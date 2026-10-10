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
##Inf, ##-Inf, ##NaN                 ;; real    (the symbolic floats)
"hello"                              ;; string  (escapes decoded, UTF-8)
#"a\d+", #"\""                       ;; regex   (the text between the quotes, no escape processing)
#inst "2026-10-09T12:30+02:00"       ;; inst    (the instant: milliseconds since the epoch, i64)
#uuid "0123abcd-4567-89ef-0123-456789abcdef" ;; uuid (its 16 bytes)
\a, \newline, \u{2603}, \u2603       ;; char    (Unicode scalar)
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
- `regex` holds the text between `#"` and `"` as written: a backslash
  and the character after it are kept, as Clojure's `RegexReader`
  passes them to `Pattern.compile`. The reader compiles it once to
  check it (§3); the compiler lifts it into a pattern constant and
  `quote` and macros see a pattern value (`docs/REGEX.md` §10).
- `inst` and `uuid` hold the value their tag's string names, parsed
  once by the reader: `#inst` in Clojure's grammar (`src/inst.zig`,
  `docs/STDLIB.md` §12), `#uuid` in Java's `UUID.fromString` grammar
  (`src/uuid.zig`). The compiler lifts each into a constant, an
  instant immediate and a UUID block, and `quote` and macros see the
  value; a macro may return either value and it becomes the datum
  again. They are the two tags EDN builds in; no other tag reads
  (§3), and user tags are open (PLAN §24 #3).
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
| `^sym x`, `^"String" x` | `(with-meta x {:tag sym})`, `(with-meta x {:tag "String"})` |
| `^[long] f` | `(with-meta f {:param-tags [long]})`, as Clojure 1.12 reads it |
| `^:a ^:b x` | one `with-meta`, the chain's maps merged; on a duplicate literal key the outer (leftmost) `^` wins, and keys sit in the order of their last occurrence |
| `^42 x` | `:unknown-reader-construct` "metadata must be a keyword, map, symbol, string or vector" |
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
| `+5`, `+0x10`, `+1.5` | the number: a leading `+` is a sign, as in Clojure |
| `1abc`, `1-2`, `1.5x`, `1/2`, `1.`, `0x`, `3.14M`, `1_000`, `1.0_5` | `:bad-number-literal`, detail the token |
| `:1`, `:2a` | a keyword: one may start with a digit, as in Clojure |
| `nexis.core//` | the symbol `/` qualified, as syntax-quote prints it (`clojure.core//` in Clojure) |
| `"one⏎two"` | a string may span lines; the newline is part of it |
| `"\u00e9"`, `"\uD83D\uDE00"` | Clojure's escape: `\u` and exactly four hex digits name a UTF-16 unit, and a high surrogate followed by a `\uXXXX` low one spells one scalar (`"é"`, `"😀"`) |
| `"\n"`, `"\t"`, `"\r"`, `"\b"`, `"\f"`, `"\\"`, `"\""` | newline, tab, return, backspace, formfeed, backslash and quote, the escapes a string may hold besides `\u` and octal |
| `"\0"`, `"\101"`, `"\377"` | Clojure's octal escape: one to three octal digits, at most `\377`, naming U+0000 to U+00FF (`"\101"` is `"A"`) |
| `"\u{2603}"` | the scalar the hex digits name (PLAN §23 #26) |
| `"a\qb"`, `"\400"`, `"\u{D800}"`, `"\u{+41}"`, `"\u41"`, `"\uD800"`, `"\uDE00\uD83D"` | `:invalid-string-escape`, detail the escape |
| `λ`, `ns.é/π`, `:ключ` | a symbol or keyword may hold any non-ASCII UTF-8 character |
| a UTF-8 byte-order mark (U+FEFF) | skipped when it starts the source, as whitespace; anywhere else a symbol constituent, as in Clojure |
| a string, symbol or keyword that is not UTF-8 | `:invalid-utf8` |
| `\é`, `\☃`, `\(` | one character, any UTF-8 sequence or delimiter |
| `\u0041`, `\u{41}` | the char `A`: `\u` and exactly four hex digits, as Clojure spells it, or `\u{HEX}` (PLAN §23 #26) |
| `\u041`, `\u00411`, `\uD800`, `\o101`, `\a1`, `\ab`, `\u{D800}`, `\u{110000}` | `:invalid-char-literal`, detail the token |
| `##Inf`, `##-Inf`, `##NaN` | the reals positive infinity, negative infinity and NaN |
| `foo/bar/baz`, `:foo/bar/baz` | `:invalid-symbol`, `:invalid-keyword`, detail the token |
| `#"a\d"` | the `regex` datum of the text `a\d`: a backslash and the character after it are kept as written, so `#"\""` holds `\"` |
| `#"("`, `#"a{2,1}"`, `#"(?=a)"` | `:invalid-regex`, detail the compiler's sentence and the code-point index in the pattern (`"Unclosed group at index 1"`), the span the literal |
| `#"abc` with no closing quote | parse error at the `#"` |
| `#inst "2026-10-09T12:30:15.123+02:00"`, `#inst "2020"` | the `inst` datum of the instant the string names: a year of four or more digits with an optional sign, then optionally `-MM`, `-DD`, `T` and `HH`, `:mm`, `:ss` and a fraction (its first three digits the milliseconds), each only after the one before; then `Z`, an offset `±HH:mm` or `±HHmm`, or nothing, which is UTC. `T` and `Z` may be lower case; a second may be 60 in minute 59, which rolls into the next minute |
| `#uuid "0123ABCD-4567-89EF-0123-456789ABCDEF"`, `#uuid "1-2-3-4-5"` | the `uuid` datum: five groups of 1–8, 1–4, 1–4, 1–4 and 1–12 hex digits of either case, joined by `-`, at most 36 characters |
| `#inst #_x "1970"` | a discard between the tag and its form is dropped |
| `#inst "2020-13"`, `#inst 5`, `#inst ^:m "2020"` | `:invalid-inst`, detail `not an instant: "2020-13"` or `#inst takes a string`, the span the tag through its form |
| `#uuid "x"`, `#uuid 5` | `:invalid-uuid`, detail `not a UUID: "x"` or `#uuid takes a string` |
| `#foo/bar 1`, `#ns.Rec{:a 1}`, `#js {}` | `:unknown-tag`, detail `#foo/bar; nexis reads the tags #inst and #uuid`, before the tag's form is read |
| `#! text`, `; text` | a comment to the end of the line, anywhere, as in Clojure, so a script may begin `#!/usr/bin/env nexis` |
| `##Infinity`, `#?(...)`, `::k`, `#%x`, `:` | parse error naming the token (`` unexpected `##Infinity` ``): none is in the reader (`CLOJURE-REVIEW.md` §4). `#` and a letter is a tag token, never a parse error |
| a form nested past the native stack's budget | `:nesting-too-deep` (`src/stack.zig`) |
| a source text past 4 GiB (`reader.max_source_len`, 2^32 - 1 bytes) | reader error naming the bound and the size, before a byte is read: positions are `u32` offsets |

`ErrorKind` in `reader.zig` is the complete list. The reader fails fast
on the first error and produces no partial tree.

**Number token boundary.** A token that begins with a digit, or with
`-` or `+` and a digit, ends where a symbol would: at whitespace, a comma,
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
reader accepts the text only when it is one character, `u{HEX}` or `u`
and four hex digits naming a Unicode scalar, or a name of the named
set (§5), so `\a1` and `\u041` fail whole.

**Duplicate detection.** Only literal keys and elements count:
`{:a 1 (keyword "a") 2}` reads, since the second key is a runtime value.
Literal equality compares integers by value, `bigint` by text, strings
byte for byte, keywords and symbols by name, instants by milliseconds
and UUIDs by bytes, so `#{#inst "2020" #inst "2020-01-01T00:00Z"}` is
a duplicate, as Clojure's reader reports one. A `regex` is equal to
nothing, so `#{#"a" #"a"}` reads, as in Clojure, where each literal
is a distinct `Pattern`. `1` and `1.0` differ
(`(= 1 1.0)` is false, PLAN §23 #11), `:a` and `a` differ, and reals
compare with `==` except that NaN equals NaN, as `=` has it, so
`{0.0 x -0.0 y}` and `#{##NaN ##NaN}` are duplicates. Detection
hashes, so it is linear in the literal's size.

**Metadata targets.** The reader wraps any Form in `with-meta`; which
values accept metadata is a runtime rule (`SEMANTICS.md` §7).

---

### 4. Stage ownership

The pipeline and its one-way stage boundaries (PLAN §5, §28.4;
`src/root.zig` and `build.zig` check the import layering):

| Stage | Input → output | Responsibilities |
|---|---|---|
| Parser (`src/parser.zig`, generated from `nexis.grammar`; scanner `src/nexis.zig`) | source → `Sexp` with token spans | Tokenizing and the LALR(1) parse; drops `#_` and its form; a tag and its form as one `tagged` node. No normalization. |
| Reader (`src/reader.zig`) | `Sexp` → `Form` | §3: typed atoms, spans, metadata merge, `anon_fn`, the `syntax-quote` marker, the `regex` datum and its validation, the `inst` and `uuid` datums, every reader error. |
| Macroexpander (`src/expand.zig`) | `Form` → expanded `Form` | Macros to a fixpoint, `syntax-quote`, `anon_fn` → `fn*`, destructuring. A macro receives the call (`&form`), the locals in scope (`&env`) and its arguments (PLAN §23 #34). `MACROEXPAND.md`. |
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
  `(string "S")`, `(regex "S")`, `(char C)`, `(keyword :K)`, `(symbol S)`,
  `(inst "2026-10-09T10:30:15.123-00:00")` (Clojure's `#inst` text of
  the milliseconds), `(uuid "0123abcd-…")` (the canonical text).
- Integers print in decimal whatever the source radix. Reals use Zig's
  `{d}` format (`1e9` prints `1000000000`); NaN and the infinities print
  `+nan`, `+inf`, `-inf`.
- Chars: the named set `\newline \space \tab \return \formfeed
  \backspace`, printable ASCII as itself (`\a`, `\(`), anything else as
  `\u{HEX}` in uppercase hex.
- Strings and regexes escape `\" \\ \n \t \r`; every other byte outside printable
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
  collection literal, reader macro, `#_`, `#()`, metadata shape, `#inst`
  and `#uuid`);
  each `.sexp` sibling is the expected `writeProgram` output.
- Each `test/golden/errors/<name>.nx` pairs with `<name>.err`: one line,
  the error keyword, then ` :detail "..."` when the reader gives one,
  or `:parser-error ParseError` for input the grammar rejects, e.g.
  `:duplicate-literal-key :detail "(keyword :a)"`.
- `src/golden.zig` prints either to stdout for one `.nx`, exiting 0
  for a program that reads and 3 (the CLI's reader-error status) for
  one the reader refuses; the build runs it once per file and checks
  the status as well as the output.

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
- **`#%` names.** The lexer accepts `#` only before `{`, `(`, `_`,
  `'`, `"` and in `##Inf`, `##-Inf`, `##NaN`, so no unqualified symbol a
  program writes begins with `#%` and the printer's `#%anon-fn` head
  cannot collide with one. A qualified name reaches the internal
  natives (`nexis.internal/#%make-record`), as `symbol`, `resolve` and
  `eval` do; the reader is not their guard: every internal native
  validates its arguments (`docs/PROTOCOLS.md` §7).
- **Nested `#()`** is rejected because nesting would make the `%`
  placeholders ambiguous.
