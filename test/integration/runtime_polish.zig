//! test/integration/runtime_polish.zig — end-to-end pins for the
//! Clojure-fidelity rules of the sequence library, records as
//! maps, and the one policy for an uncaught keyword throw raised
//! by a native.

const std = @import("std");
const value_mod = @import("value");
const vm = @import("vm");
const compile = @import("compile");
const intern_mod = @import("intern");
const reader_mod = @import("reader");
const expand_mod = @import("expand");
const stdlib = @import("stdlib");
const format_mod = @import("format");

const testing = std.testing;

/// A VM with core, `db`, `nexis.string` and `nexis.internal`
/// installed and core.nx bootstrapped, ready to run programs of
/// top-level forms.
const Program = struct {
    arena: std.heap.ArenaAllocator,
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    registry: *vm.NamespaceRegistry,
    interner: *intern_mod.Interner,

    const stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };

    fn init(self: *Program) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena.deinit();
        self.v = try vm.VM.init(testing.allocator, &stub);
        errdefer self.v.deinit();
        self.interner = self.v.ensureInterner();
        self.registry = try self.v.ensureRegistry();
        try stdlib.installCore(self.registry.core);
        const db_ns = try self.registry.getOrCreate("db", self.registry.core);
        try stdlib.installDb(db_ns);
        const string_ns = try self.registry.getOrCreate("nexis.string", self.registry.core);
        try stdlib.installString(string_ns);
        const internal_ns = try self.registry.getOrCreate("nexis.internal", self.registry.core);
        try stdlib.installInternal(internal_ns);
        self.host_macros = try expand_mod.defaultMacros(testing.allocator);
        errdefer self.host_macros.deinit(testing.allocator);
        const saved_current = self.registry.current;
        self.registry.current = self.registry.core;
        _ = try self.runForms(stdlib.CORE_NX_SOURCE, self.v.runtime_arena.allocator());
        self.registry.current = saved_current;
    }

    fn deinit(self: *Program) void {
        self.host_macros.deinit(testing.allocator);
        self.v.deinit();
        self.arena.deinit();
    }

    /// Run every top-level form of `src` in order; the last form's
    /// value is the result.
    fn run(self: *Program, src: []const u8) !value_mod.Value {
        return self.runForms(src, self.arena.allocator());
    }

    fn runForms(self: *Program, src: []const u8, compile_allocator: std.mem.Allocator) !value_mod.Value {
        var parse_result = try reader_mod.parser.parseProgram(testing.allocator, src);
        defer parse_result.parser.deinit();
        var rdr = reader_mod.Reader.init(testing.allocator, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parse_result.sexp);

        var last_result: value_mod.Value = value_mod.nilValue();
        for (forms) |form| {
            const compiled = try compile.compileFormWith(compile_allocator, form, .{
                .namespace = self.registry.current,
                .interner = self.interner,
                .host_macros = &self.host_macros,
                .persistent_allocator = self.v.runtime_arena.allocator(),
                .registry = self.registry,
            });
            const routine = compiled.toRoutine("polish-form");
            try self.v.retargetTop(&routine);
            const stack_len_before = self.v.stack.items.len;
            const frame_depth_before = self.v.frames.items.len;
            last_result = try self.v.run();
            try testing.expectEqual(stack_len_before, self.v.stack.items.len);
            try testing.expectEqual(frame_depth_before, self.v.frames.items.len);
        }
        return last_result;
    }

    fn format(self: *Program, v: value_mod.Value) ![]u8 {
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        defer w.deinit();
        try format_mod.format(v, .display, &w.writer, self.interner);
        return try testing.allocator.dupe(u8, w.written());
    }
};

fn expectOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const result = try program.run(src);
    const actual = try program.format(result);
    defer testing.allocator.free(actual);
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, actual });
        return err;
    };
}

fn expectError(src: []const u8, expected: anyerror) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(expected, program.run(src));
}

/// A store path under the test's own temporary directory, so
/// concurrent runs never share a file.
const StorePath = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(name: []const u8) !StorePath {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}.edb", .{ tmp.sub_path, name });
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *StorePath) void {
        testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

// ---- records are maps ----

test "count, empty?, not-empty, empty, conj and into treat a record as a map" {
    try expectOutput(
        \\(defrecord P [x y])
        \\(def p (->P 1 2))
        \\[(count p)
        \\ (empty? p)
        \\ (= p (not-empty p))
        \\ (empty p)
        \\ (:z (conj p [:z 3]))
        \\ (P? (conj p [:z 3]))
        \\ (:z (into p {:z 4}))
        \\ (P? (into p {:z 4}))
        \\ (count (into p {:z 4}))]
    , "[2 false true {} 3 true 4 true 3]");
}

// ---- flatten ----

test "flatten keeps nils and returns () for a non-sequential argument" {
    try expectOutput(
        \\[(flatten [1 nil [2 [nil 3]]])
        \\ (flatten 5)
        \\ (flatten "ab")
        \\ (flatten nil)
        \\ (flatten {:a 1})
        \\ (flatten '(1 (2) [3 [4]]))]
    , "[(1 nil 2 nil 3) () () () () (1 2 3 4)]");
}

// ---- negative counts clamp to zero ----

test "a negative n counts as zero in every counting seq fn" {
    try expectOutput(
        \\[(nthrest [1 2] -1)
        \\ (split-at -1 [1 2])
        \\ (take-last -1 [1 2])
        \\ (drop-last -1 [1 2])
        \\ (repeat -1 :x)
        \\ (repeatedly -1 (fn* [] :x))
        \\ (iterate inc 0 -1)]
    , "[(1 2) [() (1 2)] () (1 2) () () ()]");
}

// ---- select-keys ----

test "select-keys reads a vector by index like find does" {
    try expectOutput(
        \\(let [m (select-keys [10 20 30] [0 2 5])]
        \\  [(count m) (get m 0) (get m 2) (contains? m 5) (select-keys nil [1])])
    , "[2 10 30 false {}]");
}

// ---- uncaught keyword throws from natives ----

test "outside try a storage failure is an uncaught throw of its keyword" {
    var store = try StorePath.init("raw-error");
    defer store.deinit();
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const src = try std.fmt.allocPrint(testing.allocator,
        \\(do
        \\  (def conn (db/open "{s}"))
        \\  (def long-key (loop [s "k" n 0] (if (< n 13) (recur (str s s) (inc n)) s)))
        \\  (db/put-key! (db/ref conn :t long-key) 1))
    , .{store.path});
    defer testing.allocator.free(src);
    try testing.expectError(vm.VmError.UncaughtThrow, program.run(src));
    const payload = program.v.unhandled_throw orelse return error.TestFailed;
    const printed = try program.format(payload);
    defer testing.allocator.free(printed);
    try testing.expectEqualStrings(":db/key-too-large", printed);
}

// ---- the division symbol survives a Value → Form round trip ----

test "/ resolves after passing through a user macro, and names as itself" {
    try expectOutput(
        \\(defmacro sq [x] `(* ~x ~x))
        \\[(sq (/ 6 3)) (some-> 6 (/ 3)) (cond-> 6 true (/ 3)) (name '/) (name :/) (namespace '/)]
    , "[4 2 2 / / nil]");
}
