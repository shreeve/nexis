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
//!
//! Every benchmark function here is a tiny wrapper over a
//! `Runner.bench` call; the heavy lifting lives in `src/bench.zig`.
//!
//! CLI:
//!
//!     zig build bench                         # full suite, table to stdout
//!     zig build bench -- --out FILE           # also write JSON to FILE
//!     zig build bench -- --filter list,vector # run only named categories
//!     zig build bench -- --note "M4 idle"     # annotate the JSON host field
//!
//! The baseline numbers checked into `bench/baseline.json` are
//! produced by running this on the canonical benchmark hardware
//! noted in `docs/PERF-MEASURED.md`. Re-runs on other hardware
//! are welcome but publish separately per BENCH.md §4.

const std = @import("std");
const bench = @import("bench");
const value_mod = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const hash_mod = @import("hash");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const hamt = @import("hamt");
const transient_mod = @import("transient");
const codec_mod = @import("codec");
const dispatch = @import("dispatch");
const db = @import("db");
const emdb = @import("emdb");
const pool_mod = @import("pool");

const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const Runner = bench.Runner;

// =============================================================================
// Shared context — built once, reused across many benchmark calls.
//
// Zig 0.16: benchmark functions take a pointer to a per-bench
// state struct; the outer Bench* context below is plumbed via
// field access in closures.
// =============================================================================

fn makeHeap(alloc: std.mem.Allocator) Heap {
    return Heap.init(alloc);
}

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
    var m = try hamt.mapEmpty(&heap);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        m = try hamt.mapAssoc(&heap, m, ctx.keys[i], ctx.vals[i], &dispatch.hashValue, &dispatch.equal);
    }
    std.mem.doNotOptimizeAway(m);
}

fn benchSetConj(ctx: *BuildCtx) anyerror!void {
    var heap = Heap.init(ctx.alloc);
    defer heap.deinit();
    var s = try hamt.setEmpty(&heap);
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        s = try hamt.setConj(&heap, s, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
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
    const base = try hamt.mapEmpty(&heap);
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
    const base = try hamt.setEmpty(&heap);
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
        const lookup = hamt.mapGet(ctx.map, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
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
        const present = hamt.setContains(ctx.set, ctx.keys[i], &dispatch.hashValue, &dispatch.equal);
        ctx.sink +%= if (present) 1 else 0;
    }
}

// -----------------------------------------------------------------------------
// Codec — encode / decode representative Values
// -----------------------------------------------------------------------------

const CodecCtx = struct {
    heap: *Heap,
    interner: *Interner,
    allocator: std.mem.Allocator,
    target: Value,
    encoded: []u8, // pre-encoded bytes for the decode benchmark
    sink: u64 = 0,
};

fn benchCodecEncodeScalar(ctx: *CodecCtx) anyerror!void {
    const bytes = try codec_mod.encode(ctx.allocator, ctx.interner, ctx.target);
    defer ctx.allocator.free(bytes);
    ctx.sink +%= bytes.len;
}

fn benchCodecDecodeScalar(ctx: *CodecCtx) anyerror!void {
    const v = try codec_mod.decode(ctx.heap, ctx.interner, ctx.encoded, &dispatch.hashValue, &dispatch.equal);
    ctx.sink +%= @as(u64, @bitCast(@as(u64, v.tag)));
}

fn benchCodecEncodeMap(ctx: *CodecCtx) anyerror!void {
    const bytes = try codec_mod.encode(ctx.allocator, ctx.interner, ctx.target);
    defer ctx.allocator.free(bytes);
    ctx.sink +%= bytes.len;
}

fn benchCodecDecodeMap(ctx: *CodecCtx) anyerror!void {
    const v = try codec_mod.decode(ctx.heap, ctx.interner, ctx.encoded, &dispatch.hashValue, &dispatch.equal);
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
        }
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
    var heap = makeHeap(heap_backing);
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
            var m = try hamt.mapEmpty(&heap);
            var s2 = try hamt.setEmpty(&heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                v = try vector_mod.conj(&heap, v, kv.vals[i]);
                m = try hamt.mapAssoc(&heap, m, kv.keys[i], kv.vals[i], &dispatch.hashValue, &dispatch.equal);
                s2 = try hamt.setConj(&heap, s2, kv.keys[i], &dispatch.hashValue, &dispatch.equal);
            }

            var lctx = LookupCtx{ .vec = v, .map = m, .set = s2, .keys = kv.keys };
            const np: i64 = @intCast(n);
            try runner.bench("vector_nth_n_sequential", "collection-lookup-update", np, &lctx, benchVectorNth);
            try runner.bench("map_get_n_hit", "collection-lookup-update", np, &lctx, benchMapGet);
            try runner.bench("set_contains_n_hit", "collection-lookup-update", np, &lctx, benchSetContains);
        }
    }

    // ---- Codec ----
    if (include(filter, "codec")) {
        // Scalar round-trip.
        {
            const v = value_mod.fromFixnum(123_456_789).?;
            const bytes = try codec_mod.encode(alloc, &interner, v);
            defer alloc.free(bytes);
            var cctx = CodecCtx{ .heap = &heap, .interner = &interner, .allocator = alloc, .target = v, .encoded = bytes };
            try runner.bench("codec_encode_fixnum", "codec", null, &cctx, benchCodecEncodeScalar);
            try runner.bench("codec_decode_fixnum", "codec", null, &cctx, benchCodecDecodeScalar);
        }
        // Map round-trip (N=64, nested values).
        {
            const n: usize = 64;
            const kv = try populateKeysAndVals(alloc, &interner, n);
            defer alloc.free(kv.keys);
            defer alloc.free(kv.vals);
            var m = try hamt.mapEmpty(&heap);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                m = try hamt.mapAssoc(&heap, m, kv.keys[i], kv.vals[i], &dispatch.hashValue, &dispatch.equal);
            }
            const bytes = try codec_mod.encode(alloc, &interner, m);
            defer alloc.free(bytes);
            var cctx = CodecCtx{ .heap = &heap, .interner = &interner, .allocator = alloc, .target = m, .encoded = bytes };
            try runner.bench("codec_encode_map_n64", "codec", 64, &cctx, benchCodecEncodeMap);
            try runner.bench("codec_decode_map_n64", "codec", 64, &cctx, benchCodecDecodeMap);
        }
    }

    // ---- DB-integrated ----
    if (include(filter, "db-integrated")) {
        // Fresh temp DB per benchmark run.
        const path: [:0]const u8 = "bench_tmp.emdb";
        _ = std.c.unlink(path.ptr);
        var lockbuf: [64]u8 = undefined;
        const lock_path = try std.fmt.bufPrintSentinel(&lockbuf, "{s}-lock", .{path}, 0);
        _ = std.c.unlink(lock_path.ptr);

        var conn = try db.open(alloc, &heap, &interner, path.ptr, .{ .allocator = alloc });
        defer {
            db.close(&conn);
            _ = std.c.unlink(path.ptr);
            _ = std.c.unlink(lock_path.ptr);
        }

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

    // ---- Output ----
    //
    // Zig 0.16 removed `std.fs.File.stdout()` in favor of an
    // Io-handle model. The simplest stable path that works across
    // 0.15/0.16 is to build the table into an ArrayList and emit
    // via std.debug.print (which targets stderr but is acceptable
    // for a bench tool's human-readable output). JSON writes go
    // to a file via the standard fs.cwd().createFile path.

    {
        std.debug.print("\n(allocator: {s})\n", .{allocator_choice});
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        try runner.writeTable(&aw.writer);
        std.debug.print("{s}", .{aw.written()});
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
