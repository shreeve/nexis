//! coll/vector.zig — persistent vector heap kind.
//!
//! **This is plain 32-way radix trie + tail buffer, NOT RRB-relaxed.**
//! Despite the canonical academic name "RRB tree," the implementation
//! is the same shape Clojure ships (PLAN §9.2 + §23 #30). There is no
//! RRB relaxation. The module is named `vector` for user-facing
//! clarity.
//!
//! Authoritative spec: `docs/VECTOR.md`. Semantic framing:
//! `docs/SEMANTICS.md` §2.6 (sequential equality category) and §3.2
//! (shared-sequential hash domain byte `0xF0`). Physical storage:
//! `docs/HEAP.md`.
//!
//! Cross-kind sequential equality invariant: `(= (list 1 2 3) [1 2 3])`
//! is true and `(hash (list 1 2 3)) == (hash [1 2 3])` holds by
//! construction. See `test "cross-kind: (list 1 2 3) and [1 2 3] are
//! equal and share hashValue"` in `src/dispatch.zig`.
//!
//! Surface: `empty` / `fromSlice` / `conj` / `assoc` / `pop` / `count`
//! / `nth` / `isEmpty` / `hashSeq` / `equalSeq` / `Cursor` / `trace`.
//! There is no `subvec` or `concat`, and no small-vector inline
//! subkind; transients wrap this module from `src/coll/transient.zig`.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const hash_mod = @import("../hash.zig");

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
// Per VECTOR.md §2-§3. Four node roles (root / interior / leaf / tail)
// share one heap kind and are not tagged: every internal access,
// including `trace`, derives a node's role from structural context
// (root.shift + descent level). Only vector.zig traverses these
// allocations.
// =============================================================================

/// Root vector body. Every vector — empty, small, or
/// large — uses this exact 32-byte layout.
const RootBody = extern struct {
    /// Total element count, including tail.
    count: u32,
    /// Root trie shift. `0` when `count ≤ 32` (all elements in tail);
    /// `5` for a depth-1 trie (root points at leaves); `10` for
    /// depth-2; and so on.
    shift: u32,
    /// Root trie node pointer. `null` when `count ≤ 32` (empty trie).
    /// Otherwise an interior node, whose children are leaves when
    /// shift == 5.
    root_node: ?*HeapHeader,
    /// Tail node pointer. `null` only when `count == 0`.
    tail_node: ?*HeapHeader,
    /// Tail length in Values, 0..32 (0 only for the empty vector).
    /// Stored because `count % 32` misreports a full tail as empty.
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
/// A root for an update of the vector rooted at `src`: it carries
/// `src`'s metadata, as every Clojure collection update does
/// (SEMANTICS §7).
fn allocDerivedRoot(heap: *Heap, src: *HeapHeader) !*HeapHeader {
    const h = try allocRoot(heap);
    h.setMeta(src.getMeta());
    return h;
}

fn allocInterior(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_vector, interior_body_size);
}

/// Fresh zeroed leaf node — 32 Value slots. Leaves are always full in
/// canonical form; caller writes all 32 slots before using.
fn allocLeaf(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_vector, leaf_body_size);
}

/// Fresh zeroed tail node of `len` Values, `len` in `[1, 32]`. An
/// empty vector has no tail node: its root's `tail_node` is null.
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
/// subkind-1 vector root (no other vector subkind is user-facing),
/// so no subkind inference is needed.
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
/// Three paths:
///   (a) tail not full (or absent) → allocate a (tail_len+1)-length
///       tail with the old elements + the appended element.
///   (b) tail full + trie has room → push old tail into trie as a
///       leaf; start new 1-element tail.
///   (c) tail full + trie at capacity → grow shift by 5; new root
///       interior node has old root in slot 0 and a freshly-built
///       path to the promoted leaf in slot 1; start new tail.
pub fn conj(heap: *Heap, v: Value, elem: Value) !Value {
    const src_h = rootHeader(v);
    const src = rootBody(src_h);

    // Path (a): tail has room → grow tail by 1.
    if (src.tail_len < branch_factor) {
        const new_tail = try allocTail(heap, src.tail_len + 1);
        const new_tail_values = tailValues(new_tail);
        if (src.tail_node) |t| @memcpy(new_tail_values[0..src.tail_len], tailValues(t));
        new_tail_values[src.tail_len] = elem;

        const new_root_h = try allocDerivedRoot(heap, src_h);
        const new_root = rootBody(new_root_h);
        new_root.* = src.*;
        new_root.count = src.count + 1;
        new_root.tail_node = new_tail;
        new_root.tail_len = src.tail_len + 1;
        return valueFromRoot(new_root_h);
    }

    // Tail is full (len == 32). Old tail becomes a leaf under the
    // trie; new tail starts with the appended element.
    const new_tail = try allocTail(heap, 1);
    tailValues(new_tail)[0] = elem;

    // A full tail and a leaf share one layout: the tail joins the trie
    // as it stands.
    const promoted_leaf = src.tail_node.?;
    // `promoted_leaf_base` is the logical element index the promoted
    // leaf covers from: the leaf spans indices
    // `[promoted_leaf_base, promoted_leaf_base + 32)`. Derived from
    // the OLD count, not the new one.
    const promoted_leaf_base: u32 = src.count - @as(u32, branch_factor);
    // `elems_after_promotion` is how many elements the trie must
    // address once the promoted leaf is in place: old count (which
    // already includes the 32 elements in the tail that are about to
    // become the promoted leaf).
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
    // GC-interaction note: this function allocates several heap
    // objects (new_tail, path clones or new interiors, new_root_h)
    // before any of them is reachable from a user-held Value.
    // `Heap.alloc` never triggers a collection (GC.md §7: a cycle runs
    // only at the VM's instruction fetch), so no temporary root-stack
    // is needed to protect the partial tree.
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

    const new_root_h = try allocDerivedRoot(heap, src_h);
    const new_root = rootBody(new_root_h);
    new_root.count = src.count + 1;
    new_root.shift = new_shift;
    new_root.root_node = new_root_node;
    new_root.tail_node = new_tail;
    new_root.tail_len = 1;
    return valueFromRoot(new_root_h);
}

/// `v` with element `i` replaced by `elem`, sharing every node not
/// on the path to `i`. O(1) when `i` is in the tail, O(log₃₂ n)
/// through the trie. `i` must be in bounds.
pub fn assoc(heap: *Heap, v: Value, i: usize, elem: Value) !Value {
    const src_h = rootHeader(v);
    const src = rootBody(src_h);
    std.debug.assert(i < src.count);
    const new_root_h = try allocDerivedRoot(heap, src_h);
    const new_root = rootBody(new_root_h);
    new_root.* = src.*;
    const tail_offset: usize = src.count - src.tail_len;
    if (i >= tail_offset) {
        const new_tail = try allocTail(heap, src.tail_len);
        @memcpy(tailValues(new_tail), tailValues(src.tail_node.?));
        tailValues(new_tail)[i - tail_offset] = elem;
        new_root.tail_node = new_tail;
    } else {
        new_root.root_node = try assocPath(heap, src.root_node.?, src.shift, i, elem);
    }
    return valueFromRoot(new_root_h);
}

/// Copy the path from `node` (at `level_shift`) down to the leaf
/// holding `i`, with `elem` stored there.
fn assocPath(heap: *Heap, node: *HeapHeader, level_shift: u32, i: usize, elem: Value) !*HeapHeader {
    if (level_shift == 0) {
        const leaf = try allocLeaf(heap);
        @memcpy(leafValues(leaf), leafValues(node));
        leafValues(leaf)[i & branch_mask] = elem;
        return leaf;
    }
    const clone = try cloneInterior(heap, node);
    const child_idx: usize = (i >> @intCast(level_shift)) & branch_mask;
    interiorChildren(clone)[child_idx] = try assocPath(heap, interiorChildren(node)[child_idx].?, level_shift - branch_bits, i, elem);
    return clone;
}

/// `v` without its last element, sharing every node not on the path
/// to it. O(1) while the tail holds more than one element; otherwise
/// the trie's last leaf becomes the tail, its path is removed, and a
/// root left with a single child is replaced by that child (the shift
/// drops by 5). `v` must not be empty.
pub fn pop(heap: *Heap, v: Value) !Value {
    const src_h = rootHeader(v);
    const src = rootBody(src_h);
    std.debug.assert(src.count > 0);
    if (src.count == 1) {
        const e = try empty(heap);
        Heap.asHeapHeader(e).setMeta(src_h.getMeta());
        return e;
    }
    const new_root_h = try allocDerivedRoot(heap, src_h);
    const new_root = rootBody(new_root_h);
    new_root.* = src.*;
    new_root.count = src.count - 1;
    if (src.tail_len > 1) {
        const new_tail = try allocTail(heap, src.tail_len - 1);
        @memcpy(tailValues(new_tail), tailValues(src.tail_node.?)[0 .. src.tail_len - 1]);
        new_root.tail_node = new_tail;
        new_root.tail_len = src.tail_len - 1;
        return valueFromRoot(new_root_h);
    }
    // A leaf and a full tail share one layout, so the leaf is the new
    // tail as it stands.
    const last = src.count - 2;
    new_root.tail_node = leafFor(src, last);
    new_root.tail_len = branch_factor;
    var trie = try popTail(heap, src.root_node.?, src.shift, last);
    var shift = src.shift;
    if (trie) |t| {
        if (shift > branch_bits and interiorChildren(t)[1] == null) {
            trie = interiorChildren(t)[0];
            shift -= branch_bits;
        }
    } else shift = 0;
    new_root.root_node = trie;
    new_root.shift = shift;
    return valueFromRoot(new_root_h);
}

/// The trie under `node` (at `level_shift`) without the leaf holding
/// index `last`, the trie's final element; null when nothing is left.
fn popTail(heap: *Heap, node: *HeapHeader, level_shift: u32, last: usize) !?*HeapHeader {
    const idx: usize = (last >> @intCast(level_shift)) & branch_mask;
    const child: ?*HeapHeader = if (level_shift > branch_bits)
        try popTail(heap, interiorChildren(node)[idx].?, level_shift - branch_bits, last)
    else
        null;
    if (child == null and idx == 0) return null;
    const clone = try cloneInterior(heap, node);
    interiorChildren(clone)[idx] = child;
    return clone;
}

/// Build a vector from a slice, in natural order. The trie is built
/// bottom-up, one allocation per node, into exactly the shape a
/// left fold of `conj` produces.
pub fn fromSlice(heap: *Heap, elems: []const Value) !Value {
    if (elems.len == 0) return empty(heap);
    const n = std.math.cast(u32, elems.len) orelse return error.Overflow;
    const tail_offset: u32 = (n - 1) & ~branch_mask;
    const tail = try allocTail(heap, n - tail_offset);
    @memcpy(tailValues(tail), elems[tail_offset..]);
    var shift: u32 = 0;
    var trie: ?*HeapHeader = null;
    if (tail_offset > 0) {
        shift = branch_bits;
        while (tail_offset > capacityAtShift(shift)) shift += branch_bits;
        trie = try buildTrie(heap, elems[0..tail_offset], shift);
    }
    const root_h = try allocRoot(heap);
    const root = rootBody(root_h);
    root.count = n;
    root.shift = shift;
    root.root_node = trie;
    root.tail_node = tail;
    root.tail_len = n - tail_offset;
    return valueFromRoot(root_h);
}

/// The node at `level_shift` holding `elems`, a non-empty multiple of
/// 32 elements that fits under it; children fill from slot 0.
fn buildTrie(heap: *Heap, elems: []const Value, level_shift: u32) !*HeapHeader {
    if (level_shift == 0) {
        const leaf = try allocLeaf(heap);
        @memcpy(leafValues(leaf), elems);
        return leaf;
    }
    const node = try allocInterior(heap);
    const span = capacityAtShift(level_shift - branch_bits);
    var start: usize = 0;
    var slot: usize = 0;
    while (start < elems.len) : ({
        start += span;
        slot += 1;
    }) {
        const chunk = elems[start..@min(start + span, elems.len)];
        interiorChildren(node)[slot] = try buildTrie(heap, chunk, level_shift - branch_bits);
    }
    return node;
}

// =============================================================================
// Public API — accessors
// =============================================================================

pub fn count(v: Value) usize {
    return rootBody(rootHeader(v)).count;
}

pub fn isEmpty(v: Value) bool {
    return rootBody(rootHeader(v)).count == 0;
}

/// Element at logical index `i`. Panics in safe builds on out-of-
/// bounds. O(log₃₂ n) via trie descent when `i` is in the trie;
/// O(1) when `i` is in the tail.
pub fn nth(v: Value, i: usize) Value {
    const h = rootHeader(v);
    if (std.debug.runtime_safety) {
        const n = rootBody(h).count;
        if (i >= n) std.debug.panic("vector.nth: index {d} out of bounds (count {d})", .{ i, n });
    }
    return chunkFor(rootBody(h), i)[i & branch_mask];
}

// =============================================================================
// Per-kind hash + equality (called by dispatch)
// =============================================================================

/// Ordered-combine hash over the logical element sequence, at u32
/// precision and cached in the root header (SEMANTICS.md §3.1).
/// Matches `list.hashSeq` exactly, so equal element sequences produce
/// equal pre-mix bases across list and vector.
pub fn hashSeq(h: *HeapHeader, elementHash: *const fn (Value) u64) u64 {
    std.debug.assert(h.kind == @intFromEnum(Kind.persistent_vector));
    if (h.cachedHash()) |cached| return cached;
    var acc: u64 = hash_mod.ordered_init;
    var c = Cursor.fromHeader(h);
    while (c.next()) |elem| acc = hash_mod.combineOrdered(acc, elementHash(elem));
    const truncated: u32 = @truncate(hash_mod.finalizeOrdered(acc, c.count));
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// Pairwise structural equality. Called by dispatch when both sides
/// are kind `.persistent_vector`. Returns false on count mismatch;
/// otherwise walks both in lock-step.
pub fn equalSeq(
    a: *HeapHeader,
    b: *HeapHeader,
    elementEq: *const fn (Value, Value) bool,
) bool {
    std.debug.assert(a.kind == @intFromEnum(Kind.persistent_vector));
    std.debug.assert(b.kind == @intFromEnum(Kind.persistent_vector));
    if (a == b) return true;
    var ca = Cursor.fromHeader(a);
    var cb = Cursor.fromHeader(b);
    if (ca.count != cb.count) return false;
    while (ca.next()) |x| {
        if (!elementEq(x, cb.next().?)) return false;
    }
    return true;
}

// =============================================================================
// GC trace (GC.md §5)
//
// Vector trace walks the trie nodes directly via
// `visitor.markInternal`. External Value references (leaf/tail
// elements) route through `visitor.markValue`. Internal nodes have
// no metadata (VECTOR.md §3 invariant), so `markInternal` skips the
// meta chain. A node reachable twice (a full tail that is also the
// trie's last leaf) is walked once: `markInternal` reports it marked.
// =============================================================================

/// Walk the vector rooted at `h`. `h` itself is already marked by the
/// collector. Walks: tail_node + its values; root_node recursively +
/// every leaf's values.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = rootBody(h);
    if (body.tail_node) |tn| {
        if (visitor.markInternal(tn)) {
            // Tail node body is [tail_len] Value — walk and mark
            // heap-kind children.
            for (tailValues(tn)) |elem| visitor.markValue(elem);
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
// Cursor — streaming ordered iteration
//
// Cross-kind `sequentialEqual` walks cursors rather than `count + nth`
// so the pattern serves list and cons without random access. The
// cursor holds the current leaf (or the tail), so a walk descends the
// trie once per 32 elements: O(n) in all.
// =============================================================================

pub const Cursor = struct {
    root: *HeapHeader,
    count: usize,
    index: usize = 0,
    /// The leaf or tail holding `index` once it is loaded; its first
    /// element is at `chunk_base`.
    chunk: []const Value = &.{},
    chunk_base: usize = 0,

    pub fn init(v: Value) Cursor {
        return fromHeader(rootHeader(v));
    }

    /// A cursor whose first element is the one at `start` (≤ count);
    /// the walk of a list view (LIST.md §1).
    pub fn initAt(v: Value, start: usize) Cursor {
        var c = init(v);
        std.debug.assert(start <= c.count);
        c.index = start;
        return c;
    }

    fn fromHeader(h: *HeapHeader) Cursor {
        return .{ .root = h, .count = rootBody(h).count };
    }

    pub fn next(self: *Cursor) ?Value {
        if (self.index >= self.count) return null;
        if (self.index - self.chunk_base >= self.chunk.len) {
            self.chunk = chunkFor(rootBody(self.root), self.index);
            self.chunk_base = self.index & ~@as(usize, branch_mask);
        }
        const v = self.chunk[self.index - self.chunk_base];
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

/// The leaf or the tail holding index `i`. Both start at a multiple
/// of 32, so `i & branch_mask` indexes into the result.
fn chunkFor(body: *const RootBody, i: usize) []const Value {
    if (i >= body.count - body.tail_len) return tailValues(body.tail_node.?);
    return leafValues(leafFor(body, i));
}

/// The leaf holding index `i`, which lies in the trie
/// (`i < count - tail_len`).
fn leafFor(body: *const RootBody, i: usize) *HeapHeader {
    var node: *HeapHeader = body.root_node.?;
    var level_shift: u32 = body.shift;
    while (level_shift > 0) : (level_shift -= branch_bits) {
        node = interiorChildren(node)[(i >> @intCast(level_shift)) & branch_mask].?;
    }
    return node;
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

/// Test helper: `a` and `b` have the same root fields, the same tail
/// elements and the same trie shape, node for node.
fn expectSameShape(a: Value, b: Value) !void {
    const x = rootBody(rootHeader(a));
    const y = rootBody(rootHeader(b));
    try testing.expectEqual(x.count, y.count);
    try testing.expectEqual(x.shift, y.shift);
    try testing.expectEqual(x.tail_len, y.tail_len);
    try testing.expectEqual(x.tail_node == null, y.tail_node == null);
    if (x.tail_node) |t| try expectSameValues(tailValues(t), tailValues(y.tail_node.?));
    try testing.expectEqual(x.root_node == null, y.root_node == null);
    if (x.root_node) |r| try expectSameNode(r, y.root_node.?, x.shift);
}

fn expectSameNode(a: *HeapHeader, b: *HeapHeader, level_shift: u32) !void {
    if (level_shift == 0) return expectSameValues(leafValues(a), leafValues(b));
    for (interiorChildren(a), interiorChildren(b)) |ca, cb| {
        try testing.expectEqual(ca == null, cb == null);
        if (ca) |c| try expectSameNode(c, cb.?, level_shift - branch_bits);
    }
}

fn expectSameValues(a: []const Value, b: []const Value) !void {
    try testing.expect(std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b)));
}

/// Test helper: the vector `[0 1 … n-1]`.
fn rangeVector(heap: *Heap, n: usize) !Value {
    const elems = try testing.allocator.alloc(Value, n);
    defer testing.allocator.free(elems);
    for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
    return fromSlice(heap, elems);
}

test "pop: the result has the shape fromSlice builds, at every trie boundary" {
    // Tens of thousands of nodes: a leak still fails the test, but
    // no stack trace is captured per allocation.
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
    defer heap.deinit();
    const sizes = [_]usize{ 1, 2, 32, 33, 34, 64, 65, 1056, 1057, 1058, 1088, 1089, 32768, 32769, 32800, 32801, 32802 };
    for (sizes) |n| {
        const v = try rangeVector(&heap, n);
        const p = try pop(&heap, v);
        try expectSameShape(try rangeVector(&heap, n - 1), p);
        try testing.expectEqual(n, count(v)); // the source is untouched
        try testing.expectEqual(@as(i64, @intCast(n - 1)), nth(v, n - 1).asFixnum());
    }
}

test "pop: from 1057 down to empty, one element at a time" {
    // Tens of thousands of nodes: a leak still fails the test, but
    // no stack trace is captured per allocation.
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
    defer heap.deinit();
    var v = try rangeVector(&heap, 1057);
    var n: usize = 1057;
    while (n > 0) : (n -= 1) {
        v = try pop(&heap, v);
        try expectSameShape(try rangeVector(&heap, n - 1), v);
    }
    try testing.expect(isEmpty(v));
}

test "pop then conj: the trie regrows to the same shape" {
    // Tens of thousands of nodes: a leak still fails the test, but
    // no stack trace is captured per allocation.
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
    defer heap.deinit();
    for ([_]usize{ 33, 1057, 32801 }) |n| {
        const v = try rangeVector(&heap, n);
        const again = try conj(&heap, try pop(&heap, v), value.fromFixnum(@intCast(n - 1)).?);
        try expectSameShape(v, again);
    }
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

test "assoc: replaces one element in the tail or the trie and leaves the source intact" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const n: usize = 1025;
    const elems = try testing.allocator.alloc(Value, n);
    defer testing.allocator.free(elems);
    for (elems, 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
    const v = try fromSlice(&heap, elems);
    const probe = [_]usize{ 0, 31, 32, 500, 1023, 1024 };
    for (probe) |i| {
        const w = try assoc(&heap, v, i, value.fromFixnum(-1).?);
        try testing.expectEqual(n, count(w));
        for (0..n) |j| {
            const expected: i64 = if (j == i) -1 else @intCast(j);
            try testing.expectEqual(expected, nth(w, j).asFixnum());
            try testing.expectEqual(@as(i64, @intCast(j)), nth(v, j).asFixnum());
        }
    }
}

test "fromSlice + nth: round-trip at large size 32768 (trie depth 2 full) and 32769" {
    // Tens of thousands of nodes: a leak still fails the test, but
    // no stack trace is captured per allocation.
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
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
    const body = rootBody(rootHeader(v));
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
    expected = @as(u32, @truncate(hash_mod.finalizeOrdered(expected, 3)));

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
    const expected: u64 = @as(u32, @truncate(hash_mod.finalizeOrdered(hash_mod.ordered_init, 0)));
    const SynthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    };
    try testing.expectEqual(expected, hashSeq(rootHeader(v), &SynthHash.f));
}

test "hashSeq caches its result in the root header" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = rootHeader(try rangeVector(&heap, 40));
    const SynthHash = struct {
        fn f(x: Value) u64 {
            return x.hashImmediate();
        }
    };
    try testing.expect(h.cachedHash() == null);
    const first = hashSeq(h, &SynthHash.f);
    try testing.expectEqual(@as(?u32, @intCast(first)), h.cachedHash());
    try testing.expectEqual(first, hashSeq(h, &SynthHash.f));
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
    const body = rootBody(rootHeader(v));
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
    const body = rootBody(rootHeader(v));
    try testing.expectEqual(@as(u32, 1057), body.count);
    try testing.expectEqual(@as(u32, 2 * branch_bits), body.shift); // 10
    try testing.expectEqual(@as(u32, 1), body.tail_len);
    // Verify element integrity across the shift boundary.
    const probe = [_]usize{ 0, 31, 32, 1023, 1024, 1055, 1056 };
    for (probe) |idx| {
        try testing.expectEqual(@as(i64, @intCast(idx)), nth(v, idx).asFixnum());
    }
}

test "conj across the shift-10 → shift-15 boundary (32768 … 32802)" {
    // A shift-10 trie holds capacityAtShift(10) = 32768 elements plus
    // a 32-element tail: 32800 in all. Count 32769 fills the trie
    // exactly; count 32801 grows the shift to 15 through `newPath`.
    // Each conj from 32766 on must land on the shape fromSlice builds.
    // Tens of thousands of nodes: a leak still fails the test, but
    // no stack trace is captured per allocation.
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
    defer heap.deinit();
    var v = try rangeVector(&heap, 32766);
    var n: usize = 32766;
    while (n < 32802) : (n += 1) {
        v = try conj(&heap, v, value.fromFixnum(@intCast(n)).?);
        try expectSameShape(try rangeVector(&heap, n + 1), v);
        const body = rootBody(rootHeader(v));
        try testing.expectEqual(@as(u32, if (n + 1 > 32800) 3 * branch_bits else 2 * branch_bits), body.shift);
    }
    const body = rootBody(rootHeader(v));
    try testing.expectEqual(@as(u32, 32802), body.count);
    try testing.expectEqual(@as(u32, 2), body.tail_len);
    const probe = [_]usize{ 0, 31, 1023, 1024, 32767, 32768, 32799, 32800, 32801 };
    for (probe) |idx| try testing.expectEqual(@as(i64, @intCast(idx)), nth(v, idx).asFixnum());
}

test "fromSlice builds the shape a conj fold builds, at every size up to 1100" {
    // Tens of thousands of nodes: a leak still fails the test, but
    // no stack trace is captured per allocation.
    var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer _ = debug.deinit();
    var heap = Heap.init(debug.allocator());
    defer heap.deinit();
    var v = try empty(&heap);
    var n: usize = 0;
    while (n < 1100) : (n += 1) {
        try expectSameShape(try rangeVector(&heap, n), v);
        v = try conj(&heap, v, value.fromFixnum(@intCast(n)).?);
    }
}
