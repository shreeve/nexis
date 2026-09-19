## STRING.md — UTF-8 String Heap Kind

Authoritative body-layout and API contract for
the `string` heap kind. Derivative from `PLAN.md` §8.2, `docs/VALUE.md` §2.2,
`docs/SEMANTICS.md` §2.4 / §3.2, and `docs/HEAP.md`. Those documents win on
conflict.

This is the first real heap kind to land, so it also locks in the cross-kind
dispatch pattern every subsequent heap kind (bignum, list, persistent-map, …)
will follow. That pattern lives in `src/dispatch.zig`, which is introduced
alongside this module.

---

### 1. Scope

The string kind has **one** subkind in use:

- **Subkind 1 — heap string.** Body is the raw UTF-8 bytes, no length
  prefix. Length is recovered from `Heap.bodyBytes(h).len`.

Reserved (no implementation):

- **Subkind 0 — inline short string (SSO).** Up to 15 bytes of content
  live inside the `Value` tag + payload itself, no heap allocation.
  Performance optimization (PLAN §19.6 Tier 2). The subkind numbering
  is kept so SSO slots into subkind 0 without renumbering.
- **Subkind 2 — zero-copy slice over mmap page.** The PLAN §19.6 T2.2
  "direct-from-emdb" path.

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
   (NFC/NFD) — strings are deliberately byte blobs.
3. **Hash** (SEMANTICS §3.2). `hashHeader(h)` returns
   `xxHash3(seed, bytes)` truncated to `u32`, where `seed` is the
   project-wide constant in `src/hash.zig`. The final `Value.hashValue`
   for a string extends to `u64`, mixes the `Kind` byte via
   `mixKindDomain`, and returns the result.
4. **UTF-8 validation is NOT performed at the storage boundary.**
   `fromBytes` trusts its caller — the reader already produces
   well-formed UTF-8. Untrusted-bytes decoders (the codec) are
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

Rationale: keeping `value.zig` and `eq.zig` low-level — they describe
semantics for immediates and cross-kind rules — while cross-kind
integration lives in one module where "have we accounted for every
heap kind?" is a single-file audit.

`dispatch.zig` depends on every heap-kind module; no heap-kind module
depends on `dispatch.zig`. A new kind adds exactly one `switch`
arm to each dispatch function.

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
  (nonzero only). `HeapHeader.flags` bits are unused for strings:
  `flag_interned` is reserved and `flag_zero_copy` belongs to the
  reserved subkind 2.
- **Hash layer.** `string.hashHeader` calls `hash.hashBytes(bytes)`
  and truncates. No new hash primitives needed.
- **Intern layer.** No direct interaction — strings are not interned.
- **Reader / compiler.** `src/reader.zig` emits string Forms as byte
  slices; `src/compile.zig` calls `string.fromBytes` with the
  already-validated UTF-8 from the grammar's `STRING` token when it
  lifts a string literal into a routine's constant pool.

---

### 6. What STRING.md does not cover

- **Inline short-string optimization (SSO).** Subkind 0, reserved with
  no implementation. It would preserve every invariant in §2 except
  the "body is heap body" physical layout — SSO strings would have no
  heap allocation, with `asBytes`/`hashHeader`/`bytesEqual` working
  transparently.
- **Zero-copy subkind 2.** Reserved with no implementation; needs
  mmap / emdb-page plumbing. Same transparency contract as SSO.
- **Unicode operations** (grapheme iteration, case folding, normalization,
  collation). Case conversion + trim in `nexis.string` are
  **ASCII-only** (§8). Full Unicode case folding,
  grapheme clustering, normalization, and collation are absent; they
  need a Unicode tables module the runtime does not carry.
- **String interning** (explicit `(intern s)`). Absent (PLAN §8.4).
- **Print-time escape encoding** (`\n`, `\t`, `\u{HEX}`). That's
  handled by `src/reader.zig`'s pretty-printer for Forms and by
  `src/format.zig` for runtime Values.
- **Mutability / transient strings.** Strings are persistent (immutable)
  at the Value layer. There is no mutable string builder.

---

### 7. Language-level operations

The storage module ships codepoint-iteration helpers that the
language-surface stdlib (`src/stdlib.zig`) calls. Frozen invariants
for the user-facing API:

**Indexing is by Unicode scalar (codepoint), not grapheme cluster
and not byte.** Picked over byte indexing because
`count` / `nth` / `subs` must agree, and surfacing UTF-8 byte
positions through a user-facing `(count s)` would surprise users
porting Clojure code where `(.length s)` is character-flavored. The
runtime makes no claim about graphemes (`🇺🇸` is multiple codepoints; that's
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
the HeapHeader — the codepoint count is not cached (a cache slot
or a codepoint-counted subkind is the lever if profiling shows hot
use).

**Storage shape unchanged.** Byte layout (§2) is invariant: the body
is still raw UTF-8 bytes; codepoint indexing is purely a presentation
view. `subs` allocates a fresh heap string via `fromBytes` — no
zero-copy slicing (subkind 2 is reserved for emdb-page mmap, not
for slicing our own heap).

**Invalid-UTF-8 policy.** If a corrupted byte sequence makes
codepoint iteration fail mid-string, `string.codepointAt` /
`codepointCount` / `byteRangeForCodepoints` SHOULD return
`error.InvalidUtf8` (or equivalent). The caller (stdlib) maps that
to `:utf8-error` (catchable). Construction-time validation of
strings happens at the reader and the codec; runtime corruption
that reaches the storage layer is treated as a recoverable
language error rather than a panic, matching the storage layer's
"caller's responsibility" stance.

---

### 8. `nexis.string` namespace

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

1. **Case conversion is ASCII-only**.
   `lower-case` maps bytes `A-Z (0x41..0x5A)` → `a-z (0x61..0x7A)`;
   `upper-case` does the inverse. Bytes ≥ 0x80 (every multi-byte
   UTF-8 continuation or leading byte) are preserved
   verbatim. UTF-8 validity preservation is by construction:
   no codepoint boundary crosses an ASCII byte we modify.
   Future Unicode case folding requires per-codepoint tables;
   tracked in §6's "Unicode operations" deferral.

2. **`trim` whitespace set**: the six ASCII chars
   space (0x20), tab (0x09), LF (0x0A), VT (0x0B), FF (0x0C),
   CR (0x0D). Matches `std.ascii.isWhitespace`. Unicode
   whitespace (e.g., U+00A0, U+2028, U+2029) is NOT recognized.
   `trim` strips from both sides simultaneously (left + right);
   there is no separate `triml`/`trimr`.

3. **`split` is a literal-string splitter** that preserves
   trailing empties. Examples:
   ```
   (nexis.string/split "a,b,c" ",") → ["a" "b" "c"]
   (nexis.string/split "a,b,"  ",") → ["a" "b" ""]
   (nexis.string/split ",,"    ",") → ["" "" ""]
   (nexis.string/split ""      ",") → [""]
   (nexis.string/split "a"     "foo") → ["a"]
   ```
   `delim` must be a non-empty string. Empty delimiter
   surfaces `:invalid-argument` (empty delim is the right KIND but
   an invalid VALUE for
   the operation, distinct from `:kind-mismatch` which is for
   wrong-kind args). Result is a vector, not a list.
   The "regex split" variant (Clojure's
   `clojure.string/split` 2-arg form trims trailing empties)
   does not exist (no regex); our literal split is honest fields. Search is byte-wise (`std.mem.indexOf`).

   **UTF-8 validation**: `nexis.string/*` is a Unicode-string
   API, not a byte-blob API.
   `split` validates both `s` and `delim` as UTF-8 before
   scanning; malformed input → `:utf8-error`. This guarantees
   that valid output strings would not be sliced
   mid-codepoint by a byte-only delimiter like a lone 0xC3
   (which is a valid UTF-8 leading byte but invalid as a
   complete string). Storage (STRING.md §2) remains byte-blob
   for codec compatibility; user-surface validation lives in
   `nexis.string/*`.

4. **`join` accepts nil + sequential + set**:
   - `nil` → `""`
   - `list` / `vector` → walk in declaration order
   - `set` → walk in iteration order (implementation-defined
     for CHAMP; users requiring deterministic order should
     sort beforehand)
   - `map` → `:kind-mismatch`
   Each element stringifies via the same display formatter
   used by `(str ...)` (`src/format.zig`). The separator must be a
   `Kind.string`; non-string separator → `:kind-mismatch`.
   `join` does NOT auto-stringify the separator.

5. **`replace` is literal, all-non-overlapping, left-to-right**
   `match` must be a non-empty string; empty `match` →
   `:invalid-argument` (distinct from `:kind-mismatch`). `replacement` must be a
   `Kind.string`; non-string → `:kind-mismatch`. No special
   replacement syntax (`$1`, `\1`, etc.) in literal mode.
   After each match, scanning continues at
   `match_pos + match.len` (NOT at `match_pos + 1`), so
   `(replace "aaa" "aa" "x") → "xa"`, not `"xx"`. Consecutive
   non-overlapping matches both fire:
   `(replace "aaaa" "aa" "x") → "xx"`.

   **UTF-8 validation**: all three
   args (`s`, `match`, `replacement`) are validated as UTF-8
   before scanning; malformed input → `:utf8-error`. Same
   rationale as `split` — the user-surface API is a Unicode
   string operation, not a raw-byte one.

**Errors (catchable keywords):**

| Keyword              | Source                                       |
|----------------------|----------------------------------------------|
| `:kind-mismatch`     | non-string `s` / non-string sep / non-collection `coll` for join (wrong KIND of arg) |
| `:invalid-argument`  | empty delim for split, empty match for replace (right kind, wrong value) |
| `:utf8-error`        | malformed UTF-8 in any input to `split` / `replace` |
| `:arity-mismatch`    | wrong argc on any fn                         |

---

### 9. Printing + I/O

**Module split.** Value→text formatting lives in `src/format.zig`,
not in `src/stdlib.zig` or `src/cli.zig`. format.zig is the single
source of truth for both display + readable modes; cli.zig and
the integration-test harness delegate to it.

**`src/format.zig` API:**

```zig
pub const FormatMode = enum { display, readable };
pub const Error = std.Io.Writer.Error || error{Utf8Error};

pub fn format(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void;

pub fn formatToString(
    allocator: std.mem.Allocator,
    heap: *heap_mod.Heap,
    v: Value,
    mode: FormatMode,
    interner: ?*const intern_mod.Interner,
) !Value;
```

**Two modes (frozen):**

| Aspect | `.display` | `.readable` |
|---|---|---|
| `nil` | `"nil"` | `"nil"` |
| string | unquoted raw bytes | `"…"` with `\ " \n \t \r` + `\u{HEX}` for other 0x00..0x1F + DEL |
| char | UTF-8 encoded scalar | named tokens (`\space`, `\newline`, `\tab`, `\return`, `\formfeed`, `\backspace`, `\\`), printable ASCII as `\x`, NUL + non-printable as `\u{HEX}` |
| atom / function / native-fn / var / durable-ref / transient / connection / tx | OPAQUE (`#<atom>`, `#<fn>`, `#<native-fn NAME>`, `#'name`, `#<durable-ref :tree/key>`, ...) | OPAQUE (same; intentionally NOT reader-round-trippable — these are identity-valued/process-local kinds) |
| collections | recursive in same mode | recursive in same mode |
| malformed UTF-8 in string | passes through bytes unchanged | `:utf8-error` (readable mode must not emit invalid source) |

**`format` is purely presentation, not serialization.** The codec
(`src/codec.zig`) owns wire-format bytes; `format` owns text-out.
They don't share an encoding. `#<atom>` / `#<fn>` / durable-ref
text are NOT reader-round-trippable.

**Nil semantics split** (load-bearing):

| Call | Result |
|---|---|
| `format(.display, nil)` / `(print nil)` / `(println nil)` / `(prn nil)` / `(pr-str nil)` | `"nil"` |
| `(str nil)` / `(spit path nil)` / `(nexis.string/join [1 nil 2])` | `""` (nil → empty) |

`str` / `join` / `spit` each layer a thin wrapper
(`stdlib.appendStrValue`) that special-cases nil → empty BEFORE
delegating to `format.format(.display, ...)`. The formatter
itself never special-cases nil.

**Native fns in `nexis.core`:**

```
(print & xs)     ; stdout, no newline, display mode, args joined by " "
(println & xs)   ; stdout + "\n", display mode, args joined by " "
(prn & xs)       ; stdout + "\n", readable mode, args joined by " "
(pr-str & xs)    ; returns a String, readable mode, args joined by " "
(slurp path)     ; read UTF-8 file → String. 16 MiB cap.
(spit path content) ; write (str content) to file; NO parent-dir auto-create.
```

**Errors:**

| Keyword              | Source                                                       |
|----------------------|--------------------------------------------------------------|
| `:io-error`          | `vm.io == null` (test harnesses); writeFailed; non-FileNotFound emdb errors |
| `:file-not-found`    | slurp on missing path                                        |
| `:invalid-path`      | empty path string; path containing NUL byte                  |
| `:kind-mismatch`     | non-string path arg                                          |
| `:utf8-error`        | slurp file content not valid UTF-8                           |

**Frozen invariants:**

§9.1. `vm.io` is the authority for filesystem + stdout. Null
`vm.io` → `:io-error` on print/println/prn/slurp/spit. Tests run
with null io and exercise the error path; the CLI sets
`vm.io = init.io` on bootstrap so real programs work.

§9.2. `spit` does NOT auto-create parent directories. Missing parents → `:file-not-found` / `:io-error`. The
`db/open` parent-dir auto-create is a DB-
specific convenience; file I/O is not auto-creating.

§9.3. `slurp` size cap is **16 MiB**. Larger
files surface `:io-error`. There is no size-limit argument.

§9.4. `pr-str` does NOT print a trailing newline; `println` and
`prn` DO. `print` does not.

§9.5. Print args separate with a single space (Clojure parity).
Empty argc is legal: `(println) → "\n"`, returns `nil`.

**GC rooting (`docs/GC.md` §11.5):** all six fns allocate output
strings/vectors via `string.fromBytes` / `vector.fromSlice` while
holding only their argument Values, which are rooted for the call,
and none calls back into the VM; `Heap.alloc` never collects, so
nothing here needs a root.
