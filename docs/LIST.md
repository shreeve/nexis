## LIST.md — Immutable List Heap Kind

The contract for the `list` heap kind (`src/coll/list.zig`): singly
linked immutable cons cells, and views of a vector from an offset.
Kind number and tag layout: `docs/VALUE.md` §2.2. Header bits:
`docs/HEAP.md`. Equality category and hash domain: `docs/SEMANTICS.md`
§3.3. Serializable: `docs/CODEC.md` §3.

---

### 1. Scope

The list kind has three subkinds; the body size alone tells them
apart (0, 16, 32 bytes), which is what the collector sees.

| Subkind | Name | Body | Meaning |
|---|---|---|---|
| 0 | cons | `{ head: Value, tail: Value }`, 32 B | `tail` is always a `.list` Value |
| 1 | empty | 0 B | the empty list |
| 2 | vector view | one vector Value, 16 B; with metadata, one view Value, 16 B | the vector's elements from an offset on |

**Vector view.** The offset is a `u32` (as a vector's count is) held in
the Value's tag bits 32..63, never in the block, and is at most the
vector's count; the view is empty when the offset equals the count.
`seq`, `rest`, `next`, `nthrest`, `nthnext` and `drop` of a vector
allocate one view block, O(1) whatever the length. `tail` and `drop` of
a view return the same block at a later offset and allocate nothing,
which is why the offset lives in the Value. `head` is the vector's
`nth` (O(log₃₂ n)); `count` is the vector's count minus the offset;
`nth` of a list walks with `drop`, so it is O(log₃₂ n) once it reaches
a view; the cursor walks the vector's leaves directly
(`vector.Cursor.initAt`).

A view is a list to every consumer: it is `seq?` and `list?`, prints as
`(...)`, is `=` to and hashes as the list of the same elements, can be
the tail of a cons (`(cons 0 (rest v))`), and the codec encodes it as a
list (decoding gives cons cells).

**No empty singleton.** Every `empty(heap)` allocates a fresh block.
Two empty lists are `=`; `identical?` tells them apart by address.
`()` is not `=` to nil, and is `=` to `[]` (both sequential).

**Count.** Not cached: O(1) for a view, O(n) over cons cells. Lists are
reader and macro material; large sequences are vectors.

---

### 2. Invariants

1. **Proper lists only.** `cons` returns `error.InvalidListTail` when
   the tail is not a `.list` Value, so a cons chain always ends in an
   empty list or a view. The language `cons` takes any seqable tail and
   converts it with `seq` first: `(cons 0 [1 2])` is the list `(0 1 2)`.
2. **Hash.** `hashSeq` is the ordered combine of the element hashes
   (`hash.combineOrdered` from `ordered_init`, then
   `finalizeOrdered(acc, count)`), truncated to `u32`; `vector.hashSeq`
   computes the same value for the same elements. The caller mixes in
   the sequential domain byte. A cons cell caches a nonzero result in
   its header (SEMANTICS §3.1); a view caches nothing, because every
   offset of it shares one header. A view used over and over as a map
   key (memoizing on `(rest args)`) is rehashed in O(n) at each lookup;
   `vec` of it gives a key that caches its hash.
3. **Equality.** `equalSeq` walks both lists in lock step through their
   cursors: same length and every pair `=`.
4. **Metadata** (SEMANTICS §7). Lists carry metadata in the header's
   `meta` slot, and `conj` keeps the list's in the new cell; `cons`
   adds none. A view block that `seq`, `rest` or `drop` returns never
   carries metadata, so `(meta (seq v))` is nil whatever `v`'s.
   `with-meta` of a view (`viewWithMeta`) is O(1): one new view block
   carrying the metadata, whose body is the metadata-free view block
   it wraps instead of the vector. `tail` and `drop` of it step onto
   the wrapped block, so its rests carry no metadata, as in Clojure;
   every other reader reaches the vector through the wrapped block.
5. **Depth.** `hashSeq`, `equalSeq`, `count`, `drop` and `trace` walk
   the top-level chain iteratively, so a long flat list costs constant
   stack. Elements recurse through `dispatch.hashValue` and
   `dispatch.equal`, which check the stack guard at each structural
   step: a value nested too deep becomes the catchable
   `:stack-overflow` (SEMANTICS §2.7). `=` and `hash` cannot loop, since
   atoms, the only mutable cells, compare and hash by identity.

---

### 3. Public API (`src/coll/list.zig`)

| Function | Contract |
|---|---|
| `empty(heap) !Value` | fresh empty list (subkind 1) |
| `cons(heap, head, tail) !Value` | one cons cell; `error.InvalidListTail` for a non-list tail |
| `conj(heap, l, x) !Value` | `cons` whose cell carries `l`'s metadata |
| `fromSlice(heap, elems) !Value` | `(a b c)` from `&.{a, b, c}`, right-folded `cons` |
| `ofVector(heap, vec, start) !Value` | one view block; `start` ≤ the vector's count |
| `viewWithMeta(heap, view, meta) !Value` | the view carrying `meta` (§2 invariant 4); null gives the metadata-free view |
| `isEmpty(v) bool` | the empty list, or a view at its vector's end |
| `head(v) Value` | first element; panics in safe builds on an empty list |
| `tail(v) Value` | the rest, always a list; never allocates; panics on empty |
| `count(v) usize` | O(1) for a view, O(n) over cons cells |
| `drop(v, n) Value` | without the first `n` elements, empty when shorter; never allocates |
| `Cursor.init(v)`, `next() ?Value` | streaming iteration in order |
| `hashSeq(v, elementHash) u64` | §2 invariant 2; `elementHash` is `&dispatch.hashValue` |
| `equalSeq(a, b, elementEq) bool` | §2 invariant 3; `elementEq` is `&dispatch.equal` |
| `trace(h, visitor)` | GC trace, §6 |

The callbacks keep `list.zig` out of `dispatch`'s import graph; it
imports `vector.zig` for the view. Errors besides `InvalidListTail` are
`heap.alloc`'s. `head` and `tail` of an empty list are caller bugs; the
nil-returning `first`, `rest` and `next` are stdlib natives on top.

---

### 6. Interaction with other layers

- **GC** (`docs/GC.md` §5). `trace` marks every head and marks each
  following cons cell directly, in a loop, so the collector's recursion
  follows nesting, never length. It stops at the empty list, at an
  already-marked cell, or at a view, which marks its body: the whole
  vector (the block does not know the offset), or for a view carrying
  metadata the view block it wraps.
- **Compiler and VM.** Quoted lists reach runtime through the
  `coll:list` opcode, which builds them with `cons` (`docs/VM.md`
  §10.8).
- **Printer.** `src/format.zig` prints every subkind as `(...)`.
- **Absent.** Lazy sequences (PLAN §23 #14): `seq` of a vector is the view
  of §1, of every other collection a fresh list. Destructive list
  operations. Transients of lists.
