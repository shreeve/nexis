//! test/integration/runtime_polish.zig — end-to-end pins for the
//! Clojure-fidelity rules of the sequence library, records as
//! maps, and the one policy for an uncaught keyword throw raised
//! by a native.

const std = @import("std");
const nx = @import("nexis");
const vm = nx.vm;
const compile = nx.compile;
const stdlib = nx.stdlib;
const harness = @import("harness");

const testing = std.testing;

const Program = harness.Program;
const expectOutput = harness.expectOutput;
const expectCheckedOutput = harness.expectCheckedOutput;
const expectError = harness.expectError;
const StorePath = harness.Store;

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

// ---- def anywhere in a form declares its name ----

test "a def nested in let, when or a call is declared before its use" {
    try expectCheckedOutput(
        \\[(let [] (def y 2) y)
        \\ (when true (def z 3) z)
        \\ (str (do (def x 1) x))
        \\ (+ x y z)]
    , "[2 3 1 6]");
}

test "a quoted def declares nothing" {
    var program: Program = undefined;
    try program.init();
    defer program.deinit();
    try testing.expectError(compile.CompileError.UnresolvedSymbol, program.runChecked("(do '(def hidden 1) hidden)", null));
}

// ---- floored mod for floats ----

test "mod on floats takes the sign of the divisor" {
    try expectOutput(
        \\[(mod 7.5 -2) (mod 5.5 -2) (mod 5 -1.5) (mod -7.5 2) (mod 7.5 2) (mod -7 3) (mod 7 -3) (mod 6.0 -2)]
    , "[-0.5 -0.5 -1.0 0.5 1.5 2 -2 0.0]");
}

// ---- keyword / symbol construction ----

test "keyword and symbol refuse an empty name catchably and take a namespace" {
    try expectOutput(
        \\[(try (keyword "") (catch any e e))
        \\ (try (symbol "") (catch any e e))
        \\ (keyword "a" "b") (symbol "a" "b") (keyword nil "b")
        \\ (namespace (keyword "a" "b")) (name (symbol "a" "b"))]
    , "[:invalid-argument :invalid-argument :a/b a/b :b a b]");
}

// ---- vectors grow and update by path copy ----

test "conj and assoc on a vector share structure and stay fast" {
    try expectOutput(
        \\(def v (loop [i 0 v []] (if (< i 20000) (recur (inc i) (conj v i)) v)))
        \\(def w (assoc v 5 :a 1000 :b 19999 :c))
        \\[(count v) (nth v 19999) (count w) (nth w 5) (nth w 1000) (nth w 19999) (nth v 5) (nth v 1000)
        \\ (assoc [1 2] 2 3) (conj [1] 2 3)]
    , "[20000 19999 20000 :a :b :c 5 1000 [1 2 3] [1 2 3]]");
}

// ---- merge ----

test "merge of empty maps is a map, merge of nothing is nil" {
    try expectOutput(
        \\(defrecord R [a])
        \\(def m (merge {:a 1} nil {:a 2 :b 3}))
        \\[(merge {}) (merge {} {}) (merge) (merge nil) (merge nil {:a 1}) (count m) (:a m) (:b m)
        \\ (R? (merge (->R 1) {:b 2})) (:b (merge (->R 1) {:b 2}))]
    , "[{} {} nil nil {:a 1} 2 2 3 true 2]");
}

// ---- small Clojure conveniences ----

test "set, subvec, identical?, keys/vals of {}, max/min operands, strings under get and contains?" {
    try expectOutput(
        \\[(count (set [1 1 2])) (set? (set '(1 2))) (set nil)
        \\ (subvec [1 2 3 4] 1 3) (subvec [1 2 3] 1) (subvec [1 2] 2) (try (subvec [1 2] 1 3) (catch any e e))
        \\ (identical? :a :a) (identical? [1] [1]) (identical? 1 1) (identical? nil nil)
        \\ (keys {}) (vals {}) (keys nil) (count (keys {:a 1}))
        \\ (max 2 1.0) (max 1 2.0) (min 2 1.0) (min 2.0 1) (max 1 1.0) (min 0.0 -0.0)
        \\ (get "ab" 1) (get "ab" 5) (get "ab" -1 :d) (get "ab" :k) (contains? "ab" 0) (contains? "ab" 2)]
    , "[2 true #{} [2 3] [2 3] [] :index-out-of-bounds true false true true nil nil nil 1 2 2.0 1.0 1 1.0 -0.0 b nil :d nil true false]");
}
