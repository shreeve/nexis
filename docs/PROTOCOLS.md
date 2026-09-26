## PROTOCOLS.md — Records + Protocols

The contract for `Kind.record = 35`, `Kind.protocol = 36`,
`Kind.protocol_fn = 37` and the `defprotocol` / `defrecord` /
`extend-protocol` / `extend-type` macros and `satisfies?`. Kind
numbering is `docs/VALUE.md` §2.2; equality and hash categories are
`docs/SEMANTICS.md` §3.3. Those documents win on conflict.

Protocols dispatch at runtime on the receiver's kind (or record type)
through per-VM registries. Built-in polymorphism (`count`, `get`,
`=`, ...) stays a kind switch in Zig; user protocols sit beside it.

Code: `src/record.zig` (record body, hash, equality, trace),
`src/protocol.zig` (protocol and protocol-fn bodies), `src/vm.zig`
(registries, `DispatchKey`, `dispatchProtocolMethod`),
`src/expand.zig` (the four macros), `src/stdlib.zig` (the internal
natives and `satisfies?`).

---

### 0. Surface

| Form | Meaning |
|---|---|
| `(defprotocol IFoo "doc"? (bar [this x]) ...)` | Defines `IFoo` (a protocol) and one Var per method whose root is a protocol fn |
| `(defrecord Counter [n] IFoo (bar [this x] ...) ...)` | Registers a record type; defines `Counter` (its type), `Counter-type-id`, `->Counter`, `map->Counter`, `Counter?`; installs the inline impls; returns the type |
| `(extend-type :map IFoo (bar [m x] ...) ...)` | Installs impls for one type across protocols |
| `(extend-protocol IFoo :map (bar [m x] ...) Counter (bar ...) ...)` | Installs impls for one protocol across types |
| `(satisfies? IFoo x)` | Whether `IFoo` has an impl for `x`'s dispatch key, or a default |
| `(->Counter 5)`, `(map->Counter {:n 5})`, `(Counter? x)` | Positional constructor, map constructor, predicate |

Records are map-like for `get`, `(:k rec)`, `assoc`, `dissoc`,
`contains?`, `keys`, `vals`, `count`, `empty?`, `find` and `seq`.
`assoc` and `dissoc` return a record of the same type (a `dissoc` of
a declared field included); `empty` returns `{}`.

`defrecord` binds the type name to the record's type, as Clojure binds
its class: `Counter` is the symbol `user.Counter` (namespace, `.`,
name) that `type` and `class` return for an instance, so
`(instance? Counter x)` reads as in Clojure, and the `defrecord` form's
value is that type. `extend-*` reaches the type through
`Counter-type-id`.

Records, protocols and protocol fns are not serializable: the codec
raises `:unserializable` (`docs/CODEC.md` §3). Their ids are dense
per-VM numbers with no meaning in another process.

```clojure
(defprotocol IFoo (bar [this x]) (baz [this x y]))
(defrecord Counter [n]
  IFoo
  (bar [this x] (+ x n))
  (baz [this x y] [:counter (+ x y)]))
(bar (->Counter 5) 7)          ; => 12
(println (->Counter 5))        ; #user.Counter{:n 5}
(extend-protocol IFoo
  :map    (bar [m x] (assoc m :extended x)) (baz [m x y] [:map x y])
  :fixnum (bar [i x] (+ i x))               (baz [i x y] 0))
(bar {} 1)                     ; => {:extended 1}
(bar 100000000000000000000 1)  ; => 100000000000000000001 (a bignum takes the :fixnum impl)
(map bar [1 2] [10 20])        ; => (11 22)
(satisfies? IFoo "s")          ; => false
```

---

### 2. Storage model

#### 2.1 `Kind.record = 35`

The body (`record.RecordBody`, 24 bytes) holds a `u32` `type_id` and
a `fields` Value.

- `type_id` is a dense per-VM index into the record registry (§3),
  not a pointer; the GC trace walks only `fields`.
- `fields` is a `persistent_map` (`docs/CHAMP.md`) keyed by keywords.
  Keys outside the declared field list are allowed and declared keys
  may be absent: the field list is constructor metadata, not a
  storage restriction.

**Equality and hash**: `docs/SEMANTICS.md` §3.3. The record-specific
rule: two records are `=` when their `type_id`s are equal and their
field maps are `=`; a record is never `=` to a map. The hash is
`xxh3(type_id as u32 LE ++ field-map hash as u64 LE)` truncated to
32 bits, then mixed with kind domain 35 by `dispatch.hashValue`, and
cached in the header. Records work as map keys and set members.

**Metadata** (`docs/SEMANTICS.md` §7): a record carries it in its
header like a map, through `with-meta`, and keeps it through `assoc`
and `dissoc` (`record.withFields`). It never takes part in `=`, hash
or printing.

**Print**: `#ns.Type{:field value, ...}` in both modes, as Clojure
prints a record: `(->P 1 "a")` in `user` prints `#user.P{:x 1, :y a}`
with `println` and `#user.P{:x 1, :y "a"}` with `prn`, the field values
printed in the active mode. The name comes from the interner, which
`VM.registerRecordType` tells each new type's `ns` and name
(`Interner.nameRecordType`, `docs/INTERN.md` §2); a type id the
interner was never told prints `#<record type-id=N>`. The output does
not read back: the reader has no tagged literals.

#### 2.2 `Kind.protocol = 36`

The body holds the protocol's `u32` id. The name and method table live
in the protocol registry (§3), so `extend-*` mutates the registry
without cloning the Value. Identity equality; GC leaf; prints
`#<protocol id=N>` in both modes.

#### 2.3 `Kind.protocol_fn = 37`

The body holds `protocol_id` and `method_name_id` (the method's
keyword id). `defprotocol` makes one per method and binds it as the
method Var's root. Identity equality; GC leaf; prints
`#<protocol-fn proto=P method=M>` with the numeric ids.

A protocol fn is callable anywhere a fn is: in call position and
through `VM.callValue`, so it works as an argument to `map`, `apply`,
`comp` and the rest (§5.5). It is its own kind rather than a
`native_fn` because a `NativeFn` is a static descriptor with no
per-instance state, and a dispatcher must know its protocol and
method.

---

### 3. VM-side registries

The VM owns two registries, freed by `VM.deinit`; the names in them
are duped on registration.

| Registry | Entry | Holds |
|---|---|---|
| `VM.record_registry` | `RecordTypeEntry` | `id` (its index), `ns_name`, `type_name`, declared `field_names` in order |
| `VM.protocol_registry` | `ProtocolEntry` | `id`, `ns_name`, `name`, and `methods`: per method its keyword id, its name (for errors), an `impls` map from `DispatchKey` to a callable, and an optional `default_impl` |

`VM.ensureReducedType` registers one built-in record type,
`nexis.core/Reduced` with field `:val`, the first time `reduced` runs.

#### 3.1 Lifetime + redefinition

- Records and protocols live for the VM's life; nothing unregisters.
- `defrecord` of an existing `(ns, name)` registers a new type id, as
  Clojure's `defrecord` makes a new class: the constructors and
  predicate name the new type, and values built before keep the old
  one, so they are not `=` to new ones and fail the new predicate.
- `defprotocol` of an existing `(ns, name)` registers a new protocol
  with no impls, as Clojure's does; the method Vars are rebound to the
  new protocol's fns, so old impls no longer apply.
- Installing an impl for a `(protocol, method, dispatch key)` that
  already has one overwrites it silently; installing on `:any`
  overwrites the method's `default_impl`.

#### 3.2 Dispatch keys

A `DispatchKey` is `{tag, id}`: `{record, type_id}` for a record,
`{builtin, kind byte}` for anything else. `DispatchKey.ofValue(v)`
computes the receiver's key. The integer tower is one type
(`docs/SEMANTICS.md` §2.2): `DispatchKey.canonical` maps the bignum
key to the fixnum key, both when an impl is installed and when a
receiver is looked up, so an impl for `:fixnum` or `:bignum` covers
every integer and the later of the two replaces the earlier. `:float`
is a separate key; there is no umbrella numeric key.

---

### 4. Macros

The four macros are host macros in `src/expand.zig`. They expand to
`def`s plus fully-qualified calls to internal natives in
`nexis.internal` (§7), a namespace that is not auto-referred; they add
no special forms. Method names travel as keywords, and names are
qualified by the current namespace (`"<ns>/Name"`).

#### 4.1 `defprotocol`

```clojure
(defprotocol IFoo (bar [this x]) (baz [this x y]))
;; =>
(do (def IFoo (nexis.internal/#%register-protocol "user/IFoo" [:bar :baz]))
    (def bar (nexis.internal/#%protocol-fn IFoo :bar))
    (def baz (nexis.internal/#%protocol-fn IFoo :baz)))
```

A docstring and `:option value` pairs before the methods are accepted
and ignored. Each method spec must be a non-empty list headed by an
unqualified symbol; its parameter vectors (and anything after them)
are ignored. A method's arities are its impl's own: the registry
records none, and whichever impl the dispatcher calls picks the arity
by the argument count or raises `:arity-mismatch` (§4.2).

#### 4.2 `defrecord`

```clojure
(defrecord Counter [n] IFoo (bar [this x] (+ x n)))
;; =>
(do (def Counter-type-id (nexis.internal/#%register-record-type "user/Counter" [:n]))
    (defn ->Counter [n] (nexis.internal/#%make-record Counter-type-id {:n n}))
    (defn map->Counter [m] (nexis.internal/#%make-record Counter-type-id m))
    (defn Counter? [x] (and (nexis.internal/#%record? x)
                            (nexis.core/= Counter-type-id (nexis.internal/#%record-type-id x))))
    (nexis.internal/#%extend-record-impl IFoo :bar Counter-type-id
      (fn [g x] (let* [n (nexis.core/get g :n)] (let [this g] (+ x n))))))
```

- The name and each field must be unqualified symbols.
- After the field vector, a bare symbol names the protocol the
  following `(method [params] body...)` clauses implement; a method
  clause before any protocol symbol is a malformed macro call. A
  method must take the record as its first parameter.
- A method with several arities takes either Clojure spelling: one
  clause per arity, `(m [this] ...) (m [this x] ...)`, or one clause
  listing them, `(m ([this] ...) ([this x] ...))`. Every clause of a
  name under one protocol symbol goes into one impl, an overloaded
  `fn` (`MACROEXPAND.md` §10), so the argument count picks the arity,
  a variadic arity included; two arities with the same count fail as
  `fn`'s overloads do.
- Inside an inline method each field is a local bound to
  `(get this :field)`, as in Clojure, so a field assoc'd onto the
  record is what the method sees; a field whose name appears anywhere
  in the method's parameters is not bound, so the parameter shadows
  it.
- `map->Counter` passes its map through unchanged (§2.1).
- The compiler's declared-name table knows `Counter`,
  `Counter-type-id`, `->Counter`, `map->Counter` and `Counter?`
  (`expand.RecordNames`), so a form may refer to `->Counter` before
  the `defrecord` that defines it.

#### 4.3 `extend-protocol` / `extend-type`

```clojure
(extend-protocol IFoo :map (bar [m x] (assoc m :extended x)))
(extend-type :map IFoo (bar [m x] (assoc m :extended x)))
;; both =>
(do (nexis.internal/#%extend-builtin-impl IFoo :bar :map
      (fn [m x] (assoc m :extended x))))
```

`extend-type` takes one type and any number of
`Protocol (method ...)...` groups; `extend-protocol` takes one protocol
and any number of `type (method ...)...` groups. Both use the clause
parser `defrecord` uses, with the fixed and iterated positions
swapped, so a method's arities take either spelling of §4.2:
`(extend-type :string P (m ([s] ...) ([s x] ...)))`.

| Type form | Emits | Dispatch key |
|---|---|---|
| keyword naming a `Kind` tag (`:nil`, `:false_`, `:true_`, `:char`, `:fixnum`, `:float`, `:keyword`, `:symbol`, `:string`, `:bignum`, `:list`, `:function`, `:native_fn`, `:atom`, `:record`, ...) | `#%extend-builtin-impl` | `{builtin, kind}`; `:fixnum` and `:bignum` are one key (§3.2) |
| `:vector` / `:map` / `:set` | `#%extend-builtin-impl` | aliases for `:persistent_vector` / `:persistent_map` / `:persistent_set` |
| `:any` | `#%extend-default-impl` | the method's `default_impl` |
| record symbol `Counter` | `#%extend-record-impl` with `Counter-type-id` | `{record, type_id}` |

The keyword-to-kind mapping is derived from the `Kind` enum's field
names at compile time, so every kind tag is accepted under its enum
name (booleans are `:false_` and `:true_`; there is no `:bool`). A
keyword that names no kind and no alias raises `:invalid-argument`
when the expansion runs; the macro does not validate type names. A
record symbol no `defrecord` produced fails as an unbound
`<Name>-type-id`.

#### 4.4 `satisfies?`

`(satisfies? P x)` is a `nexis.core` native of arity 2: true when any
method of `P` has an impl for `x`'s dispatch key, or any method has a
`default_impl`; false otherwise, so a zero-method protocol never
satisfies. A first argument that is not a protocol raises
`:kind-mismatch`.

---

### 5. Dispatch

The canonical example, which `test/integration/eval_pipeline.zig`
runs end to end:

```clojure
(do
  (defprotocol IFoo (bar [this x]))
  (defrecord Counter [n] IFoo (bar [this x] (+ x (:n this))))
  (bar (->Counter 5) 7))       ; => 12
```

`defprotocol` registers protocol 0 with method `:bar` and binds `bar`
to a protocol fn `{0, <:bar>}`; `defrecord` registers type 0 and puts
the impl at `impls[{record, 0}]` of method `:bar`. The call
`(bar (->Counter 5) 7)` is an ordinary call form: `bar` is loaded as a
Var and called with two arguments.

#### 5.5 VM dispatch

A call whose callee is not a closure goes through `VM.callDirect`,
the path the call instruction and `VM.callValue` share: a `native_fn`
runs after its arity check, a `protocol_fn` goes to
`dispatchProtocolMethod`, a lookup-callable value (keyword, symbol, map, set,
vector) does its lookup, and anything else, a record included, raises
`:not-callable`. The call instruction copies the arguments off the
stack first, so the impl may grow it.

`dispatchProtocolMethod(vm, callee, args)`:

```text
proto   := protocol_registry[callee.protocol_id]     or :no-protocol-impl
method  := proto.methods[name_id == callee.method]   or :no-protocol-method
args.len == 0                                         -> :arity-mismatch
key     := DispatchKey.ofValue(args[0])
impl    := method.impls[key] or method.default_impl  or :no-protocol-impl
return vm.callValue(impl, args)
```

`callValue` applies the impl's own arity check, so a wrong argument
count is that fn's `:arity-mismatch`. There is no inline cache: every
call walks the registry.

#### 5.7 Decisions

- `#%register-protocol` returns the protocol Value, so the
  `#%protocol-fn` calls after it in the same `do` read the id from
  the `IFoo` Var.
- `#%register-record-type` returns the type id as a fixnum, held in
  `T-type-id` so the constructor bodies reference it as an ordinary
  value.
- The `extend-*` natives take the protocol Value (not its Var), the
  method keyword and, for the record and builtin forms, the dispatch
  target (a type-id fixnum or a kind keyword).
- They do not check that the impl is callable: a non-callable impl
  raises `:not-callable` at the first dispatch that selects it.

---

### 6. Errors (catchable keywords)

| Keyword | Raised by |
|---|---|
| `:no-protocol-impl` | A call whose receiver's key has no impl and the method no default; a protocol id not in the registry |
| `:no-protocol-method` | Extending, or making a protocol fn for, a method the protocol does not declare |
| `:arity-mismatch` | A protocol fn called with no arguments; an impl called with the wrong count |
| `:not-callable` | An installed impl that is not callable, at dispatch |
| `:invalid-argument` | An `extend-*` type keyword that names no kind and no alias |
| `:kind-mismatch` | `satisfies?` or an internal native given the wrong kind (a non-protocol, a non-keyword method name, a non-string name, a negative type id) |
| `:not-a-record` | `#%record-type-id` of a non-record |
| `:unserializable` | Encoding a record, protocol or protocol fn (`docs/CODEC.md` §3) |

A malformed macro call (a qualified or non-symbol name, a method
clause before a protocol, a method without a parameter vector) is an
expansion error at compile time (`docs/MACROEXPAND.md`).

---

### 7. Internal natives (`nexis.internal`)

| Native | Arity | Returns |
|---|---|---|
| `#%register-record-type "ns/Name" [:f ...]` | 2 | fixnum type id |
| `#%make-record type-id field-map` | 2 | record |
| `#%record? x` | 1 | boolean |
| `#%record-type-id rec` | 1 | fixnum |
| `#%register-protocol "ns/IFoo" [:m ...]` | 2 | protocol |
| `#%protocol-fn IFoo :m` | 2 | protocol fn |
| `#%extend-record-impl IFoo :m type-id f` | 4 | nil |
| `#%extend-builtin-impl IFoo :m :kind f` | 4 | nil |
| `#%extend-default-impl IFoo :m f` | 3 | nil |

`#%register-record-type` and `#%register-protocol` split the name on
its last `/` into namespace and name; a name with no `/` has an empty
namespace.

---

### 8. Absences

- No `Counter.` constructor syntax; `->Counter` is the constructor.
- `defrecord` does not bind the type name (§0).
- No default impl inside `defprotocol`; defaults are installed with
  `extend-protocol ... :any`.
- No arity check at the protocol fn: the impl checks its own (§4.1).
- No umbrella numeric dispatch target (§3.2).
- No inline caching of protocol dispatch (§5.5).
- No tagged-literal reading of printed records (§2.1).
