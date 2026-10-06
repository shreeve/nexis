//! coll/transient.zig — transient kind.
//!
//! Authoritative spec: `docs/TRANSIENT.md` (§1 in-place edits, §4 the
//! edit token, §5 the active/frozen states). Derivative semantics:
//! `docs/SEMANTICS.md` §2.6 (identity equality and hash),
//! `docs/CODEC.md` §3 (not serializable), `docs/VALUE.md` §2.2 (kind
//! 27, local-enum subkinds 0/1/2), `docs/GC.md` §5 (trace contract),
//! CLOJURE-REVIEW §1.2, §3.5.
//!
//! A transient holds a root of its own and an edit token; the `!`
//! operations edit that root and every node stamped with the token in
//! place, and copy any other node once, stamping the copy
//! (`vector.conjInPlace`, `champ.mapPut`, …). `persistent!` zeroes the
//! wrapper's token, so no edit reaches those nodes again.
//!
//! Token discipline enforced at every public entry point:
//!   - `owner_token == 0` → frozen; all ops return `error.TransientFrozen`.
//!   - Non-transient Value → `error.TransientKindMismatch`.
//!   - Wrong subkind (mapAssocBang on a set wrapper) →
//!     `error.TransientKindMismatch`.
//!
//! Imports: value, heap, `champ.zig` and `vector.zig` (never
//! dispatch; hash and equality arrive as callbacks). Importers: the
//! `.transient` arms of `src/dispatch.zig`, `src/gc.zig` (this
//! module's `trace`), `src/codec.zig` and `src/stdlib.zig`.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const champ = @import("champ.zig");
const vector = @import("vector.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

const ElementHash = *const fn (Value) u64;
const ElementEq = *const fn (Value, Value) bool;
/// The count of comparisons and hashes that ran past the stack guard
/// (`dispatch.spoilCount`, SEMANTICS §2.7): an edit whose lookup
/// raised it changes nothing.
const Overflows = *const fn () u64;

// =============================================================================
// Subkind taxonomy (TRANSIENT.md §2 local enum, VALUE.md §2.2)
// =============================================================================

pub const subkind_transient_map: u16 = 0;
pub const subkind_transient_set: u16 = 1;
pub const subkind_transient_vector: u16 = 2;

// =============================================================================
// Error set (TRANSIENT.md §6)
// =============================================================================

pub const TransientError = error{
    /// Op called on a frozen transient (owner_token == 0), after
    /// `persistentBang`.
    TransientFrozen,
    /// `transientFrom` called on a Value whose kind is not a valid
    /// transient inner (must be .persistent_map / .persistent_set /
    /// .persistent_vector).
    InvalidTransientInner,
    /// Transient op family mismatch — e.g. `mapAssocBang` called on
    /// a set wrapper, or any transient op on a non-transient Value.
    TransientKindMismatch,
};

const EditError = TransientError || std.mem.Allocator.Error || error{Overflow};

// =============================================================================
// Wrapper layout (TRANSIENT.md §3)
// =============================================================================

const TransientBody = extern struct {
    /// 0 = frozen; nonzero = active, the edit token (26 bits,
    /// `heap.edit_token_max`) its nodes carry.
    owner_token: u64,

    /// The root the transient owns. Never null on a well-formed
    /// wrapper; an edit that outgrows an array form or empties a trie
    /// replaces it.
    inner_header: *HeapHeader,

    comptime {
        std.debug.assert(@sizeOf(TransientBody) == 16);
        std.debug.assert(@offsetOf(TransientBody, "owner_token") == 0);
        std.debug.assert(@offsetOf(TransientBody, "inner_header") == 8);
    }
};

// =============================================================================
// Edit tokens (TRANSIENT.md §4)
// =============================================================================

/// The next edit token of `heap`, never 0 and never one a node of the
/// heap carries. When the clock would wrap, every map, set and vector
/// block of the heap forgets its token (a root forgets its cached
/// hash, which is recomputed) and every active transient takes a new
/// one, so the clock restarts clear. That reaches every holder of a
/// token because a token never leaves a wrapper: each edit reads its
/// wrapper's at the edit (TRANSIENT.md §4).
fn issueEditToken(heap: *Heap) u32 {
    if (heap.edit_clock == heap_mod.edit_token_max) retireEditTokens(heap);
    heap.edit_clock += 1;
    return heap.edit_clock;
}

fn retireEditTokens(heap: *Heap) void {
    const Retire = struct {
        issued: u32 = 0,
        pub fn visit(self: *@This(), h: *HeapHeader) void {
            switch (@as(Kind, @fromBackingInt(@intCast(h.kind)))) {
                .persistent_map, .persistent_set, .persistent_vector => h.hash = 0,
                .transient => {
                    const body = transientBody(h);
                    if (body.owner_token != 0) {
                        self.issued += 1;
                        body.owner_token = self.issued;
                    }
                },
                else => {},
            }
        }
    };
    var retire: Retire = .{};
    heap.forEachLive(&retire);
    heap.edit_clock = retire.issued;
}

// =============================================================================
// Body accessors and validation
// =============================================================================

fn transientBody(h: *HeapHeader) *TransientBody {
    return Heap.bodyOf(TransientBody, h);
}

/// The body of an active transient of `subkind`.
fn activeBody(t: Value, subkind: u16) TransientError!*TransientBody {
    if (t.kind() != .transient or t.subkind() != subkind) return TransientError.TransientKindMismatch;
    const body = transientBody(Heap.asHeapHeader(t));
    if (body.owner_token == 0) return TransientError.TransientFrozen;
    return body;
}

inline fn editOf(body: *const TransientBody) u32 {
    return @intCast(body.owner_token);
}

fn innerValueForSubkind(subkind: u16, h: *HeapHeader) Value {
    return switch (subkind) {
        subkind_transient_map => champ.valueFromMapHeader(h),
        subkind_transient_set => champ.valueFromSetHeader(h),
        subkind_transient_vector => vector.valueFromVectorHeader(h),
        else => unreachable,
    };
}

// =============================================================================
// Public API — wrapping and unwrapping
// =============================================================================

/// Wrap a persistent map/set/vector Value as a fresh active transient
/// over a copy of its root, without metadata. Returns
/// `error.InvalidTransientInner` on any other kind.
pub fn transientFrom(heap: *Heap, persistent_v: Value) EditError!Value {
    const subkind: u16 = switch (persistent_v.kind()) {
        .persistent_map => subkind_transient_map,
        .persistent_set => subkind_transient_set,
        .persistent_vector => subkind_transient_vector,
        else => return TransientError.InvalidTransientInner,
    };
    const src = Heap.asHeapHeader(persistent_v);
    const root = if (subkind == subkind_transient_vector) try vector.copyRoot(heap, src) else try champ.copyRoot(heap, src);
    const h = try heap.alloc(.transient, @sizeOf(TransientBody));
    transientBody(h).* = .{ .owner_token = issueEditToken(heap), .inner_header = root };
    return .{
        .tag = @as(u64, @backingInt(Kind.transient)) | (@as(u64, subkind) << 16),
        .payload = @intFromPtr(h),
    };
}

/// Freeze the transient and return the collection it holds, safe to
/// share: its token is zeroed, so no edit reaches its nodes again.
pub fn persistentBang(t: Value) TransientError!Value {
    if (t.kind() != .transient) return TransientError.TransientKindMismatch;
    const body = transientBody(Heap.asHeapHeader(t));
    if (body.owner_token == 0) return TransientError.TransientFrozen;
    body.owner_token = 0;
    return innerValueForSubkind(t.subkind(), body.inner_header);
}

// =============================================================================
// Public API — transient map ops (subkind 0)
//
// Each edit locates its key first, doing every hash and comparison,
// and changes nothing when that raised `overflows` (TRANSIENT.md §6).
// =============================================================================

pub fn mapAssocBang(heap: *Heap, t: Value, key: Value, val: Value, elementHash: ElementHash, elementEq: ElementEq, overflows: Overflows) EditError!Value {
    const body = try activeBody(t, subkind_transient_map);
    const before = overflows();
    const spot = champ.mapLocate(champ.valueFromMapHeader(body.inner_header), key, elementHash, elementEq);
    if (overflows() != before) return t;
    body.inner_header = try champ.mapPut(heap, body.inner_header, spot, key, val, editOf(body));
    return t;
}

pub fn mapDissocBang(heap: *Heap, t: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq, overflows: Overflows) EditError!Value {
    const body = try activeBody(t, subkind_transient_map);
    const before = overflows();
    const spot = champ.mapLocate(champ.valueFromMapHeader(body.inner_header), key, elementHash, elementEq);
    if (overflows() != before or !champ.mapSpotPresent(spot)) return t;
    body.inner_header = try champ.mapDrop(heap, body.inner_header, spot, editOf(body));
    return t;
}

/// Where `key` is or would go in a transient map: an edit's hashes
/// and comparisons, and no change. A native that reads a key's value
/// and then stores under it (`frequencies`, `group-by`) looks once.
pub fn mapLocateBang(t: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) TransientError!champ.MapSpot {
    const body = try activeBody(t, subkind_transient_map);
    return champ.mapLocate(champ.valueFromMapHeader(body.inner_header), key, elementHash, elementEq);
}

/// Store `key → val` where `mapLocateBang` found, the map unchanged
/// since.
pub fn mapPutBang(heap: *Heap, t: Value, spot: champ.MapSpot, key: Value, val: Value) EditError!void {
    const body = try activeBody(t, subkind_transient_map);
    body.inner_header = try champ.mapPut(heap, body.inner_header, spot, key, val, editOf(body));
}

/// Append `elem` to `v`, a vector of the native's own that only the
/// transient map `t` reaches (`group-by`'s buckets), editing it under
/// `t`'s token so `persistent!` freezes it with the map. The token is
/// read at the edit: no native holds one (§4).
pub fn vectorConjUnderBang(heap: *Heap, t: Value, v: Value, elem: Value) EditError!void {
    const body = try activeBody(t, subkind_transient_map);
    try vector.conjInPlace(heap, Heap.asHeapHeader(v), elem, editOf(body));
}

pub fn mapGetBang(t: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) TransientError!champ.MapLookup {
    const body = try activeBody(t, subkind_transient_map);
    return champ.mapGet(champ.valueFromMapHeader(body.inner_header), key, elementHash, elementEq);
}

pub fn mapCountBang(t: Value) TransientError!usize {
    const body = try activeBody(t, subkind_transient_map);
    return champ.mapCount(champ.valueFromMapHeader(body.inner_header));
}

// =============================================================================
// Public API — transient set ops (subkind 1)
// =============================================================================

pub fn setConjBang(heap: *Heap, t: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq, overflows: Overflows) EditError!Value {
    const body = try activeBody(t, subkind_transient_set);
    const before = overflows();
    const spot = champ.setLocate(champ.valueFromSetHeader(body.inner_header), elem, elementHash, elementEq);
    if (overflows() != before) return t;
    body.inner_header = try champ.setPut(heap, body.inner_header, spot, elem, editOf(body));
    return t;
}

pub fn setDisjBang(heap: *Heap, t: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq, overflows: Overflows) EditError!Value {
    const body = try activeBody(t, subkind_transient_set);
    const before = overflows();
    const spot = champ.setLocate(champ.valueFromSetHeader(body.inner_header), elem, elementHash, elementEq);
    if (overflows() != before or !champ.setSpotPresent(spot)) return t;
    body.inner_header = try champ.setDrop(heap, body.inner_header, spot, editOf(body));
    return t;
}

pub fn setContainsBang(t: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) TransientError!bool {
    return try setGetBang(t, elem, elementHash, elementEq) != null;
}

/// The element of transient set `t` equal to `elem`, as it holds it
/// (`champ.setGet`), or null.
pub fn setGetBang(t: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) TransientError!?Value {
    const body = try activeBody(t, subkind_transient_set);
    return champ.setGet(champ.valueFromSetHeader(body.inner_header), elem, elementHash, elementEq);
}

pub fn setCountBang(t: Value) TransientError!usize {
    const body = try activeBody(t, subkind_transient_set);
    return champ.setCount(champ.valueFromSetHeader(body.inner_header));
}

// =============================================================================
// Public API — transient vector ops (subkind 2)
// =============================================================================

pub fn vectorConjBang(heap: *Heap, t: Value, elem: Value) EditError!Value {
    const body = try activeBody(t, subkind_transient_vector);
    try vector.conjInPlace(heap, body.inner_header, elem, editOf(body));
    return t;
}

/// For a native building a vector a leaf at a time: 32 slots opened
/// at the end of the vector, whose tail is full
/// (`vector.openTailInPlace`). The transient must not be read until
/// `vectorCloseTailBang` gives the tail its length.
pub fn vectorOpenTailBang(heap: *Heap, t: Value) EditError!*[vector.branch_factor]Value {
    const body = try activeBody(t, subkind_transient_vector);
    return vector.openTailInPlace(heap, body.inner_header, editOf(body));
}

/// The tail `vectorOpenTailBang` opened holds its first `len` slots.
pub fn vectorCloseTailBang(t: Value, len: u32) TransientError!void {
    const body = try activeBody(t, subkind_transient_vector);
    vector.closeTailInPlace(body.inner_header, len);
}

/// `(assoc! t idx elem)`: replaces element `idx`, or appends when
/// `idx` is the count (as Clojure's `assoc!` on a transient vector).
/// `error.IndexOutOfBounds` beyond that.
pub fn vectorAssocBang(heap: *Heap, t: Value, idx: usize, elem: Value) (EditError || error{IndexOutOfBounds})!Value {
    const body = try activeBody(t, subkind_transient_vector);
    const n = vector.count(vector.valueFromVectorHeader(body.inner_header));
    if (idx > n) return error.IndexOutOfBounds;
    if (idx == n) {
        try vector.conjInPlace(heap, body.inner_header, elem, editOf(body));
    } else {
        try vector.assocInPlace(heap, body.inner_header, idx, elem, editOf(body));
    }
    return t;
}

/// `(pop! t)`: drops the last element. `error.IndexOutOfBounds` on an
/// empty vector.
pub fn vectorPopBang(heap: *Heap, t: Value) (EditError || error{IndexOutOfBounds})!Value {
    const body = try activeBody(t, subkind_transient_vector);
    if (vector.isEmpty(vector.valueFromVectorHeader(body.inner_header))) return error.IndexOutOfBounds;
    try vector.popInPlace(heap, body.inner_header, editOf(body));
    return t;
}

pub fn vectorNthBang(t: Value, idx: usize) TransientError!Value {
    const body = try activeBody(t, subkind_transient_vector);
    return vector.nth(vector.valueFromVectorHeader(body.inner_header), idx);
}

pub fn vectorCountBang(t: Value) TransientError!usize {
    const body = try activeBody(t, subkind_transient_vector);
    return vector.count(vector.valueFromVectorHeader(body.inner_header));
}

// =============================================================================
// GC trace (TRANSIENT.md §10 / GC.md §5)
//
// Wrappers have exactly one outgoing heap reference: `inner_header`.
// Frozen wrappers (owner_token == 0) still trace through
// inner_header; freezing does NOT sever the GC edge. Metadata is not
// attachable on transients (SEMANTICS.md §7), so no meta walk.
// =============================================================================

pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = transientBody(h);
    visitor.mark(body.inner_header);
}

// =============================================================================
// Inline tests
// =============================================================================

// ---- Synthetic element callbacks ----

const synthHash = Value.hashImmediate;

fn noOverflows() u64 {
    return 0;
}

const synthEq = value.testEqual;

// ---- transientFrom / subkind-enum wiring ----

test "TransientBody layout: 16 bytes, owner_token at 0, inner_header at 8" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(TransientBody));
    try testing.expectEqual(@as(usize, 0), @offsetOf(TransientBody, "owner_token"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(TransientBody, "inner_header"));
}

test "transientFrom: wraps a copy of a persistent map's root; subkind 0; owner_token nonzero" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    try testing.expectEqual(Kind.transient, t.kind());
    try testing.expectEqual(subkind_transient_map, t.subkind());
    const body = transientBody(Heap.asHeapHeader(t));
    try testing.expect(body.owner_token != 0);
    try testing.expect(body.inner_header != Heap.asHeapHeader(m));
    try testing.expectEqual(@as(usize, 0), champ.mapCount(champ.valueFromMapHeader(body.inner_header)));
}

test "transientFrom: wraps persistent set; subkind 1" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try champ.setEmpty(&heap);
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
    const m = try champ.mapEmpty(&heap);
    const t1 = try transientFrom(&heap, m);
    const t2 = try transientFrom(&heap, m);
    const b1 = transientBody(Heap.asHeapHeader(t1));
    const b2 = transientBody(Heap.asHeapHeader(t2));
    try testing.expect(b1.owner_token != b2.owner_token);
}

// ---- Map ops ----

test "mapAssocBang + mapGetBang: round-trip on transient map" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    const t2 = try mapAssocBang(&heap, t, value.testKeyword(1), value.fromFixnum(100).?, &synthHash, &synthEq, &noOverflows);
    // Pointer stability: t and t2 are the same wrapper Value.
    try testing.expect(t.tag == t2.tag and t.payload == t2.payload);
    const lookup = try mapGetBang(t, value.testKeyword(1), &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expectEqual(@as(i64, 100), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "mapAssocBang: multiple assoc operations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    var t = try transientFrom(&heap, m);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        t = try mapAssocBang(&heap, t, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq, &noOverflows);
    }
    try testing.expectEqual(@as(usize, 20), try mapCountBang(t));
    i = 0;
    while (i < 20) : (i += 1) {
        const lookup = try mapGetBang(t, value.testKeyword(i), &synthHash, &synthEq);
        switch (lookup) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
}

test "mapDissocBang: removes entry, updates count" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    var t = try transientFrom(&heap, m);
    t = try mapAssocBang(&heap, t, value.testKeyword(1), value.fromFixnum(1).?, &synthHash, &synthEq, &noOverflows);
    t = try mapAssocBang(&heap, t, value.testKeyword(2), value.fromFixnum(2).?, &synthHash, &synthEq, &noOverflows);
    try testing.expectEqual(@as(usize, 2), try mapCountBang(t));
    _ = try mapDissocBang(&heap, t, value.testKeyword(1), &synthHash, &synthEq, &noOverflows);
    try testing.expectEqual(@as(usize, 1), try mapCountBang(t));
    try testing.expect((try mapGetBang(t, value.testKeyword(1), &synthHash, &synthEq)) == .absent);
}

// ---- Set ops ----

test "setConjBang + setContainsBang: round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try champ.setEmpty(&heap);
    var t = try transientFrom(&heap, s);
    t = try setConjBang(&heap, t, value.testKeyword(1), &synthHash, &synthEq, &noOverflows);
    t = try setConjBang(&heap, t, value.testKeyword(2), &synthHash, &synthEq, &noOverflows);
    try testing.expectEqual(@as(usize, 2), try setCountBang(t));
    try testing.expect(try setContainsBang(t, value.testKeyword(1), &synthHash, &synthEq));
    try testing.expect(try setContainsBang(t, value.testKeyword(2), &synthHash, &synthEq));
    try testing.expect(!try setContainsBang(t, value.testKeyword(999), &synthHash, &synthEq));
}

test "setDisjBang: removes element" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try champ.setEmpty(&heap);
    var t = try transientFrom(&heap, s);
    t = try setConjBang(&heap, t, value.testKeyword(1), &synthHash, &synthEq, &noOverflows);
    t = try setDisjBang(&heap, t, value.testKeyword(1), &synthHash, &synthEq, &noOverflows);
    try testing.expectEqual(@as(usize, 0), try setCountBang(t));
    try testing.expect(!try setContainsBang(t, value.testKeyword(1), &synthHash, &synthEq));
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

test "vectorAssocBang + vectorPopBang: replace, append at count, pop to empty" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const t = try transientFrom(&heap, try vector.empty(&heap));
    for (0..40) |i| _ = try vectorAssocBang(&heap, t, i, value.fromFixnum(@intCast(i)).?);
    try testing.expectEqual(@as(usize, 40), try vectorCountBang(t));
    _ = try vectorAssocBang(&heap, t, 3, value.fromFixnum(-3).?);
    try testing.expectEqual(@as(i64, -3), (try vectorNthBang(t, 3)).asFixnum());
    try testing.expectError(error.IndexOutOfBounds, vectorAssocBang(&heap, t, 41, value.nilValue()));
    var n: usize = 40;
    while (n > 0) : (n -= 1) {
        try testing.expectEqual(@as(i64, if (n == 4) -3 else @intCast(n - 1)), (try vectorNthBang(t, n - 1)).asFixnum());
        _ = try vectorPopBang(&heap, t);
    }
    try testing.expectError(error.IndexOutOfBounds, vectorPopBang(&heap, t));
    _ = try persistentBang(t);
    try testing.expectError(TransientError.TransientFrozen, vectorPopBang(&heap, t));
    try testing.expectError(TransientError.TransientFrozen, vectorAssocBang(&heap, t, 0, value.nilValue()));
}

// ---- In-place edits ----

test "in place: a vector transient's conj! fills its owned tail without allocating" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const t = try transientFrom(&heap, try vector.fromSlice(&heap, &.{value.fromFixnum(0).?}));
    // The 33rd element starts a tail with room for a leaf.
    for (1..33) |i| _ = try vectorConjBang(&heap, t, value.fromFixnum(@intCast(i)).?);
    const live = heap.liveCount();
    for (33..64) |i| _ = try vectorConjBang(&heap, t, value.fromFixnum(@intCast(i)).?);
    _ = try vectorAssocBang(&heap, t, 40, value.fromFixnum(-40).?);
    _ = try vectorAssocBang(&heap, t, 5, value.fromFixnum(-5).?);
    _ = try vectorPopBang(&heap, t);
    // The leaf and the trie are the transient's own: nothing copied.
    try testing.expectEqual(live, heap.liveCount());
    const v = try persistentBang(t);
    try testing.expectEqual(@as(usize, 63), vector.count(v));
    try testing.expectEqual(@as(i64, -5), vector.nth(v, 5).asFixnum());
    try testing.expectEqual(@as(i64, -40), vector.nth(v, 40).asFixnum());
}

test "in place: a map transient's assoc! over a key it holds allocates nothing" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const t = try transientFrom(&heap, try champ.mapEmpty(&heap));
    for (0..100) |i| _ = try mapAssocBang(&heap, t, value.fromFixnum(@intCast(i)).?, value.nilValue(), &synthHash, &synthEq, &noOverflows);
    const live = heap.liveCount();
    for (0..100) |i| _ = try mapAssocBang(&heap, t, value.fromFixnum(@intCast(i)).?, value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq, &noOverflows);
    try testing.expectEqual(live, heap.liveCount());
}

// ---- Freeze semantics ----

test "persistentBang: freezes wrapper and returns inner persistent Value" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    var t = try transientFrom(&heap, m);
    t = try mapAssocBang(&heap, t, value.testKeyword(1), value.fromFixnum(99).?, &synthHash, &synthEq, &noOverflows);
    const frozen = try persistentBang(t);
    try testing.expectEqual(Kind.persistent_map, frozen.kind());
    try testing.expectEqual(@as(usize, 1), champ.mapCount(frozen));
    // Wrapper's owner_token is now zero.
    const body = transientBody(Heap.asHeapHeader(t));
    try testing.expectEqual(@as(u64, 0), body.owner_token);
}

test "persistentBang: post-freeze ops return TransientFrozen" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    _ = try persistentBang(t);
    // Every op now errors.
    try testing.expectError(
        TransientError.TransientFrozen,
        mapAssocBang(&heap, t, value.testKeyword(1), value.fromFixnum(1).?, &synthHash, &synthEq, &noOverflows),
    );
    try testing.expectError(
        TransientError.TransientFrozen,
        mapDissocBang(&heap, t, value.testKeyword(1), &synthHash, &synthEq, &noOverflows),
    );
    try testing.expectError(
        TransientError.TransientFrozen,
        mapGetBang(t, value.testKeyword(1), &synthHash, &synthEq),
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
    const m = try champ.mapEmpty(&heap);
    const t = try transientFrom(&heap, m);
    const inner_before = transientBody(Heap.asHeapHeader(t)).inner_header;
    _ = try persistentBang(t);
    const inner_after = transientBody(Heap.asHeapHeader(t)).inner_header;
    try testing.expect(inner_before == inner_after);
}

// ---- Kind-mismatch surface ----

test "mapAssocBang on a set transient returns TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try champ.setEmpty(&heap);
    const t_set = try transientFrom(&heap, s);
    try testing.expectError(
        TransientError.TransientKindMismatch,
        mapAssocBang(&heap, t_set, value.testKeyword(1), value.fromFixnum(1).?, &synthHash, &synthEq, &noOverflows),
    );
}

test "setConjBang on a map transient returns TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    const t_map = try transientFrom(&heap, m);
    try testing.expectError(
        TransientError.TransientKindMismatch,
        setConjBang(&heap, t_map, value.testKeyword(1), &synthHash, &synthEq, &noOverflows),
    );
}

test "vectorConjBang on a map transient returns TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
    const t_map = try transientFrom(&heap, m);
    try testing.expectError(
        TransientError.TransientKindMismatch,
        vectorConjBang(&heap, t_map, value.fromFixnum(1).?),
    );
}

test "transient ops on a non-transient Value return TransientKindMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try champ.mapEmpty(&heap);
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
    const m0 = try champ.mapEmpty(&heap);
    const m1 = try champ.mapAssoc(&heap, m0, value.testKeyword(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    // Wrap m1 in a transient, do a bunch of mutations.
    var t = try transientFrom(&heap, m1);
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        t = try mapAssocBang(&heap, t, value.testKeyword(i + 100), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq, &noOverflows);
    }
    _ = try persistentBang(t);
    // m1 MUST still have exactly 1 entry.
    try testing.expectEqual(@as(usize, 1), champ.mapCount(m1));
    const lookup = champ.mapGet(m1, value.testKeyword(1), &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expectEqual(@as(i64, 1), v.asFixnum()),
        .absent => try testing.expect(false),
    }
    try testing.expect(champ.mapGet(m1, value.testKeyword(100), &synthHash, &synthEq) == .absent);
}
