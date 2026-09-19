//! nexis CLI: `nexis run FILE.nx`, `nexis repl` and `nexis disasm
//! FILE.nx`.
//!
//! The first two boot one `Runtime` (a VM with every namespace
//! installed, the embedded core.nx and nextomic.nx bootstrapped,
//! and a namespace loader for `require`), then compile and run
//! top-level forms on it one at a time. Vars, the interner and
//! runtime values persist across the forms of a file and across
//! the lines of a REPL session because every form runs on the same
//! VM through `VM.retargetTop`.

const std = @import("std");
const value_mod = @import("value");
const vm = @import("vm");
const compile = @import("compile");
const reader_mod = @import("reader");
const intern_mod = @import("intern");
const expand_mod = @import("expand");
const stdlib = @import("stdlib");
const loader_mod = @import("loader");
const format_mod = @import("format");
const disasm_mod = @import("disasm");

const Value = value_mod.Value;

/// Print a Value the way `(print ...)` does, through the one
/// formatter in `src/format.zig`.
fn formatValue(v: Value, interner: *const intern_mod.Interner, writer: *std.Io.Writer) !void {
    try format_mod.format(v, .display, writer, interner);
}

const Usage =
    \\nexis — A Lisp where immutable values, transactional durable
    \\        identity, and historical snapshots are one coherent
    \\        programming model.
    \\
    \\usage:
    \\  nexis run FILE.nx    Reads FILE.nx, compiles and runs each
    \\                       top-level form in order, prints the
    \\                       final result.
    \\  nexis repl           Interactive read-eval-print loop.
    \\                       :quit or EOF to exit.
    \\  nexis disasm FILE.nx Compiles FILE.nx without running it and
    \\                       prints every routine's bytecode: pc,
    \\                       opcode, operands, constants and the
    \\                       source line:col each run of
    \\                       instructions comes from.
    \\                       `--disasm FILE.nx` is the same.
    \\
    \\For `run`, Vars and the interner persist across forms within
    \\the file; for `repl`, across the whole session. A runtime error
    \\is reported at its source position with the frame chain.
    \\
    \\Namespaces available without a file: nexis.core (auto-referred),
    \\db (key-value storage on emdb), nextomic (Datomic-class datoms:
    \\transact!, q, pull, as-of/since/history, with), nexis.string,
    \\nexis.test (deftest, is, testing, run-tests), nexis.pprint
    \\(pprint), nexis.math (sqrt, pow, floor, ceil, round, PI, E),
    \\nexis.simd (typed-vector kernels), nexis.internal. See README.md,
    \\docs/TOOLING.md and docs/NEXTOMIC.md.
    \\
    \\Examples: examples/*.nx (examples/nextomic-app.nx for Nextomic).
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // Iterate the argv stream into a small owned slice. Zig 0.16
    // moved argv from `process.argsAlloc` to `init.minimal.args`
    // (an iterator). We collect to a slice for simple indexing.
    var arg_iter = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_iter.deinit();
    var arg_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (arg_list.items) |a| allocator.free(a);
        arg_list.deinit(allocator);
    }
    while (arg_iter.next()) |a| {
        try arg_list.append(allocator, try allocator.dupe(u8, a));
    }
    const args = arg_list.items;

    if (args.len < 2) {
        try printUsage(io);
        std.process.exit(1);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "run")) {
        if (args.len < 3) {
            try printUsage(io);
            std.process.exit(1);
        }
        try runFile(io, allocator, args[2]);
    } else if (std.mem.eql(u8, cmd, "repl")) {
        try runRepl(io, allocator);
    } else if (std.mem.eql(u8, cmd, "disasm") or std.mem.eql(u8, cmd, "--disasm")) {
        if (args.len < 3) {
            try printUsage(io);
            std.process.exit(1);
        }
        try disasmFile(io, allocator, args[2]);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage(io);
    } else {
        try std.Io.File.stderr().writeStreamingAll(io, "nexis: unknown command '");
        try std.Io.File.stderr().writeStreamingAll(io, cmd);
        try std.Io.File.stderr().writeStreamingAll(io, "' (try `nexis --help`)\n");
        std.process.exit(1);
    }
}

fn printUsage(io: std.Io) !void {
    try std.Io.File.stderr().writeStreamingAll(io, Usage);
}

/// Report a compile error with file:line:col and a source-line
/// caret:
///
///   nexis: <path>:<line>:<col>: <ErrorKind>
///       <source line>
///       <spaces><caret>
fn emitCompileError(
    io: std.Io,
    path: []const u8,
    source: []const u8,
    err: anyerror,
    maybe_span: ?reader_mod.SrcSpan,
) !void {
    if (maybe_span) |span| {
        try emitSourceError(io, path, source, @errorName(err), span);
    } else {
        // An error without a span is reported bare.
        const stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(io, "nexis: compile error: ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
    }
}

/// Report a compile failure and return the exit code it carries:
/// 4 at its span, or 5 when a `require` inside the form ran a
/// file whose form failed at run time, which is reported as the
/// runtime error it is, with the trace the failed run left.
fn reportCompileFailure(rt: *Runtime, io: std.Io, path: []const u8, source: []const u8, err: anyerror, maybe_span: ?reader_mod.SrcSpan) !u8 {
    if (err == compile.CompileError.RequiredFileFailed) {
        try rt.reportRuntimeError(io, rt.v.traced_error orelse err);
        return 5;
    }
    try emitCompileError(io, path, source, err, maybe_span);
    return 4;
}

/// Report a parse failure at the token the parser stopped on:
///
///   nexis: <path>:<line>:<col>: parse error: unexpected `)`
///
/// or `unexpected end of input` past the last token.
fn emitParseError(io: std.Io, path: []const u8, source: []const u8, p: *const reader_mod.parser.Parser) !void {
    const pos: u32 = @intCast(@min(p.current.pos, source.len));
    var buf: [128]u8 = undefined;
    const label = if (pos >= source.len)
        "parse error: unexpected end of input"
    else
        try std.fmt.bufPrint(&buf, "parse error: unexpected `{s}`", .{source[pos..@min(source.len, pos + @as(usize, @max(p.current.len, 1)))]});
    const len: u32 = if (pos >= source.len) 1 else @max(p.current.len, 1);
    try emitSourceError(io, path, source, label, .{ .pos = pos, .len = len });
}

/// Report a reader failure at the form it rejected, with the kind
/// the golden `.err` files name (`:map-odd-count`) and the reader's
/// detail when it has one:
///
///   nexis: <path>:<line>:<col>: reader error: :duplicate-literal-key :a
///
/// A failure the reader did not record (out of memory, invalid
/// UTF-8) is reported bare.
fn emitReaderError(io: std.Io, path: []const u8, source: []const u8, rdr: *const reader_mod.Reader, err: anyerror) !void {
    const e = rdr.err orelse {
        const stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(io, "nexis: reader error: ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
        return;
    };
    var buf: [256]u8 = undefined;
    const kind = @tagName(e.kind);
    const label = if (e.detail) |detail|
        try std.fmt.bufPrint(&buf, "reader error: :{s} {s}", .{ kind, detail })
    else
        try std.fmt.bufPrint(&buf, "reader error: :{s}", .{kind});
    // Kinds are spelled with underscores in Zig and dashes in nexis.
    std.mem.replaceScalar(u8, buf[0..label.len], '_', '-');
    try emitSourceError(io, path, source, label, e.span);
}

/// `nexis: <path>:<line>:<col>: <label>`, then the source line
/// and a caret under the span.
fn emitSourceError(
    io: std.Io,
    path: []const u8,
    source: []const u8,
    label: []const u8,
    span: reader_mod.SrcSpan,
) !void {
    const stderr = std.Io.File.stderr();
    const info = vm.SourceInfo{ .path = path, .text = source };
    const loc = info.lineCol(span.pos);
    var buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf, "nexis: {s}:{d}:{d}: {s}\n", .{ path, loc.line, loc.col, label });
    try stderr.writeStreamingAll(io, header);
    const line_text = info.lineText(loc.line);
    if (line_text.len > 0) {
        try stderr.writeStreamingAll(io, "    ");
        try stderr.writeStreamingAll(io, line_text);
        try stderr.writeStreamingAll(io, "\n    ");
        var i: usize = 1;
        while (i < loc.col) : (i += 1) try stderr.writeStreamingAll(io, " ");
        // One caret per byte of the span, at least one.
        const span_len: usize = if (span.len < 1) 1 else span.len;
        var j: usize = 0;
        while (j < span_len) : (j += 1) try stderr.writeStreamingAll(io, "^");
        try stderr.writeStreamingAll(io, "\n");
    }
}

/// The embedded sources, as the routines compiled from them name
/// them in a stack trace.
const core_source = vm.SourceInfo{ .path = "core.nx", .text = stdlib.CORE_NX_SOURCE };
const nextomic_source = vm.SourceInfo{ .path = "nextomic.nx", .text = stdlib.NEXTOMIC_NX_SOURCE };
const test_source = vm.SourceInfo{ .path = "test.nx", .text = stdlib.TEST_NX_SOURCE };
const pprint_source = vm.SourceInfo{ .path = "pprint.nx", .text = stdlib.PPRINT_NX_SOURCE };
const math_source = vm.SourceInfo{ .path = "math.nx", .text = stdlib.MATH_NX_SOURCE };

/// The routine the VM is created around; `retargetTop` replaces it
/// before anything runs.
/// A VM with `nexis.core`, `db`, `nexis.string`, `nexis.internal`,
/// `nexis.math` and `nextomic` installed, the embedded core.nx,
/// nextomic.nx, test.nx, pprint.nx and math.nx bootstrapped into
/// their namespaces, and a namespace loader
/// that searches `load_paths` when `(require ...)` fires. The
/// current namespace is `user`.
const Runtime = struct {
    allocator: std.mem.Allocator,
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    loader: loader_mod.Loader,
    /// What `macroexpand-1` and `read-string` call into.
    hooks: compile.RuntimeHooks,
    interner: *intern_mod.Interner,
    registry: *vm.NamespaceRegistry,

    fn deinit(self: *Runtime) void {
        self.loader.deinit();
        self.host_macros.deinit(self.allocator);
        self.v.deinit();
    }

    /// Where `defmacro` closures and bootstrap routines live: the
    /// VM's runtime arena, so they outlive any per-form arena.
    fn persistent(self: *Runtime) std.mem.Allocator {
        return self.v.runtime_arena.allocator();
    }

    /// Everything the compiler needs from the runtime; `declared`,
    /// `out_span` and `source` are per call.
    fn compileOptions(self: *Runtime, out_span: ?*?reader_mod.SrcSpan, declared: ?*compile.DeclaredNames, source: *const vm.SourceInfo) compile.CompileOptions {
        return .{
            .namespace = self.registry.current,
            .interner = self.interner,
            .host_macros = &self.host_macros,
            .out_span = out_span,
            .persistent_allocator = self.persistent(),
            .registry = self.registry,
            .load_callback = .{ .user_data = @ptrCast(&self.loader), .load = &loader_mod.Loader.loadCallback },
            .declared = declared,
            .source = source,
        };
    }

    /// Run one compiled top-level form on the VM; `<top>` is how a
    /// stack trace names its frame.
    fn runCompiled(self: *Runtime, compiled: compile.Compiled) vm.VmError!Value {
        const routine = compiled.toRoutine("<top>");
        try self.v.retargetTop(&routine);
        return self.v.run();
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
    fn reportRuntimeError(self: *Runtime, io: std.Io, err: anyerror) !void {
        const stderr = std.Io.File.stderr();
        var label_buf: [4096]u8 = undefined;
        var label_stream = std.Io.Writer.fixed(&label_buf);
        try label_stream.print("runtime error: {s}", .{@errorName(err)});
        if (err == vm.VmError.UncaughtThrow) {
            if (self.v.unhandled_throw) |payload| {
                try label_stream.writeAll(" ");
                format_mod.format(payload, .readable, &label_stream, self.interner) catch {
                    try label_stream.writeAll("#<value too large to print>");
                };
            }
        }
        const label = label_stream.buffered();

        const trace = self.v.error_trace.items;
        const located = trace.len > 0 and trace[0].span != null and trace[0].source != null;
        if (located) {
            const src = trace[0].source.?;
            try emitSourceError(io, src.path, src.text, label, .{ .pos = trace[0].span.?.pos, .len = trace[0].span.?.len });
        } else {
            try stderr.writeStreamingAll(io, "nexis: ");
            try stderr.writeStreamingAll(io, label);
            try stderr.writeStreamingAll(io, "\n");
        }
        for (trace) |frame| {
            var buf: [1024]u8 = undefined;
            const line = if (frame.source) |src| blk: {
                if (frame.span) |span| {
                    const loc = src.lineCol(span.pos);
                    break :blk try std.fmt.bufPrint(&buf, "  at {s} ({s}:{d}:{d})\n", .{ frame.name, src.path, loc.line, loc.col });
                }
                break :blk try std.fmt.bufPrint(&buf, "  at {s} ({s})\n", .{ frame.name, src.path });
            } else try std.fmt.bufPrint(&buf, "  at {s}\n", .{frame.name});
            try stderr.writeStreamingAll(io, line);
        }
    }
};

/// Build a `Runtime` in place. `load_paths` must outlive it.
fn bootRuntime(rt: *Runtime, io: std.Io, allocator: std.mem.Allocator, load_paths: []const []const u8) !void {
    rt.allocator = allocator;
    rt.v = try vm.VM.init(allocator, &vm.VM.idle_routine);
    errdefer rt.v.deinit();
    // `(db/open path)` creates the path's parent directories through
    // the CLI's std.Io; emdb itself does not.
    rt.v.io = io;
    rt.interner = rt.v.ensureInterner();
    rt.registry = try rt.v.ensureRegistry();
    // Natives live in nexis.core (auto-referred by user) and in the
    // qualified-only namespaces; each qualified namespace has
    // nexis.core as its parent.
    try stdlib.installCore(rt.registry.core);
    const db_ns = try rt.registry.getOrCreate("db", rt.registry.core);
    try stdlib.installDb(db_ns);
    const string_ns = try rt.registry.getOrCreate("nexis.string", rt.registry.core);
    try stdlib.installString(string_ns);
    const internal_ns = try rt.registry.getOrCreate("nexis.internal", rt.registry.core);
    try stdlib.installInternal(internal_ns);
    const nextomic_ns = try rt.registry.getOrCreate("nextomic", rt.registry.core);
    try stdlib.installNextomic(nextomic_ns);
    const test_ns = try rt.registry.getOrCreate("nexis.test", rt.registry.core);
    const pprint_ns = try rt.registry.getOrCreate("nexis.pprint", rt.registry.core);
    const math_ns = try rt.registry.getOrCreate("nexis.math", rt.registry.core);
    try stdlib.installMath(math_ns);
    rt.host_macros = try expand_mod.defaultMacros(allocator);
    errdefer rt.host_macros.deinit(allocator);
    // The embedded sources define into their own namespaces; core.nx
    // first so nextomic.nx can use it.
    try bootstrapEmbedded(rt, rt.registry.core, &core_source);
    try bootstrapEmbedded(rt, nextomic_ns, &nextomic_source);
    try bootstrapEmbedded(rt, test_ns, &test_source);
    try bootstrapEmbedded(rt, pprint_ns, &pprint_source);
    try bootstrapEmbedded(rt, math_ns, &math_source);
    rt.loader = loader_mod.Loader.init(
        allocator,
        rt.persistent(),
        io,
        load_paths,
        &rt.v,
        rt.interner,
        rt.registry,
        &rt.host_macros,
    );
    rt.hooks = .{
        .host_macros = &rt.host_macros,
        .registry = rt.registry,
        .interner = rt.interner,
        .load_callback = .{ .user_data = @ptrCast(&rt.loader), .load = &loader_mod.Loader.loadCallback },
    };
    rt.hooks.install(&rt.v);
}

/// Compile and evaluate one embedded source into `ns`, one
/// top-level form at a time, so each definition is visible to
/// the forms after it. Errors here are bugs in the embedded
/// source, not in user code: the process panics rather than come
/// up with half a stdlib.
fn bootstrapEmbedded(rt: *Runtime, ns: *vm.Namespace, info: *const vm.SourceInfo) !void {
    const allocator = rt.allocator;
    const source = info.text;
    const label = info.path;
    var parse_result = reader_mod.parser.parseProgram(allocator, source) catch |err| {
        std.debug.panic("nexis: {s} parse error: {s}\n", .{ label, @errorName(err) });
    };
    defer parse_result.parser.deinit();

    var rdr = reader_mod.Reader.init(allocator, source);
    defer rdr.deinit();
    const forms = rdr.readProgram(parse_result.sexp) catch |err| {
        std.debug.panic("nexis: {s} reader error: {s}\n", .{ label, @errorName(err) });
    };

    const saved_current = rt.registry.current;
    rt.registry.current = ns;
    defer rt.registry.current = saved_current;

    // The routines of ordinary defns are referenced by closures in
    // Var roots that outlive bootstrap, so they are compiled into
    // the persistent allocator, not a temporary arena.
    for (forms) |form| {
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormWith(rt.persistent(), form, .{
            .namespace = ns,
            .interner = rt.interner,
            .host_macros = &rt.host_macros,
            .out_span = &error_span,
            .persistent_allocator = rt.persistent(),
            .registry = rt.registry,
            .source = info,
        }) catch |err| {
            std.debug.panic("nexis: {s} compile error: {s} (form span: {?})\n", .{ label, @errorName(err), error_span });
        };
        _ = rt.runCompiled(compiled) catch |err| {
            std.debug.panic("nexis: {s} runtime error: {s}\n", .{ label, @errorName(err) });
        };
    }
}

/// Interactive read-eval-print loop: one form per input line,
/// evaluated on a runtime that persists for the session; errors
/// are printed and the loop continues. `:quit`, `:q` or EOF exits.
fn runRepl(io: std.Io, allocator: std.mem.Allocator) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    const load_paths = [_][]const u8{"."};
    var rt: Runtime = undefined;
    try bootRuntime(&rt, io, allocator, &load_paths);
    defer rt.deinit();

    try stdout.writeStreamingAll(io,
        \\nexis repl
        \\Type `:quit` or hit Ctrl-D to exit.
        \\
        \\
    );

    var stdin_buf: [4096]u8 = undefined;
    var reader = stdin.readerStreaming(io, &stdin_buf);

    while (true) {
        try stdout.writeStreamingAll(io, "user=> ");
        // takeDelimiter returns null at EOF. The returned slice
        // excludes the delimiter and the reader advances past it
        // (takeDelimiterExclusive leaves it in the buffer and
        // loops forever on empty lines).
        const maybe_line = (reader.interface.takeDelimiter('\n')) catch |err| {
            try stderr.writeStreamingAll(io, "nexis: stdin read error: ");
            try stderr.writeStreamingAll(io, @errorName(err));
            try stderr.writeStreamingAll(io, "\n");
            return;
        };
        const line = maybe_line orelse {
            try stdout.writeStreamingAll(io, "\n");
            return;
        };
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, ":quit") or std.mem.eql(u8, trimmed, ":q")) return;

        // Closures and their routines reference sub-routine pointers
        // that live in the compile arena, and a line's definitions
        // are called from later lines, so every line compiles into
        // the persistent arena. The source bytes go there too:
        // Tiny.symbol slices borrow from them.
        const src = try rt.persistent().dupe(u8, trimmed);
        // Routines defined on this line name it in later traces.
        const line_source = try rt.persistent().create(vm.SourceInfo);
        line_source.* = .{ .path = "<repl>", .text = src };

        // A REPL line may only refer to what exists or what the
        // line itself defines; the compiler reports anything else
        // at the symbol.
        var declared = compile.DeclaredNames.init(allocator);
        defer declared.deinit();
        // One form per line, located like a file's.
        var parser = reader_mod.parser.Parser.init(allocator, src);
        defer parser.deinit();
        const sexp = parser.parseForm() catch {
            try emitParseError(io, "<repl>", src, &parser);
            continue;
        };
        var line_reader = reader_mod.Reader.init(allocator, src);
        defer line_reader.deinit();
        const form = line_reader.readOneForm(sexp) catch |err| {
            try emitReaderError(io, "<repl>", src, &line_reader, err);
            continue;
        };
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormWith(rt.persistent(), form, rt.compileOptions(&error_span, &declared, line_source)) catch |err| {
            _ = try reportCompileFailure(&rt, io, "<repl>", src, err, error_span);
            // A `require` inside the form may have run a file whose
            // form failed; that run's frames must not leak either.
            rt.v.resetAfterError();
            continue;
        };

        const result = rt.runCompiled(compiled) catch |err| {
            try rt.reportRuntimeError(io, err);
            // The frames and handlers an aborted run left must
            // not leak into the next line.
            rt.v.resetAfterError();
            continue;
        };

        var out_buf: [4096]u8 = undefined;
        var out_stream = std.Io.Writer.fixed(&out_buf);
        formatValue(result, rt.interner, &out_stream) catch {
            try stdout.writeStreamingAll(io, "#<value too large to print>\n");
            continue;
        };
        try stdout.writeStreamingAll(io, out_stream.buffered());
        try stdout.writeStreamingAll(io, "\n");
    }
}

/// Read FILE.nx, parse, compile and run each top-level form, and
/// print the final result to stdout.
fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const stderr = std.Io.File.stderr();
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        try stderr.writeStreamingAll(io, "nexis: failed to read '");
        try stderr.writeStreamingAll(io, path);
        try stderr.writeStreamingAll(io, "': ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
        std.process.exit(2);
    };
    defer allocator.free(source);

    // The parser owns the Sexp tree, the reader the Form tree.
    var parser = reader_mod.parser.Parser.init(allocator, source);
    defer parser.deinit();
    const sexp = parser.parseProgram() catch {
        try emitParseError(io, path, source, &parser);
        std.process.exit(3);
    };

    var reader = reader_mod.Reader.init(allocator, source);
    defer reader.deinit();

    const forms = reader.readProgram(sexp) catch |err| {
        try emitReaderError(io, path, source, &reader, err);
        std.process.exit(3);
    };

    // An empty file prints nothing.
    if (forms.len == 0) return;

    // `require` searches the working directory and the file's own.
    const file_dir = std.fs.path.dirname(path) orelse ".";
    const load_paths = [_][]const u8{ ".", file_dir };
    var rt: Runtime = undefined;
    try bootRuntime(&rt, io, allocator, &load_paths);
    defer rt.deinit();

    // One compile arena for the whole file: Form trees, Tiny IR and
    // Compiled routines, released together at the end.
    var compile_arena = std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();

    // Every name the file defines may be referred to from any form
    // in it (forward references); a symbol that resolves to nothing
    // else is a compile error at its span.
    var declared = compile.DeclaredNames.init(allocator);
    defer declared.deinit();
    for (forms) |form| try declared.declareForm(form);

    const file_source = vm.SourceInfo{ .path = path, .text = source };
    var last_result: Value = value_mod.nilValue();
    for (forms) |form| {
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormWith(compile_arena.allocator(), form, rt.compileOptions(&error_span, &declared, &file_source)) catch |err| {
            std.process.exit(try reportCompileFailure(&rt, io, path, source, err, error_span));
        };
        last_result = rt.runCompiled(compiled) catch |err| {
            try rt.reportRuntimeError(io, err);
            std.process.exit(5);
        };
    }

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    formatValue(last_result, rt.interner, &stream) catch {
        try std.Io.File.stdout().writeStreamingAll(io, "#<value too large to print>\n");
        return;
    };
    try std.Io.File.stdout().writeStreamingAll(io, stream.buffered());
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

/// Read FILE.nx, parse and compile each top-level form the way
/// `run` does, and print every routine's disassembly to stdout
/// instead of running it. Macro expansion, `(ns ...)` and
/// `(require ...)` still take effect at compile time; a `def` does
/// not run, so a macro that calls a function the same file defines
/// cannot expand here.
fn disasmFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    const stderr = std.Io.File.stderr();
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        try stderr.writeStreamingAll(io, "nexis: failed to read '");
        try stderr.writeStreamingAll(io, path);
        try stderr.writeStreamingAll(io, "': ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
        std.process.exit(2);
    };
    defer allocator.free(source);

    var parser = reader_mod.parser.Parser.init(allocator, source);
    defer parser.deinit();
    const sexp = parser.parseProgram() catch {
        try emitParseError(io, path, source, &parser);
        std.process.exit(3);
    };
    var reader = reader_mod.Reader.init(allocator, source);
    defer reader.deinit();
    const forms = reader.readProgram(sexp) catch |err| {
        try emitReaderError(io, path, source, &reader, err);
        std.process.exit(3);
    };
    if (forms.len == 0) return;

    const file_dir = std.fs.path.dirname(path) orelse ".";
    const load_paths = [_][]const u8{ ".", file_dir };
    var rt: Runtime = undefined;
    try bootRuntime(&rt, io, allocator, &load_paths);
    defer rt.deinit();

    var compile_arena = std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();
    var declared = compile.DeclaredNames.init(allocator);
    defer declared.deinit();
    for (forms) |form| try declared.declareForm(form);

    const file_source = vm.SourceInfo{ .path = path, .text = source };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (forms, 0..) |form, i| {
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormWith(compile_arena.allocator(), form, rt.compileOptions(&error_span, &declared, &file_source)) catch |err| {
            std.process.exit(try reportCompileFailure(&rt, io, path, source, err, error_span));
        };
        const routine = compiled.toRoutine("<top>");
        if (i > 0) try out.writer.writeAll("\n");
        try disasm_mod.disassemble(&routine, rt.interner, &out.writer);
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
}
