//! record.zig — the record kind (`docs/PROTOCOLS.md` §2.1, §3).
//!
//! One kind for every record type: the body is the per-VM type id and
//! the field map. Equality and hash are structural: the same type id
//! and equal field maps.

const std = @import("std");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");
const hash_mod = @import("hash.zig");
const champ_mod = @import("coll/champ.zig");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Heap body
// =============================================================================

pub const RecordBody = extern struct {
    type_id: u32,
    _pad: [4]u8 = @splat(0),
    fields: Value,
};

comptime {
    std.debug.assert(@alignOf(RecordBody) <= 16);
    std.debug.assert(@sizeOf(RecordBody) == 24);
}

// =============================================================================
// Construction & accessors
// =============================================================================

/// Build a record Value with the given type_id and field map. The
/// caller is responsible for keeping the field map (a persistent_map)
/// reachable until this record is rooted somewhere.
pub fn make(heap: *Heap, type_id: u32, fields: Value) !Value {
    std.debug.assert(fields.kind() == .persistent_map);
    const h = try heap.alloc(.record, @sizeOf(RecordBody));
    const body = Heap.bodyOf(RecordBody, h);
    body.type_id = type_id;
    body._pad = @splat(0);
    body.fields = fields;
    return Heap.valueFromHeader(.record, h);
}

pub inline fn typeId(v: Value) u32 {
    std.debug.assert(v.kind() == .record);
    return Heap.bodyOf(RecordBody, Heap.asHeapHeader(v)).type_id;
}

pub inline fn fieldsOf(v: Value) Value {
    std.debug.assert(v.kind() == .record);
    return Heap.bodyOf(RecordBody, Heap.asHeapHeader(v)).fields;
}

/// Return a NEW record Value with the same type_id and metadata but
/// `new_fields` substituted. Used by `assoc` / `dissoc` to preserve
/// record type; the metadata stays as on every Clojure record update
/// (SEMANTICS §7).
pub fn withFields(heap: *Heap, v: Value, new_fields: Value) !Value {
    const r = try make(heap, typeId(v), new_fields);
    Heap.asHeapHeader(r).setMeta(Heap.asHeapHeader(v).getMeta());
    return r;
}

// =============================================================================
// Hash + equality (structural; PROTOCOLS.md §2.1)
// =============================================================================

/// Pre-mix base hash for records. Combines `type_id` with the
/// field-map's hash. The kind-domain mix (`mixKindDomain` with
/// `Kind.record = 35`) is applied by `dispatch.hashValue` on the
/// way out.
pub fn hashHeader(h: *HeapHeader, fieldHash: *const fn (v: Value) u64) u32 {
    if (h.cachedHash()) |cached| return cached;
    const body = Heap.bodyOf(RecordBody, h);
    return h.cacheHash(hash_mod.combineOrdered(hash_mod.hashU64(body.type_id), fieldHash(body.fields)));
}

/// Structural equality: same type_id AND equal field maps.
pub fn recordsEqual(
    a: *HeapHeader,
    b: *HeapHeader,
    fieldEqual: *const fn (a: Value, b: Value) bool,
) bool {
    if (a == b) return true;
    const ab = Heap.bodyOf(RecordBody, a);
    const bb = Heap.bodyOf(RecordBody, b);
    if (ab.type_id != bb.type_id) return false;
    return fieldEqual(ab.fields, bb.fields);
}

// =============================================================================
// GC trace
// =============================================================================

pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = Heap.bodyOf(RecordBody, h);
    // type_id is a u32, not a heap value. fields is the persistent_map.
    visitor.markValue(body.fields);
}

// =============================================================================
// Inline tests
// =============================================================================

test "make / typeId / fieldsOf: round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const empty = try champ_mod.mapEmpty(&heap);
    const r = try make(&heap, 42, empty);
    try testing.expect(r.kind() == .record);
    try testing.expectEqual(@as(u32, 42), typeId(r));
    try testing.expect(fieldsOf(r).kind() == .persistent_map);
}

test "trace: marks the contained field map" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const r = try make(&heap, 7, try champ_mod.mapEmpty(&heap));
    var seen: @import("atom.zig").TestRecorder = .{};
    trace(Heap.asHeapHeader(r), &seen);
    try testing.expectEqual(@as(usize, 1), seen.n);
    try testing.expect(seen.values[0].kind() == .persistent_map);
}
