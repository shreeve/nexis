//! natives.zig — the `nextomic` namespace (NEXTOMIC.md §6, §7).
//!
//! Every native opens what it needs for its own duration: a
//! transaction, an arena for the storage layer's scratch, and copies
//! only results into the VM heap. Marshalling runs both ways here:
//! Lisp values become `key.Val` by the attribute's `:db/valueType`
//! (integer in i64 → long or instant, double → double, keyword → ident id,
//! eid/ident/lookup ref → ref, string → string, uuid or bytes text →
//! their storage form, boolean → boolean) and datom values come back
//! through `Conn.valToValue`.
//!
//! Errors: every `nextomic.Error` and storage error becomes a keyword
//! thrown through `VM.throwKeyword`, catchable by `try`. Wrong-kind
//! arguments are `KindMismatch`, as for every other native.
//!
//! A lazy entity (`entity`) is a `nextomic_entity` box over the
//! db-value and the eid; `entityLookup`, `entityHas` and `entityMap`
//! are its access paths, called from `vm.lookup` through the hook the
//! box carries and from the `stdlib` arms for `contains?`, `keys`,
//! `vals`, `seq`, `count` and `into`. Each opens one read at the
//! entity's basis and mode, as every other native does.
//!
//! Connection lifetime: `connect` registers the `Conn` on
//! `vm.nextomic_connections`; `release` closes it (idempotent, and
//! `:nextomic/busy` while an operation on it is in flight) and leaves
//! the struct allocated so db-values still pointing at it raise
//! `:nextomic/closed`; VM teardown destroys every connection through
//! `closeCallback`.
//!
//! Per-VM state (`State`): the parsed-query caches, whose query values
//! a var in `nexis.internal` keeps reachable, and the view of every
//! finished `with` scope, created on first use and destroyed at VM
//! teardown through `vm.nextomic_query_close`. A view outlives its
//! scope the way a released connection's struct does, so a db-value
//! that escaped the scope answers `:nextomic/closed`; the scope's
//! scratch is freed when the native returns.

const std = @import("std");
const value = @import("../value.zig");
const vm_mod = @import("../vm.zig");
const heap_mod = @import("../heap.zig");
const bignum = @import("../bignum.zig");
const gc = @import("../gc.zig");
const string_mod = @import("../string.zig");
const list_mod = @import("../coll/list.zig");
const vector_mod = @import("../coll/vector.zig");
const champ = @import("../coll/champ.zig");
const dispatch = @import("../dispatch.zig");
const dblayer = @import("../db.zig");
const emdb = @import("emdb");
const handle = @import("handle.zig");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const store_mod = @import("store.zig");
const schema_mod = @import("schema.zig");
const db_mod = @import("db.zig");
const transact_mod = @import("transact.zig");
const pull_mod = @import("pull.zig");
const query = @import("query.zig");
const query_natives = @import("query/natives.zig");
const marshal = @import("marshal.zig");

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
const Fault = db_mod.Fault;
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
    .{ .name = "excise!", .descriptor = &native_excise },
    .{ .name = "entity", .descriptor = &native_entity },
    .{ .name = "touch", .descriptor = &native_touch },
    .{ .name = "entity-db", .descriptor = &native_entity_db },
    .{ .name = "entid", .descriptor = &native_entid },
    .{ .name = "ident", .descriptor = &native_ident },
    .{ .name = "datoms", .descriptor = &native_datoms },
    .{ .name = "index-range", .descriptor = &native_index_range },
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
const native_excise = NativeFn{ .name = "nextomic/excise!", .min_arity = 2, .max_arity = 3, .call = &fnExcise };
const native_entity = NativeFn{ .name = "nextomic/entity", .min_arity = 2, .max_arity = 2, .call = &fnEntity };
const native_touch = NativeFn{ .name = "nextomic/touch", .min_arity = 1, .max_arity = 1, .call = &fnTouch };
const native_entity_db = NativeFn{ .name = "nextomic/entity-db", .min_arity = 1, .max_arity = 1, .call = &fnEntityDb };
const native_entid = NativeFn{ .name = "nextomic/entid", .min_arity = 2, .max_arity = 2, .call = &fnEntid };
const native_ident = NativeFn{ .name = "nextomic/ident", .min_arity = 2, .max_arity = 2, .call = &fnIdent };
const native_datoms = NativeFn{ .name = "nextomic/datoms", .min_arity = 2, .max_arity = 7, .call = &fnDatoms };
const native_index_range = NativeFn{ .name = "nextomic/index-range", .min_arity = 4, .max_arity = 4, .call = &fnIndexRange };
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
    /// The views of finished `with` scopes: closed, kept allocated for
    /// the db-values that name them, destroyed at VM teardown.
    views: std.ArrayList(*Conn) = .empty,
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
    vm.nextomic_query_mark = &markState;
    return s;
}

/// The caches' query values are roots of the VM's own walk (GC.md §3),
/// out of reach of anything a program can rebind.
fn markState(ptr: *anyopaque, c: *gc.Collector) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    s.ir_cache.mark(c);
    s.rules_cache.mark(c);
}

fn closeState(ptr: *anyopaque) void {
    const s: *State = @ptrCast(@alignCast(ptr));
    for (s.views.items) |view| view.destroy();
    s.views.deinit(s.gpa);
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
        error.TxFn => "nextomic/tx-fn",
        error.Cas => "nextomic/cas",
        error.Schema => "nextomic/schema",
        error.PullSyntax => "nextomic/pull-syntax",
        error.QuerySyntax => "nextomic/query-syntax",
        error.UnboundPattern => "nextomic/unbound-pattern",
        error.HistoryView => "nextomic/history-view",
        error.Format, error.UnknownIdent => "db/corrupted",
        error.StackOverflow => "stack-overflow",
        else => dblayer.failureName(err),
    };
}

/// What an error payload carries beyond its `:error` keyword (§7).
pub const Detail = struct {
    message: ?[]const u8 = null,
    clause: ?usize = null,
    attr: ?Value = null,
    value: ?Value = null,
    e: ?u64 = null,
    /// `:expected` and `:actual` of a failed `:db.fn/cas`; nil is a
    /// value here, meaning the attribute has none.
    cas: ?struct { expected: Value, actual: Value } = null,

    fn empty(self: Detail) bool {
        return self.message == null and self.clause == null and self.attr == null and self.value == null and self.e == null and self.cas == null;
    }
};

/// Surface `err` to the program. VM errors pass through unchanged;
/// everything else is thrown as its keyword, or as the map `{:error
/// keyword ...}` carrying `detail` when there is any.
pub fn fail(vm: *VM, err: anyerror) VmError {
    return failWith(vm, err, .{});
}

pub fn failWith(vm: *VM, err: anyerror, detail: Detail) VmError {
    inline for (@typeInfo(VmError).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return @field(VmError, e.name);
    }
    const name = errorKeyword(err);
    if (detail.empty()) return vm.throwKeyword(name);
    // A conflict names its datom as `:e` and `:a`.
    const attr_key: []const u8 = if (err == error.Conflict) "a" else "attr";
    const payload = payloadMap(vm, name, detail, attr_key) catch return VmError.OutOfMemory;
    return vm.throwValue(payload);
}

/// Throw the map a syntax error travels as: `{:error name :message
/// message :clause clause}`, `:clause` present when given.
pub fn throwSyntax(vm: *VM, name: []const u8, message: []const u8, clause: ?usize) VmError {
    const payload = payloadMap(vm, name, .{ .message = message, .clause = clause }, "attr") catch return VmError.OutOfMemory;
    return vm.throwValue(payload);
}

fn payloadMap(vm: *VM, name: []const u8, detail: Detail, attr_key: []const u8) !Value {
    const heap = vm.ensureHeap();
    const it = vm.ensureInterner();
    var m = try champ.mapEmpty(heap);
    m = try champ.mapAssoc(heap, m, try it.internKeywordValue("error"), try it.internKeywordValue(name), &dispatch.hashValue, &dispatch.equal);
    if (detail.message) |message| {
        m = try champ.mapAssoc(heap, m, try it.internKeywordValue("message"), try string_mod.fromBytes(heap, message), &dispatch.hashValue, &dispatch.equal);
    }
    if (detail.clause) |c| {
        const n = value.fromFixnum(@intCast(c)) orelse return error.ArithmeticOverflow;
        m = try champ.mapAssoc(heap, m, try it.internKeywordValue("clause"), n, &dispatch.hashValue, &dispatch.equal);
    }
    if (detail.e) |e| {
        const n = value.fromFixnum(@intCast(e)) orelse return error.ArithmeticOverflow;
        m = try champ.mapAssoc(heap, m, try it.internKeywordValue("e"), n, &dispatch.hashValue, &dispatch.equal);
    }
    if (detail.attr) |a| m = try champ.mapAssoc(heap, m, try it.internKeywordValue(attr_key), a, &dispatch.hashValue, &dispatch.equal);
    if (detail.value) |v| m = try champ.mapAssoc(heap, m, try it.internKeywordValue("value"), v, &dispatch.hashValue, &dispatch.equal);
    if (detail.cas) |c| {
        m = try champ.mapAssoc(heap, m, try it.internKeywordValue("expected"), c.expected, &dispatch.hashValue, &dispatch.equal);
        m = try champ.mapAssoc(heap, m, try it.internKeywordValue("actual"), c.actual, &dispatch.hashValue, &dispatch.equal);
    }
    return m;
}

/// The detail a failed transaction on `conn` left in `fault`. A
/// value the connection can no longer render (its keyword was minted
/// by the failed transaction) is left out.
fn detailOf(vm: *VM, conn: *Conn, fault: *const Fault) Detail {
    var d: Detail = .{ .message = fault.message, .attr = fault.attr, .e = fault.e };
    if (fault.value != null or fault.cas != null) {
        if (conn.store.beginRead()) |txn| {
            defer txn.abort();
            const heap = vm.ensureHeap();
            if (fault.value) |v| d.value = conn.valToValue(txn, heap, v) catch null;
            if (fault.cas) |c| d.cas = .{
                .expected = if (c.unseen) |k| k else if (c.expected) |v| conn.valToValue(txn, heap, v) catch value.nilValue() else value.nilValue(),
                .actual = if (c.actual) |v| conn.valToValue(txn, heap, v) catch value.nilValue() else value.nilValue(),
            };
        } else |_| {}
    }
    return d;
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

pub fn boxDb(heap: *Heap, d: DbValue) !Value {
    return handle.makeDb(heap, .{ .conn = @ptrCast(d.conn), .file = d.conn.file, .basis = d.basis, .as_of = d.as_of, .since = d.since, .history = d.history });
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

fn fixnum(n: u64) !Value {
    return value.fromFixnum(@intCast(n)) orelse error.ArithmeticOverflow;
}

// =============================================================================
// Marshalling: datoms → Lisp
// =============================================================================

/// One read of the db-value in `arg`, with a scratch arena and a value
/// builder: the prologue of a native that reads a view.
const Scope = struct {
    arena_state: std.heap.ArenaAllocator,
    db: DbValue,
    /// The db box `db` was read from: what a lazy entity made here holds.
    box: Value,
    rd: Read,
    b: Builder,

    fn open(vm: *VM, arg: Value) !Scope {
        const d = try dbOf(arg);
        const rd = try d.beginRead();
        return .{ .arena_state = std.heap.ArenaAllocator.init(vm.allocator), .db = d, .box = arg, .rd = rd, .b = Builder.init(vm, d.conn, rd.txn) };
    }

    fn close(self: *Scope) void {
        self.rd.close();
        self.arena_state.deinit();
    }

    fn arena(self: *Scope) Allocator {
        return self.arena_state.allocator();
    }
};

/// The `NativeFn.call` of a native that leaves a `Detail` on failure:
/// the detail travels with the error. The native renders its `Fault`
/// into the detail with `detailOf` before the memory the fault's value
/// lives in goes away.
fn wrap(comptime native: anytype) fn (*VM, []const Value) VmError!Value {
    return struct {
        fn call(vm: *VM, args: []const Value) VmError!Value {
            var detail: Detail = .{};
            return native(vm, args, &detail) catch |err| failWith(vm, err, detail);
        }
    }.call;
}

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

    fn attrKeyword(self: *Builder, a: u32) !Value {
        const k = (try self.conn.idents.internOf(self.txn, a)) orelse return error.Corrupted;
        return self.vm.ensureInterner().keywordValue(k);
    }

    fn val(self: *Builder, v: Val) !Value {
        return self.conn.valToValue(self.txn, self.heap, v);
    }

    /// `[e a v t added]`.
    fn datom(self: *Builder, d: Datom) !Value {
        const elems = [_]Value{
            try fixnum(d.e),
            try self.attrKeyword(d.a),
            try self.val(d.v),
            try fixnum(d.t),
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

const fnTransact = wrap(transactNative);

/// Runs `:db.fn/call` forms (NEXTOMIC.md §3 "Transaction functions"):
/// a symbol resolves as a query function does (`query/natives.zig`
/// `lookup`), and the function is called through `vm.callValue`
/// with the boxed `db-before` ahead of the form's arguments. Whatever it
/// throws propagates through the transaction, which aborts.
const TxHook = struct {
    vm: *VM,
    /// Roots the db-value each call receives and every tx-data a
    /// function returns for the transaction's life, so a nested call
    /// cannot collect them (docs/GC.md).
    scope: vm_mod.RootScope,

    fn init(vm: *VM) TxHook {
        return .{ .vm = vm, .scope = vm.rootScope() };
    }

    fn deinit(self: *TxHook) void {
        self.scope.release();
    }

    fn hook(self: *TxHook) transact_mod.CallHook {
        return .{ .ctx = @ptrCast(self), .call = &call };
    }

    fn call(ctx: *anyopaque, f: Value, db_before: DbValue, args: []const Value) anyerror!Value {
        const self: *TxHook = @ptrCast(@alignCast(ctx));
        const vm = self.vm;
        const callee = if (f.kind() == .symbol) (try query_natives.lookup(vm, f.asSymbolId())) orelse {
            const name = vm.ensureInterner().symbolName(f.asSymbolId());
            const message = try std.fmt.allocPrint(vm.allocator, "unknown function: {s}", .{name});
            defer vm.allocator.free(message);
            return throwSyntax(vm, "nextomic/tx-fn", message, null);
        } else f;
        const all = try vm.allocator.alloc(Value, args.len + 1);
        defer vm.allocator.free(all);
        all[0] = try boxDb(vm.ensureHeap(), db_before);
        try self.scope.push(all[0]);
        @memcpy(all[1..], args);
        const result = try vm.callValue(callee, all);
        try self.scope.push(result);
        return result;
    }
};

fn transactNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    const c = try openConn(args[0]);
    var fault: Fault = .{};
    var tx_hook = TxHook.init(vm);
    defer tx_hook.deinit();
    var options: transact_mod.Options = .{ .fault = &fault, .hook = tx_hook.hook() };
    if (args.len == 3) options.sync = try syncOption(vm, args[2]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    // The fault's value lives in the arena: rendered before the arena goes.
    errdefer detail.* = detailOf(vm, c, &fault);
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
        tempids = try b.put(tempids, k, try fixnum(t.eid));
    }

    var m = try champ.mapEmpty(b.heap);
    m = try b.putKw(m, "db-before", try boxDb(b.heap, report.db_before));
    m = try b.putKw(m, "db-after", try boxDb(b.heap, report.db_after));
    m = try b.putKw(m, "tx", try fixnum(report.t));
    m = try b.putKw(m, "tempids", tempids);
    m = try b.putKw(m, "tx-data", try b.datoms(arena, report.tx_data));
    return m;
}

// =============================================================================
// excise!
// =============================================================================

const fnExcise = wrap(exciseNative);

/// `(excise! conn e)` / `(excise! conn e attr)` (NEXTOMIC.md §4
/// "Excision"): the report of the recording transaction plus
/// `:excised [e]` and `:removed`, the history rows that went.
fn exciseNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    const c = try openConn(args[0]);
    var fault: Fault = .{};
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    errdefer detail.* = detailOf(vm, c, &fault);
    const arena = arena_state.allocator();
    const attr: ?Value = if (args.len == 3 and !args[2].isNil()) args[2] else null;
    const out = try transact_mod.excise(c, arena, args[1], attr, .{ .fault = &fault });
    var m = try reportMap(vm, c, arena, out.report);
    const heap = vm.ensureHeap();
    const it = vm.ensureInterner();
    m = try champ.mapAssoc(heap, m, try it.internKeywordValue("excised"), try vector_mod.fromSlice(heap, &.{try fixnum(out.excised)}), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(heap, m, try it.internKeywordValue("removed"), try fixnum(out.removed), &dispatch.hashValue, &dispatch.equal);
    return m;
}

// =============================================================================
// with
// =============================================================================

const fnWith = wrap(withNative);

/// `(with conn tx-data f)`: apply tx-data in a held write transaction,
/// call `f` with a db-value over the uncommitted state and the report
/// `transact!` would have returned, then abort. Whatever `f` raises
/// propagates after the abort. The view goes on the VM state, since
/// `db-after` and every db-value derived from it name it; the scope's
/// scratch is freed on return.
fn withNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    const c = try openConn(args[0]);
    const f = args[2];
    const st = try state(vm);
    try st.views.ensureUnusedCapacity(vm.allocator, 1);
    var fault: Fault = .{};
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    // The fault's value lives in the arena: rendered before the arena goes.
    errdefer detail.* = detailOf(vm, c, &fault);
    const arena = arena_state.allocator();
    var tx_hook = TxHook.init(vm);
    defer tx_hook.deinit();
    const w = try transact_mod.with(c, arena, args[1], .{ .fault = &fault, .hook = tx_hook.hook() });
    st.views.appendAssumeCapacity(w.view);
    defer w.finish();

    const report = try reportMap(vm, w.view, arena, w.report);
    const db_after = try boxDb(vm.ensureHeap(), w.db());
    return vm.callValue(f, &.{ db_after, report });
}

// =============================================================================
// pull, pull-many
// =============================================================================

fn fnPull(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return pullNative(vm, args, &diag) catch |err| failDiag(vm, err, &diag);
}

/// `(pull db pattern e)`: the pattern's map for `e`; nil when the
/// entity has no datoms in this view.
fn pullNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const d = try dbOf(args[0]);
    return pull_mod.pull(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), d, args[1], args[2], diag);
}

fn fnPullMany(vm: *VM, args: []const Value) VmError!Value {
    var diag: Diag = .{};
    return pullManyNative(vm, args, &diag) catch |err| failDiag(vm, err, &diag);
}

/// `(pull-many db pattern es)`: one result per entity of the vector
/// or list `es`, in its order, all in one read.
fn pullManyNative(vm: *VM, args: []const Value, diag: *Diag) !Value {
    const d = try dbOf(args[0]);
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const es = (try marshal.sequence(arena_state.allocator(), args[2])) orelse return error.KindMismatch;
    return pull_mod.pullMany(vm.allocator, vm.ensureInterner(), vm.ensureHeap(), d, args[1], es, diag);
}

/// A pattern or entity syntax error travels with its reason.
/// Surface an error of the query or pull pipeline with what `diag`
/// knows: the reason and clause of a syntax error, the attribute of an
/// unknown one, the reason and attribute of malformed input.
pub fn failDiag(vm: *VM, err: anyerror, diag: *const Diag) VmError {
    return switch (err) {
        error.QuerySyntax, error.PullSyntax => throwSyntax(vm, errorKeyword(err), diag.message, diag.clause),
        error.UnknownAttribute => failWith(vm, err, .{ .attr = diag.attr }),
        error.TxData => failWith(vm, err, .{ .message = if (diag.message.len == 0) null else diag.message, .attr = diag.attr }),
        else => fail(vm, err),
    };
}

// =============================================================================
// Reads
// =============================================================================

const fnEntity = wrap(entityNative);

/// `(entity db e)`: a lazy entity over this view; nil when the entity
/// has no datoms in it. One read resolves `e` (an eid, ident or lookup
/// ref) and confirms a datom exists; the attributes are read on
/// access. A history view has no entities (`HistoryView`).
fn entityNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    var sc = try Scope.open(vm, args[0]);
    defer sc.close();
    var fault: Fault = .{};
    errdefer detail.* = detailOf(vm, sc.db.conn, &fault);
    if (sc.db.history) return error.HistoryView;
    const arena = sc.arena();
    const e = (try marshal.entity(&sc.rd, arena, args[1], &fault)) orelse return value.nilValue();
    var it = try sc.rd.scan(arena, .eavt, .{ .e = e });
    if ((try it.next()) == null) return value.nilValue();
    return lazyEntity(vm, args[0], e);
}

fn lazyEntity(vm: *VM, db: Value, e: u64) !Value {
    return handle.makeEntity(vm.ensureHeap(), .{ .db = db, .eid = e, .vm = @ptrCast(vm), .read = &entityReadHook });
}

/// The hook an entity box carries: `vm.lookup`'s path to `entityLookup`.
fn entityReadHook(vm_ptr: *anyopaque, ent: Value, k: Value, default: Value) anyerror!Value {
    const vm: *VM = @ptrCast(@alignCast(vm_ptr));
    return entityLookup(vm, ent, k, default);
}

/// How a ref value comes back: as a lazy entity of the same view (an
/// access through the entity) or as its eid (`touch`).
const RefStyle = enum { entity, id };

/// A datom value as the entity presents it.
fn entityVal(sc: *Scope, v: Val, refs: RefStyle) !Value {
    if (refs == .entity and v == .ref) return lazyEntity(sc.b.vm, sc.box, v.ref);
    return sc.b.val(v);
}

/// The value of `attr` on `e` in the scope's view: card-many as a
/// set; null when the entity has no datom under it.
fn attrValue(sc: *Scope, e: u64, attr: Attr, refs: RefStyle) !?Value {
    var it = try sc.rd.scan(sc.arena(), .eavt, .{ .e = e, .a = attr.id });
    var many: ?Value = null;
    while (try it.next()) |dt| {
        const v = try entityVal(sc, dt.v, refs);
        if (!attr.many()) return v;
        const set = many orelse try champ.setEmpty(sc.b.heap);
        many = try champ.setConj(sc.b.heap, set, v, &dispatch.hashValue, &dispatch.equal);
    }
    return many;
}

/// `{:db/id e :attr v ...}` for `e` in the scope's view, card-many as
/// sets, refs by `refs`; null when the view holds no datom of `e`.
fn entityMapIn(sc: *Scope, e: u64, refs: RefStyle) !?Value {
    const b = &sc.b;
    var it = try sc.rd.scan(sc.arena(), .eavt, .{ .e = e });
    var m: ?Value = null;
    var cur_a: u32 = 0;
    var cur_attr: Attr = undefined;
    var many: ?Value = null;
    while (try it.next()) |dt| {
        if (m == null) m = try idOnly(b, e);
        if (many != null and dt.a != cur_a) {
            m = try b.put(m.?, try b.attrKeyword(cur_a), many.?);
            many = null;
        }
        if (many == null or dt.a != cur_a) {
            cur_a = dt.a;
            cur_attr = (try sc.rd.attr(dt.a)) orelse return error.Corrupted;
        }
        const v = try entityVal(sc, dt.v, refs);
        if (cur_attr.many()) {
            const set = many orelse try champ.setEmpty(b.heap);
            many = try champ.setConj(b.heap, set, v, &dispatch.hashValue, &dispatch.equal);
        } else {
            m = try b.put(m.?, try b.attrKeyword(dt.a), v);
        }
    }
    if (many) |set| m = try b.put(m.?, try b.attrKeyword(cur_a), set);
    return m;
}

/// `{:db/id e}`.
fn idOnly(b: *Builder, e: u64) !Value {
    return b.putKw(try champ.mapEmpty(b.heap), "db/id", try fixnum(e));
}

/// The db box of an entity argument.
fn entityArg(v: Value) !Value {
    if (v.kind() != .nextomic_entity) return error.KindMismatch;
    return handle.entityDb(v);
}

/// Is `k` the keyword `:db/id`?
fn isDbId(vm: *VM, k: Value) !bool {
    return k.kind() == .keyword and k.asKeywordId() == try vm.ensureInterner().internKeyword("db/id");
}

/// `(get ent k default)` and `(:k ent)`: `:db/id` is the eid and opens
/// nothing; any other keyword folds that attribute in one read, a ref
/// coming back as a lazy entity of the same view; an attribute the
/// entity lacks, an unknown attribute or a non-keyword key is the
/// default.
pub fn entityLookup(vm: *VM, ent: Value, k: Value, default: Value) VmError!Value {
    return entityGet(vm, ent, k, default) catch |err| fail(vm, err);
}

fn entityGet(vm: *VM, ent: Value, k: Value, default: Value) !Value {
    const box = try entityArg(ent);
    if (k.kind() != .keyword) return default;
    const e = handle.entityEid(ent);
    if (try isDbId(vm, k)) return fixnum(e);
    var sc = try Scope.open(vm, box);
    defer sc.close();
    var fault: Fault = .{};
    const attr = marshal.attrOf(&sc.rd, k, &fault) catch |err| switch (err) {
        error.UnknownAttribute => return default,
        else => return err,
    };
    return (try attrValue(&sc, e, attr, .entity)) orelse default;
}

/// `(contains? ent k)`: `:db/id` always; another keyword when the
/// entity has a datom under it in this view.
pub fn entityHas(vm: *VM, ent: Value, k: Value) VmError!bool {
    return entityHasNative(vm, ent, k) catch |err| fail(vm, err);
}

fn entityHasNative(vm: *VM, ent: Value, k: Value) !bool {
    const box = try entityArg(ent);
    if (k.kind() != .keyword) return false;
    if (try isDbId(vm, k)) return true;
    var sc = try Scope.open(vm, box);
    defer sc.close();
    var fault: Fault = .{};
    const attr = marshal.attrOf(&sc.rd, k, &fault) catch |err| switch (err) {
        error.UnknownAttribute => return false,
        else => return err,
    };
    var it = try sc.rd.scan(sc.arena(), .eavt, .{ .e = handle.entityEid(ent), .a = attr.id });
    return (try it.next()) != null;
}

/// `keys`, `vals`, `seq`, `count` and `into`: every attribute in one
/// read, refs as lazy entities of the same view; `{:db/id e}` alone
/// when the view holds no datom of `e`. The map is held on the box so
/// an iteration over it survives a collection.
pub fn entityMap(vm: *VM, ent: Value) VmError!Value {
    return entityMapNative(vm, ent) catch |err| fail(vm, err);
}

fn entityMapNative(vm: *VM, ent: Value) !Value {
    const box = try entityArg(ent);
    var sc = try Scope.open(vm, box);
    defer sc.close();
    const e = handle.entityEid(ent);
    const m = (try entityMapIn(&sc, e, .entity)) orelse try idOnly(&sc.b, e);
    handle.entityHold(ent, m);
    return m;
}

fn fnTouch(vm: *VM, args: []const Value) VmError!Value {
    return touchNative(vm, args) catch |err| fail(vm, err);
}

/// `(touch ent)`: the map `{:db/id e :attr v ...}` of every attribute
/// read in one pass, card-many as sets, refs as eids; `{:db/id e}`
/// alone when the view holds no datom of `e`.
fn touchNative(vm: *VM, args: []const Value) !Value {
    const box = try entityArg(args[0]);
    var sc = try Scope.open(vm, box);
    defer sc.close();
    const e = handle.entityEid(args[0]);
    return (try entityMapIn(&sc, e, .id)) orelse idOnly(&sc.b, e);
}

/// `(entity-db ent)`: the db-value the entity reads through.
fn fnEntityDb(_: *VM, args: []const Value) VmError!Value {
    return entityArg(args[0]) catch VmError.KindMismatch;
}

const fnEntid = wrap(entidNative);

fn entidNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    var sc = try Scope.open(vm, args[0]);
    defer sc.close();
    var fault: Fault = .{};
    errdefer detail.* = detailOf(vm, sc.db.conn, &fault);
    const e = (try marshal.entity(&sc.rd, sc.arena(), args[1], &fault)) orelse return value.nilValue();
    return fixnum(e);
}

fn fnIdent(vm: *VM, args: []const Value) VmError!Value {
    return identNative(vm, args) catch |err| fail(vm, err);
}

/// The ident keyword of an eid; a keyword answers itself when it is an
/// ident in this view. Nil otherwise.
fn identNative(vm: *VM, args: []const Value) !Value {
    var sc = try Scope.open(vm, args[0]);
    defer sc.close();
    const arena = sc.arena();
    const x = args[1];
    switch (x.kind()) {
        .fixnum => {
            const n = x.asFixnum();
            if (n <= 0 or n > @as(i64, @intCast(key.id_max))) return value.nilValue();
            const k = (try sc.rd.ident(arena, @intCast(n))) orelse return value.nilValue();
            return vm.ensureInterner().keywordValue(k);
        },
        .keyword => {
            if ((try sc.rd.entid(arena, .{ .ident = x.asKeywordId() })) == null) return value.nilValue();
            return x;
        },
        else => return error.KindMismatch,
    }
}

const fnDatoms = wrap(datomsNative);

/// `(datoms db index & components)`: the index's three components in
/// its order, then `tx` (a t or a transaction entity id) and `added`
/// (a boolean); nil leaves a position unbound, and a later one filters.
fn datomsNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    var sc = try Scope.open(vm, args[0]);
    defer sc.close();
    var fault: Fault = .{};
    errdefer detail.* = detailOf(vm, sc.db.conn, &fault);
    const index = try indexOf(vm, args[1]);
    const arena = sc.arena();
    const b = &sc.b;
    const empty = try vector_mod.fromSlice(b.heap, &.{});

    var comps: key.Components = .{};
    var attr: ?Attr = null;
    const positional: usize = @min(args.len - 2, 3);
    for (args[2 .. 2 + positional], index.order()[0..positional]) |arg, c| {
        if (arg.isNil()) continue;
        switch (c) {
            .e => comps.e = (try marshal.entity(&sc.rd, arena, arg, &fault)) orelse return empty,
            .a => {
                attr = try marshal.attrOf(&sc.rd, arg, &fault);
                comps.a = attr.?.id;
            },
            .v => {
                const val: Val = if (index == .vaet)
                    .{ .ref = (try marshal.entity(&sc.rd, arena, arg, &fault)) orelse return empty }
                else
                    (try marshal.valOf(&sc.rd, arena, (attr orelse return error.ValueType).value_type, arg, &fault)) orelse return empty;
                comps.v = try key.valBytes(arena, val);
            },
        }
    }
    const want_t: ?u64 = if (args.len > 5 and !args[5].isNil()) try txOf(args[5]) else null;
    const want_added: ?bool = if (args.len > 6 and !args[6].isNil()) (if (args[6].isBool()) args[6].asBool() else return error.KindMismatch) else null;

    var out: std.ArrayList(Value) = .empty;
    var it = try sc.rd.scan(arena, index, comps);
    while (try it.next()) |dt| {
        if (want_t) |t| if (dt.t != t) continue;
        if (want_added) |a| if (dt.added != a) continue;
        try out.append(arena, try b.datom(dt));
    }
    return vector_mod.fromSlice(b.heap, out.items);
}

/// A transaction as a program names it: its t or its entity id.
fn txOf(v: Value) !u64 {
    if (v.kind() != .fixnum or v.asFixnum() < 0) return error.KindMismatch;
    const n: u64 = @intCast(v.asFixnum());
    return key.txOfEntity(n) orelse n;
}

const fnIndexRange = wrap(indexRangeNative);

/// `(index-range db attr start end)`: the AVET datoms of an indexed or
/// unique attribute with `start <= v < end` in value order, either
/// bound open when nil. The cursor seeks to the encoded start and
/// stops at the encoded end; the range test is on decoded values, so
/// a long string or byte array is placed by its value even where the
/// index orders it by hash (§2.2), the seek window widening to the
/// whole 64-byte prefix class of such a bound (`rangeBound`).
fn indexRangeNative(vm: *VM, args: []const Value, detail: *Detail) !Value {
    var sc = try Scope.open(vm, args[0]);
    defer sc.close();
    var fault: Fault = .{};
    errdefer detail.* = detailOf(vm, sc.db.conn, &fault);
    const arena = sc.arena();
    const b = &sc.b;
    const attr = try marshal.attrOf(&sc.rd, args[1], &fault);
    if (!attr.inAvet()) {
        fault = .{ .message = "index-range reads an indexed or unique attribute", .attr = args[1] };
        return error.TxData;
    }
    const start: ?Val = if (args[2].isNil()) null else (try marshal.valOf(&sc.rd, arena, attr.value_type, args[2], &fault)) orelse return error.ValueType;
    const end: ?Val = if (args[3].isNil()) null else (try marshal.valOf(&sc.rd, arena, attr.value_type, args[3], &fault)) orelse return error.ValueType;

    var abuf: [key.attr_len]u8 = undefined;
    key.writeAttr(&abuf, attr.id);
    const lo: []const u8 = if (start) |v| try std.mem.concat(arena, u8, &.{ &abuf, try rangeBound(arena, v) }) else &abuf;
    const hi: ?[]const u8 = if (end) |v| blk: {
        const bound = try rangeBound(arena, v);
        const class = try std.mem.concat(arena, u8, &.{ &abuf, bound });
        // A bound widened to its prefix class admits the whole class.
        break :blk if (bound.len < (try key.valBytes(arena, v)).len) try key.successor(arena, class) else class;
    } else try key.successor(arena, &abuf);

    var hits: std.ArrayList(Datom) = .empty;
    var it = try sc.rd.scanRange(arena, .avet, lo, hi);
    while (try it.next()) |dt| {
        if (start) |v| if (dt.v.order(v) == .lt) continue;
        if (end) |v| if (dt.v.order(v) != .lt) continue;
        try hits.append(arena, dt);
    }
    // Index order is value order except among long values of one
    // prefix class; the result is in value order, then by entity.
    std.mem.sort(Datom, hits.items, {}, struct {
        fn lt(_: void, x: Datom, y: Datom) bool {
            return switch (x.v.order(y.v)) {
                .lt => true,
                .gt => false,
                .eq => x.e < y.e,
            };
        }
    }.lt);
    return b.datoms(arena, hits.items);
}

/// The index bytes a range bound seeks to: the value's encoding, or,
/// for a string or byte array of `prefix_len` bytes or more, the bytes
/// every value sharing its first `prefix_len` bytes starts with (the
/// tag and the escaped prefix). Such values order by hash among
/// themselves when one is out of line, so an in-range value may sit on
/// either side of the bound's own key; the class is scanned whole and
/// the range test on decoded values settles it.
fn rangeBound(arena: Allocator, v: Val) ![]const u8 {
    const enc = try key.valBytes(arena, v);
    const blob: []const u8 = switch (v) {
        .string => |s| s,
        .bytes => |x| x,
        else => return enc,
    };
    if (blob.len < key.prefix_len) return enc;
    return enc[0 .. 1 + key.escapedLen(blob[0..key.prefix_len]) - 1];
}

fn indexOf(vm: *VM, v: Value) !Index {
    if (v.kind() != .keyword) return error.KindMismatch;
    const name = vm.ensureInterner().keywordName(v.asKeywordId());
    return std.meta.stringToEnum(Index, name) orelse error.InvalidArgument;
}

// =============================================================================
// Time
// =============================================================================

/// A point in time: a `t`, or a transaction's entity id, which
/// stands for its `t`.
fn tArg(v: Value) !u64 {
    if (v.kind() != .fixnum) return error.KindMismatch;
    const n = v.asFixnum();
    if (n < 0) return error.InvalidArgument;
    const u: u64 = @intCast(n);
    return key.txOfEntity(u) orelse u;
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
        m = try b.putKw(m, "t", try fixnum(entry.t));
        m = try b.putKw(m, "instant", try bignum.fromI64(b.heap, entry.instant));
        m = try b.putKw(m, "data", try b.datoms(arena, entry.datoms));
        if (entry.excised.len > 0) {
            const ids = try arena.alloc(Value, entry.excised.len);
            for (ids, entry.excised) |*out_id, e| out_id.* = try fixnum(e);
            m = try b.putKw(m, "excised", try vector_mod.fromSlice(b.heap, ids));
        }
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

/// Ident → attribute map for every attribute this view sees: the
/// flags as the view's basis saw them (§4 "Schema as-of"), and the
/// attribute's `:db/doc` when the view holds one.
fn schemaNative(vm: *VM, args: []const Value) !Value {
    var sc = try Scope.open(vm, args[0]);
    defer sc.close();
    const arena = sc.arena();
    const b = &sc.b;
    const schema = try sc.rd.schema();
    const at = sc.db.upper();

    var out = try champ.mapEmpty(b.heap);
    var it = schema.attrs.iterator();
    while (it.next()) |entry| {
        const attr = schema.attrAt(entry.key_ptr.*, at) orelse continue;
        const ident = try b.attrKeyword(attr.id);
        var m = try champ.mapEmpty(b.heap);
        m = try b.putKw(m, "db/id", try fixnum(attr.id));
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
        m = try b.putKw(m, "db/fulltext", value.fromBool(attr.fulltext));
        var docs = try sc.rd.scan(arena, .eavt, .{ .e = attr.id, .a = boot.doc });
        if (try docs.next()) |d| m = try b.putKw(m, "db/doc", try b.val(d.v));
        out = try b.put(out, ident, m);
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const TestConn = db_mod.TestConn;

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
        .{ .err = error.TxFn, .name = "nextomic/tx-fn" },
        .{ .err = error.Cas, .name = "nextomic/cas" },
        .{ .err = error.Schema, .name = "nextomic/schema" },
        .{ .err = error.PullSyntax, .name = "nextomic/pull-syntax" },
        .{ .err = error.QuerySyntax, .name = "nextomic/query-syntax" },
        .{ .err = error.UnboundPattern, .name = "nextomic/unbound-pattern" },
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

test "a time argument is a t or the entity id of a transaction" {
    try testing.expectEqual(@as(u64, 7), try tArg(value.fromFixnum(7).?));
    try testing.expectEqual(@as(u64, 7), try tArg(value.fromFixnum(@intCast(key.txEntity(7))).?));
    try testing.expectEqual(@as(u64, 0), try tArg(value.fromFixnum(0).?));
    try testing.expectError(error.InvalidArgument, tArg(value.fromFixnum(-1).?));
    try testing.expectError(error.KindMismatch, tArg(value.nilValue()));
}
