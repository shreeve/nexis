// =============================================================================
// src/stdlib.zig — the native standard library
// =============================================================================
//
// Host-Zig functions exposed as first-class `Value`s of kind
// `.native_fn`, one table per namespace (`core_natives`,
// `db_natives`, `string_natives`, `math_natives`, `internal_natives`,
// `simd_natives`; Nextomic's are in src/nextomic/natives.zig). The
// rest of the library is written in nexis (`src/stdlib/*.nx`,
// embedded below) on top of these.
//
// Every native declares its arity in its descriptor and the VM
// enforces it; a native never indexes `args` past its declared
// minimum. Any seqable receiver goes through `makeSeqIter`, so
// nil, lists, vectors, typed vectors, maps, records, Nextomic
// entities, sets (hash or sorted) and strings behave the same way in
// every sequence function. Arithmetic delegates to the VM's numeric
// tower. nil is the empty sequence, as in Clojure:
//   (first nil)   => nil
//   (rest nil)    => ()
//   (count nil)   => 0
//   (empty? nil)  => true
//
// Natives are visible to runtime and compile-time macro eval
// alike because `routine.var_table` resolves to the same Var
// regardless of which VM evaluates it.

const std = @import("std");
const value_mod = @import("value.zig");
const vm_mod = @import("vm.zig");
const list_mod = @import("coll/list.zig");
const lazy_mod = @import("coll/lazy.zig");
const seq_mod = @import("seq.zig");
const vector_mod = @import("coll/vector.zig");
const typed_vector_mod = @import("coll/typed_vector.zig");
const bignum_mod = @import("bignum.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const intern_mod = @import("intern.zig");
const db_mod = @import("db.zig");
const codec_mod = @import("codec.zig");
const heap_mod = @import("heap.zig");
const dispatch_mod = @import("dispatch.zig");
const atom_mod = @import("atom.zig");
const string_mod = @import("string.zig");
const regex_mod = @import("regex.zig");
const format_mod = @import("format.zig");
const record_mod = @import("record.zig");
const protocol_mod = @import("protocol.zig");
const nextomic_mod = @import("nextomic/root.zig");
const transient_mod = @import("coll/transient.zig");
const loader_mod = @import("loader.zig");
const image_mod = @import("image.zig");
const expand_mod = @import("expand.zig");
const reader_mod = @import("reader.zig");
const stack = @import("stack.zig");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const VM = vm_mod.VM;
const NativeFn = vm_mod.NativeFn;
const Namespace = vm_mod.Namespace;
const VmError = vm_mod.VmError;

// =============================================================================
// Installation
// =============================================================================
//
// One table per namespace: each native's name, arity and function,
// once, and `.leaf` after a leaf (`NativeFn.leaf`: arithmetic,
// predicates and lookups over the arguments alone, none calling back,
// comparing or hashing nested data; a bignum one makes is a fresh
// block, and `Heap.alloc` never collects, VM.md §9), and after that
// the full body when the leaf body refuses some receivers with
// `NeedsReentry` (`NativeFn.general`); `.consumes` after a native that
// consumes its last argument (`NativeFn.consumes`), and
// `.consuming_leaf` after a leaf whose full body does. The row ends
// with two strings, the native's arglists as `doc` prints them and its
// docstring (`Doc`, STDLIB.md §10). `table` turns it into static
// descriptors (immortal, so a `.native_fn` Value can point at one); a
// descriptor outside nexis.core is named `ns/name` for traces and
// printing. `docs` turns it into the parallel array of `Doc`s.

fn table(comptime ns: []const u8, comptime entries: anytype) [entries.len]NativeFn {
    var out: [entries.len]NativeFn = undefined;
    inline for (entries, 0..) |e, i| {
        out[i] = .{
            .name = if (ns.len == 0) e[0] else ns ++ "/" ++ e[0],
            .min_arity = e[1],
            .max_arity = e[2],
            .call = e[3],
        };
        inline for (4..e.len) |j| switch (@TypeOf(e[j])) {
            @TypeOf(.enum_literal) => {
                out[i].leaf = e[j] == .leaf or e[j] == .consuming_leaf;
                out[i].consumes = e[j] == .consumes or e[j] == .consuming_leaf;
            },
            *const fn (*VM, []const Value) VmError!Value => out[i].general = e[j],
            else => {},
        };
    }
    return out;
}

/// What `doc` prints of a native beside its name: `arglists`, the
/// text of its `:arglists` list (`([coll] [n coll])`), and `doc`, its
/// docstring. They live in the binary, not the stdlib image, and a
/// native's Var gets its metadata from them the first time `meta`
/// asks for it (`nativeVarMeta`).
pub const Doc = struct { arglists: []const u8 = "", doc: []const u8 = "" };

fn docs(comptime entries: anytype) [entries.len]Doc {
    @setEvalBranchQuota(100 * entries.len + 1000);
    var out: [entries.len]Doc = undefined;
    inline for (entries, 0..) |e, i| {
        var strings: [2][]const u8 = .{ "", "" };
        var n: usize = 0;
        inline for (4..e.len) |j| if (@typeInfo(@TypeOf(e[j])) == .pointer and @typeInfo(@typeInfo(@TypeOf(e[j])).pointer.child) == .array) {
            strings[n] = e[j];
            n += 1;
        };
        out[i] = .{ .arglists = if (n == 2) "(" ++ strings[0] ++ ")" else "", .doc = strings[1] };
    }
    return out;
}

/// Bind every native of `natives` as a Var of `ns` under its name
/// without the namespace prefix. Re-installing replaces the root and
/// leaves the Var's flags alone.
fn installTable(ns: *Namespace, natives: []const NativeFn) !void {
    for (natives) |*d| {
        const qualified = ns.name.len > 0 and d.name.len > ns.name.len and d.name[ns.name.len] == '/' and std.mem.startsWith(u8, d.name, ns.name);
        const bare = if (qualified)
            d.name[ns.name.len + 1 ..]
        else
            d.name;
        const v = try ns.intern(bare);
        v.root = vm_mod.nativeFnValue(d);
        v.bound = true;
    }
}

/// Install the nexis.core natives into `ns`, and the `nexis.simd`
/// kernels (docs/TYPED_VECTOR.md §7.2) into the registry that owns
/// `ns`, if any.
pub fn installCore(ns: *Namespace) !void {
    vm_mod.lazy_ops = &seq_mod.ops;
    seq_mod.entity_map = &nextomic_mod.natives.entityMap;
    try installTable(ns, &core_natives);
    if (ns.registry) |registry| try installTable(try registry.getOrCreate("nexis.simd", ns), &simd_natives);
}

/// Install every namespace of the standard library into the
/// loader's registry, load the embedded sources' image into theirs
/// (or boot the sources when this build has no image of them), and
/// mark each namespace there loaded, so a `require` of one only
/// aliases it (docs/STDLIB.md §1). The CLI and the test harness boot
/// through here. A failure is a bug in an embedded source or the
/// image; `loader.diagnostic` says where a source failed.
pub fn boot(loader: *loader_mod.Loader) !void {
    return bootFrom(loader, image);
}

/// `boot` from the image `bytes`, or from the sources when `bytes`
/// is no image of them.
pub fn bootFrom(loader: *loader_mod.Loader, bytes: []const u8) !void {
    try installNatives(loader.registry);
    if (image_mod.matches(bytes, &embedded)) {
        const counted = try image_mod.load(loader.vm, bytes, &embedded);
        expand_mod.gensym_counter += counted.auto_gensyms;
        gensym_next += counted.gensyms;
    } else try bootSources(loader);
    try markLoaded(loader);
}

/// Boot the embedded sources as `boot` does, then return the image of
/// what they left (`image_mod.write`), or fail with `why` saying what
/// it cannot carry. The build's image generator calls this.
pub fn writeImage(loader: *loader_mod.Loader, gpa: std.mem.Allocator, why: *[]const u8) ![]u8 {
    try installNatives(loader.registry);
    var natives = try image_mod.NativeIndex.scan(gpa, loader.registry);
    defer natives.deinit(gpa);
    const before: image_mod.Counted = .{ .auto_gensyms = expand_mod.gensym_counter, .gensyms = gensym_next };
    try bootSources(loader);
    try markLoaded(loader);
    const counted: image_mod.Counted = .{ .auto_gensyms = expand_mod.gensym_counter - before.auto_gensyms, .gensyms = gensym_next - before.gensyms };
    return image_mod.write(gpa, loader.vm, &natives, &embedded, counted, why);
}

/// The image the build made of `embedded` (`src/imagegen.zig`); empty
/// in the generator's own build, which boots the sources.
pub const image: []const u8 = @embedFile("stdlib_image");

fn installNatives(registry: *vm_mod.NamespaceRegistry) !void {
    const core = registry.core;
    try installCore(core);
    try installTable(try registry.getOrCreate("db", core), &db_natives);
    try installTable(try registry.getOrCreate("nexis.string", core), &string_natives);
    try installTable(try registry.getOrCreate("nexis.math", core), &math_natives);
    try installTable(try registry.getOrCreate("nexis.internal", core), &internal_natives);
    try nextomic_mod.natives.install(try registry.getOrCreate("nextomic", core));
}

/// Evaluate each embedded source in its namespace, in order.
fn bootSources(loader: *loader_mod.Loader) !void {
    const registry = loader.registry;
    const saved = registry.current;
    defer registry.current = saved;
    for (&embedded) |*e| {
        registry.current = try registry.getOrCreate(e.ns, registry.core);
        _ = try loader.evalSource(&e.info, .{ .allocator = loader.persistent_allocator, .declare = false });
    }
    try packDocs(loader.vm);
}

fn markLoaded(loader: *loader_mod.Loader) !void {
    var names = loader.registry.map.keyIterator();
    while (names.next()) |name| try loader.markLoaded(name.*);
}

/// The parts of the library written in nexis, embedded at compile
/// time and bootstrapped in this order, each with its namespace
/// current, after the natives are installed: each file may use the
/// natives and the files before it.
pub const embedded = [_]image_mod.Source{
    // nexis.core's macros and functions over the natives.
    .{ .ns = "nexis.core", .info = .{ .path = "core.nx", .text = @embedFile("stdlib/core.nx"), .library = true } },
    // Sugar over the Nextomic natives (`with-conn`).
    .{ .ns = "nextomic", .info = .{ .path = "nextomic.nx", .text = @embedFile("stdlib/nextomic.nx"), .library = true } },
    // Clojure's clojure.walk; before test.nx, whose `are` uses it.
    .{ .ns = "nexis.walk", .info = .{ .path = "walk.nx", .text = @embedFile("stdlib/walk.nx"), .library = true } },
    // Clojure's clojure.edn.
    .{ .ns = "nexis.edn", .info = .{ .path = "edn.nx", .text = @embedFile("stdlib/edn.nx"), .library = true } },
    // deftest, is, testing, run-tests (docs/TOOLING.md §3).
    .{ .ns = "nexis.test", .info = .{ .path = "test.nx", .text = @embedFile("stdlib/test.nx"), .library = true } },
    // pprint, pprint-str (docs/TOOLING.md §4).
    .{ .ns = "nexis.pprint", .info = .{ .path = "pprint.nx", .text = @embedFile("stdlib/pprint.nx"), .library = true } },
    // The constants of nexis.math.
    .{ .ns = "nexis.math", .info = .{ .path = "math.nx", .text = @embedFile("stdlib/math.nx"), .library = true } },
    // The nexis.string functions written over its natives.
    .{ .ns = "nexis.string", .info = .{ .path = "string.nx", .text = @embedFile("stdlib/string.nx"), .library = true } },
    // Set algebra (Clojure's clojure.set).
    .{ .ns = "nexis.set", .info = .{ .path = "set.nx", .text = @embedFile("stdlib/set.nx"), .library = true } },
    // The environment and the working directory.
    .{ .ns = "nexis.sys", .info = .{ .path = "sys.nx", .text = @embedFile("stdlib/sys.nx"), .library = true } },
    // Clojure's clojure.java.shell.
    .{ .ns = "nexis.shell", .info = .{ .path = "shell.nx", .text = @embedFile("stdlib/shell.nx"), .library = true } },
    // Instants, ISO-8601 text and durations.
    .{ .ns = "nexis.time", .info = .{ .path = "time.nx", .text = @embedFile("stdlib/time.nx"), .library = true } },
    // JSON, in clojure.data.json's shape; after time.nx, whose
    // instants it writes.
    .{ .ns = "nexis.json", .info = .{ .path = "json.nx", .text = @embedFile("stdlib/json.nx"), .library = true } },
};

const core_rows = .{
    // Sequence primitives.
    .{ "list", 0, null, &fnList, "[& items]", "Returns a new list of the items; (list) is ()." },
    .{ "list*", 1, null, &fnListStar, "[args] [a args] [a b args] [a b c args] [a b c d & more]", "Returns a seq of the leading items consed onto the seq of the last\n  argument, which is not realized; (list* nil) is nil." },
    .{ "cons", 2, 2, &fnCons, "[x seq]", "Returns a seq of x followed by the items of seq, any seqable; a lazy\n  seq is not realized." },
    .{ "first", 1, 1, &fnFirst, "[coll]", "Returns the first item of coll, through seq; nil when coll is nil or\n  empty." },
    .{ "rest", 1, 1, &fnRest, "[coll]", "Returns a possibly empty seq of the items after the first; () when\n  coll is nil or empty. A vector's rest is an O(1) view." },
    .{ "second", 1, 1, &fnSecond, "[coll]", "Returns the second item of coll, nil when it has fewer than two." },
    .{ "take", 1, 2, &fnTake, "[n] [n coll]", "Returns a lazy seq of the first n items of coll, all of them when it\n  has fewer. A fractional n rounds up. With no coll, returns a\n  transducer." },
    .{ "drop", 1, 2, &fnDrop, "[n] [n coll]", "Returns a lazy seq of all but the first n items of coll. With no\n  coll, returns a transducer." },
    .{ "some", 2, 2, &fnSome, .consumes, "[pred coll]", "Returns the first truthy (pred x) for x in coll, else nil; stops at\n  the first one." },
    .{ "every?", 2, 2, &fnEveryQ, .consumes, "[pred coll]", "Returns true if (pred x) is truthy for every x in coll, true for an\n  empty coll; stops at the first falsy one." },
    .{ "count", 1, 1, fnCountLeaf, .consuming_leaf, fnCount, "[coll]", "Returns the number of items in coll; 0 for nil. A string counts code\n  points, not bytes; a lazy seq is realized to its end." },
    .{ "nth", 2, 3, &fnNth, .leaf, &fnNthGeneral, "[coll index] [coll index not-found]", "Returns the item at index of coll, a string's char by code point. Out\n  of range, returns not-found, or without one is\n  :index-out-of-bounds; nil coll gives not-found (nil). A lazy seq is\n  realized as far as index." },
    .{ "empty?", 1, 1, &fnEmptyQ, "[coll]", "Returns true if coll has no items; true for nil." },
    .{ "identity", 1, 1, &fnIdentity, .leaf, "[x]", "Returns x." },
    .{ "nil?", 1, 1, &fnNilQ, .leaf, "[x]", "Returns true if x is nil, false otherwise." },
    .{ "some?", 1, 1, &fnSomeQ, .leaf, "[x]", "Returns true if x is not nil, false otherwise." },
    // First-class arithmetic + comparison Vars.
    // Required so `(reduce + 0 xs)` resolves `+` as a Var.
    // `(+ x y)` at the call head is still inlined by the
    // compiler; the Var is only reached through non-head uses.
    .{ "+", 0, null, &fnAdd, .leaf, "[] [x] [x y] [x y & more]", "Returns the sum of the nums; (+) is 0. An integer result past the\n  fixnum range is a bignum, never an overflow; a float operand makes\n  the result a float." },
    .{ "-", 1, null, &fnSub, .leaf, "[x] [x y] [x y & more]", "With one arg, returns its negation; otherwise x minus each later\n  arg in turn. Integers promote to bignums, as + does." },
    .{ "*", 0, null, &fnMul, .leaf, "[] [x] [x y] [x y & more]", "Returns the product of the nums; (*) is 1. Integers promote to\n  bignums, as + does." },
    .{ "/", 1, null, &fnDiv, "[x] [x y] [x y & more]", "With one arg, returns its reciprocal; otherwise x divided by each\n  later arg in turn. There are no ratios: integers that do not divide\n  give the nearest double, (/ 7 2) is 3.5. A zero divisor of any kind\n  is :divide-by-zero." },
    .{ "quot", 2, 2, &fnQuot, "[num div]", "Returns the quotient of num by div, truncated toward zero. A zero\n  div is :divide-by-zero." },
    .{ "rem", 2, 2, &fnRem, "[num div]", "Returns the remainder of num by div under truncated division; it\n  has num's sign. A zero div is :divide-by-zero." },
    .{ "mod", 2, 2, &fnMod, "[num div]", "Returns the modulus of num by div under floored division; it has\n  div's sign. A zero div is :divide-by-zero." },
    .{ "<", 1, null, &fnLt, .leaf, "[x] [x y] [x y & more]", "Returns true if the nums are in strictly increasing order. Exact\n  across integers of any size; false against NaN." },
    .{ "<=", 1, null, &fnLte, .leaf, "[x] [x y] [x y & more]", "Returns true if the nums are in nondecreasing order. Exact across\n  integers of any size; false against NaN." },
    .{ ">", 1, null, &fnGt, .leaf, "[x] [x y] [x y & more]", "Returns true if the nums are in strictly decreasing order. Exact\n  across integers of any size; false against NaN." },
    .{ ">=", 1, null, &fnGte, .leaf, "[x] [x y] [x y & more]", "Returns true if the nums are in nonincreasing order. Exact across\n  integers of any size; false against NaN." },
    .{ "==", 1, null, &fnNumEq, .leaf, "[x] [x y] [x y & more]", "Returns true if the nums are numerically equal, across integers and\n  floats: (== 1 1.0) is true. NaN is == to nothing." },
    .{ "=", 1, null, &fnEq, "[x] [x y] [x y & more]", "Returns true if the args are equal by value. Different kinds are\n  never equal, except a list and a vector, or hash and sorted maps or\n  sets: (= 1 1.0) is false. Unlike Clojure, NaN is = to NaN." },
    .{ "not=", 1, null, &fnNotEq, "[x] [x y] [x y & more]", "Returns (not (= x y & more))." },
    .{ "inc", 1, 1, &fnInc, .leaf, "[x]", "Returns x plus one, a bignum past the fixnum range." },
    .{ "dec", 1, 1, &fnDec, .leaf, "[x]", "Returns x minus one, a bignum past the fixnum range." },
    .{ "long", 1, 1, &fnLong, "[x]", "Returns x as an integer of any size: a float's integer part (NaN is\n  0, an infinity :invalid-argument), a char's code point." },
    .{ "int", 1, 1, castTo(i32), "[x]", "Returns x as long does, within the range of Java's int, else\n  :invalid-argument; NaN is 0, a char its code point." },
    .{ "short", 1, 1, castTo(i16), "[x]", "Returns x as long does, within the range of Java's short, else\n  :invalid-argument; NaN is 0, a char its code point." },
    .{ "byte", 1, 1, castTo(i8), "[x]", "Returns x as long does, within the range of Java's byte, else\n  :invalid-argument; NaN is 0, a char its code point." },
    .{ "float", 1, 1, &fnFloat, "[x]", "Returns x as a double, within Java's float range, else\n  :invalid-argument. The one float type is 64-bit, so nothing is\n  rounded to single precision." },
    .{ "char", 1, 1, &fnChar, "[x]", "Returns the char with the code point x; a char is itself. A value\n  that is not a Unicode scalar is :invalid-argument." },
    .{ "parse-long", 1, 1, &fnParseLong, "[s]", "Returns the integer s spells in full, an optional sign and ASCII\n  digits within 64 bits, else nil. A non-string is :kind-mismatch." },
    .{ "parse-double", 1, 1, &fnParseDouble, "[s]", "Returns the double s spells as Java's Double/valueOf reads it, else\n  nil. A non-string is :kind-mismatch." },
    .{ "bit-and", 2, null, &fnBitAnd, "[x y] [x y & more]", "Returns the bitwise and of the integers, as 64-bit two's\n  complement; an integer past 64 bits is :arithmetic-overflow." },
    .{ "bit-or", 2, null, &fnBitOr, "[x y] [x y & more]", "Returns the bitwise or of the integers, as 64-bit two's complement;\n  an integer past 64 bits is :arithmetic-overflow." },
    .{ "bit-xor", 2, null, &fnBitXor, "[x y] [x y & more]", "Returns the bitwise exclusive or of the integers, as 64-bit two's\n  complement; an integer past 64 bits is :arithmetic-overflow." },
    .{ "bit-not", 1, 1, &fnBitNot, "[x]", "Returns the bitwise complement of x, as 64-bit two's complement." },
    .{ "bit-shift-left", 2, 2, &fnBitShiftLeft, "[x n]", "Returns x shifted left n bits within 64 bits; n uses its low six\n  bits." },
    .{ "bit-shift-right", 2, 2, &fnBitShiftRight, "[x n]", "Returns x shifted right n bits, keeping its sign; n uses its low six\n  bits." },
    .{ "unsigned-bit-shift-right", 2, 2, &fnUnsignedBitShiftRight, "[x n]", "Returns x, as 64 unsigned bits, shifted right n bits with zeros\n  shifted in; n uses its low six bits." },
    .{ "bit-test", 2, 2, &fnBitTest, "[x n]", "Returns true if bit n of x is set." },
    .{ "bit-set", 2, 2, &fnBitSet, "[x n]", "Returns x with bit n set." },
    .{ "bit-clear", 2, 2, &fnBitClear, "[x n]", "Returns x with bit n cleared." },
    .{ "rand", 0, 1, &fnRand, "[] [n]", "Returns a random double in [0, n), n defaulting to 1." },
    .{ "rand-int", 1, 1, &fnRandInt, "[n]", "Returns a random integer in [0, n), in (n, 0] for a negative n, 0\n  for 0." },
    .{ "format", 1, null, &fnFormat, "[fmt & args]", "Returns fmt with each % conversion replaced by the next arg, a subset\n  of Java's Formatter: %s, %d, %f, %x, %X, %c, %n and %%, with the -\n  and 0 flags, a width, and a precision for %s and %f. Anything else\n  is :invalid-argument; an arg of the wrong kind :kind-mismatch." },
    .{ "double", 1, 1, &fnDouble, "[x]", "Returns the double nearest the number x." },
    .{ "max", 1, null, &fnMax, .leaf, "[x] [x y] [x y & more]", "Returns the greatest of the nums; NaN if any is NaN." },
    .{ "min", 1, null, &fnMin, .leaf, "[x] [x y] [x y & more]", "Returns the least of the nums; NaN if any is NaN." },
    .{ "abs", 1, 1, &fnAbs, "[a]", "Returns the absolute value of a, a bignum past the fixnum range." },
    .{ "number?", 1, 1, &fnNumberQ, "[x]", "Returns true if x is a number: an integer or a float." },
    .{ "integer?", 1, 1, &fnIntegerQ, "[n]", "Returns true if n is an integer, a fixnum or a bignum." },
    .{ "float?", 1, 1, &fnFloatQ, "[n]", "Returns true if n is a float." },
    .{ "NaN?", 1, 1, &fnNanQ, "[num]", "Returns true if num is NaN. A non-number is :kind-mismatch." },
    .{ "infinite?", 1, 1, &fnInfiniteQ, "[num]", "Returns true if num is positive or negative infinity. A non-number\n  is :kind-mismatch." },
    .{ "not", 1, 1, &fnNot, .leaf, "[x]", "Returns true if x is nil or false, false otherwise." },
    .{ "zero?", 1, 1, &fnZeroQ, .leaf, "[num]", "Returns true if num is zero (-0.0 included); false for NaN." },
    .{ "pos?", 1, 1, &fnPosQ, .leaf, "[num]", "Returns true if num is greater than zero; false for NaN." },
    .{ "neg?", 1, 1, &fnNegQ, .leaf, "[num]", "Returns true if num is less than zero; false for NaN." },
    .{ "odd?", 1, 1, &fnOddQ, .leaf, "[n]", "Returns true if the integer n is odd. A float is :kind-mismatch." },
    .{ "even?", 1, 1, &fnEvenQ, .leaf, "[n]", "Returns true if the integer n is even. A float is :kind-mismatch." },
    // apply + HOFs.
    .{ "apply", 2, null, &fnApply, .consumes, "[f args] [f x args] [f x y args] [f x y z args] [f a b c d & args]", "Calls f with the leading args followed by the items of the last.\n  Unlike Clojure, the last arg is realized in full, so an infinite seq\n  never returns." },
    .{ "map", 1, null, &fnMap, "[f] [f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls]", "Returns a lazy seq of f applied to the first items of the colls,\n  then the second, ..., ending at the shortest coll; chunked, 32 at a\n  time, over one chunked coll. With no coll, returns a transducer." },
    .{ "reduce", 2, 3, &fnReduce, .consumes, "[f coll] [f val coll]", "Returns the left fold of f over coll, from val or else the first\n  item; (f) for an empty coll without val, val with one. A reduced\n  value stops the fold." },
    .{ "reduce-kv", 3, 3, &fnReduceKv, "[f init coll]", "Returns the fold of (f acc k v) from init over a map's entries or a\n  vector's indices and items; init for nil. A reduced value stops it." },
    .{ "filter", 1, 2, &fnFilter, "[pred] [pred coll]", "Returns a lazy seq of the items of coll for which (pred item) is\n  truthy; chunked when coll is. With no coll, returns a transducer." },
    .{ "remove", 1, 2, &fnRemove, "[pred] [pred coll]", "Returns a lazy seq of the items of coll for which (pred item) is\n  falsy; chunked when coll is. With no coll, returns a transducer." },
    .{ "keep", 1, 2, &fnKeep, "[f] [f coll]", "Returns a lazy seq of the non-nil results of (f item) over coll;\n  false is kept. With no coll, returns a transducer." },
    .{ "seq", 1, 1, &fnSeq, "[coll]", "Returns a seq on coll, nil when coll is nil or empty. A map gives its\n  [k v] entries, a string its chars." },
    .{ "next", 1, 1, &fnNext, "[coll]", "Returns a seq of the items after the first, nil when there are none." },
    .{ "range", 0, 3, &fnRange, "[] [end] [start end] [start end step]", "Returns a lazy seq of nums from start (0) by step (1) up to, not\n  including, end; infinite without end. Any number works, the items\n  following the tower's contagion. Finite ranges are chunked." },
    .{ "concat", 0, null, &fnConcat, "[] [x] [x y] [x y & zs]", "Returns a lazy seq of the items of each coll in turn." },
    .{ "mapcat", 1, null, &fnMapcat, "[f] [f & colls]", "Returns the lazy concatenation of (map f colls ...); an infinite\n  outer seq works. With no colls, returns a transducer." },
    .{ "into", 0, 3, &fnInto, .consumes, "[] [to] [to from] [to xform from]", "Returns to with every item of from conj'd onto it, through the\n  transducer xform when given; (into) is []." },
    .{ "mapv", 2, null, &fnMapv, .consumes, "[f coll] [f c1 c2] [f c1 c2 c3] [f c1 c2 c3 & colls]", "Returns a vector of what (map f colls ...) gives, made eagerly." },
    .{ "filterv", 2, 2, &fnFilterv, .consumes, "[pred coll]", "Returns a vector of the items of coll for which (pred item) is\n  truthy, made eagerly." },
    .{ "map-indexed", 1, 2, &fnMapIndexed, "[f] [f coll]", "Returns a lazy seq of (f index item) over coll, index from 0. With\n  no coll, returns a transducer." },
    .{ "keep-indexed", 1, 2, &fnKeepIndexed, "[f] [f coll]", "Returns a lazy seq of the non-nil results of (f index item) over\n  coll, index from 0. With no coll, returns a transducer." },
    .{ "distinct", 0, 1, &fnDistinct, "[] [coll]", "Returns a lazy seq of the items of coll without duplicates, each at\n  its first occurrence. With no coll, returns a transducer." },
    .{ "dedupe", 0, 1, &fnDedupe, "[] [coll]", "Returns a lazy seq of the items of coll without consecutive\n  duplicates. With no coll, returns a transducer." },
    .{ "partition", 2, 4, &fnPartition, "[n coll] [n step coll] [n step pad coll]", "Returns a lazy seq of seqs of n items each, at offsets step apart\n  (n by default). A short final part is dropped, unless pad is given\n  to fill it, as far as pad goes. n and step must be positive." },
    .{ "partition-all", 1, 3, &fnPartitionAll, "[n] [n coll] [n step coll]", "Returns a lazy seq of seqs of n items each, at offsets step apart\n  (n by default), the last ones possibly short. With no coll,\n  returns a transducer." },
    .{ "zipmap", 2, 2, &fnZipmap, "[keys vals]", "Returns a map of each key to the val at its position, stopping at\n  the shorter of keys and vals." },
    .{ "take-while", 1, 2, &fnTakeWhile, "[pred] [pred coll]", "Returns a lazy seq of the items of coll as long as (pred item) is\n  truthy. With no coll, returns a transducer." },
    .{ "drop-while", 1, 2, &fnDropWhile, "[pred] [pred coll]", "Returns a lazy seq of the items of coll from the first for which\n  (pred item) is falsy. With no coll, returns a transducer." },
    .{ "butlast", 1, 1, &fnButlast, .consumes, "[coll]", "Returns a seq of all but the last item of coll, nil when it has\n  fewer than two." },
    .{ "last", 1, 1, &fnLast, .consumes, "[coll]", "Returns the last item of coll, nil when it is empty. O(1) for a\n  vector, a walk of anything else." },
    .{ "reverse", 1, 1, &fnReverse, .consumes, "[coll]", "Returns a seq of the items of coll in reverse order; () when there\n  are none." },
    .{ "nthrest", 2, 2, &fnNthrest, "[coll n]", "Returns coll without its first n items; coll itself when n is not\n  positive." },
    .{ "nthnext", 2, 2, fnNthnextLeaf, .leaf, fnNthnext, "[coll n]", "Returns (seq (nthrest coll n)): the items after the first n, nil\n  when there are none." },
    .{ "take-last", 2, 2, &fnTakeLast, .consumes, "[n coll]", "Returns a seq of the last n items of coll, nil when there are none." },
    .{ "repeat", 1, 2, &fnRepeat, "[x] [n x]", "Returns a lazy seq of x, infinite, or n times; () when n is at most\n  0. n is truncated as long does." },
    .{ "repeatedly", 1, 2, &fnRepeatedly, "[f] [n f]", "Returns a lazy seq of calls to the no-argument f, infinite, or n of\n  them; each call made when its item is first needed." },
    .{ "iterate", 2, 2, &fnIterate, "[f x]", "Returns the infinite lazy seq of x, (f x), (f (f x)), ...; f must be\n  free of side effects, since a reduce over the unrealized seq calls\n  it again." },
    .{ "cycle", 1, 1, &fnCycle, "[coll]", "Returns the infinite lazy seq of the items of coll over and over; ()\n  when coll is empty." },
    .{ "max-key", 2, null, &fnMaxKey, "[k x] [k x y] [k x y & more]", "Returns the x for which (k x), a number, is greatest; a tie goes to\n  the later x. A lone x is returned without calling k." },
    .{ "min-key", 2, null, &fnMinKey, "[k x] [k x y] [k x y & more]", "Returns the x for which (k x), a number, is least; a tie goes to the\n  later x. A lone x is returned without calling k." },
    .{ "select-keys", 2, 2, &fnSelectKeys, .consumes, "[map keyseq]", "Returns a map of the entries of map whose keys are in keyseq. Of a\n  vector, the keys are indices." },
    .{ "find", 2, 2, &fnFind, "[map key]", "Returns the [k v] entry of map for key, nil when absent; k is the key\n  as map holds it. Of a vector, key is an index." },
    .{ "key", 1, 1, &fnKey, "[e]", "Returns the key of the map entry e, a [k v] vector." },
    .{ "val", 1, 1, &fnVal, "[e]", "Returns the val of the map entry e, a [k v] vector." },
    .{ "peek", 1, 1, &fnPeek, "[coll]", "Returns the last item of a vector or the first of a list; nil when\n  coll is nil or empty." },
    .{ "pop", 1, 1, &fnPop, "[coll]", "Returns a vector without its last item or a list without its first;\n  nil for nil. An empty coll is :index-out-of-bounds." },
    .{ "empty", 1, 1, &fnEmpty, "[coll]", "Returns an empty collection of coll's kind with coll's metadata; {}\n  for a record, nil for anything that is not a collection, a string\n  included." },
    .{ "not-empty", 1, 1, &fnNotEmpty, "[coll]", "Returns coll, or nil when it has no items." },
    .{ "disj", 1, null, &fnDisj, "[set] [set key] [set key & ks]", "Returns set without the keys; nil for nil." },
    .{ "compare", 2, 2, &fnCompare, "[x y]", "Returns -1, 0 or 1 as x is less than, equal to or greater than y.\n  nil sorts first; numbers compare across kinds, then booleans,\n  strings, keywords, symbols, chars and vectors (shorter first) each\n  among their own. Anything else is :kind-mismatch." },
    .{ "sort", 1, 2, &fnSort, "[coll] [comp coll]", "Returns a seq of the items of coll in order, a stable sort by comp\n  (compare by default), which returns a number (negative for less) or\n  a boolean (true for less)." },
    .{ "sort-by", 2, 3, &fnSortBy, "[keyfn coll] [keyfn comp coll]", "Returns a seq of the items of coll ordered by (keyfn item), a stable\n  sort by comp (compare by default), as sort takes it." },
    .{ "hash", 1, 1, &fnHash, "[x]", "Returns the hash of x, a non-negative fixnum consistent with =.\n  Stable within a process only; it differs from Clojure's." },
    .{ "name", 1, 1, &fnName, "[x]", "Returns the name of a keyword or symbol, without its namespace; a\n  string is its own name." },
    .{ "namespace", 1, 1, &fnNamespace, "[x]", "Returns the namespace of a keyword or symbol, nil when it has none." },
    .{ "keyword", 1, 2, &fnKeyword, "[name] [ns name]", "Returns a keyword from a string, symbol or keyword (\"a/b\" gives\n  :a/b), nil for nil; with ns, qualified by it, a nil ns leaving it\n  unqualified." },
    .{ "symbol", 1, 2, &fnSymbol, "[name] [ns name]", "Returns a symbol from a string, keyword or symbol; with ns, qualified\n  by it, a nil ns leaving it unqualified." },
    .{ "gensym", 0, 1, &fnGensym, "[] [prefix-string]", "Returns a fresh symbol, prefix-string (G__ by default) followed by a\n  number that counts up for the process." },
    .{ "in-ns", 1, 1, &fnInNs, "[name]", "Makes the namespace the symbol name names current, creating it with\n  nexis.core referred when absent; returns nil, where Clojure returns\n  the namespace." },
    // Exceptions as maps (PLAN Amendment Log, exceptions are values).
    .{ "ex-info", 2, 3, &fnExInfo, "[msg map] [msg map cause]", "Returns the exception map {:message msg :data map}, with :cause when\n  given, for throw: exceptions are values, and catch receives the map.\n  msg is a string or nil; map is a map, nil meaning {}." },
    .{ "ex-data", 1, 1, &fnExData, "[ex]", "Returns the :data of the ex-info map ex. An error map, one with an\n  :error and no :data (a caught runtime error, a Nextomic error), is\n  its own data, so (:error (ex-data e)) is the tag of either; nil for\n  anything else." },
    .{ "ex-message", 1, 1, &fnExMessage, "[ex]", "Returns the :message of the map ex: an ex-info map's message, or a\n  caught runtime error's sentence (\"+ expects numbers, got a string\").\n  nil for anything that is not a map." },
    // Early exit from a fold.
    .{ "reduced", 1, 1, &fnReduced, "[x]", "Wraps x so that reduce, and the reductions built on it, stop and\n  return x; deref reads x back." },
    .{ "reduced?", 1, 1, &fnReducedQ, "[x]", "Returns true if x is the result of a call to reduced." },
    // The compiler at run time.
    .{ "macroexpand-1", 1, 1, &fnMacroexpand1, "[form]", "Returns form after one macro expansion step when it is a macro call,\n  else form itself. Nothing inside the result is expanded." },
    .{ "macroexpand", 1, 1, &fnMacroexpand, "[form]", "Repeats macroexpand-1 on form until its head is not a macro and\n  returns it. Subforms are left alone." },
    .{ "read-string", 1, 2, &fnReadString, "[s] [opts s]", "Returns the first form of the string s as data; the text after it is\n  ignored. When s holds no form, returns the :eof value of the map\n  opts, else :reader-error, as is text that does not read." },
    .{ "eval", 1, 1, &fnEval, "[form]", "Compiles form in the current namespace, runs it and returns its\n  value. A form that does not compile throws\n  {:error :compile-error :message m :form form :kind name}, m the\n  compiler's sentence." },
    // Metadata (SEMANTICS.md §7).
    .{ "meta", 1, 1, &fnMeta, "[obj]", "Returns the metadata map of obj, a list, vector, map, set, record,\n  atom or Var; nil when it has none or cannot have any." },
    .{ "with-meta", 2, 2, &fnWithMeta, "[obj m]", "Returns a value equal to obj with the map m (or nil) as its metadata.\n  A scalar is :no-metadata-on-immediate; a Var or atom takes metadata\n  in place, through reset-meta! or alter-meta!." },
    .{ "reset-meta!", 2, 2, &fnResetMeta, "[iref metadata-map]", "Sets the metadata of the Var or atom iref to metadata-map in place\n  and returns it." },
    .{ "alter-meta!", 2, null, &fnAlterMeta, "[iref f & args]", "Sets the metadata of the Var or atom iref to\n  (apply f (meta iref) args) in place and returns it." },
    // Dynamic bindings (VM.md §6.5); `binding` and `set!` in
    // core.nx expand to these.
    .{ "push-thread-bindings", 1, 1, &fnPushThreadBindings, "[bindings]", "Opens a binding frame that rebinds each Var key of the map bindings\n  to its value. Every Var must be dynamic, else :not-dynamic and\n  nothing is rebound. Use binding, which pairs it with\n  pop-thread-bindings." },
    .{ "pop-thread-bindings", 0, 0, &fnPopThreadBindings, "[]", "Closes the innermost frame push-thread-bindings opened, restoring\n  the bindings it replaced." },
    .{ "var-set", 2, 2, &fnVarSet, "[x val]", "Sets the binding in force of the dynamic Var x to val and returns\n  val; set! expands to it. :not-dynamic for a Var that is not dynamic,\n  :no-thread-binding when no binding of it is in force." },
    .{ "thread-bound?", 0, null, &fnThreadBoundQ, "[& vars]", "Returns true if a binding of each of the vars is in force; true when\n  given none." },
    .{ "alter-var-root", 2, null, &fnAlterVarRoot, "[v f & args]", "Sets the root of the Var v to (apply f root args) and returns it; a\n  binding in force is left alone. An unbound Var's root is nil to f." },
    .{ "boolean", 1, 1, &fnBoolean, "[x]", "Returns false for nil and false, true for anything else." },
    .{ "list?", 1, 1, kindPredicate(isList), .leaf, "[x]", "Returns true if x is a list. Unlike Clojure, a seq realized as a\n  list, such as (seq [1 2]) or (keys m), is one; a lazy seq is not." },
    .{ "seq?", 1, 1, kindPredicate(isSeq), .leaf, "[x]", "Returns true if x is a seq: a list or a lazy seq. A vector, map,\n  set or string is not, though seq of one is." },
    .{ "vector?", 1, 1, kindPredicate(isVector), .leaf, "[x]", "Returns true if x is a persistent vector, a map entry included; a\n  typed vector or a transient is not." },
    .{ "map?", 1, 1, kindPredicate(isMap), .leaf, "[x]", "Returns true if x is a map: a hash map, a sorted map or a record." },
    .{ "set?", 1, 1, kindPredicate(isSet), .leaf, "[x]", "Returns true if x is a set: a hash set or a sorted set." },
    .{ "keyword?", 1, 1, kindPredicate(isKeyword), .leaf, "[x]", "Returns true if x is a keyword." },
    .{ "symbol?", 1, 1, kindPredicate(isSymbol), .leaf, "[x]", "Returns true if x is a symbol." },
    .{ "char?", 1, 1, kindPredicate(isChar), .leaf, "[x]", "Returns true if x is a char." },
    .{ "boolean?", 1, 1, kindPredicate(isBoolean), .leaf, "[x]", "Returns true if x is true or false." },
    .{ "coll?", 1, 1, kindPredicate(isColl), .leaf, "[x]", "Returns true if x is a persistent collection: a list, lazy seq,\n  vector, map, set (hash or sorted) or record. False of nil, a\n  string, a typed vector and a transient." },
    .{ "sequential?", 1, 1, kindPredicate(isSequential), .leaf, "[x]", "Returns true if x is a list, a lazy seq or a vector; false of a\n  typed vector." },
    .{ "associative?", 1, 1, kindPredicate(isAssociative), .leaf, "[x]", "Returns true if x is a vector, a hash or sorted map, or a record." },
    .{ "fn?", 1, 1, kindPredicate(isFn), .leaf, "[x]", "Returns true if x is a function: a fn, a native function or a\n  protocol method. A callable keyword or collection is not (ifn?)." },
    .{ "ifn?", 1, 1, kindPredicate(isIfn), .leaf, "[x]", "Returns true if x can be called as a function: a function, a Var,\n  a keyword, a symbol, a vector, a map or set (hash or sorted), or a\n  transient." },
    .{ "counted?", 1, 1, kindPredicate(isCounted), .leaf, "[x]", "Returns true if x is a list, vector, map, set, record, typed vector\n  or transient; false of nil, a string and a lazy seq." },
    .{ "delay?", 1, 1, &fnDelayQ, "[x]", "Returns true if x is a delay." },
    // Lazy seqs (docs/LAZY.md).
    .{ "realized?", 1, 1, &fnRealizedQ, "[x]", "Returns true if x, a lazy seq, has run its body, or x, a delay,\n  has been forced; anything else is :kind-mismatch." },
    .{ "doall", 1, 2, &fnDoall, "[coll] [n coll]", "Walks coll, realizing a lazy seq (only its first n steps with n),\n  and returns coll itself." },
    .{ "dorun", 1, 2, &fnDorun, .consumes, "[coll] [n coll]", "Walks coll as doall does, for its side effects, keeping nothing of\n  it; returns nil." },
    .{ "chunked-seq?", 1, 1, &fnChunkedSeqQ, "[s]", "Returns true if s is a seq that hands out chunks: a chunked cons\n  or a seq over a vector." },
    .{ "chunk-first", 1, 1, &fnChunkFirst, "[s]", "Returns the first chunk of the chunked seq s, as a vector." },
    .{ "chunk-rest", 1, 1, &fnChunkRest, "[s]", "Returns what follows the first chunk of the chunked seq s, () when\n  nothing does." },
    .{ "chunk-next", 1, 1, &fnChunkNext, "[s]", "Returns the seq after the first chunk of the chunked seq s, nil\n  when nothing follows." },
    .{ "chunk-buffer", 1, 1, &fnChunkBuffer, "[capacity]", "Returns an empty chunk buffer, a transient vector; capacity must be\n  an integer and is otherwise ignored." },
    .{ "chunk-append", 2, 2, &fnChunkAppend, "[b x]", "Appends x to the chunk buffer b, as conj! does; returns b." },
    .{ "chunk", 1, 1, &fnChunk, "[b]", "Returns the elements of the chunk buffer b as a chunk, a vector,\n  freezing b as persistent! does." },
    .{ "chunk-cons", 2, 2, &fnChunkCons, "[chunk rest]", "Returns a chunked seq of the elements of chunk (a vector) followed\n  by rest; rest itself when chunk is empty." },
    // Introspection: kinds, namespaces, UUIDs (STDLIB.md §8).
    .{ "class", 1, 1, &fnClass, "[x]", "Returns the type of x: the keyword of its kind (:vector, :map,\n  :fixnum, :string, :sorted_map, ...; :boolean for both booleans), the\n  symbol a record prints with (user.P), or nil for nil. There are no\n  Java classes." },
    .{ "class?", 1, 1, &fnClassQ, "[x]", "Returns true if x is a type class returns: a kind keyword such as\n  :vector or :fixnum, or the symbol of a record type." },
    .{ "var?", 1, 1, kindPredicate(isVar), .leaf, "[v]", "Returns true if v is a Var." },
    .{ "find-ns", 1, 1, &fnFindNs, "[sym]", "Returns sym when a namespace has that name, else nil. A namespace\n  is its name symbol; there is no namespace object." },
    .{ "all-ns", 0, 0, &fnAllNs, "[]", "Returns the name symbol of every namespace, sorted." },
    .{ "ns-interns", 1, 1, &fnNsInterns, "[ns]", "Returns a map from name symbol to Var of every Var interned in the\n  namespace the symbol ns names, not those it refers to;\n  :no-such-namespace when there is none." },
    .{ "ns-publics", 1, 1, &fnNsPublics, "[ns]", "Returns ns-interns of the namespace the symbol ns names without the\n  Vars marked :private." },
    .{ "resolve", 1, 1, &fnResolve, "[sym]", "Returns the Var sym names in the current namespace, resolved as the\n  compiler resolves a global, else nil. A host macro such as when has\n  no Var, so it resolves to nil." },
    .{ "ns-resolve", 2, 2, &fnNsResolve, "[ns sym]", "Returns the Var sym names in the namespace the symbol ns names, as\n  resolve does, else nil; :no-such-namespace when ns names none." },
    .{ "random-uuid", 0, 0, &fnRandomUuid, "[]", "Returns a random version-4 UUID as its canonical lowercase text: a\n  UUID is a string, and there is no #uuid literal." },
    .{ "parse-uuid", 1, 1, &fnParseUuid, "[s]", "Returns the canonical lowercase text of the UUID the string s spells\n  in 8-4-4-4-12 hex digits of either case, else nil." },
    .{ "indexed?", 1, 1, kindPredicate(isIndexed), .leaf, "[coll]", "Returns true if coll is a vector or a typed vector, whose nth takes\n  constant time." },
    // Collection construction + access.
    .{ "vector", 0, null, &fnVector, "[& args]", "Returns a vector of the args." },
    .{ "vec", 1, 1, &fnVec, .consumes, "[coll]", "Returns a vector of the elements of coll, any seqable; nil gives []." },
    .{ "hash-map", 0, null, &fnHashMap, "[& keyvals]", "Returns a hash map of the key-value pairs; a later duplicate key's\n  value wins. An odd number of args is :arity-mismatch." },
    .{ "hash-set", 0, null, &fnHashSet, "[& keys]", "Returns a hash set of the keys." },
    .{ "set", 1, 1, &fnSet, "[coll]", "Returns a hash set of the elements of coll, any seqable; a set\n  comes back itself, without its metadata." },
    .{ "subvec", 2, 3, &fnSubvec, "[v start] [v start end]", "Returns a vector of the elements of v from start (inclusive) to end\n  (exclusive, the count by default); bounds outside 0..count, or\n  start past end, are :index-out-of-bounds." },
    .{ "identical?", 2, 2, &fnIdenticalQ, "[x y]", "Returns true if x and y are the same value bit for bit: the same\n  immediate (a fixnum, float, char, keyword, ...) or the same heap\n  object." },
    .{ "assoc", 3, null, &fnAssocLeaf, .leaf, &fnAssoc, "[map key val] [map key val & kvs]", "Returns map with each key mapped to its val. Of a vector, key is an\n  index up to the count (the count appends); nil makes a map." },
    .{ "dissoc", 1, null, &fnDissoc, "[map] [map key] [map key & ks]", "Returns map, a map or record, without the keys; nil gives nil." },
    .{ "get", 2, 3, &fnGetLeaf, .leaf, &fnGet, "[map key] [map key not-found]", "Returns the value mapped to key in map, else not-found (nil). A\n  vector or string takes an index; a value that is no collection has\n  no entries, so get never throws for the kind of map." },
    .{ "contains?", 2, 2, &fnContainsQ, "[coll key]", "Returns true if key is present in coll: a key of a map or record, a\n  member of a set, an index of a vector or string. It does not search\n  values; a list is :kind-mismatch." },
    .{ "keys", 1, 1, &fnKeys, "[map]", "Returns the keys of map (a map or record) as a list, nil when it\n  has none." },
    .{ "vals", 1, 1, &fnVals, "[map]", "Returns the values of map (a map or record) as a list, nil when it\n  has none." },
    .{ "conj", 0, null, &fnConjLeaf, .leaf, &fnConj, "[] [coll] [coll x] [coll x & xs]", "Returns coll with the xs added where its kind adds: a list at the\n  front, a vector at the end, a map [k v] vectors or maps, a set\n  members. nil makes a list; (conj) is []." },
    .{ "frequencies", 1, 1, &fnFrequencies, .consumes, "[coll]", "Returns a map from each distinct element of coll to the number of\n  times it occurs." },
    .{ "group-by", 2, 2, &fnGroupBy, .consumes, "[f coll]", "Returns a map from each (f x) to the vector of the elements x of\n  coll that gave it, in their order." },
    // Transients (docs/TRANSIENT.md): each `!` edits the nodes the
    // transient owns in place and returns the transient to use.
    .{ "transient", 1, 1, &fnTransient, "[coll]", "Returns a transient of the hash map, hash set or vector coll, which\n  the ! functions edit in place; coll is unchanged. A sorted\n  collection has no transient (:kind-mismatch)." },
    .{ "persistent!", 1, 1, &fnPersistentBang, "[coll]", "Returns the persistent collection of the transient coll and freezes\n  coll: any later use is :transient-used-after-persistent." },
    .{ "conj!", 0, null, &fnConjBang, "[] [coll] [coll x] [coll x & xs]", "Adds the xs to the transient coll in place, as conj adds them, and\n  returns coll. (conj!) is a new transient vector." },
    .{ "assoc!", 3, null, &fnAssocBangLeaf, .leaf, &fnAssocBang, "[coll key val] [coll key val & kvs]", "Puts each key and val into the transient map or vector coll in\n  place (a vector index may be the count, which appends); returns\n  coll." },
    .{ "dissoc!", 2, null, &fnDissocBang, "[map key] [map key & ks]", "Removes the keys from the transient map in place; returns map." },
    .{ "disj!", 2, null, &fnDisjBang, "[set key] [set key & ks]", "Removes the keys from the transient set in place; returns set." },
    .{ "pop!", 1, 1, &fnPopBang, "[coll]", "Removes the last element of the transient vector coll in place and\n  returns coll; an empty one is :index-out-of-bounds." },
    // Sorted collections (docs/SORTED.md).
    .{ "sorted-map", 0, null, &fnSortedMap, "[& keyvals]", "Returns a sorted map of the key-value pairs, ordered by compare. A\n  later equal key replaces the value and keeps the first key." },
    .{ "sorted-map-by", 1, null, &fnSortedMapBy, "[comparator & keyvals]", "Returns a sorted map of the key-value pairs ordered by comparator,\n  as sorted-set-by orders its keys." },
    .{ "sorted-set", 0, null, &fnSortedSet, "[& keys]", "Returns a sorted set of the keys, ordered by compare." },
    .{ "sorted-set-by", 1, null, &fnSortedSetBy, "[comparator & keys]", "Returns a sorted set of the keys ordered by comparator: a function\n  returning a negative, zero or positive number, or a predicate such\n  as <. Keys it calls equal are one key." },
    .{ "sorted?", 1, 1, kindPredicate(sorted_mod.isSortedKind), .leaf, "[coll]", "Returns true if coll is a sorted map or a sorted set." },
    .{ "reversible?", 1, 1, kindPredicate(isReversible), .leaf, "[coll]", "Returns true if rseq takes coll: a vector, sorted map or sorted set." },
    .{ "subseq", 3, 5, &fnSubseq, "[sc test key] [sc start-test start-key end-test end-key]", "Returns the entries of the sorted collection sc whose keys pass the\n  tests (< <= > or >=, against key), ascending, as a list, nil when\n  none. A sorted map's entries are [k v] vectors." },
    .{ "rsubseq", 3, 5, &fnRsubseq, "[sc test key] [sc start-test start-key end-test end-key]", "Returns the entries of the sorted collection sc whose keys pass the\n  tests (< <= > or >=, against key), descending, as a list, nil when\n  none. A sorted map's entries are [k v] vectors." },
    .{ "rseq", 1, 1, &fnRseq, "[rev]", "Returns the elements of the vector or sorted collection rev, last\n  first, nil when it is empty; anything else is :kind-mismatch." },
    // Typed vectors (docs/TYPED_VECTOR.md §7.1).
    .{ "i64-vector", 1, 1, &fnI64Vector, .consumes, "[coll]", "Returns an i64 typed vector of the integers in coll, any seqable; a\n  non-integer, or one beyond 64 bits, is :kind-mismatch." },
    .{ "f64-vector", 1, 1, &fnF64Vector, .consumes, "[coll]", "Returns an f64 typed vector of the numbers in coll, any seqable;\n  an integer widens to the nearest double." },
    .{ "typed-vector?", 1, 1, kindPredicate(isTypedVector), .leaf, "[x]", "Returns true if x is a typed vector, i64 or f64. A typed vector is\n  not vector?, coll? or sequential?, and is not callable." },
    .{ "typed-vector-type", 1, 1, &fnTypedVectorType, "[tv]", "Returns :i64 or :f64, the element type of the typed vector tv." },
    // Atoms: identity-valued in-memory mutable cells (docs/ATOM.md).
    // `deref` is `fnDbDeref`, which takes a var, atom, durable ref
    // or reduced; `db_natives` installs it again as `db/deref`.
    .{ "deref", 1, 1, &fnDbDeref, "[ref]", "Returns the value of ref: an atom's, a Var's, a delay's (forcing\n  it), a reduced's, or a durable ref's stored value (nil when absent).\n  Anything else is :not-derefable. @x reads as (deref x)." },
    .{ "atom", 1, null, &fnAtom, "[x] [x & options]", "Returns an atom holding x. The options are :meta m, its metadata,\n  and :validator f, which every new value, x included, must satisfy\n  (else :invalid-reference-state)." },
    .{ "atom?", 1, 1, &fnAtomQ, "[x]", "Returns true if x is an atom." },
    .{ "reset!", 2, 2, &fnResetBang, "[atom newval]", "Sets the value of atom to newval once the validator accepts it,\n  runs the watches and returns newval." },
    .{ "swap!", 2, null, &fnSwapBang, "[atom f] [atom f x] [atom f x y] [atom f x y & args]", "Sets the value of atom to (apply f old-value args) and returns it.\n  f runs once, with no retry: changing atom from inside f is\n  :atom-re-entry, and a throw leaves atom unchanged." },
    .{ "swap-vals!", 2, null, &fnSwapValsBang, "[atom f] [atom f x] [atom f x y] [atom f x y & args]", "Swaps as swap! does and returns [old new]." },
    .{ "compare-and-set!", 3, 3, &fnCompareAndSetBang, "[atom oldval newval]", "Sets atom to newval and returns true if its value is identical? to\n  oldval (not merely =); else returns false." },
    .{ "set-validator!", 2, 2, &fnSetValidator, "[iref validator-fn]", "Sets the validator of the atom iref once its current value passes\n  (else :invalid-reference-state); nil removes it. Returns nil." },
    .{ "get-validator", 1, 1, &fnGetValidator, "[iref]", "Returns the validator of the atom iref, or nil." },
    .{ "add-watch", 3, 3, &fnAddWatch, "[reference key fn]", "Adds fn as a watch of the atom reference under key, replacing one\n  under an = key; (fn key reference old new) runs after every write.\n  Returns reference." },
    .{ "remove-watch", 2, 2, &fnRemoveWatch, "[reference key]", "Removes the watch under key from the atom reference; returns\n  reference." },
    // satisfies? predicate.
    .{ "satisfies?", 2, 2, &fnSatisfiesQ, "[protocol x]", "Returns true if a method of protocol is extended to the type of x\n  or has a default; a protocol of no methods satisfies nothing." },
    // Core string ops. Indexing semantics are by Unicode scalar
    // (codepoint), NOT byte; see `docs/STDLIB.md` §2.
    .{ "str", 0, null, &fnStrLeaf, .leaf, &fnStr, "[] [x] [x & ys]", "Returns the text of the args concatenated: nil is empty, a string\n  or char is itself, anything else as pr-str prints it, so a string\n  inside a collection keeps its quotes." },
    .{ "string?", 1, 1, &fnStringQ, "[x]", "Returns true if x is a string." },
    .{ "subs", 2, 3, &fnSubs, "[s start] [s start end]", "Returns the substring of s from start (inclusive) to end (exclusive,\n  the count by default), indexed by code point; bounds outside the\n  string, or start past end, are :index-out-of-bounds." },
    // Regular expressions (docs/REGEX.md §9); `re-seq` is core.nx's.
    .{ "re-pattern", 1, 1, &fnRePattern, "[s]", "Returns the pattern the string s compiles to; a pattern is itself.\n  Java's syntax without backreferences or lookaround, matched in\n  linear time; an invalid one throws :invalid-regex." },
    .{ "re-matcher", 2, 2, &fnReMatcher, "[re s]", "Returns a fresh matcher of the pattern re over the string s, for\n  re-find and re-groups." },
    .{ "re-find", 1, 2, &fnReFind, "[m] [re s]", "Returns the next match of the matcher m, or the first match of re\n  in s; nil when there is none. A match is the matched string, or\n  [whole g1 g2 ...] when the pattern has groups." },
    .{ "re-matches", 2, 2, &fnReMatches, "[re s]", "Returns the match of re against the whole of s, or nil. A match is\n  the string, or [whole g1 g2 ...] when re has groups." },
    .{ "re-groups", 1, 1, &fnReGroups, "[m]", "Returns the last match of the matcher m; :invalid-argument when its\n  last search failed or it has not searched." },
    // Printing + I/O.
    .{ "print", 0, null, &fnPrint, "[& more]", "Prints the args separated by spaces, for people: a string or char\n  as its text. Returns nil." },
    .{ "println", 0, null, &fnPrintln, "[& more]", "Prints as print does, then a newline. Returns nil." },
    .{ "pr", 0, null, &fnPr, "[] [x] [x & more]", "Prints the args separated by spaces, readably: strings quoted, chars\n  as literals. Returns nil." },
    .{ "prn", 0, null, &fnPrn, "[& more]", "Prints as pr does, then a newline. Returns nil." },
    .{ "pr-str", 0, null, &fnPrStr, "[& xs]", "Returns the text pr prints of the xs, as a string." },
    .{ "bound?", 0, null, &fnBoundQ, "[& vars]", "Returns true if every Var given has a value, its root or a binding\n  in force." },
    .{ "nano-time", 0, 0, &fnNanoTime, "[]", "Returns a monotonic clock reading in nanoseconds, for measuring\n  intervals; it is no time of day." },
    .{ "slurp", 1, 1, &fnSlurp, "[f]", "Returns the whole text of the file at the path f, which must be\n  UTF-8; a missing file is :file-not-found." },
    .{ "spit", 2, null, &fnSpit, "[f content & options]", "Writes (str content) to the file at the path f, replacing it, or\n  after its end with :append true; returns nil. Parent directories\n  are not created." },
    .{ "read-line", 0, 0, &fnReadLine, "[]", "Returns the next line of stdin without its line ending, nil at end\n  of input." },
    .{ "exit", 0, 1, &fnExit, "[] [status]", "Closes every open store and Nextomic connection, syncing what a\n  commit left unsynced, and ends the process with status (0 by\n  default; its low eight bits). Nothing after it runs, finally blocks\n  included." },
    // The durable-ref natives are `db_natives`, in the `db`
    // namespace, so they are called as `(db/open ...)`.
};
const core_natives = table("", core_rows);
const core_docs = docs(core_rows);

const db_rows = .{
    // Connection + ref + auto-ephemeral primitives.
    .{ "open", 1, 2, &fnDbOpen, "[path] [path opts]", "Returns a connection to the emdb store at path, creating the file and\n  its parent directories; a file the process may only read opens\n  read-only. opts takes :durability, :commit or :durable. An empty\n  path or one with a NUL byte is :invalid-path." },
    .{ "close", 1, 1, &fnDbClose, "[conn]", "Closes conn: aborts its open transactions and syncs the file when a\n  commit left it unsynced. Returns nil; closing twice is nil. Any later\n  use of conn or of a ref through it is :db-closed." },
    .{ "sync", 1, 1, &fnDbSync, "[conn]", "Makes every commit to conn's file durable, with one full sync when a\n  commit left it unsynced; returns nil. :db/sync-failed once a sync of\n  the file has failed, until it is reopened." },
    .{ "ref", 3, 3, &fnDbRef, "[conn tree key]", "Returns the durable ref naming key in tree of conn's store. tree is a\n  keyword, :a/b naming the tree a/b; key is a keyword, symbol or\n  string, equal by name, so :k, 'k and \"k\" name one key." },
    .{ "ref?", 1, 1, &fnDbRefQ, "[x]", "Returns true if x is a durable ref." },
    .{ "put-key!", 2, 2, &fnDbPutKey, "[ref v]", "Stores v at ref in one write transaction, committed as the\n  connection's durability says; returns nil." },
    .{ "get-key", 1, 2, &fnDbGetKey, "[ref] [ref default]", "Returns the value stored at ref, or default (nil) when there is none,\n  in one read transaction." },
    .{ "delete-key!", 1, 1, &fnDbDeleteKey, "[ref]", "Deletes ref's key in one write transaction; returns true if it\n  existed." },
    .{ "present?", 1, 1, &fnDbPresentQ, "[ref]", "Returns true if ref's key exists. The value is not read, so one whose\n  bytes do not decode is present." },
    // Explicit-tx primitives.
    .{ "begin-write", 1, 1, &fnDbBeginWrite, "[conn]", "Begins and returns a write transaction on conn; finish it with\n  commit! or abort-write!, or use with-tx. :db/busy while any\n  connection or Nextomic store of the same file holds one." },
    .{ "begin-read", 1, 1, &fnDbBeginRead, "[conn]", "Begins and returns a read transaction on conn, which sees the store\n  as it is now and nothing committed after; finish it with abort-read!,\n  or use with-read-tx. :db/readers-full when every reader slot is taken." },
    .{ "commit!", 1, 1, &fnDbCommit, "[tx]", "Commits the write transaction tx; returns nil. tx is over even when\n  the commit fails, and any later use of it is :tx-closed." },
    .{ "abort-write!", 1, 1, &fnDbAbortWrite, "[tx]", "Aborts the write transaction tx, discarding its writes; returns nil,\n  for a finished tx too." },
    .{ "abort-read!", 1, 1, &fnDbAbortRead, "[tx]", "Ends the read transaction tx; returns nil, for a finished tx too." },
    .{ "put!", 3, 3, &fnDbPut, "[tx ref v]", "Stores v at ref within the write transaction tx; returns nil. A read\n  transaction is :kind-mismatch." },
    .{ "get", 2, 3, &fnDbGet, "[tx ref] [tx ref default]", "Returns the value at ref as the transaction tx sees it, its own\n  writes included, or default (nil) when there is none." },
    .{ "delete!", 2, 2, &fnDbDelete, "[tx ref]", "Deletes ref's key within the write transaction tx; returns true if\n  it existed." },
    // Deref + alter.
    .{ "deref", 1, 1, &fnDbDeref, "[ref]", "Returns the value of ref: a durable ref's stored value or nil, read\n  in one read transaction, or what deref returns for a Var, atom,\n  delay or reduced. Another kind is :not-derefable." },
    .{ "alter!", 3, null, &fnDbAlter, "[tx ref f & args]", "Stores and returns (apply f current args) at ref within the write\n  transaction tx, current being the stored value or nil. When f\n  throws, nothing is written." },
    // Tree traversal.
    .{ "scan", 2, 4, &fnDbScan, "[tx tree] [tx tree start] [tx tree start end]", "Returns a vector of [key value] for the entries of tree in key-byte\n  order, each key a string of its bytes, which ref takes back. start\n  is inclusive and end exclusive, each a keyword, symbol or string as\n  a ref's key is. An absent tree is []." },
    .{ "reduce-tree", 4, 4, &fnDbReduceTree, "[tx tree f init]", "Returns the reduction of (f acc key value) over the entries of tree\n  in key order from init, each key a string as scan gives it, the tree\n  as it was when the walk began; init for an absent tree." },
    // Snapshot aliases (DB.md §12).
    .{ "snapshot", 1, 1, &fnDbBeginRead, "[conn]", "Begins and returns a read transaction on conn, as begin-read does.\n  It keeps the pages it sees from being reclaimed, so release it with\n  release-snapshot!, or use with-snapshot." },
    .{ "release-snapshot!", 1, 1, &fnDbAbortRead, "[snap]", "Releases the snapshot snap, as abort-read! does; returns nil." },
    .{ "snapshot?", 1, 1, &fnDbSnapshotQ, "[x]", "Returns true if x is a read transaction not yet released." },
};
const db_natives = table("db", db_rows);
const db_docs = docs(db_rows);

const string_rows = .{
    .{ "lower-case", 1, 1, &fnStringLowerCase, "[s]", "Returns s with its ASCII letters lower-case; every other character,\n  a multibyte one included, is unchanged." },
    .{ "upper-case", 1, 1, &fnStringUpperCase, "[s]", "Returns s with its ASCII letters upper-case; every other character,\n  a multibyte one included, is unchanged: (upper-case \"héllo\") is\n  \"HéLLO\"." },
    .{ "trim", 1, 1, &fnStringTrim, "[s]", "Returns s without whitespace at either end, whitespace as Java's\n  Character/isWhitespace reads it (U+00A0, the no-break space, stays)." },
    .{ "split", 2, 3, &fnStringSplit, "[s re] [s re limit]", "Returns a vector of the pieces of s between the matches of re, a\n  pattern or a literal string, with trailing empty pieces dropped. A\n  positive limit splits at most limit - 1 times; a negative one keeps\n  the trailing empty pieces." },
    .{ "triml", 1, 1, &fnStringTriml, "[s]", "Returns s without whitespace at its start, whitespace as trim reads\n  it." },
    .{ "trimr", 1, 1, &fnStringTrimr, "[s]", "Returns s without whitespace at its end, whitespace as trim reads it." },
    .{ "trim-newline", 1, 1, &fnStringTrimNewline, "[s]", "Returns s without every \\n and \\r at its end." },
    .{ "blank?", 1, 1, &fnStringBlankQ, "[s]", "Returns true if s is nil, empty, or only whitespace as trim reads it." },
    .{ "starts-with?", 2, 2, &fnStringStartsWithQ, "[s substr]", "Returns true if s starts with substr." },
    .{ "ends-with?", 2, 2, &fnStringEndsWithQ, "[s substr]", "Returns true if s ends with substr." },
    .{ "includes?", 2, 2, &fnStringIncludesQ, "[s substr]", "Returns true if s contains substr." },
    .{ "index-of", 2, 3, &fnStringIndexOf, "[s value] [s value from-index]", "Returns the code-point index of the first occurrence of value, a\n  string or char, in s at or after from-index (clamped to the string),\n  or nil when there is none." },
    .{ "last-index-of", 2, 3, &fnStringLastIndexOf, "[s value] [s value from-index]", "Returns the code-point index of the last occurrence of value, a\n  string or char, in s starting at or before from-index (default the\n  count), or nil when there is none." },
    .{ "join", 1, 2, &fnStringJoin, .consumes, "[coll] [separator coll]", "Returns a string of the elements of coll, each as str makes it (nil\n  as \"\"), separated by separator when given: (join \", \" [\"a\" nil 1])\n  is \"a, , 1\"." },
    .{ "replace", 3, 3, &fnStringReplace, "[s match replacement]", "Returns s with every non-overlapping match replaced, left to right.\n  match and replacement are both strings or both chars, taken\n  literally; or match is a pattern and replacement a string, in which\n  $1 and ${name} name groups, or a function of each match returning a\n  string." },
    .{ "replace-first", 3, 3, &fnStringReplaceFirst, "[s match replacement]", "Returns s with the first match replaced, or s itself when there is\n  none. A pattern match takes what replace takes; a string or char\n  match is found as it is, and replacement is a string or char." },
    .{ "re-quote-replacement", 1, 1, &fnStringReQuoteReplacement, "[replacement]", "Returns replacement with a backslash before each \\ and $, so a\n  pattern replace inserts it literally." },
};
const string_natives = table("nexis.string", string_rows);
const string_docs = docs(string_rows);

const math_rows = .{
    .{ "sqrt", 1, 1, &fnMathSqrt, "[a]", "Returns the positive square root of a as a double: (sqrt 16) is 4.0;\n  NaN for a negative a." },
    .{ "pow", 2, 2, &fnMathPow, "[a b]", "Returns a raised to the power b as a double, as Java's Math/pow:\n  (pow 2 10) is 1024.0." },
    .{ "floor", 1, 1, &fnMathFloor, "[a]", "Returns the largest integer value not above a: an integer unchanged,\n  a float's floor as a float, (floor 2.7) being 2.0." },
    .{ "ceil", 1, 1, &fnMathCeil, "[a]", "Returns the smallest integer value not below a: an integer unchanged,\n  a float's ceiling as a float, (ceil 2.1) being 3.0." },
    .{ "round", 1, 1, &fnMathRound, "[a]", "Returns the integer closest to a, halves rounding up, as Java's\n  Math/round: an integer unchanged, (round -2.5) being -2. NaN is 0; a\n  float past the long range is the long range's nearest end." },
    .{ "sin", 1, 1, mathOf1(builtinSin), "[a]", "Returns the sine of the angle a, in radians, as a double." },
    .{ "cos", 1, 1, mathOf1(builtinCos), "[a]", "Returns the cosine of the angle a, in radians, as a double." },
    .{ "tan", 1, 1, mathOf1(builtinTan), "[a]", "Returns the tangent of the angle a, in radians, as a double." },
    .{ "asin", 1, 1, mathOf1(std.math.asin), "[a]", "Returns the arc sine of a, in radians from -pi/2 to pi/2, as a\n  double; NaN when a is outside [-1, 1]." },
    .{ "acos", 1, 1, mathOf1(std.math.acos), "[a]", "Returns the arc cosine of a, in radians from 0 to pi, as a double;\n  NaN when a is outside [-1, 1]." },
    .{ "atan", 1, 1, mathOf1(std.math.atan), "[a]", "Returns the arc tangent of a, in radians from -pi/2 to pi/2, as a\n  double." },
    .{ "atan2", 2, 2, mathOf2(std.math.atan2), "[y x]", "Returns the angle, in radians from -pi to pi, of the point (x, y)\n  from the positive x axis, as a double." },
    .{ "sinh", 1, 1, mathOf1(std.math.sinh), "[x]", "Returns the hyperbolic sine of x as a double." },
    .{ "cosh", 1, 1, mathOf1(std.math.cosh), "[x]", "Returns the hyperbolic cosine of x as a double." },
    .{ "tanh", 1, 1, mathOf1(std.math.tanh), "[x]", "Returns the hyperbolic tangent of x as a double." },
    .{ "exp", 1, 1, mathOf1(builtinExp), "[a]", "Returns e raised to the power a, as a double." },
    .{ "expm1", 1, 1, mathOf1(std.math.expm1), "[x]", "Returns e raised to the power x, minus 1, as a double, accurate for\n  x near zero." },
    .{ "log", 1, 1, mathOf1(builtinLog), "[a]", "Returns the natural logarithm of a as a double: ##-Inf for zero, NaN\n  for a negative a." },
    .{ "log10", 1, 1, mathOf1(builtinLog10), "[a]", "Returns the base-10 logarithm of a as a double: ##-Inf for zero, NaN\n  for a negative a." },
    .{ "log1p", 1, 1, mathOf1(std.math.log1p), "[x]", "Returns the natural logarithm of 1 + x as a double, accurate for x\n  near zero." },
    .{ "cbrt", 1, 1, mathOf1(std.math.cbrt), "[a]", "Returns the cube root of a as a double." },
    .{ "hypot", 2, 2, mathOf2(std.math.hypot), "[x y]", "Returns the square root of x squared plus y squared as a double,\n  without intermediate overflow or underflow; ##Inf when either is\n  infinite, even if the other is NaN." },
    .{ "signum", 1, 1, mathOf1(signum), "[d]", "Returns -1.0 or 1.0 by the sign of d, or d itself as a double when\n  it is a zero or NaN." },
    .{ "to-radians", 1, 1, mathOf1(toRadians), "[deg]", "Returns the angle deg, in degrees, in radians, as a double." },
    .{ "to-degrees", 1, 1, mathOf1(toDegrees), "[r]", "Returns the angle r, in radians, in degrees, as a double:\n  (to-degrees PI) is 180.0." },
};
const math_natives = table("nexis.math", math_rows);
const math_docs = docs(math_rows);

const internal_rows = .{
    // Records.
    .{ "#%register-record-type", 2, 2, &fnRegisterRecordType },
    .{ "#%make-record", 2, 3, &fnMakeRecord },
    .{ "#%record?", 1, 1, &fnRecordQ },
    .{ "#%record-type-id", 1, 1, &fnRecordTypeId },
    // A sorted collection a macro returned, as a form (MACROEXPAND.md §5).
    .{ "#%sorted-map", 0, null, &fnSortedMap },
    .{ "#%sorted-set", 0, null, &fnSortedSet },
    // Protocols.
    .{ "#%register-protocol", 2, 2, &fnRegisterProtocol },
    .{ "#%protocol-fn", 2, 2, &fnProtocolFn },
    // defrecord inline protocol impls.
    .{ "#%extend-record-impl", 4, 4, &fnExtendRecordImpl },
    // extend-protocol / extend-type / satisfies?.
    .{ "#%extend-builtin-impl", 4, 4, &fnExtendBuiltinImpl },
    .{ "#%extend-default-impl", 3, 3, &fnExtendDefaultImpl },
    // try: the keyword-matcher test the expander emits.
    .{ "#%catch-matches?", 2, 2, &fnCatchMatches },
    .{ "#%raise", 2, 3, &fnRaise },
    // `& {:keys ...}`: the rest seq as a map.
    .{ "#%kwargs", 1, 1, &fnKwargs },
    .{ "#%load-next", 2, 2, &fnLoadNext },
    .{ "#%unbind-root", 1, 1, &fnUnbindRoot },
    // deftest and run-tests: the name of the current namespace.
    .{ "#%current-ns", 0, 0, &fnCurrentNs },
    // delay: the record a delay is (core.nx `delay`, `force`).
    .{ "#%delay", 1, 1, &fnDelay },
    // lazy-seq: an unrealized block over the body's function (core.nx).
    .{ "#%lazy-seq", 1, 1, &fnLazySeq },
    // The force under realize-caught (core.nx, docs/LAZY.md §6).
    .{ "#%force", 1, 1, &fnForce },
    // sequence with a transducer (core.nx, docs/LAZY.md §10).
    .{ "#%sequence", 2, 3, &fnSequenceXform },
    // with-out-str: capture what the print functions write.
    .{ "#%push-out", 0, 0, &fnPushOut },
    .{ "#%pop-out", 0, 0, &fnPopOut },
    // A multimethod's cached method (core.nx `mm-call`, STDLIB.md §9.3).
    .{ "#%mm-lookup", 3, 3, &fnMmLookupLeaf, .leaf, &fnMmLookup },
    // doc, find-doc, apropos and dir (core.nx, STDLIB.md §10).
    .{ "#%special-docs", 0, 0, &fnSpecialDocs },
    .{ "#%namespace-doc", 1, 1, &fnNamespaceDoc },
    .{ "#%the-ns-name", 1, 1, &fnTheNsName },
    // The natives under nexis.sys (sys.nx, STDLIB.md §11).
    .{ "#%getenv", 0, 1, &fnGetenv },
    .{ "#%cwd", 0, 0, &fnCwd },
    // nexis.shell/sh (shell.nx, STDLIB.md §11).
    .{ "#%sh", 2, 2, &fnSh },
    // The natives under nexis.time (time.nx, STDLIB.md §12).
    .{ "#%now-ms", 0, 0, &fnNowMs },
    .{ "#%format-instant", 1, 1, &fnFormatInstant },
    .{ "#%parse-instant", 1, 1, &fnParseInstant },
    // The natives under nexis.json (json.nx, STDLIB.md §13).
    .{ "#%json-read", 2, 2, &fnJsonRead },
    .{ "#%json-write", 2, 2, &fnJsonWrite },
};
const internal_natives = table("nexis.internal", internal_rows);

const simd_rows = .{
    .{ "sum", 1, 1, &fnSimdSum, "[xs]", "Returns the sum of the typed vector xs: for an i64 vector the exact\n  integer, a bignum past the fixnum range; for an f64 vector a float,\n  whose low bits can differ from (reduce + xs). 0 or 0.0 when empty." },
    .{ "dot", 2, 2, &fnSimdDot, "[xs ys]", "Returns the dot product of the typed vectors xs and ys, of the result\n  kind sum gives, exact at any size for i64. Element types that differ\n  are :kind-mismatch; lengths that differ, :invalid-argument." },
    .{ "scale", 2, 2, &fnSimdScale, "[xs k]", "Returns a typed vector of xs's element type with every element\n  multiplied by k. For i64, k must be an integer within i64 and a\n  product outside i64 is :arithmetic-overflow; for f64, k is any number." },
    .{ "map", 2, 2, &fnSimdMap, "[f xs]", "Returns a typed vector of xs's element type whose elements are (f x)\n  of each element x of xs; a result that does not fit the element type\n  is :kind-mismatch." },
};
const simd_natives = table("nexis.simd", simd_rows);
const simd_docs = docs(simd_rows);

// =============================================================================
// Implementations
// =============================================================================

/// `(list & xs)` → a fresh list of the args; `(list)` is `()`.
fn fnList(vm: *VM, args: []const Value) VmError!Value {
    return list_mod.fromSlice(vm.ensureHeap(), args) catch VmError.OutOfMemory;
}

/// `(list* a b ... s)` → the leading args consed onto `s` as `cons`
/// conses, so a lazy `s` is not realized; the last arg's seq itself
/// when there are none: nil for an empty `s`, as Clojure's.
fn fnListStar(vm: *VM, args: []const Value) VmError!Value {
    const s = args[args.len - 1];
    if (args.len == 1) return seq_mod.seqOf(vm, s);
    var result = switch (s.kind()) {
        .nil, .list, .lazy_seq => s,
        else => try seq_mod.seqOf(vm, s),
    };
    var i = args.len - 1;
    while (i > 0) {
        i -= 1;
        result = try consOnto(vm, args[i], result);
    }
    return result;
}

/// `(cons x s)` → `x` in front of the seq of `s`, any seqable: a list
/// cell onto nil, a list or a vector's view; a lazy seq's cons cell
/// onto a lazy seq, which is not realized (LAZY.md §4).
fn fnCons(vm: *VM, args: []const Value) VmError!Value {
    const s = args[1];
    return switch (s.kind()) {
        .nil, .list, .lazy_seq => consOnto(vm, args[0], s),
        else => consOnto(vm, args[0], try seq_mod.seqOf(vm, s)),
    };
}

/// `x` in front of `s`: nil, a list or a lazy seq.
fn consOnto(vm: *VM, x: Value, s: Value) VmError!Value {
    const heap = vm.ensureHeap();
    return switch (s.kind()) {
        .nil => list_mod.cons(heap, x, list_mod.empty(heap) catch return VmError.OutOfMemory),
        .list => list_mod.cons(heap, x, s),
        else => lazy_mod.cons(heap, x, s),
    } catch VmError.OutOfMemory;
}

/// `(first s)` → head of the seq, or nil if empty/nil.
fn fnFirst(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    return switch (s.kind()) {
        .nil => value_mod.nilValue(),
        .list => if (list_mod.isEmpty(s)) value_mod.nilValue() else list_mod.head(s),
        .persistent_vector => if (vector_mod.isEmpty(s)) value_mod.nilValue() else vector_mod.nth(s, 0),
        .lazy_seq => seq_mod.first(vm, s),
        else => blk: {
            var it = try makeSeqIter(vm, s);
            break :blk (try it.next()) orelse value_mod.nilValue();
        },
    };
}

/// `(rest s)` → seq of everything after the first element.
/// Always returns a list (empty if input is empty/nil); of a vector,
/// an O(1) view (LIST.md §1).
fn fnRest(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    const heap = vm.ensureHeap();
    return switch (s.kind()) {
        .nil => list_mod.empty(heap) catch VmError.OutOfMemory,
        .list => if (list_mod.isEmpty(s))
            list_mod.empty(heap) catch VmError.OutOfMemory
        else
            list_mod.tail(s),
        .persistent_vector => list_mod.ofVector(heap, s, @min(1, vector_mod.count(s))) catch VmError.OutOfMemory,
        .lazy_seq => seq_mod.rest(vm, s),
        else => blk: {
            var items = try collectSeq(vm, s);
            defer items.deinit(vm.allocator);
            if (items.items.len <= 1) break :blk list_mod.empty(heap) catch VmError.OutOfMemory;
            break :blk try buildListFromSlice(vm, items.items[1..]);
        },
    };
}

/// The element at position `i` of any seqable, nil past its end;
/// walks only as far as `i`.
fn nthOfSeq(vm: *VM, coll: Value, i: usize) VmError!Value {
    var it = try makeSeqIter(vm, coll);
    for (0..i) |_| _ = (try it.next()) orelse return value_mod.nilValue();
    return (try it.next()) orelse value_mod.nilValue();
}

fn fnSecond(vm: *VM, args: []const Value) VmError!Value {
    return nthOfSeq(vm, args[0], 1);
}

/// A count of `take` or `drop` (`requireCount`) as the fixnum the
/// producer counts down.
fn lazyCount(v: Value) VmError!Value {
    return value_mod.fromFixnum(@intCast(try requireCount(v))).?;
}

/// `(take n coll)` → the lazy seq of the first `n` elements, one at a
/// time (docs/LAZY.md §7).
fn fnTake(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-take", args);
    return seq_mod.make(vm, seq_mod.op_take, &.{ try lazyCount(args[0]), args[1] });
}

/// `(drop n coll)` → the lazy seq of `coll` without its first `n`
/// elements, walked when it is realized.
fn fnDrop(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-drop", args);
    return seq_mod.make(vm, seq_mod.op_drop, &.{ try lazyCount(args[0]), args[1] });
}

/// `(some pred coll)` → the first truthy `(pred x)`, else nil;
/// `(every? pred coll)` → whether `(pred x)` is truthy for every x.
/// Both stop at the first element that decides. Rooting: each built
/// element is only the next call's argument (GC.md §11.5, class 2);
/// both consume `coll` (`consumingSeqIter`).
fn fnSome(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, args[1], scope);
    var cb = vm_mod.Callback.init(vm, args[0], 1);
    while (try it.next()) |x| {
        const r = try cb.call1(x);
        if (r.isTruthy()) return r;
    }
    return value_mod.nilValue();
}

fn fnEveryQ(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, args[1], scope);
    var cb = vm_mod.Callback.init(vm, args[0], 1);
    while (try it.next()) |x| {
        if (!(try cb.call1(x)).isTruthy()) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

/// `(next s)` → `(seq (rest s))`: nil when nothing follows.
fn fnNext(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .lazy_seq) return seq_mod.next(vm, args[0]);
    const r = try fnRest(vm, args);
    return if (list_mod.isEmpty(r)) value_mod.nilValue() else r;
}

/// `(seq coll)` → nil for nil or an empty collection, otherwise a
/// list of the collection's elements (a non-empty list is
/// returned as is; a vector gives an O(1) view, LIST.md §1). Maps
/// yield `[k v]` entries, strings chars.
fn fnSeq(vm: *VM, args: []const Value) VmError!Value {
    return seq_mod.seqOf(vm, args[0]);
}

/// `(count coll)` → element count. nil → 0. Lists, vectors,
/// maps, records, sets and strings; a string counts Unicode
/// scalars, not bytes.
const fnCount = countNative(false);

/// `count` as a leaf (VM.md §6): a lazy seq (realized to its end) and
/// an entity (read from the store) go the general way, which consumes
/// the argument.
const fnCountLeaf = countNative(true);

/// `count`, the leaf's or the general native: one body, not a leaf
/// that calls the general one, so the count is returned where the
/// caller reads it, not copied on (`docs/VM.md` §8).
fn countNative(comptime leaf: bool) *const fn (*VM, []const Value) VmError!Value {
    return struct {
        fn call(vm: *VM, args: []const Value) VmError!Value {
            const c = args[0];
            const n: i64 = switch (c.kind()) {
                .nil => 0,
                .list => @intCast(list_mod.count(c)),
                .persistent_vector => @intCast(vector_mod.count(c)),
                .typed_vector => @intCast(typed_vector_mod.count(c)),
                .persistent_map => @intCast(champ_mod.mapCount(c)),
                .record => @intCast(champ_mod.mapCount(record_mod.fieldsOf(c))),
                .nextomic_entity => if (leaf) return VmError.NeedsReentry else @intCast(champ_mod.mapCount(try nextomic_mod.natives.entityMap(vm, c))),
                .persistent_set => @intCast(champ_mod.setCount(c)),
                .sorted_map, .sorted_set => @intCast(sorted_mod.count(c)),
                .string => @intCast(string_mod.codepointCount(c) catch return VmError.Utf8Error),
                .transient => @intCast(try transientCount(vm, c)),
                .lazy_seq => if (leaf) return VmError.NeedsReentry else @intCast(try countConsumed(vm, c)),
                else => return VmError.KindMismatch,
            };
            const v = value_mod.fromFixnum(n) orelse return VmError.ArithmeticOverflow;
            return v;
        }
    }.call;
}

/// How many elements a lazy seq `count` consumes has: an unrealized
/// range or `repeat` of a count is computed (`seq.countOf`); any other
/// seq is walked, keeping only the walk's place.
fn countConsumed(vm: *VM, s: Value) VmError!usize {
    if (seq_mod.pureOf(s)) |p| switch (p) {
        .range, .repeat_n => return seq_mod.countOf(vm, s),
        else => {},
    };
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, s, scope);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// `(nth coll n)` → element at index `n`. Throws on out-of-
/// bounds. Negative indices rejected as `IndexOutOfBounds`.
///
/// `(nth coll n default)` → element at index `n`, or `default`
/// if out-of-bounds. nil coll always returns default (nil without
/// one, as in Clojure). Required
/// by destructuring: `[a b c]` against a 2-element source binds
/// c to nil, not throw.
fn fnNth(vm: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const idx_v = args[1];
    const has_default = args.len > 2;
    const default = if (has_default) args[2] else value_mod.nilValue();
    if (idx_v.kind() != .fixnum) return VmError.KindMismatch;
    // Kind-check the receiver BEFORE consulting `idx < 0` /
    // `has_default`. Otherwise the negative-index path would
    // return `default` even when `coll` is non-indexable (e.g.
    // `(nth 123 -1 :d) → :d`), a type-soundness violation —
    // `:kind-mismatch` must fire on
    // non-indexable receivers regardless of index sign or
    // default arity.
    switch (coll.kind()) {
        .nil, .list, .persistent_vector, .typed_vector, .string => {},
        .transient => if (coll.subkind() != transient_mod.subkind_transient_vector) return VmError.KindMismatch,
        // Walking a lazy seq may run code: not in a leaf (VM.md §6).
        .lazy_seq => return VmError.NeedsReentry,
        else => return VmError.KindMismatch,
    }
    const idx = idx_v.asFixnum();
    if (idx >= 0) {
        const u_idx: usize = @intCast(idx);
        // Each element is returned by a statement of its own, so it is
        // stored where the caller reads it, not merged in a temporary
        // and copied on (docs/VM.md §8).
        switch (coll.kind()) {
            .nil => return default,
            .list => {
                const at = list_mod.drop(coll, u_idx);
                if (!list_mod.isEmpty(at)) return list_mod.head(at);
            },
            .persistent_vector => if (u_idx < vector_mod.count(coll)) return vector_mod.nth(coll, u_idx),
            .transient => if (u_idx < try transientCount(vm, coll)) {
                return transient_mod.vectorNthBang(coll, u_idx) catch |err| return transientFailure(vm, err);
            },
            .typed_vector => if (typed_vector_mod.nth(vm.ensureHeap(), coll, u_idx)) |x| {
                return x;
            } else |err| switch (err) {
                error.IndexOutOfBounds => {},
                error.OutOfMemory => return VmError.OutOfMemory,
            },
            // A string's char at code point `i`, indexed by Unicode
            // scalar to match `(count s)`; malformed UTF-8 is
            // `:utf8-error`.
            .string => if (string_mod.codepointAt(coll, u_idx)) |scalar| {
                const c = value_mod.fromChar(scalar) orelse return VmError.Utf8Error;
                return c;
            } else |err| switch (err) {
                error.OutOfBounds => {},
                error.InvalidUtf8 => return VmError.Utf8Error,
            },
            else => return VmError.KindMismatch,
        }
    }
    if (has_default) return default;
    return VmError.IndexOutOfBounds;
}

/// `nth` called other than as a leaf: a lazy seq is walked, realizing
/// as far as the index; everything else is the leaf's.
fn fnNthGeneral(vm: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    if (coll.kind() != .lazy_seq) return fnNth(vm, args);
    // `seq.nthOf` computes an unrealized range's element.
    if (args[1].kind() != .fixnum) return VmError.KindMismatch;
    const has_default = args.len > 2;
    const idx = args[1].asFixnum();
    const found = if (idx < 0) null else try seq_mod.nthOf(vm, coll, @intCast(idx));
    return found orelse if (has_default) args[2] else VmError.IndexOutOfBounds;
}

/// `(empty? coll)` → true if coll has zero elements. nil →
/// true (matches Clojure). Strings: byte-length test (O(1)) —
/// empty UTF-8 ↔ zero codepoints, so no codepoint walk needed. A
/// transient is counted, as Clojure 1.12's `empty?` counts one.
fn fnEmptyQ(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    const is_empty = switch (c.kind()) {
        .nil => true,
        .list => list_mod.isEmpty(c),
        .persistent_vector => vector_mod.isEmpty(c),
        .typed_vector => typed_vector_mod.count(c) == 0,
        .persistent_map => champ_mod.mapCount(c) == 0,
        .record => champ_mod.mapCount(record_mod.fieldsOf(c)) == 0,
        // An entity always has its :db/id.
        .nextomic_entity => false,
        .persistent_set => champ_mod.setCount(c) == 0,
        .sorted_map, .sorted_set => sorted_mod.count(c) == 0,
        .string => string_mod.byteLen(c) == 0,
        .transient => try transientCount(vm, c) == 0,
        .lazy_seq => (try seq_mod.seqOf(vm, c)).isNil(),
        else => return VmError.KindMismatch,
    };
    return value_mod.fromBool(is_empty);
}

/// `(identity x)` → x.
fn fnIdentity(_: *VM, args: []const Value) VmError!Value {
    return args[0];
}

/// `(nil? x)` → true iff x is nil.
fn fnNilQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .nil);
}

/// `(some? x)` → true iff x is NOT nil.
fn fnSomeQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() != .nil);
}

// =============================================================================
// Arithmetic + comparison
// =============================================================================
//
// Every operator runs on the numeric tower in vm.zig (`numAdd`
// and friends), the same code the `math:*` / `cmp:*` opcodes
// use, so an inlined `(+ a b)` and a first-class `+` agree
// exactly. Variadic semantics match Clojure:
//
//   (+)        => 0            (*)        => 1
//   (+ x)      => x            (- x)      => negation
//   (+ x y...) => left fold    (/ x)      => reciprocal
//   (< x)      => true         (< x y z)  => chained
//
// `=` is value equality (dispatch.equal, cross-type false);
// `==` is numeric equality with contagion (`(== 1 1.0)` is true).

fn requireNumber(v: Value) VmError!Value {
    if (!vm_mod.isNumber(v)) return VmError.KindMismatch;
    return v;
}

fn requireFixnum(v: Value) VmError!i64 {
    if (v.kind() != .fixnum) return VmError.KindMismatch;
    return v.asFixnum();
}

const BinaryNum = *const fn (*heap_mod.Heap, Value, Value) VmError!Value;

/// Left fold of `op` over `args`, which must be non-empty. A
/// promoted result lives on the VM's heap.
fn foldNumbers(vm: *VM, op: BinaryNum, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var acc = try requireNumber(args[0]);
    for (args[1..]) |x| acc = try op(heap, acc, x);
    return acc;
}

fn fnAdd(vm: *VM, args: []const Value) VmError!Value {
    // Two fixnums whose sum is one add inline, as `math:add` does.
    if (args.len == 2 and args[0].isFixnum() and args[1].isFixnum()) {
        if (value_mod.fromFixnum(args[0].asFixnum() + args[1].asFixnum())) |v| return v;
    }
    if (args.len == 0) return value_mod.fromFixnum(0).?;
    return foldNumbers(vm, &vm_mod.numAdd, args);
}

fn fnSub(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return vm_mod.numNeg(vm.ensureHeap(), args[0]);
    return foldNumbers(vm, &vm_mod.numSub, args);
}

fn fnMul(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return value_mod.fromFixnum(1).?;
    // From the last argument that is not an integer on, the product is
    // exact in any order: once it is a bignum, `bignum.product` makes
    // the rest off the heap, where a fold would leave every partial
    // product.
    var ints = args.len;
    while (ints > 0 and vm_mod.isInteger(args[ints - 1])) ints -= 1;
    const heap = vm.ensureHeap();
    var acc = try requireNumber(args[0]);
    for (args[1..], 1..) |x, i| {
        if (i >= ints and acc.kind() == .bignum) return bignum_mod.product(heap, acc, args[i..]) catch VmError.OutOfMemory;
        acc = try vm_mod.numMul(heap, acc, x);
    }
    return acc;
}

fn fnDiv(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return vm_mod.numDiv(vm.ensureHeap(), value_mod.fromFixnum(1).?, args[0]);
    return foldNumbers(vm, &vm_mod.numDiv, args);
}

fn fnQuot(vm: *VM, args: []const Value) VmError!Value {
    return vm_mod.numQuot(vm.ensureHeap(), args[0], args[1]);
}

fn fnRem(vm: *VM, args: []const Value) VmError!Value {
    return vm_mod.numRem(vm.ensureHeap(), args[0], args[1]);
}

fn fnMod(vm: *VM, args: []const Value) VmError!Value {
    return vm_mod.numMod(vm.ensureHeap(), args[0], args[1]);
}

/// Chained comparison: true iff every adjacent pair satisfies
/// `cmp`. A lone argument is true whatever it is, as Clojure's
/// `([x] true)`.
fn chainCompare(cmp: vm_mod.NumCmp, args: []const Value) VmError!Value {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!try vm_mod.numCompare(cmp, args[i], args[i + 1])) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

fn fnLt(_: *VM, args: []const Value) VmError!Value {
    return chainCompare(.lt, args);
}

fn fnLte(_: *VM, args: []const Value) VmError!Value {
    return chainCompare(.lte, args);
}

fn fnGt(_: *VM, args: []const Value) VmError!Value {
    return chainCompare(.gt, args);
}

fn fnGte(_: *VM, args: []const Value) VmError!Value {
    return chainCompare(.gte, args);
}

fn fnNumEq(_: *VM, args: []const Value) VmError!Value {
    return chainCompare(.eq, args);
}

fn fnEq(vm: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return value_mod.fromBool(true);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!try equalTop(vm, args[i], args[i + 1])) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

/// `=` of two arguments. Two sequential values of which one is a lazy
/// seq are walked in step here, in native context (LAZY.md §6): their
/// bodies' throws propagate, and an infinite seq against a finite one
/// is decided at the finite one's end, as `LazySeq.equiv` walks. Their
/// elements, and every other pair, are `dispatch.equal`'s.
fn equalTop(vm: *VM, a: Value, b: Value) VmError!bool {
    const lazy_pair = (a.kind() == .lazy_seq or b.kind() == .lazy_seq) and isSequential(a.kind()) and isSequential(b.kind());
    if (!lazy_pair or a.identicalTo(b)) return dispatch_mod.equal(a, b);
    var ia = try makeSeqIter(vm, a);
    var ib = try makeSeqIter(vm, b);
    while (true) {
        const x = (try ia.next()) orelse return (try ib.next()) == null;
        const y = (try ib.next()) orelse return false;
        if (!dispatch_mod.equal(x, y)) return false;
    }
}

fn fnNotEq(vm: *VM, args: []const Value) VmError!Value {
    const same = try fnEq(vm, args);
    return value_mod.fromBool(!same.asBool());
}

fn fnInc(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].isFixnum()) {
        if (value_mod.fromFixnum(args[0].asFixnum() + 1)) |v| return v;
    }
    return vm_mod.numAdd(vm.ensureHeap(), args[0], value_mod.fromFixnum(1).?);
}

fn fnDec(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].isFixnum()) {
        if (value_mod.fromFixnum(args[0].asFixnum() - 1)) |v| return v;
    }
    return vm_mod.numSub(vm.ensureHeap(), args[0], value_mod.fromFixnum(1).?);
}

/// `(long x)`: a number as an integer of any size, a float by its
/// integer part (NaN is 0, as Java's cast makes it), a char as its
/// code point (SEMANTICS.md §2.2).
fn fnLong(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .char) return value_mod.fromFixnum(args[0].asChar()).?;
    if (args[0].isFloat() and std.math.isNan(args[0].asFloat())) return value_mod.fromFixnum(0).?;
    return vm_mod.numLong(vm.ensureHeap(), args[0]);
}

/// `(int x)`, `(short x)`, `(byte x)`: as `long`, within the range of
/// Java's `T`, else `:invalid-argument`, as Clojure's casts check; NaN
/// is 0, as Java's cast makes it.
fn castTo(comptime T: type) *const fn (*VM, []const Value) VmError!Value {
    return &struct {
        fn call(vm: *VM, args: []const Value) VmError!Value {
            const x = args[0];
            const min = std.math.minInt(T);
            const max = std.math.maxInt(T);
            if (x.isFloat()) {
                // Truncated first, then range-checked, as Clojure's
                // boxed cast (`longCast`, then the narrowing check).
                const f = @trunc(x.asFloat());
                if (std.math.isNan(f)) return value_mod.fromFixnum(0).?;
                if (!(f >= min and f <= max)) return VmError.InvalidArgument;
            }
            const r = try fnLong(vm, args);
            return if (r.kind() == .fixnum and r.asFixnum() >= min and r.asFixnum() <= max) r else VmError.InvalidArgument;
        }
    }.call;
}

/// `(float x)`: as `double`, within Java's `float` range, else
/// `:invalid-argument`, as Clojure's cast checks. The one float type
/// is f64, so the value is not rounded to single precision.
fn fnFloat(_: *VM, args: []const Value) VmError!Value {
    const d = try vm_mod.numDouble(args[0]);
    const f = d.asFloat();
    if (!std.math.isNan(f) and @abs(f) > std.math.floatMax(f32)) return VmError.InvalidArgument;
    return d;
}

/// `(char n)`: the char with code point `n`; a char is itself. A
/// value that is no Unicode scalar is `:invalid-argument`.
fn fnChar(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .char) return args[0];
    const n = try requireFixnum(args[0]);
    if (n < 0 or n > 0x10FFFF) return VmError.InvalidArgument;
    return value_mod.fromChar(@intCast(n)) orelse VmError.InvalidArgument;
}

/// `(parse-long s)` / `(parse-double s)`: the number `s` spells in
/// full as Java's `Long/valueOf` / `Double/valueOf` read it, else nil;
/// a non-string is `:kind-mismatch`, as in Clojure (STDLIB.md §2).
fn fnParseLong(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const text = string_mod.asBytes(args[0]);
    const digits = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
    if (digits.len == 0) return value_mod.nilValue();
    for (digits) |c| if (!std.ascii.isDigit(c)) return value_mod.nilValue();
    const n = std.fmt.parseInt(i64, text, 10) catch return value_mod.nilValue();
    return integerValue(vm, n);
}

fn fnParseDouble(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const text = javaDouble(string_mod.asBytes(args[0])) orelse return value_mod.nilValue();
    return value_mod.fromFloat(std.fmt.parseFloat(f64, text) catch return value_mod.nilValue());
}

/// The part of `s` for `parseFloat` when `s` is in the grammar
/// Clojure's `parse-double` admits (Java's `Double/valueOf`): control
/// and space bytes around an optional sign and `NaN`, `Infinity`, a
/// decimal with an optional exponent, or a hex significand with a
/// binary exponent, the last two with an optional `[fFdD]` suffix.
/// Null otherwise.
fn javaDouble(s: []const u8) ?[]const u8 {
    var lo: usize = 0;
    var hi = s.len;
    while (lo < hi and s[lo] <= ' ') lo += 1;
    while (hi > lo and s[hi - 1] <= ' ') hi -= 1;
    const t = s[lo..hi];
    const sign = @intFromBool(t.len > 0 and (t[0] == '+' or t[0] == '-'));
    const body = t[sign..];
    if (std.mem.eql(u8, body, "NaN") or std.mem.eql(u8, body, "Infinity")) return t;
    const suffix = body.len > 0 and std.mem.findScalar(u8, "fFdD", body[body.len - 1]) != null;
    const number = t[0 .. t.len - @intFromBool(suffix)];
    const hex = body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X');
    const isDigit: *const fn (u8) bool = if (hex) &std.ascii.isHex else &std.ascii.isDigit;
    var i: usize = sign + @as(usize, if (hex) 2 else 0);
    var mantissa: usize = 0;
    while (i < number.len and isDigit(number[i])) : (i += 1) mantissa += 1;
    if (i < number.len and number[i] == '.') {
        i += 1;
        while (i < number.len and isDigit(number[i])) : (i += 1) mantissa += 1;
    }
    if (mantissa == 0) return null;
    if (i < number.len and std.mem.findScalar(u8, if (hex) "pP" else "eE", number[i]) != null) {
        i += 1;
        if (i < number.len and (number[i] == '+' or number[i] == '-')) i += 1;
        const digits = i;
        while (i < number.len and std.ascii.isDigit(number[i])) i += 1;
        if (i == digits) return null;
    } else if (hex) return null;
    return if (i == number.len) number else null;
}

/// An integer argument as an `i64`: a fixnum, or a bignum that fits.
fn intArg(v: Value) VmError!i64 {
    return switch (v.kind()) {
        .fixnum => v.asFixnum(),
        .bignum => bignum_mod.toI64(v) orelse VmError.ArithmeticOverflow,
        else => VmError.KindMismatch,
    };
}

/// `n` as a fixnum, or a bignum outside the fixnum range.
fn integerValue(vm: *VM, n: i64) VmError!Value {
    return value_mod.fromFixnum(n) orelse bignum_mod.fromI128(vm.ensureHeap(), n) catch VmError.OutOfMemory;
}

/// The bit operations are over 64-bit two's complement, as Java's
/// `long`; a shift count uses its low six bits.
fn bitFold(vm: *VM, args: []const Value, comptime op: enum { @"and", @"or", xor }) VmError!Value {
    var acc = try intArg(args[0]);
    for (args[1..]) |a| {
        const x = try intArg(a);
        acc = switch (op) {
            .@"and" => acc & x,
            .@"or" => acc | x,
            .xor => acc ^ x,
        };
    }
    return integerValue(vm, acc);
}

fn fnBitAnd(vm: *VM, args: []const Value) VmError!Value {
    return bitFold(vm, args, .@"and");
}

fn fnBitOr(vm: *VM, args: []const Value) VmError!Value {
    return bitFold(vm, args, .@"or");
}

fn fnBitXor(vm: *VM, args: []const Value) VmError!Value {
    return bitFold(vm, args, .xor);
}

fn fnBitNot(vm: *VM, args: []const Value) VmError!Value {
    return integerValue(vm, ~try intArg(args[0]));
}

fn shiftCount(v: Value) VmError!u6 {
    return @truncate(@as(u64, @bitCast(try intArg(v))));
}

fn fnBitShiftLeft(vm: *VM, args: []const Value) VmError!Value {
    return integerValue(vm, try intArg(args[0]) << try shiftCount(args[1]));
}

fn fnBitShiftRight(vm: *VM, args: []const Value) VmError!Value {
    return integerValue(vm, try intArg(args[0]) >> try shiftCount(args[1]));
}

fn fnUnsignedBitShiftRight(vm: *VM, args: []const Value) VmError!Value {
    const x: u64 = @bitCast(try intArg(args[0]));
    return integerValue(vm, @bitCast(x >> try shiftCount(args[1])));
}

fn bitMask(v: Value) VmError!i64 {
    return @as(i64, 1) << try shiftCount(v);
}

fn fnBitTest(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(try intArg(args[0]) & try bitMask(args[1]) != 0);
}

fn fnBitSet(vm: *VM, args: []const Value) VmError!Value {
    return integerValue(vm, try intArg(args[0]) | try bitMask(args[1]));
}

fn fnBitClear(vm: *VM, args: []const Value) VmError!Value {
    return integerValue(vm, try intArg(args[0]) & ~try bitMask(args[1]));
}

/// The generator behind `rand`, `rand-int`, `shuffle` and
/// `random-uuid`, seeded from the I/O's entropy at first use. One
/// isolate, one thread.
var prng: ?std.Random.DefaultPrng = null;

fn random(vm: *VM) std.Random {
    if (prng == null) {
        var seed: [8]u8 = undefined;
        ioOf(vm).random(&seed);
        prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));
    }
    return prng.?.random();
}

/// `(rand)` → a double in [0, 1); `(rand n)` → in [0, n).
fn fnRand(vm: *VM, args: []const Value) VmError!Value {
    const r = random(vm).float(f64);
    if (args.len == 0) return value_mod.fromFloat(r);
    return value_mod.fromFloat(r * try asDouble(args[0]));
}

/// `(rand-int n)` → `(int (rand n))`, as Clojure's: an integer in
/// [0, n), in (n, 0] for a negative `n`, 0 for 0.
fn fnRandInt(vm: *VM, args: []const Value) VmError!Value {
    const n = try intArg(args[0]);
    if (n == 0) return value_mod.fromFixnum(0).?;
    const m: i64 = @intCast(random(vm).uintLessThan(u64, @abs(n)));
    return integerValue(vm, if (n > 0) m else -m);
}

/// `(double x)`: a number as an f64.
fn fnDouble(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numDouble(args[0]);
}

fn numMax(_: *heap_mod.Heap, a: Value, b: Value) VmError!Value {
    return vm_mod.numExtremum(true, a, b);
}

fn numMin(_: *heap_mod.Heap, a: Value, b: Value) VmError!Value {
    return vm_mod.numExtremum(false, a, b);
}

fn fnMax(vm: *VM, args: []const Value) VmError!Value {
    return foldNumbers(vm, &numMax, args);
}

fn fnMin(vm: *VM, args: []const Value) VmError!Value {
    return foldNumbers(vm, &numMin, args);
}

fn fnAbs(vm: *VM, args: []const Value) VmError!Value {
    return vm_mod.numAbs(vm.ensureHeap(), args[0]);
}

// ---- nexis.math (docs/TOOLING.md §4) ----
//
// `sqrt` and `pow` are over doubles and return a float for any
// number, as `Math/sqrt` and `Math/pow` do; `floor`, `ceil` and
// `round` return an integer unchanged, `floor` and `ceil` of a
// float the float they name, `round` of a float the nearest integer
// (halves up, `Math/round`) as a fixnum or bignum.

fn asDouble(v: Value) VmError!f64 {
    return (try vm_mod.numDouble(v)).asFloat();
}

/// A `nexis.math` function of one or two doubles, as Java's `Math`
/// method of its name: any number in, a float out; NaN and the
/// infinities pass through as IEEE has them, never an error.
fn mathOf1(comptime f: anytype) *const fn (*VM, []const Value) VmError!Value {
    return struct {
        fn call(_: *VM, args: []const Value) VmError!Value {
            return value_mod.fromFloat(f(@as(f64, try asDouble(args[0]))));
        }
    }.call;
}

fn mathOf2(comptime f: anytype) *const fn (*VM, []const Value) VmError!Value {
    return struct {
        fn call(_: *VM, args: []const Value) VmError!Value {
            return value_mod.fromFloat(f(@as(f64, try asDouble(args[0])), @as(f64, try asDouble(args[1]))));
        }
    }.call;
}

fn builtinSin(x: f64) f64 {
    return @sin(x);
}

fn builtinCos(x: f64) f64 {
    return @cos(x);
}

fn builtinTan(x: f64) f64 {
    return @tan(x);
}

fn builtinExp(x: f64) f64 {
    return @exp(x);
}

fn builtinLog(x: f64) f64 {
    return @log(x);
}

fn builtinLog10(x: f64) f64 {
    return @log10(x);
}

/// Java's `Math/signum`: a zero (either sign) and NaN are themselves,
/// anything else 1.0 with its sign.
fn signum(x: f64) f64 {
    return if (x == 0 or std.math.isNan(x)) x else std.math.copysign(@as(f64, 1.0), x);
}

/// Java's `Math/toRadians` and `Math/toDegrees`: one multiplication
/// by the constant Java rounds, so the results are Java's to the bit.
fn toRadians(x: f64) f64 {
    return x * 0.017453292519943295;
}

fn toDegrees(x: f64) f64 {
    return x * 57.29577951308232;
}

fn fnMathSqrt(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromFloat(@sqrt(try asDouble(args[0])));
}

fn fnMathPow(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromFloat(std.math.pow(f64, try asDouble(args[0]), try asDouble(args[1])));
}

fn fnMathFloor(_: *VM, args: []const Value) VmError!Value {
    if (vm_mod.isInteger(args[0])) return args[0];
    return value_mod.fromFloat(@floor(try asDouble(args[0])));
}

fn fnMathCeil(_: *VM, args: []const Value) VmError!Value {
    if (vm_mod.isInteger(args[0])) return args[0];
    return value_mod.fromFloat(@ceil(try asDouble(args[0])));
}

/// Java's `Math/round`: the floor, plus one when the fraction is at
/// least a half, computed without `f + 0.5` (which rounds for
/// values just under a half and past 2^52, where every double is an
/// integer already); NaN is 0, and past the long range the result
/// clamps to it, the infinities included.
fn fnMathRound(vm: *VM, args: []const Value) VmError!Value {
    if (vm_mod.isInteger(args[0])) return args[0];
    const f = try asDouble(args[0]);
    if (std.math.isNan(f)) return value_mod.fromFixnum(0).?;
    const r = @floor(f);
    const n = if (f - r >= 0.5) r + 1 else r;
    const heap = vm.ensureHeap();
    // -2^63 is a double; 2^63 is the first one past the range.
    if (n >= 0x1p63) return bignum_mod.fromI64(heap, std.math.maxInt(i64)) catch VmError.OutOfMemory;
    if (n <= -0x1p63) return bignum_mod.fromI64(heap, std.math.minInt(i64)) catch VmError.OutOfMemory;
    return vm_mod.numLong(heap, value_mod.fromFloat(n));
}

fn fnNot(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(!args[0].isTruthy());
}

/// `zero?` / `pos?` / `neg?`: all three are false on NaN, which
/// `numSign` reports as no order at all.
fn fnZeroQ(_: *VM, args: []const Value) VmError!Value {
    const sign = (try vm_mod.numSign(args[0])) orelse return value_mod.fromBool(false);
    return value_mod.fromBool(sign == .eq);
}

fn fnPosQ(_: *VM, args: []const Value) VmError!Value {
    const sign = (try vm_mod.numSign(args[0])) orelse return value_mod.fromBool(false);
    return value_mod.fromBool(sign == .gt);
}

fn fnNegQ(_: *VM, args: []const Value) VmError!Value {
    const sign = (try vm_mod.numSign(args[0])) orelse return value_mod.fromBool(false);
    return value_mod.fromBool(sign == .lt);
}

/// `even?` / `odd?` are integer-only, as in Clojure.
fn fnOddQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(!try vm_mod.numEven(args[0]));
}

fn fnEvenQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(try vm_mod.numEven(args[0]));
}

fn fnNumberQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(vm_mod.isNumber(args[0]));
}

fn fnIntegerQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(vm_mod.isInteger(args[0]));
}

fn fnFloatQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .float);
}

fn fnNanQ(_: *VM, args: []const Value) VmError!Value {
    _ = try requireNumber(args[0]);
    return value_mod.fromBool(args[0].isFloat() and std.math.isNan(args[0].asFloat()));
}

fn fnInfiniteQ(_: *VM, args: []const Value) VmError!Value {
    _ = try requireNumber(args[0]);
    return value_mod.fromBool(args[0].isFloat() and std.math.isInf(args[0].asFloat()));
}

// =============================================================================
// apply + HOFs
// =============================================================================
//
// `apply`, `map`, `reduce`, `filter` and the rest call back into
// the VM through `VM.callValue`. They propagate
// `VmError.ControlTransferred` unchanged so a throw from inside a
// user fn lands at the outer handler.
//
// Rooting (GC.md §11.5): a collection can run inside any `callValue`.
// A native's own arguments are rooted for its whole call (the
// caller's slots, or the root stack when reached through
// `callValue`), and so is everything reachable from them. Two kinds
// of value are not: a value a callback returned, and a value the
// iterator built (a map's `[k v]` entry, a boxed typed-vector
// element). Every native below that keeps either across a further
// callback pushes it on a `RootScope` first, the second kind by
// iterating with `rootedSeqIter`; one whose only held value is the
// next call's argument and is not used again (`reduce`, `reduce-kv`,
// `db/alter!`, `db/reduce-tree`) needs nothing, because the callee
// roots its argument for as long as it uses it. A callee's fn-level
// `recur` overwrites its argument slots, so a value passed to a call
// and used after it is the native's own to root.
//
// A native that calls one function once per element, with one
// argument count, calls it through a `vm_mod.Callback` (VM.md §6):
// `callValue`'s effect, errors and rooting, with what cannot change
// between the calls decided at the first.

/// `(apply f x1 x2 ... xs)` calls `f` with the elements of
/// the last arg seq spliced in after the leading args. `xs` is
/// consumed: a lazy seq's elements wait in a `Results` as the walk
/// hands them out, so the realized seq behind the walk is garbage
/// while it goes on.
fn fnApply(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const last = args[args.len - 1];
    var combined: std.ArrayList(Value) = .empty;
    defer combined.deinit(vm.allocator);
    combined.appendSlice(vm.allocator, args[1 .. args.len - 1]) catch return VmError.OutOfMemory;
    // The built elements are the call's arguments (GC.md §11.5, class 2);
    // a walk that runs no code cannot collect before the call.
    if (!walksLazily(last)) {
        try appendSeqValues(vm, last, &combined);
        return try vm.callValue(f, combined.items);
    }
    const scope = vm.rootScope();
    defer scope.release();
    var results = try consumedInto(vm, last, scope);
    defer results.release();
    var c = vector_mod.Cursor.init(try results.vector());
    combined.ensureUnusedCapacity(vm.allocator, c.count) catch return VmError.OutOfMemory;
    while (c.next()) |x| combined.appendAssumeCapacity(x);
    return try vm.callValue(f, combined.items);
}

/// `(map f coll & colls)` → the lazy seq of `(f x1 x2 ...)`, ending
/// at the shortest collection (docs/LAZY.md §7): a chunk of 32 at a
/// time over one chunked collection, one element at a time otherwise.
fn fnMap(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-map", args);
    if (args.len == 2) return seq_mod.make(vm, seq_mod.op_map, args[0..2]);
    if (args.len - 1 <= seq_mod.map_n_inline) return seq_mod.make(vm, seq_mod.op_map_n, args);
    const colls = vector_mod.fromSlice(vm.ensureHeap(), args[1..]) catch return VmError.OutOfMemory;
    return seq_mod.make(vm, seq_mod.op_map_n, &.{ args[0], colls });
}

/// Add `(f x1 x2 ...)` for every position of the shortest of `colls`
/// to `results`, which roots each as it comes. One coll is walked a
/// run at a time (a vector's leaf, a lazy chunk), each run's calls
/// made in batches whose results go straight where `results` keeps
/// them (VM.md §6); `held` is a root slot `nextChunk` may write, and
/// `cursor` the root slot that holds the last coll, which `mapv`
/// consumes: its walk keeps its place there (`SeqIter.cursor`).
fn mapInto(vm: *VM, f: Value, colls: []const Value, results: *Results, held: usize, cursor: usize) VmError!void {
    if (colls.len == 1) {
        var it = try makeSeqIter(vm, colls[0]);
        it.cursor = cursor;
        var cb = vm_mod.Callback.init(vm, f, 1);
        var buf: [results_chunk]Value = undefined;
        while (try nextRun(&it, &buf, held)) |xs| {
            // A walk that hands out one element at a time calls as it goes.
            if (xs.len == 1) {
                try results.add(try cb.call1(xs[0]));
                continue;
            }
            var rest = xs;
            while (rest.len > 0) {
                const room = try results.room(rest.len);
                try cb.each(rest[0..room.n], room.out);
                results.fill += room.n;
                rest = rest[room.n..];
            }
        }
        return;
    }

    const iters = vm.allocator.alloc(SeqIter, colls.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(iters);
    for (colls, 0..) |c, i| iters[i] = try makeSeqIter(vm, c);
    iters[colls.len - 1].cursor = cursor;
    const call_args = vm.allocator.alloc(Value, colls.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    var cb = vm_mod.Callback.init(vm, f, @intCast(colls.len));
    outer: while (true) {
        for (iters, 0..) |*it, i| {
            call_args[i] = (try it.next()) orelse break :outer;
        }
        try results.add(try cb.call(call_args));
    }
}

/// `it.nextChunk` with nothing held, an unrealized fixnum range
/// computed a run at a time into `buf`, for a batch (VM.md §6).
fn nextRun(it: *SeqIter, buf: *[results_chunk]Value, slot: usize) VmError!?[]const Value {
    switch (it.state) {
        .range => |*r| {
            if (r.left == 0) return null;
            const k: usize = @intCast(@min(r.left, buf.len));
            for (buf[0..k]) |*x| {
                x.* = value_mod.fromFixnum(r.x).?;
                r.x += r.step;
            }
            r.left -= k;
            return buf[0..k];
        },
        else => return it.nextChunk(slot, value_mod.nilValue()),
    }
}

/// `(reduce f coll)` / `(reduce f init coll)` → left fold. With
/// no init the first element seeds the fold and an empty
/// collection yields `(f)`.
fn fnReduce(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const coll = args[args.len - 1];
    // `coll` is consumed: its slot in this scope keeps the walk, or the
    // pure seq's state (an `iterate`'s function, a `cycle`'s source).
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, coll, scope);
    if (seq_mod.pureOf(coll)) |p| return reducePure(vm, f, if (args.len == 3) args[1] else null, p);
    var acc = if (args.len == 3) args[1] else (try it.next()) orelse return try vm.callValue(f, &.{});
    var cb = vm_mod.Callback.init(vm, f, 2);
    // The accumulator is the next call's argument, and a lazy `coll`'s
    // next step may collect before that call (GC.md §11.5, class 5):
    // it goes into a root slot before such a step.
    try scope.push(acc);
    // Each run's calls in batches (VM.md §6), which stop after a record.
    while (try it.nextChunk(scope.base + 1, acc)) |xs| {
        // A walk that hands out one element at a time calls as it goes.
        if (xs.len == 1) {
            acc = try cb.call2(acc, xs[0]);
            if (isReduced(vm, acc)) return reducedValue(acc);
            continue;
        }
        var rest = xs;
        while (rest.len > 0) {
            const folded = try cb.fold(acc, rest);
            acc = folded.acc;
            if (isReduced(vm, acc)) return reducedValue(acc);
            rest = rest[folded.used..];
        }
    }
    return acc;
}

/// `reduce` over an unrealized range or repeat, computing the
/// elements instead of realizing them (docs/LAZY.md §7): nothing is
/// allocated but what `f` allocates, and nothing is cached. Such a seq
/// is never empty. The accumulator waits in a root slot between calls,
/// as `fnReduce`'s.
fn reducePure(vm: *VM, f: Value, init: ?Value, p: seq_mod.Pure) VmError!Value {
    var cb = vm_mod.Callback.init(vm, f, 2);
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(value_mod.nilValue());
    const heap = vm.ensureHeap();
    switch (p) {
        .range => |r| {
            const n = seq_mod.rangeCount(r.start, r.end, r.step);
            var x = r.start;
            var acc = init orelse blk: {
                x += r.step;
                break :blk value_mod.fromFixnum(r.start).?;
            };
            var i: u64 = if (init == null) 1 else 0;
            // The calls in batches over the elements left (VM.md §6),
            // which stop after a record.
            while (i < n) {
                vm.roots.items[scope.base] = acc;
                const folded = try cb.foldRange(acc, value_mod.fromFixnum(x).?, r.step, @intCast(n - i));
                acc = folded.acc;
                if (isReduced(vm, acc)) return reducedValue(acc);
                i += folded.used;
                x += r.step * @as(i64, @intCast(folded.used));
            }
            return acc;
        },
        // Past the fixnum range each element is a bignum the step before
        // allocated, which only the call it goes to holds, and only
        // until its last use there (COMPILER.md §4.9): it waits in a
        // second root slot, as `.iterate`'s does.
        .range_inf => |start| {
            try scope.push(start);
            var x = start;
            var acc = init orelse blk: {
                x = try vm_mod.numAdd(heap, x, value_mod.fromFixnum(1).?);
                break :blk start;
            };
            while (true) {
                vm.roots.items[scope.base] = acc;
                vm.roots.items[scope.base + 1] = x;
                acc = try cb.call2(acc, x);
                if (isReduced(vm, acc)) return reducedValue(acc);
                x = try vm_mod.numAdd(heap, x, value_mod.fromFixnum(1).?);
            }
        },
        .repeat => |x| {
            var acc = init orelse x;
            while (true) {
                vm.roots.items[scope.base] = acc;
                acc = try cb.call2(acc, x);
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
        },
        .repeat_n => |r| {
            var acc = init orelse r.x;
            var i: i64 = if (init == null) 1 else 0;
            while (i < r.n) {
                vm.roots.items[scope.base] = acc;
                const folded = try cb.foldRange(acc, r.x, 0, @intCast(r.n - i));
                acc = folded.acc;
                if (isReduced(vm, acc)) return reducedValue(acc);
                i += @intCast(folded.used);
            }
            return acc;
        },
        // `x` and its successor wait in a second root slot while `f`
        // runs, as `Iterate.reduce` walks.
        .iterate => |it| {
            try scope.push(it.x);
            var x = it.x;
            var acc = init orelse blk: {
                x = try vm.callValue(it.f, &.{x});
                break :blk it.x;
            };
            var step = vm_mod.Callback.init(vm, it.f, 1);
            while (true) {
                vm.roots.items[scope.base] = acc;
                vm.roots.items[scope.base + 1] = x;
                acc = try cb.call2(acc, x);
                if (isReduced(vm, acc)) return reducedValue(acc);
                vm.roots.items[scope.base] = acc;
                x = try step.call1(x);
            }
        },
        .cycle => |all| {
            var acc: ?Value = init;
            while (true) {
                var it = try makeSeqIter(vm, all);
                while (try it.next()) |x| {
                    if (acc) |a| {
                        vm.roots.items[scope.base] = a;
                        const r = try cb.call2(a, x);
                        if (isReduced(vm, r)) return reducedValue(r);
                        acc = r;
                    } else acc = x;
                }
            }
        },
    }
}

/// `(reduced x)` → a value `reduce` returns at once, unwrapped;
/// a one-field record of the type `nexis.core/Reduced`, so
/// `reduced?` is a type test and `@` reads the value back.
fn fnReduced(vm: *VM, args: []const Value) VmError!Value {
    const type_id = vm.ensureReducedType() catch return VmError.OutOfMemory;
    const heap = vm.ensureHeap();
    const key = vm.ensureInterner().internKeywordValue("val") catch return VmError.OutOfMemory;
    const empty = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const fields = try mapPut(heap, empty, key, args[0]);
    return record_mod.make(heap, type_id, fields) catch VmError.OutOfMemory;
}

fn fnReducedQ(vm: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(isReduced(vm, args[0]));
}

/// The kind first: a fold's accumulator is rarely a record.
fn isReduced(vm: *VM, v: Value) bool {
    if (v.kind() != .record) return false;
    const type_id = vm.home().reduced_type_id orelse return false;
    return record_mod.typeId(v) == type_id;
}

/// The value inside a `reduced` record.
fn reducedValue(r: Value) Value {
    var it = champ_mod.mapIter(record_mod.fieldsOf(r));
    const entry = it.next() orelse return value_mod.nilValue();
    return entry.value;
}

/// `(reduce-kv f init m)` → `(f acc k v)` over a map's entries or
/// a vector's index/element pairs.
fn fnReduceKv(vm: *VM, args: []const Value) VmError!Value {
    var cb = vm_mod.Callback.init(vm, args[0], 3);
    var acc = args[1];
    const coll = args[2];
    switch (coll.kind()) {
        .nil => {},
        .persistent_map, .record, .sorted_map => {
            var it = MapEntries.of(coll).?;
            while (it.next()) |e| {
                acc = try cb.call(&.{ acc, e.key, e.value });
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
        },
        .persistent_vector => {
            var c = vector_mod.Cursor.init(coll);
            var i: i64 = 0;
            while (c.next()) |x| : (i += 1) {
                acc = try cb.call(&.{ acc, value_mod.fromFixnum(i).?, x });
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
        },
        else => return VmError.KindMismatch,
    }
    return acc;
}

/// What `filterv` keeps.
const Sieve = enum { keep_truthy, keep_falsy, keep_result };

/// Add what `mode` keeps of `coll` to `results`, which roots each as
/// it comes. An element the walk built (a map's entry) waits in the
/// root slot `held` while the predicate runs, since the predicate may
/// `recur` over its argument, and in `results` once kept; one dropped
/// is garbage (GC.md §11.5, class 4). `coll` is consumed: the root slot
/// `cursor` holds it, and its walk keeps its place there.
fn sieveInto(vm: *VM, mode: Sieve, pred: Value, coll: Value, results: *Results, held: usize, cursor: usize) VmError!void {
    var it = try makeSeqIter(vm, coll);
    it.cursor = cursor;
    var cb = vm_mod.Callback.init(vm, pred, 1);
    var buf: [results_chunk]Value = undefined;
    while (try nextRun(&it, &buf, held)) |xs| {
        // A run of the source's own elements, rooted with it: the
        // predicate's calls in batches (VM.md §6), whose results are
        // only tested for truth.
        if (mode != .keep_result and xs.len > 1) {
            var rest = xs;
            while (rest.len > 0) {
                const part = rest[0..@min(rest.len, results_chunk)];
                var truth: [results_chunk]Value = undefined;
                try cb.each(part, .{ .slots = &truth });
                for (part, truth[0..part.len]) |x, r| if (r.isTruthy() == (mode == .keep_truthy)) try results.add(x);
                rest = rest[part.len..];
            }
            continue;
        }
        for (xs) |x| {
            vm.roots.items[held] = x;
            const r = try cb.call1(x);
            const kept: ?Value = switch (mode) {
                .keep_truthy => if (r.isTruthy()) x else null,
                .keep_falsy => if (r.isTruthy()) null else x,
                .keep_result => if (r.isNil()) null else r,
            };
            if (kept) |v| try results.add(v);
        }
    }
}

/// `(filter pred coll)` → the lazy seq of x where `(pred x)` is
/// truthy; `(remove pred coll)` where it is falsy; `(keep f coll)` the
/// non-nil `(f x)` (docs/LAZY.md §7).
fn fnFilter(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-filter", args);
    return seq_mod.make(vm, seq_mod.op_filter, args[0..2]);
}

fn fnRemove(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-remove", args);
    return seq_mod.make(vm, seq_mod.op_remove, args[0..2]);
}

fn fnKeep(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-keep", args);
    return seq_mod.make(vm, seq_mod.op_keep, args[0..2]);
}

// =============================================================================
// Collection utilities
// =============================================================================
//
// Persistent collection construction + access:
//
//   vector       (& xs)     persistent vector from args
//   vec          (s)        persistent vector from any seqable
//   hash-map     (& kvs)    persistent map from k/v pairs
//   hash-set     (& xs)     persistent set from args
//   assoc        (m k v)    persistent put (map, record or vector)
//   dissoc       (m k)      persistent remove (map or record)
//   get          (m k)      lookup (map/set/vector); nil if missing
//   get          (m k def)  lookup with default
//   contains?    (m k)      key/element presence check
//   keys         (m)        seq of map keys
//   vals         (m)        seq of map values
//   conj         (coll & xs) persistent add (list: cons; vector: push;
//                            map: assoc with [k v] pair; set: include)
//
// A hash map or set iterates in its trie's order, the same for equal
// collections (STDLIB.md §5).

fn fnVector(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    return vector_mod.fromSlice(heap, args) catch VmError.OutOfMemory;
}

/// `(vec coll)` → the elements of any seqable as a vector. A lazy
/// seq's walk may run code, and `vec` consumes it: the elements go
/// straight into the vector as it is built (`vecConsumed`).
fn fnVec(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    if (walksLazily(s)) return vecConsumed(vm, s);
    return switch (s.kind()) {
        .nil => {
            const heap = vm.ensureHeap();
            return vector_mod.empty(heap) catch VmError.OutOfMemory;
        },
        // A fresh vector carries no metadata (SEMANTICS §7), as
        // Clojure's `vec` clears it.
        .persistent_vector => if (heap_mod.Heap.asHeapHeader(s).getMeta() == null) s else fnWithMeta(vm, &.{ s, value_mod.nilValue() }),
        .list => {
            // A list that views a whole vector (`sort`'s, `reverse`'s, a
            // vector's seq) has that vector's elements: the vector
            // itself, without its metadata.
            if (list_mod.viewCursor(s)) |c| if (c.index == 0) return fnVec(vm, &.{vector_mod.valueFromVectorHeader(c.root)});
            return vecOfSeq(vm, s);
        },
        else => vecOfSeq(vm, s),
    };
}

/// `(vec s)` of a seqable whose walk runs no code, in one gathering.
fn vecOfSeq(vm: *VM, s: Value) VmError!Value {
    var items = try collectSeq(vm, s);
    defer items.deinit(vm.allocator);
    return vector_mod.fromSlice(vm.ensureHeap(), items.items) catch VmError.OutOfMemory;
}

/// `(hash-map k v ...)`, `(hash-set x ...)`: built at once, each node
/// allocated once (CHAMP.md §8.1); a later duplicate key's value wins.
fn fnHashMap(vm: *VM, args: []const Value) VmError!Value {
    if (args.len % 2 != 0) return VmError.ArityMismatch;
    // Flat key, value pairs are `Entry`s laid end to end.
    const entries: [*]const champ_mod.Entry = @ptrCast(args.ptr);
    return champ_mod.mapFromEntries(vm.ensureHeap(), entries[0 .. args.len / 2], &dispatch_mod.hashValue, &dispatch_mod.equal) catch VmError.OutOfMemory;
}

fn fnHashSet(vm: *VM, args: []const Value) VmError!Value {
    return champ_mod.setFromElements(vm.ensureHeap(), args, &dispatch_mod.hashValue, &dispatch_mod.equal) catch VmError.OutOfMemory;
}

/// `(set coll)` → the elements of any seqable as a hash set; a set
/// itself without its metadata, as Clojure's. Built from every element
/// at once, each node allocated once, which costs half the cycles of
/// conj'ing each on a transient at a million elements, so a lazy seq
/// is not consumed: `(into #{} s)` consumes it (`docs/PERF.md` §3.31).
fn fnSet(vm: *VM, args: []const Value) VmError!Value {
    if (isSet(args[0].kind())) {
        if (heap_mod.Heap.asHeapHeader(args[0]).getMeta() == null) return args[0];
        return fnWithMeta(vm, &.{ args[0], value_mod.nilValue() });
    }
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    return fnHashSet(vm, items.items);
}

/// `(subvec v start)` / `(subvec v start end)` → the elements
/// `start..end` of a vector as a new vector; bounds outside
/// `0..count` are `:index-out-of-bounds`.
fn fnSubvec(vm: *VM, args: []const Value) VmError!Value {
    const v = args[0];
    if (v.kind() != .persistent_vector) return VmError.KindMismatch;
    const n = vector_mod.count(v);
    const start = try requireFixnum(args[1]);
    const end = if (args.len == 3) try requireFixnum(args[2]) else @as(i64, @intCast(n));
    if (start < 0 or end < start or end > n) return VmError.IndexOutOfBounds;
    const items = vm.allocator.alloc(Value, @intCast(end - start)) catch return VmError.OutOfMemory;
    defer vm.allocator.free(items);
    for (items, @as(usize, @intCast(start))..) |*slot, i| slot.* = vector_mod.nth(v, i);
    return vector_mod.fromSlice(vm.ensureHeap(), items) catch VmError.OutOfMemory;
}

/// `(identical? a b)` → whether the two Values are the same bits:
/// the same immediate, or the same heap object.
fn fnIdenticalQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].tag == args[1].tag and args[0].payload == args[1].payload);
}

/// `(assoc coll k v & kvs)` → persistent put. Maps and records
/// key by value; vectors index by fixnum where the index may be
/// at most the count (one past the end appends); nil becomes a
/// map.
fn fnAssoc(vm: *VM, args: []const Value) VmError!Value {
    if (args.len % 2 != 1) return VmError.ArityMismatch;
    if (args[0].kind() == .sorted_map) return sortedAddAll(vm, args[0], args[1..]);
    var coll = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        coll = try assocOne(vm, coll, args[i], args[i + 1]);
    }
    return coll;
}

/// `assoc` as a leaf (VM.md §6): into a vector, and into nil, a hash
/// map or a record by keys off the heap, which hash without walking
/// anything; a key on the heap or any other collection goes the
/// general way.
fn fnAssocLeaf(vm: *VM, args: []const Value) VmError!Value {
    switch (args[0].kind()) {
        .persistent_vector => {},
        .nil, .persistent_map, .record => {
            var i: usize = 1;
            while (i < args.len) : (i += 2) if (args[i].kind().isHeap()) return VmError.NeedsReentry;
        },
        else => return VmError.NeedsReentry,
    }
    return fnAssoc(vm, args);
}

fn assocOne(vm: *VM, coll: Value, k: Value, v: Value) VmError!Value {
    const heap = vm.ensureHeap();
    return switch (coll.kind()) {
        .persistent_map => mapPut(heap, coll, k, v),
        .nil => mapPut(heap, champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory, k, v),
        .record => blk: {
            const new_fields = try mapPut(heap, record_mod.fieldsOf(coll), k, v);
            break :blk record_mod.withFields(heap, coll, new_fields) catch return VmError.OutOfMemory;
        },
        .persistent_vector => blk: {
            if (k.kind() != .fixnum) return VmError.KindMismatch;
            const idx = k.asFixnum();
            const n = vector_mod.count(coll);
            if (idx < 0 or @as(usize, @intCast(idx)) > n) return VmError.IndexOutOfBounds;
            const u_idx: usize = @intCast(idx);
            if (u_idx == n) break :blk vector_mod.conj(heap, coll, v) catch return VmError.OutOfMemory;
            break :blk vector_mod.assoc(heap, coll, u_idx, v) catch VmError.OutOfMemory;
        },
        else => VmError.KindMismatch,
    };
}

/// `(dissoc m k & ks)` → persistent remove from a map or record; a
/// record without one of its declared fields is a map.
fn fnDissoc(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .sorted_map) return sortedRemoveAll(vm, args[0], args[1..]);
    const heap = vm.ensureHeap();
    var coll = args[0];
    for (args[1..]) |k| {
        coll = switch (coll.kind()) {
            .persistent_map => champ_mod.mapDissoc(heap, coll, k, &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory,
            .nil => coll,
            .record => blk: {
                const new_fields = champ_mod.mapDissoc(heap, record_mod.fieldsOf(coll), k, &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
                // Without a declared field it is no longer the type: a
                // plain map keeping the metadata, as Clojure's record
                // `without` makes it (PROTOCOLS.md §0).
                if (isDeclaredField(vm, coll, k)) {
                    if (heap_mod.Heap.asHeapHeader(coll).getMeta() == null) break :blk new_fields;
                    break :blk try fnWithMeta(vm, &.{ new_fields, try fnMeta(vm, &.{coll}) });
                }
                break :blk record_mod.withFields(heap, coll, new_fields) catch return VmError.OutOfMemory;
            },
            else => return VmError.KindMismatch,
        };
    }
    return coll;
}

/// Whether `k` is a field the record `rec`'s `defrecord` declared.
fn isDeclaredField(vm: *VM, rec: Value, k: Value) bool {
    if (k.kind() != .keyword) return false;
    const entry = vm.recordType(record_mod.typeId(rec)) orelse return false;
    const name = vm.ensureInterner().keywordName(k.asKeywordId());
    for (entry.field_names) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

/// `(disj s x & xs)` → set without the elements.
fn fnDisj(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .sorted_set) return sortedRemoveAll(vm, args[0], args[1..]);
    const heap = vm.ensureHeap();
    var coll = args[0];
    for (args[1..]) |x| {
        coll = switch (coll.kind()) {
            .persistent_set => champ_mod.setDisj(heap, coll, x, &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory,
            .nil => coll,
            else => return VmError.KindMismatch,
        };
    }
    return coll;
}

/// `(get m k)` / `(get m k default)`: never throws for the kind of
/// `m`; a value that is not a collection has no entries (Clojure's
/// `RT.get`).
fn fnGet(vm: *VM, args: []const Value) VmError!Value {
    const default = if (args.len > 2) args[2] else value_mod.nilValue();
    if (args[0].kind() == .string) return (try stringIndex(args[0], args[1])) orelse default;
    if (args[0].kind() == .typed_vector) return (try typedVectorIndex(vm, args[0], args[1])) orelse default;
    // A key the order cannot place is an error, as in Clojure
    // (SORTED.md §6).
    if (sorted_mod.isSortedKind(args[0].kind())) return vm_mod.lookupIn(vm, args[0], args[1], default);
    return vm_mod.lookup(args[0], args[1], default) catch |err| if (err == VmError.KindMismatch) default else err;
}

/// `get` as a leaf (VM.md §6). It refuses what only `fnGet` may run:
/// a sorted collection (its comparator), an entity (the store), and a
/// hashed collection searched by a key on the heap, whose hash and `=`
/// may realize a lazy seq or walk nested data.
fn fnGetLeaf(vm: *VM, args: []const Value) VmError!Value {
    switch (args[0].kind()) {
        .sorted_map, .sorted_set, .nextomic_entity => return VmError.NeedsReentry,
        .persistent_map, .persistent_set, .record, .transient => if (args[1].kind().isHeap()) return VmError.NeedsReentry,
        else => {},
    }
    return fnGet(vm, args);
}

/// The element at fixnum index `k` of typed vector `tv`, or null
/// when `k` is not a fixnum or not in range (the tolerance `get`
/// shows a vector).
fn typedVectorIndex(vm: *VM, tv: Value, k: Value) VmError!?Value {
    if (k.kind() != .fixnum or k.asFixnum() < 0) return null;
    return typed_vector_mod.nth(vm.ensureHeap(), tv, @intCast(k.asFixnum())) catch |err| switch (err) {
        error.IndexOutOfBounds => null,
        error.OutOfMemory => VmError.OutOfMemory,
    };
}

/// The char at fixnum index `k` of string `s`, or null when `k` is
/// not a fixnum or not in range (the same tolerance `get` shows a
/// vector).
fn stringIndex(s: Value, k: Value) VmError!?Value {
    if (k.kind() != .fixnum or k.asFixnum() < 0) return null;
    const scalar = string_mod.codepointAt(s, @intCast(k.asFixnum())) catch |err| switch (err) {
        error.OutOfBounds => return null,
        error.InvalidUtf8 => return VmError.Utf8Error,
    };
    return value_mod.fromChar(scalar) orelse VmError.Utf8Error;
}

fn fnContainsQ(vm: *VM, args: []const Value) VmError!Value {
    const coll = args[0];
    const k = args[1];
    return switch (coll.kind()) {
        .nil => value_mod.fromBool(false),
        .persistent_map => value_mod.fromBool(mapHas(coll, k)),
        .persistent_set => value_mod.fromBool(champ_mod.setContains(coll, k, &dispatch_mod.hashValue, &dispatch_mod.equal)),
        .persistent_vector => value_mod.fromBool(isIndex(k, vector_mod.count(coll))),
        .string => value_mod.fromBool((try stringIndex(coll, k)) != null),
        .sorted_map, .sorted_set => value_mod.fromBool((try vm_mod.sortedFind(vm, coll, k)) != null),
        .typed_vector => value_mod.fromBool(isIndex(k, typed_vector_mod.count(coll))),
        .record => value_mod.fromBool(mapHas(record_mod.fieldsOf(coll), k)),
        .nextomic_entity => value_mod.fromBool(try nextomic_mod.natives.entityHas(vm, coll, k)),
        .transient => value_mod.fromBool(if (coll.subkind() == transient_mod.subkind_transient_set)
            transient_mod.setContainsBang(coll, k, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err)
        else
            (try vm_mod.transientLookup(coll, k)) != null),
        else => return VmError.KindMismatch,
    };
}

/// Whether `k` is an index of a collection of `n` elements.
fn isIndex(k: Value, n: usize) bool {
    return k.kind() == .fixnum and k.asFixnum() >= 0 and @as(usize, @intCast(k.asFixnum())) < n;
}

fn fnKeys(vm: *VM, args: []const Value) VmError!Value {
    return mapPart(vm, args[0], .key);
}

fn fnVals(vm: *VM, args: []const Value) VmError!Value {
    return mapPart(vm, args[0], .value);
}

/// `(keys m)` / `(vals m)`: the keys or values of a map, record or
/// lazy entity as a list, nil when there are none (so `(if (keys m)
/// ...)` reads as in Clojure).
fn mapPart(vm: *VM, m: Value, part: enum { key, value }) VmError!Value {
    const map_v: Value = switch (m.kind()) {
        .nil => return value_mod.nilValue(),
        .persistent_map, .record, .sorted_map => m,
        .nextomic_entity => try nextomic_mod.natives.entityMap(vm, m),
        else => return VmError.KindMismatch,
    };
    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(vm.allocator);
    var it = MapEntries.of(map_v).?;
    while (it.next()) |e| {
        collected.append(vm.allocator, if (part == .key) e.key else e.value) catch return VmError.OutOfMemory;
    }
    if (collected.items.len == 0) return value_mod.nilValue();
    return try buildListFromSlice(vm, collected.items);
}

/// `(conj coll & xs)` — persistent add. Kind-specific:
///   list   → cons each x onto front (so order reverses for
///            multi-arg conj; matches Clojure)
///   vector → push each x to the end (left-to-right)
///   map    → each x must be a 2-element vector [k v]; assoc
///   set    → include each x
///   nil    → builds a list (Clojure makes (conj nil 1 2) => (2 1))
/// `(conj)` is `[]` and `(conj coll)` is `coll`, nil included.
fn fnConj(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return vector_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    if (args.len == 1) return args[0];
    const coll = args[0];
    const xs = args[1..];
    const heap = vm.ensureHeap();
    return switch (coll.kind()) {
        .nil => blk: {
            // Build a cons list in reverse order to match
            // Clojure's `(conj nil 1 2) => (2 1)` semantics.
            var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
            for (xs) |x| {
                result = list_mod.cons(heap, x, result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        .list => blk: {
            var result = coll;
            for (xs) |x| {
                result = list_mod.conj(heap, result, x) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        // `(cons x (seq s))`, realizing one step, as `LazySeq.cons`.
        .lazy_seq => blk: {
            var result = try seq_mod.seqOf(vm, coll);
            for (xs) |x| result = try consOnto(vm, x, result);
            break :blk result;
        },
        .persistent_vector, .persistent_map, .persistent_set => if (xs.len >= conj_in_place_min) try conjInPlace(vm, coll, xs) else switch (coll.kind()) {
            .persistent_vector => blk: {
                var result = coll;
                for (xs) |x| result = vector_mod.conj(heap, result, x) catch return VmError.OutOfMemory;
                break :blk result;
            },
            .persistent_set => blk: {
                var result = coll;
                for (xs) |x| result = champ_mod.setConj(heap, result, x, &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
                break :blk result;
            },
            else => try conjMap(vm, coll, xs),
        },
        .record => try conjMap(vm, coll, xs),
        .sorted_map => blk: {
            // The entries of every x as key-value pairs, all reachable
            // from the arguments.
            var kvs: std.ArrayList(Value) = .empty;
            defer kvs.deinit(vm.allocator);
            for (xs) |x| switch (x.kind()) {
                .nil => {},
                .persistent_map, .record, .sorted_map => {
                    var it = MapEntries.of(x).?;
                    while (it.next()) |e| kvs.appendSlice(vm.allocator, &.{ e.key, e.value }) catch return VmError.OutOfMemory;
                },
                .persistent_vector => {
                    if (vector_mod.count(x) != 2) return VmError.ArityMismatch;
                    kvs.appendSlice(vm.allocator, &.{ vector_mod.nth(x, 0), vector_mod.nth(x, 1) }) catch return VmError.OutOfMemory;
                },
                else => return VmError.KindMismatch,
            };
            break :blk try sortedAddAll(vm, coll, kvs.items);
        },
        .sorted_set => try sortedAddAll(vm, coll, xs),
        else => return VmError.KindMismatch,
    };
}

/// `conj` as a leaf (VM.md §6): onto nil, a list or a vector, which
/// only allocates; any other collection hashes or realizes, and goes
/// the general way.
fn fnConjLeaf(vm: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return fnConj(vm, args);
    return switch (args[0].kind()) {
        .nil, .list, .persistent_vector => fnConj(vm, args),
        else => VmError.NeedsReentry,
    };
}

/// A map or record with each `x` conj'd: a `[k v]` entry, every entry
/// of a map or record, or nothing for nil.
fn conjMap(vm: *VM, coll: Value, xs: []const Value) VmError!Value {
    var result = coll;
    for (xs) |x| {
        switch (x.kind()) {
            .nil => {},
            .persistent_map, .record, .sorted_map => {
                var it = MapEntries.of(x).?;
                while (it.next()) |e| result = try assocOne(vm, result, e.key, e.value);
            },
            .persistent_vector => {
                if (vector_mod.count(x) != 2) return VmError.ArityMismatch;
                result = try assocOne(vm, result, vector_mod.nth(x, 0), vector_mod.nth(x, 1));
            },
            else => return VmError.KindMismatch,
        }
    }
    return result;
}

/// `x` conj'd in place onto `t`, a transient over a collection of
/// `kind`: a vector, a hash set or a hash map.
inline fn conjBang(vm: *VM, kind: Kind, t: Value, x: Value) VmError!void {
    switch (kind) {
        .persistent_vector => _ = transient_mod.vectorConjBang(vm.ensureHeap(), t, x) catch |err| return transientFailure(vm, err),
        .persistent_set => try conjBangSet(vm, t, x),
        else => try conjBangMap(vm, t, x),
    }
}

/// From this many elements on, `conj` onto a vector, hash map or hash
/// set (and so `into`) builds through a transient: one root copy, and
/// then each element lands in place (TRANSIENT.md §1).
const conj_in_place_min = 4;

/// `coll` with every `xs` conj'd in place on a transient over it,
/// carrying `coll`'s metadata as the persistent path does (SEMANTICS
/// §7). No collection runs while it builds.
fn conjInPlace(vm: *VM, coll: Value, xs: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const t = transient_mod.transientFrom(heap, coll) catch |err| return transientFailure(vm, err);
    for (xs) |x| try conjBang(vm, coll.kind(), t, x);
    const result = transient_mod.persistentBang(t) catch |err| return transientFailure(vm, err);
    heap_mod.Heap.asHeapHeader(result).setMeta(heap_mod.Heap.asHeapHeader(coll).getMeta());
    return result;
}

/// `(frequencies coll)` → a map from each distinct element of `coll` to
/// the number of times it occurs, counted in place on a transient
/// (TRANSIENT.md §1): one lookup per element. No collection runs while
/// it counts.
fn fnFrequencies(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const t = transient_mod.transientFrom(heap, champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory) catch |err| return transientFailure(vm, err);
    // A lazy argument's next step may collect (GC.md §11.5, class 5),
    // and the argument is consumed.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(t);
    var it = try consumingSeqIter(vm, args[0], scope);
    while (try it.next()) |x| {
        const spot = transient_mod.mapLocateBang(t, x, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err);
        const n: i64 = if (champ_mod.mapSpotValue(spot)) |c| c.asFixnum() + 1 else 1;
        transient_mod.mapPutBang(heap, t, spot, x, value_mod.fromFixnum(n).?) catch |err| return transientFailure(vm, err);
    }
    return transient_mod.persistentBang(t) catch |err| transientFailure(vm, err);
}

/// `(group-by f coll)` → a map from each `(f x)` to the vector of the
/// xs it came from, in order. The map is a transient and each vector
/// a root of its own edited under the map's token as it stands at the
/// edit, so both grow in place (TRANSIENT.md §1, §4). Rooting (GC.md
/// §11.5, class 4): the transient, which reaches every vector, is on
/// the root scope across every call of `f`; `x` waits in a root slot
/// while `f` runs, since `f` may `recur` over its argument, and lands
/// in its vector, and `(f x)` in the map, before the next call.
fn fnGroupBy(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const f = args[0];
    const scope = vm.rootScope();
    defer scope.release();
    const t = transient_mod.transientFrom(heap, champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory) catch |err| return transientFailure(vm, err);
    try scope.push(t);
    var it = try consumingSeqIter(vm, args[1], scope);
    const held = vm.roots.items.len;
    try scope.push(value_mod.nilValue());
    var cb = vm_mod.Callback.init(vm, f, 1);
    while (try it.next()) |x| {
        vm.roots.items[held] = x;
        const k = try cb.call1(x);
        const spot = transient_mod.mapLocateBang(t, k, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err);
        const bucket = champ_mod.mapSpotValue(spot) orelse blk: {
            const fresh = vector_mod.empty(heap) catch return VmError.OutOfMemory;
            transient_mod.mapPutBang(heap, t, spot, k, fresh) catch |err| return transientFailure(vm, err);
            break :blk fresh;
        };
        transient_mod.vectorConjUnderBang(heap, t, bucket, x) catch |err| return transientFailure(vm, err);
    }
    return transient_mod.persistentBang(t) catch |err| transientFailure(vm, err);
}

// =============================================================================
// Sequence library
// =============================================================================
//
// Eager, list-producing (PLAN §23 #14). Every function takes any
// seqable receiver through `makeSeqIter` and builds its result
// with `buildListFromSlice`; vector-producing variants (`mapv`,
// `filterv`, `vec`) go through `vector_mod.fromSlice`.

/// `(range)` / `(range end)` / `(range start end)` / `(range start
/// end step)` → the lazy seq start, start+step, ... up to but not
/// including end (docs/LAZY.md §7): `(range)` counts from 0 for ever,
/// one element at a time; a finite range realizes 32 at a time, and
/// is `()` when empty. Any number works; the elements follow the
/// tower's contagion (`(range 0 1 0.25)` is `(0 0.25 0.5 0.75)`,
/// `(range 3.0)` is `(0 1 2)`). A zero step repeats `start` for ever,
/// `()` when `start` is `end`, as Clojure's.
fn fnRange(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return seq_mod.make(vm, seq_mod.op_range_inf, &.{value_mod.fromFixnum(0).?});
    for (args) |a| if (a.kind() != .fixnum) return rangeNumbers(vm, args);
    const start: i64 = if (args.len == 1) 0 else try requireFixnum(args[0]);
    const end: i64 = try requireFixnum(args[if (args.len == 1) 0 else 1]);
    const step: i64 = if (args.len == 3) try requireFixnum(args[2]) else 1;
    if (step == 0) return if (start == end) list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory else seq_mod.make(vm, seq_mod.op_repeat, args[0..1]);
    return seq_mod.makeRange(vm, start, end, step);
}

/// `range` over any numbers, through the tower.
fn rangeNumbers(vm: *VM, args: []const Value) VmError!Value {
    const start = if (args.len == 1) value_mod.fromFixnum(0).? else try requireNumber(args[0]);
    const end = try requireNumber(args[if (args.len == 1) 0 else 1]);
    const step = if (args.len == 3) try requireNumber(args[2]) else value_mod.fromFixnum(1).?;
    const sign = (try vm_mod.numSign(step)) orelse return VmError.InvalidArgument;
    const empty = list_mod.empty(vm.ensureHeap()) catch return VmError.OutOfMemory;
    if (try vm_mod.numCompare(.eq, start, end)) return empty;
    if (sign == .eq) return seq_mod.make(vm, seq_mod.op_repeat, &.{start});
    if (!try vm_mod.numCompare(if (sign == .gt) .lt else .gt, start, end)) return empty;
    return seq_mod.make(vm, seq_mod.op_range_num, &.{ start, end, step });
}

/// `(concat & colls)` → the lazy seq of every element in order,
/// passing a chunked coll's chunks through (docs/LAZY.md §7).
fn fnConcat(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    if (args.len == 0) return seq_mod.make(vm, seq_mod.op_concat, &.{ value_mod.nilValue(), value_mod.nilValue() });
    // `Heap.alloc` never collects: the list of the later colls needs no
    // root on its way into the block.
    const rest = list_mod.fromSlice(heap, args[1..]) catch return VmError.OutOfMemory;
    return seq_mod.make(vm, seq_mod.op_concat, &.{ args[0], rest });
}

/// `(mapcat f & colls)` → the concatenation of `(map f & colls)`, a
/// producer over the lazy seq of colls, so an infinite one works.
fn fnMapcat(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-mapcat", args);
    const mapped = try fnMap(vm, args);
    return seq_mod.make(vm, seq_mod.op_concat, &.{ value_mod.nilValue(), mapped });
}

/// `(into to from)` → `to` with every element of `from` conj'd;
/// `(into)` is `[]` and `(into to)` is `to`; `(into to xform from)`
/// through a transducer (docs/LAZY.md §10), whose `from` parameter the
/// compiler clears at its last move. `from` is consumed: a lazy seq is
/// walked by `intoConsumed`.
fn fnInto(vm: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return fnConj(vm, args);
    if (args.len == 3) return callCore(vm, "into-xform", args);
    // An empty vector with no metadata takes every element at once.
    const fresh = args[0].kind() == .persistent_vector and vector_mod.isEmpty(args[0]) and heap_mod.Heap.asHeapHeader(args[0]).getMeta() == null;
    if (walksLazily(args[1])) return if (fresh) vecConsumed(vm, args[1]) else intoConsumed(vm, args[0], args[1]);
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    if (items.items.len == 0) return args[0];
    if (fresh) {
        return vector_mod.fromSlice(vm.ensureHeap(), items.items) catch VmError.OutOfMemory;
    }
    // A sorted target's comparator, or the realizing of a lazy target,
    // can collect while `conj` runs; a map source's entries were built
    // by the walk and reach from nothing else, and `from` is consumed
    // (GC.md §11.5, class 4).
    const scope = vm.rootScope();
    defer scope.release();
    if (sorted_mod.isSortedKind(args[0].kind()) or args[0].kind() == .lazy_seq) try scope.pushAll(items.items);
    const conj_args = vm.allocator.alloc(Value, items.items.len + 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(conj_args);
    conj_args[0] = args[0];
    @memcpy(conj_args[1..], items.items);
    return fnConj(vm, conj_args);
}

/// Whether walking `coll` may run code, and so collect: a lazy seq, but
/// for an unrealized range, whose elements are computed (LAZY.md §7).
/// A native that consumes such a seq walks it with `consumingSeqIter`.
fn walksLazily(coll: Value) bool {
    if (coll.kind() != .lazy_seq) return false;
    const p = seq_mod.pureOf(coll) orelse return true;
    return p != .range;
}

/// `(vec s)` of a lazy seq `vec` or `into` consumes: its elements go
/// into a `Results` as the walk hands them out, so the realized seq
/// behind the walk is garbage while the vector grows.
fn vecConsumed(vm: *VM, s: Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, s, scope);
    var results = Results.init(vm);
    defer results.release();
    while (try it.next()) |x| try results.add(x);
    return results.vector();
}

/// `(into to s)` of a lazy seq `into` consumes, conj'ing each
/// element as the walk hands it out (Clojure's `reduce conj`): in place
/// on a transient over a vector, hash map or hash set, as
/// `conjInPlace`, and one `conj` at a time onto anything else. `to`
/// itself when `s` is empty. The element in hand is reachable from the
/// walk's place while it is conj'd; `to` and the result so far wait in
/// root slots, since the walk's steps, a sorted target's comparator or
/// a lazy target's realizing may collect.
fn intoConsumed(vm: *VM, to: Value, s: Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(to);
    var it = try consumingSeqIter(vm, s, scope);
    switch (to.kind()) {
        .persistent_vector, .persistent_map, .persistent_set => {
            var x = (try it.next()) orelse return to;
            const t = transient_mod.transientFrom(vm.ensureHeap(), to) catch |err| return transientFailure(vm, err);
            try scope.push(t);
            while (true) {
                try conjBang(vm, to.kind(), t, x);
                x = (try it.next()) orelse break;
            }
            const result = transient_mod.persistentBang(t) catch |err| return transientFailure(vm, err);
            heap_mod.Heap.asHeapHeader(result).setMeta(heap_mod.Heap.asHeapHeader(to).getMeta());
            return result;
        },
        // The slot `to` waits in holds the result so far.
        else => {
            var acc = to;
            while (try it.next()) |x| {
                acc = try fnConj(vm, &.{ acc, x });
                vm.roots.items[scope.base] = acc;
            }
            return acc;
        },
    }
}

/// `(mapv f & colls)` / `(filterv pred coll)` — vector results.
fn fnMapv(vm: *VM, args: []const Value) VmError!Value {
    // Over several colls, one's lazy step may collect while another's
    // element waits for the call: a coll whose walk would build its
    // elements (a map's entries) is walked as its seq, rooted here
    // before `Results` opens its own scope (GC.md §11.5, class 5).
    const scope = vm.rootScope();
    defer scope.release();
    const colls = vm.allocator.dupe(Value, args[1..]) catch return VmError.OutOfMemory;
    defer vm.allocator.free(colls);
    if (colls.len > 1) for (colls) |*c| switch (c.kind()) {
        .nil, .list, .lazy_seq, .persistent_vector, .persistent_set, .string => {},
        else => {
            c.* = try seq_mod.seqOf(vm, c.*);
            try scope.push(c.*);
        },
    };
    // A slot the walk may write and the last coll, which is consumed,
    // below the scope `Results` opens.
    try scope.push(value_mod.nilValue());
    const held = vm.roots.items.len - 1;
    try scope.push(colls[colls.len - 1]);
    var results = Results.init(vm);
    defer results.release();
    try mapInto(vm, args[0], colls, &results, held, held + 1);
    return results.vector();
}

fn fnFilterv(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(value_mod.nilValue());
    try scope.push(args[1]);
    var results = Results.init(vm);
    defer results.release();
    try sieveInto(vm, .keep_truthy, args[0], args[1], &results, scope.base, scope.base + 1);
    return results.vector();
}

/// `(map-indexed f coll)` → the lazy seq of `(f i x)`;
/// `(keep-indexed f coll)` the non-nil ones (docs/LAZY.md §7).
fn fnMapIndexed(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-map-indexed", args);
    return seq_mod.make(vm, seq_mod.op_map_indexed, &.{ args[0], args[1], value_mod.fromFixnum(0).? });
}

fn fnKeepIndexed(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-keep-indexed", args);
    return seq_mod.make(vm, seq_mod.op_keep_indexed, &.{ args[0], args[1], value_mod.fromFixnum(0).? });
}

/// `(distinct coll)` → the lazy seq of first occurrences, in order,
/// one at a time.
fn fnDistinct(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return transducer(vm, "xf-distinct", args);
    const seen = champ_mod.setEmpty(vm.ensureHeap()) catch return VmError.OutOfMemory;
    return seq_mod.make(vm, seq_mod.op_distinct, &.{ args[0], seen });
}

/// `(dedupe coll)` → the lazy seq of `coll` without consecutive
/// duplicates, 32 at a time.
fn fnDedupe(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return transducer(vm, "xf-dedupe", args);
    return seq_mod.make(vm, seq_mod.op_dedupe, &.{ args[0], value_mod.nilValue(), value_mod.fromBool(false) });
}

/// `(partition n coll)` / `(partition n step coll)` /
/// `(partition n step pad coll)` → the lazy seq of n-element parts; a
/// short tail is dropped unless `pad` supplies its missing elements.
/// `(partition-all n coll)` / `(partition-all n step coll)` keeps the
/// short tail (docs/LAZY.md §7).
fn partitionImpl(vm: *VM, all: bool, args: []const Value) VmError!Value {
    const n = try requireFixnum(args[0]);
    if (n <= 0) return VmError.InvalidArgument;
    const step: i64 = if (args.len >= 3) try requireFixnum(args[1]) else n;
    if (step <= 0) return VmError.InvalidArgument;
    const mode: i64 = if (all) 2 else if (args.len == 4) 1 else 0;
    return seq_mod.make(vm, seq_mod.op_partition, &.{ value_mod.fromFixnum(n).?, value_mod.fromFixnum(step).?, if (args.len == 4) args[2] else value_mod.nilValue(), args[args.len - 1], value_mod.fromFixnum(mode).? });
}

fn fnPartition(vm: *VM, args: []const Value) VmError!Value {
    return partitionImpl(vm, false, args);
}

fn fnPartitionAll(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-partition-all", args);
    return partitionImpl(vm, true, args);
}

/// `(zipmap keys vals)` → map pairing keys with vals positionally.
fn fnZipmap(vm: *VM, args: []const Value) VmError!Value {
    var entries: std.ArrayList(champ_mod.Entry) = .empty;
    defer entries.deinit(vm.allocator);
    // Either side's built entries wait on the scope while the other's
    // lazy steps may collect (GC.md §11.5, class 5).
    const scope = vm.rootScope();
    defer scope.release();
    var ks = try rootedSeqIter(vm, args[0], scope);
    var vs = try rootedSeqIter(vm, args[1], scope);
    while (try ks.next()) |k| {
        const v = (try vs.next()) orelse break;
        entries.append(vm.allocator, .{ .key = k, .value = v }) catch return VmError.OutOfMemory;
    }
    return champ_mod.mapFromEntries(vm.ensureHeap(), entries.items, &dispatch_mod.hashValue, &dispatch_mod.equal) catch VmError.OutOfMemory;
}

/// `(take-while pred coll)` / `(drop-while pred coll)` → lazy seqs
/// (docs/LAZY.md §7).
fn fnTakeWhile(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-take-while", args);
    return seq_mod.make(vm, seq_mod.op_take_while, args[0..2]);
}

fn fnDropWhile(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return transducer(vm, "xf-drop-while", args);
    return seq_mod.make(vm, seq_mod.op_drop_while, args[0..2]);
}

/// `(butlast coll)` → all but the last element, nil when fewer
/// than two. `coll` is consumed (`consumedInto`).
fn fnButlast(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    var results = try consumedInto(vm, args[0], scope);
    defer results.release();
    return results.butlastList();
}

/// `(last coll)` → the last element, nil when there is none: an O(1)
/// read of a vector or a view, a walk of anything else.
fn fnLast(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    switch (c.kind()) {
        .persistent_vector => return if (vector_mod.isEmpty(c)) value_mod.nilValue() else vector_mod.nth(c, vector_mod.count(c) - 1),
        .list => if (c.subkind() == list_mod.subkind_view) {
            const n = list_mod.count(c);
            return if (n == 0) value_mod.nilValue() else list_mod.head(list_mod.drop(c, n - 1));
        },
        else => {},
    }
    // `c` is consumed, and the last element seen waits in a root slot
    // before a step that may collect: the walk's place has left it.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(value_mod.nilValue());
    var it = try consumingSeqIter(vm, c, scope);
    var last = value_mod.nilValue();
    while (try it.nextChunk(scope.base, last)) |xs| last = xs[xs.len - 1];
    return last;
}

/// `(reverse coll)` → a list of the elements in reverse order, `()`
/// when there are none. `coll` is consumed (`consumedInto`).
fn fnReverse(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    var results = try consumedInto(vm, args[0], scope);
    defer results.release();
    return results.reversedList();
}

/// Every element of `coll`, which the caller consumes, in a `Results`
/// as the walk hands them out, so the realized seq behind the walk is
/// garbage while the result grows. `scope` takes the walk's place and
/// the slot `nextRun` may write; the caller releases the `Results`
/// before it.
fn consumedInto(vm: *VM, coll: Value, scope: vm_mod.RootScope) VmError!Results {
    try scope.push(value_mod.nilValue());
    var it = try consumingSeqIter(vm, coll, scope);
    var results = Results.init(vm);
    errdefer results.release();
    var buf: [results_chunk]Value = undefined;
    while (try nextRun(&it, &buf, scope.base)) |xs| try results.addAll(xs);
    return results;
}

/// A count argument of a sequence function (`take`, `drop`, `nthrest`,
/// `take-last`, `repeatedly`, `dorun`, ...): any number, as Clojure's
/// count one down while it is positive, so a fraction rounds up
/// (`(take 2.5 xs)` takes 3) and NaN or a count at most 0 is none; one
/// past the fixnum range, a bignum or a float, is all.
fn requireCount(v: Value) VmError!usize {
    if (v.isFixnum()) return @intCast(@max(v.asFixnum(), 0));
    if (v.isFloat()) return floatCount(@ceil(v.asFloat()));
    if (v.kind() == .bignum) return if (bignum_mod.isNegative(v)) 0 else count_max;
    return VmError.KindMismatch;
}

const count_max: usize = @intCast(value_mod.fixnum_max);

/// A whole float as a count: NaN or at most 0 is none, past the
/// fixnum range all.
fn floatCount(f: f64) usize {
    if (!(f > 0)) return 0;
    if (f >= @as(f64, @floatFromInt(count_max))) return count_max;
    return @intFromFloat(f);
}

/// `repeat`'s count, Clojure's `(long n)` of it: a float truncated, NaN
/// 0 and an infinity `:invalid-argument`; at most 0 is none, and past
/// the fixnum range all.
fn repeatCount(v: Value) VmError!usize {
    if (!v.isFloat()) return requireCount(v);
    const f = v.asFloat();
    if (std.math.isInf(f)) return VmError.InvalidArgument;
    return floatCount(@trunc(f));
}

/// `(nthrest coll n)` → coll without its first n elements, as a
/// list; O(1) past a vector's elements (a view, LIST.md §1). As
/// Clojure's, coll itself when n is not positive, or coll is nil or
/// an empty collection other than a vector.
fn fnNthrest(vm: *VM, args: []const Value) VmError!Value {
    const count = try requireCount(args[1]);
    if (count == 0 or args[0].isNil()) return args[0];
    switch (args[0].kind()) {
        .list => return list_mod.drop(args[0], count),
        .persistent_vector => {
            const v = args[0];
            return list_mod.ofVector(vm.ensureHeap(), v, @min(count, vector_mod.count(v))) catch return VmError.OutOfMemory;
        },
        // Clojure's loop: `rest` while the seq is not empty, so what
        // is left is not realized.
        .lazy_seq => {
            // An unrealized range drops arithmetically, as Clojure's
            // `IDrop` range does.
            if (seq_mod.pureOf(args[0])) |p| switch (p) {
                .range => |r| {
                    const left = seq_mod.rangeCount(r.start, r.end, r.step);
                    if (count >= left) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
                    return seq_mod.makeRange(vm, r.start + @as(i64, @intCast(count)) * r.step, r.end, r.step);
                },
                .repeat => return args[0],
                .repeat_n => |r| {
                    if (count >= r.n) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
                    return seq_mod.make(vm, seq_mod.op_repeat_n, &.{ value_mod.fromFixnum(r.n - @as(i64, @intCast(count))).?, r.x });
                },
                .range_inf, .iterate, .cycle => {},
            };
            var xs = args[0];
            for (0..count) |_| {
                if ((try seq_mod.seqOf(vm, xs)).isNil()) break;
                xs = try seq_mod.rest(vm, xs);
            }
            return xs;
        },
        else => {},
    }
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    if (items.items.len == 0) return args[0];
    return try buildListFromSlice(vm, items.items[@min(count, items.items.len)..]);
}

/// `(nthnext coll n)` → `(seq (nthrest coll n))`: the elements after
/// the first n, nil when none; a vector's is its view, so a
/// destructuring rest (`[a b & more]`) costs one block.
const fnNthnext = nthnextNative(false);

/// `nthnext` as a leaf (VM.md §6): of nil, a list or a vector; any
/// other seqable goes the general way.
const fnNthnextLeaf = nthnextNative(true);

/// `nthnext`, the leaf's or the general native. Of nil, a list or a
/// vector it is one body that returns the rest itself, so the rest is
/// stored where the caller reads it rather than copied on from
/// `nthrest` and `seq` (`docs/VM.md` §8).
fn nthnextNative(comptime leaf: bool) *const fn (*VM, []const Value) VmError!Value {
    return struct {
        fn call(vm: *VM, args: []const Value) VmError!Value {
            const coll = args[0];
            switch (coll.kind()) {
                .nil, .list, .persistent_vector => {},
                else => {
                    if (leaf) return VmError.NeedsReentry;
                    return fnSeq(vm, &.{try fnNthrest(vm, args)});
                },
            }
            const n = try requireCount(args[1]);
            switch (coll.kind()) {
                .list => {
                    const rest = list_mod.drop(coll, n);
                    if (!list_mod.isEmpty(rest)) return rest;
                },
                .persistent_vector => if (n < vector_mod.count(coll)) {
                    return list_mod.ofVector(vm.ensureHeap(), coll, n) catch return VmError.OutOfMemory;
                },
                else => {},
            }
            return value_mod.nilValue();
        }
    }.call;
}

/// `(take-last n coll)`; of nothing it is nil, as Clojure's. A lazy
/// seq is consumed: the last `n` elements the walk handed out wait in
/// root slots used as a ring, so the walk keeps no more than they.
fn fnTakeLast(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
    if (walksLazily(args[1])) {
        const scope = vm.rootScope();
        defer scope.release();
        var it = try consumingSeqIter(vm, args[1], scope);
        const ring = vm.roots.items.len;
        var seen: usize = 0;
        while (try it.next()) |x| : (seen += 1) {
            if (seen < n) try scope.push(x) else if (n > 0) vm.roots.items[ring + seen % n] = x;
        }
        const keep = @min(n, seen);
        if (keep == 0) return value_mod.nilValue();
        const items = vm.allocator.alloc(Value, keep) catch return VmError.OutOfMemory;
        defer vm.allocator.free(items);
        const oldest = if (seen > n) seen % n else 0;
        for (items, 0..) |*slot, i| slot.* = vm.roots.items[ring + (oldest + i) % keep];
        return try buildListFromSlice(vm, items);
    }
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    const keep = @min(n, items.items.len);
    if (keep == 0) return value_mod.nilValue();
    return try buildListFromSlice(vm, items.items[items.items.len - keep ..]);
}

/// `(repeat x)` → the infinite lazy seq of `x`, one cell whose rest is
/// itself; `(repeat n x)` → `n` of them, `()` for `n` at most 0
/// (docs/LAZY.md §7).
fn fnRepeat(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return seq_mod.make(vm, seq_mod.op_repeat, args[0..1]);
    const n = try repeatCount(args[0]);
    if (n == 0) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    return seq_mod.make(vm, seq_mod.op_repeat_n, &.{ value_mod.fromFixnum(@intCast(n)).?, args[1] });
}

/// `(repeatedly f)` → the infinite lazy seq of `(f)` calls, each made
/// when its element is first needed; `(repeatedly n f)` → `n` of them.
fn fnRepeatedly(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return seq_mod.make(vm, seq_mod.op_repeatedly, args[0..1]);
    const n = try requireCount(args[0]);
    return seq_mod.make(vm, seq_mod.op_repeatedly, &.{ args[1], value_mod.fromFixnum(@intCast(n)).? });
}

/// `(iterate f x)` → the infinite lazy seq `x`, `(f x)`, `(f (f x))`
/// ..., each call made when its element is first needed.
fn fnIterate(vm: *VM, args: []const Value) VmError!Value {
    return seq_mod.make(vm, seq_mod.op_iterate, args[0..2]);
}

/// `(cycle coll)` → the infinite lazy seq of `coll`'s elements over and
/// over, `()` when it has none; `coll`'s seq is taken at the call, as
/// Clojure's.
fn fnCycle(vm: *VM, args: []const Value) VmError!Value {
    const s = try seq_mod.seqOf(vm, args[0]);
    if (s.isNil()) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    // `Heap.alloc` never collects: the seq needs no root on its way in.
    return seq_mod.make(vm, seq_mod.op_cycle, &.{ s, s });
}

/// `(max-key k x & xs)` / `(min-key k x & xs)` → the x with the
/// greatest / least `(k x)`; ties go to the later argument.
fn keyExtremum(vm: *VM, want_max: bool, args: []const Value) VmError!Value {
    // One candidate is the answer without a call, as Clojure's.
    if (args.len == 2) return args[1];
    var cb = vm_mod.Callback.init(vm, args[0], 1);
    var best = args[1];
    var best_key = try cb.call1(best);
    // The best key so far is the one value kept across the next
    // call (GC.md §11.5); it goes on the root stack when it changes.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(best_key);
    for (args[2..]) |x| {
        const key = try cb.call1(x);
        const keep_best = try vm_mod.numCompare(if (want_max) .gt else .lt, best_key, key);
        if (!keep_best) {
            best = x;
            best_key = key;
            try scope.push(best_key);
        }
    }
    return best;
}

fn fnMaxKey(vm: *VM, args: []const Value) VmError!Value {
    return keyExtremum(vm, true, args);
}

fn fnMinKey(vm: *VM, args: []const Value) VmError!Value {
    return keyExtremum(vm, false, args);
}

/// `(select-keys m ks)` → map of the entries of m whose keys are
/// in ks; a vector's entries are its `[index element]` pairs, as
/// for `find`. `ks` is consumed.
fn fnSelectKeys(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var out = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const src = args[0];
    switch (src.kind()) {
        .nil, .persistent_map, .record, .persistent_vector, .sorted_map => {},
        else => return VmError.KindMismatch,
    }
    // A sorted source's comparator can collect inside `find`, and a
    // lazy key seq's next step can (GC.md §11.5, classes 4 and 5): the
    // result so far waits in a root slot, the walk keeps its place in
    // the next, and the keys it built (a map's entries) are pushed
    // after them. The key in hand is reachable from the walk's place.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(out);
    var ks = try consumingSeqIter(vm, args[1], scope);
    ks.roots = scope;
    while (try ks.next()) |k| {
        const entry = try fnFind(vm, &.{ src, k });
        if (entry.isNil()) continue;
        out = try mapPut(heap, out, k, vector_mod.nth(entry, 1));
        vm.roots.items[scope.base] = out;
    }
    return out;
}

/// `(find m k)` → the `[k v]` entry or nil; `k` is the key as the map
/// holds it, which may be another `=` value than the argument.
fn fnFind(vm: *VM, args: []const Value) VmError!Value {
    const m = args[0];
    const map_v: Value = switch (m.kind()) {
        .nil => return value_mod.nilValue(),
        .persistent_map => m,
        .record => record_mod.fieldsOf(m),
        .persistent_vector => {
            const k = args[1];
            if (k.kind() != .fixnum) return value_mod.nilValue();
            const idx = k.asFixnum();
            if (idx < 0 or @as(usize, @intCast(idx)) >= vector_mod.count(m)) return value_mod.nilValue();
            return vector_mod.fromSlice(vm.ensureHeap(), &.{ k, vector_mod.nth(m, @intCast(idx)) }) catch VmError.OutOfMemory;
        },
        .sorted_map => {
            const e = (try vm_mod.sortedFind(vm, m, args[1])) orelse return value_mod.nilValue();
            return vector_mod.fromSlice(vm.ensureHeap(), &.{ e.key, e.value }) catch VmError.OutOfMemory;
        },
        else => return VmError.KindMismatch,
    };
    const e = champ_mod.mapFind(map_v, args[1], &dispatch_mod.hashValue, &dispatch_mod.equal) orelse return value_mod.nilValue();
    return vector_mod.fromSlice(vm.ensureHeap(), &.{ e.key, e.value }) catch VmError.OutOfMemory;
}

/// `(key e)` / `(val e)` on a `[k v]` entry.
fn entryPart(idx: usize, e: Value) VmError!Value {
    if (e.kind() != .persistent_vector or vector_mod.count(e) != 2) return VmError.KindMismatch;
    return vector_mod.nth(e, idx);
}

fn fnKey(_: *VM, args: []const Value) VmError!Value {
    return entryPart(0, args[0]);
}

fn fnVal(_: *VM, args: []const Value) VmError!Value {
    return entryPart(1, args[0]);
}

/// `(peek coll)` → last of a vector, first of a list.
/// `(pop coll)` → vector without its last, list without its first.
fn fnPeek(_: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    return switch (c.kind()) {
        .nil => value_mod.nilValue(),
        .list => if (list_mod.isEmpty(c)) value_mod.nilValue() else list_mod.head(c),
        .persistent_vector => if (vector_mod.isEmpty(c)) value_mod.nilValue() else vector_mod.nth(c, vector_mod.count(c) - 1),
        else => VmError.KindMismatch,
    };
}

fn fnPop(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    return switch (c.kind()) {
        .nil => value_mod.nilValue(),
        .list => if (list_mod.isEmpty(c)) VmError.IndexOutOfBounds else list_mod.tail(c),
        .persistent_vector => if (vector_mod.count(c) == 0) VmError.IndexOutOfBounds else vector_mod.pop(vm.ensureHeap(), c) catch VmError.OutOfMemory,
        else => VmError.KindMismatch,
    };
}

/// `(empty coll)` → an empty collection of the same kind carrying
/// `coll`'s metadata; a record, being a map, gives `{}`; anything
/// that is not a collection (a string included) gives nil, as in
/// Clojure.
fn fnEmpty(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const e = switch (args[0].kind()) {
        .nil => return value_mod.nilValue(),
        .list => list_mod.empty(heap),
        .persistent_vector => vector_mod.empty(heap),
        .record => return champ_mod.mapEmpty(heap) catch VmError.OutOfMemory,
        .persistent_map => champ_mod.mapEmpty(heap),
        .persistent_set => champ_mod.setEmpty(heap),
        .sorted_map, .sorted_set => sorted_mod.empty(heap, args[0].kind(), sorted_mod.comparatorOf(args[0])),
        // A typed vector takes no updates (TYPED_VECTOR.md §8).
        .typed_vector => return VmError.KindMismatch,
        // `LazySeq.empty` is the empty list, without metadata.
        .lazy_seq => return list_mod.empty(heap) catch VmError.OutOfMemory,
        else => return value_mod.nilValue(),
    } catch return VmError.OutOfMemory;
    heap_mod.Heap.asHeapHeader(e).setMeta(heap_mod.Heap.asHeapHeader(args[0]).getMeta());
    return e;
}

/// `(not-empty coll)` → coll, or nil when it has no elements.
fn fnNotEmpty(vm: *VM, args: []const Value) VmError!Value {
    const e = try fnEmptyQ(vm, args);
    return if (e.asBool()) value_mod.nilValue() else args[0];
}

// ---- ordering ----

/// Total order used by `compare` and `sort`: Clojure's `compare`,
/// which sorted collections share (SORTED.md §6).
fn compareValues(vm: *VM, a: Value, b: Value) VmError!std.math.Order {
    return vm_mod.naturalOrder(vm, a, b);
}

fn fnCompare(vm: *VM, args: []const Value) VmError!Value {
    const o = try compareValues(vm, args[0], args[1]);
    return value_mod.fromFixnum(switch (o) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    }).?;
}

/// Ordering used by `sort` / `sort-by`: the natural order, or a
/// user comparator returning a number (negative = less) or a
/// boolean (true = less).
const SortOrder = struct {
    interner: *const intern_mod.Interner,
    comparator: ?*vm_mod.Callback,

    /// `a` and `b` are on `sortImpl`'s root scope (GC.md §11.5,
    /// class 4). Inline in each of `mergeSort`'s two instances, so
    /// the fixnum test stays in the merge loop: called, it adds half
    /// again to the million-int sort's instructions (PERF.md §3.34).
    inline fn less(self: SortOrder, a: Value, b: Value) VmError!bool {
        const cmp = self.comparator orelse {
            // Two fixnums, the common key, compare in registers. Any
            // other pair reads `sorted`'s `OrderError!Order` as it is:
            // converted to a `VmError!Order` first, as `compareValues`
            // returns it, x86-64 code rebuilds the result with two narrow
            // stores and reloads it as one wider load, which the CPU
            // cannot forward (PERF.md §3.31).
            if (a.isFixnum() and b.isFixnum()) return a.asFixnum() < b.asFixnum();
            return (try sorted_mod.naturalOrder(self.interner, a, b)) == .lt;
        };
        const r = try cmp.call2(a, b);
        return switch (r.kind()) {
            .true_ => true,
            .false_, .nil => false,
            else => ((try vm_mod.numSign(r)) orelse return false) == .lt,
        };
    }
};

/// A sortable element: `key` is what the order looks at, `val`
/// is what the result contains.
const Keyed = struct { key: Value, val: Value };

/// What the order compares of a sorted element: a `Value` itself, a
/// `Keyed`'s key.
inline fn sortKey(e: anytype) Value {
    return if (@TypeOf(e) == Value) e else e.key;
}

/// Stable merge sort whose comparator may fail (it re-enters the
/// VM for user comparators). Each merge copies its left half into
/// `scratch`, which so needs `items.len / 2` slots, and merges into
/// `items` from the front: the slot it writes is always before the
/// right half's next unread one.
fn mergeSort(comptime T: type, items: []T, scratch: []T, order: SortOrder) VmError!void {
    if (items.len < 2) return;
    const mid = items.len / 2;
    try mergeSort(T, items[0..mid], scratch, order);
    try mergeSort(T, items[mid..], scratch, order);
    const left = scratch[0..mid];
    @memcpy(left, items[0..mid]);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < items.len) : (k += 1) {
        if (try order.less(sortKey(items[j]), sortKey(left[i]))) {
            items[k] = items[j];
            j += 1;
        } else {
            items[k] = left[i];
            i += 1;
        }
    }
    // What is left of the right half is in place; the rest of the left
    // fills the gap before it.
    @memcpy(items[k..j], left[i..]);
}

/// Sort `items` in place through a scratch array of half its length.
fn sortSlice(comptime T: type, vm: *VM, items: []T, order: SortOrder) VmError!void {
    const scratch = vm.allocator.alloc(T, items.len / 2) catch return VmError.OutOfMemory;
    defer vm.allocator.free(scratch);
    try mergeSort(T, items, scratch, order);
}

/// Sort `items` in place by `keyfn`'s key for each: the keys go on
/// `scope` as they are made, since the next call may collect (GC.md
/// §11.5, class 3).
fn sortByKey(vm: *VM, keyfn: Value, items: []Value, scope: vm_mod.RootScope, order: SortOrder) VmError!void {
    const keyed = vm.allocator.alloc(Keyed, items.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(keyed);
    var cb = vm_mod.Callback.init(vm, keyfn, 1);
    for (items, keyed) |v, *k| {
        k.* = .{ .key = try cb.call1(v), .val = v };
        try scope.push(k.key);
    }
    try sortSlice(Keyed, vm, keyed, order);
    for (keyed, items) |e, *v| v.* = e.val;
}

/// The elements are sorted where they were gathered, alone when there
/// is no key function, and the result built from them (PERF.md §3.34).
fn sortImpl(vm: *VM, keyfn: ?Value, comparator_arg: ?Value, coll: Value) VmError!Value {
    // `compare` is the natural order, without a call per comparison,
    // as sorted collections take it (`comparatorArg`).
    const comparator: ?Value = if (comparator_arg) |c| (if (c.kind() == .native_fn and comparatorArg(c).isNil()) null else c) else null;
    var items = try collectSeq(vm, coll);
    defer items.deinit(vm.allocator);
    const scope = vm.rootScope();
    defer scope.release();
    // A map's entries were built by the walk and are reachable from
    // nothing else while the key function or comparator runs.
    if (keyfn != null or comparator != null) try scope.pushAll(items.items);
    var cmp_cb = if (comparator) |c| vm_mod.Callback.init(vm, c, 2) else undefined;
    const order: SortOrder = .{ .interner = vm.ensureInterner(), .comparator = if (comparator != null) &cmp_cb else null };
    if (keyfn) |kf| try sortByKey(vm, kf, items.items, scope, order) else try sortSlice(Value, vm, items.items, order);
    return try buildListFromSlice(vm, items.items);
}

/// `(sort coll)` / `(sort cmp coll)`.
fn fnSort(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return sortImpl(vm, null, null, args[0]);
    return sortImpl(vm, null, args[0], args[1]);
}

/// `(sort-by keyfn coll)` / `(sort-by keyfn cmp coll)`.
fn fnSortBy(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 2) return sortImpl(vm, args[0], null, args[1]);
    return sortImpl(vm, args[0], args[1], args[2]);
}

// ---- names, hashes and kind predicates ----

/// `(hash x)` → the runtime's semantic hash as a fixnum.
fn fnHash(_: *VM, args: []const Value) VmError!Value {
    const h = dispatch_mod.hashValue(args[0]);
    return value_mod.fromFixnum(@intCast(h & @as(u64, @intCast(value_mod.fixnum_max)))).?;
}

fn internedName(vm: *VM, v: Value) VmError![]const u8 {
    return switch (v.kind()) {
        .keyword => vm.ensureInterner().keywordName(v.asKeywordId()),
        .symbol => vm.ensureInterner().symbolName(v.asSymbolId()),
        .string => string_mod.asBytes(v),
        else => VmError.KindMismatch,
    };
}

/// `(name x)` → the name part of a keyword or symbol; a string is
/// its own name.
fn fnName(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .string) return args[0];
    const parts = intern_mod.Interner.splitQualified(try internedName(vm, args[0]));
    return string_mod.fromBytes(vm.ensureHeap(), parts.name) catch VmError.OutOfMemory;
}

/// `(namespace x)` → the namespace part of a keyword or symbol, or
/// nil when it has none.
fn fnNamespace(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .keyword and args[0].kind() != .symbol) return VmError.KindMismatch;
    const parts = intern_mod.Interner.splitQualified(try internedName(vm, args[0]));
    const ns = parts.ns orelse return value_mod.nilValue();
    return string_mod.fromBytes(vm.ensureHeap(), ns) catch VmError.OutOfMemory;
}

/// An interner refusal as the program sees it: the empty name is
/// `:invalid-argument`.
fn internFailure(err: intern_mod.InternError) VmError {
    return switch (err) {
        error.EmptyName => VmError.InvalidArgument,
        error.OutOfMemory, error.InternTableFull => VmError.OutOfMemory,
    };
}

/// `(keyword x)` / `(symbol x)` → interned from a string, keyword
/// or symbol. `(keyword ns name)` / `(symbol ns name)` → the
/// qualified name; a nil `ns` leaves it unqualified.
fn fnKeyword(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 2) {
        const ns = if (args[0].isNil()) null else try internedName(vm, args[0]);
        return vm.ensureInterner().internQualifiedKeyword(ns, try internedName(vm, args[1])) catch |err| internFailure(err);
    }
    if (args[0].kind() == .keyword or args[0].isNil()) return args[0];
    return vm.ensureInterner().internKeywordValue(try internedName(vm, args[0])) catch |err| internFailure(err);
}

fn fnSymbol(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 2) {
        const ns = if (args[0].isNil()) null else try internedName(vm, args[0]);
        return vm.ensureInterner().internQualifiedSymbol(ns, try internedName(vm, args[1])) catch |err| internFailure(err);
    }
    if (args[0].kind() == .symbol) return args[0];
    return vm.ensureInterner().internSymbolValue(try internedName(vm, args[0])) catch |err| internFailure(err);
}

// =============================================================================
// Exceptions as maps
// =============================================================================

/// `(ex-info msg data)` / `(ex-info msg data cause)` → the map
/// `{:message msg :data data}` (+ `:cause`) for `throw`; `catch`
/// takes it by `any` or by the `:error` of its data. As Clojure's,
/// `msg` is a string or nil and `data` a map, nil meaning `{}`;
/// anything else is `:kind-mismatch`. Keys are interned at the call,
/// not at boot.
fn fnExInfo(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    if (!args[0].isNil() and args[0].kind() != .string) return VmError.KindMismatch;
    if (!args[1].isNil() and !isMap(args[1].kind())) return VmError.KindMismatch;
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var fields: [3]Value = undefined;
    @memcpy(fields[0..args.len], args);
    if (args[1].isNil()) fields[1] = m;
    const names = [_][]const u8{ "message", "data", "cause" };
    for (fields[0..args.len], 0..) |v, i| {
        const key = interner.internKeywordValue(names[i]) catch return VmError.OutOfMemory;
        m = try mapPut(heap, m, key, v);
    }
    return m;
}

/// `(ex-data e)` → the `:data` of an `ex-info` map; an error map,
/// one with an `:error` entry and no `:data` (a caught runtime error,
/// a Nextomic error), is its own data; nil for anything else.
fn fnExData(vm: *VM, args: []const Value) VmError!Value {
    const data = try exEntry(vm, args[0], "data");
    if (!data.isNil() or args[0].kind() != .persistent_map) return data;
    const tag = try exEntry(vm, args[0], "error");
    return if (tag.isNil()) data else args[0];
}

/// `(ex-message e)` → the `:message` of a map (an `ex-info` map, an
/// error map), nil for anything else.
fn fnExMessage(vm: *VM, args: []const Value) VmError!Value {
    return exEntry(vm, args[0], "message");
}

fn exEntry(vm: *VM, e: Value, name: []const u8) VmError!Value {
    if (e.kind() != .persistent_map) return value_mod.nilValue();
    const key = vm.ensureInterner().internKeywordValue(name) catch return VmError.OutOfMemory;
    return try vm_mod.lookup(e, key, value_mod.nilValue());
}

// =============================================================================
// The compiler at run time (vm.CompilerHooks)
// =============================================================================

/// `(macroexpand-1 form)` → the form after one macro step; a form
/// that is not a macro call comes back as it is.
fn fnMacroexpand1(vm: *VM, args: []const Value) VmError!Value {
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    return (try hooks.expand_once(hooks.user_data, vm, args[0])) orelse args[0];
}

/// `(macroexpand form)` → `macroexpand-1` repeated until the head
/// is no longer a macro; subforms are left alone, as in Clojure.
fn fnMacroexpand(vm: *VM, args: []const Value) VmError!Value {
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    var form = args[0];
    while (try hooks.expand_once(hooks.user_data, vm, form)) |next| form = next;
    return form;
}

/// `(read-string s)`, `(read-string opts s)` → the first form of `s`
/// as data. A string that holds no form is the value of `:eof` in the
/// map `opts` when it has the key, else `:reader-error`, as is text
/// that does not read (STDLIB.md §2).
fn fnReadString(vm: *VM, args: []const Value) VmError!Value {
    const s = args[args.len - 1];
    const opts = if (args.len == 2) args[0] else value_mod.nilValue();
    if (s.kind() != .string or (args.len == 2 and opts.kind() != .persistent_map)) return VmError.KindMismatch;
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    if (try hooks.read_string(hooks.user_data, vm, string_mod.asBytes(s))) |form| return form;
    if (args.len == 2) {
        const eof = vm.ensureInterner().internKeywordValue("eof") catch return VmError.OutOfMemory;
        switch (champ_mod.mapGet(opts, eof, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
            .present => |v| return v,
            .absent => {},
        }
    }
    return vm.throwKeyword("reader-error");
}

/// `(#%load-next s i)` → `[v j]`: the first form of `s` from byte `i`
/// on, compiled as read and run (`CompilerHooks.load`), its value `v`
/// and the byte `j` its text ends at; nil when only whitespace,
/// comments and discards follow `i`. Text that does not read there, a
/// stray closing delimiter or an unfinished form included, is
/// `:reader-error`. `load-string` loads with it a form at a time.
fn fnLoadNext(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const src = string_mod.asBytes(args[0]);
    if (args[1].kind() != .fixnum) return VmError.KindMismatch;
    if (args[1].asFixnum() < 0 or args[1].asFixnum() > src.len) return VmError.IndexOutOfBounds;
    const i: usize = @intCast(args[1].asFixnum());
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    const load = hooks.load orelse return vm.throwKeyword("no-compiler");
    const loaded = (try load(hooks.user_data, vm, src[i..])) orelse return value_mod.nilValue();
    // `Heap.alloc` never collects: the value needs no root.
    return vector_mod.fromSlice(vm.ensureHeap(), &.{ loaded.value, value_mod.fromFixnum(@intCast(i + loaded.end)).? }) catch VmError.OutOfMemory;
}

/// `(eval form)` → the value of `form` compiled in the current
/// namespace and run on this VM; a form that does not compile throws
/// `{:error :compile-error :message sentence :form form :kind name}`.
fn fnEval(vm: *VM, args: []const Value) VmError!Value {
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    const eval = hooks.eval orelse return vm.throwKeyword("no-compiler");
    return try eval(hooks.user_data, vm, args[0]);
}

// =============================================================================
// Metadata (SEMANTICS.md §7)
// =============================================================================
//
// A list, vector, map, set or record carries its metadata map in the
// heap header's `meta` slot; a Var carries it in `Var.meta`. Metadata
// never takes part in equality, hashing, printing or the codec.

fn carriesHeaderMeta(k: Kind) bool {
    return switch (k) {
        .list, .lazy_seq, .persistent_vector, .persistent_map, .persistent_set, .record, .typed_vector, .sorted_map, .sorted_set => true,
        else => false,
    };
}

/// `(meta x)` → the metadata map of a list, vector, map, set, record,
/// atom or Var; nil for anything else or when none is attached. The
/// Var a native was installed in takes the native's documentation as
/// its metadata the first time it is asked for (`nativeVarMeta`).
fn fnMeta(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    if (x.kind() == .var_) {
        const v = VM.asVar(x);
        if (v.meta.isNil()) {
            v.meta = try nativeVarMeta(vm, v);
        } else if (v.meta.kind() == .persistent_map and isLibraryNs(v.ns)) {
            v.meta = try withPackedDoc(vm, v);
        }
        return v.meta;
    }
    if (!carriesHeaderMeta(x.kind()) and x.kind() != .atom) return value_mod.nilValue();
    const m = heap_mod.Heap.asHeapHeader(x).getMeta() orelse return value_mod.nilValue();
    // The metadata is a hash map or, when with-meta was given one, a
    // sorted map.
    if (m.kind == @backingInt(Kind.sorted_map)) return heap_mod.Heap.valueFromHeader(.sorted_map, m);
    return champ_mod.valueFromMapHeader(m);
}

/// `(with-meta x m)` → a value equal to `x` carrying `m` (a map or
/// nil) as its metadata. The root object is copied, so `x` keeps its
/// own; the copy shares every node below the root. A scalar (nil, a
/// boolean, char, number, string, keyword or symbol) is
/// `:no-metadata-on-immediate`; any other kind that cannot carry
/// metadata is `:kind-mismatch`, a Var included: its metadata changes
/// in place through `reset-meta!` / `alter-meta!` (SEMANTICS §7).
fn fnWithMeta(vm: *VM, args: []const Value) VmError!Value {
    const m = args[1];
    if (!m.isNil() and m.kind() != .persistent_map and m.kind() != .sorted_map) return VmError.KindMismatch;
    const x = args[0];
    if (!carriesHeaderMeta(x.kind())) return switch (x.kind()) {
        .nil, .true_, .false_, .char, .fixnum, .float, .bignum, .string, .keyword, .symbol => vm.throwKeyword("no-metadata-on-immediate"),
        else => VmError.KindMismatch,
    };
    const meta_h: ?*heap_mod.HeapHeader = if (m.isNil()) null else heap_mod.Heap.asHeapHeader(m);
    // Every rest of a vector view shares its block (LIST.md §2).
    if (x.kind() == .list and x.subkind() == list_mod.subkind_view) return list_mod.viewWithMeta(vm.ensureHeap(), x, meta_h) catch VmError.OutOfMemory;
    // A realized block over the seq, as `LazySeq.withMeta` is
    // `new LazySeq(meta, seq())`: no rest carries the metadata.
    if (x.kind() == .lazy_seq) return lazy_mod.realizedWithMeta(vm.ensureHeap(), try seq_mod.seqOf(vm, x), meta_h) catch VmError.OutOfMemory;
    const h = heap_mod.Heap.asHeapHeader(x);
    const body = heap_mod.Heap.bodyBytes(h);
    const copy = vm.ensureHeap().alloc(x.kind(), body.len) catch return VmError.OutOfMemory;
    @memcpy(heap_mod.Heap.bodyBytes(copy), body);
    copy.kind = h.kind;
    copy.flags = h.flags & ~heap_mod.flag_has_meta;
    copy.setMeta(meta_h);
    return .{ .tag = x.tag, .payload = @intFromPtr(copy) };
}

/// `(reset-meta! r m)` → sets the metadata of the Var or atom `r`
/// to `m` (a map or nil) in place and returns it.
fn fnResetMeta(vm: *VM, args: []const Value) VmError!Value {
    try setRefMeta(vm, args[0], args[1]);
    return args[1];
}

/// The metadata of a reference, the kinds whose metadata changes in
/// place (a Var, an atom), as Clojure's `IReference`.
fn setRefMeta(vm: *VM, r: Value, m: Value) VmError!void {
    if (!m.isNil() and m.kind() != .persistent_map and m.kind() != .sorted_map) return VmError.KindMismatch;
    switch (r.kind()) {
        .var_ => try setVarMeta(vm, VM.asVar(r), m),
        .atom => heap_mod.Heap.asHeapHeader(r).setMeta(if (m.isNil()) null else heap_mod.Heap.asHeapHeader(m)),
        else => return VmError.KindMismatch,
    }
}

/// Store `m` as `v`'s metadata; `:dynamic true` in it marks the
/// Var dynamic for good (`(def ^:dynamic *x* ...)`, VM.md §6.5).
fn setVarMeta(vm: *VM, v: *vm_mod.Var, m: Value) VmError!void {
    v.meta = m;
    if (m.isNil()) return;
    const key = vm.ensureInterner().internKeywordValue("dynamic") catch return VmError.OutOfMemory;
    if ((try vm_mod.lookupIn(vm, m, key, value_mod.nilValue())).isTruthy()) v.dynamic = true;
}

/// `(alter-meta! r f & args)` → sets the metadata of the Var or atom
/// `r` to `(apply f (meta r) args)` and returns it.
fn fnAlterMeta(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_ and args[0].kind() != .atom) return VmError.KindMismatch;
    const call_args = vm.allocator.alloc(Value, args.len - 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = try fnMeta(vm, args[0..1]);
    @memcpy(call_args[1..], args[2..]);
    // The metadata is the call's argument (GC.md §11.5, class 2).
    const next = try vm.callValue(args[1], call_args);
    try setRefMeta(vm, args[0], next);
    return next;
}

// =============================================================================
// Documentation (STDLIB.md §10)
// =============================================================================
//
// `doc`, `find-doc`, `apropos` and `dir` (core.nx) read a Var's
// `:doc` and `:arglists`. A native's live in its table row (`Doc`) and
// reach its Var's metadata when `meta` first asks (`nativeVarMeta`), so
// they cost the image and the boot nothing. The embedded sources'
// docstrings travel in the image packed into one string (`packDocs`)
// and go back into a Var's metadata the same way (`withPackedDoc`).
// The special forms, the host macros and the namespaces have no Var
// metadata to carry them: `special_docs` and `namespace_docs` hold
// theirs.

/// The tables whose natives have docs, each with its `Doc`s.
const documented = .{
    .{ &core_natives, &core_docs },
    .{ &db_natives, &db_docs },
    .{ &string_natives, &string_docs },
    .{ &math_natives, &math_docs },
    .{ &simd_natives, &simd_docs },
};

/// The `Doc` of the native `d`: from its table row, or from
/// `nextomic_docs` for one of Nextomic's, which keep their descriptors
/// in src/nextomic.
pub fn nativeDoc(d: *const NativeFn) ?Doc {
    inline for (documented) |t| {
        const first = @intFromPtr(&t[0][0]);
        const at = @intFromPtr(d);
        if (at >= first and at < first + t[0].len * @sizeOf(NativeFn)) {
            const doc = t[1][(at - first) / @sizeOf(NativeFn)];
            return if (doc.doc.len == 0) null else doc;
        }
    }
    return nextomic_docs.get(d.name);
}

/// The metadata of `v` when it is the Var a native was installed in
/// (not another Var holding it, `(def f first)`) and the native has a
/// `Doc`: `{:arglists (...) :doc "..." :name name :ns ns}`, as a
/// `defn`'s; nil otherwise.
fn nativeVarMeta(vm: *VM, v: *vm_mod.Var) VmError!Value {
    if (!v.bound or v.root.kind() != .native_fn) return value_mod.nilValue();
    const d = vm_mod.asNativeFn(v.root);
    const home = if (std.mem.eql(u8, v.ns, "nexis.core"))
        std.mem.eql(u8, d.name, v.name)
    else
        d.name.len == v.ns.len + 1 + v.name.len and std.mem.startsWith(u8, d.name, v.ns) and d.name[v.ns.len] == '/' and std.mem.endsWith(u8, d.name, v.name);
    if (!home) return value_mod.nilValue();
    const doc = nativeDoc(d) orelse return value_mod.nilValue();
    return docMap(vm, &.{
        .{ "arglists", try readDocForm(vm, doc.arglists) },
        .{ "doc", string_mod.fromBytes(vm.ensureHeap(), doc.doc) catch return VmError.OutOfMemory },
        .{ "name", vm.ensureInterner().internSymbolValue(v.name) catch return VmError.OutOfMemory },
        .{ "ns", vm.ensureInterner().internSymbolValue(v.ns) catch return VmError.OutOfMemory },
    });
}

/// Move the docstring of every Var the embedded sources defined out of
/// its metadata into one string, the root of `nexis.internal/#%docs`,
/// once they have booted: `ns/name`, a NUL, the docstring, a NUL, for
/// each. The image then loads one string where it would load a string
/// and a map entry per Var, and `meta` puts a Var's docstring back the
/// first time it asks (`withPackedDoc`).
fn packDocs(vm: *VM) !void {
    const gpa = vm.allocator;
    const registry = try vm.ensureRegistry();
    const heap = vm.ensureHeap();
    const doc_key = try vm.ensureInterner().internKeywordValue("doc");
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (&embedded) |*e| {
        const ns = registry.lookupNs(e.ns) orelse continue;
        var it = ns.vars.iterator();
        while (it.next()) |entry| {
            const v = entry.value_ptr.*;
            if (entry.key_ptr.*.ptr != v.name.ptr or v.meta.kind() != .persistent_map) continue;
            const doc = switch (champ_mod.mapGet(v.meta, doc_key, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
                .present => |d| d,
                .absent => continue,
            };
            if (doc.kind() != .string) continue;
            try text.print(gpa, "{s}/{s}\x00{s}\x00", .{ v.ns, v.name, string_mod.asBytes(doc) });
            v.meta = try champ_mod.mapDissoc(heap, v.meta, doc_key, &dispatch_mod.hashValue, &dispatch_mod.equal);
        }
    }
    const docs_var = try (registry.lookupNs("nexis.internal") orelse return error.MissingNamespace).intern("#%docs");
    docs_var.root = try string_mod.fromBytes(heap, text.items);
    docs_var.bound = true;
}

/// Whether `name` is one of the namespaces the embedded sources define
/// into, whose Vars' docstrings `packDocs` packs.
fn isLibraryNs(name: []const u8) bool {
    for (&embedded) |*e| if (std.mem.eql(u8, e.ns, name)) return true;
    return false;
}

/// `v`'s metadata map with the docstring `packDocs` packed for it, when
/// it has none and one was packed; the map itself otherwise.
fn withPackedDoc(vm: *VM, v: *vm_mod.Var) VmError!Value {
    const doc_key = vm.ensureInterner().internKeywordValue("doc") catch return VmError.OutOfMemory;
    if (champ_mod.mapGet(v.meta, doc_key, &dispatch_mod.hashValue, &dispatch_mod.equal) == .present) return v.meta;
    const registry = vm.ensureRegistry() catch return VmError.OutOfMemory;
    const internal = registry.lookupNs("nexis.internal") orelse return v.meta;
    const docs_var = internal.lookupLocal("#%docs") orelse return v.meta;
    if (docs_var.root.kind() != .string) return v.meta;
    const blob = string_mod.asBytes(docs_var.root);
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, blob, i, 0)) |key_end| {
        const doc_end = std.mem.findScalarPos(u8, blob, key_end + 1, 0) orelse break;
        const key = blob[i..key_end];
        if (key.len == v.ns.len + 1 + v.name.len and std.mem.startsWith(u8, key, v.ns) and key[v.ns.len] == '/' and std.mem.endsWith(u8, key, v.name)) {
            const doc = string_mod.fromBytes(vm.ensureHeap(), blob[key_end + 1 .. doc_end]) catch return VmError.OutOfMemory;
            return mapPut(vm.ensureHeap(), v.meta, doc_key, doc);
        }
        i = doc_end + 1;
    }
    return v.meta;
}

/// The form `text` reads as; the text is the binary's own, so it reads.
fn readDocForm(vm: *VM, text: []const u8) VmError!Value {
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    return (try hooks.read_string(hooks.user_data, vm, text)) orelse value_mod.nilValue();
}

/// A map of keyword keys to values. `Heap.alloc` never collects, so
/// the values need no root while it is built.
fn docMap(vm: *VM, fields: []const struct { []const u8, Value }) VmError!Value {
    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    for (fields) |f| m = try mapPut(heap, m, vm.ensureInterner().internKeywordValue(f[0]) catch return VmError.OutOfMemory, f[1]);
    return m;
}

/// A special form's or host macro's documentation: `forms`, the text
/// of its `:forms` vector for a special form or of its `:arglists`
/// list for a host macro, and `doc`.
const SpecialDoc = struct { name: []const u8, forms: []const u8, doc: []const u8, macro: bool = false };

/// `(#%special-docs)` → a vector of the doc maps of the special forms
/// and the host macros (MACROEXPAND.md §2b, §10): `{:name sym :forms
/// [...] :doc "..." :special-form true}` for a special form,
/// `{:ns nexis.core :name sym :arglists (...) :doc "..." :macro true}`
/// for a host macro, as `doc` prints them.
fn fnSpecialDocs(vm: *VM, _: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    const interner = vm.ensureInterner();
    const yes = value_mod.fromBool(true);
    for (special_docs) |s| {
        // Reading runs no code, but the maps already made stay rooted.
        const forms = try readDocForm(vm, s.forms);
        const name = interner.internSymbolValue(s.name) catch return VmError.OutOfMemory;
        const doc = string_mod.fromBytes(vm.ensureHeap(), s.doc) catch return VmError.OutOfMemory;
        try scope.push(if (s.macro) try docMap(vm, &.{
            .{ "ns", interner.internSymbolValue("nexis.core") catch return VmError.OutOfMemory },
            .{ "name", name },
            .{ "arglists", forms },
            .{ "doc", doc },
            .{ "macro", yes },
        }) else try docMap(vm, &.{
            .{ "name", name },
            .{ "forms", forms },
            .{ "doc", doc },
            .{ "special-form", yes },
        }));
    }
    return vector_mod.fromSlice(vm.ensureHeap(), vm.roots.items[scope.base..]) catch VmError.OutOfMemory;
}

/// `(#%namespace-doc sym)` → the docstring of the library namespace
/// `sym` names, nil for any other.
fn fnNamespaceDoc(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .symbol) return VmError.KindMismatch;
    const doc = namespace_docs.get(vm.ensureInterner().symbolName(args[0].asSymbolId())) orelse return value_mod.nilValue();
    return string_mod.fromBytes(vm.ensureHeap(), doc) catch VmError.OutOfMemory;
}

/// `(#%the-ns-name sym)` → the name of the namespace `sym` names in the
/// current namespace, an alias or a namespace's own name, as a symbol;
/// nil when it names none. `dir` takes either.
fn fnTheNsName(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .symbol) return VmError.KindMismatch;
    const text = vm.ensureInterner().symbolName(args[0].asSymbolId());
    const registry = vm.ensureRegistry() catch return VmError.OutOfMemory;
    const name = vm.ensureNamespace().lookupAlias(text) orelse text;
    const ns = registry.lookupNs(name) orelse return value_mod.nilValue();
    return vm.ensureInterner().internSymbolValue(ns.name) catch VmError.OutOfMemory;
}

/// The special forms (MACROEXPAND.md §2b) and the host macros (§10).
const special_docs = [_]SpecialDoc{
    .{ .name = "quote", .forms = "[(quote form)]", .doc = "Yields the unevaluated form. 'form reads as (quote form)." },
    .{ .name = "var", .forms = "[(var symbol)]", .doc = "The Var, not its value, that symbol names. #'x reads as (var x).\n  A Var is callable, and deref yields its value." },
    .{ .name = "if", .forms = "[(if test then else?)]", .doc = "Evaluates test. If it is neither nil nor false, evaluates and yields\n  then, otherwise else, nil when there is none." },
    .{ .name = "do", .forms = "[(do exprs*)]", .doc = "Evaluates the exprs in order and yields the value of the last, nil\n  when there are none." },
    .{ .name = "recur", .forms = "[(recur exprs*)]", .doc = "Rebinds the bindings of the closest enclosing loop, or the params of\n  the enclosing fn clause, to the values of the exprs and jumps back to\n  it in constant stack. Must be in tail position, with one value per\n  binding." },
    .{ .name = "throw", .forms = "[(throw expr)]", .doc = "Throws the value of expr, which may be any value: a keyword (:oops),\n  a map, an ex-info map. try's catch clauses match it by tag." },
    .{ .name = "let*", .forms = "[(let* [bindings*] exprs*)]", .doc = "The primitive under let: binds each symbol to the value of its init in\n  order, without destructuring. Programs use let." },
    .{ .name = "loop*", .forms = "[(loop* [bindings*] exprs*)]", .doc = "The primitive under loop: let* that is also a recur target. Programs\n  use loop." },
    .{ .name = "fn*", .forms = "[(fn* name? [params*] exprs*) (fn* name? ([params*] exprs*) +)]", .doc = "The primitive under fn, a clause per arity, without destructuring.\n  Programs use fn." },
    .{ .name = "letfn*", .forms = "[(letfn* [fnspecs*] exprs*)]", .doc = "The primitive under letfn: mutually recursive local functions.\n  Programs use letfn." },
    .{ .name = "def", .forms = "[(def symbol doc-string? init?)]", .doc = "Interns a Var named symbol in the current namespace and, given init,\n  sets its root to init's value. ^meta on the symbol and the doc-string\n  go into the Var's metadata with :name and :ns. Yields the Var." },
    .{ .name = "set!", .forms = "[(set! var-symbol expr)]", .doc = "Sets the binding in force of a ^:dynamic Var that binding has bound:\n  :no-thread-binding outside a binding, :not-dynamic for a Var that is\n  not dynamic. A local cannot be set!." },
    .{ .name = "try", .forms = "[(try expr* catch-clause* finally-clause?)]", .doc = "Evaluates the exprs. A value thrown from them is tried against each\n  catch clause in order; the first that matches binds name to it and\n  yields its exprs, and a value none matches is thrown on. A matcher is\n  any or :default, which match every value; a keyword :tag, which\n  matches :tag itself, a map or record whose :error is :tag, and an\n  ex-info map whose data's :error is :tag, so (catch :divide-by-zero e\n  ...) catches the runtime's error of that tag, the map {:error\n  :divide-by-zero :message m :fn f :file p :line l :column c}; or a Java\n  class name:\n  ArithmeticException, ClassCastException and the others that name a\n  nexis error match its tags, and any other (Exception, Throwable)\n  matches every value. The finally exprs run for effect however the\n  try ends." },
    .{ .name = "defmacro", .forms = "[(defmacro name doc-string? attr-map? [params*] body) (defmacro name doc-string? attr-map? ([params*] body) +)]", .doc = "Defines name as a macro: a function called at compile time with the\n  unevaluated argument forms, whose result is compiled in place of the\n  call. Spelled as defn; &form and &env are not available." },
    .{ .name = "ns", .forms = "[(ns name doc-string? attr-map? references*)]", .doc = "Makes name the current namespace, creating it with nexis.core\n  referred. A reference is (:require spec*), as require takes;\n  (:refer-clojure :exclude [names]), which makes those names the\n  namespace's own; or (:gen-class), which is accepted and does nothing.\n  The doc-string and attr-map are accepted and not kept." },
    .{ .name = "require", .forms = "[(require spec*)]", .doc = "Loads each namespace at compile time, once. A spec is ns-name or\n  [ns-name option*], quoted or not; the options are :as alias,\n  :as-alias alias, :refer [names] or :refer :all, and :rename {from to}.\n  my.app-core loads my/app_core.nx from the working directory or the\n  running file's. The library namespaces need no require to be called\n  qualified; requiring clojure.string, clojure.set, clojure.test,\n  clojure.pprint, clojure.walk, clojure.edn or clojure.math names their\n  nexis.* counterpart." },
    .{ .name = "let", .macro = true, .forms = "([bindings*] exprs*)", .doc = "binding => binding-form init-expr\n  Evaluates the exprs with each binding-form bound to its init-expr's\n  value, in order. A binding-form is a symbol, a vector pattern\n  ([a b & more :as all]) or a map pattern ({:keys [a b] :or {b 0} :as\n  m}, :strs, :syms, {x :k}); patterns nest." },
    .{ .name = "fn", .macro = true, .forms = "([name? [params*] exprs*] [name? ([params*] exprs*) +])", .doc = "A function. Params destructure as let's bindings; & rest takes the\n  remaining arguments. Several clauses make one function of several\n  arities. A first body form that is a map with :pre and :post vectors\n  holds conditions checked before and after, % the result. A named fn\n  can call itself by its name." },
    .{ .name = "defn", .macro = true, .forms = "([name doc-string? attr-map? [params*] prepost-map? body] [name doc-string? attr-map? ([params*] prepost-map? body) +])", .doc = "(def name (fn name [params*] body)) with the doc-string, the\n  attr-map and the :arglists in the Var's metadata. The function calls\n  itself through its own name, so redefining name later does not change\n  the calls an earlier function makes to itself; (#'name ...) calls\n  through the Var." },
    .{ .name = "defn-", .macro = true, .forms = "([name & decls])", .doc = "defn with :private true in the Var's metadata, which ns-publics and\n  (require '[ns :refer :all]) skip." },
    .{ .name = "loop", .macro = true, .forms = "([bindings*] exprs*)", .doc = "let whose bindings recur rebinds: (recur v ...) in tail position\n  jumps back to the top of the loop with one new value per binding, in\n  constant stack. The binding-forms destructure again on each pass." },
    .{ .name = "when", .macro = true, .forms = "([test & body])", .doc = "Evaluates test. If it is neither nil nor false, evaluates body in an\n  implicit do and yields the last value; nil otherwise." },
    .{ .name = "when-not", .macro = true, .forms = "([test & body])", .doc = "Evaluates test. If it is nil or false, evaluates body in an implicit\n  do and yields the last value; nil otherwise." },
    .{ .name = "and", .macro = true, .forms = "([] [x] [x & next])", .doc = "Evaluates the exprs one at a time, left to right. Yields the first\n  value that is nil or false without evaluating the rest, else the last\n  value; (and) is true." },
    .{ .name = "or", .macro = true, .forms = "([] [x] [x & next])", .doc = "Evaluates the exprs one at a time, left to right. Yields the first\n  value that is neither nil nor false without evaluating the rest, else\n  the last value; (or) is nil." },
    .{ .name = "cond", .macro = true, .forms = "([& clauses])", .doc = "Takes test/expr pairs and evaluates each test in turn; for the first\n  that is neither nil nor false, yields its expr's value. nil when none\n  holds; :else as the last test always holds." },
    .{ .name = "->", .macro = true, .forms = "([x & forms])", .doc = "Threads x through the forms: inserts it as the second item of the\n  first form (making a list of a form that is not one), then that\n  result into the second form, and so on." },
    .{ .name = "->>", .macro = true, .forms = "([x & forms])", .doc = "Threads x through the forms: inserts it as the last item of the first\n  form (making a list of a form that is not one), then that result into\n  the second form, and so on." },
    .{ .name = "case", .macro = true, .forms = "([expr & clauses])", .doc = "Evaluates expr and yields the result of the clause whose constant is =\n  to it: clauses are constant result-expr pairs, a list of constants\n  (k1 k2) groups alternatives, and a lone last expr is the default. The\n  constants are not evaluated. With no match and no default, throws\n  {:error :no-matching-clause :message \"No matching clause: v\" :value v}." },
    .{ .name = "condp", .macro = true, .forms = "([pred expr & clauses])", .doc = "Yields the result of the first clause for which (pred test-expr expr)\n  holds; clauses are test-expr result-expr pairs, test-expr :>> f calls\n  f on pred's result, and a lone last expr is the default. With no\n  match and no default, throws :no-matching-clause as case does." },
    .{ .name = "defrecord", .macro = true, .forms = "([name [fields*] & specs])", .doc = "Defines a record type: a map with the fields as keys that is\n  (instance? name x), with the constructors ->name and map->name, the\n  predicate name?, and the protocol methods the specs implement, each\n  (method [this args*] body) after its protocol's name, the fields in\n  scope as locals. name is bound to the record's type symbol, ns.name." },
    .{ .name = "defprotocol", .macro = true, .forms = "([name doc-string? & sigs])", .doc = "Defines a protocol: each sig, (method [this args*]+ doc-string?),\n  becomes a function that calls the implementation for its first\n  argument's type, which defrecord, extend-type and extend-protocol\n  install. :no-protocol-impl when there is none. A doc-string lands\n  on the protocol's Var; the form's value is the name." },
    .{ .name = "extend-type", .macro = true, .forms = "([type & specs])", .doc = "Implements protocols for type: a kind keyword (:string, :vector,\n  :fixnum, :any), nil, a record name, or a Clojure class name standing\n  for its kinds (String, Long, Object for any). specs are a protocol\n  name followed by its methods, (method [this args*] body)." },
    .{ .name = "extend-protocol", .macro = true, .forms = "([protocol & specs])", .doc = "Implements protocol for several types at once: each type, spelled as\n  extend-type takes it, is followed by its methods, (method [this\n  args*] body)." },
};

/// The library's namespaces (STDLIB.md §1).
const namespace_docs = std.StaticStringMap([]const u8).initComptime(.{
    .{ "nexis.core", "The core library, referred into every namespace: Clojure's clojure.core\n  without the JVM (no interop, threads, STM or agents), with durable\n  refs and the Nextomic database beside it." },
    .{ "db", "Durable refs: values kept in emdb stores and read and written in\n  transactions: open, ref, get-key, put-key!, alter!, scan, with\n  nexis.core's with-tx, with-read-tx and with-snapshot around them." },
    .{ "nextomic", "Nextomic, a Datomic-class database in the same process: datoms,\n  transact!, Datalog q, pull, entity, as-of, since, history and with.\n  Required as [nextomic :as d] by convention." },
    .{ "nexis.string", "Clojure's clojure.string, which names it: join, split, replace,\n  trim, upper-case and the rest. Strings index by code point." },
    .{ "nexis.set", "Clojure's clojure.set, which names it: union, intersection,\n  difference, select, subset?, superset?, rename-keys and map-invert." },
    .{ "nexis.walk", "Clojure's clojure.walk, which names it: walk, postwalk, prewalk,\n  keywordize-keys, stringify-keys and the replace functions." },
    .{ "nexis.edn", "Clojure's clojure.edn, which names it: read-string over the nexis\n  reader, evaluating nothing." },
    .{ "nexis.math", "Clojure's clojure.math, which names it: sqrt, pow, the trigonometric\n  and exponential functions, floor, ceil, round, PI and E." },
    .{ "nexis.test", "Clojure's clojure.test, which names it: deftest, is, are, testing,\n  fixtures and run-tests. `nexis test FILE` runs a file's tests." },
    .{ "nexis.pprint", "Clojure's clojure.pprint, which names it: pprint and pprint-str." },
    .{ "nexis.sys", "The process's environment and working directory: getenv and cwd.\n  exit and *command-line-args* are nexis.core's." },
    .{ "nexis.shell", "Clojure's clojure.java.shell: sh runs a program and returns\n  {:exit :out :err}; with-sh-dir and with-sh-env set its defaults." },
    .{ "nexis.time", "Instants, the record Instant of epoch milliseconds: now, parse and\n  format (ISO-8601), durations in milliseconds, plus, minus, between.\n  Each takes Nextomic's epoch-millisecond longs as well." },
    .{ "nexis.json", "JSON in clojure.data.json's shape: read-str, write-str, read and\n  write, with :key-fn, :value-fn and :indent." },
    .{ "nexis.simd", "Kernels over typed vectors (i64-vector, f64-vector): sum, dot,\n  scale and map." },
    .{ "nexis.internal", "The helpers macro expansions call. Not for programs." },
});

/// The docs of Nextomic's natives (NEXTOMIC.md), by descriptor name.
const nextomic_docs = std.StaticStringMap(Doc).initComptime(.{
    .{ "nextomic/as-of", nextomicDoc("[db t]", "Returns the view of db as of the transaction t, a t or a transaction\n  entity id: what the transactions up to t asserted and did not\n  retract. Of repeated bounds the older holds. A negative t is\n  :invalid-argument.") },
    .{ "nextomic/basis-t", nextomicDoc("[db]", "Returns the basis of the db-value db: the number t of the last\n  transaction it reads.") },
    .{ "nextomic/connect", nextomicDoc("[path] [path opts]", "Opens the Nextomic store at path, creating it and its parent\n  directories, and returns a connection. opts takes :durability\n  (:commit or :durable) and :sync (:full, :no-meta or :none for every\n  transaction). Release it with release, or use with-conn.") },
    .{ "nextomic/datoms", nextomicDoc("[db index] [db index c1] [db index c1 c2] [db index c1 c2 c3] [db index c1 c2 c3 tx] [db index c1 c2 c3 tx added]", "Returns a vector of the datoms [e a v t added] of db in the order of\n  index, :eavt, :aevt, :avet or :vaet, matching the components given\n  in that index's order, then tx and added; nil matches anything.\n  Another index is :invalid-argument.") },
    .{ "nextomic/db", nextomicDoc("[conn]", "Returns the db-value of conn at its current basis, a view that later\n  transactions do not change.") },
    .{ "nextomic/entid", nextomicDoc("[db x]", "Returns the eid x names in db: x itself for an eid, an ident's or a\n  lookup ref [attr v]'s entity, or nil when it names nothing.") },
    .{ "nextomic/entity", nextomicDoc("[db e]", "Returns a lazy entity of e, an eid, ident or lookup ref, in db: (:attr\n  ent), get, contains? and keys read its attributes, a card-many value\n  as a set and a ref as an entity. nil when e has no datoms in db; a\n  history db is :nextomic/history-view.") },
    .{ "nextomic/entity-db", nextomicDoc("[ent]", "Returns the db-value the entity ent reads through.") },
    .{ "nextomic/excise!", nextomicDoc("[conn e] [conn e attr]", "Removes every datom of the entity e, or of e under attr, current and\n  history, from every view, in a transaction of its own. Returns its\n  report plus :excised [e] and :removed, the count of rows removed.") },
    .{ "nextomic/explain", nextomicDoc("[query & inputs]", "Returns, as a string, the plan q would run for query and inputs: one\n  numbered line per step with its index, estimate and join (nested,\n  hash, fixpoint or none) and the rows estimated after it.") },
    .{ "nextomic/history", nextomicDoc("[db]", "Returns the history view of db: every assertion and retraction up to\n  its basis, each datom with its added flag. q and datoms read it;\n  entity and pull are :nextomic/history-view.") },
    .{ "nextomic/ident", nextomicDoc("[db x]", "Returns the ident keyword of the entity x, an eid or ident, in db, or\n  nil when it has none.") },
    .{ "nextomic/index-range", nextomicDoc("[db attr start end]", "Returns a vector of the AVET datoms of the indexed or unique attribute\n  attr whose value v has start <= v < end, in value order; a nil bound\n  is open. Another attribute is :nextomic/tx-data.") },
    .{ "nextomic/pull", nextomicDoc("[db pattern e]", "Returns the map pattern selects of the entity e in db, nil when e has\n  no datoms there: attributes, :ns/_name reverse refs, *, {attr\n  sub-pattern} and (attr :limit n :default v :as k), :db/id always.\n  A bad pattern is :nextomic/pull-syntax.") },
    .{ "nextomic/pull-many", nextomicDoc("[db pattern es]", "Returns a vector of the pull of pattern for each entity of es, a\n  vector or list, in its order, in one read.") },
    .{ "nextomic/q", nextomicDoc("[query & inputs]", "Runs the Datalog query over inputs, positional to its :in ($ when\n  absent), and returns a set of tuple vectors, or what :find asks for\n  (., [?x ...], [[...]], :keys). (q {:query query :args [inputs]}) is\n  the same call. A query refused is :nextomic/query-syntax.") },
    .{ "nextomic/release", nextomicDoc("[conn]", "Syncs conn's file when a commit left it unsynced, then closes conn;\n  returns nil, for a released conn too. Any other later use of conn is\n  :nextomic/closed; :nextomic/busy while an operation on it is in flight.") },
    .{ "nextomic/schema", nextomicDoc("[db]", "Returns a map of each attribute's ident to its definition as db's\n  basis saw it: :db/id, :db/ident, :db/valueType, :db/cardinality,\n  :db/index, :db/isComponent and :db/fulltext, with :db/unique and\n  :db/doc when the attribute has them.") },
    .{ "nextomic/since", nextomicDoc("[db t]", "Returns the view of db holding only what the transactions after t, a\n  t or a transaction entity id, asserted and did not retract: an entity\n  untouched since t is invisible. Of repeated bounds the newer holds.") },
    .{ "nextomic/sync", nextomicDoc("[conn]", "Makes every commit to conn's file durable, with one full sync when a\n  commit left it unsynced; returns nil. :db/sync-failed once a sync of\n  the file has failed, until it is reopened.") },
    .{ "nextomic/touch", nextomicDoc("[ent]", "Returns the map {:db/id e :attr v ...} of every attribute of the\n  entity ent, read in one pass: card-many values as sets, refs as eids.") },
    .{ "nextomic/transact!", nextomicDoc("[conn tx-data] [conn tx-data opts]", "Commits tx-data as one transaction and returns the report {:db-before\n  :db-after :tx :tempids :tx-data}. tx-data holds entity maps and\n  [:db/add e a v], [:db/retract e a v?], [:db/retractEntity e],\n  [:db.fn/call f & args] and [:db.fn/cas e a old new]. opts takes :sync.") },
    .{ "nextomic/tx-range", nextomicDoc("[conn] [conn from] [conn from to]", "Returns a vector of the log's entries {:t t :instant ms :data [datoms]}\n  for from <= t < to, oldest first; a nil or missing bound is open. An\n  entry an excision touched carries :excised [e ...].") },
    .{ "nextomic/with", nextomicDoc("[conn tx-data f]", "Applies tx-data without committing it: calls (f db-after report)\n  inside the held write transaction, then aborts it, and returns f's\n  value. db-after is :nextomic/closed once f returns. Unlike Datomic's,\n  it takes a connection and a function.") },
});

fn nextomicDoc(comptime arglists: []const u8, comptime doc: []const u8) Doc {
    return .{ .arglists = "(" ++ arglists ++ ")", .doc = doc };
}

// =============================================================================
// Dynamic bindings (VM.md §6.5)
// =============================================================================

/// `(push-thread-bindings {#'a 1 #'b 2})` → opens a binding frame
/// rebinding each Var to its value; `binding` pairs it with
/// `pop-thread-bindings` in a `finally`. A key that is not a Var is
/// `:kind-mismatch`; a Var that is not dynamic is `:not-dynamic`
/// and nothing is rebound.
fn fnPushThreadBindings(vm: *VM, args: []const Value) VmError!Value {
    const m = args[0];
    if (m.kind() != .persistent_map) return VmError.KindMismatch;
    const n = champ_mod.mapCount(m);
    const vars = vm.allocator.alloc(*vm_mod.Var, n) catch return VmError.OutOfMemory;
    defer vm.allocator.free(vars);
    const values = vm.allocator.alloc(Value, n) catch return VmError.OutOfMemory;
    defer vm.allocator.free(values);
    var it = champ_mod.mapIter(m);
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) {
        if (e.key.kind() != .var_) return VmError.KindMismatch;
        vars[i] = VM.asVar(e.key);
        values[i] = e.value;
    }
    try vm.pushBindings(vars, values);
    return value_mod.nilValue();
}

/// `(pop-thread-bindings)` → closes the innermost binding frame.
fn fnPopThreadBindings(vm: *VM, _: []const Value) VmError!Value {
    vm.popBindings();
    return value_mod.nilValue();
}

/// `(var-set v x)` → rebinds the innermost binding of the dynamic
/// Var `v` to `x` and returns `x`; `set!` expands to it. A Var that
/// is not dynamic is `:not-dynamic`; one with no binding in force
/// is `:no-thread-binding`.
fn fnVarSet(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    const v = VM.asVar(args[0]);
    if (!v.dynamic) return VmError.NotDynamic;
    if (!v.thread_bound) return VmError.NoThreadBinding;
    v.thread_value = args[1];
    return args[1];
}

/// `(alter-var-root v f & args)` → sets the root of the Var `v` to
/// `(apply f root args)` and returns it; a `binding` in force is left
/// as it is. An unbound Var's root is nil to `f`, and bound after.
fn fnAlterVarRoot(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    const v = VM.asVar(args[0]);
    const call_args = vm.allocator.alloc(Value, args.len - 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = v.root;
    @memcpy(call_args[1..], args[2..]);
    // The root is the call's argument (GC.md §11.5, class 2).
    const next = try vm.callValue(args[1], call_args);
    v.root = next;
    v.bound = true;
    return next;
}

/// `(#%unbind-root v)` → nil, and the Var `v` unbound, its root nil:
/// what `with-redefs` restores for a Var that had no root, as
/// Clojure's `bindRoot` of its `Unbound` value does.
fn fnUnbindRoot(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    const v = VM.asVar(args[0]);
    v.root = value_mod.nilValue();
    v.bound = false;
    return value_mod.nilValue();
}

/// `(thread-bound? & vars)` → whether a `binding` of every Var is in
/// force; true of none, as Clojure's `every?` over its arguments.
fn fnThreadBoundQ(_: *VM, args: []const Value) VmError!Value {
    for (args) |v| if (v.kind() != .var_) return VmError.KindMismatch;
    for (args) |v| if (!VM.asVar(v).thread_bound) return value_mod.fromBool(false);
    return value_mod.fromBool(true);
}

/// `(gensym)` / `(gensym prefix)` → a fresh symbol `prefixN`
/// (`G__N` by default), N counting up for the process, as Clojure's;
/// a boot from the image advances it as booting the sources does.
var gensym_next: u64 = 0;

fn fnGensym(vm: *VM, args: []const Value) VmError!Value {
    const prefix: []const u8 = if (args.len == 1) try internedName(vm, args[0]) else "G__";
    gensym_next += 1;
    const name = vm.allocator.print("{s}{d}", .{ prefix, gensym_next }) catch return VmError.OutOfMemory;
    defer vm.allocator.free(name);
    return vm.ensureInterner().internSymbolValue(name) catch |err| internFailure(err);
}

fn fnBoolean(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].isTruthy());
}

fn kindPredicate(comptime pred: fn (Kind) bool) *const fn (*VM, []const Value) VmError!Value {
    return struct {
        fn call(_: *VM, args: []const Value) VmError!Value {
            return value_mod.fromBool(pred(args[0].kind()));
        }
    }.call;
}

fn isList(k: Kind) bool {
    return k == .list;
}
fn isSeq(k: Kind) bool {
    return k == .list or k == .lazy_seq;
}
fn isVector(k: Kind) bool {
    return k == .persistent_vector;
}
/// `m` with `k` mapped to `v`, under the runtime's `hash` and `=`.
fn mapPut(heap: *heap_mod.Heap, m: Value, k: Value, v: Value) VmError!Value {
    return champ_mod.mapAssoc(heap, m, k, v, &dispatch_mod.hashValue, &dispatch_mod.equal) catch VmError.OutOfMemory;
}

/// Whether the hash map `m` has the key `k`.
fn mapHas(m: Value, k: Value) bool {
    return champ_mod.mapGet(m, k, &dispatch_mod.hashValue, &dispatch_mod.equal) == .present;
}

fn isMap(k: Kind) bool {
    return k == .persistent_map or k == .record or k == .sorted_map;
}
fn isSet(k: Kind) bool {
    return k == .persistent_set or k == .sorted_set;
}
fn isKeyword(k: Kind) bool {
    return k == .keyword;
}
fn isSymbol(k: Kind) bool {
    return k == .symbol;
}
fn isChar(k: Kind) bool {
    return k == .char;
}
fn isBoolean(k: Kind) bool {
    return k == .true_ or k == .false_;
}
fn isColl(k: Kind) bool {
    return switch (k) {
        .list, .lazy_seq, .persistent_vector, .persistent_map, .persistent_set, .record, .sorted_map, .sorted_set => true,
        else => false,
    };
}
fn isVar(k: Kind) bool {
    return k == .var_;
}
/// Clojure's `Counted`: the collections but a lazy seq, typed vectors
/// and transients.
fn isCounted(k: Kind) bool {
    return (isColl(k) and k != .lazy_seq) or k == .typed_vector or k == .transient;
}
/// Clojure's `Indexed`: the vectors, `nth` in constant time.
fn isIndexed(k: Kind) bool {
    return k == .persistent_vector or k == .typed_vector;
}
fn isSequential(k: Kind) bool {
    return k == .list or k == .persistent_vector or k == .lazy_seq;
}
fn isAssociative(k: Kind) bool {
    return k == .persistent_map or k == .persistent_vector or k == .record or k == .sorted_map;
}
fn isFn(k: Kind) bool {
    return switch (k) {
        .function, .native_fn, .protocol_fn => true,
        else => false,
    };
}
/// What `callDirect` calls: a function, a Var (its value in force,
/// as Clojure's `Var` is an `IFn`) or a lookup target.
fn isIfn(k: Kind) bool {
    return isFn(k) or k == .var_ or vm_mod.isLookupCallable(k);
}

// =============================================================================
// db primitives
// =============================================================================
//
// `(db/open path)` opens a connection; `db/close` closes it.
// `(db/ref conn tree-keyword key)` constructs a durable ref Value.
// `db/put-key!` / `db/get-key` / `db/delete-key!` / `db/present?`
// each run inside a transaction of their own; the explicit
// transaction primitives below thread one through several
// operations.
//
// Errors land as catchable keyword payloads:
//   :db/<reason>         a named emdb / db-layer failure, see
//                        `db.failureName` (:db/key-too-large,
//                        :db/max-trees, :db/corrupted, ...)
//   :db-error            any other storage failure
//   :db-closed           op on already-closed connection
//   :invalid-durable-ref arg was not a durable_ref Value
//   :unserializable      a value of a kind with no serialized form
//   :codec-failed        stored bytes that do not decode
//   :tx-closed           op on a finished transaction
//
// Storage failures are thrown through `VM.throwKeyword`, so outside
// any `try` they surface as `UncaughtThrow` with the keyword in
// `vm.unhandled_throw`, exactly like `(throw :db/key-too-large)`.
//
// Connection lifetime: each `db/open` allocates a Connection on the
// allocator of the VM that owns the registries (`VM.home`: a macro's
// sub-VM opens for the VM it compiles for, VM.md §9.1) and appends it
// to that VM's `db_connections`. `db/close`
// closes its env and leaves the struct in place; VM.deinit closes
// whatever is still open and frees every Connection.

/// Throw a db.zig / emdb / codec error to the program as its
/// keyword (`db.failureName`).
fn dbFailure(vm: *VM, err: anyerror) VmError {
    if (err == error.OutOfMemory or err == error.InternTableFull) return VmError.OutOfMemory;
    return vm.throwKeyword(db_mod.failureName(err));
}

/// The VM's I/O, or the process-wide single-threaded one for a VM
/// the host gave none (a test harness): what every native that touches
/// the file system, the clock or the random source runs on.
fn ioOf(vm: *VM) std.Io {
    return vm.io orelse std.Io.Threaded.global_single_threaded.io();
}

/// `(db/open path)` / `(db/open path {:durability d})`: the store at
/// `path`, created with its parent directories when absent (emdb
/// creates only the file). `d` is `:commit` or `:durable`; without it
/// the connection takes the process's (`NEXIS_DURABILITY`, DB.md §3.3).
fn fnDbOpen(vm: *VM, args: []const Value) VmError!Value {
    const path = try vm_mod.pathArg(args[0]);
    const durability = if (args.len > 1) try durabilityOption(vm, args[1]) else null;
    const io = ioOf(vm);
    if (std.Io.Dir.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const host = vm.home();
    const path_z = host.allocator.dupeSentinel(u8, path, 0) catch return VmError.OutOfMemory;
    defer host.allocator.free(path_z);
    const conn = host.allocator.create(db_mod.Connection) catch return VmError.OutOfMemory;
    errdefer host.allocator.destroy(conn);
    conn.* = db_mod.open(host.allocator, host.ensureHeap(), host.ensureInterner(), path_z.ptr, .{ .allocator = host.allocator }) catch |err| return dbFailure(vm, err);
    if (durability) |d| conn.durability = d;
    host.db_close_callback = &dbCloseCallback;
    host.db_connections.append(host.allocator, @ptrCast(conn)) catch {
        db_mod.shutdown(conn);
        return VmError.OutOfMemory;
    };
    return .{ .tag = @backingInt(Kind.db_connection), .payload = @intFromPtr(conn) };
}

/// The `:durability` of a `db/open` options map; null when the map is
/// nil or has none.
fn durabilityOption(vm: *VM, opts: Value) VmError!?db_mod.Durability {
    if (opts.isNil()) return null;
    if (opts.kind() != .persistent_map) return VmError.KindMismatch;
    const k = vm.ensureInterner().internKeywordValue("durability") catch return VmError.OutOfMemory;
    const found = switch (champ_mod.mapGet(opts, k, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
        .absent => return null,
        .present => |x| x,
    };
    if (found.kind() != .keyword) return VmError.InvalidArgument;
    return db_mod.Durability.parse(vm.ensureInterner().keywordName(found.asKeywordId())) orelse VmError.InvalidArgument;
}

/// Teardown of the VM: close whatever is still open and free the
/// struct. Only here is a Connection freed, so every ref, handle
/// and connection Value that names one stays valid while the VM
/// lives.
fn dbCloseCallback(opaque_ptr: *anyopaque) void {
    const conn: *db_mod.Connection = @ptrCast(@alignCast(opaque_ptr));
    db_mod.shutdown(conn);
    conn.allocator.destroy(conn);
}

/// `(db/close conn)` → nil. Aborts the connection's open
/// transactions, whose handles then report `:tx-closed`; refs of a
/// closed connection report `:db-closed`; closing twice is nil;
/// closing from a callback a native runs over one of its
/// transactions is `:db/busy` (DB.md §3).
fn fnDbClose(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(args[0].payload);
    db_mod.close(conn) catch |err| return dbFailure(vm, err);
    return value_mod.nilValue();
}

/// `(db/sync conn)` → nil: every commit to the connection's file is
/// durable, with one full sync when a commit left it unsynced.
fn fnDbSync(vm: *VM, args: []const Value) VmError!Value {
    const conn = try openConn(args[0]);
    db_mod.sync(conn) catch |err| return dbFailure(vm, err);
    return value_mod.nilValue();
}

fn fnDbRef(vm: *VM, args: []const Value) VmError!Value {
    const conn_v = args[0];
    const tree_v = args[1];
    const key_v = args[2];
    if (conn_v.kind() != .db_connection) return VmError.KindMismatch;
    // Tree name must be a keyword (its interned name = tree id).
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    // Key can be keyword / symbol (interned-name as key bytes)
    // or string.
    if (key_v.kind() != .keyword and key_v.kind() != .symbol and key_v.kind() != .string) {
        return VmError.KindMismatch;
    }
    const conn: *db_mod.Connection = @ptrFromInt(conn_v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    const interner = vm.ensureInterner();
    const tree_id: u32 = tree_v.asKeywordId();
    const tree_name = interner.keywordName(tree_id);
    const key_bytes: []const u8 = switch (key_v.kind()) {
        .keyword => interner.keywordName(key_v.asKeywordId()),
        .symbol => interner.symbolName(key_v.asSymbolId()),
        .string => string_mod.asBytes(key_v),
        else => unreachable,
    };
    return db_mod.ref(vm.ensureHeap(), conn, tree_name, key_bytes) catch |err| return dbFailure(vm, err);
}

fn fnDbRefQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .durable_ref);
}

/// The open connection a durable ref belongs to.
fn liveConnOf(vm: *VM, r: Value) VmError!*db_mod.Connection {
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const conn = db_mod.refConn(r) orelse return vm.throwKeyword("db/no-connection");
    if (!conn.open_flag) return VmError.DbClosed;
    return conn;
}

/// `(db/put-key! ref value)` — one write transaction around one put.
fn fnDbPutKey(vm: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const v = args[1];
    const conn = try liveConnOf(vm, r);
    var txn = try beginWrite(vm, conn);
    db_mod.putRef(&txn, r, v) catch |err| {
        db_mod.abortWrite(&txn);
        if (err != error.Unrealized) return dbFailure(vm, err);
        // Realized outside the transaction, which is begun again.
        try seq_mod.realizeAll(vm, v);
        return fnDbPutKey(vm, args);
    };
    db_mod.commit(&txn) catch |err| return dbFailure(vm, err);
    return value_mod.nilValue();
}

/// `(db/get-key ref)` or `(db/get-key ref default)` — one read
/// transaction around one get.
fn fnDbGetKey(vm: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const default = if (args.len > 1) args[1] else value_mod.nilValue();
    const conn = try liveConnOf(vm, r);
    var txn = try beginRead(vm, conn);
    defer db_mod.abortRead(&txn);
    const result = db_mod.getRef(&txn, r, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return dbFailure(vm, err);
    return result orelse default;
}

fn fnDbDeleteKey(vm: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const conn = try liveConnOf(vm, r);
    var txn = try beginWrite(vm, conn);
    const existed = db_mod.delRef(&txn, r) catch |err| {
        db_mod.abortWrite(&txn);
        return dbFailure(vm, err);
    };
    db_mod.commit(&txn) catch |err| return dbFailure(vm, err);
    return value_mod.fromBool(existed);
}

fn fnDbPresentQ(vm: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const conn = try liveConnOf(vm, r);
    var txn = try beginRead(vm, conn);
    defer db_mod.abortRead(&txn);
    return value_mod.fromBool(db_mod.has(&txn, db_mod.refTreeName(r), db_mod.refKeyBytes(r)) catch |err| return dbFailure(vm, err));
}

// =============================================================================
// db explicit-transaction primitives
// =============================================================================
//
// Transactions are threaded explicitly. The `with-tx` /
// `with-read-tx` macros (in core.nx) generate
// `(let [tx (db/begin-write conn)] (try ...body... (catch any e (db/abort-write! tx) (throw e))))`
// with commit at the end of the body.
//
// A handle (`db.Handle`) is open until commit or abort, the close
// of its connection, or a collection that finds it unreachable;
// afterwards every operation on it but abort is `:tx-closed`.
//
// Held transactions: a native that calls back into the program
// while it uses a transaction (`db/alter!`, `db/reduce-tree`) holds
// the handle for the call, and commit or abort of a held handle is
// `:db/busy`, so no callback finishes a transaction under the native
// using it (DB.md §12).
//
// Connection mismatch: `db/put!` etc. validate that the supplied
// ref belongs to the same connection the tx is open against.
// db.zig's putRef/getRef/delRef do this via `assertRefMatchesConn`.

fn writeTxnHandle(v: Value) ?*db_mod.Handle {
    if (v.kind() != .db_write_txn) return null;
    return db_mod.handleOf(v);
}

fn readTxnHandle(v: Value) ?*db_mod.Handle {
    if (v.kind() != .db_read_txn) return null;
    return db_mod.handleOf(v);
}

/// The open handle of a transaction Value of either kind.
fn activeTxn(v: Value) VmError!*db_mod.Handle {
    if (v.kind() != .db_write_txn and v.kind() != .db_read_txn) return VmError.KindMismatch;
    const h = db_mod.handleOf(v);
    if (!h.active) return VmError.TxClosed;
    return h;
}

/// The open write transaction of `v`.
fn activeWrite(v: Value) VmError!*db_mod.WriteTxn {
    const h = writeTxnHandle(v) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    return &h.txn.write;
}

/// A write transaction on `conn`. When the file's writer or every
/// reader slot is taken and a handle this VM could collect holds a
/// transaction on the file, one collection ends the handles the
/// program dropped and the transaction is begun again (DB.md §12).
/// The natives that begin transactions hold no heap value but their
/// rooted arguments, so the cycle may run inside them (GC.md §7).
fn beginWrite(vm: *VM, conn: *db_mod.Connection) VmError!db_mod.WriteTxn {
    return db_mod.beginWrite(conn) catch |err| {
        try collectForTxn(vm, conn, err);
        return db_mod.beginWrite(conn) catch |again| dbFailure(vm, again);
    };
}

/// A read transaction on `conn`, as `beginWrite`.
fn beginRead(vm: *VM, conn: *db_mod.Connection) VmError!db_mod.ReadTxn {
    return db_mod.beginRead(conn) catch |err| {
        try collectForTxn(vm, conn, err);
        return db_mod.beginRead(conn) catch |again| dbFailure(vm, again);
    };
}

fn collectForTxn(vm: *VM, conn: *db_mod.Connection, err: anyerror) VmError!void {
    if (err != error.WriterActive and err != error.ReaderTableFull) return dbFailure(vm, err);
    if (!vm.gc_enabled or vm.borrowed_heap != null or !db_mod.collectableHandles(conn)) return dbFailure(vm, err);
    vm.collectGarbage();
}

/// The open connection a `db/begin-*` native names.
fn openConn(v: Value) VmError!*db_mod.Connection {
    if (v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    return conn;
}

fn fnDbBeginWrite(vm: *VM, args: []const Value) VmError!Value {
    const txn = try beginWrite(vm, try openConn(args[0]));
    const h = db_mod.Handle.create(.{ .write = txn }) catch return VmError.OutOfMemory;
    return .{ .tag = @backingInt(Kind.db_write_txn), .payload = @intFromPtr(h) };
}

fn fnDbBeginRead(vm: *VM, args: []const Value) VmError!Value {
    const txn = try beginRead(vm, try openConn(args[0]));
    const h = db_mod.Handle.create(.{ .read = txn }) catch return VmError.OutOfMemory;
    return .{ .tag = @backingInt(Kind.db_read_txn), .payload = @intFromPtr(h) };
}

fn fnDbCommit(vm: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    if (h.held != 0) return vm.throwKeyword("db/busy");
    h.active = false;
    db_mod.commit(&h.txn.write) catch |err| return dbFailure(vm, err);
    return value_mod.nilValue();
}

/// `(db/abort-write! tx)` and `(db/abort-read! tx)`: nil, and nil
/// again for a finished transaction.
fn abortHandle(vm: *VM, h: *db_mod.Handle) VmError!Value {
    if (!h.active) return value_mod.nilValue();
    if (h.held != 0) return vm.throwKeyword("db/busy");
    h.end();
    return value_mod.nilValue();
}

fn fnDbAbortWrite(vm: *VM, args: []const Value) VmError!Value {
    return abortHandle(vm, writeTxnHandle(args[0]) orelse return VmError.KindMismatch);
}

fn fnDbAbortRead(vm: *VM, args: []const Value) VmError!Value {
    return abortHandle(vm, readTxnHandle(args[0]) orelse return VmError.KindMismatch);
}

/// `(db/put! tx ref value)` — write through an active tx.
fn fnDbPut(vm: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    const r = args[1];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    try putRealizing(vm, h, r, args[2]);
    return value_mod.nilValue();
}

/// `db.putRef`, realizing `v` and encoding it again when the codec
/// finds a lazy seq in it that has not run (docs/LAZY.md §8). The
/// realization runs program code with the transaction held, so a
/// body that commits, aborts or closes it is `:db/busy` (DB.md §12).
fn putRealizing(vm: *VM, h: *db_mod.Handle, r: Value, v: Value) VmError!void {
    db_mod.putRef(&h.txn.write, r, v) catch |err| {
        if (err != error.Unrealized) return dbFailure(vm, err);
        h.held += 1;
        defer h.held -= 1;
        try seq_mod.realizeAll(vm, v);
        // Nothing ends a held handle: not commit or abort, not a close
        // of its connection, not a collection.
        std.debug.assert(h.active);
        db_mod.putRef(&h.txn.write, r, v) catch |again| return dbFailure(vm, again);
    };
}

/// `(db/get tx ref)` or `(db/get tx ref default)` — read through
/// either a write or read tx. Returns `default` (nil if omitted)
/// for missing keys.
fn fnDbGet(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const r = args[1];
    const default = if (args.len > 2) args[2] else value_mod.nilValue();
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const result: ?Value = switch ((try activeTxn(tx_v)).txn) {
        inline else => |*t| db_mod.getRef(t, r, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return dbFailure(vm, err),
    };
    return result orelse default;
}

fn fnDbDelete(vm: *VM, args: []const Value) VmError!Value {
    const txn = try activeWrite(args[0]);
    const r = args[1];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const existed = db_mod.delRef(txn, r) catch |err| return dbFailure(vm, err);
    return value_mod.fromBool(existed);
}

/// `(deref x)` (also installed as `db/deref`) — universal deref:
///   durable_ref → ephemeral read tx, return decoded value (nil
///                 if absent)
///   var         → Var.root (raises :unbound-var if unbound)
///   atom        → current contained value (deref does NOT
///                 touch in_flight and is allowed inside a swap!
///                 critical section)
///   other       → :not-derefable (catchable)
fn fnDbDeref(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    return switch (x.kind()) {
        .durable_ref => blk: {
            const conn = try liveConnOf(vm, x);
            var txn = try beginRead(vm, conn);
            defer db_mod.abortRead(&txn);
            const result = db_mod.getRef(&txn, x, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return dbFailure(vm, err);
            break :blk result orelse value_mod.nilValue();
        },
        .var_ => vm_mod.VM.asVar(x).current() orelse VmError.UnboundVar,
        .atom => atom_mod.getValue(x),
        .record => if (isReduced(vm, x)) reducedValue(x) else if (isDelay(vm, x)) forceDelay(vm, x) else VmError.NotDerefable,
        else => VmError.NotDerefable,
    };
}

// =============================================================================
// Introspection (STDLIB.md §8)
// =============================================================================
//
// A type is the keyword `extend-type` names a kind with (`:vector`,
// `:fixnum`, `:string`, ...; `:boolean` for both booleans) or, for a
// record, the symbol it prints with (`user.P`). A namespace is its
// name symbol: the registry holds namespaces, not values.

/// `(class x)` → the type of `x` (nil for nil, as Clojure's).
fn fnClass(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    const interner = vm.ensureInterner();
    const name: []const u8 = switch (x.kind()) {
        .nil => return value_mod.nilValue(),
        .true_, .false_ => "boolean",
        .persistent_vector => "vector",
        .persistent_map => "map",
        .persistent_set => "set",
        .record => {
            const e = vm.recordType(record_mod.typeId(x)) orelse return VmError.InvalidArgument;
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(vm.allocator);
            if (e.ns_name.len > 0) buf.print(vm.allocator, "{s}.", .{e.ns_name}) catch return VmError.OutOfMemory;
            buf.appendSlice(vm.allocator, e.type_name) catch return VmError.OutOfMemory;
            return interner.internSymbolValue(buf.items) catch VmError.OutOfMemory;
        },
        else => |k| @tagName(k),
    };
    return interner.internKeywordValue(name) catch VmError.OutOfMemory;
}

/// `(#%mm-lookup cache href dv)` → the method a multimethod's cache
/// holds for `dv` (core.nx `mm-call`, STDLIB.md §9.3): `cache` is the
/// atom of the pair `[hierarchy methods]`, `href` the Var or atom the
/// hierarchy is read through, and the answer `(get methods dv)` while
/// the hierarchy is still the identical value, else nil. One call for
/// the two derefs, the identity check and the lookup of the fast path.
fn fnMmLookup(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .atom) return VmError.KindMismatch;
    const h = switch (args[1].kind()) {
        .var_ => vm_mod.VM.asVar(args[1]).current() orelse return VmError.UnboundVar,
        .atom => atom_mod.getValue(args[1]),
        else => return VmError.KindMismatch,
    };
    const pair = atom_mod.getValue(args[0]);
    const cached = try fnNth(vm, &.{ pair, value_mod.fromFixnum(0).? });
    if (cached.tag != h.tag or cached.payload != h.payload) return value_mod.nilValue();
    return fnGet(vm, &.{ try fnNth(vm, &.{ pair, value_mod.fromFixnum(1).? }), args[2] });
}

/// `#%mm-lookup` as a leaf: it refuses a dispatch value on the heap,
/// whose hash and `=` may walk nested data, as `fnGetLeaf` does.
fn fnMmLookupLeaf(vm: *VM, args: []const Value) VmError!Value {
    if (args[2].kind().isHeap()) return VmError.NeedsReentry;
    return fnMmLookup(vm, args);
}

/// `(class? x)` → whether `x` is a type `class` returns, which the
/// global hierarchy takes as a tag (STDLIB.md §9.1): the keyword of a
/// kind (`:boolean`, `:vector`, `:map`, `:set` or a `Kind` name that
/// `fnClass` passes through), or the symbol of a registered record type.
fn fnClassQ(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    const interner = vm.ensureInterner();
    return value_mod.fromBool(switch (x.kind()) {
        .keyword => isClassKeyword(interner.keywordName(x.asKeywordId())),
        .symbol => blk: {
            const name = interner.symbolName(x.asSymbolId());
            for (vm.home().record_registry.items) |e| {
                const dotted = e.ns_name.len > 0;
                if (name.len != e.ns_name.len + @intFromBool(dotted) + e.type_name.len) continue;
                if (dotted and !(std.mem.startsWith(u8, name, e.ns_name) and name[e.ns_name.len] == '.')) continue;
                if (std.mem.endsWith(u8, name, e.type_name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    });
}

fn isClassKeyword(name: []const u8) bool {
    for ([_][]const u8{ "boolean", "vector", "map", "set" }) |alias| if (std.mem.eql(u8, name, alias)) return true;
    const k = std.meta.stringToEnum(Kind, name) orelse return false;
    return switch (k) {
        // nil has no class, `fnClass` renames these, and the rest are
        // reserved or never escape.
        .nil, .true_, .false_, .persistent_vector, .persistent_map, .persistent_set, .record, .byte_vector, .error_, .meta_symbol, .cell_internal => false,
        else => true,
    };
}

fn nsOfSymbol(vm: *VM, v: Value) VmError!?*Namespace {
    if (v.kind() != .symbol) return VmError.KindMismatch;
    const registry = vm.ensureRegistry() catch return VmError.OutOfMemory;
    return registry.lookupNs(vm.ensureInterner().symbolName(v.asSymbolId()));
}

/// The namespace a symbol names, else `:no-such-namespace`, as
/// `the-ns` has it.
fn theNs(vm: *VM, v: Value) VmError!*Namespace {
    return (try nsOfSymbol(vm, v)) orelse vm.throwKeyword("no-such-namespace");
}

/// `(find-ns sym)` → `sym` when a namespace has that name, else nil.
fn fnFindNs(vm: *VM, args: []const Value) VmError!Value {
    return if (try nsOfSymbol(vm, args[0])) |_| args[0] else value_mod.nilValue();
}

/// `(all-ns)` → the name of every namespace, sorted.
fn fnAllNs(vm: *VM, _: []const Value) VmError!Value {
    const registry = vm.ensureRegistry() catch return VmError.OutOfMemory;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(vm.allocator);
    var it = registry.map.keyIterator();
    while (it.next()) |k| names.append(vm.allocator, k.*) catch return VmError.OutOfMemory;
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var syms: std.ArrayList(Value) = .empty;
    defer syms.deinit(vm.allocator);
    for (names.items) |n| syms.append(vm.allocator, vm.ensureInterner().internSymbolValue(n) catch return VmError.OutOfMemory) catch return VmError.OutOfMemory;
    return buildListFromSlice(vm, syms.items);
}

/// The map of name symbol → Var of every Var interned in the
/// namespace `args[0]` names, not those it refers to from another
/// (a referral is keyed with a copy of the name, MACROEXPAND.md §2b);
/// only the ones not marked `:private` when `publics`.
fn nsVars(vm: *VM, ns_sym: Value, publics: bool) VmError!Value {
    const ns = try theNs(vm, ns_sym);
    const interner = vm.ensureInterner();
    const heap = vm.ensureHeap();
    const private_key = interner.internKeywordValue("private") catch return VmError.OutOfMemory;
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var it = ns.vars.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        if (entry.key_ptr.*.ptr != v.name.ptr) continue;
        if (publics and v.meta.kind() == .persistent_map) switch (champ_mod.mapGet(v.meta, private_key, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
            .present => |flag| if (flag.isTruthy()) continue,
            .absent => {},
        };
        const sym = interner.internSymbolValue(v.name) catch return VmError.OutOfMemory;
        m = try mapPut(heap, m, sym, VM.varToValue(v));
    }
    return m;
}

fn fnNsInterns(vm: *VM, args: []const Value) VmError!Value {
    return nsVars(vm, args[0], false);
}

fn fnNsPublics(vm: *VM, args: []const Value) VmError!Value {
    return nsVars(vm, args[0], true);
}

/// The Var `sym` names in `ns`, as the compiler resolves a global:
/// unqualified, the namespace's own or referred name, then
/// `nexis.core`'s; qualified, the Var of that name in the namespace
/// the prefix (an alias of `ns`, or a namespace name) names. nil when
/// there is none, a host macro's name included.
fn resolveIn(vm: *VM, ns: *Namespace, sym: Value) VmError!Value {
    if (sym.kind() != .symbol) return VmError.KindMismatch;
    const text = vm.ensureInterner().symbolName(sym.asSymbolId());
    const slash = if (text.len > 1) std.mem.findScalar(u8, text, '/') else null;
    const v = if (slash) |i| blk: {
        const prefix = text[0..i];
        const registry = ns.registry orelse break :blk null;
        const target = registry.lookupNs(ns.lookupAlias(prefix) orelse prefix) orelse break :blk null;
        break :blk target.lookupLocal(text[i + 1 ..]);
    } else ns.lookup(text);
    return if (v) |found| VM.varToValue(found) else value_mod.nilValue();
}

/// `(resolve sym)` → the Var `sym` names in the current namespace.
fn fnResolve(vm: *VM, args: []const Value) VmError!Value {
    return resolveIn(vm, vm.ensureNamespace(), args[0]);
}

/// `(ns-resolve ns sym)` → the Var `sym` names in `ns`.
fn fnNsResolve(vm: *VM, args: []const Value) VmError!Value {
    return resolveIn(vm, try theNs(vm, args[0]), args[1]);
}

/// `(random-uuid)` → a random (version 4) UUID, as its canonical
/// lowercase text: a UUID is a string, as Nextomic's `:db.type/uuid`
/// values are.
fn fnRandomUuid(vm: *VM, _: []const Value) VmError!Value {
    var u: [16]u8 = undefined;
    random(vm).bytes(&u);
    u[6] = (u[6] & 0x0F) | 0x40;
    u[8] = (u[8] & 0x3F) | 0x80;
    var text: [36]u8 = undefined;
    nextomic_mod.datom.uuidToText(&text, u);
    return string_mod.fromBytes(vm.ensureHeap(), &text) catch VmError.OutOfMemory;
}

/// `(parse-uuid s)` → the canonical lowercase text of the UUID `s`
/// spells in 8-4-4-4-12 hex digits of either case, else nil.
fn fnParseUuid(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const u = nextomic_mod.datom.uuidFromText(string_mod.asBytes(args[0])) orelse return value_mod.nilValue();
    var text: [36]u8 = undefined;
    nextomic_mod.datom.uuidToText(&text, u);
    return string_mod.fromBytes(vm.ensureHeap(), &text) catch VmError.OutOfMemory;
}

// =============================================================================
// Delays
// =============================================================================
//
// A delay is the record `nexis.core/Delay` whose `:state` is an atom
// holding `[:pending thunk]`, `[:ready value]` or `[:failed thrown]`.
// `force` (core.nx) runs the thunk once and caches its value or its
// throw, which only nexis code can catch; `deref` of a delay calls it.

/// The type id of `nexis.core/Delay`, registered on first use.
fn delayType(vm: *VM) VmError!u32 {
    for (vm.home().record_registry.items) |e| {
        if (std.mem.eql(u8, e.ns_name, "nexis.core") and std.mem.eql(u8, e.type_name, "Delay")) return e.id;
    }
    return vm.registerRecordType("nexis.core", "Delay", &.{"state"}) catch VmError.OutOfMemory;
}

fn isDelay(vm: *VM, v: Value) bool {
    if (v.kind() != .record) return false;
    const e = vm.recordType(record_mod.typeId(v)) orelse return false;
    return std.mem.eql(u8, e.ns_name, "nexis.core") and std.mem.eql(u8, e.type_name, "Delay");
}

/// `(#%delay thunk)` → a pending delay of `thunk` (the `delay` macro).
fn fnDelay(vm: *VM, args: []const Value) VmError!Value {
    const type_id = try delayType(vm);
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    const pending = interner.internKeywordValue("pending") catch return VmError.OutOfMemory;
    const key = interner.internKeywordValue("state") catch return VmError.OutOfMemory;
    // `Heap.alloc` never collects (GC.md §11.5): the pieces need no
    // roots on their way into the record.
    const thunk = vector_mod.fromSlice(heap, &.{ pending, args[0] }) catch return VmError.OutOfMemory;
    const state = atom_mod.make(heap, thunk) catch return VmError.OutOfMemory;
    const empty = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const fields = try mapPut(heap, empty, key, state);
    return record_mod.make(heap, type_id, fields) catch VmError.OutOfMemory;
}

fn fnDelayQ(vm: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(isDelay(vm, args[0]));
}

/// `(realized? x)` → whether a lazy block's body has run (a cons or a
/// chunked cons is realized), or whether a delay has been forced;
/// `:kind-mismatch` for anything else.
fn fnRealizedQ(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    if (x.kind() == .lazy_seq) {
        return value_mod.fromBool(lazy_mod.shapeOf(x) != .lazy or lazy_mod.state(x) == .realized);
    }
    if (!isDelay(vm, x)) return VmError.KindMismatch;
    const key = vm.ensureInterner().internKeywordValue("state") catch return VmError.OutOfMemory;
    const state = atom_mod.getValue(try vm_mod.lookup(x, key, value_mod.nilValue()));
    const pending = vm.ensureInterner().internKeywordValue("pending") catch return VmError.OutOfMemory;
    return value_mod.fromBool(!vector_mod.nth(state, 0).identicalTo(pending));
}

/// `(doall coll)` / `(doall n coll)` → coll, its first n elements (all
/// of them) realized; `(dorun ...)` the same walk, returning nil.
fn fnDoall(vm: *VM, args: []const Value) VmError!Value {
    try realizeArg(vm, args);
    return args[args.len - 1];
}

/// `(dorun coll)` / `(dorun n coll)`: realize, keeping nothing. `coll`
/// is consumed: the walk's place, or the seq `next` has reached, is
/// its root.
fn fnDorun(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    const coll = args[args.len - 1];
    if (args.len == 1) {
        try scope.push(coll);
        var it = try SeqIter.realizing(vm, coll);
        it.cursor = scope.base;
        while (try it.next()) |_| {}
        return value_mod.nilValue();
    }
    const n = try requireCount(args[0]);
    try scope.push(coll);
    var xs = coll;
    for (0..n) |_| {
        const s = try seq_mod.seqOf(vm, xs);
        if (s.isNil()) break;
        vm.roots.items[scope.base] = s;
        xs = try seq_mod.next(vm, s);
        vm.roots.items[scope.base] = xs;
    }
    return value_mod.nilValue();
}

fn realizeArg(vm: *VM, args: []const Value) VmError!void {
    const limit: ?usize = if (args.len == 2) try requireCount(args[0]) else null;
    try seq_mod.realizeSpine(vm, args[args.len - 1], limit);
}

// The chunk functions, for library code written against Clojure's
// (docs/LAZY.md §7): a chunk is a vector here, and a chunk buffer a
// transient vector; `chunk-cons` copies the vector into a chunk block.

/// `(chunked-seq? s)` → whether `s` is a seq that hands out chunks: a
/// chunked cons or a vector's view.
fn fnChunkedSeqQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(seq_mod.chunkOf(args[0]) != null);
}

fn chunkArg(s: Value) VmError!seq_mod.Chunk {
    return seq_mod.chunkOf(s) orelse VmError.KindMismatch;
}

/// `(chunk-first s)` → the elements of `s`'s first chunk, a vector.
fn fnChunkFirst(vm: *VM, args: []const Value) VmError!Value {
    return vector_mod.fromSlice(vm.ensureHeap(), (try chunkArg(args[0])).items) catch VmError.OutOfMemory;
}

/// `(chunk-rest s)` → what follows the first chunk, `()` when nothing.
fn fnChunkRest(vm: *VM, args: []const Value) VmError!Value {
    const after = (try chunkArg(args[0])).after;
    if (after.isNil()) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    return after;
}

/// `(chunk-next s)` → the seq after the first chunk, nil when nothing.
fn fnChunkNext(vm: *VM, args: []const Value) VmError!Value {
    return seq_mod.seqOf(vm, (try chunkArg(args[0])).after);
}

/// `(chunk-buffer n)` → an empty transient vector to append to.
fn fnChunkBuffer(vm: *VM, args: []const Value) VmError!Value {
    _ = try requireFixnum(args[0]);
    return fnTransient(vm, &.{vector_mod.empty(vm.ensureHeap()) catch return VmError.OutOfMemory});
}

/// `(chunk-append b x)` → `(conj! b x)`.
fn fnChunkAppend(vm: *VM, args: []const Value) VmError!Value {
    return fnConjBang(vm, args);
}

/// `(chunk b)` → the buffer's elements, a vector.
fn fnChunk(vm: *VM, args: []const Value) VmError!Value {
    return fnPersistentBang(vm, args);
}

/// `(chunk-cons c rest)` → the elements of `c` (a vector) in front of
/// `rest`, or `rest` itself when `c` is empty, as Clojure's.
fn fnChunkCons(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    if (c.kind() != .persistent_vector) return VmError.KindMismatch;
    const n = vector_mod.count(c);
    if (n == 0) return args[1];
    const more = if (lazy_mod.isMore(args[1])) args[1] else try seq_mod.seqOf(vm, args[1]);
    // `Heap.alloc` never collects: the chunk needs no root on its way in.
    const chunked = lazy_mod.allocChunked(vm.ensureHeap(), n) catch return VmError.OutOfMemory;
    var it = vector_mod.Cursor.init(c);
    for (lazy_mod.chunkItems(chunked)) |*slot| slot.* = it.next().?;
    lazy_mod.finishChunked(chunked, n, more);
    return chunked;
}

/// The transducer arity of a sequence native: the `xf-` function of its
/// name in core.nx, called with the arguments (docs/LAZY.md §10).
fn transducer(vm: *VM, comptime name: []const u8, args: []const Value) VmError!Value {
    return callCore(vm, name, args);
}

/// The function `name` of nexis.core, private ones included, called
/// with `args`, the native's own arguments (GC.md §11.5, class 2).
fn callCore(vm: *VM, name: []const u8, args: []const Value) VmError!Value {
    const registry = if (vm.home().registry) |*r| r else return VmError.UnboundVar;
    const v = registry.core.lookupLocal(name) orelse return VmError.UnboundVar;
    return vm.callValue(v.current() orelse return VmError.UnboundVar, args);
}

/// `(#%sequence xform coll)` / `(#%sequence xform tuples true)` → the
/// lazy seq of `coll` through the transducer, 32 outputs at a time
/// (docs/LAZY.md §10); the second form calls the reducing function with
/// each tuple's elements.
fn fnSequenceXform(vm: *VM, args: []const Value) VmError!Value {
    const conj_bang = comptime for (&core_natives, 0..) |*d, i| {
        if (std.mem.eql(u8, d.name, "conj!")) break i;
    } else @compileError("no conj! native");
    const rf = try vm.callValue(args[0], &.{vm_mod.nativeFnValue(&core_natives[conj_bang])});
    // `Heap.alloc` never collects: `rf` needs no root on its way in.
    return seq_mod.make(vm, seq_mod.op_sequence, &.{ rf, args[1], value_mod.fromBool(false), value_mod.fromBool(args.len == 3 and args[2].isTruthy()) });
}

/// `(#%lazy-seq f)` → an unrealized lazy block whose body calls `f`
/// (the `lazy-seq` macro, LAZY.md §4).
fn fnLazySeq(vm: *VM, args: []const Value) VmError!Value {
    return seq_mod.make(vm, seq_mod.op_thunk, args[0..1]);
}

/// `(#%force s)` → the seq of `s`, any seqable.
fn fnForce(vm: *VM, args: []const Value) VmError!Value {
    return seq_mod.seqOf(vm, args[0]);
}

/// `@d` of a delay: `(nexis.core/force d)`.
fn forceDelay(vm: *VM, d: Value) VmError!Value {
    const registry = if (vm.home().registry) |*r| r else return VmError.NotDerefable;
    const force = registry.core.lookupLocal("force") orelse return VmError.NotDerefable;
    // `d` is the call's argument (GC.md §11.5, class 2).
    return vm.callValue(force.current() orelse return VmError.UnboundVar, &.{d});
}

// =============================================================================
// scan + reduce-tree
// =============================================================================
//
// `(db/scan tx tree-keyword)` returns a vector of `[key value]`
// 2-vectors in key order; `(db/scan tx tree-keyword start-key)`
// starts at `start-key` (inclusive) and
// `(db/scan tx tree-keyword start-key end-key)` stops before
// `end-key`. `(db/reduce-tree tx tree-keyword f init)` walks the
// whole tree applying `(f acc key value)` and returns the final
// accumulator.
//
// Keys come back as strings of the key bytes: interned keywords would
// grow the interner, which never shrinks, by every key a walk meets.
// `db/ref` takes a string key, so a key read back names its ref. Each
// value is fully decoded onto the heap before the cursor advances.
// Results are eager.

/// Start `walk` over `tree_name` in the transaction of `h`; false
/// for an absent tree, which every caller treats as empty.
fn beginWalk(vm: *VM, walk: *db_mod.Walk, h: *db_mod.Handle, tree_name: []const u8) VmError!bool {
    return switch (h.txn) {
        inline else => |*t| walk.begin(t, tree_name),
    } catch |err| dbFailure(vm, err);
}

/// An entry's value, decoded onto the heap before the walk moves on.
fn decodeEntry(vm: *VM, kv: db_mod.Walk.Entry) VmError!Value {
    return codec_mod.decode(
        vm.ensureHeap(),
        vm.ensureInterner(),
        kv.value,
        &dispatch_mod.hashValue,
        &dispatch_mod.equal,
    ) catch |err| return dbFailure(vm, err);
}

fn fnDbScan(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const tree_v = args[1];
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    const interner = vm.ensureInterner();
    const tree_name = interner.keywordName(tree_v.asKeywordId());

    // Optional range bounds: a keyword, symbol or string, whose name
    // or bytes are the key's, as for `db/ref`.
    const start_bytes: ?[]const u8 = if (args.len >= 3) try internedName(vm, args[2]) else null;
    const end_bytes: ?[]const u8 = if (args.len >= 4) try internedName(vm, args[3]) else null;

    var walk: db_mod.Walk = undefined;
    if (!try beginWalk(vm, &walk, try activeTxn(tx_v), tree_name)) {
        return vector_mod.fromSlice(vm.ensureHeap(), &.{}) catch VmError.OutOfMemory;
    }
    defer walk.end();

    var entries: std.ArrayList(Value) = .empty;
    defer entries.deinit(vm.allocator);

    var maybe_kv = walk.first(start_bytes) catch |err| return dbFailure(vm, err);
    while (maybe_kv) |kv| : (maybe_kv = walk.next() catch |err| return dbFailure(vm, err)) {
        if (end_bytes) |eb| {
            if (std.mem.order(u8, kv.key, eb) != .lt) break;
        }
        const decoded_v = try decodeEntry(vm, kv);
        const key_v = string_mod.fromBytes(vm.ensureHeap(), kv.key) catch return VmError.OutOfMemory;
        const pair = [_]Value{ key_v, decoded_v };
        const pair_vec = vector_mod.fromSlice(vm.ensureHeap(), &pair) catch return VmError.OutOfMemory;
        entries.append(vm.allocator, pair_vec) catch return VmError.OutOfMemory;
    }

    return vector_mod.fromSlice(vm.ensureHeap(), entries.items) catch VmError.OutOfMemory;
}

/// Predicate for snapshot Values. True if `x` is a
/// read-tx handle that has not been released. Released
/// snapshots return false (mirrors Var.bound semantics).
fn fnDbSnapshotQ(_: *VM, args: []const Value) VmError!Value {
    const v = args[0];
    if (v.kind() != .db_read_txn) return value_mod.fromBool(false);
    const h = readTxnHandle(v).?;
    return value_mod.fromBool(h.active);
}

/// `(db/reduce-tree tx tree f init)`: `(f acc key value)` over the
/// tree as it was when the walk began, whatever `f` writes to it
/// (DB.md §12). Rooting class 2 (GC.md §11.5).
fn fnDbReduceTree(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const tree_v = args[1];
    const f = args[2];
    var acc = args[3];
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    const interner = vm.ensureInterner();
    const tree_name = interner.keywordName(tree_v.asKeywordId());

    const h = try activeTxn(tx_v);
    var walk: db_mod.Walk = undefined;
    if (!try beginWalk(vm, &walk, h, tree_name)) return acc;
    defer walk.end();
    h.held += 1;
    defer h.held -= 1;

    var maybe_kv = walk.first(null) catch |err| return dbFailure(vm, err);
    while (maybe_kv) |kv| : (maybe_kv = walk.next() catch |err| return dbFailure(vm, err)) {
        const decoded_v = try decodeEntry(vm, kv);
        const key_v = string_mod.fromBytes(vm.ensureHeap(), kv.key) catch return VmError.OutOfMemory;
        const call_args = [_]Value{ acc, key_v, decoded_v };
        acc = try vm.callValue(f, &call_args);
    }
    return acc;
}

/// `(db/alter! tx ref f & args)` — read-modify-write inside an
/// active write tx. Reads current via getRef, computes
/// `(apply f current args)` via vm.callValue, writes via putRef.
/// Returns the new value.
///
/// If `f` throws or control transfers, do NOT write.
/// Connection mismatch on `ref` surfaces as
/// :db/store-mismatch via db.zig's assertRefMatchesConn.
fn fnDbAlter(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const r = args[1];
    const f = args[2];
    const extra = args[3..];

    const h = writeTxnHandle(tx_v) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;

    // 1. Read current.
    const current_opt = db_mod.getRef(&h.txn.write, r, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return dbFailure(vm, err);
    const current = current_opt orelse value_mod.nilValue();

    // 2. Build (f current extra...) arg list. f is the FIRST
    //    arg to callValue; current + extra follow.
    const call_args = vm.allocator.alloc(Value, 1 + extra.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = current;
    for (extra, 0..) |a, i| call_args[1 + i] = a;

    // 3. Invoke, the transaction held. Throws / control transfers
    //    propagate UNCHANGED so the with-tx's catch can abort. NO
    //    write on error.
    h.held += 1;
    defer h.held -= 1;
    const new_value = try vm.callValue(f, call_args);

    // 4. Write; a lazy result is realized with the transaction still
    //    held, and rooted while it is.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(new_value);
    try putRealizing(vm, h, r, new_value);
    return new_value;
}

// =============================================================================
// Transients (docs/TRANSIENT.md)
// =============================================================================
//
// The Clojure surface over `coll/transient.zig`: each `!` returns the
// transient to use from then on, which a vector `assoc!` or `pop!`
// replaces (the old one is frozen, as `persistent!` leaves it).

fn transientFailure(vm: *VM, err: anyerror) VmError {
    return switch (err) {
        error.TransientFrozen => vm.throwKeyword("transient-used-after-persistent"),
        error.OutOfMemory, error.Overflow => VmError.OutOfMemory,
        error.IndexOutOfBounds => VmError.IndexOutOfBounds,
        else => VmError.KindMismatch,
    };
}

fn requireTransient(v: Value) VmError!u16 {
    if (v.kind() != .transient) return VmError.KindMismatch;
    return v.subkind();
}

fn transientCount(vm: *VM, t: Value) VmError!usize {
    return switch (try requireTransient(t)) {
        transient_mod.subkind_transient_map => transient_mod.mapCountBang(t),
        transient_mod.subkind_transient_set => transient_mod.setCountBang(t),
        else => transient_mod.vectorCountBang(t),
    } catch |err| transientFailure(vm, err);
}

/// `(transient coll)` → a transient of a vector, map or set.
fn fnTransient(vm: *VM, args: []const Value) VmError!Value {
    return transient_mod.transientFrom(vm.ensureHeap(), args[0]) catch |err| transientFailure(vm, err);
}

/// `(persistent! t)` → the collection, the transient frozen.
fn fnPersistentBang(vm: *VM, args: []const Value) VmError!Value {
    _ = try requireTransient(args[0]);
    return transient_mod.persistentBang(args[0]) catch |err| transientFailure(vm, err);
}

// A map or set edit whose key hashed or compared past the stack guard
// changes nothing and raises `:stack-overflow`, so a `!` call of
// several edits stops there, the edits before it kept (TRANSIENT.md
// §6, SEMANTICS §2.7).

// A key or element is realized before the in-place edit starts
// (docs/LAZY.md §6), so no code runs in the middle of an edit of a
// transient the code can reach.
fn assocBang(vm: *VM, t: Value, k: Value, v: Value) VmError!void {
    try seq_mod.realizeAll(vm, k);
    const before = dispatch_mod.spoilCount();
    _ = transient_mod.mapAssocBang(vm.ensureHeap(), t, k, v, &dispatch_mod.hashValue, &dispatch_mod.equal, &dispatch_mod.spoilCount) catch |err| return transientFailure(vm, err);
    try vm.checkDeepData(before);
}

fn conjBangSet(vm: *VM, t: Value, x: Value) VmError!void {
    try seq_mod.realizeAll(vm, x);
    const before = dispatch_mod.spoilCount();
    _ = transient_mod.setConjBang(vm.ensureHeap(), t, x, &dispatch_mod.hashValue, &dispatch_mod.equal, &dispatch_mod.spoilCount) catch |err| return transientFailure(vm, err);
    try vm.checkDeepData(before);
}

/// `(conj! t x & xs)`; `(conj!)` is a transient vector, `(conj! t)` t.
fn fnConjBang(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    if (args.len == 0) return fnTransient(vm, &.{vector_mod.empty(heap) catch return VmError.OutOfMemory});
    const t = args[0];
    switch (try requireTransient(t)) {
        transient_mod.subkind_transient_vector => for (args[1..]) |x| {
            _ = transient_mod.vectorConjBang(heap, t, x) catch |err| return transientFailure(vm, err);
        },
        transient_mod.subkind_transient_set => for (args[1..]) |x| try conjBangSet(vm, t, x),
        else => {
            // Every operand's shape is checked before the first edit.
            for (args[1..]) |x| try checkMapConjOperand(x);
            for (args[1..]) |x| try conjBangMap(vm, t, x);
        },
    }
    return t;
}

/// What `conj` adds to a map: a `[k v]` entry, a map or record, or nil.
fn checkMapConjOperand(x: Value) VmError!void {
    switch (x.kind()) {
        .nil, .persistent_map, .record, .sorted_map => {},
        .persistent_vector => if (vector_mod.count(x) != 2) return VmError.ArityMismatch,
        else => return VmError.KindMismatch,
    }
}

/// A transient map with `x` added as `conj` adds it to a map: a
/// `[k v]` entry, every entry of a map or record, or nothing for nil.
fn conjBangMap(vm: *VM, t: Value, x: Value) VmError!void {
    try checkMapConjOperand(x);
    switch (x.kind()) {
        .persistent_map, .record, .sorted_map => {
            var it = MapEntries.of(x).?;
            while (it.next()) |e| try assocBang(vm, t, e.key, e.value);
        },
        .persistent_vector => {
            // The entry is the argument; its key is realized through it.
            try seq_mod.realizeAll(vm, x);
            try assocBang(vm, t, vector_mod.nth(x, 0), vector_mod.nth(x, 1));
        },
        else => {},
    }
}

/// `(assoc! t k v & kvs)` on a transient map or vector.
fn fnAssocBang(vm: *VM, args: []const Value) VmError!Value {
    if (args.len % 2 != 1) return VmError.ArityMismatch;
    const heap = vm.ensureHeap();
    const t = args[0];
    const sub = try requireTransient(t);
    if (sub == transient_mod.subkind_transient_set) return VmError.KindMismatch;
    if (sub == transient_mod.subkind_transient_vector) {
        // Every index is checked before the first write.
        var n = try transientCount(vm, t);
        var i: usize = 1;
        while (i < args.len) : (i += 2) {
            const k = args[i];
            if (k.kind() != .fixnum) return VmError.KindMismatch;
            if (k.asFixnum() < 0 or k.asFixnum() > n) return VmError.IndexOutOfBounds;
            if (k.asFixnum() == n) n += 1;
        }
        i = 1;
        while (i < args.len) : (i += 2) {
            _ = transient_mod.vectorAssocBang(heap, t, @intCast(args[i].asFixnum()), args[i + 1]) catch |err| return transientFailure(vm, err);
        }
        return t;
    }
    var i: usize = 1;
    while (i < args.len) : (i += 2) try assocBang(vm, t, args[i], args[i + 1]);
    return t;
}

/// `assoc!` as a leaf (VM.md §6): into a transient vector, and into a
/// transient map by keys off the heap; anything else goes the general
/// way.
fn fnAssocBangLeaf(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .transient) return VmError.NeedsReentry;
    switch (args[0].subkind()) {
        transient_mod.subkind_transient_vector => {},
        transient_mod.subkind_transient_map => {
            var i: usize = 1;
            while (i < args.len) : (i += 2) if (args[i].kind().isHeap()) return VmError.NeedsReentry;
        },
        else => return VmError.NeedsReentry,
    }
    return fnAssocBang(vm, args);
}

/// `(dissoc! t k & ks)` on a transient map.
fn fnDissocBang(vm: *VM, args: []const Value) VmError!Value {
    const t = args[0];
    if (try requireTransient(t) != transient_mod.subkind_transient_map) return VmError.KindMismatch;
    for (args[1..]) |k| {
        try seq_mod.realizeAll(vm, k);
        const before = dispatch_mod.spoilCount();
        _ = transient_mod.mapDissocBang(vm.ensureHeap(), t, k, &dispatch_mod.hashValue, &dispatch_mod.equal, &dispatch_mod.spoilCount) catch |err| return transientFailure(vm, err);
        try vm.checkDeepData(before);
    }
    return t;
}

/// `(disj! t x & xs)` on a transient set.
fn fnDisjBang(vm: *VM, args: []const Value) VmError!Value {
    const t = args[0];
    if (try requireTransient(t) != transient_mod.subkind_transient_set) return VmError.KindMismatch;
    for (args[1..]) |x| {
        try seq_mod.realizeAll(vm, x);
        const before = dispatch_mod.spoilCount();
        _ = transient_mod.setDisjBang(vm.ensureHeap(), t, x, &dispatch_mod.hashValue, &dispatch_mod.equal, &dispatch_mod.spoilCount) catch |err| return transientFailure(vm, err);
        try vm.checkDeepData(before);
    }
    return t;
}

/// `(pop! t)` on a transient vector: without its last element.
fn fnPopBang(vm: *VM, args: []const Value) VmError!Value {
    if (try requireTransient(args[0]) != transient_mod.subkind_transient_vector) return VmError.KindMismatch;
    return transient_mod.vectorPopBang(vm.ensureHeap(), args[0]) catch |err| transientFailure(vm, err);
}

// =============================================================================
// format (a subset of Java's Formatter, as Clojure's format uses)
// =============================================================================

/// `(format fmt & args)` → `fmt` with each `%` conversion replaced by
/// the next argument: `%s` (as `str` makes it text, nil as `nil`),
/// `%d` (an integer), `%f` (any number; 6 decimals unless `.N`),
/// `%x` / `%X` (an integer in hex, two's complement when negative),
/// `%c` (a char), `%n` and `%%`. A width pads to that many code
/// points on the left, or the right with `-`; `0` pads a number with
/// zeros; `.N` keeps N characters of a `%s`. A missing argument or
/// unknown conversion is `:invalid-argument`, an argument of the
/// wrong kind `:kind-mismatch` (STDLIB.md §2).
fn fnFormat(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const fmt = string_mod.asBytes(args[0]);
    var out = std.Io.Writer.Allocating.init(vm.allocator);
    defer out.deinit();
    var piece = std.Io.Writer.Allocating.init(vm.allocator);
    defer piece.deinit();
    const interner = vm.ensureInterner();
    var next: usize = 1;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') {
            out.writer.writeByte(fmt[i]) catch return VmError.OutOfMemory;
            continue;
        }
        i += 1;
        var left = false;
        var zero = false;
        while (i < fmt.len and (fmt[i] == '-' or fmt[i] == '0')) : (i += 1) {
            if (fmt[i] == '-') left = true else zero = true;
        }
        const width = try formatField(fmt, &i);
        var precision: ?usize = null;
        if (i < fmt.len and fmt[i] == '.') {
            i += 1;
            precision = try formatField(fmt, &i);
        }
        if (i >= fmt.len) return VmError.InvalidArgument;
        const conv = fmt[i];
        if (precision != null and conv != 's' and conv != 'f') return VmError.InvalidArgument;
        piece.clearRetainingCapacity();
        const w = &piece.writer;
        switch (conv) {
            '%' => w.writeByte('%') catch return VmError.OutOfMemory,
            'n' => w.writeByte('\n') catch return VmError.OutOfMemory,
            else => {
                if (next >= args.len) return VmError.InvalidArgument;
                const a = args[next];
                next += 1;
                switch (conv) {
                    's' => {
                        if (a.isNil()) w.writeAll("nil") catch return VmError.OutOfMemory else try appendStrValue(vm, &piece, a);
                        if (precision) |p| piece.shrinkRetainingCapacity(try codepointPrefix(piece.written(), p));
                    },
                    'd' => {
                        if (!vm_mod.isInteger(a)) return VmError.KindMismatch;
                        format_mod.format(a, .readable, w, interner) catch return VmError.OutOfMemory;
                    },
                    'f' => try formatFixed(vm, w, (try vm_mod.numDouble(a)).asFloat(), precision orelse 6),
                    'x', 'X' => {
                        const n: u64 = @bitCast(try intArg(a));
                        w.printInt(n, 16, if (conv == 'x') .lower else .upper, .{}) catch return VmError.OutOfMemory;
                    },
                    'c' => {
                        if (a.kind() != .char) return VmError.KindMismatch;
                        format_mod.format(a, .display, w, interner) catch return VmError.OutOfMemory;
                    },
                    else => return VmError.InvalidArgument,
                }
            },
        }
        const text = piece.written();
        const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
        const pad = if (width > chars) width - chars else 0;
        const numeric = conv == 'd' or conv == 'f' or conv == 'x' or conv == 'X';
        if (left) {
            out.writer.writeAll(text) catch return VmError.OutOfMemory;
            out.writer.splatByteAll(' ', pad) catch return VmError.OutOfMemory;
        } else if (zero and numeric) {
            // Zeros go after the sign.
            const signed = text.len > 0 and text[0] == '-';
            if (signed) out.writer.writeByte('-') catch return VmError.OutOfMemory;
            out.writer.splatByteAll('0', pad) catch return VmError.OutOfMemory;
            out.writer.writeAll(if (signed) text[1..] else text) catch return VmError.OutOfMemory;
        } else {
            out.writer.splatByteAll(' ', pad) catch return VmError.OutOfMemory;
            out.writer.writeAll(text) catch return VmError.OutOfMemory;
        }
    }
    return string_mod.fromBytes(vm.ensureHeap(), out.written()) catch VmError.OutOfMemory;
}

/// The largest width or precision `format` accepts; a larger one would
/// only allocate padding.
const format_field_max = 1 << 20;

/// The decimal number at `fmt[i.*..]`, advancing `i` past it; 0 when
/// there is none, `:invalid-argument` above `format_field_max`.
fn formatField(fmt: []const u8, i: *usize) VmError!usize {
    var n: usize = 0;
    while (i.* < fmt.len and std.ascii.isDigit(fmt[i.*])) : (i.* += 1) {
        n = n * 10 + (fmt[i.*] - '0');
        if (n > format_field_max) return VmError.InvalidArgument;
    }
    return n;
}

/// The byte length of the first `n` code points of `text`;
/// `:utf8-error` when a malformed sequence starts within them.
fn codepointPrefix(text: []const u8, n: usize) VmError!usize {
    var i: usize = 0;
    for (0..n) |_| {
        if (i == text.len) break;
        i += (string_mod.decodeAt(text, i) catch return VmError.Utf8Error).len;
    }
    return i;
}

/// `%f`: `x` with `precision` decimals from its shortest round-trip
/// digits, as Java's `Formatter` rounds them; NaN and the infinities
/// as Java spells them.
fn formatFixed(vm: *VM, w: *std.Io.Writer, x: f64, precision: usize) VmError!void {
    if (std.math.isNan(x)) return w.writeAll("NaN") catch VmError.OutOfMemory;
    if (std.math.isInf(x)) return w.writeAll(if (x < 0) "-Infinity" else "Infinity") catch VmError.OutOfMemory;
    // Every f64's integer digits and sign, plus the decimals.
    const buf = vm.allocator.alloc(u8, std.fmt.float.bufferSize(.decimal, f64) + 1 + precision) catch return VmError.OutOfMemory;
    defer vm.allocator.free(buf);
    const text = std.fmt.float.render(buf, x, .{ .mode = .decimal, .precision = precision }) catch return VmError.InvalidArgument;
    w.writeAll(text) catch return VmError.OutOfMemory;
}

// =============================================================================
// Atoms (see docs/ATOM.md)
// =============================================================================
//
// Each mutator marks the atom in flight (`atom_mod.tryEnterCritical`,
// cleared by a `defer` on every exit path) while it computes and
// validates the new state, writes it only after every call back into
// the VM has returned, then clears the flag and runs the watches
// (ATOM.md §4). A throw or control transfer before the write leaves
// the atom unchanged.

/// `(atom init & {:keys [meta validator]})`: a key it does not take
/// is ignored and a key with no value is `:invalid-argument`, as in
/// Clojure. The initial value must satisfy the validator.
fn fnAtom(vm: *VM, args: []const Value) VmError!Value {
    const opts = args[1..];
    if (opts.len % 2 != 0) return VmError.InvalidArgument;
    const interner = vm.ensureInterner();
    const meta_key = interner.internKeywordValue("meta") catch return VmError.OutOfMemory;
    const validator_key = interner.internKeywordValue("validator") catch return VmError.OutOfMemory;
    var meta = value_mod.nilValue();
    var validator = value_mod.nilValue();
    var i: usize = 0;
    while (i < opts.len) : (i += 2) {
        if (opts[i].identicalTo(meta_key)) meta = opts[i + 1];
        if (opts[i].identicalTo(validator_key)) validator = opts[i + 1];
    }
    if (!meta.isNil() and meta.kind() != .persistent_map and meta.kind() != .sorted_map) return VmError.KindMismatch;
    try validate(vm, validator, args[0]);
    const a = atom_mod.make(vm.ensureHeap(), args[0]) catch return VmError.OutOfMemory;
    atom_mod.body(a).validator = validator;
    if (!meta.isNil()) heap_mod.Heap.asHeapHeader(a).setMeta(heap_mod.Heap.asHeapHeader(meta));
    return a;
}

fn fnAtomQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .atom);
}

/// Clojure's `ARef.validate`: a falsy answer from the validator is
/// `:invalid-reference-state`; a throw out of it propagates. A caller
/// that keeps `state` past the call roots it: the validator may
/// `recur` over its argument (GC.md §11.5).
fn validate(vm: *VM, validator: Value, state: Value) VmError!void {
    if (validator.isNil()) return;
    if (!(try vm.callValue(validator, &.{state})).isTruthy()) return vm.throwKeyword("invalid-reference-state");
}

/// Clojure's `ARef.notifyWatches`: each watch called with
/// `(key atom old new)` after the change, in the watches map's order.
/// The map is rooted here, since a watch that adds or removes one
/// replaces the atom's map; the caller roots `old` and `new`, which
/// every call receives and any may `recur` away (GC.md §11.5, class 3).
fn notifyWatches(vm: *VM, a: Value, old: Value, new: Value) VmError!void {
    const watches = atom_mod.body(a).watches;
    if (watches.isNil()) return;
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(watches);
    var it = champ_mod.mapIter(watches);
    while (it.next()) |e| _ = try vm.callValue(e.value, &.{ e.key, a, old, new });
}

fn fnResetBang(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    const new_val = args[1];
    if (a.kind() != .atom) return VmError.KindMismatch;
    // `new_val` is an argument; `old` leaves the atom at the write.
    const scope = vm.rootScope();
    defer scope.release();
    const old = blk: {
        if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
        defer atom_mod.exitCritical(a);
        try validate(vm, atom_mod.body(a).validator, new_val);
        const old = atom_mod.getValue(a);
        atom_mod.setValue(a, new_val);
        break :blk old;
    };
    try scope.push(old);
    try notifyWatches(vm, a, old, new_val);
    return new_val;
}

/// `(swap! a f & args)` → sets `a` to `(apply f @a args)` and
/// returns it; `swap-vals!` returns `[old new]`. Nothing is written
/// when `f` or the validator throws or control transfers.
fn swapImpl(vm: *VM, args: []const Value, pair: bool) VmError!Value {
    const a = args[0];
    if (a.kind() != .atom) return VmError.KindMismatch;
    // `old` leaves the atom at the write, and `f`'s result is no
    // argument: both are kept across the validator and the watches,
    // which may `recur` over them (GC.md §11.5, class 3).
    const scope = vm.rootScope();
    defer scope.release();
    const old = atom_mod.getValue(a);
    try scope.push(old);
    const new_val = blk: {
        if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
        defer atom_mod.exitCritical(a);
        const call_args = vm.allocator.alloc(Value, args.len - 1) catch return VmError.OutOfMemory;
        defer vm.allocator.free(call_args);
        call_args[0] = old;
        @memcpy(call_args[1..], args[2..]);
        const new_val = try vm.callValue(args[1], call_args);
        try scope.push(new_val);
        try validate(vm, atom_mod.body(a).validator, new_val);
        atom_mod.setValue(a, new_val);
        break :blk new_val;
    };
    try notifyWatches(vm, a, old, new_val);
    if (!pair) return new_val;
    return vector_mod.fromSlice(vm.ensureHeap(), &.{ old, new_val }) catch VmError.OutOfMemory;
}

fn fnSwapBang(vm: *VM, args: []const Value) VmError!Value {
    return swapImpl(vm, args, false);
}

fn fnSwapValsBang(vm: *VM, args: []const Value) VmError!Value {
    return swapImpl(vm, args, true);
}

/// `identical?` semantics, not structural `=`: bit identity for an
/// immediate, the same block for a heap value (ATOM.md §4.6). The
/// new value is validated before the comparison, as in Clojure.
fn fnCompareAndSetBang(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    const old = args[1];
    const new_val = args[2];
    if (a.kind() != .atom) return VmError.KindMismatch;
    {
        if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
        defer atom_mod.exitCritical(a);
        try validate(vm, atom_mod.body(a).validator, new_val);
        if (!atom_mod.getValue(a).identicalTo(old)) return value_mod.fromBool(false);
        atom_mod.setValue(a, new_val);
    }
    try notifyWatches(vm, a, old, new_val);
    return value_mod.fromBool(true);
}

/// `(set-validator! a f)` → nil once the current value satisfies `f`
/// (nil removes the validator); a value that does not leaves the old
/// validator in place.
fn fnSetValidator(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    if (a.kind() != .atom) return VmError.KindMismatch;
    try validate(vm, args[1], atom_mod.getValue(a));
    atom_mod.body(a).validator = args[1];
    return value_mod.nilValue();
}

fn fnGetValidator(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .atom) return VmError.KindMismatch;
    return atom_mod.body(args[0]).validator;
}

/// `(add-watch a key f)` → `a`, with `f` its watch under `key` (an
/// `=` key replaces the watch it names).
fn fnAddWatch(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    if (a.kind() != .atom) return VmError.KindMismatch;
    const heap = vm.ensureHeap();
    const b = atom_mod.body(a);
    const watches = if (b.watches.isNil()) champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory else b.watches;
    b.watches = try mapPut(heap, watches, args[1], args[2]);
    return a;
}

/// `(remove-watch a key)` → `a`, without the watch under `key`.
fn fnRemoveWatch(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    if (a.kind() != .atom) return VmError.KindMismatch;
    const b = atom_mod.body(a);
    if (b.watches.isNil()) return a;
    const rest = champ_mod.mapDissoc(vm.ensureHeap(), b.watches, args[1], &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
    b.watches = if (champ_mod.mapCount(rest) == 0) value_mod.nilValue() else rest;
    return a;
}

// =============================================================================
// Core string ops
// =============================================================================
//
// `(str & xs)` concatenates each argument's text as
// `appendStrValue` makes it: a string or char displayed, nil empty,
// anything else as `pr` prints it.
//
// GC rooting: str / pr-str allocate the final heap string after
// walking the args slice, which is rooted for the call, and never
// call back into the VM (`docs/GC.md` §11.5, class 1).

/// Append `v` as `str` makes it text (Clojure's `toString`): nil is
/// empty, a string or char is itself, anything else prints as `pr`
/// prints it, so the strings inside a collection keep their quotes.
/// Used by `str`, `join` and `spit`.
fn appendStrValue(
    vm: *VM,
    w: *std.Io.Writer.Allocating,
    v: Value,
) VmError!void {
    if (v.kind() == .nil) return;
    const interner = vm.ensureInterner();
    // The printer runs no code: every lazy seq in `v` is realized
    // first, in native context (docs/LAZY.md §8).
    try seq_mod.realizeAll(vm, v);
    // A float by itself is Java's `toString` (`Infinity`), as Clojure's
    // `str` makes it; inside a collection it prints readable (`##Inf`).
    if (v.isFloat()) return format_mod.formatFloatJava(v.asFloat(), &w.writer) catch return VmError.OutOfMemory;
    // A pattern by itself is its source (`Pattern.toString`).
    if (v.kind() == .regex) return w.writer.writeAll(regex_mod.sourceOf(v)) catch return VmError.OutOfMemory;
    const mode: format_mod.FormatMode = switch (v.kind()) {
        .string, .char => .display,
        else => .readable,
    };
    // The writer is an Allocating buffer: a failed write is an
    // allocation failure.
    format_mod.format(v, mode, &w.writer, interner) catch |err| switch (err) {
        error.Utf8Error => return VmError.Utf8Error,
        error.WriteFailed => return VmError.OutOfMemory,
    };
}

/// The length of `v`'s `str` text when no formatter is needed to
/// make it: nil, a string, a char or a fixnum; null for anything else.
fn plainStrLen(v: Value) ?usize {
    return switch (v.kind()) {
        .nil => 0,
        .string => string_mod.byteLen(v),
        .char => std.unicode.utf8CodepointSequenceLength(v.asChar()) catch unreachable,
        .fixnum => decimalLen(v.asFixnum()),
        else => null,
    };
}

fn decimalLen(x: i64) usize {
    const u = @abs(x);
    var len: usize = if (x < 0) 2 else 1;
    var bound: u64 = 10;
    while (u >= bound) : (bound *%= 10) {
        len += 1;
        if (bound > std.math.maxInt(u64) / 10) break;
    }
    return len;
}

/// Write `v`'s text, `plainStrLen(v)` bytes, at the start of `out`;
/// the rest of `out` follows it.
fn writePlainStr(v: Value, out: []u8) []u8 {
    const len = plainStrLen(v).?;
    switch (v.kind()) {
        .string => @memcpy(out[0..len], string_mod.asBytes(v)),
        .char => _ = std.unicode.utf8Encode(v.asChar(), out[0..len]) catch unreachable,
        .fixnum => _ = std.fmt.printInt(out[0..len], v.asFixnum(), 10, .lower, .{}),
        else => {},
    }
    return out[len..];
}

/// `(str x ...)`. Arguments that are all nil, strings, chars or
/// fixnums are measured and written once into a string of their
/// length; one string alone is itself, as in Clojure. Anything else
/// goes through the printer.
fn fnStr(vm: *VM, args: []const Value) VmError!Value {
    return (try strPlain(vm, args)) orelse strFormatted(vm, args);
}

/// `str` as a leaf (VM.md §6): of nil, strings, chars and fixnums,
/// whose text is written without walking anything; anything else goes
/// the general way.
fn fnStrLeaf(vm: *VM, args: []const Value) VmError!Value {
    return (try strPlain(vm, args)) orelse VmError.NeedsReentry;
}

/// `str` of `args` when each is nil, a string, a char or a fixnum;
/// null otherwise.
fn strPlain(vm: *VM, args: []const Value) VmError!?Value {
    if (args.len == 1 and args[0].kind() == .string) return args[0];
    var len: usize = 0;
    for (args) |x| len += plainStrLen(x) orelse return null;
    const out = string_mod.allocUninit(vm.ensureHeap(), len) catch return VmError.OutOfMemory;
    var rest = out.bytes;
    for (args) |x| rest = writePlainStr(x, rest);
    return out.value;
}

fn strFormatted(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    for (args) |x| try appendStrValue(vm, &w, x);
    return string_mod.fromBytes(vm.ensureHeap(), w.written()) catch return VmError.OutOfMemory;
}

fn fnStringQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .string);
}

/// `(subs s start)` / `(subs s start end)` — substring by CODEPOINT
/// indices. Allocates a fresh heap string; there is no zero-copy
/// slice (subkind 2 is reserved for emdb-mmap, NOT for in-heap
/// slicing).
fn fnSubs(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    if (s.kind() != .string) return VmError.KindMismatch;
    if (args[1].kind() != .fixnum) return VmError.KindMismatch;
    const start = args[1].asFixnum();
    if (start < 0) return VmError.IndexOutOfBounds;

    const cp_count = string_mod.codepointCount(s) catch return VmError.Utf8Error;
    const start_u: usize = @intCast(start);
    const end_u: usize = if (args.len > 2) blk: {
        if (args[2].kind() != .fixnum) return VmError.KindMismatch;
        const end_i = args[2].asFixnum();
        if (end_i < 0) return VmError.IndexOutOfBounds;
        break :blk @intCast(end_i);
    } else cp_count;

    if (start_u > cp_count or end_u > cp_count or start_u > end_u) {
        return VmError.IndexOutOfBounds;
    }
    const byte_range = string_mod.byteRangeForCodepoints(s, start_u, end_u) catch |err| switch (err) {
        error.InvalidUtf8 => return VmError.Utf8Error,
        // `byteRangeForCodepoints` returns OutOfBounds for
        // start/end/cp_count consistency; we already validated
        // above so this branch is defensive.
        error.OutOfBounds => return VmError.IndexOutOfBounds,
    };
    const src_bytes = string_mod.asBytes(s);
    return string_mod.fromBytes(vm.ensureHeap(), src_bytes[byte_range.start..byte_range.end]) catch return VmError.OutOfMemory;
}

// =============================================================================
// Regular expressions (docs/REGEX.md §9)
// =============================================================================
//
// A match is the matched string when the pattern has no groups, else
// the vector `[whole g1 g2 ...]` with nil for a group that did not
// take part (Clojure's `re-groups`). Each native validates its string
// once (`:utf8-error`, as `nexis.string` does); a matcher's string is
// validated when the matcher is made. The engine's scratch space is
// on `vm.allocator`, freed before the native returns.
//
// GC rooting: the strings and the vector a match builds are fresh
// blocks gathered before anything else allocates; `Heap.alloc` never
// collects, and no native here calls back into the VM.

/// The pattern `v`, or `:kind-mismatch`, as Clojure's cast to
/// `Pattern` fails.
fn patternArg(v: Value) VmError!Value {
    if (v.kind() != .regex) return VmError.KindMismatch;
    return v;
}

/// The bytes of the string `v`, validated as UTF-8.
fn utf8Arg(v: Value) VmError![]const u8 {
    const s = try stringArg(v);
    if (!std.unicode.utf8ValidateSlice(s)) return VmError.Utf8Error;
    return s;
}

/// A match as Clojure's `re-groups` gives it, from `group(g)`, the
/// span of group `g` or null.
fn matchValue(vm: *VM, hay: []const u8, ngroups: usize, ctx: anytype, comptime group: fn (@TypeOf(ctx), usize) ?[2]usize) VmError!Value {
    const heap = vm.ensureHeap();
    const span = group(ctx, 0).?;
    if (ngroups == 0) return string_mod.fromBytes(heap, hay[span[0]..span[1]]) catch VmError.OutOfMemory;
    const items = vm.allocator.alloc(Value, ngroups + 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(items);
    for (items, 0..) |*item, g| item.* = if (group(ctx, g)) |s|
        string_mod.fromBytes(heap, hay[s[0]..s[1]]) catch return VmError.OutOfMemory
    else
        value_mod.nilValue();
    return vector_mod.fromSlice(heap, items) catch VmError.OutOfMemory;
}

fn vmGroup(vm: *const regex_mod.Vm, g: usize) ?[2]usize {
    return vm.group(g);
}

fn matcherGroup(m: Value, g: usize) ?[2]usize {
    return regex_mod.matcherGroup(m, g);
}

/// `(re-pattern s)` → the pattern `s` compiles to, or `s` itself when
/// it is a pattern. A syntax error throws `{:error :invalid-regex
/// :message M :pattern s :index I}`, `I` the code-point index Java's
/// `PatternSyntaxException` reports (docs/REGEX.md §9).
fn fnRePattern(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .regex) return args[0];
    const source = try utf8Arg(args[0]);
    const made = regex_mod.make(vm.ensureHeap(), vm.allocator, source) catch |err| return switch (err) {
        error.OutOfMemory => VmError.OutOfMemory,
        error.StackOverflow => VmError.StackOverflow,
    };
    switch (made) {
        .ok => |p| return p,
        .err => |e| {
            defer vm.allocator.free(e.msg);
            const heap = vm.ensureHeap();
            const interner = vm.ensureInterner();
            const index = std.unicode.utf8CountCodepoints(source[0..e.offset]) catch e.offset;
            const fields = [_]struct { []const u8, Value }{
                .{ "error", interner.internKeywordValue("invalid-regex") catch return VmError.OutOfMemory },
                .{ "message", string_mod.fromBytes(heap, e.msg) catch return VmError.OutOfMemory },
                .{ "pattern", args[0] },
                .{ "index", value_mod.fromFixnum(@intCast(index)).? },
            };
            var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
            for (fields) |f| m = try mapPut(heap, m, interner.internKeywordValue(f[0]) catch return VmError.OutOfMemory, f[1]);
            return vm.throwErrorMap(m);
        },
    }
}

/// `(re-matcher re s)` → a fresh matcher of `re` over `s`.
fn fnReMatcher(vm: *VM, args: []const Value) VmError!Value {
    const p = try patternArg(args[0]);
    _ = try utf8Arg(args[1]);
    return regex_mod.makeMatcher(vm.ensureHeap(), p, args[1]) catch VmError.OutOfMemory;
}

/// `(re-find m)` → the next match of the matcher `m`, or nil;
/// `(re-find re s)` → the first match of `re` in `s`, or nil.
fn fnReFind(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) {
        const m = args[0];
        if (m.kind() != .matcher) return VmError.KindMismatch;
        if (!(regex_mod.matcherFind(vm.allocator, m) catch return VmError.OutOfMemory)) return value_mod.nilValue();
        return reGroups(vm, m);
    }
    return searchOnce(vm, args, false);
}

/// `(re-matches re s)` → the match of all of `s` (Java's `matches`),
/// or nil.
fn fnReMatches(vm: *VM, args: []const Value) VmError!Value {
    return searchOnce(vm, args, true);
}

fn searchOnce(vm: *VM, args: []const Value, whole: bool) VmError!Value {
    const prog = regex_mod.programOf(try patternArg(args[0]));
    const hay = try utf8Arg(args[1]);
    var rvm = regex_mod.Vm.init(vm.allocator, prog, prog.ngroups > 0) catch return VmError.OutOfMemory;
    defer rvm.deinit(vm.allocator);
    if (!rvm.exec(hay, 0, 0, whole)) return value_mod.nilValue();
    return matchValue(vm, hay, prog.ngroups, &rvm, vmGroup);
}

/// `(re-groups m)` → the last match of the matcher `m`;
/// `:invalid-argument` when it has none.
fn fnReGroups(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .matcher) return VmError.KindMismatch;
    return reGroups(vm, args[0]);
}

fn reGroups(vm: *VM, m: Value) VmError!Value {
    const b = regex_mod.matcherBox(m);
    if (b.state != .matched) return vm.fail(VmError.InvalidArgument, "re-groups: no match found", .{});
    return matchValue(vm, string_mod.asBytes(b.input), regex_mod.programOf(b.pattern).ngroups, m, matcherGroup);
}

// =============================================================================
// nexis.string namespace
// =============================================================================
//
// The seventeen natives of `string_natives` (docs/STDLIB.md §3);
// `capitalize`, `reverse`, `split-lines` and `escape` are in
// string.nx. Case mapping is ASCII-only. Searches, `split` and
// `replace` compare bytes with `string.Matches`, which on valid UTF-8
// matches only at code-point boundaries; indexes count code points.
// `split`, `replace` and `replace-first` also take a pattern
// (docs/REGEX.md §11), whose literal programs search with the same
// `string.Matches`.
//
// Errors are catchable keywords: `:kind-mismatch` for an argument of
// the wrong kind, `:utf8-error` for a malformed string a function
// reads by code point (`split` and the replaces validate every string
// argument first).
//
// GC rooting: each fn allocates output via string.fromBytes /
// vector.fromSlice while holding only its arguments, which are
// rooted for the call. Only `replace` and `replace-first` with a
// pattern and a function call back into the VM: they build the result
// in a Zig buffer and pass the match as the call's argument, so no
// heap value is held across the call (docs/GC.md §11.5).

/// `s` with its ASCII letters in one case; other bytes, every byte
/// of a multibyte scalar included, pass through.
fn mapAsciiCase(vm: *VM, s: Value, upper: bool) VmError!Value {
    const src = try stringArg(s);
    const out = string_mod.allocUninit(vm.ensureHeap(), src.len) catch return VmError.OutOfMemory;
    for (src, out.bytes) |b, *o| o.* = if (upper) std.ascii.toUpper(b) else std.ascii.toLower(b);
    return out.value;
}

fn fnStringLowerCase(vm: *VM, args: []const Value) VmError!Value {
    return mapAsciiCase(vm, args[0], false);
}

fn fnStringUpperCase(vm: *VM, args: []const Value) VmError!Value {
    return mapAsciiCase(vm, args[0], true);
}

/// Java's `Character.isWhitespace`, which Clojure's `blank?` and `trim`
/// use: the Unicode space, line and paragraph separators except the
/// no-break ones, and the controls tab through CR and FS through US.
fn isJavaWhitespace(c: u21) bool {
    return switch (c) {
        0x09...0x0D, 0x1C...0x20, 0x1680, 0x2000...0x2006, 0x2008...0x200A, 0x2028, 0x2029, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// `trim`, `triml`, `trimr`: `s` without whitespace at both ends, the
/// start or the end; `trim-newline` without every `\n` and `\r` at the
/// end. Bytes that are not UTF-8 are never trimmed.
fn trimString(vm: *VM, s: Value, left: bool, right: bool, comptime isTrimmed: fn (u21) bool) VmError!Value {
    const src = try stringArg(s);
    var lo: usize = 0;
    var hi: usize = src.len;
    if (left) while (lo < hi) {
        const sc = string_mod.decodeAt(src[0..hi], lo) catch break;
        if (!isTrimmed(sc.scalar)) break;
        lo += sc.len;
    };
    if (right) while (hi > lo) {
        var start = hi - 1;
        while (start > lo and src[start] & 0xC0 == 0x80) start -= 1;
        const sc = string_mod.decodeAt(src[0..hi], start) catch break;
        if (start + sc.len != hi or !isTrimmed(sc.scalar)) break;
        hi = start;
    };
    return string_mod.fromBytes(vm.ensureHeap(), src[lo..hi]) catch return VmError.OutOfMemory;
}

fn isNewline(c: u21) bool {
    return c == '\n' or c == '\r';
}

fn fnStringTrim(vm: *VM, args: []const Value) VmError!Value {
    return trimString(vm, args[0], true, true, isJavaWhitespace);
}

fn fnStringTriml(vm: *VM, args: []const Value) VmError!Value {
    return trimString(vm, args[0], true, false, isJavaWhitespace);
}

fn fnStringTrimr(vm: *VM, args: []const Value) VmError!Value {
    return trimString(vm, args[0], false, true, isJavaWhitespace);
}

fn fnStringTrimNewline(vm: *VM, args: []const Value) VmError!Value {
    return trimString(vm, args[0], false, true, isNewline);
}

fn stringArg(v: Value) VmError![]const u8 {
    if (v.kind() != .string) return VmError.KindMismatch;
    return string_mod.asBytes(v);
}

/// `(blank? s)` → whether `s` is nil, empty or only whitespace (Java's,
/// as `trim` reads it).
fn fnStringBlankQ(_: *VM, args: []const Value) VmError!Value {
    if (args[0].isNil()) return value_mod.fromBool(true);
    const src = try stringArg(args[0]);
    var i: usize = 0;
    while (i < src.len) {
        const sc = string_mod.decodeAt(src, i) catch return value_mod.fromBool(false);
        if (!isJavaWhitespace(sc.scalar)) return value_mod.fromBool(false);
        i += sc.len;
    }
    return value_mod.fromBool(true);
}

fn fnStringStartsWithQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(std.mem.startsWith(u8, try stringArg(args[0]), try stringArg(args[1])));
}

fn fnStringEndsWithQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(std.mem.endsWith(u8, try stringArg(args[0]), try stringArg(args[1])));
}

fn fnStringIncludesQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(string_mod.indexOf(try stringArg(args[0]), try stringArg(args[1]), 0) != null);
}

/// The bytes a search looks for: a string's, or a char's UTF-8.
fn needleBytes(v: Value, buf: *[4]u8) VmError![]const u8 {
    if (v.kind() == .char) {
        const n = std.unicode.utf8Encode(v.asChar(), buf) catch return VmError.Utf8Error;
        return buf[0..n];
    }
    return stringArg(v);
}

/// `(index-of s value)` / `(index-of s value from)` → the code-point
/// index of the first occurrence of `value` (a string or char) at or
/// after `from`, nil when there is none; `last-index-of` the last at
/// or before `from`. Indexes count code points, as `count` and `subs`
/// do (STDLIB.md §2).
fn fnStringIndexOf(vm: *VM, args: []const Value) VmError!Value {
    return stringSearch(vm, args, false);
}

fn fnStringLastIndexOf(vm: *VM, args: []const Value) VmError!Value {
    return stringSearch(vm, args, true);
}

fn stringSearch(vm: *VM, args: []const Value, last: bool) VmError!Value {
    _ = vm;
    const src = try stringArg(args[0]);
    var buf: [4]u8 = undefined;
    const needle = try needleBytes(args[1], &buf);
    const n = string_mod.codepointCount(args[0]) catch return VmError.Utf8Error;
    const from_arg: ?i64 = if (args.len == 3) try requireFixnum(args[2]) else null;
    // Java's lastIndexOf finds nothing before a negative index.
    if (last and from_arg != null and from_arg.? < 0) return value_mod.nilValue();
    const from: usize = if (from_arg) |f| @intCast(std.math.clamp(f, 0, @as(i64, @intCast(n)))) else if (last) n else 0;
    const at = string_mod.byteRangeForCodepoints(args[0], from, from) catch return VmError.Utf8Error;
    const byte_at: ?usize = if (last)
        std.mem.findLast(u8, src[0..@min(src.len, at.start + needle.len)], needle)
    else
        string_mod.indexOf(src, needle, at.start);
    const b = byte_at orelse return value_mod.nilValue();
    return value_mod.fromFixnum(@intCast(std.unicode.utf8CountCodepoints(src[0..b]) catch return VmError.Utf8Error)).?;
}

/// `(nexis.string/split s sep)` / `(nexis.string/split s sep limit)`
/// → a vector of the pieces of `s` between occurrences of the literal
/// `sep`, as Clojure's `split` with a regex that matches only `sep`:
/// trailing empty pieces are dropped; a positive `limit` splits at
/// most `limit - 1` times and keeps the rest whole; a negative one
/// keeps trailing empties. An empty `sep` splits between code points,
/// as `#""` does.
///   - Invalid UTF-8 in either string → :utf8-error
fn fnStringSplit(vm: *VM, args: []const Value) VmError!Value {
    const limit: i64 = if (args.len == 3) try requireFixnum(args[2]) else 0;
    // A pattern that is a literal of a byte or more splits as that
    // string does: `Pattern.split`'s one zero-width rule cannot apply.
    const literal: ?[]const u8 = if (args[1].kind() == .regex) regex_mod.programOf(args[1]).literal else null;
    if (args[1].kind() == .regex and (literal == null or literal.?.len == 0)) return splitPattern(vm, args[0], args[1], limit);
    if (args[0].kind() != .string or (literal == null and args[1].kind() != .string)) return VmError.KindMismatch;
    const src = string_mod.asBytes(args[0]);
    const sep = literal orelse string_mod.asBytes(args[1]);
    // A separator that is not UTF-8 could match the first byte of a
    // multibyte scalar and split inside it (STDLIB.md §3). Validated
    // once here, the pieces are made from their bytes as they are.
    if (!std.unicode.utf8ValidateSlice(src)) return VmError.Utf8Error;
    if (!std.unicode.utf8ValidateSlice(sep)) return VmError.Utf8Error;

    // The pieces are fresh strings nothing else reaches, gathered
    // before the vector is built; `Heap.alloc` never collects (VM.md §9).
    const heap = vm.ensureHeap();
    var pieces: std.ArrayList(Value) = .empty;
    defer pieces.deinit(vm.allocator);
    var start: usize = 0;
    var matches = string_mod.Matches.init(src, if (sep.len > 0) sep else " ", 0);
    while (limit <= 0 or pieces.items.len + 1 < limit) {
        // An empty separator matches after each code point but the
        // last, whose match ends the text.
        const at = if (sep.len > 0)
            matches.next() orelse break
        else if (start < src.len)
            start + (std.unicode.utf8ByteSequenceLength(src[start]) catch unreachable)
        else
            break;
        pieces.append(vm.allocator, string_mod.fromBytes(heap, src[start..at]) catch return VmError.OutOfMemory) catch return VmError.OutOfMemory;
        start = at + sep.len;
    }
    // The rest from the start is `s` itself, as `Pattern.split` returns it.
    const rest = if (start == 0) args[0] else string_mod.fromBytes(heap, src[start..]) catch return VmError.OutOfMemory;
    pieces.append(vm.allocator, rest) catch return VmError.OutOfMemory;
    if (limit == 0 and src.len > 0) {
        while (pieces.items.len > 0 and string_mod.byteLen(pieces.getLast()) == 0) _ = pieces.pop();
    }
    return vector_mod.fromSlice(heap, pieces.items) catch VmError.OutOfMemory;
}

/// `split` on a pattern: Java's `Pattern.split`. A match that is
/// empty at the start makes no leading piece; a positive `limit`
/// keeps at most `limit` pieces, the last the rest of `s`; 0 drops the
/// trailing empty pieces; no match at all is `[s]`.
fn splitPattern(vm: *VM, s: Value, re: Value, limit: i64) VmError!Value {
    const src = try utf8Arg(s);
    const prog = regex_mod.programOf(re);
    var rvm = regex_mod.Vm.init(vm.allocator, prog, false) catch return VmError.OutOfMemory;
    defer rvm.deinit(vm.allocator);
    var finder: regex_mod.Finder = .{ .vm = &rvm, .hay = src };
    const heap = vm.ensureHeap();
    // The pieces are fresh strings nothing else reaches, gathered
    // before the vector is built; `Heap.alloc` never collects.
    var pieces: std.ArrayList(Value) = .empty;
    defer pieces.deinit(vm.allocator);
    var index: usize = 0;
    var last = false;
    while (!last and finder.find()) {
        const span = rvm.group(0).?;
        if (index == 0 and span[0] == 0 and span[1] == 0) continue;
        last = limit > 0 and pieces.items.len + 1 == limit;
        const piece = if (last) src[index..] else src[index..span[0]];
        pieces.append(vm.allocator, string_mod.fromBytes(heap, piece) catch return VmError.OutOfMemory) catch return VmError.OutOfMemory;
        index = span[1];
    }
    if (index == 0) return vector_mod.fromSlice(heap, &.{s}) catch VmError.OutOfMemory;
    if (!last) pieces.append(vm.allocator, string_mod.fromBytes(heap, src[index..]) catch return VmError.OutOfMemory) catch return VmError.OutOfMemory;
    if (limit == 0) {
        while (pieces.items.len > 0 and string_mod.byteLen(pieces.getLast()) == 0) _ = pieces.pop();
    }
    return vector_mod.fromSlice(heap, pieces.items) catch VmError.OutOfMemory;
}

/// `replace` and `replace-first` on a pattern: Java's `replaceAll` and
/// `replaceFirst` with a replacement string (`$n`, `${name}`, `\x`;
/// docs/REGEX.md §11), or Clojure's `replace-by` with a function of
/// the match returning a string. `s` itself when nothing matches.
fn replacePattern(vm: *VM, s: Value, re: Value, replacement: Value, all: bool) VmError!Value {
    const src = try utf8Arg(s);
    const prog = regex_mod.programOf(re);
    const template = replacement.kind() == .string;
    if (template) _ = try utf8Arg(replacement);
    var rvm = regex_mod.Vm.init(vm.allocator, prog, prog.ngroups > 0) catch return VmError.OutOfMemory;
    defer rvm.deinit(vm.allocator);
    var finder: regex_mod.Finder = .{ .vm = &rvm, .hay = src };
    if (!finder.find()) return s;
    var arena: std.heap.ArenaAllocator = .init(vm.allocator);
    defer arena.deinit();
    // Parsed at the first match, as Java's `appendReplacement` reads
    // it: a replacement no match uses is never judged.
    const pieces: []const regex_mod.Piece = if (template) switch (regex_mod.parseReplacement(arena.allocator(), prog, string_mod.asBytes(replacement)) catch return VmError.OutOfMemory) {
        .ok => |p| p,
        .err => |message| return throwInvalidReplacement(vm, message),
    } else &.{};
    // The result grows in a Zig buffer, never as heap Values, so
    // nothing here is held across the function's call; the input, the
    // pattern and the function are this native's rooted arguments.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.allocator);
    var cursor: usize = 0;
    while (true) {
        const span = rvm.group(0).?;
        out.appendSlice(vm.allocator, src[cursor..span[0]]) catch return VmError.OutOfMemory;
        if (template) {
            for (pieces) |piece| switch (piece) {
                .text => |t| out.appendSlice(vm.allocator, t) catch return VmError.OutOfMemory,
                .group => |g| if (rvm.group(g)) |gs| out.appendSlice(vm.allocator, src[gs[0]..gs[1]]) catch return VmError.OutOfMemory,
            };
        } else {
            const match = try matchValue(vm, src, prog.ngroups, &rvm, vmGroup);
            const text = try vm.callValue(replacement, &.{match});
            if (text.kind() != .string) return VmError.KindMismatch;
            out.appendSlice(vm.allocator, string_mod.asBytes(text)) catch return VmError.OutOfMemory;
        }
        cursor = span[1];
        if (!all or !finder.find()) break;
    }
    out.appendSlice(vm.allocator, src[cursor..]) catch return VmError.OutOfMemory;
    return string_mod.fromBytes(vm.ensureHeap(), out.items) catch VmError.OutOfMemory;
}

/// Throw `{:error :invalid-replacement :message message}`.
fn throwInvalidReplacement(vm: *VM, message: []const u8) VmError {
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const kind = interner.internKeywordValue("invalid-replacement") catch return VmError.OutOfMemory;
    m = try mapPut(heap, m, interner.internKeywordValue("error") catch return VmError.OutOfMemory, kind);
    m = try mapPut(heap, m, interner.internKeywordValue("message") catch return VmError.OutOfMemory, string_mod.fromBytes(heap, message) catch return VmError.OutOfMemory);
    return vm.throwErrorMap(m);
}

/// `(nexis.string/re-quote-replacement s)` → `s` with `\` and `$`
/// escaped, so `replace` reads it literally (`Matcher.quoteReplacement`).
fn fnStringReQuoteReplacement(vm: *VM, args: []const Value) VmError!Value {
    const quoted = regex_mod.quoteReplacement(vm.allocator, try stringArg(args[0])) catch return VmError.OutOfMemory;
    defer vm.allocator.free(quoted);
    return string_mod.fromBytes(vm.ensureHeap(), quoted) catch VmError.OutOfMemory;
}

/// `(nexis.string/replace-first s match replacement)` → `s` with its
/// first match replaced, else `s` itself: a pattern as `replace` takes
/// one, or a string or char `match` and a string or char replacement,
/// an empty `match` found at the start.
fn fnStringReplaceFirst(vm: *VM, args: []const Value) VmError!Value {
    if (args[1].kind() == .regex) return replacePattern(vm, args[0], args[1], args[2], false);
    const src = try utf8Arg(args[0]);
    var match_buf: [4]u8 = undefined;
    var replacement_buf: [4]u8 = undefined;
    const m = try needleBytes(args[1], &match_buf);
    const r = try needleBytes(args[2], &replacement_buf);
    if (!std.unicode.utf8ValidateSlice(m) or !std.unicode.utf8ValidateSlice(r)) return VmError.Utf8Error;
    const i = string_mod.indexOf(src, m, 0) orelse return args[0];
    const out = string_mod.allocUninit(vm.ensureHeap(), src.len - m.len + r.len) catch return VmError.OutOfMemory;
    @memcpy(out.bytes[0..i], src[0..i]);
    @memcpy(out.bytes[i..][0..r.len], r);
    @memcpy(out.bytes[i + r.len ..], src[i + m.len ..]);
    return out.value;
}

/// `(nexis.string/join coll)` / `(nexis.string/join sep coll)` → the
/// elements of any seqable as `str` makes them text (nil is empty),
/// separated by `sep`. `coll` is consumed: a lazy seq is walked once,
/// its text written as the walk hands out each element, so the
/// realized seq behind the walk is garbage while the text grows.
fn fnStringJoin(vm: *VM, args: []const Value) VmError!Value {
    const sep: []const u8 = if (args.len == 2) blk: {
        if (args[0].kind() != .string) return VmError.KindMismatch;
        break :blk string_mod.asBytes(args[0]);
    } else "";
    const coll = args[args.len - 1];
    if (!walksLazily(coll)) if (try joinPlain(vm, sep, coll)) |joined| return joined;
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    // Making an element text may run code (a lazy seq's printing
    // realizes it), which may collect.
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, coll, scope);
    var first = true;
    while (try it.next()) |x| {
        if (!first) w.writer.writeAll(sep) catch return VmError.OutOfMemory;
        first = false;
        if (x.kind() == .string) {
            w.writer.writeAll(string_mod.asBytes(x)) catch return VmError.OutOfMemory;
        } else try appendStrValue(vm, &w, x);
    }
    return string_mod.fromBytes(vm.ensureHeap(), w.written()) catch VmError.OutOfMemory;
}

/// `join` of a collection whose elements are all nil, strings, chars
/// or fixnums: measured in one walk, written in a second into a
/// string of that length. Null at the first element that is not, for
/// the printer's path. `coll` is no lazy seq whose walk runs code
/// (`walksLazily`), so nothing collects.
fn joinPlain(vm: *VM, sep: []const u8, coll: Value) VmError!?Value {
    var len: usize = 0;
    var n: usize = 0;
    var it = try makeSeqIter(vm, coll);
    while (try it.next()) |x| : (n += 1) len += plainStrLen(x) orelse return null;
    if (n > 1) len += sep.len * (n - 1);
    const out = string_mod.allocUninit(vm.ensureHeap(), len) catch return VmError.OutOfMemory;
    var rest = out.bytes;
    it = try makeSeqIter(vm, coll);
    var first = true;
    while (try it.next()) |x| {
        if (!first) {
            @memcpy(rest[0..sep.len], sep);
            rest = rest[sep.len..];
        }
        first = false;
        rest = writePlainStr(x, rest);
    }
    return out.value;
}

/// `(nexis.string/replace s match replacement)` — literal,
/// all-non-overlapping, left-to-right; `match` and `replacement` are
/// both strings or both chars. An empty `match` matches before every
/// code point and at the end, as Java's `String.replace`.
///   - Invalid UTF-8 in any arg → :utf8-error
/// After each match, cursor advances by `match.len` so
/// `(replace "aaa" "aa" "x") → "xa"`.
fn fnStringReplace(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    const match = args[1];
    const replacement = args[2];
    if (match.kind() == .regex) return replacePattern(vm, s, match, replacement, true);
    const pair: Kind = if (match.kind() == .char) .char else .string;
    if (s.kind() != .string or match.kind() != pair or replacement.kind() != pair) return VmError.KindMismatch;
    const src = string_mod.asBytes(s);
    var match_buf: [4]u8 = undefined;
    var replacement_buf: [4]u8 = undefined;
    const m = try needleBytes(match, &match_buf);
    const r = try needleBytes(replacement, &replacement_buf);
    // Validate all three byte slices as UTF-8 before scanning.
    // Same rationale
    // as fnStringSplit — keep `nexis.string/*` semantically a
    // Unicode-string operation rather than a raw-byte one.
    if (!std.unicode.utf8ValidateSlice(src)) return VmError.Utf8Error;
    if (!std.unicode.utf8ValidateSlice(m)) return VmError.Utf8Error;
    if (!std.unicode.utf8ValidateSlice(r)) return VmError.Utf8Error;

    // Measured first, so the result is written once into a string of
    // its length.
    const heap = vm.ensureHeap();
    if (m.len == 0) {
        const n = std.unicode.utf8CountCodepoints(src) catch unreachable;
        const out = string_mod.allocUninit(heap, src.len + r.len * (n + 1)) catch return VmError.OutOfMemory;
        var at: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(src).iterator();
        while (it.nextCodepointSlice()) |c| {
            @memcpy(out.bytes[at..][0..r.len], r);
            @memcpy(out.bytes[at + r.len ..][0..c.len], c);
            at += r.len + c.len;
        }
        @memcpy(out.bytes[at..], r);
        return out.value;
    }
    const k = string_mod.countMatches(src, m);
    if (k == 0) return s;
    const out = string_mod.allocUninit(heap, src.len - k * m.len + k * r.len) catch return VmError.OutOfMemory;
    var at: usize = 0;
    var cursor: usize = 0;
    var matches = string_mod.Matches.init(src, m, 0);
    while (matches.next()) |i| {
        @memcpy(out.bytes[at..][0 .. i - cursor], src[cursor..i]);
        at += i - cursor;
        @memcpy(out.bytes[at..][0..r.len], r);
        at += r.len;
        cursor = i + m.len;
    }
    @memcpy(out.bytes[at..], src[cursor..]);
    return out.value;
}

// =============================================================================
// Printing + I/O
// =============================================================================
//
// `print` / `println` / `pr` / `prn` write to the innermost
// `with-out-str` buffer, or to stdout through `vm.io` (`:io-error`
// when the host gave the VM none); `pr-str` returns a string. The
// arguments are separated by one space, as in Clojure; `println` and
// `prn` end with a newline. `print`/`println` write display form
// (`nil`, strings without quotes), `pr`/`prn`/`pr-str` readable form.

/// The `with-out-str` buffers in force, innermost last. One isolate,
/// one thread. The stack and its buffers live on `out_allocator`,
/// which outlives every VM: a macro's sub-VM, whose allocator dies
/// with it, prints into a buffer its caller opened.
var out_stack: std.ArrayList(std.ArrayList(u8)) = .empty;
const out_allocator = std.heap.smp_allocator;

/// Close every `with-out-str` buffer still open, dropping what was
/// printed into it: the host calls it where an error no handler can
/// take (out of memory) ends a run, which skips the `#%pop-out` in
/// `with-out-str`'s handler, so output after it is not swallowed.
pub fn discardOutCaptures() void {
    for (out_stack.items) |*buf| buf.deinit(out_allocator);
    out_stack.clearAndFree(out_allocator);
}

/// A reader that closed stdout has all it wants: the program ends
/// there, quietly and successfully, its stores synced, as the CLI's
/// own output does (TOOLING.md §1).
fn writeOut(vm: *VM, bytes: []const u8) VmError!void {
    if (out_stack.lastPtr()) |top| return top.appendSlice(out_allocator, bytes) catch VmError.OutOfMemory;
    const io_handle = vm.io orelse return VmError.IoError;
    std.Io.File.stdout().writeStreamingAll(io_handle, bytes) catch |err| switch (err) {
        error.BrokenPipe => {
            db_mod.StoreFile.syncAll();
            std.process.exit(0);
        },
        else => return VmError.IoError,
    };
}

/// `args` formatted in `mode`, separated by spaces, into `w`. The
/// writer is an Allocating buffer, so a failed write is an allocation
/// failure.
fn formatArgs(vm: *VM, w: *std.Io.Writer.Allocating, args: []const Value, mode: format_mod.FormatMode) VmError!void {
    const interner = vm.ensureInterner();
    // The printer runs no code: every lazy seq is realized first, in
    // native context (docs/LAZY.md §8).
    for (args) |x| try seq_mod.realizeAll(vm, x);
    for (args, 0..) |x, i| {
        if (i > 0) w.writer.writeAll(" ") catch return VmError.OutOfMemory;
        format_mod.format(x, mode, &w.writer, interner) catch |err| switch (err) {
            error.Utf8Error => return VmError.Utf8Error,
            error.WriteFailed => return VmError.OutOfMemory,
        };
    }
}

fn printArgs(vm: *VM, args: []const Value, mode: format_mod.FormatMode, newline: bool) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    try formatArgs(vm, &w, args, mode);
    if (newline) w.writer.writeAll("\n") catch return VmError.OutOfMemory;
    try writeOut(vm, w.written());
    return value_mod.nilValue();
}

fn fnPrint(vm: *VM, args: []const Value) VmError!Value {
    return printArgs(vm, args, .display, false);
}

fn fnPrintln(vm: *VM, args: []const Value) VmError!Value {
    return printArgs(vm, args, .display, true);
}

fn fnPr(vm: *VM, args: []const Value) VmError!Value {
    return printArgs(vm, args, .readable, false);
}

fn fnPrn(vm: *VM, args: []const Value) VmError!Value {
    return printArgs(vm, args, .readable, true);
}

fn fnPrStr(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    try formatArgs(vm, &w, args, .readable);
    return string_mod.fromBytes(vm.ensureHeap(), w.written()) catch return VmError.OutOfMemory;
}

/// `(#%push-out)` opens a `with-out-str` buffer; `(#%pop-out)` closes
/// the innermost one and returns what was printed into it.
fn fnPushOut(_: *VM, _: []const Value) VmError!Value {
    out_stack.append(out_allocator, .empty) catch return VmError.OutOfMemory;
    return value_mod.nilValue();
}

fn fnPopOut(vm: *VM, _: []const Value) VmError!Value {
    var buf = out_stack.pop() orelse return VmError.InvalidArgument;
    defer buf.deinit(out_allocator);
    if (out_stack.items.len == 0) out_stack.clearAndFree(out_allocator);
    return string_mod.fromBytes(vm.ensureHeap(), buf.items) catch VmError.OutOfMemory;
}

/// `(bound? & vs)` → whether every Var has a value, its root or a
/// binding in force, as Clojure's `Var.isBound`.
fn fnBoundQ(_: *VM, args: []const Value) VmError!Value {
    for (args) |v| {
        if (v.kind() != .var_) return VmError.KindMismatch;
        if (VM.asVar(v).current() == null) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

/// `(nano-time)` → a monotonic clock in nanoseconds, for measuring
/// intervals (Java's `System/nanoTime`).
fn fnNanoTime(vm: *VM, _: []const Value) VmError!Value {
    const now = std.Io.Clock.awake.now(ioOf(vm));
    return value_mod.fromFixnum(@intCast(@mod(now.nanoseconds, value_mod.fixnum_max))) orelse VmError.ArithmeticOverflow;
}

/// `(slurp path)` → the file's text. `:file-not-found` for a missing
/// file, `:utf8-error` for text that is not UTF-8, `:io-error` for
/// any other failure.
fn fnSlurp(vm: *VM, args: []const Value) VmError!Value {
    const path = try vm_mod.pathArg(args[0]);
    const slice = std.Io.Dir.cwd().readFileAlloc(ioOf(vm), path, vm.allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return VmError.FileNotFound,
        error.OutOfMemory => return VmError.OutOfMemory,
        else => return VmError.IoError,
    };
    defer vm.allocator.free(slice);
    if (!std.unicode.utf8ValidateSlice(slice)) return VmError.Utf8Error;
    return string_mod.fromBytes(vm.ensureHeap(), slice) catch return VmError.OutOfMemory;
}

/// `(spit path content)` / `(spit path content :append true)` →
/// writes `(str content)` to the file, replacing it, or after its
/// end with `:append`; nil. Parent directories are not created
/// (`:file-not-found`).
fn fnSpit(vm: *VM, args: []const Value) VmError!Value {
    const path = try vm_mod.pathArg(args[0]);
    if (args.len % 2 != 0) return VmError.ArityMismatch;
    var append = false;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (args[i].kind() != .keyword or !std.mem.eql(u8, vm.ensureInterner().keywordName(args[i].asKeywordId()), "append")) return VmError.InvalidArgument;
        append = args[i + 1].isTruthy();
    }
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    try appendStrValue(vm, &w, args[1]);
    const io = ioOf(vm);
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = !append }) catch |err| switch (err) {
        error.FileNotFound => return VmError.FileNotFound,
        else => return VmError.IoError,
    };
    defer file.close(io);
    const at = if (append) file.length(io) catch return VmError.IoError else 0;
    file.writePositionalAll(io, w.written(), at) catch return VmError.IoError;
    return value_mod.nilValue();
}

/// The process's stdin, read through one buffer: the REPL's input
/// and `read-line` share it, so neither loses what the other
/// buffered. A line longer than the buffer is gathered in
/// `stdin_long_line`. One isolate, one thread.
var stdin_buf: [64 * 1024]u8 = undefined;
var stdin_reader: ?std.Io.File.Reader = null;
var stdin_long_line: std.ArrayList(u8) = .empty;

/// The next line of stdin without its newline, null at end of input;
/// valid until the next read.
pub fn readStdinLine(io: std.Io) error{ ReadFailed, OutOfMemory }!?[]const u8 {
    if (stdin_reader == null) stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    return readLine(&stdin_reader.?.interface, &stdin_long_line, std.heap.page_allocator);
}

/// The next line of `r` without its newline or a trailing `\r`, null
/// at end of input; valid until the next read. A line longer than
/// `r`'s buffer is gathered in `overflow`, allocated from `gpa`.
fn readLine(r: *std.Io.Reader, overflow: *std.ArrayList(u8), gpa: std.mem.Allocator) error{ ReadFailed, OutOfMemory }!?[]const u8 {
    const line = r.takeDelimiter('\n') catch |err| switch (err) {
        error.ReadFailed => return error.ReadFailed,
        error.StreamTooLong => long: {
            overflow.clearRetainingCapacity();
            var w: std.Io.Writer.Allocating = .fromArrayList(gpa, overflow);
            const streamed = r.streamDelimiterEnding(&w.writer, '\n');
            overflow.* = w.toArrayList();
            _ = streamed catch |e| return switch (e) {
                error.ReadFailed => error.ReadFailed,
                error.WriteFailed => error.OutOfMemory,
            };
            // The newline, unless the input ended first.
            if (r.bufferedLen() > 0) r.toss(1);
            break :long overflow.items;
        },
    } orelse return null;
    return std.mem.trimEnd(u8, line, "\r");
}

/// `(read-line)` → the next line of stdin as a string, nil at end
/// of input.
fn fnReadLine(vm: *VM, _: []const Value) VmError!Value {
    // A wait on stdin is a wait like the REPL's: no read snapshot is
    // held across it (DB.md §3.4).
    db_mod.StoreFile.dropAllHeld();
    const line = (readStdinLine(vm.io orelse return VmError.IoError) catch |err| return switch (err) {
        error.OutOfMemory => VmError.OutOfMemory,
        error.ReadFailed => VmError.IoError,
    }) orelse return value_mod.nilValue();
    return string_mod.fromBytes(vm.ensureHeap(), line) catch VmError.OutOfMemory;
}

/// `(exit)` / `(exit status)` → ends the process with `status` (0 by
/// default) after closing every store the program opened, through
/// `db/open` or `nextomic/connect`, and syncing every file a commit
/// left unsynced; nothing after it runs, `finally` blocks included, as
/// with Java's `System/exit`.
fn fnExit(vm: *VM, args: []const Value) VmError!Value {
    const status: u8 = if (args.len == 0) 0 else @truncate(@as(u64, @bitCast(try requireFixnum(args[0]))));
    const host = vm.home();
    for (host.db_connections.items) |conn| db_mod.shutdown(@ptrCast(@alignCast(conn)));
    if (host.nextomic_close_callback) |close| for (host.nextomic_connections.items) |conn| close(conn);
    db_mod.StoreFile.syncAll();
    std.process.exit(status);
}

// =============================================================================
// The process's environment (nexis.sys, STDLIB.md §11)
// =============================================================================
//
// Every native here reads its arguments, allocates its result last and
// never calls back into the VM (GC.md §11.5, class 1).

/// `bytes` as a string, each byte that starts no well-formed UTF-8
/// sequence read as U+FFFD, as Java decodes text it did not make: an
/// environment variable or a process's output is any bytes.
fn lossyString(vm: *VM, bytes: []const u8) VmError!Value {
    const heap = vm.ensureHeap();
    if (std.unicode.utf8ValidateSlice(bytes)) return string_mod.fromBytes(heap, bytes) catch VmError.OutOfMemory;
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    var i: usize = 0;
    while (i < bytes.len) {
        const n: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        const ok = n > 0 and i + n <= bytes.len and if (std.unicode.utf8Decode(bytes[i..][0..n])) |_| true else |_| false;
        w.writer.writeAll(if (ok) bytes[i..][0..n] else "\u{FFFD}") catch return VmError.OutOfMemory;
        i += if (ok) n else 1;
    }
    return string_mod.fromBytes(heap, w.written()) catch VmError.OutOfMemory;
}

/// `(#%getenv)` → every variable of the process's environment as a map
/// of name to value; `(#%getenv name)` → the value of one, nil when it
/// is not set. libc's environment, which the runtime never changes.
fn fnGetenv(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) {
        if (args[0].kind() != .string) return VmError.KindMismatch;
        const name = string_mod.asBytes(args[0]);
        if (name.len == 0 or std.mem.findScalar(u8, name, 0) != null) return value_mod.nilValue();
        const name_z = vm.allocator.dupeSentinel(u8, name, 0) catch return VmError.OutOfMemory;
        defer vm.allocator.free(name_z);
        const v = std.c.getenv(name_z.ptr) orelse return value_mod.nilValue();
        return lossyString(vm, std.mem.span(v));
    }
    var m = champ_mod.mapEmpty(vm.ensureHeap()) catch return VmError.OutOfMemory;
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const text = std.mem.span(entry);
        const eq = std.mem.findScalar(u8, text, '=') orelse continue;
        m = try mapPut(vm.ensureHeap(), m, try lossyString(vm, text[0..eq]), try lossyString(vm, text[eq + 1 ..]));
    }
    return m;
}

/// `(#%cwd)` → the absolute path of the working directory.
fn fnCwd(vm: *VM, _: []const Value) VmError!Value {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = std.process.currentPath(ioOf(vm), &buf) catch return VmError.IoError;
    return lossyString(vm, buf[0..n]);
}

/// `(#%sh argv opts)` → `{:exit status :out text :err text}`: runs the
/// program `argv` names (its first string, found on the PATH as the
/// shell finds it) with the rest as its arguments, and waits for it.
/// `opts` maps `:in` to the text written to its stdin (nil: none, the
/// child reads end of input at once), `:dir` to its working directory
/// and `:env` to the whole of its environment, each nil for the
/// process's own. One thread feeds stdin and drains stdout and stderr
/// together, so neither side waits on a full pipe. A VM with no `io`
/// spawns nothing (`:io-error`).
fn fnSh(vm: *VM, args: []const Value) VmError!Value {
    const io = vm.io orelse return VmError.IoError;
    var arena_state = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const interner = vm.ensureInterner();

    if (args[0].kind() != .persistent_vector) return VmError.KindMismatch;
    const argc = vector_mod.count(args[0]);
    if (argc == 0) return vm.fail(VmError.InvalidArgument, "sh: no command to run", .{});
    const argv = arena.alloc([]const u8, argc) catch return VmError.OutOfMemory;
    for (argv, 0..) |*a, i| {
        const s = vector_mod.nth(args[0], i);
        if (s.kind() != .string) return VmError.KindMismatch;
        a.* = string_mod.asBytes(s);
        if (std.mem.findScalar(u8, a.*, 0) != null) return vm.fail(VmError.InvalidArgument, "sh: an argument holds a NUL byte", .{});
    }

    var input: ?[]const u8 = null;
    var cwd: std.process.Child.Cwd = .inherit;
    var env: ?std.process.Environ.Map = null;
    if (!args[1].isNil()) {
        if (args[1].kind() != .persistent_map) return VmError.KindMismatch;
        var it = champ_mod.mapIter(args[1]);
        while (it.next()) |e| {
            const name = if (e.key.kind() == .keyword) interner.keywordName(e.key.asKeywordId()) else "";
            if (std.mem.eql(u8, name, "in")) {
                if (e.value.isNil()) continue;
                if (e.value.kind() != .string) return VmError.KindMismatch;
                input = string_mod.asBytes(e.value);
            } else if (std.mem.eql(u8, name, "dir")) {
                if (!e.value.isNil()) cwd = .{ .path = try vm_mod.pathArg(e.value) };
            } else if (std.mem.eql(u8, name, "env")) {
                if (e.value.isNil()) continue;
                if (!isMap(e.value.kind())) return VmError.KindMismatch;
                env = try shEnviron(vm, arena, e.value);
            } else return vm.fail(VmError.InvalidArgument, "sh: no option {s}", .{name});
        }
    }

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = if (env) |*m| m else null,
        .stdin = if (input != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| return switch (err) {
        error.OutOfMemory => VmError.OutOfMemory,
        error.FileNotFound => vm.fail(VmError.FileNotFound, "sh: cannot run {s}", .{argv[0]}),
        else => vm.fail(VmError.IoError, "sh: cannot run {s}: {t}", .{ argv[0], err }),
    };
    defer child.kill(io);

    var out: [2]std.ArrayList(u8) = .{ .empty, .empty };
    defer for (&out) |*o| o.deinit(vm.allocator);
    try shExchange(vm, io, &child, input orelse "", &out);
    const term = child.wait(io) catch return VmError.IoError;
    const status: i64 = switch (term) {
        .exited => |code| code,
        .signal, .stopped => |sig| 128 + @as(i64, @backingInt(sig)),
        .unknown => |code| code,
    };

    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const fields = [_]struct { []const u8, Value }{
        .{ "exit", value_mod.fromFixnum(status) orelse return VmError.ArithmeticOverflow },
        .{ "out", try lossyString(vm, out[0].items) },
        .{ "err", try lossyString(vm, out[1].items) },
    };
    for (fields) |f| m = try mapPut(heap, m, interner.internKeywordValue(f[0]) catch return VmError.OutOfMemory, f[1]);
    return m;
}

/// The environment `:env` gives a command: each key's name (a string
/// as it is, a keyword or symbol by `name`) bound to its value's
/// `str`, as Clojure's `as-env-strings` makes it.
fn shEnviron(vm: *VM, arena: std.mem.Allocator, map: Value) VmError!std.process.Environ.Map {
    var env = std.process.Environ.Map.init(arena);
    // Each entry lies in the map, reachable from it across the call
    // back into the VM that realizing a value can make.
    var it = MapEntries.of(map).?;
    while (it.next()) |entry| {
        const key = entry.key;
        const name = if (key.kind() == .string) string_mod.asBytes(key) else intern_mod.Interner.splitQualified(try internedName(vm, key)).name;
        var w = std.Io.Writer.Allocating.init(arena);
        try appendStrValue(vm, &w, entry.value);
        if (!std.process.Environ.Map.validateKeyForPut(name) or std.mem.findScalar(u8, w.written(), 0) != null)
            return vm.fail(VmError.InvalidArgument, "sh: no environment variable can be named {s}", .{name});
        env.put(name, w.written()) catch return VmError.OutOfMemory;
    }
    return env;
}

/// Write `input` to the child's stdin while reading its stdout and
/// stderr into `out`, until both reach their end. A write never
/// exceeds the 512 bytes POSIX guarantees a pipe that polls writable
/// takes at once, so it never blocks; a child that closes its stdin
/// early leaves the rest of `input` unwritten.
fn shExchange(vm: *VM, io: std.Io, child: *std.process.Child, input: []const u8, out: *[2]std.ArrayList(u8)) VmError!void {
    var storage: [3]std.Io.Operation.Storage = undefined;
    var batch = std.Io.Batch.init(&storage);
    defer batch.cancel(io);
    var bufs: [2][16 * 1024]u8 = undefined;
    var read_vecs: [2][1][]u8 = .{ .{&bufs[0]}, .{&bufs[1]} };
    const files = [2]std.Io.File{ child.stdout.?, child.stderr.? };
    for (0..2) |i| batch.addAt(@intCast(i), .{ .file_read_streaming = .{ .file = files[i], .data = &read_vecs[i] } });
    var rest = input;
    var write_vec: [1][]const u8 = undefined;
    var open: usize = 2;
    if (child.stdin) |stdin| {
        if (rest.len == 0) {
            stdin.close(io);
            child.stdin = null;
        } else {
            write_vec[0] = rest[0..@min(rest.len, 512)];
            batch.addAt(2, .{ .file_write_streaming = .{ .file = stdin, .data = &write_vec } });
            open += 1;
        }
    }
    while (open > 0) {
        batch.awaitConcurrent(io, .none) catch return VmError.IoError;
        while (batch.next()) |done| switch (done.index) {
            0, 1 => {
                const i = done.index;
                const n = done.result.file_read_streaming catch |err| switch (err) {
                    error.EndOfStream => {
                        open -= 1;
                        continue;
                    },
                    else => return VmError.IoError,
                };
                out[i].appendSlice(vm.allocator, bufs[i][0..n]) catch return VmError.OutOfMemory;
                batch.addAt(i, .{ .file_read_streaming = .{ .file = files[i], .data = &read_vecs[i] } });
            },
            else => {
                const n = done.result.file_write_streaming catch |err| switch (err) {
                    error.BrokenPipe => rest.len,
                    else => return VmError.IoError,
                };
                rest = rest[n..];
                if (rest.len == 0) {
                    child.stdin.?.close(io);
                    child.stdin = null;
                    open -= 1;
                    continue;
                }
                write_vec[0] = rest[0..@min(rest.len, 512)];
                batch.addAt(2, .{ .file_write_streaming = .{ .file = child.stdin.?, .data = &write_vec } });
            },
        };
    }
}

// =============================================================================
// Instants (nexis.time, STDLIB.md §12)
// =============================================================================
//
// An instant is a count of milliseconds since 1970-01-01T00:00:00Z on
// the proleptic Gregorian calendar, as Nextomic's `:db.type/instant`
// values are; these natives turn one into ISO-8601 text and back.

const ms_per_day = 86_400_000;

/// The days from 1970-01-01 to the date `year-month-day` (Hinnant's
/// `days_from_civil`, exact for every year).
fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// The date `days` after 1970-01-01 (`civil_from_days`).
fn civilFromDays(days: i64) Civil {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = yoe + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1),
    };
}

fn daysInMonth(year: i64, month: u32) u32 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

/// The instant `ms` as Java's `Instant.toString` writes it, to the
/// millisecond: `2026-10-09T12:30:15.123Z`, the fraction left out when
/// it is zero, a year before 1 with a `-` and one past 9999 with a `+`.
fn writeInstant(w: *std.Io.Writer, ms: i64) std.Io.Writer.Error!void {
    const in_day: u64 = @intCast(@mod(ms, ms_per_day));
    const date = civilFromDays(@divFloor(ms, ms_per_day));
    if (date.year < 0) try w.writeByte('-') else if (date.year > 9999) try w.writeByte('+');
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @abs(date.year), date.month, date.day, in_day / 3_600_000, in_day / 60_000 % 60, in_day / 1000 % 60 });
    if (in_day % 1000 != 0) try w.print(".{d:0>3}", .{in_day % 1000});
    try w.writeByte('Z');
}

/// The instant the ISO-8601 text `s` names, in epoch milliseconds, or
/// null when `s` is not one. The grammar is Clojure's `#inst`, which
/// RFC 3339 is a part of: `[+-]YYYY`, then optionally `-MM`, `-DD`,
/// `THH:MM`, `:SS` and a fraction of 1 to 9 digits (truncated to the
/// millisecond), each only after the one before; then `Z`, an offset
/// `+HH:MM` (or `+HHMM`), or nothing, which is UTC. `T` and `Z` may be
/// lower case.
fn parseInstant(s: []const u8) ?i64 {
    const Scan = struct {
        s: []const u8,
        i: usize = 0,

        fn eat(p: *@This(), set: []const u8) bool {
            if (p.i >= p.s.len or std.mem.findScalar(u8, set, p.s[p.i]) == null) return false;
            p.i += 1;
            return true;
        }

        fn digits(p: *@This(), n: usize) ?u32 {
            if (p.s.len - p.i < n) return null;
            var v: u32 = 0;
            for (p.s[p.i..][0..n]) |c| {
                if (!std.ascii.isDigit(c)) return null;
                v = v * 10 + (c - '0');
            }
            p.i += n;
            return v;
        }
    };
    var p: Scan = .{ .s = s };
    const negative = p.eat("-");
    if (!negative) _ = p.eat("+");
    const year: i64 = @as(i64, p.digits(4) orelse return null) * @as(i64, if (negative) -1 else 1);
    var month: u32 = 1;
    var day: u32 = 1;
    var hour: u32 = 0;
    var minute: u32 = 0;
    var second: u32 = 0;
    var milli: u32 = 0;
    if (p.eat("-")) {
        month = p.digits(2) orelse return null;
        if (p.eat("-")) {
            day = p.digits(2) orelse return null;
            if (p.eat("Tt")) {
                hour = p.digits(2) orelse return null;
                if (!p.eat(":")) return null;
                minute = p.digits(2) orelse return null;
                if (p.eat(":")) {
                    second = p.digits(2) orelse return null;
                    if (p.eat(".")) {
                        const start = p.i;
                        while (p.i < s.len and std.ascii.isDigit(s[p.i])) p.i += 1;
                        const n = p.i - start;
                        if (n == 0 or n > 9) return null;
                        for (0..3) |k| milli = milli * 10 + if (k < n) s[start + k] - '0' else 0;
                    }
                }
            }
        }
    }
    var offset: i64 = 0;
    if (!p.eat("Zz") and p.i < s.len and (s[p.i] == '+' or s[p.i] == '-')) {
        const sign: i64 = if (s[p.i] == '-') -1 else 1;
        p.i += 1;
        const oh = p.digits(2) orelse return null;
        _ = p.eat(":");
        const om = p.digits(2) orelse return null;
        if (oh > 23 or om > 59) return null;
        offset = sign * (oh * 60 + om);
    }
    if (p.i != s.len) return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;
    const seconds = (@as(i64, hour) * 60 + minute - offset) * 60 + second;
    return daysFromCivil(year, month, day) * ms_per_day + seconds * 1000 + milli;
}

/// `(#%now-ms)` → the wall clock in epoch milliseconds.
fn fnNowMs(vm: *VM, _: []const Value) VmError!Value {
    const now = std.Io.Clock.real.now(ioOf(vm));
    return value_mod.fromFixnum(@intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms))) orelse VmError.ArithmeticOverflow;
}

/// `(#%format-instant ms)` → the ISO-8601 text of the instant `ms`.
fn fnFormatInstant(vm: *VM, args: []const Value) VmError!Value {
    var buf: [40]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeInstant(&w, try requireFixnum(args[0])) catch unreachable;
    return string_mod.fromBytes(vm.ensureHeap(), w.buffered()) catch VmError.OutOfMemory;
}

/// `(#%parse-instant s)` → the instant the ISO-8601 text `s` names, in
/// epoch milliseconds; `:invalid-argument` for any other text, or an
/// instant past the fixnum range (-2490-03-17 to 6429-10-17).
fn fnParseInstant(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const s = string_mod.asBytes(args[0]);
    const ms = parseInstant(s) orelse return vm.fail(VmError.InvalidArgument, "not an ISO-8601 instant: \"{s}\"", .{s});
    return value_mod.fromFixnum(ms) orelse vm.fail(VmError.InvalidArgument, "an instant past the fixnum range: \"{s}\"", .{s});
}

// =============================================================================
// JSON (nexis.json, STDLIB.md §13)
// =============================================================================

/// The options map of a JSON native: the value of each keyword of
/// `names` (nil when absent; a nil map is no options). Any other key
/// is `:invalid-argument`.
fn jsonOptions(vm: *VM, opts: Value, comptime names: []const []const u8) VmError![names.len]Value {
    var out: [names.len]Value = @splat(value_mod.nilValue());
    if (opts.isNil()) return out;
    if (opts.kind() != .persistent_map) return VmError.KindMismatch;
    const interner = vm.ensureInterner();
    var it = champ_mod.mapIter(opts);
    next: while (it.next()) |e| {
        if (e.key.kind() == .keyword) {
            const name = interner.keywordName(e.key.asKeywordId());
            for (names, 0..) |n, i| if (std.mem.eql(u8, name, n)) {
                out[i] = e.value;
                continue :next;
            };
        }
        const accepted = comptime blk: {
            var text: []const u8 = "";
            for (names, 0..) |n, i| text = text ++ (if (i > 0) ", :" else ":") ++ n;
            break :blk text;
        };
        return vm.fail(VmError.InvalidArgument, "JSON: an option other than " ++ accepted, .{});
    }
    return out;
}

/// Throw `{:error :json-error :message message}`, with `:line` and
/// `:column` when `at` is a position in the text read, as the
/// multimethod errors are maps (§9.4); `catch :json-error` takes it.
fn throwJson(vm: *VM, message: []const u8, at: ?struct { line: i64, column: i64 }) VmError {
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const kw = struct {
        fn of(i: *intern_mod.Interner, name: []const u8) VmError!Value {
            return i.internKeywordValue(name) catch VmError.OutOfMemory;
        }
    }.of;
    m = try mapPut(heap, m, try kw(interner, "error"), try kw(interner, "json-error"));
    m = try mapPut(heap, m, try kw(interner, "message"), string_mod.fromBytes(heap, message) catch return VmError.OutOfMemory);
    if (at) |pos| {
        m = try mapPut(heap, m, try kw(interner, "line"), try integerValue(vm, pos.line));
        m = try mapPut(heap, m, try kw(interner, "column"), try integerValue(vm, pos.column));
    }
    return vm.throwValue(m);
}

/// `throwJson` of `JSON: <what> at line L, column C` for the byte `at`
/// of `text`, the column counted in characters.
fn jsonSyntaxError(vm: *VM, text: []const u8, at: usize, comptime what: []const u8, args: anytype) VmError {
    var line: i64 = 1;
    var line_start: usize = 0;
    for (text[0..at], 0..) |c, k| if (c == '\n') {
        line += 1;
        line_start = k + 1;
    };
    const column: i64 = @intCast((std.unicode.utf8CountCodepoints(text[line_start..at]) catch at - line_start) + 1);
    var buf: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "JSON: " ++ what ++ " at line {d}, column {d}", args ++ .{ line, column }) catch &buf;
    return throwJson(vm, message, .{ .line = line, .column = column });
}

/// Whether `f` is `nexis.core/keyword`, which `:key-fn` names to read
/// keys as keywords: the reader interns them itself, with no call and
/// no string made.
fn isKeywordFn(f: Value) bool {
    return f.kind() == .native_fn and vm_mod.asNativeFn(f).call == &fnKeyword;
}

/// A JSON text read into values, without recursion: every value read
/// waits on the root stack until the array or object it is in closes,
/// and is then built into that collection, so the text may nest as
/// deep as memory allows and every value is rooted across the calls
/// `:key-fn` and `:value-fn` make.
const JsonReader = struct {
    vm: *VM,
    heap: *heap_mod.Heap,
    s: []const u8,
    i: usize = 0,
    scope: vm_mod.RootScope,
    key_fn: Value,
    value_fn: Value,
    /// The arrays and objects open, innermost last.
    open: std.ArrayList(Open) = .empty,
    /// A string's bytes once it holds an escape.
    scratch: std.ArrayList(u8) = .empty,

    /// An open collection: its first slot on the root stack, and
    /// whether it is an object, whose slots alternate key and value.
    const Open = struct { base: usize, object: bool };

    fn deinit(r: *JsonReader) void {
        r.open.deinit(r.vm.allocator);
        r.scratch.deinit(r.vm.allocator);
    }

    fn fail(r: *JsonReader, at: usize, comptime what: []const u8, args: anytype) VmError {
        return jsonSyntaxError(r.vm, r.s, at, what, args);
    }

    fn unexpected(r: *JsonReader) VmError {
        const n: usize = std.unicode.utf8ByteSequenceLength(r.s[r.i]) catch 1;
        return r.fail(r.i, "unexpected '{s}'", .{r.s[r.i..][0..@min(n, r.s.len - r.i)]});
    }

    fn skipSpace(r: *JsonReader) void {
        while (r.i < r.s.len) switch (r.s[r.i]) {
            ' ', '\t', '\n', '\r' => r.i += 1,
            else => return,
        };
    }

    fn peek(r: *JsonReader, c: u8) bool {
        return r.i < r.s.len and r.s[r.i] == c;
    }

    fn push(r: *JsonReader, v: Value) VmError!void {
        return r.scope.push(v);
    }

    fn top(r: *JsonReader) *Value {
        return &r.vm.roots.items[r.vm.roots.items.len - 1];
    }

    fn openCollection(r: *JsonReader, object: bool) VmError!void {
        r.i += 1;
        r.open.append(r.vm.allocator, .{ .base = r.vm.roots.items.len, .object = object }) catch return VmError.OutOfMemory;
        r.skipSpace();
    }

    /// The text's one value.
    fn read(r: *JsonReader) VmError!Value {
        value: while (true) {
            r.skipSpace();
            if (r.i >= r.s.len) return r.fail(r.i, "the text ends before its value", .{});
            switch (r.s[r.i]) {
                '{' => {
                    try r.openCollection(true);
                    if (!r.peek('}')) {
                        try r.key();
                        continue :value;
                    }
                    r.i += 1;
                    try r.close();
                },
                '[' => {
                    try r.openCollection(false);
                    if (!r.peek(']')) continue :value;
                    r.i += 1;
                    try r.close();
                },
                '"' => try r.push(string_mod.fromBytes(r.heap, try r.string()) catch return VmError.OutOfMemory),
                '-', '0'...'9' => try r.push(try r.number()),
                't' => try r.literal("true", value_mod.fromBool(true)),
                'f' => try r.literal("false", value_mod.fromBool(false)),
                'n' => try r.literal("null", value_mod.nilValue()),
                else => return r.unexpected(),
            }
            // A value is whole: end each collection it completes.
            while (r.open.getLastOrNull()) |o| {
                if (o.object) try r.member();
                r.skipSpace();
                if (r.peek(',')) {
                    r.i += 1;
                    if (o.object) try r.key();
                    continue :value;
                }
                const end: u8 = if (o.object) '}' else ']';
                if (!r.peek(end)) {
                    if (r.i >= r.s.len) return r.fail(r.i, "the text ends inside an {s}", .{if (o.object) "object" else "array"});
                    return r.fail(r.i, "expected ',' or '{c}'", .{end});
                }
                r.i += 1;
                try r.close();
            }
            r.skipSpace();
            if (r.i < r.s.len) return r.fail(r.i, "text follows the value", .{});
            return r.top().*;
        }
    }

    /// Build the innermost open collection from its slots.
    fn close(r: *JsonReader) VmError!void {
        const o = r.open.pop().?;
        const items = r.vm.roots.items[o.base..];
        const v = if (!o.object)
            vector_mod.fromSlice(r.heap, items)
        else if (items.len == 0)
            champ_mod.mapEmpty(r.heap)
        else
            champ_mod.mapFromEntries(r.heap, @as([*]const champ_mod.Entry, @ptrCast(items.ptr))[0 .. items.len / 2], &dispatch_mod.hashValue, &dispatch_mod.equal);
        r.vm.roots.shrinkRetainingCapacity(o.base);
        try r.push(v catch return VmError.OutOfMemory);
    }

    /// An object's key and its colon, the key through `:key-fn`.
    fn key(r: *JsonReader) VmError!void {
        r.skipSpace();
        if (!r.peek('"')) {
            if (r.i >= r.s.len) return r.fail(r.i, "the text ends inside an object", .{});
            return r.fail(r.i, "expected a string key", .{});
        }
        if (isKeywordFn(r.key_fn)) {
            const name = try r.string();
            if (name.len == 0) return r.vm.fail(VmError.InvalidArgument, "JSON: the empty key names no keyword", .{});
            try r.push(r.vm.ensureInterner().internKeywordValue(name) catch return VmError.OutOfMemory);
        } else {
            try r.push(string_mod.fromBytes(r.heap, try r.string()) catch return VmError.OutOfMemory);
            if (!r.key_fn.isNil()) {
                // The call may move the root stack: its slot is found
                // again after it.
                const k = try r.vm.callValue(r.key_fn, &.{r.top().*});
                r.top().* = k;
            }
        }
        r.skipSpace();
        if (!r.peek(':')) return r.fail(r.i, "expected ':' after a key", .{});
        r.i += 1;
    }

    /// The member whose key and value end the root stack, through
    /// `:value-fn`: its result replaces the value, or drops the member
    /// when it is `:value-fn` itself.
    fn member(r: *JsonReader) VmError!void {
        if (r.value_fn.isNil()) return;
        const n = r.vm.roots.items.len;
        const kv = [2]Value{ r.vm.roots.items[n - 2], r.vm.roots.items[n - 1] };
        const v = try r.vm.callValue(r.value_fn, &kv);
        if (v.tag == r.value_fn.tag and v.payload == r.value_fn.payload) {
            r.vm.roots.shrinkRetainingCapacity(n - 2);
        } else r.vm.roots.items[n - 1] = v;
    }

    fn literal(r: *JsonReader, word: []const u8, v: Value) VmError!void {
        if (!std.mem.startsWith(u8, r.s[r.i..], word)) return r.unexpected();
        r.i += word.len;
        try r.push(v);
    }

    /// The string at the opening quote, its escapes decoded; the bytes
    /// lie in the text or in `scratch`, until the next string.
    fn string(r: *JsonReader) VmError![]const u8 {
        const s = r.s;
        const start = r.i + 1;
        var j = start;
        while (j < s.len) : (j += 1) switch (s[j]) {
            '"' => {
                r.i = j + 1;
                return s[start..j];
            },
            '\\' => break,
            0...0x1f => return r.fail(j, "a control character in a string", .{}),
            else => {},
        } else return r.fail(s.len, "the text ends inside a string", .{});
        const gpa = r.vm.allocator;
        r.scratch.clearRetainingCapacity();
        r.scratch.appendSlice(gpa, s[start..j]) catch return VmError.OutOfMemory;
        while (true) {
            var k = j;
            while (k < s.len and s[k] != '"' and s[k] != '\\' and s[k] >= 0x20) k += 1;
            r.scratch.appendSlice(gpa, s[j..k]) catch return VmError.OutOfMemory;
            j = k;
            if (j >= s.len) return r.fail(s.len, "the text ends inside a string", .{});
            switch (s[j]) {
                '"' => {
                    r.i = j + 1;
                    return r.scratch.items;
                },
                '\\' => {},
                else => return r.fail(j, "a control character in a string", .{}),
            }
            const at = j;
            if (j + 1 >= s.len) return r.fail(s.len, "the text ends inside a string", .{});
            j += 2;
            const simple: u8 = switch (s[j - 1]) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 8,
                'f' => 12,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => 0,
                else => return r.fail(at, "an unknown escape", .{}),
            };
            if (s[j - 1] != 'u') {
                r.scratch.append(gpa, simple) catch return VmError.OutOfMemory;
                continue;
            }
            var cp: u21 = try r.hex4(at, j);
            j += 4;
            if (cp >= 0xDC00 and cp <= 0xDFFF) return r.fail(at, "a lone surrogate", .{});
            if (cp >= 0xD800 and cp <= 0xDBFF) {
                if (j + 6 > s.len or s[j] != '\\' or s[j + 1] != 'u') return r.fail(at, "a lone surrogate", .{});
                const low = try r.hex4(at, j + 2);
                if (low < 0xDC00 or low > 0xDFFF) return r.fail(at, "a lone surrogate", .{});
                cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                j += 6;
            }
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &enc) catch unreachable;
            r.scratch.appendSlice(gpa, enc[0..n]) catch return VmError.OutOfMemory;
        }
    }

    /// The four hex digits at `j` of the `\u` escape at `at`.
    fn hex4(r: *JsonReader, at: usize, j: usize) VmError!u21 {
        if (j + 4 > r.s.len) return r.fail(at, "an unknown escape", .{});
        var cp: u21 = 0;
        for (r.s[j..][0..4]) |c| cp = cp * 16 + (std.fmt.charToDigit(c, 16) catch return r.fail(at, "an unknown escape", .{}));
        return cp;
    }

    /// The number at `i`, in JSON's grammar: an integer a fixnum or a
    /// bignum, anything with a fraction or an exponent a double.
    fn number(r: *JsonReader) VmError!Value {
        const s = r.s;
        const start = r.i;
        var j = start + @intFromBool(s[start] == '-');
        const digits = struct {
            fn run(text: []const u8, from: usize) usize {
                var k = from;
                while (k < text.len and std.ascii.isDigit(text[k])) k += 1;
                return k;
            }
        }.run;
        if (j < s.len and s[j] == '0') j += 1 else {
            const k = digits(s, j);
            if (k == j) return r.fail(start, "a malformed number", .{});
            j = k;
        }
        var integer = true;
        if (j < s.len and s[j] == '.') {
            const k = digits(s, j + 1);
            if (k == j + 1) return r.fail(start, "a malformed number", .{});
            j = k;
            integer = false;
        }
        if (j < s.len and (s[j] == 'e' or s[j] == 'E')) {
            j += 1;
            if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
            const k = digits(s, j);
            if (k == j) return r.fail(start, "a malformed number", .{});
            j = k;
            integer = false;
        }
        r.i = j;
        const text = s[start..j];
        if (!integer) return value_mod.fromFloat(std.fmt.parseFloat(f64, text) catch unreachable);
        if (text.len <= 18) return integerValue(r.vm, std.fmt.parseInt(i64, text, 10) catch unreachable);
        return (bignum_mod.parseDecimal(r.heap, text) catch return VmError.OutOfMemory) orelse unreachable;
    }
};

/// `(#%json-read s opts)` → the value of the JSON text `s`: an object
/// a map, an array a vector, a string a string, a number a fixnum,
/// bignum or double, true, false and null themselves. `opts` maps
/// `:key-fn` to a function of each key's string (`keyword` interns it
/// directly) and `:value-fn` to a function of each object member's key
/// and value whose result replaces the value, or drops the member when
/// it is `:value-fn` itself (clojure.data.json's options).
fn fnJsonRead(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const opts = try jsonOptions(vm, args[1], &.{ "key-fn", "value-fn" });
    const text = string_mod.asBytes(args[0]);
    if (!std.unicode.utf8ValidateSlice(text)) return VmError.Utf8Error;
    var r: JsonReader = .{ .vm = vm, .heap = vm.ensureHeap(), .s = text, .scope = vm.rootScope(), .key_fn = opts[0], .value_fn = opts[1] };
    defer r.scope.release();
    defer r.deinit();
    return r.read();
}

/// The class name `class` gives a value of kind `k`, for messages.
fn className(k: Kind) []const u8 {
    return switch (k) {
        .true_, .false_ => "boolean",
        .persistent_vector => "vector",
        .persistent_map => "map",
        .persistent_set => "set",
        else => @tagName(k),
    };
}

/// Values written as JSON text into `w`. The walk recurses on the
/// data's depth under the stack guard; each `:value-fn` result is
/// rooted while it is written.
const JsonWriter = struct {
    vm: *VM,
    w: *std.Io.Writer,
    scope: vm_mod.RootScope,
    key_fn: Value,
    value_fn: Value,
    indent: bool,
    escape_unicode: bool,
    escape_slash: bool,
    depth: usize = 0,

    fn put(jw: *JsonWriter, bytes: []const u8) VmError!void {
        jw.w.writeAll(bytes) catch return VmError.OutOfMemory;
    }

    fn newline(jw: *JsonWriter) VmError!void {
        if (!jw.indent) return;
        try jw.put("\n");
        jw.w.splatByteAll(' ', 2 * jw.depth) catch return VmError.OutOfMemory;
    }

    fn value(jw: *JsonWriter, v: Value) VmError!void {
        stack.check() catch return VmError.StackOverflow;
        const interner = jw.vm.ensureInterner();
        switch (v.kind()) {
            .nil => try jw.put("null"),
            .true_ => try jw.put("true"),
            .false_ => try jw.put("false"),
            .fixnum => jw.w.print("{d}", .{v.asFixnum()}) catch return VmError.OutOfMemory,
            .bignum => bignum_mod.formatDecimal(v, jw.w) catch return VmError.OutOfMemory,
            .float => {
                const f = v.asFloat();
                if (std.math.isNan(f)) return throwJson(jw.vm, "JSON: cannot write NaN", null);
                if (std.math.isInf(f)) return throwJson(jw.vm, if (f > 0) "JSON: cannot write Infinity" else "JSON: cannot write -Infinity", null);
                format_mod.formatFloatJava(f, jw.w) catch return VmError.OutOfMemory;
            },
            .string => try jw.string(string_mod.asBytes(v)),
            .char => {
                var b: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(v.asChar(), &b) catch return VmError.Utf8Error;
                try jw.string(b[0..n]);
            },
            .keyword => try jw.string(interner.keywordName(v.asKeywordId())),
            .symbol => try jw.string(interner.symbolName(v.asSymbolId())),
            .persistent_map, .sorted_map => try jw.object(v),
            .record => if (jw.instantMs(v)) |ms| {
                var buf: [40]u8 = undefined;
                var fixed: std.Io.Writer = .fixed(&buf);
                writeInstant(&fixed, ms) catch unreachable;
                try jw.string(fixed.buffered());
            } else try jw.object(v),
            .nextomic_entity => {
                const m = try (seq_mod.entity_map orelse return VmError.KindMismatch)(jw.vm, v);
                try jw.scope.push(m);
                try jw.object(m);
            },
            .persistent_vector, .list, .lazy_seq, .persistent_set, .sorted_set, .typed_vector => try jw.array(v),
            else => |k| {
                var buf: [80]u8 = undefined;
                return throwJson(jw.vm, std.fmt.bufPrint(&buf, "JSON: cannot write a value of class {s}", .{className(k)}) catch unreachable, null);
            },
        }
    }

    /// The epoch milliseconds of a `nexis.time.Instant`, null for any
    /// other record (STDLIB.md §12).
    fn instantMs(jw: *JsonWriter, v: Value) ?i64 {
        const t = jw.vm.recordType(record_mod.typeId(v)) orelse return null;
        if (!std.mem.eql(u8, t.ns_name, "nexis.time") or !std.mem.eql(u8, t.type_name, "Instant")) return null;
        const ms_key = jw.vm.ensureInterner().internKeywordValue("ms") catch return null;
        const ms = switch (champ_mod.mapGet(record_mod.fieldsOf(v), ms_key, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
            .present => |x| x,
            .absent => return null,
        };
        return if (ms.kind() == .fixnum) ms.asFixnum() else null;
    }

    fn array(jw: *JsonWriter, v: Value) VmError!void {
        var it = try makeSeqIter(jw.vm, v);
        try jw.put("[");
        jw.depth += 1;
        var first = true;
        while (try it.next()) |x| {
            if (!first) try jw.put(",");
            first = false;
            try jw.newline();
            try jw.value(x);
        }
        jw.depth -= 1;
        if (!first) try jw.newline();
        try jw.put("]");
    }

    fn object(jw: *JsonWriter, m: Value) VmError!void {
        var it = MapEntries.of(m).?;
        try jw.put("{");
        jw.depth += 1;
        var first = true;
        while (it.next()) |e| {
            const mark = jw.vm.roots.items.len;
            defer jw.vm.roots.shrinkRetainingCapacity(mark);
            var v = e.value;
            if (!jw.value_fn.isNil()) {
                v = try jw.vm.callValue(jw.value_fn, &.{ e.key, e.value });
                if (v.tag == jw.value_fn.tag and v.payload == jw.value_fn.payload) continue;
                try jw.scope.push(v);
                try seq_mod.realizeAll(jw.vm, v);
            }
            if (!first) try jw.put(",");
            first = false;
            try jw.newline();
            try jw.key(e.key);
            try jw.put(if (jw.indent) ": " else ":");
            try jw.value(v);
        }
        jw.depth -= 1;
        if (!first) try jw.newline();
        try jw.put("}");
    }

    /// A member's key: `:key-fn`'s string, else a string as it is, a
    /// keyword or symbol by its whole name and an integer by its digits.
    fn key(jw: *JsonWriter, k: Value) VmError!void {
        var buf: [80]u8 = undefined;
        if (!jw.key_fn.isNil()) {
            const out = try jw.vm.callValue(jw.key_fn, &.{k});
            if (out.kind() != .string) return throwJson(jw.vm, std.fmt.bufPrint(&buf, "JSON: :key-fn returned a value of class {s}, not a string", .{className(out.kind())}) catch unreachable, null);
            return jw.string(string_mod.asBytes(out));
        }
        switch (k.kind()) {
            .string, .keyword, .symbol => return jw.value(k),
            .fixnum, .bignum => {
                try jw.put("\"");
                try jw.value(k);
                try jw.put("\"");
            },
            .nil => return throwJson(jw.vm, "JSON: cannot write a nil key", null),
            else => |kind| return throwJson(jw.vm, std.fmt.bufPrint(&buf, "JSON: cannot write a key of class {s}", .{className(kind)}) catch unreachable, null),
        }
    }

    /// `bytes` as a JSON string: `"` and `\` escaped, a control
    /// character by its short escape or `\u00XX`, `/` and every
    /// character past ASCII (`\uXXXX`, a pair past the BMP) when the
    /// options ask.
    fn string(jw: *JsonWriter, bytes: []const u8) VmError!void {
        if (!std.unicode.utf8ValidateSlice(bytes)) return VmError.Utf8Error;
        try jw.put("\"");
        var i: usize = 0;
        var plain: usize = 0;
        while (i < bytes.len) {
            const c = bytes[i];
            const needs = c < 0x20 or c == '"' or c == '\\' or (c == '/' and jw.escape_slash) or (c >= 0x80 and jw.escape_unicode);
            if (!needs) {
                i += 1;
                continue;
            }
            try jw.put(bytes[plain..i]);
            var len: usize = 1;
            switch (c) {
                '"' => try jw.put("\\\""),
                '\\' => try jw.put("\\\\"),
                '/' => try jw.put("\\/"),
                '\n' => try jw.put("\\n"),
                '\r' => try jw.put("\\r"),
                '\t' => try jw.put("\\t"),
                8 => try jw.put("\\b"),
                12 => try jw.put("\\f"),
                0...7, 11, 14...0x1f => jw.w.print("\\u{x:0>4}", .{c}) catch return VmError.OutOfMemory,
                else => {
                    len = std.unicode.utf8ByteSequenceLength(c) catch unreachable;
                    const cp = std.unicode.utf8Decode(bytes[i..][0..len]) catch unreachable;
                    if (cp < 0x10000) {
                        jw.w.print("\\u{x:0>4}", .{cp}) catch return VmError.OutOfMemory;
                    } else {
                        const v = cp - 0x10000;
                        jw.w.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF) }) catch return VmError.OutOfMemory;
                    }
                },
            }
            i += len;
            plain = i;
        }
        try jw.put(bytes[plain..]);
        try jw.put("\"");
    }
};

/// `(#%json-write x opts)` → the JSON text of `x`: a map (hash, sorted,
/// a record, a Nextomic entity) an object, any other collection or seq
/// an array, a string, character, keyword or symbol a string (the
/// keyword's whole name, without its colon), a `nexis.time.Instant` its
/// ISO-8601 text, numbers, booleans and nil themselves. `opts` maps
/// `:key-fn`, `:value-fn`, `:indent`, `:escape-unicode` and
/// `:escape-slash` (STDLIB.md §13).
fn fnJsonWrite(vm: *VM, args: []const Value) VmError!Value {
    const opts = try jsonOptions(vm, args[1], &.{ "key-fn", "value-fn", "indent", "escape-unicode", "escape-slash" });
    // Every lazy seq in `x` is realized first, so the walk calls back
    // into the VM only for the options' functions.
    try seq_mod.realizeAll(vm, args[0]);
    var out = std.Io.Writer.Allocating.init(vm.allocator);
    defer out.deinit();
    var jw: JsonWriter = .{
        .vm = vm,
        .w = &out.writer,
        .scope = vm.rootScope(),
        .key_fn = opts[0],
        .value_fn = opts[1],
        .indent = opts[2].isTruthy(),
        .escape_unicode = opts[3].isTruthy(),
        .escape_slash = opts[4].isTruthy(),
    };
    defer jw.scope.release();
    try jw.value(args[0]);
    return string_mod.fromBytes(vm.ensureHeap(), out.written()) catch VmError.OutOfMemory;
}

// =============================================================================
// Record internals (PROTOCOLS.md §7)
// =============================================================================
//
// Four internal helpers installed in `nexis.internal` (NOT auto-
// referred). `defrecord` expansion emits qualified calls. Users
// don't touch these directly; they're macro-emit-only
// scaffolding.

/// `(#%register-record-type "ns/name" [:field1 :field2 ...])`
///   → fixnum type_id
///
/// Looks up the receiver VM's namespace registry to derive the
/// effective ns prefix (the current namespace), then calls
/// `vm.registerRecordType`; redefining a type registers a new one.
/// The `"ns/name"` a record or protocol registers under, split at the
/// last `/`; the namespace is "" when there is none.
fn splitNsName(full: []const u8) struct { ns: []const u8, name: []const u8 } {
    const i = std.mem.findScalarLast(u8, full, '/') orelse return .{ .ns = "", .name = full };
    return .{ .ns = full[0..i], .name = full[i + 1 ..] };
}

fn fnRegisterRecordType(vm: *VM, args: []const Value) VmError!Value {
    const full_name_v = args[0];
    const fields_vec = args[1];
    if (full_name_v.kind() != .string) return VmError.KindMismatch;
    if (fields_vec.kind() != .persistent_vector) return VmError.KindMismatch;

    const parts = splitNsName(string_mod.asBytes(full_name_v));

    const interner = vm.ensureInterner();
    const n = vector_mod.count(fields_vec);
    const field_names = vm.allocator.alloc([]const u8, n) catch return VmError.OutOfMemory;
    defer vm.allocator.free(field_names);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const f = vector_mod.nth(fields_vec, i);
        if (f.kind() != .keyword) return VmError.KindMismatch;
        const id: u32 = f.asKeywordId();
        field_names[i] = interner.keywordName(id);
    }

    const new_id = vm.registerRecordType(parts.ns, parts.name, field_names) catch return VmError.OutOfMemory;
    return value_mod.fromFixnum(@intCast(new_id)) orelse VmError.ArithmeticOverflow;
}

/// The record type id `v` holds: `:kind-mismatch` unless it is an
/// integer, `:invalid-argument` unless a `defrecord` registered it.
/// The `#%` natives are reachable by their qualified names, so each
/// checks the ids it is given (FORMS.md §8).
fn recordTypeArg(vm: *VM, v: Value) VmError!u32 {
    if (v.kind() != .fixnum) return VmError.KindMismatch;
    const id = std.math.cast(u32, v.asFixnum()) orelse return VmError.InvalidArgument;
    _ = vm.recordType(id) orelse return VmError.InvalidArgument;
    return id;
}

/// `(#%make-record type-id m)` → a record of the type with the
/// entries of the map `m` (any map, a record's fields, or nil for
/// none) as its fields; `(#%make-record type-id m fields)`, `map->R`'s
/// call, also maps each keyword of the vector `fields` that `m` lacks
/// to nil, as Clojure's `create` fills its base fields.
fn fnMakeRecord(vm: *VM, args: []const Value) VmError!Value {
    const id = try recordTypeArg(vm, args[0]);
    const heap = vm.ensureHeap();
    const fields = switch (args[1].kind()) {
        .persistent_map => args[1],
        .record => record_mod.fieldsOf(args[1]),
        .nil => champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory,
        .sorted_map => blk: {
            // `Heap.alloc` never collects (GC.md §11.5): the map
            // being built needs no root.
            var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
            var it = MapEntries.of(args[1]).?;
            while (it.next()) |e| m = try mapPut(heap, m, e.key, e.value);
            break :blk m;
        },
        else => return VmError.KindMismatch,
    };
    if (args.len == 3) {
        if (args[2].kind() != .persistent_vector) return VmError.KindMismatch;
        // `Heap.alloc` never collects (GC.md §11.5): the map being
        // built needs no root.
        var filled = fields;
        for (0..vector_mod.count(args[2])) |i| {
            const k = vector_mod.nth(args[2], i);
            if (!mapHas(filled, k)) filled = try mapPut(heap, filled, k, value_mod.nilValue());
        }
        return record_mod.make(heap, id, filled) catch return VmError.OutOfMemory;
    }
    return record_mod.make(heap, id, fields) catch return VmError.OutOfMemory;
}

/// `(#%current-ns)` → the name of the current namespace as a string:
/// what `deftest` registers under and `run-tests` runs by default.
fn fnCurrentNs(vm: *VM, _: []const Value) VmError!Value {
    return string_mod.fromBytes(vm.ensureHeap(), vm.ensureNamespace().name) catch VmError.OutOfMemory;
}

/// `(in-ns 'name)` → makes `name` the current namespace, creating
/// it (with nexis.core referred) when absent, so the forms after it
/// compile there; nil.
fn fnInNs(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .symbol) return VmError.KindMismatch;
    const registry = vm.ensureRegistry() catch return VmError.OutOfMemory;
    registry.switchTo(vm.ensureInterner().symbolName(args[0].asSymbolId())) catch return VmError.OutOfMemory;
    registry.publishCurrent(vm.ensureInterner()) catch return VmError.OutOfMemory;
    return value_mod.nilValue();
}

/// `(#%record? x)` → bool.
fn fnRecordQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .record);
}

/// `(#%record-type-id record)` → fixnum.
fn fnRecordTypeId(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .record) return VmError.NotARecord;
    return value_mod.fromFixnum(@intCast(record_mod.typeId(args[0]))) orelse VmError.ArithmeticOverflow;
}

// =============================================================================
// Protocol internals (PROTOCOLS.md §7)
// =============================================================================
//
// Two helpers installed in `nexis.internal` (alongside the
// record helpers). `defprotocol` macro emits qualified calls.
//
//   (#%register-protocol "ns/IFoo" [:bar :baz])  → protocol Value
//   (#%protocol-fn IFoo :bar)                    → protocol_fn Value
//
// Method-name IDs are KEYWORD-pool ids — the macro converts each
// method symbol to a keyword in the emitted expansion so the
// natives see homogeneous values + use a single interning pool.

fn fnRegisterProtocol(vm: *VM, args: []const Value) VmError!Value {
    const full_name_v = args[0];
    const methods_vec = args[1];
    if (full_name_v.kind() != .string) return VmError.KindMismatch;
    if (methods_vec.kind() != .persistent_vector) return VmError.KindMismatch;

    const parts = splitNsName(string_mod.asBytes(full_name_v));

    const interner = vm.ensureInterner();
    const n = vector_mod.count(methods_vec);
    const specs = vm.allocator.alloc(vm_mod.ProtocolMethodSpec, n) catch return VmError.OutOfMemory;
    defer vm.allocator.free(specs);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const m = vector_mod.nth(methods_vec, i);
        if (m.kind() != .keyword) return VmError.KindMismatch;
        const id: u32 = m.asKeywordId();
        specs[i] = .{ .name_id = id, .name = interner.keywordName(id) };
    }

    const new_id = vm.registerProtocol(parts.ns, parts.name, specs) catch return VmError.OutOfMemory;
    return protocol_mod.makeProtocol(vm.ensureHeap(), new_id) catch return VmError.OutOfMemory;
}

fn fnProtocolFn(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    if (args[1].kind() != .keyword) return VmError.KindMismatch;
    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = args[1].asKeywordId();

    // Verify the method exists on the protocol — otherwise the
    // protocol_fn would be dispatching into the void at every
    // call site. Raise NoProtocolMethod at construction time
    // (earliest possible) so the error points at defprotocol /
    // a corrupted macro.
    const proto = vm.protocolById(protocol_id) orelse return VmError.NoProtocolMethod;
    var found = false;
    for (proto.methods.items) |m| {
        if (m.name_id == method_name_id) {
            found = true;
            break;
        }
    }
    if (!found) return VmError.NoProtocolMethod;

    return protocol_mod.makeProtocolFn(vm.ensureHeap(), protocol_id, method_name_id) catch return VmError.OutOfMemory;
}

/// `(#%extend-record-impl protocol method-kw record-type-id impl-fn)`
///   → nil
///
/// Wire an impl for a specific record type into the protocol
/// registry. Used by `defrecord`'s inline protocol clauses + by
/// `extend-protocol`/`extend-type` over record receivers.
fn fnExtendRecordImpl(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    if (args[1].kind() != .keyword) return VmError.KindMismatch;
    // args[3] is the impl callable: closure / native_fn / etc.
    // We don't validate its kind here — dispatchProtocolMethod
    // calls `callValue` which surfaces NotCallable if it's not
    // invocable. Errors point at the user's impl form rather
    // than this scaffolding.
    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = args[1].asKeywordId();
    const type_id = try recordTypeArg(vm, args[2]);
    const key = vm_mod.DispatchKey{ .tag = .record, .id = type_id };
    vm.extendProtocol(protocol_id, method_name_id, key, args[3]) catch |err| switch (err) {
        error.NoProtocolMethod => return VmError.NoProtocolMethod,
        error.OutOfMemory => return VmError.OutOfMemory,
    };
    return value_mod.nilValue();
}

// =============================================================================
// extend-protocol over built-in kinds + Any default + satisfies?
// =============================================================================
//
// `extend-type` / `extend-protocol` macros (in expand.zig) emit
// qualified calls to these helpers. A type-tag keyword is a field
// name of the `Kind` enum (`:nil`, `:false_`, `:true_`, `:fixnum`,
// `:string`, `:persistent_vector`, `:var_`, `:atom`, ...), matched by
// `typeNameToKinds` (PROTOCOLS.md §4.3).
//
// Plus the aliases, each of the kinds Clojure's type covers:
//   :boolean → :true_ and :false_ (what `class` returns for both)
//   :vector  → :persistent_vector
//   :map     → :persistent_map and :sorted_map
//   :set     → :persistent_set and :sorted_set
//
// `:any` triggers the default-fallback path (default_impl on the
// method) and lives in #%extend-default-impl, not the builtin one.

fn fnExtendBuiltinImpl(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    if (args[1].kind() != .keyword) return VmError.KindMismatch;
    if (args[2].kind() != .keyword) return VmError.KindMismatch;

    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = args[1].asKeywordId();

    const interner = vm.ensureInterner();
    const type_id_kw: u32 = args[2].asKeywordId();
    const type_name = interner.keywordName(type_id_kw);
    const kinds = typeNameToKinds(type_name) orelse return VmError.InvalidArgument;
    for (kinds) |kind| {
        const key = vm_mod.DispatchKey{ .tag = .builtin, .id = @backingInt(kind) };
        vm.extendProtocol(protocol_id, method_name_id, key, args[3]) catch |err| switch (err) {
            error.NoProtocolMethod => return VmError.NoProtocolMethod,
            error.OutOfMemory => return VmError.OutOfMemory,
        };
    }
    return value_mod.nilValue();
}

/// `(#%kwargs x)` → what a map pattern destructures, as Clojure 1.12
/// makes it: a value that is not a seq (a map, a vector, nil) is
/// itself; a seq, lazy or not, of one element is that element (a
/// trailing map), the empty seq `{}`, and a longer seq alternating
/// keys and values the map of them, an odd count `:invalid-argument`.
/// A lazy seq's elements stay reachable from it once realized.
fn fnKwargs(vm: *VM, args: []const Value) VmError!Value {
    if (!isSeq(args[0].kind())) return args[0];
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    if (items.items.len == 1) return items.items[0];
    if (items.items.len % 2 != 0) return VmError.InvalidArgument;
    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var i: usize = 0;
    while (i < items.items.len) : (i += 2) {
        m = try mapPut(heap, m, items.items[i], items.items[i + 1]);
    }
    return m;
}

/// `(#%raise tag message x?)` → throws the library's own error `tag`
/// as the runtime throws one of its own (docs/VM.md §13): the map
/// `{:error tag :message m}`, `m` being `message` followed by the kind
/// of `x` when given ("num takes a number or nil, got a string"), and
/// the place of the program's call when a handler is in force.
fn fnRaise(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .keyword or args[1].kind() != .string) return VmError.KindMismatch;
    var buf: [256]u8 = undefined;
    const text = string_mod.asBytes(args[1]);
    const message = if (args.len == 3)
        std.mem.print(&buf, "{s} {s}", .{ text, vm_mod.kindPhrase(args[2].kind()) }) catch text
    else
        text;
    const m = vm.errorValue(args[0], message, null);
    if (m.kind() != .persistent_map) return vm.throwValue(m);
    return vm.throwErrorMap(m);
}

/// `(#%catch-matches? v tag)` → whether `(catch tag e ...)` takes the
/// thrown `v`: `v` is `tag` itself, or a map or record whose
/// `:error` entry is `tag`.
fn fnCatchMatches(vm: *VM, args: []const Value) VmError!Value {
    const v = args[0];
    const tag = args[1];
    if (dispatch_mod.equal(v, tag)) return value_mod.fromBool(true);
    if (v.kind() != .persistent_map and v.kind() != .record) return value_mod.fromBool(false);
    const interner = vm.ensureInterner();
    const error_key = interner.internKeywordValue("error") catch return VmError.OutOfMemory;
    if (dispatch_mod.equal(try vm_mod.lookup(v, error_key, value_mod.nilValue()), tag)) return value_mod.fromBool(true);
    // An `ex-info` map: its data's `:error`.
    const data_key = interner.internKeywordValue("data") catch return VmError.OutOfMemory;
    const data = try vm_mod.lookup(v, data_key, value_mod.nilValue());
    if (data.kind() != .persistent_map) return value_mod.fromBool(false);
    return value_mod.fromBool(dispatch_mod.equal(try vm_mod.lookup(data, error_key, value_mod.nilValue()), tag));
}

fn fnExtendDefaultImpl(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    if (args[1].kind() != .keyword) return VmError.KindMismatch;

    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = args[1].asKeywordId();
    const proto = vm.protocolById(protocol_id) orelse return VmError.NoProtocolMethod;
    for (proto.methods.items) |*m| {
        if (m.name_id == method_name_id) {
            m.default_impl = args[2];
            return value_mod.nilValue();
        }
    }
    return VmError.NoProtocolMethod;
}

fn fnSatisfiesQ(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    const proto = vm.protocolById(protocol_mod.protocolId(args[0])) orelse
        return value_mod.fromBool(false);
    const key = vm_mod.DispatchKey.ofValue(args[1]);
    for (proto.methods.items) |m| {
        if (m.impls.contains(key) or m.default_impl != null) {
            return value_mod.fromBool(true);
        }
    }
    return value_mod.fromBool(false);
}

/// Map a friendly type-tag keyword name to a Kind
/// enum value. Friendly aliases (vector/map/set) are accepted
/// alongside the canonical Kind enum names. Returns null for
/// unknown names; the caller raises `:invalid-argument`.
fn typeNameToKinds(name: []const u8) ?[]const Kind {
    if (std.mem.eql(u8, name, "boolean")) return &.{ .true_, .false_ };
    if (std.mem.eql(u8, name, "vector")) return &.{.persistent_vector};
    if (std.mem.eql(u8, name, "map")) return &.{ .persistent_map, .sorted_map };
    if (std.mem.eql(u8, name, "set")) return &.{ .persistent_set, .sorted_set };
    const all = comptime std.enums.values(Kind);
    for (all, 0..) |k, i| if (std.mem.eql(u8, @tagName(k), name)) return all[i..][0..1];
    return null;
}

// =============================================================================
// Helpers
// =============================================================================

/// Every seqable receiver (`seq.SeqIter`, LAZY.md §5).
const SeqIter = seq_mod.SeqIter;

fn makeSeqIter(vm: *VM, coll: Value) VmError!SeqIter {
    return SeqIter.init(vm, coll);
}

/// `makeSeqIter` over an argument the native consumes
/// (`NativeFn.consumes`): `coll` is pushed on `scope`, and the slot
/// keeps the walk's place (`SeqIter.cursor`).
fn consumingSeqIter(vm: *VM, coll: Value, scope: vm_mod.RootScope) VmError!SeqIter {
    try scope.push(coll);
    var it = try makeSeqIter(vm, coll);
    it.cursor = vm.roots.items.len - 1;
    return it;
}

/// `makeSeqIter` whose built values stay rooted in `scope`.
fn rootedSeqIter(vm: *VM, coll: Value, scope: vm_mod.RootScope) VmError!SeqIter {
    return SeqIter.rooted(vm, coll, scope);
}

/// Materialize a seqable into an owned list of Values. The
/// caller frees it with `vm.allocator`.
fn collectSeq(vm: *VM, coll: Value) VmError!std.ArrayList(Value) {
    var out: std.ArrayList(Value) = .empty;
    errdefer out.deinit(vm.allocator);
    try appendSeqValues(vm, coll, &out);
    return out;
}

/// Append every element of `seq` to `out`. Used by `apply` to
/// splice the trailing seq into the args list.
fn appendSeqValues(vm: *VM, seq: Value, out: *std.ArrayList(Value)) VmError!void {
    // An unrealized range's elements in one reserved pass, which the
    // iterator would compute one call at a time (docs/LAZY.md §7).
    if (seq_mod.pureOf(seq)) |p| if (p == .range) {
        const r = p.range;
        const n: usize = @intCast(seq_mod.rangeCount(r.start, r.end, r.step));
        out.ensureUnusedCapacity(vm.allocator, n) catch return VmError.OutOfMemory;
        var x = r.start;
        for (0..n) |_| {
            out.appendAssumeCapacity(value_mod.fromFixnum(x).?);
            x += r.step;
        }
        return;
    };
    var it = try makeSeqIter(vm, seq);
    while (try it.next()) |e| {
        out.append(vm.allocator, e) catch return VmError.OutOfMemory;
    }
}

/// A fresh list of `items` (`list.build`). Nothing built needs a
/// root: `Heap.alloc` never collects (VM.md §9).
fn buildListFromSlice(vm: *VM, items: []const Value) VmError!Value {
    return list_mod.build(vm.ensureHeap(), items) catch VmError.OutOfMemory;
}

/// The result of a sequence native that calls back into the VM,
/// rooted as it is made (docs/GC.md §11.5, class 3). The first 32
/// values wait on the native's root scope; the 33rd makes them a
/// transient vector the scope holds instead, and every value from
/// there on is written into the slots of the vector's open tail
/// (`vector.openTailInPlace`), which the collector reaches through the
/// transient. A long result is so built where it ends up, never first
/// as a buffer on the root stack; a short one is built at the end from
/// the scope.
const Results = struct {
    vm: *VM,
    heap: *heap_mod.Heap,
    scope: vm_mod.RootScope,
    /// The transient vector, the scope's one entry, from the 33rd
    /// value on.
    building: ?Value = null,
    /// The open tail's slots, while `building`.
    slots: *[results_chunk]Value = undefined,
    /// How many values wait on the scope, or fill the open tail.
    fill: usize = 0,

    fn init(vm: *VM) Results {
        return .{ .vm = vm, .heap = vm.ensureHeap(), .scope = vm.rootScope() };
    }

    fn release(self: *const Results) void {
        self.scope.release();
    }

    /// Write `v` into the open tail; anything else (the first 32
    /// values, a full tail) takes `addOther`, out of the caller's loop.
    inline fn add(self: *Results, v: Value) VmError!void {
        if (self.fill < results_chunk and self.building != null) {
            self.slots[self.fill] = v;
            self.fill += 1;
            return;
        }
        return self.addOther(v);
    }

    /// Room for up to `k` more values in one place, for a batch of
    /// `vm.Callback.each` to write (GC.md §11.5): the open tail's
    /// slots, or slots pushed on the scope, which the batch writes by
    /// index. The caller adds the count it wrote to `fill`.
    fn room(self: *Results, k: usize) VmError!struct { n: usize, out: vm_mod.Callback.Out } {
        if (self.fill == results_chunk) try self.openTail();
        const n = @min(k, results_chunk - self.fill);
        if (self.building != null) return .{ .n = n, .out = .{ .slots = self.slots[self.fill..].ptr } };
        const at = self.vm.roots.items.len;
        for (0..n) |_| try self.scope.push(value_mod.nilValue());
        return .{ .n = n, .out = .{ .roots = at } };
    }

    /// Every value of `xs`, a tail's worth at a time once the scope's
    /// first 32 have moved into the vector.
    fn addAll(self: *Results, xs: []const Value) VmError!void {
        var rest = xs;
        while (rest.len > 0) {
            if (self.building == null or self.fill == results_chunk) {
                try self.addOther(rest[0]);
                rest = rest[1..];
                continue;
            }
            const k = @min(rest.len, results_chunk - self.fill);
            @memcpy(self.slots[self.fill..][0..k], rest[0..k]);
            self.fill += k;
            rest = rest[k..];
        }
    }

    noinline fn addOther(self: *Results, v: Value) VmError!void {
        if (self.fill == results_chunk) try self.openTail();
        if (self.building != null) self.slots[self.fill] = v else try self.scope.push(v);
        self.fill += 1;
    }

    /// Open the next 32 slots; the first time, move the values
    /// waiting on the scope into a transient vector and root that
    /// instead. `Heap.alloc` never collects, so the values need no
    /// root while they move.
    fn openTail(self: *Results) VmError!void {
        const t = self.building orelse blk: {
            const first = vector_mod.fromSlice(self.heap, scopeItems(self.scope)) catch return VmError.OutOfMemory;
            const t = transient_mod.transientFrom(self.heap, first) catch return VmError.OutOfMemory;
            self.scope.release();
            try self.scope.push(t);
            self.building = t;
            break :blk t;
        };
        self.slots = transient_mod.vectorOpenTailBang(self.heap, t) catch return VmError.OutOfMemory;
        self.fill = 0;
    }

    /// The vector, its open tail closed at what was written.
    fn finish(self: *Results, t: Value) VmError!Value {
        transient_mod.vectorCloseTailBang(t, @intCast(self.fill)) catch return VmError.OutOfMemory;
        return transient_mod.persistentBang(t) catch VmError.OutOfMemory;
    }

    /// The result as a list without its last value, nil when it holds
    /// fewer than two (`butlast`). A long one drops it from the
    /// transient in place.
    fn butlastList(self: *Results) VmError!Value {
        const t = self.building orelse {
            const items = scopeItems(self.scope);
            if (items.len < 2) return value_mod.nilValue();
            return buildListFromSlice(self.vm, items[0 .. items.len - 1]);
        };
        transient_mod.vectorCloseTailBang(t, @intCast(self.fill)) catch return VmError.OutOfMemory;
        _ = transient_mod.vectorPopBang(self.heap, t) catch return VmError.OutOfMemory;
        const v = transient_mod.persistentBang(t) catch return VmError.OutOfMemory;
        return list_mod.ofVector(self.heap, v, 0) catch VmError.OutOfMemory;
    }

    /// The result as a list, its values in the reverse of the order
    /// they came (`reverse`): reversed where they wait, on the scope,
    /// or in the vector the transient made, which nothing else has
    /// reached (`reverseFresh`).
    fn reversedList(self: *Results) VmError!Value {
        const t = self.building orelse {
            std.mem.reverse(Value, self.vm.roots.items[self.scope.base..]);
            return buildListFromSlice(self.vm, scopeItems(self.scope));
        };
        const v = try self.finish(t);
        reverseFresh(v);
        return list_mod.ofVector(self.heap, v, 0) catch VmError.OutOfMemory;
    }

    /// The result as a list (`buildListFromSlice`'s shape).
    fn list(self: *Results) VmError!Value {
        const t = self.building orelse return buildListFromSlice(self.vm, scopeItems(self.scope));
        return list_mod.ofVector(self.heap, try self.finish(t), 0) catch VmError.OutOfMemory;
    }

    /// The result as a vector.
    fn vector(self: *Results) VmError!Value {
        const t = self.building orelse return vector_mod.fromSlice(self.heap, scopeItems(self.scope)) catch VmError.OutOfMemory;
        return self.finish(t);
    }
};

/// Reverse `v` in its own storage, a leaf at a time from both ends.
/// Only for a vector the caller has just built, whose nodes nothing
/// else has reached and whose hash is not yet cached: the one place a
/// persistent vector's elements change.
fn reverseFresh(v: Value) void {
    const mask = vector_mod.branch_factor - 1;
    const n = vector_mod.count(v);
    if (n < 2) return;
    var i: usize = 0;
    var j: usize = n - 1;
    while (i < j) {
        const left = @constCast(vector_mod.chunkFrom(v, i));
        const base = j & ~@as(usize, mask);
        const right = @constCast(vector_mod.chunkFrom(v, base));
        const k = @min(left.len, j - base + 1, (j - i + 1) / 2);
        for (0..k) |d| std.mem.swap(Value, &left[d], &right[j - base - d]);
        i += k;
        j -= k;
    }
}

/// How many values `Results` keeps waiting on the root stack, and
/// writes into each open tail: one vector leaf's worth.
const results_chunk = vector_mod.branch_factor;

/// What `scope` holds: a native that roots each result as it makes
/// it reads them back here as its buffer.
fn scopeItems(scope: vm_mod.RootScope) []const Value {
    return scope.vm.roots.items[scope.base..];
}

// =============================================================================
// Sorted collections (docs/SORTED.md)
//
// A comparator of the user's re-enters the VM and may collect. The
// natives that update a sorted collection more than once in one call
// keep each intermediate collection on a root scope (GC.md §11.5,
// class 4); `subseq` and `rsubseq` gather the tree's own entries and
// build the result after the last comparison.
// =============================================================================

/// The entries of a hash map, record or sorted map, in its order.
const MapEntries = union(enum) {
    champ: champ_mod.MapIter,
    sorted: sorted_mod.Iter,

    fn of(m: Value) ?MapEntries {
        return switch (m.kind()) {
            .persistent_map => .{ .champ = champ_mod.mapIter(m) },
            .record => .{ .champ = champ_mod.mapIter(record_mod.fieldsOf(m)) },
            .sorted_map => .{ .sorted = sorted_mod.Iter.init(m, true) },
            else => null,
        };
    }

    fn next(self: *MapEntries) ?sorted_mod.Entry {
        switch (self.*) {
            .champ => |*it| {
                const e = it.next() orelse return null;
                return .{ .key = e.key, .value = e.value };
            },
            .sorted => |*it| return it.next(),
        }
    }
};

fn isReversible(k: Kind) bool {
    return k == .persistent_vector or sorted_mod.isSortedKind(k);
}

/// The comparator a `-by` constructor keeps: `compare` itself is the
/// natural order, kept as nil (SORTED.md §4).
fn comparatorArg(f: Value) Value {
    if (f.kind() == .native_fn and vm_mod.asNativeFn(f).call == &fnCompare) return value_mod.nilValue();
    return f;
}

/// `coll`, a sorted map or set, with `items` added: key-value pairs
/// for a map (an odd count is `:arity-mismatch`), elements for a set.
fn sortedAddAll(vm: *VM, coll: Value, items: []const Value) VmError!Value {
    const is_map = coll.kind() == .sorted_map;
    if (is_map and items.len % 2 != 0) return VmError.ArityMismatch;
    const heap = vm.ensureHeap();
    const order = vm_mod.SortedOrder.of(vm, coll);
    const collects = !order.comparator.isNil();
    const scope = vm.rootScope();
    defer scope.release();
    var acc = coll;
    if (collects) try scope.push(acc);
    var i: usize = 0;
    while (i < items.len) : (i += if (is_map) 2 else 1) {
        acc = (if (is_map)
            sorted_mod.assoc(heap, acc, items[i], items[i + 1], order)
        else
            sorted_mod.conj(heap, acc, items[i], order)) catch |err| return vm_mod.sortedFailure(err);
        if (collects) try scope.push(acc);
    }
    return acc;
}

/// `coll`, a sorted map or set, without `keys`.
fn sortedRemoveAll(vm: *VM, coll: Value, keys: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const order = vm_mod.SortedOrder.of(vm, coll);
    const collects = !order.comparator.isNil();
    const scope = vm.rootScope();
    defer scope.release();
    var acc = coll;
    for (keys) |k| {
        acc = sorted_mod.without(heap, acc, k, order) catch |err| return vm_mod.sortedFailure(err);
        if (collects) try scope.push(acc);
    }
    return acc;
}

fn sortedFrom(vm: *VM, kind: Kind, comparator: Value, items: []const Value) VmError!Value {
    const empty = sorted_mod.empty(vm.ensureHeap(), kind, comparator) catch return VmError.OutOfMemory;
    return sortedAddAll(vm, empty, items);
}

/// `(sorted-map & kvs)`, `(sorted-map-by f & kvs)`,
/// `(sorted-set & xs)`, `(sorted-set-by f & xs)`: a later equal key
/// replaces the value and keeps the first key object.
fn fnSortedMap(vm: *VM, args: []const Value) VmError!Value {
    return sortedFrom(vm, .sorted_map, value_mod.nilValue(), args);
}

fn fnSortedMapBy(vm: *VM, args: []const Value) VmError!Value {
    return sortedFrom(vm, .sorted_map, comparatorArg(args[0]), args[1..]);
}

fn fnSortedSet(vm: *VM, args: []const Value) VmError!Value {
    return sortedFrom(vm, .sorted_set, value_mod.nilValue(), args);
}

fn fnSortedSetBy(vm: *VM, args: []const Value) VmError!Value {
    return sortedFrom(vm, .sorted_set, comparatorArg(args[0]), args[1..]);
}

/// The relation a `subseq` test names when it is one of `<`, `<=`,
/// `>`, `>=`.
const Relation = enum { lt, lte, gt, gte };

fn relationOf(f: Value) ?Relation {
    if (f.kind() != .native_fn) return null;
    const call = vm_mod.asNativeFn(f).call;
    if (call == &fnLt) return .lt;
    if (call == &fnLte) return .lte;
    if (call == &fnGt) return .gt;
    if (call == &fnGte) return .gte;
    return null;
}

/// One bound of a `subseq`: whether `(test (cmp k key) 0)` holds. A
/// test other than the four relations is called on the comparison's
/// sign (class 2: its arguments are immediates).
const Bound = struct {
    vm: *VM,
    order: vm_mod.SortedOrder,
    test_fn: Value,
    key: Value,

    fn holds(b: Bound, k: Value) VmError!bool {
        const o = try b.order.order(k, b.key);
        if (relationOf(b.test_fn)) |r| return switch (r) {
            .lt => o == .lt,
            .lte => o != .gt,
            .gt => o == .gt,
            .gte => o != .lt,
        };
        const sign = value_mod.fromFixnum(switch (o) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        }).?;
        return (try b.vm.callValue(b.test_fn, &.{ sign, value_mod.fromFixnum(0).? })).isTruthy();
    }
};

/// `(subseq sc test key)` / `(subseq sc start-test start-key end-test
/// end-key)`, and `rsubseq` descending (SORTED.md §5): Clojure's
/// walks, returning a list of entries or nil.
fn subseqImpl(vm: *VM, args: []const Value, ascending: bool) VmError!Value {
    if (args.len == 4) return VmError.ArityMismatch;
    const sc = args[0];
    if (!sorted_mod.isSortedKind(sc.kind())) return VmError.KindMismatch;
    const order = vm_mod.SortedOrder.of(vm, sc);
    var found: std.ArrayList(sorted_mod.Entry) = .empty;
    defer found.deinit(vm.allocator);
    if (args.len == 3) {
        const b: Bound = .{ .vm = vm, .order = order, .test_fn = args[1], .key = args[2] };
        const r = relationOf(args[1]);
        // `subseq` starts at the key for `>` and `>=`, `rsubseq` for
        // `<` and `<=`; any other test walks from the first entry.
        const from_key = if (r) |rel| (if (ascending) rel == .gt or rel == .gte else rel == .lt or rel == .lte) else false;
        if (from_key) {
            var it = try sorted_mod.Iter.from(sc, b.key, ascending, order);
            if (it.next()) |e| if (try b.holds(e.key)) found.append(vm.allocator, e) catch return VmError.OutOfMemory;
            while (it.next()) |e| found.append(vm.allocator, e) catch return VmError.OutOfMemory;
        } else {
            var it = sorted_mod.Iter.init(sc, ascending);
            while (it.next()) |e| {
                if (!try b.holds(e.key)) break;
                found.append(vm.allocator, e) catch return VmError.OutOfMemory;
            }
        }
    } else {
        const start: Bound = .{ .vm = vm, .order = order, .test_fn = args[1], .key = args[2] };
        const end: Bound = .{ .vm = vm, .order = order, .test_fn = args[3], .key = args[4] };
        const near, const far = if (ascending) .{ start, end } else .{ end, start };
        var it = try sorted_mod.Iter.from(sc, near.key, ascending, order);
        var next = it.next();
        if (next) |e| if (!try near.holds(e.key)) {
            next = it.next();
        };
        while (next) |e| : (next = it.next()) {
            if (!try far.holds(e.key)) break;
            found.append(vm.allocator, e) catch return VmError.OutOfMemory;
        }
    }
    return entriesList(vm, sc.kind() == .sorted_map, found.items);
}

fn fnSubseq(vm: *VM, args: []const Value) VmError!Value {
    return subseqImpl(vm, args, true);
}

fn fnRsubseq(vm: *VM, args: []const Value) VmError!Value {
    return subseqImpl(vm, args, false);
}

/// The list of `entries` (`[k v]` vectors for a map, the keys for a
/// set), or nil when there are none. Nothing calls back in while it
/// builds.
fn entriesList(vm: *VM, is_map: bool, entries: []const sorted_mod.Entry) VmError!Value {
    if (entries.len == 0) return value_mod.nilValue();
    const items = vm.allocator.alloc(Value, entries.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(items);
    for (items, entries) |*slot, e| slot.* = if (is_map)
        vector_mod.fromSlice(vm.ensureHeap(), &.{ e.key, e.value }) catch return VmError.OutOfMemory
    else
        e.key;
    return buildListFromSlice(vm, items);
}

/// `(rseq rev)` → the elements of a vector or sorted collection last
/// first, nil when it is empty; anything else is `:kind-mismatch`, as
/// Clojure's `Reversible` requires.
fn fnRseq(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    switch (c.kind()) {
        .persistent_vector => {
            const n = vector_mod.count(c);
            if (n == 0) return value_mod.nilValue();
            const items = vm.allocator.alloc(Value, n) catch return VmError.OutOfMemory;
            defer vm.allocator.free(items);
            for (items, 0..) |*slot, i| slot.* = vector_mod.nth(c, n - 1 - i);
            return buildListFromSlice(vm, items);
        },
        .sorted_map, .sorted_set => {
            const entries = vm.allocator.alloc(sorted_mod.Entry, sorted_mod.count(c)) catch return VmError.OutOfMemory;
            defer vm.allocator.free(entries);
            var it = sorted_mod.Iter.init(c, false);
            for (entries) |*slot| slot.* = it.next().?;
            return entriesList(vm, c.kind() == .sorted_map, entries);
        },
        else => return VmError.KindMismatch,
    }
}

// =============================================================================
// Typed vectors (docs/TYPED_VECTOR.md §7)
//
// `i64-vector` / `f64-vector` / `typed-vector?` / `typed-vector-type`
// are `nexis.core` natives; `sum` / `dot` / `scale` / `map` are the
// `nexis.simd` kernels. A typed vector is a seqable receiver through
// `makeSeqIter`, so every generic sequence native works on it.
// =============================================================================

fn isTypedVector(k: Kind) bool {
    return k == .typed_vector;
}

/// An `i64` element from a Value: a fixnum, or a bignum within
/// `i64`. Anything else is `:kind-mismatch`.
fn i64Elem(v: Value) VmError!i64 {
    return typed_vector_mod.i64FromValue(v) orelse VmError.KindMismatch;
}

/// An `f64` element from a Value: any number, widened.
fn f64Elem(v: Value) VmError!f64 {
    return typed_vector_mod.f64FromValue(v) orelse VmError.KindMismatch;
}

/// `(i64-vector coll)`: an `i64` typed vector of the integers in
/// `coll`, any seqable.
fn fnI64Vector(vm: *VM, args: []const Value) VmError!Value {
    var elems = try typedElems(i64, vm, args[0], i64Elem);
    defer elems.deinit(vm.allocator);
    return typed_vector_mod.fromI64Slice(vm.ensureHeap(), elems.items) catch VmError.OutOfMemory;
}

/// `(f64-vector coll)`: an `f64` typed vector of the numbers in
/// `coll`, any seqable; integers widen.
fn fnF64Vector(vm: *VM, args: []const Value) VmError!Value {
    var elems = try typedElems(f64, vm, args[0], f64Elem);
    defer elems.deinit(vm.allocator);
    return typed_vector_mod.fromF64Slice(vm.ensureHeap(), elems.items) catch VmError.OutOfMemory;
}

/// The elements of `coll`, any seqable, made `T`s as the walk hands
/// them out. `i64-vector` and `f64-vector` consume `coll`: an element is
/// a number, held by nothing once it is made a `T`.
fn typedElems(comptime T: type, vm: *VM, coll: Value, comptime elem: fn (Value) VmError!T) VmError!std.ArrayList(T) {
    const scope = vm.rootScope();
    defer scope.release();
    var it = try consumingSeqIter(vm, coll, scope);
    var out: std.ArrayList(T) = .empty;
    errdefer out.deinit(vm.allocator);
    while (try it.next()) |v| out.append(vm.allocator, try elem(v)) catch return VmError.OutOfMemory;
    return out;
}

/// `(typed-vector-type tv)` → `:i64` or `:f64`.
fn fnTypedVectorType(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .typed_vector) return VmError.KindMismatch;
    const name = typed_vector_mod.elemType(args[0]).name();
    return vm.ensureInterner().internKeywordValue(name) catch VmError.OutOfMemory;
}

fn requireTypedVector(v: Value) VmError!void {
    if (v.kind() != .typed_vector) return VmError.KindMismatch;
}

const f64_lanes = 4;
const F64Lanes = @Vector(f64_lanes, f64);

/// Sum of an `f64` slice: four lanes, folded at the end, then the
/// tail. The association order differs from a left fold.
fn sumF64(xs: []const f64) f64 {
    var acc: F64Lanes = @splat(0.0);
    var i: usize = 0;
    while (i + f64_lanes <= xs.len) : (i += f64_lanes) {
        const lane: F64Lanes = xs[i..][0..f64_lanes].*;
        acc += lane;
    }
    var total = @reduce(.Add, acc);
    while (i < xs.len) : (i += 1) total += xs[i];
    return total;
}

/// Dot product of two `f64` slices of equal length, in lanes.
fn dotF64(xs: []const f64, ys: []const f64) f64 {
    var acc: F64Lanes = @splat(0.0);
    var i: usize = 0;
    while (i + f64_lanes <= xs.len) : (i += f64_lanes) {
        const a: F64Lanes = xs[i..][0..f64_lanes].*;
        const b: F64Lanes = ys[i..][0..f64_lanes].*;
        acc += a * b;
    }
    var total = @reduce(.Add, acc);
    while (i < xs.len) : (i += 1) total += xs[i] * ys[i];
    return total;
}

/// `(tv/sum xs)`: the exact integer sum for `i64`, a bignum when it
/// is beyond the fixnum range, as `(reduce + xs)` yields; a float
/// for `f64`. Fewer than 2^64 elements of `i64` sum to a magnitude
/// under 2^127, so the `i128` accumulator never overflows.
fn fnSimdSum(vm: *VM, args: []const Value) VmError!Value {
    try requireTypedVector(args[0]);
    switch (typed_vector_mod.elemType(args[0])) {
        .i64 => {
            var total: i128 = 0;
            for (typed_vector_mod.i64Elems(args[0])) |x| total += x;
            return bignum_mod.fromI128(vm.ensureHeap(), total) catch VmError.OutOfMemory;
        },
        .f64 => return value_mod.fromFloat(sumF64(typed_vector_mod.f64Elems(args[0]))),
    }
}

/// `acc + n` as an exact integer Value; a null `acc` is zero. Used
/// by `tv/dot` to spill an `i128` partial total into a bignum.
/// `Heap.alloc` never collects (GC.md §11.5), so the running bignum
/// needs no root while the kernel holds it.
fn spillI128(heap: *heap_mod.Heap, acc: ?Value, n: i128) VmError!Value {
    const v = bignum_mod.fromI128(heap, n) catch return VmError.OutOfMemory;
    const a = acc orelse return v;
    return bignum_mod.add(heap, a, v) catch VmError.OutOfMemory;
}

/// `(tv/dot xs ys)`: same element type (`:kind-mismatch`) and length
/// (`:invalid-argument`); result kind as `sum`, exact at any size. A
/// product of two `i64` fits `i128`; when the running total of
/// products leaves `i128` it spills into a bignum and the `i128`
/// accumulation restarts from the product that overflowed it.
fn fnSimdDot(vm: *VM, args: []const Value) VmError!Value {
    try requireTypedVector(args[0]);
    try requireTypedVector(args[1]);
    const elem = typed_vector_mod.elemType(args[0]);
    if (elem != typed_vector_mod.elemType(args[1])) return VmError.KindMismatch;
    if (typed_vector_mod.count(args[0]) != typed_vector_mod.count(args[1])) return VmError.InvalidArgument;
    switch (elem) {
        .i64 => {
            const heap = vm.ensureHeap();
            var total: i128 = 0;
            var spilled: ?Value = null;
            for (typed_vector_mod.i64Elems(args[0]), typed_vector_mod.i64Elems(args[1])) |x, y| {
                const p = @as(i128, x) * @as(i128, y);
                total = std.math.add(i128, total, p) catch blk: {
                    spilled = try spillI128(heap, spilled, total);
                    break :blk p;
                };
            }
            return spillI128(heap, spilled, total);
        },
        .f64 => return value_mod.fromFloat(dotF64(typed_vector_mod.f64Elems(args[0]), typed_vector_mod.f64Elems(args[1]))),
    }
}

/// `(tv/scale xs k)`: every element times `k`, same element type.
/// The result is an element-typed vector, so an `i64` product
/// outside `i64` has no representation and is `:arithmetic-overflow`
/// (TYPED_VECTOR.md §7.2), the one arithmetic that raises it.
fn fnSimdScale(vm: *VM, args: []const Value) VmError!Value {
    try requireTypedVector(args[0]);
    const heap = vm.ensureHeap();
    switch (typed_vector_mod.elemType(args[0])) {
        .i64 => {
            const k = try i64Elem(args[1]);
            const src = typed_vector_mod.i64Elems(args[0]);
            const out = vm.allocator.alloc(i64, src.len) catch return VmError.OutOfMemory;
            defer vm.allocator.free(out);
            for (out, src) |*slot, x| slot.* = std.math.mul(i64, x, k) catch return VmError.ArithmeticOverflow;
            return typed_vector_mod.fromI64Slice(heap, out) catch VmError.OutOfMemory;
        },
        .f64 => {
            const k = try f64Elem(args[1]);
            const src = typed_vector_mod.f64Elems(args[0]);
            const out = vm.allocator.alloc(f64, src.len) catch return VmError.OutOfMemory;
            defer vm.allocator.free(out);
            const ks: F64Lanes = @splat(k);
            var i: usize = 0;
            while (i + f64_lanes <= src.len) : (i += f64_lanes) {
                const lane: F64Lanes = src[i..][0..f64_lanes].*;
                out[i..][0..f64_lanes].* = lane * ks;
            }
            while (i < src.len) : (i += 1) out[i] = src[i] * k;
            return typed_vector_mod.fromF64Slice(heap, out) catch VmError.OutOfMemory;
        },
    }
}

/// `(tv/map f xs)`: `(f x)` over every element, collected into a
/// typed vector of the same element type under the constructor rule.
/// `xs` stays reachable through the caller's argument slot across
/// every `callValue`; the results live in a Zig slice until the
/// result vector is allocated.
fn fnSimdMap(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const xs = args[1];
    try requireTypedVector(xs);
    const heap = vm.ensureHeap();
    const n = typed_vector_mod.count(xs);
    switch (typed_vector_mod.elemType(xs)) {
        .i64 => {
            const out = vm.allocator.alloc(i64, n) catch return VmError.OutOfMemory;
            defer vm.allocator.free(out);
            var cb = vm_mod.Callback.init(vm, f, 1);
            for (out, 0..) |*slot, i| {
                const x = typed_vector_mod.nth(heap, xs, i) catch return VmError.OutOfMemory;
                slot.* = try i64Elem(try cb.call1(x));
            }
            return typed_vector_mod.fromI64Slice(heap, out) catch VmError.OutOfMemory;
        },
        .f64 => {
            const out = vm.allocator.alloc(f64, n) catch return VmError.OutOfMemory;
            defer vm.allocator.free(out);
            var cb = vm_mod.Callback.init(vm, f, 1);
            for (out, typed_vector_mod.f64Elems(xs)) |*slot, x| {
                slot.* = try f64Elem(try cb.call1(value_mod.fromFloat(x)));
            }
            return typed_vector_mod.fromF64Slice(heap, out) catch VmError.OutOfMemory;
        },
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stdlib: every core native is bound in nexis.core" {
    var dbg: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = dbg.deinit();
    const ally = dbg.allocator();
    // Var objects normally live in VM.runtime_arena (wholesale
    // freed at VM.deinit per the Namespace.deinit doc-comment).
    // Tests mirror that by using an arena for var_allocator.
    var arena = std.heap.ArenaAllocator.init(ally);
    defer arena.deinit();

    var ns = Namespace.init(ally, arena.allocator());
    defer ns.deinit();
    try installCore(&ns);
    for (core_natives) |d| {
        const v = ns.lookup(d.name) orelse return error.TestFailed;
        try testing.expect(v.bound);
        try testing.expectEqual(Kind.native_fn, v.root.kind());
        try testing.expect(!v.macro);
    }
}

test "stdlib: a native's arglists agree with the arities its row declares" {
    // STDLIB.md §10: each `[...]` of the text is one arity; params
    // before `&` are fixed, a nested vector or map one param.
    inline for (documented) |t| for (t[0], t[1]) |d, doc| {
        try testing.expect(doc.doc.len > 0);
        var min: ?usize = null;
        var max: ?usize = 0;
        var depth: usize = 0;
        var fixed: usize = 0;
        var variadic = false;
        var in_token = false;
        for (doc.arglists[1 .. doc.arglists.len - 1], 0..) |c, i| {
            const at_param = depth == 1 and !std.ascii.isWhitespace(c) and !in_token;
            switch (c) {
                '[', '{' => {
                    if (at_param and !variadic) fixed += 1;
                    depth += 1;
                    in_token = false;
                },
                ']', '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        min = @min(min orelse fixed, fixed);
                        if (variadic) max = null else if (max) |m| {
                            max = @max(m, fixed);
                        }
                        fixed = 0;
                        variadic = false;
                    }
                    in_token = false;
                },
                else => if (std.ascii.isWhitespace(c)) {
                    in_token = false;
                } else if (at_param) {
                    in_token = true;
                    if (c == '&' and (i + 1 == doc.arglists.len - 2 or std.ascii.isWhitespace(doc.arglists[i + 2]))) {
                        variadic = true;
                    } else if (!variadic) fixed += 1;
                },
            }
        }
        errdefer std.debug.print("{s}: {s}\n", .{ d.name, doc.arglists });
        try testing.expectEqual(@as(?usize, d.min_arity), min);
        try testing.expectEqual(if (d.max_arity) |m| @as(?usize, m) else null, max);
    };
}

test "stdlib: a string that is not UTF-8 seqs as :utf8-error" {
    var stub_code = [_]vm_mod.Inst{vm_mod.asm_.returnNil()};
    const stub = vm_mod.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var vm = try VM.init(testing.allocator, &stub);
    defer vm.deinit();
    const bad = try string_mod.fromBytes(vm.ensureHeap(), "a\xffb");
    try testing.expectError(VmError.Utf8Error, fnFirst(&vm, &.{bad}));
    try testing.expectError(VmError.Utf8Error, fnSeq(&vm, &.{bad}));
    const good = try string_mod.fromBytes(vm.ensureHeap(), "é");
    try testing.expectEqual(@as(u21, 0xE9), (try fnFirst(&vm, &.{good})).asChar());
}

test "stdlib: malformed UTF-8 never panics a string native or format" {
    var stub_code = [_]vm_mod.Inst{vm_mod.asm_.returnNil()};
    const stub = vm_mod.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var vm = try VM.init(testing.allocator, &stub);
    defer vm.deinit();
    const heap = vm.ensureHeap();
    // A truncated tail, a stray continuation, a lone lead, an invalid
    // byte, a surrogate, an overlong form, each with whitespace around.
    const malformed = [_][]const u8{ "ab\xe2\x82", "\x82ab", "\xe2\x82", "a\xffb", "\xed\xa0\x80", "\xc0\xaf", " \xe2\x82 ", "\xe2\x82\n", " \x82" };
    var pool: [malformed.len + 4]Value = undefined;
    for (malformed, 0..) |m, i| pool[i] = try string_mod.fromBytes(heap, m);
    pool[malformed.len] = try string_mod.fromBytes(heap, "a b");
    pool[malformed.len + 1] = try string_mod.fromBytes(heap, "");
    pool[malformed.len + 2] = value_mod.fromFixnum(1).?;
    pool[malformed.len + 3] = value_mod.fromChar('a').?;
    for (&string_natives) |*d| {
        const max = d.max_arity orelse 3;
        for (d.min_arity..max + 1) |arity| {
            var idx: [3]usize = @splat(0);
            while (true) {
                var args: [3]Value = undefined;
                for (0..arity) |k| args[k] = pool[idx[k]];
                _ = d.call(&vm, args[0..arity]) catch {};
                var k: usize = 0;
                while (k < arity) : (k += 1) {
                    idx[k] += 1;
                    if (idx[k] < pool.len) break;
                    idx[k] = 0;
                }
                if (k == arity) break;
            }
        }
    }
    for ([_][]const u8{ "%.1s", "%.3s", "%5s", "%-5s|" }) |f| {
        const fmt = try string_mod.fromBytes(heap, f);
        for (pool[0..malformed.len]) |m| if (fnFormat(&vm, &.{ fmt, m })) |_| {} else |e| try testing.expectEqual(VmError.Utf8Error, e);
    }
    // Bytes that are not UTF-8 stop a trim and are never trimmed.
    const t = try fnStringTrim(&vm, &.{try string_mod.fromBytes(heap, " \xe2\x82 \x82 ")});
    try testing.expectEqualStrings("\xe2\x82 \x82", string_mod.asBytes(t));
    const nl = try fnStringTrimNewline(&vm, &.{pool[7]});
    try testing.expectEqualStrings("\xe2\x82", string_mod.asBytes(nl));
}

test "stdlib: name of a string is the string itself" {
    var stub_code = [_]vm_mod.Inst{vm_mod.asm_.returnNil()};
    const stub = vm_mod.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var vm = try VM.init(testing.allocator, &stub);
    defer vm.deinit();
    const s = try string_mod.fromBytes(vm.ensureHeap(), "abc");
    const named = try fnName(&vm, &.{s});
    try testing.expectEqual(s.payload, named.payload);
}

test "stdlib: readLine returns a line longer than the reader's buffer whole" {
    var buf: [8]u8 = undefined;
    var r: std.testing.Reader = .init(&buf, &.{ .{ .buffer = "short\r\n0123456789abcdef" }, .{ .buffer = "ghij\nthe-last-line" } });
    var overflow: std.ArrayList(u8) = .empty;
    defer overflow.deinit(testing.allocator);
    try testing.expectEqualStrings("short", (try readLine(&r.interface, &overflow, testing.allocator)).?);
    try testing.expectEqualStrings("0123456789abcdefghij", (try readLine(&r.interface, &overflow, testing.allocator)).?);
    try testing.expectEqualStrings("the-last-line", (try readLine(&r.interface, &overflow, testing.allocator)).?);
    try testing.expect(try readLine(&r.interface, &overflow, testing.allocator) == null);
}

test "stdlib: nativeFnValue round-trips" {
    const v = vm_mod.nativeFnValue(&core_natives[3]);
    try testing.expectEqual(Kind.native_fn, v.kind());
    const back = vm_mod.asNativeFn(v);
    try testing.expectEqualStrings("first", back.name);
}

test "stdlib: decimalLen agrees with printInt at every power of ten and the i64 ends" {
    var buf: [24]u8 = undefined;
    var x: i64 = 1;
    for (0..19) |_| {
        for ([_]i64{ x - 1, x, -x, -(x - 1) }) |v| try std.testing.expectEqual(std.fmt.printInt(&buf, v, 10, .lower, .{}), decimalLen(v));
        x *%= 10;
    }
    for ([_]i64{ std.math.maxInt(i64), std.math.minInt(i64) }) |v| try std.testing.expectEqual(std.fmt.printInt(&buf, v, 10, .lower, .{}), decimalLen(v));
}

/// A runtime the image tests boot: a VM with its registry, the host
/// macros and a loader, on an allocator that checks for leaks.
const ImageTestRuntime = struct {
    gpa: std.heap.SafeAllocator,
    v: VM,
    host_macros: expand_mod.HostMacroTable,
    loader: loader_mod.Loader,

    /// In place: the loader keeps pointers into the runtime.
    fn init(rt: *ImageTestRuntime) !void {
        rt.gpa = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
        const gpa = rt.gpa.allocator();
        rt.v = try VM.init(gpa, &VM.idle_routine);
        const interner = rt.v.ensureInterner();
        const registry = try rt.v.ensureRegistry();
        rt.host_macros = try expand_mod.defaultMacros(gpa);
        rt.loader = loader_mod.Loader.init(gpa, rt.v.runtime_arena.allocator(), testing.io, &.{}, &rt.v, interner, registry, &rt.host_macros);
    }

    fn deinit(rt: *ImageTestRuntime) void {
        rt.loader.deinit();
        rt.host_macros.deinit(rt.gpa.allocator());
        rt.v.deinit();
        if (rt.gpa.deinit() != 0) @panic("the runtime leaked");
    }

    /// `src`'s value printed, evaluated in `ns`.
    fn eval(rt: *ImageTestRuntime, ns: []const u8, src: []const u8) ![]u8 {
        const saved = rt.loader.registry.current;
        defer rt.loader.registry.current = saved;
        rt.loader.registry.current = try rt.loader.registry.getOrCreate(ns, rt.loader.registry.core);
        const info: vm_mod.SourceInfo = .{ .path = "<test>", .text = src };
        const v = try rt.loader.evalSource(&info, .{ .allocator = rt.v.runtime_arena.allocator() });
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        errdefer w.deinit();
        try format_mod.format(v, .readable, &w.writer, rt.v.ensureInterner());
        return w.toOwnedSlice();
    }
};

/// `bootFrom` as the first boot of a process: the names it generates
/// count from zero, as the build's boot that wrote the image did.
fn bootFirst(loader: *loader_mod.Loader, bytes: []const u8) !void {
    const saved = .{ expand_mod.gensym_counter, gensym_next };
    expand_mod.gensym_counter = 0;
    gensym_next = 0;
    defer {
        expand_mod.gensym_counter = @max(expand_mod.gensym_counter, saved[0]);
        gensym_next = @max(gensym_next, saved[1]);
    }
    try bootFrom(loader, bytes);
}

fn expectVerified(a: *VM, b: *VM) !void {
    var why: []const u8 = "";
    image_mod.verify(testing.allocator, a, b, &why) catch |err| {
        std.debug.print("image differs: {s}\n", .{why});
        testing.allocator.free(why);
        return err;
    };
}

test "stdlib: the embedded image loads what booting the sources leaves" {
    try testing.expect(image_mod.matches(image, &embedded));
    var a: ImageTestRuntime = undefined;
    try a.init();
    defer a.deinit();
    try bootFirst(&a.loader, "");
    var b: ImageTestRuntime = undefined;
    try b.init();
    defer b.deinit();
    try boot(&b.loader);
    try expectVerified(&a.v, &b.v);
    // An image from another build boots the sources.
    var other = try testing.allocator.dupe(u8, image);
    defer testing.allocator.free(other);
    other[magic_offset] +%= 1;
    try testing.expect(!image_mod.matches(other, &embedded));
    var c: ImageTestRuntime = undefined;
    try c.init();
    defer c.deinit();
    try bootFirst(&c.loader, other);
    try expectVerified(&a.v, &c.v);
}

/// Where the fingerprint of an image starts: past the magic and the
/// format number.
const magic_offset = 12;

test "stdlib: an image carries every kind of value it writes, with its sharing" {
    const extra: image_mod.Source = .{ .ns = "image.test", .info = .{ .path = "image_test.nx", .text =
        \\(def big 123456789012345678901234567890)
        \\(def re #"a+b")
        \\(defrecord P [x y])
        \\(def p (->P 1 [2 3]))
        \\(defprotocol Shape (area [s]) (label [s]))
        \\(extend-protocol Shape P (area [s] (:x s)) :any (label [_] :other))
        \\(def shared (let [c (atom [])] [(fn [x] (swap! c conj x)) (fn [] @c)]))
        \\(def data ^{:tag :v} [1 2.5 \c "s" :k :q/k 'sym 'q/sym '(1 ^:m (2 3)) #{1 2} {:a {:b [nil true false]}} -0.0])
        \\(defn count-down [n] (if (zero? n) :done (recur (dec n))))
        \\(def self-ref (fn me [n] (if (zero? n) 0 (+ 1 (me (dec n))))))
        \\(def ^:dynamic *d* 1)
        \\(def ^:private hidden (list 1 2 3))
        \\(defmacro twice [x] `(do ~x ~x))
        \\(def same-twice [data data])
    } };
    const sources = embedded ++ [_]image_mod.Source{extra};
    const gpa = testing.allocator;

    var a: ImageTestRuntime = undefined;
    try a.init();
    defer a.deinit();
    try installNatives(a.loader.registry);
    var natives = try image_mod.NativeIndex.scan(gpa, a.loader.registry);
    defer natives.deinit(gpa);
    try bootSources(&a.loader);
    a.loader.registry.current = try a.loader.registry.getOrCreate(extra.ns, a.loader.registry.core);
    _ = try a.loader.evalSource(&sources[sources.len - 1].info, .{ .allocator = a.v.runtime_arena.allocator() });
    a.loader.registry.current = a.loader.registry.core;
    var why: []const u8 = "";
    const bytes = try image_mod.write(gpa, &a.v, &natives, &sources, .{ .auto_gensyms = 0, .gensyms = 0 }, &why);
    defer gpa.free(bytes);

    var b: ImageTestRuntime = undefined;
    try b.init();
    defer b.deinit();
    try installNatives(b.loader.registry);
    _ = try image_mod.load(&b.v, bytes, &sources);
    try expectVerified(&a.v, &b.v);

    // What the loaded values do.
    const probe =
        \\[((first shared) 5) ((first shared) 6) ((second shared) )
        \\ (area p) (label 1) (re-find re "xaab") (+ big 1) (count-down 3) (self-ref 4)
        \\ (meta data) (meta (nth (nth data 8) 1)) (identical? (first same-twice) (second same-twice))
        \\ (let [n (atom 0)] (twice (swap! n inc)) @n) (:dynamic (meta #'*d*)) (count (ns-publics 'image.test))]
    ;
    const want = try a.eval("image.test", probe);
    defer gpa.free(want);
    const got = try b.eval("image.test", probe);
    defer gpa.free(got);
    try testing.expectEqualStrings(want, got);
}

test "stdlib: a truncated image fails to load as Corrupt, never a crash" {
    var cut: usize = 64;
    while (cut < image.len) : (cut += image.len / 23) {
        var rt: ImageTestRuntime = undefined;
        try rt.init();
        defer rt.deinit();
        try installNatives(rt.loader.registry);
        try testing.expectError(error.Corrupt, image_mod.load(&rt.v, image[0..cut], &embedded));
    }
}

test "stdlib: an image holding a routine that does not verify is refused, not loaded" {
    if (!image_mod.verify_routines) return error.SkipZigTest;
    // The first instruction of `interpose`'s routine, the last record
    // that names it, made other than primary: the image is otherwise
    // whole, and only the routine's verification can tell.
    const bytes = try testing.allocator.dupe(u8, image);
    defer testing.allocator.free(bytes);
    const name = "interpose";
    var record: [4 + name.len]u8 = undefined;
    std.mem.writeInt(u32, record[0..4], name.len, .little);
    @memcpy(record[4..], name);
    var at = (std.mem.findLast(u8, bytes, &record) orelse return error.TestUnexpectedResult) + record.len;
    at += 2 + 2 + 1 + 2; // slot count, fixed arity, variadic, upvalue count
    at += 1 + @as(usize, if (bytes[at] != 0) 8 else 0); // the origin
    at += 4; // the source
    try testing.expect(std.mem.readInt(u32, bytes[at..][0..4], .little) > 0);
    at += 4;
    bytes[at] |= 1; // the instruction's kind, its low four bits
    var rt: ImageTestRuntime = undefined;
    try rt.init();
    defer rt.deinit();
    try installNatives(rt.loader.registry);
    try testing.expectError(error.UnfitRoutine, image_mod.load(&rt.v, bytes, &embedded));
}

test "stdlib: an image holding a closure whose cells are not its routine's upvalues is refused" {
    if (!image_mod.verify_routines) return error.SkipZigTest;
    // `interpose`'s routine, the last record that names it, made to
    // take one upvalue more than its closure (the Var's root) carries.
    const bytes = try testing.allocator.dupe(u8, image);
    defer testing.allocator.free(bytes);
    const name = "interpose";
    var record: [4 + name.len]u8 = undefined;
    std.mem.writeInt(u32, record[0..4], name.len, .little);
    @memcpy(record[4..], name);
    const at = (std.mem.findLast(u8, bytes, &record) orelse return error.TestUnexpectedResult) + record.len + 2 + 2 + 1;
    const count = std.mem.readInt(u16, bytes[at..][0..2], .little);
    std.mem.writeInt(u16, bytes[at..][0..2], count + 1, .little);
    var rt: ImageTestRuntime = undefined;
    try rt.init();
    defer rt.deinit();
    try installNatives(rt.loader.registry);
    try testing.expectError(error.UnfitRoutine, image_mod.load(&rt.v, bytes, &embedded));
}

test "stdlib: the image refuses what it cannot carry" {
    const gpa = testing.allocator;
    var a: ImageTestRuntime = undefined;
    try a.init();
    defer a.deinit();
    try installNatives(a.loader.registry);
    var natives = try image_mod.NativeIndex.scan(gpa, a.loader.registry);
    defer natives.deinit(gpa);
    try bootSources(&a.loader);
    const sorted = try a.eval("nexis.core", "(def image-test-sorted (sorted-map 1 2))");
    gpa.free(sorted);
    var why: []const u8 = "";
    try testing.expectError(error.Unsupported, image_mod.write(gpa, &a.v, &natives, &embedded, .{ .auto_gensyms = 0, .gensyms = 0 }, &why));
    try testing.expectEqualStrings("sorted_map", why);
}

test "stdlib: the image refuses sorted-map metadata as it refuses a sorted map" {
    const gpa = testing.allocator;
    var a: ImageTestRuntime = undefined;
    try a.init();
    defer a.deinit();
    try installNatives(a.loader.registry);
    var natives = try image_mod.NativeIndex.scan(gpa, a.loader.registry);
    defer natives.deinit(gpa);
    try bootSources(&a.loader);
    const meta = try a.eval("nexis.core", "(def image-test-sorted-meta (with-meta [1] (sorted-map :a 1)))");
    gpa.free(meta);
    var why: []const u8 = "";
    try testing.expectError(error.Unsupported, image_mod.write(gpa, &a.v, &natives, &embedded, .{ .auto_gensyms = 0, .gensyms = 0 }, &why));
    try testing.expectEqualStrings("sorted_map", why);
}

test "stdlib: reduce, mapv, filterv and the lazy producers call a closure in batches with one call's results" {
    // Expected values from babashka and JVM Clojure 1.12.6.
    const gpa = testing.allocator;
    var rt: ImageTestRuntime = undefined;
    try rt.init();
    defer rt.deinit();
    try boot(&rt.loader);
    const cases = [_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "(defrecord R [v])", .want = "user.R" },
        // `reduced` at the first element, the last of a run, the first
        // of the next and one past, over a vector, a lazy seq, an
        // unrealized range, with and without init, and a repeat.
        .{
            .src =
            \\(vec (for [k [0 31 32 33]]
            \\  (let [f (fn [a x] (if (= x k) (reduced [a x]) (+ a x)))]
            \\    [(reduce f 0 (vec (range 64))) (reduce f 0 (map identity (vec (range 64)))) (reduce f 0 (range 64)) (reduce f (range 64)) (reduce f 0 (repeat 64 k))])))
            ,
            .want = "[[[0 0] [0 0] [0 0] 2016 [0 0]] [[465 31] [465 31] [465 31] [465 31] [0 31]] [[496 32] [496 32] [496 32] [496 32] [0 32]] [[528 33] [528 33] [528 33] [528 33] [0 33]]]",
        },
        // A record that is not `reduced` goes on.
        .{
            .src = "(let [f (fn [a x] (if (= x 31) (->R 1000) (+ (if (number? a) a (:v a)) x)))] [(reduce f 0 (range 64)) (reduce f 0 (vec (range 64))) (reduce f 0 (map identity (vec (range 64))))])",
            .want = "[2520 2520 2520]",
        },
        // A throw in a chunk's 9th call, walked twice: the second walk
        // ends at the chunk before (docs/LAZY.md §4).
        .{
            .src =
            \\(vec (for [sieve [map filter remove]]
            \\  (let [n (atom 0) s (sieve (fn [x] (swap! n inc) (if (= x 40) (throw :t) (even? x))) (vec (range 64)))]
            \\    [(try (doall s) (catch any e e)) @n (try (doall s) (catch any e e)) @n])))
            ,
            .want = "[[:t 41 (true false true false true false true false true false true false true false true false true false true false true false true false true false true false true false true false) 41] [:t 41 (0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30) 41] [:t 41 (1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31) 41]]",
        },
        .{
            .src = "[(mapv (fn [x] (* 2 x)) (vec (range 70))) (mapv (fn [x] (* 2 x)) (map inc (range 40))) (filterv (fn [x] (odd? x)) (vec (range 70))) (vec (remove (fn [x] (odd? x)) (vec (range 40))))]",
            .want = "[[0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64 66 68 70 72 74 76 78 80 82 84 86 88 90 92 94 96 98 100 102 104 106 108 110 112 114 116 118 120 122 124 126 128 130 132 134 136 138] [2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64 66 68 70 72 74 76 78 80] [1 3 5 7 9 11 13 15 17 19 21 23 25 27 29 31 33 35 37 39 41 43 45 47 49 51 53 55 57 59 61 63 65 67 69] [0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38]]",
        },
        // An unrealized range, computed a run at a time.
        .{
            .src = "[(mapv (fn [x] (* 2 x)) (range 70)) (filterv (fn [x] (odd? x)) (range 3 80 7)) (mapv (fn [x] x) (range 0)) (mapv (fn [x] (- x)) (range 10 0 -3)) (filterv (fn [x] (even? x)) (range 65))]",
            .want = "[[0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64 66 68 70 72 74 76 78 80 82 84 86 88 90 92 94 96 98 100 102 104 106 108 110 112 114 116 118 120 122 124 126 128 130 132 134 136 138] [3 17 31 45 59 73] [] [-10 -7 -4 -1] [0 2 4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 34 36 38 40 42 44 46 48 50 52 54 56 58 60 62 64]]",
        },
        // A throw past the native, and one caught inside the callee.
        .{
            .src = "[(try (mapv (fn [x] (if (= x 40) (throw :t) x)) (vec (range 64))) (catch any e e)) (try (reduce (fn [a x] (if (= x 33) (throw :t) (+ a x))) 0 (range 64)) (catch any e e)) (mapv (fn [x] (try (if (odd? x) (throw :t) x) (catch any e :c))) (vec (range 8)))]",
            .want = "[:t :t [0 :c 2 :c 4 :c 6 :c]]",
        },
        // A batch inside a batch's callee, and a map's built entries.
        .{
            .src = "[(mapv (fn [x] (reduce (fn [a y] (+ a y)) 0 (mapv (fn [y] (* x y)) (vec (range 40))))) (vec (range 5))) (filterv (fn [[k v]] (odd? v)) {:a 1 :b 2 :c 3})]",
            .want = "[[0 780 1560 2340 3120] [[:a 1] [:c 3]]]",
        },
    };
    for (cases) |c| {
        const got = try rt.eval("user", c.src);
        defer gpa.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "stdlib: reduce over an infinite range past the fixnum range keeps its element and accumulator rooted" {
    // `(range)` reaches the bignums only after 2^47 elements, so the
    // ranges here start where they are: just below the fixnum limit,
    // and at 2^131072, whose every element is a block past
    // `max_small_block` that the heap hands back to its allocator when
    // it is freed. The callback clears its element at its last use and
    // then allocates past a collection's trigger.
    var rt: ImageTestRuntime = undefined;
    try rt.init();
    defer rt.deinit();
    try boot(&rt.loader);
    const defs = try rt.eval("user",
        \\(do (def big (nth (iterate (fn [x] (* x x)) 2) 17))
        \\    (defn step [k] (fn [acc x] (let [d (k x)] (vec (range 20000)) (if (= 6 (count acc)) (reduced (conj acc d)) (conj acc d)))))
        \\    (def near (step str))
        \\    (def far (step (fn [x] (- x big)))))
    );
    defer testing.allocator.free(defs);
    const vm = &rt.v;
    vm.setGcPolicy(vm_mod.GcPolicy.stress);
    for ([_]struct { f: []const u8, start: []const u8, want: []const u8 }{
        .{ .f = "near", .start = "140737488355325", .want = "[\"140737488355325\" \"140737488355326\" \"140737488355327\" \"140737488355328\" \"140737488355329\" \"140737488355330\" \"140737488355331\"]" },
        .{ .f = "far", .start = "big", .want = "[0 1 2 3 4 5 6]" },
    }) |case| {
        const f = try rt.loader.evalSource(&.{ .path = "<test>", .text = case.f }, .{ .allocator = vm.runtime_arena.allocator() });
        const start = try rt.loader.evalSource(&.{ .path = "<test>", .text = case.start }, .{ .allocator = vm.runtime_arena.allocator() });
        const s = try seq_mod.make(vm, seq_mod.op_range_inf, &.{start});
        const cycles = vm.gc_cycles;
        const got = try fnReduce(vm, &.{ f, try vector_mod.empty(vm.ensureHeap()), s });
        try testing.expect(vm.gc_cycles >= cycles + 7);
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        defer w.deinit();
        try format_mod.format(got, .readable, &w.writer, vm.ensureInterner());
        try testing.expectEqualStrings(case.want, w.written());
    }
}

test "stdlib: the civil calendar agrees with std.time.epoch and walks day by day" {
    var day: i64 = 0;
    while (day < 60_000) : (day += 1) {
        const yd = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
        const md = yd.calculateMonthDay();
        const c = civilFromDays(day);
        try testing.expectEqual(@as(i64, yd.year), c.year);
        try testing.expectEqual(@as(u32, @backingInt(md.month)), c.month);
        try testing.expectEqual(@as(u32, md.day_index) + 1, c.day);
    }
    // Every day of years -2500 to 6500 follows the one before it.
    var prev = civilFromDays(-1_633_000);
    day = -1_632_999;
    while (day < 1_660_000) : (day += 1) {
        const c = civilFromDays(day);
        try testing.expectEqual(day, daysFromCivil(c.year, c.month, c.day));
        if (c.day == 1) {
            try testing.expectEqual(daysInMonth(prev.year, prev.month), prev.day);
            try testing.expectEqual(if (c.month == 1) prev.year + 1 else prev.year, c.year);
        } else try testing.expectEqual(prev.day + 1, c.day);
        prev = c;
    }
}

test "stdlib: an instant's text reads back as the same instant" {
    var buf: [40]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0x1505);
    for (0..20_000) |i| {
        const ms: i64 = switch (i) {
            0 => value_mod.fixnum_min,
            1 => value_mod.fixnum_max,
            else => rng.random().intRangeAtMost(i64, value_mod.fixnum_min, value_mod.fixnum_max),
        };
        var w: std.Io.Writer = .fixed(&buf);
        try writeInstant(&w, ms);
        try testing.expectEqual(ms, parseInstant(w.buffered()).?);
    }
}
