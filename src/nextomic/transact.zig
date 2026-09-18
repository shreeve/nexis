//! transact.zig — the transaction protocol (NEXTOMIC.md §3).
//!
//! One `transact` is one emdb write transaction; emdb's write lock is
//! the transactor. The pipeline:
//!
//!   1. begin the write transaction, `t = sys["t"] + 1`;
//!   2. normalise tx-data to ops (vector forms, map forms with nested
//!      entities and card-many collections), resolving attributes through
//!      the schema at `now` and converting values by the attribute's type;
//!   3. bind tempids: `:db/ident` binds to the ident's id (minting it),
//!      unique-identity assertions upsert through an AVET probe, two
//!      tempids naming one identity unify, the rest take fresh eids;
//!   4. expand ops in order against the committed trees plus the
//!      transaction's own overlay: card-one implicit retracts, no-op
//!      re-assertions, conflicts, unique-value collisions, lookup refs,
//!      retract-attribute, retract-entity with VAET cleanup and component
//!      cascade, then the `:db/txInstant` datom;
//!   5. validate schema changes and backfill AVET for attributes that
//!      become indexed or unique;
//!   6. write the eight index trees, the txlog, the counts and `sys`;
//!   7. commit, then publish minted idents to the cache.
//!
//! Any error aborts the write transaction; nothing partial can exist.
//! Everything the transaction allocates lives in the caller's arena.
//!
//! A speculative `with` runs steps 1-6 and stops: the write transaction
//! stays open, a view connection reads it through read-only children,
//! and `finish` aborts it. Only one write transaction exists per store,
//! so `transact` and `with` are `error.Nested` while one is held.

const std = @import("std");
const value = @import("value");
const intern_mod = @import("intern");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const emdb = @import("emdb");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const idents_mod = @import("idents.zig");
const schema_mod = @import("schema.zig");
const db_mod = @import("db.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Txn = emdb.Txn;
const Store = store_mod.Store;
const Minter = idents_mod.Minter;
const Schema = schema_mod.Schema;
const Attr = schema_mod.Attr;
const Conn = db_mod.Conn;
const DbValue = db_mod.DbValue;
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
};

pub const Options = struct {
    /// Overrides the connection's sync mode for this commit.
    sync: ?SyncMode = null,
    /// Wall-clock milliseconds for `:db/txInstant`; the clock when null.
    now_ms: ?i64 = null,
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
    for (ops) |op| try ctx.normaliseOp(op);
    return ctx.run();
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
/// Allocated in the caller's arena, which must outlive every use of
/// the view.
pub const With = struct {
    ctx: Ctx,
    /// The view: the connection's store and interner, its own ident and
    /// schema caches, reads through `ctx.txn`.
    view: Conn,
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
        self.view.dropSchema();
        self.view.idents.deinit();
        self.view.is_open = false;
        self.view.overlay = null;
        self.ctx.conn.speculative = null;
        self.ctx.abort();
    }

    /// The protocol after normalisation: apply, then open the view over
    /// the held transaction.
    fn speculate(self: *With) !void {
        const conn = self.ctx.conn;
        try self.ctx.apply();
        self.view = .{
            .gpa = conn.gpa,
            .store = conn.store,
            .interner = conn.interner,
            .idents = try conn.idents.clone(),
            .sync_mode = self.ctx.sync_mode,
            .is_open = true,
            .overlay = self.ctx.txn,
        };
        errdefer self.view.idents.deinit();
        self.report = .{
            .db_before = .{ .conn = conn, .basis = self.ctx.now },
            .db_after = .{ .conn = &self.view, .basis = self.ctx.t },
            .t = self.ctx.t,
            .tempids = try self.ctx.userTempids(),
            .tx_data = try self.ctx.txData(),
        };
        self.finished = false;
        conn.speculative = &self.view;
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
    for (ops) |op| try self.ctx.normaliseOp(op);
    try self.speculate();
    return self;
}

// =============================================================================
// Internal representation
// =============================================================================

const Lookup = struct { attr: Attr, v: Val };

const Ent = union(enum) {
    eid: u64,
    /// Index into `Ctx.bindings`.
    tempid: u32,
    lookup: Lookup,
};

const PVal = union(enum) {
    val: Val,
    tempid: u32,
    lookup: Lookup,
};

const ROp = union(enum) {
    add: struct { e: Ent, attr: Attr, v: PVal },
    retract: struct { e: Ent, attr: Attr, v: PVal },
    retract_attr: struct { e: Ent, attr: Attr },
    retract_entity: Ent,
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
    attr: Attr,
    v: Val,
    vbytes: []const u8,
    added: bool,
};

const EA = struct { e: u64, a: u32 };

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
    finished: bool = false,

    bindings: std.ArrayList(Binding) = .empty,
    str_tempids: std.StringHashMapUnmanaged(u32) = .empty,
    num_tempids: std.AutoHashMapUnmanaged(i64, u32) = .empty,
    ops: std.ArrayList(ROp) = .empty,

    overlay: std.ArrayList(Pending) = .empty,
    /// EAVT key of a pending datom -> overlay index.
    facts: std.StringHashMapUnmanaged(u32) = .empty,
    /// (e a) -> overlay index of the pending card-one assertion.
    one_adds: std.AutoHashMapUnmanaged(EA, u32) = .empty,
    /// (e a) -> number of pending assertions.
    ea_adds: std.AutoHashMapUnmanaged(EA, u32) = .empty,
    /// `[a][v]` of a pending assertion -> e.
    av_adds: std.StringHashMapUnmanaged(u64) = .empty,

    next_eid: u64,
    eid_bumped: bool = false,
    /// Any datom on an attribute-partition entity.
    schema_touched: bool = false,
    /// Per-attribute change in current-datom count.
    deltas: std.AutoHashMapUnmanaged(u32, i64) = .empty,

    fn begin(conn: *Conn, arena: Allocator, options: Options) !Ctx {
        if (!conn.is_open) return error.Closed;
        if (conn.speculative != null or conn.overlay != null) return error.Nested;
        const sync_mode = options.sync orelse conn.sync_mode;
        const txn = try conn.store.beginWrite(sync_mode);
        errdefer txn.abort();
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
            .next_eid = try conn.store.readNextEid(txn),
        };
    }

    fn abort(self: *Ctx) void {
        if (self.finished) return;
        self.finished = true;
        self.txn.abort();
    }

    // ── attributes ────────────────────────────────────────────────

    fn attrById(self: *Ctx, id: u32) !Attr {
        const a = self.schema.attr(id) orelse return error.UnknownAttribute;
        return a.*;
    }

    fn attrByIntern(self: *Ctx, intern_id: u32) !Attr {
        const id = (try self.minter.lookup(intern_id)) orelse return error.UnknownAttribute;
        return self.attrById(id);
    }

    fn attrOf(self: *Ctx, ref: AttrRef) !Attr {
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

    fn bind(self: *Ctx, i: u32, eid: u64) !void {
        const r = self.root(i);
        const b = &self.bindings.items[r];
        if (b.eid) |cur| {
            if (cur != eid) return error.Conflict;
            return;
        }
        b.eid = eid;
    }

    fn unify(self: *Ctx, i: u32, j: u32) !void {
        const ri = self.root(i);
        const rj = self.root(j);
        if (ri == rj) return;
        const bi = &self.bindings.items[ri];
        const bj = &self.bindings.items[rj];
        if (bi.eid != null and bj.eid != null and bi.eid.? != bj.eid.?) return error.Conflict;
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
            .lookup => |l| .{ .lookup = .{ .attr = try self.lookupAttr(try self.attrOf(l.a), l.v), .v = l.v } },
            .ident => |k| .{ .eid = (try self.minter.lookup(k)) orelse return error.NoEntity },
            .tx => .{ .eid = key.txEntity(self.t) },
        };
    }

    fn lookupAttr(self: *Ctx, attr: Attr, v: Val) !Attr {
        _ = self;
        if (attr.unique == .none) return error.TxData;
        if (v.valueType() != attr.value_type) return error.ValueType;
        return attr;
    }

    fn valueOf(self: *Ctx, attr: Attr, v: ValRef) !PVal {
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
                return .{ .val = .{ .keyword = try self.minter.resolve(k) } };
            },
            .vm => |x| return self.valueFromVm(attr, x),
        }
    }

    fn normaliseOp(self: *Ctx, op: Op) !void {
        switch (op) {
            .add => |o| {
                const attr = try self.attrOf(o.a);
                try self.ops.append(self.arena, .{ .add = .{ .e = try self.entityOf(o.e), .attr = attr, .v = try self.valueOf(attr, o.v) } });
            },
            .retract => |o| {
                const attr = try self.attrOf(o.a);
                try self.ops.append(self.arena, .{ .retract = .{ .e = try self.entityOf(o.e), .attr = attr, .v = try self.valueOf(attr, o.v) } });
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

    fn normaliseValue(self: *Ctx, tx_data: Value) !void {
        switch (tx_data.kind()) {
            .persistent_vector => {
                var it = vector_mod.Cursor.init(tx_data);
                while (it.next()) |form| try self.normaliseForm(form);
            },
            .list => {
                var it = list_mod.Cursor.init(tx_data);
                while (it.next()) |form| try self.normaliseForm(form);
            },
            else => return error.TxData,
        }
    }

    fn normaliseForm(self: *Ctx, form: Value) !void {
        switch (form.kind()) {
            .persistent_vector => {
                const n = vector_mod.count(form);
                if (n < 2) return error.TxData;
                const op = vector_mod.nth(form, 0);
                if (self.kwIs(op, "db/add")) {
                    if (n != 4) return error.TxData;
                    const attr = try self.attrFromVm(vector_mod.nth(form, 2));
                    const e = try self.entityFromVm(vector_mod.nth(form, 1));
                    try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, vector_mod.nth(form, 3)) } });
                } else if (self.kwIs(op, "db/retract")) {
                    if (n != 3 and n != 4) return error.TxData;
                    const attr = try self.attrFromVm(vector_mod.nth(form, 2));
                    const e = try self.entityFromVm(vector_mod.nth(form, 1));
                    if (n == 3) {
                        try self.ops.append(self.arena, .{ .retract_attr = .{ .e = e, .attr = attr } });
                    } else {
                        try self.ops.append(self.arena, .{ .retract = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, vector_mod.nth(form, 3)) } });
                    }
                } else if (self.kwIs(op, "db/retractEntity")) {
                    if (n != 2) return error.TxData;
                    try self.ops.append(self.arena, .{ .retract_entity = try self.entityFromVm(vector_mod.nth(form, 1)) });
                } else return error.TxData;
            },
            .persistent_map => _ = try self.normaliseMap(form, null),
            else => return error.TxData,
        }
    }

    /// Expand a map form into adds; returns the entity. `parent` is the
    /// attribute under which a nested map appeared.
    fn normaliseMap(self: *Ctx, m: Value, parent: ?Attr) anyerror!Ent {
        _ = parent;
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
            const attr = try self.attrFromVm(entry.key);
            const v = entry.value;
            if (attr.many() and isCollection(v)) {
                var elems = try collectionElements(self.arena, v);
                for (elems[0..]) |el| try self.addFromVm(e, attr, el);
                elems = &.{};
            } else {
                try self.addFromVm(e, attr, v);
            }
        }
        return e;
    }

    fn addFromVm(self: *Ctx, e: Ent, attr: Attr, v: Value) anyerror!void {
        if (v.kind() == .persistent_map and attr.value_type == .ref) {
            const nested = try self.normaliseMap(v, attr);
            const pv: PVal = switch (nested) {
                .eid => |id| .{ .val = .{ .ref = id } },
                .tempid => |i| .{ .tempid = i },
                .lookup => |l| .{ .lookup = l },
            };
            try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = pv } });
            return;
        }
        try self.ops.append(self.arena, .{ .add = .{ .e = e, .attr = attr, .v = try self.valueFromVm(attr, v) } });
    }

    fn attrFromVm(self: *Ctx, v: Value) !Attr {
        return switch (v.kind()) {
            .keyword => self.attrByIntern(v.asKeywordId()),
            .fixnum => blk: {
                const n = v.asFixnum();
                if (n <= 0 or n > std.math.maxInt(u32)) return error.UnknownAttribute;
                break :blk self.attrById(@intCast(n));
            },
            else => error.TxData,
        };
    }

    fn entityFromVm(self: *Ctx, v: Value) anyerror!Ent {
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
                if (vector_mod.count(v) != 2) return error.TxData;
                const attr = try self.attrFromVm(vector_mod.nth(v, 0));
                if (attr.unique == .none) return error.TxData;
                const lv = try self.valueFromVm(attr, vector_mod.nth(v, 1));
                if (lv != .val) return error.TxData;
                return .{ .lookup = .{ .attr = attr, .v = lv.val } };
            },
            else => return error.TxData,
        }
    }

    /// Convert a VM value by the attribute's type.
    fn valueFromVm(self: *Ctx, attr: Attr, v: Value) anyerror!PVal {
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
                return .{ .val = .{ .keyword = try self.minter.resolve(v.asKeywordId()) } };
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

    /// Steps 3-6: everything up to the commit, leaving the write
    /// transaction open with the datoms, txlog and counters written.
    fn apply(self: *Ctx) !void {
        try self.bindTempids();
        try self.expandAll();
        try self.txInstant();
        try self.applySchema();
        try self.write();
    }

    /// Step 7: commit, then publish the mints and update the schema
    /// cache, and report.
    fn commit(self: *Ctx) !Report {
        const db_before: DbValue = .{ .conn = self.conn, .basis = self.now };
        try self.txn.commit();
        self.finished = true;
        try self.minter.commitCache();
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
            .tempids = try self.userTempids(),
            .tx_data = try self.txData(),
        };
    }

    // ── step 3: tempids ───────────────────────────────────────────

    fn bindTempids(self: *Ctx) !void {
        // `:db/ident` names the entity: its id is the ident's id.
        for (self.ops.items) |op| {
            if (op != .add or op.add.e != .tempid or op.add.attr.id != boot.ident) continue;
            if (op.add.v != .val) return error.ValueType;
            try self.bind(op.add.e.tempid, op.add.v.val.keyword);
        }
        // Unique-identity assertions upsert; equal identities unify.
        var claims: std.StringHashMapUnmanaged(u32) = .empty;
        for (self.ops.items) |op| {
            if (op != .add or op.add.e != .tempid) continue;
            const attr = op.add.attr;
            if (attr.unique != .identity or attr.id == boot.ident or op.add.v != .val) continue;
            const vb = try key.valBytes(self.arena, op.add.v.val);
            const av = try self.avKey(attr.id, vb);
            const g = try claims.getOrPut(self.arena, av);
            if (g.found_existing) {
                try self.unify(op.add.e.tempid, g.value_ptr.*);
            } else {
                g.value_ptr.* = op.add.e.tempid;
            }
            if (try self.probeAvet(attr.id, vb)) |eid| try self.bind(op.add.e.tempid, eid);
        }
        // Fresh eids for the rest.
        for (self.bindings.items, 0..) |*b, i| {
            if (b.alias != null) continue;
            if (b.eid != null) continue;
            _ = i;
            if (self.next_eid >= key.user_partition_end) return error.DatabaseFull;
            b.eid = self.next_eid;
            self.next_eid += 1;
            self.eid_bumped = true;
        }
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
        var s = try self.conn.store.scan(self.txn, self.conn.store.trees.cur(.avet), prefix);
        while (s.next()) |kv| {
            const parts = try key.unpackKey(.avet, false, kv.key);
            if (std.mem.eql(u8, parts.v, vbytes)) return parts.e;
        }
        return null;
    }

    /// The entity holding `(a v)` in the tree or the overlay, or null.
    fn findByAv(self: *Ctx, a: u32, vbytes: []const u8) !?u64 {
        const av = try self.avKey(a, vbytes);
        if (self.av_adds.get(av)) |e| return e;
        const e = (try self.probeAvet(a, vbytes)) orelse return null;
        // A pending retraction of that datom hides it.
        const fk = try key.keyBytes(self.arena, .eavt, e, a, vbytes, null);
        if (self.facts.get(fk)) |i| if (!self.overlay.items[i].added) return null;
        return e;
    }

    fn resolveEnt(self: *Ctx, e: Ent) !u64 {
        return switch (e) {
            .eid => |id| id,
            .tempid => |i| self.eidOfTempid(i),
            .lookup => |l| blk: {
                const vb = try key.valBytes(self.arena, l.v);
                break :blk (try self.findByAv(l.attr.id, vb)) orelse return error.NoEntity;
            },
        };
    }

    fn resolveVal(self: *Ctx, v: PVal) !Val {
        return switch (v) {
            .val => |x| x,
            .tempid => |i| .{ .ref = self.eidOfTempid(i) },
            .lookup => |l| blk: {
                const vb = try key.valBytes(self.arena, l.v);
                break :blk .{ .ref = (try self.findByAv(l.attr.id, vb)) orelse return error.NoEntity };
            },
        };
    }

    // ── step 4: expand ────────────────────────────────────────────

    fn expandAll(self: *Ctx) !void {
        for (self.ops.items) |op| {
            switch (op) {
                .add => |o| try self.expandAdd(try self.resolveEnt(o.e), o.attr, try self.resolveVal(o.v)),
                .retract => |o| try self.expandRetract(try self.resolveEnt(o.e), o.attr, try self.resolveVal(o.v)),
                .retract_attr => |o| try self.expandRetractAttr(try self.resolveEnt(o.e), o.attr),
                .retract_entity => |e| {
                    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
                    try self.expandRetractEntity(try self.resolveEnt(e), &seen);
                },
            }
        }
    }

    fn checkAttrValue(self: *Ctx, e: u64, attr: Attr, v: Val) !void {
        _ = self;
        if (attr.value_type == .ref and !key.isAttrPartition(v.ref) and v.ref < key.user_partition_start) return error.NoEntity;
        switch (attr.id) {
            boot.value_type => if (boot.valueTypeOf(v.keyword) == null) return error.ValueType,
            boot.cardinality => if (v.keyword != boot.card_one and v.keyword != boot.card_many) return error.ValueType,
            boot.unique => if (v.keyword != boot.unique_identity and v.keyword != boot.unique_value) return error.ValueType,
            boot.ident => if (e != v.keyword) return error.Conflict,
            else => {},
        }
    }

    fn expandAdd(self: *Ctx, e: u64, attr: Attr, v: Val) !void {
        try self.checkAttrValue(e, attr, v);
        const vb = try key.valBytes(self.arena, v);
        const fk = try key.keyBytes(self.arena, .eavt, e, attr.id, vb, null);
        if (self.facts.get(fk)) |i| {
            if (!self.overlay.items[i].added) return error.Conflict;
            return;
        }
        if (attr.unique != .none) {
            if (try self.findByAv(attr.id, vb)) |other| if (other != e) return error.Unique;
        }
        const already = (try self.txn.getFromTree(self.conn.store.trees.cur(.eavt), fk)) != null;
        if (!attr.many()) {
            const ea: EA = .{ .e = e, .a = attr.id };
            if (self.one_adds.get(ea)) |_| return error.Conflict;
            if (already) return;
            if (try self.currentOne(e, attr.id)) |old| {
                try self.pushRetract(e, attr, old.val, old.vbytes);
            }
            try self.push(e, attr, v, vb, true);
            try self.one_adds.put(self.arena, ea, @intCast(self.overlay.items.len - 1));
            return;
        }
        if (already) return;
        try self.push(e, attr, v, vb, true);
    }

    const Current = struct { val: Val, vbytes: []const u8 };

    /// The committed value of a card-one `(e a)` that is not already
    /// retracted in this transaction.
    fn currentOne(self: *Ctx, e: u64, a: u32) !?Current {
        const prefix = try key.prefixBytes(self.arena, .eavt, .{ .e = e, .a = a });
        var s = try self.conn.store.scan(self.txn, self.conn.store.trees.cur(.eavt), prefix);
        while (s.next()) |kv| {
            if (self.facts.get(kv.key)) |i| if (!self.overlay.items[i].added) continue;
            const parts = try key.unpackKey(.eavt, false, kv.key);
            return .{ .val = try self.valFromParts(parts), .vbytes = try self.arena.dupe(u8, parts.v) };
        }
        return null;
    }

    /// The value of a current EAVT row. A cursor's value is clamped to
    /// one page, so an out-of-line payload is read again by exact key.
    fn valFromParts(self: *Ctx, parts: key.Parts) !Val {
        const kv = try key.decodeVal(self.arena, parts.v);
        if (kv == .val) return kv.val;
        const raw = (try self.conn.store.getCurrent(self.txn, .eavt, parts.e, parts.a, parts.v, self.arena)) orelse return error.Corrupted;
        if (raw.len < key.id_len) return error.Corrupted;
        const payload = try self.arena.dupe(u8, raw[key.id_len..]);
        return switch (kv) {
            .string_long => .{ .string = payload },
            .bytes_long => .{ .bytes = payload },
            .val => unreachable,
        };
    }

    fn expandRetract(self: *Ctx, e: u64, attr: Attr, v: Val) !void {
        const vb = try key.valBytes(self.arena, v);
        const fk = try key.keyBytes(self.arena, .eavt, e, attr.id, vb, null);
        if (self.facts.get(fk)) |i| {
            if (self.overlay.items[i].added) return error.Conflict;
            return;
        }
        if ((try self.txn.getFromTree(self.conn.store.trees.cur(.eavt), fk)) == null) return;
        try self.pushRetract(e, attr, v, vb);
    }

    fn expandRetractAttr(self: *Ctx, e: u64, attr: Attr) !void {
        if (self.ea_adds.get(.{ .e = e, .a = attr.id })) |_| return error.Conflict;
        const prefix = try key.prefixBytes(self.arena, .eavt, .{ .e = e, .a = attr.id });
        var s = try self.conn.store.scan(self.txn, self.conn.store.trees.cur(.eavt), prefix);
        while (s.next()) |kv| {
            if (self.facts.get(kv.key)) |_| continue;
            const parts = try key.unpackKey(.eavt, false, kv.key);
            try self.pushRetract(e, attr, try self.valFromParts(parts), try self.arena.dupe(u8, parts.v));
        }
    }

    fn expandRetractEntity(self: *Ctx, e: u64, seen: *std.AutoHashMapUnmanaged(u64, void)) anyerror!void {
        if ((try seen.getOrPut(self.arena, e)).found_existing) return;
        var components: std.ArrayList(u64) = .empty;
        // Its own datoms.
        {
            const prefix = try key.prefixBytes(self.arena, .eavt, .{ .e = e });
            var s = try self.conn.store.scan(self.txn, self.conn.store.trees.cur(.eavt), prefix);
            while (s.next()) |kv| {
                const parts = try key.unpackKey(.eavt, false, kv.key);
                const attr = try self.attrById(parts.a);
                const v = try self.valFromParts(parts);
                if (attr.component and v == .ref) try components.append(self.arena, v.ref);
                if (self.facts.get(kv.key)) |i| {
                    if (self.overlay.items[i].added) return error.Conflict;
                    continue;
                }
                try self.pushRetract(e, attr, v, try self.arena.dupe(u8, parts.v));
            }
        }
        // Datoms pointing at it.
        {
            const vb = try key.valBytes(self.arena, .{ .ref = e });
            const prefix = try key.prefixBytes(self.arena, .vaet, .{ .v = vb });
            var s = try self.conn.store.scan(self.txn, self.conn.store.trees.cur(.vaet), prefix);
            while (s.next()) |kv| {
                const parts = try key.unpackKey(.vaet, false, kv.key);
                const attr = try self.attrById(parts.a);
                const fk = try key.keyBytes(self.arena, .eavt, parts.e, parts.a, vb, null);
                if (self.facts.get(fk)) |i| {
                    if (self.overlay.items[i].added) return error.Conflict;
                    continue;
                }
                try self.pushRetract(parts.e, attr, .{ .ref = e }, vb);
            }
        }
        for (components.items) |c| try self.expandRetractEntity(c, seen);
    }

    fn push(self: *Ctx, e: u64, attr: Attr, v: Val, vbytes: []const u8, added: bool) !void {
        const fk = try key.keyBytes(self.arena, .eavt, e, attr.id, vbytes, null);
        const i: u32 = @intCast(self.overlay.items.len);
        try self.overlay.append(self.arena, .{ .e = e, .attr = attr, .v = v, .vbytes = vbytes, .added = added });
        try self.facts.put(self.arena, fk, i);
        if (added) {
            const g = try self.ea_adds.getOrPut(self.arena, .{ .e = e, .a = attr.id });
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
            if (attr.unique != .none) try self.av_adds.put(self.arena, try self.avKey(attr.id, vbytes), e);
        }
        if (key.isAttrPartition(e)) self.schema_touched = true;
    }

    fn pushRetract(self: *Ctx, e: u64, attr: Attr, v: Val, vbytes: []const u8) !void {
        try self.push(e, attr, v, vbytes, false);
    }

    fn txInstant(self: *Ctx) !void {
        const attr = try self.attrById(boot.tx_instant);
        try self.expandAdd(key.txEntity(self.t), attr, .{ .instant = self.now_ms });
    }

    // ── step 5: schema ────────────────────────────────────────────

    /// Attribute entities: a new attribute needs `:db/valueType` and
    /// `:db/cardinality`; an existing one keeps both; adding
    /// `:db/index` or `:db/unique` backfills AVET from AEVT.
    fn applySchema(self: *Ctx) !void {
        if (!self.schema_touched) return;
        var new_attrs: std.AutoHashMapUnmanaged(u32, struct { has_type: bool = false, has_card: bool = false }) = .empty;
        var backfill: std.AutoHashMapUnmanaged(u32, Attr) = .empty;
        for (self.overlay.items) |p| {
            if (!key.isAttrPartition(p.e)) continue;
            const a: u32 = @intCast(p.e);
            const existing = self.schema.attr(a);
            switch (p.attr.id) {
                boot.value_type, boot.cardinality => {
                    if (!p.added) return error.Conflict;
                    if (existing != null) return error.Conflict;
                    const g = try new_attrs.getOrPut(self.arena, a);
                    if (!g.found_existing) g.value_ptr.* = .{};
                    if (p.attr.id == boot.value_type) g.value_ptr.has_type = true else g.value_ptr.has_card = true;
                },
                boot.unique, boot.index => {
                    if (!p.added) return error.Conflict;
                    if (p.attr.id == boot.index and !p.v.boolean) continue;
                    if (existing) |ex| {
                        if (!ex.inAvet()) {
                            try backfill.put(self.arena, a, ex.*);
                        } else if (p.attr.id == boot.unique) {
                            try self.checkUniqueAvet(ex.*);
                        }
                    }
                },
                else => {},
            }
        }
        var it = new_attrs.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.has_type or !e.value_ptr.has_card) return error.TxData;
        }
        var bit = backfill.iterator();
        while (bit.next()) |e| try self.backfillAvet(e.value_ptr.*);
    }

    /// An indexed attribute becoming unique: no value may be held by two
    /// entities, in the tree or in this transaction.
    fn checkUniqueAvet(self: *Ctx, attr: Attr) !void {
        const store = self.conn.store;
        const prefix = try key.prefixBytes(self.arena, .avet, .{ .a = attr.id });
        var s = try store.scan(self.txn, store.trees.cur(.avet), prefix);
        var prev: ?[]const u8 = null;
        while (s.next()) |kv| {
            const parts = try key.unpackKey(.avet, false, kv.key);
            const fk = try key.keyBytes(self.arena, .eavt, parts.e, parts.a, parts.v, null);
            if (self.facts.get(fk)) |i| if (!self.overlay.items[i].added) continue;
            if (prev) |pv| if (std.mem.eql(u8, pv, parts.v)) return error.Unique;
            prev = try self.arena.dupe(u8, parts.v);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        for (self.overlay.items) |p| {
            if (p.attr.id != attr.id or !p.added) continue;
            if ((try seen.getOrPut(self.arena, p.vbytes)).found_existing) return error.Unique;
            if (try self.probeAvet(attr.id, p.vbytes)) |other| if (other != p.e) return error.Unique;
        }
    }

    /// Copy every current `(e v t)` of the attribute from AEVT into AVET
    /// and AVET-h with its original `t`, refusing duplicate values when
    /// the attribute becomes unique.
    fn backfillAvet(self: *Ctx, attr: Attr) !void {
        var unique = false;
        for (self.overlay.items) |p| {
            if (p.e == attr.id and p.attr.id == boot.unique and p.added) unique = true;
        }
        const store = self.conn.store;
        const prefix = try key.prefixBytes(self.arena, .aevt, .{ .a = attr.id });
        var rows: std.ArrayList(struct { e: u64, vbytes: []const u8, t: u64 }) = .empty;
        var s = try store.scan(self.txn, store.trees.cur(.aevt), prefix);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        while (s.next()) |kv| {
            const parts = try key.unpackKey(.aevt, false, kv.key);
            if (kv.value.len < key.id_len) return error.Corrupted;
            const fk = try key.keyBytes(self.arena, .eavt, parts.e, parts.a, parts.v, null);
            if (self.facts.get(fk)) |i| if (!self.overlay.items[i].added) continue;
            const vb = try self.arena.dupe(u8, parts.v);
            if (unique) {
                if ((try seen.getOrPut(self.arena, vb)).found_existing) return error.Unique;
            }
            try rows.append(self.arena, .{ .e = parts.e, .vbytes = vb, .t = key.readId(kv.value[0..key.id_len]) });
        }
        if (unique) {
            for (self.overlay.items) |p| {
                if (p.attr.id != attr.id or !p.added) continue;
                if ((try seen.getOrPut(self.arena, p.vbytes)).found_existing) return error.Unique;
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
        // Pending datoms of this attribute in this transaction now belong in AVET too.
        for (self.overlay.items) |*p| {
            if (p.attr.id == attr.id) {
                p.attr.indexed = true;
                if (unique) p.attr.unique = .identity;
            }
        }
    }

    // ── step 6: write ─────────────────────────────────────────────

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
        }
        try store.writeBatch(self.txn, self.t, batch, self.arena);

        var it = counts.iterator();
        while (it.next()) |e| {
            const cur: i64 = @intCast(try store.attrCount(self.txn, e.key_ptr.*));
            const next = cur + e.value_ptr.*;
            if (next < 0) return error.Corrupted;
            try store.writeAttrCount(self.txn, e.key_ptr.*, @intCast(next));
        }

        const datoms = try self.txData();
        const names: datom_mod.NameSource = .{ .ctx = @ptrCast(self), .identName = &identName };
        const entry = try datom_mod.encodeTxlog(self.arena, self.now_ms, datoms, names);
        try store.putTxlog(self.txn, self.t, entry);

        try store.writeT(self.txn, self.t);
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
    var out: std.ArrayList(Value) = .empty;
    switch (v.kind()) {
        .persistent_vector => {
            var it = vector_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .persistent_set => {
            var it = champ.setIter(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .list => {
            var it = list_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        else => unreachable,
    }
    return out.toOwnedSlice(arena);
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
    try testing.expectEqual(@as(u64, 0), (try (try tc.conn.db()).attr(arena, name)).?.count);
    try testing.expectEqual(@as(u64, 1), (try (try tc.conn.db()).attr(arena, email)).?.count);

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
    try testing.expect((try db2.attr(arena, name)).?.indexed);
    try testing.expect(!(try db2.asOf(r1.t).attr(arena, name)).?.indexed);
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
    // Value type and cardinality never change.
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
    var heap = @import("heap").Heap.init(arena);
    defer heap.deinit();
    const dispatch = @import("dispatch");
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
        fn s(h: *@import("heap").Heap, t: []const u8) !Value {
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
    const rep = try transact(tc.conn, arena, tx_data, .{ .now_ms = 42 });
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
    try testing.expectEqual(@as(i64, 42), txe[1].vals[0].instant);

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
    defer w.finish();

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
    try testing.expectEqual(@as(u64, 1), (try view.attr(arena, email)).?.count);
    const entries = try db_mod.txRange(&w.view, arena, w.report.t, null);
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
        defer txn.abort();
        try testing.expect((try w.view.idents.idOf(txn, k_new)) != null);
    }
    try testing.expect(tc.conn.idents.by_intern.get(k_new) == null);

    // The committed state is untouched.
    try testing.expectEqual(before.basis, (try tc.conn.db()).basis);
    try testing.expectEqual(@as(usize, 0), (try before.entity(arena, a)).len);
    try testing.expectEqual(@as(usize, 0), (try w.report.db_before.entity(arena, a)).len);
    try testing.expectEqual(@as(u64, 0), (try before.attr(arena, email)).?.count);

    // One write transaction per store: nothing else may begin one.
    try testing.expectError(error.Nested, withOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Nested, transactOps(tc.conn, arena, &.{}, .{}));
    try testing.expectError(error.Nested, transactOps(&w.view, arena, &.{}, .{}));
    try testing.expectError(error.Nested, withOps(&w.view, arena, &.{}, .{}));

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
    defer w.finish();
    const nick: u32 = @intCast(w.report.tempids[0].eid);
    try testing.expectEqual(key.ValueType.string, (try w.db().attr(arena, nick)).?.value_type);
    try testing.expectEqual(@as(?u64, nick), try w.db().entid(arena, .{ .ident = try kw(tc, "user/nick") }));
    try testing.expect((try (try tc.conn.db()).attr(arena, nick)) == null);
    w.finish();
    try testing.expect((try (try tc.conn.db()).attr(arena, nick)) == null);
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
    var heap = @import("heap").Heap.init(arena);
    defer heap.deinit();
    try installSchema(tc, arena);
    const name = try attrId(tc, "user/name");
    const add = try vector_mod.fromSlice(&heap, &.{
        try tc.interner.internKeywordValue("db/add"),
        try string_mod.fromBytes(&heap, "z"),
        try tc.interner.internKeywordValue("user/name"),
        try string_mod.fromBytes(&heap, "Zed"),
    });
    const w = try with(tc.conn, arena, try vector_mod.fromSlice(&heap, &.{add}), .{ .now_ms = 7 });
    defer w.finish();
    const z = w.report.tempids[0].eid;
    const ent = try w.db().entity(arena, z);
    try testing.expectEqual(@as(usize, 1), ent.len);
    try testing.expectEqual(name, ent[0].a);
    try testing.expectEqualStrings("Zed", ent[0].vals[0].string);
    try testing.expectEqual(@as(i64, 7), (try w.db().entity(arena, key.txEntity(w.report.t)))[0].vals[0].instant);
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
