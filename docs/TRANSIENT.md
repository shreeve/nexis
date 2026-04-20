## TRANSIENT.md — Transient Wrappers (Phase 1)

**Status**: Phase 1 deliverable. Authoritative contract for the
`.transient` heap kind and the `...Bang` mutation operations.
Derivative from `PLAN.md` §9.4, `docs/VALUE.md` §2.2,
`docs/SEMANTICS.md` §2.6 (identity-based equality + serialization
disallowed), `docs/GC.md` (trace integration), and
`CLOJURE-REVIEW.md` §1.2 + §2.7 (owner-token epoch vs. thread
identity). Those documents win on conflict. Reviewed peer-AI turn 17.

This module unblocks **Phase 1 gate tests #3 (transient
equivalence) and #4 (transient ownership discipline)** per PLAN §20.2.

Scope-frozen commitment for this commit: **v1 transients are
"shallow" wrappers** — they hold an owner-token and a mutable
pointer to a persistent inner root. Mutating ops call the
persistent backing operations underneath, reassigning the wrapper's
`inner_header` field in place. Token discipline enforced at every
boundary. Node-level in-place mutation (Clojure's real perf
advantage) is explicitly deferred to a Phase 6 performance commit
(PLAN §19.6 Tier 2).

---

### 1. The two-option fork, and why v1 picks "shallow" (peer-AI turn 17)

**Option A — full Clojure-style transients** with per-node owner
tags: every CHAMP interior / collision / vector interior / leaf /
tail node grows an `owner_token: ?u64` field. Mutating ops walk the
tree and mutate owner-matched nodes in place, clone + stamp
owner-mismatched ones. Real O(1) amortized `conjBang` etc. Cost:
~8 bytes/node, every clone helper in hamt and rrb grows a
transient-aware variant, structural invariants loosen in
transient-mode.

**Option B — shallow wrappers** (v1): `.transient` is a thin heap
kind with `{owner_token, inner_header}`. Mutation ops call
`mapAssoc` / `setConj` / `vector.conj` on the inner, receive a new
persistent root, atomically update the wrapper's `inner_header`
field. No existing hamt/rrb code changes. Gate-test discipline
(#3 equivalence, #4 ownership) satisfied by construction.

**v1 picks B.** Reasons (peer-AI turn 17 concurring):
  - Gate tests measure semantics, not performance. B delivers
    semantics with ~800 LOC of new code + zero changes to stable
    persistent paths.
  - Peer-AI turn 8 specifically rejected pre-reserving transient
    fields in CHAMP nodes. Option B's landing is the payoff of
    that earlier discipline.
  - B → A is achievable later without changing the user-facing
    transient API: wrapper layout stays identical, owner-token
    discipline stays identical, only the internal mutation paths
    and node bodies change.

Option B is documented as the v1 implementation; the user-facing
wrapper API and ownership model are forward-compatible with a
Phase 6 performance revision that replaces the underlying
mutation paths with in-place editing.

---

### 2. Subkind taxonomy (local enum)

VALUE.md §2.2 is amended in this commit. Previously the row for
kind 27 said "subkind mirrors the inner collection kind" — a
reading that would reuse global kind bytes (18/19/20) as transient
subkinds. Peer-AI turn 17 flagged this: subkinds should classify
within a kind, not mirror external kind numbering.

The amended taxonomy is a **local enum**:

| Subkind | Meaning                          | Wraps       |
|---------|----------------------------------|-------------|
| 0       | transient map                    | `.persistent_map`    |
| 1       | transient set                    | `.persistent_set`    |
| 2       | transient vector                 | `.persistent_vector` |
| 3..15   | reserved                         | —           |

No other kinds are transient-wrappable in v1. Attempting to wrap a
list, string, bignum, byte-vector, typed-vector, function, var,
durable-ref, or error Value in `transientFrom` returns
`error.InvalidTransientInner`. (Byte/typed vectors and the rest
may earn transients in a future commit if profiling justifies; not
committed for v1.)

Kind 27 + subkind 0/1/2 together give enough information to
dispatch any operation without inspecting the inner header's kind.
The inner header's kind is implicitly guaranteed by construction:

  - subkind 0 wrapper's `inner_header.kind` is always `persistent_map`,
  - subkind 1 wrapper's is always `persistent_set`,
  - subkind 2 wrapper's is always `persistent_vector`.

Safe-build code asserts this at every entry point.

---

### 3. Wrapper layout

```zig
const TransientBody = extern struct {
    /// Owner-token epoch. `0` means frozen/invalidated (after
    /// `persistentBang`, or allocator-zero-init pre-stamp).
    /// Nonzero is an active owner. Tokens are monotonically
    /// assigned by a private `issueOwnerToken()` counter in
    /// `src/coll/transient.zig`; they are opaque to user code.
    owner_token: u64,

    /// Pointer to the current persistent inner root (one of:
    /// `.persistent_map` subkind 0/1, `.persistent_set` subkind
    /// 0/1, `.persistent_vector` subkind 1). Mutated in place by
    /// every successful `...Bang` op. Never null: cleared only
    /// when the wrapper itself is freed.
    inner_header: *HeapHeader,

    comptime {
        std.debug.assert(@sizeOf(TransientBody) == 16);
    }
};
```

Body size is 16 bytes; wrapper allocation total is
`@sizeOf(Block) + 16` = 48 bytes. `_pad` is not needed because the
two u64-sized fields consume the whole body.

Invariants (checked at every entry point in safe builds):

  - `owner_token != 0` on active wrappers; `== 0` on frozen.
  - `inner_header != 0` always.
  - `inner_header.kind` matches the wrapper's subkind:
    - subkind 0 → `.persistent_map`
    - subkind 1 → `.persistent_set`
    - subkind 2 → `.persistent_vector`
  - No metadata on transient wrappers (`h.meta == null`). Per
    VALUE.md §7 / SEMANTICS §7: transients are not
    metadata-attachable.

---

### 4. Owner-token model

Tokens are u64 counters issued by a **private module-level source**
in `src/coll/transient.zig`:

```zig
var next_token: u64 = 1; // 0 is reserved for "frozen"

fn issueOwnerToken() u64 {
    const t = next_token;
    next_token += 1;
    // Overflow-safe on u64 for every practical workload. Wraparound
    // after 2^64 - 1 tokens is theoretically reachable in a long-
    // running multi-isolate system; v1 single-isolate cannot.
    // Phase 7+ multi-isolate should revisit.
    return t;
}
```

**No public API exposes token issuance.** Tokens are opaque; the
transient wrapper owns token state; user code never constructs or
inspects tokens directly.

**Token semantics** (PLAN §9.4 frozen):
  - `0` = frozen/invalidated. Reached after `persistentBang` OR
    initial allocator-zero state BEFORE `transientFrom` stamps.
    Any op on a wrapper whose `owner_token == 0` returns
    `error.TransientFrozen`.
  - Nonzero = active owner. In v1 single-threaded, the token is
    effectively an aliveness signal. Phase 7+ multi-isolate will
    additionally check that the **current isolate's epoch** matches
    the token's issuing epoch; that check is absent here because
    there is no second isolate to mismatch against.

**Token exhaustion.** Owner tokens are issued from a monotonically
increasing `u64` counter. Exhaustion is not handled in v1;
wraparound is considered practically unreachable for Phase 1
workloads and should be revisited when multi-isolate support
lands. No saturation / error path is provided.

**`TransientWrongOwner` in v1.** The error variant exists in the
`TransientError` set for Phase 7+ forward compatibility, but no v1
runtime code path produces it — single-isolate, single-threaded
Phase 1 has no legitimate way for a transient to encounter a
mismatched-but-nonzero owner. Gate test #4 is satisfied by the
frozen-rejection path alone: "using a transient after
`persistentBang`" IS the v1 operational manifestation of "using a
transient from the wrong owner" (the owner has become the
nobody-token `0`). The `TransientWrongOwner` code path is wired in
`transient.zig` so Phase 7+ can light it up by adding an isolate-
epoch comparison without introducing a new error kind.

---

### 5. State machine

Every `.transient` wrapper is in exactly one of three states:

```
            transientFrom(persistent_v)
                │
                ▼
        ┌───────────────┐
        │     ACTIVE    │  owner_token != 0
        │               │  mutating ops allowed
        │               │  reads allowed
        └───────┬───────┘
                │  persistentBang(t)
                ▼
        ┌───────────────┐
        │     FROZEN    │  owner_token == 0
        │  (invalidated)│  any op returns .TransientFrozen
        │               │  wrapper still GC-reachable via
        │               │  inner_header, but discarded for user use
        └───────┬───────┘
                │  wrapper unreachable from roots
                ▼
        ┌───────────────┐
        │      DEAD     │  sweep frees the wrapper header
        │               │  inner_header still traceable from
        │               │  other roots if any hold it
        └───────────────┘
```

**All** transient ops — `...Bang` mutations AND queries (`mapGet`,
`setContains`, `mapCount`, etc.) — reject frozen wrappers.
Per peer-AI turn 17: keeping reads also rejecting frozen makes the
ownership discipline crisp. The user-visible rule is simple:
"after `persistentBang`, the transient is dead; use the returned
persistent value instead."

**`persistentBang` does NOT null `inner_header`.** Only zeros
`owner_token`. Rationale: the wrapper may still be GC-reachable
from other roots; leaving `inner_header` intact lets GC continue
to trace through it without special-casing frozen wrappers.

---

### 6. Error surface

Public transient ops return typed errors at the user boundary
(peer-AI turn 17):

```zig
pub const TransientError = error{
    TransientFrozen,            // owner_token == 0
    TransientWrongOwner,        // owner mismatch (Phase 7+ primary; v1 test-only)
    InvalidTransientInner,      // transientFrom on a non-wrappable kind
    TransientKindMismatch,      // e.g., mapAssocBang called with a set wrapper
};
```

Each public entry point:
  - asserts in safe builds that the Value's kind is `.transient`,
  - returns `error.TransientKindMismatch` if the Value's subkind
    doesn't match the op family (mapAssocBang on a set, etc.),
  - returns `error.TransientFrozen` if `owner_token == 0`,
  - (Phase 7+) returns `error.TransientWrongOwner` on token
    mismatch,
  - proceeds to the underlying persistent op.

Non-safe-build safety: in Release builds, kind/subkind
assertions are compiled out. The token + frozen checks remain.
Users calling `...Bang` on a non-transient Value in a release
build get undefined behavior — same discipline as calling
`mapAssoc` on a list value.

---

### 7. Public API

Lives in `src/coll/transient.zig`. All ops take callbacks for
hash/eq the same way their persistent counterparts do.

```zig
// ---- Wrapping / unwrapping ----

/// Wrap a persistent map/set/vector Value as an active transient.
/// `error.InvalidTransientInner` on any other kind.
pub fn transientFrom(heap: *Heap, persistent_v: Value) !Value;

/// Freeze the wrapper and return the current inner persistent
/// Value. The wrapper's `owner_token` is zeroed; subsequent ops
/// on the wrapper return `error.TransientFrozen`. The returned
/// persistent Value is safe to share.
pub fn persistentBang(t: Value) !Value;

// ---- Transient map ops (inner subkind 0) ----

pub fn mapAssocBang(
    heap: *Heap, t: Value, key: Value, val: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value;    // returns the same transient wrapper (pointer-stable)

pub fn mapDissocBang(
    heap: *Heap, t: Value, key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value;

pub fn mapGetBang(
    t: Value, key: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !MapLookup;     // same union as persistent side

pub fn mapCountBang(t: Value) !usize;

// ---- Transient set ops (inner subkind 1) ----

pub fn setConjBang(
    heap: *Heap, t: Value, elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value;

pub fn setDisjBang(
    heap: *Heap, t: Value, elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !Value;

pub fn setContainsBang(
    t: Value, elem: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !bool;

pub fn setCountBang(t: Value) !usize;

// ---- Transient vector ops (inner subkind 2) ----

pub fn vectorConjBang(heap: *Heap, t: Value, elem: Value) !Value;
pub fn vectorNthBang(t: Value, idx: usize) !Value;
pub fn vectorCountBang(t: Value) !usize;
```

**`isEmptyBang` is deliberately not exported.** `countBang == 0`
suffices; a dedicated `isEmptyBang` per kind is trivial wrapper
surface area that peer-AI turn 18 recommended against bloating the
public API with. Users who want the check call
`(try mapCountBang(t)) == 0`.

**Vector `assocBang` is deferred.** PLAN §9.2's vector supports
`assoc n v` in the persistent path (random index update via
path-copy), and a transient `assocBang` would parallel it. But
`assocBang` isn't landed in `src/coll/rrb.zig`'s Scope A commit
yet, so its transient counterpart can't exist either. When the
persistent `assoc n v` ships (Phase 6 or a scheduled vector Scope
B commit), `vectorAssocBang` joins the transient API.

**`...Bang` ops return the same transient wrapper Value they were
given.** The wrapper's `inner_header` field is mutated in place.
Pointer-stability means callers can hold a `Value` for the
lifetime of the transient session; they don't need to rebind it on
each op. (Internal implementation may optimize this differently
in the future; the user-facing contract is pointer-stable.)

---

### 8. Implementation sketch

**Per-kind root reconstruction helpers (new).** The transient
module needs to reconstruct a persistent Value from a raw
`*HeapHeader` — e.g. to call `hamt.mapAssoc(heap, v, …)` where `v`
is a persistent-map Value built from the transient's
`inner_header`. Per peer-AI turn 18, this is kind-specific
knowledge (CHAMP/array-map subkind discovery via body-size
inspection; vector root is always subkind 1) and shouldn't live in
transient code. Each collection module exports a small helper:

```zig
// src/coll/hamt.zig
pub fn valueFromMapHeader(h: *HeapHeader) Value;
pub fn valueFromSetHeader(h: *HeapHeader) Value;

// src/coll/rrb.zig
pub fn valueFromVectorHeader(h: *HeapHeader) Value;
```

These wrap the existing `inferRootSubkind` / `inferSetRootSubkind`
logic behind a single per-kind entry point. The transient module
calls them; it never inspects kind-specific body layouts.

```zig
// Wrapping
pub fn transientFrom(heap: *Heap, v: Value) !Value {
    const inner_kind = v.kind();
    const subkind: u16 = switch (inner_kind) {
        .persistent_map => subkind_transient_map,      // 0
        .persistent_set => subkind_transient_set,      // 1
        .persistent_vector => subkind_transient_vector, // 2
        else => return error.InvalidTransientInner,
    };
    const h = try heap.alloc(.transient, @sizeOf(TransientBody));
    const body = Heap.bodyOf(TransientBody, h);
    body.owner_token = issueOwnerToken();
    body.inner_header = Heap.asHeapHeader(v);
    return .{
        .tag = @as(u64, @intFromEnum(Kind.transient)) | (@as(u64, subkind) << 16),
        .payload = @intFromPtr(h),
    };
}

// Freezing
pub fn persistentBang(t: Value) !Value {
    try assertTransientActive(t);
    const h = Heap.asHeapHeader(t);
    const body = Heap.bodyOf(TransientBody, h);
    const inner = body.inner_header;
    body.owner_token = 0; // freeze
    return innerValueForSubkind(t.subkind(), inner);
}

// Mutation (map example)
pub fn mapAssocBang(heap, t, key, val, hash, eq) !Value {
    try assertTransientActive(t);
    try assertSubkind(t, subkind_transient_map);
    const h = Heap.asHeapHeader(t);
    const body = Heap.bodyOf(TransientBody, h);
    const old_v = hamt.valueFromMapHeader(body.inner_header);
    const new_v = try hamt.mapAssoc(heap, old_v, key, val, hash, eq);
    body.inner_header = Heap.asHeapHeader(new_v);
    return t; // same pointer
}

// Subkind → persistent Value dispatch (single place transient
// crosses into kind-specific reconstruction; calls only the public
// per-kind `valueFromXxxHeader` helpers).
fn innerValueForSubkind(subkind: u16, h: *HeapHeader) Value {
    return switch (subkind) {
        subkind_transient_map => hamt.valueFromMapHeader(h),
        subkind_transient_set => hamt.valueFromSetHeader(h),
        subkind_transient_vector => vector.valueFromVectorHeader(h),
        else => unreachable,
    };
}

// Validation helpers
fn assertTransientActive(t: Value) !void {
    if (t.kind() != .transient) return error.TransientKindMismatch;
    const body = Heap.bodyOf(TransientBody, Heap.asHeapHeader(t));
    if (body.owner_token == 0) return error.TransientFrozen;
}
```

---

### 9. Equality, hash, print, codec

Per SEMANTICS §2.6 / PLAN §15.10:

- **Equality**: transients compare by `identical?` only — two
  transient Values are equal iff they are the same wrapper header
  pointer. Two structurally-identical transients built
  independently are NOT equal.
- **Hash**: transients are not hashable. `dispatch.hashValue` on a
  transient panics with `:no-hash-on-transient`. This matches
  Clojure's semantics and guards against accidentally using a
  transient as a map key.
- **Print**: `#object[transient 0x...]`-style diagnostic print for
  REPL debugging. Does NOT round-trip (`read` does not produce
  transients; `pr-str` output is not codec-compatible).
- **Codec**: transients are non-serializable per PLAN §23 #25.
  Codec encode on a transient throws `:unserializable`.
- **Metadata**: not attachable per PLAN §8.5 / SEMANTICS §7.

These are enforced in `dispatch.zig`:

```zig
// In heapHashBase:
.transient => std.debug.panic(
    "dispatch.hashValue: transients are not hashable (SEMANTICS §3.2). " ++
    "Call persistentBang first or avoid using transients as map keys / set elements.",
    .{},
),

// In heapEqual:
.transient => a == b,  // bit-identity on headers (same wrapper pointer)
```

The `dispatch.equal` top-level bit-identity fast path (`a.tag ==
b.tag and a.payload == b.payload`) already catches same-wrapper
comparisons before reaching `heapEqual`. The explicit transient
arm in `heapEqual` is defensive routing per peer-AI turn 17:
makes transient identity semantics visible in the dispatch table
rather than an accidental fast-path consequence.

Two distinct transient wrappers never compare equal even if
their `inner_header`s happen to point at the same persistent
structure. (Unusual but possible construction: `let t1 =
transientFrom(v); let t2 = transientFrom(v);` — `t1 != t2` by
identity.)

---

### 10. GC interaction

The `.transient` kind ships with a `trace` function in
`src/coll/transient.zig` that the Collector (`src/gc.zig`) imports
at its `.transient` arm:

```zig
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    const body = Heap.bodyOf(TransientBody, h);
    // The wrapper has one outgoing heap reference: inner_header.
    // Even on frozen wrappers (owner_token == 0), the inner_header
    // is still a valid *HeapHeader that the GC must walk so the
    // inner persistent structure survives while the wrapper does.
    // Other roots holding the persistent Value independently would
    // keep it alive regardless; this trace covers the case where
    // only the wrapper holds the reference.
    visitor.mark(body.inner_header);
}
```

After `persistentBang`: the wrapper still traces its
`inner_header` until the wrapper itself becomes unreachable.
Freezing does NOT sever the GC edge — clearing `owner_token` is
the only state change. This simplifies GC reasoning: frozen
wrappers behave identically to active wrappers at the trace
level.

The collector's `mark` dispatch in `src/gc.zig` replaces the
current `.transient => panic` arm with
`.transient => transient_mod.trace(h, self)`.

---

### 11. Dispatch wiring (one-way terminal, same discipline as `gc.zig`)

`src/dispatch.zig` gains a `.transient` arm in `heapHashBase`
(panic per §9) and `heapEqual` (explicit bit-identity per §9).
The `equal` switch's `.kind_local` arm continues to handle
transients via the standard kind-local dispatch — no category
changes needed since `eqCategory(.transient) == .kind_local`
already in the exhaustive table test.

`src/gc.zig` gains a real `.transient => transient_mod.trace(h,
self)` arm in `mark`.

The transient module itself imports `heap`, `value`, `hamt`, and
`vector` (plus whatever the set ops need, which is the same hamt
module). No other module depends on `transient.zig`.

---

### 12. Testing

Inline tests in `src/coll/transient.zig`:

- `transientFrom` wraps map/set/vector; errors on list/string/bignum/nil.
- Basic lifecycle: `transientFrom → mapAssocBang × N → persistentBang`.
- Freeze semantics: `persistentBang` then any op errors `TransientFrozen`.
- Owner-token uniqueness: two `transientFrom` calls produce two
  distinct tokens.
- Subkind mismatch: `mapAssocBang` on a set transient errors
  `TransientKindMismatch`.
- Pointer-stability: `mapAssocBang` returns the same wrapper Value.
- Mutation visibility: after `mapAssocBang`, `mapGetBang` reflects
  the update.
- Nil-key/nil-value legal (inherited from persistent ops).
- GC trace exercised: wrap a map, disconnect the persistent root,
  collect with only the transient as root — inner structure survives.

Property tests in `test/prop/transient.zig` (new):

- **T1. Equivalence (gate test #3)**: for random edit sequences
  of length 0..40 applied to identical starting maps/sets/vectors,
  the (transient → N × ...Bang → persistentBang) path and the
  direct (persistent × N × assoc/conj) path produce
  `dispatch.equal` and `dispatch.hashValue`-equal results. 300
  trials per kind.
- **T2. Ownership (gate test #4)**: frozen transients reject
  every subsequent op with `error.TransientFrozen`. v1 has no
  operational `TransientWrongOwner` path (single-isolate); the
  error kind is retained in the API for Phase 7+ forward
  compatibility.
- **T3. No mutation escapes the wrapper**: after a session of
  `...Bang` ops on transient `t`, the original persistent value
  the transient was wrapped from is still structurally intact
  (persistent semantics preserved end-to-end).
- **T4. GC survival**: random graphs of transients holding
  persistent inner structures; collect with random root subsets;
  every reachable inner structure survives intact.

Together T1 and T2 deliver the PLAN §20.2 gate test #3 and #4
receipts. v1 has no test-only `_testReplaceOwnerToken` helper
(peer-AI turn 18 recommendation against direct internal state
surgery) — instead the ownership discipline is tested entirely
through the frozen path, which is the operationally reachable
ownership failure in single-isolate Phase 1.

---

### 13. Scope frozen / deferred

**In (this commit):**
  - `.transient` kind, three subkinds (0/1/2).
  - `transientFrom` / `persistentBang`.
  - Map, set, vector mutation ops per §7.
  - Wrapper layout, owner-token source, state machine.
  - GC trace integration.
  - Dispatch hash-panic + equality-identity arms.
  - Inline + property tests for T1–T4.
  - VALUE.md §2.2 amendment: transient subkind is a local enum.

**Deferred:**
  - **Node-level in-place mutation** (Option A, real Clojure-
    style). Phase 6 Tier 2 performance commit.
  - **Transient vector `assocBang`**. Depends on persistent
    `vector.assoc` which is in vector Scope B (not yet shipped).
  - **Transient byte-vector / typed-vector**. Depends on those
    kinds existing.
  - **Multi-isolate token mismatch path** (gate #4 cross-owner
    case). Phase 7+ when isolates exist; v1 tests manufacture
    via internal helper.
  - **Auto-promotion** of array-map/set when growing beyond 8
    entries while transient. Today the persistent `mapAssoc`
    handles promotion internally; the transient inherits this
    behavior automatically. A dedicated transient promotion
    path would be Phase 6 optimization work.

---

### 14. Amendment note for VALUE.md §2.2

This commit updates VALUE.md §2.2's row 27:

```
| 27 | `transient` | mutable wrapper | subkind mirrors the inner collection kind |
```

to:

```
| 27 | `transient` | mutable wrapper | 0 = map, 1 = set, 2 = vector (local enum, peer-AI turn 17) |
```

Previous phrasing would have subkinds mirror kind bytes 18/19/20;
amended phrasing uses a local enum so the subkind field classifies
within `.transient` rather than pulling external kind numbering
into the transient namespace.
