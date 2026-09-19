//! marshal.zig — VM values to and from datom values, one contract per
//! direction, shared by the natives, the query engine, pull and
//! transactions.
//!
//! Contracts:
//!   - `entity`: an entity reference is a fixnum id, a keyword ident or
//!     a lookup ref `[attr v]`. A fixnum below 1 is `NoEntity` (a
//!     fixnum cannot exceed `key.id_max`, which is `value.fixnum_max`);
//!     an ident or lookup that names nothing in the view is
//!     null, and the caller decides what that means; a lookup ref on an
//!     unknown attribute is `UnknownAttribute`, on a non-unique one
//!     `TxData`, with a value of the wrong type `ValueType`; a vector
//!     of any other shape is `TxData`; any other kind is
//!     `KindMismatch`. `fault` names the attribute or carries the
//!     reason.
//!   - `valOf`: a VM value under an attribute's type; null when a
//!     keyword or entity reference names nothing (no datom can match
//!     it), `ValueType` on a kind mismatch.
//!   - `encodeCell`: a query cell under an attribute's type; null when
//!     no value of that type equals it, never an error, because a
//!     query constant of the wrong type matches nothing.
//!   - `cellOf`: a datom value as the query engine compares it: ids
//!     as `int`, keywords as VM keyword ids.
//!   - `sequence` and `collection`: the elements of a vector or list,
//!     or of a vector, list or set; null for any other kind.

const std = @import("std");
const value = @import("value");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const key = @import("key.zig");
const datom_mod = @import("datom.zig");
const db_mod = @import("db.zig");
const schema_mod = @import("schema.zig");
const relation = @import("relation.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Read = db_mod.Read;
const Fault = db_mod.Fault;
const Attr = schema_mod.Attr;
const Val = key.Val;
const Cell = relation.Cell;

// =============================================================================
// Sequences
// =============================================================================

/// The elements of a vector or list; null for any other kind.
pub fn sequence(arena: Allocator, v: Value) !?[]Value {
    return switch (v.kind()) {
        .persistent_vector, .list => collection(arena, v),
        else => null,
    };
}

/// The elements of a vector, list or set; null for any other kind.
pub fn collection(arena: Allocator, v: Value) !?[]Value {
    var out: std.ArrayList(Value) = .empty;
    switch (v.kind()) {
        .persistent_vector => {
            var it = vector_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .list => {
            var it = list_mod.Cursor.init(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        .persistent_set => {
            var it = champ.setIter(v);
            while (it.next()) |x| try out.append(arena, x);
        },
        else => return null,
    }
    return try out.toOwnedSlice(arena);
}

// =============================================================================
// Attributes and entities
// =============================================================================

/// The attribute a program named as `v`: a keyword ident or a fixnum
/// id. `UnknownAttribute`, naming it in `fault`, when there is none.
pub fn attrOf(rd: *Read, v: Value, fault: *Fault) !Attr {
    const id: u32 = switch (v.kind()) {
        .keyword => (try rd.db.conn.idents.idOf(rd.txn, v.asKeywordId())) orelse 0,
        .fixnum => blk: {
            const n = v.asFixnum();
            break :blk if (n <= 0 or n > std.math.maxInt(u32)) 0 else @intCast(n);
        },
        else => return error.KindMismatch,
    };
    if (id != 0) {
        if (try rd.attr(id)) |attr| return attr;
    }
    fault.* = .{ .attr = v };
    return error.UnknownAttribute;
}

/// The entity `v` refers to (see the module contract).
pub fn entity(rd: *Read, arena: Allocator, v: Value, fault: *Fault) anyerror!?u64 {
    switch (v.kind()) {
        .fixnum => {
            const n = v.asFixnum();
            if (n <= 0 or n > @as(i64, @intCast(key.id_max))) return error.NoEntity;
            return @intCast(n);
        },
        .keyword => return rd.entid(arena, .{ .ident = v.asKeywordId() }),
        .persistent_vector => {
            if (vector_mod.count(v) != 2 or vector_mod.nth(v, 0).kind() != .keyword) {
                fault.* = .{ .message = "a lookup ref is [attr value]" };
                return error.TxData;
            }
            const attr = try attrOf(rd, vector_mod.nth(v, 0), fault);
            if (attr.unique == .none) {
                fault.* = .{ .message = "a lookup ref needs a unique attribute", .attr = vector_mod.nth(v, 0) };
                return error.TxData;
            }
            const lv = (try valOf(rd, arena, attr.value_type, vector_mod.nth(v, 1), fault)) orelse return null;
            return rd.entid(arena, .{ .lookup = .{ .a = attr.id, .v = lv } });
        },
        else => return error.KindMismatch,
    }
}

// =============================================================================
// Values
// =============================================================================

/// The datom value of a VM value under type `vt` (see the module
/// contract).
pub fn valOf(rd: *Read, arena: Allocator, vt: key.ValueType, v: Value, fault: *Fault) anyerror!?Val {
    switch (vt) {
        .boolean => {
            if (!v.isBool()) return error.ValueType;
            return .{ .boolean = v.asBool() };
        },
        .long => {
            if (v.kind() != .fixnum) return error.ValueType;
            return .{ .long = v.asFixnum() };
        },
        .double => {
            if (v.kind() != .float) return error.ValueType;
            const d = v.asFloat();
            if (std.math.isNan(d)) return error.ValueType;
            return .{ .double = d };
        },
        .instant => {
            if (v.kind() != .fixnum) return error.ValueType;
            return .{ .instant = v.asFixnum() };
        },
        .keyword => {
            if (v.kind() != .keyword) return error.ValueType;
            const id = (try rd.db.conn.idents.idOf(rd.txn, v.asKeywordId())) orelse return null;
            return .{ .keyword = id };
        },
        .ref => {
            const e = entity(rd, arena, v, fault) catch |err| switch (err) {
                error.KindMismatch => return error.ValueType,
                else => return err,
            };
            return .{ .ref = e orelse return null };
        },
        .string => {
            if (v.kind() != .string) return error.ValueType;
            return .{ .string = string_mod.asBytes(v) };
        },
        .uuid => {
            if (v.kind() != .string) return error.ValueType;
            return .{ .uuid = datom_mod.uuidFromText(string_mod.asBytes(v)) orelse return error.ValueType };
        },
        .bytes => {
            if (v.kind() != .string) return error.ValueType;
            return .{ .bytes = string_mod.asBytes(v) };
        },
    }
}

/// The datom value of `cell` under type `vt` (see the module contract).
/// Keywords are resolved through the store's idents; an unknown ident
/// is null.
pub fn encodeCell(read: *Read, cell: Cell, vt: key.ValueType) anyerror!?Val {
    return switch (vt) {
        .boolean => if (cell == .boolean) .{ .boolean = cell.boolean } else null,
        .long => if (cell == .int) .{ .long = cell.int } else null,
        .double => if (cell == .double) .{ .double = cell.double } else null,
        .instant => if (cell == .int) .{ .instant = cell.int } else null,
        .keyword => blk: {
            if (cell != .keyword) break :blk null;
            const id = (try read.db.conn.idents.idOf(read.txn, cell.keyword)) orelse break :blk null;
            break :blk .{ .keyword = id };
        },
        .ref => blk: {
            const eid = cell.asEid() orelse break :blk null;
            break :blk .{ .ref = eid };
        },
        .string => if (cell == .str) .{ .string = cell.str } else null,
        .uuid => blk: {
            if (cell != .str) break :blk null;
            const u = datom_mod.uuidFromText(cell.str) orelse break :blk null;
            break :blk .{ .uuid = u };
        },
        .bytes => if (cell == .str) .{ .bytes = cell.str } else null,
    };
}

/// The cell a datom value compares as (see the module contract). A
/// keyword the store knows but the interner does not is `Corrupted`.
pub fn cellOf(read: *Read, arena: Allocator, v: Val) !Cell {
    return switch (v) {
        .boolean => |b| .{ .boolean = b },
        .long, .instant => |n| .{ .int = n },
        .double => |d| .{ .double = d },
        .keyword => |id| .{ .keyword = (try read.db.conn.idents.internOf(read.txn, id)) orelse return error.Corrupted },
        .ref => |e| .{ .int = @intCast(e) },
        .string, .bytes => |s| .{ .str = s },
        .uuid => |u| blk: {
            const text = try arena.alloc(u8, 36);
            datom_mod.uuidToText(text[0..36], u);
            break :blk .{ .str = text };
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const TestConn = db_mod.TestConn;
const Heap = @import("heap").Heap;
const string_mod = @import("string");
const boot = @import("store.zig").boot;

test "marshalling both ways for every value type" {
    const tc = try TestConn.init("marshal_round_trip");
    defer tc.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const db = try tc.conn.db();
    var rd = try db.beginRead();
    defer rd.close();
    const conn = tc.conn;
    var fault: Fault = .{};

    // Lisp → Val → Lisp, one round trip per type.
    const kw_string = try tc.interner.internKeywordValue("db.type/string");
    const kw_ident = try tc.interner.internKeywordValue("db/ident");
    const kw_doc = try tc.interner.internKeywordValue("db/doc");
    const uuid_text = try string_mod.fromBytes(&heap, "0123abcd-4567-89ef-0123-456789abcdef");
    const lookup = try vector_mod.fromSlice(&heap, &.{ kw_ident, kw_doc });

    const b = (try valOf(&rd, arena, .boolean, value.fromBool(true), &fault)).?;
    try testing.expect(b.boolean);
    try testing.expect((try conn.valToValue(rd.txn, &heap, b)).asBool());

    const n = (try valOf(&rd, arena, .long, value.fromFixnum(-42).?, &fault)).?;
    try testing.expectEqual(@as(i64, -42), n.long);
    try testing.expectEqual(@as(i64, -42), (try conn.valToValue(rd.txn, &heap, n)).asFixnum());

    const f = (try valOf(&rd, arena, .double, value.fromFloat(2.5), &fault)).?;
    try testing.expectEqual(@as(f64, 2.5), f.double);
    try testing.expectEqual(@as(f64, 2.5), (try conn.valToValue(rd.txn, &heap, f)).asFloat());

    const i = (try valOf(&rd, arena, .instant, value.fromFixnum(1_700_000_000_000).?, &fault)).?;
    try testing.expectEqual(@as(i64, 1_700_000_000_000), i.instant);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), (try conn.valToValue(rd.txn, &heap, i)).asFixnum());

    const k = (try valOf(&rd, arena, .keyword, kw_string, &fault)).?;
    try testing.expectEqual(@as(u32, boot.type_string), k.keyword);
    try testing.expectEqual(kw_string.asKeywordId(), (try conn.valToValue(rd.txn, &heap, k)).asKeywordId());

    const r = (try valOf(&rd, arena, .ref, value.fromFixnum(boot.doc).?, &fault)).?;
    try testing.expectEqual(@as(u64, boot.doc), r.ref);
    try testing.expectEqual(@as(i64, boot.doc), (try conn.valToValue(rd.txn, &heap, r)).asFixnum());
    try testing.expectEqual(@as(u64, boot.doc), (try valOf(&rd, arena, .ref, kw_doc, &fault)).?.ref);
    try testing.expectEqual(@as(u64, boot.doc), (try valOf(&rd, arena, .ref, lookup, &fault)).?.ref);

    const s = (try valOf(&rd, arena, .string, try string_mod.fromBytes(&heap, "héllo"), &fault)).?;
    try testing.expectEqualStrings("héllo", s.string);
    try testing.expectEqualStrings("héllo", string_mod.asBytes(try conn.valToValue(rd.txn, &heap, s)));

    const u = (try valOf(&rd, arena, .uuid, uuid_text, &fault)).?;
    try testing.expectEqual(@as(u8, 0x01), u.uuid[0]);
    try testing.expectEqualStrings("0123abcd-4567-89ef-0123-456789abcdef", string_mod.asBytes(try conn.valToValue(rd.txn, &heap, u)));

    const by = (try valOf(&rd, arena, .bytes, try string_mod.fromBytes(&heap, "\x00\x01"), &fault)).?;
    try testing.expectEqualStrings("\x00\x01", by.bytes);
    try testing.expectEqualStrings("\x00\x01", string_mod.asBytes(try conn.valToValue(rd.txn, &heap, by)));

    // Names that resolve to nothing match nothing.
    const kw_none = try tc.interner.internKeywordValue("nope/nope");
    try testing.expect((try valOf(&rd, arena, .keyword, kw_none, &fault)) == null);
    try testing.expect((try valOf(&rd, arena, .ref, kw_none, &fault)) == null);

    // Kind mismatches are `:nextomic/value-type` for every type.
    const wrong = try string_mod.fromBytes(&heap, "x");
    try testing.expectError(error.ValueType, valOf(&rd, arena, .boolean, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .long, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .double, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .instant, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .keyword, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .ref, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .string, value.fromFixnum(1).?, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .uuid, wrong, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .bytes, value.fromFixnum(1).?, &fault));
    try testing.expectError(error.ValueType, valOf(&rd, arena, .double, value.fromFloat(std.math.nan(f64)), &fault));

    // Entity references.
    try testing.expectEqual(@as(?u64, boot.doc), try entity(&rd, arena, kw_doc, &fault));
    try testing.expect((try entity(&rd, arena, kw_none, &fault)) == null);
    try testing.expectError(error.NoEntity, entity(&rd, arena, value.fromFixnum(0).?, &fault));
    try testing.expectError(error.KindMismatch, entity(&rd, arena, wrong, &fault));
    const bad_lookup = try vector_mod.fromSlice(&heap, &.{ kw_doc, wrong });
    try testing.expectError(error.TxData, entity(&rd, arena, bad_lookup, &fault));
    try testing.expect(fault.message != null);
    const short = try vector_mod.fromSlice(&heap, &.{kw_doc});
    try testing.expectError(error.TxData, entity(&rd, arena, short, &fault));
    try testing.expect(fault.message != null);
    const not_ref = try vector_mod.fromSlice(&heap, &.{ wrong, wrong });
    try testing.expectError(error.TxData, entity(&rd, arena, not_ref, &fault));
    try testing.expectError(error.UnknownAttribute, attrOf(&rd, kw_none, &fault));
    try testing.expectEqual(kw_none.asKeywordId(), fault.attr.?.asKeywordId());
}
