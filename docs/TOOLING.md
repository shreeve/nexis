## TOOLING.md — the tooling layer: error output, disassembler

What `bin/nexis` shows a programmer beyond running a file: where a
runtime error happened and how execution got there, and what the
compiler made of a file. Each section names the module that
implements it and the section of the layer contract it rests on.

### 1. Runtime error output (`src/cli.zig`, `src/vm.zig` §13)

A runtime error that no `try` catches ends `nexis run` with exit 5
and this report on stderr:

```
nexis: test/golden/cli/divide-by-zero.nx:5:4: runtime error: DivideByZero
      (/ total n))
       ^^^^^^^^^
  at average (test/golden/cli/divide-by-zero.nx:5:4)
  at report (test/golden/cli/divide-by-zero.nx:8:4)
  at <top> (test/golden/cli/divide-by-zero.nx:10:2)
```

- The header locates the instruction that raised the error through
  the routine's span table (`COMPILER.md` §8): the path, the
  1-based line and column of the form the instruction was lowered
  from, and the `VmError` name. An uncaught throw is
  `UncaughtThrow` followed by the thrown value as `pr-str` prints
  it. The source line and a caret under the span follow, exactly as
  a compile error's do.
- One `at` line per frame of the chain the VM recorded
  (`VM.md` §13), innermost first: the routine's name (`defn` and
  named `fn*` routines carry their name, an anonymous closure is
  `fn`, a top-level form `<top>`) and the position of the
  instruction that frame was executing, which for a caller is its
  call. A closure a native called back (`map`, `reduce`) appears
  as its own frame; the native itself has none.
- A form that a macro produced reports at the macro call, since
  its forms carry the call's span.
- The REPL reports under `<repl>` and keeps every line's source,
  so a function defined on one line and failing on a later one
  points into the line that defined it. A file loaded by `require`
  reports under its own path.
- A routine without a span table (one built from hand-written
  bytecode) is listed by name alone; when the innermost frame has
  none the header carries no position.

`test/golden/cli/*.nx` pin the report byte for byte (`zig build
golden`); `test/integration/eval_pipeline.zig` asserts the line,
column and frame names of two-deep calls through the VM's trace.

### 2. Disassembler (`src/disasm.zig`)

`nexis disasm FILE.nx` (or `nexis --disasm FILE.nx`) compiles FILE
the way `run` does and prints every routine instead of running it:
each top-level form's routine, then the prototype of every closure
nested in it, depth first.

```
routine <top> (examples/sum10.nx:4:2) slots=12 arity=0 upvalues=0
  0000  mov:load-const      s1  c0=0  -  ; 4:11
  0001  mov:load-const      s2  c1=0  -  ; 4:17
  0002  mov:move            s4  s1  -  ; 5:10
  0003  mov:load-const      s5  c2=10  -  ; 5:12
  0004  cmp:lt              s3  s4  s5  ; 5:8
  0005  jump:if-false       j0016  s3  -  ; 5:4
```

- The header: the routine's name, the path and position of the
  form it was lowered from, its slot count, its fixed arity
  (`+rest` when variadic) and its upvalue count.
- One line per instruction: the pc, `group:variant` as `VM.md`
  §10 names them, then operands A, B and C. An operand prints its
  kind letter and index (`VM.md` §4: `s` slot, `c` constant, `v`
  var, `u` upvalue, `i` intern, `j` jump, `e` durable), `-` when
  unused. A constant shows its value as `pr-str` prints it
  (`c0=:x`) or the routine it holds (`c0=<routine greet>`); a var
  its name (`v0=greet`); a jump target its pc (`j0016`). Operand
  B of `call:call`, `call:tailcall`, `closure:make` and every
  `coll:*` is a raw immediate (`VM.md` §4.5) and prints as `#n`.
  An unnamed group or variant prints its number after `?`; an
  extension instruction prints `extension`.
- `; line:col` after an instruction is the source position of the
  form it was lowered from, printed where the span table changes
  (`VM.md` §5); instructions without an annotation carry the last
  one printed.

Macro expansion, `(ns ...)` and `(require ...)` take effect while
the file compiles, but no form runs, so a macro that calls a
function the same file defines cannot expand under `disasm`.

The opcode names are tables in `src/disasm.zig`, one per dispatched
group; a test walks every variant enum `src/vm.zig` defines and
fails when a variant lacks a name, so an opcode cannot be added
without one. `test/golden/cli/sum10.disasm` pins the listing of
`examples/sum10.nx`.
