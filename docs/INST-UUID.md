# `#inst` and `#uuid` for nexis: design

**Base:** main `c5f800a` (v0.2.0).
**Line references** are to that commit. The revamp-3 cleanup (PRs 36–45) has since moved and trimmed the code, so find each site by name.
 This is a design only. Nothing here is implemented.

**Owner decision:** an `#inst` reader literal and a UUID value kind are in scope (2026-10-09). This note replaces TODO.md #22 and #23.

**References:**
- Clojure 1.12.0: `core.clj` (`Inst`, `inst?`, `inst-ms`, `uuid?`, `random-uuid`, `parse-uuid`, `default-data-readers`), `instant.clj` (`parse-timestamp`, `print-date`), `uuid.clj`.
- Java `UUID.fromString`, `UUID.compareTo` and `Instant.toString`.

**Oracle:** expected outputs come from bb 1.12 (`bb -e`) unless noted.

---

## 0. Decision summary

| # | Question | Decision |
|---|---|---|
| 1 | Instant representation | A new **immediate kind `inst` = 8**. The payload is the epoch milliseconds as an `i64`, which is `java.util.Date`'s precision and range. The record `nexis.time.Instant` is **deleted**. |
| 2 | UUID representation | A new **heap kind `uuid` = 46**, a 32-byte leaf block (16-byte header and the 16 bytes). 128 bits cannot fit a 16-byte Value: the tag word's kind byte leaves 120 bits. |
| 3 | Syntax | **Grammar:** the scanner makes a `tag` token for `#` followed by a letter, and the grammar gains `datum = TAG gap datum → (tagged 1 3)`. **Reader:** turns `#inst "…"` and `#uuid "…"` into two new atom datums, `inst` (an i64) and `uuid` (16 bytes). Any other tag is the reader error `:unknown-tag`. **Printer:** `#inst "…"` in Clojure's exact text, and `#uuid "…"`, in both modes. **`pr-str`/`read-string`:** round-trips. **`nexis.edn`:** reads both tags with no code of its own. |
| 4 | Storage | **Codec:** both kinds serialize. Kind byte 8 is followed by a zigzag LEB128 i64; kind byte 46 by 16 raw bytes. The codec stays at version 1.0, because a new kind byte is additive (CODEC §2). **Nextomic:** `:db.type/instant` and `:db.type/uuid` take and return the new kinds and nothing else, as Datomic's do. The key and txlog bytes are unchanged, because only `marshal`, `Cell` and `valToValue` change. |
| 5 | API compatibility | **`uuid?`:** true of the uuid kind only, as in Clojure; a string is `false`. **`random-uuid`, `parse-uuid`:** return uuid values. **`random-uuid`'s source:** the I/O's CSPRNG, as Java's `SecureRandom` is. **JSON:** an inst is written as `Instant.toString` text and a uuid as its canonical text, both as JSON strings (clojure.data.json's choices). **`str`:** an inst gives `Instant.toString` text and a uuid its canonical text. |
| 6 | Proof | Tests come first in every commit (§7). A cross-version check reads a v0.2.0-written Nextomic store with the new binary (§7.4). |

**Amendments.** There are two Log entries, both dated 2026-10-09 (§6):
- **(A) Instants and UUIDs as value kinds.** Commit 1 carries it: §5 and §23 #25.
- **(B) The `#inst` and `#uuid` literals.** Commit 2 carries it: §4, §24 #3 and §28.

**Size.**
- **Source:** about +305 / −180 lines in `src/`, so about **+125 net**, not counting code moved between files (§7.5). The deletions are:
  - the record Instant and its doc block;
  - the JSON writer's record sniffing;
  - `uuidFromCanonical` and its special case in the query planner;
  - `taggedLiteralHint`;
  - transact's duplicate scalar arms.
- **Tests:** about +260 lines.

---

## 1. Instant representation

### 1.1 Options

| | A: keep the record `nexis.time.Instant {:ms n}` | B: immediate kind `inst` (chosen) | C: heap kind `inst` |
|---|---|---|---|
| Literal | `#inst` would need a record value in the constant pool: the type registry is per VM and the type lives in `time.nx`, which loads on demand | an atom datum lifted to an immediate constant, as `int` is | as B, plus an allocation |
| `=` and `hash` | already structural, but `(= i {:ms 5})` needs record rules | bit equality, which is `equalImmediate` unchanged; `hashI64` with kind domain 8 | a new heap arm |
| `compare`, `sort` | records have no order; a special case in `naturalOrder` would have to sniff the type | one `naturalOrder` arm | one arm |
| Codec and durable refs | records are unserializable (§23 #25), and making one type serializable is a special case | a kind byte, as fixnum's | a kind byte |
| GC, allocation | a record block and a field map per instant | none | a 16+16-byte block per instant |
| Printing | sniff the record type in `format.zig` | one arm | one arm |
| Metadata | a record carries it; Clojure's `Date` does not (`IObj` cast fails) | `:no-metadata-on-immediate`, as Clojure refuses | needs an explicit refusal |
| Range | the fixnum's, ±2^47 ms (−2490 to 6429) | i64 ms, `Date`'s range | i64 ms |

**Why B.**
- The payload word holds an i64 exactly, so an instant costs no allocation.
- Equality, `identical?`, truthiness and GC need no new code.
- The other arms are one line each (§5).
- The kind byte 8 is the first of the reserved immediates 8–15 (VALUE §2).

**Option A, rejected.** It keeps a special case in every layer: printing, compare, codec, JSON (`stdlib.zig` `instantMs` already sniffs the record by namespace and type name), literal and EDN. It also leaves instants unstorable in durable refs.

**Option C, rejected.** It costs an allocation and gives nothing that B lacks.

### 1.2 Semantics of the `inst` kind

| Operation | Result |
|---|---|
| Value | Milliseconds since 1970-01-01T00:00:00Z, proleptic Gregorian, UTC, no leap seconds: an `i64`. |
| `=` | Same milliseconds, as `Date.equals`. Never equal to another kind: `(= #inst "1970" 0)` is false. |
| `hash` | `mixKindDomain(hashI64(ms), 8)`. nexis's hashes are its own (`(hash 1)` already differs from Clojure's). |
| `identical?` | Bit equality, so two insts of the same milliseconds are identical, as two equal fixnums are. Clojure's `Date`s are not, which is harmless. |
| `compare` | By milliseconds. Comparing an inst with another kind is `:kind-mismatch` (`ClassCastException`). nil sorts first. |
| `<`, `+`, `inc` | `:kind-mismatch`: an instant is not a number, as in Clojure. |
| `class` / `type` | `:inst` (the kind's tag name, through `fnClass`'s generic arm). `(instance? :inst x)` and `class?` work with no further change. |
| `inst?`, `inst-ms` | `true`, and the milliseconds as an integer: a fixnum within ±2^47, else a bignum, as a Java long. |
| Metadata | `with-meta` is `:no-metadata-on-immediate`; `meta` is `nil`. |
| `str` | The `Instant.toString` text, `2026-10-09T10:30:15.123Z`, which is `nexis.time/format`'s. Clojure's `(str date)` is `Date.toString` in the local zone (`"Tue Dec 31 17:00:00 MST 2019"`), which no one parses. This is a documented difference. |
| `pr`, `print`, the REPL | `#inst "2026-10-09T10:30:15.123-00:00"`: Clojure's text byte for byte, always `.SSS` and `-00:00`. Display mode prints the same, as Clojure's `print-method` for `Date` ignores `*print-readably*`. |
| Codec | Kind byte 8, then the zigzag LEB128 of the i64 (1–10 bytes). |

### 1.3 Text: one parser, two writers

`src/inst.zig` is a new file declared after `value.zig`. It takes the calendar code and both text functions out of `stdlib.zig` (`daysFromCivil`, `civilFromDays`, `daysInMonth`, `writeInstant`, `parseInstant`, and the two tests). `reader.zig` and `format.zig`, which sit below `stdlib.zig`, can then use them.

**`parse(s) ?i64`** is Clojure's `#inst` grammar (`instant.clj` `timestamp`), plus the three spellings nexis already accepts:

```
instant = year [ "-" MM [ "-" DD [ T HH [ ":" mm [ ":" ss [ "." 1*DIGIT ] ] ] ] ] ] [ offset ]
year    = [ "+" / "-" ] 4*DIGIT          ; Clojure: exactly 4DIGIT, no sign
T       = "T" / "t"                       ; Clojure: "T"
offset  = "Z" / "z" / ( "+" / "-" ) HH [ ":" ] mm     ; Clojure: "Z" or ±HH:mm
```

**Ranges.**
- Month 1–12, day 1 to the month's length, hour 0–23, minute 0–59.
- Second 0–59, or 60 when the minute is 59. A leap second rolls into the next minute, as Clojure's lenient `GregorianCalendar` does: `#inst "2020-01-01T23:59:60"` is `#inst "2020-01-02T00:00:00.000-00:00"`.
- The offset's hour 0–23 and minute 0–59.
- The fraction may be any number of digits; the first three are the milliseconds and the rest are ignored, as Clojure's are.
- The result must fit an i64 (checked arithmetic), else `null`.

**Changes from today's `parseInstant`** (`docs/STDLIB.md` §12):
- **Brought to Clojure's grammar:**
  - an hour without minutes (`T10`) reads;
  - a fraction past 9 digits reads;
  - `:60` reads at minute 59;
  - a year of 5 or more digits reads.
- **Range:** widened from the fixnum's to i64, so `"an instant past the fixnum range"` disappears.

**`write(w, ms, style)`** has two styles over the same calendar:
- **`.literal`** is Clojure's `#inst` text:
  - `yyyy-MM-ddTHH:mm:ss.SSS-00:00`;
  - a year outside 0–9999 is written with its sign and at least four digits (`-0001-…`, `+10000-…`), which `parse` reads back.

  Clojure prints year 10000 unsigned and cannot read it back. nexis's text always reads back.
- **`.iso`** is today's `writeInstant`, Java's `Instant.toString` to the millisecond: `2026-10-09T10:30:15.123Z`, with the fraction left out when it is zero.

`.literal` is used by the printer and the golden printer. `.iso` is used by `str`, `nexis.time/format` and JSON.

**Expected outputs (bb):**
- `(pr-str #inst "2020")` → `"#inst \"2020-01-01T00:00:00.000-00:00\""`
- `(pr-str (java.util.Date. -1))` → `"#inst \"1969-12-31T23:59:59.999-00:00\""`
- `(inst-ms #inst "2026-10-09T12:30:15.123+02:00")` → `1791541815123`
- `(read-string "#inst \"2020-13\"")` → error
- `(read-string "#inst \"2020-01-01T24:00\"")` → error

---

## 2. UUID representation

### 2.1 Options

| | A: keep strings | B: immediate | C: heap kind `uuid` (chosen) | D: record `nexis.uuid.UUID` |
|---|---|---|---|---|
| Fits | — | **No.** The tag word has the kind byte (bits 0–7), leaving bits 8–63 (56) plus the payload (64), which is 120 < 128. Even a v4 UUID has 122 random bits. Two representations, one packed and one boxed, would double every arm. | 16 bytes in a leaf block of 32 bytes | a record and a map |
| `uuid?`, `#uuid`, printing | Clojure-incompatible: `(uuid? "…")` is true in nexis and false in Clojure | — | Clojure's | needs sniffing of the record type, as today's Instant does |
| Codec | as a string | — | 16 bytes | unserializable |

**Why C.**
- A uuid is a value of its own kind: equal by its 16 bytes, ordered by them, with no metadata.
- The block is a GC leaf (`gc.isLeafKind`), as `string` is.
- Kind 46 is the first reserved heap number (VALUE §2: 46–63).

**Option A, rejected.** Strings cannot give Clojure's `uuid?`, `#uuid` printing or a typed Nextomic value. The owner approved the kind.

**Option D, rejected.** A record is unserializable, and it repeats the special cases that option A of §1 has.

### 2.2 Semantics of the `uuid` kind

| Operation | Result |
|---|---|
| `=` | Same 16 bytes. Never equal to its text: `(= (parse-uuid s) s)` is false, as in Clojure. |
| `hash` | XXH3 of the 16 bytes with kind domain 46, not cached (no header bit is needed for 16 bytes). |
| `compare` | **Unsigned byte order**, which is the canonical text's order, RFC 9562's order (so v7 UUIDs sort by time), Nextomic's index order (`key.zig` tag `0x60`, `std.mem.order`) and the order today's string UUIDs sort in. Java's `UUID.compareTo` compares two **signed** longs, so in Clojure `(compare #uuid "8000…" #uuid "0000…")` is −1, a known JDK defect (JDK-7025832). nexis keeps the unsigned order and documents the difference. |
| `class` | `:uuid` |
| Metadata | `:no-metadata-on-immediate`. `uuid` joins the scalars row of SEMANTICS §7, as `string` (also a heap kind) is there. |
| `str` | The canonical text: lower-case hex in groups of 8-4-4-4-12 joined by `-`. |
| `pr`, `print` | `#uuid "0123abcd-4567-89ef-0123-456789abcdef"` in both modes, as Clojure's `print-method` writes it. |
| Codec | Kind byte 46, then 16 bytes. |

### 2.3 Text: one parser

`src/uuid.zig` is a new file declared after `string.zig`. It is the kind's module:
- `make(heap, [16]u8) !Value`;
- `bytesOf(v) *const [16]u8`;
- `hashOf(v) u64`;
- `parse(s) ?[16]u8`;
- `writeText(*[36]u8, [16]u8)`.

`nextomic/datom.zig` loses `uuidToText`, `uuidFromText`, `uuidFromCanonical` and their test (−45 lines) and calls `uuid.zig`.

**`parse` is Java's `UUID.fromString` grammar**, which Clojure's `parse-uuid` and the `#uuid` reader both use:
- five groups of hex digits of either case, joined by `-`;
- group lengths 1–8, 1–4, 1–4, 1–4 and 1–12, each right-aligned;
- at most 36 characters.

Java's own accidents are refused: a sign on a group (`Long.parseLong` takes `+1`) and an over-long group that Java truncates (`123456789-1-1-1-1`). Where Java parses those, nexis returns nil. Everything else matches:
- `1-2-3-4-5` → `#uuid "00000001-0002-0003-0004-000000000005"`;
- an empty group, six groups, a non-hex digit or 37 characters → nil.

**A spec/code mismatch found on the way.** STDLIB.md §8 says `parse-uuid` takes "Java's lenient short groups", but `datom.uuidFromText` requires exactly 36 characters (`(parse-uuid "1-2-3-4-5")` is nil today). The code is wrong; this design fixes it.

---

## 3. Syntax

### 3.1 Scanner and grammar

**`src/nexis.zig`.** In the `#` dispatch, the `else` arm now splits on the character after `#`:
- an ASCII letter makes one **`tag`** token over `#` and the symbol constituents after it (`#inst`, `#uuid`, `#my/tag`, `#ns.Rec`);
- every other character keeps today's `err` token (`#?`, `#%`, `#=`, `#<`, `#!`).

About ±6 lines.

**`nexis.grammar`:**

```
tokens … tag …
datum = …
      | TAG gap datum                         → (tagged 1 3)
```

`gap` lets `#inst #_x "1970"` read, as Clojure's reader does. Run `zig build parser` and commit `src/parser.zig` with it.

**Why a generic `tag` token and not two keywords.**
- An unknown tag becomes a reader error with a span and a message (`:unknown-tag`), not a parse error at a token.
- The grammar already carries `#tag form` for the open question of user tags (§24 #3 stays open; §6.2).

**Alternative rejected:** read `#inst "…"` as the form `(nexis.time/parse "…")`, as `#()` reads as `fn*`. TODO #22 notes the cost:
- `'#inst "…"` would quote a list;
- `nexis.edn/read-string` would return a list, not an instant;
- data would not round-trip.

### 3.2 Reader (`src/reader.zig`)

Two atom datums join `Datum`:
- `inst: i64`;
- `uuid: [16]u8`.

The `tagged` Sexp normalizes:

| Source | Form |
|---|---|
| `#inst "2026-10-09T12:30:15.123+02:00"` | `(inst "2026-10-09T10:30:15.123-00:00")` |
| `#uuid "0123ABCD-4567-89EF-0123-456789ABCDEF"` | `(uuid "0123abcd-4567-89ef-0123-456789abcdef")` |
| `#inst "2020-13"`, `#inst 5`, `#inst ^:m "2020"` | reader error `:invalid-inst`, detail `not an instant: "2020-13"` or `#inst takes a string` |
| `#uuid "x"`, `#uuid 5` | reader error `:invalid-uuid`, detail `not a UUID: "x"` or `#uuid takes a string` |
| `#foo/bar 1`, `#ns.Rec{:a 1}` | reader error `:unknown-tag`, detail `#foo/bar; nexis reads the tags #inst and #uuid` |

**Rules:**
- The span is the tag through the string.
- The string is the decoded `string` datum, so escapes work.
- Both datums are literal keys (`isLiteralKey`, `LiteralSet` hash, `formLiteralEq`), compared by milliseconds and by bytes. So `#{#inst "2020" #inst "2020-01-01T00:00Z"}` is `:duplicate-literal-element`, as Clojure's `Duplicate key` is.
- The golden printer writes `(inst "<.literal text>")` and `(uuid "<canonical>")`.
- `taggedLiteralHint` and its test are deleted (−12 lines). The `:unknown-tag` detail carries the hint.

**Error vocabulary.** The three new `ErrorKind`s follow `:invalid-regex`, and read errors surface as `:reader-error` from `read-string` as today. With a span, `:unknown-tag` is the clearer error; a parse error has none.

### 3.3 Macroexpander and compiler

**`expand.zig`** (+14 lines):
- **Form → Value** (`formValue`): an `inst` datum becomes `value.fromInst(ms)` and a `uuid` datum becomes `uuid.make(heap, bytes)`.
- **Value → Form** (`valueForm`): the inverse, so a macro may return either.
- **Self-evaluating datums** (`:359`, `:2179`, `:2852`): both are atoms everywhere `regex` and `string` are. `` `#inst "…" `` is the instant, unqualified.
- **Phrase table** (`:571`): "an instant", "a UUID".

**`compile.zig`** `lowerDatum` (+8 lines):
- `inst` → `.literal = fromInst(ms)`, an immediate constant;
- `uuid` → a heap constant, made once per routine as a string is.

`quote` therefore yields the values: `(class '#uuid "…")` is `:uuid`.

**`image.zig`** (+12 lines): `.inst` joins the immediate arm of `ref`, and `immediate()` validates it. `.uuid` becomes an `ObjTag` with 16 body bytes and joins the `.string, .bignum, .regex` comparison arm. A stdlib source may then hold either literal.

### 3.4 Printing, `read-string`, EDN

**Printing.** `format.zig` gains two arms (+12 lines):
- `#inst "` + `inst.write(.literal)` + `"`;
- `#uuid "` + text + `"`.

Both modes print the same. `str` of a bare inst or uuid writes the `.iso` text or the canonical text, beside today's arm for a bare regex (`stdlib.zig:5539`). `str` of a collection stays readable: `(str [#inst "2020"])` is `"[#inst \"2020-01-01T00:00:00.000-00:00\"]"`, as in bb.

**Round trip.** SEMANTICS §6.1 gains both kinds: `(= (read-string (pr-str v)) v)` and equal hashes, for every i64 instant and every UUID.

**`nexis.edn`.** `edn.nx` is unchanged: `nexis.core/read-string` reads both tags. STDLIB §4 changes its sentence: "the reader reads the tags `#inst` and `#uuid` (EDN's two built-in tags); any other tag is `:reader-error`, and `:readers` and `:default` have nothing to apply to." Clojure's EDN reader applies `:readers` to user tags; nexis does not, and that stays §24 #3.

---

## 4. Storage

### 4.1 Codec (`src/codec.zig`, CODEC.md)

| Kind | Bytes |
|---|---|
| `inst` (8) | `[8] [zigzag LEB128 = the i64 milliseconds]` |
| `uuid` (46) | `[46] [16 bytes, the UUID in network order]` |

**Format.** It stays 1.0: "A new kind byte is additive without a version change: a reader that predates it refuses the byte as `InvalidKindByte`" (CODEC §2).

**Decode rules.**
- A ten-byte LEB128 is limited to bit 63 as today, so every decoded value is an i64. There is no `MalformedPayload` case for the inst kind, because the whole i64 range is valid.
- A uuid with fewer than 16 bytes left is `TruncatedInput`.

**Tables.**
- CODEC §3 moves `inst` and `uuid` to "yes".
- The reserved bytes are now the immediates 9–15 and the heap bytes 47–63.
- The 256-byte sweep test changes for bytes 8 and 46.

**Durable refs.** `db/put!` and `db/get` of instants and UUIDs follow, which the Instant record could never do.

**Side finding.** CODEC §6 names `src/nextomic/datom.zig` as a codec caller, but no Nextomic file imports `codec.zig`: the store-format-3 txlog is its own binary encoding. Correct §6 in the codec commit.

### 4.2 Nextomic

The stored bytes do not change:
- `key.Val` is still `.instant: i64` (key tag `0x20`) and `.uuid: [16]u8` (`0x60`);
- the txlog encodes by attribute type (`datom.zig`).

Only the VM side of the conversion changes, in four places. Every Datomic path takes and returns the kinds, **strictly**.

| Site | Today | Becomes |
|---|---|---|
| `marshal.convertVal`, `transact.convertValue`: tx-data, lookup refs, `datoms` components, `index-range` bounds | instant: any integer in i64. uuid: canonical lower-case text | instant: an `inst`. uuid: a `uuid`. Anything else is `:nextomic/value-type` naming the attribute and type, as a wrong type is today. |
| `marshal.encodeCell`: query constants and inputs under an attribute | instant: an `.int` cell. uuid: a canonical `.str` cell | an `.inst` cell, a `.uuid` cell. Any other cell matches nothing. |
| `marshal.cellOf`: datom → query cell | instant → `.int`. uuid → 36 bytes of text in the arena | `.inst = ms`, `.uuid = bytes` (no allocation) |
| `Conn.valToValue`, `Exec.cellValue`, `tx-range` | instant → fixnum or bignum. uuid → a string | `value.fromInst(ms)` (cannot fail) and `uuid.make(heap, bytes)` |

**`relation.Cell`** gains `inst: i64` and `uuid: [16]u8`. The union stays 24 bytes, since a `[16]u8` is no larger than the `str` slice.
- **`fromValue`:** maps the two kinds onto the arms.
- **`eql` and `hash`:** compare and hash by value.
- **`rank`:** each kind has a rank of its own, between strings and keywords.
- **`order`:** by i64 and by unsigned bytes.

This brings Datomic's comparisons to Datomic's types:
- `[(< ?t ?cutoff)]` on two insts orders them;
- `(min ?t)` and `(max ?t)` of `:db/txInstant` are insts;
- `<` between an inst and a long is the existing "compares values of one kind" error.

`cellPhrase` gains "an instant" and "a UUID".

**Why strict, and not "take an inst or a long".**
- **Joins.** A relation join compares cells with `Cell.eql` and knows no attribute. A long bound by `:in` would match an `:db.type/instant` datom when the plan scans with it as a constant (through `encodeCell`), but not when the plan hash-joins two relations. The answer would depend on the plan.
- **Two spellings.** Today's uuid rule exists for the same reason (NEXTOMIC.md §2.2: "one text per uuid … so every path compares the same bytes"). One kind per type removes the hazard and the special case in `plan.zig:1144`.
- **Datomic.** It is strict in the same way (`java.util.Date`, `java.util.UUID`).

Migration is `(nexis.time/instant ms)` and `(parse-uuid s)` (or a literal). A long written to a `:db.type/instant` attribute is now `:nextomic/value-type`, as Datomic rejects one.

**Smaller on the way (optional, −20 lines).** `transact.convertValue` repeats `marshal.convertVal`'s boolean, long, double, instant and uuid arms. Both arms change here anyway, so one `marshal.scalarVal(vt, v) error{ValueType}!?Val` can serve both, with transact keeping only its arena copy of strings and bytes and its ref and keyword arms.

**Unchanged.**
- `:db/txInstant` defaults, monotonicity and the txlog header instant: they are i64 inside the store.
- An explicit `[:db/add "datomic.tx" :db/txInstant x]` takes an inst.

**Follow-up, not in scope.** Datomic's `(d/as-of db #inst "…")` takes a `Date` and resolves it through the `:db/txInstant` index. nexis's `as-of` takes a `t`. With the inst kind, an `as-of` of an inst is a small, separate feature (AVET on `:db/txInstant` exists). TODO.md should get a row.

---

## 5. Compatibility of the API

### 5.1 `nexis.core`

| Name | Today | Becomes |
|---|---|---|
| `uuid?` | true of a canonical string | `(instance? :uuid x)`: true of the kind only. `(uuid? "0123…")` is false, as in Clojure. The string test is `(some? (parse-uuid s))`. |
| `random-uuid` | canonical text | A uuid. Version 4, variant `10`, from **`io.random`** (`std.Io.random`, the process CSPRNG that `std.Io.Threaded` keeps and seeds from the OS) instead of the shared xoshiro `prng`. Java's `randomUUID` uses `SecureRandom`. An identity minted for a store must not be predictable from earlier `rand` output. The cost is a ChaCha fill in user space; measure it if it matters. |
| `parse-uuid` | canonical text, or nil | A uuid, or nil, through `uuid.parse` (Java's grammar, §2.3). A non-string is `:kind-mismatch` as today. |
| `Inst`, `inst?`, `inst-ms` | protocol; record extends it | Unchanged as definitions. `core.nx` adds `(extend-type :inst Inst (inst-ms* [i] (nexis.internal/#%inst-ms i)))`, since protocols already extend kind keywords (`extend-type :fixnum` works). A record may still extend `Inst`. |

**New natives in `internal_natives`:**
- `#%inst`: an integer in i64 → inst; past i64 is `:invalid-argument`.
- `#%inst-ms`: inst → integer.

**Changed natives:**
- `#%parse-instant` returns an inst.
- `#%format-instant` takes an inst.

**Interop hint.** `expand.zig`'s `System/currentTimeMillis` hint becomes `(inst-ms (nexis.time/now))`.

### 5.2 `nexis.time` (`time.nx`: 88 → about 55 lines)

**Deleted:**
- `defrecord Instant` and its five Vars (`Instant`, `->Instant`, `map->Instant`, `Instant?`, `Instant-type-id`) and their doc block;
- `nexis.time/inst?` and `nexis.time/inst-ms` (core's serve).

**Rewritten:**
- `instant`: an inst (or any `Inst`) is itself, as `(#%inst (inst-ms x))`; an integer becomes `(#%inst x)`; a string is `parse`d; anything else is `:kind-mismatch`.
- `now`: `(#%inst (#%now-ms))`.
- `parse`: `(#%parse-instant s)`.
- `format`: `(#%format-instant (instant x))`.
- `plus` and `minus`: `(#%inst (apply + (ms x) durations))`.
- `between`, `before?` and `after?`: over a private `(defn- ms [x] (inst-ms (instant x)))`, so every function still takes epoch milliseconds or text as well as an instant.

**Breaking, and to be documented:**
- `(:ms i)`, `->Instant` and `#nexis.time.Instant{…}` output;
- `t/inst?` and `t/inst-ms` (use core's);
- `(t/instant 5)` prints `#inst "1970-01-01T00:00:00.005-00:00"`.

### 5.3 `nexis.json`

**Writing.** The writer (`stdlib.zig` `JsonWriter`) handles both kinds:
- `.inst` → `"2026-10-09T10:30:15.123Z"` (`.iso`, clojure.data.json's `ISO_INSTANT` default);
- `.uuid` → `"0123abcd-…"` (data.json writes a UUID as its string).

The `.record` arm's `instantMs` (−14 lines), which sniffs the record by namespace and type name, is deleted. So is the load-order comment in `stdlib.zig` (`json.nx` "after time.nx, whose instants it writes").

**Reading** is unchanged: JSON has no instant or UUID, and `:value-fn` converts them.

### 5.4 Error messages and docstrings

- `vm.kindPhrase` gains "an instant" and "a UUID".
- These docstrings change: `random-uuid`, `parse-uuid`, `uuid?`, the `nexis.time` namespace (`stdlib.zig:3821`), `nextomic/tx-range` (`:instant` is an inst), and `json.nx` `write-str`.
- `test/integration/eval_pipeline.zig:317` (`apropos #"^->"`) loses `nexis.time/->Instant`.

---

## 6. Amendment texts

### 6.1 Amendment Log (append both, in this order)

```markdown
- **2026-10-09 — Instants and UUIDs are value kinds (§5, §23 #25).**
  An instant is the immediate kind `inst` (8): the payload is the
  milliseconds since 1970-01-01T00:00:00Z as an i64, the precision and
  range of Clojure's `java.util.Date`. It is `=` and hashes by its
  milliseconds, orders by them under `compare`, is not a number,
  carries no metadata, satisfies `Inst`, and `class` names it `:inst`.
  A UUID is the heap kind `uuid` (46), a leaf block of its 16 bytes:
  128 bits do not fit the 120 a Value leaves beside its kind byte. It
  is `=` and hashes by its bytes, carries no metadata, and `class`
  names it `:uuid`. `compare` orders it by unsigned bytes, which is its
  text's order, RFC 9562's and Nextomic's index order, where Java's
  `UUID.compareTo` compares signed longs. Both serialize: kind byte 8
  and a zigzag LEB128 i64, kind byte 46 and 16 bytes, additive to
  codec format 1.0. `random-uuid` and `parse-uuid` return a uuid,
  `random-uuid` from the process CSPRNG as Java's `SecureRandom`;
  `uuid?` is true of the kind only, as in Clojure. The record
  `nexis.time.Instant` is removed: `nexis.time` makes and takes the
  kind. Nextomic's `:db.type/instant` and `:db.type/uuid` take and
  return the kinds and nothing else, as Datomic's take a `Date` and a
  `UUID`; the stored bytes do not change. Reason: Clojure programs and
  EDN data carry instants and UUIDs as values, a record could be
  neither stored nor compared, and a UUID string was not
  `uuid?` in Clojure; one kind per Nextomic type keeps every query path
  comparing one representation. `docs/VALUE.md` §2 and
  `docs/SEMANTICS.md` §2.8 are the authority; `docs/CODEC.md` §2 and
  §3, `docs/GC.md` §5, `docs/STDLIB.md` §5, §8, §12, §13 and §14,
  `docs/NEXTOMIC.md` §2.2 and §9, `CLOJURE-REVIEW.md` and
  `docs/GUIDE.md` carry it.

- **2026-10-09 — The `#inst` and `#uuid` literals (§4, §24 #3,
  §28.2–§28.5).** Supersedes the §4 "Tagged literals" row. The
  scanner reads `#` and a letter as a tag token and the grammar
  `#tag form` as a tagged form; the reader reads `#inst "text"` as the
  atom datum `inst`, the instant the text names in Clojure's `#inst`
  grammar (a signed or longer year, a lower-case `T` or `Z` and an
  offset without its colon also read), and `#uuid "text"` as the atom
  datum `uuid`, in the grammar of Java's `UUID.fromString`. A text that
  names no instant or UUID is `:invalid-inst` or `:invalid-uuid`; any
  other tag is `:unknown-tag`. The compiler lifts both datums into
  constants and `quote` and macros see the values. An instant prints as
  Clojure prints a `Date`, `#inst "2026-10-09T10:30:15.123-00:00"`, a
  UUID as `#uuid "…"`, in both modes, and both read back `=`;
  `nexis.edn` reads both, EDN's two built-in tags. User tags
  (`*data-readers*`, `:readers`) stay open (§24 #3). Reason: EDN data
  and Clojure source write instants and UUIDs as literals, and reading
  them as values, not as the forms that build them, is what lets data
  round-trip through `pr-str`, `read-string` and `nexis.edn`.
  `docs/FORMS.md` §2, §3 and §5 are the authority; `docs/STDLIB.md` §4
  and §5, `docs/SEMANTICS.md` §6.1, `docs/TOOLING.md` and
  `CLOJURE-REVIEW.md` §4 carry it.
```

### 6.2 Section text changes

**§4: delete the row**

```
| Tagged literals `#inst`, `#uuid` | Rich literals are functions or macros (§24 #3). |
```

No row replaces it: user tags are an open question, not a non-goal.

**§5, Layer 2, second sentence**, which becomes:

```
Immediates are nil, booleans, chars, fixnums (i48), floats (f64),
instants (i64 epoch milliseconds), keywords and symbols (intern ids);
every other kind is a pointer to a heap object with a shared header
```

**§23 #25**, which becomes:

```
25. **Serialization has a fixed scope.** Serializable: nil, bool,
    char, fixnum, bignum, f64, instant, UUID, string, keyword and
    symbol (as text), list, vector, map, set, typed vector, a lazy seq
    (written as the list it realizes to), and sorted map and sorted set
    in the natural order. Everything else (functions, Vars, atoms,
    transients, durable refs, byte vectors, records, protocols, db and
    Nextomic handles, regexes and matchers, a sorted collection with a
    comparator of its own) is not; encoding one raises the keyword
    `:unserializable` (`docs/CODEC.md`). Nesting depth is unbounded.
```

**§24 #3**, which becomes:

```
- **#3 Tagged literals.** `#inst` and `#uuid` are read (Amendment
  2026-10-09); every other tag is `:unknown-tag`. User tags
  (`*data-readers*`, `nexis.edn`'s `:readers` and `:default`) are
  open: the grammar already reads `#tag form`, and the question is
  where a tag's function lives at read time, which has no namespace.
```

**§28.2**, inserted into the Atoms block after the regex line:

```
#inst "2026-10-09T12:30+02:00"       ;; inst (epoch milliseconds, i64; Clojure's #inst grammar)
#uuid "0123abcd-4567-89ef-0123-456789abcdef" ;; uuid (128 bits; Java's UUID.fromString grammar)
```

**§28.3**, new rows after the regex rows:

```
| `#inst "2026-10-09T12:30:15.123+02:00"` | the `inst` datum of the instant, 1791541815123 ms; the golden printer writes `(inst "2026-10-09T10:30:15.123-00:00")` |
| `#uuid "0123ABCD-4567-89EF-0123-456789ABCDEF"`, `#uuid "1-2-3-4-5"` | the `uuid` datum of its 16 bytes; the golden printer writes the canonical lower-case text |
| `#inst #_x "1970"` | a discard between the tag and its string is skipped |
| `#inst "2020-13"`, `#inst 5` | reader error `:invalid-inst` |
| `#uuid "x"`, `#uuid 5` | reader error `:invalid-uuid` |
| `#foo/bar 1`, `#ns.Rec{:a 1}` | reader error `:unknown-tag` |
| `#{#inst "2020" #inst "2020-01-01T00:00Z"}` | reader error `:duplicate-literal-element`: two `inst` datums of the same milliseconds |
```

The last parse-error row becomes:

```
| `##Infinity`, `#?(...)`, `::k` | parse error naming the construct |
```

It is unchanged, except that `#` and a letter is a tag token and no longer a parse error.

**§28.4**, Parser row: "Tokenizing and LALR(1) parsing; drops `#_` and the form it discards; a tag and its form as one tagged node." Reader row: append "the `inst` and `uuid` datums from their tags, `:unknown-tag`".

**§28.5**, row 12:

```
| 12 | `(< #inst "2026" t)` | `(list (symbol <) (inst "2026-01-01T00:00:00.000-00:00") (symbol t))` |
```

Bullet **12**: "The reader parses the text once: the `inst` datum holds milliseconds, and the golden printer writes Clojure's text of them."

### 6.3 Other documents, by commit

| Commit | Document | Change |
|---|---|---|
| 1 | VALUE.md | §1.1 the immediates' tag is 0 above bit 7; §2 reserved ranges 9–15 and 47–63; §2.1 row 8 `inst`: "the i64 epoch milliseconds; every i64 is valid"; §2.2 row 46 `uuid`: "a leaf block of the 16 bytes"; §3 constructor row `fromInst(ms: i64) Value`, infallible |
| 1 | SEMANTICS.md | new §2.8 "Instants and UUIDs" (§1.2 and §2.2 above); §3.3 rows 8 and 46 (own kind, `=` by milliseconds or bytes); §7 scalars row adds `inst`, `uuid` |
| 1 | SORTED.md §6 | rows "two instants: by milliseconds", "two UUIDs: by unsigned bytes" |
| 1 | CODEC.md | §1 Scope, §2 table, §3 table and reserved ranges, §6 callers (the stale datom.zig mention), §7 tests |
| 1 | GC.md §5 | `uuid` among the leaves |
| 1 | STDLIB.md §5 | print rows for both kinds, and the `str` row |
| 1 | HANDOFF.md §3.2 | immediates list; "heap kinds are numbered 16–46" |
| 2 | FORMS.md | §2 datums, §3 rows and the duplicate-detection sentence, §5 golden spelling, §7 goldens |
| 2 | TOOLING.md §… (line 173) | the idiom-hint sentence loses "a tagged literal (`#inst`, `#uuid`)" and `taggedLiteralHint`; it gains "an unknown tag names the two nexis reads" |
| 2 | STDLIB.md §4 | the `nexis.edn` sentence (§3.4) |
| 3 | STDLIB.md | §1 table natives for `nexis.time`; §8 rows `Inst`, `inst?`/`inst-ms`, `random-uuid`, `parse-uuid`, `uuid?`; §12 rewritten (representation, range i64, the table without `inst?`/`inst-ms`, the `parse` grammar of §1.3); §13 writing sentence; new §14 "UUIDs" owning `src/uuid.zig` (grammar, canonical text, order) |
| 3 | docs/README.md | rows `src/inst.zig` → STDLIB §12, `src/uuid.zig` → STDLIB §14 |
| 3 | CLOJURE-REVIEW.md | rows 197 (`#inst`/`#uuid`: read, with the grammar's superset), 254 (UUIDs: a kind; `compare` unsigned; `parse-uuid` refuses signed and over-long groups), 257 (instants: a kind of i64 ms; `str` is ISO), 258 (JSON) |
| 3 | GUIDE.md | lines 108, 111, 112, 267 ("UUIDs are strings" removed), 412 |
| 3 | TODO.md | #22 and #23 deleted; a row for `as-of` of an instant (§4.2) |
| 4 | NEXTOMIC.md | §2.2: the uuid paragraph becomes "a uuid is the `uuid` kind; an instant the `inst` kind; any other value is `:nextomic/value-type`…"; the long-or-instant paragraph keeps longs only; the query paragraph at line 765 is deleted; §9 "Values are the VM's" bullet: an instant is an inst and a uuid is a uuid, as Datomic's `Date` and `UUID`; the API table's `tx-range` row: `:instant` is an inst |

---

## 7. Commit plan

The commits land in a worktree branch `inst-uuid`, each with its failing tests first and the full gate (plus `-Dgc-stress` once, on commit 1) before it lands. Estimates are lines in `src/` (+added / −deleted) and in tests.

### 7.1 Commit 1 — `value: the inst and uuid kinds`

The code, the codec and the printer; no syntax yet. Amendment (A).

**Tests first:**
- **`src/inst.zig`.** The two calendar tests move from `stdlib.zig`. New tests:
  - `parse` of `"2020-01-01T10"`, a 12-digit fraction, `"…T23:59:60"` (the next day), `"10000-01-01"`, `"+10000-01-01"`, `"-0001-01-01"`;
  - refusal of `"…T22:59:60"`, `"2020-13"`, a year past i64 ms, and `""`;
  - `write(.literal)` of 0, −1, the year 0, the year 10000 and both i64 extremes, against bb's text where bb has one;
  - over a sweep of `ms`: `parse(write(ms, s)) == ms` for both styles.
- **`src/uuid.zig`.**
  - `parse` against the bb table of §2.3 (`1-2-3-4-5`, upper case, 37 characters, an empty group, six groups, `+1-…`, `123456789-…`);
  - `writeText` round trip;
  - `make` and `bytesOf`.
- **`src/value.zig`.**
  - `fromInst` and `asInstMs` at `minInt(i64)`, −1, 0 and `maxInt(i64)`;
  - `hashImmediate` of `inst(65)` ≠ `fixnum(65)`.
- **Properties.**
  - `test/prop/primitive.zig`: P1–P7 over random insts.
  - `test/prop/codec.zig` C1/C2: generators for both kinds.
  - `test/prop/gc.zig`: a uuid held and dropped across collections.
- **`src/codec.zig`.**
  - round trips of both kinds at the extremes;
  - a truncated uuid;
  - the 256-byte sweep with bytes 8 and 46 now decoding;
  - kind byte 8 with an 11-byte LEB is `InvalidLeb128`.
- **`src/format.zig`.** `#inst "1970-01-01T00:00:00.000-00:00"` for 0, and `#uuid "…"`.
- **`src/coll/sorted.zig`.** `naturalOrder` of insts, and of uuids `ffff…` above `0000…`.
- **`src/image.zig`.** A program constant of each kind survives the image round trip.

**Files:**

| File | Change |
|---|---|
| `src/value.zig` | +20 |
| `src/inst.zig` | new: +150 moved from `stdlib.zig` (−150 there), +30 code, +45 tests |
| `src/uuid.zig` | new: +60, +45 tests |
| `src/nextomic/datom.zig` | −45; calls `uuid.zig` |
| `src/dispatch.zig` | +4 |
| `src/coll/sorted.zig` | +2 |
| `src/gc.zig` | ±2 |
| `src/format.zig` | +12 |
| `src/codec.zig` | +22, +35 tests |
| `src/image.zig` | +12 |
| `src/vm.zig` (`kindPhrase`) | +2 |
| `src/stdlib.zig` | `str` arms +4; the moved code −150 |
| `src/root.zig` | +2 |
| `test/prop/*` | +40 |
| `test/portable/write.nx`, `read.nx` and their `.out` | `refs.edb` gains an inst and a uuid value (CODEC's every-serializable-kind contract) |

PLAN, VALUE, SEMANTICS, SORTED, CODEC, GC, STDLIB §5 and HANDOFF change as in §6.

**Estimate:** `src/` about +170 / −50 net of moves; tests about +165.

### 7.2 Commit 2 — `reader: the #inst and #uuid literals`

Amendment (B).

**Tests first:**
- **`test/golden/reader-literals.nx`/`.sexp`:** `#inst "2026-10-09T12:30:15.123+02:00"`, `#inst "2020"`, `#uuid "0123ABCD-…"`, `#uuid "1-2-3-4-5"`, `#inst #_x "1970"`, `'#inst "1970"` and `[#inst "2026"]`.
- **`test/golden/errors/`:** new `invalid-inst.{nx,err}` (`#inst "2020-13"`), `invalid-uuid.{nx,err}` (`#uuid 5`), `unknown-tag.{nx,err}` (`#foo/bar 1`) and `duplicate-inst.{nx,err}`.
- **`reader.zig` inline:** duplicate detection across two spellings of one instant and one UUID.
- **`test/integration/eval_pipeline.zig`:** the two `expectLoadFailure` lines at 1519–1520 are replaced by an `:unknown-tag` case. New cases:
  - `(pr-str #inst "2020")` gives bb's text;
  - `(= v (read-string (pr-str v)))` for both kinds;
  - `(class '#uuid "…")` is `:uuid`;
  - a macro that returns an inst and one that returns a uuid;
  - `` `[#inst "1970"] ``;
  - `(nexis.edn/read-string "#inst \"2020\"")`;
  - `(with-meta #inst "2020" {})` is `:no-metadata-on-immediate`;
  - `#{#inst "2020" #inst "2020-01-01T00:00Z"}` is a reader error.

**Files:**

| File | Change |
|---|---|
| `nexis.grammar` | +2 |
| `src/parser.zig` | regenerated |
| `src/nexis.zig` | ±6 |
| `src/reader.zig` | +45 / −12 |
| `src/expand.zig` | +14 |
| `src/compile.zig` | +8 |

PLAN §4, §24 #3 and §28, and FORMS, TOOLING and STDLIB §4 change as in §6.

**Estimate:** `src/` about +75 / −14, plus the generated parser; tests about +60.

### 7.3 Commit 3 — `core: UUIDs and instants are their kinds in core, nexis.time and nexis.json`

**Tests first.** `eval_pipeline.zig` 2390–2392 are rewritten:
- `(uuid? (random-uuid))` true;
- `(uuid? "0123…")` false;
- `(count (str u))` 36, with the version nibble `4` and the variant in `89ab`;
- `(parse-uuid "1-2-3-4-5")`;
- `(compare u1 u2)`.

The time tests at 5040–5110 are rewritten:
- `(nexis.time/instant 5)` prints `#inst "1970-01-01T00:00:00.005-00:00"`;
- `inst?` and `inst-ms` of the kind, and of a record extending `Inst`;
- `(sort [#inst "2021" #inst "2020"])`;
- `(str #inst "2020")` is `"2020-01-01T00:00:00Z"`;
- `plus` past the year 9999;
- JSON writes of an inst and a uuid;
- a durable ref holding `{:at #inst … :id #uuid …}` reads back `=`.

**Files:**

| File | Change |
|---|---|
| `src/stdlib/core.nx` | ±4 |
| `src/stdlib/time.nx` | −33 |
| `src/stdlib/json.nx` | ±2 |
| `src/stdlib.zig` | `#%inst`/`#%inst-ms` +18, `random-uuid`/`parse-uuid` −6, JSON +6 / −16, load-order comment −2 |
| `src/expand.zig` | ±1 |
| `test/integration/eval_pipeline.zig` | about ±60 |

STDLIB §1, §8, §12, §13 and §14, docs/README, CLOJURE-REVIEW, GUIDE and TODO change as in §6.

**Estimate:** `src/` about +30 / −60.

### 7.4 Commit 4 — `nextomic: instant and uuid attributes take and return the kinds`

**Tests first:**
- **`marshal.zig` inline,** "marshalling both ways":
  - instant ↔ inst and uuid ↔ uuid;
  - a long under `:db.type/instant` and a string under `:db.type/uuid` are `ValueType`;
  - `key.valBytes` of both is pinned in hex, so the stored bytes are proven unchanged.
- **`test/integration/nextomic_q.zig`** (around 505 and 1327):
  - a uuid constant and a uuid `:in` binding;
  - a string spelling that matches nothing;
  - `[(< ?t ?c)]` between insts;
  - `(max ?t)` of `:db/txInstant` is an inst;
  - an inst-valued variable joined across two clauses.
- **`test/nextomic/basics.nx`/`.out`:** `#uuid` and `#inst` in tx-data. The upper-case-spelling case becomes "a string is `:nextomic/value-type`".
- **`longs-1.nx`/`.out`:** instant edges as insts at the i64 extremes.
- **`time.nx`:** `(every? inst? (map :instant (d/tx-range c)))`.
- **`test/portable/write.nx`/`read.nx`/`.out`:** the explicit `:db/txInstant`s are insts; `read.nx:149` uses `inst-ms`; the digests change because `hash` of an inst is not `hash` of a long.
- **`examples/nextomic-app.nx`:** its `:instant` attribute is fed insts.

**Cross-version check.** This is a one-off that the implementer records in the PR body. The v0.2.0 binary (`bin/nexis` at `c5f800a`) runs the old `test/portable/write.nx` into directory D. The new binary runs the new `read.nx` on D, and its output equals the new `read.out` byte for byte. That means a store written before the change reads as one written after it.

**Files:**

| File | Change |
|---|---|
| `src/nextomic/relation.zig` | +18 |
| `src/nextomic/marshal.zig` | ±10, −4 |
| `src/nextomic/db.zig` | −3 |
| `src/nextomic/query/exec.zig` | +4 |
| `src/nextomic/query/plan.zig` | −3 |
| `src/nextomic/natives.zig` | ±1 |
| `src/nextomic/transact.zig` | ±4, or −20 with `scalarVal` (§4.2) |

NEXTOMIC.md §2.2 and §9 change as in §6.

**Estimate:** `src/` about +30 / −35 (−55 with `scalarVal`); tests about ±80.

### 7.5 Totals

| | `src/` added | `src/` deleted | net | tests |
|---|---|---|---|---|
| 1 value | 170 | 50 | +120 | +165 |
| 2 reader | 75 | 14 | +61 | +60 |
| 3 core | 30 | 60 | −30 | ±60 |
| 4 nextomic | 30 | 55 (with `scalarVal`) | −25 | ±80 |
| **all** | **≈305** | **≈180** | **≈ +125** | **≈ +260** |

The totals exclude about 150 lines moved from `stdlib.zig` to `inst.zig` and 45 moved from `datom.zig` to `uuid.zig`; a move is not growth. Without the optional `scalarVal`, the net is about +145.

**Hot paths.** None changes:
- `equalImmediate` and `isTruthy` are untouched;
- `hashImmediate` and `naturalOrder` gain one arm after the existing ones;
- `Cell.order` gains a rank.

The implementer need not bench this change, except `random-uuid` if anyone generates millions of them (ChaCha against xoshiro).

---

## 8. Decisions

1. **`str` of an inst** is the ISO text ending in `Z` (`.iso`), as JSON and `nexis.time/format` write it; a CLOJURE-REVIEW row records the difference from `Date.toString`.
2. **Nextomic is strict.** `:db.type/instant` takes and returns an inst and `:db.type/uuid` a uuid, everywhere, as Datomic; a program that transacts longs or strings changes (release notes call it out).
3. **No `java.util.Date`/`UUID` interop hints** beyond the existing Java-interop error.
4. **`as-of` of an instant** is a separate TODO item.
