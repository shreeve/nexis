//! nexis — Build Configuration.
//!
//! Usage:
//!   zig build parser                    regenerate src/parser.zig from nexis.grammar
//!   zig build test                      run Zig-native unit + property tests (full suite, ~3min)
//!   zig build phase2-test               run only vm + compile tests (~3s, for Phase 2 iteration)
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
        .root_source_file = b.path("src/coll/vector.zig"),
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

    const champ_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/champ.zig"),
        .target = target,
        .optimize = optimize,
    });
    champ_mod.addImport("value", value_mod);
    champ_mod.addImport("heap", heap_mod);
    champ_mod.addImport("hash", hash_mod);

    const transient_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    transient_mod.addImport("value", value_mod);
    transient_mod.addImport("heap", heap_mod);
    transient_mod.addImport("champ", champ_mod);
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
    codec_mod.addImport("champ", champ_mod);
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
    gc_mod.addImport("champ", champ_mod);
    gc_mod.addImport("transient", transient_mod);

    const pool_mod = b.createModule(.{
        .root_source_file = b.path("src/pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = optimize,
    });
    vm_mod.addImport("value", value_mod);
    // Step 5e: VM owns a `Heap` (backed by its runtime_arena) for
    // variadic rest-list construction. heap+list are tiny pure-
    // allocator wrappers; pulling them in does NOT pull GC.
    vm_mod.addImport("heap", heap_mod);
    vm_mod.addImport("list", list_mod);
    // Step E1 (pre-#8): VM owns an `Interner` for quoted-symbol /
    // quoted-keyword Value construction. Per peer-AI turn 55 §K
    // (macro execution model preflight), the compile-side
    // `lowerQuotePayload` interns symbols/keywords through this
    // shared Interner so identity is stable across compile + run.
    vm_mod.addImport("intern", intern_mod);

    // Step #7a: reader exposed as a proper module so compile.zig
    // can consume `reader.Form` trees. reader.zig uses sibling-
    // file imports (`@import("parser.zig")`, `@import("nexis.zig")`)
    // which Zig resolves automatically from the file's directory,
    // so no addImport calls are needed on this module.
    const reader_mod = b.createModule(.{
        .root_source_file = b.path("src/reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Step #8a: Form → Form macro expansion (see
    // docs/MACROEXPAND.md). Lives between Reader.readOneForm
    // and lowerForm in the pipeline.
    const macroexpand_mod = b.createModule(.{
        .root_source_file = b.path("src/macroexpand.zig"),
        .target = target,
        .optimize = optimize,
    });
    macroexpand_mod.addImport("reader", reader_mod);
    macroexpand_mod.addImport("intern", intern_mod);

    const compile_mod = b.createModule(.{
        .root_source_file = b.path("src/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile_mod.addImport("vm", vm_mod);
    compile_mod.addImport("value", value_mod);
    // Step 5e: tests inspect rest-list results from variadic
    // fn calls. compile.zig core doesn't depend on list — the
    // VM constructs rest lists at call/prologue time.
    compile_mod.addImport("list", list_mod);
    // Step #7a: Form-tree input from the reader.
    compile_mod.addImport("reader", reader_mod);
    // Step E1 (pre-#8): Interner threaded through Form lowering
    // for quoted-symbol/quoted-keyword Value construction.
    // The Interner instance comes from the VM at runtime; the
    // compile-side just imports the type.
    compile_mod.addImport("intern", intern_mod);
    // Step #8a: macroexpander is consumed by compileFormFullWithMacros.
    compile_mod.addImport("macroexpand", macroexpand_mod);

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
    db_mod.addImport("champ", champ_mod);
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
    dispatch_mod.addImport("champ", champ_mod);
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
        champ: *std.Build.Module,
        transient: *std.Build.Module,
        gc: *std.Build.Module,
        codec: *std.Build.Module,
        db: *std.Build.Module,
        emdb: *std.Build.Module,
        pool: *std.Build.Module,
        vm: *std.Build.Module,
        compile: *std.Build.Module,
        reader: *std.Build.Module,
        macroexpand: *std.Build.Module,
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
        .champ = champ_mod,
        .transient = transient_mod,
        .gc = gc_mod,
        .codec = codec_mod,
        .db = db_mod,
        .emdb = emdb_mod,
        .pool = pool_mod,
        .vm = vm_mod,
        .compile = compile_mod,
        .reader = reader_mod,
        .macroexpand = macroexpand_mod,
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
        .{ .name = "vector", .path = "src/coll/vector.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "bignum", .path = "src/bignum.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "champ", .path = "src/coll/champ.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "transient", .path = "src/coll/transient.zig", .imports = &.{ "value", "heap", "champ", "vector" } },
        .{ .name = "codec", .path = "src/codec.zig", .imports = &.{ "value", "heap", "intern", "hash", "string", "bignum", "list", "vector", "champ", "transient" } },
        .{ .name = "gc", .path = "src/gc.zig", .imports = &.{ "value", "heap", "string", "bignum", "list", "vector", "champ", "transient", "db" } },
        .{ .name = "dispatch", .path = "src/dispatch.zig", .imports = &.{ "value", "eq", "heap", "hash", "string", "list", "vector", "bignum", "champ", "transient", "db" } },
        .{ .name = "db", .path = "src/db.zig", .imports = &.{ "value", "heap", "intern", "hash", "codec", "list", "champ", "emdb" } },
        .{ .name = "pool", .path = "src/pool.zig", .imports = &.{} },
        .{ .name = "vm", .path = "src/vm.zig", .imports = &.{ "value", "heap", "list", "intern" } },
        .{ .name = "compile", .path = "src/compile.zig", .imports = &.{ "vm", "value", "list", "reader", "intern", "macroexpand" } },
        .{ .name = "macroexpand", .path = "src/macroexpand.zig", .imports = &.{ "reader", "intern" } },
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
                else if (std.mem.eql(u8, imp_name, "champ")) siblings.champ
                else if (std.mem.eql(u8, imp_name, "transient")) siblings.transient
                else if (std.mem.eql(u8, imp_name, "gc")) siblings.gc
                else if (std.mem.eql(u8, imp_name, "codec")) siblings.codec
                else if (std.mem.eql(u8, imp_name, "db")) siblings.db
                else if (std.mem.eql(u8, imp_name, "emdb")) siblings.emdb
                else if (std.mem.eql(u8, imp_name, "pool")) siblings.pool
                else if (std.mem.eql(u8, imp_name, "vm")) siblings.vm
                else if (std.mem.eql(u8, imp_name, "compile")) siblings.compile
                else if (std.mem.eql(u8, imp_name, "reader")) siblings.reader
                else if (std.mem.eql(u8, imp_name, "macroexpand")) siblings.macroexpand
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

    const prop_champ_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/champ.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_champ_mod.addImport("value", value_mod);
    prop_champ_mod.addImport("heap", heap_mod);
    prop_champ_mod.addImport("hash", hash_mod);
    prop_champ_mod.addImport("champ", champ_mod);
    prop_champ_mod.addImport("list", list_mod);
    prop_champ_mod.addImport("vector", vector_mod);
    prop_champ_mod.addImport("dispatch", dispatch_mod);

    const prop_champ_tests = b.addTest(.{ .root_module = prop_champ_mod });
    const run_prop_champ_tests = b.addRunArtifact(prop_champ_tests);

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
    prop_gc_mod.addImport("champ", champ_mod);
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
    prop_transient_mod.addImport("champ", champ_mod);
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
    prop_codec_mod.addImport("champ", champ_mod);
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
    prop_db_mod.addImport("champ", champ_mod);
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
    bench_runner_mod.addImport("champ", champ_mod);
    bench_runner_mod.addImport("transient", transient_mod);
    bench_runner_mod.addImport("codec", codec_mod);
    bench_runner_mod.addImport("dispatch", dispatch_mod);
    bench_runner_mod.addImport("db", db_mod);
    bench_runner_mod.addImport("emdb", emdb_mod);
    bench_runner_mod.addImport("pool", pool_mod);

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

    // -------------------------------------------------------------------------
    // Step H1 (peer-AI turn 55): minimal CLI runner
    //
    // `zig build nexis` produces bin/nexis. `zig build run -- run foo.nx`
    // builds + runs (forwards args after `--`).
    // -------------------------------------------------------------------------

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("value", value_mod);
    cli_mod.addImport("vm", vm_mod);
    cli_mod.addImport("compile", compile_mod);
    cli_mod.addImport("reader", reader_mod);
    cli_mod.addImport("intern", intern_mod);
    cli_mod.addImport("macroexpand", macroexpand_mod);
    cli_mod.addImport("list", list_mod);

    const nexis_exe = b.addExecutable(.{
        .name = "nexis",
        .root_module = cli_mod,
    });

    const install_nexis = b.addInstallArtifact(nexis_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis",
    });

    const run_nexis = b.addRunArtifact(nexis_exe);
    if (b.args) |args| run_nexis.addArgs(args);
    run_nexis.step.dependOn(&install_nexis.step);

    const nexis_step = b.step("nexis", "Build bin/nexis (the CLI runner)");
    nexis_step.dependOn(&install_nexis.step);

    const run_step = b.step("run", "Build and run nexis (forwards args after `--`)");
    run_step.dependOn(&run_nexis.step);

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

    // -------------------------------------------------------------------------
    // `zig build phase2-test` — fast iteration target for Phase 2 work
    //
    // Runs ONLY the vm + compile module tests (currently ~187 tests in ~3s).
    // The full `zig build test` re-runs Phase 1's randomized HAMT correctness
    // gate, 10k+ collection ops, etc. — ~3min and unrelated to Phase 2
    // compiler/VM iteration. Use this step during the Phase 2 edit/test loop;
    // run the full suite before committing significant changes.
    //
    // When a new Phase 2 module lands (e.g., macroexpand.zig, resolve.zig),
    // add its entry to `runtime_test_files` AND append the corresponding
    // `runtime_test_runs[N]` to this step.
    // -------------------------------------------------------------------------

    const phase2_test_step = b.step("phase2-test", "Run only vm + compile tests (fast Phase 2 iteration)");
    // Indices into runtime_test_files: vm = 16, compile = 17,
    // macroexpand = 18. Asserted at build time so re-ordering
    // trips this loudly instead of silently running the wrong
    // tests.
    comptime {
        std.debug.assert(std.mem.eql(u8, runtime_test_files[16].name, "vm"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[17].name, "compile"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[18].name, "macroexpand"));
    }
    phase2_test_step.dependOn(&runtime_test_runs[16].step);
    phase2_test_step.dependOn(&runtime_test_runs[17].step);
    phase2_test_step.dependOn(&runtime_test_runs[18].step);

    test_step.dependOn(&run_prop_primitive_tests.step);
    test_step.dependOn(&run_prop_intern_tests.step);
    test_step.dependOn(&run_prop_heap_tests.step);
    test_step.dependOn(&run_prop_string_tests.step);
    test_step.dependOn(&run_prop_list_tests.step);
    test_step.dependOn(&run_prop_bignum_tests.step);
    test_step.dependOn(&run_prop_vector_tests.step);
    test_step.dependOn(&run_prop_champ_tests.step);
    test_step.dependOn(&run_prop_gc_tests.step);
    test_step.dependOn(&run_prop_transient_tests.step);
    test_step.dependOn(&run_prop_codec_tests.step);
    test_step.dependOn(&run_prop_db_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&run_golden.step);

    b.getInstallStep().dependOn(&install_golden.step);
    b.getInstallStep().dependOn(&install_nexis.step);
}
