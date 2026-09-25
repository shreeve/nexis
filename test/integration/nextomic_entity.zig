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
const stdlib = nx.stdlib;
const harness = @import("harness");

const testing = std.testing;

/// A program booted as `bin/nexis` boots one (test/harness.zig) over a
/// store under a fresh temporary directory; `@STORE@` in a program's
/// source names the store's path.
const Program = struct {
    program: harness.Program,
    store: harness.Store,

    fn init(self: *Program, name: []const u8) !void {
        return self.initWith(name, .{});
    }

    /// `init` with the collector due every few kilobytes.
    fn initUnderGc(self: *Program, name: []const u8) !void {
        return self.initWith(name, .{ .gc_stress = true });
    }

    fn initWith(self: *Program, name: []const u8, options: harness.Program.Options) !void {
        self.store = try harness.Store.init(name);
        errdefer self.store.deinit();
        try self.program.initWith(options);
    }

    fn deinit(self: *Program) void {
        self.program.deinit();
        self.store.deinit();
    }

    /// Run every top-level form of `src`, `@STORE@` replaced by the
    /// store path; the last form's value is the result.
    fn run(self: *Program, src: []const u8) !value_mod.Value {
        const text = try self.store.source(src);
        defer testing.allocator.free(text);
        return self.program.run(text);
    }

    /// `run`, printed through `format.zig` in display mode.
    fn runPrinted(self: *Program, src: []const u8, expected: []const u8) !void {
        try harness.expectResult(&self.program, src, try self.run(src), expected);
    }
};

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
    try testing.expect(p.program.v.gc_cycles > 0);
}
