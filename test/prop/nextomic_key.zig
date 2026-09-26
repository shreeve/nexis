//! test/prop/nextomic_key.zig — for every value type, the byte order of
//! two encodings equals the order of the two values and each decodes to
//! its value (NEXTOMIC.md §2.2), longs over all of i64 with its edges;
//! the string escape round-trips through embedded NUL; order holds across
//! the inline threshold on the 64-byte prefix; every AVET key of an
//! inline value stays under emdb's 256-byte search-clue buffer.

const std = @import("std");
const nx = @import("nexis");
const nextomic = nx.nextomic;

const key = nextomic.key;
const Val = key.Val;
const testing = std.testing;

const prng_seed: u64 = 0x6e78_6b65_795f_7000; // "nxkey_p\0"
const pairs_per_type: usize = 100_000;

/// The edges of the long range: i64's ends, the fixnum range's (±2^47)
/// and the last integers a double holds exactly (±2^53).
const long_edges = [_]i64{ std.math.minInt(i64), -(1 << 53), -(1 << 47), 0, (1 << 47) - 1, 1 << 53, std.math.maxInt(i64) };

fn randLong(rand: std.Random) i64 {
    return switch (rand.uintLessThan(u8, 5)) {
        0 => rand.int(i64),
        1 => @as(i64, rand.int(i8)),
        2 => @as(i64, rand.int(i32)),
        3 => long_edges[rand.uintLessThan(usize, long_edges.len)] +| rand.intRangeAtMost(i64, -2, 2),
        else => rand.intRangeAtMost(i64, -1000, 1000),
    };
}

fn randDouble(rand: std.Random) f64 {
    while (true) {
        const d: f64 = switch (rand.uintLessThan(u8, 6)) {
            0 => @bitCast(rand.int(u64)),
            1 => rand.float(f64) * 2000.0 - 1000.0,
            2 => @as(f64, @floatFromInt(rand.intRangeAtMost(i32, -50, 50))),
            3 => if (rand.boolean()) 0.0 else -0.0,
            4 => if (rand.boolean()) std.math.inf(f64) else -std.math.inf(f64),
            else => @bitCast(@as(u64, rand.int(u16))), // subnormals
        };
        if (!std.math.isNan(d)) return d;
    }
}

fn randBlob(rand: std.Random, buf: []u8, max: usize) []u8 {
    const n = rand.uintAtMost(usize, max);
    const s = buf[0..n];
    for (s) |*c| {
        c.* = switch (rand.uintLessThan(u8, 8)) {
            0 => 0,
            1 => 0xFF,
            2 => rand.intRangeAtMost(u8, 'a', 'c'),
            else => rand.int(u8),
        };
    }
    return s;
}

/// Every trial allocates in an arena reset per iteration: the debug
/// allocator's per-allocation bookkeeping would otherwise dominate.
const Arena = struct {
    state: std.heap.ArenaAllocator,

    fn init() Arena {
        return .{ .state = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(self: *Arena) void {
        self.state.deinit();
    }

    fn reset(self: *Arena) std.mem.Allocator {
        _ = self.state.reset(.retain_capacity);
        return self.state.allocator();
    }
};

fn expectOrdered(gpa: std.mem.Allocator, a: Val, b: Val) !void {
    const ea = try key.valBytes(gpa, a);
    const eb = try key.valBytes(gpa, b);
    const want = a.order(b);
    const got = std.mem.order(u8, ea, eb);
    if (want != got) {
        std.debug.print("order mismatch: {any} vs {any}: want {s} got {s}\n", .{ a, b, @tagName(want), @tagName(got) });
        return error.OrderMismatch;
    }
    try testing.expectEqual(want == .eq, a.eql(b));
    for ([_]Val{ a, b }, [_][]const u8{ ea, eb }) |v, e| try testing.expect((try key.decodeVal(gpa, e)).val.eql(v));
}

/// Names the failing trial of a sweep: its seed and iteration.
fn trial(seed: u64, i: usize) void {
    std.debug.print("failed at iteration {d} of seed 0x{x}\n", .{ i, seed });
}

test "K1 fixed-width types: encoding order equals value order" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 1);
    const rand = prng.random();
    var arena = Arena.init();
    defer arena.deinit();
    var i: usize = 0;
    while (i < pairs_per_type) : (i += 1) {
        errdefer trial(prng_seed +% 1, i);
        const gpa = arena.reset();
        try expectOrdered(gpa, .{ .boolean = rand.boolean() }, .{ .boolean = rand.boolean() });
        try expectOrdered(gpa, .{ .long = randLong(rand) }, .{ .long = randLong(rand) });
        try expectOrdered(gpa, .{ .instant = randLong(rand) }, .{ .instant = randLong(rand) });
        try expectOrdered(gpa, .{ .double = randDouble(rand) }, .{ .double = randDouble(rand) });
        try expectOrdered(gpa, .{ .keyword = rand.int(u32) }, .{ .keyword = rand.int(u32) });
        try expectOrdered(gpa, .{ .ref = rand.uintAtMost(u64, key.id_max) }, .{ .ref = rand.uintAtMost(u64, key.id_max) });
        var ua: [16]u8 = undefined;
        var ub: [16]u8 = undefined;
        rand.bytes(&ua);
        rand.bytes(&ub);
        if (rand.boolean()) ub[0] = ua[0];
        try expectOrdered(gpa, .{ .uuid = ua }, .{ .uuid = ub });
    }
}

test "K2 inline strings and bytes: encoding order equals byte order, escape round-trips" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 2);
    const rand = prng.random();
    var arena = Arena.init();
    defer arena.deinit();
    var ba: [key.inline_max]u8 = undefined;
    var bb: [key.inline_max]u8 = undefined;
    var i: usize = 0;
    while (i < pairs_per_type) : (i += 1) {
        errdefer trial(prng_seed +% 2, i);
        const gpa = arena.reset();
        const sa = randBlob(rand, &ba, key.inline_max);
        var sb = randBlob(rand, &bb, key.inline_max);
        // Share a prefix often so the terminator and escape rules are hit.
        if (rand.boolean()) {
            const n = @min(sa.len, sb.len);
            @memcpy(sb[0..n], sa[0..n]);
        }
        if (rand.boolean()) {
            try expectOrdered(gpa, .{ .string = sa }, .{ .string = sb });
        } else {
            try expectOrdered(gpa, .{ .bytes = sa }, .{ .bytes = sb });
        }

        const enc = try key.valBytes(gpa, .{ .string = sa });
        const dec = try key.decodeVal(gpa, enc);
        try testing.expectEqualSlices(u8, sa, dec.val.string);
        try testing.expectEqual(1 + key.escapedLen(sa), enc.len);
    }
}

test "K3 out-of-line values: digest equality, prefix order, key bound" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 3);
    const rand = prng.random();
    var arena = Arena.init();
    defer arena.deinit();
    var ba: [4096]u8 = undefined;
    var bb: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const gpa = arena.reset();
        const sa = ba[0 .. key.inline_max + 1 + rand.uintAtMost(usize, ba.len - key.inline_max - 1)];
        rand.bytes(sa);
        for (sa) |*c| if (rand.uintLessThan(u8, 8) == 0) {
            c.* = 0;
        };
        const ea = try key.valBytes(gpa, .{ .string = sa });
        try testing.expectEqual(@as(u8, @intFromEnum(key.Tag.string)), ea[0]);
        try testing.expect(ea.len <= 1 + 2 * key.prefix_len + 2 + key.hash_len);

        // Same bytes: same key. Different bytes with the same prefix: same
        // prefix section, different hash.
        const sb = bb[0..sa.len];
        @memcpy(sb, sa);
        const eb = try key.valBytes(gpa, .{ .string = sb });
        try testing.expectEqualSlices(u8, ea, eb);
        sb[sb.len - 1] +%= 1;
        const ec = try key.valBytes(gpa, .{ .string = sb });
        try testing.expect(!std.mem.eql(u8, ea, ec));
        const da = try key.decodeVal(gpa, ea);
        const dc = try key.decodeVal(gpa, ec);
        try testing.expectEqualSlices(u8, da.string_long.prefix, dc.string_long.prefix);
        try testing.expect(da.string_long.hash != dc.string_long.hash);
        try testing.expectEqual(key.hash128(sa), da.string_long.hash);
    }
}

test "K4 every AVET key of an inline value is under 256 bytes" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 4);
    const rand = prng.random();
    var arena = Arena.init();
    defer arena.deinit();
    var buf: [key.inline_max]u8 = undefined;
    var i: usize = 0;
    while (i < pairs_per_type) : (i += 1) {
        errdefer trial(prng_seed +% 4, i);
        const gpa = arena.reset();
        const v: Val = switch (rand.uintLessThan(u8, 9)) {
            0 => .{ .boolean = rand.boolean() },
            1 => .{ .long = randLong(rand) },
            2 => .{ .double = randDouble(rand) },
            3 => .{ .instant = randLong(rand) },
            4 => .{ .keyword = rand.int(u32) },
            5 => .{ .ref = rand.uintAtMost(u64, key.id_max) },
            6 => .{ .string = randBlob(rand, &buf, key.inline_max) },
            7 => .{ .uuid = [_]u8{0xAB} ** 16 },
            else => .{ .bytes = randBlob(rand, &buf, key.inline_max) },
        };
        const vb = try key.valBytes(gpa, v);
        const k = try key.keyBytes(gpa, .avet, rand.uintAtMost(u64, key.id_max), rand.int(u32), vb, .{ .t = rand.uintLessThan(u64, key.tx_partition_bit), .added = rand.boolean() });
        try testing.expect(k.len < 256);
        const parts = try key.unpackKey(.avet, true, k);
        const kv = try key.partsVal(gpa, .avet, parts);
        try testing.expect(kv.val.eql(v));
    }
    const gpa = arena.reset();
    // The worst case named in §2.2: a 96-byte string of NULs escapes to
    // 192 bytes and the AVET history key is 210 bytes.
    const worst = [_]u8{0} ** key.inline_max;
    const wb = try key.valBytes(gpa, .{ .string = &worst });
    const wk = try key.keyBytes(gpa, .avet, key.id_max, std.math.maxInt(u32), wb, .{ .t = 1, .added = true });
    try testing.expectEqual(@as(usize, 210), wk.len);
}

test "K6 values of different types order by type, whatever their contents" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 6);
    const rand = prng.random();
    var arena = Arena.init();
    defer arena.deinit();
    var ba: [key.inline_max]u8 = undefined;
    var bb: [key.inline_max]u8 = undefined;
    var i: usize = 0;
    while (i < pairs_per_type) : (i += 1) {
        errdefer trial(prng_seed +% 6, i);
        const gpa = arena.reset();
        const a = randVal(rand, &ba);
        const b = randVal(rand, &bb);
        if (a.valueType() == b.valueType()) continue;
        const want = std.math.order(@intFromEnum(a.valueType()), @intFromEnum(b.valueType()));
        const ea = try key.valBytes(gpa, a);
        const eb = try key.valBytes(gpa, b);
        try testing.expectEqual(want, std.mem.order(u8, ea, eb));
        try testing.expect(!a.eql(b));
    }
}

/// A value of a random type; strings and bytes are inline.
fn randVal(rand: std.Random, buf: []u8) Val {
    return switch (rand.uintLessThan(u8, 9)) {
        0 => .{ .boolean = rand.boolean() },
        1 => .{ .long = randLong(rand) },
        2 => .{ .double = randDouble(rand) },
        3 => .{ .instant = randLong(rand) },
        4 => .{ .keyword = rand.int(u32) },
        5 => .{ .ref = rand.uintAtMost(u64, key.id_max) },
        6 => .{ .string = randBlob(rand, buf, buf.len) },
        7 => blk: {
            var u: [16]u8 = undefined;
            rand.bytes(&u);
            break :blk .{ .uuid = u };
        },
        else => .{ .bytes = randBlob(rand, buf, buf.len) },
    };
}

test "K5 strings across the inline threshold: one tag, order holds on the 64-byte prefix" {
    var prng = std.Random.DefaultPrng.init(prng_seed +% 5);
    const rand = prng.random();
    var arena = Arena.init();
    defer arena.deinit();
    var ba: [key.inline_max]u8 = undefined;
    var bb: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < pairs_per_type) : (i += 1) {
        errdefer trial(prng_seed +% 5, i);
        const gpa = arena.reset();
        const sa = randBlob(rand, &ba, key.inline_max);
        const sb = bb[0 .. key.inline_max + 1 + rand.uintAtMost(usize, bb.len - key.inline_max - 1)];
        for (sb) |*c| c.* = switch (rand.uintLessThan(u8, 8)) {
            0 => 0,
            1 => 0xFF,
            2 => rand.intRangeAtMost(u8, 'a', 'c'),
            else => rand.int(u8),
        };
        // Share a prefix often, sometimes the whole inline value.
        if (rand.boolean()) {
            const n = rand.uintAtMost(usize, sa.len);
            @memcpy(sb[0..n], sa[0..n]);
        }
        const pa = sa[0..@min(sa.len, key.prefix_len)];
        const pb = sb[0..@min(sb.len, key.prefix_len)];
        const want = std.mem.order(u8, pa, pb);
        const as_string = rand.boolean();
        const va: Val = if (as_string) .{ .string = sa } else .{ .bytes = sa };
        const vb: Val = if (as_string) .{ .string = sb } else .{ .bytes = sb };
        const ea = try key.valBytes(gpa, va);
        const eb = try key.valBytes(gpa, vb);
        try testing.expectEqual(ea[0], eb[0]);
        if (want == .eq) continue;
        try testing.expectEqual(want, std.mem.order(u8, ea, eb));
        // The same holds for whole index keys, where fixed fields follow v.
        const e = rand.uintAtMost(u64, key.id_max);
        const ka = try key.keyBytes(gpa, .avet, e, 7, ea, .{ .t = 3, .added = true });
        const kb = try key.keyBytes(gpa, .avet, e, 7, eb, .{ .t = 3, .added = true });
        try testing.expectEqual(want, std.mem.order(u8, ka, kb));
        // Both decode to what they are.
        const da = try key.decodeVal(gpa, ea);
        try testing.expect(da == .val);
        const db = try key.decodeVal(gpa, eb);
        try testing.expect(db != .val);
        try testing.expectEqual(key.hash128(sb), if (as_string) db.string_long.hash else db.bytes_long.hash);
    }
}
