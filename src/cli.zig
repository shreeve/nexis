//! nexis CLI — minimal source runner.
//!
//! Step H1 (peer-AI turn 55). Tiny integration-shell that lets
//! users execute `.nx` source files without going through Zig
//! tests. Deliberately small: no REPL, no module loading, no
//! pretty diagnostics, no watch mode. Future scope (Phase 3):
//! REPL via `nexis repl`, module loading via `:require`,
//! structured error rendering with SrcSpans (step #10).
//!
//! Usage:
//!   nexis run FILE.nx     read FILE, parse all top-level forms,
//!                         compile + run each in order, print
//!                         the final result.
//!
//! Pipeline:
//!   source bytes
//!   → parser.parseProgram → Sexp
//!   → Reader.readProgram  → []const *Form
//!   → for each form:
//!       → compileFormFull (VM's ns + interner)
//!       → VM.run
//!   → print last result via formatValue
//!
//! Multi-form files work because the VM (and its namespace +
//! interner) persists across iterations; each form re-uses the
//! same frame, recycled by replacing routine + pc + slot_count.

const std = @import("std");
const value_mod = @import("value");
const vm = @import("vm");
const compile = @import("compile");
const reader_mod = @import("reader");
const intern_mod = @import("intern");
const expand_mod = @import("expand");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const stdlib = @import("stdlib");

const Value = value_mod.Value;

/// Pretty-print a Value to the given writer. Step H1 covers the
/// kinds the current language produces:
///   nil / true / false / fixnum / symbol / keyword
///   function (closure — printed as #<fn>)
///   var_ (printed as #'name)
///   list (recursive)
/// Everything else falls back to a kind-tag placeholder. Phase 3
/// will replace this with a proper formatValue per VALUE.md.
fn formatValue(v: Value, interner: *const intern_mod.Interner, writer: anytype) !void {
    switch (v.kind()) {
        .nil => try writer.writeAll("nil"),
        .true_ => try writer.writeAll("true"),
        .false_ => try writer.writeAll("false"),
        .fixnum => try writer.print("{d}", .{v.asFixnum()}),
        .symbol => {
            const id: u32 = @intCast(v.payload);
            try writer.print("{s}", .{interner.symbolName(id)});
        },
        .keyword => {
            const id: u32 = @intCast(v.payload);
            try writer.print(":{s}", .{interner.keywordName(id)});
        },
        .function => try writer.writeAll("#<fn>"),
        .var_ => {
            const var_obj = vm.VM.asVar(v);
            try writer.print("#'{s}", .{var_obj.name});
        },
        .list => {
            // Step #8c.1: walk the list and recursively format
            // each element. Empty list prints as `()`.
            try writer.writeAll("(");
            var node = v;
            var first = true;
            while (node.kind() == .list and !list_mod.isEmpty(node)) {
                if (!first) try writer.writeAll(" ");
                first = false;
                try formatValue(list_mod.head(node), interner, writer);
                node = list_mod.tail(node);
            }
            try writer.writeAll(")");
        },
        .persistent_vector => {
            // Step #8c.3: print as [a b c]. Empty as [].
            try writer.writeAll("[");
            const n = vector_mod.count(v);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try writer.writeAll(" ");
                try formatValue(vector_mod.nth(v, i), interner, writer);
            }
            try writer.writeAll("]");
        },
        .persistent_map => {
            // Phase 3.1: print as {k1 v1, k2 v2}. Empty as {}.
            // Iteration order is implementation-defined for
            // CHAMP; for deterministic test output, a stable
            // key-sorted printer can come later.
            try writer.writeAll("{");
            var it = champ_mod.mapIter(v);
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try formatValue(entry.key, interner, writer);
                try writer.writeAll(" ");
                try formatValue(entry.value, interner, writer);
            }
            try writer.writeAll("}");
        },
        .persistent_set => {
            // Phase 3.1: print as #{a b c}. Empty as #{}.
            try writer.writeAll("#{");
            var it = champ_mod.setIter(v);
            var first = true;
            while (it.next()) |elem| {
                if (!first) try writer.writeAll(" ");
                first = false;
                try formatValue(elem, interner, writer);
            }
            try writer.writeAll("}");
        },
        else => try writer.print("#<value kind={d}>", .{@intFromEnum(v.kind())}),
    }
}

const Usage =
    \\nexis — A Lisp where immutable values, transactional durable
    \\        identity, and historical snapshots are one coherent
    \\        programming model.
    \\
    \\usage:
    \\  nexis run FILE.nx    Reads FILE.nx, parses all top-level
    \\                       forms, compiles and runs each in
    \\                       order, prints the final result.
    \\  nexis repl           Interactive read-eval-print loop.
    \\                       :quit or EOF to exit.
    \\
    \\For `run`, the namespace (Vars from `def`/`defn`) and
    \\interner persist across forms within the file. For `repl`,
    \\they persist across the entire session.
    \\
    \\Phase 2 source surface (what compiles today):
    \\  literals: nil, true, false, integers, :keywords
    \\  arithmetic: (+ a b), (< a b)
    \\  conditionals: (if test then else?), (do ...)
    \\  bindings: (let [name1 v1 ...] body...)  -- or let*
    \\  functions: (fn name? [params & rest?] body...)  -- or fn*
    \\  recursion: (loop [...] body...) (recur args...)  -- or loop*
    \\  vars: (def name value?), (defn name [params] body...), (var name)
    \\  quoting: (quote x), 'x (scalars + interned symbols/keywords)
    \\  mutual: (letfn* [(name [params] body...) ...] body...)
    \\  macros: when, when-not, and, or, cond, ->, ->>
    \\  exceptions: (try body (catch any e handler) [(finally ...)])
    \\              (throw value)
    \\
    \\Phase 3.0 + 3.1 surface (also shipped):
    \\  - `nexis repl` interactive eval
    \\  - `#(...)` anon-fn shorthand with %, %1..%N, %&
    \\  - try/catch can now catch recoverable VM errors as
    \\    keywords: :kind-mismatch, :unbound-var, :arity-mismatch,
    \\    :not-callable, :integer-overflow
    \\  - collection literals: [vectors], {maps}, #{sets}
    \\    + quoted forms of all three
    \\
    \\Limitations (post-v1):
    \\  - recur-in-try: not supported (wrap try around loop)
    \\  - user defmacro / multi-namespace / stdlib: Phase 3+
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

/// Step #10.0: format a compile error with file:line:col +
/// source-line caret. Closes COMPILER.md §9.4 gate item 5
/// for compile-side errors (runtime VmError SrcSpans defer
/// to post-gate).
///
/// Format:
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

/// Step Phase-3.0a (peer-AI turn 62): interactive read-eval-
/// print loop. One form per input line; persistent namespace +
/// interner across iterations; errors print + continue (REPL
/// never crashes on user code).
///
/// MVP scope (peer recommendation):
///   - single-form-per-line (no multiline continuation in v1)
///   - persistent ns/interner across the session
///   - default macro table active
///   - `:quit` / `:q` / EOF exits
///   - errors caught + printed without exiting the loop
/// Phase 3.3d (peer-AI turn 67 §3.3d): compile + evaluate the
/// embedded `core.nx` source against the supplied VM. Each
/// top-level form runs sequentially in a fresh stub frame, so
/// `def`/`defn`/`defmacro` mutations land in `ns` and become
/// visible to subsequent forms (and to user code that runs
/// after bootstrap).
///
/// Errors here are FATAL — they indicate a bug in `core.nx`
/// itself, not user code. We print and exit so the CLI doesn't
/// silently come up with a half-loaded stdlib.
fn bootstrapCoreNx(
    v: *vm.VM,
    ns: *vm.Namespace,
    interner: *intern_mod.Interner,
    allocator: std.mem.Allocator,
) !void {
    var parse_result = reader_mod.parser.parseProgram(allocator, stdlib.CORE_NX_SOURCE) catch |err| {
        std.debug.panic("nexis: core.nx parse error: {s}\n", .{@errorName(err)});
    };
    defer parse_result.parser.deinit();

    var rdr = reader_mod.Reader.init(allocator, stdlib.CORE_NX_SOURCE);
    defer rdr.deinit();
    const forms = rdr.readProgram(parse_result.sexp) catch |err| {
        std.debug.panic("nexis: core.nx reader error: {s}\n", .{@errorName(err)});
    };

    var host_macros = try expand_mod.defaultMacros(allocator);
    defer host_macros.deinit(allocator);

    // CRITICAL: use the VM's runtime arena as the compile arena
    // for bootstrap. ORDINARY `defn` compiled Routines live in
    // the compile arena and are referenced by Closures stored in
    // Var.roots. Those Vars must outlive bootstrap, so the
    // routines must too. A separate temp compile_arena would
    // dangle on bootstrap exit and crash on first user call to
    // any core.nx fn. (Macros already use the persistent
    // allocator via `compileFormFullWithMacrosSpanPersistent`,
    // but ordinary fns need it too.)
    const ra = v.runtime_arena.allocator();

    for (forms) |form| {
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormFullWithMacrosSpanPersistent(
            ra,
            form,
            ns,
            interner,
            &host_macros,
            &error_span,
            ra,
        ) catch |err| {
            std.debug.panic("nexis: core.nx compile error: {s} (form span: {?})\n", .{ @errorName(err), error_span });
        };
        const routine = compiled.toRoutine("core-nx");
        v.frames.items[0].routine = &routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = routine.slot_count;
        v.halted = false;
        if (v.stack.items.len < routine.slot_count) {
            try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
        }
        _ = v.run() catch |err| {
            std.debug.panic("nexis: core.nx runtime error: {s}\n", .{@errorName(err)});
        };
    }
}

fn runRepl(io: std.Io, allocator: std.mem.Allocator) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

    // Initialize the persistent VM + namespace + interner +
    // macro table. These outlive every REPL evaluation.
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    // Phase 3.3a: install core native fns (list/cons/first/rest/
    // count/nth/empty?/identity/nil?/some?) into the namespace
    // so they're callable from user code AND from compile-time
    // macro bodies. Names are string literals; no allocator
    // needed for storage.
    try stdlib.installCore(ns);
    // Phase 3.3d: bootstrap the embedded core.nx composite
    // layer.
    try bootstrapCoreNx(&v, ns, interner, allocator);
    var host_macros = try expand_mod.defaultMacros(allocator);
    defer host_macros.deinit(allocator);

    // Each evaluation gets its own arena so we can release
    // form/Tiny/Compiled memory between iterations. The VM's
    // runtime_arena holds the long-lived values (closures,
    // cells, list nodes).
    try stdout.writeStreamingAll(io,
        \\nexis repl — Phase 3.0a
        \\Type `:quit` or hit Ctrl-D to exit.
        \\
        \\
    );

    var stdin_buf: [4096]u8 = undefined;
    var reader = stdin.readerStreaming(io, &stdin_buf);

    while (true) {
        try stdout.writeStreamingAll(io, "user=> ");
        // takeDelimiter returns ?[]u8 — null at EOF.
        // The returned slice excludes the delimiter, but the
        // reader's seek position advances past it (unlike
        // takeDelimiterExclusive which leaves the delimiter
        // in the buffer — that variant infinite-loops on
        // empty lines).
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

        // Per-evaluation arena.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // Source bytes need to live AT LEAST through the
        // compile call (Tiny.symbol slices borrow from
        // source). dupe into the arena.
        const src = try arena.allocator().dupe(u8, trimmed);

        var error_span: ?reader_mod.SrcSpan = null;
        // Phase 3.2: pass v.runtime_arena.allocator() as the
        // persistent allocator so defmacro Closures defined
        // on one REPL line survive into subsequent lines.
        const compiled = compile.compileSourceFullWithMacrosSpanPersistent(
            arena.allocator(),
            src,
            ns,
            interner,
            &host_macros,
            &error_span,
            v.runtime_arena.allocator(),
        ) catch |err| {
            try emitCompileError(io, "<repl>", src, err, error_span);
            continue;
        };

        // Bind the new routine onto frame 0 + reset the VM
        // state for a fresh run.
        const routine = compiled.toRoutine("repl");
        v.frames.items[0].routine = &routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = routine.slot_count;
        v.halted = false;
        if (v.stack.items.len < routine.slot_count) {
            try v.stack.appendNTimes(
                v.allocator,
                value_mod.nilValue(),
                routine.slot_count - v.stack.items.len,
            );
        }

        const result = v.run() catch |err| {
            try stderr.writeStreamingAll(io, "nexis: runtime error: ");
            try stderr.writeStreamingAll(io, @errorName(err));
            try stderr.writeStreamingAll(io, "\n");
            // Print throw payload if available.
            if (err == vm.VmError.UncaughtThrow and v.unhandled_throw != null) {
                var buf: [4096]u8 = undefined;
                var stream = std.Io.Writer.fixed(&buf);
                formatValue(v.unhandled_throw.?, interner, &stream) catch {
                    try stderr.writeStreamingAll(io, "  (payload too large to print)\n");
                    continue;
                };
                try stderr.writeStreamingAll(io, "  payload: ");
                try stderr.writeStreamingAll(io, stream.buffered());
                try stderr.writeStreamingAll(io, "\n");
            }
            // Clear handler/finally state so next iteration
            // starts clean. Otherwise an aborted try leaks
            // handlers across REPL inputs.
            v.handlers.shrinkRetainingCapacity(0);
            v.finally_stack.shrinkRetainingCapacity(0);
            v.unhandled_throw = null;
            continue;
        };

        // Print the result.
        var out_buf: [4096]u8 = undefined;
        var out_stream = std.Io.Writer.fixed(&out_buf);
        formatValue(result, interner, &out_stream) catch {
            try stdout.writeStreamingAll(io, "#<value too large to print>\n");
            continue;
        };
        try stdout.writeStreamingAll(io, out_stream.buffered());
        try stdout.writeStreamingAll(io, "\n");
    }
}

/// Read FILE.nx, parse, compile, run each top-level form. Print
/// the final result to stdout.
fn runFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
    // Read entire file. 16 MB cap is plenty for v1; Phase 3 may
    // grow when stdlib bootstrap files arrive.
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(io, "nexis: failed to read '");
        try std.Io.File.stderr().writeStreamingAll(io, path);
        try std.Io.File.stderr().writeStreamingAll(io, "': ");
        try std.Io.File.stderr().writeStreamingAll(io, @errorName(err));
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
        std.process.exit(2);
    };
    defer allocator.free(source);

    // Parser owns its own arena for the Sexp tree.
    var parse_result = reader_mod.parser.parseProgram(allocator, source) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(io, "nexis: parse error: ");
        try std.Io.File.stderr().writeStreamingAll(io, @errorName(err));
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
        std.process.exit(3);
    };
    defer parse_result.parser.deinit();

    // Reader owns its own arena for the Form tree.
    var reader = reader_mod.Reader.init(allocator, source);
    defer reader.deinit();

    const forms = reader.readProgram(parse_result.sexp) catch |err| {
        try std.Io.File.stderr().writeStreamingAll(io, "nexis: reader error: ");
        try std.Io.File.stderr().writeStreamingAll(io, @errorName(err));
        try std.Io.File.stderr().writeStreamingAll(io, "\n");
        std.process.exit(3);
    };

    if (forms.len == 0) {
        // Empty file → nothing to print. Exit cleanly.
        return;
    }

    // Initialize VM with a stub routine; we'll rebind it per
    // form. The VM owns the namespace + interner that persist
    // across forms.
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    // Phase 3.3a: install core native fns.
    try stdlib.installCore(ns);
    // Phase 3.3d: bootstrap the embedded core.nx composite
    // layer (second, last, reverse, range, take, drop,
    // when-let, if-let, dotimes, true?/false?).
    try bootstrapCoreNx(&v, ns, interner, allocator);

    // Compile arena: shared across all top-level forms in this
    // file. Form trees + Tiny IR + Compiled routines all live
    // here. Released wholesale at the end.
    var compile_arena = std.heap.ArenaAllocator.init(allocator);
    defer compile_arena.deinit();

    // Step #8b: default host macro table — let/fn/loop
    // renames + when/when-not/and/or/cond + ->/->>. Phase 3
    // will add user-defined `defmacro` and let users extend
    // this table.
    var host_macros = try expand_mod.defaultMacros(allocator);
    defer host_macros.deinit(allocator);

    var last_result: Value = value_mod.nilValue();

    for (forms) |form| {
        // Step #10.0: surface SrcSpan from compile errors.
        // The CLI converts byte offsets to file:line:col +
        // shows the source line with a caret.
        var error_span: ?reader_mod.SrcSpan = null;
        const compiled = compile.compileFormFullWithMacrosSpan(
            compile_arena.allocator(),
            form,
            ns,
            interner,
            &host_macros,
            &error_span,
        ) catch |err| {
            try emitCompileError(io, path, source, err, error_span);
            std.process.exit(4);
        };
        const routine = compiled.toRoutine("file-form");
        v.frames.items[0].routine = &routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = routine.slot_count;
        v.halted = false;
        // Grow stack if needed.
        if (v.stack.items.len < routine.slot_count) {
            try v.stack.appendNTimes(
                v.allocator,
                value_mod.nilValue(),
                routine.slot_count - v.stack.items.len,
            );
        }
        last_result = v.run() catch |err| {
            try std.Io.File.stderr().writeStreamingAll(io, "nexis: runtime error: ");
            try std.Io.File.stderr().writeStreamingAll(io, @errorName(err));
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(5);
        };
    }

    // Print the final result via a small stack buffer + write to
    // stdout. Avoids needing a writer adapter; Phase 3+ refactor
    // can introduce a proper Value formatter.
    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    formatValue(last_result, interner, &stream) catch {
        // Buffer overflow on a deep/large value — fall back to a
        // kind tag. Phase 3 replaces this with a streaming
        // formatter.
        try std.Io.File.stdout().writeStreamingAll(io, "#<value too large to print>\n");
        return;
    };
    const written = stream.buffered();
    try std.Io.File.stdout().writeStreamingAll(io, written);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}
