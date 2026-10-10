//! The process's pseudo-random generator: behind `rand`, `rand-int`
//! and `shuffle`, and behind the sampling aggregates of Nextomic's
//! queries (`sample`, `rand`). It is seeded from the I/O's entropy at
//! first use, or by `seed`. One isolate, one thread (`docs/STDLIB.md`
//! §6).

const std = @import("std");

var prng: ?std.Random.DefaultPrng = null;

/// The generator, seeded from `io`'s entropy on first use.
pub fn shared(io: std.Io) std.Random {
    if (prng == null) {
        var bytes: [8]u8 = undefined;
        io.random(&bytes);
        prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &bytes, .little));
    }
    return prng.?.random();
}

/// Restart the generator from `s`: the same sequence follows.
pub fn seed(s: u64) void {
    prng = std.Random.DefaultPrng.init(s);
}

test "seed: a reseeded generator repeats its sequence" {
    const io = std.Io.Threaded.global_single_threaded.io();
    seed(42);
    const a = shared(io).int(u64);
    const b = shared(io).int(u64);
    seed(42);
    try std.testing.expectEqual(a, shared(io).int(u64));
    try std.testing.expectEqual(b, shared(io).int(u64));
}
