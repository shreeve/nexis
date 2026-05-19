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
const string_mod = @import("string");
const format_mod = @import("format");

const testing = std.testing;

/// Format a runtime Value via the canonical `src/format.zig`
/// formatter in display mode. Phase 5.2c (peer-AI turn 81)
/// pulled this from the prior per-kind duplicate (and the
/// matching helpers in `cli.zig` and `stdlib.zig`) into one
/// source of truth so test expectations match REPL output
/// byte-for-byte.
fn formatValue(buf: *std.array_list.Managed(u8), v: value_mod.Value, interner: *const intern_mod.Interner) anyerror!void {
    var w = std.Io.Writer.Allocating.init(buf.allocator);
    defer w.deinit();
    try format_mod.format(v, .display, &w.writer, interner);
    try buf.appendSlice(w.written());
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

/// Phase 3.4: multi-form test helper that processes top-level
/// forms sequentially (matching runFile semantics). Use this
/// when `(ns NAME)` switching needs to affect subsequent
/// forms within the same test. The final form's value is the
/// "result".
fn expectOutputProgram(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    // Phase 5.2c (peer-AI turn 81 §D6): integration tests leave
    // `v.io` null, so 5.2c I/O fns (`slurp`/`spit`/`print`/
    // `println`/`prn`) surface `:io-error` cleanly. Their format
    // output is fully covered by `src/format.zig`'s 8 inline
    // tests; integration tests check only the error path + the
    // language-level surface (return values, taxonomy). A
    // future smoke test in `examples/` exercises real I/O.
    const interner = v.ensureInterner();
    const registry = try v.ensureRegistry();
    try stdlib.installCore(registry.core);
    // Phase 5 Item 1: mirror the CLI's environment so qualified
    // `db/...` calls (the Phase 4 surface, and the backward-
    // compat `db/deref` alias for `@x` on atoms) resolve.
    const db_ns_program = try registry.getOrCreate("db", registry.core);
    try stdlib.installDb(db_ns_program);
    // Phase 5.2b: nexis.string namespace (qualified-only).
    const string_ns_program = try registry.getOrCreate("nexis.string", registry.core);
    try stdlib.installString(string_ns_program);
    // Phase 5.3a: nexis.internal (qualified-only macro scaffolding).
    const internal_ns_program = try registry.getOrCreate("nexis.internal", registry.core);
    try stdlib.installInternal(internal_ns_program);
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const saved_current = registry.current;
    registry.current = registry.core;
    try bootstrapCoreForTest(&v, registry.core, interner, &host_macros);
    registry.current = saved_current;

    // Parse + read program (multiple top-level forms).
    var parse_result = try reader_mod.parser.parseProgram(testing.allocator, src);
    defer parse_result.parser.deinit();
    var rdr = reader_mod.Reader.init(testing.allocator, src);
    defer rdr.deinit();
    const forms = try rdr.readProgram(parse_result.sexp);

    var last_result: value_mod.Value = value_mod.nilValue();
    for (forms) |form| {
        // Re-read current per form so (ns NAME) takes effect.
        const current_ns = registry.current;
        const compiled = try compile.compileFormFullWithMacrosSpanPersistentRegistry(
            arena.allocator(),
            form,
            current_ns,
            interner,
            &host_macros,
            null,
            v.runtime_arena.allocator(),
            registry,
        );
        const routine = compiled.toRoutine("test-form");
        v.frames.items[0].routine = &routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = routine.slot_count;
        v.halted = false;
        if (v.stack.items.len < routine.slot_count) {
            try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
        }
        last_result = try v.run();
    }

    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, last_result, interner);
    testing.expectEqualStrings(expected, buf.items) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, buf.items });
        return err;
    };
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
    // Phase 5.2c (peer-AI turn 81 §D6): tests leave `v.io` null;
    // see `expectOutputProgram` for the rationale.
    const interner = v.ensureInterner();
    // Phase 3.4: set up the namespace registry so tests can
    // exercise `(ns NAME)` + qualified symbol resolution.
    const registry = try v.ensureRegistry();
    // Phase 3.3a: install core native fns into nexis.core (auto-
    // referred by user via parent).
    try stdlib.installCore(registry.core);
    // Phase 5 Item 1: install db namespace so qualified `db/...`
    // calls and the `db/deref` alias resolve in tests.
    const db_ns_single = try registry.getOrCreate("db", registry.core);
    try stdlib.installDb(db_ns_single);
    // Phase 5.2b: nexis.string namespace (qualified-only).
    const string_ns_single = try registry.getOrCreate("nexis.string", registry.core);
    try stdlib.installString(string_ns_single);
    // Phase 5.3a: nexis.internal (qualified-only macro scaffolding).
    const internal_ns_single = try registry.getOrCreate("nexis.internal", registry.core);
    try stdlib.installInternal(internal_ns_single);
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    // Phase 3.3d: bootstrap composite core.nx layer into core.
    const saved_current = registry.current;
    registry.current = registry.core;
    try bootstrapCoreForTest(&v, registry.core, interner, &host_macros);
    registry.current = saved_current;

    // Phase 3.4: each test compiles in the CURRENT namespace
    // (initially user). `(ns NAME)` in src can switch mid-test.
    const current_ns = registry.current;
    const compiled = try compile.compileSourceFullWithMacrosSpanPersistentRegistry(
        arena.allocator(),
        src,
        current_ns,
        interner,
        &host_macros,
        null,
        v.runtime_arena.allocator(),
        registry,
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
// Phase 3.5b — multi-arity defn
// =============================================================================

test "integration: 3.5b — multi-arity dispatch by argc" {
    try expectOutput(
        \\(do (defn f ([x] :one) ([x y] :two) ([x y z] :three))
        \\    (f :a))
    , ":one");
    try expectOutput(
        \\(do (defn f ([x] :one) ([x y] :two) ([x y z] :three))
        \\    (f :a :b))
    , ":two");
    try expectOutput(
        \\(do (defn f ([x] :one) ([x y] :two) ([x y z] :three))
        \\    (f :a :b :c))
    , ":three");
}

test "integration: 3.5b — multi-arity arity-mismatch is catchable" {
    try expectOutput(
        \\(do (defn f ([x] :one) ([x y] :two))
        \\    (try (f 1 2 3) (catch any e e)))
    , ":arity-mismatch");
}

test "integration: 3.5b — multi-arity with variadic overload" {
    try expectOutput(
        \\(do (defn f ([x] x) ([x & rest] (+ x (reduce + 0 rest))))
        \\    (f 100))
    , "100");
    try expectOutput(
        \\(do (defn f ([x] x) ([x & rest] (+ x (reduce + 0 rest))))
        \\    (f 1 2 3 4 5))
    , "15");
}

test "integration: 3.5b — multi-arity with destructured params" {
    try expectOutput(
        \\(do (defn f ([[a b]] (+ a b)) ([x y] (* x y)))
        \\    (f [10 20]))
    , "30");
    try expectOutput(
        \\(do (defn f ([[a b]] (+ a b)) ([x y] (* x y)))
        \\    (f 3 4))
    , "12");
}

// =============================================================================
// Phase 3.5a — destructuring (let / fn / defn params)
// =============================================================================

test "integration: 3.5a — sequential destructuring (let)" {
    try expectOutput("(let [[a b c] [10 20 30]] (+ a b c))", "60");
    try expectOutput("(let [[a b] [1 2 3]] (+ a b))", "3");
    try expectOutput("(let [[a b c] [1 2]] (nil? c))", "true");
}

test "integration: 3.5a — sequential with rest" {
    try expectOutput("(let [[a & rest] [1 2 3 4]] rest)", "(2 3 4)");
    try expectOutput("(let [[a b & rest] [1 2 3 4 5]] rest)", "(3 4 5)");
    try expectOutput("(let [[a & rest] [1]] rest)", "()");
}

test "integration: 3.5a — sequential with :as" {
    try expectOutput("(let [[a b :as v] [10 20]] (+ a b (count v)))", "32");
}

test "integration: 3.5a — nested sequential destructuring" {
    try expectOutput("(let [[a [b c] d] [1 [2 3] 4]] (+ a b c d))", "10");
}

test "integration: 3.5a — associative destructuring (:keys)" {
    try expectOutput("(let [{:keys [x y]} {:x 1 :y 2}] (+ x y))", "3");
}

test "integration: 3.5a — associative with explicit keys" {
    try expectOutput("(let [{a :alpha b :beta} {:alpha 10 :beta 20}] (+ a b))", "30");
}

test "integration: 3.5a — associative with :or defaults" {
    try expectOutput("(let [{:keys [x y] :or {y 99}} {:x 5}] (+ x y))", "104");
    // :or default applies only when key is missing.
    try expectOutput("(let [{:keys [y] :or {y 99}} {:y 7}] y)", "7");
}

test "integration: 3.5a — associative with :as" {
    try expectOutput("(let [{:keys [a] :as m} {:a 1 :b 2}] (count m))", "2");
}

test "integration: 3.5a — fn with destructured params" {
    try expectOutput(
        \\(do (defn point-sum [[x y]] (+ x y))
        \\    (point-sum [3 4]))
    , "7");
    try expectOutput(
        \\(do (defn sum-keys [{:keys [a b]}] (+ a b))
        \\    (sum-keys {:a 10 :b 20}))
    , "30");
}

test "integration: 3.5a — defn with destructured params + rest" {
    try expectOutput(
        \\(do (defn first-of [[a & _]] a)
        \\    (first-of [99 1 2 3]))
    , "99");
}

test "integration: 3.5a — let preserves single-evaluation of source" {
    // The source expression should be evaluated once and bound to
    // a gensym; destructuring reads from that gensym. Side-effect
    // semantics matter for `(let [[a b] (some-effecting-call) ...])`.
    // Easiest proof: a fn that counts invocations isn't possible
    // without atoms, but we can verify structural correctness:
    // a complex expression's value matches what plain (let [tmp e] e)
    // would yield.
    try expectOutput("(let [[a b] [(+ 1 2) (* 3 4)]] (+ a b))", "15");
}

// =============================================================================
// Phase 3.4 — multi-namespace (auto-refer core + qualified symbols + (ns NAME))
// =============================================================================

test "integration: 3.4 — auto-refer nexis.core from user" {
    try expectOutput("(map inc [1 2 3])", "(2 3 4)");
    try expectOutput("(reduce + 0 (range 5))", "10");
}

test "integration: 3.4 — qualified core symbol" {
    try expectOutput("(nexis.core/+ 1 2 3)", "6");
    try expectOutput("(nexis.core/* 2 3 4)", "24");
    try expectOutput("(nexis.core/inc 41)", "42");
}

test "integration: 3.4 — (ns NAME) switches current namespace" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(def x 100)
        \\(ns user)
        \\my.app/x
    , "100");
}

test "integration: 3.4 — defn in a namespace + qualified call" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(defn double [n] (* n 2))
        \\(ns user)
        \\(my.app/double 21)
    , "42");
}

test "integration: 3.4 — qualified symbol resolves via registry not lexical" {
    // Qualified `my.app/x` is parsed as a single symbol with
    // `ns="my.app"`. Lexical `let` binding form `[my.app/x 99]`
    // is rejected at expand-time (let* binding names must be
    // unqualified). This test just verifies a let with an
    // UNQUALIFIED name doesn't shadow a same-name qualified
    // symbol elsewhere.
    try expectOutputProgram(
        \\(ns my.app)
        \\(def x 100)
        \\(ns user)
        \\(let [x 99] my.app/x)
    , "100");
}

test "integration: 3.4 — defs in different namespaces don't collide" {
    try expectOutputProgram(
        \\(ns a) (def x 1)
        \\(ns b) (def x 2)
        \\(ns user)
        \\(+ a/x b/x)
    , "3");
}

test "integration: 3.4 — unqualified def shadows core in current ns" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(def map :i-am-not-a-function)
        \\map
    , ":i-am-not-a-function");
}

test "integration: 3.4 — missing qualified ns is UnresolvedSymbol" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    defer v.deinit();
    const interner = v.ensureInterner();
    const registry = try v.ensureRegistry();
    try stdlib.installCore(registry.core);
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    try testing.expectError(
        compile.CompileError.UnresolvedSymbol,
        compile.compileSourceFullWithMacrosSpanPersistentRegistry(
            arena.allocator(),
            "missing.ns/foo",
            registry.current,
            interner,
            &host_macros,
            null,
            v.runtime_arena.allocator(),
            registry,
        ),
    );
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

// =============================================================================
// Phase 5 Item 1 — atoms (peer-AI turn 75; docs/ATOM.md)
// =============================================================================
//
// Coverage map (every spec invariant in ATOM.md should have at
// least one row here):
//   §3 identity equality + identity hash         → atom-eq tests
//   §4.1 `(atom init)`                           → ctor + deref
//   §4.2 `(atom? x)`                             → predicate tests
//   §4.3 `(reset! a v)` returns v                → reset tests
//   §4.4 `(swap! a f & args)` + rollback         → swap tests
//   §4.5 `(swap-vals! a f & args)`               → swap-vals test
//   §4.6 `(compare-and-set! a old new)`          → CAS tests
//   §5 universal `deref` / `@a` / `db/deref`     → deref tests
//   §6 codec :unserializable (atom + nested)     → wire later via DB
//   §9 catchable errors                          → error keyword tests

test "phase5 atom: ctor + atom? predicate" {
    try expectOutput("(atom? (atom 0))", "true");
    try expectOutput("(atom? (atom :anything))", "true");
    try expectOutput("(atom? 1)", "false");
    try expectOutput("(atom? :keyword)", "false");
    try expectOutput("(atom? nil)", "false");
    try expectOutput("(atom? [1 2])", "false");
}

test "phase5 atom: deref via @a, (deref a), (db/deref a)" {
    try expectOutput("@(atom 42)", "42");
    try expectOutput("(deref (atom 42))", "42");
    try expectOutput("(db/deref (atom 42))", "42");
    try expectOutput("@(atom :keyword)", ":keyword");
    try expectOutput("@(atom nil)", "nil");
    try expectOutput("@(atom [1 2 3])", "[1 2 3]");
}

test "phase5 atom: identity equality (= a a) vs (= (atom v) (atom v))" {
    // Same atom compares equal to itself.
    try expectOutput("(let [a (atom 1)] (= a a))", "true");
    // Two distinct atoms holding equal values are NOT equal.
    try expectOutput("(= (atom 1) (atom 1))", "false");
    try expectOutput("(= (atom :x) (atom :x))", "false");
    // Equality survives a mutation: same atom always equals
    // itself, even after its contained value changes.
    try expectOutput(
        \\(let [a (atom 1)]
        \\  (reset! a 999)
        \\  (= a a))
    , "true");
}

test "phase5 atom: reset! sets value, returns new value" {
    try expectOutput("(let [a (atom 0)] (reset! a 42))", "42");
    try expectOutput("(let [a (atom 0)] (reset! a 42) @a)", "42");
    try expectOutput("(let [a (atom :before)] (reset! a :after) @a)", ":after");
}

test "phase5 atom: swap! with inc / + / variadic args" {
    try expectOutput("(let [a (atom 0)] (swap! a inc))", "1");
    try expectOutput("(let [a (atom 0)] (swap! a inc) (swap! a inc) @a)", "2");
    try expectOutput("(let [a (atom 10)] (swap! a + 32))", "42");
    try expectOutput("(let [a (atom 10)] (swap! a + 1 2 3 4))", "20");
}

test "phase5 atom: swap! rollback on throw — value unchanged" {
    try expectOutput(
        \\(let [a (atom 11)]
        \\  (try (swap! a (fn [_] (throw :bad))) (catch any e e))
        \\  @a)
    , "11");
    // The thrown value propagates as the catch's bound value
    // (rollback is observable through @a above, NOT through the
    // catch shape itself).
    try expectOutput(
        \\(let [a (atom 0)]
        \\  (try (swap! a (fn [_] (throw :nope))) (catch any e e)))
    , ":nope");
}

test "phase5 atom: swap! re-entrancy detection (:atom-re-entry)" {
    try expectOutput(
        \\(let [a (atom 0)]
        \\  (try (swap! a (fn [_] (reset! a 999))) (catch any e e)))
    , ":atom-re-entry");
    // After the failed re-entrant attempt, the outer swap! also
    // failed to write — atom remains at the original value.
    try expectOutput(
        \\(let [a (atom 0)]
        \\  (try (swap! a (fn [_] (reset! a 999))) (catch any e e))
        \\  @a)
    , "0");
    // CAS-from-inside-swap! also trips re-entry.
    try expectOutput(
        \\(let [a (atom 0)]
        \\  (try (swap! a (fn [_] (compare-and-set! a 0 999))) (catch any e e)))
    , ":atom-re-entry");
}

test "phase5 atom: swap! deref of in-flight atom is allowed" {
    // deref does NOT touch in_flight, so a swap! function may
    // legally call @a (e.g., to inspect the staging value).
    // This is the canonical "side-effecting log inside swap!"
    // pattern.
    try expectOutput(
        \\(let [a (atom 7)]
        \\  (swap! a (fn [old] (+ old @a))))
    , "14");
}

test "phase5 atom: swap-vals! returns [old new] vector" {
    try expectOutput("(let [a (atom 10)] (swap-vals! a inc))", "[10 11]");
    try expectOutput("(let [a (atom 10)] (swap-vals! a inc) @a)", "11");
    try expectOutput(
        \\(let [a (atom 1)] (swap-vals! a + 2 3 4))
    , "[1 10]");
}

test "phase5 atom: swap-vals! rollback on throw" {
    try expectOutput(
        \\(let [a (atom 1)]
        \\  (try (swap-vals! a (fn [_] (throw :bad))) (catch any e :caught))
        \\  @a)
    , "1");
}

test "phase5 atom: compare-and-set! identity-based" {
    try expectOutput(
        \\(let [a (atom 11)] (compare-and-set! a 11 100))
    , "true");
    try expectOutput(
        \\(let [a (atom 11)] (compare-and-set! a 11 100) @a)
    , "100");
    try expectOutput(
        \\(let [a (atom 11)] (compare-and-set! a 99 100))
    , "false");
    try expectOutput(
        \\(let [a (atom 11)] (compare-and-set! a 99 100) @a)
    , "11");
}

test "phase5 atom: compare-and-set! uses identity, not =" {
    // Two distinct vectors are structurally equal but NOT
    // pointer-identical. CAS must reject the swap.
    try expectOutput(
        \\(let [a (atom [1 2])] (compare-and-set! a [1 2] :new))
    , "false");
    try expectOutput(
        \\(let [a (atom [1 2])] (compare-and-set! a [1 2] :new) @a)
    , "[1 2]");
    // But CAS with the SAME atom-stored value (identity match)
    // succeeds.
    try expectOutput(
        \\(let [v [1 2] a (atom v)]
        \\  (compare-and-set! a v :new))
    , "true");
}

test "phase5 atom: reset!/swap!/CAS type errors caught as :kind-mismatch" {
    try expectOutput("(try (reset! 1 2) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (swap! 1 inc) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (compare-and-set! 1 1 2) (catch any e e))", ":kind-mismatch");
}

test "phase5 atom: swap! with non-callable f surfaces :not-callable" {
    try expectOutput(
        \\(try (swap! (atom 1) 2) (catch any e e))
    , ":not-callable");
}

test "phase5 atom: atoms as map keys distinguish by identity" {
    // Same atom used twice as a key resolves to its single
    // entry's value. Identity-based; lookup with the same atom
    // succeeds.
    try expectOutput(
        \\(let [a (atom 1) m {a :one}] (get m a))
    , ":one");
    // Distinct atoms holding `=` values do NOT collide in a map.
    // Distinguish via a let-bound copy of one atom — the *other*
    // atom (distinct allocation) does not see :one.
    try expectOutput(
        \\(let [a (atom 1) b (atom 1) m {a :one}] (get m b))
    , "nil");
}

test "phase5 atom: universal deref still serves Vars" {
    // deref over Var: still works after the .atom arm was added
    // (regression guard for peer-AI turn 73's behavior).
    try expectOutput("(do (def x 5) (deref (var x)))", "5");
}

test "phase5 atom: @-lowering is not lexically shadowable" {
    // Peer-AI turn 76 §"Must-fix": reader-macro `@` must NOT be
    // captured by a local binding named `deref`. `@x` lowers to
    // QUALIFIED `(nexis.core/deref x)` which resolves through the
    // registry, not through lexical fall-through. Confirms the
    // turn-76 fix.
    try expectOutput(
        \\(let [deref (fn [_] 42)
        \\      a    (atom 5)]
        \\  @a)
    , "5");
    // Note: `(def deref ...)` at top level does NOT prove a
    // separate shadowing case because Phase 3.4 auto-refer makes
    // `def` of an auto-referred name UPDATE the shared
    // `nexis.core/deref` Var in place (compile.zig addVarRef walks
    // the parent chain). That's a pre-existing language behavior,
    // not specific to atoms or `@`. The lexical-binding case above
    // is the load-bearing one for the turn-76 fix.
}

test "phase5 atom: self-reference does not break equality / count" {
    // An atom holding itself satisfies (= @a a). Pins the
    // GC self-reference safety + cycle behavior at the
    // language level.
    try expectOutput(
        \\(let [a (atom nil)] (reset! a a) (= @a a))
    , "true");
}

// =============================================================================
// Phase 5 Item 2 sub-step 5.2a — core string ops (peer-AI turn 77)
// =============================================================================
//
// User-facing string ops index by Unicode SCALAR (codepoint), not
// byte. Test coverage hits the four corners turn 77 §Tests:
//   - ASCII baseline                  → count/nth/subs on ASCII
//   - Multi-byte codepoint sanity     → count of "é", "🦀", mixed
//   - Bounds                          → :index-out-of-bounds keyword
//   - str shape                       → Clojure-canonical for nil/kw/sym/atom

test "phase5.2a string?: kind predicate" {
    try expectOutput("(string? \"hi\")", "true");
    try expectOutput("(string? \"\")", "true");
    try expectOutput("(string? :hello)", "false");
    try expectOutput("(string? 1)", "false");
    try expectOutput("(string? nil)", "false");
    try expectOutput("(string? [\"a\"])", "false");
}

test "phase5.2a count: ASCII + multibyte codepoints" {
    try expectOutput("(count \"\")", "0");
    try expectOutput("(count \"a\")", "1");
    try expectOutput("(count \"hello\")", "5");
    // U+00E9 é is 2 bytes UTF-8 → 1 codepoint.
    try expectOutput("(count \"é\")", "1");
    // U+1F980 🦀 is 4 bytes → 1 codepoint.
    try expectOutput("(count \"🦀\")", "1");
    // Mixed: a(1) + é(2) + b(1) + 🦀(4) bytes = 4 codepoints.
    try expectOutput("(count \"aéb🦀\")", "4");
}

test "phase5.2a empty?: byteLen == 0 fast path" {
    try expectOutput("(empty? \"\")", "true");
    try expectOutput("(empty? \"x\")", "false");
    try expectOutput("(empty? \"🦀\")", "false");
}

test "phase5.2a nth on string: returns Kind.char at codepoint index" {
    try expectOutput("(nth \"abc\" 0)", "a");
    try expectOutput("(nth \"abc\" 1)", "b");
    try expectOutput("(nth \"abc\" 2)", "c");
    // Multibyte: index 1 in "aéb" is é (U+00E9).
    try expectOutput("(nth \"aéb\" 0)", "a");
    try expectOutput("(nth \"aéb\" 1)", "é");
    try expectOutput("(nth \"aéb\" 2)", "b");
    // 4-byte codepoint at index 1.
    try expectOutput("(nth \"a🦀b\" 1)", "🦀");
}

test "phase5.2a nth on string: out-of-bounds + default" {
    try expectOutput("(try (nth \"ab\" 2) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (nth \"\" 0) (catch any e e))", ":index-out-of-bounds");
    // Negative index: same keyword (peer-AI turn 77 §D2).
    try expectOutput("(try (nth \"ab\" -1) (catch any e e))", ":index-out-of-bounds");
    // Default branch: out-of-bounds returns default instead of throwing.
    try expectOutput("(nth \"ab\" 5 :missing)", ":missing");
    try expectOutput("(nth \"ab\" -1 :neg)", ":neg");
}

test "phase5.2a subs: codepoint indices, two- and three-arity" {
    try expectOutput("(subs \"hello\" 1)", "ello");
    try expectOutput("(subs \"hello\" 0)", "hello");
    try expectOutput("(subs \"hello\" 1 4)", "ell");
    try expectOutput("(subs \"hello\" 0 0)", "");
    try expectOutput("(subs \"hello\" 5)", "");
    try expectOutput("(subs \"hello\" 5 5)", "");
    // Multibyte: code-points 1..3 of "aéb🦀" = "éb".
    try expectOutput("(subs \"aéb🦀\" 1 3)", "éb");
    // Trailing 4-byte codepoint preserved.
    try expectOutput("(subs \"aéb🦀\" 3)", "🦀");
}

test "phase5.2a subs: bounds errors as :index-out-of-bounds" {
    try expectOutput("(try (subs \"ab\" -1) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (subs \"ab\" 0 -1) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (subs \"ab\" 3) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (subs \"ab\" 0 3) (catch any e e))", ":index-out-of-bounds");
    // start > end.
    try expectOutput("(try (subs \"abc\" 2 1) (catch any e e))", ":index-out-of-bounds");
}

test "phase5.2a subs: kind-mismatch on non-string / non-fixnum index" {
    try expectOutput("(try (subs 42 0) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (subs \"ab\" :nope) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (subs \"ab\" 0 :nope) (catch any e e))", ":kind-mismatch");
}

test "phase5.2a str: Clojure-canonical concat shape" {
    try expectOutput("(str)", "");
    try expectOutput("(str nil)", "");
    try expectOutput("(str \"a\" \"b\" \"c\")", "abc");
    try expectOutput("(str \"a\" 1 :b)", "a1:b");
    try expectOutput("(str :hello)", ":hello");
    try expectOutput("(str true)", "true");
    try expectOutput("(str false)", "false");
    try expectOutput("(str -7)", "-7");
    // Char concatenates as its UTF-8 bytes (matches display mode).
    try expectOutput("(str (nth \"é\" 0))", "é");
    // Atom prints opaquely as `#<atom>` (turn 77 §D4 deterministic).
    try expectOutput("(str (atom 1))", "#<atom>");
}

test "phase5.2a str: result is itself a string" {
    try expectOutput("(string? (str \"a\" 1 :b))", "true");
    try expectOutput("(count (str \"héllo\"))", "5");
}

test "phase5.2a string? after subs returns true" {
    try expectOutput("(string? (subs \"hello\" 1 4))", "true");
}

test "phase5.2a nth: kind-mismatch fires on non-indexable receiver (peer-AI turn 78)" {
    // Pre-5.2a bug: the negative-index + default path returned
    // the default even when the receiver was non-indexable. The
    // turn-78 fix moves the kind check ABOVE the index-sign
    // branch. `(nth 123 -1 :d)` must be `:kind-mismatch`, NOT
    // `:d`.
    try expectOutput("(try (nth 123 -1 :d) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nth :keyword 0 :d) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nth {:a 1} 0 :d) (catch any e e))", ":kind-mismatch");
    // Strings + vectors + lists + nil still honor the default-
    // on-OOB contract from Phase 3.5.
    try expectOutput("(nth \"ab\" -1 :d)", ":d");
    try expectOutput("(nth nil 0 :d)", ":d");
    try expectOutput("(nth [1 2] 5 :d)", ":d");
}

test "phase5.2a subs: boundary case (start == end at count)" {
    // Peer-AI turn 78 §R4: `(subs s n n)` for any `n` in
    // `[0, count]` returns `""`. The end-at-end boundary should
    // succeed, not throw.
    try expectOutput("(subs \"abc\" 3 3)", "");
    try expectOutput("(count (subs \"abc\" 3 3))", "0");
}

test "phase5.2a nth: char-at-default on out-of-bounds + multibyte" {
    // Peer-AI turn 78 §R5: `(nth s i :default)` returns default
    // when `i >= codepointCount`. Multi-byte boundary.
    try expectOutput("(nth \"é\" 0 :default)", "é");
    try expectOutput("(nth \"é\" 1 :default)", ":default");
}

test "phase5.2a end-to-end DB persistence of a string value (peer-AI turn 78 §R9)" {
    // Direct test that string literals survive the entire
    // compile → durable codec → emdb → decode → user path. The
    // todo-app demo uses keyword values; this test pins the
    // string Value codec round-trip explicitly. The /tmp file
    // is overwritten by the with-tx put on every run, so no
    // explicit cleanup is needed (and Zig 0.16's std.Io.Dir
    // file ops would add unnecessary boilerplate here).
    try expectOutputProgram(
        \\(do
        \\  (def conn (db/open "/tmp/nexis-phase5-2a-strings.edb"))
        \\  (def r   (db/ref conn :strings "k"))
        \\  (with-tx [tx conn] (db/put! tx r "hello-utf8-é-🦀"))
        \\  (with-read-tx [tx conn] (db/get tx r)))
    , "hello-utf8-é-🦀");
}

// =============================================================================
// Phase 5 Item 2 sub-step 5.2b — nexis.string namespace (peer-AI turn 79)
// =============================================================================
//
// Coverage map (every STRING.md §8 invariant gets at least one row):
//   §8.1 ASCII case conversion preserves non-ASCII bytes
//   §8.2 trim = six ASCII whitespace chars; both sides
//   §8.3 literal split preserves trailing empties; vector return
//   §8.4 join over nil/list/vector/set; map rejected; sep is string
//   §8.5 replace literal, all-non-overlapping, left-to-right
//
// Also pins: qualified-only (NOT auto-referred into user).

test "phase5.2b nexis.string is qualified-only (not auto-referred)" {
    // Bare `(lower-case ...)` from user namespace must NOT
    // resolve to nexis.string/lower-case. The user-friendly
    // surface for short names will be require/alias (Phase 3.6
    // already supports this) or `:refer`. Until then, qualified
    // calls are the only path.
    try expectOutput("(try (lower-case \"HI\") (catch any e e))", ":unbound-var");
    try expectOutput("(nexis.string/lower-case \"HI\")", "hi");
}

test "phase5.2b lower-case + upper-case: ASCII baseline" {
    try expectOutput("(nexis.string/lower-case \"HELLO\")", "hello");
    try expectOutput("(nexis.string/lower-case \"Hello, World!\")", "hello, world!");
    try expectOutput("(nexis.string/upper-case \"hello\")", "HELLO");
    try expectOutput("(nexis.string/upper-case \"MixedCASE\")", "MIXEDCASE");
    try expectOutput("(nexis.string/lower-case \"\")", "");
    try expectOutput("(nexis.string/upper-case \"\")", "");
}

test "phase5.2b lower-case + upper-case: non-ASCII passes through unchanged" {
    // ASCII letters map; non-ASCII bytes are preserved verbatim
    // (peer-AI turn 79 §D1). UTF-8 validity is preserved by
    // construction because bytes ≥ 0x80 are never modified.
    try expectOutput("(nexis.string/lower-case \"HéLLO\")", "héllo");
    try expectOutput("(nexis.string/upper-case \"abç\")", "ABç");
    try expectOutput("(nexis.string/lower-case \"🦀A\")", "🦀a");
    // Round-trip identity: codepoint count survives transform.
    try expectOutput("(count (nexis.string/lower-case \"HéLLO\"))", "5");
}

test "phase5.2b trim: six ASCII whitespace chars; both sides" {
    try expectOutput("(nexis.string/trim \"   hello   \")", "hello");
    try expectOutput("(nexis.string/trim \"hello\")", "hello");
    try expectOutput("(nexis.string/trim \"\")", "");
    // nexis source uses `\t` `\n` `\r` escapes inside string
    // literals (the reader decodes them per nexis.grammar §28.3).
    // The Zig source-level "\\t" produces the two bytes `\` `t`,
    // which the nexis reader then decodes into the tab byte.
    try expectOutput("(nexis.string/trim \"\\t\\nhi\\r\\n\")", "hi");
    // All-whitespace input → empty.
    try expectOutput("(nexis.string/trim \"   \\t\\n\")", "");
    // Unicode whitespace (U+00A0 NBSP) is NOT recognized in v1
    // (turn 79 §D2). Bytes 0xC2 0xA0 pass through.
    try expectOutput("(nexis.string/trim \"\u{00A0}x\u{00A0}\")", "\u{00A0}x\u{00A0}");
}

test "phase5.2b split: literal delimiter, preserves trailing empties" {
    // Turn 79 §D3 override of Clojure's regex-trim behavior.
    try expectOutput("(nexis.string/split \"a,b,c\" \",\")", "[a b c]");
    try expectOutput("(nexis.string/split \"a,b,\" \",\")", "[a b ]");
    try expectOutput("(nexis.string/split \",,\" \",\")", "[  ]");
    try expectOutput("(nexis.string/split \"\" \",\")", "[]");
    try expectOutput("(nexis.string/split \"a\" \"foo\")", "[a]");
    // Multi-char delim.
    try expectOutput("(nexis.string/split \"a::b::c\" \"::\")", "[a b c]");
    // Multi-byte content split on ASCII delim (UTF-8 safety:
    // continuation bytes never match ASCII delimiter).
    try expectOutput("(nexis.string/split \"é,🦀,b\" \",\")", "[é 🦀 b]");
}

test "phase5.2b split: empty delim and non-string args (peer-AI turn 80 §#2)" {
    // Empty delimiter is a string of the wrong VALUE (not the
    // wrong KIND), so it surfaces `:invalid-argument` per turn
    // 80's taxonomy improvement; non-string args remain
    // `:kind-mismatch`.
    try expectOutput("(try (nexis.string/split \"abc\" \"\") (catch any e e))", ":invalid-argument");
    try expectOutput("(try (nexis.string/split \"abc\" 42) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/split 1 \",\") (catch any e e))", ":kind-mismatch");
}

test "phase5.2b split: returns a vector" {
    try expectOutput("(let [parts (nexis.string/split \"a,b,c\" \",\")] (count parts))", "3");
    try expectOutput("(nth (nexis.string/split \"a,b,c\" \",\") 1)", "b");
}

test "phase5.2b join: 1-arity concatenates without separator" {
    try expectOutput("(nexis.string/join [])", "");
    try expectOutput("(nexis.string/join nil)", "");
    try expectOutput("(nexis.string/join [\"a\" \"b\" \"c\"])", "abc");
    try expectOutput("(nexis.string/join [1 2 :a])", "12:a");
    try expectOutput("(nexis.string/join (list :x :y :z))", ":x:y:z");
}

test "phase5.2b join: 2-arity inserts separator between elements" {
    try expectOutput("(nexis.string/join \",\" [])", "");
    try expectOutput("(nexis.string/join \",\" [\"a\"])", "a");
    try expectOutput("(nexis.string/join \",\" [\"a\" \"b\" \"c\"])", "a,b,c");
    try expectOutput("(nexis.string/join \" \" [1 2 3])", "1 2 3");
    try expectOutput("(nexis.string/join \"::\" [\"x\" \"y\" \"z\"])", "x::y::z");
}

test "phase5.2b join: rejects map; rejects non-string sep" {
    // Turn 79 §D4: maps excluded until CHAMP iteration order is
    // pinned; non-string sep surfaces :kind-mismatch.
    try expectOutput("(try (nexis.string/join {:a 1 :b 2}) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/join :sep [1 2]) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/join 42 [1 2]) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/join \",\" 42) (catch any e e))", ":kind-mismatch");
}

test "phase5.2b join: round-trips with split" {
    // Useful pin: (join sep (split s sep)) == s when sep is in s
    // and trailing empties are preserved (turn 79 §D3).
    try expectOutput(
        \\(let [s "x,y,z" sep ","]
        \\  (nexis.string/join sep (nexis.string/split s sep)))
    , "x,y,z");
    try expectOutput(
        \\(let [s "a,b,," sep ","]
        \\  (nexis.string/join sep (nexis.string/split s sep)))
    , "a,b,,");
}

test "phase5.2b replace: literal, all-non-overlapping" {
    try expectOutput("(nexis.string/replace \"abc\" \"b\" \"X\")", "aXc");
    try expectOutput("(nexis.string/replace \"abababab\" \"ab\" \"X\")", "XXXX");
    // Turn 79 §D5: after match, cursor jumps by match.len, so
    // `(replace "aaa" "aa" "x") → "xa"`, not `"xx"`.
    try expectOutput("(nexis.string/replace \"aaa\" \"aa\" \"x\")", "xa");
    // Turn 80 §"Additional tests" pin: consecutive non-overlapping
    // matches both fire.
    try expectOutput("(nexis.string/replace \"aaaa\" \"aa\" \"x\")", "xx");
    try expectOutput("(nexis.string/replace \"abc\" \"z\" \"x\")", "abc");
    try expectOutput("(nexis.string/replace \"\" \"x\" \"y\")", "");
    // Replacement can be longer/shorter than match.
    try expectOutput("(nexis.string/replace \"a\" \"a\" \"foo\")", "foo");
    try expectOutput("(nexis.string/replace \"foobar\" \"foo\" \"\")", "bar");
}

test "phase5.2b replace: empty match / non-string args (peer-AI turn 80 §#2)" {
    // Empty match → :invalid-argument (right kind, wrong value);
    // non-string args → :kind-mismatch.
    try expectOutput("(try (nexis.string/replace \"abc\" \"\" \"x\") (catch any e e))", ":invalid-argument");
    try expectOutput("(try (nexis.string/replace \"abc\" :nope \"x\") (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/replace \"abc\" \"b\" 42) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/replace 42 \"b\" \"x\") (catch any e e))", ":kind-mismatch");
}

test "phase5.2b replace: UTF-8 boundary safety" {
    // Valid UTF-8 in, valid UTF-8 out. `é` (0xC3 0xA9) won't be
    // matched by ASCII `c` (UTF-8 continuation bytes never equal
    // ASCII delimiter targets).
    try expectOutput("(nexis.string/replace \"aécé\" \"c\" \"X\")", "aéXé");
}

// =============================================================================
// Phase 5 Item 2 sub-step 5.2c — printing + I/O (peer-AI turn 81)
// =============================================================================
//
// Print fns (print/println/prn) return nil; the test harness
// compares the FINAL VALUE per peer-AI turn 81 §D8. Stdout
// capture isn't worth the harness surgery for v1 — the
// formatter's output shape is fully tested in src/format.zig.
//
// Slurp + spit are tested via round-trip in /tmp.

test "phase5.2c pr-str: readable string output" {
    try expectOutput("(pr-str)", "");
    try expectOutput("(pr-str nil)", "nil");
    try expectOutput("(pr-str 42)", "42");
    try expectOutput("(pr-str :hello)", ":hello");
    // Strings are QUOTED in readable mode (the test harness'
    // formatValue runs in DISPLAY mode, so the result string —
    // which contains the literal characters `"hi"` — gets printed
    // back without re-quoting).
    try expectOutput("(pr-str \"hi\")", "\"hi\"");
    // Embedded `"` + `\n` + `\` → `\" \n \\` in readable output.
    try expectOutput(
        \\(pr-str "a\"b\nc")
    , "\"a\\\"b\\nc\"");
    // Multiple args separated by single space.
    try expectOutput("(pr-str :a \"b\" 1)", ":a \"b\" 1");
    // Readable mode preserves char tokens too.
    try expectOutput("(pr-str (nth \"abc\" 1))", "\\b");
}

test "phase5.2c str vs pr-str: nil semantics (peer-AI turn 81 §F1)" {
    // `str` uses str-semantics: nil → "".
    try expectOutput("(str nil)", "");
    try expectOutput("(str nil :x nil)", ":x");
    // `pr-str` uses readable mode: nil → "nil".
    try expectOutput("(pr-str nil)", "nil");
    try expectOutput("(pr-str nil :x nil)", "nil :x nil");
}

test "phase5.2c join: nil-element semantics (turn 81 §D9 #1)" {
    // `join` uses str-semantics for each element, so nil → empty
    // (no `nil` literal emitted between separators).
    try expectOutput("(nexis.string/join [1 nil 2])", "12");
    try expectOutput("(nexis.string/join \",\" [1 nil 2])", "1,,2");
}

// =============================================================================
// Phase 5.2c I/O error paths (peer-AI turn 81 §D6)
// =============================================================================
//
// Integration tests leave `vm.io` null (the test harness has no
// std.Io context). Per turn 81 §D6 pin, that surfaces :io-error
// — pinned here so the contract is grep-able. End-to-end I/O
// is exercised via `bin/nexis run examples/...` smoke tests, not
// here.

test "phase5.2c print / println / prn / pr-str: no vm.io → :io-error" {
    try expectOutput("(try (print :a) (catch any e e))", ":io-error");
    try expectOutput("(try (println :a) (catch any e e))", ":io-error");
    try expectOutput("(try (prn :a) (catch any e e))", ":io-error");
    // pr-str does NOT touch vm.io (it returns a String); it
    // works regardless. Pin the contract.
    try expectOutput("(pr-str :a)", ":a");
}

test "phase5.2c slurp / spit: no vm.io → :io-error" {
    try expectOutput("(try (slurp \"/tmp/anything.txt\") (catch any e e))", ":io-error");
    try expectOutput("(try (spit \"/tmp/anything.txt\" \"x\") (catch any e e))", ":io-error");
}

test "phase5.2c slurp / spit: non-string path is :kind-mismatch" {
    try expectOutput("(try (slurp 42) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (spit :nope \"x\") (catch any e e))", ":kind-mismatch");
}

test "phase5.2c slurp / spit: empty path is :invalid-path" {
    try expectOutput("(try (slurp \"\") (catch any e e))", ":invalid-path");
    try expectOutput("(try (spit \"\" \"x\") (catch any e e))", ":invalid-path");
}

// =============================================================================
// Phase 5 Item 4 — case / condp macros (peer-AI turn 83)
// =============================================================================
//
// `for` ships in a follow-up commit per turn 83's split rec.
// `case` + `condp` are pure expansion + single-eval gensym
// patterns; both throw `:no-matching-clause` when no clause
// matches and no default is supplied (peer-AI turn 83 §D1/§D2
// OVERRIDE — returning nil silently masks bugs).

test "phase5.4 case: basic match + default" {
    try expectOutput("(case 1 1 :one 2 :two :default)", ":one");
    try expectOutput("(case 2 1 :one 2 :two :default)", ":two");
    try expectOutput("(case 99 1 :one 2 :two :default)", ":default");
    try expectOutput("(case 1 1 :one)", ":one");
    // Odd terminal arg = default; no clauses → default.
    try expectOutput("(case :anything :default)", ":default");
}

test "phase5.4 case: no match without default throws :no-matching-clause" {
    try expectOutput(
        \\(try (case 99 1 :one 2 :two) (catch any e e))
    , ":no-matching-clause");
    // Even count = no default; still throws.
    try expectOutput(
        \\(try (case 5 1 :one) (catch any e e))
    , ":no-matching-clause");
}

test "phase5.4 case: heterogeneous keys + nested expressions" {
    // Keywords, integers, strings all compare via `=`.
    try expectOutput(
        \\(case :hi 1 :one :hi :greet :default)
    , ":greet");
    try expectOutput(
        \\(case "x" 1 :one "x" :str-match :default)
    , ":str-match");
    // The result expr is fully evaluated (not just a literal).
    try expectOutput(
        \\(let [base 100]
        \\  (case 2 1 (+ base 1) 2 (+ base 2) :nope))
    , "102");
}

test "phase5.4 case: expression evaluated EXACTLY ONCE" {
    // Use an atom-mutating step fn to count evaluations.
    try expectOutput(
        \\(let [counter (atom 0)
        \\      step    (fn [] (swap! counter inc) @counter)]
        \\  (case (step) 1 :one :other)
        \\  @counter)
    , "1");
}

test "phase5.4 condp: predicate + default" {
    try expectOutput("(condp = 1 1 :one 2 :two :default)", ":one");
    try expectOutput("(condp = 2 1 :one 2 :two :default)", ":two");
    try expectOutput("(condp = 99 1 :one 2 :two :default)", ":default");
    // Single trailing default with no clauses.
    try expectOutput("(condp = 99 :default)", ":default");
}

test "phase5.4 condp: no match without default throws :no-matching-clause" {
    try expectOutput(
        \\(try (condp = 99 1 :one 2 :two) (catch any e e))
    , ":no-matching-clause");
}

test "phase5.4 condp: predicate is called as (pred clause expr)" {
    // `(condp < 5 ...)` invokes `(< clause 5)` per clause.
    // `(< 3 5)` is true → `:gt3`. `(< 10 5)` is false.
    try expectOutput(
        \\(condp < 5 3 :gt3 10 :gt10 :default)
    , ":gt3");
    try expectOutput(
        \\(condp < 5 10 :gt10 3 :gt3 :default)
    , ":gt3");
}

test "phase5.4 condp: pred + expr each evaluated EXACTLY ONCE" {
    try expectOutput(
        \\(let [p-count (atom 0)
        \\      e-count (atom 0)
        \\      p (fn [a b] (swap! p-count inc) (= a b))
        \\      e (fn []   (swap! e-count inc) 42)]
        \\  (condp p (e) 1 :one 42 :match :default)
        \\  [@p-count @e-count])
    , "[2 1]");
}

// ---- for -----------------------------------------------------

test "phase5.4 for: single binding maps over the source" {
    try expectOutput("(for [x [1 2 3]] (* x x))", "[1 4 9]");
    try expectOutput("(for [x []] (* x x))", "[]");
    try expectOutput("(for [x [42]] x)", "[42]");
}

test "phase5.4 for: multi-binding cartesian product" {
    // Cartesian order: outermost iterates first, innermost
    // varies fastest. (Peer-AI turn 83 §D3 verified output
    // expectation.)
    try expectOutput("(for [x [1 2] y [10 20]] (+ x y))", "[11 21 12 22]");
    try expectOutput(
        \\(for [x [:a :b] y [1 2 3]] [x y])
    , "[[:a 1] [:a 2] [:a 3] [:b 1] [:b 2] [:b 3]]");
}

test "phase5.4 for: :when filter" {
    // `<` is in core (not `>`); use `<` consistently in tests.
    try expectOutput("(for [x [1 2 3 4 5] :when (< 0 x)] x)", "[1 2 3 4 5]");
    try expectOutput("(for [x [1 2 3 4 5] :when (< 2 x)] x)", "[3 4 5]");
    try expectOutput("(for [x [1 2 3] :when (< 99 x)] x)", "[]");
}

test "phase5.4 for: :let modifier with destructuring-capable bindings" {
    // `:let` uses `let` (NOT `let*`) so destructuring works —
    // peer-AI turn 83 §\"`:let` destructuring\".
    try expectOutput("(for [x [1 2 3] :let [y (* x 10)]] y)", "[10 20 30]");
    // Compose :let + :when (order matters; let-bound name
    // visible to the when's predicate).
    try expectOutput(
        \\(for [x [1 2 3 4] :let [y (* x 10)] :when (< 15 y)] y)
    , "[20 30 40]");
    // Destructuring: bind a vector to [a b].
    try expectOutput(
        \\(for [pair [[1 :a] [2 :b]] :let [[n k] pair]] [k n])
    , "[[:a 1] [:b 2]]");
}

// Note: malformed `for` shapes (empty bindings, unknown modifier
// keyword, dangling symbol) raise MalformedMacroCall at EXPAND
// time, which surfaces as CompileError.MacroExpansionFailure —
// not catchable via runtime try/catch. The rejection is verified
// by the impl (expand.zig:expandFor); we don't add an integration
// test because the test harness panics on compile errors rather
// than surfacing them as catchable values.

// =============================================================================
// Phase 5 Item 3 sub-step 5.3a — records substrate (peer-AI turn 84)
// =============================================================================

test "phase5.3a defrecord: constructor + predicate + Counter-type-id" {
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (Counter? (->Counter 5)))
    , "true");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (Counter? 42))
    , "false");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (Counter? {:n 5}))
    , "false");
}

test "phase5.3a defrecord: structural equality (turn 84 §D1)" {
    // Two distinct constructor calls with the same field map
    // are STRUCTURALLY equal.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (= (->Counter 5) (->Counter 5)))
    , "true");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (= (->Counter 5) (->Counter 7)))
    , "false");
    // Records of DIFFERENT types with the same field map are NOT
    // equal (type_id participates in equality).
    try expectOutputProgram(
        \\(do
        \\  (defrecord A [n])
        \\  (defrecord B [n])
        \\  (= (->A 5) (->B 5)))
    , "false");
}

test "phase5.3a defrecord: map-like get / assoc / dissoc / contains?" {
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (get (->Counter 5) :n))
    , "5");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (get (->Counter 5) :nope :missing))
    , ":missing");
    // `assoc` returns a record of the SAME type with updated fields.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (let [c (->Counter 5)
        \\        c2 (assoc c :n 99)]
        \\    [(Counter? c2) (get c2 :n)]))
    , "[true 99]");
    // `dissoc` likewise preserves record type.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (let [c (->Counter 5)
        \\        c2 (dissoc c :n)]
        \\    [(Counter? c2) (get c2 :n)]))
    , "[true nil]");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (contains? (->Counter 5) :n))
    , "true");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (contains? (->Counter 5) :nope))
    , "false");
}

test "phase5.3a defrecord: extra keys allowed via map->Counter" {
    // Declared fields are constructor metadata, NOT a storage
    // restriction (turn 84 §D4). map->Counter passes its arg
    // verbatim as the field map.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (let [c (map->Counter {:n 5 :extra :hi})]
        \\    [(Counter? c) (get c :extra)]))
    , "[true :hi]");
}

test "phase5.3a defrecord: keys + vals walk the field map" {
    // Single-key map → deterministic key/value output via
    // `count` to avoid CHAMP iteration-order brittleness.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (count (keys (->Counter 5))))
    , "1");
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (count (vals (->Counter 5))))
    , "1");
}

// =============================================================================
// Phase 5 Item 3 sub-step 5.3b — protocols substrate (peer-AI turn 84)
// =============================================================================

test "phase5.3b defprotocol: registers protocol + method dispatchers" {
    // Smoke: both IFoo and bar end up bound to the right kinds.
    // (Use `str` rather than `println` because the test harness
    // has no `vm.io` and println→:io-error there.)
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (str IFoo " " bar))
    , "#<protocol id=0> #<protocol-fn proto=0 method=0>");
}

test "phase5.3b protocol dispatch with NO impl raises :no-protocol-impl" {
    // Hand-trace from PROTOCOLS.md §5: registering IFoo then
    // calling `(bar receiver y)` with no impl for receiver's
    // dispatch key must raise a catchable :no-protocol-impl
    // (NOT panic, NOT silently return nil). turn 84 §D6.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (try (bar 1 2) (catch any e e)))
    , ":no-protocol-impl");
    // Even when the receiver is a record, no impl means
    // :no-protocol-impl (different dispatch key but same
    // outcome).
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (defrecord Counter [n])
        \\  (try (bar (->Counter 5) 7) (catch any e e)))
    , ":no-protocol-impl");
}

test "phase5.3b protocol dispatch with zero args raises :arity-mismatch" {
    // `(bar)` has no receiver to dispatch on; dispatchProtocolMethod
    // raises ArityMismatch which surfaces as the catchable
    // keyword `:arity-mismatch`.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (try (bar) (catch any e e)))
    , ":arity-mismatch");
}

// =============================================================================
// Phase 5 Item 3 sub-step 5.3c — defrecord with inline protocol impls
// (peer-AI turn 84). The canonical hand-trace from PROTOCOLS.md §5.
// =============================================================================

test "phase5.3c hand-trace: (bar (->Counter 5) 7) -> 12" {
    // The canonical hand-trace from PROTOCOLS.md §5 — verifies
    // end-to-end that defprotocol + defrecord-with-impl wire up
    // protocol dispatch correctly.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo
        \\    (bar [this y]))
        \\  (defrecord Counter [n]
        \\    IFoo
        \\    (bar [this y] (+ (get this :n) y)))
        \\  (bar (->Counter 5) 7))
    , "12");
}

test "phase5.3c defrecord impls: receiver-typed dispatch" {
    // Two distinct records each with their own impl. Each
    // dispatches to its own body.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (defrecord A [n] IFoo (bar [this] (+ (get this :n) 100)))
        \\  (defrecord B [n] IFoo (bar [this] (* (get this :n) 10)))
        \\  [(bar (->A 5)) (bar (->B 5))])
    , "[105 50]");
}

test "phase5.3c defrecord impls: multiple methods" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo
        \\    (bar [this])
        \\    (baz [this y]))
        \\  (defrecord Counter [n]
        \\    IFoo
        \\    (bar [this] (get this :n))
        \\    (baz [this y] (+ (get this :n) y)))
        \\  [(bar (->Counter 5)) (baz (->Counter 5) 7)])
    , "[5 12]");
}

test "phase5.3c defrecord impls: multiple protocols on one record" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (defprotocol IBaz (baz [this]))
        \\  (defrecord Counter [n]
        \\    IFoo (bar [this] :i-am-bar)
        \\    IBaz (baz [this] :i-am-baz))
        \\  [(bar (->Counter 5)) (baz (->Counter 5))])
    , "[:i-am-bar :i-am-baz]");
}

test "phase5.3c defrecord impls: this is the literal record value" {
    // The first arg to a protocol method is the receiver itself
    // (NOT a magic this-pointer). It's just the value that gets
    // passed in — peer-AI turn 84 §D2.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (defrecord Counter [n]
        \\    IFoo
        \\    (bar [this] (Counter? this)))
        \\  (bar (->Counter 5)))
    , "true");
}

// =============================================================================
// Phase 5 Item 3 sub-step 5.3d — extend-protocol/extend-type + satisfies? +
// :any default (peer-AI turn 84).
// =============================================================================

test "phase5.3d extend-protocol: built-in kinds" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (extend-protocol IFoo
        \\    :string (bar [s y] (str s "-" y))
        \\    :fixnum (bar [n y] (* n y)))
        \\  [(bar "hi" 7) (bar 5 7)])
    , "[hi-7 35]");
}

test "phase5.3d extend-type: record and built-in mixed" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (defrecord Counter [n])
        \\  (extend-type Counter IFoo (bar [c y] (+ (get c :n) y)))
        \\  (extend-type :string IFoo (bar [s y] (str s "-" y)))
        \\  [(bar (->Counter 5) 7) (bar "hi" 7)])
    , "[12 hi-7]");
}

test "phase5.3d :any default fallback" {
    // :any catches receivers with no specific impl.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (extend-protocol IFoo
        \\    :fixnum (bar [n y] :got-fixnum)
        \\    :any (bar [x y] :got-any))
        \\  [(bar 1 2) (bar "hi" 2) (bar [] 2)])
    , "[:got-fixnum :got-any :got-any]");
}

test "phase5.3d satisfies?: identifies impl presence" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (defrecord Counter [n])
        \\  (extend-protocol IFoo
        \\    :string (bar [s] :s)
        \\    Counter (bar [c] :c))
        \\  [(satisfies? IFoo "hi")
        \\   (satisfies? IFoo (->Counter 5))
        \\   (satisfies? IFoo 5)])
    , "[true true false]");
}

test "phase5.3d satisfies? with :any default: always true" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (extend-protocol IFoo :any (bar [x] :default))
        \\  [(satisfies? IFoo "hi")
        \\   (satisfies? IFoo 5)
        \\   (satisfies? IFoo [])])
    , "[true true true]");
}

test "phase5.3d extend with :vector / :map friendly aliases" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (extend-protocol IFoo
        \\    :vector (bar [v] :v)
        \\    :map (bar [m] :m))
        \\  [(bar []) (bar {})])
    , "[:v :m]");
}

test "phase5.3d extend-protocol with bogus type-kw: :invalid-argument" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (try
        \\    (extend-protocol IFoo
        \\      :no-such-kind (bar [x] :nope))
        \\    (catch any e e)))
    , ":invalid-argument");
}

// =============================================================================
// Phase 5 Item 5 — broader core.nx stdlib (peer-AI turn 74 §10.5)
// =============================================================================

test "phase5.5 core.nx: constantly / complement / partial / comp" {
    try expectOutputProgram(
        \\((constantly 42))
    , "42");
    try expectOutputProgram(
        \\((complement even?) 3)
    , "true");
    try expectOutputProgram(
        \\((partial + 10) 5)
    , "15");
    try expectOutputProgram(
        \\((comp inc inc) 1)
    , "3");
    // (comp) → identity; identity itself is a native fn.
    try expectOutputProgram(
        \\((comp identity inc) 5)
    , "6");
}

test "phase5.5 core.nx: every? truthy + falsy cases" {
    try expectOutputProgram(
        \\(every? pos? [1 2 3])
    , "true");
    try expectOutputProgram(
        \\(every? pos? [1 -2 3])
    , "false");
}

test "phase5.5 core.nx: every? empty seq is vacuously true" {
    try expectOutputProgram(
        \\(every? pos? [])
    , "true");
}

test "phase5.5 core.nx: not-every?" {
    try expectOutputProgram(
        \\(not-every? pos? [1 -2 3])
    , "true");
    try expectOutputProgram(
        \\(not-every? pos? [1 2 3])
    , "false");
}

test "phase5.5 core.nx: some + not-any?" {
    try expectOutputProgram(
        \\(some even? [1 3 5])
    , "nil");
    try expectOutputProgram(
        \\(some even? [1 4 5])
    , "true");
    try expectOutputProgram(
        \\(not-any? neg? [1 2 3])
    , "true");
    try expectOutputProgram(
        \\(not-any? neg? [1 -2 3])
    , "false");
}

test "phase5.5 core.nx: merge / update / get-in / assoc-in / update-in" {
    try expectOutputProgram(
        \\(merge {:a 1} {:b 2} {:a 99})
    , "{:a 99, :b 2}");
    try expectOutputProgram(
        \\(update {:x 5} :x inc)
    , "{:x 6}");
    try expectOutputProgram(
        \\(get-in {:a {:b {:c 42}}} [:a :b :c])
    , "42");
    try expectOutputProgram(
        \\(get-in {:a {:b 1}} [:a :missing])
    , "nil");
    try expectOutputProgram(
        \\(assoc-in {:a {:b 1}} [:a :b] 99)
    , "{:a {:b 99}}");
    try expectOutputProgram(
        \\(update-in {:a {:b 1}} [:a :b] inc)
    , "{:a {:b 2}}");
}

test "phase5.5 core.nx: frequencies / group-by / interpose" {
    try expectOutputProgram(
        \\(get (frequencies [:a :b :a :c :a :b]) :a)
    , "3");
    try expectOutputProgram(
        \\(get (group-by even? [1 2 3 4 5 6]) true)
    , "[2 4 6]");
    try expectOutputProgram(
        \\(interpose :- [1 2 3])
    , "(1 :- 2 :- 3)");
    try expectOutputProgram(
        \\(interpose :- [])
    , "()");
}

test "phase5.3b defprotocol: protocol-fn passes through map-as-key" {
    // protocol_fn values are identity-valued; storing two distinct
    // calls to defprotocol-emitted protocol_fn under the same key
    // verifies hash + equality agree.
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (let [m {bar :hi}]
        \\    (get m bar)))
    , ":hi");
}

test "phase5.3a defrecord: records-as-map-keys use structural identity" {
    // Two structurally-equal records hash + compare equal so
    // they're the SAME key in a map. (Verified by storing under
    // the first record and looking up with the second.)
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (let [c1 (->Counter 5)
        \\        c2 (->Counter 5)
        \\        m  {c1 :found}]
        \\    (get m c2)))
    , ":found");
}

test "phase5.2b end-to-end: case + trim + split + join chain" {
    // Composite test pinning that the six fns interop cleanly.
    try expectOutput(
        \\(let [raw     "  HELLO,WORLD,FROM,NEXIS  "
        \\      cleaned (nexis.string/trim raw)
        \\      lower   (nexis.string/lower-case cleaned)
        \\      parts   (nexis.string/split lower ",")
        \\      joined  (nexis.string/join "/" parts)]
        \\  joined)
    , "hello/world/from/nexis");
}

