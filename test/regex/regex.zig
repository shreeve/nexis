//! test/regex/regex.zig — the regex engine against java.util.regex.
//!
//! Runs `src/regex.zig` directly (no VM, no heap) on every line of
//! `corpus.json`, which `corpus.clj` generated through the JVM: random
//! patterns over the supported syntax and random inputs, with Java's
//! every find and its groups (docs/REGEX.md §7). A Java `ERR` must be
//! a compile error here too; a Java `TIMEOUT` asserts only that the
//! search completes, which it always does in linear time. The gate
//! needs no JVM: regenerating the corpus is a deliberate commit.

const std = @import("std");
const nx = @import("nexis");
const regex = nx.regex;

const corpus = @embedFile("corpus.json");

/// Why `line` disagrees with Java, or null when it agrees.
fn check(gpa: std.mem.Allocator, arena: std.mem.Allocator, line: []const u8) !?[]const u8 {
    const case = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    const fields = case.array.items;
    const pattern = fields[0].string;
    const hay = fields[1].string;
    const want = fields[2];
    const prog = switch (try regex.compile(arena, pattern, .{})) {
        .err => |e| return if (want == .string and std.mem.eql(u8, want.string, "ERR")) null else e.msg,
        .ok => |p| p,
    };
    if (want == .string and std.mem.eql(u8, want.string, "ERR")) return "Java refuses the pattern";
    var vm: regex.Vm = try .init(gpa, &prog, true);
    defer vm.deinit(gpa);
    var finder: regex.Finder = .{ .vm = &vm, .hay = hay };
    if (want == .string) { // TIMEOUT
        while (finder.find()) {}
        return null;
    }
    for (want.array.items) |groups| {
        if (!finder.find()) return "fewer matches";
        for (groups.array.items, 0..) |g, i| {
            const got = vm.group(i);
            const same = if (got) |s| g != .null and std.mem.eql(u8, g.string, hay[s[0]..s[1]]) else g == .null;
            if (!same) return if (i == 0) "the match differs" else "a group differs";
        }
    }
    return if (finder.find()) "more matches" else null;
}

test "regex: every corpus case agrees with java.util.regex" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    var cases: usize = 0;
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        cases += 1;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        if (try check(gpa, arena.allocator(), line)) |why| {
            failures += 1;
            if (failures <= 40) std.debug.print("{s}: {s}\n", .{ why, line });
        }
    }
    if (failures > 0) std.debug.print("{d} of {d} cases disagree\n", .{ failures, cases });
    try std.testing.expectEqual(@as(usize, 0), failures);
    try std.testing.expect(cases >= 9000);
}
