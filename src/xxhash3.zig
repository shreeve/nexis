//! xxhash3.zig — XXH3-64, one-shot, over a seed fixed at compile time.
//!
//! Every value is `std.hash.XxHash3.hash(seed, bytes)`'s: the tests
//! compare the two at every length through 2 KiB and at each stripe
//! and block boundary through 4 KiB. The algorithm and constants are
//! the standard library's (MIT license, Copyright (c) Zig contributors);
//! this copy is shaped for the code the compiler makes of it:
//!
//! - inputs and the secret are read with `std.mem.readInt`, never
//!   through a `@bitCast` of a byte array, which the optimizer lowers
//!   to byte shuffles;
//! - the seeded secret of the long path is computed at compile time;
//! - a 64-byte stripe is one vector, loaded through an unaligned
//!   pointer.
//!
//! nexis builds only for little-endian targets, where the byte order
//! of a load is the algorithm's.

const std = @import("std");
const builtin = @import("builtin");

comptime {
    std.debug.assert(builtin.target.cpu.arch.endian() == .little);
}

const prime32_1: u64 = 0x9E3779B1;
const prime32_2: u64 = 0x85EBCA77;
const prime32_3: u64 = 0xC2B2AE3D;
const prime64_1: u64 = 0x9E3779B185EBCA87;
const prime64_2: u64 = 0xC2B2AE3D27D4EB4F;
const prime64_3: u64 = 0x165667B19E3779F9;
const prime64_4: u64 = 0x85EBCA77C2B2AE63;
const prime64_5: u64 = 0x27D4EB2F165667C5;
const prime_mx1: u64 = 0x165667919E3779F9;
const prime_mx2: u64 = 0x9FB21C651E98DF25;

const default_secret: [192]u8 = .{
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, 0xf7, 0x21, 0xad, 0x1c,
    0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb, 0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f,
    0xcb, 0x79, 0xe6, 0x4e, 0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6, 0x81, 0x3a, 0x26, 0x4c,
    0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb, 0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3,
    0x71, 0x64, 0x48, 0x97, 0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7, 0xc7, 0x0b, 0x4f, 0x1d,
    0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31, 0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64,
    0xea, 0xc5, 0xac, 0x83, 0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26, 0x29, 0xd4, 0x68, 0x9e,
    0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc, 0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce,
    0x45, 0xcb, 0x3a, 0x8f, 0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
};

/// A 64-byte stripe as eight lanes.
const Block = @Vector(8, u64);
const block_bytes = @sizeOf(Block);

/// The 64-bit little-endian word at `bytes[at..]`.
inline fn word(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

inline fn word32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

inline fn avalanche(x0: u64) u64 {
    const x1 = (x0 ^ (x0 >> 37)) *% prime_mx1;
    return x1 ^ (x1 >> 32);
}

inline fn avalanche64(x0: u64) u64 {
    const x1 = (x0 ^ (x0 >> 33)) *% prime64_2;
    const x2 = (x1 ^ (x1 >> 29)) *% prime64_3;
    return x2 ^ (x2 >> 32);
}

inline fn rrmxmx(x0: u64, len: u64) u64 {
    const x1 = (x0 ^ std.math.rotl(u64, x0, 49) ^ std.math.rotl(u64, x0, 24)) *% prime_mx2;
    const x2 = (x1 ^ ((x1 >> 35) +% len)) *% prime_mx2;
    return x2 ^ (x2 >> 28);
}

/// The two halves of the 128-bit product, folded.
inline fn fold(a: u64, b: u64) u64 {
    const wide = @as(u128, a) *% b;
    return @as(u64, @truncate(wide)) ^ @as(u64, @truncate(wide >> 64));
}

/// An empty asm statement that takes `x`, so the optimizer keeps the
/// scalar mix loops scalar: vectorized, they run slower.
inline fn keepScalar(x: anytype) void {
    if (!@inComptime()) asm volatile (""
        :
        : [x] "r" (x),
    );
}

inline fn mix16(seed: u64, input: []const u8, at: usize, secret_at: usize) u64 {
    const lo = word(input, at) ^ (word(&default_secret, secret_at) +% seed);
    const hi = word(input, at + 8) ^ (word(&default_secret, secret_at + 8) -% seed);
    keepScalar(seed);
    return fold(lo, hi);
}

/// XXH3-64 of `input` with `seed`.
pub inline fn hash(comptime seed: u64, input: []const u8) u64 {
    if (input.len > 240) return hashLong(seed, input);
    if (input.len > 128) return hash240(seed, input);
    if (input.len > 16) return hash128(seed, input);
    if (input.len > 8) return hash16(seed, input);
    if (input.len > 3) return hash8(seed, input);
    if (input.len > 0) return hash3(seed, input);
    return comptime avalanche64(seed ^ (word(&default_secret, 56) ^ word(&default_secret, 64)));
}

fn hash3(comptime seed: u64, input: []const u8) u64 {
    const len = input.len;
    const combined: u32 = @as(u32, input[0]) << 16 | @as(u32, input[len / 2]) << 24 | @as(u32, input[len - 1]) | @as(u32, @intCast(len)) << 8;
    const key = comptime @as(u64, word32(&default_secret, 0) ^ word32(&default_secret, 4)) +% seed;
    return avalanche64(key ^ combined);
}

fn hash8(comptime seed: u64, input: []const u8) u64 {
    const mixed = comptime seed ^ (@as(u64, @byteSwap(@as(u32, @truncate(seed)))) << 32);
    const key = comptime (word(&default_secret, 8) ^ word(&default_secret, 16)) -% mixed;
    const combined = (@as(u64, word32(input, 0)) << 32) +% word32(input, input.len - 4);
    return rrmxmx(key ^ combined, input.len);
}

fn hash16(comptime seed: u64, input: []const u8) u64 {
    const lo = word(input, 0) ^ comptime ((word(&default_secret, 24) ^ word(&default_secret, 32)) +% seed);
    const hi = word(input, input.len - 8) ^ comptime ((word(&default_secret, 40) ^ word(&default_secret, 48)) -% seed);
    return avalanche(@as(u64, input.len) +% @byteSwap(lo) +% hi +% fold(lo, hi));
}

fn hash128(comptime seed: u64, input: []const u8) u64 {
    var acc = prime64_1 *% @as(u64, input.len);
    inline for (0..4) |i| {
        const in_at = 48 - i * 16;
        const secret_at = 96 - i * 32;
        if (input.len > secret_at) {
            acc +%= mix16(seed, input, in_at, secret_at);
            acc +%= mix16(seed, input, input.len - (in_at + 16), secret_at + 16);
        }
    }
    return avalanche(acc);
}

fn hash240(comptime seed: u64, input: []const u8) u64 {
    var acc = prime64_1 *% @as(u64, input.len);
    inline for (0..8) |i| acc +%= mix16(seed, input, i * 16, i * 16);
    var acc_end = mix16(seed, input, input.len - 16, 136 - 17);
    for (8..input.len / 16) |i| {
        acc_end +%= mix16(seed, input, i * 16, (i - 8) * 16 + 3);
        keepScalar(i);
    }
    return avalanche(avalanche(acc) +% acc_end);
}

/// The long path's secret for `seed`: the default secret's 64-bit
/// words, alternately plus and minus the seed.
fn seededSecret(comptime seed: u64) [192]u8 {
    var secret: [192]u8 = undefined;
    for (0..192 / 16) |i| {
        std.mem.writeInt(u64, secret[i * 16 ..][0..8], word(&default_secret, i * 16) +% seed, .little);
        std.mem.writeInt(u64, secret[i * 16 + 8 ..][0..8], word(&default_secret, i * 16 + 8) -% seed, .little);
    }
    return secret;
}

/// The stripe of `bytes` at `at`, word by word: for the secret's
/// blocks, built at compile time.
fn blockOf(bytes: []const u8, at: usize) Block {
    var block: Block = undefined;
    inline for (0..8) |i| block[i] = word(bytes, at + i * 8);
    return block;
}

inline fn loadBlock(bytes: []const u8, at: usize) Block {
    return @as(*align(1) const Block, @ptrCast(bytes[at..][0..block_bytes])).*;
}

inline fn round(state: *Block, data: Block, key: Block) void {
    const mixed = data ^ key;
    state.* +%= (mixed & @as(Block, @splat(0xffffffff))) *% (mixed >> @splat(32));
    state.* +%= @shuffle(u64, data, undefined, [_]i32{ 1, 0, 3, 2, 5, 4, 7, 6 });
}

noinline fn hashLong(comptime seed: u64, input: []const u8) u64 {
    const secret = comptime seededSecret(seed);
    // A block is 16 stripes, each mixed with the secret 8 bytes further
    // on; the state is scrambled after every whole block.
    const stripes_per_block = (192 - block_bytes) / 8;

    var state: Block = .{ prime32_3, prime64_1, prime64_2, prime64_3, prime64_4, prime32_2, prime64_5, prime32_1 };
    // Every stripe but the last, which the digest takes from the end.
    const stripes = (input.len - 1) / block_bytes;
    var s: usize = 0;
    while (s + stripes_per_block <= stripes) : (s += stripes_per_block) {
        inline for (0..stripes_per_block) |k| {
            @prefetch(input.ptr + (s + k) * block_bytes + 320, .{});
            round(&state, loadBlock(input, (s + k) * block_bytes), comptime blockOf(&secret, k * 8));
        }
        state ^= state >> @splat(47);
        state ^= comptime blockOf(&secret, 192 - block_bytes);
        state *%= @as(Block, @splat(prime32_1));
    }
    for (s..stripes) |stripe| {
        round(&state, loadBlock(input, stripe * block_bytes), loadBlock(&secret, (stripe - s) * 8));
    }

    round(&state, loadBlock(input, input.len - block_bytes), comptime blockOf(&secret, 192 - block_bytes - 7));
    state ^= comptime blockOf(&secret, 11);
    var result = prime64_1 *% @as(u64, input.len);
    inline for (0..4) |i| result +%= fold(state[i * 2], state[i * 2 + 1]);
    return avalanche(result);
}

const testing = std.testing;

test "hash: std.hash.XxHash3's value at every length through 2 KiB and every boundary through 4 KiB" {
    var bytes: [4096 + 1]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x6e65786973);
    prng.random().bytes(&bytes);
    inline for (.{ 0, 0x3173_6978_656E | (@as(u64, '/') << 48) | (@as(u64, '1') << 56) }) |seed| {
        for (0..2049) |len| try testing.expectEqual(std.hash.XxHash3.hash(seed, bytes[0..len]), hash(seed, bytes[0..len]));
        var len: usize = 2049;
        while (len <= 4096) : (len += 1) {
            const at_boundary = len % 64 <= 1 or len % 64 == 63 or len % 1024 <= 1 or len % 1024 >= 1023;
            if (at_boundary) try testing.expectEqual(std.hash.XxHash3.hash(seed, bytes[0..len]), hash(seed, bytes[0..len]));
        }
        // An unaligned start.
        for ([_]usize{ 1, 7, 100, 241, 1025, 4095 }) |n| try testing.expectEqual(std.hash.XxHash3.hash(seed, bytes[1..][0..n]), hash(seed, bytes[1..][0..n]));
    }
}

/// The first `n` bytes of "1234567890" repeated.
fn digits(comptime n: usize) *const [n]u8 {
    return comptime blk: {
        @setEvalBranchQuota(2 * n + 1000);
        var buf: [n]u8 = undefined;
        for (&buf, 0..) |*c, i| c.* = '0' + @as(u8, @intCast((i + 1) % 10));
        const final = buf;
        break :blk &final;
    };
}

test "hash: the XXH3-64 reference vectors, pinned" {
    const seed0 = [_]struct { []const u8, u64 }{
        .{ "", 0x2d06800538d394c2 },
        .{ "a", 0xe6c632b61e964e1f },
        .{ "abc", 0x78af5f94892f3950 },
        .{ "message", 0x0b1ca9b8977554fa },
        .{ "message digest", 0x160d8e9329be94f9 },
        .{ "abcdefghijklmnopqrstuvwxyz", 0x810f9ca067fbb90c },
        .{ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", 0x643542bb51639cb2 },
        .{ digits(80), 0x7f58aa2520c681f9 },
        .{ digits(218), 0xb66ea795b5edc38c },
        .{ digits(320), 0x8845e0b1b57330de },
        .{ digits(320) ++ "123123", 0xf031f373d63c5653 },
        .{ digits(3200), 0xf1bf601f9d868dce },
    };
    const seed1 = [_]struct { []const u8, u64 }{
        .{ "", 0x4dc5b0cc826f6703 },
        .{ "a", 0xd2f6d0996f37a720 },
        .{ "abc", 0x6b4467b443c76228 },
        .{ "message", 0x73fb1cf20d561766 },
        .{ "message digest", 0xfe71a82a70381174 },
        .{ "abcdefghijklmnopqrstuvwxyz", 0x902a2c2d016a37ba },
        .{ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", 0xbf552e540c5c6882 },
        .{ digits(80), 0xf2ca33235a6b865b },
        .{ digits(218), 0x06ef5cf958ba52c4 },
        .{ digits(320), 0xfbc5f9c53d21cb2f },
        .{ digits(320) ++ "123123", 0x48682aca3b1c5c18 },
        .{ digits(3200), 0x3903c5437fc4e726 },
    };
    for (seed0) |c| try testing.expectEqual(c[1], hash(0, c[0]));
    for (seed1) |c| try testing.expectEqual(c[1], hash(1, c[0]));
}
