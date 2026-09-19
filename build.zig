//! nexis — Build Configuration.
//!
//! Usage:
//!   zig build parser                    regenerate src/parser.zig from nexis.grammar
//!   zig build test                      everything: unit, property, golden, Nextomic corpora,
//!                                       test/nextomic scripts, examples (minutes)
//!   zig build quick                     the inner loop: language, eval-pipeline and Nextomic
//!                                       unit + property binaries (seconds)
//!   zig build nextomic-test             Nextomic unit, property and corpus binaries
//!   zig build nextomic-nx               test/nextomic/*.nx through bin/nexis
//!   zig build examples                  every examples/*.nx through bin/nexis
//!   zig build golden                    verify golden reader outputs (byte-exact)
//!   zig build golden -Dupdate=true      regenerate golden expected files
//!
//! The checked-in `src/parser.zig` is the authoritative artifact; the
//! `parser` step exists so contributors editing `nexis.grammar` can
//! regenerate it reproducibly.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const update_golden = b.option(bool, "update", "rewrite golden expected files in-place") orelse false;

    // External dependency: emdb (path dep per build.zig.zon).
    const emdb_dep = b.dependency("emdb", .{
        .target = target,
        .optimize = optimize,
    });
    const emdb_mod = emdb_dep.module("emdb");

    // -------------------------------------------------------------------------
    // Parser generation (via the external nexus tool at ../nexus/bin/nexus)
    // -------------------------------------------------------------------------

    const nexus_bin = b.pathJoin(&.{ b.pathFromRoot(".."), "nexus", "bin", "nexus" });
    const run_nexus = b.addSystemCommand(&.{
        nexus_bin,
        "nexis.grammar",
        "src/parser.zig",
    });
    const parser_step = b.step("parser", "Regenerate src/parser.zig from nexis.grammar");
    parser_step.dependOn(&run_nexus.step);

    // -------------------------------------------------------------------------
    // Modules exposed to tests
    //
    // Each runtime-core module gets its own standalone module handle so
    // cross-module tests (test/prop/*) can `@import("hash")` etc. without
    // relying on relative paths outside the test's own module.
    // -------------------------------------------------------------------------

    const hash_mod = b.createModule(.{
        .root_source_file = b.path("src/hash.zig"),
        .target = target,
        .optimize = optimize,
    });

    const value_mod = b.createModule(.{
        .root_source_file = b.path("src/value.zig"),
        .target = target,
        .optimize = optimize,
    });
    value_mod.addImport("hash", hash_mod);

    const eq_mod = b.createModule(.{
        .root_source_file = b.path("src/eq.zig"),
        .target = target,
        .optimize = optimize,
    });
    eq_mod.addImport("value", value_mod);
    eq_mod.addImport("hash", hash_mod);

    const intern_mod = b.createModule(.{
        .root_source_file = b.path("src/intern.zig"),
        .target = target,
        .optimize = optimize,
    });
    intern_mod.addImport("value", value_mod);
    intern_mod.addImport("hash", hash_mod);

    const heap_mod = b.createModule(.{
        .root_source_file = b.path("src/heap.zig"),
        .target = target,
        .optimize = optimize,
    });
    heap_mod.addImport("value", value_mod);

    const string_mod = b.createModule(.{
        .root_source_file = b.path("src/string.zig"),
        .target = target,
        .optimize = optimize,
    });
    string_mod.addImport("value", value_mod);
    string_mod.addImport("heap", heap_mod);
    string_mod.addImport("hash", hash_mod);

    // atom: in-memory mutable cell. Identical module-graph shape
    // to string_mod (value+heap+hash).
    // No back-edges; consumed only by dispatch / gc / stdlib /
    // codec / cli at their `.atom` arms.
    const atom_mod = b.createModule(.{
        .root_source_file = b.path("src/atom.zig"),
        .target = target,
        .optimize = optimize,
    });
    atom_mod.addImport("value", value_mod);
    atom_mod.addImport("heap", heap_mod);
    atom_mod.addImport("hash", hash_mod);

    // record_mod declared further down (after champ_mod) — needs
    // champ for field-map hash composition.

    // format_mod is declared further down (after db_mod) so its
    // addImport calls see every dependency already-created.

    const list_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/list.zig"),
        .target = target,
        .optimize = optimize,
    });
    list_mod.addImport("value", value_mod);
    list_mod.addImport("heap", heap_mod);
    list_mod.addImport("hash", hash_mod);

    const vector_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/vector.zig"),
        .target = target,
        .optimize = optimize,
    });
    vector_mod.addImport("value", value_mod);
    vector_mod.addImport("heap", heap_mod);
    vector_mod.addImport("hash", hash_mod);

    const bignum_mod = b.createModule(.{
        .root_source_file = b.path("src/bignum.zig"),
        .target = target,
        .optimize = optimize,
    });
    bignum_mod.addImport("value", value_mod);
    bignum_mod.addImport("heap", heap_mod);
    bignum_mod.addImport("hash", hash_mod);

    // typed_vector: Kind.typed_vector = 23, unboxed i64 / f64
    // elements. Leaf kind; bignum only for `nth` promoting an i64
    // beyond the fixnum range.
    const typed_vector_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/typed_vector.zig"),
        .target = target,
        .optimize = optimize,
    });
    typed_vector_mod.addImport("value", value_mod);
    typed_vector_mod.addImport("heap", heap_mod);
    typed_vector_mod.addImport("hash", hash_mod);
    typed_vector_mod.addImport("bignum", bignum_mod);

    const champ_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/champ.zig"),
        .target = target,
        .optimize = optimize,
    });
    champ_mod.addImport("value", value_mod);
    champ_mod.addImport("heap", heap_mod);
    champ_mod.addImport("hash", hash_mod);
    // string: the collision-node fixtures key by heap strings, the one
    // key kind whose indexing hash reaches the `elementHash` callback
    // (CHAMP.md §5.1).
    champ_mod.addImport("string", string_mod);

    const transient_mod = b.createModule(.{
        .root_source_file = b.path("src/coll/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    transient_mod.addImport("value", value_mod);
    transient_mod.addImport("heap", heap_mod);
    transient_mod.addImport("champ", champ_mod);
    transient_mod.addImport("vector", vector_mod);

    // record: Kind.record = 35. Needs champ for field-map hash
    // composition. One-way terminal.
    const record_mod = b.createModule(.{
        .root_source_file = b.path("src/record.zig"),
        .target = target,
        .optimize = optimize,
    });
    record_mod.addImport("value", value_mod);
    record_mod.addImport("heap", heap_mod);
    record_mod.addImport("hash", hash_mod);
    record_mod.addImport("champ", champ_mod);

    // protocol: Kind.protocol = 36 + Kind.protocol_fn = 37.
    // Identity-valued. Same module-graph
    // shape as atom (value + heap + hash only).
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_mod.addImport("value", value_mod);
    protocol_mod.addImport("heap", heap_mod);
    protocol_mod.addImport("hash", hash_mod);

    const codec_mod = b.createModule(.{
        .root_source_file = b.path("src/codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    codec_mod.addImport("value", value_mod);
    codec_mod.addImport("heap", heap_mod);
    codec_mod.addImport("intern", intern_mod);
    codec_mod.addImport("hash", hash_mod);
    codec_mod.addImport("string", string_mod);
    codec_mod.addImport("bignum", bignum_mod);
    codec_mod.addImport("list", list_mod);
    codec_mod.addImport("vector", vector_mod);
    codec_mod.addImport("champ", champ_mod);
    codec_mod.addImport("typed_vector", typed_vector_mod);
    // codec's inline tests import transient to exercise the
    // UnserializableKind error path for transient Values.
    codec_mod.addImport("transient", transient_mod);
    // codec rejects atoms as :unserializable.
    codec_mod.addImport("atom", atom_mod);
    codec_mod.addImport("record", record_mod);
    codec_mod.addImport("protocol", protocol_mod);

    const gc_mod = b.createModule(.{
        .root_source_file = b.path("src/gc.zig"),
        .target = target,
        .optimize = optimize,
    });
    gc_mod.addImport("value", value_mod);
    gc_mod.addImport("heap", heap_mod);
    gc_mod.addImport("string", string_mod);
    gc_mod.addImport("bignum", bignum_mod);
    gc_mod.addImport("list", list_mod);
    gc_mod.addImport("vector", vector_mod);
    gc_mod.addImport("champ", champ_mod);
    gc_mod.addImport("typed_vector", typed_vector_mod);
    gc_mod.addImport("transient", transient_mod);
    gc_mod.addImport("atom", atom_mod);
    gc_mod.addImport("record", record_mod);
    gc_mod.addImport("protocol", protocol_mod);

    const pool_mod = b.createModule(.{
        .root_source_file = b.path("src/pool.zig"),
        .target = target,
        .optimize = optimize,
    });

    const vm_mod = b.createModule(.{
        .root_source_file = b.path("src/vm.zig"),
        .target = target,
        .optimize = optimize,
    });
    vm_mod.addImport("value", value_mod);
    // The VM owns the collected heap and is the collector's host
    // (docs/VM.md §9).
    vm_mod.addImport("heap", heap_mod);
    vm_mod.addImport("gc", gc_mod);
    vm_mod.addImport("list", list_mod);
    // VM owns `coll:vector` runtime construction.
    vm_mod.addImport("vector", vector_mod);
    // VM also owns `coll:map` / `coll:set`. The `dispatch`
    // addImport happens LATER in the file (after dispatch_mod is
    // declared) — it is attached to the same vm_mod below
    // dispatch_mod.
    vm_mod.addImport("champ", champ_mod);
    // VM owns an `Interner` for quoted-symbol / quoted-keyword
    // Value construction. The compile-side `lowerQuotePayload`
    // interns symbols/keywords through this shared Interner so
    // identity is stable across compile + run.
    vm_mod.addImport("intern", intern_mod);
    // DispatchKey.ofValue inspects record type_id.
    vm_mod.addImport("record", record_mod);
    // VM owns the protocol registry + the
    // dispatchProtocolMethod path used by `call:call`.
    vm_mod.addImport("protocol", protocol_mod);
    // The numeric tower promotes to bignum and demotes back.
    vm_mod.addImport("bignum", bignum_mod);

    // reader exposed as a proper module so compile.zig
    // can consume `reader.Form` trees. reader.zig uses sibling-
    // file imports (`@import("parser.zig")`, `@import("nexis.zig")`)
    // which Zig resolves automatically from the file's directory,
    // so no addImport calls are needed on this module.
    const reader_mod = b.createModule(.{
        .root_source_file = b.path("src/reader.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Form → Form macro expansion (see
    // docs/MACROEXPAND.md). Lives between Reader.readOneForm
    // and lowerForm in the pipeline.
    const expand_mod = b.createModule(.{
        .root_source_file = b.path("src/expand.zig"),
        .target = target,
        .optimize = optimize,
    });
    expand_mod.addImport("reader", reader_mod);
    expand_mod.addImport("intern", intern_mod);
    // defmacro + user-macro invocation need vm
    // (Namespace, Var, evalClosure) + value + collection
    // modules for Form↔Value conversion.
    expand_mod.addImport("vm", vm_mod);
    expand_mod.addImport("value", value_mod);
    expand_mod.addImport("list", list_mod);
    expand_mod.addImport("vector", vector_mod);
    expand_mod.addImport("champ", champ_mod);
    expand_mod.addImport("heap", heap_mod);
    // formToValue handles `.string`
    // Form datums by allocating via `string.fromBytes` against
    // the macro-arg heap.
    expand_mod.addImport("string", string_mod);
    // Form↔Value conversion of integers beyond the fixnum range.
    expand_mod.addImport("bignum", bignum_mod);
    // dispatch_mod is declared LATER (it depends on db); the
    // addImport for it is attached after that block. See below.

    // standard library — host-Zig native fns
    // installed into the user's namespace at VM startup.
    const stdlib_mod = b.createModule(.{
        .root_source_file = b.path("src/stdlib.zig"),
        .target = target,
        .optimize = optimize,
    });
    stdlib_mod.addImport("value", value_mod);
    stdlib_mod.addImport("vm", vm_mod);
    stdlib_mod.addImport("list", list_mod);
    stdlib_mod.addImport("vector", vector_mod);
    stdlib_mod.addImport("typed_vector", typed_vector_mod);
    stdlib_mod.addImport("bignum", bignum_mod);
    stdlib_mod.addImport("champ", champ_mod);
    stdlib_mod.addImport("intern", intern_mod);
    stdlib_mod.addImport("heap", heap_mod);
    // atom native fns.
    stdlib_mod.addImport("atom", atom_mod);
    // core string ops + codepoint helpers.
    stdlib_mod.addImport("string", string_mod);
    // records substrate (Kind.record + registry +
    // native helpers + map-like ops over records).
    stdlib_mod.addImport("record", record_mod);
    // protocols substrate.
    stdlib_mod.addImport("protocol", protocol_mod);
    // stdlib_mod's "format" import is wired AFTER format_mod is
    // declared (which is after db_mod). See further down.
    // dispatch_mod, db_mod, codec_mod are declared later;
    // imports attached at the bottom of the dispatch block.

    // loader_mod declared AFTER compile_mod (below).

    const compile_mod = b.createModule(.{
        .root_source_file = b.path("src/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    compile_mod.addImport("vm", vm_mod);
    compile_mod.addImport("value", value_mod);
    // tests inspect rest-list results from variadic
    // fn calls. compile.zig core doesn't depend on list — the
    // VM constructs rest lists at call/prologue time.
    compile_mod.addImport("list", list_mod);
    // Form-tree input from the reader.
    compile_mod.addImport("reader", reader_mod);
    // Interner threaded through Form lowering
    // for quoted-symbol/quoted-keyword Value construction.
    // The Interner instance comes from the VM at runtime; the
    // compile-side just imports the type.
    compile_mod.addImport("intern", intern_mod);
    // expander is consumed by compileFormFullWithMacros.
    compile_mod.addImport("expand", expand_mod);
    // champ used by compile.zig tests to assert
    // mapCount / setCount / mapGet on result Values; the
    // compile-side core itself doesn't need champ (the VM
    // executes coll:map / coll:set).
    compile_mod.addImport("champ", champ_mod);
    // string literals lower to
    // Tiny.literal via `string.fromBytes` against a heap reached
    // through `namespace.registry.heap`.
    compile_mod.addImport("heap", heap_mod);
    compile_mod.addImport("string", string_mod);
    // integer literals beyond the fixnum range lower to bignums.
    compile_mod.addImport("bignum", bignum_mod);

    // namespace loader (require + file loading).
    const loader_mod = b.createModule(.{
        .root_source_file = b.path("src/loader.zig"),
        .target = target,
        .optimize = optimize,
    });
    loader_mod.addImport("reader", reader_mod);
    loader_mod.addImport("intern", intern_mod);
    loader_mod.addImport("expand", expand_mod);
    loader_mod.addImport("compile", compile_mod);
    loader_mod.addImport("vm", vm_mod);
    loader_mod.addImport("value", value_mod);

    const db_mod = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    db_mod.addImport("value", value_mod);
    db_mod.addImport("heap", heap_mod);
    db_mod.addImport("intern", intern_mod);
    db_mod.addImport("hash", hash_mod);
    db_mod.addImport("codec", codec_mod);
    db_mod.addImport("string", string_mod);
    db_mod.addImport("list", list_mod);
    db_mod.addImport("champ", champ_mod);
    db_mod.addImport("emdb", emdb_mod);

    gc_mod.addImport("db", db_mod);

    // central Value → text formatter with `.display` and
    // `.readable` modes. Imports the menagerie of consumer kinds
    // (one-way; nothing depends on format_mod). The single
    // formatValue implementation; compile, cli and the integration
    // tests all delegate to it.
    // Declared here AFTER all leaf-kind modules + db + vm exist.
    const format_mod = b.createModule(.{
        .root_source_file = b.path("src/format.zig"),
        .target = target,
        .optimize = optimize,
    });
    format_mod.addImport("value", value_mod);
    format_mod.addImport("intern", intern_mod);
    format_mod.addImport("list", list_mod);
    format_mod.addImport("vector", vector_mod);
    format_mod.addImport("champ", champ_mod);
    format_mod.addImport("string", string_mod);
    format_mod.addImport("heap", heap_mod);
    format_mod.addImport("atom", atom_mod);
    format_mod.addImport("db", db_mod);
    format_mod.addImport("vm", vm_mod);
    format_mod.addImport("record", record_mod);
    format_mod.addImport("protocol", protocol_mod);
    format_mod.addImport("bignum", bignum_mod);
    format_mod.addImport("typed_vector", typed_vector_mod);

    // Late-binding addImport for stdlib_mod (declared earlier).
    stdlib_mod.addImport("format", format_mod);

    const dispatch_mod = b.createModule(.{
        .root_source_file = b.path("src/dispatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    dispatch_mod.addImport("value", value_mod);
    dispatch_mod.addImport("eq", eq_mod);
    dispatch_mod.addImport("heap", heap_mod);
    dispatch_mod.addImport("hash", hash_mod);
    dispatch_mod.addImport("string", string_mod);
    dispatch_mod.addImport("list", list_mod);
    dispatch_mod.addImport("vector", vector_mod);
    dispatch_mod.addImport("bignum", bignum_mod);
    dispatch_mod.addImport("champ", champ_mod);
    dispatch_mod.addImport("typed_vector", typed_vector_mod);
    dispatch_mod.addImport("transient", transient_mod);
    dispatch_mod.addImport("db", db_mod);
    dispatch_mod.addImport("atom", atom_mod);
    dispatch_mod.addImport("record", record_mod);
    dispatch_mod.addImport("protocol", protocol_mod);
    // dispatch is a one-way terminal: nothing depends on it. value
    // and eq deliberately stay low-level (panicking on heap kinds)
    // so the module graph remains acyclic and every test-binary
    // root resolves cleanly.
    //
    // Exception: vm_mod + compile_mod need dispatch
    // for `coll:map` / `coll:set` hash + equality (compile_mod's
    // tests use it for assertions; vm_mod for the runtime build).
    // Attaching here so they're not forward-declared above
    // dispatch_mod's creation.
    vm_mod.addImport("dispatch", dispatch_mod);
    compile_mod.addImport("dispatch", dispatch_mod);
    // expand needs dispatch for Form→Value
    // construction of maps/sets (hash + equality).
    expand_mod.addImport("dispatch", dispatch_mod);
    // stdlib needs dispatch for `=` (value
    // equality) implementation.
    stdlib_mod.addImport("dispatch", dispatch_mod);
    // stdlib's db primitives need db + codec.
    stdlib_mod.addImport("db", db_mod);
    stdlib_mod.addImport("codec", codec_mod);
    // db/scan + db/reduce-tree need emdb cursors.
    stdlib_mod.addImport("emdb", emdb_mod);

    // -------------------------------------------------------------------------
    // nextomic — the Datomic-class database (docs/NEXTOMIC.md §8). One
    // module above dispatch and vm, imported by stdlib and cli only. The
    // storage half lives in src/nextomic/{key,datom,store,idents,schema,
    // transact,db}.zig; the query pipeline, pull and natives are files in
    // the same module. Its test binary is `nextomic` below.
    // -------------------------------------------------------------------------

    // nextomic_handle — the heap bodies of the `nextomic_conn`,
    // `nextomic_db` and `nextomic_entity` kinds. Below dispatch, format,
    // gc and vm so their kind arms can print, compare, hash, trace and
    // look up the handles without importing the module above them.
    const nextomic_handle_mod = b.createModule(.{
        .root_source_file = b.path("src/nextomic/handle.zig"),
        .target = target,
        .optimize = optimize,
    });
    nextomic_handle_mod.addImport("value", value_mod);
    nextomic_handle_mod.addImport("heap", heap_mod);
    nextomic_handle_mod.addImport("hash", hash_mod);
    dispatch_mod.addImport("nextomic_handle", nextomic_handle_mod);
    format_mod.addImport("nextomic_handle", nextomic_handle_mod);
    gc_mod.addImport("nextomic_handle", nextomic_handle_mod);
    // `vm.lookup` reads a lazy entity through the hook its box carries.
    vm_mod.addImport("nextomic_handle", nextomic_handle_mod);
    const nextomic_handle_tests = b.addTest(.{ .root_module = nextomic_handle_mod });
    const run_nextomic_handle_tests = b.addRunArtifact(nextomic_handle_tests);

    const nextomic_imports = [_]struct { name: []const u8, mod: *std.Build.Module }{
        .{ .name = "value", .mod = value_mod },
        .{ .name = "heap", .mod = heap_mod },
        .{ .name = "intern", .mod = intern_mod },
        .{ .name = "hash", .mod = hash_mod },
        .{ .name = "string", .mod = string_mod },
        .{ .name = "list", .mod = list_mod },
        .{ .name = "vector", .mod = vector_mod },
        .{ .name = "champ", .mod = champ_mod },
        .{ .name = "codec", .mod = codec_mod },
        .{ .name = "dispatch", .mod = dispatch_mod },
        .{ .name = "emdb", .mod = emdb_mod },
        // natives.zig: the VM (NativeFn, throwKeyword), the db.zig
        // failure-name table and the handle bodies.
        .{ .name = "vm", .mod = vm_mod },
        .{ .name = "db", .mod = db_mod },
        .{ .name = "nextomic_handle", .mod = nextomic_handle_mod },
    };
    const nextomic_mod = b.createModule(.{
        .root_source_file = b.path("src/nextomic/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (nextomic_imports) |imp| nextomic_mod.addImport(imp.name, imp.mod);
    stdlib_mod.addImport("nextomic", nextomic_mod);

    // The module is its own test root, as nextomic_handle is above.
    const nextomic_tests = b.addTest(.{ .root_module = nextomic_mod });
    const run_nextomic_tests = b.addRunArtifact(nextomic_tests);

    const prop_nextomic_key_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/nextomic_key.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_nextomic_key_mod.addImport("nextomic", nextomic_mod);
    const prop_nextomic_key_tests = b.addTest(.{ .root_module = prop_nextomic_key_mod });
    const run_prop_nextomic_key_tests = b.addRunArtifact(prop_nextomic_key_tests);

    const prop_nextomic_tx_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/nextomic_tx.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_nextomic_tx_mod.addImport("nextomic", nextomic_mod);
    const prop_nextomic_tx_tests = b.addTest(.{ .root_module = prop_nextomic_tx_mod });
    const run_prop_nextomic_tx_tests = b.addRunArtifact(prop_nextomic_tx_tests);

    // The query corpus (test/integration/nextomic_q.zig) reads its
    // queries with the language reader and checks every result against
    // a naive evaluator.
    const integration_nextomic_q_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/nextomic_q.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_nextomic_q_mod.addImport("nextomic", nextomic_mod);
    integration_nextomic_q_mod.addImport("reader", reader_mod);
    for (nextomic_imports) |imp| integration_nextomic_q_mod.addImport(imp.name, imp.mod);
    const integration_nextomic_q_tests = b.addTest(.{ .root_module = integration_nextomic_q_mod });
    const run_integration_nextomic_q_tests = b.addRunArtifact(integration_nextomic_q_tests);

    // The pull corpus (test/integration/nextomic_pull.zig) checks every
    // pattern against a naive evaluator over entity() and datoms(), and
    // covers speculative `with` through q, entity and pull.
    const integration_nextomic_pull_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/nextomic_pull.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_nextomic_pull_mod.addImport("nextomic", nextomic_mod);
    integration_nextomic_pull_mod.addImport("reader", reader_mod);
    for (nextomic_imports) |imp| integration_nextomic_pull_mod.addImport(imp.name, imp.mod);
    const integration_nextomic_pull_tests = b.addTest(.{ .root_module = integration_nextomic_pull_mod });
    const run_integration_nextomic_pull_tests = b.addRunArtifact(integration_nextomic_pull_tests);

    // The transaction-function corpus (test/integration/nextomic_fn.zig):
    // :db.fn/call and :db.fn/cas through transact!.
    const integration_nextomic_fn_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/nextomic_fn.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_nextomic_fn_mod.addImport("nextomic", nextomic_mod);
    integration_nextomic_fn_mod.addImport("reader", reader_mod);
    for (nextomic_imports) |imp| integration_nextomic_fn_mod.addImport(imp.name, imp.mod);
    const integration_nextomic_fn_tests = b.addTest(.{ .root_module = integration_nextomic_fn_mod });
    const run_integration_nextomic_fn_tests = b.addRunArtifact(integration_nextomic_fn_tests);

    const nextomic_test_step = b.step("nextomic-test", "Nextomic unit tests, key and transaction property tests, and the query and pull corpora");
    nextomic_test_step.dependOn(&run_nextomic_handle_tests.step);
    nextomic_test_step.dependOn(&run_nextomic_tests.step);
    nextomic_test_step.dependOn(&run_prop_nextomic_key_tests.step);
    nextomic_test_step.dependOn(&run_prop_nextomic_tx_tests.step);
    nextomic_test_step.dependOn(&run_integration_nextomic_q_tests.step);
    nextomic_test_step.dependOn(&run_integration_nextomic_pull_tests.step);
    nextomic_test_step.dependOn(&run_integration_nextomic_fn_tests.step);

    // -------------------------------------------------------------------------
    // Reader unit tests (src/reader.zig has its own test { ... }
    // blocks; depends on src/parser.zig + src/nexis.zig which live in the
    // same directory and import each other via @import("parser.zig") etc.).
    // -------------------------------------------------------------------------

    const reader_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/reader.zig"),
        .target = target,
        .optimize = optimize,
    });
    const reader_tests = b.addTest(.{ .root_module = reader_tests_mod });
    const run_reader_tests = b.addRunArtifact(reader_tests);

    // -------------------------------------------------------------------------
    // Runtime-core inline tests (hash, value, eq). Each file owns
    // its own `test "..."` blocks and is compiled as a standalone test
    // binary. The modules share import paths via the standalone modules
    // above.
    // -------------------------------------------------------------------------

    // Per-file test configuration. Each entry lists the sibling
    // modules the test binary needs as named imports. A file is
    // deliberately omitted from its own import list — Zig rejects a
    // source file appearing both as the test binary's `root` module
    // and as a named import of the same graph.
    const AllSiblings = struct {
        hash: *std.Build.Module,
        value: *std.Build.Module,
        eq: *std.Build.Module,
        heap: *std.Build.Module,
        intern: *std.Build.Module,
        string: *std.Build.Module,
        list: *std.Build.Module,
        vector: *std.Build.Module,
        bignum: *std.Build.Module,
        typed_vector: *std.Build.Module,
        champ: *std.Build.Module,
        transient: *std.Build.Module,
        atom: *std.Build.Module,
        record: *std.Build.Module,
        protocol: *std.Build.Module,
        format: *std.Build.Module,
        gc: *std.Build.Module,
        codec: *std.Build.Module,
        db: *std.Build.Module,
        emdb: *std.Build.Module,
        pool: *std.Build.Module,
        vm: *std.Build.Module,
        compile: *std.Build.Module,
        reader: *std.Build.Module,
        expand: *std.Build.Module,
        dispatch: *std.Build.Module,
        stdlib: *std.Build.Module,
        loader: *std.Build.Module,
        nextomic_handle: *std.Build.Module,
        nextomic: *std.Build.Module,
    };
    const siblings: AllSiblings = .{
        .hash = hash_mod,
        .value = value_mod,
        .eq = eq_mod,
        .heap = heap_mod,
        .intern = intern_mod,
        .string = string_mod,
        .list = list_mod,
        .vector = vector_mod,
        .bignum = bignum_mod,
        .typed_vector = typed_vector_mod,
        .champ = champ_mod,
        .transient = transient_mod,
        .atom = atom_mod,
        .record = record_mod,
        .protocol = protocol_mod,
        .format = format_mod,
        .gc = gc_mod,
        .codec = codec_mod,
        .db = db_mod,
        .emdb = emdb_mod,
        .pool = pool_mod,
        .vm = vm_mod,
        .compile = compile_mod,
        .reader = reader_mod,
        .expand = expand_mod,
        .dispatch = dispatch_mod,
        .stdlib = stdlib_mod,
        .loader = loader_mod,
        .nextomic_handle = nextomic_handle_mod,
        .nextomic = nextomic_mod,
    };

    const RuntimeTest = struct {
        name: []const u8,
        path: []const u8,
        imports: []const []const u8,
    };
    const runtime_test_files = [_]RuntimeTest{
        .{ .name = "hash", .path = "src/hash.zig", .imports = &.{} },
        .{ .name = "value", .path = "src/value.zig", .imports = &.{"hash"} },
        .{ .name = "eq", .path = "src/eq.zig", .imports = &.{ "value", "hash" } },
        .{ .name = "intern", .path = "src/intern.zig", .imports = &.{ "value", "hash" } },
        .{ .name = "heap", .path = "src/heap.zig", .imports = &.{"value"} },
        .{ .name = "string", .path = "src/string.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "list", .path = "src/coll/list.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "vector", .path = "src/coll/vector.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "bignum", .path = "src/bignum.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "champ", .path = "src/coll/champ.zig", .imports = &.{ "value", "heap", "hash", "string" } },
        .{ .name = "transient", .path = "src/coll/transient.zig", .imports = &.{ "value", "heap", "champ", "vector" } },
        // atom test binary. Same import shape as string.
        .{ .name = "atom", .path = "src/atom.zig", .imports = &.{ "value", "heap", "hash" } },
        // record test binary (Kind.record = 35).
        .{ .name = "record", .path = "src/record.zig", .imports = &.{ "value", "heap", "hash", "champ" } },
        // protocol test binary (Kind.protocol = 36 + Kind.protocol_fn = 37).
        .{ .name = "protocol", .path = "src/protocol.zig", .imports = &.{ "value", "heap", "hash" } },
        .{ .name = "codec", .path = "src/codec.zig", .imports = &.{ "value", "heap", "intern", "hash", "string", "bignum", "list", "vector", "champ", "typed_vector", "transient", "atom", "record", "protocol" } },
        .{ .name = "gc", .path = "src/gc.zig", .imports = &.{ "value", "heap", "string", "bignum", "list", "vector", "champ", "typed_vector", "transient", "db", "atom", "record", "protocol", "nextomic_handle" } },
        .{ .name = "dispatch", .path = "src/dispatch.zig", .imports = &.{ "value", "eq", "heap", "hash", "string", "list", "vector", "bignum", "champ", "typed_vector", "transient", "db", "atom", "record", "protocol", "nextomic_handle" } },
        .{ .name = "db", .path = "src/db.zig", .imports = &.{ "value", "heap", "intern", "hash", "codec", "string", "list", "champ", "emdb" } },
        .{ .name = "pool", .path = "src/pool.zig", .imports = &.{} },
        .{ .name = "vm", .path = "src/vm.zig", .imports = &.{ "value", "heap", "gc", "list", "intern", "vector", "champ", "dispatch", "record", "protocol", "bignum", "nextomic_handle" } },
        // format test binary. Imports the menagerie of
        // consumer kinds; nothing depends on format itself.
        .{ .name = "format", .path = "src/format.zig", .imports = &.{ "value", "intern", "list", "vector", "champ", "string", "heap", "atom", "db", "vm", "record", "protocol", "nextomic_handle", "bignum", "typed_vector" } },
        .{ .name = "compile", .path = "src/compile.zig", .imports = &.{ "vm", "value", "list", "reader", "intern", "expand", "vector", "champ", "dispatch", "heap", "string", "bignum" } },
        .{ .name = "expand", .path = "src/expand.zig", .imports = &.{ "reader", "intern", "vm", "value", "list", "vector", "champ", "heap", "dispatch", "string", "bignum" } },
        .{ .name = "stdlib", .path = "src/stdlib.zig", .imports = &.{ "value", "vm", "list", "vector", "typed_vector", "bignum", "champ", "intern", "dispatch", "db", "codec", "heap", "emdb", "atom", "string", "format", "record", "protocol", "nextomic" } },
        .{ .name = "loader", .path = "src/loader.zig", .imports = &.{ "reader", "intern", "expand", "compile", "vm", "value" } },
        .{ .name = "disasm", .path = "src/disasm.zig", .imports = &.{ "vm", "value", "format", "intern" } },
        // Appended after `loader` so the `quick` step's index
        // assertions below hold.
        .{ .name = "typed_vector", .path = "src/coll/typed_vector.zig", .imports = &.{ "value", "heap", "hash", "bignum" } },
    };

    var runtime_test_runs: [runtime_test_files.len]*std.Build.Step.Run = undefined;
    for (runtime_test_files, 0..) |f, i| {
        const m = b.createModule(.{
            .root_source_file = b.path(f.path),
            .target = target,
            .optimize = optimize,
        });
        for (f.imports) |imp_name| {
            var mod: ?*std.Build.Module = null;
            inline for (@typeInfo(AllSiblings).@"struct".fields) |field| {
                if (std.mem.eql(u8, imp_name, field.name)) mod = @field(siblings, field.name);
            }
            m.addImport(imp_name, mod orelse @panic("unknown sibling import"));
        }

        const t = b.addTest(.{ .root_module = m });
        runtime_test_runs[i] = b.addRunArtifact(t);
    }

    // -------------------------------------------------------------------------
    // Property tests — cross-module sweeps over the runtime invariants.
    // -------------------------------------------------------------------------

    const prop_primitive_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/primitive.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_primitive_mod.addImport("hash", hash_mod);
    prop_primitive_mod.addImport("value", value_mod);
    prop_primitive_mod.addImport("eq", eq_mod);

    const prop_primitive_tests = b.addTest(.{ .root_module = prop_primitive_mod });
    const run_prop_primitive_tests = b.addRunArtifact(prop_primitive_tests);

    const prop_intern_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/intern.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_intern_mod.addImport("hash", hash_mod);
    prop_intern_mod.addImport("value", value_mod);
    prop_intern_mod.addImport("intern", intern_mod);

    const prop_intern_tests = b.addTest(.{ .root_module = prop_intern_mod });
    const run_prop_intern_tests = b.addRunArtifact(prop_intern_tests);

    const prop_heap_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/heap.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_heap_mod.addImport("value", value_mod);
    prop_heap_mod.addImport("heap", heap_mod);

    const prop_heap_tests = b.addTest(.{ .root_module = prop_heap_mod });
    const run_prop_heap_tests = b.addRunArtifact(prop_heap_tests);

    const prop_string_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/string.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_string_mod.addImport("value", value_mod);
    prop_string_mod.addImport("heap", heap_mod);
    prop_string_mod.addImport("hash", hash_mod);
    prop_string_mod.addImport("string", string_mod);
    prop_string_mod.addImport("dispatch", dispatch_mod);

    const prop_string_tests = b.addTest(.{ .root_module = prop_string_mod });
    const run_prop_string_tests = b.addRunArtifact(prop_string_tests);

    const prop_list_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/list.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_list_mod.addImport("value", value_mod);
    prop_list_mod.addImport("heap", heap_mod);
    prop_list_mod.addImport("hash", hash_mod);
    prop_list_mod.addImport("list", list_mod);
    prop_list_mod.addImport("dispatch", dispatch_mod);

    const prop_list_tests = b.addTest(.{ .root_module = prop_list_mod });
    const run_prop_list_tests = b.addRunArtifact(prop_list_tests);

    const prop_bignum_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/bignum.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_bignum_mod.addImport("value", value_mod);
    prop_bignum_mod.addImport("heap", heap_mod);
    prop_bignum_mod.addImport("hash", hash_mod);
    prop_bignum_mod.addImport("bignum", bignum_mod);
    prop_bignum_mod.addImport("dispatch", dispatch_mod);

    const prop_bignum_tests = b.addTest(.{ .root_module = prop_bignum_mod });
    const run_prop_bignum_tests = b.addRunArtifact(prop_bignum_tests);

    const prop_vector_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/vector.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_vector_mod.addImport("value", value_mod);
    prop_vector_mod.addImport("heap", heap_mod);
    prop_vector_mod.addImport("hash", hash_mod);
    prop_vector_mod.addImport("list", list_mod);
    prop_vector_mod.addImport("vector", vector_mod);
    prop_vector_mod.addImport("dispatch", dispatch_mod);

    const prop_vector_tests = b.addTest(.{ .root_module = prop_vector_mod });
    const run_prop_vector_tests = b.addRunArtifact(prop_vector_tests);

    const prop_champ_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/champ.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_champ_mod.addImport("value", value_mod);
    prop_champ_mod.addImport("heap", heap_mod);
    prop_champ_mod.addImport("hash", hash_mod);
    prop_champ_mod.addImport("champ", champ_mod);
    prop_champ_mod.addImport("string", string_mod);
    prop_champ_mod.addImport("list", list_mod);
    prop_champ_mod.addImport("vector", vector_mod);
    prop_champ_mod.addImport("dispatch", dispatch_mod);

    const prop_champ_tests = b.addTest(.{ .root_module = prop_champ_mod });
    const run_prop_champ_tests = b.addRunArtifact(prop_champ_tests);

    const prop_gc_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/gc.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_gc_mod.addImport("value", value_mod);
    prop_gc_mod.addImport("heap", heap_mod);
    prop_gc_mod.addImport("hash", hash_mod);
    prop_gc_mod.addImport("string", string_mod);
    prop_gc_mod.addImport("list", list_mod);
    prop_gc_mod.addImport("vector", vector_mod);
    prop_gc_mod.addImport("champ", champ_mod);
    prop_gc_mod.addImport("dispatch", dispatch_mod);
    prop_gc_mod.addImport("gc", gc_mod);
    // The program-level case runs source through the whole pipeline
    // on a VM whose collector is forced frequent.
    prop_gc_mod.addImport("vm", vm_mod);
    prop_gc_mod.addImport("compile", compile_mod);
    prop_gc_mod.addImport("intern", intern_mod);
    prop_gc_mod.addImport("reader", reader_mod);
    prop_gc_mod.addImport("expand", expand_mod);
    prop_gc_mod.addImport("stdlib", stdlib_mod);

    const prop_gc_tests = b.addTest(.{ .root_module = prop_gc_mod });
    const run_prop_gc_tests = b.addRunArtifact(prop_gc_tests);

    const prop_transient_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_transient_mod.addImport("value", value_mod);
    prop_transient_mod.addImport("heap", heap_mod);
    prop_transient_mod.addImport("hash", hash_mod);
    prop_transient_mod.addImport("champ", champ_mod);
    prop_transient_mod.addImport("vector", vector_mod);
    prop_transient_mod.addImport("transient", transient_mod);
    prop_transient_mod.addImport("dispatch", dispatch_mod);
    prop_transient_mod.addImport("gc", gc_mod);

    const prop_transient_tests = b.addTest(.{ .root_module = prop_transient_mod });
    const run_prop_transient_tests = b.addRunArtifact(prop_transient_tests);

    const prop_codec_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_codec_mod.addImport("value", value_mod);
    prop_codec_mod.addImport("heap", heap_mod);
    prop_codec_mod.addImport("hash", hash_mod);
    prop_codec_mod.addImport("intern", intern_mod);
    prop_codec_mod.addImport("string", string_mod);
    prop_codec_mod.addImport("bignum", bignum_mod);
    prop_codec_mod.addImport("list", list_mod);
    prop_codec_mod.addImport("vector", vector_mod);
    prop_codec_mod.addImport("champ", champ_mod);
    prop_codec_mod.addImport("transient", transient_mod);
    prop_codec_mod.addImport("codec", codec_mod);
    prop_codec_mod.addImport("dispatch", dispatch_mod);

    const prop_codec_tests = b.addTest(.{ .root_module = prop_codec_mod });
    const run_prop_codec_tests = b.addRunArtifact(prop_codec_tests);

    const prop_typed_vector_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/typed_vector.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_typed_vector_mod.addImport("value", value_mod);
    prop_typed_vector_mod.addImport("heap", heap_mod);
    prop_typed_vector_mod.addImport("hash", hash_mod);
    prop_typed_vector_mod.addImport("intern", intern_mod);
    prop_typed_vector_mod.addImport("bignum", bignum_mod);
    prop_typed_vector_mod.addImport("vector", vector_mod);
    prop_typed_vector_mod.addImport("typed_vector", typed_vector_mod);
    prop_typed_vector_mod.addImport("codec", codec_mod);
    prop_typed_vector_mod.addImport("dispatch", dispatch_mod);

    const prop_typed_vector_tests = b.addTest(.{ .root_module = prop_typed_vector_mod });
    const run_prop_typed_vector_tests = b.addRunArtifact(prop_typed_vector_tests);

    const prop_db_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/db.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_db_mod.addImport("value", value_mod);
    prop_db_mod.addImport("heap", heap_mod);
    prop_db_mod.addImport("hash", hash_mod);
    prop_db_mod.addImport("intern", intern_mod);
    prop_db_mod.addImport("string", string_mod);
    prop_db_mod.addImport("bignum", bignum_mod);
    prop_db_mod.addImport("list", list_mod);
    prop_db_mod.addImport("vector", vector_mod);
    prop_db_mod.addImport("champ", champ_mod);
    prop_db_mod.addImport("codec", codec_mod);
    prop_db_mod.addImport("db", db_mod);
    prop_db_mod.addImport("dispatch", dispatch_mod);

    const prop_db_tests = b.addTest(.{ .root_module = prop_db_mod });
    const run_prop_db_tests = b.addRunArtifact(prop_db_tests);

    // Compiler property tests (COMPILER.md §9.4): closure
    // capture depth-10 + syntax-quote structural equality.
    const prop_compile_mod = b.createModule(.{
        .root_source_file = b.path("test/prop/compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    prop_compile_mod.addImport("value", value_mod);
    prop_compile_mod.addImport("vm", vm_mod);
    prop_compile_mod.addImport("compile", compile_mod);
    prop_compile_mod.addImport("intern", intern_mod);
    prop_compile_mod.addImport("reader", reader_mod);
    prop_compile_mod.addImport("expand", expand_mod);
    prop_compile_mod.addImport("list", list_mod);

    const prop_compile_tests = b.addTest(.{ .root_module = prop_compile_mod });
    const run_prop_compile_tests = b.addRunArtifact(prop_compile_tests);

    // Golden + eval pipeline tests (COMPILER.md §9.4 + §10).
    // End-to-end source→VM coverage for every
    // primitive-core form, macro, and exception-handling
    // path. Lives in test/integration/.
    const integration_eval_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/eval_pipeline.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_eval_mod.addImport("value", value_mod);
    integration_eval_mod.addImport("vm", vm_mod);
    integration_eval_mod.addImport("compile", compile_mod);
    integration_eval_mod.addImport("intern", intern_mod);
    integration_eval_mod.addImport("reader", reader_mod);
    integration_eval_mod.addImport("expand", expand_mod);
    integration_eval_mod.addImport("list", list_mod);
    integration_eval_mod.addImport("vector", vector_mod);
    integration_eval_mod.addImport("champ", champ_mod);
    integration_eval_mod.addImport("stdlib", stdlib_mod);
    // formatValue prints strings via string.asBytes.
    integration_eval_mod.addImport("string", string_mod);
    // integration tests delegate
    // value-printing to the central format.zig too, so test
    // expectations match REPL output exactly.
    integration_eval_mod.addImport("format", format_mod);

    const integration_eval_tests = b.addTest(.{ .root_module = integration_eval_mod });
    const run_integration_eval_tests = b.addRunArtifact(integration_eval_tests);

    // Runtime completeness tests: numeric tower, callable
    // collections, core functions, throw policy.
    const runtime_polish_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/runtime_polish.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_]struct { []const u8, *std.Build.Module }{
        .{ "value", value_mod },   .{ "vm", vm_mod },         .{ "compile", compile_mod },
        .{ "intern", intern_mod }, .{ "reader", reader_mod }, .{ "expand", expand_mod },
        .{ "stdlib", stdlib_mod }, .{ "format", format_mod },
    }) |imp| runtime_polish_mod.addImport(imp[0], imp[1]);
    const runtime_polish_tests = b.addTest(.{ .root_module = runtime_polish_mod });
    const run_runtime_polish_tests = b.addRunArtifact(runtime_polish_tests);

    // The lazy entity through the pipeline (test/integration/
    // nextomic_entity.zig): every access path as a program sees it,
    // and an entity kept in a Var under the collector's stress policy.
    const integration_nextomic_entity_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/nextomic_entity.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_]struct { []const u8, *std.Build.Module }{
        .{ "value", value_mod },   .{ "vm", vm_mod },         .{ "compile", compile_mod },
        .{ "intern", intern_mod }, .{ "reader", reader_mod }, .{ "expand", expand_mod },
        .{ "stdlib", stdlib_mod }, .{ "format", format_mod },
    }) |imp| integration_nextomic_entity_mod.addImport(imp[0], imp[1]);
    const integration_nextomic_entity_tests = b.addTest(.{ .root_module = integration_nextomic_entity_mod });
    const run_integration_nextomic_entity_tests = b.addRunArtifact(integration_nextomic_entity_tests);
    nextomic_test_step.dependOn(&run_integration_nextomic_entity_tests.step);

    // The numeric tower end to end: promotion, demotion, contagion,
    // literals, printing, predicates, conversions and the codec.
    const numbers_mod = b.createModule(.{
        .root_source_file = b.path("test/integration/numbers.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_]struct { []const u8, *std.Build.Module }{
        .{ "value", value_mod },   .{ "vm", vm_mod },         .{ "compile", compile_mod },
        .{ "intern", intern_mod }, .{ "reader", reader_mod }, .{ "expand", expand_mod },
        .{ "stdlib", stdlib_mod }, .{ "format", format_mod },
    }) |imp| numbers_mod.addImport(imp[0], imp[1]);
    const numbers_tests = b.addTest(.{ .root_module = numbers_mod });
    const run_numbers_tests = b.addRunArtifact(numbers_tests);

    // -------------------------------------------------------------------------
    // Benchmark harness (src/bench.zig) + benchmark runner (bench/main.zig).
    //
    // `zig build bench` produces + runs a ReleaseFast binary that
    // writes a table to stdout and (via --out) baseline JSON.
    //
    // The harness file is also compiled as a runtime test binary
    // so its inline tests (Stats, Runner) run under `zig build test`.
    // -------------------------------------------------------------------------

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bench_runner_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        // Bench runs in ReleaseFast so the numbers are
        // meaningful. Override with `-Doptimize=Debug` if the
        // intent is to sanity-check the bench plumbing itself.
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
    });
    bench_runner_mod.addImport("bench", bench_mod);
    bench_runner_mod.addImport("value", value_mod);
    bench_runner_mod.addImport("heap", heap_mod);
    bench_runner_mod.addImport("intern", intern_mod);
    bench_runner_mod.addImport("hash", hash_mod);
    bench_runner_mod.addImport("string", string_mod);
    bench_runner_mod.addImport("list", list_mod);
    bench_runner_mod.addImport("vector", vector_mod);
    bench_runner_mod.addImport("champ", champ_mod);
    bench_runner_mod.addImport("transient", transient_mod);
    bench_runner_mod.addImport("codec", codec_mod);
    bench_runner_mod.addImport("dispatch", dispatch_mod);
    bench_runner_mod.addImport("db", db_mod);
    bench_runner_mod.addImport("emdb", emdb_mod);
    bench_runner_mod.addImport("pool", pool_mod);
    // bench/main.zig (COMPILER.md §9.4)
    // measures compile + eval throughput + closure-creation
    // cost + recur per-iter cost.
    bench_runner_mod.addImport("vm", vm_mod);
    bench_runner_mod.addImport("compile", compile_mod);
    bench_runner_mod.addImport("expand", expand_mod);

    const bench_exe = b.addExecutable(.{
        .name = "nexis-bench",
        .root_module = bench_runner_mod,
    });
    const install_bench = b.addInstallArtifact(bench_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis-bench",
    });

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    run_bench.step.dependOn(&install_bench.step);

    const bench_step = b.step("bench", "Run baseline benchmark suite (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const bench_tests_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_tests = b.addTest(.{ .root_module = bench_tests_mod });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    // -------------------------------------------------------------------------
    // Golden test runner (src/golden.zig)
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // CLI runner
    //
    // `zig build nexis` produces bin/nexis. `zig build run -- run foo.nx`
    // builds + runs (forwards args after `--`).
    // -------------------------------------------------------------------------

    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("value", value_mod);
    cli_mod.addImport("vm", vm_mod);
    cli_mod.addImport("compile", compile_mod);
    cli_mod.addImport("reader", reader_mod);
    cli_mod.addImport("intern", intern_mod);
    cli_mod.addImport("expand", expand_mod);
    cli_mod.addImport("list", list_mod);
    cli_mod.addImport("vector", vector_mod);
    cli_mod.addImport("champ", champ_mod);
    cli_mod.addImport("stdlib", stdlib_mod);
    cli_mod.addImport("loader", loader_mod);
    // cli.formatValue prints strings via string.asBytes (display
    // mode, unquoted).
    cli_mod.addImport("string", string_mod);
    // cli delegates value-printing
    // to the central format.zig (display mode).
    cli_mod.addImport("format", format_mod);
    // `nexis disasm` prints routines through src/disasm.zig, which
    // reads Routine and the opcode decoders and is imported by the
    // CLI only.
    const disasm_mod = b.createModule(.{
        .root_source_file = b.path("src/disasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    disasm_mod.addImport("vm", vm_mod);
    disasm_mod.addImport("value", value_mod);
    disasm_mod.addImport("format", format_mod);
    disasm_mod.addImport("intern", intern_mod);
    cli_mod.addImport("disasm", disasm_mod);

    const nexis_exe = b.addExecutable(.{
        .name = "nexis",
        .root_module = cli_mod,
    });

    const install_nexis = b.addInstallArtifact(nexis_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis",
    });

    const run_nexis = b.addRunArtifact(nexis_exe);
    if (b.args) |args| run_nexis.addArgs(args);
    run_nexis.step.dependOn(&install_nexis.step);

    const nexis_step = b.step("nexis", "Build bin/nexis (the CLI runner)");
    nexis_step.dependOn(&install_nexis.step);

    const run_step = b.step("run", "Build and run nexis (forwards args after `--`)");
    run_step.dependOn(&run_nexis.step);

    // -------------------------------------------------------------------------
    // test/nextomic/*.nx — end-to-end Nextomic scripts run through the
    // nexis binary (NEXTOMIC.md §8). The scripts and their shared
    // prelude are copied into one generated directory that is also
    // their working directory, so the store files they create are
    // fresh whenever the binary or a script changes and the
    // persistence pair shares one file. Each script's stdout is
    // compared with its test/nextomic/<name>.out.
    // -------------------------------------------------------------------------

    const nextomic_nx_step = b.step("nextomic-nx", "Run the test/nextomic end-to-end scripts through bin/nexis");
    {
        const scripts = [_][]const u8{
            "basics",
            "indexes",
            "time",
            "errors",
            "query",
            "pull",
            "with",
            "with-conn",
            "polish",
            "datoms",
            "persist-1",
            "persist-2",
            "gc",
        };
        const scratch = b.addWriteFiles();
        // The binary is copied only so the directory's hash, and with
        // it the store files inside, changes when the binary does.
        _ = scratch.addCopyFile(nexis_exe.getEmittedBin(), "nexis");
        _ = scratch.addCopyFile(b.path("test/nextomic/prelude.nx"), "prelude.nx");
        for (scripts) |name| {
            _ = scratch.addCopyFile(b.path(b.fmt("test/nextomic/{s}.nx", .{name})), b.fmt("{s}.nx", .{name}));
        }
        var persist_1: ?*std.Build.Step = null;
        for (scripts) |name| {
            const expected = b.build_root.handle.readFileAlloc(
                b.graph.io,
                b.fmt("test/nextomic/{s}.out", .{name}),
                b.allocator,
                .limited(1 << 20),
            ) catch @panic("test/nextomic: missing expected-output file");
            const run = b.addRunArtifact(nexis_exe);
            run.addArg("run");
            run.addArg(b.fmt("{s}.nx", .{name}));
            run.setCwd(scratch.getDirectory());
            run.expectExitCode(0);
            run.expectStdOutEqual(expected);
            // gc.nx proves the collector inside query callbacks: it
            // runs with a cycle due every few kilobytes.
            if (std.mem.eql(u8, name, "gc")) run.setEnvironmentVariable("NEXIS_GC_STRESS", "1");
            // persist-2 reads what persist-1 wrote; every other script
            // owns its store.
            if (std.mem.eql(u8, name, "persist-1")) persist_1 = &run.step;
            if (std.mem.eql(u8, name, "persist-2")) run.step.dependOn(persist_1.?);
            nextomic_nx_step.dependOn(&run.step);
        }
    }

    // -------------------------------------------------------------------------
    // examples/*.nx — every example runs through the nexis binary from
    // a generated working directory (the store-backed ones write under
    // tmp/ relative to it). The three that keep a store run a second
    // time in the same directory to prove they are idempotent.
    // -------------------------------------------------------------------------

    const examples_step = b.step("examples", "Run every examples/*.nx through bin/nexis");
    {
        const examples = [_]struct { name: []const u8, twice: bool = false }{
            .{ .name = "hello" },
            .{ .name = "sum10" },
            .{ .name = "forward-ref" },
            .{ .name = "cond" },
            .{ .name = "threading" },
            .{ .name = "macros" },
            .{ .name = "quoted-list" },
            .{ .name = "syntax-quote" },
            .{ .name = "macro-author" },
            .{ .name = "try-catch" },
            .{ .name = "metadata" },
            .{ .name = "binding" },
            .{ .name = "maps-sets" },
            .{ .name = "defmacro" },
            .{ .name = "eval" },
            .{ .name = "stdlib-primitives" },
            .{ .name = "require-demo" },
            .{ .name = "shapes" },
            .{ .name = "shapes-app" },
            .{ .name = "typed-vectors" },
            .{ .name = "tests-demo" },
            .{ .name = "durable-refs", .twice = true },
            .{ .name = "todo-app", .twice = true },
            .{ .name = "nextomic-app", .twice = true },
        };
        const scratch = b.addWriteFiles();
        _ = scratch.addCopyFile(nexis_exe.getEmittedBin(), "nexis");
        for (examples) |ex| {
            var first: ?*std.Build.Step = null;
            const passes: usize = if (ex.twice) 2 else 1;
            for (0..passes) |pass| {
                const run = b.addRunArtifact(nexis_exe);
                run.addArg("run");
                run.addFileArg(b.path(b.fmt("examples/{s}.nx", .{ex.name})));
                run.setCwd(scratch.getDirectory());
                // Distinguishes the second pass's cache entry from the first's.
                run.setEnvironmentVariable("NEXIS_EXAMPLE_PASS", b.fmt("{d}", .{pass + 1}));
                run.expectExitCode(0);
                if (first) |f| run.step.dependOn(f);
                first = &run.step;
                examples_step.dependOn(&run.step);
            }
        }
    }

    const golden_mod = b.createModule(.{
        .root_source_file = b.path("src/golden.zig"),
        .target = target,
        .optimize = optimize,
    });
    const golden_exe = b.addExecutable(.{
        .name = "nexis-golden",
        .root_module = golden_mod,
    });

    const install_golden = b.addInstallArtifact(golden_exe, .{
        .dest_dir = .{ .override = .{ .custom = ".." } },
        .dest_sub_path = "bin/nexis-golden",
    });

    const run_golden = b.addRunArtifact(golden_exe);
    run_golden.addArg(if (update_golden) "--update" else "--verify");
    run_golden.addArg("test/golden");
    run_golden.step.dependOn(&install_golden.step);

    const golden_step = b.step("golden", "Run reader golden tests");
    golden_step.dependOn(&run_golden.step);

    // test/golden/cli — what bin/nexis prints for a script, pinned
    // byte for byte: a runtime error's stderr (`<name>.nx` +
    // `<name>.err`, exit 5), a disassembly's stdout (`.disasm`) and
    // a script's stdout (`.out`).
    // Each runs from the build root so the paths in the output are
    // the relative ones committed. To refresh an expected file, run
    // the command from the build root and redirect the stream it
    // pins.
    {
        const CliGolden = struct {
            verb: []const u8 = "run",
            file: []const u8,
            expected: []const u8,
            stream: enum { stdout, stderr } = .stdout,
            exit_code: u8 = 0,
        };
        const cases = [_]CliGolden{
            .{ .file = "test/golden/cli/divide-by-zero.nx", .expected = "divide-by-zero.err", .stream = .stderr, .exit_code = 5 },
            .{ .file = "test/golden/cli/uncaught-throw.nx", .expected = "uncaught-throw.err", .stream = .stderr, .exit_code = 5 },
            .{ .verb = "disasm", .file = "examples/sum10.nx", .expected = "sum10.disasm" },
            .{ .file = "test/golden/cli/pprint.nx", .expected = "pprint.out" },
        };
        for (cases) |case| {
            const expected = b.build_root.handle.readFileAlloc(
                b.graph.io,
                b.fmt("test/golden/cli/{s}", .{case.expected}),
                b.allocator,
                .limited(1 << 20),
            ) catch @panic("test/golden/cli: missing expected-output file");
            const run = b.addRunArtifact(nexis_exe);
            run.addArg(case.verb);
            run.addArg(case.file);
            run.expectExitCode(case.exit_code);
            switch (case.stream) {
                .stdout => run.expectStdOutEqual(expected),
                .stderr => run.expectStdErrEqual(expected),
            }
            golden_step.dependOn(&run.step);
        }
    }

    // -------------------------------------------------------------------------
    // Aggregate `zig build test` — everything
    // -------------------------------------------------------------------------

    const test_step = b.step("test", "Run everything: unit, property, golden, Nextomic corpora, test/nextomic scripts, examples");
    for (runtime_test_runs) |r| test_step.dependOn(&r.step);

    // -------------------------------------------------------------------------
    // `zig build quick` — the inner loop
    //
    // The language binaries (vm, compile, expand, stdlib, loader, atom,
    // record, protocol, format), the compile property tests, the
    // eval-pipeline integration tests and the Nextomic unit and
    // property binaries: seconds. The full `zig build test` adds the
    // randomized collection gates (minutes) and the end-to-end
    // scripts; run it before committing.
    //
    // A new language module joins by an entry in `runtime_test_files`
    // and the matching `runtime_test_runs[N]` line below.
    // -------------------------------------------------------------------------

    const quick_step = b.step("quick", "The inner loop: language, eval-pipeline and Nextomic unit + property binaries (seconds)");
    // Indices into runtime_test_files: atom = 11, record = 12,
    // protocol = 13, vm = 19, format = 20, compile = 21,
    // expand = 22, stdlib = 23, loader = 24. Asserted at build
    // time so re-ordering trips this loudly instead of silently
    // running the wrong tests.
    comptime {
        std.debug.assert(std.mem.eql(u8, runtime_test_files[11].name, "atom"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[12].name, "record"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[13].name, "protocol"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[19].name, "vm"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[20].name, "format"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[21].name, "compile"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[22].name, "expand"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[23].name, "stdlib"));
        std.debug.assert(std.mem.eql(u8, runtime_test_files[24].name, "loader"));
    }
    // Language binaries: atom + record + protocol +
    // vm + format + compile + expand + stdlib + loader.
    quick_step.dependOn(&runtime_test_runs[11].step);
    quick_step.dependOn(&runtime_test_runs[12].step);
    quick_step.dependOn(&runtime_test_runs[13].step);
    quick_step.dependOn(&runtime_test_runs[19].step);
    quick_step.dependOn(&runtime_test_runs[20].step);
    quick_step.dependOn(&runtime_test_runs[21].step);
    quick_step.dependOn(&runtime_test_runs[22].step);
    quick_step.dependOn(&runtime_test_runs[23].step);
    quick_step.dependOn(&runtime_test_runs[24].step);
    quick_step.dependOn(&runtime_test_runs[25].step);
    // Closure-capture and emitter property tests (COMPILER.md §9.4).
    quick_step.dependOn(&run_prop_compile_tests.step);
    // Eval-pipeline integration tests.
    quick_step.dependOn(&run_integration_eval_tests.step);
    quick_step.dependOn(&run_runtime_polish_tests.step);
    quick_step.dependOn(&run_numbers_tests.step);
    // Nextomic unit binaries and the key and transaction property tests.
    quick_step.dependOn(&run_nextomic_handle_tests.step);
    quick_step.dependOn(&run_nextomic_tests.step);
    quick_step.dependOn(&run_prop_nextomic_key_tests.step);
    quick_step.dependOn(&run_prop_nextomic_tx_tests.step);

    test_step.dependOn(&run_prop_primitive_tests.step);
    test_step.dependOn(&run_prop_intern_tests.step);
    test_step.dependOn(&run_prop_heap_tests.step);
    test_step.dependOn(&run_prop_string_tests.step);
    test_step.dependOn(&run_prop_list_tests.step);
    test_step.dependOn(&run_prop_bignum_tests.step);
    test_step.dependOn(&run_prop_vector_tests.step);
    test_step.dependOn(&run_prop_champ_tests.step);
    test_step.dependOn(&run_prop_gc_tests.step);
    test_step.dependOn(&run_prop_transient_tests.step);
    test_step.dependOn(&run_prop_codec_tests.step);
    test_step.dependOn(&run_prop_typed_vector_tests.step);
    test_step.dependOn(&run_prop_db_tests.step);
    test_step.dependOn(&run_nextomic_handle_tests.step);
    test_step.dependOn(&run_nextomic_tests.step);
    test_step.dependOn(nextomic_nx_step);
    test_step.dependOn(&run_prop_nextomic_key_tests.step);
    test_step.dependOn(&run_prop_nextomic_tx_tests.step);
    test_step.dependOn(&run_integration_nextomic_q_tests.step);
    test_step.dependOn(&run_integration_nextomic_pull_tests.step);
    test_step.dependOn(&run_integration_nextomic_fn_tests.step);
    test_step.dependOn(&run_integration_nextomic_entity_tests.step);
    test_step.dependOn(&run_prop_compile_tests.step);
    test_step.dependOn(&run_integration_eval_tests.step);
    test_step.dependOn(&run_runtime_polish_tests.step);
    test_step.dependOn(&run_numbers_tests.step);
    test_step.dependOn(&run_bench_tests.step);
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&run_golden.step);
    test_step.dependOn(examples_step);

    b.getInstallStep().dependOn(&install_golden.step);
    b.getInstallStep().dependOn(&install_nexis.step);
}
