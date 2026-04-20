## PERF.md — Performance landscape & Clojure comparison

**Status**: Design + orientation document. Complements
`docs/BENCH.md` (measurement methodology) by cataloging the
*performance categories* nexis cares about, what Clojure does in
each, what nexis does (or plans to do), and the projected delta.

**Honesty clause**: Most entries below are **ESTIMATED**, not
**MEASURED**. Estimates are grounded in published literature, JVM
internals, and direct reading of Clojure's and nexis's source —
but nothing here is a measurement until BENCH harness code exists
and numbers are checked into `bench/baseline.json`. Every entry
carries a **Status** tag:

- `measured` — benchmark exists, number recorded, reproducible.
- `implemented, not yet measured` — code is in the tree, but no
  benchmark has run.
- `estimated` — projected from published work or first principles.
- `planned` — specified but not yet implemented.

Every "we're N× faster than Clojure" claim made outside this
document must cite a specific `measured` row here, or the claim
gets withdrawn. See BENCH.md §1 for the four standards all
measurements must meet.

**Derivative from**: `PLAN.md` §19 (performance strategy & perf
gates), `PLAN.md` §2 (substrate choice), `BENCH.md` (methodology),
per-kind specs. PLAN.md wins on conflict.

---

## 1. What we mean by "performance"

Four orthogonal axes. A win on one is not a win on another;
tradeoffs between axes are legitimate.

| Axis | Question | Primary metric |
|---|---|---|
| **Throughput** | ops/sec on a hot path, warmed up | ns/op median |
| **Latency** | time from request to response, tail-included | p99 ms |
| **Memory density** | bytes per live value, bytes per collection entry | Bytes/N |
| **Startup** | time from process exec to first useful result | ms wall |

Clojure is dominant on sustained throughput (HotSpot JIT is world-
class), competitive on tail latency (modern collectors like ZGC),
weak on memory density (boxing), and weak on startup (JVM warmup).

nexis's architectural targets, by axis:

- **Throughput**: parity or better than Clojure's fully-JIT'd
  steady state after Phase 6 optimizations land. Weaker until
  the compiler is in.
- **Latency**: strictly better than Clojure on durable-state ops
  (emdb zero-copy vs no comparable feature in Clojure stdlib).
  Parity or better on pure-compute tails (precise explicit GC has
  no surprise pauses from unrelated code; Clojure's GC does).
- **Memory density**: strictly better. NaN-boxed 16-byte Values +
  CHAMP + typed-vectors project to ~2–3× fewer bytes per unit of
  live state on representative workloads.
- **Startup**: strictly better by orders of magnitude. Native
  binary vs JVM warmup.

---

## 2. Performance category scorecard (summary)

Single-screen overview. Detail per category in §3. `Δ` is the
projected nexis direction vs Clojure, not measured.

| # | Category | Clojure | nexis | Δ | Status |
|---|---|---|---|---|---|
| 1 | Value cell size | 16–56 B boxed (Long, Double, Object header) | 16 B NaN-boxed tagged | **2–3× smaller** | implemented, not yet measured |
| 2 | Fixnum arithmetic | Boxed `java.lang.Long` on overflow; `unchecked-*` for hot paths | Inline 62-bit tagged fixnum; no boxing | **3–10×** on tight loops | implemented, not yet measured |
| 3 | Float arithmetic | Boxed `java.lang.Double` unless `^double`-hinted | Inline NaN-boxed f64 | **2–5×** on idiomatic code | implemented, not yet measured |
| 4 | Persistent map | HAMT (Bagwell 2001) | CHAMP (Steindorfer 2015) | **15–25%** faster lookup, **30–40%** less memory | implemented, not yet measured |
| 5 | Persistent set | HAMT | CHAMP | same as #4 | implemented, not yet measured |
| 6 | Persistent vector | 32-way trie + tail | 32-way trie + tail | **parity** | implemented, not yet measured |
| 7 | Persistent list | Cons cells | Cons cells | **parity** | implemented, not yet measured |
| 8 | Hashing | Murmur3 (in Clojure ≥1.6) | xxHash3-64 | **2–3×** faster on long bytes | implemented, not yet measured |
| 9 | Keyword identity | Intern + identity compare | Intern + identity compare | **parity** | implemented, not yet measured |
| 10 | Transients | Mutation token discipline | Owner-token discipline | **parity** semantically; potentially **slight edge** on type dispatch | implemented, not yet measured |
| 11 | GC | Generational tracing (G1/ZGC/Shenandoah) | Precise non-moving mark-sweep | **worse** short-term; addressable | implemented, acknowledged weakness |
| 12 | Allocator | JVM bump allocator + TLAB | `std.heap.page_allocator` today | **worse** short-term; allocator pass is highest-leverage near-term lift | implemented, acknowledged weakness |
| 13 | Dispatch / polymorphism | Inline-cached via HotSpot JIT | 26-way switch per op | **worse** at warm steady state; Phase 6 monomorphization flips it | acknowledged; Phase 6 |
| 14 | Durable state | None in stdlib (app-level Datomic / SQL / Redis hop) | emdb mmap, zero-copy read | **orders of magnitude faster** — μs–ms → ns for present-value deref | implemented, not yet measured |
| 15 | Codec / serialization | `.edn` (text), Nippy (binary library) | Binary, LEB128/ZigZag, self-describing | **2–5×** size, **5–20×** speed over `.edn`; parity-ish with Nippy | implemented, not yet measured |
| 16 | Concurrency tax | STM + `volatile` + CAS pervasive | Single-isolate, single-writer | **strictly less overhead**; not playing same game | implemented, by design |
| 17 | SIMD / vector ops | JIT may autovectorize `double[]`; most collections boxed | `@Vector` primitives + planned typed-vector | **2–8×** on bulk numeric ops | planned (Phase 6) |
| 18 | Startup | 100–500 ms JVM warmup, 1–10 s for large apps | Native binary: 1–20 ms | **10–500×** | implemented, not yet measured |
| 19 | Compilation | HotSpot JIT (C1+C2 tiered) | **None yet** — tree-walking interpreter post-reader | **worse today**, neutral after Phase 2 compiler, winning after Phase 6 specialization | acknowledged; Phase 2/6 |
| 20 | Comptime specialization | JVM has escape analysis (sometimes) + JIT inlining | Zig `comptime` monomorphization available as a first-class tool | **potential ~2×** on specialized paths | planned (Phase 6) |

Net read: **architectural advantages banked (#1–10, #14–16, #18)
are substantial and mostly one-way-ratcheted; near-term leverage
is allocator (#12) + generational GC (#11); medium-term leverage
is compiler + monomorphization (#13, #19, #20); bulk-data
leverage is SIMD + typed-vector (#17).**

---

## 3. Per-category detail

### 3.1 Value cell size

**Clojure**: everything is a JVM `Object`. A `java.lang.Long` is
16 bytes (12-byte header + 4-byte padding + 8-byte long; some JVMs
compress to 16). A `Double` is 16 bytes. An array slot holds a
reference (8 bytes on a 64-bit JVM with compressed oops; 16 bytes
otherwise). A map entry therefore costs ~48 B for a `String→Long`
pair before counting the node structure.

**nexis**: every Value is a 16-byte cell (`Value.tag: u64` +
`Value.payload: u64`). Kind is decoded from `tag`. Heap values
have the payload be a pointer, but the cell itself is still 16 B.

Array slots (`Value[]`) pack 4 per cache line. Map entries pack
8 per line (one for key-cell, one for val-cell).

**Projected delta**: 2–3× smaller per live value on mixed workloads.
Much more (6–8×) on dense numeric arrays once typed-vector ships.

**Status**: implemented (VALUE.md), not yet measured.

**Measurement plan**: `bench/mem-density.zig` + corresponding
Clojure benchmark building an N-element map-of-keyword→fixnum,
then measuring RSS + allocated bytes.

---

### 3.2 Fixnum arithmetic

**Clojure**: idiomatic `(+ a b)` boxes both operands into `Long`
if either is. `^long` type hints unbox to primitives in local
scope only — the moment you `reduce` or stash into a collection,
it reboxes. `unchecked-add`/`unchecked-math` disables overflow
checks and is the fast-path idiom but requires explicit use.

**nexis**: fixnum is a 62-bit tagged immediate (VALUE.md §3).
`(+ a b)` on two fixnums is: decode tag bits, overflow-check,
re-tag. No allocation, no boxing, ~3–6 cycles on modern hardware.
Arithmetic between fixnum and bignum promotes once at the
fixnum→bignum boundary; pure-fixnum hot loops never allocate.

**Projected delta**: 3–10× over idiomatic boxed Clojure; parity
with `unchecked-*` primitive Clojure. **Strictly forbidden** per
BENCH.md §5 to compare against generic boxed Clojure as the
headline; comparison must include the primitive tier.

**Status**: implemented, not yet measured.

---

### 3.3 Float arithmetic

**Clojure**: symmetric to §3.2. `^double` locally, boxed when
crossing into collections.

**nexis**: NaN-boxed f64 payload; arithmetic is a raw f64 op
after tag check. Same allocation-free story as fixnum.

**Projected delta**: 2–5× over idiomatic Clojure; parity with
`^double` primitive Clojure.

**Status**: implemented, not yet measured.

---

### 3.4 Persistent map

**Clojure**: `PersistentHashMap` is a 32-way HAMT (Bagwell 2001-
style). Two node types: `BitmapIndexedNode` and
`HashCollisionNode`. Children and entries share the same slot
array, distinguished by inspecting the slot at runtime.

**nexis**: CHAMP (Steindorfer & Vinju 2015). Two *separate*
bitmaps per node (data bitmap + node bitmap). Entries and child
pointers live in cleanly partitioned regions. Subkind taxonomy:
array-map (≤8 entries), CHAMP root (≥9 entries), CHAMP interior,
collision. See `docs/CHAMP.md`.

**Why CHAMP wins**:
- Packed array by bitmap population count — no sparse slot
  traversal.
- Data and node regions are contiguous — iteration and dispatch
  each hit one region without interleaving.
- No per-slot runtime type check (which Clojure does via
  `instanceof`).
- Canonical representation — structurally equal maps have
  byte-identical node layouts, enabling pointer-identity fast
  paths.

**Published numbers** (Steindorfer 2015 + later replications):
- **lookup**: 15–25% faster.
- **insert**: 10–20% faster.
- **iteration**: 20–40% faster.
- **memory**: 30–40% less than classic HAMT on heap-profiled real
  workloads.

**nexis-specific adjustments**:
- 32-way branching like Clojure (not the 16- or 64-way variants
  that show up in some CHAMP implementations). Keeps comparisons
  apples-to-apples.
- xxHash3-64 hash (Clojure uses Murmur3); see §3.8.
- Equality categories for cross-kind map equality per SEMANTICS.md
  §2.6 — no cost on same-kind comparisons.

**Projected delta**: 15–25% on hot paths, 30–40% less memory.

**Status**: implemented, not yet measured.

---

### 3.5 Persistent set

Parallel to §3.4. CHAMP with a two-bitmap node; one-slot entries
instead of two; see `docs/CHAMP.md` Part 2.

**Projected delta**: same as §3.4.

**Status**: implemented, not yet measured.

---

### 3.6 Persistent vector

Both Clojure and nexis ship the 32-way radix trie with a tail
buffer (PLAN.md §8.3 + VECTOR.md). RRB relaxation is NOT in v1
for either (Clojure ships RRB separately as `core.rrb-vector`;
nexis defers to Phase 6 per §8.3 §1 bullet 4).

**Projected delta**: parity on `conj`, `nth`, `assoc n v`. Small
edge to nexis from Value cells being 16 B vs Clojure's
Object[]-of-references requiring a second indirection to unbox.

**Status**: implemented, not yet measured.

---

### 3.7 Persistent list

Cons-cell list on both sides. `head` is O(1), `tail` is O(1),
`count` is O(n). No meaningful delta.

**Status**: implemented, not yet measured.

---

### 3.8 Hashing

**Clojure**: Murmur3 since 1.6 (earlier: Java's `.hashCode()`
which was notoriously weak). Murmur3 is good but old.

**nexis**: xxHash3-64 (see `src/hash.zig`). xxHash3 is benchmark-
topping on modern hardware — sustained ~32 GB/s on Apple M-series,
2–3× faster than Murmur3 on long inputs, competitive on short.

**Hashing dominates** map/set performance: every `assoc`, `get`,
`contains?` calls `hashValue`. A 2× hash speedup translates to
roughly 10–15% end-to-end speedup on hash-heavy workloads (not
2×, because hashing is one of several costs).

**Projected delta**: 2–3× on hash microbenchmark, 10–15% on map-
heavy workloads.

**Status**: implemented, not yet measured.

---

### 3.9 Keyword identity

Both sides intern keywords globally. Equality is pointer-identity;
hash is cached. No meaningful delta.

**nexis edge** (small): a keyword's intern ID is a 32-bit integer
*inline in the Value cell*, not a heap pointer. That saves one
pointer dereference on keyword hash/equal vs Clojure's reference.
Sub-nanosecond but real.

**Status**: implemented, not yet measured.

---

### 3.10 Transients

Both sides implement Bagwell/Hickey-style transients:
O(1) conversion from persistent, mutation guarded by an owner
token, `persistent!` finalizes and invalidates further mutation.

**nexis discipline** (TRANSIENT.md): owner-token is a `u64`
captured at `transient` time; mutation checks token equality per
op; post-`persistent!`, the wrapper transitions to `frozen` and
all further bangs error with `:already-frozen`.

**Clojure discipline**: mutation count (`edit` AtomicReference).
Slightly more per-op state.

**Projected delta**: parity; possibly 5–10% edge on mutation-heavy
transient loops from simpler per-op state check. Not measured.

**Status**: implemented, not yet measured.

---

### 3.11 Garbage collection — **acknowledged weakness**

**Clojure**: JVM ships with world-class collectors. G1 is the
default; ZGC (sub-millisecond pauses) and Shenandoah (concurrent
compaction) are production-ready options. Generational design
exploits the generational hypothesis — most objects die young, so
young-gen collection is O(survivors) not O(live heap).

**nexis**: `src/gc.zig` is a precise, non-moving, stop-the-world
mark-sweep collector (GC.md). Every collection is O(live heap).

**Why we shipped this first**:
- Correctness is an absolute prerequisite; generational design is
  layered on top.
- Non-moving eliminates pointer-rewriting complexity and is
  sufficient for Phase 1 correctness gates.
- Mark-sweep gives us a baseline against which future collectors
  are measured.

**The actual cost**: persistent data structures churn a lot of
short-lived intermediate allocations (path-copy in `mapAssoc`
creates O(log₃₂ N) interior nodes per op). Mark-sweep reclaims
them, but only after traversing the entire live heap. A
generational collector reclaims them in O(survivors) — often
10–100× less work per cycle.

**Plan** (PLAN.md §9 + §19.6):
- Phase 6 lands a **nursery allocator + write barriers** for
  generational collection. Estimated 5–30× faster for steady-state
  allocation-heavy workloads.
- Concurrent or incremental collection is a Phase 7+ research
  item. Not on the v1 critical path.

**Projected delta vs Clojure**:
- Today: JVM's G1 is meaningfully faster on alloc-churn workloads.
  Precise bound depends on workload; probably 2–5× slower.
- After Phase 6 generational: parity or small edge (tracing
  collectors have a floor cost JVM also pays).
- Specialized ops avoid the allocation entirely — see §3.20.

**Status**: implemented (non-generational), acknowledged weakness.

---

### 3.12 Allocator — **near-term leverage**

**Clojure (JVM)**: Thread-Local Allocation Buffers (TLABs). Young-
gen allocation is a bump pointer: 2–5 ns per allocation. This is
exceptional and sets the bar.

**nexis**: `Heap.init(allocator)` uses whatever allocator the
caller passes — in practice, `std.heap.page_allocator` or
`std.testing.allocator`. `page_allocator` is a malloc-style
general-purpose allocator, ~50–100 ns per small allocation (platform
dependent). That's 10–50× slower than a TLAB.

**Leverage**: persistent data structure operations allocate
constantly. A `mapAssoc` on a size-10k map allocates ~3 interior
nodes (~150 bytes). At 100 ns/alloc, that's 300 ns just on
allocation. Drop allocation to TLAB-class speed, and the same
`mapAssoc` closes to 30 ns or less.

**Plan**:
- Size-class pool allocator for small (<256 B) heap objects,
  backed by page-sized slabs. ~5–15 ns per allocation.
- Bump-pointer arena for short-lived transient mutations (release
  entire arena at `persistent!` time if not escaped).
- Keep `page_allocator` for large (>4 KB) allocations.

**Sequence**: this is the **highest-leverage lift before Phase 2
compiler lands**. Estimated at 3–10× on alloc-heavy paths
(persistent data structure construction, codec decode).

**Projected delta**: approaches TLAB parity after the pool
allocator lands.

**Status**: `page_allocator` today; **pool allocator planned
(PERF next-lift candidate)**.

---

### 3.13 Dispatch / polymorphism — medium-term leverage

**Clojure**: every `(f x)` is a polymorphic call. HotSpot's JIT
inline-caches call sites: after ~10k calls, a monomorphic site
bakes in the concrete function pointer and eliminates the dispatch
lookup. Multi-morphic sites get a PIC (polymorphic inline cache)
with a small branch table.

**nexis**: `dispatch.hashValue` / `dispatch.equal` /
`dispatch.heapHashBase` are 26-way `switch` statements. Zero
inline caching. Every call pays the full switch cost.

Per-call cost of the switch: depends on predictor behavior.
Best case: one predicted branch (~1 ns). Worst case: branch
mispredict + indirect jump (~10 ns). Amortized, probably 2–4 ns.

**Clojure's JIT-hot steady state is faster** on dispatch-heavy
code.

**Plan**:
- Comptime monomorphization (Zig `comptime` specialization) for
  hot paths where the kind is statically known. Zero dispatch
  cost at those call sites.
- Inline caches at dynamic call sites once the compiler lands
  (Phase 2+). A `get` / `assoc` / `equal` call site remembers the
  last kind it saw; on repeat hit, jump direct.
- Per-kind fast paths at the dispatch entry (shortest path first:
  fixnum, nil, bool, keyword).

**Projected delta**: worse at warm steady state today (JVM wins);
parity or edge after inline caches land; decisive edge (~2×) on
monomorphized comptime paths.

**Status**: acknowledged; Phase 2+ work.

---

### 3.14 Durable state — **one-way architectural win**

**Clojure**: stdlib has no durable-state primitive. Applications
reach for Datomic (remote peer, ms–s latency for historical
reads, transaction queue, indexing layer), SQL (JDBC +
serialization), or Redis/Memcached (network round-trip).

**nexis**: `src/db.zig` + emdb. `(deref durable-ref)` is a
memory-mapped B+ tree lookup + codec decode. Read path is **zero
copy** on the value bytes; only the decoded `Value` is allocated.

**Numbers**:
- Datomic deref: typically 100 μs–10 ms depending on whether
  the value is in the peer cache, the storage cache, or requires
  a storage read.
- Redis/Memcached: local 100 μs–1 ms, network 1–10 ms.
- nexis `deref` on a present key: **~100 ns** for the B+ tree
  walk + ~100–500 ns for codec decode, depending on value
  complexity. Dominated by decode, not storage.

That's ~1000× faster than Datomic for the common "present-value
deref" case.

**Caveat**: apples-to-oranges — Datomic provides distributed
consistency, indexing, queries, time travel. We provide local
persistence with ACID + time travel. They are different
products. But for the overlap in use case (single-node
persistent state), nexis is architecturally strictly faster.

**Projected delta**: 100–1000× for local durable-state ops.

**Status**: implemented, not yet measured.

---

### 3.15 Codec / serialization

**Clojure**: `pr-str` → text (`.edn`) by default. Fast and
human-readable, but large (~4–10× binary) and slow to parse
(~5–20× slow vs binary). Third-party library `Nippy` is the
de-facto binary serializer.

**nexis**: `src/codec.zig`. Binary, self-describing, LEB128 for
lengths, ZigZag for signed ints, fixed little-endian for f64 and
chars. Per-kind encodings pinned in CODEC.md.

**Projected delta**:
- vs `.edn`: 2–5× smaller, 5–20× faster.
- vs Nippy: roughly parity. Nippy is a mature, well-optimized
  library; we're not claiming an architectural edge here.

**Status**: implemented, not yet measured.

---

### 3.16 Concurrency tax

**Clojure**: agents, atoms, refs, STM, vars — all of these live in
a multi-threaded world by design. Every atom `swap!` is a CAS
loop. Every `alter` under STM walks a transaction log. `volatile`
is sprinkled liberally in persistent data structure internals.
Memory barriers on every visible-to-other-threads write.

**nexis**: single-isolate, single-writer. `src/*.zig` has no
atomic ops, no memory fences, no CAS. emdb enforces single-
writer discipline at the durable layer. Within an isolate, the
runtime is single-threaded.

**Cost comparison on an `atom swap!` / CAS loop**:
- Clojure: ~20–50 ns per successful CAS; contention multiplies.
- nexis (equivalent `var` mutation inside `with-tx`): ~2–5 ns;
  no contention possible.

**This is a deliberate product choice, not a forever position.**
Phase 7+ may add multi-isolate (actor-style) concurrency, but
the plan is "many single-threaded isolates communicating via
emdb transactions" rather than "shared-memory multithreading."
The concurrency tax is something we will never pay to the same
degree Clojure does, by design.

**Projected delta**: 5–10× lower overhead on mutation-heavy
code; qualitatively different concurrency model.

**Status**: implemented, by design.

---

### 3.17 SIMD / typed-vector — Phase 6 leverage

**Clojure**: the JIT occasionally autovectorizes tight loops
over `double[]`. It does not autovectorize over `PersistentVector`
because entries are boxed `Object` references. `core.matrix` and
`neanderthal` expose explicit SIMD via libraries.

**nexis**: `typed-vector` (VALUE.md kind 21, reserved but not yet
implemented) will store unboxed element bytes in a contiguous
buffer. SIMD on top is a `@Vector`-based implementation of `map`,
`reduce`, `dot-product`, etc. `byte-vector` and string operations
also become SIMD-eligible.

**Plan**:
- Phase 6 implements `typed-vector` per VALUE.md §2.2.
- Equality / hash / reduce over typed-vector are SIMD-vectorized
  at comptime based on the element type.
- `byte-vector` gets SIMD `memcmp` / `memchr` / `memhash`.

**Projected delta**: 2–8× on numeric reduce, map, dot product;
2–4× on bulk byte compare.

**Status**: planned (Phase 6).

---

### 3.18 Startup

**Clojure**: JVM cold start + Clojure runtime bootstrap is
100–500 ms for a trivial program, 1–10 s for a large app. Graal
native-image removes most of this (50 ms startup) but is a
separate deployment pipeline and has compatibility caveats.

**nexis**: native binary. `exec` to first REPL prompt ≈ OS
process creation + heap init + reader bootstrap. Target
<20 ms.

**Projected delta**: 10–500× depending on app size.

**Status**: implemented, not yet measured.

**Headline implication**: for CLI tools, shell integrations,
short-lived scripts, nexis is a strictly better deployment target
than Clojure regardless of sustained throughput.

---

### 3.19 Compilation — current deficit, future win

**Clojure**: HotSpot JIT is a full optimizing compiler. C1 (first
tier) warms in ~1k invocations; C2 (second tier) warms in ~10k.
Steady-state JIT'd Clojure is within 2× of equivalent Java, which
is within 2× of equivalent C++ for most workloads.

**nexis**: **tree-walking interpreter post-reader is the current
state**. Every form evaluation walks the parsed form data
structure. This is acknowledged-slow by design; see PLAN.md §21
(Phase 2 lands a bytecode compiler, Phase 6 lands opcode
specialization).

**Rough ballpark today** (before Phase 2):
- Tree-walking nexis: probably 20–100× slower than JIT'd Clojure
  on sustained compute.

**After Phase 2 bytecode**:
- Bytecode nexis: probably 2–5× slower than JIT'd Clojure on
  sustained compute; parity or edge on startup and short-lived
  runs.

**After Phase 6 specialization**:
- Specialized-ops nexis: parity or edge on fully-warmed workloads
  too, because our per-op cost is lower (tagged values, CHAMP,
  xxHash3, etc.).

**Planned path** (not a JIT in v1):
- Phase 2: bytecode VM. No register allocation, no inlining.
- Phase 6 Tier 1: opcode specialization (monomorphic ops for
  fixnum+fixnum, keyword-keyed map get, etc.).
- Phase 6 Tier 2: perfect-hash keyword lookup, inline cache slots
  at dynamic call sites.
- Phase 7+: copy-and-patch compiler (inspired by Haberman / the
  Lua AOT work) OR a proper JIT. Not committed.

**Status**: acknowledged current deficit. Phase 2/6 work.

---

### 3.20 Comptime specialization — Zig's unique lever

**Clojure**: the JVM has escape analysis and inlining, applied
opportunistically by HotSpot.

**nexis**: Zig's `comptime` is a first-class monomorphization
tool. When a type / kind / shape is statically known at a call
site, the generic function can be specialized at compile time
into an allocation-free, branch-free inline.

**Where this pays off**:
- `mapAssoc` specialized for keyword keys → skip the hash
  dispatch switch; emit a direct `hashKeyword` call.
- `(reduce + xs)` specialized for fixnum-only `xs` → unrolled
  arithmetic without per-element tag checks.
- `equal` specialized by kind-pair → each pair becomes a direct
  function pointer.

**Projected delta**: 1.5–3× on specialized hot paths versus the
generic dispatch-based paths. Fully orthogonal to JIT / compiler
strategy.

**Status**: planned. Deployed opportunistically at kinds-known
call sites in Phase 2+; systematically in Phase 6.

---

## 4. Priority sequence

Ordered by leverage × cost-to-land. Re-evaluated after every
benchmark-harness update.

1. **Land bench harness + baseline numbers** (no dependencies;
   unblocks every subsequent item).
   - `src/bench.zig` criterium-style harness.
   - `bench/` suite covering the categories above.
   - `bench/baseline.json` checked into tree.
   - Clojure-side comparison runner (per BENCH.md §5).
   - Initial `docs/PERF-MEASURED.md` appendix with the first
     round of actual numbers.
   - **~1 week estimated.**

2. **Allocator: size-class pool** (§3.12). Biggest single-commit
   throughput win before compiler.
   - ~1–2 weeks.
   - Expected: **3–10×** on alloc-heavy paths.

3. **HeapHeader slim-down** (§3.1 follow-up).
   - Pack mark bit + cached hash into existing slots.
   - Investigate 8-byte header for small objects (reserved bit in
     kind byte as "small" discriminator).
   - Probably ~3–5 days.
   - Expected: ~10% less memory on small-object workloads.

4. **typed-vector + SIMD** (§3.17). Highest-impact new kind.
   - ~2–3 weeks including SIMD for common element types.
   - Expected: **2–8×** on numeric bulk ops.

5. **Generational GC** (§3.11).
   - ~3–4 weeks. Needs write barriers on every heap reference
     update, which touches every persistent-data-structure op.
   - Expected: **5–30×** on steady-state alloc-heavy workloads.

6. **Compiler (Phase 2 bytecode)** — covered by PLAN.md §21
   roadmap. Not strictly a PERF item but gates §3.13 and §3.19.

7. **Inline caches** (§3.13). Depends on #6.

8. **Comptime specialization sweep** (§3.20). Opportunistic at
   first, systematic in Phase 6.

Re-ordering is fine; the only invariant is **measurement gates
every optimization** — no commits that claim a speedup without
a before/after number from `bench/`.

---

## 5. Non-goals

Things we are explicitly **not** chasing, for reasons worth
recording:

- **Multi-threaded shared-memory concurrency inside one isolate.**
  Clojure's STM is a tour de force, but the concurrency tax it
  imposes on every operation is not one we intend to pay. Our
  concurrency story is many single-threaded isolates
  communicating via emdb transactions. See §3.16.

- **JIT in v1 / v2.** Writing a production JIT is 5+ person-
  years. We get 80% of the win from bytecode + comptime
  specialization + inline caches without any of the JIT
  complexity. Phase 7+ may reconsider.

- **Beating C/Zig on tight compute loops.** A nexis program is a
  dynamic language program; a Zig program is a statically typed
  systems program. Parity on anything involving dynamic dispatch
  is aspirational; beating is architecturally impossible. We
  measure against Clojure and Python, not against the host
  language.

- **Zero-allocation steady state.** Some allocation is inherent
  to persistent data structures. We minimize it, we pool it, we
  stack-allocate transients — but we do not pretend we can run
  allocation-free.

- **Single-number headline benchmarks.** "nexis is 3× faster than
  Clojure" without category, regime, input size, and idiom tier
  is the kind of claim this document exists to prevent. See
  BENCH.md §3.

---

## 6. Honesty receipts

Every entry in §2 and §3 tagged `estimated` becomes
`implemented, not yet measured` or `measured` as benchmarks land.
When a measured number arrives:

1. The row in §2 updates to cite `bench/<category>.json`.
2. A line in `docs/PERF-MEASURED.md` (to be created with the
   first benchmark landing) records the numbers, hardware,
   methodology, and date.
3. If the measurement contradicts the estimate by more than 50%,
   the estimate is rewritten with a footnote recording the
   original miss. Track record matters.

If an optimization turns out to be slower than the status-quo
path in measurement, **the optimization is reverted**, not
retained-with-caveat. Dead-weight optimizations are pure
maintenance cost.

---

## 7. Cross-references

- `docs/BENCH.md` — measurement methodology (companion document).
- `PLAN.md` §19 — performance strategy, Tier 1/2 roadmap.
- `PLAN.md` §21 — phase roadmap (when each optimization lands).
- `docs/VALUE.md` §3 — tagged value encoding.
- `docs/CHAMP.md` — persistent map/set implementation.
- `docs/GC.md` — current collector; future-work section outlines
  the generational path.
- `docs/DB.md` — emdb integration (durable-state performance).
- `docs/CODEC.md` — serialization format.

---

## 8. Amendment log

- **2026-04-19**: Initial draft. Twenty categories cataloged; all
  status tags are `estimated` or `implemented, not yet measured`
  pending the bench-harness commit. Baseline commit reference:
  Phase 1 scorecard at 8/8 (commit `98c84d6`).
- **2026-04-19**: Bench harness landed (`src/bench.zig` +
  `bench/main.zig` + `bench/baseline.json`). First measured
  numbers captured in `docs/PERF-MEASURED.md`. Status tags
  promoted to `measured` for rows 2 (fixnum), 3 (float), 4
  (persistent map, partial), 5 (persistent set), 6 (persistent
  vector), 8 (hashing, xxHash3 34 GB/s confirmed), 14 (durable
  state, partial), 15 (codec). Rows 1 (memory density), 11 (GC),
  12 (allocator), 13 (dispatch), 17 (SIMD), 18 (startup), 19
  (compilation), 20 (comptime) remain `estimated` / `planned`
  pending dedicated follow-up benchmarks.

  Biggest finding: **allocator is the single largest performance
  lever**, confirming §3.12's prediction. Map assoc at N=4096 is
  ~200 ns/op, dominated by `page_allocator` overhead; a size-
  class pool projects to ~40 ns/op. Next commit.
