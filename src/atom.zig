//! atom.zig — the atom: a mutable cell (`docs/ATOM.md`).
//!
//! An identity kind: equal only to itself and hashed by its pointer,
//! never by what it holds, so a map key never changes under a mutation
//! (SEMANTICS.md §2.6). The natives in `src/stdlib.zig` call the
//! validator and the watches through `vm.callValue`, a safe point, and
//! root what the atom does not hold across those calls (ATOM.md §7).

const std = @import("std");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Heap body
// =============================================================================

/// In-memory mutable cell. Held in the heap body of a `Kind.atom`
/// allocation. `value` is the current contained Value; `validator`
/// the function every new state must satisfy, or nil; `watches` the
/// hash map of key → watch function, or nil when it has none;
/// `in_flight` the re-entrancy guard set by `swap!` / `reset!` /
/// `compare-and-set!` / `swap-vals!` while they compute and validate
/// the new state.
///
/// The padding makes the body a multiple of 8 bytes.
pub const AtomBox = extern struct {
    value: Value,
    validator: Value,
    watches: Value,
    in_flight: u8,
    _pad: [7]u8 = @splat(0),
};

comptime {
    std.debug.assert(@alignOf(AtomBox) <= 16);
    std.debug.assert(@sizeOf(AtomBox) == 56);
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
    Heap.bodyOf(AtomBox, h).* = .{ .value = init, .validator = value_mod.nilValue(), .watches = value_mod.nilValue(), .in_flight = 0 };
    return Heap.valueFromHeader(.atom, h);
}

/// The body of the atom `v`, for the validator and the watches.
pub inline fn body(v: Value) *AtomBox {
    std.debug.assert(v.kind() == .atom);
    return Heap.bodyOf(AtomBox, Heap.asHeapHeader(v));
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
/// The VM is single-threaded so this is a simple read+set, not a CAS.
/// The flag exists purely to detect a user fn (passed to `swap!` or
/// `swap-vals!`) re-entering a mutating op on the same atom.
pub inline fn tryEnterCritical(v: Value) bool {
    const b = body(v);
    if (b.in_flight == 1) return false;
    b.in_flight = 1;
    return true;
}

/// Release the in-flight flag. Caller MUST have acquired it via a
/// successful `tryEnterCritical`. Idempotent w.r.t. non-acquired
/// state (we never assert here — callers wrap with `defer` for
/// throw-safety, and the read+write is harmless if the slot is
/// already 0).
pub inline fn exitCritical(v: Value) void {
    body(v).in_flight = 0;
}

// =============================================================================
// GC trace
// =============================================================================

/// Mark the contained value, the validator and the watches map.
/// The `meta` chain is handled centrally by the collector before
/// `trace` is invoked.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const b = Heap.bodyOf(AtomBox, h);
    visitor.markValue(b.value);
    visitor.markValue(b.validator);
    visitor.markValue(b.watches);
}

// =============================================================================
// Inline tests
// =============================================================================

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

test "trace: the value, the validator and the watches, without recursing into a self-holding atom" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try make(&heap, value_mod.nilValue());
    setValue(a, a);
    body(a).validator = value_mod.fromFixnum(1).?;
    var seen: TestRecorder = .{};
    trace(Heap.asHeapHeader(a), &seen);
    try testing.expectEqual(@as(usize, 3), seen.n);
    try testing.expect(seen.values[0].identicalTo(a));
    try testing.expectEqual(@as(i64, 1), seen.values[1].asFixnum());
}

/// A trace visitor that records what it is shown, for the kinds'
/// trace tests.
pub const TestRecorder = struct {
    values: [4]Value = undefined,
    n: usize = 0,

    pub fn markValue(self: *TestRecorder, v: Value) void {
        if (!@import("builtin").is_test) @compileError("TestRecorder is for tests");
        self.values[self.n] = v;
        self.n += 1;
    }
};
