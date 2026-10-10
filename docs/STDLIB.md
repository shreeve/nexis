## STDLIB.md — the standard library: namespaces, text, sets, printing and I/O

The contract for the parts of the standard library that no kind doc
owns: the namespaces and how they boot, the core text natives,
`nexis.string`, `nexis.set`, printing (`src/format.zig`), the I/O
natives, the documentation `doc` reads (§10), the process and its
programs (`nexis.sys`, `nexis.shell`, §11), instants (`nexis.time`,
§12) and JSON (`nexis.json`, §13). The natives are in
`src/stdlib.zig`, one table per namespace; the rest of the library is
nexis in `src/stdlib/*.nx`.
An error a native or a library function raises is caught as its error
map, `{:error :tag :message m ...}` with the place of the program's
call it was raised under (`docs/VM.md` §13): the `.nx` sources raise
theirs through `nexis.internal/#%raise`; a
wrong argument count is `:arity-mismatch` for every native (the VM
checks the declared arity).

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
   `pprint.nx`, `math.nx`, `string.nx`, `set.nx`, `sys.nx`,
   `shell.nx`, `time.nx`, `json.nx`.
4. Every namespace in the registry is marked loaded, so a `require`
   of one only makes the alias.

Memory running out in step 3 is reported as at any other time: the
CLI prints its out-of-memory report and exits 5 (`TOOLING.md` §1).
Any other failure there is a bug in an embedded file or the image and
panics with the loader's diagnostic or the image's error.

**The image.** Evaluating the sources at every start would read,
expand, compile and run 100 KB of nexis; instead the build does it once
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
`file:line:col`; every arity table (`docs/VM.md` §5), written after
the routines as each member's index, with every member of a table
written once the first is (a closure names only the head), and set on
each member once all of them are made; the heap values all of these reach, with their
metadata and sharing (a cell or atom is made empty, and filled once
everything it can reach exists); and how many names the boot
generated, so `gensym` and the expander's auto-gensyms count on from
where they would have; the names inside the library's own code are
those of a first boot in the process, as the build's was. Keywords
and symbols are written as text and interned again, natives as the
Var step 2 installed them in.

The loader makes each closure before the routine it runs is read, so
it verifies the routines (`Routine.verifyAlone`, `docs/VM.md` §5)
once the image is whole: in debug and safe builds every routine, each
member of an arity table proving the table's shape, and
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
boot instead. A struct the image writes field by field (a routine and
its capture descriptors, tries, spans and arity table; a Var; a
namespace; a closure, a cell, an atom and a record; a record type; a
protocol and
its methods) gaining a field fails to compile until `image.zig`
carries it, and the writer fails the build on a value it
cannot carry: a kind outside the image's set (strings, bignums,
regexes, vectors, lists of cons cells, hash maps and sets, closures,
cells, atoms, records, protocols and their functions), a list view, a
Var inside a `binding`.

| Namespace | Natives (`src/stdlib.zig`) | nexis source | Contract |
|---|---|---|---|
| `nexis.core` | `core_natives` | `core.nx` | text §2, printing §5, I/O §6, the rest of Clojure's core §8; `=` and `hash` SEMANTICS.md; `compare`, sorted collections, `subseq` and `rseq` SORTED.md; atoms ATOM.md; transients TRANSIENT.md; typed vectors TYPED_VECTOR.md §7.1; records and protocols PROTOCOLS.md; hierarchies and multimethods §9; the host macros MACROEXPAND.md §10 |
| `db` | `db_natives` | (`with-tx`, `with-read-tx`, `with-snapshot` in `core.nx`) | DB.md §12 |
| `nextomic` | `src/nextomic/natives.zig` | `nextomic.nx` (`with-conn`) | NEXTOMIC.md |
| `nexis.string` | `string_natives` | `string.nx` | §3 |
| `nexis.set` | — | `set.nx` | §4 |
| `nexis.walk` | — | `walk.nx` | §4 |
| `nexis.edn` | — | `edn.nx` | §4 |
| `nexis.math` | `math_natives` | `math.nx` (`PI`, `E`, `floor-div`, `floor-mod`) | TOOLING.md §4 |
| `nexis.sys` | (`#%getenv`, `#%cwd` in `internal_natives`) | `sys.nx` | §11 |
| `nexis.shell` | (`#%sh` in `internal_natives`) | `shell.nx` | §11 |
| `nexis.time` | (`#%now-ms`, `#%format-instant`, `#%parse-instant` in `internal_natives`) | `time.nx` | §12 |
| `nexis.json` | (`#%json-read`, `#%json-write` in `internal_natives`) | `json.nx` | §13 |
| `nexis.test` | — | `test.nx` | TOOLING.md §3 |
| `nexis.pprint` | — | `pprint.nx` | TOOLING.md §4 |
| `nexis.simd` | `simd_natives` | — | TYPED_VECTOR.md §7.2 |
| `nexis.internal` | `internal_natives` | — | the `#%` helpers macros emit: records and protocols (PROTOCOLS.md §7), `#%catch-matches?` (`try`), `#%raise` (the library's own error, `(#%raise :tag "sentence, got" x)`: the error map of `docs/VM.md` §13, its message naming the kind of `x`), `#%kwargs` (`& {:keys ...}`), `#%current-ns` (TOOLING.md §3), `#%delay` (`delay`, §8), `#%sorted-map` / `#%sorted-set` (a sorted collection a macro returns, MACROEXPAND.md §5), `#%push-out` / `#%pop-out` (`with-out-str`, §6), `#%mm-lookup` (a multimethod's call, §9.3), and the natives the namespaces of §11–§13 call |

**Resolution.** Every other namespace has `nexis.core` as its parent,
so an unqualified symbol a namespace does not define resolves in
`nexis.core`. The other namespaces are reached qualified with no
`require` (`(nexis.string/join "," xs)`), or through an alias
(`(require '[nexis.string :as s])`); a bare `join` is
`UnresolvedSymbol`. `volatile!`, `volatile?`, `vreset!` and `vswap!`
are defined in `core.nx` as the atom operations: one isolate, one
thread.

**Clojure's names.** The loader (`clojure_names` in
`src/loader.zig`) accepts nine Clojure library namespaces:
`clojure.string` → `nexis.string`, `clojure.set` → `nexis.set`,
`clojure.test` → `nexis.test`, `clojure.pprint` → `nexis.pprint`,
`clojure.walk` → `nexis.walk`, `clojure.edn` → `nexis.edn`,
`clojure.math` → `nexis.math`, `clojure.java.shell` → `nexis.shell`
(§11) and `clojure.data.json` → `nexis.json` (§13).
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
  namespace, unless the expansion calls it through its Var, as `doc`
  calls `(#'nexis.core/doc-of ...)`.

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
| `seq` and the sequence library | — | A string is a seq of its chars (`(seq "hé")` is `(\h \é)`, `(seq "")` nil), so `first`, `map`, `into`, `reverse`, `frequencies` and the rest take one. `(empty "abc")` is nil. A string is not callable (`:not-callable`) | — |
| `char` | 1 | The char with a code point; a char is itself | `:kind-mismatch` (non-integer), `:invalid-argument` (not a Unicode scalar: negative, past `0x10FFFF`, a surrogate) |
| `char?` | 1 | Whether the argument is a char | — |
| `int`, `short`, `byte`, `long` | 1 | Of a char: its code point (`(int \é)` is 233); of a number, its integer part (SEMANTICS.md §2.2). `long` takes any size (`(long 1e30)` is a bignum); `int`, `short` and `byte` only the range of Java's type, checked on the integer part as Clojure's boxed cast checks it (`(byte 127.5)` is 127), and make NaN 0 | `:kind-mismatch`, `:invalid-argument` (out of range; an infinity) |
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
| `escape` | 2 | `(escape s cmap)`: `s` with each character that `cmap` maps to a truthy value replaced by that value's text (`str`), every other character kept, one mapped to `false` too: `(escape "a<b" {\< "&lt;"})` is `"a&lt;b"`, `(escape "ab" {\a false})` `"ab"`. Clojure's code tests truth with `if-let`, though its docstring says non-nil (`string.nx`) |
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
| `difference` | 1+ | The first set without the elements of the others, as Clojure's: of each pair the smaller set is walked, the first's elements tested against the second's when it has fewer; the first must be a set (`disj`), else `:kind-mismatch` |
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
`(read-string s)` is `nexis.core`'s `read-string` with `{:eof nil}`,
so a string with no form is nil; `(read-string opts s)` passes `opts`
as they are, so with no `:eof` in them a string with no form is
`:reader-error`, as in Clojure; either is nil for a nil `s`. Nothing is
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
| float | SEMANTICS.md §6.3, in both modes (`str` and `%s` of a bare float write Java's `NaN`, `Infinity`, `-Infinity`) |
| char, string | display: a char's UTF-8, a string's bytes. readable: SEMANTICS.md §6.4, §6.5 |
| keyword, symbol | `:ns/name`, `ns/name`; names are not escaped |
| list, vector, set | `(a b)`, `[a b]`, `#{a b}`, elements separated by one space; a sorted set in its order |
| lazy seq | as a list, `(a b)`, `()` when empty. The printer runs no code: every caller but an error report realizes the value first, and a block whose body has not run prints as `...`, as does a cell of a realized cycle met again (`docs/LAZY.md` §8) |
| map | `{k v, k v}`, entries separated by `, `; a sorted map in its order |
| record | `#ns.Type{:k v, ...}` (the fields in the record's mode), or `#<record type-id=N>` when the interner has no name for the type; `(reduced x)` is the record `#nexis.core.Reduced{:val x}` |
| typed vector | `#i64[1 2]`, `#f64[1.5]` |
| function, native fn | `#<fn>`, `#<native-fn NAME>` (`NAME` is `ns/name` outside `nexis.core`: `#<native-fn nexis.string/join>`) |
| var | `#'ns/name`, as Clojure prints one (`#'nexis.core/inc`, `#'user/x`) |
| atom, transient | `#<atom>`, `#<transient>` |
| regex | `#"source"`, with Clojure's escaping of `"` (`docs/REGEX.md` §8); `str` and `%s` of a bare pattern write its source, as `Pattern.toString` does |
| matcher | `#<matcher #"source">` |
| protocol, protocol fn | `#<protocol id=N>`, `#<protocol-fn NAME>` (`NAME` the method's: `(defprotocol P (area [x]))` makes `#<protocol-fn area>`) |
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

`test/integration/eval_pipeline.zig` pins this document end to end,
`src/format.zig` the printer kind by kind, `test/golden/cli/` what
needs `bin/nexis` (`read-line`, `*command-line-args*`, `exit`).

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
| `replace` | 1–2 | `(replace smap coll)`: each element that `smap` (a map, or a vector by index) has as a key replaced by its value; a vector of a vector, keeping its metadata, else a lazy seq |
| `partitionv`, `partitionv-all` | 2–4, 1–3 | `partition` and `partition-all` with each part a vector |
| `splitv-at` | 2 | `[(vec (take n coll)) (drop n coll)]` |
| `bounded-count` | 2 | `(count coll)` of a counted collection, else the count of at most the first `n` elements (`(bounded-count 2 "abcd")` is 2) |
| `random-sample` | 1–2 | `(random-sample prob coll)`: each element kept with probability `prob` (`rand`) |
| `lazy-seq` | macro | `(lazy-seq body...)`: a lazy seq whose body runs once, when the seq is first walked, its result cached; a body that throws ends the seq there on the next walk (`docs/LAZY.md` §4) |
| `chunked-seq?`, `chunk-first`, `chunk-rest`, `chunk-next`, `chunk-buffer`, `chunk-append`, `chunk`, `chunk-cons` | 1, 1, 1, 1, 1, 2, 1, 2 | Clojure's chunk functions, for library code (`docs/LAZY.md` §7): `chunked-seq?` is true of a chunked cons and of a vector's view; a chunk is a vector, `chunk-buffer` a transient vector, `chunk-append` `conj!`, `chunk` `persistent!`; `chunk-cons` copies the vector into a chunked cons in front of the rest, or is the rest itself when the chunk is empty |
| `transduce`, `completing`, `cat`, `halt-when`, `eduction` | 3–4, 1–2, 1, 1–2, 1+ | Clojure 1.12's transducers (`docs/LAZY.md` §10), as are `into`'s 3-arity, `sequence`'s 2-arity and the transducer arities of `map`, `filter`, `remove`, `keep`, `take`, `take-while`, `drop`, `drop-while`, `map-indexed`, `keep-indexed`, `partition-all`, `partition-by`, `partitionv-all`, `mapcat`, `interpose`, `take-nth`, `replace`, `random-sample`, `distinct` and `dedupe` |
| `lazy-cat` | macro | `(lazy-cat coll...)`: `(concat (lazy-seq coll) ...)`, each coll's expression evaluated when the walk reaches it |
| `iterate`, `repeat`, `repeatedly`, `cycle` | 2, 1–2, 1–2, 1 | Lazy and, without a count, infinite (`docs/LAZY.md` §7): `(take 5 (iterate inc 0))`; `(iterate f x n)` is `:arity-mismatch`; `repeat`'s count is truncated, as Clojure's `(long n)`, and every other sequence function's rounds up (`docs/LAZY.md` §9) |
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
| `class?` | 1 | Whether `x` is a type `class` returns: a kind keyword (`:boolean`, `:vector`, `:map`, `:set`, or a kind name `class` passes through, such as `:fixnum`, `:sorted_map` or `:function`) or the symbol of a registered record type (`user.P`); false of any other keyword (`:persistent_vector`, `:frob`), symbol or value. The global hierarchy takes these as tags without a namespace (§9.1) |
| `type` | 1 | `(or (:type (meta x)) (class x))`, as Clojure's |
| `make-multifn`, `multifn?`, `add-method` | 4, 1, 3 | The multimethod constructor, predicate and method setter `defmulti` and `defmethod` expand to: nexis's names for Clojure's `new MultiFn`, `instance? MultiFn` and `.addMethod` (§9.2) |
| `instance?` | 2 | `(instance? t x)`: whether `(class x)` is `t`, a keyword or symbol (`(instance? :vector [])`, `(instance? 'user.P p)`); there is no hierarchy, so `(instance? :map p)` of a record is false. Any other `t` is `:kind-mismatch` |
| `var?` | 1 | Whether `x` is a Var |
| `var-get` | 1 | The value of the Var (`deref`); a non-Var is `:kind-mismatch` |
| `find-var` | 1 | `(find-var 'ns/name)`: the Var the qualified symbol names, nil when the namespace has none; `:no-such-namespace` when there is no such namespace |
| `load-string`, `load-file` | 1 | Read each form of the string (of the file's text) in turn and compile and run it in the current namespace, so a form that does not read (a stray closing delimiter, an unfinished form) raises `:reader-error` after the ones before it ran; the namespace in force when it was called is restored afterwards, whether it returns or throws, as Clojure's `Compiler.load` binds `*ns*`; the last form's value, nil for none. Each form is compiled as read, as a file's form is (`CompilerHooks.load`, `docs/VM.md` §9.1), never made a value first, so a syntax-quote in the text loads; a form that does not compile throws as `eval`'s does, its `:form` nil when it has no value form |
| `array-map` | 0+ | `(apply hash-map kvs)`: a map of up to eight entries keeps its insertion order (§5), all that Clojure's array map promises; a larger one is a hash map, as Clojure's becomes one past eight |
| `bigint`, `biginteger` | 1 | `long`: one integer domain (BIGNUM.md), so a number truncated to an integer of any size |
| `decimal?` | 1 | false: there are no decimals (PLAN §4) |
| `Inst`, `inst-ms*` | protocol | Clojure's `Inst`: an instant is a value of a type extended to it, whose `inst-ms*` is its epoch milliseconds. `nexis.time`'s `Instant` extends it (§12), and so may any record |
| `inst?`, `inst-ms` | 1 | `(satisfies? Inst x)`; `(inst-ms* inst)`, `:no-protocol-impl` for anything else (an integer included: `nexis.time/inst-ms` takes one too) |
| `qualified-ident?`, `simple-ident?` | 1 | Whether `x` is a keyword or symbol with a namespace, without one |
| `bit-and-not`, `bit-flip` | 2+, 2 | `(bit-and x (bit-not y))` over each further argument; `bit-flip` is `bit-set` or `bit-clear` of the bit, as `bit-test` finds it |
| `alter-var-root` | 2+ | `(alter-var-root v f & args)`: sets the root of the Var `v` to `(apply f root args)` and returns it; a `binding` in force is left as it is. An unbound Var's root is nil to `f` and bound after (Clojure passes its `Unbound` object). A non-Var is `:kind-mismatch` |
| `with-redefs-fn`, `with-redefs` | 2, macro | `(with-redefs-fn {#'v val ...} f)` calls `f` with each Var's root set to its value; `(with-redefs [name val ...] body...)` does it for the body, the names resolved as `var` resolves them. Root writes, not bindings, so every caller sees them and a Var need not be dynamic; each root is restored on every exit, a throw included, and a Var that was unbound is unbound again (`nexis.internal/#%unbind-root`), as Clojure restores its `Unbound` root. A call the compiler inlines (the arithmetic and comparison functions and `not`, COMPILER.md) does not go through the Var |
| `*ns*` | Var | The namespace a form is compiled in, as its name symbol: the compiler sets the root before it expands each top-level form, and `in-ns` when it switches, so `(ns-name *ns*)` in a file or a macro names the file's namespace. Dynamic, but a `binding` of it does not change where forms compile |
| `ex-info`, `ex-data`, `ex-message`, `ex-cause` | 2–3, 1, 1, 1 | `(ex-info msg data cause?)` is the map `{:message msg :data data}` (`:cause` with a third argument), `msg` a string or nil and `data` a map, nil meaning `{}`, else `:kind-mismatch`. `ex-message` is a map's `:message`; `ex-data` an `ex-info` map's `:data`, and an error map (one with an `:error` and no `:data`: a caught runtime error, a Nextomic error) is its own data, so `(:error (ex-data e))` is the tag of either; `ex-cause` a map's `:cause`; each nil for anything else (`docs/VM.md` §13) |
| `special-symbol?` | 1 | Whether `s` is a name the compiler takes as a special form: `def if do let* fn* loop* letfn* quote var recur try catch finally throw set! &` |
| `find-ns`, `the-ns`, `ns-name` | 1 | A namespace is its name symbol: `find-ns` returns the symbol when a namespace has that name, else nil; `the-ns` and `ns-name` return it, else throw `:no-such-namespace`. A non-symbol is `:kind-mismatch` |
| `all-ns` | 0 | Every namespace's name, sorted |
| `ns-interns`, `ns-publics` | 1 | The map of name symbol to Var of every Var interned in the namespace (the ones it refers to from another excluded), an unbound one a `declare` or a forward reference made included; `ns-publics` leaves out those marked `:private`. `clojure.string` and its kin hold `nexis.string`'s Vars, so ask the `nexis.*` namespace |
| `resolve`, `ns-resolve` | 1, 2 | `(resolve sym)`, `(ns-resolve ns sym)`: the Var `sym` names in the current namespace or `ns`, resolved as the compiler resolves a global (an unqualified name the namespace's own or referred, then `nexis.core`'s; a qualified one through an alias or a namespace name), else nil. A host macro (`when`, `let`, `defn`, ...) has no Var, so it resolves to nil |
| `random-uuid` | 0 | A random version-4 UUID. A UUID is its canonical lowercase text, a string, as Nextomic's `:db.type/uuid` values are; there is no `#uuid` literal |
| `parse-uuid` | 1 | The canonical text of the UUID a string spells as 8-4-4-4-12 hex digits of either case, else nil (Java's lenient short groups included); a non-string is `:kind-mismatch` |
| `uuid?` | 1 | Whether `x` is a string in the canonical form (so `(uuid? (random-uuid))` is true, and an uppercase spelling is not) |
| `re-pattern`, `re-matcher`, `re-find`, `re-matches`, `re-groups`, `re-seq` | 1, 2, 1–2, 2, 1, 2 | Clojure's regular expressions, over the linear-time engine of `docs/REGEX.md`, which owns their rows (§9 there): `(re-find #"\d+" "ab12")` is `"12"`, `(re-seq #"(\w)=(\d)" "a=1 b=2")` is `(["a=1" "a" "1"] ["b=2" "b" "2"])`, lazy |

---

### 9. Multimethods and hierarchies

Clojure 1.12's hierarchies and multimethods, in `core.nx` (the
"Hierarchies and multimethods" section): `core.clj` from `defmulti`
through `prefers` and from `make-hierarchy` through `underive`, and
the dispatch of `MultiFn.java`, ported. The dispatch function and the
method are ordinary calls, so a recursive multimethod is as deep as a
recursive `defn`; the one native on the way, `#%mm-lookup`, reads the
cache and calls nothing back, so nothing needs rooting.

#### 9.1 Hierarchies

A hierarchy is the map `{:parents {} :descendants {} :ancestors {}}`:
each tag's set of direct parents, and the transitive closures of its
ancestors and of its descendants, which `derive` and `underive` keep.
It is a plain map, so it compares, prints and serializes as one. The
global hierarchy is the private Var `nexis.core/global-hierarchy`,
as Clojure's: the arities without a hierarchy read its root, and
`derive` and `underive` change it with `alter-var-root`, so
`(with-redefs [nexis.core/global-hierarchy (make-hierarchy)] ...)`
and `@#'nexis.core/global-hierarchy` reach it as Clojure's tests do.

| Name | Arity | Semantics |
|---|---|---|
| `make-hierarchy` | 0 | The empty hierarchy |
| `isa?` | 2, 3 | `(isa? h child parent)`: true when `(= child parent)`, when `parent` is among `child`'s ancestors in `h`, or when both are vectors of one count whose elements are `isa?` pairwise (`(isa? h [:user/a :user/b] [:user/p :user/q])`; `(isa? [] [])` is true). A non-hierarchy `h` gives false where Clojure's call of `(:ancestors h)` throws |
| `parents`, `ancestors`, `descendants` | 1, 2 | The tag's set of direct parents, of ancestors, of descendants; nil when it has none |
| `derive` | 2, 3 | `(derive h tag parent)`: `h` with `tag` a child of `parent`, the closures updated as Clojure's do; `h` itself (`identical?`) when the edge exists. `tag` and `parent` must differ and both be keywords or symbols, else `:assertion-failed` with the text of Clojure's assertion (`"Assert failed: (not= tag parent)"`). An edge whose parent is already an ancestor of the tag is `{:error :invalid-derivation :message "T already has P as ancestor"}`, one that would make a cycle `"Cyclic derivation: P has T as ancestor"`, the tags printed by `print-str`. `(derive tag parent)` changes the global hierarchy and returns nil; there `parent` must have a namespace and so must the tag unless it is a class (`class?`), else `:assertion-failed`, and `namespace` of a non-ident is `:kind-mismatch`, as Clojure's cast fails |
| `underive` | 2, 3 | `(underive h tag parent)`: `h` without the edge, rebuilt by deriving every remaining edge into an empty hierarchy, as Clojure's; `h` itself when there is no such edge. The 2-arity changes the global hierarchy and returns nil |

**Classes as tags.** Clojure's global hierarchy takes a Java class as
a tag without a namespace (`(derive String ::text)`); the nexis
equivalent of a class is what `class` returns (§8), so `class?` holds
of those: `(derive :vector :user/coll)` and, after `(defrecord Circle
[r])`, `(derive Circle :user/shape)` make `(isa? (class x) :user/coll)`
and `(isa? (class (->Circle 1)) :user/shape)` true, and
`(defmulti area class)` dispatches through them. A record type is its
symbol, so a redefined record keeps its derivations, where Clojure's
redefinition makes a new class.

There is no supertype relation between kinds: `isa?`, `parents` and
`ancestors` follow only the edges `derive` made, where Clojure's also
walk Java's superclasses and interfaces, and `descendants` of any tag
reads the hierarchy, where Clojure's throws for a class.

#### 9.2 Multimethods

| Name | Arity | Semantics |
|---|---|---|
| `defmulti` | macro | `(defmulti name docstring? attr-map? dispatch-fn & options)`. The options are `:default`, the dispatch value of the fallback method (`:default`), and `:hierarchy`, a Var or atom the hierarchy is read through (`#'nexis.core/global-hierarchy`; anything else is `:kind-mismatch`). Expands to `(let [v (def name)] (when-not (and (bound? v) (multifn? @v)) (def name (make-multifn "name" dispatch-fn default hierarchy))))`, then merges the docstring and attr-map into the Var's metadata: the Var the first time, nil when `name` already holds a multimethod, which is left as it is, dispatch function, options and methods. `(def name nil)` first makes `defmulti` define it again. One option without its value fails the expansion with "The syntax for defmulti has changed. Example: (defmulti name dispatch-fn :default dispatch-value)", an option other than the two with "Only these options are valid: :default, :hierarchy" |
| `defmethod` | macro | `(defmethod mf dispatch-val & fn-tail)` → `(add-method mf dispatch-val (fn fn-tail...))`, so a named or multi-arity method works; returns `mf` |
| `make-multifn` | 4 | `(make-multifn name dispatch-fn default href)`: a multimethod named by the string `name` |
| `multifn?` | 1 | Whether `x` is a multimethod |
| `add-method` | 3 | Sets the method for a dispatch value; returns the multimethod |
| `remove-method` | 2 | Removes the method for a dispatch value; returns the multimethod |
| `remove-all-methods` | 1 | Empties the method table and the prefer table; returns the multimethod |
| `prefer-method` | 3 | `(prefer-method mf x y)`: where `x` and `y` both match, `x` wins. Returns the multimethod; `{:error :preference-conflict :message "Preference conflict in multimethod 'f': Y is already preferred to X"}` when `y` is already preferred to `x`, directly or through the parents of either |
| `methods` | 1 | The method table, dispatch value to method, `:default`'s included |
| `prefers` | 1 | The prefer table, `{x #{y ...}}` |
| `get-method` | 2 | The method a call with that dispatch value would run, nil when none would; an ambiguity throws as the call would |

`methods`, `get-method` and the rest of a non-multimethod are
`:kind-mismatch`.

A multimethod is a closure (`fn?` and `ifn?` are true, `class` is
`:function`, it prints `#<fn>`), which a private registry in `core.nx`
maps by identity to its state: its name, default dispatch value,
hierarchy reference, method table and prefer table, and its cache. A
function's `=` and `hash` are its identity, the collector never moves
it, and so the closure is its own key. `=`, `hash`, its use as a map
key, `meta` (nil) and `with-meta` (`:kind-mismatch`) agree with
Clojure's `MultiFn`; it is unserializable, as any function is.

#### 9.3 Dispatch and the cache

A call applies the dispatch function to the arguments, of any number,
and the method for the dispatch value to the same arguments. The
method is found as `MultiFn.getMethod` finds it:

1. The cache, a map from dispatch value to method, holds the value:
   its method. `nexis.internal/#%mm-lookup` reads it in one call: the
   cache and the hierarchy reference dereferenced, the hierarchy the
   cache was built against compared by identity, the value looked up. The cache starts as the method table itself, so an
   exact key always wins, even over a preference for one of its
   ancestors.
2. Else the best entry: of the table's entries whose key the dispatch
   value `isa?` in the hierarchy, the one that dominates every other.
   `x` dominates `y` when `x` is preferred to `y` (through the prefer
   table, directly or through the parents of either) or `(isa? x y)`.
   Two matches neither of which dominates the other are ambiguous.
3. Else the method under the default dispatch value; with
   `:default :user/dflt`, a method under `:default` is an ordinary
   entry, not the fallback.
4. Else there is none.

A method found by the search is cached under the dispatch value when
the method table, the prefer table and the hierarchy are each still
the values the search read; otherwise the cache is reset and the
search runs again, as `MultiFn` re-checks its basis. Every
`add-method`, `remove-method`, `prefer-method` and
`remove-all-methods` resets the cache to the table, and a call whose
hierarchy is no longer the identical value the cache was built
against resets it first: every `derive` or `underive` that changes a
hierarchy makes a new map, so the next call sees it, and one that
changes nothing returns the same map and invalidates nothing. The
cache grows by one entry per distinct dispatch value that resolves,
as Clojure's does. `isa?` and `parents` are called through their
Vars, as `MultiFn` calls `clojure.core/isa?`.

#### 9.4 Errors, the registry and the image

| Situation | Error map | `catch` class |
|---|---|---|
| No method | `{:error :no-method :message "No method in multimethod 'f' for dispatch value: X" :value dv}` | `IllegalArgumentException` |
| An ambiguity | `{:error :ambiguous-method :message "Multiple methods in multimethod 'f' match dispatch value: X -> K and B, and neither is preferred" :value dv}` | `IllegalArgumentException` |
| A preference conflict | `{:error :preference-conflict :message ...}` | `IllegalStateException` |
| A cycle, or an edge to an ancestor (§9.1) | `{:error :invalid-derivation :message ...}` | any |
| A `derive` assertion (§9.1) | `{:error :assertion-failed :message "Assert failed: ..."}` | `AssertionError` |

Each is raised through `#%raise`, so a caught one carries the place
keys of the program's call, as a runtime error does (`docs/VM.md` §13).

Each value is printed into its message by `format`'s `%s`: a string
bare, a keyword or vector as `pr-str` prints it, nil as `nil` where
Clojure prints `null`. In the ambiguity message `K` is the later
entry in the method table's order and `B` the best before it; the
table iterates in insertion order up to eight entries and in CHAMP
order past them, where Clojure's iterates in its hash order, so the
two can be named the other way round.

The registry keeps every multimethod for the VM's life, as the record
type and protocol registries keep theirs; re-evaluating a file keeps
each multimethod (`defmulti` defines once) and replaces its methods,
Clojure's reload story. The stdlib image carries the registry, an
empty map, and the global hierarchy. The stdlib defines no
multimethod: the registry's keys hash by address, so past eight
entries the image's rebuilt map would iterate in another order and
`image.verify` would fail the build.


---

### 10. Documentation

`doc`, `find-doc`, `apropos`, `dir` and `dir-fn` are Clojure's
`clojure.repl` functions, in `nexis.core` (`core.nx`), so a program
and the REPL both have them with no `require`. They read
documentation from four places:

- **A Var's metadata.** `defn`, `defmacro` and `def` put a docstring
  in `:doc` and the parameter vectors in `:arglists`
  (MACROEXPAND.md §10). The library's own functions and macros are
  written this way, but once the embedded sources have booted their
  docstrings move out of the metadata into one string, the root of
  `nexis.internal/#%docs` (`ns/name`, a NUL, the docstring, a NUL, for
  each), which the stdlib image carries: loading one string costs the
  boot less than a string and a map entry per Var. When `meta` reads a
  Var of a library namespace whose map has no `:doc`, it finds the
  Var's docstring there, adds it under `:doc` and keeps it.
- **A native's table row** (`src/stdlib.zig`). Each row ends with two
  strings, the arglists as `doc` prints them (`"[coll] [n coll]"`)
  and the docstring; Nextomic's natives, whose descriptors live in
  `src/nextomic/`, have theirs in `nextomic_docs`, keyed by the
  descriptor's name. The text is in the binary, not the image: the
  Var a native was installed in takes `{:arglists (...) :doc "..."
  :name name :ns ns}` as its metadata the first time `meta` reads a
  Var with none, the arglists read by the reader, and keeps it. Another
  Var holding the native, `(def f first)`, takes nothing.
- **The special forms and host macros**, which have no Var
  (MACROEXPAND.md §2b, §10): `(nexis.internal/#%special-docs)` builds
  a doc map for each from `special_docs`: `{:name if :forms [(if test
  then else?)] :doc "..." :special-form true}`, or for a host macro
  `{:ns nexis.core :name defn :arglists (...) :doc "..." :macro true}`.
- **The library namespaces**, whose `ns` docstrings are not kept:
  `(nexis.internal/#%namespace-doc 'nexis.string)` is the text from
  `namespace_docs`, nil for another namespace.

| Name | Arity | Behaviour |
|---|---|---|
| `doc` | macro | `(doc name)` prints the documentation of what `name` names, looked up in this order: a special form or host macro (`&` is `fn`'s, `catch` and `finally` are `try`'s; `nexis.core/defn` is `defn`), a namespace, then the Var `resolve` finds. Clojure's layout: a line of 25 dashes, the qualified name, each of a special form's forms after two spaces, the arglists as `prn` prints them, `Special Form` or `Macro`, then two spaces and the docstring as written (its own lines indented by its author, two spaces by convention). Prints nothing for a name that names nothing; nil |
| `find-doc` | 1 | `(find-doc re-string-or-pattern)` prints, as `doc` does, every Var of every namespace (`ns-interns`, sorted by name within each), then every library namespace, then every special form and host macro, whose docstring or name `re-find` matches; nil |
| `apropos` | 1 | `(apropos str-or-pattern)` → the sorted qualified symbols of every public Var outside `nexis.internal`, and of every host macro as `nexis.core/name`, whose name contains the string or has a match for the regex |
| `dir-fn` | 1 | `(dir-fn ns)` → the sorted symbols naming the public Vars of the namespace the symbol `ns` names, or that an alias of the current namespace names; for `nexis.core` the host macros as well. `:no-such-namespace` when it names none |
| `dir` | macro | `(dir ns)` prints `(dir-fn 'ns)` one name per line; nil |

Every public Var of the library namespaces but `nexis.internal`
carries a docstring, and every one holding a function its arglists
(`test/integration/eval_pipeline.zig` walks them all); a native's
arglists agree with the arities its row declares (an inline test in
`src/stdlib.zig`). A docstring says what nexis does where that differs
from Clojure; `docs/GUIDE.md` is the user's account of the
differences. `nexis doc NAME` prints `(doc NAME)` from the command
line (`TOOLING.md` §1).

Clojure's `source` has no counterpart: a Var does not record the
file and line it came from.

---

### 11. The process: `nexis.sys` and `nexis.shell`

`src/stdlib/sys.nx` holds the process's environment and working
directory, `src/stdlib/shell.nx` Clojure's `clojure.java.shell`, each
function a docstring'd `defn` over a native in `internal_natives`.
`exit` and `*command-line-args*` are `nexis.core`'s (§6): `nexis run`
and `nexis -e` both bind the arguments after the program. Text the operating system hands over is
any bytes; each byte that starts no well-formed UTF-8 sequence reads
as U+FFFD, as Java decodes it.

| Name | Arity | Semantics | Errors |
|---|---|---|---|
| `getenv` | 0–1 | `(getenv name)`: the value of the environment variable as a string, nil when it is not set (an empty name, or one holding a NUL byte, is never set); `(getenv)`: every variable as a map of name to value, Clojure's `(System/getenv)`. libc's environment, which nexis never changes | `:kind-mismatch` (a name that is not a string) |
| `cwd` | 0 | The absolute path of the working directory, Java's `(System/getProperty "user.dir")` | `:io-error` |
| `sh` | 1+ | `(sh "ls" "-l" :dir "/tmp")`: runs a program and waits for it, returning `{:exit status :out text :err text}`. The leading strings are the program, found on the PATH (`/usr/local/bin:/bin:/usr/bin` when the process has none), and its arguments; keyword options follow. `:in` is text written to the program's stdin, which otherwise reads end of input at once; `:dir` its working directory, else `*sh-dir*`; `:env` a map that is the whole of its environment, each name by `name` and value by `str`, else `*sh-env*`; nil for any of them is the process's own. A signal's status is 128 plus its number, as Java reports it; output that is not UTF-8 reads as U+FFFD | `:invalid-argument` (no program; an option other than these, among them Clojure's `:in-enc` and `:out-enc`; a NUL byte in an argument; a name no variable can have), `:kind-mismatch` (a non-string `:in`, a non-map `:env`), `:arity-mismatch` (an option without its value), `:file-not-found` (no such program, or no such `:dir`), `:io-error` (any other failure to run it; a VM with no `io`) |
| `*sh-dir*`, `*sh-env*` | Var | Dynamic, nil at the root: the `:dir` and `:env` of a `sh` that gives none | — |
| `with-sh-dir`, `with-sh-env` | macro | `(with-sh-dir dir body...)`: the body with `*sh-dir*` bound to `dir`; `with-sh-env` the same for `*sh-env*` | — |

One thread runs a program's three streams together: it writes `:in`
to the stdin pipe and drains stdout and stderr through one `std.Io`
batch (`std.Io.Batch.awaitConcurrent`, a `poll` on POSIX), each
write at most the 512 bytes POSIX lets a pipe that polls writable take
at once, so neither side waits on a full pipe whatever the sizes. A
program that closes its stdin early leaves the rest of `:in`
unwritten, as Java's does. The program inherits nothing else: no
terminal, no open file but the three pipes.

`test/integration/eval_pipeline.zig` pins every row, a variable and
output holding bytes that are not UTF-8 and a `:in` past any pipe's
buffer included; `sh` runs there with the test's `std.Io`.

---

### 12. Instants: `nexis.time`

`src/stdlib/time.nx` holds instants, their ISO-8601 text and
durations, each function a docstring'd `defn`; three natives in
`internal_natives` read the clock and convert the text.

**The representation.** An instant is the record
`nexis.time.Instant` of one field, `:ms`, the milliseconds since
1970-01-01T00:00:00Z on the proleptic Gregorian calendar, UTC, with no
leap seconds: Java's `Instant` to the millisecond, the precision of
Clojure's `#inst` and of Nextomic's `:db.type/instant`. A record needs
no new value kind (PLAN §23): it is `=` and hashes by its `:ms`,
`(:ms i)` reads it, and it prints as `#nexis.time.Instant{:ms
1791549015123}`. It is not `compare`-able, as records are not
(`docs/SORTED.md` §6): sort instants with `(sort-by t/inst-ms xs)`.
It extends `nexis.core`'s `Inst` protocol, so Clojure's `inst?` and
`inst-ms` take it (§8). There is no `#inst` literal (PLAN §4;
`TODO.md` #22 has the design note). The range is
the fixnum's, ±2^47 ms: -2490-03-17 to 6429-10-17.

**Nextomic.** A `:db.type/instant` value, `:db/txInstant` included, is
epoch milliseconds, a long (`docs/NEXTOMIC.md` §2), and every function
here that takes an instant takes such a long as well: `(t/format
(:db/txInstant tx))` writes one, `(t/instant ms)` makes it an Instant,
and `(t/inst-ms i)` is what a transaction asserts.

| Name | Arity | Semantics | Errors |
|---|---|---|---|
| `now` | 0 | The wall clock (`CLOCK_REALTIME`) as an Instant, to the millisecond | — |
| `instant` | 1 | An Instant of epoch milliseconds (an integer), of ISO-8601 text as `parse` reads it, or of an Instant (itself) | `:kind-mismatch`, as `parse` |
| `inst?` | 1 | Whether `x` is an Instant | — |
| `inst-ms` | 1 | The epoch milliseconds of an instant: an Instant's `:ms`, an integer itself (Clojure's `inst-ms`) | `:kind-mismatch` |
| `parse` | 1 | The Instant ISO-8601 text names, in the grammar of Clojure's `#inst`, which RFC 3339's is a part of: `YYYY` (with an optional sign), then optionally `-MM`, `-DD`, `THH:MM`, `:SS` and a fraction of 1 to 9 digits, each only after the one before, truncated to the millisecond; then `Z`, an offset `+HH:MM` or `+HHMM`, or nothing, which is UTC. `T` and `Z` may be lower case. A field out of its range (month 13, February 29 of a common year, hour 24, second 60) is not an instant | `:kind-mismatch` (not a string), `:invalid-argument` (any other text; an instant past the range) |
| `format` | 1 | The instant's ISO-8601 text in UTC as Java's `Instant.toString` writes it: `2026-10-09T12:30:15.123Z`, the fraction left out when it is zero, a year before 1 written with a `-` (`-0001-01-01T00:00:00Z`) | `:kind-mismatch` (not an instant, or past the range) |
| `seconds`, `minutes`, `hours`, `days` | 1 | A duration of `n` of the unit, in milliseconds: a duration is a number of milliseconds, a day 24 hours | — |
| `plus`, `minus` | 1+ | `(plus x d ...)`: the Instant each duration later (`minus`: earlier) than the instant `x`, `long` of the sum | `:kind-mismatch` |
| `between` | 2 | The duration from instant `a` to instant `b`, negative when `b` is earlier | `:kind-mismatch` |
| `before?`, `after?` | 2 | Whether instant `a` is earlier (later) than instant `b` | `:kind-mismatch` |

There are no time zones but UTC, no local dates, and no calendar
arithmetic (a month later); a program that needs them builds them on
`inst-ms`. `src/stdlib.zig` checks the calendar against
`std.time.epoch` and day by day over the whole range, and that every
instant's text reads back as the same instant;
`test/integration/eval_pipeline.zig` pins each row and a Nextomic
round trip.

---

### 13. JSON: `nexis.json`

`src/stdlib/json.nx` is JSON in the shape of `clojure.data.json`
(`read-str`, `write-str`, `read`, `write` and their options), each a
docstring'd `defn` over a native in `internal_natives`. Options are
keyword arguments or a trailing map (`(read-str s :key-fn keyword)`,
`(read-str s {:key-fn keyword})`); a key other than the ones a
function takes is `:invalid-argument`, where `clojure.data.json`
ignores it.

**Reading.** The text is RFC 8259 JSON, exactly: an object is a map,
a later duplicate key winning and one of up to eight members keeping
the text's order (§5); an array a vector; a string a string, every
escape decoded, a surrogate pair to its character; an integer a
fixnum, or a bignum past one, with no limit on its digits; a number
with a fraction or an exponent a double (`1e400` is `##Inf`, as Java
reads it); `true`, `false` and `null` themselves. Whitespace is space,
tab, CR and LF. Nothing else is JSON: a trailing comma, a comment,
`NaN`, a leading zero (`01` is `0` and text after it), a control
character unescaped in a string, a lone surrogate, text after the
value. The reader is a loop, not a recursion: each value waits on the
VM's root stack until the array or object it is in closes and is then
built into it, so the text nests as deep as memory allows, and every
value is rooted across the options' calls (GC.md §11.5).

**Writing.** A hash map, sorted map, record or Nextomic entity is an
object; a vector, list, seq (realized first), set or typed vector an
array; a string a string; a character a one-character string; a
keyword or symbol its whole name without the colon (`:person/name` is
`"person/name"`, where `clojure.data.json` writes `"name"`: a
Nextomic attribute keeps its namespace; `:key-fn name` gives
`clojure.data.json`'s keys); a `nexis.time.Instant` its ISO-8601 text
(§12); an integer its digits; a double Java's `Double.toString`
(`1.0E10`), a valid JSON number; `true`, `false` and nil `null`. A map
key is a string as it is, a keyword or symbol by its whole name, an
integer by its digits. A string is written as UTF-8 with `"`, `\` and
the control characters escaped (`\b`, `\f`, `\n`, `\r`, `\t`, else
`\u00XX`); `clojure.data.json` escapes every non-ASCII character and
`/` by default, this writer only when asked. The walk recurses on the
data's depth under the stack guard, so data nested past the native
stack is a catchable `:stack-overflow`.

| Name | Arity | Semantics |
|---|---|---|
| `read-str` | 1+ | `(read-str s & opts)`: the value of the JSON text `s`. `:key-fn`: a function of each key's string, its result the map key (`keyword` gives keyword keys, interned without a call: an empty key, which names no keyword, is `:invalid-argument`). `:value-fn`: a function of each object member's key (after `:key-fn`) and value, inner objects first, whose result replaces the value, or drops the member when it is `:value-fn` itself |
| `write-str` | 1+ | `(write-str x & opts)`: the JSON text of `x`, as above. `:key-fn`: a function of each map key to the string written; `:value-fn`: a function of each map entry's key and value whose result is written, the entry left out when it is `:value-fn` itself; `:indent true`: a newline before each member and element, two spaces a level, `": "` after a key, an empty collection kept as `{}` or `[]` (`clojure.data.json` 2.5's `:indent`); `:escape-unicode true`: every character past ASCII as `\uXXXX`, a pair past the BMP; `:escape-slash true`: `/` as `\/` |
| `read` | 1+ | `(read path & opts)`: `read-str` of the file's text (`slurp`); stdin is `(read "/dev/stdin")` |
| `write` | 2+ | `(write x path & opts)`: `write-str` of `x` into the file, replacing it (`spit`); nil |

**Errors.** Malformed text throws the map `{:error :json-error
:message "JSON: <what> at line L, column C" :line L :column C}` (as
the multimethod errors are maps, §9.4), the column counted in
characters, so `(catch :json-error e (ex-message e))` takes it; the
`<what>`s are `the text ends before its value`, `the text ends inside
a string` (an `object`, an `array`), `text follows the value`,
`unexpected 'c'`, `expected a string key`, `expected ':' after a
key`, `expected ',' or '}'` (`']'`), `a malformed number`, `a control
character in a string`, `an unknown escape`, `a lone surrogate`.
Writing what JSON cannot hold throws `{:error :json-error :message
...}` without a position: `NaN` or an infinity, a nil key, a key of
another class, a `:key-fn` result that is not a string, a value of any
other class (a function, an atom). A text that is not a string, or an
options map that is not a map, is `:kind-mismatch`; a string that is
not UTF-8 `:utf8-error`; a throw from an option's function passes
through.

`test/integration/eval_pipeline.zig` pins every value kind both ways,
the options, each error and its position, a round trip of every kind
JSON holds, files, and a text 200,000 arrays deep, which reads, and
writes as `:stack-overflow`.
