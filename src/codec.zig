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
//! float, instant, keyword, symbol, string, bignum, UUID, list,
//! vector, map, set, typed vector, and the sorted map and set in the
//! natural order)
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
const uuid = @import("uuid.zig");
const bignum = @import("bignum.zig");
const list_mod = @import("coll/list.zig");
const lazy_mod = @import("coll/lazy.zig");
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
// Errors (CODEC.md §5)
// =============================================================================

/// A kind outside the serializable set (CODEC.md §3), memory, or a lazy
/// seq whose body has not run, which the codec never runs: the caller
/// realizes the value and encodes it again.
pub const EncodeError = error{ UnserializableKind, Unrealized } || std.mem.Allocator.Error;

/// `TruncatedInput`: the input ends mid-value, or a length or count
/// asks for more than it holds. `MalformedPayload`: input no encoder
/// writes (CODEC.md §5).
pub const DecodeError = error{ TruncatedInput, MalformedPayload, Overflow } || std.mem.Allocator.Error || intern_mod.InternError;

// =============================================================================
// Varint primitives (unsigned LEB128 + signed ZigZag LEB128)
// =============================================================================

inline fn writeUleb128(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
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
/// more overflows u64. Overlong encodings (`80 00`) are accepted:
/// encode never writes them, and they name the same number.
fn readUleb128(bytes: []const u8, cursor: *usize) DecodeError!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) : (shift += 7) {
        const byte = try readByte(bytes, cursor);
        if (shift == 63 and byte > 1) return error.MalformedPayload;
        result |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
    }
}

/// ZigZag LEB128: `(v << 1) ^ (v >> 63)`, the shift arithmetic, keeps
/// small magnitudes of either sign small.
fn writeIleb128Zigzag(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i64) !void {
    const u: u64 = @bitCast(v);
    try writeUleb128(buf, allocator, (u << 1) ^ (@as(u64, 0) -% (u >> 63)));
}

fn readIleb128Zigzag(bytes: []const u8, cursor: *usize) DecodeError!i64 {
    const u = try readUleb128(bytes, cursor);
    return @bitCast((u >> 1) ^ (@as(u64, 0) -% (u & 1)));
}

// =============================================================================
// Fixed-width primitives
// =============================================================================

fn writeU32Le(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn readU32Le(bytes: []const u8, cursor: *usize) DecodeError!u32 {
    return std.mem.readInt(u32, (try readBytes(bytes, cursor, 4))[0..4], .little);
}

fn writeU64Le(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    try buf.appendSlice(allocator, &bytes);
}

fn readU64Le(bytes: []const u8, cursor: *usize) DecodeError!u64 {
    return std.mem.readInt(u64, (try readBytes(bytes, cursor, 8))[0..8], .little);
}

fn readByte(bytes: []const u8, cursor: *usize) DecodeError!u8 {
    if (cursor.* >= bytes.len) return error.TruncatedInput;
    const b = bytes[cursor.*];
    cursor.* += 1;
    return b;
}

/// `len` comes from the input and may be anything up to 2^64-1, so
/// the bound is written as a subtraction: `cursor.* <= bytes.len`
/// always holds, and `cursor.* + len` could wrap.
fn readBytes(bytes: []const u8, cursor: *usize, len: usize) DecodeError![]const u8 {
    if (len > bytes.len - cursor.*) return error.TruncatedInput;
    const slice = bytes[cursor.*..][0..len];
    cursor.* += len;
    return slice;
}

// =============================================================================
// Public API
// =============================================================================

/// Encode `v` to a freshly-allocated byte slice. Caller frees.
pub fn encode(
    allocator: std.mem.Allocator,
    interner: *const Interner,
    v: Value,
) EncodeError![]u8 {
    var e: Encoder = .{ .allocator = allocator, .interner = interner };
    defer e.stack.deinit(allocator);
    errdefer e.buf.deinit(allocator);
    try e.byte(version_major);
    try e.byte(version_minor);
    try e.run(v);
    return e.buf.toOwnedSlice(allocator);
}

/// Decode a byte slice to a Value, consuming it completely. `heap`
/// owns the new Value's blocks; `interner` gives keywords and symbols
/// their ids.
pub fn decode(
    heap: *Heap,
    interner: *Interner,
    bytes: []const u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) DecodeError!Value {
    if (bytes.len < 2) return error.TruncatedInput;
    if (bytes[0] != version_major or bytes[1] != version_minor) return error.MalformedPayload;
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
    if (d.cursor != bytes.len) return error.MalformedPayload;
    return v;
}

// =============================================================================
// Encoder — a loop over an explicit stack of open containers
// =============================================================================

const Encoder = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    interner: *const Interner,
    /// The containers whose elements are still being written,
    /// innermost last.
    stack: std.ArrayList(Open) = .empty,

    const Error = EncodeError;

    /// A container being written and where its walk stands. A map
    /// yields each entry's key, then holds its value for the next
    /// step.
    const Open = union(enum) {
        list: list_mod.Cursor,
        /// A lazy seq, counted before it opened: every block of it is
        /// realized and nothing runs in between.
        lazy: lazy_mod.Cursor,
        vector: vector_mod.Cursor,
        map: Pairs(champ.MapIter),
        set: champ.SetIter,
        sorted_map: Pairs(sorted.Cursor),
        sorted_set: sorted.Cursor,

        fn next(o: *Open) ?Value {
            return switch (o.*) {
                .list => |*c| c.next(),
                .lazy => |*c| c.next() catch unreachable,
                .vector => |*c| c.next(),
                .set => |*it| it.next(),
                .sorted_set => |*c| if (c.next()) |e| e.key else null,
                .map => |*m| m.next(),
                .sorted_map => |*m| m.next(),
            };
        }
    };

    /// The entries of `It` as key, value, key, value, ...
    fn Pairs(comptime It: type) type {
        return struct {
            it: It,
            value: ?Value = null,

            fn next(p: *@This()) ?Value {
                if (p.value) |v| {
                    p.value = null;
                    return v;
                }
                const e = p.it.next() orelse return null;
                p.value = e.value;
                return e.key;
            }
        };
    }

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
                // Written as the list it realized to; it decodes as one.
                .lazy_seq => {
                    var n: usize = 0;
                    var c = lazy_mod.Cursor.init(v);
                    while (try c.next()) |_| n += 1;
                    try e.header(.list, n);
                    try e.stack.append(e.allocator, .{ .lazy = lazy_mod.Cursor.init(v) });
                },
                .persistent_vector => {
                    try e.header(.persistent_vector, vector_mod.count(v));
                    try e.stack.append(e.allocator, .{ .vector = vector_mod.Cursor.init(v) });
                },
                .persistent_map => {
                    try e.header(.persistent_map, champ.mapCount(v));
                    try e.stack.append(e.allocator, .{ .map = .{ .it = champ.mapIter(v) } });
                },
                .persistent_set => {
                    try e.header(.persistent_set, champ.setCount(v));
                    try e.stack.append(e.allocator, .{ .set = champ.setIter(v) });
                },
                // Only the natural order can be named in bytes; a
                // comparator is code (CODEC.md §2.8).
                .sorted_map, .sorted_set => {
                    if (!sorted.comparatorOf(v).isNil()) return error.UnserializableKind;
                    try e.header(v.kind(), sorted.count(v));
                    try e.stack.append(e.allocator, if (v.kind() == .sorted_map)
                        .{ .sorted_map = .{ .it = sorted.Cursor.init(v) } }
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

    inline fn header(e: *Encoder, k: Kind, n: usize) Error!void {
        try e.byte(@backingInt(k));
        try e.uleb(n);
    }

    fn leaf(e: *Encoder, v: Value) Error!void {
        const k = v.kind();
        switch (k) {
            .nil, .false_, .true_ => try e.byte(@backingInt(k)),
            .char => {
                try e.byte(@backingInt(k));
                try writeU32Le(&e.buf, e.allocator, @as(u32, v.asChar()));
            },
            .fixnum => {
                try e.byte(@backingInt(k));
                try writeIleb128Zigzag(&e.buf, e.allocator, v.asFixnum());
            },
            .float => {
                try e.byte(@backingInt(k));
                try writeU64Le(&e.buf, e.allocator, @bitCast(hash_mod.canonicalizeFloat(v.asFloat())));
            },
            .inst => {
                try e.byte(@backingInt(k));
                try writeIleb128Zigzag(&e.buf, e.allocator, v.asInstMs());
            },
            .uuid => {
                try e.byte(@backingInt(k));
                try e.buf.appendSlice(e.allocator, uuid.bytesOf(v));
            },
            .keyword => try e.named(k, e.interner.keywordName(v.asKeywordId())),
            .symbol => try e.named(k, e.interner.symbolName(v.asSymbolId())),
            .string => try e.named(k, string.asBytes(v)),
            .bignum => {
                try e.byte(@backingInt(k));
                try e.byte(@intFromBool(bignum.isNegative(v)));
                const limbs = bignum.limbs(v);
                try e.uleb(limbs.len);
                for (limbs) |limb| try writeU64Le(&e.buf, e.allocator, limb);
            },
            // `[23] [elem tag] [count] [u64 LE × count]`: i64 as two's
            // complement bits, f64 as canonical IEEE bits (CODEC.md §2).
            .typed_vector => {
                try e.byte(@backingInt(k));
                const elem = typed_vector.elemType(v);
                try e.byte(@backingInt(elem));
                try e.uleb(typed_vector.count(v));
                switch (elem) {
                    .i64 => for (typed_vector.i64Elems(v)) |x| try writeU64Le(&e.buf, e.allocator, @bitCast(x)),
                    .f64 => for (typed_vector.f64Elems(v)) |x| try writeU64Le(&e.buf, e.allocator, @bitCast(hash_mod.canonicalizeFloat(x))),
                }
            },
            // Every other kind is outside the serializable set
            // (CODEC.md §3): identity-valued, mutable or process-local.
            else => return error.UnserializableKind,
        }
    }

    inline fn byte(e: *Encoder, b: u8) Error!void {
        try e.buf.append(e.allocator, b);
    }

    inline fn uleb(e: *Encoder, n: usize) Error!void {
        try writeUleb128(&e.buf, e.allocator, n);
    }

    inline fn named(e: *Encoder, k: Kind, bytes: []const u8) Error!void {
        try e.byte(@backingInt(k));
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
                @backingInt(Kind.list), @backingInt(Kind.persistent_vector), @backingInt(Kind.persistent_set), @backingInt(Kind.sorted_set) => try d.open(tag, try d.count(1)),
                @backingInt(Kind.persistent_map), @backingInt(Kind.sorted_map) => try d.open(tag, 2 * try d.count(2)),
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
            // Built as a built sequence is (LIST.md §1); a view
            // encodes as a list.
            @backingInt(Kind.list) => return list_mod.build(d.heap, elems) catch |e| switch (e) {
                // Built from a slice, it ends in the empty list.
                error.InvalidListTail => unreachable,
                else => |other| other,
            },
            @backingInt(Kind.persistent_vector) => return vector_mod.fromSlice(d.heap, elems),
            @backingInt(Kind.sorted_map), @backingInt(Kind.sorted_set) => return d.sortedFrom(@fromBackingInt(@intCast(tag)), elems),
            // A trie hashes every key, so past an array form's size the
            // bulk builder, which allocates each node once, hashes no
            // more than a fold of `assoc` would; an array form hashes
            // no key, so a key nested too deeply to hash still decodes.
            @backingInt(Kind.persistent_map) => {
                const n = elems.len / 2;
                var m = try champ.mapEmpty(d.heap);
                if (n > champ.array_map_max) {
                    const entries: [*]const champ.Entry = @ptrCast(elems.ptr);
                    m = try champ.mapFromEntries(d.heap, entries[0..n], d.elementHash, d.elementEq);
                } else {
                    var i: usize = 0;
                    while (i < elems.len) : (i += 2) m = try champ.mapAssoc(d.heap, m, elems[i], elems[i + 1], d.elementHash, d.elementEq);
                }
                if (champ.mapCount(m) != n) return error.MalformedPayload;
                return m;
            },
            else => {
                var s = try champ.setEmpty(d.heap);
                if (elems.len > champ.array_map_max) {
                    s = try champ.setFromElements(d.heap, elems, d.elementHash, d.elementEq);
                } else {
                    for (elems) |x| s = try champ.setConj(d.heap, s, x, d.elementHash, d.elementEq);
                }
                if (champ.setCount(s) != elems.len) return error.MalformedPayload;
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
            const o = order.order(a.key, b.key) catch return error.MalformedPayload;
            if (o != .lt) return error.MalformedPayload;
        };
        return sorted.fromSortedEntries(d.heap, kind, value.nilValue(), entries);
    }

    fn leaf(d: *Decoder, tag: u8) DecodeError!Value {
        const bytes = d.bytes;
        const cursor = &d.cursor;
        return switch (tag) {
            @backingInt(Kind.nil) => value.nilValue(),
            @backingInt(Kind.false_) => value.fromBool(false),
            @backingInt(Kind.true_) => value.fromBool(true),
            @backingInt(Kind.char) => value.fromChar(std.math.cast(u21, try readU32Le(bytes, cursor)) orelse
                return error.MalformedPayload) orelse error.MalformedPayload,
            // A fixnum kind byte over a number outside i48 is malformed
            // rather than promoted: the kind byte is authoritative.
            @backingInt(Kind.fixnum) => value.fromFixnum(try readIleb128Zigzag(bytes, cursor)) orelse error.MalformedPayload,
            @backingInt(Kind.float) => value.fromFloat(@bitCast(try readU64Le(bytes, cursor))),
            // Every i64 is an instant.
            @backingInt(Kind.inst) => value.fromInst(try readIleb128Zigzag(bytes, cursor)),
            @backingInt(Kind.uuid) => uuid.make(d.heap, (try readBytes(bytes, cursor, 16))[0..16].*),
            @backingInt(Kind.keyword) => d.interner.internKeywordValue(try readBytes(bytes, cursor, try d.count(1))),
            @backingInt(Kind.symbol) => d.interner.internSymbolValue(try readBytes(bytes, cursor, try d.count(1))),
            @backingInt(Kind.string) => string.fromBytes(d.heap, try readBytes(bytes, cursor, try d.count(1))),
            @backingInt(Kind.bignum) => blk: {
                const sign = try readByte(bytes, cursor);
                if (sign > 1) return error.MalformedPayload;
                const limbs = try d.heap.backing.alloc(u64, try d.count(8));
                defer d.heap.backing.free(limbs);
                for (limbs) |*slot| slot.* = try readU64Le(bytes, cursor);
                // `fromLimbs` canonicalizes (CODEC.md §2.6).
                break :blk bignum.fromLimbs(d.heap, sign == 1, limbs);
            },
            @backingInt(Kind.typed_vector) => blk: {
                const elem = typed_vector.ElemType.fromTag(try readByte(bytes, cursor)) orelse return error.MalformedPayload;
                const n = try d.count(8);
                break :blk typed_vector.fromLeBytes(d.heap, elem, try readBytes(bytes, cursor, n * 8));
            },
            // A kind outside the serializable set (CODEC.md §3), or a
            // byte that names no kind: no encoder writes either.
            else => error.MalformedPayload,
        };
    }

    /// A length or count read from the input. Each unit it counts
    /// takes at least `min_bytes` bytes of what remains, so a count
    /// past that is `TruncatedInput` here, before anything is
    /// allocated for it.
    fn count(d: *Decoder, min_bytes: usize) DecodeError!usize {
        const n = try readUleb128(d.bytes, &d.cursor);
        if (n > (d.bytes.len - d.cursor) / min_bytes) return error.TruncatedInput;
        return @intCast(n);
    }
};

// =============================================================================
// Inline tests
// =============================================================================

// ---- Synthetic callbacks ----

const synthHash = Value.hashImmediate;
const synthEq = value.testEqual;

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
        var buf: std.ArrayList(u8) = .empty;
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
        var buf: std.ArrayList(u8) = .empty;
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
    try testing.expectError(error.TruncatedInput, readUleb128(&bytes, &cursor));
}

test "LEB128 unsigned: past u64 is MalformedPayload" {
    // Eleven bytes, and ten whose last carries more than bit 63.
    var too_long: [11]u8 = @splat(0x80);
    too_long[10] = 0;
    var too_wide: [10]u8 = @splat(0xFF);
    too_wide[9] = 0x02;
    for ([_][]const u8{ &too_long, &too_wide }) |bytes| {
        var cursor: usize = 0;
        try testing.expectError(error.MalformedPayload, readUleb128(bytes, &cursor));
    }
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

test "roundtrip: an instant across the i64 range, byte for byte" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    for ([_]i64{ std.math.minInt(i64), -1, 0, 1, 1_791_541_815_123, std.math.maxInt(i64) }) |ms| {
        const got = try ctx.roundtrip(value.fromInst(ms));
        try testing.expect(got.identicalTo(value.fromInst(ms)));
    }
    // `[8]` and the zigzag LEB128 of the milliseconds.
    const bytes = try encode(testing.allocator, &ctx.interner, value.fromInst(-1));
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 8, 1 }, bytes);
    // An eleven-byte LEB128 is no i64.
    try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &.{ 1, 0, 8, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0 }, &synthHash, &synthEq));
}

test "roundtrip: a uuid is its kind byte and 16 bytes; fewer is TruncatedInput" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const u = [16]u8{ 0xff, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0xee };
    const v = try uuid.make(&ctx.heap, u);
    const bytes = try encode(testing.allocator, &ctx.interner, v);
    defer testing.allocator.free(bytes);
    try testing.expectEqualSlices(u8, &([_]u8{ 1, 0, 46 } ++ u), bytes);
    const got = try decode(&ctx.heap, &ctx.interner, bytes, &synthHash, &synthEq);
    try testing.expect(got.kind() == .uuid);
    try testing.expectEqualSlices(u8, &u, uuid.bytesOf(got));
    try testing.expectError(error.TruncatedInput, decode(&ctx.heap, &ctx.interner, bytes[0 .. bytes.len - 1], &synthHash, &synthEq));
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.append(testing.allocator, version_major);
    try buf.append(testing.allocator, version_minor);
    try buf.append(testing.allocator, @backingInt(Kind.bignum));
    try buf.append(testing.allocator, 0); // sign: non-negative
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

test "a realized lazy seq encodes byte for byte as the list of its elements; an unrealized one is Unrealized" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const items = [_]Value{ value.fromFixnum(1).?, value.fromFixnum(2).?, value.fromFixnum(3).? };
    const as_list = try list_mod.fromSlice(&ctx.heap, &items);
    const cc = try lazy_mod.chunkedOf(&ctx.heap, items[1..], value.nilValue());
    const lz = try lazy_mod.realizedWithMeta(&ctx.heap, try lazy_mod.cons(&ctx.heap, items[0], cc), null);
    const want = try encode(testing.allocator, &ctx.interner, as_list);
    defer testing.allocator.free(want);
    const got = try encode(testing.allocator, &ctx.interner, lz);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, want, got);
    const back = try decode(&ctx.heap, &ctx.interner, got, &synthHash, &synthEq);
    try testing.expect(back.kind() == .list);
    try testing.expectEqual(@as(usize, 3), list_mod.count(back));
    const pending = try lazy_mod.unrealized(&ctx.heap, 0, &.{value.nilValue()});
    try testing.expectError(error.Unrealized, encode(testing.allocator, &ctx.interner, try lazy_mod.cons(&ctx.heap, items[0], pending)));
}

test "a pattern and a matcher are unserializable" {
    const regex = @import("regex.zig");
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const p = (try regex.make(&ctx.heap, testing.allocator, "a+")).ok;
    const m = try regex.makeMatcher(&ctx.heap, p, try string.fromBytes(&ctx.heap, "aa"));
    try testing.expectError(error.UnserializableKind, encode(testing.allocator, &ctx.interner, p));
    try testing.expectError(error.UnserializableKind, encode(testing.allocator, &ctx.interner, m));
}

test "decode: a list of four or more elements is a view of a vector, and encodes as it was" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    for ([_]usize{ 3, 4, 40 }) |n| {
        var elems: [40]Value = undefined;
        for (elems[0..n], 0..) |*slot, i| slot.* = value.fromFixnum(@intCast(i)).?;
        const src = try list_mod.fromSlice(&ctx.heap, elems[0..n]);
        const got = try ctx.roundtrip(src);
        try testing.expectEqual(n >= 4, got.subkind() == list_mod.subkind_view);
        try testing.expectEqual(n, list_mod.count(got));
        try testing.expectEqual(@as(i64, @intCast(n - 1)), list_mod.head(list_mod.drop(got, n - 1)).asFixnum());
        try testing.expectEqual(list_mod.hashSeq(src, &synthHash), list_mod.hashSeq(got, &synthHash));
        const again = try ctx.roundtrip(got);
        try testing.expectEqual(n, list_mod.count(again));
    }
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
        const name = try std.mem.print(&buf, "k{d}", .{i});
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
        const name = try std.mem.print(&buf, "s{d}", .{i});
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
    try testing.expectEqual(@as(u8, @backingInt(Kind.typed_vector)), b1[2]);
    try testing.expectEqual(@as(u8, 3), b1[3]);
    try testing.expectEqual(@as(u8, 4), b1[4]);
}

test "decode: typed vector with an unknown element tag → MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const bytes = [_]u8{ 1, 0, @backingInt(Kind.typed_vector), 2, 0 };
    try testing.expectError(
        error.MalformedPayload,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
}

test "decode: bignum whose limb count exceeds the input → TruncatedInput without allocating" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // Non-negative sign, limb count 2^56, one limb of input behind it.
    const bytes = [_]u8{ 1, 0, @backingInt(Kind.bignum), 0, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(
        error.TruncatedInput,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
    try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
}

test "decode: typed vector whose count exceeds the input → TruncatedInput without allocating" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // Count 2^56 with eight bytes of elements behind it.
    const bytes = [_]u8{ 1, 0, @backingInt(Kind.typed_vector), 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(
        error.TruncatedInput,
        decode(&ctx.heap, &ctx.interner, &bytes, &synthHash, &synthEq),
    );
    try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
}

// ---- Hostile input: lengths, counts and depth come from the bytes ----

/// `[1 0] [kind] [uleb n] [rest]`, into `buf`.
fn hostile(buf: *std.ArrayList(u8), kind: u8, n: u64, rest: []const u8) ![]const u8 {
    try buf.append(testing.allocator, version_major);
    try buf.append(testing.allocator, version_minor);
    try buf.append(testing.allocator, kind);
    try writeUleb128(buf, testing.allocator, n);
    try buf.appendSlice(testing.allocator, rest);
    return buf.items;
}

test "decode: a length near 2^64 is TruncatedInput, not an overflow" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    // An interned name first, so a wrapped bounds check would hash
    // the bogus slice.
    _ = try ctx.interner.internKeywordValue("k");
    for ([_]u8{ @backingInt(Kind.string), @backingInt(Kind.keyword), @backingInt(Kind.symbol) }) |kind| {
        for ([_]u64{ std.math.maxInt(u64), std.math.maxInt(u64) - 7, std.math.maxInt(u64) - 2 }) |len| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(testing.allocator);
            const bytes = try hostile(&buf, kind, len, "abc");
            try testing.expectError(error.TruncatedInput, decode(&ctx.heap, &ctx.interner, bytes, &synthHash, &synthEq));
        }
    }
}

test "decode: a bignum or typed-vector count near 2^64 is TruncatedInput" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    for ([_]u64{ std.math.maxInt(u64) / 8, std.math.maxInt(u64) / 8 - 1, std.math.maxInt(u64) }) |n| {
        var b1: std.ArrayList(u8) = .empty;
        defer b1.deinit(testing.allocator);
        try b1.append(testing.allocator, version_major);
        try b1.append(testing.allocator, version_minor);
        try b1.append(testing.allocator, @backingInt(Kind.bignum));
        try b1.append(testing.allocator, 0);
        try writeUleb128(&b1, testing.allocator, n);
        try writeU64Le(&b1, testing.allocator, 1);
        try testing.expectError(error.TruncatedInput, decode(&ctx.heap, &ctx.interner, b1.items, &synthHash, &synthEq));

        var b2: std.ArrayList(u8) = .empty;
        defer b2.deinit(testing.allocator);
        try b2.append(testing.allocator, version_major);
        try b2.append(testing.allocator, version_minor);
        try b2.append(testing.allocator, @backingInt(Kind.typed_vector));
        try b2.append(testing.allocator, 1);
        try writeUleb128(&b2, testing.allocator, n);
        try writeU64Le(&b2, testing.allocator, 1);
        try testing.expectError(error.TruncatedInput, decode(&ctx.heap, &ctx.interner, b2.items, &synthHash, &synthEq));
    }
    try testing.expectEqual(@as(usize, 0), ctx.heap.liveCount());
}

test "decode: a collection count past the input is TruncatedInput before any allocation" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const kinds = [_]Kind{ .list, .persistent_vector, .persistent_map, .persistent_set };
    for (kinds) |kind| {
        for ([_]u64{ 1 << 35, std.math.maxInt(u64), 3 }) |n| {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(testing.allocator);
            // Two nils: fewer bytes than three map entries, and than
            // any count of 3 or more elements.
            const bytes = try hostile(&buf, @backingInt(kind), n, &.{ 0, 0 });
            try testing.expectError(error.TruncatedInput, decode(&ctx.heap, &ctx.interner, bytes, &synthHash, &synthEq));
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
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try buf.append(testing.allocator, version_major);
        try buf.append(testing.allocator, version_minor);
        // One-element containers around a nil; a map's one entry is
        // `nil` to the next level.
        for (0..depth) |_| {
            try buf.append(testing.allocator, @backingInt(kind));
            try buf.append(testing.allocator, 1);
            if (kind == .persistent_map) try buf.append(testing.allocator, 0);
        }
        try buf.append(testing.allocator, 0);
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
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try buf.append(testing.allocator, version_major);
        try buf.append(testing.allocator, version_minor);
        // 1000 levels each claiming 3000 elements, then 2000 nils:
        // every level but the deepest few passes the count check.
        for (0..1000) |_| {
            try buf.append(testing.allocator, @backingInt(kind));
            try writeUleb128(&buf, testing.allocator, 3000);
        }
        try buf.appendNTimes(testing.allocator, @backingInt(Kind.nil), 2000);
        try testing.expectError(error.TruncatedInput, decode(&heap, &interner, buf.items, &synthHash, &synthEq));
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
    const map_bytes = [_]u8{ 1, 0, @backingInt(Kind.persistent_map), 2, 4, 2, 4, 2, 4, 2, 4, 4 };
    try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &map_bytes, &synthHash, &synthEq));
    // #{1 1}.
    const set_bytes = [_]u8{ 1, 0, @backingInt(Kind.persistent_set), 2, 4, 2, 4, 2 };
    try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &set_bytes, &synthHash, &synthEq));
}

test "decode: every kind byte outside the serializable set is MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const serializable = [_]Kind{ .nil, .false_, .true_, .char, .fixnum, .float, .inst, .keyword, .symbol, .string, .bignum, .uuid, .persistent_map, .persistent_set, .persistent_vector, .list, .typed_vector, .sorted_map, .sorted_set };
    for (0..256) |b| {
        const byte: u8 = @intCast(b);
        if (std.mem.findScalar(Kind, &serializable, @fromBackingInt(byte)) != null) continue;
        try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &.{ 1, 0, byte }, &synthHash, &synthEq));
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
    try testing.expectEqualSlices(u8, &.{ 1, 0, @backingInt(Kind.sorted_map), 5, @backingInt(Kind.keyword), 5, 'a', 'p', 'p', 'l', 'e' }, bytes[0..11]);
}

test "encode: a sorted collection with a comparator of its own is unserializable" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const by = value.fromNativeFnPtr(&ctx);
    try testing.expectError(error.UnserializableKind, encode(testing.allocator, &ctx.interner, try sorted.empty(&ctx.heap, .sorted_map, by)));
    try testing.expectError(error.UnserializableKind, encode(testing.allocator, &ctx.interner, try sorted.empty(&ctx.heap, .sorted_set, by)));
}

test "decode: sorted entries out of order, repeated or without an order are MalformedPayload" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const map_tag = @backingInt(Kind.sorted_map);
    const set_tag = @backingInt(Kind.sorted_set);
    const fixnum = @backingInt(Kind.fixnum);
    // {2 0, 1 0}: descending keys.
    const descending = [_]u8{ 1, 0, map_tag, 2, fixnum, 4, fixnum, 0, fixnum, 2, fixnum, 0 };
    try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &descending, &synthHash, &synthEq));
    // #{1 1}.
    const repeated = [_]u8{ 1, 0, set_tag, 2, fixnum, 2, fixnum, 2 };
    try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &repeated, &synthHash, &synthEq));
    // #{1 nil-list}: a list has no natural order.
    const unordered = [_]u8{ 1, 0, set_tag, 2, fixnum, 2, @backingInt(Kind.list), 0 };
    try testing.expectError(error.MalformedPayload, decode(&ctx.heap, &ctx.interner, &unordered, &synthHash, &synthEq));
    // One entry needs no comparison, whatever its key.
    const single = [_]u8{ 1, 0, set_tag, 1, @backingInt(Kind.list), 0 };
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
        error.UnserializableKind,
        encode(testing.allocator, &ctx.interner, t),
    );
}

test "decode: each malformed or short input fails with its error" {
    var ctx = TestCtx.init();
    defer ctx.deinit();
    const nil = @backingInt(Kind.nil);
    const cases = [_]struct { []const u8, DecodeError }{
        .{ &.{ 2, 0, nil }, error.MalformedPayload }, // major version
        .{ &.{ 1, 5, nil }, error.MalformedPayload }, // minor version
        .{ &.{1}, error.TruncatedInput }, // envelope
        .{ &.{ 1, 0, nil, 0xFF }, error.MalformedPayload }, // trailing bytes
        .{ &.{ 1, 0, @backingInt(Kind.bignum), 7, 0 }, error.MalformedPayload }, // sign byte
        .{ &.{ 1, 0, @backingInt(Kind.char), 0x00, 0xD8, 0x00, 0x00 }, error.MalformedPayload }, // surrogate
        .{ &.{ 1, 0, @backingInt(Kind.char), 0x00, 0x00, 0x11, 0x00 }, error.MalformedPayload }, // past U+10FFFF
        .{ &.{ 1, 0, @backingInt(Kind.string), 5, 'a', 'b', 'c' }, error.TruncatedInput }, // mid-string
    };
    for (cases) |c| try testing.expectError(c[1], decode(&ctx.heap, &ctx.interner, c[0], &synthHash, &synthEq));
}
