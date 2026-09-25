## STDLIB.md — the standard library: namespaces, text, sets, printing and I/O

The contract for the parts of the standard library that no kind doc
owns: the namespaces and how they boot, the core text natives,
`nexis.string`, `nexis.set`, printing (`src/format.zig`) and the I/O
natives. The natives are in `src/stdlib.zig`, one table per
namespace; the rest of the library is nexis in `src/stdlib/*.nx`.
Errors are catchable keywords; a wrong argument count is
`:arity-mismatch` for every native (the VM checks the declared
arity).

---

### 1. Namespaces and the embedded `.nx` sources

**Boot.** `stdlib.boot(loader)` builds the library into the loader's
registry; the CLI (`cli.zig` `Runtime.init`) and the test harness
(`test/harness.zig`) both boot through it. In order:

1. `installCore`: `core_natives` into `nexis.core`, `simd_natives`
   into `nexis.simd`.
2. `db_natives` into `db`, `string_natives` into `nexis.string`,
   `math_natives` into `nexis.math`, `internal_natives` into
   `nexis.internal`, and `src/nextomic/natives.zig` into `nextomic`.
3. The embedded sources, each evaluated with its namespace current:
   `core.nx`, `nextomic.nx`, `test.nx`, `pprint.nx`, `math.nx`,
   `string.nx`, `set.nx`.
4. Every namespace in the registry is marked loaded, so a `require`
   of one only makes the alias.

A failure in step 3 is a bug in an embedded file and panics with the
loader's diagnostic.

| Namespace | Natives (`src/stdlib.zig`) | nexis source | Contract |
|---|---|---|---|
| `nexis.core` | `core_natives` | `core.nx` | text §2, printing §5, I/O §6; `=` and `hash` SEMANTICS.md; atoms ATOM.md; transients TRANSIENT.md; typed vectors TYPED_VECTOR.md §7.1; records and protocols PROTOCOLS.md; the macros MACROEXPAND.md §2b |
| `db` | `db_natives` | (`with-tx`, `with-read-tx`, `with-snapshot` in `core.nx`) | DB.md §12 |
| `nextomic` | `src/nextomic/natives.zig` | `nextomic.nx` (`with-conn`) | NEXTOMIC.md |
| `nexis.string` | `string_natives` | `string.nx` | §3 |
| `nexis.set` | — | `set.nx` | §4 |
| `nexis.math` | `math_natives` | `math.nx` (`PI`, `E`) | TOOLING.md §4 |
| `nexis.test` | — | `test.nx` | TOOLING.md §3 |
| `nexis.pprint` | — | `pprint.nx` | TOOLING.md §4 |
| `nexis.simd` | `simd_natives` | — | TYPED_VECTOR.md §7.2 |
| `nexis.internal` | `internal_natives` | — | the `#%` helpers macros emit: records and protocols (PROTOCOLS.md §7), `#%catch-matches?` (`try`), `#%kwargs` (`& {:keys ...}`), `#%current-ns` (TOOLING.md §3), `#%push-out` / `#%pop-out` (`with-out-str`, §6) |

**Resolution.** Every other namespace has `nexis.core` as its parent,
so an unqualified symbol a namespace does not define resolves in
`nexis.core`. The other namespaces are reached qualified with no
`require` (`(nexis.string/join "," xs)`), or through an alias
(`(require '[nexis.string :as s])`); a bare `join` is
`UnresolvedSymbol`. `volatile!`, `volatile?`, `vreset!` and `vswap!`
are defined in `core.nx` as the atom operations: one isolate, one
thread.

**Clojure's names.** The loader (`clojure_names` in
`src/loader.zig`) accepts four Clojure library namespaces:
`clojure.string` → `nexis.string`, `clojure.set` → `nexis.set`,
`clojure.test` → `nexis.test`, `clojure.pprint` → `nexis.pprint`.
Requiring one creates a namespace of that name holding the nexis
namespace's Vars (the same Var objects), so `(require
'[clojure.string :as str])` and, after it, `clojure.string/join`
both reach `nexis.string/join`. Before a `require` a
`clojure.string/...` symbol does not resolve. No other `clojure.*`
namespace exists; `(:refer-clojure :exclude [...])` in `ns` makes
the names the namespace's own (`MACROEXPAND.md` §2b).

**Rules for the embedded sources.**

- A file may use the natives and the files before it in the boot
  order.
- A definition that needs bytes, bits, the clock or a callback loop
  that must stop early is a native; the rest is nexis.
- No embedded file holds a keyword literal; each builds the keywords
  it needs when it runs (`(keyword "doc")`). A keyword is an
  immediate whose hash is its intern id (`Value.hashImmediate`), and
  ids are handed out in the order keywords are first interned. A
  literal in an embedded file is interned at boot, ahead of the
  program's keywords, and shifts the id, and so the hash, of every
  keyword a program interns. A map or set past the eight-entry array form
  (CHAMP.md §2.1) iterates, and prints, in hash order, so its printed
  order would change, and with it the pinned outputs under
  `test/nextomic/*.out` and `test/examples/*.out`. The rule stands
  while keyword hashing follows intern order.

---

### 2. Core text and string natives

All in `nexis.core`. Strings index by Unicode scalar (code point),
never by byte or grapheme: `count`, `nth`, `get`, `subs` and
`nexis.string/index-of` agree (`(count "🇺🇸")` is 2). A string with
malformed UTF-8 (reachable only through the codec or a store) makes
any of them throw `:utf8-error` (STRING.md §2, invariant 4).

| Name | Arity | Semantics | Errors |
|---|---|---|---|
| `str` | 0+ | The arguments' text, concatenated: nil is empty, a string or char is itself, anything else as `pr-str` prints it, so strings inside a collection keep their quotes: `(str "a" \b 1 nil :k)` is `"ab1:k"`, `(str ["a" nil])` is `"[\"a\" nil]"`; `(str)` is `""` | `:utf8-error` (a malformed string inside a collection) |
| `string?` | 1 | Whether the argument is a string | — |
| `subs` | 2–3 | `(subs s start)`, `(subs s start end)`: a fresh string of the code points in `[start, end)`, `end` defaulting to the count; `(subs "héllo" 1 3)` is `"él"` | `:kind-mismatch` (non-string, non-fixnum index), `:index-out-of-bounds` (negative, past the count, or `start > end`) |
| `count` | 1 | Of a string: its code points, an O(n) scan | — |
| `nth` | 2–3 | Of a string: the char at a code-point index; out of range (negative included) is the default, or `:index-out-of-bounds` without one | `:kind-mismatch` (non-fixnum index) |
| `get` | 2–3 | Of a string: the char at a fixnum index, else the default (nil); `contains?` answers whether the index is in range | — |
| `seq` and the sequence library | — | A string is a seq of its chars (`(seq "hé")` is `(\h \u{E9})`, `(seq "")` nil), so `first`, `map`, `into`, `reverse`, `frequencies` and the rest take one. `(empty "abc")` is nil. A string is not callable (`:not-callable`) | — |
| `char` | 1 | The char with a code point; a char is itself | `:kind-mismatch` (non-integer), `:invalid-argument` (not a Unicode scalar: negative, past `0x10FFFF`, a surrogate) |
| `char?` | 1 | Whether the argument is a char | — |
| `int`, `long` | 1 | Of a char: its code point (`(int \é)` is 233); of a number, its integer part (SEMANTICS.md §2.2). `long` takes any size (`(long 1e30)` is a bignum); `int` only Java's 32-bit `int` range, as Clojure's cast checks | `:kind-mismatch`, `:invalid-argument` (NaN, an infinity; for `int`, out of range) |
| `name` | 1 | The name part of a keyword or symbol; a string is itself | `:kind-mismatch` |
| `namespace` | 1 | The namespace part of a keyword or symbol, nil when unqualified | `:kind-mismatch` (a string included) |
| `keyword` | 1–2 | `(keyword x)`: interned from a string, symbol or keyword (`"a/b"` makes the qualified `:a/b`); nil is nil. `(keyword ns name)`: qualified, a nil `ns` leaving it unqualified. The name is not checked against the reader's grammar: `(keyword "a b")` prints `:a b` | `:kind-mismatch`, `:invalid-argument` (empty name) |
| `symbol` | 1–2 | As `keyword`, making a symbol; `(symbol nil)` is `:kind-mismatch` | `:kind-mismatch`, `:invalid-argument` (empty name) |
| `parse-long` | 1 | The integer a whole string spells as Java's `Long/valueOf` reads it: ASCII decimal digits after one optional `+` or `-`, within the 64-bit range (a fixnum or bignum); anything else nil (`" 42"`, `"4.2"`, `"1_000"`, `"0x10"`, `"99999999999999999999"`) | `:kind-mismatch` (non-string) |
| `parse-double` | 1 | The float a string spells in the grammar Clojure's `parse-double` admits (Java's `Double/valueOf`): control or space bytes around an optional sign and `NaN`, `Infinity`, a decimal with an optional exponent (`"1e3"`, `".5"`, `"5."`) or a hex significand with its binary exponent (`"0x1p3"`), the last two with an optional `f`, `F`, `d` or `D` suffix; anything else nil (`"inf"`, `"nan"`, `"1_000"`, `"0x10"`) | `:kind-mismatch` |
| `parse-boolean` | 1 | `"true"` and `"false"` to booleans, any other string nil (`core.nx`) | `:kind-mismatch` |
| `format` | 1+ | Below | Below |
| `read-string` | 1 | The first form of the string as data (the reader of `docs/FORMS.md`); text after it is ignored | `:kind-mismatch`, `:reader-error` (no form, or text that does not read) |
| `compare` | 2 | Of two strings: byte order of their UTF-8, which is code-point order; `sort` uses it | — |

**`format`.** `(format fmt & args)` is a subset of Java's
`Formatter`, as Clojure's `format` uses it. `fmt` is text with
conversions `%[flags][width][.precision]conv`, each consuming the next
argument:

| Conversion | Argument | Text |
|---|---|---|
| `%s` | any | As `str` makes it, except nil is `nil` (Java prints `null`); a precision keeps that many characters: `(format "%.2s" "héllo")` is `"hé"` |
| `%d` | integer (fixnum or bignum) | Decimal |
| `%f` | any number | Fixed-point with `precision` decimals, 6 by default: `(format "%.2f" 3.14159)` is `"3.14"`. As Java's, the digits are the double's shortest round-trip ones, rounded half up and padded with zeros (`(format "%.2f" 0.125)` is `"0.13"`, `(format "%.20f" 0.1)` `"0.10000000000000000000"`); NaN and the infinities are `NaN`, `Infinity`, `-Infinity` |
| `%x`, `%X` | integer within 64 bits | Hex of the 64-bit two's complement: `(format "%x" -1)` is `"ffffffffffffffff"`; a larger bignum is `:arithmetic-overflow` |
| `%c` | char | The char (a number is `:kind-mismatch`) |
| `%n` | none | `"\n"` |
| `%%` | none | `"%"` |

The flags are `-` (pad on the right) and `0` (pad with zeros after
any sign, for `%d`, `%f`, `%x`, `%X` only). `width` pads on the left
with spaces to that many characters (code points: `(format "[%3s]"
"é")` is `"[  é]"`). A width or precision above 1048576, a precision
on a conversion other than `%s` and `%f` (as Java refuses `%.2d`), a
missing argument, an unknown conversion or flag (`%e`, `%b`, `%+d`,
`%1$s`) and a trailing `%` are `:invalid-argument`; an argument of
the wrong kind is `:kind-mismatch`, as is a non-string `fmt`;
surplus arguments are ignored. `printf` (§6) prints the result.

---

### 3. `nexis.string`

The natives are in `string_natives`; `capitalize`, `reverse` and
`split-lines` are in `src/stdlib/string.nx`. Every function takes
strings, not chars or nil, except where the table says so; any
other kind is `:kind-mismatch`. There are no regular expressions:
`split` and `replace` take a literal string (`replace` also a char).
Searches compare bytes,
which on valid UTF-8 match only at code-point boundaries.

| Name | Arity | Semantics |
|---|---|---|
| `lower-case`, `upper-case` | 1 | ASCII letters mapped; every other byte, every byte of a multibyte scalar included, unchanged: `(upper-case "héllo")` is `"HéLLO"` |
| `capitalize` | 1 | The first character upper-case and the rest lower-case, by the same ASCII rule |
| `reverse` | 1 | The code points in reverse order (not grapheme clusters) |
| `trim`, `triml`, `trimr` | 1 | Without whitespace at both ends, the start, the end. Whitespace is Java's `Character/isWhitespace`, as Clojure's: tab through CR, FS through US, space, and the Unicode space, line and paragraph separators except the no-break ones (U+2003 and U+3000 are trimmed, U+00A0 stays) |
| `trim-newline` | 1 | Without every `\n` and `\r` at the end |
| `blank?` | 1 | Whether the argument is nil, empty, or only whitespace as `trim` reads it |
| `starts-with?`, `ends-with?`, `includes?` | 2 | Whether the second string is a prefix, suffix, substring of the first |
| `index-of` | 2–3 | `(index-of s x)`, `(index-of s x from)`: the code-point index of the first occurrence of `x` (a string or a char) at or after `from`, nil when there is none; `from` is clamped to `[0, (count s)]`; `(index-of "héllo" "l")` is 2 |
| `last-index-of` | 2–3 | The code-point index of the last occurrence starting at or before `from` (default the count; clamped to it, and nil when negative, as Java's `lastIndexOf`), nil when there is none; the empty string is found at `from` |
| `split` | 2–3 | `(split s sep)`, `(split s sep limit)`: a vector of the pieces between occurrences of `sep`, as Clojure's `split` with a pattern that matches only `sep`. With no limit (or 0) trailing empty pieces are dropped (`(split "a,b,," ",")` is `["a" "b"]`, `(split ",," ",")` is `[]`, `(split "" ",")` is `[""]`); a positive limit splits at most `limit − 1` times and keeps the rest whole; a negative one keeps every trailing empty piece. An empty `sep` splits between code points, as Clojure's `#""` does (`(split "abc" "")` is `["a" "b" "c"]`) |
| `split-lines` | 1 | The lines of `s`, split at `\n` or `\r\n`, trailing empty lines dropped |
| `join` | 1–2 | `(join coll)`, `(join sep coll)`: the elements of any seqable, each as `str` makes it (nil empty), separated by `sep`: `(join ", " ["a" nil 1])` is `"a, , 1"`; a map joins its entries (`"[:a 1]"`), a string its chars; nil is `""`. A set joins in its iteration order |
| `replace` | 3 | `(replace s match replacement)`: every non-overlapping occurrence of `match`, left to right, replaced; the scan resumes after each match, so `(replace "aaa" "aa" "x")` is `"xa"`. `match` and `replacement` are both strings or both chars (`(replace "a.b" \. \/)`); an empty `match` is found before every code point and at the end (`(replace "ab" "" "-")` is `"-a-b-"`), as Java's `String.replace`. The replacement is literal (`$1` is two characters) |

Errors beyond `:kind-mismatch`: `split` and `replace` validate every
string argument as UTF-8 before scanning and throw `:utf8-error` on a
malformed one, so a separator can never cut a scalar in two; the
code-point functions throw `:utf8-error` as §2 says.

Absent from Clojure's `clojure.string`: `replace-first`, `escape`,
`re-quote-replacement`, and every pattern argument. Full Unicode case
mapping, normalization and grapheme segmentation are absent
(STRING.md §6).

---

### 4. `nexis.set`

Clojure's `clojure.set`, written in `src/stdlib/set.nx` over the
core collection functions.

| Name | Arity | Semantics |
|---|---|---|
| `union` | 0+ | A set of every element of any argument; `(union)` is `#{}`; nil and any seqable are accepted (each is poured `into` the result) |
| `intersection` | 1+ | The elements of the first set present in every other one; with one argument, that argument unchanged |
| `difference` | 1+ | The first set without the elements of the others; the first must be a set (`disj`), else `:kind-mismatch` |
| `subset?`, `superset?` | 2 | Whether every element of the first is in the second (`subset?`), or the reverse |
| `select` | 2 | `(select pred s)`: a set of the elements for which `pred` is truthy |
| `map-invert` | 1 | The map with keys and values swapped; of duplicate values, the key iterated last wins |
| `rename-keys` | 2 | `(rename-keys m kmap)`: `m` with each key of `kmap` present in `m` renamed to its value |

`index`, `project`, `join` and `rename` (the relational functions)
are absent.

---

### 5. Printing (`src/format.zig`)

`format.format(v, mode, writer, interner)` is the one printer: the
print natives, `str`, `format`'s `%s`, `nexis.string/join`, `spit`,
the REPL and `-e`, and the error reports all go through it.
SEMANTICS.md §6 owns which kinds read back and the number, char and
string spellings; this section owns the printer.

**Modes.** `.display` writes a string's bytes and a char's UTF-8 as
they are; `.readable` quotes and escapes them. Collections print
their elements in the same mode. Who uses which:

| Caller | Mode |
|---|---|
| `print`, `println`, `print-str`, `println-str` | display |
| `pr`, `prn`, `pr-str`, `prn-str`; the REPL and `nexis -e` results; error-report payloads | readable |
| `str`, `%s`, `join`, `spit` | nil is empty (`%s` writes `nil`); a string or char display; any other value readable, so `(str ["a"])` is `"[\"a\"]"` |

**By kind** (both modes unless the row says otherwise):

| Kind | Printed |
|---|---|
| nil, booleans | `nil`, `true`, `false` |
| fixnum, bignum | Decimal, no suffix |
| float | SEMANTICS.md §6.3: `1.0`, `-0.0`, `1.0E10`, `1.0E-4`, `NaN`, `Infinity`, `-Infinity` |
| char | display: its UTF-8. readable: `\space`, `\newline`, `\tab`, `\return`, `\formfeed`, `\backspace`, `\\`, printable ASCII as `\x`, anything else `\u{HEX}` (`\u{E9}`) |
| string | display: its bytes. readable: double-quoted, `\" \\ \n \t \r` escaped, other ASCII controls and DEL as `\u{HEX}`, every other byte as itself (`"é"`) |
| keyword, symbol | `:ns/name`, `ns/name`; names are not escaped |
| list, vector, set | `(a b)`, `[a b]`, `#{a b}`, elements separated by one space |
| map | `{k v, k v}`, entries separated by `, ` |
| record | `#ns.Type{:k v, ...}` (the fields in the record's mode), or `#<record type-id=N>` when the interner has no name for the type; `(reduced x)` is the record `#nexis.core.Reduced{:val x}` |
| typed vector | `#i64[1 2]`, `#f64[1.5]` |
| function, native fn | `#<fn>`, `#<native-fn NAME>` (`NAME` is `ns/name` outside `nexis.core`: `#<native-fn nexis.string/join>`) |
| var | `#'name`, the Var's unqualified name (`#'inc`, `#'join`) |
| atom, transient | `#<atom>`, `#<transient>` |
| protocol, protocol fn | `#<protocol id=N>`, `#<protocol-fn proto=N method=M>` |
| durable ref | `#<durable-ref :tree hex:KEY>`, the key bytes in upper-case hex |
| db connection, transactions | `#<db-connection>`, `#<db-write-txn>`, `#<db-read-txn>` |
| Nextomic handles | `#nextomic/conn "path"`, `#nextomic/db {:basis-t N :mode :current}` (`:as-of N` / `:since N` when set), `#nextomic/entity {:db/id N}` |

A map or set of up to eight entries prints in insertion order, a
larger one in hash order (CHAMP.md §2). None of the `#<...>`,
`#'`, `#ns.Type{...}`, `#i64[...]` or `#nextomic/...` forms reads
back; the codec (CODEC.md) is the serialization layer.

**Limits.** There is no length or depth option (`*print-length*` is
absent). The printer recurses on the native stack; a collection
nested past the stack guard prints `#<too deep>` there and the VM
raises `:stack-overflow` (SEMANTICS.md §2.7).

**Malformed UTF-8.** Display mode writes the bytes unchanged;
readable mode refuses them with `:utf8-error` rather than emit text
that is not source. The REPL and `-e` print such a value as
`#<invalid utf-8>`.

---

### 6. I/O natives

Output goes to the innermost `with-out-str` buffer when one is open,
else to stdout through `vm.io`, one write per call (nothing is
buffered, so nothing is lost at `exit`). A VM with no `io` throws
`:io-error` from the print functions and `read-line`; `slurp`,
`spit` and `nano-time` fall back to a process-wide `std.Io`.

| Name | Arity | Semantics | Errors |
|---|---|---|---|
| `print`, `println` | 0+ | The arguments in display mode, separated by one space; `println` ends with `"\n"` (`(println)` writes just that); nil | `:io-error` |
| `pr`, `prn` | 0+ | The same in readable mode | `:io-error`, `:utf8-error` |
| `pr-str` | 0+ | The `pr` text as a string, no newline | `:utf8-error` |
| `print-str`, `println-str`, `prn-str` | 0+ | What `print`, `println`, `prn` would write, as a string (`core.nx`, through `with-out-str`) | — |
| `printf` | 1+ | `(print (apply format fmt args))` (`core.nx`) | as `format` |
| `newline` | 0 | `(print "\n")` (`core.nx`) | — |
| `with-out-str` | macro | The body's printed output as a string; nothing reaches stdout. Captures nest; a throw discards the buffer and propagates | — |
| `slurp` | 1 | The whole file at a path (relative to the working directory) as a string; no size cap; the text must be UTF-8 | `:kind-mismatch` (non-string path), `:invalid-path` (empty, or holding a NUL byte), `:file-not-found`, `:utf8-error`, `:io-error` (a directory, a permission, any other failure) |
| `spit` | 2+ | `(spit path x)` writes `(str x)` (nil: an empty file), replacing the file; `(spit path x :append true)` writes after its end. Parent directories are not created (`db/open` is the one call that creates them). nil | as `slurp`, and `:file-not-found` for a missing parent; `:arity-mismatch` (an odd option list), `:invalid-argument` (an option other than `:append`) |
| `read-line` | 0 | The next line of stdin, of any length, without its `\n` or a trailing `\r`; nil at end of input. It shares one buffer with the REPL, so neither loses what the other read | `:io-error` (a read failure) |
| `nano-time` | 0 | A monotonic clock in nanoseconds, reduced modulo the fixnum maximum, for intervals; the `time` macro prints `"Elapsed time: X msecs"` with `prn` | — |
| `exit` | 0–1 | Closes every store `db/open` or `nextomic/connect` opened, then ends the process with the status (0 by default; the integer's low eight bits, so `(exit 257)` exits 1 and `(exit -1)` 255). Nothing after it runs, `finally` blocks included, as with Java's `System/exit` (`test/golden/cli/exit-status.nx`) | `:kind-mismatch` (non-integer) |
| `*command-line-args*` | Var | The arguments after the program as a vector of strings, nil when there are none; `nexis run` binds it (TOOLING.md §1) | — |

The `with-out-str` buffer stack is process-wide (one isolate, one
thread); `nexis.internal/#%push-out` opens a buffer and `#%pop-out`
closes the innermost and returns its text.

**Rooting.** Every native here reads its arguments, which are rooted
for the call, allocates its result last and never calls back into
the VM, so none needs a root scope (GC.md §11.5).

---

### 7. Tests

`test/integration/eval_pipeline.zig` pins the text natives
(`parse-long` and `parse-double` included), `format`,
`nexis.string`, printing in both modes, `with-out-str`, `slurp` and
`spit` end to end; `src/format.zig` carries the per-kind printer
tests; `test/golden/cli/` pins `read-line` (`stdin`),
`*command-line-args*` (`args`) and `exit` (`exit-status`) through
`bin/nexis`; `test/integration/numbers.zig` pins the float
spellings.
