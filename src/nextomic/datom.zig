//! datom.zig — the Datom struct, the txlog entry codec and uuid text.
//!
//! A txlog entry (NEXTOMIC.md §2, `nx/txlog`) is bytes:
//!
//!   [flags:1] [instant: zigzag LEB] [rows: LEB] row* [excised]
//!
//! where each row is `[Δe: zigzag LEB] [a << 1 | added: LEB] [v]`, `Δe`
//! the entity less the previous row's (0 before the first), and `v`
//! typed by the attribute's value type, which never changes: a long or
//! an instant zigzag LEB, a double its 8 bits big-endian, a boolean one
//! byte, a keyword its ident id LEB, a ref its `E(e)` (key.zig), a uuid 16
//! bytes, a string or byte array of at most `key.inline_max` bytes its
//! length LEB and its bytes. A longer one is `key.inline_max + 1`, then
//! the length LEB and bytes of its index encoding after the tag (the
//! escaped prefix, `0x00 0x01` and the hash, NEXTOMIC.md §2.2): its
//! payload is the fact's, read from the index trees when the entry is
//! decoded, so the log never repeats it. Flags:
//!
//!   - `attr_partition`: a row's entity is in the attribute partition,
//!     a schema or ident change (the schema cache reads this alone);
//!   - `excised`: the entry ends with the excision marker, the count
//!     LEB and each entity LEB (NEXTOMIC.md §4 "Excision");
//!   - `instant_row`: the entry's last datom is the transaction entity's
//!     `:db/txInstant` of the header's instant, stored once, in the
//!     header, and rebuilt by the decoder.
//!
//! The decoder refuses anything else, trailing bytes included, as
//! `error.Corrupted`.

const std = @import("std");
const value = @import("../value.zig");
const bignum = @import("../bignum.zig");
const key = @import("key.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
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
    /// The entities an excision removed datoms of from this entry, or
    /// that this entry's own transaction excised; empty otherwise.
    excised: []u64,
};

/// What the decoder asks of the store: each attribute's value type, and
/// the payload of an out-of-line value from the row of the datom at
/// `t` (its EAVT row while current, else its EAVT-h one).
pub const Source = struct {
    ctx: *anyopaque,
    /// Value type of attribute `a`, or null when unknown.
    attrType: *const fn (ctx: *anyopaque, a: u32) anyerror!?ValueType,
    payload: *const fn (ctx: *anyopaque, e: u64, a: u32, vbytes: []const u8, t: u64, added: bool) anyerror![]const u8,
};

const flag_attr_partition: u8 = 1;
const flag_excised: u8 = 2;
const flag_instant_row: u8 = 4;
const flags_known = flag_attr_partition | flag_excised | flag_instant_row;
/// The length a string or byte array's row gives when its value is out
/// of line.
const out_of_line: u64 = key.inline_max + 1;

// =============================================================================
// Encode
// =============================================================================

/// Encode the entry of transaction `t` into `arena`; `excised`
/// non-empty appends the marker.
pub fn encodeTxlog(arena: Allocator, t: u64, instant: i64, datoms: []const Datom, excised: []const u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var rows = datoms;
    var flags: u8 = 0;
    if (rows.len > 0) {
        const last = rows[rows.len - 1];
        if (last.e == key.txEntity(t) and last.a == tx_instant_attr and last.added and last.v == .instant and last.v.instant == instant) {
            flags |= flag_instant_row;
            rows = rows[0 .. rows.len - 1];
        }
    }
    for (rows) |d| if (key.isAttrPartition(d.e)) {
        flags |= flag_attr_partition;
    };
    if (excised.len > 0) flags |= flag_excised;
    try out.append(arena, flags);
    try writeLeb(&out, arena, zigzag(instant));
    try writeLeb(&out, arena, rows.len);
    var prev: u64 = 0;
    for (rows) |d| {
        try writeLeb(&out, arena, zigzag(@as(i64, @bitCast(d.e -% prev))));
        prev = d.e;
        try writeLeb(&out, arena, (@as(u64, d.a) << 1) | @intFromBool(d.added));
        try writeVal(&out, arena, d.v);
    }
    if (excised.len > 0) {
        try writeLeb(&out, arena, excised.len);
        for (excised) |e| try writeLeb(&out, arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// `:db/txInstant`, a bootstrap attribute (store.zig `boot.tx_instant`).
pub const tx_instant_attr: u32 = 8;

fn writeVal(out: *std.ArrayList(u8), arena: Allocator, v: Val) !void {
    switch (v) {
        .boolean => |b| try out.append(arena, @intFromBool(b)),
        .long, .instant => |n| try writeLeb(out, arena, zigzag(n)),
        .double => |d| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @bitCast(d), .big);
            try out.appendSlice(arena, &buf);
        },
        .keyword => |id| try writeLeb(out, arena, id),
        .ref => |eid| try key.appendEntity(out, arena, eid),
        .uuid => |u| try out.appendSlice(arena, &u),
        .string, .bytes => |s| {
            if (s.len <= key.inline_max) {
                try writeLeb(out, arena, s.len);
                return out.appendSlice(arena, s);
            }
            const vbytes = try key.valBytes(arena, v);
            try writeLeb(out, arena, out_of_line);
            try writeLeb(out, arena, vbytes.len - 1);
            try out.appendSlice(arena, vbytes[1..]);
        },
    }
}

fn zigzag(n: i64) u64 {
    return @bitCast((n << 1) ^ (n >> 63));
}

fn unzigzag(u: u64) i64 {
    return @as(i64, @bitCast(u >> 1)) ^ -@as(i64, @bitCast(u & 1));
}

fn writeLeb(out: *std.ArrayList(u8), arena: Allocator, n: u64) !void {
    var x = n;
    while (x >= 0x80) : (x >>= 7) try out.append(arena, @as(u8, @truncate(x)) | 0x80);
    try out.append(arena, @truncate(x));
}

// =============================================================================
// Decode
// =============================================================================

/// A reader over an entry's bytes; every overrun is `error.Corrupted`.
const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.at >= self.bytes.len) return error.Corrupted;
        defer self.at += 1;
        return self.bytes[self.at];
    }

    fn take(self: *Reader, n: u64) ![]const u8 {
        if (n > self.bytes.len - self.at) return error.Corrupted;
        defer self.at += @intCast(n);
        return self.bytes[self.at..][0..@intCast(n)];
    }

    /// An unsigned LEB128 of at most 64 bits, in its shortest form.
    fn leb(self: *Reader) !u64 {
        var n: u64 = 0;
        var shift: u7 = 0;
        while (true) : (shift += 7) {
            const b = try self.byte();
            if (shift == 63 and b > 1) return error.Corrupted;
            n |= @as(u64, b & 0x7F) << @intCast(shift);
            if (b & 0x80 == 0) {
                if (b == 0 and shift > 0) return error.Corrupted;
                return n;
            }
            if (shift == 63) return error.Corrupted;
        }
    }

    fn done(self: *const Reader) bool {
        return self.at == self.bytes.len;
    }
};

/// One row as stored: the value's bytes undecoded.
const RawRow = struct { e: u64, a: u32, added: bool, v: []const u8 };

/// The header and the raw rows of an entry.
const Raw = struct {
    flags: u8,
    instant: i64,
    rows: []RawRow,
    excised: []u64,
};

fn parse(arena: Allocator, bytes: []const u8, types: Source) !Raw {
    var r: Reader = .{ .bytes = bytes };
    const flags = try r.byte();
    if (flags & ~flags_known != 0) return error.Corrupted;
    const instant = unzigzag(try r.leb());
    const n = try r.leb();
    // Every row takes at least three bytes.
    if (n > bytes.len / 3) return error.Corrupted;
    const rows = try arena.alloc(RawRow, @intCast(n));
    var prev: u64 = 0;
    for (rows) |*row| {
        const e = prev +% @as(u64, @bitCast(unzigzag(try r.leb())));
        if (e > key.id_max) return error.Corrupted;
        prev = e;
        const aa = try r.leb();
        if (aa >> 1 > std.math.maxInt(u32)) return error.Corrupted;
        const a: u32 = @intCast(aa >> 1);
        const vt = (try types.attrType(types.ctx, a)) orelse return error.Corrupted;
        const start = r.at;
        try skipVal(&r, vt);
        row.* = .{ .e = e, .a = a, .added = aa & 1 == 1, .v = bytes[start..r.at] };
    }
    var excised: []u64 = &.{};
    if (flags & flag_excised != 0) {
        const m = try r.leb();
        if (m == 0 or m > bytes.len) return error.Corrupted;
        excised = try arena.alloc(u64, @intCast(m));
        for (excised) |*e| {
            e.* = try r.leb();
            if (e.* > key.id_max) return error.Corrupted;
        }
    }
    if (!r.done()) return error.Corrupted;
    return .{ .flags = flags, .instant = instant, .rows = rows, .excised = excised };
}

fn skipVal(r: *Reader, vt: ValueType) !void {
    switch (vt) {
        .boolean => if (try r.byte() > 1) return error.Corrupted,
        .long, .instant, .keyword => _ = try r.leb(),
        .ref => _ = try r.take(key.entityLen(try r.byte()) - 1),
        .double => _ = try r.take(8),
        .uuid => _ = try r.take(16),
        .string, .bytes => {
            const n = try r.leb();
            if (n <= key.inline_max) {
                _ = try r.take(n);
            } else if (n == out_of_line) {
                _ = try r.take(try r.leb());
            } else return error.Corrupted;
        },
    }
}

/// Decode the entry of transaction `t`. Datoms and their bytes live in
/// `arena`; `t` on each datom is the caller's key.
pub fn decodeTxlog(arena: Allocator, bytes: []const u8, t: u64, src: Source) !TxlogEntry {
    const raw = try parse(arena, bytes, src);
    const instant_row = raw.flags & flag_instant_row != 0;
    const datoms = try arena.alloc(Datom, raw.rows.len + @intFromBool(instant_row));
    for (raw.rows, datoms[0..raw.rows.len]) |row, *d| {
        const vt = (try src.attrType(src.ctx, row.a)) orelse return error.Corrupted;
        d.* = .{ .e = row.e, .a = row.a, .v = try decodeVal(arena, row, vt, t, src), .t = t, .added = row.added };
    }
    if (instant_row) datoms[raw.rows.len] = .{ .e = key.txEntity(t), .a = tx_instant_attr, .v = .{ .instant = raw.instant }, .t = t, .added = true };
    return .{ .instant = raw.instant, .datoms = datoms, .excised = raw.excised };
}

fn decodeVal(arena: Allocator, row: RawRow, vt: ValueType, t: u64, src: Source) !Val {
    var r: Reader = .{ .bytes = row.v };
    return switch (vt) {
        .boolean => .{ .boolean = try r.byte() == 1 },
        .long => .{ .long = unzigzag(try r.leb()) },
        .instant => .{ .instant = unzigzag(try r.leb()) },
        .double => .{ .double = @bitCast(std.mem.readInt(u64, (try r.take(8))[0..8], .big)) },
        .keyword => .{ .keyword = std.math.cast(u32, try r.leb()) orelse return error.Corrupted },
        .ref => blk: {
            const x = try key.readEntity(row.v);
            break :blk if (x.len != row.v.len) error.Corrupted else .{ .ref = x.e };
        },
        .uuid => .{ .uuid = (try r.take(16))[0..16].* },
        .string, .bytes => blk: {
            const n = try r.leb();
            const s = if (n <= key.inline_max) try arena.dupe(u8, try r.take(n)) else inner: {
                // The index encoding after its tag; the payload is the
                // fact's own.
                const digest = try r.take(try r.leb());
                const vbytes = try arena.alloc(u8, digest.len + 1);
                vbytes[0] = @backingInt(if (vt == .string) key.Tag.string else key.Tag.bytes);
                @memcpy(vbytes[1..], digest);
                const kv = try key.decodeVal(arena, vbytes);
                if (kv == .val) return error.Corrupted;
                break :inner try arena.dupe(u8, try src.payload(src.ctx, row.e, row.a, vbytes, t, row.added));
            };
            break :blk if (vt == .string) .{ .string = s } else .{ .bytes = s };
        },
    };
}

/// Whether a txlog entry holds a datom on an attribute-partition
/// entity, a schema or ident change.
pub fn touchesAttrPartition(bytes: []const u8) !bool {
    if (bytes.len == 0) return error.Corrupted;
    return bytes[0] & flag_attr_partition != 0;
}

/// The entry `bytes` of transaction `t` without the datoms of `e` (under
/// `a` when given), marked with `e`; a marker already there keeps its
/// other entities. The instant and every other row stand as stored, an
/// out-of-line value's digest included.
pub fn exciseTxlog(arena: Allocator, bytes: []const u8, e: u64, a: ?u32, types: Source) ![]u8 {
    const raw = try parse(arena, bytes, types);
    var out: std.ArrayList(u8) = .empty;
    var kept: usize = 0;
    var attr_partition = false;
    for (raw.rows) |row| {
        if (row.e == e and (a == null or row.a == a.?)) continue;
        kept += 1;
        attr_partition = attr_partition or key.isAttrPartition(row.e);
    }
    var flags: u8 = (raw.flags & flag_instant_row) | flag_excised;
    if (attr_partition) flags |= flag_attr_partition;
    try out.append(arena, flags);
    try writeLeb(&out, arena, zigzag(raw.instant));
    try writeLeb(&out, arena, kept);
    var prev: u64 = 0;
    for (raw.rows) |row| {
        if (row.e == e and (a == null or row.a == a.?)) continue;
        try writeLeb(&out, arena, zigzag(@as(i64, @bitCast(row.e -% prev))));
        prev = row.e;
        try writeLeb(&out, arena, (@as(u64, row.a) << 1) | @intFromBool(row.added));
        try out.appendSlice(arena, row.v);
    }
    const marked = std.mem.findScalar(u64, raw.excised, e) != null;
    try writeLeb(&out, arena, raw.excised.len + @intFromBool(!marked));
    for (raw.excised) |x| try writeLeb(&out, arena, x);
    if (!marked) try writeLeb(&out, arena, e);
    return out.toOwnedSlice(arena);
}

/// The i64 of a long or an instant: an integer, fixnum or bignum, in
/// i64's range; null for any other value (NEXTOMIC.md §2.2).
pub fn longOf(v: Value) ?i64 {
    return switch (v.kind()) {
        .fixnum, .bignum => bignum.toI64(v),
        else => null,
    };
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

/// The uuid whose canonical text `s` is (lower-case hex, 8-4-4-4-12),
/// or null for any other string: Nextomic takes one text per uuid, so
/// a string compares alike wherever a uuid is matched (NEXTOMIC.md
/// §2.2).
pub fn uuidFromCanonical(s: []const u8) ?[16]u8 {
    for (s) |c| if (c >= 'A' and c <= 'F') return null;
    return uuidFromText(s);
}

/// The uuid `s` spells in 8-4-4-4-12 hex digits of either case, or
/// null (`parse-uuid`).
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

/// Attribute types by id, and payloads from a table by digest.
const TestSource = struct {
    long_text: []const u8 = "",

    fn attrType(_: *anyopaque, a: u32) anyerror!?ValueType {
        return switch (a) {
            1 => .keyword,
            2 => .string,
            3 => .ref,
            4 => .uuid,
            5 => .bytes,
            6 => .double,
            7 => .boolean,
            tx_instant_attr => .instant,
            9 => .long,
            else => null,
        };
    }

    fn payload(ctx: *anyopaque, _: u64, _: u32, vbytes: []const u8, _: u64, _: bool) anyerror![]const u8 {
        const self: *TestSource = @ptrCast(@alignCast(ctx));
        var buf: [256]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const want = try key.valBytes(fba.allocator(), .{ .string = self.long_text });
        if (!std.mem.eql(u8, want[1..], vbytes[1..])) return error.Corrupted;
        return self.long_text;
    }

    fn source(self: *TestSource) Source {
        return .{ .ctx = @ptrCast(self), .attrType = &attrType, .payload = &payload };
    }
};

test "txlog entry round trips every value type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = "a string past the inline limit of ninety-six bytes, whose payload the entry leaves to the index trees";
    var ts: TestSource = .{ .long_text = long };
    const uuid = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
    const t = 7;
    const in = [_]Datom{
        .{ .e = 1 << 33, .a = 1, .v = .{ .keyword = 50 }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 2, .v = .{ .string = "hi\x00there" }, .t = t, .added = false },
        .{ .e = (1 << 33) + 5, .a = 2, .v = .{ .string = long }, .t = t, .added = true },
        .{ .e = 1 << 32, .a = 2, .v = .{ .string = "" }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 3, .v = .{ .ref = 1 << 40 }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 4, .v = .{ .uuid = uuid }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 5, .v = .{ .bytes = "\x00\x01\x02" }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 6, .v = .{ .double = -2.25 }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 7, .v = .{ .boolean = true }, .t = t, .added = true },
        .{ .e = 1 << 33, .a = 9, .v = .{ .long = -99 }, .t = t, .added = true },
        .{ .e = key.txEntity(t), .a = tx_instant_attr, .v = .{ .instant = 1234 }, .t = t, .added = true },
    };
    const bytes = try encodeTxlog(arena, t, 1234, &in, &.{});
    // The instant's datom is the header's; no row repeats the long
    // string's payload.
    try testing.expect(bytes[0] & flag_instant_row != 0 and bytes[0] & flag_attr_partition == 0);
    try testing.expect(std.mem.indexOf(u8, bytes, long[64..]) == null);
    try testing.expect(!try touchesAttrPartition(bytes));
    const out = try decodeTxlog(arena, bytes, t, ts.source());
    try testing.expectEqual(@as(i64, 1234), out.instant);
    try testing.expectEqual(in.len, out.datoms.len);
    try testing.expectEqual(@as(usize, 0), out.excised.len);
    for (in, out.datoms) |x, y| {
        try testing.expect(x.eqlFact(y));
        try testing.expectEqual(x.added, y.added);
        try testing.expectEqual(x.t, y.t);
    }
}

test "txlog entry holds longs and instants over all of i64, and flags the attribute partition" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ts: TestSource = .{};
    const edges = [_]i64{ std.math.minInt(i64), -(1 << 47) - 1, -1, 0, 1, 1 << 47, std.math.maxInt(i64) };
    var in: [2 * edges.len + 1]Datom = undefined;
    for (edges, 0..) |n, i| {
        in[2 * i] = .{ .e = 1 << 33, .a = 9, .v = .{ .long = n }, .t = 3, .added = true };
        in[2 * i + 1] = .{ .e = 1 << 33, .a = tx_instant_attr, .v = .{ .instant = n }, .t = 3, .added = true };
    }
    // An attribute entity's datom, after the user entity's: a negative Δe.
    in[2 * edges.len] = .{ .e = 9, .a = 7, .v = .{ .boolean = false }, .t = 3, .added = false };
    for (edges) |instant| {
        const bytes = try encodeTxlog(arena, 3, instant, &in, &.{});
        try testing.expect(try touchesAttrPartition(bytes));
        const out = try decodeTxlog(arena, bytes, 3, ts.source());
        try testing.expectEqual(instant, out.instant);
        try testing.expectEqual(in.len, out.datoms.len);
        for (in, out.datoms) |x, y| try testing.expect(x.eqlFact(y) and x.added == y.added);
    }
}

test "an excision rewrites an entry without its entity's rows and marks it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = "another string past the inline limit of ninety-six bytes, kept as its digest when the entry is rewritten";
    var ts: TestSource = .{ .long_text = long };
    const e: u64 = 1 << 33;
    const f: u64 = (1 << 33) + 1;
    const in = [_]Datom{
        .{ .e = e, .a = 9, .v = .{ .long = 1 }, .t = 5, .added = true },
        .{ .e = f, .a = 2, .v = .{ .string = long }, .t = 5, .added = true },
        .{ .e = e, .a = 2, .v = .{ .string = "x" }, .t = 5, .added = false },
        .{ .e = key.txEntity(5), .a = tx_instant_attr, .v = .{ .instant = 5 }, .t = 5, .added = true },
    };
    const bytes = try encodeTxlog(arena, 5, 5, &in, &.{});
    // One attribute, then the rest, then the entity again: the marker
    // names it once.
    const once = try exciseTxlog(arena, bytes, e, 9, ts.source());
    const out1 = try decodeTxlog(arena, once, 5, ts.source());
    try testing.expectEqual(@as(usize, 3), out1.datoms.len);
    try testing.expectEqualSlices(u64, &.{e}, out1.excised);
    const twice = try exciseTxlog(arena, once, e, null, ts.source());
    const out2 = try decodeTxlog(arena, twice, 5, ts.source());
    try testing.expectEqual(@as(usize, 2), out2.datoms.len);
    try testing.expect(out2.datoms[0].eqlFact(in[1]) and out2.datoms[1].eqlFact(in[3]));
    try testing.expectEqualSlices(u64, &.{e}, out2.excised);
    const other = try exciseTxlog(arena, twice, f, null, ts.source());
    const out3 = try decodeTxlog(arena, other, 5, ts.source());
    try testing.expectEqualSlices(u64, &.{ e, f }, out3.excised);
    try testing.expectEqual(@as(usize, 1), out3.datoms.len);
    // An entry emptied by excision keeps its instant and its marker.
    const empty = try encodeTxlog(arena, 6, 9, &.{}, &.{e});
    const out4 = try decodeTxlog(arena, empty, 6, ts.source());
    try testing.expectEqual(@as(usize, 0), out4.datoms.len);
    try testing.expectEqual(@as(i64, 9), out4.instant);
    try testing.expectEqualSlices(u64, &.{e}, out4.excised);
}

test "a malformed entry is Corrupted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ts: TestSource = .{};
    const good = try encodeTxlog(arena, 2, 1, &.{.{ .e = 1 << 33, .a = 9, .v = .{ .long = 300 }, .t = 2, .added = true }}, &.{});
    _ = try decodeTxlog(arena, good, 2, ts.source());
    const cases = [_][]const u8{
        &.{},
        try std.mem.concat(arena, u8, &.{ good, &.{0} }), // a trailing byte
        good[0 .. good.len - 1], // a value cut short
        &.{ 0x80, 0, 0 }, // an unknown flag
        &.{ 0, 0x80, 0x00, 0 }, // a LEB longer than it needs
        &.{ 0, 0, 1, 0, 2 << 1, 0, 0 }, // attribute 2 is a string: length 0, then a stray byte
        &.{ 0, 0, 1, 0, 50 << 1 | 1, 0 }, // an unknown attribute
        &.{ 0, 0, 1, 0, 7 << 1, 2 }, // a boolean that is neither
        &.{ 0, 0, 1, 0, 2 << 1, 98 }, // a string length past the out-of-line mark
    };
    for (cases) |bytes| try testing.expectError(error.Corrupted, decodeTxlog(arena, bytes, 2, ts.source()));
}

test "uuid text round trip" {
    const u = [_]u8{ 0xff, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    var text: [36]u8 = undefined;
    uuidToText(&text, u);
    try testing.expectEqualStrings("ff000102-0304-0506-0708-090a0b0c0d0e", &text);
    try testing.expectEqualSlices(u8, &u, &uuidFromText(&text).?);
    try testing.expect(uuidFromText("nope") == null);
    // One text per uuid: upper-case hex is not its text.
    try testing.expect(uuidFromCanonical("0123ABCD-4567-89EF-0123-456789ABCDEF") == null);
    try testing.expectEqualSlices(u8, &u, &uuidFromCanonical(&text).?);
}
