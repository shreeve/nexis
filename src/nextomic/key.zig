//! key.zig — sortable value encodings and index key layout (NEXTOMIC.md §2).
//!
//! Every datom component becomes bytes whose unsigned lexicographic
//! order is the index order emdb sees. Invariants:
//!
//!   - One tag byte orders types; within a type, byte order equals
//!     value order (`test/prop/nextomic_key.zig` sweeps every type).
//!   - An entity id in a key is `E(e)` (`appendEntity`): a header
//!     byte, its partition's class in the high nibble and a count `n`
//!     in the low, then `n` bytes of the id's offset in its partition,
//!     big-endian and minimal. An attribute or ident id in a key is
//!     `A(a)`, an ordered varint (`appendOrdered`): 1 byte up to 240, 2
//!     up to 2287, 3 up to 67823, then a length byte and 3 or 4 bytes.
//!     Each has byte order equal to numeric order, gives its own length
//!     in its first byte, and decodes only in its shortest form, so
//!     equal ids have equal bytes. `sys` and `nx/idents` keep ids in 6
//!     and 4 fixed bytes; `top = (t << 1) | added` is 6 bytes.
//!   - A key parses forward: every field but `v` gives its own length,
//!     and `v` runs to the next fixed field or the key's end.
//!   - Strings and byte arrays carry one tag each. Up to `inline_max`
//!     bytes they are stored inline; longer ones become an equality key
//!     (the escaped 64-byte prefix, then `0x00`, `out_of_line_mark` and
//!     the 128-bit hash) and the full payload lives beside `t` in the
//!     fact's current EAVT row, and on its retired EAVT-h assertion
//!     rows.
//!     The one tag keeps byte order equal to value order across the
//!     threshold whenever two values differ within their first 64 bytes.
//!   - `-0.0` is stored as `+0.0`; NaN is refused with `error.ValueType`.

const std = @import("std");
const xxhash3 = @import("../xxhash3.zig");

const Allocator = std.mem.Allocator;

// =============================================================================
// Widths and limits
// =============================================================================

/// Bytes of an entity id or a `t` in a fixed field: `sys`, the
/// current trees' values, the txlog's keys.
pub const id_len = 6;
/// Bytes of an attribute or ident id in the `sys` and `nx/idents` trees.
pub const attr_len = 4;
/// Most bytes of `A(a)`, an attribute or ident id in an index key.
pub const attr_key_max = 5;
/// Most bytes of `E(e)`, an entity id in an index key.
pub const entity_key_max = 7;
/// Bytes of `top` in a history key.
pub const top_len = 6;
/// Largest string or byte array stored inline in a key.
pub const inline_max = 96;
/// Escaped-prefix length of an out-of-line string or byte array.
pub const prefix_len = 64;
/// Bytes of the out-of-line hash.
pub const hash_len = 16;
/// The byte after the `0x00` that ends an out-of-line prefix. An inline
/// encoding has no bare `0x00` before its terminator and nothing after
/// it, so the marker tells the two shapes apart whatever the hash holds.
pub const out_of_line_mark: u8 = 0x01;

/// Ids are stored in 6 bytes and every id fits the VM's i48 fixnum, so
/// the usable range is `0 .. 2^47-1`.
pub const id_max: u64 = (1 << 47) - 1;
/// Attribute and ident partition: `1 .. 2^32-1`.
pub const attr_partition_end: u64 = 1 << 32;
/// User entity partition: `2^32 .. 2^46-1`.
pub const user_partition_start: u64 = 1 << 32;
pub const user_partition_end: u64 = 1 << 46;
/// Transaction entities are `tx_partition_bit | t`, `t < 2^46`.
pub const tx_partition_bit: u64 = 1 << 46;

/// Entity id of the transaction with logical number `t`.
pub inline fn txEntity(t: u64) u64 {
    std.debug.assert(t < tx_partition_bit);
    return tx_partition_bit | t;
}

/// The logical `t` of a transaction entity id, or null for other ids.
pub inline fn txOfEntity(e: u64) ?u64 {
    if (e & tx_partition_bit == 0) return null;
    return e & (tx_partition_bit - 1);
}

pub inline fn isAttrPartition(e: u64) bool {
    return e >= 1 and e < attr_partition_end;
}

// =============================================================================
// Type tags (§2.2)
// =============================================================================

pub const Tag = enum(u8) {
    bool_false = 0x02,
    bool_true = 0x03,
    long = 0x10,
    double = 0x18,
    instant = 0x20,
    keyword = 0x30,
    ref = 0x40,
    string = 0x50,
    uuid = 0x60,
    bytes = 0x70,
};

/// Attribute value types (`:db/valueType`).
pub const ValueType = enum(u8) {
    boolean,
    long,
    double,
    instant,
    keyword,
    ref,
    string,
    uuid,
    bytes,

    pub fn identName(self: ValueType) []const u8 {
        return switch (self) {
            .boolean => "db.type/boolean",
            .long => "db.type/long",
            .double => "db.type/double",
            .instant => "db.type/instant",
            .keyword => "db.type/keyword",
            .ref => "db.type/ref",
            .string => "db.type/string",
            .uuid => "db.type/uuid",
            .bytes => "db.type/bytes",
        };
    }
};

// =============================================================================
// Val — a datom value in Zig
// =============================================================================

/// A datom value. Slices borrow from whatever arena decoded or
/// received them; a `Val` never owns memory.
pub const Val = union(ValueType) {
    boolean: bool,
    long: i64,
    double: f64,
    instant: i64,
    /// Ident id from `nx/idents`.
    keyword: u32,
    /// Entity id.
    ref: u64,
    string: []const u8,
    uuid: [16]u8,
    bytes: []const u8,

    pub fn valueType(self: Val) ValueType {
        return std.meta.activeTag(self);
    }

    /// Is this value stored out of line (equality key + payload)?
    pub fn isOutOfLine(self: Val) bool {
        return switch (self) {
            .string => |s| s.len > inline_max,
            .bytes => |b| b.len > inline_max,
            else => false,
        };
    }

    /// Value equality within one type; different types are never equal.
    pub fn eql(a: Val, b: Val) bool {
        if (a.valueType() != b.valueType()) return false;
        return switch (a) {
            .boolean => |x| x == b.boolean,
            .long => |x| x == b.long,
            .double => |x| normalizeDouble(x) == normalizeDouble(b.double),
            .instant => |x| x == b.instant,
            .keyword => |x| x == b.keyword,
            .ref => |x| x == b.ref,
            .string => |x| std.mem.eql(u8, x, b.string),
            .uuid => |x| std.mem.eql(u8, &x, &b.uuid),
            .bytes => |x| std.mem.eql(u8, x, b.bytes),
        };
    }

    /// Total order matching the encoded byte order within one type.
    /// Callers compare values of one type only.
    pub fn order(a: Val, b: Val) std.math.Order {
        std.debug.assert(a.valueType() == b.valueType());
        return switch (a) {
            .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
            .long => |x| std.math.order(x, b.long),
            .double => |x| std.math.order(normalizeDouble(x), normalizeDouble(b.double)),
            .instant => |x| std.math.order(x, b.instant),
            .keyword => |x| std.math.order(x, b.keyword),
            .ref => |x| std.math.order(x, b.ref),
            .string => |x| std.mem.order(u8, x, b.string),
            .uuid => |x| std.mem.order(u8, &x, &b.uuid),
            .bytes => |x| std.mem.order(u8, x, b.bytes),
        };
    }

    /// Copy the borrowed bytes of a string or byte value into `gpa`.
    pub fn dupe(self: Val, gpa: Allocator) !Val {
        return switch (self) {
            .string => |s| .{ .string = try gpa.dupe(u8, s) },
            .bytes => |b| .{ .bytes = try gpa.dupe(u8, b) },
            else => self,
        };
    }
};

fn normalizeDouble(d: f64) f64 {
    return if (d == 0.0) 0.0 else d;
}

// =============================================================================
// Fixed-width fields
// =============================================================================

pub fn writeId(out: *[id_len]u8, id: u64) void {
    std.debug.assert(id <= id_max);
    std.mem.writeInt(u48, out, @intCast(id), .big);
}

/// An id read from file bytes: one past `id_max` is corrupt, since no
/// allocator hands it out and `writeId` refuses it.
pub fn readId(in: *const [id_len]u8) DecodeError!u64 {
    const id = std.mem.readInt(u48, in, .big);
    return if (id > id_max) error.Corrupted else id;
}

/// A transaction number read from the file: below the tx-partition
/// bit, as every `t` is (§2.1).
pub fn readT(in: *const [id_len]u8) DecodeError!u64 {
    const t = std.mem.readInt(u48, in, .big);
    return if (t >= tx_partition_bit) error.Corrupted else t;
}

pub fn writeAttr(out: *[attr_len]u8, a: u32) void {
    std.mem.writeInt(u32, out, a, .big);
}

pub fn readAttr(in: *const [attr_len]u8) u32 {
    return std.mem.readInt(u32, in, .big);
}

// =============================================================================
// Ordered varints (SQLite4's): byte order is numeric order, and the
// first byte gives the length.
// =============================================================================

/// Most bytes of an ordered varint.
pub const ordered_max = 9;

/// The ordered varint of `n` in `buf`.
pub fn writeOrdered(buf: *[ordered_max]u8, n: u64) []const u8 {
    if (n <= 240) {
        buf[0] = @intCast(n);
        return buf[0..1];
    }
    if (n <= 2287) {
        buf[0] = @intCast(241 + (n - 240) / 256);
        buf[1] = @intCast((n - 240) % 256);
        return buf[0..2];
    }
    if (n <= 67823) {
        buf[0] = 249;
        std.mem.writeInt(u16, buf[1..3], @intCast(n - 2288), .big);
        return buf[0..3];
    }
    // A length byte, 250 for three bytes up to 255 for eight, then `n`.
    const bytes: usize = @max(3, (64 - @clz(n) + 7) / 8);
    buf[0] = @intCast(250 + bytes - 3);
    var be: [8]u8 = undefined;
    std.mem.writeInt(u64, &be, n, .big);
    @memcpy(buf[1..][0..bytes], be[8 - bytes ..]);
    return buf[0 .. 1 + bytes];
}

pub fn appendOrdered(out: *std.ArrayList(u8), gpa: Allocator, n: u64) !void {
    var buf: [ordered_max]u8 = undefined;
    try out.appendSlice(gpa, writeOrdered(&buf, n));
}

/// The bytes the ordered varint starting with `first` takes.
pub fn orderedLen(first: u8) usize {
    return if (first <= 240) 1 else if (first <= 248) 2 else if (first == 249) 3 else @as(usize, first) - 246;
}

/// The ordered varint at the start of `in` and its length. One longer
/// than it need be is `error.Corrupted`, so equal values have equal
/// bytes.
pub fn readOrdered(in: []const u8) DecodeError!struct { n: u64, len: usize } {
    if (in.len == 0) return error.Corrupted;
    const len = orderedLen(in[0]);
    if (in.len < len) return error.Corrupted;
    const n: u64 = switch (len) {
        1 => in[0],
        2 => 240 + 256 * @as(u64, in[0] - 241) + in[1],
        3 => 2288 + @as(u64, std.mem.readInt(u16, in[1..3], .big)),
        else => blk: {
            var n: u64 = 0;
            for (in[1..len]) |b| n = (n << 8) | b;
            // The shortest form: past three bytes' worth, a leading byte.
            if (n <= 67823 or (len > 4 and in[1] == 0)) return error.Corrupted;
            break :blk n;
        },
    };
    return .{ .n = n, .len = len };
}

/// `A(a)`, an attribute or ident id in an index key, appended.
pub fn appendAttrKey(out: *std.ArrayList(u8), gpa: Allocator, a: u32) !void {
    try appendOrdered(out, gpa, a);
}

/// `E(e)` in `buf`: the partition's class (1 attributes, 2 users, 3
/// transactions) in the header's high nibble, the offset's byte count
/// in its low, then the offset in the partition, big-endian, in as few
/// bytes as it takes. Entity 0, which no partition holds, is the bare
/// header `0x10`, which no stored key holds.
pub fn writeEntity(buf: *[entity_key_max]u8, e: u64) []const u8 {
    std.debug.assert(e <= id_max);
    const class: u8, const offset: u64 = if (e < attr_partition_end)
        .{ 1, e }
    else if (e < tx_partition_bit)
        .{ 2, e - user_partition_start }
    else
        .{ 3, e - tx_partition_bit };
    const n: usize = (64 - @clz(offset) + 7) / 8;
    buf[0] = (class << 4) | @as(u8, @intCast(n));
    var be: [8]u8 = undefined;
    std.mem.writeInt(u64, &be, offset, .big);
    @memcpy(buf[1..][0..n], be[8 - n ..]);
    return buf[0 .. 1 + n];
}

pub fn appendEntity(out: *std.ArrayList(u8), gpa: Allocator, e: u64) !void {
    var buf: [entity_key_max]u8 = undefined;
    try out.appendSlice(gpa, writeEntity(&buf, e));
}

/// The bytes the `E(e)` whose header is `first` takes.
pub fn entityLen(first: u8) usize {
    return 1 + (first & 0x0F);
}

/// The `E(e)` at the start of `in` and its length. A class outside the
/// three, an offset past its partition or spelled longer than it need
/// be, and entity 0 are `error.Corrupted`.
pub fn readEntity(in: []const u8) DecodeError!struct { e: u64, len: usize } {
    if (in.len == 0) return error.Corrupted;
    const class = in[0] >> 4;
    const n: usize = in[0] & 0x0F;
    if (class < 1 or class > 3 or n > 6 or in.len < 1 + n) return error.Corrupted;
    if (n > 0 and in[1] == 0) return error.Corrupted;
    var offset: u64 = 0;
    for (in[1..][0..n]) |b| offset = (offset << 8) | b;
    const e = switch (class) {
        1 => if (offset == 0 or offset >= attr_partition_end) return error.Corrupted else offset,
        2 => if (offset >= user_partition_end - user_partition_start) return error.Corrupted else user_partition_start + offset,
        else => if (offset >= tx_partition_bit) return error.Corrupted else tx_partition_bit + offset,
    };
    return .{ .e = e, .len = 1 + n };
}

// =============================================================================
// Current-tree values and txlog keys
// =============================================================================

/// Most bytes of a current-tree value's `t`.
pub const t_value_max = 7;

/// A current-tree value's `t`, the fact's latest assertion's, as an
/// unsigned LEB128; in `nx/eavt` an out-of-line value's payload follows.
pub fn writeCurrentT(buf: *[t_value_max]u8, t: u64) []const u8 {
    std.debug.assert(t < tx_partition_bit);
    var x = t;
    var n: usize = 0;
    while (x >= 0x80) : (x >>= 7) {
        buf[n] = @as(u8, @truncate(x)) | 0x80;
        n += 1;
    }
    buf[n] = @truncate(x);
    return buf[0 .. n + 1];
}

/// A current-tree value: its `t` and what follows it.
pub const Current = struct { t: u64, rest: []const u8 };

/// Read a current-tree value. A `t` spelled longer than it need be, or
/// one at the transaction partition or past it, is `error.Corrupted`.
pub fn readCurrent(value: []const u8) DecodeError!Current {
    var t: u64 = 0;
    for (value, 0..) |b, i| {
        if (i == t_value_max) break;
        t |= @as(u64, b & 0x7F) << @intCast(7 * i);
        if (b & 0x80 != 0) continue;
        if (b == 0 and i > 0) return error.Corrupted;
        if (t >= tx_partition_bit) return error.Corrupted;
        return .{ .t = t, .rest = value[i + 1 ..] };
    }
    return error.Corrupted;
}

/// The `nx/txlog` key of transaction `t`: its ordered varint, so the log
/// sorts by `t`.
pub fn writeTxlogKey(buf: *[ordered_max]u8, t: u64) []const u8 {
    return writeOrdered(buf, t);
}

/// The `t` an `nx/txlog` key names; anything but one ordered varint of a
/// `t` below the transaction partition is `error.Corrupted`.
pub fn readTxlogKey(k: []const u8) DecodeError!u64 {
    const r = try readOrdered(k);
    if (r.len != k.len or r.n >= tx_partition_bit) return error.Corrupted;
    return r.n;
}

/// The `A(a)` at the start of `in` and its length.
pub fn readAttrKey(in: []const u8) DecodeError!struct { a: u32, len: usize } {
    const r = try readOrdered(in);
    return .{ .a = std.math.cast(u32, r.n) orelse return error.Corrupted, .len = r.len };
}

pub const Top = struct { t: u64, added: bool };

pub fn packTop(t: u64, added: bool) u64 {
    std.debug.assert(t < tx_partition_bit);
    return (t << 1) | @intFromBool(added);
}

pub fn writeTop(out: *[top_len]u8, t: u64, added: bool) void {
    std.mem.writeInt(u48, out, @intCast(packTop(t, added)), .big);
}

pub fn readTop(in: *const [top_len]u8) DecodeError!Top {
    const raw = std.mem.readInt(u48, in, .big);
    if (raw >> 1 >= tx_partition_bit) return error.Corrupted;
    return .{ .t = raw >> 1, .added = (raw & 1) == 1 };
}

// =============================================================================
// 128-bit content hash for out-of-line values
//
// Two independent xxh3-64 lanes (seeds 0 and `hash_seed_hi`) form the
// 128-bit digest. Both lanes are stable across builds and platforms.
// =============================================================================

const hash_seed_hi: u64 = 0x9E37_79B9_7F4A_7C15;

pub fn hash128(bytes: []const u8) u128 {
    const lo = xxhash3.hash(0, bytes);
    const hi = xxhash3.hash(hash_seed_hi, bytes);
    return (@as(u128, hi) << 64) | @as(u128, lo);
}

// =============================================================================
// Value encoding
// =============================================================================

pub const EncodeError = error{ ValueType, OutOfMemory };

const sign_bit: u64 = 0x8000_0000_0000_0000;

fn encodeI64(out: *std.ArrayList(u8), gpa: Allocator, n: i64) !void {
    const u: u64 = @as(u64, @bitCast(n)) ^ sign_bit;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, u, .big);
    try out.appendSlice(gpa, &buf);
}

fn decodeI64(in: *const [8]u8) i64 {
    return @bitCast(std.mem.readInt(u64, in, .big) ^ sign_bit);
}

fn encodeF64(out: *std.ArrayList(u8), gpa: Allocator, d: f64) !void {
    const b: u64 = @bitCast(normalizeDouble(d));
    const u: u64 = if (b & sign_bit != 0) ~b else b ^ sign_bit;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, u, .big);
    try out.appendSlice(gpa, &buf);
}

fn decodeF64(in: *const [8]u8) f64 {
    const u = std.mem.readInt(u64, in, .big);
    const b: u64 = if (u & sign_bit != 0) u ^ sign_bit else ~u;
    return @bitCast(b);
}

/// Append `s` with `0x00 → 0x00 0xFF`, then the `0x00` terminator.
fn escapeInto(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) !void {
    try out.ensureUnusedCapacity(gpa, s.len + 1);
    for (s) |c| {
        try out.append(gpa, c);
        if (c == 0) try out.append(gpa, 0xFF);
    }
    try out.append(gpa, 0);
}

/// Escaped length of `s` including the terminator.
pub fn escapedLen(s: []const u8) usize {
    var n: usize = s.len + 1;
    for (s) |c| {
        if (c == 0) n += 1;
    }
    return n;
}

/// Unescape from `in` up to and including the terminator. Returns the
/// unescaped bytes (allocated in `gpa`) and the number of input bytes
/// consumed. Malformed input (no terminator, dangling escape) is
/// `error.Corrupted`.
fn unescapeFrom(gpa: Allocator, in: []const u8) !struct { bytes: []u8, consumed: usize } {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < in.len) {
        const c = in[i];
        if (c == 0) {
            if (i + 1 < in.len and in[i + 1] == 0xFF) {
                try out.append(gpa, 0);
                i += 2;
                continue;
            }
            return .{ .bytes = try out.toOwnedSlice(gpa), .consumed = i + 1 };
        }
        try out.append(gpa, c);
        i += 1;
    }
    return error.Corrupted;
}

/// Append the sortable encoding of `v` (tag byte included).
pub fn encodeVal(out: *std.ArrayList(u8), gpa: Allocator, v: Val) EncodeError!void {
    switch (v) {
        .boolean => |b| try out.append(gpa, @backingInt(if (b) Tag.bool_true else Tag.bool_false)),
        .long => |n| {
            try out.append(gpa, @backingInt(Tag.long));
            try encodeI64(out, gpa, n);
        },
        .double => |d| {
            if (std.math.isNan(d)) return error.ValueType;
            try out.append(gpa, @backingInt(Tag.double));
            try encodeF64(out, gpa, d);
        },
        .instant => |n| {
            try out.append(gpa, @backingInt(Tag.instant));
            try encodeI64(out, gpa, n);
        },
        .keyword => |id| {
            try out.append(gpa, @backingInt(Tag.keyword));
            try appendAttrKey(out, gpa, id);
        },
        .ref => |eid| {
            try out.append(gpa, @backingInt(Tag.ref));
            try appendEntity(out, gpa, eid);
        },
        .string => |s| try encodeBlob(out, gpa, s, .string),
        .uuid => |u| {
            try out.append(gpa, @backingInt(Tag.uuid));
            try out.appendSlice(gpa, &u);
        },
        .bytes => |b| try encodeBlob(out, gpa, b, .bytes),
    }
}

fn encodeBlob(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, tag: Tag) !void {
    try out.append(gpa, @backingInt(tag));
    if (s.len <= inline_max) {
        try escapeInto(out, gpa, s);
        return;
    }
    // The first `prefix_len` bytes, escaped, without a terminator of
    // their own; the 0x00 that follows separates prefix from hash and
    // the marker after it distinguishes the shape from an inline value
    // that happens to share the prefix.
    try out.ensureUnusedCapacity(gpa, 2 * prefix_len + 2 + hash_len);
    for (s[0..prefix_len]) |c| {
        try out.append(gpa, c);
        if (c == 0) try out.append(gpa, 0xFF);
    }
    try out.append(gpa, 0);
    try out.append(gpa, out_of_line_mark);
    var hbuf: [hash_len]u8 = undefined;
    std.mem.writeInt(u128, &hbuf, hash128(s), .big);
    try out.appendSlice(gpa, &hbuf);
}

/// The longest value encoding: an inline blob of `inline_max` bytes,
/// every one escaped, and its terminator.
pub const max_val_len = 1 + 2 * inline_max + 1;
/// The longest key: a history key carrying the longest value.
pub const max_key_len = entity_key_max + attr_key_max + max_val_len + top_len;

/// The owned-slice encoders build in stack scratch and copy out
/// exactly: nothing they produce exceeds `max_key_len`, and a list
/// growing to that length stays within the scratch.
const scratch_len = 1024;

comptime {
    std.debug.assert(1 + 2 * prefix_len + 2 + hash_len <= max_val_len);
    std.debug.assert(std.ArrayList(u8).growCapacity(max_key_len) + std.ArrayList(u8).growCapacity(0) <= scratch_len);
}

/// The sortable encoding of `v` as an owned slice.
pub fn valBytes(gpa: Allocator, v: Val) EncodeError![]u8 {
    var scratch: [scratch_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var out: std.ArrayList(u8) = .empty;
    try encodeVal(&out, fba.allocator(), v);
    return gpa.dupe(u8, out.items);
}

/// An out-of-line equality key: the escaped 64-byte prefix and the
/// 128-bit hash of the whole value.
pub const Digest = struct {
    prefix: []const u8,
    hash: u128,
};

/// A value decoded from an index key: exact for inline values, a digest
/// for out-of-line strings and byte arrays (the full value is the
/// payload of the fact's EAVT rows, NEXTOMIC.md §2.2).
pub const KeyVal = union(enum) {
    val: Val,
    string_long: Digest,
    bytes_long: Digest,

    pub fn valueType(self: KeyVal) ValueType {
        return switch (self) {
            .val => |v| v.valueType(),
            .string_long => .string,
            .bytes_long => .bytes,
        };
    }
};

pub const DecodeError = error{ Corrupted, OutOfMemory };

/// Decode one value encoding. `bytes` must hold exactly one encoding
/// (the caller slices `v` out of the key by the fixed suffix). Strings
/// and byte arrays are copied, unescaped, into `gpa`; digests borrow
/// their prefix from `bytes`.
pub fn decodeVal(gpa: Allocator, bytes: []const u8) DecodeError!KeyVal {
    if (bytes.len == 0) return error.Corrupted;
    const tag = tagFromByte(bytes[0]) orelse return error.Corrupted;
    const body = bytes[1..];
    switch (tag) {
        .bool_false => return if (body.len == 0) .{ .val = .{ .boolean = false } } else error.Corrupted,
        .bool_true => return if (body.len == 0) .{ .val = .{ .boolean = true } } else error.Corrupted,
        .long => {
            if (body.len != 8) return error.Corrupted;
            return .{ .val = .{ .long = decodeI64(body[0..8]) } };
        },
        .double => {
            if (body.len != 8) return error.Corrupted;
            return .{ .val = .{ .double = decodeF64(body[0..8]) } };
        },
        .instant => {
            if (body.len != 8) return error.Corrupted;
            return .{ .val = .{ .instant = decodeI64(body[0..8]) } };
        },
        .keyword => {
            const r = try readAttrKey(body);
            if (r.len != body.len) return error.Corrupted;
            return .{ .val = .{ .keyword = r.a } };
        },
        .ref => {
            const r = try readEntity(body);
            if (r.len != body.len) return error.Corrupted;
            return .{ .val = .{ .ref = r.e } };
        },
        .string, .bytes => {
            const r = try unescapeFrom(gpa, body);
            if (r.consumed == body.len) {
                return if (tag == .string) .{ .val = .{ .string = r.bytes } } else .{ .val = .{ .bytes = r.bytes } };
            }
            // Out of line: the bare 0x00 ends the escaped prefix, then the
            // marker and the hash fill the rest exactly.
            gpa.free(r.bytes);
            const sep = r.consumed - 1;
            if (body.len != sep + 2 + hash_len or body[sep + 1] != out_of_line_mark) return error.Corrupted;
            const d: Digest = .{
                .prefix = body[0..sep],
                .hash = std.mem.readInt(u128, body[sep + 2 ..][0..hash_len], .big),
            };
            return if (tag == .string) .{ .string_long = d } else .{ .bytes_long = d };
        },
        .uuid => {
            if (body.len != 16) return error.Corrupted;
            return .{ .val = .{ .uuid = body[0..16].* } };
        },
    }
}

/// The bytes the value encoding at the start of `in` takes: by its
/// tag for a fixed shape, by its terminator for a string or byte array
/// (an escaped NUL is `0x00 0xFF`, a bare `0x00` ends an inline value,
/// and `0x00 0x01` an out-of-line one's prefix before the hash). A key
/// parses its value this way where a field follows it.
pub fn valLen(in: []const u8) DecodeError!usize {
    if (in.len == 0) return error.Corrupted;
    const tag = tagFromByte(in[0]) orelse return error.Corrupted;
    const n: usize = switch (tag) {
        .bool_false, .bool_true => 1,
        .long, .double, .instant => 9,
        .uuid => 17,
        .keyword => if (in.len < 2) return error.Corrupted else 1 + orderedLen(in[1]),
        .ref => if (in.len < 2) return error.Corrupted else 1 + entityLen(in[1]),
        .string, .bytes => blk: {
            var i: usize = 1;
            while (i < in.len) : (i += 1) {
                if (in[i] != 0) continue;
                if (i + 1 < in.len and in[i + 1] == 0xFF) {
                    i += 1;
                    continue;
                }
                break :blk if (i + 1 < in.len and in[i + 1] == out_of_line_mark) i + 2 + hash_len else i + 1;
            }
            return error.Corrupted;
        },
    };
    return if (n > in.len) error.Corrupted else n;
}

fn tagFromByte(b: u8) ?Tag {
    inline for (@typeInfo(Tag).@"enum".field_values) |value| {
        if (value == b) return @fromBackingInt(@intCast(b));
    }
    return null;
}

// =============================================================================
// Index keys (§2)
// =============================================================================

pub const Index = enum(u8) {
    eavt,
    aevt,
    avet,
    vaet,

    /// A key component.
    pub const Component = enum { e, a, v };

    /// The order of the components in this index's keys.
    pub fn order(self: Index) [3]Component {
        return switch (self) {
            .eavt => .{ .e, .a, .v },
            .aevt => .{ .a, .e, .v },
            .avet => .{ .a, .v, .e },
            .vaet => .{ .v, .a, .e },
        };
    }

    pub fn name(self: Index) []const u8 {
        return switch (self) {
            .eavt => "eavt",
            .aevt => "aevt",
            .avet => "avet",
            .vaet => "vaet",
        };
    }
};

/// Components of a datom key, decoded. `v` is the raw value section:
/// a tagged encoding for EAVT/AEVT/AVET and a bare `E(v)` for VAET.
pub const Parts = struct {
    e: u64,
    a: u32,
    v: []const u8,
    /// Present in history keys only.
    top: ?Top,
};

/// The VAET value section is the referenced entity's `E` without a
/// tag; any other value encoding has no place in VAET.
fn vaetValue(vbytes: []const u8) error{ValueType}![]const u8 {
    if (vbytes.len < 2 or vbytes[0] != @backingInt(Tag.ref) or entityLen(vbytes[1]) != vbytes.len - 1) return error.ValueType;
    return vbytes[1..];
}

/// Append the key of datom `(e a v)` in `index`; a history key when
/// `top` is given. `vbytes` is the tagged value encoding.
pub fn packKey(out: *std.ArrayList(u8), gpa: Allocator, index: Index, e: u64, a: u32, vbytes: []const u8, top: ?Top) !void {
    var ebuf: [entity_key_max]u8 = undefined;
    var abuf: [ordered_max]u8 = undefined;
    const eb = writeEntity(&ebuf, e);
    const ab = writeOrdered(&abuf, a);
    switch (index) {
        .eavt => {
            try out.appendSlice(gpa, eb);
            try out.appendSlice(gpa, ab);
            try out.appendSlice(gpa, vbytes);
        },
        .aevt => {
            try out.appendSlice(gpa, ab);
            try out.appendSlice(gpa, eb);
            try out.appendSlice(gpa, vbytes);
        },
        .avet => {
            try out.appendSlice(gpa, ab);
            try out.appendSlice(gpa, vbytes);
            try out.appendSlice(gpa, eb);
        },
        .vaet => {
            try out.appendSlice(gpa, try vaetValue(vbytes));
            try out.appendSlice(gpa, ab);
            try out.appendSlice(gpa, eb);
        },
    }
    if (top) |tp| {
        var tbuf: [top_len]u8 = undefined;
        writeTop(&tbuf, tp.t, tp.added);
        try out.appendSlice(gpa, &tbuf);
    }
}

pub fn keyBytes(gpa: Allocator, index: Index, e: u64, a: u32, vbytes: []const u8, top: ?Top) ![]u8 {
    var scratch: [scratch_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var out: std.ArrayList(u8) = .empty;
    try packKey(&out, fba.allocator(), index, e, a, vbytes, top);
    return gpa.dupe(u8, out.items);
}

/// Decode a key of `index`. `history` selects the trailing `top`.
pub fn unpackKey(index: Index, history: bool, key: []const u8) DecodeError!Parts {
    const suffix_top: usize = if (history) top_len else 0;
    if (key.len < suffix_top) return error.Corrupted;
    const body = key[0 .. key.len - suffix_top];
    const top: ?Top = if (history) try readTop(key[key.len - top_len ..][0..top_len]) else null;
    var parts: Parts = .{ .e = 0, .a = 0, .v = &.{}, .top = top };
    switch (index) {
        .eavt, .aevt => {
            var at: usize = 0;
            if (index == .eavt) {
                parts.e = try idAt(body, &at);
                parts.a = try attrAt(body, &at);
            } else {
                parts.a = try attrAt(body, &at);
                parts.e = try idAt(body, &at);
            }
            parts.v = body[at..];
            if (parts.v.len == 0) return error.Corrupted;
        },
        .avet => {
            var at: usize = 0;
            parts.a = try attrAt(body, &at);
            const n = try valLen(body[at..]);
            parts.v = body[at..][0..n];
            at += n;
            parts.e = try idAt(body, &at);
            if (at != body.len) return error.Corrupted;
        },
        .vaet => {
            var at: usize = 0;
            _ = try idAt(body, &at);
            parts.v = body[0..at];
            parts.a = try attrAt(body, &at);
            parts.e = try idAt(body, &at);
            if (at != body.len) return error.Corrupted;
        },
    }
    return parts;
}

/// The `E(e)` at `at.*` in `body`, advancing past it.
fn idAt(body: []const u8, at: *usize) DecodeError!u64 {
    const r = try readEntity(body[at.*..]);
    at.* += r.len;
    return r.e;
}

/// The `A(a)` at `at.*` in `body`, advancing past it.
fn attrAt(body: []const u8, at: *usize) DecodeError!u32 {
    const r = try readAttrKey(body[at.*..]);
    at.* += r.len;
    return r.a;
}

/// The value of decoded key parts as a `KeyVal`.
pub fn partsVal(gpa: Allocator, index: Index, parts: Parts) DecodeError!KeyVal {
    if (index == .vaet) {
        const r = try readEntity(parts.v);
        if (r.len != parts.v.len) return error.Corrupted;
        return .{ .val = .{ .ref = r.e } };
    }
    return decodeVal(gpa, parts.v);
}

/// Leading components of a scan prefix. The packer appends them in
/// the index's order and stops at the first absent one; components
/// after a gap are the caller's filter, not part of the prefix.
pub const Components = struct {
    e: ?u64 = null,
    a: ?u32 = null,
    /// Tagged value encoding.
    v: ?[]const u8 = null,
};

/// Append the scan prefix for `comps` in `index`. Returns how many
/// components the prefix covers.
pub fn packPrefix(out: *std.ArrayList(u8), gpa: Allocator, index: Index, comps: Components) !u8 {
    var ebuf: [entity_key_max]u8 = undefined;
    var abuf: [ordered_max]u8 = undefined;
    const eb = if (comps.e) |e| writeEntity(&ebuf, e) else &.{};
    const ab = if (comps.a) |a| writeOrdered(&abuf, a) else &.{};
    var n: u8 = 0;
    for (index.order()) |c| {
        switch (c) {
            .e => {
                if (comps.e == null) break;
                try out.appendSlice(gpa, eb);
            },
            .a => {
                if (comps.a == null) break;
                try out.appendSlice(gpa, ab);
            },
            .v => {
                const v = comps.v orelse break;
                try out.appendSlice(gpa, if (index == .vaet) try vaetValue(v) else v);
            },
        }
        n += 1;
    }
    return n;
}

pub fn prefixBytes(gpa: Allocator, index: Index, comps: Components) ![]u8 {
    var scratch: [scratch_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var out: std.ArrayList(u8) = .empty;
    _ = try packPrefix(&out, fba.allocator(), index, comps);
    return gpa.dupe(u8, out.items);
}

/// The least key greater than every key that starts with `prefix`,
/// or null when no such key exists (the prefix is all `0xFF`). Owned
/// by `gpa`.
pub fn successor(gpa: Allocator, prefix: []const u8) !?[]u8 {
    var i = prefix.len;
    while (i > 0) : (i -= 1) {
        if (prefix[i - 1] != 0xFF) {
            const out = try gpa.dupe(u8, prefix[0..i]);
            out[i - 1] += 1;
            return out;
        }
    }
    return null;
}

/// Does `key` start with `prefix`?
pub inline fn hasPrefix(key: []const u8, prefix: []const u8) bool {
    return key.len >= prefix.len and std.mem.eql(u8, key[0..prefix.len], prefix);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn enc(v: Val) ![]u8 {
    return valBytes(testing.allocator, v);
}

test "hash128: stored digests keep their values" {
    // Long strings and fulltext rows carry these digests on disk
    // (NEXTOMIC.md §2.2), so a change to any of them is a format change.
    try testing.expectEqual(@as(u128, 0x602b0e2cd6662c8b2d06800538d394c2), hash128(""));
    try testing.expectEqual(@as(u128, 0xa4c931c08d47c66c21ac2147387893df), hash128("person/name"));
    try testing.expectEqual(@as(u128, 0x7cd1c442390e2ce274b315dfe47d3377), hash128("a string longer than sixteen bytes, for the mid path"));
    try testing.expectEqual(@as(u128, 0xd7aa4e081cbf1f58a5d1b4607dc83554), hash128(&@as([300]u8, @splat('x'))));
}

test "tags order types" {
    const a = try enc(.{ .boolean = true });
    defer testing.allocator.free(a);
    const b = try enc(.{ .long = -5 });
    defer testing.allocator.free(b);
    const c = try enc(.{ .string = "a" });
    defer testing.allocator.free(c);
    try testing.expect(std.mem.order(u8, a, b) == .lt);
    try testing.expect(std.mem.order(u8, b, c) == .lt);
}

test "long and double order" {
    const pairs = [_][2]i64{ .{ -1, 0 }, .{ std.math.minInt(i64), -1 }, .{ 0, 1 }, .{ 41, 42 }, .{ 42, std.math.maxInt(i64) } };
    for (pairs) |p| {
        const x = try enc(.{ .long = p[0] });
        defer testing.allocator.free(x);
        const y = try enc(.{ .long = p[1] });
        defer testing.allocator.free(y);
        try testing.expect(std.mem.order(u8, x, y) == .lt);
    }
    const dpairs = [_][2]f64{ .{ -1.5, -1.0 }, .{ -1.0, 0.0 }, .{ 0.0, 0.5 }, .{ 0.5, 1e300 }, .{ -std.math.inf(f64), -1e300 }, .{ 1e300, std.math.inf(f64) } };
    for (dpairs) |p| {
        const x = try enc(.{ .double = p[0] });
        defer testing.allocator.free(x);
        const y = try enc(.{ .double = p[1] });
        defer testing.allocator.free(y);
        try testing.expect(std.mem.order(u8, x, y) == .lt);
    }
}

test "negative zero normalizes and NaN is refused" {
    const x = try enc(.{ .double = -0.0 });
    defer testing.allocator.free(x);
    const y = try enc(.{ .double = 0.0 });
    defer testing.allocator.free(y);
    try testing.expectEqualSlices(u8, x, y);
    try testing.expectError(error.ValueType, enc(.{ .double = std.math.nan(f64) }));
}

test "string escape round trip with embedded NUL" {
    const s = "a\x00b\x00\xff";
    const x = try enc(.{ .string = s });
    defer testing.allocator.free(x);
    try testing.expectEqual(@as(usize, 1 + escapedLen(s)), x.len);
    const kv = try decodeVal(testing.allocator, x);
    defer testing.allocator.free(kv.val.string);
    try testing.expectEqualSlices(u8, s, kv.val.string);
}

test "string order with NUL against terminator" {
    const a = try enc(.{ .string = "a" });
    defer testing.allocator.free(a);
    const b = try enc(.{ .string = "a\x00" });
    defer testing.allocator.free(b);
    const c = try enc(.{ .string = "a\x01" });
    defer testing.allocator.free(c);
    try testing.expect(std.mem.order(u8, a, b) == .lt);
    try testing.expect(std.mem.order(u8, b, c) == .lt);
}

test "long string becomes a digest key" {
    const s = &@as([200]u8, @splat('x'));
    const x = try enc(.{ .string = s });
    defer testing.allocator.free(x);
    try testing.expectEqual(@as(usize, 1 + prefix_len + 2 + hash_len), x.len);
    try testing.expectEqual(@as(u8, @backingInt(Tag.string)), x[0]);
    const kv = try decodeVal(testing.allocator, x);
    try testing.expect(kv == .string_long);
    try testing.expectEqual(hash128(s), kv.string_long.hash);
    try testing.expectEqualSlices(u8, s[0..prefix_len], kv.string_long.prefix);
}

test "every fixed-width type round trips" {
    const vals = [_]Val{
        .{ .boolean = false }, .{ .boolean = true }, .{ .long = -7 },        .{ .double = 2.5 }, .{ .instant = 1_700_000_000_000 },
        .{ .keyword = 17 },    .{ .ref = 1 << 40 },  .{ .uuid = @splat(9) },
    };
    for (vals) |v| {
        const x = try enc(v);
        defer testing.allocator.free(x);
        const kv = try decodeVal(testing.allocator, x);
        try testing.expect(kv.val.eql(v));
    }
}

test "index keys pack and unpack in all four shapes" {
    const v = try enc(.{ .ref = 12345 });
    defer testing.allocator.free(v);
    inline for (.{ Index.eavt, Index.aevt, Index.avet, Index.vaet }) |ix| {
        const cur = try keyBytes(testing.allocator, ix, 1 << 33, 42, v, null);
        defer testing.allocator.free(cur);
        const p = try unpackKey(ix, false, cur);
        try testing.expectEqual(@as(u64, 1 << 33), p.e);
        try testing.expectEqual(@as(u32, 42), p.a);
        const kv = try partsVal(testing.allocator, ix, p);
        try testing.expectEqual(@as(u64, 12345), kv.val.ref);
        try testing.expect(p.top == null);

        const hist = try keyBytes(testing.allocator, ix, 1 << 33, 42, v, .{ .t = 9, .added = false });
        defer testing.allocator.free(hist);
        try testing.expectEqual(cur.len + top_len, hist.len);
        const hp = try unpackKey(ix, true, hist);
        try testing.expectEqual(@as(u64, 9), hp.top.?.t);
        try testing.expect(!hp.top.?.added);
        try testing.expectEqualSlices(u8, p.v, hp.v);
    }
}

test "prefix covers leading components only" {
    const v = try enc(.{ .long = 1 });
    defer testing.allocator.free(v);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(u8, 2), try packPrefix(&out, testing.allocator, .avet, .{ .a = 3, .v = v }));
    try testing.expectEqual(1 + v.len, out.items.len);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), try packPrefix(&out, testing.allocator, .eavt, .{ .e = 3, .v = v }));
    try testing.expectEqual(@as(usize, 2), out.items.len);
}

test "successor increments with carry" {
    const s = (try successor(testing.allocator, &.{ 1, 0xFF, 0xFF })).?;
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(u8, &.{2}, s);
    try testing.expect((try successor(testing.allocator, &.{ 0xFF, 0xFF })) == null);
}

test "a current value's t is a LEB128 in its shortest form, below the transaction partition" {
    var buf: [t_value_max]u8 = undefined;
    for ([_]u64{ 0, 1, 127, 128, 16383, 16384, tx_partition_bit - 1 }) |t| {
        const b = writeCurrentT(&buf, t);
        const v = try std.mem.concat(testing.allocator, u8, &.{ b, "payload" });
        defer testing.allocator.free(v);
        const cur = try readCurrent(v);
        try testing.expectEqual(t, cur.t);
        try testing.expectEqualStrings("payload", cur.rest);
    }
    try testing.expectEqual(@as(usize, 1), writeCurrentT(&buf, 127).len);
    try testing.expectEqual(@as(usize, 7), writeCurrentT(&buf, tx_partition_bit - 1).len);
    for ([_][]const u8{ &.{}, &.{0x80}, &.{ 0x81, 0x00 }, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40 }, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 } }) |bad| {
        try testing.expectError(error.Corrupted, readCurrent(bad));
    }
    var kb: [ordered_max]u8 = undefined;
    try testing.expectEqual(@as(u64, 300), try readTxlogKey(writeTxlogKey(&kb, 300)));
    try testing.expectError(error.Corrupted, readTxlogKey(writeOrdered(&kb, tx_partition_bit)));
}

test "top packs t and added" {
    var buf: [top_len]u8 = undefined;
    writeTop(&buf, 77, true);
    const tp = try readTop(&buf);
    try testing.expectEqual(@as(u64, 77), tp.t);
    try testing.expect(tp.added);
}

test "ids and tops read from bytes are range-checked" {
    const high: [id_len]u8 = @splat(0xFF);
    try testing.expectError(error.Corrupted, readId(&high));
    try testing.expectError(error.Corrupted, readTop(&high));
    var buf: [id_len]u8 = undefined;
    writeId(&buf, id_max);
    try testing.expectEqual(id_max, try readId(&buf));
    // An index key naming an id past the range is corrupt, not a crash.
    var k: [id_len + 2]u8 = undefined;
    @memcpy(k[0..id_len], &high);
    k[id_len] = 1;
    k[id_len + 1] = @backingInt(Tag.bool_true);
    try testing.expectError(error.Corrupted, unpackKey(.eavt, false, &k));
}
