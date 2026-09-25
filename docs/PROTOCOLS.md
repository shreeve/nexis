## PROTOCOLS.md — Records + Protocols

Authoritative contract for the runtime-side `Kind.record = 35`,
`Kind.protocol = 36`, `Kind.protocol_fn = 37` and the
language-surface `defprotocol` / `defrecord` / `extend-protocol` /
`extend-type` / `satisfies?` macros and natives. Related contracts:
`docs/VALUE.md` §2.2 (kind numbering) and `docs/SEMANTICS.md` §2.6
(structural-equality categories). Those documents win on conflict.

Protocols are static-dispatch over per-VM registries: single
isolate, single thread, no STM, no agents, no concurrency.

---

### 0. Surface

- `Kind.record = 35` — one heap kind for all record types; the
  record type id lives in the heap body, NOT as a separate Kind.
  Structural equality + structural hash by `(type_id, field_map)`.
- `Kind.protocol = 36` — opaque protocol handle. Identity equality;
  not serializable; user code holds them only as Var roots.
- `Kind.protocol_fn = 37` — opaque dispatcher handle. Identity
  equality. Carries `(protocol_id, method_name_id)` so the
  generic dispatcher knows what to look up. Distinct from
  `Kind.native_fn` because `NativeFn` is a static descriptor with
  no per-method state.
- `defprotocol`, `defrecord`, `extend-protocol`, `extend-type` —
  host macros; `satisfies?` — native fn in `nexis.core`.
- `(->Counter n)` positional constructor; `(map->Counter {:n 1})`
  map constructor; `Counter?` predicate.
- `(get rec :k)`, `(:k rec)`, `(assoc rec :k v)`, `(dissoc rec :k)`,
  `(contains? rec :k)`, `(keys rec)`, `(vals rec)`, `(count rec)`,
  `(empty? rec)`, `(find rec :k)`, `(seq rec)` — records behave
  map-like for these. `assoc` / `dissoc` return a record of the
  same type; `empty` on a record returns `{}`.
- Built-in dispatch targets for `extend-protocol` / `extend-type`
  are keywords naming a `Kind` (see §4.3), plus `:any` for the
  default fallback.

Facts about the boundary:

- There is no `Counter.` (dot-suffix) constructor syntax; `->Counter`
  is the constructor.
- Records and protocols are not in the codec serializable set; both
  throw `:unserializable`.
- Protocol method calls have no inline cache; every call walks the
  registry (§5.5).
- Redefining a record type or protocol with the same `(ns, name)`
  is rejected with `:record-redefinition` / `:protocol-redefinition`
  (§3.1).
- A protocol method has exactly one arity: the impl fn's own. The
  registry stores no per-method arity, and `defprotocol` ignores the
  parameter vectors in its method specs (§4.1).
- Every `Kind` tag name is a valid dispatch keyword, so `:fixnum`,
  `:bignum`, and `:float` are three distinct dispatch targets; there
  is no umbrella `Number` target.

---

### 1. Relationship to the decision record

Protocols and records add scope without changing any
architecturally load-bearing decision: the runtime is
single-isolate and single-threaded, so protocols are static-dispatch
+ per-VM registries. Built-in polymorphism (`count`, `get`, `=`, ...) stays
kind-switch based in Zig; user protocols sit beside it.

---

### 2. Storage model

#### 2.1 `Kind.record = 35`

```zig
RecordBody extern struct {
    type_id: u32,                     // dense index into VM.record_registry
    _pad: [4]u8,
    fields: Value,                    // persistent_map (keyword → value)
}
```

`@sizeOf(RecordBody) == 24`, alignment ≤ 16.

- **`type_id` is a per-VM dense `u32`**, NOT a pointer. Stable
  across allocations within a VM; not stable across VMs (single
  isolate = irrelevant) and not stable across serialization
  (records are unserializable).
- **`fields` is a `Kind.persistent_map`** — CHAMP/array-map per
  CHAMP.md. Keys are keywords (or symbols, for completeness).
  Extra keys not in the declared field list are ALLOWED; the
  declared list is constructor metadata, not a storage restriction.

**Equality** (kind-local, structural):

```
equal(record_a, record_b) :=
    record_a.type_id == record_b.type_id
        AND equal(record_a.fields, record_b.fields)
```

**Hash** (kind-local, structural):

```
hash(record) := mixKindDomain(xxh3(type_id_le ++ field_map_hash_le), 35)
```

Two `(->Counter 5)` instances are `=` regardless of which `->Counter`
call produced them. Records-as-map-keys WORK because hash + equality
are structural. The hash is cached in the header hash slot.

**Codec**: records throw `:unserializable` (same arm as functions /
Vars / atoms / etc.).

**GC trace**: walk `fields`. The `type_id` is a `u32`, not a heap
pointer.

**Format**: `#<record type-id=N>` in both display and readable
modes (opaque, not reader-roundtrippable).

#### 2.2 `Kind.protocol = 36`

```zig
ProtocolBody extern struct {
    id: u32,           // dense index into VM.protocol_registry
    _pad: [4]u8,
}
```

- **Opaque heap kind.** User code holds these as Var roots.
- **Identity equality** (pointer-to-heap-header). Two `IFoo`
  references resolve to the same Var → same protocol value.
- **Unserializable.**
- **Format**: `#<protocol id=N>` in both display and readable
  modes (opaque, not pretending to be reader-roundtrippable).
- **GC trace**: leaf; no inner heap to mark.

The protocol's name and METHOD TABLE live in
`VM.protocol_registry[id]`, not in the heap body — that way
mutation via `extend-protocol` doesn't have to clone the protocol
Value.

#### 2.3 `Kind.protocol_fn = 37`

```zig
ProtocolFnBody extern struct {
    protocol_id: u32,
    method_name_id: u32,    // keyword-pool id of the method name
}
```

- **Opaque heap kind.** User code obtains these by deref'ing the
  Var that `defprotocol` registers per method (e.g. `bar` is a
  Var whose root is a `protocol_fn` with the right `(protocol_id,
  method_name_id)`).
- **Identity equality.**
- **Unserializable.**
- **Format**: `#<protocol-fn proto=P method=M>` (numeric ids).
- **GC trace**: leaf.
- **Call dispatch**: `call:call` on a `protocol_fn` routes to the
  VM helper `dispatchProtocolMethod(vm, callee, args)` which walks
  `VM.protocol_registry[protocol_id].methods[method_name_id].impls[DispatchKey.ofValue(args[0])]`
  and invokes the resulting closure / native_fn / fn.

`NativeFn` is a static descriptor with `{name, min_arity,
max_arity, call}` — no per-instance state. Protocol dispatchers
NEED to know which protocol + which method they belong to. A
separate `Kind.protocol_fn` with that state in the payload keeps
`NativeFn`'s static-descriptor design intact.

---

### 3. VM-side registries

The VM owns two registries:

```zig
record_registry: std.ArrayList(RecordTypeEntry) = .empty,
protocol_registry: std.ArrayList(ProtocolEntry) = .empty,
```

where:

```zig
RecordTypeEntry {
    id: u32,                       // dense, == index into the ArrayList
    ns_name: []const u8,           // qualified namespace name
    type_name: []const u8,         // short name (e.g. "Counter")
    field_names: []const []const u8, // declared field keyword names, in order
}

ProtocolEntry {
    id: u32,
    ns_name: []const u8,
    name: []const u8,
    methods: std.ArrayList(ProtocolMethod),
}

ProtocolMethod {
    name_id: u32,                  // keyword-pool id; matches ProtocolFnBody.method_name_id
    name: []const u8,              // for error messages
    impls: std.AutoHashMapUnmanaged(DispatchKey, Value),  // each Value is callable
    default_impl: ?Value = null,   // installed by extend-* on :any
}

DispatchKey {
    tag: enum(u8) { builtin = 0, record = 1 },
    id: u32,                       // Kind byte for builtin; RecordTypeEntry.id for record
}
```

`DispatchKey.ofValue(v)` returns `{ .record, typeId(v) }` when
`v.kind() == .record` and `{ .builtin, @intFromEnum(v.kind()) }`
otherwise.

`VM.deinit` frees both registries (the ArrayLists + the per-method
maps). Names are owned by the registries (duped on registration).

#### 3.1 Lifetime + redefinition

- Defining a record type with a name that's already in
  `record_registry` for the same `(ns, name)` → reject with
  `:record-redefinition`. Avoids the confusing-state hazard
  where existing instances reference an old type_id.
- Defining a protocol with an existing `(ns, name)` → same
  treatment: `:protocol-redefinition`.
- Adding impls to an existing protocol via
  `extend-protocol` / `extend-type` / `defrecord` is allowed (that's
  the whole point of those macros). Registering an impl for a
  `(protocol_id, method, dispatch_key)` triple that already has one
  → overwrite silently (Clojure-canonical behavior; users
  redefining at the REPL is the common case). Registering a
  `:any` impl overwrites the method's `default_impl`.

---

### 4. Macros

`defprotocol`, `defrecord`, `extend-protocol` and `extend-type` are
host macros in `src/expand.zig` next to `defmacro` / `defn`. They
expand to combinations of `def` + calls to internal natives that
live in the `nexis.internal` namespace (NOT auto-referred); the
macros emit fully-qualified calls. Method names travel as keywords
so the natives see homogeneous values and one interning pool.

#### 4.1 `defprotocol`

```clojure
(defprotocol IFoo
  (bar [this x])
  (baz [this x y]))
```

Expansion:

```clojure
(do
  ;; Register the protocol in VM.protocol_registry.
  (def IFoo (nexis.internal/#%register-protocol "my.ns/IFoo" [:bar :baz]))
  ;; Each method gets a Var whose root is a `Kind.protocol_fn`.
  (def bar (nexis.internal/#%protocol-fn IFoo :bar))
  (def baz (nexis.internal/#%protocol-fn IFoo :baz)))
```

Each method spec must be a list headed by an unqualified symbol.
The parameter vector after the method name is accepted and ignored:
the registry records no arity or doc string, and arity is enforced
by whichever impl fn the dispatcher invokes.

`#%register-protocol` returns the `Kind.protocol` Value carrying the
protocol's id; `#%protocol-fn` reads that id out of the Value.

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
  ;; Register the record type; gets a fresh type_id (a fixnum).
  (def Counter-type-id
       (nexis.internal/#%register-record-type "my.ns/Counter" [:n]))
  ;; Positional constructor.
  (defn ->Counter [n]
    (nexis.internal/#%make-record Counter-type-id {:n n}))
  ;; Map constructor.
  (defn map->Counter [m]
    (nexis.internal/#%make-record Counter-type-id m))
  ;; Predicate.
  (defn Counter? [x]
    (and (nexis.internal/#%record? x)
         (= Counter-type-id (nexis.internal/#%record-type-id x))))
  ;; Per-protocol impls registered into the protocol's method table.
  ;; A method sees the fields as locals (below).
  (nexis.internal/#%extend-record-impl IFoo :bar Counter-type-id
    (fn [this x] (assoc this :n (+ x n))))
  (nexis.internal/#%extend-record-impl IFoo :baz Counter-type-id
    (fn [this x y] [:counter (+ x y)])))
```

Inside an inline method each field is a local bound to the record's
value for it, `(nexis.core/get this :n)`, as in Clojure, unless a
parameter of the method has the same name, which shadows it. So a
field assoc'd onto the record is what a method sees.

Clauses after the field vector are parsed in order: a bare symbol
switches the current protocol; a list `(method [params] body...)`
emits one `#%extend-record-impl` call against the current protocol.
A method clause before any protocol symbol is a malformed macro
call.

`map->Counter` passes its argument through unchanged; the map may
carry extra keys or omit declared ones (§2.1).

The four Vars a `defrecord` defines besides the type (`T-type-id`,
`->T`, `map->T`, `T?`) are also known to the compiler's declared-name
table, so a form may refer to `->T` before the `defrecord` that
produces it.

The `assoc this :n (...)` inside the body works because records
are map-like for `get` / `assoc` / `dissoc`. The returned value
from `assoc` is a NEW record of the same type with an updated
field map (NOT a plain map).

#### 4.3 `extend-protocol` / `extend-type`

```clojure
(extend-protocol IFoo
  :map
  (bar [m x] (assoc m :extended x))
  (baz [m x y] [:map x y]))

(extend-type :map
  IFoo
  (bar [m x] (assoc m :extended x))
  (baz [m x y] [:map x y]))
```

Both expand to:

```clojure
(do
  (nexis.internal/#%extend-builtin-impl IFoo :bar :map
    (fn [m x] (assoc m :extended x)))
  (nexis.internal/#%extend-builtin-impl IFoo :baz :map
    (fn [m x y] [:map x y])))
```

`extend-type` takes one type and any number of
`Protocol (method ...)...` groups; `extend-protocol` takes one
protocol and any number of `type (method ...)...` groups. Both walk
the same clause parser with the fixed and iterated positions
swapped.

Type forms:

| Type form | Emits | Dispatch key |
|---|---|---|
| keyword naming a `Kind` tag (`:nil`, `:false_`, `:true_`, `:char`, `:fixnum`, `:float`, `:keyword`, `:symbol`, `:string`, `:bignum`, `:persistent_map`, `:persistent_set`, `:persistent_vector`, `:list`, `:function`, `:native_fn`, `:atom`, `:record`, ...) | `#%extend-builtin-impl` | `{ .builtin, kind }` |
| `:vector` / `:map` / `:set` | `#%extend-builtin-impl` | aliases for `:persistent_vector` / `:persistent_map` / `:persistent_set` |
| `:any` | `#%extend-default-impl` | sets the method's `default_impl` |
| symbol `Counter` | `#%extend-record-impl` with `Counter-type-id` | `{ .record, type_id }` |

The keyword → `Kind` mapping is derived from the `Kind` enum's field
names at compile time, so every kind tag is accepted. A keyword
that names no kind and no alias raises `:invalid-argument` when the
expansion runs (the macro does not validate type names). The record
symbol resolves to `<Name>-type-id` at runtime; using a name that no
`defrecord` produced fails as an unbound symbol.

#### 4.4 `satisfies?`

```clojure
(satisfies? IFoo (->Counter 5))   ; => true
(satisfies? IFoo 42)              ; => false when neither :fixnum nor :any has an impl
```

Native fn in `nexis.core`, arity 2. For the receiver's dispatch key
(record type or Kind), walk the protocol's methods; the result is
true if ANY method has an impl for that key or a `default_impl`,
false otherwise. A zero-method protocol therefore yields false. A
first argument that is not a protocol raises `:kind-mismatch`.

---

### 5. Dispatch flow (the hand-trace)

This is the load-bearing section. The hand-trace walks `(bar
(->Counter 5))` end-to-end through reader → expand → compile →
VM, with EVERY step annotated.

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
  (def IFoo (nexis.internal/#%register-protocol "user/IFoo" [:bar]))
  (def bar  (nexis.internal/#%protocol-fn IFoo :bar)))
```

After execution:
- `VM.protocol_registry[0]` exists, named `user/IFoo`, with
  one method `bar`.
- The `IFoo` Var's root is a `Kind.protocol` Value carrying
  `{ id: 0 }`.
- The `bar` Var's root is a `Kind.protocol_fn` Value carrying
  `{ protocol_id: 0, method_name_id: <keyword id of :bar> }`.

##### 5.3.b `defrecord`

```text
(defrecord Counter [n]
  IFoo
  (bar [this x] (+ x (:n this))))
→
(do
  (def Counter-type-id
       (nexis.internal/#%register-record-type "user/Counter" [:n]))
  (defn ->Counter [n]
    (nexis.internal/#%make-record Counter-type-id {:n n}))
  (defn map->Counter [m]
    (nexis.internal/#%make-record Counter-type-id m))
  (defn Counter? [x]
    (and (nexis.internal/#%record? x)
         (= Counter-type-id (nexis.internal/#%record-type-id x))))
  (nexis.internal/#%extend-record-impl IFoo :bar Counter-type-id
    (fn [this x] (+ x (:n this)))))
```

After execution:
- `VM.record_registry[0]` exists with `{ id: 0, ns_name: "user",
  type_name: "Counter", field_names: ["n"] }`.
- `Counter-type-id` Var's root is `Value.fromFixnum(0).?`.
- `->Counter` / `map->Counter` / `Counter?` Vars hold compiled
  closures.
- `VM.protocol_registry[0].methods[bar].impls[{record, 0}]`
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
    .function       → Closure dispatch
    .native_fn      → NativeFn dispatch
    .protocol_fn    → copy args off the stack;
                      dispatchProtocolMethod(vm, slot[X+0], args)
    else            → :not-callable
```

The args are COPIED off the stack (same shape as the native arm) so
the invoked impl can safely grow the stack; the result is written to
the caller's `result_dst` slot.

`dispatchProtocolMethod(vm, fn_value, args)`:

```text
if args.len == 0 → throw :arity-mismatch
pfn         := asProtocolFn(fn_value)        // {protocol_id, method_name_id}
proto       := vm.protocol_registry[pfn.protocol_id]
            or throw :no-protocol-impl
method      := proto.methods[name_id == pfn.method_name_id]
            or throw :no-protocol-method

receiver    := args[0]
dkey        := DispatchKey.ofValue(receiver)  // record or builtin
impl        := method.impls[dkey]
            or method.default_impl
            or throw :no-protocol-impl

return vm.callValue(impl, args)
```

`callValue` applies the impl's own arity check; a wrong argument
count surfaces as that fn's `:arity-mismatch`.

#### 5.6 Worked numbers for `(bar (->Counter 5) 7)`

1. `(->Counter 5)` runs:
   - `->Counter` Var → its root is a closure.
   - Closure body calls `(#%make-record 0 {:n 5})`.
   - Result: `Kind.record` Value carrying `{type_id: 0, fields:
     {:n 5}}`.

2. `(bar <record> 7)` runs:
   - `bar` Var → `Kind.protocol_fn` Value `{protocol_id: 0,
     method_name_id: <:bar>}`.
   - `call:call` sees `.protocol_fn` → routes to
     `dispatchProtocolMethod`.
   - `DispatchKey.ofValue(<record>)` → `{record, 0}`.
   - Lookup: `protocol_registry[0].methods[bar].impls[{record, 0}]`
     → the `(fn [this x] (+ x (:n this)))` closure.
   - `vm.callValue(impl, [<record>, 7])` runs the closure:
     - `this` = the record. `x` = 7.
     - `(:n this)` = 5.
     - `(+ x (:n this))` = `(+ 7 5)` = `12`.
   - Return `12`.

3. The outer `do` returns the result of its last subform → `12`. ✓

#### 5.7 Decisions the hand-trace pins

- `#%register-protocol` returns a `Kind.protocol` Value with the
  protocol's id — needed by the `(#%protocol-fn IFoo :bar)` form
  immediately below in the same `do`. The id is captured at
  registration time.
- `#%register-record-type` returns a fixnum (the type_id) so the
  `->Counter` constructor body can reference it as an ordinary
  value. Stored in a Var.
- `#%extend-record-impl` / `#%extend-builtin-impl` /
  `#%extend-default-impl` take the protocol VALUE (not Var), the
  method NAME (keyword), and — for the first two — a dispatch
  target (a type-id fixnum, or a kind keyword).
- The dispatcher's `call:call` arm fires BEFORE the
  `:not-callable` fallback; `Kind.protocol_fn` joins `.function`
  and `.native_fn` as the three callable kinds.
- `Kind.record`'s field-map operations (`get`, `assoc`, `dissoc`,
  `:k` keyword-as-fn) route through the record's field map;
  `assoc` on a record returns a record (same type_id), NOT a plain
  map.
- All `#%`-prefixed internal forms are native fns installed in the
  `nexis.internal` namespace (NOT auto-referred); macros emit
  fully-qualified calls. No special-form extensions.

---

### 6. Errors (catchable keywords)

| Keyword | Source |
|---|---|
| `:no-protocol-method` | Calling a method-name not defined on the protocol; extending a method the protocol does not declare |
| `:no-protocol-impl` | Receiver kind has no impl + no default; protocol id not in the registry |
| `:not-a-record` | `#%record-type-id` on a non-record |
| `:record-redefinition` | `defrecord` with an existing `(ns, name)` |
| `:protocol-redefinition` | `defprotocol` with an existing `(ns, name)` |
| `:invalid-argument` | `extend-protocol`/`extend-type` keyword that names no kind and no alias |
| `:arity-mismatch` | Protocol method called with no receiver; impl fn called with the wrong number of args |
| `:kind-mismatch` | Internal natives / `satisfies?` receiving a value of the wrong kind (non-protocol, non-keyword method name, non-map fields, ...) |

---

### 7. Internal natives (`nexis.internal`)

| Native | Arity | Returns |
|---|---|---|
| `#%register-record-type "ns/Name" [:f ...]` | 2 | fixnum type_id |
| `#%make-record type-id field-map` | 2 | record |
| `#%record? x` | 1 | bool |
| `#%record-type-id rec` | 1 | fixnum |
| `#%register-protocol "ns/IFoo" [:m ...]` | 2 | protocol |
| `#%protocol-fn IFoo :m` | 2 | protocol_fn |
| `#%extend-record-impl IFoo :m type-id f` | 4 | nil |
| `#%extend-builtin-impl IFoo :m :kind f` | 4 | nil |
| `#%extend-default-impl IFoo :m f` | 3 | nil |

`#%register-record-type` and `#%register-protocol` split the name
string on its LAST `/` into `(ns, name)`; a string with no `/` has
an empty ns. The `extend-*` natives do not validate that `f` is
callable; a non-callable impl surfaces as `:not-callable` at the
first dispatch that selects it, pointing at the user's impl form.

---

### 8. Absences

- No `Counter.` reader syntax for constructor calls.
- No default impl syntax inside `defprotocol` (a body after the
  parameter vector is ignored); defaults are installed with
  `extend-protocol ... :any`.
- No multi-arity protocol methods and no arity declared per method.
- No umbrella numeric dispatch target; `:fixnum`, `:bignum`, `:float`
  are separate keys.
- No inline caching of protocol dispatch.
