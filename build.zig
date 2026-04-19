//! nexis — Build Configuration (Phase 0)
//!
//! Usage:
//!   zig build parser                    regenerate src/parser.zig from nexis.grammar
//!   zig build test                      run Zig-native unit tests
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
    // Library / test modules — only compile when the generated parser is
    // present. Phase 0 keeps scope minimal: a Zig unit test on the reader.
    // -------------------------------------------------------------------------

    // Reader unit tests (src/reader.zig has its own `test { ... }` blocks;
    // the module depends on src/nexis.zig and src/parser.zig).
    const reader_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    const reader_tests = b.addTest(.{ .root_module = reader_tests_mod });
    const run_reader_tests = b.addRunArtifact(reader_tests);

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

    // Installed to ./bin/nexis-golden so the developer can run it directly.
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
    // Aggregate `zig build test` — unit tests + golden
    // -------------------------------------------------------------------------

    const test_step = b.step("test", "Run all Phase 0 tests (unit + golden)");
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&run_golden.step);

    // Default step installs golden helper so `zig build` leaves a usable tree.
    b.getInstallStep().dependOn(&install_golden.step);
}
