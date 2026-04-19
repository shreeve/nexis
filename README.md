# nexis

> A Lisp where immutable values, transactional durable identity, and
> historical snapshots are one coherent programming model.

**nexis** is a modern, Zig-native Lisp inspired by Clojure. It takes Clojure's
best ideas — persistent immutable collections, macros, keywords, data-first
APIs, identity/value separation — and replants them on a vertically integrated
substrate: a grammar-driven parser (`nexus`), an mmap'd MVCC B+ tree storage
engine (`emdb`), and a production 64-bit bytecode VM lineage (`em`). Durable
identities are first-class values, not a library bolted on top.

## Status

**Phase 0 — foundations.** The grammar, `@lang` module, reader / Form
normalizer, pretty-printer, and golden-test infrastructure are landed. No
runtime, no compiler, no collections yet — see [`PLAN.md`](PLAN.md) §21 for
the phase map.

```
zig build parser      # regenerate src/parser.zig from nexis.grammar
zig build test        # reader unit tests + golden verification
zig build golden      # reader golden tests alone
```

## What's here

| Path | What it is |
|---|---|
| [`PLAN.md`](PLAN.md) | Authoritative design — read this first |
| [`CLOJURE-REVIEW.md`](CLOJURE-REVIEW.md) | What we take, adapt, reject from Clojure |
| [`docs/FORMS.md`](docs/FORMS.md) | Canonical Form schema + pretty-printer spec |
| [`docs/SEMANTICS.md`](docs/SEMANTICS.md) | Equality, hash, numeric edge cases (frozen) |
| [`docs/CODEC.md`](docs/CODEC.md) | Serialization scope (stub; locked in Phase 4) |
| [`nexis.grammar`](nexis.grammar) | Reader grammar — source of truth |
| [`src/nexis.zig`](src/nexis.zig) | `@lang` module — Tag enum + Lexer wrapper |
| [`src/reader.zig`](src/reader.zig) | Sexp → Form normalizer + pretty-printer |
| [`src/golden.zig`](src/golden.zig) | Golden-file test runner |
| [`AGENTS.md`](AGENTS.md) | Routing guide for contributors / AI sessions |

## Phase 0 implementation limits

These lift in Phase 1; called out here so no one mistakes them for language
semantics.

- Integers are stored in `i64`; out-of-range literals error as
  `:bad-number-literal`. Bignum promotion lands in Phase 1.
- The reader does not yet accept a source syntax for NaN / ±Inf; those
  are reader extensions scheduled for Phase 3.
- The Form pretty-printer escapes non-ASCII bytes individually (so `"☃"`
  round-trips as `\u{E2}\u{98}\u{83}` in goldens). Stable, not canonical —
  a Phase 1 tooling pass tightens to codepoint-level output.
- `#(...)` lowers to `(#%anon-fn body)`; positional-arg placeholders (`%`,
  `%1`, `%&`) are ordinary symbols at this stage. The macroexpander
  (Phase 3) is the owner of placeholder rewriting and `fn*` synthesis.
- `src/parser.zig` is **committed, generated**. Run `zig build parser`
  whenever you edit `nexis.grammar`.

See [`docs/FORMS.md`](docs/FORMS.md) §8 for the longer list with rationale.

## Requirements

- **Zig 0.16.0** (pinned; stdlib changed substantially between 0.15 and 0.16).
  See [`ZIG-0.16.0-REFERENCE.md`](ZIG-0.16.0-REFERENCE.md) before writing Zig.
- **nexus** at `../nexus/bin/nexus` for `zig build parser`.

## License

TBD (v1 ships under a permissive license).
