//! coll/sorted.zig — the persistent sorted map and set heap kinds.
//!
//! Authoritative spec: `docs/SORTED.md`. Kind numbers: `docs/VALUE.md`
//! §2.2 (`sorted_map` 41, `sorted_set` 42). Equality and hashing share
//! the hash map's and hash set's categories and domains
//! (`docs/SEMANTICS.md` §3.3); `dispatch.zig` routes them.
//!
//! One weight-balanced binary tree serves both kinds (Adams' trees with
//! the (3, 2) parameters of Haskell's `Data.Map`, proven by Hirai and
//! Yamamoto): every node records the size of its subtree, and an insert
//! or a delete rebuilds the path it walked with `balance`. Every
//! operation is O(log n) and copies only that path; everything off it
//! is shared with the collection it came from.
//!
//! The order is a comparator the caller passes as a value with a
//! `pub const Error` and an `order(a, b) Error!Order` method: `Natural`
//! (Clojure's `compare`, `naturalOrder` below) or, in the VM, a user
//! function. An insert or a delete makes every comparison on its way
//! down before it allocates anything, so a comparator that re-enters
//! the VM (and may collect) never runs while a node this module built
//! is held only in a Zig local (`docs/GC.md` §11.5).
//!
//! The module never imports `dispatch.zig`: element hashing and
//! equality arrive as function pointers, as in `champ.zig`.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const hash_mod = @import("../hash.zig");
const intern_mod = @import("../intern.zig");
const string_mod = @import("../string.zig");
const bignum_mod = @import("../bignum.zig");
const vector_mod = @import("vector.zig");
const stack = @import("../stack.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

pub const Order = std.math.Order;

const ElementHash = *const fn (Value) u64;
const ElementEq = *const fn (Value, Value) bool;

/// What `Heap.alloc` can fail with.
pub const AllocError = @typeInfo(@typeInfo(@TypeOf(Heap.alloc)).@"fn".return_type.?).error_union.error_set;

/// One entry of a sorted map, or one element of a sorted set (whose
/// `value` is nil).
pub const Entry = struct { key: Value, value: Value };

// =============================================================================
// Layout (SORTED.md §2)
// =============================================================================

/// The block a sorted map or set Value points at.
const Root = extern struct {
    /// The ordering function, or nil for the natural order.
    comparator: Value,
    /// The tree; null when empty.
    tree: ?*HeapHeader,
    _pad: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(Root) == 32);
    }
};

/// A tree node: a block of the collection's kind that no Value points
/// at. A set's node ends before `val`.
const Node = extern struct {
    left: ?*HeapHeader,
    right: ?*HeapHeader,
    /// Nodes in this subtree, this one included.
    size: u64,
    key: Value,
    val: Value,

    comptime {
        std.debug.assert(@sizeOf(Node) == 56);
        std.debug.assert(@offsetOf(Node, "key") == 24);
    }
};

const set_node_bytes = @offsetOf(Node, "val");
const map_node_bytes = @sizeOf(Node);

/// Balance parameters (SORTED.md §3): a subtree of two or more nodes
/// holds at most `delta` times as many nodes on one side as on the
/// other; a rotation is double when the inner grandchild holds at least
/// `ratio` times the outer one.
const delta: u64 = 3;
const ratio: u64 = 2;

/// The tallest tree an iterator's path can hold. The smallest tree of
/// height h grows by 4/3 per level, so a tree of height 128 has more
/// than 2^52 nodes: more memory than any machine has (SORTED.md §3).
pub const max_height = 128;

inline fn node(h: *HeapHeader) *Node {
    return Heap.bodyOf(Node, h);
}

inline fn rootOf(v: Value) *Root {
    return Heap.bodyOf(Root, Heap.asHeapHeader(v));
}

inline fn size(t: ?*HeapHeader) u64 {
    return if (t) |h| node(h).size else 0;
}

inline fn same(a: ?*HeapHeader, b: ?*HeapHeader) bool {
    return a == b;
}

fn entryOf(h: *HeapHeader, is_map: bool) Entry {
    const n = node(h);
    return .{ .key = n.key, .value = if (is_map) n.val else value.nilValue() };
}

pub fn isSortedKind(k: Kind) bool {
    return k == .sorted_map or k == .sorted_set;
}

// =============================================================================
// Construction and accessors
// =============================================================================

/// A fresh empty sorted map (`kind` `.sorted_map`) or set
/// (`.sorted_set`) ordered by `comparator`, nil meaning the natural
/// order.
pub fn empty(heap: *Heap, kind: Kind, comparator: Value) !Value {
    std.debug.assert(isSortedKind(kind));
    const h = try heap.alloc(kind, @sizeOf(Root));
    Heap.bodyOf(Root, h).* = .{ .comparator = comparator, .tree = null };
    return Heap.valueFromHeader(kind, h);
}

/// `v`'s comparator and metadata over `tree`.
fn withTree(heap: *Heap, v: Value, tree: ?*HeapHeader) !Value {
    const h = try heap.alloc(v.kind(), @sizeOf(Root));
    Heap.bodyOf(Root, h).* = .{ .comparator = rootOf(v).comparator, .tree = tree };
    h.setMeta(Heap.asHeapHeader(v).getMeta());
    return Heap.valueFromHeader(v.kind(), h);
}

pub fn count(v: Value) usize {
    return @intCast(size(rootOf(v).tree));
}

/// The comparator `v` was built with; nil for the natural order.
pub fn comparatorOf(v: Value) Value {
    return rootOf(v).comparator;
}

/// The collection holding `entries`, which are in strictly ascending
/// order under `comparator` (the caller has checked): a perfectly
/// balanced tree, built bottom-up with one allocation per node.
pub fn fromSortedEntries(heap: *Heap, kind: Kind, comparator: Value, entries: []const Entry) !Value {
    const v = try empty(heap, kind, comparator);
    rootOf(v).tree = try builder(heap, kind).fromSorted(entries);
    return v;
}

// =============================================================================
// Path copying (SORTED.md §3)
// =============================================================================

const Builder = struct {
    heap: *Heap,
    kind: Kind,
    is_map: bool,

    fn valOf(b: Builder, h: *HeapHeader) Value {
        return if (b.is_map) node(h).val else value.nilValue();
    }

    fn mk(b: Builder, key: Value, val: Value, l: ?*HeapHeader, r: ?*HeapHeader) AllocError!*HeapHeader {
        const h = try b.heap.alloc(b.kind, if (b.is_map) map_node_bytes else set_node_bytes);
        const n = node(h);
        n.left = l;
        n.right = r;
        n.size = size(l) + size(r) + 1;
        n.key = key;
        if (b.is_map) n.val = val;
        return h;
    }

    /// A node over `l` and `r`, rotated when one side has outgrown the
    /// other after one insert or delete below it.
    fn balance(b: Builder, key: Value, val: Value, l: ?*HeapHeader, r: ?*HeapHeader) AllocError!*HeapHeader {
        const sl = size(l);
        const sr = size(r);
        if (sl + sr <= 1) return b.mk(key, val, l, r);
        if (sr > delta * sl) return b.rotateLeft(key, val, l, r.?);
        if (sl > delta * sr) return b.rotateRight(key, val, l.?, r);
        return b.mk(key, val, l, r);
    }

    fn rotateLeft(b: Builder, key: Value, val: Value, l: ?*HeapHeader, r: *HeapHeader) AllocError!*HeapHeader {
        const rn = node(r);
        if (size(rn.left) < ratio * size(rn.right)) {
            return b.mk(rn.key, b.valOf(r), try b.mk(key, val, l, rn.left), rn.right);
        }
        const rl = rn.left.?;
        const rln = node(rl);
        return b.mk(rln.key, b.valOf(rl), try b.mk(key, val, l, rln.left), try b.mk(rn.key, b.valOf(r), rln.right, rn.right));
    }

    fn rotateRight(b: Builder, key: Value, val: Value, l: *HeapHeader, r: ?*HeapHeader) AllocError!*HeapHeader {
        const ln = node(l);
        if (size(ln.right) < ratio * size(ln.left)) {
            return b.mk(ln.key, b.valOf(l), ln.left, try b.mk(key, val, ln.right, r));
        }
        const lr = ln.right.?;
        const lrn = node(lr);
        return b.mk(lrn.key, b.valOf(lr), try b.mk(ln.key, b.valOf(l), ln.left, lrn.left), try b.mk(key, val, lrn.right, r));
    }

    /// `t` with `key` (and, for a map, `val`); `t` itself when the key
    /// is there with a bit-identical value, or for a set at all. A
    /// replaced value keeps the key object the tree holds. Every
    /// comparison happens before the first allocation.
    fn insert(b: Builder, comptime Cmp: type, cmp: Cmp, t: ?*HeapHeader, key: Value, val: Value) (Cmp.Error || AllocError)!*HeapHeader {
        const h = t orelse return b.mk(key, val, null, null);
        const n = node(h);
        switch (try cmp.order(key, n.key)) {
            .lt => {
                const l = try b.insert(Cmp, cmp, n.left, key, val);
                return if (same(l, n.left)) h else b.balance(n.key, b.valOf(h), l, n.right);
            },
            .gt => {
                const r = try b.insert(Cmp, cmp, n.right, key, val);
                return if (same(r, n.right)) h else b.balance(n.key, b.valOf(h), n.left, r);
            },
            .eq => return if (!b.is_map or n.val.identicalTo(val)) h else b.mk(n.key, val, n.left, n.right),
        }
    }

    /// `t` without `key`; `t` itself when the key is absent.
    fn remove(b: Builder, comptime Cmp: type, cmp: Cmp, t: ?*HeapHeader, key: Value) (Cmp.Error || AllocError)!?*HeapHeader {
        const h = t orelse return null;
        const n = node(h);
        switch (try cmp.order(key, n.key)) {
            .lt => {
                const l = try b.remove(Cmp, cmp, n.left, key);
                return if (same(l, n.left)) h else try b.balance(n.key, b.valOf(h), l, n.right);
            },
            .gt => {
                const r = try b.remove(Cmp, cmp, n.right, key);
                return if (same(r, n.right)) h else try b.balance(n.key, b.valOf(h), n.left, r);
            },
            .eq => return b.glue(n.left, n.right),
        }
    }

    /// The tree of `l`'s nodes then `r`'s, which were siblings: the
    /// larger side gives up its extreme node as the new root.
    fn glue(b: Builder, l: ?*HeapHeader, r: ?*HeapHeader) AllocError!?*HeapHeader {
        const lh = l orelse return r;
        const rh = r orelse return l;
        if (size(l) > size(r)) {
            const m = try b.popMax(lh);
            return try b.balance(m.key, m.val, m.rest, r);
        }
        const m = try b.popMin(rh);
        return try b.balance(m.key, m.val, l, m.rest);
    }

    const Popped = struct { key: Value, val: Value, rest: ?*HeapHeader };

    fn popMin(b: Builder, h: *HeapHeader) AllocError!Popped {
        const n = node(h);
        const lh = n.left orelse return .{ .key = n.key, .val = b.valOf(h), .rest = n.right };
        const m = try b.popMin(lh);
        return .{ .key = m.key, .val = m.val, .rest = try b.balance(n.key, b.valOf(h), m.rest, n.right) };
    }

    fn popMax(b: Builder, h: *HeapHeader) AllocError!Popped {
        const n = node(h);
        const rh = n.right orelse return .{ .key = n.key, .val = b.valOf(h), .rest = n.left };
        const m = try b.popMax(rh);
        return .{ .key = m.key, .val = m.val, .rest = try b.balance(n.key, b.valOf(h), n.left, m.rest) };
    }

    fn fromSorted(b: Builder, entries: []const Entry) AllocError!?*HeapHeader {
        if (entries.len == 0) return null;
        const mid = entries.len / 2;
        return try b.mk(entries[mid].key, entries[mid].value, try b.fromSorted(entries[0..mid]), try b.fromSorted(entries[mid + 1 ..]));
    }
};

fn builder(heap: *Heap, kind: Kind) Builder {
    return .{ .heap = heap, .kind = kind, .is_map = kind == .sorted_map };
}

/// Map `m` with `key → val` (SORTED.md §4): `m` itself when the key
/// already maps to a bit-identical value; a replaced value keeps the
/// original key object. Keeps `m`'s metadata and comparator.
pub fn assoc(heap: *Heap, m: Value, key: Value, val: Value, cmp: anytype) !Value {
    std.debug.assert(m.kind() == .sorted_map);
    const old = rootOf(m).tree;
    const t = try builder(heap, .sorted_map).insert(@TypeOf(cmp), cmp, old, key, val);
    return if (same(t, old)) m else withTree(heap, m, t);
}

/// Set `s` with `key`; `s` itself when an equal key is there.
pub fn conj(heap: *Heap, s: Value, key: Value, cmp: anytype) !Value {
    std.debug.assert(s.kind() == .sorted_set);
    const old = rootOf(s).tree;
    const t = try builder(heap, .sorted_set).insert(@TypeOf(cmp), cmp, old, key, value.nilValue());
    return if (same(t, old)) s else withTree(heap, s, t);
}

/// `v` (a map or a set) without `key`; `v` itself when it is absent.
pub fn without(heap: *Heap, v: Value, key: Value, cmp: anytype) !Value {
    const old = rootOf(v).tree;
    const t = try builder(heap, v.kind()).remove(@TypeOf(cmp), cmp, old, key);
    return if (same(t, old)) v else withTree(heap, v, t);
}

/// The entry whose key the comparator finds equal to `key`, with the
/// key as `v` holds it; null when absent.
pub fn find(v: Value, key: Value, cmp: anytype) @TypeOf(cmp).Error!?Entry {
    var cur = rootOf(v).tree;
    while (cur) |h| {
        cur = switch (try cmp.order(key, node(h).key)) {
            .lt => node(h).left,
            .gt => node(h).right,
            .eq => return entryOf(h, v.kind() == .sorted_map),
        };
    }
    return null;
}

/// The least entry, or null when `v` is empty.
pub fn first(v: Value) ?Entry {
    var h = rootOf(v).tree orelse return null;
    while (node(h).left) |l| h = l;
    return entryOf(h, v.kind() == .sorted_map);
}

/// The greatest entry, or null when `v` is empty.
pub fn last(v: Value) ?Entry {
    var h = rootOf(v).tree orelse return null;
    while (node(h).right) |r| h = r;
    return entryOf(h, v.kind() == .sorted_map);
}

/// The entry at position `i` of the ascending order, `i < count(v)`;
/// O(log n) through the subtree sizes.
pub fn entryAt(v: Value, i: usize) Entry {
    var h = rootOf(v).tree.?;
    var k: u64 = i;
    while (true) {
        const n = node(h);
        const ls = size(n.left);
        if (k < ls) {
            h = n.left.?;
        } else if (k == ls) {
            return entryOf(h, v.kind() == .sorted_map);
        } else {
            k -= ls + 1;
            h = n.right.?;
        }
    }
}

// =============================================================================
// Walks (SORTED.md §5)
// =============================================================================

/// An in-order walk, ascending or descending, holding the path from
/// the root to the next entry.
pub const Iter = struct {
    path: [max_height]*HeapHeader = undefined,
    len: usize = 0,
    ascending: bool,
    is_map: bool,

    /// Every entry of `v`, least first when `ascending`, greatest first
    /// otherwise.
    pub fn init(v: Value, ascending: bool) Iter {
        var it: Iter = .{ .ascending = ascending, .is_map = v.kind() == .sorted_map };
        it.descend(rootOf(v).tree);
        return it;
    }

    /// Clojure's `seqFrom`: ascending, the entries from the least key
    /// not below `key`; descending, from the greatest key not above it.
    pub fn from(v: Value, key: Value, ascending: bool, cmp: anytype) @TypeOf(cmp).Error!Iter {
        var it: Iter = .{ .ascending = ascending, .is_map = v.kind() == .sorted_map };
        var cur = rootOf(v).tree;
        while (cur) |h| {
            const o = try cmp.order(key, node(h).key);
            if (o == .eq) {
                it.push(h);
                break;
            }
            if ((o == .lt) == ascending) {
                it.push(h);
                cur = if (ascending) node(h).left else node(h).right;
            } else {
                cur = if (ascending) node(h).right else node(h).left;
            }
        }
        return it;
    }

    fn push(it: *Iter, h: *HeapHeader) void {
        it.path[it.len] = h;
        it.len += 1;
    }

    fn descend(it: *Iter, t: ?*HeapHeader) void {
        var cur = t;
        while (cur) |h| {
            it.push(h);
            cur = if (it.ascending) node(h).left else node(h).right;
        }
    }

    pub fn next(it: *Iter) ?Entry {
        if (it.len == 0) return null;
        it.len -= 1;
        const h = it.path[it.len];
        it.descend(if (it.ascending) node(h).right else node(h).left);
        return entryOf(h, it.is_map);
    }
};

/// An ascending walk by position: a few words where `Iter` holds a
/// path, O(log n) a step. The codec keeps one per open container.
pub const Cursor = struct {
    v: Value,
    i: usize = 0,

    pub fn init(v: Value) Cursor {
        return .{ .v = v };
    }

    pub fn next(c: *Cursor) ?Entry {
        if (c.i >= count(c.v)) return null;
        c.i += 1;
        return entryAt(c.v, c.i - 1);
    }
};

// =============================================================================
// The natural order (SORTED.md §6): Clojure's `compare`
// =============================================================================

pub const OrderError = error{ KindMismatch, StackOverflow };

inline fn isNumber(v: Value) bool {
    return switch (v.kind()) {
        .fixnum, .float, .bignum => true,
        else => false,
    };
}

fn toF64(v: Value) f64 {
    return switch (v.kind()) {
        .fixnum => @floatFromInt(v.asFixnum()),
        .float => v.asFloat(),
        else => bignum_mod.toF64(v),
    };
}

/// Clojure's `compare`: nil before everything; numbers across the
/// tower (an f64 operand compares both as f64, and NaN is equal to
/// every number, as neither `<` nor `>` holds); false before true;
/// strings by their UTF-8 bytes; keywords and symbols by namespace,
/// then name; chars by scalar; vectors by count, then element by
/// element. Two values of different kinds otherwise, or of a kind with
/// no order (lists, maps, sets, functions, ...), are `KindMismatch`.
pub fn naturalOrder(interner: *const intern_mod.Interner, a: Value, b: Value) OrderError!Order {
    stack.check() catch return error.StackOverflow;
    const ka = a.kind();
    const kb = b.kind();
    if (ka == .nil) return if (kb == .nil) .eq else .lt;
    if (kb == .nil) return .gt;
    if (isNumber(a) and isNumber(b)) {
        if (a.isFixnum() and b.isFixnum()) return std.math.order(a.asFixnum(), b.asFixnum());
        if (a.isFloat() or b.isFloat()) {
            const x = toF64(a);
            const y = toF64(b);
            return if (x < y) .lt else if (x > y) .gt else .eq;
        }
        return bignum_mod.compare(a, b);
    }
    if (a.isBool() and b.isBool()) return std.math.order(@intFromBool(a.asBool()), @intFromBool(b.asBool()));
    if (ka != kb) return error.KindMismatch;
    return switch (ka) {
        .string => std.mem.order(u8, string_mod.asBytes(a), string_mod.asBytes(b)),
        .keyword => intern_mod.Interner.compareNames(interner.keywordName(a.asKeywordId()), interner.keywordName(b.asKeywordId())),
        .symbol => intern_mod.Interner.compareNames(interner.symbolName(a.asSymbolId()), interner.symbolName(b.asSymbolId())),
        .char => std.math.order(a.asChar(), b.asChar()),
        .persistent_vector => blk: {
            const na = vector_mod.count(a);
            const nb = vector_mod.count(b);
            if (na != nb) break :blk std.math.order(na, nb);
            var ca = vector_mod.Cursor.init(a);
            var cb = vector_mod.Cursor.init(b);
            while (ca.next()) |x| {
                const o = try naturalOrder(interner, x, cb.next().?);
                if (o != .eq) break :blk o;
            }
            break :blk .eq;
        },
        else => error.KindMismatch,
    };
}

/// The natural order as a comparator.
pub const Natural = struct {
    interner: *const intern_mod.Interner,

    pub const Error = OrderError;

    pub fn order(self: Natural, a: Value, b: Value) Error!Order {
        return naturalOrder(self.interner, a, b);
    }
};

// =============================================================================
// Hash and equality (SEMANTICS §3.2; dispatch routes them)
// =============================================================================

/// The pre-domain-mix hash: the formula `champ` uses for a map
/// (`is_map`) or a set, so a sorted collection hashes as the hash
/// collection with its entries. Cached in the root header.
pub fn hashOf(h: *HeapHeader, elementHash: ElementHash) u64 {
    if (h.cachedHash()) |cached| return cached;
    const kind: Kind = @enumFromInt(h.kind);
    const is_map = kind == .sorted_map;
    var acc: u64 = hash_mod.unordered_init;
    var n: usize = 0;
    var it = Iter.init(Heap.valueFromHeader(kind, h), true);
    while (it.next()) |e| : (n += 1) {
        const x = if (is_map) blk: {
            var eh: u64 = hash_mod.ordered_init;
            eh = hash_mod.combineOrdered(eh, elementHash(e.key));
            break :blk hash_mod.combineOrdered(eh, elementHash(e.value));
        } else elementHash(e.key);
        acc = hash_mod.combineUnordered(acc, x);
    }
    const truncated: u32 = @truncate(hash_mod.finalizeUnordered(acc, n));
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// Two sorted collections of one kind whose orders agree on every key
/// (both natural): equal when their entries are, position by position.
pub fn equalInOrder(a: Value, b: Value, elementEq: ElementEq) bool {
    if (count(a) != count(b)) return false;
    const is_map = a.kind() == .sorted_map;
    var ia = Iter.init(a, true);
    var ib = Iter.init(b, true);
    while (ia.next()) |x| {
        const y = ib.next().?;
        if (!elementEq(x.key, y.key)) return false;
        if (is_map and !elementEq(x.value, y.value)) return false;
    }
    return true;
}

// =============================================================================
// GC (GC.md §5)
// =============================================================================

/// The comparator, then every node through `markInternal` and its key
/// and value through `markValue`. Recursion depth is the tree height.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const r = Heap.bodyOf(Root, h);
    visitor.markValue(r.comparator);
    if (r.tree) |t| traceNode(t, h.kind == @intFromEnum(Kind.sorted_map), visitor);
}

fn traceNode(start: *HeapHeader, is_map: bool, visitor: anytype) void {
    var cur: ?*HeapHeader = start;
    while (cur) |h| {
        if (!visitor.markInternal(h)) return;
        const n = node(h);
        visitor.markValue(n.key);
        if (is_map) visitor.markValue(n.val);
        if (n.left) |l| traceNode(l, is_map, visitor);
        cur = n.right;
    }
}

// =============================================================================
// Invariants, for the property tests (SORTED.md §3)
// =============================================================================

pub const InvariantError = error{InvalidTree};

/// Every node's size is its subtree's, every subtree of two or more
/// nodes is within `delta` on both sides, the height fits an `Iter`,
/// and the keys ascend strictly under `cmp`.
pub fn checkInvariants(v: Value, cmp: anytype) (InvariantError || @TypeOf(cmp).Error)!void {
    _ = try checkNode(rootOf(v).tree, 0);
    var it = Iter.init(v, true);
    var prev: ?Value = null;
    while (it.next()) |e| {
        if (prev) |p| if (try cmp.order(p, e.key) != .lt) return error.InvalidTree;
        prev = e.key;
    }
}

fn checkNode(t: ?*HeapHeader, depth: usize) InvariantError!u64 {
    const h = t orelse return 0;
    if (depth >= max_height) return error.InvalidTree;
    const n = node(h);
    const sl = try checkNode(n.left, depth + 1);
    const sr = try checkNode(n.right, depth + 1);
    if (n.size != sl + sr + 1) return error.InvalidTree;
    if (sl + sr >= 2 and (sl > delta * sr or sr > delta * sl)) return error.InvalidTree;
    return n.size;
}

// =============================================================================
// Tests — the tree's shape and walks; the randomized laws are
// test/prop/sorted.zig
// =============================================================================

fn fx(n: i64) Value {
    return value.fromFixnum(n).?;
}

/// Fixnums in their natural order, with no interner.
const FixOrder = struct {
    pub const Error = error{};
    pub fn order(_: FixOrder, a: Value, b: Value) Error!Order {
        return std.math.order(a.asFixnum(), b.asFixnum());
    }
};

test "insert and remove keep the tree balanced and ordered through 2000 keys" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try empty(&heap, .sorted_map, value.nilValue());
    var prng = std.Random.DefaultPrng.init(0x5041);
    const r = prng.random();
    for (0..2000) |i| {
        m = try assoc(&heap, m, fx(r.intRangeAtMost(i64, 0, 999)), fx(@intCast(i)), FixOrder{});
        try checkInvariants(m, FixOrder{});
    }
    for (0..2000) |_| {
        m = try without(&heap, m, fx(r.intRangeAtMost(i64, 0, 999)), FixOrder{});
        try checkInvariants(m, FixOrder{});
    }
}

test "ascending insertion stays logarithmic in height" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try empty(&heap, .sorted_set, value.nilValue());
    for (0..4096) |i| s = try conj(&heap, s, fx(@intCast(i)), FixOrder{});
    try checkInvariants(s, FixOrder{});
    try testing.expectEqual(@as(usize, 4096), count(s));
    // log_{4/3}(4097) + 2 bounds the height of any (3, 2) tree.
    var height: usize = 0;
    var it = Iter.init(s, true);
    while (it.len > 0) : (_ = it.next()) height = @max(height, it.len);
    try testing.expect(height <= 31);
}

test "an update that changes nothing returns the collection itself; a replaced value keeps the old key" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try empty(&heap, .sorted_map, value.nilValue());
    m = try assoc(&heap, m, fx(1), fx(10), FixOrder{});
    try testing.expect((try assoc(&heap, m, fx(1), fx(10), FixOrder{})).identicalTo(m));
    try testing.expect((try without(&heap, m, fx(2), FixOrder{})).identicalTo(m));
    const m2 = try assoc(&heap, m, fx(1), fx(11), FixOrder{});
    try testing.expectEqual(@as(i64, 11), (try find(m2, fx(1), FixOrder{})).?.value.asFixnum());
    try testing.expectEqual(@as(i64, 10), (try find(m, fx(1), FixOrder{})).?.value.asFixnum());
    var s = try empty(&heap, .sorted_set, value.nilValue());
    s = try conj(&heap, s, fx(3), FixOrder{});
    try testing.expect((try conj(&heap, s, fx(3), FixOrder{})).identicalTo(s));
}

test "walks: both directions, from a bound, by position, least and greatest" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var entries: [50]Entry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .key = fx(@intCast(2 * i)), .value = fx(@intCast(i)) };
    const m = try fromSortedEntries(&heap, .sorted_map, value.nilValue(), &entries);
    try checkInvariants(m, FixOrder{});
    var up = Iter.init(m, true);
    var down = Iter.init(m, false);
    for (0..50) |i| {
        try testing.expectEqual(@as(i64, @intCast(2 * i)), up.next().?.key.asFixnum());
        try testing.expectEqual(@as(i64, @intCast(98 - 2 * i)), down.next().?.key.asFixnum());
        try testing.expectEqual(@as(i64, @intCast(i)), entryAt(m, i).value.asFixnum());
    }
    try testing.expect(up.next() == null and down.next() == null);
    // From 31: ascending starts at 32, descending at 30; an exact key starts at itself.
    var a = try Iter.from(m, fx(31), true, FixOrder{});
    try testing.expectEqual(@as(i64, 32), a.next().?.key.asFixnum());
    try testing.expectEqual(@as(i64, 34), a.next().?.key.asFixnum());
    var d = try Iter.from(m, fx(31), false, FixOrder{});
    try testing.expectEqual(@as(i64, 30), d.next().?.key.asFixnum());
    try testing.expectEqual(@as(i64, 28), d.next().?.key.asFixnum());
    var e = try Iter.from(m, fx(40), true, FixOrder{});
    try testing.expectEqual(@as(i64, 40), e.next().?.key.asFixnum());
    var past = try Iter.from(m, fx(99), true, FixOrder{});
    try testing.expect(past.next() == null);
    try testing.expectEqual(@as(i64, 0), first(m).?.key.asFixnum());
    try testing.expectEqual(@as(i64, 98), last(m).?.key.asFixnum());
    var cur = Cursor.init(m);
    var n: usize = 0;
    while (cur.next()) |_| n += 1;
    try testing.expectEqual(@as(usize, 50), n);
}

test "a set node stops before the value slot" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try empty(&heap, .sorted_set, value.nilValue());
    s = try conj(&heap, s, fx(1), FixOrder{});
    const tree = rootOf(s).tree.?;
    try testing.expectEqual(@as(usize, set_node_bytes), Heap.bodyBytes(tree).len);
    try testing.expect(first(s).?.value.isNil());
}

test "the natural order: nil first, numbers across the tower, vectors by count, other kinds apart" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = intern_mod.Interner.init(testing.allocator);
    defer interner.deinit();
    const o = Natural{ .interner = &interner };
    try testing.expectEqual(Order.lt, try o.order(value.nilValue(), fx(-5)));
    try testing.expectEqual(Order.eq, try o.order(fx(1), value.fromFloat(1.0)));
    try testing.expectEqual(Order.lt, try o.order(fx(1), value.fromFloat(1.5)));
    try testing.expectEqual(Order.gt, try o.order(try bignum_mod.fromI64(&heap, value.fixnum_max + 1), fx(value.fixnum_max)));
    try testing.expectEqual(Order.eq, try o.order(value.fromFloat(std.math.nan(f64)), fx(3)));
    try testing.expectEqual(Order.lt, try o.order(value.fromBool(false), value.fromBool(true)));
    try testing.expectEqual(Order.lt, try o.order(try interner.internKeywordValue("b"), try interner.internKeywordValue("a/a")));
    try testing.expectEqual(Order.lt, try o.order(try vector_mod.fromSlice(&heap, &.{fx(9)}), try vector_mod.fromSlice(&heap, &.{ fx(1), fx(2) })));
    try testing.expectEqual(Order.gt, try o.order(try vector_mod.fromSlice(&heap, &.{ fx(1), fx(3) }), try vector_mod.fromSlice(&heap, &.{ fx(1), fx(2) })));
    try testing.expectError(error.KindMismatch, o.order(fx(1), try interner.internKeywordValue("a")));
}
