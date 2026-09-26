## FORMS.md — the reader's Form tree

The contract between the `nexis.grammar` parser output and the
`src/reader.zig` normalizer: the Form tree macros and the compiler
consume, the normalization rules, the reader errors, the pretty-printer
the goldens pin, and the reader's limits. The frozen schema is `PLAN.md`
Appendix C (§28); where the two disagree, PLAN wins and this document
is corrected in the same commit. A new datum variant is a PLAN §23
amendment first.

---

### 1. Form shape

A `Form` is two fields (PLAN §28.1):

- `datum` — the content, one `Datum` variant (§2).
- `origin` — a `SrcSpan {pos: u32, len: u32}`, byte offset and length
  in the source. It is never absent: the reader derives it from the
  parser's token spans (§6), and a Form the macroexpander builds takes
  the span of the form it expands.

A Form has no metadata field and no compiler annotation. Metadata is a
datum of its own, `with_meta {target, meta}` (§2). The reader's arena
owns every Form and every name and string they hold.

---

### 2. Datums

Every Form's `datum` is exactly one of these (`reader.zig` `Datum`):

```
;; Atoms
nil                                  ;; nil
true, false                          ;; bool
42, 0x2A, 0b101                      ;; int     (any radix, within i64)
18446744073709551616                 ;; bigint  (beyond i64, canonical decimal text)
3.14, 1e9, 1.5e-3                    ;; real    (f64)
"hello"                              ;; string  (escapes decoded, UTF-8)
\a, \newline, \u{2603}               ;; char    (Unicode scalar)
:foo, :ns/foo                        ;; keyword
foo, ns/foo, set!, ->>               ;; symbol

;; Compounds
(f1 f2)   [f1 f2]   {k1 v1 k2 v2}   #{f1 f2}   ;; list, vector, map (flat k/v), set
'f  `f  ~f  ~@f  @f                  ;; quote, syntax_quote, unquote, unquote_splicing, deref
^meta x                              ;; with_meta {target: x, meta: a map Form}
#(body)                              ;; anon_fn  (the body forms)
```

- A map's children alternate key and value.
- `nil`, `true` and `false` lex as symbols and become their own datums.
- `syntax_quote` is a marker. Auto-qualification, auto-gensym `x#` and
  unquote handling belong to the macroexpander (`MACROEXPAND.md` §5).
- `#'x` has no datum of its own: it reads as the list `(var x)` (§3).
- `anon_fn` holds the body forms only; `%`, `%1`, `%&` inside stay
  ordinary symbols. The macroexpander rewrites it to `(fn* [%1 ...]
  (body))` (`MACROEXPAND.md` §9). The pretty-printer renders it with the
  head `#%anon-fn`, a name user code cannot spell (§8).

---

### 3. Normalization rules and reader errors

| Source | Form, or reader error |
|---|---|
| `^:kw x` | `(with-meta x {:kw true})` |
| `^{:a 1} x` | `(with-meta x {:a 1})` |
| `^sym x` | `(with-meta x {:tag sym})` |
| `^:a ^:b x` | one `with-meta`, the chain's maps merged; on a duplicate literal key the outer (leftmost) `^` wins, and keys sit in the order of their last occurrence |
| `^42 x` | `:unknown-reader-construct` "metadata must be a keyword, map, or symbol" |
| `#_ x y` | `x` is dropped by the parser; only `y` remains |
| `'#_ x y`, `^:m #_ x y` | the prefix takes the form after the dropped one: `(quote y)`, `(with-meta y {:m true})` |
| `#_ #_ x y z` | each `#_` drops one form: only `z` remains |
| `#(body)` | `anon_fn` of the body forms |
| `#(#(inc %))` | `:nested-anon-fn` |
| `` `x `` | `(syntax-quote x)`, unexpanded |
| `#'x`, `#'ns/x`, `#' x` | the list `(var x)`, as Clojure's reader makes it: quoting it yields the list, and a printed Var (`#'ns/name`) reads back as `(var ns/name)` |
| `#'(f)`, `#'42` | `(var (f))`, `(var 42)`: `#'` reads any form, as in Clojure; the compiler rejects a `var` whose operand is not a symbol |
| `#'` with no form after it | parse error |
| `~x`, `~@x` outside `` `...` `` | `:unquote-outside-syntax-quote`, `:unquote-splice-outside-syntax-quote` |
| `{:a 1 :a 2}` | `:duplicate-literal-key`, detail the key |
| `#{1 1 2}` | `:duplicate-literal-element`, detail the element |
| `{:a}` | `:map-odd-count` |
| `42N`, `0xFFN`, `18446744073709551616N` | the integer, as without the suffix |
| `1abc`, `1-2`, `1.5x`, `1/2`, `1.`, `0x`, `3.14M` | `:bad-number-literal`, detail the token |
| `"one⏎two"` | a string may span lines; the newline is part of it |
| `"a\qb"`, `"\u{D800}"`, `"\u0041"` | `:invalid-string-escape`, detail the escape |
| `λ`, `ns.é/π`, `:ключ` | a symbol or keyword may hold any non-ASCII UTF-8 character |
| a UTF-8 byte-order mark (U+FEFF) | skipped when it starts the source, as whitespace; anywhere else a symbol constituent, as in Clojure |
| a string, symbol or keyword that is not UTF-8 | `:invalid-utf8` |
| `\é`, `\☃`, `\(` | one character, any UTF-8 sequence or delimiter |
| `\u0041`, `\o101`, `\a1`, `\ab`, `\u{D800}`, `\u{110000}` | `:invalid-char-literal`, detail the token (`\u{HEX}` is the one escape, PLAN §23 #26) |
| `foo/bar/baz`, `:foo/bar/baz` | `:invalid-symbol`, `:invalid-keyword`, detail the token |
| `#"re"`, `##Inf`, `#?(...)`, `#!`, `::k`, `#%x`, `:` | parse error naming the token (`` unexpected `##Inf` ``): none is in the reader (`CLOJURE-REVIEW.md` §4) |
| a form nested past the native stack's budget | `:nesting-too-deep` (`src/stack.zig`) |
| a source text past 4 GiB (`reader.max_source_len`, 2^32 - 1 bytes) | reader error naming the bound and the size, before a byte is read: positions are `u32` offsets |

`ErrorKind` in `reader.zig` is the complete list. The reader fails fast
on the first error and produces no partial tree.

**Number token boundary.** A token that begins with a digit, or with
`-` and a digit, ends where a symbol would: at whitespace, a comma,
a delimiter (`( ) [ ] { }`), `"`, `;`, a reader macro character
(`' ` ~ @ ^ \`) or the end of input. The lexer never splits `1abc`
into `1` and `abc` or `1-2` into `1` and `-2`; the reader reads the
whole run as a number when it is one of the §2 spellings (with an
optional `N` on an integer) and fails with `:bad-number-literal`
otherwise, its span the whole token. The differences from Clojure
(`1.` and `22/7` are errors, `017` is decimal 17, `3.14M` is an error)
are in `CLOJURE-REVIEW.md` §4.2.

**Char token boundary.** A char token is `\`, one character (a whole
UTF-8 sequence, or any other byte, a delimiter included), then every
symbol constituent that follows; `\u{HEX}` runs to its `}` first. The
reader accepts the text only when it is one character, `u{HEX}` naming
a Unicode scalar, or a name of the named set (§5), so `\a1` and
`\u0041` fail whole.

**Duplicate detection.** Only literal keys and elements count:
`{:a 1 (keyword "a") 2}` reads, since the second key is a runtime value.
Literal equality compares integers by value, `bigint` by text, strings
byte for byte, keywords and symbols by name. `1` and `1.0` differ
(`(= 1 1.0)` is false, PLAN §23 #11), `:a` and `a` differ, and reals
compare with `==`, so `{0.0 x -0.0 y}` is a duplicate. Detection
hashes, so it is linear in the literal's size.

**Metadata targets.** The reader wraps any Form in `with-meta`; which
values accept metadata is a runtime rule (`SEMANTICS.md` §7).

---

### 4. Stage ownership

The pipeline and its one-way stage boundaries (PLAN §5, §28.4;
`src/root.zig` and `build.zig` check the import layering):

| Stage | Input → output | Responsibilities |
|---|---|---|
| Parser (`src/parser.zig`, generated from `nexis.grammar`; scanner `src/nexis.zig`) | source → `Sexp` with token spans | Tokenizing and the LALR(1) parse; drops `#_` and its form. No normalization. |
| Reader (`src/reader.zig`) | `Sexp` → `Form` | §3: typed atoms, spans, metadata merge, `anon_fn`, the `syntax-quote` marker, every reader error. |
| Macroexpander (`src/expand.zig`) | `Form` → expanded `Form` | Macros to a fixpoint, `syntax-quote`, `anon_fn` → `fn*`, destructuring. A macro receives its arguments only; there is no `&form` or `&env` (PLAN §23 #34). `MACROEXPAND.md`. |
| Compiler (`src/compile.zig`) | expanded `Form` → Tiny tree → bytecode | Resolves each symbol to a slot, capture, Var or special form in `lowerForm`; there is no separate resolver. `COMPILER.md`. |

Syntax-quote expansion lives in the macroexpander so the reader holds no
namespace state and tooling sees the backtick structure.

---

### 5. Pretty-printer

`reader.writeForm` and `writeProgram` render a Form tree for the
`test/golden/*.sexp` files (`src/golden.zig`). The output is
deterministic:

- `(tag child ...)`. A compound whose children are all atoms prints on
  one line; otherwise each child goes on its own line, indented two
  spaces past the parent. There is no width-aware wrapping.
- Atoms carry their datum tag, so a symbol and a keyword are never
  confused: `nil`, `(bool true)`, `(int N)`, `(bigint N)`, `(real R)`,
  `(string "S")`, `(char C)`, `(keyword :K)`, `(symbol S)`.
- Integers print in decimal whatever the source radix. Reals use Zig's
  `{d}` format (`1e9` prints `1000000000`); NaN and the infinities print
  `+nan`, `+inf`, `-inf`.
- Chars: the named set `\newline \space \tab \return \formfeed
  \backspace`, printable ASCII as itself (`\a`, `\(`), anything else as
  `\u{HEX}` in uppercase hex.
- Strings escape `\" \\ \n \t \r`; every other byte outside printable
  ASCII prints as `\u{HEX}` of that byte, so `"☃"` prints
  `\u{E2}\u{98}\u{83}`. The output is stable; it is not source that
  reads back as the same string.
- Compound tags: `list vector map set quote syntax-quote unquote
  unquote-splicing deref with-meta #%anon-fn`. Map and set children
  print in source order. Metadata prints as the `with-meta` compound.

Source `^:private (defn foo [x] x)` prints:

```
(with-meta
  (list
    (symbol defn)
    (symbol foo)
    (vector (symbol x))
    (symbol x))
  (map (keyword :private) (bool true)))
```

---

### 6. Span policy

- An atom's span is its token's.
- A compound's span runs from its opening punctuation (`(`, `[`, `{`,
  `#{`, `'`, `` ` ``, `~`, `~@`, `@`, `^`, `#(`, `#'`) to its closing
  delimiter, or to the end of its target for a prefix form. In the `(var x)`
  that `#'x` reads as, the `var` symbol spans the `#'`.
- A `with-meta` Form covers the first `^` through the target; the merged
  metadata map carries that same span.
- A reader error carries the span of the token or form it rejects. The
  CLI reports it as `path:line:col: reader error: :kind detail` with a
  caret under the span (`TOOLING.md` §1); `read-string` throws
  `:reader-error`.

The `.sexp` goldens omit spans. The CLI goldens in `test/golden/cli/`
pin them where they show: error carets and `nexis disasm` annotations.

---

### 7. Golden tests

- `test/golden/basic.nx` and `reader-literals.nx` cover the reader
  surface (every radix, escape, named and hex char, qualified name,
  collection literal, reader macro, `#_`, `#()` and metadata shape);
  each `.sexp` sibling is the expected `writeProgram` output.
- Each `test/golden/errors/<name>.nx` pairs with `<name>.err`: one line,
  the error keyword, then ` :detail "..."` when the reader gives one,
  or `:parser-error ParseError` for input the grammar rejects, e.g.
  `:duplicate-literal-key :detail "(keyword :a)"`.

A golden diff is a reader regression. `zig build golden -Dupdate=true`
rewrites the expected files; use it only for an intended change and
commit the diff with the code.

---

### 8. Reader limits

These describe the reader as it is; they are not language commitments.

- **Integers.** An `int` is an i64; a literal beyond it, in any radix,
  is a `bigint` of canonical decimal text. The compiler lifts an `int`
  outside the i48 fixnum range, and every `bigint`, into a bignum
  constant (`COMPILER.md` §4.3).
- **No NaN or infinity literals.** There is no source spelling
  (Clojure's `##NaN`, `##Inf`); `SEMANTICS.md` §2.2 gives the runtime
  rules.
- **`#%` names are unreachable.** The lexer accepts `#` only before
  `{`, `(` and `_`, so no user symbol begins with `#%` and the
  printer's `#%anon-fn` head cannot collide with one.
- **Nested `#()`** is rejected because nesting would make the `%`
  placeholders ambiguous.
