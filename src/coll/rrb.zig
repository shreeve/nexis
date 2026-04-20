//! coll/rrb.zig — persistent vector heap kind (Phase 1, Scope A).
//!
//! **This is plain 32-way radix trie + tail buffer, NOT RRB-relaxed.**
//! The file is named `rrb.zig` for historical consistency with PLAN.md
//! §22's repository layout; the v1 implementation is the same shape
//! Clojure has shipped for 17+ years (PLAN §9.2 + §23 #30, frozen).
//! RRB relaxation lands in v2+.
//!
//! Authoritative spec: `docs/VECTOR.md`. Semantic framing:
//! `docs/SEMANTICS.md` §2.6 (sequential equality category) and §3.2
//! (shared-sequential hash domain byte `0xF0`). Physical storage:
//! `docs/HEAP.md`.
//!
//! This is the **second sequential collection kind**. Its landing is
//! the first direct exercise of the cross-kind sequential equality
//! story the architecture committed to in `accbb83`. The critical
//! invariant exercised here: `(= (list 1 2 3) [1 2 3])` must be true
//! and `(hash (list 1 2 3)) == (hash [1 2 3])` must hold by
//! construction. See `test "cross-kind: (list 1 2 3) and [1 2 3] are
//! equal and share hashValue"` in `src/dispatch.zig`.
//!
//! Scope (Scope A): `empty` / `fromSlice` / `conj` / `count` / `nth`
//! / `isEmpty` / `hashSeq` / `equalSeq` / `Cursor`. Deferred:
//! `assoc`, `pop`, `subvec`, `concat`, transients, small-vector
//! inline (subkind 0).

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
// Constants
// =============================================================================

pub const branch_bits: u32 = 5;
pub const branch_factor: usize = 1 << branch_bits; // 32
pub const branch_mask: u32 = @as(u32, branch_factor) - 1; // 0x1F

pub const subkind_root: u16 = 1;

// =============================================================================
// Body layouts
//
// Per VECTOR.md §3. Four conceptual subkinds (root / interior / leaf /
// tail) are semantically distinct but NOT encoded in the HeapHeader in
// v1 — every internal access derives the kind from structural context
// (root.shift + descent level). GC will add explicit subkind encoding
// when gc.zig lands; Scope A doesn't need it because only vector.zig
// itself traverses these allocations today.
// =============================================================================

/// Root vector body (subkind 1). Every vector — empty, small, or
/// large — uses this exact 32-byte layout.
const RootBody = extern struct {
    /// Total element count, including tail.
    count: u32,
    /// Root trie shift. `0` when `count ≤ 32` (all elements in tail);
    /// `5` for a depth-1 trie (root points at leaves); `10` for
    /// depth-2; and so on.
    shift: u32,
    /// Root trie node pointer. `null` when `count ≤ 32` (empty trie).
    /// Otherwise points at an interior node (if shift > 5) or a leaf
    /// node (if shift == 5).
    root_node: ?*HeapHeader,
    /// Tail node pointer. `null` only when `count == 0`.
    tail_node: ?*HeapHeader,
    /// Tail length in Values, 0..32. Stored explicitly rather than
    /// derived from `count % 32` because the latter misreports the
    /// boundary case where count == 32 (tail is full, not empty).
    tail_len: u32,
    /// Padding to make the struct a clean 32 bytes. NEVER semantic.
    _pad: u32,

    comptime {
        std.debug.assert(@sizeOf(RootBody) == 32);
        std.debug.assert(@offsetOf(RootBody, "count") == 0);
        std.debug.assert(@offsetOf(RootBody, "shift") == 4);
        std.debug.assert(@offsetOf(RootBody, "root_node") == 8);
        std.debug.assert(@offsetOf(RootBody, "tail_node") == 16);
        std.debug.assert(@offsetOf(RootBody, "tail_len") == 24);
    }
};

const root_body_size: usize = @sizeOf(RootBody);
const interior_body_size: usize = branch_factor * @sizeOf(?*HeapHeader); // 256
const leaf_body_size: usize = branch_factor * @sizeOf(Value); // 512

// =============================================================================
// Allocation helpers
// =============================================================================

/// Fresh zeroed root allocation. Returns the header; caller sets
/// `RootBody` fields.
fn allocRoot(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_vector, root_body_size);
}

/// Fresh zeroed interior node — 32 null child pointers.
fn allocInterior(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_vector, interior_body_size);
}

/// Fresh zeroed leaf node — 32 Value slots. Leaves are always full in
/// canonical form; caller writes all 32 slots before using.
fn allocLeaf(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_vector, leaf_body_size);
}

/// Fresh zeroed tail node of `len` Values. `len` must be in `[0, 32]`.
/// An empty tail is not allocated — the root's `tail_node` stays null.
fn allocTail(heap: *Heap, len: usize) !*HeapHeader {
    std.debug.assert(len >= 1 and len <= branch_factor);
    const body_size = try std.math.mul(usize, len, @sizeOf(Value));
    return heap.alloc(.persistent_vector, body_size);
}

// =============================================================================
// Body accessors
// =============================================================================

fn rootBody(h: *HeapHeader) *RootBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == root_body_size);
    return @ptrCast(@alignCast(body.ptr));
}

fn rootBodyConst(h: *HeapHeader) *const RootBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == root_body_size);
    return @ptrCast(@alignCast(body.ptr));
}

fn interiorChildren(h: *HeapHeader) *[branch_factor]?*HeapHeader {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == interior_body_size);
    return @ptrCast(@alignCast(body.ptr));
}

fn leafValues(h: *HeapHeader) *[branch_factor]Value {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == leaf_body_size);
    return @ptrCast(@alignCast(body.ptr));
}

fn tailValues(h: *HeapHeader) []Value {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len % @sizeOf(Value) == 0);
    const count_len = body.len / @sizeOf(Value);
    std.debug.assert(count_len >= 1 and count_len <= branch_factor);
    const ptr: [*]Value = @ptrCast(@alignCast(body.ptr));
    return ptr[0..count_len];
}

fn tailValuesConst(h: *HeapHeader) []const Value {
    return tailValues(h);
}

// =============================================================================
// Value packing
// =============================================================================

/// Wrap a root header into a Value. Only callable on subkind-1 roots.
fn valueFromRoot(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_vector)) |
            (@as(u64, subkind_root) << 16),
        .payload = @intFromPtr(h),
    };
}

/// Public reconstruction helper for the transient module (TRANSIENT.md
/// §8). Builds a persistent-vector user Value from a raw root
/// `*HeapHeader`. The transient wrapper's `inner_header` is always a
/// subkind-1 vector root in v1 (no other vector subkind is
/// user-facing), so no subkind inference is needed.
pub fn valueFromVectorHeader(h: *HeapHeader) Value {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.persistent_vector));
    }
    return valueFromRoot(h);
}

fn rootHeader(v: Value) *HeapHeader {
    std.debug.assert(v.kind() == .persistent_vector);
    std.debug.assert(v.subkind() == subkind_root);
    return Heap.asHeapHeader(v);
}

// =============================================================================
// Public API — construction
// =============================================================================

/// Empty vector. count == 0; no trie; no tail.
pub fn empty(heap: *Heap) !Value {
    const h = try allocRoot(heap);
    const body = rootBody(h);
    body.count = 0;
    body.shift = 0;
    body.root_node = null;
    body.tail_node = null;
    body.tail_len = 0;
    return valueFromRoot(h);
}

/// Append `elem` to `v`, producing a new vector. O(1) amortized.
/// Four paths:
///   (a) count == 0 → allocate a 1-element tail.
///   (b) tail not full → allocate a new (tail_len+1)-length tail with
///       old elements + appended element.
///   (c) tail full + trie has room → push old tail into trie as a
///       leaf; start new 1-element tail.
///   (d) tail full + trie at capacity → grow shift by 5; new root
///       interior node has old root in slot 0 and a freshly-built
///       path to the promoted leaf in slot 1; start new tail.
pub fn conj(heap: *Heap, v: Value, elem: Value) !Value {
    const src_h = rootHeader(v);
    const src = rootBodyConst(src_h);

    // Path (a): empty vector → 1-element tail.
    if (src.count == 0) {
        const new_tail = try allocTail(heap, 1);
        tailValues(new_tail)[0] = elem;
        const new_root_h = try allocRoot(heap);
        const new_root = rootBody(new_root_h);
        new_root.count = 1;
        new_root.shift = 0;
        new_root.root_node = null;
        new_root.tail_node = new_tail;
        new_root.tail_len = 1;
        return valueFromRoot(new_root_h);
    }

    // Path (b): tail has room → grow tail by 1.
    if (src.tail_len < branch_factor) {
        const old_tail = tailValuesConst(src.tail_node.?);
        const new_tail = try allocTail(heap, src.tail_len + 1);
        const new_tail_values = tailValues(new_tail);
        @memcpy(new_tail_values[0..src.tail_len], old_tail);
        new_tail_values[src.tail_len] = elem;

        const new_root_h = try allocRoot(heap);
        const new_root = rootBody(new_root_h);
        new_root.count = src.count + 1;
        new_root.shift = src.shift;
        new_root.root_node = src.root_node;
        new_root.tail_node = new_tail;
        new_root.tail_len = src.tail_len + 1;
        return valueFromRoot(new_root_h);
    }

    // Tail is full (len == 32). Old tail becomes a leaf under the
    // trie; new tail starts with the appended element.
    const new_tail = try allocTail(heap, 1);
    tailValues(new_tail)[0] = elem;

    const promoted_leaf = try leafFromTail(heap, src.tail_node.?);
    // `promoted_leaf_base` is the logical element index the promoted
    // leaf covers from: the leaf spans indices
    // `[promoted_leaf_base, promoted_leaf_base + 32)`. Derived from
    // the OLD count, not the new one (peer-AI turn-7 naming review).
    const promoted_leaf_base: u32 = src.count - @as(u32, branch_factor);
    // `elems_after_promotion` is how many elements the trie must
    // address once the promoted leaf is in place: old count (which
    // already includes the 32 elements currently in the tail that
    // are about to become the promoted leaf).
    const elems_after_promotion: u32 = src.count;

    var new_root_node: *HeapHeader = undefined;
    var new_shift: u32 = src.shift;

    // Two regimes that both build a NEW interior root:
    //   (i) First-trie-materialization — old root is null (count was
    //       ≤ 32). Promoted leaf becomes the sole content; shift
    //       grows from 0 to 5. The root is an interior holding the
    //       leaf at slot 0 (per Clojure: leaves never occupy the
    //       root position; the root is always an interior when
    //       shift > 0).
    //   (ii) Capacity overflow — trie is full at its current shift.
    //        New root is an interior whose slot 0 holds the old root
    //        and whose later slot holds a freshly-built path to the
    //        promoted leaf; shift grows by 5.
    //
    // Both regimes share the same arithmetic via `newPath`: the
    // promoted leaf goes at `local_idx = (promoted_leaf_base >>
    // new_shift) & branch_mask`. For regime (i): base=0, new_shift=5,
    // local_idx=0. For regime (ii): base > capacityAtShift(
    // src.shift), so local_idx ≥ 1.
    //
    // Boundary discipline: at the exact-capacity case (e.g.
    // src.count == 1024, capacityAtShift(5) == 1024), the strict `>`
    // is CORRECT — the trie still has room for one more leaf in its
    // last slot (slot 31 at shift=5 for a 1024-capacity trie), and
    // `pushLeaf` handles the insertion. Shift only grows when
    // elems_after_promotion STRICTLY exceeds current capacity, which
    // matches Clojure's `(cnt >>> 5) > (1 << shift)` formulation.
    //
    // GC-interaction note: this function allocates 3–5 heap objects
    // (new_tail, promoted_leaf, possibly clones and new interiors,
    // new_root_h) before any of them is reachable from a user-held
    // Value. v1's heap is arena-ish and does not trigger GC during
    // `alloc`. When `gc.zig` lands, this function will need a
    // temporary root-stack pattern (or a "no-GC during construction"
    // discipline) to prevent partial-tree reclamation.
    if (src.root_node == null or elems_after_promotion > capacityAtShift(src.shift)) {
        const old_shift = src.shift;
        new_shift = if (src.root_node == null) branch_bits else src.shift + branch_bits;
        const new_root_interior = try allocInterior(heap);
        const children = interiorChildren(new_root_interior);
        if (src.root_node) |old_root| children[0] = old_root;
        const local_idx: usize = (@as(usize, promoted_leaf_base) >> @intCast(new_shift)) & branch_mask;
        children[local_idx] = try newPath(heap, old_shift, promoted_leaf);
        new_root_node = new_root_interior;
    } else {
        // Trie has room at the current shift; path-copy insertion.
        new_root_node = try pushLeaf(heap, src.root_node.?, src.shift, promoted_leaf_base, promoted_leaf);
    }

    const new_root_h = try allocRoot(heap);
    const new_root = rootBody(new_root_h);
    new_root.count = src.count + 1;
    new_root.shift = new_shift;
    new_root.root_node = new_root_node;
    new_root.tail_node = new_tail;
    new_root.tail_len = 1;
    return valueFromRoot(new_root_h);
}

/// Build a vector from a slice, in natural order. Implemented as
/// a left-fold of `conj` for simplicity and to exercise the append
/// paths during construction.
pub fn fromSlice(heap: *Heap, elems: []const Value) !Value {
    var result = try empty(heap);
    for (elems) |e| result = try conj(heap, result, e);
    return result;
}

// =============================================================================
// Public API — accessors
// =============================================================================

pub fn count(v: Value) usize {
    return rootBodyConst(rootHeader(v)).count;
}

pub fn isEmpty(v: Value) bool {
    return rootBodyConst(rootHeader(v)).count == 0;
}

/// Element at logical index `i`. Panics in safe builds on out-of-
/// bounds. O(log₃₂ n) via trie descent when `i` is in the trie;
/// O(1) when `i` is in the tail.
pub fn nth(v: Value, i: usize) Value {
    const h = rootHeader(v);
    const body = rootBodyConst(h);
    if (std.debug.runtime_safety) {
        if (i >= body.count) {
            std.debug.panic(
                "vector.nth: index {d} out of bounds (count {d})",
                .{ i, body.count },
            );
        }
    }
    const tail_offset: usize = body.count - body.tail_len;
    if (i >= tail_offset) {
        return tailValuesConst(body.tail_node.?)[i - tail_offset];
    }
    // Descend the trie. Start at shift; at each level take
    // `(i >> level_shift) & 0x1F`.
    var node: *HeapHeader = body.root_node.?;
    var level_shift: u32 = body.shift;
    while (level_shift > 0) {
        const child_idx: usize = (i >> @intCast(level_shift)) & branch_mask;
        node = interiorChildren(node)[child_idx].?;
        level_shift -= branch_bits;
    }
    const leaf_idx: usize = i & branch_mask;
    return leafValues(node)[leaf_idx];
}

// =============================================================================
// Per-kind hash + equality (called by dispatch)
// =============================================================================

/// Ordered-combine hash over the logical element sequence. Matches
/// `list.hashSeq` arithmetic exactly so equal element sequences
/// produce equal pre-mix u64 bases across list and vector.
pub fn hashSeq(h: *HeapHeader, elementHash: *const fn (Value) u64) u64 {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.persistent_vector));
    }
    const body = rootBodyConst(h);
    var acc: u64 = hash_mod.ordered_init;
    var idx: usize = 0;
    const tail_offset: usize = body.count - body.tail_len;
    // Trie elements first (indices 0..tail_offset), then tail.
    while (idx < tail_offset) : (idx += 1) {
        const elem = nthFromHeader(h, idx);
        acc = hash_mod.combineOrdered(acc, elementHash(elem));
    }
    if (body.tail_node) |tn| {
        for (tailValuesConst(tn)) |elem| {
            acc = hash_mod.combineOrdered(acc, elementHash(elem));
        }
    }
    return hash_mod.finalizeOrdered(acc, body.count);
}

/// Pairwise structural equality. Called by dispatch.heapEqual when
/// both sides are kind `.persistent_vector`. Returns false on count
/// mismatch; otherwise walks both in lock-step via index.
pub fn equalSeq(
    a: *HeapHeader,
    b: *HeapHeader,
    elementEq: *const fn (Value, Value) bool,
) bool {
    if (std.debug.runtime_safety) {
        std.debug.assert(a.kind == @intFromEnum(Kind.persistent_vector));
        std.debug.assert(b.kind == @intFromEnum(Kind.persistent_vector));
    }
    if (a == b) return true;
    const ab = rootBodyConst(a);
    const bb = rootBodyConst(b);
    if (ab.count != bb.count) return false;
    var i: usize = 0;
    while (i < ab.count) : (i += 1) {
        if (!elementEq(nthFromHeader(a, i), nthFromHeader(b, i))) return false;
    }
    return true;
}

// =============================================================================
// GC trace (GC.md §5)
//
// Vector trace walks the trie (internal subkinds 2/3/4) directly via
// `visitor.markInternal`. External Value references (leaf/tail
// elements) route through `visitor.markValue`. Internal nodes have
// no metadata (VECTOR.md §3 invariant), so `markInternal` skips the
// meta chain.
// =============================================================================

/// Walk the vector rooted at `h` (subkind 1). `h` itself is already
/// marked by the collector. Walks: tail_node (internal) + its leaf
/// values; root_node recursively (interior/leaf subkinds) + every
/// leaf's values.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = rootBodyConst(h);
    if (body.tail_node) |tn| {
        if (visitor.markInternal(tn)) {
            // Tail node body is [tail_len] Value — walk and mark
            // heap-kind children.
            for (tailValuesConst(tn)) |elem| visitor.markValue(elem);
        }
    }
    if (body.root_node) |rn| traceTrie(rn, body.shift, visitor);
}

/// Recursively walk a trie subtree. `shift == 0` means `node` is a
/// leaf (32 Values); `shift > 0` means `node` is an interior (32
/// child pointers).
fn traceTrie(node: *HeapHeader, shift: u32, visitor: anytype) void {
    if (!visitor.markInternal(node)) return;
    if (shift == 0) {
        // Leaf: 32 Value slots.
        for (leafValues(node)) |elem| visitor.markValue(elem);
    } else {
        // Interior: 32 ?*HeapHeader child slots.
        const next_shift: u32 = shift - branch_bits;
        for (interiorChildren(node)) |child_opt| {
            if (child_opt) |c| traceTrie(c, next_shift, visitor);
        }
    }
}

// =============================================================================
// Cursor — streaming ordered iteration for cross-kind walking
//
// Peer-AI turn-7: cross-kind `sequentialEqual` uses cursor-based walks
// rather than `count + nth` so the pattern generalizes to lazy-seq and
// cons without random-access. Vector's v1 cursor uses `nth(i)` per
// step — O(log₃₂ n) per element; a Phase 6 optimization can rewrite
// to leaf-wise traversal without changing the public shape.
// =============================================================================

pub const Cursor = struct {
    root: Value,
    index: usize,

    pub fn init(v: Value) Cursor {
        std.debug.assert(v.kind() == .persistent_vector);
        return .{ .root = v, .index = 0 };
    }

    pub fn next(self: *Cursor) ?Value {
        const n = count(self.root);
        if (self.index >= n) return null;
        const v = nth(self.root, self.index);
        self.index += 1;
        return v;
    }
};

// =============================================================================
// Private — trie construction helpers
// =============================================================================

/// Compute the maximum element capacity of a trie at `shift`.
/// A trie at shift `s` holds `32^((s / 5) + 1)` leaves worth of
/// elements. We compute it as `32 << s` which equals `2^(5 + s) = 32 * 32^(s/5)`
/// when `s` is a multiple of 5.
fn capacityAtShift(shift: u32) usize {
    // shift is always a multiple of branch_bits in a valid trie.
    return @as(usize, 1) << @intCast(branch_bits + shift);
}

/// Clone an existing interior node. New node has the same children.
fn cloneInterior(heap: *Heap, src: *HeapHeader) !*HeapHeader {
    const new = try allocInterior(heap);
    @memcpy(interiorChildren(new), interiorChildren(src));
    return new;
}

/// Build a fresh tail node that's an exact copy of an existing tail
/// PROMOTED to leaf shape (a full 32-Value leaf). The source MUST
/// have exactly 32 values (tail was full).
fn leafFromTail(heap: *Heap, tail: *HeapHeader) !*HeapHeader {
    const tail_vals = tailValuesConst(tail);
    std.debug.assert(tail_vals.len == branch_factor);
    const leaf = try allocLeaf(heap);
    @memcpy(leafValues(leaf), tail_vals);
    return leaf;
}

/// Build a chain of interior nodes from `level_shift` down to level 0
/// (leaf level), each of which has the constructed path in slot 0 and
/// null elsewhere, terminating in `leaf` at the bottom. Used when
/// growing shift or when the inserted path is fresh.
fn newPath(heap: *Heap, level_shift: u32, leaf: *HeapHeader) !*HeapHeader {
    if (level_shift == 0) return leaf;
    const node = try allocInterior(heap);
    const children = interiorChildren(node);
    children[0] = try newPath(heap, level_shift - branch_bits, leaf);
    return node;
}

/// Insert `leaf` into the trie rooted at `root` at the position
/// corresponding to `idx` (the first element-index the leaf will
/// cover, i.e., `tail_offset`). Returns a new root (path-copied as
/// necessary). Precondition: the trie at `shift` has room for another
/// leaf (checked by caller via `capacityAtShift`).
fn pushLeaf(
    heap: *Heap,
    root: *HeapHeader,
    shift: u32,
    idx: u32,
    leaf: *HeapHeader,
) !*HeapHeader {
    // Path-copy descent. At each level, pick the child slot for `idx`
    // at the current shift; if it's null, materialize a fresh path
    // from here to the leaf. Otherwise clone the subtree and recurse.
    std.debug.assert(shift > 0);
    const local_idx: usize = (idx >> @intCast(shift)) & branch_mask;
    const cloned = try cloneInterior(heap, root);
    const children = interiorChildren(cloned);
    if (shift == branch_bits) {
        // Children of this interior are leaves. Insert directly.
        std.debug.assert(children[local_idx] == null);
        children[local_idx] = leaf;
    } else if (children[local_idx]) |existing_child| {
        children[local_idx] = try pushLeaf(heap, existing_child, shift - branch_bits, idx, leaf);
    } else {
        children[local_idx] = try newPath(heap, shift - branch_bits, leaf);
    }
    return cloned;
}

/// Index-based trie lookup starting from a root header. Used by
/// `hashSeq` and `equalSeq` to avoid re-deriving the whole root body
/// per element. For bulk iteration a future optimization can cache
/// the current leaf; for Scope A this is O(log₃₂ n) per call.
fn nthFromHeader(h: *HeapHeader, i: usize) Value {
    const body = rootBodyConst(h);
    const tail_offset: usize = body.count - body.tail_len;
    if (i >= tail_offset) {
        return tailValuesConst(body.tail_node.?)[i - tail_offset];
    }
    var node: *HeapHeader = body.root_node.?;
    var level_shift: u32 = body.shift;
    while (level_shift > 0) {
        const child_idx: usize = (i >> @intCast(level_shift)) & branch_mask;
        node = interiorChildren(node)[child_idx].?;
        level_shift -= branch_bits;
    }
    return leafValues(node)[i & branch_mask];
}

// =============================================================================
// Inline tests — representation + invariants + scope-A behavior.
// Cross-kind list↔vector tests live in src/dispatch.zig and
// test/prop/vector.zig.
// =============================================================================

test "empty: count 0, isEmpty true, no allocations for internal nodes" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try empty(&heap);
    try testing.expect(v.kind() == .persistent_vector);
    try testing.expectEqual(subkind_root, v.subkind());
    try testing.expect(isEmpty(v));
    try testing.expectEqual(@as(usize, 0), count(v));
    try testing.expectEqual(@as(usize, 1), heap.liveCount()); // just the root
}

test "conj of a single element: count 1, stored in tail" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const e = try empty(&heap);
    const one = try conj(&heap, e, value.fromFixnum(42).?);
    try testing.expectEqual(@as(usize, 1), count(one));
    try testing.expect(!isEmpty(one));
    try testing.expectEqual(@as(i64, 42), nth(one, 0).asFixnum());
}

test "fromSlice + nth: round-trip at sizes 0, 1, 31, 32, 33" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const sizes = [_]usize{ 0, 1, 31, 32, 33 };
    for (sizes) |n| {
        const elems = try testing.allocator.alloc(Value, n);
        defer testing.allocator.free(elems);
        for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
        const v = try fromSlice(&heap, elems);
        try testing.expectEqual(n, count(v));
        for (0..n) |i| {
            try testing.expectEqual(@as(i64, @intCast(i)), nth(v, i).asFixnum());
        }
    }
}

test "fromSlice + nth: round-trip across trie depth boundaries (1024, 1025)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const sizes = [_]usize{ 1024, 1025 };
    for (sizes) |n| {
        const elems = try testing.allocator.alloc(Value, n);
        defer testing.allocator.free(elems);
        for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
        const v = try fromSlice(&heap, elems);
        try testing.expectEqual(n, count(v));
        // Spot-check a dense set of indices plus boundary sites.
        const probe = [_]usize{ 0, 1, 31, 32, 33, 1022, 1023, 1024 };
        for (probe) |i| if (i < n) {
            try testing.expectEqual(@as(i64, @intCast(i)), nth(v, i).asFixnum());
        };
    }
}

test "fromSlice + nth: round-trip at large size 32768 (trie depth 2 full) and 32769" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const sizes = [_]usize{ 32768, 32769 };
    for (sizes) |n| {
        const elems = try testing.allocator.alloc(Value, n);
        defer testing.allocator.free(elems);
        for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
        const v = try fromSlice(&heap, elems);
        try testing.expectEqual(n, count(v));
        // Dense spot-check across the full range.
        const probe = [_]usize{ 0, 31, 32, 1023, 1024, 32767, 32768 };
        for (probe) |i| if (i < n) {
            try testing.expectEqual(@as(i64, @intCast(i)), nth(v, i).asFixnum());
        };
    }
}

test "conj at 32→33 boundary: old tail promoted to leaf, shift becomes 5" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var v = try empty(&heap);
    for (0..33) |i| {
        v = try conj(&heap, v, value.fromFixnum(@intCast(i)).?);
    }
    try testing.expectEqual(@as(usize, 33), count(v));
    const body = rootBodyConst(rootHeader(v));
    try testing.expectEqual(@as(u32, branch_bits), body.shift);
    try testing.expect(body.root_node != null);
    try testing.expectEqual(@as(u32, 1), body.tail_len);
    // Full round-trip via nth.
    for (0..33) |i| try testing.expectEqual(@as(i64, @intCast(i)), nth(v, i).asFixnum());
}

test "immutability: conj on a vector does not mutate the source" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    _ = try conj(&heap, a, value.fromFixnum(99).?);
    // Original still has count 3 and values intact.
    try testing.expectEqual(@as(usize, 3), count(a));
    try testing.expectEqual(@as(i64, 1), nth(a, 0).asFixnum());
    try testing.expectEqual(@as(i64, 2), nth(a, 1).asFixnum());
    try testing.expectEqual(@as(i64, 3), nth(a, 2).asFixnum());
}

test "equalSeq: reflexive and symmetric across distinct allocations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromFixnum(10).?,
        value.fromFixnum(20).?,
        value.fromFixnum(30).?,
    };
    const a = try fromSlice(&heap, &elems);
    const b = try fromSlice(&heap, &elems);
    const ah = rootHeader(a);
    const bh = rootHeader(b);
    try testing.expect(ah != bh);
    const SynthEq = struct {
        fn f(x: Value, y: Value) bool {
            if (x.tag == y.tag and x.payload == y.payload) return true;
            if (x.kind() != y.kind()) return false;
            return switch (x.kind()) {
                .fixnum => x.asFixnum() == y.asFixnum(),
                else => false,
            };
        }
    };
    try testing.expect(equalSeq(ah, bh, &SynthEq.f));
    try testing.expect(equalSeq(bh, ah, &SynthEq.f));
    try testing.expect(equalSeq(ah, ah, &SynthEq.f));
}

test "equalSeq: length mismatch breaks equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromSlice(&heap, &.{ value.fromFixnum(1).?, value.fromFixnum(2).? });
    const b = try fromSlice(&heap, &.{value.fromFixnum(1).?});
    const SynthEq = struct {
        fn f(x: Value, y: Value) bool {
            if (x.kind() != y.kind()) return false;
            return x.asFixnum() == y.asFixnum();
        }
    };
    try testing.expect(!equalSeq(rootHeader(a), rootHeader(b), &SynthEq.f));
}

test "hashSeq: matches manual ordered-combine for small vector" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    };
    const v = try fromSlice(&heap, &elems);

    var expected: u64 = hash_mod.ordered_init;
    expected = hash_mod.combineOrdered(expected, elems[0].hashImmediate());
    expected = hash_mod.combineOrdered(expected, elems[1].hashImmediate());
    expected = hash_mod.combineOrdered(expected, elems[2].hashImmediate());
    expected = hash_mod.finalizeOrdered(expected, 3);

    const SynthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    };
    try testing.expectEqual(expected, hashSeq(rootHeader(v), &SynthHash.f));
}

test "hashSeq: equal vectors share pre-mix hash across allocations" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromFixnum(7).?,
        value.fromKeywordId(3),
        value.fromChar('z').?,
    };
    const a = try fromSlice(&heap, &elems);
    const b = try fromSlice(&heap, &elems);
    const SynthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    };
    try testing.expectEqual(hashSeq(rootHeader(a), &SynthHash.f), hashSeq(rootHeader(b), &SynthHash.f));
}

test "hashSeq: empty vector matches empty ordered-combine with count 0" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try empty(&heap);
    const expected = hash_mod.finalizeOrdered(hash_mod.ordered_init, 0);
    const SynthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    };
    try testing.expectEqual(expected, hashSeq(rootHeader(v), &SynthHash.f));
}

test "Cursor: streams head-to-tail, null on exhaustion" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromSlice(&heap, &.{
        value.fromFixnum(10).?,
        value.fromFixnum(20).?,
        value.fromFixnum(30).?,
    });
    var c = Cursor.init(v);
    try testing.expectEqual(@as(i64, 10), c.next().?.asFixnum());
    try testing.expectEqual(@as(i64, 20), c.next().?.asFixnum());
    try testing.expectEqual(@as(i64, 30), c.next().?.asFixnum());
    try testing.expectEqual(@as(?Value, null), c.next());
    try testing.expectEqual(@as(?Value, null), c.next());
}

test "Cursor: empty vector yields null on first next()" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const e = try empty(&heap);
    var c = Cursor.init(e);
    try testing.expectEqual(@as(?Value, null), c.next());
}

test "capacityAtShift: trie capacity grows by 32 per shift level" {
    try testing.expectEqual(@as(usize, 32), capacityAtShift(0));
    try testing.expectEqual(@as(usize, 1024), capacityAtShift(5));
    try testing.expectEqual(@as(usize, 32768), capacityAtShift(10));
    try testing.expectEqual(@as(usize, 1024 * 1024), capacityAtShift(15));
}

test "conj just past shift-5 leaf capacity (1024 + 1): still shift 5, tail=1" {
    // A trie at shift 5 holds 32 leaves × 32 elements = 1024 elements
    // plus a 32-element tail = 1056 total before overflowing. At count
    // 1025 the trie holds 992 (31 full leaves) + the new leaf (from
    // the tail-at-1023 promotion) = 1024, and the tail has 1 element.
    // No shift growth yet.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var v = try empty(&heap);
    var i: usize = 0;
    while (i < 1025) : (i += 1) {
        v = try conj(&heap, v, value.fromFixnum(@intCast(i)).?);
    }
    const body = rootBodyConst(rootHeader(v));
    try testing.expectEqual(@as(u32, 1025), body.count);
    try testing.expectEqual(@as(u32, branch_bits), body.shift); // still 5
    try testing.expectEqual(@as(u32, 1), body.tail_len);
}

test "conj at the actual shift-5 → shift-10 overflow (1056 + 1 = 1057)" {
    // The shift-growth boundary is at count 1057 (capacityAtShift(5)
    // = 1024 trie elements + 32 tail = 1056 max before forcing a new
    // level). At count 1057 the trie root must grow to shift 10.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var v = try empty(&heap);
    var i: usize = 0;
    while (i < 1057) : (i += 1) {
        v = try conj(&heap, v, value.fromFixnum(@intCast(i)).?);
    }
    const body = rootBodyConst(rootHeader(v));
    try testing.expectEqual(@as(u32, 1057), body.count);
    try testing.expectEqual(@as(u32, 2 * branch_bits), body.shift); // 10
    try testing.expectEqual(@as(u32, 1), body.tail_len);
    // Verify element integrity across the shift boundary.
    const probe = [_]usize{ 0, 31, 32, 1023, 1024, 1055, 1056 };
    for (probe) |idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), nth(v, idx).asFixnum());
    }
}

test "conj at the actual shift-10 → shift-15 overflow (32800 + 1 = 32801)" {
    // The deep growth boundary: a shift-10 trie holds
    // capacityAtShift(10) = 32768 elements plus a 32-element tail =
    // 32800 total before forcing a new level. At count 32801 shift
    // grows to 15. This test validates the recursive newPath
    // construction at the deepest depth v1 exercises.
    const gpa = std.testing.allocator;
    var heap = Heap.init(gpa);
    defer heap.deinit();
    var v = try empty(&heap);
    var i: usize = 0;
    while (i < 32801) : (i += 1) {
        v = try conj(&heap, v, value.fromFixnum(@intCast(i)).?);
    }
    const body = rootBodyConst(rootHeader(v));
    try testing.expectEqual(@as(u32, 32801), body.count);
    try testing.expectEqual(@as(u32, 3 * branch_bits), body.shift); // 15
    try testing.expectEqual(@as(u32, 1), body.tail_len);
    // Spot-check at deep-trie boundaries.
    const probe = [_]usize{ 0, 31, 1023, 1024, 32767, 32768, 32799, 32800 };
    for (probe) |idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), nth(v, idx).asFixnum());
    }
}

test "conj just past shift-10 capacity (32768 + 1): still shift 10, tail=1" {
    // A trie at shift 10 holds 32 * 32 * 32 = 32768 elements
    // plus a 32-element tail = 32800 total before overflow. At
    // count 32769 the trie is exactly full; tail has 1 element.
    // No shift growth yet.
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var v = try empty(&heap);
    var i: usize = 0;
    while (i < 32769) : (i += 1) {
        v = try conj(&heap, v, value.fromFixnum(@intCast(i)).?);
    }
    const body = rootBodyConst(rootHeader(v));
    try testing.expectEqual(@as(u32, 32769), body.count);
    try testing.expectEqual(@as(u32, 2 * branch_bits), body.shift); // 10
    try testing.expectEqual(@as(u32, 1), body.tail_len);
    // Spot-check a few indices across the range to confirm the trie
    // pathing survived the grow operations.
    const probe = [_]usize{ 0, 1023, 1024, 32767, 32768 };
    for (probe) |idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), nth(v, idx).asFixnum());
    }
}
