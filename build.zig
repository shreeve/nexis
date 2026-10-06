//! nexis — build configuration.
//!
//! Steps:
//!   zig build [install]               bin/nexis (`--prefix DIR`: DIR/bin/nexis)
//!   zig build test                    the gate: unit, property, integration and
//!                                     Nextomic corpora, goldens, test/nextomic
//!                                     scripts, examples; analyzes the bench
//!   zig build test -Dgc-stress        the gate with a collection every few kilobytes
//!   zig build test -Ddurability=durable  the gate with every store commit synced
//!   zig build install -Dopcodes=true  bin/nexis printing its dispatch and native
//!                                     call counts at exit (docs/TOOLING.md §1)
//!   zig build quick                   the inner loop: unit tests, the compile and
//!                                     Nextomic property tests, the eval corpora
//!   zig build nextomic-test           Nextomic unit, property and corpus tests
//!   zig build nextomic-nx             test/nextomic/*.nx through bin/nexis
//!   zig build examples                every examples/*.nx through bin/nexis
//!   zig build golden [-Dupdate=true]  reader and CLI goldens (byte-exact)
//!   zig build nexis                   bin/nexis alone
//!   zig build bench [-- ARGS]         the benchmark suite, optimized for speed
//!   zig build run -- ARGS             build and run bin/nexis
//!   zig build parser                  regenerate src/parser.zig from nexis.grammar
//!   zig build parser-check            diff src/parser.zig against a fresh generation
//!                                     (part of `test` when nexus is present)
//!   zig build check-targets           compile and link every binary for Linux
//!                                     (x86_64 and aarch64, glibc and musl)
//!
//! The runtime is one module, `nexis`, rooted at src/root.zig; its files
//! import each other by relative path. `checkLayering` below enforces the
//! import order src/root.zig declares. The checked-in src/parser.zig is
//! authoritative; `parser` regenerates it after an edit to nexis.grammar,
//! with the nexus at ../nexus/bin/nexus or `-Dnexus=PATH`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const update = b.option(bool, "update", "rewrite the expected-output files the gate compares, instead of comparing") orelse false;
    const env: RunEnv = .{
        .gc_stress = b.option(bool, "gc-stress", "run every test and program with a collection every few kilobytes (NEXIS_GC_STRESS)") orelse false,
        .durability = b.option(RunEnv.Durability, "durability", "the durability of every store commit the tests and programs make (NEXIS_DURABILITY)"),
    };

    const nexis = runtime(b, target, optimize);

    const test_step = b.step("test", "Run everything: unit, property, golden, Nextomic corpora, test/nextomic scripts, examples");
    const quick_step = b.step("quick", "The inner loop: unit tests, compile and Nextomic property tests, eval corpora");
    const nextomic_test_step = b.step("nextomic-test", "Nextomic unit tests, key and transaction property tests, and the Nextomic corpora");

    if (checkLayering(b)) |message| {
        const fail = b.addFail(message);
        test_step.dependOn(&fail.step);
        quick_step.dependOn(&fail.step);
    }
    // The tests of this file: the import scanner `checkLayering` uses.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "build",
        .root_module = b.createModule(.{ .root_source_file = b.path("build.zig"), .target = target, .optimize = optimize }),
    })).step);

    // Parser generation, through the external nexus tool at ../nexus/bin/nexus.
    const nexus_bin = b.option([]const u8, "nexus", "the nexus parser generator (default ../nexus/bin/nexus)") orelse
        b.pathResolve(&.{ rootPath(b), "..", "nexus", "bin", "nexus" });
    const run_nexus = b.addSystemCommand(&.{ nexus_bin, "nexis.grammar", "src/parser.zig" });
    run_nexus.setCwd(b.path("."));
    b.step("parser", "Regenerate src/parser.zig from nexis.grammar").dependOn(&run_nexus.step);
    // The committed src/parser.zig against a generation into the cache;
    // the gate runs it whenever nexus is there to run. The build
    // notices a nexus built after it last looked.
    const parser_check_step = b.step("parser-check", "Fail when src/parser.zig differs from what nexus generates from nexis.grammar");
    if (std.Io.Dir.cwd().access(b.graph.io, nexus_bin, .{})) |_| {
        b.dependOnFileMetadata(.{ .cwd_relative = nexus_bin });
        const generate = b.addSystemCommand(&.{nexus_bin});
        generate.addFileArg2(b.path("nexis.grammar"), .{});
        const generated = generate.addOutputFileArg2("parser.zig", .{});
        generate.addFileInput(.{ .cwd_relative = nexus_bin });
        generate.expectExitCode(0);
        _ = generate.captureStdOut(.{});
        _ = generate.captureStdErr(.{});
        const compare = b.addSystemCommand(&.{ "sh", "-c", "diff -u \"$1\" \"$2\" >&2 || { echo 'src/parser.zig is stale: run zig build parser' >&2; exit 1; }", "parser-check" });
        compare.addFileArg2(b.path("src/parser.zig"), .{});
        compare.addFileArg2(generated, .{});
        compare.expectExitCode(0);
        parser_check_step.dependOn(&compare.step);
        test_step.dependOn(&compare.step);
    } else |_| {
        b.graph.poisonCache();
        const skip = b.addSystemCommand(&.{ "echo", b.fmt("parser-check: skipped, no nexus at {s}", .{nexus_bin}) });
        parser_check_step.dependOn(&skip.step);
    }

    const suites = listSuites(b);
    const bins = binaries(b, target, optimize, nexis, suites);

    // Every inline `test` block of the runtime, in one binary.
    // Every test binary runs from the build root, so the stores its
    // tests create under .zig-cache/tmp/ land in the build's cache
    // whatever directory `zig build` started in.
    const unit = b.addRunArtifact(bins.unit);
    unit.setCwd(b.path("."));
    env.apply(unit, env.gc_stress);
    test_step.dependOn(&unit.step);
    quick_step.dependOn(&unit.step);
    // The inline tests of src/cli.zig, an executable root the runtime
    // module does not reach.
    const cli_unit = b.addRunArtifact(bins.cli_unit);
    test_step.dependOn(&cli_unit.step);
    quick_step.dependOn(&cli_unit.step);
    // The Nextomic subset, compiled only when `nextomic-test` runs alone.
    const nextomic_unit = b.addRunArtifact(b.addTest(.{
        .name = "nextomic-unit",
        .root_module = nexis,
        .filters = &.{"nextomic"},
        .use_llvm = useLlvm(target),
    }));
    nextomic_unit.setCwd(b.path("."));
    env.apply(nextomic_unit, env.gc_stress);
    nextomic_test_step.dependOn(&nextomic_unit.step);

    // Property and integration binaries: one per file, so they run in parallel.
    for (suites, bins.suites) |suite, compile| {
        const run = b.addRunArtifact(compile);
        run.setCwd(b.path("."));
        env.apply(run, env.gc_stress);
        test_step.dependOn(&run.step);
        if (suite.quick) quick_step.dependOn(&run.step);
        if (suite.nextomic) nextomic_test_step.dependOn(&run.step);
    }

    // Every native binary the gate runs, compiled and not run, so a
    // caller can give the compile phase a share of the machine of its
    // own and run the single-threaded tests on less.
    const compile_step = b.step("compile", "Compile every binary and test binary the gate runs, without running them");
    const gate_bins = [_]*std.Build.Step.Compile{ bins.nexis, bins.golden, bins.bench, bins.unit, bins.cli_unit };
    for ([_][]const *std.Build.Step.Compile{ &gate_bins, bins.suites }) |set| for (set) |compile| {
        _ = compile.getEmittedBin();
        compile_step.dependOn(&compile.step);
    };

    // bin/nexis, the CLI. `run` and `bench` are never cached (they
    // take the arguments after `--`), so they keep the caller's
    // environment: NEXIS_MAX_ALLOC and the like reach the program.
    const nexis_exe = bins.nexis;
    const install_nexis = install(b, nexis_exe);
    b.getInstallStep().dependOn(install_nexis);
    b.step("nexis", "Build bin/nexis (the CLI runner)").dependOn(install_nexis);
    const run_nexis = b.addRunArtifact(nexis_exe);
    run_nexis.addPassthruArgs();
    run_nexis.step.dependOn(install_nexis);
    b.step("run", "Build and run nexis (forwards args after `--`)").dependOn(&run_nexis.step);

    // The benchmark runner. Its runtime is optimized too, so the numbers
    // measure release code; `-Doptimize=safe` and the like apply.
    const bench_optimize: std.lang.Optimize = if (optimize == .debug) .fast else optimize;
    const bench_exe = benchExe(b, target, bench_optimize, runtime(b, target, bench_optimize));
    const run_bench = b.addRunArtifact(bench_exe);
    run_bench.addPassthruArgs();
    run_bench.step.dependOn(install(b, bench_exe));
    b.step("bench", "Run the benchmark suite (optimized for speed)").dependOn(&run_bench.step);
    // The gate analyzes the suite against the Debug runtime without
    // generating code or running it, so an API change cannot leave the
    // bench broken.
    test_step.dependOn(&bins.bench.step);
    // The same for the counting CLI (`-Dopcodes=true`), so the code a
    // default build compiles out cannot rot.
    const counted = cliModule(b, target, optimize);
    const counted_options = b.addOptions();
    counted_options.addOption(bool, "opcodes", true);
    counted.addOptions("build_options", counted_options);
    test_step.dependOn(&b.addExecutable(.{ .name = "nexis-counted", .root_module = counted, .use_llvm = useLlvm(target) }).step);

    // Every binary above, compiled and linked for each Linux target the
    // release supports; nothing runs. The musl builds are the static
    // binaries.
    const check_targets_step = b.step("check-targets", "Compile and link every binary and test binary for Linux (x86_64 and aarch64, glibc and musl)");
    for (linux_targets) |t| {
        const cross = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = t.triple, .cpu_features = t.cpu }) catch unreachable);
        const cross_bins = binaries(b, cross, optimize, runtime(b, cross, optimize), suites);
        const named = [_]*std.Build.Step.Compile{ cross_bins.nexis, cross_bins.golden, cross_bins.bench, cross_bins.unit, cross_bins.cli_unit };
        for ([_][]const *std.Build.Step.Compile{ &named, cross_bins.suites }) |set| for (set) |compile| {
            _ = compile.getEmittedBin();
            check_targets_step.dependOn(&compile.step);
        };
    }

    // -------------------------------------------------------------------------
    // Programs through bin/nexis, their output pinned byte for byte.
    // `-Dupdate=true` rewrites every expected file instead of comparing.
    // -------------------------------------------------------------------------

    const scripts: Scripts = .{
        .b = b,
        .exe = nexis_exe,
        .update = update,
        .env = env,
    };

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
        const pair = std.mem.endsWith(u8, name, "-1");
        var programs: std.ArrayList(Program) = .empty;
        for (if (pair) &[_][]const u8{ name, b.fmt("{s}-2", .{name[0 .. name.len - 2]}) } else &[_][]const u8{name}) |n|
            programs.append(b.allocator, .{
                .script = b.fmt("test/nextomic/{s}.nx", .{n}),
                .expected = b.fmt("test/nextomic/{s}.out", .{n}),
            }) catch @panic("OOM");
        scripts.unit(nextomic_nx_step, b.fmt("nextomic-nx-{s}", .{name}), programs.items, &.{"test/nextomic/prelude.nx"}, true);
    }
    test_step.dependOn(nextomic_nx_step);

    // examples/*.nx: each example's stdout against
    // test/examples/<name>.out, from a fresh directory (the
    // store-backed ones write under tmp/ in it). An example with a
    // `<name>.2.out` runs again in the same directory, over the
    // store the first run left.
    const examples_step = b.step("examples", "Run every examples/*.nx through bin/nexis");
    const example_libs = listFiles(b, "examples/lib", true);
    for (listStems(b, "examples", ".nx")) |name| {
        const script = b.fmt("examples/{s}.nx", .{name});
        const second = b.fmt("test/examples/{s}.2.out", .{name});
        const programs = [_]Program{
            .{ .script = script, .expected = b.fmt("test/examples/{s}.out", .{name}) },
            .{ .script = script, .expected = second },
        };
        const count: usize = if (exists(b, second)) 2 else 1;
        scripts.unit(examples_step, b.fmt("examples-{s}", .{name}), programs[0..count], example_libs, env.gc_stress);
    }
    test_step.dependOn(examples_step);

    // Reader goldens (src/golden.zig, docs/FORMS.md §5): each
    // test/golden/<name>.nx reads, its Form program pinned to
    // <name>.sexp; each test/golden/errors/<name>.nx is refused with
    // status 3, the refusal pinned to <name>.err.
    const golden_step = b.step("golden", "Run the reader and CLI goldens");
    test_step.dependOn(golden_step);
    for ([_]struct { dir: []const u8, ext: []const u8, status: u8 }{
        .{ .dir = "test/golden", .ext = ".sexp", .status = 0 },
        .{ .dir = "test/golden/errors", .ext = ".err", .status = 3 },
    }) |set| for (listStems(b, set.dir, ".nx")) |name| {
        const run = b.addRunArtifact(bins.golden);
        env.apply(run, false);
        run.addFileArg2(b.path(b.fmt("{s}/{s}.nx", .{ set.dir, name })), .{ .make_absolute = true });
        run.expectExitCode(set.status);
        scripts.pin(golden_step, run, b.fmt("{s}/{s}{s}", .{ set.dir, name, set.ext }), .stdout);
    };

    // test/golden/cli: what bin/nexis prints, pinned byte for byte: a
    // runtime error's stderr (exit 5), a reader error's stderr (exit
    // 3), a compile error's (exit 4), a disassembly, scripts' stdout
    // (with arguments, from stdin, an explicit exit status), `nexis
    // test`, a REPL session and the usage errors. Each runs from the
    // build root, so the paths in the output are the relative ones
    // committed.
    {
        const CliGolden = struct {
            args: []const []const u8,
            /// The expected-output files each stream is pinned to.
            stdout: ?[]const u8 = null,
            stderr: ?[]const u8 = null,
            exit_code: u8 = 0,
            stdin: ?[]const u8 = null,
            /// `NEXIS_MAX_ALLOC` for the run (TOOLING.md §1).
            max_alloc: ?[]const u8 = null,
        };
        const cli = "test/golden/cli/";
        const cases = [_]CliGolden{
            .{ .args = &.{ "run", cli ++ "divide-by-zero.nx" }, .stderr = "divide-by-zero.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "uncaught-throw.nx" }, .stderr = "uncaught-throw.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "rethrow-finally.nx" }, .stdout = "rethrow-finally.out", .stderr = "rethrow-finally.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "rethrow-catch.nx" }, .stdout = "rethrow-catch.out", .stderr = "rethrow-catch.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "require-runtime-error.nx" }, .stderr = "require-runtime-error.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "bad-number.nx" }, .stderr = "bad-number.err", .exit_code = 3 },
            .{ .args = &.{ "run", cli ++ "duplicate-key.nx" }, .stderr = "duplicate-key.err", .exit_code = 3 },
            .{ .args = &.{ "run", cli ++ "invalid-regex.nx" }, .stderr = "invalid-regex.err", .exit_code = 3 },
            .{ .args = &.{ "run", cli ++ "macro-failure.nx" }, .stderr = "macro-failure.err", .exit_code = 4 },
            .{ .args = &.{ "run", cli ++ "too-many-locals.nx" }, .stderr = "too-many-locals.err", .exit_code = 4 },
            .{ .args = &.{ "run", cli ++ "bom.nx" }, .stderr = "bom.err", .exit_code = 4 },
            .{ .args = &.{ "-e", "\xEF\xBB\xBF(nope)" }, .stderr = "bom-expr.err", .exit_code = 4 },
            .{ .args = &.{ "run", cli ++ "unicode-columns.nx" }, .stderr = "unicode-columns.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "deep-trace.nx" }, .stderr = "deep-trace.err", .exit_code = 5 },
            .{ .args = &.{ "run", cli ++ "out-of-memory.nx" }, .stdout = "out-of-memory.out", .stderr = "out-of-memory.err", .exit_code = 5, .max_alloc = "16777216" },
            .{ .args = &.{ "run", cli ++ "long-sequences.nx" }, .stdout = "long-sequences.out", .max_alloc = "4194304" },
            .{ .args = &.{ "disasm", "examples/sum10.nx" }, .stdout = "sum10.disasm" },
            .{ .args = &.{ "run", cli ++ "pprint.nx" }, .stdout = "pprint.out" },
            .{ .args = &.{ "run", cli ++ "deep-recursion.nx" }, .stdout = "deep-recursion.out" },
            .{ .args = &.{ "run", cli ++ "deep-nesting.nx" }, .stdout = "deep-nesting.out" },
            .{ .args = &.{ "run", cli ++ "deep-calls.nx" }, .stdout = "deep-calls.out" },
            .{ .args = &.{ "run", cli ++ "args.nx", "a", "b c" }, .stdout = "args.out" },
            .{ .args = &.{ "run", cli ++ "exit-status.nx" }, .stdout = "exit-status.out", .exit_code = 3 },
            .{ .args = &.{ "run", "-", "x" }, .stdin = "stdin.in", .stdout = "stdin.out" },
            .{ .args = &.{ "test", cli ++ "tests.nx" }, .stdout = "tests.out", .exit_code = 1 },
            .{ .args = &.{ "test", cli ++ "test-shadow.nx", cli ++ "lib/test-beside.nx" }, .stdout = "test-shadow.out", .exit_code = 1 },
            .{ .args = &.{"repl"}, .stdin = "repl.in", .stdout = "repl.out", .stderr = "repl.err", .max_alloc = "16777216" },
            .{ .args = &.{ "-e", "1" }, .stderr = "boot-out-of-memory.err", .exit_code = 5, .max_alloc = "4096" },
            .{ .args = &.{cli ++ "script"}, .stdout = "script.out" },
            .{ .args = &.{"--help"}, .stdout = "help.out" },
            .{ .args = &.{ "repl", "x" }, .stderr = "help.err", .exit_code = 1 },
            .{ .args = &.{}, .stderr = "help.err", .exit_code = 1 },
            .{ .args = &.{"frobnicate"}, .stderr = "unknown-command.err", .exit_code = 1 },
        };
        for (cases) |case| {
            const run = scripts.program(env.gc_stress);
            run.setCwd(b.path("."));
            if (case.max_alloc) |max| run.setEnvironmentVariable("NEXIS_MAX_ALLOC", max);
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

/// One program of a unit: the script `nexis run` runs and the file its
/// stdout is pinned to.
const Program = struct { script: []const u8, expected: []const u8 };

/// Programs run through bin/nexis with their output compared to, or
/// under `-Dupdate=true` written to, a file in the tree.
const Scripts = struct {
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    update: bool,
    env: RunEnv,

    /// A run of bin/nexis, with `NEXIS_GC_STRESS` when `stress`.
    fn program(self: Scripts, stress: bool) *std.Build.Step.Run {
        const r = self.b.addRunArtifact(self.exe);
        self.env.apply(r, stress);
        return r;
    }

    /// Run `programs` in order from one fresh directory named after
    /// `name`, each one's stdout pinned to its expected file. Every
    /// run hashes the contents of its script, its expected output,
    /// the binary and each of `inputs` (the files the scripts load),
    /// so a change to any of them re-runs it. A unit of two programs
    /// shares a store, so both run on every build: a second program
    /// never reads a directory its first did not write in the same
    /// build.
    fn unit(self: Scripts, step: *std.Build.Step, name: []const u8, programs: []const Program, inputs: []const []const u8, stress: bool) void {
        const cwd = self.freshDir(name);
        var previous: ?*std.Build.Step = null;
        for (programs) |p| {
            const r = self.program(stress);
            r.addArg("run");
            r.addFileArg2(self.b.path(p.script), .{ .make_absolute = true });
            r.setCwd(cwd);
            for (inputs) |input| r.addFileInput(self.b.path(input));
            r.has_side_effects = programs.len > 1;
            r.expectExitCode(0);
            self.pin(step, r, p.expected, .stdout);
            if (previous) |prev| r.step.dependOn(prev);
            previous = &r.step;
        }
    }

    /// A directory emptied on every build, for a unit's programs to
    /// use as their working directory: the stores a run leaves, a
    /// failed run's included, never reach a later build. Its path
    /// follows `name` only; what a program reads is hashed on its run.
    fn freshDir(self: Scripts, name: []const u8) std.Build.LazyPath {
        const mk = self.b.addSystemCommand(&.{ "sh", "-c", "rm -rf \"$1\" && mkdir -p \"$1\"", name });
        mk.has_side_effects = true;
        const dir = mk.addOutputDirectoryArg2("cwd", .{});
        mk.expectExitCode(0);
        return dir;
    }

    /// Make `step` compare `r`'s `stream` with the file at `path`, or
    /// rewrite the file. The run reads the file when it runs, so a
    /// missing or different file fails that run alone.
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
        if (!exists(b, path)) r.step.dependOn(&b.addFail(b.fmt("{s} is missing: write it with -Dupdate=true", .{path})).step);
        r.addCheck(switch (stream) {
            .stdout => .{ .expect_stdout_snapshot = b.path(path) },
            .stderr => .{ .expect_stderr_snapshot = b.path(path) },
        });
    }
};

/// The environment of every cached run of a binary the build makes,
/// from its options. The build reads nothing from its own
/// environment, and none of the caller's reaches a run: the runtime
/// reads its variables with `getenv`, and an inherited variable is not
/// part of a run's cache key, so a run would replay a result made
/// under another setting. A variable set on a run is part of its key,
/// so a stressed or durable run never replays a normal run's result.
const RunEnv = struct {
    /// `NEXIS_GC_STRESS`: a collection every few kilobytes (docs/GC.md §7).
    gc_stress: bool,
    /// `NEXIS_DURABILITY` (docs/DB.md §3.3); unset leaves the runtime's
    /// default.
    durability: ?Durability,

    const Durability = enum { commit, durable };

    /// Give `run` an empty environment, then the variables,
    /// `NEXIS_GC_STRESS` when `stress`.
    fn apply(env: RunEnv, run: *std.Build.Step.Run, stress: bool) void {
        run.clearEnvironment();
        if (stress) run.setEnvironmentVariable("NEXIS_GC_STRESS", "1");
        if (env.durability) |d| run.setEnvironmentVariable("NEXIS_DURABILITY", @tagName(d));
    }
};

/// A step that installs `exe` as `bin/<name>` in the checkout when
/// the install prefix is the default (`zig-out`), where the docs, the
/// examples and CI run it, and as `<prefix>/bin/<name>` when
/// `--prefix` names another, leaving the checkout's binary alone.
/// `build()` cannot see the prefix, so the step compares it when it
/// runs. The new binary replaces the old by rename, never by a write
/// into a file a running process may have mapped.
fn install(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    const script =
        \\dest=$1; [ "$dest" = "$2" ] && dest=$3
        \\mkdir -p "$dest" || exit 1
        \\cmp -s "$4" "$dest/$5" || { cp "$4" "$dest/.$5.new" && mv -f "$dest/.$5.new" "$dest/$5"; }
    ;
    const copy = b.addSystemCommand(&.{ "sh", "-c", script, "install" });
    copy.addDirectoryArg2(.{ .relative = .{ .base = .install_bin } }, .{ .make_absolute = true });
    copy.addArgs(&.{ b.pathJoin(&.{ rootPath(b), "zig-out", "bin" }), b.pathJoin(&.{ rootPath(b), "bin" }) });
    copy.addArtifactArg(exe);
    copy.addArg(exe.name);
    copy.has_side_effects = true;
    return &copy.step;
}

/// The build root as a path string.
fn rootPath(b: *std.Build) []const u8 {
    return b.fmt("{f}", .{b.root});
}

/// The names under `dir` (relative to the build root) ending in `ext`,
/// without it, sorted.
fn listStems(b: *std.Build, dir: []const u8, ext: []const u8) []const []const u8 {
    var stems: std.ArrayList([]const u8) = .empty;
    for (listFiles(b, dir, false)) |path| {
        const base = std.Io.Dir.path.basename(path);
        if (std.mem.endsWith(u8, base, ext))
            stems.append(b.allocator, base[0 .. base.len - ext.len]) catch @panic("OOM");
    }
    return stems.items;
}

/// The paths of the files under `dir`, and under its subdirectories
/// when `recursive`, sorted. A file added or removed there configures
/// the build again.
fn listFiles(b: *std.Build, dir: []const u8, recursive: bool) []const []const u8 {
    const io = b.graph.io;
    var handle = b.root.openDir(io, dir, .{ .iterate = true }) catch |err|
        std.debug.panic("cannot open {s}: {t}", .{ dir, err });
    defer handle.close(io);
    b.dependOnDirectoryContents(b.path(dir));
    var paths: std.ArrayList([]const u8) = .empty;
    var walker = handle.walkSelectively(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| std.debug.panic("cannot list {s}: {t}", .{ dir, err })) |entry| switch (entry.kind) {
        .file => paths.append(b.allocator, b.pathJoin(&.{ dir, entry.path })) catch @panic("OOM"),
        .directory => if (recursive) {
            walker.enter(io, entry) catch |err| std.debug.panic("cannot list {s}: {t}", .{ entry.path, err });
            b.dependOnDirectoryContents(b.path(b.pathJoin(&.{ dir, entry.path })));
        },
        else => {},
    };
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return paths.items;
}

/// Whether `path`, relative to the build root, exists. Creating or
/// deleting it configures the build again.
fn exists(b: *std.Build, path: []const u8) bool {
    b.dependOnDirectoryContents(b.path(std.Io.Dir.path.dirname(path) orelse "."));
    b.root.access(b.graph.io, path, .{}) catch return false;
    return true;
}

/// A property or integration test file, its own binary.
const Suite = struct { path: []const u8, quick: bool, nextomic: bool };

/// The suites `zig build quick` runs besides `unit`.
const quick_suites = [_][]const u8{ "compile", "nextomic_key", "nextomic_tx", "eval_pipeline", "runtime_polish", "numbers" };

/// Every `.zig` file in test/prop, test/integration and test/regex but the
/// fixtures the suites import (`_fx.zig`), so a new suite runs without
/// a line here. The Nextomic suites (`nextomic_*`) also run under
/// `nextomic-test`.
fn listSuites(b: *std.Build) []const Suite {
    var list: std.ArrayList(Suite) = .empty;
    for ([_][]const u8{ "test/prop", "test/integration", "test/regex" }) |dir| for (listFiles(b, dir, false)) |path| {
        if (!std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, "_fx.zig")) continue;
        const name = std.Io.Dir.path.stem(path);
        list.append(b.allocator, .{
            .path = path,
            .quick = for (quick_suites) |q| {
                if (std.mem.eql(u8, q, name)) break true;
            } else false,
            .nextomic = std.mem.startsWith(u8, name, "nextomic_"),
        }) catch @panic("OOM");
    };
    return list.items;
}

/// The targets `check-targets` compiles for: Linux on both
/// architectures, glibc and musl (the static binary). x86_64 is
/// checked at the x86-64-v3 level, the CPU of every current CI runner
/// and server, so emdb's SSE4.2 and AVX2 paths compile as they will
/// on a native build; baseline x86_64 would skip them.
const linux_targets = [_]struct { triple: []const u8, cpu: []const u8 }{
    .{ .triple = "x86_64-linux-gnu", .cpu = "x86_64_v3" },
    .{ .triple = "aarch64-linux-gnu", .cpu = "baseline" },
    .{ .triple = "x86_64-linux-musl", .cpu = "x86_64_v3" },
    .{ .triple = "aarch64-linux-musl", .cpu = "baseline" },
};

const Binaries = struct {
    nexis: *std.Build.Step.Compile,
    golden: *std.Build.Step.Compile,
    /// The benchmark runner over the runtime at the build's optimize
    /// mode: the gate's check that it compiles.
    bench: *std.Build.Step.Compile,
    unit: *std.Build.Step.Compile,
    /// The inline tests of src/cli.zig.
    cli_unit: *std.Build.Step.Compile,
    /// One per `suites` entry, in order.
    suites: []*std.Build.Step.Compile,
};

/// Every binary the build compiles for `target`, over the runtime
/// module `nexis`.
fn binaries(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, nexis: *std.Build.Module, suites: []const Suite) Binaries {
    const harness = b.createModule(.{
        .root_source_file = b.path("test/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    harness.addImport("nexis", nexis);
    const suite_bins = b.allocator.alloc(*std.Build.Step.Compile, suites.len) catch @panic("OOM");
    for (suites, suite_bins) |suite, *bin| {
        const module = b.createModule(.{
            .root_source_file = b.path(suite.path),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("nexis", nexis);
        module.addImport("harness", harness);
        bin.* = b.addTest(.{ .name = std.Io.Dir.path.stem(suite.path), .root_module = module, .use_llvm = useLlvm(target) });
    }
    const cli_mod = cliModule(b, target, optimize);
    cli_mod.addOptions("build_options", runtimeOptions(b));
    return .{
        .nexis = b.addExecutable(.{ .name = "nexis", .root_module = cli_mod, .use_llvm = useLlvm(target) }),
        .golden = b.addExecutable(.{
            .name = "nexis-golden",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/golden.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = useLlvm(target),
        }),
        .bench = benchExe(b, target, optimize, nexis),
        .unit = b.addTest(.{ .name = "unit", .root_module = nexis, .use_llvm = useLlvm(target) }),
        // The runtime's own tests run in `unit`; this binary reaches
        // them too, through the files cli.zig imports.
        .cli_unit = b.addTest(.{ .name = "cli-unit", .root_module = cli_mod, .filters = &.{"cli: "}, .use_llvm = useLlvm(target) }),
        .suites = suite_bins,
    };
}

/// The module of bin/nexis, rooted at src/cli.zig, without its
/// `build_options`.
fn cliModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .omit_frame_pointer = omitFramePointer(optimize),
    });
    module.addImport("emdb", emdbModule(b, target, optimize));
    return module;
}

fn benchExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, nexis: *std.Build.Module) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("nexis", nexis);
    return b.addExecutable(.{ .name = "nexis-bench", .root_module = module, .use_llvm = useLlvm(target) });
}

/// Every binary on x86_64 compiles through LLVM, whatever the optimize
/// mode. Zig's own x86_64 backend, the default for Debug there, cannot
/// compile the threaded dispatch's `@call(.always_tail, ...)`
/// (`docs/VM.md` §6); LLVM can, and release builds use LLVM already.
/// Elsewhere the compiler chooses.
fn useLlvm(target: std.Build.ResolvedTarget) ?bool {
    return if (target.result.cpu.arch == .x86_64) true else null;
}

/// The `nexis` module: the whole runtime, rooted at src/root.zig. It
/// links libc on every target: the runtime and emdb call it, and
/// Linux, unlike macOS, links it only on request.
fn runtime(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .omit_frame_pointer = omitFramePointer(optimize),
    });
    module.addImport("emdb", emdbModule(b, target, optimize));
    module.addOptions("build_options", runtimeOptions(b));
    return module;
}

var runtime_options: ?*std.Build.Step.Options = null;

/// The runtime's `build_options`, made once for every module that
/// compiles src/vm.zig: `opcodes`, whether every dispatch and native
/// call is counted and the CLI prints the counts at exit
/// (docs/TOOLING.md §1).
fn runtimeOptions(b: *std.Build) *std.Build.Step.Options {
    if (runtime_options) |o| return o;
    const o = b.addOptions();
    o.addOption(bool, "opcodes", b.option(bool, "opcodes", "count every dispatch by opcode and every native call; bin/nexis prints the counts at exit") orelse false);
    runtime_options = o;
    return o;
}

/// emdb, the storage engine: a path dependency on the sibling checkout.
fn emdbModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const module = b.dependency("emdb", .{ .target = target, .optimize = optimize }).module("emdb");
    module.omit_frame_pointer = omitFramePointer(optimize);
    return module;
}

/// A release build keeps no frame pointer, so a dispatch handler that
/// needs no stack has no frame record to push (docs/VM.md §8); a debug
/// build keeps the compiler's default.
fn omitFramePointer(optimize: std.lang.Optimize) ?bool {
    return if (optimize == .debug) null else true;
}

/// Check every `@import` under src/ against the layering src/root.zig
/// declares (PLAN §5, docs/FORMS.md §4). Returns a message naming the
/// first violation, or null. Every file and directory it reads is a
/// configure input, so an edit under src/ checks the layering again.
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
    var src = b.root.openDir(io, "src", .{ .iterate = true }) catch |err|
        return b.fmt("layering: cannot open src/: {t}", .{err});
    defer src.close(io);
    b.dependOnDirectoryContents(b.path("src"));
    b.dependOnFileContents(b.path("src/root.zig"));

    const root_text = src.readFileAlloc(io, "root.zig", gpa, .limited(1 << 20)) catch |err|
        return b.fmt("layering: cannot read src/root.zig: {t}", .{err});
    var rank: std.StringHashMapUnmanaged(usize) = .empty;
    for (importPaths(gpa, root_text)) |path| {
        if (std.mem.endsWith(u8, path, ".zig")) rank.put(gpa, path, rank.count()) catch @panic("OOM");
    }

    var walker = src.walk(gpa) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err| return b.fmt("layering: walking src/: {t}", .{err})) |entry| {
        if (entry.kind == .directory) b.dependOnDirectoryContents(b.path(b.pathJoin(&.{ "src", entry.path })));
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const file = b.graph.dupeString(entry.path);
        if (std.mem.eql(u8, file, "root.zig")) continue;
        const from = layerUnit(file);
        const from_rank = rank.get(from) orelse if (isExecutableRoot(file))
            std.math.maxInt(usize)
        else
            return b.fmt("layering: src/{s} is not declared in src/root.zig", .{file});

        b.dependOnFileContents(b.path(b.pathJoin(&.{ "src", file })));
        const text = src.readFileAlloc(io, file, gpa, .limited(1 << 24)) catch |err|
            return b.fmt("layering: cannot read src/{s}: {t}", .{ file, err });
        for (importPaths(gpa, text)) |rel| {
            if (!std.mem.endsWith(u8, rel, ".zig")) continue;
            const dir = std.Io.Dir.path.dirnamePosix(file) orelse "";
            const target = std.Io.Dir.path.resolveAllocPosix(gpa, &.{ dir, rel }) catch @panic("OOM");
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

/// The path of every `@import("...")` in the Zig source `text`, in
/// order, whatever whitespace or line breaks sit around the paren;
/// comments and string and character literals are skipped.
fn importPaths(gpa: std.mem.Allocator, text: []const u8) []const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) switch (text[i]) {
        // A comment, or a line of a multiline string literal.
        '/', '\\' => if (i + 1 < text.len and text[i + 1] == text[i]) {
            i = std.mem.findScalarPos(u8, text, i, '\n') orelse text.len;
        },
        '"', '\'' => {
            const quote = text[i];
            i += 1;
            while (i < text.len and text[i] != quote and text[i] != '\n') : (i += 1) {
                if (text[i] == '\\') i += 1;
            }
        },
        '@' => if (std.mem.startsWith(u8, text[i..], "@import")) {
            var j = skipSpace(text, i + "@import".len);
            if (j == text.len or text[j] != '(') continue;
            j = skipSpace(text, j + 1);
            if (j == text.len or text[j] != '"') continue;
            const end = std.mem.findScalarPos(u8, text, j + 1, '"') orelse text.len;
            paths.append(gpa, text[j + 1 .. end]) catch @panic("OOM");
            i = end;
        },
        else => {},
    };
    return paths.items;
}

fn skipSpace(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
    return i;
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

test "importPaths: every @import in order, in any spacing, never one inside a comment or string" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src =
        \\const a = @import("a.zig"); const b = @import("b.zig");
        \\const c = @import (
        \\    "c.zig",
        \\);
        \\const d = @import("d.zig"); // was @import("x.zig")
        \\    // @import("y.zig")
        \\const s = "@import(\"z.zig\")";
        \\const q = '"'; const e = @import("e.zig");
        \\const m =
        \\    \\@import("w.zig")
        \\;
    ;
    const paths = importPaths(arena.allocator(), src);
    try std.testing.expectEqual(5, paths.len);
    for (paths, [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig", "e.zig" }) |got, want|
        try std.testing.expectEqualStrings(want, got);
}
