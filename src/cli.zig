//! nexis CLI: `nexis run FILE.nx` and `nexis repl`.
//!
//! Both commands boot one `Runtime` (a VM with every namespace
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
    \\
    \\For `run`, Vars and the interner persist across forms within
    \\the file; for `repl`, across the whole session.
    \\
    \\Namespaces available without a file: nexis.core (auto-referred),
    \\db (key-value storage on emdb), nextomic (Datomic-class datoms:
    \\transact!, q, pull, as-of/since/history, with), nexis.string,
    \\nexis.internal. See README.md and docs/NEXTOMIC.md.
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
    const stderr = std.Io.File.stderr();
    if (maybe_span) |span| {
        const loc = byteOffsetToLineCol(source, span.pos);
        var buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&buf, "nexis: {s}:{d}:{d}: {s}\n", .{ path, loc.line, loc.col, @errorName(err) });
        try stderr.writeStreamingAll(io, header);
        // Show source line + caret.
        const line_text = lineAt(source, loc.line);
        if (line_text.len > 0) {
            try stderr.writeStreamingAll(io, "    ");
            try stderr.writeStreamingAll(io, line_text);
            try stderr.writeStreamingAll(io, "\n    ");
            var i: usize = 1;
            while (i < loc.col) : (i += 1) try stderr.writeStreamingAll(io, " ");
            // Caret(s): one for each byte in the span, but cap
            // at the line length so we don't run off.
            const span_len: usize = if (span.len < 1) 1 else span.len;
            var j: usize = 0;
            while (j < span_len) : (j += 1) try stderr.writeStreamingAll(io, "^");
            try stderr.writeStreamingAll(io, "\n");
        }
    } else {
        // No span — fall back to the prior bare-error format.
        try stderr.writeStreamingAll(io, "nexis: compile error: ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
    }
}

const LineCol = struct { line: u32, col: u32 };

fn byteOffsetToLineCol(source: []const u8, offset: u32) LineCol {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: u32 = 0;
    const cap: u32 = if (offset < source.len) offset else @intCast(source.len);
    while (i < cap) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ .line = line, .col = col };
}

fn lineAt(source: []const u8, line: u32) []const u8 {
    var current_line: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (current_line == line) return source[start..i];
            current_line += 1;
            start = i + 1;
        }
    }
    if (current_line == line) return source[start..];
    return "";
}

/// The routine the VM is created around; `retargetTop` replaces it
/// before anything runs.
const stub_code = [_]vm.Inst{vm.asm_.returnNil()};
const stub_routine = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };

/// A VM with `nexis.core`, `db`, `nexis.string`, `nexis.internal`
/// and `nextomic` installed, the embedded core.nx and nextomic.nx
/// bootstrapped into their namespaces, and a namespace loader
/// that searches `load_paths` when `(require ...)` fires. The
/// current namespace is `user`.
const Runtime = struct {
    allocator: std.mem.Allocator,
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    loader: loader_mod.Loader,
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

    /// Everything the compiler needs from the runtime; `declared`
    /// and `out_span` are per call.
    fn compileOptions(self: *Runtime, out_span: ?*?reader_mod.SrcSpan, declared: ?*compile.DeclaredNames) compile.CompileOptions {
        return .{
            .namespace = self.registry.current,
            .interner = self.interner,
            .host_macros = &self.host_macros,
            .out_span = out_span,
            .persistent_allocator = self.persistent(),
            .registry = self.registry,
            .load_callback = .{ .user_data = @ptrCast(&self.loader), .load = &loader_mod.Loader.loadCallback },
            .declared = declared,
        };
    }

    /// Run one compiled top-level form on the VM.
    fn runCompiled(self: *Runtime, compiled: compile.Compiled, label: []const u8) vm.VmError!Value {
        const routine = compiled.toRoutine(label);
        try self.v.retargetTop(&routine);
        return self.v.run();
    }

    /// Print a runtime error and, for an uncaught throw, its payload.
    fn reportRuntimeError(self: *Runtime, io: std.Io, err: anyerror) !void {
        const stderr = std.Io.File.stderr();
        try stderr.writeStreamingAll(io, "nexis: runtime error: ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
        if (err != vm.VmError.UncaughtThrow) return;
        if (self.v.unhandled_throw) |payload| {
            var buf: [4096]u8 = undefined;
            var stream = std.Io.Writer.fixed(&buf);
            if (formatValue(payload, self.interner, &stream)) |_| {
                try stderr.writeStreamingAll(io, "  payload: ");
                try stderr.writeStreamingAll(io, stream.buffered());
                try stderr.writeStreamingAll(io, "\n");
            } else |_| {
                try stderr.writeStreamingAll(io, "  (payload too large to print)\n");
            }
        }
    }
};

/// Build a `Runtime` in place. `load_paths` must outlive it.
fn bootRuntime(rt: *Runtime, io: std.Io, allocator: std.mem.Allocator, load_paths: []const []const u8) !void {
    rt.allocator = allocator;
    rt.v = try vm.VM.init(allocator, &stub_routine);
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
    rt.host_macros = try expand_mod.defaultMacros(allocator);
    errdefer rt.host_macros.deinit(allocator);
    // The embedded sources define into their own namespaces; core.nx
    // first so nextomic.nx can use it.
    try bootstrapEmbedded(rt, rt.registry.core, stdlib.CORE_NX_SOURCE, "core.nx");
    try bootstrapEmbedded(rt, nextomic_ns, stdlib.NEXTOMIC_NX_SOURCE, "nextomic.nx");
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
}

/// Compile and evaluate one embedded source into `ns`, one
/// top-level form at a time, so each definition is visible to
/// the forms after it. Errors here are bugs in the embedded
/// source, not in user code: the process panics rather than come
/// up with half a stdlib.
fn bootstrapEmbedded(rt: *Runtime, ns: *vm.Namespace, source: []const u8, label: []const u8) !void {
    const allocator = rt.allocator;
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
        }) catch |err| {
            std.debug.panic("nexis: {s} compile error: {s} (form span: {?})\n", .{ label, @errorName(err), error_span });
        };
        _ = rt.runCompiled(compiled, label) catch |err| {
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

        // A REPL line may only refer to what exists or what the
        // line itself defines; the compiler reports anything else
        // at the symbol.
        var declared = compile.DeclaredNames.init(allocator);
        defer declared.deinit();
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileSourceWith(rt.persistent(), src, rt.compileOptions(&error_span, &declared)) catch |err| {
            try emitCompileError(io, "<repl>", src, err, error_span);
            continue;
        };

        const result = rt.runCompiled(compiled, "repl") catch |err| {
            try rt.reportRuntimeError(io, err);
            // An aborted try must not leak handlers into the next line.
            rt.v.handlers.shrinkRetainingCapacity(0);
            rt.v.finally_stack.shrinkRetainingCapacity(0);
            rt.v.unhandled_throw = null;
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
    var parse_result = reader_mod.parser.parseProgram(allocator, source) catch |err| {
        try stderr.writeStreamingAll(io, "nexis: parse error: ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
        std.process.exit(3);
    };
    defer parse_result.parser.deinit();

    var reader = reader_mod.Reader.init(allocator, source);
    defer reader.deinit();

    const forms = reader.readProgram(parse_result.sexp) catch |err| {
        try stderr.writeStreamingAll(io, "nexis: reader error: ");
        try stderr.writeStreamingAll(io, @errorName(err));
        try stderr.writeStreamingAll(io, "\n");
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

    var last_result: Value = value_mod.nilValue();
    for (forms) |form| {
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormWith(compile_arena.allocator(), form, rt.compileOptions(&error_span, &declared)) catch |err| {
            try emitCompileError(io, path, source, err, error_span);
            std.process.exit(4);
        };
        last_result = rt.runCompiled(compiled, "file-form") catch |err| {
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
