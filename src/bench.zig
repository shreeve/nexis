//! bench.zig — the criterion-style benchmark harness `bench/main.zig`
//! runs (docs/BENCH.md §3, §10): each row is a distribution of
//! per-operation times, its body repeated in an inner loop long enough
//! to time, reported as a table and as JSON. `docs/PERF.md` holds the
//! numbers of record.

const std = @import("std");

// =============================================================================
// Results (BENCH.md §3, §10)
// =============================================================================

/// One row: what ran, and the statistics of its per-operation times
/// in nanoseconds, the median the headline.
pub const BenchResult = struct {
    name: []const u8 = "",
    category: []const u8 = "",
    /// A scaling parameter (a collection's size), or null.
    param: ?i64 = null,
    samples: usize,
    /// Runs of the body each sample times.
    inner_reps: usize = 1,
    warmup_iters: usize = 0,
    min_ns: f64,
    p5_ns: f64,
    median_ns: f64,
    p95_ns: f64,
    p99_ns: f64,
    max_ns: f64,
    mean_ns: f64,
    stddev_ns: f64,
    ops_per_sec_median: f64,

    /// The statistics of `samples_ns`, which it sorts.
    pub fn fromSamples(samples_ns: []f64) BenchResult {
        std.debug.assert(samples_ns.len > 0);
        std.mem.sort(f64, samples_ns, {}, comptime std.sort.asc(f64));
        const n: f64 = @floatFromInt(samples_ns.len);
        var sum: f64 = 0;
        for (samples_ns) |x| sum += x;
        const mean = sum / n;
        var sqsum: f64 = 0;
        for (samples_ns) |x| sqsum += (x - mean) * (x - mean);
        const median = percentile(samples_ns, 50);
        return .{
            .samples = samples_ns.len,
            .min_ns = samples_ns[0],
            .p5_ns = percentile(samples_ns, 5),
            .median_ns = median,
            .p95_ns = percentile(samples_ns, 95),
            .p99_ns = percentile(samples_ns, 99),
            .max_ns = samples_ns[samples_ns.len - 1],
            .mean_ns = mean,
            .stddev_ns = if (samples_ns.len > 1) std.math.sqrt(sqsum / (n - 1)) else 0,
            .ops_per_sec_median = if (median == 0) 0 else 1_000_000_000.0 / median,
        };
    }

    /// Nearest rank: the sample at rank ceil(p/100 * n), never
    /// interpolated.
    fn percentile(sorted: []const f64, comptime p: u8) f64 {
        const rank = (@as(usize, p) * sorted.len + 99) / 100;
        return sorted[@min(rank -| 1, sorted.len - 1)];
    }
};

// =============================================================================
// Runner (BENCH.md §3)
// =============================================================================

pub const RunnerOptions = struct {
    warmup_iters: usize = 10,
    /// BENCH.md §3's minimum for a warm microbenchmark.
    measure_iters: usize = 30,
    /// The least time one sample takes: the inner loop repeats the
    /// body until it does.
    min_time_ns: u64 = 50_000_000,
    /// The most runs of the body one sample takes, however fast it is.
    max_inner_reps: usize = 100_000_000,
};

/// The span one pilot timing must cover before its per-run estimate
/// is trusted: a thousand ticks of a microsecond clock.
const pilot_min_ns: u64 = 1_000_000;

pub const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    results: std.ArrayList(BenchResult) = .empty,
    opts: RunnerOptions = .{},

    pub fn deinit(self: *Runner) void {
        self.results.deinit(self.allocator);
    }

    fn nowNs(self: Runner) i96 {
        return std.Io.Clock.awake.now(self.io).nanoseconds;
    }

    /// Time `run_fn(ctx)` and record the row `name` of `category`
    /// (`--filter` selects rows by category; bench/main.zig lists
    /// them), with the scaling parameter `param`. `run_fn` must take
    /// the same time on every call; an error it returns propagates, and
    /// no row is recorded.
    pub fn bench(
        self: *Runner,
        comptime name: []const u8,
        comptime category: []const u8,
        param: ?i64,
        ctx: anytype,
        comptime run_fn: anytype,
    ) !void {
        // The pilot: the clock resolves to about a microsecond on
        // macOS, so a body of a few nanoseconds reads as zero in one
        // run; it doubles its runs until one timing spans
        // `pilot_min_ns`, and estimates a run from that span.
        var pilot_reps: usize = 1;
        var pilot_total_ns: u64 = 0;
        while (true) {
            const start = self.nowNs();
            for (0..pilot_reps) |_| try run_fn(ctx);
            pilot_total_ns = @intCast(self.nowNs() - start);
            if (pilot_total_ns >= pilot_min_ns or pilot_reps >= self.opts.max_inner_reps) break;
            pilot_reps *= 2;
        }
        const pilot_ns: u64 = @max(pilot_total_ns / pilot_reps, 1);
        const inner_reps: usize = @min(@divCeil(self.opts.min_time_ns, pilot_ns), self.opts.max_inner_reps);

        for (0..self.opts.warmup_iters) |_| {
            for (0..inner_reps) |_| try run_fn(ctx);
        }
        const samples = try self.allocator.alloc(f64, self.opts.measure_iters);
        defer self.allocator.free(samples);
        for (samples) |*sample| {
            const start = self.nowNs();
            for (0..inner_reps) |_| try run_fn(ctx);
            sample.* = @as(f64, @floatFromInt(self.nowNs() - start)) / @as(f64, @floatFromInt(inner_reps));
        }
        var r = BenchResult.fromSamples(samples);
        r.name = name;
        r.category = category;
        r.param = param;
        r.inner_reps = inner_reps;
        r.warmup_iters = self.opts.warmup_iters;
        try self.results.append(self.allocator, r);
    }

    pub fn writeTable(self: Runner, writer: *std.Io.Writer) !void {
        try writer.print(
            "\n{s:<48} {s:<28} {s:>10} {s:>14} {s:>14} {s:>14} {s:>16}\n",
            .{ "benchmark", "category", "param", "median", "p5", "p95", "ops/sec" },
        );
        try writer.print("{s}\n", .{&@as([150]u8, @splat('-'))});
        var pbuf: [24]u8 = undefined;
        var mbuf: [24]u8 = undefined;
        var p5buf: [24]u8 = undefined;
        var p95buf: [24]u8 = undefined;
        for (self.results.items) |r| {
            const param_str = if (r.param) |p| try std.mem.print(&pbuf, "{d}", .{p}) else "-";
            try writer.print(
                "{s:<48} {s:<28} {s:>10} {s:>14} {s:>14} {s:>14} {d:>16.0}\n",
                .{
                    r.name,
                    r.category,
                    param_str,
                    try formatDurationInto(&mbuf, r.median_ns),
                    try formatDurationInto(&p5buf, r.p5_ns),
                    try formatDurationInto(&p95buf, r.p95_ns),
                    r.ops_per_sec_median,
                },
            );
        }
        try writer.print("\n", .{});
    }

    pub const HostInfo = struct {
        cpu: []const u8,
        os: []const u8,
        ram: []const u8,
        zig_version: []const u8,
        optimize_mode: []const u8,
        note: []const u8 = "",
    };

    /// The JSON of `--out FILE` (BENCH.md §10).
    pub fn writeJson(self: Runner, writer: *std.Io.Writer, host: HostInfo) !void {
        try writer.print("{f}\n", .{std.json.fmt(.{
            .schema_version = 1,
            .generated_at_unix = std.Io.Clock.real.now(self.io).toSeconds(),
            .host = host,
            .results = self.results.items,
        }, .{ .whitespace = .indent_2 })});
    }
};

// =============================================================================
// Formatting helpers
// =============================================================================

fn formatDurationInto(buf: []u8, ns: f64) ![]const u8 {
    if (ns < 1_000) return std.mem.print(buf, "{d:.2} ns", .{ns});
    if (ns < 1_000_000) return std.mem.print(buf, "{d:.2} us", .{ns / 1_000.0});
    if (ns < 1_000_000_000) return std.mem.print(buf, "{d:.2} ms", .{ns / 1_000_000.0});
    return std.mem.print(buf, "{d:.2} s", .{ns / 1_000_000_000.0});
}

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

test "BenchResult.fromSamples: percentiles on trivial distribution" {
    var samples = [_]f64{ 100, 20, 30, 40, 50, 60, 70, 80, 90, 10 };
    const s = BenchResult.fromSamples(&samples);
    try testing.expectEqual(@as(usize, 10), s.samples);
    try testing.expectEqual(@as(f64, 10), s.min_ns);
    try testing.expectEqual(@as(f64, 100), s.max_ns);
    // median of 10 items = 5th ranked = 50
    try testing.expectEqual(@as(f64, 50), s.median_ns);
    // p95 nearest-rank of 10 → rank ceil(0.95*10)=10 → idx 9 → 100
    try testing.expectEqual(@as(f64, 100), s.p95_ns);
}

test "BenchResult.fromSamples: singleton" {
    var samples = [_]f64{42};
    const s = BenchResult.fromSamples(&samples);
    try testing.expectEqual(@as(f64, 42), s.min_ns);
    try testing.expectEqual(@as(f64, 42), s.median_ns);
    try testing.expectEqual(@as(f64, 42), s.max_ns);
    try testing.expectEqual(@as(f64, 0.0), s.stddev_ns);
}

test "Runner: runs a trivial benchmark and computes stats" {
    var runner: Runner = .{
        .allocator = testing.allocator,
        .io = testing.io,
        .opts = .{
            .warmup_iters = 2,
            .measure_iters = 5,
            .min_time_ns = 100_000, // short for test speed
        },
    };
    defer runner.deinit();

    const Ctx = struct { counter: u64 = 0 };
    var ctx = Ctx{};

    try runner.bench("sanity", "test", null, &ctx, struct {
        fn run(c: *Ctx) anyerror!void {
            // Volatile pointer aliasing defeats DCE on `counter`.
            // A thousand increments keep one run above the timer's
            // resolution, so the per-op median is never rounded to
            // zero and the throughput assertion below is exact.
            const vp: *volatile u64 = &c.counter;
            for (0..1000) |_| vp.* = vp.* +% 1;
        }
    }.run);

    try testing.expectEqual(@as(usize, 1), runner.results.items.len);
    const r = runner.results.items[0];
    try testing.expectEqual(@as(usize, 5), r.samples);
    try testing.expect(r.ops_per_sec_median > 0);
}

test "BenchResult: a sub-nanosecond operation keeps its fraction" {
    var samples = [_]f64{ 0.25, 0.5, 0.75 };
    const s = BenchResult.fromSamples(&samples);
    try testing.expectEqual(@as(f64, 0.5), s.median_ns);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("0.50 ns", try formatDurationInto(&buf, s.median_ns));
}

test "writeJson escapes the strings it writes" {
    var runner: Runner = .{ .allocator = testing.allocator, .io = testing.io };
    defer runner.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try runner.writeJson(&out.writer, .{ .cpu = "M5", .os = "macos", .ram = "", .zig_version = "0.17.0", .optimize_mode = "fast", .note = "an \"idle\" run\\" });
    try testing.expect(std.mem.find(u8, out.written(), "\"note\": \"an \\\"idle\\\" run\\\\\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
}
