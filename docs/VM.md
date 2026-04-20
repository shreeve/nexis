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

---

### 5. Routine

A **routine** is the compiled code of one `fn*` (or the implicit
top-level form). Runtime representation is a heap value of kind
`function` (VALUE.md kind 22).

**Routine contents** (logical; Zig layout flexible):

- **Code**: array of 64-bit instructions.
- **Constant pool** (`consts`): array of runtime `Value`s.
- **Var table** (`vars`): array of pointers to namespace Vars
  the code references.
- **Upvalue descriptors**: for each upvalue slot in this routine,
  how to locate the source cell when a closure is created from
  the enclosing frame.
- **Entry points** per arity: offset where each supported arity
  starts executing. Multi-arity `fn*` is macro-lowered to
  separate `fn*` nodes pre-compiler, but the routine may still
  carry multiple entry points for variadic dispatch.
- **Source-span map**: table mapping instruction offsets to
  `SrcSpan` for error reporting + disassembly.
- **Metadata**: name, doc, `:arglists`, `:line`, etc. — a map
  attached for tooling.

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
- Carries exactly one `Value` slot.
- Written once at binding time; subsequent mutation depends on
  future `set!` / `volatile!` semantics (not part of Phase 2).
- Multiple closures sharing the same upvalue cell observe each
  other's writes (when writes are permitted).

**Closure creation** (`closure:make-closure`):

- Operand A = result slot.
- Operand B = constant-pool index of the routine.
- Operand C = upvalue descriptor (interpreted via the routine's
  upvalue table).
- Effect: allocate the closure; populate upvalues from the
  current frame's captured cells; store the closure reference
  into operand-A slot.

**Closure invocation** (`call:call`, `call:tailcall`,
`call:apply`):
- Operand A = closure slot (must be a closure).
- Operand B = arg list (encoding group-specific).
- Operand C = result slot (for `call`) or ignored (for
  `tailcall`).
- Effect: set up a new frame, pass args into the callee's
  parameter slots, point `frame.upvalues` at the closure's
  upvalue array, dispatch into the callee's entry point.

**Logical calling convention** (peer-AI turn 30):
- The callee receives its arguments in its local slot space
  in the declared parameter order, starting from slot 0.
- Arity checking (including variadic rest-arg) happens BEFORE
  control transfers to the callee. A failed arity check raises
  `:arity-mismatch` from the caller's PC.
- Caller and callee slots do NOT alias. The caller may
  continue to hold its own slot values after the callee
  returns (for `call:call`; `call:tailcall` deliberately
  overwrites the caller's frame in place).
- Physical realization of this contract (dedicated arg area
  vs in-place slot copy vs remap) is an implementation choice
  under `frame-stack storage strategy` (§7).

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

**Storage strategy** (intentionally flexible per peer-AI turn 28):
- v1 may use a contiguous growable stack, a slab chain, or
  segmented frames. The spec requires only that:
  - Frames are accessible by the VM in O(1).
  - Arbitrary depth is supported (bounded only by memory).
  - Stack overflow produces a recoverable error
    (`:stack-overflow`), not a crash.

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

- Dispatch is **tail-call threaded**: each handler ends with a
  tail call to the central dispatch function, which in turn
  tail-calls the next handler. No stack growth from dispatch.
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
documented here; exact variant-level specs live next to the
implementation per group.

| # | Group | Phase | Notes |
|---|---|---|---|
| 0 | `jump` | 2 | Branches (unconditional + conditional). Operand A is always J; operands B/C are hot-path. |
| 1 | `cmp` | 2 | Compare ops producing a bool into a slot. |
| 2 | `math` | 2 | Integer + float arithmetic. Fixnum fast path + bignum promotion. |
| 3 | `mov` | 2 | Data movement, load-const, load-true/false/nil, load-keyword/symbol (via I operands). |
| 4 | `call` | 2 | Function invocation (`call`, `tailcall`, `invoke-var`, `apply`, `return`). |
| 5 | `closure` | 2 | Closure creation + upvalue access. |
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

**Codegen lowering** (per `COMPILER.md` §5.6):
- Evaluate each `arg` into a temporary slot.
- Emit `mov:move` to copy temporaries into the target's binding
  slots.
- Emit `jump:jmp` to the target's entry label.
- **No `call` opcode is emitted**.

**VM runtime**:
- `jump:jmp` is a plain PC update + tail-call-to-dispatch.
- No frame allocation, no stack growth, no GC safepoint
  mandatory (a GC may still safepoint voluntarily, but `recur`
  does not force one).

**Guarantee**: a `recur`-driven loop runs in **constant** stack
space and **constant** heap space per iteration (apart from
allocations the body itself performs).

**Tested by Phase 2 gate #2** (`COMPILER.md` §9.4): a 10k-
iteration `recur` loop maintains constant stack high-water mark.

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
| `:bytecode-corruption` | Invalid opcode group/variant | Programming error; halts VM |

All errors are structured `Value`s (map with `:kind`, `:msg`,
`:span` keys minimally) so user code can pattern-match.

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
- `closure` group: creation, upvalue read/write, nested
  closures, shared-upvalue mutation visibility.
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
