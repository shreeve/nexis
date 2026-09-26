## HEAP.md — Runtime Heap Allocator & Object Storage

The storage contract for every heap-kind `Value` (`docs/VALUE.md`
§2.2): the block layout, the `HeapHeader` and its bits, and the `Heap`
API in `src/heap.zig`. The module allocates, frees, enumerates and
sweeps; the collector that decides what to sweep is `src/gc.zig`
(`docs/GC.md`).

---

### 1. Physical layout

```
 ┌───────────────────────────────┐  ← Block, 16-byte aligned (private)
 │ next: ?*Block        8 bytes   │
 │ total_size: usize    8 bytes   │  header + body + 16
 ├───────────────────────────────┤  ← *HeapHeader = &block.header
 │ HeapHeader          16 bytes   │
 ├───────────────────────────────┤  ← body = header + 16
 │ body           body_size bytes │
 └───────────────────────────────┘
```

`Block` is private to `src/heap.zig`; every other module holds only a
`*HeapHeader`. The prefix links the live list and records the size
`free` needs to hand the slice back to the allocator.

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
   Values starts as `nil`s (VALUE.md §1.2).

Only a user-visible root carries metadata; the internal nodes of a map,
set or vector never do.

---

### 2. Allocation list

Every live block is on one intrusive singly linked list at
`Heap.live_head`. `alloc` prepends in O(1); `free` unlinks by a linear
scan for the predecessor; `sweepUnmarked` unlinks as it walks. The list
is the one record of what is live: the sweep walks it and tests count
it.

Blocks come from the allocator the `Heap` is created with, the VM's
(`VM.ensureHeap`). In `bin/nexis` that is a `DebugAllocator` (leak
check, no per-allocation stack trace) in a Debug build and the
process allocator otherwise (`src/cli.zig`). There are no size
classes, slabs or large-object path, and no finalizers: an object that
owns an OS resource is closed at the db layer.

---

### 3. Public API

| `Heap` member | Contract |
|---|---|
| `init(backing: Allocator) Heap` | O(1); nothing is allocated until the first block |
| `deinit()` | Frees every block still live |
| `alloc(kind, body_size) !*HeapHeader` | A zero-filled block (§1 invariant 4) with `kind` set. `kind` is a heap kind or `cell_internal` (an upvalue cell, `docs/VM.md` §6). Errors: `error.OutOfMemory` from the backing allocator, `error.Overflow` when `body_size + 32` overflows `usize`. A zero `body_size` is legal. Never collects |
| `free(h)` | Unlinks and releases one block. Debug builds poison the kind (`0xDEAD`) and panic on a second free |
| `sweepUnmarked() usize` | Frees every block that is neither marked nor pinned, clears the mark on survivors, returns the count freed. The sweep half of `gc.Collector.collect`; it enumerates no roots |
| `live_bytes`, `peak_live_bytes`, `allocated_since_collect` | Bytes held by live blocks (prefix included), the largest that has been, and bytes allocated since `resetAllocationCounter()`, which the collector's trigger reads (`docs/GC.md` §7) |
| `isBlockKind(kind) bool` | Whether a Value of `kind` carries a `*HeapHeader`: every heap kind except `native_fn`, `var_` and the three db handles, plus `cell_internal`. The collector marks only these |
| `bodyOf(Body, h) *Body`, `bodyBytes(h) []u8` | The body, typed (alignment ≤ 16, checked at compile time) or as bytes (`total_size - 32` long) |
| `valueFromHeader(kind, h) Value`, `asHeapHeader(v) *HeapHeader` | Pack a header into a Value with subkind 0, and back. A kind that sets a subkind or view offset packs its own tag (VALUE.md §3) |
| `liveCount() usize`, `forEachLive(visitor)` | O(n) enumeration for tests and diagnostics; the visitor must not allocate or free |

| `HeapHeader` method | Contract |
|---|---|
| `isMarked`, `setMarked`, `clearMarked` | The `marked` bit |
| `isPinned`, `setPinned`, `clearPinned` | The `pinned` bit |
| `hasMeta`, `getMeta`, `setMeta` | `setMeta` keeps `flags.has_meta` equal to `meta != null`; `getMeta` asserts it in safe builds. Raw writes to `meta` are not made |
| `cachedHash() ?u32`, `setCachedHash(u32)` | Null when `hash == 0` (§1 invariant 3) |

---

### 4. Header bits

`mark`:

| Bit | Name | Meaning |
|---|---|---|
| 0 | `marked` | Reached in the current mark phase; cleared by the sweep |
| 1 | `pinned` | Survives every sweep, marked or not. No runtime module pins a block; tests do |
| 2–7 | reserved | 0 |

`flags`:

| Bit | Name | Meaning |
|---|---|---|
| 0 | `has_meta` | `meta` is non-null |
| 1–7 | reserved | 0 |

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
  its instruction-fetch safe point, never inside `alloc`.
- **Interner.** Keyword and symbol names are interner allocations, not
  heap blocks (`docs/INTERN.md`).
- **Codec.** Builds values through the per-kind constructors; the heap
  is codec-unaware.

Per-kind body layouts are in each kind's doc.
