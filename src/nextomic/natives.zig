//! natives.zig — the `nextomic` namespace (NEXTOMIC.md §6, §7).
//!
//! Every native opens what it needs for its own duration: a
//! transaction, an arena for the storage layer's scratch, and copies
//! only results into the VM heap. Marshalling runs both ways here:
//! Lisp values become `key.Val` by the attribute's `:db/valueType`
//! (fixnum → long or instant, double → double, keyword → ident id,
//! eid/ident/lookup ref → ref, string → string, uuid or bytes text →
//! their storage form, boolean → boolean) and datom values come back
//! through `Conn.valToValue`.
//!
//! Errors: every `nextomic.Error` and storage error becomes a keyword
//! thrown through `VM.throwKeyword`, catchable by `try`. Wrong-kind
//! arguments are `KindMismatch`, as for every other native.
//!
//! Connection lifetime: `connect` registers the `Conn` on
//! `vm.nextomic_connections`; `release` closes it (idempotent, and
//! `:nextomic/busy` while an operation on it is in flight) and leaves
//! the struct allocated so db-values still pointing at it raise
//! `:nextomic/closed`; VM teardown destroys every connection through
//! `closeCallback`.
//!
//! Per-VM state (`State`): the parsed-query caches and every finished
//! `with` scope, created on first use and destroyed at VM teardown
//! through `vm.nextomic_query_close`. A scope's arena holds the view
//! `Conn` that its db-values name, so it outlives the scope the way a
//! released connection's struct does: after `finish` the view answers
//! `:nextomic/closed`.

const std = @import("std");
const value = @import("value");
const vm_mod = @import("vm");
const heap_mod = @import("heap");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const dispatch = @import("dispatch");
const dblayer = @import("db");
const emdb = @import("emdb");
const handle = @import("nextomic_handle");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const schema_mod = @import("schema.zig");
const db_mod = @import("db.zig");
const transact_mod = @import("transact.zig");
const pull_mod = @import("pull.zig");
const query = @import("query.zig");
const query_natives = @import("query/natives.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const VM = vm_mod.VM;
const VmError = vm_mod.VmError;
const NativeFn = vm_mod.NativeFn;
const Namespace = vm_mod.Namespace;
const Heap = heap_mod.Heap;
const Conn = db_mod.Conn;
const DbValue = db_mod.DbValue;
const Read = db_mod.Read;
const Txn = emdb.Txn;
const Val = key.Val;
const Index = key.Index;
const Datom = datom_mod.Datom;
const Attr = schema_mod.Attr;
const SyncMode = store_mod.SyncMode;
const boot = store_mod.boot;
const Diag = pull_mod.Diag;

// =============================================================================
// Installation
// =============================================================================

const Entry = struct { name: []const u8, descriptor: *const NativeFn };

const natives = [_]Entry{
    .{ .name = "connect", .descriptor = &native_connect },
    .{ .name = "release", .descriptor = &native_release },
    .{ .name = "db", .descriptor = &native_db },
    .{ .name = "basis-t", .descriptor = &native_basis_t },
    .{ .name = "transact!", .descriptor = &native_transact },
    .{ .name = "entity", .descriptor = &native_entity },
    .{ .name = "entid", .descriptor = &native_entid },
    .{ .name = "ident", .descriptor = &native_ident },
    .{ .name = "datoms", .descriptor = &native_datoms },
    .{ .name = "as-of", .descriptor = &native_as_of },
    .{ .name = "since", .descriptor = &native_since },
    .{ .name = "history", .descriptor = &native_history },
    .{ .name = "tx-range", .descriptor = &native_tx_range },
    .{ .name = "schema", .descriptor = &native_schema },
    .{ .name = "sync", .descriptor = &native_sync },
    .{ .name = "pull", .descriptor = &native_pull },
    .{ .name = "pull-many", .descriptor = &native_pull_many },
    .{ .name = "with", .descriptor = &native_with },
};

/// Install the `nextomic/*` natives into `ns`, then the query natives
/// (`q`, `explain`; NEXTOMIC.md §5) from `query/natives.zig`.
pub fn install(ns: *Namespace) !void {
    for (natives) |entry| {
        const v = try ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
    }
    try query_natives.install(ns);
}

const native_connect = NativeFn{ .name = "nextomic/connect", .min_arity = 1, .max_arity = 2, .call = &fnConnect };
const native_release = NativeFn{ .name = "nextomic/release", .min_arity = 1, .max_arity = 1, .call = &fnRelease };
const native_db = NativeFn{ .name = "nextomic/db", .min_arity = 1, .max_arity = 1, .call = &fnDb };
const native_basis_t = NativeFn{ .name = "nextomic/basis-t", .min_arity = 1, .max_arity = 1, .call = &fnBasisT };
const native_transact = NativeFn{ .name = "nextomic/transact!", .min_arity = 2, .max_arity = 3, .call = &fnTransact };
const native_entity = NativeFn{ .name = "nextomic/entity", .min_arity = 2, .max_arity = 2, .call = &fnEntity };
const native_entid = NativeFn{ .name = "nextomic/entid", .min_arity = 2, .max_arity = 2, .call = &fnEntid };
const native_ident = NativeFn{ .name = "nextomic/ident", .min_arity = 2, .max_arity = 2, .call = &fnIdent };
const native_datoms = NativeFn{ .name = "nextomic/datoms", .min_arity = 2, .max_arity = 5, .call = &fnDatoms };
const native_as_of = NativeFn{ .name = "nextomic/as-of", .min_arity = 2, .max_arity = 2, .call = &fnAsOf };
const native_since = NativeFn{ .name = "nextomic/since", .min_arity = 2, .max_arity = 2, .call = &fnSince };
const native_history = NativeFn{ .name = "nextomic/history", .min_arity = 1, .max_arity = 1, .call = &fnHistory };
const native_tx_range = NativeFn{ .name = "nextomic/tx-range", .min_arity = 1, .max_arity = 3, .call = &fnTxRange };
const native_schema = NativeFn{ .name = "nextomic/schema", .min_arity = 1, .max_arity = 1, .call = &fnSchema };
const native_sync = NativeFn{ .name = "nextomic/sync", .min_arity = 1, .max_arity = 1, .call = &fnSync };
const native_pull = NativeFn{ .name = "nextomic/pull", .min_arity = 3, .max_arity = 3, .call = &fnPull };
const native_pull_many = NativeFn{ .name = "nextomic/pull-many", .min_arity = 3, .max_arity = 3, .call = &fnPullMany };
const native_with = NativeFn{ .name = "nextomic/with", .min_arity = 3, .max_arity = 3, .call = &fnWith };

// =============================================================================
// Per-VM state
// =============================================================================

pub const State = struct {
    gpa: Allocator,
    ir_cache: query.Cache,
    rules_cache: query.RulesCache,
    /// Finished `with` scopes. Each arena holds the view `Conn` that
    /// the scope's db-values name, so it lives until VM teardown.
    scopes: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
};

/// The VM's state, created on first use.
pub fn state(vm: *VM) !*State {
    if (vm.nextomic_query_state) |p| return @ptrCast(@alignCast(p));
    const s = try vm.allocator.create(State);
    s.* = .{
        .gpa = vm.allocator,
        .ir_cache = query.Cache.init(vm.allocator),
        .rules_cache = query.RulesCache.init(vm.allocator),
    };
    vm.nextomic_query_state = @ptrCast(s);
    vm.nextomic_query_close = &closeState;
    return s;
}

fn closeState(ptr: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    for (s.scopes.items) |scope| {
        scope.deinit();
        s.gpa.destroy(scope);
    }
    s.scopes.deinit(s.gpa);
    s.ir_cache.deinit();
    s.rules_cache.deinit();
    s.gpa.destroy(s);
}

// =============================================================================
// Errors (§7)
// =============================================================================

/// The keyword an error surfaces as: the `nextomic` set for the
/// storage, transaction and pull layers' own errors, the `db.zig` set
/// for engine errors.
pub fn errorKeyword(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownAttribute => "nextomic/unknown-attribute",
        error.ValueType => "nextomic/value-type",
        error.Unique => "nextomic/unique",
        error.Conflict => "nextomic/conflict",
        error.NoEntity => "nextomic/no-entity",
        error.BasisInFuture => "nextomic/basis-in-future",
        error.Closed => "nextomic/closed",
        error.Busy => "nextomic/busy",
        error.TxData => "nextomic/tx-data",
        error.Nested => "nextomic/nested",
        error.PullSyntax => "nextomic/pull-syntax",
        error.HistoryView => "nextomic/history-view",
        error.Format, error.UnknownIdent => "db/corrupted",
        else => dblayer.failureName(err),
    };
}

/// Surface `err` to the program. VM errors pass through unchanged;
/// everything else is thrown as its keyword.
pub fn fail(vm: *VM, err: anyerror) VmError {
    inline for (@typeInfo(VmError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(VmError, e.name);
    }
    return vm.throwKeyword(errorKeyword(err));
}

/// Throw the map a syntax error travels as (§7): `{:error name
/// :message message :clause clause}`, `:clause` present when given.
pub fn throwSyntax(vm: *VM, name: []const u8, message: []const u8, clause: ?usize) VmError {
    const payload = syntaxPayload(vm, name, message, clause) catch return VmError.OutOfMemory;
    return vm.throwValue(payload);
}

fn syntaxPayload(vm: *VM, name: []const u8, message: []const u8, clause: ?usize) !Value {
    const heap = vm.ensureHeap();
    const it = vm.ensureInterner();
    var m = try champ.mapEmpty(heap);
    m = try champ.mapAssoc(heap, m, try it.internKeywordValue("error"), try it.internKeywordValue(name), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(heap, m, try it.internKeywordValue("message"), try string_mod.fromBytes(heap, message), &dispatch.hashValue, &dispatch.equal);
    if (clause) |c| {
        const n = value.fromFixnum(@intCast(c)) orelse return error.ArithmeticOverflow;
        m = try champ.mapAssoc(heap, m, try it.internKeywordValue("clause"), n, &dispatch.hashValue, &dispatch.equal);
    }
    return m;
}

// =============================================================================
// Connections
// =============================================================================

/// VM teardown closer: destroys a connection that was never released
/// or was released and is still on the list.
fn closeCallback(ptr: *anyopaque) void {
    const c: *Conn = @ptrCast(@alignCast(ptr));
    c.destroy();
}

fn connOf(v: Value) !*Conn {
    if (v.kind() != .nextomic_conn) return error.KindMismatch;
    return @ptrCast(@alignCast(handle.connPtr(v)));
}

/// The connection behind an open handle.
fn openConn(v: Value) !*Conn {
    const c = try connOf(v);
    if (!c.is_open) return error.Closed;
    return c;
}

pub fn dbOf(v: Value) !DbValue {
    if (v.kind() != .nextomic_db) return error.KindMismatch;
    const s = handle.dbShape(v);
    const c: *Conn = @ptrCast(@alignCast(s.conn));
    if (!c.is_open) return error.Closed;
    return .{ .conn = c, .basis = s.basis, .as_of = s.as_of, .since = s.since, .history = s.history };
}

fn boxDb(heap: *Heap, d: DbValue) !Value {
    return handle.makeDb(heap, .{ .conn = @ptrCast(d.conn), .basis = d.basis, .as_of = d.as_of, .since = d.since, .history = d.history });
}

/// `{:sync :full | :no-meta | :none}`; nil means the default.
fn syncOption(vm: *VM, v: Value) !?SyncMode {
    if (v.isNil()) return null;
    if (v.kind() != .persistent_map) return error.KindMismatch;
    const k = try vm.ensureInterner().internKeywordValue("sync");
    const found = switch (champ.mapGet(v, k, &dispatch.hashValue, &dispatch.equal)) {
        .absent => return null,
        .present => |x| x,
    };
    if (found.kind() != .keyword) return error.InvalidArgument;
    const name = vm.ensureInterner().keywordName(found.asKeywordId());
    if (std.mem.eql(u8, name, "full")) return .full;
    if (std.mem.eql(u8, name, "no-meta")) return .no_meta;
    if (std.mem.eql(u8, name, "none")) return .none;
    return error.InvalidArgument;
}

fn fnConnect(vm: *VM, args: []const Value) VmError!Value {
    return connect(vm, args) catch |err| fail(vm, err);
}

fn connect(vm: *VM, args: []const Value) !Value {
    if (args[0].kind() != .string) return error.KindMismatch;
    const path = string_mod.asBytes(args[0]);
    var options: db_mod.OpenOptions = .{};
    if (args.len == 2) options.sync = (try syncOption(vm, args[1])) orelse options.sync;

    const path_z = try vm.allocator.dupeZ(u8, path);
    defer vm.allocator.free(path_z);
    // The engine does not create parent directories; best effort here.
    if (vm.io) |io| {
        if (std.fs.path.dirname(path)) |dir| {
            if (dir.len > 0) std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
    }
    const c = try Conn.open(vm.allocator, vm.ensureInterner(), path_z.ptr, options);
    errdefer c.destroy();
    vm.nextomic_close_callback = &closeCallback;
    try vm.nextomic_connections.append(vm.allocator, @ptrCast(c));
    return handle.makeConn(vm.ensureHeap(), @ptrCast(c), path);
}

/// `(release conn)`: idempotent; `:nextomic/busy` while a query, pull,
/// transaction or `with` on the connection is in flight, so nothing
/// running holds cursors into a freed store.
fn fnRelease(vm: *VM, args: []const Value) VmError!Value {
    const c = connOf(args[0]) catch |err| return fail(vm, err);
    c.release() catch |err| return fail(vm, err);
    return value.nilValue();
}

fn fnDb(vm: *VM, args: []const Value) VmError!Value {
    return dbNative(vm, args) catch |err| fail(vm, err);
}

fn dbNative(vm: *VM, args: []const Value) !Value {
    const c = try openConn(args[0]);
    return boxDb(vm.ensureHeap(), try c.db());
}

fn fnBasisT(vm: *VM, args: []const Value) VmError!Value {
    const d = dbOf(args[0]) catch |err| return fail(vm, err);
    return value.fromFixnum(@intCast(d.basis)) orelse VmError.ArithmeticOverflow;
}

fn fnSync(vm: *VM, args: []const Value) VmError!Value {
    const c = openConn(args[0]) catch |err| return fail(vm, err);
    c.sync() catch |err| return fail(vm, err);
    return value.nilValue();
}

// =============================================================================
// Marshalling: Lisp → Val
// =============================================================================

/// Attribute id of a keyword ident or a fixnum id.
fn attrId(rd: *Read, v: Value) !u32 {
    switch (v.kind()) {
        .keyword => return (try rd.db.conn.idents.idOf(rd.txn, v.asKeywordId())) orelse error.UnknownAttribute,
        .fixnum => {
            const n = v.asFixnum();
            if (n <= 0 or n > std.math.maxInt(u32)) return error.UnknownAttribute;
            return @intCast(n);
        },
        else => return error.KindMismatch,
    }
}

fn attrOf(rd: *Read, v: Value) !Attr {
    return (try rd.attr(try attrId(rd, v))) orelse error.UnknownAttribute;
}

/// An entity position: an eid, an ident keyword or a lookup ref
/// `[attr v]`. Null when the ident or lookup names nothing in this view.
pub fn entityRef(rd: *Read, arena: Allocator, v: Value) anyerror!?u64 {
    switch (v.kind()) {
        .fixnum => {
            const n = v.asFixnum();
            if (n <= 0 or n > @as(i64, @intCast(key.id_max))) return error.NoEntity;
            return @intCast(n);
        },
        .keyword => return rd.entid(arena, .{ .ident = v.asKeywordId() }),
        .persistent_vector => {
            if (vector_mod.count(v) != 2) return error.KindMismatch;
            const a = try attrId(rd, vector_mod.nth(v, 0));
            const attr = (try rd.attr(a)) orelse return error.UnknownAttribute;
            const lv = (try valFrom(rd, arena, attr.value_type, vector_mod.nth(v, 1))) orelse return null;
            return rd.entid(arena, .{ .lookup = .{ .a = a, .v = lv } });
        },
        else => return error.KindMismatch,
    }
}

/// Convert a Lisp value by an attribute's value type. Null when a
/// keyword or entity reference names nothing in this view, so that no
/// datom can match it; `error.ValueType` on a kind mismatch.
pub fn valFrom(rd: *Read, arena: Allocator, vt: key.ValueType, v: Value) anyerror!?Val {
    switch (vt) {
        .boolean => {
            if (!v.isBool()) return error.ValueType;
            return .{ .boolean = v.asBool() };
        },
        .long => {
            if (v.kind() != .fixnum) return error.ValueType;
            return .{ .long = v.asFixnum() };
        },
        .double => {
            if (v.kind() != .float) return error.ValueType;
            const d = v.asFloat();
            if (std.math.isNan(d)) return error.ValueType;
            return .{ .double = d };
        },
        .instant => {
            if (v.kind() != .fixnum) return error.ValueType;
            return .{ .instant = v.asFixnum() };
        },
        .keyword => {
            if (v.kind() != .keyword) return error.ValueType;
            const id = (try rd.db.conn.idents.idOf(rd.txn, v.asKeywordId())) orelse return null;
            return .{ .keyword = id };
        },
        .ref => {
            const e = entityRef(rd, arena, v) catch |err| switch (err) {
                error.KindMismatch => return error.ValueType,
                else => return err,
            };
            return .{ .ref = e orelse return null };
        },
        .string => {
            if (v.kind() != .string) return error.ValueType;
            return .{ .string = string_mod.asBytes(v) };
        },
        .uuid => {
            if (v.kind() != .string) return error.ValueType;
            return .{ .uuid = datom_mod.uuidFromText(string_mod.asBytes(v)) orelse return error.ValueType };
        },
        .bytes => {
            if (v.kind() != .string) return error.ValueType;
            return .{ .bytes = string_mod.asBytes(v) };
        },
    }
}

// =============================================================================
// Marshalling: datoms → Lisp
// =============================================================================

const Builder = struct {
    vm: *VM,
    conn: *Conn,
    txn: *Txn,
    heap: *Heap,

    fn init(vm: *VM, conn: *Conn, txn: *Txn) Builder {
        return .{ .vm = vm, .conn = conn, .txn = txn, .heap = vm.ensureHeap() };
    }

    fn kw(self: *Builder, name: []const u8) !Value {
        return self.vm.ensureInterner().internKeywordValue(name);
    }

    fn fixnum(self: *Builder, n: u64) !Value {
        _ = self;
        return value.fromFixnum(@intCast(n)) orelse error.ArithmeticOverflow;
    }

    fn attrKeyword(self: *Builder, a: u32) !Value {
        const k = (try self.conn.idents.internOf(self.txn, a)) orelse return error.Corrupted;
        return value.fromKeywordId(k);
    }

    fn val(self: *Builder, v: Val) !Value {
        return self.conn.valToValue(self.txn, self.heap, v);
    }

    /// `[e a v t added]`.
    fn datom(self: *Builder, d: Datom) !Value {
        const elems = [_]Value{
            try self.fixnum(d.e),
            try self.attrKeyword(d.a),
            try self.val(d.v),
            try self.fixnum(d.t),
            value.fromBool(d.added),
        };
        return vector_mod.fromSlice(self.heap, &elems);
    }

    fn datoms(self: *Builder, arena: Allocator, ds: []const Datom) !Value {
        const elems = try arena.alloc(Value, ds.len);
        for (elems, ds) |*out, d| out.* = try self.datom(d);
        return vector_mod.fromSlice(self.heap, elems);
    }

    fn put(self: *Builder, m: Value, k: Value, v: Value) !Value {
        return champ.mapAssoc(self.heap, m, k, v, &dispatch.hashValue, &dispatch.equal);
    }

    fn putKw(self: *Builder, m: Value, name: []const u8, v: Value) !Value {
        return self.put(m, try self.kw(name), v);
    }
};

// =============================================================================
// transact!
// =============================================================================

fn fnTransact(vm: *VM, args: []const Value) VmError!Value {
    return transactNative(vm, args) catch |err| fail(vm, err);
}

fn transactNative(vm: *VM, args: []const Value) !Value {
    const c = try openConn(args[0]);
    var options: transact_mod.Options = .{};
    if (args.len == 3) options.sync = try syncOption(vm, args[2]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const report = try transact_mod.transact(c, arena, args[1], options);
    return reportMap(vm, c, arena, report);
}

/// The report (§3): `{:db-before :db-after :tx :tempids :tx-data}`.
/// `conn` resolves the report's idents and values: the connection
/// after `transact!`, the view after `with`, whose minted idents live
/// in the view's cache only.
fn reportMap(vm: *VM, conn: *Conn, arena: Allocator, report: transact_mod.Report) !Value {
    const txn = try conn.beginReadTxn();
    defer conn.endReadTxn(txn);
    var b = Builder.init(vm, conn, txn);

    var tempids = try champ.mapEmpty(b.heap);
    for (report.tempids) |t| {
        const k: Value = switch (t.key) {
            .string => |s| try string_mod.fromBytes(b.heap, s),
            .fixnum => |n| value.fromFixnum(n) orelse return error.ArithmeticOverflow,
        };
        tempids = try b.put(tempids, k, try b.fixnum(t.eid));
    }

    var m = try champ.mapEmpty(b.heap);
    m = try b.putKw(m, "db-before", try boxDb(b.heap, report.db_before));
    m = try b.putKw(m, "db-after", try boxDb(b.heap, report.db_after));
    m = try b.putKw(m, "tx", try b.fixnum(report.t));
    m = try b.putKw(m, "tempids", tempids);
    m = try b.putKw(m, "tx-data", try b.datoms(arena, report.tx_data));
    return m;
}

// =============================================================================
// with
// =============================================================================

fn fnWith(vm: *VM, args: []const Value) VmError!Value {
    return withNative(vm, args) catch |err| fail(vm, err);
}

/// `(with conn tx-data f)`: apply tx-data in a held write transaction,
/// call `f` with a db-value over the uncommitted state and the report
/// `transact!` would have returned, then abort. Whatever `f` raises
/// propagates after the abort. The scope's arena goes on the VM state:
/// it holds the view `Conn` that `db-after`, and every db-value
/// derived from it, name.
fn withNative(vm: *VM, args: []const Value) !Value {
    const c = try openConn(args[0]);
    const f = args[2];
    const st = try state(vm);
    try st.scopes.ensureUnusedCapacity(vm.allocator, 1);
    const scope = try vm.allocator.create(std.heap.ArenaAllocator);
    scope.* = .init(vm.allocator);
    const w = transact_mod.with(c, scope.allocator(), args[1], .{}) catch |err| {
        scope.deinit();
        vm.allocator.destroy(scope);
        return err;
    };
    st.scopes.appendAssumeCapacity(scope);
    defer w.finish();

    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const report = try reportMap(vm, &w.view, arena_state.allocator(), w.report);
    const db_after = try boxDb(vm.ensureHeap(), w.db());
    return vm.callValue(f, &.{ db_after, report });
}

// =============================================================================
// pull, pull-many
// =============================================================================

fn fnPull(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return pullNative(vm, args, &diag) catch |err| failPull(vm, err, &diag);
}

/// `(pull db pattern e)`: the pattern's map for `e`; nil when the
/// entity has no datoms in this view.
fn pullNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const d = try dbOf(args[0]);
    return pull_mod.pull(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), d, args[1], args[2], diag);
}

fn fnPullMany(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return pullManyNative(vm, args, &diag) catch |err| failPull(vm, err, &diag);
}

/// `(pull-many db pattern es)`: one result per entity of the vector
/// or list `es`, in its order, all in one read.
fn pullManyNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const d = try dbOf(args[0]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const es = try entities(arena_state.allocator(), args[2]);
    return pull_mod.pullMany(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), d, args[1], es, diag);
}

/// A pattern or entity syntax error travels with its reason.
fn failPull(vm: *VM, err: anyerror, diag: *const Diag) VmError {
    if (err == error.PullSyntax) return throwSyntax(vm, "nextomic/pull-syntax", diag.message, diag.clause);
    return fail(vm, err);
}

/// The elements of a vector or list.
fn entities(arena: Allocator, v: Value) ![]Value {
    var out: std.ArrayList(Value) = .empty;
    switch (v.kind()) {
        .persistent_vector => {
            var it = vector_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .list => {
            var it = list_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        else => return error.KindMismatch,
    }
    return out.items;
}

// =============================================================================
// Reads
// =============================================================================

fn fnEntity(vm: *VM, args: []const Value) VmError!Value {
    return entityNative(vm, args) catch |err| fail(vm, err);
}

/// `{:db/id e :attr v ...}` with card-many values as sets; nil when the
/// entity has no datoms in this view.
fn entityNative(vm: *VM, args: []const Value) !Value {
    const d = try dbOf(args[0]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rd = try d.beginRead();
    defer rd.close();
    const e = (try entityRef(&rd, arena, args[1])) orelse return value.nilValue();
    var b = Builder.init(vm, d.conn, rd.txn);

    var it = try rd.scan(arena, .eavt, .{ .e = e });
    var m: ?Value = null;
    var cur_a: u32 = 0;
    var cur_attr: Attr = undefined;
    var many: ?Value = null;
    while (try it.next()) |dt| {
        if (m == null) {
            m = try b.putKw(try champ.mapEmpty(b.heap), "db/id", try b.fixnum(e));
        }
        if (many != null and dt.a != cur_a) {
            m = try b.put(m.?, try b.attrKeyword(cur_a), many.?);
            many = null;
        }
        if (many == null or dt.a != cur_a) {
            cur_a = dt.a;
            cur_attr = (try rd.attr(dt.a)) orelse return error.Corrupted;
        }
        const v = try b.val(dt.v);
        if (cur_attr.many()) {
            const set = many orelse try champ.setEmpty(b.heap);
            many = try champ.setConj(b.heap, set, v, &dispatch.hashValue, &dispatch.equal);
        } else {
            m = try b.put(m.?, try b.attrKeyword(dt.a), v);
        }
    }
    if (many) |set| m = try b.put(m.?, try b.attrKeyword(cur_a), set);
    return m orelse value.nilValue();
}

fn fnEntid(vm: *VM, args: []const Value) VmError!Value {
    return entidNative(vm, args) catch |err| fail(vm, err);
}

fn entidNative(vm: *VM, args: []const Value) !Value {
    const d = try dbOf(args[0]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    var rd = try d.beginRead();
    defer rd.close();
    const e = (try entityRef(&rd, arena_state.allocator(), args[1])) orelse return value.nilValue();
    return value.fromFixnum(@intCast(e)) orelse error.ArithmeticOverflow;
}

fn fnIdent(vm: *VM, args: []const Value) VmError!Value {
    return identNative(vm, args) catch |err| fail(vm, err);
}

/// The ident keyword of an eid; a keyword answers itself when it is an
/// ident in this view. Nil otherwise.
fn identNative(vm: *VM, args: []const Value) !Value {
    const d = try dbOf(args[0]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rd = try d.beginRead();
    defer rd.close();
    const x = args[1];
    switch (x.kind()) {
        .fixnum => {
            const n = x.asFixnum();
            if (n <= 0 or n > @as(i64, @intCast(key.id_max))) return value.nilValue();
            const k = (try rd.ident(arena, @intCast(n))) orelse return value.nilValue();
            return value.fromKeywordId(k);
        },
        .keyword => {
            if ((try rd.entid(arena, .{ .ident = x.asKeywordId() })) == null) return value.nilValue();
            return x;
        },
        else => return error.KindMismatch,
    }
}

fn fnDatoms(vm: *VM, args: []const Value) VmError!Value {
    return datomsNative(vm, args) catch |err| fail(vm, err);
}

/// `(datoms db index & components)`: components follow the index's
/// order; nil leaves a position unbound and later ones filter.
fn datomsNative(vm: *VM, args: []const Value) !Value {
    const d = try dbOf(args[0]);
    const index = try indexOf(vm, args[1]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var rd = try d.beginRead();
    defer rd.close();
    var b = Builder.init(vm, d.conn, rd.txn);
    const empty = try vector_mod.fromSlice(b.heap, &.{});

    const order: [3]u8 = switch (index) {
        .eavt => .{ 'e', 'a', 'v' },
        .aevt => .{ 'a', 'e', 'v' },
        .avet => .{ 'a', 'v', 'e' },
        .vaet => .{ 'v', 'a', 'e' },
    };
    var comps: key.Components = .{};
    var attr: ?Attr = null;
    for (args[2..], 0..) |arg, i| {
        if (arg.isNil()) continue;
        switch (order[i]) {
            'e' => comps.e = (try entityRef(&rd, arena, arg)) orelse return empty,
            'a' => {
                const a = try attrId(&rd, arg);
                attr = (try rd.attr(a)) orelse return error.UnknownAttribute;
                comps.a = a;
            },
            'v' => {
                const val: Val = if (index == .vaet)
                    .{ .ref = (try entityRef(&rd, arena, arg)) orelse return empty }
                else
                    (try valFrom(&rd, arena, (attr orelse return error.ValueType).value_type, arg)) orelse return empty;
                comps.v = try key.valBytes(arena, val);
            },
            else => unreachable,
        }
    }

    var out: std.ArrayList(Value) = .empty;
    var it = try rd.scan(arena, index, comps);
    while (try it.next()) |dt| try out.append(arena, try b.datom(dt));
    return vector_mod.fromSlice(b.heap, out.items);
}

fn indexOf(vm: *VM, v: Value) !Index {
    if (v.kind() != .keyword) return error.KindMismatch;
    const name = vm.ensureInterner().keywordName(v.asKeywordId());
    return std.meta.stringToEnum(Index, name) orelse error.InvalidArgument;
}

// =============================================================================
// Time
// =============================================================================

fn tArg(v: Value) !u64 {
    if (v.kind() != .fixnum) return error.KindMismatch;
    const n = v.asFixnum();
    if (n < 0) return error.InvalidArgument;
    return @intCast(n);
}

fn fnAsOf(vm: *VM, args: []const Value) VmError!Value {
    return timeView(vm, args, .as_of) catch |err| fail(vm, err);
}

fn fnSince(vm: *VM, args: []const Value) VmError!Value {
    return timeView(vm, args, .since) catch |err| fail(vm, err);
}

fn fnHistory(vm: *VM, args: []const Value) VmError!Value {
    return timeView(vm, args, .history) catch |err| fail(vm, err);
}

fn timeView(vm: *VM, args: []const Value, mode: enum { as_of, since, history }) !Value {
    const d = try dbOf(args[0]);
    const view = switch (mode) {
        .as_of => d.asOf(try tArg(args[1])),
        .since => d.sinceT(try tArg(args[1])),
        .history => d.withHistory(),
    };
    return boxDb(vm.ensureHeap(), view);
}

fn fnTxRange(vm: *VM, args: []const Value) VmError!Value {
    return txRangeNative(vm, args) catch |err| fail(vm, err);
}

/// `(tx-range conn from to)`: entries with `from <= t < to`; a nil or
/// absent bound is open.
fn txRangeNative(vm: *VM, args: []const Value) !Value {
    const c = try openConn(args[0]);
    const from: u64 = if (args.len >= 2 and !args[1].isNil()) try tArg(args[1]) else 0;
    const to: ?u64 = if (args.len == 3 and !args[2].isNil()) try tArg(args[2]) else null;
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = try db_mod.txRange(c, arena, from, to);
    const txn = try c.store.beginRead();
    defer txn.abort();
    var b = Builder.init(vm, c, txn);
    const out = try arena.alloc(Value, entries.len);
    for (out, entries) |*slot, entry| {
        var m = try champ.mapEmpty(b.heap);
        m = try b.putKw(m, "t", try b.fixnum(entry.t));
        m = try b.putKw(m, "instant", value.fromFixnum(entry.instant) orelse return error.ArithmeticOverflow);
        m = try b.putKw(m, "data", try b.datoms(arena, entry.datoms));
        slot.* = m;
    }
    return vector_mod.fromSlice(b.heap, out);
}

// =============================================================================
// Schema
// =============================================================================

fn fnSchema(vm: *VM, args: []const Value) VmError!Value {
    return schemaNative(vm, args) catch |err| fail(vm, err);
}

/// Ident → attribute map for every attribute this view sees.
fn schemaNative(vm: *VM, args: []const Value) !Value {
    const d = try dbOf(args[0]);
    var rd = try d.beginRead();
    defer rd.close();
    var b = Builder.init(vm, d.conn, rd.txn);
    const schema = try rd.schema();
    const at = d.upper();

    var out = try champ.mapEmpty(b.heap);
    var it = schema.attrs.iterator();
    while (it.next()) |entry| {
        const attr = schema.attrAt(entry.key_ptr.*, at) orelse continue;
        const ident = try b.attrKeyword(attr.id);
        var m = try champ.mapEmpty(b.heap);
        m = try b.putKw(m, "db/id", try b.fixnum(attr.id));
        m = try b.putKw(m, "db/ident", ident);
        m = try b.putKw(m, "db/valueType", try b.kw(attr.value_type.identName()));
        m = try b.putKw(m, "db/cardinality", try b.kw(if (attr.many()) "db.cardinality/many" else "db.cardinality/one"));
        switch (attr.unique) {
            .none => {},
            .identity => m = try b.putKw(m, "db/unique", try b.kw("db.unique/identity")),
            .value => m = try b.putKw(m, "db/unique", try b.kw("db.unique/value")),
        }
        m = try b.putKw(m, "db/index", value.fromBool(attr.indexed));
        m = try b.putKw(m, "db/isComponent", value.fromBool(attr.component));
        out = try b.put(out, ident, m);
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const TestConn = db_mod.TestConn;
const intern_mod = @import("intern");

test {
    _ = query_natives;
}

test "every nextomic error maps to its §7 keyword; engine errors to the db set" {
    const cases = [_]struct { err: anyerror, name: []const u8 }{
        .{ .err = error.UnknownAttribute, .name = "nextomic/unknown-attribute" },
        .{ .err = error.ValueType, .name = "nextomic/value-type" },
        .{ .err = error.Unique, .name = "nextomic/unique" },
        .{ .err = error.Conflict, .name = "nextomic/conflict" },
        .{ .err = error.NoEntity, .name = "nextomic/no-entity" },
        .{ .err = error.BasisInFuture, .name = "nextomic/basis-in-future" },
        .{ .err = error.Closed, .name = "nextomic/closed" },
        .{ .err = error.Busy, .name = "nextomic/busy" },
        .{ .err = error.TxData, .name = "nextomic/tx-data" },
        .{ .err = error.Nested, .name = "nextomic/nested" },
        .{ .err = error.PullSyntax, .name = "nextomic/pull-syntax" },
        .{ .err = error.HistoryView, .name = "nextomic/history-view" },
        .{ .err = error.Format, .name = "db/corrupted" },
        .{ .err = error.Corrupted, .name = "db/corrupted" },
        .{ .err = error.KeyTooLarge, .name = "db/key-too-large" },
        .{ .err = error.DatabaseFull, .name = "db/map-full" },
        .{ .err = error.SomethingElse, .name = "db-error" },
    };
    for (cases) |c| try testing.expectEqualStrings(c.name, errorKeyword(c.err));
    // The set is total over the storage, transaction and pull errors.
    inline for (.{ db_mod.Error, transact_mod.Error, pull_mod.Error }) |Set| {
        inline for (@typeInfo(Set).error_set.?) |e| {
            const name = errorKeyword(@field(anyerror, e.name));
            try testing.expect(std.mem.startsWith(u8, name, "nextomic/"));
        }
    }
}

test "marshalling both ways for every value type" {
    const tc = try TestConn.init("natives_marshal");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const db = try tc.conn.db();
    var rd = try db.beginRead();
    defer rd.close();
    const conn = tc.conn;

    // Lisp → Val → Lisp, one round trip per type.
    const kw_string = try tc.interner.internKeywordValue("db.type/string");
    const kw_ident = try tc.interner.internKeywordValue("db/ident");
    const kw_doc = try tc.interner.internKeywordValue("db/doc");
    const uuid_text = try string_mod.fromBytes(&heap, "0123abcd-4567-89ef-0123-456789abcdef");
    const lookup = try vector_mod.fromSlice(&heap, &.{ kw_ident, kw_doc });

    const b = (try valFrom(&rd, arena, .boolean, value.fromBool(true))).?;
    try testing.expect(b.boolean);
    try testing.expect((try conn.valToValue(rd.txn, &heap, b)).asBool());

    const n = (try valFrom(&rd, arena, .long, value.fromFixnum(-42).?)).?;
    try testing.expectEqual(@as(i64, -42), n.long);
    try testing.expectEqual(@as(i64, -42), (try conn.valToValue(rd.txn, &heap, n)).asFixnum());

    const f = (try valFrom(&rd, arena, .double, value.fromFloat(2.5))).?;
    try testing.expectEqual(@as(f64, 2.5), f.double);
    try testing.expectEqual(@as(f64, 2.5), (try conn.valToValue(rd.txn, &heap, f)).asFloat());

    const i = (try valFrom(&rd, arena, .instant, value.fromFixnum(1_700_000_000_000).?)).?;
    try testing.expectEqual(@as(i64, 1_700_000_000_000), i.instant);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), (try conn.valToValue(rd.txn, &heap, i)).asFixnum());

    const k = (try valFrom(&rd, arena, .keyword, kw_string)).?;
    try testing.expectEqual(@as(u32, boot.type_string), k.keyword);
    try testing.expectEqual(kw_string.asKeywordId(), (try conn.valToValue(rd.txn, &heap, k)).asKeywordId());

    const r = (try valFrom(&rd, arena, .ref, value.fromFixnum(boot.doc).?)).?;
    try testing.expectEqual(@as(u64, boot.doc), r.ref);
    try testing.expectEqual(@as(i64, boot.doc), (try conn.valToValue(rd.txn, &heap, r)).asFixnum());
    try testing.expectEqual(@as(u64, boot.doc), (try valFrom(&rd, arena, .ref, kw_doc)).?.ref);
    try testing.expectEqual(@as(u64, boot.doc), (try valFrom(&rd, arena, .ref, lookup)).?.ref);

    const s = (try valFrom(&rd, arena, .string, try string_mod.fromBytes(&heap, "héllo"))).?;
    try testing.expectEqualStrings("héllo", s.string);
    try testing.expectEqualStrings("héllo", string_mod.asBytes(try conn.valToValue(rd.txn, &heap, s)));

    const u = (try valFrom(&rd, arena, .uuid, uuid_text)).?;
    try testing.expectEqual(@as(u8, 0x01), u.uuid[0]);
    try testing.expectEqualStrings("0123abcd-4567-89ef-0123-456789abcdef", string_mod.asBytes(try conn.valToValue(rd.txn, &heap, u)));

    const by = (try valFrom(&rd, arena, .bytes, try string_mod.fromBytes(&heap, "\x00\x01"))).?;
    try testing.expectEqualStrings("\x00\x01", by.bytes);
    try testing.expectEqualStrings("\x00\x01", string_mod.asBytes(try conn.valToValue(rd.txn, &heap, by)));

    // Names that resolve to nothing match nothing.
    const kw_none = try tc.interner.internKeywordValue("nope/nope");
    try testing.expect((try valFrom(&rd, arena, .keyword, kw_none)) == null);
    try testing.expect((try valFrom(&rd, arena, .ref, kw_none)) == null);

    // Kind mismatches are `:nextomic/value-type` for every type.
    const wrong = try string_mod.fromBytes(&heap, "x");
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .boolean, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .long, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .double, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .instant, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .keyword, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .ref, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .string, value.fromFixnum(1).?));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .uuid, wrong));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .bytes, value.fromFixnum(1).?));
    try testing.expectError(error.ValueType, valFrom(&rd, arena, .double, value.fromFloat(std.math.nan(f64))));

    // Entity references.
    try testing.expectEqual(@as(?u64, boot.doc), try entityRef(&rd, arena, kw_doc));
    try testing.expect((try entityRef(&rd, arena, kw_none)) == null);
    try testing.expectError(error.NoEntity, entityRef(&rd, arena, value.fromFixnum(0).?));
    try testing.expectError(error.KindMismatch, entityRef(&rd, arena, wrong));
    const bad_lookup = try vector_mod.fromSlice(&heap, &.{ kw_doc, wrong });
    try testing.expectError(error.TxData, entityRef(&rd, arena, bad_lookup));
    try testing.expectError(error.UnknownAttribute, attrId(&rd, kw_none));
}
