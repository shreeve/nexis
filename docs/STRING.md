## STRING.md — UTF-8 String Heap Kind (Phase 1)

**Status**: Phase 1 deliverable. Authoritative body-layout and API contract for
the `string` heap kind. Derivative from `PLAN.md` §8.2, `docs/VALUE.md` §2.2,
`docs/SEMANTICS.md` §2.4 / §3.2, and `docs/HEAP.md`. Those documents win on
conflict.

This is the first real heap kind to land, so it also locks in the cross-kind
dispatch pattern every subsequent heap kind (bignum, list, persistent-map, …)
will follow. That pattern lives in `src/dispatch.zig`, which is introduced
alongside this module.

---

### 1. Scope

v1 ships **one** string subkind:

- **Subkind 1 — heap string.** Body is the raw UTF-8 bytes, no length
  prefix. Length is recovered from `Heap.bodyBytes(h).len`.

Reserved for later (no v1 implementation):

- **Subkind 0 — inline short string (SSO).** Up to 15 bytes of content
  live inside the `Value` tag + payload itself, no heap allocation.
  Performance optimization (PLAN §19.6 Tier 2); deferred. The subkind
  numbering is kept so SSO slots into subkind 0 without renumbering.
- **Subkind 2 — zero-copy slice over mmap page.** Needed for the Phase 6
  T2.2 "direct-from-emdb" path.

The Value layer's `Kind.string == 16` (VALUE.md §2.2) is unchanged. Two
string Values with different subkinds compare `=` iff their logical byte
content is equal, and produce the same hash; this discipline is
enforced in `src/dispatch.zig` and verified once a second subkind
lands.

---

### 2. Frozen invariants

1. **Body layout (subkind 1).** A string's body is exactly `N` UTF-8
   bytes, where `N = block.total_size - @sizeOf(Block)`. No header, no
   length prefix, no padding. Empty strings (`N == 0`) are legal.
2. **Byte-level equality** (SEMANTICS §2.4). Two strings are `=` iff
   their byte sequences are identical. No Unicode normalization
   (NFC/NFD) — v1 is deliberately byte-blob.
3. **Hash** (SEMANTICS §3.2). `hashHeader(h)` returns
   `xxHash3(seed, bytes)` truncated to `u32`, where `seed` is the
   project-wide constant in `src/hash.zig`. The final `Value.hashValue`
   for a string extends to `u64`, mixes the `Kind` byte via
   `mixKindDomain`, and returns the result.
4. **UTF-8 validation is NOT performed at the storage boundary.**
   `fromBytes` trusts its caller — the reader already produces
   well-formed UTF-8. Untrusted-bytes decoders (Phase 4 codec) are
   expected to validate before calling. A malformed-bytes `Value`
   remains byte-identical to itself, byte-equal only to another string
   with the same bytes, and hashes deterministically — equality and
   hash discipline hold even for ill-formed bytes.
5. **Not interned.** PLAN §8.4: strings are not content-deduplicated.
   Two `fromBytes(heap, "foo")` calls produce two distinct
   `*HeapHeader`s with different addresses; `(identical? a b)` is
   `false`; `(= a b)` is `true`; `(hash a) == (hash b)`.
6. **Not attachable.** PLAN §8.5 / SEMANTICS §7: v1 strings cannot
   carry metadata. `setMeta` on a string heap-header is a runtime bug;
   the check belongs at the language surface (`with-meta`), not at the
   storage layer.
7. **Cached hash: nonzero only.** A genuine computed hash of 0 is not
   written to `HeapHeader.hash` (which is still the uncomputed
   sentinel per VALUE.md §4). That string recomputes on every access.
   Cost: at most ~1-in-2³² recomputation rate. Accepted per spec.

---

### 3. Public API

Lives in `src/string.zig`.

```zig
/// Allocate a new heap string from raw UTF-8 bytes. Bytes are copied
/// into a freshly-allocated heap object. Caller is responsible for
/// passing well-formed UTF-8 (invariant 4).
pub fn fromBytes(heap: *Heap, bytes: []const u8) !value.Value;

/// Logical byte view of a string Value. Panics if `v.kind() != .string`.
/// For subkind 1 this is the body of the heap block. For future
/// subkinds (SSO, zero-copy) the same API will return the logical view
/// regardless of storage; callers must not assume the pointer lives on
/// the runtime heap.
pub fn asBytes(v: value.Value) []const u8;

/// Cheaper than asBytes when only length is needed.
pub fn byteLen(v: value.Value) usize;

/// Per-kind hash entry point. Reads the cached hash from `h.hash`; if
/// zero (uncomputed), computes `xxHash3(seed, bodyBytes(h))`,
/// truncates to u32, writes to the cache only when the result is
/// nonzero, and returns it. Called by `dispatch.heapHashValue`.
pub fn hashHeader(h: *HeapHeader) u32;

/// Per-kind equality entry point. Byte-for-byte comparison over the
/// two string headers' bodies. Called by `dispatch.heapEqual` after
/// the dispatcher has verified both sides are `.string`.
pub fn bytesEqual(a: *HeapHeader, b: *HeapHeader) bool;
```

**Subkind check.** `hashHeader` / `bytesEqual` assert `subkind == 1`
in safe builds. When SSO or zero-copy subkinds arrive, these functions
grow a branch; the assert flags the unsupported-subkind case loudly
rather than silently mishandling.

---

### 4. Cross-kind dispatch (`src/dispatch.zig`)

Landing alongside this module. The contract every subsequent heap
kind follows:

```zig
// src/dispatch.zig — single central integration point.

pub fn heapHashValue(v: value.Value) u64;
pub fn heapEqual(a: value.Value, b: value.Value) bool;
```

- `heapHashValue(v)` is called by `value.hashValue(v)` when the Kind
  dispatcher sees a heap kind. It resolves the `*HeapHeader`,
  switches on kind to the right per-kind `hashHeader`, extends the
  `u32` result to `u64`, and applies `mixKindDomain`.
- `heapEqual(a, b)` is called by `eq.equal(a, b)` from the same-kind
  heap branch. It asserts both sides share the kind, resolves both
  `*HeapHeader`s, and dispatches to the per-kind `bytesEqual` /
  `structuralEqual` / etc.

Rationale (peer-review recommendation, conversation `nexis-phase-1`
turn 6): keeping `value.zig` and `eq.zig` low-level — they describe
semantics for immediates and cross-kind rules — while cross-kind
integration lives in one module where "have we accounted for every
heap kind?" is a single-file audit.

`dispatch.zig` depends on every heap-kind module; no heap-kind module
depends on `dispatch.zig`. When a new kind lands, exactly one
`switch` arm in each dispatch function is added.

---

### 5. Interaction with other layers

- **Value layer.** `value.hashValue(v)` for `.string` delegates to
  `dispatch.heapHashValue(v)`. The Kind byte is still the canonical
  discriminator; `mixKindDomain` is still applied exactly once.
- **eq layer.** `eq.equal(a, b)` for same-kind heap strings delegates
  to `dispatch.heapEqual(a, b)`. Cross-kind comparisons still resolve
  to `false` without touching string-specific code.
- **Heap layer.** `heap.alloc(.string, len)` is the only path to a
  string heap-header. `HeapHeader.hash` caches the computed hash
  (nonzero only). `HeapHeader.flags` bits are unused for strings in
  v1 — `flag_interned` is reserved and `flag_zero_copy` will be set
  by subkind 2 when it lands.
- **Hash layer.** `string.hashHeader` calls `hash.hashBytes(bytes)`
  and truncates. No new hash primitives needed.
- **Intern layer.** No direct interaction — strings are not interned.
- **Reader.** `src/reader.zig` emits string Forms as byte slices;
  when the reader→Value lifting pass lands (Phase 2), it will call
  `string.fromBytes` with the already-validated UTF-8 from the
  grammar's `STRING` token.

---

### 6. What STRING.md does not cover

- **Inline short-string optimization (SSO).** Subkind 0. Deferred to a
  future commit; when it lands, it will preserve every invariant in §2
  except the "body is heap body" physical layout — SSO strings have no
  heap allocation, but `asBytes`/`hashHeader`/`bytesEqual` will work
  transparently.
- **Zero-copy subkind 2.** Needs mmap / emdb-page plumbing from
  Phase 6. Same transparency contract as SSO.
- **Unicode operations** (grapheme iteration, case folding, normalization,
  collation). These are stdlib-level operations that will live in a
  future `nexis.string` namespace, not in the runtime module.
- **String interning** (explicit `(intern s)`). PLAN §8.4 defers this
  to v2+ or an opt-in string module; not v1 runtime.
- **Print-time escape encoding** (`\n`, `\t`, `\u{HEX}`). That's
  already handled by `src/reader.zig`'s pretty-printer for Forms; the
  runtime `Value` → textual form path will reuse the same encoder
  when the reverse lifting pass lands.
- **Mutability / transient strings.** Strings are persistent (immutable)
  at the Value layer. Mutable string builders will be a separate
  transient-kind facility if/when needed (not committed for v1).
