// =============================================================================
// src/stdlib.zig — Phase 3.3 standard library installation
// =============================================================================
//
// Phase 3.3a (peer-AI turn 67): host-Zig functions exposed as
// first-class `Value`s of kind `.native_fn`. Each fn has a
// STATIC `NativeFn` descriptor (no heap allocation, immortal
// lifetime) and is installed as a Var in the user's namespace
// at VM startup.
//
// Phase 3.3a scope (intentionally narrow per peer-AI turn 67
// §D8 — bound first commit to non-reentrant primitives):
//   - sequence:   list, cons, first, rest, count, nth, empty?
//   - utility:    identity, nil?, some?
//
// NO higher-order fns (map/reduce/filter/apply) — those require
// `VM.callValue` reentrancy and ship in Phase 3.3b. NO arithmetic
// Vars (+, <, =) — also 3.3b. NO collection ops beyond list (no
// assoc/get/conj/etc.) — 3.3c.
//
// `nil`-as-empty-seq semantics (peer-AI turn 67 §D8 + §Sharp
// warnings §8) match Clojure:
//   (first nil)   => nil
//   (rest nil)    => ()
//   (count nil)   => 0
//   (empty? nil)  => true
//
// Native fns are visible to BOTH runtime AND compile-time macro
// eval, because the persistent-namespace design from Phase 3.2
// (peer-AI turn 66) means `routine.var_table` resolves to the
// SAME Var pointer regardless of which VM evaluates it.

const std = @import("std");
const value_mod = @import("value");
const vm_mod = @import("vm");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const intern_mod = @import("intern");
const db_mod = @import("db");
const codec_mod = @import("codec");
const heap_mod = @import("heap");
const dispatch_mod_alias = @import("dispatch");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const VM = vm_mod.VM;
const NativeFn = vm_mod.NativeFn;
const Namespace = vm_mod.Namespace;
const VmError = vm_mod.VmError;

// =============================================================================
// Installation
// =============================================================================

/// Phase 3.3a (peer-AI turn 67 §D2): install core native fns
/// into `ns`. Idempotent: re-installing replaces the root
/// without disturbing the Var's `.macro` flag. Callers
/// typically invoke this ONCE at VM startup (REPL, file runner,
/// test harness).
///
/// Native fn NAMES are string literals (`.rodata`, immortal),
/// so the Namespace's existing `intern(name)` overload (which
/// borrows the name slice into the Var) is safe — no separate
/// name allocator needed.
pub fn installCore(ns: *Namespace) !void {
    for (core_fns) |entry| {
        const v = try ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
        // Native fns are NOT macros (Var.macro stays false).
    }
}

/// Phase 4.0a: install db primitives into the `db` namespace
/// so `(db/open path)` resolves through the registry's
/// qualified-symbol path. CLI calls this AFTER `installCore`
/// + after the registry has a "db" namespace registered.
pub fn installDb(db_ns: *Namespace) !void {
    for (db_fns) |entry| {
        const v = try db_ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
    }
}

const db_fns = [_]CoreEntry{
    // 4.0a connection + ref + auto-ephemeral primitives.
    .{ .name = "open", .descriptor = &native_db_open },
    .{ .name = "close", .descriptor = &native_db_close },
    .{ .name = "ref", .descriptor = &native_db_ref },
    .{ .name = "ref?", .descriptor = &native_db_ref_q },
    .{ .name = "put-key!", .descriptor = &native_db_put_key },
    .{ .name = "get-key", .descriptor = &native_db_get_key },
    .{ .name = "delete-key!", .descriptor = &native_db_delete_key },
    .{ .name = "present?", .descriptor = &native_db_present_q },
    // 4.0b explicit-tx primitives.
    .{ .name = "begin-write", .descriptor = &native_db_begin_write },
    .{ .name = "begin-read", .descriptor = &native_db_begin_read },
    .{ .name = "commit!", .descriptor = &native_db_commit },
    .{ .name = "abort-write!", .descriptor = &native_db_abort_write },
    .{ .name = "abort-read!", .descriptor = &native_db_abort_read },
    .{ .name = "put!", .descriptor = &native_db_put },
    .{ .name = "get", .descriptor = &native_db_get },
    .{ .name = "delete!", .descriptor = &native_db_delete },
    // 4.0c
    .{ .name = "deref", .descriptor = &native_db_deref },
    .{ .name = "alter!", .descriptor = &native_db_alter },
};

/// Phase 3.3d (peer-AI turn 67 §D5 + §3.3d): composite stdlib
/// layer written in nexis itself, embedded at compile time.
/// CLI / test harnesses compile + evaluate this AFTER calling
/// `installCore` so the composite definitions can use the
/// native primitives.
///
/// Lives in `src/stdlib/core.nx`. Add new macros/fns there,
/// not here — keeping the composite layer in nexis source
/// matches CLOJURE-REVIEW.md §1.1 two-stage bootstrap.
pub const CORE_NX_SOURCE: []const u8 = @embedFile("stdlib/core.nx");

const CoreEntry = struct {
    name: []const u8,
    descriptor: *const NativeFn,
};

const core_fns = [_]CoreEntry{
    // 3.3a sequence primitives.
    .{ .name = "list", .descriptor = &native_list },
    .{ .name = "cons", .descriptor = &native_cons },
    .{ .name = "first", .descriptor = &native_first },
    .{ .name = "rest", .descriptor = &native_rest },
    .{ .name = "count", .descriptor = &native_count },
    .{ .name = "nth", .descriptor = &native_nth },
    .{ .name = "empty?", .descriptor = &native_empty_q },
    .{ .name = "identity", .descriptor = &native_identity },
    .{ .name = "nil?", .descriptor = &native_nil_q },
    .{ .name = "some?", .descriptor = &native_some_q },
    // 3.3b first-class arithmetic + comparison Vars.
    // Required so `(reduce + 0 xs)` resolves `+` as a Var
    // (the inlining of `(+ x y)` at the call head continues
    // to work — known limitation per peer-AI turn 67 §Sharp
    // warning §2).
    .{ .name = "+", .descriptor = &native_add },
    .{ .name = "-", .descriptor = &native_sub },
    .{ .name = "*", .descriptor = &native_mul },
    .{ .name = "<", .descriptor = &native_lt },
    .{ .name = "=", .descriptor = &native_eq },
    .{ .name = "inc", .descriptor = &native_inc },
    .{ .name = "dec", .descriptor = &native_dec },
    .{ .name = "not", .descriptor = &native_not },
    .{ .name = "zero?", .descriptor = &native_zero_q },
    .{ .name = "pos?", .descriptor = &native_pos_q },
    .{ .name = "neg?", .descriptor = &native_neg_q },
    .{ .name = "odd?", .descriptor = &native_odd_q },
    .{ .name = "even?", .descriptor = &native_even_q },
    // 3.3b apply + HOFs.
    .{ .name = "apply", .descriptor = &native_apply },
    .{ .name = "map", .descriptor = &native_map },
    .{ .name = "reduce", .descriptor = &native_reduce },
    .{ .name = "filter", .descriptor = &native_filter },
    // 3.3c collection construction + access.
    .{ .name = "vector", .descriptor = &native_vector },
    .{ .name = "vec", .descriptor = &native_vec },
    .{ .name = "hash-map", .descriptor = &native_hash_map },
    .{ .name = "hash-set", .descriptor = &native_hash_set },
    .{ .name = "assoc", .descriptor = &native_assoc },
    .{ .name = "dissoc", .descriptor = &native_dissoc },
    .{ .name = "get", .descriptor = &native_get },
    .{ .name = "contains?", .descriptor = &native_contains_q },
    .{ .name = "keys", .descriptor = &native_keys },
    .{ .name = "vals", .descriptor = &native_vals },
    .{ .name = "conj", .descriptor = &native_conj },
    // Phase 4.0a: db primitives live in the `db` namespace
    // (installed separately via `installDb`) so they appear as
    // qualified `(db/open ...)` calls.
};

// =============================================================================
// Static descriptors
// =============================================================================

const native_list = NativeFn{
    .name = "list",
    .min_arity = 0,
    .max_arity = null,
    .call = &fnList,
};

const native_cons = NativeFn{
    .name = "cons",
    .min_arity = 2,
    .max_arity = 2,
    .call = &fnCons,
};

const native_first = NativeFn{
    .name = "first",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnFirst,
};

const native_rest = NativeFn{
    .name = "rest",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnRest,
};

const native_count = NativeFn{
    .name = "count",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnCount,
};

const native_nth = NativeFn{
    .name = "nth",
    .min_arity = 2,
    .max_arity = 3,
    .call = &fnNth,
};

const native_empty_q = NativeFn{
    .name = "empty?",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnEmptyQ,
};

const native_identity = NativeFn{
    .name = "identity",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnIdentity,
};

const native_nil_q = NativeFn{
    .name = "nil?",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnNilQ,
};

const native_some_q = NativeFn{
    .name = "some?",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnSomeQ,
};

// 3.3b arithmetic + comparison.
const native_add = NativeFn{ .name = "+", .min_arity = 0, .max_arity = null, .call = &fnAdd };
const native_sub = NativeFn{ .name = "-", .min_arity = 1, .max_arity = null, .call = &fnSub };
const native_mul = NativeFn{ .name = "*", .min_arity = 0, .max_arity = null, .call = &fnMul };
const native_lt = NativeFn{ .name = "<", .min_arity = 0, .max_arity = null, .call = &fnLt };
const native_eq = NativeFn{ .name = "=", .min_arity = 0, .max_arity = null, .call = &fnEq };
const native_inc = NativeFn{ .name = "inc", .min_arity = 1, .max_arity = 1, .call = &fnInc };
const native_dec = NativeFn{ .name = "dec", .min_arity = 1, .max_arity = 1, .call = &fnDec };
const native_not = NativeFn{ .name = "not", .min_arity = 1, .max_arity = 1, .call = &fnNot };
const native_zero_q = NativeFn{ .name = "zero?", .min_arity = 1, .max_arity = 1, .call = &fnZeroQ };
const native_pos_q = NativeFn{ .name = "pos?", .min_arity = 1, .max_arity = 1, .call = &fnPosQ };
const native_neg_q = NativeFn{ .name = "neg?", .min_arity = 1, .max_arity = 1, .call = &fnNegQ };
const native_odd_q = NativeFn{ .name = "odd?", .min_arity = 1, .max_arity = 1, .call = &fnOddQ };
const native_even_q = NativeFn{ .name = "even?", .min_arity = 1, .max_arity = 1, .call = &fnEvenQ };

// 3.3b apply + HOFs.
const native_apply = NativeFn{ .name = "apply", .min_arity = 2, .max_arity = null, .call = &fnApply };
const native_map = NativeFn{ .name = "map", .min_arity = 2, .max_arity = 2, .call = &fnMap };
const native_reduce = NativeFn{ .name = "reduce", .min_arity = 3, .max_arity = 3, .call = &fnReduce };
const native_filter = NativeFn{ .name = "filter", .min_arity = 2, .max_arity = 2, .call = &fnFilter };

// 3.3c collection utilities.
const native_vector = NativeFn{ .name = "vector", .min_arity = 0, .max_arity = null, .call = &fnVector };
const native_vec = NativeFn{ .name = "vec", .min_arity = 1, .max_arity = 1, .call = &fnVec };
const native_hash_map = NativeFn{ .name = "hash-map", .min_arity = 0, .max_arity = null, .call = &fnHashMap };
const native_hash_set = NativeFn{ .name = "hash-set", .min_arity = 0, .max_arity = null, .call = &fnHashSet };
const native_assoc = NativeFn{ .name = "assoc", .min_arity = 3, .max_arity = 3, .call = &fnAssoc };
const native_dissoc = NativeFn{ .name = "dissoc", .min_arity = 2, .max_arity = 2, .call = &fnDissoc };
const native_get = NativeFn{ .name = "get", .min_arity = 2, .max_arity = 3, .call = &fnGet };
const native_contains_q = NativeFn{ .name = "contains?", .min_arity = 2, .max_arity = 2, .call = &fnContainsQ };
const native_keys = NativeFn{ .name = "keys", .min_arity = 1, .max_arity = 1, .call = &fnKeys };
const native_vals = NativeFn{ .name = "vals", .min_arity = 1, .max_arity = 1, .call = &fnVals };
const native_conj = NativeFn{ .name = "conj", .min_arity = 1, .max_arity = null, .call = &fnConj };

// Phase 4.0a db primitives.
const native_db_open = NativeFn{ .name = "db/open", .min_arity = 1, .max_arity = 1, .call = &fnDbOpen };
const native_db_close = NativeFn{ .name = "db/close", .min_arity = 1, .max_arity = 1, .call = &fnDbClose };
const native_db_ref = NativeFn{ .name = "db/ref", .min_arity = 3, .max_arity = 3, .call = &fnDbRef };
const native_db_ref_q = NativeFn{ .name = "db/ref?", .min_arity = 1, .max_arity = 1, .call = &fnDbRefQ };
const native_db_put_key = NativeFn{ .name = "db/put-key!", .min_arity = 2, .max_arity = 2, .call = &fnDbPutKey };
const native_db_get_key = NativeFn{ .name = "db/get-key", .min_arity = 1, .max_arity = 2, .call = &fnDbGetKey };
const native_db_delete_key = NativeFn{ .name = "db/delete-key!", .min_arity = 1, .max_arity = 1, .call = &fnDbDeleteKey };
const native_db_present_q = NativeFn{ .name = "db/present?", .min_arity = 1, .max_arity = 1, .call = &fnDbPresentQ };
// Phase 4.0b explicit tx primitives.
const native_db_begin_write = NativeFn{ .name = "db/begin-write", .min_arity = 1, .max_arity = 1, .call = &fnDbBeginWrite };
const native_db_begin_read = NativeFn{ .name = "db/begin-read", .min_arity = 1, .max_arity = 1, .call = &fnDbBeginRead };
const native_db_commit = NativeFn{ .name = "db/commit!", .min_arity = 1, .max_arity = 1, .call = &fnDbCommit };
const native_db_abort_write = NativeFn{ .name = "db/abort-write!", .min_arity = 1, .max_arity = 1, .call = &fnDbAbortWrite };
const native_db_abort_read = NativeFn{ .name = "db/abort-read!", .min_arity = 1, .max_arity = 1, .call = &fnDbAbortRead };
const native_db_put = NativeFn{ .name = "db/put!", .min_arity = 3, .max_arity = 3, .call = &fnDbPut };
const native_db_get = NativeFn{ .name = "db/get", .min_arity = 2, .max_arity = 3, .call = &fnDbGet };
const native_db_delete = NativeFn{ .name = "db/delete!", .min_arity = 2, .max_arity = 2, .call = &fnDbDelete };
// Phase 4.0c — deref + alter.
const native_db_deref = NativeFn{ .name = "db/deref", .min_arity = 1, .max_arity = 1, .call = &fnDbDeref };
const native_db_alter = NativeFn{ .name = "db/alter!", .min_arity = 3, .max_arity = null, .call = &fnDbAlter };

// =============================================================================
// Implementations
// =============================================================================

/// `(list & xs)` → fresh cons list of the args (left-to-right).
/// `(list)` is the empty list. GC TODO: root partial result.
fn fnList(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        result = list_mod.cons(heap, args[i], result) catch return VmError.OutOfMemory;
    }
    return result;
}

/// `(cons x s)` → new cons cell with `x` as head and `s` as
/// tail. `s` may be nil (treated as empty), a list, or
/// (Phase 3.3b+) any seqable collection. v1 accepts nil and
/// lists; other kinds are a `KindMismatch`.
fn fnCons(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    const tail_v = try coerceToList(vm, args[1]);
    const heap = vm.ensureHeap();
    return list_mod.cons(heap, x, tail_v) catch VmError.OutOfMemory;
}

/// `(first s)` → head of the seq, or nil if empty/nil.
fn fnFirst(_: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    return switch (s.kind()) {
        .nil => value_mod.nilValue(),
        .list => if (list_mod.isEmpty(s)) value_mod.nilValue() else list_mod.head(s),
        .persistent_vector => if (vector_mod.isEmpty(s)) value_mod.nilValue() else vector_mod.nth(s, 0),
        else => VmError.KindMismatch,
    };
}

/// `(rest s)` → seq of everything after the first element.
/// Always returns a list (empty if input is empty/nil).
fn fnRest(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    const heap = vm.ensureHeap();
    return switch (s.kind()) {
        .nil => list_mod.empty(heap) catch VmError.OutOfMemory,
        .list => if (list_mod.isEmpty(s))
            list_mod.empty(heap) catch VmError.OutOfMemory
        else
            list_mod.tail(s),
        .persistent_vector => blk: {
            const n = vector_mod.count(s);
            if (n <= 1) {
                break :blk list_mod.empty(heap) catch VmError.OutOfMemory;
            }
            // Build a list from elements [1..n-1] in reverse so
            // cons threads correctly.
            var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
            var i: usize = n;
            while (i > 1) {
                i -= 1;
                result = list_mod.cons(heap, vector_mod.nth(s, i), result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        else => VmError.KindMismatch,
    };
}

/// `(count coll)` → element count. nil → 0. Lists, vectors,
/// maps, sets, strings supported.
fn fnCount(_: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    const n: i64 = switch (c.kind()) {
        .nil => 0,
        .list => @intCast(list_mod.count(c)),
        .persistent_vector => @intCast(vector_mod.count(c)),
        .persistent_map => @intCast(champ_mod.mapCount(c)),
        .persistent_set => @intCast(champ_mod.setCount(c)),
        else => return VmError.KindMismatch,
    };
    return value_mod.fromFixnum(n) orelse VmError.IntegerOverflow;
}

/// `(nth coll n)` → element at index `n`. Throws on out-of-
/// bounds. Negative indices rejected as `IndexOutOfBounds`.
///
/// `(nth coll n default)` → element at index `n`, or `default`
/// if out-of-bounds. nil coll always returns default. Required
/// by Phase 3.5 destructuring (peer-AI turn 70 §missing-trap
/// §9: `[a b c]` against a 2-element source should bind c to
/// nil, not throw).
fn fnNth(_: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const idx_v = args[1];
    const has_default = args.len > 2;
    const default = if (has_default) args[2] else value_mod.nilValue();
    if (idx_v.kind() != .fixnum) return VmError.KindMismatch;
    const idx = idx_v.asFixnum();
    if (idx < 0) {
        if (has_default) return default;
        return VmError.IndexOutOfBounds;
    }
    const u_idx: usize = @intCast(idx);
    return switch (coll.kind()) {
        .nil => if (has_default) default else VmError.IndexOutOfBounds,
        .list => blk: {
            if (u_idx >= list_mod.count(coll)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            var node = coll;
            var i: usize = 0;
            while (i < u_idx) : (i += 1) node = list_mod.tail(node);
            break :blk list_mod.head(node);
        },
        .persistent_vector => blk: {
            if (u_idx >= vector_mod.count(coll)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            break :blk vector_mod.nth(coll, u_idx);
        },
        else => return VmError.KindMismatch,
    };
}

/// `(empty? coll)` → true if coll has zero elements. nil →
/// true (matches Clojure).
fn fnEmptyQ(_: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    const is_empty = switch (c.kind()) {
        .nil => true,
        .list => list_mod.isEmpty(c),
        .persistent_vector => vector_mod.isEmpty(c),
        .persistent_map => champ_mod.mapCount(c) == 0,
        .persistent_set => champ_mod.setCount(c) == 0,
        else => return VmError.KindMismatch,
    };
    return value_mod.fromBool(is_empty);
}

/// `(identity x)` → x.
fn fnIdentity(_: *VM, args: []const Value) VmError!Value {
    return args[0];
}

/// `(nil? x)` → true iff x is nil.
fn fnNilQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .nil);
}

/// `(some? x)` → true iff x is NOT nil.
fn fnSomeQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() != .nil);
}

// =============================================================================
// Arithmetic + comparison (3.3b)
// =============================================================================
//
// Fixnum-only for v1, matching the inlined `math:add` /
// `cmp:lt` opcode paths. Float / bignum support is a Phase 4+
// numeric-tower expansion. Variadic semantics match Clojure:
//
//   (+)        => 0
//   (+ x)      => x  (must be numeric)
//   (+ x y...) => left-to-right sum
//   (<)        => true
//   (< x)      => true
//   (< x y z)  => chained
//
// Equality `(=)`:
//   (=)        => true
//   (= x)      => true
//   (= x y z)  => chained value-equality via dispatch.equal

const dispatch_mod = @import("dispatch");

fn requireFixnum(v: Value) VmError!i64 {
    if (v.kind() != .fixnum) return VmError.KindMismatch;
    return v.asFixnum();
}

fn fnAdd(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return value_mod.fromFixnum(0).?;
    var acc = try requireFixnum(args[0]);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = try requireFixnum(args[i]);
        const sum = std.math.add(i64, acc, x) catch return VmError.IntegerOverflow;
        acc = sum;
    }
    return value_mod.fromFixnum(acc) orelse VmError.IntegerOverflow;
}

fn fnSub(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) {
        // Unary negation.
        const x = try requireFixnum(args[0]);
        const neg = std.math.negate(x) catch return VmError.IntegerOverflow;
        return value_mod.fromFixnum(neg) orelse VmError.IntegerOverflow;
    }
    var acc = try requireFixnum(args[0]);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = try requireFixnum(args[i]);
        const diff = std.math.sub(i64, acc, x) catch return VmError.IntegerOverflow;
        acc = diff;
    }
    return value_mod.fromFixnum(acc) orelse VmError.IntegerOverflow;
}

fn fnMul(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return value_mod.fromFixnum(1).?;
    var acc = try requireFixnum(args[0]);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = try requireFixnum(args[i]);
        const prod = std.math.mul(i64, acc, x) catch return VmError.IntegerOverflow;
        acc = prod;
    }
    return value_mod.fromFixnum(acc) orelse VmError.IntegerOverflow;
}

fn fnLt(_: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return value_mod.fromBool(true);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        const a = try requireFixnum(args[i]);
        const b = try requireFixnum(args[i + 1]);
        if (!(a < b)) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

fn fnEq(_: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return value_mod.fromBool(true);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!dispatch_mod.equal(args[i], args[i + 1])) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

fn fnInc(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    const r = std.math.add(i64, x, 1) catch return VmError.IntegerOverflow;
    return value_mod.fromFixnum(r) orelse VmError.IntegerOverflow;
}

fn fnDec(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    const r = std.math.sub(i64, x, 1) catch return VmError.IntegerOverflow;
    return value_mod.fromFixnum(r) orelse VmError.IntegerOverflow;
}

fn fnNot(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(!args[0].isTruthy());
}

fn fnZeroQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(x == 0);
}

fn fnPosQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(x > 0);
}

fn fnNegQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(x < 0);
}

fn fnOddQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(@mod(x, 2) != 0);
}

fn fnEvenQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(@mod(x, 2) == 0);
}

// =============================================================================
// apply + HOFs (3.3b)
// =============================================================================
//
// `apply` + `map` / `reduce` / `filter` are the FIRST users of
// `VM.callValue` (peer-AI turn 68). They MUST propagate
// `VmError.ControlTransferred` unchanged so throws from inside
// user fns escape to the outer handler correctly.

/// `(apply f x1 x2 ... xs)` calls `f` with the elements of
/// the last arg seq spliced in after the leading args.
fn fnApply(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const last = args[args.len - 1];

    // Materialize the final arg list.
    var combined: std.ArrayList(Value) = .empty;
    defer combined.deinit(vm.allocator);
    // Leading args (between f and the seq).
    var i: usize = 1;
    while (i < args.len - 1) : (i += 1) {
        combined.append(vm.allocator, args[i]) catch return VmError.OutOfMemory;
    }
    // Walk `last` as a seq.
    try appendSeqValues(vm, last, &combined);

    return try vm.callValue(f, combined.items);
}

/// `(map f coll)` → eager cons list of `(f x)` for each x in
/// coll. Order-preserving. Throws inside `f` propagate via
/// `ControlTransferred`.
fn fnMap(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const coll = args[1];

    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);

    var it = try makeSeqIter(coll);
    while (it.next()) |x| {
        const one = [_]Value{x};
        const mapped = try vm.callValue(f, &one);
        results.append(vm.allocator, mapped) catch return VmError.OutOfMemory;
    }

    return try buildListFromSlice(vm, results.items);
}

/// `(reduce f init coll)` → left fold.
fn fnReduce(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    var acc = args[1];
    const coll = args[2];

    var it = try makeSeqIter(coll);
    while (it.next()) |x| {
        const pair = [_]Value{ acc, x };
        acc = try vm.callValue(f, &pair);
    }
    return acc;
}

/// `(filter pred coll)` → eager cons list of x where `(pred x)`
/// is truthy.
fn fnFilter(vm: *VM, args: []const Value) VmError!Value {
    const pred = args[0];
    const coll = args[1];

    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);

    var it = try makeSeqIter(coll);
    while (it.next()) |x| {
        const one = [_]Value{x};
        const keep = try vm.callValue(pred, &one);
        if (keep.isTruthy()) {
            results.append(vm.allocator, x) catch return VmError.OutOfMemory;
        }
    }
    return try buildListFromSlice(vm, results.items);
}

// =============================================================================
// Collection utilities (3.3c)
// =============================================================================
//
// Persistent collection construction + access. Per peer-AI
// turn 67 §D8 Group B:
//
//   vector       (& xs)     persistent vector from args
//   vec          (s)        persistent vector from seq
//   hash-map     (& kvs)    persistent map from k/v pairs
//   hash-set     (& xs)     persistent set from args
//   assoc        (m k v)    persistent put (map or vector)
//   dissoc       (m k)      persistent remove (map only)
//   get          (m k)      lookup (map/set/vector); nil if missing
//   get          (m k def)  lookup with default
//   contains?    (m k)      key/element presence check
//   keys         (m)        seq of map keys
//   vals         (m)        seq of map values
//   conj         (coll & xs) persistent add (list: cons; vector: push;
//                            map: assoc with [k v] pair; set: include)
//
// HAMT iteration order is unspecified (peer-AI turn 67 §Sharp
// warning §7). Tests using `keys`/`vals` should compare as
// sets, not by exact order.

fn fnVector(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    return vector_mod.fromSlice(heap, args) catch VmError.OutOfMemory;
}

fn fnVec(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    return switch (s.kind()) {
        .nil => {
            const heap = vm.ensureHeap();
            return vector_mod.empty(heap) catch VmError.OutOfMemory;
        },
        .persistent_vector => s,
        .list => blk: {
            const heap = vm.ensureHeap();
            // Materialize the list into a slice then fromSlice.
            var items: std.ArrayList(Value) = .empty;
            defer items.deinit(vm.allocator);
            var node = s;
            while (!list_mod.isEmpty(node)) {
                items.append(vm.allocator, list_mod.head(node)) catch return VmError.OutOfMemory;
                node = list_mod.tail(node);
            }
            break :blk vector_mod.fromSlice(heap, items.items) catch VmError.OutOfMemory;
        },
        else => VmError.KindMismatch,
    };
}

fn fnHashMap(vm: *VM, args: []const Value) VmError!Value {
    if (args.len % 2 != 0) return VmError.ArityMismatch;
    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        m = champ_mod.mapAssoc(
            heap,
            m,
            args[i],
            args[i + 1],
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch return VmError.OutOfMemory;
    }
    return m;
}

fn fnHashSet(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var s = champ_mod.setEmpty(heap) catch return VmError.OutOfMemory;
    for (args) |x| {
        s = champ_mod.setConj(
            heap,
            s,
            x,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch return VmError.OutOfMemory;
    }
    return s;
}

fn fnAssoc(vm: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const k = args[1];
    const v = args[2];
    const heap = vm.ensureHeap();
    return switch (coll.kind()) {
        .persistent_map => champ_mod.mapAssoc(
            heap,
            coll,
            k,
            v,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch VmError.OutOfMemory,
        .nil => blk: {
            // Per Clojure, (assoc nil k v) => {k v}.
            var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
            m = champ_mod.mapAssoc(
                heap,
                m,
                k,
                v,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory;
            break :blk m;
        },
        // Vector assoc-by-index is a Clojure feature; defer to
        // a follow-up commit. v1: maps only.
        else => VmError.KindMismatch,
    };
}

fn fnDissoc(vm: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const k = args[1];
    return switch (coll.kind()) {
        .persistent_map => champ_mod.mapDissoc(
            vm.ensureHeap(),
            coll,
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch VmError.OutOfMemory,
        .nil => coll,
        else => VmError.KindMismatch,
    };
}

fn fnGet(vm: *VM, args: []const Value) VmError!Value {
    _ = vm;
    const coll = args[0];
    const k = args[1];
    const default = if (args.len > 2) args[2] else value_mod.nilValue();
    return switch (coll.kind()) {
        .nil => default,
        .persistent_map => switch (champ_mod.mapGet(
            coll,
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )) {
            .present => |v| v,
            .absent => default,
        },
        .persistent_set => blk: {
            // `(get s elem)` returns elem if present, default
            // (or nil) otherwise.
            const present = champ_mod.setContains(
                coll,
                k,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            );
            break :blk if (present) k else default;
        },
        .persistent_vector => blk: {
            if (k.kind() != .fixnum) break :blk default;
            const idx = k.asFixnum();
            if (idx < 0) break :blk default;
            const u_idx: usize = @intCast(idx);
            if (u_idx >= vector_mod.count(coll)) break :blk default;
            break :blk vector_mod.nth(coll, u_idx);
        },
        else => return VmError.KindMismatch,
    };
}

fn fnContainsQ(_: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const k = args[1];
    return switch (coll.kind()) {
        .nil => value_mod.fromBool(false),
        .persistent_map => value_mod.fromBool(switch (champ_mod.mapGet(
            coll,
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )) {
            .present => true,
            .absent => false,
        }),
        .persistent_set => value_mod.fromBool(champ_mod.setContains(
            coll,
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )),
        .persistent_vector => blk: {
            if (k.kind() != .fixnum) break :blk value_mod.fromBool(false);
            const idx = k.asFixnum();
            if (idx < 0) break :blk value_mod.fromBool(false);
            const u_idx: usize = @intCast(idx);
            break :blk value_mod.fromBool(u_idx < vector_mod.count(coll));
        },
        else => return VmError.KindMismatch,
    };
}

fn fnKeys(vm: *VM, args: []const Value) VmError!Value {
    const m = args[0];
    return switch (m.kind()) {
        .nil => list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory,
        .persistent_map => blk: {
            var collected: std.ArrayList(Value) = .empty;
            defer collected.deinit(vm.allocator);
            var it = champ_mod.mapIter(m);
            while (it.next()) |e| {
                collected.append(vm.allocator, e.key) catch return VmError.OutOfMemory;
            }
            break :blk try buildListFromSlice(vm, collected.items);
        },
        else => return VmError.KindMismatch,
    };
}

fn fnVals(vm: *VM, args: []const Value) VmError!Value {
    const m = args[0];
    return switch (m.kind()) {
        .nil => list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory,
        .persistent_map => blk: {
            var collected: std.ArrayList(Value) = .empty;
            defer collected.deinit(vm.allocator);
            var it = champ_mod.mapIter(m);
            while (it.next()) |e| {
                collected.append(vm.allocator, e.value) catch return VmError.OutOfMemory;
            }
            break :blk try buildListFromSlice(vm, collected.items);
        },
        else => return VmError.KindMismatch,
    };
}

/// `(conj coll & xs)` — persistent add. Kind-specific:
///   list   → cons each x onto front (so order reverses for
///            multi-arg conj; matches Clojure)
///   vector → push each x to the end (left-to-right)
///   map    → each x must be a 2-element vector [k v]; assoc
///   set    → include each x
///   nil    → builds a list (Clojure makes (conj nil 1 2) => (2 1))
fn fnConj(vm: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const xs = args[1..];
    const heap = vm.ensureHeap();
    return switch (coll.kind()) {
        .nil => blk: {
            // Build a cons list in reverse order to match
            // Clojure's `(conj nil 1 2) => (2 1)` semantics.
            var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
            for (xs) |x| {
                result = list_mod.cons(heap, x, result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        .list => blk: {
            var result = coll;
            for (xs) |x| {
                result = list_mod.cons(heap, x, result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        .persistent_vector => blk: {
            // Materialize, append, rebuild. Vector push API
            // exists but our limited public surface only has
            // fromSlice; round-tripping is fine for v1.
            const n = vector_mod.count(coll);
            var items: std.ArrayList(Value) = .empty;
            defer items.deinit(vm.allocator);
            items.ensureTotalCapacity(vm.allocator, n + xs.len) catch return VmError.OutOfMemory;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                items.append(vm.allocator, vector_mod.nth(coll, i)) catch return VmError.OutOfMemory;
            }
            for (xs) |x| {
                items.append(vm.allocator, x) catch return VmError.OutOfMemory;
            }
            break :blk vector_mod.fromSlice(heap, items.items) catch VmError.OutOfMemory;
        },
        .persistent_map => blk: {
            var result = coll;
            for (xs) |x| {
                // Each x must be a 2-element vector or list.
                if (x.kind() != .persistent_vector) return VmError.KindMismatch;
                if (vector_mod.count(x) != 2) return VmError.ArityMismatch;
                const k = vector_mod.nth(x, 0);
                const v = vector_mod.nth(x, 1);
                result = champ_mod.mapAssoc(
                    heap,
                    result,
                    k,
                    v,
                    &dispatch_mod.hashValue,
                    &dispatch_mod.equal,
                ) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        .persistent_set => blk: {
            var result = coll;
            for (xs) |x| {
                result = champ_mod.setConj(
                    heap,
                    result,
                    x,
                    &dispatch_mod.hashValue,
                    &dispatch_mod.equal,
                ) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        else => return VmError.KindMismatch,
    };
}

// =============================================================================
// db primitives (Phase 4.0a)
// =============================================================================
//
// Per peer-AI turn 72: Path B (explicit transaction threading).
// `(db/open path)` opens a connection; `db/close` closes it.
// `(db/ref conn tree-keyword key-string)` constructs a durable
// ref Value. `db/put-key!` / `db/get-key` / `db/delete-key!` /
// `db/present?` operate via AUTO-EPHEMERAL transactions for
// v1.alpha (4.0a). Explicit `with-tx` + tx-threaded ops land in
// 4.0b.
//
// Errors land as catchable keyword payloads:
//   :db-error            general open/io failure
//   :db-closed           op on already-closed connection
//   :invalid-durable-ref arg was not a durable_ref Value
//   :codec-failed        encode/decode error
//
// Connection lifetime: each `db/open` allocates a Connection
// on the VM's main allocator (NOT the runtime arena) + appends
// it to vm.db_connections. `db/close` removes from the list +
// frees. VM.deinit closes any remaining as a safety net.

fn fnDbOpen(vm: *VM, args: []const Value) VmError!Value {
    // v1.alpha: accept the path as a keyword OR symbol (their
    // interned name is the path string). First-class strings
    // arrive in Phase 4 polish.
    const path_v = args[0];
    const path_slice: []const u8 = blk: {
        if (path_v.kind() == .keyword) {
            const id: u32 = @intCast(path_v.payload);
            break :blk vm.ensureInterner().keywordName(id);
        }
        if (path_v.kind() == .symbol) {
            const id: u32 = @intCast(path_v.payload);
            break :blk vm.ensureInterner().symbolName(id);
        }
        return VmError.KindMismatch;
    };
    // Heap-alloc the Connection on VM.allocator (NOT the arena).
    const conn = vm.allocator.create(db_mod.Connection) catch return VmError.OutOfMemory;
    errdefer vm.allocator.destroy(conn);
    const path_z = vm.allocator.dupeZ(u8, path_slice) catch return VmError.OutOfMemory;
    defer vm.allocator.free(path_z);
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    conn.* = db_mod.open(vm.allocator, heap, interner, path_z.ptr, .{}) catch return VmError.DbError;
    // Register on VM safety-net list.
    vm.db_close_callback = &dbCloseCallback;
    vm.db_connections.append(vm.allocator, @ptrCast(conn)) catch return VmError.OutOfMemory;
    return value_mod.Value{
        .tag = @intFromEnum(value_mod.Kind.db_connection),
        .payload = @intFromPtr(conn),
    };
}

/// Phase 4.0a: stand-alone closer used by VM.deinit safety net.
/// Closes the emdb env AND destroys the Connection struct. The
/// struct's own `allocator` field tells us how it was allocated.
fn dbCloseCallback(opaque_ptr: *anyopaque) void {
    const conn: *db_mod.Connection = @ptrCast(@alignCast(opaque_ptr));
    if (conn.open_flag) db_mod.close(conn);
    const allocator = conn.allocator;
    allocator.destroy(conn);
}

fn fnDbClose(vm: *VM, args: []const Value) VmError!Value {
    const v = args[0];
    if (v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(v.payload);
    // Remove from VM safety-net list.
    var i: usize = 0;
    while (i < vm.db_connections.items.len) : (i += 1) {
        if (vm.db_connections.items[i] == @as(*anyopaque, @ptrCast(conn))) {
            _ = vm.db_connections.swapRemove(i);
            break;
        }
    }
    db_mod.close(conn);
    vm.allocator.destroy(conn);
    return value_mod.nilValue();
}

fn fnDbRef(vm: *VM, args: []const Value) VmError!Value {
    const conn_v = args[0];
    const tree_v = args[1];
    const key_v = args[2];
    if (conn_v.kind() != .db_connection) return VmError.KindMismatch;
    // Tree name must be a keyword (its interned name = tree id).
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    // Key can be keyword / symbol (interned-name as key bytes).
    // First-class string keys arrive in Phase 4 polish.
    if (key_v.kind() != .keyword and key_v.kind() != .symbol) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(conn_v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    const interner = vm.ensureInterner();
    const tree_id: u32 = @intCast(tree_v.payload);
    const tree_name = interner.keywordName(tree_id);
    const key_id: u32 = @intCast(key_v.payload);
    const key_bytes: []const u8 = switch (key_v.kind()) {
        .keyword => interner.keywordName(key_id),
        .symbol => interner.symbolName(key_id),
        else => unreachable,
    };
    return db_mod.ref(vm.ensureHeap(), conn, tree_name, key_bytes) catch return VmError.DbError;
}

fn fnDbRefQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .durable_ref);
}

/// `(db/put-key! ref value)` — auto-ephemeral write tx for v1.alpha.
fn fnDbPutKey(_: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const v = args[1];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const conn = db_mod.refConn(r) orelse return VmError.DbError;
    if (!conn.open_flag) return VmError.DbClosed;
    var txn = db_mod.beginWrite(conn) catch return VmError.DbError;
    db_mod.putRef(&txn, r, v) catch {
        db_mod.abortWrite(&txn);
        return VmError.CodecFailed;
    };
    db_mod.commit(&txn) catch return VmError.DbError;
    return value_mod.nilValue();
}

/// `(db/get-key ref)` or `(db/get-key ref default)` — auto-ephemeral read tx.
fn fnDbGetKey(_: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const default = if (args.len > 1) args[1] else value_mod.nilValue();
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const conn = db_mod.refConn(r) orelse return VmError.DbError;
    if (!conn.open_flag) return VmError.DbClosed;
    var txn = db_mod.beginRead(conn) catch return VmError.DbError;
    defer db_mod.abortRead(&txn);
    const result = db_mod.getRef(&txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.CodecFailed;
    return result orelse default;
}

fn fnDbDeleteKey(_: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const conn = db_mod.refConn(r) orelse return VmError.DbError;
    if (!conn.open_flag) return VmError.DbClosed;
    var txn = db_mod.beginWrite(conn) catch return VmError.DbError;
    const existed = db_mod.delRef(&txn, r) catch {
        db_mod.abortWrite(&txn);
        return VmError.DbError;
    };
    db_mod.commit(&txn) catch return VmError.DbError;
    return value_mod.fromBool(existed);
}

fn fnDbPresentQ(_: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const conn = db_mod.refConn(r) orelse return VmError.DbError;
    if (!conn.open_flag) return VmError.DbClosed;
    var txn = db_mod.beginRead(conn) catch return VmError.DbError;
    defer db_mod.abortRead(&txn);
    const tree = db_mod.refTreeName(r);
    const key = db_mod.refKeyBytes(r);
    const result = db_mod.get(&txn, tree, key, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.DbError;
    return value_mod.fromBool(result != null);
}

// =============================================================================
// db explicit-tx primitives (Phase 4.0b)
// =============================================================================
//
// Per peer-AI turn 72: PATH B (explicit tx threading). The
// `with-tx` / `with-read-tx` macros (in core.nx) generate
// `(let [tx (db/begin-write conn)] (try ...body... (catch any e (db/abort-write! tx) (throw e))))`
// with commit at the end of the body.
//
// Single-owner enforcement: each TxnHandle struct carries an
// `active` flag. commit/abort sets it to false; subsequent ops
// detect this and raise `:tx-closed`. Prevents double-commit and
// use-after-finalize.
//
// Lifetime: TxnHandle structs live on `vm.runtime_arena` (small
// allocations, short-lived; arena reclaims at VM teardown). The
// underlying emdb txn handle is freed by commit/abort.
//
// Connection mismatch: `db/put!` etc. validate that the supplied
// ref belongs to the same connection the tx is open against.
// db.zig's putRef/getRef/delRef do this via `assertRefMatchesConn`.

pub const WriteTxnHandle = struct {
    txn: db_mod.WriteTxn,
    active: bool,
};

pub const ReadTxnHandle = struct {
    txn: db_mod.ReadTxn,
    active: bool,
};

fn writeTxnHandle(v: Value) ?*WriteTxnHandle {
    if (v.kind() != .db_write_txn) return null;
    return @ptrFromInt(v.payload);
}

fn readTxnHandle(v: Value) ?*ReadTxnHandle {
    if (v.kind() != .db_read_txn) return null;
    return @ptrFromInt(v.payload);
}

fn fnDbBeginWrite(vm: *VM, args: []const Value) VmError!Value {
    const conn_v = args[0];
    if (conn_v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(conn_v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    const handle = vm.runtime_arena.allocator().create(WriteTxnHandle) catch return VmError.OutOfMemory;
    handle.* = .{
        .txn = db_mod.beginWrite(conn) catch return VmError.DbError,
        .active = true,
    };
    return value_mod.Value{
        .tag = @intFromEnum(value_mod.Kind.db_write_txn),
        .payload = @intFromPtr(handle),
    };
}

fn fnDbBeginRead(vm: *VM, args: []const Value) VmError!Value {
    const conn_v = args[0];
    if (conn_v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(conn_v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    const handle = vm.runtime_arena.allocator().create(ReadTxnHandle) catch return VmError.OutOfMemory;
    handle.* = .{
        .txn = db_mod.beginRead(conn) catch return VmError.DbError,
        .active = true,
    };
    return value_mod.Value{
        .tag = @intFromEnum(value_mod.Kind.db_read_txn),
        .payload = @intFromPtr(handle),
    };
}

fn fnDbCommit(_: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    db_mod.commit(&h.txn) catch {
        h.active = false;
        return VmError.DbError;
    };
    h.active = false;
    return value_mod.nilValue();
}

fn fnDbAbortWrite(_: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return value_mod.nilValue(); // idempotent abort
    db_mod.abortWrite(&h.txn);
    h.active = false;
    return value_mod.nilValue();
}

fn fnDbAbortRead(_: *VM, args: []const Value) VmError!Value {
    const h = readTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return value_mod.nilValue();
    db_mod.abortRead(&h.txn);
    h.active = false;
    return value_mod.nilValue();
}

/// `(db/put! tx ref value)` — write through an active tx.
fn fnDbPut(_: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    const r = args[1];
    const v = args[2];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    db_mod.putRef(&h.txn, r, v) catch return VmError.CodecFailed;
    return value_mod.nilValue();
}

/// `(db/get tx ref)` or `(db/get tx ref default)` — read through
/// either a write or read tx. Returns `default` (nil if omitted)
/// for missing keys.
fn fnDbGet(_: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const r = args[1];
    const default = if (args.len > 2) args[2] else value_mod.nilValue();
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const result: ?Value = switch (tx_v.kind()) {
        .db_write_txn => blk: {
            const h = writeTxnHandle(tx_v).?;
            if (!h.active) return VmError.TxClosed;
            break :blk db_mod.getRef(&h.txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.CodecFailed;
        },
        .db_read_txn => blk: {
            const h = readTxnHandle(tx_v).?;
            if (!h.active) return VmError.TxClosed;
            break :blk db_mod.getRef(&h.txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.CodecFailed;
        },
        else => return VmError.KindMismatch,
    };
    return result orelse default;
}

fn fnDbDelete(_: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    const r = args[1];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const existed = db_mod.delRef(&h.txn, r) catch return VmError.DbError;
    return value_mod.fromBool(existed);
}

/// `(db/deref x)` — universal deref:
///   durable_ref → ephemeral read tx, return decoded value (nil
///                 if absent)
///   var         → Var.root (raises :unbound-var if unbound, per
///                 peer-AI turn 73 §Q1)
///   other       → :not-derefable (catchable)
fn fnDbDeref(_: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    return switch (x.kind()) {
        .durable_ref => blk: {
            const conn = db_mod.refConn(x) orelse return VmError.DbError;
            if (!conn.open_flag) return VmError.DbClosed;
            var txn = db_mod.beginRead(conn) catch return VmError.DbError;
            defer db_mod.abortRead(&txn);
            const result = db_mod.getRef(&txn, x, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.CodecFailed;
            break :blk result orelse value_mod.nilValue();
        },
        .var_ => blk: {
            const var_obj = vm_mod.VM.asVar(x);
            if (!var_obj.bound) return VmError.UnboundVar;
            break :blk var_obj.root;
        },
        else => VmError.NotDerefable,
    };
}

/// `(db/alter! tx ref f & args)` — read-modify-write inside an
/// active write tx. Reads current via getRef, computes
/// `(apply f current args)` via vm.callValue, writes via putRef.
/// Returns the new value.
///
/// Per peer-AI turn 73 §Q2: if `f` throws or control transfers,
/// do NOT write. Connection mismatch on `ref` surfaces as
/// :db-error via db.zig's assertRefMatchesConn.
fn fnDbAlter(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const r = args[1];
    const f = args[2];
    const extra = args[3..];

    const h = writeTxnHandle(tx_v) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;

    // 1. Read current.
    const current_opt = db_mod.getRef(&h.txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.CodecFailed;
    const current = current_opt orelse value_mod.nilValue();

    // 2. Build (f current extra...) arg list. f is the FIRST
    //    arg to callValue; current + extra follow.
    const call_args = vm.allocator.alloc(Value, 1 + extra.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = current;
    for (extra, 0..) |a, i| call_args[1 + i] = a;

    // 3. Invoke. Throws / control transfers propagate UNCHANGED
    //    so the with-tx's catch can abort. NO write on error.
    const new_value = try vm.callValue(f, call_args);

    // 4. Write.
    db_mod.putRef(&h.txn, r, new_value) catch return VmError.CodecFailed;
    return new_value;
}

// =============================================================================
// Helpers
// =============================================================================

/// Phase 3.3b seq iterator: walks a Value as a sequence.
/// Supports nil (empty), list, vector. Map/set seq semantics
/// deferred (Clojure returns entry-pairs/elements but our 3.3
/// scope doesn't pin that yet).
const SeqIter = struct {
    kind: enum { empty, list, vector },
    node: Value = value_mod.nilValue(),
    vec: Value = value_mod.nilValue(),
    vec_idx: usize = 0,
    vec_count: usize = 0,

    fn next(self: *SeqIter) ?Value {
        switch (self.kind) {
            .empty => return null,
            .list => {
                if (list_mod.isEmpty(self.node)) return null;
                const h = list_mod.head(self.node);
                self.node = list_mod.tail(self.node);
                return h;
            },
            .vector => {
                if (self.vec_idx >= self.vec_count) return null;
                const e = vector_mod.nth(self.vec, self.vec_idx);
                self.vec_idx += 1;
                return e;
            },
        }
    }
};

fn makeSeqIter(coll: Value) VmError!SeqIter {
    return switch (coll.kind()) {
        .nil => SeqIter{ .kind = .empty },
        .list => SeqIter{ .kind = .list, .node = coll },
        .persistent_vector => SeqIter{
            .kind = .vector,
            .vec = coll,
            .vec_count = vector_mod.count(coll),
        },
        else => VmError.KindMismatch,
    };
}

/// Append every element of `seq` to `out`. Used by `apply` to
/// splice the trailing seq into the args list.
fn appendSeqValues(vm: *VM, seq: Value, out: *std.ArrayList(Value)) VmError!void {
    var it = try makeSeqIter(seq);
    while (it.next()) |e| {
        out.append(vm.allocator, e) catch return VmError.OutOfMemory;
    }
}

/// Build a fresh cons list from a slice of Values (left-to-
/// right). Uses `vm.ensureHeap()`. GC TODO: results aren't
/// rooted between cons calls.
fn buildListFromSlice(vm: *VM, items: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        result = list_mod.cons(heap, items[i], result) catch return VmError.OutOfMemory;
    }
    return result;
}

/// Convert a Value into a list for cons. nil → empty list;
/// list passes through unchanged; vector becomes a fresh list
/// of its elements. Other kinds → KindMismatch.
fn coerceToList(vm: *VM, v: Value) VmError!Value {
    return switch (v.kind()) {
        .nil => list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory,
        .list => v,
        .persistent_vector => blk: {
            const heap = vm.ensureHeap();
            const n = vector_mod.count(v);
            var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                result = list_mod.cons(heap, vector_mod.nth(v, i), result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        else => VmError.KindMismatch,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stdlib: installCore registers all 10 fns" {
    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const ally = dbg.allocator();
    // Var objects normally live in VM.runtime_arena (wholesale
    // freed at VM.deinit per the Namespace.deinit doc-comment).
    // Tests mirror that by using an arena for var_allocator.
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();

    var ns = Namespace.init(ally, arena.allocator());
    defer ns.deinit();
    try installCore(&ns);
    for (core_fns) |entry| {
        const v = ns.lookup(entry.name) orelse return error.TestFailed;
        try testing.expect(v.bound);
        try testing.expectEqual(Kind.native_fn, v.root.kind());
        try testing.expect(!v.macro);
    }
}

test "stdlib: nativeFnValue round-trips" {
    const v = vm_mod.nativeFnValue(&native_first);
    try testing.expectEqual(Kind.native_fn, v.kind());
    const back = vm_mod.asNativeFn(v);
    try testing.expectEqualStrings("first", back.name);
}
