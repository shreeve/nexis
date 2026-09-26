## VM.md — runtime: bytecode format + execution contracts

The contract of the nexis virtual machine (`src/vm.zig`), which runs
the bytecode routines the compiler (`docs/COMPILER.md`) emits. It
pins what each opcode does and which invariants the VM upholds:
operand meanings, the logical contents of routines, closures and
frames, the calling and `recur` contracts, and the error taxonomy.
It does not pin Zig struct layout, the dispatch-loop code or handler
signatures; any representation that keeps these obligations is
conforming. The frozen decisions it refines are `PLAN.md` §23 #19
(tail calls), #20 (Vars), #21 (operand kinds) and #33 (keywords
and symbols as functions).

---

### 1. Scope

**In:** the 64-bit instruction encoding (§3); the operand kinds
(§4); routines, closures and upvalue cells (§5, §6); the range-call
ABI and native re-entry (§6); dynamic bindings (§6.5); frames (§7);
two-level switch dispatch (§8); the heap and the collector's host
side (§9); the opcode groups (§10); the `recur` guarantee (§11);
`try` / `catch` / `finally` / `throw` with cross-frame unwinding
shared by bytecode and natives (§12); execution errors, the error
detail and the error trace (§13); the native stack guard (§13.1).
`src/vm.zig` also holds the numeric tower behind `math:*`, `cmp:*`
and the arithmetic natives (`numAdd` … `numCompare`), `lookup` (the
one implementation of `get`, `(:k m)`, `('s m)`, `(m :k)`, `(s x)`
and `(v i)`), namespaces, Vars and the namespace registry.

**Absent:**
- Operand-specialized opcodes and inline caches.
- Executed `transient`, `hash`, `tx`, `io` and `simd` opcodes: the
  group numbers exist and an instruction in one traps
  `UnimplementedOpcode`. Transient, hashing, durable-ref, I/O and
  typed-vector operations are natives.
- A bytecode verifier, object files, tiered compilation.
  `bin/nexis disasm` prints routines (`docs/TOOLING.md` §2); nothing
  checks them before they run.
- Per-PC liveness maps: the whole backing stack is a root (§9).
- Unbounded recursion: the frame chain stops at `VM.max_frames` and
  native re-entry at the stack guard, both with a catchable
  `:stack-overflow` (§13, §13.1).

---

### 3. Physical instruction format

```
Primary instruction (64 bits):
  | kind(4) | group(6) | variant(6) | opA(16) | opB(16) | opC(16) |

Operand (16 bits):
  | kind(4) | index(12) |

Extension instruction (64 bits):
  | kind(4) | extA(20) | extB(20) | extC(20) |
```

- `InstKind` is `primary` (0) or `extension` (1). The extension form
  is defined but never executed: the VM traps `UnimplementedOpcode`
  on one and the compiler never emits one.
- Group and variant together select the handler (64 × 64 address
  space).
- An operand index is 12 bits (0..4095). Every table an operand
  indexes is bounded by it, and the compiler reports the overflow
  (`COMPILER.md` §4.4): more than 4096 constants or capture
  descriptors is `ConstantPoolOverflow`; more than 4096 live slots,
  upvalues or Var-table entries is `SlotOverflow`; a jump to a pc
  past 4095 is `JumpTargetOutOfRange` at the form that needs it.
  Code past pc 4095 that nothing jumps to runs, so the limit is on
  branch targets, not on routine length.

---

### 4. Operand kinds

| # | Letter | Name | Meaning |
|---|---|---|---|
| 0 | `s` | slot | Frame-local slot, `stack[frame.base_slot + index]` |
| 1 | `c` | constant | `routine.consts[index]`, which must be `Const.value` where a value is read |
| 2 | `v` | var | `routine.var_table[index]`: its binding in force, else its root; `:unbound-var` if never bound |
| 3 | `u` | upvalue | The contents of `frame.upvalues[index]` (a cell read, not the cell) |
| 4 | `i` | intern | Reserved: no opcode resolves it (`resolve` traps `UnimplementedOpcode`) |
| 5 | `j` | jump | An absolute pc in the current routine: `jump:*` targets and the pcs of `ctrl:try-enter` / `ctrl:try-exit` |
| 6 | `e` | durable | Reserved: no opcode resolves it (`resolve` traps `UnimplementedOpcode`) |
| 7–14 | | | Unassigned; an operand carrying one is `BytecodeCorruption` |
| 15 | `-` | unused | No operand; `resolve` of it is `InvalidOperandKind` |

`resolve()` accepts `s`, `c`, `v` and `u`: an operand position
documented as "any" takes any of the four. `store()` accepts only
`s`: a store to `c` or `v` is `InvalidOperandKind`, a store to `u`
traps `UnimplementedOpcode` (upvalues are never written, §6).

#### 4.5 Raw immediates

The format has no immediate operand kind. Where §10 says
"immediate", the handler reads the 12-bit `index` as the datum and
ignores the kind bits; assemblers write the kind as `.slot`. The
immediates are operand B of `call:call` / `call:tailcall` (argc),
of `closure:make` (capture-descriptor index) and of every `coll:*`
variant (argc). A jump target is not an immediate: it must carry
kind `j` (§10.6).

---

### 5. Routine

A routine is the compiled code of one `fn*` or top-level form: a
plain Zig struct, not a heap Value, reachable by users only through
the closures that wrap it (§6).

| Field | Contents |
|---|---|
| `code` | The instructions |
| `consts` | Typed constants, `Const = union { value: Value, routine: *const Routine }`. A position that reads a value (`mov:load-const`, any `c` operand) needs `.value`; `closure:make` operand A needs `.routine`; a mismatch is `InvalidOperandKind` |
| `var_table` | The `*Var`s the code references, bound at compile time; `v` operands index it |
| `capture_descs` | The capture descriptors this routine's `closure:make` instructions use to build child closures (§6) |
| `upvalue_count` | The number of cells a closure over this routine carries; `u` operands index them |
| `slot_count` | The frame window size |
| `fixed_arity`, `variadic` | `call:call` requires `argc == fixed_arity`, or `argc >= fixed_arity` when variadic; a variadic routine with `slot_count < fixed_arity + 1` is `BytecodeCorruption` |
| `name` | For reports: `<anonymous>` by default; the compiler names a named `fn` (so a `defn`) after its name and an anonymous one `fn`; the loader names a top-level form `<top>`, `eval` its form `<eval>` |
| `spans`, `origin`, `source` | The span table: `SpanEntry{pc, span}` ascending by pc, one per change of source span, so `spanAt(pc)` (a binary search) gives the `SourceSpan{pos, len}` of the form the instruction was lowered from; `origin` is the routine's own form, `source` the `SourceInfo{path, text}` the spans index (null when unknown). The compiler fills them (`COMPILER.md` §8); a hand-built routine has none. Execution never reads them; the error path (§13) and the disassembler do |

Routines carry no metadata map. Two routines compiled from the same
source are not required to be identical; `=` on two closures
compares identity.

---

### 6. Closure

A closure is a routine plus its captured upvalue cells. Every `fn*`
value at runtime is a closure, with an empty cell array when it
captures nothing. It is a heap block of kind `function` (VALUE.md
kind 24, §2): the body is `Closure{routine, upvalues}` and the
block's tail holds the cell pointers `upvalues` points at, so one
allocation carries the whole closure and the slice stays valid
because the collector never moves a block. `VM.asClosure` reads the
body. The collector traces a closure through its cells and the heap
constants of its routine (§9).

**Upvalue cells.** An `UpvalCell{value, initialized}` is a heap block
of kind `cell_internal`; the `.cell_internal` Value a slot holds and
the `*UpvalCell` a closure or frame holds name the same block. A cell
is written once: at binding time (`box-local`) or at initialization
(`new-cell`, then `init-cell`); `initialized = false` marks a
placeholder (for `letfn*` and a named `fn*`'s self-reference) so a
read before init traps. Closures that capture the same cell share
it. There is no rewrite path.

**Capture.** The compiler knows every closure's capture set
statically, so capture is a side table rather than runtime staging.
A capture descriptor is a list of sources, one per upvalue of the
child:

| Source | Effect |
|---|---|
| `local_cell_slot(s)` | Copy the cell pointer in this frame's `slot[s]` (boxed by `box-local` or `new-cell`); `ExpectedCell` if the slot holds no cell |
| `inherited_upvalue(u)` | Copy this closure's `upvalues[u]`; `UpvalueOutOfRange` past the closure's count |

`closure:make` copies cell pointers, never contents, so closures over
one binding see the same cell, which is how `letfn*` bindings see each
other after init.

**Reading an upvalue** is a `u` operand on any opcode
(`math:add s0, u0, c1`); it dereferences the cell. A `u` operand is
always a cell's contents and a capture source always a cell pointer;
the two never mix. A slot operand never dereferences a cell, so a
boxed local in its defining frame is read with `closure:get-cell`.

**Lowering is the compiler's.** Which bindings are boxed and when
(`box-local` in straight-line code at binding time or function entry,
never lazily before a `closure:make`) is `COMPILER.md` §6.1. A
`recur` that rebinds a captured `loop*` binding installs a fresh cell
per iteration, so closures made in earlier iterations keep their
values; that lowering is `COMPILER.md` §5.6. The VM does nothing
special for either: the opcodes below have no timing requirement
beyond their preconditions.

| Opcode | Operands | Effect | Traps |
|---|---|---|---|
| `closure:make` | A=routine constant, B=descriptor (immediate), C=dst slot | Allocate a closure over `consts[A].routine` with one cell per descriptor source, filled as above; store it in `slot[C]` | `CaptureCountMismatch` when the source count differs from the child's `upvalue_count`; `ExpectedCell`, `UpvalueOutOfRange` |
| `closure:box-local` | A=slot | Replace `slot[A]`'s value `v` with a fresh cell `{v, initialized}` | `InvalidCellState` if the slot already holds a cell |
| `closure:new-cell` | A=dst slot | Store a fresh uninitialized cell in `slot[A]` | |
| `closure:init-cell` | A=cell slot, B=any | Write `resolve(B)` into the cell, mark it initialized | `ExpectedCell`; `InvalidCellState` if already initialized; `InvalidOperandKind` if A is not a slot |
| `closure:get-cell` | A=dst slot, B=cell slot | `slot[A] :=` the cell's value | `ExpectedCell`; `UninitializedCell` |

A `u` resolve of an uninitialized cell is also `UninitializedCell`.

**Range-call ABI.** The caller stages the callee and its arguments
in a contiguous block of its own slots and emits one `call:call`
naming the block (Lua's `CALL A B C`); three 16-bit operands cannot
carry an argument list, and the block makes the call a single
instruction.

`call:call A=call_base B=argc C=result_slot`: `slot[A]` is the callee
and `slot[A + 1 + i]` argument `i`. A and C must be slot operands
(`InvalidOperandKind`); a block past the routine's `slot_count` is
`CallBlockOutOfRange`. The callee kinds, in dispatch order:

- `native_fn`: arity checked against the descriptor's `min_arity` /
  `max_arity` (`:arity-mismatch`), then called with the argument
  slice; the result lands in `slot[C]`.
- `protocol_fn`: dispatched on the first argument's kind or record
  type through the VM's protocol registry (`docs/PROTOCOLS.md`);
  `:no-protocol-impl` on a miss.
- `var_`: the Var's value in force (the binding under `binding`, else
  the root) is called with the same arguments, as Clojure's
  `Var.invoke`; `:unbound-var` while it is unbound.
- `keyword`, `symbol`, `persistent_map`, `persistent_set`,
  `persistent_vector`, `transient`: a lookup with an optional default,
  `(:k m)`, `('s m)`, `(m :k)`, `(s x)`, `(v i)` (`VM.lookup`); a
  symbol looks itself up exactly as a keyword does, and a transient
  map, set or vector as its persistent kind.
- `function` (a closure): the frame transfer below.
- Anything else: `:not-callable`.

A closure call checks `argc` against `fixed_arity` / `variadic`
(`:arity-mismatch`), then pushes a callee frame whose window begins
at the caller's `slot[A + 1]` (`callee_base = caller_base + A + 1`),
so the callee's slot 0 is its first argument and nothing is copied.
The backing stack grows to `callee_base + slot_count`; the frame
records the stack length on entry (`entry_stack_len`), the caller's
pc and the result slot. For a variadic routine the call machinery
builds a list of the excess arguments at `slot[fixed_arity]`, nil
when there are none (so `(if more ...)` tests for extra arguments,
as in Clojure), and resets the slots above it to nil. The frame's
`upvalues` is the closure's cell array; execution starts at pc 0.
On return the frame pops, the stack length is restored, the value
lands in the caller's `slot[C]` and the caller resumes at the next
instruction.

**Call-clobbered region.** Slots at and above A are overwritten by
the callee's window; values live across the call sit strictly below
A (a compiler invariant).

`call:tailcall` traps `UnimplementedOpcode` and the compiler never
emits it; `recur` compiles to a jump (§11). `call:return A` and
`call:return-nil` deliver `slot[A]` or nil: pop the frame, restore
the stack length, write the caller's result slot. Returning from the
outermost frame halts the VM with the value in `vm.result`. There is
no `call:apply`; `apply` is a native over `VM.callValue`.

**Native re-entry.** `VM.callValue(callee, args)` calls any callable
from Zig (`map`, `reduce`, `swap!`, `apply`, ...): a closure by
copying the arguments to the top of the stack, entering it as
`call:call` does and running the loop until that frame returns; a
native, a protocol fn or a lookup by calling it directly with its
arguments rooted. `call:call` and `callValue` share the closure entry
and the direct call, so a protocol fn passed to `map` behaves as it
does in call position. `VM.runRoutine` runs a routine to completion
the same way (the loader and `eval`).

---

#### 6.5 Dynamic bindings

A Var whose metadata carries `:dynamic true` (`(def ^:dynamic *x*
1)`; `reset-meta!` and `alter-meta!` also set `Var.dynamic`, which is
never cleared) can be rebound for a dynamic extent. The binding in
force lives on the Var: `Var.thread_value` with `Var.thread_bound`
set, so a load is one flag test. The VM keeps the save stack:
`vm.dyn_saves` holds, for each Var a frame rebound, the binding it
replaced, and `vm.dyn_frames` the index each frame starts at.

| Native | VM entry | Effect |
|---|---|---|
| `push-thread-bindings` (a map of Vars to values) | `VM.pushBindings` | Every Var must be dynamic, else `:not-dynamic` and nothing is rebound; then each is saved and set |
| `pop-thread-bindings` | `VM.popBindings` | Restore the innermost frame's Vars in reverse order |
| `var-set` (`set!`) | | Write `thread_value` of a dynamic Var with a binding in force; `:not-dynamic` / `:no-thread-binding` otherwise. Only `def` writes the root |
| `thread-bound?` | | Whether a binding of the Var is in force |

`binding` (`src/stdlib/core.nx`) evaluates its values outside the
form, calls `push-thread-bindings` once and runs the body inside
`(try ... (finally (pop-thread-bindings)))`, so a throw through the
form restores the previous bindings before the handler runs. A
closure sees the binding in force when it is called, wherever it was
created. The scope is the process (one thread): a compile-time
sub-VM running inside a `binding` extent sees it too, and
`VM.deinit` pops whatever frames a VM abandoned with an error before
its `finally` ran. Every saved value and every `thread_value` is a
collector root (§9).

### 7. Call frame

| Field | Contents |
|---|---|
| `routine`, `pc` | The routine and the index of the next instruction |
| `base_slot`, `slot_count` | The window into the shared backing stack (`vm.stack`); `slot[i]` is `stack[base_slot + i]` |
| `entry_stack_len` | The stack length before the window grew; a return or an unwind restores it |
| `upvalues` | The closure's cell array (shared, not owned) |
| `closure` | The `.function` Value the frame runs, nil for the top-level frame; a root that keeps the closure block and its cells alive for the frame's life |
| `return_dst`, `return_pc` | Where the caller receives the result and resumes |

A frame is pushed by `call:call` and by `callValue` / `runRoutine`,
and popped by a return or discarded by a throw that unwinds past it.
`try` handlers are not per-frame: they live on one VM-wide stack
keyed by frame index (§12).

**Storage discipline.** Frames window one backing stack and a
callee's window overlaps the top of its caller's, so no slice into
`vm.stack.items` may be held across an operation that can grow it,
and no `*Frame` across `vm.frames.append()`; `slotPtr` and
`currentFrame` are one-shot. Frame indices stay valid because frames
pop only from the top.

---

### 8. Dispatch

A two-level switch: on the group, then in each handler on the
variant.

```
loop:
  if the last instruction could allocate and a cycle is due: collect   (§9)
  frame = current frame
  if frame.pc >= code.len: BytecodeExhausted
  inst = frame.routine.code[frame.pc]; frame.pc += 1
  if inst is an extension: UnimplementedOpcode
  switch inst.group:
    mov, cmp, jump, var, math     => exec<Group>(frame, inst)
    call, closure, coll, ctrl     => exec<Group>(inst)
    transient, hash, tx, io, simd => UnimplementedOpcode
    other                         => BytecodeCorruption
```

The groups that never push or pop a frame (`mov`, `cmp`, `jump`,
`var`, `math`) resolve operands through the frame pointer the fetch
took (`resolveIn`, `storeIn`, `slotPtrIn`); the others re-derive the
current frame because a call or a native may have grown `frames`.
`VM.loop` is the one run loop: `run` drives it until the VM halts,
`callValue` and `runRoutine` until the frame they pushed returns.

- The pc advances before the handler runs, so a handler sees the
  next pc: a conditional jump not taken does nothing, a taken one
  overwrites `pc`, and every frame's `pc` in an error trace is one
  past its instruction (§13).
- Dispatch is a `while` / `switch` loop, not tail-call threading.

---

### 9. Memory and the collector

Every runtime value lives on the VM's `Heap` (`VM.ensureHeap`, backed
by `VM.allocator`): closures, upvalue cells, rest-argument lists, the
values `coll:*` builds, everything natives allocate, and the string
and bignum literals the compiler lowers onto `registry.heap`, the same
heap. Vars, namespaces and routines live in `VM.runtime_arena` or the
compiler's persistent allocator for the VM's life. `VM.deinit` frees
the heap block by block and the arena wholesale.

**The VM hosts the collector** (`docs/GC.md` §3, §7). `VM.gcRoots`
marks, in order: the whole backing stack (every slot, which needs no
per-PC liveness map); each frame's closure (its trace reaches the
cells and routine constants) or, for a frame without one, its
routine's constants, recursively through nested routines; every Var
of every namespace (`root`, `meta`, `thread_value`); the saved
dynamic bindings; the root stack (`vm.roots`); the values of pending
`finally` throws; `vm.unhandled_throw`; `vm.result`; and the
protocol registry's implementations. `VM.gcTrace` traces a closure
(cells, then routine constants) and a cell (its value).

**Trigger and safe point.** `VM.gcDue` is tested only at an
instruction fetch in `VM.loop`: at a loop's first fetch and after an
instruction of a group that can allocate (`math`, `call`, `closure`,
`coll`, `ctrl`); after `mov`, `cmp`, `jump` or `var` the heap's
counter cannot have moved. A cycle is due when the heap has allocated
`gc_next_at` bytes since the last one: the larger of `gc_threshold`
and `gc_growth_percent` percent of the bytes that survived
(`GcPolicy.default` 16 MiB and 100 %; `GcPolicy.stress`, selected by
`NEXIS_GC_STRESS`, 4 KiB and 0 %). `Heap.alloc` never collects, so
what the VM or a native builds within one instruction needs no
rooting; a native that keeps a callback's result across a further
call into the VM roots it (`docs/GC.md` §11.5). A VM over a borrowed
heap (the expander's macro sub-VMs) has `gc_enabled = false`.
`VM.collectGarbage` runs one cycle and sizes the next window;
`gc_cycles` counts them.

---

### 10. Opcode groups

Group and variant numbers are the enums in `src/vm.zig` (`Group`,
`Mov`, `Call`, `Closure_`, `Jump`, `CtrlOp`, `CollOp`, `VarOp`,
`Cmp`, `Math`) and the names the disassembler prints
(`docs/TOOLING.md` §2).

| # | Group | Dispatched | Contents |
|---|---|---|---|
| 0 | `jump` | yes | Unconditional and conditional branches |
| 1 | `cmp` | yes | Ordered comparison and numeric equality into a slot |
| 2 | `math` | yes | Arithmetic over the numeric tower |
| 3 | `mov` | yes | Moves and constant loads |
| 4 | `call` | yes | `call`, `return`, `return-nil` (`tailcall` traps) |
| 5 | `closure` | yes | `make`, `box-local`, `new-cell`, `init-cell`, `get-cell` (§6) |
| 6 | `var` | yes | Var load, store and Var object |
| 7 | `coll` | yes | List, concat, vector, map and set construction from a slot block |
| 8 | `transient` | no | Transients are natives (`docs/TRANSIENT.md`) |
| 9 | `hash` | no | Hashing and equality are natives over `src/dispatch.zig` |
| 10 | `tx` | no | Durable refs and transactions are natives (`docs/DB.md`) |
| 11 | `ctrl` | yes | `try-enter`, `try-exit`, `finally-exit`, `throw` (`halt` traps) |
| 12 | `io` | no | I/O is natives |
| 13 | `simd` | no | Typed-vector kernels are natives in `nexis.simd` (`docs/TYPED_VECTOR.md` §7.2) |

A group number outside the enum is `BytecodeCorruption`; an
undispatched group traps `UnimplementedOpcode`. A variant number
outside its group's enum is `BytecodeCorruption`, except in `mov`
and `call`, where it traps `UnimplementedOpcode`.

#### 10.1 `mov`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `mov:move` | A=slot, B=any | `slot[A] := resolve(B)` |
| 1 | `mov:load-const` | A=slot, B=constant | `slot[A] := consts[B].value` |
| 2 | `mov:load-nil` | A=slot | `slot[A] := nil` |
| 3 | `mov:load-true` | A=slot | `slot[A] := true` |
| 4 | `mov:load-false` | A=slot | `slot[A] := false` |

Keywords and symbols are `Const.value` entries; there is no
`load-keyword`.

#### 10.2 `call`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `call:call` | A=call_base, B=argc (immediate), C=result slot | Range call (§6) |
| 1 | `call:tailcall` | | Traps `UnimplementedOpcode` |
| 2 | `call:return` | A=any | Return `resolve(A)`; halt from the outermost frame |
| 3 | `call:return-nil` | | Return nil |

#### 10.3 `math`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `math:add` | A=slot, B=any, C=any | `+` |
| 1 | `math:sub` | A=slot, B=any, C=any | `-` |
| 2 | `math:mul` | A=slot, B=any, C=any | `*` |
| 3 | `math:div` | A=slot, B=any, C=any | `/`: an exact integer quotient stays an integer, otherwise a float; `:divide-by-zero` for an integer zero divisor |
| 4 | `math:idiv` | A=slot, B=any, C=any | `quot`, truncated; `:divide-by-zero` |
| 5 | `math:mod` | A=slot, B=any, C=any | `mod`, floored (sign of the divisor); `:divide-by-zero` |
| 6 | `math:pow` | | Traps `UnimplementedOpcode` |
| 7 | `math:neg` | A=slot, B=any | Unary `-` |
| 8 | `math:abs` | A=slot, B=any | `abs` |

Every variant but `pow` runs the numeric tower over fixnum, bignum
and float (SEMANTICS.md §2.2 contagion): an integer result outside
i48 is a bignum on the VM's heap, and a non-number is
`:kind-mismatch` with the detail `+ expects numbers, got a string`.
The arithmetic natives call the same tower functions, so `(+ a b)`
through a Var and the inlined `math:add` agree exactly. A float
divisor of zero gives IEEE infinity or NaN for `/`; `quot`, `rem`
and `mod` raise for either kind (`(mod 1 0.0)` raises, as in
Clojure).

#### 10.4 `cmp`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `cmp:lt` | A=slot, B=any, C=any | `<` |
| 1 | `cmp:lte` | A=slot, B=any, C=any | `<=` |
| 2 | `cmp:gt` | A=slot, B=any, C=any | `>` |
| 3 | `cmp:gte` | A=slot, B=any, C=any | `>=` |
| 4 | `cmp:eq-num` | A=slot, B=any, C=any | `==`, cross-type numeric equality |

All five go through `numCompare`: two integers compare exactly, a
float operand widens both sides to f64 (`(< 1 1.5)`, `(== 1 1.0)`),
NaN compares false under every predicate, and a non-number is
`:kind-mismatch`.

#### 10.5 `closure`

| # | Name |
|---|---|
| 0 | `closure:make` |
| 1 | `closure:box-local` |
| 2 | `closure:new-cell` |
| 3 | `closure:init-cell` |
| 4 | `closure:get-cell` |

Operands, effects and traps: §6.

#### 10.6 `jump`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `jump:jmp` | A=jump | `pc := A` |
| 1 | `jump:if-true` | A=jump, B=any | `pc := A` when `resolve(B)` is truthy |
| 2 | `jump:if-false` | A=jump, B=any | `pc := A` when `resolve(B)` is nil or false |

The target must carry kind `j`: any other kind is
`InvalidOperandKind`, so a stale placeholder instruction fails
cleanly instead of jumping to slot 0's index. A target at or past
the end of the code is `OperandOutOfRange`. A conditional jump
checks its target only when taken.

#### 10.7 `var`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `var:load-var` | A=slot, B=var | `slot[A] :=` the Var's `thread_value` when a binding is in force (§6.5), else its root; `:unbound-var` when it has neither. The same as `mov:move A, vB` |
| 1 | `var:store-var` | A=slot, B=var, C=any | The Var's root `:= resolve(C)`, marked bound; `slot[A] :=` the Var object. Redefining a name updates the same Var, so code compiled against it sees the new root |
| 2 | `var:var-object` | A=slot, B=var | `slot[A] :=` the Var object; an unbound Var does not trap |

A `Var` carries `root`, `bound`, `meta`, `macro` (set by `defmacro`,
`docs/MACROEXPAND.md` §1.2), `dynamic`, `thread_value` and
`thread_bound`.

#### 10.8 `coll`

Every variant is `A=arg_base B=argc (immediate) C=dst` and reads
`argc` values from `slot[A ..]`:

| # | Name | Semantics |
|---|---|---|
| 0 | `coll:list` | The list of the values |
| 1 | `coll:concat` | Each value is nil, a list, a vector, a map (its `[k v]` entries) or a set, else `:kind-mismatch`; the result is the list of all their elements left to right. The runtime of syntax-quote's `~@` |
| 2 | `coll:vector` | The vector of the values |
| 3 | `coll:map` | Flat `k v` pairs (`argc` even, else `BytecodeCorruption`); a later duplicate key wins |
| 4 | `coll:set` | The set of the values; duplicates collapse |

Maps and sets hash and compare through `src/dispatch.zig`.

#### 10.9 `ctrl`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `ctrl:try-enter` | A=catch pc (jump), B=binding slot, C=finally pc (jump) or unused | Push a `try_` handler (§12) |
| 1 | `ctrl:try-exit` | A=post pc (jump) | Normal exit of a try or catch body (§12) |
| 2 | `ctrl:finally-exit` | | End of a finally body: resume its continuation (§12) |
| 3 | `ctrl:throw` | A=any | Throw `resolve(A)` (§12) |
| 5 | `ctrl:halt` | | Traps `UnimplementedOpcode` |

Variant 4 is unassigned.

---

### 11. `recur`

`(recur arg...)` re-enters the nearest enclosing `fn*` or `loop*`
body with new bindings without growing the call stack. The compiler
checks that it is in tail position and matches the target's binding
count (a variadic `fn*`'s rest param is one binding and receives the
seq passed), raising `RecurOutsideTail` or `RecurArityMismatch`
(`COMPILER.md` §4.4), and lowers it (`COMPILER.md` §5.6) to a
parallel assignment of the new values into the binding slots (a
fresh cell per captured binding, §6) and a `jump:jmp` to the
target's entry. No call opcode is emitted.

**Guarantee.** A `recur` loop runs in constant stack space: no frame
is pushed and the backing stack does not grow. It allocates nothing
per iteration for bindings no closure captures, and one cell per
captured binding per iteration. What the body allocates is its own.
`VM.stack_high_water` and `VM.frame_high_water` move only on growth,
so a test comparing them around a loop sees the true maximum;
`src/compile.zig` pins a 10k-iteration loop leaving both unchanged.

---

### 12. try / catch / finally / throw

**Handler stack.** One VM-wide stack, `vm.handlers`, of
`Handler{kind, frame_index, catch_pc, binding_slot, finally_pc?,
finally_depth}`, where `finally_depth` is the length of
`vm.finally_stack` when the `try` was entered. Two kinds:

- `try_`: a `try` body is running; a throw routes to `catch_pc` with
  the value in `binding_slot`.
- `cleanup`: the catch body of a fired `try` is running. It keeps the
  handler's `finally_pc` for the catch body's `try-exit` and ensures
  a throw from the catch body is not caught by the same handler.

**`ctrl:try-enter A=catch_pc B=binding_slot C=finally_pc?`** pushes a
`try_` handler for the current frame; the pcs are absolute in the
current routine and C is unused for a `try` without `finally`.

**`ctrl:try-exit A=post_pc`** pops the top handler
(`InvalidHandlerState` if there is none or it belongs to another
frame). With a `finally_pc` it pushes a
`FinallyContinuation{frame_index, .normal = post_pc}` and jumps to
the finally body; otherwise it jumps to `post_pc`.

**`ctrl:throw A`**, `VM.throwValue(v)` and `VM.throwKeyword(name)`
walk the handler stack from the top:
- A `try_` handler catches: every frame above the handler's is
  discarded (each restoring the stack length it recorded), the
  handler becomes `cleanup`, the value goes to `binding_slot` and
  `pc = catch_pc`.
- A `cleanup` handler does not catch, but when it has a `finally_pc`
  its finally body runs first with a
  `FinallyContinuation{.throwing = value}` and the throw resumes from
  `finally-exit`.
- With no handler anywhere the run fails with `UncaughtThrow` and the
  value in `vm.unhandled_throw`.

**`ctrl:finally-exit`** pops the top `FinallyContinuation`
(`InvalidHandlerState` if there is none or it belongs to another
frame): `.normal(pc)` resumes at `pc`, `.throwing(v)` re-throws `v`.
A throw out of a finally body abandons that body's continuation: the
handler that takes it truncates `vm.finally_stack` to its
`finally_depth`, dropping the continuations of every finally body the
throw leaves mid-run.

**Matching.** At the bytecode level the only matcher is `any`: the
innermost active `try` catches every throw. The `try` macro turns
keyword and class-name `catch` clauses into tests on the caught value
and re-throws what no clause takes (`docs/MACROEXPAND.md` §10).
Thrown values are ordinary Values with no stack trace or cause
chain; an error that leaves a run records the frame chain in
`VM.error_trace` (§13).

**Throws from natives.** A native throws exactly as `ctrl:throw`
does, with the same walk and the same unwinding through every frame
above the handler's, including the frames `callValue` pushed for
callbacks. When a handler catches, frames and pc are already
positioned there and the native returns `ControlTransferred`, from
which the run loop resumes. With no handler the result is
`UncaughtThrow`, for every native alike: a storage failure outside
`try` surfaces as an uncaught `:db/key-too-large`, not a raw Zig
error.

**Catchable VM errors.** A `VmError` in the keyword-mapped set (§13)
raised while a handler is active becomes its keyword and is thrown
through the same path, so `(try (/ 1 0) (catch any e e))` is
`:divide-by-zero`. Without a handler the Zig error leaves the run.

---

### 13. Execution errors

`VmError` is the VM's Zig error set. User code and reports see the
keyword form of the catchable subset (`vmErrorToKeywordName`).

**Catchable** (raised as the keyword when a handler is active):

| Error | Keyword | When |
|---|---|---|
| `KindMismatch` | `:kind-mismatch` | An operand of the wrong kind: a non-number to `math:*` / `cmp:*`, a non-seqable to `coll:concat`, a wrong kind to a native |
| `ArityMismatch` | `:arity-mismatch` | A call passes an argument count the callee does not accept |
| `NotCallable` | `:not-callable` | A call on a value that is not a closure, native, protocol fn, Var, keyword, symbol, map, set, vector or transient |
| `UnboundVar` | `:unbound-var` | A `v` operand or `var:load-var` on a Var never bound |
| `NotDynamic` | `:not-dynamic` | `binding` or `set!` on a Var not marked `^:dynamic` (§6.5) |
| `NoThreadBinding` | `:no-thread-binding` | `set!` on a dynamic Var with no binding in force |
| `ArithmeticOverflow` | `:arithmetic-overflow` | A count or identifier the runtime produces does not fit a fixnum; arithmetic never raises it (results promote to bignums) |
| `DivideByZero` | `:divide-by-zero` | `/` with an integer zero divisor; `quot`, `rem`, `mod` with a zero divisor of either kind |
| `IndexOutOfBounds` | `:index-out-of-bounds` | `nth` and friends past the end |
| `DbError`, `DbClosed`, `InvalidDurableRef`, `CodecFailed`, `TxClosed` | `:db-error`, `:db-closed`, `:invalid-durable-ref`, `:codec-failed`, `:tx-closed` | Storage natives (`docs/DB.md`) |
| `NotDerefable` | `:not-derefable` | `deref` of a value that is not a durable ref, Var or atom |
| `AtomReEntry` | `:atom-re-entry` | A mutating atom op re-entered on the atom it is mutating (`docs/ATOM.md`) |
| `TransientUsedAfterPersistent` | `:transient-used-after-persistent` | A transient called or looked up after `persistent!` froze it (`docs/TRANSIENT.md` §6) |
| `Utf8Error`, `InvalidArgument`, `IoError`, `FileNotFound`, `InvalidPath` | `:utf8-error`, `:invalid-argument`, `:io-error`, `:file-not-found`, `:invalid-path` | String, math and I/O natives |
| `NotARecord`, `NoProtocolImpl`, `NoProtocolMethod` | `:not-a-record`, `:no-protocol-impl`, `:no-protocol-method` | Records and protocols (`docs/PROTOCOLS.md`) |
| `StackOverflow` | `:stack-overflow` | A call would push frame number `VM.max_frames` (default 2^20; an embedder may set it); a native re-entering the VM finds the native stack past the guard (§13.1); or `=`, `hash` or printing inside a call or opcode met data nested past the guard (SEMANTICS.md §2.7). Runaway recursion ends in well under a second; legitimate recursion a hundred thousand calls deep runs |

Natives also throw keywords of their own through `throwKeyword` or a
thrown map, documented with the native: `:unserializable`
(`docs/CODEC.md`), the `:db/*` and `:nextomic/*` errors
(`docs/DB.md`, `docs/NEXTOMIC.md`),
`:transient-used-after-persistent` (`docs/TRANSIENT.md`),
`:no-metadata-on-immediate` (`docs/SEMANTICS.md` §7) and
`:no-compiler` (`docs/MACROEXPAND.md` §1.2).

**Not catchable** (compiler bugs or corrupt bytecode; they leave the
run):

| Error | When |
|---|---|
| `UnimplementedOpcode` | A defined but unexecuted group or variant (§10), an extension instruction, an `i`, `j` or `e` operand where a value is read, a store to `u` |
| `OperandOutOfRange` | An operand index past the routine's slots, constants or Var table; a jump target past the code |
| `InvalidOperandKind` | An operand kind the position does not accept: `resolve` of unused, `store` to a constant, a jump target without kind `j`, the wrong `Const` variant |
| `BytecodeExhausted` | `pc` ran past the code |
| `BytecodeCorruption` | An unrecognized group, variant or operand-kind bit pattern (§10); a variadic routine with `slot_count < fixed_arity + 1`; an odd `coll:map` count |
| `CallBlockOutOfRange` | A call block past the frame's slot count |
| `CaptureCountMismatch` | A capture descriptor's source count differs from the child's `upvalue_count` |
| `UpvalueOutOfRange` | A `u` index or `inherited_upvalue` source past the closure's upvalue count |
| `ExpectedCell` | `get-cell`, `init-cell` or a `local_cell_slot` source found no cell |
| `InvalidCellState` | `box-local` on a boxed slot; `init-cell` on an initialized cell |
| `UninitializedCell` | `get-cell` or a `u` resolve of a placeholder not yet filled |
| `InvalidHandlerState` | `try-exit` or `finally-exit` with no matching handler or continuation |
| `OutOfMemory` | Allocation failure |

**Control signals:** `ControlTransferred` (a native's throw was
caught and the loop resumes at the handler) and `UncaughtThrow` (no
handler; the value is in `vm.unhandled_throw`). The outermost
`return` is no error: it sets `vm.halted` and `run` returns
`vm.result`.

Frames live on the heap, so bytecode recursion costs no native
stack; `VM.max_frames` bounds its depth.

**Error detail.** Where the VM can describe an error it writes one
sentence to `VM.error_detail` for the host's report: `f takes 1
argument, got 0`, `g takes at least 2 arguments, got 1` (closures,
natives and protocol methods alike), `an integer is not callable`,
`+ expects numbers, got a string`, `no impl of area for a vector`,
`a value nests too deeply to compare, hash or print`. A value's kind
is named as the language presents it (`kindPhrase`: `nil`, `a
boolean`, `an integer`, `a map`, ...). The detail is empty when the
raise site has nothing to add; `run` clears it on entry and a
handler clears it when it takes the error as a keyword, so it never
describes an earlier error.

**Error trace.** When an error leaves a run the VM records the frame
chain in `VM.error_trace`, innermost first, one
`TraceFrame{name, pc, span, source}` per frame: the routine's name,
the index of the instruction the frame was executing (the failing
instruction innermost, the `call:call` in each caller), that
instruction's span from the routine's table (null without one) and
the routine's `source`. Neither an untranslated `VmError` nor an
uncaught throw pops a frame, so the chain is complete, including the
frames `callValue` pushed for closures a native called back. A
parked top frame (resting on `idle_routine`) is left out.
`VM.traced_error` names the error. `runRoutine` records the same way
when a nested run fails, so a host that learns of the failure
indirectly (the loader ran a required file while compiling a form)
reports it with its chain. A chain longer than 40 frames keeps its
innermost 32 and outermost 8 around one marker frame named `<N
frames elided>` (no span, no source), so a runaway recursion lists
41 lines. The next failing run rebuilds the trace. `resetAfterError`
discards what a failed run left (the frames above the top-level one,
handlers, pending finallys, the unhandled throw) so `retargetTop` can
run the next form; the REPL calls it after reporting. The report
built from the detail and the trace is `docs/TOOLING.md` §1.

#### 13.1 Native stack guard

Bytecode recursion costs no native stack, but Zig code that recurses
once per level of nested input does: reading, expanding and lowering
forms, equality, hashing and comparison, printing, the codec, pull,
transaction expansion, query parsing and rule expansion, and every
native that re-enters the VM through `callValue`. `src/stack.zig`
guards all of it with one address per thread (a `threadlocal`), the
lowest frame address a guarded function may run at on that thread's
stack, so a VM created on any thread checks against its own stack:

- `stack.check()` is the first statement of every such function and
  fails with `error.StackOverflow` once the caller's frame lies below
  the limit. A deep input is an error, never a fault.
- `stack.arm(budget)` sets the limit `budget` bytes below the calling
  frame; `stack.armIfUnarmed(budget)` does so only if nothing armed it
  yet. `VM.init` calls `armIfUnarmed(stack.main_thread_budget)`
  (6 MiB), which fits the 8 MiB stack of a process's main thread, the
  one test binaries and embedders run on.
- `bin/nexis` runs the runtime on a thread with a 1 GiB stack, a
  virtual reservation whose pages are committed only when touched,
  and arms the guard at that thread's entry with the stack less a
  16 MiB margin for unguarded leaf calls.

The VM checks on entry to `callValue` and `runRoutine`, the two ways
a native re-enters it, so recursion through `apply`, `map`, `reduce`,
a protocol impl or `eval` ends in the same catchable `:stack-overflow`
as runaway bytecode recursion. Each layer maps the error to its own
report: the VM raises `StackOverflow`, the reader a reader error, the
compiler a compile error, and a codec decode of bytes nested too deep
treats them as corrupt input.

`=`, `hash` and printing cannot return an error to their many callers,
so past the guard they answer `false`, `0` or `#<too deep>` and count
an overflow (`dispatch.overflowCount`). `callDirect` snapshots the
count around every native call, and `coll:*` around its construction;
a count that moved raises `:stack-overflow` and rewinds the count to
the snapshot, and a native call that fails rewinds it too. An overflow
is therefore reported once, by the innermost call that saw it: a
callback that catches it returns normally through `mapv`, `reduce`,
`swap!` or any other native that called it (SEMANTICS §2.7).

---

### 14. Interaction with other subsystems

- `src/heap.zig`, `src/gc.zig`: §9.
- `src/intern.zig`: one `Interner` per VM keeps symbol and keyword
  identity consistent across the compiler, the macroexpander and
  runtime values.
- `src/dispatch.zig`: `hashValue` and `equal` for map and set
  construction and the equality natives; the VM has no equality or
  hash logic of its own.
- `src/coll/*.zig`: `coll:*` delegates directly.
- `src/protocol.zig`, `src/record.zig`: per-VM registries;
  `protocol_fn` dispatch in `call:call`.
- `src/codec.zig`, `src/db.zig`, `src/nextomic/*`: reached only
  through natives; the VM tracks open `db` and Nextomic connections
  so `VM.deinit` closes them.

---

### 15. Tests

`src/vm.zig` holds the opcode tests: hand-assembled routines
covering every dispatched opcode and every trap it can raise, mostly
as `RunCase{code, consts, slots, want}` tables run by `expectRuns`,
which also asserts that a run that returns leaves no handler,
pending finally or frame behind; the closure, cell, var and ctrl
tests that inspect VM state are individual. `src/compile.zig` pins
the 10k-iteration `recur` loop (§11).
`test/integration/eval_pipeline.zig`, `runtime_polish.zig` and
`numbers.zig` run source through the compiler and VM (captured loop
bindings, `letfn*`, variadic calls, every catchable keyword, error
traces); `test/golden/cli/*` pin the reports and `zig build examples`
runs every example.

---

### 17. Cross-references

- `docs/COMPILER.md`: the compiler that emits this bytecode;
  capture and `recur` lowering (§5.6, §6.1).
- `PLAN.md` §23 #19, #20, #21, #33: the frozen decisions.
- `docs/VALUE.md`: kinds; `function` (24) carries closures.
- `docs/SEMANTICS.md`: equality, hash and numeric rules the VM
  respects.
- `docs/GC.md`: the collector the VM hosts (§9).
- `docs/PROTOCOLS.md`: `protocol_fn` dispatch.
- `docs/TOOLING.md`: the runtime error report (§1) and the
  disassembler (§2).
