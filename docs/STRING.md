## STRING.md — the string heap kind

The storage contract of `Kind.string` (16, VALUE.md §2.2): its
subkinds, invariants and Zig API (`src/string.zig`). The language
surface over strings (`str`, `subs`, `nexis.string`, printing, I/O)
is STDLIB.md.

---

### 1. Subkinds

| Subkind | Name | State |
|---|---|---|
| 0 | inline short string (up to 15 bytes in the Value itself) | reserved |
| 1 | heap string (`subkind_heap`): the body is the raw UTF-8 bytes, no length prefix | the only one built |
| 2 | zero-copy slice over an emdb page | reserved |

A second subkind would have to keep every invariant below, with
`=` and `hash` over the logical bytes whatever the storage.

---

### 2. Invariants

1. **Layout.** A string's body is exactly its bytes; the length is
   the body's length (`Heap.bodyBytes`). The empty string is legal.
2. **Byte equality.** Two strings are `=` iff their bytes are
   identical; there is no Unicode normalization. Equality and hash:
   SEMANTICS.md §3.3.
3. **Hash.** `hashHeader` is `hash.hashBytes` (xxHash3-64 with the
   fixed seed of `src/hash.zig`) over the body, truncated to 32
   bits; `dispatch.hashValue` mixes in the kind's domain byte.
4. **No validation at the storage boundary.** `fromBytes` stores the
   bytes it is given. The reader produces well-formed UTF-8; the
   codec round-trips a string byte-exact without validating it
   (CODEC.md §2.2). A string with malformed bytes is still equal only
   to a string with the same bytes and still hashes
   deterministically; the operations that read characters (`count`,
   `nth`, `get`, `subs`, the sequence functions, `nexis.string`) and
   readable printing throw `:utf8-error` on it, and display printing
   writes its bytes (STDLIB.md §2, §5).
5. **Not interned.** Two `fromBytes` calls with the same bytes make
   two headers: `=` and of equal hash, not `identical?`. Explicit
   interning of strings is absent.
6. **No metadata.** A string carries none; `with-meta` on one throws
   `:no-metadata-on-immediate` (SEMANTICS.md §7).
7. **Cached hash, nonzero only.** The hash is cached in the header
   (`HeapHeader.setCachedHash`) when it is not 0; a string whose hash
   is 0 recomputes it on each use.

Strings are immutable; there is no mutable string builder, and
`subs` copies (no slice of a heap string shares its body).

---

### 3. Zig API (`src/string.zig`)

| Function | Contract |
|---|---|
| `fromBytes(heap, bytes) !Value` | A fresh `.string` block (`heap.alloc(.string, len)`) holding a copy of `bytes` |
| `asBytes(v) []const u8` | The byte view; asserts the kind, and subkind 1 in safe builds. Callers must not assume the bytes live on the heap |
| `byteLen(v) usize` | The byte length |
| `hashHeader(h) u32` | Invariants 3 and 7; called by `dispatch.heapHashBase` |
| `bytesEqual(a, b) bool` | Byte comparison of two string headers; called by `dispatch.equal` |
| `trace(h, visitor)` | No-op: a string holds no references (GC.md §5) |
| `codepointCount(v) error{InvalidUtf8}!usize` | Unicode scalars in the body (`std.unicode.utf8CountCodepoints`) |
| `codepointAt(v, i) error{OutOfBounds, InvalidUtf8}!u21` | The scalar at code-point index `i` |
| `byteRangeForCodepoints(v, start, end)` | The byte range of code points `[start, end)`; `error.OutOfBounds` when `start > end` or `end` is past the count, `error.InvalidUtf8` on malformed bytes before `end` |

The code-point helpers are what the language's indexing is built on:
a string indexes by Unicode scalar, not by byte and not by grapheme
cluster. `codepointAt` and `byteRangeForCodepoints` find the ASCII
run at the start of the body sixteen bytes at a time and index inside
it directly, decoding only the bytes past it, so on an ASCII string
`nth` and `subs` cost a vector scan to the index. The code-point
count is not cached; `count` of a string is an O(n) scan. The stdlib
maps `error.InvalidUtf8` to `:utf8-error`.

`test/prop/string.zig` checks the kind: S1–S3 equality and hash
(reflexive, symmetric, transitive; equal implies equal hash; never
equal to another kind), S4 the `fromBytes` / `asBytes` round trip,
S5 the hash function, S6 the hash cache, S7 the code-point helpers
against a plain decode, malformed bytes included.

---

### 5. Interactions

- **Heap.** `heap.alloc(.string, len)` is the only way a string
  header is made; strings use none of the header flags.
- **Dispatch.** `dispatch.hashValue` and `dispatch.equal` reach
  `hashHeader` and `bytesEqual` for `.string` (SEMANTICS.md §3.3).
- **Compiler.** `src/compile.zig` makes each string literal of a
  routine's constants with `fromBytes`.
- **Codec.** A string is length-prefixed raw bytes on the wire;
  decode calls `fromBytes` (CODEC.md §2.2).
- **Printer.** `src/format.zig` prints a string raw or quoted and
  escaped (STDLIB.md §5).

---

### 6. Absent

- Subkinds 0 and 2 (§1).
- Unicode case mapping, normalization, grapheme segmentation and
  collation: the runtime carries no Unicode tables; `nexis.string`'s
  case functions are ASCII-only (STDLIB.md §3).
- String interning and a mutable string builder.

---

### 7. Language-level operations

STDLIB.md §2, over the code-point helpers of §3.

### 8. `nexis.string` namespace

STDLIB.md §3.

### 9. Printing and I/O

STDLIB.md §5 (`src/format.zig`) and §6.
