## ATOM.md — In-memory mutable cells

Authoritative contract for `Kind.atom` (`src/atom.zig`) and the
`atom`/`atom?`/`reset!`/`swap!`/`swap-vals!`/`compare-and-set!`
native fns in `nexis.core`. Derivative from `PLAN.md` §23 (Hard
Decisions; atoms enter v1 by Amendment Log entry), `docs/VALUE.md`
§2.2 (kind 34 `atom`) and `docs/SEMANTICS.md` §3.2 (equality
categories). Those documents win on conflict.

Atoms are the in-memory mutable identity; durable mutation is
`db/alter!` + `with-tx` (`docs/DB.md`). Atoms cover EPHEMERAL
mutation, single-VM, single-thread.

Atoms are NOT a Clojure CAS retry primitive. PLAN.md §23 #5 freezes
nexis v1 as single-isolate, single-threaded; an atom is a single
mutable cell whose API mirrors `clojure.core/atom` for portability,
but whose `compare-and-set!` is a deterministic check-and-set under
the single-threaded execution model — no retry loop, no
synchronization primitives.

---

### 1. Scope

**In:**
- `Kind.atom = 34` — heap kind, 16-byte aligned body, GC-traced.
- `AtomBox { value: Value, in_flight: bool, _pad: ... }` — heap body.
- Per-kind dispatch integration: hash by pointer identity, equality by
  pointer identity, GC trace marks the contained value, codec arm
  throws `:unserializable`.
- `nexis.core` native fns: `atom`, `atom?`, `reset!`, `swap!`,
  `swap-vals!`, `compare-and-set!`.
- Universal `(deref x)` and `@x` cover atoms: `fnDbDeref` is the
  universal-deref native for `durable_ref`, `var_` and `atom`, installed
  in `nexis.core` as plain `deref` and aliased as `db/deref`.
- `swap!` re-entrancy detection: an `in_flight` flag on `AtomBox`
  causes nested `swap!`/`reset!`/`compare-and-set!`/`swap-vals!` on the
  SAME atom to throw `:atom-re-entry`. `deref` of an in-flight atom is
  allowed.
- `swap!`/`swap-vals!` rollback-on-throw: if the user fn throws or
  control-transfers, the atom is NOT mutated. Proved by the order of
  operations (read → call → write) plus a `defer` on `in_flight`.
- Printable representation: `#<atom 0x…>` (pointer identity, NOT the
  contained value — avoids self-reference infinite loops).

**Absent:**
- Validators (`:validator`), watches (`add-watch` / `remove-watch`),
  metadata on atoms (`:meta`). Every keyword opt to `(atom init …)`
  throws `:unsupported-arg`.
- Real CAS / lock-free concurrency primitives. Single-threaded v1 has
  no meaning for these; atoms here are sequential mutable cells.
  Multi-isolate concurrency is post-v1 (PLAN.md §23 #5).
- `agent` / `ref` / `dosync` — explicitly removed from v1 per
  Appendix A.
- Codec round-trip — atoms are NOT serializable (see §6).

---

### 2. Storage

```zig
// src/value.zig — Kind enum, in the heap range (16..63):
atom = 34,    // in-memory mutable
              // cell. Payload is *HeapHeader → AtomBox in heap body.

// src/atom.zig (new module):
pub const AtomBox = extern struct {
    value: Value,        // 16 bytes; current contained Value
    in_flight: u8,       // 0 or 1; re-entrancy guard
    _pad: [7]u8,         // pad to 24 bytes; AtomBox alignment ≤ 16
};
comptime { std.debug.assert(@alignOf(AtomBox) <= 16); }
comptime { std.debug.assert(@sizeOf(AtomBox) == 24); }
```

Allocation:

```zig
pub fn make(heap: *Heap, init: Value) !Value {
    const h = try heap.alloc(.atom, @sizeOf(AtomBox));
    const body = Heap.bodyOf(AtomBox, h);
    body.value = init;
    body.in_flight = 0;
    return Value{ .tag = @intFromEnum(Kind.atom), .payload = @intFromPtr(h) };
}
```

The header carries the standard mark bit, flags, cached hash slot, and
optional meta pointer. `flag_has_meta` is unused for v1 atoms (no
`:meta` opt); reserved for post-v1.

Atoms are heap kinds in the standard sense — they live on the live
list owned by `Heap`, participate in mark-sweep, and are reclaimed in
sweep when unreachable. They are NOT runtime-arena-staged like the
raw-pointer-in-payload Closure/UpvalCell/Var bodies; those staged
encodings predate the GC migration and will move to standard heap
form later. New kinds (this one included) use the standard form
directly.

---

### 3. Equality and hash

**Equality is pointer-identity.** Two distinct atoms holding `(= a b)`
values are NOT equal:

```clojure
(= (atom 1) (atom 1))             ; => false
(let [a (atom 1)] (= a a))        ; => true
```

This matches Clojure: atom equality is reference equality. It also
matches the runtime invariant that mutable identity values must NOT
participate in structural equality (otherwise a value being a key in a
map could become unequal to itself after a mutation — disaster).

```zig
// src/atom.zig:
pub fn atomsEqual(a: *HeapHeader, b: *HeapHeader) bool {
    return a == b;
}
```

`dispatch.equal` adds an arm for `.atom` that delegates to
`atom.atomsEqual`.

**Hash is pointer-identity, kind-domain-mixed.** The hash domain byte
is `@intFromEnum(Kind.atom) = 34`, placed via
`hash.mixKindDomain(..., 34)` exactly as `durable_ref` (domain 26),
`native_fn`, etc. do. This keeps atoms in their own hash domain
distinct from the sequential/associative/set shared domains
(SEMANTICS.md §3.2), so an atom and a `durable_ref` whose body bytes
happened to hash-collide remain hash-distinct.

```zig
pub fn hashHeader(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    const ptr_bytes = std.mem.toBytes(@intFromPtr(h));
    hasher.update(&ptr_bytes);
    const truncated: u32 = @truncate(hasher.final());
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}
```

Caching the pointer-hash is safe BECAUSE the pointer itself never
changes for the lifetime of the atom. Only the contained `value` can
change; pointer-hash is invariant under value mutation. (A moving
collector would require the atom hash to migrate to a stable
object-identity instead of raw `@intFromPtr`; the collector is
non-moving, `docs/GC.md`.)

**`dispatch.eqCategory` mapping:**

```zig
.{ .kind = .atom, .cat = .kind_local, .domain = 34 },
```

Same shape as `durable_ref` and the other identity-valued kinds.

---

### 4. The `nexis.core` native fns

All six install in `nexis.core` so `(atom …)`, `(swap! a f)`, etc.
resolve without a namespace prefix. None are macros.

#### 4.1 `(atom init)`

Single-arity only in this commit. Any extra args throw
`:unsupported-arg` (validators/watches/meta keyword opts are reserved
post-v1; see §1).

```clojure
(atom 0)              ; => #<atom 0x...>
(atom :keyword-init)  ; => #<atom 0x...>
(atom)                ; throws :unsupported-arg (arity)
(atom 1 :meta {})     ; throws :unsupported-arg (no keyword opts)
```

Allocation goes through `heap.alloc(.atom, …)` via `atom.make`. Result
is the new atom Value.

#### 4.2 `(atom? x)`

Kind predicate. `(atom? (atom 1)) → true`, anything else → `false`.

#### 4.3 `(reset! a v)`

Unconditional set. Returns the new value (NOT the atom — matches
Clojure).

```clojure
(let [a (atom 0)]
  (reset! a 42))
;; => 42
;; @a is now 42
```

Re-entrancy: if `a.in_flight = 1`, throws `:atom-re-entry`. Sets
`a.value = v`, returns `v`.

#### 4.4 `(swap! a f & args)`

Read-modify-write. Semantically equivalent to:

```clojure
(let [old @a, new (apply f old args)] (reset! a new))
```

with rollback-on-throw atomicity. Returns the new value.

Implementation order is load-bearing:

```zig
fn swap_impl(vm: *VM, a_h: *HeapHeader, f: Value, extra: []const Value) !Value {
    const body = Heap.bodyOf(AtomBox, a_h);
    if (body.in_flight == 1) return VmError.AtomReEntry;
    body.in_flight = 1;
    defer body.in_flight = 0;

    // 1. read
    const old = body.value;

    // 2. build call_args = [old, ...extra]
    const call_args = try vm.allocator.alloc(Value, 1 + extra.len);
    defer vm.allocator.free(call_args);
    call_args[0] = old;
    for (extra, 0..) |x, i| call_args[1 + i] = x;

    // 3. invoke. May throw / control-transfer. NO write on error.
    const new_val = try vm.callValue(f, call_args);

    // 4. write
    body.value = new_val;
    return new_val;
}
```

The `defer body.in_flight = 0` ensures the flag clears on every exit
path — normal return, thrown VmError, or VM-internal control transfer.
No `try/finally` is needed for rollback itself;
the write only happens at step 4, which is only reached if `callValue`
returns normally.

Re-entrancy semantics: if `f` calls
`swap!`/`reset!`/`compare-and-set!`/`swap-vals!` on the SAME atom,
those nested calls observe `in_flight = 1` and throw `:atom-re-entry`.
The outer `swap!` then propagates that error and does NOT write (the
inner throw unwinds before step 4). This is stricter than Clojure's
CAS retry semantics but is the only sensible single-threaded behavior:
nexis cannot retry `f`, so silently overwriting the inner write would
be surprising.

`(deref a)` and `@a` of an in-flight atom are ALLOWED — `deref` does
not touch `in_flight` and never mutates.

#### 4.5 `(swap-vals! a f & args)`

Like `swap!`, but returns a 2-vector `[old new]` (Clojure-shape, NOT a
list). Rollback semantics identical: on throw, atom NOT mutated,
nothing returned (the exception propagates).

Order of operations:

```text
1. check in_flight, set in_flight = 1 with defer reset
2. old = body.value
3. new_val = vm.callValue(f, [old, ...extra])         // may throw
4. body.value = new_val
5. result_vec = vector_mod.fromTwo(old, new_val)
6. return result_vec
```

**GC rooting note:** step 5 allocates a 2-element vector AFTER the
atom write at step 4, when `old` (a Zig local) is no longer
reachable from the atom. A collection cannot run there: the only
safe point is the VM's instruction fetch and `Heap.alloc` never
collects (`docs/GC.md` §7), so `old` is only ever at risk during
the callback of step 3, where it is the atom's value and rooted
through it. `docs/GC.md` §11.5 states the rule every native follows.

#### 4.6 `(compare-and-set! a old new)`

Identity-based check-and-set. Returns `true` if the swap happened,
`false` otherwise.

```zig
if (body.in_flight == 1) return VmError.AtomReEntry;
if (identicalImmediate(body.value, old)) {
    body.value = new;
    return value_mod.fromBool(true);
}
return value_mod.fromBool(false);
```

The comparison uses `identical?` semantics (`eq.identicalImmediate`-
shaped: bit-equality for immediates, pointer-equality for heap kinds),
NOT `=` (structural). This matches Clojure's
documented "identical to oldval" CAS contract and avoids the surprise
of value-equal-but-distinct collections matching by accident.

Re-entrancy: same `in_flight` guard as `swap!`/`reset!`. CAS does NOT
itself set `in_flight` (it doesn't call user code) but DOES throw
`:atom-re-entry` if called from inside an in-flight `swap!` on the
same atom.

---

### 5. `deref` integration

`deref` is unified over `{durable_ref, var_, atom}` in one native
fn, `fnDbDeref`:

1. The same descriptor (`&native_db_deref` — the name is internal,
   the descriptor is shared) is installed as `db/deref` AND in
   `core_fns` as bare `deref`. Both `(deref x)` and `(db/deref x)`
   resolve to the same call.
2. The `.atom` arm of the `fnDbDeref` switch:
   ```zig
   .atom => atom.deref(x),
   ```
   where `atom.deref(v: Value) Value` returns `Heap.bodyOf(AtomBox, h).value`.
3. The `@x` reader-macro lowering in `expand.zig` is `@x → (db/deref x)`,
   which dispatches over atoms through the same switch.

The `fnDbDeref` switch:

```zig
return switch (x.kind()) {
    .durable_ref => /* existing arm: ephemeral read tx */,
    .var_        => /* existing arm: Var.root, throws :unbound-var */,
    .atom        => atom.deref(x),
    else         => VmError.NotDerefable,
};
```

---

### 6. Codec

Atoms are NOT serializable. Per `PLAN.md` §23 #25, the v1 codec
serializable set is fixed; atoms are NOT in it (they join functions,
Vars, transients, tx handles, error traces).

`codec.encodeValue` adds an `.atom` arm that returns
`error.Unserializable`. Nested atoms inside maps/vectors propagate the
same error (existing recursive encoder behavior).

```zig
.atom => return error.Unserializable,
```

User-facing surface: any `db/put!` of a value containing an atom
throws `:unserializable`. Test pins this for direct (`(db/put! tx ref
(atom 1))`) and nested (`(db/put! tx ref {:k (atom 1)})`) cases.

---

### 7. GC trace

```zig
// src/atom.zig:
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = Heap.bodyOfConst(AtomBox, h);
    visitor.visit(body.value);
}
```

The single trace edge is the contained `value`. `in_flight` is a u8,
not a Value. The flag bit (mark, has-meta, hash-cached) live in the
header per the standard heap layout and are managed by the collector,
not by `trace`.

Atoms held in maps/vectors/Vars/slots are reachable through their
owning collection's trace; the chain composes correctly because every
intermediate kind already traces its element/value Values.

Cycles are possible:

```clojure
(let [a (atom nil)] (reset! a a))
;; a now references itself; @a is a
```

Mark-sweep handles cycles correctly by construction. The
self-reference test pins this as a sanity check; no special handling
required.

---

### 8. Printing

The `formatValue` helper in `cli.zig` adds an `.atom` arm. Output is
opaque:

```text
#<atom 0x7f8a1c00a000>
```

Does NOT recurse into the contained value. Reason: an atom holding
itself (a legal Lisp value) would otherwise recurse forever. The
opaque form sidesteps the issue and matches Clojure's
`#object[clojure.lang.Atom 0x... {:status :ready, :val ...}]`-shape
(though shorter).

A future REPL command like `(pprint @a)` or `(println @a)` will format
the contained value via the normal recursive printer, since `@a` ≡
`(deref a)` evaluates to the contained value before printing.

---

### 9. Errors

| Keyword              | Cause                                                     |
|----------------------|-----------------------------------------------------------|
| `:atom-re-entry`     | nested mutation op on a same atom whose `in_flight = 1`   |
| `:unsupported-arg`   | extra args to `(atom init …)` (validators/watches/meta)   |
| `:kind-mismatch`     | non-atom passed to `reset!`/`swap!`/`swap-vals!`/`CAS`    |
| `:not-callable`      | non-fn `f` passed to `swap!`/`swap-vals!`                 |
| `:unserializable`    | codec encounters an atom                                  |
| `:not-derefable`     | `deref` of a value that is not a durable ref, Var or atom |

All are catchable via `(try … (catch _ e))` (`docs/VM.md` §12).

---

### 10. Test surface

Inline + integration tests. Names follow the `phase5: atoms — …`
convention.

**Equality & identity:**
- `(= (atom 1) (atom 1)) → false`
- `(let [a (atom 1)] (= a a)) → true`
- `(let [a (atom 1)] (get {a :one} a)) → :one` — atom-as-map-key
- `(get {(atom 1) :one} (atom 1)) → nil` — distinct atoms don't collide

**Single-call ops:**
- `(atom? (atom 1)) → true`; `(atom? 1) → false`
- `(reset! a 42)` returns `42`; `@a → 42`
- `(let [a (atom 1)] (swap! a inc)) → 2`
- `(swap! a + 10 20)` — variadic args

**Universal deref:**
- `@(atom 5) → 5`
- `(deref (atom 5)) → 5`
- `(db/deref (atom 5)) → 5` — alias works
- `examples/todo-app.nx` passes (durable_ref deref unchanged)

**Rollback on throw:**
- `(let [a (atom 11)]
     (try (swap! a (fn [_] (throw :bad))) (catch _ :caught))
     @a) → 11`
- Same for `swap-vals!`.

**Re-entrancy detection:**
- `(let [a (atom 0)]
     (try (swap! a (fn [_] (reset! a 9))) (catch _ e e))) → :atom-re-entry`
- `@a → 0` (outer write never happened)
- Same hazard tested for nested `swap!` and CAS.

**`compare-and-set!`:**
- `(compare-and-set! a 11 100) → true` (when `@a` is `11`), `@a → 100`
- `(compare-and-set! a 11 200) → false` (when `@a` is `100`), `@a → 100`
- CAS with structurally-equal-but-distinct values fails:
  `(let [a (atom [1])] (compare-and-set! a [1] 2)) → false`

**`swap-vals!`:**
- `(let [a (atom 100)] (swap-vals! a inc)) → [100 101]`; `@a → 101`
- Failure rollback as above.

**Type errors:**
- `(reset! 1 2)` → `:kind-mismatch`
- `(swap! (atom 1) 2)` → `:not-callable`
- `(compare-and-set! 1 1 2)` → `:kind-mismatch`

**Codec:**
- `(db/put! tx ref (atom 1))` → `:unserializable`
- `(db/put! tx ref {:k (atom 1)})` → `:unserializable` (nested)

**Self-reference:**
- `(let [a (atom nil)] (reset! a a) (= @a a)) → true`

---

