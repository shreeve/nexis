## ATOM.md — In-memory mutable cells

Contract for `Kind.atom` (`src/atom.zig`) and the atom natives in
`nexis.core`. `docs/VALUE.md` (kind 34) and `docs/SEMANTICS.md` win on
conflict.

An atom is the in-memory mutable identity: ephemeral, one VM, one
thread. Durable mutation is `db/alter!` inside `with-tx`
(`docs/DB.md`). The API mirrors `clojure.core/atom`, but nexis is
single-isolate and single-threaded (PLAN.md §23 #5), so
`compare-and-set!` is a deterministic check-and-set and `swap!` calls
its function once: there is no retry loop and no synchronization.

---

### 1. Scope

| name | arity | result |
|---|---|---|
| `(atom init & opts)` | 1+ | a fresh atom holding `init`; options `:meta` and `:validator` (§4.1) |
| `(atom? x)` | 1 | true for an atom |
| `(reset! a v)` | 2 | sets `a` to `v`; returns `v` |
| `(swap! a f & args)` | 2+ | sets `a` to `(apply f @a args)`; returns the new value |
| `(swap-vals! a f & args)` | 2+ | as `swap!`; returns `[old new]` |
| `(reset-vals! a v)` | 2 | as `reset!`; returns `[old new]` (`core.nx`, over `swap-vals!`) |
| `(compare-and-set! a old new)` | 3 | sets `a` to `new` when its value is identical to `old`; returns whether it did |
| `(set-validator! a f)`, `(get-validator a)` | 2, 1 | sets (nil removes) and reads the validator (§4.8) |
| `(add-watch a key f)`, `(remove-watch a key)` | 3, 2 | adds and removes a watch; return `a` (§4.8) |
| `(meta a)`, `(reset-meta! a m)`, `(alter-meta! a f & args)` | | the atom's metadata, changed in place (§4.9) |
| `(deref a)`, `@a` | 1 | the contained value (§5) |
| `volatile!`, `volatile?`, `vreset!`, `vswap!` | | `core.nx` aliases: a volatile is an atom (§4.7) |

All are natives in `src/stdlib.zig` except the `core.nx` definitions
named above.

Absent: `agent`, `ref` and `dosync` (CLOJURE-REVIEW.md), and
watches and validators on a Var.

---

### 2. Storage

An atom is a heap block of kind 34, freed by the sweep when
unreachable. Its body, `AtomBox`, is 56 bytes: the
contained `value`, the `validator` (nil when there is none) and the
`watches` map (nil when there are none), 16 bytes each, then the
`in_flight` re-entrancy byte and padding. `atom.make` allocates it;
`getValue` and `setValue` read and write the value, `body` reaches the
validator and the watches; `tryEnterCritical` and `exitCritical` own
the flag. The header's meta pointer holds the atom's metadata; its hash
slot is unused (`docs/HEAP.md`).

---

### 3. Equality and hash

Equality and hash: SEMANTICS.md §3.3. An atom is an identity kind:
equal only to itself and hashed by its pointer, never by the value it
holds, so `(= (atom 1) (atom 1))` is false and an atom is a stable map
key across mutations. The collector does not move blocks, so the hash
needs no cache.

---

### 4. The natives

#### 4.1 `(atom init & opts)`

`opts` are keyword-value pairs, as Clojure's: `:meta m` makes `m` (a
map or nil, else `:kind-mismatch`) the atom's metadata, `:validator f`
its validator, which `init` must satisfy (§4.8) before the atom is
made. A later pair for the same key wins, a key `atom` does not take
is ignored, and an odd number of option arguments is
`:invalid-argument`; `(atom)` is `:arity-mismatch`. An atom prints as
`#<atom>` (§8).

```clojure
(let [a (atom 1 :meta {:m 1} :validator pos?)] [(meta a) (get-validator a)])
;; => [{:m 1} #<native-fn pos?>]
(atom -1 :validator pos?)   ;; throws :invalid-reference-state
```

#### 4.2 `(atom? x)`

True for an atom, false for anything else.

#### 4.3 `(reset! a v)`

Validates `v` (§4.8), sets the value, runs the watches and returns
`v`, not the atom. Called while `a` is in flight (§4.4) it is
`:atom-re-entry`.

#### 4.4 `(swap! a f & args)`

Sets `a` to `(apply f @a args)` and returns the new value. The order is
the contract:

1. `a` not an atom → `:kind-mismatch`; `a` in flight →
   `:atom-re-entry`. Otherwise mark it in flight until the native
   returns, by any path.
2. Read the old value.
3. Call `f` with the old value and `args` through `vm.callValue`.
4. Validate the result (§4.8).
5. Write it, and clear the in-flight mark.
6. Run the watches with the old and the new value (§4.8).

A throw or control transfer out of `f` or the validator leaves step 5
unreached, so the atom is unchanged. While `f` runs, `reset!`, `swap!`, `swap-vals!` or
`compare-and-set!` on the same atom is `:atom-re-entry`, and the outer
`swap!` propagates it without writing. Clojure would retry `f`; nexis
cannot, and silently overwriting the inner write would lose it. `deref`
of an in-flight atom is allowed: it reads and never marks.

```clojure
(let [a (atom 0)]
  [(try (swap! a (fn [_] (reset! a 9))) (catch :atom-re-entry e e)) @a])
;; => [:atom-re-entry 0]
```

#### 4.5 `(swap-vals! a f & args)`

`swap!` returning the vector `[old new]`, with the same order and
rollback. The vector is allocated after the watches run, and no
collection can run between their last call and the allocation
(`docs/GC.md` §11.5). `reset-vals!` is `swap-vals!` with
`(constantly v)`.

#### 4.6 `(compare-and-set! a old new)`

Validates `new` (§4.8) whether or not it will be written, as Clojure
does; then sets `a` to `new`, runs the watches and returns true when
the current value is identical to `old` (`identical?`: bit equality of the 16-byte value, so the same
immediate or the same heap block); otherwise returns false. Structural
`=` is not used, so a collection equal to the current one but distinct
from it does not match, as in Clojure. It marks the atom in flight like
the other mutators, so it is `:atom-re-entry` inside a `swap!` on the
same atom.

```clojure
(let [a (atom 11)] [(compare-and-set! a 11 100) (compare-and-set! a 11 200) @a])
;; => [true false 100]
(let [a (atom [1])] (compare-and-set! a [1] 2))   ;; => false
```

#### 4.7 Volatiles

`volatile!` is `atom`, `volatile?` is `atom?`, `vreset!` is `reset!`
and `vswap!` is a macro over `swap!`. With one thread a volatile has
nothing to give up relative to an atom, so it is one.

#### 4.8 Validators and watches

The validator is a function of one argument or nil. Every new state,
from `reset!`, `swap!`, `swap-vals!`, `reset-vals!`,
`compare-and-set!`, the `:validator` option of `atom` and
`set-validator!` (which checks the current value), is passed to it
before it is written: a falsy answer is `:invalid-reference-state` (in
Clojure an `IllegalStateException`, "Invalid reference state") and a
throw out of the validator propagates; either way nothing is written
and `set-validator!` leaves the old validator in place.
`(set-validator! a nil)` removes it; `set-validator!` returns nil,
`get-validator` the validator or nil.

A watch is a function of four arguments, `(key atom old new)`, kept in
a hash map under its key: `add-watch` adds or replaces the watch under
a key `=` to `key`, `remove-watch` drops it (no watch under the key is
no change); both return the atom. After every write, the watches run
in the map's order, which is unspecified, as in Clojure, even when
`old` and `new` are the same value. They run after the in-flight mark
is cleared, so a watch may change the atom again (and runs the watches
again); a throw out of a watch propagates from the mutator after the
write, and the watches after it do not run. Validators and watches
belong to atoms only: on any other value the four natives are
`:kind-mismatch`.

The collector reaches the validator and the watches map through the
atom (§7). While the watches run, the mutator roots the map it runs
through, which a watch that adds or removes one replaces on the atom
(`docs/GC.md` §11.5, class 3); the new state, and the old one, are
rooted as the arguments of each call.

```clojure
(let [a (atom 1) log (atom [])]
  (add-watch a :log (fn [k r old new] (swap! log conj [k old new])))
  (swap! a inc) (reset! a 5)
  @log)
;; => [[:log 1 2] [:log 2 5]]
(let [a (atom 1 :validator pos?)] [(try (swap! a dec) (catch any e e)) @a])
;; => [:invalid-reference-state 1]
```

#### 4.9 Metadata

An atom's metadata is a hash map or nil, set by the `:meta` option and
changed in place by `reset-meta!` and `alter-meta!`, as a Var's is;
`meta` reads it. It takes no part in equality, hashing or printing.
`with-meta` of an atom is `:kind-mismatch`, as in Clojure, where an
atom is a reference and not a value that carries metadata.

---

### 5. `deref`

`deref` is one native, `fnDbDeref`, installed as `nexis.core/deref` and
as `db/deref`. On an atom it returns the contained value; on a durable
ref it reads the stored value (`docs/DB.md`), on a Var its root
(`:unbound-var` when unbound), on a `reduced` wrapper its value, on a
delay its forced value (`force`, `docs/STDLIB.md` §8), and on anything
else it is `:not-derefable`. The reader's `@x` expands to
`(nexis.core/deref x)`, qualified so that no local or Var named `deref`
captures it (`src/expand.zig`).

---

### 6. Codec

An atom is not serializable: `docs/CODEC.md` §3 owns the table and
the `:unserializable` keyword, raised for an atom at any depth
(`(db/put! tx r [1 (atom 2)])`).

---

### 7. GC trace

`atom.trace` marks the contained value, the validator and the watches
map; the collector marks the metadata map through the header, as for
every kind; `in_flight` is a byte, not a value. An atom reachable through a collection, Var or slot is marked
through its owner's trace. An atom may hold itself,
`(let [a (atom nil)] (reset! a a) (= @a a))` is true, and the mark bit
ends the cycle (`docs/GC.md` §5).

---

### 8. Printing

`src/format.zig` prints every atom as `#<atom>`, in `pr-str` and `str`
modes alike, without the contained value, so an atom holding itself
prints. `(println @a)` prints the value, since `@a` evaluates to it
first.

---

### 9. Errors

| keyword | cause |
|---|---|
| `:atom-re-entry` | `reset!`, `swap!`, `swap-vals!` or `compare-and-set!` on an atom whose `swap!` or `swap-vals!` is running |
| `:invalid-reference-state` | a new state, or the current one under `set-validator!`, the validator answers falsy to (§4.8) |
| `:invalid-argument` | an option key with no value to `atom` |
| `:arity-mismatch` | a wrong argument count, including options to `atom` |
| `:kind-mismatch` | a non-atom to `reset!`, `swap!`, `swap-vals!`, `compare-and-set!`, `set-validator!`, `get-validator`, `add-watch` or `remove-watch`; a `:meta` option or a `reset-meta!` value that is neither a map nor nil |
| `:not-callable` | an `f` to `swap!` or `swap-vals!` that cannot be called |
| `:not-derefable` | `deref` of a value that is not an atom, Var, durable ref, delay or `reduced` |
| `:unserializable` | the codec meets an atom (§6) |
| `:kind-mismatch` | `with-meta` on an atom (SEMANTICS.md §7) |

Every one is catchable by keyword, `(catch :atom-re-entry e …)`, or
with `(catch any e …)` (`docs/VM.md` §12).

---

### 10. Tests

`src/atom.zig` tests the body layout, the accessors, the in-flight flag
and the trace (a self-referential atom included).
`test/integration/eval_pipeline.zig` runs the language surface through
the whole pipeline: identity equality and atoms as map keys, each
native, `deref` through `@a`, `deref` and `db/deref`, rollback of
`swap!` and `swap-vals!` on a throw, re-entrancy through `reset!`,
`swap!` and `compare-and-set!`, identity CAS, the type errors,
`reset-vals!` and `volatile!`, and an atom nested in a `db/put!` value
as `:unserializable`; validators on every mutator and on `atom` and
`set-validator!`, watches through every mutator (one that changes the
atom again, one that throws), the options and an atom's metadata, and
a loop whose validator and watches allocate on every call, which
`zig build test -Dgc-stress` runs with a collection every 4 KiB.
