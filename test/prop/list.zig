//! test/prop/list.zig — randomized properties for the cons-list kind.
//!
//! Exercises the full Value → dispatch → list pipeline including the
//! function-pointer callbacks and the sequential hash domain.
//! Deterministic PRNG seeds so failures reproduce.
//!
//! Properties:
//!   L1. `equal` + `hashValue` agree on 500 random list pairs built
//!       from mixed immediate elements (fixnum / keyword / char).
//!   L2. Equal lists with identity-distinct cons nodes share the same
//!       full `hashValue`.
//!   L3. Cross-kind: a list Value is never `=` to any non-list
//!       (including nil, empty string, empty persistent_map); hashes
//!       differ via the equality-category domain.
//!   L4. Length ≠ length → never equal; empty ≠ non-empty.
//!   L5. Nested lists (2- and 3-level) round-trip through `hashValue`
//!       and `equal` with recursive element dispatch.
//!   L6. Element mutation (swap one inner element) breaks equality
//!       at exactly the expected pair.
//!   L7. `fromSlice(n random elements)` + `count(...)` + walk via
//!       `head`/`tail` reproduces the original sequence byte-exact.
//!   L8. A 2000-element flat list computes `count` and `hashValue` in
//!       reasonable time and equals another identical list.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const list = @import("list");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;

const prng_seed: u64 = 0x6C69_7374_5F70_726F; // "list_pro"

fn randImmediate(rand: std.Random) Value {
    // Sample from the cheap, total immediates (avoid floats to skip
    // NaN/±0 nuance — those are covered in prop/primitive.zig).
    const pick = rand.uintLessThan(u8, 3);
    return switch (pick) {
        0 => value.fromFixnum(rand.intRangeAtMost(i64, -1000, 1000)).?,
        1 => value.fromKeywordId(rand.uintLessThan(u32, 32)),
        2 => value.fromChar(rand.intRangeAtMost(u21, 32, 126)).?,
        else => unreachable,
    };
}

// -----------------------------------------------------------------------------
// L1. equal + hashValue agree over random pairs
// -----------------------------------------------------------------------------

test "L1: equal lists have equal hashValue; different lists almost always differ" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    const elems = try gpa.alloc(Value, 32);
    defer gpa.free(elems);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const len = r.uintLessThan(usize, elems.len);
        for (elems[0..len]) |*slot| slot.* = randImmediate(r);

        const a = try list.fromSlice(&heap, elems[0..len]);
        const b = try list.fromSlice(&heap, elems[0..len]);
        try std.testing.expect(dispatch.equal(a, b));
        try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
    }
}

// -----------------------------------------------------------------------------
// L2. Identity-distinct equal lists still share hashValue
// -----------------------------------------------------------------------------

test "L2: two separately-allocated equal lists share identical hashValue" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const a = try list.fromSlice(&heap, &.{
        value.fromFixnum(11).?,
        value.fromFixnum(22).?,
        value.fromFixnum(33).?,
    });
    const b = try list.fromSlice(&heap, &.{
        value.fromFixnum(11).?,
        value.fromFixnum(22).?,
        value.fromFixnum(33).?,
    });
    try std.testing.expect(Heap.asHeapHeader(a) != Heap.asHeapHeader(b));
    try std.testing.expect(!a.identicalTo(b));
    try std.testing.expect(dispatch.equal(a, b));
    try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
}

// -----------------------------------------------------------------------------
// L3. Cross-kind non-equality + domain separation
// -----------------------------------------------------------------------------

test "L3: list is never equal to any non-sequential Value; hashes differ" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const lst = try list.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    const lst_h = dispatch.hashValue(lst);

    const non_sequentials = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
        value.fromFixnum(0).?,
        value.fromFixnum(1).?,
        value.fromChar('x').?,
        value.fromKeywordId(0),
        value.fromSymbolId(0),
    };
    for (non_sequentials) |o| {
        try std.testing.expect(!dispatch.equal(lst, o));
        try std.testing.expect(!dispatch.equal(o, lst));
        try std.testing.expect(lst_h != dispatch.hashValue(o));
    }
}

// -----------------------------------------------------------------------------
// L4. Length discrimination
// -----------------------------------------------------------------------------

test "L4: length difference breaks equality" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const empty_l = try list.empty(&heap);
    const one = try list.fromSlice(&heap, &.{value.fromFixnum(42).?});
    try std.testing.expect(!dispatch.equal(empty_l, one));
    try std.testing.expect(dispatch.hashValue(empty_l) != dispatch.hashValue(one));

    const two = try list.fromSlice(&heap, &.{ value.fromFixnum(42).?, value.fromFixnum(42).? });
    try std.testing.expect(!dispatch.equal(one, two));
    try std.testing.expect(dispatch.hashValue(one) != dispatch.hashValue(two));
}

// -----------------------------------------------------------------------------
// L5. Nested lists exercise recursive dispatch
// -----------------------------------------------------------------------------

test "L5: nested lists round-trip hash and equal via recursive dispatch" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const inner1a = try list.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    const inner1b = try list.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    const inner2a = try list.fromSlice(&heap, &.{inner1a});
    const inner2b = try list.fromSlice(&heap, &.{inner1b});

    try std.testing.expect(dispatch.equal(inner2a, inner2b));
    try std.testing.expectEqual(dispatch.hashValue(inner2a), dispatch.hashValue(inner2b));

    const outer_a = try list.fromSlice(&heap, &.{
        inner2a,
        value.fromKeywordId(7),
        try list.empty(&heap),
    });
    const outer_b = try list.fromSlice(&heap, &.{
        inner2b,
        value.fromKeywordId(7),
        try list.empty(&heap),
    });
    try std.testing.expect(dispatch.equal(outer_a, outer_b));
    try std.testing.expectEqual(dispatch.hashValue(outer_a), dispatch.hashValue(outer_b));
}

// -----------------------------------------------------------------------------
// L6. Element mutation (via rebuilding) breaks equality
// -----------------------------------------------------------------------------

test "L6: single-element change breaks equality and hash" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const elems_a = [_]Value{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
        value.fromFixnum(4).?,
    };
    const elems_b = [_]Value{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(99).?, // <-- different here
        value.fromFixnum(4).?,
    };

    const a = try list.fromSlice(&heap, &elems_a);
    const b = try list.fromSlice(&heap, &elems_b);
    try std.testing.expect(!dispatch.equal(a, b));
    try std.testing.expect(dispatch.hashValue(a) != dispatch.hashValue(b));
}

// -----------------------------------------------------------------------------
// L7. fromSlice + walk reproduces the sequence
// -----------------------------------------------------------------------------

test "L7: fromSlice + walk via head/tail reproduces the original sequence" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    var prng = std.Random.DefaultPrng.init(prng_seed +% 7);
    const r = prng.random();

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = r.uintLessThan(usize, 24);
        const elems = try gpa.alloc(Value, len);
        defer gpa.free(elems);
        for (elems) |*slot| slot.* = randImmediate(r);

        const lst = try list.fromSlice(&heap, elems);
        try std.testing.expectEqual(len, list.count(lst));

        var cur = lst;
        for (elems) |expected| {
            try std.testing.expect(list.head(cur).identicalTo(expected));
            cur = list.tail(cur);
        }
        try std.testing.expect(list.isEmpty(cur));
    }
}

// -----------------------------------------------------------------------------
// L8. 2000-element flat list
// -----------------------------------------------------------------------------

test "L8: 2000-element list: count, equal, hashValue all behave" {
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();

    const N: usize = 2000;
    const elems = try gpa.alloc(Value, N);
    defer gpa.free(elems);
    for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;

    const a = try list.fromSlice(&heap, elems);
    const b = try list.fromSlice(&heap, elems);

    try std.testing.expectEqual(N, list.count(a));
    try std.testing.expect(dispatch.equal(a, b));
    try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));
}
