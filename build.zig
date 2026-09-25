//! nexis — build configuration.
//!
//! Steps:
//!   zig build install                 bin/nexis and bin/nexis-golden
//!   zig build test                    the gate: unit, property, integration and
//!                                     Nextomic corpora, goldens, test/nextomic
//!                                     scripts, examples
//!   zig build quick                   the inner loop: unit tests, the compile and
//!                                     Nextomic property tests, the eval corpora
//!   zig build nextomic-test           Nextomic unit, property and corpus tests
//!   zig build nextomic-nx             test/nextomic/*.nx through bin/nexis
//!   zig build examples                every examples/*.nx through bin/nexis
//!   zig build golden [-Dupdate=true]  reader and CLI goldens (byte-exact)
//!   zig build bench [-- ARGS]         the benchmark suite, ReleaseFast
//!   zig build run -- ARGS             build and run bin/nexis
//!   zig build parser                  regenerate src/parser.zig from nexis.grammar
//!
//! The runtime is one module, `nexis`, rooted at src/root.zig; its files
//! import each other by relative path. `checkLayering` below enforces the
//! import order src/root.zig declares. The checked-in src/parser.zig is
//! authoritative; `parser` regenerates it after an edit to nexis.grammar.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const update = b.option(bool, "update", "rewrite the expected-output files the gate compares, instead of comparing") orelse false;

    const nexis = runtime(b, target, optimize);

    const test_step = b.step("test", "Run everything: unit, property, golden, Nextomic corpora, test/nextomic scripts, examples");
    const quick_step = b.step("quick", "The inner loop: unit tests, compile and Nextomic property tests, eval corpora");
    const nextomic_test_step = b.step("nextomic-test", "Nextomic unit tests, key and transaction property tests, and the Nextomic corpora");

    if (checkLayering(b)) |message| {
        const fail = b.addFail(message);
        test_step.dependOn(&fail.step);
        quick_step.dependOn(&fail.step);
    }

    // Parser generation, through the external nexus tool at ../nexus/bin/nexus.
    const nexus_bin = b.pathJoin(&.{ b.pathFromRoot(".."), "nexus", "bin", "nexus" });
    const run_nexus = b.addSystemCommand(&.{ nexus_bin, "nexis.grammar", "src/parser.zig" });
    run_nexus.setCwd(b.path("."));
    b.step("parser", "Regenerate src/parser.zig from nexis.grammar").dependOn(&run_nexus.step);

    // Every inline `test` block of the runtime, in one binary.
    // Every test binary runs from the build root, so the stores its
    // tests create under .zig-cache/tmp/ land in the build's cache
    // whatever directory `zig build` started in.
    const unit = b.addRunArtifact(b.addTest(.{ .name = "unit", .root_module = nexis }));
    unit.setCwd(b.path("."));
    test_step.dependOn(&unit.step);
    quick_step.dependOn(&unit.step);
    // The Nextomic subset, compiled only when `nextomic-test` runs alone.
    const nextomic_unit = b.addRunArtifact(b.addTest(.{
        .name = "nextomic-unit",
        .root_module = nexis,
        .filters = &.{"nextomic"},
    }));
    nextomic_unit.setCwd(b.path("."));
    nextomic_test_step.dependOn(&nextomic_unit.step);

    // Property and integration binaries: one per file, so they run in parallel.
    const Suite = struct { path: []const u8, quick: bool = false, nextomic: bool = false };
    const suites = [_]Suite{
        .{ .path = "test/prop/primitive.zig" },
        .{ .path = "test/prop/intern.zig" },
        .{ .path = "test/prop/heap.zig" },
        .{ .path = "test/prop/string.zig" },
        .{ .path = "test/prop/list.zig" },
        .{ .path = "test/prop/bignum.zig" },
        .{ .path = "test/prop/vector.zig" },
        .{ .path = "test/prop/champ.zig" },
        .{ .path = "test/prop/gc.zig" },
        .{ .path = "test/prop/transient.zig" },
        .{ .path = "test/prop/codec.zig" },
        .{ .path = "test/prop/typed_vector.zig" },
        .{ .path = "test/prop/db.zig" },
        .{ .path = "test/prop/compile.zig", .quick = true },
        .{ .path = "test/prop/nextomic_key.zig", .quick = true, .nextomic = true },
        .{ .path = "test/prop/nextomic_tx.zig", .quick = true, .nextomic = true },
        .{ .path = "test/integration/eval_pipeline.zig", .quick = true },
        .{ .path = "test/integration/runtime_polish.zig", .quick = true },
        .{ .path = "test/integration/numbers.zig", .quick = true },
        .{ .path = "test/integration/nextomic_q.zig", .nextomic = true },
        .{ .path = "test/integration/nextomic_pull.zig", .nextomic = true },
        .{ .path = "test/integration/nextomic_fn.zig", .nextomic = true },
        .{ .path = "test/integration/nextomic_entity.zig", .nextomic = true },
    };
    const harness = b.createModule(.{
        .root_source_file = b.path("test/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness.addImport("nexis", nexis);
    for (suites) |suite| {
        const module = b.createModule(.{
            .root_source_file = b.path(suite.path),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("nexis", nexis);
        module.addImport("harness", harness);
        const name = std.fs.path.stem(suite.path);
        const run = b.addRunArtifact(b.addTest(.{ .name = name, .root_module = module }));
        run.setCwd(b.path("."));
        test_step.dependOn(&run.step);
        if (suite.quick) quick_step.dependOn(&run.step);
        if (suite.nextomic) nextomic_test_step.dependOn(&run.step);
    }

    // bin/nexis, the CLI.
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("emdb", emdbModule(b, target, optimize));
    const nexis_exe = b.addExecutable(.{ .name = "nexis", .root_module = cli_mod });
    const install_nexis = b.addInstallArtifact(nexis_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis",
    });
    b.getInstallStep().dependOn(&install_nexis.step);
    b.step("nexis", "Build bin/nexis (the CLI runner)").dependOn(&install_nexis.step);
    const run_nexis = b.addRunArtifact(nexis_exe);
    if (b.args) |args| run_nexis.addArgs(args);
    run_nexis.step.dependOn(&install_nexis.step);
    b.step("run", "Build and run nexis (forwards args after `--`)").dependOn(&run_nexis.step);

    // The benchmark runner. Its runtime is optimized too, so the numbers
    // measure release code; `-Doptimize=ReleaseSafe` and the like apply.
    const bench_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = bench_optimize,
    });
    bench_mod.addImport("nexis", runtime(b, target, bench_optimize));
    const bench_exe = b.addExecutable(.{ .name = "nexis-bench", .root_module = bench_mod });
    const install_bench = b.addInstallArtifact(bench_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis-bench",
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    run_bench.step.dependOn(&install_bench.step);
    b.step("bench", "Run the benchmark suite (ReleaseFast)").dependOn(&run_bench.step);

    // -------------------------------------------------------------------------
    // Programs through bin/nexis, their output pinned byte for byte.
    // `-Dupdate=true` rewrites every expected file instead of comparing.
    // -------------------------------------------------------------------------

    const scripts: Scripts = .{ .b = b, .exe = nexis_exe, .update = update };

    // test/nextomic/*.nx: each script's stdout against its `.out`
    // (NEXTOMIC.md §8), run from a fresh directory that holds the
    // stores it creates; `prelude.nx` is found beside the script.
    // `<name>-2.nx` reads what `<name>-1.nx` wrote, from the same
    // directory. Every script runs with a collection every few
    // kilobytes (NEXIS_GC_STRESS), so a rooting gap in a native the
    // scripts reach fails the gate rather than a later program.
    const nextomic_nx_step = b.step("nextomic-nx", "Run the test/nextomic end-to-end scripts through bin/nexis");
    for (listStems(b, "test/nextomic", ".nx")) |name| {
        if (std.mem.eql(u8, name, "prelude") or std.mem.endsWith(u8, name, "-2")) continue;
        const pair: []const []const u8 = if (std.mem.endsWith(u8, name, "-1"))
            &.{ name, b.fmt("{s}-2", .{name[0 .. name.len - 2]}) }
        else
            &.{name};
        var inputs: std.ArrayList(std.Build.LazyPath) = .empty;
        inputs.append(b.allocator, b.path("test/nextomic/prelude.nx")) catch @panic("OOM");
        for (pair) |n| {
            inputs.append(b.allocator, b.path(b.fmt("test/nextomic/{s}.nx", .{n}))) catch @panic("OOM");
            inputs.append(b.allocator, b.path(b.fmt("test/nextomic/{s}.out", .{n}))) catch @panic("OOM");
        }
        const cwd = scripts.freshDir(inputs.items);
        var previous: ?*std.Build.Step = null;
        for (pair) |n| {
            const run = scripts.run(nextomic_nx_step, b.fmt("test/nextomic/{s}.nx", .{n}), cwd, b.fmt("test/nextomic/{s}.out", .{n}));
            run.setEnvironmentVariable("NEXIS_GC_STRESS", "1");
            if (previous) |p| run.step.dependOn(p);
            previous = &run.step;
        }
    }
    test_step.dependOn(nextomic_nx_step);

    // examples/*.nx: each example's stdout against
    // test/examples/<name>.out, from a fresh directory (the
    // store-backed ones write under tmp/ in it). An example with a
    // `<name>.2.out` runs again in the same directory, proving it
    // idempotent over the store it left.
    const examples_step = b.step("examples", "Run every examples/*.nx through bin/nexis");
    const example_libs = listFiles(b, "examples/lib");
    for (listStems(b, "examples", ".nx")) |name| {
        const script = b.fmt("examples/{s}.nx", .{name});
        const first = b.fmt("test/examples/{s}.out", .{name});
        const second = b.fmt("test/examples/{s}.2.out", .{name});
        const twice = exists(b, second);
        var inputs: std.ArrayList(std.Build.LazyPath) = .empty;
        inputs.append(b.allocator, b.path(script)) catch @panic("OOM");
        inputs.append(b.allocator, b.path(first)) catch @panic("OOM");
        if (twice) inputs.append(b.allocator, b.path(second)) catch @panic("OOM");
        for (example_libs) |lib| inputs.append(b.allocator, b.path(lib)) catch @panic("OOM");
        const cwd = scripts.freshDir(inputs.items);
        const run = scripts.run(examples_step, script, cwd, first);
        if (twice) scripts.run(examples_step, script, cwd, second).step.dependOn(&run.step);
    }
    test_step.dependOn(examples_step);

    // Goldens: the reader's Form output (src/golden.zig) and the CLI.
    const golden_exe = b.addExecutable(.{
        .name = "nexis-golden",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/golden.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_golden = b.addInstallArtifact(golden_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis-golden",
    });
    b.getInstallStep().dependOn(&install_golden.step);

    const golden_step = b.step("golden", "Run the reader and CLI goldens");
    test_step.dependOn(golden_step);
    const run_golden = b.addRunArtifact(golden_exe);
    run_golden.addArg(if (update) "--update" else "--verify");
    run_golden.addArg("test/golden");
    run_golden.setCwd(b.path("."));
    if (update) run_golden.has_side_effects = true else run_golden.expectExitCode(0);
    for (listFiles(b, "test/golden")) |path| run_golden.addFileInput(b.path(path));
    for (listFiles(b, "test/golden/errors")) |path| run_golden.addFileInput(b.path(path));
    golden_step.dependOn(&run_golden.step);

    // test/golden/cli: what bin/nexis prints, pinned byte for byte: a
    // runtime error's stderr (exit 5), a reader error's stderr (exit
    // 3), a disassembly, scripts' stdout (with arguments, from stdin,
    // an explicit exit status), `nexis test`, a REPL session and the
    // usage errors. Each runs from the build root, so the paths in
    // the output are the relative ones committed.
    {
        const CliGolden = struct {
            args: []const []const u8,
            /// The expected-output files each stream is pinned to.
            stdout: ?[]const u8 = null,
            stderr: ?[]const u8 = null,
            exit_code: u8 = 0,
            stdin: ?[]const u8 = null,
        };
        const cli = "test/golden/cli/";
        const cases = [_]CliGolden{
            .{ .args = &.{ "run", cli ++ "divide-by-zero.nx" }, .stderr = "divide-by-zero.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "uncaught-throw.nx" }, .stderr = "uncaught-throw.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "require-runtime-error.nx" }, .stderr = "require-runtime-error.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "bad-number.nx" }, .stderr = "bad-number.err", .exit_code = 3 },
            .{ .args = &.{ "run", cli ++ "duplicate-key.nx" }, .stderr = "duplicate-key.err", .exit_code = 3 },
            .{ .args = &.{ "disasm", "examples/sum10.nx" }, .stdout = "sum10.disasm" },
            .{ .args = &.{ "run", cli ++ "pprint.nx" }, .stdout = "pprint.out" },
            .{ .args = &.{ "run", cli ++ "deep-recursion.nx" }, .stdout = "deep-recursion.out" },
            .{ .args = &.{ "run", cli ++ "args.nx", "a", "b c" }, .stdout = "args.out" },
            .{ .args = &.{ "run", cli ++ "exit-status.nx" }, .stdout = "exit-status.out", .exit_code = 3 },
            .{ .args = &.{ "run", "-", "x" }, .stdin = "stdin.in", .stdout = "stdin.out" },
            .{ .args = &.{ "test", cli ++ "tests.nx" }, .stdout = "tests.out", .exit_code = 1 },
            .{ .args = &.{"repl"}, .stdin = "repl.in", .stdout = "repl.out", .stderr = "repl.err" },
            .{ .args = &.{"--help"}, .stderr = "help.err" },
            .{ .args = &.{}, .stderr = "help.err", .exit_code = 1 },
            .{ .args = &.{"frobnicate"}, .stderr = "unknown-command.err", .exit_code = 1 },
        };
        for (cases) |case| {
            const run = b.addRunArtifact(nexis_exe);
            run.setCwd(b.path("."));
            run.addArgs(case.args);
            for (case.args) |arg| {
                if (std.mem.endsWith(u8, arg, ".nx")) run.addFileInput(b.path(arg));
            }
            run.addFileInput(b.path(cli ++ "lib/failing.nx"));
            if (case.stdin) |stdin| run.setStdIn(.{ .lazy_path = b.path(b.fmt(cli ++ "{s}", .{stdin})) });
            run.expectExitCode(case.exit_code);
            if (case.stdout) |file| scripts.pin(golden_step, run, b.fmt(cli ++ "{s}", .{file}), .stdout);
            if (case.stderr) |file| scripts.pin(golden_step, run, b.fmt(cli ++ "{s}", .{file}), .stderr);
        }
    }
}

/// Programs run through bin/nexis with their output compared to, or
/// under `-Dupdate=true` written to, a file in the tree.
const Scripts = struct {
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    update: bool,

    /// A directory emptied on every build, for a program to use as its
    /// working directory: the stores a run leaves, including a failed
    /// run's, never reach the next run. Its path follows `inputs` and
    /// the binary.
    fn freshDir(self: Scripts, inputs: []const std.Build.LazyPath) std.Build.LazyPath {
        const mk = self.b.addSystemCommand(&.{ "sh", "-c", "rm -rf \"$1\" && mkdir -p \"$1\"", "fresh-dir" });
        mk.has_side_effects = true;
        const dir = mk.addOutputDirectoryArg("cwd");
        mk.addFileInput(self.exe.getEmittedBin());
        for (inputs) |input| {
            // An expected file not written yet is no input.
            if (input == .src_path and !exists(self.b, input.src_path.sub_path)) continue;
            mk.addFileInput(input);
        }
        mk.expectExitCode(0);
        return dir;
    }

    /// `nexis run script` from `cwd`, its stdout pinned to `expected`.
    fn run(self: Scripts, step: *std.Build.Step, script: []const u8, cwd: std.Build.LazyPath, expected: []const u8) *std.Build.Step.Run {
        const r = self.b.addRunArtifact(self.exe);
        r.addArg("run");
        r.addFileArg(self.b.path(script));
        r.setCwd(cwd);
        r.expectExitCode(0);
        self.pin(step, r, expected, .stdout);
        return r;
    }

    /// Make `step` compare `r`'s `stream` with the file at `path`, or
    /// rewrite the file. A missing file fails the step, not the
    /// configure.
    fn pin(self: Scripts, step: *std.Build.Step, r: *std.Build.Step.Run, path: []const u8, stream: enum { stdout, stderr }) void {
        const b = self.b;
        if (self.update) {
            const captured = switch (stream) {
                .stdout => r.captureStdOut(.{}),
                .stderr => r.captureStdErr(.{}),
            };
            const usf = b.addUpdateSourceFiles();
            usf.addCopyFileToSource(captured, path);
            step.dependOn(&usf.step);
            return;
        }
        step.dependOn(&r.step);
        const expected = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20)) catch |err| {
            r.step.dependOn(&b.addFail(b.fmt("{s}: {t} (write it with -Dupdate=true)", .{ path, err })).step);
            return;
        };
        switch (stream) {
            .stdout => r.expectStdOutEqual(expected),
            .stderr => r.expectStdErrEqual(expected),
        }
    }
};

/// The names under `dir` (relative to the build root) ending in `ext`,
/// without it, sorted.
fn listStems(b: *std.Build, dir: []const u8, ext: []const u8) []const []const u8 {
    var stems: std.ArrayList([]const u8) = .empty;
    for (listFiles(b, dir)) |path| {
        const base = std.fs.path.basename(path);
        if (std.mem.endsWith(u8, base, ext))
            stems.append(b.allocator, base[0 .. base.len - ext.len]) catch @panic("OOM");
    }
    return stems.items;
}

/// The paths of the files directly under `dir`, sorted.
fn listFiles(b: *std.Build, dir: []const u8) []const []const u8 {
    const io = b.graph.io;
    var handle = b.build_root.handle.openDir(io, dir, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ dir, err });
    defer handle.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    var it = handle.iterate();
    while (it.next(io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ dir, err })) |entry| {
        if (entry.kind != .file) continue;
        paths.append(b.allocator, b.pathJoin(&.{ dir, entry.name })) catch @panic("OOM");
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return paths.items;
}

fn exists(b: *std.Build, path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, path, .{}) catch return false;
    return true;
}

/// The `nexis` module: the whole runtime, rooted at src/root.zig.
fn runtime(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("emdb", emdbModule(b, target, optimize));
    return module;
}

/// emdb, the storage engine: a path dependency on the sibling checkout.
fn emdbModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.dependency("emdb", .{ .target = target, .optimize = optimize }).module("emdb");
}

/// Check every `@import` under src/ against the layering src/root.zig
/// declares (PLAN §5, docs/FORMS.md §4). Returns a message naming the
/// first violation, or null.
///
/// - src/root.zig declares the runtime files bottom-up; a file may import
///   only files declared above it. That keeps the graph acyclic and the
///   stages in order: reader, then expand, then compile, with the VM,
///   dispatch and the value layer below all three.
/// - A unit is one declared file plus the files it owns: src/parser.zig
///   and src/nexis.zig belong to src/reader.zig, and every file under
///   src/nextomic/ except handle.zig to src/nextomic/root.zig. Imports
///   inside a unit are free.
/// - Only src/stdlib.zig (and src/root.zig) import the Nextomic unit.
/// - src/cli.zig and src/golden.zig are executable roots above
///   everything; every other file must be declared, so its tests run.
fn checkLayering(b: *std.Build) ?[]const u8 {
    const io = b.graph.io;
    const gpa = b.allocator;
    var src = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch |err|
        return b.fmt("layering: cannot open src/: {t}", .{err});
    defer src.close(io);

    const root_text = src.readFileAlloc(io, "root.zig", gpa, .limited(1 << 20)) catch |err|
        return b.fmt("layering: cannot read src/root.zig: {t}", .{err});
    var rank: std.StringHashMapUnmanaged(usize) = .empty;
    var lines = std.mem.splitScalar(u8, root_text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pub const ")) continue;
        const path = importPath(line) orelse continue;
        if (std.mem.endsWith(u8, path, ".zig")) rank.put(gpa, path, rank.count()) catch @panic("OOM");
    }

    var walker = src.walk(gpa) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| return b.fmt("layering: walking src/: {t}", .{err})) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const file = b.dupe(entry.path);
        if (std.mem.eql(u8, file, "root.zig")) continue;
        const from = layerUnit(file);
        const from_rank = rank.get(from) orelse if (isExecutableRoot(file))
            std.math.maxInt(usize)
        else
            return b.fmt("layering: src/{s} is not declared in src/root.zig", .{file});

        const text = src.readFileAlloc(io, file, gpa, .limited(1 << 24)) catch |err|
            return b.fmt("layering: cannot read src/{s}: {t}", .{ file, err });
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "//")) continue;
            const rel = importPath(line) orelse continue;
            if (!std.mem.endsWith(u8, rel, ".zig")) continue;
            const dir = std.fs.path.dirnamePosix(file) orelse "";
            const target = std.fs.path.resolvePosix(gpa, &.{ dir, rel }) catch @panic("OOM");
            const to = layerUnit(target);
            if (std.mem.eql(u8, to, from)) continue;
            if (std.mem.eql(u8, to, "nextomic/root.zig") and !std.mem.eql(u8, from, "stdlib.zig"))
                return b.fmt("layering: src/{s} imports Nextomic ({s}); only stdlib.zig does", .{ file, rel });
            const to_rank = rank.get(to) orelse
                return b.fmt("layering: src/{s} imports {s}, which src/root.zig does not declare", .{ file, rel });
            if (to_rank >= from_rank)
                return b.fmt("layering: src/{s} imports {s}, which src/root.zig declares above it", .{ file, rel });
        }
    }
    return null;
}

/// The path inside the first `@import("...")` on a line.
fn importPath(line: []const u8) ?[]const u8 {
    const open = "@import(\"";
    const start = (std.mem.indexOf(u8, line, open) orelse return null) + open.len;
    const len = std.mem.indexOfScalar(u8, line[start..], '"') orelse return null;
    return line[start..][0..len];
}

fn layerUnit(file: []const u8) []const u8 {
    if (std.mem.eql(u8, file, "parser.zig") or std.mem.eql(u8, file, "nexis.zig")) return "reader.zig";
    if (std.mem.startsWith(u8, file, "nextomic/") and !std.mem.eql(u8, file, "nextomic/handle.zig"))
        return "nextomic/root.zig";
    return file;
}

fn isExecutableRoot(file: []const u8) bool {
    return std.mem.eql(u8, file, "cli.zig") or std.mem.eql(u8, file, "golden.zig");
}
