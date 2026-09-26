//! coll/list.zig — immutable list heap kind: cons cells and vector views.
//!
//! Authoritative spec: `docs/LIST.md`. Physical storage: `src/heap.zig`.
//! Semantics: `docs/SEMANTICS.md` §2.6 (sequential equality category)
//! and §3.2 (sequential-domain hash mixing; the domain mixer is chosen
//! by equality category).
//!
//! Subkinds (LIST.md §1):
//!   - 0 = cons  — body is `{ head: Value, tail: Value }` = 32 bytes;
//!         tail is always kind .list (proper lists only).
//!   - 1 = empty — body size 0; the Value alone encodes emptiness.
//!   - 2 = view  — body is one vector Value = 16 bytes; the Value's
//!         tag bits 32..63 hold the offset of its first element. The
//!         elements of a vector from an offset on, so `seq`, `rest`
//!         and `next` of a vector are O(1): `tail` of a view is the
//!         same block at the next offset and allocates nothing. A
//!         view carrying metadata holds, instead of the vector, a
//!         view Value of the metadata-free block its rests share.
//!
//! Every reader goes through `isEmpty` / `head` / `tail` / `count` /
//! `drop` / `Cursor`; only this file knows the bodies.
//!
//! Dispatch plumbing: `hashSeq` and `equalSeq` take function-pointer
//! callbacks (`elementHash`, `elementEq`) for the inner operations so
//! list.zig never imports `dispatch`. The dispatcher passes
//! `&dispatch.hashValue` and `&dispatch.equal` at the kind switch.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const hash_mod = @import("../hash.zig");
const vector = @import("vector.zig");

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
pub const subkind_view: u16 = 2;

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

/// A view's body is the vector it reads; its size tells a view block
/// from a cons cell (32) and an empty list (0) where only the header
/// is at hand (`trace`).
const view_body_size: usize = @sizeOf(Value);

pub const ListError = error{
    InvalidListTail,
};

// =============================================================================
// Public API — constructors
// =============================================================================

/// Fresh empty list. Not a shared singleton; every call allocates
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

/// `(conj l x)`: `x` prepended in a cell that carries `l`'s metadata,
/// as Clojure's `conj` on a list does (SEMANTICS §7); `cons` carries
/// none.
pub fn conj(heap: *Heap, l: Value, x: Value) !Value {
    const c = try cons(heap, x, l);
    Heap.asHeapHeader(c).setMeta(Heap.asHeapHeader(l).getMeta());
    return c;
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

/// The elements of the vector `vec` from index `start` on, as a
/// list: one 16-byte block whatever the vector's length. `start ==
/// count(vec)` gives an empty list.
pub fn ofVector(heap: *Heap, vec: Value, start: usize) !Value {
    std.debug.assert(start <= vector.count(vec));
    const h = try heap.alloc(.list, view_body_size);
    Heap.bodyOf(Value, h).* = vec;
    return viewAt(h, start);
}

/// The view `v` carrying `meta`, in O(1). The metadata goes on a new
/// view block whose body is the metadata-free block `v` reads, and
/// `tail` and `drop` step onto that block, so the metadata stays on
/// the view `with-meta` returned and never reaches a rest (LIST.md
/// §2). Null metadata gives the metadata-free view.
pub fn viewWithMeta(heap: *Heap, v: Value, meta: ?*HeapHeader) !Value {
    std.debug.assert(v.kind() == .list and v.subkind() == subkind_view);
    const plain = restBlock(v);
    const m = meta orelse return viewAt(plain, viewOffset(v));
    const h = try heap.alloc(.list, view_body_size);
    Heap.bodyOf(Value, h).* = valueFrom(plain, subkind_view);
    h.setMeta(m);
    return viewAt(h, viewOffset(v));
}

// =============================================================================
// Public API — accessors
// =============================================================================

pub fn isEmpty(v: Value) bool {
    std.debug.assert(v.kind() == .list);
    return switch (v.subkind()) {
        subkind_cons => false,
        subkind_view => viewOffset(v) >= vector.count(viewVector(v)),
        else => true,
    };
}

/// First element. Panics in safe builds if the list is empty.
pub fn head(v: Value) Value {
    if (std.debug.runtime_safety and isEmpty(v)) std.debug.panic("list.head: called on empty list", .{});
    if (v.subkind() == subkind_view) return vector.nth(viewVector(v), viewOffset(v));
    return consBody(v).head;
}

/// Rest of the list. Always a list Value; never allocates. Panics in
/// safe builds if the list is empty.
pub fn tail(v: Value) Value {
    if (std.debug.runtime_safety and isEmpty(v)) std.debug.panic("list.tail: called on empty list", .{});
    if (v.subkind() == subkind_view) return viewAt(restBlock(v), viewOffset(v) + 1);
    return consBody(v).tail;
}

/// Length: O(1) for a view, O(n) over cons cells; nothing caches it.
pub fn count(v: Value) usize {
    std.debug.assert(v.kind() == .list);
    var cur = v;
    var n: usize = 0;
    while (true) switch (cur.subkind()) {
        subkind_cons => {
            n += 1;
            cur = consBody(cur).tail;
        },
        subkind_view => return n + vector.count(viewVector(cur)) - viewOffset(cur),
        else => return n,
    };
}

/// The list without its first `n` elements; empty when it is
/// shorter. Never allocates: a view moves its offset in one step.
pub fn drop(v: Value, n: usize) Value {
    std.debug.assert(v.kind() == .list);
    var cur = v;
    var left = n;
    while (left > 0) : (left -= 1) switch (cur.subkind()) {
        subkind_cons => cur = consBody(cur).tail,
        subkind_view => {
            const at = viewOffset(cur);
            const remaining = vector.count(viewVector(cur)) - at;
            return viewAt(restBlock(cur), at + @min(left, remaining));
        },
        else => return cur,
    };
    return cur;
}

// =============================================================================
// Per-kind hash / equality — called by dispatch with element callbacks
// =============================================================================

/// Ordered-combine hash over the list's elements, invoking
/// `elementHash` on each. Top-level walk is iterative; the element
/// callback may itself recurse (nested lists hash through
/// `dispatch.hashValue → list.hashSeq → elementHash → …`). Returns
/// the pre-domain base at u32 precision (SEMANTICS.md §3.1);
/// `dispatch.hashValue` applies the sequential-category domain byte
/// on the way out. `vector.hashSeq` computes the same value for the
/// same elements. A cons cell caches the result in its header; a
/// view does not, because every offset of it shares one header.
pub fn hashSeq(v: Value, elementHash: *const fn (Value) u64) u64 {
    std.debug.assert(v.kind() == .list);
    const h = Heap.asHeapHeader(v);
    const cacheable = v.subkind() != subkind_view;
    if (cacheable) if (h.cachedHash()) |cached| return cached;
    var acc: u64 = hash_mod.ordered_init;
    var n: usize = 0;
    var c = Cursor.init(v);
    while (c.next()) |x| : (n += 1) acc = hash_mod.combineOrdered(acc, elementHash(x));
    const truncated: u32 = @truncate(hash_mod.finalizeOrdered(acc, n));
    if (cacheable and truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// Pairwise structural equality. Walks both lists in lock-step,
/// comparing each paired element via `elementEq`. Returns true iff
/// the lists have identical length and every pair is equal.
pub fn equalSeq(a: Value, b: Value, elementEq: *const fn (Value, Value) bool) bool {
    std.debug.assert(a.kind() == .list and b.kind() == .list);
    if (a.identicalTo(b)) return true;
    var ca = Cursor.init(a);
    var cb = Cursor.init(b);
    while (true) {
        const x = ca.next() orelse return cb.next() == null;
        const y = cb.next() orelse return false;
        if (!elementEq(x, y)) return false;
    }
}

// =============================================================================
// GC trace (GC.md §5)
// =============================================================================

/// Walk the chain that starts at `h`: mark every head as a normal
/// heap value, and mark each following cons cell directly (its
/// mark bit through `visitor.markInternal`, its meta through
/// `visitor.mark`) instead of handing the tail back to the
/// collector, so a list of any length is walked in a loop and the
/// collector's recursion depth follows nesting, never length. The
/// walk stops at the empty list, at a view (which marks its whole
/// vector: the offset lives in the Value, not the block), or at the
/// first cell that is already marked, which is also what ends a
/// cyclic chain.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    var cell = h;
    while (true) {
        const body = Heap.bodyBytes(cell);
        switch (body.len) {
            0 => return,
            view_body_size => return visitor.markValue(Heap.bodyOf(Value, cell).*),
            else => {},
        }
        std.debug.assert(body.len == @sizeOf(ConsBody));
        const cons_body: *ConsBody = @ptrCast(@alignCast(body.ptr));
        visitor.markValue(cons_body.head);
        std.debug.assert(cons_body.tail.kind() == .list);
        const next = Heap.asHeapHeader(cons_body.tail);
        if (!visitor.markInternal(next)) return;
        if (next.meta) |m| visitor.mark(m);
        cell = next;
    }
}

// =============================================================================
// Cursor — streaming ordered iteration
// =============================================================================
//
// The cross-kind walker pattern is streaming ordered traversal rather
// than random-access-by-index. `dispatch.sequentialEqual`, `hashSeq`,
// `equalSeq` and the stdlib's sequence iterator walk lists with it;
// once it reaches a view it walks the vector's leaves directly.

pub const Cursor = struct {
    /// The part of the list still to be yielded, until a view is
    /// reached; from then on `view` yields the rest.
    current: Value,
    view: ?vector.Cursor = null,

    pub fn init(v: Value) Cursor {
        std.debug.assert(v.kind() == .list);
        return .{ .current = v };
    }

    pub fn next(self: *Cursor) ?Value {
        if (self.view) |*vc| return vc.next();
        switch (self.current.subkind()) {
            subkind_cons => {
                const body = consBody(self.current);
                self.current = body.tail;
                return body.head;
            },
            subkind_view => {
                self.view = vector.Cursor.initAt(viewVector(self.current), viewOffset(self.current));
                return self.view.?.next();
            },
            else => return null,
        }
    }
};

// =============================================================================
// Private helpers
// =============================================================================

fn valueFrom(h: *HeapHeader, sk: u16) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.list)) | (@as(u64, sk) << 16),
        .payload = @intFromPtr(h),
    };
}

/// The view Value over the block `h` at `offset`. A vector's count is
/// a u32, so the offset fits the tag's upper half.
fn viewAt(h: *HeapHeader, offset: usize) Value {
    const v = valueFrom(h, subkind_view);
    return .{ .tag = v.tag | (@as(u64, @as(u32, @intCast(offset))) << 32), .payload = v.payload };
}

fn viewOffset(v: Value) usize {
    return @intCast(v.tag >> 32);
}

/// The metadata-free block a view's rests share: the view's own, or
/// the one a view carrying metadata wraps (`viewWithMeta`).
fn restBlock(v: Value) *HeapHeader {
    const h = Heap.asHeapHeader(v);
    const body = Heap.bodyOf(Value, h).*;
    return if (body.kind() == .list) Heap.asHeapHeader(body) else h;
}

fn viewVector(v: Value) Value {
    return Heap.bodyOf(Value, restBlock(v)).*;
}

fn consBody(v: Value) *ConsBody {
    std.debug.assert(v.subkind() == subkind_cons);
    return Heap.bodyOf(ConsBody, Heap.asHeapHeader(v));
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
    const kw = value.testKeyword(7);
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
    // Cross-kind rule + bit identity for immediates. Mirrors
    // eq.equalImmediate's scope for same-kind immediate comparison.
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

test "hashSeq: empty list returns finalizeOrdered(init, 0) at u32 precision" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const e = try empty(&heap);
    const expected: u64 = @as(u32, @truncate(hash_mod.finalizeOrdered(hash_mod.ordered_init, 0)));
    try testing.expectEqual(expected, hashSeq(e, &callbackHashImmediateOnly));
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
    expected = @as(u32, @truncate(hash_mod.finalizeOrdered(expected, 3)));

    try testing.expectEqual(expected, hashSeq(lst, &callbackHashImmediateOnly));
}

test "hashSeq caches its result in the head cell's header" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const l = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(2).? });
    const h = Heap.asHeapHeader(l);
    try testing.expect(h.cachedHash() == null);
    const first = hashSeq(l, &callbackHashImmediateOnly);
    try testing.expectEqual(@as(?u32, @intCast(first)), h.cachedHash());
    try testing.expectEqual(first, hashSeq(l, &callbackHashImmediateOnly));
}

test "hashSeq: a view hashes as the list of its elements and caches nothing" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var elems: [40]Value = undefined;
    for (&elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
    const vec = try vector.fromSlice(&heap, &elems);
    const view = try ofVector(&heap, vec, 0);
    for (0..elems.len + 1) |k| {
        const at = drop(view, k);
        const expected = hashSeq(try fromSlice(&heap, elems[k..]), &callbackHashImmediateOnly);
        try testing.expectEqual(expected, hashSeq(at, &callbackHashImmediateOnly));
    }
    try testing.expect(Heap.asHeapHeader(view).cachedHash() == null);
}

test "hashSeq: equal lists produce equal base hashes (different allocations)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{
        value.fromFixnum(7).?,
        value.testKeyword(3),
    });
    const b = try fromSlice(&heap, &.{
        value.fromFixnum(7).?,
        value.testKeyword(3),
    });
    const ha = hashSeq(a, &callbackHashImmediateOnly);
    const hb = hashSeq(b, &callbackHashImmediateOnly);
    try testing.expectEqual(ha, hb);
}

test "hashSeq: different-length lists produce different hashes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const one = value.fromFixnum(1).?;
    const lst1 = try fromSlice(&heap, &.{one});
    const lst2 = try fromSlice(&heap, &.{ one, one });
    const h1 = hashSeq(lst1, &callbackHashImmediateOnly);
    const h2 = hashSeq(lst2, &callbackHashImmediateOnly);
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
    try testing.expect(equalSeq(a, b, &callbackEqImmediateOnly));
}

test "equalSeq: length mismatch returns false" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(2).? });
    const b = try fromSlice(&heap, &.{value.fromFixnum(1).?});
    try testing.expect(!equalSeq(a, b, &callbackEqImmediateOnly));
    try testing.expect(!equalSeq(b, a, &callbackEqImmediateOnly));
}

test "equalSeq: element-level inequality propagates up" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(2).? });
    const b = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(99).? });
    try testing.expect(!equalSeq(a, b, &callbackEqImmediateOnly));
}

test "equalSeq: two empty lists compare equal" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try empty(&heap);
    const b = try empty(&heap);
    try testing.expect(equalSeq(a, b, &callbackEqImmediateOnly));
}

test "equalSeq: identity short-circuit on same *HeapHeader" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{value.fromFixnum(42).?});
    try testing.expect(equalSeq(a, a, &callbackEqImmediateOnly));
}

test "Cursor: streaming iteration yields head-to-tail, null on empty" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Empty list: init + next returns null immediately.
    const e = try empty(&heap);
    var ce = Cursor.init(e);
    try testing.expectEqual(@as(?Value, null), ce.next());

    // Non-empty list: yields 1, 2, 3, then null.
    const lst = try fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    var c = Cursor.init(lst);
    try testing.expectEqual(@as(i64, 1), c.next().?.asFixnum());
    try testing.expectEqual(@as(i64, 2), c.next().?.asFixnum());
    try testing.expectEqual(@as(i64, 3), c.next().?.asFixnum());
    try testing.expectEqual(@as(?Value, null), c.next());
    try testing.expectEqual(@as(?Value, null), c.next()); // still null
}

test "view: head, tail, count, drop and Cursor read the vector from the offset" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // 1100 elements: a tail, full leaves and a two-level trie.
    var elems: [1100]Value = undefined;
    for (&elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
    const vec = try vector.fromSlice(&heap, &elems);
    const live = heap.liveCount();
    const view = try ofVector(&heap, vec, 0);
    try testing.expectEqual(subkind_view, view.subkind());

    var cur = view;
    for (elems, 0..) |x, i| {
        try testing.expect(!isEmpty(cur));
        try testing.expectEqual(elems.len - i, count(cur));
        try testing.expect(head(cur).identicalTo(x));
        try testing.expect(drop(view, i).identicalTo(cur));
        cur = tail(cur);
    }
    try testing.expect(isEmpty(cur));
    try testing.expectEqual(@as(usize, 0), count(cur));
    try testing.expect(drop(view, elems.len + 5).identicalTo(cur));
    // One block for the view; tail and drop allocate nothing.
    try testing.expectEqual(live + 1, heap.liveCount());

    for ([_]usize{ 0, 1, 31, 32, 33, 1055, 1056, 1057, 1099, 1100 }) |k| {
        var c = Cursor.init(drop(view, k));
        for (elems[k..]) |x| try testing.expect(c.next().?.identicalTo(x));
        try testing.expectEqual(@as(?Value, null), c.next());
    }
}

test "view: a cons in front of a view walks into it" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const one = value.fromFixnum(1).?;
    const vec = try vector.fromSlice(&heap, &.{ one, value.fromFixnum(2).?, value.fromFixnum(3).? });
    const l = try cons(&heap, value.fromFixnum(0).?, try ofVector(&heap, vec, 1));
    try testing.expectEqual(@as(usize, 3), count(l));
    try testing.expectEqual(@as(i64, 3), head(drop(l, 2)).asFixnum());
    try testing.expect(equalSeq(l, try fromSlice(&heap, &.{ value.fromFixnum(0).?, value.fromFixnum(2).?, value.fromFixnum(3).? }), &callbackEqImmediateOnly));
    try testing.expect(!equalSeq(l, try ofVector(&heap, vec, 0), &callbackEqImmediateOnly));
    try testing.expect(equalSeq(try ofVector(&heap, vec, 3), try empty(&heap), &callbackEqImmediateOnly));
}

test "count: flat list with 100 elements" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var elems: [100]Value = undefined;
    for (&elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
    const lst = try fromSlice(&heap, &elems);
    try testing.expectEqual(@as(usize, 100), count(lst));
}
