// =============================================================================
// src/stdlib.zig — the native standard library
// =============================================================================
//
// Host-Zig functions exposed as first-class `Value`s of kind
// `.native_fn`. Each has a static `NativeFn` descriptor (no heap
// allocation, immortal) that the install functions bind as Vars
// in `nexis.core`, `db`, `nexis.string`, `nexis.internal` and
// `nextomic` at VM startup. The rest of nexis.core is written in
// nexis itself (`stdlib/core.nx`, embedded below) on top of these.
//
// Every native declares its arity in its descriptor and the VM
// enforces it; a native never indexes `args` past its declared
// minimum. Any seqable receiver goes through `makeSeqIter`, so
// nil, lists, vectors, maps, records, sets and strings behave the
// same way in every sequence function. Arithmetic delegates to the
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
const value_mod = @import("value");
const vm_mod = @import("vm");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const intern_mod = @import("intern");
const db_mod = @import("db");
const codec_mod = @import("codec");
const heap_mod = @import("heap");
const dispatch_mod_alias = @import("dispatch");
const emdb_mod = @import("emdb");
const atom_mod = @import("atom");
const string_mod = @import("string");
const format_mod = @import("format");
const record_mod = @import("record");
const protocol_mod = @import("protocol");
const nextomic_mod = @import("nextomic");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const VM = vm_mod.VM;
const NativeFn = vm_mod.NativeFn;
const Namespace = vm_mod.Namespace;
const VmError = vm_mod.VmError;

// =============================================================================
// Installation
// =============================================================================

/// Install the core natives into `ns`. Idempotent: re-installing
/// replaces the root without disturbing the Var's `.macro` flag.
///
/// Native fn NAMES are string literals (`.rodata`, immortal),
/// so the Namespace's existing `intern(name)` overload (which
/// borrows the name slice into the Var) is safe — no separate
/// name allocator needed.
pub fn installCore(ns: *Namespace) !void {
    for (core_fns) |entry| {
        const v = try ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
        // Native fns are NOT macros (Var.macro stays false).
    }
}

/// Install db primitives into the `db` namespace
/// so `(db/open path)` resolves through the registry's
/// qualified-symbol path. CLI calls this AFTER `installCore`
/// + after the registry has a "db" namespace registered.
pub fn installDb(db_ns: *Namespace) !void {
    for (db_fns) |entry| {
        const v = try db_ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
    }
}

/// Install the `nextomic/*` natives (docs/NEXTOMIC.md §6) into the
/// `nextomic` namespace; `NEXTOMIC_NX_SOURCE` adds the sugar on top.
pub fn installNextomic(nextomic_ns: *Namespace) !void {
    try nextomic_mod.natives.install(nextomic_ns);
}

/// Install `nexis.string/*` into the `nexis.string` namespace. Not
/// auto-referred (like Clojure's `clojure.string`): users call
/// `(nexis.string/lower-case ...)`. Installed before core.nx is
/// bootstrapped so composite definitions may refer to it.
pub fn installString(string_ns: *Namespace) !void {
    for (string_fns) |entry| {
        const v = try string_ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
    }
}

/// Install the `#%`-prefixed helpers into the `nexis.internal`
/// namespace. Not auto-referred: the `defrecord`/`defprotocol`
/// macros emit qualified calls (`nexis.internal/#%register-record-type`
/// etc.); user code does not call these directly.
pub fn installInternal(internal_ns: *Namespace) !void {
    for (internal_fns) |entry| {
        const v = try internal_ns.intern(entry.name);
        v.root = vm_mod.nativeFnValue(entry.descriptor);
        v.bound = true;
    }
}

const db_fns = [_]CoreEntry{
    // Connection + ref + auto-ephemeral primitives.
    .{ .name = "open", .descriptor = &native_db_open },
    .{ .name = "close", .descriptor = &native_db_close },
    .{ .name = "ref", .descriptor = &native_db_ref },
    .{ .name = "ref?", .descriptor = &native_db_ref_q },
    .{ .name = "put-key!", .descriptor = &native_db_put_key },
    .{ .name = "get-key", .descriptor = &native_db_get_key },
    .{ .name = "delete-key!", .descriptor = &native_db_delete_key },
    .{ .name = "present?", .descriptor = &native_db_present_q },
    // Explicit-tx primitives.
    .{ .name = "begin-write", .descriptor = &native_db_begin_write },
    .{ .name = "begin-read", .descriptor = &native_db_begin_read },
    .{ .name = "commit!", .descriptor = &native_db_commit },
    .{ .name = "abort-write!", .descriptor = &native_db_abort_write },
    .{ .name = "abort-read!", .descriptor = &native_db_abort_read },
    .{ .name = "put!", .descriptor = &native_db_put },
    .{ .name = "get", .descriptor = &native_db_get },
    .{ .name = "delete!", .descriptor = &native_db_delete },
    // Deref + alter.
    .{ .name = "deref", .descriptor = &native_db_deref },
    .{ .name = "alter!", .descriptor = &native_db_alter },
    // Tree traversal.
    .{ .name = "scan", .descriptor = &native_db_scan },
    .{ .name = "reduce-tree", .descriptor = &native_db_reduce_tree },
    // Snapshot aliases (PLAN.md §15.7 vocabulary).
    .{ .name = "snapshot", .descriptor = &native_db_snapshot },
    .{ .name = "release-snapshot!", .descriptor = &native_db_release_snapshot },
    .{ .name = "snapshot?", .descriptor = &native_db_snapshot_q },
};

/// `nexis.string` namespace entries.
/// Installed into `registry.string` via `installString`. NOT
/// auto-referred — users call qualified `nexis.string/lower-case`.
const string_fns = [_]CoreEntry{
    .{ .name = "lower-case", .descriptor = &native_string_lower_case },
    .{ .name = "upper-case", .descriptor = &native_string_upper_case },
    .{ .name = "trim", .descriptor = &native_string_trim },
    .{ .name = "split", .descriptor = &native_string_split },
    .{ .name = "join", .descriptor = &native_string_join },
    .{ .name = "replace", .descriptor = &native_string_replace },
};

/// `nexis.internal` namespace entries. Installed via
/// `installInternal`. NOT auto-referred; macros emit qualified
/// calls.
const internal_fns = [_]CoreEntry{
    // Records.
    .{ .name = "#%register-record-type", .descriptor = &native_register_record_type },
    .{ .name = "#%make-record", .descriptor = &native_make_record },
    .{ .name = "#%record?", .descriptor = &native_record_q },
    .{ .name = "#%record-type-id", .descriptor = &native_record_type_id },
    // Protocols.
    .{ .name = "#%register-protocol", .descriptor = &native_register_protocol },
    .{ .name = "#%protocol-fn", .descriptor = &native_protocol_fn },
    // defrecord inline protocol impls.
    .{ .name = "#%extend-record-impl", .descriptor = &native_extend_record_impl },
    // extend-protocol / extend-type / satisfies?.
    .{ .name = "#%extend-builtin-impl", .descriptor = &native_extend_builtin_impl },
    .{ .name = "#%extend-default-impl", .descriptor = &native_extend_default_impl },
    // try: the keyword-matcher test the expander emits.
    .{ .name = "#%catch-matches?", .descriptor = &native_catch_matches },
    // `& {:keys ...}`: the rest seq as a map.
    .{ .name = "#%kwargs", .descriptor = &native_kwargs },
};

/// The part of nexis.core written in nexis itself, embedded at
/// compile time. Evaluated after `installCore` so its definitions
/// can use the natives. Add composite macros and fns to
/// `src/stdlib/core.nx`, not here. A keyword literal in that file
/// is interned at boot, ahead of every keyword a script reads, and
/// a map's iteration order is a function of intern order, so the
/// file builds any keyword it needs at run time (`(keyword "x")`)
/// and `test/nextomic/*.out` stay as they are.
pub const CORE_NX_SOURCE: []const u8 = @embedFile("stdlib/core.nx");
/// The `nextomic` namespace's sugar (`with-conn`), bootstrapped after
/// `installNextomic` with that namespace current.
pub const NEXTOMIC_NX_SOURCE: []const u8 = @embedFile("stdlib/nextomic.nx");

const CoreEntry = struct {
    name: []const u8,
    descriptor: *const NativeFn,
};

const core_fns = [_]CoreEntry{
    // Sequence primitives.
    .{ .name = "list", .descriptor = &native_list },
    .{ .name = "cons", .descriptor = &native_cons },
    .{ .name = "first", .descriptor = &native_first },
    .{ .name = "rest", .descriptor = &native_rest },
    .{ .name = "count", .descriptor = &native_count },
    .{ .name = "nth", .descriptor = &native_nth },
    .{ .name = "empty?", .descriptor = &native_empty_q },
    .{ .name = "identity", .descriptor = &native_identity },
    .{ .name = "nil?", .descriptor = &native_nil_q },
    .{ .name = "some?", .descriptor = &native_some_q },
    // First-class arithmetic + comparison Vars.
    // Required so `(reduce + 0 xs)` resolves `+` as a Var.
    // `(+ x y)` at the call head is still inlined by the
    // compiler; the Var is only reached through non-head uses.
    .{ .name = "+", .descriptor = &native_add },
    .{ .name = "-", .descriptor = &native_sub },
    .{ .name = "*", .descriptor = &native_mul },
    .{ .name = "/", .descriptor = &native_div },
    .{ .name = "quot", .descriptor = &native_quot },
    .{ .name = "rem", .descriptor = &native_rem },
    .{ .name = "mod", .descriptor = &native_mod },
    .{ .name = "<", .descriptor = &native_lt },
    .{ .name = "<=", .descriptor = &native_lte },
    .{ .name = ">", .descriptor = &native_gt },
    .{ .name = ">=", .descriptor = &native_gte },
    .{ .name = "==", .descriptor = &native_num_eq },
    .{ .name = "=", .descriptor = &native_eq },
    .{ .name = "not=", .descriptor = &native_not_eq },
    .{ .name = "inc", .descriptor = &native_inc },
    .{ .name = "dec", .descriptor = &native_dec },
    .{ .name = "max", .descriptor = &native_max },
    .{ .name = "min", .descriptor = &native_min },
    .{ .name = "abs", .descriptor = &native_abs },
    .{ .name = "number?", .descriptor = &native_number_q },
    .{ .name = "integer?", .descriptor = &native_integer_q },
    .{ .name = "float?", .descriptor = &native_float_q },
    .{ .name = "NaN?", .descriptor = &native_nan_q },
    .{ .name = "infinite?", .descriptor = &native_infinite_q },
    .{ .name = "not", .descriptor = &native_not },
    .{ .name = "zero?", .descriptor = &native_zero_q },
    .{ .name = "pos?", .descriptor = &native_pos_q },
    .{ .name = "neg?", .descriptor = &native_neg_q },
    .{ .name = "odd?", .descriptor = &native_odd_q },
    .{ .name = "even?", .descriptor = &native_even_q },
    // apply + HOFs.
    .{ .name = "apply", .descriptor = &native_apply },
    .{ .name = "map", .descriptor = &native_map },
    .{ .name = "reduce", .descriptor = &native_reduce },
    .{ .name = "reduce-kv", .descriptor = &native_reduce_kv },
    .{ .name = "filter", .descriptor = &native_filter },
    .{ .name = "remove", .descriptor = &native_remove },
    .{ .name = "keep", .descriptor = &native_keep },
    .{ .name = "seq", .descriptor = &native_seq },
    .{ .name = "next", .descriptor = &native_next },
    .{ .name = "range", .descriptor = &native_range },
    .{ .name = "concat", .descriptor = &native_concat },
    .{ .name = "mapcat", .descriptor = &native_mapcat },
    .{ .name = "into", .descriptor = &native_into },
    .{ .name = "mapv", .descriptor = &native_mapv },
    .{ .name = "filterv", .descriptor = &native_filterv },
    .{ .name = "map-indexed", .descriptor = &native_map_indexed },
    .{ .name = "keep-indexed", .descriptor = &native_keep_indexed },
    .{ .name = "distinct", .descriptor = &native_distinct },
    .{ .name = "partition", .descriptor = &native_partition },
    .{ .name = "partition-all", .descriptor = &native_partition_all },
    .{ .name = "interleave", .descriptor = &native_interleave },
    .{ .name = "zipmap", .descriptor = &native_zipmap },
    .{ .name = "take-while", .descriptor = &native_take_while },
    .{ .name = "drop-while", .descriptor = &native_drop_while },
    .{ .name = "butlast", .descriptor = &native_butlast },
    .{ .name = "nthrest", .descriptor = &native_nthrest },
    .{ .name = "split-at", .descriptor = &native_split_at },
    .{ .name = "take-last", .descriptor = &native_take_last },
    .{ .name = "drop-last", .descriptor = &native_drop_last },
    .{ .name = "flatten", .descriptor = &native_flatten },
    .{ .name = "reductions", .descriptor = &native_reductions },
    .{ .name = "repeat", .descriptor = &native_repeat },
    .{ .name = "repeatedly", .descriptor = &native_repeatedly },
    .{ .name = "iterate", .descriptor = &native_iterate },
    .{ .name = "max-key", .descriptor = &native_max_key },
    .{ .name = "min-key", .descriptor = &native_min_key },
    .{ .name = "select-keys", .descriptor = &native_select_keys },
    .{ .name = "find", .descriptor = &native_find },
    .{ .name = "key", .descriptor = &native_key },
    .{ .name = "val", .descriptor = &native_val },
    .{ .name = "peek", .descriptor = &native_peek },
    .{ .name = "pop", .descriptor = &native_pop },
    .{ .name = "empty", .descriptor = &native_empty },
    .{ .name = "not-empty", .descriptor = &native_not_empty },
    .{ .name = "disj", .descriptor = &native_disj },
    .{ .name = "compare", .descriptor = &native_compare },
    .{ .name = "sort", .descriptor = &native_sort },
    .{ .name = "sort-by", .descriptor = &native_sort_by },
    .{ .name = "hash", .descriptor = &native_hash },
    .{ .name = "name", .descriptor = &native_name },
    .{ .name = "namespace", .descriptor = &native_namespace },
    .{ .name = "keyword", .descriptor = &native_keyword },
    .{ .name = "symbol", .descriptor = &native_symbol },
    .{ .name = "gensym", .descriptor = &native_gensym },
    // Metadata (PLAN §8.5).
    .{ .name = "meta", .descriptor = &native_meta },
    .{ .name = "with-meta", .descriptor = &native_with_meta },
    .{ .name = "reset-meta!", .descriptor = &native_reset_meta },
    .{ .name = "alter-meta!", .descriptor = &native_alter_meta },
    .{ .name = "boolean", .descriptor = &native_boolean },
    .{ .name = "list?", .descriptor = &native_list_q },
    .{ .name = "seq?", .descriptor = &native_seq_q },
    .{ .name = "vector?", .descriptor = &native_vector_q },
    .{ .name = "map?", .descriptor = &native_map_q },
    .{ .name = "set?", .descriptor = &native_set_q },
    .{ .name = "keyword?", .descriptor = &native_keyword_q },
    .{ .name = "symbol?", .descriptor = &native_symbol_q },
    .{ .name = "char?", .descriptor = &native_char_q },
    .{ .name = "boolean?", .descriptor = &native_boolean_q },
    .{ .name = "coll?", .descriptor = &native_coll_q },
    .{ .name = "sequential?", .descriptor = &native_sequential_q },
    .{ .name = "associative?", .descriptor = &native_associative_q },
    .{ .name = "fn?", .descriptor = &native_fn_q },
    .{ .name = "ifn?", .descriptor = &native_ifn_q },
    // Collection construction + access.
    .{ .name = "vector", .descriptor = &native_vector },
    .{ .name = "vec", .descriptor = &native_vec },
    .{ .name = "hash-map", .descriptor = &native_hash_map },
    .{ .name = "hash-set", .descriptor = &native_hash_set },
    .{ .name = "set", .descriptor = &native_set },
    .{ .name = "subvec", .descriptor = &native_subvec },
    .{ .name = "identical?", .descriptor = &native_identical_q },
    .{ .name = "assoc", .descriptor = &native_assoc },
    .{ .name = "dissoc", .descriptor = &native_dissoc },
    .{ .name = "get", .descriptor = &native_get },
    .{ .name = "contains?", .descriptor = &native_contains_q },
    .{ .name = "keys", .descriptor = &native_keys },
    .{ .name = "vals", .descriptor = &native_vals },
    .{ .name = "conj", .descriptor = &native_conj },
    // Atom primitives.
    // Identity-valued in-memory mutable cells. `deref` is
    // installed above (`&native_db_deref` aliased in
    // db_fns; we also expose it as bare `deref` here so
    // `(deref atom-or-var-or-durable-ref)` resolves without the
    // `db/` prefix). See `docs/ATOM.md`.
    .{ .name = "deref", .descriptor = &native_db_deref },
    .{ .name = "atom", .descriptor = &native_atom },
    .{ .name = "atom?", .descriptor = &native_atom_q },
    .{ .name = "reset!", .descriptor = &native_reset_bang },
    .{ .name = "swap!", .descriptor = &native_swap_bang },
    .{ .name = "swap-vals!", .descriptor = &native_swap_vals_bang },
    .{ .name = "compare-and-set!", .descriptor = &native_compare_and_set_bang },
    // satisfies? predicate.
    .{ .name = "satisfies?", .descriptor = &native_satisfies_q },
    // Core string ops. Indexing semantics are by Unicode scalar
    // (codepoint), NOT byte; see `docs/STRING.md` §7.
    .{ .name = "str", .descriptor = &native_str },
    .{ .name = "string?", .descriptor = &native_string_q },
    .{ .name = "subs", .descriptor = &native_subs },
    // Printing + I/O.
    .{ .name = "print", .descriptor = &native_print },
    .{ .name = "println", .descriptor = &native_println },
    .{ .name = "prn", .descriptor = &native_prn },
    .{ .name = "pr-str", .descriptor = &native_pr_str },
    .{ .name = "slurp", .descriptor = &native_slurp },
    .{ .name = "spit", .descriptor = &native_spit },
    // db primitives live in the `db` namespace
    // (installed separately via `installDb`) so they appear as
    // qualified `(db/open ...)` calls.
};

// =============================================================================
// Static descriptors
// =============================================================================

const native_list = NativeFn{
    .name = "list",
    .min_arity = 0,
    .max_arity = null,
    .call = &fnList,
};

const native_cons = NativeFn{
    .name = "cons",
    .min_arity = 2,
    .max_arity = 2,
    .call = &fnCons,
};

const native_first = NativeFn{
    .name = "first",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnFirst,
};

const native_rest = NativeFn{
    .name = "rest",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnRest,
};

const native_count = NativeFn{
    .name = "count",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnCount,
};

const native_nth = NativeFn{
    .name = "nth",
    .min_arity = 2,
    .max_arity = 3,
    .call = &fnNth,
};

const native_empty_q = NativeFn{
    .name = "empty?",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnEmptyQ,
};

const native_identity = NativeFn{
    .name = "identity",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnIdentity,
};

const native_nil_q = NativeFn{
    .name = "nil?",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnNilQ,
};

const native_some_q = NativeFn{
    .name = "some?",
    .min_arity = 1,
    .max_arity = 1,
    .call = &fnSomeQ,
};

// Arithmetic + comparison.
const native_add = NativeFn{ .name = "+", .min_arity = 0, .max_arity = null, .call = &fnAdd };
const native_sub = NativeFn{ .name = "-", .min_arity = 1, .max_arity = null, .call = &fnSub };
const native_mul = NativeFn{ .name = "*", .min_arity = 0, .max_arity = null, .call = &fnMul };
const native_div = NativeFn{ .name = "/", .min_arity = 1, .max_arity = null, .call = &fnDiv };
const native_quot = NativeFn{ .name = "quot", .min_arity = 2, .max_arity = 2, .call = &fnQuot };
const native_rem = NativeFn{ .name = "rem", .min_arity = 2, .max_arity = 2, .call = &fnRem };
const native_mod = NativeFn{ .name = "mod", .min_arity = 2, .max_arity = 2, .call = &fnMod };
const native_lt = NativeFn{ .name = "<", .min_arity = 0, .max_arity = null, .call = &fnLt };
const native_lte = NativeFn{ .name = "<=", .min_arity = 0, .max_arity = null, .call = &fnLte };
const native_gt = NativeFn{ .name = ">", .min_arity = 0, .max_arity = null, .call = &fnGt };
const native_gte = NativeFn{ .name = ">=", .min_arity = 0, .max_arity = null, .call = &fnGte };
const native_num_eq = NativeFn{ .name = "==", .min_arity = 0, .max_arity = null, .call = &fnNumEq };
const native_eq = NativeFn{ .name = "=", .min_arity = 0, .max_arity = null, .call = &fnEq };
const native_not_eq = NativeFn{ .name = "not=", .min_arity = 1, .max_arity = null, .call = &fnNotEq };
const native_inc = NativeFn{ .name = "inc", .min_arity = 1, .max_arity = 1, .call = &fnInc };
const native_dec = NativeFn{ .name = "dec", .min_arity = 1, .max_arity = 1, .call = &fnDec };
const native_max = NativeFn{ .name = "max", .min_arity = 1, .max_arity = null, .call = &fnMax };
const native_min = NativeFn{ .name = "min", .min_arity = 1, .max_arity = null, .call = &fnMin };
const native_abs = NativeFn{ .name = "abs", .min_arity = 1, .max_arity = 1, .call = &fnAbs };
const native_number_q = NativeFn{ .name = "number?", .min_arity = 1, .max_arity = 1, .call = &fnNumberQ };
const native_integer_q = NativeFn{ .name = "integer?", .min_arity = 1, .max_arity = 1, .call = &fnIntegerQ };
const native_float_q = NativeFn{ .name = "float?", .min_arity = 1, .max_arity = 1, .call = &fnFloatQ };
const native_nan_q = NativeFn{ .name = "NaN?", .min_arity = 1, .max_arity = 1, .call = &fnNanQ };
const native_infinite_q = NativeFn{ .name = "infinite?", .min_arity = 1, .max_arity = 1, .call = &fnInfiniteQ };
const native_not = NativeFn{ .name = "not", .min_arity = 1, .max_arity = 1, .call = &fnNot };
const native_zero_q = NativeFn{ .name = "zero?", .min_arity = 1, .max_arity = 1, .call = &fnZeroQ };
const native_pos_q = NativeFn{ .name = "pos?", .min_arity = 1, .max_arity = 1, .call = &fnPosQ };
const native_neg_q = NativeFn{ .name = "neg?", .min_arity = 1, .max_arity = 1, .call = &fnNegQ };
const native_odd_q = NativeFn{ .name = "odd?", .min_arity = 1, .max_arity = 1, .call = &fnOddQ };
const native_even_q = NativeFn{ .name = "even?", .min_arity = 1, .max_arity = 1, .call = &fnEvenQ };

// apply + HOFs.
const native_apply = NativeFn{ .name = "apply", .min_arity = 2, .max_arity = null, .call = &fnApply };
const native_map = NativeFn{ .name = "map", .min_arity = 2, .max_arity = null, .call = &fnMap };
const native_reduce = NativeFn{ .name = "reduce", .min_arity = 2, .max_arity = 3, .call = &fnReduce };
const native_reduce_kv = NativeFn{ .name = "reduce-kv", .min_arity = 3, .max_arity = 3, .call = &fnReduceKv };
const native_filter = NativeFn{ .name = "filter", .min_arity = 2, .max_arity = 2, .call = &fnFilter };
const native_remove = NativeFn{ .name = "remove", .min_arity = 2, .max_arity = 2, .call = &fnRemove };
const native_keep = NativeFn{ .name = "keep", .min_arity = 2, .max_arity = 2, .call = &fnKeep };
const native_seq = NativeFn{ .name = "seq", .min_arity = 1, .max_arity = 1, .call = &fnSeq };
const native_next = NativeFn{ .name = "next", .min_arity = 1, .max_arity = 1, .call = &fnNext };
const native_range = NativeFn{ .name = "range", .min_arity = 1, .max_arity = 3, .call = &fnRange };
const native_concat = NativeFn{ .name = "concat", .min_arity = 0, .max_arity = null, .call = &fnConcat };
const native_mapcat = NativeFn{ .name = "mapcat", .min_arity = 2, .max_arity = null, .call = &fnMapcat };
const native_into = NativeFn{ .name = "into", .min_arity = 2, .max_arity = 2, .call = &fnInto };
const native_mapv = NativeFn{ .name = "mapv", .min_arity = 2, .max_arity = null, .call = &fnMapv };
const native_filterv = NativeFn{ .name = "filterv", .min_arity = 2, .max_arity = 2, .call = &fnFilterv };
const native_map_indexed = NativeFn{ .name = "map-indexed", .min_arity = 2, .max_arity = 2, .call = &fnMapIndexed };
const native_keep_indexed = NativeFn{ .name = "keep-indexed", .min_arity = 2, .max_arity = 2, .call = &fnKeepIndexed };
const native_distinct = NativeFn{ .name = "distinct", .min_arity = 1, .max_arity = 1, .call = &fnDistinct };
const native_partition = NativeFn{ .name = "partition", .min_arity = 2, .max_arity = 4, .call = &fnPartition };
const native_partition_all = NativeFn{ .name = "partition-all", .min_arity = 2, .max_arity = 3, .call = &fnPartitionAll };
const native_interleave = NativeFn{ .name = "interleave", .min_arity = 0, .max_arity = null, .call = &fnInterleave };
const native_zipmap = NativeFn{ .name = "zipmap", .min_arity = 2, .max_arity = 2, .call = &fnZipmap };
const native_take_while = NativeFn{ .name = "take-while", .min_arity = 2, .max_arity = 2, .call = &fnTakeWhile };
const native_drop_while = NativeFn{ .name = "drop-while", .min_arity = 2, .max_arity = 2, .call = &fnDropWhile };
const native_butlast = NativeFn{ .name = "butlast", .min_arity = 1, .max_arity = 1, .call = &fnButlast };
const native_nthrest = NativeFn{ .name = "nthrest", .min_arity = 2, .max_arity = 2, .call = &fnNthrest };
const native_split_at = NativeFn{ .name = "split-at", .min_arity = 2, .max_arity = 2, .call = &fnSplitAt };
const native_take_last = NativeFn{ .name = "take-last", .min_arity = 2, .max_arity = 2, .call = &fnTakeLast };
const native_drop_last = NativeFn{ .name = "drop-last", .min_arity = 2, .max_arity = 2, .call = &fnDropLast };
const native_flatten = NativeFn{ .name = "flatten", .min_arity = 1, .max_arity = 1, .call = &fnFlatten };
const native_reductions = NativeFn{ .name = "reductions", .min_arity = 2, .max_arity = 3, .call = &fnReductions };
const native_repeat = NativeFn{ .name = "repeat", .min_arity = 2, .max_arity = 2, .call = &fnRepeat };
const native_repeatedly = NativeFn{ .name = "repeatedly", .min_arity = 2, .max_arity = 2, .call = &fnRepeatedly };
const native_iterate = NativeFn{ .name = "iterate", .min_arity = 3, .max_arity = 3, .call = &fnIterate };
const native_max_key = NativeFn{ .name = "max-key", .min_arity = 2, .max_arity = null, .call = &fnMaxKey };
const native_min_key = NativeFn{ .name = "min-key", .min_arity = 2, .max_arity = null, .call = &fnMinKey };
const native_select_keys = NativeFn{ .name = "select-keys", .min_arity = 2, .max_arity = 2, .call = &fnSelectKeys };
const native_find = NativeFn{ .name = "find", .min_arity = 2, .max_arity = 2, .call = &fnFind };
const native_key = NativeFn{ .name = "key", .min_arity = 1, .max_arity = 1, .call = &fnKey };
const native_val = NativeFn{ .name = "val", .min_arity = 1, .max_arity = 1, .call = &fnVal };
const native_peek = NativeFn{ .name = "peek", .min_arity = 1, .max_arity = 1, .call = &fnPeek };
const native_pop = NativeFn{ .name = "pop", .min_arity = 1, .max_arity = 1, .call = &fnPop };
const native_empty = NativeFn{ .name = "empty", .min_arity = 1, .max_arity = 1, .call = &fnEmpty };
const native_not_empty = NativeFn{ .name = "not-empty", .min_arity = 1, .max_arity = 1, .call = &fnNotEmpty };
const native_disj = NativeFn{ .name = "disj", .min_arity = 1, .max_arity = null, .call = &fnDisj };
const native_compare = NativeFn{ .name = "compare", .min_arity = 2, .max_arity = 2, .call = &fnCompare };
const native_sort = NativeFn{ .name = "sort", .min_arity = 1, .max_arity = 2, .call = &fnSort };
const native_sort_by = NativeFn{ .name = "sort-by", .min_arity = 2, .max_arity = 3, .call = &fnSortBy };
const native_hash = NativeFn{ .name = "hash", .min_arity = 1, .max_arity = 1, .call = &fnHash };
const native_name = NativeFn{ .name = "name", .min_arity = 1, .max_arity = 1, .call = &fnName };
const native_namespace = NativeFn{ .name = "namespace", .min_arity = 1, .max_arity = 1, .call = &fnNamespace };
const native_keyword = NativeFn{ .name = "keyword", .min_arity = 1, .max_arity = 2, .call = &fnKeyword };
const native_symbol = NativeFn{ .name = "symbol", .min_arity = 1, .max_arity = 2, .call = &fnSymbol };
const native_gensym = NativeFn{ .name = "gensym", .min_arity = 0, .max_arity = 1, .call = &fnGensym };
const native_meta = NativeFn{ .name = "meta", .min_arity = 1, .max_arity = 1, .call = &fnMeta };
const native_with_meta = NativeFn{ .name = "with-meta", .min_arity = 2, .max_arity = 2, .call = &fnWithMeta };
const native_reset_meta = NativeFn{ .name = "reset-meta!", .min_arity = 2, .max_arity = 2, .call = &fnResetMeta };
const native_alter_meta = NativeFn{ .name = "alter-meta!", .min_arity = 2, .max_arity = null, .call = &fnAlterMeta };
const native_boolean = NativeFn{ .name = "boolean", .min_arity = 1, .max_arity = 1, .call = &fnBoolean };
const native_list_q = NativeFn{ .name = "list?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isList) };
const native_seq_q = NativeFn{ .name = "seq?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isList) };
const native_vector_q = NativeFn{ .name = "vector?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isVector) };
const native_map_q = NativeFn{ .name = "map?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isMap) };
const native_set_q = NativeFn{ .name = "set?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isSet) };
const native_keyword_q = NativeFn{ .name = "keyword?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isKeyword) };
const native_symbol_q = NativeFn{ .name = "symbol?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isSymbol) };
const native_char_q = NativeFn{ .name = "char?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isChar) };
const native_boolean_q = NativeFn{ .name = "boolean?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isBoolean) };
const native_coll_q = NativeFn{ .name = "coll?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isColl) };
const native_sequential_q = NativeFn{ .name = "sequential?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isSequential) };
const native_associative_q = NativeFn{ .name = "associative?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isAssociative) };
const native_fn_q = NativeFn{ .name = "fn?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isFn) };
const native_ifn_q = NativeFn{ .name = "ifn?", .min_arity = 1, .max_arity = 1, .call = kindPredicate(isIfn) };

// Collection utilities.
const native_vector = NativeFn{ .name = "vector", .min_arity = 0, .max_arity = null, .call = &fnVector };
const native_vec = NativeFn{ .name = "vec", .min_arity = 1, .max_arity = 1, .call = &fnVec };
const native_hash_map = NativeFn{ .name = "hash-map", .min_arity = 0, .max_arity = null, .call = &fnHashMap };
const native_hash_set = NativeFn{ .name = "hash-set", .min_arity = 0, .max_arity = null, .call = &fnHashSet };
const native_set = NativeFn{ .name = "set", .min_arity = 1, .max_arity = 1, .call = &fnSet };
const native_subvec = NativeFn{ .name = "subvec", .min_arity = 2, .max_arity = 3, .call = &fnSubvec };
const native_identical_q = NativeFn{ .name = "identical?", .min_arity = 2, .max_arity = 2, .call = &fnIdenticalQ };
const native_assoc = NativeFn{ .name = "assoc", .min_arity = 3, .max_arity = null, .call = &fnAssoc };
const native_dissoc = NativeFn{ .name = "dissoc", .min_arity = 1, .max_arity = null, .call = &fnDissoc };
const native_get = NativeFn{ .name = "get", .min_arity = 2, .max_arity = 3, .call = &fnGet };
const native_contains_q = NativeFn{ .name = "contains?", .min_arity = 2, .max_arity = 2, .call = &fnContainsQ };
const native_keys = NativeFn{ .name = "keys", .min_arity = 1, .max_arity = 1, .call = &fnKeys };
const native_vals = NativeFn{ .name = "vals", .min_arity = 1, .max_arity = 1, .call = &fnVals };
const native_conj = NativeFn{ .name = "conj", .min_arity = 1, .max_arity = null, .call = &fnConj };

// db primitives.
const native_db_open = NativeFn{ .name = "db/open", .min_arity = 1, .max_arity = 1, .call = &fnDbOpen };
const native_db_close = NativeFn{ .name = "db/close", .min_arity = 1, .max_arity = 1, .call = &fnDbClose };
const native_db_ref = NativeFn{ .name = "db/ref", .min_arity = 3, .max_arity = 3, .call = &fnDbRef };
const native_db_ref_q = NativeFn{ .name = "db/ref?", .min_arity = 1, .max_arity = 1, .call = &fnDbRefQ };
const native_db_put_key = NativeFn{ .name = "db/put-key!", .min_arity = 2, .max_arity = 2, .call = &fnDbPutKey };
const native_db_get_key = NativeFn{ .name = "db/get-key", .min_arity = 1, .max_arity = 2, .call = &fnDbGetKey };
const native_db_delete_key = NativeFn{ .name = "db/delete-key!", .min_arity = 1, .max_arity = 1, .call = &fnDbDeleteKey };
const native_db_present_q = NativeFn{ .name = "db/present?", .min_arity = 1, .max_arity = 1, .call = &fnDbPresentQ };
// Explicit tx primitives.
const native_db_begin_write = NativeFn{ .name = "db/begin-write", .min_arity = 1, .max_arity = 1, .call = &fnDbBeginWrite };
const native_db_begin_read = NativeFn{ .name = "db/begin-read", .min_arity = 1, .max_arity = 1, .call = &fnDbBeginRead };
const native_db_commit = NativeFn{ .name = "db/commit!", .min_arity = 1, .max_arity = 1, .call = &fnDbCommit };
const native_db_abort_write = NativeFn{ .name = "db/abort-write!", .min_arity = 1, .max_arity = 1, .call = &fnDbAbortWrite };
const native_db_abort_read = NativeFn{ .name = "db/abort-read!", .min_arity = 1, .max_arity = 1, .call = &fnDbAbortRead };
const native_db_put = NativeFn{ .name = "db/put!", .min_arity = 3, .max_arity = 3, .call = &fnDbPut };
const native_db_get = NativeFn{ .name = "db/get", .min_arity = 2, .max_arity = 3, .call = &fnDbGet };
const native_db_delete = NativeFn{ .name = "db/delete!", .min_arity = 2, .max_arity = 2, .call = &fnDbDelete };
// deref + alter.
const native_db_deref = NativeFn{ .name = "deref", .min_arity = 1, .max_arity = 1, .call = &fnDbDeref };

// Atoms.
const native_atom = NativeFn{ .name = "atom", .min_arity = 1, .max_arity = 1, .call = &fnAtom };
const native_atom_q = NativeFn{ .name = "atom?", .min_arity = 1, .max_arity = 1, .call = &fnAtomQ };
const native_reset_bang = NativeFn{ .name = "reset!", .min_arity = 2, .max_arity = 2, .call = &fnResetBang };
const native_swap_bang = NativeFn{ .name = "swap!", .min_arity = 2, .max_arity = null, .call = &fnSwapBang };
const native_swap_vals_bang = NativeFn{ .name = "swap-vals!", .min_arity = 2, .max_arity = null, .call = &fnSwapValsBang };
const native_compare_and_set_bang = NativeFn{ .name = "compare-and-set!", .min_arity = 3, .max_arity = 3, .call = &fnCompareAndSetBang };

// Core string ops.
const native_str = NativeFn{ .name = "str", .min_arity = 0, .max_arity = null, .call = &fnStr };
const native_string_q = NativeFn{ .name = "string?", .min_arity = 1, .max_arity = 1, .call = &fnStringQ };
const native_subs = NativeFn{ .name = "subs", .min_arity = 2, .max_arity = 3, .call = &fnSubs };

// Printing + I/O.
const native_print = NativeFn{ .name = "print", .min_arity = 0, .max_arity = null, .call = &fnPrint };
const native_println = NativeFn{ .name = "println", .min_arity = 0, .max_arity = null, .call = &fnPrintln };
const native_prn = NativeFn{ .name = "prn", .min_arity = 0, .max_arity = null, .call = &fnPrn };
const native_pr_str = NativeFn{ .name = "pr-str", .min_arity = 0, .max_arity = null, .call = &fnPrStr };
const native_slurp = NativeFn{ .name = "slurp", .min_arity = 1, .max_arity = 1, .call = &fnSlurp };
const native_spit = NativeFn{ .name = "spit", .min_arity = 2, .max_arity = 2, .call = &fnSpit };

// Record internals. All four
// install into `nexis.internal`; macros emit qualified calls.
const native_register_record_type = NativeFn{ .name = "#%register-record-type", .min_arity = 2, .max_arity = 2, .call = &fnRegisterRecordType };
const native_make_record = NativeFn{ .name = "#%make-record", .min_arity = 2, .max_arity = 2, .call = &fnMakeRecord };
const native_record_q = NativeFn{ .name = "#%record?", .min_arity = 1, .max_arity = 1, .call = &fnRecordQ };
const native_record_type_id = NativeFn{ .name = "#%record-type-id", .min_arity = 1, .max_arity = 1, .call = &fnRecordTypeId };

// Protocol internals.
const native_register_protocol = NativeFn{ .name = "#%register-protocol", .min_arity = 2, .max_arity = 2, .call = &fnRegisterProtocol };
const native_protocol_fn = NativeFn{ .name = "#%protocol-fn", .min_arity = 2, .max_arity = 2, .call = &fnProtocolFn };
// defrecord inline protocol impls.
const native_extend_record_impl = NativeFn{ .name = "#%extend-record-impl", .min_arity = 4, .max_arity = 4, .call = &fnExtendRecordImpl };
// extend-protocol over built-in kinds + Any default + satisfies?.
const native_extend_builtin_impl = NativeFn{ .name = "#%extend-builtin-impl", .min_arity = 4, .max_arity = 4, .call = &fnExtendBuiltinImpl };
const native_extend_default_impl = NativeFn{ .name = "#%extend-default-impl", .min_arity = 3, .max_arity = 3, .call = &fnExtendDefaultImpl };
const native_kwargs = NativeFn{ .name = "#%kwargs", .min_arity = 1, .max_arity = 1, .call = &fnKwargs };
const native_catch_matches = NativeFn{ .name = "#%catch-matches?", .min_arity = 2, .max_arity = 2, .call = &fnCatchMatches };
const native_satisfies_q = NativeFn{ .name = "satisfies?", .min_arity = 2, .max_arity = 2, .call = &fnSatisfiesQ };

// nexis.string namespace.
const native_string_lower_case = NativeFn{ .name = "nexis.string/lower-case", .min_arity = 1, .max_arity = 1, .call = &fnStringLowerCase };
const native_string_upper_case = NativeFn{ .name = "nexis.string/upper-case", .min_arity = 1, .max_arity = 1, .call = &fnStringUpperCase };
const native_string_trim = NativeFn{ .name = "nexis.string/trim", .min_arity = 1, .max_arity = 1, .call = &fnStringTrim };
const native_string_split = NativeFn{ .name = "nexis.string/split", .min_arity = 2, .max_arity = 2, .call = &fnStringSplit };
const native_string_join = NativeFn{ .name = "nexis.string/join", .min_arity = 1, .max_arity = 2, .call = &fnStringJoin };
const native_string_replace = NativeFn{ .name = "nexis.string/replace", .min_arity = 3, .max_arity = 3, .call = &fnStringReplace };
const native_db_alter = NativeFn{ .name = "db/alter!", .min_arity = 3, .max_arity = null, .call = &fnDbAlter };
// scan + reduce-tree.
const native_db_scan = NativeFn{ .name = "db/scan", .min_arity = 2, .max_arity = 4, .call = &fnDbScan };
const native_db_reduce_tree = NativeFn{ .name = "db/reduce-tree", .min_arity = 4, .max_arity = 4, .call = &fnDbReduceTree };
// Snapshot aliases. emdb read transactions ARE
// snapshots (pinned to the commit generation at begin time).
// These names give users PLAN.md §15.7 vocabulary without
// duplicating the underlying mechanism.
const native_db_snapshot = NativeFn{ .name = "db/snapshot", .min_arity = 1, .max_arity = 1, .call = &fnDbBeginRead };
const native_db_release_snapshot = NativeFn{ .name = "db/release-snapshot!", .min_arity = 1, .max_arity = 1, .call = &fnDbAbortRead };
const native_db_snapshot_q = NativeFn{ .name = "db/snapshot?", .min_arity = 1, .max_arity = 1, .call = &fnDbSnapshotQ };

// =============================================================================
// Implementations
// =============================================================================

/// `(list & xs)` → fresh cons list of the args (left-to-right).
/// `(list)` is the empty list. The partial result is not
/// rooted; `Heap.alloc` never collects (GC.md §9).
fn fnList(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        result = list_mod.cons(heap, args[i], result) catch return VmError.OutOfMemory;
    }
    return result;
}

/// `(cons x s)` → new cons cell with `x` as head and `s` as
/// tail. `s` may be nil (treated as empty) or a list; other
/// kinds are a `KindMismatch`.
fn fnCons(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    const tail_v = try coerceToList(vm, args[1]);
    const heap = vm.ensureHeap();
    return list_mod.cons(heap, x, tail_v) catch VmError.OutOfMemory;
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
/// Always returns a list (empty if input is empty/nil).
fn fnRest(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    const heap = vm.ensureHeap();
    return switch (s.kind()) {
        .nil => list_mod.empty(heap) catch VmError.OutOfMemory,
        .list => if (list_mod.isEmpty(s))
            list_mod.empty(heap) catch VmError.OutOfMemory
        else
            list_mod.tail(s),
        .persistent_vector => blk: {
            const n = vector_mod.count(s);
            if (n <= 1) {
                break :blk list_mod.empty(heap) catch VmError.OutOfMemory;
            }
            // Build a list from elements [1..n-1] in reverse so
            // cons threads correctly.
            var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
            var i: usize = n;
            while (i > 1) {
                i -= 1;
                result = list_mod.cons(heap, vector_mod.nth(s, i), result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        else => blk: {
            var items = try collectSeq(vm, s);
            defer items.deinit(vm.allocator);
            if (items.items.len <= 1) break :blk list_mod.empty(heap) catch VmError.OutOfMemory;
            break :blk try buildListFromSlice(vm, items.items[1..]);
        },
    };
}

/// `(next s)` → `(seq (rest s))`: nil when nothing follows.
fn fnNext(vm: *VM, args: []const Value) VmError!Value {
    const r = try fnRest(vm, args);
    return if (list_mod.isEmpty(r)) value_mod.nilValue() else r;
}

/// `(seq coll)` → nil for nil or an empty collection, otherwise a
/// list of the collection's elements (a non-empty list is
/// returned as is). Maps yield `[k v]` entries, strings chars.
fn fnSeq(vm: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    if (c.kind() == .list) return if (list_mod.isEmpty(c)) value_mod.nilValue() else c;
    var items = try collectSeq(vm, c);
    defer items.deinit(vm.allocator);
    if (items.items.len == 0) return value_mod.nilValue();
    return try buildListFromSlice(vm, items.items);
}

/// `(count coll)` → element count. nil → 0. Lists, vectors,
/// maps, records, sets and strings; a string counts Unicode
/// scalars, not bytes.
fn fnCount(_: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    const n: i64 = switch (c.kind()) {
        .nil => 0,
        .list => @intCast(list_mod.count(c)),
        .persistent_vector => @intCast(vector_mod.count(c)),
        .persistent_map => @intCast(champ_mod.mapCount(c)),
        .record => @intCast(champ_mod.mapCount(record_mod.fieldsOf(c))),
        .persistent_set => @intCast(champ_mod.setCount(c)),
        .string => @intCast(string_mod.codepointCount(c) catch return VmError.Utf8Error),
        else => return VmError.KindMismatch,
    };
    return value_mod.fromFixnum(n) orelse VmError.ArithmeticOverflow;
}

/// `(nth coll n)` → element at index `n`. Throws on out-of-
/// bounds. Negative indices rejected as `IndexOutOfBounds`.
///
/// `(nth coll n default)` → element at index `n`, or `default`
/// if out-of-bounds. nil coll always returns default. Required
/// by destructuring: `[a b c]` against a 2-element source binds
/// c to nil, not throw.
fn fnNth(_: *VM, args: []const Value) VmError!Value {
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
        .nil, .list, .persistent_vector, .string => {},
        else => return VmError.KindMismatch,
    }
    const idx = idx_v.asFixnum();
    if (idx < 0) {
        if (has_default) return default;
        return VmError.IndexOutOfBounds;
    }
    const u_idx: usize = @intCast(idx);
    return switch (coll.kind()) {
        .nil => if (has_default) default else VmError.IndexOutOfBounds,
        .list => blk: {
            if (u_idx >= list_mod.count(coll)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            var node = coll;
            var i: usize = 0;
            while (i < u_idx) : (i += 1) node = list_mod.tail(node);
            break :blk list_mod.head(node);
        },
        .persistent_vector => blk: {
            if (u_idx >= vector_mod.count(coll)) {
                if (has_default) break :blk default;
                return VmError.IndexOutOfBounds;
            }
            break :blk vector_mod.nth(coll, u_idx);
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
/// empty UTF-8 ↔ zero codepoints, so no codepoint walk needed.
fn fnEmptyQ(_: *VM, args: []const Value) VmError!Value {
    const c = args[0];
    const is_empty = switch (c.kind()) {
        .nil => true,
        .list => list_mod.isEmpty(c),
        .persistent_vector => vector_mod.isEmpty(c),
        .persistent_map => champ_mod.mapCount(c) == 0,
        .record => champ_mod.mapCount(record_mod.fieldsOf(c)) == 0,
        .persistent_set => champ_mod.setCount(c) == 0,
        .string => string_mod.byteLen(c) == 0,
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

const dispatch_mod = @import("dispatch");

fn requireNumber(v: Value) VmError!Value {
    if (!vm_mod.isNumber(v)) return VmError.KindMismatch;
    return v;
}

fn requireFixnum(v: Value) VmError!i64 {
    if (v.kind() != .fixnum) return VmError.KindMismatch;
    return v.asFixnum();
}

const BinaryNum = *const fn (Value, Value) VmError!Value;

/// Left fold of `op` over `args`, which must be non-empty.
fn foldNumbers(op: BinaryNum, args: []const Value) VmError!Value {
    var acc = try requireNumber(args[0]);
    for (args[1..]) |x| acc = try op(acc, x);
    return acc;
}

fn fnAdd(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return value_mod.fromFixnum(0).?;
    return foldNumbers(&vm_mod.numAdd, args);
}

fn fnSub(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return vm_mod.numNeg(args[0]);
    return foldNumbers(&vm_mod.numSub, args);
}

fn fnMul(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 0) return value_mod.fromFixnum(1).?;
    return foldNumbers(&vm_mod.numMul, args);
}

fn fnDiv(_: *VM, args: []const Value) VmError!Value {
    if (args.len == 1) return vm_mod.numDiv(value_mod.fromFixnum(1).?, args[0]);
    return foldNumbers(&vm_mod.numDiv, args);
}

fn fnQuot(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numQuot(args[0], args[1]);
}

fn fnRem(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numRem(args[0], args[1]);
}

fn fnMod(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numMod(args[0], args[1]);
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

fn fnInc(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numAdd(args[0], value_mod.fromFixnum(1).?);
}

fn fnDec(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numSub(args[0], value_mod.fromFixnum(1).?);
}

fn numMax(a: Value, b: Value) VmError!Value {
    return vm_mod.numExtremum(true, a, b);
}

fn numMin(a: Value, b: Value) VmError!Value {
    return vm_mod.numExtremum(false, a, b);
}

fn fnMax(_: *VM, args: []const Value) VmError!Value {
    return foldNumbers(&numMax, args);
}

fn fnMin(_: *VM, args: []const Value) VmError!Value {
    return foldNumbers(&numMin, args);
}

fn fnAbs(_: *VM, args: []const Value) VmError!Value {
    return vm_mod.numAbs(args[0]);
}

fn fnNot(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(!args[0].isTruthy());
}

fn fnZeroQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(try vm_mod.numSign(args[0]) == .eq);
}

fn fnPosQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(try vm_mod.numSign(args[0]) == .gt);
}

fn fnNegQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(try vm_mod.numSign(args[0]) == .lt);
}

/// `even?` / `odd?` are integer-only, as in Clojure.
fn fnOddQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(@mod(x, 2) != 0);
}

fn fnEvenQ(_: *VM, args: []const Value) VmError!Value {
    const x = try requireFixnum(args[0]);
    return value_mod.fromBool(@mod(x, 2) == 0);
}

fn fnNumberQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(vm_mod.isNumber(args[0]));
}

fn fnIntegerQ(_: *VM, args: []const Value) VmError!Value {
    return value_mod.fromBool(args[0].kind() == .fixnum);
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
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    try mapInto(vm, args[0], args[1..], &results);
    return try buildListFromSlice(vm, results.items);
}

/// Append `(f x1 x2 ...)` for every position of the shortest of
/// `colls` to `out`.
fn mapInto(vm: *VM, f: Value, colls: []const Value, out: *std.ArrayList(Value)) VmError!void {
    if (colls.len == 1) {
        var it = try makeSeqIter(vm, colls[0]);
        while (try it.next()) |x| {
            const one = [_]Value{x};
            out.append(vm.allocator, try vm.callValue(f, &one)) catch return VmError.OutOfMemory;
        }
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
        out.append(vm.allocator, try vm.callValue(f, call_args)) catch return VmError.OutOfMemory;
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
        const pair = [_]Value{ acc, x };
        acc = try vm.callValue(f, &pair);
    }
    return acc;
}

/// `(reduce-kv f init m)` → `(f acc k v)` over a map's entries or
/// a vector's index/element pairs.
fn fnReduceKv(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    var acc = args[1];
    const coll = args[2];
    switch (coll.kind()) {
        .nil => {},
        .persistent_map, .record => {
            var it = champ_mod.mapIter(if (coll.kind() == .record) record_mod.fieldsOf(coll) else coll);
            while (it.next()) |e| {
                acc = try vm.callValue(f, &.{ acc, e.key, e.value });
            }
        },
        .persistent_vector => {
            const n = vector_mod.count(coll);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                acc = try vm.callValue(f, &.{ acc, value_mod.fromFixnum(@intCast(i)).?, vector_mod.nth(coll, i) });
            }
        },
        else => return VmError.KindMismatch,
    }
    return acc;
}

/// Shared body of `filter` / `remove` / `keep`.
const Sieve = enum { keep_truthy, keep_falsy, keep_result };

fn sieve(vm: *VM, mode: Sieve, pred: Value, coll: Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    try sieveInto(vm, mode, pred, coll, &results);
    return try buildListFromSlice(vm, results.items);
}

fn sieveInto(vm: *VM, mode: Sieve, pred: Value, coll: Value, out: *std.ArrayList(Value)) VmError!void {
    var it = try makeSeqIter(vm, coll);
    while (try it.next()) |x| {
        const one = [_]Value{x};
        const r = try vm.callValue(pred, &one);
        const kept: ?Value = switch (mode) {
            .keep_truthy => if (r.isTruthy()) x else null,
            .keep_falsy => if (r.isTruthy()) null else x,
            .keep_result => if (r.isNil()) null else r,
        };
        if (kept) |v| out.append(vm.allocator, v) catch return VmError.OutOfMemory;
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

fn fnGet(_: *VM, args: []const Value) VmError!Value {
    const default = if (args.len > 2) args[2] else value_mod.nilValue();
    if (args[0].kind() == .string) return (try stringIndex(args[0], args[1])) orelse default;
    return vm_mod.lookup(args[0], args[1], default);
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

fn fnContainsQ(_: *VM, args: []const Value) VmError!Value {
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
        .record => value_mod.fromBool(switch (champ_mod.mapGet(
            record_mod.fieldsOf(coll),
            k,
            &dispatch_mod.hashValue,
            &dispatch_mod.equal,
        )) {
            .present => true,
            .absent => false,
        }),
        else => return VmError.KindMismatch,
    };
}

fn fnKeys(vm: *VM, args: []const Value) VmError!Value {
    return mapPart(vm, args[0], .key);
}

fn fnVals(vm: *VM, args: []const Value) VmError!Value {
    return mapPart(vm, args[0], .value);
}

/// `(keys m)` / `(vals m)`: the keys or values of a map or record
/// as a list, nil when there are none (so `(if (keys m) ...)`
/// reads as in Clojure).
fn mapPart(vm: *VM, m: Value, part: enum { key, value }) VmError!Value {
    const map_v: Value = switch (m.kind()) {
        .nil => return value_mod.nilValue(),
        .persistent_map => m,
        .record => record_mod.fieldsOf(m),
        else => return VmError.KindMismatch,
    };
    var collected: std.ArrayList(Value) = .empty;
    defer collected.deinit(vm.allocator);
    var it = champ_mod.mapIter(map_v);
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
fn fnConj(vm: *VM, args: []const Value) VmError!Value {
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
                result = list_mod.cons(heap, x, result) catch return VmError.OutOfMemory;
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
                    .persistent_map, .record => {
                        var it = champ_mod.mapIter(if (x.kind() == .record) record_mod.fieldsOf(x) else x);
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
/// → list of fixnums. A zero step is `:invalid-argument` (there
/// is no infinite sequence to return).
fn fnRange(vm: *VM, args: []const Value) VmError!Value {
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

/// `(into to from)` → `to` with every element of `from` conj'd.
fn fnInto(vm: *VM, args: []const Value) VmError!Value {
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    if (items.items.len == 0) return args[0];
    const conj_args = vm.allocator.alloc(Value, items.items.len + 1) catch return VmError.OutOfMemory;
    defer vm.allocator.free(conj_args);
    conj_args[0] = args[0];
    @memcpy(conj_args[1..], items.items);
    return fnConj(vm, conj_args);
}

/// `(mapv f & colls)` / `(filterv pred coll)` — vector results.
fn fnMapv(vm: *VM, args: []const Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    try mapInto(vm, args[0], args[1..], &results);
    return vector_mod.fromSlice(vm.ensureHeap(), results.items) catch VmError.OutOfMemory;
}

fn fnFilterv(vm: *VM, args: []const Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    try sieveInto(vm, .keep_truthy, args[0], args[1], &results);
    return vector_mod.fromSlice(vm.ensureHeap(), results.items) catch VmError.OutOfMemory;
}

/// `(map-indexed f coll)` → `(f i x)`; `(keep-indexed f coll)` →
/// the non-nil `(f i x)`.
fn indexedMap(vm: *VM, keep_nil: bool, f: Value, coll: Value) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    var it = try makeSeqIter(vm, coll);
    var i: i64 = 0;
    while (try it.next()) |x| : (i += 1) {
        const r = try vm.callValue(f, &.{ value_mod.fromFixnum(i).?, x });
        if (keep_nil or !r.isNil()) results.append(vm.allocator, r) catch return VmError.OutOfMemory;
    }
    return try buildListFromSlice(vm, results.items);
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
    var it = try makeSeqIter(vm, coll);
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

/// A count argument. Negative counts mean zero everywhere Clojure
/// takes one (`nthrest`, `split-at`, `take-last`, `repeat`, ...).
fn requireCount(v: Value) VmError!usize {
    return @intCast(@max(try requireFixnum(v), 0));
}

/// `(nthrest coll n)` → coll without its first n elements, as a list.
fn fnNthrest(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[1]);
    var items = try collectSeq(vm, args[0]);
    defer items.deinit(vm.allocator);
    const skip = @min(n, items.items.len);
    return try buildListFromSlice(vm, items.items[skip..]);
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

/// `(take-last n coll)` / `(drop-last n coll)`.
fn fnTakeLast(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
    var items = try collectSeq(vm, args[1]);
    defer items.deinit(vm.allocator);
    const keep = @min(n, items.items.len);
    return try buildListFromSlice(vm, items.items[items.items.len - keep ..]);
}

fn fnDropLast(vm: *VM, args: []const Value) VmError!Value {
    const n = try requireCount(args[0]);
    var items = try collectSeq(vm, args[1]);
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
    if (!isSequential(v.kind())) return out.append(vm.allocator, v) catch VmError.OutOfMemory;
    var it = try makeSeqIter(vm, v);
    while (try it.next()) |x| try flattenInto(vm, x, out);
}

/// `(reductions f coll)` / `(reductions f init coll)` → every
/// intermediate accumulator of the fold.
fn fnReductions(vm: *VM, args: []const Value) VmError!Value {
    const f = args[0];
    var it = try makeSeqIter(vm, args[args.len - 1]);
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    var acc = if (args.len == 3) args[1] else (try it.next()) orelse return try buildListFromSlice(vm, &.{try vm.callValue(f, &.{})});
    results.append(vm.allocator, acc) catch return VmError.OutOfMemory;
    while (try it.next()) |x| {
        acc = try vm.callValue(f, &.{ acc, x });
        results.append(vm.allocator, acc) catch return VmError.OutOfMemory;
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

/// The list of `n` successive `producer.next(vm)` results.
fn repeatInto(vm: *VM, n: usize, producer: anytype) VmError!Value {
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.allocator);
    results.ensureTotalCapacity(vm.allocator, n) catch return VmError.OutOfMemory;
    for (0..n) |_| results.appendAssumeCapacity(try producer.next(vm));
    return try buildListFromSlice(vm, results.items);
}

/// `(max-key k x & xs)` / `(min-key k x & xs)` → the x with the
/// greatest / least `(k x)`; ties go to the later argument.
fn keyExtremum(vm: *VM, want_max: bool, args: []const Value) VmError!Value {
    const k = args[0];
    var best = args[1];
    var best_key = try vm.callValue(k, &.{best});
    for (args[2..]) |x| {
        const key = try vm.callValue(k, &.{x});
        const keep_best = try vm_mod.numCompare(if (want_max) .gt else .lt, best_key, key);
        if (!keep_best) {
            best = x;
            best_key = key;
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
        .nil, .persistent_map, .record, .persistent_vector => {},
        else => return VmError.KindMismatch,
    }
    var ks = try makeSeqIter(vm, args[1]);
    while (try ks.next()) |k| {
        const entry = try fnFind(vm, &.{ src, k });
        if (entry.isNil()) continue;
        out = champ_mod.mapAssoc(heap, out, k, vector_mod.nth(entry, 1), &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
    }
    return out;
}

/// `(find m k)` → the `[k v]` entry or nil.
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
        else => return VmError.KindMismatch,
    };
    return switch (champ_mod.mapGet(map_v, args[1], &dispatch_mod.hashValue, &dispatch_mod.equal)) {
        .present => |v| vector_mod.fromSlice(vm.ensureHeap(), &.{ args[1], v }) catch VmError.OutOfMemory,
        .absent => value_mod.nilValue(),
    };
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
        .persistent_vector => blk: {
            const n = vector_mod.count(c);
            if (n == 0) return VmError.IndexOutOfBounds;
            const items = vm.allocator.alloc(Value, n - 1) catch return VmError.OutOfMemory;
            defer vm.allocator.free(items);
            var i: usize = 0;
            while (i < n - 1) : (i += 1) items[i] = vector_mod.nth(c, i);
            break :blk vector_mod.fromSlice(vm.ensureHeap(), items) catch VmError.OutOfMemory;
        },
        else => VmError.KindMismatch,
    };
}

/// `(empty coll)` → an empty collection of the same kind; a
/// record, being a map, gives `{}`.
fn fnEmpty(vm: *VM, args: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    return switch (args[0].kind()) {
        .nil => value_mod.nilValue(),
        .list => list_mod.empty(heap) catch VmError.OutOfMemory,
        .persistent_vector => vector_mod.empty(heap) catch VmError.OutOfMemory,
        .persistent_map, .record => champ_mod.mapEmpty(heap) catch VmError.OutOfMemory,
        .persistent_set => champ_mod.setEmpty(heap) catch VmError.OutOfMemory,
        .string => string_mod.fromBytes(heap, "") catch VmError.OutOfMemory,
        else => VmError.KindMismatch,
    };
}

/// `(not-empty coll)` → coll, or nil when it has no elements.
fn fnNotEmpty(vm: *VM, args: []const Value) VmError!Value {
    const e = try fnEmptyQ(vm, args);
    return if (e.asBool()) value_mod.nilValue() else args[0];
}

// ---- ordering ----

/// Total order used by `compare` and `sort`: nil sorts first;
/// numbers order across the tower; strings, keywords and symbols
/// by bytes; chars by scalar; false before true; vectors by count
/// then elementwise. Comparing different kinds is a
/// `KindMismatch`.
fn compareValues(vm: *VM, a: Value, b: Value) VmError!std.math.Order {
    const ka = a.kind();
    const kb = b.kind();
    if (ka == .nil and kb == .nil) return .eq;
    if (ka == .nil) return .lt;
    if (kb == .nil) return .gt;
    if (vm_mod.isNumber(a) and vm_mod.isNumber(b)) {
        if (try vm_mod.numCompare(.lt, a, b)) return .lt;
        if (try vm_mod.numCompare(.gt, a, b)) return .gt;
        return .eq;
    }
    if (a.isBool() and b.isBool()) return std.math.order(@intFromBool(a.asBool()), @intFromBool(b.asBool()));
    if (ka != kb) return VmError.KindMismatch;
    return switch (ka) {
        .string => std.mem.order(u8, string_mod.asBytes(a), string_mod.asBytes(b)),
        .keyword => blk: {
            const it = vm.ensureInterner();
            break :blk std.mem.order(u8, it.keywordName(a.asKeywordId()), it.keywordName(b.asKeywordId()));
        },
        .symbol => blk: {
            const it = vm.ensureInterner();
            break :blk std.mem.order(u8, it.symbolName(a.asSymbolId()), it.symbolName(b.asSymbolId()));
        },
        .char => std.math.order(a.asChar(), b.asChar()),
        .persistent_vector => blk: {
            const na = vector_mod.count(a);
            const nb = vector_mod.count(b);
            if (na != nb) break :blk std.math.order(na, nb);
            var i: usize = 0;
            while (i < na) : (i += 1) {
                const o = try compareValues(vm, vector_mod.nth(a, i), vector_mod.nth(b, i));
                if (o != .eq) break :blk o;
            }
            break :blk .eq;
        },
        else => VmError.KindMismatch,
    };
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
            else => (try vm_mod.numSign(r)) == .lt,
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
    for (items.items, 0..) |v, i| {
        keyed[i] = .{ .key = if (keyfn) |kf| try vm.callValue(kf, &.{v}) else v, .val = v };
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
    if (args[0].kind() == .keyword) return args[0];
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
// Metadata (PLAN §8.5, SEMANTICS.md §7)
// =============================================================================
//
// A list, vector, map or set carries its metadata map in the heap
// header's `meta` slot; a Var carries it in `Var.meta`. Metadata
// never takes part in equality, hashing, printing or the codec.

fn carriesHeaderMeta(k: Kind) bool {
    return k == .list or k == .persistent_vector or k == .persistent_map or k == .persistent_set;
}

/// `(meta x)` → the metadata map of a list, vector, map, set or Var;
/// nil for anything else or when none is attached.
fn fnMeta(_: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    if (x.kind() == .var_) return VM.asVar(x).meta;
    if (!carriesHeaderMeta(x.kind())) return value_mod.nilValue();
    const m = heap_mod.Heap.asHeapHeader(x).getMeta() orelse return value_mod.nilValue();
    return champ_mod.valueFromMapHeader(m);
}

/// `(with-meta x m)` → a value equal to `x` carrying `m` (a map or
/// nil) as its metadata. The root object is copied, so `x` keeps its
/// own; the copy shares every node below the root. A kind that
/// cannot carry metadata is `:no-metadata-on-immediate`; a Var's
/// metadata changes in place through `reset-meta!` / `alter-meta!`.
fn fnWithMeta(vm: *VM, args: []const Value) VmError!Value {
    const x = args[0];
    const m = args[1];
    if (!m.isNil() and m.kind() != .persistent_map) return VmError.KindMismatch;
    if (!carriesHeaderMeta(x.kind())) return vm.throwKeyword("no-metadata-on-immediate");
    const h = heap_mod.Heap.asHeapHeader(x);
    const body = heap_mod.Heap.bodyBytes(h);
    const copy = vm.ensureHeap().alloc(x.kind(), body.len) catch return VmError.OutOfMemory;
    @memcpy(heap_mod.Heap.bodyBytes(copy), body);
    copy.kind = h.kind;
    copy.flags = h.flags & ~heap_mod.flag_has_meta;
    copy.setMeta(if (m.isNil()) null else heap_mod.Heap.asHeapHeader(m));
    return .{ .tag = x.tag, .payload = @intFromPtr(copy) };
}

/// `(reset-meta! v m)` → sets the Var's metadata to `m` (a map or
/// nil) and returns it.
fn fnResetMeta(_: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .var_) return VmError.KindMismatch;
    if (!args[1].isNil() and args[1].kind() != .persistent_map) return VmError.KindMismatch;
    VM.asVar(args[0]).meta = args[1];
    return args[1];
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
    v.meta = next;
    return next;
}

/// `(gensym)` / `(gensym prefix)` → a fresh symbol `prefix__N`
/// (`G__N` by default), N counting up for the process.
var gensym_next: u64 = 0;

fn fnGensym(vm: *VM, args: []const Value) VmError!Value {
    const prefix: []const u8 = if (args.len == 1) try internedName(vm, args[0]) else "G";
    gensym_next += 1;
    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}__{d}", .{ prefix, gensym_next }) catch return VmError.InvalidArgument;
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
    return k == .persistent_map or k == .record;
}
fn isSet(k: Kind) bool {
    return k == .persistent_set;
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
        .list, .persistent_vector, .persistent_map, .persistent_set, .record => true,
        else => false,
    };
}
fn isSequential(k: Kind) bool {
    return k == .list or k == .persistent_vector;
}
fn isAssociative(k: Kind) bool {
    return k == .persistent_map or k == .persistent_vector or k == .record;
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
//   :codec-failed        encode/decode error
//   :tx-closed           op on a finished transaction
//
// Storage failures are thrown through `VM.throwKeyword`, so outside
// any `try` they surface as `UncaughtThrow` with the keyword in
// `vm.unhandled_throw`, exactly like `(throw :db/key-too-large)`.
//
// Connection lifetime: each `db/open` allocates a Connection
// on the VM's main allocator (NOT the runtime arena) + appends
// it to vm.db_connections. `db/close` removes from the list +
// frees. VM.deinit closes any remaining as a safety net.

/// Throw a db.zig / emdb / codec error to the program as its
/// keyword (`db.failureName`).
fn dbFailure(vm: *VM, err: anyerror) VmError {
    if (err == error.OutOfMemory) return VmError.OutOfMemory;
    return vm.throwKeyword(db_mod.failureName(err));
}

fn fnDbOpen(vm: *VM, args: []const Value) VmError!Value {
    // `(db/open "/tmp/x.edb")` is the canonical form; a keyword
    // or symbol argument is accepted as well (its interned name
    // is the path).
    const path_v = args[0];
    const path_slice: []const u8 = blk: {
        if (path_v.kind() == .string) break :blk string_mod.asBytes(path_v);
        if (path_v.kind() == .keyword) {
            const id: u32 = @intCast(path_v.payload);
            break :blk vm.ensureInterner().keywordName(id);
        }
        if (path_v.kind() == .symbol) {
            const id: u32 = @intCast(path_v.payload);
            break :blk vm.ensureInterner().symbolName(id);
        }
        return VmError.KindMismatch;
    };
    // Heap-alloc the Connection on VM.allocator (NOT the arena).
    const conn = vm.allocator.create(db_mod.Connection) catch return VmError.OutOfMemory;
    errdefer vm.allocator.destroy(conn);
    const path_z = vm.allocator.dupeZ(u8, path_slice) catch return VmError.OutOfMemory;
    defer vm.allocator.free(path_z);

    // Auto-create the path's parent directories so
    // `(db/open "tmp/x.edb")` / `(db/open
    // "data/v1/state.edb")` Just Work. emdb does NOT create
    // parents; without this, the open fails with `:db/open-failed`
    // unless the user pre-created the directory.
    //
    // The auto-create branch only fires when the VM was given
    // a `std.Io` handle (the CLI sets one; ad-hoc test harnesses
    // don't, and tests use absolute `/tmp/...` paths or
    // pre-create their dirs explicitly). Best-effort: any error
    // here is swallowed — emdb's open will surface
    // `:db/open-failed` if the directory still isn't usable.
    if (vm.io) |io_handle| {
        if (std.fs.path.dirname(path_slice)) |dir| {
            if (dir.len > 0) {
                std.Io.Dir.cwd().createDirPath(io_handle, dir) catch {};
            }
        }
    }

    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    conn.* = db_mod.open(vm.allocator, heap, interner, path_z.ptr, .{}) catch |err| return dbFailure(vm, err);
    // Register on VM safety-net list.
    vm.db_close_callback = &dbCloseCallback;
    vm.db_connections.append(vm.allocator, @ptrCast(conn)) catch return VmError.OutOfMemory;
    return value_mod.Value{
        .tag = @intFromEnum(value_mod.Kind.db_connection),
        .payload = @intFromPtr(conn),
    };
}

/// Stand-alone closer used by VM.deinit safety net.
/// Closes the emdb env AND destroys the Connection struct. The
/// struct's own `allocator` field tells us how it was allocated.
fn dbCloseCallback(opaque_ptr: *anyopaque) void {
    const conn: *db_mod.Connection = @ptrCast(@alignCast(opaque_ptr));
    if (conn.open_flag) db_mod.close(conn);
    const allocator = conn.allocator;
    allocator.destroy(conn);
}

fn fnDbClose(vm: *VM, args: []const Value) VmError!Value {
    const v = args[0];
    if (v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(v.payload);
    // Remove from VM safety-net list.
    var i: usize = 0;
    while (i < vm.db_connections.items.len) : (i += 1) {
        if (vm.db_connections.items[i] == @as(*anyopaque, @ptrCast(conn))) {
            _ = vm.db_connections.swapRemove(i);
            break;
        }
    }
    db_mod.close(conn);
    vm.allocator.destroy(conn);
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
    const tree_id: u32 = @intCast(tree_v.payload);
    const tree_name = interner.keywordName(tree_id);
    const key_bytes: []const u8 = switch (key_v.kind()) {
        .keyword => interner.keywordName(@intCast(key_v.payload)),
        .symbol => interner.symbolName(@intCast(key_v.payload)),
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
    var txn = db_mod.beginWrite(conn) catch |err| return dbFailure(vm, err);
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
    var txn = db_mod.beginRead(conn) catch |err| return dbFailure(vm, err);
    defer db_mod.abortRead(&txn);
    const result = db_mod.getRef(&txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
    return result orelse default;
}

fn fnDbDeleteKey(vm: *VM, args: []const Value) VmError!Value {
    const r = args[0];
    const conn = try liveConnOf(vm, r);
    var txn = db_mod.beginWrite(conn) catch |err| return dbFailure(vm, err);
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
    var txn = db_mod.beginRead(conn) catch |err| return dbFailure(vm, err);
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
// Single-owner enforcement: each TxnHandle struct carries an
// `active` flag. commit/abort sets it to false; subsequent ops
// detect this and raise `:tx-closed`. Prevents double-commit and
// use-after-finalize.
//
// Lifetime: TxnHandle structs live on `vm.runtime_arena` (small
// allocations, short-lived; arena reclaims at VM teardown). The
// underlying emdb txn handle is freed by commit/abort.
//
// Connection mismatch: `db/put!` etc. validate that the supplied
// ref belongs to the same connection the tx is open against.
// db.zig's putRef/getRef/delRef do this via `assertRefMatchesConn`.

pub const WriteTxnHandle = struct {
    txn: db_mod.WriteTxn,
    active: bool,
};

pub const ReadTxnHandle = struct {
    txn: db_mod.ReadTxn,
    active: bool,
};

fn writeTxnHandle(v: Value) ?*WriteTxnHandle {
    if (v.kind() != .db_write_txn) return null;
    return @ptrFromInt(v.payload);
}

fn readTxnHandle(v: Value) ?*ReadTxnHandle {
    if (v.kind() != .db_read_txn) return null;
    return @ptrFromInt(v.payload);
}

/// A transaction Value of either kind that is still open.
const ActiveTxn = union(enum) {
    write: *WriteTxnHandle,
    read: *ReadTxnHandle,
};

fn activeTxn(v: Value) VmError!ActiveTxn {
    switch (v.kind()) {
        .db_write_txn => {
            const h = writeTxnHandle(v).?;
            if (!h.active) return VmError.TxClosed;
            return .{ .write = h };
        },
        .db_read_txn => {
            const h = readTxnHandle(v).?;
            if (!h.active) return VmError.TxClosed;
            return .{ .read = h };
        },
        else => return VmError.KindMismatch,
    }
}

fn fnDbBeginWrite(vm: *VM, args: []const Value) VmError!Value {
    const conn_v = args[0];
    if (conn_v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(conn_v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    const handle = vm.runtime_arena.allocator().create(WriteTxnHandle) catch return VmError.OutOfMemory;
    handle.* = .{
        .txn = db_mod.beginWrite(conn) catch |err| return dbFailure(vm, err),
        .active = true,
    };
    return value_mod.Value{
        .tag = @intFromEnum(value_mod.Kind.db_write_txn),
        .payload = @intFromPtr(handle),
    };
}

fn fnDbBeginRead(vm: *VM, args: []const Value) VmError!Value {
    const conn_v = args[0];
    if (conn_v.kind() != .db_connection) return VmError.KindMismatch;
    const conn: *db_mod.Connection = @ptrFromInt(conn_v.payload);
    if (!conn.open_flag) return VmError.DbClosed;
    const handle = vm.runtime_arena.allocator().create(ReadTxnHandle) catch return VmError.OutOfMemory;
    handle.* = .{
        .txn = db_mod.beginRead(conn) catch |err| return dbFailure(vm, err),
        .active = true,
    };
    return value_mod.Value{
        .tag = @intFromEnum(value_mod.Kind.db_read_txn),
        .payload = @intFromPtr(handle),
    };
}

fn fnDbCommit(vm: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    db_mod.commit(&h.txn) catch |err| {
        h.active = false;
        return dbFailure(vm, err);
    };
    h.active = false;
    return value_mod.nilValue();
}

fn fnDbAbortWrite(_: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return value_mod.nilValue(); // idempotent abort
    db_mod.abortWrite(&h.txn);
    h.active = false;
    return value_mod.nilValue();
}

fn fnDbAbortRead(_: *VM, args: []const Value) VmError!Value {
    const h = readTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return value_mod.nilValue();
    db_mod.abortRead(&h.txn);
    h.active = false;
    return value_mod.nilValue();
}

/// `(db/put! tx ref value)` — write through an active tx.
fn fnDbPut(vm: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    const r = args[1];
    const v = args[2];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    db_mod.putRef(&h.txn, r, v) catch |err| return dbFailure(vm, err);
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
    const result: ?Value = switch (try activeTxn(tx_v)) {
        inline else => |h| db_mod.getRef(&h.txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err),
    };
    return result orelse default;
}

fn fnDbDelete(vm: *VM, args: []const Value) VmError!Value {
    const h = writeTxnHandle(args[0]) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    const r = args[1];
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;
    const existed = db_mod.delRef(&h.txn, r) catch |err| return dbFailure(vm, err);
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
            var txn = db_mod.beginRead(conn) catch |err| return dbFailure(vm, err);
            defer db_mod.abortRead(&txn);
            const result = db_mod.getRef(&txn, x, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
            break :blk result orelse value_mod.nilValue();
        },
        .var_ => blk: {
            const var_obj = vm_mod.VM.asVar(x);
            if (!var_obj.bound) return VmError.UnboundVar;
            break :blk var_obj.root;
        },
        .atom => atom_mod.getValue(x),
        else => VmError.NotDerefable,
    };
}

/// `(db/alter! tx ref f & args)` — read-modify-write inside an
/// active write tx. Reads current via getRef, computes
/// `(apply f current args)` via vm.callValue, writes via putRef.
/// Returns the new value.
///
/// If `f` throws or control transfers, do NOT write.
/// Connection mismatch on `ref` surfaces as
/// :db/store-mismatch via db.zig's assertRefMatchesConn.
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

/// A cursor over one named tree inside an active transaction.
const TreeCursor = struct {
    conn: *db_mod.Connection,
    inner: *emdb_mod.Txn,
    tree_id: emdb_mod.TreeId,
    cursor: emdb_mod.Cursor,
    /// See `db.cursorPageBytes`.
    page_bytes: u32,

    /// Open a cursor on `tree_name`. Null when the tree does not
    /// exist, which every caller treats as an empty tree.
    fn open(vm: *VM, tx_v: Value, tree_name: []const u8) VmError!?TreeCursor {
        const Resolved = struct { conn: *db_mod.Connection, inner: *emdb_mod.Txn, tree_id: ?emdb_mod.TreeId };
        const r: Resolved = switch (try activeTxn(tx_v)) {
            inline else => |h| .{
                .conn = h.txn.conn,
                .inner = h.txn.inner,
                .tree_id = db_mod.treeId(&h.txn, tree_name, false) catch |err| return dbFailure(vm, err),
            },
        };
        const tree_id = r.tree_id orelse return null;
        const cursor = r.inner.openCursorForTree(tree_id) catch |err| return dbFailure(vm, err);
        return .{
            .conn = r.conn,
            .inner = r.inner,
            .tree_id = tree_id,
            .cursor = cursor,
            .page_bytes = db_mod.cursorPageBytes(r.conn),
        };
    }

    /// The complete value of `kv`, decoded onto the heap. Values
    /// that continue past the cursor's first page are re-read
    /// through the tree (`db.cursorValue`).
    fn decode(self: *TreeCursor, vm: *VM, kv: emdb_mod.Cursor.KeyValue) VmError!Value {
        const bytes = db_mod.cursorValue(self, self.tree_id, kv, self.page_bytes) catch |err| return dbFailure(vm, err);
        return codec_mod.decode(
            vm.ensureHeap(),
            vm.ensureInterner(),
            bytes,
            &dispatch_mod_alias.hashValue,
            &dispatch_mod_alias.equal,
        ) catch |err| return dbFailure(vm, err);
    }
};

fn fnDbScan(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const tree_v = args[1];
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    const interner = vm.ensureInterner();
    const tree_id: u32 = @intCast(tree_v.payload);
    const tree_name = interner.keywordName(tree_id);

    // Optional range bounds. Keys are keyword Values; extract
    // their interned names as byte slices.
    const start_bytes: ?[]const u8 = if (args.len >= 3) blk: {
        const sv = args[2];
        if (sv.kind() != .keyword and sv.kind() != .symbol) return VmError.KindMismatch;
        const id: u32 = @intCast(sv.payload);
        break :blk if (sv.kind() == .keyword) interner.keywordName(id) else interner.symbolName(id);
    } else null;
    const end_bytes: ?[]const u8 = if (args.len >= 4) blk: {
        const ev = args[3];
        if (ev.kind() != .keyword and ev.kind() != .symbol) return VmError.KindMismatch;
        const id: u32 = @intCast(ev.payload);
        break :blk if (ev.kind() == .keyword) interner.keywordName(id) else interner.symbolName(id);
    } else null;

    var tc = (try TreeCursor.open(vm, tx_v, tree_name)) orelse {
        return vector_mod.fromSlice(vm.ensureHeap(), &.{}) catch VmError.OutOfMemory;
    };

    var entries: std.ArrayList(Value) = .empty;
    defer entries.deinit(vm.allocator);

    // Seek to the first key >= start (or the first key).
    var maybe_kv: ?emdb_mod.Cursor.KeyValue = if (start_bytes) |sb| tc.cursor.setRange(sb) else tc.cursor.first();

    while (maybe_kv) |kv| {
        // End-exclusive check.
        if (end_bytes) |eb| {
            if (std.mem.order(u8, kv.key, eb) != .lt) break;
        }
        // Decode value (Heap-owned) and intern key (interner-owned).
        // Both are stable past the next cursor advance.
        const decoded_v = try tc.decode(vm, kv);
        const key_id = interner.internKeyword(kv.key) catch return VmError.OutOfMemory;
        const key_v = value_mod.fromKeywordId(key_id);
        // Build [key value] 2-vector.
        const pair = [_]Value{ key_v, decoded_v };
        const pair_vec = vector_mod.fromSlice(vm.ensureHeap(), &pair) catch return VmError.OutOfMemory;
        entries.append(vm.allocator, pair_vec) catch return VmError.OutOfMemory;
        maybe_kv = tc.cursor.next();
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

fn fnDbReduceTree(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const tree_v = args[1];
    const f = args[2];
    var acc = args[3];
    if (tree_v.kind() != .keyword) return VmError.KindMismatch;
    const interner = vm.ensureInterner();
    const tree_id: u32 = @intCast(tree_v.payload);
    const tree_name = interner.keywordName(tree_id);

    // No such tree: the init value, unchanged.
    var tc = (try TreeCursor.open(vm, tx_v, tree_name)) orelse return acc;

    var maybe_kv: ?emdb_mod.Cursor.KeyValue = tc.cursor.first();
    while (maybe_kv) |kv| {
        const decoded_v = try tc.decode(vm, kv);
        const key_id = interner.internKeyword(kv.key) catch return VmError.OutOfMemory;
        const key_v = value_mod.fromKeywordId(key_id);
        // (f acc key value)
        const call_args = [_]Value{ acc, key_v, decoded_v };
        acc = try vm.callValue(f, &call_args);
        maybe_kv = tc.cursor.next();
    }
    return acc;
}

fn fnDbAlter(vm: *VM, args: []const Value) VmError!Value {
    const tx_v = args[0];
    const r = args[1];
    const f = args[2];
    const extra = args[3..];

    const h = writeTxnHandle(tx_v) orelse return VmError.KindMismatch;
    if (!h.active) return VmError.TxClosed;
    if (r.kind() != .durable_ref) return VmError.InvalidDurableRef;

    // 1. Read current.
    const current_opt = db_mod.getRef(&h.txn, r, &dispatch_mod_alias.hashValue, &dispatch_mod_alias.equal) catch |err| return dbFailure(vm, err);
    const current = current_opt orelse value_mod.nilValue();

    // 2. Build (f current extra...) arg list. f is the FIRST
    //    arg to callValue; current + extra follow.
    const call_args = vm.allocator.alloc(Value, 1 + extra.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = current;
    for (extra, 0..) |a, i| call_args[1 + i] = a;

    // 3. Invoke. Throws / control transfers propagate UNCHANGED
    //    so the with-tx's catch can abort. NO write on error.
    const new_value = try vm.callValue(f, call_args);

    // 4. Write.
    db_mod.putRef(&h.txn, r, new_value) catch |err| return dbFailure(vm, err);
    return new_value;
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

fn fnSwapBang(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    const f = args[1];
    const extra = args[2..];

    if (a.kind() != .atom) return VmError.KindMismatch;
    if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
    defer atom_mod.exitCritical(a);

    // 1. Read current.
    const old = atom_mod.getValue(a);

    // 2. Build call_args = [old, ...extra].
    const call_args = vm.allocator.alloc(Value, 1 + extra.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = old;
    for (extra, 0..) |x, i| call_args[1 + i] = x;

    // 3. Invoke. NO write on throw / control transfer.
    const new_val = try vm.callValue(f, call_args);

    // 4. Write.
    atom_mod.setValue(a, new_val);
    return new_val;
}

fn fnSwapValsBang(vm: *VM, args: []const Value) VmError!Value {
    const a = args[0];
    const f = args[1];
    const extra = args[2..];

    if (a.kind() != .atom) return VmError.KindMismatch;
    if (!atom_mod.tryEnterCritical(a)) return VmError.AtomReEntry;
    defer atom_mod.exitCritical(a);

    const old = atom_mod.getValue(a);

    const call_args = vm.allocator.alloc(Value, 1 + extra.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(call_args);
    call_args[0] = old;
    for (extra, 0..) |x, i| call_args[1 + i] = x;

    const new_val = try vm.callValue(f, call_args);

    // GC rooting note: the [old new] vector is built AFTER
    // `setValue`. The collector is explicit-only (docs/GC.md §9),
    // so `vector_mod.fromTwo`'s alloc cannot trigger collection
    // and `old` (a Zig local) stays alive trivially. This site is
    // listed in the docs/GC.md §11.5 audit checklist.
    atom_mod.setValue(a, new_val);
    const pair_elems = [_]Value{ old, new_val };
    return vector_mod.fromSlice(vm.ensureHeap(), &pair_elems) catch return VmError.OutOfMemory;
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
// GC rooting note: str / pr-str allocate the final heap string
// AFTER walking the args slice. The args slice is held by
// `vm.invokeNative` for the duration of the call, so input
// values stay reachable. Listed in the `docs/GC.md` §11.5 audit
// checklist.

/// Append a single Value to `out` in `str`-semantics (display mode
/// with `nil → empty` override). Used by `str`, `join`, and `spit`.
/// `print`/`println`/`prn` do NOT go through this — they print
/// `nil` as the literal `"nil"`.
fn appendStrValue(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer.Allocating,
    v: Value,
    interner: ?*const intern_mod.Interner,
) VmError!void {
    _ = allocator;
    if (v.kind() == .nil) return; // str/join/spit: nil → "".
    // `format_mod.Error = std.Io.Writer.Error || error{Utf8Error}` —
    // WriteFailed bubbles up from the Allocating writer's drain
    // when the backing allocator fails, so map it to OutOfMemory
    // (the closest catchable taxonomy entry the VM has).
    format_mod.format(v, .display, &w.writer, interner) catch |err| switch (err) {
        error.Utf8Error => return VmError.Utf8Error,
        error.WriteFailed => return VmError.OutOfMemory,
    };
}

fn fnStr(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    for (args) |x| {
        try appendStrValue(vm.allocator, &w, x, interner);
    }
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
// ASCII-only case conversion + trim; literal-string split / replace;
// join over nil/list/vector/set. All six fns are byte-preserving for
// non-ASCII content (case conversion bypasses bytes ≥ 0x80; trim
// recognizes only six ASCII whitespace chars; split/replace search
// via `std.mem.indexOf` which is byte-exact, safe for valid UTF-8
// because continuation bytes can never equal ASCII delimiter bytes
// and multi-byte delimiters align only at codepoint boundaries).
//
// Errors are catchable keywords:
//   :kind-mismatch          non-string s/sep/match, empty delim/match,
//                           non-collection arg to join, etc.
//   :arity-mismatch         enforced by NativeFn descriptor
//
// GC rooting: each fn allocates output via string.fromBytes /
// vector.fromSlice AFTER holding inputs in Zig locals. The
// collector is explicit-only, so this is structurally safe;
// documented in docs/GC.md §11.5.

fn fnStringLowerCase(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    if (s.kind() != .string) return VmError.KindMismatch;
    const src = string_mod.asBytes(s);
    const buf = vm.allocator.alloc(u8, src.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(buf);
    for (src, 0..) |b, i| {
        buf[i] = if (b >= 'A' and b <= 'Z') b + ('a' - 'A') else b;
    }
    return string_mod.fromBytes(vm.ensureHeap(), buf) catch return VmError.OutOfMemory;
}

fn fnStringUpperCase(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    if (s.kind() != .string) return VmError.KindMismatch;
    const src = string_mod.asBytes(s);
    const buf = vm.allocator.alloc(u8, src.len) catch return VmError.OutOfMemory;
    defer vm.allocator.free(buf);
    for (src, 0..) |b, i| {
        buf[i] = if (b >= 'a' and b <= 'z') b - ('a' - 'A') else b;
    }
    return string_mod.fromBytes(vm.ensureHeap(), buf) catch return VmError.OutOfMemory;
}

/// `std.ascii.isWhitespace` recognizes the six ASCII whitespace
/// characters: space, tab, LF, VT, FF, CR. Inlined
/// rather than calling so the fn is testable without Zig stdlib
/// internals.
inline fn isAsciiSpace(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\n' or b == 0x0B or b == 0x0C or b == '\r';
}

fn fnStringTrim(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    if (s.kind() != .string) return VmError.KindMismatch;
    const src = string_mod.asBytes(s);
    var lo: usize = 0;
    var hi: usize = src.len;
    while (lo < hi and isAsciiSpace(src[lo])) lo += 1;
    while (hi > lo and isAsciiSpace(src[hi - 1])) hi -= 1;
    return string_mod.fromBytes(vm.ensureHeap(), src[lo..hi]) catch return VmError.OutOfMemory;
}

/// `(nexis.string/split s delim)` — literal split, preserves
/// trailing empties (unlike Clojure's regex trimming). Returns
/// a vector.
///   - Empty delimiter → :invalid-argument
///   - Invalid UTF-8 in either arg → :utf8-error
fn fnStringSplit(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    const delim = args[1];
    if (s.kind() != .string or delim.kind() != .string) return VmError.KindMismatch;
    const src = string_mod.asBytes(s);
    const sep = string_mod.asBytes(delim);
    if (sep.len == 0) return VmError.InvalidArgument;
    // Validate both arguments as UTF-8 before scanning. Storage
    // is byte-blob
    // (STRING.md §2 invariant 4); without validation a delimiter
    // like a lone 0xC3 byte could match the first byte of a
    // multibyte codepoint and split mid-character, producing
    // invalid UTF-8 output from valid-looking inputs. Validation
    // is O(n) and the input is already byte-walked anyway.
    if (!std.unicode.utf8ValidateSlice(src)) return VmError.Utf8Error;
    if (!std.unicode.utf8ValidateSlice(sep)) return VmError.Utf8Error;

    var fragments: std.ArrayList(Value) = .empty;
    defer fragments.deinit(vm.allocator);
    const heap = vm.ensureHeap();

    var cursor: usize = 0;
    while (cursor <= src.len) {
        // `std.mem.indexOf(u8, haystack[cursor..], sep)` returns an
        // offset relative to the suffix; remap to an absolute index.
        const rel = std.mem.indexOf(u8, src[cursor..], sep);
        if (rel) |r| {
            const abs = cursor + r;
            const frag = string_mod.fromBytes(heap, src[cursor..abs]) catch return VmError.OutOfMemory;
            fragments.append(vm.allocator, frag) catch return VmError.OutOfMemory;
            cursor = abs + sep.len;
        } else {
            const frag = string_mod.fromBytes(heap, src[cursor..]) catch return VmError.OutOfMemory;
            fragments.append(vm.allocator, frag) catch return VmError.OutOfMemory;
            break;
        }
    }
    return vector_mod.fromSlice(heap, fragments.items) catch return VmError.OutOfMemory;
}

/// `(nexis.string/join coll)` / `(nexis.string/join sep coll)` —
/// concatenate stringified elements, optionally separated.
/// Elements stringify via `appendStrValue` (str-semantics:
/// nil → "") so `(join [1 nil 2]) → "12"` and
/// `(join "," [1 nil 2]) → "1,,2"`. Maps are rejected: CHAMP
/// iteration order isn't pinned.
fn fnStringJoin(vm: *VM, args: []const Value) VmError!Value {
    const sep_bytes: []const u8 = if (args.len == 2) blk: {
        if (args[0].kind() != .string) return VmError.KindMismatch;
        break :blk string_mod.asBytes(args[0]);
    } else &.{};
    const coll = if (args.len == 2) args[1] else args[0];

    // Validate the collection kind up front (the kind check
    // fires before any other branch).
    switch (coll.kind()) {
        .nil, .list, .persistent_vector, .persistent_set => {},
        else => return VmError.KindMismatch,
    }

    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    var first = true;

    const appendSep = struct {
        fn go(ww: *std.Io.Writer.Allocating, sep: []const u8, firstp: *bool) VmError!void {
            if (!firstp.*) {
                // Allocating writer; WriteFailed = allocator-fail.
                ww.writer.writeAll(sep) catch return VmError.OutOfMemory;
            }
            firstp.* = false;
        }
    }.go;

    switch (coll.kind()) {
        .nil => {},
        .list => {
            var node = coll;
            while (node.kind() == .list and !list_mod.isEmpty(node)) {
                try appendSep(&w, sep_bytes, &first);
                try appendStrValue(vm.allocator, &w, list_mod.head(node), interner);
                node = list_mod.tail(node);
            }
        },
        .persistent_vector => {
            const n = vector_mod.count(coll);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                try appendSep(&w, sep_bytes, &first);
                try appendStrValue(vm.allocator, &w, vector_mod.nth(coll, i), interner);
            }
        },
        .persistent_set => {
            var it = champ_mod.setIter(coll);
            while (it.next()) |elem| {
                try appendSep(&w, sep_bytes, &first);
                try appendStrValue(vm.allocator, &w, elem, interner);
            }
        },
        else => unreachable,
    }

    return string_mod.fromBytes(vm.ensureHeap(), w.written()) catch return VmError.OutOfMemory;
}

/// `(nexis.string/replace s match replacement)` — literal,
/// all-non-overlapping, left-to-right.
///   - Empty `match` → :invalid-argument
///   - Invalid UTF-8 in any arg → :utf8-error
/// After each match, cursor advances by `match.len` so
/// `(replace "aaa" "aa" "x") → "xa"`.
fn fnStringReplace(vm: *VM, args: []const Value) VmError!Value {
    const s = args[0];
    const match = args[1];
    const replacement = args[2];
    if (s.kind() != .string or match.kind() != .string or replacement.kind() != .string) {
        return VmError.KindMismatch;
    }
    const src = string_mod.asBytes(s);
    const m = string_mod.asBytes(match);
    const r = string_mod.asBytes(replacement);
    if (m.len == 0) return VmError.InvalidArgument;
    // Validate all three byte slices as UTF-8 before scanning.
    // Same rationale
    // as fnStringSplit — keep `nexis.string/*` semantically a
    // Unicode-string operation rather than a raw-byte one.
    if (!std.unicode.utf8ValidateSlice(src)) return VmError.Utf8Error;
    if (!std.unicode.utf8ValidateSlice(m)) return VmError.Utf8Error;
    if (!std.unicode.utf8ValidateSlice(r)) return VmError.Utf8Error;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(vm.allocator);

    var cursor: usize = 0;
    while (cursor < src.len) {
        const rel = std.mem.indexOf(u8, src[cursor..], m);
        if (rel) |off| {
            const abs = cursor + off;
            buf.appendSlice(vm.allocator, src[cursor..abs]) catch return VmError.OutOfMemory;
            buf.appendSlice(vm.allocator, r) catch return VmError.OutOfMemory;
            cursor = abs + m.len;
        } else {
            buf.appendSlice(vm.allocator, src[cursor..]) catch return VmError.OutOfMemory;
            cursor = src.len;
        }
    }
    return string_mod.fromBytes(vm.ensureHeap(), buf.items) catch return VmError.OutOfMemory;
}

// =============================================================================
// Printing + I/O
// =============================================================================
//
// `print` / `println` / `prn` write to the VM's stdout (via
// `vm.io`); `pr-str` returns a String; `slurp` / `spit` read or
// write UTF-8 files via `vm.io`. All six fns require `vm.io != null`;
// ad-hoc test harnesses (which don't run user-source I/O paths)
// leave `vm.io` null and these fns surface `:io-error` cleanly.
// CLI bootstrap (`runFile` / `runRepl`) sets `vm.io = init.io`.
//
// Nil semantics:
//   - `print` / `println` / `prn`  treat `nil` arg as the literal
//     `"nil"` because they use `format(.display, ...)` directly.
//   - `pr-str` similarly. (Readable mode also writes `"nil"`.)
//   - `spit` uses str-semantics so `(spit path nil) → ""`.
//
// Each fn writes through format_mod, which lives in `src/format.zig`.
// Print fns separate args with a single space (Clojure parity);
// `println` and `prn` append a trailing newline.

/// Append a single Value to an Allocating buffer with optional
/// leading separator. The writer is an Allocating buffer;
/// WriteFailed from it means the backing
/// allocator failed → OutOfMemory (not IoError). Print fns that
/// drain to stdout later map THAT failure to IoError separately.
fn writeOneAndSep(
    w: *std.Io.Writer.Allocating,
    v: Value,
    mode: format_mod.FormatMode,
    first: *bool,
    interner: *const intern_mod.Interner,
) VmError!void {
    if (!first.*) {
        w.writer.writeAll(" ") catch return VmError.OutOfMemory;
    }
    first.* = false;
    format_mod.format(v, mode, &w.writer, interner) catch |err| switch (err) {
        error.Utf8Error => return VmError.Utf8Error,
        // Allocating-writer drain → allocator failure.
        error.WriteFailed => return VmError.OutOfMemory,
    };
}

fn writeBufferedToStdout(vm: *VM, bytes: []const u8) VmError!void {
    const io_handle = vm.io orelse return VmError.IoError;
    std.Io.File.stdout().writeStreamingAll(io_handle, bytes) catch return VmError.IoError;
}

fn fnPrint(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    var first = true;
    for (args) |x| try writeOneAndSep(&w, x, .display, &first, interner);
    try writeBufferedToStdout(vm, w.written());
    return value_mod.nilValue();
}

fn fnPrintln(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    var first = true;
    for (args) |x| try writeOneAndSep(&w, x, .display, &first, interner);
    // The trailing newline goes into the SAME Allocating buffer,
    // so a WriteFailed here is allocator-fail, not I/O. Map to
    // OOM. Real stdout-write failure surfaces from
    // writeBufferedToStdout below as :io-error.
    w.writer.writeAll("\n") catch return VmError.OutOfMemory;
    try writeBufferedToStdout(vm, w.written());
    return value_mod.nilValue();
}

fn fnPrn(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    var first = true;
    for (args) |x| try writeOneAndSep(&w, x, .readable, &first, interner);
    w.writer.writeAll("\n") catch return VmError.OutOfMemory;
    try writeBufferedToStdout(vm, w.written());
    return value_mod.nilValue();
}

fn fnPrStr(vm: *VM, args: []const Value) VmError!Value {
    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    const interner = vm.ensureInterner();
    var first = true;
    for (args) |x| try writeOneAndSep(&w, x, .readable, &first, interner);
    return string_mod.fromBytes(vm.ensureHeap(), w.written()) catch return VmError.OutOfMemory;
}

/// `(slurp path)` — read a UTF-8 text file into a String.
/// 16 MiB cap (matches `cli.zig`'s file-source reader).
/// Errors: `:invalid-path` for non-string path or empty path;
/// `:file-not-found` for a missing target; `:utf8-error` for
/// malformed file content (validation happens after read);
/// `:io-error` for anything else (permissions, too-large, etc.).
fn fnSlurp(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const path = string_mod.asBytes(args[0]);
    if (path.len == 0) return VmError.InvalidPath;
    for (path) |b| if (b == 0) return VmError.InvalidPath;
    const io_handle = vm.io orelse return VmError.IoError;
    const slice = std.Io.Dir.cwd().readFileAlloc(
        io_handle,
        path,
        vm.allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| switch (err) {
        error.FileNotFound => return VmError.FileNotFound,
        else => return VmError.IoError,
    };
    defer vm.allocator.free(slice);
    if (!std.unicode.utf8ValidateSlice(slice)) return VmError.Utf8Error;
    return string_mod.fromBytes(vm.ensureHeap(), slice) catch return VmError.OutOfMemory;
}

/// `(spit path content)` — write `(str content)` to a file.
/// `spit` does NOT auto-create parent
/// directories (unlike `db/open`); missing parents surface as
/// `:file-not-found` / `:io-error`. Content stringifies via the
/// str-semantics wrapper (nil → empty).
fn fnSpit(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .string) return VmError.KindMismatch;
    const path = string_mod.asBytes(args[0]);
    if (path.len == 0) return VmError.InvalidPath;
    for (path) |b| if (b == 0) return VmError.InvalidPath;
    const io_handle = vm.io orelse return VmError.IoError;

    var w = std.Io.Writer.Allocating.init(vm.allocator);
    defer w.deinit();
    try appendStrValue(vm.allocator, &w, args[1], vm.ensureInterner());

    std.Io.Dir.cwd().writeFile(io_handle, .{
        .sub_path = path,
        .data = w.written(),
    }) catch |err| switch (err) {
        error.FileNotFound => return VmError.FileNotFound,
        else => return VmError.IoError,
    };
    return value_mod.nilValue();
}

// =============================================================================
// Record internals (PROTOCOLS.md §4)
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
/// `vm.registerRecordType`. Re-defining a record type with the
/// same (ns, name) raises `:record-redefinition` (avoids the
/// stale type_id hazard).
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
        const id: u32 = @intCast(f.payload);
        field_names[i] = interner.keywordName(id);
    }

    const new_id = vm.registerRecordType(ns_name, type_name, field_names) catch |err| switch (err) {
        error.RecordRedefinition => return VmError.RecordRedefinition,
        error.OutOfMemory => return VmError.OutOfMemory,
    };
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
// Protocol internals (PROTOCOLS.md §4.1)
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
        const id: u32 = @intCast(m.payload);
        specs[i] = .{ .name_id = id, .name = interner.keywordName(id) };
    }

    const new_id = vm.registerProtocol(ns_name, proto_name, specs) catch |err| switch (err) {
        error.ProtocolRedefinition => return VmError.ProtocolRedefinition,
        error.OutOfMemory => return VmError.OutOfMemory,
    };
    return protocol_mod.makeProtocol(vm.ensureHeap(), new_id) catch return VmError.OutOfMemory;
}

fn fnProtocolFn(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    if (args[1].kind() != .keyword) return VmError.KindMismatch;
    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = @intCast(args[1].payload);

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
    const method_name_id: u32 = @intCast(args[1].payload);
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
// qualified calls to these helpers. Type-tag keywords match
// the `Kind` enum's tag names:
//
//   :nil :bool :char :fixnum :bignum :rational :keyword :symbol
//   :string :list :persistent_vector :persistent_map :persistent_set
//   :transient_vector :transient_map :transient_set :function
//   :native_fn :db_connection :db_write_txn :db_read_txn :atom
//   :record :protocol :protocol_fn :var :durable_ref :error_object
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
    const method_name_id: u32 = @intCast(args[1].payload);

    const interner = vm.ensureInterner();
    const type_id_kw: u32 = @intCast(args[2].payload);
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
    if (items.items.len == 1 and (items.items[0].kind() == .persistent_map or items.items[0].kind() == .record)) return items.items[0];
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
    const error_key = vm.ensureInterner().internKeywordValue("error") catch return VmError.OutOfMemory;
    return value_mod.fromBool(dispatch_mod_alias.equal(try vm_mod.lookup(v, error_key, value_mod.nilValue()), tag));
}

fn fnExtendDefaultImpl(vm: *VM, args: []const Value) VmError!Value {
    if (args[0].kind() != .protocol) return VmError.KindMismatch;
    if (args[1].kind() != .keyword) return VmError.KindMismatch;

    const protocol_id = protocol_mod.protocolId(args[0]);
    const method_name_id: u32 = @intCast(args[1].payload);
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
const SeqIter = union(enum) {
    empty,
    list: Value,
    vector: struct { v: Value, idx: usize, count: usize },
    map: struct { it: champ_mod.MapIter, heap: *heap_mod.Heap },
    set: champ_mod.SetIter,
    string: std.unicode.Utf8Iterator,

    fn next(self: *SeqIter) VmError!?Value {
        switch (self.*) {
            .empty => return null,
            .list => |*node| {
                if (list_mod.isEmpty(node.*)) return null;
                const h = list_mod.head(node.*);
                node.* = list_mod.tail(node.*);
                return h;
            },
            .vector => |*vec| {
                if (vec.idx >= vec.count) return null;
                const e = vector_mod.nth(vec.v, vec.idx);
                vec.idx += 1;
                return e;
            },
            .map => |*m| {
                const e = m.it.next() orelse return null;
                return vector_mod.fromSlice(m.heap, &.{ e.key, e.value }) catch VmError.OutOfMemory;
            },
            .set => |*it| return it.next(),
            .string => |*utf8| {
                const scalar = utf8.nextCodepoint() orelse return null;
                return value_mod.fromChar(scalar) orelse VmError.Utf8Error;
            },
        }
    }
};

/// Every seqable receiver: nil, list, vector, map (as `[k v]`
/// entries), record (its field map), set and string (as chars). A
/// string that is not valid UTF-8 is `:utf8-error`, as for every
/// other string operation.
fn makeSeqIter(vm: *VM, coll: Value) VmError!SeqIter {
    return switch (coll.kind()) {
        .nil => .empty,
        .list => .{ .list = coll },
        .persistent_vector => .{ .vector = .{ .v = coll, .idx = 0, .count = vector_mod.count(coll) } },
        .persistent_map => .{ .map = .{ .it = champ_mod.mapIter(coll), .heap = vm.ensureHeap() } },
        .record => .{ .map = .{ .it = champ_mod.mapIter(record_mod.fieldsOf(coll)), .heap = vm.ensureHeap() } },
        .persistent_set => .{ .set = champ_mod.setIter(coll) },
        .string => .{
            .string = (std.unicode.Utf8View.init(string_mod.asBytes(coll)) catch return VmError.Utf8Error).iterator(),
        },
        else => VmError.KindMismatch,
    };
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

/// Build a fresh cons list from a slice of Values (left-to-
/// right). Uses `vm.ensureHeap()`. Results aren't rooted
/// between cons calls; `Heap.alloc` never collects (GC.md §9).
fn buildListFromSlice(vm: *VM, items: []const Value) VmError!Value {
    const heap = vm.ensureHeap();
    var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
    var i: usize = items.len;
    while (i > 0) {
        i -= 1;
        result = list_mod.cons(heap, items[i], result) catch return VmError.OutOfMemory;
    }
    return result;
}

/// Convert a Value into a list for cons. nil → empty list;
/// list passes through unchanged; vector becomes a fresh list
/// of its elements. Other kinds → KindMismatch.
fn coerceToList(vm: *VM, v: Value) VmError!Value {
    return switch (v.kind()) {
        .nil => list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory,
        .list => v,
        .persistent_vector => blk: {
            const heap = vm.ensureHeap();
            const n = vector_mod.count(v);
            var result = list_mod.empty(heap) catch return VmError.OutOfMemory;
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                result = list_mod.cons(heap, vector_mod.nth(v, i), result) catch return VmError.OutOfMemory;
            }
            break :blk result;
        },
        else => VmError.KindMismatch,
    };
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "stdlib: installCore registers all 10 fns" {
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
    for (core_fns) |entry| {
        const v = ns.lookup(entry.name) orelse return error.TestFailed;
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

test "stdlib: nativeFnValue round-trips" {
    const v = vm_mod.nativeFnValue(&native_first);
    try testing.expectEqual(Kind.native_fn, v.kind());
    const back = vm_mod.asNativeFn(v);
    try testing.expectEqualStrings("first", back.name);
}
