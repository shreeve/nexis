//! transact.zig — the transaction protocol (NEXTOMIC.md §3).
//!
//! One `transact` is one emdb write transaction; emdb's write lock is
//! the transactor. The pipeline, named as the banners below name it:
//!
//!   - begin: the write transaction, `t = sys["t"] + 1`;
//!   - normalise: tx-data to ops (list forms, written as vectors or
//!     lists, and map forms with nested entities and card-many
//!     collections), resolving attributes through the schema at `now`
//!     and converting values by the attribute's type;
//!   - tempids: `:db/ident` binds to the ident's id (minting it); one
//!     fixpoint over the unique assertions upserts identities through
//!     an AVET probe, unifies the tempids naming one identity, and
//!     resolves a lookup ref against the committed state and every
//!     unique assertion of the transaction alike; the rest take fresh
//!     eids;
//!   - expand: ops against the committed trees plus the transaction's
//!     own overlay: card-one implicit retracts, no-op re-assertions,
//!     conflicts, retract-attribute, retract-entity with VAET cleanup
//!     and component cascade, then the `:db/txInstant` datom unless the
//!     tx-data asserted one on the transaction entity, then the unique
//!     check over the whole expansion;
//!   - schema: validate schema changes and backfill AVET for attributes
//!     that become indexed or unique;
//!   - write: the eight index trees, the txlog, the counts and `sys`;
//!   - commit: then publish minted idents to the cache.
//!
//! Any error aborts the write transaction; nothing partial can exist.
//! Everything the transaction allocates lives in the caller's arena.
//!
//! A speculative `with` stops before the commit: the write transaction
//! stays open, a view connection reads it through read-only children,
//! and `finish` aborts it. Only one write transaction exists per store,
//! so `transact` and `with` are `error.Nested` while one is held.

const std = @import("std");
const value = @import("../value.zig");
const intern_mod = @import("../intern.zig");
const string_mod = @import("../string.zig");
const list_mod = @import("../coll/list.zig");
const vector_mod = @import("../coll/vector.zig");
const champ = @import("../coll/champ.zig");
const Heap = @import("../heap.zig").Heap;
const sorted = @import("../coll/sorted.zig");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const idents_mod = @import("idents.zig");
const schema_mod = @import("schema.zig");
const db_mod = @import("db.zig");
const marshal = @import("marshal.zig");
const excise_mod = @import("excise.zig");
const fulltext = @import("fulltext.zig");
const stack = @import("../stack.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Txn = emdb.Txn;
const Store = store_mod.Store;
const Minter = idents_mod.Minter;
const Schema = schema_mod.Schema;
const Attr = schema_mod.Attr;
const Conn = db_mod.Conn;
const DbValue = db_mod.DbValue;
const Fault = db_mod.Fault;
const Val = key.Val;
const Datom = datom_mod.Datom;
const boot = store_mod.boot;
const SyncMode = store_mod.SyncMode;

// =============================================================================
// Public types
// =============================================================================

pub const Error = error{
    /// A speculative `with` holds the connection's write transaction, so
    /// another `transact` or `with` cannot begin: `:nextomic/nested`.
    Nested,
    /// A transaction function could not run: no hook to call it through,
    /// or calls nested past `max_call_depth`: `:nextomic/tx-fn`.
    TxFn,
    /// A `:db.fn/cas` found a value other than the one it expected:
    /// `:nextomic/cas`.
    Cas,
    /// A schema change the attribute's data refuses: `:nextomic/schema`.
    Schema,
};

const ident_too_long = std.fmt.comptimePrint("a keyword the store holds is at most {d} bytes long", .{idents_mod.max_name_len});

/// How deep `:db.fn/call` results may nest further calls: far past any
/// real chain, and short enough that a function calling itself forever
/// fails in milliseconds.
pub const max_call_depth: u32 = 1000;

/// Calls a transaction function (NEXTOMIC.md §3 "Transaction
/// functions"). `f` is the value in the `:db.fn/call` form: a function,
/// or a symbol the hook resolves through the namespace registry. The
/// hook boxes `db_before` for the VM, calls `f` with it ahead of
/// `args`, and returns the tx-data the function produced.
pub const CallHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, f: Value, db_before: DbValue, args: []const Value) anyerror!Value,
};

/// A map tx-data form: a hash map or a sorted one, as Datomic takes
/// any `java.util.Map`.
fn isMapForm(v: Value) bool {
    return v.kind() == .persistent_map or v.kind() == .sorted_map;
}

/// Everything a transaction can fail with: its own errors, the
/// db-value's, the value contract's and the store's.
pub const Failure = Error || stack.Error || db_mod.Error || marshal.Error || db_mod.ErrorsOf(Minter.lookup) || db_mod.ErrorsOf(Minter.resolve) || db_mod.ErrorsOf(Minter.lookupName) || db_mod.ErrorsOf(Store.scan) || db_mod.ErrorsOf(Txn.getFromTree) || db_mod.ErrorsOf(Store.currentPayload) || db_mod.ErrorsOf(champ.mapEmpty);

pub const Options = struct {
    /// Overrides the connection's sync mode for this commit.
    sync: ?SyncMode = null,
    /// Wall-clock milliseconds for `:db/txInstant`; the clock when null.
    now_ms: ?i64 = null,
    /// Filled with what a failing step was looking at.
    fault: ?*Fault = null,
    /// Runs `:db.fn/call` forms; without it they are `error.TxFn`.
    hook: ?CallHook = null,
};

/// A tempid as the caller wrote it.
pub const TempidKey = union(enum) {
    string: []const u8,
    fixnum: i64,
};

pub const TempidBinding = struct {
    key: TempidKey,
    eid: u64,
};

pub const Report = struct {
    db_before: DbValue,
    db_after: DbValue,
    t: u64,
    /// User tempids only, in first-seen order.
    tempids: []TempidBinding,
    /// Every datom of the transaction in write order; the clock's
    /// `:db/txInstant`, when the tx-data asserts none, last.
    tx_data: []Datom,
};

// The tx-data shape the tests and the bench write in Zig: each op is
// lowered to the VM's tx-data (`lowerOps`) and normalised as any other.

/// An entity position in a Zig-level op.
pub const Entity = union(enum) {
    eid: u64,
    tempid: TempidKey,
    /// Lookup ref on a unique attribute.
    lookup: struct { a: AttrRef, v: Val },
    /// VM keyword id of an ident.
    ident: u32,
    /// The transaction entity.
    tx,
};

pub const AttrRef = union(enum) {
    id: u32,
    /// VM keyword id.
    ident: u32,
};

/// A value position in a Zig-level op.
pub const ValRef = union(enum) {
    /// Already typed; refs carry an eid.
    val: Val,
    /// A ref to an entity resolved like an entity position.
    entity: Entity,
    /// A keyword value by VM keyword id, minted as needed.
    keyword: u32,
    /// A VM value converted by the attribute's type.
    vm: Value,
};

pub const Op = union(enum) {
    add: struct { e: Entity, a: AttrRef, v: ValRef },
    retract: struct { e: Entity, a: AttrRef, v: ValRef },
    retract_attr: struct { e: Entity, a: AttrRef },
    retract_entity: Entity,
};

// =============================================================================
// Entry points
// =============================================================================

/// Transact Lisp tx-data (a vector or list of vector and map forms).
pub fn transact(conn: *Conn, arena: Allocator, tx_data: Value, options: Options) !Report {
    var ctx = try Ctx.begin(conn, arena, options);
    errdefer ctx.abort();
    try ctx.normaliseValue(tx_data);
    return ctx.run();
}

/// Transact Zig-level ops.
pub fn transactOps(conn: *Conn, arena: Allocator, ops: []const Op, options: Options) !Report {
    var heap = Heap.init(conn.gpa);
    defer heap.deinit();
    // A refused value as written lives in the heap that goes here.
    errdefer if (options.fault) |f| {
        f.given = null;
    };
    return transact(conn, arena, try lowerOps(conn, &heap, ops), options);
}

/// The VM tx-data `ops` stand for, built in `heap`. A typed value
/// becomes the VM value it reads back as (`Conn.valToValue`).
fn lowerOps(conn: *Conn, heap: *Heap, ops: []const Op) !Value {
    const txn = try conn.beginReadTxn();
    defer conn.endReadTxn(txn);
    const L = struct {
        conn: *Conn,
        heap: *Heap,
        txn: *Txn,

        fn kw(l: @This(), f: db_mod.FormKeyword) Value {
            return l.conn.interner.keywordValue(l.conn.form_keywords.get(f));
        }

        fn id(n: u64) !Value {
            return value.fromFixnum(@intCast(n)) orelse error.NoEntity;
        }

        fn attr(l: @This(), a: AttrRef) !Value {
            return switch (a) {
                .id => |n| id(n),
                .ident => |k| l.conn.interner.keywordValue(k),
            };
        }

        fn entity(l: @This(), e: Entity) !Value {
            return switch (e) {
                .eid => |n| id(n),
                .tempid => |t| switch (t) {
                    .string => |str| string_mod.fromBytes(l.heap, str),
                    .fixnum => |n| value.fromFixnum(n) orelse error.NoEntity,
                },
                .lookup => |r| vector_mod.fromSlice(l.heap, &.{ try l.attr(r.a), try l.conn.valToValue(l.txn, l.heap, r.v) }),
                .ident => |k| l.conn.interner.keywordValue(k),
                .tx => string_mod.fromBytes(l.heap, "datomic.tx"),
            };
        }

        fn val(l: @This(), v: ValRef) !Value {
            return switch (v) {
                .val => |x| l.conn.valToValue(l.txn, l.heap, x),
                .entity => |e| l.entity(e),
                .keyword => |k| l.conn.interner.keywordValue(k),
                .vm => |x| x,
            };
        }

        fn form(l: @This(), op: Op) !Value {
            return switch (op) {
                .add => |o| vector_mod.fromSlice(l.heap, &.{ l.kw(.@"db/add"), try l.entity(o.e), try l.attr(o.a), try l.val(o.v) }),
                .retract => |o| vector_mod.fromSlice(l.heap, &.{ l.kw(.@"db/retract"), try l.entity(o.e), try l.attr(o.a), try l.val(o.v) }),
                .retract_attr => |o| vector_mod.fromSlice(l.heap, &.{ l.kw(.@"db/retract"), try l.entity(o.e), try l.attr(o.a) }),
                .retract_entity => |e| vector_mod.fromSlice(l.heap, &.{ l.kw(.@"db/retractEntity"), try l.entity(e) }),
            };
        }
    };
    const l: L = .{ .conn = conn, .heap = heap, .txn = txn };
    const forms = try conn.gpa.alloc(Value, ops.len);
    defer conn.gpa.free(forms);
    for (ops, forms) |op, *f| f.* = try l.form(op);
    return vector_mod.fromSlice(heap, forms);
}

pub const ExciseReport = struct {
    report: Report,
    /// The entity whose datoms went.
    excised: u64,
    /// History rows removed.
    removed: u64,
};

/// Excise the datoms of entity `e` (a VM entity reference), under the
/// attribute `a` when given (NEXTOMIC.md §4 "Excision"): one
/// transaction whose only datom is its `:db/txInstant`, whose txlog
/// entry carries the marker, and inside whose write transaction the
/// datoms leave every tree and every txlog entry that held them.
pub fn excise(conn: *Conn, arena: Allocator, e: Value, a: ?Value, options: Options) !ExciseReport {
    var ctx = try Ctx.begin(conn, arena, options);
    errdefer ctx.abort();
    const ent = try ctx.entityFromVm(e);
    if (ent == .tempid) return ctx.malformed("excision takes an existing entity", .{ .given = e });
    const attr: ?*const Attr = if (a) |x| try ctx.attrFromVm(x) else null;
    ctx.excision = .{ .e = ent, .a = attr };
    try ctx.apply();
    const report = try ctx.commit();
    return .{ .report = report, .excised = ctx.excised[0], .removed = ctx.removed };
}

/// A speculative transaction (NEXTOMIC.md §6, row `with`): tx-data
/// applied inside the write transaction, which is held open, never
/// committed, and aborted by `finish`. `report.db_after` is a view of
/// the uncommitted state: its reads are read-only children of the held
/// transaction, so `q`, `entity`, `pull`, `datoms` and `txRange` see
/// the speculative datoms, while the connection's committed state,
/// ident cache and schema cache are untouched throughout. The write
/// lock is held until `finish`; meanwhile `transact` and `with` on the
/// connection, and any write through the view, are `error.Nested`.
/// The `With` and its scratch live in the caller's arena, which must
/// outlive `finish`. The view is the connection's (`Conn.view`), made by
/// its first `with` and reused, in a new life, by every later one, so
/// a db-value naming an earlier scope's view stays `error.Closed` and
/// a program running `with` in a loop holds one view.
pub const With = struct {
    ctx: Ctx,
    /// The view: the connection's store and interner, its own ident and
    /// schema caches, reads through `ctx.txn`. Closed by `finish`, freed
    /// with the connection.
    view: *Conn,
    report: Report,
    finished: bool = false,

    /// The uncommitted state at the speculative `t`.
    pub fn db(self: *With) DbValue {
        return self.report.db_after;
    }

    /// Close the view and abort the write transaction. Every `Read`
    /// opened on the view must be closed first: they are children of
    /// the transaction. Idempotent.
    pub fn finish(self: *With) void {
        if (self.finished) return;
        self.finished = true;
        self.view.close();
        self.view.overlay = null;
        self.ctx.conn.speculative = null;
        self.ctx.abort();
    }

    /// The protocol after normalisation: apply, then open the view over
    /// the held transaction.
    fn speculate(self: *With) !void {
        const conn = self.ctx.conn;
        try self.ctx.apply();
        const tempids = try self.ctx.userTempids();
        var idents = try conn.idents.clone();
        errdefer idents.deinit();
        const view = conn.view orelse blk: {
            const v = try conn.gpa.create(Conn);
            v.* = .{ .gpa = conn.gpa, .store = conn.store, .interner = conn.interner, .idents = undefined, .sync_mode = .none, .is_open = false, .store_closed = true, .owns_store = false };
            conn.view = v;
            break :blk v;
        };
        // The last scope's finish closed it once the reads it lent ended.
        if (!view.store_closed) return error.Busy;
        const gen = view.gen + 1;
        view.* = .{
            .gpa = conn.gpa,
            .store = conn.store,
            .interner = conn.interner,
            .form_keywords = conn.form_keywords,
            .idents = idents,
            .sync_mode = self.ctx.sync_mode,
            .is_open = true,
            .owns_store = false,
            .overlay = self.ctx.txn,
            .gen = gen,
        };
        self.view = view;
        self.report = .{
            .db_before = conn.at(self.ctx.now),
            .db_after = view.at(self.ctx.t),
            .t = self.ctx.t,
            .tempids = tempids,
            .tx_data = self.ctx.tx_data,
        };
        self.finished = false;
        conn.speculative = view;
    }
};

/// Apply Lisp tx-data speculatively.
pub fn with(conn: *Conn, arena: Allocator, tx_data: Value, options: Options) !*With {
    const self = try arena.create(With);
    self.ctx = try Ctx.begin(conn, arena, options);
    errdefer self.ctx.abort();
    try self.ctx.normaliseValue(tx_data);
    try self.speculate();
    return self;
}

/// Apply Zig-level ops speculatively.
pub fn withOps(conn: *Conn, arena: Allocator, ops: []const Op, options: Options) !*With {
    var heap = Heap.init(conn.gpa);
    defer heap.deinit();
    errdefer if (options.fault) |f| {
        f.given = null;
    };
    return with(conn, arena, try lowerOps(conn, &heap, ops), options);
}

// =============================================================================
// Internal representation
// =============================================================================

const Lookup = struct { attr: *const Attr, v: Val };

const Ent = union(enum) {
    eid: u64,
    /// Index into `Ctx.bindings`.
    tempid: u32,
    /// In the arena: the rare case, kept off the common op's size.
    lookup: *const Lookup,
};

const PVal = union(enum) {
    val: Val,
    tempid: u32,
    lookup: *const Lookup,
    /// A `:db/ident` value by VM keyword id, settled by `bindIdents`:
    /// the keyword may name the entity already, be fresh (minted for a
    /// new entity, or renaming an attribute entity), or belong to
    /// another entity (a conflict).
    ident: u32,
};

/// `[:db.fn/cas e a old new]`: assert `new` when the current value of
/// the card-one `(e a)` is `old` (absent when `old` is null). In the
/// arena: the rare case, kept off the common op's size.
/// `old` is matched, never minted; `written` is the old value as the
/// form wrote it, for the refusal to name one the store cannot spell.
const CasOp = struct { e: Ent, attr: *const Attr, old: ?PVal, written: Value, new: PVal };

/// An entity a unique assertion names while tempids are bound.
const Named = union(enum) { eid: u64, tempid: u32 };

const Add = struct { e: Ent, attr: *const Attr, v: PVal };

const ROp = union(enum) {
    add: Add,
    retract: struct { e: Ent, attr: *const Attr, v: PVal },
    retract_attr: struct { e: Ent, attr: *const Attr },
    retract_entity: Ent,
    cas: *const CasOp,
};

const Binding = struct {
    /// The tempid as the program wrote it, a string or a negative
    /// fixnum; null for a map form's own entity.
    written: ?Value,
    eid: ?u64 = null,
    /// Unified with another binding.
    alias: ?u32 = null,
};

/// Tempids by their key: a string's bytes, a fixnum's value.
const TempidContext = struct {
    pub fn hash(_: TempidContext, k: TempidKey) u64 {
        return switch (k) {
            .string => |b| std.hash.Wyhash.hash(0, b),
            .fixnum => |n| std.hash.Wyhash.hash(1, std.mem.asBytes(&n)),
        };
    }

    pub fn eql(_: TempidContext, a: TempidKey, b: TempidKey) bool {
        return switch (a) {
            .string => |x| b == .string and std.mem.eql(u8, x, b.string),
            .fixnum => |n| b == .fixnum and b.fixnum == n,
        };
    }
};

/// One datom the transaction will write.
const Pending = struct {
    e: u64,
    attr: *const Attr,
    v: Val,
    vbytes: []const u8,
    added: bool,
};

const EA = struct { e: u64, a: u32 };

/// Whether a value position asserts its value or matches a stored one.
const Use = enum { assert, match };

/// The id of no ident: ident ids start at 1.
const no_keyword: u32 = 0;

const Ctx = struct {
    conn: *Conn,
    arena: Allocator,
    txn: *Txn,
    now: u64,
    t: u64,
    now_ms: i64,
    sync_mode: SyncMode,
    schema: *Schema,
    minter: Minter,
    fault: ?*Fault,
    hook: ?CallHook,
    finished: bool = false,
    /// Nesting of the `:db.fn/call` whose result is being normalised.
    call_depth: u32 = 0,

    bindings: std.ArrayList(Binding) = .empty,
    /// The bindings of the tempids the program wrote, by key; a string
    /// key borrows the rooted tx-data.
    tempids: std.HashMapUnmanaged(TempidKey, u32, TempidContext, std.hash_map.default_max_load_percentage) = .empty,
    ops: std.ArrayList(ROp) = .empty,

    overlay: std.ArrayList(Pending) = .empty,
    /// EAVT key of a pending datom -> overlay index.
    facts: std.StringHashMapUnmanaged(u32) = .empty,
    /// (e a) -> value bytes of the card-one assertion seen so far,
    /// pending or already current.
    one_adds: std.AutoHashMapUnmanaged(EA, []const u8) = .empty,
    /// EAVT keys of the current datoms this transaction re-asserts: a
    /// claim on the datom that writes nothing, and that a retraction
    /// of the same datom in this transaction conflicts with.
    kept: std.StringHashMapUnmanaged(void) = .empty,
    /// `[a][v]` of a pending assertion -> e.
    av_adds: std.StringHashMapUnmanaged(u64) = .empty,
    /// `[a][v]` -> e for every unique assertion of the tx-data, whatever
    /// its place: what a lookup ref names when the committed state holds
    /// nothing under `(a v)`.
    av_claims: std.StringHashMapUnmanaged(Named) = .empty,

    next_eid: u64,
    /// The first user id this transaction mints: an entity at or past
    /// it has no committed datom, so expansion probes nothing for it.
    first_fresh: u64,
    eid_bumped: bool = false,
    /// Any datom on an attribute-partition entity.
    schema_touched: bool = false,
    /// Per-attribute change in current-datom count.
    deltas: std.AutoHashMapUnmanaged(u32, i64) = .empty,
    /// The attributes this transaction touches, one copy each
    /// (`attrCopy`).
    attrs: std.AutoHashMapUnmanaged(u32, *Attr) = .empty,
    /// The transaction's datoms in write order, built once by `write`.
    tx_data: []Datom = &.{},
    /// The excision this transaction records, if it is one.
    excision: ?struct { e: Ent, a: ?*const Attr } = null,
    /// The marker of this transaction's txlog entry: the excised entity.
    excised: []const u64 = &.{},
    /// History rows an excision removed.
    removed: u64 = 0,

    fn begin(conn: *Conn, arena: Allocator, options: Options) !Ctx {
        if (!conn.is_open) return error.Closed;
        if (conn.speculative != null or conn.overlay != null) return error.Nested;
        const sync_mode = options.sync orelse conn.sync_mode;
        // The file has one writer: a transaction function that
        // transacts on its own connection, or on another connection to
        // the same file, and a `transact!` inside a `db/*` write to the
        // file, meet the write transaction already open.
        const txn = conn.beginWriteTxn(sync_mode) catch |err| switch (err) {
            error.WriterActive => return error.Nested,
            else => return err,
        };
        errdefer {
            txn.abort();
            conn.taskDone();
        }
        const now = try conn.store.readT(txn);
        if (now + 1 >= key.t_limit) return error.DatabaseFull;
        const schema = try conn.schemaAt(txn, now, now);
        const next_eid = try conn.store.readNextEid(txn);
        return .{
            .conn = conn,
            .arena = arena,
            .txn = txn,
            .now = now,
            .t = now + 1,
            .now_ms = options.now_ms orelse store_mod.nowMillis(),
            .sync_mode = sync_mode,
            .schema = schema,
            .minter = try Minter.init(&conn.idents, txn, arena),
            .fault = options.fault,
            .hook = options.hook,
            .next_eid = next_eid,
            .first_fresh = next_eid,
        };
    }

    // ── faults ────────────────────────────────────────────────────

    /// `Unique`: `attr` already holds `v` on another entity.
    fn unique(self: *Ctx, attr: *const Attr, v: ?Val) error{Unique} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(attr.id), .value = v };
        return error.Unique;
    }

    /// `Conflict`: two claims about `(e a)` in one transaction.
    fn conflict(self: *Ctx, e: u64, a: u32) error{Conflict} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(a), .e = e };
        return error.Conflict;
    }

    /// `UnknownAttribute` for the attribute a program named as `attr`.
    fn unknownAttr(self: *Ctx, attr: Value) error{UnknownAttribute} {
        if (self.fault) |f| f.* = .{ .attr = attr };
        return error.UnknownAttribute;
    }

    /// `ValueType`: `v`, as the program wrote it, does not fit
    /// `attr`. A value inside it at fault already (a lookup ref's) is
    /// the one named.
    fn wrongType(self: *Ctx, attr: *const Attr, v: Value) error{ValueType} {
        if (self.fault) |f| if (f.given == null) {
            f.* = .{ .attr = self.attrValue(attr.id), .given = v, .value_type = attr.value_type };
        };
        return error.ValueType;
    }

    /// `ValueType`: keyword `k`, as the program wrote it, is not of
    /// the enumeration `attr` takes.
    fn notEnum(self: *Ctx, attr: *const Attr, k: Value) error{ValueType} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(attr.id), .given = k };
        return error.ValueType;
    }

    /// `NoEntity`: `v`, as the program wrote it, names no entity.
    fn noEntity(self: *Ctx, v: Value) error{NoEntity} {
        if (self.fault) |f| if (f.given == null) {
            f.* = .{ .given = v };
        };
        return error.NoEntity;
    }

    /// `NoEntity`: lookup ref `l` finds nothing, in the store or among
    /// this transaction's claims.
    fn noLookup(self: *Ctx, l: *const Lookup) error{NoEntity} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(l.attr.id), .value = l.v };
        return error.NoEntity;
    }

    /// What a refusal names besides its reason: the attribute at fault,
    /// and the form, reference or value as the program wrote it.
    const At = struct { attr: ?u32 = null, given: ?Value = null };

    /// `TxData` with the reason and what it names.
    fn malformed(self: *Ctx, message: []const u8, at: At) error{TxData} {
        if (self.fault) |f| f.* = .{ .message = message, .attr = if (at.attr) |a| self.attrValue(a) else null, .given = at.given };
        return error.TxData;
    }

    /// `TxFn` with the reason.
    fn txFn(self: *Ctx, message: []const u8) error{TxFn} {
        if (self.fault) |f| f.* = .{ .message = message };
        return error.TxFn;
    }

    /// `Cas`: `attr` holds `actual` where the form expected `expected`;
    /// `unseen` is the expected keyword when the store has never seen it.
    fn cas(self: *Ctx, attr: *const Attr, expected: ?Val, actual: ?Val, unseen: ?Value) error{Cas} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(attr.id), .cas = .{ .expected = expected, .actual = actual, .unseen = unseen } };
        return error.Cas;
    }

    /// `Schema`: the change to attribute `a` is refused for `message`,
    /// by entity `e` when one is at fault.
    fn schemaRefused(self: *Ctx, a: u32, e: ?u64, message: []const u8) error{Schema} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(a), .e = e, .message = message };
        return error.Schema;
    }

    /// The ident id of keyword `k`, minted when new; a name retired by
    /// a rename is malformed tx-data.
    fn mintKeyword(self: *Ctx, k: u32) !u32 {
        return self.minter.resolve(k) catch |err| self.identRefused(err);
    }

    /// A name the minter refuses is malformed tx-data.
    fn identRefused(self: *Ctx, err: anytype) (@TypeOf(err) || error{TxData}) {
        return switch (err) {
            error.RetiredIdent => self.malformed("a retired ident name is never reused", .{}),
            error.IdentTooLong => self.malformed(ident_too_long, .{}),
            else => err,
        };
    }

    /// A keyword value: an assertion mints a new keyword (a `:db/ident`
    /// value waits for `bindIdents`); a retraction or a lookup ref only
    /// matches, and a keyword the store has never seen is `no_keyword`,
    /// which matches nothing.
    fn keywordValue(self: *Ctx, attr: *const Attr, k: u32, use: Use) !PVal {
        if (use == .match) return .{ .val = .{ .keyword = (try self.minter.lookup(k)) orelse no_keyword } };
        if (attr.id == boot.ident) return .{ .ident = k };
        return .{ .val = .{ .keyword = try self.mintKeyword(k) } };
    }

    /// Whether keyword `k` may be asserted under attribute `a`: any
    /// keyword, but `:db/valueType`, `:db/cardinality` and `:db/unique`
    /// take their enumeration's bootstrap idents alone, so a typo mints
    /// nothing.
    fn enumAllows(self: *Ctx, a: u32, k: u32) !bool {
        const first: u32, const last: u32 = switch (a) {
            boot.value_type => .{ boot.type_long, boot.type_boolean },
            boot.cardinality => .{ boot.card_one, boot.card_many },
            boot.unique => .{ boot.unique_identity, boot.unique_value },
            else => return true,
        };
        const id = (try self.minter.lookup(k)) orelse return false;
        return id >= first and id <= last;
    }

    /// The attribute as a program names it: its ident, else its id.
    fn attrValue(self: *Ctx, a: u32) ?Value {
        const k = (self.minter.keywordOf(a) catch null) orelse return value.fromFixnum(a);
        return self.conn.interner.keywordValue(k);
    }

    fn abort(self: *Ctx) void {
        if (self.finished) return;
        self.finished = true;
        self.txn.abort();
        self.conn.taskDone();
    }

    // ── attributes ────────────────────────────────────────────────

    /// The transaction's copy of attribute `id`, made on first use:
    /// every op and pending datom under the attribute points at it, so
    /// a flag the schema step turns on reaches all of them at once.
    fn attrCopy(self: *Ctx, id: u32) !?*Attr {
        if (self.attrs.get(id)) |c| return c;
        const a = self.schema.attr(id) orelse return null;
        const c = try self.arena.create(Attr);
        c.* = a.*;
        try self.attrs.put(self.arena, id, c);
        return c;
    }

    fn attrById(self: *Ctx, id: u32) !*const Attr {
        return (try self.attrCopy(id)) orelse self.unknownAttr(value.fromFixnum(id) orelse unreachable);
    }

    fn attrByIntern(self: *Ctx, intern_id: u32) !*const Attr {
        const id = (try self.minter.lookup(intern_id)) orelse return self.unknownAttr(self.conn.interner.keywordValue(intern_id));
        return (try self.attrCopy(id)) orelse self.unknownAttr(self.conn.interner.keywordValue(intern_id));
    }

    // ── entity ids ────────────────────────────────────────────────

    /// An explicit entity id, as an entity or a ref value, must have been
    /// handed out by its partition's allocator: a user id below the next
    /// user id, an attribute or ident id below the next ident id, a
    /// transaction entity from bootstrap (`t = 1`) to this transaction.
    /// Anything else
    /// would collide with an id minted later: `error.NoEntity`.
    fn checkEid(self: *Ctx, id: u64) !u64 {
        if (id == 0 or id > key.id_max) return error.NoEntity;
        if (key.txOfEntity(id)) |t| return if (t > 0 and t <= self.t) id else error.NoEntity;
        if (key.isAttrPartition(id)) return if (id < self.minter.next_aid) id else error.NoEntity;
        return if (id < self.next_eid) id else error.NoEntity;
    }

    // ── tempids ───────────────────────────────────────────────────

    /// The binding of tempid `written`, whose key is `k`.
    fn tempid(self: *Ctx, written: Value, k: TempidKey) !u32 {
        const g = try self.tempids.getOrPut(self.arena, k);
        if (!g.found_existing) {
            g.value_ptr.* = @intCast(self.bindings.items.len);
            try self.bindings.append(self.arena, .{ .written = written });
        }
        return g.value_ptr.*;
    }

    fn internalTempid(self: *Ctx) !u32 {
        const i: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.arena, .{ .written = null });
        return i;
    }

    fn root(self: *Ctx, i: u32) u32 {
        var cur = i;
        while (self.bindings.items[cur].alias) |a| cur = a;
        return cur;
    }

    /// Bind tempid `i` to `eid` through attribute `a`; a tempid bound to
    /// another entity already is a conflict on that entity's `a`.
    fn bind(self: *Ctx, i: u32, eid: u64, a: u32) !void {
        const r = self.root(i);
        const b = &self.bindings.items[r];
        if (b.eid) |cur| {
            if (cur != eid) return self.conflict(cur, a);
            return;
        }
        b.eid = eid;
    }

    /// Tempids `i` and `j` name one entity, by their claims on `a`.
    fn unify(self: *Ctx, i: u32, j: u32, a: u32) !void {
        const ri = self.root(i);
        const rj = self.root(j);
        if (ri == rj) return;
        const bi = &self.bindings.items[ri];
        const bj = &self.bindings.items[rj];
        if (bi.eid != null and bj.eid != null and bi.eid.? != bj.eid.?) return self.conflict(bi.eid.?, a);
        if (bi.eid == null) bi.eid = bj.eid;
        bj.alias = ri;
    }

    fn eidOfTempid(self: *Ctx, i: u32) u64 {
        return self.bindings.items[self.root(i)].eid.?;
    }

    fn lookupRef(self: *Ctx, attr: *const Attr, v: Val) !*const Lookup {
        const l = try self.arena.create(Lookup);
        l.* = .{ .attr = attr, .v = v };
        return l;
    }

    // ── normalisation from VM values ──────────────────────────────

    /// The form keyword `v` is, if any.
    fn formKeyword(self: *Ctx, v: Value) ?db_mod.FormKeyword {
        if (v.kind() != .keyword) return null;
        for (std.enums.values(db_mod.FormKeyword)) |f| {
            if (self.conn.form_keywords.get(f) == v.asKeywordId()) return f;
        }
        return null;
    }

    fn normaliseValue(self: *Ctx, tx_data: Value) anyerror!void {
        switch (tx_data.kind()) {
            .persistent_vector => {
                try self.ops.ensureTotalCapacityPrecise(self.arena, vector_mod.count(tx_data));
                var it = vector_mod.Cursor.init(tx_data);
                while (it.next()) |form| try self.normaliseForm(form);
            },
            .list => {
                try self.ops.ensureTotalCapacityPrecise(self.arena, list_mod.count(tx_data));
                var it = list_mod.Cursor.init(tx_data);
                while (it.next()) |form| try self.normaliseForm(form);
            },
            else => return self.malformed("tx-data is a vector or a list of forms", .{}),
        }
    }

    fn normaliseForm(self: *Ctx, form: Value) anyerror!void {
        if (isMapForm(form)) {
            _ = try self.normaliseMap(form);
            return;
        }
        const f = (try self.listForm(form)) orelse return self.malformed("a form is a vector, a list or a map", .{ .given = form });
        if (f.len < 2) return self.malformed("a list form is [op e ...]", .{ .given = form });
        const op = f[0];
        const unknown = "unknown op; one of :db/add, :db/retract, :db/retractEntity, :db.fn/call, :db.fn/cas";
        switch (self.formKeyword(op) orelse return self.malformed(unknown, .{ .given = op })) {
            .@"db/id" => return self.malformed(unknown, .{ .given = op }),
            .@"db.fn/call" => try self.normaliseCall(f),
            .@"db.fn/cas" => {
                if (f.len != 5) return self.malformed(":db.fn/cas is [:db.fn/cas e a old new]", .{ .given = form });
                const attr = try self.attrFromVm(f[2]);
                if (attr.id == boot.ident) return self.malformed(":db.fn/cas never renames; assert the new :db/ident", .{ .attr = attr.id });
                const e = try self.entityFromVm(f[1]);
                const op_cas = try self.arena.create(CasOp);
                op_cas.* = .{ .e = e, .attr = attr, .old = if (f[3].isNil()) null else try self.valueFromVm(attr, f[3], .match), .written = f[3], .new = try self.valueFromVm(attr, f[4], .assert) };
                try self.ops.append(self.arena, .{ .cas = op_cas });
            },
            .@"db/add" => {
                if (f.len != 4) return self.malformed(":db/add is [:db/add e a v]", .{ .given = form });
                const attr = try self.attrFromVm(f[2]);
                const e = try self.entityFromVm(f[1]);
                try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, f[3], .assert) } });
            },
            .@"db/retract" => {
                if (f.len != 3 and f.len != 4) return self.malformed(":db/retract is [:db/retract e a] or [:db/retract e a v]", .{ .given = form });
                const attr = try self.attrFromVm(f[2]);
                const e = try self.entityFromVm(f[1]);
                if (f.len == 3) {
                    try self.ops.append(self.arena, .{ .retract_attr = .{ .e = e, .attr = attr } });
                } else {
                    try self.ops.append(self.arena, .{ .retract = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, f[3], .match) } });
                }
            },
            .@"db/retractEntity" => {
                if (f.len != 2) return self.malformed(":db/retractEntity is [:db/retractEntity e]", .{ .given = form });
                try self.ops.append(self.arena, .{ .retract_entity = try self.entityFromVm(f[1]) });
            },
        }
    }

    /// The elements of a list form `[op e ...]`, which, as in Datomic,
    /// is any sequential form: a vector or a list (a lazy seq arrives
    /// as a list, §6). A vector's own storage when one chunk holds them
    /// all, else a copy in the arena; null for any other kind.
    fn listForm(self: *Ctx, form: Value) !?[]const Value {
        switch (form.kind()) {
            .persistent_vector => if (vector_mod.count(form) > 0) {
                const chunk = vector_mod.chunkFrom(form, 0);
                if (chunk.len == vector_mod.count(form)) return chunk;
            },
            .list => {},
            else => return null,
        }
        return marshal.collection(self.arena, form);
    }

    /// `[:db.fn/call f arg ...]`, its elements `form`: call `f` with
    /// `db-before` and the arguments, then normalise the tx-data it
    /// returns in place of the form, where further calls may nest to
    /// `max_call_depth`. The function value is called, never stored:
    /// only the datoms it returns reach the trees and the txlog. A nil
    /// result is no tx-data.
    fn normaliseCall(self: *Ctx, form: []const Value) anyerror!void {
        try stack.check();
        const hook = self.hook orelse return self.txFn("transaction functions run inside transact! and with only");
        const f = form[1];
        switch (f.kind()) {
            .function, .native_fn, .symbol => {},
            else => return self.malformed(":db.fn/call takes a function or a symbol naming one", .{ .given = f }),
        }
        if (self.call_depth >= max_call_depth) return self.txFn(std.fmt.comptimePrint("transaction functions nest past {d} calls", .{max_call_depth}));
        const db_before = self.conn.at(self.now);
        const result = try hook.call(hook.ctx, f, db_before, form[2..]);
        if (result.isNil()) return;
        self.call_depth += 1;
        defer self.call_depth -= 1;
        try self.normaliseValue(result);
    }

    /// A map form's entity, and whether the map names it: by `:db/id`
    /// or a unique attribute.
    const MapEnt = struct { ent: Ent, identified: bool };

    /// Expand a map form into adds; returns the entity. A key
    /// `:ns/_attr` is a reverse ref: its value names the entities that
    /// refer to this one through `:ns/attr`.
    fn normaliseMap(self: *Ctx, m: Value) Failure!MapEnt {
        // Nested map forms recurse here, one frame per level.
        try stack.check();
        var ent: ?Ent = null;
        var it = sorted.MapEntries.init(m);
        while (it.next()) |entry| {
            if (self.formKeyword(entry.key) == .@"db/id") {
                ent = try self.entityFromVm(entry.value);
                break;
            }
        }
        const e: Ent = ent orelse .{ .tempid = try self.internalTempid() };
        var identified = ent != null;

        var it2 = sorted.MapEntries.init(m);
        while (it2.next()) |entry| {
            if (self.formKeyword(entry.key) == .@"db/id") continue;
            const v = entry.value;
            if (try self.reverseAttr(entry.key)) |attr| {
                if (try self.elementsOf(v, true)) |els| {
                    for (els) |el| try self.addReverse(e, attr, el);
                } else try self.addReverse(e, attr, v);
                continue;
            }
            const attr = try self.attrFromVm(entry.key);
            if (attr.unique != .none) identified = true;
            if (attr.many()) if (try self.elementsOf(v, attr.value_type == .ref)) |els| {
                for (els) |el| try self.addFromVm(e, attr, el);
                continue;
            };
            try self.addFromVm(e, attr, v);
        }
        return .{ .ent = e, .identified = identified };
    }

    /// The values the collection `v` stands for, or null when `v` is one
    /// value: not a collection, or under a ref attribute (`ref`) a
    /// lookup ref.
    fn elementsOf(self: *Ctx, v: Value, ref: bool) !?[]Value {
        if (ref and try self.isLookupRef(v)) return null;
        return marshal.collection(self.arena, v);
    }

    /// The ref attribute a `:ns/_attr` key reverses, or null for any
    /// other key.
    fn reverseAttr(self: *Ctx, k: Value) !?*const Attr {
        if (k.kind() != .keyword) return null;
        const name = self.conn.interner.keywordName(k.asKeywordId());
        if (!reverseName(name)) return null;
        const slash = std.mem.findScalar(u8, name, '/').?;
        const forward = try std.mem.concat(self.arena, u8, &.{ name[0 .. slash + 1], name[slash + 2 ..] });
        const id = (try self.minter.lookupName(forward)) orelse return self.unknownAttr(k);
        const attr = (try self.attrCopy(id)) orelse return self.unknownAttr(k);
        if (attr.value_type != .ref) return self.malformed("a reverse ref needs a ref attribute", .{ .attr = attr.id });
        return attr;
    }

    /// `ns/_name`, the reverse of `ns/name` in a map form or a pull
    /// pattern, which therefore names no attribute.
    fn reverseName(name: []const u8) bool {
        const slash = std.mem.findScalar(u8, name, '/') orelse return false;
        return slash + 1 < name.len and name[slash + 1] == '_';
    }

    /// `:nextomic/schema` when attribute `a` would be known by a
    /// reverse-ref name.
    fn checkAttrName(self: *Ctx, a: u32, k: u32) !void {
        if (reverseName(self.conn.interner.keywordName(k))) return self.schemaRefused(a, null, "an attribute name never starts with _, which marks a reverse ref");
    }

    /// `[referrer attr e]` for one value under a reverse ref: an entity,
    /// or a map form of one.
    fn addReverse(self: *Ctx, e: Ent, attr: *const Attr, referrer: Value) Failure!void {
        const from = if (isMapForm(referrer)) (try self.normaliseMap(referrer)).ent else try self.entityFromVm(referrer);
        try self.ops.append(self.arena, .{ .add = .{ .e = from, .attr = attr, .v = pvalOf(e) } });
    }

    fn pvalOf(e: Ent) PVal {
        return switch (e) {
            .eid => |id| .{ .val = .{ .ref = id } },
            .tempid => |i| .{ .tempid = i },
            .lookup => |l| .{ .lookup = l },
        };
    }

    /// Under a ref attribute a two-element vector whose first element is
    /// a keyword naming an attribute is a lookup ref, one value; a
    /// collection of lookup refs is a vector of such vectors.
    fn isLookupRef(self: *Ctx, v: Value) !bool {
        if (v.kind() != .persistent_vector or vector_mod.count(v) != 2) return false;
        const head = vector_mod.nth(v, 0);
        if (head.kind() != .keyword) return false;
        const id = (try self.minter.lookup(head.asKeywordId())) orelse return false;
        return self.schema.attr(id) != null;
    }

    /// One value under `attr`. A nested map under a ref attribute is an
    /// entity; unless the attribute is a component it must carry an
    /// identity, or nothing could ever reach it.
    fn addFromVm(self: *Ctx, e: Ent, attr: *const Attr, v: Value) Failure!void {
        if (isMapForm(v) and attr.value_type == .ref) {
            const nested = try self.normaliseMap(v);
            if (!attr.component and !nested.identified) return self.malformed("a nested map under a non-component ref needs :db/id or a unique attribute", .{ .attr = attr.id });
            try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = pvalOf(nested.ent) } });
            return;
        }
        try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, v, .assert) } });
    }

    fn attrFromVm(self: *Ctx, v: Value) !*const Attr {
        return switch (v.kind()) {
            .keyword => self.attrByIntern(v.asKeywordId()),
            .fixnum => blk: {
                const n = v.asFixnum();
                if (n <= 0 or n > std.math.maxInt(u32)) return self.unknownAttr(v);
                break :blk self.attrById(@intCast(n));
            },
            else => self.malformed("an attribute is a keyword or an id", .{ .given = v }),
        };
    }

    fn entityFromVm(self: *Ctx, v: Value) Failure!Ent {
        return self.convertEntity(v) catch |err| switch (err) {
            error.NoEntity => self.noEntity(v),
            else => err,
        };
    }

    fn convertEntity(self: *Ctx, v: Value) Failure!Ent {
        // A lookup ref's value may be a lookup ref: one frame per level.
        try stack.check();
        switch (v.kind()) {
            .fixnum => {
                const n = v.asFixnum();
                if (n < 0) return .{ .tempid = try self.tempid(v, .{ .fixnum = n }) };
                return .{ .eid = try self.checkEid(@intCast(n)) };
            },
            .string => {
                const s = string_mod.asBytes(v);
                if (std.mem.eql(u8, s, "datomic.tx")) return .{ .eid = key.txEntity(self.t) };
                return .{ .tempid = try self.tempid(v, .{ .string = s }) };
            },
            .keyword => return .{ .eid = (try self.minter.lookup(v.asKeywordId())) orelse return error.NoEntity },
            .persistent_vector => {
                if (vector_mod.count(v) != 2) return self.malformed("a lookup ref is [attr value]", .{ .given = v });
                const attr = try self.attrFromVm(vector_mod.nth(v, 0));
                if (attr.unique == .none) return self.malformed("a lookup ref needs a unique attribute", .{ .attr = attr.id });
                const lv = try self.valueFromVm(attr, vector_mod.nth(v, 1), .match);
                if (lv != .val) return self.malformed("a lookup ref value is a plain value", .{ .attr = attr.id, .given = vector_mod.nth(v, 1) });
                return .{ .lookup = try self.lookupRef(attr, lv.val) };
            },
            else => return self.malformed("an entity is an id, a tempid, a lookup ref, an ident or \"datomic.tx\"", .{ .given = v }),
        }
    }

    /// Convert a VM value by the attribute's type.
    fn valueFromVm(self: *Ctx, attr: *const Attr, v: Value, use: Use) Failure!PVal {
        return self.convertValue(attr, v, use) catch |err| switch (err) {
            error.ValueType => self.wrongType(attr, v),
            else => err,
        };
    }

    fn convertValue(self: *Ctx, attr: *const Attr, v: Value, use: Use) Failure!PVal {
        switch (attr.value_type) {
            .keyword => {
                if (v.kind() != .keyword) return error.ValueType;
                if (use == .assert and !try self.enumAllows(attr.id, v.asKeywordId())) return self.notEnum(attr, v);
                return self.keywordValue(attr, v.asKeywordId(), use);
            },
            .ref => {
                // A malformed lookup ref is malformed tx-data here as in
                // entity position; a value of no entity kind is the
                // wrong type.
                switch (v.kind()) {
                    .fixnum, .string, .keyword, .persistent_vector => {},
                    else => return error.ValueType,
                }
                return pvalOf(try self.entityFromVm(v));
            },
            else => {
                // The arena keeps a string's bytes past the tx-data.
                return .{ .val = switch (try marshal.scalarVal(attr.value_type, v)) {
                    .string => |b| .{ .string = try self.arena.dupe(u8, b) },
                    .bytes => |b| .{ .bytes = try self.arena.dupe(u8, b) },
                    else => |x| x,
                } };
            },
        }
    }

    // ── the pipeline ──────────────────────────────────────────────

    fn run(self: *Ctx) !Report {
        try self.apply();
        return self.commit();
    }

    /// Everything after normalisation and before the commit, leaving
    /// the write transaction open with the datoms, txlog and counters
    /// written.
    fn apply(self: *Ctx) !void {
        try self.bindIdents();
        try self.bindTempids();
        try self.expandAll();
        try self.txInstant();
        try self.checkUnique();
        try self.applySchema();
        if (self.excision) |x| {
            // Resolved before the write, which marks the entry with it.
            const e = try self.resolveEnt(x.e);
            if (e < key.user_partition_start or e >= key.user_partition_end) return self.malformed("excision takes a user entity", .{});
            self.excised = try self.arena.dupe(u64, &.{e});
        }
        try self.write();
        if (self.excision) |x| try self.runExcision(self.excised[0], if (x.a) |attr| attr.id else null);
    }

    /// Remove the datoms of `e` (under `a`) from the trees and the
    /// txlog entries that held them, and settle the attribute counts.
    fn runExcision(self: *Ctx, e: u64, a: ?u32) !void {
        const store = self.conn.store;
        const out = try excise_mod.removeDatoms(store, self.txn, self.arena, self.schema, e, a);
        self.removed = out.removed;
        var it = out.counts.iterator();
        while (it.next()) |entry| {
            const cur = try store.attrCount(self.txn, entry.key_ptr.*);
            if (cur < entry.value_ptr.*) return error.Corrupted;
            try store.writeAttrCount(self.txn, entry.key_ptr.*, cur - entry.value_ptr.*);
            const g = try self.deltas.getOrPut(self.arena, entry.key_ptr.*);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* -= @intCast(entry.value_ptr.*);
        }
        try excise_mod.rewriteTxlog(store, self.txn, self.arena, out.ts, e, a, .{ .ctx = @ptrCast(self), .attrType = &attrTypeOf, .payload = &noPayload });
    }

    /// A rewrite keeps an out-of-line value's digest and reads no
    /// payload.
    fn noPayload(_: *anyopaque, _: u64, _: u32, _: []const u8, _: u64, _: bool) anyerror![]const u8 {
        return error.Corrupted;
    }

    fn attrTypeOf(ctx: *anyopaque, a: u32) anyerror!?key.ValueType {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const attr = self.schema.attr(a) orelse return null;
        return attr.value_type;
    }

    /// Commit, then publish the mints and update the schema cache, and
    /// report. Everything that can fail (the report's tempid bindings,
    /// the tx-data, room in the ident cache) is prepared before the
    /// commit, so every commit that stands reaches the caches. One
    /// error comes after a commit stands: `DurabilityUnknown`, a
    /// published commit whose meta page did not sync, which reaches the
    /// caches and is then reported; emdb ends its transaction with the
    /// abort the caller's `errdefer` runs. After it, or any failed sync
    /// of the file, a commit that would sync is `SyncFailed` and
    /// publishes nothing (`db.StoreFile.syncFailed`).
    fn commit(self: *Ctx) !Report {
        const db_before = self.conn.at(self.now);
        const tempids = try self.userTempids();
        try self.minter.reserveCache();
        self.conn.store.commit(self.txn) catch |err| {
            if (err == error.DurabilityUnknown) self.published();
            return err;
        };
        self.finished = true;
        self.conn.taskDone();
        self.published();
        return .{
            .db_before = db_before,
            .db_after = self.conn.at(self.t),
            .t = self.t,
            .tempids = tempids,
            .tx_data = self.tx_data,
        };
    }

    /// Bring the ident and schema caches up to a commit that stands.
    fn published(self: *Ctx) void {
        self.minter.commitCache();
        if (self.schema_touched) {
            self.conn.dropSchema();
        } else if (self.conn.schema_cache) |s| {
            s.basis = self.t;
            var it = self.deltas.iterator();
            while (it.next()) |e| {
                if (s.attrs.getPtr(e.key_ptr.*)) |a| {
                    const n: i64 = @as(i64, @intCast(a.count)) + e.value_ptr.*;
                    a.count = @intCast(@max(n, 0));
                }
            }
        }
    }

    // ── idents ────────────────────────────────────────────────────

    /// Settle every `:db/ident` value (NEXTOMIC.md §3 step 5). An
    /// assertion on a tempid mints the keyword when it is new, and the
    /// tempid takes the ident's id. On an entity that exists: a keyword
    /// naming it already is a no-op, one naming another entity a
    /// conflict, and a fresh keyword on an attribute-partition entity
    /// renames it, retiring the old name. Only an assertion carries one:
    /// a retraction matches its keyword (`keywordValue`), and a cas on
    /// `:db/ident` is refused as it is read.
    fn bindIdents(self: *Ctx) !void {
        for (self.ops.items) |*op| {
            if (op.* != .add or op.add.attr.id != boot.ident) continue;
            const slot = &op.add.v;
            if (slot.* == .ident) {
                const id = try self.identId(op.add.e, slot.ident);
                slot.* = .{ .val = .{ .keyword = id } };
            }
            // The ident names the entity: a tempid's id is the ident's.
            if (op.add.e == .tempid) try self.bind(op.add.e.tempid, slot.val.keyword, boot.ident);
        }
    }

    /// The id keyword `k` names as the `:db/ident` of entity `ent`:
    /// minted for a tempid when new, renaming an attribute or ident
    /// entity the keyword does not name yet.
    fn identId(self: *Ctx, ent: Ent, k: u32) !u32 {
        const existing = try self.minter.lookup(k);
        const eid: u64 = switch (ent) {
            .eid => |id| id,
            .tempid => return existing orelse try self.mintKeyword(k),
            // Against the committed state alone: idents settle before
            // the transaction's unique assertions.
            .lookup => |l| (try self.probeAvet(l.attr.id, try key.valBytes(self.arena, l.v))) orelse return self.noLookup(l),
        };
        if (existing) |x| return if (x == eid) x else self.conflict(eid, boot.ident);
        if (!key.isAttrPartition(eid)) return self.conflict(eid, boot.ident);
        // The store and every build know the bootstrap idents by their
        // ids and names alike (§2.4).
        if (eid < boot.next_aid) return self.schemaRefused(@intCast(eid), null, "a bootstrap ident is never renamed");
        // Two renames of one entity are two card-one values of its
        // `:db/ident`; the first would retire a name no commit ever
        // showed.
        if (self.minter.renamed.contains(@intCast(eid))) return self.conflict(eid, boot.ident);
        if (self.schema.attr(@intCast(eid)) != null) try self.checkAttrName(@intCast(eid), k);
        self.minter.rename(@intCast(eid), k) catch |err| return self.identRefused(err);
        return @intCast(eid);
    }

    // ── tempids ───────────────────────────────────────────────────

    /// Tempids (NEXTOMIC.md §3 step 3), in one fixpoint over the unique
    /// assertions. Each settles once its entity and value are known:
    /// `(a v)` then names its entity, for a lookup ref anywhere in the
    /// transaction, and a unique identity a tempid claims upserts to
    /// the committed holder of `(a v)` and unifies the tempids claiming
    /// it. Each round settles what the last one bound. Then claims on
    /// entities the transaction creates unify by their value, the
    /// remaining tempids take fresh eids, and every unique assertion
    /// settles.
    fn bindTempids(self: *Ctx) !void {
        var pending: std.ArrayList(usize) = .empty;
        for (self.ops.items, 0..) |op, i| {
            if (op == .add and op.add.attr.unique != .none and op.add.attr.id != boot.ident) try pending.append(self.arena, i);
        }
        var identities: std.StringHashMapUnmanaged(u32) = .empty;
        try self.settleAll(&pending, &identities);
        var by_target: std.AutoHashMapUnmanaged(struct { a: u32, root: u32 }, u32) = .empty;
        for (pending.items) |i| {
            const op = self.ops.items[i].add;
            if (op.attr.unique != .identity or op.e != .tempid or op.v != .tempid) continue;
            const g = try by_target.getOrPut(self.arena, .{ .a = op.attr.id, .root = self.root(op.v.tempid) });
            if (g.found_existing) try self.unify(op.e.tempid, g.value_ptr.*, op.attr.id) else g.value_ptr.* = op.e.tempid;
        }
        try self.freshEids();
        try self.settleAll(&pending, &identities);
    }

    /// Settle the `pending` unique assertions, round by round until a
    /// round settles none.
    fn settleAll(self: *Ctx, pending: *std.ArrayList(usize), identities: *std.StringHashMapUnmanaged(u32)) !void {
        var progress = true;
        while (progress) {
            progress = false;
            var i: usize = 0;
            while (i < pending.items.len) {
                if (try self.settle(&self.ops.items[pending.items[i]].add, identities)) {
                    _ = pending.swapRemove(i);
                    progress = true;
                } else i += 1;
            }
        }
    }

    /// Settle one unique assertion once its entity and value are known;
    /// false while either waits for a binding or names nothing yet. A
    /// lookup ref among them becomes the entity it names.
    fn settle(self: *Ctx, op: *Add, identities: *std.StringHashMapUnmanaged(u32)) !bool {
        if (op.e == .lookup) {
            const named = (try self.lookupNamed(op.e.lookup)) orelse return false;
            op.e = entOf(named);
        }
        if (op.v == .lookup) {
            const named = (try self.lookupNamed(op.v.lookup)) orelse return false;
            op.v = pvalOf(entOf(named));
        }
        const v: Val = switch (op.v) {
            .val => |x| x,
            .tempid => |t| .{ .ref = self.bindings.items[self.root(t)].eid orelse return false },
            .lookup, .ident => unreachable,
        };
        const vb = try key.valBytes(self.arena, v);
        const av = try self.avKey(op.attr.id, vb);
        if (op.attr.unique == .identity and op.e == .tempid) {
            const g = try identities.getOrPut(self.arena, av);
            if (g.found_existing) try self.unify(op.e.tempid, g.value_ptr.*, op.attr.id) else g.value_ptr.* = op.e.tempid;
            if (try self.probeAvet(op.attr.id, vb)) |eid| try self.bind(op.e.tempid, eid, op.attr.id);
        }
        const g = try self.av_claims.getOrPut(self.arena, av);
        if (!g.found_existing) g.value_ptr.* = switch (op.e) {
            .eid => |id| .{ .eid = id },
            .tempid => |t| .{ .tempid = t },
            .lookup => unreachable,
        };
        return true;
    }

    /// Fresh eids for the tempids no identity bound, each the entity of
    /// an assertion: a tempid only in value positions or retractions
    /// would name an entity with no datoms.
    fn freshEids(self: *Ctx) !void {
        const named = try self.arena.alloc(bool, self.bindings.items.len);
        @memset(named, false);
        for (self.ops.items) |op| {
            const e: Ent = switch (op) {
                .add => |o| o.e,
                .cas => |c| c.e,
                else => continue,
            };
            if (e == .tempid) named[self.root(e.tempid)] = true;
        }
        for (self.bindings.items, named) |*b, n| {
            if (b.alias != null or b.eid != null) continue;
            if (!n) return self.malformed("a tempid no assertion stands on names no entity", .{ .given = b.written });
            if (self.next_eid >= key.user_partition_end) return error.DatabaseFull;
            b.eid = self.next_eid;
            self.next_eid += 1;
            self.eid_bumped = true;
        }
    }

    /// The entity a lookup ref names so far: the committed holder of
    /// its `(a v)`, else the entity a settled unique assertion of this
    /// transaction puts `(a v)` on; null when neither exists yet.
    fn lookupNamed(self: *Ctx, l: *const Lookup) !?Named {
        const vb = try key.valBytes(self.arena, l.v);
        if (try self.probeAvet(l.attr.id, vb)) |e| return .{ .eid = e };
        return self.av_claims.get(try self.avKey(l.attr.id, vb));
    }

    fn entOf(n: Named) Ent {
        return switch (n) {
            .eid => |id| .{ .eid = id },
            .tempid => |t| .{ .tempid = t },
        };
    }

    fn avKey(self: *Ctx, a: u32, vbytes: []const u8) ![]u8 {
        const k = try self.arena.alloc(u8, key.attr_len + vbytes.len);
        key.writeAttr(k[0..key.attr_len], a);
        @memcpy(k[key.attr_len..], vbytes);
        return k;
    }

    /// The entity holding `(a v)` in the committed AVET tree, or null.
    /// The first key under the prefix may carry a longer value whose
    /// encoding continues past the terminator of `vbytes` (an escaped
    /// NUL), so the value section is compared exactly.
    fn probeAvet(self: *Ctx, a: u32, vbytes: []const u8) !?u64 {
        const prefix = try key.prefixBytes(self.arena, .avet, .{ .a = a, .v = vbytes });
        var s = try Store.scan(self.txn, self.conn.store.trees.cur(.avet), prefix);
        while (try s.next()) |kv| {
            const parts = try key.unpackKey(.avet, false, kv.key);
            if (std.mem.eql(u8, parts.v, vbytes)) return parts.e;
        }
        return null;
    }

    /// The entity a lookup ref names once every tempid is bound.
    fn lookupEid(self: *Ctx, l: *const Lookup) !?u64 {
        return switch ((try self.lookupNamed(l)) orelse return null) {
            .eid => |id| id,
            .tempid => |t| self.eidOfTempid(t),
        };
    }

    fn resolveEnt(self: *Ctx, e: Ent) !u64 {
        return switch (e) {
            .eid => |id| id,
            .tempid => |i| self.eidOfTempid(i),
            .lookup => |l| (try self.lookupEid(l)) orelse self.noLookup(l),
        };
    }

    fn resolveVal(self: *Ctx, v: PVal) !Val {
        return switch (v) {
            .val => |x| x,
            .tempid => |i| .{ .ref = self.eidOfTempid(i) },
            .lookup => |l| .{ .ref = (try self.lookupEid(l)) orelse return self.noLookup(l) },
            .ident => unreachable,
        };
    }

    /// Unique attributes (NEXTOMIC.md §3 step 4) over the whole
    /// expansion, so the order of the forms never matters: no two
    /// entities assert one `(a v)`, and an entity other than the
    /// asserting one holds it in the committed state only when the
    /// transaction retracts it there.
    fn checkUnique(self: *Ctx) !void {
        for (self.overlay.items) |p| {
            if (!p.added or p.attr.unique == .none) continue;
            if (self.av_adds.get(try self.avKey(p.attr.id, p.vbytes))) |e| if (e != p.e) return self.unique(p.attr, p.v);
            const other = (try self.probeAvet(p.attr.id, p.vbytes)) orelse continue;
            if (other != p.e and !try self.retracts(other, p.attr.id, p.vbytes)) return self.unique(p.attr, p.v);
        }
    }

    /// Does the transaction retract the committed datom `(e a v)`?
    fn retracts(self: *Ctx, e: u64, a: u32, vbytes: []const u8) !bool {
        const fk = try key.keyBytes(self.arena, .eavt, e, a, vbytes, null);
        const i = self.facts.get(fk) orelse return false;
        return !self.overlay.items[i].added;
    }

    // ── expand ────────────────────────────────────────────────────

    fn expandAll(self: *Ctx) !void {
        // Room for one datom per op and the transaction's instant; a
        // card-one overwrite or a cascade grows past it.
        const n = self.ops.items.len + 1;
        try self.overlay.ensureTotalCapacityPrecise(self.arena, n);
        try self.facts.ensureTotalCapacity(self.arena, @intCast(n));
        for (self.ops.items) |op| {
            switch (op) {
                .add => |o| try self.expandAdd(try self.resolveEnt(o.e), o.attr, try self.resolveVal(o.v)),
                .retract => |o| try self.expandRetract(try self.resolveEnt(o.e), o.attr, try self.resolveVal(o.v)),
                .retract_attr => |o| try self.expandRetractAttr(try self.resolveEnt(o.e), o.attr),
                .retract_entity => |e| try self.expandRetractEntity(try self.resolveEnt(e)),
                .cas => |o| {
                    const old: ?Val = if (o.old) |v| try self.resolveVal(v) else null;
                    try self.expandCas(try self.resolveEnt(o.e), o.attr, old, o.written, try self.resolveVal(o.new));
                },
            }
        }
    }

    /// `:db.fn/cas`: the committed value of the card-one `(e a)`, less
    /// what this transaction retracted, must be `old` (absent when `old`
    /// is null); then `new` is asserted as an ordinary add.
    fn expandCas(self: *Ctx, e: u64, attr: *const Attr, old: ?Val, written: Value, new: Val) !void {
        if (attr.many()) return self.malformed(":db.fn/cas takes a cardinality-one attribute", .{ .attr = attr.id });
        const current = try self.currentOne(e, attr.id);
        const actual: ?Val = if (current) |c| c.val else null;
        const matches = if (old) |o| (if (actual) |a| a.eql(o) else false) else actual == null;
        if (!matches) {
            const unseen = if (old) |o| o == .keyword and o.keyword == no_keyword else false;
            return self.cas(attr, old, actual, if (unseen) written else null);
        }
        try self.expandAdd(e, attr, new);
    }

    /// What an attribute asks of an assertion beyond its value's type
    /// (`convertValue`): a schema attribute describes an attribute, and
    /// an ident names its own entity.
    fn checkAttrValue(self: *Ctx, e: u64, attr: *const Attr, v: Val) !void {
        // On a user or transaction entity a schema attribute would
        // install nothing.
        if (isSchemaAttr(attr.id) and !key.isAttrPartition(e)) return self.malformed("a schema attribute is asserted on an attribute only; an attribute map needs :db/ident", .{ .attr = attr.id });
        if (attr.id == boot.ident and e != v.keyword) return self.conflict(e, attr.id);
    }

    /// `:db/valueType`, `:db/cardinality`, `:db/unique`, `:db/index`,
    /// `:db/isComponent` and `:db/fulltext`.
    fn isSchemaAttr(a: u32) bool {
        return switch (a) {
            boot.value_type, boot.cardinality, boot.unique, boot.index, boot.is_component, boot.fulltext => true,
            else => false,
        };
    }

    fn expandAdd(self: *Ctx, e: u64, attr: *const Attr, v: Val) !void {
        try self.checkAttrValue(e, attr, v);
        const vb = try key.valBytes(self.arena, v);
        const fk = try key.keyBytes(self.arena, .eavt, e, attr.id, vb, null);
        if (self.facts.get(fk)) |i| {
            if (!self.overlay.items[i].added) return self.conflict(e, attr.id);
            return;
        }
        // An entity this transaction minted has no committed datom.
        const fresh = e >= self.first_fresh and e < key.user_partition_end;
        const already = !fresh and (try self.txn.getFromTree(self.conn.store.trees.cur(.eavt), fk)) != null;
        if (!attr.many()) {
            // One value per (e a) per transaction, whether it is
            // pending or was current already.
            const ea: EA = .{ .e = e, .a = attr.id };
            if (self.one_adds.get(ea)) |seen| return if (std.mem.eql(u8, seen, vb)) {} else self.conflict(e, attr.id);
            try self.one_adds.put(self.arena, ea, vb);
            if (already) return self.kept.put(self.arena, fk, {});
            if (!fresh) if (try self.currentOne(e, attr.id)) |old| {
                try self.pushRetract(e, attr, old.val, old.vbytes);
            };
            try self.push(e, attr, v, vb, true, fk);
            return;
        }
        if (already) return self.kept.put(self.arena, fk, {});
        try self.push(e, attr, v, vb, true, fk);
    }

    const Current = struct { val: Val, vbytes: []const u8 };

    /// A committed row of a current tree with this transaction's claim
    /// on it: the pending retraction, if any (a pending assertion of a
    /// committed row never exists, since re-asserting one writes
    /// nothing), or `kept` when the transaction re-asserted it.
    const LiveRow = struct { parts: key.Parts, kv: Store.KeyValue, pending: ?Pending, kept: bool };

    /// The committed rows of a current tree under a prefix, each with
    /// the overlay's pending fact about it. Under VAET, `comps.v` must
    /// be the whole value section, since the rows carry it untagged.
    const LiveScan = struct {
        ctx: *Ctx,
        index: key.Index,
        vbytes: ?[]const u8,
        scan: Store.Scan,

        fn next(self: *LiveScan) !?LiveRow {
            const kv = (try self.scan.next()) orelse return null;
            const parts = try key.unpackKey(self.index, false, kv.key);
            const fk = switch (self.index) {
                .eavt => kv.key,
                .vaet => try key.keyBytes(self.ctx.arena, .eavt, parts.e, parts.a, self.vbytes.?, null),
                else => try key.keyBytes(self.ctx.arena, .eavt, parts.e, parts.a, parts.v, null),
            };
            const pending: ?Pending = if (self.ctx.facts.get(fk)) |i| self.ctx.overlay.items[i] else null;
            return .{ .parts = parts, .kv = kv, .pending = pending, .kept = self.ctx.kept.contains(fk) };
        }

        /// The next row this transaction does not retract.
        fn nextCurrent(self: *LiveScan) !?LiveRow {
            while (try self.next()) |r| {
                if (r.pending) |p| if (!p.added) continue;
                return r;
            }
            return null;
        }
    };

    fn liveRows(self: *Ctx, index: key.Index, comps: key.Components) !LiveScan {
        const prefix = try key.prefixBytes(self.arena, index, comps);
        return .{ .ctx = self, .index = index, .vbytes = comps.v, .scan = try Store.scan(self.txn, self.conn.store.trees.cur(index), prefix) };
    }

    /// The committed value of a card-one `(e a)` that is not already
    /// retracted in this transaction.
    fn currentOne(self: *Ctx, e: u64, a: u32) !?Current {
        var rows = try self.liveRows(.eavt, .{ .e = e, .a = a });
        const r = (try rows.nextCurrent()) orelse return null;
        return .{ .val = try self.valFromParts(r.parts), .vbytes = try self.arena.dupe(u8, r.parts.v) };
    }

    /// The value of a current row. An out-of-line payload lives in the
    /// fact's current EAVT row alone, so it is read by the EAVT fact.
    fn valFromParts(self: *Ctx, parts: key.Parts) !Val {
        const kv = try key.decodeVal(self.arena, parts.v);
        if (kv == .val) return kv.val;
        const payload = (try self.conn.store.currentPayload(self.txn, parts.e, parts.a, parts.v, self.arena)) orelse return error.Corrupted;
        return switch (kv) {
            .string_long => .{ .string = payload },
            .bytes_long => .{ .bytes = payload },
            .val => unreachable,
        };
    }

    fn expandRetract(self: *Ctx, e: u64, attr: *const Attr, v: Val) !void {
        const vb = try key.valBytes(self.arena, v);
        const fk = try key.keyBytes(self.arena, .eavt, e, attr.id, vb, null);
        if (self.facts.get(fk)) |i| {
            if (self.overlay.items[i].added) return self.conflict(e, attr.id);
            return;
        }
        if (self.kept.contains(fk)) return self.conflict(e, attr.id);
        if ((try self.txn.getFromTree(self.conn.store.trees.cur(.eavt), fk)) == null) return;
        try self.pushRetract(e, attr, v, vb);
    }

    /// `[:db/retract e a]` and `[:db/retractEntity e]` expand against
    /// the committed rows, so tx-data is a set: an assertion under the
    /// same `(e a)` stands whichever form comes first, a row this
    /// transaction already retracted is skipped, and a row it
    /// re-asserted is the assertion-and-retraction conflict.
    fn expandRetractAttr(self: *Ctx, e: u64, attr: *const Attr) !void {
        var rows = try self.liveRows(.eavt, .{ .e = e, .a = attr.id });
        while (try rows.next()) |r| {
            if (r.kept) return self.conflict(e, attr.id);
            if (r.pending != null) continue;
            try self.pushRetract(e, attr, try self.valFromParts(r.parts), try self.arena.dupe(u8, r.parts.v));
        }
    }

    /// `[:db/retractEntity e]`: the entity's own datoms and the datoms
    /// pointing at it, then the same for every component it holds, from
    /// a worklist, so a component chain of any length retracts whole.
    fn expandRetractEntity(self: *Ctx, root_e: u64) Failure!void {
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        var work: std.ArrayList(u64) = .empty;
        try work.append(self.arena, root_e);
        while (work.pop()) |e| {
            if ((try seen.getOrPut(self.arena, e)).found_existing) continue;
            {
                var rows = try self.liveRows(.eavt, .{ .e = e });
                while (try rows.next()) |r| {
                    const attr = try self.attrById(r.parts.a);
                    const v = try self.valFromParts(r.parts);
                    if (attr.component and v == .ref) try work.append(self.arena, v.ref);
                    if (r.kept) return self.conflict(e, attr.id);
                    if (r.pending != null) continue;
                    try self.pushRetract(e, attr, v, try self.arena.dupe(u8, r.parts.v));
                }
            }
            const vb = try key.valBytes(self.arena, .{ .ref = e });
            var rows = try self.liveRows(.vaet, .{ .v = vb });
            while (try rows.next()) |r| {
                const attr = try self.attrById(r.parts.a);
                if (r.kept) return self.conflict(r.parts.e, r.parts.a);
                if (r.pending != null) continue;
                try self.pushRetract(r.parts.e, attr, .{ .ref = e }, vb);
            }
        }
    }

    /// Queue a datom; `fact_key` is its EAVT key when the caller has it.
    fn push(self: *Ctx, e: u64, attr: *const Attr, v: Val, vbytes: []const u8, added: bool, fact_key: ?[]const u8) !void {
        // The txlog entry carries the instant too: it never changes.
        if (attr.id == boot.tx_instant and (!added or e != key.txEntity(self.t))) return self.malformed(":db/txInstant is asserted on the transaction's own entity only, and never retracted", .{});
        // Keyword values and the attribute of every datom are stored by
        // the ident's id, so a name only moves, by a rename.
        if (attr.id == boot.ident and !added) return self.schemaRefused(@intCast(e), null, "an ident is never retracted; assert a new :db/ident to rename it");
        const fk = fact_key orelse try key.keyBytes(self.arena, .eavt, e, attr.id, vbytes, null);
        const i: u32 = @intCast(self.overlay.items.len);
        try self.overlay.append(self.arena, .{ .e = e, .attr = attr, .v = v, .vbytes = vbytes, .added = added });
        try self.facts.put(self.arena, fk, i);
        if (added and attr.unique != .none) try self.av_adds.put(self.arena, try self.avKey(attr.id, vbytes), e);
        if (key.isAttrPartition(e)) self.schema_touched = true;
    }

    fn pushRetract(self: *Ctx, e: u64, attr: *const Attr, v: Val, vbytes: []const u8) !void {
        try self.push(e, attr, v, vbytes, false, null);
    }

    /// The transaction's instant: one the tx-data asserted on its own
    /// transaction entity stands, and is the txlog's instant too;
    /// otherwise the clock's. Neither is earlier than the previous
    /// transaction's.
    fn txInstant(self: *Ctx) !void {
        const last = if (try self.currentOne(key.txEntity(self.now), boot.tx_instant)) |c| c.val.instant else std.math.minInt(i64);
        const tx = key.txEntity(self.t);
        for (self.overlay.items) |p| {
            if (p.e == tx and p.attr.id == boot.tx_instant and p.added) {
                if (p.v.instant < last) return self.malformed("a transaction's :db/txInstant is never earlier than the one before", .{});
                self.now_ms = p.v.instant;
                return;
            }
        }
        // A clock behind the last instant takes it: instants never go back.
        self.now_ms = @max(self.now_ms, last);
        const attr = try self.attrById(boot.tx_instant);
        try self.expandAdd(tx, attr, .{ .instant = self.now_ms });
    }

    // ── schema ────────────────────────────────────────────────────

    /// What one transaction does to one attribute-partition entity: the
    /// fields a new attribute asserts and the flags it gains.
    const SchemaChange = struct {
        a: u32,
        /// The attribute as the transaction began, null when the entity
        /// is not one.
        existing: ?*const Attr,
        value_type: ?key.ValueType = null,
        /// `:db/cardinality` asserted: its value is `many`. On an
        /// existing attribute it is a change, since re-asserting the
        /// current value writes nothing.
        has_card: bool = false,
        many: bool = false,
        /// The card-one overwrite's retraction of the old cardinality.
        card_retracted: bool = false,
        unique: bool = false,
        /// `:db/index true` or `:db/unique`: the attribute is in AVET.
        avet: bool = false,
        fulltext: bool = false,
        component: bool = false,
    };

    /// Attribute entities (NEXTOMIC.md §3 step 5), one record per
    /// entity: a new attribute needs `:db/valueType` and
    /// `:db/cardinality`, and so does an entity that gains any schema
    /// flag; `:db/valueType` never changes; `:db/cardinality` may go one
    /// → many, and many → one while no entity holds two values; adding
    /// `:db/index` or `:db/unique` backfills AVET from AEVT, adding
    /// `:db/fulltext` the tokens tree; none of them is retracted.
    fn applySchema(self: *Ctx) !void {
        if (!self.schema_touched) return;
        var changes: std.ArrayList(SchemaChange) = .empty;
        var index: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        for (self.overlay.items) |p| {
            if (!key.isAttrPartition(p.e)) continue;
            const a: u32 = @intCast(p.e);
            const g = try index.getOrPut(self.arena, a);
            if (!g.found_existing) {
                g.value_ptr.* = changes.items.len;
                try changes.append(self.arena, .{ .a = a, .existing = self.schema.attr(a) });
            }
            const c = &changes.items[g.value_ptr.*];
            switch (p.attr.id) {
                boot.fulltext => {
                    // A `false` flag gives way to `true`; `true` stays.
                    if (!p.added and p.v.boolean) return self.conflict(p.e, p.attr.id);
                    if (p.added and p.v.boolean) c.fulltext = true;
                },
                boot.value_type => {
                    if (!p.added or c.existing != null) return self.conflict(p.e, p.attr.id);
                    c.value_type = boot.valueTypeOf(p.v.keyword);
                },
                boot.cardinality => if (p.added) {
                    c.has_card = true;
                    c.many = p.v.keyword == boot.card_many;
                } else {
                    c.card_retracted = true;
                },
                boot.is_component => if (p.added and p.v.boolean) {
                    c.component = true;
                },
                boot.unique, boot.index => {
                    if (!p.added and (p.attr.id == boot.unique or p.v.boolean)) return self.conflict(p.e, p.attr.id);
                    if (!p.added or (p.attr.id == boot.index and !p.v.boolean)) continue;
                    if (p.attr.id == boot.unique) c.unique = true;
                    c.avet = true;
                },
                else => {},
            }
        }
        for (changes.items) |c| {
            // The cardinality's retraction is the overwrite's, never a
            // removal.
            if (c.card_retracted and !c.has_card) return self.conflict(c.a, boot.cardinality);
            const vt: key.ValueType, const many: bool = if (c.existing) |ex| .{ ex.value_type, if (c.has_card) c.many else ex.many() } else blk: {
                const flagged = c.unique or c.avet or c.fulltext or c.component;
                if (c.value_type == null and !c.has_card and !flagged) continue;
                if (c.value_type == null or !c.has_card) return self.malformed("a new attribute needs :db/valueType and :db/cardinality", .{ .attr = c.a });
                if (try self.minter.keywordOf(c.a)) |k| try self.checkAttrName(c.a, k);
                break :blk .{ c.value_type.?, c.many };
            };
            if (c.existing) |ex| if (c.has_card) {
                if (many and ex.unique != .none) return self.schemaRefused(c.a, null, "a unique attribute is cardinality one");
                if (!many) try self.checkSingleValued(ex);
            };
            // A unique attribute identifies one entity by one value, so
            // it is card-one.
            if (c.unique and many) return self.malformed("a unique attribute is cardinality one", .{ .attr = c.a });
            if (c.fulltext and vt != .string) return self.schemaRefused(c.a, null, ":db/fulltext takes a string attribute");
            if (c.component and vt != .ref) return self.schemaRefused(c.a, null, ":db/isComponent takes a ref attribute");
        }
        for (changes.items) |c| {
            const ex = c.existing orelse continue;
            if (c.avet) {
                if (c.unique) try self.checkUniqueValues(ex, if (ex.inAvet()) .avet else .aevt);
                if (!ex.inAvet()) try self.backfillAvet(ex);
            }
            if (c.fulltext and !ex.fulltext) {
                try self.backfillFulltext(ex);
                // Pending string datoms of an attribute that is
                // full-text from this transaction on belong in the
                // tokens tree too.
                if (self.attrs.get(c.a)) |copy| copy.fulltext = true;
            }
        }
    }

    /// Index every current string value of the attribute in the tokens
    /// tree, less this transaction's retractions.
    fn backfillFulltext(self: *Ctx, attr: *const Attr) !void {
        const store = self.conn.store;
        var live = try self.liveRows(.aevt, .{ .a = attr.id });
        while (try live.nextCurrent()) |r| {
            const v = try self.valFromParts(r.parts);
            try fulltext.index(store, self.txn, self.arena, attr.id, r.parts.e, v.string, true);
        }
    }

    /// An attribute becoming cardinality one: no entity may hold two
    /// values, in the tree less this transaction's retractions, or
    /// counting its assertions.
    fn checkSingleValued(self: *Ctx, attr: *const Attr) !void {
        var rows = try self.liveRows(.aevt, .{ .a = attr.id });
        var prev: ?u64 = null;
        while (try rows.nextCurrent()) |r| {
            if (prev) |e| if (e == r.parts.e) return self.schemaRefused(attr.id, e, "an entity holds two values; cardinality stays many");
            prev = r.parts.e;
        }
        var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
        for (self.overlay.items) |p| {
            if (p.attr.id != attr.id or !p.added) continue;
            if ((try seen.getOrPut(self.arena, p.e)).found_existing) return self.schemaRefused(attr.id, p.e, "an entity holds two values; cardinality stays many");
            var live = try self.liveRows(.eavt, .{ .e = p.e, .a = attr.id });
            while (try live.next()) |r| {
                if (r.pending != null) continue;
                return self.schemaRefused(attr.id, p.e, "an entity holds two values; cardinality stays many");
            }
        }
    }

    /// An attribute becoming unique: no value may be held by two
    /// entities, in the tree less this transaction's retractions or
    /// counting its assertions. `index` holds its current values: AVET
    /// once the attribute is indexed, AEVT before the backfill.
    fn checkUniqueValues(self: *Ctx, attr: *const Attr, index: key.Index) !void {
        var holders: std.StringHashMapUnmanaged(u64) = .empty;
        var rows = try self.liveRows(index, .{ .a = attr.id });
        while (try rows.nextCurrent()) |r| {
            const g = try holders.getOrPut(self.arena, try self.arena.dupe(u8, r.parts.v));
            if (g.found_existing) return self.unique(attr, try self.valFromParts(r.parts));
            g.value_ptr.* = r.parts.e;
        }
        for (self.overlay.items) |p| {
            if (p.attr.id != attr.id or !p.added) continue;
            const g = try holders.getOrPut(self.arena, p.vbytes);
            if (g.found_existing and g.value_ptr.* != p.e) return self.unique(attr, p.v);
            g.value_ptr.* = p.e;
        }
    }

    /// Copy every current `(e v t)` of the attribute from AEVT into AVET
    /// with its original `t`, and every row of its AEVT history into
    /// AVET-h, retractions and values retracted long before included,
    /// so a history or as-of view of the index reads what EAVT holds.
    fn backfillAvet(self: *Ctx, attr: *const Attr) !void {
        const store = self.conn.store;
        var rows: std.ArrayList(struct { e: u64, vbytes: []const u8, t: u64 }) = .empty;
        var live = try self.liveRows(.aevt, .{ .a = attr.id });
        while (try live.nextCurrent()) |r| {
            try rows.append(self.arena, .{ .e = r.parts.e, .vbytes = try self.arena.dupe(u8, r.parts.v), .t = (try key.readCurrent(r.kv.value)).t });
        }
        for (rows.items) |r| {
            const ck = try key.keyBytes(self.arena, .avet, r.e, attr.id, r.vbytes, null);
            var tb: [key.t_value_max]u8 = undefined;
            try self.txn.putInTree(store.trees.cur(.avet), ck, key.writeCurrentT(&tb, r.t));
        }
        // Collected before the puts: no cursor stays open across a write.
        var history: std.ArrayList([]const u8) = .empty;
        var hs = try Store.scan(self.txn, store.trees.hist(.aevt), try key.prefixBytes(self.arena, .aevt, .{ .a = attr.id }));
        while (try hs.next()) |kv| {
            const parts = try key.unpackKey(.aevt, true, kv.key);
            try history.append(self.arena, try key.keyBytes(self.arena, .avet, parts.e, attr.id, parts.v, parts.top orelse return error.Corrupted));
        }
        for (history.items) |hk| try self.txn.putInTree(store.trees.hist(.avet), hk, &.{});
        // Pending datoms of this attribute belong in AVET too.
        if (self.attrs.get(attr.id)) |c| c.indexed = true;
    }

    // ── write ─────────────────────────────────────────────────────

    fn write(self: *Ctx) !void {
        const store = self.conn.store;
        const batch = try self.arena.alloc(Store.Prepared, self.overlay.items.len);
        const counts = &self.deltas;
        for (self.overlay.items, 0..) |p, i| {
            batch[i] = .{
                .e = p.e,
                .a = p.attr.id,
                .vbytes = p.vbytes,
                .payload = if (p.v.isOutOfLine()) (switch (p.v) {
                    .string => |s| s,
                    .bytes => |b| b,
                    else => unreachable,
                }) else null,
                .added = p.added,
                .avet = p.attr.inAvet(),
                .vaet = p.attr.inVaet(),
            };
            const g = try counts.getOrPut(self.arena, p.attr.id);
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += if (p.added) 1 else -1;
            if (p.attr.fulltext and p.v == .string) try fulltext.index(store, self.txn, self.arena, p.attr.id, p.e, p.v.string, p.added);
        }
        try store.writeBatch(self.txn, self.t, batch, self.arena);

        var it = counts.iterator();
        while (it.next()) |e| {
            const cur: i64 = @intCast(try store.attrCount(self.txn, e.key_ptr.*));
            const next = cur + e.value_ptr.*;
            if (next < 0) return error.Corrupted;
            try store.writeAttrCount(self.txn, e.key_ptr.*, @intCast(next));
        }

        self.tx_data = try self.txData();
        try store.putTxlog(self.txn, self.t, try datom_mod.encodeTxlog(self.arena, self.t, self.now_ms, self.tx_data, self.excised));

        try store.writeT(self.txn, self.t);
        try store.writeFulltextStamp(self.txn, self.t);
        if (self.schema_touched) try store.bumpSchemaGen(self.txn);
        if (self.eid_bumped) try store.writeNextEid(self.txn, self.next_eid);
        try self.minter.finish();
    }

    fn txData(self: *Ctx) ![]Datom {
        const out = try self.arena.alloc(Datom, self.overlay.items.len);
        for (out, self.overlay.items) |*d, p| {
            d.* = .{ .e = p.e, .a = p.attr.id, .v = p.v, .t = self.t, .added = p.added };
        }
        return out;
    }

    fn userTempids(self: *Ctx) ![]TempidBinding {
        var out: std.ArrayList(TempidBinding) = .empty;
        for (self.bindings.items, 0..) |b, i| {
            const w = b.written orelse continue;
            // The report outlives the tx-data.
            const k: TempidKey = if (w.kind() == .string) .{ .string = try self.arena.dupe(u8, string_mod.asBytes(w)) } else .{ .fixnum = w.asFixnum() };
            try out.append(self.arena, .{ .key = k, .eid = self.eidOfTempid(@intCast(i)) });
        }
        return out.toOwnedSlice(self.arena);
    }
};
