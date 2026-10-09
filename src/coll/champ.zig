//! coll/champ.zig — persistent map + set heap kinds.
//!
//! Authoritative spec: `docs/CHAMP.md`. Semantic framing:
//! `docs/SEMANTICS.md` §2.6 (maps and sets: the own-kind structural rule)
//! and §3.2–§3.3 (map entry-hash formula; the hash domains are the
//! kind numbers 18 and 19). Physical storage: `docs/HEAP.md`. Representation
//! choices: `docs/VALUE.md` §2.2.
//!
//! One trie implementation, `Trie(P, kind)`, serves both kinds: a map's
//! payload is an `Entry` (key + value, 32 bytes), a set's a bare key
//! `Value` (16 bytes). The public `map*` / `set*` names are the
//! operations of `MapTrie` and `SetTrie`.
//!
//! ## Representation (CHAMP.md §3-§4)
//!
//!   - subkind 0 = array-map / array-set: up to 8 payloads inline,
//!     in association order.
//!   - subkind 1 = CHAMP root: count + pointer to the root interior.
//!
//! Interior and collision nodes are internal: no Value ever points at
//! one, and no header records which one a node is. Every walk derives
//! it from the shift it reached the node at (a node reached past
//! `MAX_TRIE_SHIFT` is a collision node).
//!
//! ## Dispatch plumbing (one-way terminal)
//!
//! This module does not import `dispatch.zig` (CHAMP.md §9). Every
//! operation that hashes or compares arbitrary Values takes callbacks
//! (`elementHash: *const fn (Value) u64`, `elementEq: *const fn
//! (Value, Value) bool`); the dispatcher passes `&dispatch.hashValue`
//! and `&dispatch.equal`.
//!
//! Transients are the separate `src/coll/transient.zig` module.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const hash_mod = @import("../hash.zig");
const string_mod = @import("../string.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

const ElementHash = *const fn (Value) u64;
const ElementEq = *const fn (Value, Value) bool;

// =============================================================================
// Constants (CHAMP.md §5)
// =============================================================================

pub const branch_bits: u5 = 5;
pub const branch_factor: usize = 1 << branch_bits; // 32
pub const branch_mask: u32 = @as(u32, branch_factor) - 1; // 0x1F

/// Shift at the deepest interior level. Levels 0..5 consume 5 bits each
/// (30 total); level 6 consumes the remaining 2 bits (`shift == 30`).
/// A node reached past it is a collision node. Typed `u8` so a walk
/// can carry `MAX_TRIE_SHIFT + branch_bits` as the collision level.
pub const MAX_TRIE_SHIFT: u8 = 30;

/// An array-map or array-set holds up to this many payloads; the next
/// distinct key promotes it to a CHAMP root.
pub const array_map_max: u32 = 8;

pub const subkind_array_map: u16 = 0;
pub const subkind_champ_root: u16 = 1;

// =============================================================================
// Public types (CHAMP.md §8)
// =============================================================================

pub const Entry = extern struct {
    key: Value,
    value: Value,

    comptime {
        std.debug.assert(@sizeOf(Entry) == 32);
        std.debug.assert(@offsetOf(Entry, "key") == 0);
        std.debug.assert(@offsetOf(Entry, "value") == 16);
    }
};

/// Nil-safe lookup result. `?Value` would conflate "absent" with
/// "present with nil value" (CHAMP.md §6.3).
pub const MapLookup = union(enum) {
    absent,
    present: Value,
};

// =============================================================================
// Body layouts (CHAMP.md §4). Each header is followed by its payloads
// (and, for an interior, its child pointers).
// =============================================================================

/// Array-map / array-set: `count` payloads follow.
const ArrayHeader = extern struct {
    count: u32,
    _pad: u32,
};

/// CHAMP root. `root_node` is always an interior node.
const RootBody = extern struct {
    count: u32,
    _pad: u32,
    root_node: *HeapHeader,

    comptime {
        std.debug.assert(@sizeOf(RootBody) == 16);
        std.debug.assert(@offsetOf(RootBody, "root_node") == 8);
    }
};

/// Interior node: `popCount(data_bitmap)` payloads in ascending slot
/// order, then `popCount(node_bitmap)` child pointers in descending
/// slot order. `data_bitmap & node_bitmap == 0`.
const InteriorHeader = extern struct {
    data_bitmap: u32,
    node_bitmap: u32,
};

/// Collision node: `count ≥ 2` payloads whose keys share the 32-bit
/// indexing hash `shared_hash`, in association order.
const CollisionHeader = extern struct {
    shared_hash: u32,
    count: u32,
};

comptime {
    for (.{ ArrayHeader, InteriorHeader, CollisionHeader }) |H| std.debug.assert(@sizeOf(H) == 8);
}

inline fn headerOf(comptime H: type, h: *HeapHeader) *H {
    return Heap.bodyOf(H, h);
}

/// The first byte after a node's 8-byte header: where its payloads
/// start.
inline fn afterHeader(h: *HeapHeader) [*]u8 {
    return @as([*]u8, @ptrCast(Heap.bodyOf(InteriorHeader, h))) + 8;
}

// =============================================================================
// Key equivalence and indexing hash
// =============================================================================

/// Key equality with two shortcuts ahead of `elementEq` (CHAMP.md
/// §6.2): bit identity, and an immediate on either side compared
/// inline, since an immediate is `=` only to an immediate of its kind.
inline fn keyEquivalent(a: Value, b: Value, elementEq: ElementEq) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    const a_heap = a.kind().isHeap();
    const b_heap = b.kind().isHeap();
    if (!a_heap or !b_heap) return !a_heap and !b_heap and a.equalImmediate(b);
    return elementEq(a, b);
}

/// The low 32 bits of `dispatch.hashValue(k)` (CHAMP.md §5.1). An
/// immediate hashes through `Value.hashImmediate`, which is what
/// `dispatch.hashValue` computes for it, so only a heap key reaches
/// the callback; a fixture that shapes the indexing hash through
/// `elementHash` must key by heap values.
inline fn indexHashOf(k: Value, elementHash: ElementHash) u32 {
    if (!k.kind().isHeap()) return @truncate(k.hashImmediate());
    return @truncate(elementHash(k));
}

/// An array form indexes nothing by hash, but hashes a key it adds
/// that may hold a lazy seq: hashing realizes every lazy seq in it, so
/// no map or set holds one unrealized (CHAMP.md §2.1, docs/LAZY.md §6).
/// A set's elements were realized when it took them.
inline fn hashAdded(k: Value, elementHash: ElementHash) void {
    switch (k.kind()) {
        .lazy_seq, .list, .persistent_vector, .persistent_map, .sorted_map, .sorted_set, .record => _ = elementHash(k),
        else => {},
    }
}

inline fn slotOf(hash32: u32, shift: u8) u32 {
    return (hash32 >> @intCast(shift)) & branch_mask;
}

inline fn bitOf(slot: u32) u32 {
    return @as(u32, 1) << @intCast(slot);
}

/// Physical index of `slot` in the child segment, stored in
/// descending slot order: the set bits of `node_bitmap` above `slot`.
inline fn childIndex(node_bitmap: u32, slot: u32) usize {
    const at_or_below: u32 = (bitOf(slot) - 1) | bitOf(slot);
    return @popCount(node_bitmap & ~at_or_below);
}

/// Physical index of `slot` in the payload segment, stored in
/// ascending slot order: the set bits of `data_bitmap` below `slot`.
inline fn dataIndex(data_bitmap: u32, slot: u32) usize {
    return @popCount(data_bitmap & (bitOf(slot) - 1));
}

/// `dst` = `src` with the element at `at` dropped when `had`, and
/// `put` inserted there.
/// Each path-copied node costs as few libc copies as the edit allows.
inline fn splice(comptime T: type, dst: []T, src: []const T, at: usize, had: bool, put: ?T) void {
    if (had == (put != null)) {
        if (src.len > 0) @memcpy(dst, src);
        if (put) |x| dst[at] = x;
        return;
    }
    if (at > 0) @memcpy(dst[0..at], src[0..at]);
    var w = at;
    if (put) |x| {
        dst[w] = x;
        w += 1;
    }
    const rest = src[at + @intFromBool(had) ..];
    if (rest.len > 0) @memcpy(dst[w..], rest);
}

// =============================================================================
// The trie, generic over its payload
// =============================================================================

fn Trie(comptime P: type, comptime kind: Kind) type {
    return struct {
        const is_map = P == Entry;

        inline fn keyOf(p: P) Value {
            return if (is_map) p.key else p;
        }

        /// Whether storing `new` over `old` (equal keys) changes
        /// nothing: a set's payload is its key; a map's value must be
        /// bit-identical (CHAMP.md §8.1).
        inline fn sameValue(old: P, new: P) bool {
            if (!is_map) return true;
            return old.value.tag == new.value.tag and old.value.payload == new.value.payload;
        }

        /// `new` stored over `old` (equal keys): the original key
        /// object stays, as in Clojure.
        fn replaced(old: P, new: P) P {
            return if (is_map) .{ .key = old.key, .value = new.value } else old;
        }

        // ---- allocation and accessors ----

        inline fn arrayPayloads(h: *HeapHeader) []P {
            const n = headerOf(ArrayHeader, h).count;
            if (builtin.optimize.runtimeSafety()) std.debug.assert(Heap.bodyBytes(h).len == 8 + @as(usize, n) * @sizeOf(P));
            const ptr: [*]P = @ptrCast(@alignCast(afterHeader(h)));
            return ptr[0..n];
        }

        inline fn payloads(h: *HeapHeader) []P {
            const ptr: [*]P = @ptrCast(@alignCast(afterHeader(h)));
            return ptr[0..@popCount(headerOf(InteriorHeader, h).data_bitmap)];
        }

        inline fn children(h: *HeapHeader) []*HeapHeader {
            const hdr = headerOf(InteriorHeader, h);
            const ptr: [*]*HeapHeader = @ptrCast(@alignCast(afterHeader(h) + @as(usize, @popCount(hdr.data_bitmap)) * @sizeOf(P)));
            return ptr[0..@popCount(hdr.node_bitmap)];
        }

        inline fn collisionPayloads(h: *HeapHeader) []P {
            const n = headerOf(CollisionHeader, h).count;
            if (builtin.optimize.runtimeSafety()) std.debug.assert(Heap.bodyBytes(h).len == 8 + @as(usize, n) * @sizeOf(P));
            const ptr: [*]P = @ptrCast(@alignCast(afterHeader(h)));
            return ptr[0..n];
        }

        fn allocArray(heap: *Heap, n: usize) !*HeapHeader {
            std.debug.assert(n <= array_map_max);
            const h = try heap.alloc(kind, @sizeOf(ArrayHeader) + n * @sizeOf(P));
            headerOf(ArrayHeader, h).count = @intCast(n);
            return h;
        }

        /// Room a node an edit grows keeps past its body, so the next
        /// payloads it gains land in place (TRANSIENT.md §1). A node
        /// an edit makes at its final size (a copy, a split's pair)
        /// keeps none.
        const edit_slack = 2 * @sizeOf(P);

        /// A node of `size` body bytes with `spare` more bytes of room;
        /// one an edit allocates (`edit` nonzero) carries its token.
        fn allocNode(heap: *Heap, size: usize, edit: u32, spare: usize) !*HeapHeader {
            if (edit == 0) return heap.alloc(kind, size);
            const h = try heap.alloc(kind, size + spare);
            if (spare > 0) _ = Heap.resizeInPlace(h, size);
            heap_mod.stampEdit(h, edit);
            return h;
        }

        inline fn interiorSize(data_bitmap: u32, node_bitmap: u32) usize {
            return @sizeOf(InteriorHeader) +
                @as(usize, @popCount(data_bitmap)) * @sizeOf(P) +
                @as(usize, @popCount(node_bitmap)) * @sizeOf(*HeapHeader);
        }

        fn allocInterior(heap: *Heap, data_bitmap: u32, node_bitmap: u32, edit: u32, spare: usize) !*HeapHeader {
            std.debug.assert(data_bitmap & node_bitmap == 0);
            const h = try allocNode(heap, interiorSize(data_bitmap, node_bitmap), edit, spare);
            headerOf(InteriorHeader, h).* = .{ .data_bitmap = data_bitmap, .node_bitmap = node_bitmap };
            return h;
        }

        fn allocCollision(heap: *Heap, shared_hash: u32, n: usize, edit: u32) !*HeapHeader {
            std.debug.assert(n >= 2);
            const h = try allocNode(heap, @sizeOf(CollisionHeader) + n * @sizeOf(P), edit, 0);
            headerOf(CollisionHeader, h).* = .{ .shared_hash = shared_hash, .count = @intCast(n) };
            return h;
        }

        fn valueOf(h: *HeapHeader, subkind: u16) Value {
            return .{
                .tag = @as(u64, @backingInt(kind)) | (@as(u64, subkind) << 16),
                .payload = @intFromPtr(h),
            };
        }

        fn newRoot(heap: *Heap, n: usize, node: *HeapHeader) !Value {
            const h = try heap.alloc(kind, @sizeOf(RootBody));
            headerOf(RootBody, h).* = .{ .count = std.math.cast(u32, n) orelse return error.OutOfMemory, ._pad = 0, .root_node = node };
            return valueOf(h, subkind_champ_root);
        }

        /// The subkind of a map or set root header, from its body size:
        /// a CHAMP root is 16 bytes, which no array body (8 + n·32 or
        /// 8 + n·16 bytes) can be.
        fn inferSubkind(h: *HeapHeader) u16 {
            std.debug.assert(h.kind == @backingInt(kind));
            const size = Heap.bodyBytes(h).len;
            if (size == @sizeOf(RootBody)) return subkind_champ_root;
            if (builtin.optimize.runtimeSafety()) {
                const n = (size -| @sizeOf(ArrayHeader)) / @sizeOf(P);
                if (size != @sizeOf(ArrayHeader) + n * @sizeOf(P) or n > array_map_max) {
                    std.debug.panic("champ: body size {d} is no {s} root", .{ size, @tagName(kind) });
                }
            }
            return subkind_array_map;
        }

        fn fromHeader(h: *HeapHeader) Value {
            return valueOf(h, inferSubkind(h));
        }

        fn rootHeader(v: Value) *HeapHeader {
            std.debug.assert(v.kind() == kind);
            std.debug.assert(v.subkind() == subkind_array_map or v.subkind() == subkind_champ_root);
            return Heap.asHeapHeader(v);
        }

        // ---- public operations ----

        fn empty(heap: *Heap) !Value {
            return valueOf(try allocArray(heap, 0), subkind_array_map);
        }

        fn count(v: Value) usize {
            const h = rootHeader(v);
            return if (v.subkind() == subkind_array_map) headerOf(ArrayHeader, h).count else headerOf(RootBody, h).count;
        }

        /// The payload whose key equals `key`, or null.
        inline fn find(v: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) ?P {
            const h = rootHeader(v);
            if (v.subkind() == subkind_array_map) {
                for (arrayPayloads(h)) |p| if (keyEquivalent(keyOf(p), key, elementEq)) return p;
                return null;
            }
            const hash32 = indexHashOf(key, elementHash);
            var node = headerOf(RootBody, h).root_node;
            var shift: u8 = 0;
            while (shift <= MAX_TRIE_SHIFT) : (shift += branch_bits) {
                const hdr = headerOf(InteriorHeader, node);
                const slot = slotOf(hash32, shift);
                if (hdr.data_bitmap & bitOf(slot) != 0) {
                    const p = payloads(node)[dataIndex(hdr.data_bitmap, slot)];
                    return if (keyEquivalent(keyOf(p), key, elementEq)) p else null;
                }
                if (hdr.node_bitmap & bitOf(slot) == 0) return null;
                node = children(node)[childIndex(hdr.node_bitmap, slot)];
            }
            if (headerOf(CollisionHeader, node).shared_hash != hash32) return null;
            for (collisionPayloads(node)) |p| if (keyEquivalent(keyOf(p), key, elementEq)) return p;
            return null;
        }

        /// A root built from `from` by an update carries `from`'s
        /// metadata, as every Clojure collection update does
        /// (SEMANTICS §7). `to` is `from` itself or a fresh root.
        fn keepMeta(from: Value, to: Value) Value {
            if (to.payload == from.payload) return to;
            const m = Heap.asHeapHeader(from).getMeta() orelse return to;
            Heap.asHeapHeader(to).setMeta(m);
            return to;
        }

        /// `v` with `p` stored under its key (CHAMP.md §8.1): `v`
        /// itself when that changes nothing.
        fn insert(heap: *Heap, v: Value, p: P, elementHash: ElementHash, elementEq: ElementEq) !Value {
            return keepMeta(v, try insertBare(heap, v, p, elementHash, elementEq));
        }

        fn insertBare(heap: *Heap, v: Value, p: P, elementHash: ElementHash, elementEq: ElementEq) !Value {
            const h = rootHeader(v);
            if (v.subkind() == subkind_array_map) {
                const ps = arrayPayloads(h);
                for (ps, 0..) |old, i| {
                    if (!keyEquivalent(keyOf(old), keyOf(p), elementEq)) continue;
                    if (sameValue(old, p)) return v;
                    const nh = try allocArray(heap, ps.len);
                    @memcpy(arrayPayloads(nh), ps);
                    arrayPayloads(nh)[i] = replaced(old, p);
                    return valueOf(nh, subkind_array_map);
                }
                if (ps.len < array_map_max) {
                    hashAdded(keyOf(p), elementHash);
                    const nh = try allocArray(heap, ps.len + 1);
                    splice(P, arrayPayloads(nh), ps, ps.len, false, p);
                    return valueOf(nh, subkind_array_map);
                }
                // Promotion (CHAMP.md §5.3): build the trie of the nine.
                var items: [array_map_max + 1]Item = undefined;
                for (ps, 0..) |old, i| items[i] = .of(old, indexHashOf(keyOf(old), elementHash), i);
                items[array_map_max] = .of(p, indexHashOf(keyOf(p), elementHash), array_map_max);
                std.mem.sortUnstable(Item, &items, {}, Item.lessThan);
                return newRoot(heap, items.len, try build(heap, &items, 0, 0));
            }
            const root = headerOf(RootBody, h);
            var added = false;
            const node = try insertIn(heap, root.root_node, p, indexHashOf(keyOf(p), elementHash), 0, elementHash, elementEq, &added);
            if (node == root.root_node) return v;
            return newRoot(heap, @as(usize, root.count) + @intFromBool(added), node);
        }

        /// `node` (reached at `shift`) with `p` stored; `node` itself
        /// when that changes nothing. Sets `added` for a new key.
        fn insertIn(
            heap: *Heap,
            node: *HeapHeader,
            p: P,
            hash32: u32,
            shift: u8,
            elementHash: ElementHash,
            elementEq: ElementEq,
            added: *bool,
        ) !*HeapHeader {
            if (shift > MAX_TRIE_SHIFT) {
                const ps = collisionPayloads(node);
                for (ps, 0..) |old, i| {
                    if (!keyEquivalent(keyOf(old), keyOf(p), elementEq)) continue;
                    if (sameValue(old, p)) return node;
                    const nh = try allocCollision(heap, hash32, ps.len, 0);
                    @memcpy(collisionPayloads(nh), ps);
                    collisionPayloads(nh)[i] = replaced(old, p);
                    return nh;
                }
                added.* = true;
                const nh = try allocCollision(heap, hash32, ps.len + 1, 0);
                splice(P, collisionPayloads(nh), ps, ps.len, false, p);
                return nh;
            }
            const hdr = headerOf(InteriorHeader, node).*;
            const slot = slotOf(hash32, shift);
            if (hdr.data_bitmap & bitOf(slot) != 0) {
                const old = payloads(node)[dataIndex(hdr.data_bitmap, slot)];
                if (keyEquivalent(keyOf(old), keyOf(p), elementEq)) {
                    if (sameValue(old, p)) return node;
                    return withSlot(heap, node, slot, .{ .data = replaced(old, p) }, 0);
                }
                // Two keys on one slot: they move into a subtree.
                added.* = true;
                const sub = try pair(heap, old, indexHashOf(keyOf(old), elementHash), p, hash32, shift + branch_bits, 0);
                return withSlot(heap, node, slot, .{ .child = sub }, 0);
            }
            if (hdr.node_bitmap & bitOf(slot) != 0) {
                const child = children(node)[childIndex(hdr.node_bitmap, slot)];
                const new_child = try insertIn(heap, child, p, hash32, shift + branch_bits, elementHash, elementEq, added);
                if (new_child == child) return node;
                return withSlot(heap, node, slot, .{ .child = new_child }, 0);
            }
            added.* = true;
            return withSlot(heap, node, slot, .{ .data = p }, 0);
        }

        /// The subtree at `shift` holding `a` and `b`, distinct keys
        /// whose hashes share the bits below `shift`: a collision node
        /// past the last level, else an interior with both inline or,
        /// when they share this level's slot too, one child.
        fn pair(heap: *Heap, a: P, ha: u32, b: P, hb: u32, shift: u8, edit: u32) !*HeapHeader {
            if (shift > MAX_TRIE_SHIFT) {
                const h = try allocCollision(heap, ha, 2, edit);
                collisionPayloads(h)[0] = a;
                collisionPayloads(h)[1] = b;
                return h;
            }
            const sa = slotOf(ha, shift);
            const sb = slotOf(hb, shift);
            if (sa == sb) {
                const below = try pair(heap, a, ha, b, hb, shift + branch_bits, edit);
                const h = try allocInterior(heap, 0, bitOf(sa), edit, 0);
                children(h)[0] = below;
                return h;
            }
            const h = try allocInterior(heap, bitOf(sa) | bitOf(sb), 0, edit, 0);
            payloads(h)[@intFromBool(sa > sb)] = a;
            payloads(h)[@intFromBool(sb > sa)] = b;
            return h;
        }

        /// `v` without the payload keyed `key`; `v` itself when there
        /// is none. A CHAMP root emptied by it becomes a fresh empty
        /// array (CHAMP.md §5.6); there is no demotion otherwise
        /// (§5.4).
        fn remove(heap: *Heap, v: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
            return keepMeta(v, try removeBare(heap, v, key, elementHash, elementEq));
        }

        fn removeBare(heap: *Heap, v: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
            const h = rootHeader(v);
            if (v.subkind() == subkind_array_map) {
                const ps = arrayPayloads(h);
                for (ps, 0..) |old, i| {
                    if (!keyEquivalent(keyOf(old), key, elementEq)) continue;
                    const nh = try allocArray(heap, ps.len - 1);
                    splice(P, arrayPayloads(nh), ps, i, true, null);
                    return valueOf(nh, subkind_array_map);
                }
                return v;
            }
            const root = headerOf(RootBody, h);
            const removed = (try removeIn(heap, root.root_node, key, indexHashOf(key, elementHash), 0, elementEq)) orelse return v;
            if (root.count == 1) return empty(heap);
            return newRoot(heap, root.count - 1, removed.node);
        }

        const Removed = union(enum) {
            node: *HeapHeader,
            /// The subtree is left holding this one payload, which
            /// belongs inline in an ancestor (CHAMP.md §5.5). The root
            /// (shift 0) never returns it.
            single: P,
        };

        /// `node` (reached at `shift`) without `key`, or null when the
        /// key is absent.
        fn removeIn(heap: *Heap, node: *HeapHeader, key: Value, hash32: u32, shift: u8, elementEq: ElementEq) !?Removed {
            if (shift > MAX_TRIE_SHIFT) {
                const ps = collisionPayloads(node);
                for (ps, 0..) |old, i| {
                    if (!keyEquivalent(keyOf(old), key, elementEq)) continue;
                    if (ps.len == 2) return .{ .single = ps[1 - i] };
                    const nh = try allocCollision(heap, hash32, ps.len - 1, 0);
                    splice(P, collisionPayloads(nh), ps, i, true, null);
                    return .{ .node = nh };
                }
                return null;
            }
            const hdr = headerOf(InteriorHeader, node).*;
            const slot = slotOf(hash32, shift);
            if (hdr.data_bitmap & bitOf(slot) != 0) {
                const i = dataIndex(hdr.data_bitmap, slot);
                if (!keyEquivalent(keyOf(payloads(node)[i]), key, elementEq)) return null;
                if (shift > 0 and hdr.node_bitmap == 0 and @popCount(hdr.data_bitmap) == 2) {
                    return .{ .single = payloads(node)[1 - i] };
                }
                return .{ .node = try withSlot(heap, node, slot, .empty, 0) };
            }
            if (hdr.node_bitmap & bitOf(slot) == 0) return null;
            const child = children(node)[childIndex(hdr.node_bitmap, slot)];
            return switch ((try removeIn(heap, child, key, hash32, shift + branch_bits, elementEq)) orelse return null) {
                .node => |c| .{ .node = try withSlot(heap, node, slot, .{ .child = c }, 0) },
                // A node whose only content was that child would hold
                // the lone payload itself: it passes further up.
                .single => |p| if (shift > 0 and hdr.data_bitmap == 0 and @popCount(hdr.node_bitmap) == 1)
                    .{ .single = p }
                else
                    .{ .node = try withSlot(heap, node, slot, .{ .data = p }, 0) },
            };
        }

        const Slot = union(enum) { empty, data: P, child: *HeapHeader };

        /// A copy of interior `src` with `slot` holding `new`: the one
        /// path-copy primitive every insert and remove goes through.
        /// An edit's copy carries its token and room to grow: an edit
        /// copies a node here only to add a payload (`insertData`).
        inline fn withSlot(heap: *Heap, src: *HeapHeader, slot: u32, new: Slot, edit: u32) !*HeapHeader {
            const hdr = headerOf(InteriorHeader, src).*;
            const bit = bitOf(slot);
            var data = hdr.data_bitmap & ~bit;
            var nodes = hdr.node_bitmap & ~bit;
            switch (new) {
                .empty => {},
                .data => data |= bit,
                .child => nodes |= bit,
            }
            const h = try allocInterior(heap, data, nodes, edit, if (edit == 0) 0 else edit_slack);
            const put_data: ?P = switch (new) {
                .data => |p| p,
                else => null,
            };
            const put_child: ?*HeapHeader = switch (new) {
                .child => |c| c,
                else => null,
            };
            splice(P, payloads(h), payloads(src), dataIndex(hdr.data_bitmap, slot), hdr.data_bitmap & bit != 0, put_data);
            splice(*HeapHeader, children(h), children(src), childIndex(hdr.node_bitmap, slot), hdr.node_bitmap & bit != 0, put_child);
            return h;
        }

        // ---- in-place edits (TRANSIENT.md §1) ----
        //
        // A transient owns its root and every node whose header `hash`
        // holds its edit token. An edit is two steps: `locate` does
        // every hash and comparison and changes nothing; `put` or
        // `drop` then rewrites the owned nodes in place and copies any
        // other node on the path once, stamping the copy. A caller can
        // therefore look at what `locate` cost (a comparison past the
        // stack guard, SEMANTICS §2.7) before anything changes. Both
        // allocate before they write a node the collection reaches,
        // so a failed allocation leaves the payloads as they were.
        // The layout stays canonical (CHAMP.md §2.2): the same
        // insert, promotion and lone-key pull-up as the persistent
        // operations.

        const At = enum {
            /// The key is stored: `index` in the last node.
            present,
            /// An empty slot of the last interior.
            empty_slot,
            /// The last interior's slot holds `old`, another key.
            split,
            /// The last node is a collision node without the key.
            collision_append,
            /// An array form with room.
            array_append,
            /// A full array form: `hashes` are its payloads'.
            promote,
        };

        /// What `locate` found: the nodes from the root interior down
        /// to where the key is or would go (`path[k]` reached at shift
        /// `5k`, a collision node past `MAX_TRIE_SHIFT`).
        pub const Spot = struct {
            at: At,
            hash32: u32 = 0,
            len: u8 = 0,
            path: [8]*HeapHeader = undefined,
            index: usize = 0,
            /// The stored payload (`present`) or the occupant (`split`).
            old: P = undefined,
            other_hash: u32 = 0,
            hashes: [array_map_max]u32 = undefined,
        };

        fn locate(v: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) Spot {
            const h = rootHeader(v);
            if (v.subkind() == subkind_array_map) {
                const ps = arrayPayloads(h);
                for (ps, 0..) |p, i| {
                    if (keyEquivalent(keyOf(p), key, elementEq)) return .{ .at = .present, .index = i, .old = p };
                }
                if (ps.len < array_map_max) {
                    hashAdded(key, elementHash);
                    return .{ .at = .array_append };
                }
                var spot: Spot = .{ .at = .promote, .hash32 = indexHashOf(key, elementHash) };
                for (ps, 0..) |p, i| spot.hashes[i] = indexHashOf(keyOf(p), elementHash);
                return spot;
            }
            var spot: Spot = .{ .at = .empty_slot, .hash32 = indexHashOf(key, elementHash) };
            var node = headerOf(RootBody, h).root_node;
            var shift: u8 = 0;
            while (true) : (shift += branch_bits) {
                spot.path[spot.len] = node;
                spot.len += 1;
                if (shift > MAX_TRIE_SHIFT) {
                    for (collisionPayloads(node), 0..) |p, i| {
                        if (keyEquivalent(keyOf(p), key, elementEq)) {
                            spot.at = .present;
                            spot.index = i;
                            spot.old = p;
                            return spot;
                        }
                    }
                    spot.at = .collision_append;
                    return spot;
                }
                const hdr = headerOf(InteriorHeader, node);
                const slot = slotOf(spot.hash32, shift);
                if (hdr.data_bitmap & bitOf(slot) != 0) {
                    spot.index = dataIndex(hdr.data_bitmap, slot);
                    spot.old = payloads(node)[spot.index];
                    if (keyEquivalent(keyOf(spot.old), key, elementEq)) {
                        spot.at = .present;
                    } else {
                        spot.at = .split;
                        spot.other_hash = indexHashOf(keyOf(spot.old), elementHash);
                    }
                    return spot;
                }
                if (hdr.node_bitmap & bitOf(slot) == 0) return spot;
                node = children(node)[childIndex(hdr.node_bitmap, slot)];
            }
        }

        /// Point the link to `path[k]` at `node`: the root's
        /// `root_node`, or the child slot of `path[k - 1]`, which the
        /// edit owns.
        fn relink(root: *HeapHeader, spot: *Spot, k: usize, node: *HeapHeader) void {
            spot.path[k] = node;
            if (k == 0) {
                headerOf(RootBody, root).root_node = node;
                return;
            }
            const parent = spot.path[k - 1];
            const slot = slotOf(spot.hash32, @intCast(5 * (k - 1)));
            children(parent)[childIndex(headerOf(InteriorHeader, parent).node_bitmap, slot)] = node;
        }

        /// Make `path[0..n]` owned by the edit, top down.
        fn ownPath(heap: *Heap, root: *HeapHeader, spot: *Spot, n: usize, edit: u32) !void {
            for (0..n) |k| {
                const node = spot.path[k];
                if (heap_mod.ownedBy(node, edit)) continue;
                const size = Heap.bodySize(node);
                const copy = try allocNode(heap, size, edit, 0);
                @memcpy(Heap.bodyBytes(copy), Heap.bodyBytes(node));
                relink(root, spot, k, copy);
            }
        }

        /// Store `p` where `spot` says in the collection rooted at
        /// `root`, which the edit owns; the root afterwards, which is
        /// `root` unless an array form grew or promoted.
        fn put(heap: *Heap, root: *HeapHeader, spot_in: Spot, p: P, edit: u32) !*HeapHeader {
            var spot = spot_in;
            const array = spot.len == 0;
            if (!array and spot.at != .present and headerOf(RootBody, root).count == std.math.maxInt(u32)) return error.OutOfMemory;
            switch (spot.at) {
                .present => {
                    if (sameValue(spot.old, p)) return root;
                    if (array) {
                        arrayPayloads(root)[spot.index] = replaced(spot.old, p);
                        return root;
                    }
                    try ownPath(heap, root, &spot, spot.len, edit);
                    const last = spot.path[spot.len - 1];
                    const ps = if (5 * (spot.len - 1) > MAX_TRIE_SHIFT) collisionPayloads(last) else payloads(last);
                    ps[spot.index] = replaced(spot.old, p);
                    return root;
                },
                .array_append => {
                    const n = headerOf(ArrayHeader, root).count;
                    const size = @sizeOf(ArrayHeader) + (n + 1) * @sizeOf(P);
                    const target = if (Heap.resizeInPlace(root, size)) root else blk: {
                        const grown = try heap.alloc(kind, size + edit_slack);
                        _ = Heap.resizeInPlace(grown, size);
                        @memcpy(Heap.bodyBytes(grown)[0..Heap.bodySize(root)], Heap.bodyBytes(root));
                        break :blk grown;
                    };
                    headerOf(ArrayHeader, target).count = n + 1;
                    arrayPayloads(target)[n] = p;
                    return target;
                },
                .promote => {
                    var items: [array_map_max + 1]Item = undefined;
                    for (arrayPayloads(root), 0..) |old, i| items[i] = .of(old, spot.hashes[i], i);
                    items[array_map_max] = .of(p, spot.hash32, array_map_max);
                    std.mem.sortUnstable(Item, &items, {}, Item.lessThan);
                    return Heap.asHeapHeader(try newRoot(heap, items.len, try build(heap, &items, 0, edit)));
                },
                .empty_slot, .collision_append => {
                    try ownPath(heap, root, &spot, spot.len - 1, edit);
                    const k = spot.len - 1;
                    const last = spot.path[k];
                    const grown = if (spot.at == .empty_slot)
                        try insertData(heap, last, slotOf(spot.hash32, @intCast(5 * k)), p, edit)
                    else
                        try appendCollision(heap, last, p, edit);
                    if (grown != last) relink(root, &spot, k, grown);
                },
                .split => {
                    const k = spot.len - 1;
                    const shift: u8 = @intCast(5 * k);
                    const sub = try pair(heap, spot.old, spot.other_hash, p, spot.hash32, shift + branch_bits, edit);
                    try ownPath(heap, root, &spot, spot.len, edit);
                    dataToChild(spot.path[k], slotOf(spot.hash32, shift), sub);
                },
            }
            headerOf(RootBody, root).count += 1;
            return root;
        }

        /// Interior `node` with payload `p` in its empty `slot`: in
        /// place when the edit owns it and its block has room, else an
        /// owned copy.
        fn insertData(heap: *Heap, node: *HeapHeader, slot: u32, p: P, edit: u32) !*HeapHeader {
            const hdr = headerOf(InteriorHeader, node);
            const nd: usize = @popCount(hdr.data_bitmap);
            const nc: usize = @popCount(hdr.node_bitmap);
            const at = dataIndex(hdr.data_bitmap, slot);
            if (!heap_mod.ownedBy(node, edit) or !Heap.resizeInPlace(node, interiorSize(hdr.data_bitmap | bitOf(slot), hdr.node_bitmap))) {
                return withSlot(heap, node, slot, .{ .data = p }, edit);
            }
            const base = afterHeader(node);
            const child_bytes = nc * @sizeOf(*HeapHeader);
            const old_children = base + nd * @sizeOf(P);
            @memmove((old_children + @sizeOf(P))[0..child_bytes], old_children[0..child_bytes]);
            const ps: [*]P = @ptrCast(@alignCast(base));
            @memmove(ps[at + 1 .. nd + 1], ps[at..nd]);
            ps[at] = p;
            hdr.data_bitmap |= bitOf(slot);
            return node;
        }

        /// Collision node `node` with `p` appended: in place when the
        /// edit owns it and its block has room, else an owned copy.
        fn appendCollision(heap: *Heap, node: *HeapHeader, p: P, edit: u32) !*HeapHeader {
            const hdr = headerOf(CollisionHeader, node);
            const n = hdr.count;
            const size = @sizeOf(CollisionHeader) + (n + 1) * @sizeOf(P);
            const target = if (heap_mod.ownedBy(node, edit) and Heap.resizeInPlace(node, size)) node else blk: {
                const copy = try allocNode(heap, size, edit, edit_slack);
                @memcpy(Heap.bodyBytes(copy)[0..Heap.bodySize(node)], Heap.bodyBytes(node));
                break :blk copy;
            };
            headerOf(CollisionHeader, target).count = n + 1;
            collisionPayloads(target)[n] = p;
            return target;
        }

        /// Owned interior `node` with its payload at `slot` replaced by
        /// the child `sub`: smaller, so always in place.
        fn dataToChild(node: *HeapHeader, slot: u32, sub: *HeapHeader) void {
            const hdr = headerOf(InteriorHeader, node);
            const nd: usize = @popCount(hdr.data_bitmap);
            const nc: usize = @popCount(hdr.node_bitmap);
            const base = afterHeader(node);
            const ps: [*]P = @ptrCast(@alignCast(base));
            const at = dataIndex(hdr.data_bitmap, slot);
            @memmove(ps[at .. nd - 1], ps[at + 1 .. nd]);
            const old_cs: [*]*HeapHeader = @ptrCast(@alignCast(base + nd * @sizeOf(P)));
            const cs: [*]*HeapHeader = @ptrCast(@alignCast(base + (nd - 1) * @sizeOf(P)));
            @memmove(cs[0..nc], old_cs[0..nc]);
            const nodes = hdr.node_bitmap | bitOf(slot);
            const ci = childIndex(nodes, slot);
            @memmove(cs[ci + 1 .. nc + 1], cs[ci..nc]);
            cs[ci] = sub;
            hdr.data_bitmap &= ~bitOf(slot);
            hdr.node_bitmap = nodes;
            _ = Heap.resizeInPlace(node, interiorSize(hdr.data_bitmap, nodes));
        }

        /// Remove the key `spot` found present from the collection
        /// rooted at `root`, which the edit owns; the root afterwards,
        /// a fresh empty array form when the last key went (CHAMP.md
        /// §5.6).
        fn drop(heap: *Heap, root: *HeapHeader, spot_in: Spot, edit: u32) !*HeapHeader {
            var spot = spot_in;
            std.debug.assert(spot.at == .present);
            if (spot.len == 0) {
                const hdr = headerOf(ArrayHeader, root);
                const ps = arrayPayloads(root);
                @memmove(ps[spot.index .. ps.len - 1], ps[spot.index + 1 ..]);
                hdr.count -= 1;
                _ = Heap.resizeInPlace(root, @sizeOf(ArrayHeader) + hdr.count * @sizeOf(P));
                return root;
            }
            const rb = headerOf(RootBody, root);
            if (rb.count == 1) return Heap.asHeapHeader(try empty(heap));
            var k: usize = spot.len - 1;
            const bottom = spot.path[k];
            var single: ?P = null;
            if (5 * k > MAX_TRIE_SHIFT) {
                const ps = collisionPayloads(bottom);
                if (ps.len == 2) {
                    single = ps[1 - spot.index];
                } else {
                    try ownPath(heap, root, &spot, k + 1, edit);
                    const owned = spot.path[k];
                    const qs = collisionPayloads(owned);
                    @memmove(qs[spot.index .. qs.len - 1], qs[spot.index + 1 ..]);
                    headerOf(CollisionHeader, owned).count -= 1;
                    _ = Heap.resizeInPlace(owned, @sizeOf(CollisionHeader) + (qs.len - 1) * @sizeOf(P));
                }
            } else {
                const hdr = headerOf(InteriorHeader, bottom);
                if (k > 0 and hdr.node_bitmap == 0 and @popCount(hdr.data_bitmap) == 2) {
                    single = payloads(bottom)[1 - spot.index];
                } else {
                    try ownPath(heap, root, &spot, k + 1, edit);
                    removeData(spot.path[k], slotOf(spot.hash32, @intCast(5 * k)));
                }
            }
            // A lone payload climbs to the first ancestor with other
            // content, or to the root (CHAMP.md §5.5).
            while (single) |lone| {
                k -= 1;
                const hdr = headerOf(InteriorHeader, spot.path[k]);
                if (k > 0 and hdr.data_bitmap == 0 and @popCount(hdr.node_bitmap) == 1) continue;
                try ownPath(heap, root, &spot, k, edit);
                relink(root, &spot, k, try withSlot(heap, spot.path[k], slotOf(spot.hash32, @intCast(5 * k)), .{ .data = lone }, edit));
                single = null;
            }
            rb.count -= 1;
            return root;
        }

        /// Owned interior `node` without its payload at `slot`: always
        /// in place.
        fn removeData(node: *HeapHeader, slot: u32) void {
            const hdr = headerOf(InteriorHeader, node);
            const nd: usize = @popCount(hdr.data_bitmap);
            const nc: usize = @popCount(hdr.node_bitmap);
            const base = afterHeader(node);
            const ps: [*]P = @ptrCast(@alignCast(base));
            const at = dataIndex(hdr.data_bitmap, slot);
            @memmove(ps[at .. nd - 1], ps[at + 1 .. nd]);
            const child_bytes = nc * @sizeOf(*HeapHeader);
            const old_children = base + nd * @sizeOf(P);
            @memmove((old_children - @sizeOf(P))[0..child_bytes], old_children[0..child_bytes]);
            hdr.data_bitmap &= ~bitOf(slot);
            _ = Heap.resizeInPlace(node, interiorSize(hdr.data_bitmap, hdr.node_bitmap));
        }

        // ---- bulk construction ----

        const Item = struct {
            p: P,
            /// The hash bit-reversed above the input position. Ordered by
            /// it, the hash's slot on level 0 comes first, then level 1's,
            /// and so on, so every subtree's keys are contiguous, and
            /// equal hashes keep input order (a collision node is in
            /// association order). One word, stored and compared whole:
            /// on x86-64 an 8-byte load of two 4-byte stores waits for
            /// them to reach the cache (docs/PERF.md "Natives that return
            /// in place").
            key: u64,

            fn of(p: P, h: u32, at: usize) Item {
                return .{ .p = p, .key = @as(u64, @bitReverse(h)) << 32 | @as(u32, @intCast(at)) };
            }

            fn hash(item: Item) u32 {
                return @bitReverse(@as(u32, @intCast(item.key >> 32)));
            }

            fn order(item: Item) u32 {
                return @truncate(item.key);
            }

            fn lessThan(_: void, a: Item, b: Item) bool {
                return a.key < b.key;
            }
        };

        /// The canonical node at `shift` holding `items`, which are
        /// sorted by `Item.lessThan`, have distinct keys, and share
        /// the hash bits below `shift`; at least two below the root.
        /// One allocation per node.
        fn build(heap: *Heap, items: []const Item, shift: u8, edit: u32) !*HeapHeader {
            if (shift > MAX_TRIE_SHIFT) {
                const h = try allocCollision(heap, items[0].hash(), items.len, edit);
                for (collisionPayloads(h), items) |*dst, item| dst.* = item.p;
                return h;
            }
            var data: u32 = 0;
            var nodes: u32 = 0;
            var i: usize = 0;
            while (i < items.len) {
                const slot = slotOf(items[i].hash(), shift);
                const j = runEnd(items, i, shift);
                if (j - i == 1) data |= bitOf(slot) else nodes |= bitOf(slot);
                i = j;
            }
            const h = try allocInterior(heap, data, nodes, edit, 0);
            i = 0;
            while (i < items.len) {
                const slot = slotOf(items[i].hash(), shift);
                const j = runEnd(items, i, shift);
                if (j - i == 1) {
                    payloads(h)[dataIndex(data, slot)] = items[i].p;
                } else {
                    children(h)[childIndex(nodes, slot)] = try build(heap, items[i..j], shift + branch_bits, edit);
                }
                i = j;
            }
            return h;
        }

        fn runEnd(items: []const Item, start: usize, shift: u8) usize {
            const slot = slotOf(items[start].hash(), shift);
            var j = start + 1;
            while (j < items.len and slotOf(items[j].hash(), shift) == slot) j += 1;
            return j;
        }

        /// The map or set of `ps`, as a left fold of `insert` from empty
        /// would build it (a later payload with an equal key replaces
        /// the value, keeping the first key), built bottom-up with one
        /// allocation per node.
        fn fromSlice(heap: *Heap, ps: []const P, elementHash: ElementHash, elementEq: ElementEq) !Value {
            // A literal's handful of payloads is an array form, built as
            // the fold builds it: no hash to index by, no sort.
            if (ps.len <= array_map_max) {
                var kept: [array_map_max]P = undefined;
                var n: usize = 0;
                next: for (ps) |p| {
                    for (kept[0..n]) |*k| if (keyEquivalent(keyOf(k.*), keyOf(p), elementEq)) {
                        k.* = replaced(k.*, p);
                        continue :next;
                    };
                    hashAdded(keyOf(p), elementHash);
                    kept[n] = p;
                    n += 1;
                }
                const h = try allocArray(heap, n);
                @memcpy(arrayPayloads(h), kept[0..n]);
                return valueOf(h, subkind_array_map);
            }
            // A few more payloads sort on the stack.
            var small: [16]Item = undefined;
            const items = if (ps.len <= small.len) small[0..ps.len] else try heap.backing.alloc(Item, ps.len);
            defer if (ps.len > small.len) heap.backing.free(items);
            for (ps, items, 0..) |p, *item, i| item.* = .of(p, indexHashOf(keyOf(p), elementHash), i);
            std.mem.sortUnstable(Item, items, {}, Item.lessThan);
            // Merge equal keys; they share a hash, so they are adjacent.
            var n: usize = 0;
            var i: usize = 0;
            while (i < items.len) {
                const run = n;
                var j = i;
                while (j < items.len and items[j].hash() == items[i].hash()) : (j += 1) {
                    const item = items[j];
                    for (items[run..n]) |*kept| {
                        if (keyEquivalent(keyOf(kept.p), keyOf(item.p), elementEq)) {
                            kept.p = replaced(kept.p, item.p);
                            break;
                        }
                    } else {
                        items[n] = item;
                        n += 1;
                    }
                }
                i = j;
            }
            if (n <= array_map_max) {
                std.mem.sortUnstable(Item, items[0..n], {}, struct {
                    fn byOrder(_: void, a: Item, b: Item) bool {
                        return a.order() < b.order();
                    }
                }.byOrder);
                const h = try allocArray(heap, n);
                for (arrayPayloads(h), items[0..n]) |*dst, item| dst.* = item.p;
                return valueOf(h, subkind_array_map);
            }
            return newRoot(heap, n, try build(heap, items[0..n], 0, 0));
        }

        // ---- dispatch entry points ----

        /// The pre-domain-mix hash (CHAMP.md §7): an unordered combine
        /// of payload hashes, cached in the root header at u32
        /// precision (§7.3).
        fn hashOf(h: *HeapHeader, elementHash: ElementHash) u64 {
            if (h.cachedHash()) |cached| return cached;
            var acc: u64 = hash_mod.unordered_init;
            var n: usize = 0;
            var it = Iter.init(fromHeader(h));
            while (it.next()) |p| : (n += 1) {
                acc = hash_mod.combineUnordered(acc, if (is_map) entryHash(p, elementHash) else elementHash(p));
            }
            const truncated: u32 = @truncate(hash_mod.finalizeUnordered(acc, n));
            if (truncated != 0) h.setCachedHash(truncated);
            return truncated;
        }

        /// Semantic equality (CHAMP.md §6.1): equal counts, and every
        /// payload of `a` found in `b` (for a map, with an equal value).
        fn equal(a: *HeapHeader, b: *HeapHeader, elementHash: ElementHash, elementEq: ElementEq) bool {
            if (a == b) return true;
            const va = fromHeader(a);
            const vb = fromHeader(b);
            if (count(va) != count(vb)) return false;
            var it = Iter.init(va);
            while (it.next()) |p| {
                const q = find(vb, keyOf(p), elementHash, elementEq) orelse return false;
                if (is_map and !elementEq(p.value, q.value)) return false;
            }
            return true;
        }

        /// Every payload of a map or set: array order for an array
        /// root; otherwise depth first, each node's payloads before its
        /// children. Equal CHAMP-backed maps iterate alike (CHAMP.md
        /// §2.2) except inside collision nodes.
        const Iter = struct {
            /// The array root's payloads not yet returned.
            flat: []const P = &.{},
            /// Root interior first; at most seven interior levels and a
            /// collision node below them.
            stack: [8]Frame = undefined,
            depth: u8 = 0,

            const Frame = struct { node: *HeapHeader, shift: u8, data: u32 = 0, child: u8 = 0 };

            pub fn init(v: Value) Iter {
                const h = rootHeader(v);
                if (v.subkind() == subkind_array_map) return .{ .flat = arrayPayloads(h) };
                var it: Iter = .{ .depth = 1 };
                it.stack[0] = .{ .node = headerOf(RootBody, h).root_node, .shift = 0 };
                return it;
            }

            pub fn next(self: *Iter) ?P {
                if (self.flat.len > 0) {
                    defer self.flat = self.flat[1..];
                    return self.flat[0];
                }
                while (self.depth > 0) {
                    const top = &self.stack[self.depth - 1];
                    const collision = top.shift > MAX_TRIE_SHIFT;
                    const ps = if (collision) collisionPayloads(top.node) else payloads(top.node);
                    if (top.data < ps.len) {
                        top.data += 1;
                        return ps[top.data - 1];
                    }
                    const cs = if (collision) &[_]*HeapHeader{} else children(top.node);
                    if (top.child < cs.len) {
                        top.child += 1;
                        self.stack[self.depth] = .{ .node = cs[top.child - 1], .shift = top.shift + branch_bits };
                        self.depth += 1;
                    } else {
                        self.depth -= 1;
                    }
                }
                return null;
            }
        };

        /// GC trace (GC.md §5): every key and value, and every internal
        /// node through `markInternal`.
        fn trace(h: *HeapHeader, visitor: anytype) void {
            if (inferSubkind(h) == subkind_array_map) {
                for (arrayPayloads(h)) |p| markPayload(p, visitor);
            } else {
                traceNode(headerOf(RootBody, h).root_node, 0, visitor);
            }
        }

        fn traceNode(node: *HeapHeader, shift: u8, visitor: anytype) void {
            if (!visitor.markInternal(node)) return;
            if (shift > MAX_TRIE_SHIFT) {
                for (collisionPayloads(node)) |p| markPayload(p, visitor);
                return;
            }
            for (payloads(node)) |p| markPayload(p, visitor);
            for (children(node)) |child| traceNode(child, shift + branch_bits, visitor);
        }

        fn markPayload(p: P, visitor: anytype) void {
            if (is_map) {
                if (p.key.kind().isHeap()) visitor.markValue(p.key);
                if (p.value.kind().isHeap()) visitor.markValue(p.value);
            } else if (p.kind().isHeap()) visitor.markValue(p);
        }

        // ---- introspection for tests (CHAMP.md §4.3, §12.3) ----

        fn collisionCount(v: Value, hash32: u32) ?u32 {
            if (v.subkind() != subkind_champ_root) return null;
            var node = headerOf(RootBody, rootHeader(v)).root_node;
            var shift: u8 = 0;
            while (shift <= MAX_TRIE_SHIFT) : (shift += branch_bits) {
                const hdr = headerOf(InteriorHeader, node);
                const slot = slotOf(hash32, shift);
                if (hdr.node_bitmap & bitOf(slot) == 0) return null;
                node = children(node)[childIndex(hdr.node_bitmap, slot)];
            }
            const hdr = headerOf(CollisionHeader, node);
            std.debug.assert(hdr.shared_hash == hash32);
            return hdr.count;
        }

        fn canonical(v: Value, elementHash: ElementHash) bool {
            if (v.subkind() != subkind_champ_root) return true;
            const root = headerOf(RootBody, rootHeader(v));
            return canonicalNode(root.root_node, 0, 0, elementHash) == root.count;
        }

        /// The key count of the canonical subtree `node` at `shift`,
        /// whose keys' indexing hashes all have `path` in their low
        /// `shift` bits; null when the subtree is not canonical.
        fn canonicalNode(node: *HeapHeader, shift: u8, path: u32, elementHash: ElementHash) ?usize {
            const low: u32 = @truncate((@as(u64, 1) << @intCast(shift)) - 1);
            if (shift > MAX_TRIE_SHIFT) {
                const hdr = headerOf(CollisionHeader, node);
                if (hdr.count < 2 or hdr.shared_hash != path) return null;
                for (collisionPayloads(node)) |p| {
                    if (indexHashOf(keyOf(p), elementHash) != hdr.shared_hash) return null;
                }
                return hdr.count;
            }
            const hdr = headerOf(InteriorHeader, node);
            if (hdr.data_bitmap & hdr.node_bitmap != 0) return null;
            var total: usize = 0;
            var bits = hdr.data_bitmap;
            for (payloads(node)) |p| {
                const slot: u32 = @ctz(bits);
                bits &= bits - 1;
                const h = indexHashOf(keyOf(p), elementHash);
                if (h & low != path or slotOf(h, shift) != slot) return null;
                total += 1;
            }
            bits = hdr.node_bitmap;
            for (children(node)) |child| {
                const slot: u32 = 31 - @clz(bits);
                bits &= ~bitOf(slot);
                total += canonicalNode(child, shift + branch_bits, path | (slot << @intCast(shift)), elementHash) orelse return null;
            }
            if (shift > 0 and total < 2) return null;
            return total;
        }
    };
}

const MapTrie = Trie(Entry, .persistent_map);
const SetTrie = Trie(Value, .persistent_set);

/// Per-entry hash (CHAMP.md §7.1): two ordered combines, no finalize,
/// no inner domain mix. SEMANTICS.md §3.2 pins this formula.
pub inline fn entryHash(e: Entry, elementHash: ElementHash) u64 {
    var acc: u64 = hash_mod.ordered_init;
    acc = hash_mod.combineOrdered(acc, elementHash(e.key));
    acc = hash_mod.combineOrdered(acc, elementHash(e.value));
    return acc;
}

// =============================================================================
// Public API — map (CHAMP.md §8)
// =============================================================================

/// A fresh empty map: a zero-entry array-map, not a shared singleton.
pub const mapEmpty = MapTrie.empty;

/// The map of `entries`; a later entry with an equal key wins
/// (CHAMP.md §8.1). Built bottom-up: one allocation per node.
pub const mapFromEntries = MapTrie.fromSlice;

pub const mapCount = MapTrie.count;

pub fn mapGet(m: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) MapLookup {
    const e = MapTrie.find(m, key, elementHash, elementEq) orelse return .absent;
    return .{ .present = e.value };
}

/// The entry whose key equals `key`, with the key as `m` holds it
/// (Clojure's `find`), or null.
pub fn mapFind(m: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) ?Entry {
    return MapTrie.find(m, key, elementHash, elementEq);
}

/// `m` with `key → val` (CHAMP.md §8.1). Returns `m` itself when the
/// key already maps to a bit-identical value; a replaced value keeps
/// the original key object.
pub fn mapAssoc(heap: *Heap, m: Value, key: Value, val: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return MapTrie.insert(heap, m, .{ .key = key, .value = val }, elementHash, elementEq);
}

/// `m` without `key`; `m` itself when the key is absent (CHAMP.md
/// §5.4-§5.6, §8.1).
pub const mapDissoc = MapTrie.remove;

pub const MapIter = MapTrie.Iter;

pub const mapIter = MapIter.init;

/// A user-facing map Value for a root header (TRANSIENT.md §8), its
/// subkind read off the body size.
pub const valueFromMapHeader = MapTrie.fromHeader;

// =============================================================================
// In-place edits for transients (TRANSIENT.md §1)
// =============================================================================

/// A copy of the map or set root `src` for a transient to own: the
/// same payloads, no metadata, no cached hash.
pub fn copyRoot(heap: *Heap, src: *HeapHeader) !*HeapHeader {
    const size = Heap.bodySize(src);
    const h = try heap.alloc(@fromBackingInt(@intCast(src.kind)), size);
    @memcpy(Heap.bodyBytes(h), Heap.bodyBytes(src));
    return h;
}

pub const MapSpot = MapTrie.Spot;

/// Where `key` is or would go in `m`: every hash and comparison an
/// edit makes, and no change.
pub const mapLocate = MapTrie.locate;

pub fn mapSpotPresent(spot: MapSpot) bool {
    return spot.at == .present;
}

/// The value stored under the key `spot` found, or null when absent.
pub fn mapSpotValue(spot: MapSpot) ?Value {
    return if (spot.at == .present) spot.old.value else null;
}

/// Store `key → val` at `spot` in the map rooted at `root`, which the
/// edit `edit` owns, as `mapAssoc` would; the root afterwards.
pub fn mapPut(heap: *Heap, root: *HeapHeader, spot: MapSpot, key: Value, val: Value, edit: u32) !*HeapHeader {
    return MapTrie.put(heap, root, spot, .{ .key = key, .value = val }, edit);
}

/// Remove the key `spot` found present, as `mapDissoc` would; the root
/// afterwards.
pub const mapDrop = MapTrie.drop;

pub const SetSpot = SetTrie.Spot;

pub const setLocate = SetTrie.locate;

pub fn setSpotPresent(spot: SetSpot) bool {
    return spot.at == .present;
}

pub const setPut = SetTrie.put;

pub const setDrop = SetTrie.drop;

// =============================================================================
// Public API — set
// =============================================================================

/// A fresh empty set: a zero-element array-set.
pub const setEmpty = SetTrie.empty;

/// The set of `elems`, duplicates merged. Built bottom-up.
pub const setFromElements = SetTrie.fromSlice;

pub const setCount = SetTrie.count;

pub fn setContains(s: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) bool {
    return setGet(s, elem, elementHash, elementEq) != null;
}

/// The element of `s` equal to `elem`, as `s` holds it, or null: what
/// `(get s elem)` returns, which may differ from `elem` itself (a list
/// for a vector key, a different number type).
pub fn setGet(s: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) ?Value {
    return SetTrie.find(s, elem, elementHash, elementEq);
}

/// `s` with `elem`; `s` itself when `elem` is already present.
pub const setConj = SetTrie.insert;

/// `s` without `elem`; `s` itself when `elem` is absent.
pub const setDisj = SetTrie.remove;

pub const SetIter = SetTrie.Iter;

pub const setIter = SetIter.init;

pub const valueFromSetHeader = SetTrie.fromHeader;

// =============================================================================
// Dispatch and GC entry points (CHAMP.md §9, GC.md §5)
// =============================================================================

/// Pre-domain-mix hash of a map root; `dispatch.hashValue` mixes in
/// the map's domain, its kind number 18.
pub const hashMap = MapTrie.hashOf;

/// Pre-domain-mix hash of a set root (domain: kind number 19).
pub const hashSet = SetTrie.hashOf;

pub const equalMap = MapTrie.equal;

pub const equalSet = SetTrie.equal;

pub const traceMap = MapTrie.trace;

pub const traceSet = SetTrie.trace;

// =============================================================================
// Trie introspection for tests (CHAMP.md §4.3, §12.3)
// =============================================================================

/// The entry count of the collision node holding every key of `m`
/// whose indexing hash is `hash32`, or `null` when no such node exists
/// (an array-map, or a descent that ends above the collision layer).
/// A collision fixture asserts through this that its keys reached the
/// collision node.
pub const mapCollisionCount = MapTrie.collisionCount;

pub const setCollisionCount = SetTrie.collisionCount;

/// Whether the trie of map or set `v` has the canonical layout
/// (CHAMP.md §4.3): bitmaps disjoint, every key at the slot its
/// indexing hash selects along the path from the root, every
/// collision node holding at least two keys that share its hash, and
/// every node below the root holding at least two keys in its subtree
/// (a subtree with one key is that key, inline in its parent). An
/// array-map or array-set is trivially canonical.
pub fn canonicalTrie(v: Value, elementHash: ElementHash) bool {
    return switch (v.kind()) {
        .persistent_map => MapTrie.canonical(v, elementHash),
        else => SetTrie.canonical(v, elementHash),
    };
}

// =============================================================================
// Inline tests
//
// Unit-level invariants + trap coverage. Property tests live in
// test/prop/champ.zig.
// =============================================================================

// ---- Synthetic element callbacks for inline tests ----

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
        .string => string_mod.bytesEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(b)),
        else => false,
    };
}

/// A hash that collides every heap key: the low 32 bits, the indexing
/// hash (§5.1), are pinned; the high 32 are the key's own, so the
/// entries of a colliding map still hash apart.
fn collidingHash(x: Value) u64 {
    return (@as(u64, string_mod.hashHeader(Heap.asHeapHeader(x))) << 32) | 0xDEAD_BEEF;
}

/// The `i`-th key of a collision fixture: a fresh heap string, so the
/// indexing hash goes through the `elementHash` callback (§5.1).
/// Equal by content under `synthEq`, so any call with the same `i`
/// names the same key.
fn collidingKey(heap: *Heap, i: u32) !Value {
    var buf: [32]u8 = undefined;
    const text = std.mem.print(&buf, "collider-{d}", .{i}) catch unreachable;
    return string_mod.fromBytes(heap, text);
}

// ---- Body layout tests ----

test "Entry layout: 32 bytes, key at 0, value at 16" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Entry));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Entry, "key"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Entry, "value"));
}

test "RootBody layout: 16 bytes total" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(RootBody));
    try testing.expectEqual(@as(usize, 0), @offsetOf(RootBody, "count"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(RootBody, "root_node"));
}

// ---- mapEmpty / mapCount ----

test "mapEmpty: subkind 0, count 0" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try mapEmpty(&heap);
    try testing.expectEqual(Kind.persistent_map, m.kind());
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 0), mapCount(m));
}

test "mapEmpty: each call allocates a fresh header (not a shared singleton)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try mapEmpty(&heap);
    const b = try mapEmpty(&heap);
    try testing.expect(Heap.asHeapHeader(a) != Heap.asHeapHeader(b));
}

// ---- Nil key / nil value legality ----

test "nil is a legal map value — MapLookup distinguishes absent from present-with-nil" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const k = value.testKeyword(1);
    const m1 = try mapAssoc(&heap, m0, k, value.nilValue(), &synthHash, &synthEq);
    const lookup = mapGet(m1, k, &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expect(v.isNil()),
        .absent => try testing.expect(false),
    }
    // Absent key still returns .absent.
    try testing.expect(mapGet(m1, value.testKeyword(999), &synthHash, &synthEq) == .absent);
}

test "nil is a legal map key" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const m1 = try mapAssoc(&heap, m0, value.nilValue(), value.fromFixnum(99).?, &synthHash, &synthEq);
    switch (mapGet(m1, value.nilValue(), &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 99), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

// ---- Promotion boundary ----

test "promotion: count 8 stays array-map, count 9 promotes to CHAMP" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        m = try mapAssoc(&heap, m, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 8), mapCount(m));
    // Ninth distinct key triggers promotion.
    m = try mapAssoc(&heap, m, value.testKeyword(100), value.fromFixnum(100).?, &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, m.subkind());
    try testing.expectEqual(@as(usize, 9), mapCount(m));
    // All nine keys must be retrievable.
    i = 0;
    while (i < 8) : (i += 1) {
        switch (mapGet(m, value.testKeyword(i), &synthHash, &synthEq)) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
    switch (mapGet(m, value.testKeyword(100), &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 100), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "a map or set at its largest count refuses a new key as out of memory, and takes a present one" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // A root's count field set to the bound: building one that size
    // takes 128 GiB.
    var m = try mapEmpty(&heap);
    for (0..9) |i| m = try mapAssoc(&heap, m, value.testKeyword(@intCast(i)), value.nilValue(), &synthHash, &synthEq);
    headerOf(RootBody, Heap.asHeapHeader(m)).count = std.math.maxInt(u32);
    try testing.expectError(error.OutOfMemory, mapAssoc(&heap, m, value.testKeyword(100), value.nilValue(), &synthHash, &synthEq));
    _ = try mapAssoc(&heap, m, value.testKeyword(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    const root = try copyRoot(&heap, Heap.asHeapHeader(m));
    const spot = mapLocate(valueFromMapHeader(root), value.testKeyword(100), &synthHash, &synthEq);
    try testing.expectError(error.OutOfMemory, mapPut(&heap, root, spot, value.testKeyword(100), value.nilValue(), 1));
    var s = try setEmpty(&heap);
    for (0..9) |i| s = try setConj(&heap, s, value.testKeyword(@intCast(i)), &synthHash, &synthEq);
    headerOf(RootBody, Heap.asHeapHeader(s)).count = std.math.maxInt(u32);
    try testing.expectError(error.OutOfMemory, setConj(&heap, s, value.testKeyword(100), &synthHash, &synthEq));
}

test "promotion: duplicate assoc at count 8 does NOT promote" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        m = try mapAssoc(&heap, m, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    // Associng an existing key with a new value must NOT promote.
    m = try mapAssoc(&heap, m, value.testKeyword(3), value.fromFixnum(999).?, &synthHash, &synthEq);
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 8), mapCount(m));
}

test "no demotion: dissoc from CHAMP back to 8 entries stays CHAMP" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        m = try mapAssoc(&heap, m, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_champ_root, m.subkind());
    m = try mapDissoc(&heap, m, value.testKeyword(0), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 8), mapCount(m));
    try testing.expectEqual(subkind_champ_root, m.subkind()); // NOT demoted
}

// ---- Dissoc-to-empty ----

test "dissoc: last CHAMP entry removed returns fresh subkind-0 empty map" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        m = try mapAssoc(&heap, m, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    i = 0;
    while (i < 9) : (i += 1) {
        m = try mapDissoc(&heap, m, value.testKeyword(i), &synthHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 0), mapCount(m));
    try testing.expectEqual(subkind_array_map, m.subkind());
}

// ---- Duplicate-key canonicalization in mapFromEntries ----

test "mapFromEntries: later wins on duplicate keys; count reflects unique" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const k = value.testKeyword(1);
    const entries = [_]Entry{
        .{ .key = k, .value = value.fromFixnum(1).? },
        .{ .key = k, .value = value.fromFixnum(2).? },
        .{ .key = k, .value = value.fromFixnum(3).? },
    };
    const m = try mapFromEntries(&heap, &entries, &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 1), mapCount(m));
    switch (mapGet(m, k, &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 3), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "assoc over an equal key keeps the original key object, array-map and CHAMP alike" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    for ([_]u32{ 1, 20 }) |n| {
        var m = try mapEmpty(&heap);
        for (0..n) |i| m = try mapAssoc(&heap, m, try collidingKey(&heap, @intCast(i)), value.fromFixnum(0).?, &synthHash2, &synthEq);
        const first = mapIterKey(m, try collidingKey(&heap, 0));
        m = try mapAssoc(&heap, m, try collidingKey(&heap, 0), value.fromFixnum(1).?, &synthHash2, &synthEq);
        try testing.expectEqual(first.payload, mapIterKey(m, try collidingKey(&heap, 0)).payload);
        switch (mapGet(m, first, &synthHash2, &synthEq)) {
            .present => |v| try testing.expectEqual(@as(i64, 1), v.asFixnum()),
            .absent => return error.TestUnexpectedResult,
        }
    }
}

/// Content hash for string keys, so equal strings in distinct
/// allocations collide on purpose and nothing else does.
fn synthHash2(x: Value) u64 {
    return if (x.kind() == .string) string_mod.hashHeader(Heap.asHeapHeader(x)) else x.hashImmediate();
}

/// The key object `m` stores for a key equal to `key`.
fn mapIterKey(m: Value, key: Value) Value {
    var it = mapIter(m);
    while (it.next()) |e| if (synthEq(e.key, key)) return e.key;
    unreachable;
}

test "mapFromEntries of a literal's few entries asks the backing allocator for nothing" {
    // Slabs do not come from the backing allocator, so a heap over one
    // that refuses everything still holds small blocks.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var heap = Heap.init(failing.allocator());
    defer heap.deinit();
    const es = [_]Entry{
        .{ .key = value.testKeyword(1), .value = value.fromFixnum(1).? },
        .{ .key = value.testKeyword(2), .value = value.fromFixnum(2).? },
        .{ .key = value.testKeyword(3), .value = value.fromFixnum(3).? },
    };
    const m = try mapFromEntries(&heap, &es, &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 3), mapCount(m));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "mapFromEntries and setFromElements build what a fold of assoc and conj builds" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Sizes across the array/CHAMP boundary, keys drawn with
    // repeats, under a real hash and under one that forces collision
    // nodes (string keys through `collidingHash`).
    var prng = std.Random.DefaultPrng.init(0x6368616d70);
    const r = prng.random();
    for ([_]usize{ 0, 1, 8, 9, 10, 40, 300 }) |n| {
        for ([_]ElementHash{ &synthHash2, &collidingHash }) |h| {
            const entries = try testing.allocator.alloc(Entry, n);
            defer testing.allocator.free(entries);
            for (entries, 0..) |*e, i| e.* = .{ .key = try collidingKey(&heap, r.uintLessThan(u32, @intCast(n / 2 + 1))), .value = value.fromFixnum(@intCast(i)).? };
            var fold = try mapEmpty(&heap);
            var set_fold = try setEmpty(&heap);
            for (entries) |e| {
                fold = try mapAssoc(&heap, fold, e.key, e.value, h, &synthEq);
                set_fold = try setConj(&heap, set_fold, e.key, h, &synthEq);
            }
            const built = try mapFromEntries(&heap, entries, h, &synthEq);
            try testing.expectEqual(fold.subkind(), built.subkind());
            try testing.expect(canonicalTrie(built, h));
            var a = mapIter(fold);
            var b = mapIter(built);
            while (a.next()) |x| {
                const y = b.next().?;
                try testing.expectEqual(x.key.payload, y.key.payload);
                try testing.expectEqual(x.value.payload, y.value.payload);
            }
            try testing.expect(b.next() == null);

            const keys = try testing.allocator.alloc(Value, n);
            defer testing.allocator.free(keys);
            for (entries, keys) |e, *k| k.* = e.key;
            const set_built = try setFromElements(&heap, keys, h, &synthEq);
            try testing.expectEqual(set_fold.subkind(), set_built.subkind());
            var sa = setIter(set_fold);
            var sb = setIter(set_built);
            while (sa.next()) |x| try testing.expectEqual(x.payload, sb.next().?.payload);
            try testing.expect(sb.next() == null);
        }
    }
}

// ---- Collision nodes ----

test "collision nodes: an immediate key hashes inline and never reaches the callback" {
    // The counterpart of the collision stress tests (test/prop/champ.zig
    // M10, S9): keyword keys under a callback that pins every hash
    // partition cleanly, because
    // `indexHashOf` hashes an immediate through `hashImmediate` and
    // consults `elementHash` for heap keys only (§5.1). A collision
    // fixture keyed by immediates would exercise no collision node.
    const pinned = struct {
        fn f(_: Value) u64 {
            return 0xDEAD_BEEF;
        }
    };
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        m = try mapAssoc(&heap, m, value.testKeyword(i), value.fromFixnum(@intCast(i)).?, &pinned.f, &synthEq);
    }
    try testing.expectEqual(@as(usize, 10), mapCount(m));
    try testing.expectEqual(@as(?u32, null), mapCollisionCount(m, 0xDEAD_BEEF));
}

// ---- Bitmap positional arithmetic ----

test "dataIndex / childIndex: monotonic ranks under bitmap mutation" {
    // dataIndex counts set bits at positions BELOW the target slot.
    try testing.expectEqual(@as(usize, 0), dataIndex(0b0001, 0));
    try testing.expectEqual(@as(usize, 1), dataIndex(0b0011, 1));
    try testing.expectEqual(@as(usize, 2), dataIndex(0b0101, 3));
    try testing.expectEqual(@as(usize, 0), dataIndex(0b0000, 5));
    // childIndex counts set bits at positions ABOVE the target slot.
    // Layout = descending slot order.
    try testing.expectEqual(@as(usize, 0), childIndex(0b0100, 2)); // slot 2 is highest
    try testing.expectEqual(@as(usize, 1), childIndex(0b0101, 0)); // slot 0, slot 2 above
    try testing.expectEqual(@as(usize, 0), childIndex(0b1000_0000_0000_0000_0000_0000_0000_0000, 31));
}

// ---- Keyword-keyed fast path ----

test "keyword-keyed fast path: intern-id identity matches general equality" {
    // Two keyword Values with the same intern id must register as
    // equal under `keyEquivalent` even when their tag bits differ
    // (they shouldn't — keyword Values with the same id produce
    // identical tags — but the test pins correctness end-to-end).
    const a = value.testKeyword(42);
    const b = value.testKeyword(42);
    try testing.expect(a.identicalTo(b));
    const wrapEq = struct {
        fn f(x: Value, y: Value) bool {
            _ = x;
            _ = y;
            return false; // deliberately return false to prove the keyword fast path bypasses this
        }
    };
    try testing.expect(keyEquivalent(a, b, &wrapEq.f));
    // Different keyword ids → not equal.
    try testing.expect(!keyEquivalent(value.testKeyword(1), value.testKeyword(2), &wrapEq.f));
}

test "immediate keys compare inline: never through the callback, never equal to a heap key" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const never = struct {
        fn f(_: Value, _: Value) bool {
            unreachable;
        }
    };
    try testing.expect(keyEquivalent(value.fromFloat(-0.0), value.fromFloat(0.0), &never.f));
    try testing.expect(!keyEquivalent(value.fromFixnum(1).?, value.fromFixnum(2).?, &never.f));
    try testing.expect(!keyEquivalent(value.fromFixnum(1).?, value.fromFloat(1.0), &never.f));
    const s = try string_mod.fromBytes(&heap, "1");
    try testing.expect(!keyEquivalent(value.fromFixnum(1).?, s, &never.f));
    try testing.expect(!keyEquivalent(s, value.testKeyword(1), &never.f));
}

// ---- Single-entry-subtree promotion ----

test "single-entry-subtree promotion: dissoc inside a deep subtree pulls entry up" {
    // Build a map that creates a deeper subtree (two keys hashing to
    // the same level-0 slot but different level-1 slots), then dissoc
    // one of those keys and confirm the other is pulled back up into
    // the parent's data area.
    //
    // Setup: two string keys (heap keys, so the callback shapes their
    // indexing hash; §5.1) share the level-0 slot and split at
    // level 1. The eight filler keys are keywords and hash inline.
    const twoColliders = struct {
        fn f(x: Value) u64 {
            // Low 5 bits zero for both (slot 0 at level 0); bits 5..9
            // differ (slot 4 and slot 5 at level 1).
            const bytes = string_mod.asBytes(x);
            if (std.mem.eql(u8, bytes, "collider-100")) return 100 << 5;
            if (std.mem.eql(u8, bytes, "collider-101")) return 101 << 5;
            return string_mod.hashHeader(Heap.asHeapHeader(x));
        }
    };
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    // First fill 8 distinct keys so promotion to CHAMP happens.
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        m = try mapAssoc(&heap, m, value.testKeyword(i + 200), value.fromFixnum(@intCast(i)).?, &twoColliders.f, &synthEq);
    }
    // Then add the two colliders.
    m = try mapAssoc(&heap, m, try collidingKey(&heap, 100), value.fromFixnum(1000).?, &twoColliders.f, &synthEq);
    m = try mapAssoc(&heap, m, try collidingKey(&heap, 101), value.fromFixnum(1001).?, &twoColliders.f, &synthEq);
    try testing.expectEqual(@as(usize, 10), mapCount(m));
    // Dissoc one collider — the other should still be findable.
    m = try mapDissoc(&heap, m, try collidingKey(&heap, 100), &twoColliders.f, &synthEq);
    try testing.expectEqual(@as(usize, 9), mapCount(m));
    switch (mapGet(m, try collidingKey(&heap, 101), &twoColliders.f, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 1001), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

/// Indexing hash for the canonical-layout tests: a string key
/// "collider-N" hashes to N, so a test places each key at chosen
/// slots on every level.
fn slotHash(x: Value) u64 {
    const bytes = string_mod.asBytes(x);
    return std.fmt.parseInt(u32, bytes["collider-".len..], 10) catch unreachable;
}

/// Key `(c << 10) | (b << 5) | a`: slot a on level 0, b on level 1,
/// c on level 2.
fn slotKey(heap: *Heap, a: u32, b: u32, c: u32) !Value {
    return collidingKey(heap, (c << 10) | (b << 5) | a);
}

test "dissoc passes a lone entry up through every emptied level (canonical layout)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Nine fillers at level-0 slots 8..16, then `a` at slot 7. `b`
    // shares a's slots on levels 0 and 1 and splits from it on level
    // 2, so assoc b builds a two-level subtree under slot 7; dissoc b
    // must pull `a` all the way back to slot 7 of the root.
    var base = try mapEmpty(&heap);
    for (8..17) |i| base = try mapAssoc(&heap, base, try slotKey(&heap, @intCast(i), 0, 0), value.fromFixnum(@intCast(i)).?, &slotHash, &synthEq);
    const a = try slotKey(&heap, 7, 3, 1);
    const b = try slotKey(&heap, 7, 3, 2);
    const m2 = try mapAssoc(&heap, base, a, value.fromFixnum(1).?, &slotHash, &synthEq);
    const with_b = try mapAssoc(&heap, m2, b, value.fromFixnum(2).?, &slotHash, &synthEq);
    try testing.expect(canonicalTrie(with_b, &slotHash));
    const m1 = try mapDissoc(&heap, with_b, b, &slotHash, &synthEq);
    try testing.expect(canonicalTrie(m1, &slotHash));
    // Equal maps with canonical tries iterate in the same order.
    var it1 = mapIter(m1);
    var it2 = mapIter(m2);
    while (it2.next()) |e2| {
        const e1 = it1.next().?;
        try testing.expect(synthEq(e1.key, e2.key));
    }
    try testing.expect(it1.next() == null);

    var s_base = try setEmpty(&heap);
    for (8..17) |i| s_base = try setConj(&heap, s_base, try slotKey(&heap, @intCast(i), 0, 0), &slotHash, &synthEq);
    const s2 = try setConj(&heap, s_base, a, &slotHash, &synthEq);
    const s1 = try setDisj(&heap, try setConj(&heap, s2, b, &slotHash, &synthEq), b, &slotHash, &synthEq);
    try testing.expect(canonicalTrie(s1, &slotHash));
    var si1 = setIter(s1);
    var si2 = setIter(s2);
    while (si2.next()) |x2| try testing.expect(synthEq(si1.next().?, x2));
    try testing.expect(si1.next() == null);
}

test "dissoc from a collision node passes the survivor up to the root" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    for (8..17) |i| m = try mapAssoc(&heap, m, value.fromFixnum(@intCast(i)).?, value.nilValue(), &collidingHash, &synthEq);
    m = try mapAssoc(&heap, m, try collidingKey(&heap, 1), value.nilValue(), &collidingHash, &synthEq);
    m = try mapAssoc(&heap, m, try collidingKey(&heap, 2), value.nilValue(), &collidingHash, &synthEq);
    try testing.expectEqual(@as(?u32, 2), mapCollisionCount(m, 0xDEAD_BEEF));
    try testing.expect(canonicalTrie(m, &collidingHash));
    m = try mapDissoc(&heap, m, try collidingKey(&heap, 1), &collidingHash, &synthEq);
    try testing.expectEqual(@as(?u32, null), mapCollisionCount(m, 0xDEAD_BEEF));
    try testing.expect(canonicalTrie(m, &collidingHash));
}

// =============================================================================
// Set inline tests
//
// Unit-level invariants for the set kind. Mirrors the map test layout
// but exercises set-specific shapes (no value column, no replace-
// value case, contains bool instead of get union). Property tests
// live in test/prop/champ.zig (S1..S9).
// =============================================================================

test "set: promotion at count 8→9 → CHAMP, no demotion on disj back to 8" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try setEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        s = try setConj(&heap, s, value.testKeyword(i), &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_array_map, s.subkind());
    s = try setConj(&heap, s, value.testKeyword(100), &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, s.subkind());
    try testing.expectEqual(@as(usize, 9), setCount(s));
    // Every element must still be findable.
    i = 0;
    while (i < 8) : (i += 1) {
        try testing.expect(setContains(s, value.testKeyword(i), &synthHash, &synthEq));
    }
    try testing.expect(setContains(s, value.testKeyword(100), &synthHash, &synthEq));
    // Dissoc back to 8 — must stay CHAMP (no demotion).
    s = try setDisj(&heap, s, value.testKeyword(100), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 8), setCount(s));
    try testing.expectEqual(subkind_champ_root, s.subkind());
}
