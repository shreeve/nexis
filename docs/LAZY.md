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
the list of its elements, and printed as one. The kind has three
shapes:

- a **lazy block**, Clojure's `LazySeq`: a body that has not run, or
  the seq it ran to;
- a **cons** cell whose rest may be a lazy seq, Clojure's `Cons`;
- a **chunked cons**, a chunk of up to 32 elements in front of a rest,
  Clojure's `ChunkedCons` and its `ArrayChunk` in one block.

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
| 1 | cons | `{ first: Value, more: Value }`, 32 B | `more` is nil, a list (any subkind) or a lazy seq |
| 2 | chunked cons | `{ more: Value, count: u32, cap: u32, _: u64, items: [cap]Value }`, 32 + 16·cap B; the offset of its first element in tag bits 32..63 | the chunk's elements from the offset on, then `more`. Its `rest` inside the chunk is the same block at the next offset and allocates nothing. A fresh one is zero-filled, so unwritten slots are nil; a producer fills it in place and closes it with its count and `more` |

Shape 3 is unused. The chunk lives in the chunked cons's own block, as
a vector's elements live in its leaf: a chunk costs one block and 48
bytes of header and fields beside its elements.

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
elements, immediates skipped inline as a vector leaf's trace skips
them) and marks the next block of the chain (a lazy block's `result`,
a cons's or chunked cons's `more`) itself, through `markInternal`, so
a chain of a million cells costs no worklist and no recursion
(`src/gc.zig` "a chain of realized lazy cells"). The walk stops at
nil, at a list (marked as a value; its own trace walks its cells) or
at a block already marked. A chunked cons marks every slot of its
capacity: a producer filling one in place may be interrupted by a
collection, and the unwritten slots are nil. A realized or forwarding block holds
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
this way. `reduce` takes each chunk as a slice
(`SeqIter.nextChunk`), its inner loop calling the function over the
slice.

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

---

### 6. Where realization happens

**Native context.** A native, an opcode, the expander or a host that
holds a VM realizes through `seq.force` and the walks built on it
(§4, §5). Running a body may collect: every such call is a call back
into the VM for `docs/GC.md` §11.5, class 5. Errors are ordinary
`VmError`s, `ControlTransferred` included.

**Isolated context.** `=` and `hash` (`src/dispatch.zig`) have neither
a VM nor an error path, and their callers (CHAMP, the sorted tree,
transients, a map or set literal, the Nextomic relation code) hold
unrooted nodes. A lazy block they meet is realized through
`lazy.realizeIsolated`:

- `lazy.host`, per thread, names the innermost running VM. `VM.run`
  and `VM.runRoutine` install themselves and restore the previous host
  on return, so a macro's sub-VM realizes on itself, sharing its
  owner's heap; `VM.realizeOutside` installs the VM for a host that
  realizes a value outside any run.
- The VM raises `gc_hold`, under which no cycle is due, so the
  callers' unrooted nodes are safe, and calls the closure
  `nexis.core/realize-caught`, `(fn [s] (try [true (#%force s)] (catch
  any e [false e])))`. A throw is caught inside it, so nothing unwinds
  past the native that was comparing.
- A failure (a caught value, or an error the barrier cannot catch) is
  parked on the VM (`parked_realize`, a root while it is parked; the
  first wins, and later isolated realizations fail at once) and counts
  a spoil (`dispatch.noteSpoiled`): `=` answers false, `hash` 0, and
  no hash is cached, as for a value nested past the stack guard
  (`docs/SEMANTICS.md` §2.7).
- Every native call and opcode that compares or hashes already
  snapshots the spoil count (`VM.callDirect`, the native path of
  `call:call`, the `coll` opcodes, the transient natives). When the
  count moved, it raises the parked failure, a thrown value through
  `throwValue` or an error as itself, and `:stack-overflow` when none
  is parked (`VM.checkDeepData`). One that fails for another reason
  consumes the spoils under it and drops a failure parked since its
  snapshot (`VM.dropSpoils`), so no later call raises it; a failure
  parked before the snapshot belongs to an enclosing call and stays.

What a program sees: `(get {(lazy-seq [1 2]) :a} [1 2])` is `:a`, and
`(try (= [(lazy-seq (throw :x))] [[1]]) (catch any e e))` is `:x`.
The one wart: a native that compares or hashes a lazy seq nested
inside other structure whose body throws finishes its own loop, with
spoiled answers, before the throw surfaces, because `dispatch` cannot
stop it. Natives confine it to nested seqs: `=` walks its own
arguments in native context (§5), and the transient natives (`conj!`,
`assoc!`, `dissoc!`, `disj!`) realize the key or element they are
given (`seq.realizeAll`) before the in-place edit starts, so no code
runs in the middle of an edit of a transient the code can reach: `(let
[t (transient {})] (assoc! t (lazy-seq (assoc! t :x 1) [1]) 2))`
completes the inner `assoc!` before the outer one begins. A key in a
map or set was realized when the collection took it: an array form,
which indexes nothing by hash, still hashes each key it adds that
may hold a lazy seq
(`docs/CHAMP.md` §2.1), so `(frequencies [(lazy-seq (throw :x))])`
throws `:x` from `frequencies`.

A coll opcode that hashes copies its operands off the stack before it
builds, and reads its frame again after: running a body can grow the
stack and the frames.

**Never realized by**: `compare` (a lazy seq has no natural order:
`:kind-mismatch`, as a list), `identical?`, `meta`, `class`, `seq?` and
the other kind predicates, and `realized?`.

---

### 7. Producers

A producer is a Zig step function selected by a lazy block's `op`
(`src/seq.zig`), whose state is the block's `args`: `force` runs it as
it runs a `lazy-seq` body, with no closure and no bytecode in between.
A step returns a raw result: a new cell whose rest is a fresh
unrealized block carrying the advanced state, nil, or a block to
forward to (§4). A step that calls back into the VM keeps what it holds
in its own block (the seq it took of its source goes back into `args`
before the first call; the chunked cons it fills sits in the block's
result field while it fills, `lazy.setScratch`), so a collection
inside a call marks everything (`docs/GC.md`
§11.5, classes 3 and 5).

| Function | Result | Chunked | Notes |
|---|---|---|---|
| `range` finite | lazy; `()` when empty | yes, 32 | fixnums computed, the tower for other numbers (`(range 0 1 0.25)`); `(range s e 0)` is `(repeat s)`, `()` when `s` is `e` |
| `(range)` | lazy, infinite | no, as Clojure's `(iterate inc' 0)` | promotes past the fixnum range |
| `map` of one coll | lazy | when the source is | |
| `map` of several colls | lazy | no, as Clojure's | each source's seq taken as the step runs |
| `filter`, `remove`, `keep` | lazy | when the source is | a chunk that keeps nothing forwards to the next block |
| `map-indexed`, `keep-indexed` | lazy | when the source is | the index runs in the block |
| `iterate` | lazy, infinite | no | `f` is called when its element is first needed, as `Iterate`: `(second (iterate f x))` calls it once |
| `repeat` | lazy; `(repeat x)` infinite, one cell whose rest is its own block; `(repeat n x)` `()` for `n` at most 0 | no | |
| `repeatedly` | lazy; infinite without a count | no | each call when its element is first needed |
| `cycle` | lazy, infinite; `()` of an empty coll | no | `coll`'s seq is taken at the call, as Clojure's |
| `concat`, `lazy-cat` (macro) | lazy | a chunked coll's chunks, copied | one block per coll or chunk; a concat nested in a concat forces it as it walks, a native recursion per level (the stack guard stops a deep one, `(reduce concat [] ...)`, with `:stack-overflow`) |
| `mapcat` | lazy | as `concat` | a producer over the lazy seq of `(map f colls)`, so an infinite outer seq works where `(apply concat ...)` would realize it |
| `take`, `take-while` | lazy | no | |
| `drop`, `drop-while` | lazy | the source's own cells, after the walk | the walk runs at realization; `drop` of a view or of an unrealized range or repeat jumps at once |
| `partition`, `partition-all` | lazy | no | each part a realized lazy seq over a list of its elements (Clojure's `(doall (take n s))`), so `list?` of one is false |
| `distinct` | lazy | no | the elements seen in a persistent set in the block, which a step that throws and runs again finds as it was |
| `dedupe` | lazy | 32 outputs at a time, as Clojure's `sequence` over its transducer | |
| `interleave`, `interpose`, `take-nth`, `partition-by`, `tree-seq`, `flatten`, `reductions`, `drop-last`, `split-at`, `split-with`, `replace` of a seq, `random-sample`, `partitionv`, `partitionv-all`, `sequence` | lazy | as Clojure's (none but through the functions they are built on) | Clojure 1.12's definitions, in `src/stdlib/core.nx` with `lazy-seq`: bytecode and two blocks per element, where a native producer has none; none is in a benchmark |

**Chunked sources** are the seqs that hand out a slice of their
elements and the seq after them without allocating: a vector's view
(the leaf from its offset to the leaf's end, the rest the view at the
next leaf boundary, the same block) and a chunked cons (its chunk from
its offset, the rest its `more`). The seq of a map, a set or a string
is a view of a fresh vector once it has four elements, so it is
chunked where Clojure's is not (§9). The chunked step fills a chunk
through one prepared `vm.Callback`, as `Results` fills an open tail:
`(map :score rows)` keeps its in-place lookup and `(map inc xs)` its
direct leaf call. Per 32 elements it allocates two blocks, the
chunked cons and the next lazy block; `filter`, `remove`, `keep` and
`keep-indexed` gather what they keep first (a source element needs no
root, a result waits on a root scope) and make the chunk its exact
size. Over an unchunked source, two blocks per element, as Clojure's
objects.

**Pure producers compute without realizing.** While a block of a
fixnum `range`, of `(range)`, of `repeat`, of `iterate` or of `cycle`
is unrealized, `reduce` runs over the elements it would hold, calling
the function with no allocation and caching nothing
(`LongRange.reduce`, `Repeat.reduce`, `Iterate.reduce`,
`Cycle.reduce`); `iterate`'s `f` "must be free of side effects", as
Clojure's docstring says, since a later walk calls it again. `count`
of a range or a finite repeat is its arithmetic count, `nth` its
arithmetic element, `drop` and `nthrest` a new range or repeat from the
index, and every native that walks an unrealized range (`vec`, `into`,
`set`, `sort`, `apply`, `mapv`, `filterv`, `frequencies`, `group-by`,
...) computes its elements without making a cell, as Clojure's
`LongRange` iterator does; `doall` and `dorun` realize it.
`(reduce + (range 100000000))` allocates nothing, and `(count (range
1e12))` is O(1). Recomputing is invisible: a range's elements are
numbers. A range that has been realized (by `seq`, `first`, a producer
over it, `doall`) is a realized chain, walked as any other.

---

### 8. Printing, storage and the codec

**Printing.** The printer (`src/format.zig`) runs no code: a block
whose body has not run prints as `...` (`(0 ...)`), which an error
report shows when the value it names holds one. A realized chain that
is a cycle (`(repeat x)` once walked is one cell whose rest is its own
block, as is `(def s (lazy-seq (cons 1 s)))`) prints as far as the
printer finds the cycle (Brent's algorithm: within three times the
length of the cycle and of the cells before it) and then `...`, so an
error report naming one ends: `(repeat 1)` prints `(1 ...)`. Everything that prints
a value a program will see realizes it first, in native context
(`seq.realizeAll`): `pr`, `prn`, `print`, `println`, `pr-str`, `str`,
`format`'s `%s`, `nexis.string/join` and `spit`, and the REPL and `-e`
before they print a result (`VM.realizeOutside`). A throw while a
result realizes is reported as an evaluation's runtime error, with its
trace, and the REPL binds it to `*e` and goes on. A lazy seq prints as
a list, `(lazy-seq nil)` as `()`; `str` of one is its printed text
(Clojure's is `clojure.lang.LazySeq@` and a hash).

**The codec** never realizes (`docs/CODEC.md` §3): a realized lazy seq
is written as the list of its elements, and one any block of which has
not run is `error.Unrealized`, on which the storage native
(`db/put!`, `db/put-key!`, `db/alter!`'s result) realizes the value and
encodes it again; `db/put-key!` realizes it outside the transaction
and begins the write again. Decoding gives a list, `=` to the seq and
hashed alike.

**`db/*`.** The storage natives stay eager: `db/scan` returns a
realized list. A lazy seq whose body reads a transaction realizes when
it is walked: walked after `with-tx` or `with-read-tx` closed it, it
raises `:tx-closed`, as `line-seq` outside `with-open` does in
Clojure. `doall` or `mapv` inside the block is the remedy.

**Code that walks a value as data.** The expander making a macro's
result, `eval`'s or `macroexpand`'s argument a form, and the Nextomic
natives over their arguments, over what a transaction function
returns, and over the results a query binds or aggregates, take the
value through `seq.asLists`: every lazy seq in it is realized and
replaced by the list of its elements, the collections on the way to
one copied (keeping their metadata) and everything else shared, so the
code after it knows lists only and runs no code. A sorted collection is
rebuilt from its entries in their order, a key made a list being `=`
to the seq it was, so no comparator runs. `` `(a ~@xs) `` realizes `xs`'s spine before
it splices (`coll:concat`, `docs/VM.md` §10.8).

---

### 9. Where nexis differs from Clojure

- **Chunking of built seqs.** The seq of a map, a set, a string or a
  sorted collection, and the list an eager function builds (`sort`,
  `reverse`, `keys`, ...) once it has four or more elements, is a
  vector's view, so mapping over it takes 32 at a time where Clojure
  walks one at a time. It shows only through side effects in the
  mapped function, which Clojure's docstrings disclaim.
- **`apply` realizes its last argument**: `(apply f (range))` does not
  end, where Clojure's variadic rest can stay lazy. `mapcat` is lazy,
  so prefer it to `(apply concat ...)` over an unbounded seq.
- **`str` of a lazy seq** is its printed text, `"(2 3)"`, where
  Clojure's is `clojure.lang.LazySeq@` and a hash.
- **Arguments are checked at the call**: `(take :a xs)` and `(partition
  0 xs)` raise when called; Clojure raises when the seq is realized, or
  returns an infinite seq of `()` for `(partition 0 xs)`.
- **Holding the head.** The VM roots every slot of its stack
  (`docs/VM.md` §9), so a lazy seq a local or a call's argument holds
  keeps what it realized until the slot is reused: `(reduce + (map inc
  (range 100000000)))` realizes and keeps the mapped seq, where
  Clojure's locals clearing lets it go as it walks; `(reduce + (range
  100000000))` itself allocates nothing (§7). A native's call block is
  cleared when the native returns (`docs/VM.md` §6), so a seq passed
  to a native and walked by a later one is not kept by the first
  call's block: in `(reduce + (map inc (filter even? (map inc (range
  n)))))` only the outermost seq stays, and not even that: `reduce`,
  like `frequencies`, `group-by`, `some`, `every?`, `last` and
  `dorun`, consumes its sequence argument, clearing its slot and
  keeping only its walk's place (`docs/GC.md` §11.5), so such a
  pipeline runs in constant memory. A seq bound to a local, or passed
  to a closure, stays held by the slot until it is reused; clearing a
  local at its last use, as Clojure does, needs liveness in the
  compiler.
- **A lazy key of a small map is realized when the map takes it**, as
  a set's or a larger map's is in both (§6); Clojure's array map
  compares keys and hashes none, so `(assoc {} s 1)`, `frequencies`
  and `group-by` leave a lazy key unrealized there until something
  hashes or prints the map.
- `counted?` of a range is false (Clojure's `LongRange` is counted);
  `realized?` of a cons or a chunked cons is true (Clojure's throws).
- **A datom form and a lookup ref are vectors** to Nextomic, so a lazy
  one, made a list (§8), is not one; Datomic takes any list.
- **A `sequence` step that throws** runs again from its block's
  source position with the transducer's state as the failed step left
  it: `(sequence (comp (map f) (take 4)) (range 10))` whose `f` throws
  once at 2 gives `(0 1)` on the next walk, `take` having counted 0
  and 1 twice. Clojure's iterator goes on from its advanced source and
  transducer and drops the outputs of the chunk it was filling: `(3 4)`.
  Both reuse state the failure advanced; neither is a fresh run.
- **`eduction`** is `sequence` over the composed transducers: a cached
  lazy seq, where Clojure's `Eduction` runs the transform again on
  every reduce. Only side effects in the transform tell them apart.

---

### 10. Transducers

`transduce`, `completing`, `cat`, `halt-when`, `eduction`, `into`
with a transducer (`(into to xform from)`) and `sequence` with one are
Clojure 1.12's (`src/stdlib/core.nx`), and so are the transducer
arities: `(map f)`, `(filter p)`, `(remove p)`, `(keep f)`, `(take n)`,
`(take-while p)`, `(drop n)`, `(drop-while p)`, `(map-indexed f)`,
`(keep-indexed f)`, `(partition-all n)`, `(partition-by f)`, `(mapcat
f)`, `(interpose sep)`, `(distinct)` and `(dedupe)`. The ones whose
other arities are natives reach the `xf-` function of their name in
`core.nx`; a stateful one keeps its state in volatiles, one per
application of the transducer to a reducing function. A reduction
stops at a `reduced` value as `reduce` does.

`(sequence xform coll)` is a producer (§7, `op_sequence`): the
transducer applied once to `conj!`, each step runs it over the
source's elements into a transient vector until 32 outputs or more are
waiting, the source ends, or a step returns a reduced value, and
hands them out as one chunk; at the end it runs the completion arity
once, so `partition-all`'s last part comes out. As in Clojure's
`TransformerIterator`, the outputs are what reached the transient:
what the transducer returns is not an accumulator, and a reduced value
only ends the walk, so `(sequence (halt-when #{3}) [0 1 2 3 4])` is
`(0 1 2)`. A step that throws runs again from its block's source
position (§4), but the transducer's state (a stateful one's volatiles)
is as the failed step left it (§9). It realizes the source
as far as the outputs need, as Clojure's `TransformerIterator` pulls
it. Unlike the other producers' (§7), its walk's position stays out of
the block, on a root scope while the step calls the transducer: the
seq it took of a source that is not one (a vector's view, a set's
elements) is all that reaches what the walk has left. `(sequence xform c1 c2 ...)` runs the transducer over `(map vector
c1 c2 ...)`, its reducing function called with each tuple's elements.
A call through the transducer costs a closure call per element where
the native producers call their function directly, so `(sequence (map
f) xs)` is slower than `(map f xs)`.

---

### 11. What changes for a program written against eager sequences

- **Nothing runs until something walks the result.** `(map println
  xs)` at a script's top level prints nothing; use `run!`, `doseq` or
  `dorun`. `(with-out-str (map print xs))` is `""`, and `(time (map f
  xs))` times nothing. A `for` used as a loop for its effects is a
  `doseq`.
- **Errors surface where the seq is walked.** `(try (map f xs) (catch
  ...))` does not catch what `f` throws: the throw comes when the result
  is printed or consumed. Realize it inside the `try` (`doall`, `vec`,
  `mapv`).
- **Dynamic bindings and transactions are read at realization.** A lazy
  seq built inside `binding`, `with-tx`, `with-read-tx` or
  `with-snapshot` and walked outside sees the outer binding, or raises
  `:tx-closed`. Realize it inside.
- **`iterate` takes two arguments**: `(iterate f x n)` is
  `:arity-mismatch`; write `(take n (iterate f x))`. `(range s e 0)`
  repeats `s` where it raised `:invalid-argument`.
- `(list? (map f xs))` is false (`seq?` is true) and `(class (map f
  xs))` is `:lazy_seq`; code that asked `list?` to find a sequence asks
  `seq?` or `sequential?`, and `extend-type :list` does not cover a lazy
  seq: extend `:lazy_seq` too. `counted?` of a lazy seq is false;
  `count` walks it (O(1) of an unrealized range). `peek` and `pop` of
  one are `:kind-mismatch`, as of Clojure's `LazySeq`.
