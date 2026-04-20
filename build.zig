//! nexis — Build Configuration.
//!
//! Usage:
//!   zig build parser                    regenerate src/parser.zig from nexis.grammar
//!   zig build test                      run Zig-native unit + property tests
//!   zig build golden                    verify golden reader outputs (byte-exact)
//!   zig build golden -Dupdate=true      regenerate golden expected files
//!
//! The checked-in `src/parser.zig` is the authoritative artifact; the
//! `parser` step exists so contributors editing `nexis.grammar` can
//! regenerate it reproducibly.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const update_golden = b.option(bool, "update", "rewrite golden expected files in-place") orelse false;

    // External dependency: emdb (path dep per build.zig.zon).
    const emdb_dep = b.dependency("emdb", .{
        .target = target,
        .optimize = optimize,
    });
    const emdb_mod = emdb_dep.module("emdb");

    // -------------------------------------------------------------------------
    // Parser generation (via the external nexus tool at ../nexus/bin/nexus)
    // -------------------------------------------------------------------------

    const nexus_bin = b.pathJoin(&.{ b.pathFromRoot(".."), "nexus", "bin", "nexus" });
    const run_nexus = b.addSystemCommand(&.{
        nexus_bin,
        "nexis.grammar",
        "src/parser.zig",
    });
    const parser_step = b.step("parser", "Regenerate src/parser.zig from nexis.grammar");
    parser_step.dependOn(&run_nexus.step);

    // -------------------------------------------------------------------------
    // Modules exposed to tests
    //
    // Each runtime-core module gets its own standalone module handle so
    // cross-module tests (test/prop/*) can `@import("hash")` etc. without
    // relying on relative paths outside the test's own module.
    // -------------------------------------------------------------------------

    const hash_mod = b.createModule(.{
        .root_source_file = b.path("src/hash.zig"),
        .target = target,
        .optimize = optimize,
    });

    const value_mod = b.createModule(.{
        .root_source_file = b.path("src/value.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_mod.addImport("hash", hash_mod);

    const eq_mod = b.createModule(.{
        .root_source_file = b.path("src/eq.zig"),
        .target = target,
        .optimize = optimize,
    });
    eq_mod.addImport("value", value_mod);
    eq_mod.addImport("hash", hash_mod);

    const intern_mod = b.createModule(.{
        .root_source_file = b.path("src/intern.zig"),
        .target = target,
        .optimize = optimize,
    });
    intern_mod.addImport("value", value_mod);
    intern_mod.addImport("hash", hash_mod);

    const heap_mod = b.createModule(.{
        .root_source_file = b.path("src/heap.zig"),
        .target = target,
        .optimize = optimize,
    });
    heap_mod.addImport("value", value_mod);

    const string_mod = b.createModule(.{
        .root_source_file = b.path("src/string.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_mod.addImport("value", value_mod);
    string_mod.addImport("heap", heap_mod);
    string_mod.addImport("hash", hash_mod);

    const list_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/list.zig"),
        .target = target,
        .optimize = optimize,
    });
    list_mod.addImport("value", value_mod);
    list_mod.addImport("heap", heap_mod);
    list_mod.addImport("hash", hash_mod);

    const vector_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/rrb.zig"),
        .target = target,
        .optimize = optimize,
    });
    vector_mod.addImport("value", value_mod);
    vector_mod.addImport("heap", heap_mod);
    vector_mod.addImport("hash", hash_mod);

    const bignum_mod = b.createModule(.{
        .root_source_file = b.path("src/bignum.zig"),
        .target = target,
        .optimize = optimize,
    });
    bignum_mod.addImport("value", value_mod);
    bignum_mod.addImport("heap", heap_mod);
    bignum_mod.addImport("hash", hash_mod);

    const hamt_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/hamt.zig"),
        .target = target,
        .optimize = optimize,
    });
    hamt_mod.addImport("value", value_mod);
    hamt_mod.addImport("heap", heap_mod);
    hamt_mod.addImport("hash", hash_mod);

    const transient_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    transient_mod.addImport("value", value_mod);
    transient_mod.addImport("heap", heap_mod);
    transient_mod.addImport("hamt", hamt_mod);
    transient_mod.addImport("vector", vector_mod);

    const codec_mod = b.createModule(.{
        .root_source_file = b.path("src/codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    codec_mod.addImport("value", value_mod);
    codec_mod.addImport("heap", heap_mod);
    codec_mod.addImport("intern", intern_mod);
    codec_mod.addImport("hash", hash_mod);
    codec_mod.addImport("string", string_mod);
    codec_mod.addImport("bignum", bignum_mod);
    codec_mod.addImport("list", list_mod);
    codec_mod.addImport("vector", vector_mod);
    codec_mod.addImport("hamt", hamt_mod);
    // codec's inline tests import transient to exercise the
    // UnserializableKind error path for transient Values.
    codec_mod.addImport("transient", transient_mod);

    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = optimize,
    });
    gc_mod.addImport("value", value_mod);
    gc_mod.addImport("heap", heap_mod);
    gc_mod.addImport("string", string_mod);
    gc_mod.addImport("bignum", bignum_mod);
    gc_mod.addImport("list", list_mod);
    gc_mod.addImport("vector", vector_mod);
    gc_mod.addImport("hamt", hamt_mod);
    gc_mod.addImport("transient", transient_mod);

    const db_mod = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_mod.addImport("value", value_mod);
    db_mod.addImport("heap", heap_mod);
    db_mod.addImport("intern", intern_mod);
    db_mod.addImport("hash", hash_mod);
    db_mod.addImport("codec", codec_mod);
    db_mod.addImport("list", list_mod);
    db_mod.addImport("hamt", hamt_mod);
    db_mod.addImport("emdb", emdb_mod);

    gc_mod.addImport("db", db_mod);

    const dispatch_mod = b.createModule(.{
        .root_source_file = b.path("src/dispatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    dispatch_mod.addImport("value", value_mod);
    dispatch_mod.addImport("eq", eq_mod);
    dispatch_mod.addImport("heap", heap_mod);
    dispatch_mod.addImport("hash", hash_mod);
    dispatch_mod.addImport("string", string_mod);
    dispatch_mod.addImport("list", list_mod);
    dispatch_mod.addImport("vector", vector_mod);
    dispatch_mod.addImport("bignum", bignum_mod);
    dispatch_mod.addImport("hamt", hamt_mod);
    dispatch_mod.addImport("transient", transient_mod);
    dispatch_mod.addImport("db", db_mod);
    // dispatch is a one-way terminal: nothing depends on it. value
    // and eq deliberately stay low-level (panicking on heap kinds)
    // so the module graph remains acyclic and every test-binary
    // root resolves cleanly.

    // -------------------------------------------------------------------------
    // Phase 0: reader unit tests (src/reader.zig has its own test { ... }
    // blocks; depends on src/parser.zig + src/nexis.zig which live in the
    // same directory and import each other via @import("parser.zig") etc.).
    // -------------------------------------------------------------------------

    const reader_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const reader_tests = b.addTest(.{ .root_module = reader_tests_mod });
    const run_reader_tests = b.addRunArtifact(reader_tests);

    // -------------------------------------------------------------------------
    // Phase 1: runtime-core inline tests (hash, value, eq). Each file owns
    // its own `test "..."` blocks and is compiled as a standalone test
    // binary. The modules share import paths via the standalone modules
    // above.
    // -------------------------------------------------------------------------

    // Per-file test configuration. Each entry lists the sibling
    // modules the test binary needs as named imports. A file is
    // deliberately omitted from its own import list — Zig rejects a
    // source file appearing both as the test binary's `root` module
    // and as a named import of the same graph.
    const AllSiblings = struct {
        hash: *std.Build.Module,
        value: *std.Build.Module,
        eq: *std.Build.Module,
        heap: *std.Build.Module,
        intern: *std.Build.Module,
        string: *std.Build.Module,
        list: *std.Build.Module,
        vector: *std.Build.Module,
        bignum: *std.Build.Module,
        hamt: *std.Build.Module,
        transient: *std.Build.Module,
        gc: *std.Build.Module,
        codec: *std.Build.Module,
        db: *std.Build.Module,
        emdb: *std.Build.Module,
    };
    const siblings: AllSiblings = .{
        .hash = hash_mod,
        .value = value_mod,
        .eq = eq_mod,
        .heap = heap_mod,
        .intern = intern_mod,
        .string = string_mod,
        .list = list_mod,
        .vector = vector_mod,
        .bignum = bignum_mod,
        .hamt = hamt_mod,
        .transient = transient_mod,
        .gc = gc_mod,
        .codec = codec_mod,
        .db = db_mod,
        .emdb = emdb_mod,
    };

    const RuntimeTest = struct {
        name: []const u8,
        path: []const u8,
        imports: []const []const u8,
    };
    const runtime_test_files = [_]RuntimeTest{
        .{ .name = "hash", .path = "src/hash.zig", .imports = &.{} },
        .{ .name = "value", .path = "src/value.zig", .imports = &.{"hash"} },
        .{ .name = "eq", .path = "src/eq.zig", .imports = &.{ "value", "hash" } },
        .{ .name = "intern", .path = "src/intern.zig", .imports = &.{ "value", "hash" } },
        .{ .name = "heap", .path = "src/heap.zig", .imports = &.{"value"} },
        .{ .name = "string", .path = "src/string.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "list", .path = "src/coll/list.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "vector", .path = "src/coll/rrb.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "bignum", .path = "src/bignum.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "hamt", .path = "src/coll/hamt.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "transient", .path = "src/coll/transient.zig", .imports = &.{ "value", "heap", "hamt", "vector" } },
        .{ .name = "codec", .path = "src/codec.zig", .imports = &.{ "value", "heap", "intern", "hash", "string", "bignum", "list", "vector", "hamt", "transient" } },
        .{ .name = "gc", .path = "src/gc.zig", .imports = &.{ "value", "heap", "string", "bignum", "list", "vector", "hamt", "transient", "db" } },
        .{ .name = "dispatch", .path = "src/dispatch.zig", .imports = &.{ "value", "eq", "heap", "hash", "string", "list", "vector", "bignum", "hamt", "transient", "db" } },
        .{ .name = "db", .path = "src/db.zig", .imports = &.{ "value", "heap", "intern", "hash", "codec", "list", "hamt", "emdb" } },
    };

    var runtime_test_runs: [runtime_test_files.len]*std.Build.Step.Run = undefined;
    for (runtime_test_files, 0..) |f, i| {
        const m = b.createModule(.{
            .root_source_file = b.path(f.path),
            .target = target,
            .optimize = optimize,
        });
        for (f.imports) |imp_name| {
            const mod: *std.Build.Module =
                if (std.mem.eql(u8, imp_name, "hash")) siblings.hash
                else if (std.mem.eql(u8, imp_name, "value")) siblings.value
                else if (std.mem.eql(u8, imp_name, "eq")) siblings.eq
                else if (std.mem.eql(u8, imp_name, "heap")) siblings.heap
                else if (std.mem.eql(u8, imp_name, "string")) siblings.string
                else if (std.mem.eql(u8, imp_name, "list")) siblings.list
                else if (std.mem.eql(u8, imp_name, "vector")) siblings.vector
                else if (std.mem.eql(u8, imp_name, "bignum")) siblings.bignum
                else if (std.mem.eql(u8, imp_name, "intern")) siblings.intern
                else if (std.mem.eql(u8, imp_name, "hamt")) siblings.hamt
                else if (std.mem.eql(u8, imp_name, "transient")) siblings.transient
                else if (std.mem.eql(u8, imp_name, "gc")) siblings.gc
                else if (std.mem.eql(u8, imp_name, "codec")) siblings.codec
                else if (std.mem.eql(u8, imp_name, "db")) siblings.db
                else if (std.mem.eql(u8, imp_name, "emdb")) siblings.emdb
                else @panic("unknown sibling import");
            m.addImport(imp_name, mod);
        }

        const t = b.addTest(.{ .root_module = m });
        runtime_test_runs[i] = b.addRunArtifact(t);
    }

    // -------------------------------------------------------------------------
    // Property tests — cross-module sweeps over the runtime invariants.
    // -------------------------------------------------------------------------

    const prop_primitive_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/primitive.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_primitive_mod.addImport("hash", hash_mod);
    prop_primitive_mod.addImport("value", value_mod);
    prop_primitive_mod.addImport("eq", eq_mod);

    const prop_primitive_tests = b.addTest(.{ .root_module = prop_primitive_mod });
    const run_prop_primitive_tests = b.addRunArtifact(prop_primitive_tests);

    const prop_intern_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/intern.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_intern_mod.addImport("hash", hash_mod);
    prop_intern_mod.addImport("value", value_mod);
    prop_intern_mod.addImport("intern", intern_mod);

    const prop_intern_tests = b.addTest(.{ .root_module = prop_intern_mod });
    const run_prop_intern_tests = b.addRunArtifact(prop_intern_tests);

    const prop_heap_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/heap.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_heap_mod.addImport("value", value_mod);
    prop_heap_mod.addImport("heap", heap_mod);

    const prop_heap_tests = b.addTest(.{ .root_module = prop_heap_mod });
    const run_prop_heap_tests = b.addRunArtifact(prop_heap_tests);

    const prop_string_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/string.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_string_mod.addImport("value", value_mod);
    prop_string_mod.addImport("heap", heap_mod);
    prop_string_mod.addImport("hash", hash_mod);
    prop_string_mod.addImport("string", string_mod);
    prop_string_mod.addImport("dispatch", dispatch_mod);

    const prop_string_tests = b.addTest(.{ .root_module = prop_string_mod });
    const run_prop_string_tests = b.addRunArtifact(prop_string_tests);

    const prop_list_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/list.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_list_mod.addImport("value", value_mod);
    prop_list_mod.addImport("heap", heap_mod);
    prop_list_mod.addImport("hash", hash_mod);
    prop_list_mod.addImport("list", list_mod);
    prop_list_mod.addImport("dispatch", dispatch_mod);

    const prop_list_tests = b.addTest(.{ .root_module = prop_list_mod });
    const run_prop_list_tests = b.addRunArtifact(prop_list_tests);

    const prop_bignum_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/bignum.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_bignum_mod.addImport("value", value_mod);
    prop_bignum_mod.addImport("heap", heap_mod);
    prop_bignum_mod.addImport("hash", hash_mod);
    prop_bignum_mod.addImport("bignum", bignum_mod);
    prop_bignum_mod.addImport("dispatch", dispatch_mod);

    const prop_bignum_tests = b.addTest(.{ .root_module = prop_bignum_mod });
    const run_prop_bignum_tests = b.addRunArtifact(prop_bignum_tests);

    const prop_vector_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/vector.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_vector_mod.addImport("value", value_mod);
    prop_vector_mod.addImport("heap", heap_mod);
    prop_vector_mod.addImport("hash", hash_mod);
    prop_vector_mod.addImport("list", list_mod);
    prop_vector_mod.addImport("vector", vector_mod);
    prop_vector_mod.addImport("dispatch", dispatch_mod);

    const prop_vector_tests = b.addTest(.{ .root_module = prop_vector_mod });
    const run_prop_vector_tests = b.addRunArtifact(prop_vector_tests);

    const prop_hamt_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/hamt.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_hamt_mod.addImport("value", value_mod);
    prop_hamt_mod.addImport("heap", heap_mod);
    prop_hamt_mod.addImport("hash", hash_mod);
    prop_hamt_mod.addImport("hamt", hamt_mod);
    prop_hamt_mod.addImport("list", list_mod);
    prop_hamt_mod.addImport("vector", vector_mod);
    prop_hamt_mod.addImport("dispatch", dispatch_mod);

    const prop_hamt_tests = b.addTest(.{ .root_module = prop_hamt_mod });
    const run_prop_hamt_tests = b.addRunArtifact(prop_hamt_tests);

    const prop_gc_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/gc.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_gc_mod.addImport("value", value_mod);
    prop_gc_mod.addImport("heap", heap_mod);
    prop_gc_mod.addImport("hash", hash_mod);
    prop_gc_mod.addImport("string", string_mod);
    prop_gc_mod.addImport("list", list_mod);
    prop_gc_mod.addImport("vector", vector_mod);
    prop_gc_mod.addImport("hamt", hamt_mod);
    prop_gc_mod.addImport("dispatch", dispatch_mod);
    prop_gc_mod.addImport("gc", gc_mod);

    const prop_gc_tests = b.addTest(.{ .root_module = prop_gc_mod });
    const run_prop_gc_tests = b.addRunArtifact(prop_gc_tests);

    const prop_transient_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_transient_mod.addImport("value", value_mod);
    prop_transient_mod.addImport("heap", heap_mod);
    prop_transient_mod.addImport("hash", hash_mod);
    prop_transient_mod.addImport("hamt", hamt_mod);
    prop_transient_mod.addImport("vector", vector_mod);
    prop_transient_mod.addImport("transient", transient_mod);
    prop_transient_mod.addImport("dispatch", dispatch_mod);
    prop_transient_mod.addImport("gc", gc_mod);

    const prop_transient_tests = b.addTest(.{ .root_module = prop_transient_mod });
    const run_prop_transient_tests = b.addRunArtifact(prop_transient_tests);

    const prop_codec_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_codec_mod.addImport("value", value_mod);
    prop_codec_mod.addImport("heap", heap_mod);
    prop_codec_mod.addImport("hash", hash_mod);
    prop_codec_mod.addImport("intern", intern_mod);
    prop_codec_mod.addImport("string", string_mod);
    prop_codec_mod.addImport("bignum", bignum_mod);
    prop_codec_mod.addImport("list", list_mod);
    prop_codec_mod.addImport("vector", vector_mod);
    prop_codec_mod.addImport("hamt", hamt_mod);
    prop_codec_mod.addImport("transient", transient_mod);
    prop_codec_mod.addImport("codec", codec_mod);
    prop_codec_mod.addImport("dispatch", dispatch_mod);

    const prop_codec_tests = b.addTest(.{ .root_module = prop_codec_mod });
    const run_prop_codec_tests = b.addRunArtifact(prop_codec_tests);

    const prop_db_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_db_mod.addImport("value", value_mod);
    prop_db_mod.addImport("heap", heap_mod);
    prop_db_mod.addImport("hash", hash_mod);
    prop_db_mod.addImport("intern", intern_mod);
    prop_db_mod.addImport("string", string_mod);
    prop_db_mod.addImport("bignum", bignum_mod);
    prop_db_mod.addImport("list", list_mod);
    prop_db_mod.addImport("vector", vector_mod);
    prop_db_mod.addImport("hamt", hamt_mod);
    prop_db_mod.addImport("codec", codec_mod);
    prop_db_mod.addImport("db", db_mod);
    prop_db_mod.addImport("dispatch", dispatch_mod);

    const prop_db_tests = b.addTest(.{ .root_module = prop_db_mod });
    const run_prop_db_tests = b.addRunArtifact(prop_db_tests);

    // -------------------------------------------------------------------------
    // Benchmark harness (src/bench.zig) + benchmark runner (bench/main.zig).
    //
    // `zig build bench` produces + runs a ReleaseFast binary that
    // writes a table to stdout and (via --out) baseline JSON.
    //
    // The harness file is also compiled as a runtime test binary
    // so its inline tests (Stats, Runner) run under `zig build test`.
    // -------------------------------------------------------------------------

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_runner_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        // Bench runs in ReleaseFast so the numbers are
        // meaningful. Override with `-Doptimize=Debug` if the
        // intent is to sanity-check the bench plumbing itself.
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
    });
    bench_runner_mod.addImport("bench", bench_mod);
    bench_runner_mod.addImport("value", value_mod);
    bench_runner_mod.addImport("heap", heap_mod);
    bench_runner_mod.addImport("intern", intern_mod);
    bench_runner_mod.addImport("hash", hash_mod);
    bench_runner_mod.addImport("string", string_mod);
    bench_runner_mod.addImport("list", list_mod);
    bench_runner_mod.addImport("vector", vector_mod);
    bench_runner_mod.addImport("hamt", hamt_mod);
    bench_runner_mod.addImport("transient", transient_mod);
    bench_runner_mod.addImport("codec", codec_mod);
    bench_runner_mod.addImport("dispatch", dispatch_mod);
    bench_runner_mod.addImport("db", db_mod);
    bench_runner_mod.addImport("emdb", emdb_mod);

    const bench_exe = b.addExecutable(.{
        .name = "nexis-bench",
        .root_module = bench_runner_mod,
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis-bench",
    });

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    run_bench.step.dependOn(&install_bench.step);

    const bench_step = b.step("bench", "Run baseline benchmark suite (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const bench_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_tests = b.addTest(.{ .root_module = bench_tests_mod });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    // -------------------------------------------------------------------------
    // Golden test runner (src/golden.zig)
    // -------------------------------------------------------------------------

    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/golden.zig"),
        .target = target,
        .optimize = optimize,
    });
    const golden_exe = b.addExecutable(.{
        .name = "nexis-golden",
        .root_module = golden_mod,
    });

    const install_golden = b.addInstallArtifact(golden_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis-golden",
    });

    const run_golden = b.addRunArtifact(golden_exe);
    run_golden.addArg(if (update_golden) "--update" else "--verify");
    run_golden.addArg("test/golden");
    run_golden.step.dependOn(&install_golden.step);

    const golden_step = b.step("golden", "Run reader golden tests");
    golden_step.dependOn(&run_golden.step);

    // -------------------------------------------------------------------------
    // Aggregate `zig build test` — unit + property + golden
    // -------------------------------------------------------------------------

    const test_step = b.step("test", "Run all Phase 0/1 tests (unit + property + golden)");
    for (runtime_test_runs) |r| test_step.dependOn(&r.step);
    test_step.dependOn(&run_prop_primitive_tests.step);
    test_step.dependOn(&run_prop_intern_tests.step);
    test_step.dependOn(&run_prop_heap_tests.step);
    test_step.dependOn(&run_prop_string_tests.step);
    test_step.dependOn(&run_prop_list_tests.step);
    test_step.dependOn(&run_prop_bignum_tests.step);
    test_step.dependOn(&run_prop_vector_tests.step);
    test_step.dependOn(&run_prop_hamt_tests.step);
    test_step.dependOn(&run_prop_gc_tests.step);
    test_step.dependOn(&run_prop_transient_tests.step);
    test_step.dependOn(&run_prop_codec_tests.step);
    test_step.dependOn(&run_prop_db_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&run_golden.step);

    b.getInstallStep().dependOn(&install_golden.step);
}
