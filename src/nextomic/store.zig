//! store.zig — Env ownership, the twelve trees, sys counters, bootstrap
//! and the raw datom write / scan primitives (NEXTOMIC.md §2).
//!
//! Invariants:
//!   - The environment is opened with the geometry every nexis store
//!     shares, which `db.StoreFile.acquire` pins; the page size is
//!     fixed for the file's life.
//!   - All twelve trees are opened at open and their `TreeId`s are
//!     cached for the store's life (tree registration is the only
//!     non-thread-safe engine call). A complete store opens in a read
//!     transaction; a write transaction creates a tree absent from the
//!     file, so a store written without one gains it.
//!   - Every store and `db/*` connection of one file in this process
//!     shares the file's one environment (`db.StoreFile`), so a second
//!     writer is `error.WriterActive`, never a wait on this process's own
//!     writer lock.
//!   - `sys["t"]` is the last committed logical transaction number and
//!     commits atomically with the datoms it counts.
//!   - Bootstrap ids are fixed (`boot`): a store created by any build has
//!     `:db/ident` at 1, `:db.unique/value` at 21 and `:db/fulltext` at
//!     22, and a reopened store reads the same ids back from the file. A
//!     store whose idents lack `:db/fulltext` receives it at open, minted
//!     at the store's next ident id in a transaction of its own, and the
//!     id it took is `fulltext_aid`.
//!   - Current-tree values are `[t:6]` (a format-1 store's `nx/eavt`
//!     rows may follow it with their payload); history-tree values are
//!     empty, except an out-of-line value's payload on each `nx/eavt-h`
//!     assertion row of its fact.
//!   - A value spanning several pages, from a cursor or `getFromTree`,
//!     is assembled in the transaction's buffer and valid until the
//!     transaction's next mutation or its end (emdb API-KV01); callers
//!     copy what they keep past either.
//!   - A cursor move that meets a page failing its check returns no
//!     entry and records why (emdb API-C08); every walk here reads that
//!     record (`ended`), so a damaged page is an error, never the end
//!     of a scan.

const std = @import("std");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
pub const db_layer = @import("../db.zig");

const Allocator = std.mem.Allocator;
const Txn = emdb.Txn;
const TreeId = emdb.TreeId;
const Index = key.Index;
const Datom = datom_mod.Datom;

/// The newest store format this build reads and writes (NEXTOMIC.md
/// §2.3). A new store is format 1; the first transaction that writes
/// an out-of-line value makes it 2, whose current EAVT rows hold `t`
/// alone.
pub const format_version: u16 = 2;
const format_payload_once: u16 = 2;

// =============================================================================
// Trees
// =============================================================================

pub const tree_names = [_][]const u8{
    "nx/eavt",   "nx/aevt",   "nx/avet",   "nx/vaet",
    "nx/eavt-h", "nx/aevt-h", "nx/avet-h", "nx/vaet-h",
    "nx/txlog",  "nx/idents", "nx/sys",    "nx/fulltext",
};

pub const Trees = struct {
    current: [4]TreeId,
    history: [4]TreeId,
    txlog: TreeId,
    idents: TreeId,
    sys: TreeId,
    /// The tokens of `:db/fulltext` string values (NEXTOMIC.md §2).
    fulltext: TreeId,

    pub inline fn cur(self: Trees, index: Index) TreeId {
        return self.current[@backingInt(index)];
    }

    pub inline fn hist(self: Trees, index: Index) TreeId {
        return self.history[@backingInt(index)];
    }
};

/// How one commit syncs: data and meta, data only, or nothing
/// (`db.Durability` chooses a connection's).
pub const SyncMode = enum {
    full,
    no_meta,
    none,

    pub fn of(durability: db_layer.Durability) SyncMode {
        return switch (durability) {
            .commit => .none,
            .durable => .full,
        };
    }

    fn override(self: SyncMode) emdb.SyncOverride {
        return switch (self) {
            .full => .full,
            .no_meta => .noMeta,
            .none => .none,
        };
    }
};

pub const Options = struct {
    /// How the commit that creates, bootstraps or completes the store
    /// syncs.
    sync: SyncMode = .full,
    /// False leaves `:db/fulltext` out of the bootstrap, making a store
    /// as one written without the attribute, for the test of its mint
    /// at open.
    fulltext_attr: bool = true,
};

// =============================================================================
// Bootstrap ids (§2.4)
// =============================================================================

pub const boot = struct {
    // Attributes.
    pub const ident: u32 = 1;
    pub const value_type: u32 = 2;
    pub const cardinality: u32 = 3;
    pub const unique: u32 = 4;
    pub const index: u32 = 5;
    pub const is_component: u32 = 6;
    pub const doc: u32 = 7;
    pub const tx_instant: u32 = 8;
    // Value-type idents.
    pub const type_long: u32 = 9;
    pub const type_double: u32 = 10;
    pub const type_instant: u32 = 11;
    pub const type_keyword: u32 = 12;
    pub const type_ref: u32 = 13;
    pub const type_string: u32 = 14;
    pub const type_uuid: u32 = 15;
    pub const type_bytes: u32 = 16;
    pub const type_boolean: u32 = 17;
    // Cardinality idents.
    pub const card_one: u32 = 18;
    pub const card_many: u32 = 19;
    // Unique idents.
    pub const unique_identity: u32 = 20;
    pub const unique_value: u32 = 21;
    /// The `:db/fulltext` attribute, in a store bootstrapped with it.
    pub const fulltext: u32 = 22;
    /// First id minted after bootstrap.
    pub const next_aid: u32 = 23;
    /// The bootstrap transaction.
    pub const t: u64 = 1;

    pub const Ident = struct { id: u32, name: []const u8 };
    pub const idents = [_]Ident{
        .{ .id = ident, .name = "db/ident" },
        .{ .id = value_type, .name = "db/valueType" },
        .{ .id = cardinality, .name = "db/cardinality" },
        .{ .id = unique, .name = "db/unique" },
        .{ .id = index, .name = "db/index" },
        .{ .id = is_component, .name = "db/isComponent" },
        .{ .id = doc, .name = "db/doc" },
        .{ .id = tx_instant, .name = "db/txInstant" },
        .{ .id = type_long, .name = "db.type/long" },
        .{ .id = type_double, .name = "db.type/double" },
        .{ .id = type_instant, .name = "db.type/instant" },
        .{ .id = type_keyword, .name = "db.type/keyword" },
        .{ .id = type_ref, .name = "db.type/ref" },
        .{ .id = type_string, .name = "db.type/string" },
        .{ .id = type_uuid, .name = "db.type/uuid" },
        .{ .id = type_bytes, .name = "db.type/bytes" },
        .{ .id = type_boolean, .name = "db.type/boolean" },
        .{ .id = card_one, .name = "db.cardinality/one" },
        .{ .id = card_many, .name = "db.cardinality/many" },
        .{ .id = unique_identity, .name = "db.unique/identity" },
        .{ .id = unique_value, .name = "db.unique/value" },
        .{ .id = fulltext, .name = "db/fulltext" },
    };
    /// The idents through `unique_value`: the bootstrap without
    /// `:db/fulltext`.
    pub const idents_without_fulltext = idents[0 .. idents.len - 1];
    /// The idents that are entities without a value type: the
    /// `:db.type/*`, `:db.cardinality/*` and `:db.unique/*`
    /// enumerations, each bootstrapped by its `:db/ident` datom alone.
    pub const enum_idents = idents[type_long - 1 .. unique_value];

    pub const Attr = struct {
        id: u32,
        type_ident: u32,
        many: bool = false,
        unique_ident: ?u32 = null,
        indexed: bool = false,
    };
    pub const attrs = [_]Attr{
        .{ .id = ident, .type_ident = type_keyword, .unique_ident = unique_identity, .indexed = true },
        .{ .id = value_type, .type_ident = type_keyword },
        .{ .id = cardinality, .type_ident = type_keyword },
        .{ .id = unique, .type_ident = type_keyword },
        .{ .id = index, .type_ident = type_boolean },
        .{ .id = is_component, .type_ident = type_boolean },
        .{ .id = doc, .type_ident = type_string },
        .{ .id = tx_instant, .type_ident = type_instant, .indexed = true },
        .{ .id = fulltext, .type_ident = type_boolean },
    };
    /// The ident and attribute datoms of `:db/fulltext`.
    pub const fulltext_attr: Attr = attrs[attrs.len - 1];
    /// The attributes through `:db/txInstant`: the bootstrap without
    /// `:db/fulltext`.
    pub const attrs_without_fulltext = attrs[0 .. attrs.len - 1];

    comptime {
        // `idents[i]` carries id `i + 1`, so the enumerations slice by id.
        for (idents, 1..) |id, i| std.debug.assert(id.id == i);
        std.debug.assert(fulltext_attr.id == fulltext);
        std.debug.assert(enum_idents[0].id == type_long and enum_idents[enum_idents.len - 1].id == unique_value);
    }

    /// Value type named by a `:db.type/*` ident, or null.
    pub fn valueTypeOf(type_ident: u32) ?key.ValueType {
        return switch (type_ident) {
            type_long => .long,
            type_double => .double,
            type_instant => .instant,
            type_keyword => .keyword,
            type_ref => .ref,
            type_string => .string,
            type_uuid => .uuid,
            type_bytes => .bytes,
            type_boolean => .boolean,
            else => null,
        };
    }
};

// =============================================================================
// Store
// =============================================================================

/// The case folding `nx/fulltext` rows are written under (fulltext.zig
/// `fold`); 1, folding ASCII only, is what a store without a stamp
/// holds.
pub const fulltext_fold: u8 = 3;

pub const FulltextStamp = struct { fold: u8, t: u64 };

pub const Store = struct {
    allocator: Allocator,
    /// The file's one environment in this process, shared with every
    /// other store and `db/*` connection of it (`db.StoreFile`).
    file: *db_layer.StoreFile,
    trees: Trees,
    uuid: [16]u8,
    /// The id of the `:db/fulltext` attribute in this store.
    fulltext_aid: u32,

    /// Open or create the store at `path`. The store is heap-allocated
    /// so it never moves while transactions reference it. A store that
    /// has every tree, its header and `:db/fulltext` opens in a read
    /// transaction alone; a write transaction runs only to create,
    /// bootstrap or complete one. A file this process may not write
    /// opens read-only.
    pub fn open(allocator: Allocator, path: [*:0]const u8, options: Options) !*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .file = try db_layer.StoreFile.acquire(path, .{ .allocator = allocator }),
            .trees = undefined,
            .uuid = @splat(0),
            .fulltext_aid = boot.fulltext,
        };
        errdefer self.file.release();

        if (!try self.openComplete()) {
            const txn = try self.file.beginWrite(.{ .sync = options.sync.override() });
            errdefer txn.abort();
            try self.openTrees(txn);
            if (try self.sysGet(txn, "format")) |_| {
                try self.readHeader(txn);
                try self.ensureFulltextAttr(txn);
            } else {
                try self.bootstrap(txn, options.fulltext_attr);
            }
            try self.file.commit(txn);
        }
        return self;
    }

    /// Release the file and free the store. Called once; the
    /// connection owns the store.
    pub fn close(self: *Store) void {
        self.file.release();
        self.allocator.destroy(self);
    }

    /// Open the trees, header and `:db/fulltext` id of a complete store
    /// in a read transaction; false when anything is missing.
    fn openComplete(self: *Store) !bool {
        const txn = try self.file.env.beginRead();
        defer txn.abort();
        var ids: [tree_names.len]TreeId = undefined;
        for (tree_names, 0..) |name, i| {
            ids[i] = txn.openTree(name, false) catch |err| switch (err) {
                error.NotFound => return false,
                else => return err,
            };
        }
        self.setTrees(ids);
        if ((try self.sysGet(txn, "format")) == null) return false;
        try self.readHeader(txn);
        self.fulltext_aid = (try self.identIdByName(txn, "db/fulltext")) orelse return false;
        return true;
    }

    fn openTrees(self: *Store, txn: *Txn) !void {
        var ids: [tree_names.len]TreeId = undefined;
        for (tree_names, 0..) |name, i| {
            ids[i] = try txn.openTree(name, true);
        }
        self.setTrees(ids);
    }

    fn setTrees(self: *Store, ids: [tree_names.len]TreeId) void {
        self.trees = .{
            .current = ids[0..4].*,
            .history = ids[4..8].*,
            .txlog = ids[8],
            .idents = ids[9],
            .sys = ids[10],
            .fulltext = ids[11],
        };
    }

    fn readHeader(self: *Store, txn: *Txn) !void {
        const fmt = (try self.sysGet(txn, "format")) orelse return error.Corrupted;
        if (fmt.len != 2) return error.Corrupted;
        const version = std.mem.readInt(u16, fmt[0..2], .big);
        if (version == 0 or version > format_version) return error.Format;
        const uuid = (try self.sysGet(txn, "uuid")) orelse return error.Corrupted;
        if (uuid.len != 16) return error.Corrupted;
        self.uuid = uuid[0..16].*;
    }

    // ── Transactions ──────────────────────────────────────────────

    // A transaction opens a tree on its first use of the cached handle
    // (emdb INV-SUB03), so it pays only for the trees it touches: a
    // transaction of one entity writes eight or ten of the twelve, and
    // a read touches fewer still. The handles hold for the store's
    // life: nexis never deletes a tree, and `db/*` refuses an `nx/`
    // name (`db.zig`), so an open finds the record the handle names
    // (NEXTOMIC.md §2).

    /// Begin a read transaction.
    pub fn beginRead(self: *Store) !*Txn {
        return self.file.env.beginRead();
    }

    /// Begin a read-only child of the open write transaction `parent`,
    /// seeing its uncommitted state. The parent refuses mutations and
    /// commit until the child is finished.
    pub fn beginReadChild(self: *Store, parent: *Txn) !*Txn {
        _ = self;
        return parent.beginReadChild();
    }

    /// Begin the write transaction: `error.WriterActive` while any store
    /// or `db/*` connection of the file holds it
    /// (`db.StoreFile.beginWrite`).
    pub fn beginWrite(self: *Store, sync_mode: SyncMode) !*Txn {
        return self.file.beginWrite(.{ .sync = sync_mode.override() });
    }

    /// Commit the write transaction `txn` (`db.StoreFile.commit`).
    pub fn commit(self: *Store, txn: *Txn) !void {
        try self.file.commit(txn);
    }

    /// Make every commit so far durable: one full sync, when a commit
    /// since the last left the file unsynced; `error.SyncFailed` once a
    /// sync of the file has failed (`db.StoreFile.sync`).
    pub fn sync(self: *Store) !void {
        try self.file.sync();
    }

    /// The sync of a `release`: `sync`, but nothing once a sync of the
    /// file has failed (`db.StoreFile.closingSync`).
    pub fn closingSync(self: *Store) !void {
        try self.file.closingSync();
    }

    // ── sys ───────────────────────────────────────────────────────

    pub fn sysGet(self: *Store, txn: *Txn, name: []const u8) !?[]const u8 {
        return txn.getFromTree(self.trees.sys, name);
    }

    pub fn sysPut(self: *Store, txn: *Txn, name: []const u8, bytes: []const u8) !void {
        try txn.putInTree(self.trees.sys, name, bytes);
    }

    fn sysGetInt(self: *Store, txn: *Txn, name: []const u8, comptime width: usize) !u64 {
        const raw = (try self.sysGet(txn, name)) orelse return error.Corrupted;
        if (raw.len != width) return error.Corrupted;
        return std.mem.readInt(@Int(.unsigned, width * 8), raw[0..width], .big);
    }

    fn sysPutInt(self: *Store, txn: *Txn, name: []const u8, comptime width: usize, n: u64) !void {
        var buf: [width]u8 = undefined;
        std.mem.writeInt(@Int(.unsigned, width * 8), &buf, @intCast(n), .big);
        try self.sysPut(txn, name, &buf);
    }

    /// Last committed logical transaction number.
    pub fn readT(self: *Store, txn: *Txn) !u64 {
        const t = try self.sysGetInt(txn, "t", 6);
        return if (t >= key.tx_partition_bit) error.Corrupted else t;
    }

    pub fn writeT(self: *Store, txn: *Txn, t: u64) !void {
        try self.sysPutInt(txn, "t", 6, t);
    }

    /// Next user entity id.
    pub fn readNextEid(self: *Store, txn: *Txn) !u64 {
        const eid = try self.sysGetInt(txn, "eid", 6);
        return if (eid < key.user_partition_start or eid > key.user_partition_end) error.Corrupted else eid;
    }

    pub fn writeNextEid(self: *Store, txn: *Txn, eid: u64) !void {
        try self.sysPutInt(txn, "eid", 6, eid);
    }

    /// Next attribute / ident id.
    pub fn readNextAid(self: *Store, txn: *Txn) !u32 {
        const aid = try self.sysGetInt(txn, "aid", 4);
        return if (aid == 0) error.Corrupted else @intCast(aid);
    }

    pub fn writeNextAid(self: *Store, txn: *Txn, aid: u32) !void {
        try self.sysPutInt(txn, "aid", 4, aid);
    }

    fn countKey(a: u32) [1 + key.attr_len]u8 {
        var k: [1 + key.attr_len]u8 = undefined;
        k[0] = 'n';
        key.writeAttr(k[1..], a);
        return k;
    }

    /// Number of current datoms of attribute `a` (AEVT entries).
    pub fn attrCount(self: *Store, txn: *Txn, a: u32) !u64 {
        const k = countKey(a);
        const raw = (try self.sysGet(txn, &k)) orelse return 0;
        if (raw.len != 8) return error.Corrupted;
        // No attribute holds more current datoms than there are ids.
        const n = std.mem.readInt(u64, raw[0..8], .big);
        return if (n > key.id_max) error.Corrupted else n;
    }

    pub fn writeAttrCount(self: *Store, txn: *Txn, a: u32, n: u64) !void {
        const k = countKey(a);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, n, .big);
        try self.sysPut(txn, &k, &buf);
    }

    // ── idents ────────────────────────────────────────────────────

    pub fn identIdByName(self: *Store, txn: *Txn, name: []const u8) !?u32 {
        return self.identIdUnder(txn, ident_live, name);
    }

    /// The id a retired name (`[0x02][text]`) once named, or null. Read
    /// by the txlog decoder, whose entries spell keywords by the name
    /// they had when written, and by the minter, which never reuses a
    /// retired name.
    pub fn retiredIdentId(self: *Store, txn: *Txn, name: []const u8) !?u32 {
        return self.identIdUnder(txn, ident_retired, name);
    }

    fn identIdUnder(self: *Store, txn: *Txn, prefix: u8, name: []const u8) !?u32 {
        var buf: [256]u8 = undefined;
        const k = try identNameKey(&buf, self.allocator, prefix, name);
        defer if (k.len > buf.len) self.allocator.free(k);
        const raw = (try txn.getFromTree(self.trees.idents, k)) orelse return null;
        if (raw.len != key.attr_len) return error.Corrupted;
        return key.readAttr(raw[0..key.attr_len]);
    }

    pub fn identNameById(self: *Store, txn: *Txn, id: u32) !?[]const u8 {
        var k: [1 + key.attr_len]u8 = undefined;
        k[0] = 0x01;
        key.writeAttr(k[1..], id);
        return txn.getFromTree(self.trees.idents, &k);
    }

    /// Write both directions of an ident mapping.
    pub fn putIdent(self: *Store, txn: *Txn, name: []const u8, id: u32) !void {
        var buf: [256]u8 = undefined;
        const k = try identNameKey(&buf, self.allocator, ident_live, name);
        defer if (k.len > buf.len) self.allocator.free(k);
        var idb: [key.attr_len]u8 = undefined;
        key.writeAttr(&idb, id);
        try txn.putInTree(self.trees.idents, k, &idb);
        var rk: [1 + key.attr_len]u8 = undefined;
        rk[0] = ident_by_id;
        key.writeAttr(rk[1..], id);
        try txn.putInTree(self.trees.idents, &rk, name);
    }

    /// Give ident `id` the name `new`: its old name moves from the live
    /// names to the retired ones, where it stays reserved, and `new`
    /// maps both ways. Bumps the ident generation so every cache
    /// reloads.
    pub fn renameIdent(self: *Store, txn: *Txn, id: u32, new: []const u8) !void {
        const old = (try self.identNameById(txn, id)) orelse return error.Corrupted;
        const old_copy = try self.allocator.dupe(u8, old);
        defer self.allocator.free(old_copy);
        var buf: [256]u8 = undefined;
        const live = try identNameKey(&buf, self.allocator, ident_live, old_copy);
        defer if (live.len > buf.len) self.allocator.free(live);
        _ = try txn.delFromTree(self.trees.idents, live);
        var rbuf: [256]u8 = undefined;
        const retired = try identNameKey(&rbuf, self.allocator, ident_retired, old_copy);
        defer if (retired.len > rbuf.len) self.allocator.free(retired);
        var idb: [key.attr_len]u8 = undefined;
        key.writeAttr(&idb, id);
        try txn.putInTree(self.trees.idents, retired, &idb);
        try self.putIdent(txn, new, id);
        try self.writeIdentGen(txn, (try self.readIdentGen(txn)) + 1);
    }

    /// Key prefixes of `nx/idents`: live name → id, id → name, retired
    /// name → id.
    const ident_live: u8 = 0x00;
    const ident_by_id: u8 = 0x01;
    const ident_retired: u8 = 0x02;

    fn identNameKey(buf: []u8, gpa: Allocator, prefix: u8, name: []const u8) ![]u8 {
        const k = if (name.len + 1 <= buf.len) buf[0 .. name.len + 1] else try gpa.alloc(u8, name.len + 1);
        k[0] = prefix;
        @memcpy(k[1..], name);
        return k;
    }

    /// The ident generation: bumped by every rename, so a cache that
    /// remembers the generation it loaded at knows when a name it holds
    /// may have moved. Absent in a store with no renames, which reads
    /// as 0.
    pub fn readIdentGen(self: *Store, txn: *Txn) !u64 {
        const raw = (try self.sysGet(txn, "ig")) orelse return 0;
        if (raw.len != 8) return error.Corrupted;
        return std.mem.readInt(u64, raw[0..8], .big);
    }

    fn writeIdentGen(self: *Store, txn: *Txn, gen: u64) !void {
        try self.sysPutInt(txn, "ig", 8, gen);
    }

    /// The `nx/fulltext` stamp: the folding its rows were written under
    /// and the `t` they are current at; null when absent (rows that
    /// fold ASCII only).
    pub fn readFulltextStamp(self: *Store, txn: *Txn) !?FulltextStamp {
        const raw = (try self.sysGet(txn, "ft")) orelse return null;
        if (raw.len != 1 + key.id_len) return error.Corrupted;
        return .{ .fold = raw[0], .t = try key.readT(raw[1..][0..key.id_len]) };
    }

    /// Stamp the rows current at `t` under `fulltext_fold`.
    pub fn writeFulltextStamp(self: *Store, txn: *Txn, t: u64) !void {
        var buf: [1 + key.id_len]u8 = undefined;
        buf[0] = fulltext_fold;
        key.writeId(buf[1..][0..key.id_len], t);
        try self.sysPut(txn, "ft", &buf);
    }

    /// Whether the rows are this build's folding, current at `t`.
    pub fn fulltextFresh(self: *Store, txn: *Txn, t: u64) !bool {
        const stamp = (try self.readFulltextStamp(txn)) orelse return false;
        return stamp.fold == fulltext_fold and stamp.t == t;
    }

    /// Schema generation: bumped by every transaction that writes a
    /// datom on an attribute-partition entity; absent reads as 0.
    pub fn readSchemaGen(self: *Store, txn: *Txn) !u64 {
        const raw = (try self.sysGet(txn, "sg")) orelse return 0;
        if (raw.len != 8) return error.Corrupted;
        return std.mem.readInt(u64, raw[0..8], .big);
    }

    pub fn bumpSchemaGen(self: *Store, txn: *Txn) !void {
        try self.sysPutInt(txn, "sg", 8, (try self.readSchemaGen(txn)) +% 1);
    }

    // ── txlog ─────────────────────────────────────────────────────

    fn txlogKey(t: u64) [key.id_len]u8 {
        var k: [key.id_len]u8 = undefined;
        key.writeId(&k, t);
        return k;
    }

    pub fn putTxlog(self: *Store, txn: *Txn, t: u64, bytes: []const u8) !void {
        const k = txlogKey(t);
        try txn.putInTree(self.trees.txlog, &k, bytes);
    }

    /// The full entry (multi-page values are assembled).
    pub fn getTxlog(self: *Store, txn: *Txn, t: u64) !?[]const u8 {
        const k = txlogKey(t);
        return txn.getFromTree(self.trees.txlog, &k);
    }

    // ── datoms ────────────────────────────────────────────────────

    /// One datom ready to write: encoded value, optional out-of-line
    /// payload, and which optional indexes it belongs in.
    pub const Prepared = struct {
        e: u64,
        a: u32,
        vbytes: []const u8,
        payload: ?[]const u8 = null,
        added: bool,
        avet: bool,
        vaet: bool,
    };

    /// Write a batch of datoms of transaction `t` to the eight index
    /// trees: EAVT, then AEVT, then AVET and VAET, each current tree
    /// before its history twin, each tree in the order `writeTree`
    /// gives. Scratch lives in `arena`.
    pub fn writeBatch(self: *Store, txn: *Txn, t: u64, batch: []const Prepared, arena: Allocator) !void {
        if (batch.len == 0) return;
        for (batch) |p| {
            if (p.payload != null) {
                // A reader of format 1 alone would take a current or
                // retraction row's missing payload for an empty value.
                if (try self.sysGetInt(txn, "format", 2) < format_payload_once) try self.sysPutInt(txn, "format", 2, format_payload_once);
                break;
            }
        }
        // The keys of one index, packed end to end and reused for the
        // next; an index a datom is absent from gets an empty key.
        var total: usize = 0;
        for (batch) |p| total += key.id_len + key.attr_len + p.vbytes.len;
        var keys: std.ArrayList(u8) = .empty;
        try keys.ensureTotalCapacityPrecise(arena, total);
        const offsets = try arena.alloc(u32, batch.len + 1);
        const order = try arena.alloc(usize, batch.len);
        const sorted = try arena.alloc(usize, batch.len);
        for (order, 0..) |*o, i| o.* = i;
        inline for (.{ Index.eavt, Index.aevt, Index.avet, Index.vaet }) |index| {
            keys.clearRetainingCapacity();
            for (batch, 0..) |p, i| {
                offsets[i] = @intCast(keys.items.len);
                if (index == .avet and !p.avet or index == .vaet and !p.vaet) continue;
                try key.packKey(&keys, arena, index, p.e, p.a, p.vbytes, null);
            }
            offsets[batch.len] = @intCast(keys.items.len);
            const packed_keys: PackedKeys = .{ .bytes = keys.items, .offsets = offsets };
            // Stable, so equal keys keep their batch order.
            std.mem.sort(usize, order, packed_keys, PackedKeys.less);
            var n: usize = 0;
            for (order) |i| {
                if (packed_keys.at(i).len == 0) continue;
                sorted[n] = i;
                n += 1;
            }
            const w: TreeWrite = .{ .index = index, .t = t, .batch = batch, .keys = packed_keys, .sorted = sorted[0..n] };
            try self.writeTree(txn, w, false);
            try self.writeTree(txn, w, true);
        }
    }

    const PackedKeys = struct {
        bytes: []const u8,
        offsets: []const u32,

        fn at(self: PackedKeys, i: usize) []const u8 {
            return self.bytes[self.offsets[i]..self.offsets[i + 1]];
        }

        fn less(self: PackedKeys, a: usize, b: usize) bool {
            return std.mem.order(u8, self.at(a), self.at(b)) == .lt;
        }
    };

    /// One index's share of a batch: its current keys and their
    /// ascending order.
    const TreeWrite = struct {
        index: Index,
        t: u64,
        batch: []const Prepared,
        keys: PackedKeys,
        sorted: []const usize,

        /// The key of the `r`th datom in key order, in the current or
        /// the history tree's form.
        fn keyAt(self: TreeWrite, buf: *[key.max_key_len]u8, r: usize, history: bool) []const u8 {
            const i = self.sorted[r];
            const k = self.keys.at(i);
            if (!history) return k;
            @memcpy(buf[0..k.len], k);
            key.writeTop(buf[k.len..][0..key.top_len], self.t, self.batch[i].added);
            return buf[0 .. k.len + key.top_len];
        }
    };

    /// Write one index's share of a batch to its current or history
    /// tree in ascending key order (NEXTOMIC.md §2.5). emdb takes an
    /// ascending run of puts without a descent wherever it lands in the
    /// tree and splits a leaf the run fills right-biased, so the run
    /// leaves its leaves about nine tenths full, between existing keys
    /// as at the tree's end.
    fn writeTree(self: *Store, txn: *Txn, w: TreeWrite, comptime history: bool) !void {
        var buf: [key.max_key_len]u8 = undefined;
        for (0..w.sorted.len) |r| try self.writeOne(txn, w, r, history, &buf);
    }

    fn writeOne(self: *Store, txn: *Txn, w: TreeWrite, r: usize, comptime history: bool, buf: *[key.max_key_len]u8) !void {
        const p = w.batch[w.sorted[r]];
        const k = w.keyAt(buf, r, history);
        if (history) {
            const payload: []const u8 = if (w.index == .eavt and p.added) (p.payload orelse &.{}) else &.{};
            return txn.putInTree(self.trees.hist(w.index), k, payload);
        }
        if (!p.added) {
            _ = try txn.delFromTree(self.trees.cur(w.index), k);
            return;
        }
        var tb: [key.id_len]u8 = undefined;
        key.writeId(&tb, w.t);
        try txn.putInTree(self.trees.cur(w.index), k, &tb);
    }

    /// The out-of-line payload of the current datom `(e a v)`, copied
    /// into `arena`: the EAVT-h value of the fact's latest row when that
    /// row is an assertion (every EAVT-h assertion row of an out-of-line
    /// value holds its payload, in every format), null when the fact is
    /// not current. One seek, the cost of the current row's own read.
    pub fn currentPayload(self: *Store, txn: *Txn, e: u64, a: u32, vbytes: []const u8, arena: Allocator) !?[]const u8 {
        if (vbytes.len > key.max_val_len) return error.Corrupted;
        var buf: [key.max_key_len]u8 = undefined;
        const fact_len = key.id_len + key.attr_len + vbytes.len;
        key.writeId(buf[0..key.id_len], e);
        key.writeAttr(buf[key.id_len..][0..key.attr_len], a);
        @memcpy(buf[key.id_len + key.attr_len ..][0..vbytes.len], vbytes);
        const fact = buf[0..fact_len];
        // Past every `top` of the fact (whose first byte is below 0x80)
        // and before any longer fact it prefixes.
        buf[fact_len] = 0x80;
        const probe = buf[0 .. fact_len + 1];
        var c = try txn.openCursorForTree(self.trees.hist(.eavt));
        const row = (if (c.setRange(probe) != null) c.prev() else c.last()) orelse {
            try ended(&c);
            return null;
        };
        if (row.key.len != fact.len + key.top_len or !std.mem.startsWith(u8, row.key, fact)) return null;
        const top = try key.readTop(row.key[fact.len..][0..key.top_len]);
        return if (top.added) try arena.dupe(u8, row.value) else null;
    }

    /// The history-tree value of `(e a v top)` in `index`, or null. An
    /// EAVT-h retraction row holds no payload (a format-1 one may): its
    /// value is that of the row before it, the assertion it retracts.
    pub fn getHistory(self: *Store, txn: *Txn, index: Index, e: u64, a: u32, vbytes: []const u8, top: key.Top, arena: Allocator) !?[]const u8 {
        const k = try key.keyBytes(arena, index, e, a, vbytes, top);
        if (index != .eavt or top.added) return txn.getFromTree(self.trees.hist(index), k);
        var c = try txn.openCursorForTree(self.trees.hist(index));
        const row = c.set(k) orelse {
            try ended(&c);
            return null;
        };
        if (row.value.len > 0) return row.value;
        const before = c.prev() orelse {
            try ended(&c);
            return error.Corrupted;
        };
        const fact_len = k.len - key.top_len;
        if (before.key.len != k.len or !std.mem.eql(u8, before.key[0..fact_len], k[0..fact_len])) return error.Corrupted;
        if (!(try key.readTop(before.key[fact_len..][0..key.top_len])).added) return error.Corrupted;
        return before.value;
    }

    // ── scans ─────────────────────────────────────────────────────

    pub const KeyValue = emdb.Cursor.KeyValue;

    /// A cursor move that found no entry: the tree's real end, or the
    /// page or value the cursor could not read, which it records rather
    /// than returns (emdb API-C08). A damaged page is an error, never a
    /// short scan.
    pub fn ended(c: *const emdb.Cursor) emdb.cursor.OverflowError!void {
        if (c.failure) |err| return err;
    }

    /// Forward scan of one tree: the keys starting with a prefix (every
    /// key when it is empty), or the keys in `[start, end)` (an absent
    /// `end` runs to the tree's last key). Keys and values borrow the
    /// transaction's snapshot until its next mutation or its end.
    pub const Scan = struct {
        cursor: emdb.Cursor,
        start: []const u8,
        stop: union(enum) { prefix: []const u8, end: ?[]const u8 },
        started: bool = false,
        done: bool = false,

        pub fn next(self: *Scan) !?KeyValue {
            if (self.done) return null;
            const kv = if (!self.started) blk: {
                self.started = true;
                break :blk if (self.start.len == 0) self.cursor.first() else self.cursor.setRange(self.start);
            } else self.cursor.next();
            if (kv) |e| {
                const inside = switch (self.stop) {
                    .prefix => |p| key.hasPrefix(e.key, p),
                    .end => |end| if (end) |x| std.mem.order(u8, e.key, x) == .lt else true,
                };
                if (inside) return e;
            } else try ended(&self.cursor);
            self.done = true;
            return null;
        }
    };

    pub fn scan(txn: *Txn, tree: TreeId, prefix: []const u8) !Scan {
        return .{ .cursor = try txn.openCursorForTree(tree), .start = prefix, .stop = .{ .prefix = prefix } };
    }

    pub fn scanRange(txn: *Txn, tree: TreeId, start: []const u8, end: ?[]const u8) !Scan {
        return .{ .cursor = try txn.openCursorForTree(tree), .start = start, .stop = .{ .end = end } };
    }

    /// Which history rows a fold sees (NEXTOMIC.md §4).
    pub const Window = union(enum) {
        /// `t <= T`: fold, emit current facts as of `T`.
        as_of: u64,
        /// `after < t <= upto`: fold from an empty state.
        since: struct { after: u64, upto: u64 },
        /// `after < t <= upto`: every row, no fold.
        all: struct { after: u64, upto: u64 },

        pub fn contains(self: Window, t: u64) bool {
            return switch (self) {
                .as_of => |upto| t <= upto,
                .since => |w| t > w.after and t <= w.upto,
                .all => |w| t > w.after and t <= w.upto,
            };
        }
    };

    /// One row of a fact's timeline: the key without `top`, `t` and
    /// `added`. The fact borrows the transaction's snapshot.
    pub const HistoryRow = struct {
        fact: []const u8,
        t: u64,
        added: bool,
        /// The fact's current-tree row, its latest assertion, whose `t`
        /// is the row's value.
        current: bool = false,
    };

    /// The rows of one index in `[start, end)` from its current tree and
    /// its history twin together: every fact in order, and each fact's
    /// rows in ascending `t`, its history rows before its current row.
    /// The trees are compared by fact bytes, a history key less its
    /// `top`: a current key is a byte prefix of its own history keys,
    /// so raw keys would put it first. Facts that prefix one another
    /// (`"a"` and `"a\x00b"`, an inline value and its out-of-line
    /// sibling) sort alike in both trees: `top` starts with a zero byte
    /// below `t = 2^39`, and a fact that continues a shorter one has an
    /// escape (`0xFF`) or the out-of-line mark (`0x01`) there
    /// (NEXTOMIC.md §2.2). A current row the history tree also holds,
    /// as its fact's last row, is that row, and is read once.
    pub const MergedScan = struct {
        cur: Scan,
        hist: Scan,
        cur_row: ?KeyValue = null,
        hist_row: ?KeyValue = null,
        /// The last history row read, against which a current row is
        /// told apart from a history row it repeats.
        last: ?HistoryRow = null,

        pub fn next(self: *MergedScan) !?HistoryRow {
            while (true) {
                if (self.cur_row == null) self.cur_row = try self.cur.next();
                if (self.hist_row == null) self.hist_row = try self.hist.next();
                const c = self.cur_row;
                if (self.hist_row) |h| {
                    if (h.key.len < key.top_len) return error.Corrupted;
                    const fact = h.key[0 .. h.key.len - key.top_len];
                    if (c == null or std.mem.order(u8, fact, c.?.key) != .gt) {
                        self.hist_row = null;
                        const top = try key.readTop(h.key[fact.len..][0..key.top_len]);
                        const r: HistoryRow = .{ .fact = fact, .t = top.t, .added = top.added };
                        self.last = r;
                        return r;
                    }
                }
                const row = c orelse return null;
                self.cur_row = null;
                if (row.value.len < key.id_len) return error.Corrupted;
                const r: HistoryRow = .{ .fact = row.key, .t = try key.readT(row.value[0..key.id_len]), .added = true, .current = true };
                if (self.last) |l| if (l.added and l.t == r.t and std.mem.eql(u8, l.fact, r.fact)) continue;
                return r;
            }
        }
    };

    /// The merged rows of `index` in `[start, end)` (an absent `end`
    /// runs to the trees' last keys). The history walk reads keys
    /// alone: an EAVT-h row's payload is read for the one datom that
    /// needs it, never assembled for every row the walk passes.
    pub fn mergedScan(txn: *Txn, trees: Trees, index: Index, start: []const u8, end: ?[]const u8) !MergedScan {
        var hist = try scanRange(txn, trees.hist(index), start, end);
        hist.cursor.keysOnly = true;
        return .{ .cur = try scanRange(txn, trees.cur(index), start, end), .hist = hist };
    }

    /// The §4 fold over an index's merged rows: rows grouped by their
    /// fact bytes ascend in `t`; the last row inside the window wins and
    /// is emitted iff it is an assertion. `.all` emits every row in the
    /// window unfolded.
    pub const FoldScan = struct {
        inner: MergedScan,
        window: Window,
        pending: ?HistoryRow = null,
        exhausted: bool = false,

        pub fn next(self: *FoldScan) !?HistoryRow {
            while (!self.exhausted) {
                const r = (try self.inner.next()) orelse {
                    self.exhausted = true;
                    break;
                };
                if (!self.window.contains(r.t)) continue;
                if (self.window == .all) return r;
                if (self.pending) |p| {
                    if (std.mem.eql(u8, p.fact, r.fact)) {
                        self.pending = r;
                        continue;
                    }
                    self.pending = r;
                    if (p.added) return p;
                    continue;
                }
                self.pending = r;
            }
            if (self.pending) |p| {
                self.pending = null;
                if (p.added) return p;
            }
            return null;
        }
    };

    pub fn foldScan(txn: *Txn, trees: Trees, index: Index, start: []const u8, end: ?[]const u8, window: Window) !FoldScan {
        return .{ .inner = try mergedScan(txn, trees, index, start, end), .window = window };
    }

    /// Number of entries in `tree` at the transaction's snapshot.
    pub fn treeEntries(txn: *Txn, tree: TreeId) !u64 {
        return (try txn.treeStat(tree)).entries;
    }

    /// What a tree holds and the pages it takes: its entries' key and
    /// value bytes from a walk, its pages from `treeStat`
    /// (`docs/PERF.md` §3.11's per-tree table).
    pub const TreeSize = struct {
        entries: u64 = 0,
        key_bytes: u64 = 0,
        value_bytes: u64 = 0,
        leaf_pages: u64 = 0,
        branch_pages: u64 = 0,
        overflow_pages: u64 = 0,

        /// The share of the leaves the entries fill, counting emdb's 10
        /// bytes of pointer and node header per entry.
        pub fn fill(self: TreeSize) f64 {
            if (self.leaf_pages == 0) return 0;
            const used = self.key_bytes + self.value_bytes + 10 * self.entries;
            return @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(self.leaf_pages * leaf_usable));
        }

        pub fn pages(self: TreeSize) u64 {
            return self.leaf_pages + self.branch_pages + self.overflow_pages;
        }

        /// A leaf's room for nodes: the page less its header.
        const leaf_usable = db_layer.page_size - 32;
    };

    /// The size of `tree` at the transaction's snapshot. Each value is
    /// read into one buffer in `gpa`, so the walk holds none of them.
    pub fn treeSize(txn: *Txn, tree: TreeId, gpa: Allocator) !TreeSize {
        const stat = try txn.treeStat(tree);
        var out: TreeSize = .{ .entries = stat.entries, .leaf_pages = stat.leafPages, .branch_pages = stat.branchPages, .overflow_pages = stat.overflowPages };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        var c = try txn.openCursorForTree(tree);
        c.keysOnly = true;
        var kv = c.first();
        while (kv) |e| : (kv = c.next()) {
            out.key_bytes += e.key.len;
            out.value_bytes += ((try c.readValueInto(gpa, &buf)) orelse return error.Corrupted).len;
        }
        try ended(&c);
        return out;
    }

    // ── bootstrap (§2.4) ──────────────────────────────────────────

    fn bootstrap(self: *Store, txn: *Txn, with_fulltext: bool) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        try self.sysPutInt(txn, "format", 2, 1);
        std.Io.Threaded.global_single_threaded.io().random(&self.uuid);
        try self.sysPut(txn, "uuid", &self.uuid);

        const idents = if (with_fulltext) &boot.idents else boot.idents_without_fulltext;
        const attrs = if (with_fulltext) &boot.attrs else boot.attrs_without_fulltext;
        for (idents) |id| try self.putIdent(txn, id.name, id.id);

        var datoms: std.ArrayList(Datom) = .empty;
        const now = nowMillis();
        for (attrs) |a| try appendAttrDatoms(arena, &datoms, a, boot.t);
        for (boot.enum_idents) |id| {
            try datoms.append(arena, .{ .e = id.id, .a = boot.ident, .v = .{ .keyword = id.id }, .t = boot.t, .added = true });
        }
        try datoms.append(arena, .{ .e = key.txEntity(boot.t), .a = boot.tx_instant, .v = .{ .instant = now }, .t = boot.t, .added = true });
        try self.writeSystemTransaction(txn, arena, boot.t, now, datoms.items);

        try self.writeNextEid(txn, key.user_partition_start);
        try self.writeNextAid(txn, if (with_fulltext) boot.next_aid else boot.fulltext);
    }

    /// The ident, value type, cardinality, unique and index datoms of a
    /// bootstrap attribute at `t`.
    fn appendAttrDatoms(arena: Allocator, datoms: *std.ArrayList(Datom), a: boot.Attr, t: u64) !void {
        try datoms.append(arena, .{ .e = a.id, .a = boot.ident, .v = .{ .keyword = a.id }, .t = t, .added = true });
        try datoms.append(arena, .{ .e = a.id, .a = boot.value_type, .v = .{ .keyword = a.type_ident }, .t = t, .added = true });
        try datoms.append(arena, .{ .e = a.id, .a = boot.cardinality, .v = .{ .keyword = if (a.many) boot.card_many else boot.card_one }, .t = t, .added = true });
        if (a.unique_ident) |u| try datoms.append(arena, .{ .e = a.id, .a = boot.unique, .v = .{ .keyword = u }, .t = t, .added = true });
        if (a.indexed) try datoms.append(arena, .{ .e = a.id, .a = boot.index, .v = .{ .boolean = true }, .t = t, .added = true });
    }

    /// Write assertions the store makes on its own behalf as
    /// transaction `t`: the index trees, the counts, the txlog entry and
    /// `sys["t"]`. Every keyword value is an ident already in
    /// `nx/idents`.
    fn writeSystemTransaction(self: *Store, txn: *Txn, arena: Allocator, t: u64, now: i64, datoms: []const Datom) !void {
        const batch = try arena.alloc(Prepared, datoms.len);
        for (datoms, 0..) |d, i| {
            const avet = d.a == boot.ident or d.a == boot.tx_instant;
            batch[i] = .{
                .e = d.e,
                .a = d.a,
                .vbytes = try key.valBytes(arena, d.v),
                .added = true,
                .avet = avet,
                .vaet = false,
            };
        }
        try self.writeBatch(txn, t, batch, arena);

        var counts = std.AutoHashMapUnmanaged(u32, u64).empty;
        for (datoms) |d| {
            const g = try counts.getOrPut(arena, d.a);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        var it = counts.iterator();
        while (it.next()) |e| try self.writeAttrCount(txn, e.key_ptr.*, (try self.attrCount(txn, e.key_ptr.*)) + e.value_ptr.*);

        var names = IdentNames{ .store = self, .txn = txn };
        const entry = try datom_mod.encodeTxlog(arena, now, datoms, &.{}, .{ .ctx = @ptrCast(&names), .identName = &IdentNames.identName });
        try self.putTxlog(txn, t, entry);
        try self.writeT(txn, t);
        try self.bumpSchemaGen(txn);
        // No attribute is full-text yet: the empty tree is current.
        try self.writeFulltextStamp(txn, t);
    }

    /// Ident names for the txlog encoder, from `nx/idents` through the
    /// transaction that is writing.
    const IdentNames = struct {
        store: *Store,
        txn: *Txn,

        fn identName(ctx: *anyopaque, id: u32) anyerror!?[]const u8 {
            const self: *IdentNames = @ptrCast(@alignCast(ctx));
            return self.store.identNameById(self.txn, id);
        }
    };

    /// A store whose idents lack `:db/fulltext` receives the attribute
    /// as a transaction of its own at the store's next ident id.
    fn ensureFulltextAttr(self: *Store, txn: *Txn) !void {
        if (try self.identIdByName(txn, "db/fulltext")) |id| {
            self.fulltext_aid = id;
            return;
        }
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const id = try self.readNextAid(txn);
        if (id == std.math.maxInt(u32)) return error.DatabaseFull;
        const t = (try self.readT(txn)) + 1;
        if (t >= key.tx_partition_bit) return error.DatabaseFull;
        try self.putIdent(txn, "db/fulltext", id);
        var attr = boot.fulltext_attr;
        attr.id = id;
        var datoms: std.ArrayList(Datom) = .empty;
        const now = nowMillis();
        try appendAttrDatoms(arena, &datoms, attr, t);
        try datoms.append(arena, .{ .e = key.txEntity(t), .a = boot.tx_instant, .v = .{ .instant = now }, .t = t, .added = true });
        try self.writeSystemTransaction(txn, arena, t, now, datoms.items);
        try self.writeNextAid(txn, id + 1);
        self.fulltext_aid = id;
    }
};

// =============================================================================
// Clock
// =============================================================================

/// Wall-clock milliseconds since the Unix epoch.
pub fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

pub const TestDir = struct {
    tmp: std.testing.TmpDir,
    path: [:0]u8,

    pub fn init(name: []const u8) !TestDir {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try testing.allocator.printSentinel(".zig-cache/tmp/{s}/{s}.emdb", .{ tmp.sub_path, name }, 0);
        return .{ .tmp = tmp, .path = path };
    }

    pub fn deinit(self: *TestDir) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

const repeat = @import("../string.zig").repeat;

test "a count, a fulltext stamp or a t read out of its range is Corrupted" {
    var td = try TestDir.init("store_ranges");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginWrite(.none);
    defer txn.abort();
    // No attribute holds more current datoms than there are ids.
    try store.writeAttrCount(txn, boot.doc, key.id_max + 1);
    try testing.expectError(error.Corrupted, store.attrCount(txn, boot.doc));
    var stamp: [1 + key.id_len]u8 = undefined;
    stamp[0] = fulltext_fold;
    key.writeId(stamp[1..][0..key.id_len], key.tx_partition_bit | 1);
    try store.sysPut(txn, "ft", &stamp);
    try testing.expectError(error.Corrupted, store.readFulltextStamp(txn));
    var raw: [key.id_len]u8 = undefined;
    key.writeId(&raw, key.tx_partition_bit);
    try testing.expectError(error.Corrupted, key.readT(&raw));
    key.writeId(&raw, key.tx_partition_bit - 1);
    try testing.expectEqual(key.tx_partition_bit - 1, try key.readT(&raw));
}

test "a page that fails its check ends a scan with an error, never early" {
    var td = try TestDir.init("store_damaged");
    defer td.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fact = try key.keyBytes(arena, .eavt, boot.doc, boot.ident, try key.valBytes(arena, .{ .keyword = boot.doc }), null);
    (try Store.open(testing.allocator, td.path.ptr, .{})).close();
    // One byte flipped in every page holding :db/doc's ident row: the
    // leaves of nx/eavt and nx/eavt-h fail their checksum.
    const io = testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, td.path, arena, .unlimited);
    var at: usize = 0;
    var damaged: usize = 0;
    while (std.mem.findPos(u8, bytes, at, fact)) |i| : (at = i + fact.len) {
        bytes[i + fact.len - 1] ^= 0xFF;
        damaged += 1;
    }
    try testing.expect(damaged >= 2);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = td.path, .data = bytes });

    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginRead();
    defer txn.abort();
    var s = try Store.scan(txn, store.trees.cur(.eavt), &.{});
    try testing.expectError(error.InvalidPage, s.next());
    var f = try Store.foldScan(txn, store.trees, .eavt, &.{}, null, .{ .as_of = 1 });
    try testing.expectError(error.InvalidPage, f.next());
    try testing.expectError(error.InvalidPage, store.currentPayload(txn, boot.doc, boot.ident, fact[key.id_len + key.attr_len ..], arena));
}

test "open bootstraps once and reopen finds the same ids" {
    var td = try TestDir.init("store_boot");
    defer td.deinit();

    var uuid: [16]u8 = undefined;
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        uuid = store.uuid;
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
        try testing.expectEqual(key.user_partition_start, try store.readNextEid(txn));
        try testing.expectEqual(boot.next_aid, try store.readNextAid(txn));
        try testing.expectEqual(@as(?u32, boot.ident), try store.identIdByName(txn, "db/ident"));
        try testing.expectEqual(@as(?u32, boot.unique_value), try store.identIdByName(txn, "db.unique/value"));
        try testing.expectEqualStrings("db.type/string", (try store.identNameById(txn, boot.type_string)).?);
        try testing.expectEqual(@as(u64, boot.idents.len), try store.attrCount(txn, boot.ident));
        try testing.expect((try store.getTxlog(txn, 1)) != null);
    }
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        try testing.expectEqualSlices(u8, &uuid, &store.uuid);
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
        try testing.expectEqual(@as(?u32, boot.ident), try store.identIdByName(txn, "db/ident"));
        try testing.expectEqual(@as(u64, boot.idents.len), try store.attrCount(txn, boot.ident));
    }
}

test "a new store file starts small and grows a step at a time" {
    var td = try TestDir.init("store_map");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    try testing.expectEqual(db_layer.initial_map_size, store.file.env.info().mapSize);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Payloads past the first size grow the file in whole steps.
    const payload = try arena.alloc(u8, 4096);
    @memset(payload, 'x');
    const batch = try arena.alloc(Store.Prepared, 512);
    for (batch, 0..) |*p, i| p.* = .{ .e = (1 << 33) + i, .a = 100, .vbytes = try key.valBytes(arena, .{ .long = 0 }), .payload = payload, .added = true, .avet = false, .vaet = false };
    const txn = try store.beginWrite(.none);
    errdefer txn.abort();
    try store.writeBatch(txn, 2, batch, arena);
    try txn.commit();
    const grown = store.file.env.info().mapSize;
    try testing.expect(grown > db_layer.initial_map_size and grown < 64 << 20);
    try testing.expectEqual(0, (grown - db_layer.initial_map_size) % db_layer.map_grow_step);
}

test "a store without :db/fulltext receives it at open, at its next ident id" {
    var td = try TestDir.init("store_fulltext_open");
    defer td.deinit();
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{ .fulltext_attr = false });
        defer store.close();
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expect((try store.identIdByName(txn, "db/fulltext")) == null);
        try testing.expectEqual(boot.fulltext, try store.readNextAid(txn));
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
    }
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        try testing.expectEqual(boot.fulltext, store.fulltext_aid);
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(?u32, boot.fulltext), try store.identIdByName(txn, "db/fulltext"));
        try testing.expectEqual(boot.next_aid, try store.readNextAid(txn));
        try testing.expectEqual(@as(u64, 2), try store.readT(txn));
        try testing.expect((try store.getTxlog(txn, 2)) != null);
        try testing.expectEqual(@as(u64, boot.idents.len), try store.attrCount(txn, boot.ident));
        const prefix = try key.prefixBytes(testing.allocator, .eavt, .{ .e = boot.fulltext });
        defer testing.allocator.free(prefix);
        var s = try Store.scan(txn, store.trees.cur(.eavt), prefix);
        var n: usize = 0;
        while (try s.next()) |_| n += 1;
        try testing.expectEqual(@as(usize, 3), n);
    }
    // Opening again mints nothing more.
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 2), try store.readT(txn));
        try testing.expectEqual(boot.next_aid, try store.readNextAid(txn));
    }
}

test "a store whose next ident id is taken mints :db/fulltext past it" {
    var td = try TestDir.init("store_fulltext_taken");
    defer td.deinit();
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{ .fulltext_attr = false });
        defer store.close();
        const txn = try store.beginWrite(.none);
        try store.putIdent(txn, "user/name", boot.fulltext);
        try store.writeNextAid(txn, boot.fulltext + 1);
        try txn.commit();
    }
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    try testing.expectEqual(boot.fulltext + 1, store.fulltext_aid);
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expectEqual(@as(?u32, boot.fulltext + 1), try store.identIdByName(txn, "db/fulltext"));
    try testing.expectEqual(@as(?u32, boot.fulltext), try store.identIdByName(txn, "user/name"));
    try testing.expectEqual(boot.fulltext + 2, try store.readNextAid(txn));
}

test "bootstrap datoms are in every index they belong to" {
    var td = try TestDir.init("store_idx");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginRead();
    defer txn.abort();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // EAVT [1]: :db/ident has ident, valueType, cardinality, unique, index.
    const p = try key.prefixBytes(arena, .eavt, .{ .e = boot.ident });
    var s = try Store.scan(txn, store.trees.cur(.eavt), p);
    var n: usize = 0;
    while (try s.next()) |kv| : (n += 1) {
        try testing.expectEqual(@as(usize, key.id_len), kv.value.len);
        try testing.expectEqual(@as(u64, 1), try key.readId(kv.value[0..key.id_len]));
    }
    try testing.expectEqual(@as(usize, 5), n);

    // AVET [:db/ident] holds every ident; [:db/valueType] is not indexed.
    const pa = try key.prefixBytes(arena, .avet, .{ .a = boot.ident });
    var sa = try Store.scan(txn, store.trees.cur(.avet), pa);
    n = 0;
    while (try sa.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, boot.idents.len), n);
    const pv = try key.prefixBytes(arena, .avet, .{ .a = boot.value_type });
    var sv = try Store.scan(txn, store.trees.cur(.avet), pv);
    try testing.expect((try sv.next()) == null);

    // History mirrors current with top = (1 << 1) | 1.
    const ph = try key.prefixBytes(arena, .eavt, .{ .e = boot.ident });
    var sh = try Store.scan(txn, store.trees.hist(.eavt), ph);
    n = 0;
    while (try sh.next()) |kv| : (n += 1) {
        const parts = try key.unpackKey(.eavt, true, kv.key);
        try testing.expectEqual(@as(u64, 1), parts.top.?.t);
        try testing.expect(parts.top.?.added);
        try testing.expectEqual(@as(usize, 0), kv.value.len);
    }
    try testing.expectEqual(@as(usize, 5), n);

    // Empty prefix walks the whole tree.
    var all = try Store.scan(txn, store.trees.cur(.aevt), &.{});
    n = 0;
    while (try all.next()) |_| n += 1;
    try testing.expect(n > boot.idents.len);
}

test "abort leaves nothing behind" {
    var td = try TestDir.init("store_abort");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    {
        const txn = try store.beginWrite(.none);
        try store.writeT(txn, 99);
        try store.putIdent(txn, "gone", 1000);
        txn.abort();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expectEqual(@as(u64, 1), try store.readT(txn));
    try testing.expect((try store.identIdByName(txn, "gone")) == null);
}

test "fold keeps the newest in-window row per fact and drops retractions" {
    var td = try TestDir.init("store_fold");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Entity 2^33, attribute 100: v=1 asserted at t=2, retracted at t=3,
    // v=2 asserted at t=3, v=2 retracted at t=5; attribute 101: v=7 at t=4.
    const e: u64 = 1 << 33;
    const v1 = try key.valBytes(arena, .{ .long = 1 });
    const v2 = try key.valBytes(arena, .{ .long = 2 });
    const v7 = try key.valBytes(arena, .{ .long = 7 });
    {
        const txn = try store.beginWrite(.none);
        try store.writeBatch(txn, 2, &.{.{ .e = e, .a = 100, .vbytes = v1, .added = true, .avet = false, .vaet = false }}, arena);
        try store.writeBatch(txn, 3, &.{
            .{ .e = e, .a = 100, .vbytes = v1, .added = false, .avet = false, .vaet = false },
            .{ .e = e, .a = 100, .vbytes = v2, .added = true, .avet = false, .vaet = false },
        }, arena);
        try store.writeBatch(txn, 4, &.{.{ .e = e, .a = 101, .vbytes = v7, .added = true, .avet = false, .vaet = false }}, arena);
        try store.writeBatch(txn, 5, &.{.{ .e = e, .a = 100, .vbytes = v2, .added = false, .avet = false, .vaet = false }}, arena);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    const prefix = try key.prefixBytes(arena, .eavt, .{ .e = e });
    const end = (try key.successor(arena, prefix)).?;

    const Expect = struct { window: Store.Window, facts: []const u64 };
    const cases = [_]Expect{
        .{ .window = .{ .as_of = 1 }, .facts = &.{} },
        .{ .window = .{ .as_of = 2 }, .facts = &.{1} },
        .{ .window = .{ .as_of = 3 }, .facts = &.{2} },
        .{ .window = .{ .as_of = 4 }, .facts = &.{ 2, 7 } },
        .{ .window = .{ .as_of = 5 }, .facts = &.{7} },
        .{ .window = .{ .since = .{ .after = 3, .upto = 5 } }, .facts = &.{7} },
        .{ .window = .{ .since = .{ .after = 2, .upto = 4 } }, .facts = &.{ 2, 7 } },
        .{ .window = .{ .since = .{ .after = 4, .upto = 5 } }, .facts = &.{} },
    };
    for (cases) |c| {
        var fs = try Store.foldScan(txn, store.trees, .eavt, prefix, end, c.window);
        var got: std.ArrayList(u64) = .empty;
        while (try fs.next()) |r| {
            try testing.expect(r.added);
            const parts = try key.unpackKey(.eavt, false, r.fact);
            const kv = try key.decodeVal(arena, parts.v);
            try got.append(arena, @intCast(kv.val.long));
        }
        try testing.expectEqualSlices(u64, c.facts, got.items);
    }
    // History mode sees all five rows in t order with their flags.
    var all = try Store.foldScan(txn, store.trees, .eavt, prefix, end, .{ .all = .{ .after = 0, .upto = 5 } });
    var n: usize = 0;
    var adds: usize = 0;
    while (try all.next()) |r| {
        n += 1;
        if (r.added) adds += 1;
    }
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(usize, 3), adds);
    // Current trees hold only attribute 101 now.
    var cur = try Store.scan(txn, store.trees.cur(.eavt), prefix);
    const only = (try cur.next()).?;
    try testing.expectEqual(@as(u32, 101), (try key.unpackKey(.eavt, false, only.key)).a);
    try testing.expect((try cur.next()) == null);
}

test "batches written between existing keys fill their leaves" {
    var td = try TestDir.init("store_fill");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // New entities land before the bootstrap transaction's entity in
    // EAVT and attribute 100's between attribute 8's and 101's in AEVT;
    // attribute 101's are appended past AEVT's last key.
    var k: u64 = 0;
    for (0..16) |t| {
        const batch = try arena.alloc(Store.Prepared, 5000);
        for (0..2500) |j| {
            const e = (1 << 33) + k;
            const name = try arena.print("name-{d}", .{k});
            batch[2 * j] = .{ .e = e, .a = 100, .vbytes = try key.valBytes(arena, .{ .long = @intCast(k) }), .added = true, .avet = false, .vaet = false };
            batch[2 * j + 1] = .{ .e = e, .a = 101, .vbytes = try key.valBytes(arena, .{ .string = name }), .added = true, .avet = false, .vaet = false };
            k += 1;
        }
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        try store.writeBatch(txn, t + 2, batch, arena);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    for ([_]TreeId{ store.trees.cur(.eavt), store.trees.hist(.eavt), store.trees.cur(.aevt), store.trees.hist(.aevt) }) |tree| {
        try testing.expect((try Store.treeSize(txn, tree, testing.allocator)).fill() > 0.75);
    }
}

test "a batch holds what writing its datoms one at a time holds" {
    var tds = [2]TestDir{ try TestDir.init("store_order_batch"), try TestDir.init("store_order_single") };
    defer for (&tds) |*td| td.deinit();
    const batched = try Store.open(testing.allocator, tds[0].path.ptr, .{});
    defer batched.close();
    const single = try Store.open(testing.allocator, tds[1].path.ptr, .{});
    defer single.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(0x6e78_6f72_6465_7200);
    const rand = prng.random();

    // Batches of up to 4000 datoms over a few thousand facts, most of
    // them assertions, with retractions of held and absent facts and
    // the same fact more than once in a batch.
    for (0..30) |i| {
        const t = i + 2;
        const batch = try arena.alloc(Store.Prepared, rand.intRangeAtMost(usize, 1, 4000));
        for (batch) |*p| {
            const a = rand.intRangeAtMost(u32, 100, 102);
            const x = rand.uintLessThan(u64, 3000);
            const v: key.Val = if (a == 102) .{ .ref = (1 << 33) + x } else .{ .long = @intCast(x % 50) };
            p.* = .{
                .e = (1 << 33) + rand.uintLessThan(u64, 3000),
                .a = a,
                .vbytes = try key.valBytes(arena, v),
                .added = rand.uintLessThan(u8, 5) != 0,
                .avet = a == 101,
                .vaet = a == 102,
            };
        }
        for ([_]*Store{ batched, single }) |store| {
            const txn = try store.beginWrite(.none);
            errdefer txn.abort();
            if (store == batched) {
                try store.writeBatch(txn, t, batch, arena);
            } else for (batch) |p| try store.writeBatch(txn, t, &.{p}, arena);
            try txn.commit();
        }
    }
    const txns = [2]*Txn{ try batched.beginRead(), try single.beginRead() };
    defer for (txns) |txn| txn.abort();
    for (0..4) |ix| for ([_]bool{ false, true }) |history| {
        const index: Index = @fromBackingInt(@intCast(ix));
        // The bootstrap's datoms differ in their instants: compare the
        // keys the batches can hold.
        var start: [key.id_len]u8 = undefined;
        if (index == .eavt or index == .vaet) key.writeId(&start, 1 << 33) else key.writeAttr(start[0..key.attr_len], 100);
        const from = if (index == .eavt or index == .vaet) start[0..] else start[0..key.attr_len];
        var tx_start: [key.id_len]u8 = undefined;
        key.writeId(&tx_start, key.tx_partition_bit);
        const to: ?[]const u8 = if (index == .eavt) &tx_start else null;
        var scans: [2]Store.Scan = undefined;
        for (&scans, txns, [_]*Store{ batched, single }) |*sc, txn, store|
            sc.* = try Store.scanRange(txn, if (history) store.trees.hist(index) else store.trees.cur(index), from, to);
        while (try scans[0].next()) |x| {
            const y = (try scans[1].next()) orelse return error.TestUnexpectedResult;
            try testing.expectEqualSlices(u8, y.key, x.key);
            try testing.expectEqualSlices(u8, y.value, x.value);
        }
        try testing.expect((try scans[1].next()) == null);
    };
}

fn formatOf(store: *Store, txn: *Txn) !u16 {
    const raw = (try store.sysGet(txn, "format")).?;
    return std.mem.readInt(u16, raw[0..2], .big);
}

test "an out-of-line value is stored once in the index trees, on its assertion's history row" {
    var td = try TestDir.init("store_payload");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const e: u64 = 1 << 33;
    const long = repeat("a string long enough to leave its index keys for a payload of its own, ", 3);
    const v = try key.valBytes(arena, .{ .string = long });
    const short = try key.valBytes(arena, .{ .long = 7 });
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        try store.writeBatch(txn, 2, &.{.{ .e = e, .a = 100, .vbytes = short, .added = true, .avet = false, .vaet = false }}, arena);
        // A store no out-of-line value was written to keeps format 1.
        try testing.expectEqual(1, try formatOf(store, txn));
        try store.writeBatch(txn, 3, &.{.{ .e = e, .a = 101, .vbytes = v, .payload = long, .added = true, .avet = false, .vaet = false }}, arena);
        try txn.commit();
    }
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(2, try formatOf(store, txn));
        try testing.expectEqual(key.id_len, (try txn.getFromTree(store.trees.cur(.eavt), try key.keyBytes(arena, .eavt, e, 101, v, null))).?.len);
        try testing.expectEqualStrings(long, (try store.getHistory(txn, .eavt, e, 101, v, .{ .t = 3, .added = true }, arena)).?);
        try testing.expectEqualStrings(long, (try store.currentPayload(txn, e, 101, v, arena)).?);
    }
    {
        // The retraction's history row holds nothing; its payload is
        // its assertion's. A retraction alone moves format 1 to 2.
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        try store.sysPutInt(txn, "format", 2, 1);
        try store.writeBatch(txn, 4, &.{.{ .e = e, .a = 101, .vbytes = v, .payload = long, .added = false, .avet = false, .vaet = false }}, arena);
        try txn.commit();
    }
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(2, try formatOf(store, txn));
        try testing.expect((try store.currentPayload(txn, e, 101, v, arena)) == null);
        const k = try key.keyBytes(arena, .eavt, e, 101, v, .{ .t = 4, .added = false });
        try testing.expectEqual(0, (try txn.getFromTree(store.trees.hist(.eavt), k)).?.len);
        try testing.expectEqualStrings(long, (try store.getHistory(txn, .eavt, e, 101, v, .{ .t = 4, .added = false }, arena)).?);
    }
    {
        const w = try store.beginWrite(.none);
        errdefer w.abort();
        try store.writeBatch(w, 5, &.{.{ .e = e, .a = 101, .vbytes = v, .payload = long, .added = true, .avet = false, .vaet = false }}, arena);
        try w.commit();
    }
    const again = try store.beginRead();
    defer again.abort();
    try testing.expectEqualStrings(long, (try store.currentPayload(again, e, 101, v, arena)).?);
}

test "a store opens at every format up to this build's and refuses a newer one" {
    var td = try TestDir.init("store_format");
    defer td.deinit();
    for ([_]u16{ 1, 2, 3 }) |f| {
        {
            const store = try Store.open(testing.allocator, td.path.ptr, .{});
            defer store.close();
            const txn = try store.beginWrite(.none);
            errdefer txn.abort();
            var buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &buf, f, .big);
            try store.sysPut(txn, "format", &buf);
            try txn.commit();
        }
        if (f <= format_version) {
            const store = try Store.open(testing.allocator, td.path.ptr, .{});
            store.close();
        } else try testing.expectError(error.Format, Store.open(testing.allocator, td.path.ptr, .{}));
    }
}

test "renaming an ident retires the old name and bumps the generation" {
    var td = try TestDir.init("store_rename");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    {
        const txn = try store.beginWrite(.none);
        try testing.expectEqual(@as(u64, 0), try store.readIdentGen(txn));
        try store.putIdent(txn, "user/email", boot.next_aid);
        try store.renameIdent(txn, boot.next_aid, "user/mail");
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expect((try store.identIdByName(txn, "user/email")) == null);
    try testing.expectEqual(@as(?u32, boot.next_aid), try store.retiredIdentId(txn, "user/email"));
    try testing.expectEqual(@as(?u32, boot.next_aid), try store.identIdByName(txn, "user/mail"));
    try testing.expect((try store.retiredIdentId(txn, "user/mail")) == null);
    try testing.expectEqualStrings("user/mail", (try store.identNameById(txn, boot.next_aid)).?);
    try testing.expectEqual(@as(u64, 1), try store.readIdentGen(txn));
}

test "long ident names use the heap path" {
    var td = try TestDir.init("store_longname");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const long_name = "ns/" ++ @as([400]u8, @splat('x'));
    {
        const txn = try store.beginWrite(.none);
        try store.putIdent(txn, long_name, 5000);
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expectEqual(@as(?u32, 5000), try store.identIdByName(txn, long_name));
    try testing.expectEqualStrings(long_name, (try store.identNameById(txn, 5000)).?);
}

test "sys counters outside their partitions are corrupt" {
    var td = try TestDir.init("store_sys_range");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const txn = try store.beginWrite(.none);
    defer txn.abort();
    try store.sysPutInt(txn, "t", 6, key.tx_partition_bit);
    try testing.expectError(error.Corrupted, store.readT(txn));
    try store.sysPutInt(txn, "eid", 6, key.user_partition_end + 1);
    try testing.expectError(error.Corrupted, store.readNextEid(txn));
    try store.sysPutInt(txn, "eid", 6, 5);
    try testing.expectError(error.Corrupted, store.readNextEid(txn));
    try store.sysPutInt(txn, "aid", 4, 0);
    try testing.expectError(error.Corrupted, store.readNextAid(txn));
}

test "reopening a complete store writes nothing, so a read-only file opens" {
    var td = try TestDir.init("store_open_read");
    defer td.deinit();
    const committed = blk: {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        const txn = try store.beginRead();
        defer txn.abort();
        break :blk txn.txnId;
    };
    {
        const store = try Store.open(testing.allocator, td.path.ptr, .{});
        defer store.close();
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(committed, txn.txnId);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(td.path.ptr, 0o444));
    defer _ = std.c.chmod(td.path.ptr, 0o644);
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(u64, 1), try store.readT(txn));
    }
    try testing.expectError(error.TxnReadOnly, store.beginWrite(.none));
}

test "a second store on the same file refuses to write while the first does" {
    var td = try TestDir.init("store_same_file");
    defer td.deinit();
    const a = try Store.open(testing.allocator, td.path.ptr, .{});
    defer a.close();
    const b = try Store.open(testing.allocator, td.path.ptr, .{});
    defer b.close();
    // One environment, checked before a second write begins: on two,
    // emdb's writer lock would wait for `a`, which this thread holds.
    try testing.expect(a.file == b.file);
    const txn = try a.beginWrite(.none);
    try testing.expectError(error.WriterActive, b.beginWrite(.none));
    txn.abort();
    const again = try b.beginWrite(.none);
    again.abort();
}

test "a db/* connection and a store of one file share one writer" {
    var td = try TestDir.init("store_db_layer");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    const file = try db_layer.StoreFile.acquire(td.path.ptr, .{ .allocator = testing.allocator });
    defer file.release();
    try testing.expect(file == store.file);
    const kv = try file.beginWrite(.{});
    try testing.expectError(error.WriterActive, store.beginWrite(.none));
    kv.abort();
    const txn = try store.beginWrite(.none);
    try testing.expectError(error.WriterActive, file.beginWrite(.{}));
    txn.abort();
}

test "a copy of a store file is another file: its uuid is shared, its writer is not" {
    var td = try TestDir.init("store_copied");
    defer td.deinit();
    const a = try Store.open(testing.allocator, td.path.ptr, .{});
    defer a.close();
    const copy = try testing.allocator.printSentinel("{s}/copy.emdb", .{std.Io.Dir.path.dirname(td.path).?}, 0);
    defer testing.allocator.free(copy);
    try std.Io.Dir.cwd().copyFile(td.path, std.Io.Dir.cwd(), copy, testing.io, .{});
    const b = try Store.open(testing.allocator, copy.ptr, .{});
    defer b.close();
    try testing.expectEqualSlices(u8, &a.uuid, &b.uuid);
    try testing.expect(a.file != b.file);
    const ta = try a.beginWrite(.none);
    defer ta.abort();
    const tb = try b.beginWrite(.none);
    tb.abort();
}

test "a merged scan orders facts by their bytes, each fact's history before its current row" {
    var td = try TestDir.init("store_merged");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Facts that prefix one another: "a", "a\x00", "a\x00b", a 64-byte
    // inline string and its out-of-line sibling, each with rows in
    // the current tree, the history tree or both.
    const e: u64 = 1 << 33;
    const inline64 = &@as([key.prefix_len]u8, @splat('x'));
    const long = inline64 ++ "and more, past the inline limit of ninety-six bytes, so out of line";
    const Row = struct { v: []const u8, t: u64, added: bool, current: bool };
    const rows = [_]Row{
        .{ .v = "a", .t = 2, .added = true, .current = false },
        .{ .v = "a", .t = 3, .added = false, .current = false },
        .{ .v = "a", .t = 5, .added = true, .current = true },
        .{ .v = "a\x00", .t = 2, .added = true, .current = false },
        .{ .v = "a\x00", .t = 6, .added = false, .current = false },
        .{ .v = "a\x00b", .t = 4, .added = true, .current = true },
        .{ .v = inline64, .t = 7, .added = true, .current = true },
        .{ .v = long, .t = 3, .added = true, .current = false },
        .{ .v = long, .t = 8, .added = false, .current = false },
        .{ .v = long, .t = 9, .added = true, .current = true },
        .{ .v = "z", .t = 2, .added = true, .current = false },
        .{ .v = "z", .t = 2, .added = true, .current = true },
    };
    {
        const txn = try store.beginWrite(.none);
        errdefer txn.abort();
        for (rows) |r| {
            const vb = try key.valBytes(arena, .{ .string = r.v });
            inline for (.{ Index.eavt, Index.avet }) |ix| {
                if (r.current) {
                    var tb: [key.id_len]u8 = undefined;
                    key.writeId(&tb, r.t);
                    try txn.putInTree(store.trees.cur(ix), try key.keyBytes(arena, ix, e, 100, vb, null), &tb);
                } else {
                    try txn.putInTree(store.trees.hist(ix), try key.keyBytes(arena, ix, e, 100, vb, .{ .t = r.t, .added = r.added }), &.{});
                }
            }
        }
        try txn.commit();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    inline for (.{ Index.eavt, Index.avet }) |ix| {
        const prefix = try key.prefixBytes(arena, ix, if (ix == .eavt) .{ .e = e } else .{ .a = 100 });
        const end = try key.successor(arena, prefix);
        var m = try Store.mergedScan(txn, store.trees, ix, prefix, end);
        // Every row but "z"'s current one, which repeats its last
        // history row, in the order `rows` lists them.
        for (rows[0 .. rows.len - 1]) |want| {
            const got = (try m.next()) orelse return error.TestUnexpectedResult;
            const parts = try key.unpackKey(ix, false, got.fact);
            try testing.expectEqualSlices(u8, try key.valBytes(arena, .{ .string = want.v }), parts.v);
            try testing.expectEqual(want.t, got.t);
            try testing.expectEqual(want.added, got.added);
            try testing.expectEqual(want.current, got.current);
        }
        try testing.expect((try m.next()) == null);
        // As of 6: "a" (asserted again at 5) and the out-of-line
        // value (asserted at 3) and "z"; "a\x00" went at 6, and "a\x00b"
        // came at 4.
        var f = try Store.foldScan(txn, store.trees, ix, prefix, end, .{ .as_of = 6 });
        var n: usize = 0;
        while (try f.next()) |r| : (n += 1) try testing.expect(r.added and r.t <= 6);
        try testing.expectEqual(@as(usize, 4), n);
    }
}
