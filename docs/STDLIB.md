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
3. The image of the embedded sources is loaded (below). Without one,
   the sources themselves are evaluated, each with its namespace
   current: `core.nx`, `nextomic.nx`, `walk.nx`, `edn.nx`, `test.nx`,
   `pprint.nx`, `math.nx`, `string.nx`, `set.nx`.
4. Every namespace in the registry is marked loaded, so a `require`
   of one only makes the alias.

A failure in step 3 is a bug in an embedded file or the image and
panics with the loader's diagnostic or the image's error.

**The image.** Evaluating the sources at every start would read,
expand, compile and run 66 KB of nexis; instead the build does it once
and every binary loads the result (`src/image.zig`). `zig build` runs
`src/imagegen.zig`, built for the host over a runtime without an
image: it boots the sources (`stdlib.writeImage`), writes the image of
what they left, loads that image into a second runtime and compares
the two (`image.verify`), failing the build on any difference. Every
runtime module embeds the file as `stdlib_image`. A change to a source
or to any runtime file the generator compiles makes a new image; one
image serves every target, all 64-bit little-endian.

The image holds the state the boot leaves: each namespace, its parent
and aliases, and its map of names to Vars rebuilt at the capacity it
had and in an order that puts every entry back in its slot, so the map
iterates as after the boot (`ns-interns`, `:refer :all`); each Var's
root, metadata and flags (natives the sources did not touch are left as
step 2 installed them); the record types and protocols and their
implementations; the routines the closures run, with their code as
the compiler quickened it (`docs/VM.md` §10.10, so loading one costs
no rewrite), constants, Var tables, captures, `try` table and spans into the
embedded text, so an error inside a library function reports the same
`file:line:col`; the heap values all of these reach, with their
metadata and sharing (a cell or atom is made empty, and filled once
everything it can reach exists); and how many names the boot
generated, so `gensym` and the expander's auto-gensyms count on from
where they would have; the names inside the library's own code are
those of a first boot in the process, as the build's was. Keywords
and symbols are written as text and interned again, natives as the
Var step 2 installed them in.

The loader makes each closure before the routine it runs is read, so
it verifies the routines (`Routine.verifyAlone`, `docs/VM.md` §5)
once the image is whole: in debug and safe builds every routine, and
one that does not verify fails the load with `UnfitRoutine` instead
of reaching the dispatch, which trusts verified code (VM.md §8). A
release build trusts them: the only image it loads is the one it
embeds (an image whose header differs is not loaded), byte for byte
the image the generator, a debug build, loaded and verified before
the binary was built, and verifying it again would cost every start
0.35 M instructions, 1.6% (`docs/PERF.md` §3.18).

It is an internal format of one build, not the codec: no other build
reads it, and nothing in it is compatible across versions (PLAN §23
#25 governs the codec alone). Its header carries a format number and
a fingerprint of the sources and of the layouts it writes; an image
whose header differs from this build's is not loaded, and the sources
boot instead. A struct the image writes field by field (a routine, a
Var, a capture descriptor) gaining a field fails to compile until
`image.zig` carries it, and the writer fails the build on a value it
cannot carry: a kind outside the image's set (strings, bignums,
regexes, vectors, lists of cons cells, hash maps and sets, closures,
cells, atoms, records, protocols and their functions), a list view, a
Var inside a `binding`.

| Namespace | Natives (`src/stdlib.zig`) | nexis source | Contract |
|---|---|---|---|
| `nexis.core` | `core_natives` | `core.nx` | text §2, printing §5, I/O §6, the rest of Clojure's core §8; `=` and `hash` SEMANTICS.md; `compare`, sorted collections, `subseq` and `rseq` SORTED.md; atoms ATOM.md; transients TRANSIENT.md; typed vectors TYPED_VECTOR.md §7.1; records and protocols PROTOCOLS.md; the macros MACROEXPAND.md §2b |
| `db` | `db_natives` | (`with-tx`, `with-read-tx`, `with-snapshot` in `core.nx`) | DB.md §12 |
| `nextomic` | `src/nextomic/natives.zig` | `nextomic.nx` (`with-conn`) | NEXTOMIC.md |
| `nexis.string` | `string_natives` | `string.nx` | §3 |
| `nexis.set` | — | `set.nx` | §4 |
| `nexis.walk` | — | `walk.nx` | §4 |
| `nexis.edn` | — | `edn.nx` | §4 |
| `nexis.math` | `math_natives` | `math.nx` (`PI`, `E`, `floor-div`, `floor-mod`) | TOOLING.md §4 |
| `nexis.test` | — | `test.nx` | TOOLING.md §3 |
| `nexis.pprint` | — | `pprint.nx` | TOOLING.md §4 |
| `nexis.simd` | `simd_natives` | — | TYPED_VECTOR.md §7.2 |
| `nexis.internal` | `internal_natives` | — | the `#%` helpers macros emit: records and protocols (PROTOCOLS.md §7), `#%catch-matches?` (`try`), `#%kwargs` (`& {:keys ...}`), `#%current-ns` (TOOLING.md §3), `#%delay` (`delay`, §8), `#%sorted-map` / `#%sorted-set` (a sorted collection a macro returns, MACROEXPAND.md §5), `#%push-out` / `#%pop-out` (`with-out-str`, §6) |

**Resolution.** Every other namespace has `nexis.core` as its parent,
so an unqualified symbol a namespace does not define resolves in
`nexis.core`. The other namespaces are reached qualified with no
`require` (`(nexis.string/join "," xs)`), or through an alias
(`(require '[nexis.string :as s])`); a bare `join` is
`UnresolvedSymbol`. `volatile!`, `volatile?`, `vreset!` and `vswap!`
are defined in `core.nx` as the atom operations: one isolate, one
thread.

**Clojure's names.** The loader (`clojure_names` in
`src/loader.zig`) accepts seven Clojure library namespaces:
`clojure.string` → `nexis.string`, `clojure.set` → `nexis.set`,
`clojure.test` → `nexis.test`, `clojure.pprint` → `nexis.pprint`,
`clojure.walk` → `nexis.walk`, `clojure.edn` → `nexis.edn`,
`clojure.math` → `nexis.math`.
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
- A helper no caller outside the file names is `defn-`, so `(require
  '[ns :refer :all])` skips it; a function a macro's expansion calls
  stays public, since the expansion names it from the caller's
  namespace.

---

### 2. Core text and string natives

All in `nexis.core`. Strings index by Unicode scalar (code point),
never by byte or grapheme: `count`, `nth`, `get`, `subs` and
`nexis.string/index-of` agree (`(count "🇺🇸")` is 2). A string with
malformed UTF-8 (a string's bytes are not validated: `read-line`,
`*command-line-args*`, the codec and a store can all bring one in)
makes any of them throw `:utf8-error` (STRING.md §2, invariant 4); no
string function panics on one.

| Name | Arity | Semantics | Errors |
|---|---|---|---|
| `str` | 0+ | The arguments' text, concatenated: nil is empty, a string or char is itself, anything else as `pr-str` prints it, so strings inside a collection keep their quotes: `(str "a" \b 1 nil :k)` is `"ab1:k"`, `(str ["a" nil])` is `"[\"a\" nil]"`; `(str)` is `""`. One string argument is returned itself, as Clojure's (`(identical? s (str s))`); arguments that are all nil, strings, chars or fixnums are measured and written once into a string of that length | `:utf8-error` (a malformed string inside a collection) |
| `string?` | 1 | Whether the argument is a string | — |
| `subs` | 2–3 | `(subs s start)`, `(subs s start end)`: a fresh string of the code points in `[start, end)`, `end` defaulting to the count; `(subs "héllo" 1 3)` is `"él"` | `:kind-mismatch` (non-string, non-fixnum index), `:index-out-of-bounds` (negative, past the count, or `start > end`) |
| `count` | 1 | Of a string: its code points, an O(n) scan | — |
| `nth` | 2–3 | Of a string: the char at a code-point index; out of range (negative included) is the default, or `:index-out-of-bounds` without one | `:kind-mismatch` (non-fixnum index) |
| `get` | 2–3 | Of a string: the char at a fixnum index, else the default (nil); `contains?` answers whether the index is in range | — |
| `seq` and the sequence library | — | A string is a seq of its chars (`(seq "hé")` is `(\h \u{E9})`, `(seq "")` nil), so `first`, `map`, `into`, `reverse`, `frequencies` and the rest take one. `(empty "abc")` is nil. A string is not callable (`:not-callable`) | — |
| `char` | 1 | The char with a code point; a char is itself | `:kind-mismatch` (non-integer), `:invalid-argument` (not a Unicode scalar: negative, past `0x10FFFF`, a surrogate) |
| `char?` | 1 | Whether the argument is a char | — |
| `int`, `short`, `byte`, `long` | 1 | Of a char: its code point (`(int \é)` is 233); of a number, its integer part (SEMANTICS.md §2.2). `long` takes any size (`(long 1e30)` is a bignum); `int`, `short` and `byte` only the range of Java's type, checked on the integer part as Clojure's boxed cast checks it (`(byte 127.5)` is 127), and make NaN 0 | `:kind-mismatch`, `:invalid-argument` (out of range; an infinity; NaN for `long`) |
| `name` | 1 | The name part of a keyword or symbol; a string is itself | `:kind-mismatch` |
| `namespace` | 1 | The namespace part of a keyword or symbol, nil when unqualified | `:kind-mismatch` (a string included) |
| `keyword` | 1–2 | `(keyword x)`: interned from a string, symbol or keyword (`"a/b"` makes the qualified `:a/b`); nil is nil. `(keyword ns name)`: qualified, a nil `ns` leaving it unqualified. The name is not checked against the reader's grammar: `(keyword "a b")` prints `:a b` | `:kind-mismatch`, `:invalid-argument` (empty name) |
| `symbol` | 1–2 | As `keyword`, making a symbol; `(symbol nil)` is `:kind-mismatch` | `:kind-mismatch`, `:invalid-argument` (empty name) |
| `parse-long` | 1 | The integer a whole string spells as Java's `Long/valueOf` reads it: ASCII decimal digits after one optional `+` or `-`, within the 64-bit range (a fixnum or bignum); anything else nil (`" 42"`, `"4.2"`, `"1_000"`, `"0x10"`, `"99999999999999999999"`) | `:kind-mismatch` (non-string) |
| `parse-double` | 1 | The float a string spells in the grammar Clojure's `parse-double` admits (Java's `Double/valueOf`): control or space bytes around an optional sign and `NaN`, `Infinity`, a decimal with an optional exponent (`"1e3"`, `".5"`, `"5."`) or a hex significand with its binary exponent (`"0x1p3"`), the last two with an optional `f`, `F`, `d` or `D` suffix; anything else nil (`"inf"`, `"nan"`, `"1_000"`, `"0x10"`) | `:kind-mismatch` |
| `parse-boolean` | 1 | `"true"` and `"false"` to booleans, any other string nil (`core.nx`) | `:kind-mismatch` |
| `format` | 1+ | Below | Below |
| `read-string` | 1–2 | `(read-string s)`, `(read-string opts s)`: the first form of the string as data (the reader of `docs/FORMS.md`); text after it is ignored. A string that holds no form (only whitespace, comments and `#_` discards) is the value of `:eof` in the map `opts` when it has that key; other keys are ignored | `:kind-mismatch` (a non-string, or `opts` not a map), `:reader-error` (no form and no `:eof`, a form left open, or text that does not read) |
| `compare` | 2 | -1, 0 or 1. Of two strings: byte order of their UTF-8, which is code-point order; `sort` and sorted collections use it (the whole order is SORTED.md §6). Only the sign is the contract: Clojure's `compare` of two strings is `String.compareTo`'s difference (`(compare "B" "a")` is -31 there, -1 here) | — |

**`format`.** `(format fmt & args)` is a subset of Java's
`Formatter`, as Clojure's `format` uses it. `fmt` is text with
conversions `%[flags][width][.precision]conv`, each consuming the next
argument:

| Conversion | Argument | Text |
|---|---|---|
| `%s` | any | As `str` makes it, except nil is `nil` (Java prints `null`); a precision keeps that many characters: `(format "%.2s" "héllo")` is `"hé"`, and is `:utf8-error` when a malformed sequence starts within them |
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

The natives are in `string_natives`; `capitalize`, `reverse`,
`split-lines` and `escape` are in `src/stdlib/string.nx`. Every
function takes strings, not chars or nil, except where the table says
so; any other kind is `:kind-mismatch`. `split`, `replace` and
`replace-first` take a pattern (`docs/REGEX.md` §11) or a literal
string (the replaces also a char). Searches compare bytes 32 at a time (`string.Matches`, STRING.md §3),
which on valid UTF-8 match only at code-point boundaries. `split`
validates its arguments once and makes each piece from its bytes;
`join` of nil, strings, chars and fixnums and every `replace` measure
the result and write it once; a `replace` that finds nothing returns
`s` itself.

| Name | Arity | Semantics |
|---|---|---|
| `lower-case`, `upper-case` | 1 | ASCII letters mapped; every other byte, every byte of a multibyte scalar included, unchanged: `(upper-case "héllo")` is `"HéLLO"` |
| `capitalize` | 1 | The first character upper-case and the rest lower-case, by the same ASCII rule |
| `reverse` | 1 | The code points in reverse order (not grapheme clusters) |
| `trim`, `triml`, `trimr` | 1 | Without whitespace at both ends, the start, the end. Whitespace is Java's `Character/isWhitespace`, as Clojure's: tab through CR, FS through US, space, and the Unicode space, line and paragraph separators except the no-break ones (U+2003 and U+3000 are trimmed, U+00A0 stays). A byte that is not part of a well-formed UTF-8 sequence is not whitespace: it stops the trim and stays |
| `trim-newline` | 1 | Without every `\n` and `\r` at the end |
| `blank?` | 1 | Whether the argument is nil, empty, or only whitespace as `trim` reads it |
| `starts-with?`, `ends-with?`, `includes?` | 2 | Whether the second string is a prefix, suffix, substring of the first |
| `index-of` | 2–3 | `(index-of s x)`, `(index-of s x from)`: the code-point index of the first occurrence of `x` (a string or a char) at or after `from`, nil when there is none; `from` is clamped to `[0, (count s)]`; `(index-of "héllo" "l")` is 2 |
| `last-index-of` | 2–3 | The code-point index of the last occurrence starting at or before `from` (default the count; clamped to it, and nil when negative, as Java's `lastIndexOf`), nil when there is none; the empty string is found at `from` |
| `split` | 2–3 | `(split s sep)`, `(split s sep limit)`: a vector of the pieces between the matches of the pattern `sep`, Java's `Pattern.split`: a match that is empty at the start makes no leading piece (`(split "1a1" #"1")` is `["" "a"]`), no match at all gives `[s]`, and the limit works as below. A string `sep` is a nexis extension: the pieces between occurrences of `sep`, as Clojure's `split` with a pattern that matches only `sep`. With no limit (or 0) trailing empty pieces are dropped (`(split "a,b,," ",")` is `["a" "b"]`, `(split ",," ",")` is `[]`, `(split "" ",")` is `[""]`); a positive limit splits at most `limit − 1` times and keeps the rest whole; a negative one keeps every trailing empty piece. An empty `sep` splits between code points, as Clojure's `#""` does (`(split "abc" "")` is `["a" "b" "c"]`) |
| `split-lines` | 1 | The lines of `s`, split at `\n` or `\r\n`, trailing empty lines dropped |
| `join` | 1–2 | `(join coll)`, `(join sep coll)`: the elements of any seqable, each as `str` makes it (nil empty), separated by `sep`: `(join ", " ["a" nil 1])` is `"a, , 1"`; a map joins its entries (`"[:a 1]"`), a string its chars; nil is `""`. A set joins in its iteration order |
| `replace-first` | 3 | `(replace-first s match replacement)`: the first match replaced, else `s` itself. A pattern `match` takes what `replace` takes; a string or char `match` is found as it is, an empty one at the start, and `replacement` is a string or char |
| `re-quote-replacement` | 1 | `s` with a backslash before each `\` and `$`, so a pattern `replace` inserts it literally (`Matcher.quoteReplacement`) |
| `escape` | 2 | `(escape s cmap)`: `s` with each character that `cmap` maps to a non-nil value replaced by that value's text (`str`), the rest kept: `(escape "a<b" {\< "&lt;"})` is `"a&lt;b"` (`string.nx`) |
| `replace` | 3 | `(replace s match replacement)`: every non-overlapping occurrence of `match`, left to right, replaced; the scan resumes after each match, so `(replace "aaa" "aa" "x")` is `"xa"`. `match` and `replacement` are both strings or both chars (`(replace "a.b" \. \/)`); an empty `match` is found before every code point and at the end (`(replace "ab" "" "-")` is `"-a-b-"`), as Java's `String.replace`, and the replacement is literal. A pattern `match` is Java's `replaceAll`: a string replacement reads `$1` and `${name}` as groups and `\$` as `$` (`(replace "a1b2" #"(\d)" "<$1>")` is `"a<1>b<2>"`; one Java refuses throws `{:error :invalid-replacement :message M}` with Java's sentence, `No group 2`), and a function replacement is called with each match (a string, or the groups vector) and must return a string (`:kind-mismatch`) |

Errors beyond `:kind-mismatch`: `split` and the replaces validate every
string argument as UTF-8 before scanning and throw `:utf8-error` on a
malformed one, so a separator can never cut a scalar in two; the
code-point functions throw `:utf8-error` as §2 says.

Full Unicode case mapping, normalization and grapheme segmentation
are absent (STRING.md §6).

---

### 4. `nexis.set`, `nexis.walk` and `nexis.edn`

**`nexis.set`** is Clojure's `clojure.set`, written in
`src/stdlib/set.nx` over the core collection functions.

| Name | Arity | Semantics |
|---|---|---|
| `union` | 0+ | Every element of any argument, poured `into` the largest, which keeps its kind and metadata: `(union (sorted-set 3 1) #{2})` is a sorted set; `(union)` is `#{}`, one argument is itself (`(union nil)` is nil) |
| `intersection` | 1+ | The elements of the first set present in every other one, `disj`ed from the smallest, which keeps its kind; with one argument, that argument unchanged |
| `difference` | 1+ | The first set without the elements of the others; the first must be a set (`disj`), else `:kind-mismatch` |
| `subset?`, `superset?` | 2 | Whether every element of the first is in the second (`subset?`), or the reverse |
| `select` | 2 | `(select pred s)`: `s` without the elements for which `pred` is falsy (`disj`), so of `s`'s kind |
| `map-invert` | 1 | The map with keys and values swapped; of duplicate values, the key iterated last wins |
| `rename-keys` | 2 | `(rename-keys m kmap)`: `m` with each key of `kmap` present in `m` renamed to its value |

`index`, `project`, `join` and `rename` (the relational functions)
are absent.

**`nexis.walk`** is Clojure's `clojure.walk`, written in
`src/stdlib/walk.nx`. `walk` rebuilds a form in its own kind: a list
as a list and any other seq (a lazy seq, a range, a cons) as a
realized seq, each in order and with the form's metadata, as
Clojure's `seq?` arm keeps them; a record by `conj`ing its walked entries onto it, so it
keeps its type, and any other collection by pouring the walked
elements `into` `(empty form)`, so a sorted collection keeps its
comparator and every collection its metadata. A map's elements are
its `[k v]` entries, which are vectors (§8 `map-entry?`), so the
function sees each entry as a vector. A typed vector, like every
value that is not a collection, is a leaf. The walks recurse on the
VM's frames, so a form nested past the frame cap is a catchable
`:stack-overflow`.

| Name | Arity | Semantics |
|---|---|---|
| `walk` | 3 | `(walk inner outer form)`: `outer` of `form` rebuilt from `inner` of each element, as above; a leaf is `(outer form)` |
| `postwalk`, `prewalk` | 2 | `f` of every subform: `postwalk` children first, each parent rebuilt from what `f` returned for them; `prewalk` the parent first, walking into what `f` returned |
| `postwalk-replace`, `prewalk-replace` | 2 | `(postwalk-replace smap form)`: every subform that is a key of `smap` replaced by its value |
| `keywordize-keys`, `stringify-keys` | 1 | Every string key of every map a keyword; every keyword key its name. A record or sorted map in the form becomes a hash map, as in Clojure |
| `macroexpand-all` | 1 | Every list in the form `macroexpand`ed, outermost first (a host macro's expansion is the expander's, so `when` gives `(if c (do ...) nil)`) |

`postwalk-demo` and `prewalk-demo` are absent.

**`nexis.edn`** is Clojure's `clojure.edn`, in `src/stdlib/edn.nx`:
`(read-string s)` and `(read-string opts s)` are `nexis.core`'s
`read-string` with `{:eof nil}` unless `opts` give an `:eof`, so a
string with no form is nil, and nil for a nil `s`. Nothing is
evaluated (the reader has no `#=`). It reads nexis's syntax, which
EDN's is a part of: reader sugar (`'x`, `@x`, `#()`) reads as the form
it stands for, where Clojure's EDN reader refuses it, and the reader
has no tagged literals (PLAN §4), so a tag is a `:reader-error` and
`:readers` and `:default` have nothing to apply to. There is no `read`
from a stream.

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
| `str`, `%s`, `join`, `spit` | nil is empty (`%s` writes `nil`); a string or char display, a float in Java's spelling (`(str ##Inf)` is `"Infinity"`); any other value readable, so `(str ["a"])` is `"[\"a\"]"` and `(str [##Inf])` `"[##Inf]"` |

**By kind** (both modes unless the row says otherwise):

| Kind | Printed |
|---|---|
| nil, booleans | `nil`, `true`, `false` |
| fixnum, bignum | Decimal, no suffix |
| float | SEMANTICS.md §6.3: `1.0`, `-0.0`, `1.0E10`, `1.0E-4`; `##NaN`, `##Inf`, `##-Inf` in both modes (`str` and `%s` of a bare float write Java's `NaN`, `Infinity`, `-Infinity`) |
| char | display: its UTF-8. readable: `\space`, `\newline`, `\tab`, `\return`, `\formfeed`, `\backspace`, `\\`, printable ASCII as `\x`, anything else `\u{HEX}` (`\u{E9}`) |
| string | display: its bytes. readable: double-quoted, `\" \\ \n \t \r` escaped, other ASCII controls and DEL as `\u{HEX}`, every other byte as itself (`"é"`) |
| keyword, symbol | `:ns/name`, `ns/name`; names are not escaped |
| list, vector, set | `(a b)`, `[a b]`, `#{a b}`, elements separated by one space; a sorted set in its order |
| lazy seq | as a list, `(a b)`, `()` when empty. The printer runs no code: every caller but an error report realizes the value first, and a block whose body has not run prints as `...` (`docs/LAZY.md` §8) |
| map | `{k v, k v}`, entries separated by `, `; a sorted map in its order |
| record | `#ns.Type{:k v, ...}` (the fields in the record's mode), or `#<record type-id=N>` when the interner has no name for the type; `(reduced x)` is the record `#nexis.core.Reduced{:val x}` |
| typed vector | `#i64[1 2]`, `#f64[1.5]` |
| function, native fn | `#<fn>`, `#<native-fn NAME>` (`NAME` is `ns/name` outside `nexis.core`: `#<native-fn nexis.string/join>`) |
| var | `#'ns/name`, as Clojure prints one (`#'nexis.core/inc`, `#'user/x`) |
| atom, transient | `#<atom>`, `#<transient>` |
| regex | `#"source"`, with Clojure's escaping of `"` (`docs/REGEX.md` §8); `str` and `%s` of a bare pattern write its source, as `Pattern.toString` does |
| matcher | `#<matcher #"source">` |
| protocol, protocol fn | `#<protocol id=N>`, `#<protocol-fn proto=N method=M>` |
| durable ref | `#<durable-ref :tree hex:KEY>`, the key bytes in upper-case hex |
| db connection, transactions | `#<db-connection>`, `#<db-write-txn>`, `#<db-read-txn>` |
| Nextomic handles | `#nextomic/conn "path"`, `#nextomic/db {:basis-t N :mode :current}` (`:as-of N` / `:since N` when set), `#nextomic/entity {:db/id N}` |

A hash map or set of up to eight entries prints in insertion order, a
larger one in hash order (CHAMP.md §2); a sorted one prints in its
comparator's order, so `(pr-str (sorted-map :b 1 :a 2))` is `"{:a 2,
:b 1}"` and reads back as a hash map equal to it. A Var's `#'ns/name` reads
back as `(var ns/name)`, which evaluates to the same Var; none of the
`#<...>`, `#ns.Type{...}`, `#i64[...]` or `#nextomic/...` forms reads
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
| `flush` | 0 | nil: every print writes through at once, so there is nothing to flush (`core.nx`) | — |
| `with-out-str` | macro | The body's printed output as a string; nothing reaches stdout. Captures nest; a throw discards the buffer and propagates | — |
| `slurp` | 1 | The whole file at a path (relative to the working directory) as a string; no size cap; the text must be UTF-8 | `:kind-mismatch` (non-string path), `:invalid-path` (empty, or holding a NUL byte), `:file-not-found`, `:utf8-error`, `:io-error` (a directory, a permission, any other failure) |
| `spit` | 2+ | `(spit path x)` writes `(str x)` (nil: an empty file), replacing the file; `(spit path x :append true)` writes after its end. Parent directories are not created (`db/open` is the one call that creates them). nil | as `slurp`, and `:file-not-found` for a missing parent; `:arity-mismatch` (an odd option list), `:invalid-argument` (an option other than `:append`) |
| `read-line` | 0 | The next line of stdin, of any length, without its `\n` or a trailing `\r`; nil at end of input. It shares one buffer with the REPL, so neither loses what the other read | `:io-error` (a read failure) |
| `nano-time` | 0 | A monotonic clock in nanoseconds, reduced modulo the fixnum maximum, for intervals; the `time` macro prints `"Elapsed time: X msecs"` with `prn` | — |
| `exit` | 0–1 | Closes every store `db/open` opened and every Nextomic connection `connect` made, syncs every store file a commit left unsynced (`docs/DB.md` §3.3), then ends the process with the status (0 by default; the integer's low eight bits, so `(exit 257)` exits 1 and `(exit -1)` 255). Nothing after it runs, `finally` blocks included, as with Java's `System/exit` (`test/golden/cli/exit-status.nx`) | `:kind-mismatch` (non-integer) |
| `*command-line-args*` | Var | The arguments after the program as a vector of strings, nil when there are none; `nexis run` binds it (TOOLING.md §1) | — |

The `with-out-str` buffer stack is process-wide (one isolate, one
thread); `nexis.internal/#%push-out` opens a buffer and `#%pop-out`
closes the innermost and returns its text. The stack and its buffers
live on one process allocator (`std.heap.smp_allocator`), not a VM's,
so a macro's sub-VM prints into a buffer the program opened.
`stdlib.discardOutCaptures` closes every open buffer; the CLI calls it
where an error no handler takes (out of memory) ends a run, which
skips `with-out-str`'s `#%pop-out`, so the REPL's next output is not
swallowed.

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

---

### 8. More of Clojure's core

Functions of `nexis.core` that no kind doc owns, each with Clojure
1.12's semantics except where a row says otherwise. Lazy seqs are
`docs/LAZY.md`'s; a sequence function that §7 there does not list
returns a realized list where Clojure returns a lazy seq.

| Name | Arity | Semantics |
|---|---|---|
| `nfirst` | 1 | `(next (first x))` |
| `tree-seq` | 3 | `(tree-seq branch? children root)`: the lazy seq of every node, depth first, each before its children; `children` of a node for which `branch?` is truthy gives its children. Realizing a node calls `branch?` and `children` on it, as Clojure's does; the children still to visit wait on an explicit stack, so a tree of any depth walks |
| `replace` | 2 | `(replace smap coll)`: each element that `smap` (a map, or a vector by index) has as a key replaced by its value; a vector of a vector, keeping its metadata, else a lazy seq |
| `partitionv`, `partitionv-all` | 2–4, 2–3 | `partition` and `partition-all` with each part a vector |
| `splitv-at` | 2 | `[(vec (take n coll)) (drop n coll)]` |
| `bounded-count` | 2 | `(count coll)` of a counted collection, else the count of at most the first `n` elements (`(bounded-count 2 "abcd")` is 2) |
| `random-sample` | 2 | `(random-sample prob coll)`: each element kept with probability `prob` (`rand`) |
| `lazy-seq` | macro | `(lazy-seq body...)`: a lazy seq whose body runs once, when the seq is first walked, its result cached; a body that throws runs again on the next walk (`docs/LAZY.md` §4) |
| `chunked-seq?`, `chunk-first`, `chunk-rest`, `chunk-next`, `chunk-buffer`, `chunk-append`, `chunk`, `chunk-cons` | 1, 1, 1, 1, 1, 2, 1, 2 | Clojure's chunk functions, for library code (`docs/LAZY.md` §7): `chunked-seq?` is true of a chunked cons and of a vector's view; a chunk is a vector, `chunk-buffer` a transient vector, `chunk-append` `conj!`, `chunk` `persistent!`; `chunk-cons` copies the vector into a chunked cons in front of the rest, or is the rest itself when the chunk is empty |
| `transduce`, `completing`, `cat`, `halt-when`, `eduction` | 3–4, 1–2, 1, 1–2, 1+ | Clojure 1.12's transducers (`docs/LAZY.md` §10), as are `into`'s 3-arity, `sequence`'s 2-arity and the transducer arities of `map`, `filter`, `remove`, `keep`, `take`, `take-while`, `drop`, `drop-while`, `map-indexed`, `keep-indexed`, `partition-all`, `partition-by`, `mapcat`, `interpose`, `distinct` and `dedupe` |
| `lazy-cat` | macro | `(lazy-cat coll...)`: `(concat (lazy-seq coll) ...)`, each coll's expression evaluated when the walk reaches it |
| `iterate`, `repeat`, `repeatedly`, `cycle` | 2, 1–2, 1–2, 1 | Lazy and, without a count, infinite (`docs/LAZY.md` §7): `(take 5 (iterate inc 0))`; `(iterate f x n)` is `:arity-mismatch` |
| `doall`, `dorun` | 1–2 | Walk the seq, realizing it (the first `n` steps with a count, as Clojure's `next` loop); `doall` returns its argument, `dorun` nil |
| `rand`, `rand-int`, `shuffle` | 0–1, 1, 1 | Clojure's, over one process-wide generator seeded from the I/O's entropy at its first use (as `random-uuid` and `random-sample`): `(rand-int n)` of an integer is `(int (rand n))`, so 0 for 0 and in (n, 0] below it |
| `in-ns` | 1 | `(in-ns 'name)`: makes the namespace named by the symbol current, creating it with `nexis.core` referred; nil, where Clojure returns the namespace |
| `counted?` | 1 | True of a list, vector, map, set, record, typed vector or transient; false of nil, strings and lazy seqs |
| `indexed?` | 1 | True of a vector or typed vector |
| `map-entry?` | 1 | True of a two-element vector: a map's entries are vectors (`(map-entry? [1 2])` is true, where Clojure's is false) |
| `delay` | macro | `(delay body...)`: a delay, the record `nexis.core/Delay`, whose body runs the first time it is forced; every later `force` or `deref` (`@d`) returns the same value, or rethrows what the body threw (the body runs once either way) |
| `force` | 1 | A delay's value, forcing it; anything else itself |
| `delay?`, `realized?` | 1 | Whether `x` is a delay; whether the delay has been forced, or a lazy seq's body has run (`docs/LAZY.md` §4; `realized?` of anything else is `:kind-mismatch`) |
| `Closeable`, `close` | protocol | What `with-open` closes: `close` of a db connection is `db/close`, of a Nextomic connection `nextomic/release`; a record or kind extends it to be closed the same way |
| `with-open` | macro | `(with-open [name init ...] body...)`: body with each name bound, each closed through `close` in reverse order on every exit, a throw included; the bindings must be symbol and value pairs, else the expansion fails |
| `tap>` | 1 | Calls every function `add-tap` added with `x`, ignoring any that throws, and returns true. Clojure calls the taps on another thread; one isolate, one thread calls them before `tap>` returns |
| `add-tap`, `remove-tap` | 1 | Add or remove a tap function; nil |
| `class` | 1 | The type of `x`: for a record the symbol it prints with (`user.P`), for anything else the keyword `extend-type` names its kind with (`:vector`, `:map`, `:set`, `:list`, `:fixnum`, `:bignum`, `:float`, `:string`, `:typed_vector`, `:function`, `:native_fn`, `:var_`, ...), except that both booleans are `:boolean`; nil for nil |
| `type` | 1 | `(or (:type (meta x)) (class x))`, as Clojure's |
| `instance?` | 2 | `(instance? t x)`: whether `(class x)` is `t`, a keyword or symbol (`(instance? :vector [])`, `(instance? 'user.P p)`); there is no hierarchy, so `(instance? :map p)` of a record is false. Any other `t` is `:kind-mismatch` |
| `var?` | 1 | Whether `x` is a Var |
| `var-get` | 1 | The value of the Var (`deref`); a non-Var is `:kind-mismatch` |
| `find-var` | 1 | `(find-var 'ns/name)`: the Var the qualified symbol names, nil when the namespace has none; `:no-such-namespace` when there is no such namespace |
| `load-string`, `load-file` | 1 | Read and evaluate each form of the string (of the file's text) in turn in the current namespace through `eval`, so a form that does not read (a stray closing delimiter, an unfinished form) raises `:reader-error` after the ones before it ran; the namespace in force when it was called is restored afterwards, whether it returns or throws, as Clojure's `Compiler.load` binds `*ns*`; the last form's value, nil for none. Each form is read as `read-string` reads it, so a syntax-quote in the text is `:reader-error` |
| `array-map` | 0+ | `(apply hash-map kvs)`: a map of up to eight entries keeps its insertion order (§5), all that Clojure's array map promises; a larger one is a hash map, as Clojure's becomes one past eight |
| `bigint`, `biginteger` | 1 | `long`: one integer domain (BIGNUM.md), so a number truncated to an integer of any size |
| `decimal?`, `inst?` | 1 | false: there are no decimals and no instants (PLAN §4) |
| `qualified-ident?`, `simple-ident?` | 1 | Whether `x` is a keyword or symbol with a namespace, without one |
| `bit-and-not`, `bit-flip` | 2+, 2 | `(bit-and x (bit-not y))` over each further argument; `bit-flip` is `bit-set` or `bit-clear` of the bit, as `bit-test` finds it |
| `alter-var-root` | 2+ | `(alter-var-root v f & args)`: sets the root of the Var `v` to `(apply f root args)` and returns it; a `binding` in force is left as it is. An unbound Var's root is nil to `f` and bound after (Clojure passes its `Unbound` object). A non-Var is `:kind-mismatch` |
| `with-redefs-fn`, `with-redefs` | 2, macro | `(with-redefs-fn {#'v val ...} f)` calls `f` with each Var's root set to its value; `(with-redefs [name val ...] body...)` does it for the body, the names resolved as `var` resolves them. Root writes, not bindings, so every caller sees them and a Var need not be dynamic; each root is restored on every exit, a throw included. An unbound Var is left bound to nil. A call the compiler inlines (the arithmetic and comparison functions, COMPILER.md) does not go through the Var |
| `*ns*` | Var | The namespace a form is compiled in, as its name symbol: the compiler sets the root before it expands each top-level form, and `in-ns` when it switches, so `(ns-name *ns*)` in a file or a macro names the file's namespace. Dynamic, but a `binding` of it does not change where forms compile |
| `special-symbol?` | 1 | Whether `s` is a name the compiler takes as a special form: `def if do let* fn* loop* letfn* quote var recur try catch finally throw set! &` |
| `find-ns`, `the-ns`, `ns-name` | 1 | A namespace is its name symbol: `find-ns` returns the symbol when a namespace has that name, else nil; `the-ns` and `ns-name` return it, else throw `:no-such-namespace`. A non-symbol is `:kind-mismatch` |
| `all-ns` | 0 | Every namespace's name, sorted |
| `ns-interns`, `ns-publics` | 1 | The map of name symbol to Var of every Var interned in the namespace (the ones it refers to from another excluded), an unbound one a `declare` or a forward reference made included; `ns-publics` leaves out those marked `:private`. `clojure.string` and its kin hold `nexis.string`'s Vars, so ask the `nexis.*` namespace |
| `resolve`, `ns-resolve` | 1, 2 | `(resolve sym)`, `(ns-resolve ns sym)`: the Var `sym` names in the current namespace or `ns`, resolved as the compiler resolves a global (an unqualified name the namespace's own or referred, then `nexis.core`'s; a qualified one through an alias or a namespace name), else nil. A host macro (`when`, `let`, `defn`, ...) has no Var, so it resolves to nil |
| `random-uuid` | 0 | A random version-4 UUID. A UUID is its canonical lowercase text, a string, as Nextomic's `:db.type/uuid` values are; there is no `#uuid` literal |
| `parse-uuid` | 1 | The canonical text of the UUID a string spells as 8-4-4-4-12 hex digits of either case, else nil (Java's lenient short groups included); a non-string is `:kind-mismatch` |
| `uuid?` | 1 | Whether `x` is a string in the canonical form (so `(uuid? (random-uuid))` is true, and an uppercase spelling is not) |
| `re-pattern`, `re-matcher`, `re-find`, `re-matches`, `re-groups`, `re-seq` | 1, 2, 1–2, 2, 1, 2 | Clojure's regular expressions, over the linear-time engine of `docs/REGEX.md`, which owns their rows (§9 there): `(re-find #"\d+" "ab12")` is `"12"`, `(re-seq #"(\w)=(\d)" "a=1 b=2")` is `(["a=1" "a" "1"] ["b=2" "b" "2"])`, lazy |
