//! coll/champ.zig — persistent map + set heap kinds.
//!
//! Authoritative spec: `docs/CHAMP.md`. Semantic framing:
//! `docs/SEMANTICS.md` §2.6 (associative and set equality categories)
//! and §3.2 (hash-domain bytes `0xF1` / `0xF2`, map entry-hash
//! formula). Physical storage: `docs/HEAP.md`. Representation
//! choices: `docs/VALUE.md` §2.2.
//!
//! One trie implementation, `Trie(P)`, serves both kinds: a map's
//! payload is an `Entry` (key + value, 32 bytes), a set's a bare key
//! `Value` (16 bytes). The public `map*` / `set*` functions are thin
//! wrappers over `MapTrie` and `SetTrie`.
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
/// "present with nil value" (CHAMP.md §6.6).
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
/// §6.5): bit identity, and interned-id identity for two keywords.
inline fn keyEquivalent(a: Value, b: Value, elementEq: ElementEq) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    if (a.kind() == .keyword and b.kind() == .keyword) {
        return a.asKeywordId() == b.asKeywordId();
    }
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
            if (std.debug.runtime_safety) std.debug.assert(Heap.bodyBytes(h).len == 8 + @as(usize, n) * @sizeOf(P));
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
            if (std.debug.runtime_safety) std.debug.assert(Heap.bodyBytes(h).len == 8 + @as(usize, n) * @sizeOf(P));
            const ptr: [*]P = @ptrCast(@alignCast(afterHeader(h)));
            return ptr[0..n];
        }

        fn allocArray(heap: *Heap, n: usize) !*HeapHeader {
            std.debug.assert(n <= array_map_max);
            const h = try heap.alloc(kind, @sizeOf(ArrayHeader) + n * @sizeOf(P));
            headerOf(ArrayHeader, h).count = @intCast(n);
            return h;
        }

        fn allocInterior(heap: *Heap, data_bitmap: u32, node_bitmap: u32) !*HeapHeader {
            std.debug.assert(data_bitmap & node_bitmap == 0);
            const size = @sizeOf(InteriorHeader) +
                @as(usize, @popCount(data_bitmap)) * @sizeOf(P) +
                @as(usize, @popCount(node_bitmap)) * @sizeOf(*HeapHeader);
            const h = try heap.alloc(kind, size);
            headerOf(InteriorHeader, h).* = .{ .data_bitmap = data_bitmap, .node_bitmap = node_bitmap };
            return h;
        }

        fn allocCollision(heap: *Heap, shared_hash: u32, n: usize) !*HeapHeader {
            std.debug.assert(n >= 2);
            const h = try heap.alloc(kind, @sizeOf(CollisionHeader) + n * @sizeOf(P));
            headerOf(CollisionHeader, h).* = .{ .shared_hash = shared_hash, .count = @intCast(n) };
            return h;
        }

        fn valueOf(h: *HeapHeader, subkind: u16) Value {
            return .{
                .tag = @as(u64, @intFromEnum(kind)) | (@as(u64, subkind) << 16),
                .payload = @intFromPtr(h),
            };
        }

        fn newRoot(heap: *Heap, n: usize, node: *HeapHeader) !Value {
            const h = try heap.alloc(kind, @sizeOf(RootBody));
            headerOf(RootBody, h).* = .{ .count = @intCast(n), ._pad = 0, .root_node = node };
            return valueOf(h, subkind_champ_root);
        }

        /// The subkind of a map or set root header, from its body size:
        /// a CHAMP root is 16 bytes, which no array body (8 + n·32 or
        /// 8 + n·16 bytes) can be.
        fn inferSubkind(h: *HeapHeader) u16 {
            std.debug.assert(h.kind == @intFromEnum(kind));
            const size = Heap.bodyBytes(h).len;
            if (size == @sizeOf(RootBody)) return subkind_champ_root;
            if (std.debug.runtime_safety) {
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

        /// `v` with `p` stored under its key (CHAMP.md §8.1): `v`
        /// itself when that changes nothing.
        fn insert(heap: *Heap, v: Value, p: P, elementHash: ElementHash, elementEq: ElementEq) !Value {
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
                    const nh = try allocArray(heap, ps.len + 1);
                    splice(P, arrayPayloads(nh), ps, ps.len, false, p);
                    return valueOf(nh, subkind_array_map);
                }
                // Promotion (CHAMP.md §5.3): build the trie of the nine.
                var items: [array_map_max + 1]Item = undefined;
                for (ps, 0..) |old, i| items[i] = .{ .p = old, .hash = indexHashOf(keyOf(old), elementHash), .order = @intCast(i) };
                items[array_map_max] = .{ .p = p, .hash = indexHashOf(keyOf(p), elementHash), .order = array_map_max };
                std.mem.sortUnstable(Item, &items, {}, Item.lessThan);
                return newRoot(heap, items.len, try build(heap, &items, 0));
            }
            const root = headerOf(RootBody, h);
            var added = false;
            const node = try insertIn(heap, root.root_node, p, indexHashOf(keyOf(p), elementHash), 0, elementHash, elementEq, &added);
            if (node == root.root_node) return v;
            return newRoot(heap, root.count + @intFromBool(added), node);
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
                    const nh = try allocCollision(heap, hash32, ps.len);
                    @memcpy(collisionPayloads(nh), ps);
                    collisionPayloads(nh)[i] = replaced(old, p);
                    return nh;
                }
                added.* = true;
                const nh = try allocCollision(heap, hash32, ps.len + 1);
                splice(P, collisionPayloads(nh), ps, ps.len, false, p);
                return nh;
            }
            const hdr = headerOf(InteriorHeader, node).*;
            const slot = slotOf(hash32, shift);
            if (hdr.data_bitmap & bitOf(slot) != 0) {
                const old = payloads(node)[dataIndex(hdr.data_bitmap, slot)];
                if (keyEquivalent(keyOf(old), keyOf(p), elementEq)) {
                    if (sameValue(old, p)) return node;
                    return withSlot(heap, node, slot, .{ .data = replaced(old, p) });
                }
                // Two keys on one slot: they move into a subtree.
                added.* = true;
                const sub = try pair(heap, old, indexHashOf(keyOf(old), elementHash), p, hash32, shift + branch_bits);
                return withSlot(heap, node, slot, .{ .child = sub });
            }
            if (hdr.node_bitmap & bitOf(slot) != 0) {
                const child = children(node)[childIndex(hdr.node_bitmap, slot)];
                const new_child = try insertIn(heap, child, p, hash32, shift + branch_bits, elementHash, elementEq, added);
                if (new_child == child) return node;
                return withSlot(heap, node, slot, .{ .child = new_child });
            }
            added.* = true;
            return withSlot(heap, node, slot, .{ .data = p });
        }

        /// The subtree at `shift` holding `a` and `b`, distinct keys
        /// whose hashes share the bits below `shift`: a collision node
        /// past the last level, else an interior with both inline or,
        /// when they share this level's slot too, one child.
        fn pair(heap: *Heap, a: P, ha: u32, b: P, hb: u32, shift: u8) !*HeapHeader {
            if (shift > MAX_TRIE_SHIFT) {
                const h = try allocCollision(heap, ha, 2);
                collisionPayloads(h)[0] = a;
                collisionPayloads(h)[1] = b;
                return h;
            }
            const sa = slotOf(ha, shift);
            const sb = slotOf(hb, shift);
            if (sa == sb) {
                const h = try allocInterior(heap, 0, bitOf(sa));
                children(h)[0] = try pair(heap, a, ha, b, hb, shift + branch_bits);
                return h;
            }
            const h = try allocInterior(heap, bitOf(sa) | bitOf(sb), 0);
            payloads(h)[@intFromBool(sa > sb)] = a;
            payloads(h)[@intFromBool(sb > sa)] = b;
            return h;
        }

        /// `v` without the payload keyed `key`; `v` itself when there
        /// is none. A CHAMP root emptied by it becomes a fresh empty
        /// array (CHAMP.md §5.6); there is no demotion otherwise
        /// (§5.4).
        fn remove(heap: *Heap, v: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
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
                    const nh = try allocCollision(heap, hash32, ps.len - 1);
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
                return .{ .node = try withSlot(heap, node, slot, .empty) };
            }
            if (hdr.node_bitmap & bitOf(slot) == 0) return null;
            const child = children(node)[childIndex(hdr.node_bitmap, slot)];
            return switch ((try removeIn(heap, child, key, hash32, shift + branch_bits, elementEq)) orelse return null) {
                .node => |c| .{ .node = try withSlot(heap, node, slot, .{ .child = c }) },
                // A node whose only content was that child would hold
                // the lone payload itself: it passes further up.
                .single => |p| if (shift > 0 and hdr.data_bitmap == 0 and @popCount(hdr.node_bitmap) == 1)
                    .{ .single = p }
                else
                    .{ .node = try withSlot(heap, node, slot, .{ .data = p }) },
            };
        }

        const Slot = union(enum) { empty, data: P, child: *HeapHeader };

        /// A copy of interior `src` with `slot` holding `new`: the one
        /// path-copy primitive every insert and remove goes through.
        inline fn withSlot(heap: *Heap, src: *HeapHeader, slot: u32, new: Slot) !*HeapHeader {
            const hdr = headerOf(InteriorHeader, src).*;
            const bit = bitOf(slot);
            var data = hdr.data_bitmap & ~bit;
            var nodes = hdr.node_bitmap & ~bit;
            switch (new) {
                .empty => {},
                .data => data |= bit,
                .child => nodes |= bit,
            }
            const h = try allocInterior(heap, data, nodes);
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

        // ---- bulk construction ----

        const Item = struct {
            p: P,
            hash: u32,
            /// Input position: equal hashes keep it (a collision node
            /// is in association order).
            order: u32,

            /// Orders by the hash's slot on level 0, then level 1, and
            /// so on, so every subtree's keys are contiguous; equal
            /// hashes keep input order.
            fn lessThan(_: void, a: Item, b: Item) bool {
                const ra = @bitReverse(a.hash);
                const rb = @bitReverse(b.hash);
                return ra < rb or (ra == rb and a.order < b.order);
            }
        };

        /// The canonical node at `shift` holding `items`, which are
        /// sorted by `Item.lessThan`, have distinct keys, and share
        /// the hash bits below `shift`; at least two below the root.
        /// One allocation per node.
        fn build(heap: *Heap, items: []const Item, shift: u8) !*HeapHeader {
            if (shift > MAX_TRIE_SHIFT) {
                const h = try allocCollision(heap, items[0].hash, items.len);
                for (collisionPayloads(h), items) |*dst, item| dst.* = item.p;
                return h;
            }
            var data: u32 = 0;
            var nodes: u32 = 0;
            var i: usize = 0;
            while (i < items.len) {
                const slot = slotOf(items[i].hash, shift);
                const j = runEnd(items, i, shift);
                if (j - i == 1) data |= bitOf(slot) else nodes |= bitOf(slot);
                i = j;
            }
            const h = try allocInterior(heap, data, nodes);
            i = 0;
            while (i < items.len) {
                const slot = slotOf(items[i].hash, shift);
                const j = runEnd(items, i, shift);
                if (j - i == 1) {
                    payloads(h)[dataIndex(data, slot)] = items[i].p;
                } else {
                    children(h)[childIndex(nodes, slot)] = try build(heap, items[i..j], shift + branch_bits);
                }
                i = j;
            }
            return h;
        }

        fn runEnd(items: []const Item, start: usize, shift: u8) usize {
            const slot = slotOf(items[start].hash, shift);
            var j = start + 1;
            while (j < items.len and slotOf(items[j].hash, shift) == slot) j += 1;
            return j;
        }

        /// The map or set of `ps`, as a left fold of `insert` from empty
        /// would build it (a later payload with an equal key replaces
        /// the value, keeping the first key), built bottom-up with one
        /// allocation per node.
        fn fromSlice(heap: *Heap, ps: []const P, elementHash: ElementHash, elementEq: ElementEq) !Value {
            const items = try heap.backing.alloc(Item, ps.len);
            defer heap.backing.free(items);
            for (ps, items, 0..) |p, *item, i| item.* = .{ .p = p, .hash = indexHashOf(keyOf(p), elementHash), .order = @intCast(i) };
            std.mem.sortUnstable(Item, items, {}, Item.lessThan);
            // Merge equal keys; they share a hash, so they are adjacent.
            var n: usize = 0;
            var i: usize = 0;
            while (i < items.len) {
                const run = n;
                var j = i;
                while (j < items.len and items[j].hash == items[i].hash) : (j += 1) {
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
                        return a.order < b.order;
                    }
                }.byOrder);
                const h = try allocArray(heap, n);
                for (arrayPayloads(h), items[0..n]) |*dst, item| dst.* = item.p;
                return valueOf(h, subkind_array_map);
            }
            return newRoot(heap, n, try build(heap, items[0..n], 0));
        }

        // ---- dispatch entry points ----

        /// The pre-domain-mix hash (CHAMP.md §7): an unordered combine
        /// of payload hashes, cached in the root header at u32
        /// precision (§7.5).
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

        /// Semantic equality (CHAMP.md §6.3): equal counts, and every
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
        /// §4.3) except inside collision nodes.
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
                visitor.markValue(p.key);
                visitor.markValue(p.value);
            } else visitor.markValue(p);
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
inline fn entryHash(e: Entry, elementHash: ElementHash) u64 {
    var acc: u64 = hash_mod.ordered_init;
    acc = hash_mod.combineOrdered(acc, elementHash(e.key));
    acc = hash_mod.combineOrdered(acc, elementHash(e.value));
    return acc;
}

// =============================================================================
// Public API — map (CHAMP.md §8)
// =============================================================================

/// A fresh empty map: a zero-entry array-map, not a shared singleton.
pub fn mapEmpty(heap: *Heap) !Value {
    return MapTrie.empty(heap);
}

/// The map of `entries`; a later entry with an equal key wins
/// (CHAMP.md §8.1). Built bottom-up: one allocation per node.
pub fn mapFromEntries(heap: *Heap, entries: []const Entry, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return MapTrie.fromSlice(heap, entries, elementHash, elementEq);
}

pub fn mapCount(m: Value) usize {
    return MapTrie.count(m);
}

pub fn mapGet(m: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) MapLookup {
    const e = MapTrie.find(m, key, elementHash, elementEq) orelse return .absent;
    return .{ .present = e.value };
}

/// `m` with `key → val` (CHAMP.md §8.1). Returns `m` itself when the
/// key already maps to a bit-identical value; a replaced value keeps
/// the original key object.
pub fn mapAssoc(heap: *Heap, m: Value, key: Value, val: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return MapTrie.insert(heap, m, .{ .key = key, .value = val }, elementHash, elementEq);
}

/// `m` without `key`; `m` itself when the key is absent (CHAMP.md
/// §5.4-§5.6, §8.1).
pub fn mapDissoc(heap: *Heap, m: Value, key: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return MapTrie.remove(heap, m, key, elementHash, elementEq);
}

pub const MapIter = MapTrie.Iter;

pub fn mapIter(m: Value) MapIter {
    return MapIter.init(m);
}

/// A user-facing map Value for a root header (TRANSIENT.md §8), its
/// subkind read off the body size.
pub fn valueFromMapHeader(h: *HeapHeader) Value {
    return MapTrie.fromHeader(h);
}

// =============================================================================
// Public API — set
// =============================================================================

/// A fresh empty set: a zero-element array-set.
pub fn setEmpty(heap: *Heap) !Value {
    return SetTrie.empty(heap);
}

/// The set of `elems`, duplicates merged. Built bottom-up.
pub fn setFromElements(heap: *Heap, elems: []const Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return SetTrie.fromSlice(heap, elems, elementHash, elementEq);
}

pub fn setCount(s: Value) usize {
    return SetTrie.count(s);
}

pub fn setContains(s: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) bool {
    return SetTrie.find(s, elem, elementHash, elementEq) != null;
}

/// `s` with `elem`; `s` itself when `elem` is already present.
pub fn setConj(heap: *Heap, s: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return SetTrie.insert(heap, s, elem, elementHash, elementEq);
}

/// `s` without `elem`; `s` itself when `elem` is absent.
pub fn setDisj(heap: *Heap, s: Value, elem: Value, elementHash: ElementHash, elementEq: ElementEq) !Value {
    return SetTrie.remove(heap, s, elem, elementHash, elementEq);
}

pub const SetIter = SetTrie.Iter;

pub fn setIter(s: Value) SetIter {
    return SetIter.init(s);
}

pub fn valueFromSetHeader(h: *HeapHeader) Value {
    return SetTrie.fromHeader(h);
}

// =============================================================================
// Dispatch and GC entry points (CHAMP.md §9, GC.md §5)
// =============================================================================

/// Pre-domain-mix hash of a map root; `dispatch.hashValue` applies the
/// `0xF1` domain mix.
pub fn hashMap(h: *HeapHeader, elementHash: ElementHash) u64 {
    return MapTrie.hashOf(h, elementHash);
}

/// Pre-domain-mix hash of a set root (domain byte `0xF2`).
pub fn hashSet(h: *HeapHeader, elementHash: ElementHash) u64 {
    return SetTrie.hashOf(h, elementHash);
}

pub fn equalMap(a: *HeapHeader, b: *HeapHeader, elementHash: ElementHash, elementEq: ElementEq) bool {
    return MapTrie.equal(a, b, elementHash, elementEq);
}

pub fn equalSet(a: *HeapHeader, b: *HeapHeader, elementHash: ElementHash, elementEq: ElementEq) bool {
    return SetTrie.equal(a, b, elementHash, elementEq);
}

pub fn traceMap(h: *HeapHeader, visitor: anytype) void {
    MapTrie.trace(h, visitor);
}

pub fn traceSet(h: *HeapHeader, visitor: anytype) void {
    SetTrie.trace(h, visitor);
}

// =============================================================================
// Trie introspection for tests (CHAMP.md §4.3, §12.3)
// =============================================================================

/// The entry count of the collision node holding every key of `m`
/// whose indexing hash is `hash32`, or `null` when no such node exists
/// (an array-map, or a descent that ends above the collision layer).
/// A collision fixture asserts through this that its keys reached the
/// collision node.
pub fn mapCollisionCount(m: Value, hash32: u32) ?u32 {
    return MapTrie.collisionCount(m, hash32);
}

pub fn setCollisionCount(s: Value, hash32: u32) ?u32 {
    return SetTrie.collisionCount(s, hash32);
}

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

/// Hash-colliding synthetic for collision-node tests: the low 32
/// bits are pinned to `0xDEAD_BEEF` for every key, the high 32 bits
/// are the key's own content hash.
///
/// The keys are heap strings from `collidingKey`, never immediates:
/// `indexHashOf` (§5.1) hashes an immediate key inline and consults
/// `elementHash` for heap keys only, so a keyword or fixnum key would
/// never see this function and the trie would partition the keys
/// cleanly instead of colliding them. Each collision test asserts
/// through `mapCollisionCount` / `setCollisionCount` that its keys
/// did reach the collision node.
///
/// Why the low 32 bits are the pinned half: `indexHashOf` truncates
/// to them. Pinning the high half instead would not collide. The high
/// half stays input-dependent because the same callback hashes the
/// map's own entries when a colliding-keyed map is itself hashed,
/// and distinct entries must keep distinct hashes there.
fn collidingHash(x: Value) u64 {
    return (@as(u64, string_mod.hashHeader(Heap.asHeapHeader(x))) << 32) | 0xDEAD_BEEF;
}

/// The `i`-th key of a collision fixture: a fresh heap string, so the
/// indexing hash goes through the `elementHash` callback (§5.1).
/// Equal by content under `synthEq`, so any call with the same `i`
/// names the same key.
fn collidingKey(heap: *Heap, i: u32) !Value {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "collider-{d}", .{i}) catch unreachable;
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

test "mapEmpty: subkind 0, count 0, isEmpty true" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try mapEmpty(&heap);
    try testing.expectEqual(Kind.persistent_map, m.kind());
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 0), mapCount(m));
    try testing.expectEqual(@as(usize, 0), mapCount(m));
}

test "mapEmpty: each call allocates a fresh header (not a shared singleton)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try mapEmpty(&heap);
    const b = try mapEmpty(&heap);
    try testing.expect(Heap.asHeapHeader(a) != Heap.asHeapHeader(b));
}

// ---- Array-map assoc / get / dissoc ----

test "array-map assoc + get: single key round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const key = value.fromKeywordId(1);
    const val = value.fromFixnum(42).?;
    const m1 = try mapAssoc(&heap, m0, key, val, &synthHash, &synthEq);
    try testing.expectEqual(subkind_array_map, m1.subkind());
    try testing.expectEqual(@as(usize, 1), mapCount(m1));
    const lookup = mapGet(m1, key, &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expectEqual(@as(i64, 42), v.asFixnum()),
        .absent => try testing.expect(false),
    }
    // Absence round-trip.
    const miss = mapGet(m1, value.fromKeywordId(999), &synthHash, &synthEq);
    try testing.expect(miss == .absent);
}

test "array-map: mapCount correctly tracks 0..8" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        const k = value.fromKeywordId(i);
        const v = value.fromFixnum(@intCast(i)).?;
        m = try mapAssoc(&heap, m, k, v, &synthHash, &synthEq);
        try testing.expectEqual(@as(usize, i + 1), mapCount(m));
        try testing.expectEqual(subkind_array_map, m.subkind());
    }
}

test "array-map: same-value assoc returns same pointer (short-circuit)" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const k = value.fromKeywordId(1);
    const v = value.fromFixnum(42).?;
    const m1 = try mapAssoc(&heap, m0, k, v, &synthHash, &synthEq);
    const m2 = try mapAssoc(&heap, m1, k, v, &synthHash, &synthEq);
    try testing.expect(Heap.asHeapHeader(m1) == Heap.asHeapHeader(m2));
}

test "array-map: different-value assoc replaces value, count unchanged" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const k = value.fromKeywordId(1);
    const v1 = value.fromFixnum(1).?;
    const v2 = value.fromFixnum(2).?;
    const m1 = try mapAssoc(&heap, m0, k, v1, &synthHash, &synthEq);
    const m2 = try mapAssoc(&heap, m1, k, v2, &synthHash, &synthEq);
    try testing.expect(Heap.asHeapHeader(m1) != Heap.asHeapHeader(m2));
    try testing.expectEqual(@as(usize, 1), mapCount(m2));
    switch (mapGet(m2, k, &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 2), v.asFixnum()),
        .absent => try testing.expect(false),
    }
    // Original still has v1.
    switch (mapGet(m1, k, &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 1), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "array-map dissoc: absent key returns same pointer" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const k = value.fromKeywordId(1);
    const v = value.fromFixnum(42).?;
    const m1 = try mapAssoc(&heap, m0, k, v, &synthHash, &synthEq);
    const m2 = try mapDissoc(&heap, m1, value.fromKeywordId(999), &synthHash, &synthEq);
    try testing.expect(Heap.asHeapHeader(m1) == Heap.asHeapHeader(m2));
}

test "array-map dissoc: present key shrinks count by 1" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    m = try mapDissoc(&heap, m, value.fromKeywordId(2), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 4), mapCount(m));
    try testing.expect(mapGet(m, value.fromKeywordId(2), &synthHash, &synthEq) == .absent);
    switch (mapGet(m, value.fromKeywordId(0), &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 0), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

// ---- Nil key / nil value legality ----

test "nil is a legal map value — MapLookup distinguishes absent from present-with-nil" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const k = value.fromKeywordId(1);
    const m1 = try mapAssoc(&heap, m0, k, value.nilValue(), &synthHash, &synthEq);
    const lookup = mapGet(m1, k, &synthHash, &synthEq);
    switch (lookup) {
        .present => |v| try testing.expect(v.isNil()),
        .absent => try testing.expect(false),
    }
    // Absent key still returns .absent.
    try testing.expect(mapGet(m1, value.fromKeywordId(999), &synthHash, &synthEq) == .absent);
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
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 8), mapCount(m));
    // Ninth distinct key triggers promotion.
    m = try mapAssoc(&heap, m, value.fromKeywordId(100), value.fromFixnum(100).?, &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, m.subkind());
    try testing.expectEqual(@as(usize, 9), mapCount(m));
    // All nine keys must be retrievable.
    i = 0;
    while (i < 8) : (i += 1) {
        switch (mapGet(m, value.fromKeywordId(i), &synthHash, &synthEq)) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
    switch (mapGet(m, value.fromKeywordId(100), &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 100), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "promotion: duplicate assoc at count 8 does NOT promote" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    // Associng an existing key with a new value must NOT promote.
    m = try mapAssoc(&heap, m, value.fromKeywordId(3), value.fromFixnum(999).?, &synthHash, &synthEq);
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 8), mapCount(m));
}

test "no demotion: dissoc from CHAMP back to 8 entries stays CHAMP" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_champ_root, m.subkind());
    m = try mapDissoc(&heap, m, value.fromKeywordId(0), &synthHash, &synthEq);
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
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    i = 0;
    while (i < 9) : (i += 1) {
        m = try mapDissoc(&heap, m, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 0), mapCount(m));
    try testing.expectEqual(subkind_array_map, m.subkind());
}

// ---- Persistent immutability ----

test "persistent: assoc does not mutate source" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const m1 = try mapAssoc(&heap, m0, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    _ = try mapAssoc(&heap, m1, value.fromKeywordId(2), value.fromFixnum(2).?, &synthHash, &synthEq);
    // m1 must still have just one entry.
    try testing.expectEqual(@as(usize, 1), mapCount(m1));
    try testing.expect(mapGet(m1, value.fromKeywordId(2), &synthHash, &synthEq) == .absent);
}

test "persistent: dissoc does not mutate source" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const m1 = try mapAssoc(&heap, m0, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    const m2 = try mapAssoc(&heap, m1, value.fromKeywordId(2), value.fromFixnum(2).?, &synthHash, &synthEq);
    _ = try mapDissoc(&heap, m2, value.fromKeywordId(1), &synthHash, &synthEq);
    // m2 must still have both keys.
    try testing.expectEqual(@as(usize, 2), mapCount(m2));
    switch (mapGet(m2, value.fromKeywordId(1), &synthHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 1), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

// ---- Duplicate-key canonicalization in fromEntries ----

test "mapFromEntries: later wins on duplicate keys; count reflects unique" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const k = value.fromKeywordId(1);
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

// ---- Hash consistency ----

test "hashMap: equal maps hash equally regardless of insertion order" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const kvs = [_]Entry{
        .{ .key = value.fromKeywordId(1), .value = value.fromFixnum(10).? },
        .{ .key = value.fromKeywordId(2), .value = value.fromFixnum(20).? },
        .{ .key = value.fromKeywordId(3), .value = value.fromFixnum(30).? },
    };
    var m_abc = try mapEmpty(&heap);
    for (kvs) |e| m_abc = try mapAssoc(&heap, m_abc, e.key, e.value, &synthHash, &synthEq);
    var m_cba = try mapEmpty(&heap);
    var i: usize = kvs.len;
    while (i > 0) {
        i -= 1;
        m_cba = try mapAssoc(&heap, m_cba, kvs[i].key, kvs[i].value, &synthHash, &synthEq);
    }
    const h_abc = hashMap(Heap.asHeapHeader(m_abc), &synthHash);
    const h_cba = hashMap(Heap.asHeapHeader(m_cba), &synthHash);
    try testing.expectEqual(h_abc, h_cba);
}

test "hashMap: empty map hash is deterministic and distinct from one-entry map" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m0 = try mapEmpty(&heap);
    const m1 = try mapAssoc(&heap, m0, value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    const h0 = hashMap(Heap.asHeapHeader(m0), &synthHash);
    const h1 = hashMap(Heap.asHeapHeader(m1), &synthHash);
    try testing.expect(h0 != h1);
    // Recompute to verify cache stability.
    try testing.expectEqual(h0, hashMap(Heap.asHeapHeader(m0), &synthHash));
    try testing.expectEqual(h1, hashMap(Heap.asHeapHeader(m1), &synthHash));
}

// ---- Equality ----

test "equalMap: reflexive, symmetric, transitive" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const kvs = [_]Entry{
        .{ .key = value.fromKeywordId(1), .value = value.fromFixnum(10).? },
        .{ .key = value.fromKeywordId(2), .value = value.fromFixnum(20).? },
    };
    var a = try mapEmpty(&heap);
    var b = try mapEmpty(&heap);
    var c = try mapEmpty(&heap);
    for (kvs) |e| {
        a = try mapAssoc(&heap, a, e.key, e.value, &synthHash, &synthEq);
        b = try mapAssoc(&heap, b, e.key, e.value, &synthHash, &synthEq);
        c = try mapAssoc(&heap, c, e.key, e.value, &synthHash, &synthEq);
    }
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    const ch = Heap.asHeapHeader(c);
    try testing.expect(equalMap(ah, ah, &synthHash, &synthEq));
    try testing.expect(equalMap(ah, bh, &synthHash, &synthEq));
    try testing.expect(equalMap(bh, ah, &synthHash, &synthEq));
    try testing.expect(equalMap(ah, ch, &synthHash, &synthEq) and equalMap(bh, ch, &synthHash, &synthEq));
}

test "equalMap: different count breaks equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try mapAssoc(&heap, try mapEmpty(&heap), value.fromKeywordId(1), value.fromFixnum(1).?, &synthHash, &synthEq);
    const b = try mapAssoc(&heap, a, value.fromKeywordId(2), value.fromFixnum(2).?, &synthHash, &synthEq);
    try testing.expect(!equalMap(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &synthHash, &synthEq));
}

test "equalMap: different value breaks equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const k = value.fromKeywordId(1);
    const a = try mapAssoc(&heap, try mapEmpty(&heap), k, value.fromFixnum(1).?, &synthHash, &synthEq);
    const b = try mapAssoc(&heap, try mapEmpty(&heap), k, value.fromFixnum(2).?, &synthHash, &synthEq);
    try testing.expect(!equalMap(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &synthHash, &synthEq));
}

// ---- Cross-subkind equality (§6.4) ----

test "cross-subkind: array-map and CHAMP holding same entries compare equal" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Build an 8-entry array-map.
    var am = try mapEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        am = try mapAssoc(&heap, am, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_array_map, am.subkind());
    // Build a CHAMP that has the same 8 entries: grow to 9 then dissoc one.
    var ch = am;
    ch = try mapAssoc(&heap, ch, value.fromKeywordId(100), value.fromFixnum(100).?, &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, ch.subkind());
    ch = try mapDissoc(&heap, ch, value.fromKeywordId(100), &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, ch.subkind()); // no demote
    // am (array-map) and ch (CHAMP) hold the same 8 entries.
    try testing.expectEqual(mapCount(am), mapCount(ch));
    try testing.expect(equalMap(Heap.asHeapHeader(am), Heap.asHeapHeader(ch), &synthHash, &synthEq));
    // Hash must agree too.
    try testing.expectEqual(
        hashMap(Heap.asHeapHeader(am), &synthHash),
        hashMap(Heap.asHeapHeader(ch), &synthHash),
    );
}

// ---- Collision-node stress via colliding synthetic hash ----

test "collision nodes: many keys with the same indexing hash survive the trie" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var m = try mapEmpty(&heap);
    // Insert 10 distinct string keys: with `collidingHash` the low 32
    // bits are always `0xDEAD_BEEF`, so every key descends the same
    // path and lands in one collision node at MAX_TRIE_SHIFT.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        m = try mapAssoc(&heap, m, try collidingKey(&heap, i), value.fromFixnum(@intCast(i)).?, &collidingHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 10), mapCount(m));
    try testing.expectEqual(@as(?u32, 10), mapCollisionCount(m, 0xDEAD_BEEF));
    // Every key must still look up correctly.
    i = 0;
    while (i < 10) : (i += 1) {
        switch (mapGet(m, try collidingKey(&heap, i), &collidingHash, &synthEq)) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
    // Dissoc from the collision bucket works end-to-end.
    m = try mapDissoc(&heap, m, try collidingKey(&heap, 5), &collidingHash, &synthEq);
    try testing.expectEqual(@as(usize, 9), mapCount(m));
    try testing.expectEqual(@as(?u32, 9), mapCollisionCount(m, 0xDEAD_BEEF));
    try testing.expect(mapGet(m, try collidingKey(&heap, 5), &collidingHash, &synthEq) == .absent);
    // Other keys still present.
    switch (mapGet(m, try collidingKey(&heap, 3), &collidingHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 3), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

test "collision nodes: an immediate key hashes inline and never reaches the callback" {
    // The counterpart of the stress test: keyword keys under the same
    // `collidingHash`-shaped callback partition cleanly, because
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
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &pinned.f, &synthEq);
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
    const a = value.fromKeywordId(42);
    const b = value.fromKeywordId(42);
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
    try testing.expect(!keyEquivalent(value.fromKeywordId(1), value.fromKeywordId(2), &wrapEq.f));
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
        m = try mapAssoc(&heap, m, value.fromKeywordId(i + 200), value.fromFixnum(@intCast(i)).?, &twoColliders.f, &synthEq);
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
// live in test/prop/champ.zig (S1..S6).
// =============================================================================

test "setEmpty: subkind 0, count 0, isEmpty true" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try setEmpty(&heap);
    try testing.expectEqual(Kind.persistent_set, s.kind());
    try testing.expectEqual(subkind_array_map, s.subkind());
    try testing.expectEqual(@as(usize, 0), setCount(s));
    try testing.expectEqual(@as(usize, 0), setCount(s));
}

test "set: conj + contains single element round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s0 = try setEmpty(&heap);
    const e = value.fromKeywordId(1);
    const s1 = try setConj(&heap, s0, e, &synthHash, &synthEq);
    try testing.expectEqual(subkind_array_map, s1.subkind());
    try testing.expectEqual(@as(usize, 1), setCount(s1));
    try testing.expect(setContains(s1, e, &synthHash, &synthEq));
    try testing.expect(!setContains(s1, value.fromKeywordId(999), &synthHash, &synthEq));
}

test "set: conj of existing element returns same pointer" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s0 = try setEmpty(&heap);
    const e = value.fromKeywordId(1);
    const s1 = try setConj(&heap, s0, e, &synthHash, &synthEq);
    const s2 = try setConj(&heap, s1, e, &synthHash, &synthEq);
    try testing.expect(Heap.asHeapHeader(s1) == Heap.asHeapHeader(s2));
}

test "set: array-set count 0..8 without promotion" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try setEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        s = try setConj(&heap, s, value.fromKeywordId(i), &synthHash, &synthEq);
        try testing.expectEqual(@as(usize, i + 1), setCount(s));
        try testing.expectEqual(subkind_array_map, s.subkind());
    }
}

test "set: promotion at count 8→9 → CHAMP, no demotion on disj back to 8" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try setEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        s = try setConj(&heap, s, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_array_map, s.subkind());
    s = try setConj(&heap, s, value.fromKeywordId(100), &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, s.subkind());
    try testing.expectEqual(@as(usize, 9), setCount(s));
    // Every element must still be findable.
    i = 0;
    while (i < 8) : (i += 1) {
        try testing.expect(setContains(s, value.fromKeywordId(i), &synthHash, &synthEq));
    }
    try testing.expect(setContains(s, value.fromKeywordId(100), &synthHash, &synthEq));
    // Dissoc back to 8 — must stay CHAMP (no demotion).
    s = try setDisj(&heap, s, value.fromKeywordId(100), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 8), setCount(s));
    try testing.expectEqual(subkind_champ_root, s.subkind());
}

test "set: disj of absent element returns same pointer" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s0 = try setEmpty(&heap);
    const s1 = try setConj(&heap, s0, value.fromKeywordId(1), &synthHash, &synthEq);
    const s2 = try setDisj(&heap, s1, value.fromKeywordId(999), &synthHash, &synthEq);
    try testing.expect(Heap.asHeapHeader(s1) == Heap.asHeapHeader(s2));
}

test "set: disj all elements from CHAMP returns fresh subkind-0 empty set" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try setEmpty(&heap);
    var i: u32 = 0;
    while (i < 9) : (i += 1) {
        s = try setConj(&heap, s, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    i = 0;
    while (i < 9) : (i += 1) {
        s = try setDisj(&heap, s, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 0), setCount(s));
    try testing.expectEqual(subkind_array_map, s.subkind());
}

test "set: nil is a legal element" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try setConj(&heap, try setEmpty(&heap), value.nilValue(), &synthHash, &synthEq);
    try testing.expect(setContains(s, value.nilValue(), &synthHash, &synthEq));
    try testing.expect(!setContains(s, value.fromFixnum(0).?, &synthHash, &synthEq));
}

test "set: persistent immutability on conj" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s0 = try setEmpty(&heap);
    const s1 = try setConj(&heap, s0, value.fromKeywordId(1), &synthHash, &synthEq);
    _ = try setConj(&heap, s1, value.fromKeywordId(2), &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 1), setCount(s1));
    try testing.expect(!setContains(s1, value.fromKeywordId(2), &synthHash, &synthEq));
}

test "set: setFromElements deduplicates naturally" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromKeywordId(1),
        value.fromKeywordId(2),
        value.fromKeywordId(1),
        value.fromKeywordId(2),
        value.fromKeywordId(3),
    };
    const s = try setFromElements(&heap, &elems, &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 3), setCount(s));
    try testing.expect(setContains(s, value.fromKeywordId(1), &synthHash, &synthEq));
    try testing.expect(setContains(s, value.fromKeywordId(2), &synthHash, &synthEq));
    try testing.expect(setContains(s, value.fromKeywordId(3), &synthHash, &synthEq));
}

test "hashSet: insertion-order-independent" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const elems = [_]Value{
        value.fromKeywordId(1),
        value.fromKeywordId(2),
        value.fromKeywordId(3),
    };
    var s_abc = try setEmpty(&heap);
    for (elems) |e| s_abc = try setConj(&heap, s_abc, e, &synthHash, &synthEq);
    var s_cba = try setEmpty(&heap);
    var i: usize = elems.len;
    while (i > 0) {
        i -= 1;
        s_cba = try setConj(&heap, s_cba, elems[i], &synthHash, &synthEq);
    }
    try testing.expectEqual(
        hashSet(Heap.asHeapHeader(s_abc), &synthHash),
        hashSet(Heap.asHeapHeader(s_cba), &synthHash),
    );
}

test "equalSet: reflexive, cross-subkind equivalence" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    // Build an 8-element array-set and a CHAMP set holding the same
    // 8 elements (via grow-to-9-then-disj). Equality must recognize
    // them as equal despite different subkinds.
    var a = try setEmpty(&heap);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        a = try setConj(&heap, a, value.fromKeywordId(i), &synthHash, &synthEq);
    }
    try testing.expectEqual(subkind_array_map, a.subkind());
    var b = a;
    b = try setConj(&heap, b, value.fromKeywordId(100), &synthHash, &synthEq);
    b = try setDisj(&heap, b, value.fromKeywordId(100), &synthHash, &synthEq);
    try testing.expectEqual(subkind_champ_root, b.subkind());
    try testing.expect(equalSet(Heap.asHeapHeader(a), Heap.asHeapHeader(b), &synthHash, &synthEq));
    try testing.expectEqual(
        hashSet(Heap.asHeapHeader(a), &synthHash),
        hashSet(Heap.asHeapHeader(b), &synthHash),
    );
}

test "set: collision-node stress with colliding fixture" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var s = try setEmpty(&heap);
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        s = try setConj(&heap, s, try collidingKey(&heap, i), &collidingHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 10), setCount(s));
    try testing.expectEqual(@as(?u32, 10), setCollisionCount(s, 0xDEAD_BEEF));
    i = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(setContains(s, try collidingKey(&heap, i), &collidingHash, &synthEq));
    }
    // Disj alternating elements.
    s = try setDisj(&heap, s, try collidingKey(&heap, 0), &collidingHash, &synthEq);
    s = try setDisj(&heap, s, try collidingKey(&heap, 5), &collidingHash, &synthEq);
    try testing.expectEqual(@as(usize, 8), setCount(s));
    try testing.expectEqual(@as(?u32, 8), setCollisionCount(s, 0xDEAD_BEEF));
    try testing.expect(!setContains(s, try collidingKey(&heap, 0), &collidingHash, &synthEq));
    try testing.expect(!setContains(s, try collidingKey(&heap, 5), &collidingHash, &synthEq));
    try testing.expect(setContains(s, try collidingKey(&heap, 3), &collidingHash, &synthEq));
}
