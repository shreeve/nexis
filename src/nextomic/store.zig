//! store.zig — Env ownership, the twelve trees, sys counters, bootstrap
//! and the raw datom write / scan primitives (NEXTOMIC.md §2).
//!
//! Invariants:
//!   - The environment is opened with the geometry every nexis store
//!     shares (`db.page_size`, `db.max_named_trees`); the page size is
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
//!   - Current-tree values are `[t:6]`, plus the payload in `nx/eavt`
//!     for out-of-line values; history-tree values are empty, plus the
//!     payload in `nx/eavt-h`.
//!   - A value spanning several pages, from a cursor or `getFromTree`,
//!     is assembled in the transaction's buffer and valid until the
//!     next such read; callers copy what they keep.

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

pub const format_version: u16 = 1;

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
        return self.current[@intFromEnum(index)];
    }

    pub inline fn hist(self: Trees, index: Index) TreeId {
        return self.history[@intFromEnum(index)];
    }
};

pub const SyncMode = enum {
    full,
    no_meta,
    none,

    fn override(self: SyncMode) emdb.SyncOverride {
        return switch (self) {
            .full => .full,
            .no_meta => .noMeta,
            .none => .none,
        };
    }
};

pub const Options = struct {
    map_size: u64 = 256 * 1024 * 1024,
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
pub const fulltext_fold: u8 = 2;

pub const FulltextStamp = struct { fold: u8, t: u64 };

pub const Store = struct {
    allocator: Allocator,
    /// The file's one environment in this process, shared with every
    /// other store and `db/*` connection of it (`db.StoreFile`).
    file: *db_layer.StoreFile,
    trees: Trees,
    uuid: [16]u8,
    is_open: bool,
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
            .file = try db_layer.StoreFile.acquire(path, .{
                .pageSize = db_layer.page_size,
                .maxNamedTrees = db_layer.max_named_trees,
                .mapSize = options.map_size,
                .allocator = allocator,
            }),
            .trees = undefined,
            .uuid = @splat(0),
            .is_open = false,
            .fulltext_aid = boot.fulltext,
        };
        errdefer self.file.release();

        if (!try self.openComplete()) {
            const txn = try self.file.beginWrite(.{});
            errdefer txn.abort();
            try self.openTrees(txn);
            if (try self.sysGet(txn, "format")) |_| {
                try self.readHeader(txn);
                try self.ensureFulltextAttr(txn);
            } else {
                try self.bootstrap(txn, options.fulltext_attr);
            }
            try txn.commit();
        }
        self.is_open = true;
        return self;
    }

    /// Release the file and free the store. Called once; the
    /// connection owns the store.
    pub fn close(self: *Store) void {
        if (self.is_open) {
            self.file.release();
            self.is_open = false;
        }
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
        if (fmt.len != 2 or std.mem.readInt(u16, fmt[0..2], .big) != format_version) return error.Format;
        const uuid = (try self.sysGet(txn, "uuid")) orelse return error.Corrupted;
        if (uuid.len != 16) return error.Corrupted;
        self.uuid = uuid[0..16].*;
    }

    // ── Transactions ──────────────────────────────────────────────

    /// Begin a read transaction with all twelve trees loaded.
    pub fn beginRead(self: *Store) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try self.file.env.beginRead();
        errdefer txn.abort();
        try self.loadTrees(txn);
        return txn;
    }

    /// Begin a read-only child of the open write transaction `parent`,
    /// seeing its uncommitted state, with all twelve trees loaded. The
    /// parent refuses mutations and commit until the child is finished.
    pub fn beginReadChild(self: *Store, parent: *Txn) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try parent.beginReadChild();
        errdefer txn.abort();
        try self.loadTrees(txn);
        return txn;
    }

    /// Begin the write transaction with all twelve trees loaded:
    /// `error.WriterActive` while any store or `db/*` connection of the
    /// file holds it (`db.StoreFile.beginWrite`).
    pub fn beginWrite(self: *Store, sync_mode: SyncMode) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try self.file.beginWrite(.{ .sync = sync_mode.override() });
        errdefer txn.abort();
        try self.loadTrees(txn);
        return txn;
    }

    /// A `TreeId` is registered once per environment, but each
    /// transaction loads its own view of a tree on `openTree`; the ids
    /// never change after the first open.
    fn loadTrees(self: *Store, txn: *Txn) !void {
        for (tree_names, 0..) |name, i| {
            const id = try txn.openTree(name, false);
            const expected = switch (i) {
                0...3 => self.trees.current[i],
                4...7 => self.trees.history[i - 4],
                8 => self.trees.txlog,
                9 => self.trees.idents,
                10 => self.trees.sys,
                else => self.trees.fulltext,
            };
            if (id != expected) return error.Corrupted;
        }
    }

    /// Make every commit so far durable (after `.none` loads).
    pub fn sync(self: *Store) !void {
        if (!self.is_open) return error.Closed;
        try self.file.env.sync();
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
        return std.mem.readInt(std.meta.Int(.unsigned, width * 8), raw[0..width], .big);
    }

    fn sysPutInt(self: *Store, txn: *Txn, name: []const u8, comptime width: usize, n: u64) !void {
        var buf: [width]u8 = undefined;
        std.mem.writeInt(std.meta.Int(.unsigned, width * 8), &buf, @intCast(n), .big);
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
        return std.mem.readInt(u64, raw[0..8], .big);
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
    /// and the `t` they are current at; null when absent (rows an older
    /// build wrote, folding ASCII only).
    pub fn readFulltextStamp(self: *Store, txn: *Txn) !?FulltextStamp {
        const raw = (try self.sysGet(txn, "ft")) orelse return null;
        if (raw.len != 1 + key.id_len) return error.Corrupted;
        return .{ .fold = raw[0], .t = try key.readId(raw[1..][0..key.id_len]) };
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
    /// trees: EAVT in key order, then AEVT, then AVET and VAET, each in
    /// its own key order. Scratch lives in `arena`.
    pub fn writeBatch(self: *Store, txn: *Txn, t: u64, batch: []const Prepared, arena: Allocator) !void {
        if (batch.len == 0) return;
        // The keys of one index, packed end to end and reused for the
        // next; an index a datom is absent from gets an empty key.
        var total: usize = 0;
        for (batch) |p| total += key.id_len + key.attr_len + p.vbytes.len;
        var keys: std.ArrayList(u8) = .empty;
        try keys.ensureTotalCapacityPrecise(arena, total);
        const offsets = try arena.alloc(u32, batch.len + 1);
        const order = try arena.alloc(usize, batch.len);
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
            std.mem.sort(usize, order, packed_keys, PackedKeys.less);
            for (order) |i| {
                const k = packed_keys.at(i);
                if (k.len == 0) continue;
                try self.writeOne(txn, index, t, batch[i], k, arena);
            }
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

    fn writeOne(self: *Store, txn: *Txn, index: Index, t: u64, p: Prepared, cur_key: []const u8, arena: Allocator) !void {
        var hist_buf: [key.max_key_len]u8 = undefined;
        const hist_key = hist_buf[0 .. cur_key.len + key.top_len];
        @memcpy(hist_key[0..cur_key.len], cur_key);
        key.writeTop(hist_key[cur_key.len..][0..key.top_len], t, p.added);
        const payload: []const u8 = if (index == .eavt) (p.payload orelse &.{}) else &.{};

        if (p.added) {
            var tb: [key.id_len]u8 = undefined;
            key.writeId(&tb, t);
            const val = if (payload.len == 0) &tb else blk: {
                const buf = try arena.alloc(u8, key.id_len + payload.len);
                @memcpy(buf[0..key.id_len], &tb);
                @memcpy(buf[key.id_len..], payload);
                break :blk buf;
            };
            try txn.putInTree(self.trees.cur(index), cur_key, val);
        } else {
            _ = try txn.delFromTree(self.trees.cur(index), cur_key);
        }
        try txn.putInTree(self.trees.hist(index), hist_key, payload);
    }

    /// The current-tree value of `(e a v)` in `index`, or null.
    pub fn getCurrent(self: *Store, txn: *Txn, index: Index, e: u64, a: u32, vbytes: []const u8, arena: Allocator) !?[]const u8 {
        const k = try key.keyBytes(arena, index, e, a, vbytes, null);
        return txn.getFromTree(self.trees.cur(index), k);
    }

    /// The out-of-line payload of the current datom `(e a v)`: the bytes
    /// after the `t` header of its EAVT value, copied into `arena`.
    /// Null when there is no such datom.
    pub fn currentPayload(self: *Store, txn: *Txn, e: u64, a: u32, vbytes: []const u8, arena: Allocator) !?[]const u8 {
        const raw = (try self.getCurrent(txn, .eavt, e, a, vbytes, arena)) orelse return null;
        if (raw.len < key.id_len) return error.Corrupted;
        return try arena.dupe(u8, raw[key.id_len..]);
    }

    /// The history-tree value of `(e a v top)` in `index`, or null.
    pub fn getHistory(self: *Store, txn: *Txn, index: Index, e: u64, a: u32, vbytes: []const u8, top: key.Top, arena: Allocator) !?[]const u8 {
        const k = try key.keyBytes(arena, index, e, a, vbytes, top);
        return txn.getFromTree(self.trees.hist(index), k);
    }

    // ── scans ─────────────────────────────────────────────────────

    pub const KeyValue = emdb.Cursor.KeyValue;

    /// Forward scan of one tree: the keys starting with a prefix (every
    /// key when it is empty), or the keys in `[start, end)` (an absent
    /// `end` runs to the tree's last key). Keys and values borrow the
    /// transaction's snapshot, a multi-page value only until the next
    /// multi-page read.
    pub const Scan = struct {
        cursor: emdb.Cursor,
        start: []const u8,
        stop: union(enum) { prefix: []const u8, end: ?[]const u8 },
        started: bool = false,
        done: bool = false,

        pub fn next(self: *Scan) ?KeyValue {
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
            }
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

    /// A history row: the key without `top`, its value, `t` and
    /// `added`. Slices borrow the transaction's snapshot.
    pub const HistoryRow = struct {
        fact: []const u8,
        value: []const u8,
        t: u64,
        added: bool,
    };

    /// The §4 fold over a history tree: rows in `[start, end)` grouped
    /// by their fact bytes (everything before `top`); consecutive rows
    /// of one fact ascend in `t`; the last row inside the window wins
    /// and is emitted iff it is an assertion. `.all` emits every row in
    /// the window unfolded.
    pub const FoldScan = struct {
        inner: Scan,
        window: Window,
        pending: ?HistoryRow = null,
        exhausted: bool = false,

        pub fn next(self: *FoldScan) key.DecodeError!?HistoryRow {
            while (!self.exhausted) {
                const row = self.inner.next() orelse {
                    self.exhausted = true;
                    break;
                };
                if (row.key.len < key.top_len) continue;
                const fact_len = row.key.len - key.top_len;
                const top = try key.readTop(row.key[fact_len..][0..key.top_len]);
                if (!self.window.contains(top.t)) continue;
                const r: HistoryRow = .{ .fact = row.key[0..fact_len], .value = row.value, .t = top.t, .added = top.added };
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

    pub fn foldScan(txn: *Txn, tree: TreeId, start: []const u8, end: ?[]const u8, window: Window) !FoldScan {
        return .{ .inner = try scanRange(txn, tree, start, end), .window = window };
    }

    /// Number of entries in `tree` at the transaction's snapshot.
    pub fn treeEntries(txn: *Txn, tree: TreeId) !u64 {
        return (try txn.treeStat(tree)).entries;
    }

    // ── bootstrap (§2.4) ──────────────────────────────────────────

    fn bootstrap(self: *Store, txn: *Txn, with_fulltext: bool) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var fmt: [2]u8 = undefined;
        std.mem.writeInt(u16, &fmt, format_version, .big);
        try self.sysPut(txn, "format", &fmt);
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
        const path = try std.fmt.allocPrintSentinel(testing.allocator, ".zig-cache/tmp/{s}/{s}.emdb", .{ tmp.sub_path, name }, 0);
        return .{ .tmp = tmp, .path = path };
    }

    pub fn deinit(self: *TestDir) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

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
        while (s.next()) |_| n += 1;
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
    while (s.next()) |kv| : (n += 1) {
        try testing.expectEqual(@as(usize, key.id_len), kv.value.len);
        try testing.expectEqual(@as(u64, 1), try key.readId(kv.value[0..key.id_len]));
    }
    try testing.expectEqual(@as(usize, 5), n);

    // AVET [:db/ident] holds every ident; [:db/valueType] is not indexed.
    const pa = try key.prefixBytes(arena, .avet, .{ .a = boot.ident });
    var sa = try Store.scan(txn, store.trees.cur(.avet), pa);
    n = 0;
    while (sa.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, boot.idents.len), n);
    const pv = try key.prefixBytes(arena, .avet, .{ .a = boot.value_type });
    var sv = try Store.scan(txn, store.trees.cur(.avet), pv);
    try testing.expect(sv.next() == null);

    // History mirrors current with top = (1 << 1) | 1.
    const ph = try key.prefixBytes(arena, .eavt, .{ .e = boot.ident });
    var sh = try Store.scan(txn, store.trees.hist(.eavt), ph);
    n = 0;
    while (sh.next()) |kv| : (n += 1) {
        const parts = try key.unpackKey(.eavt, true, kv.key);
        try testing.expectEqual(@as(u64, 1), parts.top.?.t);
        try testing.expect(parts.top.?.added);
        try testing.expectEqual(@as(usize, 0), kv.value.len);
    }
    try testing.expectEqual(@as(usize, 5), n);

    // Empty prefix walks the whole tree.
    var all = try Store.scan(txn, store.trees.cur(.aevt), &.{});
    n = 0;
    while (all.next()) |_| n += 1;
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
    const tree = store.trees.hist(.eavt);

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
        var fs = try Store.foldScan(txn, tree, prefix, end, c.window);
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
    var all = try Store.foldScan(txn, tree, prefix, end, .{ .all = .{ .after = 0, .upto = 5 } });
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
    const only = cur.next().?;
    try testing.expectEqual(@as(u32, 101), (try key.unpackKey(.eavt, false, only.key)).a);
    try testing.expect(cur.next() == null);
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
    const long_name = "ns/" ++ ("x" ** 400);
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
    const file = try db_layer.StoreFile.acquire(td.path.ptr, .{ .pageSize = db_layer.page_size, .allocator = testing.allocator });
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
    const copy = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/copy.emdb", .{std.fs.path.dirname(td.path).?}, 0);
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
