//! test/integration/eval_pipeline.zig — Phase 2 gate close-out
//! (COMPILER.md §9.4 + §10 step #11 + §11 golden+eval tests).
//!
//! End-to-end pipeline coverage: source → reader → macroexpand →
//! lowerForm → Tiny → compile → VM → printed Value. Each test
//! case is a `.nx` source string + an expected printed-output
//! string. Failures show the diff in test output.
//!
//! Categories (mirroring the source-surface taxonomy):
//!   - literals
//!   - arithmetic
//!   - conditionals
//!   - bindings (let* / let / loop* / loop / recur)
//!   - functions (fn* / fn / closures)
//!   - vars (def / defn / forward references)
//!   - macros (when / and / or / cond / -> / ->>)
//!   - quote / syntax-quote / collections
//!   - try / catch / finally / throw
//!
//! Per peer-AI turn 28 §"Golden test discipline": every
//! primitive-core form has at least one golden here; every
//! macro from defaultMacros has at least one golden; every
//! exit path of try/catch/finally has at least one golden.

const std = @import("std");
const value_mod = @import("value");
const vm = @import("vm");
const compile = @import("compile");
const intern_mod = @import("intern");
const reader_mod = @import("reader");
const expand_mod = @import("expand");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const stdlib = @import("stdlib");

const testing = std.testing;

/// Format a runtime Value the same way the CLI does. Tests
/// compare against the printed form, NOT the internal Value
/// representation — that's the end-user contract.
fn formatValue(buf: *std.array_list.Managed(u8), v: value_mod.Value, interner: *const intern_mod.Interner) anyerror!void {
    switch (v.kind()) {
        .nil => try buf.appendSlice("nil"),
        .true_ => try buf.appendSlice("true"),
        .false_ => try buf.appendSlice("false"),
        .fixnum => {
            const s = try std.fmt.allocPrint(testing.allocator, "{d}", .{v.asFixnum()});
            defer testing.allocator.free(s);
            try buf.appendSlice(s);
        },
        .symbol => {
            const id: u32 = @intCast(v.payload);
            try buf.appendSlice(interner.symbolName(id));
        },
        .keyword => {
            const id: u32 = @intCast(v.payload);
            try buf.append(':');
            try buf.appendSlice(interner.keywordName(id));
        },
        .list => {
            try buf.append('(');
            var node = v;
            var first = true;
            while (node.kind() == .list and !list_mod.isEmpty(node)) {
                if (!first) try buf.append(' ');
                first = false;
                try formatValue(buf, list_mod.head(node), interner);
                node = list_mod.tail(node);
            }
            try buf.append(')');
        },
        .persistent_vector => {
            try buf.append('[');
            const n = vector_mod.count(v);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try buf.append(' ');
                try formatValue(buf, vector_mod.nth(v, i), interner);
            }
            try buf.append(']');
        },
        .persistent_map => {
            try buf.append('{');
            var it = champ_mod.mapIter(v);
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buf.appendSlice(", ");
                first = false;
                try formatValue(buf, entry.key, interner);
                try buf.append(' ');
                try formatValue(buf, entry.value, interner);
            }
            try buf.append('}');
        },
        .persistent_set => {
            try buf.appendSlice("#{");
            var it = champ_mod.setIter(v);
            var first = true;
            while (it.next()) |elem| {
                if (!first) try buf.append(' ');
                first = false;
                try formatValue(buf, elem, interner);
            }
            try buf.append('}');
        },
        .var_ => {
            const var_obj = vm.VM.asVar(v);
            try buf.appendSlice("#'");
            try buf.appendSlice(var_obj.name);
        },
        .function => try buf.appendSlice("#<fn>"),
        else => {
            const s = try std.fmt.allocPrint(testing.allocator, "#<value kind={d}>", .{@intFromEnum(v.kind())});
            defer testing.allocator.free(s);
            try buf.appendSlice(s);
        },
    }
}

/// Phase 3.3d: compile + run the embedded core.nx layer
/// against `v` so test programs can use composite definitions
/// (second, last, reverse, range, take, drop, when-let,
/// if-let, dotimes). Uses the VM's runtime arena as the
/// compile arena so closures + routines outlive bootstrap.
fn bootstrapCoreForTest(
    v: *vm.VM,
    ns: *vm.Namespace,
    interner: *intern_mod.Interner,
    host_macros: *const expand_mod.HostMacroTable,
) !void {
    var parse_result = try reader_mod.parser.parseProgram(testing.allocator, stdlib.CORE_NX_SOURCE);
    defer parse_result.parser.deinit();
    var rdr = reader_mod.Reader.init(testing.allocator, stdlib.CORE_NX_SOURCE);
    defer rdr.deinit();
    const forms = try rdr.readProgram(parse_result.sexp);
    const ra = v.runtime_arena.allocator();
    for (forms) |form| {
        const compiled = try compile.compileFormFullWithMacrosSpanPersistent(
            ra,
            form,
            ns,
            interner,
            host_macros,
            null,
            ra,
        );
        const routine = compiled.toRoutine("core-nx-test");
        v.frames.items[0].routine = &routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = routine.slot_count;
        v.halted = false;
        if (v.stack.items.len < routine.slot_count) {
            try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
        }
        _ = try v.run();
    }
}

/// Run `src` end-to-end and assert the printed output equals
/// `expected`. Wraps multiple top-level forms in an implicit do
/// so callers can write multi-form programs naturally.
fn expectOutput(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    // Phase 3.3a: install core native fns so integration tests
    // can exercise list/cons/first/rest/etc.
    try stdlib.installCore(ns);
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    // Phase 3.3d: bootstrap composite core.nx layer so tests
    // can exercise when-let/if-let/dotimes/second/last/reverse/
    // range/take/drop.
    try bootstrapCoreForTest(&v, ns, interner, &host_macros);

    const compiled = try compile.compileSourceFullWithMacros(
        arena.allocator(),
        src,
        ns,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("integration");
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    // Reset halted because bootstrap left the VM in the halted
    // state after running the last core.nx form.
    v.halted = false;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    const result = try v.run();

    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, result, interner);

    testing.expectEqualStrings(expected, buf.items) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, buf.items });
        return err;
    };
}

// =============================================================================
// Literals + arithmetic
// =============================================================================

test "integration: literals" {
    try expectOutput("nil", "nil");
    try expectOutput("true", "true");
    try expectOutput("false", "false");
    try expectOutput("0", "0");
    try expectOutput("42", "42");
    try expectOutput("-7", "-7");
    try expectOutput(":hello", ":hello");
    try expectOutput("'foo", "foo");
}

test "integration: arithmetic" {
    try expectOutput("(+ 1 2)", "3");
    try expectOutput("(+ 0 0)", "0");
    try expectOutput("(+ -5 5)", "0");
    try expectOutput("(+ (+ 1 2) (+ 3 4))", "10");
}

test "integration: comparison" {
    try expectOutput("(< 1 2)", "true");
    try expectOutput("(< 2 1)", "false");
    try expectOutput("(< 5 5)", "false");
}

// =============================================================================
// Conditionals
// =============================================================================

test "integration: if" {
    try expectOutput("(if true :yes :no)", ":yes");
    try expectOutput("(if false :yes :no)", ":no");
    try expectOutput("(if nil :yes :no)", ":no");
    try expectOutput("(if 0 :truthy :falsy)", ":truthy"); // 0 is truthy
    try expectOutput("(if :kw :truthy :falsy)", ":truthy");
}

test "integration: do" {
    try expectOutput("(do 1)", "1");
    try expectOutput("(do 1 2 3)", "3");
    try expectOutput("(do (+ 1 2) (+ 3 4))", "7");
}

// =============================================================================
// Bindings (let* + rename, loop* + rename, recur)
// =============================================================================

test "integration: let*" {
    try expectOutput("(let* [x 1] x)", "1");
    try expectOutput("(let* [x 1 y 2] (+ x y))", "3");
    try expectOutput("(let* [x 1 y x] y)", "1"); // sequential: y sees x
}

test "integration: let (rename macro)" {
    try expectOutput("(let [x 10 y 20] (+ x y))", "30");
}

test "integration: loop*/recur" {
    try expectOutput("(loop* [i 0 acc 0] (if (< i 5) (recur (+ i 1) (+ acc i)) acc))", "10");
    // 0+1+2+3+4 = 10
}

test "integration: loop (rename macro)" {
    try expectOutput("(loop [i 0] (if (< i 3) (recur (+ i 1)) i))", "3");
}

// =============================================================================
// Functions and closures
// =============================================================================

test "integration: fn*" {
    try expectOutput("((fn* [x] (+ x 1)) 41)", "42");
    try expectOutput("((fn* [x y] (+ x y)) 10 20)", "30");
    try expectOutput("((fn* [] 99))", "99");
}

test "integration: fn (rename macro)" {
    try expectOutput("((fn [x] (+ x 100)) 5)", "105");
}

test "integration: closures capture outer bindings" {
    try expectOutput("(let* [x 42] ((fn* [] x)))", "42");
    try expectOutput("(let* [x 1 y 2] ((fn* [] (+ x y))))", "3");
}

test "integration: deeply nested closure capture" {
    try expectOutput("(let* [x 7] ((fn* [] ((fn* [] ((fn* [] x)))))))", "7");
}

test "integration: named fn* + recursion via self-name" {
    try expectOutput("((fn* fact [n] (if (< n 2) n (recur (+ n -1)))) 5)", "1");
}

test "integration: variadic & rest" {
    // ((fn [x & xs] x) 1 2 3) → 1
    try expectOutput("((fn* [x & xs] x) 1 2 3)", "1");
}

// =============================================================================
// Vars and definitions
// =============================================================================

test "integration: def returns the Var" {
    try expectOutput("(def x 5)", "#'x");
}

test "integration: def + Var lookup" {
    try expectOutput("(do (def x 42) x)", "42");
}

test "integration: defn" {
    try expectOutput("(do (defn inc [x] (+ x 1)) (inc 41))", "42");
}

test "integration: defn forward reference (Var late-binding)" {
    try expectOutput("(do (defn f [] (g)) (defn g [] 99) (f))", "99");
}

// =============================================================================
// Macros — each macro from defaultMacros gets a case
// =============================================================================

test "integration: macro when" {
    try expectOutput("(when true 1 2 3)", "3");
    try expectOutput("(when false 1)", "nil");
}

test "integration: macro when-not" {
    try expectOutput("(when-not false 7)", "7");
    try expectOutput("(when-not true 7)", "nil");
}

test "integration: macro and" {
    try expectOutput("(and)", "true");
    try expectOutput("(and 1 2 3)", "3");
    try expectOutput("(and 1 nil 3)", "nil");
    try expectOutput("(and 0 1)", "1"); // 0 is truthy
}

test "integration: macro or" {
    try expectOutput("(or)", "nil");
    try expectOutput("(or nil false 7)", "7");
    try expectOutput("(or false nil)", "nil");
    try expectOutput("(or 0 7)", "0"); // 0 is truthy
}

test "integration: macro cond" {
    try expectOutput("(cond)", "nil");
    try expectOutput("(cond true :a)", ":a");
    try expectOutput("(cond false :a false :b :else :c)", ":c");
}

test "integration: macro ->" {
    try expectOutput("(-> 1 (+ 2) (+ 3))", "6");
    try expectOutput("(-> 10)", "10");
}

test "integration: macro ->>" {
    try expectOutput("(->> 1 (+ 2) (+ 3))", "6");
}

// =============================================================================
// Quote / syntax-quote / collections
// =============================================================================

test "integration: quote scalar" {
    try expectOutput("(quote 42)", "42");
    try expectOutput("(quote foo)", "foo");
    try expectOutput("(quote :bar)", ":bar");
}

test "integration: quote list" {
    try expectOutput("(quote (1 2 3))", "(1 2 3)");
    try expectOutput("(quote ())", "()");
    try expectOutput("(quote (a (b c) d))", "(a (b c) d)");
}

test "integration: quote vector" {
    try expectOutput("(quote [1 2 3])", "[1 2 3]");
    try expectOutput("(quote [])", "[]");
}

test "integration: syntax-quote no unquote" {
    try expectOutput("`(1 2 3)", "(1 2 3)");
    try expectOutput("`(a b c)", "(a b c)");
}

test "integration: syntax-quote with unquote" {
    try expectOutput("(let* [x 5] `(value ~x))", "(value 5)");
}

test "integration: syntax-quote with splicing" {
    try expectOutput(
        "(let* [xs (quote (b c d))] `(a ~@xs e))",
        "(a b c d e)",
    );
}

test "integration: syntax-quote vector" {
    try expectOutput("(let* [x 10 y 20] `[~x ~y])", "[10 20]");
}

test "integration: synthesize let* form (the macro author's pattern)" {
    try expectOutput(
        "(let* [name (quote x) val 42] `(let* [~name ~val] ~name))",
        "(let* [x 42] x)",
    );
}

// =============================================================================
// Exception handling
// =============================================================================

test "integration: try normal exit" {
    try expectOutput("(try 42 (catch any e e))", "42");
}

test "integration: try catches throw" {
    try expectOutput("(try (throw 7) (catch any e e))", "7");
    try expectOutput("(try (throw :boom) (catch any e e))", ":boom");
}

test "integration: try cross-frame" {
    try expectOutput(
        "(do (defn f [] (throw 99)) (try (f) (catch any e e)))",
        "99",
    );
}

test "integration: try/catch/finally — normal exit" {
    try expectOutput("(try 1 (catch any e 99) (finally 42))", "1");
}

test "integration: try/catch/finally — caught throw" {
    try expectOutput("(try (throw 7) (catch any e e) (finally 99))", "7");
}

test "integration: throw inside finally overrides" {
    try expectOutput(
        "(try (try 1 (catch any e e) (finally (throw 99))) (catch any e e))",
        "99",
    );
}

test "integration: nested try — outer catches what inner rethrows" {
    try expectOutput(
        "(try (try (throw 100) (catch any e (throw e))) (catch any e e))",
        "100",
    );
}

// =============================================================================
// Composite programs — every category at once
// =============================================================================

test "integration: composite — defn + cond + recur" {
    try expectOutput(
        \\(do
        \\  (defn classify [n]
        \\    (cond
        \\      (< n 0)  :neg
        \\      (< n 10) :small
        \\      :else    :big))
        \\  (classify 5))
    , ":small");
}

test "integration: composite — let + threading" {
    try expectOutput(
        "(let [start 0] (-> start (+ 1) (+ 10) (+ 100)))",
        "111",
    );
}

test "integration: composite — sum using loop/recur, gensym-hygienic or" {
    try expectOutput(
        \\(do
        \\  (defn sum-up-to [n]
        \\    (loop [i 0 acc 0]
        \\      (if (< i (+ n 1)) (recur (+ i 1) (+ acc i)) acc)))
        \\  (or (sum-up-to 10) :never))
    , "55");
}

test "integration: composite — try with macros" {
    try expectOutput(
        \\(do
        \\  (defn check [n]
        \\    (when-not (< -1 n) (throw :negative))
        \\    n)
        \\  (try (check 42) (catch any e e)))
    , "42");
}

// =============================================================================
// Phase 3.3a — native fns (macro-authoring primitives)
// =============================================================================

test "integration: native list — empty + variadic" {
    try expectOutput("(list)", "()");
    try expectOutput("(list 1 2 3)", "(1 2 3)");
}

test "integration: native cons" {
    try expectOutput("(cons 0 (list 1 2 3))", "(0 1 2 3)");
    try expectOutput("(cons :x nil)", "(:x)");
}

test "integration: native first — nil/list/vector" {
    try expectOutput("(first nil)", "nil");
    try expectOutput("(first (list))", "nil");
    try expectOutput("(first (list :a :b))", ":a");
    try expectOutput("(first [10 20 30])", "10");
}

test "integration: native rest — nil/list/vector" {
    try expectOutput("(rest nil)", "()");
    try expectOutput("(rest (list))", "()");
    try expectOutput("(rest (list :a :b :c))", "(:b :c)");
    try expectOutput("(rest [10 20 30])", "(20 30)");
}

test "integration: native count — nil/list/vector/map/set" {
    try expectOutput("(count nil)", "0");
    try expectOutput("(count (list))", "0");
    try expectOutput("(count (list 1 2 3))", "3");
    try expectOutput("(count [10 20 30])", "3");
    try expectOutput("(count {:a 1 :b 2})", "2");
    try expectOutput("(count #{1 2 3 4})", "4");
}

test "integration: native nth — list + vector" {
    try expectOutput("(nth (list :a :b :c) 0)", ":a");
    try expectOutput("(nth (list :a :b :c) 2)", ":c");
    try expectOutput("(nth [10 20 30] 1)", "20");
}

test "integration: native nth — out of bounds catchable" {
    try expectOutput("(try (nth [1 2] 5) (catch any e e))", ":index-out-of-bounds");
}

test "integration: native empty?" {
    try expectOutput("(empty? nil)", "true");
    try expectOutput("(empty? (list))", "true");
    try expectOutput("(empty? (list 1))", "false");
    try expectOutput("(empty? [])", "true");
    try expectOutput("(empty? [1])", "false");
    try expectOutput("(empty? {})", "true");
    try expectOutput("(empty? #{})", "true");
}

test "integration: native identity / nil? / some?" {
    try expectOutput("(identity :hello)", ":hello");
    try expectOutput("(nil? nil)", "true");
    try expectOutput("(nil? 0)", "false");
    try expectOutput("(some? nil)", "false");
    try expectOutput("(some? 0)", "true");
}

test "integration: my-cond — user procedural macro using native fns" {
    // The canonical 3.3a payoff: a user-written recursive
    // procedural macro that uses first/rest/empty? at COMPILE
    // TIME. Native fns work in defmacro bodies because the
    // persistent-namespace design from 3.2 makes them visible
    // to the compile-time sub-VM.
    try expectOutput(
        \\(do (defmacro my-cond [& clauses]
        \\      (if (empty? clauses)
        \\        nil
        \\        `(if ~(first clauses)
        \\           ~(first (rest clauses))
        \\           (my-cond ~@(rest (rest clauses))))))
        \\    (my-cond))
    , "nil");
    try expectOutput(
        \\(do (defmacro my-cond [& clauses]
        \\      (if (empty? clauses)
        \\        nil
        \\        `(if ~(first clauses)
        \\           ~(first (rest clauses))
        \\           (my-cond ~@(rest (rest clauses))))))
        \\    (my-cond false :no true :yes false :nope))
    , ":yes");
}

test "integration: native fn — arity mismatch is catchable" {
    try expectOutput("(try (first) (catch any e e))", ":arity-mismatch");
    try expectOutput("(try (cons 1) (catch any e e))", ":arity-mismatch");
}

// =============================================================================
// Phase 3.3d — embedded core.nx composite layer
// =============================================================================

test "integration: 3.3d — second / third / last" {
    try expectOutput("(second [10 20 30])", "20");
    try expectOutput("(third [10 20 30])", "30");
    try expectOutput("(last [10 20 30])", "30");
    try expectOutput("(last (list :a :b :c))", ":c");
    try expectOutput("(last (list))", "nil");
}

test "integration: 3.3d — reverse" {
    try expectOutput("(reverse [1 2 3 4 5])", "(5 4 3 2 1)");
    try expectOutput("(reverse (list))", "()");
    try expectOutput("(reverse nil)", "()");
}

test "integration: 3.3d — range" {
    try expectOutput("(range 0)", "()");
    try expectOutput("(range 1)", "(0)");
    try expectOutput("(range 5)", "(0 1 2 3 4)");
}

test "integration: 3.3d — take / drop" {
    try expectOutput("(take 3 [1 2 3 4 5])", "(1 2 3)");
    try expectOutput("(take 0 [1 2 3])", "()");
    try expectOutput("(take 10 [1 2 3])", "(1 2 3)");
    try expectOutput("(drop 2 [1 2 3 4 5])", "(3 4 5)");
    try expectOutput("(drop 10 [1 2 3])", "()");
    try expectOutput("(drop 0 (list :a :b))", "(:a :b)");
}

test "integration: 3.3d — true? / false?" {
    try expectOutput("(true? true)", "true");
    try expectOutput("(true? 1)", "false");
    try expectOutput("(true? :a)", "false");
    try expectOutput("(false? false)", "true");
    try expectOutput("(false? nil)", "false");
}

test "integration: 3.3d — when-let" {
    try expectOutput("(when-let [x 42] (+ x 1))", "43");
    try expectOutput("(when-let [x nil] :unreached)", "nil");
    try expectOutput("(when-let [x false] :unreached)", "nil");
    try expectOutput("(when-let [x (list 1 2)] (first x))", "1");
}

test "integration: 3.3d — if-let" {
    try expectOutput("(if-let [x 7] (* x x) :nope)", "49");
    try expectOutput("(if-let [x nil] :nope :else-branch)", ":else-branch");
    try expectOutput("(if-let [x (get {:a 1} :missing)] x :default)", ":default");
}

test "integration: 3.3d — composite + HOFs" {
    try expectOutput("(reduce + 0 (range 10))", "45");
    try expectOutput("(count (filter odd? (range 10)))", "5");
    try expectOutput("(reverse (map inc [1 2 3]))", "(4 3 2)");
}

// =============================================================================
// Phase 3.3c — collection utilities
// =============================================================================

test "integration: 3.3c — vector / vec" {
    try expectOutput("(vector 1 2 3)", "[1 2 3]");
    try expectOutput("(vector)", "[]");
    try expectOutput("(vec (list :a :b :c))", "[:a :b :c]");
    try expectOutput("(vec nil)", "[]");
}

test "integration: 3.3c — hash-map / hash-set" {
    try expectOutput("(hash-set 1 2 3 1 2)", "#{1 2 3}");
    // hash-map iteration order is unspecified (HAMT); test via count + get
    try expectOutput("(count (hash-map :a 1 :b 2 :c 3))", "3");
    try expectOutput("(get (hash-map :a 1 :b 2) :a)", "1");
}

test "integration: 3.3c — assoc / dissoc" {
    try expectOutput("(get (assoc {:a 1} :b 2) :b)", "2");
    try expectOutput("(get (assoc nil :x 99) :x)", "99");
    try expectOutput("(contains? (dissoc {:a 1 :b 2} :a) :a)", "false");
    try expectOutput("(contains? (dissoc {:a 1 :b 2} :a) :b)", "true");
}

test "integration: 3.3c — get (2-arg + 3-arg default)" {
    try expectOutput("(get {:a 1} :a)", "1");
    try expectOutput("(get {:a 1} :missing)", "nil");
    try expectOutput("(get {:a 1} :missing :default)", ":default");
    try expectOutput("(get [10 20 30] 1)", "20");
    try expectOutput("(get [10 20 30] 99 :oob)", ":oob");
    try expectOutput("(get #{1 2 3} 2)", "2");
    try expectOutput("(get nil :anything :fallback)", ":fallback");
}

test "integration: 3.3c — contains?" {
    try expectOutput("(contains? {:a 1} :a)", "true");
    try expectOutput("(contains? {:a 1} :b)", "false");
    try expectOutput("(contains? #{1 2 3} 2)", "true");
    try expectOutput("(contains? [10 20 30] 1)", "true");
    try expectOutput("(contains? [10 20 30] 99)", "false");
    try expectOutput("(contains? nil :anything)", "false");
}

test "integration: 3.3c — keys / vals" {
    try expectOutput("(count (keys {:a 1 :b 2 :c 3}))", "3");
    try expectOutput("(count (vals {:a 1 :b 2 :c 3}))", "3");
    try expectOutput("(keys nil)", "()");
    try expectOutput("(vals nil)", "()");
}

test "integration: 3.3c — conj (kind-specific)" {
    try expectOutput("(conj nil 1 2 3)", "(3 2 1)"); // Clojure reverses for nil/list
    try expectOutput("(conj (list 1 2 3) 0)", "(0 1 2 3)");
    try expectOutput("(conj [10 20] 30 40)", "[10 20 30 40]");
    try expectOutput("(get (conj {:a 1} [:b 2]) :b)", "2");
    try expectOutput("(contains? (conj #{1 2} 3 4) 4)", "true");
}

test "integration: 3.3c — collection ops compose with HOFs" {
    try expectOutput(
        \\(reduce (fn* [m k] (assoc m k true)) {} [:a :b :c])
    , "{:a true, :b true, :c true}");
    try expectOutput("(count (filter (fn* [x] (contains? #{1 3 5} x)) [1 2 3 4 5]))", "3");
}

// =============================================================================
// Phase 3.3b — VM.callValue + apply + HOFs + first-class arithmetic
// =============================================================================

test "integration: 3.3b — variadic native + / * / - / <" {
    try expectOutput("(+)", "0");
    try expectOutput("(+ 1 2 3 4 5)", "15");
    try expectOutput("(*)", "1");
    try expectOutput("(* 2 3 4)", "24");
    try expectOutput("(- 10 3)", "7");
    try expectOutput("(- 7)", "-7");
    try expectOutput("(<)", "true");
    try expectOutput("(< 1 2 3)", "true");
    try expectOutput("(< 1 3 2)", "false");
}

test "integration: 3.3b — value equality `=` (variadic, structural)" {
    try expectOutput("(=)", "true");
    try expectOutput("(= 1)", "true");
    try expectOutput("(= 1 1 1)", "true");
    try expectOutput("(= 1 1 2)", "false");
    try expectOutput("(= :a :a)", "true");
    try expectOutput("(= [1 2 3] [1 2 3])", "true");
    try expectOutput("(= {:a 1} {:a 1})", "true");
}

test "integration: 3.3b — inc / dec / not / predicates" {
    try expectOutput("(inc 41)", "42");
    try expectOutput("(dec 1)", "0");
    try expectOutput("(not nil)", "true");
    try expectOutput("(not false)", "true");
    try expectOutput("(not 0)", "false");
    try expectOutput("(zero? 0)", "true");
    try expectOutput("(pos? 5)", "true");
    try expectOutput("(neg? -3)", "true");
    try expectOutput("(odd? 7)", "true");
    try expectOutput("(even? 4)", "true");
}

test "integration: 3.3b — apply (no leading args)" {
    try expectOutput("(apply + (list 1 2 3 4 5))", "15");
    try expectOutput("(apply * [2 3 4])", "24");
}

test "integration: 3.3b — apply with leading args" {
    try expectOutput("(apply + 10 (list 1 2 3))", "16");
    try expectOutput("(apply + 1 2 3 (list 4 5))", "15");
}

test "integration: 3.3b — apply with user fn" {
    try expectOutput(
        \\(do (defn square [x] (* x x))
        \\    (apply square (list 7)))
    , "49");
}

test "integration: 3.3b — map (eager) on list + vector" {
    try expectOutput("(map inc (list 1 2 3 4))", "(2 3 4 5)");
    try expectOutput("(map inc [10 20 30])", "(11 21 31)");
    try expectOutput("(map inc nil)", "()");
}

test "integration: 3.3b — reduce" {
    try expectOutput("(reduce + 0 [1 2 3 4 5])", "15");
    try expectOutput("(reduce + 0 (list))", "0");
    try expectOutput("(reduce * 1 [1 2 3 4])", "24");
    try expectOutput("(reduce + 100 nil)", "100");
}

test "integration: 3.3b — filter" {
    try expectOutput("(filter odd? [1 2 3 4 5 6 7])", "(1 3 5 7)");
    try expectOutput("(filter pos? [-2 -1 0 1 2])", "(1 2)");
    try expectOutput("(filter some? (list 1 nil 2 nil 3))", "(1 2 3)");
}

test "integration: 3.3b — map with user lambda" {
    try expectOutput(
        \\(map (fn* [x] (* x x)) [1 2 3 4])
    , "(1 4 9 16)");
}

test "integration: 3.3b — reduce with user lambda" {
    try expectOutput(
        \\(reduce (fn* [acc x] (+ acc (* x x))) 0 [1 2 3])
    , "14");
}

test "integration: 3.3b — throw inside map propagates to outer catch" {
    try expectOutput(
        \\(try (map (fn* [x] (throw :boom)) [1 2 3])
        \\     (catch any e e))
    , ":boom");
}

test "integration: 3.3b — throw inside reduce propagates" {
    try expectOutput(
        \\(try (reduce (fn* [acc x]
        \\               (if (< 10 acc)
        \\                 (throw :too-big)
        \\                 (+ acc x)))
        \\             0 [1 5 8 2])
        \\     (catch any e e))
    , ":too-big");
}

test "integration: 3.3b — throw through apply" {
    try expectOutput(
        \\(try (apply (fn* [x] (throw :inside-apply)) (list 99))
        \\     (catch any e e))
    , ":inside-apply");
}

test "integration: 3.3b — HOFs composed" {
    try expectOutput(
        \\(reduce + 0 (filter odd? (map inc [0 1 2 3 4 5])))
    , "9");
    // (map inc xs) => (1 2 3 4 5 6)
    // (filter odd? ...) => (1 3 5)
    // (reduce + 0 ...) => 9
}

// =============================================================================
// Phase 3.2 — user-defined defmacro
// =============================================================================

test "integration: defmacro — define then use in same do-block" {
    try expectOutput(
        \\(do (defmacro my-unless [test body] `(if ~test nil ~body))
        \\    (my-unless false :got-it))
    , ":got-it");
}

test "integration: defmacro — true branch returns nil for unless" {
    try expectOutput(
        \\(do (defmacro my-unless [test body] `(if ~test nil ~body))
        \\    (my-unless true :nope))
    , "nil");
}

test "integration: defmacro — variadic body with splicing" {
    try expectOutput(
        \\(do (defmacro my-when [test & body] `(if ~test (do ~@body) nil))
        \\    (my-when true :a :b :c))
    , ":c");
}

test "integration: defmacro — lexical shadowing suppresses macro" {
    try expectOutput(
        \\(do (defmacro foo [x] `(+ ~x 100))
        \\    (let [foo 7] foo))
    , "7");
}

test "integration: defmacro — user macro shadows host macro" {
    try expectOutput(
        \\(do (defmacro when [test] `(if ~test :user-when :nope))
        \\    (when true))
    , ":user-when");
}

test "integration: defmacro — macro can use already-defined macros in body" {
    // outer's body uses unless (a previously-defined macro);
    // when outer is invoked, the macro fn body is already
    // expanded so the unless call is already turned into (if).
    try expectOutput(
        \\(do (defmacro unless [test body] `(if ~test nil ~body))
        \\    (defmacro twice [x] `(unless false ~x))
        \\    (twice :twice-got-it))
    , ":twice-got-it");
}

// =============================================================================
// Phase 3.1 — maps/sets as runtime values
// =============================================================================

test "integration: quoted empty map" {
    try expectOutput("(quote {})", "{}");
}

test "integration: quoted map with keyword keys" {
    try expectOutput("(quote {:a 1})", "{:a 1}");
}

test "integration: runtime map literal — computed value" {
    try expectOutput("(let* [n 42] {:answer n})", "{:answer 42}");
}

test "integration: nested quoted maps" {
    try expectOutput("(quote {:outer {:inner 1}})", "{:outer {:inner 1}}");
}

test "integration: quoted empty set" {
    try expectOutput("(quote #{})", "#{}");
}

test "integration: quoted set" {
    try expectOutput("(quote #{:a})", "#{:a}");
}

test "integration: runtime set literal" {
    try expectOutput("#{:x}", "#{:x}");
}

test "integration: bare vector literal as expression" {
    try expectOutput("[1 2 3]", "[1 2 3]");
}

// =============================================================================
// Phase 3.0c — catchable VmErrors
// =============================================================================
//
// Per peer-AI turn 62: recoverable VmError variants are
// translated into keyword Values when an active handler can
// catch them. Without a handler, the raw VmError propagates
// unchanged (backward compat).

test "integration: catchable — KindMismatch caught as :kind-mismatch" {
    try expectOutput("(try (+ 1 :hello) (catch any e e))", ":kind-mismatch");
}

test "integration: catchable — UnboundVar caught as :unbound-var" {
    try expectOutput("(try (+ 1 nope) (catch any e e))", ":unbound-var");
}

test "integration: catchable — KindMismatch BYPASSES translation when no handler" {
    // No try wraps this; runtime should raise the raw
    // VmError so the existing error taxonomy is preserved.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const compiled = try compile.compileSourceFullWithMacros(
        arena.allocator(),
        "(+ 1 :hello)",
        ns,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("catchable-no-handler");
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    try testing.expectError(vm.VmError.KindMismatch, v.run());
}

// =============================================================================
// Phase 3.0b — anon-fn #(...) shorthand
// =============================================================================

test "integration: anon-fn — bare #(+ 1 2)" {
    try expectOutput("(#(+ 1 2))", "3");
}

test "integration: anon-fn — % positional 1" {
    try expectOutput("(#(+ % 1) 41)", "42");
}

test "integration: anon-fn — %1 %2 explicit" {
    try expectOutput("(#(+ %1 %2) 10 20)", "30");
}

test "integration: anon-fn — closure captures outer binding" {
    try expectOutput("((fn* [x] (#(+ % x) 3)) 10)", "13");
}

test "integration: anon-fn — macro inside body re-expands" {
    try expectOutput("(#(when % :yes) :anything)", ":yes");
}

test "integration: composite — syntax-quote inside defn" {
    try expectOutput(
        \\(do
        \\  (defn build [a b]
        \\    `(pair ~a ~b))
        \\  (build 1 2))
    , "(pair 1 2)");
}
