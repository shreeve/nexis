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
//!     ├─ @import("hash")         (combineOrdered + mixKindDomain)
//!     ├─ @import("string")       (hashHeader + bytesEqual)
//!     ├─ @import("bignum")       (hashHeader + limbsEqual)
//!     └─ @import("list")         (hashSeq + equalSeq, fn-pointer plumbing)
//!       [+ future kinds: persistent_map, persistent_vector, …]
//!
//! No heap-kind module imports `dispatch.zig`. Collection kinds whose
//! hash/equal is recursive over their elements (list, future
//! vector/map/set) take the element callback as a function pointer:
//! `hashSeq(h, &hashValue)` / `equalSeq(a, b, &equal)`. That keeps
//! the dependency graph acyclic while letting collection modules
//! recurse through the full dispatcher.
//!
//! Public API:
//!   - `hashValue(v)`: full hash for any Value. Immediates go through
//!     `value.hashImmediate`; heap kinds go through `heapHashBase` +
//!     the **equality-category** domain mixer (SEMANTICS §3.2).
//!   - `equal(a, b)`: full equality. Bit-identity fast path, then
//!     equality-category check (cross-category → false; within a
//!     cross-kind category → dispatch by category; kind-local →
//!     same-kind routes through `heapEqual` or `eq.equalImmediate`).
//!   - `heapHashBase(v)` / `heapEqual(a, b)`: low-level entry points
//!     exposed for tests and advanced callers who have already
//!     established they hold heap-kind Values.
//!   - `eqCategory(k)`: the equality category a kind belongs to.
//!     Drives both the hash domain byte and the equality dispatch.

const std = @import("std");
const value = @import("value");
const eq = @import("eq");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const string = @import("string");
const list = @import("list");
const bignum = @import("bignum");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;

// =============================================================================
// Equality categories (SEMANTICS.md §2.6 + §3.2)
// =============================================================================

/// Equality category a kind belongs to. Values in different categories
/// are always unequal (even among heap kinds). Values in the same
/// cross-kind category (e.g. `.sequential`) may be `=` even when their
/// physical kinds differ.
pub const EqCategory = enum(u8) {
    kind_local,
    sequential,
    associative,
    set,
};

/// Maps a `Kind` to its equality category. Amended whenever a new
/// cross-kind equality category gains a member. Today `.list` is the
/// only sequential kind; `.persistent_vector` will join when it ships.
pub fn eqCategory(k: Kind) EqCategory {
    return switch (k) {
        .list, .persistent_vector => .sequential,
        .persistent_map => .associative,
        .persistent_set => .set,
        else => .kind_local,
    };
}

/// Shared domain bytes for cross-kind equality categories. Chosen
/// outside the 0..29 valid-Kind range so they can never collide with
/// a real kind byte used by kind-local mixing. Frozen; changing these
/// invalidates any already-serialized hashes (future codec concern).
pub const sequential_domain_byte: u8 = 0xF0;
pub const associative_domain_byte: u8 = 0xF1;
pub const set_domain_byte: u8 = 0xF2;

/// The domain byte fed into `mixKindDomain` for a given kind. For
/// kind-local equality, it's the kind byte itself; for cross-kind
/// categories it's the shared category byte so two different kinds
/// in the same category fold to the same hash when their base hashes
/// match. Pinned in SEMANTICS.md §3.2.
pub fn domainByteForKind(k: Kind) u8 {
    return switch (eqCategory(k)) {
        .kind_local => @intFromEnum(k),
        .sequential => sequential_domain_byte,
        .associative => associative_domain_byte,
        .set => set_domain_byte,
    };
}

// =============================================================================
// Hash dispatch
// =============================================================================

/// Full hash for any Value. Routes immediates to `value.hashImmediate`
/// (the immediate-kind fast path) and heap kinds through
/// `heapHashBase` + the equality-category domain mixer. Result
/// satisfies the bedrock `(= x y) ⇒ (hash x) = (hash y)` invariant
/// end-to-end, including across cross-kind equality categories
/// (sequential collections today; associative / set when those land).
pub fn hashValue(v: Value) u64 {
    const k = v.kind();
    if (k.isHeap()) {
        const base = heapHashBase(v);
        return hash_mod.mixKindDomain(base, domainByteForKind(k));
    }
    // Sentinels (`unbound`, `undef`) panic inside value.hashImmediate
    // via its default switch arm. Immediates are all kind-local in v1.
    return v.hashImmediate();
}

/// Pre-mix heap-kind hash base. Resolves the `*HeapHeader`, switches
/// on kind to the per-kind hasher, extends narrow results to `u64`.
/// Does **not** apply the domain mixer — `hashValue` above owns that
/// final step so every heap kind goes through exactly one mixer
/// with the correct category byte.
pub fn heapHashBase(v: Value) u64 {
    std.debug.assert(v.kind().isHeap());
    const k = v.kind();
    const h = Heap.asHeapHeader(v);
    return switch (k) {
        .string => @as(u64, string.hashHeader(h)),
        .bignum => @as(u64, bignum.hashHeader(h)),
        .list => list.hashSeq(h, &hashValue),
        // Future: .persistent_map, .persistent_set,
        // .persistent_vector, .byte_vector, .typed_vector, .function,
        // .var_, .durable_ref, .transient, .error_, .meta_symbol.
        else => std.debug.panic(
            "dispatch.heapHashBase: kind {s} not implemented",
            .{@tagName(k)},
        ),
    };
}

// =============================================================================
// Equality dispatch
// =============================================================================

/// Full equality for any two Values. Category-aware: two Values in
/// different equality categories are always unequal; within a cross-
/// kind category (e.g. `.sequential`) two Values with different kinds
/// can still be `=`. Handles the bit-identity fast path inline.
pub fn equal(a: Value, b: Value) bool {
    // Identical bits → trivially equal for every immediate kind and
    // for heap kinds when the payload is the same *HeapHeader.
    if (a.tag == b.tag and a.payload == b.payload) return true;
    const ka = a.kind();
    const kb = b.kind();
    const cat_a = eqCategory(ka);
    const cat_b = eqCategory(kb);
    if (cat_a != cat_b) return false;
    // Cross-kind category paths. Today only `.sequential` has members;
    // `.associative` / `.set` join as those kinds ship.
    switch (cat_a) {
        .sequential => return sequentialEqual(a, b),
        .associative, .set, .kind_local => {
            // Kind-local: must be the same kind to compare further.
            // `.associative` / `.set` end up here in v1 because each
            // category has only one kind today; the switch arm grows
            // when a second associative/set kind lands.
            if (ka != kb) return false;
            if (ka.isHeap()) return heapEqual(a, b);
            return eq.equalImmediate(a, b);
        },
    }
}

/// Cross-kind sequential equality. Both operands are known to be in
/// the `.sequential` category but may have different kinds. Today the
/// only sequential kind is `.list`; when `.persistent_vector` ships
/// this function grows a walk that iterates one side as a list and
/// the other as a vector, using a common element-callback shape.
fn sequentialEqual(a: Value, b: Value) bool {
    std.debug.assert(eqCategory(a.kind()) == .sequential);
    std.debug.assert(eqCategory(b.kind()) == .sequential);
    // v1: both sequential kinds are `.list`. When vector lands, add
    // cross-kind arms here (list-vs-vector, vector-vs-list,
    // vector-vs-vector) that walk via a unified element iterator.
    return list.equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &equal);
}

/// Same-kind heap structural compare. Caller (`equal` above, or
/// advanced code that has already done its own kind checks) has
/// established `a.kind() == b.kind()`, `a.kind().isHeap()`, and that
/// the category is `.kind_local` (cross-kind categories route through
/// `sequentialEqual` and friends instead).
pub fn heapEqual(a: Value, b: Value) bool {
    std.debug.assert(a.kind() == b.kind());
    std.debug.assert(a.kind().isHeap());
    const k = a.kind();
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    return switch (k) {
        .string => string.bytesEqual(ah, bh),
        .bignum => bignum.limbsEqual(ah, bh),
        .list => list.equalSeq(ah, bh, &equal),
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

test "equal: cross-kind is false; same-kind immediate delegates to eq.equalImmediate" {
    const n = value.nilValue();
    const f = value.fromBool(false);
    try testing.expect(!equal(n, f)); // nil != false
    const pos = value.fromFloat(0.0);
    const neg = value.fromFloat(-0.0);
    // Signed-zero case: eq.equalImmediate returns true; bit-identity
    // doesn't match. Covered via dispatch.
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

// ---- Bignum kind end-to-end dispatch ----

const bignum_mod = @import("bignum");

test "hashValue / equal: bignum round-trip across distinct allocations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 60;
    const a = try bignum_mod.fromLimbs(&heap, false, &[_]u64{ big, 7 });
    const b = try bignum_mod.fromLimbs(&heap, false, &[_]u64{ big, 7 });
    try testing.expect(a.kind() == .bignum and b.kind() == .bignum);
    try testing.expect(equal(a, b));
    try testing.expectEqual(hashValue(a), hashValue(b));
}

test "equal: bignum is never equal to a fixnum (cross-kind, canonical form prevents overlap)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Large bignum that can't canonicalize to fixnum.
    const big = try bignum_mod.fromLimbs(&heap, false, &[_]u64{ 1, 1 });
    try testing.expect(big.kind() == .bignum);

    // Every fixnum. Cross-kind (both are kind-local, different kinds).
    const small_fx = value.fromFixnum(42).?;
    const zero_fx = value.fromFixnum(0).?;
    try testing.expect(!equal(big, small_fx));
    try testing.expect(!equal(big, zero_fx));
    try testing.expect(hashValue(big) != hashValue(small_fx));
}

test "fromI64 integer-tower boundary: fixnum_max vs fixnum_max + 1 dispatch cleanly" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const at = try bignum_mod.fromI64(&heap, value.fixnum_max);
    const over = try bignum_mod.fromI64(&heap, value.fixnum_max + 1);
    try testing.expect(at.kind() == .fixnum);
    try testing.expect(over.kind() == .bignum);
    // Definitely NOT equal — they differ mathematically by 1.
    try testing.expect(!equal(at, over));
    try testing.expect(hashValue(at) != hashValue(over));
}

test "fromI64 integer-tower boundary: fixnum_min is representable as fixnum (asymmetric i48)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try bignum_mod.fromI64(&heap, value.fixnum_min);
    try testing.expect(v.kind() == .fixnum);
    try testing.expectEqual(value.fixnum_min, v.asFixnum());
}

test "equal: bignum sign flip breaks equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: u64 = @as(u64, 1) << 60;
    const pos = try bignum_mod.fromLimbs(&heap, false, &[_]u64{ big, 1 });
    const neg = try bignum_mod.fromLimbs(&heap, true, &[_]u64{ big, 1 });
    try testing.expect(!equal(pos, neg));
    try testing.expect(hashValue(pos) != hashValue(neg));
}

test "canonicalization invariant: fromLimbs with trailing zeros + fixnum-range tail folds to fixnum" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Input has a real fixnum-range limb and trailing zeros; must
    // canonicalize to a fixnum Value, not a bignum.
    const v = try bignum_mod.fromLimbs(&heap, false, &[_]u64{ 42, 0, 0 });
    try testing.expect(v.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 42), v.asFixnum());
    // Equality against a directly-constructed fixnum.
    const direct = value.fromFixnum(42).?;
    try testing.expect(equal(v, direct));
    try testing.expectEqual(hashValue(v), hashValue(direct));
}

// ---- List kind end-to-end dispatch ----

const list_mod = @import("list");

test "hashValue / equal: empty list round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try list_mod.empty(&heap);
    const b = try list_mod.empty(&heap);
    try testing.expect(equal(a, b));
    try testing.expectEqual(hashValue(a), hashValue(b));
}

test "hashValue / equal: (list 1 2 3) across two allocations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    };
    const a = try list_mod.fromSlice(&heap, &elems);
    const b = try list_mod.fromSlice(&heap, &elems);
    try testing.expect(equal(a, b));
    try testing.expectEqual(hashValue(a), hashValue(b));
}

test "hashValue / equal: nested lists recurse through dispatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Outer list whose first element is itself a list; hashes and
    // equality must walk both levels through the dispatch callback.
    const inner_a = try list_mod.fromSlice(&heap, &.{
        value.fromFixnum(7).?,
        value.fromFixnum(8).?,
    });
    const inner_b = try list_mod.fromSlice(&heap, &.{
        value.fromFixnum(7).?,
        value.fromFixnum(8).?,
    });
    const outer_a = try list_mod.fromSlice(&heap, &.{ inner_a, value.fromFixnum(99).? });
    const outer_b = try list_mod.fromSlice(&heap, &.{ inner_b, value.fromFixnum(99).? });

    try testing.expect(equal(outer_a, outer_b));
    try testing.expectEqual(hashValue(outer_a), hashValue(outer_b));
}

test "equal: empty list is NOT equal to nil (cross-category)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const e = try list_mod.empty(&heap);
    const n = value.nilValue();
    // nil is kind_local (.nil), list is sequential → cross-category.
    try testing.expect(!equal(e, n));
    try testing.expect(!equal(n, e));
}

test "hashValue: sequential domain differs from string's kind domain" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Construct a list and a string whose base hashes might coincide;
    // verify the full hashValue outputs differ because their domain
    // bytes differ.
    const lst = try list_mod.empty(&heap);
    const s = try string.fromBytes(&heap, "");

    // Base hashes are independent streams. We only assert the domain
    // mixer fully separates the kinds under hashValue.
    try testing.expect(hashValue(lst) != hashValue(s));

    // domainByteForKind returns the sequential byte for list, the
    // kind byte for string. Confirm directly.
    try testing.expectEqual(sequential_domain_byte, domainByteForKind(.list));
    try testing.expectEqual(@intFromEnum(Kind.string), domainByteForKind(.string));
}

test "eqCategory + domainByteForKind: exhaustive table matches SEMANTICS §2.6/§3.2" {
    // Exhaustive table over every Kind in v1. This test is the
    // primary defense against silent drift between the equality-
    // category rule and the hash-domain rule; a missed entry here
    // would create a subtle `(= x y) ⇒ hash(x) = hash(y)` bug.
    const cases = [_]struct {
        kind: Kind,
        cat: EqCategory,
        domain: u8,
    }{
        // Immediates — all kind-local in v1.
        .{ .kind = .nil, .cat = .kind_local, .domain = 0 },
        .{ .kind = .false_, .cat = .kind_local, .domain = 1 },
        .{ .kind = .true_, .cat = .kind_local, .domain = 2 },
        .{ .kind = .char, .cat = .kind_local, .domain = 3 },
        .{ .kind = .fixnum, .cat = .kind_local, .domain = 4 },
        .{ .kind = .float, .cat = .kind_local, .domain = 5 },
        .{ .kind = .keyword, .cat = .kind_local, .domain = 6 },
        .{ .kind = .symbol, .cat = .kind_local, .domain = 7 },
        // Heap kinds — most are kind-local; sequentials share 0xF0,
        // associative shares 0xF1, set shares 0xF2.
        .{ .kind = .string, .cat = .kind_local, .domain = 16 },
        .{ .kind = .bignum, .cat = .kind_local, .domain = 17 },
        .{ .kind = .persistent_map, .cat = .associative, .domain = associative_domain_byte },
        .{ .kind = .persistent_set, .cat = .set, .domain = set_domain_byte },
        .{ .kind = .persistent_vector, .cat = .sequential, .domain = sequential_domain_byte },
        .{ .kind = .list, .cat = .sequential, .domain = sequential_domain_byte },
        .{ .kind = .byte_vector, .cat = .kind_local, .domain = 22 },
        .{ .kind = .typed_vector, .cat = .kind_local, .domain = 23 },
        .{ .kind = .function, .cat = .kind_local, .domain = 24 },
        .{ .kind = .var_, .cat = .kind_local, .domain = 25 },
        .{ .kind = .durable_ref, .cat = .kind_local, .domain = 26 },
        .{ .kind = .transient, .cat = .kind_local, .domain = 27 },
        .{ .kind = .error_, .cat = .kind_local, .domain = 28 },
        .{ .kind = .meta_symbol, .cat = .kind_local, .domain = 29 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.cat, eqCategory(c.kind));
        try testing.expectEqual(c.domain, domainByteForKind(c.kind));
    }
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
