//! protocol.zig — `Kind.protocol = 36` + `Kind.protocol_fn = 37`
//! heap kinds.
//!
//! Authoritative spec: `docs/PROTOCOLS.md` §2.2 + §2.3. The per-VM
//! protocol registry and method dispatch live in `vm.zig`; this module
//! owns only the heap bodies of the two kinds:
//!
//!     ProtocolBody extern struct {
//!         id: u32,         // dense per-VM
//!         _pad: [4]u8,
//!     }
//!
//!     ProtocolFnBody extern struct {
//!         protocol_id: u32,
//!         method_name_id: u32,   // interned symbol id of method
//!     }
//!
//! Both are identity kinds (`dispatch.isIdentityKind`): equal to
//! themselves only, hashed by pointer, not serializable.

const std = @import("std");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Protocol kind (36)
// =============================================================================

pub const ProtocolBody = extern struct {
    id: u32,
    _pad: [4]u8 = [_]u8{0} ** 4,
};

comptime {
    std.debug.assert(@alignOf(ProtocolBody) <= 16);
    std.debug.assert(@sizeOf(ProtocolBody) == 8);
}

pub fn makeProtocol(heap: *Heap, id: u32) !Value {
    const h = try heap.alloc(.protocol, @sizeOf(ProtocolBody));
    const body = Heap.bodyOf(ProtocolBody, h);
    body.id = id;
    body._pad = [_]u8{0} ** 4;
    return Heap.valueFromHeader(.protocol, h);
}

pub inline fn protocolId(v: Value) u32 {
    std.debug.assert(v.kind() == .protocol);
    return Heap.bodyOf(ProtocolBody, Heap.asHeapHeader(v)).id;
}

// =============================================================================
// Protocol-fn kind (37)
// =============================================================================

pub const ProtocolFnBody = extern struct {
    protocol_id: u32,
    method_name_id: u32,
};

comptime {
    std.debug.assert(@alignOf(ProtocolFnBody) <= 16);
    std.debug.assert(@sizeOf(ProtocolFnBody) == 8);
}

pub fn makeProtocolFn(heap: *Heap, protocol_id: u32, method_name_id: u32) !Value {
    const h = try heap.alloc(.protocol_fn, @sizeOf(ProtocolFnBody));
    const body = Heap.bodyOf(ProtocolFnBody, h);
    body.protocol_id = protocol_id;
    body.method_name_id = method_name_id;
    return Heap.valueFromHeader(.protocol_fn, h);
}

pub inline fn protocolFnProtocolId(v: Value) u32 {
    std.debug.assert(v.kind() == .protocol_fn);
    return Heap.bodyOf(ProtocolFnBody, Heap.asHeapHeader(v)).protocol_id;
}

pub inline fn protocolFnMethodNameId(v: Value) u32 {
    std.debug.assert(v.kind() == .protocol_fn);
    return Heap.bodyOf(ProtocolFnBody, Heap.asHeapHeader(v)).method_name_id;
}

// =============================================================================
// GC trace (both kinds — leaf; no inner heap to mark)
// =============================================================================

pub fn trace(h: *HeapHeader, visitor: anytype) void {
    _ = h;
    _ = visitor;
}

// =============================================================================
// Inline tests
// =============================================================================

test "ProtocolBody / ProtocolFnBody: ABI invariants" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(ProtocolBody));
    try testing.expectEqual(@as(usize, 8), @sizeOf(ProtocolFnBody));
}

test "makeProtocol / protocolId: round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const p = try makeProtocol(&heap, 42);
    try testing.expect(p.kind() == .protocol);
    try testing.expectEqual(@as(u32, 42), protocolId(p));
}

test "makeProtocolFn / accessors" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const pfn = try makeProtocolFn(&heap, 7, 99);
    try testing.expect(pfn.kind() == .protocol_fn);
    try testing.expectEqual(@as(u32, 7), protocolFnProtocolId(pfn));
    try testing.expectEqual(@as(u32, 99), protocolFnMethodNameId(pfn));
}
