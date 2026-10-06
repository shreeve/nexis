## GC.md — Precise Mark-Sweep Garbage Collector

The contract of `src/gc.zig`: what the collector owns, its roots, how
each kind is traced, when a cycle runs, and the rule every native
follows to keep its values alive. PLAN §23 #2 and #18 freeze the
strategy; the header and its mark bits are `docs/HEAP.md` §1 and §4.

The collector is **precise, non-moving, stop-the-world mark-sweep with
an iterative mark phase, run by the VM at its safe point.**
`gc.Collector.collect` marks from the caller's roots and the host's,
tracing each block by its kind; `Heap.sweepUnmarked` is the sweep. The
VM is the host: `src/vm.zig` enumerates the runtime's roots (§3),
traces closures and upvalue cells (§5), and runs a cycle between two
instructions once the heap has allocated enough since the last (§7).
There is no stack scanning, no generation, no concurrency, no write
barrier and no finalizer on a block (§9); the one resource the
collector ends is a db transaction the program dropped (§5).

A VM over a borrowed heap (the sub-VMs the expander runs macros on,
which allocate on the heap, and use the registries, of the VM whose
Vars they use, `docs/VM.md` §9.1) never collects: it cannot enumerate the owner's roots. The collector also
runs over a bare heap with explicit roots and no host in the tests
(§10).

---

### 1. Strategy

Mark-sweep over the blocks of `src/heap.zig`, with complete roots and
per-kind precise tracing. One isolate on one thread (PLAN §23 #5) makes
stop-the-world trivially correct and write barriers unnecessary. Blocks
never move, so a pointer is a stable identity (identity kinds hash it,
SEMANTICS §3.3) and interned names, emdb byte slices and native handles
need no relocation. A generational collector is admissible only if
measurements demand it (PLAN §23 #18).

---

### 2. What the collector owns

| Storage | Owner | Collected |
|---|---|---|
| Blocks from `Heap.alloc`: every heap kind, and collection-internal nodes | `src/heap.zig` | yes |
| Closures and upvalue cells (kinds `function`, `cell_internal`) | `src/heap.zig`, laid out by the VM | yes, traced through the host (§5) |
| Heap constants in `Routine.consts` (string, bignum and constant-collection literals) | the VM's heap | yes, rooted through the frames and closures that run the routine (§3) |
| Keyword and symbol names | `src/intern.zig` | no; freed by `Interner.deinit` (`docs/INTERN.md`) |
| Forms and macro-expansion intermediates | the caller's arena | no; freed with the arena |
| Vars, namespaces, routines | `VM.runtime_arena` and the compiler's allocator | no; they live as long as the VM, and their values are roots (§3) |
| `NativeFn` descriptors, `db.Connection` | static storage or the VM | no; pointer kinds with no block, skipped by `markValue` (`Heap.isBlockKind`) |
| db transaction handles (`db.Handle`) | `src/db.zig`, on the VM's allocator | ended and freed by the handle sweep once no Value reaches them (§5) |

A heap block that points into storage the collector does not own
(interned bytes, an emdb page) holds data, not a GC edge.

---

### 3. Roots

A root is a block or Value the collector starts marking from; anything
not reachable from one is freed. There are two sources:
the `roots` slice `collect` takes (the tests' fixtures) and the host's
`Host.roots` callback, which the VM implements as `VM.gcRoots`. The
VM's roots, in the order it marks them:

1. **The backing stack, in full** (`vm.stack.items`): every slot of
   every frame's window and the slots above them. A slot above a
   popped frame keeps its stale value until the slot is grown into
   again, which retains garbage for a while and is sound. Between
   top-level forms the stack holds nothing: `retargetTop` and
   `resetAfterError` clear every slot, so a form keeps nothing an
   earlier one left alive. A slot holding a `cell_internal` Value
   marks the cell.
2. **Every frame**: the closure it runs, whose trace reaches its cells
   and its routine's constants once however many frames run it; or,
   for a frame with no closure (a top-level form, a loader routine),
   the heap constants of its routine, recursively through the
   routines its capture descriptors name (`Routine.capture_descs`).
3. **Every Var of every namespace** in the registry, and of the
   ad-hoc namespace: `root`, `meta` and `thread_value`. A `var_` Value
   is never marked itself (`Heap.isBlockKind` excludes it); its
   contents are reached only here.
4. **The dynamic-binding stack**: the value each open `binding` frame
   saved (`vm.dyn_saves`); the bindings in force are the Vars'
   `thread_value`, covered by 3.
5. **The root stack** (`vm.roots`): what `callValue` and natives push
   under the rooting rule (§11.5).
6. **Pending `finally` throws** (`vm.finally_stack`), **the values of
   throw origins** handlers still hold (`vm.origins`, `docs/VM.md` §12),
   **the unhandled throw** and **the halt result** (`vm.result`).
7. **The protocol registry**: every method implementation and default.
8. **The Nextomic query caches**: the query value of every entry in the
   per-VM parse and rule caches, through the hook the Nextomic natives
   install (`vm.nextomic_query_mark`), since a parse borrows from its
   query value (`docs/NEXTOMIC.md` §5).

The interner holds no heap values (keywords and symbols are
immediates). Open db and Nextomic connections hold none either; a
durable ref, a transaction handle or a Nextomic db-value or entity is
reachable from wherever the program keeps it.

---

### 4. Collector API

| `gc.Collector` member | Contract |
|---|---|
| `init(heap)` | A collector over `heap` with no host |
| `deinit()` | Frees the gray worklist, whose capacity `collect` keeps |
| `host: ?Host` | `Host.roots(ctx, collector)` marks every root the runtime holds, once per cycle after the explicit roots; `Host.trace(ctx, h, collector)` walks an already-marked `function` or `cell_internal` block |
| `markValue(v)` | Ignores immediates and the pointer kinds with no block (`native_fn`, `var_`, the db connection), flags a db transaction handle reached (§5), and marks any other Value's header |
| `mark(h)` | Sets the mark bit once and, unless `h` is a leaf (string, bignum, typed vector, durable ref, protocol, protocol fn, Nextomic connection or db) with no metadata, which has nothing to trace, traces `h` in place when the trace that reached it may (below), else pushes it on the gray worklist; outside a drain it drains before returning, so a direct call marks the transitive closure |
| `markInternal(h) bool` | Sets the mark bit of a collection-internal node and returns whether this call set it; walks neither the node's `meta` nor its kind: the caller walks the payload |
| `collect(roots) usize` | Marks the roots and the host's roots, each root's transitive closure before the next root, sweeps the db transaction handles of the heap (`db.sweepHandles`, §5) and then the blocks (`Heap.sweepUnmarked`), resets the heap's allocation counter, and returns the number of blocks freed |

`mark` and `markInternal` share one primitive (`markHeaderOnce`), so
the mark bit has one owner. Nothing in the API can fail: sweeping only
frees, and a cycle that runs out of memory frees nothing.

**Iterative marking.** The mark phase is a loop, never an unbounded
recursion on the data: `mark` pushes the header on `gray`; the drain
pops a header, marks its meta map and runs its kind's trace (§5). A
block that trace marks is traced there and then, in place, and so on
down to four levels below the popped header (`in_place_depth`); what
the fourth level marks is pushed on `gray`. However deep the data,
nesting costs entries of `gray`, never more than those four levels of
native frames, and a wide structure queues only what lies past them:
a vector of a million small maps, alone or inside a transient, an
atom or a record, queues none of the maps. A kind's trace walks its
own interior nodes in place with `markInternal`, which is bounded: a
vector trie is at most seven levels deep, a CHAMP tree seven interior
levels and a collision node, and
a list's tail chain is walked in a loop. `collect` marks one root at a
time and drains after each, so the worklist holds what one root
reaches, never every root's children at once (the root stack of a
native that keeps its values there, §11.5). If `gray` cannot grow,
the header stays marked but untraced and the cycle is abandoned:
`collect` clears every mark bit and frees nothing, and the allocation
that next fails raises the VM's `OutOfMemory`, a runtime error like
any other (`docs/TOOLING.md` §1). The VM keeps `gray` between cycles
(`VM.gc_gray`), so a cycle reuses the capacity the last one grew.

---

### 5. Per-kind trace contract

Each heap kind whose blocks hold heap values has its module export
`trace(h, visitor)` (CHAMP, which hosts two kinds, exports `traceMap`
and `traceSet`); a leaf kind has none. The visitor is
duck-typed: `markValue`, `mark`, `markInternal`, which `gc.Collector`
provides. The rules:

1. **Do not mark `h`**: the collector marked it before dispatching.
2. **Do not walk `h.meta`**: the collector does (§6).
3. **Mark every Value the block references** with `visitor.markValue`.
4. **Walk interior nodes with `visitor.markInternal`**, and walk a
   node's payload only when the call returns true. Interior nodes are
   ordinary blocks for the sweep; "internal" only means they are
   reached through their owner's trace, not through the kind switch.

The dispatch in `Collector.trace`:

| Kind | Trace | Walks |
|---|---|---|
| `string`, `bignum`, `typed_vector`, `durable_ref`, `protocol`, `protocol_fn`, `nextomic_conn`, `nextomic_db` | none: the leaves | nothing: bytes, limbs, unboxed elements, inline store id, tree and key (a durable ref's advisory connection pointer is not a heap block, `docs/DB.md` §7.3), ids, or a VM-owned pointer with inline text and numbers |
| `list` | `list.trace` | subkind 0 (cons): every head, and the tail chain in a loop (cells through `markInternal`, a cell's meta through `mark`); subkind 1 (empty): nothing; subkind 2 (vector view): its vector, through `markValue`, also when the view ends a cons chain |
| `lazy_seq` | `lazy.trace` | by the shape in the header's flags (`docs/LAZY.md` §3): a lazy block's producer arguments, a cons's first element, a chunked cons's every slot (unwritten ones are nil), each heap value through `markValue`; the chain (a lazy block's `result`, a cons's or chunked cons's `more`) in a loop, through `markInternal`, so a chain of any length costs no worklist; a list at the chain's end through `markValue` |
| `persistent_vector` | `vector.trace` | the tail node, every slot of its block (vectors sharing a tail use different lengths of it, `docs/VECTOR.md` §2), and the trie, interior and leaf nodes through `markInternal` |
| `persistent_map`, `persistent_set` | `champ.traceMap`, `champ.traceSet` | the array-form entries, or the CHAMP trie with interior and collision nodes through `markInternal` |
| `sorted_map`, `sorted_set` | `sorted.trace` | the comparator, then every tree node through `markInternal` and its key and value through `markValue`, recursing to the tree's height (`docs/SORTED.md` §2) |
| `transient` | `transient.trace` | the wrapped collection (`docs/TRANSIENT.md` §10) |
| `atom` | `atom.trace` | the contained value, the validator and the watches map (`docs/ATOM.md` §7) |
| `record` | `record.trace` | the field map |
| `nextomic_entity` | `nextomic_handle.traceEntity` | the db-value box and the map of the entity's last full read |
| `function` | `Host.trace` (`VM.gcTrace`) | every upvalue cell (cells are blocks of their own kind, marked through `mark`), then the routine's heap constants, recursively through nested routines (`docs/VM.md` §6); a routine with more than eight constants and nested routines is walked once per cycle however many closures reach it (`VM.gc_routines`) |
| `cell_internal` | `Host.trace` (`VM.gcTrace`) | the cell's value |
| anything else (`var_`, whose payload is an arena `*Var`; `byte_vector`, `error_`, `meta_symbol`, reserved and never allocated; an immediate) | panic | |

**Transaction handles.** A `db_write_txn` or `db_read_txn` Value
points at a `db.Handle`, which is not a block but holds an emdb
transaction: the file's writer, or one of its reader slots. `markValue`
sets the handle's reached flag. After the drain, `db.sweepHandles`
walks the process's handles whose connection is on this heap: a
flagged or held one (a native is running a callback over it) has its
flag cleared and survives; any other has its transaction ended (a
write aborted, a read ended) and is freed. Ending one frees emdb's
transaction and releases its lock or slot, touching nothing on the
heap. A cycle whose worklist could not grow ends nothing and only
clears the flags. `docs/DB.md` §3.2 is the db side.

A `function` or `cell_internal` block reaching a collector with no
host panics, as does any immediate or sentinel kind byte on a header.
The collector panics rather than skip: a silent no-op on a kind that
should trace would be an invisible retention bug, and reaching one of
these arms means memory corruption or a Value built with the wrong
kind.

---

### 6. Metadata

`HeapHeader.meta` points at a metadata map or is null. Metadata never
takes part in equality or hash (SEMANTICS §7), but it is a live
reference: when the drain traces a header it marks `h.meta` first,
then dispatches on the kind, so per-kind traces ignore the field. Only
a user-visible root carries metadata; interior nodes of a vector, map
or set never do, so `markInternal` does not look at `meta`. A cons
cell reached along a list's tail may carry metadata of its own, which
`list.trace` marks.

---

### 7. Cycle, trigger and safe point

```
collect(roots):
    for each root, then host.roots(...):
        mark(root)                      // push on gray
        while gray.pop() |h|: trace(h)  // its transitive closure; a
                                        // block trace marks is traced
                                        // in place, four levels deep
    empty gray, keeping its capacity
    db.sweepHandles(heap, !overflowed)  // ends unreached transactions
    freed = heap.sweepUnmarked()        // frees unmarked blocks;
                                        // clears the mark on survivors
                                        // (or, if gray could not grow:
                                        // clear every mark, free nothing)
    heap.resetAllocationCounter()
    return freed
```

No marks carry between cycles: each starts and ends with every mark
bit clear. Only the worklist's capacity carries over.

**Trigger.** `Heap.alloc` counts the bytes it hands out in
`allocated_since_collect`, and `collect` resets the counter. The VM
owns the policy (`VM.gcDue`): a cycle is due once the counter reaches
`gc_next_at`, which each cycle sets to the larger of `gc_threshold`
and `gc_growth_percent` percent of `Heap.live_bytes` after the sweep,
so a large live set is not re-marked every few kilobytes. Every VM
starts with `GcPolicy.default` (16 MiB, 100 %). With `NEXIS_GC_STRESS`
set in the environment every VM starts with `GcPolicy.stress` (4 KiB,
2 %): a cycle becomes due every few kilobytes while under about
200 KiB is live (a booted standard library leaves 95 KiB), which is
how the suite proves the rooting rules, and a large live set spaces
cycles out by 2 % of itself, so a program that
holds a million values stays linear rather than re-marking them every
4 KiB. A test can set the three fields on its VM to
the same effect. A VM with `gc_enabled = false` or a borrowed heap is
never due.

**Safe point.** The VM tests `gcDue` in two places. The first is
before fetching an instruction in its one run loop (`VM.loop`, which
`run`, `callValue` and `runRoutine` drive), at a loop's first fetch
and at every fetch after an instruction that could have allocated:
`math` through the numeric tower (not a fixnum result computed
inline), a `call:call` that ran a native, a protocol fn or a lookup
other than the in-place keyword lookup of `docs/VM.md` §8, or entered
a closure through the general entry of `docs/VM.md` §6 (not the
direct one), and every `closure` instruction but `get-cell`, and
every `coll` and `ctrl` instruction. After `mov`, `cmp`, `jump`,
`var`, `call:return` or `call:return-nil` the counter cannot have
moved. Between two instructions every
live value is in one of the roots §3 lists, so a cycle there frees
nothing live. The second is `callValue` of anything but a closure (a
native, a protocol fn, a lookup), once its arguments are on the root
stack: a native that calls natives in a loop (`(reduce conj #{} xs)`)
reaches no closure frame, and without it would run to its end without
collecting. A native keeps what it holds across `callValue` on its
root scope already (§11.5), so a cycle there frees nothing live
either. A leaf native (`docs/VM.md` §6) skips it while no cycle is
due and takes it once one is, so `(reduce * xs)` collects as it goes;
a keyword or symbol a `Callback` looks up in a map, a record or nil
skips it (the lookup does not allocate). A `Callback`'s call of a closure reaches the
loop's entry, the first safe point, as `callValue`'s does.
`Heap.alloc` never collects: the compiler, a native and one instruction
(a rest list, a closure and its cells) allocate as many blocks as they
like with no rooting, and what one instruction allocates is in a slot
before the next fetch. A cycle therefore runs inside a native only
through a call back into the VM, which is what the rooting rule
(§11.5) covers, or where a native that holds nothing but its rooted
arguments runs one itself: a native that begins a db transaction
collects once when the file's writer or reader slots are taken by a
handle the cycle could end (`docs/DB.md` §3.2). Such a native is at
the point a `callValue` from it would be, so every frame beneath it is
already safe for a cycle. `VM.collectGarbage` runs one cycle on demand from a
safe point and counts it in `gc_cycles`; tests call it directly.

---

### 8. Cycles in the object graph

Persistent collections are immutable, so a node's children are fixed
when it is built and those kinds cannot form a cycle; a metadata map is
attached when a new root is built and never changes after. An atom can:
its value may reach the atom itself, as may a closure that a Var's
root reaches and that calls through the same Var. The mark bit makes
every such cycle safe: `markHeaderOnce` returns false on a block
already marked, so the walk stops there.

---

### 9. Absent

- **Stack scanning.** The VM's slot windows are precise.
- **Write barriers, generations, concurrent or incremental marking.**
  One thread, stop-the-world (PLAN §23 #5, #18).
- **Finalizers on blocks.** No block owns an OS resource. A db
  connection is closed explicitly; a db transaction handle, which is
  not a block, is ended by commit, abort, `db/close` or the handle
  sweep (§5).
- **Transient ownership in the collector.** A transient is an ordinary
  block whose trace walks the wrapped collection; its owner token is
  the kind's business (`src/coll/transient.zig`).
- **A per-PC liveness map.** The whole backing stack is a root, so a
  dead slot retains its value until it is overwritten or grown into.
- **Collection in a sub-VM.** Its garbage is the owner's to collect
  after it returns.

---

### 10. Testing

The inline tests in `src/gc.zig` cover the primitives and small graphs
of every traced kind (roots, nesting, CHAMP and vector interior nodes,
atoms, idempotence, metadata). `test/prop/gc.zig` G1–G6b drive
randomized graphs against a reachability model, a half-million-cell
list (G3b) and a 300,000-level chain of vectors, maps, atoms and meta
maps (G3c) through a cycle, repeated cycles without leaks
(G5), and programs that allocate on every step of a loop on a VM under
`GcPolicy.stress` (G6, G6b). `test/prop/heap.zig` H2, H3 and H6 test
the sweep primitive with hand-set marks, and `test/prop/transient.zig`
T4 and T4b collect with a transient as the only root. Under the
runtime, the `gc:` tests of `test/integration/eval_pipeline.zig` run
every callback-taking native of §11.5 with allocating callbacks on a
stressed VM, and `test/nextomic/gc.nx` does the same through `bin/nexis`
for query predicates, function bindings and custom aggregates. The
`db:` test of dropped transactions ends ten thousand unreachable read
handles and dropped writes under both policies.
`zig build test -Dgc-stress` runs the whole suite with every VM
under the stress policy (each run gets `NEXIS_GC_STRESS=1`).

---

### 11.5 The rooting rule for natives

A cycle can run inside any `VM.callValue` (§7), so a native that holds
a heap Value only in a Zig local across a call back into the VM must
make sure a root reaches it. What is rooted already:

- **A native's arguments, for its whole call**: through the caller's
  slots when reached by `call:call`, through the root stack when
  reached by `callValue`, which pushes a native callee's `args` for the
  call's duration. A closure callee holds its arguments in its own
  slots.
- **Everything reachable from a rooted value**, so an element of an
  argument collection needs nothing.
- **Nothing is lost between callbacks**: `Heap.alloc` never collects,
  so a native may allocate freely with unrooted locals as long as it
  does not call back in.

The rule each native follows, by what it holds across a further
`callValue` (natives cite the class number):

1. **An argument, or anything reachable from one**: nothing to do.
   The string natives, the printers, `buildListFromSlice`, `swap-vals!`
   (its `[old new]` vector is built after the last callback, with no
   safe point in between) and every native that never calls back in.
2. **Only the next callback's argument**: nothing to do, since
   `callValue` roots it for the call. `reduce`, `reduce-kv`, `swap!`,
   an atom's validator and its watches (the old and new states are
   their arguments), `alter-meta!`, `db/alter!` and `db/reduce-tree` (its decoded value
   is the call's argument and is not kept), `some` and `every?`.
3. **Callback results kept across further callbacks**: a
   `VM.rootScope()` pushes each one, and its deferred `release` drops
   them on every exit path, a `ControlTransferred` unwind included.
   `Results`, the result builder of `mapv` and `filterv`: it pushes the first 32 results on its root scope, and
   from the 33rd roots a transient vector in their place, writing
   each later result into its open tail, whose every slot the
   vector's trace marks (§5, `docs/LIST.md` §1); `reductions`, `repeatInto` (`repeatedly`,
   `iterate`), `keyExtremum` (`max-key`, `min-key`: the best key so
   far), `sortImpl` when a key fn is given; the `nextomic/q` hook for
   every user-function result and every heap value the query pipeline
   builds (a tuple or full-text result bound as one value, an
   aggregate's vector or set); and the Nextomic transaction-function
   hook (`transact`, `with`) for the db-value each call receives and
   every tx-data a function returns, for the transaction's life; and
   the atom mutators, for the watches map they run through, which a
   watch that adds or removes one replaces (`docs/ATOM.md` §4.8).
4. **Values a native builds itself and keeps across callbacks**: no
   argument reaches them. The iterator over a map, a record or an
   entity builds each `[k v]` entry, and the one over a typed vector
   boxes each element. `sieveInto` (`filterv`) passes each element to the predicate,
   its call's argument, and keeps it in its `Results` before the next
   call;
   `whileSplit` (`take-while`, `drop-while`) and
   `reductions` keep what the iterator yields and walk with
   `rootedSeqIter`, which pushes each built value on the native's
   root scope; `sortImpl` (`sort`, `sort-by`) collects the elements and
   pushes them all (`pushAll`) before any key fn or comparator runs;
   `group-by` builds its map on a transient it pushes, which reaches
   every group, and stores each element and key before its next call.
   A native that only passes a built value to the next call (`map`,
   `some`, `every?`, `reduce` over a map) is class 2 for it.

5. **Realization**: walking a lazy seq runs its bodies
   (`docs/LAZY.md` §4), which may collect at every step, so every
   `seq.SeqIter.next` over a seqable that may be lazy is a call back
   into the VM. What a native holds across the walk must be reachable
   from its arguments or on a root scope: a realized chain is cached
   in the block that heads it, so the elements already walked reach
   from the argument the walk started at, but a callback result
   (`reduce`'s accumulator, which waits in a root slot between calls),
   a value the native built (`frequencies`' transient, `select-keys`'
   result) and a value another iterator built (the entries of a map
   walked beside a lazy seq by `concat`, `interleave`, `zipmap`,
   `partition`'s pad, which walk with `rootedSeqIter`) are not.

A new native that calls back into the VM states its class next to its
`callValue`.

**Routine constant pools.** The heap constants of a routine (string,
bignum and constant-collection literals, allocated on the VM's heap)
are rooted through every frame running the routine and every closure
over it, recursively through the routines its capture descriptors
name (§3), so a literal lives as long as any code that can load it and
no longer.
