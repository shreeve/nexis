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
| `(atom init)` | 1 | a fresh atom holding `init` |
| `(atom? x)` | 1 | true for an atom |
| `(reset! a v)` | 2 | sets `a` to `v`; returns `v` |
| `(swap! a f & args)` | 2+ | sets `a` to `(apply f @a args)`; returns the new value |
| `(swap-vals! a f & args)` | 2+ | as `swap!`; returns `[old new]` |
| `(reset-vals! a v)` | 2 | as `reset!`; returns `[old new]` (`core.nx`, over `swap-vals!`) |
| `(compare-and-set! a old new)` | 3 | sets `a` to `new` when its value is identical to `old`; returns whether it did |
| `(deref a)`, `@a` | 1 | the contained value (§5) |
| `volatile!`, `volatile?`, `vreset!`, `vswap!` | | `core.nx` aliases: a volatile is an atom (§4.7) |

All are natives in `src/stdlib.zig` except the `core.nx` definitions
named above.

Absent: validators (`:validator`, `set-validator!`), watches
(`add-watch`, `remove-watch`), metadata on an atom, and `agent`, `ref`
and `dosync` (CLOJURE-REVIEW.md). `(atom init & opts)` takes no
options: any extra argument is `:arity-mismatch`.

---

### 2. Storage

An atom is a heap block of kind 34 on the heap's live list, reclaimed
by sweep when unreachable. Its body, `AtomBox`, is 24 bytes: the
contained `value` (16 bytes), the `in_flight` re-entrancy byte, and
padding. `atom.make` allocates it; `getValue` and `setValue` read and
write the value; `tryEnterCritical` and `exitCritical` own the flag.
The header's hash slot and meta pointer are unused (`docs/HEAP.md`).

---

### 3. Equality and hash

Equality and hash: SEMANTICS.md §3.3. An atom is an identity kind:
equal only to itself and hashed by its pointer, never by the value it
holds, so `(= (atom 1) (atom 1))` is false and an atom is a stable map
key across mutations. The collector does not move blocks, so the hash
needs no cache.

---

### 4. The natives

#### 4.1 `(atom init)`

One argument; `(atom)` and `(atom 1 :meta {})` are `:arity-mismatch`.
An atom prints as `#<atom>` (§8).

#### 4.2 `(atom? x)`

True for an atom, false for anything else.

#### 4.3 `(reset! a v)`

Sets the value unconditionally and returns `v`, not the atom. Called
while `a` is in flight (§4.4) it is `:atom-re-entry`.

#### 4.4 `(swap! a f & args)`

Sets `a` to `(apply f @a args)` and returns the new value. The order is
the contract:

1. `a` not an atom → `:kind-mismatch`; `a` in flight →
   `:atom-re-entry`. Otherwise mark it in flight until the native
   returns, by any path.
2. Read the old value.
3. Call `f` with the old value and `args` through `vm.callValue`.
4. Write the result.

A throw or control transfer out of `f` leaves step 4 unreached, so the
atom is unchanged. While `f` runs, `reset!`, `swap!`, `swap-vals!` or
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
rollback. The vector is allocated after the write; `old` is rooted
through the atom while `f` runs, and no collection can run between the
write and the allocation (`docs/GC.md` §11.5). `reset-vals!` is
`swap-vals!` with `(constantly v)`.

#### 4.6 `(compare-and-set! a old new)`

Sets `a` to `new` and returns true when the current value is identical
to `old` (`identical?`: bit equality of the 16-byte value, so the same
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

---

### 5. `deref`

`deref` is one native, `fnDbDeref`, installed as `nexis.core/deref` and
as `db/deref`. On an atom it returns the contained value; on a durable
ref it reads the stored value (`docs/DB.md`), on a Var its root
(`:unbound-var` when unbound), on a `reduced` wrapper its value, and on
anything else it is `:not-derefable`. The reader's `@x` expands to
`(nexis.core/deref x)`, qualified so that no local or Var named `deref`
captures it (`src/expand.zig`).

---

### 6. Codec

An atom is not serializable: `docs/CODEC.md` §3 owns the table and
the `:unserializable` keyword, raised for an atom at any depth
(`(db/put! tx r [1 (atom 2)])`).

---

### 7. GC trace

`atom.trace` marks the contained value; `in_flight` is a byte, not a
value. An atom reachable through a collection, Var or slot is marked
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
| `:arity-mismatch` | a wrong argument count, including options to `atom` |
| `:kind-mismatch` | a non-atom to `reset!`, `swap!`, `swap-vals!` or `compare-and-set!` |
| `:not-callable` | an `f` to `swap!` or `swap-vals!` that cannot be called |
| `:not-derefable` | `deref` of a value that is not an atom, Var, durable ref or `reduced` |
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
as `:unserializable`.
