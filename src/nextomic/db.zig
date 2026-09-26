//! db.zig — connections and db-values (NEXTOMIC.md §4).
//!
//! A `Conn` owns the store, the ident cache and the schema cache. A
//! `DbValue` is a plain value `{conn, basis, as_of, since, history}`
//! with no open read transaction: every operation opens one, reads
//! `sys["t"]` as `now`, and closes it. A speculative `with`
//! (transact.zig) makes a second `Conn` over the same store whose
//! reads are read-only children of the held write transaction, with
//! ident and schema caches of its own. Invariants:
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
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const intern_mod = @import("../intern.zig");
const string_mod = @import("../string.zig");
const bignum = @import("../bignum.zig");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const idents_mod = @import("idents.zig");
const schema_mod = @import("schema.zig");
const fulltext = @import("fulltext.zig");

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

/// The error set of `f`, for naming a module's failures by the
/// operations it performs.
pub fn ErrorsOf(comptime f: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.error_set;
}

/// What an operation was looking at when it failed, for the error
/// payload the program sees (NEXTOMIC.md §7). A caller that wants the
/// detail passes one in; every field is set only when the failing
/// step has it at hand.
pub const Fault = struct {
    /// The attribute, as a keyword when it has an ident, else its id.
    attr: ?Value = null,
    e: ?u64 = null,
    value: ?Val = null,
    message: ?[]const u8 = null,
    /// A failed `:db.fn/cas`: what it expected and what it found, either
    /// absent when the attribute had no value, and the expected keyword
    /// as the form wrote it when the store has never seen it.
    cas: ?struct { expected: ?Val, actual: ?Val, unseen: ?Value = null } = null,
};

/// The Nextomic error set; each maps to a `:nextomic/*` keyword.
pub const Error = error{
    HistoryView,
    UnknownAttribute,
    ValueType,
    Unique,
    Conflict,
    NoEntity,
    BasisInFuture,
    Closed,
    /// Malformed tx-data: `:nextomic/tx-data`.
    TxData,
    /// `release` while a read, a `transact` or a `with` is in flight on
    /// the connection: `:nextomic/busy`.
    Busy,
};

// =============================================================================
// Conn
// =============================================================================

pub const OpenOptions = struct {
    /// How the connection's commits sync; null takes the process's
    /// durability (`NEXIS_DURABILITY`, NEXTOMIC.md §3).
    sync: ?SyncMode = null,
    map_size: u64 = store_mod.initial_map_size,
};

pub const Conn = struct {
    gpa: Allocator,
    store: *Store,
    interner: *Interner,
    idents: Idents,
    schema_cache: ?*Schema = null,
    sync_mode: SyncMode,
    /// Accepting operations. A closed `Conn` stays allocated so that
    /// db-values still pointing at it fail with `error.Closed`.
    is_open: bool,
    /// Operations in flight: reads between `beginReadTxn` and
    /// `endReadTxn`, and the write transaction of a `transact` or a held
    /// `with` (`beginWriteTxn` until `taskDone`).
    busy: u32 = 0,
    /// `close` was asked while busy: the store is freed when the last
    /// operation ends, so no cursor in flight dangles.
    close_pending: bool = false,
    /// The store (when owned), ident cache and schema cache are gone.
    store_closed: bool = false,
    /// Closing frees the store; false on the view of a speculative
    /// `with`, which shares its connection's store.
    owns_store: bool = true,
    /// The write transaction this connection reads through, as
    /// read-only children: set on the view of a speculative `with`.
    overlay: ?*Txn = null,
    /// The view of the speculative `with` holding this connection's
    /// write transaction, while it is open.
    speculative: ?*Conn = null,
    /// The (device, inode) of the store's file, which db-values compare
    /// by (NEXTOMIC.md §6): every connection to one file reads one
    /// database. Null on the view of a speculative `with`, whose
    /// uncommitted state is its own.
    file: ?[2]u64 = null,

    /// Open or create the store at `path`; bootstrap on first open.
    /// `interner` is the VM's keyword table and outlives the connection.
    pub fn open(gpa: Allocator, interner: *Interner, path: [*:0]const u8, options: OpenOptions) !*Conn {
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        const sync_mode = options.sync orelse SyncMode.of(store_mod.db_layer.Durability.process());
        const store = try Store.open(gpa, path, .{ .map_size = options.map_size, .sync = sync_mode });
        errdefer store.close();
        try refreshFulltext(gpa, store, sync_mode);
        self.* = .{
            .gpa = gpa,
            .store = store,
            .interner = interner,
            .idents = Idents.init(gpa, store, interner),
            .sync_mode = sync_mode,
            .is_open = true,
            .file = .{ store.file.id.dev, store.file.id.ino },
        };
        return self;
    }

    /// Rebuild `nx/fulltext` when its rows are stale and some attribute
    /// is full-text (fulltext.zig), in a write transaction of its own
    /// that writes no datom. A file this process may only read, or one
    /// whose writer is busy in this process, is left as it is: its
    /// searches re-tokenise until a transaction rebuilds the rows.
    fn refreshFulltext(gpa: Allocator, store: *Store, sync_mode: SyncMode) !void {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        {
            const txn = try store.beginRead();
            defer txn.abort();
            if (!try fulltext.needsRebuild(store, txn, arena, try store.readT(txn))) return;
        }
        const txn = store.beginWrite(sync_mode) catch |err| switch (err) {
            error.TxnReadOnly, error.WriterActive => return,
            else => return err,
        };
        errdefer txn.abort();
        try fulltext.rebuild(store, txn, arena, try store.readT(txn));
        try store.commit(txn);
    }

    /// Stop accepting operations. Idempotent. The `Conn` stays allocated
    /// so db-values that still point at it fail with `error.Closed`; the
    /// store and the caches are freed now, or when the last operation in
    /// flight ends.
    pub fn close(self: *Conn) void {
        if (!self.is_open) return;
        self.is_open = false;
        if (self.busy > 0) {
            self.close_pending = true;
            return;
        }
        self.closeStore();
    }

    /// `close`, refused while an operation is in flight, after syncing
    /// the file when a commit left it unsynced. A failed sync is
    /// returned once the connection is closed.
    pub fn release(self: *Conn) !void {
        if (!self.is_open) return;
        if (self.busy > 0) return error.Busy;
        const synced = self.store.sync();
        self.close();
        return synced;
    }

    fn closeStore(self: *Conn) void {
        self.close_pending = false;
        self.dropSchema();
        self.idents.deinit();
        if (self.owns_store) self.store.close();
        self.store_closed = true;
    }

    /// Free the `Conn`: teardown, when nothing references it any more.
    pub fn destroy(self: *Conn) void {
        self.is_open = false;
        if (!self.store_closed) self.closeStore();
        self.gpa.destroy(self);
    }

    /// A read transaction for one operation: the file's held snapshot
    /// while no commit has passed it (`db.StoreFile.takeHeld`), else a
    /// fresh reader; on a `with` view, a read-only child of the held
    /// write transaction. Ends with `endReadTxn`.
    pub fn beginReadTxn(self: *Conn) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = if (self.overlay) |w| try self.store.beginReadChild(w) else self.store.file.takeHeld() orelse try self.store.beginRead();
        errdefer txn.abort();
        try self.idents.refresh(txn);
        self.busy += 1;
        return txn;
    }

    /// End the read: a reader is kept for the next read while it is the
    /// latest commit (NEXTOMIC.md §2), a child is aborted.
    pub fn endReadTxn(self: *Conn, txn: *Txn) void {
        if (self.overlay == null) self.store.file.keep(txn) else txn.abort();
        self.taskDone();
    }

    /// The write transaction of a `transact` or a `with`; the caller
    /// commits or aborts it, then calls `taskDone`.
    pub fn beginWriteTxn(self: *Conn, sync_mode: SyncMode) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = try self.store.beginWrite(sync_mode);
        errdefer txn.abort();
        try self.idents.refresh(txn);
        self.busy += 1;
        return txn;
    }

    /// One operation ended; a pending close completes with the last.
    pub fn taskDone(self: *Conn) void {
        self.busy -= 1;
        if (self.busy == 0 and self.close_pending) self.closeStore();
    }

    /// A db-value at the current basis.
    pub fn db(self: *Conn) !DbValue {
        const txn = try self.beginReadTxn();
        defer self.endReadTxn(txn);
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
    /// through `attrAt`; one whose schema generation is still the
    /// store's serves `now` too once the txlog entries committed since
    /// hold no attribute-partition datom, since only data was committed
    /// (the entries settle it for a writer of a build that does not
    /// bump the generation); otherwise the cache is rebuilt at `now`.
    pub fn schemaAt(self: *Conn, txn: *Txn, basis: u64, now: u64) !*Schema {
        if (self.schema_cache) |s| {
            if (s.basis >= basis) return s;
            if (s.gen == try self.store.readSchemaGen(txn) and !try self.schemaWritten(txn, s.basis, now)) {
                s.basis = now;
                return s;
            }
            s.deinit();
            self.schema_cache = null;
        }
        const s = try Schema.build(self.gpa, self.store, txn, now);
        self.schema_cache = s;
        return s;
    }

    /// Whether a transaction in `(after, upto]` wrote a datom on an
    /// attribute-partition entity. Each entry is read once per
    /// connection: the cache then serves `upto`.
    fn schemaWritten(self: *Conn, txn: *Txn, after: u64, upto: u64) !bool {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        var start: [key.id_len]u8 = undefined;
        key.writeId(&start, after + 1);
        var end: [key.id_len]u8 = undefined;
        key.writeId(&end, upto + 1);
        var s = try Store.scanRange(txn, self.store.trees.txlog, &start, &end);
        while (s.next()) |kv| {
            defer _ = arena_state.reset(.retain_capacity);
            if (try datom_mod.touchesAttrPartition(arena_state.allocator(), kv.value)) return true;
        }
        return false;
    }

    /// Materialise a datom value into the VM heap. Refs become
    /// fixnums, longs and instants the language's integer (a bignum
    /// past the fixnum range); keywords are interned into the VM;
    /// uuids become their canonical text; byte arrays become strings.
    pub fn valToValue(self: *Conn, txn: *Txn, heap: *Heap, v: Val) !Value {
        return switch (v) {
            .boolean => |b| value.fromBool(b),
            .long, .instant => |n| try bignum.fromI64(heap, n),
            .double => |d| value.fromFloat(d),
            .keyword => |id| blk: {
                const k = (try self.idents.internOf(txn, id)) orelse return error.Corrupted;
                break :blk self.interner.keywordValue(k);
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
        if (self.history) return .{ .all = .{ .after = self.since orelse 0, .upto = up } };
        if (self.since) |after| return .{ .since = .{ .after = after, .upto = up } };
        return .{ .as_of = up };
    }

    /// Open a read transaction for one operation and check the basis.
    pub fn beginRead(self: DbValue) !Read {
        const txn = try self.conn.beginReadTxn();
        errdefer self.conn.endReadTxn(txn);
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
    /// order; empty when the entity has no datoms in this view. Not
    /// defined on a history view, whose datoms are not a state.
    pub fn entity(self: DbValue, arena: Allocator, e: u64) ![]EntityAttr {
        if (self.history) return error.HistoryView;
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
    pub fn attr(self: DbValue, a: u32) !?Attr {
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
        self.db.conn.endReadTxn(self.txn);
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
                .source = .{ .current = try Store.scan(self.txn, store.trees.cur(index), prefix) },
            };
        }
        const end = try key.successor(arena, prefix);
        return .{
            .read = self,
            .arena = arena,
            .index = index,
            .filter = filter,
            .source = .{ .folded = try Store.foldScan(self.txn, store.trees.hist(index), prefix, end, self.db.window()) },
        };
    }

    /// Stream the datoms of `index` whose keys lie in `[start, end)`,
    /// folded for this view; an absent `end` runs to the tree's last
    /// key. The bounds pin every component they cover, so nothing
    /// filters.
    pub fn scanRange(self: *Read, arena: Allocator, index: Index, start: []const u8, end: ?[]const u8) !DatomScan {
        const store = self.db.conn.store;
        if (self.fast()) {
            return .{
                .read = self,
                .arena = arena,
                .index = index,
                .filter = .{},
                .source = .{ .current = try Store.scanRange(self.txn, store.trees.cur(index), start, end) },
            };
        }
        return .{
            .read = self,
            .arena = arena,
            .index = index,
            .filter = .{},
            .source = .{ .folded = try Store.foldScan(self.txn, store.trees.hist(index), start, end, self.db.window()) },
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

    /// Components the prefix does not pin exactly: those after a gap,
    /// and always `v`. A value encoding that ends in the `0x00`
    /// terminator is a byte prefix of every key whose value continues
    /// with an escaped NUL (`"a"` is a prefix of `"a\x00b"`), so a
    /// prefix scan covering `v` still admits longer values; comparing
    /// the row's whole value section makes the match exact.
    pub const Filter = struct {
        e: ?u64 = null,
        a: ?u32 = null,
        v: ?[]const u8 = null,

        fn after(index: Index, covered: u8, comps: key.Components) Filter {
            var f: Filter = .{ .v = comps.v };
            for (index.order()[covered..]) |c| switch (c) {
                .e => f.e = comps.e,
                .a => f.a = comps.a,
                .v => {},
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
                    const t = try key.readId(kv.value[0..key.id_len]);
                    return try self.materialise(parts, t, true);
                },
                .folded => |*s| {
                    const r = (try s.next()) orelse return null;
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

    /// The full out-of-line value from the EAVT-h payload of this exact
    /// datom (current or history), read with `getFromTree` and copied
    /// into the arena: a multi-page value is assembled in the
    /// transaction's own buffer, which dies with the transaction.
    fn payload(self: *DatomScan, parts: key.Parts, t: u64, added: bool) ![]const u8 {
        const store = self.read.db.conn.store;
        const vbytes = if (self.index == .vaet) unreachable else parts.v;
        if (self.source == .current) {
            return (try store.currentPayload(self.read.txn, parts.e, parts.a, vbytes, self.arena)) orelse error.Corrupted;
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
    /// The excision marker (§4); empty on an untouched entry.
    excised: []u64,
};

/// Txlog entries with `from <= t < to` (an absent `to` runs to the newest).
pub fn txRange(conn: *Conn, arena: Allocator, from: u64, to: ?u64) ![]TxEntry {
    const txn = try conn.beginReadTxn();
    defer conn.endReadTxn(txn);
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
    var s = try Store.scanRange(txn, conn.store.trees.txlog, &start, end);
    while (s.next()) |kv| {
        if (kv.key.len != key.id_len) return error.Corrupted;
        const t = try key.readId(kv.key[0..key.id_len]);
        const entry = try datom_mod.decodeTxlog(arena, kv.value, t, ids);
        try out.append(arena, .{ .t = t, .instant = entry.instant, .datoms = entry.datoms, .excised = entry.excised });
    }
    return out.toOwnedSlice(arena);
}

const TxCtx = struct {
    conn: *Conn,
    txn: *Txn,
    schema: *Schema,

    /// An entry spells a keyword by the name it had when written; a
    /// name retired by a rename still decodes to its id.
    fn identId(ctx: *anyopaque, name: []const u8) anyerror!?u32 {
        const self: *TxCtx = @ptrCast(@alignCast(ctx));
        if (try self.conn.idents.idOfName(self.txn, name)) |id| return id;
        return self.conn.store.retiredIdentId(self.txn, name);
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

test "a connection creates a new store file at the store's initial map size" {
    const tc = try TestConn.init("db_map_size");
    defer tc.deinit();
    try testing.expectEqual(store_mod.initial_map_size, tc.conn.store.file.env.info().mapSize);
}

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

    // entity: current, as-of and since views; never a history view.
    const ent = try db.entity(arena, boot.tx_instant);
    try testing.expectEqual(@as(usize, 4), ent.len);
    try testing.expectEqual(boot.ident, ent[0].a);
    try testing.expectEqual(@as(u32, boot.tx_instant), ent[0].vals[0].keyword);
    try testing.expectError(error.HistoryView, db.withHistory().entity(arena, boot.tx_instant));

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
    try testing.expect((try db.attr(boot.ident)).?.indexed);
    try testing.expect((try db.asOf(0).attr(boot.ident)) == null);

    // tx-range
    const entries = try txRange(tc.conn, arena, 0, null);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u64, 1), entries[0].t);
    try testing.expect(entries[0].datoms.len > boot.idents.len);
    try testing.expect(entries[0].instant > 0);
    const empty = try txRange(tc.conn, arena, 2, null);
    try testing.expectEqual(@as(usize, 0), empty.len);

    // A closed connection refuses every operation.
    try tc.conn.release();
    try testing.expectError(error.Closed, db.datoms(arena, .eavt, .{ .e = 1 }));
    try testing.expectError(error.Closed, tc.conn.db());
}

test "a bounded scan seeks to its start and stops at its end, on every view" {
    const tc = try TestConn.init("db_scan_range");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();

    // AVET of :db/ident is keyed by ident id: [doc, type_double) holds
    // doc, txInstant and type_long.
    var abuf: [key.attr_len]u8 = undefined;
    key.writeAttr(&abuf, boot.ident);
    const lo = try std.mem.concat(arena, u8, &.{ &abuf, try key.valBytes(arena, .{ .keyword = boot.doc }) });
    const hi = try std.mem.concat(arena, u8, &.{ &abuf, try key.valBytes(arena, .{ .keyword = boot.type_double }) });
    for ([_]DbValue{ db, db.asOf(1) }) |view| {
        var rd = try view.beginRead();
        defer rd.close();
        var it = try rd.scanRange(arena, .avet, lo, hi);
        var seen: [3]u64 = undefined;
        var n: usize = 0;
        while (try it.next()) |d| : (n += 1) seen[n] = d.e;
        try testing.expectEqual(@as(usize, 3), n);
        try testing.expectEqualSlices(u64, &.{ boot.doc, boot.tx_instant, boot.type_long }, &seen);
        // An open end runs to the attribute's last key and past it.
        var open = try rd.scanRange(arena, .avet, lo, (try key.successor(arena, &abuf)).?);
        var m: usize = 0;
        while (try open.next()) |_| m += 1;
        try testing.expectEqual(@as(usize, boot.idents.len - boot.doc + 1), m);
    }
}

test "a txlog key past the id range is corrupt, not a crash" {
    const tc = try TestConn.init("db_txlog_corrupt");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    {
        const txn = try tc.conn.store.beginWrite(.none);
        errdefer txn.abort();
        try txn.putInTree(tc.conn.store.trees.txlog, &([_]u8{0xFF} ** key.id_len), &.{});
        try txn.commit();
    }
    try testing.expectError(error.Corrupted, txRange(tc.conn, arena_state.allocator(), 1, null));
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

test "a VAET component must be a ref value" {
    const tc = try TestConn.init("db_vaet_value");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();
    const sb = try key.valBytes(arena, .{ .string = "x" });
    try testing.expectError(error.ValueType, db.datoms(arena, .vaet, .{ .v = sb }));
    try testing.expectError(error.ValueType, key.prefixBytes(arena, .vaet, .{ .v = sb }));
    try testing.expectError(error.ValueType, key.keyBytes(arena, .vaet, 1, 2, sb, null));
    try testing.expectError(error.ValueType, key.prefixBytes(arena, .vaet, .{ .v = "" }));
    // A ref value scans; the other indexes take any value.
    const rb = try key.valBytes(arena, .{ .ref = 1 });
    _ = try db.datoms(arena, .vaet, .{ .v = rb });
    _ = try db.datoms(arena, .avet, .{ .a = 1, .v = sb });
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

test "every operation on a closed connection is error.Closed" {
    const tc = try TestConn.init("db_closed");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();
    const views = [_]DbValue{ db, db.asOf(1), db.sinceT(0), db.withHistory() };
    try tc.conn.release();
    try tc.conn.release();
    tc.conn.close();
    try testing.expect(!tc.conn.is_open and tc.conn.store_closed);
    try testing.expectError(error.Closed, tc.conn.db());
    try testing.expectError(error.Closed, tc.conn.sync());
    try testing.expectError(error.Closed, txRange(tc.conn, arena, 0, null));
    for (views) |v| {
        try testing.expectError(error.Closed, v.beginRead());
        try testing.expectError(error.Closed, v.datoms(arena, .eavt, .{ .e = 1 }));
        if (!v.history) try testing.expectError(error.Closed, v.entity(arena, 1));
        try testing.expectError(error.Closed, v.entid(arena, .{ .eid = 1 }));
        try testing.expectError(error.Closed, v.entid(arena, .{ .lookup = .{ .a = boot.ident, .v = .{ .keyword = boot.doc } } }));
        try testing.expectError(error.Closed, v.ident(arena, boot.doc));
        try testing.expectError(error.Closed, v.attr(boot.ident));
    }
}

test "close waits for operations in flight; release refuses them" {
    const tc = try TestConn.init("db_busy");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db = try tc.conn.db();

    var rd = try db.beginRead();
    try testing.expectEqual(@as(u32, 1), tc.conn.busy);
    try testing.expectError(error.Busy, tc.conn.release());
    try testing.expect(tc.conn.is_open);
    // close marks the connection closed at once and keeps the store until
    // the read ends, so its cursors stay valid.
    tc.conn.close();
    try testing.expect(!tc.conn.is_open);
    try testing.expect(tc.conn.close_pending);
    try testing.expectError(error.Closed, tc.conn.db());
    try testing.expectError(error.Closed, db.datoms(arena, .eavt, .{ .e = 1 }));
    var it = try rd.scan(arena, .eavt, .{ .e = boot.ident });
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 5), n);
    rd.close();
    try testing.expectEqual(@as(u32, 0), tc.conn.busy);
    try testing.expect(!tc.conn.close_pending);
    try testing.expect(tc.conn.store_closed);
    try tc.conn.release();
}
