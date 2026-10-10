## TOOLING.md — the tooling layer: commands, error reports, disassembler, test runner, pprint, math

What `bin/nexis` gives a programmer beyond running a file: the
commands, where an error happened and how execution got there, what
the compiler made of a file, a test runner, a pretty-printer and
`nexis.math`. Each section names the module that implements it. The
samples are the committed goldens under `test/golden/cli/`, which
`zig build golden` compares byte for byte.

### 1. Commands and error output (`src/cli.zig`)

| Command | What it does |
|---|---|
| `nexis run FILE [ARG...]` | Runs FILE's top-level forms in order and prints only what the program prints. FILE `-` reads the program from stdin (reported as `<stdin>`). |
| `nexis FILE [ARG...]`, `nexis - [ARG...]` | The same as `run`, for a FILE that ends `.nx` or names an existing file (a `#!` script needs no suffix). |
| `nexis -e EXPR [ARG...]` | Evaluates EXPR's forms (reported as `<-e>`) and prints each value that is not nil, as `prn` does. |
| `nexis repl` | The read-eval-print loop below. |
| `nexis test FILE...` | Reads every file (one that cannot be read stops it before any runs, exit 2), runs each (restoring the current namespace after each), then `(nexis.test/run-all-tests)` (§3); exit 1 when an assertion failed or a test threw. A file's own definitions cannot change the exit status. `require` searches the working directory, then each file's directory. |
| `nexis doc NAME` | Prints what `(doc NAME)` prints (STDLIB.md §10) on stdout: the documentation of a function, macro, special form or namespace. A NAME that names nothing is `nexis: no documentation for NAME` on stderr, exit 1; one that does not read as one symbol (`-1`, `nil`, `a/b/c`, `(exit 7)`) is ``nexis: doc takes a symbol (try `nexis --help`)``, exit 1. |
| `nexis disasm FILE`, `nexis --disasm FILE` | §2. |
| `nexis --help`, `nexis -h` | The usage text, on stdout, exit 0. With no arguments, a command missing its FILE, or an argument `repl`, `disasm`, `--help` or `--version` takes no more of, the same text on stderr and exit 1; an unknown command is ``nexis: unknown command 'X' (try `nexis --help`)``, exit 1. |
| `nexis --version`, `nexis -V` | `nexis 0.2.0`: `nexis` and its version, on stdout, exit 0. The version is `build.zig.zon`'s `.version`, which the build passes to the CLI as the `version` build option. |

Every command evaluates through `Loader.evalSource`: parse and read
every top-level form, then compile and run each before compiling the
next, on one VM (MACROEXPAND.md §2b, the loader). `require` searches
the working directory, then the directory of the file being run.
`*command-line-args*` holds the ARGs (`run` and `-e`); a first line
that begins `#!`, after a byte-order mark if one opens the file, is a
comment, so a script can be made executable. A
file (run, tested, disassembled or required) that opens with a UTF-8
byte-order mark is read without it, so its line-1 columns and carets
count from the character after the mark (`test/golden/cli/bom.nx`;
`test/golden/cli/lib/failing.nx` is required through one).
`exit`, `read-line` and `*command-line-args*` are STDLIB.md §6.

| Exit status | Meaning |
|---|---|
| 0 | success |
| 1 | usage error; `nexis test` with a failure or an error; `nexis doc` of a name that names nothing |
| 2 | the file could not be read (`nexis: failed to read 'PATH': ErrorName`) |
| 3 | parse or reader error |
| 4 | compile error |
| 5 | runtime error that no `try` caught; an error of the command itself, such as output it cannot write or memory to boot (`nexis: runtime error: ErrorName`) |
| n | `(exit n)` |

However a command ends, through its normal end, `exit` or an error it
reports, every store file a commit left unsynced is synced once first
(`docs/DB.md` §3.3).

**A closed pipe.** When what reads the command's stdout closes it (`nexis
-e '(range 100000)' | head`), the value, disassembly, usage text or
prompt being written goes nowhere and the command ends there, with no
report and exit 0, as a JVM Clojure program's does. So does a program
whose `print`, `println`, `pr`, `prn` or `printf` writes into the
closed pipe (`nexis -e '(dotimes [i 100000] (println i))' | head -1`):
it ends at that write, every store a commit left unsynced synced
first. A JVM program's `System.out` swallows the error and runs on to
its end; nexis stops, so a program printing an endless seq ends too.

**The runtime's stack.** The runtime runs on a thread with a 1 GiB
stack reservation, committed only as it is touched (`docs/VM.md`
§13.1). A host that refuses that much (strict overcommit, a small
memory limit) gets the largest half of it it grants, down to 64 MiB,
and below that the main thread's own stack; the stack guard is armed
for whichever runs, so only the depth a program can reach shrinks.

**Environment.** `NEXIS_DURABILITY` is the durability of every store
connection that names none: `durable` (the default: every commit
syncs) or `commit` (a commit syncs nothing, and the file is synced at
close, `sync` and the end of the program); `docs/DB.md` §3.3. Any
other value stops the command before it runs with `nexis:
NEXIS_DURABILITY is not commit or durable`, exit 1.
`NEXIS_MAX_ALLOC` is below; `NEXIS_GC_STRESS` is `docs/GC.md` §7, and
any value but `1` stops the command with `nexis: NEXIS_GC_STRESS is
not 1`, exit 1.

**Dispatch counts.** A binary built with `-Dopcodes=true` counts every
dispatch by opcode (a comparison that runs its branch is one, and a
step that runs its comparison and branch, `docs/VM.md` §8, §10.10) and every native called through the VM's call paths
(an instruction, `callValue`, a `Callback`), and writes them to stderr
as CSV when the process exits, however it exits: `opcode,dispatches`
then `group:variant,N` rows (a quickened variant named as the
disassembler names it, `math:add.sc`, §2), then `native,calls` and `name,N` rows,
each most first. The counts start after the standard library's boot,
so they are the program's. Without the option the counting is compiled
out; the gate analyzes the counting build so it cannot rot.
`docs/BENCH.md` §13 uses it.

**The REPL** prints a banner (`nexis repl`, then ``Type `:quit` or hit
Ctrl-D to exit.``) and prompts with the current namespace (`user=> `,
`other=> ` after `(ns other)`). It reads lines until they hold
complete forms, so a form or a string literal may span lines and a
line may hold several; blank lines are skipped. While a form is open
each further line is prompted with `#_=> `, right-aligned under the
namespace prompt (`user=> ` then `  #_=> `, as Leiningen's REPL
prints it). A line is scanned once for the brackets, strings,
comments and character literals it opens or closes, and the text is
read only when they balance, so pasting a form of n lines costs
O(n). It evaluates every
form and prints each value on stdout as `prn` does, nil included,
whatever its size, realizing a lazy seq in it first (`docs/LAZY.md`
§8): a throw while it does is that input's runtime error, as one in
the evaluation would be, and so it is for `nexis -e`. `*1`, `*2` and
`*3` hold the last three values. A runtime error is reported on stderr, the frames, handlers and
bindings the aborted run left are discarded (`VM.resetAfterError`),
and `*e` is the thrown value, or for a VM error the error map `catch`
would have taken (`VM.errorValue`, `docs/VM.md` §13: `DivideByZero`
is `{:error :divide-by-zero :message "divide by zero" ...}`; out of
memory, which no `catch` sees, the keyword `:out-of-memory`); a parse, reader or compile
error is reported and leaves `*e` as it was. `:quit` or `:q` alone
on a line at the start of a form, or end of input, exits. Every
input's text is kept for the session, so a function defined in one
input and failing in a later one points into the input that defined
it. `test/golden/cli/repl.in` with `repl.out` and `repl.err` pin a
session.

**A parse, reader or compile error** is `nexis: PATH:LINE:COL:
LABEL`, the source line and a caret under the span the error is
about, one `^` per character up to the end of that line, so a form
that spans lines is underlined on its first (exit 3 for a parse or
reader error, 4 for a compile error). LINE and COL are 1-based and
COL counts code points, not bytes, as the trace's positions do; the
shown line has each tab as four spaces and the caret lines up beneath
(`unicode-columns.err`); a byte-order mark that opens any text, a
file's or `-e`'s, takes no column (`bom.err`, `bom-expr.err`):

```
nexis: test/golden/cli/bad-number.nx:5:10: reader error: :bad-number-literal 1-2
    (println 1-2)
             ^^^
```

The label is ``parse error: unexpected `)` `` at the token the parser
stopped on, naming the delimiter still open when the token is a closer
of another kind (``unexpected `)`; the `[` at 1:10 is open``);
``parse error: unclosed `(` `` at the innermost delimiter the text
leaves open, or `parse error: unexpected end of input` at the end when
none is; or `parse error: unterminated string` at the `"` of a string
literal no quote closes;
`reader error:
:KIND DETAIL` at the form the reader rejected (`:duplicate-literal-key
(keyword :a_b)`, FORMS.md §3); `compile error: SENTENCE` at the span
COMPILER.md §7 gives, the sentence saying what failed: the expander's
reason for a macro expansion that failed (MACROEXPAND.md §8), at the
innermost form that failed; `unable to resolve symbol: foo`; a routine
limit with the routine and the limit (COMPILER.md §4.4,
`too-many-locals.err`). A compile error with nothing to add reads
`compile error: NAME`, the `CompileError` name.

```
nexis: test/golden/cli/macro-failure.nx:4:1: compile error: macro m threw bad macro input
    (m 1)
    ^^^^^
nexis: test/golden/cli/too-many-locals.nx:7:3: compile error: fn many: more than 4096 local slots
      (let-many 4100 a0))
      ^^^^^^^^^^^^^^^^^^
```

A file `require` could not load is reported in that file at its
place (a parse, reader or compile error there), or at the requiring
form: `require: no file my/app.nx on the load path`, `require: cyclic
require of my.app`, `require: PATH does not begin with (ns my.app)`
(metadata on the name, `(ns ^:no-doc my.app)`, is allowed).

A Clojure idiom nexis lacks adds, after `; `, one clause on what to
write instead, so a program written from Clojure finds the nexis
spelling at the error: an unresolved Java constructor, method or
class member (`Exception.`: ``throw (ex-info "message" {:key
value})``; `.toUpperCase`: `nexis.string/upper-case`; `Math/sqrt`:
`nexis.math/sqrt`; `System/getenv`: `nexis.sys/getenv`), a name of
Clojure's threads, agents or STM (`future`, `pmap`, `agent`,
`thread`, `dosync`), a ratio or BigDecimal literal (`1/3`, `1.5M`), a
tagged literal (`#inst`, `#uuid`) and a library with no counterpart
(`clojure.java.io`). The tables are `expand.idiomHint` and
`namespaceHint` and `reader.numberLiteralHint` and
`taggedLiteralHint`; a name the program defines itself is its own, so
`(defn thread ...)` resolves as any other.

```
nexis: <-e>:1:2: compile error: unable to resolve symbol: Exception.; nexis has no Java classes: throw (ex-info "message" {:key value}), or any value
nexis: <-e>:1:1: reader error: :bad-number-literal 1/3; nexis has no ratios: (/ 1 3) divides, to a double when inexact
```

**A runtime error** that no `try` catches ends the program with exit
5 and this report on stderr:

```
nexis: test/golden/cli/divide-by-zero.nx:5:3: runtime error: DivideByZero
      (/ total n))
      ^^^^^^^^^^^
  at average (test/golden/cli/divide-by-zero.nx:5:3)
  at report (test/golden/cli/divide-by-zero.nx:8:3)
  at <top> (test/golden/cli/divide-by-zero.nx:10:1)
```

- The header locates the instruction that raised the error through
  the routine's span table (COMPILER.md §8) and names the `VmError`
  (VM.md §13). When the VM wrote a sentence to `vm.error_detail` it
  follows after `: ` (`runtime error: ArityMismatch: f takes 1
  argument, got 0`). An uncaught throw is `UncaughtThrow` followed by
  the thrown value as `pr-str` prints it (`runtime error:
  UncaughtThrow {:error :negative, :value -3}`, `uncaught-throw.err`,
  whose `throw` spans two lines and is underlined on its first). An
  error map's place keys (`:fn`, `:file`, `:line`, `:column`; VM.md
  §13) are left out when they name the frame the trace shows the
  error raised in, the innermost running the program's code, which
  the header and the trace then show; a map the program built, or one
  a handler changed (`(throw (assoc e :k v))`, reported at that
  throw), is printed whole. An
  error or a thrown value that leaves through a `finally`, a `catch`
  no clause of which matches, or a `catch` that throws it again is
  reported where it was raised, with its detail and the frames it left,
  as it would be with no `try` around it (VM.md §12;
  `rethrow-finally.err`, `rethrow-catch.err`).

- One `at NAME (PATH:LINE:COL)` line per frame of `vm.error_trace`,
  innermost first: `defn` and named `fn*` routines carry their name,
  an anonymous closure is `fn`, a top-level form `<top>`, a form
  `eval` runs `<eval>` (listed by name alone: it has no source). A
  caller's position is its call. A closure a native called back
  (`map`, `reduce`) is its own frame; the native has none. A chain
  longer than 41 frames keeps its innermost 32 and outermost 8 around
  one line `  <N frames elided>`, N the frames between them, which has
  no `at` (VM.md §13; `deep-trace.err`), so a runaway recursion ending
  in `StackOverflow` lists 41 lines.
- Out of memory is a runtime error like the rest: `runtime error:
  OutOfMemory` at the call whose allocation failed, with its frames
  (`out-of-memory.err`). No `try` catches it (VM.md §13); what the
  failed allocation was building is unreachable, so the heap stays
  usable and the REPL carries on; a `with-out-str` capture the error
  left open is discarded, so the next input prints (`repl.in`). Memory that runs out while reading,
  compiling or printing is reported the same way with no position.
  With `NEXIS_MAX_ALLOC=BYTES` in the environment every allocation, or
  growth of one, past BYTES fails as a request the machine refuses
  does; the goldens reach this report through it without exhausting
  the machine.
- A form a macro produced reports at the macro call.
- A frame without a span table (a routine built from hand-written
  bytecode) is listed by name alone; when the innermost frame has none
  the header carries no position.
- A file loaded by `require` reports under its own path, its
  top-level forms as `<top>`. The file runs while the requiring form
  is being compiled, so when one of its forms fails with no handler in
  force the report is a runtime error's (exit 5), not a compile
  error's, and the chain ends at the file's `<top>`
  (`require-runtime-error.err`). A file required through `eval` runs
  inside the program, so a handler in the caller takes its throw.

`test/golden/cli/` pins each report and command above (`build.zig`
lists the cases); `test/integration/eval_pipeline.zig` asserts the
line, column and frame names of the trace.

### 2. Disassembler (`src/disasm.zig`)

`nexis disasm FILE` compiles FILE the way `run` does and prints every
routine on stdout instead of running it: each top-level form's
routine, then every routine its capture descriptors build, depth
first, a blank line between routines. A multi-arity fn lists every
member of its arity table (VM.md §5) by arity, the rest clause last,
each with its own header, and then the routines their descriptors
build; `test/golden/cli/multi-arity.disasm` pins one. `test/golden/cli/sum10.disasm`
pins the listing of `test/examples/pins/sum10.nx`:

```
routine <top> (test/examples/pins/sum10.nx:5:1) slots=6 arity=0 upvalues=0
  0000  var:load-var        s1  v0=nexis.core/println  ; 5:2
  0001  mov:load-const      s3  c0=0  ; 6:13
  0002  mov:load-const      s4  c0=0  ; 6:19
  0003  cmp:lt.sc+if-false  s5  s3  c1=10  ; 7:9
  0004  jump:if-false       s5  j0009  ; 7:5
  0005  math:add.ss         s4  s4  s3  ; 8:22
  0006  math:add.sc+lt.sc+if-true  s3  s3  c2=1  ; 8:14
  0007  cmp:lt.sc+if-true   s5  s3  c1=10  ; 7:9
  0008  jump:if-true        s5  j0005  ; 7:5
  0009  mov:move-clear      s2  s4  -  ; 9:7
  0010  call:call           s1  #1  s0  ; 5:1
  0011  call:return.s       s0  -  -
```

The loop is pcs 5-8, four instructions and two dispatches per
iteration: the inlined `<` and `+` read their operands in place,
`recur` computes `(+ acc i)` before `(+ i 1)`, which cannot fail, so
neither waits in a temporary, and it repeats the loop's test,
branching back while it holds (COMPILER.md §5.6, §5.7); `(+ i 1)` is
the step that runs the test and the branch with it (VM.md §10.10).
Pc 9 moves `acc` into `println`'s block at its last read, so the move
clears its slot (COMPILER.md §4.9).

- The header: the routine's name, the path and position of the form
  it was lowered from, its slot count, its fixed arity (`+rest` when
  variadic) and its upvalue count.
- One line per instruction: the pc, `group:variant` as VM.md §10
  names them (a quickened variant as its base's name and its form,
  `math:add.sc`, and a step with the comparison it runs,
  `math:add.sc+lt.sc+if-true`, VM.md §10.10), then operands A, B and C, or operand A and the wide
  field for an instruction that has one (VM.md §3). An operand prints
  its kind letter and index (VM.md §4: `s` slot, `c` constant, `v`
  var, `u` upvalue, `i` intern, `e` durable), `-` when unused. A
  constant shows its value as `pr-str` prints it (`c2=1`), cut at a
  space within 60 bytes and followed by ` ...` and, for a collection,
  its item count when longer (`c0=[0 1 2 ... 22 ...(5000 items)`); a
  var its namespace-qualified name (`v0=nexis.core/println`). Operand B of `call:call`,
  `call:self` and every `coll:*` is a raw immediate (VM.md §4.5) and
  prints as `#n`. The wide field prints as what it names: a jump
  or `try-exit` target as its pc (`j0009`), `mov:load-const`'s
  constant and a `var:*` Var as a `c` or `v` operand would,
  `try-enter`'s try as `#n<catch j0012 finally j0015>`, and
  `closure:make`'s capture descriptor as `#n<routine NAME>[sources]`,
  `sN` for a cell in this frame's slot N and `uN` for this closure's
  upvalue N (`#0<routine adder>[s0]`, `[]` for none), with a
  multi-arity fn's arities after its name
  (`#0<routine f arities 0,1,2+rest>[s3]`). An unnamed group or
  variant prints its number after `?`.
- `; LINE:COL` is the source position of the form an instruction was
  lowered from, printed where the span table changes (VM.md §5); an
  instruction without one carries the last one printed.

Macro expansion, `(ns ...)` and `(require ...)` take effect while the
file compiles, but no form runs, so a macro that calls a function the
same file defines cannot expand under `disasm`. The opcode names are
the tags of the group and variant enums in `src/vm.zig`, `_` spelled
`-` and a trailing `_` dropped, and what each operand is, an immediate
or a wide field, is what verification proves (`Routine.shapeOf`, VM.md
§5).

### 3. Test runner (`src/stdlib/test.nx`, the `nexis.test` namespace)

`nexis.test` is written in nexis over atoms and `throw`, embedded at
build and booted at start (STDLIB.md §1); `(require '[nexis.test :as
t])` only makes the alias, and `:refer :all` refers the API but not
the private helpers.

```clojure
(t/deftest area-test
  (t/testing "rectangles"
    (t/is (= 6 (area 2 3)))
    (t/is (t/thrown? :divide-by-zero (area 1 (/ 1 0))))))
(t/run-tests)
```

- `(deftest name body...)` defines `name` as a function of no
  arguments and registers it under the current namespace in the atom
  `nexis.test/tests` (namespace name → vector of `[name fn]` in
  definition order); a second `deftest` of the same name replaces the
  first in place. The form's value is the Var. The current namespace
  is read at run time through `nexis.internal/#%current-ns`, since a
  macro body runs in a compile-time VM with no registry.
- `(is (= expected actual) msg?)` reports both values on failure.
  `(is (thrown? MATCHER expr) msg?)` passes when `expr` throws a value
  `(catch MATCHER ...)` would take (a keyword tag, MACROEXPAND.md §2b,
  or `any`) and fails when `expr` returns, reporting the value; a
  throw the matcher does not take propagates and counts as an error.
  `(is expr msg?)` passes when `expr` is truthy. Every `is` returns
  whether it passed. The head is matched by name, so `t/thrown?` and
  `thrown?` are the same. `msg` is evaluated once, after the values,
  whether the assertion passes or fails, as in Clojure. An assertion
  is one call of a helper (`check=`, `check-truthy`; a
  `thrown?` with a keyword tag is a `try` whose handler calls
  `check-thrown`) with the quoted form, the values and the message,
  so the judging and the reporting are compiled once, in
  `nexis.test`: `(is (= a 1))` as a function's body is seven
  instructions, the helper, the form, the two values, the message, the
  call and the return (COMPILER.md §4.8).
- `(are [x y] (= x (f y)) 2 1 3 2)` is `(do (is (= 2 (f 1))) (is
  (= 3 (f 2))))`: the template once per group of values, each
  substituted for the names of the vector through
  `nexis.walk/postwalk-replace`, as Clojure's `are` does through
  `clojure.template/do-template`. A number of values that is not a
  multiple of the names' (or values with no names) fails the
  expansion with Clojure's message; `(are [] true)` is nil.
- `(testing "description" body...)` pushes the description for the
  extent of `body`, popped on every exit; descriptions nest.
- `(use-fixtures :once f...)` and `(use-fixtures :each f...)` set the
  current namespace's fixtures, a later call replacing the earlier of
  its kind; any other kind is `:invalid-argument`. A fixture is a
  function of the function it wraps, which it calls: the `:once`
  fixtures wrap the run of the namespace's tests, the `:each`
  fixtures each test, the first given outermost
  (`join-fixtures`, `compose-fixtures`). A fixture's throw is not a
  test's and propagates out of the run, as in Clojure.
- `(run-tests)` runs the current namespace's tests in definition
  order, `(run-tests 'my.ns)` a named namespace's, `(run-all-tests)`
  every namespace that registered a test, in first-registration
  order. Each returns `{:test n :pass n :fail n :error n}`: tests
  run, assertions passed, assertions failed, tests that threw. A
  test's throw is caught by `any` and counted as an error; the next
  test still runs. `(successful? summary)` is whether a summary has
  no failure and no error.
- Outside a run (at the REPL, or a test function called directly) an
  assertion judges, reports and returns as in one, but counts
  nothing; its report line names only the descriptions in force
  (`FAIL (ctx): ...`). A run's end leaves no test current.
- Every report line goes through the function in the atom
  `nexis.test/out`, `println` unless replaced (a harness without
  stdout collects the lines instead). One line per failure names the
  test, the descriptions in force, the form, the expected and actual
  values (`pr-str`) and the message when given. A test's error names
  an error map by its tag, its message and the file name, line and
  column it was raised at (`ERROR in user/t: :divide-by-zero divide
  by zero at app.nx:12:5`), any other thrown value as `pr-str` prints
  it. `examples/tests-demo.nx` shows every outcome:

  ```
  FAIL in user/failing-test (a wrong expectation): (= 5 (area 2 2)) expected: 5 actual: 4 ; areas multiply
  ERROR in user/erroring-test: {:message "not a number", :data {:error :bad-age, :input "one"}}
  FAIL in user/bare-test: (empty? [1]) expected: true actual: false ; a bare assertion that fails
  Ran 5 tests containing 10 assertions.
  2 failures, 1 errors.
  ```

`test/golden/cli/tests.out` pins `nexis test`;
`test/integration/eval_pipeline.zig` pins the counts and the report
lines; `zig build examples` runs the demo.

### 4. `nexis.pprint` and `nexis.math`

**`nexis.pprint`** (`src/stdlib/pprint.nx`): `(pprint x)` prints `x`
and a newline, `(pprint-str x)` returns the text. A collection whose
`pr-str` fits within 72 columns from its indent prints on one line,
as `pr-str` prints it. A longer one breaks: a map one `key value`
pair per line, separated by `,`, each value laid out from the column
after its key; a vector, list or set of scalars filled line by line
within the width, aligned after the opening bracket; one holding a
collection one element per line, each laid out from its own column.
Records and empty collections print flat. `test/golden/cli/pprint.out`
pins the layout.

**`nexis.math`** is Clojure's `clojure.math`, which names it in
`require` (`src/stdlib.zig` `math_natives`, `src/stdlib/math.nx` for
`PI`, `E`, `floor-div` and `floor-mod`):

| Name | Result |
|---|---|
| `sqrt`, `pow` | over doubles; a float for any number in the tower: `(sqrt 16)` is `4.0`, `(pow 2 10)` is `1024.0` |
| `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `exp`, `expm1`, `log`, `log10`, `log1p`, `cbrt`, `hypot` | Java's `Math` method of the name over doubles, a float for any number; NaN and the infinities as IEEE and Java give them, never an error (`(log 0)` is `##-Inf`, `(asin 2)` `##NaN`, `(hypot ##Inf ##NaN)` `##Inf`). The results are the platform library's (Zig's `std.math` and the C library's `sin`, `cos`, `tan`, `exp`, `log`, `log10`), within an ulp of Java's, which leaves the last bit to the implementation too: `(log 3)` is `1.0986122886681098` here and `1.0986122886681096` on the JVM |
| `signum` | `-1.0`, `1.0`, or a zero or NaN itself, as `Math/signum` |
| `to-radians`, `to-degrees` | one multiplication by Java's constant, so Java's result to the bit: `(to-degrees PI)` is `180.0` |
| `floor-div`, `floor-mod` | `Math/floorDiv` and `Math/floorMod` of the arguments as longs (a float truncated, as Clojure casts it): the quotient toward negative infinity and the remainder with the divisor's sign; any integer size, a quotient past the long range a bignum (`(floor-div -9223372036854775808 -1)`, Java's `Long/MIN_VALUE` by `-1`, is `9223372036854775808`; SEMANTICS.md §2.2); a zero divisor is `:divide-by-zero` |
| `floor`, `ceil` | an integer unchanged; a float's floor or ceiling as a float: `(floor 2.7)` is `2.0` |
| `round` | an integer unchanged; a float's nearest integer, halves up, as a fixnum or bignum, as Java's `Math/round`: `(round 2.5)` is `3`, `(round -2.5)` is `-2`, `(round 0.49999999999999994)` is `0`; NaN is `0`, and a float past the long range, an infinity included, is `9223372036854775807` or `-9223372036854775808`, Java's `Long/MAX_VALUE` or `Long/MIN_VALUE` |
| `PI`, `E` | the doubles |

`abs` is `nexis.core/abs`. Absent from `clojure.math`: `rint`,
`IEEE-remainder`, `copy-sign`, `ulp`, `next-after`, `next-up`,
`next-down`, `scalb`, `get-exponent`, `random` and the `-exact`
functions. `test/integration/numbers.zig` pins each.
