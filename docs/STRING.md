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
  collation). Phase 5.2b will ship case conversion + trim as
  **ASCII-only** in `nexis.string`. Full Unicode case folding,
  grapheme clustering, normalization, and collation are post-v1 and
  will require a dedicated Unicode tables module.
- **String interning** (explicit `(intern s)`). PLAN §8.4 defers this
  to v2+ or an opt-in string module; not v1 runtime.
- **Print-time escape encoding** (`\n`, `\t`, `\u{HEX}`). That's
  already handled by `src/reader.zig`'s pretty-printer for Forms; the
  runtime `Value` → textual form path will reuse the same encoder
  when the reverse lifting pass lands.
- **Mutability / transient strings.** Strings are persistent (immutable)
  at the Value layer. Mutable string builders will be a separate
  transient-kind facility if/when needed (not committed for v1).

---

### 7. Language-level operations (Phase 5.2a — peer-AI turn 77)

The storage module ships codepoint-iteration helpers that the
language-surface stdlib (`src/stdlib.zig`) calls. Frozen invariants
for the user-facing API:

**Indexing is by Unicode scalar (codepoint), not grapheme cluster
and not byte.** Picked over byte indexing in turn 77 §D1 because
`count` / `nth` / `subs` must agree, and surfacing UTF-8 byte
positions through a user-facing `(count s)` would surprise users
porting Clojure code where `(.length s)` is character-flavored. v1
makes no claim about graphemes (`🇺🇸` is multiple codepoints; that's
out of scope and documented).

**Native fns in `nexis.core`:**

```
(str & xs)        ; variadic, concat-stringify per Clojure; nil → "".
                  ; Display-mode formatting: strings unquoted.
(string? x)       ; true iff x.kind() == .string
(subs s start)        ; [start, codepoint-count) byte-slice → fresh string
(subs s start end)    ; [start, end)

(count s)         ; extends to strings: number of codepoints (O(n) walk).
(nth s i)         ; codepoint at index → Kind.char
(nth s i default) ; default on out-of-bounds (matches existing nth)
(empty? s)        ; (= 0 (count s))
```

**Errors** (catchable keywords):
- `:kind-mismatch` — non-string passed to `string?`/`subs` etc.;
  non-fixnum index to `subs`/`nth`.
- `:index-out-of-bounds` — negative start, end > count, start > end,
  index outside `[0, count)`.

**Algorithm**: `string.codepointCount(v)` walks the byte body once
using `std.unicode.utf8ByteSequenceLength`-style decoding;
`string.byteRangeForCodepoints(v, start, end)` converts a
codepoint range to a byte range in a second walk;
`string.codepointAt(v, i)` returns a `Kind.char` Value via a
front-to-position walk. None of these store side-cache state on
the HeapHeader — codepoint count IS NOT cached today (v1; if
profiling shows hot use, a Phase 6 cache slot or full
codepoint-counted subkind could land).

**Storage shape unchanged.** Byte layout (§2) is invariant: the body
is still raw UTF-8 bytes; codepoint indexing is purely a presentation
view. `subs` allocates a fresh heap string via `fromBytes` — no
zero-copy slicing in v1 (subkind 2 is reserved for emdb-page
mmap, not for slicing our own heap; turn 77 §D3 confirmed).

**v1 invalid-UTF-8 policy.** If a corrupted byte sequence makes
codepoint iteration fail mid-string, `string.codepointAt` /
`codepointCount` / `byteRangeForCodepoints` SHOULD return
`error.InvalidUtf8` (or equivalent). The caller (stdlib) maps that
to `:utf8-error` (catchable). Construction-time validation of
strings happens at the reader and the codec; runtime corruption
that reaches the storage layer is treated as a recoverable
language error rather than a panic, matching the Phase 1
"caller's responsibility" stance.

---

### 8. `nexis.string` namespace (Phase 5.2b — peer-AI turn 79)

Separate from `nexis.core`, NOT auto-referred (matches Clojure's
`clojure.string`). Users call qualified: `(nexis.string/lower-case
"HI") → "hi"`. The `nexis.string` namespace is registered with
`nexis.core` as parent so its own definitions can use core fns,
but bare `(lower-case ...)` from user code resolves to
`:unresolved-symbol` unless the user explicitly requires/aliases
the namespace.

**Installation order (frozen).** CLI + test harnesses install in
this exact sequence so namespace + Var visibility is consistent
at every load:

```
1. installCore(registry.core)        ; sequence/HOF/arithmetic/atoms/strings
2. installDb(registry.db)            ; emdb primitives
3. installString(registry.string)    ; nexis.string ops below
4. bootstrap embedded core.nx        ; composite definitions
```

`installString` is called BEFORE `core.nx` so future composite
definitions in `stdlib/core.nx` can refer to `nexis.string/*`
without a load-order trap, even if no current core.nx form does
so today.

**Native fns:**

```
(nexis.string/lower-case s)        ; ASCII-only; non-ASCII bytes preserved
(nexis.string/upper-case s)        ; ASCII-only; non-ASCII bytes preserved
(nexis.string/trim s)              ; six ASCII whitespace chars
(nexis.string/split s delim)       ; literal delimiter, preserves trailing empties
(nexis.string/join coll)           ; concatenate, no separator
(nexis.string/join sep coll)       ; concatenate with separator
(nexis.string/replace s match new) ; literal match, all non-overlapping
```

**Frozen invariants:**

1. **Case conversion is ASCII-only** (turn 77 §D10 + turn 79 §D1).
   `lower-case` maps bytes `A-Z (0x41..0x5A)` → `a-z (0x61..0x7A)`;
   `upper-case` does the inverse. Bytes ≥ 0x80 (every multi-byte
   UTF-8 continuation or leading byte) are preserved
   verbatim. UTF-8 validity preservation is by construction:
   no codepoint boundary crosses an ASCII byte we modify.
   Future Unicode case folding requires per-codepoint tables;
   tracked in §6's "Unicode operations" deferral.

2. **`trim` whitespace set** (turn 79 §D2): the six ASCII chars
   space (0x20), tab (0x09), LF (0x0A), VT (0x0B), FF (0x0C),
   CR (0x0D). Matches `std.ascii.isWhitespace`. Unicode
   whitespace (e.g., U+00A0, U+2028, U+2029) is NOT recognized.
   `trim` strips from both sides simultaneously (left + right);
   no separate `triml`/`trimr` shipped in 5.2b.

3. **`split` is a literal-string splitter** that preserves
   trailing empties (turn 79 §D3 override). Examples:
   ```
   (nexis.string/split "a,b,c" ",") → ["a" "b" "c"]
   (nexis.string/split "a,b,"  ",") → ["a" "b" ""]
   (nexis.string/split ",,"    ",") → ["" "" ""]
   (nexis.string/split ""      ",") → [""]
   (nexis.string/split "a"     "foo") → ["a"]
   ```
   `delim` must be a non-empty string. Empty delimiter
   surfaces `:invalid-argument` (peer-AI turn 80 §"Must-fix"
   #2: empty delim is the right KIND but an invalid VALUE for
   the operation, distinct from `:kind-mismatch` which is for
   wrong-kind args). Result is a vector, not a list.
   The "regex split" variant (Clojure's
   `clojure.string/split` 2-arg form trims trailing empties)
   is deferred to Item 6 alongside regex; our literal split
   is honest fields. Search is byte-wise (`std.mem.indexOf`).

   **UTF-8 validation**: `nexis.string/*` is a Unicode-string
   API, not a byte-blob API (peer-AI turn 80 §"Must-fix" #1).
   `split` validates both `s` and `delim` as UTF-8 before
   scanning; malformed input → `:utf8-error`. This guarantees
   that valid output strings would not be sliced
   mid-codepoint by a byte-only delimiter like a lone 0xC3
   (which is a valid UTF-8 leading byte but invalid as a
   complete string). Storage (STRING.md §2) remains byte-blob
   for codec compatibility; user-surface validation lives in
   `nexis.string/*`.

4. **`join` accepts nil + sequential + set** (turn 79 §D4):
   - `nil` → `""`
   - `list` / `vector` → walk in declaration order
   - `set` → walk in iteration order (implementation-defined
     for CHAMP; users requiring deterministic order should
     sort beforehand)
   - `map` → `:kind-mismatch` until map seq shape is pinned
   Each element stringifies via the same display formatter
   used by `(str ...)` (5.2a's `appendStringified`; 5.2c
   replaces with `src/format.zig`). The separator must be a
   `Kind.string`; non-string separator → `:kind-mismatch`.
   `join` does NOT auto-stringify the separator.

5. **`replace` is literal, all-non-overlapping, left-to-right**
   (turn 79 §D5). `match` must be a non-empty string; empty
   `match` → `:invalid-argument` (turn 80 §"Must-fix" #2:
   distinct from `:kind-mismatch`). `replacement` must be a
   `Kind.string`; non-string → `:kind-mismatch`. No special
   replacement syntax (`$1`, `\1`, etc.) in literal mode.
   After each match, scanning continues at
   `match_pos + match.len` (NOT at `match_pos + 1`), so
   `(replace "aaa" "aa" "x") → "xa"`, not `"xx"`. Consecutive
   non-overlapping matches both fire:
   `(replace "aaaa" "aa" "x") → "xx"`.

   **UTF-8 validation** (turn 80 §"Must-fix" #1): all three
   args (`s`, `match`, `replacement`) are validated as UTF-8
   before scanning; malformed input → `:utf8-error`. Same
   rationale as `split` — the user-surface API is a Unicode
   string operation, not a raw-byte one.

**v1 errors (catchable keywords):**

| Keyword              | Source                                       |
|----------------------|----------------------------------------------|
| `:kind-mismatch`     | non-string `s` / non-string sep / non-collection `coll` for join (wrong KIND of arg) |
| `:invalid-argument`  | empty delim for split, empty match for replace (right kind, wrong value; turn 80 §"Must-fix" #2) |
| `:utf8-error`        | malformed UTF-8 in any input to `split` / `replace` (turn 80 §"Must-fix" #1) |
| `:arity-mismatch`    | wrong argc on any fn                         |

**GC-rooting checklist additions (peer-AI turn 79 §D9):** all six
fns allocate output strings/vectors via `string.fromBytes` /
`vector.fromSlice` AFTER holding their argument Values in Zig
locals. Under v1's explicit-only GC this is structurally safe;
the future-migration audit must walk each one. Tracked in
`docs/GC.md` §11.5.
