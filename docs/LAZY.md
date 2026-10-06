## LAZY.md — Lazy Sequences

The contract for the `lazy_seq` heap kind (`src/coll/lazy.zig`) and
for realizing it. PLAN §23 #14 makes sequences lazy as Clojure 1.12's
are. Kind number and tag layout: `docs/VALUE.md` §2.2. Header bits:
`docs/HEAP.md` §4. Equality category and hash domain:
`docs/SEMANTICS.md` §2.6 and §3.3. Serialization: `docs/CODEC.md` §3.

---

### 1. Scope

A lazy seq is a sequence whose elements are computed when something
walks it, once, and cached. It is sequential: `=` to, and hashed as,
the list of its elements, and printed as one. The kind has three user
shapes and one internal block:

- a **lazy block**, Clojure's `LazySeq`: a body that has not run, or
  the seq it ran to;
- a **cons** cell whose rest may be a lazy seq, Clojure's `Cons`;
- a **chunked cons** over a chunk of up to 32 elements, Clojure's
  `ChunkedCons`;
- the **chunk** a chunked cons reads, never a user value.

`list` stays fully realized: a cons cell of kind `list` always has a
`list` tail (`docs/LIST.md` §2), so every walker of a list runs no
code. A cell in front of something that may be lazy is a `lazy_seq`
cons.

---

### 2. Representation

The shape is the Value's subkind (tag bits 16..31) and, for the
collector, which sees a header and not a Value, the header's flags
bits 1–2; bit 0 stays `has_meta`.

| Shape | Name | Body | Meaning |
|---|---|---|---|
| 0 | lazy | `{ result: Value, op: u16, state: u8, argc: u8, _: u32, _: u64, args: [argc]Value }`, 32 + 16·argc B | `op` 0 is a `lazy-seq` body (`args[0]`, any callable, called with no arguments); every other op is a producer (`src/seq.zig`) whose state is `args`. `state` is 0 unrealized, 1 forwarding (`result` is the lazy block the body returned, §4), 2 realized (`result` is nil or a non-empty seq) |
| 1 | cons | `{ first: Value, more: Value }`, 32 B | `more` is nil, a list (any subkind) or a lazy seq that is not a chunk |
| 2 | chunked cons | `{ chunk: Value, more: Value }`, 32 B; the offset into the chunk in tag bits 32..63 | the chunk's elements from the offset on, then `more`. Its `rest` inside the chunk is the same block at the next offset and allocates nothing |
| 3 | chunk | `{ count: u32, cap: u32, _: u64, items: [cap]Value }` | held by chunked cons cells; never a user Value. A fresh chunk is zero-filled, so unwritten slots are nil |

**The normal form of a realized result** is nil (the empty seq) or a
non-empty seq: a non-empty list, a cons or a chunked cons. Never an
empty list and never another lazy block, as Clojure caches
`RT.seq(unwrap(sv))`.

**Walking a realized chain** (`lazy.Cursor`) runs no code: it yields a
cons's first element, a chunk's elements from the offset on (stepped
inline in the caller's loop), follows a realized or forwarding block
to its result, walks a list through `list.Cursor` once it reaches one,
and stops with `error.Unrealized` at a block whose body has not run,
leaving that block for the walker to realize (§4) before it steps
again.

---

### 3. Tracing

`lazy.trace` walks a chain in a loop, as `list.trace` walks cons
cells. At each block it marks what the block holds as values (a lazy
block's producer arguments, a cons's first element, a chunked cons's
chunk) and marks the next block of the chain (a lazy block's `result`,
a cons's or chunked cons's `more`) itself, through `markInternal`, so
a chain of a million cells costs no worklist and no recursion
(`src/gc.zig` "a chain of realized lazy cells"). The walk stops at
nil, at a list (marked as a value; its own trace walks its cells) or
at a block already marked. A chunk marks every slot of its capacity:
a producer filling one in place may be interrupted by a collection,
and the unwritten slots are nil. A realized or forwarding block holds
no producer arguments: realizing clears them, so a source the
producer held is garbage once nothing else holds it.
