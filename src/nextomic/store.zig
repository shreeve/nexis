//! store.zig — Env ownership, the eleven trees, sys counters, bootstrap
//! and the raw datom write / scan primitives (NEXTOMIC.md §2).
//!
//! Invariants:
//!   - The environment is opened with `pageSize = 16384` and
//!     `maxNamedTrees = 128`; the page size is fixed for the file's life.
//!   - All eleven trees are opened in one write transaction at open and
//!     their `TreeId`s are cached for the store's life (tree registration
//!     is the only non-thread-safe engine call).
//!   - `sys["t"]` is the last committed logical transaction number and
//!     commits atomically with the datoms it counts.
//!   - Bootstrap ids are fixed (`boot`): a store created by any build has
//!     `:db/ident` at 1 and `:db.unique/value` at 21, and a reopened store
//!     reads the same ids back from the file.
//!   - Current-tree values are `[t:6]`, plus the payload in `nx/eavt`
//!     for out-of-line values; history-tree values are empty, plus the
//!     payload in `nx/eavt-h`.
//!   - Values read off a cursor are clamped to one page; a payload is
//!     always read with `getFromTree` on its exact key.

const std = @import("std");
const builtin = @import("builtin");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");

const Allocator = std.mem.Allocator;
const Txn = emdb.Txn;
const TreeId = emdb.TreeId;
const Index = key.Index;
const Datom = datom_mod.Datom;

pub const page_size: u32 = 16384;
pub const format_version: u16 = 1;

// =============================================================================
// Trees
// =============================================================================

pub const tree_names = [_][]const u8{
    "nx/eavt",   "nx/aevt",   "nx/avet",   "nx/vaet",
    "nx/eavt-h", "nx/aevt-h", "nx/avet-h", "nx/vaet-h",
    "nx/txlog",  "nx/idents", "nx/sys",
};

pub const Trees = struct {
    current: [4]TreeId,
    history: [4]TreeId,
    txlog: TreeId,
    idents: TreeId,
    sys: TreeId,

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
    read_only: bool = false,
};

pub const StoreError = error{
    /// The file's Nextomic format number is not `format_version`.
    Format,
    /// A sys entry or key has an impossible shape.
    Corrupted,
    /// The store is closed.
    Closed,
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
    /// First id minted after bootstrap.
    pub const next_aid: u32 = 22;
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
    };

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
    };

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

    pub fn typeIdentOf(vt: key.ValueType) u32 {
        return switch (vt) {
            .long => type_long,
            .double => type_double,
            .instant => type_instant,
            .keyword => type_keyword,
            .ref => type_ref,
            .string => type_string,
            .uuid => type_uuid,
            .bytes => type_bytes,
            .boolean => type_boolean,
        };
    }
};

// =============================================================================
// Store
// =============================================================================

pub const Store = struct {
    allocator: Allocator,
    env: emdb.Env,
    trees: Trees,
    uuid: [16]u8,
    is_open: bool,

    /// Open or create the store at `path`. The store is heap-allocated
    /// so the environment never moves while transactions reference it.
    pub fn open(allocator: Allocator, path: [*:0]const u8, options: Options) !*Store {
        const self = try allocator.create(Store);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .env = undefined,
            .trees = undefined,
            .uuid = undefined,
            .is_open = false,
        };
        self.env = try emdb.Env.open(path, .{
            .pageSize = page_size,
            .maxNamedTrees = 128,
            .mapSize = options.map_size,
            .readOnly = options.read_only,
            .allocator = allocator,
        });
        errdefer self.env.close();

        if (options.read_only) {
            const txn = try self.env.beginRead();
            defer txn.abort();
            try self.openTrees(txn, false);
            try self.readHeader(txn);
        } else {
            const txn = try self.env.beginWrite();
            errdefer txn.abort();
            try self.openTrees(txn, true);
            if (try self.sysGet(txn, "format")) |_| {
                try self.readHeader(txn);
            } else {
                try self.bootstrap(txn);
            }
            try txn.commit();
        }
        self.is_open = true;
        return self;
    }

    /// Close and free the store. Idempotent.
    pub fn close(self: *Store) void {
        if (self.is_open) {
            self.env.close();
            self.is_open = false;
        }
        self.allocator.destroy(self);
    }

    fn openTrees(self: *Store, txn: *Txn, create: bool) !void {
        var ids: [tree_names.len]TreeId = undefined;
        for (tree_names, 0..) |name, i| {
            ids[i] = try txn.openTree(name, create);
        }
        self.trees = .{
            .current = ids[0..4].*,
            .history = ids[4..8].*,
            .txlog = ids[8],
            .idents = ids[9],
            .sys = ids[10],
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

    /// Begin a read transaction with all eleven trees loaded.
    pub fn beginRead(self: *Store) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try self.env.beginRead();
        errdefer txn.abort();
        try self.loadTrees(txn);
        return txn;
    }

    /// Begin a read-only child of the open write transaction `parent`,
    /// seeing its uncommitted state, with all eleven trees loaded. The
    /// parent refuses mutations and commit until the child is finished.
    pub fn beginReadChild(self: *Store, parent: *Txn) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try parent.beginReadChild();
        errdefer txn.abort();
        try self.loadTrees(txn);
        return txn;
    }

    /// Begin the write transaction with all eleven trees loaded.
    pub fn beginWrite(self: *Store, sync_mode: SyncMode) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try self.env.beginWriteWith(.{ .sync = sync_mode.override() });
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
                else => self.trees.sys,
            };
            if (id != expected) return error.Corrupted;
        }
    }

    /// Make every commit so far durable (after `.none` loads).
    pub fn sync(self: *Store) !void {
        if (!self.is_open) return error.Closed;
        try self.env.sync();
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
        return self.sysGetInt(txn, "t", 6);
    }

    pub fn writeT(self: *Store, txn: *Txn, t: u64) !void {
        try self.sysPutInt(txn, "t", 6, t);
    }

    /// Next user entity id.
    pub fn readNextEid(self: *Store, txn: *Txn) !u64 {
        return self.sysGetInt(txn, "eid", 6);
    }

    pub fn writeNextEid(self: *Store, txn: *Txn, eid: u64) !void {
        try self.sysPutInt(txn, "eid", 6, eid);
    }

    /// Next attribute / ident id.
    pub fn readNextAid(self: *Store, txn: *Txn) !u32 {
        return @intCast(try self.sysGetInt(txn, "aid", 4));
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
        var buf: [256]u8 = undefined;
        const k = try identNameKey(&buf, self.allocator, name);
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
        const k = try identNameKey(&buf, self.allocator, name);
        defer if (k.len > buf.len) self.allocator.free(k);
        var idb: [key.attr_len]u8 = undefined;
        key.writeAttr(&idb, id);
        try txn.putInTree(self.trees.idents, k, &idb);
        var rk: [1 + key.attr_len]u8 = undefined;
        rk[0] = 0x01;
        key.writeAttr(rk[1..], id);
        try txn.putInTree(self.trees.idents, &rk, name);
    }

    fn identNameKey(buf: []u8, gpa: Allocator, name: []const u8) ![]u8 {
        const k = if (name.len + 1 <= buf.len) buf[0 .. name.len + 1] else try gpa.alloc(u8, name.len + 1);
        k[0] = 0x00;
        @memcpy(k[1..], name);
        return k;
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
        const order = try arena.alloc(usize, batch.len);
        for (order, 0..) |*o, i| o.* = i;
        inline for (.{ Index.eavt, Index.aevt, Index.avet, Index.vaet }) |index| {
            const keys = try arena.alloc([]const u8, batch.len);
            for (batch, 0..) |p, i| {
                keys[i] = if (index == .avet and !p.avet or index == .vaet and !p.vaet)
                    &.{}
                else
                    try key.keyBytes(arena, index, p.e, p.a, p.vbytes, null);
            }
            std.mem.sort(usize, order, keys, lessByKey);
            for (order) |i| {
                const p = batch[i];
                const k = keys[i];
                if (k.len == 0) continue;
                try self.writeOne(txn, index, t, p, k, arena);
            }
        }
    }

    fn lessByKey(keys: []const []const u8, a: usize, b: usize) bool {
        return std.mem.order(u8, keys[a], keys[b]) == .lt;
    }

    fn writeOne(self: *Store, txn: *Txn, index: Index, t: u64, p: Prepared, cur_key: []const u8, arena: Allocator) !void {
        const hist_key = try arena.alloc(u8, cur_key.len + key.top_len);
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

    /// The history-tree value of `(e a v top)` in `index`, or null.
    pub fn getHistory(self: *Store, txn: *Txn, index: Index, e: u64, a: u32, vbytes: []const u8, top: key.Top, arena: Allocator) !?[]const u8 {
        const k = try key.keyBytes(arena, index, e, a, vbytes, top);
        return txn.getFromTree(self.trees.hist(index), k);
    }

    // ── scans ─────────────────────────────────────────────────────

    pub const KeyValue = emdb.Cursor.KeyValue;

    /// Forward scan of one tree over the keys starting with `prefix`
    /// (every key when the prefix is empty). Keys and values borrow the
    /// transaction's snapshot; cursor values are clamped to one page.
    pub const Scan = struct {
        cursor: emdb.Cursor,
        prefix: []const u8,
        started: bool = false,
        done: bool = false,

        pub fn next(self: *Scan) ?KeyValue {
            if (self.done) return null;
            const kv = if (!self.started) blk: {
                self.started = true;
                break :blk if (self.prefix.len == 0) self.cursor.first() else self.cursor.setRange(self.prefix);
            } else self.cursor.next();
            if (kv) |e| {
                if (key.hasPrefix(e.key, self.prefix)) return e;
            }
            self.done = true;
            return null;
        }
    };

    pub fn scan(self: *Store, txn: *Txn, tree: TreeId, prefix: []const u8) !Scan {
        _ = self;
        return .{ .cursor = try txn.openCursorForTree(tree), .prefix = prefix };
    }

    /// Forward scan over `[start, end)`; an absent `end` runs to the
    /// tree's last key.
    pub const RangeScan = struct {
        cursor: emdb.Cursor,
        start: []const u8,
        end: ?[]const u8,
        started: bool = false,
        done: bool = false,

        pub fn next(self: *RangeScan) ?KeyValue {
            if (self.done) return null;
            const kv = if (!self.started) blk: {
                self.started = true;
                break :blk if (self.start.len == 0) self.cursor.first() else self.cursor.setRange(self.start);
            } else self.cursor.next();
            if (kv) |e| {
                const below_end = if (self.end) |end| std.mem.order(u8, e.key, end) == .lt else true;
                if (below_end) return e;
            }
            self.done = true;
            return null;
        }
    };

    pub fn scanRange(self: *Store, txn: *Txn, tree: TreeId, start: []const u8, end: ?[]const u8) !RangeScan {
        _ = self;
        return .{ .cursor = try txn.openCursorForTree(tree), .start = start, .end = end };
    }

    /// Which history rows a fold sees (NEXTOMIC.md §4).
    pub const Window = union(enum) {
        /// `t <= T`: fold, emit current facts as of `T`.
        as_of: u64,
        /// `after < t <= upto`: fold from an empty state.
        since: struct { after: u64, upto: u64 },
        /// `t <= upto`: every row, no fold.
        all: u64,

        pub fn contains(self: Window, t: u64) bool {
            return switch (self) {
                .as_of => |upto| t <= upto,
                .since => |w| t > w.after and t <= w.upto,
                .all => |upto| t <= upto,
            };
        }
    };

    /// A history row: the key without `top`, its clamped value, `t` and
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
        inner: RangeScan,
        window: Window,
        pending: ?HistoryRow = null,
        exhausted: bool = false,

        pub fn next(self: *FoldScan) ?HistoryRow {
            while (!self.exhausted) {
                const row = self.inner.next() orelse {
                    self.exhausted = true;
                    break;
                };
                if (row.key.len < key.top_len) continue;
                const fact_len = row.key.len - key.top_len;
                const top = key.readTop(row.key[fact_len..][0..key.top_len]);
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

    pub fn foldScan(self: *Store, txn: *Txn, tree: TreeId, start: []const u8, end: ?[]const u8, window: Window) !FoldScan {
        return .{ .inner = try self.scanRange(txn, tree, start, end), .window = window };
    }

    /// Number of entries in `tree` at the transaction's snapshot.
    pub fn treeEntries(self: *Store, txn: *Txn, tree: TreeId) !u64 {
        _ = self;
        return (try txn.treeStat(tree)).entries;
    }

    // ── bootstrap (§2.4) ──────────────────────────────────────────

    fn bootstrap(self: *Store, txn: *Txn) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var fmt: [2]u8 = undefined;
        std.mem.writeInt(u16, &fmt, format_version, .big);
        try self.sysPut(txn, "format", &fmt);
        fillRandom(&self.uuid);
        try self.sysPut(txn, "uuid", &self.uuid);

        for (boot.idents) |id| try self.putIdent(txn, id.name, id.id);

        var datoms: std.ArrayList(Datom) = .empty;
        const now = nowMillis();
        for (boot.attrs) |a| {
            try datoms.append(arena, .{ .e = a.id, .a = boot.ident, .v = .{ .keyword = a.id }, .t = boot.t, .added = true });
            try datoms.append(arena, .{ .e = a.id, .a = boot.value_type, .v = .{ .keyword = a.type_ident }, .t = boot.t, .added = true });
            try datoms.append(arena, .{ .e = a.id, .a = boot.cardinality, .v = .{ .keyword = if (a.many) boot.card_many else boot.card_one }, .t = boot.t, .added = true });
            if (a.unique_ident) |u| try datoms.append(arena, .{ .e = a.id, .a = boot.unique, .v = .{ .keyword = u }, .t = boot.t, .added = true });
            if (a.indexed) try datoms.append(arena, .{ .e = a.id, .a = boot.index, .v = .{ .boolean = true }, .t = boot.t, .added = true });
        }
        for (boot.idents[boot.attrs.len..]) |id| {
            try datoms.append(arena, .{ .e = id.id, .a = boot.ident, .v = .{ .keyword = id.id }, .t = boot.t, .added = true });
        }
        try datoms.append(arena, .{ .e = key.txEntity(boot.t), .a = boot.tx_instant, .v = .{ .instant = now }, .t = boot.t, .added = true });

        const batch = try arena.alloc(Prepared, datoms.items.len);
        for (datoms.items, 0..) |d, i| {
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
        try self.writeBatch(txn, boot.t, batch, arena);

        var counts = std.AutoHashMapUnmanaged(u32, u64).empty;
        for (datoms.items) |d| {
            const g = try counts.getOrPut(arena, d.a);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
        var it = counts.iterator();
        while (it.next()) |e| try self.writeAttrCount(txn, e.key_ptr.*, e.value_ptr.*);

        const names: datom_mod.NameSource = .{ .ctx = @ptrCast(self), .identName = &bootIdentName };
        const entry = try datom_mod.encodeTxlog(arena, now, datoms.items, names);
        try self.putTxlog(txn, boot.t, entry);

        try self.writeT(txn, boot.t);
        try self.writeNextEid(txn, key.user_partition_start);
        try self.writeNextAid(txn, boot.next_aid);
    }

    fn bootIdentName(_: *anyopaque, id: u32) anyerror!?[]const u8 {
        for (boot.idents) |i| {
            if (i.id == id) return i.name;
        }
        return null;
    }
};

// =============================================================================
// Clock and entropy
// =============================================================================

/// Wall-clock milliseconds since the Unix epoch.
pub fn nowMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn fillRandom(buf: []u8) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            std.c.arc4random_buf(buf.ptr, buf.len);
        },
        .linux => {
            var off: usize = 0;
            while (off < buf.len) {
                const rc = std.os.linux.getrandom(buf.ptr + off, buf.len - off, 0);
                if (std.os.linux.E.init(rc) != .SUCCESS) break;
                off += rc;
            }
            if (off < buf.len) mixClockEntropy(buf);
        },
        else => mixClockEntropy(buf),
    }
}

fn mixClockEntropy(buf: []u8) void {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    var mono: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &mono);
    var seed: [32]u8 = undefined;
    std.mem.writeInt(i64, seed[0..8], @intCast(ts.sec), .little);
    std.mem.writeInt(i64, seed[8..16], @intCast(ts.nsec), .little);
    std.mem.writeInt(i64, seed[16..24], @intCast(mono.nsec), .little);
    std.mem.writeInt(u64, seed[24..32], @intFromPtr(buf.ptr), .little);
    var i: usize = 0;
    var counter: u64 = 0;
    while (i < buf.len) : (counter += 1) {
        const h = std.hash.XxHash3.hash(counter, &seed);
        var hb: [8]u8 = undefined;
        std.mem.writeInt(u64, &hb, h, .little);
        const n = @min(8, buf.len - i);
        @memcpy(buf[i .. i + n], hb[0..n]);
        i += n;
    }
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
    var s = try store.scan(txn, store.trees.cur(.eavt), p);
    var n: usize = 0;
    while (s.next()) |kv| : (n += 1) {
        try testing.expectEqual(@as(usize, key.id_len), kv.value.len);
        try testing.expectEqual(@as(u64, 1), key.readId(kv.value[0..key.id_len]));
    }
    try testing.expectEqual(@as(usize, 5), n);

    // AVET [:db/ident] holds every ident; [:db/valueType] is not indexed.
    const pa = try key.prefixBytes(arena, .avet, .{ .a = boot.ident });
    var sa = try store.scan(txn, store.trees.cur(.avet), pa);
    n = 0;
    while (sa.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, boot.idents.len), n);
    const pv = try key.prefixBytes(arena, .avet, .{ .a = boot.value_type });
    var sv = try store.scan(txn, store.trees.cur(.avet), pv);
    try testing.expect(sv.next() == null);

    // History mirrors current with top = (1 << 1) | 1.
    const ph = try key.prefixBytes(arena, .eavt, .{ .e = boot.ident });
    var sh = try store.scan(txn, store.trees.hist(.eavt), ph);
    n = 0;
    while (sh.next()) |kv| : (n += 1) {
        const parts = try key.unpackKey(.eavt, true, kv.key);
        try testing.expectEqual(@as(u64, 1), parts.top.?.t);
        try testing.expect(parts.top.?.added);
        try testing.expectEqual(@as(usize, 0), kv.value.len);
    }
    try testing.expectEqual(@as(usize, 5), n);

    // Empty prefix walks the whole tree.
    var all = try store.scan(txn, store.trees.cur(.aevt), &.{});
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
        var fs = try store.foldScan(txn, tree, prefix, end, c.window);
        var got: std.ArrayList(u64) = .empty;
        while (fs.next()) |r| {
            try testing.expect(r.added);
            const parts = try key.unpackKey(.eavt, false, r.fact);
            const kv = try key.decodeVal(arena, parts.v);
            try got.append(arena, @intCast(kv.val.long));
        }
        try testing.expectEqualSlices(u64, c.facts, got.items);
    }
    // History mode sees all five rows in t order with their flags.
    var all = try store.foldScan(txn, tree, prefix, end, .{ .all = 5 });
    var n: usize = 0;
    var adds: usize = 0;
    while (all.next()) |r| {
        n += 1;
        if (r.added) adds += 1;
    }
    try testing.expectEqual(@as(usize, 5), n);
    try testing.expectEqual(@as(usize, 3), adds);
    // Current trees hold only attribute 101 now.
    var cur = try store.scan(txn, store.trees.cur(.eavt), prefix);
    const only = cur.next().?;
    try testing.expectEqual(@as(u32, 101), (try key.unpackKey(.eavt, false, only.key)).a);
    try testing.expect(cur.next() == null);
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
