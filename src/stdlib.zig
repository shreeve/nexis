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
// nil, lists, vectors, maps, records, sets (hash or sorted) and
// strings behave the same way in every sequence function. Arithmetic delegates to the
// VM's numeric tower. nil is the empty sequence, as in Clojure:
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
const vector_mod = @import("coll/vector.zig");
const typed_vector_mod = @import("coll/typed_vector.zig");
const bignum_mod = @import("bignum.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const intern_mod = @import("intern.zig");
const db_mod = @import("db.zig");
const codec_mod = @import("codec.zig");
const heap_mod = @import("heap.zig");
const dispatch_mod_alias = @import("dispatch.zig");
const atom_mod = @import("atom.zig");
const string_mod = @import("string.zig");
const format_mod = @import("format.zig");
const record_mod = @import("record.zig");
const protocol_mod = @import("protocol.zig");
const nextomic_mod = @import("nextomic/root.zig");
const transient_mod = @import("coll/transient.zig");
const loader_mod = @import("loader.zig");
const stack_guard = @import("stack.zig");

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
// once. `table` turns it into static descriptors (immortal, so a
// `.native_fn` Value can point at one); a descriptor outside
// nexis.core is named `ns/name` for traces and printing.

fn table(comptime ns: []const u8, comptime entries: anytype) [entries.len]NativeFn {
    var out: [entries.len]NativeFn = undefined;
    inline for (entries, 0..) |e, i| out[i] = .{
        .name = if (ns.len == 0) e[0] else ns ++ "/" ++ e[0],
        .min_arity = e[1],
        .max_arity = e[2],
        .call = e[3],
    };
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
    try installTable(ns, &core_natives);
    if (ns.registry) |registry| try installTable(try registry.getOrCreate("nexis.simd", ns), &simd_natives);
}

/// Install every namespace of the standard library into the
/// loader's registry, bootstrap the embedded sources into theirs,
/// and mark each namespace there loaded, so a `require` of one only
/// aliases it. The CLI and the test harness boot through here. A
/// failure is a bug in an embedded source; `loader.diagnostic` says
/// where.
pub fn boot(loader: *loader_mod.Loader) !void {
    const registry = loader.registry;
    const core = registry.core;
    try installCore(core);
    try installTable(try registry.getOrCreate("db", core), &db_natives);
    try installTable(try registry.getOrCreate("nexis.string", core), &string_natives);
    try installTable(try registry.getOrCreate("nexis.math", core), &math_natives);
    try installTable(try registry.getOrCreate("nexis.internal", core), &internal_natives);
    try nextomic_mod.natives.install(try registry.getOrCreate("nextomic", core));
    const saved = registry.current;
    defer registry.current = saved;
    for (&embedded) |*e| {
        registry.current = try registry.getOrCreate(e.ns, core);
        _ = try loader.evalSource(&e.info, .{ .allocator = loader.persistent_allocator, .declare = false });
    }
    var names = registry.map.keyIterator();
    while (names.next()) |name| try loader.markLoaded(name.*);
}

/// The parts of the library written in nexis, embedded at compile
/// time and bootstrapped in this order, each with its namespace
/// current, after the natives are installed: each file may use the
/// natives and the files before it.
const Embedded = struct { ns: []const u8, info: vm_mod.SourceInfo };
const embedded = [_]Embedded{
    // nexis.core's macros and functions over the natives.
    .{ .ns = "nexis.core", .info = .{ .path = "core.nx", .text = @embedFile("stdlib/core.nx") } },
    // Sugar over the Nextomic natives (`with-conn`).
    .{ .ns = "nextomic", .info = .{ .path = "nextomic.nx", .text = @embedFile("stdlib/nextomic.nx") } },
    // deftest, is, testing, run-tests (docs/TOOLING.md §3).
    .{ .ns = "nexis.test", .info = .{ .path = "test.nx", .text = @embedFile("stdlib/test.nx") } },
    // pprint, pprint-str (docs/TOOLING.md §4).
    .{ .ns = "nexis.pprint", .info = .{ .path = "pprint.nx", .text = @embedFile("stdlib/pprint.nx") } },
    // The constants of nexis.math.
    .{ .ns = "nexis.math", .info = .{ .path = "math.nx", .text = @embedFile("stdlib/math.nx") } },
    // The nexis.string functions written over its natives.
    .{ .ns = "nexis.string", .info = .{ .path = "string.nx", .text = @embedFile("stdlib/string.nx") } },
    // Set algebra (Clojure's clojure.set).
    .{ .ns = "nexis.set", .info = .{ .path = "set.nx", .text = @embedFile("stdlib/set.nx") } },
};

const core_natives = table("", .{
    // Sequence primitives.
    .{ "list", 0, null, &fnList },
    .{ "list*", 1, null, &fnListStar },
    .{ "cons", 2, 2, &fnCons },
    .{ "first", 1, 1, &fnFirst },
    .{ "rest", 1, 1, &fnRest },
    .{ "second", 1, 1, &fnSecond },
    .{ "third", 1, 1, &fnThird },
    .{ "take", 2, 2, &fnTake },
    .{ "some", 2, 2, &fnSome },
    .{ "every?", 2, 2, &fnEveryQ },
    .{ "count", 1, 1, &fnCount },
    .{ "nth", 2, 3, &fnNth },
    .{ "empty?", 1, 1, &fnEmptyQ },
    .{ "identity", 1, 1, &fnIdentity },
    .{ "nil?", 1, 1, &fnNilQ },
    .{ "some?", 1, 1, &fnSomeQ },
    // First-class arithmetic + comparison Vars.
    // Required so `(reduce + 0 xs)` resolves `+` as a Var.
    // `(+ x y)` at the call head is still inlined by the
    // compiler; the Var is only reached through non-head uses.
    .{ "+", 0, null, &fnAdd },
    .{ "-", 1, null, &fnSub },
    .{ "*", 0, null, &fnMul },
    .{ "/", 1, null, &fnDiv },
    .{ "quot", 2, 2, &fnQuot },
    .{ "rem", 2, 2, &fnRem },
    .{ "mod", 2, 2, &fnMod },
    .{ "<", 0, null, &fnLt },
    .{ "<=", 0, null, &fnLte },
    .{ ">", 0, null, &fnGt },
    .{ ">=", 0, null, &fnGte },
    .{ "==", 0, null, &fnNumEq },
    .{ "=", 0, null, &fnEq },
    .{ "not=", 1, null, &fnNotEq },
    .{ "inc", 1, 1, &fnInc },
    .{ "dec", 1, 1, &fnDec },
    .{ "long", 1, 1, &fnLong },
    .{ "int", 1, 1, castTo(i32) },
    .{ "short", 1, 1, castTo(i16) },
    .{ "byte", 1, 1, castTo(i8) },
    .{ "float", 1, 1, &fnFloat },
    .{ "char", 1, 1, &fnChar },
    .{ "parse-long", 1, 1, &fnParseLong },
    .{ "parse-double", 1, 1, &fnParseDouble },
    .{ "bit-and", 2, null, &fnBitAnd },
    .{ "bit-or", 2, null, &fnBitOr },
    .{ "bit-xor", 2, null, &fnBitXor },
    .{ "bit-not", 1, 1, &fnBitNot },
    .{ "bit-shift-left", 2, 2, &fnBitShiftLeft },
    .{ "bit-shift-right", 2, 2, &fnBitShiftRight },
    .{ "unsigned-bit-shift-right", 2, 2, &fnUnsignedBitShiftRight },
    .{ "bit-test", 2, 2, &fnBitTest },
    .{ "bit-set", 2, 2, &fnBitSet },
    .{ "bit-clear", 2, 2, &fnBitClear },
    .{ "rand", 0, 1, &fnRand },
    .{ "rand-int", 1, 1, &fnRandInt },
    .{ "format", 1, null, &fnFormat },
    .{ "double", 1, 1, &fnDouble },
    .{ "max", 1, null, &fnMax },
    .{ "min", 1, null, &fnMin },
    .{ "abs", 1, 1, &fnAbs },
    .{ "number?", 1, 1, &fnNumberQ },
    .{ "integer?", 1, 1, &fnIntegerQ },
    .{ "float?", 1, 1, &fnFloatQ },
    .{ "NaN?", 1, 1, &fnNanQ },
    .{ "infinite?", 1, 1, &fnInfiniteQ },
    .{ "not", 1, 1, &fnNot },
    .{ "zero?", 1, 1, &fnZeroQ },
    .{ "pos?", 1, 1, &fnPosQ },
    .{ "neg?", 1, 1, &fnNegQ },
    .{ "odd?", 1, 1, &fnOddQ },
    .{ "even?", 1, 1, &fnEvenQ },
    // apply + HOFs.
    .{ "apply", 2, null, &fnApply },
    .{ "map", 2, null, &fnMap },
    .{ "reduce", 2, 3, &fnReduce },
    .{ "reduce-kv", 3, 3, &fnReduceKv },
    .{ "filter", 2, 2, &fnFilter },
    .{ "remove", 2, 2, &fnRemove },
    .{ "keep", 2, 2, &fnKeep },
    .{ "seq", 1, 1, &fnSeq },
    .{ "next", 1, 1, &fnNext },
    .{ "range", 1, 3, &fnRange },
    .{ "concat", 0, null, &fnConcat },
    .{ "mapcat", 2, null, &fnMapcat },
    .{ "into", 0, 2, &fnInto },
    .{ "mapv", 2, null, &fnMapv },
    .{ "filterv", 2, 2, &fnFilterv },
    .{ "map-indexed", 2, 2, &fnMapIndexed },
    .{ "keep-indexed", 2, 2, &fnKeepIndexed },
    .{ "distinct", 1, 1, &fnDistinct },
    .{ "partition", 2, 4, &fnPartition },
    .{ "partition-all", 2, 3, &fnPartitionAll },
    .{ "interleave", 0, null, &fnInterleave },
    .{ "zipmap", 2, 2, &fnZipmap },
    .{ "take-while", 2, 2, &fnTakeWhile },
    .{ "drop-while", 2, 2, &fnDropWhile },
    .{ "butlast", 1, 1, &fnButlast },
    .{ "last", 1, 1, &fnLast },
    .{ "reverse", 1, 1, &fnReverse },
    .{ "nthrest", 2, 2, &fnNthrest },
    .{ "nthnext", 2, 2, &fnNthnext },
    .{ "split-at", 2, 2, &fnSplitAt },
    .{ "take-last", 2, 2, &fnTakeLast },
    .{ "drop-last", 1, 2, &fnDropLast },
    .{ "flatten", 1, 1, &fnFlatten },
    .{ "reductions", 2, 3, &fnReductions },
    .{ "repeat", 2, 2, &fnRepeat },
    .{ "repeatedly", 2, 2, &fnRepeatedly },
    .{ "iterate", 3, 3, &fnIterate },
    .{ "max-key", 2, null, &fnMaxKey },
    .{ "min-key", 2, null, &fnMinKey },
    .{ "select-keys", 2, 2, &fnSelectKeys },
    .{ "find", 2, 2, &fnFind },
    .{ "key", 1, 1, &fnKey },
    .{ "val", 1, 1, &fnVal },
    .{ "peek", 1, 1, &fnPeek },
    .{ "pop", 1, 1, &fnPop },
    .{ "empty", 1, 1, &fnEmpty },
    .{ "not-empty", 1, 1, &fnNotEmpty },
    .{ "disj", 1, null, &fnDisj },
    .{ "compare", 2, 2, &fnCompare },
    .{ "sort", 1, 2, &fnSort },
    .{ "sort-by", 2, 3, &fnSortBy },
    .{ "hash", 1, 1, &fnHash },
    .{ "name", 1, 1, &fnName },
    .{ "namespace", 1, 1, &fnNamespace },
    .{ "keyword", 1, 2, &fnKeyword },
    .{ "symbol", 1, 2, &fnSymbol },
    .{ "gensym", 0, 1, &fnGensym },
    .{ "in-ns", 1, 1, &fnInNs },
    // Exceptions as maps (PLAN Amendment Log, exceptions are values).
    .{ "ex-info", 2, 3, &fnExInfo },
    .{ "ex-data", 1, 1, &fnExData },
    .{ "ex-message", 1, 1, &fnExMessage },
    // Early exit from a fold.
    .{ "reduced", 1, 1, &fnReduced },
    .{ "reduced?", 1, 1, &fnReducedQ },
    // The compiler at run time.
    .{ "macroexpand-1", 1, 1, &fnMacroexpand1 },
    .{ "macroexpand", 1, 1, &fnMacroexpand },
    .{ "read-string", 1, 1, &fnReadString },
    .{ "eval", 1, 1, &fnEval },
    // Metadata (SEMANTICS.md §7).
    .{ "meta", 1, 1, &fnMeta },
    .{ "with-meta", 2, 2, &fnWithMeta },
    .{ "reset-meta!", 2, 2, &fnResetMeta },
    .{ "alter-meta!", 2, null, &fnAlterMeta },
    // Dynamic bindings (VM.md §6.5); `binding` and `set!` in
    // core.nx expand to these.
    .{ "push-thread-bindings", 1, 1, &fnPushThreadBindings },
    .{ "pop-thread-bindings", 0, 0, &fnPopThreadBindings },
    .{ "var-set", 2, 2, &fnVarSet },
    .{ "thread-bound?", 1, 1, &fnThreadBoundQ },
    .{ "boolean", 1, 1, &fnBoolean },
    .{ "list?", 1, 1, kindPredicate(isList) },
    .{ "seq?", 1, 1, kindPredicate(isList) },
    .{ "vector?", 1, 1, kindPredicate(isVector) },
    .{ "map?", 1, 1, kindPredicate(isMap) },
    .{ "set?", 1, 1, kindPredicate(isSet) },
    .{ "keyword?", 1, 1, kindPredicate(isKeyword) },
    .{ "symbol?", 1, 1, kindPredicate(isSymbol) },
    .{ "char?", 1, 1, kindPredicate(isChar) },
    .{ "boolean?", 1, 1, kindPredicate(isBoolean) },
    .{ "coll?", 1, 1, kindPredicate(isColl) },
    .{ "sequential?", 1, 1, kindPredicate(isSequential) },
    .{ "associative?", 1, 1, kindPredicate(isAssociative) },
    .{ "fn?", 1, 1, kindPredicate(isFn) },
    .{ "ifn?", 1, 1, kindPredicate(isIfn) },
    .{ "counted?", 1, 1, kindPredicate(isCounted) },
    .{ "delay?", 1, 1, &fnDelayQ },
    // Introspection: kinds, namespaces, UUIDs (STDLIB.md §8).
    .{ "class", 1, 1, &fnClass },
    .{ "var?", 1, 1, kindPredicate(isVar) },
    .{ "find-ns", 1, 1, &fnFindNs },
    .{ "all-ns", 0, 0, &fnAllNs },
    .{ "ns-interns", 1, 1, &fnNsInterns },
    .{ "ns-publics", 1, 1, &fnNsPublics },
    .{ "resolve", 1, 1, &fnResolve },
    .{ "ns-resolve", 2, 2, &fnNsResolve },
    .{ "random-uuid", 0, 0, &fnRandomUuid },
    .{ "parse-uuid", 1, 1, &fnParseUuid },
    .{ "indexed?", 1, 1, kindPredicate(isIndexed) },
    // Collection construction + access.
    .{ "vector", 0, null, &fnVector },
    .{ "vec", 1, 1, &fnVec },
    .{ "hash-map", 0, null, &fnHashMap },
    .{ "hash-set", 0, null, &fnHashSet },
    .{ "set", 1, 1, &fnSet },
    .{ "subvec", 2, 3, &fnSubvec },
    .{ "identical?", 2, 2, &fnIdenticalQ },
    .{ "assoc", 3, null, &fnAssoc },
    .{ "dissoc", 1, null, &fnDissoc },
    .{ "get", 2, 3, &fnGet },
    .{ "contains?", 2, 2, &fnContainsQ },
    .{ "keys", 1, 1, &fnKeys },
    .{ "vals", 1, 1, &fnVals },
    .{ "conj", 0, null, &fnConj },
    // Transients (docs/TRANSIENT.md): shallow, the same cost as the
    // persistent operations; every `!` returns the transient to use.
    .{ "transient", 1, 1, &fnTransient },
    .{ "persistent!", 1, 1, &fnPersistentBang },
    .{ "conj!", 0, null, &fnConjBang },
    .{ "assoc!", 3, null, &fnAssocBang },
    .{ "dissoc!", 2, null, &fnDissocBang },
    .{ "disj!", 2, null, &fnDisjBang },
    .{ "pop!", 1, 1, &fnPopBang },
    // Sorted collections (docs/SORTED.md).
    .{ "sorted-map", 0, null, &fnSortedMap },
    .{ "sorted-map-by", 1, null, &fnSortedMapBy },
    .{ "sorted-set", 0, null, &fnSortedSet },
    .{ "sorted-set-by", 1, null, &fnSortedSetBy },
    .{ "sorted?", 1, 1, kindPredicate(sorted_mod.isSortedKind) },
    .{ "reversible?", 1, 1, kindPredicate(isReversible) },
    .{ "subseq", 3, 5, &fnSubseq },
    .{ "rsubseq", 3, 5, &fnRsubseq },
    .{ "rseq", 1, 1, &fnRseq },
    // Typed vectors (docs/TYPED_VECTOR.md §7.1).
    .{ "i64-vector", 1, 1, &fnI64Vector },
    .{ "f64-vector", 1, 1, &fnF64Vector },
    .{ "typed-vector?", 1, 1, kindPredicate(isTypedVector) },
    .{ "typed-vector-type", 1, 1, &fnTypedVectorType },
    // Atoms: identity-valued in-memory mutable cells (docs/ATOM.md).
    // `deref` is `fnDbDeref`, which takes a var, atom, durable ref
    // or reduced; `db_natives` installs it again as `db/deref`.
    .{ "deref", 1, 1, &fnDbDeref },
    .{ "atom", 1, 1, &fnAtom },
    .{ "atom?", 1, 1, &fnAtomQ },
    .{ "reset!", 2, 2, &fnResetBang },
    .{ "swap!", 2, null, &fnSwapBang },
    .{ "swap-vals!", 2, null, &fnSwapValsBang },
    .{ "compare-and-set!", 3, 3, &fnCompareAndSetBang },
    // satisfies? predicate.
    .{ "satisfies?", 2, 2, &fnSatisfiesQ },
    // Core string ops. Indexing semantics are by Unicode scalar
    // (codepoint), NOT byte; see `docs/STDLIB.md` §2.
    .{ "str", 0, null, &fnStr },
    .{ "string?", 1, 1, &fnStringQ },
    .{ "subs", 2, 3, &fnSubs },
    // Printing + I/O.
    .{ "print", 0, null, &fnPrint },
    .{ "println", 0, null, &fnPrintln },
    .{ "pr", 0, null, &fnPr },
    .{ "prn", 0, null, &fnPrn },
    .{ "pr-str", 0, null, &fnPrStr },
    .{ "bound?", 1, null, &fnBoundQ },
    .{ "nano-time", 0, 0, &fnNanoTime },
    .{ "slurp", 1, 1, &fnSlurp },
    .{ "spit", 2, null, &fnSpit },
    .{ "read-line", 0, 0, &fnReadLine },
    .{ "exit", 0, 1, &fnExit },
    // The durable-ref natives are `db_natives`, in the `db`
    // namespace, so they are called as `(db/open ...)`.
});

const db_natives = table("db", .{
    // Connection + ref + auto-ephemeral primitives.
    .{ "open", 1, 2, &fnDbOpen },
    .{ "close", 1, 1, &fnDbClose },
    .{ "sync", 1, 1, &fnDbSync },
    .{ "ref", 3, 3, &fnDbRef },
    .{ "ref?", 1, 1, &fnDbRefQ },
    .{ "put-key!", 2, 2, &fnDbPutKey },
    .{ "get-key", 1, 2, &fnDbGetKey },
    .{ "delete-key!", 1, 1, &fnDbDeleteKey },
    .{ "present?", 1, 1, &fnDbPresentQ },
    // Explicit-tx primitives.
    .{ "begin-write", 1, 1, &fnDbBeginWrite },
    .{ "begin-read", 1, 1, &fnDbBeginRead },
    .{ "commit!", 1, 1, &fnDbCommit },
    .{ "abort-write!", 1, 1, &fnDbAbortWrite },
    .{ "abort-read!", 1, 1, &fnDbAbortRead },
    .{ "put!", 3, 3, &fnDbPut },
    .{ "get", 2, 3, &fnDbGet },
    .{ "delete!", 2, 2, &fnDbDelete },
    // Deref + alter.
    .{ "deref", 1, 1, &fnDbDeref },
    .{ "alter!", 3, null, &fnDbAlter },
    // Tree traversal.
    .{ "scan", 2, 4, &fnDbScan },
    .{ "reduce-tree", 4, 4, &fnDbReduceTree },
    // Snapshot aliases (DB.md §12).
    .{ "snapshot", 1, 1, &fnDbBeginRead },
    .{ "release-snapshot!", 1, 1, &fnDbAbortRead },
    .{ "snapshot?", 1, 1, &fnDbSnapshotQ },
});

const string_natives = table("nexis.string", .{
    .{ "lower-case", 1, 1, &fnStringLowerCase },
    .{ "upper-case", 1, 1, &fnStringUpperCase },
    .{ "trim", 1, 1, &fnStringTrim },
    .{ "split", 2, 3, &fnStringSplit },
    .{ "triml", 1, 1, &fnStringTriml },
    .{ "trimr", 1, 1, &fnStringTrimr },
    .{ "trim-newline", 1, 1, &fnStringTrimNewline },
    .{ "blank?", 1, 1, &fnStringBlankQ },
    .{ "starts-with?", 2, 2, &fnStringStartsWithQ },
    .{ "ends-with?", 2, 2, &fnStringEndsWithQ },
    .{ "includes?", 2, 2, &fnStringIncludesQ },
    .{ "index-of", 2, 3, &fnStringIndexOf },
    .{ "last-index-of", 2, 3, &fnStringLastIndexOf },
    .{ "join", 1, 2, &fnStringJoin },
    .{ "replace", 3, 3, &fnStringReplace },
});

const math_natives = table("nexis.math", .{
    .{ "sqrt", 1, 1, &fnMathSqrt },
    .{ "pow", 2, 2, &fnMathPow },
    .{ "floor", 1, 1, &fnMathFloor },
    .{ "ceil", 1, 1, &fnMathCeil },
    .{ "round", 1, 1, &fnMathRound },
});

const internal_natives = table("nexis.internal", .{
    // Records.
    .{ "#%register-record-type", 2, 2, &fnRegisterRecordType },
    .{ "#%make-record", 2, 2, &fnMakeRecord },
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
    // `& {:keys ...}`: the rest seq as a map.
    .{ "#%kwargs", 1, 1, &fnKwargs },
    // deftest and run-tests: the name of the current namespace.
    .{ "#%current-ns", 0, 0, &fnCurrentNs },
    // delay: the record a delay is (core.nx `delay`, `force`).
    .{ "#%delay", 1, 1, &fnDelay },
    // with-out-str: capture what the print functions write.
    .{ "#%push-out", 0, 0, &fnPushOut },
    .{ "#%pop-out", 0, 0, &fnPopOut },
});

const simd_natives = table("nexis.simd", .{
    .{ "sum", 1, 1, &fnSimdSum },
    .{ "dot", 2, 2, &fnSimdDot },
    .{ "scale", 2, 2, &fnSimdScale },
    .{ "map", 2, 2, &fnSimdMap },
});

// =============================================================================
// Implementations
// =============================================================================

/// `(list & xs)` → a fresh list of the args; `(list)` is `()`.
fn fnList(vm: *VM, args: []const Value) VmError!Value {
    return list_mod.fromSlice(vm.ensureHeap(), args) catch VmError.OutOfMemory;
}

/// `(list* a b ... seq)` → list of the leading args followed by
/// every element of `seq`; nil when there is nothing at all, the
/// way Clojure's returns a nil seq.
fn fnListStar(vm: *VM, args: []const Value) VmError!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    items.appendSlice(vm.allocator, args[0 .. args.len - 1]) catch return VmError.OutOfMemory;
    try appendSeqValues(vm, args[args.len - 1], &items);
    if (items.items.len == 0) return value_mod.nilValue();
    return try buildListFromSlice(vm, items.items);
}

/// `(cons x s)` → a list of `x` followed by the elements of `s`,
/// any seqable; a list tail is shared, anything else is copied.
fn fnCons(vm: *VM, args: []const Value) VmError!Value {
    const tail = if (args[1].kind() == .list) args[1] else blk: {
        var items = try collectSeq(vm, args[1]);
        defer items.deinit(vm.allocator);
        break :blk try buildListFromSlice(vm, items.items);
    };
    return list_mod.cons(vm.ensureHeap(), args[0], tail) catch VmError.OutOfMemory;
}

/// `(first s)` → head of the seq, or nil if empty/nil.
fn fnFirst(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    return switch (s.kind()) {
        .nil => value_mod.nilValue(),
        .list => if (list_mod.isEmpty(s)) value_mod.nilValue() else list_mod.head(s),
        .persistent_vector => if (vector_mod.isEmpty(s)) value_mod.nilValue() else vector_mod.nth(s, 0),
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

fn fnThird(vm: *VM, args: []const Value) VmError!Value {
    return nthOfSeq(vm, args[0], 2);
}

/// `(take n coll)` → a list of the first `n` elements, all of them
/// when there are fewer; walks no further than `n`.
fn fnTake(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    var it = try makeSeqIter(vm, args[1]);
    while (items.items.len < n) {
        const x = (try it.next()) orelse break;
        items.append(vm.allocator, x) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, items.items);
}

/// `(some pred coll)` → the first truthy `(pred x)`, else nil;
/// `(every? pred coll)` → whether `(pred x)` is truthy for every x.
/// Both stop at the first element that decides.
fn fnSome(vm: *VM, args: []const Value) VmError!Value {
    var it = try makeSeqIter(vm, args[1]);
    while (try it.next()) |x| {
        const r = try callBack(vm, args[0], &.{x});
        if (r.isTruthy()) return r;
    }
    return value_mod.nilValue();
}

fn fnEveryQ(vm: *VM, args: []const Value) VmError!Value {
    var it = try makeSeqIter(vm, args[1]);
    while (try it.next()) |x| {
        if (!(try callBack(vm, args[0], &.{x})).isTruthy()) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

/// `(next s)` → `(seq (rest s))`: nil when nothing follows.
fn fnNext(vm: *VM, args: []const Value) VmError!Value {
    const r = try fnRest(vm, args);
    return if (list_mod.isEmpty(r)) value_mod.nilValue() else r;
}

/// `(seq coll)` → nil for nil or an empty collection, otherwise a
/// list of the collection's elements (a non-empty list is
/// returned as is; a vector gives an O(1) view, LIST.md §1). Maps
/// yield `[k v]` entries, strings chars.
fn fnSeq(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    switch (c.kind()) {
        .list => return if (list_mod.isEmpty(c)) value_mod.nilValue() else c,
        .persistent_vector => return if (vector_mod.isEmpty(c))
            value_mod.nilValue()
        else
            list_mod.ofVector(vm.ensureHeap(), c, 0) catch VmError.OutOfMemory,
        else => {},
    }
    var items = try collectSeq(vm, c);
    defer items.deinit(vm.allocator);
    if (items.items.len == 0) return value_mod.nilValue();
    return try buildListFromSlice(vm, items.items);
}

/// `(count coll)` → element count. nil → 0. Lists, vectors,
/// maps, records, sets and strings; a string counts Unicode
/// scalars, not bytes.
fn fnCount(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    const n: i64 = switch (c.kind()) {
        .nil => 0,
        .list => @intCast(list_mod.count(c)),
        .persistent_vector => @intCast(vector_mod.count(c)),
        .typed_vector => @intCast(typed_vector_mod.count(c)),
        .persistent_map => @intCast(champ_mod.mapCount(c)),
        .record => @intCast(champ_mod.mapCount(record_mod.fieldsOf(c))),
        .nextomic_entity => @intCast(champ_mod.mapCount(try nextomic_mod.natives.entityMap(vm, c))),
        .persistent_set => @intCast(champ_mod.setCount(c)),
        .sorted_map, .sorted_set => @intCast(sorted_mod.count(c)),
        .string => @intCast(string_mod.codepointCount(c) catch return VmError.Utf8Error),
        .transient => @intCast(try transientCount(vm, c)),
        else => return VmError.KindMismatch,
    };
    return value_mod.fromFixnum(n) orelse VmError.ArithmeticOverflow;
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
        else => return VmError.KindMismatch,
    }
    const idx = idx_v.asFixnum();
    if (idx < 0) {
        if (has_default) return default;
        return VmError.IndexOutOfBounds;
    }
    const u_idx: usize = @intCast(idx);
    return switch (coll.kind()) {
        .nil => default,
        .list => blk: {
            const at = list_mod.drop(coll, u_idx);
            if (list_mod.isEmpty(at)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            break :blk list_mod.head(at);
        },
        .persistent_vector => blk: {
            if (u_idx >= vector_mod.count(coll)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            break :blk vector_mod.nth(coll, u_idx);
        },
        .transient => blk: {
            if (u_idx >= try transientCount(vm, coll)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            break :blk transient_mod.vectorNthBang(coll, u_idx) catch |err| return transientFailure(vm, err);
        },
        .typed_vector => typed_vector_mod.nth(vm.ensureHeap(), coll, u_idx) catch |err| switch (err) {
            error.IndexOutOfBounds => if (has_default) default else VmError.IndexOutOfBounds,
            error.OutOfMemory => VmError.OutOfMemory,
        },
        // `(nth s i)` returns a
        // Kind.char at codepoint index `i`. Indexing is by
        // Unicode scalar to match `(count s)`. Out-of-bounds
        // surfaces `:index-out-of-bounds`; malformed UTF-8
        // surfaces `:utf8-error`.
        .string => blk: {
            const scalar = string_mod.codepointAt(coll, u_idx) catch |err| switch (err) {
                error.OutOfBounds => {
                    if (has_default) break :blk default;
                    return VmError.IndexOutOfBounds;
                },
                error.InvalidUtf8 => return VmError.Utf8Error,
            };
            break :blk value_mod.fromChar(scalar) orelse return VmError.Utf8Error;
        },
        else => return VmError.KindMismatch,
    };
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
//   (<)        => true         (< x y z)  => chained
//
// `=` is value equality (dispatch.equal, cross-type false);
// `==` is numeric equality with contagion (`(== 1 1.0)` is true).

const dispatch_mod = @import("dispatch.zig");

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
    if (args.len == 0) return value_mod.fromFixnum(0).?;
    return foldNumbers(vm, &vm_mod.numAdd, args);
}

fn fnSub(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return vm_mod.numNeg(vm.ensureHeap(), args[0]);
    return foldNumbers(vm, &vm_mod.numSub, args);
}

fn fnMul(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return value_mod.fromFixnum(1).?;
    return foldNumbers(vm, &vm_mod.numMul, args);
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
/// `cmp`. Fewer than two arguments is vacuously true; a lone
/// argument must still be a number.
fn chainCompare(cmp: vm_mod.NumCmp, args: []const Value) VmError!Value {
    if (args.len == 1) _ = try requireNumber(args[0]);
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

fn fnEq(_: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return value_mod.fromBool(true);
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (!dispatch_mod.equal(args[i], args[i + 1])) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

fn fnNotEq(vm: *VM, args: []const Value) VmError!Value {
    const same = try fnEq(vm, args);
    return value_mod.fromBool(!same.asBool());
}

fn fnInc(vm: *VM, args: []const Value) VmError!Value {
    return vm_mod.numAdd(vm.ensureHeap(), args[0], value_mod.fromFixnum(1).?);
}

fn fnDec(vm: *VM, args: []const Value) VmError!Value {
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
                const f = x.asFloat();
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
    const suffix = body.len > 0 and std.mem.indexOfScalar(u8, "fFdD", body[body.len - 1]) != null;
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
    if (i < number.len and std.mem.indexOfScalar(u8, if (hex) "pP" else "eE", number[i]) != null) {
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

/// The generator behind `rand` and `rand-int`, seeded from the clock
/// at first use. One isolate, one thread.
var prng: ?std.Random.DefaultPrng = null;

fn random(vm: *VM) std.Random {
    if (prng == null) {
        const now = std.Io.Clock.real.now(ioOf(vm));
        prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @bitCast(@as(i128, now.nanoseconds)))));
    }
    return prng.?.random();
}

/// `(rand)` → a double in [0, 1); `(rand n)` → in [0, n).
fn fnRand(vm: *VM, args: []const Value) VmError!Value {
    const r = random(vm).float(f64);
    if (args.len == 0) return value_mod.fromFloat(r);
    return value_mod.fromFloat(r * try asDouble(args[0]));
}

/// `(rand-int n)` → an integer in [0, n); n must be positive.
fn fnRandInt(vm: *VM, args: []const Value) VmError!Value {
    const n = try intArg(args[0]);
    if (n <= 0) return VmError.InvalidArgument;
    return integerValue(vm, random(vm).intRangeLessThan(i64, 0, n));
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
/// integer already). A float that is NaN or infinite has no nearest
/// integer: `:invalid-argument`, as `long` says.
fn fnMathRound(vm: *VM, args: []const Value) VmError!Value {
    if (vm_mod.isInteger(args[0])) return args[0];
    const f = try asDouble(args[0]);
    const r = @floor(f);
    return vm_mod.numLong(vm.ensureHeap(), value_mod.fromFloat(if (f - r >= 0.5) r + 1 else r));
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
// next call's argument (`reduce`, `reduce-kv`, `swap!`, `db/alter!`,
// `db/reduce-tree`) needs nothing, because an argument is rooted
// for the call that could collect.

/// `(f args...)` for a sequence native's callback. A keyword looking
/// up a map, a record or nil, and a leaf native (`leaf_natives`), run
/// here directly: neither can re-enter the VM, collect, or compare or
/// hash nested structure, so the root scope, the stack guard and the
/// deep-data check `VM.callValue` puts around a call have nothing to
/// do. Everything else goes through `callValue`, as does a leaf
/// native called with an arity it refuses, for its error.
fn callBack(vm: *VM, f: Value, args: []const Value) VmError!Value {
    switch (f.kind()) {
        .keyword => if (args.len == 1) switch (args[0].kind()) {
            .nil, .persistent_map, .record => return vm_mod.lookup(args[0], f, value_mod.nilValue()),
            else => {},
        },
        .native_fn => {
            const native = vm_mod.asNativeFn(f);
            if (isLeafNative(native.call) and args.len >= native.min_arity and args.len <= (native.max_arity orelse args.len)) return native.call(vm, args);
        },
        else => {},
    }
    return vm.callValue(f, args);
}

/// The natives `callBack` calls directly: arithmetic and predicates
/// over their arguments alone. A bignum they make is a fresh block,
/// and `Heap.alloc` never collects (VM.md §9).
const leaf_natives = [_]*const fn (*VM, []const Value) VmError!Value{
    &fnAdd,   &fnSub,  &fnMul,  &fnInc, &fnDec,   &fnMax,   &fnMin,
    &fnLt,    &fnLte,  &fnGt,   &fnGte, &fnNumEq, &fnEvenQ, &fnOddQ,
    &fnZeroQ, &fnPosQ, &fnNegQ, &fnNot, &fnNilQ,  &fnSomeQ, &fnIdentity,
};

fn isLeafNative(call: *const fn (*VM, []const Value) VmError!Value) bool {
    inline for (leaf_natives) |leaf| if (call == leaf) return true;
    return false;
}

/// `(apply f x1 x2 ... xs)` calls `f` with the elements of
/// the last arg seq spliced in after the leading args.
fn fnApply(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const last = args[args.len - 1];

    // Materialize the final arg list.
    var combined: std.ArrayList(Value) = .empty;
    defer combined.deinit(vm.allocator);
    // Leading args (between f and the seq).
    var i: usize = 1;
    while (i < args.len - 1) : (i += 1) {
        combined.append(vm.allocator, args[i]) catch return VmError.OutOfMemory;
    }
    // Walk `last` as a seq.
    try appendSeqValues(vm, last, &combined);

    return try vm.callValue(f, combined.items);
}

/// `(map f coll & colls)` → eager list of `(f x1 x2 ...)`,
/// stopping at the shortest collection. Throws inside `f`
/// propagate via `ControlTransferred`.
fn fnMap(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    try mapInto(vm, args[0], args[1..], scope);
    return try buildListFromSlice(vm, scopeItems(scope));
}

/// Push `(f x1 x2 ...)` for every position of the shortest of
/// `colls` on `scope`, which is both the results' root and their
/// buffer (`scopeItems`).
fn mapInto(vm: *VM, f: Value, colls: []const Value, scope: vm_mod.RootScope) VmError!void {
    if (colls.len == 1) {
        var it = try makeSeqIter(vm, colls[0]);
        while (try it.next()) |x| try scope.push(try callBack(vm, f, &.{x}));
        return;
    }

    const iters = vm.allocator.alloc(SeqIter, colls.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(iters);
    for (colls, 0..) |c, i| iters[i] = try makeSeqIter(vm, c);
    const call_args = vm.allocator.alloc(Value, colls.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    outer: while (true) {
        for (iters, 0..) |*it, i| {
            call_args[i] = (try it.next()) orelse break :outer;
        }
        try scope.push(try callBack(vm, f, call_args));
    }
}

/// `(reduce f coll)` / `(reduce f init coll)` → left fold. With
/// no init the first element seeds the fold and an empty
/// collection yields `(f)`.
fn fnReduce(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const coll = args[args.len - 1];
    var it = try makeSeqIter(vm, coll);
    var acc = if (args.len == 3) args[1] else (try it.next()) orelse return try vm.callValue(f, &.{});
    while (try it.next()) |x| {
        acc = try callBack(vm, f, &.{ acc, x });
        if (isReduced(vm, acc)) return reducedValue(acc);
    }
    return acc;
}

/// `(reduced x)` → a value `reduce` returns at once, unwrapped;
/// a one-field record of the type `nexis.core/Reduced`, so
/// `reduced?` is a type test and `@` reads the value back.
fn fnReduced(vm: *VM, args: []const Value) VmError!Value {
    const type_id = vm.ensureReducedType() catch return VmError.OutOfMemory;
    const heap = vm.ensureHeap();
    const key = vm.ensureInterner().internKeywordValue("val") catch return VmError.OutOfMemory;
    const empty = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const fields = champ_mod.mapAssoc(heap, empty, key, args[0], &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.OutOfMemory;
    return record_mod.make(heap, type_id, fields) catch VmError.OutOfMemory;
}

fn fnReducedQ(vm: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(isReduced(vm, args[0]));
}

fn isReduced(vm: *const VM, v: Value) bool {
    const type_id = vm.reduced_type_id orelse return false;
    return v.kind() == .record and record_mod.typeId(v) == type_id;
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
    const f = args[0];
    var acc = args[1];
    const coll = args[2];
    switch (coll.kind()) {
        .nil => {},
        .persistent_map, .record, .sorted_map => {
            var it = MapEntries.of(coll).?;
            while (it.next()) |e| {
                acc = try callBack(vm, f, &.{ acc, e.key, e.value });
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
        },
        .persistent_vector => {
            var c = vector_mod.Cursor.init(coll);
            var i: i64 = 0;
            while (c.next()) |x| : (i += 1) {
                acc = try callBack(vm, f, &.{ acc, value_mod.fromFixnum(i).?, x });
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
        },
        else => return VmError.KindMismatch,
    }
    return acc;
}

/// Shared body of `filter` / `remove` / `keep`.
const Sieve = enum { keep_truthy, keep_falsy, keep_result };

fn sieve(vm: *VM, mode: Sieve, pred: Value, coll: Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    try sieveInto(vm, mode, pred, coll, scope);
    return try buildListFromSlice(vm, scopeItems(scope));
}

/// Push what `mode` keeps of `coll` on `scope`, the kept values'
/// root and buffer. An element the walk built (a map's entry) is
/// rooted as the predicate's argument for its call and by the push
/// once kept; one dropped is garbage.
fn sieveInto(vm: *VM, mode: Sieve, pred: Value, coll: Value, scope: vm_mod.RootScope) VmError!void {
    var it = try makeSeqIter(vm, coll);
    while (try it.next()) |x| {
        const r = try callBack(vm, pred, &.{x});
        const kept: ?Value = switch (mode) {
            .keep_truthy => if (r.isTruthy()) x else null,
            .keep_falsy => if (r.isTruthy()) null else x,
            .keep_result => if (r.isNil()) null else r,
        };
        if (kept) |v| try scope.push(v);
    }
}

/// `(filter pred coll)` → eager list of x where `(pred x)` is truthy.
fn fnFilter(vm: *VM, args: []const Value) VmError!Value {
    return sieve(vm, .keep_truthy, args[0], args[1]);
}

/// `(remove pred coll)` → eager list of x where `(pred x)` is falsy.
fn fnRemove(vm: *VM, args: []const Value) VmError!Value {
    return sieve(vm, .keep_falsy, args[0], args[1]);
}

/// `(keep f coll)` → eager list of the non-nil `(f x)` results.
fn fnKeep(vm: *VM, args: []const Value) VmError!Value {
    return sieve(vm, .keep_result, args[0], args[1]);
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
//   assoc        (m k v)    persistent put (map or vector)
//   dissoc       (m k)      persistent remove (map only)
//   get          (m k)      lookup (map/set/vector); nil if missing
//   get          (m k def)  lookup with default
//   contains?    (m k)      key/element presence check
//   keys         (m)        seq of map keys
//   vals         (m)        seq of map values
//   conj         (coll & xs) persistent add (list: cons; vector: push;
//                            map: assoc with [k v] pair; set: include)
//
// Map and set iteration order is unspecified. Tests using
// `keys`/`vals` should compare as sets, not by exact order.

fn fnVector(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    return vector_mod.fromSlice(heap, args) catch VmError.OutOfMemory;
}

fn fnVec(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    return switch (s.kind()) {
        .nil => {
            const heap = vm.ensureHeap();
            return vector_mod.empty(heap) catch VmError.OutOfMemory;
        },
        .persistent_vector => s,
        else => blk: {
            var items = try collectSeq(vm, s);
            defer items.deinit(vm.allocator);
            break :blk vector_mod.fromSlice(vm.ensureHeap(), items.items) catch VmError.OutOfMemory;
        },
    };
}

fn fnHashMap(vm: *VM, args: []const Value) VmError!Value {
    if (args.len % 2 != 0) return VmError.ArityMismatch;
    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        m = champ_mod.mapAssoc(
            heap,
            m,
            args[i],
            args[i + 1],
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch return VmError.OutOfMemory;
    }
    return m;
}

fn fnHashSet(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var s = champ_mod.setEmpty(heap) catch return VmError.OutOfMemory;
    for (args) |x| {
        s = champ_mod.setConj(
            heap,
            s,
            x,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch return VmError.OutOfMemory;
    }
    return s;
}

/// `(set coll)` → the elements of any seqable as a set.
fn fnSet(vm: *VM, args: []const Value) VmError!Value {
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

fn assocOne(vm: *VM, coll: Value, k: Value, v: Value) VmError!Value {
    const heap = vm.ensureHeap();
    return switch (coll.kind()) {
        .persistent_map => champ_mod.mapAssoc(
            heap,
            coll,
            k,
            v,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        ) catch VmError.OutOfMemory,
        .nil => blk: {
            var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
            m = champ_mod.mapAssoc(
                heap,
                m,
                k,
                v,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory;
            break :blk m;
        },
        .record => blk: {
            const cur_fields = record_mod.fieldsOf(coll);
            const new_fields = champ_mod.mapAssoc(
                heap,
                cur_fields,
                k,
                v,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory;
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

/// `(dissoc m k & ks)` → persistent remove from a map or record.
fn fnDissoc(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .sorted_map) return sortedRemoveAll(vm, args[0], args[1..]);
    const heap = vm.ensureHeap();
    var coll = args[0];
    for (args[1..]) |k| {
        coll = switch (coll.kind()) {
            .persistent_map => champ_mod.mapDissoc(
                heap,
                coll,
                k,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory,
            .nil => coll,
            .record => blk: {
                const cur_fields = record_mod.fieldsOf(coll);
                const new_fields = champ_mod.mapDissoc(
                    heap,
                    cur_fields,
                    k,
                    &dispatch_mod.hashValue,
                    &dispatch_mod.equal,
                ) catch return VmError.OutOfMemory;
                break :blk record_mod.withFields(heap, coll, new_fields) catch return VmError.OutOfMemory;
            },
            else => return VmError.KindMismatch,
        };
    }
    return coll;
}

/// `(disj s x & xs)` → set without the elements.
fn fnDisj(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() == .sorted_set) return sortedRemoveAll(vm, args[0], args[1..]);
    const heap = vm.ensureHeap();
    var coll = args[0];
    for (args[1..]) |x| {
        coll = switch (coll.kind()) {
            .persistent_set => champ_mod.setDisj(
                heap,
                coll,
                x,
                &dispatch_mod.hashValue,
                &dispatch_mod.equal,
            ) catch return VmError.OutOfMemory,
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
        .persistent_map => value_mod.fromBool(switch (champ_mod.mapGet(
            coll,
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )) {
            .present => true,
            .absent => false,
        }),
        .persistent_set => value_mod.fromBool(champ_mod.setContains(
            coll,
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )),
        .persistent_vector => blk: {
            if (k.kind() != .fixnum) break :blk value_mod.fromBool(false);
            const idx = k.asFixnum();
            if (idx < 0) break :blk value_mod.fromBool(false);
            const u_idx: usize = @intCast(idx);
            break :blk value_mod.fromBool(u_idx < vector_mod.count(coll));
        },
        .string => value_mod.fromBool((try stringIndex(coll, k)) != null),
        .sorted_map, .sorted_set => value_mod.fromBool((try vm_mod.sortedFind(vm, coll, k)) != null),
        .typed_vector => blk: {
            if (k.kind() != .fixnum) break :blk value_mod.fromBool(false);
            const idx = k.asFixnum();
            if (idx < 0) break :blk value_mod.fromBool(false);
            const u_idx: usize = @intCast(idx);
            break :blk value_mod.fromBool(u_idx < typed_vector_mod.count(coll));
        },
        .record => value_mod.fromBool(switch (champ_mod.mapGet(
            record_mod.fieldsOf(coll),
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )) {
            .present => true,
            .absent => false,
        }),
        .nextomic_entity => value_mod.fromBool(try nextomic_mod.natives.entityHas(vm, coll, k)),
        .transient => value_mod.fromBool(if (coll.subkind() == transient_mod.subkind_transient_set)
            transient_mod.setContainsBang(coll, k, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err)
        else
            (try vm_mod.transientLookup(coll, k)) != null),
        else => return VmError.KindMismatch,
    };
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
        .persistent_vector => blk: {
            var result = coll;
            for (xs) |x| result = vector_mod.conj(heap, result, x) catch return VmError.OutOfMemory;
            break :blk result;
        },
        .persistent_map, .record => blk: {
            var result = coll;
            for (xs) |x| {
                // Each x is a `[k v]` entry, a map or record whose
                // entries are all added, or nil (skipped).
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
            break :blk result;
        },
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
        .persistent_set => blk: {
            var result = coll;
            for (xs) |x| {
                result = champ_mod.setConj(
                    heap,
                    result,
                    x,
                    &dispatch_mod.hashValue,
                    &dispatch_mod.equal,
                ) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        else => return VmError.KindMismatch,
    };
}

// =============================================================================
// Sequence library
// =============================================================================
//
// Eager, list-producing (PLAN §23 #14). Every function takes any
// seqable receiver through `makeSeqIter` and builds its result
// with `buildListFromSlice`; vector-producing variants (`mapv`,
// `filterv`, `vec`) go through `vector_mod.fromSlice`.

/// `(range end)` / `(range start end)` / `(range start end step)`
/// → the list start, start+step, ... up to but not including end.
/// Any number works; the elements follow the tower's contagion
/// (`(range 0 1 0.25)` is `(0 0.25 0.5 0.75)`, `(range 3.0)` is
/// `(0 1 2)`). A zero step is `:invalid-argument` (there is no
/// infinite sequence to return).
fn fnRange(vm: *VM, args: []const Value) VmError!Value {
    for (args) |a| if (a.kind() != .fixnum) return rangeNumbers(vm, args);
    const start: i64 = if (args.len == 1) 0 else try requireFixnum(args[0]);
    const end: i64 = try requireFixnum(args[if (args.len == 1) 0 else 1]);
    const step: i64 = if (args.len == 3) try requireFixnum(args[2]) else 1;
    if (step == 0) return VmError.InvalidArgument;
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    var i = start;
    while (if (step > 0) i < end else i > end) : (i += step) {
        items.append(vm.allocator, value_mod.fromFixnum(i) orelse return VmError.ArithmeticOverflow) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, items.items);
}

/// `range` over any numbers, through the tower.
fn rangeNumbers(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const start = if (args.len == 1) value_mod.fromFixnum(0).? else try requireNumber(args[0]);
    const end = try requireNumber(args[if (args.len == 1) 0 else 1]);
    const step = if (args.len == 3) try requireNumber(args[2]) else value_mod.fromFixnum(1).?;
    const sign = (try vm_mod.numSign(step)) orelse return VmError.InvalidArgument;
    if (sign == .eq) return VmError.InvalidArgument;
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    var x = start;
    while (try vm_mod.numCompare(if (sign == .gt) .lt else .gt, x, end)) : (x = try vm_mod.numAdd(heap, x, step)) {
        items.append(vm.allocator, x) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, items.items);
}

/// `(concat & colls)` → one list of every element in order.
fn fnConcat(vm: *VM, args: []const Value) VmError!Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    for (args) |c| try appendSeqValues(vm, c, &items);
    return try buildListFromSlice(vm, items.items);
}

/// `(mapcat f & colls)` → `(apply concat (map f & colls))`.
fn fnMapcat(vm: *VM, args: []const Value) VmError!Value {
    const mapped = try fnMap(vm, args);
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    var it = try makeSeqIter(vm, mapped);
    while (try it.next()) |sub| try appendSeqValues(vm, sub, &items);
    return try buildListFromSlice(vm, items.items);
}

/// `(into to from)` → `to` with every element of `from` conj'd;
/// `(into)` is `[]` and `(into to)` is `to`.
fn fnInto(vm: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return fnConj(vm, args);
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    if (items.items.len == 0) return args[0];
    // An empty vector with no metadata takes every element at once.
    if (args[0].kind() == .persistent_vector and vector_mod.isEmpty(args[0]) and heap_mod.Heap.asHeapHeader(args[0]).getMeta() == null) {
        return vector_mod.fromSlice(vm.ensureHeap(), items.items) catch VmError.OutOfMemory;
    }
    // A sorted target's comparator can collect while `conj` runs; a
    // map source's entries were built by the walk and reach from
    // nothing else (GC.md §11.5, class 4).
    const scope = vm.rootScope();
    defer scope.release();
    if (sorted_mod.isSortedKind(args[0].kind())) try scope.pushAll(items.items);
    const conj_args = vm.allocator.alloc(Value, items.items.len + 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(conj_args);
    conj_args[0] = args[0];
    @memcpy(conj_args[1..], items.items);
    return fnConj(vm, conj_args);
}

/// `(mapv f & colls)` / `(filterv pred coll)` — vector results.
fn fnMapv(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    try mapInto(vm, args[0], args[1..], scope);
    return vector_mod.fromSlice(vm.ensureHeap(), scopeItems(scope)) catch VmError.OutOfMemory;
}

fn fnFilterv(vm: *VM, args: []const Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    try sieveInto(vm, .keep_truthy, args[0], args[1], scope);
    return vector_mod.fromSlice(vm.ensureHeap(), scopeItems(scope)) catch VmError.OutOfMemory;
}

/// `(map-indexed f coll)` → `(f i x)`; `(keep-indexed f coll)` →
/// the non-nil `(f i x)`.
fn indexedMap(vm: *VM, keep_nil: bool, f: Value, coll: Value) VmError!Value {
    const scope = vm.rootScope();
    defer scope.release();
    var it = try makeSeqIter(vm, coll);
    var i: i64 = 0;
    while (try it.next()) |x| : (i += 1) {
        const r = try callBack(vm, f, &.{ value_mod.fromFixnum(i).?, x });
        if (keep_nil or !r.isNil()) try scope.push(r);
    }
    return try buildListFromSlice(vm, scopeItems(scope));
}

fn fnMapIndexed(vm: *VM, args: []const Value) VmError!Value {
    return indexedMap(vm, true, args[0], args[1]);
}

fn fnKeepIndexed(vm: *VM, args: []const Value) VmError!Value {
    return indexedMap(vm, false, args[0], args[1]);
}

/// `(distinct coll)` → first occurrences, in order.
fn fnDistinct(vm: *VM, args: []const Value) VmError!Value {
    var seen: ValueSet = .empty;
    defer seen.deinit(vm.allocator);
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    var it = try makeSeqIter(vm, args[0]);
    while (try it.next()) |x| {
        const entry = seen.getOrPut(vm.allocator, x) catch return VmError.OutOfMemory;
        if (entry.found_existing) continue;
        results.append(vm.allocator, x) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, results.items);
}

/// A scratch set of Values under the language's hash and equality,
/// on the VM allocator; freed when the native returns.
const ValueSet = std.HashMapUnmanaged(Value, void, struct {
    pub fn hash(_: @This(), v: Value) u64 {
        return dispatch_mod.hashValue(v);
    }
    pub fn eql(_: @This(), a: Value, b: Value) bool {
        return dispatch_mod.equal(a, b);
    }
}, std.hash_map.default_max_load_percentage);

/// `(partition n coll)` / `(partition n step coll)` /
/// `(partition n step pad coll)` → list of n-element lists; a
/// short tail is dropped unless `pad` supplies its missing
/// elements. `(partition-all n coll)` / `(partition-all n step
/// coll)` keeps the short tail.
fn partitionImpl(vm: *VM, all: bool, args: []const Value) VmError!Value {
    const n = try requireFixnum(args[0]);
    if (n <= 0) return VmError.InvalidArgument;
    const step: i64 = if (args.len >= 3) try requireFixnum(args[1]) else n;
    if (step <= 0) return VmError.InvalidArgument;
    const pad: ?Value = if (args.len == 4) args[2] else null;
    var items = try collectSeq(vm, args[args.len - 1]);
    defer items.deinit(vm.allocator);
    var pad_items: std.ArrayList(Value) = .empty;
    defer pad_items.deinit(vm.allocator);
    if (pad) |pv| try appendSeqValues(vm, pv, &pad_items);

    var groups: std.ArrayList(Value) = .empty;
    defer groups.deinit(vm.allocator);
    var group: std.ArrayList(Value) = .empty;
    defer group.deinit(vm.allocator);
    const un: usize = @intCast(n);
    const ustep: usize = @intCast(step);
    var at: usize = 0;
    while (at < items.items.len) : (at += ustep) {
        const end = @min(at + un, items.items.len);
        group.clearRetainingCapacity();
        group.appendSlice(vm.allocator, items.items[at..end]) catch return VmError.OutOfMemory;
        if (group.items.len < un) {
            if (pad != null) {
                var pi: usize = 0;
                while (group.items.len < un and pi < pad_items.items.len) : (pi += 1) {
                    group.append(vm.allocator, pad_items.items[pi]) catch return VmError.OutOfMemory;
                }
            } else if (!all) break;
        }
        groups.append(vm.allocator, try buildListFromSlice(vm, group.items)) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, groups.items);
}

fn fnPartition(vm: *VM, args: []const Value) VmError!Value {
    return partitionImpl(vm, false, args);
}

fn fnPartitionAll(vm: *VM, args: []const Value) VmError!Value {
    return partitionImpl(vm, true, args);
}

/// `(interleave & colls)` → round-robin elements until the
/// shortest collection runs out.
fn fnInterleave(vm: *VM, args: []const Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    if (args.len > 0) {
        const iters = vm.allocator.alloc(SeqIter, args.len) catch return VmError.OutOfMemory;
        defer vm.allocator.free(iters);
        for (args, 0..) |c, i| iters[i] = try makeSeqIter(vm, c);
        outer: while (true) {
            const mark = results.items.len;
            for (iters) |*it| {
                const x = (try it.next()) orelse {
                    results.shrinkRetainingCapacity(mark);
                    break :outer;
                };
                results.append(vm.allocator, x) catch return VmError.OutOfMemory;
            }
        }
    }
    return try buildListFromSlice(vm, results.items);
}

/// `(zipmap keys vals)` → map pairing keys with vals positionally.
fn fnZipmap(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var ks = try makeSeqIter(vm, args[0]);
    var vs = try makeSeqIter(vm, args[1]);
    while (try ks.next()) |k| {
        const v = (try vs.next()) orelse break;
        m = champ_mod.mapAssoc(heap, m, k, v, &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
    }
    return m;
}

/// `(take-while pred coll)` / `(drop-while pred coll)`.
fn whileSplit(vm: *VM, take: bool, pred: Value, coll: Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    const scope = vm.rootScope();
    defer scope.release();
    var it = try rootedSeqIter(vm, coll, scope);
    var dropping = true;
    while (try it.next()) |x| {
        if (dropping) {
            const r = try vm.callValue(pred, &.{x});
            if (r.isTruthy()) {
                if (take) results.append(vm.allocator, x) catch return VmError.OutOfMemory;
                continue;
            }
            dropping = false;
            if (take) break;
        }
        results.append(vm.allocator, x) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, results.items);
}

fn fnTakeWhile(vm: *VM, args: []const Value) VmError!Value {
    return whileSplit(vm, true, args[0], args[1]);
}

fn fnDropWhile(vm: *VM, args: []const Value) VmError!Value {
    return whileSplit(vm, false, args[0], args[1]);
}

/// `(butlast coll)` → all but the last element, nil when fewer
/// than two.
fn fnButlast(vm: *VM, args: []const Value) VmError!Value {
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    if (items.items.len < 2) return value_mod.nilValue();
    return try buildListFromSlice(vm, items.items[0 .. items.items.len - 1]);
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
    var it = try makeSeqIter(vm, c);
    var last = value_mod.nilValue();
    while (try it.next()) |x| last = x;
    return last;
}

/// `(reverse coll)` → a list of the elements in reverse order, `()`
/// when there are none.
fn fnReverse(vm: *VM, args: []const Value) VmError!Value {
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    std.mem.reverse(Value, items.items);
    return try buildListFromSlice(vm, items.items);
}

/// A count argument. Negative counts mean zero everywhere Clojure
/// takes one (`nthrest`, `split-at`, `take-last`, `repeat`, ...).
fn requireCount(v: Value) VmError!usize {
    return @intCast(@max(try requireFixnum(v), 0));
}

/// `(nthrest coll n)` → coll without its first n elements, as a
/// list; O(1) past a vector's elements (a view, LIST.md §1). As
/// Clojure's, coll itself when n is not positive or coll is empty.
fn fnNthrest(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireFixnum(args[1]);
    if (n <= 0 or args[0].isNil()) return args[0];
    const count: usize = @intCast(n);
    switch (args[0].kind()) {
        .list => return list_mod.drop(args[0], count),
        .persistent_vector => {
            const v = args[0];
            if (vector_mod.count(v) == 0) return v;
            return list_mod.ofVector(vm.ensureHeap(), v, @min(count, vector_mod.count(v))) catch VmError.OutOfMemory;
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
fn fnNthnext(vm: *VM, args: []const Value) VmError!Value {
    return fnSeq(vm, &.{try fnNthrest(vm, args)});
}

/// `(split-at n coll)` → `[(take n coll) (drop n coll)]`.
fn fnSplitAt(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    const at = @min(n, items.items.len);
    const head = try buildListFromSlice(vm, items.items[0..at]);
    const tail = try buildListFromSlice(vm, items.items[at..]);
    return vector_mod.fromSlice(vm.ensureHeap(), &.{ head, tail }) catch VmError.OutOfMemory;
}

/// `(take-last n coll)` / `(drop-last n coll)`; `take-last` of
/// nothing is nil, as Clojure's.
fn fnTakeLast(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    const keep = @min(n, items.items.len);
    if (keep == 0) return value_mod.nilValue();
    return try buildListFromSlice(vm, items.items[items.items.len - keep ..]);
}

fn fnDropLast(vm: *VM, args: []const Value) VmError!Value {
    const n = if (args.len == 1) 1 else try requireCount(args[0]);
    var items = try collectSeq(vm, args[args.len - 1]);
    defer items.deinit(vm.allocator);
    const drop = @min(n, items.items.len);
    return try buildListFromSlice(vm, items.items[0 .. items.items.len - drop]);
}

/// `(flatten coll)` → every non-sequential leaf of a list or
/// vector, depth first; nil leaves are kept. Anything that is not
/// sequential, nil included, flattens to `()`.
fn fnFlatten(vm: *VM, args: []const Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    if (isSequential(args[0].kind())) try flattenInto(vm, args[0], &results);
    return try buildListFromSlice(vm, results.items);
}

fn flattenInto(vm: *VM, v: Value, out: *std.ArrayList(Value)) VmError!void {
    stack_guard.check() catch return VmError.StackOverflow;
    if (!isSequential(v.kind())) return out.append(vm.allocator, v) catch VmError.OutOfMemory;
    var it = try makeSeqIter(vm, v);
    while (try it.next()) |x| try flattenInto(vm, x, out);
}

/// `(reductions f coll)` / `(reductions f init coll)` → every
/// intermediate accumulator of the fold.
fn fnReductions(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const scope = vm.rootScope();
    defer scope.release();
    var it = try rootedSeqIter(vm, args[args.len - 1], scope);
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    var acc = if (args.len == 3) args[1] else (try it.next()) orelse return try buildListFromSlice(vm, &.{try vm.callValue(f, &.{})});
    results.append(vm.allocator, acc) catch return VmError.OutOfMemory;
    while (try it.next()) |x| {
        acc = try vm.callValue(f, &.{ acc, x });
        const stop = isReduced(vm, acc);
        if (stop) acc = reducedValue(acc);
        try scope.push(acc);
        results.append(vm.allocator, acc) catch return VmError.OutOfMemory;
        if (stop) break;
    }
    return try buildListFromSlice(vm, results.items);
}

/// `(repeat n x)` → n copies of x. `(repeatedly n f)` → n results
/// of `(f)`. `(iterate f x n)` → the first n of x, (f x), (f (f x))
/// … — the count is explicit because sequences are eager.
fn fnRepeat(vm: *VM, args: []const Value) VmError!Value {
    var producer = struct {
        x: Value,
        fn next(self: *@This(), _: *VM) VmError!Value {
            return self.x;
        }
    }{ .x = args[1] };
    return repeatInto(vm, try requireCount(args[0]), &producer);
}

fn fnRepeatedly(vm: *VM, args: []const Value) VmError!Value {
    var producer = struct {
        f: Value,
        fn next(self: *@This(), vm_: *VM) VmError!Value {
            return vm_.callValue(self.f, &.{});
        }
    }{ .f = args[1] };
    return repeatInto(vm, try requireCount(args[0]), &producer);
}

fn fnIterate(vm: *VM, args: []const Value) VmError!Value {
    var producer = struct {
        f: Value,
        x: Value,
        started: bool = false,
        fn next(self: *@This(), vm_: *VM) VmError!Value {
            if (self.started) self.x = try vm_.callValue(self.f, &.{self.x});
            self.started = true;
            return self.x;
        }
    }{ .f = args[0], .x = args[1] };
    return repeatInto(vm, try requireCount(args[2]), &producer);
}

/// The list of `n` successive `producer.next(vm)` results. The list
/// grows as they come rather than reserving `n` slots, so a huge count
/// fails only when memory does, and a producer that throws first
/// throws.
fn repeatInto(vm: *VM, n: usize, producer: anytype) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    const scope = vm.rootScope();
    defer scope.release();
    for (0..n) |_| {
        const r = try producer.next(vm);
        try scope.push(r);
        results.append(vm.allocator, r) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, results.items);
}

/// `(max-key k x & xs)` / `(min-key k x & xs)` → the x with the
/// greatest / least `(k x)`; ties go to the later argument.
fn keyExtremum(vm: *VM, want_max: bool, args: []const Value) VmError!Value {
    const k = args[0];
    var best = args[1];
    var best_key = try vm.callValue(k, &.{best});
    // The best key so far is the one value kept across the next
    // call (GC.md §11.5); it goes on the root stack when it changes.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(best_key);
    for (args[2..]) |x| {
        const key = try vm.callValue(k, &.{x});
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
/// for `find`.
fn fnSelectKeys(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var out = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const src = args[0];
    switch (src.kind()) {
        .nil, .persistent_map, .record, .persistent_vector, .sorted_map => {},
        else => return VmError.KindMismatch,
    }
    // A sorted source's comparator can collect inside `find`: the
    // result so far and the keys the walk built are kept rooted
    // (GC.md §11.5, class 4).
    const scope = vm.rootScope();
    defer scope.release();
    const collects = src.kind() == .sorted_map and !sorted_mod.comparatorOf(src).isNil();
    if (collects) try scope.push(out);
    var ks = if (collects) try rootedSeqIter(vm, args[1], scope) else try makeSeqIter(vm, args[1]);
    while (try ks.next()) |k| {
        const entry = try fnFind(vm, &.{ src, k });
        if (entry.isNil()) continue;
        out = champ_mod.mapAssoc(heap, out, k, vector_mod.nth(entry, 1), &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
        if (collects) try scope.push(out);
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
    vm: *VM,
    comparator: ?Value,

    fn less(self: SortOrder, a: Value, b: Value) VmError!bool {
        const cmp = self.comparator orelse return (try compareValues(self.vm, a, b)) == .lt;
        const r = try self.vm.callValue(cmp, &.{ a, b });
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

/// Stable merge sort whose comparator may fail (it re-enters the
/// VM for user comparators).
fn mergeSort(items: []Keyed, scratch: []Keyed, order: SortOrder) VmError!void {
    if (items.len < 2) return;
    const mid = items.len / 2;
    try mergeSort(items[0..mid], scratch[0..mid], order);
    try mergeSort(items[mid..], scratch[mid..], order);
    @memcpy(scratch[0..items.len], items);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < items.len) : (k += 1) {
        if (try order.less(scratch[j].key, scratch[i].key)) {
            items[k] = scratch[j];
            j += 1;
        } else {
            items[k] = scratch[i];
            i += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) items[k] = scratch[i];
    while (j < items.len) : ({
        j += 1;
        k += 1;
    }) items[k] = scratch[j];
}

fn sortImpl(vm: *VM, keyfn: ?Value, comparator: ?Value, coll: Value) VmError!Value {
    var items = try collectSeq(vm, coll);
    defer items.deinit(vm.allocator);
    const keyed = vm.allocator.alloc(Keyed, items.items.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(keyed);
    const scratch = vm.allocator.alloc(Keyed, items.items.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(scratch);
    const scope = vm.rootScope();
    defer scope.release();
    // A map's entries were built by the walk and are reachable from
    // nothing else while the key function or comparator runs.
    if (keyfn != null or comparator != null) try scope.pushAll(items.items);
    for (items.items, 0..) |v, i| {
        const key = if (keyfn) |kf| try vm.callValue(kf, &.{v}) else v;
        if (keyfn != null) try scope.push(key);
        keyed[i] = .{ .key = key, .val = v };
    }
    try mergeSort(keyed, scratch, .{ .vm = vm, .comparator = comparator });
    for (keyed, 0..) |e, i| items.items[i] = e.val;
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
/// takes it by `any` or by the `:error` of its data. Keys are
/// interned at the call, not at boot.
fn fnExInfo(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    const names = [_][]const u8{ "message", "data", "cause" };
    for (args, 0..) |v, i| {
        const key = interner.internKeywordValue(names[i]) catch return VmError.OutOfMemory;
        m = champ_mod.mapAssoc(heap, m, key, v, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.OutOfMemory;
    }
    return m;
}

/// `(ex-data e)` → the `:data` of a map, nil for anything else.
fn fnExData(vm: *VM, args: []const Value) VmError!Value {
    return exEntry(vm, args[0], "data");
}

/// `(ex-message e)` → the `:message` of a map, nil for anything else.
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

/// `(read-string s)` → the first form of `s` as data; a string
/// that does not read throws `:reader-error`.
fn fnReadString(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    return try hooks.read_string(hooks.user_data, vm, string_mod.asBytes(args[0]));
}

/// `(eval form)` → the value of `form` compiled in the current
/// namespace and run on this VM; a form that does not compile throws
/// `{:error :compile-error :message "<CompileError>" :form form}`.
fn fnEval(vm: *VM, args: []const Value) VmError!Value {
    const hooks = vm.compiler_hooks orelse return vm.throwKeyword("no-compiler");
    return try hooks.eval(hooks.user_data, vm, args[0]);
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
        .list, .persistent_vector, .persistent_map, .persistent_set, .record, .typed_vector, .sorted_map, .sorted_set => true,
        else => false,
    };
}

/// `(meta x)` → the metadata map of a list, vector, map, set, record
/// or Var; nil for anything else or when none is attached.
fn fnMeta(_: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    if (x.kind() == .var_) return VM.asVar(x).meta;
    if (!carriesHeaderMeta(x.kind())) return value_mod.nilValue();
    const m = heap_mod.Heap.asHeapHeader(x).getMeta() orelse return value_mod.nilValue();
    // The metadata is a hash map or, when with-meta was given one, a
    // sorted map.
    if (m.kind == @intFromEnum(Kind.sorted_map)) return heap_mod.Heap.valueFromHeader(.sorted_map, m);
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
    const h = heap_mod.Heap.asHeapHeader(x);
    const body = heap_mod.Heap.bodyBytes(h);
    const copy = vm.ensureHeap().alloc(x.kind(), body.len) catch return VmError.OutOfMemory;
    @memcpy(heap_mod.Heap.bodyBytes(copy), body);
    copy.kind = h.kind;
    copy.flags = h.flags & ~heap_mod.flag_has_meta;
    copy.setMeta(meta_h);
    return .{ .tag = x.tag, .payload = @intFromPtr(copy) };
}

/// `(reset-meta! v m)` → sets the Var's metadata to `m` (a map or
/// nil) and returns it.
fn fnResetMeta(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    if (!args[1].isNil() and args[1].kind() != .persistent_map) return VmError.KindMismatch;
    try setVarMeta(vm, VM.asVar(args[0]), args[1]);
    return args[1];
}

/// Store `m` as `v`'s metadata; `:dynamic true` in it marks the
/// Var dynamic for good (`(def ^:dynamic *x* ...)`, VM.md §6.5).
fn setVarMeta(vm: *VM, v: *vm_mod.Var, m: Value) VmError!void {
    v.meta = m;
    if (m.isNil()) return;
    const key = vm.ensureInterner().internKeywordValue("dynamic") catch return VmError.OutOfMemory;
    switch (champ_mod.mapGet(m, key, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal)) {
        .present => |flag| if (flag.isTruthy()) {
            v.dynamic = true;
        },
        .absent => {},
    }
}

/// `(alter-meta! v f & args)` → sets the Var's metadata to
/// `(apply f (meta v) args)` and returns it.
fn fnAlterMeta(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    const v = VM.asVar(args[0]);
    const call_args = vm.allocator.alloc(Value, args.len - 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = v.meta;
    @memcpy(call_args[1..], args[2..]);
    const next = try vm.callValue(args[1], call_args);
    if (!next.isNil() and next.kind() != .persistent_map) return VmError.KindMismatch;
    try setVarMeta(vm, v, next);
    return next;
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

/// `(thread-bound? v)` → whether a `binding` of `v` is in force.
fn fnThreadBoundQ(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    return value_mod.fromBool(VM.asVar(args[0]).thread_bound);
}

/// `(gensym)` / `(gensym prefix)` → a fresh symbol `prefix__N`
/// (`G__N` by default), N counting up for the process.
var gensym_next: u64 = 0;

fn fnGensym(vm: *VM, args: []const Value) VmError!Value {
    const prefix: []const u8 = if (args.len == 1) try internedName(vm, args[0]) else "G";
    gensym_next += 1;
    const name = std.fmt.allocPrint(vm.allocator, "{s}__{d}", .{ prefix, gensym_next }) catch return VmError.OutOfMemory;
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
fn isVector(k: Kind) bool {
    return k == .persistent_vector;
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
        .list, .persistent_vector, .persistent_map, .persistent_set, .record, .sorted_map, .sorted_set => true,
        else => false,
    };
}
fn isVar(k: Kind) bool {
    return k == .var_;
}
/// Clojure's `Counted`: the collections, typed vectors and transients.
fn isCounted(k: Kind) bool {
    return isColl(k) or k == .typed_vector or k == .transient;
}
/// Clojure's `Indexed`: the vectors, `nth` in constant time.
fn isIndexed(k: Kind) bool {
    return k == .persistent_vector or k == .typed_vector;
}
fn isSequential(k: Kind) bool {
    return k == .list or k == .persistent_vector;
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
fn isIfn(k: Kind) bool {
    return isFn(k) or vm_mod.isLookupCallable(k);
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
// VM's allocator and appends it to `vm.db_connections`. `db/close`
// closes its env and leaves the struct in place; VM.deinit closes
// whatever is still open and frees every Connection.

/// Throw a db.zig / emdb / codec error to the program as its
/// keyword (`db.failureName`).
fn dbFailure(vm: *VM, err: anyerror) VmError {
    if (err == error.OutOfMemory) return VmError.OutOfMemory;
    return vm.throwKeyword(db_mod.failureName(err));
}

/// The VM's I/O, or the process-wide single-threaded one for a VM
/// the host gave none (a test harness): opening a store touches the
/// file system either way.
fn ioOf(vm: *VM) std.Io {
    return vm.io orelse std.Io.Threaded.global_single_threaded.io();
}

/// `(db/open path)` / `(db/open path {:durability d})`: the store at
/// `path`, created with its parent directories when absent (emdb
/// creates only the file). `d` is `:commit` or `:durable`; without it
/// the connection takes the process's (`NEXIS_DURABILITY`, DB.md §3.3).
fn fnDbOpen(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const durability = if (args.len > 1) try durabilityOption(vm, args[1]) else null;
    const path = string_mod.asBytes(args[0]);
    const io = ioOf(vm);
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path_z = vm.allocator.dupeZ(u8, path) catch return VmError.OutOfMemory;
    defer vm.allocator.free(path_z);
    const conn = vm.allocator.create(db_mod.Connection) catch return VmError.OutOfMemory;
    errdefer vm.allocator.destroy(conn);
    conn.* = db_mod.open(vm.allocator, vm.ensureHeap(), vm.ensureInterner(), path_z.ptr, .{ .allocator = vm.allocator }) catch |err| return dbFailure(vm, err);
    if (durability) |d| conn.durability = d;
    vm.db_close_callback = &dbCloseCallback;
    vm.db_connections.append(vm.allocator, @ptrCast(conn)) catch {
        db_mod.shutdown(conn);
        return VmError.OutOfMemory;
    };
    return .{ .tag = @intFromEnum(Kind.db_connection), .payload = @intFromPtr(conn) };
}

/// The `:durability` of a `db/open` options map; null when the map is
/// nil or has none.
fn durabilityOption(vm: *VM, opts: Value) VmError!?db_mod.Durability {
    if (opts.isNil()) return null;
    if (opts.kind() != .persistent_map) return VmError.KindMismatch;
    const k = vm.ensureInterner().internKeywordValue("durability") catch return VmError.OutOfMemory;
    const found = switch (champ_mod.mapGet(opts, k, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal)) {
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
        return dbFailure(vm, err);
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
    const result = db_mod.getRef(&txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
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
    const tree = db_mod.refTreeName(r);
    const key = db_mod.refKeyBytes(r);
    const result = db_mod.get(&txn, tree, key, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
    return value_mod.fromBool(result != null);
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
    return .{ .tag = @intFromEnum(Kind.db_write_txn), .payload = @intFromPtr(h) };
}

fn fnDbBeginRead(vm: *VM, args: []const Value) VmError!Value {
    const txn = try beginRead(vm, try openConn(args[0]));
    const h = db_mod.Handle.create(.{ .read = txn }) catch return VmError.OutOfMemory;
    return .{ .tag = @intFromEnum(Kind.db_read_txn), .payload = @intFromPtr(h) };
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
    const txn = try activeWrite(args[0]);
    const r = args[1];
    const v = args[2];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    db_mod.putRef(txn, r, v) catch |err| return dbFailure(vm, err);
    return value_mod.nilValue();
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
        inline else => |*t| db_mod.getRef(t, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err),
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
            const result = db_mod.getRef(&txn, x, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
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
            const e = vm.record_registry.items[record_mod.typeId(x)];
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
        if (publics and v.meta.kind() == .persistent_map) switch (champ_mod.mapGet(v.meta, private_key, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal)) {
            .present => |flag| if (flag.isTruthy()) continue,
            .absent => {},
        };
        const sym = interner.internSymbolValue(v.name) catch return VmError.OutOfMemory;
        m = champ_mod.mapAssoc(heap, m, sym, VM.varToValue(v), &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.OutOfMemory;
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
    const slash = if (text.len > 1) std.mem.indexOfScalar(u8, text, '/') else null;
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
    for (vm.record_registry.items) |e| {
        if (std.mem.eql(u8, e.ns_name, "nexis.core") and std.mem.eql(u8, e.type_name, "Delay")) return e.id;
    }
    return vm.registerRecordType("nexis.core", "Delay", &.{"state"}) catch VmError.OutOfMemory;
}

fn isDelay(vm: *const VM, v: Value) bool {
    if (v.kind() != .record) return false;
    const e = vm.record_registry.items[record_mod.typeId(v)];
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
    const fields = champ_mod.mapAssoc(heap, empty, key, state, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.OutOfMemory;
    return record_mod.make(heap, type_id, fields) catch VmError.OutOfMemory;
}

fn fnDelayQ(vm: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(isDelay(vm, args[0]));
}

/// `@d` of a delay: `(nexis.core/force d)`.
fn forceDelay(vm: *VM, d: Value) VmError!Value {
    const registry = vm.registry orelse return VmError.NotDerefable;
    const force = registry.core.lookupLocal("force") orelse return VmError.NotDerefable;
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
// Keys come back as keyword Values interned from the key bytes
// (the key model of `db/ref`). Each value is fully decoded onto
// the heap before the cursor advances. Results are eager.

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
        &dispatch_mod_alias.hashValue,
        &dispatch_mod_alias.equal,
    ) catch |err| return dbFailure(vm, err);
}

fn fnDbScan(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const tree_v = args[1];
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    const interner = vm.ensureInterner();
    const tree_name = interner.keywordName(tree_v.asKeywordId());

    // Optional range bounds: a keyword or symbol, whose name is the
    // key's bytes.
    const start_bytes: ?[]const u8 = if (args.len >= 3) try boundBytes(vm, args[2]) else null;
    const end_bytes: ?[]const u8 = if (args.len >= 4) try boundBytes(vm, args[3]) else null;

    var walk: db_mod.Walk = undefined;
    if (!try beginWalk(vm, &walk, try activeTxn(tx_v), tree_name)) {
        return vector_mod.fromSlice(vm.ensureHeap(), &.{}) catch VmError.OutOfMemory;
    }
    defer walk.end();

    var entries: std.ArrayList(Value) = .empty;
    defer entries.deinit(vm.allocator);

    var maybe_kv = walk.first(start_bytes);
    while (maybe_kv) |kv| : (maybe_kv = walk.next()) {
        if (end_bytes) |eb| {
            if (std.mem.order(u8, kv.key, eb) != .lt) break;
        }
        const decoded_v = try decodeEntry(vm, kv);
        const key_v = interner.internKeywordValue(kv.key) catch return VmError.OutOfMemory;
        const pair = [_]Value{ key_v, decoded_v };
        const pair_vec = vector_mod.fromSlice(vm.ensureHeap(), &pair) catch return VmError.OutOfMemory;
        entries.append(vm.allocator, pair_vec) catch return VmError.OutOfMemory;
    }

    return vector_mod.fromSlice(vm.ensureHeap(), entries.items) catch VmError.OutOfMemory;
}

fn boundBytes(vm: *VM, v: Value) VmError![]const u8 {
    if (v.kind() != .keyword and v.kind() != .symbol) return VmError.KindMismatch;
    return internedName(vm, v);
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

    var maybe_kv = walk.first(null);
    while (maybe_kv) |kv| : (maybe_kv = walk.next()) {
        const decoded_v = try decodeEntry(vm, kv);
        const key_v = interner.internKeywordValue(kv.key) catch return VmError.OutOfMemory;
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
    const current_opt = db_mod.getRef(&h.txn.write, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
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
    const called = vm.callValue(f, call_args);
    h.held -= 1;
    const new_value = try called;

    // 4. Write.
    db_mod.putRef(&h.txn.write, r, new_value) catch |err| return dbFailure(vm, err);
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

/// Leaves a transient as a raising `!` call found it (TRANSIENT.md §6):
/// on an error, and when an op hashed or compared past the stack guard,
/// which `callDirect` raises as `:stack-overflow` once the native
/// returns (SEMANTICS §2.7). The ops run before a collection can happen,
/// so the saved collection needs no root.
const TransientUndo = struct {
    t: Value,
    inner: *heap_mod.HeapHeader,
    overflows: u64,

    fn begin(t: Value) TransientUndo {
        return .{ .t = t, .inner = transient_mod.savedInner(t), .overflows = dispatch_mod.overflowCount() };
    }

    fn undo(self: TransientUndo) void {
        transient_mod.restoreInner(self.t, self.inner);
    }

    fn keepUnlessOverflowed(self: TransientUndo) Value {
        if (dispatch_mod.overflowCount() != self.overflows) self.undo();
        return self.t;
    }
};

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

/// `(conj! t x & xs)`; `(conj!)` is a transient vector, `(conj! t)` t.
fn fnConjBang(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    if (args.len == 0) return fnTransient(vm, &.{vector_mod.empty(heap) catch return VmError.OutOfMemory});
    const t = args[0];
    const sub = try requireTransient(t);
    const undo = TransientUndo.begin(t);
    errdefer undo.undo();
    for (args[1..]) |x| _ = switch (sub) {
        transient_mod.subkind_transient_map => try conjBangMap(vm, t, x),
        transient_mod.subkind_transient_set => transient_mod.setConjBang(heap, t, x, &dispatch_mod.hashValue, &dispatch_mod.equal),
        else => transient_mod.vectorConjBang(heap, t, x),
    } catch |err| return transientFailure(vm, err);
    return undo.keepUnlessOverflowed();
}

/// A transient map with `x` added as `conj` adds it to a map: a
/// `[k v]` entry, every entry of a map or record, or nothing for nil.
fn conjBangMap(vm: *VM, t: Value, x: Value) VmError!Value {
    const heap = vm.ensureHeap();
    switch (x.kind()) {
        .nil => return t,
        .persistent_map, .record, .sorted_map => {
            var result = t;
            var it = MapEntries.of(x).?;
            while (it.next()) |e| result = transient_mod.mapAssocBang(heap, result, e.key, e.value, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err);
            return result;
        },
        .persistent_vector => {
            if (vector_mod.count(x) != 2) return VmError.ArityMismatch;
            return transient_mod.mapAssocBang(heap, t, vector_mod.nth(x, 0), vector_mod.nth(x, 1), &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| transientFailure(vm, err);
        },
        else => return VmError.KindMismatch,
    }
}

/// `(assoc! t k v & kvs)` on a transient map or vector.
fn fnAssocBang(vm: *VM, args: []const Value) VmError!Value {
    if (args.len % 2 != 1) return VmError.ArityMismatch;
    const heap = vm.ensureHeap();
    const t = args[0];
    const sub = try requireTransient(t);
    if (sub == transient_mod.subkind_transient_set) return VmError.KindMismatch;
    const undo = TransientUndo.begin(t);
    errdefer undo.undo();
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const k = args[i];
        _ = if (sub == transient_mod.subkind_transient_map)
            transient_mod.mapAssocBang(heap, t, k, args[i + 1], &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err)
        else blk: {
            if (k.kind() != .fixnum) return VmError.KindMismatch;
            if (k.asFixnum() < 0) return VmError.IndexOutOfBounds;
            break :blk transient_mod.vectorAssocBang(heap, t, @intCast(k.asFixnum()), args[i + 1]) catch |err| return transientFailure(vm, err);
        };
    }
    return undo.keepUnlessOverflowed();
}

/// `(dissoc! t k & ks)` on a transient map.
fn fnDissocBang(vm: *VM, args: []const Value) VmError!Value {
    if (try requireTransient(args[0]) != transient_mod.subkind_transient_map) return VmError.KindMismatch;
    const undo = TransientUndo.begin(args[0]);
    errdefer undo.undo();
    for (args[1..]) |k| _ = transient_mod.mapDissocBang(vm.ensureHeap(), args[0], k, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err);
    return undo.keepUnlessOverflowed();
}

/// `(disj! t x & xs)` on a transient set.
fn fnDisjBang(vm: *VM, args: []const Value) VmError!Value {
    if (try requireTransient(args[0]) != transient_mod.subkind_transient_set) return VmError.KindMismatch;
    const undo = TransientUndo.begin(args[0]);
    errdefer undo.undo();
    for (args[1..]) |x| _ = transient_mod.setDisjBang(vm.ensureHeap(), args[0], x, &dispatch_mod.hashValue, &dispatch_mod.equal) catch |err| return transientFailure(vm, err);
    return undo.keepUnlessOverflowed();
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
                        if (a.isNil()) w.writeAll("nil") catch return VmError.OutOfMemory else try appendStrValue(&piece, a, interner);
                        if (precision) |p| piece.shrinkRetainingCapacity(codepointPrefix(piece.written(), p));
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

/// The byte length of the first `n` code points of `text`.
fn codepointPrefix(text: []const u8, n: usize) usize {
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    for (0..n) |_| _ = it.nextCodepointSlice() orelse break;
    return it.i;
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
// All six fns enforce identity-equality / identity-hash invariants
// by going through `atom_mod`'s typed accessors. Re-entrancy is
// detected via `atom_mod.tryEnterCritical` + a `defer` pairing on
// `exitCritical` so the flag clears on every exit path — normal
// return, recoverable VmError, OutOfMemory, ControlTransferred.
//
// `vm.callValue` is the reentrant call point (same shape as
// `fnDbAlter`, `fnApply`, `fnMap`). Rollback-on-throw is ensured
// by ordering: the atom is written ONLY after `callValue` returns
// normally (steps 3 → 4 in each function). If `callValue` throws
// or control-transfers, the write never executes.

fn fnAtom(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    return atom_mod.make(heap, args[0]) catch return VmError.OutOfMemory;
}

fn fnAtomQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .atom);
}

fn fnResetBang(_: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    const new_val = args[1];
    if (a.kind() != .atom) return VmError.KindMismatch;
    if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
    defer atom_mod.exitCritical(a);
    atom_mod.setValue(a, new_val);
    return new_val;
}

/// `(swap! a f & args)` → sets `a` to `(apply f @a args)` and
/// returns it; `swap-vals!` returns `[old new]`. Nothing is written
/// when `f` throws or control transfers.
fn swapImpl(vm: *VM, args: []const Value, pair: bool) VmError!Value {
    const a = args[0];
    if (a.kind() != .atom) return VmError.KindMismatch;
    if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
    defer atom_mod.exitCritical(a);
    const old = atom_mod.getValue(a);
    const call_args = vm.allocator.alloc(Value, args.len - 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = old;
    @memcpy(call_args[1..], args[2..]);
    const new_val = try vm.callValue(args[1], call_args);
    // `old` is the atom's value, hence rooted, throughout the
    // callback; the [old new] vector is built after `setValue` with
    // no safe point in between (a cycle runs only between
    // instructions, VM.md §9).
    atom_mod.setValue(a, new_val);
    if (!pair) return new_val;
    return vector_mod.fromSlice(vm.ensureHeap(), &.{ old, new_val }) catch VmError.OutOfMemory;
}

fn fnSwapBang(vm: *VM, args: []const Value) VmError!Value {
    return swapImpl(vm, args, false);
}

fn fnSwapValsBang(vm: *VM, args: []const Value) VmError!Value {
    return swapImpl(vm, args, true);
}

fn fnCompareAndSetBang(_: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    const old = args[1];
    const new_val = args[2];

    if (a.kind() != .atom) return VmError.KindMismatch;
    if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
    defer atom_mod.exitCritical(a);

    // identical? semantics, not structural `=`. Matches Clojure's
    // documented "identical to oldval" CAS contract. For
    // immediates, bit-identity. For heap kinds, pointer-identity
    // (HeapHeader). See ATOM.md §4.6.
    const current = atom_mod.getValue(a);
    if (current.tag == old.tag and current.payload == old.payload) {
        atom_mod.setValue(a, new_val);
        return value_mod.fromBool(true);
    }
    return value_mod.fromBool(false);
}

// =============================================================================
// Core string ops
// =============================================================================
//
// `(str & xs)` is display-mode stringify+concat. Nil semantics
// are split: `format(.display, nil)` writes "nil", so `str` /
// `join` / `spit` each wrap their element path to convert
// nil → empty BEFORE delegating to the formatter.
//
// GC rooting: str / pr-str allocate the final heap string after
// walking the args slice, which is rooted for the call, and never
// call back into the VM (`docs/GC.md` §11.5, class 1).

/// Append `v` as `str` makes it text (Clojure's `toString`): nil is
/// empty, a string or char is itself, anything else prints as `pr`
/// prints it, so the strings inside a collection keep their quotes.
/// Used by `str`, `join` and `spit`.
fn appendStrValue(
    w: *std.Io.Writer.Allocating,
    v: Value,
    interner: ?*const intern_mod.Interner,
) VmError!void {
    if (v.kind() == .nil) return;
    // A float by itself is Java's `toString` (`Infinity`), as Clojure's
    // `str` makes it; inside a collection it prints readable (`##Inf`).
    if (v.isFloat()) return format_mod.formatFloatJava(v.asFloat(), &w.writer) catch return VmError.OutOfMemory;
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
    if (args.len == 1 and args[0].kind() == .string) return args[0];
    var len: usize = 0;
    for (args) |x| len += plainStrLen(x) orelse return strFormatted(vm, args);
    const out = string_mod.allocUninit(vm.ensureHeap(), len) catch return VmError.OutOfMemory;
    var rest = out.bytes;
    for (args) |x| rest = writePlainStr(x, rest);
    return out.value;
}

fn strFormatted(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    for (args) |x| try appendStrValue(&w, x, interner);
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
// nexis.string namespace
// =============================================================================
//
// The fifteen natives of `string_natives` (docs/STDLIB.md §3);
// `capitalize`, `reverse` and `split-lines` are in string.nx. Case
// mapping is ASCII-only. Searches, `split` and `replace` compare
// bytes with `string.Matches`, which on valid UTF-8 matches only at
// code-point boundaries; indexes count code points.
//
// Errors are catchable keywords: `:kind-mismatch` for an argument of
// the wrong kind, `:utf8-error` for a malformed string a function
// reads by code point (`split` and `replace` validate every string
// argument first).
//
// GC rooting: each fn allocates output via string.fromBytes /
// vector.fromSlice while holding only its arguments, which are
// rooted for the call, and never calls back into the VM
// (docs/GC.md §11.5, class 1).

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

/// The six ASCII whitespace characters: space, tab, LF, VT, FF, CR.
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
        const len = std.unicode.utf8ByteSequenceLength(src[lo]) catch break;
        if (len > hi - lo) break;
        const c = std.unicode.utf8Decode(src[lo..][0..len]) catch break;
        if (!isTrimmed(c)) break;
        lo += len;
    };
    if (right) while (hi > lo) {
        var start = hi - 1;
        while (start > lo and src[start] & 0xC0 == 0x80) start -= 1;
        const c = std.unicode.utf8Decode(src[start..hi]) catch break;
        if (!isTrimmed(c)) break;
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
        const len = std.unicode.utf8ByteSequenceLength(src[i]) catch return value_mod.fromBool(false);
        if (len > src.len - i) return value_mod.fromBool(false);
        const c = std.unicode.utf8Decode(src[i..][0..len]) catch return value_mod.fromBool(false);
        if (!isJavaWhitespace(c)) return value_mod.fromBool(false);
        i += len;
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
        std.mem.lastIndexOf(u8, src[0..@min(src.len, at.start + needle.len)], needle)
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
    if (args[0].kind() != .string or args[1].kind() != .string) return VmError.KindMismatch;
    const src = string_mod.asBytes(args[0]);
    const sep = string_mod.asBytes(args[1]);
    const limit: i64 = if (args.len == 3) try requireFixnum(args[2]) else 0;
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
    pieces.append(vm.allocator, string_mod.fromBytes(heap, src[start..]) catch return VmError.OutOfMemory) catch return VmError.OutOfMemory;
    if (limit == 0 and src.len > 0) {
        while (pieces.items.len > 0 and string_mod.byteLen(pieces.items[pieces.items.len - 1]) == 0) _ = pieces.pop();
    }
    return vector_mod.fromSlice(heap, pieces.items) catch VmError.OutOfMemory;
}

/// `(nexis.string/join coll)` / `(nexis.string/join sep coll)` → the
/// elements of any seqable as `str` makes them text (nil is empty),
/// separated by `sep`.
fn fnStringJoin(vm: *VM, args: []const Value) VmError!Value {
    const sep: []const u8 = if (args.len == 2) blk: {
        if (args[0].kind() != .string) return VmError.KindMismatch;
        break :blk string_mod.asBytes(args[0]);
    } else "";
    const coll = args[args.len - 1];
    if (try joinPlain(vm, sep, coll)) |joined| return joined;
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    var it = try makeSeqIter(vm, coll);
    var first = true;
    while (try it.next()) |x| {
        if (!first) w.writer.writeAll(sep) catch return VmError.OutOfMemory;
        first = false;
        try appendStrValue(&w, x, interner);
    }
    return string_mod.fromBytes(vm.ensureHeap(), w.written()) catch VmError.OutOfMemory;
}

/// `join` of a collection whose elements are all nil, strings, chars
/// or fixnums: measured in one walk, written in a second into a
/// string of that length. Null at the first element that is not, for
/// the printer's path.
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
/// one thread; each buffer is on the allocator of the VM that pushed
/// it.
var out_stack: std.ArrayList(std.ArrayList(u8)) = .empty;

fn writeOut(vm: *VM, bytes: []const u8) VmError!void {
    if (out_stack.items.len > 0) {
        out_stack.items[out_stack.items.len - 1].appendSlice(vm.allocator, bytes) catch return VmError.OutOfMemory;
        return;
    }
    const io_handle = vm.io orelse return VmError.IoError;
    std.Io.File.stdout().writeStreamingAll(io_handle, bytes) catch return VmError.IoError;
}

/// `args` formatted in `mode`, separated by spaces, into `w`. The
/// writer is an Allocating buffer, so a failed write is an allocation
/// failure.
fn formatArgs(vm: *VM, w: *std.Io.Writer.Allocating, args: []const Value, mode: format_mod.FormatMode) VmError!void {
    const interner = vm.ensureInterner();
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
fn fnPushOut(vm: *VM, _: []const Value) VmError!Value {
    out_stack.append(vm.allocator, .empty) catch return VmError.OutOfMemory;
    return value_mod.nilValue();
}

fn fnPopOut(vm: *VM, _: []const Value) VmError!Value {
    var buf = out_stack.pop() orelse return VmError.InvalidArgument;
    defer buf.deinit(vm.allocator);
    if (out_stack.items.len == 0) out_stack.clearAndFree(vm.allocator);
    return string_mod.fromBytes(vm.ensureHeap(), buf.items) catch VmError.OutOfMemory;
}

/// `(bound? v & vs)` → whether every Var has a root value.
fn fnBoundQ(_: *VM, args: []const Value) VmError!Value {
    for (args) |v| {
        if (v.kind() != .var_) return VmError.KindMismatch;
        if (!VM.asVar(v).bound) return value_mod.fromBool(false);
    }
    return value_mod.fromBool(true);
}

/// `(nano-time)` → a monotonic clock in nanoseconds, for measuring
/// intervals (Java's `System/nanoTime`).
fn fnNanoTime(vm: *VM, _: []const Value) VmError!Value {
    const now = std.Io.Clock.awake.now(ioOf(vm));
    return value_mod.fromFixnum(@intCast(@mod(now.nanoseconds, value_mod.fixnum_max))) orelse VmError.ArithmeticOverflow;
}

/// A path argument of `slurp` / `spit`: a string, not empty, with
/// no NUL byte (`:invalid-path`).
fn pathArg(v: Value) VmError![]const u8 {
    if (v.kind() != .string) return VmError.KindMismatch;
    const path = string_mod.asBytes(v);
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return VmError.InvalidPath;
    return path;
}

/// `(slurp path)` → the file's text. `:file-not-found` for a missing
/// file, `:utf8-error` for text that is not UTF-8, `:io-error` for
/// any other failure.
fn fnSlurp(vm: *VM, args: []const Value) VmError!Value {
    const path = try pathArg(args[0]);
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
    const path = try pathArg(args[0]);
    if (args.len % 2 != 0) return VmError.ArityMismatch;
    var append = false;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (args[i].kind() != .keyword or !std.mem.eql(u8, vm.ensureInterner().keywordName(args[i].asKeywordId()), "append")) return VmError.InvalidArgument;
        append = args[i + 1].isTruthy();
    }
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    try appendStrValue(&w, args[1], vm.ensureInterner());
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
    for (vm.db_connections.items) |conn| db_mod.shutdown(@ptrCast(@alignCast(conn)));
    if (vm.nextomic_close_callback) |close| for (vm.nextomic_connections.items) |conn| close(conn);
    db_mod.StoreFile.syncAll();
    std.process.exit(status);
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
fn fnRegisterRecordType(vm: *VM, args: []const Value) VmError!Value {
    const full_name_v = args[0];
    const fields_vec = args[1];
    if (full_name_v.kind() != .string) return VmError.KindMismatch;
    if (fields_vec.kind() != .persistent_vector) return VmError.KindMismatch;

    const full_name = string_mod.asBytes(full_name_v);
    // Split on the LAST `/` for `ns/name`.
    var ns_name: []const u8 = "";
    var type_name: []const u8 = full_name;
    if (std.mem.lastIndexOfScalar(u8, full_name, '/')) |slash_idx| {
        ns_name = full_name[0..slash_idx];
        type_name = full_name[slash_idx + 1 ..];
    }

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

    const new_id = vm.registerRecordType(ns_name, type_name, field_names) catch return VmError.OutOfMemory;
    return value_mod.fromFixnum(@intCast(new_id)) orelse VmError.ArithmeticOverflow;
}

/// `(#%make-record type-id field-map)` → record Value.
fn fnMakeRecord(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .fixnum) return VmError.KindMismatch;
    const id = args[0].asFixnum();
    if (id < 0) return VmError.KindMismatch;
    if (args[1].kind() != .persistent_map) return VmError.KindMismatch;
    return record_mod.make(vm.ensureHeap(), @intCast(id), args[1]) catch return VmError.OutOfMemory;
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

    const full_name = string_mod.asBytes(full_name_v);
    var ns_name: []const u8 = "";
    var proto_name: []const u8 = full_name;
    if (std.mem.lastIndexOfScalar(u8, full_name, '/')) |slash_idx| {
        ns_name = full_name[0..slash_idx];
        proto_name = full_name[slash_idx + 1 ..];
    }

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

    const new_id = vm.registerProtocol(ns_name, proto_name, specs) catch return VmError.OutOfMemory;
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
    if (args[2].kind() != .fixnum) return VmError.KindMismatch;
    // args[3] is the impl callable: closure / native_fn / etc.
    // We don't validate its kind here — dispatchProtocolMethod
    // calls `callValue` which surfaces NotCallable if it's not
    // invocable. Errors point at the user's impl form rather
    // than this scaffolding.
    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = args[1].asKeywordId();
    const type_id_signed = args[2].asFixnum();
    if (type_id_signed < 0) return VmError.KindMismatch;
    const type_id: u32 = @intCast(type_id_signed);
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
// `typeNameToKind` (PROTOCOLS.md §4.3).
//
// Plus the friendly aliases:
//   :vector → :persistent_vector
//   :map    → :persistent_map
//   :set    → :persistent_set
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
    const kind = typeNameToKind(type_name) orelse return VmError.InvalidArgument;
    const key = vm_mod.DispatchKey{ .tag = .builtin, .id = @intFromEnum(kind) };

    vm.extendProtocol(protocol_id, method_name_id, key, args[3]) catch |err| switch (err) {
        error.NoProtocolMethod => return VmError.NoProtocolMethod,
        error.OutOfMemory => return VmError.OutOfMemory,
    };
    return value_mod.nilValue();
}

/// `(#%kwargs rest)` → the map a `& {...}` pattern destructures:
/// `rest` as alternating keys and values, a single trailing map
/// as itself, nil or empty as `{}`; an odd count is
/// `:invalid-argument`.
fn fnKwargs(vm: *VM, args: []const Value) VmError!Value {
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    if (items.items.len == 1 and isMap(items.items[0].kind())) return items.items[0];
    if (items.items.len % 2 != 0) return VmError.InvalidArgument;
    const heap = vm.ensureHeap();
    var m = champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory;
    var i: usize = 0;
    while (i < items.items.len) : (i += 2) {
        m = champ_mod.mapAssoc(heap, m, items.items[i], items.items[i + 1], &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch return VmError.OutOfMemory;
    }
    return m;
}

/// `(#%catch-matches? v tag)` → whether `(catch tag e ...)` takes the
/// thrown `v`: `v` is `tag` itself, or a map or record whose
/// `:error` entry is `tag`.
fn fnCatchMatches(vm: *VM, args: []const Value) VmError!Value {
    const v = args[0];
    const tag = args[1];
    if (dispatch_mod_alias.equal(v, tag)) return value_mod.fromBool(true);
    if (v.kind() != .persistent_map and v.kind() != .record) return value_mod.fromBool(false);
    const interner = vm.ensureInterner();
    const error_key = interner.internKeywordValue("error") catch return VmError.OutOfMemory;
    if (dispatch_mod_alias.equal(try vm_mod.lookup(v, error_key, value_mod.nilValue()), tag)) return value_mod.fromBool(true);
    // An `ex-info` map: its data's `:error`.
    const data_key = interner.internKeywordValue("data") catch return VmError.OutOfMemory;
    const data = try vm_mod.lookup(v, data_key, value_mod.nilValue());
    if (data.kind() != .persistent_map) return value_mod.fromBool(false);
    return value_mod.fromBool(dispatch_mod_alias.equal(try vm_mod.lookup(data, error_key, value_mod.nilValue()), tag));
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
fn typeNameToKind(name: []const u8) ?value_mod.Kind {
    if (std.mem.eql(u8, name, "vector")) return .persistent_vector;
    if (std.mem.eql(u8, name, "map")) return .persistent_map;
    if (std.mem.eql(u8, name, "set")) return .persistent_set;
    // Iterate over Kind tags at comptime so this stays in sync
    // with the enum without a hand-maintained table.
    inline for (std.meta.fields(value_mod.Kind)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            return @field(value_mod.Kind, field.name);
        }
    }
    return null;
}

// =============================================================================
// Helpers
// =============================================================================

/// Walks any seqable: nil, list, vector, map or record (as `[k v]`
/// entries), set, string (as chars).
///
/// A map entry and a boxed typed-vector element are built by the
/// iterator, so no argument reaches them (docs/GC.md §11.5). A native
/// that keeps what the iterator yields across a call back into the VM
/// iterates with `rootedSeqIter`, which pushes each such value on the
/// native's `RootScope`.
const SeqIter = struct {
    state: union(enum) {
        empty,
        list: list_mod.Cursor,
        vector: vector_mod.Cursor,
        typed: struct { v: Value, idx: usize, count: usize, heap: *heap_mod.Heap },
        map: struct { it: champ_mod.MapIter, heap: *heap_mod.Heap },
        set: champ_mod.SetIter,
        sorted: struct { it: sorted_mod.Iter, heap: *heap_mod.Heap },
        string: std.unicode.Utf8Iterator,
    },
    roots: ?vm_mod.RootScope = null,

    fn next(self: *SeqIter) VmError!?Value {
        switch (self.state) {
            .empty => return null,
            .list => |*c| return c.next(),
            .vector => |*c| return c.next(),
            .typed => |*tv| {
                if (tv.idx >= tv.count) return null;
                const e = typed_vector_mod.nth(tv.heap, tv.v, tv.idx) catch return VmError.OutOfMemory;
                tv.idx += 1;
                return try self.built(e);
            },
            .map => |*m| {
                const e = m.it.next() orelse return null;
                return try self.built(vector_mod.fromSlice(m.heap, &.{ e.key, e.value }) catch return VmError.OutOfMemory);
            },
            .set => |*it| return it.next(),
            .sorted => |*st| {
                const e = st.it.next() orelse return null;
                if (!st.it.is_map) return e.key;
                return try self.built(vector_mod.fromSlice(st.heap, &.{ e.key, e.value }) catch return VmError.OutOfMemory);
            },
            .string => |*utf8| {
                const scalar = utf8.nextCodepoint() orelse return null;
                return value_mod.fromChar(scalar) orelse VmError.Utf8Error;
            },
        }
    }

    fn built(self: *SeqIter, v: Value) VmError!Value {
        if (self.roots) |scope| try scope.push(v);
        return v;
    }
};

/// Every seqable receiver: nil, list, vector, map (as `[k v]`
/// entries), record (its field map), lazy entity (its attributes,
/// read in one pass), set, sorted map and set (in order) and string
/// (as chars). A string that is
/// not valid UTF-8 is `:utf8-error`, as for every other string
/// operation.
fn makeSeqIter(vm: *VM, coll: Value) VmError!SeqIter {
    return .{ .state = switch (coll.kind()) {
        .nil => .empty,
        .list => .{ .list = list_mod.Cursor.init(coll) },
        .persistent_vector => .{ .vector = vector_mod.Cursor.init(coll) },
        .typed_vector => .{ .typed = .{ .v = coll, .idx = 0, .count = typed_vector_mod.count(coll), .heap = vm.ensureHeap() } },
        .persistent_map => .{ .map = .{ .it = champ_mod.mapIter(coll), .heap = vm.ensureHeap() } },
        .record => .{ .map = .{ .it = champ_mod.mapIter(record_mod.fieldsOf(coll)), .heap = vm.ensureHeap() } },
        .nextomic_entity => .{ .map = .{ .it = champ_mod.mapIter(try nextomic_mod.natives.entityMap(vm, coll)), .heap = vm.ensureHeap() } },
        .persistent_set => .{ .set = champ_mod.setIter(coll) },
        .sorted_map, .sorted_set => .{ .sorted = .{ .it = sorted_mod.Iter.init(coll, true), .heap = vm.ensureHeap() } },
        .string => .{
            .string = (std.unicode.Utf8View.init(string_mod.asBytes(coll)) catch return VmError.Utf8Error).iterator(),
        },
        else => return VmError.KindMismatch,
    } };
}

/// `makeSeqIter` whose built values stay rooted in `scope`.
fn rootedSeqIter(vm: *VM, coll: Value, scope: vm_mod.RootScope) VmError!SeqIter {
    var it = try makeSeqIter(vm, coll);
    it.roots = scope;
    return it;
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
    var it = try makeSeqIter(vm, seq);
    while (try it.next()) |e| {
        out.append(vm.allocator, e) catch return VmError.OutOfMemory;
    }
}

/// A fresh list of `items`, in order: `view_min` or more are a
/// vector and its view (LIST.md §1), a few blocks for any length and
/// an O(1) `count`; fewer are cons cells. Nothing built needs a root:
/// `Heap.alloc` never collects (VM.md §9).
fn buildListFromSlice(vm: *VM, items: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    if (items.len < view_min or items.len > std.math.maxInt(u32)) return list_mod.fromSlice(heap, items) catch VmError.OutOfMemory;
    const vec = vector_mod.fromSlice(heap, items) catch return VmError.OutOfMemory;
    return list_mod.ofVector(heap, vec, 0) catch VmError.OutOfMemory;
}

/// The length from which a built list is a vector view: below it,
/// the cons cells are fewer blocks than a vector's root, tail and
/// view.
const view_min = 4;

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
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    const elems = vm.allocator.alloc(i64, items.items.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(elems);
    for (elems, items.items) |*slot, v| slot.* = try i64Elem(v);
    return typed_vector_mod.fromI64Slice(vm.ensureHeap(), elems) catch VmError.OutOfMemory;
}

/// `(f64-vector coll)`: an `f64` typed vector of the numbers in
/// `coll`, any seqable; integers widen.
fn fnF64Vector(vm: *VM, args: []const Value) VmError!Value {
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    const elems = vm.allocator.alloc(f64, items.items.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(elems);
    for (elems, items.items) |*slot, v| slot.* = try f64Elem(v);
    return typed_vector_mod.fromF64Slice(vm.ensureHeap(), elems) catch VmError.OutOfMemory;
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
            for (out, 0..) |*slot, i| {
                const x = typed_vector_mod.nth(heap, xs, i) catch return VmError.OutOfMemory;
                slot.* = try i64Elem(try vm.callValue(f, &.{x}));
            }
            return typed_vector_mod.fromI64Slice(heap, out) catch VmError.OutOfMemory;
        },
        .f64 => {
            const out = vm.allocator.alloc(f64, n) catch return VmError.OutOfMemory;
            defer vm.allocator.free(out);
            for (out, typed_vector_mod.f64Elems(xs)) |*slot, x| {
                slot.* = try f64Elem(try vm.callValue(f, &.{value_mod.fromFloat(x)}));
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
    var dbg: std.heap.DebugAllocator(.{}) = .init;
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
