## VM.md — Phase 2 runtime: bytecode format + execution contracts

**Status**: Phase 2 spec. Authoritative contract for the nexis
virtual machine that executes bytecode routines emitted by the
compiler described in `docs/COMPILER.md`. Derivative from
`PLAN.md` §12 (ISA physical format, operand kinds, opcode
groups) and `../em/docs/architecture/ISA.md` +
`../em/docs/architecture/RUNTIME.md` (template we adapt).

**Discipline**: this spec pins **semantic contracts**, not exact
Zig code. Dispatch-loop form, frame-stack storage strategy, and
handler signatures are implementation choices that emerge during
code contact. What each opcode DOES and what invariants the VM
upholds are frozen here. (Peer-AI turn 28.)

> **Freeze level** (peer-AI turn 30): the compiler/VM interface
> is frozen at the level of **semantic obligations** — operand
> meanings, frame/routine logical contents, calling + `recur`
> contracts, error taxonomy. It is NOT frozen at the level of
> concrete Zig struct layout. Implementation may choose any
> representation that preserves these obligations end-to-end.

---

### 1. Scope

**In (Phase 2):**
- Bytecode instruction encoding (64-bit fixed-width + 20-bit
  extension).
- SCVU hot-path / IJE context-local operand kinds per PLAN
  §12.2.
- 14 opcode groups per PLAN §12.3.
- Call frame model (logical; storage strategy flexible).
- Routine / closure / upvalue heap representations.
- Tail-call-threaded dispatch contract.
- Execution error taxonomy.
- GC interaction (v1 conservative-overapproximation fallback
  allowed).
- `recur` constant-space guarantee.
- Minimal try/catch/throw.
- Per-opcode unit tests + per-group integration tests.

**Out (Phase 3+):**
- Operand-specialized opcodes (`ADDVV` / `ADDVN` etc.) — Phase 6.
- Inline caches on polymorphic call sites — Phase 6.
- `tx:*` opcodes (durable-ref operations) — Phase 4.
- `simd:*` opcodes (typed-vector kernels) — Phase 6.
- Bytecode verification / security hardening — Phase 7+.
- AOT-linked multi-routine object files — Phase 5 tooling.
- Profile-guided tiered compilation — Phase 7+.
- Precise per-PC liveness maps (conservative fallback in v1; §9).

---

### 2. Design inheritance from em

em (`../em/src/`) is the Zig-level template for:

- Instruction encoding shape (64-bit + 20-bit extension).
- Operand-slot layout (`kind:4 | index:12` per operand).
- Tail-call-threaded dispatch (the `@call(.always_tail, ...)`
  trampoline-free loop).
- Routine object file format (`.nx.o`, adapted from em's `.o`).
- Disassembler architecture.

nexis **adapts** em for:

- **Operand kinds**: em has 8 MUMPS-flavored kinds (CVLSEPJG);
  nexis commits to 7 with a hot-path / context-local split
  (SCVU + IJE; PLAN §12.2).
- **Opcode groups**: nexis's 14 groups diverge from em's — we
  add `coll`, `transient`, `hash`, `tx`, drop MUMPS-specific
  groups.
- **Value model**: em values are dynamically-typed MUMPS
  strings-with-coercion; nexis values are 16-byte tagged
  (`docs/VALUE.md`) with strict equality categories (`docs/
  SEMANTICS.md`).
- **Closures**: em has none; nexis adds closure creation +
  upvalue representation.
- **GC**: em has none; nexis integrates with `src/gc.zig`.
- **Persistent collections**: em operates on plain arrays;
  nexis's `coll:*` group delegates to `src/coll/*.zig`.

This inheritance is the reason Phase 2 is tractable: we are not
designing a VM from scratch.

---

### 3. Physical instruction format

Per PLAN §12.1:

```
Primary instruction (64 bits):

  | kind(4) | group(6) | variant(6) | opA(16) | opB(16) | opC(16) |

Operand slot (16 bits each):

  | kind(4) | index(12) |

Extension instruction (64 bits, used when any operand index
exceeds 12 bits):

  | kind(4) | extA(20) | extB(20) | extC(20) |
```

**Invariants**:
- Primary + extension pair: when an instruction emits
  `kind = 1` (the "extension follows" kind), the NEXT
  instruction is interpreted as the extension. The pair is
  semantically atomic.
- **Group and variant** together select the handler: 64 groups
  × 64 variants = 4096 potential handlers; v1 uses ~150.
- **Operand kind** is 4 bits, permitting up to 16 kinds. v1
  uses 7 (SCVU + IJE); kinds 7–14 reserved; kind 15 is the
  `FFFF` sentinel for "missing operand."
- **Operand index** is 12 bits (0..4095). Exceeds → extension
  instruction. For v1, the vast majority of programs stay
  within 12-bit operand space.

Concrete Zig encoding (bit positions, struct layout) is an
**implementation detail**, not frozen by this spec. The
semantic contract above is frozen.

---

### 4. Operand kinds

Per PLAN §12.2. Brief recap.

#### 4.1 Hot-path kinds (SCVU) — 0..3

Dispatched together by any opcode that accepts "any of several
kinds" (math/cmp/mov/coll/call/closure/transient/hash):

| # | Code | Name | Source |
|---|---|---|---|
| 0 | `s` | slot | Frame-local slot (`frame.slots[index]`) |
| 1 | `c` | constant | Routine's constant pool (`routine.consts[index]`) |
| 2 | `v` | var | Namespace Var (`loadVar(index)`) |
| 3 | `u` | upvalue | Closure's captured cell (`frame.upvalues[index]`) |

Index 0 = slot because it's the hottest kind (predicts to
case-0 of the dispatch switch).

#### 4.2 Context-local kinds (IJE) — 4..6

Only appear in opcodes whose operand position fixes the kind.
Handlers don't dispatch on kind for these operands:

| # | Code | Name | Used by |
|---|---|---|---|
| 4 | `i` | intern | `mov:load-keyword`, `mov:load-symbol` |
| 5 | `j` | jump | `jump:*` opcodes |
| 6 | `e` | durable | `tx:*-lit` opcodes (Phase 4) |

#### 4.3 Reserved kinds — 7..14

Future slots for typed-vector references, FFI handles, protocol
method indices, etc.

#### 4.4 Sentinel — 15

`FFFF` = missing operand. Used when an opcode takes fewer than
three operands to fill unused slots.

#### 4.5 Raw-index / immediate operand convention (peer-AI turn 35)

Several opcodes carry a 12-bit operand whose `index` value is
**the data itself** rather than an index into a table — for
example, `call:call`'s `B = argc` and `closure:make`'s `B =
capture_descriptor_index`. The 64-bit instruction format does
not have a dedicated "immediate" operand kind, and adding one
would require amending PLAN §12.2.

**Convention**: for operand positions documented in §10 as
"immediate" or "raw index", the handler **ignores the
operand kind bits** and reads only the 12-bit `index`.
Assemblers MUST encode the kind as `.slot` for canonical
bytecode. Verifier/strict-mode VMs MAY reject non-`.slot`
encodings as `:invalid-operand-kind`; lenient VMs treat any
kind as valid for these operand positions.

This convention applies to:
- `call:call B=argc` and friends (`call:tailcall`,
  `call:apply`)
- `closure:make B=capture_descriptor_index`
- Any future opcode with documented argc / count / table-
  index operand semantics

The `imm` operand kind is reserved for a future PLAN
amendment if the encoding pressure justifies it; until then,
this convention is the v1 mechanism. The disassembler
renders these positions as `imm:N` in opcode-aware mode and
`s:N` in raw mode (matching the assembler's encoding).

---

### 5. Routine

A **routine** is the compiled code of one `fn*` (or the implicit
top-level form). Runtime representation is a heap value of kind
`function` (VALUE.md kind 22) in the final runtime model.

> **Staged realization** (peer-AI turn 31): early Phase 2 commits
> may materialize routines as plain Zig structs — not heap Values
> — until closure / function heap objects land. This is acceptable
> because routines are not user-visible in isolation; they become
> observable only through the closures that wrap them. The
> architectural destination (kind-22 heap Value) is preserved;
> implementation order puts it behind closures.

**Routine contents** (logical; Zig layout flexible). Updated
in turn 35 to split the previously-conflated "upvalue
descriptors" into two distinct concepts:

- **Code**: array of 64-bit instructions.
- **Constant pool** (`consts`): array of runtime `Value`s.
  May include `function-proto` entries — references to
  child routines that this routine's `closure:make`
  instructions construct closures for.
- **Var table** (`vars`): array of pointers to namespace Vars
  the code references.
- **Upvalue layout** (peer-AI turn 35): the count and order
  of upvalue cells the routine's body expects. When a
  closure carrying this routine is invoked, the callee
  frame's `upvalues` array has exactly this length, and U
  operands inside the body index into it. This is metadata
  ABOUT the routine, not metadata used BY the routine.
- **Capture-descriptor table** (peer-AI turn 35): a list of
  capture descriptors used by this routine's `closure:make`
  instructions to construct CHILD closures. Each
  `closure:make` references a descriptor by index (operand
  B). Each descriptor lists the source of every upvalue cell
  in the child closure being constructed (per §6: each
  source is `local_cell_slot(s)` or `inherited_upvalue(u)`).
  This is metadata USED BY the routine to construct other
  closures.
- **Entry points** per arity: offset where each supported
  arity starts executing. Multi-arity `fn*` is macro-lowered
  to separate `fn*` nodes pre-compiler, but the routine may
  still carry multiple entry points for variadic dispatch.
- **Source-span map**: table mapping instruction offsets to
  `SrcSpan` for error reporting + disassembly.
- **Metadata**: name, doc, `:arglists`, `:line`, etc. — a
  map attached for tooling.

**Routine identity**: two routines compiled from the same source
are NOT required to be `identical?`. Structural equality between
routines is undefined at the user-observable level; `(=)` on two
routines compares identity.

---

### 6. Closure

A **closure** is a routine bundled with its captured upvalue
cells. All user-level `fn*` values at runtime are closures,
even when no capture occurred (in that case, the upvalue array
is empty).

**Closure contents**:
- Routine reference.
- Upvalue cell array `[*]UpvalCell`.

**UpvalCell**:
- Heap object (counted toward GC).
- Carries exactly one `Value` slot, plus an `initialized: bool`
  flag (peer-AI turn 34) so that placeholder cells (used for
  `letfn*` mutual recursion) can be detected when read before
  init.
- Written once at binding time; subsequent rewrite is forbidden
  in v1 for ordinary lexical locals (PLAN §6.1's `set!` is
  scoped to dynamic-Var bindings only). Rewrite for mutable
  cells (`volatile!`, future) is a post-v1 extension.
- Multiple closures sharing the same upvalue cell observe each
  other's writes (when writes are eventually permitted).
- **CRITICAL** (peer-AI turn 34): **`recur` does NOT mutate
  captured loop-binding cells**. Each iteration of a captured
  loop binding gets a **fresh cell**. Otherwise closures
  created in earlier iterations would observe later iterations'
  values, which violates Clojure-equivalent immutable lexical
  binding semantics. See §6 "recur on captured loop bindings"
  below.

#### `closure:make A=prototype_const B=capture_desc C=result_slot`

(Peer-AI turn 34, **descriptor-based** rather than range-style.)

The compiler statically knows every closure's capture set —
both the count and the source of each upvalue. This makes
capture a side-table problem, not a runtime-staging problem.
Range-style staging (the call-ABI shape from §6 above) would
force extra `mov:move`s to materialize raw cell pointers
through slots, conflicting with the U-operand cell-deref
semantics. Descriptor-based encoding sidesteps that.

- `A` is a constant-pool index referencing the **child
  routine prototype** (constant pool kind `function-proto`).
- `B` is an index into the **current routine's
  capture-descriptor table**. Each descriptor names the
  source of every upvalue cell to be captured.
- `C` (slot) is the destination slot for the new closure.

**Capture descriptor shape** (logical):

```zig
const CaptureSource = union(enum) {
    // Read raw cell pointer from current frame's slot.
    // The slot must already hold an UpvalCell* (boxed via
    // closure:box-local or closure:new-cell).
    local_cell_slot: u16,
    // Copy raw cell pointer from current closure's
    // upvalues[index]. Used when an outer-enclosing capture
    // needs to be re-captured by an inner closure.
    inherited_upvalue: u16,
};

const CaptureDescriptor = struct {
    sources: []const CaptureSource,
};
```

**Execution**:
- Allocate a closure heap object of kind `function`
  (VALUE.md kind 22) with an `[N]UpvalCell*` array, where
  `N = descriptor.sources.len`.
- For each `source[i]`:
  - `local_cell_slot(s)`: read `slot[s]` as `UpvalCell*` and
    copy the pointer into `closure.upvalues[i]`. Trap as
    `:expected-cell` if `slot[s]` does not hold an
    `UpvalCell*`.
  - `inherited_upvalue(u)`: copy
    `current_frame.upvalues[u]` into `closure.upvalues[i]`.
    Trap as `:upvalue-out-of-range` if `u` exceeds the
    current closure's upvalue count.
- Store the new closure reference into `slot[C]`.

**Note on raw cell pointers vs cell contents**: this opcode
copies **raw cell pointers**, NOT cell contents. Multiple
closures capturing the same source cell share the same
underlying cell — that's how mutual closures see each
other's writes (when writes are permitted) and how `letfn*`
recursive bindings see each other after init.

#### `closure:box-local A=slot _ _`

(Peer-AI turn 34.) Wraps a non-captured local's value into a
fresh `UpvalCell` so that subsequent `closure:make` operations
can capture it.

- `A` (slot) currently holds a plain `Value v`.
- Effect: allocate a fresh `UpvalCell` with `value = v` and
  `initialized = true`. Replace `slot[A]` contents with the
  cell pointer.

The compiler emits this at binding time for every local that
capture analysis identified as captured by an enclosing
closure. After emission, future reads of the local in the
defining frame must use `closure:get-cell` (or any opcode
through which a U-operand resolves to cell contents).

**Errors**:
- `:invalid-cell-state` if `slot[A]` already holds an
  `UpvalCell*` (double-box). Indicates compiler bug; trap
  rather than no-op so corruption surfaces.

#### `closure:new-cell A=dst_slot _ _`

(Peer-AI turn 34, required for `letfn*`.) Allocates an
**uninitialized** `UpvalCell` and stores the cell pointer in
`slot[A]`. Used to create placeholder cells for mutually
recursive closures so that closures referring to each other
can be constructed before either has its final value.

- `A` (slot) is the destination for the new cell pointer.
- Effect: allocate `UpvalCell{ value: undefined, initialized:
  false }`. Store the pointer in `slot[A]`.

#### `closure:init-cell A=cell_slot B=value_operand _`

(Peer-AI turn 34.) Initializes an uninitialized cell with a
value. Used to fill in `letfn*` placeholder cells once their
final closure values exist.

- `A` (slot) holds an `UpvalCell*` whose `initialized = false`.
- `B` is any operand kind that `resolve()` accepts.
- Effect: write `resolve(B)` into the cell's value slot;
  flip `initialized = true`.

**Errors**:
- `:expected-cell` if `slot[A]` does not hold an
  `UpvalCell*`.
- `:invalid-cell-state` if the cell is already initialized.

#### `closure:get-cell A=dst_slot B=cell_slot _`

(Peer-AI turn 34, required for reading boxed locals in the
defining frame.) Reads the contents of an `UpvalCell` whose
pointer is in a frame slot. Necessary because slot operands
default to "the value in the slot" — they do NOT auto-deref
cells, since the same slot might also be used to hold an
already-stored `UpvalCell*` for descriptor-based capture.

- `A` (slot) is the destination.
- `B` (slot) holds an `UpvalCell*`.
- Effect: dereference the cell; write its value into
  `slot[A]`.

**Errors**:
- `:expected-cell` if `slot[B]` does not hold an
  `UpvalCell*`.
- `:uninitialized-cell` if the cell has `initialized =
  false`.

#### Reading captured upvalues from inside a closure body

Inside a closure body, captured upvalues are accessed via the
**U operand kind** (PLAN §12.2). `resolve(u:N)` returns
`current_frame.upvalues[N].value` — i.e., it deref's the cell.

This means **no dedicated `closure:read-upval` opcode is
needed**. Existing opcodes work directly:

```
mov:move  s0, u:0          ; s0 := upvalue 0's cell contents
math:add  s0, u:0, c:1     ; s0 := upvalue 0's value + 1
```

**Important distinction** (peer-AI turn 34): `U` is a
**cell-contents** operand, NOT a raw-cell operand. Closure
construction needs **raw cell pointers** and goes through the
descriptor mechanism (`local_cell_slot` /
`inherited_upvalue`) on `closure:make`. Do NOT conflate the
two — making `U` raw-pointer-on-some-paths and value-on-other-
paths is a semantic footgun.

**Writes to captured upvalues** are forbidden in v1 for
ordinary lexical locals (`set!` is scoped to `^:dynamic` Vars
per PLAN §6.1). The U-kind store path is reserved but not
implemented in v1; `store(u:N, ...)` returns
`:unsupported-write`. When dynamic-binding rebinding (Phase 3)
or mutable cells (post-v1) land, the reserved path becomes
implemented.

#### `recur` on captured loop bindings (CRITICAL)

(Peer-AI turn 34, semantic correctness.) When a `loop*`
binding is captured by a closure within the loop body, naive
implementation would mutate the captured cell on each
iteration. **This is wrong.**

```clojure
(loop [i 0 acc []]
  (if (< i 3)
    (recur (+ i 1) (conj acc (fn [] i)))
    acc))
;; Expected: closures capture 0, 1, 2 — NOT 3, 3, 3.
```

If `recur` mutated a single shared cell for `i`, the closures
created in earlier iterations would all observe the final
value `3`. This violates immutable lexical binding semantics.

**Correct lowering** for `recur` of captured loop bindings:
the recur-prelude allocates a **fresh cell** per iteration,
not mutates the existing one. Sketch:

```
; compute new value into a temp slot
math:add        s_new_i, s_i_value, c1   ; new_i := i + 1
; old slot[s_i_cell] held the previous iteration's cell
; create a fresh cell holding the new value
mov:move        s_tmp, s_new_i            ; stage value
closure:box-local s_tmp                    ; s_tmp := fresh cell
mov:move        s_i_cell, s_tmp            ; install new cell
jump:jmp        L_loop
```

For NON-captured loop bindings (the common case), `recur`
remains the simple `mov:move + jump:jmp` lowering from
COMPILER.md §5.6 — no cell allocation, no opcode-overhead per
iteration.

The analyzer is responsible for detecting which loop
bindings are captured (capture-analysis output) and emitting
the appropriate `recur` lowering: cell-fresh-per-iteration
for captured, slot-rewrite for non-captured.

**`recur` does NOT use the U-store path.** That path remains
reserved for the future dynamic-binding-rebinding /
mutable-cell features.

**Closure invocation — range-call ABI** (peer-AI turn 32,
modeled on Lua 5.x `CALL A B C`):

The compiler stages the closure plus its arguments in a
**contiguous call block** in the caller's slot space, then
emits a single `call:call` / `call:tailcall` / `call:apply`
referencing the block's base slot. This eliminates the
arg-list encoding problem (the 64-bit instruction has only
three 16-bit operands; arbitrary arg lists do not fit) and
enables a one-instruction call fast path.

#### `call:call A=call_base B=argc C=result_slot`

- `A` (slot) is the **call_base**: the slot containing the
  closure.
- `B` is the **argument count** (encoded as an immediate-style
  index — `B.kind` is `.slot` purely for encoding uniformity;
  the index value IS the argc, not a slot index).
- `C` (slot) is the **result slot**.

**Preconditions**:
- `slot[A]` is a closure (kind `function`, VALUE.md kind 22).
- `slot[A + 1 + i]` is argument `i`, for `i ∈ [0, argc)`.
- The block `[A .. A + argc]` is fully populated by the
  caller before this instruction executes.

**Semantics**:
- Validate `slot[A]` is callable; otherwise raise
  `:not-callable`.
- Validate `argc` against the closure's routine metadata;
  otherwise raise `:arity-mismatch`.
- Construct a callee frame whose slot 0 is sourced from
  caller `slot[A + 1]`, slot 1 from `slot[A + 2]`, and so on
  through `slot[A + argc]`.
- Point `callee.upvalues` at the closure's upvalue array.
- Dispatch into the callee's entry point.
- On callee `return v`: write `v` to caller `slot[C]` and
  resume caller at the next instruction.

**Compiler invariant — call-clobbered region**: caller values
that must be live across the call **must reside in slots
strictly below `A`**. Slots at and above `A` are
call-clobbered, because the callee's frame may window into
the backing stack starting at `A + 1` and extend through
`callee.routine.slot_count`. Storage strategies that do NOT
window (e.g., per-frame independent slot arrays) still
treat the region as clobbered, to preserve a single rule
the compiler can rely on.

#### `call:tailcall A=call_base B=argc C=ignored`

- Operands A, B as for `call:call`. C is unused (encoded as
  `.unused` sentinel).

**Preconditions** identical to `call:call`.

**Semantics**:
- Validate as for `call:call`.
- **Replace the current frame in place** with the callee
  frame: the callee's slot 0 receives `slot[A + 1]`, slot 1
  receives `slot[A + 2]`, etc., **copied/slid down** into
  `slot[0 .. argc)` of the (now-callee) frame, then
  `routine` and `pc` switch to the callee.
- The slide MAY require parallel-assignment semantics when
  the source range overlaps the destination; the v1
  implementation uses a small temporary buffer for `argc <=
  16`, falling back to a heap-allocated temp for larger
  arities. Compiler-emitted `recur` (which has the same
  parallel-assignment requirement) uses the same machinery.

**Why the slide is mandatory**: a tailcall MUST keep
backing-stack usage bounded across mutual tail-recursion
chains. If the implementation merely advanced `frame_base`
by `A + 1` on each tailcall, mutual recursion would leak
backing-stack memory upward without growing logical frame
depth — incorrect. The slide-into-place behavior preserves
the constant-space guarantee that PLAN §11.3 promises for
`recur` and that this opcode promises for general
tail-position calls.

(`recur` itself does NOT execute `call:tailcall` — see VM.md
§11. `recur` is a `mov:move` + `jump:jmp` lowering with no
call-op or arity revalidation. `call:tailcall` is for
explicit user-level tail-position calls to a different
function, when those become a Phase 3+ feature; the v1
compiler may emit `call:tailcall` at the codegen's
discretion when an opcode-emitted call is in tail position.)

#### `call:apply A=call_base B=argc C=result_slot`

Same encoding as `call:call`, but the LAST argument
(`slot[A + argc]`) is treated as a **sequence to splat** into
the callee's parameter positions starting at index `argc - 1`.
Used for `(apply f x y rest)`. Phase 3+ feature; deferred
beyond Phase 2 step #5. The opcode encoding is reserved here
for forward compatibility.

**Variadic rest-arg construction**:
- The closure's routine metadata carries `fixed_arity` and
  `is_variadic` flags.
- For variadic closures: when an incoming call delivers
  `argc > fixed_arity` arguments, the call/prologue
  machinery (NOT the caller's bytecode) constructs a list
  from `incoming_args[fixed_arity .. argc)` and writes it to
  callee `slot[fixed_arity]`. When `argc == fixed_arity`,
  the empty list is written to that slot.
- Range-call makes this clean because the overflow args are
  already contiguous in the source range — no gather step.

---

### 7. Call frame

A **frame** represents one invocation of a routine.

**Frame contents** (logical):

- **Routine pointer**.
- **PC** (bytecode offset into the routine's code).
- **Slots**: fixed-size array of `Value`s, size determined by
  the routine's slot count.
- **Upvalue array**: pointer to the closure's upvalue cells
  (shared with the closure; not owned by the frame).
- **Caller frame pointer** (for `return` to unwind).
- **Try-handler chain root**: for try/catch unwinding (see §12).

**Lifetime**:
- Created on `call:call`.
- Reused in place on `call:tailcall` (no unwind, no new frame
  allocated).
- Destroyed on `call:return`.

**Storage strategy** (peer-AI turn 28 + turn 32 refinement):
- v1 may use a contiguous growable stack, a slab chain, or
  segmented frames. The spec requires:
  - Frames are accessible by the VM in O(1).
  - Arbitrary depth is supported (bounded only by memory).
  - Stack overflow produces a recoverable error
    (`:stack-overflow`), not a crash.
  - The frame model **MUST support the §6 range-call ABI**:
    arg materialization in caller's slot block at `[A+1 ..
    A+argc]` followed by callee construction whose slot 0
    aliases or copies-from caller `slot[A+1]`. Per-frame
    independent slot arrays (the current `src/vm.zig`
    skeleton) are correct but copy on every call; a backing
    value-stack with frame-base pointers (em-style) avoids
    the copy on non-tail calls. v1 may ship either; the
    semantic contract is identical.

**Implementation note for the current skeleton** (peer-AI
turn 32): the existing `src/vm.zig` `Frame` carries `slots:
[]Value` owned per-frame. This is fine for the single-frame
runtime and for step #2 (math:add for `(+ 1 2)` with no
calls). When step #5 (functions + closures) lands, the
frame model evolves to a backing value-stack + frame-base
pointers so that `call:call` can window without copying.
The visible interface in this spec is unchanged either way.

---

### 8. Dispatch

Per PLAN §12.5. Conceptual shape:

```
given current instruction:
  group   = inst.group()
  variant = inst.variant()
  handler = handlers[group][variant]
  tail-call handler(vm)
```

**Contract** (not code):

- Dispatch is **tail-call threaded** in the final runtime model:
  each handler ends with a tail call to the central dispatch
  function, which in turn tail-calls the next handler. No stack
  growth from dispatch.
- **Staged realization** (peer-AI turn 31): early Phase 2 commits
  may implement dispatch as a structured two-level switch (per
  PLAN §12.5 fallback) while opcode semantics stabilize. The
  semantic contract above is independent of dispatch style; the
  tail-call-threaded upgrade lands when the opcode set is
  stable enough that the dispatch loop's shape stops churning.
- PC increment happens before handler entry (dispatch advances
  past the current instruction; handlers see the already-
  advanced PC when emitting jumps).
- `.always_tail` annotation is used where the Zig compiler
  supports it; fallback is a two-level switch (per PLAN §12.5).
- A single VM has exactly one dispatch function + one handler
  table; per-program customization happens via the routine's
  constant pool, not via the handlers themselves.

Exact Zig code — reused almost verbatim from em — is NOT part of
this spec.

---

### 9. GC interaction

v1 acceptable fallback (peer-AI turn 28): **all frame slots
treated as live roots** during collection. This overapproximates
but is always sound.

Future (precise liveness):
- Per-PC liveness map emitted by codegen.
- GC walks frame stack + uses the map to know which slots are
  actually live at the current PC.
- Dead slots are excluded from root enumeration; benefit is
  shorter live-set traversal during collection.

**Invariants** (v1):
- Closures, upvalue cells, routines, constant-pool entries
  (any heap-kind values), current-frame slots, caller-frame
  slots (all the way up the frame chain), try-handler chains,
  and currently-active Vars are all treated as live roots.
- The GC API (`src/gc.zig`) already accepts a caller-supplied
  root-enumeration callback. The VM implements this callback
  per the above.

---

### 10. Opcode groups (v1)

Per PLAN §12.3. Each group ships with its semantic contract
documented here. Variant numbers and semantic contracts are
authoritative in this document for every variant **reserved
in Phase 2** (peer-AI turn 35: implementation comments may
repeat them but are not authoritative). Variants reserved
beyond Phase 2 are listed but their semantic contract
crystallizes when their phase arrives.

| # | Group | Phase | Notes |
|---|---|---|---|
| 0 | `jump` | 2 | Branches (unconditional + conditional). Operand A is always J; operands B/C are hot-path. |
| 1 | `cmp` | 2 | Compare ops producing a bool into a slot. |
| 2 | `math` | 2 | Integer + float arithmetic. Fixnum fast path + bignum promotion. |
| 3 | `mov` | 2 | Data movement, load-const, load-true/false/nil, load-keyword/symbol (via I operands). |
| 4 | `call` | 2 | Function invocation (`call`, `tailcall`, `invoke-var`, `apply`, `return`). |
| 5 | `closure` | 2 | Closure creation + upvalue cell management. v1 variants: `make` (descriptor-based, §6), `box-local`, `new-cell`, `init-cell`, `get-cell`. Upvalue **reads** go through the U operand kind on existing opcodes (no dedicated `read-upval`). Upvalue **writes** are reserved (Phase 3+). See §6. |
| 6 | `var` | 2 | Var load / store / dynamic binding. |
| 7 | `coll` | 2 | Collection primitives (map/vector/set/list). Delegates to `src/coll/*.zig`. |
| 8 | `transient` | 2 | Transient lifecycle (`transient!` / `persistent!` / `*!`). Delegates to `src/coll/transient.zig`. |
| 9 | `hash` | 2 | Hashing + equality kernels. Delegates to `src/dispatch.zig`. |
| 10 | `tx` | 4 | Transaction boundaries + durable ref ops. Not in Phase 2. |
| 11 | `ctrl` | 2 | `throw`, `try-enter`, `try-exit`, `finally-enter`, `finally-exit`, `halt`. |
| 12 | `io` | 2 | Minimal I/O (`print`, `println`, `read-line`, `tap`). |
| 13 | `simd` | 6 | Typed-vector kernels. Not in Phase 2. |

Groups 2, 4, 5, 6, 7, 8, 9, 11, 12 are the Phase 2 critical
path. Groups 10 and 13 are reserved but not implemented in
Phase 2.

#### 10.1 `mov` group variants

| Var | Name | Status | Operands | Semantics |
|---|---|---|---|---|
| 0 | `mov:move` | step #1 | A=slot, B=any-resolvable, _ | `slot[A] := resolve(B)` |
| 1 | `mov:load-const` | step #1 | A=slot, B=constant, _ | `slot[A] := consts[B.index]` |
| 2 | `mov:load-nil` | step #1 | A=slot, _, _ | `slot[A] := nil` |
| 3 | `mov:load-true` | step #1 | A=slot, _, _ | `slot[A] := true` |
| 4 | `mov:load-false` | step #1 | A=slot, _, _ | `slot[A] := false` |
| 5 | `mov:load-keyword` | reserved | A=slot, B=intern, _ | `slot[A] := intern.lookup(B.index)` (keyword) |
| 6 | `mov:load-symbol` | reserved | A=slot, B=intern, _ | `slot[A] := intern.lookup(B.index)` (symbol) |

#### 10.2 `call` group variants

| Var | Name | Status | Operands | Semantics |
|---|---|---|---|---|
| 0 | `call:call` | reserved (step #5) | A=call_base, B=argc-imm, C=result_slot | Range-call ABI per §6 |
| 1 | `call:tailcall` | reserved (step #5/6) | A=call_base, B=argc-imm, C=ignored | Tail-call slide-into-place per §6 |
| 2 | `call:return` | step #1 | A=slot, _, _ | `result := slot[A]; halt or return to caller` |
| 3 | `call:return-nil` | step #1 | _, _, _ | `result := nil; halt or return to caller` |
| 4 | `call:apply` | reserved (Phase 3+) | A=call_base, B=argc-imm, C=result_slot | Last arg splatted; per §6 |
| 5 | `call:invoke-var` | reserved | A=var-imm, B=call_base, C=result_slot | Direct Var-call fast path; descriptor TBD |

#### 10.3 `math` group variants

| Var | Name | Status | Operands | Semantics |
|---|---|---|---|---|
| 0 | `math:add` | step #2 | A=slot, B=any, C=any | `slot[A] := resolve(B) + resolve(C)`. v1: fixnum+fixnum only. Errors: `:integer-overflow`, `:kind-mismatch` |
| 1 | `math:sub` | reserved | A=slot, B=any, C=any | subtraction |
| 2 | `math:mul` | reserved | A=slot, B=any, C=any | multiplication |
| 3 | `math:div` | reserved | A=slot, B=any, C=any | division (true) |
| 4 | `math:idiv` | reserved | A=slot, B=any, C=any | integer division |
| 5 | `math:mod` | reserved | A=slot, B=any, C=any | modulo |
| 6 | `math:pow` | reserved | A=slot, B=any, C=any | exponentiation |
| 7 | `math:neg` | reserved | A=slot, B=any, _ | unary negation |
| 8 | `math:abs` | reserved | A=slot, B=any, _ | absolute value |

#### 10.4 `closure` group variants

| Var | Name | Status | Operands | Semantics |
|---|---|---|---|---|
| 0 | `closure:make` | reserved (step #5) | A=prototype-const, B=cap_desc-imm, C=slot | Descriptor-based closure construction per §6 |
| 1 | `closure:box-local` | reserved (step #5) | A=slot, _, _ | Wrap `slot[A]`'s value in a fresh `UpvalCell{initialized=true}` |
| 2 | `closure:new-cell` | reserved (step #5) | A=slot, _, _ | Allocate uninitialized `UpvalCell{initialized=false}`; store ptr in `slot[A]` |
| 3 | `closure:init-cell` | reserved (step #5) | A=cell_slot, B=any, _ | Fill an uninitialized cell with `resolve(B)`; flip `initialized=true` |
| 4 | `closure:get-cell` | reserved (step #5) | A=slot, B=cell_slot, _ | `slot[A] := *(slot[B] as *UpvalCell)` |

#### 10.5 `jump` group variants

| Var | Name | Status | Operands | Semantics |
|---|---|---|---|---|
| 0 | `jump:jmp` | reserved (step #3) | A=jump-target, _, _ | `pc := A.index` |
| 1 | `jump:if-true` | reserved (step #3) | A=jump-target, B=any, _ | `if truthy(resolve(B)) then pc := A.index` |
| 2 | `jump:if-false` | reserved (step #3) | A=jump-target, B=any, _ | `if falsy(resolve(B)) then pc := A.index` (per PLAN §6.2: only nil and false are falsy) |

(Variant tables for `cmp`, `var`, `coll`, `transient`, `hash`,
`ctrl`, `io` populate when their respective steps land. The
implementation Zig enums use these variant numbers verbatim.)

---

### 11. `recur` semantics — the hard contract

Per peer-AI turn 28: **precise wording required, because this is
the semantic foundation users rely on for iteration.**

**User-level**: `(recur arg1 arg2 ...)` re-enters the nearest
enclosing `fn*` or `loop*` body with the given arguments,
WITHOUT growing the call stack.

**Compiler validation** (in analyzer, per `COMPILER.md` §4.4):
- `recur` MUST be in tail position of its target.
- `recur`'s arity MUST match the target's binding count.
- Errors: `:recur-outside-tail`, `:recur-arity-mismatch`.

**Codegen lowering** (per `COMPILER.md` §5.6, amended in
turn 35 to spell out the captured-binding case):
- Evaluate each `arg` into a temporary slot.
- Move temporaries into the target's binding slots using
  **parallel-assignment semantics** (a naive sequential move
  corrupts arguments when the target slots alias an earlier
  source — same hazard as `call:tailcall`'s arg slide).
- For NON-captured loop bindings: the move is a plain
  `mov:move` per binding.
- For CAPTURED loop bindings: each iteration allocates a
  **fresh `UpvalCell`** holding the new value and installs
  the cell pointer into the binding's slot. The shared cell
  is NOT mutated — that would break Clojure-equivalent
  immutable lexical binding semantics. See COMPILER.md §5.6
  for the full lowering and §6 above for the canonical
  `(loop [i 0 acc []] ...)` hazard.
- Emit `jump:jmp` to the target's entry label.
- **No `call` opcode is emitted**.

**VM runtime**:
- `jump:jmp` is a plain PC update + tail-call-to-dispatch.
- No frame allocation, no logical stack growth, no GC
  safepoint mandatory (a GC may still safepoint voluntarily,
  but `recur` does not force one).

**Guarantee** (peer-AI turn 35 amendment to remove a
contradiction with §6):
- **Constant stack space** is guaranteed unconditionally.
- **Constant heap space per iteration** is guaranteed for
  non-captured loop bindings only. For captured loop
  bindings, fresh-cell-per-iteration allocations are
  semantically required (per §6) and represent O(1) per
  captured binding per iteration — bounded, not zero.
  Allocations the body itself performs are user-observable
  and not part of this guarantee either way.

**Tested by Phase 2 gate #2** (`COMPILER.md` §9.4): a 10k-
iteration `recur` loop maintains constant stack high-water
mark. Heap behavior is body-dependent and tested separately.

---

### 12. try / catch / throw — minimal v1

Per peer-AI turn 28: minimal semantics here; exact exception-
object mechanics grow with the implementation.

**Handler region** (`ctrl:try-enter`):
- Pushes a handler entry onto the current frame's try-handler
  chain. Entry contains: PC of the catch entry, expected error
  type (or `any`), finally-entry PC (if any), binding slot for
  the thrown value.

**Normal exit** (`ctrl:try-exit`):
- Pops the handler entry.
- If a `finally` is associated, the finally body runs before
  the handler is popped; `ctrl:finally-exit` completes the exit.

**Throw** (`ctrl:throw`):
- Takes a value slot.
- Walks the current frame's try-handler chain looking for a
  matching handler:
  - If a handler matches, control transfers to the catch's
    entry PC; the thrown value is stored into the handler's
    binding slot; handlers below the matched one are discarded.
  - If no handler matches in the current frame, unwinds one
    frame (discarding slots, running any `finally` in the
    unwound frame), retries on the caller's chain.
  - If no frame's chain has a match, the VM halts with an
    unhandled-error report (source span of the throw + the
    thrown value).

**v1 type matching**:
- `any` matches everything.
- Keyword type tags match when the thrown value is a map with
  a matching `:kind` key. (Minimal; richer dispatch later.)

**`finally`**:
- Runs on both normal and exceptional paths.
- Cannot swallow exceptions: if `finally` itself throws, the
  original exception is lost (v1 behavior; later versions may
  chain).

Richer semantics (stack traces, cause chaining, restart-style
handlers) are explicitly future work. This spec pins only the
minimum needed for `(try (throw x) (catch any _ ...))` to be
correct.

---

### 13. Execution errors

Stable taxonomy for runtime errors. Tooling matches on the
keyword; renames are breaking changes.

| Error kind | When | Notes |
|---|---|---|
| `:stack-overflow` | Frame depth exceeds configured limit | Recoverable |
| `:arity-mismatch` | Var-dispatched call has wrong arg count | Runtime-only; compile-time is `COMPILER.md` §4.3 |
| `:unresolved-var` | `var:load-var` resolves to an undefined Var | Linker should catch most cases; runtime catch is safety net |
| `:divide-by-zero` | Fixnum or float `div` / `quot` / `rem` with zero divisor | Deterministic trap |
| `:kind-mismatch` | `coll:*` opcode on a value of wrong kind (e.g., `map-get` on a vector) | Recoverable via try/catch |
| `:not-callable` | `call:call` on a non-callable value | Recoverable |
| `:uncaught-throw` | `ctrl:throw` with no handler up the frame chain | Halts VM with error report |
| `:extension-decode-failure` | Primary instruction expects extension but extension bytes malformed | Programming error; halts VM |
| `:transient-frozen` | `transient_mod.*Bang` op on a finalized transient | Recoverable |
| `:invalid-operand-kind` | Operand's kind byte is incompatible with opcode context (e.g., `resolve` on an `.unused` operand, `store` to a constant operand) | Handler bug; distinct from index-OOB and from corrupted encoding |
| `:bytecode-corruption` | Unrecognized opcode group / variant / operand-kind bit pattern | Programming error; halts VM |
| `:call-block-out-of-range` | `call:call` / `call:tailcall` references a `call_base` slot such that `slot[A + argc]` exceeds the frame's slot count | Programming error; indicates compiler bug — call block was not allocated within the routine's `slot_count` |
| `:upvalue-out-of-range` | `U` operand index exceeds the current closure's upvalue count, OR `closure:make` descriptor's `inherited_upvalue` source exceeds it | Programming error; halts VM |
| `:expected-cell` | An opcode that requires an `UpvalCell*` (e.g., `closure:get-cell`, `closure:init-cell`, `closure:make`'s `local_cell_slot` source) found a different value kind in the slot | Programming error; halts VM |
| `:invalid-cell-state` | `closure:box-local` on an already-boxed slot (double-box), or `closure:init-cell` on an already-initialized cell | Programming error; halts VM |
| `:uninitialized-cell` | `closure:get-cell` (or U-operand resolve) on a cell with `initialized = false` — placeholder not yet filled | Recoverable in principle but typically a compiler-emitted-out-of-order bug |
| `:unsupported-write` | `store(u:N, ...)` attempted in v1 (writes to captured upvalues are reserved for Phase 3+ dynamic-binding rebinding) | Recoverable; user code shouldn't see this in v1 unless attempting a future feature |
| `:integer-overflow` | Fixnum arithmetic overflowed i48 range AND bignum promotion is not yet wired for the offending opcode. Temporary trap (peer-AI turn 35) until bignum-arithmetic Scope B lands; remains useful afterward for bounded-integer ops, byte conversions, FFI, and unchecked-math variants | Recoverable |

All errors are structured `Value`s (map with `:kind`, `:msg`,
`:span` keys minimally) so user code can pattern-match.

**Staged-implementation traps** (peer-AI turn 35): early
Phase 2 commits also surface internal Zig errors that aren't
in this user-facing taxonomy yet — `OperandOutOfRange`,
`BytecodeExhausted`, `UnimplementedOpcode`, and the Halt
control-flow signal. These are NOT stable user-facing error
kinds; they exist to help debugging the in-progress VM and
are mapped into the structured `Value` runtime-error layer
when the latter lands (likely with the `ctrl:throw` /
try-handler implementation). Phase 2 gate tests treat these
internal errors as "VM rejected the bytecode" without
asserting a specific kind keyword.

---

### 14. Interaction with existing subsystems

- **`src/value.zig`**: the VM operates on `Value` throughout.
  All slot/constant/upvalue reads produce `Value`s; all stores
  write `Value`s.
- **`src/heap.zig`**: heap allocation goes through `Heap` as
  elsewhere. Routines, closures, upvalue cells, and compiled
  constant-pool collections are all heap objects.
- **`src/gc.zig`**: per §9.
- **`src/intern.zig`**: I-kind operands resolve via the
  interner; routine constant pools use intern IDs for any
  embedded keywords/symbols.
- **`src/dispatch.zig`**: `hash:*` and `coll:*` groups delegate
  here; no duplicated equality / hash logic in the VM.
- **`src/coll/*.zig`**: `coll:*` + `transient:*` groups
  delegate directly.
- **`src/codec.zig`**: `tx:*` group (Phase 4, NOT Phase 2)
  routes through the codec for durable-ref serialization.
- **`src/pool.zig`**: the VM itself does not allocate
  frequently outside object creation; frame-stack storage may
  use the pool allocator or a dedicated contiguous region
  (flexible per §7).

---

### 15. Testing plan

Three layers, paralleling `COMPILER.md` §9:

#### 15.1 Per-opcode unit tests

- `src/vm.zig` inline tests for every opcode:
  - Hand-assembled bytecode for a single-instruction exercise.
  - Pre-state + post-state assertion.
  - Error-path coverage for every `:`-prefixed error kind.

#### 15.2 Per-group integration tests

- `math` group: arithmetic on fixnums, floats, bignums,
  cross-type (fixnum + float), overflow promotion,
  divide-by-zero.
- `coll` group: map get/assoc, vector conj/nth, set
  contains/conj, list first/rest, cross-kind errors.
- `closure` group (peer-AI turn 35 amendment to match v1
  semantics): `closure:make` (descriptor sources from
  `local_cell_slot` and `inherited_upvalue`), `closure:box-local`
  + double-box trap, `closure:get-cell` + `:expected-cell` /
  `:uninitialized-cell` traps, `closure:new-cell` /
  `closure:init-cell` placeholder lifecycle, nested closures,
  `letfn*` mutual recursion via placeholder cells, named `fn*`
  self-reference via single placeholder cell, captured loop
  bindings get fresh cells per iteration (the canonical
  `(loop [i 0 acc []] ...)` test from §6 — closures capture
  0/1/2, not 3/3/3), `store(u:N, ...)` returns
  `:unsupported-write` (not "shared-upvalue mutation
  visibility" — writes are reserved for Phase 3+).
- `call` group: `call` vs `tailcall` (frame reuse verified),
  `apply`, variadic arity.
- `ctrl` group: try/catch/throw with various match patterns,
  finally execution order, uncaught throw.

#### 15.3 Full-pipeline tests (shared with `COMPILER.md` §9.3)

- `test/eval/*.nx` source → expected printed output.
- Exercises compiler + VM end-to-end.

#### 15.4 Phase 2 gate tests

Shared with `COMPILER.md` §9.4. VM-specific gates:

- Dispatch-loop correctness: 10k-iteration `recur` loop in
  constant stack space.
- Frame-stack correctness: deeply-nested non-tail calls (depth
  1000) complete and return correctly.
- GC interaction: run GC at a safepoint mid-loop; all frame
  slots correctly treated as live; no use-after-free.
- Error recovery: `try`/`catch` correctly catches every
  recoverable error kind from §13.

---

### 16. What's intentionally left flexible

Per peer-AI turn 28:

- Exact Zig struct layout for `Routine`, `Closure`, `UpvalCell`,
  `Frame`. §5–§7 pin the logical model; code chooses
  representation.
- Frame-stack backing storage (contiguous / slab / segmented;
  §7).
- Exact dispatch-loop code (§8). Contract is tail-call-threaded;
  implementation matches em's approach but can diverge.
- Per-opcode handler signature. Contract is "handler reads the
  current instruction from the VM, executes semantics, tail-
  calls dispatch." Parameter names, return types,
  argument-passing conventions are flexible.
- Stack overflow handling mechanics — recoverable-error contract
  is pinned (§13); how the recovery is surfaced to user code
  is implementation-driven.
- Interned-keyword / intern-id operand encoding details beyond
  "operand position fixes the kind and the handler dispatches
  to interner.lookup" (§4.2).

---

### 17. Cross-references

- `docs/COMPILER.md` — compiler that emits bytecode for this
  VM (companion).
- `PLAN.md` §12 — ISA physical format + operand kinds + opcode
  groups (higher-level).
- `PLAN.md` §8 — Value model (what the VM manipulates).
- `docs/VALUE.md` — heap kinds; `function` (kind 22) is the
  routine / closure carrier.
- `docs/SEMANTICS.md` — equality / hash invariants the VM
  must respect via `hash:*` and comparison ops.
- `docs/GC.md` — GC contract the VM participates in.
- `docs/POOL.md` — allocator used for heap objects.
- `../em/docs/architecture/ISA.md` — em's ISA (adapted).
- `../em/docs/architecture/RUNTIME.md` — em's VM runtime
  (adapted).

---

### 18. Amendment log

- **2026-04-19** (spec commit): Initial draft. All contracts
  `proposed`. No implementation yet. Peer-AI turn 28 decisions
  embedded.
- **2026-05-15** (§6 / §10 / §13 amendment): **Closure group
  opcode set pinned** (peer-AI turn 34). The previous
  one-line `closure:make-closure A=result B=routine_const
  C=upvalue_descriptor` was underspecified in three
  load-bearing ways:
  (1) **My initial proposal** to mirror the call-ABI's
  range-style for closure construction was wrong — it
  missed the routine prototype operand (a closure is
  `(routine, upvalues[])`, not just upvalues), forced extra
  bytecode to materialize raw cell pointers through slots,
  and conflicted with U-operand cell-deref semantics.
  Replaced with a **descriptor-based** encoding:
  `closure:make A=prototype_const B=capture_desc
  C=result_slot`, with descriptor entries naming each
  upvalue source as either `local_cell_slot` (raw cell
  pointer in current frame) or `inherited_upvalue` (raw
  cell pointer from current closure's upvalue array).
  (2) **`letfn*` mutual recursion** required placeholder
  cells that exist before either closure is constructed.
  Added `closure:new-cell` and `closure:init-cell` opcodes
  with an `initialized` flag on `UpvalCell`. The v1 v1
  closure-group surface is now: `make`, `box-local`,
  `new-cell`, `init-cell`, `get-cell` (5 variants).
  (3) **`recur` on captured loop bindings** requires
  fresh cell allocation per iteration, NOT mutation of the
  shared cell. Pinned in §6 with the canonical example
  `(loop [i 0 acc []] (if (< i 3) (recur (+ i 1) (conj
  acc (fn [] i))) acc))` — closures must capture 0/1/2,
  not 3/3/3. Cell-mutation lowering for captured `recur`
  would have silently broken Clojure-equivalent immutable
  lexical binding semantics; the spec now requires the
  analyzer to emit cell-fresh-per-iteration for captured
  bindings and slot-rewrite for non-captured.
  (4) The U operand kind is **cell-contents-on-resolve**,
  NOT raw-cell-pointer. Capture construction goes through
  descriptors; reads inside closure bodies use U directly
  on existing opcodes (no dedicated `closure:read-upval`).
  U-store path reserved (`:unsupported-write`) until Phase
  3+ dynamic-binding rebinding.

  Five new error kinds added to §13:
  `:upvalue-out-of-range`, `:expected-cell`,
  `:invalid-cell-state`, `:uninitialized-cell`,
  `:unsupported-write`. None are user-language-level
  errors — all indicate compiler bugs or v1-feature gaps;
  they trap to surface corruption rather than silently
  proceed.

  Surfaced by a hand-trace of `(defn make-adder [x] (fn
  [y] (+ x y)))` which exercised closure capture for the
  first time end-to-end. Peer-AI turn 34 review caught
  three load-bearing bugs in the initial proposal before
  any code was written.

- **2026-05-15** (§6 / §7 / §13 amendment): **Range-call ABI
  pinned** (peer-AI turn 32). The previous "encoding
  group-specific" handwave for `call:call` operand B was
  replaced with a concrete Lua-5.x-style range-call ABI:
  `A` = call_base slot containing the closure, `slot[A+1..]`
  = arguments, `B` = argc, `C` = result slot. `call:tailcall`
  pinned to slide-into-place semantics (NOT base-slide,
  which would leak backing stack across mutual tail
  recursion). `call:apply` reserved for Phase 3+. Variadic
  rest-list construction pinned to call/prologue machinery,
  not caller bytecode. Frame storage strategy refined to
  require backing-stack-with-frame-base evolution when
  step #5 (functions + closures) lands; current per-frame
  owned-slot model in `src/vm.zig` is fine for the single-
  frame skeleton and for step #2 (math:add). New error kind
  `:call-block-out-of-range` added to §13.

  Surfaced by a hand-trace of `(defn fact [n] (loop [n n
  acc 1] (if (< n 2) acc (recur (- n 1) (* n acc)))))`
  which exposed that the existing spec had no syntactic
  room to encode arg lists in the 64-bit instruction. Peer-
  AI turn 32 review explicitly compared against Lua 5.x,
  Dalvik invoke/range, descriptor-based calls, Wasm/CPython
  stack-machine, and BEAM argument registers; range-call
  selected for one-instruction fast path + clean tail-call
  semantics + minimal new ISA surface. Compiler is permitted
  to ship early codegen with `mov:move` prelude staging
  (Option-1-like behavior); later allocator work targets
  arg-evaluation results directly into the call block to
  eliminate the moves. The ISA does not change either way.
