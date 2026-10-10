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
fn formatValue(buf: *std.ArrayList(u8), v: value_mod.Value, interner: *const intern_mod.Interner) anyerror!void {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try format_mod.format(v, .display, &w.writer, interner);
    try buf.appendSlice(testing.allocator, w.written());
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
    , "{:error :no-protocol-impl, :message no impl of area for an integer, :fn test-form}");
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
    // The metadata map is an expression, macros in it expanded.
    try expectOutputProgram("(def ^{:k (when true 2) :d @(delay 3)} y 1) [(:k (meta #'y)) (:d (meta #'y))]", "[2 3]");
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
    // Every Var knows its name and namespace, and a defn its arglists.
    try expectOutputProgram("(defn plain [x] x) (meta (var plain))", "{:arglists ([x]), :name plain, :ns user}");
    try expectOutputProgram("(def x 1) [(:name (meta #'x)) (:ns (meta #'x))]", "[x user]");
    try expectOutputProgram("(ns my.app) (defmacro mm [x] x) (select-keys (meta #'mm) [:name :ns :macro])", "{:name mm, :ns my.app, :macro true}");
    // A name qualified with the current namespace is the name itself.
    try expectOutputProgram("(def user/qq 1) (defn user/ff [] 2) [qq (ff) (:name (meta #'qq))]", "[1 2 qq]");
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

test "doc, find-doc, apropos and dir read the documentation of Vars, natives, special forms and namespaces" {
    // STDLIB.md §10: Clojure's layout, a defn's docstring as written.
    try expectOutputProgram("(defn f \"Doubles x.\n  Twice.\" [x] (* 2 x)) (with-out-str (doc f))", "-------------------------\nuser/f\n([x])\n  Doubles x.\n  Twice.\n");
    try expectOutputProgram("(defmacro m \"A macro.\" [x] x) (with-out-str (doc m))", "-------------------------\nuser/m\n([x])\nMacro\n  A macro.\n");
    // A native's Var takes its row's docs as metadata when asked, as a
    // defn's; another Var holding the native does not.
    try expectOutput("(select-keys (meta #'first) [:arglists :name :ns])", "{:arglists ([coll]), :name first, :ns nexis.core}");
    try expectOutput("(string? (:doc (meta #'first)))", "true");
    try expectOutputProgram("(def my-first first) (meta #'my-first)", "{:name my-first, :ns user}");
    try expectOutput("(subs (with-out-str (doc first)) 0 53)", "-------------------------\nnexis.core/first\n([coll])\n ");
    try expectOutput("(do (reset-meta! #'first {:doc \"mine\"}) (meta #'first))", "{:doc mine}");
    // Special forms and host macros have no Var: doc reads their table.
    try expectOutput("(with-out-str (doc if))", "-------------------------\nif\n  (if test then else?)\nSpecial Form\n  Evaluates test. If it is neither nil nor false, evaluates and yields\n  then, otherwise else, nil when there is none.\n");
    try expectOutput("(subs (with-out-str (doc catch)) 0 32)", "-------------------------\ntry\n  ");
    try expectOutput("(subs (with-out-str (doc ->)) 0 54)", "-------------------------\nnexis.core/->\n([x & forms])\n");
    try expectOutput("(re-find #\"Macro\" (with-out-str (doc nexis.core/defn)))", "Macro");
    try expectOutput("(subs (with-out-str (doc nexis.string)) 0 40)", "-------------------------\nnexis.string\n ");
    // What names nothing prints nothing, as in Clojure.
    try expectOutput("[(doc no-such-thing) (with-out-str (doc no-such-thing))]", "[nil ]");
    // apropos: sorted qualified symbols, host macros included.
    try expectOutput("(apropos \"cond-\")", "(nexis.core/cond-> nexis.core/cond->>)");
    try expectOutput("(apropos #\"^->\")", "(nexis.core/-> nexis.core/->> nexis.time/->Instant)");
    try expectOutput("(some #{'nexis.string/split-lines} (apropos \"split\"))", "nexis.string/split-lines");
    // dir: a namespace or an alias; nexis.core with its host macros.
    try expectOutput("(dir-fn 'nexis.set)", "(difference intersection map-invert rename-keys select subset? superset? union)");
    try expectOutputWithFiles(&.{}, "(require '[nexis.walk :as w]) (with-out-str (dir w))", "keywordize-keys\nmacroexpand-all\npostwalk\npostwalk-replace\nprewalk\nprewalk-replace\nstringify-keys\nwalk\n");
    try expectOutput("(boolean (some #{'defn} (dir-fn 'nexis.core)))", "true");
    try expectOutput("(try (dir-fn 'no.such) (catch :no-such-namespace e :none))", ":none");
    // find-doc: every doc whose text or name matches.
    try expectOutputProgram("(defn zq \"Zorbles quietly.\" []) (with-out-str (find-doc \"Zorbles\"))", "-------------------------\nuser/zq\n([])\n  Zorbles quietly.\n");
}

test "every public Var of the library namespaces has a docstring, and every function its arglists" {
    // STDLIB.md §10: a native through its row, the rest through
    // core.nx and the other embedded sources. Lists what lacks one.
    try expectOutput(
        \\(->> (all-ns)
        \\     (remove #{'user 'nexis.internal})
        \\     (mapcat (fn [ns] (map (fn [[s v]] [(symbol (str ns) (str s)) v]) (ns-publics ns))))
        \\     (remove (fn [[_ v]]
        \\               (let [m (meta v)]
        \\                 (and (string? (:doc m))
        \\                      (or (:arglists m) (not (and (bound? v) (fn? @v))))))))
        \\     (map first)
        \\     sort
        \\     vec)
    , "[]");
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
    try expectOutput("(try (with-meta 1 {}) (catch any e e))", "{:error :no-metadata-on-immediate, :message no metadata on immediate, :fn test-form}");
    try expectOutput("(try (with-meta \"s\" {}) (catch any e e))", "{:error :no-metadata-on-immediate, :message no metadata on immediate, :fn test-form}");
    try expectOutput("(try (with-meta (var meta) {}) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (with-meta [1] 5) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
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
    // vec and set build a fresh collection, which carries none, as Clojure's.
    try expectOutput(m ++ "(let [v (with-meta [1] m)] [(meta (vec v)) (meta (set (with-meta #{1} m))) (= v (vec v)) (meta v) (let [w [1 2]] (identical? w (vec w)))])", "[nil nil true {:m 1} true]");
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
    try expectOutput("[(try (with-meta (atom 1) {}) (catch any e e)) (try (with-meta inc {}) (catch any e e)) (try (with-meta (transient []) {}) (catch any e e)) (meta (atom 1))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form} nil]");
    // A typed vector carries it, as Clojure's vector-of does.
    try expectOutput("(let [v (i64-vector [1 2]) m (with-meta v {:k 1})] [(meta m) (meta v) (= m v) (= (hash m) (hash v)) m (meta (with-meta m nil)) (meta (vary-meta (f64-vector [0.5]) assoc :f 2))])", "[{:k 1} nil true true #i64[1 2] nil {:f 2}]");
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
    // A macro argument reaches the macro with its metadata, as in
    // Clojure, and the collection the macro returns keeps it.
    try expectOutputProgram("(defmacro m [x] x) [(m ^:foo [1]) (meta (m ^:foo [1]))]", "[[1] {:foo true}]");
    // A type hint names no class here: `:tag` and `:param-tags` stay symbols.
    try expectOutputProgram("(defn ^[long String] f [x] x) [(f 1) (:param-tags (meta #'f)) (:tag (meta #'f))]", "[1 [long String] nil]");
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

test "quote: reader sugar is the data it stands for, metadata included, as a macro receives it" {
    try expectOutput("'@x", "(nexis.core/deref x)");
    try expectOutput("'#(+ % 1)", "(fn* [%1] (+ %1 1))");
    try expectOutput("(meta '^:m [1])", "{:m true}");
    try expectOutput("(meta (second '(a ^:x [1])))", "{:x true}");
    try expectOutput("(meta (quote ^{:k (+ 1 2)} {:a 1}))", "{:k (+ 1 2)}");
    // A symbol carries no metadata in nexis.
    try expectOutput("'^:k sym", "sym");
    try expectOutput("(meta (read-string \"^:k [1]\"))", "{:k true}");
    try expectOutputProgram("(defmacro mm [x] (meta x)) (mm ^:foo [1])", "{:foo true}");
    try expectOutputProgram("(defmacro q [x] (list 'quote x)) [(= (q @y) '@y) (= (q #(inc %)) '#(inc %)) (meta (q ^:m [1]))]", "[true true {:m true}]");
    // A macro may pass a binding vector with metadata on to let or for.
    try expectOutputProgram("(defmacro my-let [bs & body] `(let ~bs ~@body)) (my-let ^:x [a 1] (inc a))", "2");
    try expectOutput("(let ^:x [a 1] (for ^:y [b [a]] b))", "(1)");
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
    // As Clojure's: the prefix then the counter; G__ by default.
    try expectOutputProgram(
        \\(let [p (apply str (repeat 1000 "p"))
        \\      g (name (gensym p))
        \\      d (name (gensym))]
        \\  [(= (subs g 0 1000) p) (pos? (parse-long (subs g 1000))) (subs d 0 3) (pos? (parse-long (subs d 3)))])
    , "[true true G__ true]");
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
    ), "[[:t 1] {:error :divide-by-zero, :message divide by zero, :fn fn} :in [2 3] 0 [5 7 7]]");
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

test "try: a class that names a nexis error catches that error alone, as in Clojure" {
    try expectOutput("(try (throw (ex-info \"x\" {})) (catch IllegalArgumentException e :iae) (catch Exception e :ex))", ":ex");
    try expectOutput("(try (inc nil) (catch ArithmeticException e :ae) (catch ClassCastException e :cce))", ":cce");
    try expectOutput("(try (nth [1] 5) (catch java.lang.IndexOutOfBoundsException e :oob))", ":oob");
    try expectOutput("(try ((fn [x] x)) (catch IllegalArgumentException e :iae))", ":iae");
    try expectOutput("(try (case 3 1 :one) (catch IllegalArgumentException e :iae))", ":iae");
    try expectOutput("(try (throw :other) (catch ArithmeticException e :ae) (catch Throwable e [:t e]))", "[:t :other]");
    try expectOutput("(try (try (/ 1 0) (catch ClassCastException e :cce)) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    // Calling a value that is no function is a ClassCastException in
    // Clojure; an overflow an ArithmeticException.
    try expectOutput("[(try (1 2) (catch ClassCastException e :cce)) (try (bit-and 1 10000000000000000000) (catch ArithmeticException e :ae))]", "[:cce :ae]");
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
    try expectOutput("(try (nth [1 2] 5) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
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
    try expectOutput("(try (first) (catch any e e))", "{:error :arity-mismatch, :message first takes 1 argument, got 0, :fn test-form}");
    try expectOutput("(try (cons 1) (catch any e e))", "{:error :arity-mismatch, :message cons takes 2 arguments, got 1, :fn test-form}");
}

test "integration: recursion through a native re-entry ends in a catchable :stack-overflow" {
    // Every level nests `apply` / `mapv` / a protocol impl and a run
    // loop on the native stack; the guard stops it before the stack
    // does (VM.md §13.1).
    try expectOutput("(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) (g 300)", "300");
    try expectOutput("(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) (try (g 100000000) (catch any e e))", "{:error :stack-overflow, :message stack overflow, :fn g}");
    try expectOutput("(defn h [n] (if (= n 0) 0 (+ 1 (first (mapv h [(- n 1)]))))) (try (h 100000000) (catch any e e))", "{:error :stack-overflow, :message stack overflow, :fn h}");
    // The VM is whole afterwards: the next call runs normally.
    try expectOutput("(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) (try (g 100000000) (catch any e e)) (g 10)", "10");
}

test "integration: a closure made just past the stack guard's last check is still a catchable :stack-overflow" {
    // Each level makes two closures a few native frames below the
    // re-entry that checked the guard; starting from a dozen depths
    // puts the guard's limit inside that margin at least once.
    try expectOutput(
        \\(defn f4 [n] (if (zero? n) 0 (+ 1 (first (mapv (fn [x] (let [g (fn [] x)] (f4 (g)))) [(dec n)])))))
        \\(defn pad [k] (if (zero? k) (try (f4 100000000) (catch :stack-overflow e e)) (apply pad [(dec k)])))
        \\(set (mapv pad (range 12)))
    , "#{{:error :stack-overflow, :message stack overflow, :fn f4}}");
}

test "integration: run loops nest at most max_nested_runs deep" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.max_nested_runs = 50;
    const g = "(defn g [n] (if (= n 0) 0 (+ 1 (apply g [(- n 1)])))) ";
    try harness.expectResult(&program, "", try program.run(g ++ "(g 40)"), "40");
    try harness.expectResult(&program, "", try program.run("[(try (g 60) (catch any e e)) (try (first (mapv g [60])) (catch any e e)) (g 40)]"), "[{:error :stack-overflow, :message stack overflow, :fn g} {:error :stack-overflow, :message stack overflow, :fn g} 40]");
    try testing.expectEqual(@as(usize, 0), program.v.nested_runs);
}

test "integration: runaway recursion is a catchable :stack-overflow; deep legitimate recursion runs" {
    try expectOutput("(defn d [n] (if (= n 0) 0 (inc (d (dec n))))) (d 100000)", "100000");
    // A call through the Var takes a frame, as a call of the closure does.
    try expectOutput("(defn d [n] (if (= n 0) 0 (inc (#'d (dec n))))) (d 100000)", "100000");
    try expectOutput("(declare d) (def h #'d) (defn d [n] (if (= n 0) 0 (inc (h (dec n))))) (d 100000)", "100000");
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.max_frames = 20_000;
    try harness.expectResult(&program, "", try program.run("(defn f [n] (inc (f n))) (try (f 1) (catch any e [:caught e]))"), "[:caught {:error :stack-overflow, :message stack overflow, :fn f}]");
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    try testing.expectError(vm.VmError.StackOverflow, program.run("(f 1)"));
    // The trace keeps the innermost 32 frames and the outermost 8
    // around one marker for the rest.
    const trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 41), trace.len);
    try testing.expectEqualStrings("f", trace[0].name);
    try testing.expectEqual(@as(usize, 19960), trace[32].elided);
    try testing.expectEqualStrings("test-form", trace[40].name);
    // A chain of exactly 41 frames is shown whole.
    try testing.expectError(vm.VmError.DivideByZero, program.run("(defn g [n] (if (= n 0) (/ 1 0) (+ 1 (g (dec n))))) (g 39)"));
    try testing.expectEqual(@as(usize, 41), program.v.error_trace.items.len);
    for (program.v.error_trace.items) |frame| try testing.expectEqual(@as(usize, 0), frame.elided);
}

test "integration: an elided trace survives the throws caught while it is held" {
    // Each throw caught inside the finally records an origin of its
    // own beside the one the finally holds.
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(vm.VmError.UncaughtThrow, program.run(
        \\(defn g [n] (if (= n 0) (/ 1 0) (+ 1 (g (dec n)))))
        \\(try (g 60) (finally (try (throw :a) (catch any e (try (throw :b) (catch any e2 (try (throw :c) (catch any e3 nil))))))))
    ));
    try testing.expectEqual(vm.VmError.DivideByZero, program.v.traced_error.?);
    const trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 41), trace.len);
    try testing.expectEqualStrings("g", trace[0].name);
    try testing.expectEqual(@as(usize, 22), trace[32].elided);
    try testing.expectEqualStrings("test-form", trace[40].name);
}

test "integration: an uncaught runtime error names what went wrong in VM.error_detail" {
    const Case = struct { src: []const u8, err: anyerror, detail: []const u8 };
    const cases = [_]Case{
        .{ .src = "(defn f [x] x) (f)", .err = vm.VmError.ArityMismatch, .detail = "f takes 1 argument, got 0" },
        .{ .src = "(defn g [a b & r] a) (g 1)", .err = vm.VmError.ArityMismatch, .detail = "g takes at least 2 arguments, got 1" },
        .{ .src = "(first 1 2)", .err = vm.VmError.ArityMismatch, .detail = "first takes 1 argument, got 2" },
        .{ .src = "(mapv (fn [a b] a) [1])", .err = vm.VmError.ArityMismatch, .detail = "fn takes 2 arguments, got 1" },
        .{ .src = "(doall (map (fn f [a b] a) [1]))", .err = vm.VmError.ArityMismatch, .detail = "f takes 2 arguments, got 1" },
        .{ .src = "(doall (filter (fn [] true) [1]))", .err = vm.VmError.ArityMismatch, .detail = "fn takes 0 arguments, got 1" },
        .{ .src = "(reduce inc [1 2])", .err = vm.VmError.ArityMismatch, .detail = "inc takes 1 argument, got 2" },
        .{ .src = "(reduce (fn h [a] a) 0 [1])", .err = vm.VmError.ArityMismatch, .detail = "h takes 1 argument, got 2" },
        // A multi-arity fn names every count its clauses take.
        .{ .src = "(defn f ([x] x) ([x y] y)) (f 1 2 3)", .err = vm.VmError.ArityMismatch, .detail = "f takes 1 or 2 arguments, got 3" },
        .{ .src = "(defn f ([] 0) ([x] x) ([x y] y)) (f 1 2 3)", .err = vm.VmError.ArityMismatch, .detail = "f takes 0 to 2 arguments, got 3" },
        .{ .src = "(defn f ([x] x) ([x y z & r] r)) (f)", .err = vm.VmError.ArityMismatch, .detail = "f takes 1 or at least 3 arguments, got 0" },
        .{ .src = "(defn f ([x] x) ([x y & r] r)) (f)", .err = vm.VmError.ArityMismatch, .detail = "f takes at least 1 argument, got 0" },
        .{ .src = "(doall (map (fn ([] 0) ([a b] a)) [1]))", .err = vm.VmError.ArityMismatch, .detail = "fn takes 0 or 2 arguments, got 1" },
        .{ .src = "(doall (filter 5 [1]))", .err = vm.VmError.NotCallable, .detail = "an integer is not callable" },
        .{ .src = "(reduce + [1 \"a\"])", .err = vm.VmError.KindMismatch, .detail = "" },
        .{ .src = "(5 1)", .err = vm.VmError.NotCallable, .detail = "an integer is not callable" },
        .{ .src = "(doall (map \"s\" [1]))", .err = vm.VmError.NotCallable, .detail = "a string is not callable" },
        .{ .src = "(+ 1 \"a\")", .err = vm.VmError.KindMismatch, .detail = "+ expects numbers, got a string" },
        .{ .src = "(< nil 1)", .err = vm.VmError.KindMismatch, .detail = "< expects numbers, got nil" },
        .{ .src = "(defprotocol P (m [x])) (m 1)", .err = vm.VmError.NoProtocolImpl, .detail = "no impl of m for an integer" },
        .{ .src = "({} 1 2 3)", .err = vm.VmError.ArityMismatch, .detail = "a map takes 1 to 2 arguments, got 3" },
        .{ .src = "(:a)", .err = vm.VmError.ArityMismatch, .detail = "a keyword takes 1 to 2 arguments, got 0" },
        .{ .src = "(#{1} 1 2)", .err = vm.VmError.ArityMismatch, .detail = "a set takes 1 argument, got 2" },
        .{ .src = "([1 2] 5)", .err = vm.VmError.IndexOutOfBounds, .detail = "index 5 is out of bounds for a vector of 2" },
        .{ .src = "([1 2] :a)", .err = vm.VmError.KindMismatch, .detail = "a vector takes an integer index, got a keyword" },
        .{ .src = "(+ 1 (i64-vector [1]))", .err = vm.VmError.KindMismatch, .detail = "+ expects numbers, got a typed vector" },
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
        .{ .src = f ++ "(defn h [] (try (f) (finally 1))) (h)", .err = vm.VmError.ArityMismatch, .detail = "into takes 0 to 3 arguments, got 4", .at = "f" },
        .{ .src = f ++ "(defn h [] (try (f) (catch :nope e 1))) (h)", .err = vm.VmError.ArityMismatch, .detail = "into takes 0 to 3 arguments, got 4", .at = "f" },
        .{ .src = f ++ "(defn h [] (try (f) (catch any e (throw e)))) (h)", .err = vm.VmError.ArityMismatch, .detail = "into takes 0 to 3 arguments, got 4", .at = "f" },
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
    , "{:error :arity-mismatch, :message f takes 1 or 2 arguments, got 3, :fn test-form}");
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
    try expectOutput("(try ((fn ([x] x)) 1 2) (catch any e e))", "{:error :arity-mismatch, :message fn takes 1 argument, got 2, :fn test-form}");
    try expectProgramError("(fn ([x] 1) ([x] 2))", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(fn ([x y] 1) ([x & r] 2))", compile.CompileError.MacroExpansionFailure);
}

test "multi-arity fn: each clause is called at its count through every path" {
    // call:call, apply, swap!, a Callback (map, filter, reduce), a
    // protocol method of a record, letfn and a macro.
    try expectOutput(
        \\(let [f (fn ([] :0) ([a] :1) ([a b] :2) ([a b c d & m] [:v m]))]
        \\  [(f) (f 1) (f 1 2) (f 1 2 3 4) (f 1 2 3 4 5 6 7)
        \\   (apply f []) (apply f 1 [2]) (apply f 1 [2 3 4 5]) (apply #'nexis.core/vector [1 2])
        \\   (try (f 1 2 3) (catch any e e)) (try (apply f [1 2 3]) (catch any e e))
        \\   (mapv f [1 2]) (mapv f [1] [2]) (filterv f [1]) (reduce f [1 2 3])
        \\   (let [a (atom 0)] (swap! a f 1 2 3 4) @a)])
    , "[:0 :1 :2 [:v nil] [:v (5 6 7)] :0 :2 [:v (5)] [1 2] {:error :arity-mismatch, :message fn takes 0 to 2 or at least 4 arguments, got 3, :fn test-form} {:error :arity-mismatch, :message fn takes 0 to 2 or at least 4 arguments, got 3, :fn test-form} [:1 :1] [:2] [1] :2 [:v (4)]]");
    try expectOutput(
        \\(do (defprotocol Sz (sz [x] [x n]))
        \\    (defrecord Box [v] Sz (sz [_] v) (sz [_ n] (* v n)))
        \\    (let [b (->Box 3)] [(sz b) (sz b 2) (mapv sz [b b])]))
    , "[3 6 [3 3]]");
    try expectOutput("(letfn [(f ([] (f 1)) ([n] (* n 10)) ([n & r] (count r)))] [(f) (f 2) (f 1 2 3)])", "[10 20 2]");
    try expectOutput("(do (defmacro m ([a] a) ([a b] `(+ ~a ~b))) [(m 1) (m 1 2)])", "[1 3]");
    // apply into the rest clause with 10,000 arguments, a lazy seq,
    // and through a Var.
    try expectOutput("(do (defn f ([] 0) ([x & r] (+ x (count r)))) [(apply f (range 10000)) (apply f (map inc (range 3))) (apply #'f 5 [6])])", "[9999 3 6]");
    // A transducer's step fn, called once per element.
    try expectOutput("[(transduce (map inc) + (range 100000)) (into [] (comp (filter odd?) (map inc)) (range 6))]", "[5000050000 [2 4 6]]");
}

test "multi-arity fn: an error in a clause names the fn, and a call between clauses is a frame" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const src =
        \\(defn f
        \\  ([x] (f x 0))
        \\  ([x y] (quot x y)))
        \\(f 1)
    ;
    try testing.expectError(vm.VmError.DivideByZero, program.run(src));
    const trace = program.v.error_trace.items;
    try testing.expectEqual(@as(usize, 3), trace.len);
    try testing.expectEqualStrings("f", trace[0].name);
    try testing.expectEqualStrings("(quot x y)", src[trace[0].span.?.pos..][0..trace[0].span.?.len]);
    try testing.expectEqualStrings("f", trace[1].name);
    try testing.expectEqualStrings("(f x 0)", src[trace[1].span.?.pos..][0..trace[1].span.?.len]);
}

test "multi-arity fn: recur re-enters the clause with the clause's own arity" {
    // Each clause is a routine of its own, so `recur` in a clause's
    // tail rebinds that clause's params (COMPILER.md §5.5, §5.6).
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

test "fn: a parameter name repeated binds its last occurrence, as in Clojure" {
    try expectOutput("[((fn [x x] x) 1 2) ((fn [a & a] a) 1 2) ((fn [_ _ o n] [o n]) 1 2 3 4)]", "[2 (2) [3 4]]");
    // A closure over the name, and recur, see the last binding too.
    try expectOutput("[(((fn [x x] (fn [] x)) 1 2)) ((fn [x x] (if (< x 5) (recur x (inc x)) x)) 0 0)]", "[2 5]");
    try expectOutput("(let [a (atom 0)] (add-watch a :k (fn [_ _ old new] (when (< new 10) (reset! a (+ old new 10))))) (reset! a 1) (remove-watch a :k) @a)", "11");
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
    // With nothing before it, the rest is still a seq of the source.
    try expectOutput("(let [[& r] [1 2]] [r (seq? r)])", "[(1 2) true]");
    try expectOutput("(nil? (let [[& r] []] r))", "true");
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
    // As Clojure 1.11's: one trailing argument is the map itself,
    // whatever it is, and no arguments leave nil to destructure.
    try expectOutput("[((fn [& {:keys [a]}] a) :a) ((fn [& {:as m}] m)) (try ((fn [& {:keys [a]}] a) :a 1 :b) (catch any e e))]", "[nil nil {:error :invalid-argument, :message invalid argument, :fn fn}]");
    // #%kwargs itself: a non-seq is itself, a seq of one its element,
    // the empty seq {}, a longer seq the map of its pairs.
    try expectOutput("[(nexis.internal/#%kwargs '(:a)) (nexis.internal/#%kwargs [1 2]) (nexis.internal/#%kwargs nil) (nexis.internal/#%kwargs ()) (nexis.internal/#%kwargs {:a 1}) (nexis.internal/#%kwargs '(:a 1 :b 2))]", "[:a [1 2] nil {} {:a 1} {:a 1, :b 2}]");
}

test "destructuring: every map pattern takes a seq as keyword arguments, as Clojure 1.11 does" {
    try expectOutput("(let [{:keys [a b]} (list :a 1 :b 2)] [a b])", "[1 2]");
    try expectOutput("(do (defn f [opts] (let [{:keys [a b]} opts] [a b])) (f (list :a 1 :b 2)))", "[1 2]");
    try expectOutput("(do (defn g [& opts] (let [{:keys [a]} opts] a)) (g :a 1))", "1");
    try expectOutput("(do (defn h [{:keys [a]}] a) (h '(:a 1)))", "1");
    try expectOutput("(let [{:keys [a] :as m} (list {:a 4})] [a m])", "[4 {:a 4}]");
    // Any seq, a lazy one included, as Clojure 1.12's destructure takes it.
    try expectOutput("(let [{:keys [a] :as m} (map identity [:a 1])] [a m])", "[1 {:a 1}]");
    try expectOutput("[(let [{:keys [a b]} (filter some? [:a nil 1 :b 2])] [a b]) (let [{:keys [a b]} (concat [:a 1] [:b 2])] [a b]) (let [{:keys [a]} (map identity [{:a 3}])] a) (let [{:as m} (filter some? [nil])] m)]", "[[1 2] [1 2] 3 {}]");
    try expectOutput("(try (let [{:keys [a]} (map identity [:a 1 :b])] a) (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    // A vector is not a seq: its map pattern looks it up by index.
    try expectOutput("(let [{a 1} [:x :y]] a)", ":y");
}

test "destructuring: :as binds before the keys, so an :or default may read it" {
    try expectOutput("(let [m {:a 5}] (let [{:keys [a] :or {a (:a m 0)} :as m} {}] a))", "0");
    try expectOutput("(let [{:keys [a] :or {a (count m)} :as m} {:b 1}] a)", "1");
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

/// Run `src` through the loader, as `nexis run` runs a file, and
/// compare the last form's printed value with `expected`.
fn expectLoaded(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "<test>", .text = src };
    const result = try program.loader.evalSource(&info, .{ .allocator = program.arena.allocator() });
    try harness.expectResult(&program, src, result, expected);
}

/// Run `src` through the loader and expect it to fail to compile with
/// the report `label`, located at the source text `at`.
fn expectLoadFailure(src: []const u8, label: []const u8, at: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "<test>", .text = src };
    try testing.expectError(error.Diagnosed, program.loader.evalSource(&info, .{ .allocator = program.arena.allocator() }));
    const d = program.loader.diagnostic.?;
    try testing.expectEqualStrings(label, d.label);
    try testing.expectEqualStrings(at, src[d.span.?.pos..][0..d.span.?.len]);
}

test "loader: a defmacro whose function does not compile is reported where and why, at the definition" {
    try expectLoadFailure("(defmacro m [] (undefined-fn 1))", "compile error: defmacro m: unable to resolve symbol: undefined-fn", "undefined-fn");
    try expectLoadFailure("(defmacro m [] (foo/bar 1))", "compile error: defmacro m: unable to resolve symbol: foo/bar", "foo/bar");
    // A name the file defines later is a forward reference, as in any form.
    try expectLoaded("(defmacro m [] (helper)) (defn helper [] 5) (m)", "5");
}

test "loader: a Clojure idiom nexis lacks is reported with what to use instead" {
    // Java interop: constructors, methods, static members.
    try expectLoadFailure("(throw (Exception. \"boom\"))", "compile error: unable to resolve symbol: Exception.; nexis has no Java classes: throw (ex-info \"message\" {:key value}), or any value", "Exception.");
    try expectLoadFailure("(RuntimeException. \"boom\")", "compile error: unable to resolve symbol: RuntimeException.; nexis has no Java classes: throw (ex-info \"message\" {:key value}), or any value", "RuntimeException.");
    try expectLoadFailure("(java.util.Date.)", "compile error: unable to resolve symbol: java.util.Date.; nexis has no Java interop, so no constructors: functions build values", "java.util.Date.");
    try expectLoadFailure("(.toUpperCase \"x\")", "compile error: unable to resolve symbol: .toUpperCase; nexis has no Java interop, so no .method calls: use nexis.string/upper-case", ".toUpperCase");
    try expectLoadFailure("(.frob \"x\")", "compile error: unable to resolve symbol: .frob; nexis has no Java interop, so no .method calls: call a function (nexis.string has the string ones)", ".frob");
    try expectLoadFailure("(Math/sqrt 2)", "compile error: unable to resolve symbol: Math/sqrt; nexis has no Java interop: use nexis.math/sqrt (clojure.math/sqrt)", "Math/sqrt");
    try expectLoadFailure("(Math/floorDiv 7 2)", "compile error: unable to resolve symbol: Math/floorDiv; nexis has no Java interop: use nexis.math/floor-div (clojure.math/floor-div)", "Math/floorDiv");
    try expectLoadFailure("(Math/abs -1)", "compile error: unable to resolve symbol: Math/abs; nexis has no Java interop: use abs", "Math/abs");
    try expectLoadFailure("(System/getenv \"HOME\")", "compile error: unable to resolve symbol: System/getenv; nexis has no Java interop: use nexis.sys/getenv", "System/getenv");
    try expectLoadFailure("(Thread/sleep 10)", "compile error: unable to resolve symbol: Thread/sleep; nexis has no Java interop: Thread is a Java class", "Thread/sleep");
    // One thread: no future, pmap, agent or thread.
    try expectLoadFailure("(future (+ 1 2))", "compile error: unable to resolve symbol: future; nexis runs one thread, so no future: call the function and use its value", "future");
    try expectLoadFailure("(pmap inc [1 2])", "compile error: unable to resolve symbol: pmap; nexis runs one thread, so no pmap: use map", "pmap");
    try expectLoadFailure("(agent 0)", "compile error: unable to resolve symbol: agent; nexis has no agents: an atom holds state that changes", "agent");
    try expectLoadFailure("(thread (println 1))", "compile error: unable to resolve symbol: thread; nexis runs one thread, so no thread: call the function", "thread");
    // A name the program defines is its own, a Clojure name or not.
    try expectLoaded("(defn thread [f] (f)) (thread (fn [] 7))", "7");
    // Libraries: clojure.java.io.
    try expectLoadFailure("(clojure.java.io/file \"x\")", "compile error: unable to resolve symbol: clojure.java.io/file; nexis has no clojure.java.io: slurp and spit read and write a file, read-line reads stdin", "clojure.java.io/file");
    // Literals: a ratio, a BigDecimal, #inst and #uuid.
    try expectLoadFailure("(+ 1/3 1)", "reader error: :bad-number-literal 1/3; nexis has no ratios: (/ 1 3) divides, to a double when inexact", "1/3");
    try expectLoadFailure("1.5M", "reader error: :bad-number-literal 1.5M; nexis has no BigDecimal: 1.5 is a double", "1.5M");
    try expectLoadFailure("#inst \"2026-10-09\"", "parse error: unexpected `#inst`; nexis has no #inst literal: (nexis.time/parse \"2026-10-09T12:00:00Z\") is an instant", "#inst");
    try expectLoadFailure("#uuid \"x\"", "parse error: unexpected `#uuid`; nexis has no #uuid literal: a UUID is its canonical string", "#uuid");
}

test "loader: a parse error names the delimiter left open" {
    try expectLoadFailure("(println [1 2 3)", "parse error: unexpected `)`; the `[` at 1:10 is open", ")");
    try expectLoadFailure("(def x 1)\n(defn f [x]\n  (+ x", "parse error: unclosed `(`", "(");
    try expectLoadFailure("(def x 1) #{1 2", "parse error: unclosed `#{`", "#{");
    try expectLoadFailure("(def x 1))", "parse error: unexpected `)`", ")");
}

test "loader: a top-level do runs its forms one at a time, as Clojure's eval does" {
    try expectLoaded("(do (ns foo) (def x 1)) (ns user) [(resolve 'foo/x) (resolve 'user/x)]", "[#'foo/x nil]");
    try expectLoaded("(do (def k 41) (defmacro m [] (inc k)) (m))", "42");
    // A macro that expands to a `do` is split the same way.
    try expectLoaded("(defmacro two [a b] `(do ~a ~b)) (two (def p 1) (defmacro q [] p)) (q)", "1");
    try expectLoaded("(do (do 1 2) (do))", "nil");
    try expectLoaded("(do 1 (do 2 3))", "3");
}

test "ns: a clause it refuses leaves the current namespace as it was" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(error.MacroExpansionFailure, program.run("(ns elsewhere (:import [java.util Date]))"));
    try testing.expectEqualStrings("user", program.registry.current.name);
    // A clause's options and specs are checked before the switch too.
    for ([_][]const u8{
        "(ns bar (:refer-clojure :only [map]))",
        "(ns bar (:refer-clojure :exclude [map] :rename {}))",
        "(ns baz (:require [x :bogus 1]))",
        "(ns baz (:require [x :refer y]))",
        "(ns baz (:require [x :refer [1]]))",
        "(ns baz (:require [x :as]))",
        "(ns baz (:require \"x\"))",
        "(ns baz (:require (pre [a.b])))",
    }) |src| {
        try testing.expectError(error.MacroExpansionFailure, program.run(src));
        try testing.expectEqualStrings("user", program.registry.current.name);
    }
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

test "integration: core.nx second / last" {
    try expectOutput("(second [10 20 30])", "20");
    // nexis.core has no `third`, as Clojure has none.
    try expectUnresolved("(third [10 20 30])", "third");
    try expectOutput("(last [10 20 30])", "30");
    try expectOutput("(last (list :a :b :c))", ":c");
    try expectOutput("(last (list))", "nil");
    try expectOutput("[(last []) (last nil) (last \"hé\") (last {:a 1}) (last (range 100000)) (last (rest [1])) (last (map inc (range 9))) (last (cons 0 (rest [1 2 3 4 5])))]", "[nil nil é [:a 1] 99999 nil 9 5]");
    try expectOutput("(try (last 5) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "integration: core.nx reverse" {
    try expectOutput("(reverse [1 2 3 4 5])", "(5 4 3 2 1)");
    try expectOutput("(reverse (list))", "()");
    try expectOutput("(reverse nil)", "()");
    try expectOutput("[(reverse \"héb\") (reverse (range 6)) (list? (reverse (range 6))) (reverse {:a 1}) (nexis.string/reverse \"héb🦀\")]", "[(b é h) (5 4 3 2 1 0) true ([:a 1]) 🦀béh]");
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
    // A bignum count takes all or none, as Clojure's take counts down any integer.
    try expectOutput("[(take 100000000000000000000 [1 2]) (take -100000000000000000000 [1])]", "[(1 2) ()]");
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
    try expectProgramError("(when-let [a 1 b 2] [a b])", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(when-some [a] a)", compile.CompileError.MacroExpansionFailure);
    try expectProgramError("(when-first (x [1]) x)", compile.CompileError.MacroExpansionFailure);
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
    // The shape :pre and :post throw: {:error :assertion-failed :message ...}.
    try expectOutput("(try (assert (= 1 \"a\") (str \"n\" 1)) (catch any e [(ex-message e) (:error e) (ex-data e)]))", "[Assert failed: n1\n(= 1 \"a\") :assertion-failed {:error :assertion-failed, :message Assert failed: n1\n(= 1 \"a\")}]");
    try expectOutput("(= (try (assert (pos? -1)) (catch any e (dissoc e :fn :file :line :column))) (try ((fn [x] {:pre [(pos? x)]} x) -1) (catch any e (assoc (dissoc e :fn :file :line :column) :message \"Assert failed: (pos? -1)\"))))", "true");
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
    try expectOutput("(try (some-fn) (catch any e e))", "{:error :arity-mismatch, :message some-fn takes at least 1 argument, got 0, :fn test-form}");
    try expectOutputProgram("(def calls (atom 0)) (def f (memoize (fn [x] (swap! calls inc) (* x x)))) [(f 3) (f 3) (f 4) @calls]", "[9 9 16 2]");
    try expectOutputProgram("(defn down [n] (if (zero? n) :done #(down (dec n)))) (trampoline down 100000)", ":done");
    try expectOutput("(sort (comparator >) [1 3 2])", "(3 2 1)");
    try expectOutput("(let [a (atom 0)] [(run! #(swap! a + %) [1 2 3]) @a])", "[nil 6]");
    // A reduced from f ends the walk, as Clojure's reduce-based run!.
    try expectOutput("(let [a (atom [])] [(run! #(if (= % 3) (reduced :stop) (swap! a conj %)) (range 10)) @a])", "[nil [0 1 2]]");
}

test "integration: core.nx sequence functions: partition-by, dedupe, take-nth, split-with, distinct?, doall, dorun, rseq, nthnext" {
    try expectOutput("[(partition-by odd? [1 3 2 4 5]) (dedupe [1 1 2 1 1 3]) (take-nth 2 (range 7)) (split-with neg? [-1 -2 3 -4])]", "[((1 3) (2 4) (5)) (1 2 1 3) (0 2 4 6) [(-1 -2) (3 -4)]]");
    // Clojure's shapes at the edges: partition-by and dedupe of nothing
    // are (), take-last of nothing nil; nthrest that drops nothing is
    // coll itself, while drop is always a seq.
    try expectOutput("[(partition-by odd? []) (partition-by odd? nil) (dedupe []) (dedupe nil) (take-last 0 [1 2]) (take-last 2 nil) (take-last 2 []) (take-last 5 [1 2])]", "[() () () () nil nil nil (1 2)]");
    try expectOutput("[(nthrest [1 2] 0) (nthrest [1 2] -1) (nthrest nil 1) (nthrest [] 1) (nthrest [1] 2) (nthrest (list 1 2) 1) (drop 0 [1 2]) (drop 0 nil) (drop 5 [1]) (drop -1 [1]) (nthnext [1 2] 0)]", "[[1 2] [1 2] nil () () (2) (1 2) () () (1) (1 2)]");
    // As Clojure's: distinct? takes one argument or more.
    try expectOutput("(try (distinct?) (catch any e e))", "{:error :arity-mismatch, :message distinct? takes at least 1 argument, got 0, :fn test-form}");
    try expectOutput("[(distinct? 1 2 3) (distinct? 1 2 1) (doall (map inc [1])) (dorun [1]) (rseq [1 2 3]) (rseq []) (nthnext [1 2 3] 2) (nthnext [1] 1)]", "[true false (2) nil (3 2 1) nil (3) nil]");
    try expectOutput("[(ffirst [[1 2]]) (fnext [1 2 3]) (nnext [1 2 3]) (second #{9}) (second (list 1 2 3))]", "[1 2 (3) nil 2]");
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
    // A transient is counted, as Clojure's are.
    try expectOutput("[(counted? (transient [])) (counted? (transient {})) (counted? (transient #{})) (counted? nil) (counted? '(1)) (counted? (i64-vector [1]))]", "[true true true false true true]");
    try expectOutput("[(indexed? []) (indexed? (f64-vector [1.0])) (indexed? '()) (indexed? \"a\") (indexed? nil) (indexed? {})]", "[true true false false false false]");
    // A map entry is a two-element vector.
    try expectOutput("[(map-entry? (first {:a 1})) (map-entry? [1 2]) (map-entry? [1]) (map-entry? '(1 2)) (map-entry? nil)]", "[true true false false false]");
}

test "core: nfirst, tree-seq, replace, bounded-count, random-sample" {
    try expectOutput("[(nfirst [[1 2 3] 4]) (nfirst nil) (nfirst [[1]])]", "[(2 3) nil nil]");
    try expectOutput("(tree-seq seq? identity '((1 2 (3)) (4)))", "(((1 2 (3)) (4)) (1 2 (3)) 1 2 (3) 3 (4) 4)");
    try expectOutput("[(tree-seq map? vals {:a {:b 1} :c 2}) (tree-seq vector? seq []) (tree-seq vector? seq 1)]", "[({:a {:b 1}, :c 2} {:b 1} 1 2) ([]) (1)]");
    try expectOutput("(try (doall (tree-seq nil nil 1)) (catch any e e))", "{:error :not-callable, :message nil is not callable, :fn test-form}");
    // Deep trees walk without the native stack.
    try expectOutput("(count (tree-seq vector? seq (reduce (fn [t _] [t]) 0 (range 100000))))", "100001");
    try expectOutput("[(replace {1 :a 2 :b} [1 2 3]) (replace {1 :a} '(1 2 1)) (replace [:a :b] [0 1 0 5]) (replace {} nil) (replace {1 2} #{1 3}) (meta (replace {} ^:m [1]))]", "[[:a :b 3] (:a 2 :a) [:a :b :a 5] () (2 3) {:m true}]");
    try expectOutput("[(bounded-count 2 [1 2 3 4]) (bounded-count 2 \"abcd\") (bounded-count 10 \"ab\") (bounded-count 2 nil) (bounded-count 2 '(1 2 3))]", "[4 2 2 0 3]");
    try expectOutput("[(random-sample 0 [1 2 3]) (random-sample 1 [1 2 3]) (every? #{1 2 3} (random-sample 0.5 [1 2 3]))]", "[() (1 2 3) true]");
}

test "core: array-map, bit-and-not, bit-flip, the ident predicates, bigint, decimal?, inst?" {
    try expectOutput(
        \\[(array-map) (array-map :a 1 :b 2 :a 3) (bit-and-not 15 4) (bit-and-not 15 4 1) (bit-flip 5 1) (bit-flip 0 63)
        \\ (qualified-ident? :a/b) (qualified-ident? 'a) (qualified-ident? "a/b") (simple-ident? :a) (simple-ident? 'a/b) (simple-ident? 1)
        \\ (bigint 1.9) (bigint -2.5) (biginteger 7) (bigint 100000000000000000000) (decimal? 1.0) (inst? 1)]
    , "[{} {:a 3, :b 2} 11 10 7 -9223372036854775808 true false false true false false 1 -2 7 100000000000000000000 false false]");
}

test "core: var-get, find-var, load-string" {
    try expectOutputProgram(
        \\(def x 4)
        \\[(var-get #'x) (find-var 'user/x) (find-var 'nexis.core/inc) (find-var 'user/nope) (try (find-var 'nope/x) (catch any e e))
        \\ (try (var-get 1) (catch any e e)) (load-string "(def zz 2) (+ zz x) ; c") zz (load-string "")]
    , "[4 #'user/x #'nexis.core/inc nil {:error :no-such-namespace, :message no namespace named nope, :fn test-form} {:error :kind-mismatch, :message var-get takes a Var, got an integer, :fn test-form} 6 2 nil]");
}

test "core: load-string reads and evaluates a form at a time, and leaves the namespace as it found it" {
    // As Clojure's Compiler.load binds *ns*: a namespace the text
    // switches to is left when it returns or throws.
    try expectLoaded("(load-string \"(ns foo) (def inner 1)\") (def q 1) [(resolve 'foo/inner) (resolve 'user/q) *ns*]", "[#'foo/inner #'user/q user]");
    try expectLoaded("(try (load-string \"(ns foo2) (throw :x)\") (catch :x e e)) (def q 1) [(resolve 'user/q) *ns*]", "[#'user/q user]");
    // The forms before a stray delimiter or an unfinished form run.
    try expectLoaded("[(try (load-string \"(def zz 1)) (def yy 2\") (catch :reader-error e :reader-error)) (resolve 'user/zz) (resolve 'user/yy)]", "[:reader-error #'user/zz nil]");
    try expectLoaded("[(try (load-string \"(def aa 1) (def bb\") (catch :reader-error e :reader-error)) (resolve 'user/aa)]", "[:reader-error #'user/aa]");
    // A form sees the definitions and macros of the forms before it.
    try expectLoaded("(load-string \"(defmacro twice [x] (list '* 2 x)) #_(skipped) (def t (twice 4)) ; done\") t", "8");
}

test "core: load-string compiles each form as read, so a syntax-quote loads as in a file" {
    try expectLoaded(
        \\(load-string "(defmacro unless* [c & body] `(if ~c nil (do ~@body))) (def u (unless* false 1 2 3))")
        \\[u (unless* true 4) (unless* false (let [x# 5] x#))]
    , "[3 nil 5]");
    // Each form resolves in the namespace the forms before it left.
    try expectLoaded("[(load-string \"(ns sq) `(x ~(inc 1) ~@[3 4])\") *ns*]", "[(sq/x 2 3 4) user]");
    try expectLoaded("(let [[a b] (load-string \"`[a# a#]\")] [(= a b) (simple-symbol? a)])", "[true true]");
    // A form that does not compile throws as eval's does, after the
    // forms before it ran.
    try expectLoaded("[(try (load-string \"(def ok 1) (if)\") (catch any e (:error e))) (resolve 'user/ok)]", "[:compile-error #'user/ok]");
    // Its `:form` is the form as data, nil for one that has none.
    try expectLoaded("(try (load-string \"(if 'x 1 2 3)\") (catch any e (:form e)))", "(if (quote x) 1 2 3)");
    try expectLoaded("(try (load-string \"(if `x 1 2 3)\") (catch any e [(:error e) (:form e)]))", "[:compile-error nil]");
}

test "core: partitionv, partitionv-all, splitv-at" {
    try expectOutput("[(partitionv 2 [1 2 3 4 5]) (partitionv 2 1 [1 2 3]) (partitionv 3 3 [:p] [1 2 3 4]) (partitionv 2 []) (partitionv 2 nil)]", "[([1 2] [3 4]) ([1 2] [2 3]) ([1 2 3] [4 :p]) () ()]");
    try expectOutput("[(partitionv-all 2 [1 2 3]) (partitionv-all 2 1 [1 2 3]) (partitionv-all 2 nil)]", "[([1 2] [3]) ([1 2] [2 3] [3]) ()]");
    try expectOutput("[(splitv-at 2 [1 2 3 4]) (splitv-at 2 '(1)) (vector? (first (splitv-at 1 '(1 2))))]", "[[[1 2] (3 4)] [[1] ()] true]");
}

test "integration: char and int conversion, parse-long, parse-double, parse-boolean" {
    try expectOutput("[(int \\A) (char 97) (int 3.9) (long \\a) (char \\b)]", "[65 a 3 97 b]");
    // int checks Java's 32-bit int range, as Clojure's cast does.
    try expectOutput("[(int 2147483647) (int -2147483648) (int -3.9) (int -2147483647.9)]", "[2147483647 -2147483648 -3 -2147483647]");
    try expectOutput("(map #(try (int %) (catch any e e)) [2147483648 2147483648.5 -2147483649.0 1e300 99999999999999999999 ##Inf])", "({:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn})");
    // A float is truncated, then range-checked: Clojure's boxed cast
    // (longCast, then the narrowing check), the rule nexis follows.
    try expectOutput("[(int 2147483647.5) (byte 127.5) (byte -128.5) (short -32768.5)]", "[2147483647 127 -128 -32768]");
    // NaN casts to 0, as Java's (int) and Clojure's int make it.
    try expectOutput("[(int ##NaN) (short ##NaN) (byte ##NaN)]", "[0 0 0]");
    // short and byte check their Java ranges the same way.
    try expectOutput("[(byte 127) (byte -128) (byte 1.9) (byte \\a) (short 32767) (short -32768) (short -1.5) (short \\a)]", "[127 -128 1 97 32767 -32768 -1 97]");
    try expectOutput("(map #(try (byte %) (catch any e e)) [128 -129 128.5 -129.5 \\é 99999999999999999999 ##-Inf nil \"1\"])", "({:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn})");
    try expectOutput("(map #(try (short %) (catch any e e)) [32768 -32769 32768.5])", "({:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn})");
    try expectOutput("[(parse-long \"42\") (parse-long \"-7\") (parse-long \"4x\") (parse-long \" 1\") (parse-double \"1.5\") (parse-double \"x\") (parse-boolean \"true\") (parse-boolean \"no\")]", "[42 -7 nil nil 1.5 nil true nil]");
    try expectOutput("(try (char -1) (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutput("(try (parse-long 1) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
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
    // rand-int is (int (rand n)), as Clojure's: 0 for 0, (n, 0] below.
    try expectOutput("[(rand-int 0) (every? #(<= -4 % 0) (repeatedly 100 #(rand-int -5))) (rand-int 1)]", "[0 true 0]");
}

test "integration: format with %s %d %f %x %% and widths" {
    try expectOutput("(format \"%s-%d-%5.2f-%x-%%-%3d|%-3d|%05d\" \"a\" 42 3.14159 255 7 7 42)", "a-42- 3.14-ff-%-  7|7  |00042");
    try expectOutput("(format \"%s %s\" [1 \"b\"] nil)", "[1 \"b\"] nil");
    try expectOutput("(format \"%.1f %.3f %f\" 2 -0.0005 1.5)", "2.0 -0.001 1.500000");
    try expectOutput("(try (format \"%d\" \"x\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (format \"%d\") (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutput("(with-out-str (printf \"%d+%d\" 1 2))", "1+2");
}

test "integration: format widths count characters, %.Ns truncates, fields are bounded, %f prints every double" {
    try expectOutput("(format \"[%3s|%-3s|%2s]\" \"é\" \"é\" \"日本\")", "[  é|é  |日本]");
    try expectOutput("(format \"%.2s|%.0s|%.9s|%5.1s|%.1s\" \"héllo\" \"x\" \"ab\" \"éa\" nil)", "hé||ab|    é|n");
    try expectOutput("(let [s (format \"%.400f\" 1e300)] [(count s) (subs s 0 3) (subs s 299 304)])", "[702 100 00.00]");
    try expectOutput("(format \"%f %.2f %f %5.1f\" ##NaN ##Inf ##-Inf 1e-300)", "NaN Infinity -Infinity   0.0");
    try expectOutput("[(try (format \"%99999999999999999999d\" 1) (catch any e e)) (try (format \"%.99999999999999999999f\" 1.0) (catch any e e)) (try (format \"%2000000s\" \"\") (catch any e e))]", "[{:error :invalid-argument, :message invalid argument, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form}]");
    try expectOutput("[(try (format \"%.2d\" 1) (catch any e e)) (try (format \"%.1x\" 1) (catch any e e)) (try (format \"%.1c\" \\a) (catch any e e))]", "[{:error :invalid-argument, :message invalid argument, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form}]");
    try expectOutput("(count (format \"%1048576s\" \"\"))", "1048576");
}

test "integration: transients: transient, conj!, assoc!, dissoc!, disj!, pop!, persistent!" {
    try expectOutput("(persistent! (reduce conj! (transient []) (range 5)))", "[0 1 2 3 4]");
    try expectOutput("(let [t (transient {:a 1})] (persistent! (dissoc! (assoc! t :b 2 :c 3) :a)))", "{:b 2, :c 3}");
    try expectOutput("(persistent! (disj! (conj! (transient #{1}) 2 3) 1))", "#{2 3}");
    try expectOutput("(persistent! (pop! (assoc! (transient [1 2 3]) 0 9)))", "[9 2]");
    try expectOutput("(let [t (transient [1 2])] [(count t) (nth t 1) (get t 0) (count (transient {:a 1})) (get (transient {:a 1}) :a) (contains? (transient #{1}) 1)])", "[2 2 1 1 1 true]");
    try expectOutput("(let [t (transient [])] (persistent! t) (try (conj! t 1) (catch any e e)))", "{:error :transient-used-after-persistent, :message transient used after persistent!, :fn test-form}");
    try expectOutput("(try (transient '(1)) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(persistent! (conj! (transient {}) [:k 1]))", "{:k 1}");
    // conj! onto a transient map takes what conj onto a map takes: an
    // entry, a map or record whose entries are all added, or nil.
    try expectOutputProgram("(defrecord R [x]) (persistent! (conj! (transient {:a 1}) {:b 2 :c 3} nil [:d 4] (->R 5)))", "{:a 1, :b 2, :c 3, :d 4, :x 5}");
    try expectOutput("[(try (conj! (transient {}) [1 2 3]) (catch any e e)) (try (conj! (transient {}) 1) (catch any e e))]", "[{:error :arity-mismatch, :message arity mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
    // empty? counts a transient, as Clojure 1.12's does (CLJ-1872).
    try expectOutput("[(empty? (transient [])) (empty? (transient [1])) (empty? (transient {:a 1})) (empty? (transient #{}))]", "[true false false true]");
    try expectOutput("(let [t (transient [])] (persistent! t) (try (empty? t) (catch any e e)))", "{:error :transient-used-after-persistent, :message transient used after persistent!, :fn test-form}");
    // A transient is called, and looked up by a keyword, as its
    // persistent kind is.
    try expectOutput("[(:a (transient {:a 1})) (:b (transient {:a 1}) 7) ((transient {:a 1}) :a) ((transient {:a 1}) :b 9) ((transient [5 6]) 1) ((transient #{3}) 3) ((transient #{3}) 4) (:a (transient [1])) (map (transient {:a 1}) [:a :c])]", "[1 7 1 9 6 3 nil nil (1 nil)]");
    try expectOutput("[(try ((transient [1 2]) 5) (catch any e e)) (try ((transient [1 2]) :a) (catch any e e)) (try ((transient #{1}) 1 2) (catch any e e))]", "[{:error :index-out-of-bounds, :message index 5 is out of bounds for a transient, :fn test-form} {:error :kind-mismatch, :message a transient takes an integer index, got a keyword, :fn test-form} {:error :arity-mismatch, :message a transient takes 1 argument, got 2, :fn test-form}]");
    try expectOutput("(let [t (transient {:a 1})] (persistent! t) [(try (:a t) (catch any e e)) (try (t :a) (catch any e e)) (try (get t :a) (catch any e e))])", "[{:error :transient-used-after-persistent, :message transient used after persistent!, :fn test-form} {:error :transient-used-after-persistent, :message transient used after persistent!, :fn test-form} {:error :transient-used-after-persistent, :message transient used after persistent!, :fn test-form}]");
    try expectOutput("(let [t (transient [1 2 3])] (identical? t (assoc! t 3 4)))", "true");
    try expectOutput("[(try (assoc! (transient [1]) 5 :x) (catch any e e)) (try (pop! (transient [])) (catch any e e))]", "[{:error :index-out-of-bounds, :message index out of bounds, :fn test-form} {:error :index-out-of-bounds, :message index out of bounds, :fn test-form}]");
    try expectOutput("[(pop [1 2 3]) (pop [1]) (count (reduce (fn [v _] (pop v)) (vec (range 2000)) (range 1990)))]", "[[1 2] [] 10]");
}

/// Run `before`, which wraps the heap's edit clock, from 50 tokens
/// short of the wrap; then run `after` with the clock moved forward to
/// there again, so `after`'s transients take the tokens `before`'s took
/// (TRANSIENT.md §4), and print `after`.
fn expectAcrossEditClockWrap(before: []const u8, after: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const heap = program.v.ensureHeap();
    heap.edit_clock = nx.heap.edit_token_max - 50;
    _ = try program.run(before);
    try testing.expect(heap.edit_clock < nx.heap.edit_token_max - 50);
    heap.edit_clock = nx.heap.edit_token_max - 50;
    try harness.expectResult(&program, after, try program.run(after), expected);
}

test "integration: group-by's buckets keep their elements across the edit clock's wrap" {
    // group-by's `f` wraps the clock on its first call: the buckets
    // are edited under the map's token as it stands after the call.
    try expectAcrossEditClockWrap(
        \\(def spin (fn [] (dotimes [_ 100] (transient []))))
        \\(def b (get (group-by (fn [x] (when (= x 0) (spin)) :k) (range 10)) :k))
    ,
        \\(dotimes [_ 49] (assoc! (transient b) 0 :evil))
        \\b
    , "[0 1 2 3 4 5 6 7 8 9]");
}

test "integration: a `!` call that raises across the edit clock's wrap leaves its transient no stale token" {
    try expectAcrossEditClockWrap(
        \\(def t (transient {}))
        \\(dotimes [_ 100] (try (conj! t [:x 1] :bad) (catch any e e)))
        \\(dotimes [i 40] (conj! t [i i]))
        \\(def p (persistent! t))
        \\(dotimes [_ 100] (transient []))
    ,
        \\(dotimes [_ 49] (let [u (transient p)] (dotimes [i 40] (assoc! u i :evil))))
        \\(= p (zipmap (range 40) (range 40)))
    , "true");
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

test "nextomic: a connection prints its path as a string literal" {
    try expectOutputProgramWithStore("conn-print",
        \\(def c (nextomic/connect "@STORE@\"q\ny"))
        \\(def printed [(pr-str c) (str c)])
        \\(nextomic/release c)
        \\(let [p (str "#nextomic/conn " (pr-str "@STORE@\"q\ny"))] (= printed [p p]))
    , "true");
}

test "integration: delay, force, realized?, delay?" {
    try expectOutput("(let [n (atom 0) d (delay (swap! n inc) :v)] [(realized? d) (delay? d) @d (realized? d) (force d) @d @n (force 3) (delay? 1)])", "[false true :v true :v :v 1 3 false]");
    // A throw is cached: the body runs once and every deref rethrows it.
    try expectOutput("(let [n (atom 0) d (delay (swap! n inc) (throw :boom))] [(try @d (catch any e e)) (try (force d) (catch any e e)) @n (realized? d)])", "[:boom :boom 1 true]");
    try expectOutput("(let [d (delay nil)] [@d (realized? d) (= d d) (= d (delay nil))])", "[nil true true false]");
    try expectOutput("[(try (realized? 1) (catch any e e)) (try (realized? nil) (catch any e e))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
    try expectOutputUnderGc("(let [ds (mapv (fn [i] (delay (vec (range i)))) (range 50))] (reduce + (map (comp count deref) ds)))", "1225");
}

test "integration: with-open closes each binding in reverse order, through Closeable" {
    try expectOutput(
        \\(def log (atom []))
        \\(defrecord R [n] Closeable (close [_] (swap! log conj n)))
        \\[(with-open [a (->R 1) b (->R 2)] (swap! log conj :body) :result) @log
        \\ (try (with-open [c (->R 3)] (throw :boom)) (catch any e e)) @log (with-open [] 7)]
    , "[:result [:body 2 1] :boom [:body 2 1 3] 7]");
    try expectOutput("(try (with-open [a 1] 2) (catch any e e))", "{:error :no-protocol-impl, :message no impl of close for an integer, :fn test-form}");
    try expectOutput("(try (macroexpand '(with-open [a] 1)) (catch any e e))", "{:error :macro-expansion-failure, :message macro with-open threw with-open takes a vector of symbol and value pairs, :fn test-form}");
    try expectOutputProgramWithStore("with-open-conns",
        \\(def c (with-open [c (db/open "@STORE@")] c))
        \\(def n (with-open [n (nextomic/connect "@STORE@.nextomic")] n))
        \\[(try (db/begin-read c) (catch any e e)) (try (nextomic/db n) (catch any e (or (:error e) e)))]
    , "[{:error :db-closed, :message db closed, :fn test-form} :nextomic/closed]");
}

test "integration: tap> calls every tap, and a tap that throws is ignored" {
    try expectOutput(
        \\(def seen (atom []))
        \\(defn t1 [x] (swap! seen conj [:t1 x]))
        \\(defn t2 [x] (throw :bad))
        \\[(tap> 0) (add-tap t1) (add-tap t2) (tap> 1) (remove-tap t1) (tap> 2) @seen (remove-tap t2)]
    , "[true nil nil true nil true [[:t1 1]] nil]");
}

test "integration: class, type, instance?, var?, special-symbol?" {
    try expectOutput("(map class [nil true false \\a 1 99999999999999999999 1.5 :k 'x \"s\" '(1) [1] {:a 1} #{1} (i64-vector [1]) (fn [] 1) first (atom 1) (transient []) #'inc])", "(nil :boolean :boolean :char :fixnum :bignum :float :keyword :symbol :string :list :vector :map :set :typed_vector :function :native_fn :atom :transient :var_)");
    // A record's type is the symbol it prints with; :type metadata is type's.
    try expectOutput("(defrecord P [x]) [(class (->P 1)) (type (->P 1)) (symbol? (type (->P 1))) (type (with-meta [1] {:type :point})) (class (with-meta [1] {:type :point})) (type (with-meta (->P 1) {:type :q}))]", "[user.P user.P true :point :vector :q]");
    try expectOutput("(defrecord P [x]) [(instance? :vector [1]) (instance? :map [1]) (instance? 'user.P (->P 1)) (instance? (type (->P 1)) (->P 2)) (instance? :map (->P 1)) (instance? :vector (with-meta [] {:type :t})) (try (instance? nil 1) (catch any e e))]", "[true false true true false true {:error :kind-mismatch, :message instance? takes a kind keyword or a record symbol, got nil, :fn test-form}]");
    try expectOutput("(def x 1) [(var? #'x) (var? x) (var? 'x) (var? (resolve 'inc))]", "[true false false true]");
    try expectOutput("(map special-symbol? '[if def let* fn* loop* letfn* quote var recur try catch finally throw do set! & let fn nexis.core/if])", "(true true true true true true true true true true true true true true true true false false false)");
    try expectOutput("[(special-symbol? \"if\") (special-symbol? :if)]", "[false false]");
}

// Hierarchies (STDLIB.md §9.1): Clojure 1.12's multimethods.clj tests,
// `::x` spelled `:user/x`, sets compared with `=` (print order differs).

/// `family`, `diamond` and `bird-no-more` of multimethods.clj, and its
/// `assert-valid-hierarchy` as a predicate.
const hierarchies =
    \\(def family (reduce #(apply derive (cons %1 %2)) (make-hierarchy)
    \\  [[:user/parent-1 :user/ancestor-1] [:user/parent-1 :user/ancestor-2] [:user/parent-2 :user/ancestor-2]
    \\   [:user/child :user/parent-2] [:user/child :user/parent-1]]))
    \\(def diamond (reduce #(apply derive (cons %1 %2)) (make-hierarchy)
    \\  [[:user/mammal :user/animal] [:user/bird :user/animal] [:user/griffin :user/mammal] [:user/griffin :user/bird]]))
    \\(def bird-no-more (underive diamond :user/griffin :user/bird))
    \\(defn closure [o f]
    \\  (loop [results #{} more #{o}]
    \\    (if (seq (remove results more))
    \\      (recur (into results more) (reduce into #{} (map f (remove results more))))
    \\      (disj results o))))
    \\(defn valid? [h]
    \\  (every? (fn [tag]
    \\            (and (= (closure tag #(parents h %)) (or (ancestors h tag) #{}))
    \\                 (= (closure tag #(ancestors h %)) (or (ancestors h tag) #{}))
    \\                 (= (closure tag #(descendants h %)) (or (descendants h tag) #{}))
    \\                 (every? #(isa? h tag %) (parents h tag))
    \\                 (every? #(isa? h tag %) (ancestors h tag))
    \\                 (every? #(isa? h % tag) (descendants h tag))
    \\                 (not (contains? (closure tag #(parents h %)) tag))
    \\                 (not (contains? (descendants h tag) tag))))
    \\          (set (filter ident? (reduce into #{} (map keys (vals h)))))))
    \\
;

test "hierarchies: derive builds the closures, refuses cycles, and keeps an existing edge identical" {
    try expectOutputProgram(hierarchies ++
        \\[(valid? family) (= (ancestors family :user/child) #{:user/ancestor-1 :user/ancestor-2 :user/parent-1 :user/parent-2})
        \\ (= (descendants family :user/ancestor-2) #{:user/parent-1 :user/parent-2 :user/child})
        \\ (sort (ancestors family :user/parent-1)) (parents family :user/ancestor-1) (ancestors family :user/nope)
        \\ (try (derive family :user/ancestor-1 :user/child) (catch any e e))
        \\ (try (derive family :user/child :user/ancestor-1) (catch Exception e (:message e)))
        \\ (identical? family (derive family :user/child :user/parent-1))]
    , "[true true true (:user/ancestor-1 :user/ancestor-2) nil nil {:error :invalid-derivation, :message Cyclic derivation: :user/child has :user/ancestor-1 as ancestor} :user/child already has :user/ancestor-1 as ancestor true]");
    // The assertions, each with the text of Clojure 1.12's form.
    try expectOutputProgram(hierarchies ++
        \\(map #(try (%) (catch AssertionError e (pr-str (:message e))))
        \\  [#(derive family :user/child :user/child) #(derive family "s" :user/p) #(derive family :user/a "p")
        \\   #(derive :a :user/x) #(derive :user/a :x)])
    , "(\"Assert failed: (not= tag parent)\" \"Assert failed: (or (class? tag) (instance? clojure.lang.Named tag))\" \"Assert failed: (instance? clojure.lang.Named parent)\" \"Assert failed: (or (class? tag) (and (instance? clojure.lang.Named tag) (namespace tag)))\" \"Assert failed: (namespace parent)\")");
    try expectOutputProgram("[(try (derive :user/a 1) (catch any e e)) (try (derive :user/a 'b) (catch any e (:error e)))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} :assertion-failed]");
}

test "hierarchies: underive rebuilds from the remaining edges; isa? over the diamond and over vectors" {
    try expectOutputProgram(hierarchies ++
        \\[(valid? diamond) (valid? bird-no-more)
        \\ (isa? diamond :user/griffin :user/animal) (isa? diamond :user/griffin :user/bird)
        \\ (isa? bird-no-more :user/griffin :user/bird) (isa? bird-no-more :user/griffin :user/animal)
        \\ (= bird-no-more {:parents {:user/mammal #{:user/animal} :user/bird #{:user/animal} :user/griffin #{:user/mammal}}
        \\                  :ancestors {:user/mammal #{:user/animal} :user/bird #{:user/animal} :user/griffin #{:user/mammal :user/animal}}
        \\                  :descendants {:user/animal #{:user/mammal :user/bird :user/griffin} :user/mammal #{:user/griffin}}})
        \\ (identical? diamond (underive diamond :user/griffin :user/nothing))
        \\ (identical? diamond (derive diamond :user/griffin :user/bird))]
    , "[true true true true false true true true true]");
    try expectOutputProgram(hierarchies ++
        \\[(isa? diamond [:user/griffin :user/bird] [:user/animal :user/animal]) (isa? [] []) (isa? [:a] [:a])
        \\ (isa? diamond [:user/griffin] [:user/animal :user/animal]) (isa? diamond [:user/griffin :user/bird] [:user/animal :user/mammal])
        \\ (isa? diamond '(:user/griffin) '(:user/animal)) (isa? {} :a :b) (isa? 1 1)]
    , "[true true true false false false false true]");
}

test "hierarchies: the global hierarchy is a private Var that derive and underive change" {
    try expectOutputProgram(hierarchies ++
        \\(with-redefs [nexis.core/global-hierarchy (make-hierarchy)]
        \\  [(derive :user/lion :user/cat) (derive :user/manx :user/cat) (valid? @#'nexis.core/global-hierarchy)
        \\   (isa? :user/lion :user/cat) (isa? :user/cat :user/lion) (= #{:user/manx :user/lion} (descendants :user/cat))
        \\   (parents :user/manx) (ancestors :user/manx) (underive :user/manx :user/cat)
        \\   (descendants :user/cat) (parents :user/manx) (ancestors :user/manx)])
    , "[nil nil true true false true #{:user/cat} #{:user/cat} nil #{:user/lion} nil nil]");
    try expectOutputProgram("(with-redefs [nexis.core/global-hierarchy (make-hierarchy)] (derive :user/a :user/b)) [(parents :user/a) (:private (meta #'nexis.core/global-hierarchy))]", "[nil true]");
}

test "hierarchies: class? holds of what class returns, which the global hierarchy takes as tags" {
    try expectOutputProgram(
        \\(defrecord Circle [r])
        \\[(every? class? (map class [true \a 1 99999999999999999999 1.5 :k 'x "s" '(1) [1] {:a 1} #{1} (sorted-map) (sorted-set) (lazy-seq nil)
        \\                            (i64-vector [1]) (fn [] 1) first (atom 1) (transient []) #'inc (->Circle 1) (delay 1) #"a"]))
        \\ (map class? [:frob :persistent_vector :true_ :nil :record :cell_internal :user/vector 'user.Nope 'Circle "vector" nil (class nil)])
        \\ (class? 'user.Circle) (class? Circle)]
    , "[true (false false false false false false false false false false false false) true true]");
    try expectOutputProgram(
        \\(defrecord Circle [r])
        \\(with-redefs [nexis.core/global-hierarchy (make-hierarchy)]
        \\  (derive :vector :user/coll) (derive Circle :user/shape)
        \\  [(isa? (class [1]) :user/coll) (isa? (class (->Circle 1)) :user/shape) (isa? (class '(1)) :user/coll) (parents Circle)
        \\   (try (derive :frob :user/x) (catch any e (:error e)))])
    , "[true true false #{:user/shape} :assertion-failed]");
}

// Multimethods (STDLIB.md §9.2–§9.4): Clojure 1.12's multimethods.clj
// tests and further cases, each expected value checked with bb.

test "multimethods: dispatch, :default, remove-method and a method added later" {
    try expectOutputProgram(
        \\(defmulti too-simple identity)
        \\(defmethod too-simple :a [x] :a)
        \\(defmethod too-simple :b [x] :b)
        \\(defmethod too-simple :default [x] :default)
        \\[(too-simple :a) (too-simple :b) (too-simple :c) (do (remove-method too-simple :a) (too-simple :a))
        \\ (do (defmethod too-simple :d [x] :d) (too-simple :d))]
    , "[:a :b :default :default :d]");
    // isA-multimethod-test, with kinds for Java's classes.
    try expectOutputProgram(
        \\(derive :vector :user/collection)
        \\(derive :map :user/collection)
        \\(defmulti foo class)
        \\(defmethod foo :user/collection [c] :a-collection)
        \\(defmethod foo :string [s] :a-string)
        \\[(foo []) (foo {}) (foo "bar") (try (foo 1) (catch any e (:error e)))]
    , "[:a-collection :a-collection :a-string :no-method]");
    // A record type dispatched on with no hierarchy, and a nil dispatch value.
    try expectOutputProgram(
        \\(defrecord Circle [r])
        \\(defmulti area class)
        \\(defmethod area Circle [c] (* 3 (:r c) (:r c)))
        \\(defmulti nn identity)
        \\(defmethod nn nil [_] :nil)
        \\[(area (->Circle 2)) (nn nil)]
    , "[12 :nil]");
    // Every arity: dispatch on six arguments, and on none.
    try expectOutputProgram(
        \\(defmulti six (fn [a b c d e f] (+ a b c d e f)))
        \\(defmethod six 21 [a b c d e f] f)
        \\(defmulti zero (fn [] :z))
        \\(defmethod zero :z [] :zero)
        \\(defmulti arities (fn [& xs] (count xs)))
        \\(defmethod arities :default [& xs] (vec xs))
        \\[(six 1 2 3 4 5 6) (zero) (map #(apply arities (range %)) (range 7))]
    , "[6 :zero ([] [0] [0 1] [0 1 2] [0 1 2 3] [0 1 2 3 4] [0 1 2 3 4 5])]");
}

test "multimethods: preferences resolve an ambiguity, directly or through ancestors" {
    try expectOutputProgram(
        \\(derive :user/rect :user/shape)
        \\(defmulti bar (fn [x y] [x y]))
        \\(defmethod bar [:user/rect :user/shape] [x y] :rect-shape)
        \\(defmethod bar [:user/shape :user/rect] [x y] :shape-rect)
        \\[(try (bar :user/rect :user/rect) (catch IllegalArgumentException e (:message e))) (prefers bar)
        \\ (do (prefer-method bar [:user/rect :user/shape] [:user/shape :user/rect]) (bar :user/rect :user/rect)) (prefers bar)
        \\ (try (prefer-method bar [:user/shape :user/rect] [:user/rect :user/shape]) (catch IllegalStateException e e))]
    , "[Multiple methods in multimethod 'bar' match dispatch value: [:user/rect :user/rect] -> [:user/shape :user/rect] and [:user/rect :user/shape], and neither is preferred {} :rect-shape {[:user/rect :user/shape] #{[:user/shape :user/rect]}} {:error :preference-conflict, :message Preference conflict in multimethod 'bar': [:user/rect :user/shape] is already preferred to [:user/shape :user/rect]}]");
    // indirect-preferences-mulitmethod-test, against the global hierarchy and #'local-h.
    try expectOutputProgram(
        \\(derive :user/parent-1 :user/grandparent-1)
        \\(derive :user/parent-2 :user/grandparent-2)
        \\(derive :user/child :user/parent-1)
        \\(derive :user/child :user/parent-2)
        \\(defmulti indirect-1 keyword)
        \\(prefer-method indirect-1 :user/parent-1 :user/grandparent-2)
        \\(defmethod indirect-1 :user/parent-1 [_] :user/parent-1)
        \\(defmethod indirect-1 :user/parent-2 [_] :user/parent-2)
        \\(defmulti indirect-2 keyword)
        \\(prefer-method indirect-2 :user/grandparent-1 :user/parent-2)
        \\(defmethod indirect-2 :user/parent-1 [_] :user/parent-1)
        \\(defmethod indirect-2 :user/parent-2 [_] :user/parent-2)
        \\(def local-h (-> (make-hierarchy) (derive :parent-1 :grandparent-1) (derive :parent-2 :grandparent-2)
        \\                 (derive :child :parent-1) (derive :child :parent-2)))
        \\(defmulti indirect-3 keyword :hierarchy #'local-h)
        \\(prefer-method indirect-3 :parent-1 :grandparent-2)
        \\(defmethod indirect-3 :parent-1 [_] :parent-1)
        \\(defmethod indirect-3 :parent-2 [_] :parent-2)
        \\(defmulti indirect-4 keyword :hierarchy #'local-h)
        \\(prefer-method indirect-4 :grandparent-1 :parent-2)
        \\(defmethod indirect-4 :parent-1 [_] :parent-1)
        \\(defmethod indirect-4 :parent-2 [_] :parent-2)
        \\[(indirect-1 :user/child) (indirect-2 :user/child) (indirect-3 :child) (indirect-4 :child)]
    , "[:user/parent-1 :user/parent-1 :parent-1 :parent-1]");
    // An exact match wins over a preference for one of its ancestors.
    try expectOutputProgram(
        \\(derive :user/x :user/y)
        \\(defmulti e identity)
        \\(defmethod e :user/x [_] :x)
        \\(defmethod e :user/y [_] :y)
        \\(prefer-method e :user/y :user/x)
        \\(e :user/x)
    , ":x");
}

test "multimethods: methods, get-method, prefers, remove-all-methods and what each returns" {
    try expectOutputProgram(
        \\(defmulti simple1 identity)
        \\(defmethod simple1 :a [x] :a)
        \\(defmethod simple1 :b [x] :b)
        \\(defmulti simple2 identity)
        \\(defmethod simple2 :a [x] :a)
        \\(defmethod simple2 :b [x] :b)
        \\(defmulti simple3 identity)
        \\(defmethod simple3 :a [x] :a)
        \\(defmethod simple3 :b [x] :b)
        \\[(methods (remove-all-methods simple1)) (prefers simple1)
        \\ (= #{:a :b} (into #{} (keys (methods simple2)))) ((:a (methods simple2)) 1)
        \\ (do (defmethod simple2 :c [x] :c) (= #{:a :b :c} (into #{} (keys (methods simple2)))))
        \\ (do (remove-method simple2 :a) (= #{:b :c} (into #{} (keys (methods simple2)))))
        \\ (fn? (get-method simple3 :a)) ((get-method simple3 :a) 1) ((get-method simple3 :b) 1) (get-method simple3 :c)]
    , "[{} {} true :a true true true :a :b nil]");
    try expectOutputProgram(
        \\(defmulti rv identity)
        \\[(= rv (defmethod rv :a [_] :a)) (= rv (prefer-method rv :a :b)) (prefers rv) (= rv (remove-method rv :a))
        \\ (do (defmethod rv :c [_] :c) (= rv (remove-all-methods rv))) (methods rv) (prefers rv)
        \\ (multifn? rv) (multifn? inc) (fn? rv) (ifn? rv) (= rv rv) (get {rv 1} rv) (meta rv)
        \\ (try (with-meta rv {:a 1}) (catch any e e)) (try (methods {}) (catch ClassCastException e e))
        \\ (try (defmethod {} :a [] 1) (catch any e e))]
    , "[true true {:a #{:b}} true true {} {} true false true true true 1 nil {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message expected a multimethod, got a map, :fn test-form} {:error :kind-mismatch, :message expected a multimethod, got a map, :fn test-form}]");
    // get-method: an ambiguity throws as a call does; no match and no default is nil.
    try expectOutputProgram(
        \\(derive :user/a :user/c) (derive :user/b :user/c) (derive :user/ab :user/a) (derive :user/ab :user/b)
        \\(defmulti amb identity)
        \\(defmethod amb :user/a [_] :a)
        \\(defmethod amb :user/b [_] :b)
        \\[(try (get-method amb :user/ab) (catch IllegalArgumentException e e)) (get-method amb :user/zzz) ((get-method amb :user/a) 0)]
    , "[{:error :ambiguous-method, :value :user/ab, :message Multiple methods in multimethod 'amb' match dispatch value: :user/ab -> :user/b and :user/a, and neither is preferred} nil :a]");
}

test "multimethods: :default and :hierarchy options; the cache follows the hierarchy" {
    // With :default :user/dflt, a method under :default is an ordinary entry.
    try expectOutputProgram(
        \\(defmulti dd identity :default :user/dflt)
        \\(defmethod dd :default [_] :plain-default)
        \\[(try (dd 1) (catch IllegalArgumentException e (:message e))) (dd :default) (do (defmethod dd :user/dflt [_] :dflt) (dd 1))]
    , "[No method in multimethod 'dd' for dispatch value: 1 :plain-default :dflt]");
    // A derive and an underive each make a new hierarchy, which resets the cache.
    try expectOutputProgram(
        \\(def ch (atom (make-hierarchy)))
        \\(defmulti c identity :hierarchy ch)
        \\(defmethod c :default [_] :dflt)
        \\(defmethod c :user/animal [_] :animal)
        \\[(c :user/dog) (do (swap! ch derive :user/dog :user/animal) (c :user/dog)) (do (swap! ch underive :user/dog :user/animal) (c :user/dog))]
    , "[:dflt :animal :dflt]");
    try expectOutputProgram(
        \\(defmulti g identity)
        \\(defmethod g :default [_] :dflt)
        \\(defmethod g :user/animal [_] :animal)
        \\[(g :user/dog) (do (derive :user/dog :user/animal) (g :user/dog)) (do (underive :user/dog :user/animal) (g :user/dog))
        \\ (with-redefs [nexis.core/global-hierarchy (derive (make-hierarchy) :user/cat :user/animal)] (g :user/cat)) (g :user/cat)]
    , "[:dflt :animal :dflt :animal :dflt]");
    try expectOutputProgram(
        \\(def ah (atom (make-hierarchy)))
        \\(defmulti p identity :hierarchy ah)
        \\(defmethod p :user/parent [_] :p)
        \\(swap! ah derive :user/kid :user/parent)
        \\[(p :user/kid) (try (defmulti bad identity :hierarchy {}) (catch ClassCastException e e))]
    , "[:p {:error :kind-mismatch, :message make-multifn reads its hierarchy through a Var or an atom, got a map, :fn test-form}]");
}

test "multimethods: defmulti defines once; its docstring and attr-map reach the Var" {
    try expectOutputProgram(
        \\(def first-def (defmulti r identity))
        \\(defmethod r 1 [_] :one)
        \\(def second-def (defmulti r (fn [x] 2)))
        \\(def kept (r 1))
        \\(def r nil)
        \\(defmulti r identity)
        \\(defmulti doc-m "the doc" {:extra 1} identity)
        \\[first-def second-def kept (methods r) ((juxt :doc :extra :name) (meta #'doc-m))]
    , "[#'user/r nil :one {} [the doc 1 doc-m]]");
    try expectOutputProgram(
        \\[(try (eval '(defmulti s1 identity :default)) (catch any e ((juxt :error :message) e)))
        \\ (try (eval '(defmulti s2 identity :frob 1)) (catch any e ((juxt :error :message) e)))]
    , "[[:compile-error macro defmulti threw The syntax for defmulti has changed. Example: (defmulti name dispatch-fn :default dispatch-value)] [:compile-error macro defmulti threw Only these options are valid: :default, :hierarchy]]");
}

test "multimethods: the no-method message prints the dispatch value as %s; recursion is as deep as a defn's" {
    try expectOutputProgram(
        \\(defmulti area :shape)
        \\(map #(try (area %) (catch IllegalArgumentException e (pr-str e))) [{:shape :tri} {:shape "tri"} {:shape [:a "b"]} {}])
    ,
        \\({:error :no-method, :value :tri, :message "No method in multimethod 'area' for dispatch value: :tri"} {:error :no-method, :value "tri", :message "No method in multimethod 'area' for dispatch value: tri"} {:error :no-method, :value [:a "b"], :message "No method in multimethod 'area' for dispatch value: [:a \"b\"]"} {:error :no-method, :value nil, :message "No method in multimethod 'area' for dispatch value: nil"})
    );
    // The dispatch function and the method are ordinary calls, so no native stack nests.
    try expectOutputProgram(
        \\(defmulti deep (fn [n] (if (zero? n) :done :more)))
        \\(defmethod deep :done [n] 0)
        \\(defmethod deep :more [n] (inc (deep (dec n))))
        \\(deep 100000)
    , "100000");
}

test "multimethods: #%mm-lookup reads a cache only while its hierarchy is the one it was built against" {
    try expectOutputProgram(
        \\(def h (atom {}))
        \\(def cache (atom [@h {:a 1 [:v] 2}]))
        \\(def lookup nexis.internal/#%mm-lookup)
        \\[(lookup cache h :a) (lookup cache h [:v]) (lookup cache h :b) (do (reset! h {:parents {}}) (lookup cache h :a))
        \\ (lookup cache #'nexis.core/global-hierarchy :a)
        \\ (try (lookup {} h :a) (catch any e e)) (try (lookup cache {} :a) (catch any e e))]
    , "[1 2 nil nil nil {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "multimethods: a multimethod is unserializable as any function" {
    try expectOutputProgramWithStore("multifn",
        \\(defmulti m identity)
        \\(def c (db/open "@STORE@"))
        \\(try (db/put-key! (db/ref c :t "m") m) (catch :unserializable e e))
    , "{:error :unserializable, :message unserializable, :fn test-form}");
}

const apputil = [2][]const u8{ "app/util.nx", "(ns app.util)\n(def x 1)\n(defn- y [] 2)\n" };

test "integration: namespaces as their name symbols: the-ns, find-ns, ns-name, all-ns, ns-publics, ns-interns" {
    try expectOutputWithFiles(&.{apputil},
        \\(ns user (:require [app.util :as u :refer [x]]))
        \\[(the-ns 'app.util) (find-ns 'app.util) (find-ns 'nope) (ns-name 'user) (try (the-ns 'nope) (catch any e e))
        \\ (ns-publics 'app.util) (ns-interns 'app.util) (contains? (ns-publics 'user) 'x) (get (ns-publics 'nexis.core) 'inc)
        \\ (every? symbol? (all-ns)) (boolean (some #{'app.util} (all-ns))) (try (find-ns "user") (catch any e e))]
    , "[app.util app.util nil user {:error :no-such-namespace, :message no namespace named nope, :fn test-form} {x #'app.util/x} {x #'app.util/x, y #'app.util/y} false #'nexis.core/inc true true {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "integration: resolve and ns-resolve name a Var through the namespace's names" {
    try expectOutputWithFiles(&.{apputil},
        \\(ns user (:require [app.util :as u :refer [x]] [nexis.string :as s]))
        \\(def own 2)
        \\[(resolve 'first) (resolve 'x) (resolve 'u/x) (resolve 'app.util/x) (resolve 's/join) (resolve 'own) (resolve 'nope) (resolve 'nope/x) (resolve 'u/nope)
        \\ (ns-resolve 'app.util 'x) (ns-resolve 'app.util 'own) (ns-resolve 'app.util 'inc) (resolve 'when) (@(resolve 'inc) 1)
        \\ (try (resolve "x") (catch any e e)) (try (ns-resolve 'nope 'x) (catch any e e))]
    , "[#'nexis.core/first #'app.util/x #'app.util/x #'app.util/x #'nexis.string/join #'user/own nil nil nil #'app.util/x nil #'nexis.core/inc nil 2 {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :no-such-namespace, :message no such namespace, :fn test-form}]");
}

test "vars: alter-var-root sets a Var's root through a function, beneath a binding too" {
    try expectOutputProgram("(def x 1) (defn f [] x) [(alter-var-root #'x + 10 5) x (f) (try (alter-var-root 1 inc) (catch any e e))]", "[16 16 16 {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
    try expectOutputProgram("(def ^:dynamic *d* 1) [(binding [*d* 2] [(alter-var-root #'*d* inc) *d*]) *d*]", "[[2 2] 2]");
    // An unbound Var's root is nil to the function, and bound after.
    try expectOutputProgram("(def u) [(alter-var-root #'u (constantly 3)) u]", "[3 3]");
}

test "vars: with-redefs sets roots for its body and restores them on every exit" {
    try expectOutputProgram("(defn f [] :f) (defn g [] (f)) (def n 1) [(with-redefs [f (fn [] :redef) n 2] [(f) (g) n]) (f) n]", "[[:redef :redef 2] :f 1]");
    try expectOutputProgram("(defn f [] :f) [(try (with-redefs [f (fn [] :r)] (throw :boom)) (catch any e e)) (f)]", "[:boom :f]");
    try expectOutputProgram("(def x 1) [(with-redefs-fn {#'x 5} (fn [] x)) x]", "[5 1]");
    try expectOutput("(with-redefs [rand-int (constantly 4)] (rand-int 100))", "4");
    // An unbound Var is unbound again afterwards, as Clojure restores its Unbound root.
    try expectOutputProgram("(declare u) [(with-redefs [u (fn [] :r)] (u)) (bound? #'u) (try (u) (catch any e e)) (try (with-redefs-fn {#'u 1} (fn [] (throw :t))) (catch any e e)) (bound? #'u)]", "[:r false {:error :unbound-var, :message unbound var, :fn test-form} :t false]");
}

test "vars: *ns* is the current namespace's name symbol where a form is compiled and run; flush is a no-op" {
    try expectOutputProgram("(ns app.core) (def here *ns*) (defmacro m [] (list 'quote (ns-name *ns*))) [here (= \"app.core\" (str *ns*)) (m) (ns-name *ns*)]", "[app.core true app.core app.core]");
    try expectOutputProgram("(in-ns 'other) (def a *ns*) (in-ns 'user) [other/a *ns* (do (in-ns 'x) (let [n *ns*] (in-ns 'user) n))]", "[other user x]");
    try expectOutput("[(flush) (var? #'*ns*) *ns*]", "[nil true user]");
}

test "integration: a UUID is its canonical string" {
    try expectOutput("(let [u (random-uuid)] [(uuid? u) (string? u) (count u) (subs u 14 15) (contains? #{\\8 \\9 \\a \\b} (nth u 19)) (= u (parse-uuid u)) (not= u (random-uuid))])", "[true true 36 4 true true true]");
    try expectOutput("(pr-str [(parse-uuid \"0123ABCD-4567-89EF-0123-456789ABCDEF\") (parse-uuid \"nope\") (parse-uuid \"0123abcd-4567-89ef-0123-456789abcdef0\") (parse-uuid \"0123abcd+4567-89ef-0123-456789abcdef\") (parse-uuid \"0123abcd-4567-89ef-0123-456789abcdeg\")])", "[\"0123abcd-4567-89ef-0123-456789abcdef\" nil nil nil nil]");
    try expectOutput("[(uuid? \"0123abcd-4567-89ef-0123-456789abcdef\") (uuid? \"0123ABCD-4567-89EF-0123-456789ABCDEF\") (uuid? 1) (uuid? nil) (try (parse-uuid nil) (catch any e e)) (try (parse-uuid 1) (catch any e e))]", "[true false false false {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "integration: in-ns switches the namespace the next forms compile in" {
    try expectOutputProgram("(in-ns 'other) (def x 1) (in-ns 'user) [other/x (try (in-ns \"s\") (catch any e e))]", "[1 {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "gc: a native that calls a native through callValue reaches a safe point" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
    // reduce calls the conj native for every element with no
    // closure frame in between; each persistent set conj leaves the
    // replaced path behind as garbage.
    _ = try program.run("(def xs (vec (range 20000)))");
    const heap = &program.v.heap.?;
    heap.peak_live_bytes = heap.live_bytes;
    const start = heap.live_bytes;
    _ = try program.run("(def s (reduce conj #{} xs))");
    program.v.collectGarbage();
    const kept = heap.live_bytes - start;
    const peak = heap.peak_live_bytes - start;
    try testing.expect(peak < 3 * kept);
}

test "gc: a native that calls a leaf native collects once a cycle is due" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
    // Each running product is garbage once reduce has the next.
    _ = try program.run("(def xs (vec (range 1 3000)))");
    program.v.collectGarbage();
    const heap = &program.v.heap.?;
    heap.peak_live_bytes = heap.live_bytes;
    const start = heap.live_bytes;
    _ = try program.run("(def p (reduce * xs))");
    // The products' sum is about 6 MB; collected as they go, the peak
    // stays within a few cycle windows of the start.
    try testing.expect(heap.peak_live_bytes -| start < 1 << 20);
}

test "gc: a product of many integers in one call keeps no partial product" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(def xs (vec (range 1 3000))) (def p (reduce * xs))");
    program.v.collectGarbage();
    const heap = &program.v.heap.?;
    heap.peak_live_bytes = heap.live_bytes;
    const start = heap.live_bytes;
    // One call of `*`, a leaf no collection runs inside: the partial
    // products would sum to about 6 MB.
    try harness.expectResult(&program, "", try program.run("(= (apply * xs) p)"), "true");
    try testing.expect(heap.peak_live_bytes -| start < 1 << 20);
    try harness.expectResult(&program, "", try program.run("[(apply * 1 2 3 (range 4 30)) (* 4611686018427387904 2 3.0) (* 2 4611686018427387904 -1) (try (* 4611686018427387904 2 :x) (catch any e e))]"), "[8841761993739701954543616000000 2.7670116110564327E19 -9223372036854775808 {:error :kind-mismatch, :message * expects numbers, got a keyword, :fn test-form}]");
}

test "integration: a sequence native walks a view from its offset, and a cons over one" {
    try expectOutputProgram(
        \\(let [v (map inc (range 100))]
        \\  [(every? (fn [k] (= (map identity (drop k v)) (range (inc k) 101))) (range 0 101))
        \\   (every? (fn [k] (= (filter even? (nthrest v k)) (filter even? (range (inc k) 101)))) [1 31 32 33 64 99])
        \\   (= (reduce + (rest v)) 5049) (= (mapv inc (cons 0 (rest v))) (cons 1 (range 3 102)))
        \\   (= (map inc (rest (rest '(1 2 3 4 5)))) '(4 5 6))])
    , "[true true true true true]");
}

test "gc: map, filter and mapv build a long result in place, not on the root stack" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const v = try program.run(
        \\(let [xs (range 100000)]
        \\  [(count (mapv inc xs)) (reduce + (map inc xs)) (count (filter even? xs)) (count (filterv odd? xs))
        \\   (count (remove even? xs)) (count (keep identity xs)) (count (map-indexed vector xs)) (reduce + (map + xs xs))])
    );
    const out = try program.format(v);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[100000 5000050000 50000 50000 50000 100000 100000 9999900000]", out);
    try testing.expect(program.v.roots.capacity < 1024);
}

test "gc: a sequence native's result is the same at every length" {
    // Lengths across the chunk a result is rooted in before it moves
    // into the vector it is built in, under the stress policy.
    try expectOutputProgram(
        \\(defn check [n]
        \\  (let [xs (range n) ys (vec (range 1 (inc n)))]
        \\    (and (= xs (loop [i (dec n) acc ()] (if (neg? i) acc (recur (dec i) (cons i acc)))))
        \\         (= (count ys) n) (= (reduce + 0 ys) (quot (* n (inc n)) 2)) (= (map double xs) (range 0.0 n))
        \\         (= ys (map inc xs)) (= ys (mapv inc xs)) (= ys (map + xs (repeat n 1)))
        \\         (= (filter even? ys) (filterv even? ys) (remove odd? ys) (keep #(when (even? %) %) ys))
        \\         (= (map-indexed (fn [i x] [i x]) ys) (map vector xs ys))
        \\         (seq? (map inc xs)) (vector? (mapv inc xs)) (seq? (filter even? ys)) (vector? (filterv even? ys))
        \\         (= (count (filter even? ys)) (quot n 2))
        \\         (= (map (fn [x] [x]) xs) (map vector xs)))))
        \\(every? check (range 0 200))
    , "true");
    // A collection inside the callbacks while the result is part
    // rooted, part built.
    var program: Program = undefined;
    try program.initWith(.{ .gc_stress = true });
    defer program.deinit();
    const v = try program.run(
        \\(for [n [31 32 33 64 65 100 1100]]
        \\  (let [xs (range n) boxed (map (fn [x] [x (str x)]) xs) kept (filter (fn [p] (even? (count (conj p 1 2)))) boxed)]
        \\    [(= (map first boxed) xs) (= (map second boxed) (map str xs)) (= (count kept) n) (= (mapv (fn [[x]] (inc x)) kept) (map inc xs))]))
    );
    const out = try program.format(v);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("([true true true true] [true true true true] [true true true true] [true true true true] [true true true true] [true true true true] [true true true true])", out);
    try testing.expect(program.v.gc_cycles > 0);
}

test "db: a lazy seq is stored as the list it realizes to" {
    try expectOutputProgramWithStore("lazy-put",
        \\(def conn (db/open "@STORE@"))
        \\(def r (db/ref conn :t "k"))
        \\(with-tx [tx conn] (db/put! tx r (lazy-seq [1 2])))
        \\(db/put-key! (db/ref conn :t "j") {:a (lazy-seq [3])})
        \\(with-tx [tx conn] (db/alter! tx (db/ref conn :t "i") (fn [_] (lazy-seq (list 4)))))
        \\(def got [(with-read-tx [tx conn] (db/get tx r)) (db/get-key (db/ref conn :t "j")) (db/get-key (db/ref conn :t "i"))])
        \\(db/close conn)
        \\[got (map class got)]
    , "[[(1 2) {:a (3)} (4)] (:list :map :list)]");
}

test "db: read-line lets every held snapshot go before it waits" {
    var store = try SeamStore.init("read-line-held");
    defer store.deinit();
    const src = try store.source(
        \\(def c (nextomic/connect "@STORE@"))
        \\(nextomic/transact! c [{:db/ident :rl/n :db/valueType :db.type/long :db/cardinality :db.cardinality/one}])
        \\(nextomic/transact! c [{:rl/n 1}])
        \\(nextomic/q '[:find ?n . :where [_ :rl/n ?n]] (nextomic/db c))
    );
    defer testing.allocator.free(src);
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run(src);
    try testing.expect(nx.db.StoreFile.heldCount() > 0);
    _ = try program.run("(try (read-line) (catch any e e))");
    try testing.expectEqual(@as(usize, 0), nx.db.StoreFile.heldCount());
    _ = try program.run("(nextomic/release c)");
}

test "integration: *command-line-args* is nil without arguments; read-line needs the host's stdin" {
    try expectOutput("[*command-line-args* (try (read-line) (catch any e e))]", "[nil {:error :io-error, :message io error, :fn test-form}]");
}

test "integration: =, compare, hash, set membership and printing of data nested past the stack are :stack-overflow; flatten walks it" {
    // One chain of vectors 100k deep, built once: the test's 6 MiB
    // guard (stack.main_thread_budget) stops every walk of it well
    // before the bottom, in debug and optimized builds alike (an optimized
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
        \\   (flatten a)
        \\   (try (hash a) (catch :stack-overflow e :deep))
        \\   (try #{a b} (catch :stack-overflow e :deep))
        \\   (try (pr-str a) (catch :stack-overflow e :deep))])
    , "[:deep :deep () :deep :deep :deep]");
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

test "integration: a transient `!` call is a loop: a wrong operand changes nothing, a deep key stops it" {
    // TRANSIENT.md §6: the edits before a key that hashed or compared
    // past the stack guard stay, as Clojure's loop over the keys
    // keeps them; the edits after it do not run.
    try expectOutputOverDeepData(
        \\(let [a deep-a
        \\      s (transient (set (range 20)))
        \\      m (transient (zipmap (range 20) (range 20)))]
        \\  [(try (conj! s 20 a) (catch :stack-overflow e e))
        \\   (try (assoc! m :x 1 a 2 :z 3) (catch :stack-overflow e e))
        \\   (try (dissoc! m 0 a 1) (catch :stack-overflow e e))
        \\   (try (disj! s 0 a 1) (catch :stack-overflow e e))
        \\   (try (conj! m [:y 1] :not-an-entry) (catch any e e))
        \\   (try (conj! m [:y 1] [:w]) (catch any e e))
        \\   (count (persistent! s))
        \\   (let [p (persistent! m)] [(count p) (p :x) (p :y) (p :z) (p 0) (p 1)])])
    , "[{:error :stack-overflow, :message a value nests too deeply to compare, hash or print, :fn test-form} {:error :stack-overflow, :message a value nests too deeply to compare, hash or print, :fn test-form} {:error :stack-overflow, :message a value nests too deeply to compare, hash or print, :fn test-form} {:error :stack-overflow, :message a value nests too deeply to compare, hash or print, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :arity-mismatch, :message arity mismatch, :fn test-form} 20 [20 1 nil nil nil 1]]");
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
    // set of a set is that set, as Clojure's: a sorted one stays sorted.
    try expectOutput("[(sorted? (set (sorted-set 3 1))) (let [s #{1}] (identical? s (set s))) (= #{1 3} (set [3 1 3])) (= #{1 2} (hash-set 1 1 2)) (hash-map :a 1 :a 2) (= {:a 3 :b 2} (zipmap [:a :b :a] [1 2 3]))]", "[true true true true {:a 2} true]");
}

// =============================================================================
// Sorted collections (docs/SORTED.md)
// =============================================================================

test "sorted collections: construction, printing and the predicates" {
    try expectOutput("[(sorted-map :c 3 :a 1 :b 2) (sorted-set 3 1 2 1) (sorted-map) (sorted-set) (sorted-map-by > 1 :a 3 :c 2 :b) (sorted-set-by > 1 3 2)]", "[{:a 1, :b 2, :c 3} #{1 2 3} {} #{} {3 :c, 2 :b, 1 :a} #{3 2 1}]");
    try expectOutput("(pr-str (sorted-map \"b\" [2] \"a\" #{1}))", "{\"a\" #{1}, \"b\" [2]}");
    try expectOutput("[(sorted? (sorted-map)) (sorted? {}) (sorted? (sorted-set)) (sorted? []) (map? (sorted-map)) (set? (sorted-set)) (coll? (sorted-set)) (associative? (sorted-map)) (associative? (sorted-set)) (reversible? (sorted-map)) (reversible? []) (reversible? '(1)) (reversible? {}) (counted? (sorted-set)) (ifn? (sorted-map)) (sequential? (sorted-set)) (seqable? (sorted-map))]", "[true false true false true true true true false true true false false true true false true]");
    try expectOutput("(try (sorted-map 1) (catch :arity-mismatch e :odd))", ":odd");
}

test "sorted collections: every collection function reads and updates them in order" {
    try expectOutput("(let [m (sorted-map 3 :c 1 :a 2 :b)] [(assoc m 0 :z) (assoc m 4 :d 0 :z) (dissoc m 2) (dissoc m 1 3 9) (get m 1) (get m 9 :none) (contains? m 3) (contains? m 4) (find m 2) (find m 7) (count m) (empty? m) (empty? (sorted-map))])", "[{0 :z, 1 :a, 2 :b, 3 :c} {0 :z, 1 :a, 2 :b, 3 :c, 4 :d} {1 :a, 3 :c} {2 :b} :a :none true false [2 :b] nil 3 false true]");
    try expectOutput("(let [m (sorted-map 3 :c 1 :a 2 :b)] [(keys m) (vals m) (first m) (second m) (last m) (seq m) (rest m) (next m) (seq (sorted-map)) (keys (sorted-map)) (m 3) (m 9 :d) (:k (sorted-map :k 1)) (:q (sorted-map :k 1) :d)])", "[(1 2 3) (:a :b :c) [1 :a] [2 :b] [3 :c] ([1 :a] [2 :b] [3 :c]) ([2 :b] [3 :c]) ([2 :b] [3 :c]) nil nil :c :d 1 :d]");
    try expectOutput("(let [m (sorted-map 3 :c 1 :a)] [(conj m [2 :b]) (conj m {0 :z} [4 :d]) (conj m (sorted-map 9 :i)) (conj m nil) (into m {5 :e}) (into {} m) (empty m) (sorted? (empty m)) (merge m {0 :z}) (merge {0 :z} m) (update m 1 name) (assoc-in m [9 :x] 1) (select-keys m [3 7]) (zipmap (keys m) (vals m))])", "[{1 :a, 2 :b, 3 :c} {0 :z, 1 :a, 3 :c, 4 :d} {1 :a, 3 :c, 9 :i} {1 :a, 3 :c} {1 :a, 3 :c, 5 :e} {1 :a, 3 :c} {} true {0 :z, 1 :a, 3 :c} {0 :z, 1 :a, 3 :c} {1 a, 3 :c} {1 :a, 3 :c, 9 {:x 1}} {3 :c} {1 :a, 3 :c}]");
    try expectOutput("(let [s (sorted-set 5 1 3)] [(conj s 2) (conj s 0 9) (disj s 3) (disj s 1 5 7) (contains? s 5) (get s 1) (get s 2) (s 3) (s 4) (seq s) (into s [0 9]) (count s) (first s) (last s) (empty s) (set s) (vec s)])", "[#{1 2 3 5} #{0 1 3 5 9} #{1 5} #{3} true 1 nil 3 nil (1 3 5) #{0 1 3 5 9} 3 1 5 #{} #{1 3 5} [1 3 5]]");
    try expectOutput("(let [{:keys [a b]} (sorted-map :b 2 :a 1) [x y] (seq (sorted-set 9 8))] [a b x y (reduce + (sorted-set 1 2 3)) (reduce-kv (fn [acc k v] (conj acc k v)) [] (sorted-map 2 :b 1 :a)) (into [] (sorted-map 2 :b 1 :a)) (map inc (sorted-set 3 1)) (apply + (sorted-set 1 2)) (sort (sorted-set 3 1 2)) (frequencies (sorted-set 1 2)) (filter even? (sorted-set 4 1 2)) (update-vals (sorted-map 1 1) inc) (reverse (sorted-set 1 2 3)) `(~@(sorted-set 2 1))])", "[1 2 8 9 6 [1 :a 2 :b] [[1 :a] [2 :b]] (2 4) 3 (1 2 3) {1 1, 2 1} (2 4) {1 2} (3 2 1) (1 2)]");
    // A replaced value keeps the key object the map holds, as Clojure's.
    try expectOutput("(let [m (assoc (sorted-map 1 :a) 1.0 :b)] [m (count m) (key (first m))])", "[{1 :b} 1 1]");
}

test "sorted collections: = and hash agree with the hash collections, whatever the order" {
    try expectOutput("[(= (sorted-map 1 2 3 4) {3 4 1 2}) (= {3 4 1 2} (sorted-map 1 2 3 4)) (= (hash (sorted-map 1 2 3 4)) (hash {1 2 3 4})) (= (sorted-set 1 2) #{2 1}) (= (hash (sorted-set 1 2)) (hash #{1 2})) (= (sorted-map-by > 1 2 3 4) (sorted-map 3 4 1 2)) (= (sorted-map 1 2) (sorted-map 1 3)) (= (sorted-set 1) (sorted-map 1 1)) (= (sorted-set) #{}) (= (sorted-map) {}) (= (sorted-set) {}) (contains? #{(sorted-set 1 2)} #{1 2}) (get {(sorted-map :a 1) :found} {:a 1}) (= [(sorted-set 1)] [#{1}])]", "[true true true true true true false false true true false true :found true]");
}

test "sorted collections: a comparator orders them, coerced as Clojure coerces a function" {
    try expectOutput("[(sorted-set-by (fn [a b] (- b a)) 1 5 3) (sorted-set-by (comparator <) 3 1 2) (sorted-set-by < 3 1 2) (sorted-map-by compare :b 1 :a 2) (sorted-set-by (fn [a b] (compare (count a) (count b))) [1 2] [3 4] [5]) (sorted-set-by (fn [a b] 0.5) 1 2 3) (sorted-set-by (fn [a b] -0.5) 1 2) (sorted-set-by (fn [a b] (compare (:n a) (:n b))) {:n 2} {:n 1})]", "[#{5 3 1} #{1 2 3} #{1 2 3} {:a 2, :b 1} #{[5] [1 2]} #{1} #{1} #{{:n 1} {:n 2}}]");
    // A comparator keeps its order through every update and `empty`.
    try expectOutput("(let [s (sorted-set-by > 1 2)] [(conj s 3) (disj (conj s 0) 2) (into (empty s) [5 7 6]) (assoc (sorted-map-by > 1 :a) 2 :b)])", "[#{3 2 1} #{1 0} #{7 6 5} {2 :b, 1 :a}]");
}

test "sorted collections: an incomparable key, a bad comparator result and a comparator's throw are errors" {
    try expectOutput("[(try (sorted-map 1 :a :b 2) (catch :kind-mismatch e :km)) (try (assoc (sorted-map 1 2) \"x\" 3) (catch :kind-mismatch e :km)) (try (get (sorted-map 1 2) :k) (catch :kind-mismatch e :km)) (try (:k (sorted-map 1 2)) (catch :kind-mismatch e :km)) (try (contains? (sorted-set 1) \"s\") (catch :kind-mismatch e :km)) (try (sorted-set '(1) '(2)) (catch :kind-mismatch e :km)) (count (sorted-set '(1)))]", "[:km :km :km :km :km :km 1]");
    try expectOutput("[(try (sorted-set-by (fn [a b] :x) 1 2) (catch :kind-mismatch e :km)) (try (sorted-set-by (fn [a b] (throw :boom)) 1 2) (catch :boom e :caught)) (try (transient (sorted-map)) (catch :kind-mismatch e :km)) (try (nth (sorted-set 1) 0) (catch :kind-mismatch e :km)) (try (peek (sorted-set 1)) (catch :kind-mismatch e :km))]", "[:km :caught :km :km :km]");
}

test "sorted collections: subseq, rsubseq and rseq" {
    try expectOutput("(let [s (sorted-set 1 2 3 4 5 6)] [(subseq s > 3) (subseq s >= 3) (subseq s < 3) (subseq s <= 3) (subseq s > 2 < 5) (subseq s >= 2 <= 5) (subseq s > 3.5) (subseq s > 6) (subseq (sorted-set) < 1)])", "[(4 5 6) (3 4 5 6) (1 2) (1 2 3) (3 4) (2 3 4 5) (4 5 6) nil nil]");
    try expectOutput("(let [s (sorted-set 1 2 3 4 5 6)] [(rsubseq s < 3) (rsubseq s <= 3) (rsubseq s > 4) (rsubseq s >= 4) (rsubseq s > 1 < 5) (rsubseq s >= 1 <= 5) (rsubseq s < 1)])", "[(2 1) (3 2 1) (6 5) (6 5 4) (4 3 2) (5 4 3 2 1) nil]");
    try expectOutput("[(subseq (sorted-map 1 :a 2 :b 3 :c) >= 2) (rsubseq (sorted-map 1 :a 2 :b 3 :c) < 3) (subseq (sorted-set-by > 1 2 3 4) > 2) (subseq (sorted-set 1 2 3) (fn [c z] (= c z)) 2)]", "[([2 :b] [3 :c]) ([2 :b] [1 :a]) (1) nil]");
    try expectOutput("[(rseq (sorted-set 1 2 3)) (rseq (sorted-map 1 :a 2 :b)) (rseq (sorted-set)) (rseq [1 2 3]) (rseq []) (try (rseq '(1 2)) (catch :kind-mismatch e :km)) (try (subseq [1 2] > 1) (catch :kind-mismatch e :km))]", "[(3 2 1) ([2 :b] [1 :a]) nil (3 2 1) nil :km :km]");
}

test "sorted collections: metadata rides along, never into = or hash" {
    try expectOutput("(let [m (with-meta (sorted-map 1 2) {:x 1})] [(meta m) (meta (assoc m 3 4)) (meta (dissoc m 1)) (meta (empty m)) (sorted? m) (= m (sorted-map 1 2)) (= (hash m) (hash {1 2})) (meta (conj (with-meta (sorted-set 1) {:z 1}) 2)) (meta (disj (with-meta (sorted-set-by > 1) {:z 1}) 1)) (meta (sorted-map))])", "[{:x 1} {:x 1} {:x 1} {:x 1} true true true {:z 1} {:z 1} nil]");
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

test "lazy: lazy-seq runs its body once, when first walked, and caches what it returned" {
    try expectOutput("(let [n (atom 0) s (lazy-seq (swap! n inc) [1 2])] [(realized? s) (first s) (rest s) @n (realized? s) (seq (lazy-seq nil)) (lazy-seq nil) (= (lazy-seq nil) []) (= (lazy-seq nil) nil) (seq? s) (list? s) (class s)])", "[false 1 (2) 1 true nil () true false true false :lazy_seq]");
    try expectOutput("(let [n (atom 0) s (lazy-seq (swap! n inc) (cons 1 (lazy-seq (swap! n inc) nil)))] [(first s) @n (count s) @n (next s) (rest s) (nth s 0) (nth s 3 :d) (empty? s) (count (lazy-seq nil)) (empty? (lazy-seq nil))])", "[1 1 1 2 nil () 1 :d false 0 true]");
    try expectOutput("[(coll? (lazy-seq nil)) (sequential? (lazy-seq nil)) (counted? (lazy-seq nil)) (seqable? (lazy-seq nil)) (vector? (lazy-seq nil)) (instance? :lazy_seq (lazy-seq nil))]", "[true true false true false true]");
    // A body that throws is not run again: the next walk finds the
    // seq ended there, as babashka's (LAZY.md §4).
    try expectOutput("(let [n (atom 0) s (lazy-seq (swap! n inc) (throw :x))] [(try (seq s) (catch any e e)) (realized? s) (try (seq s) (catch any e e)) @n (realized? s)])", "[:x false nil 1 true]");
    // A body may refer to its own seq; one that forces it recurses
    // until the stack guard stops it.
    try expectOutput("(do (def s (lazy-seq (cons 1 s))) (take 3 s))", "(1 1 1)");
    try expectOutput("(do (def t (lazy-seq (seq t))) (try (seq t) (catch :stack-overflow e :deep)))", ":deep");
    try expectOutput("(do (def u (lazy-seq u)) [(seq u) (count u)])", "[nil 0]");
    // nth is a leaf; over a lazy seq it is re-issued as a full call.
    try expectOutput("(let [[a b & r] (lazy-seq [1 2 3 4])] [a b r])", "[1 2 (3 4)]");
    try expectOutput("(let [s (lazy-seq [:a :b])] [(nth s 1) (try (nth s 2) (catch any e e)) (nth s -1 :d) (map (fn [i] (nth s i :z)) [0 1 2])])", "[:b {:error :index-out-of-bounds, :message index out of bounds, :fn test-form} :d (:a :b :z)]");
}

test "lazy: a step that throws ends the seq at its block on the next walk" {
    // Expected values from babashka and JVM Clojure 1.12.6: each
    // function's step throws once, at its sixth call (the 42nd over a
    // chunk), and the second walk ends where the first stopped,
    // calling nothing.
    try expectOutput(
        \\(defn walk2 [s c] [(try (vec s) (catch any e :t)) @c (try (vec s) (catch any e :t)) @c])
        \\(defn once-at [c k] (fn [x] (swap! c inc) (if (and (= x k) (= @c (inc k))) (throw :boom) x)))
        \\[(let [c (atom 0)] (walk2 (map (once-at c 41) (vec (range 64))) c)) (let [c (atom 0)] (walk2 (map (once-at c 5) (apply list (range 8))) c)) (let [c (atom 0)] (walk2 (filter (once-at c 5) (apply list (range 8))) c)) (let [c (atom 0)] (walk2 (take-while (once-at c 5) (apply list (range 8))) c)) (let [c (atom 0)] (walk2 (take 8 (iterate (fn [x] (swap! c inc) (if (and (= x 5) (= @c 6)) (throw :boom) (inc x))) 0)) c)) (let [c (atom 0)] (walk2 (partition 2 (map (once-at c 5) (apply list (range 8)))) c)) (let [c (atom 0)] (walk2 (concat [:a] (map (once-at c 5) (apply list (range 8)))) c)) (let [c (atom 0)] (walk2 (distinct (map (once-at c 5) (apply list (range 8)))) c))]
    , "[[:t 42 [0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31] 42] [:t 6 [0 1 2 3 4] 6] [:t 6 [0 1 2 3 4] 6] [:t 6 [0 1 2 3 4] 6] [:t 6 [0 1 2 3 4 5] 6] [:t 6 [(0 1) (2 3)] 6] [:t 6 [:a 0 1 2 3 4] 6] [:t 6 [0 1 2 3 4] 6]]");
    // A lazy-seq body of the program's own: babashka's, and JVM
    // Clojure's when the body reads its captured seq first.
    try expectOutput("(let [c (atom 0) s ((fn step [i] (lazy-seq (when (and (= i 3) (= (swap! c inc) 1)) (throw :boom)) (when (< i 6) (cons i (step (inc i)))))) 0)] [(try (vec s) (catch any e e)) (vec s) @c])", "[:boom [0 1 2] 1]");
}

test "leaf natives: what a leaf body refuses goes the general way from every call site" {
    // An instruction, `apply` (callValue) and `mapv` (a Callback) each
    // call the leaf, and re-issue what it refuses (VM.md §6).
    try expectOutput("(let [s (sorted-map-by > 1 :a 2 :b) m {[1] :v \"k\" :w} k [1]] [(get s 2) (get m k) (get m \"k\") (get m [2] :d) (get #{\"s\"} \"s\") (apply get [s 1]) (apply get [m k]) (mapv get [s m m {:x 1}] [1 k \"k\" :x])])", "[:b :v :w :d s :a :v [:a :v :w 1]]");
    try expectOutput("(let [s (map inc [1 2 3])] [(count s) (count (lazy-seq nil)) (apply count [s]) (mapv count [s [1] \"ab\" nil {:a 1}])])", "[3 0 3 [3 1 2 0 1]]");
    try expectOutput("(let [s (map inc [1 2 3])] [(nthnext s 1) (nthnext [1 2 3] 2) (nthnext [1] 1) (nthnext (list 1 2) 1) (apply nthnext [s 2]) (mapv nthnext [s #{1} \"ab\" {:a 1}] [2 0 1 0])])", "[(3 4) (3) nil (2) (4) [(4) (1) (b) ([:a 1])]]");
    // Each return of `count`, `nth` and `nthnext`, which store their
    // result where the caller reads it (VM.md §8), from a leaf call and
    // the general ones.
    try expectOutput("[(nthnext nil 1) (nthnext () 0) (nthnext [] 0) (nthnext [1 2] 0) (nthnext [1 2] 5) (nthnext (list 1 2) 0) (nthnext nil -1) (try (nthnext [1] :a) (catch any e (:error e))) (apply nthnext [nil 1]) (mapv nthnext [[] (list) [1 2 3] (list 1 2 3) nil] [0 1 1 2 0])]", "[nil nil nil (1 2) nil (1 2) nil :kind-mismatch nil [nil nil (2 3) (3) nil]]");
    try expectOutput("[(nth [1 2] 2 :d) (nth [1 2] -1 :d) (nth nil 0) (nth nil -1 :d) (nth (list 1 2) 1) (nth (list 1 2) 5 :d) (nth \"ab\" 1) (nth \"ab\" 2 :d) (nth (i64-vector [1 2]) 1) (nth (i64-vector [1]) 3 :d) (nth (transient [1 2]) 1) (nth (transient [1]) 4 :d) (try (nth [1] 1) (catch any e (:error e))) (try (nth nil -1) (catch any e (:error e))) (try (nth 5 0 :d) (catch any e (:error e))) (mapv nth [[1 2] \"ab\" nil (list 1)] [0 1 0 3] [:a :b :c :d])]", "[:d :d nil :d 2 :d b :d 2 :d 2 :d :index-out-of-bounds :index-out-of-bounds :kind-mismatch [1 b :c :d]]");
    try expectOutput("[(count \"h\u{e9}llo\") (count (transient [1 2 3])) (count (sorted-map 1 2)) (count (i64-vector [1 2])) (try (count 5) (catch any e (:error e))) (mapv count [[1] nil \"ab\" (range 3) (transient [1])])]", "[5 3 1 2 :kind-mismatch [1 0 2 3 1]]");
    try expectOutput("[(conj [1] 2) (conj nil 1) (conj (list 1) 0) (conj #{} [1]) (conj {} [:a 1]) (conj (map inc [1]) 0) (apply conj [#{} 1]) (mapv conj [[] #{} {} (sorted-set)] [1 [2] [:k 3] 4]) (reduce conj [] (range 3)) (reduce conj #{} [1 1 2])]", "[[1 2] (1) (0 1) #{[1]} {:a 1} (0 2) #{1} [[1] #{[2]} {:k 3} #{4}] [0 1 2] #{1 2}]");
    try expectOutput("(do (defrecord P [x]) [(assoc {} :a 1) (assoc nil 1 2 3 4) (assoc [1 2] 2 3) (assoc {} [1] :v \"k\" :w) (:x (assoc (->P 1) :x 2)) (assoc (sorted-map 2 :b) 1 :a) (try (assoc [1] 5 :x) (catch any e e)) (apply assoc [{} [2] 3]) (mapv assoc [{} (sorted-map) [0]] [:a 1 0] [1 2 3])])", "[{:a 1} {1 2, 3 4} [1 2 3] {[1] :v, k :w} 2 {1 :a, 2 :b} {:error :index-out-of-bounds, :message index out of bounds, :fn test-form} {[2] 3} [{:a 1} {1 2} [3]]]");
    try expectOutput("(let [t (transient {}) v (transient [])] (assoc! t :a 1 [1] 2) (assoc! v 0 :x) (apply assoc! [t \"k\" 3]) (mapv assoc! [t v] [:b 1] [4 :y]) [(persistent! t) (persistent! v) (try (assoc! (transient #{}) 1 1) (catch any e e)) (try (assoc! t :c 1) (catch any e e))])", "[{:a 1, [1] 2, k 3, :b 4} [:x :y] {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :transient-used-after-persistent, :message transient used after persistent!, :fn test-form}]");
    try expectOutput("(pr-str [(str) (str nil 1 \\c \"s\") (str [1 (map inc [1])] :k 1.5) (apply str [1 :a]) (mapv str [1 nil (list 2) :k])])", "[\"\" \"1cs\" \"[1 (2)]:k1.5\" \"1:a\" [\"1\" \"\" \"(2)\" \":k\"]]");
}

test "lazy: =, hash, a map's key and printing realize a lazy seq nested anywhere" {
    try expectOutput("[(get {(lazy-seq [1 2]) :a} [1 2]) (contains? #{[1 2]} (lazy-seq [1 2])) (= {:k (lazy-seq [1])} {:k [1]}) (pr-str [(lazy-seq [1])]) (= (hash (lazy-seq [2 3])) (hash [2 3])) (= (hash [(lazy-seq [2 3])]) (hash [[2 3]])) (str (lazy-seq [1 2]))]", "[:a true true [(1)] true true (1 2)]");
    // A nested body's throw surfaces from the native or opcode that
    // compared or hashed; the first of two wins.
    try expectOutput("(try (= [(lazy-seq (throw :x))] [[1]]) (catch any e e))", ":x");
    try expectOutput("(try #{(lazy-seq (throw :y)) []} (catch any e e))", ":y");
    try expectOutput("(try {[] 1 (lazy-seq (throw :z)) 2} (catch any e e))", ":z");
    try expectOutput("(try (hash [(lazy-seq (throw :a)) (lazy-seq (throw :b))]) (catch any e e))", ":a");
    try expectOutput("[(try (hash [(lazy-seq (throw :a))]) (catch any e e)) (= [(lazy-seq [1])] [[1]]) (contains? #{[1]} (lazy-seq [1]))]", "[:a true true]");
    // A lazy key is realized when a map or set takes it, an array form's
    // included, and its throw surfaces from the call that inserted it.
    try expectOutput("(let [a (lazy-seq [1]) b (lazy-seq [2]) c (lazy-seq [3]) d (lazy-seq [4]) e (lazy-seq [5]) f (lazy-seq [6])] (into #{} [a]) (conj #{} b) (assoc {} c 1) (frequencies [d]) (group-by identity [e]) (assoc {:k 1} f 2) (mapv realized? [a b c d e f]))", "[true true true true true true]");
    try expectOutput("[(try (count (into #{} [(lazy-seq (throw :in))])) (catch any e e)) (try (frequencies [(lazy-seq (throw :fq))]) (catch any e e)) (try (group-by identity [(lazy-seq (throw :gb))]) (catch any e e)) (try (conj #{} (lazy-seq (throw :cj))) (catch any e e)) (try (reduce conj #{} [(lazy-seq (throw :rc))]) (catch any e e)) (try (assoc {} [(lazy-seq (throw :nested))] 1) (catch any e e)) (try (into {} [[(lazy-seq (throw :im)) 1]]) (catch any e e)) (try (zipmap [(lazy-seq (throw :z))] [1]) (catch any e e))]", "[:in :fq :gb :cj :rc :nested :im :z]");
    // A native that parked a body's throw and then fails for another
    // reason drops it: nothing later raises it. One that keeps going
    // keeps it across a failing call it makes, and raises it at its end.
    try expectOutput("(let [r (try (group-by (fn [x] (cond (= x 3) (throw :other) (= x 2) (lazy-seq (throw :x)) :else [1])) [1 2 3]) (catch any e [:caught e]))] [r (try (= [(lazy-seq [1])] [[1]]) (catch any e [:later e])) (try (hash [(lazy-seq (throw :y))]) (catch any e e))])", "[[:caught :other] true :y]");
    try expectOutput("(try (group-by (fn [x] (cond (= x 3) (do (try (reduce + [:a]) (catch any e nil)) [3]) (= x 2) (lazy-seq (throw :x)) :else [1])) [1 2 3]) (catch any e [:caught e]))", "[:caught :x]");
    // = walks in step: an infinite seq against a finite one ends.
    try expectOutput("(do (defn nat [n] (lazy-seq (cons n (nat (inc n))))) [(= (nat 0) [0 1]) (= [0 1] (nat 0)) (= [(nat 0)] [[0 1]]) (not= (nat 0) '(0))])", "[false false false true]");
    // An in-place edit of a transient realizes its key first, so the
    // body's own edit of the transient is complete before it starts.
    try expectOutput("(let [t (transient {})] (assoc! t (lazy-seq (assoc! t :x 1) [1]) 2) (persistent! t))", "{:x 1, (1) 2}");
    try expectOutput("(let [t (transient #{})] (persistent! (conj! t (lazy-seq [1]) [1] (lazy-seq [2]))))", "#{(1) (2)}");
}

test "lazy: a macro's result, eval's form and an unquote-splice may be lazy" {
    try expectOutput("(do (defmacro m [] (lazy-seq (list '+ 1 2))) (m))", "3");
    try expectOutput("(do (defmacro m2 [] (list 'quote (lazy-seq [1 (lazy-seq [2])]))) [(m2) (class (m2)) (class (second (m2)))])", "[(1 (2)) :list :list]");
    try expectOutput("(eval (lazy-seq (list '+ 1 2)))", "3");
    // A sorted collection holding one is rebuilt in its order.
    try expectOutput("(do (defmacro m4 [] (sorted-map 1 (map identity '(+ 1 2)))) [(m4) (class (m4))])", "[{1 3} :sorted_map]");
    try expectOutput("[(eval (sorted-map 1 (list 'quote (map inc [1 2])))) (eval (list 'quote (sorted-map :a (sorted-map :b (map inc [1]))))) (class (eval (sorted-map 2 (list 'quote (map inc [1])) 1 0)))]", "[{1 (2 3)} {:a {:b (2)}} :sorted_map]");

    try expectOutput("(let [xs (lazy-seq [1 2])] `(a ~@xs))", "(user/a 1 2)");
    try expectOutput("(let [n (atom 0) xs (lazy-seq (swap! n inc) [1 2])] [`(~@xs ~@xs) @n])", "[(1 2 1 2) 1]");
    try expectOutput("(try (let [xs (lazy-seq (throw :splice))] `(a ~@xs)) (catch any e e))", ":splice");
}

test "lazy: range is lazy, 32 at a time, infinite without an end, and counts, reduces, indexes and drops without realizing" {
    try expectOutput("[(realized? (range 10)) (take 3 (range)) (take 3 (range 0 10 0)) (range 3 3 0) (count (range 1000000000000)) (reduce + (range 1000000)) (nth (range 10 100) 5) (drop 3 (range 6))]", "[false (0 1 2) (0 0 0) () 1000000000000 499999500000 15 (3 4 5)]");
    try expectOutput("[(range 0) (class (range 0)) (seq (range 5 5)) (range 5 0 -2) (count (range 0 10 3)) (count (range 10 0 -3)) (nth (range 5) 7 :x) (try (nth (range 5) 7) (catch any e e)) (vec (range 3)) (into #{} (range 3)) (range 0 1 0.25) (range 3.0) (take 2 (range 1.5 1.5 0))]", "[() :list nil (5 3 1) 4 4 :x {:error :index-out-of-bounds, :message index out of bounds, :fn test-form} [0 1 2] #{0 1 2} (0 0.25 0.5 0.75) (0 1 2) ()]");
    try expectOutput("[(reduce (fn [a x] (if (> x 10) (reduced a) (+ a x))) (range)) (reduce (fn [a x] (if (> a 10) (reduced a) (+ a x))) (range 1 2 0)) (reduce + 100 (range 3)) (reduce + (range 1 2)) (reduce (fn [a x] (if (= x 2) (reduced [a x]) x)) 0 (range 2 10 0))]", "[55 11 103 1 [0 2]]");
    // A realized range is walked, not recomputed; the first chunk is
    // 32 elements, the last what is left.
    try expectOutput("(let [r (range 70) s (seq r)] [(realized? r) (count (seq r)) (first (drop 64 r)) (last r) (= r (vec (range 70))) (= (hash r) (hash (vec (range 70))))])", "[true 70 64 69 true true]");
    try expectOutput("(take 2 (drop 140737488355326 (range 140737488355320 140737488355330)))", "()");
    // A native that walks an unrealized range computes its elements, as
    // Clojure's `LongRange` iterator does; `doall` realizes it.
    try expectOutput("(let [r (range 100)] [(count (mapv inc r)) (count (filterv odd? r)) (count (frequencies r)) (count (group-by odd? r)) (apply + r) (realized? r) (do (doall r) (realized? r))])", "[100 50 100 2 4950 false true]");
}

test "lazy: a count is any number, a fraction rounding up as Clojure's counts one down; repeat's is truncated" {
    // Expected values from babashka, which agrees with JVM Clojure 1.12 here.
    try expectOutput("[(take 2.5 (range 10)) (drop 1.5 (range 5)) (nthrest (range 5) 1.5) (nthrest [1 2 3] 1.5) (nthrest (list 1 2 3) 1.5) (nthrest (list 1 2 3) -0.5) (nthnext [1 2 3] 1.5) (repeat 2.9 :x) (repeat -2.5 :x) (repeat ##NaN :x) (try (repeat ##Inf :x) (catch any e e)) (take ##Inf [1 2]) (take ##NaN [1 2]) (drop ##NaN [1 2]) (drop ##Inf (list 1 2)) (take-last 1.5 [1 2 3]) (repeatedly 1.5 (constantly 0)) (split-at 1.5 [1 2 3]) (into [] (take 2.5) (range 10)) (into [] (drop 1.5) (range 4))]", "[(0 1 2) (2 3 4) (2 3 4) (3) (3) (1 2 3) (3) (:x :x) () () {:error :invalid-argument, :message invalid argument, :fn test-form} (1 2) () (1 2) () (2 3) (0 0) [(1 2) (3)] [0 1 2] [2 3]]");
    try expectOutput("[(try (take :a [1]) (catch any e e)) (try (repeat \"2\" 1) (catch any e e))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "lazy: map, filter, remove, keep, map-indexed and keep-indexed are lazy, 32 at a time over a chunked source" {
    // Expected values from babashka, which agrees with JVM Clojure 1.12 here.
    try expectOutput("(let [n (atom 0)] (first (map (fn [x] (swap! n inc) x) (range 100))) @n)", "32");
    try expectOutput("(let [n (atom 0)] (first (map (fn [x] (swap! n inc) x) (apply list (range 100)))) @n)", "1");
    try expectOutput("(let [n (atom 0)] (first (map (fn [x y] (swap! n inc) x) (range 100) (range 100))) @n)", "1");
    try expectOutput("(let [n (atom 0)] (first (filter (fn [x] (swap! n inc) (> x 40)) (range 100))) @n)", "64");
    try expectOutput("(let [n (atom 0)] (first (map-indexed (fn [i x] (swap! n inc) x) (vec (range 50)))) @n)", "32");
    try expectOutput("[(list? (map inc [1])) (seq? (map inc [1])) (class (filter odd? [1])) (realized? (map inc [1])) (let [s (map inc [1])] (first s) (realized? s))]", "[false true :lazy_seq false true]");
    try expectOutput("[(take 3 (map inc (range))) (first (filter #(> % 1000) (range))) (take 2 (keep #(when (odd? %) %) (range))) (take 2 (remove even? (range))) (take 3 (map-indexed vector (range 10 20))) (take 2 (keep-indexed #(when (odd? %1) %2) (range 10 20)))]", "[(1 2 3) 1001 (1 3) (1 3) ([0 10] [1 11] [2 12]) (11 13)]");
    try expectOutput("[(map + [1 2] [10 20 30]) (map str \"ab\" [1 2]) (map vector {:a 1} [2]) (map inc #{1}) (map inc nil) (filter odd? nil) (map list [1 2] (range))]", "[(11 22) (a1 b2) ([[:a 1] 2]) (2) () () ((1 0) (2 1))]");
    // A filter skipping a long run of an unchunked source forwards
    // from block to block in one loop: no native stack.
    try expectOutput("(first (filter #(> % 100000) (range)))", "100001");
    // A function's throw surfaces where the seq is walked.
    try expectOutput("(let [s (map (fn [x] (throw :m)) [1])] [(realized? s) (try (doall s) (catch any e e)) (realized? s)])", "[false :m false]");
}

test "gc: a realized map block lets its source go; an abandoned one keeps it until dropped" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const heap = program.v.ensureHeap();
    _ = try program.run("(def v (vec (range 100000)))");
    program.v.collectGarbage();
    _ = try program.run("(def m (doall (map inc v)))");
    program.v.collectGarbage();
    const with_source = heap.liveCount();
    _ = try program.run("(def v nil)");
    program.v.collectGarbage();
    // The vector's leaves and nodes: nothing of the realized map holds them.
    try testing.expect(with_source - heap.liveCount() > 3000);
    _ = try program.run("(def v (vec (range 100000))) (def h (map inc v)) (first h) (def v nil)");
    program.v.collectGarbage();
    const held = heap.liveCount();
    _ = try program.run("(def h nil)");
    program.v.collectGarbage();
    try testing.expect(held - heap.liveCount() > 3000);
}

test "gc: a native's call block holds nothing of its arguments once the call returns" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
    program.v.collectGarbage();
    const heap = &program.v.heap.?;
    heap.peak_live_bytes = heap.live_bytes;
    const start = heap.live_bytes;
    // The inner `map` and `filter` are each an argument of the call
    // outside them, which has returned before `reduce` walks: about
    // 4 MB and 2 MB realized, kept by the blocks while they stand.
    try harness.expectResult(&program, "", try program.run("(reduce + (map inc (filter even? (map inc (range 200000)))))"), "10000200000");
    try testing.expect(heap.peak_live_bytes -| start < 3 << 20);
}

test "gc: a native that consumes its sequence lets the part it walked go" {
    // Each realizes 300,000 mapped elements, about 6 MB of chunks, that
    // the argument's slot would keep while the native walks them.
    for ([_][2][]const u8{
        .{ "(reduce + (map inc (range 300000)))", "45000150000" },
        .{ "(reduce + 0 (map inc (range 300000)))", "45000150000" },
        .{ "(dorun (map inc (range 300000)))", "nil" },
        .{ "(dorun 300000 (map inc (range 300000)))", "nil" },
        .{ "(last (map inc (range 300000)))", "300000" },
        .{ "(some neg? (map inc (range 300000)))", "nil" },
        .{ "(every? pos? (map inc (range 300000)))", "true" },
        .{ "(count (frequencies (map #(mod % 10) (range 300000))))", "10" },
        .{ "(count (group-by odd? (map #(mod % 10) (range 300000))))", "2" },
    }) |case| {
        errdefer std.debug.print("consuming case {s}\n", .{case[0]});
        var program: Program = undefined;
        try program.init();
        defer program.deinit();
        program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
        program.v.collectGarbage();
        const heap = &program.v.heap.?;
        heap.peak_live_bytes = heap.live_bytes;
        const start = heap.live_bytes;
        try harness.expectResult(&program, "", try program.run(case[0]), case[1]);
        // `group-by` keeps every element in its groups: 300,000 values.
        const bound: usize = if (std.mem.startsWith(u8, case[0], "(count (group-by")) 8 << 20 else 1 << 20;
        try testing.expect(heap.peak_live_bytes -| start < bound);
    }
}

test "gc: count, into, vec, take-last and the typed vectors consume the seq they walk" {
    // Each walks 300,000 mapped elements, about 6 MB of chunks, that the
    // local's slot, moved into the call's block, would keep through the
    // walk. A vector of every element is about 5 MB of its own.
    for ([_][3][]const u8{
        .{ "(let [s (map inc (range 300000))] (count s))", "300000", "1" },
        .{ "(count (map inc (range 300000)))", "300000", "1" },
        .{ "(defn n [xs] (count xs)) (n (map inc (range 300000)))", "300000", "1" },
        .{ "(let [s (map #(mod % 10) (range 300000))] (count (into #{} s)))", "10", "1" },
        .{ "(let [s (map #(mod % 10) (range 300000))] (count (into {} (map (fn [x] [x x])) s)))", "10", "1" },
        .{ "(let [s (map #(mod % 10) (range 300000))] (count (into (sorted-set) s)))", "10", "1" },
        .{ "(let [s (map inc (range 300000))] (count (into #{} (map #(mod % 10)) s)))", "10", "1" },
        .{ "(let [s (map inc (range 300000))] (count (vec s)))", "300000", "6" },
        .{ "(let [s (map inc (range 300000))] (count (into [] s)))", "300000", "6" },
        .{ "(let [s (map inc (range 300000))] (count (into [0] s)))", "300001", "6" },
        .{ "(let [s (map inc (range 300000))] (count (into [] (map inc) s)))", "300000", "6" },
        .{ "(let [s (map inc (range 300000))] (take-last 2 s))", "(299999 300000)", "1" },
        .{ "(let [s (map inc (range 300000))] (count (i64-vector s)))", "300000", "3" },
        .{ "(let [s (map inc (range 300000))] (count (f64-vector s)))", "300000", "3" },
    }) |case| {
        errdefer std.debug.print("consuming case {s}\n", .{case[0]});
        var program: Program = undefined;
        try program.init();
        defer program.deinit();
        program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
        program.v.collectGarbage();
        const heap = &program.v.heap.?;
        heap.peak_live_bytes = heap.live_bytes;
        const start = heap.live_bytes;
        try harness.expectResult(&program, "", try program.run(case[0]), case[1]);
        const mb = try std.fmt.parseInt(usize, case[2], 10);
        errdefer std.debug.print("peak {d} bytes\n", .{heap.peak_live_bytes -| start});
        try testing.expect(heap.peak_live_bytes -| start < mb << 20);
    }
}

test "gc: reverse, butlast, mapv, filterv, apply, select-keys and nexis.string/join consume the seq they walk" {
    // Each walks 300,000 mapped elements, about 6 MB of chunks (and
    // 300,000 strings beside them for `join`), that the local's slot,
    // moved into the call's block, would keep through the walk. A
    // vector or a list of every element is about 5 MB of its own, and
    // so is what `apply` keeps of the elements to pass on.
    for ([_][3][]const u8{
        .{ "(let [s (map inc (range 300000))] (first (reverse s)))", "300000", "6" },
        .{ "(defn r [xs] (reverse xs)) (first (r (map inc (range 300000))))", "300000", "6" },
        .{ "(let [s (map inc (range 300000))] (count (butlast s)))", "299999", "6" },
        .{ "(let [s (map inc (range 300000))] (count (mapv inc s)))", "300000", "6" },
        .{ "(let [s (map inc (range 300000))] (count (mapv + (range 300000) s)))", "300000", "6" },
        .{ "(let [s (map inc (range 300000))] (count (filterv even? s)))", "150000", "3" },
        .{ "(let [s (map inc (range 300000))] (apply max s))", "300000", "5" },
        .{ "(let [s (map inc (range 300000))] (select-keys {1 :a 300000 :b} s))", "{1 :a, 300000 :b}", "1" },
        .{ "(let [s (map str (range 300000))] (count (nexis.string/join \",\" s)))", "1988889", "3" },
        .{ "(let [s (map inc (range 300000))] (count (nexis.string/join s)))", "1688895", "3" },
    }) |case| {
        errdefer std.debug.print("consuming case {s}\n", .{case[0]});
        var program: Program = undefined;
        try program.init();
        defer program.deinit();
        program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
        program.v.collectGarbage();
        const heap = &program.v.heap.?;
        heap.peak_live_bytes = heap.live_bytes;
        const start = heap.live_bytes;
        try harness.expectResult(&program, "", try program.run(case[0]), case[1]);
        const mb = try std.fmt.parseInt(usize, case[2], 10);
        errdefer std.debug.print("peak {d} bytes\n", .{heap.peak_live_bytes -| start});
        try testing.expect(heap.peak_live_bytes -| start < mb << 20);
    }
}

test "count, into, vec, take-last and the typed vectors give what they gave before consuming their seq" {
    // Expected values from babashka, a set printed in nexis's order.
    try expectOutput("(let [s (map inc (range 5)) t s] [(count s) (vec s) (into [] s) (set s) (into () t) (reduce + t) (first s)])", "[5 [1 2 3 4 5] [1 2 3 4 5] #{1 2 3 4 5} (5 4 3 2 1) 15 1]");
    try expectOutput("(let [s (map inc (range 3))] [(count s) (count s) (vec s) (into [0] s) (into [] (map inc) s) s])", "[3 3 [1 2 3] [0 1 2 3] [2 3 4] (1 2 3)]");
    try expectOutput("(let [v (with-meta [9] {:m 1}) e (with-meta [] {:m 2})] [(into v (map inc (range 3))) (meta (into v (map inc (range 3)))) (meta (into e (map inc (range 3)))) (meta (into e (map inc) (range 3)))])", "[[9 1 2 3] {:m 1} {:m 2} {:m 2}]");
    try expectOutput("[(into nil (map inc (range 3))) (into () (map inc (range 3))) (into {:a 1} (map vector [:b :c] (range 2))) (into (sorted-map) (map vector [:b :a] (range 2))) (into (sorted-set-by >) (map inc (range 4))) (into #{} (map inc (range 3))) (seq (into (lazy-seq [9]) (map inc (range 2))))]", "[(3 2 1) (3 2 1) {:a 1, :b 0, :c 1} {:a 1, :b 0} #{4 3 2 1} #{1 2 3} (2 1 9)]");
    try expectOutput("[(vec (map inc ())) (into [] (map inc ())) (count (map inc ())) (set (map inc ())) (into [] (take 3) (iterate inc 0)) (vec (take 4 (iterate inc 0))) (count (take 5 (cycle [1 2])))]", "[[] [] 0 #{} [0 1 2] [0 1 2 3] 5]");
    try expectOutput("[(take-last 2 (map inc (range 5))) (take-last 0 (map inc (range 5))) (take-last 10 (map inc (range 3))) (take-last 3 (map inc ())) (take-last 3 (map inc (range 7))) (take-last 2.5 (map inc (range 7)))]", "[(4 5) nil (1 2 3) nil (5 6 7) (5 6 7)]");
    try expectOutput("[(vec (i64-vector (map inc (range 3)))) (vec (f64-vector (map inc (range 3)))) (try (i64-vector (map identity [1 :a])) (catch :kind-mismatch e :km))]", "[[1 2 3] [1.0 2.0 3.0] :km]");
}

test "vec of a list that views a whole vector is that vector" {
    // `sort`, `reverse` and the seq of a vector make such a list; its
    // `vec` builds nothing.
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(def s (reverse (range 300000)))");
    program.v.collectGarbage();
    const heap = &program.v.heap.?;
    heap.peak_live_bytes = heap.live_bytes;
    const start = heap.live_bytes;
    try harness.expectResult(&program, "", try program.run("(let [v (vec s)] [(count v) (v 0) (v 299999)])"), "[300000 299999 0]");
    errdefer std.debug.print("peak {d} bytes\n", .{heap.peak_live_bytes -| start});
    try testing.expect(heap.peak_live_bytes -| start < 64 << 10);
    // Expected values from babashka, which carries no metadata through
    // `seq` of a vector: neither does `vec`.
    try expectOutput("(let [v (with-meta [5 6 7 8] {:m 1})] [(vec (seq v)) (meta (vec (seq v))) (vec (rest (seq v))) (vec (sort [3 1 2 5 4])) (vec (reverse [1 2 3 4 5])) (meta (vec (with-meta (seq [1 2 3 4]) {:k 2}))) (vec (seq [1 2])) (= (vec (sort (range 100 0 -1))) (range 1 101))])", "[[5 6 7 8] nil [6 7 8] [1 2 3 4 5] [5 4 3 2 1] nil [1 2] true]");
}

test "reverse, butlast, mapv, filterv, apply, select-keys and nexis.string/join give what they gave before consuming their seq" {
    // Expected values from babashka (clojure.string/join), but for the
    // text of a lazy seq (LAZY.md §9).
    try expectOutput("(let [s (map inc (range 5)) t s] [(reverse s) (butlast s) (mapv inc s) (filterv odd? s) (select-keys {1 :a 3 :b 9 :c} s) (nexis.string/join \",\" s) (reduce + t) (first s) (vec t)])", "[(5 4 3 2 1) (1 2 3 4) [2 3 4 5 6] [1 3 5] {1 :a, 3 :b} 1,2,3,4,5 15 1 [1 2 3 4 5]]");
    try expectOutput("[(reverse (map inc ())) (butlast (map inc ())) (butlast (map inc (range 1))) (butlast (map inc (range 2))) (mapv + (map inc (range 3)) (map inc (range 5))) (filterv odd? (map inc ())) (select-keys {} (map inc (range 3))) (nexis.string/join (map inc ())) (nexis.string/join \"-\" (map identity [nil \"a\" \\b 1 :k [1] (map inc [1 2])]))]", "[() nil nil (1) [2 4 6] [] {}  -a-b-1-:k-[1]-(2 3)]");
    // Either side of a vector leaf's 32, an even and an odd count.
    try expectOutput("(vec (for [n [32 33 34 64 65 70]] (let [s (map inc (range n))] [(= (reverse s) (range n 0 -1)) (= (butlast s) (range 1 n)) (= (mapv inc s) (range 2 (+ n 2))) (= (filterv even? s) (range 2 (inc n) 2))])))", "[[true true true true] [true true true true] [true true true true] [true true true true] [true true true true] [true true true true]]");
    try expectOutput("[(reverse [1 2 3]) (reverse (range 40 0 -1)) (butlast (range 5)) (reverse \"abc\") (butlast \"abcd\") (reverse {:a 1}) (butlast {:a 1 :b 2}) (reverse nil) (butlast nil) (reverse (sorted-set 3 1 2)) (mapv vector {:a 1} (map inc (range 3))) (select-keys [:a :b :c] (map inc (range 3))) (select-keys (sorted-map 1 2 3 4) (map identity [3 5])) (nexis.string/join \",\" (range 3)) (nexis.string/join \",\" [1 2]) (nexis.string/join \", \" (map str (range 3)))]", "[(3 2 1) (1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40) (0 1 2 3) (c b a) (a b c) ([:a 1]) ([:a 1]) () nil (3 2 1) [[[:a 1] 1]] {1 :b, 2 :c} {3 4} 0,1,2 1,2 0, 1, 2]");
    try expectOutput("(let [s (map inc (range 5)) t s] [(apply + 10 s) (apply vector :a s) (zipmap [:a :b :c] s) (zipmap (map inc (range 3)) s) (vec t)])", "[25 [:a 1 2 3 4 5] {:a 1, :b 2, :c 3} {1 1, 2 2, 3 3} [1 2 3 4 5]]");
    try expectOutput("[(apply + (map inc ())) (apply list (map inc (range 3))) (zipmap [:a :b] (range)) (zipmap [:a :b] (repeat 7)) (zipmap {:x 1 :y 2} (map inc (range 5))) (zipmap (map inc (range 3)) {:x 1}) (zipmap [] (range)) (zipmap (sorted-map 1 2) \"ab\") (apply str (map inc (range 40)))]", "[0 (1 2 3) {:a 0, :b 1} {:a 7, :b 7} {[:x 1] 1, [:y 2] 2} {1 [:x 1]} {} {[1 2] a} 12345678910111213141516171819202122232425262728293031323334353637383940]");
    try expectOutput("(let [s (map inc (range 70))] [(= (apply vector s) (vec (range 1 71))) (= (zipmap (range 70) s) (zipmap (range 70) (range 1 71)))])", "[true true]");
}

test "gc: a seq a local or a parameter holds is let go at its last move (COMPILER.md §4.9)" {
    // Each walks 300,000 mapped elements, about 6 MB of chunks, that
    // the local's or the parameter's slot would keep through the walk.
    for ([_][3][]const u8{
        .{ "", "(let [s (map inc (range 300000))] (reduce + s))", "45000150000" },
        .{ "(defn total [xs] (reduce + xs))", "(total (map inc (range 300000)))", "45000150000" },
        .{ "", "(let [[x & r] (map inc (range 300000))] (reduce + x r))", "45000150000" },
        .{ "", "(run! (fn [_] nil) (map inc (range 300000)))", "nil" },
        .{ "", "(transduce (map inc) + (map inc (range 300000)))", "45000450000" },
        .{ "(defn p [xs] (doseq [x xs] nil))", "(p (map inc (range 300000)))", "nil" },
        .{ "", "(let [s (map inc (range 300000))] (if (seq s) (reduce + s) 0))", "45000150000" },
        .{ "", "(let [s (map inc (range 300000))] (first s) (reduce + s))", "45000150000" },
        .{ "", "(loop [i 0 acc 0] (if (< i 2) (recur (inc i) (+ acc (let [s (map inc (range 300000))] (reduce + s)))) acc))", "90000300000" },
    }) |case| {
        errdefer std.debug.print("clearing case {s}\n", .{case[1]});
        var program: Program = undefined;
        try program.init();
        defer program.deinit();
        if (case[0].len > 0) _ = try program.run(case[0]);
        program.v.setGcPolicy(.{ .threshold = 1 << 16, .growth_percent = 0 });
        program.v.collectGarbage();
        const heap = &program.v.heap.?;
        heap.peak_live_bytes = heap.live_bytes;
        const start = heap.live_bytes;
        try harness.expectResult(&program, "", try program.run(case[1]), case[2]);
        try testing.expect(heap.peak_live_bytes -| start < 1 << 20);
    }
}

test "lazy: iterate, repeat, repeatedly and cycle are lazy and may be infinite" {
    try expectOutput("[(take 3 (iterate inc 0)) (take 3 (repeat 1)) (take 2 (repeatedly (constantly :r))) (take 5 (cycle [1 2])) (cycle []) (try (iterate inc 0 5) (catch any e e))]", "[(0 1 2) (1 1 1) (:r :r) (1 2 1 2 1) () {:error :arity-mismatch, :message iterate takes 2 arguments, got 3, :fn test-form}]");
    try expectOutput("(let [n (atom 0) s (iterate (fn [x] (swap! n inc) (inc x)) 0)] (second s) @n)", "1");
    try expectOutput("(let [n (atom 0) s (repeatedly (fn [] (swap! n inc)))] [(first s) @n (doall (take 3 s)) @n])", "[1 1 (1 2 3) 3]");
    try expectOutput("[(repeat 3 :x) (repeat 0 :x) (repeat -1 :x) (count (repeat 1000000000 :x)) (nth (repeat 5 :y) 4) (drop 3 (repeat 5 :z)) (realized? (repeat 3 1)) (class (cycle [1]))]", "[(:x :x :x) () () 1000000000 :y (:z :z) false :lazy_seq]");
    try expectOutput("[(reduce (fn [a x] (if (> a 100) (reduced a) (+ a x))) (iterate inc 1)) (reduce + 0 (repeat 4 5)) (reduce (fn [a x] (if (> a 6) (reduced a) (+ a x))) (cycle [1 2]))]", "[105 20 7]");
    try expectOutput("(let [n (atom 0) c (cycle (map (fn [x] (swap! n inc) x) [1 2 3]))] [(take 7 c) @n])", "[(1 2 3 1 2 3 1) 3]");
}

test "lazy: concat, mapcat, take, drop, take-while, drop-while, partition, partition-all, distinct and dedupe are lazy" {
    // Expected values from babashka.
    try expectOutput("[(take 5 (mapcat (fn [x] [x x]) (range))) (take 3 (drop 5 (range))) (take-while neg? (range)) (take 3 (drop-while #(< % 10) (range))) (take 2 (partition 2 (range))) (take 3 (distinct (cycle [1 2 3 1])))]", "[(0 0 1 1 2) (5 6 7) () (10 11 12) ((0 1) (2 3)) (1 2 3)]");
    try expectOutput("(let [n (atom 0)] (first (map (fn [x] (swap! n inc) x) (take 100 (range)))) @n)", "1");
    try expectOutput("(let [n (atom 0)] (first (filter (fn [x] (swap! n inc) (odd? x)) (concat [1 2 3] (range 100)))) @n)", "3");
    try expectOutput("[(list? (first (partition 2 [1 2]))) (partition 3 3 [:a] [1 2 3 4]) (partition-all 2 [1 2 3]) (partition 2 1 [1 2 3]) (dedupe [1 1 2 1 1]) (distinct [1 2 1 3]) (take 2 [1 2 3]) (drop 2 [1 2 3]) (drop -1 [1 2]) (take -1 [1 2]) (concat) (concat [1] nil [2 3] (list 4)) (mapcat reverse [[1 2] [3 4]])]", "[false ((1 2 3) (4 :a)) ((1 2) (3)) ((1 2) (2 3)) (1 2 1) (1 2 3) (1 2) (3) (1 2) () () (1 2 3 4) (2 1 4 3)]");
    try expectOutput("(let [x (lazy-cat [1 2] (do (throw :never) []))] (take 2 x))", "(1 2)");
    try expectOutput("[(realized? (take 2 [1 2])) (class (drop 1 [1 2])) (count (drop 999990 (range 1000000))) (first (drop 3 (map inc (range))))]", "[false :lazy_seq 10 4]");
    // A concat nested deep enough to exhaust the stack is the catchable
    // :stack-overflow when it is walked.
    try expectOutput("(try (first (reduce concat [] (map vector (range 200000)))) (catch :stack-overflow e :deep))", ":deep");
}

test "lazy: interleave, interpose, take-nth, partition-by, tree-seq, flatten, reductions and drop-last are lazy" {
    // Expected values from babashka.
    try expectOutput("[(take 6 (interleave (range) (repeat :x))) (take 3 (tree-seq seq? seq '((1 2) (3)))) (take 3 (reductions + (range))) (take 4 (interpose :s (range)))]", "[(0 :x 1 :x 2 :x) (((1 2) (3)) (1 2) 1) (0 1 3) (0 :s 1 :s)]");
    try expectOutput("(pr-str [(interleave) (interleave [1 2]) (interleave [1 2] [:a :b :c] [\"x\" \"y\"]) (take-nth 2 (range 7)) (partition-by odd? [1 3 2 4 5]) (flatten [1 [2 [3 nil]] '(4)]) (flatten nil) (reductions + [1 2 3]) (reductions + []) (reductions + 10 [1 2]) (drop-last [1 2 3]) (drop-last 2 [1 2 3]) (split-at 2 [1 2 3]) (split-with odd? [1 3 2 5]) (sequence [1 2]) (sequence []) (replace {1 :a} '(1 2 1))])", "[() (1 2) (1 :a \"x\" 2 :b \"y\") (0 2 4 6) ((1 3) (2 4) (5)) (1 2 3 nil 4) () (1 3 6) (0) (10 11 13) (1 2) (1) [(1 2) (3)] [(1 3) (2 5)] (1 2) () (:a 2 :a)]");
    try expectOutput("[(class (interleave [1] [2])) (realized? (take-nth 2 [1 2 3])) (first (partition-by odd? (range))) (take 3 (flatten (repeat [1 [2]])))]", "[:lazy_seq false (0) (1 2 1)]");
}

test "lazy: transducers, transduce, into and sequence with an xform, eduction, completing, cat and halt-when" {
    // Expected values from babashka.
    try expectOutput("[(transduce (map inc) + [1 2 3]) (transduce (filter odd?) + 10 [1 2 3]) (into [] (comp (map inc) (filter even?)) (range 6)) (= #{2 3} (into #{} (map inc) [1 1 2])) (into '() (map inc) [1 2]) (sequence (map inc) [1 2 3]) (sequence (comp (take 2) (map inc)) (range)) (into [] cat [[1 2] [3]]) (into [] (mapcat reverse) [[1 2] [3 4]])]", "[9 14 [2 4 6] true (3 2) (2 3 4) (1 2) [1 2 3] [2 1 4 3]]");
    try expectOutput("[(into [] (partition-all 2) [1 2 3]) (into [] (partition-by odd?) [1 3 2 4 5]) (into [] (dedupe) [1 1 2 2 1]) (into [] (distinct) [1 2 1 3]) (into [] (interpose :s) [1 2 3]) (into [] (keep #(when (odd? %) (* % %))) [1 2 3]) (into [] (map-indexed vector) [:a :b]) (into [] (keep-indexed #(when (odd? %1) %2)) [:a :b :c :d])]", "[[[1 2] [3]] [[1 3] [2 4] [5]] [1 2 1] [1 2 3] [1 :s 2 :s 3] [1 9] [[0 :a] [1 :b]] [:b :d]]");
    try expectOutput("[(into [] (take-while neg?) [-1 -2 3 -4]) (into [] (drop-while neg?) [-1 -2 3 -4]) (into [] (drop 2) [1 2 3]) (into [] (remove odd?) [1 2 3 4]) (transduce (halt-when #(> % 2)) conj [] [1 2 3 4]) ((completing +) 5) (sequence (map +) [1 2] [10 20 30]) (eduction (map inc) [1 2]) (into [] (map inc) (range 3))]", "[[-1 -2] [3 -4] [3] [2 4] 3 5 (11 22) (2 3) [1 2 3]]");
    // sequence's outputs are what reached its accumulator: a reduced
    // value ends the walk and is not one (bb, as JVM Clojure 1.12).
    try expectOutput("[(sequence (halt-when #{3}) [0 1 2 3 4]) (take 5 (sequence (halt-when #{3}) (range))) (sequence (halt-when #{3} (fn [r x] [:r x])) [0 1 2 3 4]) (sequence (comp (halt-when #{1}) (partition-all 2)) [0 1 2]) (sequence (comp (partition-all 2) (halt-when #(= % [2 3]))) (range 10))]", "[(0 1 2) (0 1 2) (0 1 2) ([0]) ([0 1])]");
    // A step that throws ends the seq at its block (LAZY.md §9).
    try expectOutput("(let [n (atom 0) s (sequence (comp (map (fn [x] (when (and (= x 2) (< (swap! n inc) 2)) (throw :once)) x)) (take 4)) (range 10))] [(try (doall s) (catch any e e)) (doall s)])", "[:once ()]");
    // sequence is lazy: 32 outputs at a time (Clojure's iterator pulls
    // one input past them), its completion once.
    try expectOutput("(let [n (atom 0) s (sequence (map (fn [x] (swap! n inc) x)) (range 100))] [(realized? s) (first s) (<= 32 @n 33) (count s) @n (sequence (partition-all 3) (range 7))])", "[false 0 true 100 100 ([0 1 2] [3 4 5] [6])]");
}

test "lazy: reduce over an unrealized range allocates nothing" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    _ = try program.run("(def r (range 10000000))");
    const heap = program.v.ensureHeap();
    const live = heap.liveCount();
    const total = try program.run("(reduce + r)");
    try testing.expectEqual(@as(i64, 49999995000000), total.asFixnum());
    try testing.expectEqual(live, heap.liveCount());
}

test "lazy: cons, conj, list*, with-meta, empty and doall over a lazy seq" {
    try expectOutput("(let [n (atom 0) s (lazy-seq (swap! n inc) [2 3]) c (cons 1 s)] [@n c @n (class c) (cons 0 [1 2]) (class (cons 0 [1 2])) (cons 1 nil)])", "[0 (1 2 3) 0 :lazy_seq (0 1 2) :list (1)]");
    // list* conses onto its last argument as cons does, not realizing it.
    try expectOutput("(let [n (atom 0) s (list* 1 2 (lazy-seq (swap! n inc) [3]))] [@n (vec s) @n (class s) (list* 1 []) (list* 1 nil) (list* 1 ()) (list* 1 #{2})])", "[0 [1 2 3] 1 :lazy_seq (1) (1) (1) (1 2)]");
    try expectOutput("(let [s (lazy-seq [2 3])] [(conj s 1) (conj (lazy-seq nil) 1 2) (list* 0 1 s) (list* s) (list* (lazy-seq nil)) (empty s) (not-empty (lazy-seq nil)) (not-empty s)])", "[(1 2 3) (2 1) (0 1 2 3) (2 3) nil () nil (2 3)]");
    try expectOutput("(let [s (with-meta (lazy-seq [1 2]) {:m 1})] [(meta s) s (meta (rest s)) (meta (next s)) (= s [1 2])])", "[{:m 1} (1 2) nil nil true]");
    try expectOutput("(let [n (atom 0) f (fn f [i] (lazy-seq (swap! n inc) (when (< i 5) (cons i (f (inc i)))))) s (f 0)] [(realized? s) (do (dorun 2 s) @n) (identical? s (doall s)) @n (dorun s) (doall 2 [1 2 3])])", "[false 3 true 6 nil [1 2 3]]");
    try expectOutput("(take 4 (lazy-cat [1 2] [3] (list 4 5)))", "(1 2 3 4)");
    try expectOutput("[(realized? (delay 1)) (let [d (delay 1)] @d (realized? d)) (try (realized? 1) (catch any e e))]", "[false true {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "integration: get (2-arg + 3-arg default)" {
    try expectOutput("(get {:a 1} :a)", "1");
    try expectOutput("(get {:a 1} :missing)", "nil");
    try expectOutput("(get {:a 1} :missing :default)", ":default");
    try expectOutput("(get [10 20 30] 1)", "20");
    try expectOutput("(get [10 20 30] 99 :oob)", ":oob");
    try expectOutput("(get #{1 2 3} 2)", "2");
    // A set gives back the element it holds, not the key it was asked
    // with, wherever the two are equal and differ (babashka agrees).
    try expectOutput("[(get #{(lazy-seq [1])} [1]) (#{(list 1)} [1]) (get #{} [1] :nf) (get (transient #{(list 1)}) [1]) ((transient #{(list 1)}) [1]) (some #{(list 1)} [[1]]) (get #{(list 1)} [2] :nf)]", "[(1) (1) :nf (1) (1) (1) :nf]");
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
    try expectOutput("[(try (<) (catch :arity-mismatch _ :arity)) (try (<=) (catch :arity-mismatch _ :arity)) (try (==) (catch :arity-mismatch _ :arity))]", "[:arity :arity :arity]");
    // One argument is true whatever it is, as Clojure's ([x] true).
    try expectOutput("[(< :a) (<= \"s\") (> nil) (>= []) (== :a) (= :a) (< 1) (== ##NaN)]", "[true true true true true true true true]");
    try expectOutput("(< 1 2 3)", "true");
    try expectOutput("(< 1 3 2)", "false");
}

test "integration: value equality `=` (variadic, structural)" {
    try expectOutput("(try (=) (catch :arity-mismatch _ :arity))", ":arity");
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

test "integration: a built sequence is a list to every consumer, whatever its length" {
    // LIST.md §1: four or more results are a vector's view, fewer
    // are cons cells; nothing tells them apart.
    try expectOutput("[(list? (map inc (range 9))) (seq? (filter odd? (range 9))) (list? (map inc [1 2]))]", "[false true false]");
    try expectOutput("(map inc (range 6))", "(1 2 3 4 5 6)");
    try expectOutput("(keep (fn [x] (when (odd? x) (str x x))) (range 9))", "(11 33 55 77)");
    try expectOutput("[(= (map inc (range 5)) '(1 2 3 4 5)) (= (hash (map inc (range 5))) (hash '(1 2 3 4 5))) (= (remove odd? (range 10)) [0 2 4 6 8])]", "[true true true]");
    try expectOutput("[(conj (map inc (range 5)) 0) (cons :a (filter even? (range 10))) (rest (map inc (range 5))) (next (map inc (range 1)))]", "[(0 1 2 3 4 5) (:a 0 2 4 6 8) (2 3 4 5) nil]");
    try expectOutput("[(try (peek (map inc (range 5))) (catch any e e)) (try (pop (map inc (range 5))) (catch any e e)) (nth (map inc (range 10)) 7) (count (map-indexed vector (range 7))) (last (range 100000))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form} 8 7 99999]");
    try expectOutput("[(meta (with-meta (filter odd? (range 9)) {:a 1})) (meta (map inc (range 9))) (with-meta (map inc (range 5)) {:b 2})]", "[{:a 1} nil (1 2 3 4 5)]");
    try expectOutput("[(map inc []) (filter odd? [2 4 6 8]) (seq (map inc [])) (empty? (remove any? (range 5)))]", "[() () nil true]");
    try expectOutput("(let [xs (map inc (range 5))] {xs :v (vec xs) :w})", "{(1 2 3 4 5) :w}");
    try expectOutput("(let [v (into [] (filter even? (range 80)))] [(count v) (v 39) (peek (conj v :x)) (= v (vec (range 0 80 2))) (into [1] (range 2 5))])", "[40 78 :x true [1 2 3 4]]");
    try expectOutput("[(reduce-kv (fn [acc i x] (+ acc (* i x))) 0 (vec (range 40))) (reduce-kv (fn [acc k v] (+ acc k v)) 0 (zipmap (range 10) (range 10)))]", "[20540 90]");
    // A macro's expansion may be a built sequence, or hold one.
    try expectOutput("(do (defmacro twice-all [& xs] (cons '+ (map (fn [x] (list '* 2 x)) xs))) (twice-all 1 2 3 4))", "20");
    try expectOutput("(do (defmacro as-code [] (map identity '(+ 1 2 3 4))) (as-code))", "10");
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
        \\(try (doall (map (fn* [x] (throw :boom)) [1 2 3]))
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
    try testing.expectError(error.MalformedMacroCall, expand_mod.expandForm(&ctx, form));
    const failure = ctx.failure orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(message, failure.message);
    try testing.expectEqualStrings(at, src[failure.span.pos..][0..failure.span.len]);
}

test "defmacro: a failing macro call names the macro and the cause, at the call" {
    try expectMacroFailure("(defmacro m [] (throw (ex-info \"bad macro input\" {:x 1})))", "(do 1 (m))", "macro m threw bad macro input", "(m)");
    try expectMacroFailure("(defmacro m [] (throw :nope))", "(when true (m))", "macro m threw :nope", "(m)");
    try expectMacroFailure("", "(when-let [a 1 b 2] [a b])", "macro when-let threw when-let requires exactly 2 forms in binding vector", "(when-let [a 1 b 2] [a b])");
    try expectMacroFailure("", "(if-some [a 1] a 2 3)", "macro if-some threw if-some requires 1 or 2 forms after binding vector", "(if-some [a 1] a 2 3)");
    try expectMacroFailure("(defmacro m [a] a)", "(do (m))", "macro m takes 1 argument, got 0", "(m)");
    try expectMacroFailure("(defmacro m [a b & c] a)", "(m 1)", "macro m takes at least 2 arguments, got 1", "(m 1)");
    try expectMacroFailure("(defmacro m ([a] a) ([a b c & d] a))", "(m 1 2)", "macro m takes 1 or at least 3 arguments, got 2", "(m 1 2)");
    try expectMacroFailure("(defmacro m [] (first 1))", "(m)", "macro m failed: KindMismatch", "(m)");
    try expectMacroFailure("(defn g [x] x) (defmacro m [] (g))", "(m)", "macro m failed: ArityMismatch: g takes 1 argument, got 0", "(m)");
    try expectMacroFailure("(defmacro m [] (fn [] 1))", "(m)", "a macro returned a function, which is not a form", "(m)");
    try expectMacroFailure("(defmacro m [] (atom 1))", "(m)", "a macro returned an atom, which is not a form", "(m)");
    try expectMacroFailure("(defmacro m [a] a)", "(m (+ 1 `x))", "a syntax-quote is not data a macro can take", "`x");
    // A macro body has no `eval` or `load-string` (MACROEXPAND.md §1.2).
    try expectMacroFailure("(defmacro m [] (eval '(+ 1 2)))", "(m)", "macro m threw :no-compiler", "(m)");
    try expectMacroFailure("(defmacro m [] (load-string \"(+ 1 2)\"))", "(m)", "macro m threw :no-compiler: no compiler", "(m)");
}

test "defmacro: a macro body runs against the program's record types, namespaces and protocols" {
    // `reduced` in a macro registers its type where the program's
    // records are, so it renames none of them.
    try expectOutputProgram(
        \\(defrecord Point [x y])
        \\(defmacro first-big [& xs] (reduce (fn [a x] (if (> x 10) (reduced x) a)) nil xs))
        \\[(first-big 1 20 30) (->Point 1 2) (class (->Point 1 2))]
    , "[20 #user.Point{:x 1, :y 2} user.Point]");
    // A delay a macro makes is a delay once the macro is gone.
    try expectOutputProgram(
        \\(defrecord P [x])
        \\(def store (atom nil))
        \\(defmacro m [] (reset! store (delay 42)) nil)
        \\(m)
        \\[(delay? @store) (class @store) @@store (class (->P 1))]
    , "[true nexis.core.Delay 42 user.P]");
    try expectOutputProgram("(def store (atom nil)) (defmacro m [] (reset! store (delay 42)) nil) (m) (delay? @store)", "true");
    try expectOutputProgram("(defmacro m [] @(delay 1)) (m)", "1");
    try expectOutputProgram("(defmacro m [] (str (resolve 'inc))) (m)", "#'nexis.core/inc");
    try expectOutputProgram("(defmacro m [] (count (all-ns))) (= (m) (count (all-ns)))", "true");
    try expectOutputProgram("(ns other) (def x 7) (ns user) (defmacro m [] (count (ns-interns 'other))) (m)", "1");
    try expectOutputProgram(
        \\(defprotocol Sz (sz [x]))
        \\(extend-protocol Sz :string (sz [s] (count s)))
        \\(defmacro m [] (sz "abcd"))
        \\(m)
    , "4");
    // A record a macro builds is the program's type.
    try expectOutputProgram(
        \\(def made (atom nil))
        \\(defrecord Q [a])
        \\(defmacro mk [] (reset! made (->Q 1)) nil)
        \\(mk)
        \\[@made (Q? @made) (class @made)]
    , "[#user.Q{:a 1} true user.Q]");
    // `macroexpand-1`, `macroexpand` and `read-string` work in a
    // macro body.
    try expectOutputProgram("(defmacro m [x] (macroexpand-1 x)) [(m (when 1 2)) (macroexpand-1 '(m (when 1 2)))]", "[2 (if 1 (do 2) nil)]");
    try expectOutputProgram("(defmacro m [x] (macroexpand x)) (m (-> 1 inc))", "2");
    try expectOutputProgram("(defmacro r [s] (read-string s)) (r \"(+ 1 2)\")", "3");
    // So does the `defmacro`'s own definition: its metadata may call
    // `resolve` or `reduced`.
    try expectOutputProgram("(defmacro m {:k (str (resolve 'inc)) :r @(reduced 2)} [] 1) [(:k (meta #'m)) (:r (meta #'m)) (m)]", "[#'nexis.core/inc 2 1]");
}

test "defmacro: a store a macro opens belongs to the program" {
    try expectOutputProgramWithStore("macro-db-open",
        \\(def store (atom nil))
        \\(defmacro m [] (reset! store (db/open "@STORE@")) nil)
        \\(m)
        \\(let [r (db/ref @store :t :k)] [(db/get-key r) (do (db/put-key! r 4) (db/get-key r))])
    , "[nil 4]");
}

test "defmacro: a Nextomic connection a macro opens belongs to the program" {
    try expectOutputProgramWithStore("macro-connect",
        \\(def keep (atom nil))
        \\(defmacro m [] (reset! keep (nextomic/connect "@STORE@")) nil)
        \\(m)
        \\(nextomic/transact! @keep [{:db/ident :n :db/valueType :db.type/long :db/cardinality :db.cardinality/one}])
        \\(nextomic/transact! @keep [{:n 4}])
        \\(nextomic/q '[:find ?v . :where [_ :n ?v]] (nextomic/db @keep))
    , "4");
}

test "defmacro: what a macro prints goes to the with-out-str buffer the program opened" {
    try expectOutputProgram(
        \\(defmacro m [] (print (apply str (repeat 5000 "m"))) nil)
        \\(count (with-out-str (print "abc") (eval '(m)) (print (apply str (repeat 5000 "z")))))
    , "10003");
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
    try expectOutput("(try (+ 1 :hello) (catch any e e))", "{:error :kind-mismatch, :message + expects numbers, got a keyword, :fn test-form}");
}

test "integration: catchable — UnboundVar caught as :unbound-var" {
    try expectOutput("(try (+ 1 nope) (catch any e e))", "{:error :unbound-var, :message unbound var, :fn test-form}");
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
    , "{:error :atom-re-entry, :message atom re-entry, :fn fn}");
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
    , "{:error :atom-re-entry, :message atom re-entry, :fn fn}");
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
    try expectOutput("(try (reset! 1 2) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (swap! 1 inc) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (compare-and-set! 1 1 2) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "atom: swap! with non-callable f surfaces :not-callable" {
    try expectOutput(
        \\(try (swap! (atom 1) 2) (catch any e e))
    , "{:error :not-callable, :message an integer is not callable, :fn test-form}");
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

test "atom: a validator refuses a new state with :invalid-reference-state and the atom keeps its value" {
    try expectOutput(
        \\(let [a (atom 1 :validator pos?)]
        \\  [(try (swap! a dec) (catch :invalid-reference-state e e))
        \\   (try (reset! a 0) (catch any e e))
        \\   (try (swap-vals! a - 5) (catch any e e))
        \\   (try (reset-vals! a -1) (catch any e e))
        \\   (try (compare-and-set! a 99 -1) (catch any e e))
        \\   (swap! a inc) @a])
    , "[{:error :invalid-reference-state, :message invalid reference state, :fn test-form} {:error :invalid-reference-state, :message invalid reference state, :fn test-form} {:error :invalid-reference-state, :message invalid reference state, :fn test-form} {:error :invalid-reference-state, :message invalid reference state, :fn test-form} {:error :invalid-reference-state, :message invalid reference state, :fn test-form} 2 2]");
    try expectOutput("(try (atom -1 :validator pos?) (catch any e e))", "{:error :invalid-reference-state, :message invalid reference state, :fn test-form}");
    try expectOutput(
        \\(let [a (atom 1)]
        \\  [(try (set-validator! a neg?) (catch any e e)) (get-validator a)
        \\   (set-validator! a pos?) (= pos? (get-validator a))
        \\   (set-validator! a nil) (reset! a -5)])
    , "[{:error :invalid-reference-state, :message invalid reference state, :fn test-form} nil nil true nil -5]");
    // A validator's own throw propagates, and nothing is written.
    try expectOutput("(let [a (atom 1 :validator (fn [x] (if (= x 3) (throw :boom) true)))] [(try (reset! a 3) (catch any e e)) @a])", "[:boom 1]");
    try expectOutput("(try (set-validator! 1 pos?) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "atom: watches see key, atom, old and new after every change, and may change the atom" {
    try expectOutput(
        \\(let [a (atom 1) l (atom [])]
        \\  (add-watch a :k (fn [k r o n] (swap! l conj [k (= r a) o n])))
        \\  (swap! a inc) (reset! a 5) (compare-and-set! a 5 6) (compare-and-set! a 5 7)
        \\  (swap-vals! a inc) (reset-vals! a 0) (reset! a 0)
        \\  @l)
    , "[[:k true 1 2] [:k true 2 5] [:k true 5 6] [:k true 6 7] [:k true 7 0] [:k true 0 0]]");
    try expectOutput(
        \\(let [a (atom 0) n (atom 0)]
        \\  [(= a (add-watch a :x (fn [& _] (swap! n + 1))))
        \\   (do (add-watch a :y (fn [& _] (swap! n + 10))) (swap! a inc) @n)
        \\   (do (add-watch a :x (fn [& _] (swap! n + 100))) (swap! a inc) @n)
        \\   (= a (remove-watch a :y)) (do (swap! a inc) @n)
        \\   (do (remove-watch a :x) (remove-watch a :absent) (swap! a inc) @n)])
    , "[true 11 121 true 221 221]");
    // A watch runs after the change is made, so it may change the
    // atom again; a throw out of a watch leaves the change made.
    try expectOutput("(let [a (atom 1)] (add-watch a :k (fn [_ r _o n] (when (< n 5) (swap! r inc)))) (swap! a inc) @a)", "5");
    try expectOutput("(let [a (atom 1)] (add-watch a :k (fn [& _] (throw :w))) [(try (swap! a inc) (catch any e e)) @a])", "[:w 2]");
    try expectOutput("[(try (add-watch 1 :k inc) (catch any e e)) (try (remove-watch [] :k) (catch any e e))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "atom: the :meta option, and reset-meta! and alter-meta! on an atom" {
    try expectOutput("(let [a (atom 1 :meta {:m 1})] [(meta a) @a])", "[{:m 1} 1]");
    try expectOutput("(let [a (atom 1)] [(reset-meta! a {:x 1}) (alter-meta! a assoc :y 2) (meta a) (reset-meta! a nil) (meta a)])", "[{:x 1} {:x 1, :y 2} {:x 1, :y 2} nil nil]");
    // Options in any order; a key `atom` does not take is ignored, as
    // in Clojure; a key with no value is :invalid-argument.
    try expectOutput("(let [a (atom 1 :foo 2 :validator odd? :meta {:a 1})] [@a (meta a) (try (swap! a inc) (catch any e e))])", "[1 {:a 1} {:error :invalid-reference-state, :message invalid reference state, :fn test-form}]");
    try expectOutput("[(try (atom 1 :validator) (catch any e e)) (try (atom 1 :meta 5) (catch any e e))]", "[{:error :invalid-argument, :message invalid argument, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
    // Any map, a sorted one included, as with-meta takes.
    try expectOutput("(let [a (atom 1 :meta (sorted-map :b 2 :a 1))] [(meta a) (sorted? (meta a)) (reset-meta! a (sorted-map :z 1)) (meta a)])", "[{:a 1, :b 2} true {:z 1} {:z 1}]");
}

test "atom: the values a validator and the watches see stay alive across their calls" {
    // Every swap! builds a fresh state the atom does not hold while
    // the validator runs; each callback allocates.
    try expectOutput(
        \\(let [a (atom [] :validator (fn [v] (count (vec (range 200))) (vector? v)))
        \\      seen (atom 0)]
        \\  (add-watch a :w1 (fn [_k _r o n] (count (vec (range 300))) (when (= (count n) (inc (count o))) (swap! seen inc))))
        \\  (add-watch a :w2 (fn [_k _r o n] (count (mapv str (range 50))) (swap! seen + (count (str (last n))))))
        \\  (dotimes [i 200] (swap! a (fn [v] (conj v (str "item-" i)))))
        \\  [(count @a) (= (nth @a 199) "item-199") @seen])
    , "[200 true 1690]");
    // Each watch replaces the atom's watches map, so the map the
    // mutator is running through is held by nothing else; the
    // garbage each watch makes is maps of its shape, which reuse its
    // nodes if they are swept.
    try expectOutput(
        \\(let [a (atom 0) calls (atom 0)
        \\      w (fn w [k r _o _n]
        \\          (swap! calls inc) (remove-watch r k) (add-watch r k w)
        \\          (dotimes [_ 20] (reduce (fn [m i] (assoc m i i)) {} (range 8))))]
        \\  (doseq [k (range 8)] (add-watch a k w))
        \\  (dotimes [_ 50] (swap! a inc))
        \\  [@a @calls])
    , "[50 400]");
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
    try expectOutput("(try (nth \"ab\" 2) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
    try expectOutput("(try (nth \"\" 0) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
    // Negative index: same keyword.
    try expectOutput("(try (nth \"ab\" -1) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
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
    try expectOutput("(try (subs \"ab\" -1) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
    try expectOutput("(try (subs \"ab\" 0 -1) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
    try expectOutput("(try (subs \"ab\" 3) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
    try expectOutput("(try (subs \"ab\" 0 3) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
    // start > end.
    try expectOutput("(try (subs \"abc\" 2 1) (catch any e e))", "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}");
}

test "string: subs: kind-mismatch on non-string / non-fixnum index" {
    try expectOutput("(try (subs 42 0) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (subs \"ab\" :nope) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (subs \"ab\" 0 :nope) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
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

test "string: str measures plain parts and writes them once; one string alone is itself" {
    try expectOutput("(str -12 \\u{E9} nil \"x\" 0 \\u{1F980})", "-12éx0🦀");
    try expectOutput("(str 140737488355327 \" \" -140737488355328)", "140737488355327 -140737488355328");
    try expectOutput("(let [s (str \"a\" 1)] [(identical? s (str s)) (= \"a1\" (str s)) (str \"\")])", "[true true ]");
    // A part the printer makes switches the whole call to it.
    try expectOutput("(str 1 1.5 :k \"é\" [\"q\"])", "11.5:ké[\"q\"]");
}

test "string: string? after subs returns true" {
    try expectOutput("(string? (subs \"hello\" 1 4))", "true");
}

test "string: nth: kind-mismatch fires on non-indexable receiver" {
    // The kind check sits ABOVE the index-sign branch, so the
    // negative-index + default path never returns the default for
    // a non-indexable receiver. `(nth 123 -1 :d)` must be
    // `:kind-mismatch`, NOT `:d`.
    try expectOutput("(try (nth 123 -1 :d) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nth :keyword 0 :d) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nth {:a 1} 0 :d) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
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
        \\     (db/scan t :range "c" 'd)
        \\     (db/scan t :range :e)
        \\     (db/scan t :range :a :a)
        \\     (db/scan t :none)
        \\     (string? (ffirst (db/scan t :range)))
        \\     (= (db/ref conn :range (ffirst (db/scan t :range))) (db/ref conn :range :a))]))
    , "[[[b 2] [c 3] [d 4]] [[c 3]] [[c 3]] [] [] [] true true]");
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
    , "[{:error :db/key-too-large, :message db key too large, :fn test-form} {:error :db/key-too-large, :message db key too large, :fn test-form} {:error :db/open-failed, :message db open failed, :fn test-form}]");
}

test "db/open and nextomic/connect refuse a path with a NUL byte, or an empty one, as spit does" {
    // The open would stop at the NUL and name a shorter path than the
    // program checked (DB.md §2).
    try expectOutputProgramWithStore("seam-path",
        \\[(try (db/open "@STORE@\u0000.txt") (catch any e e))
        \\ (try (db/open "") (catch any e e))
        \\ (try (nextomic/connect "@STORE@\u0000.txt") (catch any e e))
        \\ (try (nextomic/connect "") (catch any e e))]
    , "[{:error :invalid-path, :message invalid path, :fn test-form} {:error :invalid-path, :message invalid path, :fn test-form} {:error :invalid-path, :message invalid path, :fn test-form} {:error :invalid-path, :message invalid path, :fn test-form}]");
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
    , "[{:error :db/key-too-large, :message db key too large, :fn test-form} 42]");
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
    , "[{:error :db-closed, :message db closed, :fn test-form} {:error :db-closed, :message db closed, :fn test-form} nil {:error :db-closed, :message db closed, :fn test-form} {:error :db-closed, :message db closed, :fn test-form}]");
}

test "db/close: aborts the connection's open transactions, whose handles then report :tx-closed" {
    try expectOutputProgramWithStore("close-open",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (def r (db/ref c :t "k"))
        \\  (db/put-key! r 1)
        \\  (def tx (db/begin-read c))
        \\  (def wx (db/begin-write c))
        \\  (db/put! wx r 2)
        \\  [(db/close c)
        \\   (try (db/get tx r) (catch any e e))
        \\   (try (db/put! wx r 3) (catch any e e))
        \\   (try (db/commit! wx) (catch any e e))
        \\   (db/abort-write! wx)
        \\   (db/snapshot? tx)
        \\   (let [c2 (db/open "@STORE@") r2 (db/ref c2 :t "k")]
        \\     [(db/get-key r2) (do (db/put-key! r2 4) (db/get-key r2))])])
    , "[nil {:error :tx-closed, :message tx closed, :fn test-form} {:error :tx-closed, :message tx closed, :fn test-form} {:error :tx-closed, :message tx closed, :fn test-form} nil false [1 4]]");
}

test "db/close: refused from a callback that holds one of the connection's transactions" {
    try expectOutputProgramWithStore("close-held",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (def r (db/ref c :t "k"))
        \\  (db/put-key! r 1)
        \\  (def wx (db/begin-write c))
        \\  [(try (db/reduce-tree wx :t (fn [a k v] (db/close c)) nil) (catch any e e))
        \\   (try (db/alter! wx r (fn [v] (db/close c) v)) (catch any e e))
        \\   (db/get wx r)
        \\   (db/close c)
        \\   (try (db/get wx r) (catch any e e))])
    , "[{:error :db/busy, :message db busy, :fn fn} {:error :db/busy, :message db busy, :fn fn} 1 nil {:error :tx-closed, :message tx closed, :fn test-form}]");
}

/// Run each of `steps`, which open `@STORE@`, on one VM under
/// `policy`; the last yields `expected`, and a collection afterwards
/// leaves at most a handful of transaction handles alive: between two
/// steps no frame is live and the backing stack holds nothing, so only
/// what the program holds keeps a handle.
fn expectDroppedTxns(policy: vm.GcPolicy, steps: []const []const u8, expected: []const u8) !void {
    var store = try SeamStore.init("dropped-txns");
    defer store.deinit();
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.setGcPolicy(policy);
    var last = value_mod.nilValue();
    for (steps) |step| {
        const src = try store.source(step);
        defer testing.allocator.free(src);
        last = try program.run(src);
    }
    try harness.expectResult(&program, steps[steps.len - 1], last, expected);
    program.v.collectGarbage();
    try testing.expect(nx.db.handleCount() < 8);
}

/// Ten thousand dropped reads (a store has 4,096 reader slots), and
/// dropped writes that hold the file's writer until a collection or
/// the close ends them.
const dropped_txns = [_][]const u8{
    \\(def c (db/open "@STORE@"))
    \\(def r (db/ref c :t :k))
    \\(db/put-key! r 1)
    \\(defn stage [v] (let [tx (db/begin-write c)] (db/put! tx r v)) nil)
    \\(dotimes [i 10000] (db/begin-read c))
    \\(stage 2)
    ,
    \\(def a (db/get-key r))
    \\(def b (do (db/put-key! r 3) (db/get-key r)))
    \\(stage 4)
    ,
    \\(def d (with-tx [tx c] (db/alter! tx r inc)))
    \\(stage 5)
    \\(db/close c)
    \\[a b d (db/get-key (db/ref (db/open "@STORE@") :t :k))]
    ,
};

test "db: a transaction the program drops is ended when a collection finds it unreachable" {
    try expectDroppedTxns(vm.GcPolicy.default, &dropped_txns, "[1 3 4 4]");
    try expectDroppedTxns(vm.GcPolicy.stress, &dropped_txns, "[1 3 4 4]");
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
        \\         (when (= k "k100")
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
    , "[{:error :db/busy, :message db busy, :fn fn} {:error :db/busy, :message db busy, :fn fn} 1 [1 2] [{:error :db/busy, :message db busy, :fn fn} 300 nil] [{:error :db/busy, :message db busy, :fn fn} true nil false]]");
}

test "db/put!: the lazy value it realizes cannot finish or close the transaction it writes in" {
    try expectOutputProgramWithStore("put-held",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (def r (db/ref c :t "k"))
        \\  (def tx (db/begin-write c))
        \\  [(try (db/put! tx r (lazy-seq (db/close c) [1])) (catch any e e))
        \\   (try (db/put! tx r (lazy-seq (db/commit! tx) [2])) (catch any e e))
        \\   (try (db/put! tx r (lazy-seq (db/abort-write! tx) [3])) (catch any e e))
        \\   (db/put! tx r (lazy-seq [4]))
        \\   (db/commit! tx)
        \\   (db/get-key r)
        \\   (try (db/put! tx r (lazy-seq [5])) (catch any e e))
        \\   (db/close c)])
    , "[{:error :db/busy, :message db busy, :fn fn} {:error :db/busy, :message db busy, :fn fn} {:error :db/busy, :message db busy, :fn fn} nil nil (4) {:error :tx-closed, :message tx closed, :fn test-form} nil]");
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
    try expectOutputProgram(src, "[{:error :db-closed, :message db closed, :fn test-form} :from-b]");
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
    , "[{:error :db/busy, :message db busy, :fn test-form} {:error :db/busy, :message db busy, :fn test-form} 2 2]");
}

const engineSyncs = nx.db.engineSyncs;

/// Run each `[source expected syncs]` step of `steps` on one program
/// holding `@STORE@`, where `syncs` is how many engine syncs the step
/// may issue: an exact count, or null for at least one.
fn expectSyncs(name: []const u8, steps: []const struct { []const u8, []const u8, ?u64 }) !void {
    var store = try SeamStore.init(name);
    defer store.deinit();
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    for (steps) |step| {
        const src = try store.source(step[0]);
        defer testing.allocator.free(src);
        const before = engineSyncs();
        try harness.expectResult(&program, src, try program.run(src), step[1]);
        const n = engineSyncs() - before;
        if (step[2]) |expected| try testing.expectEqual(expected, n) else try testing.expect(n > 0);
    }
}

test "db/open: a commit syncs nothing unless the connection is :durable; db/sync and db/close sync once" {
    try expectSyncs("durability", &.{
        // Creating the file syncs its first state before open returns.
        .{ "(do (def c (db/open \"@STORE@\" {:durability :commit})) nil)", "nil", null },
        .{
            \\(def d (db/open "@STORE@" {:durability :durable}))
            \\(def r (db/ref c :t :k))
            \\(do (db/put-key! r 1) (with-tx [tx c] (db/put! tx r 2)) [(db/get-key (db/ref d :t :k)) (db/delete-key! (db/ref c :t :j))])
            ,
            "[2 false]",
            0,
        },
        .{ "(db/sync c)", "nil", 1 },
        .{ "[(db/sync c) (db/sync d)]", "[nil nil]", 0 },
        .{ "(db/put-key! (db/ref d :t :k) 3)", "nil", null },
        .{ "(db/close d)", "nil", 0 },
        .{ "(do (db/put-key! r 4) (db/close c))", "nil", 1 },
        .{
            \\[(try (db/sync c) (catch any e e))
            \\ (try (db/open "@STORE@" {:durability :batch}) (catch any e e))
            \\ (try (db/open "@STORE@" {:durability "commit"}) (catch any e e))
            \\ (try (db/open "@STORE@" [:durability :commit]) (catch any e e))
            \\ (db/get-key (db/ref (db/open "@STORE@" nil) :t :k))]
            ,
            "[{:error :db-closed, :message db closed, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form} 4]",
            0,
        },
    });
}

test "db/begin-read: two hundred reads stay open at once, past emdb's default of 126 slots" {
    try expectOutputProgramWithStore("many-readers",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  (db/put-key! (db/ref c :t :k) 1)
        \\  (def reads (mapv (fn [_] (db/begin-read c)) (range 200)))
        \\  [(count reads) (db/get (peek reads) (db/ref c :t :k)) (every? nil? (mapv db/abort-read! reads))])
    , "[200 1 true]");
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
    , "[{:error :db/busy, :message db busy, :fn fn} {:error :nextomic/nested, :message the store's write transaction is held: a with scope, a transaction function or another connection is writing, :fn test-form} {:error :nextomic/nested, :message the store's write transaction is held: a with scope, a transaction function or another connection is writing, :fn test-form} nil 1 4 #{[3]}]");
}

test "db: Nextomic's nx/ trees are not reachable through db/*" {
    try expectOutputProgramWithStore("nx-trees",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  [(try (db/ref c :nx/eavt "k") (catch any e e))
        \\   (try (with-read-tx [t c] (db/scan t :nx/sys)) (catch any e e))
        \\   (try (with-read-tx [t c] (db/reduce-tree t :nx/txlog conj [])) (catch any e e))
        \\   (db/ref? (db/ref c :nxt "k"))])
    , "[{:error :db/invalid-key, :message db invalid key, :fn test-form} {:error :db/invalid-key, :message db invalid key, :fn test-form} {:error :db/invalid-key, :message db invalid key, :fn test-form} true]");
}

test "db: a value with no serialized form is :unserializable" {
    try expectOutputProgramWithStore("unserializable",
        \\(do
        \\  (def c (db/open "@STORE@"))
        \\  [(try (db/put-key! (db/ref c :t "f") inc) (catch :unserializable e e))
        \\   (try (with-tx [tx c] (db/put! tx (db/ref c :t "a") [1 (atom 2)])) (catch any e e))])
    , "[{:error :unserializable, :message unserializable, :fn test-form} {:error :unserializable, :message unserializable, :fn test-form}]");
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
    try expectOutput("(try (lower-case \"HI\") (catch any e e))", "{:error :unbound-var, :message unbound var, :fn test-form}");
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
    try expectOutput("(try (nexis.string/split \"abc\" 42) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nexis.string/split 1 \",\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "nexis.string: escape and replace-first, with a literal match" {
    try expectOutput(
        \\(pr-str [(nexis.string/escape "a<b>&" {\< "&lt;" \> "&gt;"}) (nexis.string/escape "abc" {\b 1}) (nexis.string/escape "" {}) (nexis.string/escape "ab" {\a false \b nil})
        \\         (nexis.string/replace-first "a-b-c" "-" "+") (nexis.string/replace-first "abc" \b \x) (nexis.string/replace-first "abc" "z" "y")
        \\         (nexis.string/replace-first "abc" "" "-") (nexis.string/replace-first "héllo" "l" "L")])
    , "[\"a&lt;b&gt;&\" \"a1c\" \"\" \"ab\" \"a+b-c\" \"axc\" \"abc\" \"-abc\" \"héLlo\"]");
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
    try expectOutput("(try (nexis.string/join :sep [1 2]) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nexis.string/join 42 [1 2]) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nexis.string/join \",\" 42) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
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

test "nexis.string: join, split, replace and index-of across 32-byte blocks and multibyte text" {
    try expectOutput("(nexis.string/join \",\" [1 -2 nil \"é\" \\c])", "1,-2,,é,c");
    try expectOutput("[(nexis.string/join \"-\" \"héb\") (nexis.string/join \", \" []) (nexis.string/join \",\" {:a 1})]", "[h-é-b  [:a 1]]");
    try expectOutput("(let [s (nexis.string/join \",\" (range 1000))] [(count s) (count (nexis.string/split s \",\")) (last (nexis.string/split s \",\"))])", "[3889 1000 999]");
    try expectOutput("(pr-str [(nexis.string/split \",a,b\" \",\") (nexis.string/split \"aébéc\" \"é\") (nexis.string/split \"a::b:::c\" \"::\")])", "[[\"\" \"a\" \"b\"] [\"a\" \"b\" \"c\"] [\"a\" \"b\" \":c\"]]");
    try expectOutput("(let [s (apply str (repeat 50 \"xé,\"))] [(count (nexis.string/split s \",\")) (count (nexis.string/split s \"é,x\")) (count (nexis.string/split s \",\" 7))])", "[50 50 7]");
    try expectOutput("(let [s (apply str (repeat 100 \"ab\"))] [(count (nexis.string/replace s \"b\" \"xyz\")) (count (nexis.string/replace s \"ab\" \"\")) (identical? s (nexis.string/replace s \"z\" \"y\"))])", "[400 0 true]");
    try expectOutput("[(nexis.string/replace \"é🦀\" \"\" \"-\") (nexis.string/replace \"a.b.c\" \\. \\é) (nexis.string/replace \"aéaéa\" \"é\" \"--\")]", "[-é-🦀- aébéc a--a--a]");
    try expectOutput("(let [s (str (apply str (repeat 40 \"x\")) \"é\" \"yz\" (apply str (repeat 40 \"x\")) \"yz\")] [(nexis.string/index-of s \"yz\") (nexis.string/index-of s \"yz\" 42) (nexis.string/index-of s \\é) (nexis.string/includes? s \"éyz\") (nexis.string/includes? s \"zé\")])", "[41 83 40 true false]");
}

test "nexis.string: predicates and searches" {
    try expectOutput("(let [s \"hello world\"] [(nexis.string/starts-with? s \"hell\") (nexis.string/ends-with? s \"world\") (nexis.string/includes? s \"o w\") (nexis.string/includes? s \"x\") (nexis.string/starts-with? s \"\")])", "[true true true false true]");
    try expectOutput("[(nexis.string/index-of \"héllo\" \"l\") (nexis.string/index-of \"héllo\" \\l 3) (nexis.string/index-of \"abc\" \"z\") (nexis.string/last-index-of \"héllo\" \"l\") (nexis.string/last-index-of \"abcabc\" \"b\" 3)]", "[2 3 nil 3 1]");
    try expectOutput("[(nexis.string/blank? nil) (nexis.string/blank? \" \\t\\n\") (nexis.string/blank? \" x \")]", "[true true false]");
    try expectOutput("(try (nexis.string/starts-with? 1 \"a\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
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
    try expectOutput("[(nexis.set/union #{1 2} #{2 3}) (nexis.set/union) (nexis.set/intersection #{1 2 3} #{2 3 4} #{3 2}) (nexis.set/difference #{1 2 3} #{2} #{3})]", "[#{1 2 3} #{} #{3 2} #{1}]");
    try expectOutput("[(nexis.set/subset? #{1} #{1 2}) (nexis.set/subset? #{3} #{1 2}) (nexis.set/superset? #{1 2} #{2}) (nexis.set/select odd? #{1 2 3})]", "[true false true #{1 3}]");
    try expectOutput("[(nexis.set/map-invert {:a 1}) (= {:z 1 :b 2} (nexis.set/rename-keys {:a 1 :b 2} {:a :z}))]", "[{1 :a} true]");
    // As Clojure's: the largest (union) or smallest (intersection,
    // select's own) argument keeps its kind and metadata.
    try expectOutput("[(nexis.set/union (sorted-set 3 1 5) #{2}) (nexis.set/union nil) (nexis.set/union #{1} (sorted-set 4 2 3) #{5}) (meta (nexis.set/union (with-meta #{1 2} {:m 1}) #{3}))]", "[#{1 2 3 5} nil #{1 2 3 4 5} {:m 1}]");
    try expectOutput("[(nexis.set/intersection (sorted-set 3 1 2) #{1 2 3 4}) (nexis.set/intersection #{1 2 3 4} (sorted-set 2 1) #{1 2 9}) (nexis.set/select odd? (sorted-set 5 4 3 2 1))]", "[#{1 2 3} #{1 2} #{1 3 5}]");
}

test "nexis.string: replace: literal, all-non-overlapping" {
    // A char for a char, and an empty match between code points, as
    // Clojure's replace (Java's String.replace) does.
    try expectOutput("(pr-str [(nexis.string/replace \"aXbX\" \\X \\-) (nexis.string/replace \"héé\" \\é \\e) (nexis.string/replace \"abc\" \"\" \"-\") (nexis.string/replace \"\" \"\" \"-\")])", "[\"a-b-\" \"hee\" \"-a-b-c-\" \"-\"]");
    try expectOutput("[(try (nexis.string/replace \"abc\" \\a \"x\") (catch any e e)) (try (nexis.string/replace \"abc\" \"a\" \\x) (catch any e e))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
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
    try expectOutput("(try (nexis.string/replace \"abc\" :nope \"x\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nexis.string/replace \"abc\" \"b\" 42) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (nexis.string/replace 42 \"b\" \"x\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "nexis.string: replace: UTF-8 boundary safety" {
    // Valid UTF-8 in, valid UTF-8 out. `é` (0xC3 0xA9) won't be
    // matched by ASCII `c` (UTF-8 continuation bytes never equal
    // ASCII delimiter targets).
    try expectOutput("(nexis.string/replace \"aécé\" \"c\" \"X\")", "aéXé");
}

// =============================================================================
// Regular expressions (docs/REGEX.md §9); expected results are bb's
// =============================================================================

test "regex: re-find and re-matches give the match, or the groups vector with nil for a group that did not take part" {
    try expectOutput(
        \\(pr-str [(re-find (re-pattern "\\d+") "ab123cd45") (re-find (re-pattern "(\\w)(\\d)?") "x") (re-find (re-pattern "z") "abc") (re-find (re-pattern "") "")
        \\         (re-matches (re-pattern "a|ab") "ab") (re-matches (re-pattern "(a)(b)?") "a") (re-matches (re-pattern "\\d+") "12x") (re-matches (re-pattern "(?<y>\\d{4})-(\\d\\d)") "2024-10")
        \\         (re-find (re-pattern ".") "😀") (re-find (re-pattern "(?i)É") "é") (re-find (re-pattern "(?iu)É") "é")])
    , "[\"123\" [\"x\" \"x\" nil] nil \"\" \"ab\" [\"a\" \"a\" nil] nil [\"2024-10\" \"2024\" \"10\"] \"😀\" nil \"é\"]");
}

test "regex: re-seq is lazy, one match per element, nil when nothing matches; an empty match advances one code point" {
    try expectOutput(
        \\(pr-str [(re-seq (re-pattern "a*") "baaa") (re-seq (re-pattern "x") "abc") (re-seq (re-pattern "(\\d)(x)?") "1x2") (re-seq (re-pattern "") "aé")
        \\         (count (re-seq (re-pattern "\\w+") (apply str (repeat 1000 "ab "))))
        \\         (let [s (re-seq (re-pattern "\\d") "a1b2")] [(first s) (realized? (rest s)) (class s)])
        \\         (take 2 (re-seq (re-pattern "\\d") (apply str (repeat 1000000 "1"))))])
    , "[(\"\" \"aaa\" \"\") nil ([\"1x\" \"1\" \"x\"] [\"2\" \"2\" nil]) (\"\" \"\" \"\") 1000 [\"1\" false :lazy_seq] (\"1\" \"1\")]");
}

test "regex: a matcher advances with re-find, re-groups repeats its last match, and a failed search stays failed" {
    try expectOutput(
        \\(let [m (re-matcher (re-pattern "a(b)?") "a ab")]
        \\  (pr-str [(re-find m) (re-groups m) (re-find m) (re-find m) (re-find m) (try (re-groups m) (catch any e e))]))
    , "[[\"a\" nil] [\"a\" nil] [\"ab\" \"b\"] nil nil {:error :invalid-argument, :message \"re-groups: no match found\", :fn \"test-form\"}]");
    try expectOutput("(try (re-groups (re-matcher (re-pattern \"a\") \"a\")) (catch any e e))", "{:error :invalid-argument, :message re-groups: no match found, :fn test-form}");
}

test "regex: a pattern is an identity value that prints as #\"...\" and whose str is its source" {
    try expectOutput(
        \\(pr-str [(str (re-pattern "a\\d")) (str [(re-pattern "a")]) (format "%s|%s" (re-pattern "x+") 1) (re-pattern "é\"")
        \\         (= (re-pattern "a") (re-pattern "a")) (let [p (re-pattern "a")] [(= p p) (identical? p (re-pattern p)) (count (hash-set p p))])
        \\         (class (re-pattern "a")) (type (re-matcher (re-pattern "a") "")) (re-matcher (re-pattern "a\\d") "")])
    , "[\"a\\\\d\" \"[#\\\"a\\\"]\" \"x+|1\" #\"é\\\"\" false [true true 1] :regex :matcher #<matcher #\"a\\d\">]");
    try expectOutput("[(try (with-meta (re-pattern \"a\") {}) (catch any e e)) (meta (re-pattern \"a\")) (seqable? (re-pattern \"a\"))]", "[{:error :kind-mismatch, :message kind mismatch, :fn test-form} nil false]");
}

test "regex: #\"...\" is a pattern constant; quote, macros and read-string see a pattern value" {
    try expectOutput(
        \\(defmacro finder [p] (list 're-find p "xay"))
        \\(defmacro made [] (re-pattern "b+"))
        \\(pr-str [(re-find #"\d+" "ab12") #"a\"b" '#"x" (class '#"x") (str #"a\d") (finder #"a") (re-find (made) "abbc")
        \\         (let [f (fn [] #"a")] (identical? (f) (f))) (= #"a" #"a") (count #{#"a" #"a"}) (count {#"a" 1 #"a" 2})
        \\         (loop [i 0 ps []] (if (< i 3) (recur (inc i) (conj ps #"z")) (apply identical? (take 2 ps))))
        \\         (read-string "#\"a+\"") (class (read-string "#\"a+\"")) (try (read-string "#\"(\"") (catch any e e))])
    , "[\"12\" #\"a\\\"b\" #\"x\" :regex \"a\\\\d\" \"a\" \"bb\" true false 2 2 true #\"a+\" :regex {:error :reader-error, :message \"reader error\", :fn \"test-form\"}]");
}

test "regex: nexis.string/split on a pattern is Java's Pattern.split" {
    try expectOutput(
        \\(pr-str [(nexis.string/split "a1b2c" #"\d") (nexis.string/split "1a1" #"1") (nexis.string/split "abc" #"") (nexis.string/split "a b  c" #"\s+" 2) (nexis.string/split "a,b,," #"," -1) (nexis.string/split "" #",")
        \\         (nexis.string/split "a,b,," #",") (nexis.string/split ",a" #",") (nexis.string/split "abc" #"x") (nexis.string/split "aXbXc" #"X" 1) (nexis.string/split "a1b2c3" #"\d" 2) (nexis.string/split "é😀b" #"")
        \\         (nexis.string/split " a b " #" ") (nexis.string/split "a1b" #"\d" 0) (nexis.string/split "a1b1" #"\d" 5) (let [x "abc"] (identical? x (first (nexis.string/split x #"z"))))])
    , "[[\"a\" \"b\" \"c\"] [\"\" \"a\"] [\"a\" \"b\" \"c\"] [\"a\" \"b  c\"] [\"a\" \"b\" \"\" \"\"] [\"\"] [\"a\" \"b\"] [\"\" \"a\"] [\"abc\"] [\"aXbXc\"] [\"a\" \"b2c3\"] [\"é\" \"😀\" \"b\"] [\"\" \"a\" \"b\"] [\"a\" \"b\"] [\"a\" \"b\" \"\"] true]");
}

test "regex: nexis.string/replace and replace-first take a pattern with a $n and ${name} replacement, or a function of the match" {
    try expectOutput(
        \\(pr-str [(nexis.string/replace "a1b2" #"(\d)" "<$1>") (nexis.string/replace "a1" #"(\d)" "$12") (nexis.string/replace "2024-10" #"(?<y>\d+)-(?<m>\d+)" "${m}/${y}") (nexis.string/replace "a1" #"\d" "\\$")
        \\         (nexis.string/replace "abc" #"x" "$") (nexis.string/replace "aaa" #"a*" "-") (nexis.string/replace "abc" #"" "-") (let [x "abc"] (identical? x (nexis.string/replace x #"z" "y")))
        \\         (nexis.string/replace "a1b22" #"\d+" (fn [m] (str "<" m ">"))) (nexis.string/replace "a1b2" #"([a-z])(\d)" (fn [[_ l d]] (str d l))) (nexis.string/replace "a1" #"(x)?\d" pr-str)
        \\         (nexis.string/replace-first "a1b2" #"\d" "X") (nexis.string/replace-first "a1b2" #"(\d)" "<$1>") (nexis.string/replace-first "a1b2" #"\d" (fn [m] (str m m))) (nexis.string/replace-first "abc" #"z" "y")
        \\         (nexis.string/replace-first "a-b-c" "-" "+") (nexis.string/replace-first "abc" \b \x) (nexis.string/replace-first "abc" "" "-") (nexis.string/replace-first "aébé" "é" "E")
        \\         (nexis.string/re-quote-replacement "a$1\\b") (nexis.string/replace "x" #"x" (nexis.string/re-quote-replacement "$1\\"))])
    , "[\"a<1>b<2>\" \"a12\" \"10/2024\" \"a$\" \"abc\" \"--\" \"-a-b-c-\" true \"a<1>b<22>\" \"1a2b\" \"a[\\\"1\\\" nil]\" \"aXb2\" \"a<1>b2\" \"a11b2\" \"abc\" \"a+b-c\" \"axc\" \"-abc\" \"aEbé\" \"a\\\\$1\\\\\\\\b\" \"$1\\\\\"]");
}

test "regex: a replacement Java refuses throws :invalid-replacement with its sentence; a function must return a string" {
    try expectOutput(
        \\(pr-str (for [r ["$2" "x$" "$x" "x\\" "${y}" "${}" "${1x}" "${ab"]]
        \\          (try (nexis.string/replace "a1" #"(\d)" r) (catch :invalid-replacement e (:message e)))))
    , "(\"No group 2\" \"Illegal group reference: group index is missing\" \"Illegal group reference\" \"character to be escaped is missing\" \"No group with name {y}\" \"named capturing group has 0 length name\" \"capturing group name {1x} starts with digit character\" \"named capturing group is missing trailing '}'\")");
    try expectOutput(
        \\(map #(try (%) (catch any e e))
        \\     [#(nexis.string/replace "a1" #"\d" (fn [m] 5)) #(nexis.string/replace "a" #"a" 1) #(nexis.string/split "a" #"a" "x") #(nexis.string/replace-first "a" #"a" \b) #(nexis.string/replace-first "abc" "b" 1) #(nexis.string/re-quote-replacement 1)])
    , "({:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :not-callable, :message an integer is not callable, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :not-callable, :message a char is not callable, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn})");
}

test "regex: an invalid pattern throws :invalid-regex with the sentence and the index; a wrong kind is :kind-mismatch" {
    try expectOutput(
        \\(pr-str (for [p ["(" "a{2,1}" "é(" "(?=a)" "a)" "*a" "\\p{Foo}"]]
        \\          (try (re-pattern p) (catch :invalid-regex e [(:message e) (:index e) (= p (:pattern e))]))))
    , "([\"Unclosed group\" 1 true] [\"Illegal repetition range\" 5 true] [\"Unclosed group\" 2 true] [\"lookahead and lookbehind are not supported\" 0 true] [\"Unmatched closing ')'\" 0 true] [\"Dangling meta character '*'\" 0 true] [\"Unknown character property name {Foo}\" 6 true])");
    try expectOutput(
        \\(map #(try (%) (catch any e e))
        \\     [#(re-find "a" "a") #(re-seq "a" "a") #(re-matches "a" "a") #(re-pattern 1) #(re-find (re-pattern "a") 1) #(re-matcher (re-pattern "a") nil) #(re-find 1) #(re-groups (re-pattern "a"))])
    , "({:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn})");
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
    try expectOutput("(try (print :a) (catch any e e))", "{:error :io-error, :message io error, :fn test-form}");
    try expectOutput("(try (println :a) (catch any e e))", "{:error :io-error, :message io error, :fn test-form}");
    try expectOutput("(try (prn :a) (catch any e e))", "{:error :io-error, :message io error, :fn test-form}");
    // pr-str does NOT touch vm.io (it returns a String); it
    // works regardless. Pin the contract.
    try expectOutput("(pr-str :a)", ":a");
}

test "io: slurp / spit: a missing file or directory is :file-not-found" {
    try expectOutput("(try (slurp \"/nexis-no-such-dir/anything.txt\") (catch any e e))", "{:error :file-not-found, :message file not found, :fn test-form}");
    try expectOutput("(try (spit \"/nexis-no-such-dir/anything.txt\" \"x\") (catch any e e))", "{:error :file-not-found, :message file not found, :fn test-form}");
}

test "io: slurp / spit: non-string path is :kind-mismatch" {
    try expectOutput("(try (slurp 42) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (spit :nope \"x\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "io: slurp / spit: empty path is :invalid-path" {
    try expectOutput("(try (slurp \"\") (catch any e e))", "{:error :invalid-path, :message invalid path, :fn test-form}");
    try expectOutput("(try (spit \"\" \"x\") (catch any e e))", "{:error :invalid-path, :message invalid path, :fn test-form}");
}

// =============================================================================
// nexis.sys, nexis.shell, nexis.time, nexis.json (docs/STDLIB.md §10–§12)
// =============================================================================

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "sys: getenv reads one variable, or every one as a map" {
    try testing.expectEqual(@as(c_int, 0), setenv("NEXIS_SYS_TEST", "h\xc3\xa9llo=1", 1));
    try testing.expectEqual(@as(c_int, 0), setenv("NEXIS_SYS_BYTES", "a\xffb", 1));
    try expectOutput("(nexis.sys/getenv \"NEXIS_SYS_TEST\")", "h\xc3\xa9llo=1");
    try expectOutput("(nexis.sys/getenv \"NEXIS_NO_SUCH_VARIABLE\")", "nil");
    try expectOutput("(nexis.sys/getenv \"\")", "nil");
    try expectOutput("(nexis.sys/getenv \"A\\u0000B\")", "nil");
    try expectOutput("(get (nexis.sys/getenv) \"NEXIS_SYS_TEST\")", "h\xc3\xa9llo=1");
    try expectOutput("(every? string? (mapcat identity (nexis.sys/getenv)))", "true");
    // Bytes that are not UTF-8 read as U+FFFD, as Java decodes them.
    try expectOutput("(nexis.sys/getenv \"NEXIS_SYS_BYTES\")", "a\u{FFFD}b");
    try expectOutput("(try (nexis.sys/getenv :path) (catch any e (:error e)))", ":kind-mismatch");
}

test "sys: cwd is the working directory's absolute path" {
    const cwd = try std.process.currentPathAlloc(testing.io, testing.allocator);
    defer testing.allocator.free(cwd);
    try expectOutput("(nexis.sys/cwd)", cwd);
}

/// `expectOutput` with the VM given the test's `std.Io`, as `bin/nexis`
/// gives it the CLI's: `sh` spawns through it.
fn expectOutputWithIo(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.io = testing.io;
    try harness.expectResult(&program, src, try program.run(src), expected);
}

test "shell: sh returns the exit status and the output of both streams" {
    try expectOutputWithIo(
        \\(nexis.shell/sh "sh" "-c" "printf out; printf err >&2; exit 3")
    , "{:exit 3, :out out, :err err}");
    try expectOutputWithIo("(nexis.shell/sh \"true\")", "{:exit 0, :out , :err }");
    // A signal's status is 128 plus its number, as Java reports it.
    try expectOutputWithIo("(:exit (nexis.shell/sh \"sh\" \"-c\" \"kill -9 $$\"))", "137");
    // Output that is not UTF-8 reads as U+FFFD.
    try expectOutputWithIo("(:out (nexis.shell/sh \"printf\" \"a\\\\377b\"))", "a\u{FFFD}b");
}

test "shell: sh feeds :in to the command, past any pipe's buffer" {
    try expectOutputWithIo("(:out (nexis.shell/sh \"cat\" :in \"h\u{e9}llo\"))", "h\u{e9}llo");
    try expectOutputWithIo("(:out (nexis.shell/sh \"cat\" :in nil))", "");
    // Both directions at once: the command writes as it reads.
    try expectOutputWithIo("(count (:out (nexis.shell/sh \"cat\" :in (apply str (repeat 200000 \"0123456789\")))))", "2000000");
    // A command that stops reading early leaves the rest unwritten.
    try expectOutputWithIo("(nexis.shell/sh \"head\" \"-c\" \"3\" :in (apply str (repeat 200000 \"0123456789\")))", "{:exit 0, :out 012, :err }");
}

test "shell: sh runs in :dir and with :env, or *sh-dir* and *sh-env*" {
    try expectOutputWithIo("(:out (nexis.shell/sh \"pwd\" :dir \"/\"))", "/\n");
    try expectOutputWithIo("(:out (nexis.shell/with-sh-dir \"/\" (nexis.shell/sh \"pwd\")))", "/\n");
    try expectOutputWithIo(
        \\(:out (nexis.shell/sh "sh" "-c" "echo $A-$B" :env {"A" "x" :B 2}))
    , "x-2\n");
    try expectOutputWithIo(
        \\(nexis.shell/with-sh-env {"A" "y"} (:out (nexis.shell/sh "sh" "-c" "echo $A")))
    , "y\n");
    // An explicit option wins over the binding.
    try expectOutputWithIo(
        \\(nexis.shell/with-sh-env {"A" "y"} (:out (nexis.shell/sh "sh" "-c" "echo $A" :env {"A" "z"})))
    , "z\n");
}

test "shell: sh refuses what it cannot run" {
    try expectOutputWithIo("(try (nexis.shell/sh \"nexis-no-such-program\") (catch any e (:error e)))", ":file-not-found");
    try expectOutputWithIo("(try (nexis.shell/sh \"pwd\" :dir \"/nexis-no-such-dir\") (catch any e (:error e)))", ":file-not-found");
    try expectOutputWithIo("(try (nexis.shell/sh) (catch any e (:error e)))", ":invalid-argument");
    try expectOutputWithIo("(try (nexis.shell/sh \"ls\" :out-enc :bytes) (catch any e (:error e)))", ":invalid-argument");
    try expectOutputWithIo("(try (nexis.shell/sh \"ls\" :in 5) (catch any e (:error e)))", ":kind-mismatch");
    try expectOutputWithIo("(try (nexis.shell/sh \"ls\" :env {\"A=B\" 1}) (catch any e (:error e)))", ":invalid-argument");
    try expectOutputWithIo("(try (nexis.shell/sh \"echo\" \"a\\u0000b\") (catch any e (:error e)))", ":invalid-argument");
    try expectOutputWithIo("(try (nexis.shell/sh \"ls\" :dir) (catch any e (:error e)))", ":arity-mismatch");
    // A VM with no I/O spawns nothing.
    try expectOutput("(try (nexis.shell/sh \"true\") (catch any e (:error e)))", ":io-error");
}

test "time: format writes an instant as Java's Instant.toString does" {
    try expectOutput("(nexis.time/format 0)", "1970-01-01T00:00:00Z");
    try expectOutput("(nexis.time/format 1791549015123)", "2026-10-09T12:30:15.123Z");
    try expectOutput("(nexis.time/format (nexis.time/instant 951868799999))", "2000-02-29T23:59:59.999Z");
    try expectOutput("(nexis.time/format -1)", "1969-12-31T23:59:59.999Z");
    try expectOutput("(nexis.time/format -62167219200000)", "0000-01-01T00:00:00Z");
    try expectOutput("(nexis.time/format -62198755200000)", "-0001-01-01T00:00:00Z");
    try expectOutput("(nexis.time/format 1791549015120)", "2026-10-09T12:30:15.120Z");
    try expectOutput("(try (nexis.time/format \"2026\") (catch any e (:error e)))", ":kind-mismatch");
}

test "time: parse reads ISO-8601 instants, a missing offset UTC" {
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10-09\"))", "1791504000000");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10-09T12:30Z\"))", "1791549000000");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10-09T12:30:15.5+02:00\"))", "1791541815500");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10-09t12:30:15.123456789z\"))", "1791549015123");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10-09T12:30:00-0530\"))", "1791568800000");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10-09T12:30\"))", "1791549000000");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026\"))", "1767225600000");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"2026-10\"))", "1790812800000");
    try expectOutput("(nexis.time/inst-ms (nexis.time/parse \"-0001-01-01T00:00:00Z\"))", "-62198755200000");
    try expectOutput("(= (nexis.time/instant \"2026-10-09\") (nexis.time/parse \"2026-10-09T00:00:00.000Z\"))", "true");
    for ([_][]const u8{ "", "x", "2026-13-01", "2026-02-29", "2026-10-09T24:00Z", "2026-10-09T12:60Z", "2026-10-09T12:30:61Z", "2026-10-09T12Z", "2026-10-09T12:30:15.Z", "2026-10-09T12:30+25:00", "2026-10-09T12:30Zx", "26-10-09", "2026-1-09", "99999-01-01" }) |text| {
        const src = try std.fmt.allocPrint(testing.allocator, "(try (nexis.time/parse \"{s}\") (catch any e (:error e)))", .{text});
        defer testing.allocator.free(src);
        try expectOutput(src, ":invalid-argument");
    }
    try expectOutput("(try (nexis.time/parse 5) (catch any e (:error e)))", ":kind-mismatch");
}

test "time: nexis.core's inst? and inst-ms know an Instant, through Clojure's Inst protocol" {
    try expectOutput(
        \\[(inst? (nexis.time/now)) (inst? 5) (inst? {:ms 5}) (inst-ms (nexis.time/instant 7))
        \\ (satisfies? Inst (nexis.time/instant 7)) (try (inst-ms 7) (catch any e (:error e)))]
    , "[true false false 7 true :no-protocol-impl]");
    // A record of the program's own extends it as Clojure's types do.
    try expectOutputProgram(
        \\(defrecord Stamp [s] Inst (inst-ms* [_] (* s 1000)))
        \\[(inst? (->Stamp 2)) (inst-ms (->Stamp 2)) (nexis.time/format (inst-ms (->Stamp 2)))]
    , "[true 2000 1970-01-01T00:00:02Z]");
}

test "time: instants, the clock, durations and order" {
    try expectOutput("(nexis.time/inst? (nexis.time/now))", "true");
    try expectOutput("[(nexis.time/inst? 5) (nexis.time/inst? {:ms 5})]", "[false false]");
    try expectOutput("(< 1767225600000 (nexis.time/inst-ms (nexis.time/now)))", "true");
    try expectOutput("(nexis.time/instant 5)", "#nexis.time.Instant{:ms 5}");
    try expectOutput("(let [i (nexis.time/instant 5)] (identical? i (nexis.time/instant i)))", "true");
    try expectOutput("(try (nexis.time/instant :x) (catch any e (ex-message e)))", "instant takes an Instant, an integer or ISO-8601 text, got a keyword");
    try expectOutput("(try (nexis.time/inst-ms \"x\") (catch any e (ex-message e)))", "inst-ms takes an Instant or an integer, got a string");
    try expectOutput(
        \\(nexis.time/format (nexis.time/plus (nexis.time/parse "2026-10-09") (nexis.time/days 1) (nexis.time/hours 1) (nexis.time/minutes 30) (nexis.time/seconds 15) 7))
    , "2026-10-10T01:30:15.007Z");
    try expectOutput("(nexis.time/format (nexis.time/minus 1000 (nexis.time/seconds 2)))", "1969-12-31T23:59:59Z");
    try expectOutput("(nexis.time/between (nexis.time/parse \"2026-10-09\") (nexis.time/parse \"2026-10-08\"))", "-86400000");
    try expectOutput("[(nexis.time/before? 1 (nexis.time/instant 2)) (nexis.time/after? 1 2) (nexis.time/before? 2 2)]", "[true false false]");
    try expectOutput("(map nexis.time/format (sort-by nexis.time/inst-ms [(nexis.time/instant 2000) 1000]))", "(1970-01-01T00:00:01Z 1970-01-01T00:00:02Z)");
}

test "time: Nextomic's instants are epoch milliseconds, which every time function takes" {
    try expectOutputProgramWithStore("time-nextomic",
        \\(def c (nextomic/connect "@STORE@"))
        \\(nextomic/transact! c [{:db/ident :ev/at :db/valueType :db.type/instant :db/cardinality :db.cardinality/one}])
        \\(nextomic/transact! c [{:ev/at (nexis.time/inst-ms (nexis.time/parse "2026-10-09T12:30:15.123Z"))}])
        \\(def at (nextomic/q '[:find ?at . :where [_ :ev/at ?at]] (nextomic/db c)))
        \\(def tx (nextomic/q '[:find (max ?i) . :where [_ :db/txInstant ?i]] (nextomic/db c)))
        \\(nextomic/release c)
        \\[(nexis.time/format at) (nexis.time/inst? (nexis.time/instant tx)) (not (nexis.time/after? tx (nexis.time/now)))]
    , "[2026-10-09T12:30:15.123Z true true]");
}

test "json: read-str reads every JSON value" {
    try expectOutput(
        \\(pr-str (nexis.json/read-str "{\"a\": [1, 2.5, -3e2, true, false, null, \"x\"], \"b\": {}, \"c\": []}"))
    , "{\"a\" [1 2.5 -300.0 true false nil \"x\"], \"b\" {}, \"c\" []}");
    try expectOutput("(nexis.json/read-str \" \\t\\r\\n 42 \\n\")", "42");
    try expectOutput("(pr-str (nexis.json/read-str \"[0, -0, -0.0, 1E2, 1e-2, 0.5e+1]\"))", "[0 0 -0.0 100.0 0.01 5.0]");
    // An integer past a fixnum is a bignum; a float past a double is
    // infinite, as Java's parse makes it.
    try expectOutput("(nexis.json/read-str \"[123456789012345678901234567890, -140737488355329, 1e400]\")", "[123456789012345678901234567890 -140737488355329 ##Inf]");
    try expectOutput("(= (nexis.json/read-str \"1234567890123456789000000000000\") (* 1234567890123456789 1000000000000))", "true");
    // A later duplicate key wins; a small object keeps the document's order.
    try expectOutput("(pr-str (nexis.json/read-str \"{\\\"z\\\": 1, \\\"a\\\": 2, \\\"z\\\": 3}\"))", "{\"z\" 3, \"a\" 2}");
}

test "json: read-str decodes every escape and keeps UTF-8 as it is" {
    try expectOutput("(mapv int (nexis.json/read-str \"\\\"\\\\\\\"\\\\\\\\\\\\/\\\\b\\\\f\\\\n\\\\r\\\\t\\\"\"))", "[34 92 47 8 12 10 13 9]");
    try expectOutput("(nexis.json/read-str \"\\\"h\\\\u00e9llo \\\\uD83D\\\\uDE00 \\u65e5\\\"\")", "h\u{e9}llo \u{1F600} \u{65e5}");
    try expectOutput("(nexis.json/read-str \"\\\"\\\\u0000\\\"\")", "\x00");
}

test "json: read-str takes :key-fn and :value-fn as clojure.data.json does" {
    try expectOutput("(pr-str (nexis.json/read-str \"{\\\"a\\\": 1, \\\"b/c\\\": {\\\"d\\\": 2}}\" :key-fn keyword))", "{:a 1, :b/c {:d 2}}");
    try expectOutput("(pr-str (nexis.json/read-str \"{\\\"a\\\": 1}\" :key-fn nexis.string/upper-case))", "{\"A\" 1}");
    try expectOutput("(pr-str (nexis.json/read-str \"{\\\"a\\\": 1}\" {:key-fn keyword}))", "{:a 1}");
    // value-fn sees each member's key after key-fn, inner objects first;
    // returning value-fn itself drops the member.
    try expectOutput(
        \\(defn vf [k v] (cond (= k :drop) vf (number? v) (* v 10) :else v))
        \\(pr-str (nexis.json/read-str "{\"a\": 1, \"drop\": 2, \"o\": {\"x\": 3, \"drop\": 4}, \"v\": [5]}" :key-fn keyword :value-fn vf))
    , "{:a 10, :o {:x 30}, :v [5]}");
    try expectOutput("(try (nexis.json/read-str \"{\\\"\\\": 1}\" :key-fn keyword) (catch any e (:error e)))", ":invalid-argument");
    try expectOutput("(try (nexis.json/read-str \"1\" :keywordize true) (catch any e (:error e)))", ":invalid-argument");
    try expectOutput("(try (nexis.json/read-str 1) (catch any e (:error e)))", ":kind-mismatch");
    try expectOutput("(try (nexis.json/read-str \"{\\\"a\\\": 1}\" :key-fn (fn [k] (throw :mine))) (catch any e e))", ":mine");
    // A function that grows the root stack past its capacity, which
    // moves it, still has its result kept.
    try expectOutput(
        \\(def deep (str (apply str (repeat 50000 "[")) (apply str (repeat 50000 "]"))))
        \\(defn grow [k] (nexis.json/read-str deep) (keyword k))
        \\(pr-str (nexis.json/read-str "{\"a\": {\"b\": 1}}" :key-fn grow :value-fn (fn [k v] (nexis.json/read-str deep) v)))
    , "{:a {:b 1}}");
}

test "json: malformed text is :json-error, with its line and column" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "", "[1 1 \"JSON: the text ends before its value at line 1, column 1\"]" },
        .{ "  ", "[1 3 \"JSON: the text ends before its value at line 1, column 3\"]" },
        .{ "1 2", "[1 3 \"JSON: text follows the value at line 1, column 3\"]" },
        .{ "[1,]", "[1 4 \"JSON: unexpected ']' at line 1, column 4\"]" },
        .{ "{\\\"a\\\":1,}", "[1 8 \"JSON: expected a string key at line 1, column 8\"]" },
        .{ "{\\\"a\\\" 1}", "[1 6 \"JSON: expected ':' after a key at line 1, column 6\"]" },
        .{ "[1 2]", "[1 4 \"JSON: expected ',' or ']' at line 1, column 4\"]" },
        .{ "{\\\"a\\\":1 \\\"b\\\":2}", "[1 8 \"JSON: expected ',' or '}' at line 1, column 8\"]" },
        .{ "{\\n  \\\"\\u00e9\\\": x}", "[2 8 \"JSON: unexpected 'x' at line 2, column 8\"]" },
        .{ "tru", "[1 1 \"JSON: unexpected 't' at line 1, column 1\"]" },
        .{ "nulls", "[1 5 \"JSON: text follows the value at line 1, column 5\"]" },
        .{ "-", "[1 1 \"JSON: a malformed number at line 1, column 1\"]" },
        .{ "1.", "[1 1 \"JSON: a malformed number at line 1, column 1\"]" },
        .{ "1e+", "[1 1 \"JSON: a malformed number at line 1, column 1\"]" },
        .{ "01", "[1 2 \"JSON: text follows the value at line 1, column 2\"]" },
        .{ "\\\"abc", "[1 5 \"JSON: the text ends inside a string at line 1, column 5\"]" },
        .{ "\\\"a\\nb\\\"", "[1 3 \"JSON: a control character in a string at line 1, column 3\"]" },
        .{ "\\\"\\\\x\\\"", "[1 2 \"JSON: an unknown escape at line 1, column 2\"]" },
        .{ "\\\"\\\\u12g4\\\"", "[1 2 \"JSON: an unknown escape at line 1, column 2\"]" },
        .{ "\\\"\\\\ud800\\\"", "[1 2 \"JSON: a lone surrogate at line 1, column 2\"]" },
        .{ "\\\"\\\\udc00\\\\ud800\\\"", "[1 2 \"JSON: a lone surrogate at line 1, column 2\"]" },
        .{ "[[[", "[1 4 \"JSON: the text ends before its value at line 1, column 4\"]" },
    };
    for (cases) |case| {
        const src = try std.fmt.allocPrint(testing.allocator, "(pr-str (try (nexis.json/read-str \"{s}\") (catch :json-error e [(:line e) (:column e) (ex-message e)])))", .{case[0]});
        defer testing.allocator.free(src);
        try expectOutput(src, case[1]);
    }
}

test "json: nesting deeper than the native stack reads, and writes as :stack-overflow" {
    try expectOutput(
        \\(def deep (nexis.json/read-str (str (apply str (repeat 200000 "[")) (apply str (repeat 200000 "]")))))
        \\[(loop [x deep n 0] (if (seq x) (recur (first x) (inc n)) n)) (try (nexis.json/write-str deep) (catch any e (:error e)))]
    , "[199999 :stack-overflow]");
}

test "json: write-str writes every value nexis.json reads, and more" {
    try expectOutput("(nexis.json/write-str {:a 1 :b [1 2.5 nil true false] :c \"x\"})", "{\"a\":1,\"b\":[1,2.5,null,true,false],\"c\":\"x\"}");
    try expectOutput("(nexis.json/write-str [#{1} '(2) (range 3) (map inc [1]) (sorted-set 3) (i64-vector [4])])", "[[1],[2],[0,1,2],[2],[3],[4]]");
    try expectOutput("(nexis.json/write-str [\\a 'b :c/d 'e/f (sorted-map :b 2 :a 1)])", "[\"a\",\"b\",\"c/d\",\"e/f\",{\"a\":1,\"b\":2}]");
    try expectOutput("(nexis.json/write-str [123456789012345678901234567890 1.0E10 -0.0 0.1 1e-5])", "[123456789012345678901234567890,1.0E10,-0.0,0.1,1.0E-5]");
    try expectOutput("(nexis.json/write-str {1 :a :n/k :b \"s\" :c})", "{\"1\":\"a\",\"n/k\":\"b\",\"s\":\"c\"}");
    try expectOutput("(nexis.json/write-str (nexis.time/parse \"2026-10-09T12:30:15.123Z\"))", "\"2026-10-09T12:30:15.123Z\"");
    try expectOutput("(defrecord P [x]) (nexis.json/write-str (->P 1))", "{\"x\":1}");
    try expectOutput("(nexis.json/write-str \"q\\\"\\\\\\n\\t\\u0001\\u007f/\u{e9}\u{1F600}\")", "\"q\\\"\\\\\\n\\t\\u0001\x7f/\u{e9}\u{1F600}\"");
    try expectOutput("(nexis.json/write-str \"/\u{e9}\u{1F600}\" :escape-unicode true :escape-slash true)", "\"\\/\\u00e9\\ud83d\\ude00\"");
    try expectOutput("(nexis.json/write-str (mapv char [8 12 13]))", "[\"\\b\",\"\\f\",\"\\r\"]");
}

test "json: write-str takes :key-fn, :value-fn and :indent" {
    try expectOutput("(nexis.json/write-str {:n/a 1} :key-fn name)", "{\"a\":1}");
    try expectOutput(
        \\(defn vf [k v] (if (= k :drop) vf (inc v)))
        \\(nexis.json/write-str {:a 1 :drop 2 :b 3} :value-fn vf)
    , "{\"a\":2,\"b\":4}");
    try expectOutput("(nexis.json/write-str {:a 1} :value-fn (fn [k v] (range v)))", "{\"a\":[0]}");
    try expectOutput("(nexis.json/write-str {:a [1 {:b 2}] :c {} :d []} :indent true)",
        \\{
        \\  "a": [
        \\    1,
        \\    {
        \\      "b": 2
        \\    }
        \\  ],
        \\  "c": {},
        \\  "d": []
        \\}
    );
    try expectOutput("(nexis.json/write-str 1 :indent true)", "1");
}

test "json: what JSON cannot hold is :json-error" {
    try expectOutput("(try (nexis.json/write-str ##NaN) (catch :json-error e (ex-message e)))", "JSON: cannot write NaN");
    try expectOutput("(try (nexis.json/write-str [##Inf]) (catch :json-error e (ex-message e)))", "JSON: cannot write Infinity");
    try expectOutput("(try (nexis.json/write-str {nil 1}) (catch :json-error e (ex-message e)))", "JSON: cannot write a nil key");
    try expectOutput("(try (nexis.json/write-str {[1] 1}) (catch :json-error e (ex-message e)))", "JSON: cannot write a key of class vector");
    try expectOutput("(try (nexis.json/write-str {:a 1} :key-fn (fn [k] 1)) (catch :json-error e (ex-message e)))", "JSON: :key-fn returned a value of class fixnum, not a string");
    try expectOutput("(try (nexis.json/write-str inc) (catch :json-error e (ex-message e)))", "JSON: cannot write a value of class native_fn");
    try expectOutput("(try (nexis.json/write-str (atom 1)) (catch :json-error e (ex-message e)))", "JSON: cannot write a value of class atom");
    try expectOutput("(try (nexis.json/write-str 1 :pretty true) (catch any e (:error e)))", ":invalid-argument");
}

test "json: a value written and read back is equal" {
    try expectOutput(
        \\(def x {"s" "h\u00e9 \"q\" \\ /" "n" [0 -1 140737488355328 2.5 -0.0 1.0E300] "m" {"a" {"b" [nil true false []]}} "e" {}})
        \\[(= x (nexis.json/read-str (nexis.json/write-str x)))
        \\ (= x (nexis.json/read-str (nexis.json/write-str x :indent true :escape-unicode true :escape-slash true)))]
    , "[true true]");
}

test "json: read and write go through a file" {
    try expectOutputProgramWithStore("json-file",
        \\[(nexis.json/write {:a [1 2] :b "\u00e9"} "@STORE@" :indent true)
        \\ (slurp "@STORE@")
        \\ (nexis.json/read "@STORE@" :key-fn keyword)]
    ,
        \\[nil {
        \\  "a": [
        \\    1,
        \\    2
        \\  ],
        \\  "b": "é"
        \\} {:a [1 2], :b é}]
    );
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

test "for: lazy, 32 at a time over a chunked innermost source, as Clojure's" {
    // Expected values from babashka.
    try expectOutput("[(take 3 (for [x (range) :when (odd? x)] x)) (let [n (atom 0)] (first (for [x (range 3) y (range 100)] (do (swap! n inc) [x y]))) @n) (for [x (range 3) :while (< x 2) y [:a]] [x y]) (let [n (atom 0)] (first (for [x (range 100)] (do (swap! n inc) x))) @n) (let [n (atom 0)] (first (for [x (range 100) :when (odd? x)] (do (swap! n inc) x))) @n)]", "[(1 3 5) 32 ([0 :a] [1 :a]) 32 16]");
    try expectOutput("[(class (for [x [1]] x)) (take 4 (for [x (range) y (range x)] [x y]))]", "[:lazy_seq ([1 0] [2 0] [2 1] [3 0])]");
    try expectOutput("[(chunked-seq? (seq [1 2])) (chunked-seq? (list 1 2)) (count (chunk-first (seq [1 2 3]))) (nth (chunk-first (seq [1 2 3])) 2) (chunk-rest (seq [1 2])) (chunk-next (seq [1 2])) (let [b (chunk-buffer 2)] (chunk-append b 1) (chunk-append b 2) (chunk-cons (chunk b) (list 3))) (chunked-seq? (map inc [1 2]))]", "[true false 3 3 () nil (1 2 3) false]");
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
    // `dissoc` of a declared field leaves a plain map with the record's
    // metadata, as Clojure's record `without`; of any other key, a record.
    try expectOutputProgram(
        \\(do
        \\  (defrecord Counter [n])
        \\  (let [c (with-meta (->Counter 5) {:m 1})
        \\        c2 (dissoc c :n)
        \\        c3 (dissoc (assoc c :x 1) :x)]
        \\    [(Counter? c2) (record? c2) c2 (meta c2) (Counter? c3) c3 (record? (dissoc c :x :n)) (Counter? (dissoc c :x)) (Counter? (dissoc c :user/n))]))
    , "[false false {} {:m 1} true #user.Counter{:n 5} false true true]");
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
    // The protocol's docstring lands on its Var, and the form's value
    // is the protocol's name, as Clojure's defprotocol returns it.
    try expectOutputProgram("(defprotocol Named \"Things with names.\" (nm [x]))", "Named");
    try expectOutputProgram("(defprotocol Named \"Things with names.\" (nm [x])) [(:doc (meta #'Named)) (:doc (meta #'nm)) (symbol? (defprotocol Q (q [x])))]", "[Things with names. nil true]");
    // A method's arities and docstring land on its Var.
    try expectOutputProgram("(defprotocol Sh (ar [s] [s x] \"Area.\")) (select-keys (meta #'ar) [:doc :arglists :name])", "{:doc Area., :arglists ([s] [s x]), :name ar}");
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
        \\  [(nexis.string/starts-with? (str IFoo) "#<protocol id=") (fn? bar)])
    , "[true true]");
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
    , "{:error :no-protocol-impl, :message no impl of bar for an integer, :fn test-form}");
    // Even when the receiver is a record, no impl means
    // :no-protocol-impl (different dispatch key but same
    // outcome).
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this y]))
        \\  (defrecord Counter [n])
        \\  (try (bar (->Counter 5) 7) (catch any e e)))
    , "{:error :no-protocol-impl, :message no impl of bar for a record, :fn test-form}");
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
    , "{:error :arity-mismatch, :message bar takes at least 1 argument, got 0, :fn test-form}");
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
    , "[1 6 {:error :no-protocol-impl, :message no impl of m for a string, :fn test-form}]");
    try expectOutputProgram(
        \\(defprotocol P (m [s] [s x]))
        \\(defrecord R [a] P (m [this] 1))
        \\(try (m (->R 1) 2) (catch any e e))
    , "{:error :arity-mismatch, :message fn takes 1 argument, got 2, :fn test-form}");
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

test "extend-protocol: :boolean covers both booleans, :map and :set their sorted kinds" {
    // As Clojure's Boolean, IPersistentMap and IPersistentSet do; a
    // later extension of one kind replaces the alias's for that kind.
    try expectOutputProgram(
        \\(defprotocol Sh (sh [x]))
        \\(extend-protocol Sh :boolean (sh [x] [(class x) x]) :map (sh [x] :m) :set (sh [x] :s))
        \\(extend-protocol Sh :sorted_set (sh [x] :sorted))
        \\[(sh true) (sh false) (sh {}) (sh (sorted-map 1 2)) (sh #{}) (sh (sorted-set 1))]
    , "[[:boolean true] [:boolean false] :m :m :s :sorted]");
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

test "extend-protocol and extend-type: nil and Clojure class names, as Clojure code spells them" {
    try expectOutputProgram(
        \\(defprotocol Hello (hi [x]))
        \\(extend-protocol Hello
        \\  nil (hi [_] :nil)
        \\  String (hi [s] [:s s])
        \\  Long (hi [n] [:n n])
        \\  clojure.lang.IPersistentVector (hi [v] :v)
        \\  Boolean (hi [b] [:b b])
        \\  Object (hi [_] :obj))
        \\[(hi nil) (hi "a") (hi 1) (hi 100000000000000000000) (hi [1]) (hi true) (hi false) (hi :k)]
    , "[:nil [:s a] [:n 1] [:n 100000000000000000000] :v [:b true] [:b false] :obj]");
    try expectOutputProgram("(defprotocol Q (q [x])) (extend-type nil Q (q [_] :none)) (q nil)", ":none");
    // Every seq is an ISeq, a lazy seq and a range included; an
    // IPersistentList is a list only, as in Clojure.
    try expectOutputProgram(
        \\(defprotocol S (f [x]) (g [x]))
        \\(extend-protocol S
        \\  clojure.lang.ISeq (f [_] :seq)
        \\  IPersistentList (g [_] :list)
        \\  Object (f [_] :obj) (g [_] :obj))
        \\[(f (list 1)) (f (map inc [1 2])) (f (range 3)) (f (cons 0 (map inc [1]))) (f [1]) (g (list 1)) (g (map inc [1]))]
    , "[:seq :seq :seq :seq :obj :list :obj]");
    // A record the program defines is its name's meaning, though the
    // name is a class's too.
    try expectOutputProgram(
        \\(defprotocol P (f [x]))
        \\(defrecord Symbol [n])
        \\(defrecord Var [n])
        \\(extend-type Symbol P (f [_] :symbol-record))
        \\(extend-protocol P Var (f [_] :var-record) Keyword (f [_] :keyword))
        \\[(f (->Symbol 1)) (f (->Var 1)) (f :k) (try (f 'a) (catch any e e)) (try (f #'f) (catch any e e))]
    , "[:symbol-record :var-record :keyword {:error :no-protocol-impl, :message no impl of f for a symbol, :fn test-form} {:error :no-protocol-impl, :message no impl of f for a var, :fn test-form}]");
    try expectMacroFailure("(defprotocol Q (q [x]))", "(extend-type java.util.Frob Q (q [_] 1))", "java.util.Frob names no record and no class nexis has; extend a kind keyword such as :string", "java.util.Frob");
    try expectMacroFailure("(defprotocol Q (q [x]))", "(extend-protocol Q (q [_] 1))", "a method needs a type before it", "(q [_] 1)");
    try expectMacroFailure("", "(defrecord P [x] Object (toString [_] \"p\"))", "defrecord: Object methods (toString, equals, hashCode) have no meaning here: nexis has no classes", "Object");
}

test "extend-type: a record another namespace defines, by alias, by refer or by its type symbol" {
    const rec = [2][]const u8{ "rec.nx", "(ns rec)\n(defrecord R [a])\n" };
    try expectOutputWithFiles(&.{rec}, "(require '[rec :as r]) (defprotocol P (p [x])) (extend-type r/R P (p [x] (:a x))) (p (r/->R 5))", "5");
    try expectOutputWithFiles(&.{rec}, "(require '[rec :refer [R ->R]]) (defprotocol P (p [x])) (extend-type R P (p [x] (inc (:a x)))) (p (->R 5))", "6");
    try expectOutputWithFiles(&.{rec}, "(require 'rec) (defprotocol P (p [x])) (extend-protocol P rec.R (p [x] (dec (:a x)))) (p (rec/->R 5))", "4");
}

test "extend-protocol with bogus type-kw: :invalid-argument" {
    try expectOutputProgram(
        \\(do
        \\  (defprotocol IFoo (bar [this]))
        \\  (try
        \\    (extend-protocol IFoo
        \\      :no-such-kind (bar [x] :nope))
        \\    (catch any e e)))
    , "{:error :invalid-argument, :message invalid argument, :fn test-form}");
}

test "record internals: a type id no defrecord registered is :invalid-argument" {
    // Qualified, the `#%` names are reachable (FORMS.md §8); each
    // validates what it is given.
    try expectOutput("(try (nexis.internal/#%make-record 99999 {}) (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutput("(try (nexis.internal/#%make-record 99999999999999 {}) (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutput("(try (nexis.internal/#%make-record -1 {}) (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutput("(let [mk (resolve (symbol \"nexis.internal\" \"#%make-record\"))] (try (class (mk 77 {:x 1})) (catch any e e)))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutputProgram(
        \\(defprotocol IFoo (bar [this]))
        \\[(try (nexis.internal/#%extend-record-impl IFoo :bar 4096 (fn [x] x)) (catch any e e))
        \\ (try (nexis.internal/#%extend-record-impl IFoo :bar 99999999999999 (fn [x] x)) (catch any e e))]
    , "[{:error :invalid-argument, :message invalid argument, :fn test-form} {:error :invalid-argument, :message invalid argument, :fn test-form}]");
}

test "defrecord: map->R takes any map and fills an absent field with nil, as Clojure's does" {
    try expectOutputProgram(
        \\(defrecord P [x z])
        \\(defrecord Q [x])
        \\[(map->P (sorted-map :z 2 :x 1)) (map->P nil) (map->P (->Q 5)) (P? (map->P (->Q 5)))
        \\ (try (map->P [1 2]) (catch any e e))]
    , "[#user.P{:x 1, :z 2} #user.P{:x nil, :z nil} #user.P{:x 5, :z nil} true {:error :kind-mismatch, :message kind mismatch, :fn map->P}]");
    try expectOutputProgram("(defrecord P [x z]) (let [p (map->P {:z 1 :w 2})] [(count p) (contains? p :x) (:x p) (= p (->P nil 1)) (= p (assoc (->P nil 1) :w 2))])", "[3 true nil false true]");
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
    // An empty path is the one key nil, as Clojure's up; extra
    // arguments follow the value.
    try expectOutputProgram(
        \\[(update-in {} [] identity) (update-in {:a 1} [] assoc :b 2) (update-in {:a {:b 1}} [:a :b] + 10 100) (update-in nil [:a :b] conj 1)]
    , "[{nil nil} {:a 1, nil {:b 2}} {:a {:b 111}} {:a {:b (1)}}]");
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
        const expected_str = try std.mem.print(&expected_buf, "{d}", .{expected});
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
    try expectOutput("(* 2.0 1e308)", "##Inf");
    try expectOutput("(- ##Inf)", "##-Inf");
    try expectOutput("(- ##Inf ##Inf)", "##NaN");
    try expectOutput("(NaN? (- ##Inf ##Inf))", "true");
    try expectOutput("(NaN? 1.5)", "false");
    try expectOutput("(infinite? (* 1e300 1e300))", "true");
    try expectOutput("(infinite? (/ 1 2))", "false");
    try expectOutput("(let [n ##NaN] [(= n n) (== n n) (< n 1) (> n 1)])", "[true false false false]");
}

test "numbers: / by zero raises for every kind of number; a NaN operand passes through" {
    // Clojure's Numbers.divide(Object, Object): a NaN operand is the
    // result, then any zero divisor raises (SEMANTICS.md §2.2).
    try expectOutput("(map #(try (/ %1 %2) (catch any e e)) [1.0 -1.0 0.0 1 1.0 1 -0.0] [0 0 0.0 0.0 -0.0 0 0])", "({:error :divide-by-zero, :message divide by zero, :fn fn} {:error :divide-by-zero, :message divide by zero, :fn fn} {:error :divide-by-zero, :message divide by zero, :fn fn} {:error :divide-by-zero, :message divide by zero, :fn fn} {:error :divide-by-zero, :message divide by zero, :fn fn} {:error :divide-by-zero, :message divide by zero, :fn fn} {:error :divide-by-zero, :message divide by zero, :fn fn})");
    try expectOutput("[(try (/ 0.0) (catch any e e)) (try (/ 6 2 0.0) (catch any e e)) (try (apply / [1.0 0.0]) (catch any e e)) (let [z 0.0] (try (/ 1.0 z) (catch any e e)))]", "[{:error :divide-by-zero, :message divide by zero, :fn test-form} {:error :divide-by-zero, :message divide by zero, :fn test-form} {:error :divide-by-zero, :message divide by zero, :fn test-form} {:error :divide-by-zero, :message divide by zero, :fn test-form}]");
    try expectOutput("[(NaN? (/ ##NaN 0)) (NaN? (/ ##NaN 0.0)) (NaN? (/ 1.0 ##NaN)) (NaN? (/ 0 ##NaN)) (NaN? (apply / [##NaN 0.0]))]", "[true true true true true]");
    try expectOutput("[(/ ##Inf 2) (/ 1.0 ##Inf) (/ -1 ##Inf) (/ 1.0 1e-320)]", "[##Inf 0.0 -0.0 ##Inf]");
}

test "numbers: the promoting and unchecked operators, num, float, ratio? and rational?" {
    // Every integer operator promotes, so the ' forms are the same functions.
    try expectOutput("[(+' 9223372036854775807 1) (+') (*') (-' 1) (-' 1 2 3) (inc' 1.5) (dec' -9223372036854775808) (*' 4294967296 4294967296)]", "[9223372036854775808 0 1 -1 -4 2.5 -9223372036854775809 18446744073709551616]");
    // The unchecked operators wrap two longs at 64 bits, as Java's do;
    // a float or an integer beyond 64 bits computes as + does.
    try expectOutput("[(unchecked-add 9223372036854775807 1) (unchecked-subtract -9223372036854775808 1) (unchecked-multiply 9223372036854775807 2) (unchecked-inc 9223372036854775807) (unchecked-dec -9223372036854775808) (unchecked-negate -9223372036854775808)]", "[-9223372036854775808 9223372036854775807 -2 -9223372036854775808 9223372036854775807 -9223372036854775808]");
    try expectOutput("[(unchecked-add 1 2) (unchecked-add 1 2.5) (unchecked-add 99999999999999999999 1) (unchecked-multiply 3 -4)]", "[3 3.5 100000000000000000000 -12]");
    try expectOutput("(try (unchecked-add nil 1) (catch any e e))", "{:error :kind-mismatch, :message + expects numbers, got nil, :fn test-form}");
    try expectOutput("[(num 1) (num 1.5) (num nil) (try (num \"a\") (catch any e e))]", "[1 1.5 nil {:error :kind-mismatch, :message num takes a number or nil, got a string, :fn test-form}]");
    try expectOutput("[(float 1) (float 0.5) (NaN? (float ##NaN)) (float -3.4028234663852886E38)]", "[1.0 0.5 true -3.4028234663852886E38]");
    try expectOutput("(map #(try (float %) (catch any e e)) [1e39 -1e39 ##Inf nil \\a \"1\"])", "({:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :invalid-argument, :message invalid argument, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn} {:error :kind-mismatch, :message kind mismatch, :fn fn})");
    try expectOutput("[(ratio? 1) (ratio? 0.5) (ratio? nil) (rational? 1) (rational? 99999999999999999999) (rational? 1.0) (rational? nil)]", "[false false false true true false false]");
}

test "printing: a char past ASCII prints as itself, as Clojure's, and reads back" {
    try expectOutput("(pr-str [\\é \\u{1F980} \\☃ \\a \\u{7F} \\u{0}])", "[\\é \\🦀 \\☃ \\a \\u{7F} \\u{0}]");
    try expectOutput("(let [cs (map char [233 0x80 0xA0 0x2028 0xFEFF 0x10FFFF])] (= cs (read-string (pr-str cs))))", "true");
}

test "numbers: ##Inf, ##-Inf and ##NaN read, print readable and round-trip" {
    try expectOutput("[(= ##Inf (* 2 1e308)) (= ##-Inf (* -2 1e308)) (NaN? ##NaN) (float? ##Inf) (infinite? ##-Inf)]", "[true true true true true]");
    try expectOutput("(pr-str ##Inf ##-Inf ##NaN [1.5 ##Inf] (f64-vector [##-Inf]))", "##Inf ##-Inf ##NaN [1.5 ##Inf] #f64[##-Inf]");
    // str of a bare float is Java's spelling; print and a collection, the reader's.
    try expectOutput("(pr-str [(str ##Inf) (str ##-Inf ##NaN) (str [##Inf]) (format \"%s\" ##NaN) (with-out-str (print ##Inf))])", "[\"Infinity\" \"-InfinityNaN\" \"[##Inf]\" \"NaN\" \"##Inf\"]");
    try expectOutput("(let [v (read-string (pr-str [##Inf ##-Inf ##NaN]))] [(= (pop v) [##Inf ##-Inf]) (NaN? (peek v))])", "[true true]");
    try expectOutput("[(+ ##Inf 1) '##-Inf]", "[##Inf ##-Inf]");
}

test "reader: Clojure's \\uXXXX char and string escapes" {
    try expectOutput("[(= \\u0041 \\A) (= \\u00e9 \\u{E9}) (int \\u2603)]", "[true true 9731]");
    try expectOutput("[(= \"\\u00e9t\\u00E9\" \"été\") (count \"\\uD83D\\uDE00\") (= \"\\uD83D\\uDE00\" \"\\u{1F600}\")]", "[true 1 true]");
    try expectOutput("(try (read-string \"\\\"\\\\uD800\\\"\") (catch :reader-error e :bad))", ":bad");
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
    try expectOutput("(try (/ 1 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (quot 1 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (rem 1.0 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (mod 1 0.0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
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
    try expectOutput("[(try (>) (catch :arity-mismatch _ :arity)) (try (>=) (catch :arity-mismatch _ :arity))]", "[:arity :arity]");
    try expectOutput("(>= 5)", "true");
    try expectOutput("(= 1 1.0)", "false");
    try expectOutput("(== 1 1.0)", "true");
    try expectOutput("(== 1 1 1.0)", "true");
    try expectOutput("(== 1 2)", "false");
    try expectOutput("(not= 1 2)", "true");
    try expectOutput("(not= 1 1)", "false");
    try expectOutput("(not= 1 1.0)", "true");
    try expectOutput("(not= :a :a :a)", "false");
    try expectOutput("(try (< 1 :a) (catch any e e))", "{:error :kind-mismatch, :message < expects numbers, got a keyword, :fn test-form}");
    try expectOutput("(try (> \"a\" 1) (catch any e e))", "{:error :kind-mismatch, :message > expects numbers, got a string, :fn test-form}");
    try expectOutput("(>= nil)", "true");
}

test "numbers: predicates over the tower" {
    try expectOutput("[(number? 1) (number? 1.5) (number? :a) (number? nil)]", "[true true false false]");
    try expectOutput("[(integer? 1) (integer? 1.0) (float? 1.0) (float? 1)]", "[true false true false]");
    try expectOutput("[(zero? 0) (zero? 0.0) (zero? -0.0) (zero? 0.5)]", "[true true true false]");
    try expectOutput("[(pos? 1) (pos? 0.5) (pos? -0.5) (neg? -1) (neg? -0.5) (neg? 0.0)]", "[true true false true true false]");
    try expectOutput("[(even? 2) (odd? 3)]", "[true true]");
    try expectOutput("(try (even? 2.0) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (zero? :a) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "numbers: float equality and hashing agree with SEMANTICS" {
    try expectOutput("(= 0.0 -0.0)", "true");
    try expectOutput("(= 1.5 1.5)", "true");
    try expectOutput("(= 1.5 1.25)", "false");
    try expectOutput("(get {0.0 :zero} -0.0)", ":zero");
    try expectOutput("(get {1 :int} 1.0)", "nil");
    try expectOutput("(let [n ##NaN] (get {n :nan} (- ##Inf ##Inf)))", ":nan");
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
    try expectOutput("(try (:a) (catch any e e))", "{:error :arity-mismatch, :message a keyword takes 1 to 2 arguments, got 0, :fn test-form}");
    try expectOutput("(try (:a {} 1 2) (catch any e e))", "{:error :arity-mismatch, :message a keyword takes 1 to 2 arguments, got 3, :fn test-form}");
    // Nested and in tail position.
    try expectOutput("(:b (:a {:a {:b 2}}))", "2");
    try expectOutput("(-> {:a {:b 3}} :a :b)", "3");
    try expectOutput("(do (defn field [m] (:x m)) (field {:x 7}))", "7");
    try expectOutput("(let [f :a] (f {:a 9}))", "9");
    try expectOutput("(do (defrecord P [x y]) (:y (->P 1 2)))", "2");
    // Every receiver in call position, a map, a record and nil looked
    // up in place and the rest through the general call (VM.md §8).
    try expectOutput("(do (defrecord Q [x]) (let [q (->Q 1) m {:x 2 'y 3}] [(:x q) (:z q :d) (:x m) ('y m) ('z m :d) (:x nil) (:x [1 2]) (:x [1] :d) (:x #{:x}) (:x (sorted-map :x 4)) (:x (transient {:x 5})) ('y #{'y})]))", "[1 :d 2 3 :d nil nil :d :x 4 5 y]");
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

test "map, filter and reduce call their function once per element as a call in place would" {
    // Closures, capturing or not, variadic, throwing and catching,
    // nested, called at every depth of a recursion; keywords and
    // symbols over every receiver; leaf natives past the fixnum range
    // (VM.md §6, "Repeated calls").
    try expectOutput("(let [n 10] [(map (fn [x] (+ x n)) [1 2 3]) (filter (fn [x] (> x n)) [5 15 25]) (reduce (fn [a x] (+ a x n)) 0 [1 2])])", "[(11 12 13) (15 25) 23]");
    try expectOutput("[(map (fn [& xs] xs) [1 2]) (map (fn [x & more] [x more]) [1]) (reduce (fn [& xs] (vec xs)) [1 2 3])]", "[((1) (2)) ([1 nil]) [[1 2] 3]]");
    try expectOutput("[(try (doall (map (fn [x] (throw x)) [1 2])) (catch any e [:caught e])) (map (fn [x] (try (throw x) (catch any e (* e 10)))) [1 2 3])]", "[[:caught 1] (10 20 30)]");
    try expectOutput("[(try (reduce (fn [a x] (if (= x 3) (throw [:at a]) (+ a x))) [1 2 3 4]) (catch any e e)) (filter (fn [x] (try (odd? x) (catch any e false))) [1 2 :a 3])]", "[[:at 3] (1 3)]");
    try expectOutput("(map (fn [xs] (reduce + (map inc (filter odd? xs)))) [[1 2 3] [] [5]])", "(6 0 6)");
    try expectOutput("(do (defn walk [n] (if (zero? n) 0 (reduce + (map (fn [_] (walk (dec n))) [1 2])))) (walk 10))", "0");
    try expectOutput("(do (defrecord R [a]) [(map :a [{:a 1} nil 5 #{:a} [1] (sorted-map :a 2) (->R 3) (transient {:a 4})]) (filter 'a [{'a 1} {} nil #{'a}]) (reduce :a {:a 1} [2])])", "[(1 nil nil :a nil 2 3 4) ({a 1} #{a}) 1]");
    try expectOutput("[(map inc [140737488355327 -1 1.5]) (reduce + [140737488355327 1 2]) (filter even? [140737488355328 3 -2])]", "[(140737488355328 0 2.5) 140737488355330 (140737488355328 -2)]");
    try expectOutput("[(map dec [-140737488355328 0 0.5]) (filter odd? [-3 -2 140737488355329 -140737488355329]) (reduce + [1.5 2]) (apply + [140737488355327 1]) (let [f +] (f -140737488355328 -1)) (map even? [0 -1 -140737488355328])]", "[(-140737488355329 -1 -0.5) (-3 140737488355329 -140737488355329) 3.5 140737488355328 -140737488355329 (true false true)]");
    try expectOutput("[(map {:a 1} [:a :b]) (filter #{2} [1 2]) (map first [[1] [2 3]]) (reduce max [3 9 2]) (reduce conj [] '(1 2))]", "[(1 nil) (2) (1 2) 9 [1 2]]");
}

test "map, filter and reduce walk every shape of list and every seqable" {
    // Cons cells, a view, cons cells onto a view, an empty list, a view
    // at its end, a view carrying metadata and its rest, a built
    // sequence; then the seqables walked out of line (LIST.md §1).
    try expectOutput("(let [v (vec (range 40))] [(reduce + (cons 0 (rest v))) (count (map inc (cons -1 (cons -2 (nthrest v 38))))) (filter odd? (list 1 2 3)) (map inc ()) (map inc (nthrest v 40)) (reduce + (with-meta (seq v) {:m 1})) (reduce + (rest (with-meta (seq v) {:m 1}))) (map inc (take 3 (drop 5 v)))])", "[780 4 (1 3) () () 780 780 (6 7 8)]");
    try expectOutput("(let [v (vec (range 40))] [(filter char? \"ab\") (reduce + (map val {:a 1 :b 2})) (reduce + #{1 2 3}) (map inc (subvec v 38)) (map inc nil) (reduce + (i64-vector [1 2]))])", "[(a b) 3 6 (39 40) () 3]");
}

test "symbol-as-function: a symbol looks itself up as a keyword does" {
    try expectOutput("('a {'a 1 'b 2})", "1");
    try expectOutput("('c {'a 1} :none)", ":none");
    try expectOutput("('a #{'a})", "a");
    try expectOutput("('a 5)", "nil");
    try expectOutput("(map 'x [{'x 1} {'x 2} {}])", "(1 2 nil)");
    try expectOutput("(try ('a) (catch any e e))", "{:error :arity-mismatch, :message a symbol takes 1 to 2 arguments, got 0, :fn test-form}");
}

test "collection-as-function: maps, sets and vectors" {
    try expectOutput("({:a 1} :a)", "1");
    try expectOutput("({:a 1} :b)", "nil");
    try expectOutput("({:a 1} :b :d)", ":d");
    try expectOutput("(#{1 2} 1)", "1");
    try expectOutput("(#{1 2} 3)", "nil");
    try expectOutput("(try (#{1 2} 3 :d) (catch any e e))", "{:error :arity-mismatch, :message a set takes 1 argument, got 2, :fn test-form}");
    try expectOutput("([10 20] 1)", "20");
    try expectOutput("(try ([10 20] 2) (catch any e e))", "{:error :index-out-of-bounds, :message index 2 is out of bounds for a vector of 2, :fn test-form}");
    try expectOutput("(try ([10 20] :a) (catch any e e))", "{:error :kind-mismatch, :message a vector takes an integer index, got a keyword, :fn test-form}");
    try expectOutput("(try ([10 20] 0 :d) (catch any e e))", "{:error :arity-mismatch, :message a vector takes 1 argument, got 2, :fn test-form}");
    try expectOutput("(map {:a 1 :b 2} [:a :b :c])", "(1 2 nil)");
    try expectOutput("(filter #{2 4} [1 2 3 4])", "(2 4)");
    try expectOutput("(let [m {:x 1}] (m :x))", "1");
    try expectOutput("(try (5 1) (catch any e e))", "{:error :not-callable, :message an integer is not callable, :fn test-form}");
    try expectOutput("(try (\"s\" 1) (catch any e e))", "{:error :not-callable, :message a string is not callable, :fn test-form}");
}

test "integration: print writes a float's infinities and NaN as the reader does; str and %s of a bare float keep Java's spelling" {
    try expectOutput("(with-out-str (print ##Inf ##-Inf ##NaN [1.5 ##Inf]))", "##Inf ##-Inf ##NaN [1.5 ##Inf]");
    try expectOutput("(with-out-str (println [##NaN]))", "[##NaN]\n");
    try expectOutput("[(str ##Inf) (str ##-Inf ##NaN) (str [##Inf] 'x ##NaN) (format \"%s\" ##Inf)]", "[Infinity -InfinityNaN [##Inf]xNaN Infinity]");
}

test "integration: defrecord names its type, which instance? takes, and returns it" {
    try expectOutput("(do (defrecord P [a]) [(instance? P (->P 1)) (pr-str P) (symbol? P) (= P (type (->P 1)))])", "[true user.P true true]");
    try expectOutput("(defrecord Q [a])", "user.Q");
}

test "integration: a macro may return a sorted collection; quoted, it is itself; it may be metadata" {
    try expectOutput("(do (defmacro sm [] (sorted-map 2 :b 1 :a)) [(sm) (sorted? (sm))])", "[{1 :a, 2 :b} true]");
    try expectOutput("(let [s (eval (list 'quote (sorted-set 3 1)))] [s (sorted? s)])", "[#{1 3} true]");
    try expectOutput("(let [m (eval (list 'quote {:k (sorted-map :b 2 :a 1)}))] [m (sorted? (:k m))])", "[{:k {:a 1, :b 2}} true]");
    try expectOutput("(do (defmacro sb [] (sorted-set-by > 1 2)) (:error (try (eval '(sb)) (catch any e e))))", ":compile-error");
    try expectOutput("(let [m (meta (with-meta [1] (sorted-map :b 2 :a 1)))] [m (sorted? m)])", "[{:a 1, :b 2} true]");
}

test "integration: a Var calls, and derefs to, the value in force" {
    try expectOutput("[(#'inc 1) ((var +) 1 2 3) (apply #'max [3 9 4]) (map #'inc [1 2])]", "[2 6 9 (2 3)]");
    try expectOutput("(def ^:dynamic *f* inc) (binding [*f* dec] [(#'*f* 10) (@#'*f* 10) (*f* 10)])", "[9 9 9]");
    try expectOutput("(def ^:dynamic *x* 1) (binding [*x* 2] [@#'*x* (deref (var *x*))])", "[2 2]");
    try expectOutput("(declare later) (try (#'later 1) (catch any e e))", "{:error :unbound-var, :message unbound var, :fn test-form}");
    try expectOutput("(def n 5) (try (#'n 1) (catch any e e))", "{:error :not-callable, :message an integer is not callable, :fn test-form}");
    try expectOutput("(def ^:dynamic *u*) [(binding [*u* 3] @#'*u*) (try @#'*u* (catch :unbound-var _ :unbound))]", "[3 :unbound]");
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
        .{ .src = "(try (seq 5) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
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
        .{ .src = "(take 3 (range 0 1 0))", .expected = "(0 0 0)" },
        .{ .src = "(assoc [1 2 3] 1 :x)", .expected = "[1 :x 3]" },
        .{ .src = "(assoc [1 2 3] 3 :end)", .expected = "[1 2 3 :end]" },
        .{ .src = "(try (assoc [1 2 3] 4 :x) (catch any e e))", .expected = "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}" },
        .{ .src = "(try (assoc [1] :k 1) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(assoc {} :a 1 :b 2)", .expected = "{:a 1, :b 2}" },
        .{ .src = "(try (assoc {} :a 1 :b) (catch any e e))", .expected = "{:error :arity-mismatch, :message arity mismatch, :fn test-form}" },
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
        // A padded group ends the partition, as Clojure's does.
        .{ .src = "(partition 3 1 [:p] [1 2 3 4])", .expected = "((1 2 3) (2 3 4) (3 4 :p))" },
        .{ .src = "[(partition 3 1 [] [1 2]) (partitionv 2 1 [:p] [1 2 3])]", .expected = "[((1 2)) ([1 2] [2 3] [3 :p])]" },
        .{ .src = "(partition-all 2 [1 2 3 4 5])", .expected = "((1 2) (3 4) (5))" },
        .{ .src = "(partition-all 2 3 [1 2 3 4 5])", .expected = "((1 2) (4 5))" },
        .{ .src = "(try (partition 0 [1]) (catch any e e))", .expected = "{:error :invalid-argument, :message invalid argument, :fn test-form}" },
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
        .{ .src = "(take 5 (iterate inc 0))", .expected = "(0 1 2 3 4)" },
        .{ .src = "(take 4 (iterate (fn [x] (* 2 x)) 1))", .expected = "(1 2 4 8)" },
        .{ .src = "(take 0 (iterate inc 0))", .expected = "()" },
        // The count is not reserved up front: a callback that throws
        // ends a huge count at once.
        .{ .src = "[(try (doall (repeatedly 9999999999999 #(throw :stop))) (catch :stop e e)) (try (doall (take 9999999999999 (iterate (fn [x] (throw :stop)) 0))) (catch :stop e e))]", .expected = "[:stop :stop]" },
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
        .{ .src = "(try (sort [1 :a]) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
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
        // One candidate is the answer, without a call, as Clojure's.
        .{ .src = "[(max-key count 5) (min-key :k :x)]", .expected = "[5 :x]" },
        .{ .src = "(= (hash [1 2]) (hash '(1 2)))", .expected = "true" },
        .{ .src = "(= (hash 0.0) (hash -0.0))", .expected = "true" },
        .{ .src = "(integer? (hash :a))", .expected = "true" },
    });
}

test "core: sort orders fixnums among every other number, stably, and reports what it cannot order" {
    try runCoreCases(&.{
        .{ .src = "(sort [5 99999999999999999999 -3 2.5 nil 0 -99999999999999999999 -1])", .expected = "(nil -99999999999999999999 -3 -1 0 2.5 5 99999999999999999999)" },
        .{ .src = "(sort [140737488355327 -1 -140737488355328 0 1 140737488355326])", .expected = "(-140737488355328 -1 0 1 140737488355326 140737488355327)" },
        // Equal numbers keep their input order, whatever their kinds.
        .{ .src = "[(sort [1 1.0 0]) (sort [1.0 1 0])]", .expected = "[(0 1 1.0) (0 1.0 1)]" },
        .{ .src = "(map :i (sort-by :k (map (fn [i] {:k (mod i 3) :i i}) (range 9))))", .expected = "(0 3 6 1 4 7 2 5 8)" },
        .{ .src = "(map :i (sort-by :k compare (map (fn [i] {:k (- (mod i 3)) :i i}) (range 9))))", .expected = "(2 5 8 1 4 7 0 3 6)" },
        .{ .src = "(sort compare (range 10 0 -1))", .expected = "(1 2 3 4 5 6 7 8 9 10)" },
        .{ .src = "(try (sort (concat (range 50 0 -1) [\"x\"] (range 50))) (catch :kind-mismatch e :km))", .expected = ":km" },
        .{ .src = "(try (sort-by (fn [i] (if (= i 7) :k i)) (range 20)) (catch :kind-mismatch e :km))", .expected = ":km" },
        .{ .src = "(try (sort (fn [a b] (throw :boom)) [2 1]) (catch :boom e :caught))", .expected = ":caught" },
    });
}

test "core: sort merges in place at every length, stably, by every order and key" {
    try runCoreCases(&.{
        // Every split of the merge up to 69 elements, against a sorted set.
        .{ .src = "(every? (fn [n] (let [xs (map #(mod (* % 7919) 10007) (range n)) want (vec (into (sorted-set) xs))] (= want (sort xs) (sort < xs) (sort compare xs) (sort-by - > xs) (reverse (sort > xs))))) (range 70))", .expected = "true" },
        // Equal keys keep their input order, ascending and descending,
        // against the elements filtered key by key.
        .{ .src = "(every? (fn [n] (let [ms (map (fn [i] {:k (mod (* i 7) 5) :i i}) (range n)) by (fn [ks] (mapcat (fn [k] (filter #(= k (:k %)) ms)) ks))] (and (= (by (range 5)) (sort-by :k ms) (sort-by :k < ms) (sort #(< (:k %1) (:k %2)) ms) (sort-by :i (fn [a b] (< (mod (* a 7) 5) (mod (* b 7) 5))) ms)) (= (by (range 4 -1 -1)) (sort-by :k > ms) (sort #(> (:k %1) (:k %2)) ms))))) (range 70))", .expected = "true" },
        .{ .src = "(every? (fn [n] (let [xs (map (fn [i] (if (even? i) (mod i 5) (double (mod i 5)))) (range n))] (= (mapcat (fn [k] (filter #(== k %) xs)) (range 5)) (sort xs) (sort-by identity xs)))) (range 70))", .expected = "true" },
        .{ .src = "[(sort-by :k [{:k 2} {:k 1}]) (vec (sort (range 40 0 -1))) (conj (sort [3 1 2]) 0) (seq? (sort [2 1])) (sort nil)]", .expected = "[({:k 1} {:k 2}) [1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40] (0 1 2 3) true ()]" },
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
        .{ .src = "[(list? (seq [1 2])) (list? (rest [1 2 3])) (list? (cons 1 ())) (list? (keys {:a 1})) (list? (map inc [1])) (list? (range 3))]", .expected = "[true true true true false false]" },
        .{ .src = "(do (defrecord R [a]) [(ifn? #'inc) (ifn? (var +)) (fn? #'inc) (ifn? (->R 1)) (ifn? (transient []))])", .expected = "[true true false false true]" },
        .{ .src = "(do (defrecord R [a]) [(map? (->R 1)) (coll? (->R 1))])", .expected = "[true true]" },
        .{ .src = "[(true? true) (true? 1) (false? false) (false? nil)]", .expected = "[true false true false]" },
        .{ .src = "(name :abc)", .expected = "abc" },
        .{ .src = "(name 'x/y)", .expected = "y" },
        .{ .src = "(name \"s\")", .expected = "s" },
        .{ .src = "(try (name 1) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
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
        // The count is truncated, as Clojure's (long n).
        .{ .src = "(let [a (atom [])] (dotimes [i 2.5] (swap! a conj i)) @a)", .expected = "[0 1]" },
        .{ .src = "(when-let [x 1] (inc x))", .expected = "2" },
        .{ .src = "(if-let [x nil] x :none)", .expected = ":none" },
    });
}

test "core: cond->, some-> and as-> expand once, to one let chain" {
    // One let binding the gensym to every step but the last, as
    // Clojure's, so expansion grows linearly with the steps.
    try expectOutput("(let [e (macroexpand-1 '(cond-> 1 true inc false dec true inc))] [(count (second e)) (count (filter seq? (second e)))])", "[6 2]");
    try expectOutput("[(count (second (macroexpand-1 '(some-> 1 inc inc inc)))) (count (second (macroexpand-1 '(as-> 1 x (inc x) (inc x)))))]", "[6 4]");
    try expectOutput("(try (eval '(cond-> 1 true)) (catch any e :refused))", ":refused");
    inline for (.{
        .{ "(cond-> 0", " true inc", "4000" },
        .{ "(cond->> 0", " true inc", "4000" },
        .{ "(some-> 0", " inc", "4000" },
        .{ "(some->> 0", " inc", "4000" },
        .{ "(as-> 0 x", " (inc x)", "4000" },
    }) |c| {
        const src = try generated(c[0], c[1], 4000, ")");
        defer testing.allocator.free(src);
        try expectOutput(src, c[2]);
    }
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
    try harness.expectResult(&program, src, try program.run(src), expected);
}

test "native throw: caught by the innermost handler wherever the native runs" {
    try expectThrowingOutput("(try (boom) (catch any e e))", "{:error :boom, :message boom, :fn test-form}");
    try expectThrowingOutput("(try (boom-with {:kind :custom}) (catch any e (:kind e)))", ":custom");
    try expectThrowingOutput("(try (boom-with 42) (catch any e (inc e)))", "43");
    // Through a closure, a higher-order native, apply and nesting.
    try expectThrowingOutput("(try ((fn [] (boom))) (catch any e e))", "{:error :boom, :message boom, :fn fn}");
    try expectThrowingOutput("(try (doall (map (fn [x] (boom-with x)) [1 2])) (catch any e e))", "1");
    try expectThrowingOutput("(try (reduce (fn [a x] (if (= x 3) (boom-with a) (+ a x))) 0 [1 2 3 4]) (catch any e e))", "3");
    try expectThrowingOutput("(try (apply boom []) (catch any e e))", "{:error :boom, :message boom, :fn test-form}");
    try expectThrowingOutput("(try (try (boom) (catch any e (boom-with [:again e]))) (catch any e e))", "[:again {:error :boom, :message boom, :fn test-form}]");
    // finally runs on the way out, and the VM keeps working afterwards.
    try expectThrowingOutput(
        \\(do
        \\  (def log (atom []))
        \\  (def r (try (boom) (catch any e (swap! log conj :caught) e) (finally (swap! log conj :finally))))
        \\  [r @log (+ 1 2)])
    , "[{:error :boom, :message boom, :fn test-form} [:caught :finally] 3]");
    try expectThrowingOutput("(do (defn safe [f] (try (f) (catch any e [:err e]))) [(safe boom) (safe (fn [] :ok))])", "[[:err {:error :boom, :message boom, :fn safe}] :ok]");
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
    try harness.expectResult(&program, src, result, expected);
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
    try testing.expect(std.mem.find(u8, src[sp.pos .. sp.pos + sp.len], "(b n)") != null);
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
    // As Clojure's: nil data is {}, a nil message stays nil, and data
    // that is not a map or a message that is not a string is refused.
    try expectOutputProgram("[(ex-data (ex-info \"x\" nil)) (ex-message (ex-info nil {})) (ex-data (ex-info \"s\" (sorted-map :a 1))) (try (ex-info \"x\" 1) (catch any e e)) (try (ex-info 1 {}) (catch any e e))]", "[{} nil {:a 1} {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
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
    // What follows the first form is never read, so it may not read at
    // all, and costs nothing: a bad first form fails once, not at every
    // later cut of the text.
    try expectOutput("(read-string \"(a) ) \\\"\")", "(a)");
    try expectOutput("(try (read-string (apply str \"{:a 1 :a 2}\" (repeat 100000 \" x\"))) (catch :reader-error e :bad))", ":bad");
    try expectOutput("(try (read-string (apply str \"#_\" (repeat 100000 \" #_\"))) (catch :reader-error e :bad))", ":bad");
    // A `\u{...}` char is one token, never cut short to `\u`.
    try expectOutput("(try (read-string \"\\\\u{110000}\") (catch :reader-error e :bad))", ":bad");
}

test "read-string: an options map's :eof is the value of a string that holds no form" {
    try expectOutput(
        \\[(read-string {:eof :x} "") (read-string {:eof :x} "  ; c\n #_ 1 #_ 'a") (read-string {:eof nil} " ")
        \\ (read-string {:eof :x :other 1} "1 2") (read-string {} "[2]")]
    , "[:x :x nil 1 [2]]");
    // Without :eof, an empty string is a reader error; a form left
    // open, a prefix or metadata with nothing after it is one even
    // with :eof, as in Clojure.
    try expectOutput(
        \\(mapv (fn [s] (try (read-string {:eof :x} s) (catch :reader-error e :bad))) ["(" "'" "^:k" "#_" ")"])
    , "[:bad :bad :bad :bad :bad]");
    try expectOutput(
        \\[(try (read-string {} "") (catch any e e)) (try (read-string 1 "1") (catch any e e)) (try (read-string {:eof 1} 2) (catch any e e))]
    , "[{:error :reader-error, :message reader error, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form} {:error :kind-mismatch, :message kind mismatch, :fn test-form}]");
}

test "edn: nexis.edn/read-string reads one value as data and evaluates nothing" {
    try expectOutput(
        \\(pr-str [(nexis.edn/read-string "{:a [1 2.5 \"s\" \\c sym nil true #{:k}]} ignored")
        \\         (nexis.edn/read-string "(+ 1 2)") (nexis.edn/read-string "") (nexis.edn/read-string nil)
        \\         (nexis.edn/read-string {:eof :done} " ; nothing") (nexis.edn/read-string {:eof :done} nil)])
    , "[{:a [1 2.5 \"s\" \\c sym nil true #{:k}]} (+ 1 2) nil nil :done nil]");
    // No tagged literals: a tag is a reader error whatever :readers says.
    try expectOutput(
        \\[(try (nexis.edn/read-string "#inst \"2020\"") (catch any e e))
        \\ (try (nexis.edn/read-string {:readers {'foo inc}} "#foo 1") (catch any e e))
        \\ (try (nexis.edn/read-string {} "") (catch any e e)) (read-string "[1]")]
    , "[{:error :reader-error, :message reader error, :fn test-form} {:error :reader-error, :message reader error, :fn test-form} {:error :reader-error, :message reader error, :fn test-form} [1]]");
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
    try expectOutput("(let [x 1] (try (eval 'x) (catch :compile-error e (:message e))))", "unable to resolve symbol: x");
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
    // A `do` runs its forms one at a time, as Clojure's eval does:
    // a `def` after an `(ns ...)` binds in that namespace, and a macro
    // body sees a `def` made before it.
    try expectOutputProgram("(eval '(do (ns other) (def w 2))) (ns user) [other/w (resolve 'user/w)]", "[2 nil]");
    try expectOutput("(eval '(do (def k 41) (defmacro mk [] (inc k)) (mk)))", "42");
    try expectOutput("(eval '(do))", "nil");
}

test "eval: a compile error is a catchable map; a throw inside the form is an ordinary throw" {
    // The message is the compiler's sentence, the CompileError's name
    // in words when it has none; :kind is the name.
    try expectOutput("(try (eval '(nope 1)) (catch :compile-error e [(:error e) (:message e) (:form e) (:kind e)]))", "[:compile-error unable to resolve symbol: nope (nope 1) UnresolvedSymbol]");
    try expectOutput("(try (eval '(recur 1)) (catch :compile-error e [(:kind e) (:message e)]))", "[RecurOutsideTail recur outside tail]");
    try expectOutput("(try (eval '(quote)) (catch :compile-error e [(:kind e) (:message e)]))", "[MalformedForm malformed form]");
    try expectOutput("(try (eval '(let* [x] x)) (catch :compile-error e [(:kind e) (:message e)]))", "[MacroExpansionFailure let*: the binding vector needs an even number of forms]");
    try expectOutput("(try (eval (list 'a (fn [] 1))) (catch :compile-error e [(:kind e) (:message e)]))", "[UnsupportedForm unsupported form]");
    try expectOutput("(ex-message (try (eval '(nope)) (catch :compile-error e e)))", "unable to resolve symbol: nope");
    try expectOutput("(ex-message (try (eval '(Math/sqrt 2)) (catch :compile-error e e)))", "unable to resolve symbol: Math/sqrt; nexis has no Java interop: use nexis.math/sqrt (clojure.math/sqrt)");
    try expectOutput("(try (eval '(throw :x)) (catch :x e [:caught e]))", "[:caught :x]");
    try expectOutput("(try (eval '(/ 1 0)) (catch :divide-by-zero e e))", "{:error :divide-by-zero, :message divide by zero, :fn <eval>}");
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
    const out = try program.run("(try (eval '(+ 1 1)) (catch :no-compiler e (:error e)))");
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
        .{ .src = "(pr-str (f64-vector [10000000000.0 ##Inf ##-Inf]))", .expected = "#f64[1.0E10 ##Inf ##-Inf]" },
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
        .{ .src = "(= (f64-vector [##NaN]) (f64-vector [(- ##Inf ##Inf)]))", .expected = "true" },
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
        .{ .src = "(try (i64-vector [1.5]) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (i64-vector [:a]) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (i64-vector [18446744073709551616]) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (f64-vector [\"1\"]) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (i64-vector 5) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (typed-vector-type [1]) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (nth (i64-vector [1]) 1) (catch any e e))", .expected = "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}" },
        .{ .src = "(try (nth (i64-vector [1]) -1) (catch any e e))", .expected = "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}" },
        .{ .src = "(try (nth (f64-vector []) 0) (catch any e e))", .expected = "{:error :index-out-of-bounds, :message index out of bounds, :fn test-form}" },
        .{ .src = "(try (conj (i64-vector [1]) 2) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (assoc (i64-vector [1]) 0 2) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (pop (i64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (peek (i64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (subvec (i64-vector [1]) 0) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (empty (i64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try ((i64-vector [1]) 0) (catch any e e))", .expected = "{:error :not-callable, :message a typed vector is not callable, :fn test-form}" },
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
        .{ .src = "(try (nexis.simd/dot (i64-vector [1]) (f64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (nexis.simd/dot (i64-vector [1]) (i64-vector [1 2])) (catch any e e))", .expected = "{:error :invalid-argument, :message invalid argument, :fn test-form}" },
        .{ .src = "(nexis.simd/dot (i64-vector [4611686018427387904]) (i64-vector [4]))", .expected = "18446744073709551616" },
        .{ .src = "(nexis.simd/dot (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808]) (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808]))", .expected = "340282366920938463463374607431768211456" },
        .{ .src = "(nexis.simd/dot (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808 1]) (i64-vector [-9223372036854775808 -9223372036854775808 -9223372036854775808 -9223372036854775808 -1]))", .expected = "340282366920938463463374607431768211455" },
        .{ .src = "(let [xs (i64-vector [9223372036854775807 -9223372036854775808 3]) ys (i64-vector [9223372036854775807 9223372036854775807 -1])] (= (nexis.simd/dot xs ys) (reduce + (map * xs ys))))", .expected = "true" },
        .{ .src = "(try (nexis.simd/dot [1] (i64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(nexis.simd/scale (i64-vector [1 2 3]) 10)", .expected = "#i64[10 20 30]" },
        .{ .src = "(nexis.simd/scale (f64-vector [1 2 3 4 5]) 0.5)", .expected = "#f64[0.5 1.0 1.5 2.0 2.5]" },
        .{ .src = "(nexis.simd/scale (f64-vector [1 2]) 2)", .expected = "#f64[2.0 4.0]" },
        .{ .src = "(try (nexis.simd/scale (i64-vector [1]) 1.5) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (nexis.simd/scale (i64-vector [4611686018427387904]) 2) (catch any e e))", .expected = "{:error :arithmetic-overflow, :message arithmetic overflow, :fn test-form}" },
        .{ .src = "(nexis.simd/map (fn [x] (* x x)) (i64-vector [1 2 3]))", .expected = "#i64[1 4 9]" },
        .{ .src = "(nexis.simd/map (fn [x] (/ x 2)) (f64-vector [1 2 3]))", .expected = "#f64[0.5 1.0 1.5]" },
        .{ .src = "(nexis.simd/map (fn [x] (/ x 2)) (i64-vector [4 6]))", .expected = "#i64[2 3]" },
        .{ .src = "(nexis.simd/map inc (f64-vector []))", .expected = "#f64[]" },
        .{ .src = "(try (nexis.simd/map (fn [x] (/ x 2)) (i64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (nexis.simd/map str (f64-vector [1])) (catch any e e))", .expected = "{:error :kind-mismatch, :message kind mismatch, :fn test-form}" },
        .{ .src = "(try (nexis.simd/map (fn [x] (throw :inner)) (i64-vector [1])) (catch :inner e :caught))", .expected = ":caught" },
        .{ .src = "(nexis.simd/map (fn [x] (* x 140737488355328)) (i64-vector [1 2]))", .expected = "#i64[140737488355328 281474976710656]" },
    });
}

test "sorted collections: a store round trip through the codec keeps the order; a comparator is unserializable" {
    try expectOutputProgramWithStore("sorted",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def r (db/ref conn :s "k"))
        \\  (with-tx [tx conn] (db/put! tx r {:m (sorted-map "b" 2 "a" 1) :s (sorted-set :z :a/b :c) :c (sorted-map-by compare 2 :b 1 :a)}))
        \\  (def v (with-read-tx [tx conn] (db/get tx r)))
        \\  [(:m v) (sorted? (:m v)) (:s v) (sorted? (:s v)) (:c v) (sorted? (:c v)) (assoc (:m v) "c" 3)
        \\   (try (with-tx [tx conn] (db/put! tx r (sorted-set-by > 1 2))) (catch :unserializable e :unserializable))])
    , "[{a 1, b 2} true #{:c :z :a/b} true {1 :a, 2 :b} true {a 1, b 2, c 3} :unserializable]");
}

test "typed vectors: a store round trip through the codec" {
    try expectOutputProgramWithStore("typed-vectors",
        \\(do
        \\  (def conn (db/open "@STORE@"))
        \\  (def r (db/ref conn :tv "k"))
        \\  (with-tx [tx conn] (db/put! tx r (i64-vector [1 -2 140737488355328])))
        \\  (def i (with-read-tx [tx conn] (db/get tx r)))
        \\  (with-tx [tx conn] (db/put! tx r (f64-vector [0.5 -0.0 ##Inf])))
        \\  (def f (with-read-tx [tx conn] (db/get tx r)))
        \\  [i (typed-vector-type i) (= i (i64-vector [1 -2 140737488355328])) f (typed-vector-type f) (= f (f64-vector [0.5 0.0 ##Inf]))])
    , "[#i64[1 -2 140737488355328] :i64 true #f64[0.5 -0.0 ##Inf] :f64 true]");
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
    program.v.setGcPolicy(.stress);
    const last_result = try program.run(src);
    try testing.expect(program.v.gc_cycles > 0);
    try harness.expectResult(&program, src, last_result, expected);
}

/// Every callback of these programs allocates a few kilobytes of
/// garbage, so a cycle runs inside the native while it holds earlier
/// results, and the results must still be intact afterwards.
const churn = "(defn churn [x] (count (apply str (map (fn [i] (str x i)) (range 200))))) ";

test "gc: a pattern replace keeps its result across the cycles its function's allocations run" {
    try expectOutputUnderGc(churn ++ "(let [s (apply str (repeat 40 \"a1b2 \")) r (nexis.string/replace s #\"([a-z])(\\d)\" (fn [[_ l d]] (churn d) (str d l)))] [(count r) (subs r 0 10)])", "[200 1a2b 1a2b ]");
    try expectOutputUnderGc(churn ++ "(count (re-seq #\"\\d\" (apply str (map (fn [i] (churn i) (str i)) (range 40)))))", "70");
}

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
    try expectOutputUnderGc(churn ++ "(last (take 20 (iterate (fn [s] (churn s) (str s \"x\")) \"\")))", "xxxxxxxxxxxxxxxxxxx");
}

/// A seq of `n` strings whose every step churns the heap: a walk of it
/// collects between any two elements.
const chain = "(defn chain [n] (lazy-seq (churn n) (when (pos? n) (cons (str n) (chain (dec n)))))) (defn ints [n] (lazy-seq (churn n) (when (pos? n) (cons n (ints (dec n)))))) ";

test "gc: a native walking a lazy seq that collects at every step keeps what it built" {
    try expectOutputUnderGc(churn ++ chain ++ "(reduce (fn [acc x] (str acc x)) \"\" (chain 30))", "302928272625242322212019181716151413121110987654321");
    // The same over chunks: the accumulator lives across each step that
    // makes the next chunk.
    try expectOutputUnderGc(churn ++ "(= (reduce (fn [acc x] (str acc x)) \"\" (map (fn [x] (churn x) x) (vec (range 70)))) (apply str (range 70)))", "true");
    try expectOutputUnderGc(churn ++ chain ++ "(let [f (frequencies (map count (chain 30)))] [(f 1) (f 2)])", "[9 21]");
    try expectOutputUnderGc(churn ++ chain ++ zmap ++ "(let [z (zipmap m (chain 40))] [(count z) (count (set (vals z))) (every? vector? (keys z))])", "[40 40 true]");
    try expectOutputUnderGc(churn ++ chain ++ zmap ++ "(let [c (concat m (chain 40))] [(count c) (vector? (first c)) (last c)])", "[80 true 1]");
    try expectOutputUnderGc(churn ++ chain ++ zmap ++ "(let [c (interleave m (chain 40))] [(count c) (vector? (first c)) (second c)])", "[80 true 40]");
    try expectOutputUnderGc(churn ++ chain ++ zmap ++ "(let [p (partition 3 3 (chain 5) m)] [(count p) (vector? (first (first p))) (rest (last p))])", "[14 true (5 4)]");
    try expectOutputUnderGc(churn ++ chain ++ "(let [c (mapcat (fn [i] (chain 3)) (range 10))] [(count c) (first c)])", "[30 3]");
    try expectOutputUnderGc(churn ++ chain ++ zmap ++ "[(count (select-keys m (ints 50))) (count (set (chain 40))) (vec (take 3 (i64-vector (ints 30)))) (count (f64-vector (ints 30))) (count (into [] (chain 40))) (count (vec (chain 40)))]", "[39 40 [30 29 28] 30 40 40]");
    try expectOutputUnderGc(churn ++ chain ++ "[(apply str (chain 12)) (count (sort (chain 40))) (nth (chain 40) 39) (last (chain 40)) (count (reverse (chain 40)))]", "[121110987654321 40 1 1 40]");
    // A body that returns the next block forwards to it: a long run of
    // them costs no native stack, and each block stays reachable.
    try expectOutputUnderGc("(defn skip [n] (lazy-seq (str (range 30)) (if (pos? n) (skip (dec n)) [:end]))) (first (skip 3000))", ":end");
}

test "gc: count, into, vec and take-last keep what they built from a seq that collects at every step" {
    // The elements are strings the steps made, which nothing but the
    // walked chain reaches once the native has consumed it.
    try expectOutputUnderGc(churn ++ chain ++ "[(count (chain 30)) (vec (chain 4)) (into [:x] (chain 3)) (into () (chain 3)) (into nil (chain 3)) (count (into #{} (chain 40))) (into {} (map (fn [s] [s (str s s)])) (chain 3))]", "[30 [4 3 2 1] [:x 3 2 1] (1 2 3) (1 2 3) 40 {3 33, 2 22, 1 11}]");
    try expectOutputUnderGc(churn ++ chain ++ "[(into (sorted-set-by (fn [a b] (churn 1) (compare a b))) (chain 4)) (into [] (map (fn [s] (churn 2) (str s \"!\"))) (chain 3)) (= (set (chain 40)) (set (map str (range 1 41)))) (let [s (chain 3) t s] [(count s) (vec s) (into [] t) (first t)])]", "[#{1 2 3 4} [3! 2! 1!] true [3 [3 2 1] [3 2 1] 3]]");
    try expectOutputUnderGc(churn ++ chain ++ "[(take-last 3 (chain 40)) (count (take-last 50 (chain 40))) (vec (i64-vector (ints 5)))]", "[(3 2 1) 40 [5 4 3 2 1]]");
    // A lazy target realized while a map source's entries, built by
    // the walk, wait to be conj'd onto it.
    try expectOutputUnderGc(churn ++ "(let [m (zipmap (map str (range 40)) (range 40))] (= (set (into (map (fn [x] (churn x) x) [1]) m)) (conj (set m) 1)))", "true");
}

test "gc: reverse, butlast, mapv, filterv, apply, select-keys and nexis.string/join keep what they built from a seq that collects at every step" {
    // The elements are strings the steps made, which nothing but the
    // walked chain reaches once the native has consumed it.
    try expectOutputUnderGc(churn ++ chain ++ "[(reverse (chain 40)) (butlast (chain 40)) (count (butlast (chain 3))) (mapv (fn [s] (churn 1) (str s \"!\")) (chain 3)) (filterv (fn [s] (churn 2) (odd? (count s))) (chain 12)) (nexis.string/join \",\" (chain 5)) (nexis.string/join (map (fn [x] (churn x) (map inc [x x])) (range 3)))]", "[(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40) (40 39 38 37 36 35 34 33 32 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2) 2 [3! 2! 1!] [9 8 7 6 5 4 3 2 1] 5,4,3,2,1 (1 1)(2 2)(3 3)]");
    try expectOutputUnderGc(churn ++ chain ++ "(let [z (zipmap (map str (range 40)) (range 40))] [(= (select-keys z (chain 40)) (dissoc z \"0\")) (select-keys (sorted-map-by (fn [a b] (churn 1) (compare a b)) \"1\" 1 \"2\" 2) (chain 3)) (mapv (fn [a b] (churn 3) (str a b)) (chain 3) (chain 3))])", "[true {2 2, 1 1} [33 22 11]]");
    try expectOutputUnderGc(churn ++ chain ++ "[(apply str (chain 12)) (apply (fn [& xs] (churn 1) (count xs)) (chain 30)) (let [z (zipmap (range 40) (chain 40))] [(count z) (z 0) (z 39)]) (zipmap (chain 3) (chain 3)) (zipmap {:a 1 :b 2} (chain 2))]", "[121110987654321 30 [40 40 1] {3 3, 2 2, 1 1} {[:a 1] 2, [:b 2] 1}]");
}

test "gc: sequence and eduction keep the seq they took of a source that is not one across the transducer's calls" {
    try expectOutputUnderGc(churn ++ "(= (range 100) (vec (sequence (map (fn [x] (churn x) x)) (vec (range 100)))))", "true");
    try expectOutputUnderGc(churn ++ "(= (set (range 40)) (set (sequence (map (fn [x] (churn x) x)) (set (range 40)))))", "true");
    try expectOutputUnderGc(churn ++ "(count (eduction (map (fn [x] (churn x) x)) (filter even?) (set (range 40))))", "20");
    try expectOutputUnderGc(churn ++ "(apply str (sequence (map (fn [c] (churn 1) c)) \"abcdef\"))", "abcdef");
}

test "gc: = and hash realize a lazy key in isolation, with no cycle inside the build" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    program.v.setGcPolicy(.stress);
    _ = try program.run(churn ++ "(def ks (mapv (fn [i] (lazy-seq (churn i) [i (str i)])) (range 20)))");
    const ks = program.registry.current.lookupLocal("ks").?.root;
    const heap = program.v.ensureHeap();
    const saved = program.v.installLazyHost();
    defer nx.lazy.host = saved;
    // Nothing roots the maps built here: no cycle may run while a
    // key's body churns the heap.
    const cycles = program.v.gc_cycles;
    var m = try nx.champ.mapEmpty(heap);
    for (0..20) |i| m = try nx.champ.mapAssoc(heap, m, nx.vector.nth(ks, i), value_mod.fromFixnum(@intCast(i)).?, &nx.dispatch.hashValue, &nx.dispatch.equal);
    try testing.expectEqual(cycles, program.v.gc_cycles);
    try testing.expectEqual(@as(usize, 20), nx.champ.mapCount(m));
    const key = try nx.vector.fromSlice(heap, &.{ value_mod.fromFixnum(13).?, try nx.string.fromBytes(heap, "13") });
    switch (nx.champ.mapGet(m, key, &nx.dispatch.hashValue, &nx.dispatch.equal)) {
        .present => |v| try testing.expectEqual(@as(i64, 13), v.asFixnum()),
        .absent => return error.TestUnexpectedResult,
    }
    try testing.expect(program.v.parked_realize == null);
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

test "gc: group-by and transients built in place keep every group and node across cycles" {
    try expectOutputUnderGc(churn ++ "(let [g (group-by (fn [x] (churn x) (mod x 7)) (range 300))] [(count g) (count (g 3)) (first (g 3)) (last (g 6))])", "[7 43 3 293]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [g (group-by (fn [e] (churn (key e)) (even? (val e))) m)] [(count (g true)) (reduce + (map val (g false)))])", "[20 400]");
    try expectOutputUnderGc(churn ++ "(let [m (persistent! (reduce (fn [t x] (churn x) (assoc! t (str x) [x])) (transient {}) (range 200)))] [(count m) (m \"150\") (m \"7\")])", "[200 [150] [7]]");
    try expectOutputUnderGc(churn ++ "(let [v (persistent! (reduce (fn [t x] (churn x) (conj! t (str x))) (transient []) (range 1100)))] [(count v) (v 0) (v 1099) (v 1056)])", "[1100 0 1099 1056]");
}

/// A comparator that allocates a few kilobytes of garbage per call,
/// so a cycle runs inside every sorted update and lookup.
const by = "(defn by [a b] (churn a) (compare a b)) ";

test "gc: sorted collections under a comparator that collects keep every intermediate and entry" {
    try expectOutputUnderGc(churn ++ by ++ "(let [m (apply sorted-map-by by (interleave (range 40) (map str (range 40))))] [(count m) (first m) (last m) (get m 17) (m 39) (contains? m 40)])", "[40 [0 0] [39 39] 17 39 false]");
    try expectOutputUnderGc(churn ++ by ++ "(let [s (reduce conj (sorted-set-by by) (range 40))] [(count s) (subseq s > 36) (rsubseq s < 3) (subseq s >= 10 < 13)])", "[40 (37 38 39) (2 1 0) (10 11 12)]");
    try expectOutputUnderGc(churn ++ by ++ "(let [m (into (sorted-map-by by) (zipmap (range 30) (map str (range 30))))] [(count m) (last m)])", "[30 [29 29]]");
    try expectOutputUnderGc(churn ++ by ++ "(let [m (conj (sorted-map-by by) {1 (str 2) 3 (str 4)} [5 (str 6)] (zipmap (range 10 20) (map str (range 10 20))))] [(count m) (map val (subseq m < 6))])", "[13 (2 4 6)]");
    try expectOutputUnderGc(churn ++ by ++ "(let [m (apply sorted-map-by by (range 40))] [(count (apply dissoc m (range 0 40 4))) (select-keys m [0 2 4 6]) (count (apply assoc m (range 100 120)))])", "[10 {0 1, 2 3, 4 5, 6 7} 30]");
    try expectOutputUnderGc(churn ++ by ++ "(let [s (apply sorted-set-by by (map str (range 30)))] [(count (apply disj s (map str (range 10)))) (first s) (count (into s (map str (range 25 35))))])", "[20 0 35]");
}

test "gc: swap!, alter-meta!, apply and a closure over a loop survive cycles" {
    try expectOutputUnderGc(churn ++ "(let [a (atom [])] (dotimes [i 40] (swap! a (fn [v] (churn i) (conj v (str i))))) [(count @a) (last @a)])", "[40 39]");
    try expectOutputUnderGc(churn ++ "(def v 1) (dotimes [i 20] (alter-meta! (var v) (fn [m] (churn i) (assoc m :i (str i))))) (:i (meta (var v)))", "19");
    try expectOutputUnderGc(churn ++ "(apply str (map (fn [x] (churn x) (str x)) (range 20)))", "012345678910111213141516171819");
    try expectOutputUnderGc(churn ++ "(let [fs (map (fn [x] (fn [] (churn x) (str x))) (range 20))] (apply str (map (fn [f] (f)) fs)))", "012345678910111213141516171819");
}

/// A callee whose fn-level `recur` walks off its argument: once its
/// slot holds the rest, nothing in the callee reaches the head.
const walk_off = "(defn walk-off [xs] (if (and (seq? xs) (seq xs)) (do (churn 1) (recur (rest xs))) true)) ";

test "gc: what a native passes a callee that recurs over its parameter stays rooted by the native" {
    // GC.md §11.5: the validator drops `swap!`'s new state from its slot.
    try expectOutputUnderGc(churn ++ walk_off ++ "(let [a (atom nil)] (set-validator! a walk-off) (swap! a (fn [_] (list (str \"a\") (str \"b\") (str \"c\")))) (churn 2) @a)", "(a b c)");
    // The first watch drops the old state; the second reads it.
    try expectOutputUnderGc(churn ++ "(let [a (atom (list (str \"a\") (str \"b\"))) seen (atom nil)] (add-watch a :w1 (fn [k r o n] (if (and (seq? o) (seq o)) (do (churn 1) (recur k r (rest o) n)) nil))) (add-watch a :w2 (fn [k r o n] (churn 3) (reset! seen o))) (reset! a :next) (churn 4) @seen)", "(a b)");
    try expectOutputUnderGc(churn ++ "(let [a (atom (list (str \"a\") (str \"b\")))] (add-watch a :w (fn [k r o n] (if (and (seq? o) (seq o)) (do (churn 1) (recur k r (rest o) n)) nil))) (let [p (swap-vals! a (constantly :new))] (churn 2) (first p)))", "(a b)");
    // A map's entries are built by the walk: the native keeps each.
    try expectOutputUnderGc(churn ++ zmap ++ "(let [r (filterv (fn [e] (if (vector? e) (do (churn 1) (recur 0)) true)) m)] (churn 2) [(count r) (reduce + (map key r))])", "[40 780]");
    try expectOutputUnderGc(churn ++ zmap ++ "(let [g (group-by (fn [e] (if (vector? e) (do (churn 1) (recur 0)) :k)) m)] (churn 2) [(count (:k g)) (reduce + (map key (:k g)))])", "[40 780]");
}

test "gc: a local read again after a move keeps its value through cycles (COMPILER.md §4.9)" {
    // An outer local read every iteration of a loop.
    try expectOutputUnderGc(churn ++ "(let [v (vec (map str (range 30)))] (loop [i 0 acc []] (if (< i 30) (recur (inc i) (conj acc (do (churn i) (nth v i)))) (count (apply str acc)))))", "50");
    // A local the body moves and the handler or the finally reads.
    try expectOutputUnderGc(churn ++ "(let [s (list (str \"a\") (str \"b\"))] (try (churn (count s)) (throw :x) (catch any e (churn 1) (apply str s))))", "ab");
    try expectOutputUnderGc(churn ++ "(let [s (list (str \"a\") (str \"b\")) out (atom nil)] (try (churn (count s)) (finally (churn 1) (reset! out (apply str s)))) @out)", "ab");
    // A captured local, moved again in its frame.
    try expectOutputUnderGc(churn ++ "(let [s (list (str \"a\") (str \"b\")) f (fn [] (apply str s))] (churn (count s)) (churn 2) (f))", "ab");
    // A parameter moved into an inner call's block, then the outer's.
    try expectOutputUnderGc(churn ++ "(defn h [f g s] (f s (g s))) (h (fn [a b] (churn 1) (str (apply str a) b)) (fn [a] (churn 2) (count a)) (list (str \"a\") (str \"b\")))", "ab2");
    // A recur whose handler reads the binding the recur rebinds
    // (COMPILER.md §5.6).
    try expectOutputUnderGc(churn ++ "(loop [i 0 a (list (str \"x\"))] (if (< i 3) (recur (inc i) (try (churn i) (throw :boom) (catch any e (cons (str i) a)))) (apply str a)))", "210x");
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
    // thread-bound? takes any number of Vars, all of which must be bound; with none it is true.
    try expectOutputProgram("(def ^:dynamic *x* 1) (def ^:dynamic *y* 2) [(binding [*x* 0] (thread-bound? #'*x* #'*y*)) (binding [*x* 0 *y* 0] (thread-bound? #'*x* #'*y*)) (thread-bound?)]", "[false true true]");
    // bound? counts a binding in force, as Clojure's Var.isBound; with no Vars it is true.
    try expectOutputProgram("(def ^:dynamic *u*) [(bound? #'*u*) (binding [*u* 1] (bound? #'*u*)) (binding [*u* 1] (bound? #'*u* #'inc)) (bound?)]", "[false true true true]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (def ^:dynamic *y* 2) (binding [*x* *y* *y* *x*] [*x* *y*])", "[2 1]");
}

test "binding: a throw through binding restores the root before the catch runs" {
    try expectOutputProgram("(def ^:dynamic *x* 1) (try (binding [*x* 9] (throw :boom)) (catch :boom e [e *x*]))", "[:boom 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (defn boom [] (throw :boom)) [(try (binding [*x* 2] (binding [*x* 3] (boom))) (catch :boom _ *x*)) *x*]", "[1 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) [(binding [*x* 2] (try (binding [*x* 3] (throw :in)) (catch :in _ *x*))) *x*]", "[2 1]");
}

test "binding: only a dynamic Var can be bound; set! rebinds the innermost binding" {
    try expectOutputProgram("(def plain 1) (try (binding [plain 2] plain) (catch :not-dynamic e e))", "{:error :not-dynamic, :message not dynamic, :fn test-form}");
    try expectOutputProgram("(def plain 1) (def ^:dynamic *x* 1) [(try (binding [*x* 2 plain 2] plain) (catch :not-dynamic e e)) (thread-bound? (var *x*))]", "[{:error :not-dynamic, :message not dynamic, :fn test-form} false]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (defn read-x [] *x*) [(binding [*x* 2] (set! *x* 7) (read-x)) *x*]", "[7 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (binding [*x* 2] (binding [*x* 3] (set! *x* 4)) *x*)", "2");
    try expectOutputProgram("(def ^:dynamic *x* 1) (try (set! *x* 5) (catch :no-thread-binding e [e *x*]))", "[{:error :no-thread-binding, :message no thread binding, :fn test-form} 1]");
    try expectOutputProgram("(def plain 1) (try (set! plain 5) (catch :not-dynamic e [e plain]))", "[{:error :not-dynamic, :message not dynamic, :fn test-form} 1]");
    try expectOutputProgram("(def ^:dynamic *x* 1) (meta (var *x*))", "{:dynamic true, :name *x*, :ns user}");
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
    const info = vm.SourceInfo{ .path = "t.nx", .text = "(mapv (fn [x] (/ 1 x)) [1 0])" };
    try testing.expectError(vm.VmError.DivideByZero, runLocated(&program, &info));
    try expectFrame(&program, &info, 0, "fn", 1, 15, "(/ 1 x)");
    try expectFrame(&program, &info, 1, "<top>", 1, 1, "(mapv (fn [x] (/ 1 x)) [1 0])");
}

/// `src` run as `runLocated` runs it, its value printed as the REPL
/// prints it, readably.
fn expectLocatedOutput(src: []const u8, expected: []const u8) !void {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "t.nx", .text = src };
    const out = try runLocated(&program, &info);
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try format_mod.format(out, .readable, &w.writer, program.interner);
    try testing.expectEqualStrings(expected, w.written());
}

test "runtime errors: a caught error is a map of its tag, its message and where it was raised" {
    try expectLocatedOutput("(defn f [x]\n  (+ x \"a\"))\n(try (f 1) (catch any e e))",
        \\{:error :kind-mismatch, :message "+ expects numbers, got a string", :fn "f", :file "t.nx", :line 2, :column 3}
    );
    // With no sentence from the raise site the message is the tag in
    // words; at top level the function is `<top>`.
    try expectLocatedOutput("(try (nth [1] 5) (catch :index-out-of-bounds e e))",
        \\{:error :index-out-of-bounds, :message "index out of bounds", :fn "<top>", :file "t.nx", :line 1, :column 6}
    );
    // A native's own error keyword travels the same way.
    try expectLocatedOutput("(try (with-meta 1 {}) (catch any e e))",
        \\{:error :no-metadata-on-immediate, :message "no metadata on immediate", :fn "<top>", :file "t.nx", :line 1, :column 6}
    );
}

test "runtime errors: a form a user macro was given keeps its own place in the expansion" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "t.nx", .text = "(doseq [x [1]]\n  (inc x)\n  (/ 1 0))" };
    try testing.expectError(vm.VmError.DivideByZero, runLocated(&program, &info));
    try expectFrame(&program, &info, 0, "<top>", 3, 3, "(/ 1 0)");
    try expectLocatedOutput("(defmacro twice [& body] `(do ~@body ~@body))\n(defn f [x]\n  (twice\n    [(+ x \"a\")]))\n(try (f 1) (catch any e [(:line e) (:column e)]))",
        \\[4 6]
    );
}

test "runtime errors: the library's own refusals are error maps with a sentence" {
    try expectLocatedOutput("(try (num \"1\") (catch any e e))",
        \\{:error :kind-mismatch, :message "num takes a number or nil, got a string", :fn "<top>", :file "t.nx", :line 1, :column 6}
    );
    try expectLocatedOutput(
        \\(defmulti m identity)
        \\[(ex-message (try (parse-boolean 1) (catch :kind-mismatch e e)))
        \\ (ex-message (try (instance? "x" 1) (catch :kind-mismatch e e)))
        \\ (ex-message (try (the-ns 'nope) (catch :no-such-namespace e e)))
        \\ (ex-message (try (var-get 1) (catch :kind-mismatch e e)))
        \\ (ex-message (try (methods {}) (catch :kind-mismatch e e)))
        \\ (ex-message (try (make-multifn "m" identity :default {}) (catch :kind-mismatch e e)))
        \\ (ex-message (try (nexis.test/use-fixtures :always identity) (catch :invalid-argument e e)))]
    ,
        \\["parse-boolean takes a string, got an integer" "instance? takes a kind keyword or a record symbol, got a string" "no namespace named nope" "var-get takes a Var, got an integer" "expected a multimethod, got a map" "make-multifn reads its hierarchy through a Var or an atom, got a map" "use-fixtures takes :once or :each, not :always"]
    );
}

test "runtime errors: an error inside a library function is placed at the program's call" {
    try expectLocatedOutput("(defn g [m]\n  (update m :a inc))\n(try (g {:a \"x\"}) (catch any e [(:fn e) (:file e) (:line e) (:column e)]))",
        \\["g" "t.nx" 2 3]
    );
}

test "runtime errors: each place is its own, a handler in a loop included" {
    try expectLocatedOutput("(defn f [x] (/ 1 x))\n(defn g [x]\n  (+ x :a))\n[(try (f 0) (catch any e (:line e))) (try (g 1) (catch any e (:line e))) (try (f 0) (catch any e (:line e))) (mapv (fn [x] (try (f x) (catch any e (:column e)))) [0 0])]",
        \\[1 3 1 [13 13]]
    );
}

test "runtime errors: ex-message, ex-data and ex-cause read a caught error; catch takes it by tag and by class" {
    try expectLocatedOutput("[(try (nth [] 1) (catch :index-out-of-bounds e (ex-message e))) (try (/ 1 0) (catch ArithmeticException e (:error (ex-data e)))) (try (/ 1 0) (catch any e (ex-cause e))) (try (first 1 2) (catch :arity-mismatch e (ex-message e)))]",
        \\["index out of bounds" :divide-by-zero nil "first takes 1 argument, got 2"]
    );
    // An ex-info map's data is its :data; an error map is its own data;
    // any other value has none.
    try expectLocatedOutput("[(ex-data (ex-info \"m\" {:a 1})) (ex-data {:error :x :message \"y\"}) (ex-data {:a 1}) (ex-data :kw) (ex-message {:error :x :message \"y\"})]",
        \\[{:a 1} {:error :x, :message "y"} nil nil "y"]
    );
    // Code that compared the caught value to a keyword reads its tag.
    try expectLocatedOutput("[(= :divide-by-zero (try (/ 1 0) (catch any e e))) (= :divide-by-zero (try (/ 1 0) (catch any e (:error e))))]",
        \\[false true]
    );
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
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
        self.dir_path = try testing.allocator.print(".zig-cache/tmp/{s}", .{self.tmp.sub_path});
        errdefer testing.allocator.free(self.dir_path);
        const io = std.testing.io;
        for (files) |f| {
            const path = try std.Io.Dir.path.join(testing.allocator, &.{ self.dir_path, f[0] });
            defer testing.allocator.free(path);
            if (std.Io.Dir.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(io, parent);
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
    try expectOutputProgram("(ns ex (:refer-clojure :exclude [inc])) [(nexis.core/inc 1) (try (inc 1) (catch any e e))]", "[2 {:error :unbound-var, :message unbound var, :fn test-form}]");
    try expectOutputProgram("(ns ex (:refer-clojure :exclude [inc])) `(inc 1)", "(ex/inc 1)");
    try expectOutputProgram("(ns ex (:refer-clojure)) (inc 1)", "2");
    // Without :exclude, a Var the namespace defines hides a host macro too.
    try expectOutputProgram("(defn when [x] [:mine x]) (when 1)", "[:mine 1]");
    try expectMacroFailure("", "(ns ex (:refer-clojure :only [inc]))", "ns: (:refer-clojure :only ...) is not supported; :exclude is", ":only");
    try expectMacroFailure("", "(ns ex (:refer-clojure :exclude inc))", "ns: :exclude takes a vector of symbols, not a symbol", "inc");
}

test "ns: a name :exclude leaves to the namespace may be referred from another, as in Clojure" {
    const lib = [2][]const u8{ "lib.nx", "(ns lib (:refer-clojure :exclude [+ when]))\n(defn + [a b] (str a b))\n(defmacro when [t x] `(if ~t [:lib ~x]))\n" };
    try expectOutputWithFiles(&.{lib}, "(ns app (:refer-clojure :exclude [+ when]) (:require [lib :refer [+ when]])) [(+ 1 2) (when true 3) (nexis.core/+ 1 2)]", "[12 [:lib 3] 3]");
    try expectOutputWithFiles(&.{lib}, "(ns app (:refer-clojure :exclude [+])) (require '[lib :refer :all]) (+ 1 2)", "12");
    // A Var the namespace defined is still its own: a referral of the
    // name is refused.
    try expectOutputWithFiles(&.{lib}, "(ns app (:refer-clojure :exclude [+])) (defn + [a b] [a b]) (try (eval '(require '[lib :refer [+]])) (catch any e :refused)) (+ 1 2)", "[1 2]");
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

test "require: a file's ns form is found as the reader reads it, comments and discards before it" {
    try expectOutputWithFiles(&.{.{ "appa.nx", "(ns ; the app\n  appa)\n(def x 1)\n" }}, "(require 'appa) appa/x", "1");
    try expectOutputWithFiles(&.{.{ "appb.nx", "#_(old)\n(ns ^{:doc \"b {}\"} appb)\n(def y 2)\n" }}, "(require 'appb) appb/y", "2");
}

test "require: Clojure's library namespaces name nexis's" {
    try expectOutputWithFiles(&.{},
        \\(ns t (:require [clojure.string :as str :refer [trim]] clojure.test))
        \\[(str/upper-case "a") (trim " x ") (clojure.string/lower-case "B") (fn? clojure.test/is)]
    , "[A x b true]");
}

const appc = [2][]const u8{ "app/c.nx", "(ns app.c)\n(defn f [] :c)\n" };
const appd = [2][]const u8{ "app/d.nx", "(ns app.d)\n(defn x [] :x)\n(defn y [] :y)\n" };

test "require: a prefix list names several namespaces under one prefix" {
    try expectOutputWithFiles(&.{ appc, appd },
        \\(ns t (:require [app [c :as cc] [d :refer [x]]]))
        \\[(cc/f) (x) (app.d/y)]
    , "[:c :x :y]");
    try expectOutputWithFiles(&.{ appc, appd }, "(require '(app c [d :as dd])) [(app.c/f) (dd/y)]", "[:c :y]");
    try expectOutputWithFiles(&.{ appc, appd }, "(require '[app c d]) [(app.c/f) (app.d/x)]", "[:c :x]");
    try expectOutputWithFiles(&.{}, "(require '[clojure [string :as s] [set :refer [union]]]) [(s/upper-case \"a\") (union #{1} #{2})]", "[A #{1 2}]");
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
        _ = expand_mod.expandForm(&ctx, form) catch {
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
    // Clojure's rules for prefix lists: no period in a name under a
    // prefix, no prefix list inside another.
    try expectRequireFailure(&.{appc}, "", "(require '[app [c.e :as e]])", "require: c.e is under the prefix app, so it cannot contain a period", "c.e");
    try expectRequireFailure(&.{appc}, "", "(require '[app [c [e]]])", "require: a prefix list cannot hold another", "[c [e]]");
    try expectRequireFailure(&.{appc}, "", "(require '[app 1])", "require: a prefix list holds symbols and vectors, not an integer", "1");
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
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
        .{ .src = "(require 'broken)", .label = "parse error: unclosed `(`", .file = "broken.nx", .line = 2 },
        .{ .src = "(require 'unresolved)", .label = "compile error: unable to resolve symbol: nope", .file = "unresolved.nx", .line = 2 },
        .{ .src = "(require 'cyca)", .label = "require: cyclic require of cyca", .file = "cycb.nx", .line = 2 },
        .{ .src = "(require 'nope)", .label = "require: no file nope.nx on the load path" },
        // A Clojure library nexis lacks says what to use instead.
        .{ .src = "(require '[clojure.java.io :as io])", .label = "require: no file clojure/java/io.nx on the load path; nexis has no clojure.java.io: slurp and spit read and write a file, read-line reads stdin" },
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

test "walk: nexis.walk is Clojure's clojure.walk; records and sorted collections keep their kind" {
    try expectOutputProgram(
        \\(defrecord P [a b])
        \\(def bump (fn [x] (if (number? x) (inc x) x)))
        \\[(nexis.walk/postwalk bump (->P 1 [2 3])) (nexis.walk/postwalk bump (sorted-map-by > 1 2 3 4))
        \\ (nexis.walk/postwalk identity (sorted-set-by > 1 2 3)) (nexis.walk/prewalk bump '(1 (2 #{3})))
        \\ (meta (nexis.walk/postwalk identity (with-meta '(1 2) {:a 1}))) (meta (nexis.walk/prewalk identity (with-meta [1 2] {:a 1})))
        \\ (nexis.walk/walk inc vec [1 2]) (nexis.walk/walk inc identity '(1 2)) (nexis.walk/postwalk bump (i64-vector [1 2]))]
    , "[#user.P{:a 2, :b [3 4]} {4 5, 2 3} #{3 2 1} (2 (3 #{4})) {:a 1} {:a 1} [2 3] (2 3) #i64[1 2]]");
    try expectOutput(
        \\[(nexis.walk/keywordize-keys {"a" {"b" 1} :c [{"d" 2}]}) (nexis.walk/stringify-keys {:a {:b 1} 'c 2})
        \\ (nexis.walk/postwalk-replace {:a :b} [:a {:a :a} '(:a)]) (nexis.walk/prewalk-replace {[1 2] :x} [[1 2] 3])]
    , "[{:a {:b 1}, :c [{:d 2}]} {a {b 1}, c 2} [:b {:b :b} (:b)] [:x 3]]");
    // postwalk visits children before their parent, prewalk the
    // parent first; a map's entries are visited as [k v] vectors.
    try expectOutput("(let [l (atom [])] (nexis.walk/postwalk #(do (swap! l conj %) %) {:a [1]}) @l)", "[:a 1 [1] [:a [1]] {:a [1]}]");
    try expectOutput("(let [l (atom [])] (nexis.walk/prewalk #(do (swap! l conj %) %) {:a [1]}) @l)", "[{:a [1]} [:a [1]] :a [1] 1]");
    try expectOutput("(nexis.walk/macroexpand-all '(when a (-> b c)))", "(if a (do (c b)) nil)");
    // A seq that is not a list (a lazy seq, a range, a cons onto one)
    // keeps its order and its metadata, as Clojure's seq? arm keeps them.
    try expectOutput(
        \\[(nexis.walk/postwalk identity (map inc [1 2 3])) (nexis.walk/postwalk identity (range 3))
        \\ (nexis.walk/postwalk identity (cons 1 (map inc [1 2]))) (nexis.walk/keywordize-keys (map identity [{"a" 1} {"b" 2}]))
        \\ (nexis.walk/postwalk-replace {:a 1} (map identity [:a :b :c])) (nexis.walk/prewalk (fn [x] (if (= x [:a]) (map identity [1 2 3]) x)) [[:a]])
        \\ (meta (nexis.walk/postwalk identity (with-meta (map inc [1]) {:m 1}))) (seq? (nexis.walk/postwalk identity (map inc [1])))]
    , "[(2 3 4) (0 1 2) (1 2 3) ({:a 1} {:b 2}) (1 :b :c) [(1 2 3)] {:m 1} true]");
}

test "require: the clojure.* library names reach the nexis namespaces" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var files: RequireDir = undefined;
    try files.init(&program, &.{});
    defer files.deinit();
    const r = try program.run("(eval '(require '[clojure.string :as s] 'clojure.test '[clojure.walk :as w] '[clojure.edn :as edn] '[clojure.math :as m])) [(eval '(s/join \",\" (clojure.string/split \"a-b\" \"-\"))) (eval '(fn? clojure.test/run-tests)) (eval '(w/postwalk-replace {1 2} [1])) (eval '(edn/read-string \"[:e]\")) (eval '(m/signum -3))]");
    try harness.expectResult(&program, "clojure.string", r, "[a,b true [2] [:e] -1.0]");
    const r2 = try program.run("(eval '(require '[clojure.java.shell :as sh :refer [with-sh-dir]] '[clojure.data.json :as json])) [(eval '(fn? sh/sh)) (eval '(json/write-str {:a [1]})) (eval '(identical? sh/sh nexis.shell/sh))]");
    try harness.expectResult(&program, "clojure.java.shell", r2, "[true {\"a\":[1]} true]");
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
    try testing.expectEqual(vm.VmError.DivideByZero, program.v.traced_error.?);
    program.v.resetAfterError();
    try testing.expectEqual(@as(usize, 1), program.v.frames.items.len);
    // A later failure the run loop never sees (a host callback's) must
    // not report this one.
    try testing.expect(program.v.traced_error == null);
    const result = try program.run("(+ 1 2)");
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "runtime errors: the next form runs after a failed one, and a deep failure's memory goes back" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(vm.VmError.DivideByZero, program.run("(defn f [] (/ 1 0)) (f)"));
    try testing.expect(program.v.frames.items.len > 1);
    try harness.expectResult(&program, "", try program.run("(+ 1 2)"), "3");
    program.v.max_frames = 20_000;
    try testing.expectError(vm.VmError.StackOverflow, program.run("(defn d [n] (inc (d n))) (d 1)"));
    try testing.expect(program.v.frames.capacity >= 20_000);
    program.v.resetAfterError();
    try testing.expect(program.v.frames.capacity < 20_000);
    try testing.expect(program.v.stack.capacity < 20_000);
    try harness.expectResult(&program, "", try program.run("(+ 1 2)"), "3");
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
        \\[4 4 3 1 [FAIL in user/failing-test (wrong): (= 5 (area 2 2)) expected: 5 actual: 4 ; areas multiply FAIL in user/failing-test (wrong): (empty? [1]) expected: true actual: false FAIL in user/throwing-test: (nexis.test/thrown? :boom (+ 1 1)) expected: :boom actual: 2 ERROR in user/erroring-test: :divide-by-zero divide by zero Ran 4 tests containing 7 assertions. 3 failures, 1 errors.]]
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
        \\(reset! nexis.test/counts {:test 0 :pass 0 :fail 0 :error 0})
        \\[(nexis.test/is (= 1 1)) (nexis.test/is (= 1 2)) (nexis.test/is nil) (fn? @(var t))]
    , "[true false false true]");
}

test "nexis.test: is, testing and a deftest called directly work outside a run" {
    // Outside a run an assertion reports and returns but counts
    // nothing; after a run the last test's name is not in force.
    try expectOutputProgram(
        \\(def log (atom []))
        \\(reset! nexis.test/out (fn [line] (swap! log conj line)))
        \\(nexis.test/deftest t (nexis.test/is (= 1 2)) :ran)
        \\(def r (nexis.test/run-tests))
        \\[(nexis.test/is (= 1 1)) (nexis.test/is (= 1 2))
        \\ (nexis.test/testing "ctx" (nexis.test/is (= 1 1)) (nexis.test/is nil))
        \\ (t) @nexis.test/counts (:fail r) @log]
    ,
        \\[true false false :ran nil 1 [FAIL in user/t: (= 1 2) expected: 1 actual: 2 Ran 1 tests containing 1 assertions. 1 failures, 0 errors. FAIL: (= 1 2) expected: 1 actual: 2 FAIL (ctx): nil expected: true actual: nil FAIL: (= 1 2) expected: 1 actual: 2]]
    );
}

test "nexis.test: are substitutes each group of values into its template, as clojure.template does" {
    try expectOutputProgram(
        \\(def log (atom []))
        \\(reset! nexis.test/out (fn [line] (swap! log conj line)))
        \\(nexis.test/deftest t
        \\  (nexis.test/are [x y] (= x (inc y)) 2 1 3 2 5 3)
        \\  (nexis.test/are [s] (string? s) "a" "b"))
        \\(def r (nexis.test/run-tests))
        \\[(:pass r) (:fail r) @log (macroexpand-1 '(nexis.test/are [a b] (= a b) 1 1 2 2)) (nexis.test/are [] true)]
    ,
        \\[4 1 [FAIL in user/t: (= 5 (inc 3)) expected: 5 actual: 4 Ran 1 tests containing 5 assertions. 1 failures, 0 errors.] (do (nexis.test/is (= 1 1)) (nexis.test/is (= 2 2))) nil]
    );
    try expectMacroFailure("", "(nexis.test/are [x y] (= x y) 1 2 3)", "macro are threw The number of args doesn't match are's argv.", "(nexis.test/are [x y] (= x y) 1 2 3)");
}

test "nexis.test: use-fixtures wraps a namespace's run (:once) and each test (:each); successful? reads a summary" {
    try expectOutputProgram(
        \\(def log (atom []))
        \\(reset! nexis.test/out (fn [line] nil))
        \\(nexis.test/deftest a (swap! log conj :a))
        \\(nexis.test/deftest b (swap! log conj :b))
        \\(nexis.test/use-fixtures :once (fn [f] (swap! log conj :once) (f) (swap! log conj :once-end)))
        \\(nexis.test/use-fixtures :each (fn [f] (swap! log conj :outer) (f)) (fn [f] (swap! log conj :inner) (f) (swap! log conj :done)))
        \\(ns other)
        \\(nexis.test/deftest c (swap! user/log conj :c))
        \\(def r (nexis.test/run-all-tests))
        \\[@user/log (:test r) (nexis.test/successful? r) (nexis.test/successful? {:fail 1 :error 0})
        \\ (try (nexis.test/use-fixtures :always identity) (catch any e e))]
    , "[[:once :outer :inner :a :done :outer :inner :b :done :once-end :c] 3 true false {:error :invalid-argument, :message use-fixtures takes :once or :each, not :always, :fn test-form}]");
}

test "nexis.test, nexis.pprint: :refer :all brings the API, not the private helpers" {
    try expectOutputWithFiles(&.{}, "(require '[nexis.test :refer :all]) [(fn? run-tests) (fn? check=) (try (eval 'bump!) (catch any e :unresolved)) (try (eval 'run-namespaces) (catch any e :unresolved))]", "[true true :unresolved :unresolved]");
    try expectOutputWithFiles(&.{}, "(require '[nexis.pprint :refer :all]) [(fn? pprint-str) (try (eval 'layout) (catch any e :unresolved)) (nexis.pprint/pprint-str [1])]", "[true :unresolved [1]]");
}

test "nexis.test: thrown? takes what its catch would take, and a message is evaluated once" {
    try expectOutputProgram(
        \\(def log (atom []))
        \\(reset! nexis.test/out (fn [line] (swap! log conj line)))
        \\(reset! nexis.test/counts {:test 0 :pass 0 :fail 0 :error 0})
        \\(def n (atom 0))
        \\[(nexis.test/is (nexis.test/thrown? :x (throw {:error :x})))
        \\ (nexis.test/is (nexis.test/thrown? :default (throw 1)))
        \\ (nexis.test/is (nexis.test/thrown? Exception (throw 1)))
        \\ (try (nexis.test/is (nexis.test/thrown? :x (throw :y))) (catch any e [:went-on e]))
        \\ (nexis.test/is (= 1 1) (str "m" (swap! n inc)))
        \\ (nexis.test/is (= 1 2) (str "m" (swap! n inc)))
        \\ @n @log @nexis.test/counts]
    , "[true true true [:went-on :y] true false 2 [FAIL: (= 1 2) expected: 1 actual: 2 ; m2] {:test 0, :pass 4, :fail 1, :error 0}]");
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
    // A referred or renamed name qualifies to the namespace that owns
    // its Var, as in Clojure.
    try expectOutputWithFiles(&.{utilns}, "(require '[util :refer [twice half] :rename {half hv}]) [`twice `(hv 1)]", "[util/twice (util/half 1)]");
    try expectOutputWithFiles(&.{}, "(require '[clojure.string :refer [join]]) `join", "nexis.string/join");
}

test "a user macro named like a core macro is the namespace's own" {
    try expectOutputProgram(
        \\(ns my.app)
        \\(defmacro when-let [b & body] :mine)
        \\[(when-let [x 1] x) (nexis.core/when-let [x 1] x)]
    , "[:mine 1]");
}

test "loader: an unresolved symbol whose namespace ends in a period is reported, with no hint" {
    try expectLoadFailure("a./b", "compile error: unable to resolve symbol: a./b", "a./b");
    try expectLoadFailure("(./x 1)", "compile error: unable to resolve symbol: ./x", "./x");
}

test "clojure.core is a permanent name for nexis.core" {
    try expectOutputProgram("(clojure.core/inc 1)", "2");
    try expectOutputProgram("(clojure.core/when true (clojure.core/let [[a] [3]] a))", "3");
    try expectOutputProgram("`clojure.core/inc", "nexis.core/inc");
    try expectOutputProgram(
        \\(ns my.app (:refer-clojure :exclude [get]))
        \\(defn get [m k] :mine)
        \\[(get {} 1) (clojure.core/get {:a 1} :a)]
    , "[:mine 1]");
    try expectOutputWithFiles(&.{}, "(require '[clojure.core :as c]) [(c/inc 1) (c/when true 2)]", "[2 2]");
    try expectOutputWithFiles(&.{}, "(require '[clojure.core :refer [inc]]) (inc 1)", "2");
}

test "defmacro: a lazy result whose realization fails says why, as a failing call does" {
    try expectMacroFailure("(defn g [x] x) (defmacro m [] (lazy-seq [(g)]))", "(m)", "macro m failed: ArityMismatch: g takes 1 argument, got 0", "(m)");
}

test "loader: an unterminated string or regex is reported as one, and as incomplete" {
    try expectLoadFailure("(println \"abc)", "parse error: unterminated string", "\"");
    try expectLoadFailure("(println #\"abc)", "parse error: unterminated regex", "#\"");
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    const info = vm.SourceInfo{ .path = "<test>", .text = "(re-find #\"a" };
    try testing.expectError(error.Diagnosed, program.loader.evalSource(&info, .{ .allocator = program.arena.allocator() }));
    try testing.expect(program.loader.diagnostic.?.incomplete);
}

test "reader: #! is a comment to the end of its line anywhere, as in Clojure" {
    try expectOutputProgram("#!/usr/bin/env nexis\n(+ 1 #! two\n 2)", "3");
    try expectOutputProgram("(read-string \"#!x\\n:k\")", ":k");
}

test "a failed :pre or :post carries the place keys of the condition, as a runtime error does" {
    try expectLoaded("(try ((fn [x] {:pre [(pos? x)]} x) -1) (catch :assertion-failed e [(:message e) (:line e) (:column e)]))", "[Assert failed: (pos? x) 1 22]");
    try expectLoaded("(try ((fn [x]\n {:post [(> % 10)]} x) 3) (catch :assertion-failed e [(:message e) (:line e) (:column e)]))", "[Assert failed: (> % 10) 2 10]");
}

test "macroexpand-1 says why a macro failed" {
    try expectOutputProgram("(defmacro m [] (throw (ex-info \"bad input\" {}))) (try (macroexpand-1 '(m)) (catch :macro-expansion-failure e (:message e)))", "macro m threw bad input");
    try expectOutput("(try (macroexpand-1 '(when)) (catch any e [(:error e) (:message e)]))", "[:macro-expansion-failure when: expected a test]");
}

test "defmacro: a macro returning a native fn names its kind as every message does" {
    try expectMacroFailure("(defmacro m [] +)", "(m)", "a macro returned a function, which is not a form", "(m)");
}

/// What `evalSource` hands the REPL's callbacks: each printed value,
/// realized as the REPL realizes it, and each failure.
const ReplLike = struct {
    program: *Program,
    failures: usize = 0,

    fn value(ctx: *anyopaque, v: value_mod.Value) anyerror!void {
        const self: *ReplLike = @ptrCast(@alignCast(ctx));
        self.program.v.realizeOutside(v) catch return error.RunFailed;
    }

    fn failure(ctx: *anyopaque, _: nx.loader.EvalError) anyerror!void {
        const self: *ReplLike = @ptrCast(@alignCast(ctx));
        self.failures += 1;
        self.program.v.resetAfterError();
    }
};

test "loader: an error realizing a printed value is placed at the form printed" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var repl: ReplLike = .{ .program = &program };
    const src = "1 (map inc \"a\")";
    const info = vm.SourceInfo{ .path = "<test>", .text = src };
    try testing.expectError(error.RunFailed, program.loader.evalSource(&info, .{ .allocator = program.arena.allocator(), .on_value = .{ .ctx = &repl, .call = &ReplLike.value } }));
    const at = program.v.error_trace.items[0];
    try testing.expectEqualStrings("(map inc \"a\")", src[at.span.?.pos..][0..at.span.?.len]);
}

test "loader: with on_failure, a form that fails at run time does not stop the forms after it" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    var repl: ReplLike = .{ .program = &program };
    const src = "(defn f [x] (/ x 0)) (f 1) (map inc \"a\") (+ 1 2)";
    const info = vm.SourceInfo{ .path = "<test>", .text = src };
    const last = try program.loader.evalSource(&info, .{
        .allocator = program.arena.allocator(),
        .on_value = .{ .ctx = &repl, .call = &ReplLike.value },
        .on_failure = .{ .ctx = &repl, .call = &ReplLike.failure },
    });
    try testing.expectEqual(@as(usize, 2), repl.failures);
    try harness.expectResult(&program, src, last, "3");
}

test "letfn: a repeated name is its last binding, everywhere in the form, as in Clojure" {
    try expectOutput("[(letfn [(f [] 1) (f [] 2)] (f)) (letfn [(f [] 1) (g [] (f)) (f [] 2)] (g))]", "[2 2]");
}

test "loader: a defmulti or deftest a file defines later is a forward reference, as a defn is" {
    try expectLoaded("(defn f [x] (area x)) (defmulti area :shape) (defmethod area :sq [m] 1) (f {:shape :sq})", "1");
    try expectLoaded("(require '[nexis.test :refer [deftest]]) (defn g [] (fn? t)) (deftest t) (g)", "true");
}
