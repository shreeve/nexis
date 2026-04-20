//! coll/hamt.zig — persistent map heap kind (Phase 1, commit 1).
//!
//! Authoritative spec: `docs/CHAMP.md`. Semantic framing:
//! `docs/SEMANTICS.md` §2.6 (associative equality category) and §3.2
//! (associative-domain hash byte `0xF1`, map entry-hash formula as
//! amended 2026-04-19). Physical storage: `docs/HEAP.md`. Representation
//! choices: `docs/VALUE.md` §2.2 (extended subkind taxonomy for
//! `persistent_map` — four subkinds 0..3).
//!
//! **Commit 1 of two: map only.** `persistent_set` ships in commit 2 as
//! a parallel subkind family sharing this module's machinery. The set
//! public API surface is not present in this file yet.
//!
//! ## Subkind taxonomy
//!
//!   - 0 = array-map (inline ≤ 8 entries; user-facing)
//!   - 1 = CHAMP root (count + pointer to root node; user-facing)
//!   - 2 = CHAMP interior node (two 32-bit bitmaps + compact payload;
//!     internal, never escapes as a user-visible Value)
//!   - 3 = collision node (shared 32-bit indexing hash + entries;
//!     internal)
//!
//! Top-level `persistent_map` Values are ONLY subkinds 0 or 1. Subkinds
//! 2/3 are heap-internal and asserted against at every dispatch entry
//! point.
//!
//! ## Dispatch plumbing (one-way terminal)
//!
//! This module does NOT import `dispatch.zig` (the established
//! one-way-terminal rule — see `docs/CHAMP.md` §9 + `src/dispatch.zig`'s
//! module-level comment). Every operation that needs to hash or
//! compare an arbitrary Value takes a fn-pointer callback
//! (`elementHash: *const fn (Value) u64`,
//!  `elementEq: *const fn (Value, Value) bool`). The dispatcher wires
//! `&dispatch.hashValue` and `&dispatch.equal` into each call at the
//! `persistent_map` kind switch.
//!
//! ## Scope (commit 1)
//!
//!   - construction: `mapEmpty`, `mapFromEntries`
//!   - mutation (persistent): `mapAssoc`, `mapDissoc`
//!   - query: `mapGet` (returns `MapLookup` union, nil-safe),
//!     `mapCount`, `mapIsEmpty`
//!   - dispatch entry points: `hashMap`, `equalMap`
//!   - iterator: `MapIter` for hash accumulation + future `seq`
//!   - promotion: array-map → CHAMP at count=9; no demotion
//!   - single-entry-subtree promotion on dissoc (preserves canonicality)
//!   - keyword-keyed identity fast path in every equality call site
//!
//! ## Deferred (commit 2 and beyond)
//!
//!   - `persistent_set` kind (commit 2)
//!   - transients (separate `src/coll/transient.zig` commit)
//!   - `merge` / `update` / stdlib operators (Phase 3)

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
// Constants (CHAMP.md §5)
// =============================================================================

pub const branch_bits: u5 = 5;
pub const branch_factor: usize = 1 << branch_bits; // 32
pub const branch_mask: u32 = @as(u32, branch_factor) - 1; // 0x1F

/// Shift at the deepest interior level. Levels 0..5 consume 5 bits each
/// (30 total); level 6 consumes the remaining 2 bits (`shift == 30`).
/// Any attempt to descend further triggers collision-node creation.
///
/// Typed `u8` (not `u5`) so recursive helpers can carry transient
/// values up to `MAX_TRIE_SHIFT + branch_bits = 35` as "past-the-trie"
/// sentinels without overflowing. Narrowed to u5 only at the `>> shift`
/// site where the actual 5-bit shift amount is required.
pub const MAX_TRIE_SHIFT: u8 = 30;

/// Total trie levels before collision (levels 0..6 inclusive).
pub const COLLISION_DEPTH: u8 = 7;

/// Promotion threshold: array-map supports 0..array_map_max entries;
/// the (array_map_max + 1)-th `assoc` with a new key promotes to CHAMP.
pub const array_map_max: u32 = 8;

// =============================================================================
// Subkind discriminators (VALUE.md §2.2 amended; CHAMP.md §3)
// =============================================================================

pub const subkind_array_map: u16 = 0;
pub const subkind_champ_root: u16 = 1;
pub const subkind_champ_interior: u16 = 2;
pub const subkind_champ_collision: u16 = 3;

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
/// "present with nil value" (CHAMP.md §6.6); this union makes the
/// distinction explicit.
pub const MapLookup = union(enum) {
    absent,
    present: Value,
};

// =============================================================================
// Body layouts (CHAMP.md §4)
// =============================================================================

/// Header of an array-map body. Followed immediately by `count`
/// `Entry` structs — no padding, no length prefix beyond `count`.
const ArrayMapBody = extern struct {
    count: u32,
    _pad: u32,

    comptime {
        std.debug.assert(@sizeOf(ArrayMapBody) == 8);
        std.debug.assert(@alignOf(ArrayMapBody) == 4);
    }
};

/// CHAMP-backed root. Always points at a subkind-2 (interior) or
/// subkind-3 (collision) node; `root_node` is NEVER null at this
/// subkind.
const ChampRootBody = extern struct {
    count: u32,
    _pad: u32,
    root_node: *HeapHeader,

    comptime {
        std.debug.assert(@sizeOf(ChampRootBody) == 16);
        std.debug.assert(@offsetOf(ChampRootBody, "root_node") == 8);
    }
};

/// Header of a CHAMP interior node body. Followed by
/// `popCount(data_bitmap)` entries, then `popCount(node_bitmap)` child
/// pointers. Invariant: `data_bitmap & node_bitmap == 0`.
const ChampInteriorHeader = extern struct {
    data_bitmap: u32,
    node_bitmap: u32,

    comptime {
        std.debug.assert(@sizeOf(ChampInteriorHeader) == 8);
    }
};

/// Header of a collision-node body. Followed by `count` entries, all of
/// which share the same 32-bit `shared_hash`. `count >= 2`.
const ChampCollisionHeader = extern struct {
    shared_hash: u32,
    count: u32,

    comptime {
        std.debug.assert(@sizeOf(ChampCollisionHeader) == 8);
    }
};

// =============================================================================
// Allocation helpers — one per subkind.
//
// Every path goes through `heap.alloc(.persistent_map, body_size)`, so
// GC will see these blocks on the live list.
// =============================================================================

fn allocArrayMap(heap: *Heap, n: u32) !*HeapHeader {
    std.debug.assert(n <= array_map_max);
    const body_size = @sizeOf(ArrayMapBody) + @as(usize, n) * @sizeOf(Entry);
    return heap.alloc(.persistent_map, body_size);
}

fn allocChampRoot(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_map, @sizeOf(ChampRootBody));
}

fn allocChampInterior(heap: *Heap, entry_count: u32, child_count: u32) !*HeapHeader {
    const entry_bytes = @as(usize, entry_count) * @sizeOf(Entry);
    const child_bytes = @as(usize, child_count) * @sizeOf(*HeapHeader);
    const body_size = @sizeOf(ChampInteriorHeader) + entry_bytes + child_bytes;
    return heap.alloc(.persistent_map, body_size);
}

fn allocCollision(heap: *Heap, n: u32) !*HeapHeader {
    std.debug.assert(n >= 2);
    const body_size = @sizeOf(ChampCollisionHeader) + @as(usize, n) * @sizeOf(Entry);
    return heap.alloc(.persistent_map, body_size);
}

// =============================================================================
// Body accessors — typed views over the zero-prefixed bytes.
// =============================================================================

fn arrayMapBody(h: *HeapHeader) *ArrayMapBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(ArrayMapBody));
    return @ptrCast(@alignCast(body.ptr));
}

fn arrayMapBodyConst(h: *HeapHeader) *const ArrayMapBody {
    return arrayMapBody(h);
}

fn arrayMapEntries(h: *HeapHeader) []Entry {
    const body = Heap.bodyBytes(h);
    const n = arrayMapBodyConst(h).count;
    std.debug.assert(body.len == @sizeOf(ArrayMapBody) + @as(usize, n) * @sizeOf(Entry));
    const entries_ptr: [*]Entry = @ptrCast(@alignCast(body.ptr + @sizeOf(ArrayMapBody)));
    return entries_ptr[0..n];
}

fn champRootBody(h: *HeapHeader) *ChampRootBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == @sizeOf(ChampRootBody));
    return @ptrCast(@alignCast(body.ptr));
}

fn champRootBodyConst(h: *HeapHeader) *const ChampRootBody {
    return champRootBody(h);
}

fn champInteriorHeader(h: *HeapHeader) *ChampInteriorHeader {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(ChampInteriorHeader));
    return @ptrCast(@alignCast(body.ptr));
}

fn champInteriorHeaderConst(h: *HeapHeader) *const ChampInteriorHeader {
    return champInteriorHeader(h);
}

fn champInteriorEntries(h: *HeapHeader) []Entry {
    const hdr = champInteriorHeaderConst(h);
    const n = @popCount(hdr.data_bitmap);
    const body = Heap.bodyBytes(h);
    const entries_ptr: [*]Entry = @ptrCast(@alignCast(body.ptr + @sizeOf(ChampInteriorHeader)));
    return entries_ptr[0..n];
}

fn champInteriorChildren(h: *HeapHeader) []*HeapHeader {
    const hdr = champInteriorHeaderConst(h);
    const n_entries = @popCount(hdr.data_bitmap);
    const n_children = @popCount(hdr.node_bitmap);
    const body = Heap.bodyBytes(h);
    const entries_bytes = @as(usize, n_entries) * @sizeOf(Entry);
    const children_ptr: [*]*HeapHeader = @ptrCast(@alignCast(body.ptr + @sizeOf(ChampInteriorHeader) + entries_bytes));
    return children_ptr[0..n_children];
}

fn collisionHeader(h: *HeapHeader) *ChampCollisionHeader {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(ChampCollisionHeader));
    return @ptrCast(@alignCast(body.ptr));
}

fn collisionHeaderConst(h: *HeapHeader) *const ChampCollisionHeader {
    return collisionHeader(h);
}

fn collisionEntries(h: *HeapHeader) []Entry {
    const hdr = collisionHeaderConst(h);
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == @sizeOf(ChampCollisionHeader) + @as(usize, hdr.count) * @sizeOf(Entry));
    const entries_ptr: [*]Entry = @ptrCast(@alignCast(body.ptr + @sizeOf(ChampCollisionHeader)));
    return entries_ptr[0..hdr.count];
}

// =============================================================================
// Value packing — builds user-facing Values from internal headers.
// =============================================================================

fn valueFromArrayMap(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_map)) | (@as(u64, subkind_array_map) << 16),
        .payload = @intFromPtr(h),
    };
}

fn valueFromChampRoot(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_map)) | (@as(u64, subkind_champ_root) << 16),
        .payload = @intFromPtr(h),
    };
}

/// Resolve a user-facing map Value to its backing header. Asserts the
/// top-level subkind discipline (CHAMP.md §3): user-facing maps are
/// subkind 0 or 1 — subkinds 2/3 are internal and never appear in a
/// user Value.
fn mapHeader(v: Value) *HeapHeader {
    std.debug.assert(v.kind() == .persistent_map);
    const sk = v.subkind();
    std.debug.assert(sk == subkind_array_map or sk == subkind_champ_root);
    return Heap.asHeapHeader(v);
}

// =============================================================================
// Key equivalence — keyword-keyed fast path (CHAMP.md §6.5).
//
// Two-tier:
//   (a) Bit-identity: same tag + same payload ⇒ definitely equal.
//   (b) Keyword shortcut: both `.keyword` ⇒ interned-id compare; this
//       is equivalent to `dispatch.equal` for this kind-pair by intern-
//       table invariants, but skips the callback indirection.
//   (c) Fall-through: delegate to `elementEq` (the general-purpose
//       `dispatch.equal` callback).
// =============================================================================

inline fn keyEquivalent(a: Value, b: Value, elementEq: *const fn (Value, Value) bool) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    if (a.kind() == .keyword and b.kind() == .keyword) {
        return a.asKeywordId() == b.asKeywordId();
    }
    return elementEq(a, b);
}

// =============================================================================
// Indexing hash — low 32 bits of `dispatch.hashValue(key)`. Passed in
// as a callback so this module stays one-way-terminal w.r.t. dispatch.
// =============================================================================

inline fn indexHashOf(k: Value, elementHash: *const fn (Value) u64) u32 {
    return @truncate(elementHash(k));
}

// =============================================================================
// Public API — construction & query (CHAMP.md §8)
// =============================================================================

/// Fresh empty map. Subkind 0 (array-map) with count 0. Not a shared
/// singleton — every call allocates a new header (matches list / vector
/// precedent; shared-singleton pinning is a Phase 6 optimization).
pub fn mapEmpty(heap: *Heap) !Value {
    const h = try allocArrayMap(heap, 0);
    const body = arrayMapBody(h);
    body.count = 0;
    body._pad = 0;
    return valueFromArrayMap(h);
}

/// Build a map from an entry slice. Duplicate keys: later wins (per
/// CHAMP.md §8.1 / peer-AI turn 8). Implementation is a left-fold of
/// `mapAssoc`, which handles duplicate-key overwrite and promotion
/// threshold automatically.
pub fn mapFromEntries(
    heap: *Heap,
    entries: []const Entry,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    var result = try mapEmpty(heap);
    for (entries) |e| {
        result = try mapAssoc(heap, result, e.key, e.value, elementHash, elementEq);
    }
    return result;
}

pub fn mapCount(m: Value) usize {
    const h = mapHeader(m);
    return switch (m.subkind()) {
        subkind_array_map => arrayMapBodyConst(h).count,
        subkind_champ_root => champRootBodyConst(h).count,
        else => unreachable,
    };
}

pub fn mapIsEmpty(m: Value) bool {
    return mapCount(m) == 0;
}

/// Looks up `key` in `m`. Returns `.absent` if the key is not present,
/// or `.present = v` if it is (where `v` may itself be nil — nil is a
/// legal map value, and the union makes the distinction explicit).
pub fn mapGet(
    m: Value,
    key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) MapLookup {
    const h = mapHeader(m);
    return switch (m.subkind()) {
        subkind_array_map => arrayMapGet(h, key, elementEq),
        subkind_champ_root => champGet(champRootBodyConst(h).root_node, key, indexHashOf(key, elementHash), 0, elementEq),
        else => unreachable,
    };
}

/// Associate `key → val` in `m`, returning a new persistent map.
/// Semantics (CHAMP.md §8.1):
///   - key already present with `=`-equal value → return `m` unchanged
///     (pointer identity preserved; no allocation).
///   - key already present with different value → replace value; count
///     unchanged.
///   - key absent, count < 8 at array-map → extend array-map.
///   - key absent, count == 8 at array-map → promote to CHAMP.
///   - CHAMP path → recursive path-copy.
pub fn mapAssoc(
    heap: *Heap,
    m: Value,
    key: Value,
    val: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const h = mapHeader(m);
    return switch (m.subkind()) {
        subkind_array_map => arrayMapAssoc(heap, m, h, key, val, elementHash, elementEq),
        subkind_champ_root => champRootAssoc(heap, m, h, key, val, elementHash, elementEq),
        else => unreachable,
    };
}

/// Dissociate `key` from `m`, returning a new persistent map.
/// Semantics (CHAMP.md §8.1):
///   - key absent → return `m` unchanged (pointer identity preserved).
///   - key present → return a new map with one fewer entry.
///   - dissoc that leaves the CHAMP root with a single interior
///     subtree whose subtree in turn holds a single entry triggers
///     single-entry-subtree promotion (CHAMP.md §5.5).
///   - dissoc that leaves an empty CHAMP root returns a fresh
///     subkind-0 empty array-map (CHAMP.md §5.6).
///   - no demotion to array-map when count drops back below 9
///     (CHAMP.md §5.4).
pub fn mapDissoc(
    heap: *Heap,
    m: Value,
    key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const h = mapHeader(m);
    return switch (m.subkind()) {
        subkind_array_map => arrayMapDissoc(heap, m, h, key, elementEq),
        subkind_champ_root => champRootDissoc(heap, m, h, key, elementHash, elementEq),
        else => unreachable,
    };
}

// =============================================================================
// Array-map operations (subkind 0)
// =============================================================================

/// Linear scan lookup. O(n) for n ≤ 8 (worst case 8 compares).
fn arrayMapGet(
    h: *HeapHeader,
    key: Value,
    elementEq: *const fn (Value, Value) bool,
) MapLookup {
    const entries = arrayMapEntries(h);
    for (entries) |e| {
        // Synthetic elementHash is irrelevant here; array-map lookup
        // is by structural key equality, not by indexing hash.
        if (keyEquivalent(e.key, key, elementEq)) {
            return .{ .present = e.value };
        }
    }
    return .absent;
}

/// Find the index of `key` in the array-map, or null if absent.
fn arrayMapFindKeyIndex(
    h: *HeapHeader,
    key: Value,
    elementEq: *const fn (Value, Value) bool,
) ?usize {
    const entries = arrayMapEntries(h);
    for (entries, 0..) |e, i| {
        if (keyEquivalent(e.key, key, elementEq)) return i;
    }
    return null;
}

/// Array-map assoc. Three cases:
///   (a) key already present, value equal → return `m` unchanged.
///   (b) key already present, value different → replace value.
///   (c) key absent:
///       - count < 8 → grow by one.
///       - count == 8 → promote to CHAMP.
fn arrayMapAssoc(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    key: Value,
    val: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const src_entries = arrayMapEntries(src_h);
    // Case (a) / (b): key already present.
    if (arrayMapFindKeyIndex(src_h, key, elementEq)) |idx| {
        const existing = src_entries[idx];
        if (existing.value.tag == val.tag and existing.value.payload == val.payload) {
            return src_v; // same pointer, no allocation
        }
        // Replace-in-new-copy. Count unchanged.
        const new_h = try allocArrayMap(heap, @intCast(src_entries.len));
        const new_body = arrayMapBody(new_h);
        new_body.count = @intCast(src_entries.len);
        new_body._pad = 0;
        const new_entries = arrayMapEntries(new_h);
        @memcpy(new_entries, src_entries);
        new_entries[idx].value = val;
        return valueFromArrayMap(new_h);
    }

    // Case (c): key absent.
    if (src_entries.len < array_map_max) {
        // Grow array-map by 1.
        const new_count: u32 = @as(u32, @intCast(src_entries.len)) + 1;
        const new_h = try allocArrayMap(heap, new_count);
        const new_body = arrayMapBody(new_h);
        new_body.count = new_count;
        new_body._pad = 0;
        const new_entries = arrayMapEntries(new_h);
        @memcpy(new_entries[0..src_entries.len], src_entries);
        new_entries[src_entries.len] = .{ .key = key, .value = val };
        return valueFromArrayMap(new_h);
    }

    // Promotion: count == 8, new key → CHAMP.
    std.debug.assert(src_entries.len == array_map_max);
    return arrayMapPromoteAndAssoc(heap, src_entries, key, val, elementHash, elementEq);
}

/// Array-map dissoc. Two cases:
///   (a) key absent → return unchanged.
///   (b) key present → return a new array-map with count - 1.
fn arrayMapDissoc(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    key: Value,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const idx_opt = arrayMapFindKeyIndex(src_h, key, elementEq);
    if (idx_opt == null) return src_v;

    const idx = idx_opt.?;
    const src_entries = arrayMapEntries(src_h);
    const new_count: u32 = @as(u32, @intCast(src_entries.len)) - 1;
    const new_h = try allocArrayMap(heap, new_count);
    const new_body = arrayMapBody(new_h);
    new_body.count = new_count;
    new_body._pad = 0;
    const new_entries = arrayMapEntries(new_h);
    // Copy prefix [0..idx] and suffix [idx+1..].
    if (idx > 0) @memcpy(new_entries[0..idx], src_entries[0..idx]);
    if (idx < src_entries.len - 1) {
        @memcpy(new_entries[idx..], src_entries[idx + 1 ..]);
    }
    return valueFromArrayMap(new_h);
}

/// Array-map → CHAMP promotion. Entry count is at array_map_max (8),
/// and we're about to add a 9th distinct key. Rehash all 9 entries
/// into a single CHAMP interior node (recursively splitting as their
/// hash prefixes demand), wrap in a CHAMP root, return.
fn arrayMapPromoteAndAssoc(
    heap: *Heap,
    existing: []const Entry,
    new_key: Value,
    new_val: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    // Start with a single-entry CHAMP interior holding the first entry,
    // then assoc each subsequent entry into the growing structure.
    // This is simpler than bulk-loading and guaranteed correct.
    std.debug.assert(existing.len == array_map_max);
    const first = existing[0];
    var root_node = try champSingleEntryInterior(heap, first.key, first.value, indexHashOf(first.key, elementHash), 0);
    var count: u32 = 1;
    for (existing[1..]) |e| {
        const res = try champAssocInNode(heap, root_node, e.key, e.value, indexHashOf(e.key, elementHash), 0, elementHash, elementEq);
        root_node = res.node;
        if (res.added) count += 1;
    }
    const res = try champAssocInNode(heap, root_node, new_key, new_val, indexHashOf(new_key, elementHash), 0, elementHash, elementEq);
    root_node = res.node;
    if (res.added) count += 1;
    const root_h = try allocChampRoot(heap);
    const root_body = champRootBody(root_h);
    root_body.count = count;
    root_body._pad = 0;
    root_body.root_node = root_node;
    return valueFromChampRoot(root_h);
}

// =============================================================================
// CHAMP root operations (subkind 1)
// =============================================================================

/// Root-level assoc. Delegates to the subtree's assoc; wraps the
/// result in a new root with updated count.
fn champRootAssoc(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    key: Value,
    val: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const src_body = champRootBodyConst(src_h);
    const hash32 = indexHashOf(key, elementHash);
    const res = try champAssocInNode(heap, src_body.root_node, key, val, hash32, 0, elementHash, elementEq);
    if (res.node == src_body.root_node and !res.added and !res.replaced) {
        // Pointer-identity short-circuit (same-value assoc on an
        // existing key propagated up to the root unchanged).
        return src_v;
    }
    const new_h = try allocChampRoot(heap);
    const new_body = champRootBody(new_h);
    new_body.count = if (res.added) src_body.count + 1 else src_body.count;
    new_body._pad = 0;
    new_body.root_node = res.node;
    return valueFromChampRoot(new_h);
}

/// Root-level dissoc. On-absent returns unchanged. On-present recurses
/// down the trie; the result may collapse to subkind-0 empty array-map
/// when count drops to 0.
fn champRootDissoc(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const src_body = champRootBodyConst(src_h);
    const hash32 = indexHashOf(key, elementHash);
    const res = try champDissocFromNode(heap, src_body.root_node, key, hash32, 0, elementEq);
    if (!res.removed) return src_v;
    const new_count = src_body.count - 1;
    if (new_count == 0) {
        // CHAMP.md §5.6: empty result collapses to subkind-0 empty
        // array-map, NOT a subkind-1 root with null child.
        return mapEmpty(heap);
    }
    // Build the new root_node. Three possibilities coming back from
    // `champDissocFromNode`:
    //   (i)  `res.node != null, res.promoted_single == null` —
    //        the subtree was mutated but did not collapse; use it.
    //   (ii) `res.node == null, res.promoted_single != null` —
    //        single-entry-subtree promotion at the root. There is no
    //        parent interior to migrate into, so we wrap the sole
    //        entry in a fresh subkind-2 interior at shift 0 and make
    //        THAT the new root_node (CHAMP.md §5.6: stay in CHAMP,
    //        do not demote even at count 1).
    //   (iii) `res.node == null, res.promoted_single == null` —
    //         subtree completely emptied. Only possible when
    //         `new_count == 0`, already handled above.
    const new_root_node: *HeapHeader = if (res.promoted_single) |pulled| blk: {
        break :blk try champSingleEntryInterior(
            heap,
            pulled.key,
            pulled.value,
            indexHashOf(pulled.key, elementHash),
            0,
        );
    } else blk: {
        std.debug.assert(res.node != null);
        break :blk res.node.?;
    };
    const new_h = try allocChampRoot(heap);
    const new_body = champRootBody(new_h);
    new_body.count = new_count;
    new_body._pad = 0;
    new_body.root_node = new_root_node;
    return valueFromChampRoot(new_h);
}

// =============================================================================
// CHAMP internal ops — the trie walk
// =============================================================================

/// Result of a recursive assoc call.
const AssocResult = struct {
    node: *HeapHeader,
    /// True when the node was structurally different (count increased
    /// or a value changed) from the input. False when the caller is
    /// looking at the same pointer with no change.
    added: bool, // new key inserted
    replaced: bool, // existing key, different value
};

/// Build a single-entry CHAMP interior at `shift`. Used during
/// array-map → CHAMP promotion and when splitting a two-entry
/// collision at the deepest level.
fn champSingleEntryInterior(
    heap: *Heap,
    key: Value,
    val: Value,
    hash32: u32,
    shift: u8,
) !*HeapHeader {
    std.debug.assert(shift <= MAX_TRIE_SHIFT);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const h = try allocChampInterior(heap, 1, 0);
    const hdr = champInteriorHeader(h);
    hdr.data_bitmap = @as(u32, 1) << @intCast(slot);
    hdr.node_bitmap = 0;
    const entries = champInteriorEntries(h);
    entries[0] = .{ .key = key, .value = val };
    return h;
}

/// Build a CHAMP interior node containing two inline entries at
/// distinct slots `s1` and `s2` (s1 != s2). Entries sorted by slot
/// index (ascending) per CHAMP.md §4.3.
fn champTwoEntryInterior(
    heap: *Heap,
    k1: Value,
    v1: Value,
    slot1: u32,
    k2: Value,
    v2: Value,
    slot2: u32,
) !*HeapHeader {
    std.debug.assert(slot1 != slot2);
    const h = try allocChampInterior(heap, 2, 0);
    const hdr = champInteriorHeader(h);
    hdr.data_bitmap = (@as(u32, 1) << @intCast(slot1)) | (@as(u32, 1) << @intCast(slot2));
    hdr.node_bitmap = 0;
    const entries = champInteriorEntries(h);
    // Slot-ascending order:
    if (slot1 < slot2) {
        entries[0] = .{ .key = k1, .value = v1 };
        entries[1] = .{ .key = k2, .value = v2 };
    } else {
        entries[0] = .{ .key = k2, .value = v2 };
        entries[1] = .{ .key = k1, .value = v1 };
    }
    return h;
}

/// Build a CHAMP interior node whose only content is a single child
/// pointer at `slot`. Used during two-entry split when both entries
/// hash to the same slot at this level.
fn champSingleChildInterior(
    heap: *Heap,
    slot: u32,
    child: *HeapHeader,
) !*HeapHeader {
    const h = try allocChampInterior(heap, 0, 1);
    const hdr = champInteriorHeader(h);
    hdr.data_bitmap = 0;
    hdr.node_bitmap = @as(u32, 1) << @intCast(slot);
    const children = champInteriorChildren(h);
    children[0] = child;
    return h;
}

/// Build a collision node with two entries sharing the same 32-bit
/// indexing hash. Entries in association order (k1 first, then k2).
fn champCollisionOfTwo(
    heap: *Heap,
    k1: Value,
    v1: Value,
    k2: Value,
    v2: Value,
    shared_hash: u32,
) !*HeapHeader {
    const h = try allocCollision(heap, 2);
    const hdr = collisionHeader(h);
    hdr.shared_hash = shared_hash;
    hdr.count = 2;
    const entries = collisionEntries(h);
    entries[0] = .{ .key = k1, .value = v1 };
    entries[1] = .{ .key = k2, .value = v2 };
    return h;
}

/// Build a two-entry substructure at `shift` that holds both `k1 → v1`
/// (hash1) and `k2 → v2` (hash2). Recurses if the slots collide until
/// reaching MAX_TRIE_SHIFT; on collision at the deepest level, emits
/// a collision node.
fn champBuildTwoEntrySubtree(
    heap: *Heap,
    k1: Value,
    v1: Value,
    hash1: u32,
    k2: Value,
    v2: Value,
    hash2: u32,
    shift: u8,
) !*HeapHeader {
    if (shift > MAX_TRIE_SHIFT) {
        // All 32 bits consumed and still the same — must be equal
        // hashes. This entry point is only called after the caller
        // has confirmed the keys are different; equal-key case is
        // handled above (replace value).
        std.debug.assert(hash1 == hash2);
        return champCollisionOfTwo(heap, k1, v1, k2, v2, hash1);
    }
    const s1: u32 = (hash1 >> @intCast(shift)) & branch_mask;
    const s2: u32 = (hash2 >> @intCast(shift)) & branch_mask;
    if (s1 != s2) {
        return champTwoEntryInterior(heap, k1, v1, s1, k2, v2, s2);
    }
    // Same slot at this level — recurse one level deeper. At shift
    // == MAX_TRIE_SHIFT the recursive call goes past the trie
    // (shift + branch_bits > MAX_TRIE_SHIFT) and hits the collision
    // branch above on re-entry.
    const next_shift: u8 = shift + branch_bits;
    const child = try champBuildTwoEntrySubtree(heap, k1, v1, hash1, k2, v2, hash2, next_shift);
    return champSingleChildInterior(heap, s1, child);
}

// ---- CHAMP node dispatch ----

/// Look up `key` in any subtree node (interior or collision). Hash
/// is only used at interior levels; collision nodes ignore it beyond
/// the pre-check of `shared_hash`.
/// Look up `key` in any subtree node (interior or collision). When
/// `shift > MAX_TRIE_SHIFT`, the node IS a collision node (the caller
/// just descended into a child at the deepest level); otherwise it's
/// an interior node. Dispatch is shift-driven — no body-inspection
/// heuristic.
fn champGet(
    node: *HeapHeader,
    key: Value,
    hash32: u32,
    shift: u8,
    elementEq: *const fn (Value, Value) bool,
) MapLookup {
    if (shift > MAX_TRIE_SHIFT) {
        return collisionGet(node, key, hash32, elementEq);
    }
    return champInteriorGet(node, key, hash32, shift, elementEq);
}

/// Look up `key` in a CHAMP interior node. Descends into child nodes
/// by hash fragment; returns on inline-entry match or miss.
fn champInteriorGet(
    node: *HeapHeader,
    key: Value,
    hash32: u32,
    shift: u8,
    elementEq: *const fn (Value, Value) bool,
) MapLookup {
    std.debug.assert(shift <= MAX_TRIE_SHIFT);
    const hdr = champInteriorHeaderConst(node);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    if ((hdr.data_bitmap & slot_bit) != 0) {
        // Inline entry at this slot — compare keys.
        const idx_in_entries = @popCount(hdr.data_bitmap & (slot_bit - 1));
        const e = champInteriorEntries(node)[idx_in_entries];
        if (keyEquivalent(e.key, key, elementEq)) {
            return .{ .present = e.value };
        }
        return .absent;
    }
    if ((hdr.node_bitmap & slot_bit) != 0) {
        // Child pointer at this slot — recurse one level deeper.
        // At shift == MAX_TRIE_SHIFT the child is a collision node;
        // `champGet` detects this via `shift > MAX_TRIE_SHIFT`.
        const idx_in_children = childIndex(hdr.node_bitmap, slot);
        const child = champInteriorChildren(node)[idx_in_children];
        const next_shift: u8 = shift + branch_bits;
        return champGet(child, key, hash32, next_shift, elementEq);
    }
    return .absent;
}

/// Look up `key` in a collision node. First gate the shared hash; if
/// it mismatches, the key cannot possibly be in this bucket.
fn collisionGet(
    node: *HeapHeader,
    key: Value,
    hash32: u32,
    elementEq: *const fn (Value, Value) bool,
) MapLookup {
    const hdr = collisionHeaderConst(node);
    if (hdr.shared_hash != hash32) return .absent;
    const entries = collisionEntries(node);
    for (entries) |e| {
        if (keyEquivalent(e.key, key, elementEq)) {
            return .{ .present = e.value };
        }
    }
    return .absent;
}

/// Child-array physical index for a given slot. Child segment is
/// stored in descending slot-index order (CHAMP.md §4.3) so the
/// physical index from the start of the child segment for slot `i` is
/// the number of set bits in `node_bitmap` at slots GREATER than `i`.
/// Constructed as `popCount(mask_greater)` where `mask_greater` is the
/// complement of `mask_at_or_below` — the latter avoids the
/// "shift by 32" undefined-behavior edge when `slot == 31`.
inline fn childIndex(node_bitmap: u32, slot: u32) usize {
    const slot_u5: u5 = @intCast(slot);
    const slot_bit: u32 = @as(u32, 1) << slot_u5;
    const mask_at_or_below: u32 = (slot_bit - 1) | slot_bit;
    const mask_greater: u32 = ~mask_at_or_below;
    return @popCount(node_bitmap & mask_greater);
}

/// Data-array physical index for a given slot. Data segment is stored
/// in ascending slot-index order.
inline fn dataIndex(data_bitmap: u32, slot: u32) usize {
    const mask_lower: u32 = (@as(u32, 1) << @intCast(slot)) - 1;
    return @popCount(data_bitmap & mask_lower);
}

// =============================================================================
// CHAMP assoc — recursive path-copy with bitmap updates.
// =============================================================================

/// Assoc `key → val` into `node` at `shift`. `node` is either a CHAMP
/// interior node (when `shift <= MAX_TRIE_SHIFT`) OR a collision node
/// (when the caller reached `shift > MAX_TRIE_SHIFT` and descended into
/// its child at the deepest level).
fn champAssocInNode(
    heap: *Heap,
    node: *HeapHeader,
    key: Value,
    val: Value,
    hash32: u32,
    shift: u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !AssocResult {
    if (shift > MAX_TRIE_SHIFT) {
        return collisionAssoc(heap, node, key, val, hash32, elementEq);
    }
    const hdr = champInteriorHeaderConst(node);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);

    // Case (a): inline entry at slot → compare keys.
    if ((hdr.data_bitmap & slot_bit) != 0) {
        const data_idx = dataIndex(hdr.data_bitmap, slot);
        const existing = champInteriorEntries(node)[data_idx];
        if (keyEquivalent(existing.key, key, elementEq)) {
            // Same key. Value equal? short-circuit. Else replace.
            if (existing.value.tag == val.tag and existing.value.payload == val.payload) {
                return .{ .node = node, .added = false, .replaced = false };
            }
            const new_node = try cloneInteriorReplaceEntry(heap, node, data_idx, .{ .key = key, .value = val });
            return .{ .node = new_node, .added = false, .replaced = true };
        }
        // Different key, same slot. Must split into a subtree.
        const existing_hash = indexHashOf(existing.key, elementHash);
        const next_shift: u8 = shift + branch_bits;
        const subtree = try champBuildTwoEntrySubtree(heap, existing.key, existing.value, existing_hash, key, val, hash32, next_shift);
        // Remove the inline entry; add a child pointer at the same slot.
        const new_node = try cloneInteriorMigrateDataToChild(heap, node, slot, data_idx, subtree);
        return .{ .node = new_node, .added = true, .replaced = false };
    }

    // Case (b): child pointer at slot → recurse.
    if ((hdr.node_bitmap & slot_bit) != 0) {
        const child_idx = childIndex(hdr.node_bitmap, slot);
        const child = champInteriorChildren(node)[child_idx];
        const next_shift: u8 = shift + branch_bits;
        const sub = try champAssocInNode(heap, child, key, val, hash32, next_shift, elementHash, elementEq);
        if (sub.node == child) {
            // Child unchanged → caller is unchanged.
            return .{ .node = node, .added = sub.added, .replaced = sub.replaced };
        }
        const new_node = try cloneInteriorReplaceChild(heap, node, child_idx, sub.node);
        return .{ .node = new_node, .added = sub.added, .replaced = sub.replaced };
    }

    // Case (c): empty slot → insert inline.
    const new_node = try cloneInteriorInsertEntry(heap, node, slot, .{ .key = key, .value = val });
    return .{ .node = new_node, .added = true, .replaced = false };
}

/// Assoc into a collision node. Either replaces an existing key's
/// value or appends a new entry.
fn collisionAssoc(
    heap: *Heap,
    node: *HeapHeader,
    key: Value,
    val: Value,
    hash32: u32,
    elementEq: *const fn (Value, Value) bool,
) !AssocResult {
    const hdr = collisionHeaderConst(node);
    std.debug.assert(hdr.shared_hash == hash32); // caller asserted this by reaching here

    const entries = collisionEntries(node);
    for (entries, 0..) |e, i| {
        if (keyEquivalent(e.key, key, elementEq)) {
            if (e.value.tag == val.tag and e.value.payload == val.payload) {
                return .{ .node = node, .added = false, .replaced = false };
            }
            // Replace in new copy.
            const new_h = try allocCollision(heap, hdr.count);
            const new_hdr = collisionHeader(new_h);
            new_hdr.shared_hash = hash32;
            new_hdr.count = hdr.count;
            const new_entries = collisionEntries(new_h);
            @memcpy(new_entries, entries);
            new_entries[i].value = val;
            return .{ .node = new_h, .added = false, .replaced = true };
        }
    }
    // Append.
    const new_h = try allocCollision(heap, hdr.count + 1);
    const new_hdr = collisionHeader(new_h);
    new_hdr.shared_hash = hash32;
    new_hdr.count = hdr.count + 1;
    const new_entries = collisionEntries(new_h);
    @memcpy(new_entries[0..entries.len], entries);
    new_entries[entries.len] = .{ .key = key, .value = val };
    return .{ .node = new_h, .added = true, .replaced = false };
}

// =============================================================================
// CHAMP node clone helpers (path-copy primitives)
// =============================================================================

/// Clone an interior node, replacing the inline entry at `data_idx`
/// with `new_entry`. Bitmaps unchanged.
fn cloneInteriorReplaceEntry(
    heap: *Heap,
    src: *HeapHeader,
    data_idx: usize,
    new_entry: Entry,
) !*HeapHeader {
    const src_hdr = champInteriorHeaderConst(src);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const new_h = try allocChampInterior(
        heap,
        @intCast(src_entries.len),
        @intCast(src_children.len),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_entries = champInteriorEntries(new_h);
    @memcpy(new_entries, src_entries);
    new_entries[data_idx] = new_entry;
    const new_children = champInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    return new_h;
}

/// Clone an interior node, replacing the child pointer at `child_idx`
/// with `new_child`. Bitmaps unchanged.
fn cloneInteriorReplaceChild(
    heap: *Heap,
    src: *HeapHeader,
    child_idx: usize,
    new_child: *HeapHeader,
) !*HeapHeader {
    const src_hdr = champInteriorHeaderConst(src);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const new_h = try allocChampInterior(
        heap,
        @intCast(src_entries.len),
        @intCast(src_children.len),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_entries = champInteriorEntries(new_h);
    @memcpy(new_entries, src_entries);
    const new_children = champInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    new_children[child_idx] = new_child;
    return new_h;
}

/// Clone an interior node, inserting a new inline entry at `slot`.
/// `slot` must not already have a data or node bit set. Grows data
/// segment by 1; children unchanged.
fn cloneInteriorInsertEntry(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    new_entry: Entry,
) !*HeapHeader {
    const src_hdr = champInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) == 0);
    std.debug.assert((src_hdr.node_bitmap & slot_bit) == 0);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const insert_at = dataIndex(src_hdr.data_bitmap, slot);
    const new_h = try allocChampInterior(
        heap,
        @intCast(src_entries.len + 1),
        @intCast(src_children.len),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap | slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_entries = champInteriorEntries(new_h);
    if (insert_at > 0) @memcpy(new_entries[0..insert_at], src_entries[0..insert_at]);
    new_entries[insert_at] = new_entry;
    if (insert_at < src_entries.len) {
        @memcpy(new_entries[insert_at + 1 ..], src_entries[insert_at..]);
    }
    const new_children = champInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    return new_h;
}

/// Clone an interior node, migrating the inline entry at `slot` /
/// `data_idx` into a child pointer at the same slot. Used when two
/// different keys hash to the same slot and must be pushed into a
/// subtree. Data segment shrinks by 1; child segment grows by 1.
fn cloneInteriorMigrateDataToChild(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    data_idx: usize,
    new_child: *HeapHeader,
) !*HeapHeader {
    const src_hdr = champInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) != 0);
    std.debug.assert((src_hdr.node_bitmap & slot_bit) == 0);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const new_h = try allocChampInterior(
        heap,
        @intCast(src_entries.len - 1),
        @intCast(src_children.len + 1),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap & ~slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap | slot_bit;
    // Copy entries except the migrated one.
    const new_entries = champInteriorEntries(new_h);
    if (data_idx > 0) @memcpy(new_entries[0..data_idx], src_entries[0..data_idx]);
    if (data_idx < src_entries.len - 1) {
        @memcpy(new_entries[data_idx..], src_entries[data_idx + 1 ..]);
    }
    // Insert new child at the correct position (descending slot order).
    const child_insert_at = childIndex(new_hdr.node_bitmap, slot);
    const new_children = champInteriorChildren(new_h);
    if (child_insert_at > 0) @memcpy(new_children[0..child_insert_at], src_children[0..child_insert_at]);
    new_children[child_insert_at] = new_child;
    if (child_insert_at < src_children.len) {
        @memcpy(new_children[child_insert_at + 1 ..], src_children[child_insert_at..]);
    }
    return new_h;
}

/// Clone an interior node, removing the inline entry at `slot` /
/// `data_idx`. Data segment shrinks by 1; children unchanged.
fn cloneInteriorRemoveEntry(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    data_idx: usize,
) !*HeapHeader {
    const src_hdr = champInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) != 0);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const new_h = try allocChampInterior(
        heap,
        @intCast(src_entries.len - 1),
        @intCast(src_children.len),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap & ~slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_entries = champInteriorEntries(new_h);
    if (data_idx > 0) @memcpy(new_entries[0..data_idx], src_entries[0..data_idx]);
    if (data_idx < src_entries.len - 1) {
        @memcpy(new_entries[data_idx..], src_entries[data_idx + 1 ..]);
    }
    const new_children = champInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    return new_h;
}

/// Clone an interior node, replacing the child pointer at `slot` /
/// `child_idx` with an inline entry at the same slot. This is the
/// single-entry-subtree promotion step (CHAMP.md §5.5) — when dissoc
/// collapses a subtree to one entry, we pull it back up.
fn cloneInteriorMigrateChildToData(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    child_idx: usize,
    pulled_entry: Entry,
) !*HeapHeader {
    const src_hdr = champInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.node_bitmap & slot_bit) != 0);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) == 0);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const new_h = try allocChampInterior(
        heap,
        @intCast(src_entries.len + 1),
        @intCast(src_children.len - 1),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap | slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap & ~slot_bit;
    // Insert new entry at the appropriate data position.
    const entry_insert_at = dataIndex(new_hdr.data_bitmap, slot);
    const new_entries = champInteriorEntries(new_h);
    if (entry_insert_at > 0) @memcpy(new_entries[0..entry_insert_at], src_entries[0..entry_insert_at]);
    new_entries[entry_insert_at] = pulled_entry;
    if (entry_insert_at < src_entries.len) {
        @memcpy(new_entries[entry_insert_at + 1 ..], src_entries[entry_insert_at..]);
    }
    // Remove old child pointer.
    const new_children = champInteriorChildren(new_h);
    if (child_idx > 0) @memcpy(new_children[0..child_idx], src_children[0..child_idx]);
    if (child_idx < src_children.len - 1) {
        @memcpy(new_children[child_idx..], src_children[child_idx + 1 ..]);
    }
    return new_h;
}

// =============================================================================
// CHAMP dissoc — recursive path-copy with subtree collapse.
// =============================================================================

const DissocResult = struct {
    /// New node pointer, or null if the subtree collapsed to empty.
    node: ?*HeapHeader,
    /// If the subtree collapsed to a single inline entry, return it
    /// here so the parent can pull it up (single-entry-subtree
    /// promotion). When this is non-null, `node` is null — the parent
    /// should NOT clone the subtree; it should instead migrate the
    /// entry into its own data segment.
    promoted_single: ?Entry = null,
    removed: bool,
};

fn champDissocFromNode(
    heap: *Heap,
    node: *HeapHeader,
    key: Value,
    hash32: u32,
    shift: u8,
    elementEq: *const fn (Value, Value) bool,
) !DissocResult {
    if (shift > MAX_TRIE_SHIFT) {
        return collisionDissoc(heap, node, key, hash32, elementEq);
    }
    const hdr = champInteriorHeaderConst(node);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);

    if ((hdr.data_bitmap & slot_bit) != 0) {
        const data_idx = dataIndex(hdr.data_bitmap, slot);
        const existing = champInteriorEntries(node)[data_idx];
        if (!keyEquivalent(existing.key, key, elementEq)) {
            // Key not in this slot; absent.
            return .{ .node = node, .removed = false };
        }
        // Remove this entry. After removal, does this node collapse?
        const new_entry_count = @popCount(hdr.data_bitmap) - 1;
        const new_child_count = @popCount(hdr.node_bitmap);
        if (new_entry_count == 0 and new_child_count == 0) {
            // Completely empty; parent should collapse the slot.
            return .{ .node = null, .removed = true };
        }
        if (new_entry_count == 1 and new_child_count == 0) {
            // Single-entry node. Return the lone entry for the parent
            // to pull up (unless this is the root — handled by the
            // root-level caller).
            const entries = champInteriorEntries(node);
            const sole = if (data_idx == 0) entries[1] else entries[0];
            return .{ .node = null, .promoted_single = sole, .removed = true };
        }
        const new_node = try cloneInteriorRemoveEntry(heap, node, slot, data_idx);
        return .{ .node = new_node, .removed = true };
    }

    if ((hdr.node_bitmap & slot_bit) != 0) {
        const child_idx = childIndex(hdr.node_bitmap, slot);
        const child = champInteriorChildren(node)[child_idx];
        const next_shift: u8 = shift + branch_bits;
        const sub = try champDissocFromNode(heap, child, key, hash32, next_shift, elementEq);
        if (!sub.removed) {
            return .{ .node = node, .removed = false };
        }
        if (sub.promoted_single) |pulled| {
            // Single-entry-subtree promotion (CHAMP.md §5.5): pull the
            // lone entry up into THIS node's data area.
            const new_node = try cloneInteriorMigrateChildToData(heap, node, slot, child_idx, pulled);
            return .{ .node = new_node, .removed = true };
        }
        if (sub.node == null) {
            // Empty subtree → drop the child pointer at this slot.
            return try champInteriorDropChildAt(heap, node, slot, child_idx);
        }
        // Subtree changed but not collapsed.
        const new_node = try cloneInteriorReplaceChild(heap, node, child_idx, sub.node.?);
        return .{ .node = new_node, .removed = true };
    }

    // No entry at this slot; absent.
    return .{ .node = node, .removed = false };
}

/// Drop the child pointer at `slot` / `child_idx` from an interior
/// node. If the result would leave exactly one entry and no children,
/// surface a `promoted_single` so the parent can pull it up.
fn champInteriorDropChildAt(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    child_idx: usize,
) !DissocResult {
    const src_hdr = champInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    const src_entries = champInteriorEntries(src);
    const src_children = champInteriorChildren(src);
    const new_entry_count = src_entries.len;
    const new_child_count = src_children.len - 1;
    if (new_entry_count == 0 and new_child_count == 0) {
        return .{ .node = null, .removed = true };
    }
    if (new_entry_count == 1 and new_child_count == 0) {
        return .{ .node = null, .promoted_single = src_entries[0], .removed = true };
    }
    const new_h = try allocChampInterior(
        heap,
        @intCast(new_entry_count),
        @intCast(new_child_count),
    );
    const new_hdr = champInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap;
    new_hdr.node_bitmap = src_hdr.node_bitmap & ~slot_bit;
    const new_entries = champInteriorEntries(new_h);
    @memcpy(new_entries, src_entries);
    const new_children = champInteriorChildren(new_h);
    if (child_idx > 0) @memcpy(new_children[0..child_idx], src_children[0..child_idx]);
    if (child_idx < src_children.len - 1) {
        @memcpy(new_children[child_idx..], src_children[child_idx + 1 ..]);
    }
    return .{ .node = new_h, .removed = true };
}

/// Dissoc from a collision node. Three cases:
///   (a) hash mismatches shared_hash → absent.
///   (b) key not in bucket → absent.
///   (c) key in bucket → new collision with count-1, OR if that would
///       leave a single entry, return `promoted_single` so the parent
///       pulls it up as an inline entry.
fn collisionDissoc(
    heap: *Heap,
    node: *HeapHeader,
    key: Value,
    hash32: u32,
    elementEq: *const fn (Value, Value) bool,
) !DissocResult {
    const hdr = collisionHeaderConst(node);
    if (hdr.shared_hash != hash32) {
        return .{ .node = node, .removed = false };
    }
    const entries = collisionEntries(node);
    for (entries, 0..) |e, i| {
        if (keyEquivalent(e.key, key, elementEq)) {
            if (hdr.count == 2) {
                const sole = if (i == 0) entries[1] else entries[0];
                return .{ .node = null, .promoted_single = sole, .removed = true };
            }
            const new_h = try allocCollision(heap, hdr.count - 1);
            const new_hdr = collisionHeader(new_h);
            new_hdr.shared_hash = hash32;
            new_hdr.count = hdr.count - 1;
            const new_entries = collisionEntries(new_h);
            if (i > 0) @memcpy(new_entries[0..i], entries[0..i]);
            if (i < entries.len - 1) @memcpy(new_entries[i..], entries[i + 1 ..]);
            return .{ .node = new_h, .removed = true };
        }
    }
    return .{ .node = node, .removed = false };
}

// =============================================================================
// Dispatch entry points (CHAMP.md §9)
// =============================================================================

/// Per-kind hash for a map Value. Routed here by
/// `dispatch.heapHashBase` at the `.persistent_map` arm. The result is
/// the pre-domain-mix hash, widened to `u64`; `dispatch.hashValue`
/// applies `mixKindDomain(base, 0xF1)` on the way out.
///
/// Caching contract (CHAMP.md §7.5): the root header's `hash: u32`
/// field caches the truncated low-32 bits of the finalized hash on
/// the first call. Every subsequent call returns the cached u32 value
/// widened to u64 — so the high 32 bits of the returned u64 are
/// always zero. This loses some precision vs. the full u64 unordered
/// combine, but `mixKindDomain` still produces a well-distributed
/// final u64 because the domain_byte × golden-ratio constant
/// occupies the high 32 bits. Matches the `string.hashHeader` / `bignum.hashHeader`
/// discipline (both return u32 and cache at u32 precision).
pub fn hashMap(h: *HeapHeader, elementHash: *const fn (Value) u64) u64 {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.persistent_map));
    }
    if (h.cachedHash()) |cached| {
        return @as(u64, cached);
    }
    var acc: u64 = hash_mod.unordered_init;
    var count_seen: usize = 0;
    const root_v: Value = .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_map)) | (@as(u64, inferRootSubkind(h)) << 16),
        .payload = @intFromPtr(h),
    };
    var iter = mapIter(root_v);
    while (iter.next()) |e| {
        acc = hash_mod.combineUnordered(acc, entryHash(e.key, e.value, elementHash));
        count_seen += 1;
    }
    const finalized = hash_mod.finalizeUnordered(acc, count_seen);
    const truncated: u32 = @truncate(finalized);
    if (truncated != 0) h.setCachedHash(truncated);
    return @as(u64, truncated);
}

/// Infer subkind of a user-facing map root header. For `hashMap` and
/// `equalMap` which receive the raw `*HeapHeader` (not a Value), we
/// reconstruct the Value subkind byte from the body size.
///
/// This is sound because the two user-facing body-size sets are
/// **disjoint by construction**:
///   - subkind-0 (array-map) body size: `8 + n * 32` for `n ∈ [0, 8]`
///     = {8, 40, 72, 104, 136, 168, 200, 232, 264}
///   - subkind-1 (CHAMP root)  body size: exactly 16
///
/// 16 ∉ {8, 40, 72, …, 264}, so the discriminator is unambiguous.
/// Safe builds assert the body size matches one of the known values
/// to catch corrupted headers before they're interpreted with the
/// wrong layout (peer-AI turn 11).
///
/// Subkinds 2 (interior) and 3 (collision) are internal-only and
/// never flow through this function — user-facing maps are only
/// subkind 0 or 1 per the CHAMP.md §3 discipline.
fn inferRootSubkind(h: *HeapHeader) u16 {
    const body_size = Heap.bodyBytes(h).len;
    if (body_size == @sizeOf(ChampRootBody)) return subkind_champ_root;
    if (std.debug.runtime_safety) {
        // Array-map body must be 8 + n*32 for n ∈ [0, 8]. Reject
        // anything else loudly — it indicates a corrupted header or
        // an internal subkind-2/3 node leaked into user territory.
        const header_bytes = @sizeOf(ArrayMapBody);
        const valid = body_size >= header_bytes and
            (body_size - header_bytes) % @sizeOf(Entry) == 0 and
            (body_size - header_bytes) / @sizeOf(Entry) <= array_map_max;
        if (!valid) {
            std.debug.panic(
                "hamt.inferRootSubkind: body size {d} does not match any valid user-facing map subkind (array-map 8..264 step 32, or CHAMP root 16). Possible internal-node leak or memory corruption.",
                .{body_size},
            );
        }
    }
    return subkind_array_map;
}

/// Per-entry hash (CHAMP.md §7.1): two ordered combines, no finalize,
/// no inner domain mix. SEMANTICS.md §3.2 amended 2026-04-19 to pin
/// this formula.
inline fn entryHash(k: Value, v: Value, elementHash: *const fn (Value) u64) u64 {
    var acc: u64 = hash_mod.ordered_init;
    acc = hash_mod.combineOrdered(acc, elementHash(k));
    acc = hash_mod.combineOrdered(acc, elementHash(v));
    return acc;
}

/// Same-kind structural equality. Handles all four subkind-pair
/// combinations (0,0) / (0,1) / (1,0) / (1,1). See CHAMP.md §6.3 /
/// §6.4 for strategy.
pub fn equalMap(
    a: *HeapHeader,
    b: *HeapHeader,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) bool {
    if (std.debug.runtime_safety) {
        std.debug.assert(a.kind == @intFromEnum(Kind.persistent_map));
        std.debug.assert(b.kind == @intFromEnum(Kind.persistent_map));
    }
    if (a == b) return true;

    const sk_a = inferRootSubkind(a);
    const sk_b = inferRootSubkind(b);

    const count_a = if (sk_a == subkind_array_map) arrayMapBodyConst(a).count else champRootBodyConst(a).count;
    const count_b = if (sk_b == subkind_array_map) arrayMapBodyConst(b).count else champRootBodyConst(b).count;
    if (count_a != count_b) return false;

    // Semantic-associative strategy (CHAMP.md §6.4): iterate one side,
    // get-into the other, require every entry matches. This works
    // uniformly for all four subkind-pair combinations.
    const a_val: Value = .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_map)) | (@as(u64, sk_a) << 16),
        .payload = @intFromPtr(a),
    };
    const b_val: Value = .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_map)) | (@as(u64, sk_b) << 16),
        .payload = @intFromPtr(b),
    };
    var iter = mapIter(a_val);
    while (iter.next()) |e| {
        switch (mapGet(b_val, e.key, elementHash, elementEq)) {
            .absent => return false,
            .present => |bv| {
                if (!elementEq(e.value, bv)) return false;
            },
        }
    }
    return true;
}

// =============================================================================
// Iterator — walks every entry of a user-facing map Value.
//
// Used by `hashMap`, `equalMap`, and (eventually) language-surface
// `(seq m)`. Iteration order is insertion order for array-maps and
// trie-walk order for CHAMP-backed maps — the language does not
// guarantee either specifically (maps are unordered at the semantic
// level); the iterator's order is an implementation detail.
//
// Internal-node discrimination (peer-AI turn 11): interior-vs-collision
// is tracked by **recorded shift depth per frame**, NOT by inspecting
// body bytes. The assoc/dissoc paths only construct collision nodes
// at `shift > MAX_TRIE_SHIFT`, so a frame whose child was reached via
// descent at shift `s` knows deterministically:
//   - if `s <= MAX_TRIE_SHIFT`: child is another interior.
//   - if `s > MAX_TRIE_SHIFT`: child is a collision node.
// This matches the read/write path's shift-driven dispatch and removes
// the probabilistic body-inspection heuristic entirely.
// =============================================================================

pub const MapIter = struct {
    /// Stack of frames: one per nesting level of CHAMP traversal,
    /// plus one for the top-level array-map or root iteration.
    /// Max depth is bounded: root + up to COLLISION_DEPTH interior
    /// frames + possibly one collision frame = 9. 16 gives headroom.
    frames: [16]Frame = undefined,
    depth: u8 = 0,

    const Frame = struct {
        kind: FrameKind,
        node: *HeapHeader,
        /// Position within the frame: for array-map and collision,
        /// the current entry index; for interior, the current slot
        /// index 0..31 (we advance through the bitmaps).
        cursor: u32,
        /// Shift at which this frame's node was reached. Unused for
        /// `.array_map` frames; for `.champ_interior_*` frames it's
        /// the node's own shift (0 for the root's immediate child,
        /// branch_bits for its first sub-interior, etc.). Used to
        /// derive the kind of a child when descending (see
        /// `next()`'s `champ_interior_children` arm).
        shift: u8 = 0,
    };

    const FrameKind = enum { array_map, champ_interior_data, champ_interior_children, collision };

    pub fn init(m: Value) MapIter {
        std.debug.assert(m.kind() == .persistent_map);
        var iter = MapIter{};
        const h = Heap.asHeapHeader(m);
        const sk = m.subkind();
        switch (sk) {
            subkind_array_map => iter.push(.array_map, h, 0),
            subkind_champ_root => {
                // The CHAMP root's `root_node` is ALWAYS an interior
                // node (never a bare collision): collision nodes only
                // appear as children of an interior at shift ==
                // MAX_TRIE_SHIFT. Single-entry-post-dissoc roots are
                // also wrapped in a single-entry interior at shift 0
                // (champ_root_dissoc single-entry-promotion path).
                const root_body = champRootBodyConst(h);
                iter.push(.champ_interior_data, root_body.root_node, 0);
            },
            else => unreachable,
        }
        return iter;
    }

    fn push(self: *MapIter, kind: FrameKind, node: *HeapHeader, shift: u8) void {
        self.frames[self.depth] = .{ .kind = kind, .node = node, .cursor = 0, .shift = shift };
        self.depth += 1;
    }

    /// Advance; return the next Entry or null when exhausted.
    pub fn next(self: *MapIter) ?Entry {
        while (self.depth > 0) {
            const top = &self.frames[self.depth - 1];
            switch (top.kind) {
                .array_map => {
                    const entries = arrayMapEntries(top.node);
                    if (top.cursor >= entries.len) {
                        self.depth -= 1;
                        continue;
                    }
                    const e = entries[top.cursor];
                    top.cursor += 1;
                    return e;
                },
                .collision => {
                    const entries = collisionEntries(top.node);
                    if (top.cursor >= entries.len) {
                        self.depth -= 1;
                        continue;
                    }
                    const e = entries[top.cursor];
                    top.cursor += 1;
                    return e;
                },
                .champ_interior_data => {
                    const hdr = champInteriorHeaderConst(top.node);
                    const n_data = @as(u32, @popCount(hdr.data_bitmap));
                    if (top.cursor < n_data) {
                        const e = champInteriorEntries(top.node)[top.cursor];
                        top.cursor += 1;
                        return e;
                    }
                    // Switch to children phase.
                    top.kind = .champ_interior_children;
                    top.cursor = 0;
                    continue;
                },
                .champ_interior_children => {
                    const hdr = champInteriorHeaderConst(top.node);
                    const n_children = @as(u32, @popCount(hdr.node_bitmap));
                    if (top.cursor >= n_children) {
                        self.depth -= 1;
                        continue;
                    }
                    const child = champInteriorChildren(top.node)[top.cursor];
                    top.cursor += 1;
                    // Shift-driven child dispatch (peer-AI turn 11):
                    // the current frame's `shift` tells us what this
                    // child IS. If `shift == MAX_TRIE_SHIFT`, child
                    // is a collision node (we've consumed all 32
                    // indexing bits). Otherwise it's another interior
                    // and we descend with `shift + branch_bits`.
                    const parent_shift = top.shift;
                    if (parent_shift >= MAX_TRIE_SHIFT) {
                        self.push(.collision, child, 0); // shift unused for collision frame
                    } else {
                        self.push(.champ_interior_data, child, parent_shift + branch_bits);
                    }
                    continue;
                },
            }
        }
        return null;
    }
};

/// Construct a MapIter (alias — matches the doc's §8 signature for the
/// dispatch-internal iterator).
pub fn mapIter(m: Value) MapIter {
    return MapIter.init(m);
}

// =============================================================================
// =============================================================================
// PART 2 — Persistent set (parallel to persistent_map)
//
// Same subkind taxonomy (0 array-set / 1 CHAMP set root / 2 set
// interior / 3 set collision), same algorithms, same bitmap
// arithmetic, same shift-tracked iterator. Body layouts differ only
// in entry size: 16 bytes per element (a single Value) vs. 32 bytes
// per map entry (key+value Value pair).
//
// The distinction between map and set at the HeapHeader level is
// `h.kind` (Kind.persistent_map vs Kind.persistent_set). User Values
// also carry the kind byte so dispatch is unambiguous. CHAMP.md §3's
// parallel-subkind-numbering discipline means the same subkind byte
// (0..3) means different things under different kind bytes, but the
// meaning is regular across both kinds.
//
// Commits where set shipped: this file's commit 2. Retirement
// receipt: test/prop/hamt.zig S1..S9 (the set-category parallel of
// the map category's M1..M11). After this commit, the three
// equality categories (.sequential / .associative / .set) all have
// concrete runtime members and property-test receipts.
// =============================================================================
// =============================================================================

// -----------------------------------------------------------------------------
// Set body layouts (structurally parallel to map; layout structs
// reused where the header bytes match).
// -----------------------------------------------------------------------------

/// Header of an array-set body. Followed by `count` `Value` elements
/// (16 bytes each). Total body size = 8 + count * 16.
const ArraySetBody = extern struct {
    count: u32,
    _pad: u32,

    comptime {
        std.debug.assert(@sizeOf(ArraySetBody) == 8);
    }
};

// CHAMP set root body: `{ count, _pad, root_node: *HeapHeader }` —
// structurally identical to ChampRootBody; we alias for clarity.
const ChampSetRootBody = ChampRootBody;

// CHAMP set interior header: two u32 bitmaps, identical to
// ChampInteriorHeader.
const SetInteriorHeader = ChampInteriorHeader;

// CHAMP set collision header: shared_hash + count, identical to
// ChampCollisionHeader.
const SetCollisionHeader = ChampCollisionHeader;

// -----------------------------------------------------------------------------
// Set allocation helpers
// -----------------------------------------------------------------------------

fn allocArraySet(heap: *Heap, n: u32) !*HeapHeader {
    std.debug.assert(n <= array_map_max); // same threshold for set
    const body_size = @sizeOf(ArraySetBody) + @as(usize, n) * @sizeOf(Value);
    return heap.alloc(.persistent_set, body_size);
}

fn allocChampSetRoot(heap: *Heap) !*HeapHeader {
    return heap.alloc(.persistent_set, @sizeOf(ChampSetRootBody));
}

fn allocSetInterior(heap: *Heap, elem_count: u32, child_count: u32) !*HeapHeader {
    const elem_bytes = @as(usize, elem_count) * @sizeOf(Value);
    const child_bytes = @as(usize, child_count) * @sizeOf(*HeapHeader);
    const body_size = @sizeOf(SetInteriorHeader) + elem_bytes + child_bytes;
    return heap.alloc(.persistent_set, body_size);
}

fn allocSetCollision(heap: *Heap, n: u32) !*HeapHeader {
    std.debug.assert(n >= 2);
    const body_size = @sizeOf(SetCollisionHeader) + @as(usize, n) * @sizeOf(Value);
    return heap.alloc(.persistent_set, body_size);
}

// -----------------------------------------------------------------------------
// Set body accessors
// -----------------------------------------------------------------------------

fn arraySetBody(h: *HeapHeader) *ArraySetBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(ArraySetBody));
    return @ptrCast(@alignCast(body.ptr));
}

fn arraySetBodyConst(h: *HeapHeader) *const ArraySetBody {
    return arraySetBody(h);
}

fn arraySetElements(h: *HeapHeader) []Value {
    const body = Heap.bodyBytes(h);
    const n = arraySetBodyConst(h).count;
    std.debug.assert(body.len == @sizeOf(ArraySetBody) + @as(usize, n) * @sizeOf(Value));
    const elems_ptr: [*]Value = @ptrCast(@alignCast(body.ptr + @sizeOf(ArraySetBody)));
    return elems_ptr[0..n];
}

fn champSetRootBody(h: *HeapHeader) *ChampSetRootBody {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == @sizeOf(ChampSetRootBody));
    return @ptrCast(@alignCast(body.ptr));
}

fn champSetRootBodyConst(h: *HeapHeader) *const ChampSetRootBody {
    return champSetRootBody(h);
}

fn setInteriorHeader(h: *HeapHeader) *SetInteriorHeader {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(SetInteriorHeader));
    return @ptrCast(@alignCast(body.ptr));
}

fn setInteriorHeaderConst(h: *HeapHeader) *const SetInteriorHeader {
    return setInteriorHeader(h);
}

fn setInteriorElements(h: *HeapHeader) []Value {
    const hdr = setInteriorHeaderConst(h);
    const n = @popCount(hdr.data_bitmap);
    const body = Heap.bodyBytes(h);
    const elems_ptr: [*]Value = @ptrCast(@alignCast(body.ptr + @sizeOf(SetInteriorHeader)));
    return elems_ptr[0..n];
}

fn setInteriorChildren(h: *HeapHeader) []*HeapHeader {
    const hdr = setInteriorHeaderConst(h);
    const n_elems = @popCount(hdr.data_bitmap);
    const n_children = @popCount(hdr.node_bitmap);
    const body = Heap.bodyBytes(h);
    const elems_bytes = @as(usize, n_elems) * @sizeOf(Value);
    const children_ptr: [*]*HeapHeader = @ptrCast(@alignCast(body.ptr + @sizeOf(SetInteriorHeader) + elems_bytes));
    return children_ptr[0..n_children];
}

fn setCollisionHeader(h: *HeapHeader) *SetCollisionHeader {
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(SetCollisionHeader));
    return @ptrCast(@alignCast(body.ptr));
}

fn setCollisionHeaderConst(h: *HeapHeader) *const SetCollisionHeader {
    return setCollisionHeader(h);
}

fn setCollisionElements(h: *HeapHeader) []Value {
    const hdr = setCollisionHeaderConst(h);
    const body = Heap.bodyBytes(h);
    std.debug.assert(body.len == @sizeOf(SetCollisionHeader) + @as(usize, hdr.count) * @sizeOf(Value));
    const elems_ptr: [*]Value = @ptrCast(@alignCast(body.ptr + @sizeOf(SetCollisionHeader)));
    return elems_ptr[0..hdr.count];
}

// -----------------------------------------------------------------------------
// Set Value packing
// -----------------------------------------------------------------------------

fn valueFromArraySet(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_set)) | (@as(u64, subkind_array_map) << 16),
        .payload = @intFromPtr(h),
    };
}

fn valueFromChampSetRoot(h: *HeapHeader) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_set)) | (@as(u64, subkind_champ_root) << 16),
        .payload = @intFromPtr(h),
    };
}

/// Resolve a user-facing set Value to its backing header. Asserts the
/// top-level subkind discipline: user-facing sets are subkind 0 or 1;
/// subkinds 2/3 are internal and never appear in a user Value.
fn setHeader(v: Value) *HeapHeader {
    std.debug.assert(v.kind() == .persistent_set);
    const sk = v.subkind();
    std.debug.assert(sk == subkind_array_map or sk == subkind_champ_root);
    return Heap.asHeapHeader(v);
}

// -----------------------------------------------------------------------------
// Public API — construction and query (set)
// -----------------------------------------------------------------------------

/// Fresh empty set. Subkind 0 with count 0. Not a shared singleton.
pub fn setEmpty(heap: *Heap) !Value {
    const h = try allocArraySet(heap, 0);
    const body = arraySetBody(h);
    body.count = 0;
    body._pad = 0;
    return valueFromArraySet(h);
}

/// Build a set from an element slice. Duplicate elements are
/// deduplicated naturally via `setConj`'s same-element short-circuit
/// (pointer-identity preserved on duplicate) and membership check.
pub fn setFromElements(
    heap: *Heap,
    elems: []const Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    var result = try setEmpty(heap);
    for (elems) |e| {
        result = try setConj(heap, result, e, elementHash, elementEq);
    }
    return result;
}

pub fn setCount(s: Value) usize {
    const h = setHeader(s);
    return switch (s.subkind()) {
        subkind_array_map => arraySetBodyConst(h).count,
        subkind_champ_root => champSetRootBodyConst(h).count,
        else => unreachable,
    };
}

pub fn setIsEmpty(s: Value) bool {
    return setCount(s) == 0;
}

/// Membership check. Returns true iff `elem` is present in `s`.
/// Nil-safe: setContains(#{}, nil) returns false, setContains(#{nil}, nil)
/// returns true. Unlike map's `get`, no union wrapper is needed — the
/// return is a plain bool because presence is the ONLY information a
/// set carries about an element.
pub fn setContains(
    s: Value,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) bool {
    const h = setHeader(s);
    return switch (s.subkind()) {
        subkind_array_map => arraySetContains(h, elem, elementEq),
        subkind_champ_root => champSetContains(
            champSetRootBodyConst(h).root_node,
            elem,
            indexHashOf(elem, elementHash),
            0,
            elementEq,
        ),
        else => unreachable,
    };
}

/// Add `elem` to `s`, returning a new persistent set. Semantics:
///   - elem already present → return `s` unchanged (pointer identity).
///   - elem absent, count < 8 at array-set → extend array-set.
///   - elem absent, count == 8 at array-set → promote to CHAMP.
///   - CHAMP path → recursive path-copy.
pub fn setConj(
    heap: *Heap,
    s: Value,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const h = setHeader(s);
    return switch (s.subkind()) {
        subkind_array_map => arraySetConj(heap, s, h, elem, elementHash, elementEq),
        subkind_champ_root => champSetRootConj(heap, s, h, elem, elementHash, elementEq),
        else => unreachable,
    };
}

/// Remove `elem` from `s`, returning a new persistent set. Semantics
/// parallel to `mapDissoc`: absent → return unchanged; present →
/// return a new set with one fewer element. Single-entry-subtree
/// promotion + no-demotion + empty-collapse rules all apply (CHAMP.md
/// §5.4–§5.6).
pub fn setDisj(
    heap: *Heap,
    s: Value,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const h = setHeader(s);
    return switch (s.subkind()) {
        subkind_array_map => arraySetDisj(heap, s, h, elem, elementEq),
        subkind_champ_root => champSetRootDisj(heap, s, h, elem, elementHash, elementEq),
        else => unreachable,
    };
}

// -----------------------------------------------------------------------------
// Array-set operations (subkind 0)
// -----------------------------------------------------------------------------

fn arraySetContains(
    h: *HeapHeader,
    elem: Value,
    elementEq: *const fn (Value, Value) bool,
) bool {
    const elems = arraySetElements(h);
    for (elems) |e| {
        if (keyEquivalent(e, elem, elementEq)) return true;
    }
    return false;
}

fn arraySetFindElemIndex(
    h: *HeapHeader,
    elem: Value,
    elementEq: *const fn (Value, Value) bool,
) ?usize {
    const elems = arraySetElements(h);
    for (elems, 0..) |e, i| {
        if (keyEquivalent(e, elem, elementEq)) return i;
    }
    return null;
}

fn arraySetConj(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const src_elems = arraySetElements(src_h);
    // Already present → same pointer.
    if (arraySetFindElemIndex(src_h, elem, elementEq) != null) {
        return src_v;
    }
    // Absent: grow or promote.
    if (src_elems.len < array_map_max) {
        const new_count: u32 = @as(u32, @intCast(src_elems.len)) + 1;
        const new_h = try allocArraySet(heap, new_count);
        const new_body = arraySetBody(new_h);
        new_body.count = new_count;
        new_body._pad = 0;
        const new_elems = arraySetElements(new_h);
        @memcpy(new_elems[0..src_elems.len], src_elems);
        new_elems[src_elems.len] = elem;
        return valueFromArraySet(new_h);
    }
    // Promotion: count == 8, new element → CHAMP.
    std.debug.assert(src_elems.len == array_map_max);
    return arraySetPromoteAndConj(heap, src_elems, elem, elementHash, elementEq);
}

fn arraySetDisj(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    elem: Value,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const idx_opt = arraySetFindElemIndex(src_h, elem, elementEq);
    if (idx_opt == null) return src_v;

    const idx = idx_opt.?;
    const src_elems = arraySetElements(src_h);
    const new_count: u32 = @as(u32, @intCast(src_elems.len)) - 1;
    const new_h = try allocArraySet(heap, new_count);
    const new_body = arraySetBody(new_h);
    new_body.count = new_count;
    new_body._pad = 0;
    const new_elems = arraySetElements(new_h);
    if (idx > 0) @memcpy(new_elems[0..idx], src_elems[0..idx]);
    if (idx < src_elems.len - 1) {
        @memcpy(new_elems[idx..], src_elems[idx + 1 ..]);
    }
    return valueFromArraySet(new_h);
}

/// Array-set → CHAMP promotion. Entry count is 8, adding 9th distinct
/// element. Rehash all 9 into a single CHAMP interior (recursively
/// splitting as hash prefixes demand), wrap in CHAMP root.
fn arraySetPromoteAndConj(
    heap: *Heap,
    existing: []const Value,
    new_elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    std.debug.assert(existing.len == array_map_max);
    const first = existing[0];
    var root_node = try champSetSingleEntryInterior(heap, first, indexHashOf(first, elementHash), 0);
    var count: u32 = 1;
    for (existing[1..]) |e| {
        const res = try champSetConjInNode(heap, root_node, e, indexHashOf(e, elementHash), 0, elementHash, elementEq);
        root_node = res.node;
        if (res.added) count += 1;
    }
    const res = try champSetConjInNode(heap, root_node, new_elem, indexHashOf(new_elem, elementHash), 0, elementHash, elementEq);
    root_node = res.node;
    if (res.added) count += 1;
    const root_h = try allocChampSetRoot(heap);
    const root_body = champSetRootBody(root_h);
    root_body.count = count;
    root_body._pad = 0;
    root_body.root_node = root_node;
    return valueFromChampSetRoot(root_h);
}

// -----------------------------------------------------------------------------
// CHAMP set root operations (subkind 1)
// -----------------------------------------------------------------------------

fn champSetRootConj(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const src_body = champSetRootBodyConst(src_h);
    const hash32 = indexHashOf(elem, elementHash);
    const res = try champSetConjInNode(heap, src_body.root_node, elem, hash32, 0, elementHash, elementEq);
    if (res.node == src_body.root_node and !res.added) {
        // Same-pointer short-circuit (elem already present).
        return src_v;
    }
    const new_h = try allocChampSetRoot(heap);
    const new_body = champSetRootBody(new_h);
    new_body.count = if (res.added) src_body.count + 1 else src_body.count;
    new_body._pad = 0;
    new_body.root_node = res.node;
    return valueFromChampSetRoot(new_h);
}

fn champSetRootDisj(
    heap: *Heap,
    src_v: Value,
    src_h: *HeapHeader,
    elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value {
    const src_body = champSetRootBodyConst(src_h);
    const hash32 = indexHashOf(elem, elementHash);
    const res = try champSetDisjFromNode(heap, src_body.root_node, elem, hash32, 0, elementEq);
    if (!res.removed) return src_v;
    const new_count = src_body.count - 1;
    if (new_count == 0) {
        // §5.6 parallel: empty result collapses to subkind-0 empty array-set.
        return setEmpty(heap);
    }
    const new_root_node: *HeapHeader = if (res.promoted_single) |pulled| blk: {
        break :blk try champSetSingleEntryInterior(heap, pulled, indexHashOf(pulled, elementHash), 0);
    } else blk: {
        std.debug.assert(res.node != null);
        break :blk res.node.?;
    };
    const new_h = try allocChampSetRoot(heap);
    const new_body = champSetRootBody(new_h);
    new_body.count = new_count;
    new_body._pad = 0;
    new_body.root_node = new_root_node;
    return valueFromChampSetRoot(new_h);
}

// -----------------------------------------------------------------------------
// CHAMP set internal ops (recursive)
// -----------------------------------------------------------------------------

const SetConjResult = struct {
    node: *HeapHeader,
    added: bool, // new element inserted
};

const SetDisjResult = struct {
    node: ?*HeapHeader,
    promoted_single: ?Value = null,
    removed: bool,
};

fn champSetSingleEntryInterior(
    heap: *Heap,
    elem: Value,
    hash32: u32,
    shift: u8,
) !*HeapHeader {
    std.debug.assert(shift <= MAX_TRIE_SHIFT);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const h = try allocSetInterior(heap, 1, 0);
    const hdr = setInteriorHeader(h);
    hdr.data_bitmap = @as(u32, 1) << @intCast(slot);
    hdr.node_bitmap = 0;
    const elems = setInteriorElements(h);
    elems[0] = elem;
    return h;
}

fn champSetTwoEntryInterior(
    heap: *Heap,
    e1: Value,
    slot1: u32,
    e2: Value,
    slot2: u32,
) !*HeapHeader {
    std.debug.assert(slot1 != slot2);
    const h = try allocSetInterior(heap, 2, 0);
    const hdr = setInteriorHeader(h);
    hdr.data_bitmap = (@as(u32, 1) << @intCast(slot1)) | (@as(u32, 1) << @intCast(slot2));
    hdr.node_bitmap = 0;
    const elems = setInteriorElements(h);
    if (slot1 < slot2) {
        elems[0] = e1;
        elems[1] = e2;
    } else {
        elems[0] = e2;
        elems[1] = e1;
    }
    return h;
}

fn champSetSingleChildInterior(
    heap: *Heap,
    slot: u32,
    child: *HeapHeader,
) !*HeapHeader {
    const h = try allocSetInterior(heap, 0, 1);
    const hdr = setInteriorHeader(h);
    hdr.data_bitmap = 0;
    hdr.node_bitmap = @as(u32, 1) << @intCast(slot);
    const children = setInteriorChildren(h);
    children[0] = child;
    return h;
}

fn setCollisionOfTwo(
    heap: *Heap,
    e1: Value,
    e2: Value,
    shared_hash: u32,
) !*HeapHeader {
    const h = try allocSetCollision(heap, 2);
    const hdr = setCollisionHeader(h);
    hdr.shared_hash = shared_hash;
    hdr.count = 2;
    const elems = setCollisionElements(h);
    elems[0] = e1;
    elems[1] = e2;
    return h;
}

fn champSetBuildTwoEntrySubtree(
    heap: *Heap,
    e1: Value,
    hash1: u32,
    e2: Value,
    hash2: u32,
    shift: u8,
) !*HeapHeader {
    if (shift > MAX_TRIE_SHIFT) {
        std.debug.assert(hash1 == hash2);
        return setCollisionOfTwo(heap, e1, e2, hash1);
    }
    const s1: u32 = (hash1 >> @intCast(shift)) & branch_mask;
    const s2: u32 = (hash2 >> @intCast(shift)) & branch_mask;
    if (s1 != s2) {
        return champSetTwoEntryInterior(heap, e1, s1, e2, s2);
    }
    const next_shift: u8 = shift + branch_bits;
    const child = try champSetBuildTwoEntrySubtree(heap, e1, hash1, e2, hash2, next_shift);
    return champSetSingleChildInterior(heap, s1, child);
}

// ---- Contains ----

fn champSetContains(
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    shift: u8,
    elementEq: *const fn (Value, Value) bool,
) bool {
    if (shift > MAX_TRIE_SHIFT) {
        return setCollisionContains(node, elem, hash32, elementEq);
    }
    return champSetInteriorContains(node, elem, hash32, shift, elementEq);
}

fn champSetInteriorContains(
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    shift: u8,
    elementEq: *const fn (Value, Value) bool,
) bool {
    std.debug.assert(shift <= MAX_TRIE_SHIFT);
    const hdr = setInteriorHeaderConst(node);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    if ((hdr.data_bitmap & slot_bit) != 0) {
        const idx = dataIndex(hdr.data_bitmap, slot);
        return keyEquivalent(setInteriorElements(node)[idx], elem, elementEq);
    }
    if ((hdr.node_bitmap & slot_bit) != 0) {
        const child_idx = childIndex(hdr.node_bitmap, slot);
        const child = setInteriorChildren(node)[child_idx];
        const next_shift: u8 = shift + branch_bits;
        return champSetContains(child, elem, hash32, next_shift, elementEq);
    }
    return false;
}

fn setCollisionContains(
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    elementEq: *const fn (Value, Value) bool,
) bool {
    const hdr = setCollisionHeaderConst(node);
    if (hdr.shared_hash != hash32) return false;
    const elems = setCollisionElements(node);
    for (elems) |e| {
        if (keyEquivalent(e, elem, elementEq)) return true;
    }
    return false;
}

// ---- Conj (add) ----

fn champSetConjInNode(
    heap: *Heap,
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    shift: u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !SetConjResult {
    if (shift > MAX_TRIE_SHIFT) {
        return setCollisionConj(heap, node, elem, hash32, elementEq);
    }
    const hdr = setInteriorHeaderConst(node);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);

    if ((hdr.data_bitmap & slot_bit) != 0) {
        const data_idx = dataIndex(hdr.data_bitmap, slot);
        const existing = setInteriorElements(node)[data_idx];
        if (keyEquivalent(existing, elem, elementEq)) {
            // Already present — same pointer.
            return .{ .node = node, .added = false };
        }
        // Different element, same slot — split into subtree.
        const existing_hash = indexHashOf(existing, elementHash);
        const next_shift: u8 = shift + branch_bits;
        const subtree = try champSetBuildTwoEntrySubtree(heap, existing, existing_hash, elem, hash32, next_shift);
        const new_node = try cloneSetInteriorMigrateDataToChild(heap, node, slot, data_idx, subtree);
        return .{ .node = new_node, .added = true };
    }

    if ((hdr.node_bitmap & slot_bit) != 0) {
        const child_idx = childIndex(hdr.node_bitmap, slot);
        const child = setInteriorChildren(node)[child_idx];
        const next_shift: u8 = shift + branch_bits;
        const sub = try champSetConjInNode(heap, child, elem, hash32, next_shift, elementHash, elementEq);
        if (sub.node == child) {
            return .{ .node = node, .added = sub.added };
        }
        const new_node = try cloneSetInteriorReplaceChild(heap, node, child_idx, sub.node);
        return .{ .node = new_node, .added = sub.added };
    }

    // Empty slot — insert inline.
    const new_node = try cloneSetInteriorInsertElement(heap, node, slot, elem);
    return .{ .node = new_node, .added = true };
}

fn setCollisionConj(
    heap: *Heap,
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    elementEq: *const fn (Value, Value) bool,
) !SetConjResult {
    const hdr = setCollisionHeaderConst(node);
    std.debug.assert(hdr.shared_hash == hash32);
    const elems = setCollisionElements(node);
    for (elems) |e| {
        if (keyEquivalent(e, elem, elementEq)) {
            return .{ .node = node, .added = false };
        }
    }
    const new_h = try allocSetCollision(heap, hdr.count + 1);
    const new_hdr = setCollisionHeader(new_h);
    new_hdr.shared_hash = hash32;
    new_hdr.count = hdr.count + 1;
    const new_elems = setCollisionElements(new_h);
    @memcpy(new_elems[0..elems.len], elems);
    new_elems[elems.len] = elem;
    return .{ .node = new_h, .added = true };
}

// ---- Disj (remove) ----

fn champSetDisjFromNode(
    heap: *Heap,
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    shift: u8,
    elementEq: *const fn (Value, Value) bool,
) !SetDisjResult {
    if (shift > MAX_TRIE_SHIFT) {
        return setCollisionDisj(heap, node, elem, hash32, elementEq);
    }
    const hdr = setInteriorHeaderConst(node);
    const slot: u32 = (hash32 >> @intCast(shift)) & branch_mask;
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);

    if ((hdr.data_bitmap & slot_bit) != 0) {
        const data_idx = dataIndex(hdr.data_bitmap, slot);
        const existing = setInteriorElements(node)[data_idx];
        if (!keyEquivalent(existing, elem, elementEq)) {
            return .{ .node = node, .removed = false };
        }
        // Remove this element. Does node collapse?
        const new_entry_count = @popCount(hdr.data_bitmap) - 1;
        const new_child_count = @popCount(hdr.node_bitmap);
        if (new_entry_count == 0 and new_child_count == 0) {
            return .{ .node = null, .removed = true };
        }
        if (new_entry_count == 1 and new_child_count == 0) {
            const elems = setInteriorElements(node);
            const sole = if (data_idx == 0) elems[1] else elems[0];
            return .{ .node = null, .promoted_single = sole, .removed = true };
        }
        const new_node = try cloneSetInteriorRemoveElement(heap, node, slot, data_idx);
        return .{ .node = new_node, .removed = true };
    }

    if ((hdr.node_bitmap & slot_bit) != 0) {
        const child_idx = childIndex(hdr.node_bitmap, slot);
        const child = setInteriorChildren(node)[child_idx];
        const next_shift: u8 = shift + branch_bits;
        const sub = try champSetDisjFromNode(heap, child, elem, hash32, next_shift, elementEq);
        if (!sub.removed) {
            return .{ .node = node, .removed = false };
        }
        if (sub.promoted_single) |pulled| {
            const new_node = try cloneSetInteriorMigrateChildToData(heap, node, slot, child_idx, pulled);
            return .{ .node = new_node, .removed = true };
        }
        if (sub.node == null) {
            return try champSetInteriorDropChildAt(heap, node, slot, child_idx);
        }
        const new_node = try cloneSetInteriorReplaceChild(heap, node, child_idx, sub.node.?);
        return .{ .node = new_node, .removed = true };
    }

    return .{ .node = node, .removed = false };
}

fn champSetInteriorDropChildAt(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    child_idx: usize,
) !SetDisjResult {
    const src_hdr = setInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    const src_elems = setInteriorElements(src);
    const src_children = setInteriorChildren(src);
    const new_entry_count = src_elems.len;
    const new_child_count = src_children.len - 1;
    if (new_entry_count == 0 and new_child_count == 0) {
        return .{ .node = null, .removed = true };
    }
    if (new_entry_count == 1 and new_child_count == 0) {
        return .{ .node = null, .promoted_single = src_elems[0], .removed = true };
    }
    const new_h = try allocSetInterior(
        heap,
        @intCast(new_entry_count),
        @intCast(new_child_count),
    );
    const new_hdr = setInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap;
    new_hdr.node_bitmap = src_hdr.node_bitmap & ~slot_bit;
    const new_elems = setInteriorElements(new_h);
    @memcpy(new_elems, src_elems);
    const new_children = setInteriorChildren(new_h);
    if (child_idx > 0) @memcpy(new_children[0..child_idx], src_children[0..child_idx]);
    if (child_idx < src_children.len - 1) {
        @memcpy(new_children[child_idx..], src_children[child_idx + 1 ..]);
    }
    return .{ .node = new_h, .removed = true };
}

fn setCollisionDisj(
    heap: *Heap,
    node: *HeapHeader,
    elem: Value,
    hash32: u32,
    elementEq: *const fn (Value, Value) bool,
) !SetDisjResult {
    const hdr = setCollisionHeaderConst(node);
    if (hdr.shared_hash != hash32) {
        return .{ .node = node, .removed = false };
    }
    const elems = setCollisionElements(node);
    for (elems, 0..) |e, i| {
        if (keyEquivalent(e, elem, elementEq)) {
            if (hdr.count == 2) {
                const sole = if (i == 0) elems[1] else elems[0];
                return .{ .node = null, .promoted_single = sole, .removed = true };
            }
            const new_h = try allocSetCollision(heap, hdr.count - 1);
            const new_hdr = setCollisionHeader(new_h);
            new_hdr.shared_hash = hash32;
            new_hdr.count = hdr.count - 1;
            const new_elems = setCollisionElements(new_h);
            if (i > 0) @memcpy(new_elems[0..i], elems[0..i]);
            if (i < elems.len - 1) @memcpy(new_elems[i..], elems[i + 1 ..]);
            return .{ .node = new_h, .removed = true };
        }
    }
    return .{ .node = node, .removed = false };
}

// -----------------------------------------------------------------------------
// CHAMP set clone helpers (path-copy primitives, parallel to map)
// -----------------------------------------------------------------------------

fn cloneSetInteriorReplaceChild(
    heap: *Heap,
    src: *HeapHeader,
    child_idx: usize,
    new_child: *HeapHeader,
) !*HeapHeader {
    const src_hdr = setInteriorHeaderConst(src);
    const src_elems = setInteriorElements(src);
    const src_children = setInteriorChildren(src);
    const new_h = try allocSetInterior(
        heap,
        @intCast(src_elems.len),
        @intCast(src_children.len),
    );
    const new_hdr = setInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_elems = setInteriorElements(new_h);
    @memcpy(new_elems, src_elems);
    const new_children = setInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    new_children[child_idx] = new_child;
    return new_h;
}

fn cloneSetInteriorInsertElement(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    new_elem: Value,
) !*HeapHeader {
    const src_hdr = setInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) == 0);
    std.debug.assert((src_hdr.node_bitmap & slot_bit) == 0);
    const src_elems = setInteriorElements(src);
    const src_children = setInteriorChildren(src);
    const insert_at = dataIndex(src_hdr.data_bitmap, slot);
    const new_h = try allocSetInterior(
        heap,
        @intCast(src_elems.len + 1),
        @intCast(src_children.len),
    );
    const new_hdr = setInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap | slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_elems = setInteriorElements(new_h);
    if (insert_at > 0) @memcpy(new_elems[0..insert_at], src_elems[0..insert_at]);
    new_elems[insert_at] = new_elem;
    if (insert_at < src_elems.len) {
        @memcpy(new_elems[insert_at + 1 ..], src_elems[insert_at..]);
    }
    const new_children = setInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    return new_h;
}

fn cloneSetInteriorMigrateDataToChild(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    data_idx: usize,
    new_child: *HeapHeader,
) !*HeapHeader {
    const src_hdr = setInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) != 0);
    std.debug.assert((src_hdr.node_bitmap & slot_bit) == 0);
    const src_elems = setInteriorElements(src);
    const src_children = setInteriorChildren(src);
    const new_h = try allocSetInterior(
        heap,
        @intCast(src_elems.len - 1),
        @intCast(src_children.len + 1),
    );
    const new_hdr = setInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap & ~slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap | slot_bit;
    const new_elems = setInteriorElements(new_h);
    if (data_idx > 0) @memcpy(new_elems[0..data_idx], src_elems[0..data_idx]);
    if (data_idx < src_elems.len - 1) {
        @memcpy(new_elems[data_idx..], src_elems[data_idx + 1 ..]);
    }
    const child_insert_at = childIndex(new_hdr.node_bitmap, slot);
    const new_children = setInteriorChildren(new_h);
    if (child_insert_at > 0) @memcpy(new_children[0..child_insert_at], src_children[0..child_insert_at]);
    new_children[child_insert_at] = new_child;
    if (child_insert_at < src_children.len) {
        @memcpy(new_children[child_insert_at + 1 ..], src_children[child_insert_at..]);
    }
    return new_h;
}

fn cloneSetInteriorRemoveElement(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    data_idx: usize,
) !*HeapHeader {
    const src_hdr = setInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) != 0);
    const src_elems = setInteriorElements(src);
    const src_children = setInteriorChildren(src);
    const new_h = try allocSetInterior(
        heap,
        @intCast(src_elems.len - 1),
        @intCast(src_children.len),
    );
    const new_hdr = setInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap & ~slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap;
    const new_elems = setInteriorElements(new_h);
    if (data_idx > 0) @memcpy(new_elems[0..data_idx], src_elems[0..data_idx]);
    if (data_idx < src_elems.len - 1) {
        @memcpy(new_elems[data_idx..], src_elems[data_idx + 1 ..]);
    }
    const new_children = setInteriorChildren(new_h);
    @memcpy(new_children, src_children);
    return new_h;
}

fn cloneSetInteriorMigrateChildToData(
    heap: *Heap,
    src: *HeapHeader,
    slot: u32,
    child_idx: usize,
    pulled_elem: Value,
) !*HeapHeader {
    const src_hdr = setInteriorHeaderConst(src);
    const slot_bit: u32 = @as(u32, 1) << @intCast(slot);
    std.debug.assert((src_hdr.node_bitmap & slot_bit) != 0);
    std.debug.assert((src_hdr.data_bitmap & slot_bit) == 0);
    const src_elems = setInteriorElements(src);
    const src_children = setInteriorChildren(src);
    const new_h = try allocSetInterior(
        heap,
        @intCast(src_elems.len + 1),
        @intCast(src_children.len - 1),
    );
    const new_hdr = setInteriorHeader(new_h);
    new_hdr.data_bitmap = src_hdr.data_bitmap | slot_bit;
    new_hdr.node_bitmap = src_hdr.node_bitmap & ~slot_bit;
    const entry_insert_at = dataIndex(new_hdr.data_bitmap, slot);
    const new_elems = setInteriorElements(new_h);
    if (entry_insert_at > 0) @memcpy(new_elems[0..entry_insert_at], src_elems[0..entry_insert_at]);
    new_elems[entry_insert_at] = pulled_elem;
    if (entry_insert_at < src_elems.len) {
        @memcpy(new_elems[entry_insert_at + 1 ..], src_elems[entry_insert_at..]);
    }
    const new_children = setInteriorChildren(new_h);
    if (child_idx > 0) @memcpy(new_children[0..child_idx], src_children[0..child_idx]);
    if (child_idx < src_children.len - 1) {
        @memcpy(new_children[child_idx..], src_children[child_idx + 1 ..]);
    }
    return new_h;
}

// -----------------------------------------------------------------------------
// Set dispatch entry points (parallel to hashMap / equalMap)
// -----------------------------------------------------------------------------

pub fn hashSet(h: *HeapHeader, elementHash: *const fn (Value) u64) u64 {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.persistent_set));
    }
    if (h.cachedHash()) |cached| {
        return @as(u64, cached);
    }
    var acc: u64 = hash_mod.unordered_init;
    var count_seen: usize = 0;
    const root_v: Value = .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_set)) | (@as(u64, inferSetRootSubkind(h)) << 16),
        .payload = @intFromPtr(h),
    };
    var iter = setIter(root_v);
    while (iter.next()) |e| {
        // Set aggregate hash: SEMANTICS §3.2 — unordered combine of
        // each element's full `dispatch.hashValue` (which is what
        // elementHash delivers). No inner wrap, no finalize per
        // element; only the outer unordered combine + finalize.
        acc = hash_mod.combineUnordered(acc, elementHash(e));
        count_seen += 1;
    }
    const finalized = hash_mod.finalizeUnordered(acc, count_seen);
    const truncated: u32 = @truncate(finalized);
    if (truncated != 0) h.setCachedHash(truncated);
    return @as(u64, truncated);
}

/// Infer subkind of a user-facing set root header. Disjoint-set
/// discipline parallel to `inferRootSubkind` for maps:
///   - subkind-0 (array-set) body size: 8 + n*16 for n ∈ [0, 8]
///     = {8, 24, 40, 56, 72, 88, 104, 120, 136}
///   - subkind-1 (CHAMP set root) body size: exactly 16
/// 16 ∉ {8, 24, 40, …, 136}, unambiguous. Safe-build asserts the
/// body size matches a known shape.
fn inferSetRootSubkind(h: *HeapHeader) u16 {
    const body_size = Heap.bodyBytes(h).len;
    if (body_size == @sizeOf(ChampSetRootBody)) return subkind_champ_root;
    if (std.debug.runtime_safety) {
        const header_bytes = @sizeOf(ArraySetBody);
        const valid = body_size >= header_bytes and
            (body_size - header_bytes) % @sizeOf(Value) == 0 and
            (body_size - header_bytes) / @sizeOf(Value) <= array_map_max;
        if (!valid) {
            std.debug.panic(
                "hamt.inferSetRootSubkind: body size {d} does not match any valid user-facing set subkind (array-set 8..136 step 16, or CHAMP set root 16). Possible internal-node leak or memory corruption.",
                .{body_size},
            );
        }
    }
    return subkind_array_map;
}

/// Same-kind structural equality for sets. Handles all four subkind-
/// pair combinations via the semantic-set strategy: count match, then
/// iterate the side with the smaller/cheaper iteration, `setContains`-
/// check each element into the other. Works uniformly regardless of
/// whether either or both sides are array-set or CHAMP.
pub fn equalSet(
    a: *HeapHeader,
    b: *HeapHeader,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) bool {
    if (std.debug.runtime_safety) {
        std.debug.assert(a.kind == @intFromEnum(Kind.persistent_set));
        std.debug.assert(b.kind == @intFromEnum(Kind.persistent_set));
    }
    if (a == b) return true;

    const sk_a = inferSetRootSubkind(a);
    const sk_b = inferSetRootSubkind(b);

    const count_a = if (sk_a == subkind_array_map) arraySetBodyConst(a).count else champSetRootBodyConst(a).count;
    const count_b = if (sk_b == subkind_array_map) arraySetBodyConst(b).count else champSetRootBodyConst(b).count;
    if (count_a != count_b) return false;

    const a_val: Value = .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_set)) | (@as(u64, sk_a) << 16),
        .payload = @intFromPtr(a),
    };
    const b_val: Value = .{
        .tag = @as(u64, @intFromEnum(Kind.persistent_set)) | (@as(u64, sk_b) << 16),
        .payload = @intFromPtr(b),
    };
    var iter = setIter(a_val);
    while (iter.next()) |e| {
        if (!setContains(b_val, e, elementHash, elementEq)) return false;
    }
    return true;
}

// -----------------------------------------------------------------------------
// SetIter — walks every element of a user-facing set Value.
//
// Structurally parallel to MapIter, returning Value per element
// rather than Entry per (k, v) pair. Shift-tracked frames for
// deterministic interior/collision dispatch (same discipline).
// -----------------------------------------------------------------------------

pub const SetIter = struct {
    frames: [16]Frame = undefined,
    depth: u8 = 0,

    const Frame = struct {
        kind: FrameKind,
        node: *HeapHeader,
        cursor: u32,
        shift: u8 = 0,
    };

    const FrameKind = enum { array_set, set_interior_data, set_interior_children, set_collision };

    pub fn init(s: Value) SetIter {
        std.debug.assert(s.kind() == .persistent_set);
        var iter = SetIter{};
        const h = Heap.asHeapHeader(s);
        const sk = s.subkind();
        switch (sk) {
            subkind_array_map => iter.push(.array_set, h, 0),
            subkind_champ_root => {
                const root_body = champSetRootBodyConst(h);
                iter.push(.set_interior_data, root_body.root_node, 0);
            },
            else => unreachable,
        }
        return iter;
    }

    fn push(self: *SetIter, kind: FrameKind, node: *HeapHeader, shift: u8) void {
        self.frames[self.depth] = .{ .kind = kind, .node = node, .cursor = 0, .shift = shift };
        self.depth += 1;
    }

    pub fn next(self: *SetIter) ?Value {
        while (self.depth > 0) {
            const top = &self.frames[self.depth - 1];
            switch (top.kind) {
                .array_set => {
                    const elems = arraySetElements(top.node);
                    if (top.cursor >= elems.len) {
                        self.depth -= 1;
                        continue;
                    }
                    const e = elems[top.cursor];
                    top.cursor += 1;
                    return e;
                },
                .set_collision => {
                    const elems = setCollisionElements(top.node);
                    if (top.cursor >= elems.len) {
                        self.depth -= 1;
                        continue;
                    }
                    const e = elems[top.cursor];
                    top.cursor += 1;
                    return e;
                },
                .set_interior_data => {
                    const hdr = setInteriorHeaderConst(top.node);
                    const n_data = @as(u32, @popCount(hdr.data_bitmap));
                    if (top.cursor < n_data) {
                        const e = setInteriorElements(top.node)[top.cursor];
                        top.cursor += 1;
                        return e;
                    }
                    top.kind = .set_interior_children;
                    top.cursor = 0;
                    continue;
                },
                .set_interior_children => {
                    const hdr = setInteriorHeaderConst(top.node);
                    const n_children = @as(u32, @popCount(hdr.node_bitmap));
                    if (top.cursor >= n_children) {
                        self.depth -= 1;
                        continue;
                    }
                    const child = setInteriorChildren(top.node)[top.cursor];
                    top.cursor += 1;
                    const parent_shift = top.shift;
                    if (parent_shift >= MAX_TRIE_SHIFT) {
                        self.push(.set_collision, child, 0);
                    } else {
                        self.push(.set_interior_data, child, parent_shift + branch_bits);
                    }
                    continue;
                },
            }
        }
        return null;
    }
};

pub fn setIter(s: Value) SetIter {
    return SetIter.init(s);
}

// =============================================================================
// Inline tests
//
// Unit-level invariants + trap coverage. Property tests live in
// test/prop/hamt.zig.
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
        else => false,
    };
}

/// Hash-colliding synthetic for collision-node tests.
///
/// Contract: pins the **low 32 bits** of every output to `0xDEAD_BEEF`.
/// The high 32 bits vary by input (derived from the input's own
/// hashImmediate).
///
/// Why this is the right fixture: `indexHash` (§5.1) truncates to low
/// 32 bits. A fixture that varied the low 32 bits but pinned the high
/// 32 bits would not collide — CHAMP would partition keys cleanly
/// through the trie. Only fixing the low 32 bits forces every distinct
/// key to the same slot at every trie level and ultimately into a
/// single collision node at MAX_TRIE_SHIFT.
///
/// DO NOT "optimize" this to a constant u64 — the high 32 bits must
/// stay input-dependent so the full `dispatch.hashValue` pipeline
/// (which IS used when this fixture feeds into entry_hash for map
/// contents, not here) still produces distinct hashes for distinct
/// entries. The pattern here is specifically for keys routed through
/// hamt's indexHash + elementEq side-channel.
fn collidingHash(x: Value) u64 {
    return (@as(u64, x.hashImmediate() >> 32) << 32) | 0xDEAD_BEEF;
}

// ---- Body layout tests ----

test "Entry layout: 32 bytes, key at 0, value at 16" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Entry));
    try testing.expectEqual(@as(usize, 0), @offsetOf(Entry, "key"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Entry, "value"));
}

test "ChampRootBody layout: 16 bytes total" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(ChampRootBody));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ChampRootBody, "count"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ChampRootBody, "root_node"));
}

// ---- mapEmpty / mapCount / mapIsEmpty ----

test "mapEmpty: subkind 0, count 0, isEmpty true" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const m = try mapEmpty(&heap);
    try testing.expectEqual(Kind.persistent_map, m.kind());
    try testing.expectEqual(subkind_array_map, m.subkind());
    try testing.expectEqual(@as(usize, 0), mapCount(m));
    try testing.expect(mapIsEmpty(m));
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
    try testing.expect(mapIsEmpty(m));
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
    // Insert 10 distinct keys (all keyword ids) — with the `collidingHash`
    // fn the low 32 bits are always `0xDEAD_BEEF`, so every key descends
    // the same path and ultimately lands in a collision node.
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        m = try mapAssoc(&heap, m, value.fromKeywordId(i), value.fromFixnum(@intCast(i)).?, &collidingHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 10), mapCount(m));
    // Every key must still look up correctly.
    i = 0;
    while (i < 10) : (i += 1) {
        switch (mapGet(m, value.fromKeywordId(i), &collidingHash, &synthEq)) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
    // Dissoc from the collision bucket works end-to-end.
    m = try mapDissoc(&heap, m, value.fromKeywordId(5), &collidingHash, &synthEq);
    try testing.expectEqual(@as(usize, 9), mapCount(m));
    try testing.expect(mapGet(m, value.fromKeywordId(5), &collidingHash, &synthEq) == .absent);
    // Other keys still present.
    switch (mapGet(m, value.fromKeywordId(3), &collidingHash, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 3), v.asFixnum()),
        .absent => try testing.expect(false),
    }
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
    // Setup: we force a level-0 collision using `collidingHash` for
    // just TWO specific keys. For simplicity, we use a custom fixture.
    const twoColliders = struct {
        fn f(x: Value) u64 {
            // Two keywords collide at level-0 slot but at level-1
            // they land in different slots (simulated).
            const id = x.asKeywordId();
            if (id == 100 or id == 101) {
                // Same low-5 bits (slot 0); different level-1 bits.
                // Put id 100 → slot 0 at level-1; id 101 → slot 1.
                return (@as(u64, id) << 5) & 0xFFFF_FFFF;
            }
            return x.hashImmediate();
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
    m = try mapAssoc(&heap, m, value.fromKeywordId(100), value.fromFixnum(1000).?, &twoColliders.f, &synthEq);
    m = try mapAssoc(&heap, m, value.fromKeywordId(101), value.fromFixnum(1001).?, &twoColliders.f, &synthEq);
    try testing.expectEqual(@as(usize, 10), mapCount(m));
    // Dissoc one collider — the other should still be findable.
    m = try mapDissoc(&heap, m, value.fromKeywordId(100), &twoColliders.f, &synthEq);
    try testing.expectEqual(@as(usize, 9), mapCount(m));
    switch (mapGet(m, value.fromKeywordId(101), &twoColliders.f, &synthEq)) {
        .present => |v| try testing.expectEqual(@as(i64, 1001), v.asFixnum()),
        .absent => try testing.expect(false),
    }
}

// =============================================================================
// Set inline tests
//
// Unit-level invariants for the set kind. Mirrors the map test layout
// but exercises set-specific shapes (no value column, no replace-
// value case, contains bool instead of get union). Property tests
// live in test/prop/hamt.zig (S1..S6).
// =============================================================================

test "setEmpty: subkind 0, count 0, isEmpty true" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const s = try setEmpty(&heap);
    try testing.expectEqual(Kind.persistent_set, s.kind());
    try testing.expectEqual(subkind_array_map, s.subkind());
    try testing.expectEqual(@as(usize, 0), setCount(s));
    try testing.expect(setIsEmpty(s));
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
    try testing.expect(setIsEmpty(s));
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
        s = try setConj(&heap, s, value.fromKeywordId(i), &collidingHash, &synthEq);
    }
    try testing.expectEqual(@as(usize, 10), setCount(s));
    i = 0;
    while (i < 10) : (i += 1) {
        try testing.expect(setContains(s, value.fromKeywordId(i), &collidingHash, &synthEq));
    }
    // Disj alternating elements.
    s = try setDisj(&heap, s, value.fromKeywordId(0), &collidingHash, &synthEq);
    s = try setDisj(&heap, s, value.fromKeywordId(5), &collidingHash, &synthEq);
    try testing.expectEqual(@as(usize, 8), setCount(s));
    try testing.expect(!setContains(s, value.fromKeywordId(0), &collidingHash, &synthEq));
    try testing.expect(!setContains(s, value.fromKeywordId(5), &collidingHash, &synthEq));
    try testing.expect(setContains(s, value.fromKeywordId(3), &collidingHash, &synthEq));
}
