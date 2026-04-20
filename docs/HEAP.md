## HEAP.md — Runtime Heap Allocator & Object Storage (Phase 1)

**Status**: Phase 1 deliverable. Authoritative storage-layout contract for
every non-immediate `Value`. Derivative from `PLAN.md` §10, `docs/VALUE.md`
§4 and §5. Those documents win on conflict; nothing here may contradict
the 16-byte `HeapHeader` freeze pinned in VALUE.md.

This is the module that makes every heap kind possible. It is deliberately
tiny: allocation, free, object enumeration, and a minimal `sweepUnmarked`
that implements the sweep half of mark-sweep. Full GC (root enumeration,
precise tracing, explicit `collect(roots)` driver) ships in `src/gc.zig`
and is specified in `docs/GC.md`. This file is the allocator + sweep
bedrock the collector builds on; the kind dispatch + mark phase live
in `gc.zig`.

Risk-register entries #1 (three-reps boundary), #2 (GC bugs), and #3
(eq/hash inconsistency) are the three this module is most responsible for
keeping in check.

---

### 1. Physical layout

```
 ┌──────────────────────────────┐  ← returned Block*, 16-byte aligned
 │ Block prefix (16 bytes)       │
 │   next: ?*Block               │    (8 bytes)
 │   total_size: usize           │    (8 bytes — whole allocation)
 ├──────────────────────────────┤  ← *HeapHeader = &block.header
 │ HeapHeader (16 bytes)         │    matches VALUE.md §4 exactly:
 │   kind: u16                    │
 │   mark: u8                     │
 │   flags: u8                    │
 │   hash: u32                    │
 │   meta: ?*HeapHeader           │
 ├──────────────────────────────┤  ← body = header + 16, `body_size` bytes
 │ Body (body_size bytes)        │
 └──────────────────────────────┘
```

The `Block` struct is **private** to `src/heap.zig`. Users never see it;
they only ever hold `*HeapHeader`. The 16-byte prefix carries the
singly-linked list cursor and the allocation's total size (needed to
reconstruct the backing slice for `allocator.free`).

Pointer arithmetic:

- `block → header`: `&block.header`.
- `header → block`: `@fieldParentPtr("header", header_ptr)`.
- `header → body`: `@as([*]u8, @ptrCast(header)) + @sizeOf(HeapHeader)`.
- `block → allocation slice`: `@as([*]align(16) u8, @ptrCast(block))[0..block.total_size]`.

**Frozen invariants** (changing any of these requires a PLAN amendment
or a VALUE.md amendment, not just a HEAP.md edit):

1. Returned `*HeapHeader` is 16-byte aligned.
2. `HeapHeader` layout and field order match VALUE.md §4 exactly.
   `@sizeOf(HeapHeader) == 16`, `@alignOf(HeapHeader) == 16`.
3. `HeapHeader.hash == 0` means "not yet computed". Genuine computed-zero
   hashes recompute on next access (VALUE.md §4). The heap module provides
   `cachedHash` / `setCachedHash` helpers that encode this sentinel.
4. Fresh allocations are **zero-initialized** — both header (except `kind`
   which is set explicitly) and body. Downstream code can rely on
   `mark == 0`, `flags == 0`, `hash == 0` (uncomputed), `meta == null`,
   and all body bytes `0`. This is what makes "freshly-allocated memory
   is `nil`-valued" (VALUE.md §1.2) work for heap-stored `Value` arrays.

---

### 2. Allocation list

Every live block is on a single intrusive linked list rooted in
`Heap.live_head`. Alloc prepends (O(1)); free detaches (O(1) if you hold
the prev pointer, O(n) otherwise). For v1, `free` does a linear scan to
find the predecessor — acceptable at Phase 1 scale, and a later slab
allocator will replace the whole strategy.

The list is the canonical source of truth for "what's live." Sweep walks
it; tests enumerate it to assert leak counts.

**Why not an external registry?** Peer-AI review concluded (and I agreed):
a prefix block keeps allocation lifetime metadata physically adjacent to
the object, avoids a dual source of truth (allocator + registry), and
transitions cleanly to slab-based allocation later. See conversation
`nexis-phase-1` turn 4 for the full discussion.

---

### 3. Public API

```zig
pub const Heap = struct {
    pub fn init(gpa: std.mem.Allocator) Heap;
    pub fn deinit(self: *Heap) void;             // frees every remaining live block

    // Allocate a new heap object of the given kind with `body_size` body bytes.
    // Returns a 16-byte-aligned `*HeapHeader`. Header and body are zero-initialized
    // except `HeapHeader.kind` which is set to `kind`.
    pub fn alloc(self: *Heap, kind: value.Kind, body_size: usize) !*HeapHeader;

    // Free a single heap object. Removes it from the live list and releases
    // the backing allocation. Debug builds panic on double-free (the block's
    // kind field is poisoned at free time and checked on entry).
    pub fn free(self: *Heap, h: *HeapHeader) void;

    // Body accessors. Compile-time size/alignment check via `bodyOf`.
    pub fn bodyOf(comptime Body: type, h: *HeapHeader) *Body;
    pub fn bodyBytes(h: *HeapHeader) []u8;       // len = block.total_size - 32

    // Value ↔ *HeapHeader conversion. `valueFromHeader` sets Kind in the
    // tag word and packs the pointer into the payload. Per-kind constructors
    // (in string.zig, bignum.zig, etc.) wrap this to set subkind/aux/flags
    // appropriately for their kind.
    pub fn valueFromHeader(kind: value.Kind, h: *HeapHeader) value.Value;
    pub fn asHeapHeader(v: value.Value) *HeapHeader;

    // Enumeration. `liveCount` is O(n) over the live list (not cached);
    // it exists for tests and occasional diagnostics, not hot paths.
    pub fn liveCount(self: *const Heap) usize;
    pub fn forEachLive(self: *const Heap, visitor: anytype) void;

    // Minimal sweep — free every block whose `mark` bit is clear; on
    // survivors, clear the `mark` bit so the next cycle starts fresh.
    // Returns the number of blocks freed. Does NOT enumerate roots or
    // trace reachability (that's `src/gc.zig`'s job; see `docs/GC.md`).
    // Callers that want a full collection should use
    // `gc.Collector.collect(roots)` instead of driving this primitive
    // directly; `sweepUnmarked` is exposed only as the sweep half of
    // the mark-sweep pair.
    pub fn sweepUnmarked(self: *Heap) usize;
};

// HeapHeader instance helpers — the canonical way to mutate the bits.
// Raw field writes should be avoided outside of heap.zig itself.
pub fn HeapHeader.isMarked(self: *const HeapHeader) bool;
pub fn HeapHeader.setMarked(self: *HeapHeader) void;
pub fn HeapHeader.clearMarked(self: *HeapHeader) void;
pub fn HeapHeader.isPinned(self: *const HeapHeader) bool;
pub fn HeapHeader.setPinned(self: *HeapHeader) void;
pub fn HeapHeader.clearPinned(self: *HeapHeader) void;

pub fn HeapHeader.meta(self: *const HeapHeader) ?*HeapHeader;
pub fn HeapHeader.setMeta(self: *HeapHeader, m: ?*HeapHeader) void;

pub fn HeapHeader.cachedHash(self: *const HeapHeader) ?u32;  // null if == 0
pub fn HeapHeader.setCachedHash(self: *HeapHeader, h: u32) void;
```

**Error set.** `alloc` returns `error.OutOfMemory` from the backing
allocator. No other error cases in v1.

**Zero-body-size alloc** is legal. The returned `*HeapHeader` is valid;
`bodyBytes` returns a length-0 slice; `bodyOf(T, h)` for `@sizeOf(T) == 0`
is valid. (Rare, but pins the edge case.)

---

### 4. Bit-level conventions

`HeapHeader.mark` bit layout (VALUE.md §5):

| Bit | Name      | Meaning                                        |
|-----|-----------|------------------------------------------------|
| 0   | `marked`  | Visited in the current mark phase              |
| 1   | `pinned`  | Do not free; live root (open tx, durable ref…) |
| 2–7 | reserved  | Future tri-color / generational / remembered   |

`HeapHeader.flags` bit layout:

| Bit | Name         | Meaning                                              |
|-----|--------------|------------------------------------------------------|
| 0   | `has_meta`   | `meta` field is non-null                             |
| 1   | `interned`   | Object is content-deduplicated (for strings etc.)    |
| 2   | `immutable`  | Structural-share safe; collection invariant holder   |
| 3   | `zero_copy`  | Body points into mmap page / external buffer         |
| 4–7 | reserved     | —                                                    |

**`Value.tag.flags` is NOT `HeapHeader.flags`.** These are two different
flag bytes on two different data structures:

- `Value.tag.flags` describes the Value *reference* (hint bits used by the
  runtime's dispatcher — e.g. `hash_cached` can become a fast-path bit
  saying "don't dereference the header for the hash, it's the cached one
  embedded in `Value.aux`" if that optimization ever lands).
- `HeapHeader.flags` describes the heap object itself.

For v1, the authoritative hash cache is `HeapHeader.hash`. `Value.tag`
flag_hash_cached is reserved and not operationally used yet.

---

### 5. Interaction with other modules

- **Value layer (`src/value.zig`).** Value holds a u64 payload that, for
  heap kinds, is `@intFromPtr(header)`. `valueFromHeader` and
  `asHeapHeader` round-trip this. The Value layer's `hashValue`
  currently panics for heap kinds; when heap kinds come online it will
  load `HeapHeader.hash` (via `cachedHash`), recompute if null, write
  back via `setCachedHash`, and `mixKindDomain` as always.
- **Intern layer (`src/intern.zig`).** No direct interaction: interned
  name bytes are NOT heap-allocated (they live in interner-owned buffers,
  not on this heap). The `meta_symbol` heap kind (future) will point at
  a base symbol id from the interner plus a `*HeapHeader` metadata map
  allocated on this heap.
- **GC (`src/gc.zig`, see `docs/GC.md`).** Collector.collect(roots)
  drives a full cycle: mark each root via per-kind `trace` functions
  (each heap kind exports `pub fn trace(h, visitor)`), then call
  `sweepUnmarked`. The collector is explicit-only and non-reentrant in
  v1. `forEachLive` remains available for diagnostics. The trace seam
  on `Interner` is a no-op (intern-owned storage is not heap-managed).
- **Codec (future `src/codec.zig`).** Does not allocate directly on this
  heap; instead uses per-kind `decode` helpers that do. The heap module
  is codec-unaware.

---

### 6. What HEAP.md does not cover

- **Per-kind body layouts** (string body, CHAMP node, RRB trie node,
  bignum limbs). Those are each their own module's concern, documented
  alongside the module (`docs/STRING.md`, `docs/CHAMP.md`, `docs/VECTOR.md`,
  etc.).
- **Root enumeration and the real mark-sweep driver.** `docs/GC.md`
  and `src/gc.zig` own this. HEAP.md only owns the allocator + the
  sweep primitive + the mark-bit layout.
- **Allocation performance** (slab allocator, size-class bins, large-object
  direct-mmap). PLAN §10.4 describes the target v3+ shape; Phase 6 is
  where the optimization work lives (`PLAN §19.6` T2.6 generational,
  T1.4 slab pools).
- **Large-object threshold.** v1 uses a single strategy for every size.
  PLAN §10.4's >4 KiB direct-from-OS path is a Phase 6 performance item.
- **Finalization hooks.** Not in v1. Objects that own OS resources (open
  files, durable-ref pins) are tracked separately at the tx/db layer.
