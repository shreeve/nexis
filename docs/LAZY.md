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

---

### 4. Realization

`seq.force(vm, lz)` (`src/seq.zig`) is the one way a lazy block's body
runs. It runs in native context (§6): a native or an opcode with a VM
in hand, where running code may collect and errors are ordinary
`VmError`s.

1. A realized block answers its cached `result`.
2. The stack guard is checked: forcing one producer forces the one
   below it, so a seq built by a deep nesting of functions realizes
   with native recursion as deep, and past the guard it raises the
   catchable `:stack-overflow` (`docs/VM.md` §13.1).
3. The block's step runs: op 0 calls the `lazy-seq` body's function
   with no arguments; any other op runs its producer (§7).
4. **Forwarding.** While the step returns another lazy block whose
   body has not run, the current block forwards to it (state 1,
   `result` the block it forwards to, its own arguments cleared) and
   that block's step runs next, in the same loop. This is Clojure's
   `unwrap` loop: a `lazy-seq` returning a `lazy-seq`, or a producer
   skipping a long run of elements, costs no native stack. A block that
   returns its own block, or one before it in the chain, has the empty
   seq, as `LazySeq.sval` finds it (`(def u (lazy-seq u))` is `()`).
5. The raw result is brought to normal form (§2): `seq` of it.
6. Every block of the forwarding chain gets that seq as its `result`
   and becomes realized, its arguments cleared.

**Exactly once.** A step that returns is never run again. A step that
throws leaves its block unrealized, and the next walk runs it again
from the start, as `LazySeq.force` re-invokes its `fn`
(`LazySeq.java` 1.12.0; babashka differs, caching an empty seq).
Blocks earlier in a forwarding chain keep their completed steps.

**Re-entrance.** A body that forces its own block before it returns
(`(def t (lazy-seq (seq t)))`) runs again inside itself until the stack
guard raises `:stack-overflow` (Clojure: `StackOverflowError`). A body
that only refers to its block works, because `cons` and the producers
do not force their argument: `(def s (lazy-seq (cons 1 s)))` is
`(1 1 1 ...)`.

**The primitives** (`src/seq.zig`):

| | Of a lazy block | Of a cons | Of a chunked cons at `o` |
|---|---|---|---|
| `seq` | its forced seq | itself | itself |
| `first` | `first` of its seq, nil if empty | `first` | `items[o]` |
| `rest` | `rest` of its seq, `()` if empty | `more`, or `()` if nil | the same block at `o + 1` while inside the chunk, else `more` or `()` |
| `next` | `seq` of its `rest` | `seq` of `more` | likewise |

`rest` does not force what follows and `next` does, as in Clojure.
`count`, `nth` and `empty?` walk, realizing as far as they read; `nth`
is a leaf native whose leaf body refuses a lazy seq, so the VM
re-issues the call through the full body (`docs/VM.md` §6). `(empty s)`
is `()`; `conj` onto a lazy seq is `(cons x (seq s))`, realizing one
step, as `LazySeq.cons`; `peek`, `pop` and `contains?` are
`:kind-mismatch`, as for a list; `get` is nil. `seq?`, `sequential?`,
`coll?` and `seqable?` are true of a lazy seq; `list?`, `counted?`,
`vector?` and `indexed?` false; `class` is `:lazy_seq`, the type
`extend-type` names.

`cons` puts a list cell in front of nil, a list, or the view of a
vector (`(cons 0 [1 2])` is still a list), and a lazy seq's cons cell in
front of a lazy seq, which it does not realize. `list*` conses its
leading arguments onto the seq of its last.

**`realized?`** is true of a lazy block whose body has run, and of a
cons or a chunked cons (Clojure's throws for `Cons`: answering is the
harmless extension); of a delay, whether it has been forced; anything
else is `:kind-mismatch`.

**`doall` and `dorun`** walk the spine (`seq.realizeSpine`), returning
the argument and nil; with a count, `(dorun n coll)` calls `next` `n`
times, as Clojure's does, which realizes one step past the `n`th
element.

**Metadata.** `with-meta` of a lazy seq returns a new realized block
carrying the map, whose result is the argument's seq, realizing one
step (`LazySeq.withMeta` is `new LazySeq(meta, seq())`). The metadata
lives on the wrapper and `seq` of it is the wrapped cell, so no `rest`
carries it. `meta` reads the header.

---

### 5. Walking

`seq.SeqIter` walks any seqable. Over a lazy seq it steps a
`lazy.Cursor` (§2): a chunk's elements inline in the caller's loop, a
cons cell or a list through the cursor, and at a block whose body has
not run it forces the block (§4) and steps on into its cached seq.
`reduce`, `into`, `vec`, `count`, `apply`, `str`, `doall` and every
other native that walks a seqable walk a lazy seq a chunk at a time
this way.

The iterator holds only positions inside the chain its argument heads,
which the forced blocks cache, so it roots nothing of its own; what the
native holds across the walk follows `docs/GC.md` §11.5, class 5.

**`=` of two arguments** one of which is a lazy seq walks both in step
in native context, so a body's throw propagates as from any native
and a lazy seq against a shorter one is decided at the shorter one's
end, as `LazySeq.equiv` walks.

**`seq.realizeAll`** realizes every lazy seq inside a value at any
depth, walking its seqs, vectors, maps, sets and records with an
explicit stack: what the code that runs no code needs before it
walks a value.
