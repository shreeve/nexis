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
threaded dispatch through a handler table (§8); the heap and the collector's host
side (§9); the opcode groups (§10); the `recur` guarantee (§11);
`try` / `catch` / `finally` / `throw` with cross-frame unwinding
shared by bytecode and natives (§12); execution errors, the error
detail and the error trace (§13); the native stack guard (§13.1).
`src/vm.zig` also holds the numeric tower behind `math:*`, `cmp:*`
and the arithmetic natives (`numAdd` … `numCompare`), `lookup` (the
one implementation of `get`, `(:k m)`, `('s m)`, `(m :k)`, `(s x)`
and `(v i)`), namespaces, Vars and the namespace registry.

**Absent:**
- Inline caches. Operand-specialized opcodes are the quickened
  variants (§10.10).
- Executed `transient`, `hash`, `tx`, `io` and `simd` opcodes: the
  group numbers exist and an instruction in one traps
  `UnimplementedOpcode`. Transient, hashing, durable-ref, I/O and
  typed-vector operations are natives.
- Object files and tiered compilation. `bin/nexis disasm` prints
  routines (`docs/TOOLING.md` §2); `Routine.verify` checks each one
  before it runs (§5).
- Per-PC liveness maps: the whole backing stack is a root (§9); the
  compiler clears a local's slot at its last move instead
  (`mov:move-clear`, §10.1; `docs/COMPILER.md` §4.9).
- Unbounded recursion: the frame chain stops at `VM.max_frames` and
  native re-entry at the stack guard, both with a catchable
  `:stack-overflow` (§13, §13.1).

---

### 3. Physical instruction format

```
Instruction (64 bits):
  | kind(4) | group(6) | variant(6) | opA(16) | opB(16) | opC(16) |

Operand (16 bits):
  | kind(4) | index(12) |

Wide field W (32 bits): opB and opC read as one number, opB the low half
  | kind(4) | group(6) | variant(6) | opA(16) | W(32) |
```

- `InstKind` has one value, `primary` (0); an instruction of any
  other kind is `BytecodeCorruption`.
- Group and variant together select the handler (64 × 64 address
  space).
- An operand index is 12 bits (0..4095). It addresses a frame's
  slots, a closure's upvalues, and the first 4096 constants and
  Var-table entries in place.
- An instruction that names a pc or a table entry carries it in W:
  every jump target (`jump:*`) and `ctrl:try-exit`'s continuation, the
  `try` of `ctrl:try-enter` (whose entry holds the catch and finally
  pcs), the constant of `mov:load-const`, the Var of `var:*` and the
  capture descriptor of `closure:make`. A routine's code, constants,
  Var table, tries and capture descriptors are therefore bounded only
  by 2^32 entries; a constant or Var past the
  operand range is read through `mov:load-const` or `var:load-var`
  into a slot (`COMPILER.md` §4.4).
- Slots and upvalues are addressed only by operands: a routine has at
  most 4096 slots live at once and 4096 upvalues, the compile error
  `SlotOverflow`, whose detail names the routine and the limit.

---

### 4. Operand kinds

| # | Letter | Name | Meaning |
|---|---|---|---|
| 0 | `s` | slot | Frame-local slot, `stack[frame.base_slot + index]` |
| 1 | `c` | constant | `routine.consts[index]` |
| 2 | `v` | var | `routine.var_table[index]`: its binding in force, else its root; `:unbound-var` if never bound |
| 3 | `u` | upvalue | The contents of `frame.upvalues[index]` (a cell read, not the cell) |
| 4 | `i` | intern | Reserved: no opcode resolves it (`resolve` traps `UnimplementedOpcode`) |
| 6 | `e` | durable | Reserved: no opcode resolves it (`resolve` traps `UnimplementedOpcode`) |
| 5, 7–14 | | | Unassigned; an operand carrying one is `BytecodeCorruption` |
| 15 | `-` | unused | No operand; `resolve` of it is `InvalidOperandKind` |

`resolve()` accepts `s`, `c`, `v` and `u`: an operand position
documented as "any" takes any of the four. `store()` accepts only
`s`: a store to `c` or `v` is `InvalidOperandKind`, a store to `u`
traps `UnimplementedOpcode` (upvalues are never written, §6).

#### 4.5 Raw immediates

The format has no immediate operand kind. Where §10 says
"immediate", the handler reads the 12-bit `index` as the datum and
ignores the kind bits; assemblers write the kind as `.slot`. The
immediates are operand B of `call:call`, `call:tailcall` and
`call:self` (argc) and of every `coll:*` variant (argc). A pc or table index is not an
immediate: it is the wide field (§3).

---

### 5. Routine

A routine is the compiled code of one `fn*` or top-level form, or of
one clause of a multi-arity `fn*`: a plain Zig struct, not a heap
Value, reachable by users only through the closures that wrap it
(§6).

| Field | Contents |
|---|---|
| `code` | The instructions |
| `consts` | The constant pool, Values; `c` operands address its first 4096 entries, `mov:load-const` any |
| `var_table` | The `*Var`s the code references, bound at compile time; `v` operands address its first 4096 entries, `var:*` any |
| `capture_descs` | What this routine's `closure:make` instructions build: each descriptor names a child routine and where its upvalue cells come from (§6) |
| `tries` | One `Try{catch_pc, finally_pc?}` per `try` form, named by `ctrl:try-enter` (§12): a handler needs two pcs and an instruction carries one wide field, so they live here, as the capture sources of a `closure:make` do |
| `upvalue_count` | The number of cells a closure over this routine carries; `u` operands index them |
| `slot_count` | The frame window size |
| `fixed_arity`, `variadic` | The routine takes `argc == fixed_arity` arguments, or `argc >= fixed_arity` when variadic; a variadic routine with `slot_count < fixed_arity + 1` is `BytecodeCorruption` |
| `arities` | For a clause of a multi-arity `fn*`, the arity table every clause shares, `Arities{fixed, rest}`: `fixed[i]` the clause taking exactly `i` arguments (null where none does), `rest` the clause with a rest parameter (null when none has one); null for a routine with one arity. A call picks the member by its count (§6) |
| `name` | For reports: `<anonymous>` by default; the compiler names a named `fn` (so a `defn`) after its name and an anonymous one `fn`; the loader names a top-level form `<top>`, `eval` its form `<eval>` |
| `spans`, `origin`, `source` | The span table: `SpanEntry{pc, span}` ascending by pc, one per change of source span, so `spanAt(pc)` (a binary search) gives the `SourceSpan{pos, len}` of the form the instruction was lowered from; `origin` is the routine's own form, `source` the `SourceInfo{path, text}` the spans index (null when unknown). The compiler fills them (`COMPILER.md` §8); a hand-built routine has none. Execution never reads them; the error path (§13) and the disassembler do |

Routines carry no metadata map. Two routines compiled from the same
source are not required to be identical; `=` on two closures
compares identity.

**Arity tables.** Each clause of a multi-arity `fn*` is an ordinary
routine with its own code, constants, Var table, captures, tries and
spans, and the clauses share one table. The closure names the first
clause in source order, the head; the others are reached only through
the table. Every member carries the same `upvalue_count`, so one
closure's cells serve them all, and the same name and source, so a
trace through any of them names the function. A one-clause `fn*` has
no table. A member proves the table's shape when it is verified: it
sits in the table at `fixed[fixed_arity]`, or at `rest` when variadic;
every member points at the same table and has its `upvalue_count`;
each `fixed[i]` is null or a routine without a rest parameter whose
`fixed_arity` is `i`, and the last is not null; `rest` has a rest
parameter and a `fixed_arity` at least every fixed member's (Clojure's
rule); and the table has two members at least. The table is what the
call path trusts to pick a member (§6, §8).

**Verified before it runs.** `Routine.verify` proves a routine, the
other members of its arity table, and every routine their capture
descriptors build, fit to run: its arity table one a call can pick
from (above); every
instruction `primary` with an assigned opcode (a defined but
unexecuted one, §10, passes and traps where it runs); every operand
inside the table it indexes (a slot below `slot_count`, a constant,
a Var, an upvalue below `upvalue_count`), a destination a slot and
`mov:move-clear`'s source a slot;
every wide field inside its table, a jump target, a `try`'s catch and
finally pcs and `ctrl:try-exit`'s continuation inside the code; every
`call:call` and `coll:*` block, every `call:self`'s arguments and
every `call:lookup-or`'s two slots inside the frame; every
`call:self`'s count a fixed arity of the routine's arity table, the
routine's own when it has no rest parameter or a sibling's
`fixed[count]`, never a count only a rest clause takes; every `call:lookup` and `call:lookup-or` key a
keyword or symbol constant; every quickened instruction's operands of
the kinds its form promises, a fixnum constant holding a fixnum, a
comparison quickened with its jump followed by that jump on its
slot, and a step followed by the comparison it names reading its
slot (§10.10); every capture
descriptor's sources inside the frame and the routine's upvalues, as
many as the child's `upvalue_count`; and the last instruction one
that never falls through (`jump:jmp`, `call:return`,
`call:return-nil`, `ctrl:throw`, `ctrl:try-exit`,
`ctrl:finally-exit`), so execution cannot run off the code. `run` and
`runRoutine` verify the routine they run as a top-level frame, which
has no upvalues, and so every routine a closure built under it can
be; a routine that fails runs nothing, and its error leaves `run` or
`runRoutine` with a one-frame trace naming the instruction (§13). The
stdlib image's loader verifies each routine it loads in debug and safe
builds, and the image a release build loads is the one the build's
generator loaded and verified (`docs/STDLIB.md` §1). The dispatch
trusts what verification proved (§8). A routine is verified once,
not at every closure made over it: `closure:make` builds a closure
from a descriptor of a routine verified with every routine under it
and every member of its table, and the image loader, which makes each
closure before the routine it runs is read, verifies every routine,
each member of a table among them (`verifyAlone`, each once, the
table's shape with it), when the image is whole. Verification never traps: a routine longer than a
pc can name is `BytecodeCorruption` before any of it is read, and
verification reached past the stack guard, as by capture descriptors
that lead back to their own routine, which no compiler makes, is the
guard's `StackOverflow` (§13.1), its trace naming the routine.

---

### 6. Closure

A closure is a routine plus its captured upvalue cells. Every `fn*`
value at runtime is a closure, with an empty cell array when it
captures nothing. It is a heap block of kind `function` (VALUE.md
kind 24, §2): the body is `Closure{routine, upvalues}` and the
block's tail holds the cell pointers `upvalues` points at, so one
allocation carries the whole closure and the slice stays valid
because the collector never moves a block. `VM.asClosure` reads the
body. A multi-arity `fn*`'s closure names the head of its arity table
(§5) and runs whichever member a call picks. The collector traces a
closure through its cells and the heap constants of its routine and
every member of its table (§9).

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
A capture descriptor names the child routine and lists its sources,
one per upvalue of the child:

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
| `closure:make` | A=dst slot, W=capture descriptor | Allocate a closure over descriptor W's routine with one cell per source, filled as above; store it in `slot[A]` | `CaptureCountMismatch` when the source count differs from the child's `upvalue_count`; `ExpectedCell`, `UpvalueOutOfRange`; `OperandOutOfRange` for W past the table |
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
  `Var.invoke`: `(#'inc 1)` is 2; `:unbound-var` while it is unbound.
  A closure there takes the frame transfer below, so a recursion
  through `#'f` costs no native stack.
- `keyword`, `symbol`, `persistent_map`, `persistent_set`,
  `persistent_vector`, `sorted_map`, `sorted_set`, `transient`: a
  lookup with an optional default,
  `(:k m)`, `('s m)`, `(m :k)`, `(s x)`, `(v i)` (`VM.lookup`); a
  symbol looks itself up exactly as a keyword does, and a transient
  map, set or vector as its persistent kind. A set, as `get` of one,
  gives back the element it holds equal to `x`, which may differ from
  `x` (`(#{'(1)} [1])` is `(1)`), as Clojure's does.
- `function` (a closure): the frame transfer below.
- Anything else: `:not-callable`.

A closure call first picks the routine it enters: the closure's own
when its fixed arity is `argc` and it has no rest parameter, else the
member `fixed[argc]` of its arity table, else the rest clause (the
closure's own routine when it has no table) when `argc` reaches its
`fixed_arity`. A count nothing takes is `:arity-mismatch`, raised in
the caller before any frame is pushed, its detail naming every count
the closure takes (§13). The call then pushes a callee frame running
that routine, whose window begins
at the caller's `slot[A + 1]` (`callee_base = caller_base + A + 1`),
so the callee's slot 0 is its first argument and nothing is copied.
The backing stack grows to `callee_base + slot_count`; the frame
records the stack length on entry (`entry_stack_len`) and the result
slot, and the caller's own `pc`, which nothing changes while the
callee runs, holds its return point. A closure carries one cell for
each upvalue of its routine (`closure:make` of a verified descriptor
builds it so, and the stdlib image's loader checks its closures when
it verifies its routines), so a call does not count them; every
member of a table carries the same count (§5). For a routine with a
rest parameter the call machinery
builds a list of the excess arguments at `slot[fixed_arity]`, nil
when there are none (so `(if more ...)` tests for extra arguments,
as in Clojure), and resets the slots above it to nil. The frame's
`upvalues` is the closure's cell array; execution starts at pc 0.
On return the frame pops, the stack length is restored, the value
lands in the caller's `slot[C]` and the caller resumes at the next
instruction.

`call:self A=window B=argc C=result_slot` is that call of the frame's
own closure, the compiler's lowering of a `fn*` calling its self-name
(`COMPILER.md` §5.5): the arguments are `slot[A + i]`, the callee's
window begins at `slot[A]`, and there is no callee to read or test.
Verification proved `argc` a fixed arity of the routine's table (§5),
so the call enters the frame's own routine when `argc` is its fixed
arity and it has no rest parameter, else the table's `fixed[argc]`, a
clause of the same fn calling another, with no further test. It
checks only the frame chain and the stack, and traps as a closure
call does (`StackOverflow` at
`VM.max_frames`, `OutOfMemory`). The new frame shares the caller's
closure and cells. The top-level frame,
which runs no closure, has none to call: `BytecodeCorruption`.

`call:lookup A=dst B=target C=key` and `call:lookup-or A=dst B=slot
C=key` are the call of a keyword or symbol constant, `(:k x)` and
`(:k x default)`, in one instruction (`COMPILER.md` §4.3): the target
is `resolve(B)`, or `slot[B]` with the default in `slot[B + 1]`, and
the result is the lookup `call:call` makes of that callee with those
arguments, with the same errors and error detail. On a map, a record
or nil it looks itself up in place (§8); on anything else it goes
through the general entry, the target rooted while a sorted
collection's comparator runs.

**Call-clobbered region.** Slots at and above A are overwritten by
the callee's window; values live across the call sit strictly below
A (a compiler invariant).

**After the call.** The compiler never reads a block after its call
(`COMPILER.md` §4.4), so a call of anything but a closure or a leaf
clears its block before the result lands in `slot[C]`: the arguments
of a native called in place (§8), whose callee is a native and holds
no heap value, and the whole block of a call through the general
entry (a protocol fn, a Var, a lookup, a native past the in-place
cases). A sequence a native was given is then not kept alive by the
block until a later call reuses its slots. A leaf's block, an
in-place keyword lookup's and `call:lookup-or`'s two slots are left
as they are: they hold what a
leaf takes (numbers, a vector to index), and clearing them would
cost every arithmetic call. A closure's arguments are its own slots
and stay as its body leaves them; clearing its window's overlap with
the caller's frame on return cost 5% of a call (`docs/PERF.md` §6).
A native that consumes its last argument (`NativeFn.consumes`) has
that argument's slot cleared before the call, once the arguments are
copied: it roots the argument itself and lets the part of a lazy seq
it has walked go (`docs/GC.md` §11.5). A leaf that consumes (`count`)
is called in place, clearing nothing, unless its leaf body refuses
the receiver: a lazy seq goes the general way, which clears the slot.

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

**Repeated calls.** A native that calls one callee once per element
with the same argument count (`map` over one collection, `filter`,
`remove`, `keep`, `reduce`, `group-by`) calls it through a
`vm.Callback`, which
makes before its first call the decisions `callValue` makes at every
one and cannot change between calls from the same place: the callee's
kind, its arity against the count (for a closure, the routine with a
fixed arity, its own or a member of its table, the count enters), and
for a closure the stack guard
(§13.1), the frame cap and the room the frame chain and the stack
need, since every call starts from the frame depth and stack length
the first one finds. Each call of a closure writes the
arguments and nil locals into the window at that stack length (one or
two arguments, `call1` and `call2`, are stored straight from the
native's registers; the locals are nil'd four at once, past the window
when it is shorter, where the slots are dead), pushes
the frame built at the first call and runs it as the loop would: the
loop's depth and nesting are set, the safe point of the loop's entry
taken, and the chain entered at the callee's first instruction, the
frame the loop's first pass would run, so the pass needs no test. A
pass that ends without an error has returned, or a throw went past the
frame, which leaves the result cell unfilled (`ControlTransferred` to
the native, §12); one that ends with an error goes on to the loop,
which takes the error as its own pass would (§8, §12). The frame built at the first call returns into a
result cell of the `Callback`'s own, so a call sets one flag in it
rather than making a cell, and the native reads the value back a word
at a time, the width the return stored it (§8); a callee that
re-enters the native makes a `Callback`, and a cell, of its own. A
call that finds the depth or the length changed
goes through `callValue`. A leaf native is called as `callValue` calls it,
past the leaf call once its leaf body refuses the receiver, and a
keyword or symbol given one argument that is a map, a record or nil
looks itself up in place (§8); any other callee, a closure the count
enters at a rest clause, and any callee whose arity the count does not
fit, goes through `callValue` every time, so
the results, errors, error details, traces and rooting are
`callValue`'s.

**Batched calls.** A native that calls a closure once per element of
a run it holds calls it through `Callback.each` (`out[i] = (f
items[i])`), `fold` (`acc = (f acc items[i])`) or `foldRange` (the same
over an unrealized range or `repeat`, whose elements are computed),
which make the run's calls in one pass of the chain, starting with the
first element's prepared call as above. The return of each element's
frame into the callback's cell goes on in that frame: its result goes
to its place (`each`'s into a block a root reaches, a buffer only
tested for truth, or a root-stack region by index; `fold`'s
accumulator into the window's first slot, as the next call's
argument), the next element's arguments and nil locals go into the
window, the frame stays as the first call pushed it (nothing a call
runs changes a frame but its `pc`), the safe point a call's entry is
taken, and the chain goes on at the callee's first instruction, which
the first call looked up, so the native is re-entered once per run
rather than once per element. `fold` and `foldRange` end the pass after a
result that is a record, which the native tests for `reduced`. Every
element is still a call of its own, with a frame of its own: the pop
of one element's and the push of the next one's are fused, at the same
depth, with the same routine, base, upvalues and closure, so `PLAN.md`
§23 #19 holds, and a trace, `:stack-overflow` (checked at the first
call, the depth constant), dynamic bindings and `try` handlers (keyed
by frame index) are what one call per element gives. An element's
error goes on to the loop as a prepared call's does: caught inside the
callee, the callee returns and the pass goes on inside the loop;
caught below the native, the throw unwinds past the frame and the
native's call ends with `ControlTransferred`; with no handler, the
frame stands at the failing instruction. A callee that is not a
closure the count enters at a fixed arity, or a run that finds the
depth or the stack length changed, gets one `call` per element, with
its results, errors and rooting.

**Leaf natives.** A native whose descriptor sets `NativeFn.leaf`
never re-enters the VM and never compares, hashes or prints nested
data (arithmetic, numeric and kind predicates, the lookups below), so
nothing under it can collect, grow the stack or move the spoil count
(§13.1).
`call:call` passes it its arguments in place on the stack, and
`callValue` and a `Callback` call it without the root scope, the stack
guard or the overflow check while no cycle is due; once one is, the
call takes `callValue`'s rooted path and its safe point, so a native
that calls a leaf per element (`(reduce * xs)`) collects as it goes.
Its arity is checked, and reported, as any native's. A leaf may
allocate (`conj` onto a vector): `Heap.alloc` never collects (§9), and
the call site reaches a safe point after it, `call:call` at the next
fetch and `callValue` and a `Callback` by taking the rooted path once a
cycle is due.
A leaf may refuse a receiver it could handle only by running code or
walking nested data. Its leaf body returns the internal
`VmError.NeedsReentry` before it touches anything, and the three leaf
call sites (`call:call`'s in-place path, `callValue`'s and a
`Callback`'s) re-issue the call through the general path, arguments
copied off the stack and rooted, which runs the descriptor's `general`
body instead of `call`. The error never escapes a call site.

| Leaf | What it refuses |
|---|---|
| `nth` | a lazy seq, whose walk realizes it (`docs/LAZY.md` §4) |
| `get` | a sorted collection (its comparator), a Nextomic entity (the store), and a hash map, set, record or transient searched by a key on the heap (its hash and `=` may realize a lazy seq or walk nested data) |
| `count` | a lazy seq (realized to its end) and a Nextomic entity |
| `nthnext` | anything but nil, a list and a vector |
| `conj` | anything but nil, a list and a vector (a map or set hashes, a lazy seq is realized) |
| `assoc` | anything but a vector, nil, a hash map and a record, and any of the last three by a key on the heap |
| `assoc!` | anything but a transient vector and a transient map, and the map by a key on the heap |
| `str` | anything but nil, a string, a char and a fixnum (printing walks it) |

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
| `thread-bound?` | | Whether a binding of each Var given is in force; true of none |
| `bound?` | | Whether every Var given has a value, its root or a binding in force, as Clojure's `Var.isBound`; true of none |

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
| `routine`, `pc` | The routine and the index of the next instruction, written when a handler calls out, pushes a frame, raises or ends the dispatch chain (§8); between those the pc is a handler argument. Under a frame it called, the caller's `pc` is its return point. A frame running a closure runs the member of its arity table the call picked (§6), which may differ from the closure's routine, the head |
| `base_slot` | The window into the shared backing stack (`vm.stack`): `slot[i]` is `stack[base_slot + i]` for `i` below the routine's `slot_count` |
| `entry_stack_len` | The stack length before the window grew; a return or an unwind restores it |
| `upvalues` | The closure's cell array (shared, not owned) |
| `closure` | The `.function` Value the frame runs, nil for the top-level frame; a root that keeps the closure block, its cells and every member of its routine's table alive for the frame's life |
| `return_dst` | Where the caller receives the result |
| `host_result` | For a frame `callValue`, `runRoutine` or a `Callback` pushed: the cell its return writes instead of a caller's slot (`HostCallResult`) |

A frame is 64 bytes, one cache line. It is pushed by `call:call` and
by `callValue` / `runRoutine`, and popped by a return or discarded by
a throw that unwinds past it.
`try` handlers are not per-frame: they live on one VM-wide stack
keyed by frame index (§12).

**Storage discipline.** Frames window one backing stack and a
callee's window overlaps the top of its caller's, so no slice into
`vm.stack.items` may be held across an operation that can grow it,
and no `*Frame` across `vm.frames.append()`; `slotPtrIn` and
`currentFrame` are one-shot. Frame indices stay valid because frames
pop only from the top.

---

### 8. Dispatch

Threaded code through two handler tables, each indexed by group and
variant together (`group | variant << 6`, 4096 entries). A handler
runs its instruction, then fetches the next one itself and tail-calls
that instruction's handler (`@call(.always_tail, ...)`), so an
instruction costs one indirect branch and the native stack does not
grow with the instructions run. A handler is called with the VM, the
frame, the instruction and `pc`, the index of the instruction after
it, which stays in a register from handler to handler, and returns a
status word, an `enum(u16)`: `ok` when the chain ends with no error,
else the number of the `VmError` it ends with, which the loop turns
back into the error. An error union cannot be the return type of a
calling convention but Zig's `.auto`.

```
fetch at pc (every handler's last step):
  inst = frame.routine.code[pc]
  tail-call fast_table[inst.group | inst.variant << 6](vm, frame, inst, pc + 1)
```

The fetch checks nothing: verification (§5) proved every pc it can
reach inside the code and every instruction `primary`, and the fast
handlers read their operands, jump and fill call blocks without the
bounds verification proved. The general handlers keep their checks.
Debug and safe builds assert what verification proved; a release
build neither checks nor assumes it, since an assumed bound read
through the frame's routine changes the fast handlers' code for the
worse (`docs/PERF.md` §3.21).
A fast handler reads a slot's value as two whole 8-byte words, never
its kind byte alone or both words in one 16-byte load: a load inside
one store in flight takes its data from the store, and any other, a
16-byte load of two 8-byte stores among them, waits for them to reach
the cache, which a loop carrying a value from slot to slot would pay
at every instruction. A native's compiled code reads a whole value, an
argument among them, with one 16-byte load. So on x86-64 a value a
native may read whole is stored whole, as one 16-byte store: the moves,
constant, cell and upvalue loads that fill a call's block, and a call's
result (`VM.storeWide`). A value whose next reader is a handler on the
dispatch's chain is stored as two 8-byte words, which its 8-byte loads
take a cycle sooner than from a 16-byte store: a Var's value (a
callee), a return, a callback's window and its results. The rest of
the native boundary keeps the same widths on x86-64: a native's
result, returned through memory, is read a word at a time where the
call stores it (`call:call`, the buffered and the general call,
`call:lookup`, `coll:*`; `VM.storeResult`); the arguments a buffered
or general call and a collection's construction copy off the stack are
copied a value at a time, a map's key and value as one 32-byte entry,
the width its constructor reads, which a target without AVX (the
release's `x86_64_v2`) stores as two 16-byte halves (`VM.copyRun`,
`VM.copyEntries`).
A native returns its result through memory by a `return` of a value
it holds, or of an error, which stores it in place: a result merged
from an `if`, a `switch`, an `orelse` or a labeled block, or returned
from a call of another native's body, is assembled in a temporary of
narrow stores and copied on with an 8-byte load of the error's word
and a 16-byte load of the value, which wait for those stores. So
`count`, `nth` and `nthnext`, the leaves a destructuring form calls,
return each result by a statement of its own, and the leaf and the
general native of `count` and of `nthnext` are one body each, not a
leaf that calls the general native (`docs/PERF.md` "Natives that
return in place").
arm64 stores every value as two words and copies results and argument
runs whole. On both, `max` and `min` read their winner a word at a
time (`docs/PERF.md` "A width-consistent native boundary").

- `op_table` holds every opcode's **general handler**, which takes
  every case and raises every trap. `mov:move`, the conditional jumps,
  every variant of `cmp`, and `closure:get-cell`, `var:load-var`,
  `call:call`, `call:self`, `call:return` and `call:return-nil` each
  have a general handler of their own, and `call:lookup` and `call:lookup-or`
  share one; `mov:move-clear`, the `mov` loads and `jump:jmp` have
  their fast handler there too, since verification leaves them no
  other case; a quickened variant's (§10.10) runs the instruction as
  its base opcode, through the base's; every other entry is its
  group's, which switches on the variant or, where no variant is left,
  traps as §10 says for one outside the enum. A group outside the enum is `BytecodeCorruption`;
  `transient`, `hash`, `tx`, `io` and `simd` trap
  `UnimplementedOpcode` for every variant.
- `fast_table`, the table the fetch reads, is `op_table` with a
  **fast handler** over each hot opcode: every variant of `mov`,
  `jump` and `cmp`, `math:add`, `math:sub`, `math:mul`, `math:idiv`,
  `math:mod`, `var:load-var`, `closure:get-cell`, `call:call`,
  `call:self`, `call:lookup`, `call:lookup-or`, `call:return` and
  `call:return-nil`, and every quickened variant (§10.10), whose fast
  handler reads its operands as its form says, with no kind to
  decode. A fast handler takes its
  instruction's common case, reading its operands in place and storing
  only to a slot of its frame, with no call but its tail call and no
  stack frame; on any other case it tail-calls the general handler
  through `op_table` before it has changed anything, so every trap,
  every safe point and every allocation is the general handler's (a
  step, §10.10, whose comparison leaves its case has run its add and
  fetches the comparison). The
  table indexed at run time is what keeps the optimizer from inlining
  the general handler, and the stack frame it needs, back into the
  fast one. A case that calls out, a leaf native or a keyword
  looking itself up, goes on to a part of its own out of line: a call
  in return position that is never inlined, which a release build
  makes a tail call, so the stack frame the part needs is not the fast
  handler's. Release builds keep no frame pointer, so a fast handler
  has no frame record to push either. The fast handlers sit together
  in a section of their own, each on a cache line of its own, so code
  growing elsewhere does not move them against each other.
  `zig build codegen` holds the rule: it disassembles the arm64 and
  x86-64 release builds and fails when a fast handler (`vm.VM.fast*`)
  calls anything or, on arm64, names the stack pointer
  (`test/codegen.sh`, with an LLVM objdump). On x86-64 every handler
  and out-of-line part takes the `preserve_none` calling convention
  (`x86_64_preserve_none`), under which every general register but
  rsp and rbp is the caller's to save: System V's would leave a
  handler nine scratch registers, four of them its arguments, and
  make `call:call`, the comparisons and the arithmetic save up to six
  with `push` and `pop`. A handler keeps what it needs without saving
  its caller's, and a part out of line keeps its own across a
  native's call in the registers System V has the native save. The
  check fails on any `push` or `pop` there but rbp's, which only a
  handler using all fifteen registers would save, and on any
  reservation or address of stack, and lists what each saves. On
  arm64, whose AAPCS64 leaves eighteen scratch registers, the
  handlers take Zig's `.auto`. The chain's entries, `loop`'s passes
  and a `Callback`'s call, are ordinary calls, which save what they
  keep across the chain once a pass. The check also lists, for
  information, what the out-of-line parts save.
- `VM.loop` is the one run loop: `run` drives it until the VM halts,
  `callValue` and `runRoutine` until the frame they pushed returns (a
  `Callback` makes the first pass itself, §6). It enters the chain at
  the current frame's next instruction, and the chain returns to it
  only with an error, which it translates to a throw when a handler is
  in force (§12) or passes on, or once the loop's frame has returned.
  Only the handlers that can pop or unwind frames or halt
  (`call:return`, `call:return-nil`, `ctrl:*`) test for that; the
  return of a frame a host pushed ends the chain without the test,
  since the host's loop runs at that frame's depth.
- The handlers of the groups that never push or pop a frame (`mov`,
  `cmp`, `jump`, `var`, `math`, `closure`, `coll`) run against the
  frame the fetch took; `call` and `ctrl` re-derive the current frame,
  since a call or a native may have grown `frames`.
- A build with `-Dopcodes=true` counts each fetch by its opcode index
  and each native call (`docs/TOOLING.md` §1); any other build
  compiles the counting out.
- The pc advances before the handler runs, so a handler sees the
  next pc: a conditional jump not taken fetches at it, a taken one at
  its target. The frame's `pc` field is written only where something
  reads it: every general handler writes it on entry, before anything
  that can raise, call out, reach a safe point or end the chain, and
  goes on from the field; a fast handler writes it only before it
  pushes a frame (the return and a trace through the callee read it)
  or calls a native, and otherwise fetches at the `pc` it was passed.
  So every frame's `pc` in an error trace is one past its instruction
  (§13), and a frame's `pc` under a frame it called is its return
  point.
- The fast handlers read a slot, a constant, an initialized upvalue
  or a bound Var in place and leave every other operand, a trap
  included, to the general handler's resolution (§4). Two fixnums
  compare, add, subtract, multiply, `quot` and `mod` there when the
  result is a fixnum; anything else, a promotion or a zero divisor
  included, goes through the numeric tower (§10.3). `call:call` of a
  closure with a fixed arity of its routine or of a member of its
  arity table (a test of the routine's own arity, then a bounds check
  and a load from the table, §6), where the frame chain and the stack's
  capacity have room, pushes the callee's frame without allocating,
  `call:self` the same with the frame's own closure and the member its
  count names, and `callValue`
  enters a closure the same way; a leaf native within
  its arity reads its arguments in place (§6), and any other native
  within its arity and `max_native_args` (8) arguments gets them
  copied to a buffer on the native stack; a keyword or symbol
  called with one or two arguments on a map, a record or nil looks
  itself up in place, as `VM.lookup` does, with no copy and no safe
  point (the key is an immediate, so the lookup neither allocates nor
  walks nested data), and so do `call:lookup` and `call:lookup-or`,
  reading the target in place. `call:return` from any frame but the top-level
  one pops it and continues in the caller, or fills the cell of the
  host that pushed it (`callValue`, `runRoutine`, a `Callback`) and
  ends the chain; the return of a batch's frame (§6) goes on from the
  cell to the part the cell names, out of line, one for each kind of
  batch (`each` into slots or into the root stack, `fold`,
  `foldRange`), which starts the next element in the same frame or,
  after the last, pops it and ends the chain, so a return to bytecode
  pays nothing for batches. The general `call:return` goes on the same
  way, setting the frame's `pc` to 0, where its fetch resumes. Every other call goes through the general entry of
  §6, with the same traps.
- **A comparison and its branch.** When the instruction after a
  `cmp:*` is a `jump:if-false` or `jump:if-true` testing the slot the
  comparison wrote (the compiler's lowering of an `if` on a
  comparison, `COMPILER.md` §5.2), the comparison's handler runs the
  jump too, so the pair costs one dispatch. Nothing is skipped: the
  slot holds the boolean, `pc` and every trap are what running the two
  in turn gives, and an error trace names whichever of the two
  failed. The encoding is unchanged.

### 9. Memory and the collector

Every runtime value lives on the VM's `Heap` (`VM.ensureHeap`, backed
by `VM.allocator`): closures, upvalue cells, rest-argument lists, the
values `coll:*` builds, everything natives allocate, and the string
and bignum literals the compiler lowers onto `registry.heap`, the same
heap. Vars, namespaces and routines live in `VM.runtime_arena` or the
compiler's persistent allocator for the VM's life. `VM.deinit` frees
the heap block by block and the arena wholesale.

**The VM hosts the collector.** `VM.gcRoots` marks the roots
`docs/GC.md` §3 lists, and `VM.gcTrace` traces a closure (cells, then
the constants of its routine and every member of its arity table) and
a cell (its value). When a cycle is due and
the safe points that run one (instruction fetches after an
instruction that could allocate, and `callValue` of anything but a
closure) are `docs/GC.md` §7. `Heap.alloc` never collects, so what
the VM or a native builds within one instruction needs no rooting; a
native that keeps a value across a call into the VM roots it
(`docs/GC.md` §11.5). A VM over a borrowed heap (the expander's macro
sub-VMs) has `gc_enabled = false`. `VM.collectGarbage` runs one cycle
and sizes the next window; `gc_cycles` counts them. While `gc_hold` is
nonzero no cycle is due: a lazy block is being realized in isolation
under `=` or `hash`, whose callers hold unrooted nodes, and the
failure of such a realization waits in `parked_realize`, a root, until
the native call or opcode that compared or hashed raises it
(`docs/LAZY.md` §6). A `coll` opcode copies its operands off the stack
and reads its frame again after building, since realizing a lazy key
runs code that may grow both.

#### 9.1 Sub-VMs

A user macro runs on a fresh sub-VM (`docs/MACROEXPAND.md` §1.2) that
borrows the heap (`borrowed_heap`) and the interner
(`borrowed_interner`) of the VM it compiles for, its **owner**, and
through `VM.borrowRegistries` that VM's registries too: `owner` points
at it, and `VM.home()` (the owner, else the VM itself) is where every
registry access goes. The namespace registry (`ensureRegistry`,
`ensureNamespace`), the record types (`registerRecordType`,
`recordType`, `ensureReducedType`, the `Delay` type), the protocols
(`registerProtocol`, `protocolById`, `extendProtocol`) and the store
connections `db/open` makes are the owner's, so a type id, a protocol
id or a namespace means the same in every VM that shares a heap, and
whatever a macro registers, and every value it stores, lives as long
as the owner. The owner is found through the namespace the macro
expands in (`NamespaceRegistry.vm`, set by `ensureRegistry`). A sub-VM
gets the owner's compiler hooks without `eval` and `load`
(`CompilerHooks.eval` and `.load` are null, and `eval` and
`load-string` throw `:no-compiler`): either would compile into
the sub-VM's runtime arena, which dies with it, and a `require` it ran
would run the owner's collector over values only the sub-VM holds.

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
| 4 | `call` | yes | `call`, `return`, `return-nil`, `self`, `lookup`, `lookup-or` (`tailcall` traps) |
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
outside its group's enum that is not a quickened variant (§10.10) is
`BytecodeCorruption` in every group, which verification refuses
(§5); a reserved variant inside it (`call:tailcall`, `math:pow`,
`ctrl:halt`) traps `UnimplementedOpcode`.

#### 10.1 `mov`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `mov:move` | A=slot, B=any | `slot[A] := resolve(B)` |
| 1 | `mov:load-const` | A=slot, W=constant index | `slot[A] := consts[W]`; `OperandOutOfRange` past the pool |
| 2 | `mov:load-nil` | A=slot | `slot[A] := nil` |
| 3 | `mov:load-true` | A=slot | `slot[A] := true` |
| 4 | `mov:load-false` | A=slot | `slot[A] := false` |
| 5 | `mov:move-clear` | A=slot, B=slot | `v := slot[B]; slot[B] := nil; slot[A] := v`: a move whose source the compiler found dead after it (`COMPILER.md` §4.9), so the slot roots the value no more; A = B is a move. Never traps, allocates or reaches a safe point |

Keywords and symbols are constants; there is no `load-keyword`.

#### 10.2 `call`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `call:call` | A=call_base, B=argc (immediate), C=result slot | Range call (§6) |
| 1 | `call:tailcall` | | Traps `UnimplementedOpcode` |
| 2 | `call:return` | A=any | Return `resolve(A)`; halt from the outermost frame |
| 3 | `call:return-nil` | | Return nil |
| 4 | `call:self` | A=window slot, B=argc (immediate), C=result slot | Call the frame's own closure with `slot[A..A+argc]`, entering the frame's routine or the member of its arity table that takes `argc` (§6) |
| 5 | `call:lookup` | A=slot, B=any, C=keyword or symbol constant | `slot[A] := (C resolve(B))` (§6) |
| 6 | `call:lookup-or` | A=slot, B=slot, C=keyword or symbol constant | `slot[A] := (C slot[B] slot[B+1])` (§6) |

#### 10.3 `math`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `math:add` | A=slot, B=any, C=any | `+` |
| 1 | `math:sub` | A=slot, B=any, C=any | `-` |
| 2 | `math:mul` | A=slot, B=any, C=any | `*` |
| 3 | `math:div` | A=slot, B=any, C=any | `/`: an exact integer quotient stays an integer, otherwise the nearest float; `:divide-by-zero` for a zero divisor of any kind, a NaN operand the result first (SEMANTICS.md §2.2) |
| 4 | `math:idiv` | A=slot, B=any, C=any | `quot`, truncated; `:divide-by-zero` |
| 5 | `math:mod` | A=slot, B=any, C=any | `mod`, floored (sign of the divisor); `:divide-by-zero` |
| 6 | `math:pow` | | Traps `UnimplementedOpcode` |
| 7 | `math:neg` | A=slot, B=any | Unary `-` |
| 8 | `math:abs` | A=slot, B=any | `abs` |

Every variant but `pow` runs the numeric tower over fixnum, bignum
and float (SEMANTICS.md §2.2 contagion): an integer result outside
i48 is a bignum on the VM's heap, and a non-number is
`:kind-mismatch` with the detail `+ expects numbers, got a string`.
The arithmetic natives call the same tower functions (`+` of two
fixnums, and `inc` and `dec` of one, compute inline when the result
is a fixnum, as the handlers do), so `(+ a b)` through a Var and the
inlined `math:add` agree exactly. `/`, `quot`, `rem` and `mod`
raise for a zero divisor of either kind (`(/ 1.0 0)` and `(mod 1
0.0)` raise, as in Clojure); a NaN operand of `/` is its result
first.

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
| 0 | `jump:jmp` | W=target | `pc := W` |
| 1 | `jump:if-true` | A=any, W=target | `pc := W` when `resolve(A)` is truthy |
| 2 | `jump:if-false` | A=any, W=target | `pc := W` when `resolve(A)` is nil or false |

The target is an absolute pc in the current routine. A target at or
past the end of the code is `OperandOutOfRange`; the compiler's
placeholder for a target still to be patched is 2^32 − 1, so a missed
patch fails there instead of jumping. A conditional jump checks its
target only when taken.

#### 10.7 `var`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `var:load-var` | A=slot, W=Var index | `slot[A] :=` the Var's `thread_value` when a binding is in force (§6.5), else its root; `:unbound-var` when it has neither. The same as `mov:move A, vW` for W below 4096 |
| 1 | `var:store-var` | A=any, W=Var index | The Var's root `:= resolve(A)`, marked bound, its macro flag cleared (a `def` over a macro makes it a function, as Clojure's `def` resets the Var's metadata). Redefining a name updates the same Var, so code compiled against it sees the new root |
| 2 | `var:var-object` | A=slot, W=Var index | `slot[A] :=` the Var object; an unbound Var does not trap |

W past the Var table is `OperandOutOfRange`. `(def x v)` is
`store-var` then `var-object`, so it yields the Var.

A `Var` carries `root`, `bound`, `meta`, `macro` (set by `defmacro`,
`docs/MACROEXPAND.md` §1.2, cleared by `def`), `dynamic`, `thread_value` and
`thread_bound`.

#### 10.8 `coll`

Every variant is `A=arg_base B=argc (immediate) C=dst` and reads
`argc` values from `slot[A ..]`:

| # | Name | Semantics |
|---|---|---|
| 0 | `coll:list` | The list of the values |
| 1 | `coll:concat` | Each value is nil, a list, a lazy seq (its spine realized first, `docs/LAZY.md` §8), a vector, a map (its `[k v]` entries) or a set, else `:kind-mismatch`; the result is the list of all their elements left to right. The runtime of syntax-quote's `~@` |
| 2 | `coll:vector` | The vector of the values |
| 3 | `coll:map` | Flat `k v` pairs (`argc` even, else `BytecodeCorruption`); a later duplicate key wins |
| 4 | `coll:set` | The set of the values; duplicates collapse |

Maps and sets hash and compare through `src/dispatch.zig`.

#### 10.9 `ctrl`

| # | Name | Operands | Semantics |
|---|---|---|---|
| 0 | `ctrl:try-enter` | A=binding slot, W=try index | Push a `try_` handler for `tries[W]` (§12) |
| 1 | `ctrl:try-exit` | W=post pc | Normal exit of a try or catch body (§12) |
| 2 | `ctrl:finally-exit` | | End of a finally body: resume its continuation (§12) |
| 3 | `ctrl:throw` | A=any | Throw `resolve(A)` (§12) |
| 5 | `ctrl:halt` | | Traps `UnimplementedOpcode` |

Variant 4 is unassigned.

#### 10.10 Quickened variants

A quickened variant is a hot opcode specialized to the operand kinds
it was found with, so its fast handler (§8) decodes no operand kind.
It has its base opcode's operands and meaning; only the variant
number differs, so an instruction's pc, span and trace are its base's.
`vm.quicken` rewrites a routine's code into them, and the compiler
quickens every routine it finishes (`COMPILER.md` §4.5), the stdlib
image's included (`STDLIB.md` §1); a routine built by hand keeps its
base opcodes unless it is quickened. Verification proves what each
form promises (§5), so the fast handler trusts it as it trusts the
rest; past the fast handler's case the instruction goes to its base
opcode's general handler, with every trap and safe point.

| Group | Variants | Base | Form |
|---|---|---|---|
| `math` | 32 + base | `add`, `sub`, `mul`, `idiv`, `mod` | B and C slots |
| `math` | 40 + base | the same | B a constant holding a fixnum, C a slot |
| `math` | 48 + base | the same | B a slot, C a constant holding a fixnum |
| `math` | 16 + 4k + c | `add` | a step: B a slot, C a constant holding a fixnum, followed by the quickened comparison `c` (`lt`, `lte`, `gt`, `gte`) with its jump, reading A as its B; k = 2t + f: f 0 for the comparison's B and C slots, 1 for its C a fixnum constant; t 0 for its jump a `jump:if-true`, 1 a `jump:if-false` |
| `cmp` | 16 + 8k + base | every variant | k = 2t + f: f 0 for B and C slots, 1 for B a slot and C a fixnum constant; t 0 alone, 1 followed by a `jump:if-true` testing A, 2 by a `jump:if-false` testing A |
| `mov` | 32, 33 | `move` | B a slot; B an upvalue |
| `call` | 32 | `return` | A a slot |

A comparison quickened with its jump runs the pair as one dispatch
(§8) without looking for the jump: verification proved it is there.
A step is a counting loop's `(+ i k)` and its bottom test (`COMPILER.md`
§5.7): it runs the add, the comparison after it and that
comparison's jump as one dispatch, reading the two in place as a
comparison reads its jump. Verification proved the comparison is
there, in the form the step names and reading A, and the
comparison's own form proved its jump. A sum that is not a fixnum
(B not one, or the sum past i48) goes to `math:add`'s general
handler, and the comparison then runs as its own instruction; a
comparison whose C slot does not hold a fixnum runs as its own
instruction after the step has stored the sum. Either way each
instruction's trap, safe point, pc and trace are its own, as running
the three in turn gives.
The disassembler names a quickened variant after its base, with its
operand kinds (`s` a slot, `c` a fixnum constant, `u` an upvalue), the
comparison a step runs and the jump a comparison runs: `math:add.sc`,
`math:mul.cs`, `cmp:lt.ss+if-true`, `mov:move.s`, `mov:move.u`,
`call:return.s`, `math:add.sc+lt.ss+if-true` (`TOOLING.md` §2). Every
other number in these ranges is unassigned.

---

### 11. `recur`

`(recur arg...)` re-enters the nearest enclosing `fn*` or `loop*`
body with new bindings without growing the call stack. The compiler
checks that it is in tail position and matches the target's binding
count (a variadic `fn*`'s rest param is one binding and receives the
seq passed), raising `RecurOutsideTail` or `RecurArityMismatch`
(`COMPILER.md` §4.4), and lowers it (`COMPILER.md` §5.6) to a
parallel assignment of the new values into the binding slots (a
fresh cell per captured binding, §6) and a jump back into the target:
a `jump:jmp` to its entry, or, where the body begins with an `if` on a
simple test, that test repeated and a `jump:if-true` or
`jump:if-false` past the entry's own (`COMPILER.md` §5.7), which a
comparison runs with its branch in one dispatch (§8). No call opcode
is emitted.

**Guarantee.** A `recur` loop runs in constant stack space: no frame
is pushed and the backing stack does not grow. It allocates nothing
per iteration for bindings no closure captures, and one cell per
captured binding per iteration. What the body allocates is its own.
`VM.stack_high_water` and `VM.frame_high_water` move wherever a frame
is pushed, in builds with runtime safety (a release build keeps the
stores off its calls and leaves them at their start), so a test
comparing them around a loop sees the true maximum; `src/compile.zig`
pins a 10k-iteration loop leaving both unchanged.

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

**`ctrl:try-enter A=binding_slot W=try`** pushes a `try_` handler for
the current frame with the catch pc and, for a `try` with a
`finally`, the finally pc of `routine.tries[W]` (`OperandOutOfRange`
past the table); the pcs are absolute in the current routine.

**`ctrl:try-exit W=post_pc`** pops the top handler
(`InvalidHandlerState` if there is none or it belongs to another
frame). With a `finally_pc` it pushes a
`FinallyContinuation{frame_index, .normal = post_pc}` and jumps to
the finally body; otherwise it jumps to `post_pc`.

**`ctrl:throw A`**, `VM.throwValue(v)` and `VM.throwKeyword(name)`
(a native's error, thrown as its error value, §13) walk the handler
stack from the top:
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

**Where a throw began.** A throw a handler takes keeps its origin on
`vm.origins`: the value, the `VmError` it was translated from (if
any), that error's `vm.error_detail` and the frame chain at the raise.
The `cleanup` handler a catch leaves and the `.throwing` continuation
a finally resumes carry the origin's index. A throw of a value
identical to the one a live catch holds is that throw again and keeps
its origin, which covers the rethrow of a `catch` no clause of which
matches and `(catch any e (throw e))`; any other throw begins where it
is thrown. When a throw that carries an origin leaves the run,
`recordErrorTrace` reports the origin: `traced_error` is the original
`VmError` (or `UncaughtThrow` for a thrown value), `error_detail` its
detail and `error_trace` its chain, so the report is the one the error
would have without the `try` around it. An origin no live record names
is dropped before the next one is pushed; `resetAfterError` clears
them all. An origin is for the report only: a throw with no memory to
record one goes on without it, reported where it leaves the run.

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
chain; an error that leaves a run records in `VM.error_trace` (§13)
the frame chain where its throw began.

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
raised while a handler is active becomes its error value and is thrown
through the same path, so `(try (/ 1 0) (catch any e e))` is
`{:error :divide-by-zero :message "divide by zero" ...}` and
`(catch :divide-by-zero e ...)` takes it. Without a handler the Zig
error leaves the run.

---

### 13. Execution errors

`VmError` is the VM's Zig error set. User code and reports see the
keyword form of the catchable subset (`vmErrorToKeywordName`).

**Catchable** (raised as an error map when a handler is active; see
"Error values" below):

| Error | Keyword | When |
|---|---|---|
| `KindMismatch` | `:kind-mismatch` | An operand of the wrong kind: a non-number to `math:*` / `cmp:*`, a non-seqable to `coll:concat`, a wrong kind to a native |
| `ArityMismatch` | `:arity-mismatch` | A call passes an argument count the callee does not accept, a multi-arity closure's included: no member of its table takes it |
| `NotCallable` | `:not-callable` | A call on a value that is not a closure, native, protocol fn, Var, keyword, symbol, map or set (hash or sorted), vector or transient |
| `UnboundVar` | `:unbound-var` | A `v` operand or `var:load-var` on a Var never bound |
| `NotDynamic` | `:not-dynamic` | `binding` or `set!` on a Var not marked `^:dynamic` (§6.5) |
| `NoThreadBinding` | `:no-thread-binding` | `set!` on a dynamic Var with no binding in force |
| `ArithmeticOverflow` | `:arithmetic-overflow` | A count or identifier the runtime produces does not fit a fixnum; arithmetic never raises it (results promote to bignums) |
| `DivideByZero` | `:divide-by-zero` | `/`, `quot`, `rem`, `mod` with a zero divisor of either kind |
| `IndexOutOfBounds` | `:index-out-of-bounds` | `nth` and friends past the end |
| `DbError`, `DbClosed`, `InvalidDurableRef`, `CodecFailed`, `TxClosed` | `:db-error`, `:db-closed`, `:invalid-durable-ref`, `:codec-failed`, `:tx-closed` | Storage natives (`docs/DB.md`) |
| `NotDerefable` | `:not-derefable` | `deref` of a value that is not a durable ref, Var, atom, delay or `reduced` |
| `AtomReEntry` | `:atom-re-entry` | A mutating atom op re-entered on the atom it is mutating (`docs/ATOM.md`) |
| `TransientUsedAfterPersistent` | `:transient-used-after-persistent` | A transient called or looked up after `persistent!` froze it (`docs/TRANSIENT.md` §6) |
| `Utf8Error`, `InvalidArgument`, `IoError`, `FileNotFound`, `InvalidPath` | `:utf8-error`, `:invalid-argument`, `:io-error`, `:file-not-found`, `:invalid-path` | String, math and I/O natives |
| `NotARecord`, `NoProtocolImpl`, `NoProtocolMethod` | `:not-a-record`, `:no-protocol-impl`, `:no-protocol-method` | Records and protocols (`docs/PROTOCOLS.md`) |
| `StackOverflow` | `:stack-overflow` | A call would push frame number `VM.max_frames` (default 2^20; an embedder may set it); a native re-entering the VM finds the native stack past the guard, or `VM.max_nested_runs` run loops nested (§13.1); or `=`, `hash` or printing inside a call or opcode met data nested past the guard (SEMANTICS.md §2.7). Runaway recursion ends in well under a second; legitimate recursion a hundred thousand calls deep runs |

Natives also throw errors of their own through `throwKeyword` or
`throwErrorMap`, documented with the native: `:unserializable`
(`docs/CODEC.md`), the `:db/*` and `:nextomic/*` errors
(`docs/DB.md`, `docs/NEXTOMIC.md`),
`:transient-used-after-persistent` (`docs/TRANSIENT.md`),
`:invalid-regex` (a map, from `re-pattern`; `docs/REGEX.md` §9),
`:invalid-replacement` (a map, from a pattern `replace`;
`docs/REGEX.md` §11),
`:no-metadata-on-immediate` (`docs/SEMANTICS.md` §7) and
`:no-compiler` (`docs/MACROEXPAND.md` §1.2).

**Error values.** What a handler takes for a catchable error, or for
a native's `throwKeyword`, is the map `VM.errorValue` builds:

```
{:error :kind-mismatch :message "+ expects numbers, got a string"
 :fn "f" :file "app.nx" :line 12 :column 3}
```

`:error` is the keyword above; `:message` the error detail (below),
or with none the keyword's name in words (`"index out of bounds"`,
`"db key too large"`); `:fn`, `:file`, `:line` and `:column` the
place it was raised, each present when known: the routine's name and
its source path, and the line and column of the failing instruction's
span. The place is the innermost frame running the program's own code
(`VM.raiseSite`), so an error inside a function of the standard
library, whose sources are marked `SourceInfo.library`, is placed at
the program's call of it; with no such frame, the innermost one. A
native's error map (`throwErrorMap`: Nextomic's, `re-pattern`'s) gets
the same place keys. `catch` takes the map by its `:error`
(`docs/MACROEXPAND.md` §10), `ex-message` reads `:message`, and
`ex-data` returns the map itself (`docs/STDLIB.md` §8). With no
handler in force the error leaves the run as the `VmError`, and a
native's keyword as the bare keyword, which the host reports with its
trace; the REPL's `*e` holds the map a catch would have taken. Building
the map can fail only for memory; then the value is the bare keyword,
which every `catch` that takes the map also takes, so a handler still
runs when the heap is exhausted: nothing else a throw does allocates,
since `ctrl:try-enter` reserves the room for a finally's continuation
and the throw's origin is dropped when it cannot be recorded (§12). The line of a place costs a scan of
the source before it; the VM keeps the last place it computed, so a
handler taking an error in a loop scans once.

**Not catchable** (compiler bugs or corrupt bytecode; they leave the
run):

| Error | When |
|---|---|
| `UnimplementedOpcode` | A defined but unexecuted group or variant (§10), an `i` or `e` operand where a value is read, a store to `u` |
| `OperandOutOfRange` | Verification: an operand or wide-field index past the routine's slots, constants, Var table, tries or capture descriptors; a `call:lookup-or`'s second slot past the frame; a jump target or a `try`'s pc past the code |
| `InvalidOperandKind` | Verification: an operand read as a slot (a destination, a block's base, a cell) that is not one; a lookup key that is not a keyword or symbol constant; a quickened instruction's operand not of the kind its form promises, a slot, an upvalue or a constant holding a fixnum (§10.10). Where it runs: an operand kind the position does not accept, `resolve` of unused, `store` to a constant |
| `BytecodeExhausted` | Verification: code empty, or ending in an instruction that falls through |
| `BytecodeCorruption` | Verification: an instruction kind other than `primary`, an unrecognized group or variant (§10), a `call:self` whose count is no fixed arity of its routine's arity table (its own, without a rest parameter, or a sibling's), an arity table a call cannot pick from (a member not at its place, another table's member, a fixed entry of another arity, a last fixed entry that is null, a rest clause without a rest parameter or below a fixed arity, a table of one, §5), a comparison quickened with its jump not followed by that jump on its slot, a step not followed by the comparison it names reading its slot (§10.10). Where it runs: `call:self` in the top-level frame; an unrecognized operand-kind bit pattern; a variadic routine with `slot_count < fixed_arity + 1`; an odd `coll:map` count |
| `CallBlockOutOfRange` | Verification: a call block, or a `call:self`'s arguments, past the frame's slot count |
| `CaptureCountMismatch` | Verification: a capture descriptor's source count differs from the child's `upvalue_count`; a top-level routine with upvalues; two members of an arity table with different upvalue counts. Where it runs: `closure:make` of such a descriptor in a routine nothing verified. A call never finds a closure's cell count other than its routine's (§6) |
| `UpvalueOutOfRange` | Verification: a `u` index or `inherited_upvalue` source past the routine's upvalue count |
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
natives and protocol methods alike), and for a multi-arity closure
every count it takes, a run of three or more as a range and the rest
clause last, taking in the fixed counts just below it: `f takes 1 or
2 arguments, got 3`, `f takes 0 to 2 arguments, got 3`, `f takes 1, 3
or at least 5 arguments, got 4`; `an integer is not callable`,
`+ expects numbers, got a string`, `no impl of area for a vector`,
`a value nests too deeply to compare, hash or print`. A value's kind
is named as the language presents it (`kindPhrase`: `nil`, `a
boolean`, `an integer`, `a map`, ...). A sentence longer than the
160-byte buffer keeps what fits, cut at a character, and ends in `…`.
The detail is empty when the raise site has nothing to add; `run` clears it on entry and a
handler clears it when it takes the error as its error value's
`:message`, so it never describes an earlier error.

**Error trace.** When an error leaves a run the VM records the frame
chain in `VM.error_trace`, innermost first, one
`TraceFrame{name, pc, span, source}` per frame: the routine's name,
the index of the instruction the frame was executing (the failing
instruction innermost, the `call:call` in each caller; for a routine
verification refused, its one frame names the instruction it refused,
the last one for code that runs off its end), that
instruction's span from the routine's table (null without one) and
the routine's `source`. Neither an untranslated `VmError` nor an
uncaught throw pops a frame, so the chain is complete, including the
frames `callValue` pushed for closures a native called back. A
parked top frame (resting on `idle_routine`) is left out.
`VM.traced_error` names the error. `runRoutine` records the same way
when a nested run fails, so a host that learns of the failure
indirectly (the loader ran a required file while compiling a form)
reports it with its chain. A chain longer than 41 frames keeps its
innermost 32 and outermost 8 around one marker frame, whose `elided`
counts the frames it stands for (no span, no source), so
a runaway recursion lists 41 lines. The next failing run rebuilds the trace. `resetAfterError`
discards what a failed run left (the frames above the top-level one,
handlers, pending finallys, the unhandled throw, `traced_error`) so
`retargetTop` can
run the next form, and gives back the frame and stack capacity past
4,096 frames and 16,384 slots that a runaway recursion grew; the REPL
calls it after reporting, and `retargetTop` calls it when the frames
of a failed run still stand. The report
built from the detail and the trace is `docs/TOOLING.md` §1.

#### 13.1 Native stack guard

Bytecode recursion costs no native stack, but Zig code that recurses
once per level of nested input does: reading, expanding and lowering
forms, equality, hashing and comparison, printing, pull,
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
a native re-enters it, and at the first call of a closure through a
`Callback` (§6), whose later calls start from the same native frame,
so recursion through `apply`, `map`, `reduce`, a protocol impl or
`eval` ends in the same catchable `:stack-overflow` as runaway
bytecode recursion. The same checks count the run loops nested on the
native stack, one per such call still running, against
`VM.max_nested_runs` (default 100,000; an embedder may set it): past
it the call is `StackOverflow` too, so a runaway recursion through
natives stops before it has committed much of a large thread stack. Each layer maps the error to its own
report: the VM raises `StackOverflow`, the reader a reader error and
the compiler a compile error. The codec and the collector walk nested
data with heap stacks and need no guard.

`=`, `hash` and printing cannot return an error to their many callers,
so past the guard they answer `false`, `0` or `#<too deep>` and count
a spoil (`dispatch.spoilCount`). `callDirect` snapshots the
count around every native call, and `coll:*` around its construction;
a count that moved raises the failure an isolated realization parked
(`docs/LAZY.md` §6), else `:stack-overflow`, and rewinds the count to
the snapshot, and a native call that fails rewinds it too. A spoil
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
- `src/protocol.zig`, `src/record.zig`: the registries of
  `VM.home()` (§9.1); `protocol_fn` dispatch in `call:call`.
- `src/codec.zig`, `src/db.zig`, `src/nextomic/*`: reached only
  through natives; the VM tracks open `db` and Nextomic connections
  so `VM.deinit` closes them.

---

### 15. Tests

`src/vm.zig` holds the opcode tests: hand-assembled routines
covering every dispatched opcode and every trap it can raise, as
`RunCase` rows run by `expectRuns` (code, constants, tries, capture
descriptors, a Var table, and the value, kind, Var, error or uncaught
throw wanted), which also asserts that a run that returns leaves no
handler, pending finally or frame behind; what verification refuses is
the rows of `Routine.verify`'s own table, each run through `run` too.
The tests that inspect VM state, batches and the numeric tower are
individual. `src/compile.zig` pins the 10k-iteration `recur` loop
(§11).
`test/integration/eval_pipeline.zig`, `runtime_polish.zig` and
`numbers.zig` run source through the compiler and VM (captured loop
bindings, `letfn*`, variadic calls, every catchable error and its
error value, error traces); `test/golden/cli/*` pin the reports and `zig build examples`
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
