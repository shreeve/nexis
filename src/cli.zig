//! nexis CLI: `run`, `repl`, `test`, `disasm` and `-e` over one
//! `Runtime` (docs/TOOLING.md §1).
//!
//! A Runtime is a VM with the standard library booted
//! (`stdlib.boot`) and a `Loader` for `require`. Every command
//! evaluates its text through `Loader.evalSource`, one top-level
//! form at a time on the same VM, so Vars, the interner and runtime
//! values persist across the forms of a file and the inputs of a
//! REPL session.

const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("value.zig");
const vm = @import("vm.zig");
const compile = @import("compile.zig");
const intern_mod = @import("intern.zig");
const expand_mod = @import("expand.zig");
const stdlib = @import("stdlib.zig");
const loader_mod = @import("loader.zig");
const format_mod = @import("format.zig");
const disasm_mod = @import("disasm.zig");
const string_mod = @import("string.zig");
const vector_mod = @import("coll/vector.zig");
const reader_mod = @import("reader.zig");
const stack_guard = @import("stack.zig");

const Value = value_mod.Value;

const Usage =
    \\nexis — A Lisp where immutable values, transactional durable
    \\        identity, and historical snapshots are one coherent
    \\        programming model.
    \\
    \\usage:
    \\  nexis run FILE [ARG...]  Runs FILE's top-level forms in order;
    \\                           `-` reads the program from stdin.
    \\                           *command-line-args* holds the ARGs.
    \\  nexis FILE.nx [ARG...]   The same as `run`.
    \\  nexis -e EXPR [ARG...]   Evaluates EXPR's forms and prints each
    \\                           value that is not nil.
    \\  nexis repl               Interactive read-eval-print loop;
    \\                           :quit or EOF to exit.
    \\  nexis test FILE...       Runs each file, then every deftest
    \\                           they defined; exits 1 on a failure
    \\                           or an error.
    \\  nexis disasm FILE        Compiles FILE without running it and
    \\                           prints every routine's bytecode: pc,
    \\                           opcode, operands, constants and the
    \\                           source line:col each run of
    \\                           instructions comes from.
    \\                           `--disasm FILE` is the same.
    \\
    \\Exit status: 0 success, 1 usage or test failure, 2 unreadable
    \\file, 3 parse or reader error, 4 compile error, 5 runtime
    \\error; `(exit n)` exits with n.
    \\
    \\Namespaces available without a file: nexis.core (auto-referred),
    \\db (key-value storage on emdb), nextomic (Datomic-class datoms:
    \\transact!, q, pull, as-of/since/history, with), nexis.string,
    \\nexis.set (union, intersection, difference, ...), nexis.test
    \\(deftest, is, testing, run-tests), nexis.pprint (pprint),
    \\nexis.math (sqrt, pow, floor, ceil, round, PI, E), nexis.simd
    \\(typed-vector kernels), nexis.internal. See README.md,
    \\docs/TOOLING.md and docs/NEXTOMIC.md.
    \\
    \\Examples: examples/*.nx (examples/nextomic-app.nx for Nextomic).
    \\
;

/// The runtime's thread stack. Reading, printing, hashing and comparing
/// nested data recurse on the native stack, guarded by `stack.check`
/// (docs/VM.md §13.1), so the runtime runs on a thread whose stack is a
/// large virtual reservation: pages are committed only when touched.
const runtime_stack_size = 1 << 30;
/// Headroom below the guard's limit for unguarded leaf calls.
const runtime_stack_margin = 16 << 20;

pub fn main(init: std.process.Init) !void {
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = runtime_stack_size }, runtimeThread, .{ init, &result });
    thread.join();
    return result;
}

fn runtimeThread(init: std.process.Init, result: *anyerror!void) void {
    stack_guard.arm(runtime_stack_size - runtime_stack_margin);
    result.* = runCommand(init);
}

fn runCommand(init: std.process.Init) !void {
    // Every heap block the VM allocates goes through this allocator.
    // A Debug build keeps the leak check but not the stack trace per
    // allocation, which costs it three orders of magnitude on
    // allocation-heavy programs; a release build uses the process's.
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }) = .init;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) usageExit(io);
    const cmd = args[1];
    if (eql(cmd, "run")) {
        if (args.len < 3) usageExit(io);
        try runFile(io, allocator, args[2], args[3..]);
    } else if (eql(cmd, "repl")) {
        try runRepl(io, allocator);
    } else if (eql(cmd, "test")) {
        if (args.len < 3) usageExit(io);
        try runTests(io, allocator, args[2..]);
    } else if (eql(cmd, "disasm") or eql(cmd, "--disasm")) {
        if (args.len < 3) usageExit(io);
        try disasmFile(io, allocator, args[2]);
    } else if (eql(cmd, "-e")) {
        if (args.len < 3) usageExit(io);
        try evalExpr(io, allocator, args[2], args[3..]);
    } else if (eql(cmd, "--help") or eql(cmd, "-h")) {
        try std.Io.File.stderr().writeStreamingAll(io, Usage);
    } else if (std.mem.endsWith(u8, cmd, ".nx") or eql(cmd, "-")) {
        try runFile(io, allocator, cmd, args[2..]);
    } else {
        try std.Io.File.stderr().writeStreamingAll(io, "nexis: unknown command '");
        try std.Io.File.stderr().writeStreamingAll(io, cmd);
        try std.Io.File.stderr().writeStreamingAll(io, "' (try `nexis --help`)\n");
        std.process.exit(1);
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageExit(io: std.Io) noreturn {
    std.Io.File.stderr().writeStreamingAll(io, Usage) catch {};
    std.process.exit(1);
}

/// `nexis: <path>:<line>:<col>: <label>`, then the source line
/// and a caret under the span's part on that line. Nothing is cut: a
/// long path, label or line goes out whole.
fn emitSourceError(io: std.Io, info: *const vm.SourceInfo, label: []const u8, span: reader_mod.SrcSpan) !void {
    var buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &buf);
    const w = &stderr.interface;
    const loc = info.lineCol(span.pos);
    try w.print("nexis: {s}:{d}:{d}: {s}\n", .{ info.path, loc.line, loc.col, label });
    const line_text = info.lineText(loc.line);
    if (line_text.len > 0) {
        try w.print("    {s}\n    ", .{line_text});
        try w.splatByteAll(' ', loc.col -| 1);
        // One caret per byte of the span up to the line's end, at
        // least one.
        const rest = line_text.len -| (loc.col -| 1);
        try w.splatByteAll('^', @max(@min(span.len, rest), 1));
        try w.writeAll("\n");
    }
    try w.flush();
}

const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    loader: loader_mod.Loader,
    registry: *vm.NamespaceRegistry,
    /// What `macroexpand-1`, `read-string` and `eval` call into.
    hooks: compile.RuntimeHooks,

    /// Boot in place: the runtime keeps pointers into itself.
    /// `load_paths` must outlive it.
    fn init(rt: *Runtime, io: std.Io, allocator: std.mem.Allocator, load_paths: []const []const u8) !void {
        rt.allocator = allocator;
        rt.io = io;
        rt.v = try vm.VM.init(allocator, &vm.VM.idle_routine);
        errdefer rt.v.deinit();
        rt.v.io = io;
        const interner = rt.v.ensureInterner();
        const registry = try rt.v.ensureRegistry();
        rt.registry = registry;
        rt.host_macros = try expand_mod.defaultMacros(allocator);
        errdefer rt.host_macros.deinit(allocator);
        rt.loader = loader_mod.Loader.init(allocator, rt.v.runtime_arena.allocator(), io, load_paths, &rt.v, interner, registry, &rt.host_macros);
        errdefer rt.loader.deinit();
        // A failure here is a bug in an embedded source, not in the
        // user's program: no half-booted runtime is worth running.
        stdlib.boot(&rt.loader) catch |err| {
            const d = rt.loader.diagnostic;
            std.debug.panic("nexis: stdlib bootstrap failed: {s} {s}", .{ @errorName(err), if (d) |x| x.label else "" });
        };
        rt.hooks = .{ .host_macros = &rt.host_macros, .registry = registry, .interner = interner, .load_callback = rt.loader.callback() };
        rt.hooks.install(&rt.v);
    }

    fn deinit(rt: *Runtime) void {
        rt.loader.deinit();
        rt.host_macros.deinit(rt.allocator);
        rt.v.deinit();
    }

    fn persistent(rt: *Runtime) std.mem.Allocator {
        return rt.v.runtime_arena.allocator();
    }

    /// Bind `nexis.core/<name>` to `value`.
    fn setCoreVar(rt: *Runtime, name: []const u8, value: Value) !void {
        const v = try rt.registry.core.intern(name);
        v.root = value;
        v.bound = true;
    }

    /// `*command-line-args*`: the arguments after the program as a
    /// vector of strings, nil when there are none (as in Clojure).
    fn setArgs(rt: *Runtime, args: []const []const u8) !void {
        if (args.len == 0) return;
        const heap = rt.v.ensureHeap();
        var vec = try vector_mod.empty(heap);
        for (args) |a| vec = try vector_mod.conj(heap, vec, try string_mod.fromBytes(heap, a));
        try rt.setCoreVar("*command-line-args*", vec);
    }

    /// Report what `evalSource` failed with; the exit status it
    /// carries.
    fn report(rt: *Runtime, err: loader_mod.EvalError) !u8 {
        switch (err) {
            error.Diagnosed => {
                const d = rt.loader.diagnostic.?;
                if (d.source) |info| {
                    try emitSourceError(rt.io, info, d.label, d.span orelse .{ .pos = 0, .len = 1 });
                } else {
                    try std.Io.File.stderr().writeStreamingAll(rt.io, "nexis: ");
                    try std.Io.File.stderr().writeStreamingAll(rt.io, d.label);
                    try std.Io.File.stderr().writeStreamingAll(rt.io, "\n");
                }
                return if (d.reading) 3 else 4;
            },
            error.RunFailed, error.ControlTransferred => {
                try rt.reportRuntimeError(rt.v.traced_error orelse vm.VmError.UncaughtThrow);
                return 5;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    }

    /// Report a runtime error at the instruction that raised it and
    /// print the frame chain, innermost first:
    ///
    ///   nexis: <path>:<line>:<col>: runtime error: DivideByZero
    ///       <source line>
    ///       <caret>
    ///     at f (<path>:<line>:<col>)
    ///     at <top> (<path>:<line>:<col>)
    ///
    /// An uncaught throw names the thrown value after the error, as
    /// `pr-str` prints it. A frame whose routine carries no span
    /// table is listed by name alone.
    fn reportRuntimeError(rt: *Runtime, err: anyerror) !void {
        var label: std.Io.Writer.Allocating = .init(rt.allocator);
        defer label.deinit();
        try label.writer.print("runtime error: {s}", .{@errorName(err)});
        if (rt.v.error_detail.len > 0) try label.writer.print(": {s}", .{rt.v.error_detail});
        if (err == vm.VmError.UncaughtThrow) if (rt.v.unhandled_throw) |payload| {
            try label.writer.writeAll(" ");
            format_mod.format(payload, .readable, &label.writer, rt.v.ensureInterner()) catch try label.writer.writeAll("#<unprintable>");
        };

        const trace = rt.v.error_trace.items;
        if (trace.len > 0 and trace[0].span != null and trace[0].source != null) {
            try emitSourceError(rt.io, trace[0].source.?, label.written(), .{ .pos = trace[0].span.?.pos, .len = trace[0].span.?.len });
        } else {
            try std.Io.File.stderr().writeStreamingAll(rt.io, "nexis: ");
            try std.Io.File.stderr().writeStreamingAll(rt.io, label.written());
            try std.Io.File.stderr().writeStreamingAll(rt.io, "\n");
        }
        var buf: [1024]u8 = undefined;
        var stderr = std.Io.File.stderr().writerStreaming(rt.io, &buf);
        const w = &stderr.interface;
        for (trace) |frame| {
            // The marker the VM leaves where it cut a deep chain
            // (`<N frames elided>`) is no frame to be "at".
            if (frame.source == null and std.mem.endsWith(u8, frame.name, " frames elided>")) {
                try w.print("  {s}\n", .{frame.name});
            } else if (frame.source) |src| {
                if (frame.span) |span| {
                    const loc = src.lineCol(span.pos);
                    try w.print("  at {s} ({s}:{d}:{d})\n", .{ frame.name, src.path, loc.line, loc.col });
                } else try w.print("  at {s} ({s})\n", .{ frame.name, src.path });
            } else try w.print("  at {s}\n", .{frame.name});
        }
        try w.flush();
    }

    /// `v` as `pr` prints it, then a newline, on stdout.
    fn printReadably(rt: *Runtime, v: Value) !void {
        var out: std.Io.Writer.Allocating = .init(rt.allocator);
        defer out.deinit();
        format_mod.format(v, .readable, &out.writer, rt.v.ensureInterner()) catch |err| switch (err) {
            error.Utf8Error => try out.writer.writeAll("#<invalid utf-8>"),
            error.WriteFailed => return error.OutOfMemory,
        };
        try out.writer.writeAll("\n");
        try std.Io.File.stdout().writeStreamingAll(rt.io, out.written());
    }
};

/// The text of FILE, or of stdin for `-`; exit 2 when it cannot be
/// read. A `#!` first line is a comment, so a script can be
/// executable.
fn readProgram(io: std.Io, allocator: std.mem.Allocator, path: []const u8) []u8 {
    const text = if (eql(path, "-")) blk: {
        var buf: [4096]u8 = undefined;
        var r = std.Io.File.stdin().readerStreaming(io, &buf);
        break :blk r.interface.allocRemaining(allocator, .unlimited) catch |err| failRead(io, path, err);
    } else std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| failRead(io, path, err);
    if (std.mem.startsWith(u8, text, "#!")) @memcpy(text[0..2], ";;");
    return text;
}

fn failRead(io: std.Io, path: []const u8, err: anyerror) noreturn {
    const stderr = std.Io.File.stderr();
    stderr.writeStreamingAll(io, "nexis: failed to read '") catch {};
    stderr.writeStreamingAll(io, path) catch {};
    stderr.writeStreamingAll(io, "': ") catch {};
    stderr.writeStreamingAll(io, @errorName(err)) catch {};
    stderr.writeStreamingAll(io, "\n") catch {};
    std.process.exit(2);
}

/// `require` searches the working directory and the file's own.
fn loadPathsFor(path: []const u8) [2][]const u8 {
    return .{ ".", if (eql(path, "-")) "." else std.fs.path.dirname(path) orelse "." };
}

/// Run FILE's forms. Like Clojure's script runner, `run` writes only
/// what the program prints.
fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, args: []const []const u8) !void {
    const text = readProgram(io, allocator, path);
    defer allocator.free(text);
    const load_paths = loadPathsFor(path);
    var rt: Runtime = undefined;
    try rt.init(io, allocator, &load_paths);
    defer rt.deinit();
    try rt.setArgs(args);
    // One arena for the file's Form trees and routines, released
    // together at the end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const info = vm.SourceInfo{ .path = if (eql(path, "-")) "<stdin>" else path, .text = text };
    _ = rt.loader.evalSource(&info, .{ .allocator = arena.allocator() }) catch |err| std.process.exit(try rt.report(err));
}

/// `nexis -e EXPR`: EXPR's forms, each non-nil value printed.
fn evalExpr(io: std.Io, allocator: std.mem.Allocator, expr: []const u8, args: []const []const u8) !void {
    const load_paths = [_][]const u8{"."};
    var rt: Runtime = undefined;
    try rt.init(io, allocator, &load_paths);
    defer rt.deinit();
    try rt.setArgs(args);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const info = vm.SourceInfo{ .path = "<-e>", .text = expr };
    const Print = struct {
        fn call(ctx: *anyopaque, v: Value) anyerror!void {
            if (!v.isNil()) try @as(*Runtime, @ptrCast(@alignCast(ctx))).printReadably(v);
        }
    };
    _ = rt.loader.evalSource(&info, .{ .allocator = arena.allocator(), .on_value = .{ .ctx = &rt, .call = &Print.call } }) catch |err| std.process.exit(try rt.report(err));
}

/// `nexis test FILE...`: run each file, then `run-all-tests`; exit 1
/// when an assertion failed or a test threw.
fn runTests(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8) !void {
    const load_paths = loadPathsFor(paths[0]);
    var rt: Runtime = undefined;
    try rt.init(io, allocator, &load_paths);
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (paths) |path| {
        const text = readProgram(io, arena.allocator(), path);
        const info = try arena.allocator().create(vm.SourceInfo);
        info.* = .{ .path = path, .text = text };
        const saved = rt.registry.current;
        _ = rt.loader.evalSource(info, .{ .allocator = arena.allocator() }) catch |err| std.process.exit(try rt.report(err));
        rt.registry.current = saved;
    }
    const info = vm.SourceInfo{ .path = "<test>", .text = "(let [r (nexis.test/run-all-tests)] (+ (get r :fail) (get r :error)))" };
    const bad = rt.loader.evalSource(&info, .{ .allocator = arena.allocator() }) catch |err| std.process.exit(try rt.report(err));
    if (!bad.isFixnum() or bad.asFixnum() != 0) std.process.exit(1);
}

/// Compile FILE the way `run` does and print every routine's
/// disassembly to stdout instead of running it. Macro expansion,
/// `(ns ...)` and `(require ...)` still take effect at compile time;
/// a `def` does not run, so a macro that calls a function the same
/// file defines cannot expand here.
fn disasmFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const text = readProgram(io, allocator, path);
    defer allocator.free(text);
    const load_paths = loadPathsFor(path);
    var rt: Runtime = undefined;
    try rt.init(io, allocator, &load_paths);
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const Disasm = struct {
        rt: *Runtime,
        out: *std.Io.Writer,
        first: bool = true,
        fn call(ctx: *anyopaque, routine: *const vm.Routine) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.first) try self.out.writeAll("\n");
            self.first = false;
            try disasm_mod.disassemble(routine, self.rt.v.ensureInterner(), self.out);
        }
    };
    var each = Disasm{ .rt = &rt, .out = &out.writer };
    const info = vm.SourceInfo{ .path = path, .text = text };
    _ = rt.loader.evalSource(&info, .{ .allocator = arena.allocator(), .on_routine = .{ .ctx = &each, .call = &Disasm.call } }) catch |err| std.process.exit(try rt.report(err));
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}

/// The interactive loop: read lines until they hold complete forms,
/// evaluate every form, print each value as `pr` does and bind it to
/// `*1` (the previous ones to `*2` and `*3`); an error is printed,
/// bound to `*e`, and the loop continues. `:quit`, `:q` or EOF exits.
fn runRepl(io: std.Io, allocator: std.mem.Allocator) !void {
    const stdout = std.Io.File.stdout();
    const load_paths = [_][]const u8{"."};
    var rt: Runtime = undefined;
    try rt.init(io, allocator, &load_paths);
    defer rt.deinit();
    const nil = value_mod.nilValue();
    for ([_][]const u8{ "*1", "*2", "*3", "*e" }) |name| try rt.setCoreVar(name, nil);

    try stdout.writeStreamingAll(io,
        \\nexis repl
        \\Type `:quit` or hit Ctrl-D to exit.
        \\
        \\
    );

    const Results = struct {
        rt: *Runtime,
        fn call(ctx: *anyopaque, v: Value) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const core = self.rt.registry.core;
            core.lookupLocal("*3").?.root = core.lookupLocal("*2").?.root;
            core.lookupLocal("*2").?.root = core.lookupLocal("*1").?.root;
            core.lookupLocal("*1").?.root = v;
            try self.rt.printReadably(v);
        }
    };
    var results = Results{ .rt = &rt };

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(allocator);
    while (true) {
        if (pending.items.len == 0) {
            const ns = rt.registry.current.name;
            try stdout.writeStreamingAll(io, ns);
            try stdout.writeStreamingAll(io, "=> ");
        }
        const line = stdlib.readStdinLine(io) catch |err| {
            try std.Io.File.stderr().writeStreamingAll(io, "nexis: stdin read error: ");
            try std.Io.File.stderr().writeStreamingAll(io, @errorName(err));
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            return;
        } orelse {
            try stdout.writeStreamingAll(io, "\n");
            return;
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (pending.items.len == 0) {
            if (trimmed.len == 0) continue;
            if (eql(trimmed, ":quit") or eql(trimmed, ":q")) return;
        }
        try pending.appendSlice(allocator, line);
        try pending.append(allocator, '\n');

        // Closures made here are called from later inputs, so the
        // text, its SourceInfo and its routines live as long as the
        // session.
        const info = try rt.persistent().create(vm.SourceInfo);
        info.* = .{ .path = "<repl>", .text = try rt.persistent().dupe(u8, std.mem.trimEnd(u8, pending.items, "\n")) };
        _ = rt.loader.evalSource(info, .{ .allocator = rt.persistent(), .on_value = .{ .ctx = &results, .call = &Results.call } }) catch |err| {
            if (err == error.Diagnosed and rt.loader.diagnostic.?.incomplete) continue;
            const e = if (err == error.RunFailed) rt.v.unhandled_throw orelse errorKeyword(&rt) else nil;
            _ = try rt.report(err);
            // The frames, handlers and bindings an aborted run left
            // must not leak into the next input.
            rt.v.resetAfterError();
            if (err == error.RunFailed) rt.registry.core.lookupLocal("*e").?.root = e;
        };
        pending.clearRetainingCapacity();
    }
}

/// The keyword a caught runtime error would be (`DivideByZero` is
/// `:divide-by-zero`), for `*e`.
fn errorKeyword(rt: *Runtime) Value {
    const err = rt.v.traced_error orelse return value_mod.nilValue();
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (@errorName(err), 0..) |c, i| {
        if (n + 2 > buf.len) break;
        if (std.ascii.isUpper(c)) {
            if (i > 0) {
                buf[n] = '-';
                n += 1;
            }
            buf[n] = std.ascii.toLower(c);
        } else buf[n] = c;
        n += 1;
    }
    return rt.v.ensureInterner().internKeywordValue(buf[0..n]) catch value_mod.nilValue();
}
