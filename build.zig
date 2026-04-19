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
        string: *std.Build.Module,
    };
    const siblings: AllSiblings = .{
        .hash = hash_mod,
        .value = value_mod,
        .eq = eq_mod,
        .heap = heap_mod,
        .string = string_mod,
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
        .{ .name = "dispatch", .path = "src/dispatch.zig", .imports = &.{ "value", "eq", "heap", "hash", "string" } },
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
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&run_golden.step);

    b.getInstallStep().dependOn(&install_golden.step);
}
