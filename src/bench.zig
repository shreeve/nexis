//! bench.zig — criterion-style benchmark harness for nexis.
//!
//! Authoritative methodology: `docs/BENCH.md`. This file implements
//! it: the Runner, the Stats computation, the adaptive inner loop, the
//! table and the JSON output. `docs/PERF.md` holds the numbers of
//! record.
//!
//! Design (BENCH.md §3, §10):
//!
//!   - Every benchmark produces a distribution (30 samples by
//!     default).
//!   - Stats reported: min, p5, median, p95, p99, max, mean,
//!     stddev, in fractional nanoseconds per operation. Median is
//!     the headline.
//!   - For nanosecond-scale operations: adaptive inner loop —
//!     a pilot that repeats the body until one timing spans a
//!     millisecond chooses `inner_reps` so a single measurement
//!     takes at least `min_time_ns` (default 50 ms). Per-op cost
//!     = elapsed / inner_reps.
//!   - For operations that already take ≥min_time_ns per run:
//!     inner_reps = 1.
//!
//! Usage:
//!
//!     var runner = try bench.Runner.init(allocator, .{});
//!     defer runner.deinit();
//!
//!     try runner.bench("fixnum add", "scalar", null, &ctx, struct {
//!         fn run(c: *Ctx) anyerror!void { ... }
//!     }.run);
//!
//!     try runner.writeTable(stdout);
//!     try runner.writeJson(json_file, .{ .cpu = "...", .os = "...", ... });
//!
//! Imported by `bench/main.zig` only; no runtime file imports it.

const std = @import("std");

/// Monotonic nanosecond timestamp through POSIX
/// `clock_gettime(MONOTONIC)`.
fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// =============================================================================
// Statistics (BENCH.md §3)
// =============================================================================

pub const Stats = struct {
    samples: usize,
    min_ns: f64,
    p5_ns: f64,
    median_ns: f64,
    p95_ns: f64,
    p99_ns: f64,
    max_ns: f64,
    mean_ns: f64,
    stddev_ns: f64,

    /// Per-operation times in nanoseconds; sorts them in place.
    pub fn fromSamples(samples_ns: []f64) Stats {
        std.debug.assert(samples_ns.len > 0);
        std.mem.sort(f64, samples_ns, {}, comptime std.sort.asc(f64));
        const n = samples_ns.len;

        var sum: f64 = 0;
        for (samples_ns) |x| sum += x;
        const mean_ns = sum / @as(f64, @floatFromInt(n));
        var sqsum: f64 = 0;
        for (samples_ns) |x| sqsum += (x - mean_ns) * (x - mean_ns);
        const stddev_ns = if (n > 1) std.math.sqrt(sqsum / @as(f64, @floatFromInt(n - 1))) else 0.0;

        return .{
            .samples = n,
            .min_ns = samples_ns[0],
            .p5_ns = percentile(samples_ns, 5),
            .median_ns = percentile(samples_ns, 50),
            .p95_ns = percentile(samples_ns, 95),
            .p99_ns = percentile(samples_ns, 99),
            .max_ns = samples_ns[n - 1],
            .mean_ns = mean_ns,
            .stddev_ns = stddev_ns,
        };
    }

    /// Nearest rank (BENCH.md §10): the sample at rank ceil(p/100 * n),
    /// never interpolated.
    fn percentile(sorted: []const f64, comptime p: u8) f64 {
        const n = sorted.len;
        const rank = (@as(usize, p) * n + 99) / 100;
        return sorted[@min(if (rank == 0) 0 else rank - 1, n - 1)];
    }
};

// =============================================================================
// BenchResult
// =============================================================================

pub const BenchResult = struct {
    name: []const u8,
    category: []const u8,
    /// Optional integer parameter for scaling benchmarks (e.g.,
    /// collection size). Carried through to the JSON.
    param: ?i64,
    stats: Stats,
    /// Ops/sec derived from the *median* (not the min,
    /// not the mean). BENCH.md §3 requires median as the headline.
    ops_per_sec_median: f64,
    /// How many inner-loop iterations collapsed into each sample
    /// (the adaptive inner loop of this file's design notes).
    inner_reps: usize,
    /// Warmup iterations discarded before measurement.
    warmup_iters: usize,
};

// =============================================================================
// Runner (BENCH.md §3 default mins)
// =============================================================================

pub const RunnerOptions = struct {
    warmup_iters: usize = 10,
    measure_iters: usize = 30, // BENCH.md §3: minimum for warm microbench.
    /// Floor for a single measurement. The adaptive inner-loop
    /// scales `inner_reps` until `elapsed_ns >= min_time_ns`.
    min_time_ns: u64 = 50_000_000, // 50 ms
    /// Absolute cap on `inner_reps`. Even if pilot is very fast,
    /// we won't repeat more than this to keep a single
    /// measurement bounded.
    max_inner_reps: usize = 100_000_000,
};

/// The span one pilot timing must cover before its per-run estimate
/// is trusted: a thousand ticks of a microsecond clock.
const pilot_min_ns: u64 = 1_000_000;

pub const Runner = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayListUnmanaged(BenchResult),
    opts: RunnerOptions,

    pub fn init(allocator: std.mem.Allocator, opts: RunnerOptions) !Runner {
        return .{
            .allocator = allocator,
            .results = .empty,
            .opts = opts,
        };
    }

    pub fn deinit(self: *Runner) void {
        self.results.deinit(self.allocator);
    }

    /// Run `run_fn(ctx)` under criterion-style measurement.
    ///
    /// `name`: stable identifier for this benchmark (appears in JSON).
    /// `category`: the suite category the row belongs to, the name
    ///   `--filter` selects it by ("scalar", "collection-construction",
    ///   "db-integrated", ...; bench/main.zig lists them).
    /// `param`: optional scaling parameter (e.g., N for size-N
    ///   collection benchmarks).
    /// `ctx`: arbitrary state passed to `run_fn`.
    /// `run_fn`: the function under measurement. MUST be
    ///   deterministic-time (no I/O, no allocator pressure that
    ///   depends on prior state unless the benchmark explicitly
    ///   resets it). An error it returns propagates, and no result
    ///   is recorded.
    pub fn bench(
        self: *Runner,
        comptime name: []const u8,
        comptime category: []const u8,
        param: ?i64,
        ctx: anytype,
        comptime run_fn: anytype,
    ) !void {
        // ---- Pilot: time the body to choose `inner_reps`. ----
        //
        // The clock resolves to about a microsecond on macOS, so a
        // body of a few nanoseconds reads as zero elapsed in one run.
        // The pilot doubles its repetitions until one timing spans
        // `pilot_min_ns`, and the per-run estimate comes from that
        // span.
        var pilot_reps: usize = 1;
        var pilot_total_ns: u64 = 0;
        while (true) {
            const pilot_start = nowNs();
            var pr: usize = 0;
            while (pr < pilot_reps) : (pr += 1) try run_fn(ctx);
            pilot_total_ns = nowNs() - pilot_start;
            if (pilot_total_ns >= pilot_min_ns or pilot_reps >= self.opts.max_inner_reps) break;
            pilot_reps *= 2;
        }
        const pilot_ns: u64 = @max(pilot_total_ns / pilot_reps, 1);

        const inner_reps: usize = if (pilot_ns >= self.opts.min_time_ns)
            1
        else blk: {
            // ceil(min_time_ns / pilot_ns)
            const reps = (self.opts.min_time_ns + pilot_ns - 1) / pilot_ns;
            break :blk @min(@as(usize, @intCast(reps)), self.opts.max_inner_reps);
        };

        // ---- Warmup: `warmup_iters` measurements, discard. ----
        var wi: usize = 0;
        while (wi < self.opts.warmup_iters) : (wi += 1) {
            var r: usize = 0;
            while (r < inner_reps) : (r += 1) try run_fn(ctx);
        }

        // ---- Measurement. ----
        const samples = try self.allocator.alloc(f64, self.opts.measure_iters);
        defer self.allocator.free(samples);

        var mi: usize = 0;
        while (mi < self.opts.measure_iters) : (mi += 1) {
            const t0 = nowNs();
            var r: usize = 0;
            while (r < inner_reps) : (r += 1) try run_fn(ctx);
            const t1 = nowNs();
            samples[mi] = @as(f64, @floatFromInt(t1 - t0)) / @as(f64, @floatFromInt(inner_reps));
        }

        const stats = Stats.fromSamples(samples);

        // 1 / median (ns) → ops / s
        const ops_per_sec_median: f64 = if (stats.median_ns == 0) 0 else 1_000_000_000.0 / stats.median_ns;

        try self.results.append(self.allocator, .{
            .name = name,
            .category = category,
            .param = param,
            .stats = stats,
            .ops_per_sec_median = ops_per_sec_median,
            .inner_reps = inner_reps,
            .warmup_iters = self.opts.warmup_iters,
        });
    }

    // =========================================================================
    // Human-readable output
    // =========================================================================

    pub fn writeTable(self: Runner, writer: anytype) !void {
        try writer.print(
            "\n{s:<48} {s:<28} {s:>10} {s:>14} {s:>14} {s:>14} {s:>16}\n",
            .{ "benchmark", "category", "param", "median", "p5", "p95", "ops/sec" },
        );
        try writer.print("{s}\n", .{"-" ** 150});
        var pbuf: [24]u8 = undefined;
        var mbuf: [24]u8 = undefined;
        var p5buf: [24]u8 = undefined;
        var p95buf: [24]u8 = undefined;
        for (self.results.items) |r| {
            const param_str = if (r.param) |p|
                try std.fmt.bufPrint(&pbuf, "{d}", .{p})
            else
                "-";
            try writer.print(
                "{s:<48} {s:<28} {s:>10} {s:>14} {s:>14} {s:>14} {d:>16.0}\n",
                .{
                    r.name,
                    r.category,
                    param_str,
                    try formatDurationInto(&mbuf, r.stats.median_ns),
                    try formatDurationInto(&p5buf, r.stats.p5_ns),
                    try formatDurationInto(&p95buf, r.stats.p95_ns),
                    r.ops_per_sec_median,
                },
            );
        }
        try writer.print("\n", .{});
    }

    // =========================================================================
    // JSON output (machine-readable, `--out FILE`)
    // =========================================================================

    pub const HostInfo = struct {
        cpu: []const u8,
        os: []const u8,
        ram: []const u8,
        zig_version: []const u8,
        optimize_mode: []const u8,
        note: []const u8 = "",
    };

    pub fn writeJson(self: Runner, writer: anytype, host: HostInfo) !void {
        try writer.writeAll("{\n");
        var wall_ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &wall_ts);
        try writer.print(
            "  \"schema_version\": 1,\n  \"generated_at_unix\": {d},\n",
            .{wall_ts.sec},
        );
        try writer.writeAll("  \"host\": {\n");
        try writer.print("    \"cpu\": {f},\n", .{std.json.fmt(host.cpu, .{})});
        try writer.print("    \"os\": {f},\n", .{std.json.fmt(host.os, .{})});
        try writer.print("    \"ram\": {f},\n", .{std.json.fmt(host.ram, .{})});
        try writer.print("    \"zig_version\": {f},\n", .{std.json.fmt(host.zig_version, .{})});
        try writer.print("    \"optimize_mode\": {f},\n", .{std.json.fmt(host.optimize_mode, .{})});
        try writer.print("    \"note\": {f}\n", .{std.json.fmt(host.note, .{})});
        try writer.writeAll("  },\n");
        try writer.writeAll("  \"results\": [\n");
        for (self.results.items, 0..) |r, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"name\": {f},\n", .{std.json.fmt(r.name, .{})});
            try writer.print("      \"category\": {f},\n", .{std.json.fmt(r.category, .{})});
            if (r.param) |p| {
                try writer.print("      \"param\": {d},\n", .{p});
            } else {
                try writer.writeAll("      \"param\": null,\n");
            }
            try writer.print("      \"samples\": {d},\n", .{r.stats.samples});
            try writer.print("      \"inner_reps\": {d},\n", .{r.inner_reps});
            try writer.print("      \"warmup_iters\": {d},\n", .{r.warmup_iters});
            try writer.print("      \"min_ns\": {d:.3},\n", .{r.stats.min_ns});
            try writer.print("      \"p5_ns\": {d:.3},\n", .{r.stats.p5_ns});
            try writer.print("      \"median_ns\": {d:.3},\n", .{r.stats.median_ns});
            try writer.print("      \"p95_ns\": {d:.3},\n", .{r.stats.p95_ns});
            try writer.print("      \"p99_ns\": {d:.3},\n", .{r.stats.p99_ns});
            try writer.print("      \"max_ns\": {d:.3},\n", .{r.stats.max_ns});
            try writer.print("      \"mean_ns\": {d:.2},\n", .{r.stats.mean_ns});
            try writer.print("      \"stddev_ns\": {d:.2},\n", .{r.stats.stddev_ns});
            try writer.print("      \"ops_per_sec_median\": {d:.2}\n", .{r.ops_per_sec_median});
            if (i + 1 < self.results.items.len) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }
        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");
    }
};

// =============================================================================
// Formatting helpers
// =============================================================================

fn formatDurationInto(buf: []u8, ns: f64) ![]const u8 {
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d:.2} ns", .{ns});
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d:.2} us", .{ns / 1_000.0});
    if (ns < 1_000_000_000) return std.fmt.bufPrint(buf, "{d:.2} ms", .{ns / 1_000_000.0});
    return std.fmt.bufPrint(buf, "{d:.2} s", .{ns / 1_000_000_000.0});
}

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

test "Stats.fromSamples: percentiles on trivial distribution" {
    var samples = [_]f64{ 100, 20, 30, 40, 50, 60, 70, 80, 90, 10 };
    const s = Stats.fromSamples(&samples);
    try testing.expectEqual(@as(usize, 10), s.samples);
    try testing.expectEqual(@as(f64, 10), s.min_ns);
    try testing.expectEqual(@as(f64, 100), s.max_ns);
    // median of 10 items = 5th ranked = 50
    try testing.expectEqual(@as(f64, 50), s.median_ns);
    // p95 nearest-rank of 10 → rank ceil(0.95*10)=10 → idx 9 → 100
    try testing.expectEqual(@as(f64, 100), s.p95_ns);
}

test "Stats.fromSamples: singleton" {
    var samples = [_]f64{42};
    const s = Stats.fromSamples(&samples);
    try testing.expectEqual(@as(f64, 42), s.min_ns);
    try testing.expectEqual(@as(f64, 42), s.median_ns);
    try testing.expectEqual(@as(f64, 42), s.max_ns);
    try testing.expectEqual(@as(f64, 0.0), s.stddev_ns);
}

test "Runner: runs a trivial benchmark and computes stats" {
    var runner = try Runner.init(testing.allocator, .{
        .warmup_iters = 2,
        .measure_iters = 5,
        .min_time_ns = 100_000, // short for test speed
    });
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
    try testing.expectEqual(@as(usize, 5), r.stats.samples);
    try testing.expect(r.ops_per_sec_median > 0);
}

test "Stats: a sub-nanosecond operation keeps its fraction" {
    var samples = [_]f64{ 0.25, 0.5, 0.75 };
    const s = Stats.fromSamples(&samples);
    try testing.expectEqual(@as(f64, 0.5), s.median_ns);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("0.50 ns", try formatDurationInto(&buf, s.median_ns));
}

test "writeJson escapes the strings it writes" {
    var runner = try Runner.init(testing.allocator, .{});
    defer runner.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try runner.writeJson(&out.writer, .{ .cpu = "M5", .os = "macos", .ram = "", .zig_version = "0.16.0", .optimize_mode = "ReleaseFast", .note = "an \"idle\" run\\" });
    try testing.expect(std.mem.indexOf(u8, out.written(), "\"note\": \"an \\\"idle\\\" run\\\\\"") != null);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
}
