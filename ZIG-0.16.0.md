# Zig 0.16 in nexis

The Zig idioms this tree uses, the traps that bit it, and the compile
errors they produce. nexis builds with Zig 0.16.0 (`build.zig.zon`
`minimum_zig_version`). This note is not a Zig reference: when an API
is not here, read the installed standard library, which is the only
authority (`zig env` prints `std_dir`; `grep -n 'pub fn NAME'` there
beats any prose), or compile a five-line probe.

---

## 1. Traps that compile

These build cleanly and misbehave at run time.

- **`init.gpa` is a `DebugAllocator` in a Debug build.** It checks
  for leaks at exit and records a stack trace per allocation, which
  makes allocation-heavy code about a thousand times slower. The CLI
  uses `std.heap.DebugAllocator(.{ .stack_trace_frames = 0 })` in
  Debug (leak check kept, traces dropped) and `init.gpa` otherwise
  (`src/cli.zig` `runCommand`). Tests use `std.testing.allocator`.
- **`std.Io.Threaded.global_single_threaded` has a failing
  allocator.** Its `Io` suits leaf syscalls only: any vtable
  operation that allocates returns `error.OutOfMemory`. The tree uses
  it for one thing, entropy for a store's UUID
  (`src/nextomic/store.zig`:
  `global_single_threaded.io().random(&buf)`). Everything else gets
  the real `io` threaded from `main`.
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

---

## 2. Program entry

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;                     // the process's Io
    const gpa = init.gpa;                   // see §1
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    ...
}
```

- `std.process.Init` carries `gpa`, `io`, `arena` (process lifetime),
  `environ_map` and `minimal.args`. `src/cli.zig`, `src/golden.zig`
  and `bench/main.zig` all start this way.
- The CLI spawns the runtime thread with
  `std.Thread.spawn(.{ .stack_size = 1 << 30 }, runtimeThread, .{ init, &result })`
  and joins it; `init` is passed by value.
- `io` reaches the runtime as a field: `vm.io` (optional, set by the
  host) and the loader's `io`. A native that prints or reads reaches
  it through `vm.io`.
- `std.process.exit(status)` ends the process without unwinding
  (`(exit n)` and the CLI's error exits).

---

## 3. Files and standard streams

Every file operation takes `io`. `std.fs` keeps only `std.fs.path`
(still the canonical path module; `std.Io.Dir.path` is an alias).

| Operation | Spelling |
|---|---|
| read a whole file | `std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))` or `.unlimited`; the limit is an `Io.Limit`, and exceeding it is `error.StreamTooLong` |
| write a whole file | `var f = try std.Io.Dir.cwd().createFile(io, path, .{}); defer f.close(io); try f.writeStreamingAll(io, bytes);` (`Dir.writeFile(io, .{ .sub_path, .data })` does the same) |
| other directory calls | `std.Io.Dir.cwd().{openDir, access, createDirPath, deleteTree}(io, ...)` |
| close | `file.close(io)`, `dir.close(io)`: the handle first, then `io` |
| write stdout or stderr | `std.Io.File.stdout().writeStreamingAll(io, bytes)`; a `File` has no one-argument `writeAll` |
| read stdin to the end | `var r = std.Io.File.stdin().readerStreaming(io, &buf);` then `r.interface.allocRemaining(gpa, .unlimited)` |
| read stdin by line | `r.interface.takeDelimiter('\n')`: `?[]u8`, null at end of input, `error.StreamTooLong` past the buffer (`src/stdlib.zig` `readStdinLine`) |
| paths | `std.fs.path.join`, `dirname`, `basename`, `resolvePosix` |
| tests | `std.testing.io`, `std.testing.tmpDir(.{})` |

---

## 4. Writers

The printer and every text native write to a `*std.Io.Writer`
(`src/format.zig`). Two concrete writers cover the tree:

```zig
var buf: [256]u8 = undefined;
var w = std.Io.Writer.fixed(&buf);        // fixed buffer; error.WriteFailed when full
try w.print("{d}", .{n});
const text = w.buffered();                // what was written

var out: std.Io.Writer.Allocating = .init(gpa);   // growable
defer out.deinit();
try out.writer.print("{s}", .{name});     // `writer` is a field, not a method
const bytes = out.written();              // valid until the next write (§1)
const owned = try out.toOwnedSlice();     // caller frees
```

- Pass `&out.writer` where a `*std.Io.Writer` is wanted.
- `std.fmt.bufPrint(&buf, fmt, args)` formats into a slice when no
  writer is at hand.
- No type in the tree defines a `format` method; one would be
  `pub fn format(self: T, w: *std.Io.Writer) std.Io.Writer.Error!void`,
  called by `{f}`.

---

## 5. Containers

- `std.ArrayList(T)` is unmanaged: initialize with `.empty` and pass
  the allocator to every call (`list.append(gpa, x)`,
  `list.deinit(gpa)`, `list.toOwnedSlice(gpa)`). `= .{}` does not
  compile.
- `std.array_list.Managed(T)` stores its allocator (`.init(gpa)`,
  `append(x)`); a few tests use it.
- `std.ArrayListUnmanaged` is a deprecated alias of `std.ArrayList`;
  some files still spell it that way. New code writes `std.ArrayList`.
- Hash maps: `std.StringHashMapUnmanaged(V)`,
  `std.AutoHashMapUnmanaged(K, V)` and `std.HashMapUnmanaged(K, V, Ctx,
  load)`, initialized with `.empty` (or `.{}`), take an allocator per
  call; the managed `std.StringHashMap(V).init(gpa)` survives in the
  VM's namespace registry. `std.AutoArrayHashMapUnmanaged` is a
  deprecated alias of `std.array_hash_map.Auto`.
- `std.mem.trimStart` and `trimEnd` (not `trimLeft`, `trimRight`);
  `std.mem.sort(T, items, ctx, lessThan)`.
- `std.heap.ArenaAllocator` holds a compile's Forms and routines;
  `std.heap.stackFallback(N, gpa)` gives small scratch buffers.

---

## 6. Platform calls through `std.c`

The tree calls libc directly where the `Io` interface would add
plumbing and nothing else. libc is implicit on macOS; a Linux build is
unverified.

| Need | Call | Where |
|---|---|---|
| monotonic and wall clocks | `var ts: std.c.timespec = undefined; _ = std.c.clock_gettime(.MONOTONIC, &ts);` (`.REALTIME` for wall time) | `src/bench.zig`, `src/nextomic/store.zig` |
| an environment flag | `std.c.getenv("NEXIS_GC_STRESS") != null` | `src/vm.zig`, `bench/main.zig` |
| unlink a file | `_ = std.c.unlink(path.ptr)` (a sentinel-terminated path) | `bench/main.zig` |

`std.time` holds only constants; there is no `std.time.Timer` or
`timestamp`. `std.posix` lost its mid-level wrappers (`close`,
`fstat`, `unlink`, `write`); the tree uses none of `std.posix`.

---

## 7. Language rules the tree depends on

- **Packed types.** `vm.Operand` is `packed struct(u16)` and
  `vm.Inst` is `packed struct(u64)`: the backing integer is spelled
  out, and a packed type holds no pointers (store a `usize` and use
  `@ptrFromInt`/`@intFromPtr`).
- **Float to integer.** `@intFromFloat` is deprecated (the langref:
  "Equivalent to @trunc"). Write `@trunc`, `@floor`, `@ceil` or
  `@round` with an integer result type: `const i: i64 = @trunc(f);`.
  `@floatFromInt` is unchanged.
- **Integer types at comptime.** `@Int(.unsigned, n)`; `std.meta.Int`
  still compiles but is deprecated.
- **No doc comment on a test.** `///` before `test "..."` is an error;
  use `//`.
- **No address of a local escapes.** `return &local;` is a compile
  error.
- **`@frameAddress()`** gives the current frame's address; the stack
  guard compares it with the armed limit (stacks grow down on every
  target nexis builds for).
- Labeled loops with `continue :label` and `inline else` switch prongs
  appear in the query executor and the stdlib.

---

## 8. Format specifiers

Each output below comes from compiling the line against 0.16.0.

| Spec | Argument | Output |
|---|---|---|
| `{s}` | `"hi"` | `hi` |
| `{d}` | `42`, `-7`, `2.5`, `0.1` | `42`, `-7`, `2.5`, `0.1` |
| `{d:.2}` | `3.14159` | `3.14` |
| `{e}` | `1000.0`, `1234.5`, `1.5e-7`, `0.0` | `1e3`, `1.2345e3`, `1.5e-7`, `0e0` |
| `{d}` | NaN, infinity | `nan`, `inf` |
| `{x}`, `{X}` | `255` | `ff`, `FF` |
| `{x:0>4}` | `10` | `000a` |
| `{b}`, `{o}` | `5`, `8` | `101`, `10` |
| `{c}` | `'A'` | `A` |
| `{t}` | an enum value or an error | its tag name: `green`, `FileNotFound` |
| `{any}` | a struct `{x, y}` | `.{ .x = 10, .y = 20 }` |
| `{any}` | `[]const u8` `"ab"` | `{ 97, 98 }` |
| `{s:10}` | `"hi"` | `        hi` (right-aligned by default) |
| `{s:<6}`, `{s:>6}` | `"hi"` | `hi    `, `    hi` |
| `{d:>5}` | `42` | `   42` |

- `{e}` prints the shortest round-trip mantissa and a bare exponent.
  `src/format.zig` builds Clojure's double spelling (`1.0E10`,
  `1.5E-7`) from it, and uses `{d}` for the plain range, adding `.0`
  where the digits have no fraction.
- `{}` on a struct prints as `{any}` does; `{f}` calls a `format`
  method.

---

## 9. build.zig and build.zig.zon

- `build.zig.zon` needs `.name` as an enum literal (`.nexis`) and a
  `.fingerprint`. emdb is a path dependency,
  `.emdb = .{ .path = "../emdb" }`, so the two checkouts are siblings.
  `.paths` lists what a package of nexis contains.
- The runtime is one module rooted at `src/root.zig`:
  `b.createModule(.{ .root_source_file = b.path("src/root.zig"), ... })`
  plus `addImport("emdb", ...)`. Test binaries are
  `b.addTest(.{ .name = ..., .root_module = ... })`, run through
  `b.addRunArtifact`.
- Build-time file access goes through `b.graph.io` and
  `b.build_root.handle`:
  `b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1 << 20))`.
- `b.addFail(message)` makes a step that fails with a message; the
  layering check (`checkLayering`) uses it.
- `zig fmt --check FILE` before a commit; the generated
  `src/parser.zig` is the one file that does not pass.

---

## 10. Compile-error decoder

Each fragment is what 0.16.0 prints.

| Error fragment | Cause | Fix |
|---|---|---|
| `missing struct field: items` | `var l: std.ArrayList(T) = .{};` | `= .empty` |
| `member function expected 2 argument(s), found 1` on `append` or `deinit` | an unmanaged container called without the allocator | pass `gpa` |
| `type 'Io.Writer' not a function` | `alloc.writer()` on a `Writer.Allocating` | `alloc.writer.print(...)`, `&alloc.writer` |
| `expected type 'Io.Limit', found 'comptime_int'` | a bare size on `readFileAlloc` | `.limited(n)` or `.unlimited` |
| `root source file struct 'fs' has no member named 'cwd'` | `std.fs.cwd()` | `std.Io.Dir.cwd()` and an `io` |
| `no field or member function named 'writeAll' in 'Io.File'` | writing a `File` without `io` | `file.writeStreamingAll(io, bytes)` |
| `expected type 'Io', found ...` | an API that takes `io` called without it | thread `io: std.Io` through |
| `packed structs cannot contain fields of type '*T'` | a pointer in a packed type | store a `usize` |
| `returning address of expired local variable` | `return &x;` | return by value, or allocate |
| `root source file struct 'mem' has no member named 'trimLeft'` | the renamed trims | `trimStart`, `trimEnd` |
| `documentation comments cannot be attached to tests` | `///` before `test` | `//` |
| `error(DebugAllocator): memory address ... leaked` at exit | a leak under `init.gpa` or `std.testing.allocator` | free it; a leaking test fails |
