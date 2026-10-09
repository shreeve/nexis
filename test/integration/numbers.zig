//! test/integration/numbers.zig — the numeric tower end to end
//! (SEMANTICS.md §2.2, BIGNUM.md §8): fixnum promotion and bignum
//! demotion through every operator and predicate, contagion with
//! f64, and the errors a program can catch.

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
const expectProgramError = harness.expectError;

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
    // An inexact quotient is the nearest double, however far past
    // f64's range the operands are.
    try expectOutput("(let [a (reduce * (repeat 400 10)) b (* 3 (reduce * (repeat 399 10)))] [(/ a b) (/ (- a) b)])", "[3.3333333333333335 -3.3333333333333335]");
    try expectOutput("(/ (+ 1 (reduce * (repeat 400 10))) (reduce * (repeat 100 10)))", "1.0E300");
    try expectOutput("(/ 1 (reduce * (repeat 400 10)))", "0.0");
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
    try expectOutput("(try (/ (+ " ++ fm ++ " 1) 0.0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(float? (* (* " ++ fm ++ " " ++ fm ++ ") 1e300))", "true");
}

test "predicates over bignums" {
    try expectOutput("(let [b (+ " ++ fm ++ " 1)] [(number? b) (integer? b) (float? b)])", "[true true false]");
    try expectOutput("(let [b (* 2 " ++ fm ++ ")] [(even? b) (odd? b) (even? (inc b)) (odd? (inc b))])", "[true false false true]");
    try expectOutput("(let [b (- " ++ fmin ++ " 1)] [(odd? b) (even? b)])", "[true false]");
    try expectOutput("(let [b (+ " ++ fm ++ " 1)] [(pos? b) (neg? b) (zero? b) (pos? (- b)) (neg? (- b))])", "[true false false false true]");
    try expectOutput("(let [b (+ " ++ fm ++ " 1)] [(NaN? b) (infinite? b)])", "[false false]");
}

test "predicates: NaN is neither zero, positive nor negative; negative zero is zero" {
    try expectOutput("(let [n ##NaN] [(zero? n) (pos? n) (neg? n) (NaN? n)])", "[false false false true]");
    try expectOutput("[(zero? -0.0) (pos? -0.0) (neg? -0.0) (zero? 0.0) (pos? 1e-300) (neg? -1e-300)]", "[true false false true true true]");
    try expectOutput("(let [i ##Inf] [(pos? i) (neg? (- i)) (zero? i)])", "[true true false]");
    try expectOutput("(try (zero? nil) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "conversions: long truncates a float toward zero at any size, double widens" {
    try expectOutput("[(long 5) (long 3.99) (long -3.99) (long 0.5) (long -0.5)]", "[5 3 -3 0 0]");
    try expectOutput("(long 18446744073709551616)", "18446744073709551616");
    try expectOutput("(long 1e30)", "1000000000000000019884624838656");
    try expectOutput("(long -1.8446744073709552E19)", "-18446744073709551616");
    try expectOutput("[(long 140737488355328.0) (integer? (long 140737488355328.0)) (= (long 140737488355327.0) 140737488355327)]", "[140737488355328 true true]");
    try expectOutput("[(double 3) (double 1.5) (double 18446744073709551616) (double -140737488355328)]", "[3.0 1.5 1.8446744073709552E19 -1.40737488355328E14]");
    try expectOutput("(float? (double 18446744073709551616))", "true");
    try expectOutput("(long ##NaN)", "0");
    try expectOutput("(try (long ##Inf) (catch any e e))", "{:error :invalid-argument, :message invalid argument, :fn test-form}");
    try expectOutput("(try (long \"7\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectOutput("(try (double nil) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "errors: division by zero and kind mismatch are the catchable keywords" {
    try expectOutput("(try (/ (+ " ++ fm ++ " 1) 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (quot (+ " ++ fm ++ " 1) 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (rem (+ " ++ fm ++ " 1) 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (mod (+ " ++ fm ++ " 1) 0) (catch any e e))", "{:error :divide-by-zero, :message divide by zero, :fn test-form}");
    try expectOutput("(try (+ (+ " ++ fm ++ " 1) :a) (catch any e e))", "{:error :kind-mismatch, :message + expects numbers, got a keyword, :fn test-form}");
    try expectOutput("(try (< (+ " ++ fm ++ " 1) nil) (catch any e e))", "{:error :kind-mismatch, :message < expects numbers, got nil, :fn test-form}");
    try expectOutput("(try (even? 2.0) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
    try expectProgramError("(* (+ " ++ fm ++ " 1) \"x\")", vm.VmError.KindMismatch);
}

test "literals: the least subnormals print as Java's Double.toString does" {
    try expectOutput("[5e-324 4.9E-324 -1e-323 (str 5e-324) (pr-str 1.5e-323)]", "[4.9E-324 4.9E-324 -9.9E-324 4.9E-324 1.5E-323]");
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

const StorePath = harness.Store;

test "codec: bignums round-trip through db/put-key! and db/get-key, alone and inside collections" {
    var store = try StorePath.init("bignum-codec");
    defer store.deinit();
    const src = try testing.allocator.print(
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
    try expectOutput("(try (nexis.math/sqrt :x) (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "nexis.math: floor, ceil and round keep integers and convert floats" {
    try expectOutput("[(nexis.math/floor 7) (nexis.math/ceil 7) (nexis.math/round 7)]", "[7 7 7]");
    try expectOutput("[(nexis.math/floor 2.7) (nexis.math/ceil 2.2) (nexis.math/floor -2.2) (nexis.math/ceil -2.7)]", "[2.0 3.0 -3.0 -2.0]");
    try expectOutput("[(nexis.math/round 2.5) (nexis.math/round 2.4) (nexis.math/round -2.5) (nexis.math/round -2.6)]", "[3 2 -2 -3]");
    // Java's Math/round: past the long range the result clamps, and NaN is 0.
    try expectOutput("[(nexis.math/round 1.0E20) (nexis.math/round -1.0E20) (nexis.math/round 9.2233720368547758E18) (nexis.math/round ##NaN) (nexis.math/round ##Inf) (nexis.math/round ##-Inf)]", "[9223372036854775807 -9223372036854775808 9223372036854775807 0 9223372036854775807 -9223372036854775808]");
    try expectOutput("(nexis.math/floor 100000000000000000000)", "100000000000000000000");
    try expectOutput("(integer? (nexis.math/round 2.5))", "true");
}

test "nexis.math: PI and E" {
    try expectOutput("nexis.math/PI", "3.141592653589793");
    try expectOutput("nexis.math/E", "2.718281828459045");
    try expectOutput("(nexis.math/round (* 2 nexis.math/PI))", "6");
}

test "nexis.math: the trigonometric, hyperbolic, exponential and logarithmic functions are Java's Math" {
    try expectOutput(
        \\[(nexis.math/sin 0) (nexis.math/cos 0) (nexis.math/tan 0) (nexis.math/asin 1) (nexis.math/acos 1) (nexis.math/atan 1) (nexis.math/atan2 1 1) (nexis.math/atan2 0.0 -0.0)
        \\ (nexis.math/sinh 0) (nexis.math/cosh 0) (nexis.math/tanh 0) (nexis.math/tanh ##Inf) (nexis.math/exp 0) (nexis.math/expm1 0) (nexis.math/log 1) (nexis.math/log10 1000)
        \\ (nexis.math/log1p 0) (nexis.math/cbrt 27) (nexis.math/cbrt -8) (nexis.math/hypot 3 4)]
    , "[0.0 1.0 0.0 1.5707963267948966 0.0 0.7853981633974483 0.7853981633974483 3.141592653589793 0.0 1.0 0.0 1.0 1.0 0.0 0.0 3.0 0.0 3.0 -2.0 5.0]");
    try expectOutput(
        \\[(nexis.math/sin 1) (nexis.math/cos 1) (nexis.math/tan 1) (nexis.math/acos 0.5) (nexis.math/atan2 1 2)
        \\ (nexis.math/sinh 1) (nexis.math/cosh 1) (nexis.math/tanh 1) (nexis.math/log 10) (nexis.math/log 2)
        \\ (nexis.math/exp 2) (nexis.math/cbrt 2) (nexis.math/expm1 1.0E-10) (nexis.math/log1p 1.0E-10)]
    , "[0.8414709848078965 0.5403023058681398 1.5574077246549023 1.0471975511965979 0.4636476090008061 1.1752011936438014 1.543080634815244 0.7615941559557649 2.302585092994046 0.6931471805599453 7.38905609893065 1.2599210498948732 1.00000000005E-10 9.999999999500001E-11]");
    // NaN and the infinities as Java gives them: no error.
    try expectOutput(
        \\[(nexis.math/log 0) (nexis.math/log -1) (nexis.math/asin 2) (nexis.math/sin ##Inf) (nexis.math/exp 1000)
        \\ (nexis.math/hypot ##Inf ##NaN) (nexis.math/sinh 1000) (nexis.math/log10 0)]
    , "[##-Inf ##NaN ##NaN ##NaN ##Inf ##Inf ##Inf ##-Inf]");
    try expectOutput("(try (nexis.math/sin \"a\") (catch any e e))", "{:error :kind-mismatch, :message kind mismatch, :fn test-form}");
}

test "nexis.math: signum, to-radians, to-degrees, floor-div and floor-mod" {
    try expectOutput("[(nexis.math/signum -2.5) (nexis.math/signum 3) (nexis.math/signum 0) (nexis.math/signum -0.0) (NaN? (nexis.math/signum ##NaN))]", "[-1.0 1.0 0.0 -0.0 true]");
    try expectOutput("[(nexis.math/to-radians 180) (nexis.math/to-degrees nexis.math/PI) (nexis.math/to-degrees 1) (nexis.math/to-radians 1)]", "[3.141592653589793 180.0 57.29577951308232 0.017453292519943295]");
    // Of longs, as Java's Math/floorDiv: a float is truncated first.
    try expectOutput("[(nexis.math/floor-div 7 2) (nexis.math/floor-div -7 2) (nexis.math/floor-div 7 -2) (nexis.math/floor-div -7 -2) (nexis.math/floor-div 7.9 2)]", "[3 -4 -4 3 3]");
    try expectOutput("[(nexis.math/floor-mod -7 2) (nexis.math/floor-mod 7 -2) (nexis.math/floor-mod 7 2) (nexis.math/floor-div 100000000000000000001 -2)]", "[1 -1 1 -50000000000000000001]");
    try expectOutput("[(try (nexis.math/floor-div 1 0) (catch any e e)) (try (nexis.math/floor-mod 1 0) (catch any e e))]", "[{:error :divide-by-zero, :message divide by zero, :fn test-form} {:error :divide-by-zero, :message divide by zero, :fn test-form}]");
    // Java's Long/MIN_VALUE by -1 wraps there; every integer operator promotes here.
    try expectOutput("(nexis.math/floor-div -9223372036854775808 -1)", "9223372036854775808");
}
