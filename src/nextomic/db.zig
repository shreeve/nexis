//! db.zig — connections and db-values (NEXTOMIC.md §4).
//!
//! A `Conn` owns the store, the ident cache and the schema cache. A
//! `DbValue` is a plain value `{conn, basis, as_of, since, history}`
//! with no open read transaction: every operation opens one, reads
//! `sys["t"]` as `now`, and closes it. Invariants:
//!   - `now == basis` in current mode reads the current trees with no
//!     fold; any other view folds the history trees (`Store.FoldScan`).
//!   - `now < basis` is `error.BasisInFuture`; the db-value is dead.
//!   - `as-of T` caps the view at `min(basis, T)`; `since T` shows only
//!     facts asserted after `T`; `history` shows every row unfolded, and
//!     composes with `as-of`.
//!   - Out-of-line values are confirmed and materialised from the EAVT
//!     payload before a datom is returned.
//!   - Every operation allocates in the caller's arena; the connection's
//!     allocator holds only the store, the ident cache and the schema.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const string_mod = @import("string");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const idents_mod = @import("idents.zig");
const schema_mod = @import("schema.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const Txn = emdb.Txn;
const Store = store_mod.Store;
const Idents = idents_mod.Idents;
const Schema = schema_mod.Schema;
const Attr = schema_mod.Attr;
const Val = key.Val;
const Index = key.Index;
const Datom = datom_mod.Datom;
const boot = store_mod.boot;

pub const SyncMode = store_mod.SyncMode;

// =============================================================================
// Errors (§7)
// =============================================================================

/// The Nextomic error set; each maps to a `:nextomic/*` keyword.
pub const Error = error{
    UnknownAttribute,
    ValueType,
    Unique,
    Conflict,
    NoEntity,
    BasisInFuture,
    Closed,
    /// Malformed tx-data: `:nextomic/tx-data`.
    TxData,
};

// =============================================================================
// Conn
// =============================================================================

pub const OpenOptions = struct {
    sync: SyncMode = .full,
    map_size: u64 = 256 * 1024 * 1024,
};

pub const Conn = struct {
    gpa: Allocator,
    store: *Store,
    interner: *Interner,
    idents: Idents,
    schema_cache: ?*Schema = null,
    sync_mode: SyncMode,
    is_open: bool,

    /// Open or create the store at `path`; bootstrap on first open.
    /// `interner` is the VM's keyword table and outlives the connection.
    pub fn open(gpa: Allocator, interner: *Interner, path: [*:0]const u8, options: OpenOptions) !*Conn {
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        const store = try Store.open(gpa, path, .{ .map_size = options.map_size });
        errdefer store.close();
        self.* = .{
            .gpa = gpa,
            .store = store,
            .interner = interner,
            .idents = Idents.init(gpa, store, interner),
            .sync_mode = options.sync,
            .is_open = true,
        };
        return self;
    }

    /// Release the store and caches. Idempotent; the `Conn` stays
    /// allocated so db-values that still point at it fail with
    /// `error.Closed` instead of dangling.
    pub fn close(self: *Conn) void {
        if (!self.is_open) return;
        self.dropSchema();
        self.idents.deinit();
        self.store.close();
        self.is_open = false;
    }

    /// Close and free.
    pub fn destroy(self: *Conn) void {
        self.close();
        self.gpa.destroy(self);
    }

    /// A db-value at the current basis.
    pub fn db(self: *Conn) !DbValue {
        if (!self.is_open) return error.Closed;
        const txn = try self.store.beginRead();
        defer txn.abort();
        return .{ .conn = self, .basis = try self.store.readT(txn) };
    }

    /// Make every commit so far durable.
    pub fn sync(self: *Conn) !void {
        if (!self.is_open) return error.Closed;
        try self.store.sync();
    }

    pub fn dropSchema(self: *Conn) void {
        if (self.schema_cache) |s| {
            s.deinit();
            self.schema_cache = null;
        }
    }

    /// The schema serving `basis` inside `txn` (whose `sys["t"]` is
    /// `now`). A cached schema built at a basis `>= basis` serves it
    /// through `attrAt`; otherwise the cache is rebuilt at `now`.
    pub fn schemaAt(self: *Conn, txn: *Txn, basis: u64, now: u64) !*Schema {
        if (self.schema_cache) |s| {
            if (s.basis >= basis) return s;
            s.deinit();
            self.schema_cache = null;
        }
        const s = try Schema.build(self.gpa, self.store, txn, now, now);
        self.schema_cache = s;
        return s;
    }

    /// Materialise a datom value into the VM heap. Refs, longs and
    /// instants become fixnums; keywords are interned into the VM;
    /// uuids become their canonical text; byte arrays become strings.
    pub fn valToValue(self: *Conn, txn: *Txn, heap: *Heap, v: Val) !Value {
        return switch (v) {
            .boolean => |b| value.fromBool(b),
            .long => |n| value.fromFixnum(n) orelse error.ValueType,
            .double => |d| value.fromFloat(d),
            .instant => |n| value.fromFixnum(n) orelse error.ValueType,
            .keyword => |id| blk: {
                const k = (try self.idents.internOf(txn, id)) orelse return error.Corrupted;
                break :blk value.fromKeywordId(k);
            },
            .ref => |eid| value.fromFixnum(@intCast(eid)) orelse error.ValueType,
            .string => |s| try string_mod.fromBytes(heap, s),
            .uuid => |u| blk: {
                var text: [36]u8 = undefined;
                datom_mod.uuidToText(&text, u);
                break :blk try string_mod.fromBytes(heap, &text);
            },
            .bytes => |b| try string_mod.fromBytes(heap, b),
        };
    }
};

// =============================================================================
// DbValue
// =============================================================================

pub const DbValue = struct {
    conn: *Conn,
    /// The `t` this value was taken at.
    basis: u64,
    as_of: ?u64 = null,
    since: ?u64 = null,
    history: bool = false,

    pub fn asOf(self: DbValue, t: u64) DbValue {
        var d = self;
        d.as_of = if (self.as_of) |cur| @min(cur, t) else t;
        return d;
    }

    pub fn sinceT(self: DbValue, t: u64) DbValue {
        var d = self;
        d.since = t;
        return d;
    }

    pub fn withHistory(self: DbValue) DbValue {
        var d = self;
        d.history = true;
        return d;
    }

    /// The newest `t` this view shows.
    pub fn upper(self: DbValue) u64 {
        return if (self.as_of) |t| @min(t, self.basis) else self.basis;
    }

    fn window(self: DbValue) Store.Window {
        const up = self.upper();
        if (self.history) return .{ .all = up };
        if (self.since) |after| return .{ .since = .{ .after = after, .upto = up } };
        return .{ .as_of = up };
    }

    /// Open a read transaction for one operation and check the basis.
    pub fn beginRead(self: DbValue) !Read {
        if (!self.conn.is_open) return error.Closed;
        const txn = try self.conn.store.beginRead();
        errdefer txn.abort();
        const now = try self.conn.store.readT(txn);
        if (now < self.basis) return error.BasisInFuture;
        return .{ .db = self, .txn = txn, .now = now };
    }

    // ── datoms ────────────────────────────────────────────────────

    /// Datoms of `index` under the leading `comps`, folded for this
    /// view, collected into `arena`.
    pub fn datoms(self: DbValue, arena: Allocator, index: Index, comps: key.Components) ![]Datom {
        var rd = try self.beginRead();
        defer rd.close();
        var it = try rd.scan(arena, index, comps);
        var out: std.ArrayList(Datom) = .empty;
        while (try it.next()) |d| try out.append(arena, d);
        return out.toOwnedSlice(arena);
    }

    // ── entity ────────────────────────────────────────────────────

    pub const EntityAttr = struct {
        a: u32,
        vals: []Val,
    };

    /// Every current attribute of `e` with its values, in attribute
    /// order; empty when the entity has no datoms in this view.
    pub fn entity(self: DbValue, arena: Allocator, e: u64) ![]EntityAttr {
        const ds = try self.datoms(arena, .eavt, .{ .e = e });
        var out: std.ArrayList(EntityAttr) = .empty;
        var i: usize = 0;
        while (i < ds.len) {
            const a = ds[i].a;
            var j = i;
            while (j < ds.len and ds[j].a == a) j += 1;
            const vals = try arena.alloc(Val, j - i);
            for (vals, ds[i..j]) |*v, d| v.* = d.v;
            try out.append(arena, .{ .a = a, .vals = vals });
            i = j;
        }
        return out.toOwnedSlice(arena);
    }

    // ── entid / ident ─────────────────────────────────────────────

    pub const EntityRef = union(enum) {
        eid: u64,
        /// VM keyword id of an ident.
        ident: u32,
        /// Lookup ref on a unique attribute.
        lookup: struct { a: u32, v: Val },
    };

    /// Resolve an entity reference in this view, or null.
    pub fn entid(self: DbValue, arena: Allocator, ref: EntityRef) !?u64 {
        var rd = try self.beginRead();
        defer rd.close();
        return rd.entid(arena, ref);
    }

    /// The ident keyword (VM keyword id) of entity `e` in this view.
    pub fn ident(self: DbValue, arena: Allocator, e: u64) !?u32 {
        var rd = try self.beginRead();
        defer rd.close();
        return rd.ident(arena, e);
    }

    /// The attribute `a` as this view sees it.
    pub fn attr(self: DbValue, arena: Allocator, a: u32) !?Attr {
        _ = arena;
        var rd = try self.beginRead();
        defer rd.close();
        return rd.attr(a);
    }
};

// =============================================================================
// Read — one operation's read transaction
// =============================================================================

pub const Read = struct {
    db: DbValue,
    txn: *Txn,
    now: u64,

    pub fn close(self: *Read) void {
        self.txn.abort();
    }

    /// Current-tree fast path: the plain view at the newest basis.
    pub fn fast(self: *const Read) bool {
        const d = self.db;
        return !d.history and d.since == null and d.upper() == d.basis and self.now == d.basis;
    }

    pub fn schema(self: *Read) !*Schema {
        return self.db.conn.schemaAt(self.txn, self.db.upper(), self.now);
    }

    pub fn attr(self: *Read, a: u32) !?Attr {
        const s = try self.schema();
        return s.attrAt(a, self.db.upper());
    }

    /// Stream datoms of `index` under the leading `comps`, folded for
    /// this view. Components after a gap filter.
    pub fn scan(self: *Read, arena: Allocator, index: Index, comps: key.Components) !DatomScan {
        var prefix_list: std.ArrayList(u8) = .empty;
        const covered = try key.packPrefix(&prefix_list, arena, index, comps);
        const prefix = try prefix_list.toOwnedSlice(arena);
        const filter = DatomScan.Filter.after(index, covered, comps);
        const store = self.db.conn.store;
        if (self.fast()) {
            return .{
                .read = self,
                .arena = arena,
                .index = index,
                .filter = filter,
                .source = .{ .current = try store.scan(self.txn, store.trees.cur(index), prefix) },
            };
        }
        const end = try key.successor(arena, prefix);
        return .{
            .read = self,
            .arena = arena,
            .index = index,
            .filter = filter,
            .source = .{ .folded = try store.foldScan(self.txn, store.trees.hist(index), prefix, end, self.db.window()) },
        };
    }

    pub fn entid(self: *Read, arena: Allocator, ref: DbValue.EntityRef) !?u64 {
        switch (ref) {
            .eid => |e| return e,
            .ident => |k| {
                const id = (try self.db.conn.idents.idOf(self.txn, k)) orelse return null;
                // The ident is an entity in this view iff its :db/ident datom is.
                var it = try self.scan(arena, .eavt, .{ .e = id, .a = boot.ident });
                return if (try it.next()) |_| id else null;
            },
            .lookup => |l| {
                const a = (try self.attr(l.a)) orelse return error.UnknownAttribute;
                if (a.unique == .none) return error.TxData;
                if (l.v.valueType() != a.value_type) return error.ValueType;
                const vb = try key.valBytes(arena, l.v);
                var it = try self.scan(arena, .avet, .{ .a = l.a, .v = vb });
                const d = (try it.next()) orelse return null;
                return d.e;
            },
        }
    }

    pub fn ident(self: *Read, arena: Allocator, e: u64) !?u32 {
        var it = try self.scan(arena, .eavt, .{ .e = e, .a = boot.ident });
        const d = (try it.next()) orelse return null;
        if (d.v != .keyword) return error.Corrupted;
        return self.db.conn.idents.internOf(self.txn, d.v.keyword);
    }
};

/// A folded datom stream over one index.
pub const DatomScan = struct {
    read: *Read,
    arena: Allocator,
    index: Index,
    filter: Filter,
    source: union(enum) {
        current: Store.Scan,
        folded: Store.FoldScan,
    },

    /// Components that came after a gap in the prefix.
    pub const Filter = struct {
        e: ?u64 = null,
        a: ?u32 = null,
        v: ?[]const u8 = null,

        fn after(index: Index, covered: u8, comps: key.Components) Filter {
            const order: [3]u8 = switch (index) {
                .eavt => .{ 'e', 'a', 'v' },
                .aevt => .{ 'a', 'e', 'v' },
                .avet => .{ 'a', 'v', 'e' },
                .vaet => .{ 'v', 'a', 'e' },
            };
            var f: Filter = .{};
            for (order[covered..]) |c| switch (c) {
                'e' => f.e = comps.e,
                'a' => f.a = comps.a,
                'v' => f.v = comps.v,
                else => unreachable,
            };
            return f;
        }

        fn passes(self: Filter, index: Index, parts: key.Parts) bool {
            if (self.e) |e| if (parts.e != e) return false;
            if (self.a) |a| if (parts.a != a) return false;
            if (self.v) |v| {
                const want = if (index == .vaet) v[1..] else v;
                if (!std.mem.eql(u8, parts.v, want)) return false;
            }
            return true;
        }
    };

    pub fn next(self: *DatomScan) !?Datom {
        while (true) {
            switch (self.source) {
                .current => |*s| {
                    const kv = s.next() orelse return null;
                    const parts = try key.unpackKey(self.index, false, kv.key);
                    if (!self.filter.passes(self.index, parts)) continue;
                    if (kv.value.len < key.id_len) return error.Corrupted;
                    const t = key.readId(kv.value[0..key.id_len]);
                    return try self.materialise(parts, t, true);
                },
                .folded => |*s| {
                    const r = s.next() orelse return null;
                    const parts = try key.unpackKey(self.index, false, r.fact);
                    if (!self.filter.passes(self.index, parts)) continue;
                    return try self.materialise(parts, r.t, r.added);
                },
            }
        }
    }

    fn materialise(self: *DatomScan, parts: key.Parts, t: u64, added: bool) !Datom {
        const kv = try key.partsVal(self.arena, self.index, parts);
        const v: Val = switch (kv) {
            .val => |x| x,
            .string_long => .{ .string = try self.payload(parts, t, added) },
            .bytes_long => .{ .bytes = try self.payload(parts, t, added) },
        };
        return .{ .e = parts.e, .a = parts.a, .v = v, .t = t, .added = added };
    }

    /// The full out-of-line value from the EAVT payload of this exact
    /// datom (current or history), read with `getFromTree` and copied
    /// into the arena: a multi-page value is assembled in the
    /// transaction's own buffer, which dies with the transaction.
    fn payload(self: *DatomScan, parts: key.Parts, t: u64, added: bool) ![]const u8 {
        const store = self.read.db.conn.store;
        const vbytes = if (self.index == .vaet) unreachable else parts.v;
        if (self.source == .current) {
            const raw = (try store.getCurrent(self.read.txn, .eavt, parts.e, parts.a, vbytes, self.arena)) orelse return error.Corrupted;
            if (raw.len < key.id_len) return error.Corrupted;
            return self.arena.dupe(u8, raw[key.id_len..]);
        }
        const raw = (try store.getHistory(self.read.txn, .eavt, parts.e, parts.a, vbytes, .{ .t = t, .added = added }, self.arena)) orelse return error.Corrupted;
        return self.arena.dupe(u8, raw);
    }
};

// =============================================================================
// tx-range
// =============================================================================

pub const TxEntry = struct {
    t: u64,
    instant: i64,
    datoms: []Datom,
};

/// Txlog entries with `from <= t < to` (an absent `to` runs to the newest).
pub fn txRange(conn: *Conn, arena: Allocator, from: u64, to: ?u64) ![]TxEntry {
    if (!conn.is_open) return error.Closed;
    const txn = try conn.store.beginRead();
    defer txn.abort();
    const now = try conn.store.readT(txn);
    const schema = try conn.schemaAt(txn, now, now);

    var ctx = TxCtx{ .conn = conn, .txn = txn, .schema = schema };
    const ids: datom_mod.IdSource = .{ .ctx = @ptrCast(&ctx), .identId = &TxCtx.identId, .attrType = &TxCtx.attrType };

    var start: [key.id_len]u8 = undefined;
    key.writeId(&start, @max(from, 1));
    var end_buf: [key.id_len]u8 = undefined;
    const end: ?[]const u8 = if (to) |t| blk: {
        key.writeId(&end_buf, t);
        break :blk &end_buf;
    } else null;

    var out: std.ArrayList(TxEntry) = .empty;
    var s = try conn.store.scanRange(txn, conn.store.trees.txlog, &start, end);
    while (s.next()) |kv| {
        if (kv.key.len != key.id_len) return error.Corrupted;
        const t = key.readId(kv.key[0..key.id_len]);
        const bytes = (try conn.store.getTxlog(txn, t)) orelse return error.Corrupted;
        const entry = try datom_mod.decodeTxlog(arena, bytes, t, ids);
        try out.append(arena, .{ .t = t, .instant = entry.instant, .datoms = entry.datoms });
    }
    return out.toOwnedSlice(arena);
}

const TxCtx = struct {
    conn: *Conn,
    txn: *Txn,
    schema: *Schema,

    fn identId(ctx: *anyopaque, name: []const u8) anyerror!?u32 {
        const self: *TxCtx = @ptrCast(@alignCast(ctx));
        return self.conn.idents.idOfName(self.txn, name);
    }

    fn attrType(ctx: *anyopaque, a: u32) anyerror!?key.ValueType {
        const self: *TxCtx = @ptrCast(@alignCast(ctx));
        const attr = self.schema.attr(a) orelse return null;
        return attr.value_type;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

pub const TestConn = struct {
    td: store_mod.TestDir,
    interner: Interner,
    conn: *Conn,

    pub fn init(name: []const u8) !*TestConn {
        const self = try testing.allocator.create(TestConn);
        errdefer testing.allocator.destroy(self);
        self.td = try store_mod.TestDir.init(name);
        errdefer self.td.deinit();
        self.interner = Interner.init(testing.allocator);
        errdefer self.interner.deinit();
        self.conn = try Conn.open(testing.allocator, &self.interner, self.td.path.ptr, .{ .sync = .none });
        return self;
    }

    pub fn reopen(self: *TestConn) !void {
        self.conn.destroy();
        self.conn = try Conn.open(testing.allocator, &self.interner, self.td.path.ptr, .{ .sync = .none });
    }

    pub fn deinit(self: *TestConn) void {
        self.conn.destroy();
        self.interner.deinit();
        self.td.deinit();
        testing.allocator.destroy(self);
    }
};

test "db at bootstrap: datoms, entity, entid, ident, tx-range" {
    const tc = try TestConn.init("db_boot");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const db = try tc.conn.db();
    try testing.expectEqual(@as(u64, 1), db.basis);

    // Every view of the bootstrap agrees on :db/ident's datoms.
    const cur = try db.datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), cur.len);
    const old = try db.asOf(1).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), old.len);
    const none = try db.asOf(0).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 0), none.len);
    const hist = try db.withHistory().datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), hist.len);
    for (cur, old, hist) |a, b, c| {
        try testing.expect(a.eqlFact(b) and b.eqlFact(c));
        try testing.expectEqual(@as(u64, 1), a.t);
        try testing.expect(a.added and c.added);
    }
    const since = try db.sinceT(1).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 0), since.len);
    const since0 = try db.sinceT(0).datoms(arena, .eavt, .{ .e = boot.ident });
    try testing.expectEqual(@as(usize, 5), since0.len);

    // Filter after a gap: eavt with only `a` bound scans everything and keeps one attribute.
    const only_type = try db.datoms(arena, .eavt, .{ .a = boot.value_type });
    try testing.expectEqual(@as(usize, boot.attrs.len), only_type.len);

    // AVET on :db/ident with a value bound.
    const vb = try key.valBytes(arena, .{ .keyword = boot.doc });
    const hit = try db.datoms(arena, .avet, .{ .a = boot.ident, .v = vb });
    try testing.expectEqual(@as(usize, 1), hit.len);
    try testing.expectEqual(@as(u64, boot.doc), hit[0].e);

    // entity
    const ent = try db.entity(arena, boot.tx_instant);
    try testing.expectEqual(@as(usize, 4), ent.len);
    try testing.expectEqual(boot.ident, ent[0].a);
    try testing.expectEqual(@as(u32, boot.tx_instant), ent[0].vals[0].keyword);

    // entid / ident
    const k_doc = try tc.interner.internKeyword("db/doc");
    try testing.expectEqual(@as(?u64, boot.doc), try db.entid(arena, .{ .ident = k_doc }));
    const k_nope = try tc.interner.internKeyword("nope/nope");
    try testing.expect((try db.entid(arena, .{ .ident = k_nope })) == null);
    try testing.expectEqual(@as(?u64, boot.doc), try db.entid(arena, .{ .lookup = .{ .a = boot.ident, .v = .{ .keyword = boot.doc } } }));
    try testing.expectError(error.TxData, db.entid(arena, .{ .lookup = .{ .a = boot.doc, .v = .{ .string = "x" } } }));
    try testing.expectEqual(@as(?u32, k_doc), try db.ident(arena, boot.doc));
    try testing.expect((try db.ident(arena, 1 << 40)) == null);
    try testing.expect((try db.asOf(0).entid(arena, .{ .ident = k_doc })) == null);

    // attr as-of
    try testing.expect((try db.attr(arena, boot.ident)).?.indexed);
    try testing.expect((try db.asOf(0).attr(arena, boot.ident)) == null);

    // tx-range
    const entries = try txRange(tc.conn, arena, 0, null);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u64, 1), entries[0].t);
    try testing.expect(entries[0].datoms.len > boot.idents.len);
    try testing.expect(entries[0].instant > 0);
    const empty = try txRange(tc.conn, arena, 2, null);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // A closed connection refuses every operation.
    tc.conn.close();
    try testing.expectError(error.Closed, db.datoms(arena, .eavt, .{ .e = 1 }));
    try testing.expectError(error.Closed, tc.conn.db());
}

test "basis in the future is refused" {
    const tc = try TestConn.init("db_future");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var db = try tc.conn.db();
    db.basis = 99;
    try testing.expectError(error.BasisInFuture, db.datoms(arena, .eavt, .{ .e = 1 }));
}

test "materialise every value kind into a heap" {
    const tc = try TestConn.init("db_mat");
    defer tc.deinit();
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    const conn = tc.conn;
    try testing.expect((try conn.valToValue(txn, &heap, .{ .boolean = true })).asBool());
    try testing.expectEqual(@as(i64, -3), (try conn.valToValue(txn, &heap, .{ .long = -3 })).asFixnum());
    try testing.expectEqual(@as(f64, 1.5), (try conn.valToValue(txn, &heap, .{ .double = 1.5 })).asFloat());
    try testing.expectEqual(@as(i64, 7), (try conn.valToValue(txn, &heap, .{ .instant = 7 })).asFixnum());
    try testing.expectEqual(@as(i64, 1 << 40), (try conn.valToValue(txn, &heap, .{ .ref = 1 << 40 })).asFixnum());
    const kw = try conn.valToValue(txn, &heap, .{ .keyword = boot.card_many });
    try testing.expectEqualStrings("db.cardinality/many", tc.interner.keywordName(kw.asKeywordId()));
    const s = try conn.valToValue(txn, &heap, .{ .string = "hi" });
    try testing.expectEqualStrings("hi", string_mod.asBytes(s));
    const u = try conn.valToValue(txn, &heap, .{ .uuid = [_]u8{0} ** 16 });
    try testing.expectEqualStrings("00000000-0000-0000-0000-000000000000", string_mod.asBytes(u));
    const b = try conn.valToValue(txn, &heap, .{ .bytes = "\x00\x01" });
    try testing.expectEqualStrings("\x00\x01", string_mod.asBytes(b));
}
