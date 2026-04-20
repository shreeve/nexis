## POOL.md — size-class pool allocator (Phase 1 performance lift)

**Status**: Phase 1 deliverable. Authoritative contract for
`src/pool.zig`. Derivative from `docs/PERF.md` §5.12 / §6 #1
(size-class pool is the highest-leverage available optimization
before the Phase 2 compiler lands), `docs/HEAP.md` (the consumer
of this allocator), and peer-AI turn 26 design review.

This commit replaces `std.heap.page_allocator` with a fast
size-class pool as the default backing allocator for `Heap`.
Projected impact per PERF.md §4.3: **map assoc at N=4096 drops
from ~200 ns/op to ~60 ns/op (~3.3× lift)**; proportional wins on
every alloc-heavy benchmark. Measured A/B vs
`bench/baseline.json` from commit `7e5bb1a`.

---

### 1. Scope

**In (v1):**
- `PoolAllocator` — single-threaded, bump-pointer + free-list
  allocator with 16 size classes.
- `std.mem.Allocator` vtable adapter (`pool.allocator()`).
- Size-class lookup table (comptime-generated, 256 entries).
- Slab management (grow 16 KB → 256 KB, then stay).
- Free-list pop/push per size class.
- Delegation to backing allocator for:
  - allocations > 4096 bytes,
  - alignment > 16 bytes.
- `resize` / `remap` vtable semantics (§6).
- Inline unit tests.
- `bench/main.zig` gets `--allocator {pool|page}` flag for A/B.
- Bench suite numbers recorded to `bench/baseline-pool.json`.
- PERF.md §3 scorecard updated with measured pool numbers.

**Out (explicitly deferred):**
- Empty-slab reclamation to backing. Slabs are retained until
  `pool.deinit()`. See §7 for framing.
- Multi-threaded allocation. nexis is single-isolate per
  PLAN §16.1; no locking needed.
- Cache-line-aware placement / per-CPU pools. Phase 7+.
- Huge-page slab backing (`MADV_HUGEPAGE`). Phase 7+.
- Per-kind specialization (e.g., a dedicated pool for map
  nodes with a hot path skipping the class lookup). Phase 6.
- Memory-pressure heuristics / slab trimming. Phase 7+.

---

### 2. Size classes

Sixteen classes, roughly 1.4–1.6× spacing with fine granularity
in the small range where nexis lives:

| Index | Size (bytes) | Typical use |
|---:|---:|---|
| 0 | 16 | minimum allocation |
| 1 | 32 | tiny headers, transient wrapper bodies |
| 2 | 48 | list cons (header + one body Value) |
| 3 | 64 | small CHAMP nodes, 2-entry array-maps |
| 4 | 96 | 4-entry array-maps, small strings |
| 5 | 128 | 6-entry array-maps, medium strings |
| 6 | 192 | 8-entry array-maps, CHAMP root headers |
| 7 | 256 | small CHAMP interior nodes |
| 8 | 384 | medium CHAMP nodes |
| 9 | 512 | large CHAMP nodes, vector branches |
| 10 | 768 | full vector tail (32 × 16B) + header |
| 11 | 1024 | full 32-way vector branch + header |
| 12 | 1536 | medium bignums, long strings |
| 13 | 2048 | large CHAMP nodes with collision subtrees |
| 14 | 3072 | large bignums |
| 15 | 4096 | ceiling before passthrough |

All class sizes are multiples of 16 so every carved block is
naturally 16-byte aligned. A precomputed lookup table
(comptime-generated; see §3) maps a requested size to its class
index in a single cache-line read.

Allocations strictly greater than 4096 bytes, or with alignment
> 16 bytes, **delegate to the backing allocator**. These paths are
rare in v1 (long strings, huge bignums, cache-line-aligned special
cases) and the overhead of passthrough is not worth optimizing.

---

### 3. Size-to-class lookup

Request size `s` maps to class index via:

```
idx = (s + 15) >> 4      // round up to the next 16-byte boundary, 1-based
class_idx = LOOKUP_TABLE[idx - 1]
```

`LOOKUP_TABLE` is a 256-entry `[256]u8` array, comptime-generated
so class sizes live in one place. For `s > 4096` the lookup is
bypassed and the request goes straight to backing (see §4.5).

Cost: one table load + small arithmetic = **~2 ns on L1-hot**.

---

### 4. Layout

#### 4.1 Pool

```zig
pub const PoolAllocator = struct {
    backing: std.mem.Allocator,
    classes: [NUM_CLASSES]SizeClass,
};
```

#### 4.2 Size class

```zig
const SizeClass = struct {
    block_size: usize,
    free_list: ?*FreeNode = null,
    /// Bump pointer into the current slab for carving new blocks.
    current: [*]u8 = undefined,
    /// Bytes remaining in the current slab (0 initially; triggers
    /// slab allocation on first use).
    remaining: usize = 0,
    /// All slabs this class has allocated from backing; retained
    /// for deinit.
    slabs: std.ArrayListUnmanaged([]u8) = .empty,
    /// Adaptive slab growth: start 16 KB, double until 256 KB,
    /// then stay. Tracks the size of the NEXT slab to allocate.
    next_slab_size: usize = 16 * 1024,
};
```

#### 4.3 Free node (carved into freed blocks)

```zig
const FreeNode = struct {
    next: ?*FreeNode,
};
```

Each freed block is reinterpreted as a `FreeNode` in-place. The
block's first 8 bytes hold the `next` pointer; the remainder is
undefined. The free list is LIFO — freshly freed blocks return
first, maximizing L1 re-hits.

#### 4.4 Slab

A slab is a contiguous chunk of backing memory carved into
equal-sized blocks for one size class. Slabs are allocated with
**16-byte alignment** (the minimum needed; all class sizes are
multiples of 16, so carved blocks remain aligned).

Slab growth: **16 KB → 32 KB → 64 KB → … → 256 KB, then cap**.
Amortizes allocation cost while bounding per-slab waste.

#### 4.5 Large / high-alignment passthrough

Requests with `size > 4096` OR `alignment > 16` bypass the pool
entirely:

- **Alloc**: forward to `backing.rawAlloc(len, alignment, ret_addr)`.
- **Free**: forward to `backing.rawFree(buf, alignment, ret_addr)`.
- **Resize/remap**: forward to backing.

Backing allocator `free` receives the exact original slice, so it
can tell its own size from `buf.len` just as we do.

---

### 5. Alloc / free paths

#### 5.1 Alloc (fast path)

```
1. If size > 4096 OR alignment > 16:     → backing.rawAlloc
2. class = LOOKUP_TABLE[(size+15)/16 - 1]
3. c = &classes[class]
4. If c.free_list != null:
     block = c.free_list
     c.free_list = block.next
     return block
5. If c.remaining >= c.block_size:
     block = c.current
     c.current += c.block_size
     c.remaining -= c.block_size
     return block
6. Allocate a new slab from backing (§5.3), carve first block, return.
```

Happy path (free list hit): **~3 ns** (1 load + 1 store).
Bump path (slab has room): **~4 ns** (2 loads + 2 stores).

#### 5.2 Free (fast path)

```
1. If size > 4096 OR alignment > 16:     → backing.rawFree
2. class = LOOKUP_TABLE[(size+15)/16 - 1]
3. c = &classes[class]
4. node = (FreeNode *)block
   node.next = c.free_list
   c.free_list = node
```

Cost: **~2 ns** (1 load + 2 stores).

#### 5.3 Slab grow (cold path)

```
1. size = c.next_slab_size
2. slab = backing.alignedAlloc(u8, 16, size)
3. c.slabs.append(slab)
4. c.current = slab.ptr
5. c.remaining = size
6. c.next_slab_size = min(c.next_slab_size * 2, 256 * 1024)
```

Happens once per ~N allocations of this class (amortized).
Backing's cost is ~1 syscall (~1 μs) amortized across thousands
of fast-path allocs.

---

### 6. Allocator vtable — `resize` / `remap`

Peer-AI turn 26 flagged these as load-bearing for correctness.

#### 6.1 Resize

`vtable.resize(ctx, buf, alignment, new_len, ret_addr) bool`
returns true if the caller can treat the buffer as having the new
length without moving.

Pool semantics:

- If `buf.len > 4096` OR `alignment > 16`: forward to
  `backing.resize`. Let the backing handle its own large-block
  resizing.
- If the **new_len fits in the same class** as the old buf.len
  (same `class_idx`): return **true** (the block already has
  capacity; no move required).
- Otherwise: return **false** (the caller must alloc+copy+free).

This is a safe, conservative implementation: we never lie about
capacity, and shrinking within a class is always allowed.

#### 6.2 Remap

`vtable.remap(ctx, buf, alignment, new_len, ret_addr) ?[*]u8`
returns the same-or-new pointer for a resized allocation.

Pool semantics:

- If `buf.len > 4096` OR `alignment > 16`: forward to
  `backing.remap`.
- Same-class: return `buf.ptr` (no-op move; valid because class
  size is ≥ new_len).
- Different class: return `null`, signaling the caller to
  alloc+copy+free.

#### 6.3 Free alignment parameter

Zig 0.16's `vtable.free(ctx, buf, alignment, ret_addr)` passes
the alignment used at allocation. Pool uses `alignment` to decide
pool-vs-backing path (same as alloc).

---

### 7. Lifecycle & ownership

The pool owns slabs; the Heap owns live blocks. Teardown order:

```zig
var pool = PoolAllocator.init(backing);
defer pool.deinit();        // (2) frees all slabs back to backing

var heap = Heap.init(pool.allocator());
defer heap.deinit();        // (1) returns live blocks to pool free lists
```

`Heap.deinit()` calls `backing.free(slice)` for every live block;
those calls go through `pool.allocator()` and end up as free-list
pushes. At that point no block is "live" but all slabs are still
resident.

`PoolAllocator.deinit()` walks every size class's `slabs`
ArrayList and frees each slab via `backing.free`. This is the
only point where memory returns to the OS / backing.

**Consequence** (peer-AI turn 26):

> Once `pool.deinit()` is called, every outstanding block from
> this pool is invalidated regardless of whether the Heap has
> freed it. In practice `heap.deinit()` runs first; if a caller
> reverses the order, debug builds will catch the resulting
> use-after-free via `std.testing.allocator` wrapping the
> backing.

---

### 8. Memory retention (v1 framing)

Per peer-AI turn 26: **not a leak; deliberate retained capacity.**

- Empty slabs are not returned to backing in v1.
- Memory footprint may stay above post-GC live size until
  `pool.deinit()`.
- For the default nexis workload — single-isolate, process-
  lifetime-bounded — this is acceptable and faster.
- For long-lived REPL sessions under sustained alloc/free churn,
  RSS growth is bounded by the high-water mark of live objects
  at any point in the process's lifetime. This is documented
  behavior, not a bug.

Deferred to a later commit: per-slab refcounts + empty-slab
release when count hits zero. Would allow bounded RSS even in
long-lived sessions.

---

### 9. Default allocator

Starting with this commit, **`PoolAllocator` is the default
backing for `Heap` in the bench suite and in any test that
doesn't explicitly request `std.heap.page_allocator`**. The
`bench/main.zig` driver adds `--allocator {pool|page}` so A/B
comparisons can run on demand.

Tests currently using `std.testing.allocator` (leak-detecting)
continue to use it directly — we don't route tests through the
pool because leak detection must see the individual `alloc`/`free`
calls. The pool is a middle-tier optimization; leak detection
happens at the backing (std.testing.allocator) layer underneath.

---

### 10. Invariants / safety

- All blocks handed out are ≥ requested size (from the class
  sizes table).
- All blocks are 16-byte aligned.
- No block is ever reassigned to a different class.
- Double-free of a pool block: **undefined behavior** in release.
  Debug builds may catch via the Heap's own double-free detection
  (kind byte poisoning on free) before the block reaches the
  pool. No separate pool-level double-free detection in v1.
- Cross-allocator free (block from pool passed to page, or vice
  versa): undefined behavior. Every `alloc` and `free` MUST go
  through the same allocator.
- Alignment > 16 requests always take the backing path, so the
  pool never misreports alignment.

---

### 11. Testing

Inline tests in `src/pool.zig`:

- `alloc/free round trip`: alloc a block, free it, alloc again —
  same address (free-list reuse).
- `size classification`: every boundary (16, 17, 48, 49, 4096,
  4097) maps to the expected class or passthrough.
- `large passthrough`: 5000-byte alloc → `backing` used →
  `pool.allocator().free(slice)` → `backing.free` called with
  original slice.
- `resize within class`: alloc 48, resize to 64 where same class
  exists — returns true, no move.
- `resize across class`: alloc 48, resize to 96 (different
  class) — returns false.
- `lifecycle`: allocate many blocks, call `pool.deinit()`, verify
  backing has zero outstanding allocations (via
  `std.testing.allocator`).
- `alignment > 16 passthrough`: alloc with `@"64"` alignment →
  backing used.

Regression: full `zig build test` runs with the pool as default.
Any pre-existing allocator-assumption bugs surface here.

Benchmark: `zig build bench` against the existing
`bench/baseline.json` on the same hardware.

---

### 12. Module graph

```
src/pool.zig
├── @import("std")                 // allocator vtable + ArrayListUnmanaged
```

Zero nexis imports. `pool.zig` is a standalone allocator that
plugs into `Heap.init` via `std.mem.Allocator`.

---

### 13. Amendment note

New doc in the same commit that lands `src/pool.zig`. No existing
doc is replaced. `docs/HEAP.md` gets a short cross-reference note.
`docs/PERF.md` §5.12 status tag moves from `acknowledged weakness`
to `measured (post-lift)` once the bench numbers are in the tree.
