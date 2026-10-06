## HEAP.md — Runtime Heap Allocator & Object Storage

The storage contract for every heap-kind `Value` (`docs/VALUE.md`
§2.2): the block layout, the `HeapHeader` and its bits, and the `Heap`
API in `src/heap.zig`. The module allocates, frees, enumerates and
sweeps; the collector that decides what to sweep is `src/gc.zig`
(`docs/GC.md`).

---

### 1. Physical layout

A block is a `HeapHeader` followed by its body, 16-byte aligned. Where
it lives depends on its size, header included (§2):

```
 slab block (≤ 8 KiB)                 large block (> 8 KiB)
 ┌──────────────────────────┐          ┌──────────────────────────┐
 │ HeapHeader     16 bytes  │ ← slot   │ Large prefix   32 bytes  │ next, length, body length
 ├──────────────────────────┤          ├──────────────────────────┤
 │ body      body_size bytes│          │ HeapHeader     16 bytes  │ ← *HeapHeader
 │ (slack to the class size)│          ├──────────────────────────┤
 └──────────────────────────┘          │ body      body_size bytes│
                                       └──────────────────────────┘
```

Every other module holds only a `*HeapHeader`; the slab and the large
prefix are private to `src/heap.zig`.

**HeapHeader** (`extern struct`, 16 bytes, 16-byte aligned):

| Offset | Field | Type | Contents |
|---|---|---|---|
| 0 | `kind` | `u16` | The block's `Kind` (VALUE.md §2), set by `alloc` |
| 2 | `mark` | `u8` | Collector bits (§4) |
| 3 | `flags` | `u8` | Object flags (§4) |
| 4 | `hash` | `u32` | Cached hash; 0 means not computed |
| 8 | `meta` | `?*HeapHeader` | The metadata map (a `persistent_map` block) or null |

Frozen invariants (a change is a PLAN amendment):

1. A returned `*HeapHeader` is 16-byte aligned and nonzero;
   `Heap.asHeapHeader` asserts both.
2. `@sizeOf(HeapHeader) == 16`, `@alignOf(HeapHeader) == 16`, with the
   field offsets above (asserted at compile time).
3. `hash == 0` means "not computed". A kind's hasher caches its `u32`
   hash only when it is nonzero (`cachedHash` / `setCachedHash`); a
   genuine zero is recomputed on each use, which is cheaper than a
   validity bit per object.
4. A fresh block is zero-filled except `kind`: `mark`, `flags`, `hash`
   are 0, `meta` is null and every body byte is 0, so a body of
   Values starts as `nil`s (VALUE.md §1.2). Only the allocator's own
   `mark` bit (§4) may be set.

Only a user-visible root carries metadata; the internal nodes of a map,
set or vector never do. Those nodes cache no hash either: their `hash`
holds, in its high 26 bits, the edit token of the transient that owns
them, or 0 (`docs/TRANSIENT.md` §4), and six bits of the collection's
own below it, a vector tail's claimed length (`docs/VECTOR.md` §2);
`editTokenOf`, `ownedBy`, `stampEdit`, `nodeAux` and `setNodeAux` read
and write the two.

---

### 2. Size classes, slabs and large blocks

**Classes.** A block of up to 8 KiB, header included, is a slot of a
size class: every multiple of 16 bytes up to 528 (a 32-value vector
leaf and its header), every multiple of 32 up to 1072 (a CHAMP node of
32 entries), then steps of about an eighth up to 8192, 67 classes in
all. A class's slot is the smallest that holds the block, so a block
up to 528 bytes wastes under 16 and a larger one about an eighth at
most. The block carries no per-block prefix: a cons cell or a vector
root is 48 bytes, a vector leaf 528.

**Slabs.** A class carves its slots from slabs of 256 KiB, each
aligned to its size, so a block's slab is its address with the low 18
bits cleared. A slab starts with its header (the next slab of the
class, the class, the slots carved and the slots live), then one
`u16` per slot holding the body size `alloc` was asked for (what
`bodyBytes` returns), then the slots. A slot's index is its offset
times a reciprocal of the class size. Slabs come from the operating
system (`std.heap.page_allocator`), not the backing allocator, so a
slab handed back leaves the resident set.

**Allocation.** `alloc` takes the class's free list's head, or else
carves the next never-used slot of the class's current slab, or else
starts a slab: an empty one the heap kept, or a new mapping. It zeroes
the block and records its body size. A free slot's kind is `0xDEAD`
and its `meta` links the free list.

**Sweep.** `sweepUnmarked` walks every class's slabs slot by slot: a
block not marked is freed (its kind poisoned), a
survivor's mark cleared. It rebuilds each class's free list from the
free slots of the slabs that still hold a block, lowest address first
within a slab, and takes every slab left empty off its class. It
keeps as many empty slabs as slabs still in use, and at least 64 (16
MiB, what the collector's default trigger lets a program allocate
between two cycles), for the next class that needs one, and hands the
rest back to the operating system: a steady workload refills the
slabs it emptied instead of mapping fresh ones every cycle, and a
program whose live set shrinks, a long REPL session among them, gives
its memory back. A heap that ends (`deinit`) leaves its slabs to a
pool the process keeps for the next heap, at most 64; heaps on several
threads share it through a try-lock and skip it when it is busy, so
none waits. A slab the pool takes is carved afresh.

**Large blocks.** A block over 8 KiB comes from the backing allocator
with a 32-byte prefix (the next large block, the allocation's length,
the body's length) and sets the allocator's `mark` bit (§4). The large
blocks form one list the sweep walks. The backing allocator is the
VM's (`VM.ensureHeap`): in `bin/nexis` a `SafeAllocator` (leak check,
no per-allocation stack trace) in a debug build and the process
allocator otherwise (`src/cli.zig`); `NEXIS_MAX_ALLOC` bounds a large
block, never a slab.

There are no finalizers: an object that owns an OS resource is closed
at the db layer.

---

### 3. Public API

| `Heap` member | Contract |
|---|---|
| `init(backing: Allocator) Heap` | O(1); nothing is allocated until the first block |
| `deinit()` | Frees every block still live |
| `alloc(kind, body_size) !*HeapHeader` | A zero-filled block (§1 invariant 4) with `kind` set. `kind` is a heap kind or `cell_internal` (an upvalue cell, `docs/VM.md` §6). Errors: `error.OutOfMemory` when no slab or large block can be had, `error.Overflow` when the block's size overflows `usize`. A zero `body_size` is legal. Never collects |
| `sweepUnmarked() usize` | Frees every block that is not marked, clears the mark on survivors, rebuilds the free lists and releases empty slabs (§2); returns the count freed. The sweep half of `gc.Collector.collect`; it enumerates no roots |
| `clearMarks()` | Clears every live block's `marked` bit: a cycle abandoned (`docs/GC.md` §4) |
| `live_bytes`, `peak_live_bytes`, `allocated_since_collect` | Bytes held by live blocks (a slab block counts its class's size, a large block its allocation), the largest that has been, and bytes allocated since `resetAllocationCounter()`, which the collector's trigger reads (`docs/GC.md` §7) |
| `slab_count`, `empty_slab_count` | Slabs held, and how many of them are empty and kept (§2) |
| `edit_clock` | The last edit token a transient on the heap took (`docs/TRANSIENT.md` §4) |
| `isBlockKind(kind) bool` | Whether a Value of `kind` carries a `*HeapHeader`: every heap kind except `native_fn`, `var_` and the three db handles, plus `cell_internal`. The collector marks only these |
| `bodyOf(Body, h) *Body`, `bodyBytes(h) []u8`, `bodySize(h)` | The body, typed (alignment ≤ 16, checked at compile time) or as bytes, as long as `alloc` or the last `resizeInPlace` made it |
| `bodyCapacity(h)`, `resizeInPlace(h, n) bool` | The longest body the block can take where it stands (its class's size less the header, or a large block's allocation), and a new body size up to it: bytes a longer body gains are zero; false, changing nothing, past the capacity. The transient operations grow and shrink the nodes they own through it (`docs/TRANSIENT.md` §1) |
| `valueFromHeader(kind, h) Value`, `asHeapHeader(v) *HeapHeader` | Pack a header into a Value with subkind 0, and back. A kind that sets a subkind or view offset packs its own tag (VALUE.md §3) |
| `liveCount() usize`, `forEachLive(visitor)` | O(n) enumeration: `clearMarks`, the retiring of transient edit tokens (`docs/TRANSIENT.md` §4), tests and diagnostics; the visitor may change header bits but must not allocate or sweep |

| `HeapHeader` method | Contract |
|---|---|
| `isMarked`, `setMarked`, `clearMarked` | The `marked` bit |
| `hasMeta`, `getMeta`, `setMeta` | `setMeta` keeps `flags.has_meta` equal to `meta != null`; `getMeta` asserts it in safe builds. Raw writes to `meta` are not made |
| `cachedHash() ?u32`, `setCachedHash(u32)` | Null when `hash == 0` (§1 invariant 3) |

---

### 4. Header bits

`mark`:

| Bit | Name | Meaning |
|---|---|---|
| 0 | `marked` | Reached in the current mark phase; cleared by the sweep |
| 1 | reserved | 0 |
| 2 | `large` | The allocator's: a large block (§2), set by `alloc`, never cleared |
| 3–7 | reserved | 0 |

`flags`:

| Bit | Name | Meaning |
|---|---|---|
| 0 | `has_meta` | `meta` is non-null |
| 1 | `ascii_known` | A string's: its bytes have been scanned for ASCII (`docs/STRING.md` §3) |
| 2 | `ascii` | A string's: every byte is ASCII; meaningful with `ascii_known` |
| 1–2 | shape | A `lazy_seq` block's: 0 lazy block, 1 cons, 2 chunked cons, 3 chunk (`docs/LAZY.md` §2), which the collector reads to tell the bodies apart |
| 3–7 | reserved | 0 |

---

### 5. Interaction with other modules

- **Value layer.** A heap Value's payload is `@intFromPtr(header)`;
  its tag carries kind, subkind and (for a list view) an offset
  (VALUE.md §1.1).
- **Hashing.** `dispatch.hashValue` routes each heap kind to its
  module's hasher, which reads and fills the header cache (§1
  invariant 3) and returns the base the dispatcher domain-mixes
  (SEMANTICS §3.3).
- **Collector.** `gc.Collector.collect` marks from the roots through
  each kind's `trace`, then calls `sweepUnmarked` and
  `resetAllocationCounter` (`docs/GC.md`). The VM runs a cycle only at
  its safe points (`docs/GC.md` §7), never inside `alloc`.
- **Interner.** Keyword and symbol names are interner allocations, not
  heap blocks (`docs/INTERN.md`).
- **Codec.** Builds values through the per-kind constructors; the heap
  is codec-unaware.

Per-kind body layouts are in each kind's doc.
