//! coll/transient.zig — transient wrapper kind (Phase 1).
//!
//! Authoritative spec: `docs/TRANSIENT.md`. Derivative semantics:
//! `docs/SEMANTICS.md` §2.6 (identity-based equality; not hashable;
//! not serializable), `docs/VALUE.md` §2.2 (kind 27, local-enum
//! subkinds 0/1/2), `docs/GC.md` §5 (trace contract), PLAN §9.4
//! (owner-token + frozen state machine), CLOJURE-REVIEW §1.2 + §2.7
//! (owner-token epoch vs. Clojure's thread identity).
//!
//! v1 delivers "shallow" transients (TRANSIENT.md §1 Option B):
//! mutation ops call the persistent backing operations (`hamt.mapAssoc`,
//! `hamt.setConj`, `vector.conj`) underneath, updating the wrapper's
//! `inner_header` field in place. Real in-place node editing
//! (Option A, Clojure's performance advantage) is deferred to a
//! Phase 6 commit.
//!
//! Token discipline enforced at every public entry point:
//!   - `owner_token == 0` → frozen; all ops return `error.TransientFrozen`.
//!   - Non-transient Value → `error.TransientKindMismatch`.
//!   - Wrong subkind (mapAssocBang on a set wrapper) →
//!     `error.TransientKindMismatch`.
//!
//! Module graph (one-way terminal):
//!
//!     src/coll/transient.zig
//!     ├─ @import("value")
//!     ├─ @import("heap")
//!     ├─ @import("hamt")    — mapAssoc/Dissoc/Get/Count, setConj/Disj/Contains/Count, valueFromMapHeader, valueFromSetHeader
//!     └─ @import("vector")  — conj/nth/count, valueFromVectorHeader
//!
//! Nothing imports `transient.zig`. `src/dispatch.zig` and
//! `src/gc.zig` each gain a `.transient` arm that calls into this
//! module (dispatch) or this module's `trace` (gc).

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hamt = @import("hamt");
const vector = @import("vector");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Subkind taxonomy (TRANSIENT.md §2 local enum, VALUE.md §2.2 amended)
// =============================================================================

pub const subkind_transient_map: u16 = 0;
pub const subkind_transient_set: u16 = 1;
pub const subkind_transient_vector: u16 = 2;

// =============================================================================
// Error set (TRANSIENT.md §6)
// =============================================================================

pub const TransientError = error{
    /// Op called on a frozen transient (owner_token == 0). After
    /// `persistentBang` OR on a wrapper whose token was never stamped.
    TransientFrozen,
    /// Reserved for Phase 7+ multi-isolate owner mismatch. No v1
    /// runtime code path produces this variant; it exists so
    /// Phase 7+ can light it up without introducing a new error kind.
    TransientWrongOwner,
    /// `transientFrom` called on a Value whose kind is not a valid
    /// transient inner (must be .persistent_map / .persistent_set /
    /// .persistent_vector).
    InvalidTransientInner,
    /// Transient op family mismatch — e.g. `mapAssocBang` called on
    /// a set wrapper, or any transient op on a non-transient Value.
    TransientKindMismatch,
};

// =============================================================================
// Wrapper layout (TRANSIENT.md §3)
// =============================================================================

const TransientBody = extern struct {
    /// 0 = frozen/invalidated; nonzero = active owner token.
    owner_token: u64,

    /// Current persistent inner root pointer. Never null on a
    /// well-formed wrapper. Updated in place by every successful
    /// `...Bang` op.
    inner_header: *HeapHeader,

    comptime {
        std.debug.assert(@sizeOf(TransientBody) == 16);
        std.debug.assert(@offsetOf(TransientBody, "owner_token") == 0);
        std.debug.assert(@offsetOf(TransientBody, "inner_header") == 8);
    }
};

// =============================================================================
// Owner-token source (TRANSIENT.md §4)
//
// Private module-level counter. No public API for issuance. Tokens
// are opaque to user code. Exhaustion not handled in v1 (u64 at
// realistic issue rates is practically unreachable; wraparound
// revisited with multi-isolate support per TRANSIENT.md §4).
// =============================================================================

var next_token: u64 = 1;

fn issueOwnerToken() u64 {
    const t = next_token;
    next_token += 1;
    return t;
}

// =============================================================================
// Body accessors
// =============================================================================

fn transientBody(h: *HeapHeader) *TransientBody {
    return Heap.bodyOf(TransientBody, h);
}

fn transientBodyConst(h: *HeapHeader) *const TransientBody {
    return Heap.bodyOf(TransientBody, h);
}

// =============================================================================
// Internal validation helpers
// =============================================================================

fn assertTransient(t: Value) TransientError!void {
    if (t.kind() != .transient) return TransientError.TransientKindMismatch;
}

fn assertTransientSubkind(t: Value, expected_subkind: u16) TransientError!void {
    try assertTransient(t);
    if (t.subkind() != expected_subkind) return TransientError.TransientKindMismatch;
}

fn assertActive(t: Value) TransientError!void {
    try assertTransient(t);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    if (body.owner_token == 0) return TransientError.TransientFrozen;
}

fn assertActiveSubkind(t: Value, expected_subkind: u16) TransientError!void {
    try assertTransientSubkind(t, expected_subkind);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    if (body.owner_token == 0) return TransientError.TransientFrozen;
}

// =============================================================================
// Subkind → persistent Value dispatch
//
// The single place transient code crosses into kind-specific
// reconstruction. Calls only the public per-kind `valueFromXxxHeader`
// helpers — does NOT inspect body layouts directly. Per peer-AI
// turn 18, this boundary keeps transient ignorant of CHAMP/array-map
// subkind inference details.
// =============================================================================

fn innerValueForSubkind(subkind: u16, h: *HeapHeader) Value {
    return switch (subkind) {
        subkind_transient_map => hamt.valueFromMapHeader(h),
        subkind_transient_set => hamt.valueFromSetHeader(h),
        subkind_transient_vector => vector.valueFromVectorHeader(h),
        else => unreachable,
    };
}

// =============================================================================
// Public API — wrapping / unwrapping
// =============================================================================

/// Wrap a persistent map/set/vector Value as a fresh active transient.
/// Returns `error.InvalidTransientInner` on any other kind.
pub fn transientFrom(heap: *Heap, persistent_v: Value) (TransientError || std.mem.Allocator.Error || error{Overflow})!Value {
    const subkind: u16 = switch (persistent_v.kind()) {
        .persistent_map => subkind_transient_map,
        .persistent_set => subkind_transient_set,
        .persistent_vector => subkind_transient_vector,
        else => return TransientError.InvalidTransientInner,
    };
    const h = try heap.alloc(.transient, @sizeOf(TransientBody));
    const body = transientBody(h);
    body.owner_token = issueOwnerToken();
    body.inner_header = Heap.asHeapHeader(persistent_v);
    return .{
        .tag = @as(u64, @intFromEnum(Kind.transient)) | (@as(u64, subkind) << 16),
        .payload = @intFromPtr(h),
    };
}

/// Freeze the transient and return the current inner persistent
/// Value. The wrapper's `owner_token` is zeroed; subsequent ops on
/// the wrapper return `error.TransientFrozen`. The returned
/// persistent Value is safe to share (persistent semantics).
pub fn persistentBang(t: Value) TransientError!Value {
    try assertActive(t);
    const h = Heap.asHeapHeader(t);
    const body = transientBody(h);
    const inner = body.inner_header;
    body.owner_token = 0; // freeze
    return innerValueForSubkind(t.subkind(), inner);
}

// =============================================================================
// Public API — transient map ops (subkind 0)
// =============================================================================

pub fn mapAssocBang(
    heap: *Heap,
    t: Value,
    key: Value,
    val: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) (TransientError || std.mem.Allocator.Error || error{Overflow})!Value {
    try assertActiveSubkind(t, subkind_transient_map);
    const h = Heap.asHeapHeader(t);
    const body = transientBody(h);
    const old_v = hamt.valueFromMapHeader(body.inner_header);
    const new_v = try hamt.mapAssoc(heap, old_v, key, val, elementHash, elementEq);
    body.inner_header = Heap.asHeapHeader(new_v);
    return t;
}

pub fn mapDissocBang(
    heap: *Heap,
    t: Value,
    key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) (TransientError || std.mem.Allocator.Error || error{Overflow})!Value {
    try assertActiveSubkind(t, subkind_transient_map);
    const h = Heap.asHeapHeader(t);
    const body = transientBody(h);
    const old_v = hamt.valueFromMapHeader(body.inner_header);
    const new_v = try hamt.mapDissoc(heap, old_v, key, elementHash, elementEq);
    body.inner_header = Heap.asHeapHeader(new_v);
    return t;
}

pub fn mapGetBang(
    t: Value,
    key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) TransientError!hamt.MapLookup {
    try assertActiveSubkind(t, subkind_transient_map);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    const v = hamt.valueFromMapHeader(body.inner_header);
    return hamt.mapGet(v, key, elementHash, elementEq);
}

pub fn mapCountBang(t: Value) TransientError!usize {
    try assertActiveSubkind(t, subkind_transient_map);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    const v = hamt.valueFromMapHeader(body.inner_header);
    return hamt.mapCount(v);
}

// =============================================================================
// Public API — transient set ops (subkind 1)
// =============================================================================

pub fn setConjBang(
    heap: *Heap,
    t: Value,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) (TransientError || std.mem.Allocator.Error || error{Overflow})!Value {
    try assertActiveSubkind(t, subkind_transient_set);
    const h = Heap.asHeapHeader(t);
    const body = transientBody(h);
    const old_v = hamt.valueFromSetHeader(body.inner_header);
    const new_v = try hamt.setConj(heap, old_v, elem, elementHash, elementEq);
    body.inner_header = Heap.asHeapHeader(new_v);
    return t;
}

pub fn setDisjBang(
    heap: *Heap,
    t: Value,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) (TransientError || std.mem.Allocator.Error || error{Overflow})!Value {
    try assertActiveSubkind(t, subkind_transient_set);
    const h = Heap.asHeapHeader(t);
    const body = transientBody(h);
    const old_v = hamt.valueFromSetHeader(body.inner_header);
    const new_v = try hamt.setDisj(heap, old_v, elem, elementHash, elementEq);
    body.inner_header = Heap.asHeapHeader(new_v);
    return t;
}

pub fn setContainsBang(
    t: Value,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) TransientError!bool {
    try assertActiveSubkind(t, subkind_transient_set);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    const v = hamt.valueFromSetHeader(body.inner_header);
    return hamt.setContains(v, elem, elementHash, elementEq);
}

pub fn setCountBang(t: Value) TransientError!usize {
    try assertActiveSubkind(t, subkind_transient_set);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    const v = hamt.valueFromSetHeader(body.inner_header);
    return hamt.setCount(v);
}

// =============================================================================
// Public API — transient vector ops (subkind 2)
// =============================================================================

pub fn vectorConjBang(
    heap: *Heap,
    t: Value,
    elem: Value,
) (TransientError || std.mem.Allocator.Error || error{Overflow})!Value {
    try assertActiveSubkind(t, subkind_transient_vector);
    const h = Heap.asHeapHeader(t);
    const body = transientBody(h);
    const old_v = vector.valueFromVectorHeader(body.inner_header);
    const new_v = try vector.conj(heap, old_v, elem);
    body.inner_header = Heap.asHeapHeader(new_v);
    return t;
}

pub fn vectorNthBang(t: Value, idx: usize) TransientError!Value {
    try assertActiveSubkind(t, subkind_transient_vector);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    const v = vector.valueFromVectorHeader(body.inner_header);
    return vector.nth(v, idx);
}

pub fn vectorCountBang(t: Value) TransientError!usize {
    try assertActiveSubkind(t, subkind_transient_vector);
    const body = transientBodyConst(Heap.asHeapHeader(t));
    const v = vector.valueFromVectorHeader(body.inner_header);
    return vector.count(v);
}

// =============================================================================
// GC trace (TRANSIENT.md §10 / GC.md §5)
//
// Wrappers have exactly one outgoing heap reference: `inner_header`.
// Frozen wrappers (owner_token == 0) still trace through
// inner_header; freezing does NOT sever the GC edge. Metadata is not
// attachable on transients (VALUE.md §7), so no meta walk.
// =============================================================================

pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = transientBodyConst(h);
    visitor.mark(body.inner_header);
}

// =============================================================================
// Inline tests
// =============================================================================

// ---- Synthetic element callbacks ----

fn synthHash(x: Value) u64 {
    return x.hashImmediate();
}

fn synthEq(a: Value, b: Value) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    if (a.kind() != b.kind()) return false;
    return switch (a.kind()) {
        .nil, .false_, .true_ => true,
        .fixnum => a.asFixnum() == b.asFixnum(),
        .keyword => a.asKeywordId() == b.asKeywordId(),
        .char => a.asChar() == b.asChar(),
        else => false,
    };
}

// ---- transientFrom / subkind-enum wiring ----

test "TransientBody layout: 16 bytes, owner_token at 0, inner_header at 8" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(TransientBody));
    try testing.expectEqual(@as(usize, 0), @offsetOf(TransientBody, "owner_token"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TransientBody, "inner_header"));
}

test "transientFrom: wraps persistent map; subkind 0; owner_token nonzero" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    try testing.expectEqual(Kind.transient, t.kind());
    try testing.expectEqual(subkind_transient_map, t.subkind());
    const body = transientBodyConst(Heap.asHeapHeader(t));
    try testing.expect(body.owner_token != 0);
    try testing.expect(body.inner_header == Heap.asHeapHeader(m));
}

test "transientFrom: wraps persistent set; subkind 1" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try hamt.setEmpty(&heap);
    const t = try transientFrom(&heap, s);
    try testing.expectEqual(subkind_transient_set, t.subkind());
}

test "transientFrom: wraps persistent vector; subkind 2" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try vector.empty(&heap);
    const t = try transientFrom(&heap, v);
    try testing.expectEqual(subkind_transient_vector, t.subkind());
}

test "transientFrom: rejects non-collection kinds with InvalidTransientInner" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Nil is immediate, not transient-wrappable.
    try testing.expectError(
        TransientError.InvalidTransientInner,
        transientFrom(&heap, value.nilValue()),
    );
    // Fixnum, keyword, symbol — also immediates, all invalid.
    try testing.expectError(
        TransientError.InvalidTransientInner,
        transientFrom(&heap, value.fromFixnum(42).?),
    );
}

test "transientFrom: two calls yield distinct owner tokens" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t1 = try transientFrom(&heap, m);
    const t2 = try transientFrom(&heap, m);
    const b1 = transientBodyConst(Heap.asHeapHeader(t1));
    const b2 = transientBodyConst(Heap.asHeapHeader(t2));
    try testing.expect(b1.owner_token != b2.owner_token);
}

// ---- Map ops ----

test "mapAssocBang + mapGetBang: round-trip on transient map" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    const t2 = try mapAssocBang(&heap, t, value.fromKeywordId(1), value.fromFixnum(100).?, &synthHash, &synthEq);
    // Pointer stability: t and t2 are the same wrapper Value.
    try testing.expect(t.tag == t2.tag and t.payload == t2.payload);
    const lookup = try mapGetBang(t, value.fromKeywordId(1), &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expectEqual(@as(i64, 100), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "mapAssocBang: multiple assoc operations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    var t = try transientFrom(&heap, m);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        t = try mapAssocBang(&heap, t, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 20), try mapCountBang(t));
    i = 0;
    while (i < 20) : (i += 1) {
        const lookup = try mapGetBang(t, value.fromKeywordId(i), &synthHash, &synthEq);
        switch (lookup) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
}

test "mapDissocBang: removes entry, updates count" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    var t = try transientFrom(&heap, m);
    t = try mapAssocBang(&heap, t, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    t = try mapAssocBang(&heap, t, value.fromKeywordId(2), value.fromFixnum(2).?, &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 2), try mapCountBang(t));
    _ = try mapDissocBang(&heap, t, value.fromKeywordId(1), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 1), try mapCountBang(t));
    try testing.expect((try mapGetBang(t, value.fromKeywordId(1), &synthHash, &synthEq)) == .absent);
}

// ---- Set ops ----

test "setConjBang + setContainsBang: round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try hamt.setEmpty(&heap);
    var t = try transientFrom(&heap, s);
    t = try setConjBang(&heap, t, value.fromKeywordId(1), &synthHash, &synthEq);
    t = try setConjBang(&heap, t, value.fromKeywordId(2), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 2), try setCountBang(t));
    try testing.expect(try setContainsBang(t, value.fromKeywordId(1), &synthHash, &synthEq));
    try testing.expect(try setContainsBang(t, value.fromKeywordId(2), &synthHash, &synthEq));
    try testing.expect(!try setContainsBang(t, value.fromKeywordId(999), &synthHash, &synthEq));
}

test "setDisjBang: removes element" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try hamt.setEmpty(&heap);
    var t = try transientFrom(&heap, s);
    t = try setConjBang(&heap, t, value.fromKeywordId(1), &synthHash, &synthEq);
    t = try setDisjBang(&heap, t, value.fromKeywordId(1), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 0), try setCountBang(t));
    try testing.expect(!try setContainsBang(t, value.fromKeywordId(1), &synthHash, &synthEq));
}

// ---- Vector ops ----

test "vectorConjBang + vectorNthBang: round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try vector.empty(&heap);
    var t = try transientFrom(&heap, v);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        t = try vectorConjBang(&heap, t, value.fromFixnum(@intCast(i)).?);
    }
    try testing.expectEqual(@as(usize, 40), try vectorCountBang(t));
    i = 0;
    while (i < 40) : (i += 1) {
        const got = try vectorNthBang(t, i);
        try testing.expectEqual(@as(i64, @intCast(i)), got.asFixnum());
    }
}

// ---- Freeze semantics ----

test "persistentBang: freezes wrapper and returns inner persistent Value" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    var t = try transientFrom(&heap, m);
    t = try mapAssocBang(&heap, t, value.fromKeywordId(1), value.fromFixnum(99).?, &synthHash, &synthEq);
    const frozen = try persistentBang(t);
    try testing.expectEqual(Kind.persistent_map, frozen.kind());
    try testing.expectEqual(@as(usize, 1), hamt.mapCount(frozen));
    // Wrapper's owner_token is now zero.
    const body = transientBodyConst(Heap.asHeapHeader(t));
    try testing.expectEqual(@as(u64, 0), body.owner_token);
}

test "persistentBang: post-freeze ops return TransientFrozen" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    _ = try persistentBang(t);
    // Every op now errors.
    try testing.expectError(
        TransientError.TransientFrozen,
        mapAssocBang(&heap, t, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq),
    );
    try testing.expectError(
        TransientError.TransientFrozen,
        mapDissocBang(&heap, t, value.fromKeywordId(1), &synthHash, &synthEq),
    );
    try testing.expectError(
        TransientError.TransientFrozen,
        mapGetBang(t, value.fromKeywordId(1), &synthHash, &synthEq),
    );
    try testing.expectError(
        TransientError.TransientFrozen,
        mapCountBang(t),
    );
    // persistentBang itself also errors on an already-frozen wrapper.
    try testing.expectError(TransientError.TransientFrozen, persistentBang(t));
}

test "persistentBang: inner_header survives post-freeze (for GC reachability)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    const inner_before = transientBodyConst(Heap.asHeapHeader(t)).inner_header;
    _ = try persistentBang(t);
    const inner_after = transientBodyConst(Heap.asHeapHeader(t)).inner_header;
    try testing.expect(inner_before == inner_after);
}

// ---- Kind-mismatch surface ----

test "mapAssocBang on a set transient returns TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try hamt.setEmpty(&heap);
    const t_set = try transientFrom(&heap, s);
    try testing.expectError(
        TransientError.TransientKindMismatch,
        mapAssocBang(&heap, t_set, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq),
    );
}

test "setConjBang on a map transient returns TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t_map = try transientFrom(&heap, m);
    try testing.expectError(
        TransientError.TransientKindMismatch,
        setConjBang(&heap, t_map, value.fromKeywordId(1), &synthHash, &synthEq),
    );
}

test "vectorConjBang on a map transient returns TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    const t_map = try transientFrom(&heap, m);
    try testing.expectError(
        TransientError.TransientKindMismatch,
        vectorConjBang(&heap, t_map, value.fromFixnum(1).?),
    );
}

test "transient ops on a non-transient Value return TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try hamt.mapEmpty(&heap);
    // Pass a persistent map Value (NOT a transient) to a transient op.
    try testing.expectError(
        TransientError.TransientKindMismatch,
        mapCountBang(m),
    );
}

// ---- Immutability of source persistent ----

test "transient session does not mutate source persistent" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try hamt.mapEmpty(&heap);
    const m1 = try hamt.mapAssoc(&heap, m0, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    // Wrap m1 in a transient, do a bunch of mutations.
    var t = try transientFrom(&heap, m1);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        t = try mapAssocBang(&heap, t, value.fromKeywordId(i + 100), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    _ = try persistentBang(t);
    // m1 MUST still have exactly 1 entry.
    try testing.expectEqual(@as(usize, 1), hamt.mapCount(m1));
    const lookup = hamt.mapGet(m1, value.fromKeywordId(1), &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expectEqual(@as(i64, 1), v.asFixnum()),
        .absent => try testing.expect(false),
    }
    try testing.expect(hamt.mapGet(m1, value.fromKeywordId(100), &synthHash, &synthEq) == .absent);
}
