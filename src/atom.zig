//! atom.zig — in-memory mutable cells (Phase 5 Item 1).
//!
//! Authoritative spec: `docs/ATOM.md`. Derivative from PLAN.md Amendment
//! Log (atoms entry, 2026-05-18), `docs/VALUE.md` §2.2 (kind 34
//! `atom`), `docs/SEMANTICS.md` §2.6 / §3.2 (atom identity equality +
//! identity hash). Peer-AI turn 75.
//!
//! Responsibilities:
//!   - `AtomBox` heap body: `{ value: Value, in_flight: u8, _pad }`.
//!   - `make(heap, init)` — allocate a fresh atom holding `init`.
//!   - `getValue` / `setValue` — body accessors used by the native fns.
//!   - `tryEnterCritical` / `exitCritical` — `in_flight` flag for
//!     `swap!` / `reset!` / `compare-and-set!` re-entrancy detection.
//!   - `hashHeader` — pointer-identity hash (xxHash3-32 over the raw
//!     pointer bytes). Kind-domain mixing is applied by
//!     `dispatch.hashValue` on the way out.
//!   - `atomsEqual` — pointer-identity equality.
//!   - `trace` — GC walks the contained value.
//!
//! Module graph (one-way terminal — same shape as src/db.zig for
//! durable_ref):
//!
//!     src/atom.zig
//!     ├── @import("std")
//!     ├── @import("value")
//!     ├── @import("heap")
//!     └── @import("hash")
//!
//! Nothing imports atom.zig except `dispatch.zig` (heapHashBase +
//! heapEqual arms), `gc.zig` (trace arm), `stdlib.zig` (native fns),
//! `codec.zig` (Unserializable arm), `cli.zig` (formatter arm).
//!
//! Identity-based equality is load-bearing: a mutable identity value
//! that participated in structural equality would let a map key
//! become unequal to itself after a mutation. See SEMANTICS.md §2.6
//! addendum for the formal pinning.
//!
//! v1 GC migration audit: `swap-vals!` allocates a result vector
//! AFTER the atom write. Under v1's explicit-only GC (`docs/GC.md`
//! §9), this is safe — `heap.alloc` never auto-triggers `collect`.
//! When triggered-GC lands, `docs/GC.md` §11.5 lists this site for
//! rooting audit.

const std = @import("std");
const value_mod = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Heap body
// =============================================================================

/// In-memory mutable cell. Held in the heap body of a `Kind.atom`
/// allocation. `value` is the current contained Value; `in_flight`
/// is the re-entrancy guard set by `swap!` / `reset!` /
/// `compare-and-set!` / `swap-vals!` for the duration of their
/// critical section.
///
/// Padding makes total size a multiple of 8 so any future fields
/// remain naturally aligned without re-thinking the layout.
pub const AtomBox = extern struct {
    value: Value,
    in_flight: u8,
    _pad: [7]u8 = [_]u8{0} ** 7,
};

comptime {
    std.debug.assert(@alignOf(AtomBox) <= 16);
    std.debug.assert(@sizeOf(AtomBox) == 24);
}

// =============================================================================
// Construction & accessors
// =============================================================================

/// Allocate a fresh atom holding `init`. The atom is NOT rooted by
/// any frame slot or namespace cell on return; the caller is
/// responsible for placing the returned Value somewhere reachable
/// before the next GC.
pub fn make(heap: *Heap, init: Value) !Value {
    const h = try heap.alloc(.atom, @sizeOf(AtomBox));
    const body = Heap.bodyOf(AtomBox, h);
    body.value = init;
    body.in_flight = 0;
    body._pad = [_]u8{0} ** 7;
    return Heap.valueFromHeader(.atom, h);
}

/// Read the contained value. Caller must already know `v.kind() ==
/// .atom`. Used by `deref` / `@a`.
pub inline fn getValue(v: Value) Value {
    std.debug.assert(v.kind() == .atom);
    const h = Heap.asHeapHeader(v);
    return Heap.bodyOf(AtomBox, h).value;
}

/// Replace the contained value unconditionally. Caller must already
/// know `v.kind() == .atom`. Used by `reset!` / `swap!` / `CAS` /
/// `swap-vals!` *after* their critical-section + user-callback
/// phases have completed.
pub inline fn setValue(v: Value, new: Value) void {
    std.debug.assert(v.kind() == .atom);
    const h = Heap.asHeapHeader(v);
    Heap.bodyOf(AtomBox, h).value = new;
}

/// Attempt to mark this atom as in-flight for the caller's critical
/// section. Returns `true` if the caller acquired the flag (must
/// pair with `exitCritical`); `false` if another op already owns
/// it (caller should throw `:atom-re-entry`).
///
/// v1 is single-threaded so this is a simple read+set, not a CAS.
/// The flag exists purely to detect a user fn (passed to `swap!` or
/// `swap-vals!`) re-entering a mutating op on the same atom.
pub inline fn tryEnterCritical(v: Value) bool {
    std.debug.assert(v.kind() == .atom);
    const body = Heap.bodyOf(AtomBox, Heap.asHeapHeader(v));
    if (body.in_flight == 1) return false;
    body.in_flight = 1;
    return true;
}

/// Release the in-flight flag. Caller MUST have acquired it via a
/// successful `tryEnterCritical`. Idempotent w.r.t. non-acquired
/// state (we never assert here — callers wrap with `defer` for
/// throw-safety, and the read+write is harmless if the slot is
/// already 0).
pub inline fn exitCritical(v: Value) void {
    std.debug.assert(v.kind() == .atom);
    const body = Heap.bodyOf(AtomBox, Heap.asHeapHeader(v));
    body.in_flight = 0;
}

// =============================================================================
// Hash + equality (identity-based; SEMANTICS.md §2.6 + §3.2)
// =============================================================================

/// Identity hash: xxHash3-32 over the raw `*HeapHeader` pointer.
/// Stable for the atom's lifetime (the pointer never changes; only
/// the contained `value` mutates, which we deliberately ignore so
/// atom-as-map-key stays well-behaved across mutations).
///
/// Caches the result in the HeapHeader's cached-hash slot. Domain
/// mixing (`mixKindDomain` with `Kind.atom = 34`) happens in
/// `dispatch.hashValue` on the way out, parallel to every other
/// kind-local heap kind.
///
/// **Future GC migration note**: if a moving collector ever lands,
/// `@intFromPtr` is no longer stable across collections. The
/// migration plan must replace this with a stable object-identity
/// (e.g., a per-allocation u64 stamp baked into the header at
/// allocation time). v1's non-moving mark-sweep makes raw pointer
/// hashing both correct and cheap. Cross-referenced in
/// `docs/GC.md` §11.5 audit checklist.
pub fn hashHeader(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    const ptr_int: usize = @intFromPtr(h);
    var ptr_bytes: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &ptr_bytes, ptr_int, .little);
    hasher.update(&ptr_bytes);
    const full = hasher.final();
    const truncated: u32 = @truncate(full);
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// Identity equality: same `*HeapHeader` ↔ same atom. Two distinct
/// AtomBoxes are never equal even if their `value` fields are
/// structurally `=`. This is the load-bearing invariant for
/// atom-as-map-key — see SEMANTICS.md §2.6 amendment for atoms.
pub fn atomsEqual(a: *HeapHeader, b: *HeapHeader) bool {
    return a == b;
}

// =============================================================================
// GC trace
// =============================================================================

/// Mark the contained value. `in_flight` is a `u8` — not a Value —
/// so there's nothing else to walk. The `meta` chain (for atoms
/// carrying `:meta`, post-v1) is handled centrally by the collector
/// before `trace` is invoked.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = Heap.bodyOf(AtomBox, h);
    visitor.markValue(body.value);
}

// =============================================================================
// Inline tests
// =============================================================================

test "AtomBox: ABI invariants" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(AtomBox));
    try testing.expect(@alignOf(AtomBox) <= 16);
}

test "make / getValue / setValue: round-trips" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try make(&heap, value_mod.fromFixnum(42).?);
    try testing.expect(a.kind() == .atom);
    try testing.expectEqual(value_mod.fromFixnum(42).?.payload, getValue(a).payload);

    setValue(a, value_mod.fromFixnum(100).?);
    try testing.expectEqual(value_mod.fromFixnum(100).?.payload, getValue(a).payload);
}

test "tryEnterCritical / exitCritical: re-entrancy guard" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try make(&heap, value_mod.nilValue());

    try testing.expect(tryEnterCritical(a));
    // Second attempt while already in_flight must report false.
    try testing.expect(!tryEnterCritical(a));
    exitCritical(a);
    // After exit, the flag is clear and we can re-enter.
    try testing.expect(tryEnterCritical(a));
    exitCritical(a);
}

test "atomsEqual: identity, not contained-value equality" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const v1 = value_mod.fromFixnum(7).?;
    const a = try make(&heap, v1);
    const b = try make(&heap, v1); // distinct atom, same contained value
    const ah = Heap.asHeapHeader(a);
    const bh = Heap.asHeapHeader(b);
    try testing.expect(atomsEqual(ah, ah));
    try testing.expect(!atomsEqual(ah, bh));
}

test "hashHeader: identity-stable across value mutation" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try make(&heap, value_mod.fromFixnum(1).?);
    const ah = Heap.asHeapHeader(a);
    const h_before = hashHeader(ah);

    // Mutate the contained value; the atom's hash is identity-based,
    // so it MUST be invariant.
    setValue(a, value_mod.fromFixnum(99999).?);
    const h_after = hashHeader(ah);
    try testing.expectEqual(h_before, h_after);
}

test "hashHeader: distinct atoms (almost certainly) hash differently" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try make(&heap, value_mod.nilValue());
    const b = try make(&heap, value_mod.nilValue());
    const ha = hashHeader(Heap.asHeapHeader(a));
    const hb = hashHeader(Heap.asHeapHeader(b));
    try testing.expect(ha != hb);
}

test "trace: visits the contained value via markValue" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try make(&heap, value_mod.fromFixnum(7).?);

    // Stub visitor records every markValue call. Trace must invoke
    // markValue exactly once with the contained value.
    var recorded: [4]Value = undefined;
    var count: usize = 0;
    const Visitor = struct {
        recorded_ptr: *[4]Value,
        count_ptr: *usize,
        pub fn markValue(self: @This(), v: Value) void {
            if (self.count_ptr.* < self.recorded_ptr.len) {
                self.recorded_ptr.*[self.count_ptr.*] = v;
            }
            self.count_ptr.* += 1;
        }
    };
    trace(Heap.asHeapHeader(a), Visitor{ .recorded_ptr = &recorded, .count_ptr = &count });

    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(value_mod.fromFixnum(7).?.payload, recorded[0].payload);
}

test "trace: self-referential atom does not stack-overflow the visitor" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Build an atom whose contained value IS the atom itself.
    const a = try make(&heap, value_mod.nilValue());
    setValue(a, a);

    // The visitor records the contained Value; it does NOT recurse.
    // Recursion is the collector's job, and the collector short-
    // circuits on the mark-bit. trace itself must terminate in O(1).
    var recorded: [4]Value = undefined;
    var count: usize = 0;
    const Visitor = struct {
        recorded_ptr: *[4]Value,
        count_ptr: *usize,
        pub fn markValue(self: @This(), v: Value) void {
            if (self.count_ptr.* < self.recorded_ptr.len) {
                self.recorded_ptr.*[self.count_ptr.*] = v;
            }
            self.count_ptr.* += 1;
        }
    };
    trace(Heap.asHeapHeader(a), Visitor{ .recorded_ptr = &recorded, .count_ptr = &count });

    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(a.payload, recorded[0].payload);
    try testing.expectEqual(a.tag, recorded[0].tag);
}
