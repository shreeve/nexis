//! record.zig — `Kind.record` heap kind (Phase 5 Item 3 / 5.3a).
//!
//! Authoritative spec: `docs/PROTOCOLS.md` §2.1 + §3. Derivative from
//! `PLAN.md` Amendment Log entry (protocols+records, 2026-05-19) +
//! peer-AI turn 84. Those documents win on conflict.
//!
//! ONE kind for all record types. RecordTypeId is a per-VM dense u32
//! that lives in the heap body alongside a persistent_map of fields.
//! Equality + hash are STRUCTURAL — two `(->Counter 5)` instances
//! `(= ...)` true regardless of which constructor call produced them.
//!
//! Storage (16-byte-aligned body):
//!
//!     RecordValue extern struct {
//!         type_id: u32,            // dense per-VM
//!         _pad:    [4]u8,          // align to Value boundary
//!         fields:  Value,          // persistent_map (keyword → value)
//!     }
//!
//! Module graph (one-way terminal):
//!
//!     src/record.zig
//!     ├── @import("std")
//!     ├── @import("value")
//!     ├── @import("heap")
//!     ├── @import("hash")
//!     └── @import("champ")     // for hash composition of field map
//!
//! Nothing imports record.zig except `dispatch.zig` (heapHashBase +
//! heapEqual arms), `gc.zig` (trace arm), `stdlib.zig` (native fns),
//! `format.zig` (printer arm), `codec.zig` (unserializable arm).

const std = @import("std");
const value_mod = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const champ_mod = @import("champ");

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
    _pad: [4]u8 = [_]u8{0} ** 4,
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
    body._pad = [_]u8{0} ** 4;
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

/// Return a NEW record Value with the same type_id but `new_fields`
/// substituted. Used by `assoc` / `dissoc` to preserve record type.
pub fn withFields(heap: *Heap, v: Value, new_fields: Value) !Value {
    return try make(heap, typeId(v), new_fields);
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
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    var id_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &id_bytes, body.type_id, .little);
    hasher.update(&id_bytes);
    const fh = fieldHash(body.fields);
    var fh_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &fh_bytes, fh, .little);
    hasher.update(&fh_bytes);
    const truncated: u32 = @truncate(hasher.final());
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
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

test "RecordBody: ABI invariants" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(RecordBody));
    try testing.expect(@alignOf(RecordBody) <= 16);
}

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
    const empty = try champ_mod.mapEmpty(&heap);
    const r = try make(&heap, 7, empty);

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
    trace(Heap.asHeapHeader(r), Visitor{ .recorded_ptr = &recorded, .count_ptr = &count });
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(recorded[0].kind() == .persistent_map);
}
