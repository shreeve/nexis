//! dispatch.zig — `=` and `hash` over any Value (SEMANTICS §2, §3).
//!
//! Immediates go to `Value.equalImmediate` / `Value.hashImmediate`;
//! heap kinds to their own modules. The collection modules take the
//! element hash and equality as function pointers (`hashSeq(h,
//! &hashValue)`), so recursion into elements comes back through here
//! and no kind module imports this one.
//!
//! Three rules decide every pair of values:
//!
//!   - **Identity kinds** (functions, vars, handles, atoms, transients,
//!     protocols, Nextomic connections) are equal to themselves only
//!     and hash their pointer. The collector never moves a block, so
//!     the pointer is stable for the value's life.
//!   - **Sequential kinds** (list, vector) compare element-wise across
//!     kinds and share one hash domain byte, so `(= '(1 2) [1 2])` and
//!     their hashes agree.
//!   - **Every other kind** is equal only within its own kind, by its
//!     module's structural rule, and mixes its own kind byte into its
//!     hash.
//!
//! **Native stack.** `=` and `hash` recurse on nesting depth. Each
//! structural step checks the stack guard (`stack.zig`); a value too
//! deep for the stack that remains makes the step answer `false` or
//! `0` and counts an overflow instead of faulting. The callers of `=`
//! and `hash` are too many to thread an error through, so the VM reads
//! `overflowCount` around each native call and opcode that compares or
//! hashes and turns a change into the catchable `:stack-overflow`
//! (SEMANTICS §2.7). A map, set or record whose hash was computed past
//! an overflow keeps no cached hash.

const std = @import("std");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const hash_mod = @import("hash.zig");
const stack = @import("stack.zig");
const string = @import("string.zig");
const list = @import("coll/list.zig");
const vector = @import("coll/vector.zig");
const nextomic_handle = @import("nextomic/handle.zig");
const bignum = @import("bignum.zig");
const champ = @import("coll/champ.zig");
const typed_vector = @import("coll/typed_vector.zig");
const db = @import("db.zig");
const record = @import("record.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;

/// The hash domain byte list and vector share, outside the range of
/// kind bytes so it never meets a kind-local domain.
pub const sequential_domain_byte: u8 = 0xF0;

/// Is `k` compared and hashed by identity? These kinds are mutable,
/// process-local or code; two of them are equal only when they are
/// the same value.
pub fn isIdentityKind(k: Kind) bool {
    return switch (k) {
        .function,
        .native_fn,
        .var_,
        .db_connection,
        .db_write_txn,
        .db_read_txn,
        .transient,
        .atom,
        .protocol,
        .protocol_fn,
        .nextomic_conn,
        => true,
        else => false,
    };
}

inline fn isSequential(k: Kind) bool {
    return k == .list or k == .persistent_vector;
}

/// The domain byte `hashValue` mixes into a heap kind's hash.
pub fn domainByte(k: Kind) u8 {
    return if (isSequential(k)) sequential_domain_byte else @intFromEnum(k);
}

// =============================================================================
// Native-stack overflows
// =============================================================================

var overflow_count: u64 = 0;

/// How many times `equal`, `hashValue` or the printer ran out of
/// native stack in this process. A caller that sees the count change
/// across a call knows the call's answer is meaningless and raises
/// `:stack-overflow` instead.
pub fn overflowCount() u64 {
    return overflow_count;
}

/// Record that a recursion on data depth stopped at the stack guard.
pub fn noteOverflow() void {
    overflow_count +%= 1;
}

// =============================================================================
// Hash
// =============================================================================

/// `hash` for any Value: `(= x y) ⇒ (hash x) = (hash y)`, including
/// across list and vector.
pub fn hashValue(v: Value) u64 {
    const k = v.kind();
    if (!k.isHeap()) return v.hashImmediate();
    return hash_mod.mixKindDomain(heapHashBase(v), domainByte(k));
}

/// A heap kind's hash before the domain byte is mixed in.
pub fn heapHashBase(v: Value) u64 {
    const k = v.kind();
    std.debug.assert(k.isHeap());
    if (isIdentityKind(k)) return hash_mod.hashU64(v.payload);
    stack.check() catch {
        noteOverflow();
        return 0;
    };
    const h = Heap.asHeapHeader(v);
    const overflows_before = overflow_count;
    const base: u64 = switch (k) {
        .string => string.hashHeader(h),
        .bignum => bignum.hashHeader(h),
        .list => list.hashSeq(v, &hashValue),
        .persistent_vector => vector.hashSeq(h, &hashValue),
        .persistent_map => champ.hashMap(h, &hashValue),
        .persistent_set => champ.hashSet(h, &hashValue),
        .typed_vector => typed_vector.hashHeader(h),
        // Over the identity triple (store, tree, key), never the
        // advisory connection (DB.md §7.2).
        .durable_ref => db.hashHeader(h),
        .record => record.hashHeader(h, &hashValue),
        .nextomic_db => nextomic_handle.dbHash(h),
        .nextomic_entity => nextomic_handle.entityHash(h),
        else => std.debug.panic("dispatch.hashValue: kind {s} is never constructed", .{@tagName(k)}),
    };
    if (overflow_count != overflows_before) h.setCachedHash(0);
    return base;
}

// =============================================================================
// Equality
// =============================================================================

/// `=` for any two Values.
pub fn equal(a: Value, b: Value) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    const ka = a.kind();
    const kb = b.kind();
    if (ka != kb) return isSequential(ka) and isSequential(kb) and sequentialEqual(a, b);
    if (!ka.isHeap()) return a.equalImmediate(b);
    // Distinct identity values: the bit test above already said no.
    if (isIdentityKind(ka)) return false;
    stack.check() catch {
        noteOverflow();
        return false;
    };
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    return switch (ka) {
        .string => string.bytesEqual(ah, bh),
        .bignum => bignum.limbsEqual(ah, bh),
        .list => list.equalSeq(a, b, &equal),
        .persistent_vector => vector.equalSeq(ah, bh, &equal),
        .persistent_map => champ.equalMap(ah, bh, &hashValue, &equal),
        .persistent_set => champ.equalSet(ah, bh, &hashValue, &equal),
        .typed_vector => typed_vector.equalHeaders(ah, bh),
        .durable_ref => db.refsEqual(ah, bh),
        .record => record.recordsEqual(ah, bh, &equal),
        .nextomic_db => nextomic_handle.dbEqual(ah, bh),
        .nextomic_entity => nextomic_handle.entityEqual(ah, bh),
        else => std.debug.panic("dispatch.equal: kind {s} is never constructed", .{@tagName(ka)}),
    };
}

/// A list against a vector: one streaming walk over both.
fn sequentialEqual(a: Value, b: Value) bool {
    stack.check() catch {
        noteOverflow();
        return false;
    };
    const l, const v = if (a.kind() == .list) .{ a, b } else .{ b, a };
    var cl = list.Cursor.init(l);
    var cv = vector.Cursor.init(v);
    while (true) {
        const x = cl.next() orelse return cv.next() == null;
        const y = cv.next() orelse return false;
        if (!equal(x, y)) return false;
    }
}

// =============================================================================
// Tests — the routing rules. Each kind's own structural rule is tested
// in its module; the randomized laws live in test/prop.
// =============================================================================

const testing = std.testing;
const atom = @import("atom.zig");
const transient = @import("coll/transient.zig");

fn fx(n: i64) Value {
    return value.fromFixnum(n).?;
}

/// `=` holds both ways and the hashes agree.
fn expectSame(a: Value, b: Value) !void {
    try testing.expect(equal(a, b));
    try testing.expect(equal(b, a));
    try testing.expectEqual(hashValue(a), hashValue(b));
}

fn expectDifferent(a: Value, b: Value) !void {
    try testing.expect(!equal(a, b));
    try testing.expect(!equal(b, a));
}

test "immediates: hash is hashImmediate; no cross-kind equality; the zeros fold" {
    for ([_]Value{ value.nilValue(), value.fromBool(true), fx(42), value.fromFloat(1.5) }) |v| {
        try testing.expectEqual(v.hashImmediate(), hashValue(v));
    }
    try expectDifferent(value.nilValue(), value.fromBool(false));
    try expectDifferent(fx(1), value.fromFloat(1.0));
    try expectSame(value.fromFloat(0.0), value.fromFloat(-0.0));
}

test "strings and bignums compare by content across allocations; a bignum never equals a fixnum" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    try expectSame(try string.fromBytes(&heap, "same"), try string.fromBytes(&heap, "same"));
    try expectDifferent(try string.fromBytes(&heap, "same"), try string.fromBytes(&heap, "other"));
    const big = value.fixnum_max + 1;
    try expectSame(try bignum.fromI64(&heap, big), try bignum.fromI64(&heap, big));
    try expectDifferent(try bignum.fromI64(&heap, big), try bignum.fromI64(&heap, -big));
    // One canonical form per integer: in range, fromI64 is a fixnum.
    try testing.expect((try bignum.fromI64(&heap, value.fixnum_max)).kind() == .fixnum);
    try expectDifferent(try bignum.fromI64(&heap, big), fx(value.fixnum_max));
}

test "list and vector: equal across kinds with one hash; length and element kinds still count" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const items = [_]Value{ fx(1), fx(2), fx(3) };
    try expectSame(try list.fromSlice(&heap, &items), try vector.fromSlice(&heap, &items));
    try expectSame(try list.empty(&heap), try vector.empty(&heap));
    try expectDifferent(try list.fromSlice(&heap, items[0..2]), try vector.fromSlice(&heap, &items));
    try expectDifferent(try list.fromSlice(&heap, &items), try vector.fromSlice(&heap, &.{ fx(1), fx(2), fx(4) }));
    try expectDifferent(try list.empty(&heap), value.nilValue());
    // 1025 elements: past the vector's tail into its trie.
    var many: [1025]Value = undefined;
    for (&many, 0..) |*slot, i| slot.* = fx(@intCast(i));
    try expectSame(try list.fromSlice(&heap, &many), try vector.fromSlice(&heap, &many));
    // Nested: an inner list against an inner vector is still sequential.
    const nested_l = try list.fromSlice(&heap, &.{ fx(1), try list.fromSlice(&heap, &.{fx(2)}) });
    const nested_v = try vector.fromSlice(&heap, &.{ fx(1), try vector.fromSlice(&heap, &.{fx(2)}) });
    try expectSame(nested_l, nested_v);
}

test "maps and sets: equal across insertion orders and subkinds; never equal to each other or to a sequence" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var small_a = try champ.mapEmpty(&heap);
    var small_b = try champ.mapEmpty(&heap);
    var big_a = try champ.mapEmpty(&heap);
    var set_a = try champ.setEmpty(&heap);
    var set_b = try champ.setEmpty(&heap);
    for (0..20) |i| {
        const k = fx(@intCast(i));
        const rk = fx(@intCast(19 - i));
        big_a = try champ.mapAssoc(&heap, big_a, k, k, &hashValue, &equal);
        set_a = try champ.setConj(&heap, set_a, k, &hashValue, &equal);
        set_b = try champ.setConj(&heap, set_b, rk, &hashValue, &equal);
        if (i < 4) {
            small_a = try champ.mapAssoc(&heap, small_a, k, k, &hashValue, &equal);
            small_b = try champ.mapAssoc(&heap, small_b, fx(@intCast(3 - i)), fx(@intCast(3 - i)), &hashValue, &equal);
        }
    }
    try expectSame(small_a, small_b);
    try expectSame(set_a, set_b);
    // An array-map against a CHAMP root with the same entries.
    var big_b = big_a;
    for (4..20) |i| big_b = try champ.mapDissoc(&heap, big_b, fx(@intCast(i)), &hashValue, &equal);
    try expectSame(small_a, big_b);
    try expectDifferent(small_a, set_a);
    try expectDifferent(try champ.mapEmpty(&heap), try champ.setEmpty(&heap));
    try expectDifferent(try champ.mapEmpty(&heap), try vector.empty(&heap));
}

test "records: structural within a type, never equal to their field map" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var fields = try champ.mapEmpty(&heap);
    fields = try champ.mapAssoc(&heap, fields, fx(1), value.fromFloat(-0.0), &hashValue, &equal);
    var fields_pos = try champ.mapEmpty(&heap);
    fields_pos = try champ.mapAssoc(&heap, fields_pos, fx(1), value.fromFloat(0.0), &hashValue, &equal);
    // -0.0 and 0.0 are `=`, so the records are too, with one hash.
    try expectSame(try record.make(&heap, 3, fields), try record.make(&heap, 3, fields_pos));
    try expectDifferent(try record.make(&heap, 3, fields), try record.make(&heap, 4, fields));
    try expectDifferent(try record.make(&heap, 3, fields), fields);
}

test "identity kinds: equal to themselves only, hash stable across mutation, transients hash" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try atom.make(&heap, fx(1));
    const b = try atom.make(&heap, fx(1));
    try expectSame(a, a);
    try expectDifferent(a, b);
    const before = hashValue(a);
    atom.setValue(a, fx(2));
    try testing.expectEqual(before, hashValue(a));
    const t = try transient.transientFrom(&heap, try vector.empty(&heap));
    try expectSame(t, t);
    try expectDifferent(t, try transient.transientFrom(&heap, try vector.empty(&heap)));
    try testing.expect(!equal(t, try vector.empty(&heap)));
}

/// `depth` one-element vectors around a nil.
fn nest(heap: *Heap, depth: usize) !Value {
    var v = value.nilValue();
    for (0..depth) |_| v = try vector.fromSlice(heap, &.{v});
    return v;
}

test "stack guard: = and hash on data too deep for the stack count an overflow instead of faulting" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const deep_a = try nest(&heap, 20_000);
    const deep_b = try nest(&heap, 20_000);
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, fx(1), deep_a, &hashValue, &equal);

    // A shallow value is unaffected by a tight budget.
    defer stack.arm(stack.main_thread_budget);
    stack.arm(64 * 1024);
    const shallow = try nest(&heap, 3);
    const n0 = overflowCount();
    try testing.expect(equal(shallow, try nest(&heap, 3)));
    _ = hashValue(shallow);
    try testing.expectEqual(n0, overflowCount());

    try testing.expect(!equal(deep_a, deep_b));
    try testing.expect(overflowCount() > n0);
    const n1 = overflowCount();
    _ = hashValue(m);
    try testing.expect(overflowCount() > n1);
    // The map computed its hash past the overflow and keeps none.
    try testing.expect(Heap.asHeapHeader(m).cachedHash() == null);
}
