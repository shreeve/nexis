//! test/integration/eval_pipeline.zig — end-to-end golden + eval
//! tests (COMPILER.md §9, §10).
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
//! Golden test discipline: every
//! primitive-core form has at least one golden here; every
//! macro from defaultMacros has at least one golden; every
//! exit path of try/catch/finally has at least one golden.

const std = @import("std");
const nx = @import("nexis");
const value_mod = nx.value;
const vm = nx.vm;
const compile = nx.compile;
const intern_mod = nx.intern;
const reader_mod = nx.reader;
const expand_mod = nx.expand;
const stdlib = nx.stdlib;
const string_mod = nx.string;
const format_mod = nx.format;
const loader_mod = nx.loader;
const harness = @import("harness");

const testing = std.testing;

/// Format a runtime Value via the canonical `src/format.zig`
/// formatter in display mode, the one source of truth shared with
/// `cli.zig` and `stdlib.zig`, so test expectations match REPL
/// output byte-for-byte.
fn formatValue(buf: *std.array_list.Managed(u8), v: value_mod.Value, interner: *const intern_mod.Interner) anyerror!void {
    var w = std.Io.Writer.Allocating.init(buf.allocator);
    defer w.deinit();
    try format_mod.format(v, .display, &w.writer, interner);
    try buf.appendSlice(w.written());
}

/// A VM booted as `bin/nexis` boots one, ready to run one program of
/// top-level forms (test/harness.zig).
const Program = harness.Program;

/// Run `src` form by form, as `nexis run` does, and assert the last
/// form's printed value equals `expected`.
const expectOutput = harness.expectOutput;

/// `expectOutput` for a program whose `(ns NAME)` switches affect
/// the forms after it; the same helper.
const expectOutputProgram = harness.expectOutput;

/// Run `src` as a program and assert it fails with `expected`
/// instead of producing a value.
const expectProgramError = harness.expectError;

/// A store file for one test under `.zig-cache/tmp/<unique>/`:
/// concurrent runs never share it and `deinit` removes it.
const SeamStore = harness.Store;

/// `expectOutputProgram` for a program that opens the store named
/// `@STORE@` in `template`; the store is private to the call and
/// deleted afterwards.
fn expectOutputProgramWithStore(name: []const u8, template: []const u8, expected: []const u8) !void {
    var store = try SeamStore.init(name);
    defer store.deinit();
    const src = try store.source(template);
    defer testing.allocator.free(src);
    try expectOutputProgram(src, expected);
}

/// `expectProgramError` with the same store substitution.
fn expectProgramErrorWithStore(name: []const u8, template: []const u8, expected: anyerror) !void {
    var store = try SeamStore.init(name);
    defer store.deinit();
    const src = try store.source(template);
    defer testing.allocator.free(src);
    try expectProgramError(src, expected);
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
    // A name may be any UTF-8 text, as in Clojure.
    try expectOutput("(let [λ 2 café :crème] [(* λ λ) café 'π/τ])", "[4 :crème π/τ]");
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

test "integration: a variadic fn called with no extra arguments binds its rest parameter to nil" {
    // As in Clojure, on every entry path: call:call, apply, a native
    // calling back.
    try expectOutput("(defn f [& args] (if args :some :none)) [(f) (apply f []) (first (map f [1])) (f 1)]", "[:none :none :some :some]");
    try expectOutput("[((fn [& r] r)) ((fn [x & r] r) 1) ((fn [x & r] r) 1 2)]", "[nil nil (2)]");
    try expectOutput("(defn my-max [x & more] (if more (recur (max x (first more)) (next more)) x)) [(my-max 5) (my-max 1 9 3)]", "[5 9]");
}

test "integration: a protocol fn is a first-class function" {
    // map, apply, comp and update reach it through callValue.
    try expectOutput(
        \\(defprotocol Shape (area [s]))
        \\(defrecord Rect [w h] Shape (area [this] (* (:w this) (:h this))))
        \\(def r (->Rect 2 3))
        \\[(map area [r]) (apply area [r]) ((comp inc area) r) (update {:s r} :s area) (reduce + (map area [r r]))]
    , "[(6) 6 7 {:s 6} 12]");
    try expectOutput(
        \\(defprotocol Shape (area [s]))
        \\(try (mapv area [1]) (catch any e e))
    , ":no-protocol-impl");
}

test "integration: recur into a variadic fn passes the rest param one seq" {
    // COMPILER.md §5.6: the rest slot is the last binding of the
    // target; `(next r)` lands in `r` as it is.
    try expectOutput("((fn [& r] (if (seq r) (recur (next r)) :done)) 1 2 3)", ":done");
    try expectOutput("((fn [acc & r] (if (seq r) (recur (+ acc (first r)) (next r)) acc)) 0 1 2 3)", "6");
    try expectOutput("((fn [acc & r] (if (seq r) (recur (+ acc (first r)) (rest r)) acc)) 0 1 2 3)", "6");
    try expectProgramError("(fn [x & r] (recur x))", compile.CompileError.RecurArityMismatch);
}

// =============================================================================
// Vars and definitions
// =============================================================================

test "integration: def returns the Var" {
    try expectOutput("(def x 5)", "#'user/x");
    try expectOutputProgram("(ns my.app) (def y 1) [(var inc) (var y)]", "[#'nexis.core/inc #'my.app/y]");
}

test "var-quote: #'x reads as (var x), and a printed Var reads back" {
    // FORMS.md §3: the reader turns `#'x` into the list `(var x)`.
    try expectOutput("[(= (var inc) #'inc) (identical? #'inc #'nexis.core/inc) (@#'inc 1)]", "[true true 2]");
    try expectOutputProgram("(def ^{:doc \"d\"} x 1) [#'x (:doc (meta #'x)) @#'x]", "[#'user/x d 1]");
    try expectOutput("['#'x (read-string \"#' nexis.core/inc\")]", "[(var x) (var nexis.core/inc)]");
    try expectOutput("(= (read-string (pr-str (var inc))) '(var nexis.core/inc))", "true");
    try expectOutput("(identical? (eval (read-string (pr-str #'inc))) #'inc)", "true");
    // Syntax-quote leaves the special form `var` unqualified.
    try expectOutputProgram("(defmacro m [n] `(@#'inc ~n)) (m 1)", "2");
    try expectOutputProgram("(def z 3) (defmacro vz [] `#'z) [(vz) (macroexpand '(vz))]", "[#'user/z (var user/z)]");
    try expectOutputProgram("(defmacro vq [s] `#'~s) (vq inc)", "#'nexis.core/inc");
    // `#'` reads any form, as Clojure's reader does; `var` takes only
    // a symbol, so a non-symbol target fails to compile.
    try expectProgramError("#'(f)", compile.CompileError.ExpectedSymbol);
    try expectProgramError("#'42", compile.CompileError.ExpectedSymbol);
    try expectOutput("(try (read-string \"#'\") (catch :reader-error e :bad))", ":bad");
}

test "integration: def + Var lookup" {
    try expectOutput("(do (def x 42) x)", "42");
}

test "integration: defn" {
    try expectOutput("(do (defn inc [x] (+ x 1)) (inc 41))", "42");
}

test "defn: docstring, attribute map and ^meta land on the Var with :arglists" {
    try expectOutputProgram("(defn f \"doc\" [x] x) [(f 1) (:doc (meta (var f))) (:arglists (meta (var f)))]", "[1 doc ([x])]");
    try expectOutputProgram("(defn g {:private true} [x] x) [(g 1) (:private (meta (var g)))]", "[1 true]");
    try expectOutputProgram("(defn h \"doc\" {:k 1} [x] x) (select-keys (meta (var h)) [:doc :k])", "{:doc doc, :k 1}");
    try expectOutputProgram("(defn ^:private p [x] x) [(p 2) (:private (meta (var p)))]", "[2 true]");
    try expectOutputProgram("(defn ^{:doc \"d\"} q [x] x) (:doc (meta (var q)))", "d");
    try expectOutputProgram("(defn m \"two\" ([x] x) ([x y] y)) [(m 1 2) (:arglists (meta (var m)))]", "[2 ([x] [x y])]");
    // A docstring may span lines, as in Clojure.
    try expectOutputProgram("(defn ml\n  \"Line one.\n  Line two.\"\n  [] 1)\n[(ml) (:doc (meta (var ml)))]", "[1 Line one.\n  Line two.]");
    // Without metadata a defn's Var carries none.
    try expectOutputProgram("(defn plain [x] x) (meta (var plain))", "nil");
    // def and defmacro take the same spellings.
    try expectOutputProgram("(def ^:private v 1) [v (:private (meta (var v)))]", "[1 true]");
    try expectOutputProgram("(def ^{:doc \"dv\"} dv \"x\") [dv (:doc (meta (var dv)))]", "[x dv]");
    try expectOutputProgram("(def dd \"doc\" 3) [dd (:doc (meta (var dd)))]", "[3 doc]");
    try expectOutputProgram("(defmacro mm \"doc\" [x] x) [(mm 1) (:doc (meta (var mm)))]", "[1 doc]");
    try expectOutputProgram("(defmacro ^:private pm [x] x) [(pm 1) (:private (meta (var pm)))]", "[1 true]");
    // A ^meta name is still declared for forward references.
    try expectOutputProgram("(defn a [] (b)) (defn ^:private b [] :b) (a)", ":b");
    // defn- is defn with :private true, which :refer :all skips.
    try expectOutputProgram("(defn- dp \"doc\" [x] x) [(dp 1) (select-keys (meta (var dp)) [:private :doc :arglists])]", "[1 {:private true, :doc doc, :arglists ([x])}]");
    try expectOutputProgram("(defn- ^{:k 1} dq ([] 0) ([x] x)) [(dq) (dq 2) (select-keys (meta (var dq)) [:private :k])]", "[0 2 {:private true, :k 1}]");
    try expectOutputProgram("(defn e [] (dr)) (defn- dr [] :dr) (e)", ":dr");
    try expectOutputWithFiles(&.{.{ "privy.nx", "(ns privy) (defn- hidden [] 1) (defn shown [] 2)" }}, "(require '[privy :refer :all]) [(shown) (try (eval 'hidden) (catch any e :unresolved))]", "[2 :unresolved]");
    // reset-meta! / alter-meta! change a Var in place.
    try expectOutputProgram("(defn f [x] x) (reset-meta! (var f) {:z 1}) (alter-meta! (var f) assoc :y 2) (meta (var f))", "{:z 1, :y 2}");
}

test "meta / with-meta / vary-meta on collections never touch equality, hash or printing" {
    try expectOutput("(meta [1 2])", "nil");
    try expectOutput("(meta (with-meta [1 2] {:a 1}))", "{:a 1}");
    try expectOutput("(let [v [1 2] w (with-meta v {:a 1})] [(= v w) (= (hash v) (hash w)) (meta v) w (conj w 3)])", "[true true nil [1 2] [1 2 3]]");
    try expectOutput("(meta (with-meta {:k 1} {:m 2}))", "{:m 2}");
    try expectOutput("(meta (with-meta #{1} {:m 2}))", "{:m 2}");
    try expectOutput("(meta (with-meta '(1 2) {:m 2}))", "{:m 2}");
    try expectOutput("(meta (with-meta () {:m 2}))", "{:m 2}");
    try expectOutput("(let [m (with-meta {:k 1} {:m 2})] [(get m :k) (assoc m :j 2) (meta (assoc m :j 2))])", "[1 {:k 1, :j 2} {:m 2}]");
    try expectOutput("(meta (vary-meta [1] assoc :b 2))", "{:b 2}");
    try expectOutput("(meta (vary-meta (with-meta [1] {:a 1}) assoc :b 2))", "{:a 1, :b 2}");
    try expectOutput("(meta (with-meta (with-meta [1] {:a 1}) nil))", "nil");
    try expectOutput("(try (with-meta 1 {}) (catch any e e))", ":no-metadata-on-immediate");
    try expectOutput("(try (with-meta \"s\" {}) (catch any e e))", ":no-metadata-on-immediate");
    try expectOutput("(try (with-meta (var meta) {}) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (with-meta [1] 5) (catch any e e))", ":kind-mismatch");
    try expectOutput("[(meta \"s\") (meta 1) (meta nil) (meta :k)]", "[nil nil nil nil]");
}

test "metadata: every update of a collection keeps it, as in Clojure; rest and transients do not" {
    const m = "(def m {:m 1}) ";
    try expectOutput(m ++ "(mapv meta [(conj (with-meta [1] m) 2) (conj (with-meta '(1) m) 2) (conj (with-meta () m) 1) (conj (with-meta {:a 1} m) [:b 2]) (conj (with-meta #{1} m) 2)])", "[{:m 1} {:m 1} {:m 1} {:m 1} {:m 1}]");
    try expectOutput(m ++ "(mapv meta [(assoc (with-meta {:a 1} m) :b 2) (assoc (with-meta [1 2] m) 0 3) (assoc (with-meta [1 2] m) 2 3) (dissoc (with-meta {:a 1 :b 2} m) :a) (dissoc (with-meta {:a 1} m) :a) (disj (with-meta #{1 2} m) 1) (disj (with-meta #{1} m) 1)])", "[{:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1}]");
    try expectOutput(m ++ "(let [big (with-meta (zipmap (range 20) (range 20)) m)] (mapv meta [(assoc big :x 1) (dissoc big 0) (conj (with-meta (set (range 20)) m) :x) (disj (with-meta (set (range 20)) m) 0) (conj (with-meta (vec (range 40)) m) 40)]))", "[{:m 1} {:m 1} {:m 1} {:m 1} {:m 1}]");
    try expectOutput(m ++ "(mapv meta [(pop (with-meta [1 2] m)) (pop (with-meta [1] m)) (pop (with-meta (vec (range 33)) m)) (into (with-meta [] m) [1 2]) (into (with-meta {} m) {:a 1}) (into (with-meta #{} m) [1]) (empty (with-meta [1] m)) (empty (with-meta {:a 1} m)) (empty (with-meta #{1} m)) (empty (with-meta '(1) m))])", "[{:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1} {:m 1}]");
    try expectOutput(m ++ "(mapv meta [(assoc-in (with-meta {:a {:b 1}} m) [:a :b] 2) (update (with-meta {:a 1} m) :a inc) (merge (with-meta {:a 1} m) {:b 2}) (update (with-meta [1] m) 0 inc)])", "[{:m 1} {:m 1} {:m 1} {:m 1}]");
    // rest, next and a list's pop are the elements after the first, which carry no metadata of their own.
    try expectOutput(m ++ "(mapv meta [(rest (with-meta [1 2 3] m)) (next (with-meta [1 2 3] m)) (rest (with-meta '(1 2) m)) (pop (with-meta '(1 2) m)) (seq (with-meta [1 2] m))])", "[nil nil nil nil nil]");
    // transient and persistent! drop it; into keeps its target's.
    try expectOutput(m ++ "(mapv meta [(persistent! (conj! (transient (with-meta [1] m)) 2)) (persistent! (transient (with-meta #{1} m))) (persistent! (assoc! (transient (with-meta {} m)) :a 1))])", "[nil nil nil]");
    try expectOutput(m ++ "(let [v (conj (with-meta [1] m) 2)] [(= v [1 2]) (= (hash v) (hash [1 2])) v])", "[true true [1 2]]");
}

test "metadata: a seq view of a vector takes it without copying, and its rest does not carry it" {
    try expectOutput(
        \\(let [v (vec (range 5)) s (with-meta (seq v) {:a 1}) r (with-meta (rest v) {:b 2})]
        \\  [(meta s) s (count s) (first s) (= s v) (meta (rest s)) (rest s) (meta (next s)) (meta (drop 2 s)) (drop 2 s)
        \\   (meta r) r (meta (rest r)) (rest r) (nth s 4) (vec s) (meta (with-meta s {:c 3})) (meta (with-meta s nil)) (with-meta s nil)
        \\   (meta (seq v)) (into [] s) (apply + s) (= (hash s) (hash (seq v)))])
    , "[{:a 1} (0 1 2 3 4) 5 0 true nil (1 2 3 4) nil nil (2 3 4) {:b 2} (1 2 3 4) nil (2 3 4) 4 [0 1 2 3 4] {:c 3} nil (0 1 2 3 4) nil [0 1 2 3 4] 10 true]");
}

test "metadata: a record carries it through assoc and dissoc; kinds that cannot carry it are :kind-mismatch" {
    try expectOutput("(defrecord P [x y]) (let [p (with-meta (->P 1 2) {:m 1})] [(meta p) p (= p (->P 1 2)) (meta (assoc p :x 3)) (meta (dissoc p :z)) (meta (assoc p :z 3)) (meta (->P 1 2)) (meta (with-meta p nil))])", "[{:m 1} #user.P{:x 1, :y 2} true {:m 1} {:m 1} {:m 1} nil nil]");
    try expectOutput("[(try (with-meta (atom 1) {}) (catch any e e)) (try (with-meta (i64-vector [1]) {}) (catch any e e)) (try (with-meta inc {}) (catch any e e)) (try (with-meta (transient []) {}) (catch any e e)) (meta (atom 1))]", "[:kind-mismatch :kind-mismatch :kind-mismatch :kind-mismatch nil]");
}

test "metadata: hints in binding positions are dropped, ^meta on a collection literal is its metadata" {
    try expectOutput("(let [^String s \"x\"] s)", "x");
    try expectOutput("((fn [^long x ^:foo y] (+ x y)) 1 2)", "3");
    try expectOutput("(loop [^long i 0] (if (< i 3) (recur (inc i)) i))", "3");
    try expectOutput("(let [[^long a {:keys [^String b]}] [1 {:b 2}]] [a b])", "[1 2]");
    try expectOutput("(try (throw :z) (catch Exception ^Object e e))", ":z");
    try expectOutputProgram("(defn f ^long [x] x) (f 2)", "2");
    try expectOutputProgram("(defn h ([^long a] a) (^long [a ^long b] (+ a b))) [(h 1) (h 1 2)]", "[1 3]");
    try expectOutputProgram("(defn ^String g [] \"g\") [(g) (:tag (meta (var g)))]", "[g String]");
    try expectOutputProgram("(defrecord R [^long x ^String y]) (:x (->R 1 \"a\"))", "1");
    try expectOutput("(^:hint inc 1)", "2");
    try expectOutput("[(meta ^:foo [1 2]) (meta ^{:a (+ 1 2)} {:b 2}) (meta ^:s #{})]", "[{:foo true} {:a 3} {:s true}]");
    try expectOutput("(#(vector ^:m [%]) 1)", "[[1]]");
    // A macro argument reaches the macro without its metadata.
    try expectOutputProgram("(defmacro m [x] x) (m ^:foo [1])", "[1]");
    // ^meta inside syntax-quote reaches the definition the macro writes.
    try expectOutputProgram("(defmacro defp [n] `(def ^:private ~n 1)) (defp hidden) [hidden (:private (meta (var hidden)))]", "[1 true]");
    try expectOutputProgram("(defmacro lethint [v] `(let [^String x# ~v] x#)) (lethint 5)", "5");
    // A syntax-quoted collection with ^meta is that collection carrying it.
    try expectOutput("[`^:foo [1 2] (meta `^:foo [1 2]) (meta `^{:k 1} {:a 1}) (meta `^:s #{1}) (meta `^:l (a b))]", "[[1 2] {:foo true} {:k 1} {:s true} {:l true}]");
    try expectOutputProgram("(defmacro mv [] `(meta ^:foo [1 2])) (mv)", "{:foo true}");
    try expectOutputProgram("(defmacro wm [] (with-meta [1 2] {:w 1})) [(wm) (meta (wm))]", "[[1 2] {:w 1}]");
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

test "integration: quote inside a quoted form is the 2-list (quote x)" {
    try expectOutput("'(a 'b [1 'c])", "(a (quote b) [1 (quote c)])");
    try expectOutput("(first (rest ''x))", "x");
    try expectOutput("(= ''x '(quote x))", "true");
    try expectOutput("(eval ''x)", "x");
}

test "integration: syntax-quote no unquote" {
    try expectOutput("`(1 2 3)", "(1 2 3)");
    // An unqualified symbol with no Var resolves to the current
    // namespace, as in Clojure.
    try expectOutput("`(a b c)", "(user/a user/b user/c)");
}

test "integration: syntax-quote with unquote" {
    try expectOutput("(let* [x 5] `(value ~x))", "(user/value 5)");
}

test "integration: syntax-quote with splicing" {
    try expectOutput(
        "(let* [xs (quote (b c d))] `(a ~@xs e))",
        "(user/a b c d user/e)",
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

test "syntax-quote: ~@ splices any seqable, in lists and vectors" {
    try expectOutput("(let [x 1] `(~x ~@[2 3]))", "(1 2 3)");
    try expectOutput("(let [x 1] `(~x ~@nil))", "(1)");
    try expectOutput("(let [x 1] `(~x ~@(list 2) ~@(seq [3]) ~@(map inc [3])))", "(1 2 3 4)");
    try expectOutput("(let [xs [2 3]] `[1 ~@xs 4])", "[1 2 3 4]");
    try expectOutput("(let [xs [2 3]] `[~@xs])", "[2 3]");
    try expectOutput("(let [xs '(1 2)] `(~@xs))", "(1 2)");
    try expectOutput("`(~@#{1})", "(1)");
    try expectOutput("(let [kvs [:a 1] more '(:b 2)] `{~@kvs ~@more})", "{:a 1, :b 2}");
    try expectOutput("(let [xs [1 2 1]] `#{~@xs})", "#{1 2}");
    try expectOutput("(let [xs [2 3]] `(1 ~@xs (4 ~@xs)))", "(1 2 3 (4 2 3))");
    // A vector built by splicing is a vector, not a seq.
    try expectOutput("(let [xs [2 3]] (vector? `[1 ~@xs]))", "true");
    try expectOutput("(let [xs [2 3]] (list? `(1 ~@xs)))", "true");
}

test "syntax-quote: maps, sets, quote, #() and @ are payloads" {
    try expectOutput("`{:a 1}", "{:a 1}");
    try expectOutput("(let [x 2] `{:a ~x})", "{:a 2}");
    try expectOutput("(let [x 2] `{~x :a})", "{2 :a}");
    try expectOutput("`#{1}", "#{1}");
    try expectOutput("(let [x 1] `#{~x})", "#{1}");
    try expectOutput("`'a", "(quote user/a)");
    try expectOutput("(let [x 1] `'~x)", "(quote 1)");
    try expectOutput("`(#(inc %) 1)", "((fn* [%1] (nexis.core/inc %1)) 1)");
    try expectOutput("`@a", "(nexis.core/deref user/a)");
    try expectOutput("(let [m `{:f (fn* [x#] x#)}] (= (first (nth (:f m) 1)) (nth (:f m) 2)))", "true");
}

test "syntax-quote: symbols qualify to the namespace that defines them" {
    try expectOutput("`(+ 1 2)", "(nexis.core/+ 1 2)");
    try expectOutput("`(if a b)", "(if user/a user/b)");
    try expectOutputProgram("(defn helper [] 1) `(helper)", "(user/helper)");
    try expectOutput("(= `a 'a)", "false");
    try expectOutput("(= `a 'user/a)", "true");
    try expectOutput("(= `+ 'nexis.core/+)", "true");
    try expectOutput("`nexis.core/+", "nexis.core/+");
    try expectOutput("`db/open", "db/open");
    try expectOutputProgram("(ns other) `(foo)", "(other/foo)");
    // Special forms, `&`, catch matchers and `#()` parameters stay bare.
    try expectOutput("`(do (let* [a 1] (fn* [& r] (try a (catch any e e) (finally 1)))))", "(do (let* [user/a 1] (fn* [& user/r] (try user/a (catch any user/e user/e) (finally 1)))))");
    try expectOutput("`(quote a)", "(quote user/a)");
    try expectOutput("`(def x (var y))", "(def user/x (var user/y))");
    try expectOutput("`(recur (throw 1))", "(recur (throw 1))");
    // Host macros qualify to nexis.core and still expand from there.
    try expectOutput("(first `(let [x 1] x))", "nexis.core/let");
    try expectOutput("(nexis.core/let [x 1] (nexis.core/when true x))", "1");
    try expectOutputProgram("(defmacro m [x] `(let [y# ~x] (inc y#))) (m 1)", "2");
    try expectOutputProgram("(defmacro m [x] `(when ~x (-> ~x inc))) (m 1)", "2");
    // A forward reference through a macro resolves like a bare one.
    try expectOutputProgram("(defmacro m [] `(later)) (defn f [] (m)) (defn later [] :late) (f)", ":late");
    // Auto-gensym never qualifies; `~'x` keeps a bare symbol.
    try expectOutput("(let [f (fn [] `(x# ~'x))] [(namespace (first (f))) (subs (name (first (f))) 0 3)])", "[nil x__]");
    try expectOutput("(second `(a ~'b))", "b");
}

test "syntax-quote: auto-gensyms stay unique across top-level forms" {
    try expectOutputProgram("(def p `a#) (def q `a#) (= p q)", "false");
    // A macro's syntax-quote is expanded once, when the macro is
    // defined, so every call of it yields the same name (Clojure's
    // read-time rule); `gensym` gives a fresh one per call.
    try expectOutputProgram(
        \\(defmacro same [] `'g#)
        \\(defmacro fresh [] (list 'quote (gensym "g")))
        \\[(= (same) (same)) (= (fresh) (fresh))]
    , "[true false]");
}

test "gensym takes a prefix of any length" {
    try expectOutputProgram(
        \\(let [p (apply str (repeat 1000 "p"))
        \\      g (name (gensym p))]
        \\  (= (subs g 0 1002) (str p "__")))
    , "true");
}

test "syntax-quote: a nested syntax-quote writes macro-writing macros" {
    try expectOutputProgram("(defmacro m [x] ``(a ~~x)) (m 1)", "(user/a 1)");
    try expectOutputProgram(
        \\(defmacro make-adder-macro [name n] `(defmacro ~name [y#] `(+ ~y# ~~n)))
        \\(make-adder-macro add5 5)
        \\(add5 10)
    , "15");
}

test "syntax-quote: a bare binding name inside syntax-quote is the Clojure mistake" {
    // `(let [x ~a] x)` qualifies `x`; a qualified name cannot be bound.
    try expectProgramError("(defmacro bad [a] `(let [x ~a] x)) (bad 1)", compile.CompileError.MacroExpansionFailure);
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

test "integration: a throw out of a running finally body leaves no pending continuation" {
    // The inner finally's continuation is abandoned by its own
    // throw; the handler that catches it discards it (VM.md §12).
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try harness.expectResult(&program, "", try program.run(
        \\(defn once [] (try (try 1 (finally (throw :x))) (catch any e e)))
        \\(defn twice [] (try (try (try 1 (finally (throw :x))) (finally (throw :y))) (catch any e e)))
        \\(defn across [] (try (mapv (fn [_] (try 1 (finally (throw :z)))) [1]) (catch any e e)))
        \\(dotimes [_ 100] (once) (twice) (across))
        \\[(once) (twice) (across)]
    ), "[:x :y :z]");
    try testing.expectEqual(@as(usize, 0), program.v.finally_stack.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.handlers.items.len);
}

test "integration: every exit path leaves the VM's stacks as it found them" {
    // Normal return, a caught throw, a throw across callValue, a VM
    // error translated inside a native's callback, a binding unwound
    // by a throw, a finally that runs on the way out: afterwards no
    // handler, continuation, binding frame or root is left.
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try harness.expectResult(&program, "", try program.run(
        \\(def ^:dynamic *d* 0)
        \\(def log (atom []))
        \\(defn thrower [x] (binding [*d* x] (throw [:t *d*])))
        \\[(try (mapv thrower [1 2]) (catch any e e))
        \\ (try (reduce (fn [a x] (+ a (/ 1 x))) 0 [1 0]) (catch any e e))
        \\ (try (binding [*d* 5] (try (mapv (fn [x] (throw x)) [:in]) (finally (swap! log conj *d*)))) (catch any e e))
        \\ (binding [*d* 7] (mapv (fn [x] (try (inc x) (finally (swap! log conj *d*)))) [1 2]))
        \\ *d* @log]
    ), "[[:t 1] :divide-by-zero :in [2 3] 0 [5 7 7]]");
    try testing.expectEqual(@as(usize, 0), program.v.handlers.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.finally_stack.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.dyn_frames.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.dyn_saves.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.roots.items.len);
}

test "integration: nested try — outer catches what inner rethrows" {
    try expectOutput(
        "(try (try (throw 100) (catch any e (throw e))) (catch any e e))",
        "100",
    );
}

test "try: finally alone, no clause at all, and empty bodies" {
    try expectOutput("(try 1 (finally 2))", "1");
    try expectOutput("(let [a (atom 0)] [(try (throw :x) (catch any e e) (finally (reset! a 1))) @a])", "[:x 1]");
    try expectOutput("(let [a (atom [])] (try (try (throw :x) (finally (swap! a conj :fin))) (catch any e (swap! a conj e))) @a)", "[:fin :x]");
    try expectOutput("(try 1)", "1");
    try expectOutput("(try)", "nil");
    try expectOutput("(try (throw :x) (catch any e))", "nil");
    try expectOutput("(try (catch any e 1))", "nil");
}

test "try: catch clauses match by keyword tag, in order, or rethrow" {
    try expectOutput("(try (throw :a) (catch :a e :got-a) (catch :b e :got-b))", ":got-a");
    try expectOutput("(try (throw :b) (catch :a e :got-a) (catch :b e :got-b))", ":got-b");
    try expectOutput("(try (throw :c) (catch :a e 1) (catch any e [:any e]))", "[:any :c]");
    try expectOutput("(try (try (throw :c) (catch :a e 1)) (catch any e [:outer e]))", "[:outer :c]");
    try expectOutput("(let [a (atom 0)] [(try (try (throw :c) (catch :a e 1) (finally (swap! a inc))) (catch :c e :outer)) @a])", "[:outer 1]");
    // A map matches by its :error entry.
    try expectOutput("(try (throw {:error :boom :n 1}) (catch :boom e (:n e)))", "1");
    try expectOutput("(try (/ 1 0) (catch :divide-by-zero e :dz))", ":dz");
    try expectOutput("(try (case 3 1 :a) (catch :no-matching-clause e (:value e)))", "3");
    try expectOutput("(try (throw {:error :other}) (catch :boom e 1) (catch any e (:error e)))", ":other");
    // A caught binding may be captured by an inner fn.
    try expectOutput("(try (throw 5) (catch any e ((fn [] (inc e)))))", "6");
    try expectProgramError("(try 1 (catch 'sym e 1))", compile.CompileError.MacroExpansionFailure);
    // set! on a lexical name has no binding to rebind: refused at
    // compile time, not as a run-time :not-dynamic.
    try expectProgramError("(let [x 1] (set! x 2))", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("((fn [x] (set! x 2)) 1)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(loop [i 0] (set! i 2))", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(try 1 (catch any e 1) 2)", compile.CompileError.MacroExpansionFailure);
}

test "try: a class-name matcher or :default catches anything, as Exception would" {
    try expectOutput("(try (/ 1 0) (catch ArithmeticException e :caught))", ":caught");
    try expectOutput("(try (throw (ex-info \"boom\" {})) (catch Exception e (ex-message e)))", "boom");
    try expectOutput("(try (throw :x) (catch Throwable e e))", ":x");
    try expectOutput("(try (throw :x) (catch clojure.lang.ExceptionInfo e [:info e]))", "[:info :x]");
    try expectOutput("(try (throw :x) (catch :default e [:default e]))", "[:default :x]");
    // Clauses still run in order: a tag before a class name wins.
    try expectOutput("(try (throw :a) (catch :a e 1) (catch Exception e 2))", "1");
}

test "fn: a :pre/:post condition map checks arguments and the result" {
    try expectOutput("((fn [x] {:pre [(pos? x)]} (* 2 x)) 3)", "6");
    try expectOutput("(try ((fn [x] {:pre [(pos? x) (< x 10)]} x) -1) (catch :assertion-failed e (:message e)))", "Assert failed: (pos? x)");
    try expectOutput("(try ((fn [x] {:post [(> % 10)]} (* 2 x)) 3) (catch :assertion-failed e (:message e)))", "Assert failed: (> % 10)");
    try expectOutputProgram("(defn f ([x] {:pre [(odd? x)]} x) ([x y] {:post [(= % 3)]} (+ x y))) [(f 1) (f 1 2) (try (f 2) (catch any e :pre))]", "[1 3 :pre]");
    // A lone map is the body, not a condition map.
    try expectOutput("((fn [] {:pre [false]}))", "{:pre [false]}");
}

test "condp: :>> passes the predicate's result to a function" {
    try expectOutput("(condp some [1 2 3] #{0 6} :>> inc #{4 5 3} :>> dec #{7} 99 :none)", "2");
    try expectOutput("(condp some [9] #{0} :>> inc :none)", ":none");
    try expectOutput("(condp = 2 1 :one 2 :two)", ":two");
}

test "empty bodies are nil and () is the empty list" {
    try expectOutput("((fn []))", "nil");
    try expectOutput("(do (defn e0 []) (e0))", "nil");
    try expectOutput("((fn [x]) 1)", "nil");
    try expectOutput("(let [x 1])", "nil");
    try expectOutput("(loop [x 1])", "nil");
    try expectOutput("(letfn [(f [])] (f))", "nil");
    try expectOutput("(do)", "nil");
    try expectOutput("()", "()");
    try expectOutput("(= () '())", "true");
    try expectOutput("(count ())", "0");
    try expectOutput("(list? ())", "true");
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
// Native fns (macro-authoring primitives)
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

test "integration: seq, rest, next, nthrest and nth over a vector view" {
    // LIST.md §1: the seq of a vector is an O(1) view; it is a list
    // to every consumer.
    try expectOutput("(seq [])", "nil");
    try expectOutput("(rest [])", "()");
    try expectOutput("(rest [1])", "()");
    try expectOutput("(next [1])", "nil");
    try expectOutput("(let [s (seq [1 2 3])] [s (seq? s) (count s) (rest s) (next (next s)) (next (next (next s)))])", "[(1 2 3) true 3 (2 3) (3) nil]");
    try expectOutput("(let [v (vec (range 40))] [(nthnext v 38) (drop 38 v) (nthrest v 99) (nthnext v 40) (nth (rest v) 34) (nth (rest v) 39 :none)])", "[(38 39) (38 39) () nil 35 :none]");
    try expectOutput("(let [v (vec (range 1100))] [(= (rest v) (range 1 1100)) (= (hash (drop 1056 v)) (hash (range 1056 1100))) (= (seq v) v)])", "[true true true]");
    try expectOutput("(let [s (rest [1 2 3])] [(cons 0 s) (conj s 0) (apply + s) (into [] s) (reduce + s) (pr-str s) {s :k}])", "[(0 2 3) (0 2 3) 5 [2 3] 5 (2 3) {(2 3) :k}]");
    try expectOutput("(let [[a & more] (rest [1 2 3 4])] [a more])", "[2 (3 4)]");
    try expectOutput("(let [s (rest [1 2 3])] [(meta (with-meta s {:a 1})) (meta (rest (with-meta s {:a 1}))) (meta (seq (with-meta [1] {:b 2}))) (with-meta s {:a 1})])", "[{:a 1} nil nil (2 3)]");
    // Emptying a vector with a seq test each step is linear.
    try expectOutput("(loop [v (vec (range 3000))] (if (seq v) (recur (pop v)) (count v)))", "0");
    try expectOutput("(loop [s (seq (vec (range 3000))) n 0] (if s (recur (next s) (+ n (first s))) n))", "4498500");
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
    // A user-written recursive procedural macro that uses
    // first/rest/empty? at COMPILE TIME. Native fns work in
    // defmacro bodies because the persistent-namespace design
    // makes them visible to the compile-time sub-VM.
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

test "integration: a macro body reads names of its keyword and symbol arguments" {
    // The macro runs in a sub-VM that borrows the compile-time
    // interner, so the ids in its arguments resolve.
    try expectOutput("(do (defmacro kw-name [k] (name k)) (kw-name :abc))", "abc");
    try expectOutput("(do (defmacro tagged [k v] `[~(keyword (str (name k) \"-tag\")) ~v]) (tagged :a 1))", "[:a-tag 1]");
    try expectOutput("(do (defmacro same? [k] (= k (keyword \"x\"))) [(same? :x) (same? :y)])", "[true false]");
}

test "integration: native fn — arity mismatch is catchable" {
    try expectOutput("(try (first) (catch any e e))", ":arity-mismatch");
    try expectOutput("(try (cons 1) (catch any e e))", ":arity-mismatch");
}

test "integration: recursion through a native re-entry ends in a catchable :stack-overflow" {
    // Every level nests `apply` / `mapv` / a protocol impl and a run
    // loop on the native stack; the guard stops it before the stack
    // does (VM.md §13.1).
    try expectOutput("(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) (g 300)", "300");
    try expectOutput("(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) (try (g 100000000) (catch any e e))", ":stack-overflow");
    try expectOutput("(defn h [n] (if (= n 0) 0 (+ 1 (first (mapv h [(- n 1)]))))) (try (h 100000000) (catch any e e))", ":stack-overflow");
    // The VM is whole afterwards: the next call runs normally.
    try expectOutput("(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) (try (g 100000000) (catch any e e)) (g 10)", "10");
}

test "integration: runaway recursion is a catchable :stack-overflow; deep legitimate recursion runs" {
    try expectOutput("(defn d [n] (if (= n 0) 0 (inc (d (dec n))))) (d 100000)", "100000");
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.max_frames = 20_000;
    try harness.expectResult(&program, "", try program.run("(defn f [n] (inc (f n))) (try (f 1) (catch any e [:caught e]))"), "[:caught :stack-overflow]");
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    try testing.expectError(vm.VmError.StackOverflow, program.run("(f 1)"));
    // The trace keeps the innermost 32 frames and the outermost 8
    // around one marker for the rest.
    const trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 41), trace.len);
    try testing.expectEqualStrings("f", trace[0].name);
    try testing.expectEqualStrings("<19960 frames elided>", trace[32].name);
    try testing.expectEqualStrings("test-form", trace[40].name);
}

test "integration: an uncaught runtime error names what went wrong in VM.error_detail" {
    const Case = struct { src: []const u8, err: anyerror, detail: []const u8 };
    const cases = [_]Case{
        .{ .src = "(defn f [x] x) (f)", .err = vm.VmError.ArityMismatch, .detail = "f takes 1 argument, got 0" },
        .{ .src = "(defn g [a b & r] a) (g 1)", .err = vm.VmError.ArityMismatch, .detail = "g takes at least 2 arguments, got 1" },
        .{ .src = "(first 1 2)", .err = vm.VmError.ArityMismatch, .detail = "first takes 1 argument, got 2" },
        .{ .src = "(mapv (fn [a b] a) [1])", .err = vm.VmError.ArityMismatch, .detail = "fn takes 2 arguments, got 1" },
        .{ .src = "(5 1)", .err = vm.VmError.NotCallable, .detail = "an integer is not callable" },
        .{ .src = "(map \"s\" [1])", .err = vm.VmError.NotCallable, .detail = "a string is not callable" },
        .{ .src = "(+ 1 \"a\")", .err = vm.VmError.KindMismatch, .detail = "+ expects numbers, got a string" },
        .{ .src = "(< nil 1)", .err = vm.VmError.KindMismatch, .detail = "< expects numbers, got nil" },
        .{ .src = "(defprotocol P (m [x])) (m 1)", .err = vm.VmError.NoProtocolImpl, .detail = "no impl of m for an integer" },
    };
    for (cases) |case| {
        var program: Program = undefined;
        try program.init();
        defer program.deinit();
        // A caught error's detail does not linger into the next one.
        _ = try program.run("(try (first) (catch any e e))");
        try testing.expectError(case.err, program.run(case.src));
        try testing.expectEqualStrings(case.detail, program.v.error_detail);
    }
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(try (first) (catch any e e))");
    try testing.expectError(vm.VmError.UncaughtThrow, program.run("(throw :x)"));
    try testing.expectEqualStrings("", program.v.error_detail);
}

test "integration: a throw that leaves through a catch or a finally is reported where it began" {
    const Case = struct { src: []const u8, err: anyerror, detail: []const u8 = "", at: []const u8 };
    const f = "(defn f [] (into [] [1] [2] [3])) (defn g [] (throw {:e 1})) ";
    const cases = [_]Case{
        // A runtime error through a finally, a catch no clause of
        // which matches, and a catch that throws it again.
        .{ .src = f ++ "(defn h [] (try (f) (finally 1))) (h)", .err = vm.VmError.ArityMismatch, .detail = "into takes 0 to 2 arguments, got 4", .at = "f" },
        .{ .src = f ++ "(defn h [] (try (f) (catch :nope e 1))) (h)", .err = vm.VmError.ArityMismatch, .detail = "into takes 0 to 2 arguments, got 4", .at = "f" },
        .{ .src = f ++ "(defn h [] (try (f) (catch any e (throw e)))) (h)", .err = vm.VmError.ArityMismatch, .detail = "into takes 0 to 2 arguments, got 4", .at = "f" },
        // A thrown value the same ways, and through both at once.
        .{ .src = f ++ "(defn h [] (try (g) (catch :nope e 1) (finally 2))) (h)", .err = vm.VmError.UncaughtThrow, .at = "g" },
        // A catch that catches another throw inside it still rethrows
        // the first from where it began.
        .{ .src = f ++ "(defn h [] (try (g) (catch any e (try (throw :x) (catch any _ nil)) (throw e)))) (h)", .err = vm.VmError.UncaughtThrow, .at = "g" },
        // A different value thrown from a catch, or from a finally,
        // begins where it is thrown.
        .{ .src = f ++ "(defn h [] (try (f) (catch any e (throw {:wrapped e})))) (h)", .err = vm.VmError.UncaughtThrow, .at = "h" },
        .{ .src = f ++ "(defn h [] (try (f) (finally (throw :cleanup-failed)))) (h)", .err = vm.VmError.UncaughtThrow, .at = "h" },
        // A handled error does not stay with its value: a later throw
        // of the same keyword begins where it is thrown.
        .{ .src = f ++ "(try (f) (catch any e e)) (defn h [] (throw :arity-mismatch)) (h)", .err = vm.VmError.UncaughtThrow, .at = "h" },
    };
    for (cases) |case| {
        var program: Program = undefined;
        try program.init();
        defer program.deinit();
        try testing.expectError(vm.VmError.UncaughtThrow, program.run(case.src));
        try testing.expectEqual(case.err, program.v.traced_error.?);
        try testing.expectEqualStrings(case.detail, program.v.error_detail);
        try testing.expectEqualStrings(case.at, program.v.error_trace.items[0].name);
    }
}

// =============================================================================
// Multi-arity defn
// =============================================================================

test "integration: multi-arity dispatch by argc" {
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

test "integration: multi-arity arity-mismatch is catchable" {
    try expectOutput(
        \\(do (defn f ([x] :one) ([x y] :two))
        \\    (try (f 1 2 3) (catch any e e)))
    , ":arity-mismatch");
}

test "integration: multi-arity with variadic overload" {
    try expectOutput(
        \\(do (defn f ([x] x) ([x & rest] (+ x (reduce + 0 rest))))
        \\    (f 100))
    , "100");
    try expectOutput(
        \\(do (defn f ([x] x) ([x & rest] (+ x (reduce + 0 rest))))
        \\    (f 1 2 3 4 5))
    , "15");
}

test "integration: multi-arity with destructured params" {
    try expectOutput(
        \\(do (defn f ([[a b]] (+ a b)) ([x y] (* x y)))
        \\    (f [10 20]))
    , "30");
    try expectOutput(
        \\(do (defn f ([[a b]] (+ a b)) ([x y] (* x y)))
        \\    (f 3 4))
    , "12");
}

test "multi-arity fn: anonymous, named and letfn clauses dispatch by argc" {
    try expectOutput("((fn ([x] x) ([x y] (+ x y))) 1 2)", "3");
    try expectOutput("((fn ([x] x) ([x y] (+ x y))) 1)", "1");
    try expectOutput("((fn ([x] x)) 7)", "7");
    try expectOutput("((fn ([] 0) ([x & r] (count r))) 1 2 3)", "2");
    // The exact fixed arity wins over the variadic one, in any order.
    try expectOutput("((fn ([x & r] :var) ([x] :one)) 1)", ":one");
    try expectOutput("((fn ([x & r] :var) ([x] :one)) 1 2)", ":var");
    try expectOutput("((fn f ([n] (f n 0)) ([n acc] (if (zero? n) acc (f (dec n) (+ acc n))))) 4)", "10");
    try expectOutput("(letfn [(f ([x] x) ([x y] y))] [(f 1) (f 1 2)])", "[1 2]");
    try expectOutput("(letfn [(f [[a b]] (+ a b))] (f [1 2]))", "3");
    try expectOutput("(let [f (fn ([[a b]] (+ a b)) ([m k] (get m k)))] [(f [1 2]) (f {:k 3} :k)])", "[3 3]");
    try expectOutput("(try ((fn ([x] x)) 1 2) (catch any e e))", ":arity-mismatch");
    try expectProgramError("(fn ([x] 1) ([x] 2))", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(fn ([x y] 1) ([x & r] 2))", compile.CompileError.MacroExpansionFailure);
}

test "multi-arity fn: recur re-enters the clause with the clause's own arity" {
    // Each clause binds its params through `loop`, so `recur` in
    // a clause's tail rebinds that clause's params and never sees
    // the dispatcher's `[& args]` (MACROEXPAND.md §10, `fn`).
    try expectOutput(
        \\(do (defn fact ([n] (fact n 1)) ([n acc] (if (< n 2) acc (recur (dec n) (* n acc)))))
        \\    (fact 20))
    , "2432902008176640000");
    try expectOutput("((fn ([n] (if (pos? n) (recur (dec n)) :zero)) ([a b] :two)) 5)", ":zero");
    try expectOutput("(letfn [(f ([n] (f n 0)) ([n acc] (if (zero? n) acc (recur (dec n) (+ acc n)))))] (f 10))", "55");
    // A variadic clause's rest param receives the one seq `recur` passes.
    try expectOutput("((fn ([] :none) ([x & r] (if (seq r) (recur (first r) (next r)) x))) 1 2 3 4)", "4");
    // A pattern param destructures again after every recur.
    try expectOutput("((fn ([[a b]] (if (pos? a) (recur [(dec a) (+ b a)]) b))) [3 0])", "6");
    // A captured clause param gets a fresh cell per iteration.
    try expectOutput(
        \\(do (defn cl ([n] (cl n [])) ([n fs] (if (< n 3) (recur (inc n) (conj fs (fn [] n))) (mapv (fn [f] (f)) fs))))
        \\    (cl 0))
    , "[0 1 2]");
}

test "multi-arity fn: a nested loop in a clause owns its recur, and a wrong-count recur is a compile error" {
    try expectOutput(
        \\(do (defn g ([n] (g n [])) ([n acc] (if (zero? n) acc (recur (dec n) (conj acc (loop [i 0 s 0] (if (< i n) (recur (inc i) (+ s i)) s)))))))
        \\    (g 4))
    , "[6 3 1 0]");
    try expectProgramError("(defn bad ([n] 1) ([n acc] (recur n)))", compile.CompileError.RecurArityMismatch);
    try expectProgramError("(defn bad ([n] (recur)))", compile.CompileError.RecurArityMismatch);
}

test "named fn: the name is the function itself inside its body" {
    try expectOutput("((fn f [n] (if (pos? n) (f (dec n)) :done)) 3)", ":done");
    try expectOutput("(let [g (fn f [n] (if (zero? n) 1 (* n (f (dec n)))))] (g 5))", "120");
}

// =============================================================================
// Destructuring (let / fn / defn params)
// =============================================================================

test "integration: sequential destructuring (let)" {
    try expectOutput("(let [[a b c] [10 20 30]] (+ a b c))", "60");
    try expectOutput("(let [[a b] [1 2 3]] (+ a b))", "3");
    try expectOutput("(let [[a b c] [1 2]] (nil? c))", "true");
}

test "integration: sequential destructuring with rest" {
    // MACROEXPAND.md §10 `let`: a vector pattern's rest is `next`,
    // nil once the source is exhausted; a fn rest parameter is the
    // list the VM packs, nil when empty (VM.md §6), as in Clojure,
    // and so is a multi-arity fn's variadic rest, `(nthnext args n)`.
    try expectOutput("(let [[a & rest] [1 2 3 4]] rest)", "(2 3 4)");
    try expectOutput("(let [[a b & rest] [1 2 3 4 5]] rest)", "(3 4 5)");
    try expectOutput("(let [[a & r] [1 2 3]] r)", "(2 3)");
    try expectOutput("(nil? (let [[a & r] [1]] r))", "true");
    try expectOutput("(nil? (let [[a b & r] [1]] r))", "true");
    try expectOutput("((fn [& r] r))", "nil");
    try expectOutput("((fn ([x & r] r)) 1)", "nil");
    try expectOutput("((fn ([x & r] r) ([] 0)) 1 2 3)", "(2 3)");
    try expectOutput("((fn ([] 0) ([x & r] r)) 1)", "nil");
}

test "integration: sequential destructuring with :as" {
    try expectOutput("(let [[a b :as v] [10 20]] (+ a b (count v)))", "32");
}

test "integration: nested sequential destructuring" {
    try expectOutput("(let [[a [b c] d] [1 [2 3] 4]] (+ a b c d))", "10");
}

test "integration: associative destructuring (:keys)" {
    try expectOutput("(let [{:keys [x y]} {:x 1 :y 2}] (+ x y))", "3");
}

test "integration: associative destructuring with explicit keys" {
    try expectOutput("(let [{a :alpha b :beta} {:alpha 10 :beta 20}] (+ a b))", "30");
}

test "integration: associative destructuring with :or defaults" {
    try expectOutput("(let [{:keys [x y] :or {y 99}} {:x 5}] (+ x y))", "104");
    // :or default applies only when key is missing.
    try expectOutput("(let [{:keys [y] :or {y 99}} {:y 7}] y)", "7");
}

test "integration: associative destructuring with :as" {
    try expectOutput("(let [{:keys [a] :as m} {:a 1 :b 2}] (count m))", "2");
}

test "destructuring: :strs, :syms, namespaced keys, keyword entries and :or" {
    try expectOutput("(let [{:strs [a]} {\"a\" 1}] a)", "1");
    try expectOutput("(let [{:syms [a]} {'a 2}] a)", "2");
    try expectOutput("(let [{:keys [x/y]} {:x/y 3}] y)", "3");
    try expectOutput("(let [{:keys [:a :b/c]} {:a 1 :b/c 2}] [a c])", "[1 2]");
    try expectOutput("(let [{:p/keys [n m]} {:p/n 1 :p/m 2}] [n m])", "[1 2]");
    try expectOutput("(let [{:p/syms [n]} {'p/n 1}] n)", "1");
    try expectOutput("(let [{:keys [a] :or {a 9}} {}] a)", "9");
    try expectOutput("(let [{:strs [a] :or {a 9}} {}] a)", "9");
    try expectOutput("(let [{:keys [a b] :or {b 5} :as m} {:a 1}] [a b m])", "[1 5 {:a 1}]");
    try expectOutput("(let [{:keys [a] :or {a 9}} {:a nil}] a)", "nil");
}

test "destructuring: a map pattern after & takes keyword arguments" {
    try expectOutput("((fn [& {:keys [a b]}] [a b]) :a 1 :b 2)", "[1 2]");
    try expectOutput("((fn [x & {:keys [a]}] [x a]) 0 :a 1)", "[0 1]");
    try expectOutput("((fn [& {:keys [a] :or {a 7}}] a))", "7");
    try expectOutput("((fn [& {:keys [a]}] a) {:a 3})", "3");
    try expectOutput("(do (defn kw [& {:keys [a]}] a) (kw :a 1))", "1");
    try expectOutput("(let [[x & {:keys [k]}] [1 :k 2]] [x k])", "[1 2]");
    try expectOutput("(do (defn ma ([x] x) ([x & {:keys [a]}] [x a])) [(ma 1) (ma 1 :a 2)])", "[1 [1 2]]");
    try expectOutput("(try ((fn [& {:keys [a]}] a) :a) (catch any e e))", ":invalid-argument");
}

test "destructuring: loop bindings destructure and recur rebinds them" {
    try expectOutput("(loop [[x & xs] [1 2 3] acc 0] (if x (recur xs (+ acc x)) acc))", "6");
    try expectOutput("(loop [{:keys [n]} {:n 3} out []] (if (pos? n) (recur {:n (dec n)} (conj out n)) out))", "[3 2 1]");
    try expectOutput("(loop [[a b] [1 2]] (+ a b))", "3");
}

test "hygiene: a local or Var named after a core function cannot capture host-macro output" {
    // MACROEXPAND.md §5: host macros emit `nexis.core/name`.
    try expectOutput("(let [nth (fn [& _] :captured)] (let [[a b] [1 2]] [a b]))", "[1 2]");
    try expectOutput("(let [count (fn [& _] 99)] ((fn ([x] :one) ([x y] :two)) 1))", ":one");
    try expectOutputProgram("(defn nth [& _] :user-nth) (let [[a b] [1 2]] [a b])", "[1 2]");
    try expectOutput("(let [= (fn [& _] false)] (case 1 1 :one :none))", ":one");
    try expectOutput("(let [seq (fn [& _] nil)] (for [x [1 2]] x))", "(1 2)");
    try expectOutput("(let [get (fn [& _] :g)] (let [{a :a} {:a 1}] a))", "1");
    try expectOutput("(let [< (fn [& _] false) not (fn [& _] false)] ((fn ([x] :one) ([x & r] :var)) 1 2))", ":var");
    try expectOutput("(let [first (fn [& _] :f) next (fn [& _] nil) conj (fn [& _] :c)] (for [x [1 2]] x))", "(1 2)");
    try expectOutput("(let [rest (fn [& _] :r)] (let [[a & r] [1 2 3]] r))", "(2 3)");
}

test "hygiene: a local, Var or macro named let, fn, loop, defn or and cannot capture host-macro output" {
    // MACROEXPAND.md §5: host macros emit `nexis.core/let` and the like.
    try expectOutputProgram("(defmacro and [& xs] :my-and) (defrecord R9 [a]) (R9? (->R9 1))", "true");
    try expectOutputProgram("(defn four [let] (for [[a b] [[1 2]]] [let a b])) (four 9)", "([9 1 2])");
    try expectOutput("(let [loop 5] ((fn ([x] (+ x loop)) ([x y] y)) 1))", "6");
    try expectOutput("(let [let 5] ((fn [[a b]] (+ a b let)) [1 2]))", "8");
    try expectOutput("(let [let 5] (loop [[a b] [1 2]] (+ a b let)))", "8");
    try expectOutput("(let [fn 5] (defn g [x] (+ x fn)) (g 1))", "6");
    try expectOutput("(let [defn 5] (defrecord RR [a]) (:a (->RR 1)))", "1");
    try expectOutputProgram("(defprotocol P (m [s])) (let [fn 7 let 8] (defrecord R2 [a] P (m [s] [a fn let])) (m (->R2 1)))", "[1 7 8]");
    try expectOutputProgram("(defprotocol P (m [s])) (defrecord R3 [a]) (let [fn 7] (extend-type R3 P (m [s] fn)) (m (->R3 1)))", "7");
    // `@x` in a macro's arguments is `(nexis.core/deref x)`.
    try expectOutputProgram("(defmacro q [x] (list 'quote x)) (q @a)", "(nexis.core/deref a)");
}

test "integration: fn with destructured params" {
    try expectOutput(
        \\(do (defn point-sum [[x y]] (+ x y))
        \\    (point-sum [3 4]))
    , "7");
    try expectOutput(
        \\(do (defn sum-keys [{:keys [a b]}] (+ a b))
        \\    (sum-keys {:a 10 :b 20}))
    , "30");
}

test "integration: defn with destructured params + rest" {
    try expectOutput(
        \\(do (defn first-of [[a & _]] a)
        \\    (first-of [99 1 2 3]))
    , "99");
}

test "integration: destructuring let preserves single-evaluation of source" {
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
// Multi-namespace (auto-refer core + qualified symbols + (ns NAME))
// =============================================================================

test "integration: auto-refer nexis.core from user" {
    try expectOutput("(map inc [1 2 3])", "(2 3 4)");
    try expectOutput("(reduce + 0 (range 5))", "10");
}

test "integration: qualified core symbol" {
    try expectOutput("(nexis.core/+ 1 2 3)", "6");
    try expectOutput("(nexis.core/* 2 3 4)", "24");
    try expectOutput("(nexis.core/inc 41)", "42");
}

test "integration: (ns NAME) switches current namespace" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(def x 100)
        \\(ns user)
        \\my.app/x
    , "100");
}

test "integration: defn in a namespace + qualified call" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(defn twice [n] (* n 2))
        \\(ns user)
        \\(my.app/twice 21)
    , "42");
}

test "integration: qualified symbol resolves via registry not lexical" {
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

test "integration: defs in different namespaces don't collide" {
    try expectOutputProgram(
        \\(ns a) (def x 1)
        \\(ns b) (def x 2)
        \\(ns user)
        \\(+ a/x b/x)
    , "3");
}

test "integration: unqualified def shadows core in current ns" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(def map :i-am-not-a-function)
        \\map
    , ":i-am-not-a-function");
}

test "integration: missing qualified ns is UnresolvedSymbol" {
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
        compile.compileSourceWith(arena.allocator(), "missing.ns/foo", .{
            .namespace = registry.current,
            .interner = interner,
            .host_macros = &host_macros,
            .persistent_allocator = v.runtime_arena.allocator(),
            .registry = registry,
        }),
    );
}

// =============================================================================
// Embedded core.nx composite layer
// =============================================================================

test "integration: core.nx second / third / last" {
    try expectOutput("(second [10 20 30])", "20");
    try expectOutput("(third [10 20 30])", "30");
    try expectOutput("(last [10 20 30])", "30");
    try expectOutput("(last (list :a :b :c))", ":c");
    try expectOutput("(last (list))", "nil");
}

test "integration: core.nx reverse" {
    try expectOutput("(reverse [1 2 3 4 5])", "(5 4 3 2 1)");
    try expectOutput("(reverse (list))", "()");
    try expectOutput("(reverse nil)", "()");
}

test "integration: core.nx range" {
    try expectOutput("(range 0)", "()");
    try expectOutput("(range 1)", "(0)");
    try expectOutput("(range 5)", "(0 1 2 3 4)");
}

test "integration: core.nx take / drop" {
    try expectOutput("(take 3 [1 2 3 4 5])", "(1 2 3)");
    try expectOutput("(take 0 [1 2 3])", "()");
    try expectOutput("(take 10 [1 2 3])", "(1 2 3)");
    try expectOutput("(drop 2 [1 2 3 4 5])", "(3 4 5)");
    try expectOutput("(drop 10 [1 2 3])", "()");
    try expectOutput("(drop 0 (list :a :b))", "(:a :b)");
}

test "integration: core.nx true? / false?" {
    try expectOutput("(true? true)", "true");
    try expectOutput("(true? 1)", "false");
    try expectOutput("(true? :a)", "false");
    try expectOutput("(false? false)", "true");
    try expectOutput("(false? nil)", "false");
}

test "integration: core.nx when-let" {
    try expectOutput("(when-let [x 42] (+ x 1))", "43");
    try expectOutput("(when-let [x nil] :unreached)", "nil");
    try expectOutput("(when-let [x false] :unreached)", "nil");
    try expectOutput("(when-let [x (list 1 2)] (first x))", "1");
}

test "integration: core.nx if-let" {
    try expectOutput("(if-let [x 7] (* x x) :nope)", "49");
    try expectOutput("(if-let [x nil] :nope :else-branch)", ":else-branch");
    try expectOutput("(if-let [x (get {:a 1} :missing)] x :default)", ":default");
}

test "integration: core.nx if-let / when-let destructure, and if-let's else is optional" {
    try expectOutput("(if-let [x 1] x)", "1");
    try expectOutput("(if-let [x nil] x)", "nil");
    try expectOutput("(when-let [[a b] [1 2]] b)", "2");
    try expectOutput("(if-let [{:keys [a]} {:a 1}] a 0)", "1");
    try expectOutput("(when-let [[a & more] (seq [])] a)", "nil");
    // As Clojure's: one binding and test, then and at most one else.
    try expectProgramError("(if-let [x 1] x 2 3)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(if-let [x 1 y 2] x)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(if-some [x 1] x 2 3)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(if-some (x 1) x)", compile.CompileError.MacroExpansionFailure);
}

test "integration: core.nx if-some / when-some bind false; when-first binds the first element" {
    try expectOutput("[(if-some [x false] [:some x] :none) (if-some [x nil] :some :none) (if-some [x nil] :some)]", "[[:some false] :none nil]");
    try expectOutput("[(when-some [x false] (str x)) (when-some [x nil] :unreached)]", "[false nil]");
    try expectOutput("[(when-first [x [7 8]] (* x 2)) (when-first [x []] :unreached) (when-first [x nil] :unreached)]", "[14 nil nil]");
}

test "integration: core.nx comment, doto, defonce, assert and time" {
    try expectOutputProgram("(comment (undefined-fn 1) (more)) 1", "1");
    try expectOutput("(comment)", "nil");
    try expectOutput("(let [a (atom [])] (deref (doto a (swap! conj 1) (swap! conj 2))))", "[1 2]");
    try expectOutputProgram("(defonce x (atom 1)) (defonce x (atom 2)) @x", "1");
    try expectOutputProgram("(def y 5) (defonce y 6) y", "5");
    try expectOutput("[(assert (= 1 1)) (try (assert (= 1 2)) (catch :assertion-failed e (ex-message e)))]", "[nil Assert failed: (= 1 2)]");
    try expectOutput("(try (assert false \"nope\") (catch any e (ex-message e)))", "Assert failed: nope\nfalse");
    try expectOutput("(try (assert (= 1 \"a\") (str \"n\" 1)) (catch any e [(ex-message e) (ex-data e)]))", "[Assert failed: n1\n(= 1 \"a\") {:error :assertion-failed}]");
    try expectOutput("(let [f (fn [] (try (assert false) (catch any e e)))] (identical? (f) (f)))", "false");
    try expectOutput("(let [r (atom nil) s (with-out-str (reset! r (time (+ 1 2))))] [@r (subs s 0 15) (subs s (- (count s) 8))])", "[3 \"Elapsed time:   msecs\"\n]");
}

test "integration: with-out-str captures what the print functions write, nested and across a throw" {
    try expectOutput("(pr-str (with-out-str (print \"a\" 1) (prn \"b\") (println :c) (pr 'd) (newline)))", "\"a 1\\\"b\\\"\\n:c\\nd\\n\"");
    try expectOutput("(with-out-str (print \"x\") (print (count (with-out-str (print \"inner\")))))", "x5");
    try expectOutput("[(try (with-out-str (print \"lost\") (throw :boom)) (catch :boom e e)) (with-out-str (print \"after\"))]", "[:boom after]");
}

test "integration: core.nx higher-order functions: some-fn, every-pred, memoize, trampoline, comparator, run!" {
    try expectOutput("[((some-fn even? neg?) 3 -1) ((some-fn even?) 1 3) ((every-pred odd? pos?) 1 3) ((every-pred odd? pos?) 1 -3)]", "[true false true false]");
    // some-fn returns the first truthy result, not a boolean; a miss is
    // the last result for up to three predicates and three arguments,
    // else nil, and arguments past the third go element by element,
    // as Clojure's arities do.
    try expectOutput("[((some-fn :a :b) {:b 5}) ((some-fn :a) {} {}) ((some-fn even? neg? zero?) 1) ((some-fn even? neg? zero? #{9}) 1) ((some-fn even?) 1 3 5 7) ((some-fn even?))]", "[5 nil false nil nil nil]");
    try expectOutput("[((some-fn :a :b) {} {} {} {:b 4} {:a 5}) ((some-fn #{4} #{5} #{6} #{7}) 1 2 3 7 6)]", "[4 6]");
    try expectOutput("(try (some-fn) (catch any e e))", ":arity-mismatch");
    try expectOutputProgram("(def calls (atom 0)) (def f (memoize (fn [x] (swap! calls inc) (* x x)))) [(f 3) (f 3) (f 4) @calls]", "[9 9 16 2]");
    try expectOutputProgram("(defn down [n] (if (zero? n) :done #(down (dec n)))) (trampoline down 100000)", ":done");
    try expectOutput("(sort (comparator >) [1 3 2])", "(3 2 1)");
    try expectOutput("(let [a (atom 0)] [(run! #(swap! a + %) [1 2 3]) @a])", "[nil 6]");
}

test "integration: core.nx sequence functions: partition-by, dedupe, take-nth, split-with, distinct?, doall, dorun, rseq, nthnext" {
    try expectOutput("[(partition-by odd? [1 3 2 4 5]) (dedupe [1 1 2 1 1 3]) (take-nth 2 (range 7)) (split-with neg? [-1 -2 3 -4])]", "[((1 3) (2 4) (5)) (1 2 1 3) (0 2 4 6) [(-1 -2) (3 -4)]]");
    // Clojure's shapes at the edges: partition-by and dedupe of nothing
    // are (), take-last of nothing nil; nthrest that drops nothing is
    // coll itself, while drop is always a seq.
    try expectOutput("[(partition-by odd? []) (partition-by odd? nil) (dedupe []) (dedupe nil) (take-last 0 [1 2]) (take-last 2 nil) (take-last 2 []) (take-last 5 [1 2])]", "[() () () () nil nil nil (1 2)]");
    try expectOutput("[(nthrest [1 2] 0) (nthrest [1 2] -1) (nthrest nil 1) (nthrest [] 1) (nthrest [1] 2) (nthrest (list 1 2) 1) (drop 0 [1 2]) (drop 0 nil) (drop 5 [1]) (drop -1 [1]) (nthnext [1 2] 0)]", "[[1 2] [1 2] nil [] () (2) (1 2) () () (1) (1 2)]");
    try expectOutput("[(distinct? 1 2 3) (distinct? 1 2 1) (doall (map inc [1])) (dorun [1]) (rseq [1 2 3]) (rseq []) (nthnext [1 2 3] 2) (nthnext [1] 1)]", "[true false (2) nil (3 2 1) nil (3) nil]");
    try expectOutput("[(ffirst [[1 2]]) (fnext [1 2 3]) (nnext [1 2 3]) (second #{9}) (third (list 1 2 3))]", "[1 2 (3) nil 3]");
}

test "integration: core.nx maps: update-vals, update-keys; atoms: reset-vals!, volatile!" {
    try expectOutput("[(update-vals {:a 1 :b 2} inc) (update-keys {1 :a} str)]", "[{:a 2, :b 3} {1 :a}]");
    try expectOutputProgram("(defrecord R [x]) [(meta (update-vals (with-meta {:a 1} {:m 1}) inc)) (meta (update-keys (with-meta {1 :a} {:m 2}) str)) (update-vals (->R 1) inc) (update-vals {} inc)]", "[{:m 1} {:m 2} {:x 2} {}]");
    try expectOutput("(let [a (atom 1)] [(reset-vals! a 2) @a])", "[[1 2] 2]");
    try expectOutput("(let [v (volatile! 1)] [(vswap! v + 2) (vreset! v 9) @v (volatile? v)])", "[3 9 9 true]");
}

test "integration: core.nx predicates" {
    try expectOutput("[(any? nil) (ident? :a) (ident? 'b) (ident? \"c\") (qualified-keyword? :a/b) (simple-keyword? :a) (qualified-symbol? 'a/b) (simple-symbol? 'a)]", "[true true true false true true true true]");
    try expectOutput("[(int? 1) (int? 1.0) (pos-int? 1) (pos-int? 0) (nat-int? 0) (neg-int? -1) (double? 1.5) (double? 1)]", "[true false true false true true true false]");
    // int? and its kin are Java's long range, as Clojure's (a Long, not a BigInt).
    try expectOutput("[(int? 140737488355328) (int? 9223372036854775807) (int? 9223372036854775808) (int? -9223372036854775808) (int? -9223372036854775809) (pos-int? 9223372036854775808) (nat-int? 99999999999999999999) (neg-int? -99999999999999999999)]", "[true true false true false false false false]");
    try expectOutput("[(seqable? nil) (seqable? \"s\") (seqable? 1) (counted? [1]) (counted? \"s\") (record? {}) (ex-cause (ex-info \"m\" {} :c))]", "[true true false true false false :c]");
}

test "integration: char and int conversion, parse-long, parse-double, parse-boolean" {
    try expectOutput("[(int \\A) (char 97) (int 3.9) (long \\a) (char \\b)]", "[65 a 3 97 b]");
    // int checks Java's 32-bit int range, as Clojure's cast does.
    try expectOutput("[(int 2147483647) (int -2147483648) (int -3.9) (int -2147483647.9)]", "[2147483647 -2147483648 -3 -2147483647]");
    try expectOutput("(map #(try (int %) (catch any e e)) [2147483648 2147483647.5 -2147483649.0 1e300 99999999999999999999 (/ 0.0 0.0)])", "(:invalid-argument :invalid-argument :invalid-argument :invalid-argument :invalid-argument :invalid-argument)");
    try expectOutput("[(parse-long \"42\") (parse-long \"-7\") (parse-long \"4x\") (parse-long \" 1\") (parse-double \"1.5\") (parse-double \"x\") (parse-boolean \"true\") (parse-boolean \"no\")]", "[42 -7 nil nil 1.5 nil true nil]");
    try expectOutput("(try (char -1) (catch any e e))", ":invalid-argument");
    try expectOutput("(try (parse-long 1) (catch any e e))", ":kind-mismatch");
    // Java's Long/valueOf and Double/valueOf grammars, as Clojure's
    // parse-long and parse-double use them: no Zig-only spellings.
    try expectOutput("[(parse-long \"+5\") (parse-long \"-0\") (parse-long \"1_000\") (parse-long \"+-5\") (parse-long \"0x10\") (parse-long \"+\") (parse-long \"\") (parse-long \"99999999999999999999\") (parse-long \"-9223372036854775808\")]", "[5 0 nil nil nil nil nil nil -9223372036854775808]");
    try expectOutput("[(parse-double \"1_000\") (parse-double \"0x10\") (parse-double \"inf\") (parse-double \"nan\") (parse-double \"infinity\") (parse-double \".\") (parse-double \"e5\") (parse-double \"1e\") (parse-double \"\") (parse-double \"1.5 x\") (parse-double \"++1\") (parse-double \"0x1.8\")]", "[nil nil nil nil nil nil nil nil nil nil nil nil]");
    try expectOutput("[(parse-double \" 1.5\\n\") (parse-double \"1e5\") (parse-double \"+1\") (parse-double \".5\") (parse-double \"5.\") (parse-double \"1.5d\") (parse-double \"2F\") (parse-double \"-2.5E-1\") (parse-double \"0x10p0\") (parse-double \"0X.8P1\") (parse-double \"0x1.p1f\")]", "[1.5 100000.0 1.0 0.5 5.0 1.5 2.0 -0.25 16.0 1.0 2.0]");
    try expectOutput("(map (comp str parse-double) [\"NaN\" \"-Infinity\" \"+Infinity\" \"\\tNaN \"])", "(NaN -Infinity Infinity NaN)");
}

test "integration: bit operations" {
    try expectOutput("[(bit-and 12 10) (bit-or 12 10) (bit-xor 12 10) (bit-not 0) (bit-shift-left 1 10) (bit-shift-right -16 2) (unsigned-bit-shift-right -1 60) (bit-test 5 2) (bit-set 0 3) (bit-clear 15 0) (bit-and 7 6 3)]", "[8 14 6 -1 1024 -4 15 true 8 14 2]");
}

test "integration: rand, rand-int, rand-nth, shuffle stay in range" {
    try expectOutput("(let [xs (repeatedly 200 #(rand-int 10))] [(every? #(<= 0 % 9) xs) (every? (fn [_] (< -1 (rand) 1)) (range 50)) (contains? #{:a :b} (rand-nth [:a :b])) (sort (shuffle [3 1 2]))])", "[true true true (1 2 3)]");
}

test "integration: format with %s %d %f %x %% and widths" {
    try expectOutput("(format \"%s-%d-%5.2f-%x-%%-%3d|%-3d|%05d\" \"a\" 42 3.14159 255 7 7 42)", "a-42- 3.14-ff-%-  7|7  |00042");
    try expectOutput("(format \"%s %s\" [1 \"b\"] nil)", "[1 \"b\"] nil");
    try expectOutput("(format \"%.1f %.3f %f\" 2 -0.0005 1.5)", "2.0 -0.001 1.500000");
    try expectOutput("(try (format \"%d\" \"x\") (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (format \"%d\") (catch any e e))", ":invalid-argument");
    try expectOutput("(with-out-str (printf \"%d+%d\" 1 2))", "1+2");
}

test "integration: format widths count characters, %.Ns truncates, fields are bounded, %f prints every double" {
    try expectOutput("(format \"[%3s|%-3s|%2s]\" \"é\" \"é\" \"日本\")", "[  é|é  |日本]");
    try expectOutput("(format \"%.2s|%.0s|%.9s|%5.1s|%.1s\" \"héllo\" \"x\" \"ab\" \"éa\" nil)", "hé||ab|    é|n");
    try expectOutput("(let [s (format \"%.400f\" 1e300)] [(count s) (subs s 0 3) (subs s 299 304)])", "[702 100 00.00]");
    try expectOutput("(format \"%f %.2f %f %5.1f\" (/ 0.0 0.0) (/ 1.0 0.0) (/ -1.0 0.0) 1e-300)", "NaN Infinity -Infinity   0.0");
    try expectOutput("[(try (format \"%99999999999999999999d\" 1) (catch any e e)) (try (format \"%.99999999999999999999f\" 1.0) (catch any e e)) (try (format \"%2000000s\" \"\") (catch any e e))]", "[:invalid-argument :invalid-argument :invalid-argument]");
    try expectOutput("[(try (format \"%.2d\" 1) (catch any e e)) (try (format \"%.1x\" 1) (catch any e e)) (try (format \"%.1c\" \\a) (catch any e e))]", "[:invalid-argument :invalid-argument :invalid-argument]");
    try expectOutput("(count (format \"%1048576s\" \"\"))", "1048576");
}

test "integration: transients: transient, conj!, assoc!, dissoc!, disj!, pop!, persistent!" {
    try expectOutput("(persistent! (reduce conj! (transient []) (range 5)))", "[0 1 2 3 4]");
    try expectOutput("(let [t (transient {:a 1})] (persistent! (dissoc! (assoc! t :b 2 :c 3) :a)))", "{:b 2, :c 3}");
    try expectOutput("(persistent! (disj! (conj! (transient #{1}) 2 3) 1))", "#{2 3}");
    try expectOutput("(persistent! (pop! (assoc! (transient [1 2 3]) 0 9)))", "[9 2]");
    try expectOutput("(let [t (transient [1 2])] [(count t) (nth t 1) (get t 0) (count (transient {:a 1})) (get (transient {:a 1}) :a) (contains? (transient #{1}) 1)])", "[2 2 1 1 1 true]");
    try expectOutput("(let [t (transient [])] (persistent! t) (try (conj! t 1) (catch any e e)))", ":transient-used-after-persistent");
    try expectOutput("(try (transient '(1)) (catch any e e))", ":kind-mismatch");
    try expectOutput("(persistent! (conj! (transient {}) [:k 1]))", "{:k 1}");
    // conj! onto a transient map takes what conj onto a map takes: an
    // entry, a map or record whose entries are all added, or nil.
    try expectOutputProgram("(defrecord R [x]) (persistent! (conj! (transient {:a 1}) {:b 2 :c 3} nil [:d 4] (->R 5)))", "{:a 1, :b 2, :c 3, :d 4, :x 5}");
    try expectOutput("[(try (conj! (transient {}) [1 2 3]) (catch any e e)) (try (conj! (transient {}) 1) (catch any e e))]", "[:arity-mismatch :kind-mismatch]");
    // empty? counts a transient, as Clojure 1.12's does (CLJ-1872).
    try expectOutput("[(empty? (transient [])) (empty? (transient [1])) (empty? (transient {:a 1})) (empty? (transient #{}))]", "[true false false true]");
    try expectOutput("(let [t (transient [])] (persistent! t) (try (empty? t) (catch any e e)))", ":transient-used-after-persistent");
    // A transient is called, and looked up by a keyword, as its
    // persistent kind is.
    try expectOutput("[(:a (transient {:a 1})) (:b (transient {:a 1}) 7) ((transient {:a 1}) :a) ((transient {:a 1}) :b 9) ((transient [5 6]) 1) ((transient #{3}) 3) ((transient #{3}) 4) (:a (transient [1])) (map (transient {:a 1}) [:a :c])]", "[1 7 1 9 6 3 nil nil (1 nil)]");
    try expectOutput("[(try ((transient [1 2]) 5) (catch any e e)) (try ((transient [1 2]) :a) (catch any e e)) (try ((transient #{1}) 1 2) (catch any e e))]", "[:index-out-of-bounds :kind-mismatch :arity-mismatch]");
    try expectOutput("(let [t (transient {:a 1})] (persistent! t) [(try (:a t) (catch any e e)) (try (t :a) (catch any e e)) (try (get t :a) (catch any e e))])", "[:transient-used-after-persistent :transient-used-after-persistent :transient-used-after-persistent]");
    try expectOutput("(let [t (transient [1 2 3])] (identical? t (assoc! t 3 4)))", "true");
    try expectOutput("[(try (assoc! (transient [1]) 5 :x) (catch any e e)) (try (pop! (transient [])) (catch any e e))]", "[:index-out-of-bounds :index-out-of-bounds]");
    try expectOutput("[(pop [1 2 3]) (pop [1]) (count (reduce (fn [v _] (pop v)) (vec (range 2000)) (range 1990)))]", "[[1 2] [] 10]");
}

test "integration: a transient hashes by identity, so it can be a set member or map key (SEMANTICS §2.6)" {
    try expectOutput(
        \\(let [t (transient [])]
        \\  [(= (hash t) (hash t)) (count (conj #{t} t (transient []))) (get {t 1} t)
        \\   (= t (transient [])) (= t [])])
    , "[true 2 1 false false]");
}

test "integration: identity kinds are = only to themselves, and two of them hash apart (SEMANTICS §3.3)" {
    try expectOutputProgram(
        \\(defprotocol P (area [s]))
        \\(def old-p P)
        \\(def old-area area)
        \\(defprotocol P (area [s]))
        \\(def x 1)
        \\(def y 1)
        \\(defn same [a b] [(= a a) (= (hash a) (hash a)) (= a b) (= (hash a) (hash b))])
        \\[(same (atom 1) (atom 1)) (same (fn [] 1) (fn [] 1)) (same + -) (same (var x) (var y)) (same old-p P) (same old-area area)]
    , "[[true true false false] [true true false false] [true true false false] [true true false false] [true true false false] [true true false false]]");
    try expectOutputProgramWithStore("identity-conns",
        \\(def c (db/open "@STORE@"))
        \\(def n (nextomic/connect "@STORE@.nextomic"))
        \\(def seen [(= c c) (= (hash c) (hash c)) (= n n) (= (hash n) (hash n)) (= c n) (contains? #{c} c) (contains? #{n} n)])
        \\(db/close c)
        \\(nextomic/release n)
        \\seen
    , "[true true true true false true true]");
}

test "integration: in-ns switches the namespace the next forms compile in" {
    try expectOutputProgram("(in-ns 'other) (def x 1) (in-ns 'user) [other/x (try (in-ns \"s\") (catch any e e))]", "[1 :kind-mismatch]");
}

test "integration: *command-line-args* is nil without arguments; read-line needs the host's stdin" {
    try expectOutput("[*command-line-args* (try (read-line) (catch any e e))]", "[nil :io-error]");
}

test "integration: =, compare, flatten, hash, set membership and printing of data nested past the stack are :stack-overflow" {
    // One chain of vectors 100k deep, built once: the test's 6 MiB
    // guard (stack.main_thread_budget) stops every walk of it well
    // before the bottom, in Debug and ReleaseFast alike (a ReleaseFast
    // hash or print uses about 160 bytes a level, so about 40k levels
    // reach the guard). `b` is `a` one level down, so `=` and
    // `compare` walk both to the bottom with nothing else to build,
    // and a collection under NEXIS_GC_STRESS marks one chain, not
    // several.
    try expectOutput(
        \\(let [a (loop [acc [] i 0] (if (< i 100000) (recur [acc] (inc i)) acc))
        \\      b (nth a 0)]
        \\  [(try (= a b) (catch :stack-overflow e :deep))
        \\   (try (compare a b) (catch :stack-overflow e :deep))
        \\   (try (flatten a) (catch :stack-overflow e :deep))
        \\   (try (hash a) (catch :stack-overflow e :deep))
        \\   (try #{a b} (catch :stack-overflow e :deep))
        \\   (try (pr-str a) (catch :stack-overflow e :deep))])
    , "[:deep :deep :deep :deep :deep :deep]");
}

test "integration: a record prints as #ns.Type{...}; defrecord and defprotocol may be redefined" {
    try expectOutput("(defrecord P [x y]) (def old (->P 1 \"a\")) (defrecord P [x y z]) (defprotocol A (area [s])) (defprotocol A (area [s])) [(pr-str old) (pr-str (->P 1 2 3)) (= old (map->P {:x 1 :y \"a\"}))]", "[#user.P{:x 1, :y \"a\"} #user.P{:x 1, :y 2, :z 3} false]");
}

/// `expectOutput` with `deep-a` and `deep-b` defined as vectors nested
/// 200,000 deep, past the stack guard. They are built with the
/// collector off: under `NEXIS_GC_STRESS` every cycle re-marks the
/// growing chain, which makes building one quadratic. `src` itself
/// runs under the policy the environment chose.
fn expectOutputOverDeepData(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.gc_enabled = false;
    _ = try program.run("(defn nest [n] (loop [i 0 v []] (if (< i n) (recur (inc i) [v]) v))) (def deep-a (nest 200000)) (def deep-b (nest 200000))");
    program.v.gc_enabled = true;
    try harness.expectResult(&program, src, try program.run(src), expected);
}

test "integration: a :stack-overflow caught inside a callback does not resurface from the native that called it" {
    try expectOutputOverDeepData(
        \\(let [safe= (fn [x y] (try (= x y) (catch :stack-overflow e :deep)))
        \\      safe-str (fn [x] (try (pr-str x) (catch :stack-overflow e :deep)))
        \\      a deep-a b deep-b]
        \\  [(safe= a b)
        \\   (mapv (fn [x] (safe= x b)) [a 1])
        \\   (reduce (fn [acc x] (conj acc (safe= x b))) [] [a])
        \\   (vec (map (fn [x] (safe= x b)) [a]))
        \\   (count (filterv (fn [x] (= :deep (safe= x b))) [a 1]))
        \\   (swap! (atom 0) (fn [_] (safe= a b)))
        \\   (apply safe= [a b])
        \\   (mapv safe-str [a])
        \\   (try (mapv (fn [x] (= x b)) [a]) (catch :stack-overflow e :outer))])
    , "[:deep [:deep false] [:deep] [:deep] 1 :deep :deep [:deep] :outer]");
}

test "integration: a transient op that raises leaves the transient as it found it" {
    try expectOutputOverDeepData(
        \\(let [a deep-a
        \\      s (transient (set (range 20)))
        \\      m (transient (zipmap (range 20) (range 20)))]
        \\  [(try (conj! s 20 a) (catch :stack-overflow e e))
        \\   (try (assoc! m :x 1 a 2) (catch :stack-overflow e e))
        \\   (try (dissoc! m 0 a) (catch :stack-overflow e e))
        \\   (try (disj! s 0 a) (catch :stack-overflow e e))
        \\   (try (conj! m [:y 1] :not-an-entry) (catch any e e))
        \\   (count (persistent! s))
        \\   (let [p (persistent! m)] [(count p) (p :x) (p :y) (p 0)])])
    , "[:stack-overflow :stack-overflow :stack-overflow :stack-overflow :kind-mismatch 20 [20 nil nil 0]]");
}

test "integration: core.nx composite + HOFs" {
    try expectOutput("(reduce + 0 (range 10))", "45");
    try expectOutput("(count (filter odd? (range 10)))", "5");
    try expectOutput("(reverse (map inc [1 2 3]))", "(4 3 2)");
}

// =============================================================================
// Collection utilities
// =============================================================================

test "integration: vector / vec" {
    try expectOutput("(vector 1 2 3)", "[1 2 3]");
    try expectOutput("(vector)", "[]");
    try expectOutput("(vec (list :a :b :c))", "[:a :b :c]");
    try expectOutput("(vec nil)", "[]");
}

test "integration: hash-map / hash-set" {
    try expectOutput("(hash-set 1 2 3 1 2)", "#{1 2 3}");
    // hash-map iteration order is unspecified (HAMT); test via count + get
    try expectOutput("(count (hash-map :a 1 :b 2 :c 3))", "3");
    try expectOutput("(get (hash-map :a 1 :b 2) :a)", "1");
}

test "integration: assoc / dissoc" {
    try expectOutput("(get (assoc {:a 1} :b 2) :b)", "2");
    try expectOutput("(get (assoc nil :x 99) :x)", "99");
    try expectOutput("(contains? (dissoc {:a 1 :b 2} :a) :a)", "false");
    try expectOutput("(contains? (dissoc {:a 1 :b 2} :a) :b)", "true");
}

test "integration: get and get-in never throw on a value that is not a collection" {
    try expectOutput("[(get 5 :a) (get 5 :a :d) (get :k :a) (get inc 0 :d) (get-in {:a 1} [:a :b]) (get-in {:a 1} [:a :b] :d)]", "[nil :d nil :d nil :d]");
}

test "integration: small Clojure agreements: nth of nil, empty of a string, conj and keyword of nil, compare of qualified names, into with no source" {
    try expectOutput("[(nth nil 3) (empty \"abc\") (conj nil) (keyword nil) (compare :b :a/c) (compare :a/c :b) (into []) (into) (into [1])]", "[nil nil nil nil -1 1 [] [] [1]]");
    try expectOutput("[(conj) (conj [1]) (drop-last [1 2 3]) (drop-last nil)]", "[[] [1] (1 2) ()]");
}

test "integration: range over floats, as Clojure's" {
    try expectOutput("[(range 0 1 0.25) (range 3.0) (range 0.5 2) (range 1 0 -0.5)]", "[(0 0.25 0.5 0.75) (0 1 2) (0.5 1.5) (1 0.5)]");
}

test "integration: nexis.math/round is Java's Math/round, exact near one half and past 2^52" {
    try expectOutput("[(nexis.math/round 0.49999999999999994) (nexis.math/round 4503599627370497.0) (nexis.math/round -0.5) (nexis.math/round 0.5)]", "[0 4503599627370497 0 1]");
}

test "integration: cons onto any seqable" {
    try expectOutput("[(cons 1 #{2}) (cons 1 {:a 1}) (cons 1 \"ab\") (cons 0 [1 2]) (cons 0 nil) (cons 0 (list))]", "[(1 2) (1 [:a 1]) (1 a b) (0 1 2) (0) (0)]");
}

test "integration: get (2-arg + 3-arg default)" {
    try expectOutput("(get {:a 1} :a)", "1");
    try expectOutput("(get {:a 1} :missing)", "nil");
    try expectOutput("(get {:a 1} :missing :default)", ":default");
    try expectOutput("(get [10 20 30] 1)", "20");
    try expectOutput("(get [10 20 30] 99 :oob)", ":oob");
    try expectOutput("(get #{1 2 3} 2)", "2");
    try expectOutput("(get nil :anything :fallback)", ":fallback");
}

test "integration: contains?" {
    try expectOutput("(contains? {:a 1} :a)", "true");
    try expectOutput("(contains? {:a 1} :b)", "false");
    try expectOutput("(contains? #{1 2 3} 2)", "true");
    try expectOutput("(contains? [10 20 30] 1)", "true");
    try expectOutput("(contains? [10 20 30] 99)", "false");
    try expectOutput("(contains? nil :anything)", "false");
}

test "integration: keys / vals" {
    try expectOutput("(count (keys {:a 1 :b 2 :c 3}))", "3");
    try expectOutput("(count (vals {:a 1 :b 2 :c 3}))", "3");
    try expectOutput("(keys nil)", "nil");
    try expectOutput("(vals nil)", "nil");
}

test "integration: conj (kind-specific)" {
    try expectOutput("(conj nil 1 2 3)", "(3 2 1)"); // Clojure reverses for nil/list
    try expectOutput("(conj (list 1 2 3) 0)", "(0 1 2 3)");
    try expectOutput("(conj [10 20] 30 40)", "[10 20 30 40]");
    try expectOutput("(get (conj {:a 1} [:b 2]) :b)", "2");
    try expectOutput("(contains? (conj #{1 2} 3 4) 4)", "true");
}

test "integration: collection ops compose with HOFs" {
    try expectOutput(
        \\(reduce (fn* [m k] (assoc m k true)) {} [:a :b :c])
    , "{:a true, :b true, :c true}");
    try expectOutput("(count (filter (fn* [x] (contains? #{1 3 5} x)) [1 2 3 4 5]))", "3");
}

// =============================================================================
// VM.callValue + apply + HOFs + first-class arithmetic
// =============================================================================

test "integration: variadic native + / * / - / <" {
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

test "integration: value equality `=` (variadic, structural)" {
    try expectOutput("(=)", "true");
    try expectOutput("(= 1)", "true");
    try expectOutput("(= 1 1 1)", "true");
    try expectOutput("(= 1 1 2)", "false");
    try expectOutput("(= :a :a)", "true");
    try expectOutput("(= [1 2 3] [1 2 3])", "true");
    try expectOutput("(= {:a 1} {:a 1})", "true");
}

test "integration: inc / dec / not / predicates" {
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

test "integration: apply (no leading args)" {
    try expectOutput("(apply + (list 1 2 3 4 5))", "15");
    try expectOutput("(apply * [2 3 4])", "24");
}

test "integration: apply with leading args" {
    try expectOutput("(apply + 10 (list 1 2 3))", "16");
    try expectOutput("(apply + 1 2 3 (list 4 5))", "15");
}

test "integration: apply with user fn" {
    try expectOutput(
        \\(do (defn square [x] (* x x))
        \\    (apply square (list 7)))
    , "49");
}

test "integration: map (eager) on list + vector" {
    try expectOutput("(map inc (list 1 2 3 4))", "(2 3 4 5)");
    try expectOutput("(map inc [10 20 30])", "(11 21 31)");
    try expectOutput("(map inc nil)", "()");
}

test "integration: reduce" {
    try expectOutput("(reduce + 0 [1 2 3 4 5])", "15");
    try expectOutput("(reduce + 0 (list))", "0");
    try expectOutput("(reduce * 1 [1 2 3 4])", "24");
    try expectOutput("(reduce + 100 nil)", "100");
}

test "integration: filter" {
    try expectOutput("(filter odd? [1 2 3 4 5 6 7])", "(1 3 5 7)");
    try expectOutput("(filter pos? [-2 -1 0 1 2])", "(1 2)");
    try expectOutput("(filter some? (list 1 nil 2 nil 3))", "(1 2 3)");
}

test "integration: map with user lambda" {
    try expectOutput(
        \\(map (fn* [x] (* x x)) [1 2 3 4])
    , "(1 4 9 16)");
}

test "integration: reduce with user lambda" {
    try expectOutput(
        \\(reduce (fn* [acc x] (+ acc (* x x))) 0 [1 2 3])
    , "14");
}

test "integration: throw inside map propagates to outer catch" {
    try expectOutput(
        \\(try (map (fn* [x] (throw :boom)) [1 2 3])
        \\     (catch any e e))
    , ":boom");
}

test "integration: throw inside reduce propagates" {
    try expectOutput(
        \\(try (reduce (fn* [acc x]
        \\               (if (< 10 acc)
        \\                 (throw :too-big)
        \\                 (+ acc x)))
        \\             0 [1 5 8 2])
        \\     (catch any e e))
    , ":too-big");
}

test "integration: throw through apply" {
    try expectOutput(
        \\(try (apply (fn* [x] (throw :inside-apply)) (list 99))
        \\     (catch any e e))
    , ":inside-apply");
}

test "integration: HOFs composed" {
    try expectOutput(
        \\(reduce + 0 (filter odd? (map inc [0 1 2 3 4 5])))
    , "9");
    // (map inc xs) => (1 2 3 4 5 6)
    // (filter odd? ...) => (1 3 5)
    // (reduce + 0 ...) => 9
}

// =============================================================================
// User-defined defmacro
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

test "defmacro: a macro call nested in calls and host macros expands exactly once" {
    try expectOutput(
        \\(def counter (atom 0))
        \\(defmacro m [] (swap! counter inc) 1)
        \\(+ 1 (+ 1 (+ 1 (m))))
        \\(defn g [y] (let [z (m)] (when true (-> y (+ z) (if (m) 0)))))
        \\@counter
    , "3");
}

test "macroexpand: the depth limit counts expansions in a row, not nesting" {
    // 300 nested `let`s: each is one expansion at its own position.
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(testing.allocator);
    for (0..300) |_| try src.appendSlice(testing.allocator, "(let [a 1] ");
    try src.appendSlice(testing.allocator, "a");
    for (0..300) |_| try src.append(testing.allocator, ')');
    try expectOutput(src.items, "1");
    // A macro whose expansion is itself, forever, still trips it.
    try expectProgramError("(defmacro forever [] `(forever)) (forever)", compile.CompileError.MacroDepthExceeded);
}

/// Run `setup`, then expand `src` as the compiler would and expect
/// the expansion to fail with `message` recorded against the source
/// text `at` (MACROEXPAND.md §8).
fn expectMacroFailure(setup: []const u8, src: []const u8, message: []const u8, at: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run(setup);
    var arena = std.heap.ArenaAllocator.init(program.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try reader_mod.parser.parseForm(a, src);
    defer parsed.parser.deinit();
    var rdr = reader_mod.Reader.init(a, src);
    defer rdr.deinit();
    const form = try rdr.readOneForm(parsed.sexp);
    var ctx = expand_mod.ExpandContext{
        .allocator = a,
        .interner = program.interner,
        .host_macros = &program.host_macros,
        .namespace = program.registry.current,
        .registry = program.registry,
        .value_heap = program.v.ensureHeap(),
    };
    try testing.expectError(error.MalformedMacroCall, expand_mod.expandForm(&ctx, null, form));
    const failure = ctx.failure orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(message, failure.message);
    try testing.expectEqualStrings(at, src[failure.span.pos..][0..failure.span.len]);
}

test "defmacro: a failing macro call names the macro and the cause, at the call" {
    try expectMacroFailure("(defmacro m [] (throw (ex-info \"bad macro input\" {:x 1})))", "(do 1 (m))", "macro m threw bad macro input", "(m)");
    try expectMacroFailure("(defmacro m [] (throw :nope))", "(when true (m))", "macro m threw :nope", "(m)");
    try expectMacroFailure("(defmacro m [a] a)", "(do (m))", "macro m takes 1 argument, got 0", "(m)");
    try expectMacroFailure("(defmacro m [a b & c] a)", "(m 1)", "macro m takes 2 or more arguments, got 1", "(m 1)");
    try expectMacroFailure("(defmacro m [] (first 1))", "(m)", "macro m failed: KindMismatch", "(m)");
    try expectMacroFailure("(defn g [x] x) (defmacro m [] (g))", "(m)", "macro m failed: ArityMismatch: g takes 1 argument, got 0", "(m)");
    try expectMacroFailure("(defmacro m [] (fn [] 1))", "(m)", "a macro returned a function, which is not a form", "(m)");
    try expectMacroFailure("(defmacro m [a] a)", "(m (+ 1 `x))", "a syntax-quote is not data a macro can take", "`x");
}

test "defmacro: parameters destructure and overload clauses dispatch, as for defn" {
    try expectOutputProgram("(defmacro m [[a b] & body] `(+ ~a ~b ~@body)) (m [1 2] 3)", "6");
    try expectOutputProgram("(defmacro m ([x] x) ([x y] `(+ ~x ~y))) [(m 1) (m 1 2)]", "[1 3]");
    try expectOutputProgram("(defmacro m [{:keys [k] :or {k 9}}] k) [(m {:k 5}) (m {})]", "[5 9]");
    try expectOutputProgram(
        \\(defmacro with-x [[sym init] & body] `(let [~sym ~init] ~@body))
        \\(with-x [y 4] (* y y))
    , "16");
    try expectOutputProgram("(defmacro m \"doc\" {:added \"1\"} [x] x) [(m 1) (select-keys (meta (var m)) [:doc :added :arglists])]", "[1 {:doc doc, :added 1, :arglists ([x])}]");
}

test "integration: defmacro — macro can use already-defined macros in body" {
    // twice's body uses unless (a macro defined above it);
    // when outer is invoked, the macro fn body is already
    // expanded so the unless call is already turned into (if).
    try expectOutput(
        \\(do (defmacro unless [test body] `(if ~test nil ~body))
        \\    (defmacro twice [x] `(unless false ~x))
        \\    (twice :twice-got-it))
    , ":twice-got-it");
}

// =============================================================================
// Maps/sets as runtime values
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

/// `open`, then `item` n times with every `{d}` in it replaced by
/// the item's index, then `close`.
fn generated(open: []const u8, item: []const u8, n: usize, close: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try out.appendSlice(testing.allocator, open);
    for (0..n) |i| {
        var parts = std.mem.splitSequence(u8, item, "{d}");
        try out.appendSlice(testing.allocator, parts.first());
        while (parts.next()) |part| {
            try out.print(testing.allocator, "{d}", .{i});
            try out.appendSlice(testing.allocator, part);
        }
    }
    try out.appendSlice(testing.allocator, close);
    return out.toOwnedSlice(testing.allocator);
}

test "literals: a computed collection or call of any size builds, its items evaluated left to right" {
    // Each form has more items than a routine has slots (COMPILER.md
    // §4.4), so each is built in chunks.
    const cases = [_]struct { open: []const u8, item: []const u8, close: []const u8, out: []const u8 }{
        .{ .open = "(def n (atom 0)) (def v [", .item = " (swap! n inc)", .close = "]) [(count v) (= v (vec (range 1 10001))) (vector? v)]", .out = "[10000 true true]" },
        .{ .open = "(def n (atom 0)) (def l (list", .item = " (swap! n inc)", .close = ")) [(count l) (= l (range 1 10001)) (list? l)]", .out = "[10000 true true]" },
        .{ .open = "(def x 1) (+", .item = " x", .close = ")", .out = "10000" },
        .{ .open = "(def n (atom 0)) (def m {", .item = " {d} (swap! n inc)", .close = "}) [(count m) (get m 0) (get m 9999)]", .out = "[10000 1 10000]" },
        .{ .open = "(def x 0) (def s #{", .item = " (+ x {d})", .close = "}) [(count s) (contains? s 9999) (set? s)]", .out = "[10000 true true]" },
        .{ .open = "(def x 1) (def q `(", .item = " ~x", .close = ")) [(count q) (seq? q)]", .out = "[10000 true]" },
        .{ .open = "(def x [1]) (def q `(", .item = " ~@x", .close = ")) [(count q) (seq? q)]", .out = "[10000 true]" },
    };
    for (cases) |c| {
        const src = try generated(c.open, c.item, 10_000, c.close);
        defer testing.allocator.free(src);
        try expectOutputProgram(src, c.out);
    }
}

test "literals: a map built in chunks keeps the later of two equal keys" {
    const src = try generated("(def m {", " (* {d} 0) {d}", 5000, "}) [(count m) (get m 0)]");
    defer testing.allocator.free(src);
    try expectOutputProgram(src, "[1 4999]");
}

test "compile: a routine of more than 4096 constants, Vars and closures runs" {
    // Each distinct literal is a constant, each (def ...) a Var, each
    // fn a closure of the one routine the let compiles to.
    const cases = [_]struct { open: []const u8, item: []const u8, close: []const u8, out: []const u8 }{
        .{ .open = "(let [x 0 a (atom 0)]", .item = " (swap! a + (+ x {d}))", .close = " [@a (+ x 4999) (- x 4999)])", .out = "[12497500 4999 -4999]" },
        .{ .open = "(let [a (atom [])]", .item = " (swap! a conj \"s{d}\")", .close = " [(count @a) (last @a)])", .out = "[5000 s4999]" },
        .{ .open = "(let [x 1]", .item = " (def v{d} (+ x {d}))", .close = " [v0 v4999 (+ v4998 1) (var v4999)])", .out = "[1 5000 5000 #'user/v4999]" },
        .{ .open = "(let [x 1 a (atom [])]", .item = " (swap! a conj (fn [] (+ x {d})))", .close = " [(count @a) ((last @a)) ((first @a))])", .out = "[5000 5000 1]" },
    };
    for (cases) |c| {
        const src = try generated(c.open, c.item, 5000, c.close);
        defer testing.allocator.free(src);
        try expectOutputProgram(src, c.out);
    }
}

// =============================================================================
// Catchable VmErrors
// =============================================================================
//
// Recoverable VmError variants are translated into keyword Values
// when an active handler can catch them. Without a handler, the raw
// VmError propagates unchanged.

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
    const compiled = try compile.compileSourceWith(arena.allocator(), "(+ 1 :hello)", .{ .namespace = ns, .interner = interner, .host_macros = &host_macros });
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
// Anon-fn #(...) shorthand
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

test "anon-fn: % is found inside maps, sets, nested vectors and @" {
    try expectOutput("(#(do {:a %}) 1)", "{:a 1}");
    try expectOutput("(#(do #{%}) 1)", "#{1}");
    try expectOutput("(#(vector [%1 {:k %2}]) 1 2)", "[[1 {:k 2}]]");
    try expectOutput("(#(inc @%) (atom 1))", "2");
    try expectOutput("(#(do {% %2}) :k :v)", "{:k :v}");
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
    , "(user/pair 1 2)");
}

// =============================================================================
// Atoms (docs/ATOM.md)
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
//   §6 codec :unserializable (nested atom)       → db :unserializable test
//   §9 catchable errors                          → error keyword tests

test "atom: ctor + atom? predicate" {
    try expectOutput("(atom? (atom 0))", "true");
    try expectOutput("(atom? (atom :anything))", "true");
    try expectOutput("(atom? 1)", "false");
    try expectOutput("(atom? :keyword)", "false");
    try expectOutput("(atom? nil)", "false");
    try expectOutput("(atom? [1 2])", "false");
}

test "atom: deref via @a, (deref a), (db/deref a)" {
    try expectOutput("@(atom 42)", "42");
    try expectOutput("(deref (atom 42))", "42");
    try expectOutput("(db/deref (atom 42))", "42");
    try expectOutput("@(atom :keyword)", ":keyword");
    try expectOutput("@(atom nil)", "nil");
    try expectOutput("@(atom [1 2 3])", "[1 2 3]");
}

test "atom: identity equality (= a a) vs (= (atom v) (atom v))" {
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

test "atom: reset! sets value, returns new value" {
    try expectOutput("(let [a (atom 0)] (reset! a 42))", "42");
    try expectOutput("(let [a (atom 0)] (reset! a 42) @a)", "42");
    try expectOutput("(let [a (atom :before)] (reset! a :after) @a)", ":after");
}

test "atom: swap! with inc / + / variadic args" {
    try expectOutput("(let [a (atom 0)] (swap! a inc))", "1");
    try expectOutput("(let [a (atom 0)] (swap! a inc) (swap! a inc) @a)", "2");
    try expectOutput("(let [a (atom 10)] (swap! a + 32))", "42");
    try expectOutput("(let [a (atom 10)] (swap! a + 1 2 3 4))", "20");
}

test "atom: swap! rollback on throw — value unchanged" {
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

test "atom: swap! re-entrancy detection (:atom-re-entry)" {
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

test "atom: swap! deref of in-flight atom is allowed" {
    // deref does NOT touch in_flight, so a swap! function may
    // legally call @a (e.g., to inspect the staging value).
    // This is the canonical "side-effecting log inside swap!"
    // pattern.
    try expectOutput(
        \\(let [a (atom 7)]
        \\  (swap! a (fn [old] (+ old @a))))
    , "14");
}

test "atom: swap-vals! returns [old new] vector" {
    try expectOutput("(let [a (atom 10)] (swap-vals! a inc))", "[10 11]");
    try expectOutput("(let [a (atom 10)] (swap-vals! a inc) @a)", "11");
    try expectOutput(
        \\(let [a (atom 1)] (swap-vals! a + 2 3 4))
    , "[1 10]");
}

test "atom: swap-vals! rollback on throw" {
    try expectOutput(
        \\(let [a (atom 1)]
        \\  (try (swap-vals! a (fn [_] (throw :bad))) (catch any e :caught))
        \\  @a)
    , "1");
}

test "atom: compare-and-set! identity-based" {
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

test "atom: compare-and-set! uses identity, not =" {
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

test "atom: reset!/swap!/CAS type errors caught as :kind-mismatch" {
    try expectOutput("(try (reset! 1 2) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (swap! 1 inc) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (compare-and-set! 1 1 2) (catch any e e))", ":kind-mismatch");
}

test "atom: swap! with non-callable f surfaces :not-callable" {
    try expectOutput(
        \\(try (swap! (atom 1) 2) (catch any e e))
    , ":not-callable");
}

test "atom: atoms as map keys distinguish by identity" {
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

test "atom: universal deref still serves Vars" {
    // deref over Var: the .atom arm does not displace the Var arm.
    try expectOutput("(do (def x 5) (deref (var x)))", "5");
}

test "atom: @-lowering is not lexically shadowable" {
    // Reader-macro `@` must NOT be captured by a local binding
    // named `deref`. `@x` lowers to QUALIFIED `(nexis.core/deref x)`
    // which resolves through the registry, not through lexical
    // fall-through.
    try expectOutput(
        \\(let [deref (fn [_] 42)
        \\      a    (atom 5)]
        \\  @a)
    , "5");
    // Note: `(def deref ...)` at top level does NOT prove a
    // separate shadowing case because auto-refer makes `def` of an
    // auto-referred name UPDATE the shared `nexis.core/deref` Var in
    // place (compile.zig addVarRef walks the parent chain). That is
    // general language behavior, not specific to atoms or `@`. The
    // lexical-binding case above is the load-bearing one.
}

test "atom: self-reference does not break equality / count" {
    // An atom holding itself satisfies (= @a a). Pins the
    // GC self-reference safety + cycle behavior at the
    // language level.
    try expectOutput(
        \\(let [a (atom nil)] (reset! a a) (= @a a))
    , "true");
}

// =============================================================================
// Core string ops
// =============================================================================
//
// User-facing string ops index by Unicode SCALAR (codepoint), not
// byte. Test coverage hits four corners:
//   - ASCII baseline                  → count/nth/subs on ASCII
//   - Multi-byte codepoint sanity     → count of "é", "🦀", mixed
//   - Bounds                          → :index-out-of-bounds keyword
//   - str shape                       → Clojure-canonical for nil/kw/sym/atom

test "string: string?: kind predicate" {
    try expectOutput("(string? \"hi\")", "true");
    try expectOutput("(string? \"\")", "true");
    try expectOutput("(string? :hello)", "false");
    try expectOutput("(string? 1)", "false");
    try expectOutput("(string? nil)", "false");
    try expectOutput("(string? [\"a\"])", "false");
}

test "string: count: ASCII + multibyte codepoints" {
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

test "string: empty?: byteLen == 0 fast path" {
    try expectOutput("(empty? \"\")", "true");
    try expectOutput("(empty? \"x\")", "false");
    try expectOutput("(empty? \"🦀\")", "false");
}

test "string: nth on string: returns Kind.char at codepoint index" {
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

test "string: nth on string: out-of-bounds + default" {
    try expectOutput("(try (nth \"ab\" 2) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (nth \"\" 0) (catch any e e))", ":index-out-of-bounds");
    // Negative index: same keyword.
    try expectOutput("(try (nth \"ab\" -1) (catch any e e))", ":index-out-of-bounds");
    // Default branch: out-of-bounds returns default instead of throwing.
    try expectOutput("(nth \"ab\" 5 :missing)", ":missing");
    try expectOutput("(nth \"ab\" -1 :neg)", ":neg");
}

test "string: subs: codepoint indices, two- and three-arity" {
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

test "string: subs: bounds errors as :index-out-of-bounds" {
    try expectOutput("(try (subs \"ab\" -1) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (subs \"ab\" 0 -1) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (subs \"ab\" 3) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try (subs \"ab\" 0 3) (catch any e e))", ":index-out-of-bounds");
    // start > end.
    try expectOutput("(try (subs \"abc\" 2 1) (catch any e e))", ":index-out-of-bounds");
}

test "string: subs: kind-mismatch on non-string / non-fixnum index" {
    try expectOutput("(try (subs 42 0) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (subs \"ab\" :nope) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (subs \"ab\" 0 :nope) (catch any e e))", ":kind-mismatch");
}

test "string: str: Clojure-canonical concat shape" {
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
    // Atom prints opaquely as `#<atom>` (deterministic).
    try expectOutput("(str (atom 1))", "#<atom>");
}

test "string: str of a collection prints its elements readably, as Clojure's toString does" {
    try expectOutput("(str [\"a\" \\b])", "[\"a\" \\b]");
    try expectOutput("(str {:a \"b\"})", "{:a \"b\"}");
    try expectOutput("(str \"x\" [nil \"y\"] \\z)", "x[nil \"y\"]z");
    try expectOutput("(str '(\"q\"))", "(\"q\")");
}

test "string: str: result is itself a string" {
    try expectOutput("(string? (str \"a\" 1 :b))", "true");
    try expectOutput("(count (str \"héllo\"))", "5");
}

test "string: string? after subs returns true" {
    try expectOutput("(string? (subs \"hello\" 1 4))", "true");
}

test "string: nth: kind-mismatch fires on non-indexable receiver" {
    // The kind check sits ABOVE the index-sign branch, so the
    // negative-index + default path never returns the default for
    // a non-indexable receiver. `(nth 123 -1 :d)` must be
    // `:kind-mismatch`, NOT `:d`.
    try expectOutput("(try (nth 123 -1 :d) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nth :keyword 0 :d) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nth {:a 1} 0 :d) (catch any e e))", ":kind-mismatch");
    // Strings + vectors + lists + nil honor the default-on-OOB
    // contract.
    try expectOutput("(nth \"ab\" -1 :d)", ":d");
    try expectOutput("(nth nil 0 :d)", ":d");
    try expectOutput("(nth [1 2] 5 :d)", ":d");
}

test "string: subs: boundary case (start == end at count)" {
    // `(subs s n n)` for any `n` in `[0, count]` returns `""`.
    // The end-at-end boundary succeeds rather than throwing.
    try expectOutput("(subs \"abc\" 3 3)", "");
    try expectOutput("(count (subs \"abc\" 3 3))", "0");
}

test "string: nth: char-at-default on out-of-bounds + multibyte" {
    // `(nth s i :default)` returns default when
    // `i >= codepointCount`. Multi-byte boundary.
    try expectOutput("(nth \"é\" 0 :default)", "é");
    try expectOutput("(nth \"é\" 1 :default)", ":default");
}

test "string: end-to-end DB persistence of a string value" {
    // Direct test that string literals survive the entire
    // compile → durable codec → emdb → decode → user path. The
    // todo-app demo uses keyword values; this test pins the
    // string Value codec round-trip explicitly.
    try expectOutputProgramWithStore("strings",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def r   (db/ref conn :strings "k"))
        \\  (with-tx [tx conn] (db/put! tx r "hello-utf8-é-🦀"))
        \\  (with-read-tx [tx conn] (db/get tx r)))
    , "hello-utf8-é-🦀");
}

test "spit :append adds to the file; slurp reads it back" {
    try expectOutputProgramWithStore("spit-append",
        \\(do (spit "@STORE@" "a") (spit "@STORE@" [1 "b"] :append true) (spit "@STORE@" nil :append true) (slurp "@STORE@"))
    , "a[1 \"b\"]");
}

test "db/scan seeks to the start bound and stops before the end bound" {
    try expectOutputProgramWithStore("seam-scan-range",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (with-tx [tx conn]
        \\    (db/put! tx (db/ref conn :range :a) 1)
        \\    (db/put! tx (db/ref conn :range :b) 2)
        \\    (db/put! tx (db/ref conn :range :c) 3)
        \\    (db/put! tx (db/ref conn :range :d) 4))
        \\  (with-read-tx [t conn]
        \\    [(db/scan t :range :b)
        \\     (db/scan t :range :bb :d)
        \\     (db/scan t :range :e)
        \\     (db/scan t :range :a :a)
        \\     (db/scan t :none)]))
    , "[[[:b 2] [:c 3] [:d 4]] [[:c 3]] [] [] []]");
}

test "storage failures surface as :db/<reason> keywords inside try" {
    // 8192-byte key: past the key bound of a 16 KiB page.
    try expectOutputProgramWithStore("seam-errors",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def long-key (loop [s "k" n 0] (if (< n 13) (recur (str s s) (inc n)) s)))
        \\  [(try (with-tx [tx conn] (db/put! tx (db/ref conn :t long-key) 1))
        \\        (catch any e e))
        \\   (try (db/put-key! (db/ref conn :t long-key) 1)
        \\        (catch any e e))
        \\   (try (db/open "/nexis-no-such-directory/sub/store.edb")
        \\        (catch any e e))])
    , "[:db/key-too-large :db/key-too-large :db/open-failed]");
}

test "a value nested 100 000 deep is stored and read back through a durable ref" {
    // CODEC.md §2.7: the codec bounds no nesting depth.
    try expectOutputProgramWithStore("seam-deep",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (defn nest [n] (loop [i 0 acc nil] (if (< i n) (recur (inc i) [i acc]) acc)))
        \\  (defn depth [v] (loop [v v n 0] (if (vector? v) (recur (second v) (inc n)) n)))
        \\  (db/put-key! (db/ref conn :t :deep) (nest 100000))
        \\  (let [v (db/get-key (db/ref conn :t :deep))]
        \\    [(depth v) (first v) (first (second v))]))
    , "[100000 99999 99998]");
}

test "the VM keeps running after a caught storage failure" {
    try expectOutputProgramWithStore("seam-errors-resume",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def long-key (loop [s "k" n 0] (if (< n 13) (recur (str s s) (inc n)) s)))
        \\  (with-tx [tx conn] (db/put! tx (db/ref conn :t :k) 41))
        \\  (def caught (try (with-tx [tx conn] (db/put! tx (db/ref conn :t long-key) 1))
        \\                   (catch any e e)))
        \\  [caught (inc (with-read-tx [t conn] (db/get t (db/ref conn :t :k))))])
    , "[:db/key-too-large 42]");
}

test "db/close: a ref, a connection and a second close after it are :db-closed or nil" {
    try expectOutputProgramWithStore("close-after",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (def r (db/ref c :t "k"))
        \\  (db/put-key! r 42)
        \\  (db/close c)
        \\  [(try @r (catch any e e))
        \\   (try (db/put-key! r 1) (catch any e e))
        \\   (db/close c)
        \\   (try (db/ref c :t "k") (catch any e e))
        \\   (try (db/begin-read c) (catch any e e))])
    , "[:db-closed :db-closed nil :db-closed :db-closed]");
}

test "db/close: refused while a transaction of the connection is open" {
    try expectOutputProgramWithStore("close-busy",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (def r (db/ref c :t "k"))
        \\  (def tx (db/begin-read c))
        \\  (def wx (db/begin-write c))
        \\  [(try (db/close c) (catch any e e))
        \\   (db/abort-read! tx)
        \\   (try (db/close c) (catch any e e))
        \\   (db/abort-write! wx)
        \\   (db/close c)
        \\   (try (db/get tx r) (catch any e e))])
    , "[:db/busy nil :db/busy nil nil :tx-closed]");
}

test "db/reduce-tree walks the tree as it was when the walk began, whatever the callback writes to it" {
    try expectOutputProgramWithStore("walk-writes",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (with-tx [tx c] (dotimes [i 300] (db/put! tx (db/ref c :t (str "k" (+ 100 i))) i)))
        \\  (with-tx [tx c]
        \\    [(db/reduce-tree tx :t
        \\       (fn [acc k v]
        \\         (db/put! tx (db/ref c :t (str (name k) "x")) v)
        \\         (db/delete! tx (db/ref c :t "k399"))
        \\         (db/alter! tx (db/ref c :t "k100") inc)
        \\         (when (= k :k100)
        \\           (db/reduce-tree tx :t (fn [a k v] (db/put! tx (db/ref c :t (str (name k) "y")) v) a) nil))
        \\         (+ acc v))
        \\       0)
        \\     (count (db/scan tx :t))
        \\     (db/get tx (db/ref c :t "k100"))
        \\     (db/get tx (db/ref c :t "k399"))]))
    , "[44850 899 300 nil]");
}

test "db: a callback cannot finish the transaction db/alter! or db/reduce-tree is running it in" {
    try expectOutputProgramWithStore("held-tx",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (def r (db/ref c :t "k0"))
        \\  (with-tx [tx c] (dotimes [i 300] (db/put! tx (db/ref c :t (str "k" i)) i)))
        \\  [(try (with-tx [tx c] (db/alter! tx r (fn [v] (db/abort-write! tx) (inc v)))) (catch any e e))
        \\   (try (with-tx [tx c] (db/alter! tx r (fn [v] (db/commit! tx) (inc v)))) (catch any e e))
        \\   (with-tx [tx c] (db/alter! tx r (fn [v] (db/alter! tx (db/ref c :t "k1") inc) (inc v))))
        \\   [(db/get-key r) (db/get-key (db/ref c :t "k1"))]
        \\   (let [wt (db/begin-write c)]
        \\     [(try (db/reduce-tree wt :t (fn [a k v] (when (= a 0) (db/abort-write! wt)) (inc a)) 0) (catch any e e))
        \\      (db/reduce-tree wt :t (fn [a k v] (inc a)) 0)
        \\      (db/commit! wt)])
        \\   (let [rt (db/begin-read c)]
        \\     [(try (db/reduce-tree rt :t (fn [a k v] (when (= a 0) (db/abort-read! rt)) (inc a)) 0) (catch any e e))
        \\      (db/snapshot? rt)
        \\      (db/abort-read! rt)
        \\      (db/snapshot? rt)])])
    , "[:db/busy :db/busy 1 [1 2] [:db/busy 300 nil] [:db/busy true nil false]]");
}

test "db/close: a stale ref never reaches a store opened after the close" {
    var a = try SeamStore.init("stale-a");
    defer a.deinit();
    var b = try SeamStore.init("stale-b");
    defer b.deinit();
    const tmpl = try a.source(
        \\(do
        \\  (def c1 (db/open "@STORE@"))
        \\  (def r (db/ref c1 :t :k))
        \\  (db/put-key! r :from-a)
        \\  (db/close c1)
        \\  (def c2 (db/open "@OTHER@"))
        \\  (db/put-key! (db/ref c2 :t :k) :from-b)
        \\  [(try (db/put-key! r :stale) (catch any e e))
        \\   (db/get-key (db/ref c2 :t :k))])
    );
    defer testing.allocator.free(tmpl);
    const src = try std.mem.replaceOwned(u8, testing.allocator, tmpl, "@OTHER@", b.path);
    defer testing.allocator.free(src);
    try expectOutputProgram(src, "[:db-closed :from-b]");
}

/// The store file behind a `db/open` or `d/connect` connection Value.
fn storeFileOf(v: value_mod.Value) !*nx.db.StoreFile {
    return switch (v.kind()) {
        .db_connection => @as(*nx.db.Connection, @ptrFromInt(v.payload)).file,
        .nextomic_conn => @as(*nx.nextomic.Conn, @ptrCast(@alignCast(nx.nextomic_handle.connPtr(v)))).store.file,
        else => error.TestUnexpectedResult,
    };
}

/// Run `setup`, which defines `a` and `b` as two connections to the
/// store `@STORE@`; check that both hold one store file; only then run
/// `body`, whose second writer would wait forever on a second
/// environment of the file.
fn expectSharedWriter(name: []const u8, setup: []const u8, body: []const u8, expected: []const u8) !void {
    var store = try SeamStore.init(name);
    defer store.deinit();
    const src = try store.source(setup);
    defer testing.allocator.free(src);
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run(src);
    try testing.expect(try storeFileOf(try program.run("a")) == try storeFileOf(try program.run("b")));
    try harness.expectResult(&program, body, try program.run(body), expected);
}

test "db/open: two connections to one file share its writer; a second write is :db/busy" {
    try expectSharedWriter("shared-writer",
        \\(def a (db/open "@STORE@"))
        \\(def b (db/open "./@STORE@"))
    ,
        \\(def t1 (db/begin-write a))
        \\[(try (db/begin-write b) (catch any e e))
        \\ (try (db/put-key! (db/ref b :t :x) 1) (catch any e e))
        \\ (do (db/abort-write! t1) (db/put-key! (db/ref b :t :x) 2) (db/get-key (db/ref a :t :x)))
        \\ (do (db/close a) (db/get-key (db/ref b :t :x)))]
    , "[:db/busy :db/busy 2 2]");
}

test "db/* and Nextomic on one file: a write inside the other's transaction is refused, not waited on" {
    try expectSharedWriter("shared-nextomic",
        \\(def a (nextomic/connect "@STORE@"))
        \\(nextomic/transact! a [{:db/ident :n :db/valueType :db.type/long :db/cardinality :db.cardinality/one}])
        \\(def b (db/open "@STORE@"))
        \\(def r (db/ref b :t :k))
    ,
        \\[(try (nextomic/transact! a [[:db.fn/call (fn [db] (db/put-key! r 1) [])]]) (catch any e e))
        \\ (try (with-tx [tx b] (db/put! tx r 2) (nextomic/transact! a [{:n 1}])) (catch any e e))
        \\ (try (with-tx [tx b] (nextomic/with a [{:n 5}] (fn [db report] :x))) (catch any e e))
        \\ (db/get-key r)
        \\ (count (:tx-data (nextomic/transact! a [[:db.fn/call (fn [db] (when (db/get-key r) [{:n 9}]))]])))
        \\ (do (nextomic/transact! a [{:n 3}]) (db/put-key! r 4) (db/get-key r))
        \\ (nextomic/q '[:find ?v :where [_ :n ?v]] (nextomic/db a))]
    , "[:db/busy :nextomic/nested :nextomic/nested nil 1 4 #{[3]}]");
}

test "db: Nextomic's nx/ trees are not reachable through db/*" {
    try expectOutputProgramWithStore("nx-trees",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  [(try (db/ref c :nx/eavt "k") (catch any e e))
        \\   (try (with-read-tx [t c] (db/scan t :nx/sys)) (catch any e e))
        \\   (try (with-read-tx [t c] (db/reduce-tree t :nx/txlog conj [])) (catch any e e))
        \\   (db/ref? (db/ref c :nxt "k"))])
    , "[:db/invalid-key :db/invalid-key :db/invalid-key true]");
}

test "db: a value with no serialized form is :unserializable" {
    try expectOutputProgramWithStore("unserializable",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  [(try (db/put-key! (db/ref c :t "f") inc) (catch :unserializable e e))
        \\   (try (with-tx [tx c] (db/put! tx (db/ref c :t "a") [1 (atom 2)])) (catch any e e))])
    , "[:unserializable :unserializable]");
}

test "outside try a storage failure is the raw DbError" {
    try expectProgramErrorWithStore("seam-errors-raw",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def long-key (loop [s "k" n 0] (if (< n 13) (recur (str s s) (inc n)) s)))
        \\  (db/put-key! (db/ref conn :t long-key) 1))
    , vm.VmError.UncaughtThrow);
}

test "db/scan and db/reduce-tree read a value that spans several overflow pages" {
    // 5 * 2^13 = 40960 bytes: three 16 KiB pages once encoded. A
    // cursor alone shows the first page; the natives must return
    // the whole value.
    try expectOutputProgramWithStore("seam-overflow",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def big (loop [s "abcde" n 0] (if (< n 13) (recur (str s s) (inc n)) s)))
        \\  (with-tx [tx conn]
        \\    (db/put! tx (db/ref conn :blobs :big) big)
        \\    (db/put! tx (db/ref conn :blobs :small) "x"))
        \\  (with-read-tx [t conn]
        \\    [(count big)
        \\     (count (nth (first (db/scan t :blobs)) 1))
        \\     (= big (nth (first (db/scan t :blobs)) 1))
        \\     (db/reduce-tree t :blobs (fn* [acc k v] (+ acc (count v))) 0)]))
    , "[40960 40960 true 40961]");
}

// =============================================================================
// nexis.string namespace
// =============================================================================
//
// Coverage map (every STDLIB.md §3 row gets at least one test):
//   case conversion maps ASCII letters, passes other bytes through
//   trim takes Java's whitespace at both ends; U+00A0 stays
//   literal split drops trailing empties unless the limit is
//   negative; vector return
//   join over any seqable (a map by entries); sep is a string
//   replace literal, all-non-overlapping, left-to-right
//
// Also pins: qualified-only (NOT auto-referred into user).

test "nexis.string: qualified-only (not auto-referred)" {
    // Bare `(lower-case ...)` from user namespace must NOT
    // resolve to nexis.string/lower-case. Short names reach it
    // only through `(require ...)` with `:refer` or `:as`, or a
    // qualified call.
    try expectOutput("(try (lower-case \"HI\") (catch any e e))", ":unbound-var");
    try expectOutput("(nexis.string/lower-case \"HI\")", "hi");
}

test "nexis.string: lower-case + upper-case: ASCII baseline" {
    try expectOutput("(nexis.string/lower-case \"HELLO\")", "hello");
    try expectOutput("(nexis.string/lower-case \"Hello, World!\")", "hello, world!");
    try expectOutput("(nexis.string/upper-case \"hello\")", "HELLO");
    try expectOutput("(nexis.string/upper-case \"MixedCASE\")", "MIXEDCASE");
    try expectOutput("(nexis.string/lower-case \"\")", "");
    try expectOutput("(nexis.string/upper-case \"\")", "");
}

test "nexis.string: lower-case + upper-case: non-ASCII passes through unchanged" {
    // ASCII letters map; non-ASCII bytes are preserved verbatim
    // (STDLIB.md §3). UTF-8 validity is preserved by
    // construction because bytes ≥ 0x80 are never modified.
    try expectOutput("(nexis.string/lower-case \"HéLLO\")", "héllo");
    try expectOutput("(nexis.string/upper-case \"abç\")", "ABç");
    try expectOutput("(nexis.string/lower-case \"🦀A\")", "🦀a");
    // Round-trip identity: codepoint count survives transform.
    try expectOutput("(count (nexis.string/lower-case \"HéLLO\"))", "5");
}

test "nexis.string: trim: whitespace on both sides" {
    try expectOutput("(nexis.string/trim \"   hello   \")", "hello");
    try expectOutput("(nexis.string/trim \"hello\")", "hello");
    try expectOutput("(nexis.string/trim \"\")", "");
    // nexis source uses `\t` `\n` `\r` escapes inside string
    // literals (the reader decodes them, FORMS.md §3).
    // The Zig source-level "\\t" produces the two bytes `\` `t`,
    // which the nexis reader then decodes into the tab byte.
    try expectOutput("(nexis.string/trim \"\\t\\nhi\\r\\n\")", "hi");
    // All-whitespace input → empty.
    try expectOutput("(nexis.string/trim \"   \\t\\n\")", "");
    // No-break space (U+00A0) is not whitespace
    // (STDLIB.md §3). Bytes 0xC2 0xA0 pass through.
    try expectOutput("(nexis.string/trim \"\u{00A0}x\u{00A0}\")", "\u{00A0}x\u{00A0}");
}

test "nexis.string: split: literal delimiter; trailing empties dropped unless the limit is negative, as in Clojure" {
    try expectOutput("(nexis.string/split \"a,b,c\" \",\")", "[a b c]");
    try expectOutput("(pr-str (nexis.string/split \"a,b,,c,,\" \",\"))", "[\"a\" \"b\" \"\" \"c\"]");
    try expectOutput("(pr-str (nexis.string/split \",,\" \",\"))", "[]");
    try expectOutput("(pr-str (nexis.string/split \"\" \",\"))", "[\"\"]");
    try expectOutput("(pr-str (nexis.string/split \"a b c\" \" \" 2))", "[\"a\" \"b c\"]");
    try expectOutput("(pr-str (nexis.string/split \"a b\" \" \" 1))", "[\"a b\"]");
    try expectOutput("(pr-str (nexis.string/split \"a,,\" \",\" -1))", "[\"a\" \"\" \"\"]");
    try expectOutput("(pr-str (nexis.string/split \"a,b,,\" \",\" 3))", "[\"a\" \"b\" \",\"]");
    try expectOutput("(nexis.string/split \"a\" \"foo\")", "[a]");
    // Multi-char delim.
    try expectOutput("(nexis.string/split \"a::b::c\" \"::\")", "[a b c]");
    // Multi-byte content split on ASCII delim (UTF-8 safety:
    // continuation bytes never match ASCII delimiter).
    try expectOutput("(nexis.string/split \"é,🦀,b\" \",\")", "[é 🦀 b]");
}

test "nexis.string: split: empty delim and non-string args" {
    // An empty separator splits between code points, as Clojure's
    // split on #"" does; non-string args are `:kind-mismatch`.
    try expectOutput("(pr-str [(nexis.string/split \"abc\" \"\") (nexis.string/split \"héb\" \"\" -1) (nexis.string/split \"abc\" \"\" 2) (nexis.string/split \"\" \"\")])", "[[\"a\" \"b\" \"c\"] [\"h\" \"é\" \"b\" \"\"] [\"a\" \"bc\"] [\"\"]]");
    try expectOutput("(try (nexis.string/split \"abc\" 42) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/split 1 \",\") (catch any e e))", ":kind-mismatch");
}

test "nexis.string: split: returns a vector" {
    try expectOutput("(let [parts (nexis.string/split \"a,b,c\" \",\")] (count parts))", "3");
    try expectOutput("(nth (nexis.string/split \"a,b,c\" \",\") 1)", "b");
}

test "nexis.string: join: 1-arity concatenates without separator" {
    try expectOutput("(nexis.string/join [])", "");
    try expectOutput("(nexis.string/join nil)", "");
    try expectOutput("(nexis.string/join [\"a\" \"b\" \"c\"])", "abc");
    try expectOutput("(nexis.string/join [1 2 :a])", "12:a");
    try expectOutput("(nexis.string/join (list :x :y :z))", ":x:y:z");
}

test "nexis.string: join: 2-arity inserts separator between elements" {
    try expectOutput("(nexis.string/join \",\" [])", "");
    try expectOutput("(nexis.string/join \",\" [\"a\"])", "a");
    try expectOutput("(nexis.string/join \",\" [\"a\" \"b\" \"c\"])", "a,b,c");
    try expectOutput("(nexis.string/join \" \" [1 2 3])", "1 2 3");
    try expectOutput("(nexis.string/join \"::\" [\"x\" \"y\" \"z\"])", "x::y::z");
}

test "nexis.string: join: any seqable; a non-string separator is :kind-mismatch" {
    try expectOutput("(nexis.string/join \",\" \"abc\")", "a,b,c");
    try expectOutput("(nexis.string/join \",\" {:a 1})", "[:a 1]");
    try expectOutput("(nexis.string/join \"-\" #{7})", "7");
    try expectOutput("(nexis.string/join [\"a\" [1 \"b\"]])", "a[1 \"b\"]");
    try expectOutput("(try (nexis.string/join :sep [1 2]) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/join 42 [1 2]) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/join \",\" 42) (catch any e e))", ":kind-mismatch");
}

test "nexis.string: join: round-trips with split" {
    // (join sep (split s sep -1)) is s: a negative limit keeps the
    // trailing empty pieces a plain split drops.
    try expectOutput(
        \\(let [s "x,y,z" sep ","]
        \\  (nexis.string/join sep (nexis.string/split s sep)))
    , "x,y,z");
    try expectOutput(
        \\(let [s "a,b,," sep ","]
        \\  [(nexis.string/join sep (nexis.string/split s sep -1)) (nexis.string/join sep (nexis.string/split s sep))])
    , "[a,b,, a,b]");
}

test "nexis.string: predicates and searches" {
    try expectOutput("(let [s \"hello world\"] [(nexis.string/starts-with? s \"hell\") (nexis.string/ends-with? s \"world\") (nexis.string/includes? s \"o w\") (nexis.string/includes? s \"x\") (nexis.string/starts-with? s \"\")])", "[true true true false true]");
    try expectOutput("[(nexis.string/index-of \"héllo\" \"l\") (nexis.string/index-of \"héllo\" \\l 3) (nexis.string/index-of \"abc\" \"z\") (nexis.string/last-index-of \"héllo\" \"l\") (nexis.string/last-index-of \"abcabc\" \"b\" 3)]", "[2 3 nil 3 1]");
    try expectOutput("[(nexis.string/blank? nil) (nexis.string/blank? \" \\t\\n\") (nexis.string/blank? \" x \")]", "[true true false]");
    try expectOutput("(try (nexis.string/starts-with? 1 \"a\") (catch any e e))", ":kind-mismatch");
    // Java's lastIndexOf finds nothing before a negative index.
    try expectOutput("[(nexis.string/last-index-of \"abc\" \"a\" -1) (nexis.string/last-index-of \"abc\" \"a\" 0) (nexis.string/index-of \"abc\" \"a\" -5)]", "[nil 0 0]");
    // Whitespace is Java's Character/isWhitespace, as Clojure's blank?
    // and trim use it: U+2003 and U+3000 are, U+00A0 is not.
    try expectOutput("(pr-str [(nexis.string/blank? \"\u{2003}\u{3000}\") (nexis.string/blank? \"\u{00A0}\") (nexis.string/blank? (str (char 28) (char 31))) (nexis.string/trim \"\u{2003}x\u{2028} \") (nexis.string/triml \"\u{3000}a\") (nexis.string/trimr \"a\u{205F}\")])", "[true false true \"x\" \"a\" \"a\"]");
}

test "nexis.string: capitalize, reverse, triml, trimr, trim-newline, split-lines" {
    try expectOutput("(pr-str [(nexis.string/capitalize \"hELLO\") (nexis.string/capitalize \"\") (nexis.string/reverse \"héllo\") (nexis.string/triml \"  a \") (nexis.string/trimr \"  a \") (nexis.string/trim-newline \"a\\r\\n\\n\") (nexis.string/trim-newline \"a \")])", "[\"Hello\" \"\" \"olléh\" \"a \" \"  a\" \"a\" \"a \"]");
    try expectOutput("(pr-str (nexis.string/split-lines \"a\\nb\\r\\nc\\n\\n\"))", "[\"a\" \"b\" \"c\"]");
}

test "nexis.set: union, intersection, difference, subset?, superset?, select, map-invert, rename-keys" {
    try expectOutput("[(nexis.set/union #{1 2} #{2 3}) (nexis.set/union) (nexis.set/intersection #{1 2 3} #{2 3 4} #{3 2}) (nexis.set/difference #{1 2 3} #{2} #{3})]", "[#{1 2 3} #{} #{2 3} #{1}]");
    try expectOutput("[(nexis.set/subset? #{1} #{1 2}) (nexis.set/subset? #{3} #{1 2}) (nexis.set/superset? #{1 2} #{2}) (nexis.set/select odd? #{1 2 3})]", "[true false true #{1 3}]");
    try expectOutput("[(nexis.set/map-invert {:a 1}) (= {:z 1 :b 2} (nexis.set/rename-keys {:a 1 :b 2} {:a :z}))]", "[{1 :a} true]");
}

test "nexis.string: replace: literal, all-non-overlapping" {
    // A char for a char, and an empty match between code points, as
    // Clojure's replace (Java's String.replace) does.
    try expectOutput("(pr-str [(nexis.string/replace \"aXbX\" \\X \\-) (nexis.string/replace \"héé\" \\é \\e) (nexis.string/replace \"abc\" \"\" \"-\") (nexis.string/replace \"\" \"\" \"-\")])", "[\"a-b-\" \"hee\" \"-a-b-c-\" \"-\"]");
    try expectOutput("[(try (nexis.string/replace \"abc\" \\a \"x\") (catch any e e)) (try (nexis.string/replace \"abc\" \"a\" \\x) (catch any e e))]", "[:kind-mismatch :kind-mismatch]");
    try expectOutput("(nexis.string/replace \"abc\" \"b\" \"X\")", "aXc");
    try expectOutput("(nexis.string/replace \"abababab\" \"ab\" \"X\")", "XXXX");
    // STDLIB.md §3 `replace`: after a match the cursor advances by the
    // match length, so `(replace "aaa" "aa" "x") → "xa"`, not `"xx"`.
    try expectOutput("(nexis.string/replace \"aaa\" \"aa\" \"x\")", "xa");
    // Consecutive non-overlapping matches both fire.
    try expectOutput("(nexis.string/replace \"aaaa\" \"aa\" \"x\")", "xx");
    try expectOutput("(nexis.string/replace \"abc\" \"z\" \"x\")", "abc");
    try expectOutput("(nexis.string/replace \"\" \"x\" \"y\")", "");
    // Replacement can be longer/shorter than match.
    try expectOutput("(nexis.string/replace \"a\" \"a\" \"foo\")", "foo");
    try expectOutput("(nexis.string/replace \"foobar\" \"foo\" \"\")", "bar");
}

test "nexis.string: replace: non-string args" {
    try expectOutput("(try (nexis.string/replace \"abc\" :nope \"x\") (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/replace \"abc\" \"b\" 42) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (nexis.string/replace 42 \"b\" \"x\") (catch any e e))", ":kind-mismatch");
}

test "nexis.string: replace: UTF-8 boundary safety" {
    // Valid UTF-8 in, valid UTF-8 out. `é` (0xC3 0xA9) won't be
    // matched by ASCII `c` (UTF-8 continuation bytes never equal
    // ASCII delimiter targets).
    try expectOutput("(nexis.string/replace \"aécé\" \"c\" \"X\")", "aéXé");
}

// =============================================================================
// Printing + I/O
// =============================================================================
//
// Print fns (print/println/prn) return nil; the test harness
// compares the FINAL VALUE. Stdout is not captured here — the
// formatter's output shape is fully tested in src/format.zig.
//
// Slurp + spit are tested via round-trip in /tmp.

test "io: pr-str: readable string output" {
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

test "io: str vs pr-str: nil semantics" {
    // `str` uses str-semantics: nil → "".
    try expectOutput("(str nil)", "");
    try expectOutput("(str nil :x nil)", ":x");
    // `pr-str` uses readable mode: nil → "nil".
    try expectOutput("(pr-str nil)", "nil");
    try expectOutput("(pr-str nil :x nil)", "nil :x nil");
}

test "io: join: nil-element semantics" {
    // `join` uses str-semantics for each element, so nil → empty
    // (no `nil` literal emitted between separators).
    try expectOutput("(nexis.string/join [1 nil 2])", "12");
    try expectOutput("(nexis.string/join \",\" [1 nil 2])", "1,,2");
}

// =============================================================================
// I/O error paths
// =============================================================================
//
// Integration tests leave `vm.io` null (the test harness has no
// std.Io context). That surfaces :io-error — pinned here so the
// contract is grep-able. End-to-end I/O
// is exercised via `bin/nexis run examples/...` smoke tests, not
// here.

test "io: print / println / prn / pr-str: no vm.io → :io-error" {
    try expectOutput("(try (print :a) (catch any e e))", ":io-error");
    try expectOutput("(try (println :a) (catch any e e))", ":io-error");
    try expectOutput("(try (prn :a) (catch any e e))", ":io-error");
    // pr-str does NOT touch vm.io (it returns a String); it
    // works regardless. Pin the contract.
    try expectOutput("(pr-str :a)", ":a");
}

test "io: slurp / spit: a missing file or directory is :file-not-found" {
    try expectOutput("(try (slurp \"/nexis-no-such-dir/anything.txt\") (catch any e e))", ":file-not-found");
    try expectOutput("(try (spit \"/nexis-no-such-dir/anything.txt\" \"x\") (catch any e e))", ":file-not-found");
}

test "io: slurp / spit: non-string path is :kind-mismatch" {
    try expectOutput("(try (slurp 42) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (spit :nope \"x\") (catch any e e))", ":kind-mismatch");
}

test "io: slurp / spit: empty path is :invalid-path" {
    try expectOutput("(try (slurp \"\") (catch any e e))", ":invalid-path");
    try expectOutput("(try (spit \"\" \"x\") (catch any e e))", ":invalid-path");
}

// =============================================================================
// case / condp / for macros
// =============================================================================
//
// `case` + `condp` are pure expansion + single-eval gensym
// patterns; both throw `{:error :no-matching-clause ...}` when no
// clause matches and no default is supplied (returning nil would
// silently mask bugs).

test "case: basic match + default" {
    try expectOutput("(case 1 1 :one 2 :two :default)", ":one");
    try expectOutput("(case 2 1 :one 2 :two :default)", ":two");
    try expectOutput("(case 99 1 :one 2 :two :default)", ":default");
    try expectOutput("(case 1 1 :one)", ":one");
    // Odd terminal arg = default; no clauses → default.
    try expectOutput("(case :anything :default)", ":default");
}

test "case: constants are data, never evaluated" {
    // A list groups alternatives; a symbol is the symbol itself.
    try expectOutput("(case 1 (1 2) :a :d)", ":a");
    try expectOutput("(case 2 (1 2) :a 3 :b :d)", ":a");
    try expectOutput("(case 3 (1 2) :a 3 :b :d)", ":b");
    try expectOutput("(case 'x x :a :d)", ":a");
    try expectOutput("(case 'y x :a y :b :d)", ":b");
    try expectOutput("(case 'z (x y) :a (z w) :b :d)", ":b");
    try expectOutput("(case nil nil :nil :d)", ":nil");
    try expectOutput("(case [1 2] [1 2] :vec :d)", ":vec");
    try expectOutput("(case {:a 1} {:a 1} :map :d)", ":map");
    try expectOutput("(case :k (:j :k) :kw :d)", ":kw");
    try expectOutput("(case \"s\" (\"a\" \"s\") :str :d)", ":str");
    try expectOutput("(case \\c \\c :char :d)", ":char");
    try expectOutput("(case 1.5 1.5 :f :d)", ":f");
    try expectOutput("(case true true :t false :f)", ":t");
    // The dispatch expression is evaluated; a symbol there is a lookup.
    try expectOutput("(let [x 5] (case x 5 :five :d))", ":five");
    try expectOutput("(let [x 5] (case x (4 5 6) :mid :d))", ":mid");
}

test "case: a test constant given twice fails at expansion, as in Clojure" {
    try expectMacroFailure("", "(case 1 1 :a 1 :b)", "case: duplicate test constant", "1");
    try expectMacroFailure("", "(case x (1 2) :a (3 2) :b :d)", "case: duplicate test constant", "2");
    try expectMacroFailure("", "(case x [1 (2)] :a y :b [1 (2)] :c)", "case: duplicate test constant", "[1 (2)]");
    try expectMacroFailure("", "(case x (a a) :a)", "case: duplicate test constant", "a");
    // Equal-looking constants of different kinds, and a default equal to a key, are not duplicates.
    try expectOutput("[(case 1 1 :int 1.0 :float \\1 :char \"1\" :str :d) (case 1 1 :a 1)]", "[:int :a]");
}

test "case: three or more constants dispatch through one lookup with the chain's answers" {
    // Every kind of atom, one compound constant, grouped and alone,
    // and a miss.
    try expectOutput(
        \\(let [f (fn [x] (case x :a 1 (:b :c) 2 "s" 3 \c 4 nil 5 [1 2] 6 sym 8 1.0 9 1 10 () 11 :none))]
        \\  (mapv f [:a :b :c "s" \c nil [1 2] '(1 2) 'sym 1.0 1 2 :zz false]))
    , "[1 2 2 3 4 5 6 6 8 9 10 :none :none :none]");
    // Of two constants that are = but spelled differently, the first
    // clause wins: a case with two compound constants keeps the chain.
    try expectOutput("[(case [1] ((1)) :list [1] :vec 0 :zero) (case '(1) [1] :vec ((1)) :list 0 :zero)]", "[:list :vec]");
    try expectOutput(
        \\(try (case 99 1 :one 2 :two 3 :three) (catch any e [(:error e) (:value e) (:message e)]))
    , "[:no-matching-clause 99 No matching clause: 99]");
    // The dispatch value is evaluated once, before any test.
    try expectOutput("(let [n (atom 0)] [(case (swap! n inc) 1 :one 2 :two 3 :three) (case (swap! n inc) 1 :one 2 :two 3 :three :d) @n])", "[:one :two 2]");
    // Locals named after the core fns the expansion calls do not capture it.
    try expectOutput("(let [get (fn [& _] 0) == (fn [& _] true)] (case 2 1 :a 2 :b 3 :c))", ":b");
}

test "case: no match without default throws a map naming the value" {
    try expectOutput(
        \\(try (case 99 1 :one 2 :two) (catch any e [(:error e) (:value e) (:message e)]))
    , "[:no-matching-clause 99 No matching clause: 99]");
    // Even count = no default; still throws.
    try expectOutput(
        \\(try (case :k 1 :one) (catch any e (:error e)))
    , ":no-matching-clause");
}

test "case: heterogeneous keys + nested expressions" {
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

test "case: expression evaluated EXACTLY ONCE" {
    // Use an atom-mutating step fn to count evaluations.
    try expectOutput(
        \\(let [counter (atom 0)
        \\      step    (fn [] (swap! counter inc) @counter)]
        \\  (case (step) 1 :one :other)
        \\  @counter)
    , "1");
}

test "condp: predicate + default" {
    try expectOutput("(condp = 1 1 :one 2 :two :default)", ":one");
    try expectOutput("(condp = 2 1 :one 2 :two :default)", ":two");
    try expectOutput("(condp = 99 1 :one 2 :two :default)", ":default");
    // Single trailing default with no clauses.
    try expectOutput("(condp = 99 :default)", ":default");
}

test "condp: no match without default throws a map naming the value" {
    try expectOutput(
        \\(try (condp = 99 1 :one 2 :two) (catch any e [(:error e) (:value e)]))
    , "[:no-matching-clause 99]");
}

test "condp: predicate is called as (pred clause expr)" {
    // `(condp < 5 ...)` invokes `(< clause 5)` per clause.
    // `(< 3 5)` is true → `:gt3`. `(< 10 5)` is false.
    try expectOutput(
        \\(condp < 5 3 :gt3 10 :gt10 :default)
    , ":gt3");
    try expectOutput(
        \\(condp < 5 10 :gt10 3 :gt3 :default)
    , ":gt3");
}

test "condp: pred + expr each evaluated EXACTLY ONCE" {
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

test "for: single binding maps over the source" {
    try expectOutput("(for [x [1 2 3]] (* x x))", "(1 4 9)");
    try expectOutput("(for [x []] (* x x))", "()");
    try expectOutput("(for [x [42]] x)", "(42)");
    // A seq, as in Clojure: conj prepends.
    try expectOutput("(let [xs (for [x [1 2]] x)] [(seq? xs) (vector? xs) (conj xs 0)])", "[true false (0 1 2)]");
}

test "for: multi-binding cartesian product" {
    // Cartesian order: outermost iterates first, innermost
    // varies fastest.
    try expectOutput("(for [x [1 2] y [10 20]] (+ x y))", "(11 21 12 22)");
    try expectOutput(
        \\(for [x [:a :b] y [1 2 3]] [x y])
    , "([:a 1] [:a 2] [:a 3] [:b 1] [:b 2] [:b 3])");
}

test "for: :when filter" {
    // `<` is in core (not `>`); use `<` consistently in tests.
    try expectOutput("(for [x [1 2 3 4 5] :when (< 0 x)] x)", "(1 2 3 4 5)");
    try expectOutput("(for [x [1 2 3 4 5] :when (< 2 x)] x)", "(3 4 5)");
    try expectOutput("(for [x [1 2 3] :when (< 99 x)] x)", "()");
}

test "for: :let modifier with destructuring-capable bindings" {
    // `:let` uses `let` (NOT `let*`) so destructuring works.
    try expectOutput("(for [x [1 2 3] :let [y (* x 10)]] y)", "(10 20 30)");
    // Compose :let + :when (order matters; let-bound name
    // visible to the when's predicate).
    try expectOutput(
        \\(for [x [1 2 3 4] :let [y (* x 10)] :when (< 15 y)] y)
    , "(20 30 40)");
    // Destructuring: bind a vector to [a b].
    try expectOutput(
        \\(for [pair [[1 :a] [2 :b]] :let [[n k] pair]] [k n])
    , "([:a 1] [:b 2])");
}

test "for: :while ends its loop, patterns destructure, modifiers compose" {
    try expectOutput("(for [x [1 2 3] :while (< x 3)] x)", "(1 2)");
    try expectOutput("(for [x [1 2] y [3 4] :while (< y 4)] [x y])", "([1 3] [2 3])");
    try expectOutput("(for [x [1 2] :while (< x 2) y [1 2]] [x y])", "([1 1] [1 2])");
    try expectOutput("(for [x [1 2 3] :let [y (* x 10)] :when (< 10 y)] y)", "(20 30)");
    try expectOutput("(for [x (range 5) :while (< x 3) :when (odd? x)] x)", "(1)");
    try expectOutput("(for [x (range 10) :when (odd? x) :while (< x 6) :let [y (* x x)]] y)", "(1 9 25)");
    try expectOutput("(for [[a b] [[1 2] [3 4]]] (+ a b))", "(3 7)");
    try expectOutput("(for [[k v] {:a 1}] [v k])", "([1 :a])");
    try expectOutput("(for [{:keys [n]} [{:n 1} {:n 2}]] n)", "(1 2)");
    try expectOutput("(for [x nil] x)", "()");
    try expectProgramError("(for [:when true x [1]] x)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(for [x [1] :reduce +] x)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(for [x] x)", compile.CompileError.MacroExpansionFailure);
}

test "doseq: :when, :while and :let modifiers, destructuring, nil result" {
    try expectOutput("(let [a (atom [])] (doseq [x [1 2 3] :when (odd? x)] (swap! a conj x)) @a)", "[1 3]");
    try expectOutput("(let [a (atom [])] (doseq [x [1 2 3] :while (< x 3)] (swap! a conj x)) @a)", "[1 2]");
    try expectOutput("(let [a (atom [])] (doseq [x [1 2] :let [y (* x 10)]] (swap! a conj y)) @a)", "[10 20]");
    try expectOutput("(let [a (atom [])] (doseq [x [1 2 3] :while (< x 3) y [1]] (swap! a conj [x y])) @a)", "[[1 1] [2 1]]");
    try expectOutput("(let [a (atom [])] (doseq [x [1 2] y [10 20] :when (< 15 y)] (swap! a conj (+ x y))) @a)", "[21 22]");
    try expectOutput("(let [a (atom [])] (doseq [[k v] {:a 1}] (swap! a conj [v k])) @a)", "[[1 :a]]");
    try expectOutput("(let [a (atom [])] (doseq [x [1] :let [y 2] :when (= y 2)] (swap! a conj [x y])) @a)", "[[1 2]]");
    try expectOutput("(doseq [x [1 2] :when (odd? x)] x)", "nil");
}

// =============================================================================
// Records substrate
// =============================================================================

test "defrecord: constructor + predicate + Counter-type-id" {
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

test "defrecord: structural equality" {
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

test "defrecord: map-like get / assoc / dissoc / contains?" {
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

test "defrecord: extra keys allowed via map->Counter" {
    // Declared fields are constructor metadata, NOT a storage
    // restriction. map->Counter passes its arg
    // verbatim as the field map.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (let [c (map->Counter {:n 5 :extra :hi})]
        \\    [(Counter? c) (get c :extra)]))
    , "[true :hi]");
}

test "defrecord: keys + vals walk the field map" {
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

test "defrecord: inline methods see the fields as locals; parameters shadow them" {
    try expectOutputProgram(
        \\(defprotocol Shape (area [s]) (scaled [s k]))
        \\(defrecord Rect [w h] Shape (area [_] (* w h)) (scaled [this w] (* w h)))
        \\[(area (->Rect 2 3)) (scaled (->Rect 2 3) 10)]
    , "[6 30]");
    // A field assoc'd onto the record is what the method sees.
    try expectOutputProgram(
        \\(defprotocol P (x-of [p]))
        \\(defrecord Pt [x] P (x-of [p] x))
        \\(x-of (assoc (->Pt 1) :x 5))
    , "5");
    try expectOutputProgram(
        \\(defprotocol P (sum [p]))
        \\(defrecord Pair [a b] P (sum [{:keys [a]}] (+ a b)))
        \\(sum (->Pair 1 2))
    , "3");
}

test "defprotocol: a docstring and options before the methods" {
    try expectOutputProgram(
        \\(defprotocol Named "Things with names." :extend-via-metadata true (nm [x] "The name."))
        \\(extend-type :string Named (nm [s] (str "s:" s)))
        \\(nm "a")
    , "s:a");
}

// =============================================================================
// Protocols substrate
// =============================================================================

test "defprotocol: registers protocol + method dispatchers" {
    // Smoke: both IFoo and bar end up bound to the right kinds.
    // (Use `str` rather than `println` because the test harness
    // has no `vm.io` and println→:io-error there.)
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (str IFoo " " (fn? bar)))
    , "#<protocol id=0> true");
}

test "protocol dispatch with NO impl raises :no-protocol-impl" {
    // Hand-trace from PROTOCOLS.md §5.5: registering IFoo then
    // calling `(bar receiver y)` with no impl for receiver's
    // dispatch key must raise a catchable :no-protocol-impl
    // (NOT panic, NOT silently return nil).
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

test "protocol dispatch: the integer tower is one target, fixnum or bignum" {
    // SEMANTICS §2.2: an integer's representation is invisible, so an
    // impl for either integer kind covers both (PROTOCOLS.md §4.3).
    try expectOutput(
        \\(defprotocol Twice (twice [x]))
        \\(extend-protocol Twice :fixnum (twice [x] (* 2 x)))
        \\[(twice 140737488355327) (twice (inc 140737488355327)) (satisfies? Twice (* 1000000000 1000000000)) (satisfies? Twice 1.5)]
    , "[281474976710654 281474976710656 true false]");
    try expectOutput(
        \\(defprotocol Kind (kind-of [x]))
        \\(extend-protocol Kind :bignum (kind-of [x] :integer) :float (kind-of [x] :float))
        \\[(kind-of 1) (kind-of (* 1000000000 1000000000)) (kind-of 1.0)]
    , "[:integer :integer :float]");
}

test "protocol dispatch with zero args raises :arity-mismatch" {
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
// defrecord with inline protocol impls. The canonical hand-trace
// from PROTOCOLS.md §5.
// =============================================================================

test "protocol hand-trace: (bar (->Counter 5) 7) -> 12" {
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

test "defrecord impls: receiver-typed dispatch" {
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

test "defrecord impls: multiple methods" {
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

test "protocol methods: several arities, in either Clojure spelling, dispatch by argument count" {
    // Separate clauses per arity, Clojure's defrecord spelling.
    try expectOutputProgram(
        \\(defprotocol P (m [s] [s x]))
        \\(defrecord R [a]
        \\  P
        \\  (m [this] [:one a])
        \\  (m [this x] [:two a x]))
        \\[(m (->R 1)) (m (->R 1) 2)]
    , "[[:one 1] [:two 1 2]]");
    // One clause listing its arities, Clojure's extend spelling.
    try expectOutputProgram(
        \\(defprotocol P (m [s] [s x]))
        \\(defrecord R [a] P (m ([this] [:one a]) ([this x] [:two a x])))
        \\(extend-type :string P (m ([s] [:s1 s]) ([s x] [:s2 s x])))
        \\(extend-protocol P :fixnum (m ([n] [:n1 n]) ([n x] [:n2 n x])) :keyword (m [k] :k1) (m [k x] :k2))
        \\[(m (->R 1)) (m (->R 1) 2) (m "a") (m "a" 2) (m 5) (m 5 6) (m :z) (m :z 1)]
    , "[[:one 1] [:two 1 2] [:s1 a] [:s2 a 2] [:n1 5] [:n2 5 6] :k1 :k2]");
    // A variadic arity, and an arity no impl has.
    try expectOutputProgram(
        \\(defprotocol P (m [s] [s x] [s x y]))
        \\(extend-type :fixnum P (m ([n] n) ([n & xs] (apply + n xs))))
        \\[(m 1) (m 1 2 3) (try (m "x") (catch any e e))]
    , "[1 6 :no-protocol-impl]");
    try expectOutputProgram(
        \\(defprotocol P (m [s] [s x]))
        \\(defrecord R [a] P (m [this] 1))
        \\(try (m (->R 1) 2) (catch any e e))
    , ":arity-mismatch");
    // The same arity twice is the fn overload error.
    try expectMacroFailure("(defprotocol P (m [s]))", "(defrecord R [a] P (m [this] 1) (m [that] 2))", "fn: two overload clauses take 1 arguments", "(m [that] 2)");
    try expectMacroFailure("(defprotocol P (m [s]))", "(extend-type :string P (m ([s] 1) [s]))", "expected the method's parameter vector or its arities ([params] body...), not a vector", "[s]");
}

test "defrecord impls: multiple protocols on one record" {
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

test "defrecord impls: this is the literal record value" {
    // The first arg to a protocol method is the receiver itself
    // (NOT a magic this-pointer). It's just the value that gets
    // passed in.
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
// extend-protocol/extend-type + satisfies? + :any default
// =============================================================================

test "extend-protocol: built-in kinds" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (extend-protocol IFoo
        \\    :string (bar [s y] (str s "-" y))
        \\    :fixnum (bar [n y] (* n y)))
        \\  [(bar "hi" 7) (bar 5 7)])
    , "[hi-7 35]");
}

test "extend-type: record and built-in mixed" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (defrecord Counter [n])
        \\  (extend-type Counter IFoo (bar [c y] (+ (get c :n) y)))
        \\  (extend-type :string IFoo (bar [s y] (str s "-" y)))
        \\  [(bar (->Counter 5) 7) (bar "hi" 7)])
    , "[12 hi-7]");
}

test "protocol :any default fallback" {
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

test "satisfies?: identifies impl presence" {
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

test "satisfies? with :any default: always true" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (extend-protocol IFoo :any (bar [x] :default))
        \\  [(satisfies? IFoo "hi")
        \\   (satisfies? IFoo 5)
        \\   (satisfies? IFoo [])])
    , "[true true true]");
}

test "extend-protocol with :vector / :map friendly aliases" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (extend-protocol IFoo
        \\    :vector (bar [v] :v)
        \\    :map (bar [m] :m))
        \\  [(bar []) (bar {})])
    , "[:v :m]");
}

test "extend-protocol with bogus type-kw: :invalid-argument" {
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
// Broader core.nx stdlib
// =============================================================================

test "core.nx: constantly / complement / partial / comp" {
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

test "core.nx: every? truthy + falsy cases" {
    try expectOutputProgram(
        \\(every? pos? [1 2 3])
    , "true");
    try expectOutputProgram(
        \\(every? pos? [1 -2 3])
    , "false");
}

test "core.nx: every? empty seq is vacuously true" {
    try expectOutputProgram(
        \\(every? pos? [])
    , "true");
}

test "core.nx: not-every?" {
    try expectOutputProgram(
        \\(not-every? pos? [1 -2 3])
    , "true");
    try expectOutputProgram(
        \\(not-every? pos? [1 2 3])
    , "false");
}

test "core.nx: some + not-any?" {
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

test "core.nx: merge / update / get-in / assoc-in / update-in" {
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

test "core.nx: frequencies / group-by / interpose" {
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

test "defprotocol: protocol-fn passes through map-as-key" {
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

test "defrecord: records-as-map-keys use structural identity" {
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

test "nexis.string: end-to-end case + trim + split + join chain" {
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

// =============================================================================
// Backing-stack extent across nested frames
//
// Frames window into one backing stack, and a callee's window can end
// below a wider grandparent's extent. These tests pin the stack-length
// rule: every frame pop restores the length recorded at that frame's
// entry, so the frames beneath keep their full extent.
// =============================================================================

test "integration: stack extent — narrow middle callee under a wide caller" {
    try expectOutput(
        \\(do
        \\  (defn c [] 1)
        \\  (defn b [] (c))
        \\  (defn a [] (do (b) (let [x1 1 x2 2 x3 3 x4 4 x5 5 x6 6 x7 7 x8 8 x9 9 x10 10] x10)))
        \\  (a))
    , "10");
}

test "integration: stack extent — narrow handler frame under a wide caller" {
    // `b` registers the handler and its window ends below `a`'s
    // extent when called from `a`'s low slot; the catch fires in
    // `b`, `b` returns, and `a` still binds and reads its locals.
    try expectOutput(
        \\(do
        \\  (defn c [] (throw :deep))
        \\  (defn b [] (try (c) (catch any e 5)))
        \\  (defn a [] (do (b) (let [x1 1 x2 2 x3 3 x4 4 x5 5 x6 6 x7 7 x8 8 x9 9 x10 10] (+ x10 (b) x1))))
        \\  (a))
    , "16");
}

test "integration: stack extent — throw from a deep callee caught by an outer try keeps locals" {
    try expectOutput(
        \\(do
        \\  (defn d [] (throw :deep))
        \\  (defn c [] (let [t1 1 t2 2] (+ t1 t2 (d))))
        \\  (defn b [] (try (c) (catch any e 50)))
        \\  (defn a []
        \\    (do (b)
        \\      (let [x1 1 x2 2 x3 3 x4 4 x5 5 x6 6 x7 7 x8 8 x9 9 x10 10]
        \\        (+ (try (b) (catch any e 100)) (try (c) (catch any e 50)) x1 x2 x3 x4 x5 x6 x7 x8 x9 x10))))
        \\  (a))
    , "155");
    // The throw crosses a host frame: `reduce` re-enters the VM
    // through `callValue` and the handler sits below that entry.
    try expectOutput(
        \\(do
        \\  (defn d [] (throw :deep))
        \\  (defn c [] (reduce (fn [acc x] (+ acc (d))) 0 [1 2 3]))
        \\  (defn b [] (try (c) (catch any e 50)))
        \\  (defn a []
        \\    (do (b)
        \\      (let [x1 1 x2 2 x3 3 x4 4 x5 5 x6 6 x7 7 x8 8 x9 9 x10 10]
        \\        (+ (try (b) (catch any e 100)) (try (c) (catch any e 50)) x1 x2 x3 x4 x5 x6 x7 x8 x9 x10))))
        \\  (a))
    , "155");
}

test "integration: stack extent — native/closure reentrancy 8 deep through callValue" {
    // closure g → native reduce → closure fn → closure g → ... eight
    // levels down. Each `g` first calls the narrow `leaf` from a low
    // slot, so a narrow window ends below `g`'s extent at every
    // level; the harness checks the stack length and frame depth
    // are exactly restored after the run.
    try expectOutput(
        \\(do
        \\  (defn id [x] x)
        \\  (defn leaf [] (id 1))
        \\  (defn g [n]
        \\    (if (= n 0)
        \\      (leaf)
        \\      (do (leaf)
        \\        (let [a 1 b 2 c 3 d 4 e 5 f 6 h 7 i 8]
        \\          (+ (reduce (fn [acc x] (+ acc (g (- n 1)))) 0 [1 1]) a b c d e f h i -36)))))
        \\  (g 8))
    , "256");
    try expectOutput(
        \\(do
        \\  (defn id [x] x)
        \\  (defn leaf [] (id 1))
        \\  (defn g [n]
        \\    (if (= n 0)
        \\      (leaf)
        \\      (do (leaf)
        \\        (let [a 1 b 2 c 3 d 4 e 5 f 6 h 7 i 8]
        \\          (+ (apply g [(- n 1)]) (first (map (fn [x] (g (- n 1))) [1])) a b c d e f h i -36)))))
        \\  (g 8))
    , "256");
}

// Randomized call chains: `f0` calls `f1` calls ... `f{depth}`, each
// level with a random number of `let` locals and a random call shape,
// so narrow and wide windows interleave in every order. The expected
// value is computed directly from the generated shapes.
const ChainShape = enum {
    /// `(do (f) (let [...] sum))` — the callee's result is dropped and
    /// the caller's locals are bound after the call returns.
    call_then_let,
    /// `(let [...] (+ (f) locals...))` — locals live across the call.
    let_then_call,
    /// Half the locals bound before the call, half after it.
    call_between_lets,
    /// The call goes through `reduce`, so a host frame sits between
    /// caller and callee.
    call_via_reduce,
    /// The call sits inside a `try` whose catch never fires.
    call_in_try,
    /// The callee returns, then the caller throws to its own catch.
    call_then_throw,
};

fn appendLocals(out: *std.ArrayList(u8), values: []const u8, offset: usize) !void {
    for (values, 0..) |v, j| {
        try out.print(testing.allocator, " l{d} {d}", .{ offset + j, v });
    }
}

fn appendLocalRefs(out: *std.ArrayList(u8), count: usize) !void {
    var j: usize = 0;
    while (j < count) : (j += 1) {
        try out.print(testing.allocator, " l{d}", .{j});
    }
}

test "integration: stack extent — randomized call chains match direct evaluation" {
    var prng = std.Random.DefaultPrng.init(0x5eed_5eed_0000_0001);
    const random = prng.random();
    const shapes = std.enums.values(ChainShape);

    var trial: usize = 0;
    while (trial < 48) : (trial += 1) {
        const depth = random.intRangeAtMost(usize, 2, 7);
        const leaf_value = random.intRangeAtMost(u8, 0, 50);

        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(testing.allocator);
        try src.appendSlice(testing.allocator, "(do");

        // Widths, local values and shapes per level, kept so the
        // expected value can be computed from the same data.
        var widths: [8]usize = undefined;
        var sums: [8]i64 = undefined;
        var level_shapes: [8]ChainShape = undefined;
        var values: [8][10]u8 = undefined;

        var i: usize = 0;
        while (i < depth) : (i += 1) {
            widths[i] = random.intRangeAtMost(usize, 0, 10);
            level_shapes[i] = shapes[random.intRangeAtMost(usize, 0, shapes.len - 1)];
            sums[i] = 0;
            var j: usize = 0;
            while (j < widths[i]) : (j += 1) {
                values[i][j] = random.intRangeAtMost(u8, 1, 9);
                sums[i] += values[i][j];
            }
            const w = widths[i];
            const vals = values[i][0..w];
            try src.print(testing.allocator, " (defn f{d} []", .{i});
            switch (level_shapes[i]) {
                .call_then_let => {
                    try src.print(testing.allocator, " (do (f{d}) (let [", .{i + 1});
                    try appendLocals(&src, vals, 0);
                    try src.appendSlice(testing.allocator, "] (+ 0");
                    try appendLocalRefs(&src, w);
                    try src.appendSlice(testing.allocator, ")))");
                },
                .let_then_call => {
                    try src.appendSlice(testing.allocator, " (let [");
                    try appendLocals(&src, vals, 0);
                    try src.print(testing.allocator, "] (+ (f{d})", .{i + 1});
                    try appendLocalRefs(&src, w);
                    try src.appendSlice(testing.allocator, "))");
                },
                .call_between_lets => {
                    const half = w / 2;
                    try src.appendSlice(testing.allocator, " (let [");
                    try appendLocals(&src, vals[0..half], 0);
                    try src.print(testing.allocator, " r (f{d})", .{i + 1});
                    try appendLocals(&src, vals[half..], half);
                    try src.appendSlice(testing.allocator, "] (+ r");
                    try appendLocalRefs(&src, w);
                    try src.appendSlice(testing.allocator, "))");
                },
                .call_via_reduce => {
                    try src.appendSlice(testing.allocator, " (let [");
                    try appendLocals(&src, vals, 0);
                    try src.print(testing.allocator, "] (+ (reduce (fn [acc x] (+ acc (f{d}))) 0 [1])", .{i + 1});
                    try appendLocalRefs(&src, w);
                    try src.appendSlice(testing.allocator, "))");
                },
                .call_in_try => {
                    try src.appendSlice(testing.allocator, " (let [");
                    try appendLocals(&src, vals, 0);
                    try src.print(testing.allocator, "] (+ (try (f{d}) (catch any e -1))", .{i + 1});
                    try appendLocalRefs(&src, w);
                    try src.appendSlice(testing.allocator, "))");
                },
                .call_then_throw => {
                    try src.appendSlice(testing.allocator, " (let [");
                    try appendLocals(&src, vals, 0);
                    try src.print(testing.allocator, "] (+ (try (do (f{d}) (throw 7)) (catch any e e))", .{i + 1});
                    try appendLocalRefs(&src, w);
                    try src.appendSlice(testing.allocator, "))");
                },
            }
            try src.appendSlice(testing.allocator, ")");
        }
        try src.print(testing.allocator, " (defn f{d} [] {d}) (f0))", .{ depth, leaf_value });

        // Direct evaluation of the same chain.
        var expected: i64 = leaf_value;
        i = depth;
        while (i > 0) {
            i -= 1;
            expected = switch (level_shapes[i]) {
                .call_then_let => sums[i],
                .call_then_throw => 7 + sums[i],
                else => expected + sums[i],
            };
        }
        var expected_buf: [32]u8 = undefined;
        const expected_str = try std.fmt.bufPrint(&expected_buf, "{d}", .{expected});
        expectOutput(src.items, expected_str) catch |err| {
            std.debug.print("\n  trial {d} source:\n  {s}\n", .{ trial, src.items });
            return err;
        };
    }
}

// =============================================================================
// Numeric tower: floats, contagion, division, comparison, overflow
// =============================================================================

test "numbers: float literals print like Clojure doubles" {
    try expectOutput("1.0", "1.0");
    try expectOutput("1.5", "1.5");
    try expectOutput("-2.25", "-2.25");
    try expectOutput("0.1", "0.1");
    try expectOutput("100.0", "100.0");
    try expectOutput("1e10", "1.0E10");
    try expectOutput("12345678.5", "1.23456785E7");
    try expectOutput("0.0001", "1.0E-4");
    try expectOutput("0.001", "0.001");
    try expectOutput("(- 0.0)", "-0.0");
    try expectOutput("'1.5", "1.5");
    try expectOutput("(pr-str [1 1.0 \"s\" \\a])", "[1 1.0 \"s\" \\a]");
    try expectOutput("(str 1.5 \" \" 2.0)", "1.5 2.0");
}

test "numbers: special floats" {
    try expectOutput("(/ 1.0 0)", "Infinity");
    try expectOutput("(/ -1.0 0)", "-Infinity");
    try expectOutput("(/ 0.0 0.0)", "NaN");
    try expectOutput("(NaN? (/ 0.0 0.0))", "true");
    try expectOutput("(NaN? 1.5)", "false");
    try expectOutput("(infinite? (/ 1.0 0))", "true");
    try expectOutput("(infinite? (/ 1 2))", "false");
    try expectOutput("(let [n (/ 0.0 0.0)] [(= n n) (== n n) (< n 1) (> n 1)])", "[true false false false]");
}

test "numbers: arithmetic contagion" {
    try expectOutput("(+ 1 2.5)", "3.5");
    try expectOutput("(+ 1.5 2)", "3.5");
    try expectOutput("(+ 1 2 3.0)", "6.0");
    try expectOutput("(- 10 2.5)", "7.5");
    try expectOutput("(- 1.5)", "-1.5");
    try expectOutput("(* 2 2.5)", "5.0");
    try expectOutput("(* 2 3)", "6");
    try expectOutput("(inc 1.5)", "2.5");
    try expectOutput("(dec 0.5)", "-0.5");
    try expectOutput("(abs -3)", "3");
    try expectOutput("(abs -3.5)", "3.5");
    try expectOutput("(max 1 5 3)", "5");
    try expectOutput("(min 1 5 3)", "1");
    try expectOutput("(max 1 2.0)", "2.0");
    try expectOutput("(max 3 2.0)", "3");
    try expectOutput("(min 3 2.0)", "2.0");
    // The inlined `(+ a b)` intrinsic uses the same tower.
    try expectOutput("(let [a 1 b 2.5] (+ a b))", "3.5");
    try expectOutput("(let [a 1.0] (< a 2))", "true");
}

test "numbers: division" {
    try expectOutput("(/ 6 3)", "2");
    try expectOutput("(/ 7 2)", "3.5");
    try expectOutput("(/ -6 3)", "-2");
    try expectOutput("(/ 1 3)", "0.3333333333333333");
    try expectOutput("(/ 6.0 3)", "2.0");
    try expectOutput("(/ 2)", "0.5");
    try expectOutput("(/ 24 2 3)", "4");
    try expectOutput("(quot 7 2)", "3");
    try expectOutput("(quot -7 2)", "-3");
    try expectOutput("(rem -7 2)", "-1");
    try expectOutput("(mod -7 2)", "1");
    try expectOutput("(mod 7 -2)", "-1");
    try expectOutput("(mod 7.5 2)", "1.5");
    try expectOutput("(quot 7.5 2)", "3.0");
    try expectOutput("(rem 7.5 2)", "1.5");
    try expectOutput("(try (/ 1 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (quot 1 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (rem 1.0 0) (catch any e e))", ":divide-by-zero");
    try expectOutput("(try (mod 1 0.0) (catch any e e))", ":divide-by-zero");
}

test "numbers: comparison across kinds" {
    try expectOutput("(< 1 1.5)", "true");
    try expectOutput("(< 1.5 1)", "false");
    try expectOutput("(<= 2 2.0)", "true");
    try expectOutput("(<= 2 1.0)", "false");
    try expectOutput("(> 2 1)", "true");
    try expectOutput("(> 1 2)", "false");
    try expectOutput("(>= 2 2)", "true");
    try expectOutput("(>= 1 2)", "false");
    try expectOutput("(> 3 2 1)", "true");
    try expectOutput("(> 3 1 2)", "false");
    try expectOutput("(<= 1 1 2)", "true");
    try expectOutput("(>)", "true");
    try expectOutput("(>= 5)", "true");
    try expectOutput("(= 1 1.0)", "false");
    try expectOutput("(== 1 1.0)", "true");
    try expectOutput("(== 1 1 1.0)", "true");
    try expectOutput("(== 1 2)", "false");
    try expectOutput("(not= 1 2)", "true");
    try expectOutput("(not= 1 1)", "false");
    try expectOutput("(not= 1 1.0)", "true");
    try expectOutput("(not= :a :a :a)", "false");
    try expectOutput("(try (< 1 :a) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (> \"a\" 1) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (>= nil) (catch any e e))", ":kind-mismatch");
}

test "numbers: predicates over the tower" {
    try expectOutput("[(number? 1) (number? 1.5) (number? :a) (number? nil)]", "[true true false false]");
    try expectOutput("[(integer? 1) (integer? 1.0) (float? 1.0) (float? 1)]", "[true false true false]");
    try expectOutput("[(zero? 0) (zero? 0.0) (zero? -0.0) (zero? 0.5)]", "[true true true false]");
    try expectOutput("[(pos? 1) (pos? 0.5) (pos? -0.5) (neg? -1) (neg? -0.5) (neg? 0.0)]", "[true true false true true false]");
    try expectOutput("[(even? 2) (odd? 3)]", "[true true]");
    try expectOutput("(try (even? 2.0) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try (zero? :a) (catch any e e))", ":kind-mismatch");
}

test "numbers: float equality and hashing agree with SEMANTICS" {
    try expectOutput("(= 0.0 -0.0)", "true");
    try expectOutput("(= 1.5 1.5)", "true");
    try expectOutput("(= 1.5 1.25)", "false");
    try expectOutput("(get {0.0 :zero} -0.0)", ":zero");
    try expectOutput("(get {1 :int} 1.0)", "nil");
    try expectOutput("(let [n (/ 0.0 0.0)] (get {n :nan} (/ 0.0 0.0)))", ":nan");
    try expectOutput("(contains? #{1.5 2.5} 2.5)", "true");
    try expectOutput("(= [1.0 2.0] [1.0 2.0])", "true");
    try expectOutput("(= [1 2] [1.0 2.0])", "false");
}

test "numbers: macros can return float and char literals" {
    try expectOutput("(do (defmacro half [] 0.5) (half))", "0.5");
    try expectOutput("(do (defmacro ch [] \\z) (pr-str (ch)))", "\\z");
    try expectOutput("(do (defmacro twice [x] `(* 2 ~x)) (twice 1.25))", "2.5");
}

// =============================================================================
// Keyword-as-function and collection-as-function (VM.md §6, PLAN §23 #33)
// =============================================================================

test "keyword-as-function: direct calls" {
    try expectOutput("(:a {:a 1 :b 2})", "1");
    try expectOutput("(:c {:a 1 :b 2})", "nil");
    try expectOutput("(:c {:a 1 :b 2} :none)", ":none");
    try expectOutput("(:a {:a nil} :none)", "nil");
    try expectOutput("(:a nil)", "nil");
    try expectOutput("(:a nil :d)", ":d");
    try expectOutput("(:a 5)", "nil");
    try expectOutput("(:a \"s\" :d)", ":d");
    try expectOutput("(:a #{:a :b})", ":a");
    try expectOutput("(:z #{:a :b})", "nil");
    try expectOutput("(try (:a) (catch any e e))", ":arity-mismatch");
    try expectOutput("(try (:a {} 1 2) (catch any e e))", ":arity-mismatch");
    // Nested and in tail position.
    try expectOutput("(:b (:a {:a {:b 2}}))", "2");
    try expectOutput("(-> {:a {:b 3}} :a :b)", "3");
    try expectOutput("(do (defn field [m] (:x m)) (field {:x 7}))", "7");
    try expectOutput("(let [f :a] (f {:a 9}))", "9");
    try expectOutput("(do (defrecord P [x y]) (:y (->P 1 2)))", "2");
}

test "keyword-as-function: keywords passed to higher-order functions" {
    try expectOutput("(map :name [{:name :x} {:name :y}])", "(:x :y)");
    try expectOutput("(filter :ok [{:ok true :n 1} {:ok false :n 2} {:n 3}])", "({:ok true, :n 1})");
    try expectOutput("(apply :a [{:a 3}])", "3");
    try expectOutput("(apply :a {:b 1} [:d])", ":d");
    try expectOutput("(reduce (fn [acc m] (+ acc (:n m))) 0 [{:n 1} {:n 2} {:n 3}])", "6");
    try expectOutput("(some :hit [{:hit nil} {:hit :yes} {:hit :later}])", ":yes");
    try expectOutput("(every? :ok [{:ok 1} {:ok 2}])", "true");
    try expectOutput("((comp :b :a) {:a {:b 4}})", "4");
    try expectOutput("((partial :a) {:a 5})", "5");
}

test "symbol-as-function: a symbol looks itself up as a keyword does" {
    try expectOutput("('a {'a 1 'b 2})", "1");
    try expectOutput("('c {'a 1} :none)", ":none");
    try expectOutput("('a #{'a})", "a");
    try expectOutput("('a 5)", "nil");
    try expectOutput("(map 'x [{'x 1} {'x 2} {}])", "(1 2 nil)");
    try expectOutput("(try ('a) (catch any e e))", ":arity-mismatch");
}

test "collection-as-function: maps, sets and vectors" {
    try expectOutput("({:a 1} :a)", "1");
    try expectOutput("({:a 1} :b)", "nil");
    try expectOutput("({:a 1} :b :d)", ":d");
    try expectOutput("(#{1 2} 1)", "1");
    try expectOutput("(#{1 2} 3)", "nil");
    try expectOutput("(try (#{1 2} 3 :d) (catch any e e))", ":arity-mismatch");
    try expectOutput("([10 20] 1)", "20");
    try expectOutput("(try ([10 20] 2) (catch any e e))", ":index-out-of-bounds");
    try expectOutput("(try ([10 20] :a) (catch any e e))", ":kind-mismatch");
    try expectOutput("(try ([10 20] 0 :d) (catch any e e))", ":arity-mismatch");
    try expectOutput("(map {:a 1 :b 2} [:a :b :c])", "(1 2 nil)");
    try expectOutput("(filter #{2 4} [1 2 3 4])", "(2 4)");
    try expectOutput("(let [m {:x 1}] (m :x))", "1");
    try expectOutput("(try (5 1) (catch any e e))", ":not-callable");
    try expectOutput("(try (\"s\" 1) (catch any e e))", ":not-callable");
}

test "integration: a Var calls, and derefs to, the value in force" {
    try expectOutput("[(#'inc 1) ((var +) 1 2 3) (apply #'max [3 9 4]) (map #'inc [1 2])]", "[2 6 9 (2 3)]");
    try expectOutput("(def ^:dynamic *f* inc) (binding [*f* dec] [(#'*f* 10) (@#'*f* 10) (*f* 10)])", "[9 9 9]");
    try expectOutput("(def ^:dynamic *x* 1) (binding [*x* 2] [@#'*x* (deref (var *x*))])", "[2 2]");
    try expectOutput("(declare later) (try (#'later 1) (catch any e e))", ":unbound-var");
    try expectOutput("(def n 5) (try (#'n 1) (catch any e e))", ":not-callable");
}

// =============================================================================
// Core library completeness (table-driven)
// =============================================================================

const CoreCase = struct { src: []const u8, expected: []const u8 };

fn runCoreCases(cases: []const CoreCase) !void {
    for (cases) |c| try expectOutput(c.src, c.expected);
}

test "core: seq over every seqable kind" {
    try runCoreCases(&.{
        .{ .src = "(seq nil)", .expected = "nil" },
        .{ .src = "(seq [])", .expected = "nil" },
        .{ .src = "(seq (list))", .expected = "nil" },
        .{ .src = "(seq {})", .expected = "nil" },
        .{ .src = "(seq \"\")", .expected = "nil" },
        .{ .src = "(seq [1 2])", .expected = "(1 2)" },
        .{ .src = "(seq '(1 2))", .expected = "(1 2)" },
        .{ .src = "(seq {:a 1})", .expected = "([:a 1])" },
        .{ .src = "(seq #{7})", .expected = "(7)" },
        .{ .src = "(pr-str (seq \"ab\"))", .expected = "(\\a \\b)" },
        .{ .src = "(first {:a 1})", .expected = "[:a 1]" },
        .{ .src = "(first #{3})", .expected = "3" },
        .{ .src = "(pr-str (first \"xy\"))", .expected = "\\x" },
        .{ .src = "(pr-str (rest \"xyz\"))", .expected = "(\\y \\z)" },
        .{ .src = "(rest {:a 1})", .expected = "()" },
        .{ .src = "(next [1])", .expected = "nil" },
        .{ .src = "(next [1 2])", .expected = "(2)" },
        .{ .src = "(next nil)", .expected = "nil" },
        .{ .src = "(count (seq {:a 1 :b 2}))", .expected = "2" },
        .{ .src = "(map (fn [[k v]] (str k v)) {:a 1})", .expected = "(:a1)" },
        .{ .src = "(reduce + 0 #{1 2 3})", .expected = "6" },
        .{ .src = "(map identity \"hi\")", .expected = "(h i)" },
        .{ .src = "(apply str (reverse \"abc\"))", .expected = "cba" },
        .{ .src = "(sort (keys {:b 1 :a 2}))", .expected = "(:a :b)" },
        .{ .src = "(try (seq 5) (catch any e e))", .expected = ":kind-mismatch" },
    });
}

test "core: reduce, range, assoc, dissoc, conj" {
    try runCoreCases(&.{
        .{ .src = "(reduce + [1 2 3])", .expected = "6" },
        .{ .src = "(reduce + [])", .expected = "0" },
        .{ .src = "(reduce + [7])", .expected = "7" },
        .{ .src = "(reduce + 10 [1 2 3])", .expected = "16" },
        .{ .src = "(reduce (fn [a x] (conj a x)) [] '(1 2))", .expected = "[1 2]" },
        .{ .src = "(reduce-kv (fn [acc k v] (assoc acc v k)) {} {:a 1})", .expected = "{1 :a}" },
        .{ .src = "(reduce-kv (fn [acc i x] (+ acc (* i x))) 0 [10 20 30])", .expected = "80" },
        .{ .src = "(range 5)", .expected = "(0 1 2 3 4)" },
        .{ .src = "(range 0)", .expected = "()" },
        .{ .src = "(range 2 5)", .expected = "(2 3 4)" },
        .{ .src = "(range 5 2)", .expected = "()" },
        .{ .src = "(range 0 10 3)", .expected = "(0 3 6 9)" },
        .{ .src = "(range 5 0 -2)", .expected = "(5 3 1)" },
        .{ .src = "(try (range 0 1 0) (catch any e e))", .expected = ":invalid-argument" },
        .{ .src = "(assoc [1 2 3] 1 :x)", .expected = "[1 :x 3]" },
        .{ .src = "(assoc [1 2 3] 3 :end)", .expected = "[1 2 3 :end]" },
        .{ .src = "(try (assoc [1 2 3] 4 :x) (catch any e e))", .expected = ":index-out-of-bounds" },
        .{ .src = "(try (assoc [1] :k 1) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(assoc {} :a 1 :b 2)", .expected = "{:a 1, :b 2}" },
        .{ .src = "(try (assoc {} :a 1 :b) (catch any e e))", .expected = ":arity-mismatch" },
        .{ .src = "(assoc nil :a 1)", .expected = "{:a 1}" },
        .{ .src = "(dissoc {:a 1 :b 2 :c 3} :a :c)", .expected = "{:b 2}" },
        .{ .src = "(dissoc {:a 1})", .expected = "{:a 1}" },
        .{ .src = "(disj #{1 2 3} 1 3)", .expected = "#{2}" },
        .{ .src = "(conj {:a 1} {:b 2 :c 3})", .expected = "{:a 1, :b 2, :c 3}" },
        .{ .src = "(conj {:a 1} [:b 2] nil)", .expected = "{:a 1, :b 2}" },
        .{ .src = "(update [1 2 3] 0 inc)", .expected = "[2 2 3]" },
        .{ .src = "(update {:a 1} :a + 10)", .expected = "{:a 11}" },
        .{ .src = "(update-in {:a {:b 1}} [:a :b] inc)", .expected = "{:a {:b 2}}" },
        .{ .src = "(assoc-in {} [:a :b] 1)", .expected = "{:a {:b 1}}" },
        .{ .src = "(get-in {:a {:b 1}} [:a :b])", .expected = "1" },
        .{ .src = "(get-in {:a {:b 1}} [:a :c])", .expected = "nil" },
        .{ .src = "(get-in {:a {:b 1}} [:a :c] :d)", .expected = ":d" },
        .{ .src = "(get-in {:a {:b nil}} [:a :b] :d)", .expected = "nil" },
        .{ .src = "(get-in {:a [10 20]} [:a 1])", .expected = "20" },
    });
}

test "core: maps" {
    try runCoreCases(&.{
        .{ .src = "(merge {:a 1} {:b 2} nil {:a 3})", .expected = "{:a 3, :b 2}" },
        .{ .src = "(merge-with + {:a 1 :b 2} {:a 10} {:c 5})", .expected = "{:a 11, :b 2, :c 5}" },
        .{ .src = "(merge-with +)", .expected = "nil" },
        .{ .src = "(select-keys {:a 1 :b 2 :c 3} [:a :c :z])", .expected = "{:a 1, :c 3}" },
        .{ .src = "(select-keys nil [:a])", .expected = "{}" },
        .{ .src = "(zipmap [:a :b :c] [1 2])", .expected = "{:a 1, :b 2}" },
        .{ .src = "(find {:a 1} :a)", .expected = "[:a 1]" },
        .{ .src = "(find {:a 1} :b)", .expected = "nil" },
        // The key as the map holds it: a vector key found by a list.
        .{ .src = "(let [e (find {[1 2] :x} '(1 2))] [(vector? (key e)) (meta (key (find {(with-meta [1] {:m 1}) 2} [1])))])", .expected = "[true {:m 1}]" },
        .{ .src = "(find [5 6] 1)", .expected = "[1 6]" },
        .{ .src = "(key (find {:a 1} :a))", .expected = ":a" },
        .{ .src = "(val (find {:a 1} :a))", .expected = "1" },
        .{ .src = "(contains? {:a nil} :a)", .expected = "true" },
        .{ .src = "(contains? [1 2] 1)", .expected = "true" },
        .{ .src = "(contains? [1 2] 2)", .expected = "false" },
        .{ .src = "(contains? #{:x} :x)", .expected = "true" },
        .{ .src = "(frequencies [:a :b :a])", .expected = "{:a 2, :b 1}" },
        .{ .src = "(group-by odd? [1 2 3])", .expected = "{true [1 3], false [2]}" },
        .{ .src = "(group-by :k [{:k 1 :v :a} {:k 1 :v :b}])", .expected = "{1 [{:k 1, :v :a} {:k 1, :v :b}]}" },
        .{ .src = "(into {} [[:a 1] [:b 2]])", .expected = "{:a 1, :b 2}" },
        .{ .src = "(into {:a 1} {:b 2})", .expected = "{:a 1, :b 2}" },
        .{ .src = "(empty {:a 1})", .expected = "{}" },
        .{ .src = "(sort (map key {:b 1 :a 2}))", .expected = "(:a :b)" },
        .{ .src = "(sort (vals {:b 1 :a 2}))", .expected = "(1 2)" },
    });
}

test "core: sequence functions" {
    try runCoreCases(&.{
        .{ .src = "(concat [1 2] '(3) nil #{4})", .expected = "(1 2 3 4)" },
        .{ .src = "(concat)", .expected = "()" },
        .{ .src = "(mapcat (fn [x] [x x]) [1 2])", .expected = "(1 1 2 2)" },
        .{ .src = "(map + [1 2 3] [10 20])", .expected = "(11 22)" },
        .{ .src = "(map vector [:a :b] [1 2] [\"x\" \"y\"])", .expected = "([:a 1 x] [:b 2 y])" },
        .{ .src = "(mapv inc [1 2])", .expected = "[2 3]" },
        .{ .src = "(filterv even? [1 2 3 4])", .expected = "[2 4]" },
        .{ .src = "(map-indexed vector [:a :b])", .expected = "([0 :a] [1 :b])" },
        .{ .src = "(keep-indexed (fn [i x] (if (odd? i) x nil)) [:a :b :c :d])", .expected = "(:b :d)" },
        .{ .src = "(keep (fn [x] (if (odd? x) (* x x) nil)) [1 2 3])", .expected = "(1 9)" },
        .{ .src = "(keep identity [1 nil false 2])", .expected = "(1 false 2)" },
        .{ .src = "(remove odd? [1 2 3 4])", .expected = "(2 4)" },
        .{ .src = "(distinct [1 2 1 3 2 1.0])", .expected = "(1 2 3 1.0)" },
        .{ .src = "(distinct \"aab\")", .expected = "(a b)" },
        .{ .src = "(partition 2 [1 2 3 4 5])", .expected = "((1 2) (3 4))" },
        .{ .src = "(partition 2 1 [1 2 3])", .expected = "((1 2) (2 3))" },
        .{ .src = "(partition 3 3 [:pad] [1 2 3 4])", .expected = "((1 2 3) (4 :pad))" },
        .{ .src = "(partition-all 2 [1 2 3 4 5])", .expected = "((1 2) (3 4) (5))" },
        .{ .src = "(partition-all 2 3 [1 2 3 4 5])", .expected = "((1 2) (4 5))" },
        .{ .src = "(try (partition 0 [1]) (catch any e e))", .expected = ":invalid-argument" },
        .{ .src = "(interleave [1 2 3] [:a :b])", .expected = "(1 :a 2 :b)" },
        .{ .src = "(interleave [1 2] [:a :b] [\"x\" \"y\"])", .expected = "(1 :a x 2 :b y)" },
        .{ .src = "(interleave)", .expected = "()" },
        .{ .src = "(interpose :s [1 2 3])", .expected = "(1 :s 2 :s 3)" },
        .{ .src = "(into [] '(1 2))", .expected = "[1 2]" },
        .{ .src = "(into '(0) [1 2])", .expected = "(2 1 0)" },
        .{ .src = "(into #{} [1 1 2])", .expected = "#{1 2}" },
        .{ .src = "(into nil [1 2])", .expected = "(2 1)" },
        .{ .src = "(take-while odd? [1 3 4 5])", .expected = "(1 3)" },
        .{ .src = "(drop-while odd? [1 3 4 5])", .expected = "(4 5)" },
        .{ .src = "(take-while odd? [])", .expected = "()" },
        .{ .src = "(take 2 [1 2 3])", .expected = "(1 2)" },
        .{ .src = "(drop 2 [1 2 3])", .expected = "(3)" },
        .{ .src = "(take-last 2 [1 2 3])", .expected = "(2 3)" },
        .{ .src = "(drop-last 2 [1 2 3])", .expected = "(1)" },
        .{ .src = "(split-at 1 [1 2 3])", .expected = "[(1) (2 3)]" },
        .{ .src = "(last [1 2 3])", .expected = "3" },
        .{ .src = "(last [])", .expected = "nil" },
        .{ .src = "(butlast [1 2 3])", .expected = "(1 2)" },
        .{ .src = "(butlast [1])", .expected = "nil" },
        .{ .src = "(nth [1 2 3] 1)", .expected = "2" },
        .{ .src = "(nth '(1 2 3) 2)", .expected = "3" },
        .{ .src = "(nth [1] 5 :d)", .expected = ":d" },
        .{ .src = "(nthrest [1 2 3] 2)", .expected = "(3)" },
        .{ .src = "(nthrest [1 2 3] 0)", .expected = "[1 2 3]" },
        .{ .src = "(reverse [1 2 3])", .expected = "(3 2 1)" },
        .{ .src = "(flatten [1 [2 [3 nil]] '(4)])", .expected = "(1 2 3 nil 4)" },
        .{ .src = "(reductions + [1 2 3])", .expected = "(1 3 6)" },
        .{ .src = "(reductions + 10 [1 2])", .expected = "(10 11 13)" },
        .{ .src = "(repeat 3 :x)", .expected = "(:x :x :x)" },
        .{ .src = "(repeat 0 :x)", .expected = "()" },
        .{ .src = "(do (def n (atom 0)) (repeatedly 3 (fn [] (swap! n inc))))", .expected = "(1 2 3)" },
        .{ .src = "(iterate inc 0 5)", .expected = "(0 1 2 3 4)" },
        .{ .src = "(iterate (fn [x] (* 2 x)) 1 4)", .expected = "(1 2 4 8)" },
        .{ .src = "(iterate inc 0 0)", .expected = "()" },
        // The count is not reserved up front: a callback that throws
        // ends a huge count at once.
        .{ .src = "[(try (repeatedly 9999999999999 #(throw :stop)) (catch :stop e e)) (try (iterate (fn [x] (throw :stop)) 0 9999999999999) (catch :stop e e))]", .expected = "[:stop :stop]" },
        .{ .src = "(empty? [])", .expected = "true" },
        .{ .src = "(empty? \"\")", .expected = "true" },
        .{ .src = "(not-empty [1])", .expected = "[1]" },
        .{ .src = "(not-empty [])", .expected = "nil" },
        .{ .src = "(not-empty \"\")", .expected = "nil" },
        .{ .src = "(empty [1 2])", .expected = "[]" },
        .{ .src = "(empty '(1))", .expected = "()" },
        .{ .src = "(peek [1 2 3])", .expected = "3" },
        .{ .src = "(peek '(1 2 3))", .expected = "1" },
        .{ .src = "(pop [1 2 3])", .expected = "[1 2]" },
        .{ .src = "(pop '(1 2 3))", .expected = "(2 3)" },
        .{ .src = "(count \"héllo\")", .expected = "5" },
        .{ .src = "(count nil)", .expected = "0" },
        .{ .src = "(subs \"hello\" 1 3)", .expected = "el" },
        .{ .src = "(str)", .expected = "" },
        .{ .src = "(str \"a\" 1 :k nil \\c)", .expected = "a1:kc" },
    });
}

test "core: sorting and comparison" {
    try runCoreCases(&.{
        .{ .src = "(sort [3 1 2])", .expected = "(1 2 3)" },
        .{ .src = "(sort [3 1.5 2])", .expected = "(1.5 2 3)" },
        .{ .src = "(sort > [3 1 2])", .expected = "(3 2 1)" },
        .{ .src = "(sort (fn [a b] (compare b a)) [1 3 2])", .expected = "(3 2 1)" },
        .{ .src = "(sort [\"b\" \"a\" \"c\"])", .expected = "(a b c)" },
        .{ .src = "(sort [:b :a])", .expected = "(:a :b)" },
        .{ .src = "(sort [nil 2 1])", .expected = "(nil 1 2)" },
        .{ .src = "(sort [[2 1] [1 9] [1 2 0]])", .expected = "([1 9] [2 1] [1 2 0])" },
        .{ .src = "(sort [])", .expected = "()" },
        .{ .src = "(sort #{3 1 2})", .expected = "(1 2 3)" },
        .{ .src = "(try (sort [1 :a]) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(sort-by :age [{:age 30 :n :a} {:age 20 :n :b}])", .expected = "({:age 20, :n :b} {:age 30, :n :a})" },
        .{ .src = "(sort-by count [[1 2] [1] []])", .expected = "([] [1] [1 2])" },
        .{ .src = "(sort-by :k > [{:k 1} {:k 3} {:k 2}])", .expected = "({:k 3} {:k 2} {:k 1})" },
        // Stable: equal keys keep their input order.
        .{ .src = "(sort-by :k [{:k 1 :i 1} {:k 0 :i 2} {:k 1 :i 3} {:k 0 :i 4}])", .expected = "({:k 0, :i 2} {:k 0, :i 4} {:k 1, :i 1} {:k 1, :i 3})" },
        .{ .src = "(sort (range 20 0 -1))", .expected = "(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)" },
        .{ .src = "(compare 1 2)", .expected = "-1" },
        .{ .src = "(compare 2 2.0)", .expected = "0" },
        .{ .src = "(compare \"b\" \"a\")", .expected = "1" },
        .{ .src = "(compare nil 1)", .expected = "-1" },
        .{ .src = "(compare false true)", .expected = "-1" },
        .{ .src = "(compare [1 2] [1 3])", .expected = "-1" },
        .{ .src = "(compare [1 2 3] [9])", .expected = "1" },
        .{ .src = "(max-key count [1 2] [1] [1 2 3])", .expected = "[1 2 3]" },
        .{ .src = "(min-key count [1 2] [1] [1 2 3])", .expected = "[1]" },
        .{ .src = "(max-key :k {:k 1 :n :a} {:k 1 :n :b})", .expected = "{:k 1, :n :b}" },
        .{ .src = "(= (hash [1 2]) (hash '(1 2)))", .expected = "true" },
        .{ .src = "(= (hash 0.0) (hash -0.0))", .expected = "true" },
        .{ .src = "(integer? (hash :a))", .expected = "true" },
    });
}

test "core: predicates, names and conversions" {
    try runCoreCases(&.{
        .{ .src = "[(list? '(1)) (list? [1]) (seq? '(1)) (seq? nil)]", .expected = "[true false true false]" },
        .{ .src = "[(vector? [1]) (vector? '(1)) (map? {}) (map? []) (set? #{}) (set? {})]", .expected = "[true false true false true false]" },
        .{ .src = "[(keyword? :a) (keyword? 'a) (symbol? 'a) (symbol? :a) (string? \"s\")]", .expected = "[true false true false true]" },
        .{ .src = "[(char? \\a) (char? \"a\") (boolean? true) (boolean? nil) (nil? nil) (some? false)]", .expected = "[true false true false true true]" },
        .{ .src = "[(coll? []) (coll? {}) (coll? \"s\") (coll? nil)]", .expected = "[true true false false]" },
        .{ .src = "[(sequential? []) (sequential? '()) (sequential? #{}) (associative? {}) (associative? []) (associative? #{})]", .expected = "[true true false true true false]" },
        .{ .src = "[(fn? inc) (fn? (fn [] 1)) (fn? :a) (ifn? :a) (ifn? {}) (ifn? 1)]", .expected = "[true true false true true false]" },
        .{ .src = "(do (defrecord R [a]) [(map? (->R 1)) (coll? (->R 1))])", .expected = "[true true]" },
        .{ .src = "[(true? true) (true? 1) (false? false) (false? nil)]", .expected = "[true false true false]" },
        .{ .src = "(name :abc)", .expected = "abc" },
        .{ .src = "(name 'x/y)", .expected = "y" },
        .{ .src = "(name \"s\")", .expected = "s" },
        .{ .src = "(try (name 1) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(keyword \"k\")", .expected = ":k" },
        .{ .src = "(keyword 'k)", .expected = ":k" },
        .{ .src = "(= (keyword \"k\") :k)", .expected = "true" },
        .{ .src = "(symbol \"s\")", .expected = "s" },
        .{ .src = "(= (symbol :s) 's)", .expected = "true" },
        .{ .src = "[(boolean nil) (boolean 0) (boolean false)]", .expected = "[false true false]" },
        .{ .src = "(identity :x)", .expected = ":x" },
        .{ .src = "((constantly 7) 1 2 3)", .expected = "7" },
        .{ .src = "((comp inc inc) 1)", .expected = "3" },
        .{ .src = "((comp) 4)", .expected = "4" },
        .{ .src = "((partial + 1 2) 3 4)", .expected = "10" },
        .{ .src = "((juxt inc dec) 5)", .expected = "[6 4]" },
        .{ .src = "((juxt :a :b) {:a 1 :b 2})", .expected = "[1 2]" },
        .{ .src = "((fnil inc 10) nil)", .expected = "11" },
        .{ .src = "((fnil + 10) 1 2)", .expected = "3" },
        .{ .src = "((fnil + 10 20) nil nil 1)", .expected = "31" },
        .{ .src = "((fnil vector 1 2 3) nil 0 nil)", .expected = "[1 0 3]" },
        .{ .src = "((complement odd?) 2)", .expected = "true" },
        .{ .src = "(apply + 1 2 [3 4])", .expected = "10" },
        .{ .src = "(apply max [1 5 2])", .expected = "5" },
        .{ .src = "(apply str \"a\" [\"b\" \"c\"])", .expected = "abc" },
        .{ .src = "(some even? [1 3 4])", .expected = "true" },
        .{ .src = "(some even? [1 3])", .expected = "nil" },
        .{ .src = "(every? odd? [1 3])", .expected = "true" },
        .{ .src = "(every? odd? [])", .expected = "true" },
        .{ .src = "(not-every? odd? [1 2])", .expected = "true" },
        .{ .src = "(not-any? odd? [2 4])", .expected = "true" },
        .{ .src = "(some #{3} [1 2 3])", .expected = "3" },
    });
}

test "core: macros" {
    try runCoreCases(&.{
        .{ .src = "(if-not true :a :b)", .expected = ":b" },
        .{ .src = "(if-not nil :a :b)", .expected = ":a" },
        .{ .src = "(if-not true :a)", .expected = "nil" },
        .{ .src = "(when-not false :a)", .expected = ":a" },
        .{ .src = "(do (def a (atom 0)) (while (< @a 5) (swap! a inc)) @a)", .expected = "5" },
        .{ .src = "(letfn [(ev? [n] (if (zero? n) true (od? (dec n)))) (od? [n] (if (zero? n) false (ev? (dec n))))] (ev? 10))", .expected = "true" },
        .{ .src = "(do (def acc (atom [])) (doseq [x [1 2 3]] (swap! acc conj (* x x))) @acc)", .expected = "[1 4 9]" },
        .{ .src = "(do (def acc (atom [])) (doseq [x [1 2] y [:a :b]] (swap! acc conj [x y])) @acc)", .expected = "[[1 :a] [1 :b] [2 :a] [2 :b]]" },
        .{ .src = "(doseq [x []] :never)", .expected = "nil" },
        .{ .src = "(do (def acc (atom 0)) (doseq [[k v] {:a 1 :b 2}] (swap! acc + v)) @acc)", .expected = "3" },
        .{ .src = "(cond-> 1 true inc false (* 10) true (+ 100))", .expected = "102" },
        .{ .src = "(cond-> {} true (assoc :a 1) nil (assoc :b 2))", .expected = "{:a 1}" },
        .{ .src = "(cond-> 5)", .expected = "5" },
        .{ .src = "(cond->> [1 2 3] true (map inc) false (filter odd?) true (reduce +))", .expected = "9" },
        .{ .src = "(some-> {:a {:b 1}} :a :b inc)", .expected = "2" },
        .{ .src = "(some-> {:a {:b 1}} :c :b inc)", .expected = "nil" },
        .{ .src = "(some-> nil inc)", .expected = "nil" },
        .{ .src = "(some-> 1 (+ 2) (* 3))", .expected = "9" },
        .{ .src = "(some->> [1 2 3] (map inc) (reduce +))", .expected = "9" },
        .{ .src = "(some->> nil (map inc))", .expected = "nil" },
        .{ .src = "(as-> 1 x (+ x 1) (* x 10) [x x])", .expected = "[20 20]" },
        .{ .src = "(as-> {:a 1} m (assoc m :b 2) (count m))", .expected = "2" },
        .{ .src = "(-> 5 inc (* 2) (- 1))", .expected = "11" },
        .{ .src = "(->> [1 2 3] (map inc) (filter odd?) (reduce +))", .expected = "3" },
        .{ .src = "(dotimes [i 3] i)", .expected = "nil" },
        .{ .src = "(when-let [x 1] (inc x))", .expected = "2" },
        .{ .src = "(if-let [x nil] x :none)", .expected = ":none" },
    });
}

// =============================================================================
// VM.throwValue / VM.throwKeyword from native code
// =============================================================================

fn nativeBoom(v: *vm.VM, _: []const value_mod.Value) vm.VmError!value_mod.Value {
    return v.throwKeyword("boom");
}

fn nativeBoomWith(v: *vm.VM, args: []const value_mod.Value) vm.VmError!value_mod.Value {
    return v.throwValue(args[0]);
}

const native_boom = vm.NativeFn{ .name = "boom", .min_arity = 0, .max_arity = 0, .call = &nativeBoom };
const native_boom_with = vm.NativeFn{ .name = "boom-with", .min_arity = 1, .max_arity = 1, .call = &nativeBoomWith };

/// A Program whose core namespace also binds `boom` (throws :boom)
/// and `boom-with` (throws its argument), both from native code.
fn throwingProgram(program: *Program) !void {
    try program.init();
    errdefer program.deinit();
    const boom_var = try program.registry.core.intern("boom");
    boom_var.root = vm.nativeFnValue(&native_boom);
    boom_var.bound = true;
    const with_var = try program.registry.core.intern("boom-with");
    with_var.root = vm.nativeFnValue(&native_boom_with);
    with_var.bound = true;
}

fn expectThrowingOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try throwingProgram(&program);
    defer program.deinit();
    const result = try program.run(src);
    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, result, program.interner);
    testing.expectEqualStrings(expected, buf.items) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, buf.items });
        return err;
    };
}

test "native throw: caught by the innermost handler wherever the native runs" {
    try expectThrowingOutput("(try (boom) (catch any e e))", ":boom");
    try expectThrowingOutput("(try (boom-with {:kind :custom}) (catch any e (:kind e)))", ":custom");
    try expectThrowingOutput("(try (boom-with 42) (catch any e (inc e)))", "43");
    // Through a closure, a higher-order native, apply and nesting.
    try expectThrowingOutput("(try ((fn [] (boom))) (catch any e e))", ":boom");
    try expectThrowingOutput("(try (map (fn [x] (boom-with x)) [1 2]) (catch any e e))", "1");
    try expectThrowingOutput("(try (reduce (fn [a x] (if (= x 3) (boom-with a) (+ a x))) 0 [1 2 3 4]) (catch any e e))", "3");
    try expectThrowingOutput("(try (apply boom []) (catch any e e))", ":boom");
    try expectThrowingOutput("(try (try (boom) (catch any e (boom-with [:again e]))) (catch any e e))", "[:again :boom]");
    // finally runs on the way out, and the VM keeps working afterwards.
    try expectThrowingOutput(
        \\(do
        \\  (def log (atom []))
        \\  (def r (try (boom) (catch any e (swap! log conj :caught) e) (finally (swap! log conj :finally))))
        \\  [r @log (+ 1 2)])
    , "[:boom [:caught :finally] 3]");
    try expectThrowingOutput("(do (defn safe [f] (try (f) (catch any e [:err e]))) [(safe boom) (safe (fn [] :ok))])", "[[:err :boom] :ok]");
}

test "native throw: uncaught surfaces as UncaughtThrow with the value recorded" {
    var program: Program = undefined;
    try throwingProgram(&program);
    defer program.deinit();
    try testing.expectError(vm.VmError.UncaughtThrow, program.run("(boom-with :loose)"));
    const thrown = program.v.unhandled_throw orelse return error.TestFailed;
    try testing.expectEqualStrings("loose", program.interner.keywordName(thrown.asKeywordId()));
}

// =============================================================================
// Unresolved symbols are compile errors located at the symbol
// =============================================================================

fn expectCheckedOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var span: ?reader_mod.SrcSpan = null;
    const result = program.runChecked(src, &span) catch |err| {
        std.debug.print("\n  source: {s}\n  error: {s} at {?}\n", .{ src, @errorName(err), span });
        return err;
    };
    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, result, program.interner);
    testing.expectEqualStrings(expected, buf.items) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, buf.items });
        return err;
    };
}

/// The program must fail to compile with `UnresolvedSymbol`, and the
/// reported span must cover exactly `symbol` in the source.
fn expectUnresolved(src: []const u8, symbol: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var span: ?reader_mod.SrcSpan = null;
    try testing.expectError(compile.CompileError.UnresolvedSymbol, program.runChecked(src, &span));
    const sp = span orelse return error.TestFailed;
    testing.expectEqualStrings(symbol, src[sp.pos .. sp.pos + sp.len]) catch |err| {
        std.debug.print("\n  source: {s}\n  span: {?}\n", .{ src, span });
        return err;
    };
}

test "unresolved symbols: forward references across a file keep working" {
    try expectCheckedOutput("(defn f [] (g)) (defn g [] 42) (f)", "42");
    try expectCheckedOutput("(defn f [] (later 1)) (def later inc) (f)", "2");
    try expectCheckedOutput("(declare later) (defn f [] (later 1)) (defn later [x] (* x 3)) (f)", "3");
    try expectCheckedOutput("(do (defn h [] (i)) (defn i [] :i)) (h)", ":i");
    try expectCheckedOutput("(defmacro m [] 1) (defn f [] (m)) (f)", "1");
    try expectCheckedOutput("(defn uses [] (->P 1 2)) (defrecord P [x y]) (:y (uses))", "2");
    try expectCheckedOutput("(defn a [s] (area s)) (defprotocol Shape (area [s])) (defrecord Sq [w]) (extend-type Sq Shape (area [s] (* (:w s) (:w s)))) (a (->Sq 3))", "9");
    try expectCheckedOutput("(defn f [x] (-> x inc)) (f 1)", "2");
    try expectCheckedOutput("(defn f [] (map inc [1 2])) (f)", "(2 3)");
    try expectCheckedOutput("(defn f [] '(a b c)) (f)", "(a b c)");
    try expectCheckedOutput("(let [{k :k} {:k 5} [p q] [1 2]] (+ k p q))", "8");
    try expectCheckedOutput("(letfn [(ev? [n] (if (zero? n) true (od? (dec n)))) (od? [n] (if (zero? n) false (ev? (dec n))))] (ev? 4))", "true");
    try expectCheckedOutput("(try (throw :x) (catch any e (str e)))", ":x");
    try expectCheckedOutput("(for [x [1 2] y [10 20]] (+ x y))", "(11 21 12 22)");
    try expectCheckedOutput("(def acc (atom [])) (doseq [x [1 2]] (swap! acc conj x)) @acc", "[1 2]");
    try expectCheckedOutput("(ns other) (defn f [] (g)) (defn g [] :other) (f)", ":other");
}

test "unresolved symbols: a reference to nothing is a compile error at the symbol" {
    try expectUnresolved("(defn f [x] (+ x y))", "y");
    try expectUnresolved("(let [a 1]\n  (list a b))", "b");
    try expectUnresolved("(defn f [x]\n  (-> x inc nope dec))", "nope");
    try expectUnresolved("(fn [x] (missing-fn x))", "missing-fn");
    try expectUnresolved("(defn f [] (g)) (defn g [] (h))", "h");
    try expectUnresolved("(if true undefined-a undefined-b)", "undefined-a");
    try expectUnresolved("(let [x 1] x) y", "y");
    try expectUnresolved("(try 1 (catch any e (log e)))", "log");
}

test "unresolved symbols: a symbol a user macro produced is reported at the macro call" {
    // Forms a core.nx (user) macro produces carry the call's span,
    // so the report covers the call rather than the symbol.
    const src = "(letfn [(a [n] (b n))] (a 1))";
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var span: ?reader_mod.SrcSpan = null;
    try testing.expectError(compile.CompileError.UnresolvedSymbol, program.runChecked(src, &span));
    const sp = span orelse return error.TestFailed;
    try testing.expect(sp.pos + sp.len <= src.len);
    try testing.expect(std.mem.indexOf(u8, src[sp.pos .. sp.pos + sp.len], "(b n)") != null);
}

test "unresolved symbols: nothing is interned for a rejected form" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var span: ?reader_mod.SrcSpan = null;
    try testing.expectError(compile.CompileError.UnresolvedSymbol, program.runChecked("(defn f [] (ghost))", &span));
    try testing.expect(program.registry.current.lookupLocal("ghost") == null);
}

test "ex-info: a map thrown and caught, read back with ex-data and ex-message" {
    try expectOutputProgram(
        "(try (throw (ex-info \"boom\" {:code 7})) (catch any e [(ex-message e) (ex-data e)]))",
        "[boom {:code 7}]",
    );
    try expectOutputProgram(
        "(let [e (ex-info \"m\" {:a 1} :why)] [(:message e) (:data e) (:cause e) (map? e)])",
        "[m {:a 1} :why true]",
    );
    try expectOutputProgram("[(ex-data 1) (ex-message :k) (ex-data {:x 1}) (:cause (ex-info \"m\" {}))]", "[nil nil nil nil]");
    // A tag catches an ex-info map through the `:error` of its data.
    try expectOutputProgram(
        "(try (throw (ex-info \"nf\" {:error :not-found :id 3})) (catch :other e :no) (catch :not-found e [(ex-message e) (:id (ex-data e))]))",
        "[nf 3]",
    );
}

test "list*: leading elements before a seq" {
    try expectOutput("(list* 1 2 [3 4])", "(1 2 3 4)");
    try expectOutput("(list* [1 2])", "(1 2)");
    try expectOutput("(list* 1 nil)", "(1)");
    try expectOutput("(list* nil)", "nil");
    try expectOutput("(apply + (list* 1 2 '(3)))", "6");
}

test "reduced: reduce, reductions and reduce-kv stop and unwrap" {
    try expectOutput("(reduce (fn [acc x] (if (> acc 10) (reduced acc) (+ acc x))) 0 [1 2 3 4 5 6 7 8 9])", "15");
    try expectOutput("(reduce (fn [acc x] (if (= x 3) (reduced :stop) (+ acc x))) [1 2 3 4])", ":stop");
    try expectOutput("(reduce (fn [acc x] (reduced x)) 0 [])", "0");
    try expectOutput("(reductions (fn [acc x] (if (= x 3) (reduced :stop) (+ acc x))) 0 [1 2 3 4])", "(0 1 3 :stop)");
    try expectOutput("(reduce-kv (fn [acc i x] (if (= i 2) (reduced acc) (conj acc x))) [] [10 20 30 40])", "[10 20]");
    try expectOutput("[(reduced? (reduced 1)) (reduced? 1) (reduced? {:val 1}) @(reduced 5)]", "[true false false 5]");
    try expectOutput("[(unreduced (reduced 2)) (unreduced 2) (reduced? (ensure-reduced 3)) (reduced? (ensure-reduced (reduced 3)))]", "[2 2 true true]");
}

test "macroexpand: host and user macros, one step and to a fixed head" {
    try expectOutput("(macroexpand-1 '(when a b))", "(if a (do b) nil)");
    try expectOutput("(macroexpand-1 '(+ 1 2))", "(+ 1 2)");
    try expectOutput("(macroexpand-1 'x)", "x");
    try expectOutput("(macroexpand-1 '(if a b))", "(if a b)");
    try expectOutput("(macroexpand '(-> x f g))", "(g (f x))");
    try expectOutput("(macroexpand '(when-not a b))", "(if a nil (do b))");
    try expectOutputProgram("(defmacro twice [x] `(do ~x ~x)) (macroexpand-1 '(twice 1))", "(do 1 1)");
    try expectOutputProgram("(defmacro w [x] `(when ~x 1)) [(macroexpand-1 '(w a)) (macroexpand '(w a))]", "[(nexis.core/when a 1) (if a (do 1) nil)]");
}

test "read-string: forms as data, the first form only, errors thrown" {
    try expectOutput("(read-string \"(+ 1 2)\")", "(+ 1 2)");
    try expectOutput("(read-string \"[1 :a \\\"s\\\" nil true]\")", "[1 :a s nil true]");
    try expectOutput("(first (read-string \"(a b)\"))", "a");
    try expectOutput("(read-string \"{:a 1}\")", "{:a 1}");
    try expectOutput("(read-string \"'x\")", "(quote x)");
    try expectOutput("(read-string \" 42 ; comment\\n 43\")", "42");
    try expectOutput("(try (read-string \"(\") (catch :reader-error e :bad))", ":bad");
    try expectOutput("(try (read-string \"\") (catch :reader-error e :empty))", ":empty");
    try expectOutput("(macroexpand-1 (read-string \"(when a b)\"))", "(if a (do b) nil)");
    // A token has no 64 KiB limit: a long string and symbol round-trip.
    try expectOutput("(count (read-string (pr-str (apply str (repeat 70000 \"a\")))))", "70000");
    try expectOutput("(count (name (read-string (apply str (repeat 70000 \"b\")))))", "70000");
    // Nesting past the stack budget is a reader error, not a fault.
    try expectOutput("(try (read-string (str (apply str (repeat 200000 \"(\")) (apply str (repeat 200000 \")\")))) (catch :reader-error e :deep))", ":deep");
}

// =============================================================================
// eval: a form as data, compiled and run on the calling VM
// (MACROEXPAND.md §1.2 item 9, COMPILER.md §7)
// =============================================================================

test "eval: a form as data compiles in the current namespace and runs on the calling VM" {
    try expectOutput("(eval '(+ 1 2))", "3");
    try expectOutput("(eval (read-string \"(let [x 2] (* x x))\"))", "4");
    try expectOutput("[(eval 5) (eval nil) (eval true) (eval :k) (eval \"s\") (eval '[1 2]) (eval '{:a 1})]", "[5 nil true :k s [1 2] {:a 1}]");
    try expectOutput("(eval (list '+ 1 2 3))", "6");
    try expectOutput("(eval '(eval '(+ 1 1)))", "2");
    try expectOutput("(eval '(eval (read-string \"(eval '(* 3 3))\")))", "9");
    try expectOutput("(let [f (eval '(fn [x] (* x 10)))] (f 4))", "40");
    try expectOutput("(map eval ['(+ 1 1) '(str \"a\" \"b\")])", "(2 ab)");
    // A lexical name is not in scope for the evaluated form.
    try expectOutput("(let [x 1] (try (eval 'x) (catch :compile-error e (:message e))))", "UnresolvedSymbol");
}

test "eval: def binds in the current namespace; a macro it defines serves a later eval" {
    try expectOutputProgram("(eval '(def y 5)) y", "5");
    try expectOutputProgram("(def x 10) (eval '(+ x 1))", "11");
    try expectOutputProgram("(eval '(defn sq [x] (* x x))) (sq 7)", "49");
    try expectOutputProgram("(eval '(defn hello [] \"hello\")) (hello)", "hello");
    try expectOutputProgram("(eval '(defmacro m [x] (list '+ x 1))) [(eval '(m 41)) (m 1)]", "[42 2]");
    try expectOutputProgram("(ns my.app) (eval '(def z 9)) (ns user) [my.app/z (eval 'my.app/z)]", "[9 9]");
    // `(ns ...)` inside eval switches the current namespace, as at the REPL.
    try expectOutputProgram("(eval '(ns other)) (def w 1) (ns user) other/w", "1");
    // A `def` after an `(ns ...)` inside one form binds in the
    // namespace current when the form's compile started, as at the REPL.
    try expectOutputProgram("(eval '(do (ns other) (def w 2))) (ns user) w", "2");
}

test "eval: a compile error is a catchable map; a throw inside the form is an ordinary throw" {
    try expectOutput("(try (eval '(nope 1)) (catch :compile-error e [(:error e) (:message e) (:form e)]))", "[:compile-error UnresolvedSymbol (nope 1)]");
    try expectOutput("(try (eval '(recur 1)) (catch :compile-error e (:message e)))", "RecurOutsideTail");
    try expectOutput("(try (eval '(quote)) (catch :compile-error e (:message e)))", "MalformedForm");
    try expectOutput("(try (eval '(let* [x] x)) (catch :compile-error e (:message e)))", "MacroExpansionFailure");
    try expectOutput("(try (eval (list 'a (fn [] 1))) (catch :compile-error e (:message e)))", "UnsupportedForm");
    try expectOutput("(ex-message (try (eval '(nope)) (catch :compile-error e e)))", "UnresolvedSymbol");
    try expectOutput("(try (eval '(throw :x)) (catch :x e [:caught e]))", "[:caught :x]");
    try expectOutput("(try (eval '(/ 1 0)) (catch :divide-by-zero e e))", ":divide-by-zero");
    try expectOutput("(eval '(try (throw :in) (catch :in e :handled)))", ":handled");
    try expectOutput("(try (eval '(eval '(throw :deep))) (catch :deep e e))", ":deep");
    try expectOutput("[(try (eval '(throw :x)) (catch :x e e)) (eval '(+ 1 1))]", "[:x 2]");
}

test "eval: a form evaluated inside a binding sees the binding" {
    try expectOutputProgram("(def ^:dynamic *x* 1) [(binding [*x* 7] (eval '*x*)) (eval '*x*)]", "[7 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (binding [*x* 7] [(eval '(do (set! *x* 8) *x*)) *x*])", "[8 8]");
    try expectOutputProgram("(def ^:dynamic *x* 1) [(eval '(binding [*x* 3] *x*)) *x*]", "[3 1]");
}

test "eval: a throw out of an evaluated form leaves the caller's frames and trace clean" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const caught = try program.run("(try (eval '(throw :x)) (catch :x e e))");
    try testing.expectEqualStrings("x", program.interner.keywordName(caught.asKeywordId()));
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.handlers.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.error_trace.items.len);
    try testing.expect(program.v.unhandled_throw == null);
    // Uncaught: the evaluated routine is the frame named `<eval>`
    // above the form that called it.
    try testing.expectError(vm.VmError.UncaughtThrow, program.run("(eval '(throw :boom))"));
    const trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 2), trace.len);
    try testing.expectEqualStrings("<eval>", trace[0].name);
    try testing.expectEqualStrings("test-form", trace[1].name);
    program.v.resetAfterError();
    const again = try program.run("(eval '(+ 1 1))");
    try testing.expectEqual(@as(i64, 2), again.asFixnum());
}

test "eval: what an evaluated form allocates survives a collection" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(eval '(defn greet [] \"hello\")) (def f (eval '(fn [] (str \"a\" \"b\")))) (def q (eval ''(1 \"two\" :three)))");
    // Between runs the top frame rests on the VM's idle routine, so
    // a collection here marks nothing of the last run's routine.
    program.v.collectGarbage();
    const out = try program.run("(str (greet) (f) q)");
    try testing.expectEqualStrings("helloab(1 \"two\" :three)", string_mod.asBytes(out));
}

test "eval: a VM without compiler hooks throws :no-compiler" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.compiler_hooks = null;
    const out = try program.run("(try (eval '(+ 1 1)) (catch :no-compiler e e))");
    try testing.expectEqualStrings("no-compiler", program.interner.keywordName(out.asKeywordId()));
}

// =============================================================================
// Typed vectors (docs/TYPED_VECTOR.md §7)
// =============================================================================

test "typed vectors: constructors, type, printing and the generic natives" {
    try runCoreCases(&.{
        .{ .src = "(i64-vector [1 2 3])", .expected = "#i64[1 2 3]" },
        .{ .src = "(f64-vector [1 2.5 3])", .expected = "#f64[1.0 2.5 3.0]" },
        .{ .src = "(i64-vector nil)", .expected = "#i64[]" },
        .{ .src = "(f64-vector '(1 2))", .expected = "#f64[1.0 2.0]" },
        .{ .src = "(i64-vector (range 5))", .expected = "#i64[0 1 2 3 4]" },
        .{ .src = "(f64-vector #{1})", .expected = "#f64[1.0]" },
        .{ .src = "(f64-vector (i64-vector [1 2]))", .expected = "#f64[1.0 2.0]" },
        .{ .src = "(pr-str (f64-vector [10000000000.0 (/ 1.0 0) (/ -1.0 0)]))", .expected = "#f64[1.0E10 Infinity -Infinity]" },
        .{ .src = "(i64-vector [140737488355328 -140737488355329])", .expected = "#i64[140737488355328 -140737488355329]" },
        .{ .src = "(nth (i64-vector [140737488355328]) 0)", .expected = "140737488355328" },
        .{ .src = "(i64-vector [9223372036854775807])", .expected = "#i64[9223372036854775807]" },
        .{ .src = "(typed-vector? (i64-vector [1]))", .expected = "true" },
        .{ .src = "(typed-vector? (f64-vector []))", .expected = "true" },
        .{ .src = "(typed-vector? [1])", .expected = "false" },
        .{ .src = "(typed-vector-type (i64-vector [1]))", .expected = ":i64" },
        .{ .src = "(typed-vector-type (f64-vector [1]))", .expected = ":f64" },
        .{ .src = "(count (i64-vector [1 2 3]))", .expected = "3" },
        .{ .src = "(count (f64-vector []))", .expected = "0" },
        .{ .src = "(empty? (f64-vector []))", .expected = "true" },
        .{ .src = "(empty? (i64-vector [1]))", .expected = "false" },
        .{ .src = "(nth (i64-vector [10 20]) 1)", .expected = "20" },
        .{ .src = "(nth (f64-vector [10 20]) 1)", .expected = "20.0" },
        .{ .src = "(nth (i64-vector [10 20]) 5 :d)", .expected = ":d" },
        .{ .src = "(get (i64-vector [10 20]) 0)", .expected = "10" },
        .{ .src = "(get (f64-vector [10 20]) 1)", .expected = "20.0" },
        .{ .src = "(get (i64-vector [10 20]) 2)", .expected = "nil" },
        .{ .src = "(get (i64-vector [10 20]) -1 :d)", .expected = ":d" },
        .{ .src = "(get (i64-vector [10 20]) :k :d)", .expected = ":d" },
        .{ .src = "[(contains? (i64-vector [10 20]) 0) (contains? (i64-vector [10 20]) 1) (contains? (f64-vector [10 20]) 1)]", .expected = "[true true true]" },
        .{ .src = "[(contains? (i64-vector [10 20]) 2) (contains? (i64-vector [10 20]) -1) (contains? (i64-vector [10 20]) :k) (contains? (f64-vector []) 0)]", .expected = "[false false false false]" },
        .{ .src = "(seq (i64-vector [1 2]))", .expected = "(1 2)" },
        .{ .src = "(seq (i64-vector []))", .expected = "nil" },
        .{ .src = "(first (f64-vector [1.5 2]))", .expected = "1.5" },
        .{ .src = "(rest (i64-vector [1 2 3]))", .expected = "(2 3)" },
        .{ .src = "(next (i64-vector [1]))", .expected = "nil" },
        .{ .src = "(vec (i64-vector [1 2 3]))", .expected = "[1 2 3]" },
        .{ .src = "(vector? (vec (f64-vector [1])))", .expected = "true" },
        .{ .src = "(reduce + (i64-vector [1 2 3]))", .expected = "6" },
        .{ .src = "(reduce + 0.5 (f64-vector [1 2]))", .expected = "3.5" },
        .{ .src = "(into [] (i64-vector [1 2]))", .expected = "[1 2]" },
        .{ .src = "(into #{} (f64-vector [1 1]))", .expected = "#{1.0}" },
        .{ .src = "(into '() (i64-vector [1 2]))", .expected = "(2 1)" },
        .{ .src = "(map inc (i64-vector [1 2]))", .expected = "(2 3)" },
        .{ .src = "(mapv (fn [x] (* x 2)) (f64-vector [1 2]))", .expected = "[2.0 4.0]" },
        .{ .src = "(filter odd? (i64-vector [1 2 3]))", .expected = "(1 3)" },
        .{ .src = "(apply + (i64-vector [1 2 3]))", .expected = "6" },
        .{ .src = "(sort (i64-vector [3 1 2]))", .expected = "(1 2 3)" },
        .{ .src = "(let [[a b] (i64-vector [7 8])] (+ a b))", .expected = "15" },
        .{ .src = "(str (i64-vector [1 2]) \"!\")", .expected = "#i64[1 2]!" },
        .{ .src = "(coll? (i64-vector [1]))", .expected = "false" },
        .{ .src = "(sequential? (i64-vector [1]))", .expected = "false" },
        .{ .src = "(vector? (i64-vector [1]))", .expected = "false" },
    });
}

test "typed vectors: equality, hash and identity" {
    try runCoreCases(&.{
        .{ .src = "(= (i64-vector [1 2]) (i64-vector [1 2]))", .expected = "true" },
        .{ .src = "(= (i64-vector [1 2]) (i64-vector [1 3]))", .expected = "false" },
        .{ .src = "(= (i64-vector [1 2]) (i64-vector [1]))", .expected = "false" },
        .{ .src = "(= (i64-vector [1 2]) (f64-vector [1 2]))", .expected = "false" },
        .{ .src = "(= (i64-vector [1 2]) [1 2])", .expected = "false" },
        .{ .src = "(= [1 2] (i64-vector [1 2]))", .expected = "false" },
        .{ .src = "(= (i64-vector [1 2]) '(1 2))", .expected = "false" },
        .{ .src = "(= (i64-vector []) [])", .expected = "false" },
        .{ .src = "(= (f64-vector [0.0]) (f64-vector [-0.0]))", .expected = "true" },
        .{ .src = "(= (f64-vector [(/ 0.0 0)]) (f64-vector [(/ 0.0 0)]))", .expected = "true" },
        .{ .src = "(= (hash (i64-vector [1 2])) (hash (i64-vector [1 2])))", .expected = "true" },
        .{ .src = "(= (hash (f64-vector [0.0])) (hash (f64-vector [-0.0])))", .expected = "true" },
        .{ .src = "(= (hash (i64-vector [1 2])) (hash [1 2]))", .expected = "false" },
        .{ .src = "(let [v (i64-vector [1])] (identical? v v))", .expected = "true" },
        .{ .src = "(identical? (i64-vector [1]) (i64-vector [1]))", .expected = "false" },
        .{ .src = "(get {(i64-vector [1 2]) :hit} (i64-vector [1 2]))", .expected = ":hit" },
        .{ .src = "(contains? #{(f64-vector [1])} (f64-vector [1.0]))", .expected = "true" },
    });
}

test "typed vectors: constructor errors and the absent update operations" {
    try runCoreCases(&.{
        .{ .src = "(try (i64-vector [1.5]) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (i64-vector [:a]) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (i64-vector [18446744073709551616]) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (f64-vector [\"1\"]) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (i64-vector 5) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (typed-vector-type [1]) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (nth (i64-vector [1]) 1) (catch any e e))", .expected = ":index-out-of-bounds" },
        .{ .src = "(try (nth (i64-vector [1]) -1) (catch any e e))", .expected = ":index-out-of-bounds" },
        .{ .src = "(try (nth (f64-vector []) 0) (catch any e e))", .expected = ":index-out-of-bounds" },
        .{ .src = "(try (conj (i64-vector [1]) 2) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (assoc (i64-vector [1]) 0 2) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (pop (i64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (peek (i64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (subvec (i64-vector [1]) 0) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (empty (i64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try ((i64-vector [1]) 0) (catch any e e))", .expected = ":not-callable" },
        .{ .src = "(try (with-meta (i64-vector [1]) {}) (catch any e e))", .expected = ":kind-mismatch" },
    });
}

test "typed vectors: nexis.simd kernels" {
    // The harness has no loader, so `(require '[nexis.simd :as tv])`
    // is not available here; the namespace is installed beside core
    // and reached by its full name.
    try runCoreCases(&.{
        .{ .src = "(nexis.simd/sum (i64-vector [1 2 3]))", .expected = "6" },
        .{ .src = "(nexis.simd/sum (f64-vector [1 2 3 4 5 6 7 8 9]))", .expected = "45.0" },
        .{ .src = "(nexis.simd/sum (i64-vector []))", .expected = "0" },
        .{ .src = "(nexis.simd/sum (f64-vector []))", .expected = "0.0" },
        .{ .src = "(nexis.simd/sum (i64-vector [9223372036854775807]))", .expected = "9223372036854775807" },
        .{ .src = "(nexis.simd/sum (i64-vector [9223372036854775807 1]))", .expected = "9223372036854775808" },
        .{ .src = "(nexis.simd/sum (i64-vector [-9223372036854775808 -9223372036854775808]))", .expected = "-18446744073709551616" },
        .{ .src = "(let [xs (i64-vector [9223372036854775807 9223372036854775807 -5])] (= (nexis.simd/sum xs) (reduce + xs)))", .expected = "true" },
        .{ .src = "(nexis.simd/dot (i64-vector [1 2 3]) (i64-vector [4 5 6]))", .expected = "32" },
        .{ .src = "(nexis.simd/dot (f64-vector [1 2 3 4 5]) (f64-vector [1 1 1 1 1]))", .expected = "15.0" },
        .{ .src = "(nexis.simd/dot (f64-vector []) (f64-vector []))", .expected = "0.0" },
        .{ .src = "(try (nexis.simd/dot (i64-vector [1]) (f64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (nexis.simd/dot (i64-vector [1]) (i64-vector [1 2])) (catch any e e))", .expected = ":invalid-argument" },
        .{ .src = "(nexis.simd/dot (i64-vector [4611686018427387904]) (i64-vector [4]))", .expected = "18446744073709551616" },
        .{ .src = "(nexis.simd/dot (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808]) (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808]))", .expected = "340282366920938463463374607431768211456" },
        .{ .src = "(nexis.simd/dot (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808 1]) (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808 -1]))", .expected = "340282366920938463463374607431768211455" },
        .{ .src = "(let [xs (i64-vector [9223372036854775807 -9223372036854775808 3]) ys (i64-vector [9223372036854775807 9223372036854775807 -1])] (= (nexis.simd/dot xs ys) (reduce + (map * xs ys))))", .expected = "true" },
        .{ .src = "(try (nexis.simd/dot [1] (i64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(nexis.simd/scale (i64-vector [1 2 3]) 10)", .expected = "#i64[10 20 30]" },
        .{ .src = "(nexis.simd/scale (f64-vector [1 2 3 4 5]) 0.5)", .expected = "#f64[0.5 1.0 1.5 2.0 2.5]" },
        .{ .src = "(nexis.simd/scale (f64-vector [1 2]) 2)", .expected = "#f64[2.0 4.0]" },
        .{ .src = "(try (nexis.simd/scale (i64-vector [1]) 1.5) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (nexis.simd/scale (i64-vector [4611686018427387904]) 2) (catch any e e))", .expected = ":arithmetic-overflow" },
        .{ .src = "(nexis.simd/map (fn [x] (* x x)) (i64-vector [1 2 3]))", .expected = "#i64[1 4 9]" },
        .{ .src = "(nexis.simd/map (fn [x] (/ x 2)) (f64-vector [1 2 3]))", .expected = "#f64[0.5 1.0 1.5]" },
        .{ .src = "(nexis.simd/map (fn [x] (/ x 2)) (i64-vector [4 6]))", .expected = "#i64[2 3]" },
        .{ .src = "(nexis.simd/map inc (f64-vector []))", .expected = "#f64[]" },
        .{ .src = "(try (nexis.simd/map (fn [x] (/ x 2)) (i64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (nexis.simd/map str (f64-vector [1])) (catch any e e))", .expected = ":kind-mismatch" },
        .{ .src = "(try (nexis.simd/map (fn [x] (throw :inner)) (i64-vector [1])) (catch :inner e :caught))", .expected = ":caught" },
        .{ .src = "(nexis.simd/map (fn [x] (* x 140737488355328)) (i64-vector [1 2]))", .expected = "#i64[140737488355328 281474976710656]" },
    });
}

test "typed vectors: a store round trip through the codec" {
    try expectOutputProgramWithStore("typed-vectors",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def r (db/ref conn :tv "k"))
        \\  (with-tx [tx conn] (db/put! tx r (i64-vector [1 -2 140737488355328])))
        \\  (def i (with-read-tx [tx conn] (db/get tx r)))
        \\  (with-tx [tx conn] (db/put! tx r (f64-vector [0.5 -0.0 (/ 1.0 0)])))
        \\  (def f (with-read-tx [tx conn] (db/get tx r)))
        \\  [i (typed-vector-type i) (= i (i64-vector [1 -2 140737488355328])) f (typed-vector-type f) (= f (f64-vector [0.5 0.0 (/ 1.0 0)]))])
    , "[#i64[1 -2 140737488355328] :i64 true #f64[0.5 -0.0 Infinity] :f64 true]");
}

// =============================================================================
// The collector under a forced-frequent trigger (VM.md §9, GC.md §7)
// =============================================================================

/// `expectOutputProgram` on a VM whose collector is due every few
/// kilobytes, so a native's callback runs through many cycles; the
/// program must yield `expected` and at least one cycle must have run.
fn expectOutputUnderGc(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.gc_threshold = vm.GcPolicy.stress.threshold;
    program.v.gc_growth_percent = vm.GcPolicy.stress.growth_percent;
    program.v.gc_next_at = vm.GcPolicy.stress.threshold;
    const last_result = try program.run(src);
    try testing.expect(program.v.gc_cycles > 0);

    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, last_result, program.interner);
    testing.expectEqualStrings(expected, buf.items) catch |err| {
        std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, buf.items });
        return err;
    };
}

/// Every callback of these programs allocates a few kilobytes of
/// garbage, so a cycle runs inside the native while it holds earlier
/// results, and the results must still be intact afterwards.
const churn = "(defn churn [x] (count (apply str (map (fn [i] (str x i)) (range 200))))) ";

test "gc: map, filter, keep, map-indexed and mapv keep their earlier results across cycles" {
    try expectOutputUnderGc(churn ++ "(let [xs (map (fn [x] (churn x) (str x \"!\")) (range 60))] [(count xs) (first xs) (last xs)])", "[60 0! 59!]");
    try expectOutputUnderGc(churn ++ "(count (filter (fn [x] (churn x) (even? x)) (range 60)))", "30");
    try expectOutputUnderGc(churn ++ "(last (keep (fn [x] (churn x) (when (even? x) (str x))) (range 60)))", "58");
    try expectOutputUnderGc(churn ++ "(last (map-indexed (fn [i x] (churn i) (str i x)) (range 40)))", "3939");
    try expectOutputUnderGc(churn ++ "(peek (mapv (fn [x] (churn x) (vector x x)) (range 40)))", "[39 39]");
}

test "gc: reduce, reductions, sort-by, max-key, repeatedly and iterate survive cycles inside their callbacks" {
    try expectOutputUnderGc(churn ++ "(reduce (fn [acc x] (churn x) (str acc x)) \"\" (range 30))", "01234567891011121314151617181920212223242526272829");
    try expectOutputUnderGc(churn ++ "(last (reductions (fn [acc x] (churn x) (str acc x)) \"\" (range 30)))", "01234567891011121314151617181920212223242526272829");
    try expectOutputUnderGc(churn ++ "(sort-by (fn [x] (churn x) (str (- 10 x))) (range 12))", "(11 10 9 0 8 7 6 5 4 3 2 1)");
    try expectOutputUnderGc(churn ++ "(apply max-key (fn [x] (churn x) (count (str x))) (range 30))", "29");
    try expectOutputUnderGc(churn ++ "(count (repeatedly 30 (fn [] (churn 1) (str \"r\"))))", "30");
    try expectOutputUnderGc(churn ++ "(last (iterate (fn [s] (churn s) (str s \"x\")) \"\" 20))", "xxxxxxxxxxxxxxxxxxx");
}

test "gc: a vector view alone keeps its vector alive across cycles" {
    // LIST.md §1: nothing but the view block reaches the vector here.
    try expectOutputUnderGc(churn ++ "(reduce (fn [acc x] (churn x) (str acc x)) \"\" (rest (mapv str (range 30))))", "1234567891011121314151617181920212223242526272829");
    try expectOutputUnderGc(churn ++ "(loop [s (seq (mapv str (range 60))) acc 0] (if s (do (churn 1) (recur (next s) (+ acc (count (first s))))) acc))", "110");
    try expectOutputUnderGc(churn ++ "(let [s (drop 1050 (mapv str (range 1100)))] (churn 1) [(count s) (first s) (last s)])", "[50 1050 1099]");
}

/// A map receiver: every element a native sees is a `[k v]` entry
/// the iterator builds, reachable from no argument.
const zmap = "(def m (zipmap (range 40) (range 40))) ";

test "gc: over a map, the entries a native keeps across its callbacks survive cycles" {
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (filter (fn [e] (churn (key e)) (even? (val e))) m)] [(count r) (reduce + (map val r))])", "[20 380]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (remove (fn [e] (churn (key e)) (even? (val e))) m)] [(count r) (reduce + (map val r))])", "[20 400]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (filterv (fn [e] (churn (key e)) true) m)] [(count r) (reduce + (map key r))])", "[40 780]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (take-while (fn [e] (churn (key e)) true) m)] [(count r) (reduce + (map val r))])", "[40 780]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (sort (fn [a b] (churn (key a)) (< (key a) (key b))) m)] [(first r) (last r)])", "[[0 0] [39 39]]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (sort-by (fn [e] (churn (key e)) (- (key e))) m)] [(first r) (last r)])", "[[39 39] [0 0]]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (reductions (fn [a e] (churn (key e)) e) m)] [(count r) (reduce + (map val r))])", "[40 780]");
    try expectOutputUnderGc(churn ++ "(defrecord P [a b c]) (count (filter (fn [e] (churn (key e)) true) (->P 1 2 3)))", "3");
}

test "gc: swap!, alter-meta!, apply and a closure over a loop survive cycles" {
    try expectOutputUnderGc(churn ++ "(let [a (atom [])] (dotimes [i 40] (swap! a (fn [v] (churn i) (conj v (str i))))) [(count @a) (last @a)])", "[40 39]");
    try expectOutputUnderGc(churn ++ "(def v 1) (dotimes [i 20] (alter-meta! (var v) (fn [m] (churn i) (assoc m :i (str i))))) (meta (var v))", "{:i 19}");
    try expectOutputUnderGc(churn ++ "(apply str (map (fn [x] (churn x) (str x)) (range 20)))", "012345678910111213141516171819");
    try expectOutputUnderGc(churn ++ "(let [fs (map (fn [x] (fn [] (churn x) (str x))) (range 20))] (apply str (map (fn [f] (f)) fs)))", "012345678910111213141516171819");
}

test "gc: db/reduce-tree and db/alter! survive cycles inside their callbacks" {
    var store = try SeamStore.init("gc-reduce-tree");
    defer store.deinit();
    // One digit per value: 30 values.
    const src = try store.source(churn ++
        \\(def conn (db/open "@STORE@"))
        \\(with-tx [tx conn] (dotimes [i 30] (db/put! tx (db/ref conn :t (str "k" i)) (str "v" i))))
        \\(with-tx [tx conn] (db/alter! tx (db/ref conn :t "k0") (fn [old] (churn old) (str old "+"))))
        \\(def total (with-read-tx [tx conn] (db/reduce-tree tx :t (fn [acc k v] (churn v) (str acc (count v))) "")))
        \\(def first-value (with-read-tx [tx conn] (db/get tx (db/ref conn :t "k0"))))
        \\(db/close conn)
        \\[(count total) first-value]
    );
    defer testing.allocator.free(src);
    try expectOutputUnderGc(src, "[30 v0+]");
}

// =============================================================================
// ^:dynamic Vars and binding (VM.md §6.5)
// =============================================================================

test "binding: nesting, restoration, and a closure seeing the binding in force at the call" {
    try expectOutputProgram("(def ^:dynamic *x* 1) (defn read-x [] *x*) [(binding [*x* 2] [*x* (read-x)]) *x* (read-x)]", "[[2 2] 1 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (def ^:dynamic *y* 10) (binding [*x* 2 *y* 3] [*x* *y* (binding [*x* 4] [*x* *y*]) *x*])", "[2 3 [4 3] 2]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (let [f (fn [] *x*)] [(f) (binding [*x* 5] (f)) (f)])", "[1 5 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (binding [*x* (+ *x* 10)] (binding [*x* (+ *x* 100)] *x*))", "111");
    try expectOutputProgram("(def ^:dynamic *x* 1) [(thread-bound? (var *x*)) (binding [*x* 0] (thread-bound? (var *x*)))]", "[false true]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (def ^:dynamic *y* 2) (binding [*x* *y* *y* *x*] [*x* *y*])", "[2 1]");
}

test "binding: a throw through binding restores the root before the catch runs" {
    try expectOutputProgram("(def ^:dynamic *x* 1) (try (binding [*x* 9] (throw :boom)) (catch :boom e [e *x*]))", "[:boom 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (defn boom [] (throw :boom)) [(try (binding [*x* 2] (binding [*x* 3] (boom))) (catch :boom _ *x*)) *x*]", "[1 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) [(binding [*x* 2] (try (binding [*x* 3] (throw :in)) (catch :in _ *x*))) *x*]", "[2 1]");
}

test "binding: only a dynamic Var can be bound; set! rebinds the innermost binding" {
    try expectOutputProgram("(def plain 1) (try (binding [plain 2] plain) (catch :not-dynamic e e))", ":not-dynamic");
    try expectOutputProgram("(def plain 1) (def ^:dynamic *x* 1) [(try (binding [*x* 2 plain 2] plain) (catch :not-dynamic e e)) (thread-bound? (var *x*))]", "[:not-dynamic false]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (defn read-x [] *x*) [(binding [*x* 2] (set! *x* 7) (read-x)) *x*]", "[7 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (binding [*x* 2] (binding [*x* 3] (set! *x* 4)) *x*)", "2");
    try expectOutputProgram("(def ^:dynamic *x* 1) (try (set! *x* 5) (catch :no-thread-binding e [e *x*]))", "[:no-thread-binding 1]");
    try expectOutputProgram("(def plain 1) (try (set! plain 5) (catch :not-dynamic e [e plain]))", "[:not-dynamic 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (meta (var *x*))", "{:dynamic true}");
}

// =============================================================================
// Runtime errors carry their source location and the frame chain
// =============================================================================

/// Run `src` the way the CLI does, with one `SourceInfo` every
/// routine points at; the error the run fails with is returned and
/// `program.v.error_trace` is left for the caller to inspect.
fn runLocated(program: *Program, info: *const vm.SourceInfo) anyerror!value_mod.Value {
    var parse_result = try reader_mod.parser.parseProgram(testing.allocator, info.text);
    defer parse_result.parser.deinit();
    var rdr = reader_mod.Reader.init(testing.allocator, info.text);
    defer rdr.deinit();
    const forms = try rdr.readProgram(parse_result.sexp);
    var declared = compile.DeclaredNames.init(testing.allocator);
    defer declared.deinit();
    for (forms) |form| try declared.declareForm(form);
    var last: value_mod.Value = value_mod.nilValue();
    for (forms) |form| {
        const compiled = try compile.compileFormWith(program.arena.allocator(), form, .{
            .namespace = program.registry.current,
            .interner = program.interner,
            .host_macros = &program.host_macros,
            .persistent_allocator = program.v.runtime_arena.allocator(),
            .registry = program.registry,
            .declared = &declared,
            .source = info,
        });
        const routine = compiled.toRoutine("<top>");
        try program.v.retargetTop(&routine);
        last = try program.v.run();
    }
    return last;
}

/// The frame at `index` of the recorded trace must be named `name`
/// and sit on `line`:`col` of the source, over the text `covers`.
fn expectFrame(program: *Program, info: *const vm.SourceInfo, index: usize, name: []const u8, line: u32, col: u32, covers: []const u8) !void {
    const trace = program.v.error_trace.items;
    try testing.expect(index < trace.len);
    const frame = trace[index];
    try testing.expectEqualStrings(name, frame.name);
    try testing.expect(frame.source == info);
    const span = frame.span orelse return error.TestFailed;
    const loc = info.lineCol(span.pos);
    try testing.expectEqual(line, loc.line);
    try testing.expectEqual(col, loc.col);
    try testing.expectEqualStrings(covers, info.text[span.pos .. span.pos + span.len]);
}

test "runtime errors: a VmError is located at the form that raised it, with the frame chain" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "t.nx", .text = "(defn f [x]\n  (/ 10 x))\n\n(defn g [x] (f x))\n(g 0)" };
    try testing.expectError(vm.VmError.DivideByZero, runLocated(&program, &info));
    try testing.expectEqual(@as(usize, 3), program.v.error_trace.items.len);
    try expectFrame(&program, &info, 0, "f", 2, 3, "(/ 10 x)");
    try expectFrame(&program, &info, 1, "g", 4, 13, "(f x)");
    try expectFrame(&program, &info, 2, "<top>", 5, 1, "(g 0)");
}

test "runtime errors: an uncaught throw records the value and a two-deep chain" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "t.nx", .text = "(defn inner [] (throw :boom))\n(defn outer [] (inner))\n(outer)" };
    try testing.expectError(vm.VmError.UncaughtThrow, runLocated(&program, &info));
    const thrown = program.v.unhandled_throw orelse return error.TestFailed;
    try testing.expectEqualStrings("boom", program.interner.keywordName(thrown.asKeywordId()));
    try expectFrame(&program, &info, 0, "inner", 1, 16, "(throw :boom)");
    try expectFrame(&program, &info, 1, "outer", 2, 16, "(inner)");
    try expectFrame(&program, &info, 2, "<top>", 3, 1, "(outer)");
}

test "runtime errors: a closure called back from a native is the frame named fn" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "t.nx", .text = "(map (fn [x] (/ 1 x)) [1 0])" };
    try testing.expectError(vm.VmError.DivideByZero, runLocated(&program, &info));
    try expectFrame(&program, &info, 0, "fn", 1, 14, "(/ 1 x)");
    try expectFrame(&program, &info, 1, "<top>", 1, 1, "(map (fn [x] (/ 1 x)) [1 0])");
}

/// Compile one form of `src` into a routine the caller owns, the
/// way the loader compiles a required file's forms.
fn compileRoutineForTest(program: *Program, src: []const u8) !vm.Routine {
    var parse_result = try reader_mod.parser.parseForm(program.arena.allocator(), src);
    defer parse_result.parser.deinit();
    var rdr = reader_mod.Reader.init(program.arena.allocator(), src);
    defer rdr.deinit();
    const form = try rdr.readOneForm(parse_result.sexp);
    var declared = compile.DeclaredNames.init(testing.allocator);
    defer declared.deinit();
    try declared.declareForm(form);
    const compiled = try compile.compileFormWith(program.arena.allocator(), form, .{
        .namespace = program.registry.current,
        .interner = program.interner,
        .host_macros = &program.host_macros,
        .persistent_allocator = program.v.runtime_arena.allocator(),
        .registry = program.registry,
        .declared = &declared,
    });
    return compiled.toRoutine("nested");
}

var nested_routine: ?*const vm.Routine = null;

fn nativeNestedRun(v: *vm.VM, _: []const value_mod.Value) vm.VmError!value_mod.Value {
    return v.runRoutine(nested_routine.?);
}

const native_nested_run = vm.NativeFn{ .name = "nested-run", .min_arity = 0, .max_arity = 0, .call = &nativeNestedRun };

test "runRoutine: a top-level routine runs as a nested call inside an executing program" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const nested_var = try program.registry.core.intern("nested-run");
    nested_var.root = vm.nativeFnValue(&native_nested_run);
    nested_var.bound = true;

    var adder = try compileRoutineForTest(&program, "(do (def seen 40) (+ seen 2))");
    nested_routine = &adder;
    defer nested_routine = null;
    // Mid-execution: a local is live below the nested frame and
    // survives it; the defined Var is visible afterwards.
    const result = try program.run("(let [a 1] (+ a (nested-run)))");
    try testing.expectEqual(@as(i64, 43), result.asFixnum());
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    const seen = try program.run("seen");
    try testing.expectEqual(@as(i64, 40), seen.asFixnum());
    // Idle: the same call on a VM between runs.
    const idle = try program.v.runRoutine(&adder);
    try testing.expectEqual(@as(i64, 42), idle.asFixnum());
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);

    // A throw out of the nested routine reaches the program's handler.
    var thrower = try compileRoutineForTest(&program, "(throw :inner)");
    nested_routine = &thrower;
    const caught = try program.run("(try (nested-run) (catch :inner e [:caught e]))");
    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, caught, program.interner);
    try testing.expectEqualStrings("[:caught :inner]", buf.items);
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
}

test "between runs the top frame rests on the idle routine, so a collection is safe" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(def xs (mapv inc [1 2 3]))");
    try testing.expect(program.v.frames.items[0].routine == &vm.VM.idle_routine);
    program.v.collectGarbage();
    const again = try program.run("(reduce + xs)");
    try testing.expectEqual(@as(i64, 9), again.asFixnum());
    try testing.expect(program.v.frames.items[0].routine == &vm.VM.idle_routine);
    // A failed run keeps its frames for the trace; the reset parks
    // the top frame on the idle routine too.
    try testing.expectError(vm.VmError.DivideByZero, program.run("(/ 1 0)"));
    program.v.resetAfterError();
    try testing.expect(program.v.frames.items[0].routine == &vm.VM.idle_routine);
    program.v.collectGarbage();
    const after = try program.run("(count xs)");
    try testing.expectEqual(@as(i64, 3), after.asFixnum());
}

// =============================================================================
// `require` through the loader (TOOLING.md §1, VM.md §13)
// =============================================================================

/// A temporary directory of `.nx` files and a Loader over it,
/// attached to `program` as its load callback.
const RequireDir = struct {
    tmp: std.testing.TmpDir,
    dir_path: []u8,
    load_paths: [1][]const u8,
    loader: loader_mod.Loader,

    fn init(self: *RequireDir, program: *Program, files: []const [2][]const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.dir_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        errdefer testing.allocator.free(self.dir_path);
        const io = std.testing.io;
        for (files) |f| {
            const path = try std.fs.path.join(testing.allocator, &.{ self.dir_path, f[0] });
            defer testing.allocator.free(path);
            const file = try std.Io.Dir.cwd().createFile(io, path, .{});
            defer file.close(io);
            try file.writeStreamingAll(io, f[1]);
        }
        self.load_paths = .{self.dir_path};
        self.loader = loader_mod.Loader.init(
            testing.allocator,
            program.v.runtime_arena.allocator(),
            io,
            &self.load_paths,
            &program.v,
            program.interner,
            program.registry,
            &program.host_macros,
        );
        // The namespaces the program installed have no file.
        var names = program.registry.map.keyIterator();
        while (names.next()) |name| try self.loader.markLoaded(name.*);
        program.hooks.load_callback = self.callback();
    }

    fn callback(self: *RequireDir) expand_mod.LoadCallback {
        return .{ .user_data = @ptrCast(&self.loader), .load = &loader_mod.Loader.loadCallback };
    }

    fn deinit(self: *RequireDir) void {
        self.loader.deinit();
        testing.allocator.free(self.dir_path);
        self.tmp.cleanup();
    }

    /// Compile `src` (one form) with the loader in place, so a
    /// `require` in it runs while the form is being compiled.
    fn compileOne(self: *RequireDir, program: *Program, src: []const u8) !compile.Compiled {
        var parse_result = try reader_mod.parser.parseProgram(testing.allocator, src);
        defer parse_result.parser.deinit();
        var rdr = reader_mod.Reader.init(testing.allocator, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parse_result.sexp);
        return compile.compileFormWith(program.arena.allocator(), forms[0], .{
            .namespace = program.registry.current,
            .interner = program.interner,
            .host_macros = &program.host_macros,
            .persistent_allocator = program.v.runtime_arena.allocator(),
            .registry = program.registry,
            .load_callback = self.callback(),
        });
    }
};

/// Run every top-level form of `src`, as `nexis run` does, with a
/// loader over `files` as each form's load callback, and compare the
/// last form's printed value with `expected`.
fn expectOutputWithFiles(files: []const [2][]const u8, src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var dir: RequireDir = undefined;
    try dir.init(&program, files);
    defer dir.deinit();
    var parsed = try reader_mod.parser.parseProgram(testing.allocator, src);
    defer parsed.parser.deinit();
    var rdr = reader_mod.Reader.init(testing.allocator, src);
    defer rdr.deinit();
    var last = value_mod.nilValue();
    for (try rdr.readProgram(parsed.sexp)) |form| {
        const compiled = try compile.compileFormWith(program.arena.allocator(), form, .{
            .namespace = program.registry.current,
            .interner = program.interner,
            .host_macros = &program.host_macros,
            .persistent_allocator = program.v.runtime_arena.allocator(),
            .registry = program.registry,
            .load_callback = dir.callback(),
        });
        const routine = compiled.toRoutine("test-form");
        try program.v.retargetTop(&routine);
        last = try program.v.run();
    }
    try harness.expectResult(&program, src, last, expected);
}

const utilns = [2][]const u8{ "util.nx", "(ns util)\n(defn twice [x] (* 2 x))\n(def ^:private secret 1)\n(defn half [x] (quot x 2))\n" };

test "ns: (:refer-clojure :exclude [names]) leaves those names to the namespace" {
    // A form compiled before the namespace's own + calls it, not core's inlined +.
    try expectOutputProgram("(ns ex (:refer-clojure :exclude [+ when])) (defn f [] (+ 1 2)) (defn + [a b] (str a b)) (f)", "12");
    try expectOutputProgram("(ns ex (:refer-clojure :exclude [when])) (defn when [x] [:mine x]) (when 1)", "[:mine 1]");
    try expectOutputProgram("(ns ex (:refer-clojure :exclude [inc])) [(nexis.core/inc 1) (try (inc 1) (catch any e e))]", "[2 :unbound-var]");
    try expectOutputProgram("(ns ex (:refer-clojure :exclude [inc])) `(inc 1)", "(ex/inc 1)");
    try expectOutputProgram("(ns ex (:refer-clojure)) (inc 1)", "2");
    // Without :exclude, a Var the namespace defines hides a host macro too.
    try expectOutputProgram("(defn when [x] [:mine x]) (when 1)", "[:mine 1]");
    try expectMacroFailure("", "(ns ex (:refer-clojure :only [inc]))", "ns: (:refer-clojure :only ...) is not supported; :exclude is", ":only");
    try expectMacroFailure("", "(ns ex (:refer-clojure :exclude inc))", "ns: :exclude takes a vector of symbols, not a symbol", "inc");
}

test "ns and require: :require clauses, :as, :refer, :refer :all, :rename, flags" {
    try expectOutputWithFiles(&.{utilns},
        \\(ns my.app "An app." {:author "me"}
        \\  (:refer-clojure :exclude [replace])
        \\  (:require [util :as u :refer [twice]]
        \\            [nexis.string :refer [upper-case join] :rename {join j}])
        \\  (:gen-class))
        \\(def here 1)
        \\[(u/half 8) (twice 2) (upper-case "a") (j "-" [1 2]) my.app/here]
    , "[4 4 A 1-2 1]");
    try expectOutputWithFiles(&.{utilns}, "(require '[util :refer :all] :reload) [(twice 1) (half 4)]", "[2 2]");
    // :refer :all skips private Vars.
    try expectOutputWithFiles(&.{utilns}, "(require '[util :refer :all]) (try (eval 'secret) (catch any e :unresolved))", ":unresolved");
    try expectOutputWithFiles(&.{utilns}, "(require '[util :as-alias ua]) (require 'util) (ua/twice 3)", "6");
}

test "require: Clojure's library namespaces name nexis's" {
    try expectOutputWithFiles(&.{},
        \\(ns t (:require [clojure.string :as str :refer [trim]] clojure.test))
        \\[(str/upper-case "a") (trim " x ") (clojure.string/lower-case "B") (fn? clojure.test/is)]
    , "[A x b true]");
}

/// Run `setup`, then expand `src` with the loader over `files` and
/// expect a failure recorded with `message` against the source text
/// `at`.
fn expectRequireFailure(files: []const [2][]const u8, setup: []const u8, src: []const u8, message: []const u8, at: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run(setup);
    var dir: RequireDir = undefined;
    try dir.init(&program, files);
    defer dir.deinit();
    var arena = std.heap.ArenaAllocator.init(program.allocator());
    defer arena.deinit();
    const a = arena.allocator();
    var parsed = try reader_mod.parser.parseProgram(a, src);
    defer parsed.parser.deinit();
    var rdr = reader_mod.Reader.init(a, src);
    defer rdr.deinit();
    const forms = try rdr.readProgram(parsed.sexp);
    var failure: ?expand_mod.Failure = null;
    for (forms) |form| {
        var ctx = expand_mod.ExpandContext{
            .allocator = a,
            .interner = program.interner,
            .host_macros = &program.host_macros,
            .namespace = program.registry.current,
            .registry = program.registry,
            .load_callback = dir.callback(),
            .value_heap = program.v.ensureHeap(),
        };
        _ = expand_mod.expandForm(&ctx, null, form) catch {
            failure = ctx.failure;
            break;
        };
    }
    const f = failure orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(message, f.message);
    try testing.expectEqualStrings(at, src[f.span.pos..][0..f.span.len]);
}

test "a source text past 4 GiB is a reader error that names the bound, never a fault" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var dir: RequireDir = undefined;
    try dir.init(&program, &.{});
    defer dir.deinit();
    // Byte positions are u32, so the loader refuses the text before
    // the parser reads a byte of it; the slice is never dereferenced.
    const byte: u8 = '(';
    const huge = @as([*]const u8, @ptrCast(&byte))[0 .. @as(usize, std.math.maxInt(u32)) + 2];
    const info = vm.SourceInfo{ .path = "huge.nx", .text = huge };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Diagnosed, dir.loader.evalSource(&info, .{ .allocator = arena.allocator() }));
    const d = dir.loader.diagnostic.?;
    try testing.expect(d.reading);
    try testing.expectEqualStrings("reader error: a source text is at most 4294967295 bytes; this one is 4294967297", d.label);
}

test "ns and require: a bad spec or a missing namespace or Var is reported by name" {
    try expectRequireFailure(&.{}, "", "(require '[nope.ns :as n])", "require: nope.ns did not load", "nope.ns");
    try expectRequireFailure(&.{utilns}, "", "(require '[util :refer [nope]])", "require: util/nope does not exist", "nope");
    try expectRequireFailure(&.{utilns}, "", "(require '[util :only [twice]])", "require: unknown option only", ":only");
    try expectRequireFailure(&.{}, "", "(ns x (:import java.util.Date))", "ns: (:import ...) is not supported", "(:import java.util.Date)");
    try expectRequireFailure(&.{utilns}, "(defn twice [] 0)", "(require '[util :refer [twice]])", "require: twice is already defined in user", "twice");
    try expectRequireFailure(&.{utilns}, "", "(require '[util :refer [twice]]) (def twice 0)", "def: twice already refers to a Var of another namespace", "twice");
}

const throwsns = [2][]const u8{ "throwsns.nx", "(ns throwsns)\n(throw :boom)\n" };
const badns = [2][]const u8{ "badns.nx", "(ns badns)\n(defn f [] (/ 1 0))\n(f)\n" };

test "require: a required file's throw that the caller's handler takes reaches that handler through eval" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var files: RequireDir = undefined;
    try files.init(&program, &.{throwsns});
    defer files.deinit();
    const caught = try program.run("(try (eval '(require 'throwsns)) (catch any e [:caught e]))");
    var buf: std.array_list.Managed(u8) = .init(testing.allocator);
    defer buf.deinit();
    try formatValue(&buf, caught, program.interner);
    try testing.expectEqualStrings("[:caught :boom]", buf.items);
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.handlers.items.len);
    // The file's throw left nothing behind; the program goes on.
    try testing.expectEqual(@as(i64, 3), (try program.run("(+ 1 2)")).asFixnum());
}

test "require: a required file's runtime error reached through eval leaves with the whole chain located" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var files: RequireDir = undefined;
    try files.init(&program, &.{badns});
    defer files.deinit();
    try testing.expectError(vm.VmError.DivideByZero, program.run("(defn g [] (eval '(require 'badns)))\n(g)"));
    const trace = program.v.error_trace.items;
    try testing.expect(trace.len >= 3);
    try testing.expectEqualStrings("f", trace[0].name);
    try testing.expectEqualStrings("<top>", trace[1].name);
    try testing.expectEqualStrings("g", trace[2].name);
    const src = trace[0].source orelse return error.TestFailed;
    try testing.expect(std.mem.endsWith(u8, src.path, "badns.nx"));
    try testing.expect(trace[1].source == src);
    const loc = src.lineCol(trace[0].span.?.pos);
    try testing.expectEqual(@as(u32, 2), loc.line);
    try testing.expectEqual(@as(u32, 12), loc.col);
    try testing.expectEqualStrings("(/ 1 0)", src.text[trace[0].span.?.pos .. trace[0].span.?.pos + trace[0].span.?.len]);
    program.v.resetAfterError();
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
}

test "require: a file that cannot be loaded is diagnosed where it failed, in the file that failed" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var files: RequireDir = undefined;
    try files.init(&program, &.{
        .{ "broken.nx", "(ns broken)\n(defn f [x]\n" },
        .{ "notns.nx", "(def x 1)\n" },
        .{ "unresolved.nx", "(ns unresolved)\n(defn f [] (nope 1))\n" },
        .{ "cyca.nx", "(ns cyca)\n(require 'cycb)\n" },
        .{ "cycb.nx", "(ns cycb)\n(require 'cyca)\n" },
    });
    defer files.deinit();
    const Case = struct { src: []const u8, label: []const u8, file: ?[]const u8 = null, line: u32 = 0 };
    const cases = [_]Case{
        .{ .src = "(require 'broken)", .label = "parse error: unexpected end of input", .file = "broken.nx", .line = 3 },
        .{ .src = "(require 'unresolved)", .label = "compile error: unable to resolve symbol: nope", .file = "unresolved.nx", .line = 2 },
        .{ .src = "(require 'cyca)", .label = "require: cyclic require of cyca", .file = "cycb.nx", .line = 2 },
        .{ .src = "(require 'nope)", .label = "require: no file nope.nx on the load path" },
    };
    for (cases) |c| {
        if (files.compileOne(&program, c.src)) |_| return error.TestUnexpectedResult else |_| {}
        const d = files.loader.diagnostic orelse return error.TestFailed;
        try testing.expectEqualStrings(c.label, d.label);
        if (c.file) |name| {
            const src = d.source orelse return error.TestFailed;
            try testing.expect(std.mem.endsWith(u8, src.path, name));
            try testing.expectEqual(c.line, src.lineCol(d.span.?.pos).line);
        } else try testing.expect(d.source == null);
    }
    if (files.compileOne(&program, "(require 'notns)")) |_| return error.TestUnexpectedResult else |_| {}
    try testing.expect(std.mem.endsWith(u8, files.loader.diagnostic.?.label, "notns.nx does not begin with (ns notns)"));
    // Nothing a failed load did leaks into the requiring namespace.
    try testing.expectEqualStrings("user", program.registry.current.name);
}

test "require: clojure.string, clojure.set, clojure.test and clojure.pprint name the nexis namespaces" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var files: RequireDir = undefined;
    try files.init(&program, &.{});
    defer files.deinit();
    const r = try program.run("(eval '(require '[clojure.string :as s] 'clojure.test)) [(eval '(s/join \",\" (clojure.string/split \"a-b\" \"-\"))) (eval '(fn? clojure.test/run-tests))]");
    try harness.expectResult(&program, "clojure.string", r, "[a,b true]");
}

test "require: a required file that fails while a form is compiled is a runtime failure with its trace, not a compile error" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var files: RequireDir = undefined;
    try files.init(&program, &.{ badns, throwsns });
    defer files.deinit();

    try testing.expectError(compile.CompileError.RequiredFileFailed, files.compileOne(&program, "(require 'badns)"));
    try testing.expectEqual(vm.VmError.DivideByZero, program.v.traced_error.?);
    var trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 2), trace.len);
    try testing.expectEqualStrings("f", trace[0].name);
    try testing.expectEqualStrings("<top>", trace[1].name);
    try testing.expect(trace[0].span != null and trace[0].source != null);
    program.v.resetAfterError();

    try testing.expectError(compile.CompileError.RequiredFileFailed, files.compileOne(&program, "(require 'throwsns)"));
    try testing.expectEqual(vm.VmError.UncaughtThrow, program.v.traced_error.?);
    trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 1), trace.len);
    try testing.expectEqualStrings("<top>", trace[0].name);
    program.v.resetAfterError();

    // The VM is ready for the next form.
    try testing.expectEqual(@as(i64, 3), (try program.run("(+ 1 2)")).asFixnum());
}

test "runtime errors: resetAfterError leaves the VM ready for the next form" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "t.nx", .text = "(defn f [] (/ 1 0))\n(f)" };
    try testing.expectError(vm.VmError.DivideByZero, runLocated(&program, &info));
    try testing.expect(program.v.frames.items.len > 1);
    program.v.resetAfterError();
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    const result = try program.run("(+ 1 2)");
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "runtime errors: resetAfterError drops the dynamic bindings a failed run left in force" {
    // A thrown value and a catchable VmError both unwind through
    // `binding`'s finally, so their frames are popped before the
    // error surfaces. A run that fails between a push and its pop
    // leaves the frame in force; the reset pops it.
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(def ^:dynamic *x* 1)");
    try testing.expectError(vm.VmError.UncaughtThrow, program.run("(binding [*x* 2] (throw :boom))"));
    try testing.expectEqual(@as(usize, 0), program.v.dyn_frames.items.len);
    try testing.expectError(vm.VmError.UncaughtThrow, program.run("(binding [*x* 2] (/ 1 0))"));
    try testing.expectEqual(@as(usize, 0), program.v.dyn_frames.items.len);
    try testing.expectError(vm.VmError.DivideByZero, program.run("(do (push-thread-bindings (hash-map (var *x*) 2)) (/ 1 0))"));
    try testing.expectEqual(@as(usize, 1), program.v.dyn_frames.items.len);
    const bound = try program.run("*x*");
    try testing.expectEqual(@as(i64, 2), bound.asFixnum());
    program.v.resetAfterError();
    try testing.expectEqual(@as(usize, 0), program.v.dyn_frames.items.len);
    try testing.expectEqual(@as(usize, 0), program.v.dyn_saves.items.len);
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    const result = try program.run("*x*");
    try testing.expectEqual(@as(i64, 1), result.asFixnum());
}

test "runtime errors: a routine without a span table is traced by name alone" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(vm.VmError.DivideByZero, program.run("(defn f [] (/ 1 0)) (f)"));
    const trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 2), trace.len);
    try testing.expectEqualStrings("f", trace[0].name);
    try testing.expect(trace[0].span != null);
    try testing.expect(trace[0].source == null);
    try testing.expectEqualStrings("test-form", trace[1].name);
}

// =============================================================================
// nexis.test and nexis.pprint
// =============================================================================

test "nexis.test: run-tests counts tests, assertions, failures and errors and reports each failure" {
    // Report lines go to an atom instead of stdout (the harness has
    // no `io`); the summary map comes back from run-tests.
    try expectOutputProgram(
        \\(def log (atom []))
        \\(reset! nexis.test/out (fn [line] (swap! log conj line)))
        \\(defn area [w h] (* w h))
        \\(nexis.test/deftest area-test
        \\  (nexis.test/testing "rectangles"
        \\    (nexis.test/is (= 6 (area 2 3)))
        \\    (nexis.test/testing "degenerate"
        \\      (nexis.test/is (= 0 (area 0 9))))))
        \\(nexis.test/deftest failing-test
        \\  (nexis.test/testing "wrong"
        \\    (nexis.test/is (= 5 (area 2 2)) "areas multiply")
        \\    (nexis.test/is (empty? [1]))))
        \\(nexis.test/deftest throwing-test
        \\  (nexis.test/is (nexis.test/thrown? :divide-by-zero (/ 1 0)))
        \\  (nexis.test/is (nexis.test/thrown? any (throw "x")))
        \\  (nexis.test/is (nexis.test/thrown? :boom (+ 1 1))))
        \\(nexis.test/deftest erroring-test
        \\  (nexis.test/is (= 1 (/ 1 0))))
        \\(def r (nexis.test/run-tests))
        \\[(:test r) (:pass r) (:fail r) (:error r) @log]
    ,
        \\[4 4 3 1 [FAIL in user/failing-test (wrong): (= 5 (area 2 2)) expected: 5 actual: 4 ; areas multiply FAIL in user/failing-test (wrong): (empty? [1]) expected: true actual: false FAIL in user/throwing-test: (nexis.test/thrown? :boom (+ 1 1)) expected: :boom actual: 2 ERROR in user/erroring-test: :divide-by-zero Ran 4 tests containing 7 assertions. 3 failures, 1 errors.]]
    );
}

test "nexis.test: a deftest of 5000 assertions compiles, runs and counts every pass" {
    // One routine of more than 100,000 instructions and 4096
    // constants; the `testing` blocks' finally targets lie past the
    // 16-bit range.
    const src = try generated(
        \\(reset! nexis.test/out (fn [line] nil))
        \\(nexis.test/deftest big
    ,
        \\ (nexis.test/testing "t" (nexis.test/is (= {d} (inc (dec {d})))))
    , 5000,
        \\)
        \\(def r (nexis.test/run-tests))
        \\[(:test r) (:pass r) (:fail r) (:error r)]
    );
    defer testing.allocator.free(src);
    try expectOutputProgram(src, "[1 5000 0 0]");
}

test "nexis.test: tests register per namespace, replace by name, and run-all-tests spans namespaces" {
    try expectOutputProgram(
        \\(reset! nexis.test/out (fn [line] nil))
        \\(nexis.test/deftest t1 (nexis.test/is (= 1 2)))
        \\(nexis.test/deftest t1 (nexis.test/is (= 1 1)))
        \\(ns other)
        \\(nexis.test/deftest t2 (nexis.test/is true) (nexis.test/is true))
        \\(def here (nexis.test/run-tests))
        \\(def user-only (nexis.test/run-tests 'user))
        \\(def all (nexis.test/run-all-tests))
        \\[(:test here) (:pass here) (:test user-only) (:pass user-only) (:fail user-only) (:test all) (:pass all)]
    , "[1 2 1 1 0 2 3]");
}

test "nexis.test: is returns whether the assertion passed and deftest yields the Var" {
    try expectOutputProgram(
        \\(reset! nexis.test/out (fn [line] nil))
        \\(nexis.test/deftest t (nexis.test/is (= 1 1)))
        \\(reset! nexis.test/counts {"test" 0 "pass" 0 "fail" 0 "error" 0})
        \\[(nexis.test/is (= 1 1)) (nexis.test/is (= 1 2)) (nexis.test/is nil) (fn? @(var t))]
    , "[true false false true]");
}

test "nexis.test: thrown? takes what its catch would take, and a message is evaluated once" {
    try expectOutputProgram(
        \\(def log (atom []))
        \\(reset! nexis.test/out (fn [line] (swap! log conj line)))
        \\(reset! nexis.test/counts {"test" 0 "pass" 0 "fail" 0 "error" 0})
        \\(def n (atom 0))
        \\[(nexis.test/is (nexis.test/thrown? :x (throw {:error :x})))
        \\ (nexis.test/is (nexis.test/thrown? :default (throw 1)))
        \\ (nexis.test/is (nexis.test/thrown? Exception (throw 1)))
        \\ (try (nexis.test/is (nexis.test/thrown? :x (throw :y))) (catch any e [:went-on e]))
        \\ (nexis.test/is (= 1 1) (str "m" (swap! n inc)))
        \\ (nexis.test/is (= 1 2) (str "m" (swap! n inc)))
        \\ @n @log @nexis.test/counts]
    , "[true true true [:went-on :y] true false 2 [FAIL in /: (= 1 2) expected: 1 actual: 2 ; m2] {test 0, pass 4, fail 1, error 0}]");
}

test "nexis.pprint: a short collection prints flat, a long one breaks from its column" {
    try expectOutputProgram(
        \\[(nexis.pprint/pprint-str {:a [1 2] :b "x"})
        \\ (nexis.pprint/pprint-str (vec (range 30)))
        \\ (nexis.pprint/pprint-str {:k (vec (range 30)) :m {:deep [1 2]}})
        \\ (nexis.pprint/pprint-str [(vec (range 20)) (vec (range 20))])]
    ,
        \\[{:a [1 2], :b "x"} [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26
        \\ 27 28 29] {:k [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25
        \\     26 27 28 29],
        \\ :m {:deep [1 2]}} [[0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19]
        \\ [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19]]]
    );
}

// =============================================================================
// A definition binds the current namespace's own Var
// =============================================================================

test "def in a user namespace shadows the referred core Var without rebinding it" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(defn inc [x] (+ x 100))
        \\[(inc 1) (nexis.core/inc 1) (my.app/inc 1)]
    , "[101 2 101]");
    try expectOutputProgram(
        \\(ns my.app)
        \\(def inc 7)
        \\(ns user)
        \\[(inc 1) my.app/inc]
    , "[2 7]");
    try expectOutputProgram(
        \\(ns my.app)
        \\(declare later)
        \\(defn f [] (later 1))
        \\(defn later [x] (* x 3))
        \\[(f) (nexis.core/inc 1)]
    , "[3 2]");
}

test "syntax-quote qualifies a symbol to the namespace whose own Var it names" {
    try expectOutputProgram("`(inc 1)", "(nexis.core/inc 1)");
    try expectOutputProgram(
        \\(ns my.app)
        \\(defn inc [x] (+ x 100))
        \\`(inc 1)
    , "(my.app/inc 1)");
    try expectOutputProgram(
        \\(ns my.app)
        \\(defn inc [x] (+ x 100))
        \\(defmacro m [] `(inc 1))
        \\[(m) (nexis.core/inc 1)]
    , "[101 2]");
    try expectOutputProgram(
        \\(ns my.app)
        \\(defmacro m [] `(helper 2))
        \\(defn helper [x] (* x 5))
        \\(m)
    , "10");
}

test "a user macro named like a core macro is the namespace's own" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(defmacro when-let [b & body] :mine)
        \\[(when-let [x 1] x) (nexis.core/when-let [x 1] x)]
    , "[:mine 1]");
}
