//! protocol.zig — the protocol and protocol-fn kinds' bodies
//! (`docs/PROTOCOLS.md` §2.2, §2.3): a protocol's per-VM id, and a
//! protocol fn's protocol id and method keyword id. Both are identity
//! kinds; the registry and the dispatch are `vm.zig`'s.

const std = @import("std");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");
const intern_mod = @import("intern.zig");

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
    _pad: [4]u8 = @splat(0),
};

comptime {
    std.debug.assert(@alignOf(ProtocolBody) <= 16);
    std.debug.assert(@sizeOf(ProtocolBody) == 8);
}

pub fn makeProtocol(heap: *Heap, id: u32) !Value {
    const h = try heap.alloc(.protocol, @sizeOf(ProtocolBody));
    const body = Heap.bodyOf(ProtocolBody, h);
    body.id = id;
    body._pad = @splat(0);
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

/// The `ns/Name` of protocol `v`, or of the protocol a protocol fn `v`
/// dispatches for; null when the interner never named it
/// (`Interner.nameProtocol`).
pub fn nameOf(v: Value, interner: *const intern_mod.Interner) ?[]const u8 {
    return interner.protocolName(switch (v.kind()) {
        .protocol => protocolId(v),
        .protocol_fn => protocolFnProtocolId(v),
        else => unreachable,
    });
}

// =============================================================================
// Inline tests
// =============================================================================

test "makeProtocol / protocolId: round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const p = try makeProtocol(&heap, 42);
    try testing.expect(p.kind() == .protocol);
    try testing.expectEqual(@as(u32, 42), protocolId(p));
}

test "nameOf: a protocol and its fns by the name the interner holds" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var it = intern_mod.Interner.init(testing.allocator);
    defer it.deinit();
    const p = try makeProtocol(&heap, 3);
    const f = try makeProtocolFn(&heap, 3, 0);
    try testing.expect(nameOf(p, &it) == null);
    try it.nameProtocol(3, "user", "Shape");
    try testing.expectEqualStrings("user/Shape", nameOf(p, &it).?);
    try testing.expectEqualStrings("user/Shape", nameOf(f, &it).?);
}

test "makeProtocolFn / accessors" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const pfn = try makeProtocolFn(&heap, 7, 99);
    try testing.expect(pfn.kind() == .protocol_fn);
    try testing.expectEqual(@as(u32, 7), protocolFnProtocolId(pfn));
    try testing.expectEqual(@as(u32, 99), protocolFnMethodNameId(pfn));
}
