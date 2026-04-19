## FORMS.md — Canonical Form Schema for nexis

**Status**: Phase 0 deliverable. Authoritative contract between the `nexis.grammar`
parser output and the `src/reader.zig` normalizer. **This document is strictly
derivative from `PLAN.md` Appendix C (§28) and the frozen decisions in §23.** No
shape or rule in this file invents anything not already committed to in the plan.

When FORMS.md and PLAN.md appear to disagree, PLAN.md wins and this document is
corrected in the same commit. When you think you need a new Form kind, stop —
amend PLAN.md §23 first.

---

### 1. Form shape

A `Form` is a recursive heap-resident wrapper (PLAN §28.1):

```zig
pub const Form = struct {
    datum: Datum,                // see §2
    origin: ?SrcSpan,            // { file_id: u32, pos: u32, len: u16 }
    user_meta: ?*PersistentMap,  // normalized map, never `^:kw` sugar
    ann: ?*Annotation,           // compiler-injected; invisible to user code
};
```

- `datum` is the form's actual content — atom or compound.
- `origin` is derived from the parser's `Sexp.src`. See §6 for span policy.
- `user_meta` is **always a normalized map** (keys are normal Form atoms).
  The reader converts `^:kw` → `{:kw true}` and `^sym` → `{:tag sym}` before
  attaching. Multiple metadata annotations on the same target are merged; on
  duplicate keys, **rightmost wins** (matches Clojure, PLAN §28.5 example 2).
- `ann` is never read or written by user code. `(meta x)` returns `user_meta`
  only. This preserves the discipline that compiler provenance cannot be
  stripped by `with-meta` and similar surface operations.

---

### 2. Canonical datum shapes

Straight from PLAN §28.2. Every Form's `datum` is exactly one of these. Anything
else is a bug.

```
;; Atoms (leaves; Form's datum is an Atom variant)
nil                                  ;; nil
true, false                          ;; bool
42, 0x2A, 0b101                      ;; int  (normalized from any radix)
3.14, 1e9, 1.5e-3                    ;; real (f64)
"hello"                              ;; string
\a, \newline, \u{2603}               ;; char (Unicode scalar)
:foo, :ns/foo                        ;; keyword (interned, no metadata)
foo, ns/foo, set!, ->>               ;; symbol

;; Compounds (Form's datum is a Compound variant with a tag + children)
(list   f1 f2 f3)                    ;; (...)
(vector f1 f2 f3)                    ;; [...]
(map    k1 v1 k2 v2)                 ;; {...}   — flat key/value alternation
(set    f1 f2 f3)                    ;; #{...}

;; Reader macros (user-visible conventional tags)
(quote             f)                ;; 'f
(syntax-quote      f)                ;; `f    — marker only; expanded by macroexpander
(unquote           f)                ;; ~f
(unquote-splicing  f)                ;; ~@f
(deref             f)                ;; @f

;; Metadata — TARGET is first child, META-MAP is second
(with-meta TARGET META-MAP)          ;; ^meta x  →  (with-meta x {:meta true})

;; Internal-only (reader-normalizer output; not user-addressable)
(#%anon-fn BODY)                     ;; #(BODY) — lowered post-parse, pre-macroexpand
```

Notes:

- `(map k1 v1 k2 v2)` is a **flat** alternation. The reader rejects odd arity.
- `#%anon-fn` is a **reserved symbol name** (with the literal `%` characters),
  not a dedicated Datum variant. The macroexpander later rewrites it to
  `(fn* [%1 %2 ...] body)`.
- `syntax-quote` is a **structural marker**. Expansion (auto-qualification,
  auto-gensym `x#`, unquote/splice handling) is the macroexpander's job (PLAN
  §14.2). The reader only tags the form.

---

### 3. Reader-normalization rules (authoritative)

Transformations between the raw `Sexp` parser output and the `Form` tree macros
see. Mirrors PLAN §28.3 exactly.

| Source | Canonical Form |
|---|---|
| `^:kw x` | `(with-meta x {:kw true})` |
| `^{:a 1} x` | `(with-meta x {:a 1})` |
| `^sym x` | `(with-meta x {:tag sym})` |
| `^:a ^:b x` | `(with-meta x {:a true, :b true})` — right-to-left merge; duplicate keys: rightmost wins |
| `#_ x y` | the `x` form is discarded; only `y` appears in output |
| `#(body)` | `(#%anon-fn body)` — `%`/`%1`/`%2`/`%&` left as ordinary symbols; resolved by macroexpander |
| `` `x `` | `(syntax-quote x)` — **no expansion here**; the macroexpander does the Clojure-style rewrite |
| `{:a 1 :a 2}` | **reader error**: `:duplicate-literal-key` |
| `{:a}` | **reader error**: `:map-odd-count` |
| `#{1 1 2}` | **reader error**: `:duplicate-literal-element` |
| `#(#(inc %))` | **reader error**: `:nested-anon-fn` |
| `~x` outside `` `...` `` | **reader error**: `:unquote-outside-syntax-quote` |
| `~@x` outside `` `...` `` | **reader error**: `:unquote-splice-outside-syntax-quote` |

**Duplicate detection rule.** Only *statically-detectable literal* keys or
elements count. `{:a 1 (keyword "a") 2}` is **not** a reader error — the second
key is a runtime value. This matches the PLAN §7.2 wording "duplicate
statically-detectable literal keys".

Comparison for duplicate detection uses the reader's own literal equality:
integers by value, strings byte-for-byte, keywords/symbols by name, nil/true/
false structurally. `1` and `1.0` are **different** keys at the reader (matches
PLAN §23 decision 11: `(= 1 1.0)` is false). `:a` and `a` are different
(keyword vs symbol hash domains per §8.4).

**Metadata-target validation.** The reader allows `with-meta` to wrap any Form
that Appendix C admits; runtime validity is enforced at eval time against the
PLAN §8.5 attachability matrix. The reader does **not** enforce the matrix
because the target may be a symbol whose resolution depends on the namespace.

**Span preservation.** Normalized Forms inherit the source span of the
**outermost source construct that produced them**. `^:kw x` produces a
`with-meta` Form whose span covers both the metadata prefix and `x`. Merged
metadata maps span from the first metadata prefix to the last.

---

### 4. Stage ownership

Mirrors PLAN §28.4. A fresh implementation session **must** respect these
boundaries.

| Stage | Input | Output | Responsibilities |
|---|---|---|---|
| **Parser** (`src/parser.zig`, generated) | source text | raw `Sexp` tree with `.src` spans | Tokenization + LALR(1) parse. No semantic validation beyond grammar. No normalization. |
| **Reader / normalizer** (`src/reader.zig`) | raw `Sexp` | canonical `Form` tree | §3 rules. Attaches spans. Normalizes metadata. Lowers `#(...)`. Emits `(syntax-quote f)` marker. Discards `#_`. Rejects duplicate literal keys / odd map / nested anon-fn / bare unquote. |
| **Macroexpander** (`src/macroexpand.zig`) | canonical `Form` | expanded `Form` | Macros to fixpoint. **Expands `syntax-quote` forms.** Resolves `#%anon-fn` to `(fn* ...)`. Passes `&form` and `&env`. |
| **Resolver** (`src/resolve.zig`) | expanded `Form` | `Resolved` AST | Symbols → slot / upvalue / var / special form. Errors on unbound. |

**Important**: `syntax-quote` expansion happens in the macroexpander, not the
reader. The reader only tags. This keeps the reader stateless wrt namespaces
and lets tooling inspect raw reader output without losing backtick structure.

---

### 5. Pretty-printer (canonical Form serialization)

Used by `test/golden/*.sexp` expected files and by `nexis -s`. The pretty-
printer must be **deterministic, stable, and diff-friendly** — goldens cannot
tolerate whitespace churn.

**Format.**

- Lisp-style parens: `(tag child1 child2 ...)`.
- One child per line when any child is a compound; otherwise inline on a
  single line. (Width-aware wrapping is a future tooling pass — the
  current printer does not measure columns.)
- Children are indented 2 spaces beyond the opening `(`.
- Atom notation:
  - `nil`, `true`, `false` — bare.
  - Integers: decimal, with a leading `-` for negatives. Hex and binary source
    literals are normalized to decimal in the Form's `datum` — the pretty-
    printer does not preserve the source radix.
  - Floats: Zig's default `{d}` formatting, except special values:
    `+inf`, `-inf`, `+nan` (canonical NaN; the Form stores NaN as a single
    canonical bit pattern — see SEMANTICS §3.2).
  - Chars: `\a`, `\newline`, `\space`, `\tab`, `\return`, `\formfeed`,
    `\backspace` for the named set; all others as `\u{HEX}` with uppercase hex
    digits and no leading zeros.
  - Strings: double-quoted with `\n \t \r \\ \" \u{HEX}` escapes — same
    escape language as source (PLAN §23 decision 26).
  - Keywords: `:name` or `:ns/name`.
  - Symbols: `name` or `ns/name`. Auto-gensym markers (`x#`) do **not** appear
    in reader output; they are a macroexpander concern.
- Compound tags: bare identifier (`list`, `vector`, `map`, `set`, `quote`,
  `syntax-quote`, `unquote`, `unquote-splicing`, `deref`, `with-meta`,
  `#%anon-fn`).
- Map children render in **source order**. The reader preserves the input
  order of `(map k1 v1 k2 v2 ...)` as a flat list. A sorted canonical order is
  deferred until a runtime persistent-map is involved.
- Set children render in **source order** for the same reason. Duplicate
  detection already fired at the reader.
- `user_meta`, when present, is emitted as a second line after the target
  form, prefixed with `^meta `, and its map uses the same pretty-printer
  recursively. When `user_meta` is absent, nothing is emitted for it.
- `ann` is **never** emitted — it is invisible to user code and tooling.

**Example.**

Source:

```
^:private (defn foo [x] x)
```

Pretty-printed Form:

```
(with-meta
  (list
    (symbol defn)
    (symbol foo)
    (vector (symbol x))
    (symbol x))
  (map (keyword :private) true))
```

The exact atomic tags in the pretty-printer — `(int N)`, `(real R)`, `(string
S)`, `(char C)`, `(keyword K)`, `(symbol S)`, `(bool B)`, `nil` — make atom
types unambiguous in goldens. Bare source text like `defn` never appears as a
standalone leaf; it is always wrapped in its datum tag. This costs a few bytes
per golden but eliminates a whole class of "is this a symbol or a keyword?"
review questions.

---

### 6. Span policy

Every Form carries an `origin: ?SrcSpan` whose `Some` case records the source
range that produced it. Policy:

- **Atoms** carry the span of the token that produced them.
- **Compounds** carry the span from the opening punctuation (`(`, `[`, `{`,
  `#{`, `'`, `` ` ``, `~`, `~@`, `@`, `^`, `#_`, `#(`) to the matching close.
- **Reader-introduced constructs** (`with-meta`, `syntax-quote`, `quote`,
  `#%anon-fn`) cover the full source extent of their origin sugar.
- `None` appears only for Forms synthesized by macros; Phase 0 never produces
  `None`.

Spans are **not** printed in golden outputs by default. Including them would
churn goldens on unrelated edits. A future `nexis -s --with-spans` flag may
add them explicitly for tooling.

For reader **errors**, spans are formatted as `{:line L :col C :end-line L
:end-col C}` in the error map, where `L`/`C` are 1-based and `end-col` is the
first column *after* the offending region. This minimal form is stable across
editor conventions.

---

### 7. Golden-test contract

- `test/golden/basic.nx` exercises the happy-path reader surface from PLAN
  §7.2. Its sibling `basic.sexp` is the expected pretty-printer output of the
  Form tree, line-for-line.
- `test/golden/reader-literals.nx` exhaustively covers every reader construct
  (numbers in every radix, strings with every escape, chars named and
  hex-escaped, keywords/symbols with and without namespace, all collection
  literals, all reader macros, `#_`, `#(...)`, metadata in every shape).
- `test/golden/errors/*.nx` each pair with `<name>.err` — a single-map EDN-ish
  value of the form `{:kind :K, ...slots...}` where `...slots...` are stable
  diagnostic fields (no raw spans unless the test explicitly exercises span
  reporting). Example: `{:kind :duplicate-literal-key :key :a}`.

A golden diff is a **reader regression**. The test runner supports a
`-Dupdate-golden=true` option that overwrites the expected files; use it only
when intentionally changing the schema, and commit the diff alongside the code
change so reviewers see both.

---

### 8. Phase 0 implementation notes (non-binding)

These are **not** language-level commitments — they document the current
state of the reader and will lift as Phase 1 lands. Readers should treat
them as implementation quirks, not contract.

- **Integer range.** `src/reader.zig` stores ints in `i64`. Literals whose
  magnitude exceeds i64 range are rejected with `:bad-number-literal`; they
  will be promoted to bignum in Phase 1 and this error path will light up
  `:bignum-out-of-phase-0-range` instead (the error kind is reserved today).
- **NaN / ±Inf literal syntax.** The reader does not yet accept a source
  spelling for NaN or infinity (Clojure uses `##NaN` / `##Inf`; we defer
  the exact token to Phase 3 with the rest of the reader-extension surface).
  `SEMANTICS.md` §3.2 pins the runtime semantics; goldens do not exercise
  these until the reader accepts them.
- **String escape re-encoding.** The pretty-printer escapes non-ASCII
  bytes individually rather than re-encoding codepoints, so `"☃"` round-
  trips as `\u{E2}\u{98}\u{83}` in goldens. This is stable and correct for
  byte-level equality, but a Phase 1 tooling pass will tighten to
  codepoint-aware output for readability.
- **`#%anon-fn` reservation.** The lexer rejects a bare `#` followed by
  anything other than `{`, `(`, or `_` as `err`, so user code cannot write
  a symbol whose text begins with `#%`. The reader exploits this to claim
  `#%anon-fn` (and any future `#%*` name) as internal. If the lexer is
  ever broadened to admit `#%` prefixes, the reader must add an explicit
  collision check.
- **Anon-fn placeholder status.** `#(body)` lowers to `(#%anon-fn body)`
  with no transformation of `%`, `%1`, `%2`, `%&` inside the body — those
  remain ordinary symbols at this stage. The macroexpander (Phase 3) is
  the owner of positional-arg scanning and `(fn* [...] body)` synthesis.
  Nested `#(...)` is still rejected by the reader because nesting would
  ambiguate placeholder scoping once the expansion lands.
- **Duplicate-literal detection for numeric keys.** The reader's
  `formLiteralEq` compares `real`s with naive `==`, meaning `{0.0 x -0.0
  y}` is flagged as a duplicate but `{##NaN x ##NaN y}` (once the literal
  syntax arrives) will not be. The runtime's canonical-NaN equality
  decision (SEMANTICS §2.2) will land in Phase 1 together with the
  runtime Value layer; the reader's literal-key logic will be revisited
  then.

### 9. What FORMS.md does not cover (and why)

- **Macroexpansion rules** — lives in PLAN §14 and future `docs/MACROS.md`.
- **Resolver / compiler lowering** — lives in PLAN §11 and future
  `docs/PIPELINE.md`.
- **Serializable kinds** — lives in PLAN §15.10 and `docs/CODEC.md`. Forms
  themselves are **not** serializable values; only the Value-layer outputs of
  quote/compile are.
- **Persistent-map ordering** — Form maps use source order; runtime
  persistent maps are unordered. The two representations are distinct and
  kept so.

If you are about to add a rule to this document, check first whether it
actually belongs in PLAN.md (frozen), SEMANTICS.md (value-layer semantics), or
CODEC.md (serialization). FORMS.md is strictly about the parser-to-reader
boundary.
