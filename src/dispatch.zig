//! dispatch.zig — full-Value hash and equality dispatch.
//!
//! This is the canonical public API for hashing and comparing any
//! `Value`, immediate or heap. `value.zig` and `eq.zig` stay low-level
//! (they own immediate semantics + cross-kind rules); this module
//! layers per-kind heap dispatch on top of them.
//!
//! Why this split instead of folding heap dispatch into `value` / `eq`?
//! Peer-AI review (conversation `nexis-phase-1` turn 6) chose the
//! centralized shape for two reasons: (1) keeping the per-kind import
//! list out of `value` / `eq` so they don't accrete one import per
//! heap kind, and (2) avoiding the module-graph cycle that results
//! when `value` or `eq` imports a dispatcher that transitively imports
//! them back — Zig tolerates the cycle at ordinary compile time, but
//! the test runner's "each source file is also a test binary root"
//! model rejects a file appearing in both `root` and a named module
//! of the same graph. One-way dependencies (everyone below depends on
//! `dispatch`; `dispatch` depends on nothing else in the runtime via
//! dispatch itself) make every test binary resolve cleanly.
//!
//! Dependency shape (one-way; no cycles):
//!
//!     dispatch.zig
//!     ├─ @import("value")        (Value + Kind + v.hashImmediate path)
//!     ├─ @import("eq")           (cross-kind rule + immediate equality)
//!     ├─ @import("heap")         (*HeapHeader + Heap.asHeapHeader)
//!     ├─ @import("hash")         (mixKindDomain)
//!     └─ @import("string")       (per-kind hashHeader + bytesEqual) [+ future kinds]
//!
//! No heap-kind module imports `dispatch.zig`. Every kind's own
//! module provides `hashHeader(*HeapHeader) u32` and a per-kind
//! equality function (`bytesEqual` for strings; `structuralEqual`,
//! `limbsEqual`, etc. for future kinds); `dispatch.zig` is the only
//! place those per-kind functions are composed with `mixKindDomain`
//! and the cross-kind dispatch switch.
//!
//! Public API:
//!   - `hashValue(v)`: full hash for any Value. Immediates go through
//!     `value.hashImmediate`; heap kinds go through `heapHashBase` +
//!     `mixKindDomain` here.
//!   - `equal(a, b)`: full equality. Cross-kind + immediates go
//!     through `eq.equal`; same-kind-heap routes here to `heapEqual`.
//!   - `heapHashBase(v)` / `heapEqual(a, b)`: low-level entry points
//!     exposed for tests and advanced callers who have already
//!     established they hold heap-kind Values.

const std = @import("std");
const value = @import("value");
const eq = @import("eq");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const string = @import("string");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;

// =============================================================================
// Hash dispatch
// =============================================================================

/// Full hash for any Value. Routes immediates to `value.hashImmediate`
/// (the immediate-kind fast path) and heap kinds through
/// `heapHashBase` + `mixKindDomain`. Result satisfies the bedrock
/// `(= x y) ⇒ (hash x) = (hash y)` invariant end-to-end.
pub fn hashValue(v: Value) u64 {
    const k = v.kind();
    if (k.isHeap()) {
        const base = heapHashBase(v);
        return hash_mod.mixKindDomain(base, @intFromEnum(k));
    }
    // Sentinels (`unbound`, `undef`) panic inside value.hashImmediate
    // via its default switch arm.
    return v.hashImmediate();
}

/// Pre-mix heap-kind hash base. Resolves the `*HeapHeader`, switches
/// on kind to the per-kind `hashHeader`, extends the `u32` result to
/// `u64`. Does **not** apply `mixKindDomain` — `hashValue` above owns
/// that final step so heap kinds go through exactly one mixer.
pub fn heapHashBase(v: Value) u64 {
    std.debug.assert(v.kind().isHeap());
    const k = v.kind();
    const h = Heap.asHeapHeader(v);
    const base: u32 = switch (k) {
        .string => string.hashHeader(h),
        // Future: .bignum, .list, .persistent_map, .persistent_set,
        // .persistent_vector, .byte_vector, .typed_vector, .function,
        // .var_, .durable_ref, .transient, .error_, .meta_symbol.
        else => std.debug.panic(
            "dispatch.heapHashBase: kind {s} not implemented",
            .{@tagName(k)},
        ),
    };
    return @as(u64, base);
}

// =============================================================================
// Equality dispatch
// =============================================================================

/// Full equality for any two Values. Handles the bit-identity fast
/// path inline (so the common case skips both `eq.equal` and the
/// kind switch here), routes cross-kind and immediate-kind
/// comparisons through `eq.equal`, and handles same-kind-heap
/// structural compare through `heapEqual`.
pub fn equal(a: Value, b: Value) bool {
    // Identical bits -> trivially equal for every immediate kind and
    // for heap kinds when the payload is the same *HeapHeader.
    if (a.tag == b.tag and a.payload == b.payload) return true;
    const ka = a.kind();
    const kb = b.kind();
    if (ka != kb) return false;
    if (ka.isHeap()) return heapEqual(a, b);
    // Immediate same-kind: let eq.equal handle it (covers signed-zero
    // float case, keyword/symbol id compare, etc.).
    return eq.equal(a, b);
}

/// Same-kind heap structural compare. Caller (`equal` above, or
/// advanced code that has already done its own cross-kind checks)
/// has established `a.kind() == b.kind()` and `a.kind().isHeap()`.
pub fn heapEqual(a: Value, b: Value) bool {
    std.debug.assert(a.kind() == b.kind());
    std.debug.assert(a.kind().isHeap());
    const k = a.kind();
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    return switch (k) {
        .string => string.bytesEqual(ah, bh),
        else => std.debug.panic(
            "dispatch.heapEqual: kind {s} not implemented",
            .{@tagName(k)},
        ),
    };
}

// =============================================================================
// Tests — end-to-end dispatch for every wired kind. Per-kind deep
// semantics are tested inside the kind's own module.
// =============================================================================

const testing = std.testing;

test "heapHashBase: string dispatch returns the raw per-kind hash as u64" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const v = try string.fromBytes(&heap, "dispatch-test");
    const direct: u32 = string.hashHeader(Heap.asHeapHeader(v));
    try testing.expectEqual(@as(u64, direct), heapHashBase(v));
}

test "heapEqual: string dispatch delegates to string.bytesEqual" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "hello");
    const b = try string.fromBytes(&heap, "hello");
    const c = try string.fromBytes(&heap, "world");

    try testing.expect(heapEqual(a, b));
    try testing.expect(!heapEqual(a, c));
}

test "heapHashBase: equal strings produce equal pre-mix bases" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "bedrock-invariant");
    const b = try string.fromBytes(&heap, "bedrock-invariant");
    try testing.expect(heapEqual(a, b));
    try testing.expectEqual(heapHashBase(a), heapHashBase(b));
}

test "heapHashBase: different strings almost certainly differ" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "abc");
    const b = try string.fromBytes(&heap, "xyz");
    try testing.expect(!heapEqual(a, b));
    try testing.expect(heapHashBase(a) != heapHashBase(b));
}

// ---- Full-Value dispatch (covers both immediate and heap) ----

test "hashValue: routes immediates to v.hashImmediate()" {
    const nil = value.nilValue();
    const t = value.fromBool(true);
    const f = value.fromBool(false);
    try testing.expectEqual(nil.hashImmediate(), hashValue(nil));
    try testing.expectEqual(t.hashImmediate(), hashValue(t));
    try testing.expectEqual(f.hashImmediate(), hashValue(f));
    const fx = value.fromFixnum(42).?;
    try testing.expectEqual(fx.hashImmediate(), hashValue(fx));
}

test "hashValue: routes heap kinds through the mixed-base path" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try string.fromBytes(&heap, "full-hash");
    const b = try string.fromBytes(&heap, "full-hash");
    const c = try string.fromBytes(&heap, "different");

    try testing.expectEqual(hashValue(a), hashValue(b));
    try testing.expect(hashValue(a) != hashValue(c));
    // The full hashValue applies mixKindDomain once.
    const expected = hash_mod.mixKindDomain(heapHashBase(a), @intFromEnum(Kind.string));
    try testing.expectEqual(expected, hashValue(a));
}

test "equal: bit-identity fast path returns true without dispatch" {
    const nil = value.nilValue();
    try testing.expect(equal(nil, nil));
    const t = value.fromBool(true);
    try testing.expect(equal(t, t));
    const fx = value.fromFixnum(7).?;
    try testing.expect(equal(fx, fx));
}

test "equal: cross-kind is false, same-kind immediate delegates to eq.equal" {
    const n = value.nilValue();
    const f = value.fromBool(false);
    try testing.expect(!equal(n, f)); // nil != false
    const pos = value.fromFloat(0.0);
    const neg = value.fromFloat(-0.0);
    // Signed-zero case: eq.equal returns true, bit-identity doesn't
    // match. Covered via dispatch.
    try testing.expect(equal(pos, neg));
}

test "equal: same-kind-heap strings dispatch to bytesEqual" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try string.fromBytes(&heap, "same");
    const b = try string.fromBytes(&heap, "same");
    const c = try string.fromBytes(&heap, "different");
    try testing.expect(equal(a, b));
    try testing.expect(!equal(a, c));
}

test "equal ⇒ hashValue equal: bedrock invariant end-to-end (string)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try string.fromBytes(&heap, "bedrock-string-invariant");
    const b = try string.fromBytes(&heap, "bedrock-string-invariant");
    try testing.expect(equal(a, b));
    try testing.expectEqual(hashValue(a), hashValue(b));
}

test "equal rejects cross-kind heap Values before payload interpretation" {
    // White-box test: deliberately forges an "incomplete" Value of
    // kind `.persistent_map` by tagging a raw heap allocation with
    // that kind byte. The `persistent_map` kind has no implementation
    // yet — calling `hashValue` or `heapEqual` on such a value would
    // panic at the dispatcher's `else` arm. The whole point is to
    // prove that `dispatch.equal` short-circuits on the cross-kind
    // rule BEFORE it ever reaches kind-specific dispatch, so this
    // forgery never gets interpreted as a real map.
    //
    // Pattern is intentional for this single invariant test; do NOT
    // extend it to other coverage — once a second heap kind ships,
    // cross-kind tests should use two real kinds.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try string.fromBytes(&heap, "cross");
    const h = try heap.alloc(.persistent_map, 0);
    const fake_map: Value = .{
        .tag = @intFromEnum(Kind.persistent_map),
        .payload = @intFromPtr(h),
    };
    try testing.expect(!equal(s, fake_map));
}
