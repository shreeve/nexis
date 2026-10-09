//! loader.zig — evaluating source text, and `(require ...)`.
//!
//! `Loader.evalSource` is the one path from text to effect: parse,
//! read, declare the names the text defines, then compile each
//! top-level form in the current namespace and run it (or hand its
//! routine to the caller, for `disasm`). The CLI's `run`, `repl`,
//! `disasm` and `test`, the stdlib bootstrap (`stdlib.boot`) and
//! `require` all go through it, so a failure is reported the same
//! way wherever the text came from: a `Diagnostic` located in the
//! file that failed, or a runtime error whose frame chain the VM
//! recorded.
//!
//! `(require 'my.app.foo)` maps the name to `my/app/foo.nx` (dots
//! to slashes, dashes to underscores, as Clojure does) on the load
//! path, evaluates the file, whose first form must be
//! `(ns my.app.foo ...)`, and restores the caller's namespace. A
//! namespace loads once; a require of one still loading is a cycle.
//! The namespaces the stdlib installs have no file (`markLoaded`),
//! and the Clojure library namespaces `clojure_names` lists
//! (`clojure.string` and the rest) name their nexis counterparts'
//! Vars.
//!
//! The expander reaches the loader through `ExpandContext
//! .load_callback`, so it depends on neither this file nor the
//! compiler.

const std = @import("std");
const reader_mod = @import("reader.zig");
const intern_mod = @import("intern.zig");
const expand_mod = @import("expand.zig");
const compile_mod = @import("compile.zig");
const vm_mod = @import("vm.zig");

const Value = @import("value.zig").Value;

pub const LoadError = error{
    /// The file could not be found, read or evaluated, or did not
    /// declare the namespace; `Loader.diagnostic` says why.
    LoadFailed,
    /// A form of the file failed at run time with no handler in
    /// force anywhere; the VM's `traced_error` names the error and
    /// its `error_trace` locates it.
    RunFailed,
    /// A form of the file threw and a handler in the program that
    /// required it took the throw: the VM has already unwound to
    /// that handler. Passed through unchanged by everything between
    /// the loader and the VM, as every caller of `callValue` passes
    /// it (VM.md §13).
    ControlTransferred,
    OutOfMemory,
};

/// What `evalSource` fails with: `Diagnosed` when `diagnostic`
/// describes the failure, the rest as for `LoadError`.
pub const EvalError = error{ Diagnosed, RunFailed, ControlTransferred, OutOfMemory };

/// A UTF-8 byte-order mark. A source file that opens with one is read
/// without it, so its positions count from the character after it
/// (TOOLING.md §1).
pub const byte_order_mark = "\xEF\xBB\xBF";

/// A failure to read or compile, and where it happened.
pub const Diagnostic = struct {
    /// The source and the span in it the failure is at; null when
    /// the failure has no place of its own (a required file that
    /// does not exist), in which case `evalSource` puts it at the
    /// requiring form.
    source: ?*const vm_mod.SourceInfo = null,
    span: ?reader_mod.SrcSpan = null,
    /// What went wrong, as the CLI prints it after the location.
    label: []const u8,
    /// A parse or reader failure rather than a compile failure.
    reading: bool = false,
    /// The parser ran out of input: more text may complete the
    /// form, so the REPL reads another line.
    incomplete: bool = false,
};

/// A callback `evalSource` makes for each top-level form.
pub fn Each(comptime T: type) type {
    return struct {
        ctx: *anyopaque,
        call: *const fn (ctx: *anyopaque, x: T) anyerror!void,
    };
}

pub const EvalOptions = struct {
    /// Where compiled routines go. They must outlive every closure
    /// and trace made from them: a file's run passes an arena that
    /// lives as long as the run, a load or the REPL the VM's runtime
    /// arena. The Form and Tiny trees of a top-level form are scratch,
    /// freed once it has run.
    allocator: std.mem.Allocator,
    /// Every symbol must resolve to a name that exists or that the
    /// text defines, as in a file; without it an unresolved symbol
    /// is a forward reference (the embedded stdlib sources).
    declare: bool = true,
    /// Compile each form without running it and hand the routine
    /// here (`disasm`).
    on_routine: ?Each(*const vm_mod.Routine) = null,
    /// Each form's value as it runs (the REPL prints it).
    on_value: ?Each(Value) = null,
    /// The namespace the text must declare in its first form, `(ns
    /// NAME ...)` with `^meta` on the name allowed: a required file
    /// that declares another name, or none, is refused before any of
    /// it runs.
    expect_ns: ?[]const u8 = null,
};

pub const Loader = struct {
    /// Scratch: parse and read trees, name sets, diagnostic labels.
    allocator: std.mem.Allocator,
    /// Where a required file's text, path and routines live: they
    /// outlive the load. Typically `vm.runtime_arena.allocator()`.
    persistent_allocator: std.mem.Allocator,
    io: std.Io,
    /// Directories to search for `.nx` files, in order.
    load_paths: []const []const u8,
    vm: *vm_mod.VM,
    interner: *intern_mod.Interner,
    registry: *vm_mod.NamespaceRegistry,
    host_macros: *const expand_mod.HostMacroTable,
    /// Namespaces fully loaded, or installed without a file.
    loaded: std.StringHashMap(void),
    /// Namespaces being loaded, outermost first: a require of one
    /// of them is a cycle.
    loading: std.ArrayList([]const u8) = .empty,
    /// The last failure `evalSource` or a load reported.
    diagnostic: ?Diagnostic = null,
    /// The label `diagnostic` owns.
    label_buf: std.ArrayList(u8) = .empty,
    /// Set by a failed load while a form is being compiled, so the
    /// compile error the expander turns it into does not replace
    /// the load's own diagnostic.
    load_failed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        persistent_allocator: std.mem.Allocator,
        io: std.Io,
        load_paths: []const []const u8,
        vm: *vm_mod.VM,
        interner: *intern_mod.Interner,
        registry: *vm_mod.NamespaceRegistry,
        host_macros: *const expand_mod.HostMacroTable,
    ) Loader {
        return .{
            .allocator = allocator,
            .persistent_allocator = persistent_allocator,
            .io = io,
            .load_paths = load_paths,
            .vm = vm,
            .interner = interner,
            .registry = registry,
            .host_macros = host_macros,
            .loaded = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Loader) void {
        self.loaded.deinit();
        self.loading.deinit(self.allocator);
        self.label_buf.deinit(self.allocator);
        self.* = undefined;
    }

    /// Record `name` as loaded without a file: a namespace the
    /// runtime installs. The name must outlive the loader.
    pub fn markLoaded(self: *Loader, name: []const u8) !void {
        try self.loaded.put(name, {});
    }

    /// The load callback the expander calls for `(require ...)`.
    pub fn callback(self: *Loader) expand_mod.LoadCallback {
        return .{ .user_data = @ptrCast(self), .load = &loadCallback };
    }

    pub fn loadCallback(user_data: *anyopaque, ns_name: []const u8) anyerror!void {
        const self: *Loader = @ptrCast(@alignCast(user_data));
        self.loadNamespace(ns_name) catch |err| {
            if (err == LoadError.LoadFailed) self.load_failed = true;
            return err;
        };
    }

    /// Parse, read and compile every top-level form of `info.text`
    /// in the current namespace, running each before the next is
    /// compiled; the last form's value. `info` must outlive the
    /// routines (`options.allocator`).
    pub fn evalSource(self: *Loader, info: *const vm_mod.SourceInfo, options: EvalOptions) EvalError!Value {
        const text = info.text;
        if (text.len > reader_mod.max_source_len) {
            try self.diagnose(.{ .label = "", .reading = true }, "reader error: a source text is at most {d} bytes; this one is {d}", .{ reader_mod.max_source_len, text.len });
            return error.Diagnosed;
        }
        var parser = reader_mod.parser.Parser.init(self.allocator, text);
        defer parser.deinit();
        const sexp = parser.parseProgram() catch |err| {
            // Out of memory while parsing is the out-of-memory report
            // (TOOLING.md §1), not a syntax error.
            if (err == error.OutOfMemory) return error.OutOfMemory;
            const failure = parser.lastError() orelse return error.OutOfMemory;
            try self.parseFailure(info, failure.span.start, failure.span.end);
            return error.Diagnosed;
        };
        var rdr = reader_mod.Reader.init(self.allocator, text);
        defer rdr.deinit();
        const forms = rdr.readProgram(sexp) catch {
            const e = rdr.err orelse return error.OutOfMemory;
            // Kinds are spelled with underscores in Zig and dashes in
            // nexis; the detail is the user's own text.
            var kind_buf: [64]u8 = undefined;
            const kind = kind_buf[0..@tagName(e.kind).len];
            @memcpy(kind, @tagName(e.kind));
            std.mem.replaceScalar(u8, kind, '_', '-');
            const base: Diagnostic = .{ .source = info, .span = e.span, .label = "", .reading = true };
            if (e.detail) |detail|
                try self.diagnose(base, "reader error: :{s} {s}", .{ kind, detail })
            else
                try self.diagnose(base, "reader error: :{s}", .{kind});
            return error.Diagnosed;
        };

        var declared = compile_mod.DeclaredNames.init(self.allocator);
        defer declared.deinit();
        if (options.declare) for (forms) |form| try declared.declareForm(form);

        if (options.expect_ns) |name| if (!opensWithNs(forms, name)) {
            try self.diagnose(.{ .source = info, .span = .{ .pos = 0, .len = 1 }, .label = "" }, "require: {s} does not begin with (ns {s})", .{ info.path, name });
            return error.Diagnosed;
        };

        const decl: ?*compile_mod.DeclaredNames = if (options.declare) &declared else null;
        const nil = @import("value.zig").nilValue();
        var pending: std.ArrayList(*const reader_mod.Form) = .empty;
        defer pending.deinit(self.allocator);
        var last = nil;
        for (forms) |top| {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            if (options.on_routine) |each| {
                const routine = try self.compileForm(info, top, scratch.allocator(), options.allocator, decl);
                each.call(each.ctx, routine) catch |err| return self.callbackFailure(err);
                continue;
            }
            // A top-level `do` runs its forms one at a time, so an
            // `ns`, `def` or `defmacro` among them is in force for
            // the ones after it (MACROEXPAND.md §2b).
            try pending.append(self.allocator, top);
            while (pending.pop()) |form| {
                const expanded = try self.expandTopLevel(info, form, scratch.allocator(), decl);
                if (compile_mod.doForms(expanded)) |body| {
                    if (decl) |d| try d.declareForm(expanded);
                    last = nil;
                    var i = body.len;
                    while (i > 0) {
                        i -= 1;
                        try pending.append(self.allocator, body[i]);
                    }
                    continue;
                }
                last = try self.run(try self.compileForm(info, expanded, scratch.allocator(), options.allocator, decl));
            }
            if (options.on_value) |each| each.call(each.ctx, last) catch |err| return self.callbackFailure(err);
        }
        return last;
    }

    /// The options every compile of `info`'s forms takes.
    fn compileOptions(self: *Loader, info: *const vm_mod.SourceInfo, decl: ?*compile_mod.DeclaredNames, span: *?reader_mod.SrcSpan, detail: *?[]const u8) compile_mod.CompileOptions {
        self.load_failed = false;
        return .{
            .namespace = self.registry.current,
            .interner = self.interner,
            .host_macros = self.host_macros,
            .out_span = span,
            .out_detail = detail,
            .io = self.io,
            .persistent_allocator = self.persistent_allocator,
            .registry = self.registry,
            .load_callback = self.callback(),
            .declared = decl,
            .source = info,
        };
    }

    /// `compile_mod.expandTopLevel` in the current namespace.
    fn expandTopLevel(self: *Loader, info: *const vm_mod.SourceInfo, form: *const reader_mod.Form, allocator: std.mem.Allocator, decl: ?*compile_mod.DeclaredNames) EvalError!*const reader_mod.Form {
        var span: ?reader_mod.SrcSpan = null;
        var detail: ?[]const u8 = null;
        return compile_mod.expandTopLevel(allocator, form, self.compileOptions(info, decl, &span, &detail)) catch |err| self.compileFailure(info, err, span, detail);
    }

    /// `form` compiled in the current namespace on `scratch` into a
    /// top-level routine on `out`.
    fn compileForm(self: *Loader, info: *const vm_mod.SourceInfo, form: *const reader_mod.Form, scratch: std.mem.Allocator, out: std.mem.Allocator, decl: ?*compile_mod.DeclaredNames) EvalError!*vm_mod.Routine {
        var span: ?reader_mod.SrcSpan = null;
        var detail: ?[]const u8 = null;
        var opts = self.compileOptions(info, decl, &span, &detail);
        opts.routine_allocator = out;
        const compiled = compile_mod.compileFormWith(scratch, form, opts) catch |err| return self.compileFailure(info, err, span, detail);
        // A run that fails leaves its frame for the trace, and the
        // frame points at the routine.
        const routine = try out.create(vm_mod.Routine);
        routine.* = compiled.toRoutine("<top>");
        return routine;
    }

    /// Run `routine` as a nested call, never a retarget of the top
    /// frame: the VM may be running the program that required this
    /// text. A failure's detail and error are this routine's, not an
    /// earlier one's. Out of memory is a runtime error like any other:
    /// what the failed allocation was building is unreachable, and the
    /// report locates the form that asked.
    fn run(self: *Loader, routine: *const vm_mod.Routine) EvalError!Value {
        self.vm.error_detail = "";
        self.vm.traced_error = null;
        return self.vm.runRoutine(routine) catch |err| switch (err) {
            error.ControlTransferred => return error.ControlTransferred,
            else => {
                // A run that failed before its first instruction (its
                // frame could not be pushed) has no trace.
                if (self.vm.traced_error == null) {
                    self.vm.traced_error = err;
                    self.vm.error_trace.clearRetainingCapacity();
                }
                return error.RunFailed;
            },
        };
    }

    /// Diagnose the parse error the parser reports at `start`..`end`:
    /// at the end of the text, the innermost delimiter still open (more
    /// input may close it, so the REPL reads another line); at a closer
    /// that closes none of the right kind, the one still open.
    fn parseFailure(self: *Loader, info: *const vm_mod.SourceInfo, start: u32, end: u32) EvalError!void {
        const text = info.text;
        const pos: u32 = @intCast(@min(start, text.len));
        const open = try reader_mod.openDelimiter(self.allocator, text, pos);
        if (pos >= text.len) {
            if (open) |o| return self.diagnose(.{ .source = info, .span = o, .label = "", .reading = true, .incomplete = true }, "parse error: unclosed `{s}`", .{text[o.pos..][0..o.len]});
            return self.diagnose(.{ .source = info, .span = .{ .pos = pos, .len = 1 }, .label = "", .reading = true, .incomplete = true }, "parse error: unexpected end of input", .{});
        }
        if (unterminatedString(text[pos..])) return self.diagnose(.{ .source = info, .span = .{ .pos = pos, .len = 1 }, .label = "", .reading = true, .incomplete = true }, "parse error: unterminated string", .{});
        const token = text[pos..@min(text.len, pos + @max(end -| start, 1))];
        const at: Diagnostic = .{ .source = info, .span = .{ .pos = pos, .len = @intCast(token.len) }, .label = "", .reading = true };
        const closer = token.len == 1 and std.mem.findScalar(u8, ")]}", token[0]) != null;
        if (closer) if (open) |o| {
            const where = info.lineCol(o.pos);
            return self.diagnose(at, "parse error: unexpected `{s}`; the `{s}` at {d}:{d} is open", .{ token, text[o.pos..][0..o.len], where.line, where.col });
        };
        return self.diagnose(at, "parse error: unexpected `{s}`", .{token});
    }

    /// Whether `rest` opens a string literal that no unescaped `"`
    /// closes: the parser stops at the opening quote, and more input
    /// may complete it.
    fn unterminatedString(rest: []const u8) bool {
        if (rest.len == 0 or rest[0] != '"') return false;
        var i: usize = 1;
        while (i < rest.len) : (i += 1) switch (rest[i]) {
            '\\' => i += 1,
            '"' => return false,
            else => {},
        };
        return true;
    }

    /// A failure of an `on_value` or `on_routine` callback (the REPL
    /// or `-e` printing a value, `disasm` printing a routine): out of
    /// memory as itself, a runtime error realizing the value to print
    /// as one, anything else, such as a closed stdout, as a diagnostic
    /// naming it, never a runtime error the VM did not have.
    fn callbackFailure(self: *Loader, err: anyerror) EvalError {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        // Realizing a printed result failed (docs/LAZY.md §8).
        if (err == error.RunFailed) return error.RunFailed;
        self.diagnose(.{ .label = "" }, "cannot write the result: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        return error.Diagnosed;
    }

    fn compileFailure(self: *Loader, info: *const vm_mod.SourceInfo, err: anyerror, span: ?reader_mod.SrcSpan, detail: ?[]const u8) EvalError {
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ControlTransferred => return error.ControlTransferred,
            error.RequiredFileFailed => return error.RunFailed,
            else => {},
        }
        if (self.load_failed) {
            self.load_failed = false;
            // A load failure with no place of its own is the
            // requiring form's.
            if (self.diagnostic) |*d| if (d.source == null) {
                d.source = info;
                d.span = span;
            };
            return error.Diagnosed;
        }
        const base: Diagnostic = .{ .source = info, .span = span, .label = "" };
        // A compile error with a sentence reads as that sentence; the
        // Zig name is for the ones with nothing to add (TOOLING.md §1).
        if (detail) |d|
            self.diagnose(base, "compile error: {s}", .{d}) catch return error.OutOfMemory
        else
            self.diagnose(base, "compile error: {s}", .{@errorName(err)}) catch return error.OutOfMemory;
        return error.Diagnosed;
    }

    /// Set `diagnostic` to `base` with the formatted label.
    fn diagnose(self: *Loader, base: Diagnostic, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        self.label_buf.clearRetainingCapacity();
        self.label_buf.print(self.allocator, fmt, args) catch return error.OutOfMemory;
        var d = base;
        d.label = self.label_buf.items;
        self.diagnostic = d;
    }

    /// Load `ns_name` from the load path into the registry, once.
    /// The caller's current namespace is restored afterwards.
    pub fn loadNamespace(self: *Loader, ns_name: []const u8) LoadError!void {
        if (self.loaded.contains(ns_name)) return;
        for (self.loading.items) |name| if (std.mem.eql(u8, name, ns_name)) {
            try self.diagnose(.{ .label = "" }, "require: cyclic require of {s}", .{ns_name});
            return LoadError.LoadFailed;
        };
        for (clojure_names) |pair| if (std.mem.eql(u8, pair[0], ns_name)) return self.loadCounterpart(pair[0], pair[1]);

        const rel_path = try nsNameToRelPath(self.allocator, ns_name);
        defer self.allocator.free(rel_path);
        const path = (try searchLoadPaths(self.allocator, self.io, self.load_paths, rel_path)) orelse {
            try self.diagnose(.{ .label = "" }, "require: no file {s} on the load path", .{rel_path});
            return LoadError.LoadFailed;
        };
        defer self.allocator.free(path);

        // The text and the path outlive the load: every routine
        // compiled from the file points at them for its error
        // reports (TOOLING.md §1).
        const file = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.persistent_allocator, .unlimited) catch |err| {
            try self.diagnose(.{ .label = "" }, "require: cannot read {s}: {s}", .{ path, @errorName(err) });
            return LoadError.LoadFailed;
        };
        const source = if (std.mem.startsWith(u8, file, byte_order_mark)) file[byte_order_mark.len..] else file;
        const info = try self.persistent_allocator.create(vm_mod.SourceInfo);
        info.* = .{ .path = try self.persistent_allocator.dupe(u8, path), .text = source };

        const stable_name = try self.persistent_allocator.dupe(u8, ns_name);
        try self.loading.append(self.allocator, stable_name);
        defer _ = self.loading.pop();
        const saved_current = self.registry.current;
        defer self.registry.current = saved_current;

        _ = self.evalSource(info, .{ .allocator = self.persistent_allocator, .expect_ns = ns_name }) catch |err| return switch (err) {
            error.Diagnosed => LoadError.LoadFailed,
            error.RunFailed => LoadError.RunFailed,
            error.ControlTransferred => LoadError.ControlTransferred,
            error.OutOfMemory => LoadError.OutOfMemory,
        };
        try self.loaded.put(stable_name, {});
    }

    /// `name`, a Clojure library namespace, as a namespace of its own
    /// whose Vars are `target`'s, so `(clojure.string/join ...)` and
    /// an alias of `clojure.string` reach `nexis.string/join`.
    fn loadCounterpart(self: *Loader, name: []const u8, target_name: []const u8) LoadError!void {
        const target = self.registry.lookupNs(target_name) orelse {
            try self.diagnose(.{ .label = "" }, "require: {s} has no counterpart ({s} is not installed)", .{ name, target_name });
            return LoadError.LoadFailed;
        };
        const ns = try self.registry.getOrCreate(name, self.registry.core);
        // The target's own key storage, so each entry counts as the
        // counterpart's own Var (expand.isOwnVar): `:refer :all` from
        // it refers them all.
        var it = target.vars.iterator();
        while (it.next()) |entry| try ns.vars.put(ns.map_allocator, entry.key_ptr.*, entry.value_ptr.*);
        try self.loaded.put(ns.name, {});
    }
};

/// Clojure's library namespaces and the nexis namespaces that stand
/// for them.
const clojure_names = [_][2][]const u8{
    .{ "clojure.string", "nexis.string" },
    .{ "clojure.set", "nexis.set" },
    .{ "clojure.test", "nexis.test" },
    .{ "clojure.pprint", "nexis.pprint" },
    .{ "clojure.walk", "nexis.walk" },
    .{ "clojure.edn", "nexis.edn" },
    .{ "clojure.math", "nexis.math" },
    .{ "clojure.java.shell", "nexis.shell" },
    .{ "clojure.data.json", "nexis.json" },
};

/// `my.app-core.foo` → `my/app_core/foo.nx`. Caller owns the slice.
fn nsNameToRelPath(allocator: std.mem.Allocator, ns_name: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, ns_name.len + 3);
    for (ns_name, buf[0..ns_name.len]) |c, *out| out.* = switch (c) {
        '.' => '/',
        '-' => '_',
        else => c,
    };
    @memcpy(buf[ns_name.len..], ".nx");
    return buf;
}

/// The first of `load_paths` holding `rel_path`, joined; the caller
/// owns it.
fn searchLoadPaths(allocator: std.mem.Allocator, io: std.Io, load_paths: []const []const u8, rel_path: []const u8) !?[]u8 {
    for (load_paths) |dir| {
        const candidate = try std.Io.Dir.path.join(allocator, &.{ dir, rel_path });
        std.Io.Dir.cwd().access(io, candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Whether `forms` opens with `(ns NAME ...)`, `^meta` on NAME allowed.
fn opensWithNs(forms: []const *reader_mod.Form, name: []const u8) bool {
    if (forms.len == 0 or forms[0].datum != .list) return false;
    const items = forms[0].datum.list;
    if (items.len < 2 or items[0].datum != .symbol) return false;
    const head = items[0].datum.symbol;
    if (head.ns != null or !std.mem.eql(u8, head.name, "ns")) return false;
    var n = items[1];
    while (n.datum == .with_meta) n = n.datum.with_meta.target;
    return n.datum == .symbol and n.datum.symbol.ns == null and std.mem.eql(u8, n.datum.symbol.name, name);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "loader: namespace names map to relative paths" {
    const cases = .{
        .{ "foo", "foo.nx" },
        .{ "foo.bar", "foo/bar.nx" },
        .{ "a.b.c.d", "a/b/c/d.nx" },
        .{ "my.app-core.foo-bar", "my/app_core/foo_bar.nx" },
    };
    inline for (cases) |c| {
        const out = try nsNameToRelPath(testing.allocator, c[0]);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
    }
}

test "loader: memory that runs out while reading or compiling is OutOfMemory, never a crash" {
    var v = try vm_mod.VM.init(testing.allocator, &vm_mod.VM.idle_routine);
    defer v.deinit();
    const interner = v.ensureInterner();
    const registry = try v.ensureRegistry();
    // What a `def` sets its Var's metadata through, when it runs.
    _ = try registry.core.intern("reset-meta!");
    const no_macros: expand_mod.HostMacroTable = .{};
    const info = vm_mod.SourceInfo{ .path = "<test>", .text = "(do 1 [1 2 3 4 5 6 7 8 9] {:a [2 3] :b #{1 2}} '(a b))" };
    var failed_somewhere = false;
    for (0..400) |n| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = n });
        var loader = Loader.init(failing.allocator(), v.runtime_arena.allocator(), testing.io, &.{}, &v, interner, registry, &no_macros);
        defer loader.deinit();
        _ = loader.evalSource(&info, .{ .allocator = v.runtime_arena.allocator() }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failed_somewhere = true;
            continue;
        };
    }
    try testing.expect(failed_somewhere);
}
