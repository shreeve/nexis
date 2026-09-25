//! transact.zig — the transaction protocol (NEXTOMIC.md §3).
//!
//! One `transact` is one emdb write transaction; emdb's write lock is
//! the transactor. The pipeline, named as the banners below name it:
//!
//!   - begin: the write transaction, `t = sys["t"] + 1`;
//!   - normalise: tx-data to ops (vector forms, map forms with nested
//!     entities and card-many collections), resolving attributes through
//!     the schema at `now` and converting values by the attribute's type;
//!   - tempids: `:db/ident` binds to the ident's id (minting it),
//!     unique-identity assertions upsert through an AVET probe (a
//!     tempid- or lookup-ref-valued claim once its value is known),
//!     two tempids naming one identity unify, the rest take fresh eids;
//!     then every unique assertion is claimed, so a lookup ref resolves
//!     alike wherever it stands;
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

/// How deep `:db.fn/call` results may nest further calls.
pub const max_call_depth: u32 = 16;

/// Calls a transaction function (NEXTOMIC.md §3 "Transaction
/// functions"). `f` is the value in the `:db.fn/call` form: a function,
/// or a symbol the hook resolves through the namespace registry. The
/// hook boxes `db_before` for the VM, calls `f` with it ahead of
/// `args`, and returns the tx-data the function produced.
pub const CallHook = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, f: Value, db_before: DbValue, args: []const Value) anyerror!Value,
};

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
    /// Every datom of the transaction in write order, `:db/txInstant` last.
    tx_data: []Datom,
};

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
    var ctx = try Ctx.begin(conn, arena, options);
    errdefer ctx.abort();
    try ctx.ops.ensureTotalCapacityPrecise(arena, ops.len);
    for (ops) |op| try ctx.normaliseOp(op);
    return ctx.run();
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
    if (ent == .tempid) return ctx.malformed("excision takes an existing entity");
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
/// outlive `finish`; the view is allocated on the connection's
/// allocator so that db-values naming it may outlive the arena, and
/// `destroy` frees it.
pub const With = struct {
    ctx: Ctx,
    /// The view: the connection's store and interner, its own ident and
    /// schema caches, reads through `ctx.txn`. Allocated on the
    /// connection's allocator; closed by `finish`, freed by `destroy`.
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

    /// `finish`, then free the view. Nothing may name the view
    /// afterwards: a db-value that escaped the scope reads freed
    /// memory. Once per `With`.
    pub fn destroy(self: *With) void {
        self.finish();
        self.view.destroy();
    }

    /// The protocol after normalisation: apply, then open the view over
    /// the held transaction.
    fn speculate(self: *With) !void {
        const conn = self.ctx.conn;
        try self.ctx.apply();
        const view = try conn.gpa.create(Conn);
        errdefer conn.gpa.destroy(view);
        view.* = .{
            .gpa = conn.gpa,
            .store = conn.store,
            .interner = conn.interner,
            .idents = try conn.idents.clone(),
            .sync_mode = self.ctx.sync_mode,
            .is_open = true,
            .owns_store = false,
            .overlay = self.ctx.txn,
        };
        errdefer view.idents.deinit();
        self.view = view;
        self.report = .{
            .db_before = .{ .conn = conn, .basis = self.ctx.now },
            .db_after = .{ .conn = view, .basis = self.ctx.t },
            .t = self.ctx.t,
            .tempids = try self.ctx.userTempids(),
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
    const self = try arena.create(With);
    self.ctx = try Ctx.begin(conn, arena, options);
    errdefer self.ctx.abort();
    try self.ctx.ops.ensureTotalCapacityPrecise(arena, ops.len);
    for (ops) |op| try self.ctx.normaliseOp(op);
    try self.speculate();
    return self;
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
const CasOp = struct { e: Ent, attr: *const Attr, old: ?PVal, new: PVal };

const ROp = union(enum) {
    add: struct { e: Ent, attr: *const Attr, v: PVal },
    retract: struct { e: Ent, attr: *const Attr, v: PVal },
    retract_attr: struct { e: Ent, attr: *const Attr },
    retract_entity: Ent,
    cas: *const CasOp,
};

const Binding = struct {
    key: ?TempidKey,
    eid: ?u64 = null,
    /// Unified with another binding.
    alias: ?u32 = null,
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
    str_tempids: std.StringHashMapUnmanaged(u32) = .empty,
    num_tempids: std.AutoHashMapUnmanaged(i64, u32) = .empty,
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
    av_claims: std.StringHashMapUnmanaged(u64) = .empty,

    next_eid: u64,
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
        if (now + 1 >= key.tx_partition_bit) return error.DatabaseFull;
        const schema = try conn.schemaAt(txn, now, now);
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
            .next_eid = try conn.store.readNextEid(txn),
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

    /// `TxData` with the reason.
    fn malformed(self: *Ctx, message: []const u8) error{TxData} {
        if (self.fault) |f| f.* = .{ .message = message };
        return error.TxData;
    }

    /// `TxFn` with the reason.
    fn txFn(self: *Ctx, message: []const u8) error{TxFn} {
        if (self.fault) |f| f.* = .{ .message = message };
        return error.TxFn;
    }

    /// `Cas`: `attr` holds `actual` where the form expected `expected`.
    fn cas(self: *Ctx, attr: *const Attr, expected: ?Val, actual: ?Val) error{Cas} {
        if (self.fault) |f| f.* = .{ .attr = self.attrValue(attr.id), .cas = .{ .expected = expected, .actual = actual } };
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
        return self.minter.resolve(k) catch |err| switch (err) {
            error.RetiredIdent => self.malformed("a retired ident name is never reused"),
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

    /// The attribute as a program names it: its ident, else its id.
    fn attrValue(self: *Ctx, a: u32) ?Value {
        const k = (self.minter.keywordOf(a) catch null) orelse return value.fromFixnum(a);
        return value.fromKeywordId(k);
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
        const id = (try self.minter.lookup(intern_id)) orelse return self.unknownAttr(value.fromKeywordId(intern_id));
        return (try self.attrCopy(id)) orelse self.unknownAttr(value.fromKeywordId(intern_id));
    }

    fn attrOf(self: *Ctx, ref: AttrRef) !*const Attr {
        return switch (ref) {
            .id => |id| self.attrById(id),
            .ident => |k| self.attrByIntern(k),
        };
    }

    // ── entity ids ────────────────────────────────────────────────

    /// An explicit entity id, as an entity or a ref value, must have been
    /// handed out by its partition's allocator: a user id below the next
    /// user id, an attribute or ident id below the next ident id, a
    /// transaction entity no newer than this transaction. Anything else
    /// would collide with an id minted later: `error.NoEntity`.
    fn checkEid(self: *Ctx, id: u64) !u64 {
        if (id == 0 or id > key.id_max) return error.NoEntity;
        if (key.txOfEntity(id)) |t| return if (t <= self.t) id else error.NoEntity;
        if (key.isAttrPartition(id)) return if (id < self.minter.next_aid) id else error.NoEntity;
        return if (id < self.next_eid) id else error.NoEntity;
    }

    // ── tempids ───────────────────────────────────────────────────

    fn tempid(self: *Ctx, k: TempidKey) !u32 {
        switch (k) {
            .string => |s| {
                if (self.str_tempids.get(s)) |i| return i;
                const owned = try self.arena.dupe(u8, s);
                const i: u32 = @intCast(self.bindings.items.len);
                try self.bindings.append(self.arena, .{ .key = .{ .string = owned } });
                try self.str_tempids.put(self.arena, owned, i);
                return i;
            },
            .fixnum => |n| {
                if (self.num_tempids.get(n)) |i| return i;
                const i: u32 = @intCast(self.bindings.items.len);
                try self.bindings.append(self.arena, .{ .key = .{ .fixnum = n } });
                try self.num_tempids.put(self.arena, n, i);
                return i;
            },
        }
    }

    fn internalTempid(self: *Ctx) !u32 {
        const i: u32 = @intCast(self.bindings.items.len);
        try self.bindings.append(self.arena, .{ .key = null });
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

    // ── normalisation from Zig ops ────────────────────────────────

    fn entityOf(self: *Ctx, e: Entity) !Ent {
        return switch (e) {
            .eid => |id| .{ .eid = try self.checkEid(id) },
            .tempid => |k| .{ .tempid = try self.tempid(k) },
            .lookup => |l| .{ .lookup = try self.lookupRef(try self.lookupAttr(try self.attrOf(l.a), l.v), l.v) },
            .ident => |k| .{ .eid = (try self.minter.lookup(k)) orelse return error.NoEntity },
            .tx => .{ .eid = key.txEntity(self.t) },
        };
    }

    fn lookupRef(self: *Ctx, attr: *const Attr, v: Val) !*const Lookup {
        const l = try self.arena.create(Lookup);
        l.* = .{ .attr = attr, .v = v };
        return l;
    }

    fn lookupAttr(self: *Ctx, attr: *const Attr, v: Val) !*const Attr {
        if (attr.unique == .none) return self.malformed("a lookup ref needs a unique attribute");
        if (v.valueType() != attr.value_type) return error.ValueType;
        return attr;
    }

    /// A value position of a Zig op: asserted when `use` is `.assert`,
    /// otherwise only matched against what the store holds.
    fn valueOf(self: *Ctx, attr: *const Attr, v: ValRef, use: Use) !PVal {
        switch (v) {
            .val => |x| {
                if (x.valueType() != attr.value_type) return error.ValueType;
                if (x == .double and std.math.isNan(x.double)) return error.ValueType;
                if (x == .ref) _ = try self.checkEid(x.ref);
                return .{ .val = try x.dupe(self.arena) };
            },
            .entity => |e| {
                if (attr.value_type != .ref) return error.ValueType;
                return switch (try self.entityOf(e)) {
                    .eid => |id| .{ .val = .{ .ref = id } },
                    .tempid => |i| .{ .tempid = i },
                    .lookup => |l| .{ .lookup = l },
                };
            },
            .keyword => |k| {
                if (attr.value_type != .keyword) return error.ValueType;
                return self.keywordValue(attr, k, use);
            },
            .vm => |x| return self.valueFromVm(attr, x, use),
        }
    }

    fn normaliseOp(self: *Ctx, op: Op) !void {
        switch (op) {
            .add => |o| {
                const attr = try self.attrOf(o.a);
                try self.ops.append(self.arena, .{ .add = .{ .e = try self.entityOf(o.e), .attr = attr, .v = try self.valueOf(attr, o.v, .assert) } });
            },
            .retract => |o| {
                const attr = try self.attrOf(o.a);
                try self.ops.append(self.arena, .{ .retract = .{ .e = try self.entityOf(o.e), .attr = attr, .v = try self.valueOf(attr, o.v, .match) } });
            },
            .retract_attr => |o| {
                try self.ops.append(self.arena, .{ .retract_attr = .{ .e = try self.entityOf(o.e), .attr = try self.attrOf(o.a) } });
            },
            .retract_entity => |e| try self.ops.append(self.arena, .{ .retract_entity = try self.entityOf(e) }),
        }
    }

    // ── normalisation from VM values ──────────────────────────────

    fn kwIs(self: *Ctx, v: Value, name: []const u8) bool {
        return v.kind() == .keyword and std.mem.eql(u8, self.conn.interner.keywordName(v.asKeywordId()), name);
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
            else => return self.malformed("tx-data is a vector or a list of forms"),
        }
    }

    fn normaliseForm(self: *Ctx, form: Value) anyerror!void {
        switch (form.kind()) {
            .persistent_vector => {
                const n = vector_mod.count(form);
                if (n < 2) return self.malformed("a vector form is [op e ...]");
                const op = vector_mod.nth(form, 0);
                if (self.kwIs(op, "db.fn/call")) {
                    try self.normaliseCall(form);
                } else if (self.kwIs(op, "db.fn/cas")) {
                    if (n != 5) return self.malformed(":db.fn/cas is [:db.fn/cas e a old new]");
                    const attr = try self.attrFromVm(vector_mod.nth(form, 2));
                    const e = try self.entityFromVm(vector_mod.nth(form, 1));
                    const old_v = vector_mod.nth(form, 3);
                    const op_cas = try self.arena.create(CasOp);
                    op_cas.* = .{ .e = e, .attr = attr, .old = if (old_v.isNil()) null else try self.valueFromVm(attr, old_v, .assert), .new = try self.valueFromVm(attr, vector_mod.nth(form, 4), .assert) };
                    try self.ops.append(self.arena, .{ .cas = op_cas });
                } else if (self.kwIs(op, "db/add")) {
                    if (n != 4) return self.malformed(":db/add is [:db/add e a v]");
                    const attr = try self.attrFromVm(vector_mod.nth(form, 2));
                    const e = try self.entityFromVm(vector_mod.nth(form, 1));
                    try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, vector_mod.nth(form, 3), .assert) } });
                } else if (self.kwIs(op, "db/retract")) {
                    if (n != 3 and n != 4) return self.malformed(":db/retract is [:db/retract e a] or [:db/retract e a v]");
                    const attr = try self.attrFromVm(vector_mod.nth(form, 2));
                    const e = try self.entityFromVm(vector_mod.nth(form, 1));
                    if (n == 3) {
                        try self.ops.append(self.arena, .{ .retract_attr = .{ .e = e, .attr = attr } });
                    } else {
                        try self.ops.append(self.arena, .{ .retract = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, vector_mod.nth(form, 3), .match) } });
                    }
                } else if (self.kwIs(op, "db/retractEntity")) {
                    if (n != 2) return self.malformed(":db/retractEntity is [:db/retractEntity e]");
                    try self.ops.append(self.arena, .{ .retract_entity = try self.entityFromVm(vector_mod.nth(form, 1)) });
                } else return self.malformed("unknown op; one of :db/add, :db/retract, :db/retractEntity, :db.fn/call, :db.fn/cas");
            },
            .persistent_map => _ = try self.normaliseMap(form),
            else => return self.malformed("a form is a vector or a map"),
        }
    }

    /// `[:db.fn/call f arg ...]`: call `f` with `db-before` and the
    /// arguments, then normalise the tx-data it returns in place of the
    /// form, where further calls may nest to `max_call_depth`. The
    /// function value is called, never stored: only the datoms it
    /// returns reach the trees and the txlog. A nil result is no
    /// tx-data.
    fn normaliseCall(self: *Ctx, form: Value) anyerror!void {
        const hook = self.hook orelse return self.txFn("transaction functions run inside transact! and with only");
        const f = vector_mod.nth(form, 1);
        switch (f.kind()) {
            .function, .native_fn, .symbol => {},
            else => return self.malformed(":db.fn/call takes a function or a symbol naming one"),
        }
        if (self.call_depth >= max_call_depth) return self.txFn("transaction functions nest past the depth limit");
        const n = vector_mod.count(form);
        const args = try self.arena.alloc(Value, n - 2);
        for (args, 2..) |*a, i| a.* = vector_mod.nth(form, i);
        const db_before: DbValue = .{ .conn = self.conn, .basis = self.now };
        const result = try hook.call(hook.ctx, f, db_before, args);
        if (result.isNil()) return;
        self.call_depth += 1;
        defer self.call_depth -= 1;
        try self.normaliseValue(result);
    }

    /// Expand a map form into adds; returns the entity. A key
    /// `:ns/_attr` is a reverse ref: its value names the entities that
    /// refer to this one through `:ns/attr`.
    fn normaliseMap(self: *Ctx, m: Value) Failure!Ent {
        // Nested map forms recurse here, one frame per level.
        try stack.check();
        var ent: ?Ent = null;
        var it = champ.mapIter(m);
        while (it.next()) |entry| {
            if (self.kwIs(entry.key, "db/id")) {
                ent = try self.entityFromVm(entry.value);
                break;
            }
        }
        const e: Ent = ent orelse .{ .tempid = try self.internalTempid() };

        var it2 = champ.mapIter(m);
        while (it2.next()) |entry| {
            if (self.kwIs(entry.key, "db/id")) continue;
            const v = entry.value;
            if (try self.reverseAttr(entry.key)) |attr| {
                if (isCollection(v) and !try self.isLookupRef(v)) {
                    for (try collectionElements(self.arena, v)) |el| try self.addReverse(e, attr, el);
                } else {
                    try self.addReverse(e, attr, v);
                }
                continue;
            }
            const attr = try self.attrFromVm(entry.key);
            if (attr.many() and isCollection(v) and !(attr.value_type == .ref and try self.isLookupRef(v))) {
                for (try collectionElements(self.arena, v)) |el| try self.addFromVm(e, attr, el);
            } else {
                try self.addFromVm(e, attr, v);
            }
        }
        return e;
    }

    /// The ref attribute a `:ns/_attr` key reverses, or null for any
    /// other key.
    fn reverseAttr(self: *Ctx, k: Value) !?*const Attr {
        if (k.kind() != .keyword) return null;
        const name = self.conn.interner.keywordName(k.asKeywordId());
        const slash = std.mem.indexOfScalar(u8, name, '/') orelse return null;
        if (slash + 1 >= name.len or name[slash + 1] != '_') return null;
        const forward = try std.mem.concat(self.arena, u8, &.{ name[0 .. slash + 1], name[slash + 2 ..] });
        const id = (try self.minter.lookupName(forward)) orelse return self.unknownAttr(k);
        const attr = (try self.attrCopy(id)) orelse return self.unknownAttr(k);
        if (attr.value_type != .ref) return self.malformed("a reverse ref needs a ref attribute");
        return attr;
    }

    /// `[referrer attr e]` for one value under a reverse ref: an entity,
    /// or a map form of one.
    fn addReverse(self: *Ctx, e: Ent, attr: *const Attr, referrer: Value) Failure!void {
        const from = if (referrer.kind() == .persistent_map) try self.normaliseMap(referrer) else try self.entityFromVm(referrer);
        try self.ops.append(self.arena, .{ .add = .{ .e = from, .attr = attr, .v = pvalOf(e) } });
    }

    fn pvalOf(e: Ent) PVal {
        return switch (e) {
            .eid => |id| .{ .val = .{ .ref = id } },
            .tempid => |i| .{ .tempid = i },
            .lookup => |l| .{ .lookup = l },
        };
    }

    /// Does a map form name its entity: a `:db/id`, or a unique
    /// attribute?
    fn carriesIdentity(self: *Ctx, m: Value) !bool {
        var it = champ.mapIter(m);
        while (it.next()) |entry| {
            if (self.kwIs(entry.key, "db/id")) return true;
            if (entry.key.kind() != .keyword) continue;
            const attr = self.attrFromVm(entry.key) catch continue;
            if (attr.unique != .none) return true;
        }
        return false;
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
        if (v.kind() == .persistent_map and attr.value_type == .ref) {
            if (!attr.component and !try self.carriesIdentity(v)) return self.malformed("a nested map under a non-component ref needs :db/id or a unique attribute");
            const nested = try self.normaliseMap(v);
            try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = pvalOf(nested) } });
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
            else => self.malformed("an attribute is a keyword or an id"),
        };
    }

    fn entityFromVm(self: *Ctx, v: Value) Failure!Ent {
        switch (v.kind()) {
            .fixnum => {
                const n = v.asFixnum();
                if (n < 0) return .{ .tempid = try self.tempid(.{ .fixnum = n }) };
                return .{ .eid = try self.checkEid(@intCast(n)) };
            },
            .string => {
                const s = string_mod.asBytes(v);
                if (std.mem.eql(u8, s, "datomic.tx")) return .{ .eid = key.txEntity(self.t) };
                return .{ .tempid = try self.tempid(.{ .string = s }) };
            },
            .keyword => return .{ .eid = (try self.minter.lookup(v.asKeywordId())) orelse return error.NoEntity },
            .persistent_vector => {
                if (vector_mod.count(v) != 2) return self.malformed("a lookup ref is [attr value]");
                const attr = try self.attrFromVm(vector_mod.nth(v, 0));
                if (attr.unique == .none) return self.malformed("a lookup ref needs a unique attribute");
                const lv = try self.valueFromVm(attr, vector_mod.nth(v, 1), .match);
                if (lv != .val) return self.malformed("a lookup ref value is a plain value");
                return .{ .lookup = try self.lookupRef(attr, lv.val) };
            },
            else => return self.malformed("an entity is an id, a tempid, a lookup ref, an ident or \"datomic.tx\""),
        }
    }

    /// Convert a VM value by the attribute's type.
    fn valueFromVm(self: *Ctx, attr: *const Attr, v: Value, use: Use) Failure!PVal {
        switch (attr.value_type) {
            .boolean => {
                if (!v.isBool()) return error.ValueType;
                return .{ .val = .{ .boolean = v.asBool() } };
            },
            .long => {
                if (v.kind() != .fixnum) return error.ValueType;
                return .{ .val = .{ .long = v.asFixnum() } };
            },
            .double => {
                if (v.kind() != .float) return error.ValueType;
                const d = v.asFloat();
                if (std.math.isNan(d)) return error.ValueType;
                return .{ .val = .{ .double = d } };
            },
            .instant => {
                if (v.kind() != .fixnum) return error.ValueType;
                return .{ .val = .{ .instant = v.asFixnum() } };
            },
            .keyword => {
                if (v.kind() != .keyword) return error.ValueType;
                return self.keywordValue(attr, v.asKeywordId(), use);
            },
            .ref => {
                const e = self.entityFromVm(v) catch |err| switch (err) {
                    error.TxData => return error.ValueType,
                    else => return err,
                };
                return switch (e) {
                    .eid => |id| .{ .val = .{ .ref = id } },
                    .tempid => |i| .{ .tempid = i },
                    .lookup => |l| .{ .lookup = l },
                };
            },
            .string => {
                if (v.kind() != .string) return error.ValueType;
                return .{ .val = .{ .string = try self.arena.dupe(u8, string_mod.asBytes(v)) } };
            },
            .uuid => {
                if (v.kind() != .string) return error.ValueType;
                return .{ .val = .{ .uuid = datom_mod.uuidFromText(string_mod.asBytes(v)) orelse return error.ValueType } };
            },
            .bytes => {
                if (v.kind() != .string) return error.ValueType;
                return .{ .val = .{ .bytes = try self.arena.dupe(u8, string_mod.asBytes(v)) } };
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
        try self.claimAll();
        try self.expandAll();
        try self.txInstant();
        try self.checkUnique();
        try self.applySchema();
        if (self.excision) |x| {
            // Resolved before the write, which marks the entry with it.
            const e = try self.resolveEnt(x.e);
            if (e < key.user_partition_start or e >= key.user_partition_end) return self.malformed("excision takes a user entity");
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
        const ids: datom_mod.IdSource = .{ .ctx = @ptrCast(self), .identId = &identIdOf, .attrType = &attrTypeOf };
        const names: datom_mod.NameSource = .{ .ctx = @ptrCast(self), .identName = &identName };
        try excise_mod.rewriteTxlog(store, self.txn, self.arena, out.ts, e, a, ids, names);
    }

    fn identIdOf(ctx: *anyopaque, name: []const u8) anyerror!?u32 {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        if (try self.minter.lookupName(name)) |id| return id;
        return self.conn.store.retiredIdentId(self.txn, name);
    }

    fn attrTypeOf(ctx: *anyopaque, a: u32) anyerror!?key.ValueType {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        const attr = self.schema.attr(a) orelse return null;
        return attr.value_type;
    }

    /// Commit, then publish the mints and update the schema
    /// cache, and report. Everything that can fail (the report's tempid
    /// bindings, the tx-data, room in the ident cache) is prepared
    /// before the commit; after it only infallible steps remain, so a
    /// committed transaction is never reported as an error.
    fn commit(self: *Ctx) !Report {
        const db_before: DbValue = .{ .conn = self.conn, .basis = self.now };
        const tempids = try self.userTempids();
        try self.minter.reserveCache();
        try self.txn.commit();
        self.finished = true;
        self.conn.taskDone();
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
        return .{
            .db_before = db_before,
            .db_after = .{ .conn = self.conn, .basis = self.t },
            .t = self.t,
            .tempids = tempids,
            .tx_data = self.tx_data,
        };
    }

    // ── idents ────────────────────────────────────────────────────

    /// Settle every `:db/ident` value (NEXTOMIC.md §3 step 5). An
    /// assertion on a tempid mints the keyword when it is new, and the
    /// tempid takes the ident's id. On an entity that exists: a keyword
    /// naming it already is a no-op, one naming another entity a
    /// conflict, and a fresh keyword on an attribute-partition entity
    /// renames it, retiring the old name. A retraction resolves the
    /// keyword as any value.
    fn bindIdents(self: *Ctx) !void {
        for (self.ops.items) |*op| {
            const slot: *PVal = switch (op.*) {
                .add => |*o| if (o.attr.id == boot.ident) &o.v else continue,
                .retract => |*o| if (o.attr.id == boot.ident) &o.v else continue,
                .cas => |c| blk: {
                    const mutable: *CasOp = @constCast(c);
                    if (mutable.old) |*old| if (old.* == .ident) {
                        old.* = .{ .val = .{ .keyword = try self.mintKeyword(old.ident) } };
                    };
                    break :blk &mutable.new;
                },
                else => continue,
            };
            if (slot.* != .ident) continue;
            const k = slot.ident;
            if (op.* != .add) {
                slot.* = .{ .val = .{ .keyword = try self.mintKeyword(k) } };
                continue;
            }
            const existing = try self.minter.lookup(k);
            const e: ?u64 = switch (op.add.e) {
                .eid => |id| id,
                .tempid => null,
                .lookup => |l| blk: {
                    const vb = try key.valBytes(self.arena, l.v);
                    break :blk (try self.probeAvet(l.attr.id, vb)) orelse return error.NoEntity;
                },
            };
            const id: u32 = blk: {
                const eid = e orelse break :blk existing orelse try self.mintKeyword(k);
                if (existing) |x| {
                    if (x != eid) return self.conflict(eid, boot.ident);
                    break :blk x;
                }
                if (!key.isAttrPartition(eid)) return self.conflict(eid, boot.ident);
                self.minter.rename(@intCast(eid), k) catch |err| switch (err) {
                    error.RetiredIdent => return self.malformed("a retired ident name is never reused"),
                    else => return err,
                };
                break :blk @intCast(eid);
            };
            slot.* = .{ .val = .{ .keyword = id } };
        }
    }

    // ── tempids ───────────────────────────────────────────────────

    fn bindTempids(self: *Ctx) !void {
        // `:db/ident` names the entity: its id is the ident's id.
        for (self.ops.items) |op| {
            if (op != .add or op.add.e != .tempid or op.add.attr.id != boot.ident) continue;
            if (op.add.v != .val) return error.ValueType;
            try self.bind(op.add.e.tempid, op.add.v.val.keyword, boot.ident);
        }
        // Unique-identity assertions upsert; equal identities unify. A
        // claim whose value is a tempid or a lookup ref waits until the
        // value is known: a tempid bound by its own identity, a lookup
        // ref found in the tree or among the claims of this
        // transaction. Each round settles what the last one bound.
        var claims: std.StringHashMapUnmanaged(u32) = .empty;
        var deferred: std.ArrayList(struct { op: usize, e: u32, attr: *const Attr, v: PVal }) = .empty;
        for (self.ops.items, 0..) |op, idx| {
            if (op != .add or op.add.e != .tempid) continue;
            const attr = op.add.attr;
            if (attr.unique != .identity or attr.id == boot.ident) continue;
            switch (op.add.v) {
                .val => |v| try self.claimIdentity(&claims, op.add.e.tempid, attr, v),
                else => try deferred.append(self.arena, .{ .op = idx, .e = op.add.e.tempid, .attr = attr, .v = op.add.v }),
            }
        }
        var progress = true;
        while (progress and deferred.items.len > 0) {
            progress = false;
            var i: usize = 0;
            while (i < deferred.items.len) {
                const d = deferred.items[i];
                var eid: ?u64 = null;
                var target: ?u32 = null;
                switch (d.v) {
                    .tempid => |t| target = t,
                    .lookup => |l| {
                        const vb = try key.valBytes(self.arena, l.v);
                        eid = try self.probeAvet(l.attr.id, vb);
                        if (eid == null) target = claims.get(try self.avKey(l.attr.id, vb));
                        // A lookup ref naming a tempid's identity is that
                        // tempid, wherever the identity is asserted.
                        if (target) |t| self.ops.items[d.op].add.v = .{ .tempid = t };
                    },
                    .val, .ident => unreachable,
                }
                if (eid == null) if (target) |t| {
                    eid = self.bindings.items[self.root(t)].eid;
                };
                if (eid) |id| {
                    try self.claimIdentity(&claims, d.e, d.attr, .{ .ref = id });
                } else if (target != null) {
                    // Waits for its target's binding.
                    i += 1;
                    continue;
                }
                // Resolved, or naming nothing this transaction knows:
                // expansion resolves or refuses such a lookup ref.
                progress = true;
                _ = deferred.swapRemove(i);
            }
        }
        // Claims on entities this transaction creates: equal claims are
        // one entity, and the tree cannot hold them yet.
        var by_target: std.AutoHashMapUnmanaged(struct { a: u32, root: u32 }, u32) = .empty;
        for (deferred.items) |d| {
            const t: u32 = self.ops.items[d.op].add.v.tempid;
            const g = try by_target.getOrPut(self.arena, .{ .a = d.attr.id, .root = self.root(t) });
            if (g.found_existing) try self.unify(d.e, g.value_ptr.*, d.attr.id) else g.value_ptr.* = d.e;
        }
        // Fresh eids for the rest, each the entity of some op: a tempid
        // only in value positions would name an entity with no datoms.
        const named = try self.arena.alloc(bool, self.bindings.items.len);
        @memset(named, false);
        for (self.ops.items) |op| {
            const e: Ent = switch (op) {
                .add => |o| o.e,
                .retract => |o| o.e,
                .retract_attr => |o| o.e,
                .retract_entity => |e| e,
                .cas => |c| c.e,
            };
            if (e == .tempid) named[self.root(e.tempid)] = true;
        }
        for (self.bindings.items, named) |*b, n| {
            if (b.alias != null) continue;
            if (b.eid != null) continue;
            if (!n) return self.malformed("a tempid used only as a value, or not at all, names no entity");
            if (self.next_eid >= key.user_partition_end) return error.DatabaseFull;
            b.eid = self.next_eid;
            self.next_eid += 1;
            self.eid_bumped = true;
        }
    }

    /// One identity claim `(e a v)` with `v` known: equal claims unify,
    /// and the entity holding `(a v)` in the tree binds the tempid.
    fn claimIdentity(self: *Ctx, claims: *std.StringHashMapUnmanaged(u32), e: u32, attr: *const Attr, v: Val) !void {
        const vb = try key.valBytes(self.arena, v);
        const av = try self.avKey(attr.id, vb);
        const g = try claims.getOrPut(self.arena, av);
        if (g.found_existing) {
            try self.unify(e, g.value_ptr.*, attr.id);
        } else {
            g.value_ptr.* = e;
        }
        if (try self.probeAvet(attr.id, vb)) |eid| try self.bind(e, eid, attr.id);
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
        while (s.next()) |kv| {
            const parts = try key.unpackKey(.avet, false, kv.key);
            if (std.mem.eql(u8, parts.v, vbytes)) return parts.e;
        }
        return null;
    }

    /// The entity holding `(a v)` once the transaction's datoms are
    /// written, or null.
    fn findByAv(self: *Ctx, a: u32, vbytes: []const u8) !?u64 {
        if (self.av_adds.get(try self.avKey(a, vbytes))) |e| return e;
        const e = (try self.probeAvet(a, vbytes)) orelse return null;
        return if (try self.retracts(e, a, vbytes)) null else e;
    }

    /// The entity a lookup ref names: the committed holder of `(a v)`,
    /// else the entity the tx-data asserts it on, wherever that
    /// assertion stands; null when neither exists.
    fn lookupEid(self: *Ctx, l: *const Lookup) !?u64 {
        const vb = try key.valBytes(self.arena, l.v);
        if (try self.probeAvet(l.attr.id, vb)) |e| return e;
        return self.av_claims.get(try self.avKey(l.attr.id, vb));
    }

    fn resolveEnt(self: *Ctx, e: Ent) !u64 {
        return switch (e) {
            .eid => |id| id,
            .tempid => |i| self.eidOfTempid(i),
            .lookup => |l| (try self.lookupEid(l)) orelse error.NoEntity,
        };
    }

    fn resolveVal(self: *Ctx, v: PVal) !Val {
        return switch (v) {
            .val => |x| x,
            .tempid => |i| .{ .ref = self.eidOfTempid(i) },
            .lookup => |l| .{ .ref = (try self.lookupEid(l)) orelse return error.NoEntity },
            .ident => unreachable,
        };
    }

    /// Record every unique assertion's `(a v) -> e` before expansion,
    /// so a lookup ref resolves the same wherever it stands. An
    /// assertion whose entity or value is itself a lookup ref waits for
    /// the claims it names.
    fn claimAll(self: *Ctx) !void {
        var waiting: std.ArrayList(usize) = .empty;
        for (self.ops.items, 0..) |op, i| {
            if (op != .add or op.add.attr.unique == .none) continue;
            if (!try self.claim(op.add.e, op.add.attr, op.add.v)) try waiting.append(self.arena, i);
        }
        var progress = true;
        while (progress) {
            progress = false;
            var i: usize = 0;
            while (i < waiting.items.len) {
                const op = self.ops.items[waiting.items[i]].add;
                if (try self.claim(op.e, op.attr, op.v)) {
                    _ = waiting.swapRemove(i);
                    progress = true;
                } else i += 1;
            }
        }
    }

    /// Claim `(a v) -> e` when both sides resolve; false when a lookup
    /// ref among them names nothing yet.
    fn claim(self: *Ctx, e: Ent, attr: *const Attr, v: PVal) !bool {
        const eid = switch (e) {
            .lookup => |l| (try self.lookupEid(l)) orelse return false,
            else => try self.resolveEnt(e),
        };
        const val: Val = switch (v) {
            .lookup => |l| .{ .ref = (try self.lookupEid(l)) orelse return false },
            else => try self.resolveVal(v),
        };
        const av = try self.avKey(attr.id, try key.valBytes(self.arena, val));
        const g = try self.av_claims.getOrPut(self.arena, av);
        if (!g.found_existing) g.value_ptr.* = eid;
        return true;
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
                    try self.expandCas(try self.resolveEnt(o.e), o.attr, old, try self.resolveVal(o.new));
                },
            }
        }
    }

    /// `:db.fn/cas`: the committed value of the card-one `(e a)`, less
    /// what this transaction retracted, must be `old` (absent when `old`
    /// is null); then `new` is asserted as an ordinary add.
    fn expandCas(self: *Ctx, e: u64, attr: *const Attr, old: ?Val, new: Val) !void {
        if (attr.many()) return self.malformed(":db.fn/cas takes a cardinality-one attribute");
        const current = try self.currentOne(e, attr.id);
        const actual: ?Val = if (current) |c| c.val else null;
        const matches = if (old) |o| (if (actual) |a| a.eql(o) else false) else actual == null;
        if (!matches) return self.cas(attr, old, actual);
        try self.expandAdd(e, attr, new);
    }

    fn checkAttrValue(self: *Ctx, e: u64, attr: *const Attr, v: Val) !void {
        if (attr.value_type == .ref and !key.isAttrPartition(v.ref) and v.ref < key.user_partition_start) return error.NoEntity;
        switch (attr.id) {
            boot.value_type => if (boot.valueTypeOf(v.keyword) == null) return error.ValueType,
            boot.cardinality => if (v.keyword != boot.card_one and v.keyword != boot.card_many) return error.ValueType,
            boot.unique => if (v.keyword != boot.unique_identity and v.keyword != boot.unique_value) return error.ValueType,
            boot.ident => if (e != v.keyword) return self.conflict(e, attr.id),
            else => {},
        }
    }

    fn expandAdd(self: *Ctx, e: u64, attr: *const Attr, v: Val) !void {
        try self.checkAttrValue(e, attr, v);
        const vb = try key.valBytes(self.arena, v);
        const fk = try key.keyBytes(self.arena, .eavt, e, attr.id, vb, null);
        if (self.facts.get(fk)) |i| {
            if (!self.overlay.items[i].added) return self.conflict(e, attr.id);
            return;
        }
        const already = (try self.txn.getFromTree(self.conn.store.trees.cur(.eavt), fk)) != null;
        if (!attr.many()) {
            // One value per (e a) per transaction, whether it is
            // pending or was current already.
            const ea: EA = .{ .e = e, .a = attr.id };
            if (self.one_adds.get(ea)) |seen| return if (std.mem.eql(u8, seen, vb)) {} else self.conflict(e, attr.id);
            try self.one_adds.put(self.arena, ea, vb);
            if (already) return self.kept.put(self.arena, fk, {});
            if (try self.currentOne(e, attr.id)) |old| {
                try self.pushRetract(e, attr, old.val, old.vbytes);
            }
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
            const kv = self.scan.next() orelse return null;
            const parts = try key.unpackKey(self.index, false, kv.key);
            const fk = switch (self.index) {
                .eavt => kv.key,
                .vaet => try key.keyBytes(self.ctx.arena, .eavt, parts.e, parts.a, self.vbytes.?, null),
                else => try key.keyBytes(self.ctx.arena, .eavt, parts.e, parts.a, parts.v, null),
            };
            const pending: ?Pending = if (self.ctx.facts.get(fk)) |i| self.ctx.overlay.items[i] else null;
            return .{ .parts = parts, .kv = kv, .pending = pending, .kept = self.ctx.kept.contains(fk) };
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
        while (try rows.next()) |r| {
            if (r.pending) |p| if (!p.added) continue;
            return .{ .val = try self.valFromParts(r.parts), .vbytes = try self.arena.dupe(u8, r.parts.v) };
        }
        return null;
    }

    /// The value of a current row. An out-of-line payload lives in the
    /// EAVT row's value alone, so it is read by the EAVT key.
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
        if (attr.id == boot.tx_instant and (!added or e != key.txEntity(self.t))) return self.malformed(":db/txInstant is asserted on the transaction's own entity only, and never retracted");
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
                if (p.v.instant < last) return self.malformed("a transaction's :db/txInstant is never earlier than the one before");
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

    /// Attribute entities (NEXTOMIC.md §3 step 5): a new attribute needs
    /// `:db/valueType` and `:db/cardinality`; `:db/valueType` never
    /// changes; `:db/cardinality` may go one → many, and many → one
    /// while no entity holds two values; adding `:db/index` or
    /// `:db/unique` backfills AVET from AEVT; none of them is retracted.
    fn applySchema(self: *Ctx) !void {
        if (!self.schema_touched) return;
        var new_attrs: std.AutoHashMapUnmanaged(u32, struct { value_type: ?key.ValueType = null, has_card: bool = false, many: bool = false }) = .empty;
        var backfill: std.AutoHashMapUnmanaged(u32, *const Attr) = .empty;
        var unique_added: std.AutoHashMapUnmanaged(u32, void) = .empty;
        // Attributes gaining `:db/fulltext true`: existing ones backfill
        // the tokens tree, new ones must be strings.
        var fulltext_backfill: std.AutoHashMapUnmanaged(u32, *const Attr) = .empty;
        var fulltext_new: std.AutoHashMapUnmanaged(u32, void) = .empty;
        // Attributes gaining `:db/isComponent true`, which must be refs.
        var components: std.AutoHashMapUnmanaged(u32, void) = .empty;
        const fulltext_aid = self.conn.store.fulltext_aid;
        // The card-one overwrite of `:db/cardinality` retracts the old
        // value beside the new one; that retraction is the change, not
        // a removal.
        var card_changed: std.AutoHashMapUnmanaged(u32, void) = .empty;
        for (self.overlay.items) |p| {
            if (key.isAttrPartition(p.e) and p.attr.id == boot.cardinality and p.added) try card_changed.put(self.arena, @intCast(p.e), {});
        }
        for (self.overlay.items) |p| {
            if (!key.isAttrPartition(p.e)) continue;
            const a: u32 = @intCast(p.e);
            const existing = self.schema.attr(a);
            if (p.attr.id == fulltext_aid) {
                // A `false` flag gives way to `true`; `true` stays.
                if (!p.added and p.v.boolean) return self.conflict(p.e, p.attr.id);
                if (!p.added or !p.v.boolean) continue;
                if (existing) |ex| {
                    if (ex.value_type != .string) return self.schemaRefused(a, null, ":db/fulltext takes a string attribute");
                    if (!ex.fulltext) try fulltext_backfill.put(self.arena, a, ex);
                } else try fulltext_new.put(self.arena, a, {});
                continue;
            }
            switch (p.attr.id) {
                boot.value_type => {
                    if (!p.added or existing != null) return self.conflict(p.e, p.attr.id);
                    const g = try new_attrs.getOrPut(self.arena, a);
                    if (!g.found_existing) g.value_ptr.* = .{};
                    g.value_ptr.value_type = boot.valueTypeOf(p.v.keyword);
                },
                boot.cardinality => {
                    const many = p.v.keyword == boot.card_many;
                    if (!p.added) {
                        if (card_changed.get(a) == null) return self.conflict(p.e, p.attr.id);
                        continue;
                    }
                    if (existing) |ex| {
                        if (many == ex.many()) continue;
                        if (many and ex.unique != .none) return self.schemaRefused(a, null, "a unique attribute is cardinality one");
                        if (!many) try self.checkSingleValued(ex);
                        continue;
                    }
                    const g = try new_attrs.getOrPut(self.arena, a);
                    if (!g.found_existing) g.value_ptr.* = .{};
                    g.value_ptr.has_card = true;
                    if (many) g.value_ptr.many = true;
                },
                boot.is_component => if (p.added and p.v.boolean) try components.put(self.arena, a, {}),
                boot.unique, boot.index => {
                    if (!p.added and (p.attr.id == boot.unique or p.v.boolean)) return self.conflict(p.e, p.attr.id);
                    if (!p.added or (p.attr.id == boot.index and !p.v.boolean)) continue;
                    if (p.attr.id == boot.unique) try unique_added.put(self.arena, a, {});
                    if (existing) |ex| {
                        if (!ex.inAvet()) {
                            try backfill.put(self.arena, a, ex);
                        } else if (p.attr.id == boot.unique) {
                            try self.checkUniqueAvet(ex);
                        }
                    }
                },
                else => {},
            }
        }
        var it = new_attrs.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.value_type == null or !e.value_ptr.has_card) return self.malformed("a new attribute needs :db/valueType and :db/cardinality");
        }
        // A unique attribute identifies one entity by one value, so it
        // is card-one.
        var uit = unique_added.keyIterator();
        while (uit.next()) |a| {
            const many = if (self.schema.attr(a.*)) |ex| (if (card_changed.get(a.*) != null) !ex.many() else ex.many()) else new_attrs.get(a.*).?.many;
            if (many) return self.malformed("a unique attribute is cardinality one");
        }
        var fit = fulltext_new.keyIterator();
        while (fit.next()) |a| {
            const n = new_attrs.get(a.*) orelse return self.schemaRefused(a.*, null, ":db/fulltext takes a string attribute");
            if (n.value_type != .string) return self.schemaRefused(a.*, null, ":db/fulltext takes a string attribute");
        }
        var cit = components.keyIterator();
        while (cit.next()) |a| {
            const vt = if (self.schema.attr(a.*)) |ex| ex.value_type else if (new_attrs.get(a.*)) |n| n.value_type else null;
            if (vt != .ref) return self.schemaRefused(a.*, null, ":db/isComponent takes a ref attribute");
        }
        var bit = backfill.iterator();
        while (bit.next()) |e| try self.backfillAvet(e.value_ptr.*);
        var fbit = fulltext_backfill.iterator();
        while (fbit.next()) |e| try self.backfillFulltext(e.value_ptr.*);
        // Pending string datoms of an attribute that is full-text from
        // this transaction on belong in the tokens tree too.
        var fkit = fulltext_backfill.keyIterator();
        while (fkit.next()) |a| if (self.attrs.get(a.*)) |c| {
            c.fulltext = true;
        };
    }

    /// Index every current string value of the attribute in the tokens
    /// tree, less this transaction's retractions.
    fn backfillFulltext(self: *Ctx, attr: *const Attr) !void {
        const store = self.conn.store;
        var live = try self.liveRows(.aevt, .{ .a = attr.id });
        while (try live.next()) |r| {
            if (r.pending) |p| if (!p.added) continue;
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
        while (try rows.next()) |r| {
            if (r.pending) |p| if (!p.added) continue;
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

    /// An indexed attribute becoming unique: no value may be held by two
    /// entities, in the tree or in this transaction.
    fn checkUniqueAvet(self: *Ctx, attr: *const Attr) !void {
        var rows = try self.liveRows(.avet, .{ .a = attr.id });
        var prev: ?[]const u8 = null;
        while (try rows.next()) |r| {
            if (r.pending) |p| if (!p.added) continue;
            if (prev) |pv| if (std.mem.eql(u8, pv, r.parts.v)) return self.unique(attr, try self.valFromParts(r.parts));
            prev = try self.arena.dupe(u8, r.parts.v);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (self.overlay.items) |p| {
            if (p.attr.id != attr.id or !p.added) continue;
            if ((try seen.getOrPut(self.arena, p.vbytes)).found_existing) return self.unique(attr, p.v);
            if (try self.findByAv(attr.id, p.vbytes)) |other| if (other != p.e) return self.unique(attr, p.v);
        }
    }

    /// Copy every current `(e v t)` of the attribute from AEVT into AVET
    /// and AVET-h with its original `t`, refusing duplicate values when
    /// the attribute becomes unique.
    fn backfillAvet(self: *Ctx, attr: *const Attr) !void {
        var becomes_unique = false;
        for (self.overlay.items) |p| {
            if (p.e == attr.id and p.attr.id == boot.unique and p.added) becomes_unique = true;
        }
        const store = self.conn.store;
        var rows: std.ArrayList(struct { e: u64, vbytes: []const u8, t: u64 }) = .empty;
        var live = try self.liveRows(.aevt, .{ .a = attr.id });
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        while (try live.next()) |r| {
            if (r.kv.value.len < key.id_len) return error.Corrupted;
            if (r.pending) |p| if (!p.added) continue;
            const vb = try self.arena.dupe(u8, r.parts.v);
            if (becomes_unique) {
                if ((try seen.getOrPut(self.arena, vb)).found_existing) return self.unique(attr, try self.valFromParts(r.parts));
            }
            try rows.append(self.arena, .{ .e = r.parts.e, .vbytes = vb, .t = try key.readId(r.kv.value[0..key.id_len]) });
        }
        if (becomes_unique) {
            for (self.overlay.items) |p| {
                if (p.attr.id != attr.id or !p.added) continue;
                if ((try seen.getOrPut(self.arena, p.vbytes)).found_existing) return self.unique(attr, p.v);
            }
        }
        for (rows.items) |r| {
            const ck = try key.keyBytes(self.arena, .avet, r.e, attr.id, r.vbytes, null);
            var tb: [key.id_len]u8 = undefined;
            key.writeId(&tb, r.t);
            try self.txn.putInTree(store.trees.cur(.avet), ck, &tb);
            const hk = try key.keyBytes(self.arena, .avet, r.e, attr.id, r.vbytes, .{ .t = r.t, .added = true });
            try self.txn.putInTree(store.trees.hist(.avet), hk, &.{});
        }
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
        // The txlog entry is built through a VM heap of its own; the
        // store copies the bytes, so that scratch is freed here.
        var scratch = std.heap.ArenaAllocator.init(self.conn.gpa);
        defer scratch.deinit();
        const names: datom_mod.NameSource = .{ .ctx = @ptrCast(self), .identName = &identName };
        const entry = try datom_mod.encodeTxlog(scratch.allocator(), self.now_ms, self.tx_data, self.excised, names);
        try store.putTxlog(self.txn, self.t, entry);

        try store.writeT(self.txn, self.t);
        if (self.schema_touched) try store.bumpSchemaGen(self.txn);
        if (self.eid_bumped) try store.writeNextEid(self.txn, self.next_eid);
        try self.minter.finish();
    }

    fn identName(ctx: *anyopaque, id: u32) anyerror!?[]const u8 {
        const self: *Ctx = @ptrCast(@alignCast(ctx));
        return self.conn.store.identNameById(self.txn, id);
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
            const k = b.key orelse continue;
            try out.append(self.arena, .{ .key = k, .eid = self.eidOfTempid(@intCast(i)) });
        }
        return out.toOwnedSlice(self.arena);
    }
};

fn isCollection(v: Value) bool {
    return switch (v.kind()) {
        .persistent_vector, .persistent_set, .list => true,
        else => false,
    };
}

fn collectionElements(arena: Allocator, v: Value) ![]Value {
    return (try marshal.collection(arena, v)).?;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const TestConn = db_mod.TestConn;

fn kw(tc: *TestConn, name: []const u8) !u32 {
    return tc.interner.internKeyword(name);
}

/// Install `:user/email` (string, unique identity), `:user/name`
/// (string), `:user/age` (long), `:user/tags` (keyword, many),
/// `:user/friend` (ref, many), `:user/home` (ref, component),
/// `:addr/city` (string), `:user/bio` (string).
fn installSchema(tc: *TestConn, arena: Allocator) !void {
    const ops = [_]Op{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/email") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "name" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/name") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "name" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "name" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "age" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/age") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "age" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_long } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "age" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "tags" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/tags") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "tags" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_keyword } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "tags" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "friend" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/friend") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "friend" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_ref } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "friend" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/home") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_ref } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.is_component }, .v = .{ .val = .{ .boolean = true } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "city" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "addr/city") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "city" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "city" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bio" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/bio") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bio" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bio" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    };
    const r = try transactOps(tc.conn, arena, &ops, .{});
    try testing.expectEqual(@as(u64, 2), r.t);
    try testing.expectEqual(@as(usize, 8), r.tempids.len);
}

fn attrId(tc: *TestConn, name: []const u8) !u32 {
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    return (try tc.conn.idents.idOfName(txn, name)).?;
}

test "schema install then asserts, card-one overwrite, no-op, retract" {
    const tc = try TestConn.init("tx_basic");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);

    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    try testing.expectEqual(boot.next_aid, email);

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .fixnum = -1 } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
    }, .{});
    try testing.expectEqual(@as(u64, 3), r1.t);
    try testing.expectEqual(@as(usize, 2), r1.tempids.len);
    const a = r1.tempids[0].eid;
    try testing.expectEqual(key.user_partition_start, a);
    try testing.expectEqual(@as(usize, 4), r1.tx_data.len);
    try testing.expectEqual(boot.tx_instant, r1.tx_data[3].a);
    try testing.expectEqual(@as(u64, 2), r1.db_before.basis);
    try testing.expectEqual(@as(u64, 3), r1.db_after.basis);

    // Overwrite card-one: one retract, one add. Re-assert: nothing.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r2.tx_data.len);
    try testing.expect(!r2.tx_data[0].added and r2.tx_data[1].added);
    try testing.expectEqualStrings("Ann", r2.tx_data[0].v.string);

    const db = try tc.conn.db();
    const ds = try db.datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 2), ds.len);
    try testing.expectEqualStrings("Anne", ds[1].v.string);
    try testing.expectEqual(@as(u64, 4), ds[1].t);
    try testing.expectEqual(@as(u64, 3), ds[0].t);

    // as-of 3 shows Ann; history shows all three name rows.
    const old = try db.asOf(3).datoms(arena, .eavt, .{ .e = a, .a = name });
    try testing.expectEqualStrings("Ann", old[0].v.string);
    const hist = try db.withHistory().datoms(arena, .eavt, .{ .e = a, .a = name });
    try testing.expectEqual(@as(usize, 3), hist.len);

    // Lookup ref and ident-based attribute resolution; retract; retract-attr.
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .lookup = .{ .a = .{ .ident = try kw(tc, "user/email") }, .v = .{ .string = "a@x" } } }, .a = .{ .ident = try kw(tc, "user/name") }, .v = .{ .val = .{ .string = "Anne" } } } },
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "never" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r3.tx_data.len);
    const after = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 1), after.len);
    try testing.expectEqual(email, after[0].a);
    try testing.expectEqual(@as(u64, 0), (try (try tc.conn.db()).attr(name)).?.count);
    try testing.expectEqual(@as(u64, 1), (try (try tc.conn.db()).attr(email)).?.count);

    // Errors.
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = try kw(tc, "user/nope") }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    try testing.expectError(error.ValueType, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "nobody" } } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    // A failed transaction left t alone.
    try testing.expectEqual(@as(u64, 5), (try tc.conn.db()).basis);
}

test "unique identity upsert, unique conflicts, card-many, retractEntity cascade" {
    const tc = try TestConn.init("tx_unique");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const tags = try attrId(tc, "user/tags");
    const friend = try attrId(tc, "user/friend");
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/red") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/blue") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "h" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "a" } } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const h = r1.tempids[1].eid;
    const b = r1.tempids[2].eid;
    try testing.expect(a != h and h != b);

    // Upsert: a new tempid with a's email is a.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    try testing.expectEqual(a, r2.tempids[0].eid);
    try testing.expectEqual(@as(usize, 2), r2.tx_data.len);

    // Two tempids with one identity unify; a same-tx lookup ref resolves.
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "c@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "c@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Cy" } } } },
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "c@x" } } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/red") } } },
    }, .{});
    try testing.expectEqual(r3.tempids[0].eid, r3.tempids[1].eid);
    try testing.expectEqual(@as(usize, 4), r3.tx_data.len);

    // Unique collision with an explicit different entity.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
    }, .{}));
    // Same-transaction unique collision.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n1" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "z@x" } } } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "z@x" } } } },
    }, .{}));

    // Card-many re-assert is a no-op; retract-attr removes both tags.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/red") } } },
        .{ .retract_attr = .{ .e = .{ .eid = b }, .a = .{ .id = friend } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r4.tx_data.len);
    try testing.expect(!r4.tx_data[0].added);

    // VAET: nobody points at a now.
    const db4 = try tc.conn.db();
    const vb = try key.valBytes(arena, .{ .ref = a });
    try testing.expectEqual(@as(usize, 0), (try db4.datoms(arena, .vaet, .{ .v = vb })).len);
    try testing.expectEqual(@as(usize, 1), (try db4.asOf(r3.t).datoms(arena, .vaet, .{ .v = vb })).len);

    // retractEntity a: its datoms, the component home h, and nothing else.
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a } } } },
    }, .{});
    _ = r5;
    const r6 = try transactOps(tc.conn, arena, &.{.{ .retract_entity = .{ .eid = a } }}, .{});
    const db6 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db6.datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 0), (try db6.datoms(arena, .eavt, .{ .e = h })).len);
    try testing.expectEqual(@as(usize, 1), (try db6.datoms(arena, .eavt, .{ .e = b })).len);
    var retracted: usize = 0;
    for (r6.tx_data) |d| {
        if (!d.added) retracted += 1;
    }
    // a: email, name, tags x2, home; h: city; b: friend -> a.
    try testing.expectEqual(@as(usize, 7), retracted);
    try testing.expectEqual(@as(usize, 10), (try db6.withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 2), (try db6.withHistory().datoms(arena, .eavt, .{ .e = h })).len);
}

test "schema changes: index backfill, unique backfill refusal, immutable type" {
    const tc = try TestConn.init("tx_schema");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{});
    const a = r1.tempids[0].eid;

    // AVET on name is empty before the index, full after, with original t.
    const nb = try key.valBytes(arena, .{ .string = "Ann" });
    try testing.expectEqual(@as(usize, 0), (try (try tc.conn.db()).datoms(arena, .avet, .{ .a = name, .v = nb })).len);
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.index }, .v = .{ .val = .{ .boolean = true } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const db2 = try tc.conn.db();
    const hits = try db2.datoms(arena, .avet, .{ .a = name, .v = nb });
    try testing.expectEqual(@as(usize, 1), hits.len);
    try testing.expectEqual(r1.t, hits[0].t);
    const ab = try key.valBytes(arena, .{ .string = "Anne" });
    try testing.expectEqual(@as(usize, 1), (try db2.datoms(arena, .avet, .{ .a = name, .v = ab })).len);
    try testing.expect((try db2.attr(name)).?.indexed);
    try testing.expect(!(try db2.asOf(r1.t).attr(name)).?.indexed);
    _ = r2;

    // Unique on age is fine (distinct values); unique on name would collide.
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = age }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } },
    }, .{});
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "c" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } },
    }, .{}));
    // Value type never changes.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = age }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
    }, .{}));
    // A new attribute needs a type and a cardinality; a bad type ident is refused.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/half") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
    }, .{}));
    try testing.expectError(error.ValueType, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/bad") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{}));
    // An ident on a user entity is refused; the aborted mints were not kept.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/alias") } } },
    }, .{}));
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    try testing.expect((try tc.conn.idents.idOfName(txn, "user/half")) == null);
}

test "Lisp tx-data: vector forms, map forms, nested maps, card-many vectors, datomic.tx" {
    const tc = try TestConn.init("tx_lisp");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const dispatch = @import("../dispatch.zig");
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const home = try attrId(tc, "user/home");
    const tags = try attrId(tc, "user/tags");
    const city = try attrId(tc, "addr/city");
    const friend = try attrId(tc, "user/friend");

    const K = struct {
        fn k(t: *TestConn, n: []const u8) !Value {
            return t.interner.internKeywordValue(n);
        }
    };
    const s = struct {
        fn s(h: *@import("../heap.zig").Heap, t: []const u8) !Value {
            return string_mod.fromBytes(h, t);
        }
    };
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "db/id"), try s.s(&heap, "ann"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/email"), try s.s(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    const tagv = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "tag/a"), try K.k(tc, "tag/b") });
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/tags"), tagv, &dispatch.hashValue, &dispatch.equal);
    var nested = try champ.mapEmpty(&heap);
    nested = try champ.mapAssoc(&heap, nested, try K.k(tc, "addr/city"), try s.s(&heap, "Rome"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/home"), nested, &dispatch.hashValue, &dispatch.equal);
    const friends = try vector_mod.fromSlice(&heap, &.{try s.s(&heap, "bob")});
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/friend"), friends, &dispatch.hashValue, &dispatch.equal);

    const add_bob = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "db/add"), try s.s(&heap, "bob"), try K.k(tc, "user/email"), try s.s(&heap, "bob@x") });
    const tx_doc = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "db/add"), try s.s(&heap, "datomic.tx"), try K.k(tc, "db/doc"), try s.s(&heap, "import") });
    const tx_data = try vector_mod.fromSlice(&heap, &.{ m, add_bob, tx_doc });

    const r = try transactOps(tc.conn, arena, &.{}, .{});
    _ = r;
    const clock = store_mod.nowMillis() + 42_000;
    const rep = try transact(tc.conn, arena, tx_data, .{ .now_ms = clock });
    try testing.expectEqual(@as(usize, 2), rep.tempids.len);
    const ann = rep.tempids[0].eid;
    const bob = rep.tempids[1].eid;
    const db = try tc.conn.db();
    const ent = try db.entity(arena, ann);
    try testing.expectEqual(@as(usize, 4), ent.len);
    try testing.expectEqual(email, ent[0].a);
    try testing.expectEqual(tags, ent[1].a);
    try testing.expectEqual(@as(usize, 2), ent[1].vals.len);
    try testing.expectEqual(friend, ent[2].a);
    try testing.expectEqual(bob, ent[2].vals[0].ref);
    try testing.expectEqual(home, ent[3].a);
    const home_e = ent[3].vals[0].ref;
    const home_ent = try db.entity(arena, home_e);
    try testing.expectEqual(city, home_ent[0].a);
    try testing.expectEqualStrings("Rome", home_ent[0].vals[0].string);
    const txe = try db.entity(arena, key.txEntity(rep.t));
    try testing.expectEqual(@as(usize, 2), txe.len);
    try testing.expectEqual(boot.doc, txe[0].a);
    try testing.expectEqual(clock, txe[1].vals[0].instant);

    // retractEntity by lookup ref through a vector form.
    const lookup = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try s.s(&heap, "bob@x") });
    const re = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "db/retractEntity"), lookup });
    const rep2 = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{re}), .{});
    try testing.expectEqual(@as(usize, 3), rep2.tx_data.len);
    try testing.expectEqual(@as(usize, 0), (try (try tc.conn.db()).entity(arena, bob)).len);

    // Malformed forms.
    const bad = try vector_mod.fromSlice(&heap, &.{try K.k(tc, "db/add")});
    try testing.expectError(error.TxData, transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{bad}), .{}));
    try testing.expectError(error.TxData, transact(tc.conn, arena, try s.s(&heap, "nope"), .{}));
}

/// Lisp values for tx-data tests.
const Lisp = struct {
    tc: *TestConn,
    heap: *@import("../heap.zig").Heap,

    const dispatch = @import("../dispatch.zig");
    const KV = struct { []const u8, Value };

    fn kw(self: Lisp, name: []const u8) !Value {
        return self.tc.interner.internKeywordValue(name);
    }
    fn str(self: Lisp, text: []const u8) !Value {
        return string_mod.fromBytes(self.heap, text);
    }
    fn vec(self: Lisp, items: []const Value) !Value {
        return vector_mod.fromSlice(self.heap, items);
    }
    fn map(self: Lisp, entries: []const KV) !Value {
        var m = try champ.mapEmpty(self.heap);
        for (entries) |e| m = try champ.mapAssoc(self.heap, m, try self.kw(e[0]), e[1], &dispatch.hashValue, &dispatch.equal);
        return m;
    }
};

test "a reverse ref in a map form asserts the forward datom" {
    const tc = try TestConn.init("tx_reverse");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);
    const friend = try attrId(tc, "user/friend");
    const home = try attrId(tc, "user/home");

    // Ann and Bob befriend Cy through Cy's map; Cy's home names its
    // owner through a reverse component ref, from a nested map.
    const r = try transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("ann") }, .{ "user/email", try l.str("ann@x") } }),
        try l.map(&.{ .{ "db/id", try l.str("bob") }, .{ "user/email", try l.str("bob@x") } }),
        try l.map(&.{
            .{ "db/id", try l.str("cy") },
            .{ "user/email", try l.str("cy@x") },
            .{ "user/_friend", try l.vec(&.{ try l.str("ann"), try l.vec(&.{ try l.kw("user/email"), try l.str("bob@x") }) }) },
        }),
        try l.map(&.{ .{ "addr/city", try l.str("Rome") }, .{ "user/_home", try l.str("cy") } }),
        try l.map(&.{ .{ "db/id", try l.str("di") }, .{ "user/email", try l.str("di@x") }, .{ "user/_friend", try l.map(&.{.{ "user/email", try l.str("ed@x") }}) } }),
    }), .{});
    var ann: u64 = 0;
    var bob: u64 = 0;
    var cy: u64 = 0;
    var di: u64 = 0;
    for (r.tempids) |b| {
        if (std.mem.eql(u8, b.key.string, "ann")) ann = b.eid;
        if (std.mem.eql(u8, b.key.string, "bob")) bob = b.eid;
        if (std.mem.eql(u8, b.key.string, "cy")) cy = b.eid;
        if (std.mem.eql(u8, b.key.string, "di")) di = b.eid;
    }
    const db = try tc.conn.db();
    const ann_friends = try db.datoms(arena, .eavt, .{ .e = ann, .a = friend });
    try testing.expectEqual(@as(usize, 1), ann_friends.len);
    try testing.expectEqual(cy, ann_friends[0].v.ref);
    const bob_friends = try db.datoms(arena, .eavt, .{ .e = bob, .a = friend });
    try testing.expectEqual(cy, bob_friends[0].v.ref);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .eavt, .{ .e = cy, .a = friend })).len);
    const cy_home = try db.datoms(arena, .eavt, .{ .e = cy, .a = home });
    try testing.expectEqual(@as(usize, 1), cy_home.len);
    const ed_friends = try db.datoms(arena, .vaet, .{ .a = friend, .v = try key.valBytes(arena, .{ .ref = di }) });
    try testing.expectEqual(@as(usize, 1), ed_friends.len);

    // A reverse ref needs a ref attribute and an entity value.
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("x") }, .{ "user/_email", try l.str("ann@x") } }),
    }), .{}));
    try testing.expectError(error.UnknownAttribute, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("x") }, .{ "user/_nope", try l.str("ann") } }),
    }), .{}));
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{ .{ "db/id", try l.str("x") }, .{ "user/_friend", value.fromBool(true) } }),
    }), .{}));
}

test "a nested map under a plain ref must carry an identity" {
    const tc = try TestConn.init("tx_nested_identity");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);

    // Under a component, or with a unique attribute or a :db/id, a
    // nested map is an entity; otherwise it would be an orphan.
    const ok = try transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{
            .{ "user/email", try l.str("ann@x") },
            .{ "user/home", try l.map(&.{.{ "addr/city", try l.str("Rome") }}) },
            .{ "user/friend", try l.vec(&.{
                try l.map(&.{.{ "user/email", try l.str("bob@x") }}),
                try l.map(&.{ .{ "db/id", try l.str("cy") }, .{ "user/name", try l.str("Cy") } }),
            }) },
        }),
    }), .{});
    try testing.expectEqual(@as(usize, 1), ok.tempids.len);
    const ann = (try (try tc.conn.db()).entid(arena, .{ .lookup = .{ .a = try attrId(tc, "user/email"), .v = .{ .string = "ann@x" } } })).?;
    try testing.expectEqual(@as(usize, 2), (try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = try attrId(tc, "user/friend") })).len);
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.map(&.{
            .{ "user/email", try l.str("ann@x") },
            .{ "user/friend", try l.map(&.{.{ "user/name", try l.str("Orphan") }}) },
        }),
    }), .{}));
}

test "nested map forms past the stack budget fail with StackOverflow and abort" {
    const tc = try TestConn.init("tx_nested_deep");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);

    var m = try l.map(&.{.{ "addr/city", try l.str("Rome") }});
    for (0..100_000) |_| m = try l.map(&.{.{ "user/home", m }});
    stack.arm(1 << 20);
    defer stack.arm(stack.main_thread_budget);
    try testing.expectError(error.StackOverflow, transact(tc.conn, arena, try l.vec(&.{m}), .{}));
    // The write transaction is gone: the next one takes the next t.
    var shallow = try l.map(&.{.{ "addr/city", try l.str("Oslo") }});
    for (0..50) |_| shallow = try l.map(&.{.{ "user/home", shallow }});
    const r = try transact(tc.conn, arena, try l.vec(&.{shallow}), .{});
    try testing.expectEqual(@as(u64, 3), r.t);
    try testing.expectEqual(@as(usize, 52), r.tx_data.len);
}

test "a failing transaction reports what it was looking at" {
    const tc = try TestConn.init("tx_fault");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const age = try attrId(tc, "user/age");
    const k_email = try kw(tc, "user/email");
    const k_age = try kw(tc, "user/age");
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    const a = r.tempids[0].eid;

    var fault: Fault = .{};
    // Unique: the attribute and the value.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(k_email, fault.attr.?.asKeywordId());
    try testing.expectEqualStrings("b@x", fault.value.?.string);
    try testing.expect(fault.e == null);
    // Conflict: the entity and the attribute.
    fault = .{};
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(k_age, fault.attr.?.asKeywordId());
    try testing.expectEqual(a, fault.e.?);
    // Unknown attribute: as the program named it.
    fault = .{};
    const k_nope = try kw(tc, "user/nope");
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = k_nope }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(k_nope, fault.attr.?.asKeywordId());
    fault = .{};
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = 4000 }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(@as(i64, 4000), fault.attr.?.asFixnum());
    // Malformed tx-data: the reason.
    fault = .{};
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{
        try l.vec(&.{ try l.kw("db/add"), value.fromFixnum(@intCast(a)).?, try l.kw("user/age") }),
    }), .{ .fault = &fault }));
    try testing.expect(fault.message != null);
    // Nothing is reported when nothing fails, and a fault is optional.
    fault = .{};
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
    }, .{ .fault = &fault });
    try testing.expect(fault.attr == null and fault.message == null);
}

test "a card-many attribute cannot be unique" {
    const tc = try TestConn.init("tx_unique_many");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const tags = try attrId(tc, "user/tags");

    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = tags }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_value } } } },
    }, .{}));
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/nick") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{}));
    try testing.expect((try (try tc.conn.db()).attr(tags)).?.unique == .none);
}

test "long strings round trip through the payload in every view" {
    const tc = try TestConn.init("tx_long");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const bio = try attrId(tc, "user/bio");
    const long = "L" ** 40_000;
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = long } } } },
    }, .{});
    const a = r.tempids[0].eid;
    const db = try tc.conn.db();
    for ([_]DbValue{ db, db.asOf(r.t), db.withHistory(), db.sinceT(r.t - 1) }) |view| {
        const ds = try view.datoms(arena, .eavt, .{ .e = a });
        try testing.expectEqual(@as(usize, 1), ds.len);
        try testing.expectEqualStrings(long, ds[0].v.string);
        const via_aevt = try view.datoms(arena, .aevt, .{ .a = bio });
        try testing.expectEqualStrings(long, via_aevt[0].v.string);
    }
    // Re-assertion is a no-op; a different long value with the same prefix replaces it.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = long } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    const other = long[0 .. long.len - 1] ++ "M";
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = other } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r3.tx_data.len);
    try testing.expectEqualStrings(long, r3.tx_data[0].v.string);
    const now = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqualStrings(other, now[0].v.string);
    const txs = try db_mod.txRange(tc.conn, arena, r3.t, null);
    try testing.expectEqualStrings(other, txs[0].datoms[1].v.string);
}

test "with: the view sees the speculative state, the connection does not" {
    const tc = try TestConn.init("tx_with");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const tags = try attrId(tc, "user/tags");
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");
    const k_new = try kw(tc, "tag/new");
    const before = try tc.conn.db();

    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = k_new } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "h" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
    }, .{});
    defer w.destroy();

    // The report.
    try testing.expectEqual(before.basis + 1, w.report.t);
    try testing.expectEqual(before.basis, w.report.db_before.basis);
    try testing.expectEqual(w.report.t, w.db().basis);
    try testing.expectEqual(@as(usize, 2), w.report.tempids.len);
    try testing.expectEqual(@as(usize, 6), w.report.tx_data.len);
    const a = w.report.tempids[0].eid;
    const h = w.report.tempids[1].eid;

    // Every read of the view sees the speculative datoms.
    const view = w.db();
    try testing.expectEqual(@as(usize, 4), (try view.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 1), (try view.datoms(arena, .aevt, .{ .a = email })).len);
    const hb = try key.valBytes(arena, .{ .ref = h });
    try testing.expectEqual(@as(usize, 1), (try view.datoms(arena, .vaet, .{ .v = hb })).len);
    try testing.expectEqual(@as(?u64, a), try view.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a@x" } } }));
    try testing.expectEqual(@as(u64, 1), (try view.attr(email)).?.count);
    const entries = try db_mod.txRange(w.view, arena, w.report.t, null);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(usize, 6), entries[0].datoms.len);
    try testing.expectEqual(w.report.t, (try w.view.db()).basis);
    // Time travel on the view folds the speculative rows like any other.
    try testing.expectEqual(@as(usize, 0), (try view.asOf(before.basis).entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 4), (try view.withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 4), (try view.sinceT(before.basis).datoms(arena, .eavt, .{ .e = a })).len);
    // The minted keyword resolves through the view's cache only.
    {
        const txn = try w.view.beginReadTxn();
        defer w.view.endReadTxn(txn);
        try testing.expect((try w.view.idents.idOf(txn, k_new)) != null);
    }
    try testing.expect(tc.conn.idents.by_intern.get(k_new) == null);

    // The committed state is untouched.
    try testing.expectEqual(before.basis, (try tc.conn.db()).basis);
    try testing.expectEqual(@as(usize, 0), (try before.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try w.report.db_before.entity(arena, a)).len);
    try testing.expectEqual(@as(u64, 0), (try before.attr(email)).?.count);

    // One write transaction per store: nothing else may begin one.
    try testing.expectError(error.Nested, withOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Nested, transactOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Nested, transactOps(w.view, arena, &.{}, .{}));
    try testing.expectError(error.Nested, withOps(w.view, arena, &.{}, .{}));

    w.finish();
    w.finish();
    try testing.expectError(error.Closed, view.entity(arena, a));
    try testing.expect(tc.conn.speculative == null);
    try testing.expectEqual(before.basis, (try tc.conn.db()).basis);
    {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        try testing.expect((try tc.conn.idents.idOf(txn, k_new)) == null);
    }

    // A real transaction takes the same t, the same eid and the same ident id.
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = tags }, .v = .{ .keyword = k_new } } },
    }, .{});
    try testing.expectEqual(w.report.t, r.t);
    try testing.expectEqual(a, r.tempids[0].eid);
    try testing.expectEqual(w.report.tx_data[2].v.keyword, r.tx_data[1].v.keyword);
    try testing.expectEqual(@as(usize, 2), (try (try tc.conn.db()).entity(arena, a)).len);
}

test "with: errors surface without holding the write transaction; schema changes stay in the view" {
    const tc = try TestConn.init("tx_with_err");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const age = try attrId(tc, "user/age");
    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    const a = r0.tempids[0].eid;
    const b = r0.tempids[1].eid;

    try testing.expectError(error.Conflict, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 1 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 2 } } } },
    }, .{}));
    try testing.expectError(error.Unique, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
    }, .{}));
    try testing.expectError(error.UnknownAttribute, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = try kw(tc, "user/nope") }, .v = .{ .val = .{ .long = 1 } } } },
    }, .{}));
    try testing.expectError(error.ValueType, withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    try testing.expect(tc.conn.speculative == null);
    try testing.expectEqual(r0.t, (try tc.conn.db()).basis);
    try testing.expectEqual(@as(usize, 1), (try (try tc.conn.db()).entity(arena, a)).len);

    // A speculative attribute exists in the view and nowhere else.
    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/nick") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{});
    defer w.destroy();
    const nick: u32 = @intCast(w.report.tempids[0].eid);
    try testing.expectEqual(key.ValueType.string, (try w.db().attr(nick)).?.value_type);
    try testing.expectEqual(@as(?u64, nick), try w.db().entid(arena, .{ .ident = try kw(tc, "user/nick") }));
    try testing.expect((try (try tc.conn.db()).attr(nick)) == null);
    w.finish();
    try testing.expect((try (try tc.conn.db()).attr(nick)) == null);
    try testing.expectEqual(r0.t, (try tc.conn.db()).basis);
    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
    }, .{});
    try testing.expectEqual(r0.t + 1, r1.t);
}

test "with: Lisp tx-data" {
    const tc = try TestConn.init("tx_with_lisp");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const add = try vector_mod.fromSlice(&heap, &.{
        try tc.interner.internKeywordValue("db/add"),
        try string_mod.fromBytes(&heap, "z"),
        try tc.interner.internKeywordValue("user/name"),
        try string_mod.fromBytes(&heap, "Zed"),
    });
    const clock = store_mod.nowMillis() + 7_000;
    const w = try with(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{add}), .{ .now_ms = clock });
    defer w.destroy();
    const z = w.report.tempids[0].eid;
    const ent = try w.db().entity(arena, z);
    try testing.expectEqual(@as(usize, 1), ent.len);
    try testing.expectEqual(name, ent[0].a);
    try testing.expectEqualStrings("Zed", ent[0].vals[0].string);
    try testing.expectEqual(clock, (try w.db().entity(arena, key.txEntity(w.report.t)))[0].vals[0].instant);
    w.finish();
    try testing.expectError(error.TxData, with(tc.conn, arena, try string_mod.fromBytes(&heap, "nope"), .{}));
    try testing.expect(tc.conn.speculative == null);
}

test "a string with an escaped NUL never aliases its prefix under a prefix scan" {
    const tc = try TestConn.init("tx_nul_alias");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");

    // x's identity is "a\x00b", whose encoding starts with the encoding of "a".
    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a\x00b" } } } },
    }, .{});
    const x = r1.tempids[0].eid;
    const db = try tc.conn.db();
    const a_bytes = try key.valBytes(arena, .{ .string = "a" });

    // Reads: no datom carries "a".
    try testing.expect((try db.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a" } } })) == null);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .avet, .{ .a = email, .v = a_bytes })).len);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .eavt, .{ .e = x, .a = email, .v = a_bytes })).len);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .aevt, .{ .a = email, .e = x, .v = a_bytes })).len);
    try testing.expectEqual(@as(?u64, x), try db.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a\x00b" } } }));

    // Writes: "a" is free, so another entity may take it, and a tempid
    // claiming it is a new entity rather than an upsert onto x.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "z" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "z" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Zed" } } } },
    }, .{});
    const z = r2.tempids[0].eid;
    try testing.expect(z != x);
    const db2 = try tc.conn.db();
    const xs = try db2.datoms(arena, .eavt, .{ .e = x, .a = email });
    try testing.expectEqual(@as(usize, 1), xs.len);
    try testing.expectEqualStrings("a\x00b", xs[0].v.string);
    try testing.expectEqual(@as(?u64, z), try db2.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a" } } }));
    // A lookup ref on "a" now names z, not x.
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "a\x00" } } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "nobody" } } } },
    }, .{}));
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "a" } } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Zed2" } } } },
    }, .{});
    try testing.expectEqual(z, r3.tx_data[0].e);
}

test "explicit entity ids must have been allocated" {
    const tc = try TestConn.init("tx_explicit_eid");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const friend = try attrId(tc, "user/friend");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const next_aid = blk: {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        break :blk try tc.conn.store.readNextAid(txn);
    };

    // A user id the allocator has not handed out; an attribute-partition
    // id no ident holds; a transaction entity that does not exist yet.
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a + 5 }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "ghost" } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = next_aid + 100 }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "ghost" } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = key.txEntity(r1.t + 5) }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "ghost" } } } },
    }, .{}));
    // The same ids as ref values.
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a + 5 } } } },
    }, .{}));
    try testing.expectError(error.NoEntity, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .entity = .{ .eid = key.txEntity(r1.t + 5) } } } },
    }, .{}));
    try testing.expectEqual(r1.t, (try tc.conn.db()).basis);

    // Allocated ids are fine: an existing entity, an attribute entity, a
    // past transaction entity and this transaction's own entity, as
    // entities and as ref values.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = key.txEntity(r1.t) } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = name } } } },
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "a name" } } } },
        .{ .add = .{ .e = .{ .eid = key.txEntity(r1.t) }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "old tx" } } } },
        .{ .add = .{ .e = .{ .eid = key.txEntity(r1.t + 1) }, .a = .{ .id = boot.doc }, .v = .{ .val = .{ .string = "this tx" } } } },
    }, .{});
    try testing.expectEqual(r1.t + 1, r2.t);
    try testing.expectEqual(@as(usize, 7), r2.tx_data.len);
    // An allocated entity stays addressable after every datom is retracted.
    _ = try transactOps(tc.conn, arena, &.{.{ .retract_entity = .{ .eid = a } }}, .{});
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Back" } } } },
    }, .{});
    try testing.expectEqual(a, r4.tx_data[0].e);
}

/// Transact one new entity with a fresh keyword value while allocation
/// `fail_index` of `where` fails; returns whether a failure was induced.
fn transactWithFailure(tc: *TestConn, arena: Allocator, name: u32, tags: u32, where: enum { arena, cache }, fail_index: usize) !bool {
    var tx_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tx_arena.deinit();
    var fa = std.testing.FailingAllocator.init(if (where == .arena) tx_arena.allocator() else testing.allocator, .{ .fail_index = fail_index });
    const saved_gpa = tc.conn.idents.gpa;
    if (where == .cache) {
        // An empty cache has to grow for the mint, so the publication's
        // own allocation is in the sweep.
        tc.conn.idents.by_intern.clearAndFree(saved_gpa);
        tc.conn.idents.by_ident.clearAndFree(saved_gpa);
        tc.conn.idents.gpa = fa.allocator();
    }
    defer tc.conn.idents.gpa = saved_gpa;
    const tag = try kw(tc, try std.fmt.allocPrint(arena, "tag/oom-{s}-{d}", .{ @tagName(where), fail_index }));
    const before = (try tc.conn.db()).basis;
    const result = transactOps(tc.conn, if (where == .arena) fa.allocator() else tx_arena.allocator(), &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = tags }, .v = .{ .keyword = tag } } },
    }, .{});
    const after = (try tc.conn.db()).basis;
    if (result) |r| {
        try testing.expectEqual(before + 1, r.t);
        try testing.expectEqual(before + 1, after);
        try testing.expectEqual(@as(usize, 1), r.tempids.len);
        try testing.expectEqual(@as(usize, 3), r.tx_data.len);
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(before, after);
    }
    return fa.has_induced_failure;
}

test "an allocation failure never reports an error for a committed transaction" {
    const tc = try TestConn.init("tx_oom");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const tags = try attrId(tc, "user/tags");

    // Every allocation the transaction makes, first in its arena and
    // then in the ident cache, fails once at index i. Either the
    // transaction errors and t is untouched, or it commits and reports.
    inline for (.{ .arena, .cache }) |where| {
        var fail_index: usize = 0;
        while (try transactWithFailure(tc, arena, name, tags, where, fail_index)) : (fail_index += 1) {}
        try testing.expect(fail_index > @as(usize, if (where == .arena) 8 else 0));
    }
}

test "retractEntity expands against the committed state; the transaction's own datoms survive" {
    const tc = try TestConn.init("tx_retract_pending");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const friend = try attrId(tc, "user/friend");
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");

    // A tempid asserted and retracted in one transaction: the retraction
    // sees nothing committed, so the assertion stands.
    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "X" } } } },
        .{ .retract_entity = .{ .tempid = .{ .string = "x" } } },
    }, .{});
    const x = r1.tempids[0].eid;
    try testing.expectEqual(@as(usize, 2), r1.tx_data.len);
    try testing.expectEqual(@as(usize, 1), (try (try tc.conn.db()).entity(arena, x)).len);

    // A pending inbound ref is not a current (e' a' e) datom: it stays.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "h1" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h1" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "B" } } } },
    }, .{});
    const a = r2.tempids[0].eid;
    const h1 = r2.tempids[1].eid;
    const b = r2.tempids[2].eid;
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = friend }, .v = .{ .val = .{ .ref = a } } } },
        .{ .retract_entity = .{ .eid = a } },
    }, .{});
    var retracted: usize = 0;
    for (r3.tx_data) |d| {
        if (!d.added) retracted += 1;
    }
    // a: name, age, home; h1: city.
    try testing.expectEqual(@as(usize, 4), retracted);
    const db3 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db3.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try db3.entity(arena, h1)).len);
    const ab = try key.valBytes(arena, .{ .ref = a });
    try testing.expectEqual(@as(usize, 1), (try db3.datoms(arena, .vaet, .{ .v = ab })).len);

    // A component replaced and its parent retracted in one transaction:
    // the committed component goes with the parent, the new one stays.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "P" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "old" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "old" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
    }, .{});
    const p = r4.tempids[0].eid;
    const old = r4.tempids[1].eid;
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = p }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = "new" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "new" } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "Rome" } } } },
        .{ .retract_entity = .{ .eid = p } },
    }, .{});
    const new = r5.tempids[0].eid;
    const db5 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db5.entity(arena, old)).len);
    const p_now = try db5.entity(arena, p);
    try testing.expectEqual(@as(usize, 1), p_now.len);
    try testing.expectEqual(home, p_now[0].a);
    try testing.expectEqual(new, p_now[0].vals[0].ref);
    try testing.expectEqualStrings("Rome", (try db5.entity(arena, new))[0].vals[0].string);

    // retractEntity followed by an assertion on the same entity in one
    // transaction: the assertion is the entity's only datom afterwards.
    const r6 = try transactOps(tc.conn, arena, &.{
        .{ .retract_entity = .{ .eid = b } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 5 } } } },
    }, .{});
    _ = r6;
    const bn = try (try tc.conn.db()).entity(arena, b);
    try testing.expectEqual(@as(usize, 1), bn.len);
    try testing.expectEqual(age, bn[0].a);
}

test "retractEntity follows a component chain of any length" {
    const tc = try TestConn.init("tx_retract_chain");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const home = try attrId(tc, "user/home");
    const city = try attrId(tc, "addr/city");

    // c0 -> c1 -> ... -> cn through the component `:user/home`; a
    // native frame per level would exhaust the stack long before n.
    const n = 20_000;
    var ops: std.ArrayList(Op) = .empty;
    var names: [n + 1][]const u8 = undefined;
    for (&names, 0..) |*nm, i| nm.* = try std.fmt.allocPrint(arena, "c{d}", .{i});
    for (0..n) |i| try ops.append(arena, .{ .add = .{ .e = .{ .tempid = .{ .string = names[i] } }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .string = names[i + 1] } } } } });
    try ops.append(arena, .{ .add = .{ .e = .{ .tempid = .{ .string = names[n] } }, .a = .{ .id = city }, .v = .{ .val = .{ .string = "end" } } } });
    const r = try transactOps(tc.conn, arena, ops.items, .{});
    const head = r.tempids[0].eid;
    const tail = r.tempids[n].eid;
    const gone = try transactOps(tc.conn, arena, &.{.{ .retract_entity = .{ .eid = head } }}, .{});
    // Every home link and the tail's city, then the instant.
    try testing.expectEqual(@as(usize, n + 2), gone.tx_data.len);
    const db = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db.entity(arena, tail)).len);
    try testing.expectEqual(@as(usize, 0), (try db.datoms(arena, .aevt, .{ .a = home })).len);
}

test "a lookup ref under a card-many ref attribute is one ref; a vector of them is a collection" {
    const tc = try TestConn.init("tx_lookup_many");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const dispatch = @import("../dispatch.zig");
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const friend = try attrId(tc, "user/friend");
    const tags = try attrId(tc, "user/tags");

    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "bob" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "bob@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "cy" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "cy@x" } } } },
    }, .{});
    const bob = r0.tempids[0].eid;
    const cy = r0.tempids[1].eid;

    const K = struct {
        fn k(t: *TestConn, n: []const u8) !Value {
            return t.interner.internKeywordValue(n);
        }
    };
    const lookup_bob = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "bob@x") });
    const lookup_cy = try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "cy@x") });

    // One lookup ref: one friend.
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "ann"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, try K.k(tc, "user/friend"), lookup_bob, &dispatch.hashValue, &dispatch.equal);
    const r1 = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{m}), .{});
    try testing.expectEqual(@as(usize, 1), r1.tempids.len);
    const ann = r1.tempids[0].eid;
    const friends1 = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = friend });
    try testing.expectEqual(@as(usize, 1), friends1.len);
    try testing.expectEqual(bob, friends1[0].v.ref);

    // A vector of lookup refs and tempids: one friend each.
    const many = try vector_mod.fromSlice(&heap, &.{ lookup_cy, try string_mod.fromBytes(&heap, "dee") });
    var m2 = try champ.mapEmpty(&heap);
    m2 = try champ.mapAssoc(&heap, m2, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "ann2"), &dispatch.hashValue, &dispatch.equal);
    m2 = try champ.mapAssoc(&heap, m2, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    m2 = try champ.mapAssoc(&heap, m2, try K.k(tc, "user/friend"), many, &dispatch.hashValue, &dispatch.equal);
    var dee = try champ.mapEmpty(&heap);
    dee = try champ.mapAssoc(&heap, dee, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "dee"), &dispatch.hashValue, &dispatch.equal);
    dee = try champ.mapAssoc(&heap, dee, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "dee@x"), &dispatch.hashValue, &dispatch.equal);
    const r2 = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{ m2, dee }), .{});
    try testing.expectEqual(ann, r2.tempids[0].eid);
    const dee_e = r2.tempids[1].eid;
    const friends2 = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = friend });
    try testing.expectEqual(@as(usize, 3), friends2.len);
    try testing.expectEqual(bob, friends2[0].v.ref);
    try testing.expectEqual(cy, friends2[1].v.ref);
    try testing.expectEqual(dee_e, friends2[2].v.ref);

    // A two-element keyword vector under a card-many keyword attribute is
    // still a collection, whatever its first element names.
    var m3 = try champ.mapEmpty(&heap);
    m3 = try champ.mapAssoc(&heap, m3, try K.k(tc, "db/id"), try string_mod.fromBytes(&heap, "ann3"), &dispatch.hashValue, &dispatch.equal);
    m3 = try champ.mapAssoc(&heap, m3, try K.k(tc, "user/email"), try string_mod.fromBytes(&heap, "ann@x"), &dispatch.hashValue, &dispatch.equal);
    m3 = try champ.mapAssoc(&heap, m3, try K.k(tc, "user/tags"), try vector_mod.fromSlice(&heap, &.{ try K.k(tc, "user/email"), try K.k(tc, "tag/b") }), &dispatch.hashValue, &dispatch.equal);
    _ = try transact(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{m3}), .{});
    try testing.expectEqual(@as(usize, 2), (try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = ann, .a = tags })).len);
}

/// Install `:user/nick` (string, indexed) and `:user/spouse` (ref,
/// unique identity) beside `installSchema`'s attributes.
fn installIdentitySchema(tc: *TestConn, arena: Allocator) !void {
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/nick") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "nick" } }, .a = .{ .id = boot.index }, .v = .{ .val = .{ .boolean = true } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/spouse") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_ref } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "spouse" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{});
}

test "an indexed attribute becomes unique while a value moves between entities" {
    const tc = try TestConn.init("tx_unique_move");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    try installIdentitySchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const nick = try attrId(tc, "user/nick");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const b = r1.tempids[1].eid;

    // Without the retraction, two entities would hold "N": refused.
    try testing.expectError(error.Unique, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .eid = nick }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{}));
    // The value moves from a to b in the transaction that makes the
    // attribute unique: after it, exactly one entity holds "N".
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = nick }, .v = .{ .val = .{ .string = "N" } } } },
        .{ .add = .{ .e = .{ .eid = nick }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 4), r2.tx_data.len);
    const db = try tc.conn.db();
    try testing.expectEqual(schema_mod.Unique.identity, (try db.attr(nick)).?.unique);
    try testing.expectEqual(@as(?u64, b), try db.entid(arena, .{ .lookup = .{ .a = nick, .v = .{ .string = "N" } } }));
    try testing.expectEqual(@as(usize, 1), (try db.datoms(arena, .aevt, .{ .a = nick })).len);
}

test "identity claims whose value is a lookup ref or a tempid upsert" {
    const tc = try TestConn.init("tx_identity_ref");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    try installIdentitySchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const spouse = try attrId(tc, "user/spouse");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "h" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "h@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "h" } } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const h = r1.tempids[1].eid;

    // The claim's value is a lookup ref: x is a.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "h@x" } } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    try testing.expectEqual(a, r2.tempids[0].eid);
    try testing.expectEqual(@as(usize, 2), r2.tx_data.len);
    for (r2.tx_data) |d| try testing.expect(d.a != spouse);

    // The claim's value is a tempid that itself upserts: x is a, hh is h.
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "hh" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "x" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 3 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "hh" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "h@x" } } } },
    }, .{});
    try testing.expectEqual(a, r3.tempids[0].eid);
    try testing.expectEqual(h, r3.tempids[1].eid);
    try testing.expectEqual(@as(usize, 2), r3.tx_data.len);

    // Two tempids claiming one new entity as spouse are one entity.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "p" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "n" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .tempid = .{ .string = "n" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "q" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Q" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "n@x" } } } },
    }, .{});
    // Tempids are listed in order of first mention: p, n, q.
    try testing.expectEqual(r4.tempids[0].eid, r4.tempids[2].eid);
    try testing.expect(r4.tempids[1].eid != r4.tempids[0].eid);
    try testing.expect(r4.tempids[1].eid != a and r4.tempids[1].eid != h);
    try testing.expectEqual(@as(usize, 4), r4.tx_data.len);

    // A claim through a lookup ref on a new entity's identity, asserted
    // later in the same transaction: y and m are fresh, y's spouse is m.
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "y" } }, .a = .{ .id = spouse }, .v = .{ .entity = .{ .lookup = .{ .a = .{ .id = email }, .v = .{ .string = "m@x" } } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "y" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Y" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "m" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "m@x" } } } },
    }, .{});
    const y = r5.tempids[0].eid;
    const m = r5.tempids[1].eid;
    try testing.expect(y != m and y > h and m > h);
    try testing.expectEqual(@as(usize, 4), r5.tx_data.len);
    try testing.expectEqual(@as(?u64, y), try (try tc.conn.db()).entid(arena, .{ .lookup = .{ .a = spouse, .v = .{ .ref = m } } }));
}

test "a large transaction's arena stays well under a kilobyte per datom" {
    const tc = try TestConn.init("tx_arena_per_datom");
    defer tc.deinit();
    var setup = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup.deinit();
    try installSchema(tc, setup.allocator());
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const bio = try attrId(tc, "user/bio");
    const home = try attrId(tc, "user/home");

    // The ops live in their own arena; the transaction's arena holds
    // only what the transaction allocates.
    const entities = 20_000;
    const per_entity = 5;
    const ops = try setup.allocator().alloc(Op, entities * per_entity);
    for (0..entities) |i| {
        const id: TempidKey = .{ .fixnum = -@as(i64, @intCast(i + 1)) };
        const em = try std.fmt.allocPrint(setup.allocator(), "user{d}@example.com", .{i});
        const nm = try std.fmt.allocPrint(setup.allocator(), "User Number {d}", .{i});
        ops[i * per_entity + 0] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = email }, .v = .{ .val = .{ .string = em } } } };
        ops[i * per_entity + 1] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = name }, .v = .{ .val = .{ .string = nm } } } };
        ops[i * per_entity + 2] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = age }, .v = .{ .val = .{ .long = @intCast(i % 90) } } } };
        ops[i * per_entity + 3] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = bio }, .v = .{ .val = .{ .string = "A short biography that fits inline in the key." } } } };
        ops[i * per_entity + 4] = .{ .add = .{ .e = .{ .tempid = id }, .a = .{ .id = home }, .v = .{ .entity = .{ .tempid = .{ .fixnum = -@as(i64, @intCast((i % entities) + 1)) } } } } };
    }

    var tx_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer tx_arena.deinit();
    const r = try transactOps(tc.conn, tx_arena.allocator(), ops, .{});
    try testing.expectEqual(@as(usize, entities * per_entity + 1), r.tx_data.len);
    try testing.expect(tx_arena.queryCapacity() / r.tx_data.len < 1024);
}

test "history composed with since shows only the rows after since" {
    const tc = try TestConn.init("tx_history_since");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const db = try tc.conn.db();
    // History alone: the assertion, its retraction and the new value.
    try testing.expectEqual(@as(usize, 3), (try db.withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    // History since r1: the two rows of r2, whichever way it is composed.
    for ([_]DbValue{ db.sinceT(r1.t).withHistory(), db.withHistory().sinceT(r1.t) }) |view| {
        const rows = try view.datoms(arena, .eavt, .{ .e = a });
        try testing.expectEqual(@as(usize, 2), rows.len);
        for (rows) |d| try testing.expectEqual(r2.t, d.t);
        try testing.expect(!rows[0].added and rows[1].added);
    }
    // Since r2 there is nothing; since 0 there is everything.
    try testing.expectEqual(@as(usize, 0), (try db.sinceT(r2.t).withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    try testing.expectEqual(@as(usize, 3), (try db.sinceT(0).withHistory().datoms(arena, .eavt, .{ .e = a })).len);
    // As-of composes on top: history since r1 as of r1 is empty.
    try testing.expectEqual(@as(usize, 0), (try db.sinceT(r1.t).withHistory().asOf(r1.t).datoms(arena, .eavt, .{ .e = a })).len);
}

test "two card-one values in one transaction conflict even when the first is current" {
    const tc = try TestConn.init("tx_card_one_current");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const age = try attrId(tc, "user/age");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 31 } } } },
    }, .{}));
    // Re-asserting the current value twice writes nothing.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    try testing.expectEqual(@as(i64, 30), (try (try tc.conn.db()).entity(arena, a))[0].vals[0].long);
}

test "a bare retract and an add under one attribute commute; a re-asserted datom conflicts with its retraction" {
    const tc = try TestConn.init("tx_retract_order");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const age = try attrId(tc, "user/age");
    const tags = try attrId(tc, "user/tags");
    const red = try kw(tc, "tag/red");
    const blue = try kw(tc, "tag/blue");

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 30 } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = red } } },
    }, .{});
    const a = r1.tempids[0].eid;
    var red_id: u32 = 0;
    for (r1.tx_data) |d| if (d.a == tags) {
        red_id = d.v.keyword;
    };

    // The add stands whichever form comes first: the bare retract
    // expands against the committed value.
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 9 } } } },
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = age } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r2.tx_data.len);
    var ages = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = age });
    try testing.expectEqual(@as(usize, 1), ages.len);
    try testing.expectEqual(@as(i64, 9), ages[0].v.long);
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = age } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 10 } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r3.tx_data.len);
    ages = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = age });
    try testing.expectEqual(@as(usize, 1), ages.len);
    try testing.expectEqual(@as(i64, 10), ages[0].v.long);

    // Card-many: the committed tag goes, the asserted one stays.
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = blue } } },
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = tags } } },
    }, .{});
    var tag_rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = tags });
    try testing.expectEqual(@as(usize, 1), tag_rows.len);
    try testing.expect(tag_rows[0].v.keyword != red_id);
    _ = try transactOps(tc.conn, arena, &.{
        .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = tags } } },
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = red } } },
    }, .{});
    tag_rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a, .a = tags });
    try testing.expectEqual(@as(usize, 1), tag_rows.len);
    try testing.expectEqual(red_id, tag_rows[0].v.keyword);

    // Re-asserting a current datom and retracting it in one transaction
    // is the assertion-and-retraction conflict, in either order and
    // under every retraction form.
    const add_age: Op = .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 10 } } } };
    const bare: Op = .{ .retract_attr = .{ .e = .{ .eid = a }, .a = .{ .id = age } } };
    const exact: Op = .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = age }, .v = .{ .val = .{ .long = 10 } } } };
    const add_name: Op = .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } };
    const whole: Op = .{ .retract_entity = .{ .eid = a } };
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ add_age, bare }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ bare, add_age }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ add_age, exact }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ exact, add_age }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ add_name, whole }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{ whole, add_name }, .{}));

    // retractEntity and an add of a fresh value commute: the entity
    // keeps the added datom alone.
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bea" } } } },
        whole,
    }, .{});
    var rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Bea", rows[0].v.string);
    _ = try transactOps(tc.conn, arena, &.{
        whole,
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Cy" } } } },
    }, .{});
    rows = try (try tc.conn.db()).datoms(arena, .eavt, .{ .e = a });
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Cy", rows[0].v.string);
}

test "an explicit :db/txInstant on the transaction entity stands" {
    const tc = try TestConn.init("tx_explicit_instant");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    const later = store_mod.nowMillis() + 3_600_000;
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = later } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{ .now_ms = later + 777 });
    try testing.expectEqual(@as(usize, 2), r.tx_data.len);
    var instants: usize = 0;
    for (r.tx_data) |d| if (d.a == boot.tx_instant) {
        instants += 1;
        try testing.expectEqual(later, d.v.instant);
    };
    try testing.expectEqual(@as(usize, 1), instants);
    const db = try tc.conn.db();
    try testing.expectEqual(later, (try db.entity(arena, key.txEntity(r.t)))[0].vals[0].instant);
    const entries = try db_mod.txRange(tc.conn, arena, r.t, null);
    try testing.expectEqual(later, entries[0].instant);
    // Instants never go back: an explicit one earlier than the last is
    // refused, a clock behind it takes the last one.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = later - 1 } } } },
    }, .{}));
    const behind = try transactOps(tc.conn, arena, &.{}, .{ .now_ms = 5 });
    try testing.expectEqual(later, behind.tx_data[0].v.instant);
    // Only the transaction's own entity takes an instant, and nothing
    // retracts one.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = key.txEntity(r.t) }, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = later + 1 } } } },
    }, .{}));
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .retract_attr = .{ .e = .{ .eid = key.txEntity(r.t) }, .a = .{ .id = boot.tx_instant } } },
    }, .{}));
    // Two different instants for one transaction conflict.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = 1 } } } },
        .{ .add = .{ .e = .tx, .a = .{ .id = boot.tx_instant }, .v = .{ .val = .{ .instant = 2 } } } },
    }, .{}));
}

test "a tempid must be the entity of some datom; a retraction mints no keyword" {
    const tc = try TestConn.init("tx_tempid_value");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    const l = Lisp{ .tc = tc, .heap = &heap };
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const friend = try attrId(tc, "user/friend");
    const tags = try attrId(tc, "user/tags");
    var fault: Fault = .{};

    // A tempid only in a value position would be a dangling ref.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "ghost" } } } } },
    }, .{ .fault = &fault }));
    try testing.expect(fault.message != null);
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{try l.map(&.{.{ "db/id", try l.str("lonely") }})}), .{}));
    try testing.expectError(error.TxData, transact(tc.conn, arena, try l.vec(&.{try l.map(&.{})}), .{}));
    // As a value and as an entity, it is one new entity.
    const r = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "b" } } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "B" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r.tempids.len);

    // Retracting a keyword the store has never seen retracts nothing and
    // mints no ident id.
    const aid = blk: {
        const txn = try tc.conn.store.beginRead();
        defer txn.abort();
        break :blk try tc.conn.store.readNextAid(txn);
    };
    const a = r.tempids[0].eid;
    const gone = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "brand/new") } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), gone.tx_data.len);
    try testing.expectError(error.NoEntity, transact(tc.conn, arena, try l.vec(&.{try l.vec(&.{
        try l.kw("db/retract"), try l.vec(&.{ try l.kw("db/ident"), try l.kw("brand/newer") }), try l.kw("user/name"), try l.str("x"),
    })}), .{}));
    const txn = try tc.conn.store.beginRead();
    defer txn.abort();
    try testing.expectEqual(aid, try tc.conn.store.readNextAid(txn));
}

test "two identities naming two entities for one tempid conflict, naming the datom" {
    const tc = try TestConn.init("tx_identity_conflict");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    _ = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{});
    var fault: Fault = .{};
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "t" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "t" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "b@x" } } } },
    }, .{ .fault = &fault }));
    try testing.expect(fault.e != null);
    try testing.expectEqual(try kw(tc, "user/email"), fault.attr.?.asKeywordId());
}

test "another connection's data commits keep the schema cache; its schema changes rebuild it" {
    const tc = try TestConn.init("tx_schema_gen");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
    defer other.destroy();

    _ = try (try tc.conn.db()).attr(name);
    const cached = tc.conn.schema_cache.?;
    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "A" } } } },
    }, .{});
    const db = try tc.conn.db();
    try testing.expect((try db.attr(name)) != null);
    try testing.expectEqual(cached, tc.conn.schema_cache.?);
    try testing.expectEqual(db.basis, cached.basis);

    _ = try transactOps(other, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{});
    try testing.expect((try (try tc.conn.db()).attr(name)).?.many());
}

test "the view outlives the scratch arena until destroy" {
    const tc = try TestConn.init("tx_with_view_lifetime");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    const w = try withOps(tc.conn, scratch.allocator(), &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const escaped = w.db();
    const a = w.report.tempids[0].eid;
    try testing.expectEqual(@as(usize, 1), (try escaped.entity(arena, a)).len);
    w.finish();
    // The scratch arena, and the `With` in it, are gone; the view is
    // not: an escaped db-value answers Closed rather than reading freed
    // memory, and the connection is free again.
    scratch.deinit();
    try testing.expectError(error.Closed, escaped.entity(arena, a));
    try testing.expect(tc.conn.speculative == null);
    try testing.expectEqual(@as(usize, 0), (try (try tc.conn.db()).entity(arena, a)).len);
    escaped.conn.destroy();
}

test "a held with keeps the store open until finish; a closed connection refuses writes" {
    const tc = try TestConn.init("tx_busy_with");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");

    const w = try withOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    defer w.destroy();
    const a = w.report.tempids[0].eid;
    try testing.expectError(error.Busy, tc.conn.release());
    tc.conn.close();
    try testing.expect(!tc.conn.is_open and tc.conn.close_pending and !tc.conn.store_closed);
    // The view still reads the speculative state.
    try testing.expectEqual(@as(usize, 1), (try w.db().entity(arena, a)).len);
    w.finish();
    try testing.expect(tc.conn.store_closed);
    try testing.expectError(error.Closed, w.db().entity(arena, a));
    try testing.expectError(error.Closed, transactOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Closed, withOps(tc.conn, arena, &.{}, .{}));
}

test "an ident rename retires the old name; cardinality changes under the data's rule" {
    const tc = try TestConn.init("tx_alter");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const email = try attrId(tc, "user/email");
    const tags = try attrId(tc, "user/tags");
    var fault: Fault = .{};

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/x") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "tag/y") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const b = r1.tempids[1].eid;

    // Rename: no datom, the new keyword resolves, the old is retired.
    const k_full = try kw(tc, "user/full-name");
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.ident }, .v = .{ .keyword = k_full } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    const db2 = try tc.conn.db();
    try testing.expectEqual(@as(?u64, name), try db2.entid(arena, .{ .ident = k_full }));
    try testing.expect((try db2.entid(arena, .{ .ident = try kw(tc, "user/name") })) == null);
    try testing.expectEqual(@as(?u32, k_full), try db2.ident(arena, name));
    try testing.expectEqual(@as(?u32, k_full), try db2.asOf(r1.t).ident(arena, name));
    try testing.expectError(error.UnknownAttribute, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .ident = try kw(tc, "user/name") }, .v = .{ .val = .{ .string = "x" } } } },
    }, .{}));
    // The retired name is never minted again, as an attribute or a value.
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/name") } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = boot.type_string } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "n" } }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{}));
    try testing.expectError(error.TxData, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = tags }, .v = .{ .keyword = try kw(tc, "user/name") } } },
    }, .{}));
    // A keyword naming another entity conflicts; the entity's own ident is a no-op.
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try kw(tc, "user/email") } } },
    }, .{}));
    const r3 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.ident }, .v = .{ .keyword = k_full } } },
    }, .{});
    try testing.expectEqual(@as(usize, 1), r3.tx_data.len);
    // The txlog still decodes the entry written under the old name.
    const entries = try db_mod.txRange(tc.conn, arena, 2, 3);
    try testing.expectEqual(@as(usize, 1), entries.len);
    var saw_name = false;
    for (entries[0].datoms) |d| {
        if (d.a == boot.ident and d.v.keyword == name) saw_name = true;
    }
    try testing.expect(saw_name);
    // A second connection sees the rename through the generation.
    {
        const other = try Conn.open(testing.allocator, &tc.interner, tc.td.path.ptr, .{ .sync = .none });
        defer other.destroy();
        const odb = try other.db();
        try testing.expectEqual(@as(?u64, name), try odb.entid(arena, .{ .ident = k_full }));
        try testing.expect((try odb.entid(arena, .{ .ident = try kw(tc, "user/name") })) == null);
        try testing.expectEqual(@as(?u32, k_full), try odb.ident(arena, name));
    }

    // Cardinality one → many: the attribute takes a second value; an
    // earlier basis still reads it as card-one.
    const r4 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r4.tx_data.len);
    const r5 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Annie" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 2), r5.tx_data.len);
    const db5 = try tc.conn.db();
    try testing.expect((try db5.attr(name)).?.many());
    try testing.expect(!(try db5.asOf(r1.t).attr(name)).?.many());
    try testing.expectEqual(@as(usize, 2), (try db5.entity(arena, a))[0].vals.len);
    try testing.expectEqual(@as(usize, 1), (try db5.asOf(r1.t).entity(arena, a))[0].vals.len);

    // Many → one is refused while `a` holds two values, naming it.
    try testing.expectError(error.Schema, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(@as(?u64, a), fault.e);
    try testing.expectEqual(k_full, fault.attr.?.asKeywordId());
    // Retracting in the same transaction makes room; a second value asserted in it does not.
    try testing.expectError(error.Schema, transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .eid = b }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bobby" } } } },
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{ .fault = &fault }));
    try testing.expectEqual(@as(?u64, b), fault.e);
    const r6 = try transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{});
    const db6 = try tc.conn.db();
    try testing.expect(!(try db6.attr(name)).?.many());
    try testing.expect((try db6.asOf(r5.t).attr(name)).?.many());
    // The card-one rule applies from the next transaction on.
    const r7 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    try testing.expectEqual(@as(usize, 3), r7.tx_data.len);
    _ = r6;
    // A unique attribute stays card-one; a bare retraction of the cardinality is a conflict.
    try testing.expectError(error.Schema, transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = email }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_many } } } },
    }, .{}));
    try testing.expectError(error.Conflict, transactOps(tc.conn, arena, &.{
        .{ .retract = .{ .e = .{ .eid = name }, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = boot.card_one } } } },
    }, .{}));
}

test "excision removes an entity's datoms from every view and rewrites the txlog" {
    const tc = try TestConn.init("tx_excise");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try installSchema(tc, arena);
    const email = try attrId(tc, "user/email");
    const name = try attrId(tc, "user/name");
    const friend = try attrId(tc, "user/friend");
    var fault: Fault = .{};

    const r1 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = email }, .v = .{ .val = .{ .string = "a@x" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
        .{ .add = .{ .e = .{ .tempid = .{ .string = "b" } }, .a = .{ .id = friend }, .v = .{ .entity = .{ .tempid = .{ .string = "a" } } } } },
    }, .{});
    const a = r1.tempids[0].eid;
    const b = r1.tempids[1].eid;
    const r2 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .eid = a }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const before = try tc.conn.db();

    // One attribute: its rows go from every view, the rest stay.
    const x = try excise(tc.conn, arena, value.fromFixnum(@intCast(a)).?, value.fromFixnum(name).?, .{});
    try testing.expectEqual(r2.t + 1, x.report.t);
    try testing.expectEqual(a, x.excised);
    try testing.expectEqual(@as(u64, 3), x.removed);
    try testing.expectEqual(@as(usize, 1), x.report.tx_data.len);
    const db3 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 1), (try db3.entity(arena, a)).len);
    try testing.expectEqual(email, (try db3.entity(arena, a))[0].a);
    try testing.expectEqual(@as(usize, 1), (try before.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try db3.withHistory().datoms(arena, .eavt, .{ .e = a, .a = name })).len);
    try testing.expectEqual(@as(usize, 0), (try db3.datoms(arena, .aevt, .{ .a = name, .e = a })).len);
    try testing.expectEqual(@as(usize, 1), (try db3.datoms(arena, .aevt, .{ .a = name })).len);
    try testing.expectEqual(@as(u64, 1), (try db3.attr(name)).?.count);
    // The txlog: the entries that held the datoms lost them and carry
    // the marker; the excising entry carries it too.
    const log = try db_mod.txRange(tc.conn, arena, r1.t, null);
    try testing.expectEqual(@as(usize, 3), log.len);
    try testing.expectEqualSlices(u64, &.{a}, log[0].excised);
    try testing.expectEqual(@as(usize, 4), log[0].datoms.len);
    try testing.expectEqualSlices(u64, &.{a}, log[1].excised);
    try testing.expectEqual(@as(usize, 1), log[1].datoms.len);
    try testing.expectEqual(boot.tx_instant, log[1].datoms[0].a);
    try testing.expectEqualSlices(u64, &.{a}, log[2].excised);
    for (log) |entry| for (entry.datoms) |d| try testing.expect(!(d.e == a and d.a == name));

    // The whole entity: gone everywhere; the ref to it from `b` stays.
    const y = try excise(tc.conn, arena, value.fromFixnum(@intCast(a)).?, null, .{});
    try testing.expectEqual(@as(u64, 1), y.removed);
    const db4 = try tc.conn.db();
    try testing.expectEqual(@as(usize, 0), (try db4.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try before.entity(arena, a)).len);
    try testing.expect((try db4.entid(arena, .{ .lookup = .{ .a = email, .v = .{ .string = "a@x" } } })) == null);
    try testing.expectEqual(@as(usize, 2), (try db4.entity(arena, b)).len);
    try testing.expectEqual(a, (try db4.entity(arena, b))[1].vals[0].ref);
    try testing.expectEqual(@as(usize, 1), (try db4.datoms(arena, .vaet, .{ .v = try key.valBytes(arena, .{ .ref = a }) })).len);
    const log2 = try db_mod.txRange(tc.conn, arena, r1.t, r1.t + 1);
    try testing.expectEqual(@as(usize, 3), log2[0].datoms.len);
    for (log2[0].datoms) |d| try testing.expect(d.e == b or d.e == key.txEntity(r1.t));
    // An excised entity is still addressable: excising it again removes nothing.
    const z = try excise(tc.conn, arena, value.fromFixnum(@intCast(a)).?, null, .{});
    try testing.expectEqual(@as(u64, 0), z.removed);

    // Refusals: an attribute or transaction entity, a tempid, an
    // unallocated id, an unknown attribute; nothing is recorded.
    const basis = (try tc.conn.db()).basis;
    try testing.expectError(error.TxData, excise(tc.conn, arena, value.fromFixnum(name).?, null, .{ .fault = &fault }));
    try testing.expectError(error.TxData, excise(tc.conn, arena, value.fromFixnum(@intCast(key.txEntity(r1.t))).?, null, .{}));
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    try testing.expectError(error.TxData, excise(tc.conn, arena, try string_mod.fromBytes(&heap, "tmp"), null, .{}));
    try testing.expectError(error.NoEntity, excise(tc.conn, arena, value.fromFixnum(@intCast(key.user_partition_start + 99)).?, null, .{}));
    try testing.expectError(error.UnknownAttribute, excise(tc.conn, arena, value.fromFixnum(@intCast(b)).?, value.fromFixnum(9999).?, .{ .fault = &fault }));
    try testing.expectEqual(basis, (try tc.conn.db()).basis);
    // Inside a held `with`, excision is nested.
    const w = try withOps(tc.conn, arena, &.{}, .{});
    defer w.destroy();
    try testing.expectError(error.Nested, excise(tc.conn, arena, value.fromFixnum(@intCast(b)).?, null, .{}));
}

/// `[:db.fn/cas e a old new]` as a VM value; `old` may be nil.
fn casForm(heap: *@import("../heap.zig").Heap, tc: *TestConn, e: Value, attr: []const u8, old: Value, new: Value) !Value {
    const it = &tc.interner;
    const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/cas"), e, try it.internKeywordValue(attr), old, new });
    return vector_mod.fromSlice(heap, &.{form});
}

test "cas asserts against the committed value and reports what it found" {
    const tc = try TestConn.init("tx_cas");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const age = try attrId(tc, "user/age");
    const name = try attrId(tc, "user/name");
    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r0.tempids[0].eid;
    const eid = value.fromFixnum(@intCast(a)).?;
    const nil = value.nilValue();
    const n = struct {
        fn n(x: i64) Value {
            return value.fromFixnum(x).?;
        }
    }.n;
    var fault: Fault = .{};

    // An absent attribute: nil expected succeeds, a value expected fails.
    const r1 = try transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", nil, n(1)), .{});
    try testing.expectEqual(@as(usize, 2), r1.tx_data.len);
    try testing.expectEqual(@as(i64, 1), r1.tx_data[0].v.long);
    try testing.expectError(error.Cas, transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", nil, n(2)), .{ .fault = &fault }));
    try testing.expect(fault.cas.?.expected == null);
    try testing.expectEqual(@as(i64, 1), fault.cas.?.actual.?.long);
    try testing.expectEqual(try kw(tc, "user/age"), fault.attr.?.asKeywordId());

    // The right expectation swaps; the wrong one names both values.
    const r2 = try transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", n(1), n(2)), .{});
    try testing.expectEqual(@as(usize, 3), r2.tx_data.len);
    try testing.expect(!r2.tx_data[0].added and r2.tx_data[1].added);
    try testing.expectError(error.Cas, transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/age", n(1), n(3)), .{ .fault = &fault }));
    try testing.expectEqual(@as(i64, 1), fault.cas.?.expected.?.long);
    try testing.expectEqual(@as(i64, 2), fault.cas.?.actual.?.long);

    // A retraction earlier in the transaction counts; card-many is refused.
    const retract = try vector_mod.fromSlice(&heap, &.{ try tc.interner.internKeywordValue("db/retract"), eid, try tc.interner.internKeywordValue("user/age"), n(2) });
    const both = try vector_mod.fromSlice(&heap, &.{ retract, vector_mod.nth(try casForm(&heap, tc, eid, "user/age", nil, n(9)), 0) });
    const r3 = try transact(tc.conn, arena, both, .{});
    try testing.expectEqual(@as(usize, 3), r3.tx_data.len);
    try testing.expectError(error.TxData, transact(tc.conn, arena, try casForm(&heap, tc, eid, "user/tags", nil, try tc.interner.internKeywordValue("tag/x")), .{}));
    const ent = try (try tc.conn.db()).entity(arena, a);
    try testing.expectEqual(age, ent[1].a);
    try testing.expectEqual(@as(i64, 9), ent[1].vals[0].long);
}

/// A transaction-function hook for the tests: `f` is a symbol naming
/// a behaviour, and the hook builds the tx-data the behaviour returns.
const TestTxHook = struct {
    tc: *TestConn,
    heap: *@import("../heap.zig").Heap,
    calls: usize = 0,
    /// The basis the last call saw.
    basis: u64 = 0,

    fn hook(self: *TestTxHook) CallHook {
        return .{ .ctx = @ptrCast(self), .call = &call };
    }

    fn call(ctx: *anyopaque, f: Value, db_before: DbValue, args: []const Value) anyerror!Value {
        const self: *TestTxHook = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.basis = db_before.basis;
        const heap = self.heap;
        const it = &self.tc.interner;
        const name = it.symbolName(f.asSymbolId());
        // Age of `args[0]` becomes `args[1]`.
        if (std.mem.eql(u8, name, "age!")) {
            const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db/add"), args[0], try it.internKeywordValue("user/age"), args[1] });
            return vector_mod.fromSlice(heap, &.{form});
        }
        // Calls `age!` through a nested call form.
        if (std.mem.eql(u8, name, "via")) {
            const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/call"), try it.internSymbolValue("age!"), args[0], args[1] });
            return vector_mod.fromSlice(heap, &.{form});
        }
        // Calls itself forever.
        if (std.mem.eql(u8, name, "forever")) {
            const form = try vector_mod.fromSlice(heap, &.{ try it.internKeywordValue("db.fn/call"), f });
            return vector_mod.fromSlice(heap, &.{form});
        }
        // Nothing.
        if (std.mem.eql(u8, name, "nothing")) return value.nilValue();
        // Not tx-data.
        if (std.mem.eql(u8, name, "text")) return string_mod.fromBytes(heap, "nope");
        return error.UnknownBehaviour;
    }
};

test "transaction functions splice their tx-data in place, nest to a bound, and see db-before" {
    const tc = try TestConn.init("tx_fn");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = @import("../heap.zig").Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const age = try attrId(tc, "user/age");
    const name = try attrId(tc, "user/name");
    const r0 = try transactOps(tc.conn, arena, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "a" } }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
    }, .{});
    const a = r0.tempids[0].eid;
    var th = TestTxHook{ .tc = tc, .heap = &heap };
    const it = &tc.interner;
    const call_kw = try it.internKeywordValue("db.fn/call");
    const eid = value.fromFixnum(@intCast(a)).?;
    var fault: Fault = .{};

    // Without a hook the form cannot run; nothing is written.
    const direct = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("age!"), eid, value.fromFixnum(30).? })});
    try testing.expectError(error.TxFn, transact(tc.conn, arena, direct, .{ .fault = &fault }));
    try testing.expect(fault.message != null);
    try testing.expectEqual(r0.t, (try tc.conn.db()).basis);

    // The call's datoms land in place, between the surrounding forms.
    const add_kw = try it.internKeywordValue("db/add");
    const name_kw = try it.internKeywordValue("user/name");
    const before = try vector_mod.fromSlice(&heap, &.{ add_kw, eid, name_kw, try string_mod.fromBytes(&heap, "Anne") });
    const tx = try vector_mod.fromSlice(&heap, &.{ before, try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("via"), eid, value.fromFixnum(30).? }) });
    const r1 = try transact(tc.conn, arena, tx, .{ .hook = th.hook() });
    try testing.expectEqual(@as(usize, 2), th.calls);
    try testing.expectEqual(r0.t, th.basis);
    // Anne retract+add, age add, txInstant.
    try testing.expectEqual(@as(usize, 4), r1.tx_data.len);
    try testing.expectEqual(name, r1.tx_data[0].a);
    try testing.expectEqual(age, r1.tx_data[2].a);
    try testing.expectEqual(@as(i64, 30), r1.tx_data[2].v.long);

    // Unbounded nesting stops at the depth limit with nothing written.
    const forever = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("forever") })});
    try testing.expectError(error.TxFn, transact(tc.conn, arena, forever, .{ .hook = th.hook(), .fault = &fault }));
    try testing.expectEqual(r1.t, (try tc.conn.db()).basis);

    // A nil result is no tx-data; a non-tx-data result is malformed.
    const nothing = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("nothing") })});
    const r2 = try transact(tc.conn, arena, nothing, .{ .hook = th.hook() });
    try testing.expectEqual(@as(usize, 1), r2.tx_data.len);
    const bad = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try it.internSymbolValue("text") })});
    try testing.expectError(error.TxData, transact(tc.conn, arena, bad, .{ .hook = th.hook() }));
    // Only a function or a symbol may sit in function position.
    const not_fn = try vector_mod.fromSlice(&heap, &.{try vector_mod.fromSlice(&heap, &.{ call_kw, try string_mod.fromBytes(&heap, "f") })});
    try testing.expectError(error.TxData, transact(tc.conn, arena, not_fn, .{ .hook = th.hook() }));

    // A second write on the connection inside a call is nested.
    const Inner = struct {
        fn call(ctx: *anyopaque, _: Value, db_before: DbValue, _: []const Value) anyerror!Value {
            const c: *TestConn = @ptrCast(@alignCast(ctx));
            var inner_arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer inner_arena.deinit();
            try testing.expectError(error.Nested, transactOps(c.conn, inner_arena.allocator(), &.{}, .{}));
            try testing.expectError(error.Nested, withOps(c.conn, inner_arena.allocator(), &.{}, .{}));
            // Reads of db-before work while the write is held.
            try testing.expect((try db_before.datoms(inner_arena.allocator(), .eavt, .{ .e = boot.ident })).len > 0);
            return value.nilValue();
        }
    };
    const inner_hook: CallHook = .{ .ctx = @ptrCast(tc), .call = &Inner.call };
    _ = try transact(tc.conn, arena, nothing, .{ .hook = inner_hook });
}
