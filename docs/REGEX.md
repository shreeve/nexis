## REGEX.md — regular expressions

The regex engine (`src/regex.zig`): the syntax it accepts, how it
matches, the limits that bound it, its Unicode data, where its results
differ from `java.util.regex`, and the differential test against it.
Patterns are Java's syntax minus every construct that needs
backtracking; matching is linear in the input.

---

### 1. The engine

`compile(arena, source, flags)` parses a pattern into an AST in the
arena and lowers it to a `Program`: a flat array of 12-byte
instructions (`Op`, two `u32` operands) over code points, a table of
code-point ranges for the character classes, and the named groups.
It returns `.ok` with the program or `.err` with a sentence and the
byte offset in the source; a Zig error is only `OutOfMemory` or
`StackOverflow` (the parser and compiler call `stack.check()`,
`docs/VM.md` §13.1). The source must be UTF-8; anything else is the
error `the pattern is not valid UTF-8`.

`Vm` holds the scratch space of searches with one program: two thread
lists, a capture scratch array and an explicit stack, allocated once
(O(m·k) for m instructions and k slots) and reused by every search.
`Vm.init(gpa, prog, groups)` records every group when `groups` is
true, else only the span of the match, which is cheaper.
`exec(hay, from, last_end, whole)` finds the leftmost-first match
starting at or after `from`; `whole` asks for a match of all of
`hay[from..]` (Java's `Matcher.matches`). `group(g)` gives the byte
span of group `g` of the last match, or null for a group that did not
take part. `Finder` is Java's find loop over one input (§3.5).

The pipeline:

```
source ──parse──► AST (arena) ──compile──► Program ──► Pike VM
           │                       │
     SyntaxError              limits (§4)
```

Every class is resolved while parsing to a sorted, merged list of
code-point ranges: union, intersection, complement, case folding
(§5.1) and the general categories (§5.2) are all set algebra at
compile time, so the VM tests a code point against ranges and nothing
else.

---

### 2. Syntax

Java's (`java.util.regex.Pattern`), with its error sentences where
both accept the same input. Refused constructs are errors when the
pattern compiles, each with a sentence naming it.

| Construct | Meaning |
|---|---|
| `x`, `\\`, `\t \n \r \f \a \e` | the character |
| `\0n`, `\0nn`, `\0mnn` (m ≤ 3) | octal |
| `\xhh`, `\x{h...}` (≤ 10FFFF), `\uhhhh` | hexadecimal; a `\u` high surrogate followed by a `\u` low surrogate is one code point |
| `\cX` | the code point of X xor 64 |
| `\` before any non-letter, non-digit | that character; before any other ASCII letter not listed here, `Illegal/unsupported escape sequence` |
| `\Q...\E` | every character between is literal (rewritten before parsing, as Java does, so a quantifier after `\E` applies to the last quoted character); a stray `\E` is an error |
| `.` | any code point but a line terminator (§3.4); any with `(?s)`; any but `\n` with `(?d)` |
| `\d \D \s \S \w \W` | ASCII `[0-9]`, `[ \t\n\x0B\f\r]`, `[a-zA-Z_0-9]`, and their complements |
| `\h \H \v \V` | Java's horizontal and vertical whitespace lists, and their complements |
| `\R` | `\r\n` or one of `[\n\x0B\f\r\x85  ]` (§3.3) |
| `\p{Lower}` ... | the POSIX classes `Lower Upper ASCII Alpha Digit Alnum Punct Graph Print Blank Cntrl XDigit Space`, ASCII as Java's are; `all` |
| `\p{Lu}`, `\pL`, `\p{IsL}`, `\p{gc=Lu}`, `\p{general_category=Lu}` | a general category (§5.2): the two-letter ones, the one-letter groups `L M N Z C P S`, and `LC`, `LD`, `L1`; `\P{...}` is the complement |
| `[...]`, `[^...]` | a class: characters, ranges `a-z`, escapes, predefined classes, nested classes (union), `&&` (intersection); `^` negates the whole class |
| `^ $ \A \z \Z \b \B \G` | assertions (§3.4) |
| `X*  X+  X?  X{n}  X{n,}  X{n,m}` | greedy repetition; a trailing `?` makes it lazy |
| `(X)`, `(?<name>X)` | capturing group, numbered by its `(`; a name is an ASCII letter then letters and digits, unique |
| `(?:X)` | non-capturing group |
| `(?idmsux-idmsux)`, `(?idmsux-idmsux:X)` | flags (§2.1) for the rest of the enclosing group, or for X |
| `X\|Y` | alternation, X preferred |

Class details, all as in Java: `]` first in a class and `-` first or
last are literal; `[z-a]` and `[a-\d]` are `Illegal character range`;
`[[:alpha:]]` is the nested class of the characters `:alph`;
`[^a[b]]` negates the union; an empty operand of `&&` is skipped, and
an empty right operand intersects with the last operand
(`[-\w&&]` is `\w`).

A quantifier applies to the last character of a literal run (`ab*`
is `a(?:b*)`). A `{n}` with no atom before it repeats the empty
string (`{1}` matches everywhere), and a second bound after a
quantifier repeats the empty string too (`a{2}{3}` is `a{2}`), both
Java's reading; a `*`, `+` or `?` with no atom is `Dangling meta
character`.

**Refused**, with these sentences:

| Construct | Sentence |
|---|---|
| `\1`...`\9`, `\k<name>` | `backreferences are not supported` |
| `(?=` `(?!` `(?<=` `(?<!` | `lookahead and lookbehind are not supported` |
| `(?>X)` | `atomic groups are not supported` |
| `X*+ X++ X?+ X{n,m}+` | `possessive quantifiers are not supported` |
| `\p{IsLatin}`, `\p{InGreek}`, `\p{sc=...}`, `\p{IsAlphabetic}`, `\p{javaLowerCase}` | `Unicode scripts, blocks and binary properties are not supported` |
| `(?U)` | `the U flag (UNICODE_CHARACTER_CLASS) is not supported` |
| `(?c)` | `the c flag (CANON_EQ) is not supported` |
| `\X`, `\N{...}`, `\b{g}` | a sentence naming each |

#### 2.1 Flags

| Flag | Effect |
|---|---|
| `i` | ASCII letters match either case |
| `u` | with `i`, every cased code point folds by Java's case mappings (§5.1) |
| `m` | `^` and `$` hold at line boundaries |
| `s` | `.` matches line terminators |
| `d` | `\n` is the only line terminator for `.`, `^` and `$` |
| `x` | whitespace and `#` comments are ignored outside escapes, inside classes too |

Flags set by `(?i)` hold to the end of the enclosing group, across
`|`; `(?i:X)` holds for X. Flags apply as each construct is read:
under `(?i)` the predefined classes do not fold, except that
`\p{Lu}`, `\p{Ll}` and `\p{Lt}` become `\p{LC}` and `\p{Lower}` and
`\p{Upper}` become `\p{Alpha}` (Java's `forProperty`).

---

### 3. Matching

#### 3.1 Code points

The input is UTF-8 and matching sees code points: `.` and `[^x]`
consume a whole scalar, class ranges are code points, and every
capture offset is a byte offset on a scalar boundary. Callers
validate the input (`std.unicode.utf8ValidateSlice`); on malformed
bytes the VM decodes each bad byte as a non-character that nothing
matches, so it never faults.

#### 3.2 The Pike VM

A search simulates the NFA with one thread per instruction: the
epsilon closure (`split`, `jmp`, `save`, `mark`, `if_empty`,
`assert`) is followed with an explicit stack, and the threads resting
at a `char`, `class` or `match` form the list for the position, in
priority order. A step decodes one code point and moves each thread
that accepts it to the next position's list. A `match` records the
thread's slots and cuts every lower-priority thread: leftmost-first,
as a backtracking engine reports. With `whole`, a `match` before the
end is skipped without cutting, so `a|ab` matches all of `ab`, as
`Matcher.matches` does. While no match is found, a fresh thread
starts at each position at the lowest priority.

Each instruction enters the closure at most once per position, so a
search costs O(n·m·k) for n input bytes, m instructions and k slots
per thread, and needs no memory beyond the `Vm`. In tests the VM
counts closure steps, and a test pins the bound on the classic
catastrophic patterns (`(a*)*b`, `(x+x+)+y`, `(a|aa)*c`, ...).

Slots: 0 and 1 hold the match, then one hidden slot per nullable
repetition (§3.3), then two per group.

Prefilters, used while no thread is alive:

- A pattern that is a literal (no flags, groups or metacharacters)
  never enters the VM: `string.indexOf`, the SIMD search
  `nexis.string` uses, finds it.
- Otherwise a literal prefix of two or more bytes that every match
  starts with skips to its next occurrence;
- else the set of first bytes a match can start with skips the bytes
  outside it (none when a match can be empty or start with any ASCII
  byte).
- A program whose every path starts with `\A` or `^` (without `m`)
  tries only the first position.

#### 3.3 Repetition

`X|Y` is `split L1, L2; L1: X; jmp E; L2: Y; E`, X preferred; a lazy
quantifier swaps every split's preference. Java's results for empty
iterations follow from which node its compiler builds, and the
compiler reproduces each:

- **`X?`** is a plain branch: `(\A)?` captures `""`.
- **A zero-width deterministic body** (no alternation, no variable
  repetition, consuming nothing: `(\A)`, `\b`, `(?:(^)){2}`) repeats
  only its mandatory copies, then, when greedy and the bound allows,
  one more iteration that keeps the captures of the groups inside the
  body but not the repeated group's own: `(\A)*` leaves group 1 nil,
  `(?:(\A))*` captures `""` (Java's `GroupCurly` and `Curly`).
- **A nullable body** (it can match empty) follows Java's `Loop`:
  each iteration is `mark h; X; if_empty h → E`, and an iteration
  that consumed nothing ends the repetition with its captures, even
  below the minimum count. The unbounded loop alternates two copies
  of X, so the iteration after one that consumed runs through
  instructions its predecessor did not visit at that position;
  otherwise the per-position de-duplication would kill it, and
  `(a?)+` on `aa` would capture `a` where Java captures `""`.
- **Otherwise** `X{n,m}` is n copies and m − n nested optional copies,
  and `X{n,}` is n − 1 copies and a loop whose back edge is a split
  (`B: X; split B, E`), so an iteration leaves the loop with its
  captures.
- **`\R`** is `\r\n` or a single terminator, `\r\n` preferred. Where
  it is the body of a quantifier, or ends a deterministic group body
  a quantifier repeats as one unit, it is atomic as in Java: `\r`
  alone only where no `\n` follows, so `\R{2,}` does not match
  `"\r\n"` while `\R\n` does.

Case folding is resolved at compile time into classes (§5.1).

#### 3.4 Assertions

Positions are byte offsets; assertions see the whole input, also
before the search's start. Line terminators are `\n`, `\r`, `\r\n`
(one), U+0085, U+2028 and U+2029, or `\n` alone under `d`.

| Assertion | Holds at `pos` when |
|---|---|
| `\A`, `^` | `pos == 0` |
| `(?m)^` | `pos < len`, and `pos == 0` or a terminator ends at `pos`, not between `\r` and `\n`; never at the end, so `(?m)^` finds nothing in `""` (Java's `Caret`) |
| `\z` | `pos == len` |
| `\Z`, `$` | at the end, or before a final terminator (`\r\n` one), not between `\r` and `\n` |
| `(?m)$` | at the end, or before any terminator, not between `\r` and `\n` |
| `(?d)$`, `(?d)\Z` / `(?dm)$` | at the end or before a final `\n` / before any `\n` |
| `\b`, `\B` | the code points on either side differ (agree) in being word characters: ASCII `[A-Za-z0-9_]`, or a non-spacing mark whose base character is a letter or digit (Java's `Bound`) |
| `\G` | `pos` is where the previous match ended (the search's start for the first) |

The base of a run of non-spacing marks is found once per run, so
`\b` stays linear on a long run of marks.

#### 3.5 The find loop

`Finder.find` is Java's `Matcher.find`: each search starts where the
previous match ended, `\G` holds there, and after an empty match the
next search starts one code point later (Java: one UTF-16 unit). So
`a*` on `baaa` finds `""`, `"aaa"`, `""`.

---

### 4. Limits

Java has none of these; they make a hostile pattern an error rather
than a slow search.

| Limit | Value | Sentence |
|---|---|---|
| a repetition bound | 1000 | `repetition count exceeds 1000` |
| program size, after every repetition is expanded | 10 000 instructions | `the pattern compiles to more than 10000 instructions` |
| program size × slots | 2^20 slot words | `the pattern has too many groups for its size` |
| nesting of groups and classes | 250 | `groups nest too deeply` |

A literal pattern has no instructions and no limit on its length. The
parser counts both group and class depth and calls `stack.check()`,
so a deep pattern is an error, never a fault.

---

### 5. Unicode data

`src/regex_tables.zig` is generated by `test/regex/tables.clj` from
the JVM that runs it (`java.lang.Character`), so it is Java's Unicode
data by construction; regenerating it is a deliberate commit, never a
build step:

```
bb test/regex/tables.clj | zig fmt --stdin > src/regex_tables.zig
```

It holds two case maps as runs (`first, last, stride, delta`) and the
general category of every code point as range starts.

#### 5.1 Case folding

`(?i)` folds ASCII letters only: `(?i)é` does not match `É` and
`(?i)k` does not match U+212A KELVIN SIGN, as in Java. Under `(?iu)`
the maps are `upper` (`Character.toUpperCase`) and `fold`
(`toLowerCase(toUpperCase(c))`), and each literal becomes the set
Java's node for it accepts:

| Construct | Matches the code points `ch` with |
|---|---|
| a lone character `c` (`single`) | `c` when `upper(c) == fold(c)`; else `ch == fold(c)` or `fold(ch) == fold(c)` |
| a character of a run of two or more (`SliceU`) | `fold(ch) == fold(c)` |
| a class range `[a-z]` (`CIRangeU`) | `ch`, `upper(ch)` or `fold(ch)` in the range |
| a predefined class (`\w`, `\p{...}`) | no folding |

So `(?iu)ß` does not match U+1E9E but `(?iu)xß` matches `xẞ`, and
`(?iu)[\w]` does not match `ſ`, all as in Java. The sets are computed
at compile time from the runs, by preimage, and folded before a class
is negated (`(?i)[^a]` does not match `A`).

#### 5.2 General categories

`\p{Lu}` and the like name `Character.getType`'s categories; the
one-letter groups are their unions (`C` includes `Cn`), `LC` is `Lu Ll
Lt`, `LD` is the letters and `Nd`, `L1` is U+0000–U+00FF. Scripts,
blocks and binary properties (`\p{IsLatin}`, `\p{InGreek}`,
`\p{IsAlphabetic}`) are refused. The POSIX names stay ASCII, as in
Java without `(?U)`.

---

### 6. Differences from `java.util.regex`

1. **No backtracking constructs** (§2): in exchange no pattern takes
   more than linear time, and the limits of §4 refuse what Java
   would accept and run slowly.
2. **An empty match advances by a code point**, Java's by a UTF-16
   unit: Java finds an extra empty match inside a surrogate pair
   (`""` on `"a😀"` finds four empty matches in Java, three here).
   `.` and classes see whole code points in both.
3. **Captures come from the path that matched.** A backtracking
   engine leaves state behind that Java sometimes reports: a group
   inside a group a quantifier repeats as one unit keeps a capture
   from a branch that later failed (`(?:(a))+x|ab` on `ab`: Java's
   group 1 is `"a"`, here nil), and a group nested in a repeated
   group can keep a capture from an iteration its parent backed out
   of (`((.)+){2}` on `1ßK`: Java's group 2 is `"ß"`, here `"K"`).
   The match itself always agrees.
4. **Not carried:** Unicode scripts, blocks and binary properties,
   `(?U)`, `(?c)`, `\X`, `\N{...}` and `\b{g}`.

---

### 7. The differential test

`test/regex/corpus.json` holds 9 000 cases, each `[pattern, input,
result]`: random patterns from a grammar of the supported constructs
(three seeds, nesting to depth 5) and random inputs over ASCII,
accented and astral letters, line terminators, a combining mark and
the case-folding special cases, with Java's every find and its groups
(`null` for a group that did not take part), `"ERR"` when Java
refuses the pattern, or `"TIMEOUT"` when Java runs past a second.
`test/regex/corpus.clj` generates it through `bb`:

```
bb test/regex/corpus.clj > test/regex/corpus.json
```

The suite `test/regex/regex.zig` runs the engine on every line and
compares every match and every group; the gate never needs a JVM. An
empty Java match between the halves of a surrogate pair is dropped
from the expected result (§6 #2), and a case where a Java match
starts or ends inside a pair is not generated.
