//! coll/list.zig — immutable cons list heap kind (Phase 1).
//!
//! Authoritative spec: `docs/LIST.md`. Physical storage: `src/heap.zig`.
//! Semantics: `docs/SEMANTICS.md` §2.6 (sequential equality category)
//! and §3.2 (sequential-domain hash mixing). This is the first
//! collection kind — its landing amends SEMANTICS.md §3.2 to pin the
//! equality-category-based domain mixer.
//!
//! Subkinds (VALUE.md §2.2):
//!   - 0 = cons  — body is `{ head: Value, tail: Value }` = 32 bytes;
//!         tail is always kind .list (proper lists only).
//!   - 1 = empty — body size 0; the Value alone encodes emptiness.
//!
//! Dispatch plumbing: `hashSeq` and `equalSeq` take function-pointer
//! callbacks (`elementHash`, `elementEq`) for the inner operations so
//! list.zig never imports `dispatch`. The dispatcher passes
//! `&dispatch.hashValue` and `&dispatch.equal` at the kind switch.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Subkind discriminators
// =============================================================================

pub const subkind_cons: u16 = 0;
pub const subkind_empty: u16 = 1;

// =============================================================================
// Cons body — private, always accessed via bodyOf
// =============================================================================

/// Body of a cons cell. Laid out as two consecutive 16-byte Values;
/// `@alignOf(ConsBody) == 16` thanks to Value's own alignment, which
/// satisfies `bodyOf`'s ≤16 alignment contract in heap.zig.
const ConsBody = extern struct {
    head: Value,
    tail: Value,

    comptime {
        std.debug.assert(@sizeOf(ConsBody) == 32);
        std.debug.assert(@offsetOf(ConsBody, "head") == 0);
        std.debug.assert(@offsetOf(ConsBody, "tail") == 16);
    }
};

pub const ListError = error{
    InvalidListTail,
};

// =============================================================================
// Public API — constructors
// =============================================================================

/// Fresh empty list. Not a shared singleton (v1); every call allocates
/// a new heap block of body_size 0. Two empty lists compare `=`; their
/// `identical?` relation depends on allocation identity.
pub fn empty(heap: *Heap) !Value {
    const h = try heap.alloc(.list, 0);
    return valueFrom(h, subkind_empty);
}

/// Prepend `head` onto `tail`. `tail` must have `kind == .list`;
/// improper (dotted) pairs are rejected with `error.InvalidListTail`.
/// O(1) allocation; no traversal of `tail`.
pub fn cons(heap: *Heap, head_v: Value, tail_v: Value) !Value {
    if (tail_v.kind() != .list) return error.InvalidListTail;
    const h = try heap.alloc(.list, @sizeOf(ConsBody));
    const body = Heap.bodyOf(ConsBody, h);
    body.head = head_v;
    body.tail = tail_v;
    return valueFrom(h, subkind_cons);
}

/// Build a list from `elems` in natural order: `fromSlice(&.{a,b,c})`
/// produces `(a b c)`. Right-folds `cons` from the end of the slice;
/// O(n) allocations.
pub fn fromSlice(heap: *Heap, elems: []const Value) !Value {
    var result = try empty(heap);
    var i: usize = elems.len;
    while (i > 0) {
        i -= 1;
        result = try cons(heap, elems[i], result);
    }
    return result;
}

// =============================================================================
// Public API — accessors
// =============================================================================

pub inline fn isEmpty(v: Value) bool {
    std.debug.assert(v.kind() == .list);
    return v.subkind() == subkind_empty;
}

/// First element. Panics in safe builds if the list is empty.
pub fn head(v: Value) Value {
    std.debug.assert(v.kind() == .list);
    if (std.debug.runtime_safety) {
        if (v.subkind() == subkind_empty) {
            std.debug.panic("list.head: called on empty list", .{});
        }
    }
    const h = Heap.asHeapHeader(v);
    return Heap.bodyOf(ConsBody, h).head;
}

/// Rest of the list. Always a list Value. Panics in safe builds if
/// the list is empty.
pub fn tail(v: Value) Value {
    std.debug.assert(v.kind() == .list);
    if (std.debug.runtime_safety) {
        if (v.subkind() == subkind_empty) {
            std.debug.panic("list.tail: called on empty list", .{});
        }
    }
    const h = Heap.asHeapHeader(v);
    return Heap.bodyOf(ConsBody, h).tail;
}

/// O(n) length. No caching in v1.
pub fn count(v: Value) usize {
    std.debug.assert(v.kind() == .list);
    var cur = v;
    var n: usize = 0;
    while (cur.subkind() == subkind_cons) : (n += 1) {
        const h = Heap.asHeapHeader(cur);
        cur = Heap.bodyOf(ConsBody, h).tail;
        // Safe-build invariant: tail must stay on the list rail.
        std.debug.assert(cur.kind() == .list);
    }
    return n;
}

// =============================================================================
// Per-kind hash / equality — called by dispatch with element callbacks
// =============================================================================

/// Ordered-combine hash over the list's elements, invoking
/// `elementHash` on each. Top-level walk is iterative; the element
/// callback may itself recurse (nested lists hash through
/// `dispatch.hashValue → list.hashSeq → elementHash → …`). Returns
/// the pre-domain `u64` base; `dispatch.hashValue` applies the
/// sequential-category domain byte on the way out.
pub fn hashSeq(h: *HeapHeader, elementHash: *const fn (Value) u64) u64 {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.list));
    }
    var acc: u64 = hash_mod.ordered_init;
    var n: usize = 0;
    var cur_header: *HeapHeader = h;
    while (cur_header.kind == @intFromEnum(Kind.list)) {
        // Reconstruct the subkind from the allocation size: body == 0
        // ⇒ empty; body == 32 ⇒ cons. We avoid round-tripping through
        // a Value to preserve the pure *HeapHeader input shape.
        const body = Heap.bodyBytes(cur_header);
        if (body.len == 0) break; // empty list terminator
        std.debug.assert(body.len == @sizeOf(ConsBody));
        const cons_body: *ConsBody = @ptrCast(@alignCast(body.ptr));
        acc = hash_mod.combineOrdered(acc, elementHash(cons_body.head));
        n += 1;
        std.debug.assert(cons_body.tail.kind() == .list);
        cur_header = Heap.asHeapHeader(cons_body.tail);
    }
    return hash_mod.finalizeOrdered(acc, n);
}

/// Pairwise structural equality. Walks both cons chains in lock-step,
/// comparing each paired element via `elementEq`. Returns true iff
/// the lists have identical length and every pair is equal.
pub fn equalSeq(
    a: *HeapHeader,
    b: *HeapHeader,
    elementEq: *const fn (Value, Value) bool,
) bool {
    if (std.debug.runtime_safety) {
        std.debug.assert(a.kind == @intFromEnum(Kind.list));
        std.debug.assert(b.kind == @intFromEnum(Kind.list));
    }
    if (a == b) return true;
    var ca: *HeapHeader = a;
    var cb: *HeapHeader = b;
    while (true) {
        const a_body = Heap.bodyBytes(ca);
        const b_body = Heap.bodyBytes(cb);
        const a_empty = a_body.len == 0;
        const b_empty = b_body.len == 0;
        if (a_empty and b_empty) return true;
        if (a_empty or b_empty) return false;
        std.debug.assert(a_body.len == @sizeOf(ConsBody));
        std.debug.assert(b_body.len == @sizeOf(ConsBody));
        const abody: *ConsBody = @ptrCast(@alignCast(a_body.ptr));
        const bbody: *ConsBody = @ptrCast(@alignCast(b_body.ptr));
        if (!elementEq(abody.head, bbody.head)) return false;
        std.debug.assert(abody.tail.kind() == .list);
        std.debug.assert(bbody.tail.kind() == .list);
        ca = Heap.asHeapHeader(abody.tail);
        cb = Heap.asHeapHeader(bbody.tail);
    }
}

// =============================================================================
// Private helpers
// =============================================================================

fn valueFrom(h: *HeapHeader, sk: u16) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.list)) | (@as(u64, sk) << 16),
        .payload = @intFromPtr(h),
    };
}

// =============================================================================
// Inline tests — structural properties that don't need dispatch.
// Full-Value hash/equal tests live in dispatch.zig and test/prop/list.zig.
// =============================================================================

test "empty: produces a fresh list Value with subkind_empty" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const e = try empty(&heap);
    try testing.expect(e.kind() == .list);
    try testing.expectEqual(subkind_empty, e.subkind());
    try testing.expect(isEmpty(e));
    try testing.expectEqual(@as(usize, 0), count(e));
}

test "empty: each call yields a distinct *HeapHeader (no singleton)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try empty(&heap);
    const b = try empty(&heap);
    try testing.expect(Heap.asHeapHeader(a) != Heap.asHeapHeader(b));
    try testing.expect(!a.identicalTo(b));
}

test "cons: basic head/tail round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const e = try empty(&heap);
    const one = value.fromFixnum(1).?;
    const two = value.fromFixnum(2).?;
    const three = value.fromFixnum(3).?;

    const list3 = try cons(&heap, one, try cons(&heap, two, try cons(&heap, three, e)));
    try testing.expectEqual(@as(usize, 3), count(list3));
    try testing.expect(head(list3).asFixnum() == 1);
    try testing.expect(head(tail(list3)).asFixnum() == 2);
    try testing.expect(head(tail(tail(list3))).asFixnum() == 3);
    try testing.expect(isEmpty(tail(tail(tail(list3)))));
}

test "cons: rejects non-list tail with error.InvalidListTail" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const bad_tail = value.fromFixnum(42).?; // fixnum, not a list
    const result = cons(&heap, value.fromFixnum(1).?, bad_tail);
    try testing.expectError(error.InvalidListTail, result);
}

test "fromSlice: builds list in natural order" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const elems = [_]Value{
        value.fromFixnum(10).?,
        value.fromFixnum(20).?,
        value.fromFixnum(30).?,
        value.fromFixnum(40).?,
    };
    const lst = try fromSlice(&heap, &elems);
    try testing.expectEqual(@as(usize, 4), count(lst));

    var cur = lst;
    for (elems) |expected| {
        try testing.expectEqual(expected.asFixnum(), head(cur).asFixnum());
        cur = tail(cur);
    }
    try testing.expect(isEmpty(cur));
}

test "fromSlice: empty slice yields an empty list" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const lst = try fromSlice(&heap, &.{});
    try testing.expect(isEmpty(lst));
    try testing.expectEqual(@as(usize, 0), count(lst));
}

test "cons body: head / tail are the same Value bits we stored" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const e = try empty(&heap);
    const kw = value.fromKeywordId(7);
    const lst = try cons(&heap, kw, e);

    const h_value = head(lst);
    try testing.expect(h_value.identicalTo(kw));

    const t_value = tail(lst);
    try testing.expect(t_value.identicalTo(e));
}

test "nested lists: a list element is itself a list" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const inner = try fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
    });
    const outer = try fromSlice(&heap, &.{ inner, value.fromFixnum(99).? });
    try testing.expectEqual(@as(usize, 2), count(outer));

    const first = head(outer);
    try testing.expect(first.kind() == .list);
    try testing.expectEqual(@as(usize, 2), count(first));
}

// ---- hashSeq / equalSeq with synthetic callbacks ----
//
// These callbacks stand in for `dispatch.hashValue` / `dispatch.equal`,
// keeping the inline tests free of the dispatch dependency. Real end-
// to-end coverage lives in dispatch.zig's tests.

fn callbackHashImmediateOnly(v: Value) u64 {
    // Immediate-only hasher. Suitable for flat-list tests where every
    // element is fixnum/keyword/etc. Panics on heap kinds — the fuller
    // story is tested through dispatch.zig.
    return v.hashImmediate();
}

fn callbackEqImmediateOnly(a: Value, b: Value) bool {
    // Cross-kind rule + bit identity for immediates. Mirrors eq.equal's
    // scope for same-kind immediate comparison.
    if (a.tag == b.tag and a.payload == b.payload) return true;
    if (a.kind() != b.kind()) return false;
    return switch (a.kind()) {
        .fixnum => a.asFixnum() == b.asFixnum(),
        .keyword => a.asKeywordId() == b.asKeywordId(),
        .symbol => a.asSymbolId() == b.asSymbolId(),
        .char => a.asChar() == b.asChar(),
        else => false, // limited scope for inline tests
    };
}

test "hashSeq: empty list returns finalizeOrdered(init, 0)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const e = try empty(&heap);
    const expected = hash_mod.finalizeOrdered(hash_mod.ordered_init, 0);
    try testing.expectEqual(expected, hashSeq(Heap.asHeapHeader(e), &callbackHashImmediateOnly));
}

test "hashSeq: (list 1 2 3) matches manual ordered combine" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const lst = try fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });

    var expected: u64 = hash_mod.ordered_init;
    expected = hash_mod.combineOrdered(expected, value.fromFixnum(1).?.hashImmediate());
    expected = hash_mod.combineOrdered(expected, value.fromFixnum(2).?.hashImmediate());
    expected = hash_mod.combineOrdered(expected, value.fromFixnum(3).?.hashImmediate());
    expected = hash_mod.finalizeOrdered(expected, 3);

    try testing.expectEqual(expected, hashSeq(Heap.asHeapHeader(lst), &callbackHashImmediateOnly));
}

test "hashSeq: equal lists produce equal base hashes (different allocations)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{
        value.fromFixnum(7).?,
        value.fromKeywordId(3),
    });
    const b = try fromSlice(&heap, &.{
        value.fromFixnum(7).?,
        value.fromKeywordId(3),
    });
    const ha = hashSeq(Heap.asHeapHeader(a), &callbackHashImmediateOnly);
    const hb = hashSeq(Heap.asHeapHeader(b), &callbackHashImmediateOnly);
    try testing.expectEqual(ha, hb);
}

test "hashSeq: different-length lists produce different hashes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const one = value.fromFixnum(1).?;
    const lst1 = try fromSlice(&heap, &.{one});
    const lst2 = try fromSlice(&heap, &.{ one, one });
    const h1 = hashSeq(Heap.asHeapHeader(lst1), &callbackHashImmediateOnly);
    const h2 = hashSeq(Heap.asHeapHeader(lst2), &callbackHashImmediateOnly);
    try testing.expect(h1 != h2);
}

test "equalSeq: structural equality across distinct allocations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    const b = try fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    try testing.expect(equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &callbackEqImmediateOnly));
}

test "equalSeq: length mismatch returns false" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(2).? });
    const b = try fromSlice(&heap, &.{value.fromFixnum(1).?});
    try testing.expect(!equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &callbackEqImmediateOnly));
    try testing.expect(!equalSeq(Heap.asHeapHeader(b), Heap.asHeapHeader(a), &callbackEqImmediateOnly));
}

test "equalSeq: element-level inequality propagates up" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(2).? });
    const b = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(99).? });
    try testing.expect(!equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &callbackEqImmediateOnly));
}

test "equalSeq: two empty lists compare equal" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try empty(&heap);
    const b = try empty(&heap);
    try testing.expect(equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &callbackEqImmediateOnly));
}

test "equalSeq: identity short-circuit on same *HeapHeader" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{value.fromFixnum(42).?});
    try testing.expect(equalSeq(Heap.asHeapHeader(a), Heap.asHeapHeader(a), &callbackEqImmediateOnly));
}

test "count: flat list with 100 elements" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var elems: [100]Value = undefined;
    for (&elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
    const lst = try fromSlice(&heap, &elems);
    try testing.expectEqual(@as(usize, 100), count(lst));
}
