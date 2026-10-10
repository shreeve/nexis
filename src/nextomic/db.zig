//! db.zig — connections and db-values (NEXTOMIC.md §4).
//!
//! A `Conn` owns the store, the ident cache and the schema cache. A
//! `DbValue` is a plain value `{conn, basis, as_of, since, history}`
//! with no open read transaction: every operation begins its read in
//! the file's held snapshot or a fresh one (`docs/DB.md` §3.4), reads
//! `sys["t"]` as `now`, and ends by keeping it. A speculative `with`
//! (transact.zig) makes a second `Conn` over the same store whose
//! reads are read-only children of the held write transaction, with
//! ident and schema caches of its own. Invariants:
//!   - `now == basis` in current mode reads the current trees with no
//!     fold; any other view folds the current and history trees
//!     together (`Store.FoldScan` over `Store.MergedScan`).
//!   - `now < basis` is `error.BasisInFuture`; the db-value is dead.
//!   - `as-of T` caps the view at `min(basis, T)`; `since T` shows only
//!     facts asserted after `T`; `history` shows every row unfolded, and
//!     composes with `as-of` and `since`.
//!   - Out-of-line values are confirmed and materialised from their
//!     payload, in the current EAVT row or the EAVT-h assertion row,
//!     before a datom is returned.
//!   - Every operation allocates in the caller's arena; the connection's
//!     allocator holds only the store, the ident cache and the schema.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const intern_mod = @import("../intern.zig");
const string_mod = @import("../string.zig");
const uuid_mod = @import("../uuid.zig");
const bignum = @import("../bignum.zig");
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
    /// The value at fault as the program wrote it, when it is no datom
    /// value: one of the wrong type, an entity reference that names
    /// nothing. From the operation's own arguments, so rooted.
    given: ?Value = null,
    /// The type a value of the wrong type was refused for.
    value_type: ?key.ValueType = null,
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
    /// Given the format of a store refused as another format's
    /// (`error.Format`).
    refused_format: ?*u16 = null,
};

/// The keywords tx-data's forms are read by (transact.zig).
pub const FormKeyword = enum { @"db/id", @"db/add", @"db/retract", @"db/retractEntity", @"db.fn/call", @"db.fn/cas" };

pub const Conn = struct {
    gpa: Allocator,
    store: *Store,
    interner: *Interner,
    /// The interner's id of each form keyword, interned once.
    form_keywords: std.EnumArray(FormKeyword, u32) = .initFill(0),
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
    /// Which life of this struct is current: `reopen` starts a released
    /// connection's next one, and every `with` the view's next one. A
    /// db-value or handle made in an earlier life finds the connection
    /// closed (`error.Closed`).
    gen: u64 = 0,
    /// The view every speculative `with` on this connection reads
    /// through, made by the first and reused by each later one; freed
    /// with the connection.
    view: ?*Conn = null,

    /// Open or create the store at `path`; bootstrap on first open.
    /// `interner` is the VM's keyword table and outlives the connection.
    pub fn open(gpa: Allocator, interner: *Interner, path: [*:0]const u8, options: OpenOptions) !*Conn {
        const self = try gpa.create(Conn);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .store = undefined, .interner = interner, .idents = undefined, .sync_mode = .none, .is_open = false, .store_closed = true };
        try self.openIn(path, options, 0);
        return self;
    }

    /// Open `path` in the struct of this released connection, as its
    /// next life: its handles and db-values from before stay closed.
    pub fn reopen(self: *Conn, path: [*:0]const u8, options: OpenOptions) !void {
        std.debug.assert(self.store_closed);
        try self.openIn(path, options, self.gen + 1);
    }

    fn openIn(self: *Conn, path: [*:0]const u8, options: OpenOptions, gen: u64) !void {
        const sync_mode = options.sync orelse SyncMode.of(store_mod.db_layer.Durability.process());
        const store = try Store.open(self.gpa, path, .{ .sync = sync_mode, .refused_format = options.refused_format });
        errdefer store.close();
        const gpa = self.gpa;
        const interner = self.interner;
        const view = self.view;
        var form_keywords: std.EnumArray(FormKeyword, u32) = undefined;
        for (std.enums.values(FormKeyword)) |f| form_keywords.set(f, try interner.internKeyword(@tagName(f)));
        self.* = .{
            .gpa = gpa,
            .store = store,
            .interner = interner,
            .form_keywords = form_keywords,
            .idents = Idents.init(gpa, store, interner),
            .sync_mode = sync_mode,
            .is_open = true,
            .file = .{ store.file.id.dev, store.file.id.ino },
            .gen = gen,
            .view = view,
        };
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
    /// the file when a commit left it unsynced and no sync of it has
    /// failed (`Store.closingSync`). A sync that fails here is returned
    /// once the connection is closed.
    pub fn release(self: *Conn) !void {
        if (!self.is_open) return;
        if (self.busy > 0) return error.Busy;
        const synced = self.store.closingSync();
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

    /// Free the `Conn` and its view: teardown, when nothing references
    /// them any more.
    pub fn destroy(self: *Conn) void {
        self.is_open = false;
        if (!self.store_closed) self.closeStore();
        if (self.view) |v| v.destroy();
        self.gpa.destroy(self);
    }

    /// A read transaction for one operation: the file's held snapshot
    /// while no commit has passed it (`db.StoreFile.takeHeld`), else a
    /// fresh reader; on a `with` view, a read-only child of the held
    /// write transaction. Ends with `endReadTxn`.
    pub fn beginReadTxn(self: *Conn) !*Txn {
        if (!self.is_open) return error.Closed;
        const txn = if (self.overlay) |w| try w.beginReadChild() else self.store.file.takeHeld() orelse try self.store.beginRead();
        errdefer txn.abort();
        try self.idents.refresh(txn);
        self.busy += 1;
        return txn;
    }

    /// End the read: a reader is kept for the next read while it is the
    /// latest commit (NEXTOMIC.md §2); a `with` view's, a child of the
    /// held write transaction, is aborted.
    pub fn endReadTxn(self: *Conn, txn: *Txn) void {
        if (self.owns_store) self.store.file.keep(txn) else txn.abort();
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
        return self.at(try self.store.readT(txn));
    }

    /// The plain db-value at `basis`, in this connection's current life.
    pub fn at(self: *Conn, basis: u64) DbValue {
        return .{ .conn = self, .gen = self.gen, .basis = basis };
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
    /// (the entries settle it for a writer that leaves the generation
    /// alone); otherwise the cache is rebuilt at `now`.
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
        var start: [key.ordered_max]u8 = undefined;
        var end: [key.ordered_max]u8 = undefined;
        var s = try Store.scanRange(txn, self.store.trees.txlog, key.writeOrdered(&start, after + 1), key.writeOrdered(&end, upto + 1));
        while (try s.next()) |kv| {
            if (try datom_mod.touchesAttrPartition(kv.value)) return true;
        }
        return false;
    }

    /// Materialise a datom value into the VM heap. Refs become
    /// fixnums, longs the language's integer (a bignum past the fixnum
    /// range), instants and uuids their kinds; keywords are interned
    /// into the VM; byte arrays become strings.
    pub fn valToValue(self: *Conn, txn: *Txn, heap: *Heap, v: Val) !Value {
        return switch (v) {
            .boolean => |b| value.fromBool(b),
            .long => |n| try bignum.fromI64(heap, n),
            .instant => |ms| value.fromInst(ms),
            .double => |d| value.fromFloat(d),
            .keyword => |id| blk: {
                const k = (try self.idents.internOf(txn, id)) orelse return error.Corrupted;
                break :blk self.interner.keywordValue(k);
            },
            .ref => |eid| value.fromFixnum(@intCast(eid)) orelse error.ValueType,
            .string => |s| try string_mod.fromBytes(heap, s),
            .uuid => |u| try uuid_mod.make(heap, u),
            .bytes => |b| try string_mod.fromBytes(heap, b),
        };
    }
};

// =============================================================================
// DbValue
// =============================================================================

pub const DbValue = struct {
    conn: *Conn,
    /// The life of `conn` this value was taken in (`Conn.gen`).
    gen: u64 = 0,
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

    /// Narrows like `asOf`: the newer bound wins.
    pub fn sinceT(self: DbValue, t: u64) DbValue {
        var d = self;
        d.since = if (self.since) |cur| @max(cur, t) else t;
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
        if (self.gen != self.conn.gen) return error.Closed;
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
            .source = .{ .folded = try foldIn(arena, try Store.foldScan(self.txn, store.trees, index, prefix, end, self.db.window())) },
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
            .source = .{ .folded = try foldIn(arena, try Store.foldScan(self.txn, store.trees, index, start, end, self.db.window())) },
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

fn foldIn(arena: Allocator, scan: Store.FoldScan) !*Store.FoldScan {
    const p = try arena.create(Store.FoldScan);
    p.* = scan;
    return p;
}

/// A folded datom stream over one index.
pub const DatomScan = struct {
    read: *Read,
    arena: Allocator,
    index: Index,
    filter: Filter,
    source: union(enum) {
        current: Store.Scan,
        /// In the arena: a fold walks two trees, and a scan the
        /// planner opens once a row, in the plain view, stays one
        /// cursor wide.
        folded: *Store.FoldScan,
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
                    const kv = (try s.next()) orelse return null;
                    const parts = try key.unpackKey(self.index, false, kv.key);
                    if (!self.filter.passes(self.index, parts)) continue;
                    const t = (try key.readCurrent(kv.value)).t;
                    return try self.materialise(parts, .{ .fact = kv.key, .t = t, .added = true, .current = true });
                },
                .folded => |s| {
                    const r = (try s.next()) orelse return null;
                    const parts = try key.unpackKey(self.index, false, r.fact);
                    if (!self.filter.passes(self.index, parts)) continue;
                    return try self.materialise(parts, r);
                },
            }
        }
    }

    fn materialise(self: *DatomScan, parts: key.Parts, row: Store.HistoryRow) !Datom {
        const kv = try key.partsVal(self.arena, self.index, parts);
        const v: Val = switch (kv) {
            .val => |x| x,
            .string_long => .{ .string = try self.payload(parts, row) },
            .bytes_long => .{ .bytes = try self.payload(parts, row) },
        };
        return .{ .e = parts.e, .a = parts.a, .v = v, .t = row.t, .added = row.added };
    }

    /// The full out-of-line value of this exact datom, current or
    /// history, copied into the arena: a multi-page value is assembled
    /// in the transaction's own buffer, which dies with the
    /// transaction.
    fn payload(self: *DatomScan, parts: key.Parts, row: Store.HistoryRow) ![]const u8 {
        const store = self.read.db.conn.store;
        const vbytes = if (self.index == .vaet) unreachable else parts.v;
        if (row.current) {
            return (try store.currentPayload(self.read.txn, parts.e, parts.a, vbytes, self.arena)) orelse error.Corrupted;
        }
        return self.arena.dupe(u8, try store.historyPayload(self.read.txn, parts.e, parts.a, vbytes, .{ .t = row.t, .added = row.added }));
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

    var ctx = TxCtx{ .conn = conn, .txn = txn, .schema = schema, .arena = arena };
    const src: datom_mod.Source = .{ .ctx = @ptrCast(&ctx), .attrType = &TxCtx.attrType, .payload = &TxCtx.payload };

    var start_buf: [key.ordered_max]u8 = undefined;
    const start = key.writeOrdered(&start_buf, @max(from, 1));
    var end_buf: [key.ordered_max]u8 = undefined;
    const end: ?[]const u8 = if (to) |t| key.writeOrdered(&end_buf, t) else null;

    var out: std.ArrayList(TxEntry) = .empty;
    var s = try Store.scanRange(txn, conn.store.trees.txlog, start, end);
    while (try s.next()) |kv| {
        const t = try key.readTxlogKey(kv.key);
        const entry = try datom_mod.decodeTxlog(arena, kv.value, t, src);
        try out.append(arena, .{ .t = t, .instant = entry.instant, .datoms = entry.datoms, .excised = entry.excised });
    }
    return out.toOwnedSlice(arena);
}

const TxCtx = struct {
    conn: *Conn,
    txn: *Txn,
    schema: *Schema,
    arena: Allocator,

    fn attrType(ctx: *anyopaque, a: u32) anyerror!?key.ValueType {
        const self: *TxCtx = @ptrCast(@alignCast(ctx));
        const attr = self.schema.attr(a) orelse return null;
        return attr.value_type;
    }

    /// An out-of-line value's payload from its datom's row: the current
    /// EAVT row when it is the assertion at `t`, else the EAVT-h row
    /// (NEXTOMIC.md §2.2). A datom of the log whose row is gone is
    /// `error.Corrupted`.
    fn payload(ctx: *anyopaque, e: u64, a: u32, vbytes: []const u8, t: u64, added: bool) anyerror![]const u8 {
        const self: *TxCtx = @ptrCast(@alignCast(ctx));
        const store = self.conn.store;
        if (added) {
            const k = try key.keyBytes(self.arena, .eavt, e, a, vbytes, null);
            if (try self.txn.getFromTree(store.trees.cur(.eavt), k)) |row| {
                const cur = try key.readCurrent(row);
                if (cur.t == t) return if (cur.rest.len == 0) error.Corrupted else cur.rest;
            }
        }
        return store.historyPayload(self.txn, e, a, vbytes, .{ .t = t, .added = added });
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
