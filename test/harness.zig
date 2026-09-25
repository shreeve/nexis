//! test/harness.zig — the pipeline harness the integration and
//! property suites share (module `harness`).
//!
//! A `Program` is a VM booted the way `bin/nexis` boots one: every
//! namespace installed, every embedded source bootstrapped into its
//! namespace, and `eval`/`read-string`/`macroexpand-1` wired. Each
//! program owns a leak-checked allocator without stack traces, so a
//! fresh VM per assertion costs milliseconds, and a leak still fails
//! the test: `std.heap.DebugAllocator` logs it as an error.

const std = @import("std");
const nx = @import("nexis");
const value_mod = nx.value;
const vm = nx.vm;
const compile = nx.compile;
const intern_mod = nx.intern;
const reader_mod = nx.reader;
const expand_mod = nx.expand;
const stdlib = nx.stdlib;
const format_mod = nx.format;

const testing = std.testing;
const Value = value_mod.Value;

pub const Program = struct {
    gpa: std.heap.DebugAllocator(.{ .stack_trace_frames = 0 }),
    /// Where each top-level form of a program compiles; routines
    /// live until the program ends.
    arena: std.heap.ArenaAllocator,
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    hooks: compile.RuntimeHooks,
    registry: *vm.NamespaceRegistry,
    interner: *intern_mod.Interner,

    pub const Options = struct {
        /// Run the collector every few kilobytes (`vm.GcPolicy.stress`)
        /// once bootstrap is done.
        gc_stress: bool = false,
    };

    /// Boot in place: the program keeps pointers into itself.
    pub fn init(self: *Program) !void {
        return self.initWith(.{});
    }

    pub fn initWith(self: *Program, options: Options) !void {
        self.gpa = .init;
        errdefer _ = self.gpa.deinit();
        const gpa = self.gpa.allocator();
        self.arena = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena.deinit();
        self.v = try vm.VM.init(gpa, &vm.VM.idle_routine);
        errdefer self.v.deinit();
        // `v.io` stays null: a program under test reaches no file
        // system through the CLI's std.Io.
        self.interner = self.v.ensureInterner();
        self.registry = try self.v.ensureRegistry();
        const core = self.registry.core;
        try stdlib.installCore(core);
        try stdlib.installDb(try self.registry.getOrCreate("db", core));
        try stdlib.installString(try self.registry.getOrCreate("nexis.string", core));
        try stdlib.installInternal(try self.registry.getOrCreate("nexis.internal", core));
        const nextomic_ns = try self.registry.getOrCreate("nextomic", core);
        try stdlib.installNextomic(nextomic_ns);
        const math_ns = try self.registry.getOrCreate("nexis.math", core);
        try stdlib.installMath(math_ns);
        self.host_macros = try expand_mod.defaultMacros(gpa);
        errdefer self.host_macros.deinit(gpa);
        try self.bootstrap(core, stdlib.CORE_NX_SOURCE);
        try self.bootstrap(nextomic_ns, stdlib.NEXTOMIC_NX_SOURCE);
        try self.bootstrap(try self.registry.getOrCreate("nexis.test", core), stdlib.TEST_NX_SOURCE);
        try self.bootstrap(try self.registry.getOrCreate("nexis.pprint", core), stdlib.PPRINT_NX_SOURCE);
        try self.bootstrap(math_ns, stdlib.MATH_NX_SOURCE);
        self.hooks = .{ .host_macros = &self.host_macros, .registry = self.registry, .interner = self.interner };
        self.hooks.install(&self.v);
        if (options.gc_stress) {
            self.v.gc_threshold = vm.GcPolicy.stress.threshold;
            self.v.gc_growth_percent = vm.GcPolicy.stress.growth_percent;
            self.v.gc_next_at = vm.GcPolicy.stress.threshold;
        }
    }

    /// Release the program; a leak logs an error, which fails the test.
    pub fn deinit(self: *Program) void {
        self.host_macros.deinit(self.gpa.allocator());
        self.v.deinit();
        self.arena.deinit();
        _ = self.gpa.deinit();
    }

    pub fn allocator(self: *Program) std.mem.Allocator {
        return self.gpa.allocator();
    }

    /// Run every top-level form of `src` in order, as `nexis run`
    /// does; the last form's value is the result.
    pub fn run(self: *Program, src: []const u8) !Value {
        return self.runForms(src, null, null);
    }

    /// `run` with every name the program defines declared up front,
    /// as `nexis run` compiles a file: any other unresolved symbol is
    /// a compile error, its span in `out_span`.
    pub fn runChecked(self: *Program, src: []const u8, out_span: ?*?reader_mod.SrcSpan) !Value {
        var declared = compile.DeclaredNames.init(self.allocator());
        defer declared.deinit();
        return self.runForms(src, &declared, out_span);
    }

    /// `v` printed in display mode, owned by `std.testing.allocator`.
    pub fn format(self: *Program, v: Value) ![]u8 {
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        errdefer w.deinit();
        try format_mod.format(v, .display, &w.writer, self.interner);
        return w.toOwnedSlice();
    }

    fn runForms(self: *Program, src: []const u8, declared: ?*compile.DeclaredNames, out_span: ?*?reader_mod.SrcSpan) !Value {
        const gpa = self.allocator();
        var parsed = try reader_mod.parser.parseProgram(gpa, src);
        defer parsed.parser.deinit();
        var rdr = reader_mod.Reader.init(gpa, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parsed.sexp);
        if (declared) |names| for (forms) |form| try names.declareForm(form);

        var last = value_mod.nilValue();
        for (forms) |form| {
            // Re-read per form so `(ns NAME)` takes effect.
            const compiled = try compile.compileFormWith(self.arena.allocator(), form, .{
                .namespace = self.registry.current,
                .interner = self.interner,
                .host_macros = &self.host_macros,
                .out_span = out_span,
                .persistent_allocator = self.v.runtime_arena.allocator(),
                .registry = self.registry,
                .declared = declared,
            });
            const routine = compiled.toRoutine("test-form");
            try self.v.retargetTop(&routine);
            const stack_len = self.v.stack.items.len;
            const frame_depth = self.v.frames.items.len;
            last = try self.v.run();
            // Every frame a run pushes is popped by return or unwind,
            // each pop restoring the stack length recorded at entry.
            try testing.expectEqual(stack_len, self.v.stack.items.len);
            try testing.expectEqual(frame_depth, self.v.frames.items.len);
        }
        return last;
    }

    /// Compile and run an embedded source into `ns` one form at a
    /// time, the routines kept in the VM's runtime arena.
    fn bootstrap(self: *Program, ns: *vm.Namespace, src: []const u8) !void {
        const saved = self.registry.current;
        self.registry.current = ns;
        defer self.registry.current = saved;
        const gpa = self.allocator();
        var parsed = try reader_mod.parser.parseProgram(gpa, src);
        defer parsed.parser.deinit();
        var rdr = reader_mod.Reader.init(gpa, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parsed.sexp);
        const persistent = self.v.runtime_arena.allocator();
        for (forms) |form| {
            const compiled = try compile.compileFormWith(persistent, form, .{
                .namespace = ns,
                .interner = self.interner,
                .host_macros = &self.host_macros,
                .persistent_allocator = persistent,
                .registry = self.registry,
            });
            const routine = compiled.toRoutine("bootstrap");
            try self.v.retargetTop(&routine);
            _ = try self.v.run();
        }
    }
};

/// Print what `src` returns and compare it with `expected`.
pub fn expectOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try expectResult(&program, src, try program.run(src), expected);
}

/// `expectOutput` compiled the way `nexis run` compiles a file
/// (`Program.runChecked`).
pub fn expectCheckedOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var span: ?reader_mod.SrcSpan = null;
    try expectResult(&program, src, try program.runChecked(src, &span), expected);
}

/// `src` fails with `expected` instead of producing a value.
pub fn expectError(src: []const u8, expected: anyerror) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(expected, program.run(src));
}

/// `result`, printed, equals `expected`; on a mismatch the source is
/// shown with both.
pub fn expectResult(program: *Program, src: []const u8, result: Value, expected: []const u8) !void {
    const actual = try program.format(result);
    defer testing.allocator.free(actual);
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, actual });
        return err;
    };
}

/// A store path under the test's own temporary directory
/// (`.zig-cache/tmp/<unique>/<name>.edb`), so concurrent runs never
/// share a file; `deinit` removes the directory and the store in it.
pub const Store = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    pub fn init(name: []const u8) !Store {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}.edb", .{ tmp.sub_path, name });
        return .{ .tmp = tmp, .path = path };
    }

    pub fn deinit(self: *Store) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }

    /// `template` with every `@STORE@` replaced by this store's path,
    /// owned by `std.testing.allocator`.
    pub fn source(self: *const Store, template: []const u8) ![]u8 {
        return std.mem.replaceOwned(u8, testing.allocator, template, "@STORE@", self.path);
    }
};
