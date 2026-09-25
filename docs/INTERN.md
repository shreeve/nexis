## INTERN.md — Keyword & Symbol Intern Tables

Authoritative contract for the process-local
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
6. **No unintern, no weak semantics, no rehash-to-different-ids.** A
   long-lived REPL session grows the tables monotonically (risk #16 in
   PLAN §25), and so does every distinct keyword or symbol name decoded
   from a store or built with `(keyword s)` / `(symbol s)`: a process
   that reads untrusted stores or input keeps each name it has seen.
7. **Empty names are rejected** at the intern layer. The reader already
   won't produce them, but the intern API is also reachable from codec
   decode and direct runtime construction, so the
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

    // `ns/name` in one step, and its inverse (§3).
    pub fn internQualifiedKeyword(self: *Interner, ns: ?[]const u8, name: []const u8) !value.Value;
    pub fn internQualifiedSymbol (self: *Interner, ns: ?[]const u8, name: []const u8) !value.Value;
    pub fn splitQualified(full: []const u8) struct { ns: ?[]const u8, name: []const u8 };

    // Name accessors. Panic **unconditionally** (every build mode) if
    // `id` is out of range for the table — every id comes from the
    // table, so an out-of-range one is a runtime bug upstream, not a
    // user error to surface.
    pub fn keywordName(self: *const Interner, id: u32) []const u8;
    pub fn symbolName (self: *const Interner, id: u32) []const u8;

    pub fn keywordCount(self: *const Interner) u32;
    pub fn symbolCount (self: *const Interner) u32;

    // Record type names, by dense per-VM type id: the printer's source
    // for `#ns.Type{...}` (PROTOCOLS.md §2.1). The VM names each type
    // as it registers it; an id never named reads back null.
    pub fn nameRecordType(self: *Interner, type_id: u32, ns: []const u8, name: []const u8) !void;
    pub fn recordTypeName(self: *const Interner, type_id: u32) ?[]const u8;
};
```

Interned names are plain allocations, not heap objects: the collector
never visits the interner.
```

**Error set.** `internKeyword` / `internSymbol` / their `*Value`
variants return a union of:

- `error.OutOfMemory` — allocator rejected the name dup or map growth
- `error.EmptyName` — the input is a zero-length slice
- `error.InternTableFull` — would exceed `maxInt(u32)` entries

These errors are surfaced; callers decide whether to map them to
`:name-error` / `:oom` etc.

---

### 3. Qualified names

A qualified keyword or symbol is interned under its full text
`ns/name`. `internQualifiedKeyword` / `internQualifiedSymbol` build that
text; `splitQualified` takes it apart again at the **first** slash, as
Clojure's `namespace` and `name` do:

| Full text        | `ns`           | `name`  |
|------------------|----------------|---------|
| `"foo"`          | null           | `"foo"` |
| `"/"`            | null           | `"/"`   |
| `"ns/foo"`       | `"ns"`         | `"foo"` |
| `"a/b/c"`        | `"a"`          | `"b/c"` |
| `"nexis.core//"` | `"nexis.core"` | `"/"`   |

The bare `/` is the unqualified division symbol (`clojure.core//` in
Clojure, `nexis.core//` here), not a qualification. `splitQualified`
does not allocate; the slices point into its input.

---

### 4. Internal shape

Private; subject to change without amendment so long as §1–§3 hold.

```zig
const Table = struct {
    by_name: std.StringHashMapUnmanaged(u32),    // name -> id
    names:   std.ArrayListUnmanaged([]const u8), // id -> duped name
};
```

Insertion sequence in `internInto` (lookup-then-insert, with errdefer
cleanup on allocator failure):

1. Reject empty name: `if (name.len == 0) return error.EmptyName`.
2. Existing-id fast path: `if (by_name.get(name)) |id| return id`.
   `StringHashMap` hashes by byte content, so the caller's transient
   slice finds the entry even when the stored key points at duped bytes.
3. Bound check: `if (names.items.len >= maxInt(u32)) return
   error.InternTableFull`, so the subsequent `@intCast` to `u32`
   cannot truncate.
4. `dup := gpa.dupe(u8, name)` with `errdefer gpa.free(dup)`.
5. `names.append(gpa, dup)` with `errdefer _ = names.pop()`.
6. `by_name.put(gpa, dup, id)` — on failure, the two `errdefer`s
   above unwind in reverse order: pop the `names` entry, then free
   the dup. No state change escapes.
7. Debug assert `by_name.count() == names.items.len` before returning.

The map's key `dup` points at the interner-owned byte buffer (NOT into
`names.items`'s backing array, which may relocate on growth), so the
key stays valid for the interner's lifetime. This is exercised by the
`"by_name lookups survive names reallocation"` inline test.

Two hash-map probes occur on the insert path (one `get`, one `put`);
on the hit path only one. A single-probe `getOrPut` refactor that
also carries the caller's transient slice into the new-entry branch
and then overwrites the key pointer with `dup` is not done — the
intern table is cold outside startup, and the simpler
code is easier to audit for errdefer correctness.

`deinit` frees every duped name, then clears both containers, after
asserting the lockstep invariant one more time so a corrupted
mutation path (if one ever slipped in) fails at teardown rather than
silently leaking.

---

### 5. Interaction with other layers

- **Value layer.** Ids produced here feed directly into
  `Value.fromKeywordId` / `Value.fromSymbolId`. Those constructors do
  not validate the id — validity is an interner-level invariant.
- **Hash/Eq.** The Value layer's `hashValue` and `equal` already handle
  keyword/symbol disjointness via `Kind` byte and `mixKindDomain`. The
  interner is not consulted by `hashValue` or `equal` — hashing an id
  is independent of whether the id is in the table.
- **Codec.** Serialization always emits textual form
  (PLAN §15.10 / SEMANTICS §5). Deserialization calls `internKeyword` /
  `internSymbol` on the receiving end. Ids are **never** serialized;
  they are process-local.
- **GC.** Names are not heap objects; the collector never visits the
  interner.

---

### 6. What INTERN.md does not cover

- **Metadata on symbols** — symbols carry none (SEMANTICS §7).
- **String interning.** Strings are not interned by default (PLAN §8.4).
  There is no `(intern s)` operation on strings; one would live in
  the string module, not here.
- **Namespace objects** (the Clojure-style `Namespace` bearing Vars).
  Those live in `src/vm.zig` (`Namespace`, `NamespaceRegistry`). The
  interner stores
  the *textual* `"ns/local"` form only.
- **Multi-isolate sharing.** The runtime is single-isolate; each
  isolate has its own `Interner`. Cross-isolate intern sharing is an
  open research direction (PLAN §16.4).
