//! codec.zig — serialize / deserialize Value ↔ bytes.
//!
//! Authoritative spec: `docs/CODEC.md`. Derivative from PLAN
//! §23 #25 (serialization scope frozen),
//! `docs/SEMANTICS.md` §2.2 / §3.2 (numeric canonical form +
//! hash invariants), and `docs/VALUE.md` §2 (Kind numbering).
//!
//! Implements the wire format pinned in CODEC.md §2:
//!
//!   [major: u8 = 1] [minor: u8 = 0] [ValueEncoding]
//!
//! where ValueEncoding is a kind-tagged payload. All integers are
//! little-endian; all lengths / counts are unsigned LEB128;
//! fixnums are signed ZigZag LEB128; floats and chars are fixed-
//! width LE. See CODEC.md §2 for the per-kind table.
//!
//! Scope (CODEC.md §1): the data kinds (nil, bool, char, fixnum,
//! float, keyword, symbol, string, bignum, list, vector, map, set,
//! typed vector, and the sorted map and set in the natural order)
//! nested to any depth. Every other kind is
//! `error.UnserializableKind`.
//!
//! Both directions walk containers with an explicit stack, so data
//! nesting never becomes native recursion (CODEC.md §2.7).
//!
//! Decode reads bytes from store files, so every length and count in
//! them is hostile until bounded (CODEC.md §2.1, §2.7): nothing is
//! allocated or sliced before the input is known to hold it.

const std = @import("std");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const intern_mod = @import("intern.zig");
const hash_mod = @import("hash.zig");
const string = @import("string.zig");
const bignum = @import("bignum.zig");
const list_mod = @import("coll/list.zig");
const vector_mod = @import("coll/vector.zig");
const champ = @import("coll/champ.zig");
const sorted = @import("coll/sorted.zig");
const typed_vector = @import("coll/typed_vector.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;

const testing = std.testing;

// =============================================================================
// Version envelope (CODEC.md §2)
// =============================================================================

pub const version_major: u8 = 1;
pub const version_minor: u8 = 0;

// =============================================================================
// Error set (CODEC.md §5)
// =============================================================================

pub const CodecError = error{
    /// A kind outside the serializable set (CODEC.md §3), on encode
    /// or as a decoded kind byte.
    UnserializableKind,

    /// The input ends mid-value, or a length or count asks for more
    /// than the input holds.
    TruncatedInput,

    /// Decode consumed a valid value but input has extra bytes.
    /// Exactly one envelope + body expected per decode call.
    TrailingBytes,

    /// Envelope version bytes don't match a version this build
    /// understands. Only `[1, 0]` is accepted.
    InvalidVersion,

    /// A kind byte that names no kind. Distinct from
    /// UnserializableKind, which names a kind outside the set.
    InvalidKindByte,

    /// An unsigned LEB128 whose value exceeds u64.
    InvalidLeb128,

    /// Char encoding decoded to a surrogate (D800..DFFF) or value
    /// > 0x10FFFF. Matches `value.fromChar` rejection.
    InvalidCharScalar,

    /// Input no encoder writes: a bignum sign byte not in {0, 1}, a
    /// typed-vector element tag that names no element type, a fixnum
    /// outside i48, a map or set count that disagrees with its
    /// distinct entries, sorted keys out of their natural order.
    MalformedPayload,
};

// =============================================================================
// Varint primitives (unsigned LEB128 + signed ZigZag LEB128)
// =============================================================================

fn writeUleb128(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u64) !void {
    var x = v;
    while (true) {
        const byte: u8 = @intCast(x & 0x7F);
        x >>= 7;
        if (x == 0) {
            try buf.append(allocator, byte);
            return;
        }
        try buf.append(allocator, byte | 0x80);
    }
}

/// Decode unsigned LEB128 starting at `cursor.*`, advancing the
/// cursor past it. The tenth byte may carry only bit 63; anything
/// more overflows u64 and is `InvalidLeb128`. Overlong encodings
/// (`80 00`) are accepted: encode never writes them, and they name
/// the same number.
fn readUleb128(bytes: []const u8, cursor: *usize) CodecError!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) : (shift += 7) {
        const byte = try readByte(bytes, cursor);
        if (shift == 63 and byte > 1) return CodecError.InvalidLeb128;
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
    }
}

/// ZigZag: signed i64 → u64 for compact LEB128 encoding of small
/// signed values. Both encode and decode operate entirely in u64
/// space — no signed left shift (defensive against `i64.min` /
/// `i64.max` edge cases even though fixnum range is i48 and can't
/// reach them).
inline fn zigzagEncode(v: i64) u64 {
    const uv: u64 = @bitCast(v);
    // Top bit of v → 0 (non-negative) or 1 (negative). Negating
    // in u64 space (via two's-complement wraparound) gives either
    // 0 or `all-ones`, which is the mask we XOR into `uv << 1`.
    const sign_bit = uv >> 63;
    const sign_mask: u64 = @as(u64, 0) -% sign_bit;
    return (uv << 1) ^ sign_mask;
}

inline fn zigzagDecode(v: u64) i64 {
    // Inverse: (v >>> 1) ^ -(v & 1). Again, all in u64 space.
    const low_bit = v & 1;
    const sign_mask: u64 = @as(u64, 0) -% low_bit;
    const decoded_u: u64 = (v >> 1) ^ sign_mask;
    return @bitCast(decoded_u);
}

fn writeIleb128Zigzag(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: i64) !void {
    try writeUleb128(buf, allocator, zigzagEncode(v));
}

fn readIleb128Zigzag(bytes: []const u8, cursor: *usize) CodecError!i64 {
    const u = try readUleb128(bytes, cursor);
    return zigzagDecode(u);
}

// =============================================================================
// Fixed-width primitives
// =============================================================================

fn writeU32Le(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn readU32Le(bytes: []const u8, cursor: *usize) CodecError!u32 {
    return std.mem.readInt(u32, (try readBytes(bytes, cursor, 4))[0..4], .little);
}

fn writeU64Le(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn readU64Le(bytes: []const u8, cursor: *usize) CodecError!u64 {
    return std.mem.readInt(u64, (try readBytes(bytes, cursor, 8))[0..8], .little);
}

fn writeByte(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, b: u8) !void {
    try buf.append(allocator, b);
}

fn readByte(bytes: []const u8, cursor: *usize) CodecError!u8 {
    if (cursor.* >= bytes.len) return CodecError.TruncatedInput;
    const b = bytes[cursor.*];
    cursor.* += 1;
    return b;
}

fn writeBytes(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, src: []const u8) !void {
    try buf.appendSlice(allocator, src);
}

/// `len` comes from the input and may be anything up to 2^64-1, so
/// the bound is written as a subtraction: `cursor.* <= bytes.len`
/// always holds, and `cursor.* + len` could wrap.
fn readBytes(bytes: []const u8, cursor: *usize, len: usize) CodecError![]const u8 {
    if (len > bytes.len - cursor.*) return CodecError.TruncatedInput;
    const slice = bytes[cursor.*..][0..len];
    cursor.* += len;
    return slice;
}

// =============================================================================
// Public API
// =============================================================================

/// Encode `v` to a freshly-allocated byte slice. Caller frees.
/// Returns `UnserializableKind` if `v` is not in the
/// serializable set (CODEC.md §1).
pub fn encode(
    allocator: std.mem.Allocator,
    interner: *const Interner,
    v: Value,
) (CodecError || std.mem.Allocator.Error)![]u8 {
    var e: Encoder = .{ .allocator = allocator, .interner = interner };
    defer e.stack.deinit(allocator);
    errdefer e.buf.deinit(allocator);
    try e.byte(version_major);
    try e.byte(version_minor);
    try e.run(v);
    return e.buf.toOwnedSlice(allocator);
}

/// Decode a byte slice to a Value. Consumes `bytes` completely;
/// trailing bytes trigger `TrailingBytes`. `heap` owns the new
/// Value's backing allocations; `interner` provides the id space
/// for keyword / symbol names.
pub fn decode(
    heap: *Heap,
    interner: *Interner,
    bytes: []const u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) DecodeError!Value {
    if (bytes.len < 2) return CodecError.TruncatedInput;
    if (bytes[0] != version_major or bytes[1] != version_minor) return CodecError.InvalidVersion;
    var d: Decoder = .{
        .heap = heap,
        .interner = interner,
        .bytes = bytes,
        .cursor = 2,
        .elementHash = elementHash,
        .elementEq = elementEq,
    };
    defer d.scratch.deinit(heap.backing);
    defer d.frames.deinit(heap.backing);
    const v = try d.run();
    if (d.cursor != bytes.len) return CodecError.TrailingBytes;
    return v;
}

pub const DecodeError = CodecError || std.mem.Allocator.Error || intern_mod.InternError || error{ Overflow, InvalidListTail };

// =============================================================================
// Encoder — a loop over an explicit stack of open containers
// =============================================================================

const Encoder = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,
    interner: *const Interner,
    /// The containers whose elements are still being written,
    /// innermost last.
    stack: std.ArrayList(Open) = .empty,

    const Error = CodecError || std.mem.Allocator.Error;

    /// A container being written and where its walk stands. A map
    /// yields each entry's key, then holds its value for the next
    /// step.
    const Open = union(enum) {
        list: list_mod.Cursor,
        vector: vector_mod.Cursor,
        map: struct { iter: champ.MapIter, value: ?Value = null },
        set: champ.SetIter,
        sorted_map: struct { cursor: sorted.Cursor, value: ?Value = null },
        sorted_set: sorted.Cursor,

        fn next(o: *Open) ?Value {
            return switch (o.*) {
                .list => |*c| c.next(),
                .vector => |*c| c.next(),
                .set => |*it| it.next(),
                .sorted_set => |*c| if (c.next()) |e| e.key else null,
                .map => |*m| if (m.value) |v| blk: {
                    m.value = null;
                    break :blk v;
                } else if (m.iter.next()) |entry| blk: {
                    m.value = entry.value;
                    break :blk entry.key;
                } else null,
                .sorted_map => |*m| if (m.value) |v| blk: {
                    m.value = null;
                    break :blk v;
                } else if (m.cursor.next()) |entry| blk: {
                    m.value = entry.value;
                    break :blk entry.key;
                } else null,
            };
        }
    };

    /// Write `root`: a container's header opens it on the stack, and
    /// every step writes the next element of the innermost open one.
    fn run(e: *Encoder, root: Value) Error!void {
        var v = root;
        while (true) {
            switch (v.kind()) {
                .list => {
                    try e.header(.list, list_mod.count(v));
                    try e.stack.append(e.allocator, .{ .list = list_mod.Cursor.init(v) });
                },
                .persistent_vector => {
                    try e.header(.persistent_vector, vector_mod.count(v));
                    try e.stack.append(e.allocator, .{ .vector = vector_mod.Cursor.init(v) });
                },
                .persistent_map => {
                    try e.header(.persistent_map, champ.mapCount(v));
                    try e.stack.append(e.allocator, .{ .map = .{ .iter = champ.mapIter(v) } });
                },
                .persistent_set => {
                    try e.header(.persistent_set, champ.setCount(v));
                    try e.stack.append(e.allocator, .{ .set = champ.setIter(v) });
                },
                // Only the natural order can be named in bytes; a
                // comparator is code (CODEC.md §2.8).
                .sorted_map, .sorted_set => {
                    if (!sorted.comparatorOf(v).isNil()) return CodecError.UnserializableKind;
                    try e.header(v.kind(), sorted.count(v));
                    try e.stack.append(e.allocator, if (v.kind() == .sorted_map)
                        .{ .sorted_map = .{ .cursor = sorted.Cursor.init(v) } }
                    else
                        .{ .sorted_set = sorted.Cursor.init(v) });
                },
                else => try e.leaf(v),
            }
            v = while (e.stack.items.len > 0) {
                if (e.stack.items[e.stack.items.len - 1].next()) |x| break x;
                _ = e.stack.pop();
            } else return;
        }
    }

    fn header(e: *Encoder, k: Kind, n: usize) Error!void {
        try e.byte(@intFromEnum(k));
        try e.uleb(n);
    }

    fn leaf(e: *Encoder, v: Value) Error!void {
        const k = v.kind();
        switch (k) {
            .nil, .false_, .true_ => try e.byte(@intFromEnum(k)),
            .char => {
                try e.byte(@intFromEnum(k));
                try writeU32Le(&e.buf, e.allocator, @as(u32, v.asChar()));
            },
            .fixnum => {
                try e.byte(@intFromEnum(k));
                try writeIleb128Zigzag(&e.buf, e.allocator, v.asFixnum());
            },
            .float => {
                try e.byte(@intFromEnum(k));
                try writeU64Le(&e.buf, e.allocator, @bitCast(hash_mod.canonicalizeFloat(v.asFloat())));
            },
            .keyword => try e.named(k, e.interner.keywordName(v.asKeywordId())),
            .symbol => try e.named(k, e.interner.symbolName(v.asSymbolId())),
            .string => try e.named(k, string.asBytes(v)),
            .bignum => {
                try e.byte(@intFromEnum(k));
                try e.byte(@intFromBool(bignum.isNegative(v)));
                const limbs = bignum.limbs(v);
                try e.uleb(limbs.len);
                for (limbs) |limb| try writeU64Le(&e.buf, e.allocator, limb);
            },
            // `[23] [elem tag] [count] [u64 LE × count]`: i64 as two's
            // complement bits, f64 as canonical IEEE bits (CODEC.md §2).
            .typed_vector => {
                try e.byte(@intFromEnum(k));
                const elem = typed_vector.elemType(v);
                try e.byte(@intFromEnum(elem));
                try e.uleb(typed_vector.count(v));
                switch (elem) {
                    .i64 => for (typed_vector.i64Elems(v)) |x| try writeU64Le(&e.buf, e.allocator, @bitCast(x)),
                    .f64 => for (typed_vector.f64Elems(v)) |x| try writeU64Le(&e.buf, e.allocator, @bitCast(hash_mod.canonicalizeFloat(x))),
                }
            },
            // Every other kind is outside the serializable set
            // (CODEC.md §3): identity-valued, mutable or process-local.
            else => return CodecError.UnserializableKind,
        }
    }

    fn byte(e: *Encoder, b: u8) Error!void {
        try e.buf.append(e.allocator, b);
    }

    fn uleb(e: *Encoder, n: usize) Error!void {
        try writeUleb128(&e.buf, e.allocator, n);
    }

    fn named(e: *Encoder, k: Kind, bytes: []const u8) Error!void {
        try e.byte(@intFromEnum(k));
        try e.uleb(bytes.len);
        try e.buf.appendSlice(e.allocator, bytes);
    }
};

// =============================================================================
// Decoder — a loop over an explicit stack of open containers
// =============================================================================

const Decoder = struct {
    heap: *Heap,
    interner: *Interner,
    bytes: []const u8,
    cursor: usize,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
    /// The elements decoded so far of every open container, innermost
    /// last. It grows one element per element decoded, so a count
    /// that claims more than the input holds costs nothing until the
    /// input runs out (CODEC.md §2.7).
    scratch: std.ArrayList(Value) = .empty,
    /// The open containers, innermost last. Each took at least two
    /// bytes of input, so the stack is bounded by the input's size.
    frames: std.ArrayList(Frame) = .empty,

    /// A container whose elements are being read: its kind byte, how
    /// many elements (a map's keys and values both count) are still to
    /// come, and where its elements start in `scratch`.
    const Frame = struct { tag: u8, remaining: usize, start: usize };

    fn run(d: *Decoder) DecodeError!Value {
        while (true) {
            const tag = try readByte(d.bytes, &d.cursor);
            var v = switch (tag) {
                @intFromEnum(Kind.list), @intFromEnum(Kind.persistent_vector), @intFromEnum(Kind.persistent_set), @intFromEnum(Kind.sorted_set) => try d.open(tag, try d.count(1)),
                @intFromEnum(Kind.persistent_map), @intFromEnum(Kind.sorted_map) => try d.open(tag, 2 * try d.count(2)),
                else => try d.leaf(tag),
            } orelse continue;
            // Hand `v` to the innermost open container, closing every
            // one it completes.
            while (d.frames.items.len > 0) {
                const top = &d.frames.items[d.frames.items.len - 1];
                try d.scratch.append(d.heap.backing, v);
                top.remaining -= 1;
                if (top.remaining > 0) break;
                const f = d.frames.pop().?;
                v = try d.close(f.tag, f.start);
            } else return v;
        }
    }

    /// Open a container of `n` elements; an empty one is complete at
    /// once and returned.
    fn open(d: *Decoder, tag: u8, n: usize) DecodeError!?Value {
        const start = d.scratch.items.len;
        if (n == 0) return try d.close(tag, start);
        try d.frames.append(d.heap.backing, .{ .tag = tag, .remaining = n, .start = start });
        return null;
    }

    /// Build the container whose elements are `scratch[start..]` and
    /// drop them from `scratch`. Encode never writes a duplicate key
    /// or element, so a map or set with fewer distinct entries than
    /// elements read is corrupt input (CODEC.md §2.6).
    fn close(d: *Decoder, tag: u8, start: usize) DecodeError!Value {
        defer d.scratch.shrinkRetainingCapacity(start);
        const elems = d.scratch.items[start..];
        switch (tag) {
            @intFromEnum(Kind.list) => return list_mod.fromSlice(d.heap, elems),
            @intFromEnum(Kind.persistent_vector) => return vector_mod.fromSlice(d.heap, elems),
            @intFromEnum(Kind.sorted_map), @intFromEnum(Kind.sorted_set) => return d.sortedFrom(@enumFromInt(tag), elems),
            @intFromEnum(Kind.persistent_map) => {
                var m = try champ.mapEmpty(d.heap);
                var i: usize = 0;
                while (i < elems.len) : (i += 2) m = try champ.mapAssoc(d.heap, m, elems[i], elems[i + 1], d.elementHash, d.elementEq);
                if (champ.mapCount(m) != elems.len / 2) return CodecError.MalformedPayload;
                return m;
            },
            else => {
                var s = try champ.setEmpty(d.heap);
                for (elems) |x| s = try champ.setConj(d.heap, s, x, d.elementHash, d.elementEq);
                if (champ.setCount(s) != elems.len) return CodecError.MalformedPayload;
                return s;
            },
        }
    }

    /// A sorted collection in the natural order from its elements,
    /// which encode wrote in ascending order: each key must order
    /// strictly after the one before it, or the input is corrupt.
    fn sortedFrom(d: *Decoder, kind: Kind, elems: []const Value) DecodeError!Value {
        const is_map = kind == .sorted_map;
        const entries = try d.heap.backing.alloc(sorted.Entry, if (is_map) elems.len / 2 else elems.len);
        defer d.heap.backing.free(entries);
        for (entries, 0..) |*e, i| e.* = if (is_map)
            .{ .key = elems[2 * i], .value = elems[2 * i + 1] }
        else
            .{ .key = elems[i], .value = value.nilValue() };
        const order = sorted.Natural{ .interner = d.interner };
        if (entries.len > 1) for (entries[0 .. entries.len - 1], entries[1..]) |a, b| {
            const o = order.order(a.key, b.key) catch return CodecError.MalformedPayload;
            if (o != .lt) return CodecError.MalformedPayload;
        };
        return sorted.fromSortedEntries(d.heap, kind, value.nilValue(), entries);
    }

    fn leaf(d: *Decoder, tag: u8) DecodeError!Value {
        const bytes = d.bytes;
        const cursor = &d.cursor;
        return switch (tag) {
            @intFromEnum(Kind.nil) => value.nilValue(),
            @intFromEnum(Kind.false_) => value.fromBool(false),
            @intFromEnum(Kind.true_) => value.fromBool(true),
            @intFromEnum(Kind.char) => value.fromChar(std.math.cast(u21, try readU32Le(bytes, cursor)) orelse
                return CodecError.InvalidCharScalar) orelse CodecError.InvalidCharScalar,
            // A fixnum kind byte over a number outside i48 is malformed
            // rather than promoted: the kind byte is authoritative.
            @intFromEnum(Kind.fixnum) => value.fromFixnum(try readIleb128Zigzag(bytes, cursor)) orelse CodecError.MalformedPayload,
            @intFromEnum(Kind.float) => value.fromFloat(@bitCast(try readU64Le(bytes, cursor))),
            @intFromEnum(Kind.keyword) => d.interner.internKeywordValue(try readBytes(bytes, cursor, try d.count(1))),
            @intFromEnum(Kind.symbol) => d.interner.internSymbolValue(try readBytes(bytes, cursor, try d.count(1))),
            @intFromEnum(Kind.string) => string.fromBytes(d.heap, try readBytes(bytes, cursor, try d.count(1))),
            @intFromEnum(Kind.bignum) => blk: {
                const sign = try readByte(bytes, cursor);
                if (sign > 1) return CodecError.MalformedPayload;
                const limbs = try d.heap.backing.alloc(u64, try d.count(8));
                defer d.heap.backing.free(limbs);
                for (limbs) |*slot| slot.* = try readU64Le(bytes, cursor);
                // `fromLimbs` canonicalizes (CODEC.md §2.6).
                break :blk bignum.fromLimbs(d.heap, sign == 1, limbs);
            },
            @intFromEnum(Kind.typed_vector) => blk: {
                const elem = typed_vector.ElemType.fromTag(try readByte(bytes, cursor)) orelse return CodecError.MalformedPayload;
                const n = try d.count(8);
                const raw = try readBytes(bytes, cursor, n * 8);
                switch (elem) {
                    .i64 => {
                        const elems = try d.heap.backing.alloc(i64, n);
                        defer d.heap.backing.free(elems);
                        for (elems, 0..) |*slot, i| slot.* = @bitCast(std.mem.readInt(u64, raw[i * 8 ..][0..8], .little));
                        break :blk typed_vector.fromI64Slice(d.heap, elems);
                    },
                    .f64 => {
                        const elems = try d.heap.backing.alloc(f64, n);
                        defer d.heap.backing.free(elems);
                        for (elems, 0..) |*slot, i| slot.* = @bitCast(std.mem.readInt(u64, raw[i * 8 ..][0..8], .little));
                        break :blk typed_vector.fromF64Slice(d.heap, elems);
                    },
                }
            },
            // Every other kind that exists is outside the serializable
            // set (CODEC.md §3); a byte that names no heap kind (the
            // reserved immediates 8..15, reserved heap bytes, the
            // runtime-private sentinels 64..) is not a kind at all.
            else => if (isHeapKindByte(tag)) CodecError.UnserializableKind else CodecError.InvalidKindByte,
        };
    }

    /// A length or count read from the input. Each unit it counts
    /// takes at least `min_bytes` bytes of what remains, so a count
    /// past that is `TruncatedInput` here, before anything is
    /// allocated for it.
    fn count(d: *Decoder, min_bytes: usize) CodecError!usize {
        const n = try readUleb128(d.bytes, &d.cursor);
        if (n > (d.bytes.len - d.cursor) / min_bytes) return CodecError.TruncatedInput;
        return @intCast(n);
    }
};

/// Does `b` name a heap kind? The serializable ones are matched by
/// the decoder's own arms before this is asked.
fn isHeapKindByte(b: u8) bool {
    if (!Kind.isHeap(@enumFromInt(b))) return false;
    inline for (std.meta.fields(Kind)) |f| {
        if (f.value == b) return true;
    }
    return false;
}

// =============================================================================
// Inline tests
// =============================================================================

// ---- Synthetic callbacks ----

fn synthHash(x: Value) u64 {
    return x.hashImmediate();
}

fn synthEq(a: Value, b: Value) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    if (a.kind() != b.kind()) return false;
    return switch (a.kind()) {
        .nil, .false_, .true_ => true,
        .fixnum => a.asFixnum() == b.asFixnum(),
        .keyword => a.asKeywordId() == b.asKeywordId(),
        .symbol => a.asSymbolId() == b.asSymbolId(),
        .char => a.asChar() == b.asChar(),
        .float => a.asFloat() == b.asFloat() or (std.math.isNan(a.asFloat()) and std.math.isNan(b.asFloat())),
        else => false,
    };
}

// ---- Test helper ----

const TestCtx = struct {
    heap: Heap,
    interner: Interner,

    fn init() TestCtx {
        return .{
            .heap = Heap.init(testing.allocator),
            .interner = Interner.init(testing.allocator),
        };
    }

    fn deinit(self: *TestCtx) void {
        self.heap.deinit();
        self.interner.deinit();
    }

    fn roundtrip(self: *TestCtx, v: Value) !Value {
        const bytes = try encode(testing.allocator, &self.interner, v);
        defer testing.allocator.free(bytes);
        return try decode(&self.heap, &self.interner, bytes, &synthHash, &synthEq);
    }
};

// ---- Varint tests ----

test "LEB128 unsigned: roundtrip of 0, 127, 128, 16383, 16384, u64.max" {
    const cases = [_]u64{ 0, 1, 127, 128, 255, 16383, 16384, std.math.maxInt(u32), std.math.maxInt(u64) };
    for (cases) |v| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try writeUleb128(&buf, testing.allocator, v);
        var cursor: usize = 0;
        const got = try readUleb128(buf.items, &cursor);
        try testing.expectEqual(v, got);
        try testing.expectEqual(buf.items.len, cursor);
    }
}

test "LEB128 signed (ZigZag): roundtrip of fixnum range" {
    const cases = [_]i64{ 0, 1, -1, 42, -42, 127, -128, value.fixnum_max, value.fixnum_min };
    for (cases) |v| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try writeIleb128Zigzag(&buf, testing.allocator, v);
        var cursor: usize = 0;
        const got = try readIleb128Zigzag(buf.items, &cursor);
        try testing.expectEqual(v, got);
    }
}

test "LEB128 unsigned: truncated input errors" {
    const bytes = [_]u8{0x80}; // continuation set but no next byte
    var cursor: usize = 0;
    try testing.expectError(CodecError.TruncatedInput, readUleb128(&bytes, &cursor));
}

test "LEB128 unsigned: overlong input errors" {
    // 11+ bytes all with continuation = overflow.
    var bytes: [11]u8 = undefined;
    @memset(&bytes, 0x80);
    bytes[10] = 0x00;
    var cursor: usize = 0;
    try testing.expectError(CodecError.InvalidLeb128, readUleb128(&bytes, &cursor));
}

test "LEB128 unsigned: 10-byte encoding with invalid high payload bits" {
    // Max u64 encodes in 10 bytes; the 10th byte may use at most
    // 1 payload bit (the high bit of u64). An encoding whose 10th
    // byte carries more than 1 payload bit overflows u64.
    // Construct 9 × 0xFF (continuation + all payload = 7 low bits
    // of u64 filled), then a 10th byte = 0x02 (payload bits 65-71
    // if we count from 0; i.e., past bit 63 of u64). Must reject.
    const bytes = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x02, // terminator; payload = 0b10 which would push bits 64+
    };
    var cursor: usize = 0;
    try testing.expectError(CodecError.InvalidLeb128, readUleb128(&bytes, &cursor));
}

// ---- Round-trip: scalars ----

test "roundtrip: nil, bools" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const cases = [_]Value{
        value.nilValue(),
        value.fromBool(true),
        value.fromBool(false),
    };
    for (cases) |v| {
        const got = try ctx.roundtrip(v);
        try testing.expect(got.tag == v.tag and got.payload == v.payload);
    }
}

test "roundtrip: char (ASCII, BMP, supplementary, max)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const scalars = [_]u21{ 'a', 0x2603, 0x1F600, 0x10FFFF, 0 };
    for (scalars) |s| {
        const v = value.fromChar(s).?;
        const got = try ctx.roundtrip(v);
        try testing.expect(got.kind() == .char);
        try testing.expectEqual(s, got.asChar());
    }
}

test "roundtrip: fixnum across full i48 range" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const cases = [_]i64{ 0, 1, -1, 42, -42, 1000000, -1000000, value.fixnum_max, value.fixnum_min };
    for (cases) |n| {
        const v = value.fromFixnum(n).?;
        const got = try ctx.roundtrip(v);
        try testing.expect(got.kind() == .fixnum);
        try testing.expectEqual(n, got.asFixnum());
    }
}

test "roundtrip: float (+0.0, -0.0, Inf, -Inf, NaN canonicalized, normal)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const pos_zero = value.fromFloat(0.0);
    const neg_zero = value.fromFloat(-0.0);
    const inf_p = value.fromFloat(std.math.inf(f64));
    const inf_n = value.fromFloat(-std.math.inf(f64));
    const nan = value.fromFloat(std.math.nan(f64));
    const pi = value.fromFloat(3.14159265358979);

    const rp = try ctx.roundtrip(pos_zero);
    try testing.expectEqual(pos_zero.payload, rp.payload);

    const rn = try ctx.roundtrip(neg_zero);
    try testing.expectEqual(neg_zero.payload, rn.payload); // -0.0 preserved bit-exact

    const ri = try ctx.roundtrip(inf_p);
    try testing.expect(std.math.isInf(ri.asFloat()) and ri.asFloat() > 0);

    const rm = try ctx.roundtrip(inf_n);
    try testing.expect(std.math.isInf(rm.asFloat()) and rm.asFloat() < 0);

    const rnan = try ctx.roundtrip(nan);
    try testing.expect(std.math.isNan(rnan.asFloat()));
    try testing.expectEqual(nan.payload, rnan.payload); // canonical NaN bits

    const rpi = try ctx.roundtrip(pi);
    try testing.expectEqual(pi.asFloat(), rpi.asFloat());
}

test "roundtrip: keyword and symbol (byte-exact names)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const kw = try ctx.interner.internKeywordValue("my-kw");
    const sym = try ctx.interner.internSymbolValue("my-sym");

    const rk = try ctx.roundtrip(kw);
    try testing.expect(rk.kind() == .keyword);
    try testing.expectEqualStrings("my-kw", ctx.interner.keywordName(rk.asKeywordId()));

    const rs = try ctx.roundtrip(sym);
    try testing.expect(rs.kind() == .symbol);
    try testing.expectEqualStrings("my-sym", ctx.interner.symbolName(rs.asSymbolId()));
}

test "roundtrip: string (empty, ASCII, UTF-8, binary bytes)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const cases = [_][]const u8{
        "",
        "hello, nexis",
        "☃ snowman",
        "\x00\xFF\xFEmixed",
    };
    for (cases) |bytes_case| {
        const v = try string.fromBytes(&ctx.heap, bytes_case);
        const got = try ctx.roundtrip(v);
        try testing.expect(got.kind() == .string);
        try testing.expectEqualStrings(bytes_case, string.asBytes(got));
    }
}

test "roundtrip: bignum (positive, negative, large)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const big_positive = try bignum.fromLimbs(&ctx.heap, false, &[_]u64{ 1, 1 });
    const big_negative = try bignum.fromLimbs(&ctx.heap, true, &[_]u64{ @as(u64, 1) << 60, 42 });

    const rp = try ctx.roundtrip(big_positive);
    try testing.expect(rp.kind() == .bignum);
    try testing.expect(bignum.limbsEqual(Heap.asHeapHeader(big_positive), Heap.asHeapHeader(rp)));

    const rn = try ctx.roundtrip(big_negative);
    try testing.expect(rn.kind() == .bignum);
    try testing.expect(bignum.isNegative(rn));
}

test "decode canonicalization: bignum with trailing zeros folds to fixnum" {
    // Manually construct wire bytes for a "bignum" whose limbs are
    // [42, 0, 0] — which, after canonicalization via
    // `bignum.fromLimbs`, must become fixnum(42).
    var ctx = TestCtx.init();
    defer ctx.deinit();

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeByte(&buf, testing.allocator, version_major);
    try writeByte(&buf, testing.allocator, version_minor);
    try writeByte(&buf, testing.allocator, @intFromEnum(Kind.bignum));
    try writeByte(&buf, testing.allocator, 0); // sign: non-negative
    try writeUleb128(&buf, testing.allocator, 3); // limb_count
    try writeU64Le(&buf, testing.allocator, 42);
    try writeU64Le(&buf, testing.allocator, 0);
    try writeU64Le(&buf, testing.allocator, 0);

    const got = try decode(&ctx.heap, &ctx.interner, buf.items, &synthHash, &synthEq);
    try testing.expect(got.kind() == .fixnum); // canonicalized
    try testing.expectEqual(@as(i64, 42), got.asFixnum());
}

// ---- Round-trip: containers ----

test "roundtrip: empty collections" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const el = try list_mod.empty(&ctx.heap);
    const ev = try vector_mod.empty(&ctx.heap);
    const em = try champ.mapEmpty(&ctx.heap);
    const es = try champ.setEmpty(&ctx.heap);

    try testing.expect(list_mod.isEmpty(try ctx.roundtrip(el)));
    try testing.expectEqual(@as(usize, 0), vector_mod.count(try ctx.roundtrip(ev)));
    try testing.expectEqual(@as(usize, 0), champ.mapCount(try ctx.roundtrip(em)));
    try testing.expectEqual(@as(usize, 0), champ.setCount(try ctx.roundtrip(es)));
}

test "roundtrip: list of fixnums" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const elems = [_]Value{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    };
    const src = try list_mod.fromSlice(&ctx.heap, &elems);
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 3), list_mod.count(got));
    try testing.expectEqual(@as(i64, 1), list_mod.head(got).asFixnum());
}

test "roundtrip: vector of 100 elements" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    var src = try vector_mod.empty(&ctx.heap);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        src = try vector_mod.conj(&ctx.heap, src, value.fromFixnum(@intCast(i)).?);
    }
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 100), vector_mod.count(got));
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(i64, @intCast(i)), vector_mod.nth(got, i).asFixnum());
    }
}

test "roundtrip: map (forces CHAMP) then element-wise check" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    // Intern 20 distinct keyword names.
    var kws: [20]Value = undefined;
    for (&kws, 0..) |*slot, i| {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        slot.* = try ctx.interner.internKeywordValue(name);
    }

    var src = try champ.mapEmpty(&ctx.heap);
    for (kws, 0..) |k, i| {
        src = try champ.mapAssoc(&ctx.heap, src, k, value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 20), champ.mapCount(got));
    for (kws, 0..) |k, i| {
        switch (champ.mapGet(got, k, &synthHash, &synthEq)) {
            .present => |v| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum()),
            .absent => try testing.expect(false),
        }
    }
}

test "roundtrip: set of 15 keywords" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    var kws: [15]Value = undefined;
    for (&kws, 0..) |*slot, i| {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "s{d}", .{i});
        slot.* = try ctx.interner.internKeywordValue(name);
    }

    var src = try champ.setEmpty(&ctx.heap);
    for (kws) |k| {
        src = try champ.setConj(&ctx.heap, src, k, &synthHash, &synthEq);
    }
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 15), champ.setCount(got));
    for (kws) |k| {
        try testing.expect(champ.setContains(got, k, &synthHash, &synthEq));
    }
}

test "roundtrip: nested structure (map whose values are lists of strings)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const kw = try ctx.interner.internKeywordValue("inner");
    const s1 = try string.fromBytes(&ctx.heap, "alpha");
    const s2 = try string.fromBytes(&ctx.heap, "beta");
    const lst = try list_mod.fromSlice(&ctx.heap, &.{ s1, s2 });
    var m = try champ.mapEmpty(&ctx.heap);
    m = try champ.mapAssoc(&ctx.heap, m, kw, lst, &synthHash, &synthEq);

    const got = try ctx.roundtrip(m);
    try testing.expectEqual(@as(usize, 1), champ.mapCount(got));
    switch (champ.mapGet(got, kw, &synthHash, &synthEq)) {
        .absent => try testing.expect(false),
        .present => |v| {
            try testing.expect(v.kind() == .list);
            try testing.expectEqual(@as(usize, 2), list_mod.count(v));
        },
    }
}

test "roundtrip: typed vectors of both element types, byte-stable" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const iv = try typed_vector.fromI64Slice(&ctx.heap, &.{ 1, -2, std.math.maxInt(i64), std.math.minInt(i64) });
    const fv = try typed_vector.fromF64Slice(&ctx.heap, &.{ 1.5, -0.0, std.math.inf(f64), std.math.nan(f64) });
    const ev = try typed_vector.fromF64Slice(&ctx.heap, &.{});

    const gi = try ctx.roundtrip(iv);
    try testing.expect(gi.kind() == .typed_vector);
    try testing.expectEqual(typed_vector.ElemType.i64, typed_vector.elemType(gi));
    try testing.expectEqualSlices(i64, typed_vector.i64Elems(iv), typed_vector.i64Elems(gi));

    const gf = try ctx.roundtrip(fv);
    try testing.expectEqual(typed_vector.ElemType.f64, typed_vector.elemType(gf));
    const src_bits: []const u64 = @ptrCast(typed_vector.f64Elems(fv));
    const got_bits: []const u64 = @ptrCast(typed_vector.f64Elems(gf));
    try testing.expectEqualSlices(u64, src_bits, got_bits);

    const ge = try ctx.roundtrip(ev);
    try testing.expectEqual(@as(usize, 0), typed_vector.count(ge));

    // Fixed-width elements in a fixed order: the re-encode is the
    // same bytes.
    const b1 = try encode(testing.allocator, &ctx.interner, fv);
    defer testing.allocator.free(b1);
    const b2 = try encode(testing.allocator, &ctx.interner, gf);
    defer testing.allocator.free(b2);
    try testing.expectEqualSlices(u8, b1, b2);
    // `[1 0] [23] [elem = 3] [count = 4] [4 × 8 bytes]`.
    try testing.expectEqual(@as(usize, 2 + 1 + 1 + 1 + 32), b1.len);
    try testing.expectEqual(@as(u8, @intFromEnum(Kind.typed_vector)), b1[2]);
    try testing.expectEqual(@as(u8, 3), b1[3]);
    try testing.expectEqual(@as(u8, 4), b1[4]);
}

test "decode: typed vector with an unknown element tag → MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.typed_vector), 2, 0 };
    try testing.expectError(
        CodecError.MalformedPayload,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: bignum whose limb count exceeds the input → TruncatedInput without allocating" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // Non-negative sign, limb count 2^56, one limb of input behind it.
    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.bignum), 0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(
        CodecError.TruncatedInput,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
    try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
}

test "decode: typed vector whose count exceeds the input → TruncatedInput without allocating" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // Count 2^56 with eight bytes of elements behind it.
    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.typed_vector), 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(
        CodecError.TruncatedInput,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
    try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
}

// ---- Hostile input: lengths, counts and depth come from the bytes ----

/// `[1 0] [kind] [uleb n] [rest]`, into `buf`.
fn hostile(buf: *std.ArrayListUnmanaged(u8), kind: u8, n: u64, rest: []const u8) ![]const u8 {
    try writeByte(buf, testing.allocator, version_major);
    try writeByte(buf, testing.allocator, version_minor);
    try writeByte(buf, testing.allocator, kind);
    try writeUleb128(buf, testing.allocator, n);
    try writeBytes(buf, testing.allocator, rest);
    return buf.items;
}

test "decode: a length near 2^64 is TruncatedInput, not an overflow" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // An interned name first, so a wrapped bounds check would hash
    // the bogus slice.
    _ = try ctx.interner.internKeywordValue("k");
    for ([_]u8{ @intFromEnum(Kind.string), @intFromEnum(Kind.keyword), @intFromEnum(Kind.symbol) }) |kind| {
        for ([_]u64{ std.math.maxInt(u64), std.math.maxInt(u64) - 7, std.math.maxInt(u64) - 2 }) |len| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(testing.allocator);
            const bytes = try hostile(&buf, kind, len, "abc");
            try testing.expectError(CodecError.TruncatedInput, decode(&ctx.heap, &ctx.interner, bytes, &synthHash, &synthEq));
        }
    }
}

test "decode: a bignum or typed-vector count near 2^64 is TruncatedInput" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    for ([_]u64{ std.math.maxInt(u64) / 8, std.math.maxInt(u64) / 8 - 1, std.math.maxInt(u64) }) |n| {
        var b1: std.ArrayListUnmanaged(u8) = .empty;
        defer b1.deinit(testing.allocator);
        try writeByte(&b1, testing.allocator, version_major);
        try writeByte(&b1, testing.allocator, version_minor);
        try writeByte(&b1, testing.allocator, @intFromEnum(Kind.bignum));
        try writeByte(&b1, testing.allocator, 0);
        try writeUleb128(&b1, testing.allocator, n);
        try writeU64Le(&b1, testing.allocator, 1);
        try testing.expectError(CodecError.TruncatedInput, decode(&ctx.heap, &ctx.interner, b1.items, &synthHash, &synthEq));

        var b2: std.ArrayListUnmanaged(u8) = .empty;
        defer b2.deinit(testing.allocator);
        try writeByte(&b2, testing.allocator, version_major);
        try writeByte(&b2, testing.allocator, version_minor);
        try writeByte(&b2, testing.allocator, @intFromEnum(Kind.typed_vector));
        try writeByte(&b2, testing.allocator, 1);
        try writeUleb128(&b2, testing.allocator, n);
        try writeU64Le(&b2, testing.allocator, 1);
        try testing.expectError(CodecError.TruncatedInput, decode(&ctx.heap, &ctx.interner, b2.items, &synthHash, &synthEq));
    }
    try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
}

test "decode: a collection count past the input is TruncatedInput before any allocation" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const kinds = [_]Kind{ .list, .persistent_vector, .persistent_map, .persistent_set };
    for (kinds) |kind| {
        for ([_]u64{ 1 << 35, std.math.maxInt(u64), 3 }) |n| {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            defer buf.deinit(testing.allocator);
            // Two nils: fewer bytes than three map entries, and than
            // any count of 3 or more elements.
            const bytes = try hostile(&buf, @intFromEnum(kind), n, &.{ 0, 0 });
            try testing.expectError(CodecError.TruncatedInput, decode(&ctx.heap, &ctx.interner, bytes, &synthHash, &synthEq));
            try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
        }
    }
}

test "decode: 200 000 levels of nesting decode, on any stack" {
    // Deep input allocates a block per level; the arena keeps the
    // test from paying the leak-checking allocator for each.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ctx: TestCtx = .{ .heap = Heap.init(arena.allocator()), .interner = Interner.init(testing.allocator) };
    defer ctx.interner.deinit();
    const depth = 200_000;
    for ([_]Kind{ .list, .persistent_vector, .persistent_set, .persistent_map }) |kind| {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try writeByte(&buf, testing.allocator, version_major);
        try writeByte(&buf, testing.allocator, version_minor);
        // One-element containers around a nil; a map's one entry is
        // `nil` to the next level.
        for (0..depth) |_| {
            try writeByte(&buf, testing.allocator, @intFromEnum(kind));
            try writeByte(&buf, testing.allocator, 1);
            if (kind == .persistent_map) try writeByte(&buf, testing.allocator, 0);
        }
        try writeByte(&buf, testing.allocator, 0);
        var v = try decode(&ctx.heap, &ctx.interner, buf.items, &synthHash, &synthEq);
        var levels: usize = 0;
        while (v.kind() == kind) : (levels += 1) v = switch (kind) {
            .list => list_mod.head(v),
            .persistent_vector => vector_mod.nth(v, 0),
            .persistent_set => blk: {
                var it = champ.setIter(v);
                break :blk it.next().?;
            },
            else => blk: {
                var it = champ.mapIter(v);
                break :blk it.next().?.value;
            },
        };
        try testing.expectEqual(@as(usize, depth), levels);
        try testing.expect(v.isNil());
    }
}

test "decode: nested counts that each claim the rest of the input allocate by what is decoded" {
    for ([_]Kind{ .list, .persistent_vector }) |kind| {
        var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
        var heap = Heap.init(counting.allocator());
        defer heap.deinit();
        var interner = Interner.init(testing.allocator);
        defer interner.deinit();
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try writeByte(&buf, testing.allocator, version_major);
        try writeByte(&buf, testing.allocator, version_minor);
        // 1000 levels each claiming 3000 elements, then 2000 nils:
        // every level but the deepest few passes the count check.
        for (0..1000) |_| {
            try writeByte(&buf, testing.allocator, @intFromEnum(kind));
            try writeUleb128(&buf, testing.allocator, 3000);
        }
        try buf.appendNTimes(testing.allocator, @intFromEnum(Kind.nil), 2000);
        try testing.expectError(CodecError.TruncatedInput, decode(&heap, &interner, buf.items, &synthHash, &synthEq));
        try testing.expect(counting.allocated_bytes <= 16 * buf.items.len);
    }
}

test "codec: a value nested 200 000 deep round-trips byte for byte" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var ctx: TestCtx = .{ .heap = Heap.init(arena.allocator()), .interner = Interner.init(testing.allocator) };
    defer ctx.interner.deinit();
    var v = value.nilValue();
    for (0..200_000) |i| v = switch (i % 3) {
        0 => try vector_mod.fromSlice(&ctx.heap, &.{ value.fromFixnum(@intCast(i)).?, v }),
        1 => try list_mod.fromSlice(&ctx.heap, &.{v}),
        else => try champ.mapAssoc(&ctx.heap, try champ.mapEmpty(&ctx.heap), value.fromFixnum(@intCast(i)).?, v, &synthHash, &synthEq),
    };
    const bytes = try encode(testing.allocator, &ctx.interner, v);
    defer testing.allocator.free(bytes);
    const got = try decode(&ctx.heap, &ctx.interner, bytes, &synthHash, &synthEq);
    const again = try encode(testing.allocator, &ctx.interner, got);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, bytes, again);
}

test "decode: a map or set whose count disagrees with its distinct entries is MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // {1 1, 1 2}: two entries, one distinct key.
    const map_bytes = [_]u8{ 1, 0, @intFromEnum(Kind.persistent_map), 2, 4, 2, 4, 2, 4, 2, 4, 4 };
    try testing.expectError(CodecError.MalformedPayload, decode(&ctx.heap, &ctx.interner, &map_bytes, &synthHash, &synthEq));
    // #{1 1}.
    const set_bytes = [_]u8{ 1, 0, @intFromEnum(Kind.persistent_set), 2, 4, 2, 4, 2 };
    try testing.expectError(CodecError.MalformedPayload, decode(&ctx.heap, &ctx.interner, &set_bytes, &synthHash, &synthEq));
}

test "decode: every kind byte outside the serializable set is refused with a typed error" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const serializable = [_]Kind{ .nil, .false_, .true_, .char, .fixnum, .float, .keyword, .symbol, .string, .bignum, .persistent_map, .persistent_set, .persistent_vector, .list, .typed_vector, .sorted_map, .sorted_set };
    var b: usize = 0;
    while (b < 256) : (b += 1) {
        const byte: u8 = @intCast(b);
        const known = for (serializable) |k| {
            if (@intFromEnum(k) == byte) break true;
        } else false;
        if (known) continue;
        const bytes = [_]u8{ 1, 0, byte };
        const want: CodecError = if (isHeapKindByte(byte)) CodecError.UnserializableKind else CodecError.InvalidKindByte;
        try testing.expectError(want, decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq));
    }
    // The identity kinds among them.
    for ([_]Kind{ .atom, .record, .protocol, .protocol_fn, .function, .durable_ref }) |k| {
        const bytes = [_]u8{ 1, 0, @intFromEnum(k) };
        try testing.expectError(CodecError.UnserializableKind, decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq));
    }
}

// ---- Sorted collections (CODEC.md §2.8) ----

/// Keyword `name` in `ctx`'s interner.
fn keywordIn(ctx: *TestCtx, name: []const u8) !Value {
    return ctx.interner.internKeywordValue(name);
}

test "roundtrip: a sorted map and set in the natural order come back sorted, entry for entry" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const order = sorted.Natural{ .interner = &ctx.interner };
    var m = try sorted.empty(&ctx.heap, .sorted_map, value.nilValue());
    var s = try sorted.empty(&ctx.heap, .sorted_set, value.nilValue());
    for ([_][]const u8{ "pear", "apple", "fig", "b/kiwi", "date" }, 0..) |name, i| {
        m = try sorted.assoc(&ctx.heap, m, try keywordIn(&ctx, name), value.fromFixnum(@intCast(i)).?, order);
        s = try sorted.conj(&ctx.heap, s, try string.fromBytes(&ctx.heap, name), order);
    }
    for ([_]Value{ m, s, try sorted.empty(&ctx.heap, .sorted_set, value.nilValue()) }) |v| {
        const got = try ctx.roundtrip(v);
        try testing.expectEqual(v.kind(), got.kind());
        try testing.expectEqual(sorted.count(v), sorted.count(got));
        try sorted.checkInvariants(got, order);
        var a = sorted.Iter.init(v, true);
        var b = sorted.Iter.init(got, true);
        while (a.next()) |x| {
            const y = b.next().?;
            try testing.expectEqual(std.math.Order.eq, try order.order(x.key, y.key));
            try testing.expect(synthEq(x.value, y.value));
        }
    }
    // Written in ascending order: the keyword `:apple` comes first.
    const bytes = try encode(testing.allocator, &ctx.interner, m);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 1, 0, @intFromEnum(Kind.sorted_map), 5, @intFromEnum(Kind.keyword), 5, 'a', 'p', 'p', 'l', 'e' }, bytes[0..11]);
}

test "encode: a sorted collection with a comparator of its own is unserializable" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const by = value.fromNativeFnPtr(&ctx);
    try testing.expectError(CodecError.UnserializableKind, encode(testing.allocator, &ctx.interner, try sorted.empty(&ctx.heap, .sorted_map, by)));
    try testing.expectError(CodecError.UnserializableKind, encode(testing.allocator, &ctx.interner, try sorted.empty(&ctx.heap, .sorted_set, by)));
}

test "decode: sorted entries out of order, repeated or without an order are MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const map_tag = @intFromEnum(Kind.sorted_map);
    const set_tag = @intFromEnum(Kind.sorted_set);
    const fixnum = @intFromEnum(Kind.fixnum);
    // {2 0, 1 0}: descending keys.
    const descending = [_]u8{ 1, 0, map_tag, 2, fixnum, 4, fixnum, 0, fixnum, 2, fixnum, 0 };
    try testing.expectError(CodecError.MalformedPayload, decode(&ctx.heap, &ctx.interner, &descending, &synthHash, &synthEq));
    // #{1 1}.
    const repeated = [_]u8{ 1, 0, set_tag, 2, fixnum, 2, fixnum, 2 };
    try testing.expectError(CodecError.MalformedPayload, decode(&ctx.heap, &ctx.interner, &repeated, &synthHash, &synthEq));
    // #{1 nil-list}: a list has no natural order.
    const unordered = [_]u8{ 1, 0, set_tag, 2, fixnum, 2, @intFromEnum(Kind.list), 0 };
    try testing.expectError(CodecError.MalformedPayload, decode(&ctx.heap, &ctx.interner, &unordered, &synthHash, &synthEq));
    // One entry needs no comparison, whatever its key.
    const single = [_]u8{ 1, 0, set_tag, 1, @intFromEnum(Kind.list), 0 };
    const got = try decode(&ctx.heap, &ctx.interner, &single, &synthHash, &synthEq);
    try testing.expectEqual(@as(usize, 1), sorted.count(got));
}

// ---- Error surface ----

test "encode: transient is unserializable" {
    const transient = @import("coll/transient.zig");
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const m = try champ.mapEmpty(&ctx.heap);
    const t = try transient.transientFrom(&ctx.heap, m);
    try testing.expectError(
        CodecError.UnserializableKind,
        encode(testing.allocator, &ctx.interner, t),
    );
}

test "decode: wrong major version → InvalidVersion" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{ 2, 0, @intFromEnum(Kind.nil) };
    try testing.expectError(
        CodecError.InvalidVersion,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: wrong minor version → InvalidVersion" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{ 1, 5, @intFromEnum(Kind.nil) };
    try testing.expectError(
        CodecError.InvalidVersion,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: truncated envelope" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{1};
    try testing.expectError(
        CodecError.TruncatedInput,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: trailing bytes → TrailingBytes" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.nil), 0xFF };
    try testing.expectError(
        CodecError.TrailingBytes,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: invalid kind byte → InvalidKindByte" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    // Byte 10 is in the reserved 8..15 immediates range.
    const bytes = [_]u8{ 1, 0, 10 };
    try testing.expectError(
        CodecError.InvalidKindByte,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: recognized-but-non-serializable kind → UnserializableKind" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    // transient is kind 27, recognized but non-serializable.
    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.transient) };
    try testing.expectError(
        CodecError.UnserializableKind,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: malformed bignum sign byte → MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.bignum), 7, 0 };
    try testing.expectError(
        CodecError.MalformedPayload,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: invalid char scalar → InvalidCharScalar (surrogate)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.char), 0x00, 0xD8, 0x00, 0x00 };
    try testing.expectError(
        CodecError.InvalidCharScalar,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: invalid char scalar → InvalidCharScalar (out of range)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.char), 0x00, 0x00, 0x11, 0x00 };
    try testing.expectError(
        CodecError.InvalidCharScalar,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: truncated body mid-string" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    // String with length 5 but only 3 bytes provided.
    const bytes = [_]u8{ 1, 0, @intFromEnum(Kind.string), 5, 'a', 'b', 'c' };
    try testing.expectError(
        CodecError.TruncatedInput,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}
