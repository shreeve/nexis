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
const macroexpand_mod = @import("macroexpand");
const list_mod = @import("list");
const vector_mod = @import("vector");

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
    var host_macros = try macroexpand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);

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
