//! handle.zig — heap bodies of the `nextomic_conn`, `nextomic_db` and
//! `nextomic_entity` value kinds (NEXTOMIC.md §8).
//!
//! This file is its own build module (`nextomic_handle`), below
//! `dispatch`, `format`, `gc` and `vm`, so those layers can print,
//! compare, hash, trace and look up the three kinds without importing
//! the `nextomic` module that sits above them. The `nextomic.Conn`
//! behind a connection handle is opaque here; `natives.zig` owns the
//! cast.
//!
//! The connection and db boxes are leaves for the collector: a
//! connection box holds a pointer the VM owns and its path text
//! inline; a db box holds that same pointer and numbers. An entity box
//! holds a db box and the map of its last full read, and the collector
//! marks both.
//!
//!   - A connection handle is identity-valued: equal to itself only.
//!   - A db-value is a plain value: two db boxes are equal when they
//!     name the same connection, basis and mode (as-of, since,
//!     history); `(= (d/db c) (d/db c))` holds while nothing was
//!     transacted in between.
//!   - A lazy entity is a value: two entity boxes are equal when their
//!     db-values are equal and their eids agree, and hash accordingly.
//!     Its attributes are read on access through the hook the box
//!     carries (`entityLookup`), which `vm.lookup` calls for
//!     `(:attr ent)` and `(get ent :attr)`; the hook is a function of
//!     `natives.zig`, and the VM it runs against rides in the box too.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");

const Value = value.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

// =============================================================================
// Connection handle
// =============================================================================

const ConnBox = extern struct {
    /// The `nextomic.Conn`, owned by the VM's connection list.
    conn: *anyopaque,
    /// Length of the path text that follows the struct in the body.
    path_len: usize,
};

comptime {
    std.debug.assert(@alignOf(ConnBox) <= 16);
}

/// Box `conn` with its path text copied inline.
pub fn makeConn(heap: *Heap, conn: *anyopaque, path: []const u8) !Value {
    const h = try heap.alloc(.nextomic_conn, @sizeOf(ConnBox) + path.len);
    const body = Heap.bodyOf(ConnBox, h);
    body.conn = conn;
    body.path_len = path.len;
    @memcpy(connPathBytes(h), path);
    return Heap.valueFromHeader(.nextomic_conn, h);
}

fn connPathBytes(h: *HeapHeader) []u8 {
    const body = Heap.bodyOf(ConnBox, h);
    const base: [*]u8 = @ptrCast(body);
    return base[@sizeOf(ConnBox) .. @sizeOf(ConnBox) + body.path_len];
}

pub fn connPtr(v: Value) *anyopaque {
    std.debug.assert(v.kind() == .nextomic_conn);
    return Heap.bodyOf(ConnBox, Heap.asHeapHeader(v)).conn;
}

pub fn connPath(v: Value) []const u8 {
    std.debug.assert(v.kind() == .nextomic_conn);
    return connPathBytes(Heap.asHeapHeader(v));
}

/// Identity hash on the header pointer.
pub fn connHash(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    const full = hash_mod.hashU64(@intFromPtr(h));
    const truncated: u32 = @truncate(full);
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

pub fn connEqual(a: *HeapHeader, b: *HeapHeader) bool {
    return a == b;
}

pub fn formatConn(v: Value, writer: *std.Io.Writer) !void {
    try writer.writeAll("#nextomic/conn \"");
    try writer.writeAll(connPath(v));
    try writer.writeByte('"');
}

// =============================================================================
// Db-value
// =============================================================================

/// The fields of a db-value (NEXTOMIC.md §4).
pub const DbShape = struct {
    conn: *anyopaque,
    basis: u64,
    as_of: ?u64 = null,
    since: ?u64 = null,
    history: bool = false,
};

const DbBox = extern struct {
    conn: *anyopaque,
    basis: u64,
    as_of: u64,
    since: u64,
    has_as_of: u8,
    has_since: u8,
    history: u8,
    _pad: [5]u8,
};

comptime {
    std.debug.assert(@alignOf(DbBox) <= 16);
    std.debug.assert(@sizeOf(DbBox) == 40);
}

pub fn makeDb(heap: *Heap, shape: DbShape) !Value {
    const h = try heap.alloc(.nextomic_db, @sizeOf(DbBox));
    const body = Heap.bodyOf(DbBox, h);
    body.* = .{
        .conn = shape.conn,
        .basis = shape.basis,
        .as_of = shape.as_of orelse 0,
        .since = shape.since orelse 0,
        .has_as_of = @intFromBool(shape.as_of != null),
        .has_since = @intFromBool(shape.since != null),
        .history = @intFromBool(shape.history),
        ._pad = [_]u8{0} ** 5,
    };
    return Heap.valueFromHeader(.nextomic_db, h);
}

fn shapeOf(h: *HeapHeader) DbShape {
    const body = Heap.bodyOf(DbBox, h);
    return .{
        .conn = body.conn,
        .basis = body.basis,
        .as_of = if (body.has_as_of != 0) body.as_of else null,
        .since = if (body.has_since != 0) body.since else null,
        .history = body.history != 0,
    };
}

pub fn dbShape(v: Value) DbShape {
    std.debug.assert(v.kind() == .nextomic_db);
    return shapeOf(Heap.asHeapHeader(v));
}

pub fn dbEqual(a: *HeapHeader, b: *HeapHeader) bool {
    const x = shapeOf(a);
    const y = shapeOf(b);
    return x.conn == y.conn and x.basis == y.basis and
        std.meta.eql(x.as_of, y.as_of) and std.meta.eql(x.since, y.since) and
        x.history == y.history;
}

/// Structural hash over the same fields equality reads.
pub fn dbHash(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    const s = shapeOf(h);
    var acc = hash_mod.hashU64(@intFromPtr(s.conn));
    acc = hash_mod.combineOrdered(acc, hash_mod.hashU64(s.basis));
    acc = hash_mod.combineOrdered(acc, hash_mod.hashU64(if (s.as_of) |t| t + 1 else 0));
    acc = hash_mod.combineOrdered(acc, hash_mod.hashU64(if (s.since) |t| t + 1 else 0));
    acc = hash_mod.combineOrdered(acc, hash_mod.hashU64(@intFromBool(s.history)));
    const truncated: u32 = @truncate(acc);
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// `#nextomic/db {:basis-t 7 :mode :current}`; the mode is `:current`,
/// `:as-of`, `:since` or `:history`, with `:as-of`/`:since` bounds
/// spelled out whenever they are set.
pub fn formatDb(v: Value, writer: *std.Io.Writer) !void {
    const s = dbShape(v);
    const mode: []const u8 = if (s.history) "history" else if (s.since != null) "since" else if (s.as_of != null) "as-of" else "current";
    try writer.print("#nextomic/db {{:basis-t {d} :mode :{s}", .{ s.basis, mode });
    if (s.as_of) |t| try writer.print(" :as-of {d}", .{t});
    if (s.since) |t| try writer.print(" :since {d}", .{t});
    try writer.writeByte('}');
}

// =============================================================================
// Lazy entity
// =============================================================================

/// The read hook of an entity box: `(vm, entity, key, default)` → the
/// attribute's value in the entity's view, or `default`. It returns
/// only errors of the VM's set, so `vm.lookup` can cast them back.
pub const EntityRead = *const fn (vm: *anyopaque, ent: Value, key: Value, default: Value) anyerror!Value;

/// The fields of a lazy entity (NEXTOMIC.md §6).
pub const EntityShape = struct {
    /// The `nextomic_db` box the entity reads through.
    db: Value,
    eid: u64,
    /// The VM the hook runs against.
    vm: *anyopaque,
    read: EntityRead,
};

const EntityBox = struct {
    db: Value,
    /// The map of the last full read (`keys`, `seq`, `count`, ...),
    /// nil before one: kept reachable from the entity so an iteration
    /// over it survives a collection inside a callback. Never read
    /// back; every access folds the view again.
    held: Value,
    eid: u64,
    vm: *anyopaque,
    read: EntityRead,
};

comptime {
    std.debug.assert(@alignOf(EntityBox) <= 16);
}

pub fn makeEntity(heap: *Heap, shape: EntityShape) !Value {
    std.debug.assert(shape.db.kind() == .nextomic_db);
    const h = try heap.alloc(.nextomic_entity, @sizeOf(EntityBox));
    const body = Heap.bodyOf(EntityBox, h);
    body.* = .{
        .db = shape.db,
        .held = value.nilValue(),
        .eid = shape.eid,
        .vm = shape.vm,
        .read = shape.read,
    };
    return Heap.valueFromHeader(.nextomic_entity, h);
}

fn entityBody(v: Value) *EntityBox {
    std.debug.assert(v.kind() == .nextomic_entity);
    return Heap.bodyOf(EntityBox, Heap.asHeapHeader(v));
}

/// The db-value the entity reads through.
pub fn entityDb(v: Value) Value {
    return entityBody(v).db;
}

pub fn entityEid(v: Value) u64 {
    return entityBody(v).eid;
}

/// Keep `m`, the map of a full read, reachable from the entity.
pub fn entityHold(v: Value, m: Value) void {
    entityBody(v).held = m;
}

/// `(get ent key default)` through the box's hook.
pub fn entityLookup(ent: Value, key: Value, default: Value) anyerror!Value {
    const body = entityBody(ent);
    return body.read(body.vm, ent, key, default);
}

pub fn entityEqual(a: *HeapHeader, b: *HeapHeader) bool {
    const x = Heap.bodyOf(EntityBox, a);
    const y = Heap.bodyOf(EntityBox, b);
    return x.eid == y.eid and dbEqual(Heap.asHeapHeader(x.db), Heap.asHeapHeader(y.db));
}

/// Structural hash over the same fields equality reads.
pub fn entityHash(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    const body = Heap.bodyOf(EntityBox, h);
    const acc = hash_mod.combineOrdered(dbHash(Heap.asHeapHeader(body.db)), hash_mod.hashU64(body.eid));
    const truncated: u32 = @truncate(acc);
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// The collector marks the db box and the held map.
pub fn traceEntity(h: *HeapHeader, visitor: anytype) void {
    const body = Heap.bodyOf(EntityBox, h);
    visitor.markValue(body.db);
    visitor.markValue(body.held);
}

/// `#nextomic/entity {:db/id 4294967296}`: the eid alone, since the
/// attributes are read on access and the db-value is `entity-db`'s.
pub fn formatEntity(v: Value, writer: *std.Io.Writer) !void {
    try writer.print("#nextomic/entity {{:db/id {d}}}", .{entityEid(v)});
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn echoKey(_: *anyopaque, _: Value, key: Value, _: Value) anyerror!Value {
    return key;
}

test "entity box is a value over its db-value and eid, and reads through its hook" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var target: u32 = 0;
    const conn: *anyopaque = @ptrCast(&target);
    var other: u32 = 0;
    const cur = try makeDb(&heap, .{ .conn = conn, .basis = 7 });
    const cur2 = try makeDb(&heap, .{ .conn = conn, .basis = 7 });
    const older = try makeDb(&heap, .{ .conn = conn, .basis = 7, .as_of = 3 });
    const elsewhere = try makeDb(&heap, .{ .conn = @ptrCast(&other), .basis = 7 });
    const vm: *anyopaque = @ptrCast(&target);

    const a = try makeEntity(&heap, .{ .db = cur, .eid = 4294967296, .vm = vm, .read = &echoKey });
    const a2 = try makeEntity(&heap, .{ .db = cur2, .eid = 4294967296, .vm = vm, .read = &echoKey });
    const b = try makeEntity(&heap, .{ .db = cur, .eid = 4294967297, .vm = vm, .read = &echoKey });
    const a_older = try makeEntity(&heap, .{ .db = older, .eid = 4294967296, .vm = vm, .read = &echoKey });
    const a_elsewhere = try makeEntity(&heap, .{ .db = elsewhere, .eid = 4294967296, .vm = vm, .read = &echoKey });

    const H = Heap.asHeapHeader;
    try testing.expect(entityEqual(H(a), H(a)));
    try testing.expect(entityEqual(H(a), H(a2)));
    try testing.expectEqual(entityHash(H(a)), entityHash(H(a2)));
    try testing.expect(!entityEqual(H(a), H(b)));
    try testing.expect(entityHash(H(a)) != entityHash(H(b)));
    try testing.expect(!entityEqual(H(a), H(a_older)));
    try testing.expect(entityHash(H(a)) != entityHash(H(a_older)));
    try testing.expect(!entityEqual(H(a), H(a_elsewhere)));

    try testing.expectEqual(@as(u64, 4294967296), entityEid(a));
    try testing.expect(dbEqual(H(entityDb(a)), H(cur)));
    const key = Value{ .tag = 6, .payload = 42 };
    const got = try entityLookup(a, key, value.nilValue());
    try testing.expectEqual(key.payload, got.payload);

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatEntity(b, &w);
    try testing.expectEqualStrings("#nextomic/entity {:db/id 4294967297}", w.buffered());
}

test "conn box keeps its path and is identity-valued" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var target: u32 = 0;
    const a = try makeConn(&heap, @ptrCast(&target), "/tmp/a.edb");
    const b = try makeConn(&heap, @ptrCast(&target), "/tmp/a.edb");
    try testing.expectEqualStrings("/tmp/a.edb", connPath(a));
    try testing.expectEqual(@as(*anyopaque, @ptrCast(&target)), connPtr(a));
    try testing.expect(connEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(a)));
    try testing.expect(!connEqual(Heap.asHeapHeader(a), Heap.asHeapHeader(b)));
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatConn(a, &w);
    try testing.expectEqualStrings("#nextomic/conn \"/tmp/a.edb\"", w.buffered());
}

test "db box round trips its shape, compares structurally and prints its mode" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var target: u32 = 0;
    const conn: *anyopaque = @ptrCast(&target);
    const cur = try makeDb(&heap, .{ .conn = conn, .basis = 7 });
    const cur2 = try makeDb(&heap, .{ .conn = conn, .basis = 7 });
    const older = try makeDb(&heap, .{ .conn = conn, .basis = 7, .as_of = 3 });
    const hist = try makeDb(&heap, .{ .conn = conn, .basis = 7, .as_of = 3, .history = true });
    const sinc = try makeDb(&heap, .{ .conn = conn, .basis = 7, .since = 2 });
    const zero = try makeDb(&heap, .{ .conn = conn, .basis = 7, .as_of = 0 });

    const H = Heap.asHeapHeader;
    try testing.expect(dbEqual(H(cur), H(cur2)));
    try testing.expectEqual(dbHash(H(cur)), dbHash(H(cur2)));
    try testing.expect(!dbEqual(H(cur), H(older)));
    try testing.expect(!dbEqual(H(older), H(hist)));
    try testing.expect(!dbEqual(H(cur), H(zero)));
    try testing.expect(dbHash(H(cur)) != dbHash(H(zero)));

    const s = dbShape(hist);
    try testing.expectEqual(@as(u64, 7), s.basis);
    try testing.expectEqual(@as(?u64, 3), s.as_of);
    try testing.expectEqual(@as(?u64, null), s.since);
    try testing.expect(s.history);

    const cases = [_]struct { v: Value, text: []const u8 }{
        .{ .v = cur, .text = "#nextomic/db {:basis-t 7 :mode :current}" },
        .{ .v = older, .text = "#nextomic/db {:basis-t 7 :mode :as-of :as-of 3}" },
        .{ .v = hist, .text = "#nextomic/db {:basis-t 7 :mode :history :as-of 3}" },
        .{ .v = sinc, .text = "#nextomic/db {:basis-t 7 :mode :since :since 2}" },
    };
    for (cases) |c| {
        var buf: [96]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try formatDb(c.v, &w);
        try testing.expectEqualStrings(c.text, w.buffered());
    }
}
