//! test/prop/typed_vector.zig — randomized properties for the typed
//! vector heap kind (`docs/TYPED_VECTOR.md` §7).
//!
//! Properties:
//!   T1. Codec round trip for both element types at lengths 0, 1, 31,
//!       32, 33 and 1000 with random elements including the i64
//!       extremes, `-0.0`, the infinities and NaN:
//!       `dispatch.equal(v, decode(encode(v)))`, equal `hashValue`,
//!       and `encode(v) == encode(decode(encode(v)))` byte for byte.
//!   T2. Equality and hash agree: two vectors built from the same
//!       elements in distinct allocations are `=` and hash alike;
//!       one changed element, a different length, or the other
//!       element type breaks `=`.
//!   T3. A typed vector is never `=` to the persistent vector of the
//!       same numbers, and their hashes differ.
//!   T4. `nth` reads back every element and fails with
//!       `IndexOutOfBounds` at `count` and beyond.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const hash_mod = @import("hash");
const intern_mod = @import("intern");
const bignum = @import("bignum");
const vector_mod = @import("vector");
const typed_vector = @import("typed_vector");
const codec = @import("codec");
const dispatch = @import("dispatch");

const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;

const prng_seed: u64 = 0x7479_7065_645F_7670; // "typed_vp" ASCII LE

const lengths = [_]usize{ 0, 1, 31, 32, 33, 1000 };

fn randI64(r: std.Random) i64 {
    return switch (r.uintLessThan(u8, 8)) {
        0 => std.math.maxInt(i64),
        1 => std.math.minInt(i64),
        2 => value.fixnum_max + 1,
        3 => value.fixnum_min - 1,
        4 => 0,
        else => r.int(i64),
    };
}

fn randF64(r: std.Random) f64 {
    return switch (r.uintLessThan(u8, 8)) {
        0 => -0.0,
        1 => 0.0,
        2 => std.math.inf(f64),
        3 => -std.math.inf(f64),
        4 => std.math.nan(f64),
        5 => @bitCast(r.int(u64)),
        else => (r.float(f64) - 0.5) * 1e6,
    };
}

const Ctx = struct {
    heap: Heap,
    interner: Interner,

    fn init() Ctx {
        return .{
            .heap = Heap.init(std.testing.allocator),
            .interner = Interner.init(std.testing.allocator),
        };
    }

    fn deinit(self: *Ctx) void {
        self.heap.deinit();
        self.interner.deinit();
    }

    fn randI64Vector(self: *Ctx, r: std.Random, len: usize) !Value {
        const elems = try std.testing.allocator.alloc(i64, len);
        defer std.testing.allocator.free(elems);
        for (elems) |*slot| slot.* = randI64(r);
        return try typed_vector.fromI64Slice(&self.heap, elems);
    }

    fn randF64Vector(self: *Ctx, r: std.Random, len: usize) !Value {
        const elems = try std.testing.allocator.alloc(f64, len);
        defer std.testing.allocator.free(elems);
        for (elems) |*slot| slot.* = randF64(r);
        return try typed_vector.fromF64Slice(&self.heap, elems);
    }

    fn roundtrip(self: *Ctx, v: Value) !Value {
        const bytes = try codec.encode(std.testing.allocator, &self.interner, v);
        defer std.testing.allocator.free(bytes);
        const got = try codec.decode(&self.heap, &self.interner, bytes, &dispatch.hashValue, &dispatch.equal);
        const again = try codec.encode(std.testing.allocator, &self.interner, got);
        defer std.testing.allocator.free(again);
        try std.testing.expectEqualSlices(u8, bytes, again);
        return got;
    }
};

/// A copy of `v` in a fresh allocation.
fn copyOf(ctx: *Ctx, v: Value) !Value {
    return switch (typed_vector.elemType(v)) {
        .i64 => try typed_vector.fromI64Slice(&ctx.heap, typed_vector.i64Elems(v)),
        .f64 => try typed_vector.fromF64Slice(&ctx.heap, typed_vector.f64Elems(v)),
    };
}

// -----------------------------------------------------------------------------
// T1. Codec round trip
// -----------------------------------------------------------------------------

test "T1: codec round trip for both element types at the pinned lengths" {
    var ctx = Ctx.init();
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const r = prng.random();

    for (lengths) |len| {
        var round: usize = 0;
        while (round < 20) : (round += 1) {
            const iv = try ctx.randI64Vector(r, len);
            const gi = try ctx.roundtrip(iv);
            try std.testing.expect(gi.kind() == .typed_vector);
            try std.testing.expectEqual(typed_vector.ElemType.i64, typed_vector.elemType(gi));
            try std.testing.expectEqual(len, typed_vector.count(gi));
            try std.testing.expect(dispatch.equal(iv, gi));
            try std.testing.expectEqual(dispatch.hashValue(iv), dispatch.hashValue(gi));
            try std.testing.expectEqualSlices(i64, typed_vector.i64Elems(iv), typed_vector.i64Elems(gi));

            const fv = try ctx.randF64Vector(r, len);
            const gf = try ctx.roundtrip(fv);
            try std.testing.expectEqual(typed_vector.ElemType.f64, typed_vector.elemType(gf));
            try std.testing.expectEqual(len, typed_vector.count(gf));
            try std.testing.expect(dispatch.equal(fv, gf));
            try std.testing.expectEqual(dispatch.hashValue(fv), dispatch.hashValue(gf));
            // Bit-exact: `-0.0` survives, NaN is the canonical pattern.
            const src_bits: []const u64 = @ptrCast(typed_vector.f64Elems(fv));
            const got_bits: []const u64 = @ptrCast(typed_vector.f64Elems(gf));
            try std.testing.expectEqualSlices(u64, src_bits, got_bits);
        }
    }
}

// -----------------------------------------------------------------------------
// T2. Equality and hash agreement
// -----------------------------------------------------------------------------

test "T2: same elements are = and hash alike; a changed element, length or type breaks =" {
    var ctx = Ctx.init();
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 500) : (trial += 1) {
        const len = r.uintLessThan(usize, 40);
        const a = if (r.boolean()) try ctx.randI64Vector(r, len) else try ctx.randF64Vector(r, len);
        const b = try copyOf(&ctx, a);
        try std.testing.expect(dispatch.equal(a, a));
        try std.testing.expect(dispatch.equal(a, b));
        try std.testing.expect(dispatch.equal(b, a));
        try std.testing.expectEqual(dispatch.hashValue(a), dispatch.hashValue(b));

        // The other element type with the same numeric content.
        const other = switch (typed_vector.elemType(a)) {
            .i64 => blk: {
                const xs = try std.testing.allocator.alloc(f64, len);
                defer std.testing.allocator.free(xs);
                for (xs, typed_vector.i64Elems(a)) |*slot, x| slot.* = @floatFromInt(x);
                break :blk try typed_vector.fromF64Slice(&ctx.heap, xs);
            },
            .f64 => blk: {
                const xs = try std.testing.allocator.alloc(i64, len);
                defer std.testing.allocator.free(xs);
                for (xs, typed_vector.f64Elems(a)) |*slot, x| slot.* = if (std.math.isFinite(x)) @intFromFloat(@trunc(@min(@max(x, -1e15), 1e15))) else 0;
                break :blk try typed_vector.fromI64Slice(&ctx.heap, xs);
            },
        };
        try std.testing.expect(!dispatch.equal(a, other));
        try std.testing.expect(!dispatch.equal(other, a));

        if (len == 0) continue;

        // One element changed.
        const at = r.uintLessThan(usize, len);
        const changed = switch (typed_vector.elemType(a)) {
            .i64 => blk: {
                const xs = try std.testing.allocator.dupe(i64, typed_vector.i64Elems(a));
                defer std.testing.allocator.free(xs);
                xs[at] = if (xs[at] == std.math.maxInt(i64)) xs[at] - 1 else xs[at] + 1;
                break :blk try typed_vector.fromI64Slice(&ctx.heap, xs);
            },
            .f64 => blk: {
                const xs = try std.testing.allocator.dupe(f64, typed_vector.f64Elems(a));
                defer std.testing.allocator.free(xs);
                // Not `+ 1.0`: a large magnitude absorbs it.
                xs[at] = if (xs[at] == 1.0) 2.0 else 1.0;
                break :blk try typed_vector.fromF64Slice(&ctx.heap, xs);
            },
        };
        try std.testing.expect(!dispatch.equal(a, changed));

        // A prefix.
        const shorter = switch (typed_vector.elemType(a)) {
            .i64 => try typed_vector.fromI64Slice(&ctx.heap, typed_vector.i64Elems(a)[0 .. len - 1]),
            .f64 => try typed_vector.fromF64Slice(&ctx.heap, typed_vector.f64Elems(a)[0 .. len - 1]),
        };
        try std.testing.expect(!dispatch.equal(a, shorter));
        try std.testing.expect(!dispatch.equal(shorter, a));
    }
}

test "T2b: signed zero and NaN: = folds -0.0 and +0.0, NaN is reflexive, hashes agree" {
    var ctx = Ctx.init();
    defer ctx.deinit();
    const pos = try typed_vector.fromF64Slice(&ctx.heap, &.{ 0.0, std.math.nan(f64), 1.0 });
    const neg = try typed_vector.fromF64Slice(&ctx.heap, &.{ -0.0, std.math.nan(f64), 1.0 });
    try std.testing.expect(dispatch.equal(pos, neg));
    try std.testing.expectEqual(dispatch.hashValue(pos), dispatch.hashValue(neg));
}

// -----------------------------------------------------------------------------
// T3. Never equal to a persistent vector
// -----------------------------------------------------------------------------

test "T3: a typed vector is never = to the persistent vector of the same numbers; hashes differ" {
    var ctx = Ctx.init();
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const r = prng.random();

    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const len = r.uintLessThan(usize, 20);
        const elems = try std.testing.allocator.alloc(Value, len);
        defer std.testing.allocator.free(elems);

        const tv = if (r.boolean()) blk: {
            const xs = try std.testing.allocator.alloc(i64, len);
            defer std.testing.allocator.free(xs);
            for (xs, elems) |*slot, *e| {
                slot.* = r.intRangeAtMost(i64, -1000, 1000);
                e.* = value.fromFixnum(slot.*).?;
            }
            break :blk try typed_vector.fromI64Slice(&ctx.heap, xs);
        } else blk: {
            const xs = try std.testing.allocator.alloc(f64, len);
            defer std.testing.allocator.free(xs);
            for (xs, elems) |*slot, *e| {
                slot.* = r.float(f64);
                e.* = value.fromFloat(slot.*);
            }
            break :blk try typed_vector.fromF64Slice(&ctx.heap, xs);
        };
        const pv = try vector_mod.fromSlice(&ctx.heap, elems);

        try std.testing.expect(!dispatch.equal(tv, pv));
        try std.testing.expect(!dispatch.equal(pv, tv));
        try std.testing.expect(dispatch.hashValue(tv) != dispatch.hashValue(pv));
        try std.testing.expect(!dispatch.equal(tv, value.nilValue()));
    }
}

// -----------------------------------------------------------------------------
// T4. nth
// -----------------------------------------------------------------------------

test "T4: nth reads back every element; count and beyond are IndexOutOfBounds" {
    var ctx = Ctx.init();
    defer ctx.deinit();
    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const r = prng.random();

    for (lengths) |len| {
        const iv = try ctx.randI64Vector(r, len);
        for (typed_vector.i64Elems(iv), 0..) |x, i| {
            const got = try typed_vector.nth(&ctx.heap, iv, i);
            try std.testing.expect(got.kind() == .fixnum or got.kind() == .bignum);
            try std.testing.expectEqual(@as(?i64, x), bignum.toI64(got));
            try std.testing.expect(dispatch.equal(got, try bignum.fromI64(&ctx.heap, x)));
        }
        try std.testing.expectError(error.IndexOutOfBounds, typed_vector.nth(&ctx.heap, iv, len));
        try std.testing.expectError(error.IndexOutOfBounds, typed_vector.nth(&ctx.heap, iv, len + 1));
        try std.testing.expectError(error.IndexOutOfBounds, typed_vector.nth(&ctx.heap, iv, std.math.maxInt(usize)));

        const fv = try ctx.randF64Vector(r, len);
        for (typed_vector.f64Elems(fv), 0..) |x, i| {
            const got = try typed_vector.nth(&ctx.heap, fv, i);
            try std.testing.expect(got.kind() == .float);
            try std.testing.expectEqual(@as(u64, @bitCast(x)), got.payload);
        }
        try std.testing.expectError(error.IndexOutOfBounds, typed_vector.nth(&ctx.heap, fv, len));
    }
}
