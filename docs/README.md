# nexis docs map

One spec per module. Each doc owns its module's contract and points at
the owner of any fact it only uses. Reading order and authority order
live in [`AGENTS.md`](../AGENTS.md); the frozen decisions and the
canonical Form schema in [`PLAN.md`](../PLAN.md) §23 and §28.

## Module → spec

| Source | Spec | Scope |
|---|---|---|
| `src/root.zig` | `build.zig` `checkLayering` | The one runtime module: every runtime file, declared bottom-up in layering order |
| `src/stack.zig` | [`VM.md`](VM.md) §13.1 | Native stack guard: `check` on every recursion over input depth, `:stack-overflow` |
| `src/value.zig` | [`VALUE.md`](VALUE.md) | 16-byte tagged Value, the Kind table |
| `src/heap.zig` | [`HEAP.md`](HEAP.md) | Heap header, header bits, the Heap allocator |
| `src/dispatch.zig`, `src/hash.zig` | [`SEMANTICS.md`](SEMANTICS.md) §2, §3, §3.3 | Cross-kind `=` and hash; the kind → equality category → hash domain table |
| `src/intern.zig` | [`INTERN.md`](INTERN.md) | Symbol and keyword interning |
| `src/string.zig` | [`STRING.md`](STRING.md) | String heap kind |
| `src/bignum.zig` | [`BIGNUM.md`](BIGNUM.md) | Arbitrary-precision integers |
| `src/coll/list.zig` | [`LIST.md`](LIST.md) | Lists: cons, empty, O(1) vector view |
| `src/coll/vector.zig` | [`VECTOR.md`](VECTOR.md) | Persistent vector: 32-way trie with a tail |
| `src/coll/champ.zig` | [`CHAMP.md`](CHAMP.md) | Persistent map and set |
| `src/coll/transient.zig` | [`TRANSIENT.md`](TRANSIENT.md) | Transients and their language surface |
| `src/coll/typed_vector.zig` | [`TYPED_VECTOR.md`](TYPED_VECTOR.md) | Unboxed i64 / f64 vectors, `nexis.simd` |
| `src/gc.zig` | [`GC.md`](GC.md) | Precise mark-sweep collector; §11.5 the native rooting rule |
| `src/codec.zig` | [`CODEC.md`](CODEC.md) | Durable wire format; §3 which kinds serialize |
| `src/atom.zig` | [`ATOM.md`](ATOM.md) | Atoms and volatiles |
| `src/protocol.zig`, `src/record.zig` | [`PROTOCOLS.md`](PROTOCOLS.md) | Records, protocols, `extend-*` dispatch |
| `src/nexis.zig`, `src/parser.zig`, `src/reader.zig`, `src/golden.zig` | [`FORMS.md`](FORMS.md) | Reader, the Form tree, reader goldens; `src/parser.zig` is generated from `nexis.grammar` |
| `src/expand.zig`, `src/loader.zig` | [`MACROEXPAND.md`](MACROEXPAND.md) | Macroexpander, syntax-quote, host macros; §2b namespaces and the loader |
| `src/compile.zig` | [`COMPILER.md`](COMPILER.md) | Form → Tiny → bytecode, recur and capture lowering |
| `src/vm.zig` | [`VM.md`](VM.md) | Bytecode format, opcodes, frames, try/throw, execution errors |
| `src/stdlib.zig`, `src/stdlib/*.nx`, `src/format.zig` | [`STDLIB.md`](STDLIB.md) | Namespaces and embedded sources, text, `nexis.string`, `nexis.set`, printing, I/O |
| `src/cli.zig`, `src/disasm.zig`, `src/stdlib/{test,pprint,math}.nx` | [`TOOLING.md`](TOOLING.md) | Commands, REPL, error report, disassembler, test runner, pprint, math |
| `src/db.zig` | [`DB.md`](DB.md) | emdb connection, durable refs, the `db/*` surface |
| `src/nextomic/` | [`NEXTOMIC.md`](NEXTOMIC.md) | The database (authoritative): store, transactions, time, query, pull, API, errors |
| `src/bench.zig`, `bench/` | [`BENCH.md`](BENCH.md) | Benchmark method and harness |
| — | [`PERF.md`](PERF.md) | Measured numbers, levers, non-goals |
