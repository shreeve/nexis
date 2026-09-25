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
barrier and no finalizer (§9).

A VM over a borrowed heap (the sub-VMs the expander runs macros on,
which allocate on the heap of the VM whose Vars they use) never
collects: it cannot enumerate the owner's roots. The collector also
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
| `NativeFn` descriptors, `db.Connection`, db transaction handles | static storage or the VM | no; pointer kinds with no block, skipped by `markValue` (`Heap.isBlockKind`) |

A heap block that points into storage the collector does not own
(interned bytes, an emdb page) holds data, not a GC edge.

---

### 3. Roots

A root is a block or Value the collector starts marking from; anything
not reachable from one and not pinned is freed. There are two sources:
the `roots` slice `collect` takes (the tests' fixtures) and the host's
`Host.roots` callback, which the VM implements as `VM.gcRoots`. The
VM's roots, in the order it marks them:

1. **The backing stack, in full** (`vm.stack.items`): every slot of
   every frame's window and the slots above them. A slot above a
   popped frame keeps its stale value until the slot is grown into
   again, which retains garbage for a while and is sound. A slot
   holding a `cell_internal` Value marks the cell.
2. **Every frame**: the closure it runs, whose trace reaches its cells
   and its routine's constants once however many frames run it; or,
   for a frame with no closure (a top-level form, a loader routine),
   the heap constants of its routine, recursively through the
   routines in its constant pool.
3. **Every Var of every namespace** in the registry, and of the
   ad-hoc namespace: `root`, `meta` and `thread_value`. A `var_` Value
   is never marked itself (`Heap.isBlockKind` excludes it); its
   contents are reached only here.
4. **The dynamic-binding stack**: the value each open `binding` frame
   saved (`vm.dyn_saves`); the bindings in force are the Vars'
   `thread_value`, covered by 3.
5. **The root stack** (`vm.roots`): what `callValue` and natives push
   under the rooting rule (§11.5).
6. **Pending `finally` throws** (`vm.finally_stack`), **the unhandled
   throw** and **the halt result** (`vm.result`).
7. **The protocol registry**: every method implementation and default.

The interner holds no heap values (keywords and symbols are
immediates). Open db and Nextomic connections hold none either; a
durable ref, a transaction handle or a Nextomic db-value or entity is
reachable from wherever the program keeps it. The Nextomic query caches
keep their query values alive through the Vars
`nexis.internal/#%query-cache` and `#%rules-cache`, which are roots
like any Var.

**Pinned is not a root.** A pinned block (`HeapHeader.isPinned`)
survives every sweep whether or not it is reachable. The heap provides
the bit and `sweepUnmarked` honours it; no runtime module pins a
block, only tests do.

---

### 4. Collector API

| `gc.Collector` member | Contract |
|---|---|
| `init(heap)` | A collector over `heap` with no host |
| `host: ?Host` | `Host.roots(ctx, collector)` marks every root the runtime holds, once per cycle after the explicit roots; `Host.trace(ctx, h, collector)` walks an already-marked `function` or `cell_internal` block |
| `markValue(v)` | Ignores immediates and the pointer kinds with no block (`native_fn`, `var_`, the db handles); marks any other Value's header |
| `mark(h)` | Sets the mark bit once and pushes `h` on the gray worklist; outside `collect` it drains before returning, so a direct call marks the transitive closure |
| `markInternal(h) bool` | Sets the mark bit of a collection-internal node and returns whether this call set it; walks neither the node's `meta` nor its kind: the caller walks the payload |
| `collect(roots) usize` | Marks the roots and the host's roots, drains the worklist, sweeps (`Heap.sweepUnmarked`), resets the heap's allocation counter, and returns the number of blocks freed |

`mark` and `markInternal` share one primitive (`markHeaderOnce`), so
the mark bit has one owner. Nothing in the API can fail: sweeping only
frees.

**Iterative marking.** The mark phase is a loop, never a recursion on
the data: `mark` pushes the header on `gray`; the drain pops a header,
marks its meta map and runs its kind's trace (§5), whose own `mark` and
`markValue` calls push in turn. A structure nested a million levels
deep costs a million entries of `gray`, not a million native frames. A
kind's trace walks its own interior nodes in place with `markInternal`,
which is bounded: a vector trie is at most seven levels deep, a CHAMP
tree thirteen, and a list's tail chain is walked in a loop. If `gray`
cannot grow, `mark` traces the header on the spot instead, so a cycle
never fails; only under memory exhaustion does marking recurse. `gray`
is freed at the end of every cycle.

---

### 5. Per-kind trace contract

Each heap kind's module exports `trace(h, visitor)` (CHAMP, which hosts
two kinds, exports `traceMap` and `traceSet`). The visitor is
duck-typed: `markValue`, `mark`, `markInternal`, which `gc.Collector`
provides. The rules:

1. **Do not mark `h`**: the collector marked it before dispatching.
2. **Do not walk `h.meta`**: the collector does (§6).
3. **Mark every Value the block references** with `visitor.markValue`.
4. **Walk interior nodes with `visitor.markInternal`**, and walk a
   node's payload only when the call returns true. Interior nodes are
   ordinary blocks for the sweep; "internal" only means they are
   reached through their owner's trace, not through the kind switch.
5. **A leaf kind's trace does nothing**, and is still exported.

The dispatch in `Collector.trace`:

| Kind | Trace | Walks |
|---|---|---|
| `string`, `bignum` | `string.trace`, `bignum.trace` | nothing (bytes, limbs) |
| `list` | `list.trace` | subkind 0 (cons): every head, and the tail chain in a loop (cells through `markInternal`, a cell's meta through `mark`); subkind 1 (empty): nothing; subkind 2 (vector view): its vector, through `markValue`, also when the view ends a cons chain |
| `persistent_vector` | `vector.trace` | the tail node and the trie, interior and leaf nodes through `markInternal` |
| `persistent_map`, `persistent_set` | `champ.traceMap`, `champ.traceSet` | the array-form entries, or the CHAMP trie with interior and collision nodes through `markInternal` |
| `typed_vector` | `typed_vector.trace` | nothing (unboxed elements) |
| `transient` | `transient.trace` | the wrapped collection (`docs/TRANSIENT.md` §10) |
| `durable_ref` | `db.trace` | nothing: store id, tree and key are inline bytes, and the advisory connection pointer is not a heap block (`docs/DB.md` §7.3) |
| `atom` | `atom.trace` | the contained value (`docs/ATOM.md` §7) |
| `record` | `record.trace` | the field map |
| `protocol`, `protocol_fn` | `protocol.trace` | nothing |
| `nextomic_conn`, `nextomic_db` | none | nothing: a VM-owned pointer plus inline text and numbers |
| `nextomic_entity` | `nextomic_handle.traceEntity` | the db-value box and the map of the entity's last full read |
| `function` | `Host.trace` (`VM.gcTrace`) | every upvalue cell (cells are blocks of their own kind, marked through `mark`), then the routine's heap constants, recursively through nested routines (`docs/VM.md` §6) |
| `cell_internal` | `Host.trace` (`VM.gcTrace`) | the cell's value |
| `byte_vector`, `error_`, `meta_symbol` | panic | reserved, never allocated |
| `var_` | panic | not a block: its payload is an arena `*Var` |

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
    draining = true
    mark each root; host.roots(...)     // push on gray
    while gray.pop() |h|: trace(h)      // the transitive closure
    draining = false; free gray
    freed = heap.sweepUnmarked()        // frees unmarked, unpinned blocks;
                                        // clears the mark on survivors
    heap.resetAllocationCounter()
    return freed
```

The collector keeps no state between cycles: each starts and ends with
every mark bit clear.

**Trigger.** `Heap.alloc` counts the bytes it hands out in
`allocated_since_collect`, and `collect` resets the counter. The VM
owns the policy (`VM.gcDue`): a cycle is due once the counter reaches
`gc_next_at`, which each cycle sets to the larger of `gc_threshold`
and `gc_growth_percent` percent of `Heap.live_bytes` after the sweep,
so a large live set is not re-marked every few kilobytes. Every VM
starts with `GcPolicy.default` (16 MiB, 100 %). With `NEXIS_GC_STRESS`
set in the environment every VM starts with `GcPolicy.stress` (4 KiB,
0 %): a cycle becomes due every few kilobytes, which is how the suite
proves the rooting rules. A test can set the three fields on its VM to
the same effect. A VM with `gc_enabled = false` or a borrowed heap is
never due.

**Safe point.** The VM tests `gcDue` in one place: before fetching an
instruction in its one run loop (`VM.loop`, which `run`, `callValue`
and `runRoutine` drive), at a loop's first fetch and at every fetch
after an instruction of a group that can allocate (`math`, `call`,
`closure`, `coll`, `ctrl`); after `mov`, `cmp`, `jump` or `var` the
counter cannot have moved. Between two instructions every live value
is in one of the roots §3 lists, so a cycle there frees nothing live.
`Heap.alloc` never collects: the compiler, a native and one instruction
(a rest list, a closure and its cells) allocate as many blocks as they
like with no rooting, and what one instruction allocates is in a slot
before the next fetch. A cycle therefore runs inside a native only
through a call back into the VM, which is what the rooting rule
(§11.5) covers. `VM.collectGarbage` runs one cycle on demand from a
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
- **Finalizers.** An object that owns an OS resource (an emdb
  connection, a transaction) is closed explicitly at the db layer.
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
atoms, pins, idempotence, metadata). `test/prop/gc.zig` G1–G6b drive
randomized graphs against a reachability model, a half-million-cell
list (G3b) and a 300,000-level chain of vectors, maps, atoms and meta
maps (G3c) through a cycle, pins (G4), repeated cycles without leaks
(G5), and programs that allocate on every step of a loop on a VM under
`GcPolicy.stress` (G6, G6b). `test/prop/heap.zig` H2, H3 and H6 test
the sweep primitive with hand-set marks, and `test/prop/transient.zig`
T4 and T4b collect with a transient as the only root. Under the
runtime, the `gc:` tests of `test/integration/eval_pipeline.zig` run
every callback-taking native of §11.5 with allocating callbacks on a
stressed VM, and `test/nextomic/gc.nx` does the same through `bin/nexis`
for query predicates, function bindings and custom aggregates.
`NEXIS_GC_STRESS=1 zig build test` runs the whole suite with every VM
under the stress policy.

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
   (its `[old new]` vector is built after the callback, with no safe
   point in between) and every native that never calls back in.
2. **Only the next callback's argument**: nothing to do, since
   `callValue` roots it for the call. `reduce`, `reduce-kv`, `swap!`,
   `alter-meta!`, `db/alter!` and `db/reduce-tree` (its decoded value
   is the call's argument and is not kept), `some` and `every?`.
3. **Callback results kept across further callbacks**: a
   `VM.rootScope()` pushes each one, and its deferred `release` drops
   them on every exit path, a `ControlTransferred` unwind included.
   `mapInto` (`map`, `mapv`, `mapcat`), `indexedMap` (`map-indexed`,
   `keep-indexed`), `reductions`, `repeatInto` (`repeatedly`,
   `iterate`), `keyExtremum` (`max-key`, `min-key`: the best key so
   far), `sortImpl` when a key fn is given; the `nextomic/q` hook for
   every user-function result and every heap value the query pipeline
   builds (a tuple or full-text result bound as one value, an
   aggregate's vector or set); and the Nextomic transaction-function
   hook (`transact`, `with`) for the db-value each call receives and
   every tx-data a function returns, for the transaction's life.
4. **Values a native builds itself and keeps across callbacks**: no
   argument reaches them. The iterator over a map, a record or an
   entity builds each `[k v]` entry, and the one over a typed vector
   boxes each element. `sieveInto` (`filter`, `remove`, `keep`,
   `filterv`), `whileSplit` (`take-while`, `drop-while`) and
   `reductions` keep what the iterator yields and walk with
   `rootedSeqIter`, which pushes each built value on the native's
   root scope; `sortImpl` (`sort`, `sort-by`) collects the elements and
   pushes them all (`pushAll`) before any key fn or comparator runs.
   A native that only passes a built value to the next call (`map`,
   `some`, `every?`, `reduce` over a map) is class 2 for it.

A new native that calls back into the VM states its class next to its
`callValue`.

**Routine constant pools.** The heap constants of a routine (string,
bignum and constant-collection literals, allocated on the VM's heap)
are rooted through every frame running the routine and every closure
over it, recursively through the routines nested in its pool (§3), so
a literal lives as long as any code that can load it and no longer.
