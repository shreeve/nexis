//! bench/main.zig — nexis baseline benchmark suite.
//!
//! Driver `main()` that runs every benchmark in this file,
//! prints a human-readable table to stdout, and writes JSON to
//! `--out <path>` (default `bench/baseline.json` under the repo
//! root).
//!
//! Categories (BENCH.md §2):
//!   - scalar: fixnum / float arithmetic, keyword identity hash,
//!     raw xxHash3 over bytes.
//!   - collection-construction: list / vector / map / set built
//!     by N-fold conj/assoc from empty.
//!   - collection-lookup-update: random lookup on a pre-built
//!     collection of size N.
//!   - transient-construction: same as collection-construction,
//!     but using transient wrappers + `persistent!`.
//!   - codec: encode / decode for representative Values.
//!   - db-integrated: emdb put / get round-trip cost (PLAN §19
//!     "database-integrated" category).
//!   - vm: the dispatch loop on a routine compiled once (a counting
//!     loop, the same loop calling a global fn, a keyword lookup).
//!   - nextomic: `q` over a 200k-datom store and `pull` over 20k
//!     entities (bench/nextomic.zig).
//!
//! Every benchmark function here is a tiny wrapper over a
//! `Runner.bench` call; the harness lives in `src/bench.zig`.
//!
//! CLI:
//!
//!     zig build bench                         # full suite, table to stdout
//!     zig build bench -- --out FILE           # also write JSON to FILE
//!     zig build bench -- --filter vm,codec    # run only the named categories
//!     zig build bench -- --note "M4 idle"     # annotate the JSON host field
//!
//! An unknown flag or category is an error. The numbers of record live
//! in docs/PERF.md, each with the host that produced it (BENCH.md §4).

const std = @import("std");
const nx = @import("nexis");
const bench = nx.bench;
const nextomic_bench = @import("nextomic.zig");
const value_mod = nx.value;
const heap_mod = nx.heap;
const intern_mod = nx.intern;
const hash_mod = nx.hash;
const string_mod = nx.string;
const list_mod = nx.list;
const vector_mod = nx.vector;
const champ = nx.champ;
const transient_mod = nx.transient;
const codec_mod = nx.codec;
const dispatch = nx.dispatch;
const db = nx.db;
const emdb = nx.emdb;
const pool_mod = nx.pool;
const vm_mod = nx.vm;
const compile_mod = nx.compile;

const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const Runner = bench.Runner;

// Each benchmark function takes a pointer to its own state struct.

// -----------------------------------------------------------------------------
// Scalar — fixnum arithmetic
// -----------------------------------------------------------------------------

const ScalarCtx = struct {
    // Volatile-accessed operands so ReleaseFast can't
    // constant-fold the body into a no-op.
    a_fx: i64 = 7,
    b_fx: i64 = 11,
    a_f64: f64 = 1.5,
    b_f64: f64 = 2.25,
    acc_fx: i64 = 0,
    acc_f: f64 = 0,
};

fn benchFixnumAdd(ctx: *ScalarCtx) anyerror!void {
    // Read operands via volatile pointers to force a memory
    // load per call; otherwise ReleaseFast constant-folds the
    // entire body (observed: 0 ns before this fix).
    const ap: *volatile i64 = &ctx.a_fx;
    const bp: *volatile i64 = &ctx.b_fx;
    const a = value_mod.fromFixnum(ap.*).?;
    const b = value_mod.fromFixnum(bp.*).?;
    const sum = value_mod.fromFixnum(a.asFixnum() + b.asFixnum()).?;
    const accp: *volatile i64 = &ctx.acc_fx;
    accp.* = accp.* +% sum.asFixnum();
}

fn benchFloatAdd(ctx: *ScalarCtx) anyerror!void {
    const ap: *volatile f64 = &ctx.a_f64;
    const bp: *volatile f64 = &ctx.b_f64;
    const a = value_mod.fromFloat(ap.*);
    const b = value_mod.fromFloat(bp.*);
    const sum = value_mod.fromFloat(a.asFloat() + b.asFloat());
    const accp: *volatile f64 = &ctx.acc_f;
    accp.* = accp.* + sum.asFloat();
}

// -----------------------------------------------------------------------------
// Scalar — hashing
// -----------------------------------------------------------------------------

const HashCtx = struct {
    heap: *Heap,
    interner: *Interner,
    v: Value,
    sink: u64 = 0,
};

fn benchHashFixnum(ctx: *HashCtx) anyerror!void {
    ctx.sink +%= dispatch.hashValue(ctx.v);
}

fn benchHashKeyword(ctx: *HashCtx) anyerror!void {
    ctx.sink +%= dispatch.hashValue(ctx.v);
}

fn benchHashString(ctx: *HashCtx) anyerror!void {
    ctx.sink +%= dispatch.hashValue(ctx.v);
}

fn benchHashRawBytes(ctx: *HashCtx) anyerror!void {
    // Raw xxHash3 over bytes — what string.hashHeader calls
    // internally. Measures the hash primitive itself.
    _ = ctx;
    const s = "the quick brown fox jumps over the lazy dog" ** 4;
    const h = hash_mod.hashBytes(s);
    // defeat DCE
    const vp: *volatile u64 = @constCast(&raw_hash_sink);
    vp.* = h;
}
var raw_hash_sink: u64 = 0;

// -----------------------------------------------------------------------------
// Collection construction — build from empty by N-fold conj/assoc
// -----------------------------------------------------------------------------

const BuildCtx = struct {
    // Per-invocation heap backing (so each bench run gets a fresh
    // Heap and releases all blocks via heap.deinit()). Prevents
    // unbounded memory growth across inner_reps. Keys/vals are
    // immediates (interned keyword ids + fixnums); they don't
    // reference the per-invocation heap.
    alloc: std.mem.Allocator,
    interner: *Interner,
    n: usize,
    keys: []Value,
    vals: []Value,
};

fn benchListConj(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    var lst = try list_mod.empty(&heap);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        lst = try list_mod.cons(&heap, ctx.vals[i], lst);
    }
    std.mem.doNotOptimizeAway(lst);
}

fn benchVectorConj(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    var v = try vector_mod.empty(&heap);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        v = try vector_mod.conj(&heap, v, ctx.vals[i]);
    }
    std.mem.doNotOptimizeAway(v);
}

fn benchMapAssoc(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    var m = try champ.mapEmpty(&heap);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        m = try champ.mapAssoc(&heap, m, ctx.keys[i], ctx.vals[i], &dispatch.hashValue, &dispatch.equal);
    }
    std.mem.doNotOptimizeAway(m);
}

fn benchSetConj(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    var s = try champ.setEmpty(&heap);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        s = try champ.setConj(&heap, s, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
    }
    std.mem.doNotOptimizeAway(s);
}

// -----------------------------------------------------------------------------
// Transient construction — same N, transient wrappers + persistent!
// -----------------------------------------------------------------------------

fn benchTransientVectorConj(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    const base = try vector_mod.empty(&heap);
    var t = try transient_mod.transientFrom(&heap, base);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        t = try transient_mod.vectorConjBang(&heap, t, ctx.vals[i]);
    }
    const v = try transient_mod.persistentBang(t);
    std.mem.doNotOptimizeAway(v);
}

fn benchTransientMapAssoc(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    const base = try champ.mapEmpty(&heap);
    var t = try transient_mod.transientFrom(&heap, base);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        t = try transient_mod.mapAssocBang(&heap, t, ctx.keys[i], ctx.vals[i], &dispatch.hashValue, &dispatch.equal);
    }
    const m = try transient_mod.persistentBang(t);
    std.mem.doNotOptimizeAway(m);
}

fn benchTransientSetConj(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    const base = try champ.setEmpty(&heap);
    var t = try transient_mod.transientFrom(&heap, base);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        t = try transient_mod.setConjBang(&heap, t, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
    }
    const s = try transient_mod.persistentBang(t);
    std.mem.doNotOptimizeAway(s);
}

// -----------------------------------------------------------------------------
// Collection lookup — pre-built collection, N lookups
// -----------------------------------------------------------------------------

const LookupCtx = struct {
    vec: Value,
    map: Value,
    set: Value,
    keys: []Value, // the same keys used to build, so every lookup hits
    sink: u64 = 0,
};

fn benchVectorNth(ctx: *LookupCtx) anyerror!void {
    var i: usize = 0;
    const n = ctx.keys.len;
    // Volatile sink to force every read through memory.
    const sp: *volatile u64 = &ctx.sink;
    while (i < n) : (i += 1) {
        const v = vector_mod.nth(ctx.vec, i);
        sp.* = sp.* +% @as(u64, @bitCast(v.asFixnum()));
    }
}

fn benchMapGet(ctx: *LookupCtx) anyerror!void {
    var i: usize = 0;
    const n = ctx.keys.len;
    while (i < n) : (i += 1) {
        const lookup = champ.mapGet(ctx.map, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
        switch (lookup) {
            .present => |pv| ctx.sink +%= @as(u64, @bitCast(pv.asFixnum())),
            .absent => {},
        }
    }
}

fn benchSetContains(ctx: *LookupCtx) anyerror!void {
    var i: usize = 0;
    const n = ctx.keys.len;
    while (i < n) : (i += 1) {
        const present = champ.setContains(ctx.set, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
        ctx.sink +%= if (present) 1 else 0;
    }
}

// -----------------------------------------------------------------------------
// Codec — encode / decode representative Values
// -----------------------------------------------------------------------------

const CodecCtx = struct {
    interner: *Interner,
    allocator: std.mem.Allocator,
    target: Value,
    encoded: []u8, // pre-encoded bytes for the decode benchmark
    /// Where decoded values go. It is dropped whenever it holds more
    /// than `scratch_limit` bytes, so a decode benchmark's memory stays
    /// bounded however many repetitions the pilot chooses.
    scratch: Heap,
    sink: u64 = 0,

    const scratch_limit = 16 << 20;
};

fn benchCodecEncode(ctx: *CodecCtx) anyerror!void {
    const bytes = try codec_mod.encode(ctx.allocator, ctx.interner, ctx.target);
    defer ctx.allocator.free(bytes);
    ctx.sink +%= bytes.len;
}

fn benchCodecDecode(ctx: *CodecCtx) anyerror!void {
    if (ctx.scratch.live_bytes > CodecCtx.scratch_limit) {
        ctx.scratch.deinit();
        ctx.scratch = Heap.init(ctx.allocator);
    }
    const v = try codec_mod.decode(&ctx.scratch, ctx.interner, ctx.encoded, &dispatch.hashValue, &dispatch.equal);
    ctx.sink +%= @as(u64, @bitCast(@as(u64, v.tag)));
}

// -----------------------------------------------------------------------------
// DB — emdb put / get round-trip
// -----------------------------------------------------------------------------

const DbCtx = struct {
    conn: *db.Connection,
    key: []const u8,
    value: Value,
    sink: u64 = 0,
};

fn benchDbPut(ctx: *DbCtx) anyerror!void {
    var wtxn = try db.beginWrite(ctx.conn);
    try db.put(&wtxn, "bench", ctx.key, ctx.value);
    try db.commit(&wtxn);
}

fn benchDbGetHit(ctx: *DbCtx) anyerror!void {
    var rtxn = try db.beginRead(ctx.conn);
    defer db.abortRead(&rtxn);
    const got = try db.get(&rtxn, "bench", ctx.key, &dispatch.hashValue, &dispatch.equal);
    ctx.sink +%= if (got) |v| @as(u64, @bitCast(@as(u64, v.tag))) else 0;
}

// =============================================================================
// Driver
// =============================================================================

fn populateKeysAndVals(
    alloc: std.mem.Allocator,
    interner: *Interner,
    n: usize,
) !struct { keys: []Value, vals: []Value } {
    const keys = try alloc.alloc(Value, n);
    const vals = try alloc.alloc(Value, n);
    // Keys: interned keywords "k0000".."kNNNN" so we exercise
    // keyword keys (the common case in nexis maps).
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "k{d}", .{i});
        keys[i] = try interner.internKeywordValue(name);
        vals[i] = value_mod.fromFixnum(@intCast(i)).?;
    }
    return .{ .keys = keys, .vals = vals };
}

// =============================================================================
// Compiler benchmarks (COMPILER.md §9.4 gate item 7)
// =============================================================================

const CompileBenchCtx = struct {
    alloc: std.mem.Allocator,
};

/// Measure compile throughput: parser + reader + macroexpand +
/// lowerForm + compileTiny for `(+ 1 2)`. Allocates a fresh
/// arena per iteration so the measured cost is steady-state
/// compile, not amortized scope reuse.
fn benchCompileSimple(ctx: *CompileBenchCtx) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    var interner = intern_mod.Interner.init(arena.allocator());
    defer interner.deinit();
    const compiled = try compile_mod.compileSourceFull(
        arena.allocator(),
        "(+ 1 2)",
        null,
        &interner,
    );
    std.mem.doNotOptimizeAway(compiled);
}

/// The whole pipeline for a one-form program, per sample: a VM is
/// built, the source is read, expanded, compiled and run, and
/// everything is released. The `vm` category measures the dispatch
/// loop alone.
const PipelineCtx = struct {
    alloc: std.mem.Allocator,
    source: []const u8,
};

fn benchPipeline(ctx: *PipelineCtx) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.alloc);
    defer arena.deinit();
    var v = try vm_mod.VM.init(ctx.alloc, &vm_mod.VM.idle_routine);
    defer v.deinit();
    const compiled = try compile_mod.compileSourceFull(arena.allocator(), ctx.source, null, v.ensureInterner());
    const routine = compiled.toRoutine("bench");
    try v.retargetTop(&routine);
    std.mem.doNotOptimizeAway(try v.run());
}

// -----------------------------------------------------------------------------
// VM dispatch — a routine compiled once and run per invocation
// -----------------------------------------------------------------------------

/// A VM with one compiled routine. `run` retargets the top frame and
/// runs it, so a sample is the dispatch loop alone: no reader, no
/// compiler, no VM construction.
const RunCtx = struct {
    arena: std.heap.ArenaAllocator,
    v: vm_mod.VM,
    routine: vm_mod.Routine,
    sink: u64 = 0,

    fn init(alloc: std.mem.Allocator, setup: ?[]const u8, source: []const u8) !*RunCtx {
        const ctx = try alloc.create(RunCtx);
        ctx.arena = std.heap.ArenaAllocator.init(alloc);
        errdefer ctx.arena.deinit();
        ctx.v = try vm_mod.VM.init(alloc, &vm_mod.VM.idle_routine);
        errdefer ctx.v.deinit();
        const interner = ctx.v.ensureInterner();
        const ns = ctx.v.ensureNamespace();
        if (setup) |s| {
            const compiled = try compile_mod.compileSourceFull(ctx.arena.allocator(), s, ns, interner);
            const routine = compiled.toRoutine("bench-setup");
            try ctx.v.retargetTop(&routine);
            _ = try ctx.v.run();
        }
        const compiled = try compile_mod.compileSourceFull(ctx.arena.allocator(), source, ns, interner);
        ctx.routine = compiled.toRoutine("bench");
        ctx.sink = 0;
        return ctx;
    }

    fn deinit(self: *RunCtx, alloc: std.mem.Allocator) void {
        self.v.deinit();
        self.arena.deinit();
        alloc.destroy(self);
    }
};

fn benchRun(ctx: *RunCtx) anyerror!void {
    try ctx.v.retargetTop(&ctx.routine);
    const result = try ctx.v.run();
    ctx.sink +%= @as(u64, @bitCast(result.payload));
}

/// A fresh store file under $TMPDIR (or /tmp), named for this
/// process so concurrent runs never share it; `deinit` removes it.
const TmpStore = struct {
    path: [:0]u8,

    fn init(alloc: std.mem.Allocator, name: []const u8) !TmpStore {
        const dir = if (std.c.getenv("TMPDIR")) |d| std.mem.span(d) else "/tmp";
        const path = try std.fmt.allocPrintSentinel(alloc, "{s}/nexis-bench-{d}-{s}.emdb", .{ std.mem.trimEnd(u8, dir, "/"), std.c.getpid(), name }, 0);
        remove(path);
        return .{ .path = path };
    }

    fn deinit(self: *TmpStore, alloc: std.mem.Allocator) void {
        remove(self.path);
        alloc.free(self.path);
    }

    fn remove(path: [:0]const u8) void {
        _ = std.c.unlink(path.ptr);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const lock_path = std.fmt.bufPrintSentinel(&buf, "{s}-lock", .{path}, 0) catch return;
        _ = std.c.unlink(lock_path.ptr);
    }
};

/// Every category `--filter` accepts, in the order the suite runs them.
const categories = [_][]const u8{
    "scalar",
    "collection-construction",
    "transient-construction",
    "collection-lookup-update",
    "compiler",
    "vm",
    "codec",
    "db-integrated",
    "nextomic",
};

pub fn main(init: std.process.Init) !u8 {
    const alloc = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // ---- CLI ----
    var out_path: ?[]const u8 = null;
    var note: []const u8 = "";
    var filter: ?[]const u8 = null;
    var allocator_choice: []const u8 = "pool"; // POOL.md §9 default
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const a = args[ai];
        if (std.mem.eql(u8, a, "--out") and ai + 1 < args.len) {
            ai += 1;
            out_path = args[ai];
        } else if (std.mem.eql(u8, a, "--note") and ai + 1 < args.len) {
            ai += 1;
            note = args[ai];
        } else if (std.mem.eql(u8, a, "--filter") and ai + 1 < args.len) {
            ai += 1;
            filter = args[ai];
        } else if (std.mem.eql(u8, a, "--allocator") and ai + 1 < args.len) {
            ai += 1;
            allocator_choice = args[ai];
        } else {
            std.debug.print("nexis-bench: unknown argument '{s}'\nusage: nexis-bench [--out FILE] [--note TEXT] [--filter CATEGORY,...] [--allocator pool|std]\n", .{a});
            return 2;
        }
    }
    if (filter) |f| {
        var it = std.mem.tokenizeScalar(u8, f, ',');
        while (it.next()) |name| {
            for (categories) |category| {
                if (std.mem.eql(u8, name, category)) break;
            } else {
                std.debug.print("nexis-bench: unknown category '{s}'; the categories are", .{name});
                for (categories) |category| std.debug.print(" {s}", .{category});
                std.debug.print("\n", .{});
                return 2;
            }
        }
    }
    if (!std.mem.eql(u8, allocator_choice, "pool") and !std.mem.eql(u8, allocator_choice, "std")) {
        std.debug.print("nexis-bench: --allocator is pool or std, not '{s}'\n", .{allocator_choice});
        return 2;
    }

    // Backing allocator for the size-class pool itself. Must be
    // a real general-purpose allocator — `page_allocator` is NOT
    // suitable here because it rounds every allocation up to a
    // page, which under the bench workload OOMs quickly.
    const backing = init.gpa;

    // Heap-backing allocator under measurement. POOL.md §9:
    // pool is the default; --allocator std selects the process
    // GPA directly (matches commit 7e5bb1a's baseline).
    var pool: pool_mod.PoolAllocator = undefined;
    var heap_backing: std.mem.Allocator = undefined;
    const use_pool = std.mem.eql(u8, allocator_choice, "pool");
    if (use_pool) {
        pool = pool_mod.PoolAllocator.init(backing);
        heap_backing = pool.allocator();
    } else {
        heap_backing = init.gpa;
    }
    defer if (use_pool) pool.deinit();

    // ---- Runner ----
    var runner = try Runner.init(alloc, .{});
    defer runner.deinit();

    // ---- Shared interner + heap for non-DB benches ----
    var interner = Interner.init(alloc);
    defer interner.deinit();
    // Heap is what the pool allocator actually backs for the A/B:
    // the vast majority of allocations under measurement come from
    // `heap.alloc()`.
    var heap = Heap.init(heap_backing);
    defer heap.deinit();

    const include = struct {
        fn match(f: ?[]const u8, cat: []const u8) bool {
            const ff = f orelse return true;
            // Comma-separated exact-match on category string.
            var it = std.mem.tokenizeScalar(u8, ff, ',');
            while (it.next()) |tok| {
                if (std.mem.eql(u8, tok, cat)) return true;
            }
            return false;
        }
    }.match;

    // ---- Scalar ----
    if (include(filter, "scalar")) {
        var sctx = ScalarCtx{};
        try runner.bench("fixnum_add", "scalar", null, &sctx, benchFixnumAdd);
        try runner.bench("float_add", "scalar", null, &sctx, benchFloatAdd);

        var hctx_fx = HashCtx{ .heap = &heap, .interner = &interner, .v = value_mod.fromFixnum(12345).? };
        try runner.bench("hash_fixnum", "scalar", null, &hctx_fx, benchHashFixnum);

        const kw = try interner.internKeywordValue("benchmark-keyword-name");
        var hctx_kw = HashCtx{ .heap = &heap, .interner = &interner, .v = kw };
        try runner.bench("hash_keyword", "scalar", null, &hctx_kw, benchHashKeyword);

        const s = try string_mod.fromBytes(&heap, "the quick brown fox jumps over the lazy dog");
        var hctx_s = HashCtx{ .heap = &heap, .interner = &interner, .v = s };
        try runner.bench("hash_string_43b", "scalar", null, &hctx_s, benchHashString);

        var hctx_raw = HashCtx{ .heap = &heap, .interner = &interner, .v = value_mod.nilValue() };
        try runner.bench("xxhash3_raw_172b", "scalar", null, &hctx_raw, benchHashRawBytes);
    }

    // ---- Collection construction ----
    if (include(filter, "collection-construction")) {
        const sizes = [_]usize{ 16, 256, 4096 };
        for (sizes) |n| {
            const kv = try populateKeysAndVals(alloc, &interner, n);
            defer alloc.free(kv.keys);
            defer alloc.free(kv.vals);
            var bctx = BuildCtx{ .alloc = heap_backing, .interner = &interner, .n = n, .keys = kv.keys, .vals = kv.vals };
            const np: i64 = @intCast(n);
            try runner.bench("list_cons_n", "collection-construction", np, &bctx, benchListConj);
            try runner.bench("vector_conj_n", "collection-construction", np, &bctx, benchVectorConj);
            try runner.bench("map_assoc_n", "collection-construction", np, &bctx, benchMapAssoc);
            try runner.bench("set_conj_n", "collection-construction", np, &bctx, benchSetConj);
        }
    }

    // ---- Transient construction ----
    if (include(filter, "transient-construction")) {
        const sizes = [_]usize{ 16, 256, 4096 };
        for (sizes) |n| {
            const kv = try populateKeysAndVals(alloc, &interner, n);
            defer alloc.free(kv.keys);
            defer alloc.free(kv.vals);
            var bctx = BuildCtx{ .alloc = heap_backing, .interner = &interner, .n = n, .keys = kv.keys, .vals = kv.vals };
            const np: i64 = @intCast(n);
            try runner.bench("transient_vector_conjbang_n", "transient-construction", np, &bctx, benchTransientVectorConj);
            try runner.bench("transient_map_assocbang_n", "transient-construction", np, &bctx, benchTransientMapAssoc);
            try runner.bench("transient_set_conjbang_n", "transient-construction", np, &bctx, benchTransientSetConj);
        }
    }

    // ---- Collection lookup ----
    if (include(filter, "collection-lookup-update")) {
        const sizes = [_]usize{ 256, 4096 };
        for (sizes) |n| {
            const kv = try populateKeysAndVals(alloc, &interner, n);
            defer alloc.free(kv.keys);
            defer alloc.free(kv.vals);

            // Pre-build the collections.
            var v = try vector_mod.empty(&heap);
            var m = try champ.mapEmpty(&heap);
            var s2 = try champ.setEmpty(&heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                v = try vector_mod.conj(&heap, v, kv.vals[i]);
                m = try champ.mapAssoc(&heap, m, kv.keys[i], kv.vals[i], &dispatch.hashValue, &dispatch.equal);
                s2 = try champ.setConj(&heap, s2, kv.keys[i], &dispatch.hashValue, &dispatch.equal);
            }

            var lctx = LookupCtx{ .vec = v, .map = m, .set = s2, .keys = kv.keys };
            const np: i64 = @intCast(n);
            try runner.bench("vector_nth_n_sequential", "collection-lookup-update", np, &lctx, benchVectorNth);
            try runner.bench("map_get_n_hit", "collection-lookup-update", np, &lctx, benchMapGet);
            try runner.bench("set_contains_n_hit", "collection-lookup-update", np, &lctx, benchSetContains);
        }
    }

    // ---- Compiler (COMPILER.md §9.4 gate item 7) ----
    //
    //   compile_simple — read, expand and compile `(+ 1 2)`
    //   eval_simple_loop, closure_create, eval_arith — the whole
    //     pipeline (VM construction, compile, run) for a 100-iteration
    //     recur loop, an immediately called closure and a nested
    //     arithmetic call
    if (include(filter, "compiler")) {
        var cctx = CompileBenchCtx{ .alloc = alloc };
        try runner.bench("compile_simple", "compiler", null, &cctx, benchCompileSimple);
        var loop = PipelineCtx{ .alloc = alloc, .source = "(loop* [i 0] (if (< i 100) (recur (+ i 1)) i))" };
        try runner.bench("eval_simple_loop", "compiler", 100, &loop, benchPipeline);
        var closure = PipelineCtx{ .alloc = alloc, .source = "((fn* [] 42))" };
        try runner.bench("closure_create", "compiler", null, &closure, benchPipeline);
        var arith = PipelineCtx{ .alloc = alloc, .source = "(+ (+ 1 2) (+ 3 4))" };
        try runner.bench("eval_arith", "compiler", null, &arith, benchPipeline);
    }

    // ---- VM dispatch ----
    //
    // Each routine is compiled once; a sample runs it on the same
    // VM. Every row loops 10,000 times, so per-iteration cost is
    // the median divided by 10,000.
    if (include(filter, "vm")) {
        const loop_ctx = try RunCtx.init(alloc, null, "(loop* [i 0] (if (< i 10000) (recur (+ i 1)) i))");
        defer loop_ctx.deinit(alloc);
        try runner.bench("vm_loop_10k", "vm", 10_000, loop_ctx, benchRun);

        const call_ctx = try RunCtx.init(
            alloc,
            "(def inc1 (fn* [x] (+ x 1)))",
            "(loop* [i 0] (if (< i 10000) (recur (inc1 i)) i))",
        );
        defer call_ctx.deinit(alloc);
        try runner.bench("vm_global_call_10k", "vm", 10_000, call_ctx, benchRun);

        const kw_ctx = try RunCtx.init(
            alloc,
            "(def m {:a 1 :b 2 :c 3 :d 4 :e 5 :f 6 :g 7 :h 8 :i 9 :j 10 :k 11 :l 12})",
            "(loop* [i 0 acc 0] (if (< i 10000) (recur (+ i 1) (+ acc (:k m))) acc))",
        );
        defer kw_ctx.deinit(alloc);
        try runner.bench("vm_keyword_get_10k", "vm", 10_000, kw_ctx, benchRun);
    }

    // ---- Codec ----
    if (include(filter, "codec")) {
        // Scalar round-trip.
        {
            const v = value_mod.fromFixnum(123_456_789).?;
            const bytes = try codec_mod.encode(alloc, &interner, v);
            defer alloc.free(bytes);
            var cctx = CodecCtx{ .interner = &interner, .allocator = alloc, .target = v, .encoded = bytes, .scratch = Heap.init(alloc) };
            defer cctx.scratch.deinit();
            try runner.bench("codec_encode_fixnum", "codec", null, &cctx, benchCodecEncode);
            try runner.bench("codec_decode_fixnum", "codec", null, &cctx, benchCodecDecode);
        }
        // Map round-trip (N=64, nested values).
        {
            const n: usize = 64;
            const kv = try populateKeysAndVals(alloc, &interner, n);
            defer alloc.free(kv.keys);
            defer alloc.free(kv.vals);
            var m = try champ.mapEmpty(&heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                m = try champ.mapAssoc(&heap, m, kv.keys[i], kv.vals[i], &dispatch.hashValue, &dispatch.equal);
            }
            const bytes = try codec_mod.encode(alloc, &interner, m);
            defer alloc.free(bytes);
            var cctx = CodecCtx{ .interner = &interner, .allocator = alloc, .target = m, .encoded = bytes, .scratch = Heap.init(alloc) };
            defer cctx.scratch.deinit();
            try runner.bench("codec_encode_map_n64", "codec", 64, &cctx, benchCodecEncode);
            try runner.bench("codec_decode_map_n64", "codec", 64, &cctx, benchCodecDecode);
        }
    }

    // ---- DB-integrated ----
    if (include(filter, "db-integrated")) {
        var store = try TmpStore.init(alloc, "db");
        defer store.deinit(alloc);
        var conn = try db.open(alloc, &heap, &interner, store.path.ptr, .{ .allocator = alloc });
        defer db.close(&conn);

        // Seed the key we'll be overwriting.
        {
            var wtxn = try db.beginWrite(&conn);
            try db.put(&wtxn, "bench", "k", value_mod.fromFixnum(0).?);
            try db.commit(&wtxn);
        }

        var dctx = DbCtx{ .conn = &conn, .key = "k", .value = value_mod.fromFixnum(42).? };
        try runner.bench("db_put_commit_scalar", "db-integrated", null, &dctx, benchDbPut);
        try runner.bench("db_get_hit_scalar", "db-integrated", null, &dctx, benchDbGetHit);
    }

    // ---- Nextomic (docs/PERF.md §3.7) ----
    if (include(filter, "nextomic")) {
        {
            var store = try TmpStore.init(alloc, "q");
            defer store.deinit(alloc);
            try nextomic_bench.runQuery(&runner, alloc, store.path);
        }
        {
            var store = try TmpStore.init(alloc, "pull");
            defer store.deinit(alloc);
            try nextomic_bench.runPull(&runner, alloc, store.path);
        }
    }

    // ---- Output: the table to stdout, JSON to --out ----
    {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try aw.writer.print("\n(allocator: {s})\n", .{allocator_choice});
        try runner.writeTable(&aw.writer);
        try std.Io.File.stdout().writeStreamingAll(io, aw.written());
    }

    if (out_path) |p| {
        var jw: std.Io.Writer.Allocating = .init(alloc);
        defer jw.deinit();
        var note_buf: [256]u8 = undefined;
        const decorated_note = try std.fmt.bufPrint(&note_buf, "{s} | allocator={s}", .{ note, allocator_choice });
        try runner.writeJson(&jw.writer, .{
            .cpu = builtin_cpu_model_str,
            .os = @tagName(@import("builtin").os.tag),
            .ram = "",
            .zig_version = @import("builtin").zig_version_string,
            .optimize_mode = @tagName(@import("builtin").mode),
            .note = decorated_note,
        });
        var file = try std.Io.Dir.cwd().createFile(io, p, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, jw.written());
        std.debug.print("\nJSON written to {s}\n", .{p});
    }

    return 0;
}

// Compile-time detected CPU model string — best effort.
const builtin_cpu_model_str = blk: {
    const b = @import("builtin");
    break :blk b.cpu.model.name;
};
