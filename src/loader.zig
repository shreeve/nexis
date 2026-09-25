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
//! and `clojure.string`, `clojure.set`, `clojure.test` and
//! `clojure.pprint` name their nexis counterparts' Vars.
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
    /// Where Form trees and compiled routines go. Routines must
    /// outlive every closure and trace made from them: a file's run
    /// passes an arena that lives as long as the run, a load or the
    /// REPL the VM's runtime arena.
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
        var parser = reader_mod.parser.Parser.init(self.allocator, text);
        defer parser.deinit();
        const sexp = parser.parseProgram() catch {
            const pos: u32 = @intCast(@min(parser.current.pos, text.len));
            if (pos >= text.len) {
                try self.diagnose(.{ .source = info, .span = .{ .pos = pos, .len = 1 }, .label = "", .reading = true, .incomplete = true }, "parse error: unexpected end of input", .{});
            } else {
                const len: u32 = @max(parser.current.len, 1);
                try self.diagnose(.{ .source = info, .span = .{ .pos = pos, .len = len }, .label = "", .reading = true }, "parse error: unexpected `{s}`", .{text[pos..@min(text.len, pos + len)]});
            }
            return error.Diagnosed;
        };
        var rdr = reader_mod.Reader.init(self.allocator, text);
        defer rdr.deinit();
        const forms = rdr.readProgram(sexp) catch |err| {
            const e = rdr.err orelse {
                try self.diagnose(.{ .label = "", .reading = true }, "reader error: {s}", .{@errorName(err)});
                return error.Diagnosed;
            };
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

        var last: Value = @import("value.zig").nilValue();
        for (forms) |form| {
            var span: ?reader_mod.SrcSpan = null;
            self.load_failed = false;
            const compiled = compile_mod.compileFormWith(options.allocator, form, .{
                .namespace = self.registry.current,
                .interner = self.interner,
                .host_macros = self.host_macros,
                .out_span = &span,
                .persistent_allocator = self.persistent_allocator,
                .registry = self.registry,
                .load_callback = self.callback(),
                .declared = if (options.declare) &declared else null,
                .source = info,
            }) catch |err| return self.compileFailure(info, err, span);
            // A run that fails leaves its frame for the trace, and
            // the frame points at the routine.
            const routine = try options.allocator.create(vm_mod.Routine);
            routine.* = compiled.toRoutine("<top>");
            if (options.on_routine) |each| {
                each.call(each.ctx, routine) catch |err| return mapCallbackError(err);
                continue;
            }
            // A nested call, never a retarget of the top frame: the VM
            // may be running the program that required this text.
            last = self.vm.runRoutine(routine) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ControlTransferred => error.ControlTransferred,
                else => error.RunFailed,
            };
            if (options.on_value) |each| each.call(each.ctx, last) catch |err| return mapCallbackError(err);
        }
        return last;
    }

    fn mapCallbackError(err: anyerror) EvalError {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.RunFailed;
    }

    fn compileFailure(self: *Loader, info: *const vm_mod.SourceInfo, err: anyerror, span: ?reader_mod.SrcSpan) EvalError {
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
        self.diagnose(.{ .source = info, .span = span, .label = "" }, "{s}", .{@errorName(err)}) catch return error.OutOfMemory;
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
        const source = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.persistent_allocator, .unlimited) catch |err| {
            try self.diagnose(.{ .label = "" }, "require: cannot read {s}: {s}", .{ path, @errorName(err) });
            return LoadError.LoadFailed;
        };
        const info = try self.persistent_allocator.create(vm_mod.SourceInfo);
        info.* = .{ .path = try self.persistent_allocator.dupe(u8, path), .text = source };

        const stable_name = try self.persistent_allocator.dupe(u8, ns_name);
        try self.loading.append(self.allocator, stable_name);
        defer _ = self.loading.pop();
        const saved_current = self.registry.current;
        defer self.registry.current = saved_current;

        if (!startsWithNs(source, ns_name)) {
            try self.diagnose(.{ .source = info, .span = .{ .pos = 0, .len = 1 }, .label = "" }, "require: {s} does not begin with (ns {s})", .{ path, ns_name });
            return LoadError.LoadFailed;
        }
        _ = self.evalSource(info, .{ .allocator = self.persistent_allocator }) catch |err| return switch (err) {
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
        const candidate = try std.fs.path.join(allocator, &.{ dir, rel_path });
        std.Io.Dir.cwd().access(io, candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Whether `source`'s first form is `(ns NAME ...)` with NAME the
/// requested namespace: a file that declares another name, or none,
/// is refused before any of it runs. Only the head and the name are
/// looked at; the rest of the form is the expander's.
fn startsWithNs(source: []const u8, ns_name: []const u8) bool {
    var i: usize = 0;
    while (i < source.len) {
        switch (source[i]) {
            ' ', '\t', '\r', '\n', ',' => i += 1,
            ';' => while (i < source.len and source[i] != '\n') {
                i += 1;
            },
            else => break,
        }
    }
    const rest = source[i..];
    if (!std.mem.startsWith(u8, rest, "(ns")) return false;
    const after = std.mem.trimStart(u8, rest[3..], " \t\r\n,");
    if (after.len == rest.len - 3) return false;
    if (!std.mem.startsWith(u8, after, ns_name)) return false;
    if (after.len == ns_name.len) return false;
    return switch (after[ns_name.len]) {
        ' ', '\t', '\r', '\n', ',', ')', '"', '(', '^', '{' => true,
        else => false,
    };
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

test "loader: a file must open with (ns NAME ...)" {
    try testing.expect(startsWithNs("(ns app.a)", "app.a"));
    try testing.expect(startsWithNs("; header\n\n(ns app.a \"doc\" (:require [b]))", "app.a"));
    try testing.expect(startsWithNs("(ns\n  app.a\n  (:require [app.b :as b]))", "app.a"));
    try testing.expect(!startsWithNs("(ns app.ab)", "app.a"));
    try testing.expect(!startsWithNs("(nsx app.a)", "app.a"));
    try testing.expect(!startsWithNs("(def x 1)", "app.a"));
    try testing.expect(!startsWithNs("", "app.a"));
}
