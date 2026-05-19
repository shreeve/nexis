## PROTOCOLS.md — Records + Protocols (Phase 5 Item 3, design phase)

**Status**: Phase 5 Item 3 design freeze. Authoritative contract for
the runtime-side `Kind.record = 35`, `Kind.protocol = 36`,
`Kind.protocol_fn = 37` (introduced in this item) and the
language-surface `defprotocol` / `defrecord` / `extend-protocol` /
`extend-type` / `satisfies?` macros. Derivative from `PLAN.md`
Amendment Log (protocols-and-records entry; lands with `5.3a`),
`HANDOFF.md` §10.3, `docs/VALUE.md` §2.2, `docs/SEMANTICS.md` §2.6
(structural-equality category extension), and peer-AI turns 74 + 84.
Those documents win on conflict.

This is the **design phase** of Item 3. No code lands with this
commit — only the spec + hand-trace + the PLAN.md amendment that
unblocks the four `5.3a` – `5.3d` implementation commits.

Per HANDOFF §12 #9 + the project's spec-first discipline, the
hand-trace below is required before any code is written for this
item. The closure-design hand-trace (Phase 2 turn 34) caught three
load-bearing bugs; the variadic-rest hand-trace (Phase 2 turn 49)
caught the Option-D construction order. Protocols/records is the
only Phase 5 item complex enough to repeat that pattern.

---

### 0. v1 boundary commitments

What ships in v1 (Items 5.3a–d):

- `Kind.record = 35` — one heap kind for all record types; the
  `RecordTypeId` lives in the heap body, NOT as a separate Kind.
  Structural equality + structural hash by `(type_id, field_map)`.
- `Kind.protocol = 36` — opaque protocol handle. Identity equality;
  not serializable; user code holds them only as Var roots.
- `Kind.protocol_fn = 37` — opaque dispatcher handle. Identity
  equality. Carries `(protocol_id, method_name_id)` so the
  generic dispatcher knows what to look up. Distinct from
  `Kind.native_fn` because `NativeFn` is a static descriptor with
  no per-method state (peer-AI turn 84 §"Big missing implementation
  concern").
- `defprotocol`, `defrecord`, `extend-protocol`, `extend-type`,
  `satisfies?` — host macros + native dispatch fns.
- `(->Counter n)` positional constructor; `(map->Counter {:n 1})`
  map constructor; `Counter?` predicate.
- `(get rec :k)`, `(:k rec)`, `(assoc rec :k v)`, `(dissoc rec :k)`,
  `(contains? rec :k)`, `(keys rec)`, `(vals rec)` — records behave
  map-like for these.
- Built-in dispatch types for `extend-protocol`: `Nil`, `Boolean`,
  `Number` (fixnum only in v1; documented), `String`, `Keyword`,
  `Symbol`, `List`, `Vector`, `Map`, `Set`, `Atom`, plus `Any` /
  `Object` for the default fallback.

What is explicitly OUT of v1 (deferred):

- `Counter.` (dot-suffix) reader syntax — `->Counter` is sufficient.
- `:>>` thread-result-through-fn syntax in `condp`'s sibling
  positions (already deferred from 5.4).
- Records / protocols in the codec serializable set — both throw
  `:unserializable` (matches PLAN §23 #25 + the protocol/record
  unserializability per turn 84).
- Inline-cache dispatch for protocol method calls (Phase 6 perf).
- User-extensible protocols across namespaces with hot-swap
  semantics — single-isolate v1 means redefinition is well-behaved
  but cross-isolate semantics don't apply.
- Duplicate record/protocol name redefinition — REJECTED with a
  clear error (peer-AI turn 84 § "Redefinition"); avoiding the
  confusing-state hazard.
- Numeric tower beyond fixnum mapping to `Number` — when bignum/
  float gain `extend-protocol` support, they get their own dispatch
  type names.

---

### 1. PLAN.md amendment context

`PLAN.md` §23 #8 says "No user protocols in v1. Built-in
polymorphism only." Appendix A repeats "Protocols — Removed in v1".

This is the same shape as the Phase 5.1 atoms situation. The §23
frozen-decision text remains intact; the Amendment Log entry
(landing with `5.3a`) IS the authority record:

```
- 2026-05-19 — Protocols + records (Phase 5 Item 3) added.
  §23 #8 ("No user protocols in v1") and Appendix A
  ("Protocols — Removed in v1") were v1-scoping decisions
  pre-Phase-5; the HANDOFF.md §10.3 Phase 5 framing (peer-AI
  turn 74) and the design freeze below (turn 84) reframe these
  as Phase 5 scope additions, not changes to architecturally
  load-bearing decisions. v1 keeps its other §23 #5 constraint
  (single-isolate, single-threaded), so protocols here are
  static-dispatch + per-VM registries; no STM, no agents,
  no concurrency. Authority: peer-AI turn 84. See
  `docs/PROTOCOLS.md` for the full spec + hand-trace.
```

`5.3a` lands the amendment + the runtime substrate. `5.3b–d`
build on that without further PLAN amendments unless a real
contradiction surfaces.

---

### 2. Storage model

#### 2.1 `Kind.record = 35`

```zig
RecordValue {
    type_id: u32,                     // dense index into VM.record_registry
    fields: Value (persistent_map),   // keyword → value
}
```

- **`type_id` is a per-VM dense `u32`**, NOT a pointer. Stable
  across allocations within a VM; not stable across VMs (single
  isolate = irrelevant) and not stable across serialization
  (records are unserializable in v1).
- **`fields` is a `Kind.persistent_map`** — CHAMP/array-map per
  CHAMP.md. Keys are keywords (or symbols, for completeness).
  Extra keys not in the declared field list are ALLOWED (peer-AI
  turn 84 §D4 "Extra keys"); the declared list is constructor
  metadata, not a storage restriction.

**Equality** (kind-local, structural):

```
equal(record_a, record_b) :=
    record_a.type_id == record_b.type_id
        AND equal(record_a.fields, record_b.fields)
```

**Hash** (kind-local, structural):

```
hash(record) := mixKindDomain(combine(type_id_hash, field_map_hash), 35)
```

Two `(->Counter 5)` instances are `=` regardless of which `->Counter`
call produced them. Records-as-map-keys WORK because hash + equality
are structural.

**Codec**: records throw `:unserializable` (same arm as functions /
Vars / atoms / etc.).

**GC trace**: walk `fields`. The `type_id` is a `u32`, not a heap
pointer.

#### 2.2 `Kind.protocol = 36`

```zig
ProtocolValue {
    id: u32,           // dense index into VM.protocol_registry
    name_id: u32,      // interned symbol id (qualified name)
}
```

- **Opaque heap kind.** User code holds these as Var roots.
- **Identity equality** (pointer-to-heap-header). Two `IFoo`
  references resolve to the same Var → same protocol value.
- **Unserializable.**
- **Format**: `#<protocol my.ns/IFoo>` in both display and
  readable modes (turn 84 § "Format" — opaque, not pretending
  to be reader-roundtrippable).

The protocol's METHOD TABLE lives in `VM.protocol_registry[id]`,
not in the heap body — that way mutation via `extend-protocol`
doesn't have to clone the protocol Value.

#### 2.3 `Kind.protocol_fn = 37`

```zig
ProtocolFnValue {
    protocol_id: u32,
    method_name_id: u32,    // interned symbol id of the method name
}
```

- **Opaque heap kind.** User code obtains these by deref'ing the
  Var that `defprotocol` registers per method (e.g. `bar` is a
  Var whose root is a `protocol_fn` with the right `(protocol_id,
  method_name_id)`).
- **Identity equality.**
- **Unserializable.**
- **Format**: `#<protocol-fn my.ns/IFoo/bar>`.
- **Call dispatch**: `call:call` on a `protocol_fn` routes to a
  generic VM helper `dispatchProtocolMethod(vm, protocol_id,
  method_name_id, args)` which walks
  `VM.protocol_registry[protocol_id].methods[method_name_id].impls[dispatch_key(args[0])]`
  and invokes the resulting closure / native_fn / fn.

Peer-AI turn 84 §"Big missing implementation concern": this is the
key insight. `NativeFn` is a static descriptor with `{name, min_arity,
max_arity, fn_ptr}` — no per-instance state. Protocol dispatchers
NEED to know which protocol + which method they belong to. A
fresh `Kind.protocol_fn` with that state in the payload is the
cleanest fix, isolated from `NativeFn`'s static-descriptor design.

---

### 3. VM-side registries

The VM grows two new lazy-init fields:

```zig
record_registry: ?std.ArrayList(RecordType) = null,
protocol_registry: ?std.ArrayList(ProtocolEntry) = null,
```

where:

```zig
RecordType {
    id: u32,                       // dense, == index into the ArrayList
    ns_name: []const u8,           // qualified namespace name
    type_name: []const u8,         // short name (e.g. "Counter")
    declared_fields: []const u32,  // interned keyword ids in declared order
}

ProtocolEntry {
    id: u32,
    ns_name: []const u8,
    name: []const u8,
    methods: std.StringHashMapUnmanaged(MethodSpec),
}

MethodSpec {
    name: []const u8,
    arity: u16,                    // arity including `this`
    impls: std.AutoHashMapUnmanaged(DispatchKey, Value),  // each Value is a fn
    default_impl: ?Value = null,
}

DispatchKey = union(enum) {
    builtin_kind: Value.Kind,      // for extend-protocol on Map / String / etc.
    record_type: u32,              // RecordType.id
    any,                           // Object / Any fallback
};
```

`VM.deinit` frees both registries (the ArrayList + the per-Method
maps). Names are owned by the registries (duped on registration).

#### 3.1 Lifetime + redefinition

Per peer-AI turn 84 §"Redefinition":

- Defining a record type with a name that's already in
  `record_registry` for the same `(ns, name)` → reject with
  `:record-redefinition`. Avoids the confusing-state hazard
  where existing instances reference an old type_id.
- Defining a protocol with an existing `(ns, name)` → same
  treatment: `:protocol-redefinition`.
- Adding new impls to an existing protocol via
  `extend-protocol` / `defrecord` is allowed (that's the whole
  point of those macros). Mutation of an existing impl for the
  same `(protocol_id, method, dispatch_key)` triple → overwrite
  silently (Clojure-canonical behavior; users redefining at the
  REPL is the common case).

---

### 4. Macros

All four are host macros in `src/expand.zig` next to `defmacro` /
`defn`. They expand to combinations of `def` + native-fn
registrations + RecordType / Protocol registry calls.

#### 4.1 `defprotocol`

```clojure
(defprotocol IFoo
  (bar [this x])
  (baz [this x y]))
```

Expansion (effective shape; actual emits use synthetic gensyms):

```clojure
(do
  ;; Register the protocol in VM.protocol_registry.
  (def IFoo  (#%register-protocol "my.ns/IFoo"
                                  ["bar" 2]
                                  ["baz" 3]))
  ;; Each method gets a Var whose root is a `Kind.protocol_fn`.
  (def bar (#%protocol-fn IFoo "bar"))
  (def baz (#%protocol-fn IFoo "baz")))
```

`#%register-protocol` and `#%protocol-fn` are internal native fns
exposed only via the expansion. They're not part of the user
surface.

#### 4.2 `defrecord`

```clojure
(defrecord Counter [n]
  IFoo
  (bar [this x] (assoc this :n (+ x (:n this))))
  (baz [this x y] [:counter (+ x y)]))
```

Expansion:

```clojure
(do
  ;; Register the record type; gets a fresh type_id.
  (def ^:record-type-id Counter-type-id
       (#%register-record-type "my.ns/Counter" [:n]))
  ;; Positional constructor.
  (defn ->Counter [n]
    (#%make-record Counter-type-id {:n n}))
  ;; Map constructor.
  (defn map->Counter [m]
    (#%make-record Counter-type-id m))
  ;; Predicate.
  (defn Counter? [x]
    (and (#%record? x)
         (= Counter-type-id (#%record-type-id x))))
  ;; Per-protocol impls registered into the protocol's method table.
  (#%register-protocol-impl IFoo "bar"
                            (record-type Counter-type-id)
                            (fn [this x] (assoc this :n (+ x (:n this)))))
  (#%register-protocol-impl IFoo "baz"
                            (record-type Counter-type-id)
                            (fn [this x y] [:counter (+ x y)])))
```

`#%register-record-type`, `#%make-record`, `#%record?`,
`#%record-type-id`, `#%register-protocol-impl`, `(record-type ...)`
are internal native fns / forms — emitted only by the macro layer.

The `assoc this :n (...)` inside the body works because records
are map-like for `get` / `assoc` / `dissoc`. The returned value
from `assoc` is a NEW record of the same type with an updated
field map (NOT a plain map).

#### 4.3 `extend-protocol` / `extend-type`

```clojure
(extend-protocol IFoo
  Map
  (bar [m x] (assoc m :extended x))
  (baz [m x y] [:map x y]))

(extend-type Map
  IFoo
  (bar [m x] (assoc m :extended x))
  (baz [m x y] [:map x y]))
```

Both expand to:

```clojure
(do
  (#%register-protocol-impl IFoo "bar"
                            (builtin-kind :persistent-map)
                            (fn [m x] (assoc m :extended x)))
  (#%register-protocol-impl IFoo "baz"
                            (builtin-kind :persistent-map)
                            (fn [m x y] [:map x y])))
```

Built-in dispatch type names (resolved at expand time):

| Name | Maps to |
|---|---|
| `Nil` | `.nil` |
| `Boolean` | `.true_` and `.false_` (both) |
| `Number` | `.fixnum` (v1 only; document) |
| `String` | `.string` |
| `Keyword` | `.keyword` |
| `Symbol` | `.symbol` |
| `Char` | `.char` |
| `List` | `.list` |
| `Vector` | `.persistent_vector` |
| `Map` | `.persistent_map` |
| `Set` | `.persistent_set` |
| `Atom` | `.atom` |
| `Any` / `Object` | default fallback (`DispatchKey.any`) |

Unknown type names → `:unknown-dispatch-type` at expansion time.

#### 4.4 `satisfies?`

```clojure
(satisfies? IFoo (Counter. 5))   ; => true
(satisfies? IFoo 42)              ; => false (unless Number was extended)
```

Implementation: for the receiver's dispatch key (record_type or
Kind), walk every method in the protocol and verify there's an
impl (or a default). All-present → true, any-missing → false.

Zero-method protocols → always true (degenerate but well-defined).

---

### 5. Dispatch flow (the hand-trace)

This is the load-bearing section. The hand-trace walks `(bar
(->Counter 5))` end-to-end through reader → expand → compile →
VM, with EVERY step annotated. Per HANDOFF §12 #9, this catches
spec holes before any code can violate them.

#### 5.1 Source

```clojure
(do
  (defprotocol IFoo
    (bar [this x]))
  (defrecord Counter [n]
    IFoo
    (bar [this x] (+ x (:n this))))
  (bar (->Counter 5) 7))
```

Expected result: `12`.

#### 5.2 Reader output

```text
(do
  (defprotocol IFoo (bar [this x]))
  (defrecord Counter [n] IFoo (bar [this x] (+ x (:n this))))
  (bar (->Counter 5) 7))
```

A 4-element list of forms: `do`, `defprotocol`-form,
`defrecord`-form, call-form.

#### 5.3 Expand pass

##### 5.3.a `defprotocol`

```text
(defprotocol IFoo (bar [this x]))
→
(do
  (def IFoo (#%register-protocol "user/IFoo" ["bar" 2]))
  (def bar  (#%protocol-fn IFoo "bar")))
```

After execution:
- `VM.protocol_registry[0]` exists, named `user/IFoo`, with
  one method `bar` (arity 2).
- The `IFoo` Var's root is a `Kind.protocol` Value carrying
  `{ id: 0, name_id: <intern("user/IFoo")> }`.
- The `bar` Var's root is a `Kind.protocol_fn` Value carrying
  `{ protocol_id: 0, method_name_id: <intern("bar")> }`.

##### 5.3.b `defrecord`

```text
(defrecord Counter [n]
  IFoo
  (bar [this x] (+ x (:n this))))
→
(do
  (def Counter-type-id
       (#%register-record-type "user/Counter" [:n]))
  (defn ->Counter [n]
    (#%make-record Counter-type-id {:n n}))
  (defn map->Counter [m]
    (#%make-record Counter-type-id m))
  (defn Counter? [x]
    (and (#%record? x)
         (= Counter-type-id (#%record-type-id x))))
  (#%register-protocol-impl IFoo "bar"
                            (record-type Counter-type-id)
                            (fn [this x] (+ x (:n this)))))
```

After execution:
- `VM.record_registry[0]` exists with `{ id: 0, ns_name: "user",
  type_name: "Counter", declared_fields: [<:n keyword id>] }`.
- `Counter-type-id` Var's root is `Value.fromFixnum(0).?`.
- `->Counter` / `map->Counter` / `Counter?` Vars hold compiled
  closures.
- `VM.protocol_registry[0].methods["bar"].impls[.record_type(0)]`
  is the closure for `(fn [this x] (+ x (:n this)))`.

##### 5.3.c Call site

```text
(bar (->Counter 5) 7)
```

No macro expansion needed — this is a plain call form. After
expand, the form is unchanged.

#### 5.4 Compile

Compile yields bytecode for the `do`. The interesting bit is the
call `(bar (->Counter 5) 7)`:

1. Compile `(->Counter 5)`. `->Counter` is a Var; the compiler
   emits `var:load-var` then `call:call` with argc=1.
2. Compile `7` as a literal load.
3. Compile `bar` as a Var; emit `var:load-var`.
4. Emit `call:call` for the outer call, argc=2.

At runtime:

- Slot[X+0] = `bar` Var's root → `Kind.protocol_fn` Value
- Slot[X+1] = `(->Counter 5)` result → `Kind.record` Value
- Slot[X+2] = `7` → `Kind.fixnum` Value

#### 5.5 VM dispatch

`call:call` execution path:

```text
callee_kind := slot[X+0].kind()
switch callee_kind:
    .function       → existing Closure dispatch
    .native_fn      → existing NativeFn dispatch
    .protocol_fn    → dispatchProtocolMethod(vm, slot[X+0], &slot[X+1..X+1+argc])
    else            → :not-callable
```

`dispatchProtocolMethod(vm, fn_value, args)`:

```text
pfn         := asProtocolFn(fn_value)        // {protocol_id, method_name_id}
proto       := vm.protocol_registry[pfn.protocol_id]
method      := proto.methods[interner.name(pfn.method_name_id)]
            or throw :no-protocol-method

if args.len < method.arity → throw :arity-mismatch
receiver    := args[0]
dkey        := dispatchKeyFor(receiver)      // record_type, builtin_kind, or any
impl        := method.impls[dkey]
            or method.impls[.any]
            or method.default_impl
            or throw :no-protocol-impl

return vm.callValue(impl, args)
```

`dispatchKeyFor(v)`:
```text
if v.kind() == .record:
    return .record_type(asRecord(v).type_id)
return .builtin_kind(v.kind())
```

#### 5.6 Worked numbers for `(bar (->Counter 5) 7)`

1. `(->Counter 5)` runs:
   - `->Counter` Var → its root is a closure.
   - Closure body calls `(#%make-record 0 {:n 5})`.
   - Result: `Kind.record` Value carrying `{type_id: 0, fields:
     {:n 5}}`.

2. `(bar <record> 7)` runs:
   - `bar` Var → `Kind.protocol_fn` Value `{protocol_id: 0,
     method_name_id: <intern("bar")>}`.
   - `call:call` sees `.protocol_fn` → routes to
     `dispatchProtocolMethod`.
   - `dispatchKeyFor(<record>)` → `.record_type(0)`.
   - Lookup: `protocol_registry[0].methods["bar"].impls[.record_type(0)]`
     → the `(fn [this x] (+ x (:n this)))` closure.
   - `vm.callValue(impl, [<record>, 7])` runs the closure:
     - `this` = the record. `x` = 7.
     - `(:n this)` = 5.
     - `(+ x (:n this))` = `(+ 7 5)` = `12`.
   - Return `12`.

3. The outer `do` returns the result of its last subform → `12`. ✓

#### 5.7 What the hand-trace surfaces

Holes / decisions pinned by walking through:

- `#%register-protocol` returns a `Kind.protocol` Value with the
  protocol's id — needed by the `(#%protocol-fn IFoo "bar")` form
  immediately below in the same `do`. The id is captured at
  registration time.
- `#%register-record-type` returns a fixnum (the type_id) so the
  `->Counter` constructor body can reference it as an ordinary
  value. Stored in a Var.
- `#%register-protocol-impl` takes the protocol VALUE (not Var),
  the method NAME (string), and a DispatchKey (either
  `(record-type <type-id-value>)` or `(builtin-kind <kw>)`).
- The dispatcher's `call:call` arm must fire BEFORE the
  `:not-callable` fallback; this means `Kind.protocol_fn` joins
  `.function` and `.native_fn` as the three callable kinds.
- `Kind.record`'s field-map operations (`get`, `assoc`, `dissoc`,
  `:k` keyword-as-fn) must route through the record's field
  map; `assoc` on a record returns a record (same type_id), NOT
  a plain map.
- All five `#%`-prefixed internal forms need to be in
  `compile.zig`'s special-form set or as native-fn calls. Lean:
  native fns installed in the `#nexis.internal` namespace (NOT
  auto-referred); macros emit fully-qualified calls. Cleaner
  than special-form extensions.

---

### 6. Errors (catchable keywords)

| Keyword | Source |
|---|---|
| `:no-protocol-method` | Calling a method-name not defined on the protocol |
| `:no-protocol-impl` | Receiver kind has no impl + no default |
| `:not-a-record` | Operations expecting a record receiver got something else |
| `:record-redefinition` | `defrecord` with an existing `(ns, name)` |
| `:protocol-redefinition` | `defprotocol` with an existing `(ns, name)` |
| `:unknown-dispatch-type` | `extend-protocol`/`extend-type` referenced an unknown type name |
| `:arity-mismatch` | Protocol method called with wrong number of args |
| `:kind-mismatch` | `Counter?` predicate-style fns getting non-record |

---

### 7. Implementation sub-commit split (per peer-AI turn 84)

- **5.3a — records substrate + PLAN amendment.**
  Lands `Kind.record = 35`, the record registry, `->Counter` /
  `map->Counter` / `Counter?`, `get` / `assoc` / `dissoc` /
  keyword-as-fn / `contains?` / `keys` / `vals` over records,
  format/codec/equality/hash, PLAN.md Amendment Log entry,
  Appendix A update.

- **5.3b — protocols substrate.**
  Lands `Kind.protocol = 36`, `Kind.protocol_fn = 37`, the
  protocol registry, `defprotocol` macro, dispatcher routing
  in `call:call`, `:no-protocol-method` / `:no-protocol-impl` /
  `:arity-mismatch` taxonomy. Calling a method-name fails
  cleanly until `defrecord` / `extend-protocol` install impls.

- **5.3c — defrecord with inline impls.**
  Lands `defrecord` macro with inline `Protocol (method ...)`
  clauses. Registers impls in the protocol method table during
  compile-time eval. End-to-end `(bar (->Counter 5) 7) → 12`
  starts working here.

- **5.3d — extend-protocol/extend-type + satisfies? + default.**
  Lands `extend-protocol` / `extend-type` (aliases for the same
  expansion), `satisfies?`, `Any` / `Object` default fallback,
  the built-in dispatch-type name table.

After 5.3d: Phase 5 EXIT criterion (HANDOFF §10.8) becomes
testable — port a non-trivial Clojure-style app that uses
atoms + protocols + records + require + multiple stdlib utilities
and verify it runs.

---

### 8. Open questions (deferred, not blockers for 5.3a)

- `Counter.` reader syntax for constructor call — defer; `->Counter`
  is sufficient for v1 (peer-AI turn 84 §D4).
- `defrecord` field auto-promotion to map keys — already implicit
  in the `fields: persistent_map` storage choice; no special
  affordance needed.
- Protocol method default impls expressed in `defprotocol` body —
  shape is `(defprotocol IFoo (bar [this] default-body))`. Defer
  to 5.3e (post-Phase-5) if surfaced as a need; the v1 hand-trace
  doesn't require defaults.
- `Number` dispatch type covering bignum/float when those gain
  protocol-extension targets — defer; ship fixnum-only in 5.3d
  with a documented limitation.
- Multi-arity protocol methods — defer; v1 fixes arity per method.

---

### 9. Amendment log

- **2026-05-19 (peer-AI turn 84)**: initial design freeze.
  Pins one `Kind.record` with structural equality + structural
  hash; per-VM registries for records + protocols; opaque
  `Kind.protocol` + `Kind.protocol_fn` heap kinds (distinct from
  the existing static `Kind.native_fn` — peer-AI turn 84 §"Big
  missing implementation concern"); `->Counter` + `map->Counter`
  constructors; map-like `get`/`assoc`/`dissoc`/keyword-as-fn on
  records; `extend-protocol`/`extend-type` aliasing; `Any` /
  `Object` default fallback; opaque `#<record my.ns/Counter>` /
  `#<protocol my.ns/IFoo>` format (NOT reader-roundtrippable);
  4-sub-commit split (5.3a–d); hand-trace below as the spec-hole
  surface. Authority: peer-AI turn 84.
