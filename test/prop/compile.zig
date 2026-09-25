//! test/prop/compile.zig — the compiler's behaviour, source in and
//! printed value out (COMPILER.md §9), and randomized properties.
//!
//! `cases` pins what every primitive-core form, every binding and
//! capture shape, `recur` target and quoted literal evaluates to;
//! `failures` pins the compile and run errors. Each case runs on a
//! program booted as `bin/nexis` boots one (test/harness.zig), so
//! `+` and `<` resolve to `nexis.core`'s Vars and inline.
//!
//! The properties:
//!   - closure capture at nesting depth 1..10 round-trips a value
//!     (§9.4 item 3);
//!   - syntax-quote of a random shape equals `quote` of the shape
//!     with its symbols qualified (§9.4 item 4).
//!
//! Deterministic PRNG seeds so failures reproduce.

const std = @import("std");
const nx = @import("nexis");
const value_mod = nx.value;
const list_mod = nx.list;
const harness = @import("harness");

const testing = std.testing;
const Value = value_mod.Value;

// =============================================================================
// Source in, printed value out
// =============================================================================

const Case = struct { src: []const u8, out: []const u8 };

/// Each row runs as its own program: definitions do not leak.
const cases = [_]Case{
    // Literals, arithmetic and comparison.
    .{ .src = "42", .out = "42" },
    .{ .src = "-7", .out = "-7" },
    .{ .src = "nil", .out = "nil" },
    .{ .src = "[true false]", .out = "[true false]" },
    .{ .src = "(+ 1 2)", .out = "3" },
    .{ .src = "(+ -7 -5)", .out = "-12" },
    .{ .src = "(+ (+ 1 2) (+ 3 4))", .out = "10" },
    .{ .src = "(+ 140737488355327 1)", .out = "140737488355328" },
    .{ .src = "[(< 1 2) (< 2 1) (< 3 3)]", .out = "[true false false]" },
    .{ .src = "(let* [x 3] (if (< x 5) 1 0))", .out = "1" },
    .{ .src = "(let* [a 1 b 2 c 4] (< (+ a b) c))", .out = "true" },
    // if and do.
    .{ .src = "[(if true 1 2) (if false 1 2) (if nil 1 2) (if 0 1 2)]", .out = "[1 2 2 1]" },
    .{ .src = "[(if false 1) (if true 1) (if true 7) (if false 7)]", .out = "[nil 1 7 nil]" },
    .{ .src = "[(if true (+ 1 2) (+ 3 4)) (if false (+ 1 2) (+ 3 4))]", .out = "[3 7]" },
    .{ .src = "(if true (if false 1 2) 3)", .out = "2" },
    .{ .src = "(if (+ 1 2) 99 -1)", .out = "99" },
    .{ .src = "(if (< 1 2) (+ 10 20) (+ 100 200))", .out = "30" },
    .{ .src = "[(do) (do 42) (do 1 2 3)]", .out = "[nil 42 3]" },
    .{ .src = "(let* [x 4] (do 1 x))", .out = "4" },
    // let*: strict left-of-self visibility, shadowing, scope exit.
    .{ .src = "(let* [x 1] x)", .out = "1" },
    .{ .src = "(let* [x 1 y 2] (+ x y))", .out = "3" },
    .{ .src = "(let* [x 1 y x] y)", .out = "1" },
    .{ .src = "(let* [x 7] (let* [x x] x))", .out = "7" },
    .{ .src = "(let* [x 1 x 2] x)", .out = "2" },
    .{ .src = "(let* [x 1] (do (let* [x 2] x) x))", .out = "1" },
    .{ .src = "(let* [x 1] (let* [x 2 y x] y))", .out = "2" },
    .{ .src = "(let* [x 1] (let* [x 99] x))", .out = "99" },
    .{ .src = "(if true (let* [x 1] x) 2)", .out = "1" },
    .{ .src = "(let* [x (if false 1 2)] x)", .out = "2" },
    .{ .src = "(let* [] 42)", .out = "42" },
    .{ .src = "(let* [x 1] 99 88 x)", .out = "1" },
    // fn* and calls.
    .{ .src = "((fn* [] 42))", .out = "42" },
    .{ .src = "((fn* [x] (+ x 1)) 5)", .out = "6" },
    .{ .src = "((fn* [x y] (+ x y)) 3 4)", .out = "7" },
    .{ .src = "(let* [f (fn* [x] (+ x 1))] (f 5))", .out = "6" },
    .{ .src = "((fn* [x] x) ((fn* [y] (+ y 1)) 4))", .out = "5" },
    .{ .src = "(let* [f (fn* [x] (+ x 1))] (+ (f 5) (f 10)))", .out = "17" },
    .{ .src = "((fn* [x] (if true x 0)) 7)", .out = "7" },
    .{ .src = "((fn* [x y] (+ x y)) ((fn* [a] a) 1) 2)", .out = "3" },
    // Empty bodies are nil; () is the empty list.
    .{ .src = "[((fn* [])) ((fn* f [])) ((fn* [x]) 1) (let* [x 1]) (loop* [x 1])]", .out = "[nil nil nil nil nil]" },
    .{ .src = "[(letfn* [(f [])] (f)) (try (throw 1) (catch any e)) (try (catch any e 1))]", .out = "[nil nil nil]" },
    .{ .src = "[() '() (list? ())]", .out = "[() () true]" },
    // Closure capture.
    .{ .src = "(let* [x 5] ((fn* [y] x) 3))", .out = "5" },
    .{ .src = "(let* [x 5] ((fn* [y] (+ x y)) 3))", .out = "8" },
    .{ .src = "(let* [x 5 y 10] ((fn* [] (+ x y))))", .out = "15" },
    .{ .src = "(let* [x 5] (let* [f (fn* [] x)] (f)))", .out = "5" },
    .{ .src = "(let* [x 5] ((fn* [] ((fn* [] x)))))", .out = "5" },
    .{ .src = "(let* [x 5] ((fn* [] ((fn* [] ((fn* [] x)))))))", .out = "5" },
    .{ .src = "(let* [x 5] ((fn* [] x)) ((fn* [] x)))", .out = "5" },
    .{ .src = "(let* [x 10] ((fn* [y] (+ x y)) 7))", .out = "17" },
    .{ .src = "(let* [add5 (let* [x 5] (fn* [y] (+ x y)))] (add5 3))", .out = "8" },
    .{ .src = "(let* [x 5] (do ((fn* [] x)) x))", .out = "5" },
    // A capture in a branch boxes the binding on every path.
    .{ .src = "(let* [x 5] (do (if false (fn* [] x) 0) x))", .out = "5" },
    .{ .src = "(let* [x 5] (do (if false (fn* [] x) 0) ((fn* [] x))))", .out = "5" },
    .{ .src = "(let* [x 5] (do (if true (fn* [] x) 0) x))", .out = "5" },
    .{ .src = "((fn* [x] (do (if false (fn* [] x) 0) x)) 5)", .out = "5" },
    .{ .src = "(try (throw 1) (catch any e ((fn* [] e))))", .out = "1" },
    // Shadowing decides which binding a closure captures.
    .{ .src = "(let* [x 1] (let* [f (let* [x 2] (fn* [] x))] (f)))", .out = "2" },
    .{ .src = "(let* [x 1 f (fn* [] x)] (let* [x 2] (f)))", .out = "1" },
    .{ .src = "(((fn* [x] (let* [x 2] (fn* [] x))) 1))", .out = "2" },
    // Named fn* and letfn*.
    .{ .src = "((fn* foo [x] x) 5)", .out = "5" },
    .{ .src = "((fn* foo [x] (if true x (foo (+ x 1)))) 7)", .out = "7" },
    .{ .src = "((fn* foo [x] (if true (+ x 1) (foo x))) 7)", .out = "8" },
    .{ .src = "(let* [f (fn* fact [n] (if true n (fact (+ n 1))))] (f 5))", .out = "5" },
    .{ .src = "((fn* foo [x] (let* [foo 5] foo)) 0)", .out = "5" },
    .{ .src = "(let* [foo 123] (fn? ((fn* foo [] foo))))", .out = "true" },
    .{ .src = "((fn* foo [foo] foo) 7)", .out = "7" },
    .{ .src = "((fn* foo [n] (if (< n 3) (recur (+ n 1)) n)) 0)", .out = "3" },
    .{ .src = "((fn* f [n] (if (< n 1) 0 (+ 1 (f (+ n -1))))) 10)", .out = "10" },
    .{ .src = "(letfn* [(f [x] (+ x 1))] (f 10))", .out = "11" },
    .{ .src = "(letfn* [(f [] (g)) (g [] 42)] (f))", .out = "42" },
    .{ .src = "(letfn* [(f [n] (if true n (g n))) (g [n] (if true (+ n 10) (f n)))] (g 5))", .out = "15" },
    .{ .src = "(letfn* [(ev? [n] (if (< n 1) true (od? (+ n -1)))) (od? [n] (if (< n 1) false (ev? (+ n -1))))] [(ev? 10) (od? 7)])", .out = "[true true]" },
    .{ .src = "(let* [x 10] (letfn* [(f [] (+ x (g))) (g [] 5)] (f)))", .out = "15" },
    .{ .src = "(letfn* [(a [] (b)) (b [] (c)) (c [] 7)] (a))", .out = "7" },
    .{ .src = "(let* [f 10] (letfn* [(f [] 5)] (f)))", .out = "5" },
    .{ .src = "(let* [x 100] (letfn* [(f [] x)] (f)))", .out = "100" },
    .{ .src = "(letfn* [(f [] 99) (g [] 0)] (f))", .out = "99" },
    .{ .src = "(let* [x 1] (do (letfn* [(x [] 99)] (x)) x))", .out = "1" },
    .{ .src = "[(letfn* [(f [a & r] a)] (f 1 2)) (letfn* [(f [& r] 7)] (f)) (letfn* [(f [& r] 7) (g [a & r] (+ a (f)))] (g 1 2 3))]", .out = "[1 7 8]" },
    // loop*/recur: tail positions, parallel assignment, nesting.
    .{ .src = "(loop* [i 7] i)", .out = "7" },
    .{ .src = "(loop* [i 0] (if (< i 1) (recur (+ i 1)) i))", .out = "1" },
    .{ .src = "(loop* [i 0 acc 0] (if (< i 10) (recur (+ i 1) (+ acc i)) acc))", .out = "45" },
    .{ .src = "(loop* [a 1 b 2] (if false (recur b a) (+ a b)))", .out = "3" },
    .{ .src = "(loop* [a 1 b 2 c 0] (if (< c 1) (recur b a (+ c 1)) [a b]))", .out = "[2 1]" },
    .{ .src = "(loop* [i 0] (do (if (< i 1) (recur (+ i 1)) i)))", .out = "1" },
    .{ .src = "(let* [x 100] (loop* [i 0] (if (< i 1) (recur (+ i x)) i)))", .out = "100" },
    .{ .src = "(loop* [i 0] (letfn* [(f [] 1)] (if (< i 1) (recur (+ i 1)) i)))", .out = "1" },
    .{ .src = "(letfn* [(f [n] (if (< n 3) (recur (+ n 1)) n))] (f 0))", .out = "3" },
    .{ .src = "(loop* [i 0] (loop* [j 0] (if (< j 1) (recur (+ j 1)) (+ i j))))", .out = "1" },
    .{ .src = "(loop* [i 0] ((fn* [j] (if (< j 1) (recur (+ j 1)) (+ i j))) 0))", .out = "1" },
    .{ .src = "((fn* [n] (if (< n 5) (recur (+ n 1)) n)) 0)", .out = "5" },
    .{ .src = "((fn* [n] (if (< n 3) (recur (+ n 1)) n)) 0)", .out = "3" },
    // A captured binding gets a fresh cell per iteration.
    .{ .src = "(loop* [i 0 f (fn* [] 999)] (if (< i 1) (recur (+ i 1) (fn* [] i)) (f)))", .out = "0" },
    .{ .src = "((fn* [i f] (if (< i 1) (recur (+ i 1) (fn* [] i)) (f))) 0 (fn* [] 999))", .out = "0" },
    .{ .src = "(loop* [i 0 acc []] (if (< i 3) (recur (+ i 1) (conj acc (fn* [] i))) (mapv (fn* [f] (f)) acc)))", .out = "[0 1 2]" },
    // Variadic fns and recur into them.
    .{ .src = "((fn* [a & r] a) 1 2 3)", .out = "1" },
    .{ .src = "((fn* [a & r] r) 1 2 3)", .out = "(2 3)" },
    .{ .src = "(seq ((fn* [a & r] r) 1))", .out = "nil" },
    .{ .src = "((fn* [& r] r) 1 2 3 4)", .out = "(1 2 3 4)" },
    .{ .src = "[(seq ((fn* [& r] r))) ((fn* [& r] 42))]", .out = "[nil 42]" },
    .{ .src = "(((fn* [a & r] (fn* [] r)) 1 2 3))", .out = "(2 3)" },
    .{ .src = "((fn* [a & r] (if (< a 1) (recur (+ a 1) 42) r)) 0 7)", .out = "42" },
    // def, var and Var resolution.
    .{ .src = "(= (def x 5) (var x))", .out = "true" },
    .{ .src = "(do (def x 5) x)", .out = "5" },
    .{ .src = "(do (def x 5) (def x 10) x)", .out = "10" },
    .{ .src = "(let* [v (def x 5)] (identical? v (def x 10)))", .out = "true" },
    .{ .src = "(= (var some-name) (var some-name))", .out = "true" },
    .{ .src = "(do (def x 100) (let* [x 5] x))", .out = "5" },
    .{ .src = "(do (def x 5) (let* [x 99] x))", .out = "99" },
    .{ .src = "(do (defn add1 [n] (+ n 1)) (add1 5))", .out = "6" },
    .{ .src = "(do (defn zero [] 0) (zero))", .out = "0" },
    .{ .src = "(do (defn id [x] x) (id 42))", .out = "42" },
    .{ .src = "(do (defn loop-down [n] (if (< n 1) n (recur (+ n -1)))) (loop-down 5))", .out = "0" },
    .{ .src = "(do (defn f [] (g)) (defn g [] 42) (f))", .out = "42" },
    .{ .src = "(do (defn f [] 1) (defn f [] 2) (f))", .out = "2" },
    .{ .src = "(do (defn first-of [a & r] a) (first-of 7 99 100))", .out = "7" },
    // The inlined core ops agree with the fns they stand for.
    .{ .src = "(let* [a 7 b 2] [(+ a b) (- a b) (* a b) (/ a b) (quot a b) (mod a b) (- a) (abs (- a)) (inc a) (dec a)])", .out = "[9 5 14 3.5 3 1 -7 7 8 6]" },
    .{ .src = "(let* [a -7 b 2] [(quot a b) (mod a b) (/ 6 b) (/ a 2.0)])", .out = "[-3 1 3 -3.5]" },
    .{ .src = "(let* [a 1 b 2] [(< a b) (<= a b) (> a b) (>= a b) (== a b) (== a 1.0) (<= b b) (>= a a)])", .out = "[true true false false false true true true]" },
    .{ .src = "(let* [big 140737488355327] [(inc big) (dec (- big)) (* big 2)])", .out = "[140737488355328 -140737488355328 281474976710654]" },
    .{ .src = "(let* [x 1.5] [(+ x 1) (* x 2) (< x 2) (inc x)])", .out = "[2.5 3.0 true 2.5]" },
    .{ .src = "(try (inc :a) (catch any e :caught))", .out = ":caught" },
    // Lexical names shadow the inlined operators; special forms stay.
    .{ .src = "(let* [+ (fn* [a b] 42)] (+ 1 2))", .out = "42" },
    .{ .src = "(let* [< (fn* [a b] false)] (if (< 1 2) 1 0))", .out = "0" },
    .{ .src = "(let* [+ (+ 1 2)] +)", .out = "3" },
    .{ .src = "((fn* [+] (+ 1 2)) (fn* [a b] 42))", .out = "42" },
    .{ .src = "(letfn* [(+ [a b] 42)] (+ 1 2))", .out = "42" },
    .{ .src = "[(let* [+ 9] (nexis.core/+ 1 2)) (let* [< 9] (nexis.core/< 1 2)) ((fn* [<] (nexis.core/< 2 1)) 9)]", .out = "[3 true false]" },
    .{ .src = "(let* [if 1] (if true 2 3))", .out = "2" },
    // Quote and literal data.
    .{ .src = "[(quote 42) (quote nil) (quote true) 'true]", .out = "[42 nil true true]" },
    .{ .src = "[(quote foo) 'foo (quote :bar) ':bar :bar]", .out = "[foo foo :bar :bar :bar]" },
    .{ .src = "[(symbol? 'foo) (keyword? ':bar) (identical? 'foo 'foo)]", .out = "[true true true]" },
    .{ .src = "(if true :yes :no)", .out = ":yes" },
    .{ .src = "'db/begin-write", .out = "db/begin-write" },
    .{ .src = "[(quote (1 2 3)) (quote ()) '(1 2 3) '(foo) '(:a :b) '(1 (2 3) 4)]", .out = "[(1 2 3) () (1 2 3) (foo) (:a :b) (1 (2 3) 4)]" },
    .{ .src = "[(quote [1 2 3]) (quote []) '(a [1 2] b)]", .out = "[[1 2 3] [] (a [1 2] b)]" },
    .{ .src = "[(quote {}) (quote {:a 1 :b 2}) (quote {:outer {:inner 1}})]", .out = "[{} {:a 1, :b 2} {:outer {:inner 1}}]" },
    .{ .src = "[(quote #{}) (count (quote #{1 2 3}))]", .out = "[#{} 3]" },
    .{ .src = "'(a 'b)", .out = "(a (quote b))" },
    .{ .src = "(let* [k :a k2 :a] {k 1 k2 2})", .out = "{:a 2}" },
    .{ .src = "(let* [a 1 b 1] (count #{a b 2}))", .out = "2" },
    .{ .src = "(let* [n 42] {:answer n})", .out = "{:answer 42}" },
    // Syntax-quote.
    .{ .src = "[`(1 2 3) `() `:bar]", .out = "[(1 2 3) () :bar]" },
    .{ .src = "`foo", .out = "user/foo" },
    .{ .src = "(let* [x 42] `(value ~x))", .out = "(user/value 42)" },
    .{ .src = "(let* [xs (quote (1 2 3))] `(start ~@xs end))", .out = "(user/start 1 2 3 user/end)" },
    .{ .src = "(let* [x 10 y 20] `[~x ~y])", .out = "[10 20]" },
    .{ .src = "(let* [l `(g# g#)] (= (first l) (second l)))", .out = "true" },
    .{ .src = "(let* [l `(~`g# ~`g#)] (= (first l) (second l)))", .out = "false" },
    // Host macros the compiler relies on.
    .{ .src = "[(let [x 1 y 2] (+ x y)) ((fn [x] (+ x 1)) 41) (loop [i 0 acc 0] (if (< i 5) (recur (+ i 1) (+ acc i)) acc))]", .out = "[3 42 10]" },
    .{ .src = "[(when true 42) (when false 42) (when true 1 2 3) (when-not false 99) (when-not true 99)]", .out = "[42 nil 3 99 nil]" },
    .{ .src = "[(and) (and 42) (and 1 2 3) (and 1 false 3) (and nil 99) (and false 99) (and 0 1)]", .out = "[true 42 3 false nil false 1]" },
    .{ .src = "[(or 0 7) (or false nil) (or) (or 42) (or false nil 42) (or 1 2 3) (or false false false)]", .out = "[0 nil nil 42 42 1 false]" },
    .{ .src = "(do (def n 0) (defn step [] (do (def n (+ n 1)) nil)) (and (step) 99) n)", .out = "1" },
    .{ .src = "(do (def n 0) (defn step [] (do (def n (+ n 1)) n)) (or (step) 99) n)", .out = "1" },
    .{ .src = "[(cond) (cond true 42) (cond false 1 true 2 false 3) (cond false 1 false 2) (cond false :a false :b :else :c)]", .out = "[nil 42 2 nil :c]" },
    .{ .src = "[(-> 10) (-> 1 (+ 2)) (-> 1 (+ 2) (+ 3)) (->> 1 (+ 2) (+ 3))]", .out = "[10 3 6 6]" },
    .{ .src = "(do (defn my-inc [x] (+ x 1)) (-> 41 my-inc))", .out = "42" },
    .{ .src = "(let [when 99] when)", .out = "99" },
    .{ .src = "(when (and 1 2) (or false :yes))", .out = ":yes" },
    // try/catch/finally and throw.
    .{ .src = "[(try 42 (catch any e e)) (try (throw 7) (catch any e e)) (try (throw :boom) (catch any e e))]", .out = "[42 7 :boom]" },
    .{ .src = "(do (defn f [] (throw 99)) (try (f) (catch any e e)))", .out = "99" },
    .{ .src = "(try (try (throw :a) (catch any e (throw :b))) (catch any e e))", .out = ":b" },
    .{ .src = "(try (throw 41) (catch any e (+ e 1)))", .out = "42" },
    .{ .src = "(try 1)", .out = "1" },
    .{ .src = "(try (try (throw 100) (catch any e (throw e))) (catch any e e))", .out = "100" },
    .{ .src = "(try (do (try 1 (catch any e 2)) (throw :x)) (catch any e [:outer e]))", .out = "[:outer :x]" },
};

test "cases: each source evaluates to the printed value" {
    var failed = false;
    for (cases) |c| {
        var program: harness.Program = undefined;
        try program.init();
        defer program.deinit();
        const result = program.run(c.src) catch |err| {
            std.debug.print("\n  source: {s}\n  error:  {s}\n", .{ c.src, @errorName(err) });
            failed = true;
            continue;
        };
        harness.expectResult(&program, c.src, result, c.out) catch {
            failed = true;
        };
    }
    try testing.expect(!failed);
}

const Failure = struct { src: []const u8, err: anyerror };

/// Programs that fail to compile, or compile and fail when run.
const failures = [_]Failure{
    // Special-form shape: the expander checks the forms it walks
    // (the lowering-level errors are pinned in compile.zig).
    .{ .src = "(if)", .err = error.MacroExpansionFailure },
    .{ .src = "(if true 1 2 3)", .err = error.MacroExpansionFailure },
    .{ .src = "(quote)", .err = error.MalformedForm },
    .{ .src = "(quote 1 2)", .err = error.MalformedForm },
    .{ .src = "(let* [x] x)", .err = error.MacroExpansionFailure },
    .{ .src = "(let* (x 1) x)", .err = error.MacroExpansionFailure },
    .{ .src = "(fn* [x &] x)", .err = error.MalformedForm },
    .{ .src = "(fn* [x & r y] x)", .err = error.MalformedForm },
    .{ .src = "(fn* (x) x)", .err = error.MacroExpansionFailure },
    .{ .src = "(def 42 5)", .err = error.MacroExpansionFailure },
    .{ .src = "(var)", .err = error.MalformedForm },
    .{ .src = "(fn* [x x] x)", .err = error.DuplicateParam },
    .{ .src = "(fn* [a & a] a)", .err = error.DuplicateParam },
    .{ .src = "(letfn* [(f [] 1) (f [] 2)] (f))", .err = error.DuplicateBinding },
    .{ .src = "(try 1 (catch Exception e e))", .err = error.MacroExpansionFailure },
    .{ .src = "(when)", .err = error.MacroExpansionFailure },
    .{ .src = "(cond true)", .err = error.MacroExpansionFailure },
    .{ .src = "~x", .err = error.ReaderFailure },
    // recur only in tail position, with the target's arity.
    .{ .src = "(recur)", .err = error.RecurOutsideTail },
    .{ .src = "(loop* [i 0] (let* [x (recur 1)] x))", .err = error.RecurOutsideTail },
    .{ .src = "(loop* [i 0] (do (recur 1) i))", .err = error.RecurOutsideTail },
    .{ .src = "(loop* [i 0] (if (recur 1) i i))", .err = error.RecurOutsideTail },
    .{ .src = "(loop* [i 0] ((fn* [x] x) (recur 1)))", .err = error.RecurOutsideTail },
    .{ .src = "(loop* [i 0] (try (recur 1) (catch any e e)))", .err = error.RecurOutsideTail },
    .{ .src = "(loop* [i 0] (recur 1 2))", .err = error.RecurArityMismatch },
    .{ .src = "(fn* [a b] (recur 1))", .err = error.RecurArityMismatch },
    .{ .src = "(fn* [a & r] (recur 1))", .err = error.RecurArityMismatch },
    // Run-time failures of compiled code.
    .{ .src = "((fn* [x y] x) 1)", .err = error.ArityMismatch },
    .{ .src = "((fn* [a b & r] a) 1)", .err = error.ArityMismatch },
    .{ .src = "never-bound", .err = error.UnboundVar },
    .{ .src = "(do (defn f [] (g)) (f))", .err = error.UnboundVar },
    .{ .src = "(throw 13)", .err = error.UncaughtThrow },
    .{ .src = "(let* [z 0] (quot 1 z))", .err = error.DivideByZero },
    .{ .src = "(let* [k :a] (- k 1))", .err = error.KindMismatch },
    .{ .src = "(try (throw :a) (catch any e (throw :b)))", .err = error.UncaughtThrow },
    .{ .src = "(do (try 1 (catch any e 2)) (throw :x))", .err = error.UncaughtThrow },
};

test "failures: each source fails with its error" {
    var failed = false;
    for (failures) |f| {
        var program: harness.Program = undefined;
        try program.init();
        defer program.deinit();
        if (program.run(f.src)) |v| {
            const printed = try program.format(v);
            defer testing.allocator.free(printed);
            std.debug.print("\n  source: {s}\n  expected {s}, got {s}\n", .{ f.src, @errorName(f.err), printed });
            failed = true;
        } else |err| {
            if (err != f.err) {
                std.debug.print("\n  source: {s}\n  expected {s}, got {s}\n", .{ f.src, @errorName(f.err), @errorName(err) });
                failed = true;
            }
        }
    }
    try testing.expect(!failed);
}

// =============================================================================
// Properties
// =============================================================================

const closure_prng_seed: u64 = 0x636C_6F73_7572_655F; // "closure_"
const sq_prng_seed: u64 = 0x7379_6E71_7572_7465; // "synqurte"

// =============================================================================
// Gate item 3: closure capture depth-10
// =============================================================================
//
// Build:
//   (let* [x VALUE]
//     ((fn* []           ; depth 1
//       ((fn* []         ; depth 2
//         ...
//           ((fn* [] x)) ; depth N
//         ...)))))
//
// For each N in 1..10, assert the result equals VALUE.

fn buildNestedClosureSource(buf: *std.array_list.Managed(u8), value: i64, depth: u32) !void {
    const prefix = try std.fmt.allocPrint(testing.allocator, "(let* [x {d}] ", .{value});
    defer testing.allocator.free(prefix);
    try buf.appendSlice(prefix);
    var d: u32 = 0;
    while (d < depth) : (d += 1) {
        try buf.appendSlice("((fn* [] ");
    }
    try buf.appendSlice("x");
    d = 0;
    while (d < depth) : (d += 1) {
        try buf.appendSlice("))");
    }
    try buf.appendSlice(")");
}

test "prop capture depth: closure capture depth 1..10 round-trips value" {
    var prng = std.Random.DefaultPrng.init(closure_prng_seed);
    const rand = prng.random();
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();

    var depth: u32 = 1;
    while (depth <= 10) : (depth += 1) {
        // Run several trials at this depth with random values.
        var trial: u32 = 0;
        while (trial < 10) : (trial += 1) {
            const v: i64 = @intCast(rand.int(i32));
            var src: std.array_list.Managed(u8) = .init(testing.allocator);
            defer src.deinit();
            try buildNestedClosureSource(&src, v, depth);
            try testing.expectEqual(v, (try program.run(src.items)).asFixnum());
        }
    }
}

test "prop capture depth: independent captures don't interfere" {
    // Two separate closures each capturing a different binding.
    // Force them to be called in sequence; both must return their
    // own captured value.
    var prng = std.Random.DefaultPrng.init(closure_prng_seed +% 2);
    const rand = prng.random();
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();

    var trial: u32 = 0;
    while (trial < 20) : (trial += 1) {
        const a: i64 = @intCast(rand.int(i16));
        const b: i64 = @intCast(rand.int(i16));
        var src: std.array_list.Managed(u8) = .init(testing.allocator);
        defer src.deinit();
        const formatted = try std.fmt.allocPrint(
            testing.allocator,
            "(let* [a {d} b {d}] (+ ((fn* [] a)) ((fn* [] b))))",
            .{ a, b },
        );
        defer testing.allocator.free(formatted);
        try src.appendSlice(formatted);
        try testing.expectEqual(a + b, (try program.run(src.items)).asFixnum());
    }
}

// =============================================================================
// Gate item 4: syntax-quote structural equality
// =============================================================================
//
// For each random Form shape, evaluate `` `SHAPE `` (syntax-quote
// with no unquotes) and `(quote SHAPE)` with its symbols qualified the
// way syntax-quote qualifies them. Both must produce structurally
// equal runtime list values.

fn listEq(a: Value, b: Value) bool {
    if (a.kind() != b.kind()) return false;
    if (a.kind() != .list) {
        // Cheap eq for the leaves we generate (fixnum / symbol /
        // keyword). Exploit interning for symbol/keyword identity.
        return a.tag == b.tag and a.payload == b.payload;
    }
    var na = a;
    var nb = b;
    while (true) {
        const ea = list_mod.isEmpty(na);
        const eb = list_mod.isEmpty(nb);
        if (ea and eb) return true;
        if (ea or eb) return false;
        if (!listEq(list_mod.head(na), list_mod.head(nb))) return false;
        na = list_mod.tail(na);
        nb = list_mod.tail(nb);
    }
}

fn writeRandomLeaf(buf: *std.array_list.Managed(u8), rand: std.Random) !void {
    const pick = rand.uintLessThan(u8, 4);
    const s = switch (pick) {
        0 => try std.fmt.allocPrint(testing.allocator, "{d}", .{rand.int(i16)}),
        1 => try std.fmt.allocPrint(testing.allocator, "sym{d}", .{rand.uintLessThan(u32, 100)}),
        2 => try std.fmt.allocPrint(testing.allocator, ":kw{d}", .{rand.uintLessThan(u32, 100)}),
        else => try std.fmt.allocPrint(testing.allocator, "{d}", .{rand.int(i8)}),
    };
    defer testing.allocator.free(s);
    try buf.appendSlice(s);
}

fn writeRandomShape(buf: *std.array_list.Managed(u8), rand: std.Random, depth: u32) !void {
    if (depth == 0 or rand.uintLessThan(u8, 3) == 0) {
        try writeRandomLeaf(buf, rand);
        return;
    }
    const n = rand.uintLessThan(u8, 5);
    try buf.append('(');
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try buf.append(' ');
        try writeRandomShape(buf, rand, depth - 1);
    }
    try buf.append(')');
}

test "prop syntax-quote: syntax-quote ≡ quote of the namespace-qualified shape" {
    var prng = std.Random.DefaultPrng.init(sq_prng_seed);
    const rand = prng.random();

    // One program for every trial, so interned symbols compare by
    // identity; syntax-quote qualifies in its namespace, `user`.
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();

    var trial: u32 = 0;
    while (trial < 100) : (trial += 1) {
        var shape: std.array_list.Managed(u8) = .init(testing.allocator);
        defer shape.deinit();
        try writeRandomShape(&shape, rand, 3);

        //   q:  (quote SHAPE) with every symbol leaf written user/symN
        //   sq: `SHAPE
        const qualified = try std.mem.replaceOwned(u8, testing.allocator, shape.items, "sym", "user/sym");
        defer testing.allocator.free(qualified);
        const q_src = try std.fmt.allocPrint(testing.allocator, "(quote {s})", .{qualified});
        defer testing.allocator.free(q_src);
        const sq_src = try std.fmt.allocPrint(testing.allocator, "`{s}", .{shape.items});
        defer testing.allocator.free(sq_src);

        const q_result = try program.run(q_src);
        const sq_result = try program.run(sq_src);
        testing.expect(listEq(q_result, sq_result)) catch |err| {
            std.debug.print("\n  shape: {s}\n", .{shape.items});
            return err;
        };
    }
}

test "prop syntax-quote: syntax-quote with unquoted integer matches hand-built list" {
    // For each trial, generate a fixed list shape with one
    // integer unquoted; verify the resulting list contains
    // that integer at the expected position.
    var prng = std.Random.DefaultPrng.init(sq_prng_seed +% 1);
    const rand = prng.random();
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();

    var trial: u32 = 0;
    while (trial < 50) : (trial += 1) {
        const v: i64 = @intCast(rand.int(i16));
        var src_buf: std.array_list.Managed(u8) = .init(testing.allocator);
        defer src_buf.deinit();
        const formatted = try std.fmt.allocPrint(
            testing.allocator,
            "(let* [n {d}] `(start ~n end))",
            .{v},
        );
        defer testing.allocator.free(formatted);
        try src_buf.appendSlice(formatted);
        const result = try program.run(src_buf.items);
        try testing.expect(result.kind() == .list);
        // Position 1 = the unquoted n value.
        const second = list_mod.head(list_mod.tail(result));
        try testing.expectEqual(v, second.asFixnum());
    }
}

// =============================================================================
// Inlined core arithmetic (COMPILER.md §4.3 rule 2)
// =============================================================================

test "inlining: an operator inlines only when it names nexis.core's Var" {
    // A namespace's own definition wins in every call shape.
    try harness.expectOutput(
        \\(ns foo)
        \\(defn + [a b] 42)
        \\[(+ 1 2) (apply + [1 2]) (let [p +] (p 1 2))]
    , "[42 42 42]");
    try harness.expectOutput(
        \\(ns foo)
        \\(defn < [a b] :mine)
        \\[(< 1 2) (apply < [1 2])]
    , "[:mine :mine]");
    // A definition in the same form counts from its own definition on.
    try harness.expectCheckedOutput("(do (def + (fn* [a b] 42)) (+ 1 2))", "42");
    // Every other namespace still gets core's.
    try harness.expectOutput(
        \\(ns foo)
        \\(defn + [a b] 42)
        \\(ns bar)
        \\(+ 1 2)
    , "3");
}

/// Compile the one form of `src` the way `program` compiles a form,
/// without running it.
fn compileIn(program: *harness.Program, src: []const u8) !nx.compile.Compiled {
    const reader_mod = nx.reader;
    var parsed = try reader_mod.parser.parseForm(program.arena.allocator(), src);
    defer parsed.parser.deinit();
    var rdr = reader_mod.Reader.init(program.arena.allocator(), src);
    defer rdr.deinit();
    const form = try rdr.readOneForm(parsed.sexp);
    return nx.compile.compileFormWith(program.arena.allocator(), form, .{
        .namespace = program.registry.current,
        .interner = program.interner,
        .host_macros = &program.host_macros,
        .persistent_allocator = program.v.runtime_arena.allocator(),
        .registry = program.registry,
    });
}

test "inlining: core arithmetic and comparison run as one instruction each" {
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();
    const ops = [_][]const u8{ "(+ a b)", "(- a b)", "(* a b)", "(/ a b)", "(quot a b)", "(mod a b)", "(< a b)", "(<= a b)", "(> a b)", "(>= a b)", "(== a b)", "(- a)", "(abs a)", "(inc a)", "(dec a)" };
    for (ops) |op| {
        const src = try std.fmt.allocPrint(testing.allocator, "(fn* [a b] {s})", .{op});
        defer testing.allocator.free(src);
        const compiled = try compileIn(&program, src);
        const body = for (compiled.consts) |k| {
            if (k == .routine) break k.routine;
        } else return error.TestFailed;
        testing.expectEqual(@as(usize, 0), body.var_table.len) catch |err| {
            std.debug.print("\n  {s} calls through a Var\n", .{op});
            return err;
        };
        // The op, then the return of its result.
        try testing.expectEqual(@as(usize, 2), body.code.len);
    }
    // Every other arity is a call.
    const call = try compileIn(&program, "(fn* [a b c] (+ a b c))");
    for (call.consts) |k| if (k == .routine) try testing.expectEqual(@as(usize, 1), k.routine.var_table.len);
}
