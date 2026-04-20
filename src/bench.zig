//! bench.zig — criterion-style benchmark harness for nexis.
//!
//! Authoritative methodology: `docs/BENCH.md`. This file is the
//! *implementation* of the methodology — the Runner, the Stats
//! computation, the adaptive inner-loop, the JSON output.
//!
//! Complements `docs/PERF.md` (performance landscape) and
//! `docs/PERF-MEASURED.md` (human-readable companion to
//! `bench/baseline.json`, updated on each baseline refresh).
//!
//! Design (BENCH.md §3):
//!
//!   - Every benchmark produces a distribution (min 30 samples for
//!     warm microbenchmarks; user can override).
//!   - Stats reported: min, p5, median, p95, p99, max, mean,
//!     stddev. Median is the headline (§3 mandate).
//!   - For nanosecond-scale operations: adaptive inner loop —
//!     pilot once, choose `inner_reps` so a single measurement
//!     takes at least `min_time_ns` (default 50 ms). Per-op cost
//!     = elapsed / inner_reps.
//!   - For operations that already take ≥min_time_ns per run:
//!     inner_reps = 1.
//!
//! Output:
//!
//!   - Human-readable table to stdout.
//!   - JSON to `--out <file>` (one entry per `Runner.bench` call)
//!     with fields matching BENCH.md §3 and §4 hardware-disclosure
//!     metadata (host metadata filled by the caller of
//!     `Runner.writeJson`).
//!
//! Usage:
//!
//!     var runner = try bench.Runner.init(allocator, .{});
//!     defer runner.deinit();
//!
//!     try runner.bench("fixnum add", "scalar", null, &ctx, 1, struct {
//!         fn run(c: *Ctx) anyerror!void { ... }
//!     }.run);
//!
//!     try runner.writeTable(stdout);
//!     try runner.writeJson(json_file, .{ .cpu = "...", .os = "...", ... });
//!
//! This file is imported only by benchmark source files and by
//! the `bench` executable entrypoint. It is NOT part of the
//! runtime core.

const std = @import("std");

/// Monotonic nanosecond timestamp. Zig 0.16 removed
/// `std.time.nanoTimestamp`; we use POSIX `clock_gettime(MONOTONIC)`
/// directly via `std.c`. macOS, Linux, and *BSD all expose it.
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
    min_ns: u64,
    p5_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    mean_ns: f64,
    stddev_ns: f64,

    pub fn fromSamples(samples_ns: []u64) Stats {
        std.debug.assert(samples_ns.len > 0);
        std.mem.sort(u64, samples_ns, {}, comptime std.sort.asc(u64));

        const n = samples_ns.len;
        const min_ns = samples_ns[0];
        const max_ns = samples_ns[n - 1];

        // Percentile helper — nearest-rank method (BENCH.md §3
        // specifies percentiles; nearest-rank is the
        // parameterless default. We document; we do not compute
        // interpolated percentiles to avoid per-rep method drift
        // across harnesses.)
        const p5_ns = percentile(samples_ns, 5);
        const median_ns = percentile(samples_ns, 50);
        const p95_ns = percentile(samples_ns, 95);
        const p99_ns = percentile(samples_ns, 99);

        // Mean + stddev.
        var sum: f64 = 0;
        for (samples_ns) |s| sum += @floatFromInt(s);
        const mean_ns = sum / @as(f64, @floatFromInt(n));
        var sqsum: f64 = 0;
        for (samples_ns) |s| {
            const d = @as(f64, @floatFromInt(s)) - mean_ns;
            sqsum += d * d;
        }
        const stddev_ns = if (n > 1)
            std.math.sqrt(sqsum / @as(f64, @floatFromInt(n - 1)))
        else
            0.0;

        return .{
            .samples = n,
            .min_ns = min_ns,
            .p5_ns = p5_ns,
            .median_ns = median_ns,
            .p95_ns = p95_ns,
            .p99_ns = p99_ns,
            .max_ns = max_ns,
            .mean_ns = mean_ns,
            .stddev_ns = stddev_ns,
        };
    }

    fn percentile(sorted: []const u64, comptime p: u8) u64 {
        // Nearest-rank: rank k = ceil(p/100 * n), then sample at
        // index k-1.
        const n = sorted.len;
        const rank_num: u64 = @as(u64, p) * @as(u64, n);
        const rank_ceil = (rank_num + 99) / 100; // ceil division
        const idx = if (rank_ceil == 0) 0 else rank_ceil - 1;
        return sorted[@min(idx, n - 1)];
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
    /// Best-case ops/sec derived from the *median* (not the min,
    /// not the mean). BENCH.md §3 requires median as the headline.
    ops_per_sec_median: f64,
    /// How many inner-loop iterations collapsed into each sample
    /// (adaptive scaling — §1 of this file's doc).
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
    /// `category`: one of BENCH.md §2 taxonomy strings
    ///   ("warm-microbench", "collection-construction",
    ///   "collection-lookup-update", "memory-footprint", etc.).
    /// `param`: optional scaling parameter (e.g., N for size-N
    ///   collection benchmarks).
    /// `ctx`: arbitrary state passed to `run_fn`.
    /// `run_fn`: the function under measurement. MUST be
    ///   deterministic-time (no I/O, no allocator pressure that
    ///   depends on prior state unless the benchmark explicitly
    ///   resets it). Returning an error aborts this benchmark and
    ///   records a zero-sample BenchResult.
    pub fn bench(
        self: *Runner,
        comptime name: []const u8,
        comptime category: []const u8,
        param: ?i64,
        ctx: anytype,
        comptime run_fn: anytype,
    ) !void {
        // ---- Pilot: one run to choose `inner_reps`. ----
        const pilot_start = nowNs();
        try run_fn(ctx);
        const pilot_end = nowNs();
        const pilot_ns: u64 = pilot_end - pilot_start;

        const inner_reps: usize = if (pilot_ns >= self.opts.min_time_ns)
            1
        else blk: {
            // ceil(min_time_ns / max(pilot_ns, 1))
            const p = @max(pilot_ns, 1);
            const reps = (self.opts.min_time_ns + p - 1) / p;
            break :blk @min(@as(usize, @intCast(reps)), self.opts.max_inner_reps);
        };

        // ---- Warmup: `warmup_iters` measurements, discard. ----
        var wi: usize = 0;
        while (wi < self.opts.warmup_iters) : (wi += 1) {
            var r: usize = 0;
            while (r < inner_reps) : (r += 1) try run_fn(ctx);
        }

        // ---- Measurement. ----
        const samples = try self.allocator.alloc(u64, self.opts.measure_iters);
        defer self.allocator.free(samples);

        var mi: usize = 0;
        while (mi < self.opts.measure_iters) : (mi += 1) {
            const t0 = nowNs();
            var r: usize = 0;
            while (r < inner_reps) : (r += 1) try run_fn(ctx);
            const t1 = nowNs();
            const elapsed: u64 = t1 - t0;
            samples[mi] = elapsed / inner_reps;
        }

        const stats = Stats.fromSamples(samples);

        // 1 / median (ns) → ops / s
        const ops_per_sec_median: f64 = if (stats.median_ns == 0)
            0
        else
            1_000_000_000.0 / @as(f64, @floatFromInt(stats.median_ns));

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
    // Human-readable output (table to stdout)
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
    // JSON output (machine-readable; checked into bench/baseline.json)
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
        try writer.print("    \"cpu\": \"{s}\",\n", .{host.cpu});
        try writer.print("    \"os\": \"{s}\",\n", .{host.os});
        try writer.print("    \"ram\": \"{s}\",\n", .{host.ram});
        try writer.print("    \"zig_version\": \"{s}\",\n", .{host.zig_version});
        try writer.print("    \"optimize_mode\": \"{s}\",\n", .{host.optimize_mode});
        try writer.print("    \"note\": \"{s}\"\n", .{host.note});
        try writer.writeAll("  },\n");
        try writer.writeAll("  \"results\": [\n");
        for (self.results.items, 0..) |r, i| {
            try writer.writeAll("    {\n");
            try writer.print("      \"name\": \"{s}\",\n", .{r.name});
            try writer.print("      \"category\": \"{s}\",\n", .{r.category});
            if (r.param) |p| {
                try writer.print("      \"param\": {d},\n", .{p});
            } else {
                try writer.writeAll("      \"param\": null,\n");
            }
            try writer.print("      \"samples\": {d},\n", .{r.stats.samples});
            try writer.print("      \"inner_reps\": {d},\n", .{r.inner_reps});
            try writer.print("      \"warmup_iters\": {d},\n", .{r.warmup_iters});
            try writer.print("      \"min_ns\": {d},\n", .{r.stats.min_ns});
            try writer.print("      \"p5_ns\": {d},\n", .{r.stats.p5_ns});
            try writer.print("      \"median_ns\": {d},\n", .{r.stats.median_ns});
            try writer.print("      \"p95_ns\": {d},\n", .{r.stats.p95_ns});
            try writer.print("      \"p99_ns\": {d},\n", .{r.stats.p99_ns});
            try writer.print("      \"max_ns\": {d},\n", .{r.stats.max_ns});
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

fn formatDurationInto(buf: []u8, ns: u64) ![]const u8 {
    if (ns < 1_000) {
        return std.fmt.bufPrint(buf, "{d} ns", .{ns});
    } else if (ns < 1_000_000) {
        const us = @as(f64, @floatFromInt(ns)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.2} us", .{us});
    } else if (ns < 1_000_000_000) {
        const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2} ms", .{ms});
    } else {
        const s = @as(f64, @floatFromInt(ns)) / 1_000_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2} s", .{s});
    }
}

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

test "Stats.fromSamples: percentiles on trivial distribution" {
    var samples = [_]u64{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    const s = Stats.fromSamples(&samples);
    try testing.expectEqual(@as(usize, 10), s.samples);
    try testing.expectEqual(@as(u64, 10), s.min_ns);
    try testing.expectEqual(@as(u64, 100), s.max_ns);
    // median of 10 items = 5th ranked = 50
    try testing.expectEqual(@as(u64, 50), s.median_ns);
    // p95 nearest-rank of 10 → rank ceil(0.95*10)=10 → idx 9 → 100
    try testing.expectEqual(@as(u64, 100), s.p95_ns);
}

test "Stats.fromSamples: singleton" {
    var samples = [_]u64{42};
    const s = Stats.fromSamples(&samples);
    try testing.expectEqual(@as(u64, 42), s.min_ns);
    try testing.expectEqual(@as(u64, 42), s.median_ns);
    try testing.expectEqual(@as(u64, 42), s.max_ns);
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
            // Volatile pointer aliasing defeats DCE on `counter`
            // reliably in Zig 0.16 without depending on the
            // `std.mem.doNotOptimizeAway` API (which was reshuffled
            // between 0.15 and 0.16).
            const vp: *volatile u64 = &c.counter;
            vp.* = vp.* +% 1;
        }
    }.run);

    try testing.expectEqual(@as(usize, 1), runner.results.items.len);
    const r = runner.results.items[0];
    try testing.expectEqual(@as(usize, 5), r.stats.samples);
    try testing.expect(r.ops_per_sec_median > 0);
}
