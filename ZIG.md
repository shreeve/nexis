# Zig in nexis

The Zig idioms this tree depends on and the traps that bit it. nexis
builds with Zig 0.17.0 (`build.zig.zon` `minimum_zig_version`). For
the language and standard library at large, read the shared guide,
[ZIG-0.17.md](https://github.com/shreeve/zig-agent-docs/blob/main/ZIG-0.17.md):
its API tables, format specifiers and compile-error decoder are all
checked against 0.17.0. Where an API is in neither, the installed
standard library is the authority (`zig env` prints `std_dir`;
`grep -n 'pub fn NAME'` there beats any prose), or compile a
five-line probe.

---

## 1. Traps that compile

These build cleanly and misbehave at run time.

- **A `defer` never runs past `@call(.always_tail, ...)`.** A function
  that returns through a tail call leaves its frame before the call,
  so its `defer` and `errdefer` blocks are skipped, in every build
  mode, and Zig says nothing. A VM handler that tail-calls the next
  one (`docs/VM.md` §6) releases what it holds before the call, not
  in a `defer`.
- **`init.gpa` is a `SafeAllocator` in debug and safe builds.** In
  Debug it records a stack trace per allocation, which makes
  allocation-heavy code about a hundred times slower. The CLI uses
  `std.heap.SafeAllocator.init(std.heap.page_allocator, .{ .stack_trace_frames = 0 })`
  in Debug (the leak check kept, the traces dropped) and `init.gpa`
  otherwise (`src/cli.zig` `runCommand`); the test harness and the
  allocation-heavy tests do the same. `deinit()` returns the leak
  count and logs each leak as an error, which fails a test.
- **`std.Io.Threaded.global_single_threaded` has a failing
  allocator.** Its `Io` suits leaf syscalls only: any operation that
  allocates returns `error.OutOfMemory`. The tree uses it in two
  places: entropy for a store's UUID (`src/nextomic/store.zig`:
  `global_single_threaded.io().random(&buf)`), and the `Io` of the
  natives that read a clock or the file system when the host gave the
  VM none, as the test harness does (`src/stdlib.zig` `ioOf`: the
  `rand` seed, `nano-time`, `slurp`, `spit`, `db/open`). Everything
  else gets the real `io` threaded from `main`.
- **The native stack is finite and nothing checks it for you.** A
  Zig recursion on user-controlled depth segfaults when it runs out.
  Every such function calls `try stack.check()` on entry
  (`src/stack.zig`, `docs/VM.md` §13.1). The CLI runs the runtime on a
  thread with a 1 GiB stack (virtual; pages commit when touched) and
  arms the guard at that thread's entry; when no host armed it,
  `VM.init` arms a 6 MiB budget sized for a default 8 MiB main-thread
  stack.
- **A slice from `Writer.Allocating.written()` dies at the next
  write.** Copy it, or take `toOwnedSlice()`, before writing again.
- **`zig build` replays a cached run.** A step whose inputs are
  unchanged runs nothing: a second gate on the same tree prints no
  test counts. The count of record comes from a run that ran: a
  changed input, or `--cache-dir` naming an empty directory.
- **A run step inherits the caller's environment unhashed.** A
  variable the program reads that the build did not set on the step
  is not part of its cache key, so a result made under one value
  replays under another. The build gives every cached run of a
  binary it builds an empty environment (`build.zig` `RunEnv.apply`)
  and sets what the run needs on the step.

---

## 2. Program entry and `io`

- `src/cli.zig` starts with `pub fn main(init: std.process.Init) !void`,
  `src/golden.zig` and `bench/main.zig` with `!u8` (the exit status);
  `init` carries `gpa`, `io`, `arena` (process lifetime),
  `environ_map` and `minimal.args`.
- The CLI spawns the runtime thread with
  `std.Thread.spawn(.{ .stack_size = 1 << 30 }, runtimeThread, .{ init, &result })`
  and joins it; `init` is passed by value.
- `io` reaches the runtime as a field: `vm.io` (optional, set by the
  host) and the loader's `io`. A native that prints or reads reaches
  it through `vm.io`.
- `std.process.exit(status)` ends the process without unwinding
  (`(exit n)` and the CLI's error exits).

---

## 3. Platform calls through `std.c`

The runtime links libc on every target (`build.zig` `runtime`) and
calls it directly where the `Io` interface would add plumbing and
nothing else.

| Need | Call | Where |
|---|---|---|
| monotonic and wall clocks | `var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.MONOTONIC, &ts);` (`.REALTIME` for wall time) | `src/bench.zig`, `src/nextomic/store.zig`, `src/nextomic/query/exec.zig` |
| an environment variable | `std.c.getenv("NEXIS_GC_STRESS") != null` | `src/vm.zig`, `src/db.zig`, `bench/main.zig` |
| the process id | `std.c.getpid()` | `bench/main.zig` |
| unlink a file | `_ = std.c.unlink(path.ptr)` (a sentinel-terminated path) | `bench/main.zig` |

---

## 4. Language rules the tree depends on

- **Packed types.** `vm.Operand` is `packed struct(u16)` and
  `vm.Inst` is `packed struct(u64)`: the backing integer is spelled
  out, and a packed type holds no pointers (store a `usize` and use
  `@ptrFromInt`/`@intFromPtr`).
- **Threaded dispatch.** The VM's handlers end in
  `@call(.always_tail, ...)` through a 4096-entry table
  (`docs/VM.md` §6). Zig's own x86_64 backend cannot compile it, so
  every x86_64 binary builds through LLVM (`build.zig` `useLlvm`).
- **`@frameAddress()`** gives the current frame's address; the stack
  guard compares it with the armed limit (stacks grow down on every
  target nexis builds for).
- **No doc comment on a test.** `///` before `test "..."` is an error;
  use `//`.

---

## 5. build.zig and build.zig.zon

- emdb is a path dependency, `.emdb = .{ .path = "../emdb" }`, so the
  two checkouts are siblings.
- `build()` runs only when `build.zig`, a `-D` option or a declared
  input changes. Every file it reads is declared:
  `b.dependOnFileContents` for the sources `checkLayering` reads,
  `b.dependOnDirectoryContents` for each directory it lists. A check
  for a file that may not exist depends on its directory's entries
  (`exists`). A run reads the files it is compared with when it runs
  (`expect_stdout_snapshot`, `expect_stderr_snapshot`), so they are
  its inputs, never the configuration's.
- `build()` never reads its own environment. What a run needs comes
  from an option and is set on the step (`RunEnv`: `-Dgc-stress`,
  `-Ddurability`), so it is part of the step's cache key.
- `b.addFail(message)` makes a step that fails with a message; the
  layering check and a missing expected file use it.
- `build()` cannot see the install prefix: the build runner chooses
  it when it runs the steps. `zig build install` passes it to a step
  (`install`, a `LazyPath` relative to `install_bin`) that puts
  `bin/nexis` in the checkout for the default prefix and in
  `<prefix>/bin` for `--prefix`.
- `zig fmt --check` before a commit; the generated `src/parser.zig` is
  the one file that does not pass.
