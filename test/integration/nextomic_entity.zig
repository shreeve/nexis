//! test/integration/nextomic_entity.zig — the lazy entity through the
//! whole pipeline (docs/NEXTOMIC.md §6): a program runs source against
//! a VM with core, `db` and `nextomic` installed, and every access
//! path of `entity` is checked as a program sees it. The collector
//! case runs the VM under the stress policy (`vm.GcPolicy.stress`),
//! so an entity kept in a Var lives across many cycles and still
//! reads.

const std = @import("std");
const nx = @import("nexis");
const value_mod = nx.value;
const vm = nx.vm;
const compile = nx.compile;
const intern_mod = nx.intern;
const reader_mod = nx.reader;
const expand_mod = nx.expand;
const stdlib = nx.stdlib;
const format_mod = nx.format;

const testing = std.testing;

/// A VM with core, `db`, `nexis.internal` and `nextomic` installed and
/// core.nx bootstrapped, over a store under a fresh temporary
/// directory; `@STORE@` in a program's source names the store's path.
const Program = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    store: []u8,
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    hooks: compile.RuntimeHooks,
    registry: *vm.NamespaceRegistry,
    interner: *intern_mod.Interner,

    const stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };

    fn init(self: *Program, name: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        errdefer self.arena.deinit();
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.store = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/{s}.emdb", .{ self.tmp.sub_path, name });
        errdefer testing.allocator.free(self.store);
        self.v = try vm.VM.init(testing.allocator, &stub);
        errdefer self.v.deinit();
        self.interner = self.v.ensureInterner();
        self.registry = try self.v.ensureRegistry();
        try stdlib.installCore(self.registry.core);
        const db_ns = try self.registry.getOrCreate("db", self.registry.core);
        try stdlib.installDb(db_ns);
        const internal_ns = try self.registry.getOrCreate("nexis.internal", self.registry.core);
        try stdlib.installInternal(internal_ns);
        const nextomic_ns = try self.registry.getOrCreate("nextomic", self.registry.core);
        try stdlib.installNextomic(nextomic_ns);
        self.host_macros = try expand_mod.defaultMacros(testing.allocator);
        errdefer self.host_macros.deinit(testing.allocator);
        const saved_current = self.registry.current;
        self.registry.current = self.registry.core;
        try bootstrapEmbedded(&self.v, self.registry.core, stdlib.CORE_NX_SOURCE, self.interner, &self.host_macros);
        self.registry.current = saved_current;
        self.hooks = .{ .host_macros = &self.host_macros, .registry = self.registry, .interner = self.interner };
        self.hooks.install(&self.v);
    }

    /// `init` with the collector due every few kilobytes.
    fn initUnderGc(self: *Program, name: []const u8) !void {
        try self.init(name);
        self.v.gc_threshold = vm.GcPolicy.stress.threshold;
        self.v.gc_growth_percent = vm.GcPolicy.stress.growth_percent;
        self.v.gc_next_at = vm.GcPolicy.stress.threshold;
    }

    fn deinit(self: *Program) void {
        self.host_macros.deinit(testing.allocator);
        self.v.deinit();
        testing.allocator.free(self.store);
        self.tmp.cleanup();
        self.arena.deinit();
    }

    /// Run every top-level form of `src`, `@STORE@` replaced by the
    /// store path; the last form's value is the result.
    fn run(self: *Program, src: []const u8) !value_mod.Value {
        const text = try std.mem.replaceOwned(u8, testing.allocator, src, "@STORE@", self.store);
        defer testing.allocator.free(text);
        var parse_result = try reader_mod.parser.parseProgram(testing.allocator, text);
        defer parse_result.parser.deinit();
        var rdr = reader_mod.Reader.init(testing.allocator, text);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parse_result.sexp);
        var last: value_mod.Value = value_mod.nilValue();
        for (forms) |form| {
            const compiled = try compile.compileFormFullWithMacrosSpanPersistentRegistryLoader(
                self.arena.allocator(),
                form,
                self.registry.current,
                self.interner,
                &self.host_macros,
                null,
                self.v.runtime_arena.allocator(),
                self.registry,
                null,
                null,
            );
            const routine = compiled.toRoutine("test-form");
            try self.v.retargetTop(&routine);
            last = try self.v.run();
        }
        return last;
    }

    /// `run`, printed through `format.zig` in display mode.
    fn runPrinted(self: *Program, src: []const u8, expected: []const u8) !void {
        const result = try self.run(src);
        var w = std.Io.Writer.Allocating.init(testing.allocator);
        defer w.deinit();
        try format_mod.format(result, .display, &w.writer, self.interner);
        testing.expectEqualStrings(expected, w.written()) catch |err| {
            std.debug.print("\n  source:   {s}\n  expected: {s}\n  actual:   {s}\n", .{ src, expected, w.written() });
            return err;
        };
    }
};

fn bootstrapEmbedded(
    v: *vm.VM,
    ns: *vm.Namespace,
    source: []const u8,
    interner: *intern_mod.Interner,
    host_macros: *const expand_mod.HostMacroTable,
) !void {
    var parse_result = try reader_mod.parser.parseProgram(testing.allocator, source);
    defer parse_result.parser.deinit();
    var rdr = reader_mod.Reader.init(testing.allocator, source);
    defer rdr.deinit();
    const forms = try rdr.readProgram(parse_result.sexp);
    const ra = v.runtime_arena.allocator();
    for (forms) |form| {
        const compiled = try compile.compileFormFullWithMacrosSpanPersistent(ra, form, ns, interner, host_macros, null, ra);
        const routine = compiled.toRoutine("core-nx-test");
        try v.retargetTop(&routine);
        _ = try v.run();
    }
}

/// A connection, a schema and two people: Ann with a component home,
/// tags and a friend, Bob with a friend. `ann`, `bob`, `home` are
/// their eids; `db` the db-value after the load; `ent` Ann's entity.
const setup =
    \\(def c (nextomic/connect "@STORE@"))
    \\(nextomic/transact! c [{:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
    \\                       {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one :db/unique :db.unique/identity}
    \\                       {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
    \\                       {:db/ident :person/tags :db/valueType :db.type/keyword :db/cardinality :db.cardinality/many}
    \\                       {:db/ident :person/friends :db/valueType :db.type/ref :db/cardinality :db.cardinality/many}
    \\                       {:db/ident :person/home :db/valueType :db.type/ref :db/cardinality :db.cardinality/one :db/isComponent true}
    \\                       {:db/ident :addr/city :db/valueType :db.type/string :db/cardinality :db.cardinality/one}])
    \\(def r (nextomic/transact! c [{:db/id "ann" :person/name "Ann" :person/email "ann@x" :person/age 41 :person/tags [:staff :admin]
    \\                               :person/home {:addr/city "Rome"} :person/friends ["bob"]}
    \\                              {:db/id "bob" :person/name "Bob" :person/email "bob@x" :person/friends ["ann"]}]))
    \\(def ann (get (:tempids r) "ann"))
    \\(def bob (get (:tempids r) "bob"))
    \\(def db (nextomic/db c))
    \\(def ent (nextomic/entity db ann))
    \\(def home (:db/id (:person/home ent)))
    \\(defmacro caught [& body] `(try (do ~@body :no-error) (catch any e# e#)))
    \\
;

test "every access path reads the entity's view" {
    var p: Program = undefined;
    try p.init("entity_access");
    defer p.deinit();
    try p.runPrinted(setup ++
        \\[(:person/name ent) (get ent :person/name) (get ent :person/nope :none) (:person/nope ent) (get ent "x" :d)
        \\ (= ann (:db/id ent)) (:person/tags ent)
        \\ (contains? ent :person/name) (contains? ent :person/nope) (contains? ent :db/id) (contains? ent :person/age)
        \\ (sort (keys ent)) (count ent) (empty? ent) (map? ent)
        \\ (= (sort (keys ent)) (sort (map first (seq ent))))
        \\ (= (count ent) (count (vals ent)) (count (into {} ent)))
        \\ (= "Ann" (:person/name (into {} ent)))
        \\ (reduce (fn [n [k v]] (inc n)) 0 ent)]
    , "[Ann Ann :none nil :d true #{:staff :admin} true false true true (:db/id :person/age :person/email :person/friends :person/home :person/name :person/tags) 7 false false true true true 7]");
}

test "a ref reads as a lazy entity of the same view; touch keeps the eid" {
    var p: Program = undefined;
    try p.init("entity_refs");
    defer p.deinit();
    const ref = try p.run(setup ++ "(:person/home ent)");
    try testing.expectEqual(value_mod.Kind.nextomic_entity, ref.kind());
    try p.runPrinted(
        \\[(:addr/city (:person/home ent))
        \\ (= (:person/home ent) (nextomic/entity db home))
        \\ (= db (nextomic/entity-db (:person/home ent)))
        \\ (map :person/name (:person/friends ent))
        \\ (= #{bob} (set (map :db/id (:person/friends ent))))
        \\ (= (:person/home (into {} ent)) (:person/home ent))
        \\ (= home (:person/home (nextomic/touch ent)))
        \\ (= #{bob} (:person/friends (nextomic/touch ent)))]
    , "[Rome true true (Bob) true true true true]");
}

test "touch is the eager map; an entity with no datoms is nil" {
    var p: Program = undefined;
    try p.init("entity_touch");
    defer p.deinit();
    try p.runPrinted(setup ++
        \\[(= (nextomic/touch ent) {:db/id ann :person/name "Ann" :person/email "ann@x" :person/age 41
        \\                          :person/tags #{:staff :admin} :person/home home :person/friends #{bob}})
        \\ (= (nextomic/touch (nextomic/entity db [:person/email "bob@x"])) {:db/id bob :person/name "Bob" :person/email "bob@x" :person/friends #{ann}})
        \\ (nextomic/entity db 4294967999) (nextomic/entity db [:person/email "zed@x"])
        \\ (caught (nextomic/entity (nextomic/history db) ann))
        \\ (caught (nextomic/touch db)) (caught (nextomic/entity-db 1)) (caught (assoc ent :person/name "x"))
        \\ (nextomic/touch (nextomic/entity db :person/name))]
    , "[true true nil nil :nextomic/history-view :kind-mismatch :kind-mismatch :kind-mismatch {:db/id 23, :db/ident :person/name, :db/valueType :db.type/string, :db/cardinality :db.cardinality/one}]");
}

test "entities are values over their db-value and eid" {
    var p: Program = undefined;
    try p.init("entity_identity");
    defer p.deinit();
    try p.runPrinted(setup ++
        \\(def db-later (:db-after (nextomic/transact! c [[:db/add ann :person/age 42]])))
        \\[(= ent (nextomic/entity db ann)) (= ent (nextomic/entity db bob)) (= ent (nextomic/entity db-later ann))
        \\ (= ent (nextomic/entity (nextomic/as-of db-later (nextomic/basis-t db)) ann))
        \\ (count (into #{} [ent (nextomic/entity db ann) (nextomic/entity db bob) (nextomic/entity db-later ann)]))
        \\ (get {ent :here} (nextomic/entity db ann))
        \\ (:person/age ent) (:person/age (nextomic/entity db-later ann))
        \\ (str ent)]
    , "[true false false false 3 :here 41 42 #nextomic/entity {:db/id 4294967296}]");
}

test "a released connection makes every access :nextomic/closed" {
    var p: Program = undefined;
    try p.init("entity_closed");
    defer p.deinit();
    try p.runPrinted(setup ++
        \\(def friend (first (:person/friends ent)))
        \\(nextomic/release c)
        \\[(caught (:person/name ent)) (caught (get ent :person/name)) (caught (contains? ent :person/name))
        \\ (caught (keys ent)) (caught (seq ent)) (caught (count ent)) (caught (into {} ent))
        \\ (caught (nextomic/touch ent)) (caught (:person/name friend)) (:db/id ent) (caught (nextomic/entity db ann))]
    , "[:nextomic/closed :nextomic/closed :nextomic/closed :nextomic/closed :nextomic/closed :nextomic/closed :nextomic/closed :nextomic/closed :nextomic/closed 4294967296 :nextomic/closed]");
}

test "a with view's entity is closed after the scope" {
    var p: Program = undefined;
    try p.init("entity_with");
    defer p.deinit();
    try p.runPrinted(setup ++
        \\(def escaped (atom nil))
        \\(def inside (nextomic/with c [[:db/add ann :person/age 50]]
        \\              (fn [db-after report]
        \\                (reset! escaped (nextomic/entity db-after ann))
        \\                (:person/age @escaped))))
        \\[inside (caught (:person/age @escaped)) (:person/age ent)]
    , "[50 :nextomic/closed 41]");
}

test "an entity kept in a Var reads across collections" {
    var p: Program = undefined;
    try p.initUnderGc("entity_gc");
    defer p.deinit();
    try p.runPrinted(setup ++
        \\(defn churn [x] (count (apply str (map (fn [i] (str x i)) (range 200)))))
        \\(def names (mapv (fn [i] (churn i) (:person/name ent)) (range 40)))
        \\(def cities (mapv (fn [i] (churn i) (:addr/city (:person/home ent))) (range 40)))
        \\(def friends (mapv (fn [i] (churn i) (map :person/name (:person/friends ent))) (range 40)))
        \\(def entries (mapv (fn [[k v]] (churn k) k) ent))
        \\(def touched (mapv (fn [i] (churn i) (nextomic/touch ent)) (range 20)))
        \\[(count (set names)) (first names) (count (set cities)) (first cities) (count (set friends)) (first friends)
        \\ (count entries) (count (set touched)) (= ent (nextomic/entity db ann)) (count ent)]
    , "[1 Ann 1 Rome 1 (Bob) 7 1 true 7]");
    try testing.expect(p.v.gc_cycles > 0);
}
