//! test/integration/numbers.zig — the numeric tower end to end
//! (SEMANTICS.md §2.2, BIGNUM.md §9): fixnum promotion and bignum
//! demotion through every operator and predicate, contagion with
//! f64, and the errors a program can catch.

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
        const math_ns = try self.registry.getOrCreate("nexis.math", self.registry.core);
        try stdlib.installMath(math_ns);
        self.host_macros = try expand_mod.defaultMacros(testing.allocator);
        errdefer self.host_macros.deinit(testing.allocator);
        const saved_current = self.registry.current;
        self.registry.current = self.registry.core;
        _ = try self.runForms(stdlib.CORE_NX_SOURCE, self.v.runtime_arena.allocator(), false);
        self.registry.current = math_ns;
        _ = try self.runForms(stdlib.MATH_NX_SOURCE, self.v.runtime_arena.allocator(), false);
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
        return self.runForms(src, self.arena.allocator(), false);
    }

    /// `run` the way the CLI runs a file: every name the program
    /// defines is declared up front and any other unresolved
    /// symbol is a compile error.
    fn runChecked(self: *Program, src: []const u8) !value_mod.Value {
        return self.runForms(src, self.arena.allocator(), true);
    }

    fn runForms(self: *Program, src: []const u8, compile_allocator: std.mem.Allocator, checked: bool) !value_mod.Value {
        var parse_result = try reader_mod.parser.parseProgram(testing.allocator, src);
        defer parse_result.parser.deinit();
        var rdr = reader_mod.Reader.init(testing.allocator, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parse_result.sexp);

        var declared = compile.DeclaredNames.init(testing.allocator);
        defer declared.deinit();
        if (checked) for (forms) |form| try declared.declareForm(form);

        var last_result: value_mod.Value = value_mod.nilValue();
        for (forms) |form| {
            const compiled = try compile.compileFormWith(compile_allocator, form, .{
                .namespace = self.registry.current,
                .interner = self.interner,
                .host_macros = &self.host_macros,
                .persistent_allocator = self.v.runtime_arena.allocator(),
                .registry = self.registry,
                .declared = if (checked) &declared else null,
            });
            const routine = compiled.toRoutine("numbers-form");
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

fn expectCheckedOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const result = try program.runChecked(src);
    const actual = try program.format(result);
    defer testing.allocator.free(actual);
    testing.expectEqualStrings(expected, actual) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, actual });
        return err;
    };
}

fn expectProgramError(src: []const u8, expected: anyerror) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(expected, program.run(src));
}

// Every big value here is built by arithmetic from `fm`, the
// largest fixnum, and `fmin`, the smallest.
const fm = "140737488355327";
const fmin = "-140737488355328";

test "promotion: a result that leaves i48 is a bignum, and the reverse step is a fixnum again" {
    try expectOutput("(integer? (+ " ++ fm ++ " 1))", "true");
    try expectOutput("(= (- (+ " ++ fm ++ " 1) 1) " ++ fm ++ ")", "true");
    try expectOutput("(= (+ (- " ++ fmin ++ " 1) 1) " ++ fmin ++ ")", "true");
    try expectOutput("(= (inc " ++ fm ++ ") (- (inc (inc " ++ fm ++ ")) 1))", "true");
    try expectOutput("(= (dec (inc " ++ fm ++ ")) " ++ fm ++ ")", "true");
    try expectOutput("(= (* 100000000 10000000000) (* 10000000000 100000000))", "true");
    try expectOutput("(= (- (* 2 " ++ fm ++ ") " ++ fm ++ ") " ++ fm ++ ")", "true");
    try expectOutput("(= (- (- " ++ fmin ++ ")) " ++ fmin ++ ")", "true");
    try expectOutput("(= (abs " ++ fmin ++ ") (- " ++ fmin ++ "))", "true");
    try expectOutput("(= (quot " ++ fmin ++ " -1) (- " ++ fmin ++ "))", "true");
    try expectOutput("(= (/ " ++ fmin ++ " -1) (- " ++ fmin ++ "))", "true");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (= (/ a " ++ fm ++ ") " ++ fm ++ "))", "true");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (= (quot a " ++ fm ++ ") " ++ fm ++ "))", "true");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (rem (+ a 2) " ++ fm ++ "))", "2");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] [(rem (- (+ a 2)) 7) (mod (- (+ a 2)) 7)])", "[-4 3]");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (= (mod (- a) a) 0))", "true");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (float? (/ a 2)))", "true");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (/ a 2))", "9.903520314282901E27");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (= (* a a) (* (* a " ++ fm ++ ") (* a " ++ fm ++ "))))", "false");
    try expectOutput("(let [a (* " ++ fm ++ " " ++ fm ++ ")] (= (* a a) (* (* a " ++ fm ++ ") " ++ fm ++ ")))", "true");
}

test "canonical form: bignums built differently are = and hash alike, and fixnum results are fixnums" {
    try expectOutput("(= (+ " ++ fm ++ " 1) (- (+ " ++ fm ++ " 2) 1))", "true");
    try expectOutput("(= (hash (+ " ++ fm ++ " 1)) (hash (* 2 (+ 1 (quot " ++ fm ++ " 2)))))", "true");
    try expectOutput("(get {(+ " ++ fm ++ " 1) :big} (* 2 (+ 1 (quot " ++ fm ++ " 2))))", ":big");
    try expectOutput("(contains? #{(* " ++ fm ++ " " ++ fm ++ ")} (* " ++ fm ++ " " ++ fm ++ "))", "true");
    try expectOutput("(= [(+ " ++ fm ++ " 1)] [(+ 1 " ++ fm ++ ")])", "true");
    try expectOutput("(not= (+ " ++ fm ++ " 1) (+ " ++ fm ++ " 2))", "true");
    try expectOutput("(= (+ " ++ fm ++ " 1) 140737488355328.0)", "false");
    try expectOutput("(== (+ " ++ fm ++ " 1) 140737488355328.0)", "true");
    try expectOutput("(- (+ " ++ fm ++ " 1) (+ " ++ fm ++ " 1))", "0");
    try expectOutput("(zero? (- (+ " ++ fm ++ " 1) (+ " ++ fm ++ " 1)))", "true");
}

test "ordering: <, >, compare, max, min and sort across the tower" {
    try expectOutput("(< " ++ fm ++ " (+ " ++ fm ++ " 1) (+ " ++ fm ++ " 2))", "true");
    try expectOutput("(> (- " ++ fmin ++ " 1) " ++ fmin ++ ")", "false");
    try expectOutput("(<= (+ " ++ fm ++ " 1) (+ " ++ fm ++ " 1))", "true");
    try expectOutput("(>= (* " ++ fm ++ " " ++ fm ++ ") (* " ++ fm ++ " 2))", "true");
    try expectOutput("(< 1.5e14 (+ " ++ fm ++ " 1))", "false");
    try expectOutput("(< 1.5e14 (* 2 " ++ fm ++ "))", "true");
    try expectOutput("[(compare (+ " ++ fm ++ " 1) 1) (compare 1 (+ " ++ fm ++ " 1)) (compare (+ " ++ fm ++ " 1) (+ " ++ fm ++ " 1))]", "[1 -1 0]");
    try expectOutput("(= (max (* 2 " ++ fm ++ ") 5 (* 3 " ++ fm ++ ")) (* 3 " ++ fm ++ "))", "true");
    try expectOutput("(min (* 2 " ++ fm ++ ") 5 (* 3 " ++ fm ++ "))", "5");
    try expectOutput("(= (min (- " ++ fmin ++ " 1) (- " ++ fmin ++ " 2)) (- " ++ fmin ++ " 2))", "true");
    try expectOutput("(= (max (* 2 " ++ fm ++ ") 1.0) (* 2 " ++ fm ++ "))", "true");
    try expectOutput("(max 1.0 (- " ++ fmin ++ " 1))", "1.0");
    try expectOutput("(= (sort [(* 3 " ++ fm ++ ") 2.5 (* 2 " ++ fm ++ ") 1]) [1 2.5 (* 2 " ++ fm ++ ") (* 3 " ++ fm ++ ")])", "true");
    try expectOutput("(= (sort > [(* 3 " ++ fm ++ ") 2.5 (* 2 " ++ fm ++ ") 1]) [(* 3 " ++ fm ++ ") (* 2 " ++ fm ++ ") 2.5 1])", "true");
}

test "contagion: a float operand makes a bignum operation a float" {
    try expectOutput("(+ (+ " ++ fm ++ " 1) 0.5)", "1.407374883553285E14");
    try expectOutput("(* (* 2 " ++ fm ++ ") 1.0)", "2.81474976710654E14");
    try expectOutput("(/ (+ " ++ fm ++ " 1) 2.0)", "7.0368744177664E13");
    try expectOutput("(quot (* 2 " ++ fm ++ ") 2.0)", "1.40737488355327E14");
    try expectOutput("(mod (* 2 " ++ fm ++ ") 3.0)", "2.0");
    try expectOutput("(mod (- (* 2 " ++ fm ++ ")) 3.0)", "1.0");
    try expectOutput("(/ (+ " ++ fm ++ " 1) 0.0)", "Infinity");
    try expectOutput("(float? (* (* " ++ fm ++ " " ++ fm ++ ") 1e300))", "true");
}

test "predicates over bignums" {
    try expectOutput("(let [b (+ " ++ fm ++ " 1)] [(number? b) (integer? b) (float? b)])", "[true true false]");
    try expectOutput("(let [b (* 2 " ++ fm ++ ")] [(even? b) (odd? b) (even? (inc b)) (odd? (inc b))])", "[true false false true]");
    try expectOutput("(let [b (- " ++ fmin ++ " 1)] [(odd? b) (even? b)])", "[true false]");
    try expectOutput("(let [b (+ " ++ fm ++ " 1)] [(pos? b) (neg? b) (zero? b) (pos? (- b)) (neg? (- b))])", "[true false false false true]");
    try expectOutput("(let [b (+ " ++ fm ++ " 1)] [(NaN? b) (infinite? b)])", "[false false]");
}

test "conversions: long truncates a float toward zero at any size, double widens" {
    try expectOutput("[(long 5) (long 3.99) (long -3.99) (long 0.5) (long -0.5)]", "[5 3 -3 0 0]");
    try expectOutput("(long 18446744073709551616)", "18446744073709551616");
    try expectOutput("(long 1e30)", "1000000000000000019884624838656");
    try expectOutput("(long -1.8446744073709552E19)", "-18446744073709551616");
    try expectOutput("[(long 140737488355328.0) (integer? (long 140737488355328.0)) (= (long 140737488355327.0) 140737488355327)]", "[140737488355328 true true]");
    try expectOutput("[(double 3) (double 1.5) (double 18446744073709551616) (double -140737488355328)]", "[3.0 1.5 1.8446744073709552E19 -1.40737488355328E14]");
    try expectOutput("(float? (double 18446744073709551616))", "true");
    try expectOutput("(try (long (/ 0.0 0.0)) (catch any e e))", ":invalid-argument");
    try expectOutput("(try (long (/ 1.0 0.0)) (catch any e e))", ":invalid-argument");
    try expectOutput("(try (long \"7\") (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (double nil) (catch any e e))", ":kind-mismatch");
}

test "errors: division by zero and kind mismatch are the catchable keywords" {
    try expectOutput("(try (/ (+ " ++ fm ++ " 1) 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (quot (+ " ++ fm ++ " 1) 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (rem (+ " ++ fm ++ " 1) 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (mod (+ " ++ fm ++ " 1) 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (+ (+ " ++ fm ++ " 1) :a) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (< (+ " ++ fm ++ " 1) nil) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (even? 2.0) (catch any e e))", ":kind-mismatch");
    try expectProgramError("(* (+ " ++ fm ++ " 1) \"x\")", vm.VmError.KindMismatch);
}

test "literals: integers beyond the fixnum range read as bignums and print in decimal" {
    try expectOutput("140737488355328", "140737488355328");
    try expectOutput("-140737488355329", "-140737488355329");
    try expectOutput("1000000000000000000", "1000000000000000000");
    try expectOutput("9223372036854775807", "9223372036854775807");
    try expectOutput("-9223372036854775808", "-9223372036854775808");
    try expectOutput("18446744073709551616", "18446744073709551616");
    try expectOutput("-18446744073709551616", "-18446744073709551616");
    try expectOutput("0x10000000000000000", "18446744073709551616");
    try expectOutput("123456789012345678901234567890123456789012345678901234567890", "123456789012345678901234567890123456789012345678901234567890");
    try expectOutput("[(integer? 18446744073709551616) (= 18446744073709551616 (* 4294967296 4294967296))]", "[true true]");
    try expectOutput("(= 140737488355328 (+ 140737488355327 1))", "true");
    try expectOutput("(- 140737488355328 1)", "140737488355327");
    try expectOutput("(integer? (- 140737488355328 1))", "true");
    try expectOutput("'(1 18446744073709551616)", "(1 18446744073709551616)");
    try expectOutput("[18446744073709551616 {:n -18446744073709551616}]", "[18446744073709551616 {:n -18446744073709551616}]");
    try expectOutput("(str 18446744073709551616)", "18446744073709551616");
    try expectOutput("(pr-str [18446744073709551616 \"s\"])", "[18446744073709551616 \"s\"]");
    try expectOutput("(str (* 140737488355327 140737488355327))", "19807040628565802923409276929");
    try expectOutput("(let [a 100000000000000000000] (+ a a))", "200000000000000000000");
}

test "literals: macros carry bignums in and out" {
    try expectOutput("(do (defmacro big [] 18446744073709551616) (big))", "18446744073709551616");
    try expectOutput("(do (defmacro big [] 9223372036854775807) (big))", "9223372036854775807");
    try expectOutput("(do (defmacro twice [x] `(* 2 ~x)) (twice 18446744073709551616))", "36893488147419103232");
    try expectOutput("(do (defmacro sq [x] (* x x)) (sq 4294967296))", "18446744073709551616");
    try expectOutput("(do (defmacro sq [x] (* x x)) (sq 18446744073709551616))", "340282366920938463463374607431768211456");
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

test "codec: bignums round-trip through db/put-key! and db/get-key, alone and inside collections" {
    var store = try StorePath.init("bignum-codec");
    defer store.deinit();
    const src = try std.fmt.allocPrint(testing.allocator,
        \\(do
        \\  (def conn (db/open "{s}"))
        \\  (def big (db/ref conn :t "big"))
        \\  (def neg (db/ref conn :t "neg"))
        \\  (def edge (db/ref conn :t "edge"))
        \\  (def coll (db/ref conn :t "coll"))
        \\  (db/put-key! big 18446744073709551616)
        \\  (db/put-key! neg (- (* 140737488355327 140737488355327)))
        \\  (db/put-key! edge (+ 140737488355327 1))
        \\  (db/put-key! coll [1 18446744073709551616 {{:k -18446744073709551617}} #{{340282366920938463463374607431768211456}}])
        \\  [(db/get-key big) (integer? (db/get-key big)) (= (db/get-key big) 18446744073709551616)
        \\   (db/get-key neg) @edge (= @edge 140737488355328) (integer? (- @edge 1))
        \\   (db/get-key coll) (contains? (nth (db/get-key coll) 3) (* 18446744073709551616 18446744073709551616))])
    , .{store.path});
    defer testing.allocator.free(src);
    try expectOutput(src, "[18446744073709551616 true true -19807040628565802923409276929 140737488355328 true true [1 18446744073709551616 {:k -18446744073709551617} #{340282366920938463463374607431768211456}] true]");
}

test "programs: factorial and a product fold grow past 2^47 and come back" {
    try expectOutput("(reduce * (range 1 30))", "8841761993739701954543616000000");
    try expectOutput("(= (reduce * (range 1 30)) (* (reduce * (range 1 29)) 29))", "true");
    try expectOutput("(let [f (fn [n] (loop [i n acc 1] (if (= i 0) acc (recur (dec i) (* acc i)))))] (f 25))", "15511210043330985984000000");
    try expectOutput("(let [f (fn [n] (loop [i n acc 1] (if (= i 0) acc (recur (dec i) (* acc i)))))] (= (quot (f 25) (f 24)) 25))", "true");
    try expectOutput("(let [f (fn [n] (loop [i n acc 1] (if (= i 0) acc (recur (dec i) (* acc i)))))] (integer? (f 25)))", "true");
    try expectOutput("(let [f (fn [n] (loop [i n acc 1] (if (= i 0) acc (recur (dec i) (* acc i)))))] (rem (f 25) 1000000007))", "440732388");
    try expectOutput("(let [b (* " ++ fm ++ " " ++ fm ++ ")] (loop [x b n 0] (if (< x 1) n (recur (quot x 2) (inc n)))))", "94");
}

// =============================================================================
// nexis.math (TOOLING.md §4)
// =============================================================================

test "nexis.math: sqrt and pow are over doubles for every number" {
    try expectOutput("(nexis.math/sqrt 16)", "4.0");
    try expectOutput("(nexis.math/sqrt 2.25)", "1.5");
    try expectOutput("(nexis.math/sqrt 100000000000000000000)", "1.0E10");
    try expectOutput("(nexis.math/pow 2 10)", "1024.0");
    try expectOutput("(nexis.math/pow 2.0 0.5)", "1.4142135623730951");
    try expectOutput("(nexis.math/pow 10 -1)", "0.1");
    try expectOutput("(NaN? (nexis.math/sqrt -1))", "true");
    try expectOutput("(try (nexis.math/sqrt :x) (catch any e e))", ":kind-mismatch");
}

test "nexis.math: floor, ceil and round keep integers and convert floats" {
    try expectOutput("[(nexis.math/floor 7) (nexis.math/ceil 7) (nexis.math/round 7)]", "[7 7 7]");
    try expectOutput("[(nexis.math/floor 2.7) (nexis.math/ceil 2.2) (nexis.math/floor -2.2) (nexis.math/ceil -2.7)]", "[2.0 3.0 -3.0 -2.0]");
    try expectOutput("[(nexis.math/round 2.5) (nexis.math/round 2.4) (nexis.math/round -2.5) (nexis.math/round -2.6)]", "[3 2 -2 -3]");
    try expectOutput("(nexis.math/round 1.0E20)", "100000000000000000000");
    try expectOutput("(nexis.math/floor 100000000000000000000)", "100000000000000000000");
    try expectOutput("(integer? (nexis.math/round 2.5))", "true");
    try expectOutput("(try (nexis.math/round (/ 1.0 0)) (catch any e e))", ":invalid-argument");
}

test "nexis.math: PI and E" {
    try expectOutput("nexis.math/PI", "3.141592653589793");
    try expectOutput("nexis.math/E", "2.718281828459045");
    try expectOutput("(nexis.math/round (* 2 nexis.math/PI))", "6");
}
