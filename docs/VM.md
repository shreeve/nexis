## VM.md — runtime: bytecode format + execution contracts

Authoritative contract for the nexis virtual machine (`src/vm.zig`)
that executes bytecode routines emitted by the compiler described
in `docs/COMPILER.md`. Derivative from `PLAN.md` §12 (ISA physical
format, operand kinds, opcode groups) and
`../em/docs/architecture/ISA.md` + `../em/docs/architecture/RUNTIME.md`
(the template nexis adapts).

**Discipline**: this spec pins **semantic contracts**, not exact
Zig code. Dispatch-loop form, frame-stack storage strategy, and
handler signatures are implementation choices. What each opcode
DOES and what invariants the VM upholds are frozen here.

> **Freeze level**: the compiler/VM interface is frozen at the
> level of **semantic obligations** — operand meanings,
> frame/routine logical contents, calling + `recur` contracts,
> error taxonomy. It is NOT frozen at the level of concrete Zig
> struct layout. Implementation may choose any representation
> that preserves these obligations end-to-end.

---

### 1. Scope

**In:**
- Bytecode instruction encoding (64-bit fixed-width; the 20-bit
  extension form is encoded but never executed, §3).
- SCVU hot-path / IJE context-local operand kinds per PLAN §12.2.
- The 14 opcode group numbers per PLAN §12.3, nine of which are
  dispatched (§10).
- Call frame model: frames windowing one shared backing stack.
- Routine / closure / upvalue representations.
- Two-level switch dispatch.
- Execution error set and the catchable subset (§13).
- `recur` constant-space guarantee.
- `try` / `catch` / `finally` / `throw` with cross-frame unwinding,
  shared by bytecode throws and native throws.
- Native functions (`NativeFn`), reentrant calls into the VM from
  natives (`VM.callValue`), the numeric tower behind `math:*` /
  `cmp:*` and the arithmetic natives, `lookup` (the one
  implementation of `get`, `(:k m)`, `(m :k)`, `(s x)`, `(v i)`),
  namespaces, Vars and the namespace registry.
- Per-opcode unit tests + per-group integration tests.

**Absent (stated as facts):**
- No operand-specialized opcodes (`ADDVV` / `ADDVN` etc.), no
  inline caches on call sites.
- No `tx:*`, `simd:*`, `io:*`, `hash:*` or `transient:*` opcodes:
  the group numbers exist; an instruction in one of those groups
  traps `UnimplementedOpcode`. Durable-ref, I/O, hashing and
  transient operations are natives.
- No bytecode verifier, no object files, no tiered compilation.
  `bin/nexis disasm` reads routines; nothing checks them before
  they run.
- No per-PC liveness maps: the whole backing stack is a root (§9).
- No unbounded recursion: the frame chain stops at `VM.max_frames`
  and native re-entry at the stack guard, both with a catchable
  `:stack-overflow` (§13).

---

### 2. Design inheritance from em

em (`../em/src/`) is the Zig-level template for:

- Instruction encoding shape (64-bit + 20-bit extension).
- Operand-slot layout (`kind:4 | index:12` per operand).
- Group/variant handler selection.

nexis **adapts** em for:

- **Operand kinds**: em has 8 MUMPS-flavored kinds (CVLSEPJG);
  nexis commits to 7 with a hot-path / context-local split
  (SCVU + IJE; PLAN §12.2).
- **Opcode groups**: nexis's 14 groups diverge from em's — nexis
  adds `coll`, `transient`, `hash`, `tx` and drops MUMPS-specific
  groups.
- **Value model**: em values are dynamically-typed MUMPS
  strings-with-coercion; nexis values are 16-byte tagged
  (`docs/VALUE.md`) with strict equality categories (`docs/
  SEMANTICS.md`).
- **Closures**: em has none; nexis adds closure creation +
  upvalue representation.
- **Persistent collections**: em operates on plain arrays;
  nexis's `coll:*` group delegates to `src/coll/*.zig`.
- **Dispatch**: em is tail-call threaded; nexis dispatches through
  a two-level switch (§8).

---

### 3. Physical instruction format

Per PLAN §12.1:

```
Primary instruction (64 bits):

  | kind(4) | group(6) | variant(6) | opA(16) | opB(16) | opC(16) |

Operand slot (16 bits each):

  | kind(4) | index(12) |

Extension instruction (64 bits, defined for operand indexes that
exceed 12 bits):

  | kind(4) | extA(20) | extB(20) | extC(20) |
```

**Invariants**:
- `InstKind` distinguishes `primary` (0) from `extension` (1).
  The VM traps `UnimplementedOpcode` on an extension instruction
  and the compiler never emits one: a routine needing more than
  4096 constants, slots or instructions is a compile error
  (`COMPILER.md §4.4`).
- **Group and variant** together select the handler: 64 groups
  × 64 variants of address space.
- **Operand kind** is 4 bits, permitting up to 16 kinds. Seven are
  defined (SCVU + IJE); kinds 7–14 are reserved; kind 15 is the
  `unused` sentinel for "missing operand."
- **Operand index** is 12 bits (0..4095).

Concrete Zig encoding (bit positions, struct layout) is an
**implementation detail**, not frozen by this spec. The
semantic contract above is frozen.

---

### 4. Operand kinds

Per PLAN §12.2. Brief recap.

#### 4.1 Hot-path kinds (SCVU) — 0..3

Dispatched together by any opcode whose operand position accepts
"any resolvable operand" (`resolve()`):

| # | Code | Name | Source |
|---|---|---|---|
| 0 | `s` | slot | Frame-local slot (`stack[frame.base_slot + index]`) |
| 1 | `c` | constant | Routine's constant pool (`routine.consts[index]`, must be `Const.value`) |
| 2 | `v` | var | `routine.var_table[index].root`; traps `:unbound-var` if never `def`'d |
| 3 | `u` | upvalue | Closure's captured cell contents (`frame.upvalues[index].value`) |

Index 0 = slot because it's the hottest kind (predicts to
case-0 of the dispatch switch).

`store()` accepts only `s`; a store to `c` / `v` is
`InvalidOperandKind`, a store to `u` traps `UnimplementedOpcode`
(there is no upvalue write path; §6).

#### 4.2 Context-local kinds (IJE) — 4..6

Only appear in opcodes whose operand position fixes the kind.
Handlers don't dispatch on kind for these operands:

| # | Code | Name | Used by |
|---|---|---|---|
| 4 | `i` | intern | reserved — no opcode reads it (`resolve` traps `UnimplementedOpcode`) |
| 5 | `j` | jump | `jump:*` targets, `ctrl:try-enter` / `ctrl:try-exit` pcs |
| 6 | `e` | durable | reserved — no opcode reads it |

#### 4.3 Reserved kinds — 7..14

Unassigned.

#### 4.4 Sentinel — 15

`unused` = missing operand. Used when an opcode takes fewer than
three operands to fill unused slots.

#### 4.5 Raw-index / immediate operand convention

Several opcodes carry a 12-bit operand whose `index` value is
**the data itself** rather than an index into a table — for
example, `call:call`'s `B = argc` and `closure:make`'s `B =
capture_descriptor_index`. The 64-bit instruction format has no
dedicated "immediate" operand kind.

**Convention**: for operand positions documented in §10 as
"immediate" or "raw index", the handler **ignores the operand
kind bits** and reads only the 12-bit `index`. Assemblers encode
the kind as `.slot` for canonical bytecode.

This convention applies to:
- `call:call B=argc` (and `call:tailcall B=argc`)
- `closure:make B=capture_descriptor_index`
- `coll:* B=argc`

---

### 5. Routine

A **routine** is the compiled code of one `fn*` (or the implicit
top-level form). It is a plain Zig struct, not a heap Value;
routines are user-visible only through the closures that wrap
them (§6).

**Routine contents**:

- **Code**: array of 64-bit instructions.
- **Constant pool** (`consts`): array of **typed constants**:
  ```
  Const = union(enum) {
      value: Value,                  // ordinary runtime value
      routine: *const Routine,       // child routine prototype
  }
  ```
  Operands that reference the constant pool must match the
  expected variant: `mov:load-const A=slot B=constant`
  requires `Const.value`; `closure:make A=constant` requires
  `Const.routine`. Mismatched variant raises
  `InvalidOperandKind`. The typed pool prevents prototype
  constants from being loaded into ordinary value slots.
- **Var table** (`var_table`): array of `*Var` the code
  references, bound at compile time. `V#` operands index it.
- **Capture-descriptor table** (`capture_descs`): the descriptors
  this routine's `closure:make` instructions use to construct
  CHILD closures (§6). Metadata USED BY the routine.
- **Upvalue count** (`upvalue_count`): the number of upvalue cells
  the routine's body expects. When a closure carrying this
  routine is invoked, the callee frame's `upvalues` array has
  exactly this length, and U operands index into it. Metadata
  ABOUT the routine.
- **Slot count** (`slot_count`): the frame window size.
- **Arity** (`fixed_arity`, `variadic`): `call:call` requires
  `argc == fixed_arity` for a fixed routine and
  `argc >= fixed_arity` for a variadic one; a variadic routine's
  `slot_count` is at least `fixed_arity + 1` (room for the rest
  slot) or the routine is `BytecodeCorruption`.
- **Name**: for diagnostics (`<anonymous>` by default; the
  compiler names a `defn` routine after its Var, an anonymous
  closure `fn`, the CLI a top-level form `<top>` and `eval` the
  form it runs `<eval>`).
- **Span table** (`spans`): `SpanEntry{pc, span}` runs ascending
  by pc, one per change of source span, so `spanAt(pc)` (a
  binary search) gives the `SourceSpan{pos, len}` of the form
  the instruction at `pc` was lowered from. `origin` is the span
  of the routine's own form and `source` the `SourceInfo{path,
  text}` the spans index into (null when unknown). The compiler
  fills all three (`COMPILER.md` §8); a routine built by hand
  has an empty table. Execution never reads them: the error path
  (§13) and the disassembler do.

Routines carry no metadata map.

**Routine identity**: two routines compiled from the same source
are NOT required to be `identical?`. Structural equality between
routines is undefined at the user-observable level; `(=)` on two
closures compares identity.

---

### 6. Closure

A **closure** is a routine bundled with its captured upvalue
cells. All user-level `fn*` values at runtime are closures,
even when no capture occurred (in that case, the upvalue array
is empty).

**Closure contents**:
- Routine reference.
- Upvalue cell array `[]const *UpvalCell`.

**Closure value representation**: a closure is a heap block of
kind `function` (VALUE.md §4): the body is `Closure { routine,
upvalues }` and the block's tail holds the cell pointers
`upvalues` points at, so one allocation carries the whole closure
and the slice stays valid because the collector never moves a
block. `closure:make` allocates the block and fills the tail with
nothing allocated in between. `VM.asClosure` reads the body. The
collector traces a closure by its cells and by the heap constants
of its routine (§9).

**UpvalCell**:
- A heap block of kind `cell_internal` whose body is
  `UpvalCell { value, initialized }`; the `.cell_internal` Value a
  slot holds and the `*UpvalCell` a closure or frame holds both name
  the block. Reachable from the slot that boxed it, from every
  closure that captured it and from every frame running such a
  closure; the collector traces it by its value.
- Carries exactly one `Value` slot, plus an `initialized: bool`
  flag so that placeholder cells (used for `letfn*` mutual
  recursion and named `fn*` self-reference) can be detected when
  read before init.
- Written once at binding time (`box-local`) or once at init
  (`new-cell` + `init-cell`). There is no rewrite path: a store
  through a U operand traps `UnimplementedOpcode`.
- Multiple closures sharing the same upvalue cell see the same
  contents.
- **CRITICAL**: **`recur` does NOT mutate captured loop-binding
  cells**. Each iteration of a captured loop binding gets a
  **fresh cell**. Otherwise closures created in earlier
  iterations would observe later iterations' values, which
  violates Clojure-equivalent immutable lexical binding
  semantics. See "recur on captured loop bindings" below.

#### `closure:make A=prototype_const B=capture_desc C=result_slot`

**Descriptor-based** rather than range-style: the compiler
statically knows every closure's capture set — both the count and
the source of each upvalue. This makes capture a side-table
problem, not a runtime-staging problem. Range-style staging would
force extra `mov:move`s to materialize raw cell pointers through
slots, conflicting with the U-operand cell-deref semantics.

- `A` is a constant-pool index referencing the **child
  routine prototype** (`Const.routine`).
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
- Allocate a closure (kind `function`, VALUE.md kind 24) with an
  `[N]*UpvalCell` array, where `N = descriptor.sources.len`. `N`
  must equal the child routine's `upvalue_count`, otherwise
  `CaptureCountMismatch`.
- For each `source[i]`:
  - `local_cell_slot(s)`: read `slot[s]` as `UpvalCell*` and
    copy the pointer into `closure.upvalues[i]`. Trap
    `ExpectedCell` if `slot[s]` does not hold an `UpvalCell*`.
  - `inherited_upvalue(u)`: copy
    `current_frame.upvalues[u]` into `closure.upvalues[i]`.
    Trap `UpvalueOutOfRange` if `u` exceeds the current
    closure's upvalue count.
- Store the new closure reference into `slot[C]`.

**Note on raw cell pointers vs cell contents**: this opcode
copies **raw cell pointers**, NOT cell contents. Multiple
closures capturing the same source cell share the same
underlying cell — that's how `letfn*` recursive bindings see
each other after init.

#### `closure:box-local A=slot _ _`

Wraps a local's value into a fresh `UpvalCell` so that a
subsequent `closure:make` can capture it.

- `A` (slot) holds a plain `Value v`.
- Effect: allocate a fresh `UpvalCell` with `value = v` and
  `initialized = true`. Replace `slot[A]` contents with the
  cell pointer.

**Compiler emission timing**: the compiler does **capture
pre-analysis per `let*` / `loop*` / `fn*`** and emits
`closure:box-local` at **binding time** (let-binding prelude) or
**function entry** (for captured params). The emission sits in
straight-line code that every reachable runtime path traverses,
guaranteeing the slot holds an `UpvalCell*` before any inner
closure could possibly construct against it. This makes
`closure:get-cell` and `closure:make`'s `local_cell_slot` source
safely strict (no runtime "ensure cell" dynamic check). Emitting
the box lazily, just before the enclosing `closure:make`, is not
control-flow safe: a closure created in an unreachable branch
would leave the binding unboxed at runtime while the compiler's
scope treated it as boxed. See `COMPILER.md §6.1`.

The opcode itself is timing-agnostic. After emission, reads of
the local in the defining frame must use `closure:get-cell` (or
any opcode through which a U-operand resolves to cell contents).

**Errors**:
- `InvalidCellState` if `slot[A]` already holds an `UpvalCell*`
  (double-box). Indicates compiler bug; trap rather than no-op
  so corruption surfaces.

#### `closure:new-cell A=dst_slot _ _`

Allocates an **uninitialized** `UpvalCell` and stores the cell
pointer in `slot[A]`. Used to create placeholder cells for
mutually recursive closures so that closures referring to each
other can be constructed before either has its final value.

- `A` (slot) is the destination for the new cell pointer.
- Effect: allocate `UpvalCell{ value: undefined, initialized:
  false }`. Store the pointer in `slot[A]`.

#### `closure:init-cell A=cell_slot B=value_operand _`

Initializes an uninitialized cell with a value. Used to fill in
`letfn*` placeholder cells once their final closure values exist.

- `A` (slot) holds an `UpvalCell*` whose `initialized = false`.
- `B` is any operand kind that `resolve()` accepts.
- Effect: write `resolve(B)` into the cell's value slot;
  flip `initialized = true`.

**Errors**:
- `ExpectedCell` if `slot[A]` does not hold an `UpvalCell*`.
- `InvalidCellState` if the cell is already initialized.
- `InvalidOperandKind` if `A` is not a slot operand.

#### `closure:get-cell A=dst_slot B=cell_slot _`

Reads the contents of an `UpvalCell` whose pointer is in a frame
slot. Necessary because slot operands mean "the value in the
slot" — they do NOT auto-deref cells, since the same slot might
also be used to hold an already-stored `UpvalCell*` for
descriptor-based capture.

- `A` (slot) is the destination.
- `B` (slot) holds an `UpvalCell*`.
- Effect: dereference the cell; write its value into
  `slot[A]`.

**Errors**:
- `ExpectedCell` if `slot[B]` does not hold an `UpvalCell*`.
- `UninitializedCell` if the cell has `initialized = false`.

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

**Important distinction**: `U` is a **cell-contents** operand,
NOT a raw-cell operand. Closure construction needs **raw cell
pointers** and goes through the descriptor mechanism
(`local_cell_slot` / `inherited_upvalue`) on `closure:make`. The
two are never conflated — making `U` raw-pointer-on-some-paths
and value-on-other-paths would be a semantic footgun.

**Writes to captured upvalues** do not exist. There is no `set!`
on lexical locals; `store(u:N, ...)` traps `UnimplementedOpcode`.

#### `recur` on captured loop bindings (CRITICAL)

When a `loop*` binding is captured by a closure within the loop
body, a naive implementation would mutate the captured cell on
each iteration. **This is wrong.**

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

The compiler's capture pre-analysis decides which loop bindings
are captured and emits the appropriate `recur` lowering:
cell-fresh-per-iteration for captured, slot-rewrite for
non-captured. The VM does no special work for `recur`.

**Closure invocation — range-call ABI** (modeled on Lua 5.x
`CALL A B C`):

The compiler stages the closure plus its arguments in a
**contiguous call block** in the caller's slot space, then
emits a single `call:call` referencing the block's base slot.
This eliminates the arg-list encoding problem (the 64-bit
instruction has only three 16-bit operands; arbitrary arg lists
do not fit) and enables a one-instruction call fast path.

#### `call:call A=call_base B=argc C=result_slot`

- `A` (slot) is the **call_base**: the slot containing the
  callee.
- `B` is the **argument count** (encoded as an immediate-style
  index — `B.kind` is `.slot` purely for encoding uniformity;
  the index value IS the argc, not a slot index).
- `C` (slot) is the **result slot**.

**Preconditions**:
- `slot[A]` is callable (below).
- `slot[A + 1 + i]` is argument `i`, for `i ∈ [0, argc)`.
- The block `[A .. A + argc]` is fully populated by the
  caller before this instruction executes, and lies within the
  routine's `slot_count`; otherwise `CallBlockOutOfRange`.

**Callable kinds**, in dispatch order:
- `native_fn`: the Zig function is called with the argument
  slice; its result lands in `slot[C]`. Arity is checked
  against the descriptor's `min_arity` / `max_arity`
  (`:arity-mismatch`).
- `protocol_fn`: dispatch on the first argument's kind (or record
  type) through the VM's protocol registry (`docs/PROTOCOLS.md`);
  `:no-protocol-impl` / `:no-protocol-method` on a miss.
- `keyword`, `symbol`, `persistent_map`, `persistent_set`,
  `persistent_vector`: invoked as a lookup — `(:k m)`, `('s m)`,
  `(m :k)`, `(s x)`, `(v i)` with an optional default (PLAN §8.7,
  `VM.lookup`); a symbol looks itself up exactly as a keyword does.
- `function` (a closure): the frame transfer below.
- Anything else: `:not-callable`.

**Closure semantics**:
- Validate `argc` against the routine's `fixed_arity` /
  `variadic`; otherwise `:arity-mismatch`.
- Construct a callee frame whose window begins at caller
  `slot[A + 1]`: `callee_base = caller_base + A + 1`, so the
  callee's slot 0 IS the caller's `slot[A + 1]` — no argument
  copy. The backing stack grows to `callee_base + slot_count`;
  the frame records the stack length on entry
  (`entry_stack_len`) and the caller's `pc` and result slot.
- For a variadic routine, the call machinery (NOT the caller's
  bytecode) builds a list from the excess arguments right-to-left
  and installs it at callee `slot[fixed_arity]`; when
  `argc == fixed_arity` the rest slot holds nil, as in Clojure, so
  `(if more ...)` tests for extra arguments. Slots above it up to
  the callee's window end are reset to nil.
- Point `callee.upvalues` at the closure's upvalue array.
- Dispatch into the callee's entry point (pc 0).
- On callee `return v`: pop the frame, restore the stack length
  recorded on entry, write `v` to caller `slot[C]` and resume
  the caller at the next instruction.

**Compiler invariant — call-clobbered region**: caller values
that must be live across the call **must reside in slots
strictly below `A`**. Slots at and above `A` are
call-clobbered, because the callee's frame windows into the
backing stack starting at `A + 1` and extends through
`callee.routine.slot_count`.

#### `call:tailcall A=call_base B=argc C=ignored`

Reserved: the variant traps `UnimplementedOpcode` and the compiler
never emits it. Its contract, should it be implemented: replace
the current frame in place — slide the arguments from
`slot[A + 1 ..]` down into `slot[0 .. argc)` with
parallel-assignment semantics, switch `routine` and `pc` to the
callee, and perform the same variadic rest-list construction as
`call:call` after the slide. The slide (not a base advance) is
what keeps backing-stack usage bounded across mutual
tail-recursion chains. `recur` does NOT use this opcode (§11).

#### `call:return A=slot _ _` / `call:return-nil _ _ _`

Return `slot[A]` (or nil) from the current frame: pop the frame,
restore the stack length recorded on entry, deliver the value to
the caller's result slot. Returning from the outermost frame
halts the VM with that value as `vm.result`.

`call:apply` and `call:invoke-var` are not defined; `apply` is a
native built on `VM.callValue`.

**Native entry points**: `VM.callValue(callee, args)` invokes any
callable from Zig (used by `map`, `reduce`, `swap!`, `apply`, ...):
a closure by copying the arguments to the top of the stack, entering
it exactly as `call:call` does and running the VM to its return; a
native, a protocol fn or a lookup by calling it directly with its
arguments rooted. `call:call`, `callValue` and `VM.evalClosure`
(which runs a closure in a fresh sub-VM; the macroexpander uses it
for `defmacro` bodies) share one closure entry and one direct call,
so a protocol fn passed to `map` or `apply` behaves as it does in
call position.

---

#### 6.5 Dynamic bindings

A Var whose metadata carries `:dynamic true` (`(def ^:dynamic *x*
1)`; `reset-meta!` and `alter-meta!` set `Var.dynamic`, which is
never cleared) can be rebound for a dynamic extent. The binding in
force lives on the Var itself: `Var.thread_value` with
`Var.thread_bound` set, so a load is one flag test and a Var that
was never bound costs nothing. The VM keeps the save stack:
`vm.dyn_saves` holds, for each Var a frame rebound, the binding it
replaced, and `vm.dyn_frames` the index each frame starts at.

- `VM.pushBindings(vars, values)` (the `push-thread-bindings`
  native, which takes a map of Vars to values): every Var must be
  dynamic, else `NotDynamic` and nothing is rebound; then each is
  saved and set.
- `VM.popBindings()` (`pop-thread-bindings`): restores the innermost
  frame's Vars in reverse order.
- `var-set` (`set!`): writes `thread_value` of a dynamic Var with a
  binding in force; `NotDynamic` / `NoThreadBinding` otherwise. The
  root is written only by `def`.
- `thread-bound?`: whether a binding of the Var is in force.

`binding` (`src/stdlib/core.nx`) evaluates its values in the
bindings outside the form, calls `push-thread-bindings` once, and
runs the body inside `(try ... (finally (pop-thread-bindings)))`, so
a throw through the form restores the previous bindings before the
handler runs. A closure sees the binding in force when it is
called, wherever it was created. The scope is the process (one
thread): a compile-time sub-VM running inside a `binding` extent
sees it too, and `VM.deinit` pops whatever frames a VM abandoned
with an error before its `finally` ran. Every value on the save
stack and every `thread_value` is a collector root (§9).

### 7. Call frame

A **frame** represents one invocation of a routine.

**Frame contents**:

- **Routine pointer**.
- **PC** (bytecode offset into the routine's code).
- **Window**: `base_slot` + `slot_count` into the VM's shared
  backing stack (`vm.stack: ArrayList(Value)`). `slot[i]` is
  `stack[base_slot + i]`.
- **`entry_stack_len`**: the stack length before the window is
  grown; a return or an unwind restores it.
- **Upvalue array**: the closure's upvalue cells (shared with the
  closure; not owned by the frame).
- **Closure** (`closure`): the `.function` Value the frame runs,
  nil for the top-level frame; a root that keeps the closure block,
  and the upvalue array in its tail, alive for the frame's life.
- **Return destination** (`return_dst`, `return_pc`): where the
  caller receives the result and resumes.

Handlers are NOT per-frame: `try` handlers live on one VM-wide
stack keyed by frame index (§12).

**Lifetime**:
- Created on `call:call` (and by `VM.callValue` for native
  re-entry).
- Destroyed on `call:return` / `call:return-nil`, or discarded by
  a throw that unwinds past it.

**Storage discipline**: frames window into one backing stack and
a callee's window overlaps the top of its caller's, so no slice
into `vm.stack.items` may be held across an operation that can
grow it, and no `*Frame` across `vm.frames.append()`. Helpers
(`slotPtr`, `currentFrame`) are one-shot. Frame indices stay valid
across `frames` reallocations because frames only pop from the
top.

---

### 8. Dispatch

Per PLAN §12.5 fallback: a **two-level switch**.

```
loop:
  frame = current frame
  inst = frame.routine.code[frame.pc]; frame.pc += 1
  switch inst.group:                       -- step
    .mov, .cmp, .jump, .var, .math => exec<Group>(frame, inst) -> switch variant
    .call, .closure, .coll, .ctrl  => exec<Group>(inst)        -> switch variant
    .transient, .hash, .tx, .io, .simd => UnimplementedOpcode
    other    => BytecodeCorruption
```

The groups that never push or pop a frame (`mov`, `cmp`, `jump`,
`var`, `math`) resolve their operands through the frame pointer the
fetch took (`resolveIn`, `storeIn`, `slotPtrIn`); the others
re-derive the current frame because a call or a native may have
grown `frames`. The bounds checks are the same on both paths.
`run` drives the loop until the VM halts; `callValue` and
`runRoutine` drive the same loop until the frame they pushed
returns.

**Contract**:
- PC increment happens before handler entry: handlers see the
  already-advanced PC, so a non-taken conditional jump falls
  through by doing nothing and a taken one overwrites `pc`.
- Running off the end of a routine's code is `BytecodeExhausted`.
- A single VM has exactly one dispatch function; per-program
  customization happens via the routine's constant pool.
- Dispatch is not tail-call threaded. The switch is the
  implementation; the semantic contract above is what is frozen.

---

### 9. Memory and the collector

Every runtime value lives on the VM's `Heap` (`VM.ensureHeap`,
backed by `VM.allocator`): closures, upvalue cells, rest-arg lists,
the values `coll:*` builds, everything the natives allocate, and
the string and bignum literals the compiler lowers onto
`registry.heap`, which is the same heap. Vars, namespaces and the
routines live in `VM.runtime_arena` or the compiler's persistent
allocator for the VM's life. `VM.deinit` frees the heap block by
block and the arena wholesale.

**The VM is the collector's host** (`docs/GC.md` §3, §7).
`vm.zig` imports `gc.zig`; `VM.gcRoots` enumerates the roots, in
this order: the whole backing stack (every slot, the conservative
overapproximation that needs no per-PC liveness map), every frame's
closure (whose trace reaches its cells and routine constants, once
however many frames run it) or, for a frame with none, its routine
constants (recursively through nested routines), every Var of every namespace (`root`, `meta`,
`thread_value`), the dynamic-binding stack's saved values, the root
stack (`vm.roots`), pending `finally` throws, `vm.unhandled_throw`,
`vm.result`, and the protocol registry's implementations.
`VM.gcTrace` walks a closure (its cells, then its routine's
constants) and a cell (its value).

**Trigger and safe point.** `VM.gcDue` is checked at the
instruction fetch of `VM.loop`, the one run loop (`run`,
`callValue` and `runRoutine` drive it), and nowhere else: at a loop's first fetch and at every fetch that
follows an instruction of a group that can allocate (`math`,
`call`, `closure`, `coll`, `ctrl`); the fetch after a `mov`, `cmp`,
`jump` or `var` instruction skips the test because the heap's
counter cannot have moved. A cycle is due when the heap has allocated
`gc_next_at` bytes since the last one, `gc_next_at` being the larger
of `gc_threshold` and `gc_growth_percent` percent of the bytes that
survived (`GcPolicy.default`: 16 MiB, 100 %; `GcPolicy.stress`,
selected by `NEXIS_GC_STRESS` in the environment: 4 KiB, 0 %).
`Heap.alloc` never collects, so anything the VM or a native builds
inside one instruction needs no rooting; a native that keeps a
callback's result across a further call back into the VM roots it
on a `VM.RootScope`, and `callValue` roots a native callee's
arguments for the call (`docs/GC.md` §3, §11.5). A VM over a
borrowed heap (`evalClosure`, the `defmacro` evaluation) has
`gc_enabled = false` and never collects. `VM.collectGarbage` runs
one cycle from a safe point, clears the Nextomic query caches
(`nextomic_query_clear`) and sizes the next window; `gc_cycles`
counts them.

---

### 10. Opcode groups

Per PLAN §12.3. Variant numbers and semantic contracts are
authoritative here; the implementation Zig enums use these variant
numbers verbatim.

| # | Group | Dispatched | Notes |
|---|---|---|---|
| 0 | `jump` | yes | Branches (unconditional + conditional). Operand A is always J; operand B is hot-path. |
| 1 | `cmp` | yes | Ordered comparison + numeric equality producing a bool into a slot. |
| 2 | `math` | yes | Fixnum + float arithmetic with contagion. |
| 3 | `mov` | yes | Data movement, load-const, load-true/false/nil. |
| 4 | `call` | yes | `call`, `return`, `return-nil` (`tailcall` traps). |
| 5 | `closure` | yes | `make`, `box-local`, `new-cell`, `init-cell`, `get-cell`. Upvalue **reads** go through the U operand kind on existing opcodes. |
| 6 | `var` | yes | Var load / store / Var object. |
| 7 | `coll` | yes | List / concat / vector / map / set construction from a slot range. Delegates to `src/coll/*.zig`. |
| 8 | `transient` | no — `UnimplementedOpcode` | Transient operations are natives. |
| 9 | `hash` | no — `UnimplementedOpcode` | Hashing and equality are natives over `src/dispatch.zig`. |
| 10 | `tx` | no — `UnimplementedOpcode` | Durable-ref and transaction operations are natives (`docs/DB.md`). |
| 11 | `ctrl` | yes | `try-enter`, `try-exit`, `finally-exit`, `throw` (`halt` traps). |
| 12 | `io` | no — `UnimplementedOpcode` | I/O is natives. |
| 13 | `simd` | no — `UnimplementedOpcode` | The typed-vector kernels are natives in `nexis.simd` (`docs/TYPED_VECTOR.md` §7.2), not opcodes. |

An unrecognized group byte is `BytecodeCorruption`.

#### 10.1 `mov` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `mov:move` | A=slot, B=any-resolvable, _ | `slot[A] := resolve(B)` |
| 1 | `mov:load-const` | A=slot, B=constant, _ | `slot[A] := consts[B.index].value` |
| 2 | `mov:load-nil` | A=slot, _, _ | `slot[A] := nil` |
| 3 | `mov:load-true` | A=slot, _, _ | `slot[A] := true` |
| 4 | `mov:load-false` | A=slot, _, _ | `slot[A] := false` |

Variants 5+ (`load-keyword`, `load-symbol`) are not defined;
keywords and symbols are `Const.value` entries.

#### 10.2 `call` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `call:call` | A=call_base, B=argc-imm, C=result_slot | Range-call ABI per §6 |
| 1 | `call:tailcall` | A=call_base, B=argc-imm, C=ignored | Traps `UnimplementedOpcode` (§6) |
| 2 | `call:return` | A=slot, _, _ | `result := slot[A]`; halt or return to caller |
| 3 | `call:return-nil` | _, _, _ | `result := nil`; halt or return to caller |

#### 10.3 `math` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `math:add` | A=slot, B=any, C=any | `slot[A] := resolve(B) + resolve(C)` over the fixnum/bignum/float tower (SEMANTICS.md §2.2 contagion); an integer result outside i48 is a bignum on the VM's heap. Errors: `:kind-mismatch` |
| 1 | `math:sub` | A=slot, B=any, C=any | subtraction, same tower and errors |
| 2 | `math:mul` | A=slot, B=any, C=any | multiplication, same tower and errors |
| 3 | `math:div` | A=slot, B=any, C=any | `/`: an exact integer quotient stays an integer, otherwise float. Errors: `:divide-by-zero` (integer), `:kind-mismatch` |
| 4 | `math:idiv` | A=slot, B=any, C=any | `quot`: truncated division. Errors: `:divide-by-zero`, `:kind-mismatch` |
| 5 | `math:mod` | A=slot, B=any, C=any | `mod`: floored remainder, sign of the divisor. Same errors as `math:idiv` |
| 6 | `math:pow` | A=slot, B=any, C=any | Traps `UnimplementedOpcode` |
| 7 | `math:neg` | A=slot, B=any, _ | unary negation. Errors: `:kind-mismatch` |
| 8 | `math:abs` | A=slot, B=any, _ | absolute value. Same errors as `math:neg` |

The same tower functions (`numAdd` … `numCompare`) back the
arithmetic natives, so `(+ a b)` through a Var and the inlined
`math:add` agree exactly.

#### 10.4 `cmp` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `cmp:lt` | A=slot, B=any, C=any | `slot[A] := resolve(B) < resolve(C)` |
| 1 | `cmp:lte` | A=slot, B=any, C=any | `<=` |
| 2 | `cmp:gt` | A=slot, B=any, C=any | `>` |
| 3 | `cmp:gte` | A=slot, B=any, C=any | `>=` |
| 4 | `cmp:eq-num` | A=slot, B=any, C=any | `==`: cross-type numeric equality |

Two fixnums compare as integers; any float operand widens both
sides to f64, so `(< 1 1.5)` and `(== 1 1.0)` hold. NaN compares
false under every predicate. A non-numeric operand traps
`:kind-mismatch`. Comparisons live in their own group, NOT in
`math`.

#### 10.5 `closure` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `closure:make` | A=prototype-const, B=cap_desc-imm, C=slot | Descriptor-based closure construction per §6 |
| 1 | `closure:box-local` | A=slot, _, _ | Wrap `slot[A]`'s value in a fresh `UpvalCell{initialized=true}` |
| 2 | `closure:new-cell` | A=slot, _, _ | Allocate uninitialized `UpvalCell{initialized=false}`; store ptr in `slot[A]` |
| 3 | `closure:init-cell` | A=cell_slot, B=any, _ | Fill an uninitialized cell with `resolve(B)`; flip `initialized=true` |
| 4 | `closure:get-cell` | A=slot, B=cell_slot, _ | `slot[A] := *(slot[B] as *UpvalCell)` |

#### 10.6 `jump` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `jump:jmp` | A=jump-target, _, _ | `pc := A.index` |
| 1 | `jump:if-true` | A=jump-target, B=any, _ | `if truthy(resolve(B)) then pc := A.index` |
| 2 | `jump:if-false` | A=jump-target, B=any, _ | `if falsy(resolve(B)) then pc := A.index` (per PLAN §6.2: only nil and false are falsy) |

**Target operand kind requirement**: the jump-target operand `A`
MUST have `kind = .jump`. Other kinds (e.g., `.slot`,
`.constant`) are rejected as `InvalidOperandKind`. This is
stricter than the §4.5 raw-index convention because jump targets
are control-flow critical: accepting a `.slot` target
permissively turns a stale placeholder instruction into a
self-jump that loops forever. The `.jump` requirement turns that
class of corruption into a clean error.

**Target validation timing**: for conditional jumps
(`jump:if-true`, `jump:if-false`), the target operand is
validated only when the branch is **taken**.

**Pre-increment dispatch invariant**: the VM's `run()` loop
increments `frame.pc` BEFORE invoking the handler. Non-taken
conditional jumps therefore "fall through" by simply not
calling `applyJump`. If this invariant ever needs to change
(e.g., for an optimized dispatch loop), the conditional jump
handlers must be revisited.

#### 10.7 `var` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `var:load-var` | A=dst_slot, B=var, _ | `slot[A] :=` the Var's `thread_value` when a `binding` of it is in force (`thread_bound`, §6.5), else its `root`. Traps `:unbound-var` if the Var has never been bound by `def` and has no binding. Equivalent to `mov:move A, v:B`; the dedicated opcode exists for symmetry with `store-var` |
| 1 | `var:store-var` | A=dst_slot, B=var, C=any | `var_table[B.index].root := resolve(C)`, mark bound; `slot[A] :=` the Var object (kind `var_`). Rebinding the same name updates the SAME Var in place (identity-stable), so closures compiled against it see the new root |
| 2 | `var:var-object` | A=dst_slot, B=var, _ | `slot[A] :=` the Var object; does not trap on an unbound Var |

A `Var` carries `root`, `bound` and `macro` (set by `defmacro`,
`docs/MACROEXPAND.md` §1).

#### 10.8 `coll` group variants

All take `A=arg_base B=argc-imm C=dst` and read `argc` values
from `slot[arg_base ..]`:

| Var | Name | Semantics |
|---|---|---|
| 0 | `coll:list` | Build a list right-to-left via `cons` |
| 1 | `coll:concat` | Each arg is a seqable: nil, a list, a vector, a map (its `[k v]` entries) or a set (`:kind-mismatch` otherwise); result is the list of every element left to right, built by collecting the elements then consing right-to-left (no recursive append) |
| 2 | `coll:vector` | `vector.fromSlice` over the range |
| 3 | `coll:map` | Flat `k v k v ...` pairs (`argc` even); later duplicate keys overwrite earlier (Clojure semantics) |
| 4 | `coll:set` | Set from the range; duplicates collapse |

#### 10.9 `ctrl` group variants

| Var | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `ctrl:try-enter` | A=catch_pc (jump), B=binding_slot, C=finally_pc (jump) or unused | Push a `try_` handler (§12) |
| 1 | `ctrl:try-exit` | A=post_pc (jump), _, _ | Normal exit of a try body or catch body (§12) |
| 2 | `ctrl:finally-exit` | _, _, _ | End of a finally body: resume the pending continuation (§12) |
| 3 | `ctrl:throw` | A=any, _, _ | Throw `resolve(A)` (§12) |
| 5 | `ctrl:halt` | _, _, _ | Traps `UnimplementedOpcode` |

---

### 11. `recur` semantics — the hard contract

**Precise wording required, because this is the semantic
foundation users rely on for iteration.**

**User-level**: `(recur arg1 arg2 ...)` re-enters the nearest
enclosing `fn*` or `loop*` body with the given arguments,
WITHOUT growing the call stack.

**Compiler validation** (`COMPILER.md` §4.4):
- `recur` MUST be in tail position of its target.
- `recur`'s arity MUST match the target's binding count; a
  variadic `fn*`'s rest param is one binding and receives the
  seq passed.
- Errors: `RecurOutsideTail`, `RecurArityMismatch`.

**Codegen lowering** (`COMPILER.md` §5.6):
- Evaluate each `arg` into a temporary slot.
- Move temporaries into the target's binding slots using
  **parallel-assignment semantics** (a naive sequential move
  corrupts arguments when the target slots alias an earlier
  source).
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
- `jump:jmp` is a plain PC update.
- No frame allocation, no logical stack growth, no
  backing-stack growth.

**Guarantee**:
- **Constant stack space** is guaranteed unconditionally.
- **Constant heap space per iteration** is guaranteed for
  non-captured loop bindings only. For captured loop
  bindings, fresh-cell-per-iteration allocations are
  semantically required (per §6) and represent O(1) per
  captured binding per iteration — bounded, not zero.
  Allocations the body itself performs are user-observable
  and not part of this guarantee either way.

**Instrumentation**: `VM.stack_high_water` and
`VM.frame_high_water` are updated only on grow operations, so
comparing them before and after a loop gives a TRUE maximum, not
just the final size. The test suite pins a 10k-iteration `recur`
loop leaving both unchanged (`COMPILER.md` §9.4).

---

### 12. try / catch / finally / throw

**Handler stack**: one VM-wide stack (`vm.handlers`) of
`Handler { kind, frame_index, catch_pc, binding_slot, finally_pc?,
finally_depth }` keyed by frame index rather than a list per frame;
`finally_depth` is the length of `vm.finally_stack` when the `try` was
entered. Two kinds:

- `try_` — a `(try body (catch any x handler))` is active:
  a throw routes to `catch_pc` with the value in `binding_slot`.
- `cleanup` — the catch body of a fired `try` is running. It keeps
  the handler's bookkeeping (its `finally_pc`) for the catch
  body's `try-exit` while ensuring a throw from inside the catch
  body is NOT caught by the same handler again.

**`ctrl:try-enter A=catch_pc B=binding_slot C=finally_pc?`**:
push a `try_` handler for the current frame. `catch_pc` and
`finally_pc` are absolute within the current routine; `C` is
`.unused` for a `try` without `finally`.

**`ctrl:try-exit A=post_pc`** (normal exit of the body, or of the
catch body): pop the top handler (`InvalidHandlerState` if the
stack is empty or the top belongs to another frame). If it has a
`finally_pc`, push a `FinallyContinuation{ frame_index, .normal =
post_pc }` and jump to the finally body; otherwise jump to
`post_pc`.

**`ctrl:throw A`** / `VM.throwValue(v)` / `VM.throwKeyword(name)`:
walk the handler stack top-down:
- A `try_` handler catches: discard every frame above the
  handler's frame (restoring the stack length each recorded on
  entry), convert the handler to `cleanup`, store the value in
  `binding_slot`, set `pc = catch_pc`.
- A `cleanup` handler does not catch, but if it has a
  `finally_pc` its finally body runs first with a
  `FinallyContinuation{ .throwing = value }`; the throw resumes
  from `finally-exit`.
- With no handler anywhere: `UncaughtThrow` with the value in
  `vm.unhandled_throw`. The CLI prints the payload with the
  error.

**`ctrl:finally-exit`**: pop the top `FinallyContinuation`
(`InvalidHandlerState` if none, or if it belongs to another
frame). `.normal(pc)` resumes at `pc`; `.throwing(v)` re-throws
`v` from this point. A throw out of a finally body abandons that
body's continuation: the handler that takes any throw first
truncates `vm.finally_stack` to its `finally_depth`, dropping the
continuations of every finally body the throw leaves mid-run, so the
stack is back to where it stood when the catching `try` was entered.

**Matching**: the only matcher is `any`; every throw is caught by
the innermost active `try`. Thrown values are ordinary Values.
A thrown value carries no stack trace and no cause chain; an error
that leaves `run` records the frame chain, with source spans, in
`VM.error_trace` (§13).

**Throws from natives** (`VM.throwValue`, `VM.throwKeyword`):
- A native throws exactly as `ctrl:throw` does: the same handler
  walk, the same unwinding through every frame above the handler's
  (including the synthetic frames `callValue` pushes for host
  callbacks). When a handler catches it the frames and pc are
  already positioned there and the native returns
  `ControlTransferred`, which the run loop resumes from.
- With no handler anywhere the result is `UncaughtThrow` with the
  thrown value in `vm.unhandled_throw`, for every native alike:
  a storage failure outside `try` surfaces as an uncaught
  `:db/key-too-large`, not as a raw `DbError`.

**Catchable VM errors**: a `VmError` in the keyword-mapped set
(§13) raised while a handler is active is converted to its
keyword and thrown through the same path, so
`(try (/ 1 0) (catch any e e))` yields `:divide-by-zero`. Without
a handler the raw Zig error propagates out of `run`.

---

### 13. Execution errors

`VmError` is the VM's Zig error set. Tooling and user code see the
keyword form of the catchable subset.

**Catchable** (keyword-mapped; raised as a thrown keyword when a
handler is active):

| Keyword | When |
|---|---|
| `:kind-mismatch` | An operand of the wrong kind: non-numeric to `math:*` / `cmp:*`, non-seqable to `coll:concat`, wrong kind to a native |
| `:arity-mismatch` | `call:call` (or `callValue`) passes an argument count the callee does not accept |
| `:not-callable` | `call:call` on a value that is not a function, native, protocol fn, keyword, symbol, map, set or vector |
| `:unbound-var` | A `v` operand or `var:load-var` on a Var never bound by `def` |
| `:not-dynamic` | `binding` (`push-thread-bindings`) or `set!` (`var-set`) on a Var not marked `^:dynamic` (§6.5) |
| `:no-thread-binding` | `set!` (`var-set`) on a dynamic Var with no `binding` of it in force (§6.5) |
| `:arithmetic-overflow` | A count or identifier the runtime produces does not fit in a fixnum. No `math:*` opcode or arithmetic native raises it: an integer result outside i48 promotes to a bignum |
| `:divide-by-zero` | `/` with an integer zero divisor, and `quot`, `rem`, `mod` with a zero divisor of either kind (`(/ 1 0.0)` is IEEE infinity; `(mod 1 0.0)` raises, as in Clojure) |
| `:index-out-of-bounds` | `nth` and friends past the end |
| `:db-error`, `:db-closed`, `:invalid-durable-ref`, `:codec-failed`, `:tx-closed` | Storage natives (`docs/DB.md`) |
| `:not-derefable` | `deref` of a value that is not a durable ref, Var or atom |
| `:atom-re-entry` | `swap!` re-entered on the atom it is swapping (`docs/ATOM.md`) |
| `:utf8-error`, `:invalid-argument`, `:io-error`, `:file-not-found`, `:invalid-path` | String and I/O natives |
| `:record-redefinition`, `:not-a-record`, `:no-protocol-impl`, `:no-protocol-method`, `:protocol-redefinition` | Records and protocols (`docs/PROTOCOLS.md`) |
| `:stack-overflow` | A call would push frame number `VM.max_frames` (default 2^20, about a million; an embedder may set it), or a native re-entering the VM (`callValue`, `runRoutine`) finds the native stack past the guard's limit (§13.1). Runaway recursion ends in well under a second instead of growing memory until the process dies; legitimate recursion a hundred thousand calls deep runs |

**Not catchable** (compiler bugs or corrupt bytecode; propagate
out of `run`):

| Error | When |
|---|---|
| `UnimplementedOpcode` | A group/variant that is defined but not executed (§10), an extension instruction, a U-operand store |
| `OperandOutOfRange` | Operand index past the routine's slots / consts / var table |
| `InvalidOperandKind` | Operand kind incompatible with the opcode context (`resolve` of `.unused`, `store` to a constant, non-`.jump` jump target, wrong `Const` variant) |
| `BytecodeExhausted` | `pc` ran past the routine's code |
| `BytecodeCorruption` | Unrecognized group / variant / operand-kind bit pattern; variadic routine with `slot_count < fixed_arity + 1` |
| `CallBlockOutOfRange` | `slot[A + argc]` exceeds the frame's slot count |
| `CaptureCountMismatch` | `closure:make` descriptor source count ≠ child routine's `upvalue_count` |
| `UpvalueOutOfRange` | `U` operand index or `inherited_upvalue` source exceeds the closure's upvalue count |
| `ExpectedCell` | `get-cell` / `init-cell` / `local_cell_slot` found a non-cell in the slot |
| `InvalidCellState` | `box-local` on an already-boxed slot, `init-cell` on an initialized cell |
| `UninitializedCell` | `get-cell` (or U resolve) on a placeholder not yet filled |
| `InvalidHandlerState` | `try-exit` / `finally-exit` with no matching handler or continuation |
| `OutOfMemory` | Allocation failure |

**Control signals** (not errors in the user sense):
`ControlTransferred` (a native's throw has been caught and the run
loop resumes at the handler), `UncaughtThrow` (no handler; value in
`vm.unhandled_throw`). The outermost `return` is no error: it sets
`vm.halted` and `run` returns `vm.result`.

Frames live on the heap, so bytecode recursion costs no native
stack; its depth is bounded by `VM.max_frames`. The native stack is
bounded and guarded (§13.1).

**What the error was about**: where the VM raises an error it can
describe, it writes one sentence to `VM.error_detail` for the host's
report: `f takes 1 argument, got 0`, `first takes 1 argument, got
2`, `g takes at least 2 arguments, got 1` (closures, natives and
protocol methods alike), `an integer is not callable`, `+ expects
numbers, got a string` (the `math:*` and `cmp:*` opcodes), `no impl
of area for a vector`. A value's kind is named as the language
presents it (`kindPhrase`: `nil`, `a boolean`, `an integer`, `a
map`, ...). The detail is empty when the raise site has nothing to
add, as for errors natives raise; `run` clears it on entry and a
handler clears it when it takes the error as a keyword, so it never
describes an earlier error.

**What the VM records when an error leaves `run`**: the frame
chain as it stood, in `VM.error_trace`, innermost first, one
`TraceFrame{name, pc, span, source}` per frame: the routine's
name, the index of the instruction the frame was executing (the
failing instruction for the innermost frame, the `call:call` for
each caller; every frame's `pc` is one past it because the loop
increments before it dispatches), that instruction's span from
the routine's table (null without one) and the routine's
`source`. Neither an untranslated `VmError` nor an uncaught throw
pops a frame, so the chain is complete, including the frames
`callValue` pushed for a closure a native called back. A parked
top frame (one resting on `idle_routine`) is not part of any run
and is left out. `VM.traced_error` names the error the trace was
recorded for. `runRoutine` records the same way when a nested run
fails, so a host that learns of the failure indirectly (the loader
ran a required file while a form was being compiled) reports it
with its chain. A chain longer than 40 frames keeps its innermost 32
and outermost 8 around one marker frame named `<N frames elided>`
(no span, no source), so a runaway recursion reports in 41 lines.
The trace is rebuilt by the next failing run. `resetAfterError` discards
what the failed run left (the frames above the top-level one,
handlers, pending finallys, the unhandled throw) so `retargetTop`
can run the next form; the CLI's REPL calls it after reporting.

#### 13.1 Native stack guard

Bytecode recursion costs no native stack, but Zig code that recurses
once per level of nested input does: reading, expanding and lowering
forms, equality, hashing and comparison, printing, the codec, pull,
transaction expansion, query parsing and rule expansion, and every
native that re-enters the VM through `callValue`. `src/stack.zig`
guards all of it with one address, the lowest frame address a
guarded function may run at:

- `stack.check()` is the first statement of every such function and
  fails with `error.StackOverflow` once the caller's frame lies below
  the limit. A deep input is an error, never a fault.
- `stack.arm(budget)` sets the limit `budget` bytes below the calling
  frame; `stack.armIfUnarmed(budget)` does so only if nothing armed it
  yet. `VM.init` calls `armIfUnarmed(stack.main_thread_budget)`
  (6 MiB), which fits the 8 MiB stack of a process's main thread, the
  one test binaries and embedders run on.
- `bin/nexis` runs the runtime on a thread with a 1 GiB stack, a
  virtual reservation whose pages are committed only when touched, and
  arms the guard at that thread's entry with the stack less a 16 MiB
  margin for unguarded leaf calls.

The VM checks on entry to `callValue` and `runRoutine`, the two ways
a native re-enters it, so recursion through `apply`, `map`, `reduce`,
a protocol impl or `eval` ends in the same catchable `:stack-overflow`
as runaway bytecode recursion. Each layer maps the error to its own
report: the VM raises `StackOverflow`, the reader a reader error, the compiler a compile
error, and a codec decode of bytes nested too deep treats them as
corrupt input.

---

### 14. Interaction with other subsystems

- **`src/value.zig`**: the VM operates on `Value` throughout.
  All slot/constant/upvalue reads produce `Value`s; all stores
  write `Value`s.
- **`src/heap.zig`**: the VM's own `Heap` is backed by
  `VM.allocator`, so a sweep returns memory; it holds every runtime
  value, the ones the VM constructs itself (rest-arg lists, `coll:*`
  results, closures, cells) included.
- **`src/gc.zig`**: the VM is the collector's host (§9).
- **`src/intern.zig`**: one shared `Interner` per VM keeps symbol
  and keyword identity consistent between the compiler, the
  macroexpander and runtime values.
- **`src/dispatch.zig`**: `hashValue` + `equal` for map and set
  construction and for the equality natives; no duplicated
  equality / hash logic in the VM.
- **`src/coll/*.zig`**: `coll:*` delegates directly.
- **`src/protocol.zig`, `src/record.zig`**: per-VM registries;
  `protocol_fn` dispatch in `call:call`.
- **`src/codec.zig`, `src/db.zig`, `src/nextomic/*`**: reached
  only through natives; the VM tracks open connections so
  `VM.deinit` can close them.

---

### 15. Tests

Three layers, paralleling `COMPILER.md` §9:

#### 15.1 Per-opcode unit tests

- `src/vm.zig` inline tests for every dispatched opcode:
  hand-assembled bytecode and error-path coverage for every trap the
  opcode can raise. The single-routine cases are tables of
  `RunCase{code, consts, slots, want}` run by `expectRuns`, which
  also asserts that a run that returns leaves no handler, pending
  finally or frame behind; the closure, cell, var and ctrl tests
  that inspect VM state stay individual.

#### 15.2 Per-group integration tests

- `math` / `cmp`: fixnums, floats, contagion, overflow,
  divide-by-zero, NaN.
- `coll`: list / concat / vector / map / set construction,
  duplicate keys, cross-kind errors.
- `closure`: `closure:make` (descriptor sources from
  `local_cell_slot` and `inherited_upvalue`), `closure:box-local`
  + double-box trap, `closure:get-cell` + `ExpectedCell` /
  `UninitializedCell` traps, `closure:new-cell` /
  `closure:init-cell` placeholder lifecycle, nested closures,
  `letfn*` mutual recursion via placeholder cells, named `fn*`
  self-reference via single placeholder cell, captured loop
  bindings get fresh cells per iteration (the canonical
  `(loop [i 0 acc []] ...)` test from §6 — closures capture
  0/1/2, not 3/3/3).
- `call`: fixed and variadic arity, rest-list construction,
  `:arity-mismatch`, `:not-callable`, keyword / collection
  invocation, natives, `callValue` re-entry.
- `ctrl`: every exit path (normal, caught throw, uncaught throw,
  throw inside finally), throws from natives, catchable
  `VmError`s.

#### 15.3 Full-pipeline tests (shared with `COMPILER.md` §9.3)

- `test/integration/eval_pipeline.zig` and
  `test/integration/runtime_polish.zig`: source → result,
  exercising compiler + VM end-to-end.
- `zig build examples`: every `examples/*.nx` through `bin/nexis`.

#### 15.4 Guarantees the tests pin

- 10k-iteration `recur` loop in constant stack space (§11).
- Deeply nested non-tail calls complete and return correctly.
- `try`/`catch` catches every keyword in the catchable set of §13.

---

### 16. What's intentionally left flexible

- Exact Zig struct layout for `Routine`, `Closure`, `UpvalCell`,
  `Frame`. §5–§7 pin the logical model; code chooses
  representation.
- Frame-stack backing storage beyond the windowing contract (§7).
- Exact dispatch-loop code (§8).
- Per-opcode handler signature. Contract is "handler reads the
  current instruction from the VM and executes its semantics."

---

### 17. Cross-references

- `docs/COMPILER.md` — compiler that emits bytecode for this
  VM (companion).
- `PLAN.md` §12 — ISA physical format + operand kinds + opcode
  groups (higher-level).
- `PLAN.md` §8 — Value model (what the VM manipulates).
- `docs/VALUE.md` — heap kinds; `function` (kind 24) is the
  closure carrier.
- `docs/SEMANTICS.md` — equality / hash / numeric invariants the
  VM must respect.
- `docs/GC.md` — the collector the VM hosts (§9).
- `docs/PROTOCOLS.md` — `protocol_fn` dispatch.
- `docs/TOOLING.md` — the runtime error report built on §13's
  trace and the disassembler that reads §5's tables.
- `../em/docs/architecture/ISA.md` — em's ISA (adapted).
- `../em/docs/architecture/RUNTIME.md` — em's VM runtime
  (adapted).
