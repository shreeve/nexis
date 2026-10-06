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
// `NeedsReentry` (`NativeFn.general`). `table` turns it into static
// descriptors (immortal, so a `.native_fn` Value can point at one); a
// descriptor outside nexis.core is named `ns/name` for traces and
// printing.

fn table(comptime ns: []const u8, comptime entries: anytype) [entries.len]NativeFn {
    var out: [entries.len]NativeFn = undefined;
    inline for (entries, 0..) |e, i| out[i] = .{
        .name = if (ns.len == 0) e[0] else ns ++ "/" ++ e[0],
        .min_arity = e[1],
        .max_arity = e[2],
        .call = e[3],
        .leaf = if (e.len > 4) e[4] == .leaf else false,
        .general = if (e.len > 5) e[5] else null,
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
    .{ .ns = "nexis.core", .info = .{ .path = "core.nx", .text = @embedFile("stdlib/core.nx") } },
    // Sugar over the Nextomic natives (`with-conn`).
    .{ .ns = "nextomic", .info = .{ .path = "nextomic.nx", .text = @embedFile("stdlib/nextomic.nx") } },
    // Clojure's clojure.walk; before test.nx, whose `are` uses it.
    .{ .ns = "nexis.walk", .info = .{ .path = "walk.nx", .text = @embedFile("stdlib/walk.nx") } },
    // Clojure's clojure.edn.
    .{ .ns = "nexis.edn", .info = .{ .path = "edn.nx", .text = @embedFile("stdlib/edn.nx") } },
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
    .{ "take", 1, 2, &fnTake },
    .{ "drop", 1, 2, &fnDrop },
    .{ "some", 2, 2, &fnSome },
    .{ "every?", 2, 2, &fnEveryQ },
    .{ "count", 1, 1, &fnCountLeaf, .leaf, &fnCount },
    .{ "nth", 2, 3, &fnNth, .leaf, &fnNthGeneral },
    .{ "empty?", 1, 1, &fnEmptyQ },
    .{ "identity", 1, 1, &fnIdentity, .leaf },
    .{ "nil?", 1, 1, &fnNilQ, .leaf },
    .{ "some?", 1, 1, &fnSomeQ, .leaf },
    // First-class arithmetic + comparison Vars.
    // Required so `(reduce + 0 xs)` resolves `+` as a Var.
    // `(+ x y)` at the call head is still inlined by the
    // compiler; the Var is only reached through non-head uses.
    .{ "+", 0, null, &fnAdd, .leaf },
    .{ "-", 1, null, &fnSub, .leaf },
    .{ "*", 0, null, &fnMul, .leaf },
    .{ "/", 1, null, &fnDiv },
    .{ "quot", 2, 2, &fnQuot },
    .{ "rem", 2, 2, &fnRem },
    .{ "mod", 2, 2, &fnMod },
    .{ "<", 0, null, &fnLt, .leaf },
    .{ "<=", 0, null, &fnLte, .leaf },
    .{ ">", 0, null, &fnGt, .leaf },
    .{ ">=", 0, null, &fnGte, .leaf },
    .{ "==", 0, null, &fnNumEq, .leaf },
    .{ "=", 0, null, &fnEq },
    .{ "not=", 1, null, &fnNotEq },
    .{ "inc", 1, 1, &fnInc, .leaf },
    .{ "dec", 1, 1, &fnDec, .leaf },
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
    .{ "max", 1, null, &fnMax, .leaf },
    .{ "min", 1, null, &fnMin, .leaf },
    .{ "abs", 1, 1, &fnAbs },
    .{ "number?", 1, 1, &fnNumberQ },
    .{ "integer?", 1, 1, &fnIntegerQ },
    .{ "float?", 1, 1, &fnFloatQ },
    .{ "NaN?", 1, 1, &fnNanQ },
    .{ "infinite?", 1, 1, &fnInfiniteQ },
    .{ "not", 1, 1, &fnNot, .leaf },
    .{ "zero?", 1, 1, &fnZeroQ, .leaf },
    .{ "pos?", 1, 1, &fnPosQ, .leaf },
    .{ "neg?", 1, 1, &fnNegQ, .leaf },
    .{ "odd?", 1, 1, &fnOddQ, .leaf },
    .{ "even?", 1, 1, &fnEvenQ, .leaf },
    // apply + HOFs.
    .{ "apply", 2, null, &fnApply },
    .{ "map", 1, null, &fnMap },
    .{ "reduce", 2, 3, &fnReduce },
    .{ "reduce-kv", 3, 3, &fnReduceKv },
    .{ "filter", 1, 2, &fnFilter },
    .{ "remove", 1, 2, &fnRemove },
    .{ "keep", 1, 2, &fnKeep },
    .{ "seq", 1, 1, &fnSeq },
    .{ "next", 1, 1, &fnNext },
    .{ "range", 0, 3, &fnRange },
    .{ "concat", 0, null, &fnConcat },
    .{ "mapcat", 1, null, &fnMapcat },
    .{ "into", 0, 3, &fnInto },
    .{ "mapv", 2, null, &fnMapv },
    .{ "filterv", 2, 2, &fnFilterv },
    .{ "map-indexed", 1, 2, &fnMapIndexed },
    .{ "keep-indexed", 1, 2, &fnKeepIndexed },
    .{ "distinct", 0, 1, &fnDistinct },
    .{ "dedupe", 0, 1, &fnDedupe },
    .{ "partition", 2, 4, &fnPartition },
    .{ "partition-all", 1, 3, &fnPartitionAll },
    .{ "zipmap", 2, 2, &fnZipmap },
    .{ "take-while", 1, 2, &fnTakeWhile },
    .{ "drop-while", 1, 2, &fnDropWhile },
    .{ "butlast", 1, 1, &fnButlast },
    .{ "last", 1, 1, &fnLast },
    .{ "reverse", 1, 1, &fnReverse },
    .{ "nthrest", 2, 2, &fnNthrest },
    .{ "nthnext", 2, 2, &fnNthnextLeaf, .leaf, &fnNthnext },
    .{ "take-last", 2, 2, &fnTakeLast },
    .{ "repeat", 1, 2, &fnRepeat },
    .{ "repeatedly", 1, 2, &fnRepeatedly },
    .{ "iterate", 2, 2, &fnIterate },
    .{ "cycle", 1, 1, &fnCycle },
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
    .{ "read-string", 1, 2, &fnReadString },
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
    .{ "alter-var-root", 2, null, &fnAlterVarRoot },
    .{ "boolean", 1, 1, &fnBoolean },
    .{ "list?", 1, 1, kindPredicate(isList), .leaf },
    .{ "seq?", 1, 1, kindPredicate(isSeq), .leaf },
    .{ "vector?", 1, 1, kindPredicate(isVector), .leaf },
    .{ "map?", 1, 1, kindPredicate(isMap), .leaf },
    .{ "set?", 1, 1, kindPredicate(isSet), .leaf },
    .{ "keyword?", 1, 1, kindPredicate(isKeyword), .leaf },
    .{ "symbol?", 1, 1, kindPredicate(isSymbol), .leaf },
    .{ "char?", 1, 1, kindPredicate(isChar), .leaf },
    .{ "boolean?", 1, 1, kindPredicate(isBoolean), .leaf },
    .{ "coll?", 1, 1, kindPredicate(isColl), .leaf },
    .{ "sequential?", 1, 1, kindPredicate(isSequential), .leaf },
    .{ "associative?", 1, 1, kindPredicate(isAssociative), .leaf },
    .{ "fn?", 1, 1, kindPredicate(isFn), .leaf },
    .{ "ifn?", 1, 1, kindPredicate(isIfn), .leaf },
    .{ "counted?", 1, 1, kindPredicate(isCounted), .leaf },
    .{ "delay?", 1, 1, &fnDelayQ },
    // Lazy seqs (docs/LAZY.md).
    .{ "realized?", 1, 1, &fnRealizedQ },
    .{ "doall", 1, 2, &fnDoall },
    .{ "dorun", 1, 2, &fnDorun },
    .{ "chunked-seq?", 1, 1, &fnChunkedSeqQ },
    .{ "chunk-first", 1, 1, &fnChunkFirst },
    .{ "chunk-rest", 1, 1, &fnChunkRest },
    .{ "chunk-next", 1, 1, &fnChunkNext },
    .{ "chunk-buffer", 1, 1, &fnChunkBuffer },
    .{ "chunk-append", 2, 2, &fnChunkAppend },
    .{ "chunk", 1, 1, &fnChunk },
    .{ "chunk-cons", 2, 2, &fnChunkCons },
    // Introspection: kinds, namespaces, UUIDs (STDLIB.md §8).
    .{ "class", 1, 1, &fnClass },
    .{ "var?", 1, 1, kindPredicate(isVar), .leaf },
    .{ "find-ns", 1, 1, &fnFindNs },
    .{ "all-ns", 0, 0, &fnAllNs },
    .{ "ns-interns", 1, 1, &fnNsInterns },
    .{ "ns-publics", 1, 1, &fnNsPublics },
    .{ "resolve", 1, 1, &fnResolve },
    .{ "ns-resolve", 2, 2, &fnNsResolve },
    .{ "random-uuid", 0, 0, &fnRandomUuid },
    .{ "parse-uuid", 1, 1, &fnParseUuid },
    .{ "indexed?", 1, 1, kindPredicate(isIndexed), .leaf },
    // Collection construction + access.
    .{ "vector", 0, null, &fnVector },
    .{ "vec", 1, 1, &fnVec },
    .{ "hash-map", 0, null, &fnHashMap },
    .{ "hash-set", 0, null, &fnHashSet },
    .{ "set", 1, 1, &fnSet },
    .{ "subvec", 2, 3, &fnSubvec },
    .{ "identical?", 2, 2, &fnIdenticalQ },
    .{ "assoc", 3, null, &fnAssocLeaf, .leaf, &fnAssoc },
    .{ "dissoc", 1, null, &fnDissoc },
    .{ "get", 2, 3, &fnGetLeaf, .leaf, &fnGet },
    .{ "contains?", 2, 2, &fnContainsQ },
    .{ "keys", 1, 1, &fnKeys },
    .{ "vals", 1, 1, &fnVals },
    .{ "conj", 0, null, &fnConjLeaf, .leaf, &fnConj },
    .{ "frequencies", 1, 1, &fnFrequencies },
    .{ "group-by", 2, 2, &fnGroupBy },
    // Transients (docs/TRANSIENT.md): each `!` edits the nodes the
    // transient owns in place and returns the transient to use.
    .{ "transient", 1, 1, &fnTransient },
    .{ "persistent!", 1, 1, &fnPersistentBang },
    .{ "conj!", 0, null, &fnConjBang },
    .{ "assoc!", 3, null, &fnAssocBangLeaf, .leaf, &fnAssocBang },
    .{ "dissoc!", 2, null, &fnDissocBang },
    .{ "disj!", 2, null, &fnDisjBang },
    .{ "pop!", 1, 1, &fnPopBang },
    // Sorted collections (docs/SORTED.md).
    .{ "sorted-map", 0, null, &fnSortedMap },
    .{ "sorted-map-by", 1, null, &fnSortedMapBy },
    .{ "sorted-set", 0, null, &fnSortedSet },
    .{ "sorted-set-by", 1, null, &fnSortedSetBy },
    .{ "sorted?", 1, 1, kindPredicate(sorted_mod.isSortedKind), .leaf },
    .{ "reversible?", 1, 1, kindPredicate(isReversible), .leaf },
    .{ "subseq", 3, 5, &fnSubseq },
    .{ "rsubseq", 3, 5, &fnRsubseq },
    .{ "rseq", 1, 1, &fnRseq },
    // Typed vectors (docs/TYPED_VECTOR.md §7.1).
    .{ "i64-vector", 1, 1, &fnI64Vector },
    .{ "f64-vector", 1, 1, &fnF64Vector },
    .{ "typed-vector?", 1, 1, kindPredicate(isTypedVector), .leaf },
    .{ "typed-vector-type", 1, 1, &fnTypedVectorType },
    // Atoms: identity-valued in-memory mutable cells (docs/ATOM.md).
    // `deref` is `fnDbDeref`, which takes a var, atom, durable ref
    // or reduced; `db_natives` installs it again as `db/deref`.
    .{ "deref", 1, 1, &fnDbDeref },
    .{ "atom", 1, null, &fnAtom },
    .{ "atom?", 1, 1, &fnAtomQ },
    .{ "reset!", 2, 2, &fnResetBang },
    .{ "swap!", 2, null, &fnSwapBang },
    .{ "swap-vals!", 2, null, &fnSwapValsBang },
    .{ "compare-and-set!", 3, 3, &fnCompareAndSetBang },
    .{ "set-validator!", 2, 2, &fnSetValidator },
    .{ "get-validator", 1, 1, &fnGetValidator },
    .{ "add-watch", 3, 3, &fnAddWatch },
    .{ "remove-watch", 2, 2, &fnRemoveWatch },
    // satisfies? predicate.
    .{ "satisfies?", 2, 2, &fnSatisfiesQ },
    // Core string ops. Indexing semantics are by Unicode scalar
    // (codepoint), NOT byte; see `docs/STDLIB.md` §2.
    .{ "str", 0, null, &fnStr },
    .{ "string?", 1, 1, &fnStringQ },
    .{ "subs", 2, 3, &fnSubs },
    // Regular expressions (docs/REGEX.md §9); `re-seq` is core.nx's.
    .{ "re-pattern", 1, 1, &fnRePattern },
    .{ "re-matcher", 2, 2, &fnReMatcher },
    .{ "re-find", 1, 2, &fnReFind },
    .{ "re-matches", 2, 2, &fnReMatches },
    .{ "re-groups", 1, 1, &fnReGroups },
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
    .{ "replace-first", 3, 3, &fnStringReplaceFirst },
    .{ "re-quote-replacement", 1, 1, &fnStringReQuoteReplacement },
});

const math_natives = table("nexis.math", .{
    .{ "sqrt", 1, 1, &fnMathSqrt },
    .{ "pow", 2, 2, &fnMathPow },
    .{ "floor", 1, 1, &fnMathFloor },
    .{ "ceil", 1, 1, &fnMathCeil },
    .{ "round", 1, 1, &fnMathRound },
    .{ "sin", 1, 1, mathOf1(builtinSin) },
    .{ "cos", 1, 1, mathOf1(builtinCos) },
    .{ "tan", 1, 1, mathOf1(builtinTan) },
    .{ "asin", 1, 1, mathOf1(std.math.asin) },
    .{ "acos", 1, 1, mathOf1(std.math.acos) },
    .{ "atan", 1, 1, mathOf1(std.math.atan) },
    .{ "atan2", 2, 2, mathOf2(std.math.atan2) },
    .{ "sinh", 1, 1, mathOf1(std.math.sinh) },
    .{ "cosh", 1, 1, mathOf1(std.math.cosh) },
    .{ "tanh", 1, 1, mathOf1(std.math.tanh) },
    .{ "exp", 1, 1, mathOf1(builtinExp) },
    .{ "expm1", 1, 1, mathOf1(std.math.expm1) },
    .{ "log", 1, 1, mathOf1(builtinLog) },
    .{ "log10", 1, 1, mathOf1(builtinLog10) },
    .{ "log1p", 1, 1, mathOf1(std.math.log1p) },
    .{ "cbrt", 1, 1, mathOf1(std.math.cbrt) },
    .{ "hypot", 2, 2, mathOf2(std.math.hypot) },
    .{ "signum", 1, 1, mathOf1(signum) },
    .{ "to-radians", 1, 1, mathOf1(toRadians) },
    .{ "to-degrees", 1, 1, mathOf1(toDegrees) },
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
    // lazy-seq: an unrealized block over the body's function (core.nx).
    .{ "#%lazy-seq", 1, 1, &fnLazySeq },
    // The force under realize-caught (core.nx, docs/LAZY.md §6).
    .{ "#%force", 1, 1, &fnForce },
    // sequence with a transducer (core.nx, docs/LAZY.md §10).
    .{ "#%sequence", 2, 3, &fnSequenceXform },
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

/// `(list* a b ... s)` → the leading args consed onto `(seq s)`, the
/// last arg's seq itself when there are none: nil for an empty `s`,
/// as Clojure's.
fn fnListStar(vm: *VM, args: []const Value) VmError!Value {
    var result = try seq_mod.seqOf(vm, args[args.len - 1]);
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

/// A count of `take` or `drop`: any integer, negative ones none; a
/// bignum is all or none, as Clojure's counts one down.
fn lazyCount(v: Value) VmError!Value {
    if (v.kind() == .bignum) return value_mod.fromFixnum(if (bignum_mod.isNegative(v)) 0 else value_mod.fixnum_max).?;
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
/// element is only the next call's argument (GC.md §11.5, class 2).
fn fnSome(vm: *VM, args: []const Value) VmError!Value {
    var it = try makeSeqIter(vm, args[1]);
    var cb = vm_mod.Callback.init(vm, args[0], 1);
    while (try it.next()) |x| {
        const r = try cb.call(&.{x});
        if (r.isTruthy()) return r;
    }
    return value_mod.nilValue();
}

fn fnEveryQ(vm: *VM, args: []const Value) VmError!Value {
    var it = try makeSeqIter(vm, args[1]);
    var cb = vm_mod.Callback.init(vm, args[0], 1);
    while (try it.next()) |x| {
        if (!(try cb.call(&.{x})).isTruthy()) return value_mod.fromBool(false);
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
        .lazy_seq => @intCast(try seq_mod.countOf(vm, c)),
        else => return VmError.KindMismatch,
    };
    return value_mod.fromFixnum(n) orelse VmError.ArithmeticOverflow;
}

/// `count` as a leaf (VM.md §6): a lazy seq (realized to its end) and
/// an entity (read from the store) go the general way.
fn fnCountLeaf(vm: *VM, args: []const Value) VmError!Value {
    return switch (args[0].kind()) {
        .lazy_seq, .nextomic_entity => VmError.NeedsReentry,
        else => fnCount(vm, args),
    };
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
//   (<)        => true         (< x y z)  => chained
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
//
// A native that calls one function once per element, with one
// argument count, calls it through a `vm_mod.Callback` (VM.md §6):
// `callValue`'s effect, errors and rooting, with what cannot change
// between the calls decided at the first.

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
    // The built elements are the call's arguments (GC.md §11.5, class 2).
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
/// to `results`, which roots each as it comes.
fn mapInto(vm: *VM, f: Value, colls: []const Value, results: *Results) VmError!void {
    if (colls.len == 1) {
        var it = try makeSeqIter(vm, colls[0]);
        var cb = vm_mod.Callback.init(vm, f, 1);
        while (try it.next()) |x| try results.add(try cb.call(&.{x}));
        return;
    }

    const iters = vm.allocator.alloc(SeqIter, colls.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(iters);
    for (colls, 0..) |c, i| iters[i] = try makeSeqIter(vm, c);
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

/// `(reduce f coll)` / `(reduce f init coll)` → left fold. With
/// no init the first element seeds the fold and an empty
/// collection yields `(f)`.
fn fnReduce(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    const coll = args[args.len - 1];
    if (seq_mod.pureOf(coll)) |p| return reducePure(vm, f, if (args.len == 3) args[1] else null, p);
    var it = try makeSeqIter(vm, coll);
    var acc = if (args.len == 3) args[1] else (try it.next()) orelse return try vm.callValue(f, &.{});
    var cb = vm_mod.Callback.init(vm, f, 2);
    // The accumulator is the next call's argument, and a lazy `coll`'s
    // next step may collect before that call (GC.md §11.5, class 5):
    // it goes into a root slot before such a step.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(acc);
    while (try it.nextChunk(scope.base, acc)) |xs| for (xs) |x| {
        acc = try cb.call(&.{ acc, x });
        if (isReduced(vm, acc)) return reducedValue(acc);
    };
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
            while (i < n) : ({
                i += 1;
                x += r.step;
            }) {
                vm.roots.items[scope.base] = acc;
                acc = try cb.call(&.{ acc, value_mod.fromFixnum(x).? });
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
            return acc;
        },
        .range_inf => |start| {
            var x = start;
            var acc = init orelse blk: {
                x = try vm_mod.numAdd(heap, x, value_mod.fromFixnum(1).?);
                break :blk start;
            };
            while (true) {
                vm.roots.items[scope.base] = acc;
                acc = try cb.call(&.{ acc, x });
                if (isReduced(vm, acc)) return reducedValue(acc);
                x = try vm_mod.numAdd(heap, x, value_mod.fromFixnum(1).?);
            }
        },
        .repeat => |x| {
            var acc = init orelse x;
            while (true) {
                vm.roots.items[scope.base] = acc;
                acc = try cb.call(&.{ acc, x });
                if (isReduced(vm, acc)) return reducedValue(acc);
            }
        },
        .repeat_n => |r| {
            var acc = init orelse r.x;
            var i: i64 = if (init == null) 1 else 0;
            while (i < r.n) : (i += 1) {
                vm.roots.items[scope.base] = acc;
                acc = try cb.call(&.{ acc, r.x });
                if (isReduced(vm, acc)) return reducedValue(acc);
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
                acc = try cb.call(&.{ acc, x });
                if (isReduced(vm, acc)) return reducedValue(acc);
                vm.roots.items[scope.base] = acc;
                x = try step.call(&.{x});
            }
        },
        .cycle => |all| {
            var acc: ?Value = init;
            while (true) {
                var it = try makeSeqIter(vm, all);
                while (try it.next()) |x| {
                    if (acc) |a| {
                        vm.roots.items[scope.base] = a;
                        const r = try cb.call(&.{ a, x });
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

fn isReduced(vm: *VM, v: Value) bool {
    const type_id = vm.home().reduced_type_id orelse return false;
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
/// it comes. An element the walk built (a map's entry) is rooted as
/// the predicate's argument for its call and by `results` once kept;
/// one dropped is garbage.
fn sieveInto(vm: *VM, mode: Sieve, pred: Value, coll: Value, results: *Results) VmError!void {
    var it = try makeSeqIter(vm, coll);
    var cb = vm_mod.Callback.init(vm, pred, 1);
    while (try it.next()) |x| {
        const r = try cb.call(&.{x});
        const kept: ?Value = switch (mode) {
            .keep_truthy => if (r.isTruthy()) x else null,
            .keep_falsy => if (r.isTruthy()) null else x,
            .keep_result => if (r.isNil()) null else r,
        };
        if (kept) |v| try results.add(v);
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

fn fnVec(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    return switch (s.kind()) {
        .nil => {
            const heap = vm.ensureHeap();
            return vector_mod.empty(heap) catch VmError.OutOfMemory;
        },
        // A fresh vector carries no metadata (SEMANTICS §7), as
        // Clojure's `vec` clears it.
        .persistent_vector => if (heap_mod.Heap.asHeapHeader(s).getMeta() == null) s else fnWithMeta(vm, &.{ s, value_mod.nilValue() }),
        else => blk: {
            var items = try collectSeq(vm, s);
            defer items.deinit(vm.allocator);
            break :blk vector_mod.fromSlice(vm.ensureHeap(), items.items) catch VmError.OutOfMemory;
        },
    };
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
/// itself without its metadata, as Clojure's.
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

/// `(dissoc m k & ks)` → persistent remove from a map or record.
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
    for (xs) |x| switch (coll.kind()) {
        .persistent_vector => _ = transient_mod.vectorConjBang(heap, t, x) catch |err| return transientFailure(vm, err),
        .persistent_set => try conjBangSet(vm, t, x),
        else => try conjBangMap(vm, t, x),
    };
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
    // A lazy argument's next step may collect (GC.md §11.5, class 5).
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(t);
    var it = try makeSeqIter(vm, args[0]);
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
/// the root scope across every call of `f`; `x` is the call's argument
/// and lands in its vector, and `(f x)` in the map, before the next
/// call.
fn fnGroupBy(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    const f = args[0];
    const scope = vm.rootScope();
    defer scope.release();
    const t = transient_mod.transientFrom(heap, champ_mod.mapEmpty(heap) catch return VmError.OutOfMemory) catch |err| return transientFailure(vm, err);
    try scope.push(t);
    var it = try makeSeqIter(vm, args[1]);
    while (try it.next()) |x| {
        const k = try vm.callValue(f, &.{x});
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
/// through a transducer (docs/LAZY.md §10).
fn fnInto(vm: *VM, args: []const Value) VmError!Value {
    if (args.len < 2) return fnConj(vm, args);
    if (args.len == 3) return callCore(vm, "into-xform", args);
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
    var results = Results.init(vm);
    defer results.release();
    try mapInto(vm, args[0], colls, &results);
    return results.vector();
}

fn fnFilterv(vm: *VM, args: []const Value) VmError!Value {
    var results = Results.init(vm);
    defer results.release();
    try sieveInto(vm, .keep_truthy, args[0], args[1], &results);
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
/// Clojure's, coll itself when n is not positive, or coll is nil or
/// an empty collection other than a vector.
fn fnNthrest(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireFixnum(args[1]);
    if (n <= 0 or args[0].isNil()) return args[0];
    const count: usize = @intCast(n);
    switch (args[0].kind()) {
        .list => return list_mod.drop(args[0], count),
        .persistent_vector => {
            const v = args[0];
            return list_mod.ofVector(vm.ensureHeap(), v, @min(count, vector_mod.count(v))) catch VmError.OutOfMemory;
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
fn fnNthnext(vm: *VM, args: []const Value) VmError!Value {
    return fnSeq(vm, &.{try fnNthrest(vm, args)});
}

/// `nthnext` as a leaf (VM.md §6): of nil, a list or a vector; any
/// other seqable goes the general way.
fn fnNthnextLeaf(vm: *VM, args: []const Value) VmError!Value {
    return switch (args[0].kind()) {
        .nil, .list, .persistent_vector => fnNthnext(vm, args),
        else => VmError.NeedsReentry,
    };
}

/// `(take-last n coll)`; of nothing it is nil, as Clojure's.
fn fnTakeLast(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
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
    const n = try requireCount(args[0]);
    if (n == 0) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    return seq_mod.make(vm, seq_mod.op_repeat_n, &.{ value_mod.fromFixnum(@intCast(@min(n, @as(usize, @intCast(value_mod.fixnum_max))))).?, args[1] });
}

/// `(repeatedly f)` → the infinite lazy seq of `(f)` calls, each made
/// when its element is first needed; `(repeatedly n f)` → `n` of them.
fn fnRepeatedly(vm: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return seq_mod.make(vm, seq_mod.op_repeatedly, args[0..1]);
    const n = try requireCount(args[0]);
    return seq_mod.make(vm, seq_mod.op_repeatedly, &.{ args[1], value_mod.fromFixnum(@intCast(@min(n, @as(usize, @intCast(value_mod.fixnum_max))))).? });
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
    var best_key = try cb.call(&.{best});
    // The best key so far is the one value kept across the next
    // call (GC.md §11.5); it goes on the root stack when it changes.
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(best_key);
    for (args[2..]) |x| {
        const key = try cb.call(&.{x});
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
    // A sorted source's comparator can collect inside `find`, and a
    // lazy key seq's next step can (GC.md §11.5, classes 4 and 5): the
    // result so far and the keys the walk built are kept rooted.
    const scope = vm.rootScope();
    defer scope.release();
    const collects = (src.kind() == .sorted_map and !sorted_mod.comparatorOf(src).isNil()) or args[1].kind() == .lazy_seq;
    if (collects) try scope.push(out);
    var ks = if (collects) try rootedSeqIter(vm, args[1], scope) else try makeSeqIter(vm, args[1]);
    while (try ks.next()) |k| {
        const entry = try fnFind(vm, &.{ src, k });
        if (entry.isNil()) continue;
        out = try mapPut(heap, out, k, vector_mod.nth(entry, 1));
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
    vm: *VM,
    comparator: ?*vm_mod.Callback,

    /// `a` and `b` are on `sortImpl`'s root scope (GC.md §11.5,
    /// class 4).
    fn less(self: SortOrder, a: Value, b: Value) VmError!bool {
        const cmp = self.comparator orelse return (try compareValues(self.vm, a, b)) == .lt;
        const r = try cmp.call(&.{ a, b });
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

fn sortImpl(vm: *VM, keyfn: ?Value, comparator_arg: ?Value, coll: Value) VmError!Value {
    // `compare` is the natural order, without a call per comparison,
    // as sorted collections take it (`comparatorArg`).
    const comparator: ?Value = if (comparator_arg) |c| (if (c.kind() == .native_fn and comparatorArg(c).isNil()) null else c) else null;
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
    if (keyfn) |kf| {
        var cb = vm_mod.Callback.init(vm, kf, 1);
        for (items.items, keyed) |v, *k| {
            k.* = .{ .key = try cb.call(&.{v}), .val = v };
            try scope.push(k.key);
        }
    } else for (items.items, keyed) |v, *k| {
        k.* = .{ .key = v, .val = v };
    }
    var cmp_cb = if (comparator) |c| vm_mod.Callback.init(vm, c, 2) else undefined;
    try mergeSort(keyed, scratch, .{ .vm = vm, .comparator = if (comparator != null) &cmp_cb else null });
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

/// `(eval form)` → the value of `form` compiled in the current
/// namespace and run on this VM; a form that does not compile throws
/// `{:error :compile-error :message "<CompileError>" :form form}`.
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
/// atom or Var; nil for anything else or when none is attached.
fn fnMeta(_: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    if (x.kind() == .var_) return VM.asVar(x).meta;
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
    if (!m.isNil() and m.kind() != .persistent_map) return VmError.KindMismatch;
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
    switch (champ_mod.mapGet(m, key, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
        .present => |flag| if (flag.isTruthy()) {
            v.dynamic = true;
        },
        .absent => {},
    }
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

/// `(thread-bound? v)` → whether a `binding` of `v` is in force.
fn fnThreadBoundQ(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    return value_mod.fromBool(VM.asVar(args[0]).thread_bound);
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
    const txn = try activeWrite(args[0]);
    const r = args[1];
    const v = args[2];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    try putRealizing(vm, txn, r, v);
    return value_mod.nilValue();
}

/// `db.putRef`, realizing `v` and encoding it again when the codec
/// finds a lazy seq in it that has not run (docs/LAZY.md §8).
fn putRealizing(vm: *VM, txn: *db_mod.WriteTxn, r: Value, v: Value) VmError!void {
    db_mod.putRef(txn, r, v) catch |err| {
        if (err != error.Unrealized) return dbFailure(vm, err);
        try seq_mod.realizeAll(vm, v);
        db_mod.putRef(txn, r, v) catch |again| return dbFailure(vm, again);
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

fn fnDorun(vm: *VM, args: []const Value) VmError!Value {
    try realizeArg(vm, args);
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
    try putRealizing(vm, &h.txn.write, r, new_value);
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
    if (!meta.isNil() and meta.kind() != .persistent_map) return VmError.KindMismatch;
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
/// `:invalid-reference-state`; a throw out of it propagates. `state`
/// is the call's argument, so rooted while the validator runs.
fn validate(vm: *VM, validator: Value, state: Value) VmError!void {
    if (validator.isNil()) return;
    if (!(try vm.callValue(validator, &.{state})).isTruthy()) return vm.throwKeyword("invalid-reference-state");
}

/// Clojure's `ARef.notifyWatches`: each watch called with
/// `(key atom old new)` after the change, in the watches map's order.
/// The map is rooted here, since a watch that adds or removes one
/// replaces the atom's map; `old` and `new` are every call's
/// arguments, and nothing collects between two calls (GC.md §11.5).
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
    const old = blk: {
        if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
        defer atom_mod.exitCritical(a);
        try validate(vm, atom_mod.body(a).validator, new_val);
        const old = atom_mod.getValue(a);
        atom_mod.setValue(a, new_val);
        break :blk old;
    };
    try notifyWatches(vm, a, old, new_val);
    return new_val;
}

/// `(swap! a f & args)` → sets `a` to `(apply f @a args)` and
/// returns it; `swap-vals!` returns `[old new]`. Nothing is written
/// when `f` or the validator throws or control transfers.
fn swapImpl(vm: *VM, args: []const Value, pair: bool) VmError!Value {
    const a = args[0];
    if (a.kind() != .atom) return VmError.KindMismatch;
    const old = atom_mod.getValue(a);
    const new_val = blk: {
        if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
        defer atom_mod.exitCritical(a);
        const call_args = vm.allocator.alloc(Value, args.len - 1) catch return VmError.OutOfMemory;
        defer vm.allocator.free(call_args);
        call_args[0] = old;
        @memcpy(call_args[1..], args[2..]);
        // `old` is the atom's value, hence rooted, until the write.
        const new_val = try vm.callValue(args[1], call_args);
        try validate(vm, atom_mod.body(a).validator, new_val);
        atom_mod.setValue(a, new_val);
        break :blk new_val;
    };
    try notifyWatches(vm, a, old, new_val);
    if (!pair) return new_val;
    // No safe point between the last call and this allocation (a
    // cycle runs only between instructions, VM.md §9).
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
/// :message M :pattern s :index I}`, `I` counting code points as
/// Java's index counts chars.
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
            return vm.throwValue(m);
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
    return vm.throwValue(m);
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
    var it = try makeSeqIter(vm, coll);
    var first = true;
    while (try it.next()) |x| {
        if (!first) w.writer.writeAll(sep) catch return VmError.OutOfMemory;
        first = false;
        try appendStrValue(vm, &w, x);
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

fn writeOut(vm: *VM, bytes: []const u8) VmError!void {
    if (out_stack.lastPtr()) |top| return top.appendSlice(out_allocator, bytes) catch VmError.OutOfMemory;
    const io_handle = vm.io orelse return VmError.IoError;
    std.Io.File.stdout().writeStreamingAll(io_handle, bytes) catch return VmError.IoError;
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
/// none) as its fields.
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

/// `(#%kwargs x)` → what a map pattern destructures, as Clojure 1.11
/// makes it: a value that is not a seq (a map, a vector, nil) is
/// itself; a seq of one element is that element (a trailing map), the
/// empty seq `{}`, and a longer seq alternating keys and values the
/// map of them, an odd count `:invalid-argument`.
fn fnKwargs(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .list) return args[0];
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
            var cb = vm_mod.Callback.init(vm, f, 1);
            for (out, 0..) |*slot, i| {
                const x = typed_vector_mod.nth(heap, xs, i) catch return VmError.OutOfMemory;
                slot.* = try i64Elem(try cb.call(&.{x}));
            }
            return typed_vector_mod.fromI64Slice(heap, out) catch VmError.OutOfMemory;
        },
        .f64 => {
            const out = vm.allocator.alloc(f64, n) catch return VmError.OutOfMemory;
            defer vm.allocator.free(out);
            var cb = vm_mod.Callback.init(vm, f, 1);
            for (out, typed_vector_mod.f64Elems(xs)) |*slot, x| {
                slot.* = try f64Elem(try cb.call(&.{value_mod.fromFloat(x)}));
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
