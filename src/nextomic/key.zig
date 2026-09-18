//! key.zig — sortable value encodings and index key layout (NEXTOMIC.md §2).
//!
//! Every datom component becomes bytes whose unsigned lexicographic
//! order is the index order emdb sees. Invariants:
//!
//!   - One tag byte orders types; within a type, byte order equals
//!     value order (`test/prop/nextomic_key.zig` sweeps every type).
//!   - Ids are unsigned 48-bit big-endian in 6 bytes; attributes are
//!     unsigned 32-bit big-endian in 4 bytes; `top = (t << 1) | added`
//!     in 6 bytes.
//!   - A value encoding is always followed by fixed-width fields only,
//!     so `v` is `key[prefix .. len - suffix]` and carries no length.
//!   - Strings and byte arrays carry one tag each. Up to `inline_max`
//!     bytes they are stored inline; longer ones become an equality key
//!     (the escaped 64-byte prefix, then `0x00`, `out_of_line_mark` and
//!     the 128-bit hash) and the full payload lives in the EAVT value.
//!     The one tag keeps byte order equal to value order across the
//!     threshold whenever two values differ within their first 64 bytes.
//!   - `-0.0` is stored as `+0.0`; NaN is refused with `error.ValueType`.

const std = @import("std");

const Allocator = std.mem.Allocator;

// =============================================================================
// Widths and limits
// =============================================================================

/// Bytes of an entity or transaction id in a key.
pub const id_len = 6;
/// Bytes of an attribute id in a key.
pub const attr_len = 4;
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

pub fn readId(in: *const [id_len]u8) u64 {
    return std.mem.readInt(u48, in, .big);
}

pub fn writeAttr(out: *[attr_len]u8, a: u32) void {
    std.mem.writeInt(u32, out, a, .big);
}

pub fn readAttr(in: *const [attr_len]u8) u32 {
    return std.mem.readInt(u32, in, .big);
}

pub const Top = struct { t: u64, added: bool };

pub fn packTop(t: u64, added: bool) u64 {
    std.debug.assert(t < tx_partition_bit);
    return (t << 1) | @intFromBool(added);
}

pub fn writeTop(out: *[top_len]u8, t: u64, added: bool) void {
    std.mem.writeInt(u48, out, @intCast(packTop(t, added)), .big);
}

pub fn readTop(in: *const [top_len]u8) Top {
    const raw = std.mem.readInt(u48, in, .big);
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
    const lo = std.hash.XxHash3.hash(0, bytes);
    const hi = std.hash.XxHash3.hash(hash_seed_hi, bytes);
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
        .boolean => |b| try out.append(gpa, @intFromEnum(if (b) Tag.bool_true else Tag.bool_false)),
        .long => |n| {
            try out.append(gpa, @intFromEnum(Tag.long));
            try encodeI64(out, gpa, n);
        },
        .double => |d| {
            if (std.math.isNan(d)) return error.ValueType;
            try out.append(gpa, @intFromEnum(Tag.double));
            try encodeF64(out, gpa, d);
        },
        .instant => |n| {
            try out.append(gpa, @intFromEnum(Tag.instant));
            try encodeI64(out, gpa, n);
        },
        .keyword => |id| {
            try out.append(gpa, @intFromEnum(Tag.keyword));
            var buf: [attr_len]u8 = undefined;
            writeAttr(&buf, id);
            try out.appendSlice(gpa, &buf);
        },
        .ref => |eid| {
            try out.append(gpa, @intFromEnum(Tag.ref));
            var buf: [id_len]u8 = undefined;
            writeId(&buf, eid);
            try out.appendSlice(gpa, &buf);
        },
        .string => |s| try encodeBlob(out, gpa, s, .string),
        .uuid => |u| {
            try out.append(gpa, @intFromEnum(Tag.uuid));
            try out.appendSlice(gpa, &u);
        },
        .bytes => |b| try encodeBlob(out, gpa, b, .bytes),
    }
}

fn encodeBlob(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, tag: Tag) !void {
    try out.append(gpa, @intFromEnum(tag));
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

/// The sortable encoding of `v` as an owned slice.
pub fn valBytes(gpa: Allocator, v: Val) EncodeError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try encodeVal(&out, gpa, v);
    return out.toOwnedSlice(gpa);
}

/// An out-of-line equality key: the escaped 64-byte prefix and the
/// 128-bit hash of the whole value.
pub const Digest = struct {
    prefix: []const u8,
    hash: u128,
};

/// A value decoded from an index key: exact for inline values, a digest
/// for out-of-line strings and byte arrays (the full value is in the
/// EAVT payload).
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
            if (body.len != attr_len) return error.Corrupted;
            return .{ .val = .{ .keyword = readAttr(body[0..attr_len]) } };
        },
        .ref => {
            if (body.len != id_len) return error.Corrupted;
            return .{ .val = .{ .ref = readId(body[0..id_len]) } };
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

/// The type an encoded value carries, from its tag byte.
pub fn tagOf(vbytes: []const u8) DecodeError!Tag {
    if (vbytes.len == 0) return error.Corrupted;
    return tagFromByte(vbytes[0]) orelse error.Corrupted;
}

fn tagFromByte(b: u8) ?Tag {
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        if (f.value == b) return @enumFromInt(b);
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
/// a tagged encoding for EAVT/AEVT/AVET and a bare 6-byte entity id
/// for VAET.
pub const Parts = struct {
    e: u64,
    a: u32,
    v: []const u8,
    /// Present in history keys only.
    top: ?Top,
};

/// The VAET value section is the referenced entity id without a tag;
/// any other value encoding has no place in VAET.
fn vaetValue(vbytes: []const u8) error{ValueType}![]const u8 {
    if (vbytes.len != 1 + id_len or vbytes[0] != @intFromEnum(Tag.ref)) return error.ValueType;
    return vbytes[1..];
}

/// Append the key of datom `(e a v)` in `index`; a history key when
/// `top` is given. `vbytes` is the tagged value encoding.
pub fn packKey(out: *std.ArrayList(u8), gpa: Allocator, index: Index, e: u64, a: u32, vbytes: []const u8, top: ?Top) !void {
    var ebuf: [id_len]u8 = undefined;
    var abuf: [attr_len]u8 = undefined;
    writeId(&ebuf, e);
    writeAttr(&abuf, a);
    switch (index) {
        .eavt => {
            try out.appendSlice(gpa, &ebuf);
            try out.appendSlice(gpa, &abuf);
            try out.appendSlice(gpa, vbytes);
        },
        .aevt => {
            try out.appendSlice(gpa, &abuf);
            try out.appendSlice(gpa, &ebuf);
            try out.appendSlice(gpa, vbytes);
        },
        .avet => {
            try out.appendSlice(gpa, &abuf);
            try out.appendSlice(gpa, vbytes);
            try out.appendSlice(gpa, &ebuf);
        },
        .vaet => {
            try out.appendSlice(gpa, try vaetValue(vbytes));
            try out.appendSlice(gpa, &abuf);
            try out.appendSlice(gpa, &ebuf);
        },
    }
    if (top) |tp| {
        var tbuf: [top_len]u8 = undefined;
        writeTop(&tbuf, tp.t, tp.added);
        try out.appendSlice(gpa, &tbuf);
    }
}

pub fn keyBytes(gpa: Allocator, index: Index, e: u64, a: u32, vbytes: []const u8, top: ?Top) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try packKey(&out, gpa, index, e, a, vbytes, top);
    return out.toOwnedSlice(gpa);
}

/// Decode a key of `index`. `history` selects the trailing `top`.
pub fn unpackKey(index: Index, history: bool, key: []const u8) DecodeError!Parts {
    const suffix_top: usize = if (history) top_len else 0;
    const v_min: usize = if (index == .vaet) id_len else 1;
    const fixed: usize = id_len + attr_len + suffix_top;
    if (key.len < fixed + v_min) return error.Corrupted;
    const body = key[0 .. key.len - suffix_top];
    const top: ?Top = if (history) readTop(key[key.len - top_len ..][0..top_len]) else null;
    return switch (index) {
        .eavt => .{
            .e = readId(body[0..id_len]),
            .a = readAttr(body[id_len..][0..attr_len]),
            .v = body[id_len + attr_len ..],
            .top = top,
        },
        .aevt => .{
            .a = readAttr(body[0..attr_len]),
            .e = readId(body[attr_len..][0..id_len]),
            .v = body[attr_len + id_len ..],
            .top = top,
        },
        .avet => .{
            .a = readAttr(body[0..attr_len]),
            .v = body[attr_len .. body.len - id_len],
            .e = readId(body[body.len - id_len ..][0..id_len]),
            .top = top,
        },
        .vaet => .{
            .v = body[0..id_len],
            .a = readAttr(body[id_len..][0..attr_len]),
            .e = readId(body[id_len + attr_len ..][0..id_len]),
            .top = top,
        },
    };
}

/// The value of decoded key parts as a `KeyVal`.
pub fn partsVal(gpa: Allocator, index: Index, parts: Parts) DecodeError!KeyVal {
    if (index == .vaet) {
        if (parts.v.len != id_len) return error.Corrupted;
        return .{ .val = .{ .ref = readId(parts.v[0..id_len]) } };
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
    var ebuf: [id_len]u8 = undefined;
    var abuf: [attr_len]u8 = undefined;
    if (comps.e) |e| writeId(&ebuf, e);
    if (comps.a) |a| writeAttr(&abuf, a);
    const order: [3]u8 = switch (index) {
        .eavt => .{ 'e', 'a', 'v' },
        .aevt => .{ 'a', 'e', 'v' },
        .avet => .{ 'a', 'v', 'e' },
        .vaet => .{ 'v', 'a', 'e' },
    };
    var n: u8 = 0;
    for (order) |c| {
        switch (c) {
            'e' => {
                const e = comps.e orelse break;
                _ = e;
                try out.appendSlice(gpa, &ebuf);
            },
            'a' => {
                const a = comps.a orelse break;
                _ = a;
                try out.appendSlice(gpa, &abuf);
            },
            'v' => {
                const v = comps.v orelse break;
                try out.appendSlice(gpa, if (index == .vaet) try vaetValue(v) else v);
            },
            else => unreachable,
        }
        n += 1;
    }
    return n;
}

pub fn prefixBytes(gpa: Allocator, index: Index, comps: Components) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    _ = try packPrefix(&out, gpa, index, comps);
    return out.toOwnedSlice(gpa);
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
    const s = "x" ** 200;
    const x = try enc(.{ .string = s });
    defer testing.allocator.free(x);
    try testing.expectEqual(@as(usize, 1 + prefix_len + 2 + hash_len), x.len);
    try testing.expectEqual(@as(u8, @intFromEnum(Tag.string)), x[0]);
    const kv = try decodeVal(testing.allocator, x);
    try testing.expect(kv == .string_long);
    try testing.expectEqual(hash128(s), kv.string_long.hash);
    try testing.expectEqualSlices(u8, s[0..prefix_len], kv.string_long.prefix);
}

test "every fixed-width type round trips" {
    const vals = [_]Val{
        .{ .boolean = false }, .{ .boolean = true }, .{ .long = -7 }, .{ .double = 2.5 }, .{ .instant = 1_700_000_000_000 },
        .{ .keyword = 17 },    .{ .ref = 1 << 40 },   .{ .uuid = [_]u8{9} ** 16 },
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
    try testing.expectEqual(attr_len + v.len, out.items.len);
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 1), try packPrefix(&out, testing.allocator, .eavt, .{ .e = 3, .v = v }));
    try testing.expectEqual(@as(usize, id_len), out.items.len);
}

test "successor increments with carry" {
    const s = (try successor(testing.allocator, &.{ 1, 0xFF, 0xFF })).?;
    defer testing.allocator.free(s);
    try testing.expectEqualSlices(u8, &.{2}, s);
    try testing.expect((try successor(testing.allocator, &.{ 0xFF, 0xFF })) == null);
}

test "top packs t and added" {
    var buf: [top_len]u8 = undefined;
    writeTop(&buf, 77, true);
    const tp = readTop(&buf);
    try testing.expectEqual(@as(u64, 77), tp.t);
    try testing.expect(tp.added);
}
