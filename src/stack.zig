//! Native stack guard: every recursion on user-controlled depth calls `check`.
//!
//! The runtime recurses on the Zig stack wherever data nests: reading,
//! expanding and lowering forms, equality, hashing and comparison,
//! printing, the codec, pull, transaction expansion, query parsing, rule
//! expansion, and every native that calls back into the VM. Each such
//! function calls `check` on entry, so an input nested past the stack's
//! budget fails with `error.StackOverflow` instead of faulting
//! (docs/VM.md §13.1).
//!
//! The guard is one address: the lowest frame address a guarded function
//! may run at. `VM.init` arms it for a default 8 MiB main-thread stack
//! unless the host armed it first; the CLI runs the runtime on a thread
//! with a large stack and arms it at that thread's entry. The runtime is
//! single-threaded, so the address is a plain global.

const std = @import("std");

pub const Error = error{StackOverflow};

/// The budget `VM.init` arms: the 8 MiB stack a process's main thread
/// gets by default, less headroom for the frames below the arming call
/// and for the unguarded leaf calls under the deepest guarded frame.
pub const main_thread_budget = 6 << 20;

/// Lowest permitted frame address; 0 leaves the guard unarmed.
var limit: usize = 0;

/// Arm the guard `budget` bytes below the caller's frame.
pub fn arm(budget: usize) void {
    limit = @frameAddress() -| budget;
}

/// Arm the guard `budget` bytes below the caller's frame, unless the
/// host already armed it.
pub fn armIfUnarmed(budget: usize) void {
    if (limit == 0) arm(budget);
}

/// Fail once the calling frame lies below the armed limit. Stacks grow
/// down on every target nexis supports.
pub inline fn check() Error!void {
    if (@frameAddress() < limit) return error.StackOverflow;
}

fn nest(depth: usize) Error!usize {
    try check();
    var pad: [512]u8 = undefined;
    std.mem.doNotOptimizeAway(&pad);
    return 1 + try nest(depth + 1);
}

test "a recursion past the budget fails with StackOverflow instead of faulting" {
    const saved = limit;
    defer limit = saved;
    arm(256 * 1024);
    try std.testing.expectError(error.StackOverflow, nest(0));
}

test "an unarmed guard never fails, and armIfUnarmed keeps an armed limit" {
    const saved = limit;
    defer limit = saved;
    limit = 0;
    try check();
    armIfUnarmed(1 << 20);
    try std.testing.expect(limit != 0);
    const armed = limit;
    armIfUnarmed(1);
    try std.testing.expectEqual(armed, limit);
}
