## COMPILER.md — compiler: pipeline, lowering, contracts

The contract of the nexis compiler (`src/compile.zig`): reader `Form`
→ macroexpansion → `Tiny` IR → bytecode routines. It owns lowering,
including `recur`, capture marking and box-local emission; `docs/VM.md`
specifies what the emitted bytecode does, `docs/MACROEXPAND.md` the
Form → Form rewriter that runs first, `docs/FORMS.md` the Form schema.
The frozen decisions it refines are `PLAN.md` §23 #19 (`recur`), #21
(operand kinds) and #31 (the primitive core). It pins what each stage
guarantees, not the Zig shape of `Tiny`, `Compiled` or the `Emitter`
(§11).

---

### 1. Scope

**In:**
- Lowering: `Form` → `Tiny` (`lowerForm`), where every symbol
  reference is classified (special form, inlined core fn, lexical
  local, captured upvalue, Var, declared-later name) and every
  captured binding is marked.
- Codegen: `Tiny` → 64-bit bytecode (`Emitter`), with a per-routine
  constant pool, Var table, capture-descriptor table and span table.
- Var linking at compile time through the current namespace and the
  namespace registry; `require` file loading is `src/loader.zig`
  (MACROEXPAND.md §8).
- The primitive core: `quote`, `if`, `do`, `let*`, `fn*`, `letfn*`,
  `loop*`, `recur`, `def`, `var`, `try` / `catch` / `finally`,
  `throw`, and the constructors `#%list`, `#%concat`, `#%vector`,
  `#%map`, `#%set` that syntax-quote emits.
- Compile errors: the `CompileError` set and the span of the form an
  error is about (§7).

**Absent:**
- Folding of computations: `(+ 1 2)` compiles to `math:add`. Only
  collections of constants are built at compile time (§4.4).
- A bytecode cache or object file: every run compiles from source.
- A separate resolver or analyzer module: classification and
  capture marking happen inside `lowerForm`.
- Register allocation beyond a stack of slots (§4.4); inline caches,
  operand-specialized opcodes, extension instructions.

---

### 2. Pipeline

```
source text
   │  parser (src/parser.zig, generated from nexis.grammar)
   ▼
Sexp tree
   │  reader (src/reader.zig)
   ▼
Form tree                                     docs/FORMS.md
   │  macroexpand (src/expand.zig), recursive to a fixed point
   ▼
expanded Form tree                            docs/MACROEXPAND.md
   │  lowerForm (src/compile.zig)
   ▼
Tiny tree: symbols classified, captured bindings marked
   │  Emitter (src/compile.zig)
   ▼
routines: code, constants, Var table, capture descriptors, spans
   │  VM (src/vm.zig)                         docs/VM.md
```

Stage boundaries are strict. A stage that receives input violating
the previous stage's guarantees has found a compiler bug, not a user
error (`InternalCompilerBug` where it can tell).

---

### 3. Compile-time memory

Form trees, `Tiny` trees and the `Emitter`'s working storage live on
the allocator the caller passes; `CompileOptions.routine_allocator`
puts the routines (code, constants, span tables, nested routines) on
a longer-lived one, so the trees can be freed as soon as the call
returns. The compile allocator is not collected by `src/gc.zig`;
freeing is the caller's arena drop.

| Caller | Trees | Routines |
|---|---|---|
| `nexis run FILE` | one arena for the whole file | the same arena |
| REPL | the runtime's persistent arena (a line's closures are called from later lines, and `Tiny.symbol` slices borrow from the line's text) | the same |
| `eval` | a scratch arena freed when `eval` returns | the runtime's persistent arena: a closure the form returns, a Var it defines and a frame an escaping throw leaves outlive the call |

Literal Values that reach run time (strings, bignums, keywords,
symbols, collections of constants) are built through the heap and
interner plumbed into lowering (`LowerCtx.heap`, `LowerCtx.interner`)
and held in the routine's constant pool, which the collector marks
for as long as a frame or closure can run the routine (VM.md §9).
Nothing collects between lowering a form and running it. Without an
interner, quoted symbols and keywords are `UnsupportedFeature` and no
macro expands; without a heap, so are string and bignum literals.

---

### 4. Stage invariants

#### 4.1 Reader

Produces `Form` trees per `docs/FORMS.md`: every Form carries its
`SrcSpan` (`origin`), user metadata is normalized, reader-detectable
errors are rejected, and `syntax-quote` / `unquote` /
`unquote-splicing` / `#(...)` stay as unexpanded datums.

#### 4.2 Macroexpander

Contract in `docs/MACROEXPAND.md`. The compiler relies on: no macro
call remains; special forms are preserved; the syntax-quote and
`#(...)` datums are rewritten away; expansion is recursive to a fixed
point, bounded at 256 expansions in a row (`MacroDepthExceeded`,
MACROEXPAND.md §6); a synthetic form carries the macro call's span
and a reused subform its own (MACROEXPAND.md §4b).

#### 4.3 Lowering (`lowerForm`)

**Symbol classification**, in priority order:

1. **Special form**: a primitive-core name in operator position. The
   names are reserved and recognized regardless of lexical bindings
   (`(let* [if 1] (if true 2 3))` is still `if`). They are the
   expander's `special_forms` (MACROEXPAND.md §1.1) less the four it
   rewrites away (`ns`, `require`, `defmacro`, `set!`), plus the `#%`
   constructors; a test holds the two tables to that.
2. **Inlined core fn**: a call of one of 15 core fns at one arity
   (`inlined_ops`) lowers to one `math` or `cmp` instruction
   (`Tiny.prim`), which runs the numeric-tower helper the fn itself
   runs (VM.md §10), so results and errors are the fn's:

   | Arity | Fns |
   |---|---|
   | 2 | `+` `-` `*` `/` `quot` `mod` `<` `<=` `>` `>=` `==` |
   | 1 | `-` (negate), `abs`, `inc` and `dec` (`+` / `-` with a constant 1) |

   It inlines only when the operator means `nexis.core`'s Var
   (`namesCore`): it is not lexically bound, the namespace resolves it
   to `nexis.core`'s Var rather than one it defines or refers to, and
   (outside `nexis.core`) the file or REPL line does not define it
   (`DeclaredNames`), so `(do (def + f) (+ 1 2))` calls `f`, as in
   Clojure. Any other arity is an ordinary call. A qualified
   `nexis.core/+` inlines unconditionally, since a qualified head is
   never a local; host macros emit such heads (MACROEXPAND.md §5,
   capture safety).
3. **Lexical local**: the innermost binding from `let*`, `loop*`,
   `fn*` (parameters and self-name), `letfn*` or `catch`.
4. **Captured upvalue**: a lexical local of an enclosing `fn*` (§6).
5. **Qualified symbol** `p/foo` (`Tiny.qualified_symbol`): `p` (an
   alias first) must name a registered namespace and `foo` one of its
   own Vars; no parent walk, no lexical lookup.
6. **Current-namespace Var**: a bare symbol looked up in the current
   namespace, then its parent chain (`user`'s parent is `nexis.core`).
7. **Declared-later name**: a name the file or REPL line defines
   anywhere, at any depth (`def`, `defn`, `defonce`, `defmacro`,
   `defrecord` and its derived names, `defprotocol` and its methods;
   `DeclaredNames`, collected before any form compiles), so a form
   may refer to a Var a later form defines.
8. Otherwise `UnresolvedSymbol`, at the symbol's own span.

**Binding rules:**
- Inner bindings shadow outer.
- `let*` / `loop*` bindings are sequential with strict left-of-self
  visibility: binding i's right-hand side sees bindings 1..i-1, not
  its own name. `(let* [n n] body)` reads the outer `n`;
  `(let* [x e1 x e2] body)` is well-formed, `e2` seeing the first `x`.
- A `fn*` self-name (`(fn* name [params] body)`) is a lexical local
  bound to the closure itself, so recursion needs no Var (rule 3 wins
  over rules 5-7).
- A name repeated in one parameter list, or a rest parameter that
  repeats a fixed one, is `DuplicateParam`; a name repeated in one
  `letfn*` is `DuplicateBinding`. `&` is never a parameter name:
  `(fn* [a b & r] body)` lowers with `rest_param = "r"`, and a
  `letfn*` binding takes a rest parameter the same way.
- Every binding a closure captures is marked as the reference is
  lowered (§6.1).
- `recur` is a marker here; the `Emitter` validates it (§4.4).
- `catch` takes the matcher `any` only; any other is
  `UnsupportedFeature` (the expander lowers every surface matcher to
  `any`, MACROEXPAND.md §2b). The catch binding may be captured.
- An integer literal outside the i48 fixnum range lowers to a bignum
  constant; `IntegerOutOfFixnumRange` is only for a hand-built
  `Tiny.int` outside it.

**Errors**: `UnresolvedSymbol`, `DuplicateParam`, `DuplicateBinding`,
`MalformedForm`, `ExpectedSymbol`, `ExpectedVector`,
`UnsupportedFeature`, `StackOverflow`.

#### 4.4 Emitter: slots, captures, codegen

**Output**: one routine per `fn*`, plus one per top-level form: code,
constant pool, Var table, capture descriptors, span table,
`slot_count`, `fixed_arity`, `variadic` and `upvalue_count`
(VM.md §5).

- **Captured vs. direct.** A local arrives from lowering marked
  captured or not. An uncaptured local is a plain frame slot; a
  captured one is a heap cell (VM.md §6) boxed where it is bound, and
  closures capture the cell pointer, not a copy (§6.1).
- **`recur` validation.** `recur` must be in tail position of the
  nearest enclosing `fn*` or `loop*` (the active `RecurTarget`) with
  its binding count, else `RecurOutsideTail` / `RecurArityMismatch`.
  Tail position propagates through `if` arms, the last form of `do`,
  and `let*` and `letfn*` bodies; a `loop*` or `fn*` body installs a
  new target (a `recur` never crosses a `fn*`); every other position
  (an `if` test, a non-last `do` form, a right-hand side, a callee, a
  call or `recur` argument, an operand) has none.
- **Slots are a stack.** Each local and each temporary takes the next
  free slot, and every slot a form took is free again once the form
  is compiled: a binding's slot lives to the end of its scope, a
  temporary until the instruction that consumes it, a call block
  until the call. `slot_count` is the most slots live at once. A
  call's argument block (and a `coll:*` item block) is reserved
  contiguously before its items compile, on top of every live slot,
  so a cell slot needed after the call (per the range-call ABI,
  VM.md §6) or by a later `closure:make` is never inside it:
  `(let* [x 1, f (g), h (fn* [] x)] h)` keeps `x`'s cell below `(g)`'s
  block.
- **The destination is written last.** Every form writes its result
  slot as its last act: nothing it evaluates runs after the write, so
  no handler inside it can see the slot half-updated. A `try` with a
  `finally` computes its value into a temporary and moves it to the
  destination after the finally has run (§5.10). This is what lets a
  `recur` argument compile straight into its binding's slot (§5.6).
- **Operands in place.** A `math` or `cmp` instruction,
  `jump:if-false`, `var:store-var` and `ctrl:throw` read a literal (as
  a constant), a local held directly in its slot, an upvalue or a Var
  where it is, instead of copying it into a slot first. Evaluation
  stays left to right: the left operand of a two-operand instruction
  reads a Var in place only when the right one is a literal or a
  symbol, which run no code.
- **Literals.** nil, booleans and fixnums use `mov:load-nil` /
  `load-true` / `load-false` or a constant; every other literal
  (string, float, char, bignum, keyword, symbol) is a constant.
- **Constant collections.** A list, vector, map or set whose items
  are all constants (quoted data, `[1 2 3]`, `{:a 1}`, the `#%`
  constructors syntax-quote emits over constants) is built once at
  lowering, on the lowering heap, the way the VM would build it, and
  is one constant: its size costs no slots and no instructions, and
  evaluating it twice yields the same object, as in Clojure.
  A quote nested in quoted data (`'(a 'b)`) is the constant 2-list
  `(quote b)`. `#%concat` and a collection with a computed item compile
  to `coll:*` over a slot block.
- **Deduplication.** The constant pool holds each Value once
  (identical bits: the same immediate or the same heap object), and
  the Var table each Var once; a routine that captures one name from
  several scopes has one upvalue for it.
- **Limits.** Operand indexes are 12 bits (VM.md §3):

  | Limit | Error |
  |---|---|
  | more than 4096 slots live at once, upvalues, Var-table entries, or call arguments | `SlotOverflow` |
  | more than 4096 constants or capture descriptors | `ConstantPoolOverflow` |
  | a jump, `try` handler or `finally` target past pc 4095 | `JumpTargetOutOfRange` |

  Straight-line code past pc 4095 that nothing jumps to runs; the
  limit is on branch targets, so a routine longer than 4096
  instructions fails only where a form needs such a target (a very
  long `deftest` body is one). Each error is reported at the
  innermost form being compiled when it is raised (§7).

**Errors**: `RecurOutsideTail`, `RecurArityMismatch`, `SlotOverflow`,
`ConstantPoolOverflow`, `JumpTargetOutOfRange`, `InternalCompilerBug`,
`StackOverflow`.

#### 4.5 Codegen invariants

- Instructions are 64-bit primary instructions; the extension form is
  never emitted.
- Var references compile to `v` operands bound to `*Var` pointers at
  compile time (§4.7).
- A closure's upvalues are numbered 0..N-1 and it captures N cell
  pointers at construction.

#### 4.6 Spans

A compile error is reported at the span of the innermost form being
lowered or compiled when it is raised, or of the symbol lowering
rejects (§7). Routines carry a span table (§8), so a runtime error is
reported at the instruction that raised it.

#### 4.7 Var linking

- `def` interns the Var in the current namespace itself at compile
  time (unbound until the form runs), never in a referred one:
  `(ns my.app) (defn inc ...)` binds `my.app/inc`, leaves
  `nexis.core/inc` as it was, and from then on a bare `inc` in
  `my.app` is the local Var (rule 6 finds it before the parent
  chain). A symbol qualified with the current namespace's own name is
  that namespace's Var, interned unbound when its definition is still
  to come.
- Every other Var reference resolves to a `*Var` at compile time (an
  unbound one is interned when nothing resolves, for forward
  references). The VM reads the Var's root at execution time, so
  forward references work and a redefinition is visible to callers
  already compiled.
- `(require ...)` runs through the expander and `src/loader.zig`
  (MACROEXPAND.md §8).

---

### 5. Primitive core lowering

What each form lowers to, in terms of the opcodes of VM.md §10.

#### 5.1 `(quote x)`

- nil, booleans and fixnums use the ordinary `Tiny` variants.
- Symbols and keywords are interned; strings and bignums built on the
  heap; each is a constant.
- A compound payload is quoted element by element
  (`lowerQuotePayload`) and is one constant (§4.4). A quote inside
  the payload is data: `'(a 'b)` is `(a (quote b))`. Syntax-quote,
  unquote, `@x`, `#(...)` and `^meta` inside a quoted form are
  `UnsupportedFeature`.

#### 5.2 `(if test then else?)`

`test` is read in place when it can be (§4.4); `jump:if-false` to
the else label; `then` into the result slot; `jump:jmp` to the end,
unless every path through `then` ends in `recur` or `throw`; the else
branch (nil when absent).

#### 5.3 `(do expr...)`

Every expression but the last compiles for effect; the last into the
result slot. `(do)` is nil, and so is every empty body: `(fn* [])`,
`(let* [x 1])`, `(loop* [x 1])`, a `letfn*` without a body, a `try`
body or handler with no forms. The literal `()` is the empty list.

#### 5.4 `(let* [b1 v1 ...] body...)`

Each binding takes a slot; each value compiles into it in order, and
a captured binding is boxed with `closure:box-local` immediately
(§6.1). The body compiles as `do`.

#### 5.5 `(fn* name? [params... & rest?] body...)`

- The body compiles into a child routine, registered in the current
  routine's constant pool (`c` operand A of `closure:make`).
- Every enclosing binding the body references becomes a source in a
  capture descriptor (operand B): `local_cell_slot(s)` for a cell in
  the current frame, `inherited_upvalue(u)` for one the current
  closure captured. `closure:make A=proto B=desc C=dst` builds the
  closure, kind `function` (VALUE.md kind 24).
- The routine records `fixed_arity` and `variadic`; the rest parameter
  is slot `params.len`, filled by the VM at call time (VM.md §6). A
  captured parameter, rest included, is boxed at function entry.
- `fn*` takes one parameter vector; multi-arity `fn` and `defn` are
  the expander's (MACROEXPAND.md §10).

**Self-name.** When the body refers to its self-name, the closure
does not exist yet at `closure:make`, so the self-reference goes
through a placeholder cell:

```
; (def f (fn* fact [n] ... (fact (- n 1)) ...)), from nexis disasm
closure:new-cell    s2  -  -                        ; an uninitialized cell
closure:make        c0=<routine fact>  #0[s2]  s1   ; captures it
closure:init-cell   s2  s1  -                       ; the cell holds the closure
```

Inside the body `fact` is `u0`. A body that never names itself gets
no cell and an empty descriptor. Generated code never runs user code
between `closure:make` and its `closure:init-cell`, so the
placeholder's uninitialized state is invisible; hand-written bytecode
that reads it traps `UninitializedCell` (VM.md §13).

#### 5.6 `(recur args...)`

The arguments rebind the target's bindings with parallel-assignment
semantics: every argument sees the bindings as they were before the
`recur` (a sequential move would corrupt `(loop* [a 1 b 2] (recur b
a))`).

- An argument for an uncaptured binding that no other argument
  mentions compiles straight into the binding's slot: the slot is
  written only as the argument's last act (§4.4), so a handler inside
  the argument reads the old value, as in
  `(recur (try (try 5 (finally (throw :x))) (catch any e a)) ...)`,
  which rebinds `a` to itself.
- Every other argument is read in place when it is a constant, an
  upvalue or a slot no rebinding overwrites, and otherwise compiles
  into a fresh temporary; the moves into the binding slots follow once
  every argument is computed.
- `jump:jmp` to the target's entry. No call is emitted, so the loop
  runs in constant stack (VM.md §11).

**Captured bindings get a fresh cell per iteration**, never a
mutated one:

```clojure
(loop [i 0 acc []]
  (if (< i 3)
    (recur (+ i 1) (conj acc (fn [] i)))
    acc))
;; the closures return 0, 1, 2, not 3, 3, 3
```

If `recur` wrote into the one cell for `i`, closures from earlier
iterations would see the final value. So the new value goes into a
temporary, is boxed there, and the fresh cell replaces the old one:

```
math:add          s_tmp, ...           ; the new value
closure:box-local s_tmp                ; a fresh cell holding it
mov:move          s_i, s_tmp           ; install the cell
jump:jmp          L_entry
```

That cell is the one per-iteration allocation a captured binding
costs; an uncaptured binding costs none. A store to a `u` operand is
`UnimplementedOpcode` (VM.md §4); the fresh cell is the only way a
captured binding changes.

**Into a `fn*`.** With no enclosing `loop*`, `recur` targets the
function's own parameters: the target is installed after the
captured-parameter boxing prelude, so the rebind and jump re-enter the
body without a call. The bindings are the fixed parameters followed,
for a variadic `fn*`, by the rest slot: `(recur a b s)` into `(fn* [a
b & r] ...)` puts `s` in `r` as it is (Clojure's rule), and omitting
it is `RecurArityMismatch`. Overload clauses bind their parameters
through `loop`, so a `recur` in a clause re-enters that clause
(MACROEXPAND.md §10, `fn`).

#### 5.6b `(letfn* [(name1 [params] body...) ...] body...)`

Every name is visible to every function and to the body, so the
functions can call each other:

1. `closure:new-cell` a placeholder cell for each name.
2. Compile each function (a rest parameter is allowed); its
   descriptor lists every `letfn*` name it references, itself
   included, as a `local_cell_slot` source.
3. `closure:make` each closure (each captures cells the others fill).
4. `closure:init-cell` each cell with its closure.
5. The body compiles as `do`, reading the names through their cells.

The cell slots stay live across steps 3 and 4 (§4.4). Allocate-all,
make-all, init-all means no function can be called before its cell
is initialized.

#### 5.7 `(loop* [b1 v1 ...] body...)`

Bindings as `let*`, captured ones boxed. The entry label is placed
after that prelude, so a `recur` neither re-evaluates the initial
values nor re-boxes; the body compiles as `do` with the loop's
`RecurTarget`.

#### 5.8 `(def name expr?)`

Interns `name` in the current namespace (§4.7), compiles `expr` (nil
when absent) and emits `var:store-var`, which sets the root, marks the
Var bound and yields the Var. `defn` is the host macro's `(def name
(fn name ...))` (MACROEXPAND.md §10), so the body recurses through the
self-name.

#### 5.9 `(var name)`, `(var ns/name)`

`var:var-object` into the result slot: the Var itself, bound or not.
A bare name resolves as a symbol does (§4.3 rules 6-7), a qualified
one as rule 5.

#### 5.10 `(try body... (catch any binding handler...) (finally ...)?)`

The primitive takes exactly one `(catch any b ...)` and an optional
`finally`; the expander lowers the surface form (several clauses,
keyword matchers, a `finally` alone) onto it, with keyword matching as
a chain of `nexis.internal/#%catch-matches?` tests (MACROEXPAND.md
§2b).

- `ctrl:try-enter` installs the handler (catch pc, binding slot,
  optional finally pc); the body runs; `ctrl:try-exit` pops it on the
  normal path.
- On a throw the VM stores the value in the binding's slot and jumps
  to the catch entry; a captured binding is boxed first thing.
- The `finally` body sees the enclosing scope, not the catch binding,
  and runs on every exit path; its value is discarded. Its semantics
  (a throw in it replaces the pending one) are VM.md §12. The body's
  or handler's value waits in a temporary and moves to the result
  slot once the finally completes, so a finally that throws leaves
  the result slot as it was (§4.4).
- A thrown value is any value; there is no exception object.

#### 5.11 `(throw expr)`

`ctrl:throw` with `expr` read in place when it can be. Control goes to
the nearest handler, or the run ends with `UncaughtThrow` and the
value in `vm.unhandled_throw` (VM.md §12).

`set!` is not a primitive: the expander rewrites it to
`nexis.core/var-set` on a dynamic Var and refuses a local
(MACROEXPAND.md §2b).

---

### 6. Closure and upvalue contract

- A local is **captured** iff a nested `fn*` body references it;
  lowering decides this before the binding's code is emitted (§6.1).
- An uncaptured local is a plain slot, read and written through `s`
  operands with no overhead.
- A captured local's slot holds a pointer to its `UpvalCell` (VM.md
  §6), not the value:
  - in the defining frame it is read with `closure:get-cell dst,
    s_cell` (a slot operand never dereferences a cell);
  - inside a child closure it is a `u` operand on any opcode (`math:add
    s0, u0, c1`), which dereferences the cell;
  - it is never written after binding (a `u` store is
    `UnimplementedOpcode`); a `recur` installs a fresh cell (§5.6).
- `closure:make` copies cell pointers, not contents, so closures over
  one binding share its cell. A closure's cell array is fixed at
  creation; only a placeholder's contents change, once, through
  `closure:init-cell` (§5.5, §5.6b).
- Cells and closures are heap values the collector traces (VM.md §6,
  §9).

#### 6.1 Capture marking, binding-time boxing

Lowering marks every captured binding, and the `Emitter` emits
`closure:box-local` where the binding is bound (at function entry for
a parameter, at handler entry for a catch binding), so whether a slot
holds a cell is the same on every control-flow path. Boxing lazily,
when a closure first captures, would be unsound: in `(if false (fn*
[] x) 0)` the `box-local` would sit in a branch that never runs, and a
later same-frame `closure:get-cell` would trap `ExpectedCell` on a
valid program.

1. **Marking.** `LowerEnv` mirrors every scope the `Emitter` will
   have (`let*` / `loop*` bindings, `fn*` parameters and self-name,
   `letfn*` names, the catch binding), each entry recording the `fn*`
   depth it was made at and pointing at its Tiny node's `captured`
   flag. Lowering a symbol finds its innermost binding; one made at a
   smaller `fn*` depth is captured and its flag is set. One pass,
   O(scope depth) per symbol.
2. **Binding.** A marked binding is boxed as it is bound and pushed
   as `.cell_slot(s)`; every other one is `.direct_slot(s)`; a marked
   self-name gets a placeholder cell (§5.5). The instruction is in
   straight-line code every path into the scope runs.
3. **Same-frame reads** (`compileSymbol`): `.direct_slot(s)` →
   `mov:move dst, s`; `.cell_slot(s)` → `closure:get-cell dst, s`;
   `.upvalue(u)` → `mov:move dst, u` (the `u` operand dereferences).
4. **Capture** (`resolveOrCapture`): a child resolving a parent's
   binding finds it already `.cell_slot` (or an `.upvalue` further
   out) because lowering marked it; a `.direct_slot` there is
   `InternalCompilerBug`. Repeat references to one name reuse one
   upvalue.
5. A `BindingRef` never changes after binding time.

**Soundness invariant.** A binding is `.cell_slot` iff
`closure:box-local` is emitted for its slot where it is bound, so the
slot holds a cell on every reachable path, and `closure:get-cell` and
`local_cell_slot` sources need no run-time "ensure cell" check.

---

### 7. Error reporting

A compile error is a `CompileError` variant plus a span. The variant
set is the stable taxonomy (additions are compatible, renames are
not):

| Variant | Raised for |
|---|---|
| `UnresolvedSymbol` | a symbol that resolves to nothing (§4.3) |
| `DuplicateParam`, `DuplicateBinding` | a repeated parameter; a repeated `letfn*` name |
| `MalformedForm` | a special form of the wrong shape (`(if)`, `(quote)`, an odd `#%map`) |
| `ExpectedSymbol`, `ExpectedVector` | a binding name that is not a symbol; a binding or parameter spec that is not a vector |
| `UnsupportedFeature` | a non-`any` catch matcher; a syntax-quote, `#(...)`, `@x` or `^meta` datum reaching lowering or inside a quote; a quoted symbol or keyword without an interner, a string or bignum without a heap |
| `RecurOutsideTail`, `RecurArityMismatch` | §4.4 |
| `SlotOverflow`, `ConstantPoolOverflow`, `JumpTargetOutOfRange` | the limits of §4.4 |
| `MacroDepthExceeded` | 256 expansions in a row (MACROEXPAND.md §6) |
| `MacroExpansionFailure` | every other expansion error: a malformed macro call, a macro that threw or returned a non-form (MACROEXPAND.md §8) |
| `StackOverflow` | a form nested past the native stack budget (below) |
| `ReaderFailure` | `compileSourceWith` could not parse or read its text |
| `IntegerOutOfFixnumRange` | a hand-built `Tiny.int` outside i48 (§4.3) |
| `UnsupportedForm` | `eval` given a value that is not a form (MACROEXPAND.md §1.2); the compiler never raises it |
| `RequiredFileFailed`, `ControlTransferred` | not compile errors: the loader's run signals for a `require`d file, passed through under their own names (MACROEXPAND.md §8) |
| `InternalCompilerBug` | an invariant the compiler believes impossible, reported instead of miscompiled |
| `OutOfMemory` | |

`StackOverflow`: every recursive step of lowering and of the
`Emitter` calls `stack.check` (VM.md §13.1), so depth fails cleanly
instead of faulting; `DeclaredNames` stops descending at the same
budget.

**The span** (`CompileOptions.out_span`) is that of the innermost
form being lowered or emitted when the error was raised, or the
symbol's own for `UnresolvedSymbol` (`LowerDiag`). An expansion error
carries the span of the innermost form the expander failed at
(`ExpandContext.failure`), and its reason goes to
`CompileOptions.out_detail`. Forms a macro produced carry the call's
span, so an error inside an expansion is reported at the call. There
is no secondary span and no expansion-provenance chain. The CLI's
rendering of a compile error, and its exit status, are `TOOLING.md`
§1.

**Inside `eval`**, a compile error is not reported by the CLI: the
hook throws `{:error :compile-error :message "<variant name>" :form
<the form>}`, plus `:detail` with the expander's reason for a macro
failure, on the calling VM, a catchable value like any other throw
(MACROEXPAND.md §1.2 item 9). Uncaught, it reaches the CLI as
`UncaughtThrow` with the map as its value.

---

### 8. SrcSpan threading

- Every Form has the reader's `SrcSpan` (`Form.origin`); the expander
  gives synthetic forms the macro call's span.
- Lowering allocates every node as a `TinyNode{span, tiny}` stamped
  with its Form's span; a node lowering synthesizes (the `do` around a
  body, the constant 1 of an inlined `inc`) has none and inherits its
  enclosing form's. A hand-built `Tiny` tree compiles without spans
  (`compileTiny`).
- The `Emitter` attributes every instruction to the innermost node
  being compiled: `compileExpr` sets the current span on entry and
  restores the parent's on exit, so an instruction a parent emits
  after its children (`call:call` after the arguments, `call:return`
  after a body) carries the parent's span. `emit` grows a run-length
  table, one `SpanEntry{pc, span}` per change of span, ascending by pc.
- Each `Routine` carries the table (`spans`), the span of the form it
  was lowered from (`origin`) and the `vm.SourceInfo{path, text}` the
  spans index (`source`, from `CompileOptions.source`, owned by the
  caller); a nested prototype carries its own. `Routine.spanAt(pc)`
  is a binary search; execution never reads the table (VM.md §5).
- A named `fn*` routine (what `defn` produces) carries its name; an
  anonymous one is `fn`, a top-level form `<top>`, a form `eval` runs
  `<eval>`.

The table serves the runtime error report and `nexis disasm`
(`TOOLING.md` §1, §2).

---

### 9. Tests

`src/compile.zig` holds the tests only the compiler can see: the
error taxonomy (malformed programs with their variant and the span
each is reported at), bytecode shape (one Var-table entry per Var, one
upvalue per captured name, boxing of exactly the captured bindings on
every path, a quoted scalar needing no extra constant), the routine
limits of §4.4, the span table, declared names and the stack guard.
`test/prop/compile.zig` runs source through a program booted as
`bin/nexis` boots one: the `cases` table (source and printed value for
every primitive-core form, binding and capture shape, `recur` target,
quoted literal and the host macros the compiler relies on), the
`failures` table (source and error), inlining, slot reuse, constant
collections, `eval`'s freeing, the randomized properties (capture at
nesting depth 1..10, syntax-quote equal to the hand-built shape), and
a differential test comparing random programs over arithmetic, `if`,
shadowing `let*`, closures and counting `loop*`s against a reference
evaluator. `test/integration/eval_pipeline.zig` runs source end to
end through every host macro and every `try` exit path.

#### 9.4 Guarantees the tests pin

1. Every primitive-core form compiles and runs per §5.
2. `recur` in a 10k-iteration loop leaves `VM.stack_high_water` and
   `VM.frame_high_water` unchanged (VM.md §11).
3. Closure capture works to nesting depth 10.
4. Syntax-quote produces Forms structurally equal to hand-built ones.
5. A compile error carries its variant and span.
6. `bench/main.zig`'s `compiler` category measures compilation
   (`compile_simple`) and the whole pipeline for a 100-iteration
   `recur` loop (`eval_simple_loop`), a closure called in place
   (`closure_create`) and nested arithmetic (`eval_arith`)
   (`docs/BENCH.md`); the per-iteration cost of a `recur` loop is the
   `vm` category's `vm_loop_10k` (`docs/PERF.md` §3.8).

---

### 10. Compilation entry points

| Entry | What it does |
|---|---|
| `compileFormWith(allocator, form, options)` | Macroexpand, lower and emit one Form into a `Compiled` routine. The loader (`nexis run`, the REPL, `require`) and `eval` compile through it. |
| `compileSourceWith(allocator, source, options)` | Parse and read the first form of `source`, then `compileFormWith`; `ReaderFailure` when it cannot. |
| `compileTiny(allocator, tiny)` | Emit a hand-built `Tiny` tree: no namespace, no expansion, no span table. |

`CompileOptions` (every field optional): `namespace`, `interner`,
`host_macros`, `out_span`, `out_detail`, `io` (what a user macro's
sub-VM prints through), `persistent_allocator` (where `defmacro`
closures go), `routine_allocator` (§3), `registry` (without it `(ns
...)` is an error), `load_callback`, `declared` and `source`.

`DeclaredNames` collects the names a file or REPL line defines before
any of its forms compiles (§4.3 rule 7). `RuntimeHooks` installs the
compiler as the VM's `macroexpand-1`, `read-string` and `eval`
(MACROEXPAND.md §1.2). The loader's `evalSource` parses and reads
every top-level form first, then compiles and runs each before
compiling the next, sharing the VM's namespace, interner and macro
table.

---

### 11. Left to the implementation

The Zig shapes of `Tiny`, `Compiled`, `LowerEnv` and the `Emitter`,
and the frame stack's backing storage, are not part of this contract;
any representation that keeps the invariants above conforms.
