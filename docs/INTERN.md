## INTERN.md — Keyword & Symbol Intern Tables (Phase 1)

**Status**: Phase 1 deliverable. Authoritative contract for the process-local
keyword and symbol intern tables that back `Value.fromKeywordId` /
`Value.fromSymbolId`. Derivative from `PLAN.md` §8.4, §10.5, §15.10 and
`docs/SEMANTICS.md` §5. PLAN.md wins on conflict.

This is the smallest piece of the runtime that persists identity across
read/eval cycles inside a process. Every bit of state it carries — id,
ordering, byte ownership, table disjointness — is frozen before first use.
Changing any of §1, §2, §3, or §5 below requires a PLAN amendment.

---

### 1. Scope and invariants

The interner maps **textual names** to **dense process-local `u32` ids** for
two independent namespaces:

- keyword ids (consumed by `Value.fromKeywordId`)
- symbol ids (consumed by `Value.fromSymbolId`)

Non-negotiable invariants:

1. **Dense-from-0 ids, per table.** First intern in a table returns `0`,
   the Nth distinct name returns `N-1`. Ids are never reused; tables never
   shrink. There is **no reserved sentinel id**. The `nil == all-zero Value`
   rule (VALUE.md §2.1) is a per-kind invariant at kind `0`, not a
   cross-kind invariant on payload zero, so a keyword with id `0` is a
   fully legitimate value.
2. **Idempotence.** Second intern of the same byte sequence returns the
   original id. No rehash, no canonicalization (no NFC/NFD — consistent
   with SEMANTICS §2.4).
3. **Independent id spaces.** The keyword table and the symbol table share
   no ids. The same text may intern to different ids in each; Value-layer
   hash-domain separation (`mixKindDomain` over the `Kind` byte, see
   `docs/SEMANTICS.md` §3.2) keeps `(= :foo 'foo) ⇒ false` and
   `(hash :foo) ≠ (hash 'foo)`.
4. **Byte-exact round-trip.** For every successfully-interned name `s`,
   `keywordName(internKeyword(s)) == s` byte-for-byte, and the same for
   symbols. No trimming, no normalization, no folding.
5. **Name bytes owned by the interner.** Each name is duplicated into
   interner-owned storage on first intern and freed in `deinit`. Callers
   may pass transient buffers (e.g. slices into a parser buffer); the
   returned name slice from `keywordName`/`symbolName` lives as long as
   the interner.
6. **No unintern, no weak semantics, no rehash-to-different-ids** in v1.
   Long-lived REPL sessions are noted as risk #16 in PLAN §25; revisit in
   v2 when a concrete workload demands it.
7. **Empty names are rejected** at the intern layer. The reader already
   won't produce them, but the intern API is also reachable from codec
   decode (future Phase 4) and direct runtime construction, so the
   rejection is pinned here rather than delegated upstream.
8. **ID-space bound.** An intern call that would make the table exceed
   `maxInt(u32)` entries returns `error.InternTableFull`. In practice
   unreachable; pinned for correctness of the `usize → u32` cast.

---

### 2. Public API

```zig
pub const Interner = struct {
    pub fn init(gpa: std.mem.Allocator) Interner;
    pub fn deinit(self: *Interner) void;

    // Raw intern — returns the dense id. Error on OOM, empty name, or
    // table-full.
    pub fn internKeyword(self: *Interner, name: []const u8) !u32;
    pub fn internSymbol (self: *Interner, name: []const u8) !u32;

    // Convenience: return a fully-constructed Value. Preferred at call
    // sites that don't need the raw id.
    pub fn internKeywordValue(self: *Interner, name: []const u8) !value.Value;
    pub fn internSymbolValue (self: *Interner, name: []const u8) !value.Value;

    // Name accessors. Panic **unconditionally** (every build mode) if
    // `id` is out of range for the table — an out-of-range id is a
    // runtime-bug leak upstream, not a user error to surface. This
    // matches the fail-fast discipline in `eq.zig` for sentinel escape.
    pub fn keywordName(self: *const Interner, id: u32) []const u8;
    pub fn symbolName (self: *const Interner, id: u32) []const u8;

    pub fn keywordCount(self: *const Interner) u32;
    pub fn symbolCount (self: *const Interner) u32;

    // GC-root tracing seam. v1 implementation is a no-op — name bytes
    // are not heap objects in the `HeapHeader` sense. Exists so the
    // GC wiring in Phase 1 can list the interner as a root without a
    // later struct refactor (PLAN §10.5).
    pub fn trace(self: *Interner, visitor: anytype) void;
};
```

**Error set.** `internKeyword` / `internSymbol` / their `*Value`
variants return a union of:

- `error.OutOfMemory` — allocator rejected the name dup or map growth
- `error.EmptyName` — input was a zero-length slice
- `error.InternTableFull` — would exceed `maxInt(u32)` entries

These errors are surfaced; callers decide whether to map them to
`:name-error` / `:oom` etc.

---

### 3. Namespace splitting (`split`)

The grammar (`nexis.grammar`) already restricts multi-slash forms and
treats the bare symbol `/` as the legal division symbol, so the reader
only ever hands the intern table one of:

- unqualified name: `"foo"`, `"+"`, `"/"`
- qualified name: `"ns/foo"` (exactly one `/`, both halves non-empty)

Nevertheless, the `split` helper is **robust against malformed raw
inputs** — it is a pure function over a `[]const u8` and therefore
reachable independently of the reader.

```zig
pub const Qualified = struct {
    ns: ?[]const u8,
    local: []const u8,
};

pub fn split(name: []const u8) SplitError!Qualified;

pub const SplitError = error{
    EmptyName,             // input is "" — not a valid symbol/keyword name
    EmptyNamespace,        // input is "/foo" — namespace half is empty
    EmptyLocalName,        // input is "foo/" — local half is empty (bare
                           // "/" is handled separately as the division symbol)
    MultipleSlashes,       // input has more than one '/'
};
```

Canonical table:

| Input    | Result                                |
|----------|---------------------------------------|
| `"foo"`  | `{ ns = null, local = "foo" }`        |
| `"+"`    | `{ ns = null, local = "+" }`          |
| `"/"`    | `{ ns = null, local = "/" }`          |
| `"a/b"`  | `{ ns = "a",  local = "b" }`          |
| `""`     | `error.EmptyName`                     |
| `"/foo"` | `error.EmptyNamespace`                |
| `"foo/"` | `error.EmptyLocalName`                |
| `"a//b"` | `error.MultipleSlashes`               |
| `"a/b/c"`| `error.MultipleSlashes`               |

Note: `"/"` is NOT `EmptyLocalName` — it is the unqualified division
symbol (`clojure.core//` in Clojure, `nexis.core//` here). The rule is:
a single `/` with no characters on either side is the bare symbol, not
a qualification.

`split` does **not** allocate and is a pure function of its input
slice. It performs one linear pass for the slash count + one for the
final split.

---

### 4. Internal shape

Private; subject to change without amendment so long as §1–§3 hold.

```zig
const Table = struct {
    by_name: std.StringHashMapUnmanaged(u32),   // name -> id
    names:   std.ArrayListUnmanaged([]const u8), // id -> duped name
};
```

Insertion sequence (lookup-then-insert, with cleanup on failure):

1. `by_name.getOrPut(name)` — if found, return the existing id.
2. Else: `dup := gpa.dupe(u8, name)` (`errdefer gpa.free(dup)`).
3. Reserve `names` capacity, `names.appendAssumeCapacity(dup)`
   (`errdefer _ = names.pop()`).
4. Ensure `by_name` has room (`ensureUnusedCapacity` pre-step), then
   `by_name.putAssumeCapacityNoClobber(dup, id)`.
5. Commit the id.

The errdefer chain ensures we never leak a duped slice on a mid-insert
allocator failure. The map's key is a slice into the duped buffer (not
into `names`'s backing storage), which is stable for the interner's
lifetime.

`deinit` frees every duped name, clears both containers.

**Debug invariant**: `by_name.count() == names.items.len` is asserted
after every successful intern and at entry to every public accessor.

---

### 5. Interaction with other layers

- **Value layer.** Ids produced here feed directly into
  `Value.fromKeywordId` / `Value.fromSymbolId`. Those constructors do
  not validate the id — validity is an interner-level invariant.
- **Hash/Eq.** The Value layer's `hashValue` and `equal` already handle
  keyword/symbol disjointness via `Kind` byte and `mixKindDomain`. The
  interner is not consulted by `hashValue` or `equal` — hashing an id
  is independent of whether the id is in the table.
- **Codec (Phase 4).** Serialization always emits textual form
  (PLAN §15.10 / SEMANTICS §5). Deserialization calls `internKeyword` /
  `internSymbol` on the receiving end. Ids are **never** serialized;
  they are process-local.
- **Heap (future).** `meta_symbol` heap objects wrap a base symbol id
  (from this table) plus a metadata map pointer. The interner never
  sees metadata; that concern belongs to the future `heap.zig` /
  `meta_symbol` module.
- **GC (future).** The interner is a root (PLAN §10.5). `trace` exists
  today as a no-op; the GC will call it to visit any heap-owned state
  reachable through interned names once heap-owned names are allowed.

---

### 6. What INTERN.md does not cover

- **Metadata-bearing symbols** — the heap `meta_symbol` kind. Future
  `heap.zig` / `docs/META-SYMBOL.md`.
- **String interning.** Strings are not interned by default (PLAN §8.4).
  An explicit `(intern s)` operation on strings may arrive in Phase 5;
  if so, it would live in the string module, not here.
- **Namespace objects** (the Clojure-style `Namespace` bearing Vars).
  Those are a Phase 3 concern (`src/namespace.zig`). The interner stores
  the *textual* `"ns/local"` form only.
- **Multi-isolate sharing.** v1 is single-isolate; each isolate has its
  own `Interner`. Cross-isolate intern sharing is a v2+ research
  direction (PLAN §16.4).
