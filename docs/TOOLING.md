## TOOLING.md — the tooling layer: error output, disassembler, test runner, pprint, math

What `bin/nexis` gives a programmer beyond running a file: where a
runtime error happened and how execution got there, what the
compiler made of a file, a test runner, a pretty-printer and the
`nexis.math` functions. Each section names the module that
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
  `fn`, a top-level form `<top>`, a form `eval` runs `<eval>`,
  listed by name alone since it has no source) and the position of the
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

### 3. Test runner (`src/stdlib/test.nx`, the `nexis.test` namespace)

`nexis.test` is written in nexis over atoms and `throw`, embedded
at build and bootstrapped at start; `(require '[nexis.test :as t])`
aliases it (it has no file to load). `examples/tests-demo.nx` shows
every outcome.

```clojure
(t/deftest area-test
  (t/testing "rectangles"
    (t/is (= 6 (area 2 3)))
    (t/is (t/thrown? :divide-by-zero (area 1 (/ 1 0))))))
(t/run-tests)
```

- `(deftest name body...)` defines `name` as a function of no
  arguments and registers it under the current namespace in a
  registry the namespace `nexis.test/tests` holds in an atom:
  namespace name → vector of `[name fn]` in definition order; a
  second `deftest` of the same name replaces the first in place.
  The form's value is the Var.
- `(is (= expected actual) msg?)` reports the two values on
  failure; `(is (thrown? MATCHER expr) msg?)` passes when `expr`
  throws a value `(catch MATCHER ...)` would take (a keyword tag
  under the rule of `MACROEXPAND.md` §10 or `any`) and fails when
  `expr` returns, reporting the value; a throw the matcher does
  not take propagates and counts as an error. `(is expr msg?)`
  passes when `expr` is truthy. Every `is` returns whether it
  passed. The head is matched by name, so `t/thrown?` and
  `thrown?` are the same.
- `(testing "description" body...)` pushes the description for the
  extent of `body`, popped on every exit; descriptions nest.
- `(run-tests)` runs the current namespace's tests in definition
  order, `(run-tests 'my.ns)` a named namespace's,
  `(run-all-tests)` every namespace that registered a test, in
  first-registration order. Each returns `{:test n :pass n :fail n
  :error n}`: tests run, assertions passed, assertions failed,
  tests that threw. A test's throw is caught by `any` and counted
  as an error; the next test still runs.
- Every report line goes through the function in the atom
  `nexis.test/out`, `println` unless replaced (a harness without
  stdout collects the lines instead). One line per failure names
  the test, the descriptions in force, the form, the expected and
  the actual value (`pr-str`) and the message when given:

  ```
  FAIL in user/failing-test (a wrong expectation): (= 5 (area 2 2)) expected: 5 actual: 4 ; areas multiply
  ERROR in user/erroring-test: :divide-by-zero
  Ran 5 tests containing 8 assertions.
  2 failures, 1 errors.
  ```

- `nexis.internal/#%current-ns` is the native `deftest` and
  `run-tests` read the current namespace's name from at run time,
  since a macro body runs in a compile-time VM that has no
  registry.

No keyword literal appears in `test.nx`: the file is compiled at
boot, ahead of every keyword a script reads, and a map's layout is
a function of intern order; the keys of the result map are built
when `run-tests` returns. `test/integration/eval_pipeline.zig` pins
the counts and the report lines; `zig build examples` runs the
demo.

### 4. `nexis.pprint` and `nexis.math`

**`nexis.pprint`** (`src/stdlib/pprint.nx`): `(pprint x)` prints
`x` and a newline, `(pprint-str x)` returns the text. A collection
whose `pr-str` fits within 72 columns from its indent prints on
one line, as `pr-str` prints it; a longer one breaks: a map one
`key value` pair per line, separated by `,`, each value laid out
from the column after its key; a vector, list or set of scalars
filled line by line within the width, aligned after the opening
bracket; one holding a collection one element per line, each laid
out from its own column. Records and empty collections print flat.
`test/golden/cli/pprint.out` pins the layout.

**`nexis.math`** (`src/stdlib.zig` `math_fns` + `src/stdlib/math.nx`):
`sqrt` and `pow` are over doubles and return a float for any
number in the tower (`(sqrt 16)` is `4.0`, `(pow 2 10)` is
`1024.0`); `floor` and `ceil` return an integer unchanged and a
float's floor or ceiling as a float; `round` returns an integer
unchanged and a float's nearest integer, halves up, as a fixnum or
bignum (`(round 2.5)` is `3`, `(round -2.5)` is `-2`; NaN and the
infinities are `:invalid-argument`). `PI` and `E` are the doubles.
`abs` is `nexis.core/abs` and is not duplicated here.
`test/integration/numbers.zig` pins each.
