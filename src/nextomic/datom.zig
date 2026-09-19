//! datom.zig — the Datom struct, the txlog entry codec and uuid text.
//!
//! A txlog entry is the codec-encoded vector
//! `[instant [e a v added] ...]` (NEXTOMIC.md §2, `nx/txlog`). Inside
//! it `e` and `a` are fixnums, `added` a boolean and `v` the value in
//! its natural VM shape: keywords by name (durable across stores),
//! refs / longs / instants as fixnums, doubles as floats, uuids as
//! canonical text, byte arrays as strings. The entry is self-describing
//! given the attribute's value type, which the decoder asks for.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const string_mod = @import("string");
const vector_mod = @import("vector");
const codec_mod = @import("codec");
const dispatch = @import("dispatch");
const key = @import("key.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const Val = key.Val;
const ValueType = key.ValueType;

// =============================================================================
// Datom
// =============================================================================

/// One fact. `v` borrows from the arena of the operation that produced
/// the datom.
pub const Datom = struct {
    e: u64,
    a: u32,
    v: Val,
    t: u64,
    added: bool,

    pub fn eqlFact(a: Datom, b: Datom) bool {
        return a.e == b.e and a.a == b.a and a.v.eql(b.v);
    }
};

/// A decoded txlog entry.
pub const TxlogEntry = struct {
    instant: i64,
    datoms: []Datom,
};

// =============================================================================
// Name resolution seams
//
// The codec needs ident text for keyword values on the way out and
// ident ids plus attribute types on the way in. Callers supply them
// through these vtables so this file depends on no store state.
// =============================================================================

pub const NameSource = struct {
    ctx: *anyopaque,
    /// Text of ident `id`, or null when unknown.
    identName: *const fn (ctx: *anyopaque, id: u32) anyerror!?[]const u8,
};

pub const IdSource = struct {
    ctx: *anyopaque,
    /// Id of the ident with this text, or null when unknown.
    identId: *const fn (ctx: *anyopaque, name: []const u8) anyerror!?u32,
    /// Value type of attribute `a`, or null when unknown.
    attrType: *const fn (ctx: *anyopaque, a: u32) anyerror!?ValueType,
};

// =============================================================================
// Encode
// =============================================================================

/// Encode a txlog entry into `arena`.
pub fn encodeTxlog(arena: Allocator, instant: i64, datoms: []const Datom, names: NameSource) ![]u8 {
    var heap = Heap.init(arena);
    defer heap.deinit();
    var interner = Interner.init(arena);
    defer interner.deinit();

    const elems = try arena.alloc(Value, datoms.len + 1);
    elems[0] = value.fromFixnum(instant) orelse return error.Corrupted;
    for (datoms, 0..) |d, i| {
        const v = try valToTxlogValue(&heap, &interner, d.v, names);
        const row = [_]Value{
            fixnum(d.e) orelse return error.Corrupted,
            fixnum(d.a) orelse return error.Corrupted,
            v,
            value.fromBool(d.added),
        };
        elems[i + 1] = try vector_mod.fromSlice(&heap, &row);
    }
    const vec = try vector_mod.fromSlice(&heap, elems);
    return codec_mod.encode(arena, &interner, vec);
}

fn fixnum(n: u64) ?Value {
    if (n > std.math.maxInt(i64)) return null;
    return value.fromFixnum(@intCast(n));
}

fn valToTxlogValue(heap: *Heap, interner: *Interner, v: Val, names: NameSource) !Value {
    return switch (v) {
        .boolean => |b| value.fromBool(b),
        .long => |n| value.fromFixnum(n) orelse error.Corrupted,
        .double => |d| value.fromFloat(d),
        .instant => |n| value.fromFixnum(n) orelse error.Corrupted,
        .keyword => |id| blk: {
            const name = (try names.identName(names.ctx, id)) orelse return error.UnknownIdent;
            break :blk try interner.internKeywordValue(name);
        },
        .ref => |eid| fixnum(eid) orelse error.Corrupted,
        .string => |s| try string_mod.fromBytes(heap, s),
        .uuid => |u| blk: {
            var text: [36]u8 = undefined;
            uuidToText(&text, u);
            break :blk try string_mod.fromBytes(heap, &text);
        },
        .bytes => |b| try string_mod.fromBytes(heap, b),
    };
}

// =============================================================================
// Decode
// =============================================================================

/// Decode a txlog entry. Datoms and their borrowed bytes live in `arena`;
/// `t` on each datom is set from the caller's key.
pub fn decodeTxlog(arena: Allocator, bytes: []const u8, t: u64, ids: IdSource) !TxlogEntry {
    var heap = Heap.init(arena);
    defer heap.deinit();
    var interner = Interner.init(arena);
    defer interner.deinit();

    const vec = codec_mod.decode(&heap, &interner, bytes, &dispatch.hashValue, &dispatch.equal) catch return error.Corrupted;
    if (vec.kind() != .persistent_vector) return error.Corrupted;
    const n = vector_mod.count(vec);
    if (n == 0) return error.Corrupted;
    const inst = vector_mod.nth(vec, 0);
    if (inst.kind() != .fixnum) return error.Corrupted;

    const datoms = try arena.alloc(Datom, n - 1);
    for (datoms, 1..) |*d, i| {
        const row = vector_mod.nth(vec, i);
        if (row.kind() != .persistent_vector or vector_mod.count(row) != 4) return error.Corrupted;
        const e = vector_mod.nth(row, 0);
        const a = vector_mod.nth(row, 1);
        const v = vector_mod.nth(row, 2);
        const added = vector_mod.nth(row, 3);
        if (e.kind() != .fixnum or a.kind() != .fixnum or !added.isBool()) return error.Corrupted;
        if (e.asFixnum() < 0 or a.asFixnum() < 0 or a.asFixnum() > std.math.maxInt(u32)) return error.Corrupted;
        const attr: u32 = @intCast(a.asFixnum());
        const vt = try ids.attrType(ids.ctx, attr);
        d.* = .{
            .e = @intCast(e.asFixnum()),
            .a = attr,
            .v = try txlogValueToVal(arena, &interner, v, vt, ids),
            .t = t,
            .added = added.asBool(),
        };
    }
    return .{ .instant = inst.asFixnum(), .datoms = datoms };
}

fn txlogValueToVal(arena: Allocator, interner: *const Interner, v: Value, vt: ?ValueType, ids: IdSource) !Val {
    switch (v.kind()) {
        .true_, .false_ => return .{ .boolean = v.asBool() },
        .fixnum => {
            const n = v.asFixnum();
            return switch (vt orelse .long) {
                .instant => .{ .instant = n },
                .ref => if (n < 0) error.Corrupted else .{ .ref = @intCast(n) },
                else => .{ .long = n },
            };
        },
        .float => return .{ .double = v.asFloat() },
        .keyword => {
            const name = interner.keywordName(v.asKeywordId());
            const id = (try ids.identId(ids.ctx, name)) orelse return error.UnknownIdent;
            return .{ .keyword = id };
        },
        .string => {
            const s = string_mod.asBytes(v);
            return switch (vt orelse .string) {
                .uuid => .{ .uuid = uuidFromText(s) orelse return error.Corrupted },
                .bytes => .{ .bytes = try arena.dupe(u8, s) },
                else => .{ .string = try arena.dupe(u8, s) },
            };
        },
        else => return error.Corrupted,
    }
}

// =============================================================================
// UUID text (8-4-4-4-12, lower-case hex)
// =============================================================================

pub fn uuidToText(out: *[36]u8, u: [16]u8) void {
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (u, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b >> 4];
        out[o + 1] = hex[b & 0xF];
        o += 2;
    }
}

pub fn uuidFromText(s: []const u8) ?[16]u8 {
    if (s.len != 36) return null;
    var out: [16]u8 = undefined;
    var o: usize = 0;
    var i: usize = 0;
    while (i < 36) {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (s[i] != '-') return null;
            i += 1;
            continue;
        }
        const hi = std.fmt.charToDigit(s[i], 16) catch return null;
        const lo = std.fmt.charToDigit(s[i + 1], 16) catch return null;
        out[o] = (hi << 4) | lo;
        o += 1;
        i += 2;
    }
    return out;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const TestNames = struct {
    fn identName(_: *anyopaque, id: u32) anyerror!?[]const u8 {
        return switch (id) {
            9 => "db.type/long",
            50 => "color/red",
            else => null,
        };
    }
    fn identId(_: *anyopaque, name: []const u8) anyerror!?u32 {
        if (std.mem.eql(u8, name, "db.type/long")) return 9;
        if (std.mem.eql(u8, name, "color/red")) return 50;
        return null;
    }
    fn attrType(_: *anyopaque, a: u32) anyerror!?ValueType {
        return switch (a) {
            1 => .keyword,
            2 => .string,
            3 => .ref,
            4 => .instant,
            5 => .uuid,
            6 => .bytes,
            7 => .double,
            8 => .boolean,
            else => .long,
        };
    }
};

test "txlog entry round trips every value type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var dummy: u8 = 0;
    const names: NameSource = .{ .ctx = @ptrCast(&dummy), .identName = &TestNames.identName };
    const ids: IdSource = .{ .ctx = @ptrCast(&dummy), .identId = &TestNames.identId, .attrType = &TestNames.attrType };

    const uuid = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    const in = [_]Datom{
        .{ .e = 1 << 33, .a = 1, .v = .{ .keyword = 50 }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 2, .v = .{ .string = "hi\x00there" }, .t = 0, .added = false },
        .{ .e = 1 << 33, .a = 3, .v = .{ .ref = 1 << 40 }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 4, .v = .{ .instant = -5 }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 5, .v = .{ .uuid = uuid }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 6, .v = .{ .bytes = "\x00\x01\x02" }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 7, .v = .{ .double = -2.25 }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 8, .v = .{ .boolean = true }, .t = 0, .added = true },
        .{ .e = 1 << 33, .a = 9, .v = .{ .long = -99 }, .t = 0, .added = true },
    };
    const bytes = try encodeTxlog(arena, 1234, &in, names);
    const out = try decodeTxlog(arena, bytes, 7, ids);
    try testing.expectEqual(@as(i64, 1234), out.instant);
    try testing.expectEqual(in.len, out.datoms.len);
    for (in, out.datoms) |x, y| {
        try testing.expect(x.eqlFact(y));
        try testing.expectEqual(x.added, y.added);
        try testing.expectEqual(@as(u64, 7), y.t);
    }
}

test "uuid text round trip" {
    const u = [_]u8{ 0xff, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    var text: [36]u8 = undefined;
    uuidToText(&text, u);
    try testing.expectEqualStrings("ff000102-0304-0506-0708-090a0b0c0d0e", &text);
    try testing.expectEqualSlices(u8, &u, &uuidFromText(&text).?);
    try testing.expect(uuidFromText("nope") == null);
}
