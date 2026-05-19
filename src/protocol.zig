//! protocol.zig — `Kind.protocol = 36` + `Kind.protocol_fn = 37`
//! heap kinds (Phase 5 Item 3 / 5.3b).
//!
//! Authoritative spec: `docs/PROTOCOLS.md` §2.2 + §2.3. Per-VM
//! protocol registry lives on the VM; this module owns only the
//! heap-side storage + identity-equality + identity-hash for the
//! two kinds. The dispatch logic for `(method-fn receiver args)`
//! lives in `vm.zig`'s `dispatchProtocolMethod`.
//!
//! Storage (both kinds opaque, identity-valued):
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
//! Both kinds are opaque (`#<protocol my.ns/IFoo>` /
//! `#<protocol-fn my.ns/IFoo/bar>` in format.zig). Identity
//! equality + identity hash via the *HeapHeader pointer (matching
//! atoms / durable_refs / vars). NOT serializable.
//!
//! Module graph: src/protocol.zig depends on value + heap + hash
//! only. Consumed by dispatch.zig (eq + hash arms), gc.zig
//! (trace arms — both are leafs, no inner heap to mark),
//! format.zig (printer arms), codec.zig (unserializable arm),
//! stdlib.zig (native helpers + dispatcher).

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
// Identity hash / equality (both kinds — pointer-identity)
// =============================================================================

pub fn hashHeader(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    const ptr_int: usize = @intFromPtr(h);
    var ptr_bytes: [@sizeOf(usize)]u8 = undefined;
    std.mem.writeInt(usize, &ptr_bytes, ptr_int, .little);
    hasher.update(&ptr_bytes);
    const truncated: u32 = @truncate(hasher.final());
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

pub fn pointerEqual(a: *HeapHeader, b: *HeapHeader) bool {
    return a == b;
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

test "pointerEqual + hashHeader: identity-based" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const p1 = try makeProtocol(&heap, 1);
    const p2 = try makeProtocol(&heap, 1); // distinct allocation, same id
    const ph1 = Heap.asHeapHeader(p1);
    const ph2 = Heap.asHeapHeader(p2);
    try testing.expect(pointerEqual(ph1, ph1));
    try testing.expect(!pointerEqual(ph1, ph2));
    try testing.expect(hashHeader(ph1) != hashHeader(ph2));
}
