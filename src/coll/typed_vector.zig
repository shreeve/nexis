//! coll/typed_vector.zig — typed vector heap kind.
//!
//! A typed vector is an immutable, contiguous, unboxed sequence of one
//! numeric element type: `i64` or `f64`. It is `Kind.typed_vector`
//! (23) with the element type in the Value's subkind and in the body,
//! so a header alone can be decoded. There is no trie and no tail: the
//! elements sit in one heap block after a 16-byte prefix.
//!
//! Authoritative spec: `docs/TYPED_VECTOR.md`. Semantics:
//! `docs/SEMANTICS.md` §2.6 (typed vectors are their own equality
//! category: element-wise, same element type; never equal to a
//! persistent vector) and §3.2 (kind-local hash domain). Physical
//! storage: `docs/HEAP.md`. Wire format: `docs/CODEC.md` §2.
//!
//! Surface: `fromI64Slice` / `fromF64Slice` / `count` / `elemType` /
//! `i64Elems` / `f64Elems` / `nth` / `hashHeader` / `equalHeaders` /
//! `trace` / `format`. There is no `conj`, `assoc` or `pop`: a typed
//! vector is built whole and read; every derived vector is a fresh
//! allocation made by a kernel or a constructor. `u8` elements are
//! the province of `Kind.byte_vector` (22), which has no
//! implementation; `i32` and `f32` are reserved subkinds with no
//! implementation.
//!
//! An `f64` element is stored canonical: every NaN bit pattern
//! collapses to `hash.canonical_nan_bits` at construction and at
//! decode, so element equality is `==` plus a NaN check and hashing
//! goes through `hash.hashFloat` unchanged. `-0.0` is stored as is;
//! `=` and `hash` fold it into `+0.0` as they do for a float Value.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const bignum = @import("bignum");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Element types
//
// The numbers are the subkind values VALUE.md §2.2 assigns to the
// kind: 0 = i32, 1 = i64, 2 = f32, 3 = f64. Only i64 and f64 exist.
// =============================================================================

pub const ElemType = enum(u8) {
    i64 = 1,
    f64 = 3,

    /// The tag byte's element type, or null for a byte that names no
    /// implemented element type (the codec's malformed-payload case).
    pub fn fromTag(tag: u8) ?ElemType {
        return switch (tag) {
            1 => .i64,
            3 => .f64,
            else => null,
        };
    }

    /// The name printed after `#` and returned by `typed-vector-type`.
    pub fn name(self: ElemType) []const u8 {
        return switch (self) {
            .i64 => "i64",
            .f64 => "f64",
        };
    }
};

// =============================================================================
// Body layout
// =============================================================================

/// Prefix of every typed-vector body. The elements follow at offset
/// 16, 8-byte aligned (the body starts 16-byte aligned, HEAP.md §1).
const Body = extern struct {
    len: u64,
    elem: u8,
    _pad: [7]u8,

    comptime {
        std.debug.assert(@sizeOf(Body) == 16);
        std.debug.assert(@offsetOf(Body, "len") == 0);
        std.debug.assert(@offsetOf(Body, "elem") == 8);
    }
};

const elem_size: usize = 8;

comptime {
    std.debug.assert(@sizeOf(i64) == elem_size);
    std.debug.assert(@sizeOf(f64) == elem_size);
}

fn bodyOf(h: *HeapHeader) *Body {
    if (std.debug.runtime_safety) {
        std.debug.assert(h.kind == @intFromEnum(Kind.typed_vector));
    }
    return Heap.bodyOf(Body, h);
}

fn elemBytes(h: *HeapHeader) []u8 {
    const bytes = Heap.bodyBytes(h);
    std.debug.assert(bytes.len == @sizeOf(Body) + bodyOf(h).len * elem_size);
    return bytes[@sizeOf(Body)..];
}

fn i64Slice(h: *HeapHeader) []i64 {
    const bytes = elemBytes(h);
    const ptr: [*]i64 = @ptrCast(@alignCast(bytes.ptr));
    return ptr[0 .. bytes.len / elem_size];
}

fn f64Slice(h: *HeapHeader) []f64 {
    const bytes = elemBytes(h);
    const ptr: [*]f64 = @ptrCast(@alignCast(bytes.ptr));
    return ptr[0 .. bytes.len / elem_size];
}

fn alloc(heap: *Heap, elem: ElemType, len: usize) !*HeapHeader {
    const elems_size = try std.math.mul(usize, len, elem_size);
    const body_size = try std.math.add(usize, @sizeOf(Body), elems_size);
    const h = try heap.alloc(.typed_vector, body_size);
    const body = bodyOf(h);
    body.len = len;
    body.elem = @intFromEnum(elem);
    return h;
}

fn valueFrom(h: *HeapHeader, elem: ElemType) Value {
    return .{
        .tag = @as(u64, @intFromEnum(Kind.typed_vector)) |
            (@as(u64, @intFromEnum(elem)) << 16),
        .payload = @intFromPtr(h),
    };
}

fn header(v: Value) *HeapHeader {
    std.debug.assert(v.kind() == .typed_vector);
    return Heap.asHeapHeader(v);
}

// =============================================================================
// Public API — construction
// =============================================================================

/// A typed vector of `i64` holding a copy of `elems`.
pub fn fromI64Slice(heap: *Heap, elems: []const i64) !Value {
    const h = try alloc(heap, .i64, elems.len);
    @memcpy(i64Slice(h), elems);
    return valueFrom(h, .i64);
}

/// A typed vector of `f64` holding a copy of `elems`, every NaN
/// canonicalized.
pub fn fromF64Slice(heap: *Heap, elems: []const f64) !Value {
    const h = try alloc(heap, .f64, elems.len);
    const dst = f64Slice(h);
    for (dst, elems) |*slot, x| slot.* = hash_mod.canonicalizeFloat(x);
    return valueFrom(h, .f64);
}

// =============================================================================
// Public API — accessors
// =============================================================================

/// The element type, read from the Value's subkind.
pub fn elemType(v: Value) ElemType {
    std.debug.assert(v.kind() == .typed_vector);
    return @enumFromInt(@as(u8, @intCast(v.subkind())));
}

/// The element type, read from the body.
pub fn elemTypeOf(h: *HeapHeader) ElemType {
    return @enumFromInt(bodyOf(h).elem);
}

pub fn count(v: Value) usize {
    return bodyOf(header(v)).len;
}

/// The elements of an `i64` vector. Asserts the element type.
pub fn i64Elems(v: Value) []const i64 {
    std.debug.assert(elemType(v) == .i64);
    return i64Slice(header(v));
}

/// The elements of an `f64` vector. Asserts the element type.
pub fn f64Elems(v: Value) []const f64 {
    std.debug.assert(elemType(v) == .f64);
    return f64Slice(header(v));
}

pub const NthError = error{ IndexOutOfBounds, OutOfMemory };

/// Element `i` as a Value: a float for an `f64` vector; for an `i64`
/// vector a fixnum, or a bignum when the element is outside the
/// fixnum range (which is why `nth` takes the heap).
pub fn nth(heap: *Heap, v: Value, i: usize) NthError!Value {
    const h = header(v);
    if (i >= bodyOf(h).len) return NthError.IndexOutOfBounds;
    return switch (elemTypeOf(h)) {
        .i64 => bignum.fromI64(heap, i64Slice(h)[i]) catch NthError.OutOfMemory,
        .f64 => value.fromFloat(f64Slice(h)[i]),
    };
}

// =============================================================================
// Per-kind hash + equality (called by dispatch)
// =============================================================================

/// Ordered-combine hash over the element type tag and then every
/// element: `hash.hashI64` for `i64`, `hash.hashFloat` for `f64` (so
/// `-0.0` and `+0.0` hash alike, as they compare). The pre-mix base;
/// `dispatch.hashValue` applies the kind-local domain byte. Not
/// cached: every call walks the elements.
pub fn hashHeader(h: *HeapHeader) u64 {
    const body = bodyOf(h);
    var acc: u64 = hash_mod.ordered_init;
    acc = hash_mod.combineOrdered(acc, hash_mod.hashU64(body.elem));
    switch (elemTypeOf(h)) {
        .i64 => for (i64Slice(h)) |x| {
            acc = hash_mod.combineOrdered(acc, hash_mod.hashI64(x));
        },
        .f64 => for (f64Slice(h)) |x| {
            acc = hash_mod.combineOrdered(acc, hash_mod.hashFloat(x));
        },
    }
    return hash_mod.finalizeOrdered(acc, body.len);
}

/// Structural equality: same element type, same length, every element
/// equal. `f64` elements compare as float Values do (`-0.0` equals
/// `+0.0`; the canonical NaN equals itself). A typed vector is never
/// compared with a persistent vector here: the two kinds are in
/// different equality categories and `dispatch.equal` answers false
/// before reaching any per-kind routine.
pub fn equalHeaders(a: *HeapHeader, b: *HeapHeader) bool {
    if (a == b) return true;
    const ab = bodyOf(a);
    const bb = bodyOf(b);
    if (ab.elem != bb.elem or ab.len != bb.len) return false;
    switch (elemTypeOf(a)) {
        .i64 => return std.mem.eql(i64, i64Slice(a), i64Slice(b)),
        .f64 => {
            for (f64Slice(a), f64Slice(b)) |x, y| {
                if (!(x == y or (std.math.isNan(x) and std.math.isNan(y)))) return false;
            }
            return true;
        },
    }
}

// =============================================================================
// GC trace (GC.md §5)
// =============================================================================

/// Typed vectors are leaf heap kinds: the body is unboxed numbers
/// with no heap references. Exported for uniformity.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    _ = h;
    _ = visitor;
}

// =============================================================================
// Presentation
// =============================================================================

/// `#i64[1 2 3]` / `#f64[1.0 2.0]`, the same text in both format
/// modes. `floatFn` prints one `f64` the way `src/format.zig` prints a
/// float Value, so an `f64` element and the float `nth` returns for it
/// print identically. The reader has no `#i64[` / `#f64[` dispatch:
/// the text does not read back.
pub fn format(v: Value, writer: *std.Io.Writer, floatFn: anytype) !void {
    const h = header(v);
    const elem = elemTypeOf(h);
    try writer.writeByte('#');
    try writer.writeAll(elem.name());
    try writer.writeByte('[');
    switch (elem) {
        .i64 => for (i64Slice(h), 0..) |x, i| {
            if (i > 0) try writer.writeByte(' ');
            try writer.print("{d}", .{x});
        },
        .f64 => for (f64Slice(h), 0..) |x, i| {
            if (i > 0) try writer.writeByte(' ');
            try floatFn(x, writer);
        },
    }
    try writer.writeByte(']');
}

// =============================================================================
// Inline tests
// =============================================================================

fn testFloat(f: f64, writer: *std.Io.Writer) !void {
    try writer.print("{d}", .{f});
}

test "Body prefix is 16 bytes; elements start 8-byte aligned" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromI64Slice(&heap, &.{ 1, 2, 3 });
    const h = header(v);
    try testing.expectEqual(@as(usize, 16 + 3 * 8), Heap.bodyBytes(h).len);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(i64Slice(h).ptr) % 8);
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
}

test "fromI64Slice: kind, subkind, count and elements" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromI64Slice(&heap, &.{ -1, 0, std.math.maxInt(i64), std.math.minInt(i64) });
    try testing.expect(v.kind() == .typed_vector);
    try testing.expectEqual(ElemType.i64, elemType(v));
    try testing.expectEqual(@as(u16, 1), v.subkind());
    try testing.expectEqual(@as(usize, 4), count(v));
    try testing.expectEqualSlices(i64, &.{ -1, 0, std.math.maxInt(i64), std.math.minInt(i64) }, i64Elems(v));
}

test "fromF64Slice: kind, subkind, count, elements; NaN canonicalized" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const odd_nan: f64 = @bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF));
    const v = try fromF64Slice(&heap, &.{ 1.5, -0.0, odd_nan });
    try testing.expectEqual(ElemType.f64, elemType(v));
    try testing.expectEqual(@as(u16, 3), v.subkind());
    try testing.expectEqual(@as(usize, 3), count(v));
    const xs = f64Elems(v);
    try testing.expectEqual(@as(f64, 1.5), xs[0]);
    try testing.expectEqual(@as(u64, @bitCast(@as(f64, -0.0))), @as(u64, @bitCast(xs[1])));
    try testing.expectEqual(hash_mod.canonical_nan_bits, @as(u64, @bitCast(xs[2])));
}

test "empty vectors of both types" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromI64Slice(&heap, &.{});
    const b = try fromF64Slice(&heap, &.{});
    try testing.expectEqual(@as(usize, 0), count(a));
    try testing.expectEqual(@as(usize, 0), count(b));
    try testing.expectEqual(@as(usize, 16), Heap.bodyBytes(header(a)).len);
    try testing.expectError(NthError.IndexOutOfBounds, nth(&heap, a, 0));
    try testing.expect(!equalHeaders(header(a), header(b)));
}

test "nth: fixnum, bignum promotion, float, out of bounds" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const big: i64 = value.fixnum_max + 1;
    const iv = try fromI64Slice(&heap, &.{ 7, big });
    const n0 = try nth(&heap, iv, 0);
    try testing.expect(n0.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 7), n0.asFixnum());
    const n1 = try nth(&heap, iv, 1);
    try testing.expect(n1.kind() == .bignum);
    try testing.expectEqual(@as(?i64, big), bignum.toI64(n1));
    try testing.expectError(NthError.IndexOutOfBounds, nth(&heap, iv, 2));

    const fv = try fromF64Slice(&heap, &.{2.5});
    const f0 = try nth(&heap, fv, 0);
    try testing.expect(f0.kind() == .float);
    try testing.expectEqual(@as(f64, 2.5), f0.asFloat());
    try testing.expectError(NthError.IndexOutOfBounds, nth(&heap, fv, 1));
}

test "equalHeaders: same elements equal across allocations; type, length and element differences break it" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try fromI64Slice(&heap, &.{ 1, 2, 3 });
    const b = try fromI64Slice(&heap, &.{ 1, 2, 3 });
    const c = try fromI64Slice(&heap, &.{ 1, 2 });
    const d = try fromI64Slice(&heap, &.{ 1, 2, 4 });
    const f = try fromF64Slice(&heap, &.{ 1.0, 2.0, 3.0 });
    try testing.expect(equalHeaders(header(a), header(b)));
    try testing.expect(equalHeaders(header(b), header(a)));
    try testing.expect(equalHeaders(header(a), header(a)));
    try testing.expect(!equalHeaders(header(a), header(c)));
    try testing.expect(!equalHeaders(header(a), header(d)));
    try testing.expect(!equalHeaders(header(a), header(f)));
    try testing.expectEqual(hashHeader(header(a)), hashHeader(header(b)));
    try testing.expect(hashHeader(header(a)) != hashHeader(header(f)));
}

test "equalHeaders and hashHeader: signed zero folds, canonical NaN is reflexive" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const pos = try fromF64Slice(&heap, &.{ 0.0, std.math.nan(f64) });
    const neg = try fromF64Slice(&heap, &.{ -0.0, std.math.nan(f64) });
    try testing.expect(equalHeaders(header(pos), header(neg)));
    try testing.expectEqual(hashHeader(header(pos)), hashHeader(header(neg)));
}

test "hashHeader: empty vectors of different types hash differently; length is folded in" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const ei = try fromI64Slice(&heap, &.{});
    const ef = try fromF64Slice(&heap, &.{});
    const zero = try fromI64Slice(&heap, &.{0});
    try testing.expect(hashHeader(header(ei)) != hashHeader(header(ef)));
    try testing.expect(hashHeader(header(ei)) != hashHeader(header(zero)));
}

test "format: #i64[...] and #f64[...]" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const iv = try fromI64Slice(&heap, &.{ 1, -2, 3 });
    const fv = try fromF64Slice(&heap, &.{ 1.5, 2 });
    const ev = try fromF64Slice(&heap, &.{});
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(iv, &w, testFloat);
    try testing.expectEqualStrings("#i64[1 -2 3]", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try format(fv, &w, testFloat);
    try testing.expectEqualStrings("#f64[1.5 2]", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try format(ev, &w, testFloat);
    try testing.expectEqualStrings("#f64[]", w.buffered());
}

test "ElemType.fromTag accepts only the implemented tags" {
    try testing.expectEqual(@as(?ElemType, .i64), ElemType.fromTag(1));
    try testing.expectEqual(@as(?ElemType, .f64), ElemType.fromTag(3));
    try testing.expectEqual(@as(?ElemType, null), ElemType.fromTag(0));
    try testing.expectEqual(@as(?ElemType, null), ElemType.fromTag(2));
    try testing.expectEqual(@as(?ElemType, null), ElemType.fromTag(4));
}

test "trace is a no-op: the visitor is never called" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const v = try fromI64Slice(&heap, &.{ 1, 2 });
    const Visitor = struct {
        calls: usize = 0,
        pub fn markValue(self: *@This(), _: Value) void {
            self.calls += 1;
        }
        pub fn mark(self: *@This(), _: *HeapHeader) void {
            self.calls += 1;
        }
        pub fn markInternal(self: *@This(), _: *HeapHeader) bool {
            self.calls += 1;
            return true;
        }
    };
    var visitor: Visitor = .{};
    trace(header(v), &visitor);
    try testing.expectEqual(@as(usize, 0), visitor.calls);
}
