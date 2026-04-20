//! codec.zig — serialize / deserialize Value ↔ bytes (Phase 1).
//!
//! Authoritative spec: `docs/CODEC.md`. Derivative from PLAN
//! §15.6 / §15.10 / §23 #25 (serialization scope frozen),
//! `docs/SEMANTICS.md` §2.2 / §3.2 (numeric canonical form +
//! hash invariants), and `docs/VALUE.md` §2 (Kind numbering).
//!
//! Ships the v1 interim wire format pinned in CODEC.md §2:
//!
//!   [major: u8 = 1] [minor: u8 = 0] [ValueEncoding]
//!
//! where ValueEncoding is a kind-tagged payload. All integers are
//! little-endian; all lengths / counts are unsigned LEB128;
//! fixnums are signed ZigZag LEB128; floats and chars are fixed-
//! width LE. See CODEC.md §2 for the per-kind table.
//!
//! Scope (CODEC.md §1):
//!   In: nil, bool, char, fixnum, float, keyword, symbol, string,
//!       bignum, list, persistent_vector, persistent_map,
//!       persistent_set.
//!   Out: function, var_, transient, error_, meta_symbol,
//!        byte_vector, typed_vector, durable_ref (non-serializable
//!        or reserved-unallocated). Public API returns
//!        `error.UnserializableKind`.
//!
//! Closes PLAN §20.2 gate test #5 (codec round-trip).
//!
//! Module graph (one-way terminal; dispatch / gc / transient /
//! codec all share this shape):
//!
//!     src/codec.zig
//!     ├── @import("value")
//!     ├── @import("heap")
//!     ├── @import("intern")
//!     ├── @import("hash")
//!     ├── @import("string")
//!     ├── @import("bignum")
//!     ├── @import("list")
//!     ├── @import("vector")
//!     └── @import("hamt")
//!
//! Nothing imports `codec.zig`.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const hash_mod = @import("hash");
const string = @import("string");
const bignum = @import("bignum");
const list = @import("list");
const vector = @import("vector");
const hamt = @import("hamt");

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
    /// Attempt to encode/decode a kind excluded from the v1
    /// Serializable set — function, var_, transient, error_,
    /// meta_symbol, byte_vector, typed_vector, durable_ref. Public
    /// API typed error (peer-AI turn 20 wording).
    UnserializableKind,

    /// Decode ran out of bytes mid-value.
    TruncatedInput,

    /// Decode consumed a valid value but input has extra bytes.
    /// Exactly one envelope + body expected per decode call.
    TrailingBytes,

    /// Envelope version bytes don't match a version this build
    /// understands. v1 accepts only `[1, 0]`.
    InvalidVersion,

    /// First byte of a ValueEncoding isn't a recognized Kind
    /// numeric value. Distinct from UnserializableKind which is
    /// returned for recognized-but-non-serializable kinds.
    InvalidKindByte,

    /// Unsigned LEB128 decode overflow (> 10 continuation bytes,
    /// or value > u64 max).
    InvalidLeb128,

    /// Char encoding decoded to a surrogate (D800..DFFF) or value
    /// > 0x10FFFF. Matches `value.fromChar` rejection.
    InvalidCharScalar,

    /// Per-kind payload field is structurally invalid: bignum
    /// sign byte not in {0, 1}, or similar per-kind field.
    /// Distinct from InvalidKindByte (which is about the top-level
    /// kind tag) per peer-AI turn 21.
    MalformedPayload,
};

// =============================================================================
// Varint primitives (unsigned LEB128 + signed ZigZag LEB128)
// =============================================================================

/// Max u64 LEB128 encoding: 10 bytes (64 / 7 = 9.1, rounded up).
const max_uleb128_bytes: usize = 10;

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

/// Decode unsigned LEB128 starting at `cursor.*`. Advances cursor
/// past the consumed bytes. Errors on overflow (value doesn't fit
/// u64) or truncation (ran out of bytes before terminator).
fn readUleb128(bytes: []const u8, cursor: *usize) CodecError!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    var consumed: usize = 0;
    while (true) : (consumed += 1) {
        if (cursor.* >= bytes.len) return CodecError.TruncatedInput;
        if (consumed >= max_uleb128_bytes) return CodecError.InvalidLeb128;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        const payload: u64 = byte & 0x7F;
        // Overflow check: shifting payload by `shift` must not lose bits.
        const shifted_ok = shift == 0 or (payload == (payload << @as(u6, shift)) >> @as(u6, shift));
        if (!shifted_ok) return CodecError.InvalidLeb128;
        result |= payload << shift;
        if (byte & 0x80 == 0) return result;
        const new_shift: u32 = @as(u32, shift) + 7;
        if (new_shift >= 64) {
            // Next byte's payload would need to fit in the high
            // bits of u64; flag overflow if the final byte has
            // bits that would shift past bit 63.
            if (byte & 0x80 != 0) return CodecError.InvalidLeb128;
        }
        if (new_shift > 63) return CodecError.InvalidLeb128;
        shift = @intCast(new_shift);
    }
}

/// ZigZag: signed i64 → u64 for compact LEB128 encoding of small
/// signed values. Both encode and decode operate entirely in u64
/// space — no signed left shift (defensive against future
/// `i64.min` / `i64.max` edge cases per peer-AI turn 22 even
/// though fixnum range is i48 and can't reach them).
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
    if (cursor.* + 4 > bytes.len) return CodecError.TruncatedInput;
    const v = std.mem.readInt(u32, bytes[cursor.*..][0..4], .little);
    cursor.* += 4;
    return v;
}

fn writeU64Le(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn readU64Le(bytes: []const u8, cursor: *usize) CodecError!u64 {
    if (cursor.* + 8 > bytes.len) return CodecError.TruncatedInput;
    const v = std.mem.readInt(u64, bytes[cursor.*..][0..8], .little);
    cursor.* += 8;
    return v;
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

fn readBytes(bytes: []const u8, cursor: *usize, len: usize) CodecError![]const u8 {
    if (cursor.* + len > bytes.len) return CodecError.TruncatedInput;
    const slice = bytes[cursor.*..][0..len];
    cursor.* += len;
    return slice;
}

// =============================================================================
// Public API
// =============================================================================

/// Encode `v` to a freshly-allocated byte slice. Caller frees.
/// Returns `UnserializableKind` if `v` is not in the v1
/// serializable set (CODEC.md §1).
pub fn encode(
    allocator: std.mem.Allocator,
    interner: *const Interner,
    v: Value,
) (CodecError || std.mem.Allocator.Error)![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Version envelope — top level only.
    try writeByte(&buf, allocator, version_major);
    try writeByte(&buf, allocator, version_minor);
    try encodeValue(&buf, allocator, interner, v);

    return buf.toOwnedSlice(allocator);
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
) (CodecError || std.mem.Allocator.Error || intern_mod.InternError || error{ Overflow, InvalidListTail })!Value {
    var cursor: usize = 0;

    // Envelope.
    if (cursor + 2 > bytes.len) return CodecError.TruncatedInput;
    const maj = bytes[cursor];
    const min = bytes[cursor + 1];
    if (maj != version_major or min != version_minor) return CodecError.InvalidVersion;
    cursor += 2;

    const v = try decodeValue(heap, interner, bytes, &cursor, elementHash, elementEq);
    if (cursor != bytes.len) return CodecError.TrailingBytes;
    return v;
}

// =============================================================================
// encodeValue — recursive
// =============================================================================

fn encodeValue(
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    interner: *const Interner,
    v: Value,
) (CodecError || std.mem.Allocator.Error)!void {
    const k = v.kind();
    switch (k) {
        .nil => try writeByte(buf, allocator, @intFromEnum(Kind.nil)),
        .false_ => try writeByte(buf, allocator, @intFromEnum(Kind.false_)),
        .true_ => try writeByte(buf, allocator, @intFromEnum(Kind.true_)),
        .char => {
            try writeByte(buf, allocator, @intFromEnum(Kind.char));
            try writeU32Le(buf, allocator, @as(u32, v.asChar()));
        },
        .fixnum => {
            try writeByte(buf, allocator, @intFromEnum(Kind.fixnum));
            try writeIleb128Zigzag(buf, allocator, v.asFixnum());
        },
        .float => {
            try writeByte(buf, allocator, @intFromEnum(Kind.float));
            // Canonicalize NaN on the way out (redundant with
            // `fromFloat`'s entry canonicalization but defensive).
            const canonical = hash_mod.canonicalizeFloat(v.asFloat());
            try writeU64Le(buf, allocator, @as(u64, @bitCast(canonical)));
        },
        .keyword => {
            try writeByte(buf, allocator, @intFromEnum(Kind.keyword));
            const name = interner.keywordName(v.asKeywordId());
            try writeUleb128(buf, allocator, @as(u64, name.len));
            try writeBytes(buf, allocator, name);
        },
        .symbol => {
            try writeByte(buf, allocator, @intFromEnum(Kind.symbol));
            const name = interner.symbolName(v.asSymbolId());
            try writeUleb128(buf, allocator, @as(u64, name.len));
            try writeBytes(buf, allocator, name);
        },
        .string => {
            try writeByte(buf, allocator, @intFromEnum(Kind.string));
            const bytes = string.asBytes(v);
            try writeUleb128(buf, allocator, @as(u64, bytes.len));
            try writeBytes(buf, allocator, bytes);
        },
        .bignum => {
            try writeByte(buf, allocator, @intFromEnum(Kind.bignum));
            try writeByte(buf, allocator, if (bignum.isNegative(v)) @as(u8, 1) else @as(u8, 0));
            const limbs = bignum.limbs(v);
            try writeUleb128(buf, allocator, @as(u64, limbs.len));
            for (limbs) |limb| try writeU64Le(buf, allocator, limb);
        },
        .list => {
            try writeByte(buf, allocator, @intFromEnum(Kind.list));
            // Count first, then elements.
            const n = list.count(v);
            try writeUleb128(buf, allocator, @as(u64, n));
            var cur = v;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try encodeValue(buf, allocator, interner, list.head(cur));
                cur = list.tail(cur);
            }
        },
        .persistent_vector => {
            try writeByte(buf, allocator, @intFromEnum(Kind.persistent_vector));
            const n = vector.count(v);
            try writeUleb128(buf, allocator, @as(u64, n));
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try encodeValue(buf, allocator, interner, vector.nth(v, i));
            }
        },
        .persistent_map => {
            try writeByte(buf, allocator, @intFromEnum(Kind.persistent_map));
            const n = hamt.mapCount(v);
            try writeUleb128(buf, allocator, @as(u64, n));
            var iter = hamt.mapIter(v);
            while (iter.next()) |entry| {
                try encodeValue(buf, allocator, interner, entry.key);
                try encodeValue(buf, allocator, interner, entry.value);
            }
        },
        .persistent_set => {
            try writeByte(buf, allocator, @intFromEnum(Kind.persistent_set));
            const n = hamt.setCount(v);
            try writeUleb128(buf, allocator, @as(u64, n));
            var iter = hamt.setIter(v);
            while (iter.next()) |elem| {
                try encodeValue(buf, allocator, interner, elem);
            }
        },
        // Non-serializable kinds (CODEC.md §3).
        .byte_vector,
        .typed_vector,
        .function,
        .var_,
        .durable_ref,
        .transient,
        .error_,
        .meta_symbol,
        => return CodecError.UnserializableKind,
        // Sentinels (unbound, undef) and any other non-heap,
        // non-immediate kind reaching here is a runtime bug. Treat
        // as unserializable at the public API boundary.
        else => return CodecError.UnserializableKind,
    }
}

// =============================================================================
// decodeValue — recursive
// =============================================================================

fn decodeValue(
    heap: *Heap,
    interner: *Interner,
    bytes: []const u8,
    cursor: *usize,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) (CodecError || std.mem.Allocator.Error || intern_mod.InternError || error{ Overflow, InvalidListTail })!Value {
    const tag = try readByte(bytes, cursor);
    return switch (tag) {
        @intFromEnum(Kind.nil) => value.nilValue(),
        @intFromEnum(Kind.false_) => value.fromBool(false),
        @intFromEnum(Kind.true_) => value.fromBool(true),
        @intFromEnum(Kind.char) => blk: {
            const scalar_u32 = try readU32Le(bytes, cursor);
            if (scalar_u32 > 0x10FFFF) return CodecError.InvalidCharScalar;
            const scalar: u21 = @intCast(scalar_u32);
            const v = value.fromChar(scalar) orelse return CodecError.InvalidCharScalar;
            break :blk v;
        },
        @intFromEnum(Kind.fixnum) => blk: {
            const n = try readIleb128Zigzag(bytes, cursor);
            const v = value.fromFixnum(n) orelse {
                // i64 outside i48 range — would normally promote to
                // bignum. But the encoded kind byte said fixnum, so
                // the input is malformed or the encoder emitted a
                // non-canonical fixnum. Treat as malformed rather
                // than promote (keeps the wire format's kind byte
                // authoritative).
                return CodecError.MalformedPayload;
            };
            break :blk v;
        },
        @intFromEnum(Kind.float) => blk: {
            const bits = try readU64Le(bytes, cursor);
            const f: f64 = @bitCast(bits);
            break :blk value.fromFloat(f);
        },
        @intFromEnum(Kind.keyword) => blk: {
            const len_u64 = try readUleb128(bytes, cursor);
            const len: usize = std.math.cast(usize, len_u64) orelse return CodecError.InvalidLeb128;
            const name = try readBytes(bytes, cursor, len);
            break :blk try interner.internKeywordValue(name);
        },
        @intFromEnum(Kind.symbol) => blk: {
            const len_u64 = try readUleb128(bytes, cursor);
            const len: usize = std.math.cast(usize, len_u64) orelse return CodecError.InvalidLeb128;
            const name = try readBytes(bytes, cursor, len);
            break :blk try interner.internSymbolValue(name);
        },
        @intFromEnum(Kind.string) => blk: {
            const len_u64 = try readUleb128(bytes, cursor);
            const len: usize = std.math.cast(usize, len_u64) orelse return CodecError.InvalidLeb128;
            const bytes_slice = try readBytes(bytes, cursor, len);
            break :blk try string.fromBytes(heap, bytes_slice);
        },
        @intFromEnum(Kind.bignum) => blk: {
            const sign = try readByte(bytes, cursor);
            if (sign != 0 and sign != 1) return CodecError.MalformedPayload;
            const limb_count_u64 = try readUleb128(bytes, cursor);
            const limb_count: usize = std.math.cast(usize, limb_count_u64) orelse return CodecError.InvalidLeb128;
            // Read limbs into a temporary buffer (uses the Heap's
            // backing allocator — the Heap is the authoritative
            // runtime allocator source for this decode).
            const limbs = try heap.backing.alloc(u64, limb_count);
            defer heap.backing.free(limbs);
            for (limbs) |*slot| slot.* = try readU64Le(bytes, cursor);
            // Canonicalize via bignum.fromLimbs (CODEC.md §2.6
            // — decode accepts non-canonical and normalizes).
            break :blk try bignum.fromLimbs(heap, sign == 1, limbs);
        },
        @intFromEnum(Kind.list) => blk: {
            const count_u64 = try readUleb128(bytes, cursor);
            const n: usize = std.math.cast(usize, count_u64) orelse return CodecError.InvalidLeb128;
            // Build list right-to-left: read all elements into a
            // scratch array, then fold via `cons` from the tail.
            const elems = try heap.backing.alloc(Value, n);
            defer heap.backing.free(elems);
            for (elems) |*slot| {
                slot.* = try decodeValue(heap, interner, bytes, cursor, elementHash, elementEq);
            }
            break :blk try list.fromSlice(heap, elems);
        },
        @intFromEnum(Kind.persistent_vector) => blk: {
            const count_u64 = try readUleb128(bytes, cursor);
            const n: usize = std.math.cast(usize, count_u64) orelse return CodecError.InvalidLeb128;
            var v = try vector.empty(heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const elem = try decodeValue(heap, interner, bytes, cursor, elementHash, elementEq);
                v = try vector.conj(heap, v, elem);
            }
            break :blk v;
        },
        @intFromEnum(Kind.persistent_map) => blk: {
            const count_u64 = try readUleb128(bytes, cursor);
            const n: usize = std.math.cast(usize, count_u64) orelse return CodecError.InvalidLeb128;
            var m = try hamt.mapEmpty(heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const key = try decodeValue(heap, interner, bytes, cursor, elementHash, elementEq);
                const val = try decodeValue(heap, interner, bytes, cursor, elementHash, elementEq);
                m = try hamt.mapAssoc(heap, m, key, val, elementHash, elementEq);
            }
            break :blk m;
        },
        @intFromEnum(Kind.persistent_set) => blk: {
            const count_u64 = try readUleb128(bytes, cursor);
            const n: usize = std.math.cast(usize, count_u64) orelse return CodecError.InvalidLeb128;
            var s = try hamt.setEmpty(heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const elem = try decodeValue(heap, interner, bytes, cursor, elementHash, elementEq);
                s = try hamt.setConj(heap, s, elem, elementHash, elementEq);
            }
            break :blk s;
        },
        // Recognized-but-non-serializable kinds (CODEC.md §3).
        // These kind bytes ARE valid `Kind` enum values; they're
        // just not in the v1 serializable subset.
        @intFromEnum(Kind.byte_vector),
        @intFromEnum(Kind.typed_vector),
        @intFromEnum(Kind.function),
        @intFromEnum(Kind.var_),
        @intFromEnum(Kind.durable_ref),
        @intFromEnum(Kind.transient),
        @intFromEnum(Kind.error_),
        @intFromEnum(Kind.meta_symbol),
        => CodecError.UnserializableKind,
        // Any other byte — including values in the reserved range
        // (8..15 immediates, 30..63 heap, 64..255 sentinels/unused)
        // — is an invalid kind byte.
        else => CodecError.InvalidKindByte,
    };
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

test "LEB128 unsigned: 10-byte encoding with invalid high payload bits (peer-AI turn 22)" {
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

    const el = try list.empty(&ctx.heap);
    const ev = try vector.empty(&ctx.heap);
    const em = try hamt.mapEmpty(&ctx.heap);
    const es = try hamt.setEmpty(&ctx.heap);

    try testing.expect(list.isEmpty(try ctx.roundtrip(el)));
    try testing.expectEqual(@as(usize, 0), vector.count(try ctx.roundtrip(ev)));
    try testing.expectEqual(@as(usize, 0), hamt.mapCount(try ctx.roundtrip(em)));
    try testing.expectEqual(@as(usize, 0), hamt.setCount(try ctx.roundtrip(es)));
}

test "roundtrip: list of fixnums" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const elems = [_]Value{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    };
    const src = try list.fromSlice(&ctx.heap, &elems);
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 3), list.count(got));
    try testing.expectEqual(@as(i64, 1), list.head(got).asFixnum());
}

test "roundtrip: vector of 100 elements" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    var src = try vector.empty(&ctx.heap);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        src = try vector.conj(&ctx.heap, src, value.fromFixnum(@intCast(i)).?);
    }
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 100), vector.count(got));
    i = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(i64, @intCast(i)), vector.nth(got, i).asFixnum());
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

    var src = try hamt.mapEmpty(&ctx.heap);
    for (kws, 0..) |k, i| {
        src = try hamt.mapAssoc(&ctx.heap, src, k, value.fromFixnum(@intCast(i)).?, &synthHash, &synthEq);
    }
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 20), hamt.mapCount(got));
    for (kws, 0..) |k, i| {
        switch (hamt.mapGet(got, k, &synthHash, &synthEq)) {
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

    var src = try hamt.setEmpty(&ctx.heap);
    for (kws) |k| {
        src = try hamt.setConj(&ctx.heap, src, k, &synthHash, &synthEq);
    }
    const got = try ctx.roundtrip(src);
    try testing.expectEqual(@as(usize, 15), hamt.setCount(got));
    for (kws) |k| {
        try testing.expect(hamt.setContains(got, k, &synthHash, &synthEq));
    }
}

test "roundtrip: nested structure (map whose values are lists of strings)" {
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const kw = try ctx.interner.internKeywordValue("inner");
    const s1 = try string.fromBytes(&ctx.heap, "alpha");
    const s2 = try string.fromBytes(&ctx.heap, "beta");
    const lst = try list.fromSlice(&ctx.heap, &.{ s1, s2 });
    var m = try hamt.mapEmpty(&ctx.heap);
    m = try hamt.mapAssoc(&ctx.heap, m, kw, lst, &synthHash, &synthEq);

    const got = try ctx.roundtrip(m);
    try testing.expectEqual(@as(usize, 1), hamt.mapCount(got));
    switch (hamt.mapGet(got, kw, &synthHash, &synthEq)) {
        .absent => try testing.expect(false),
        .present => |v| {
            try testing.expect(v.kind() == .list);
            try testing.expectEqual(@as(usize, 2), list.count(v));
        },
    }
}

// ---- Error surface ----

test "encode: transient is unserializable" {
    const transient = @import("transient");
    var ctx = TestCtx.init();
    defer ctx.deinit();

    const m = try hamt.mapEmpty(&ctx.heap);
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
