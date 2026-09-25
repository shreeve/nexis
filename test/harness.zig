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
    /// What boots the library; no load path, so a `require` reaches
    /// only the namespaces the library installs.
    loader: nx.loader.Loader,

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
        self.host_macros = try expand_mod.defaultMacros(gpa);
        errdefer self.host_macros.deinit(gpa);
        self.loader = nx.loader.Loader.init(gpa, self.v.runtime_arena.allocator(), testing.io, &.{}, &self.v, self.interner, self.registry, &self.host_macros);
        errdefer self.loader.deinit();
        try stdlib.boot(&self.loader);
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
        self.loader.deinit();
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

/// Random values of every serializable kind, nested to a given depth:
/// the generator the codec and db property suites share. `shape`
/// bounds the sizes, so each suite keeps its own population.
pub const Gen = struct {
    heap: *nx.heap.Heap,
    interner: *intern_mod.Interner,
    /// Scratch for building lists.
    allocator: std.mem.Allocator,
    r: std.Random,
    shape: Shape = .{},

    pub const Shape = struct {
        /// Longest keyword and symbol name.
        name_max: usize = 10,
        /// Exclusive bounds on each collection's count.
        list_max: usize = 6,
        vector_max: usize = 10,
        map_max: usize = 8,
        set_max: usize = 8,
        /// Chance in ten that a node three or more levels above the
        /// leaves is a scalar; two levels up it is 5, one level 7.
        deep_leaf: u8 = 3,
    };

    pub const Error = std.mem.Allocator.Error || error{ InternTableFull, EmptyName, InvalidListTail, Overflow };

    /// nil, a boolean, a fixnum, a char, a float, a keyword, a
    /// symbol, a string or a bignum outside the fixnum range.
    pub fn scalar(self: *Gen) Error!Value {
        const r = self.r;
        return switch (r.uintLessThan(u8, 10)) {
            0 => value_mod.nilValue(),
            1 => value_mod.fromBool(true),
            2 => value_mod.fromBool(false),
            3 => value_mod.fromFixnum(r.intRangeAtMost(i64, value_mod.fixnum_min, value_mod.fixnum_max)).?,
            4 => blk: {
                var c: u21 = r.intRangeAtMost(u21, 0, 0x10FFFF);
                if (c >= 0xD800 and c <= 0xDFFF) c = 'a';
                break :blk value_mod.fromChar(c).?;
            },
            5 => value_mod.fromFloat(r.float(f64)),
            6 => blk: {
                var buf: [32]u8 = undefined;
                const n = r.intRangeAtMost(usize, 1, self.shape.name_max);
                for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 'a', 'z');
                break :blk try self.interner.internKeywordValue(buf[0..n]);
            },
            7 => blk: {
                var buf: [32]u8 = undefined;
                const n = r.intRangeAtMost(usize, 1, self.shape.name_max);
                for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 'A', 'Z');
                break :blk try self.interner.internSymbolValue(buf[0..n]);
            },
            8 => blk: {
                var buf: [32]u8 = undefined;
                const n = r.uintLessThan(usize, 20);
                for (buf[0..n]) |*b| b.* = r.intRangeAtMost(u8, 32, 126);
                break :blk try nx.string.fromBytes(self.heap, buf[0..n]);
            },
            9 => blk: {
                const high: u64 = r.int(u64) | (@as(u64, 1) << 63);
                const neg = r.boolean();
                break :blk try nx.bignum.fromLimbs(self.heap, neg, &[_]u64{ r.int(u64), high });
            },
            else => unreachable,
        };
    }

    /// A scalar, or a list, vector, map (scalar keys) or set (scalar
    /// elements) whose values nest up to `depth` more levels.
    pub fn container(self: *Gen, depth: u8) Error!Value {
        if (depth == 0) return self.scalar();
        const leaf: u8 = if (depth >= 3) self.shape.deep_leaf else if (depth == 2) 5 else 7;
        if (self.r.uintLessThan(u8, 10) < leaf) return self.scalar();
        const hash = &nx.dispatch.hashValue;
        const equal = &nx.dispatch.equal;
        switch (self.r.uintLessThan(u8, 4)) {
            0 => {
                const elems = try self.allocator.alloc(Value, self.r.uintLessThan(usize, self.shape.list_max));
                defer self.allocator.free(elems);
                for (elems) |*slot| slot.* = try self.container(depth - 1);
                return nx.list.fromSlice(self.heap, elems);
            },
            1 => {
                var v = try nx.vector.empty(self.heap);
                for (0..self.r.uintLessThan(usize, self.shape.vector_max)) |_|
                    v = try nx.vector.conj(self.heap, v, try self.container(depth - 1));
                return v;
            },
            2 => {
                var m = try nx.champ.mapEmpty(self.heap);
                for (0..self.r.uintLessThan(usize, self.shape.map_max)) |_| {
                    const key = try self.scalar();
                    m = try nx.champ.mapAssoc(self.heap, m, key, try self.container(depth - 1), hash, equal);
                }
                return m;
            },
            else => {
                var s = try nx.champ.setEmpty(self.heap);
                for (0..self.r.uintLessThan(usize, self.shape.set_max)) |_|
                    s = try nx.champ.setConj(self.heap, s, try self.scalar(), hash, equal);
                return s;
            },
        }
    }
};
