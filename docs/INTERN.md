## INTERN.md — Keyword & Symbol Intern Tables

The contract of `src/intern.zig`: the process-local tables that map
keyword and symbol names to the ids `Value.fromKeywordId` and
`Value.fromSymbolId` carry, and the record-type names the printer
reads. PLAN §23 #32 freezes the keyword/symbol asymmetry; equality and
hashing of the two kinds are `docs/SEMANTICS.md` §2.5 and §3.3.

A VM owns one `Interner` (`VM.ensureInterner`); a sub-VM the expander
runs macros on shares its owner's (`borrowed_interner`), so ids agree
across the two. §1–§3 are the contract; §4 is private.

---

### 1. Invariants

The interner maps **names** to **dense `u32` ids** in two independent
tables, one for keywords and one for symbols.

1. **Dense from 0, per table.** The first name interned in a table gets
   `0`, the Nth distinct name `N-1`. Ids are never reused and tables
   never shrink. No id is reserved: `nil` is the all-zero Value because
   its kind is 0 (`docs/VALUE.md` §1.2), so a keyword with id 0 is an
   ordinary keyword.
2. **Idempotent.** Interning the same bytes again returns the original
   id. There is no normalization (no NFC/NFD, SEMANTICS §2.4).
3. **Independent id spaces.** The keyword and symbol tables share
   nothing; the same text may have different ids in each. The Value
   layer keeps `:foo` and `'foo` apart by kind and hash domain
   (SEMANTICS §3.3), not the interner.
4. **Byte-exact round trip.** `keywordName(internKeyword(s))` is `s`
   byte for byte, and likewise for symbols.
5. **The interner owns the name bytes.** Each name is copied on its
   first intern and freed by `deinit`, so a caller may pass a
   transient buffer (a slice of source text); a returned name lives as
   long as the interner.
6. **No unintern, no weak entries.** The tables grow monotonically
   for the process's life: every distinct name read, decoded from a
   store or built with `(keyword s)` / `(symbol s)` stays (PLAN §25
   risk #16). A process that reads untrusted stores or input keeps
   every name it has seen.
7. **Empty names are rejected** (`error.EmptyName`). The reader never
   produces one, but codec decode and `(keyword "")` reach the
   interner directly; the language raises `:invalid-argument`.
8. **Bounded id space.** An intern that would take a table past
   `maxInt(u32)` entries returns `error.InternTableFull`, so the id
   cast cannot truncate.

`test/prop/intern.zig` I1–I10 check invariants 1–5, the qualified
split (§3) and the map/list lockstep (§4) over random names.

---

### 2. Public API

| `Interner` member | Contract |
|---|---|
| `init(gpa)`, `deinit()` | Empty tables; `deinit` frees every name |
| `internKeyword(name) !u32`, `internSymbol(name) !u32` | The dense id (§1) |
| `internKeywordValue(name) !Value`, `internSymbolValue(name) !Value` | The same, wrapped as a Value |
| `internQualifiedKeyword(ns, name) !Value`, `internQualifiedSymbol(ns, name) !Value` | Interns `ns/name`, or `name` when `ns` is null (§3) |
| `splitQualified(full)` | `{ ns: ?[]const u8, name: []const u8 }`, without allocating (§3) |
| `keywordName(id)`, `symbolName(id)` | The name. An out-of-range id panics in every build mode: every id comes from the table, so a bad one is a runtime bug, not a user error |
| `keywordCount()`, `symbolCount()` | The table sizes |
| `nameRecordType(type_id, ns, name) !void` | Names a record type `ns.name`, the printer's source for `#ns.Type{...}` (`docs/PROTOCOLS.md` §2.1); naming an id again renames it |
| `recordTypeName(type_id) ?[]const u8` | That name, or null for a type never named |

The intern calls fail with `error.OutOfMemory`, `error.EmptyName` or
`error.InternTableFull` (`InternError`); the stdlib maps `EmptyName`
to `:invalid-argument` and the other two to the VM's uncatchable
`OutOfMemory` (`docs/VM.md` §13). A failed intern leaves both tables
unchanged.

---

### 3. Qualified names

A qualified keyword or symbol is interned under its full text
`ns/name`. `internQualifiedKeyword` / `internQualifiedSymbol` build
that text; `splitQualified` takes it apart again at the **first**
slash, as Clojure's `namespace` and `name` do:

| Full text | `ns` | `name` |
|---|---|---|
| `"foo"` | null | `"foo"` |
| `"/"` | null | `"/"` |
| `"ns/foo"` | `"ns"` | `"foo"` |
| `"a/b/c"` | `"a"` | `"b/c"` |
| `"nexis.core//"` | `"nexis.core"` | `"/"` |

The bare `/` is the unqualified division symbol, not a qualification;
qualified, it is `nexis.core//` (Clojure's `clojure.core//`). The
returned slices point into the argument.

---

### 4. Internal shape

Each table is a `StringHashMapUnmanaged(u32)` from name to id and an
`ArrayListUnmanaged([]const u8)` from id to the owned copy of the
name; the map's key is that copy, never a slice of the list's backing
array, which moves when the list grows. `internInto`, shared by both
tables, rejects an empty name, returns an existing id on a hit, checks
the bound, then copies the name, appends it and inserts it, each step
undone by an `errdefer` if a following step fails. Both `internInto` and
`deinit` assert that the map and the list have the same length.

---

### 5. Interaction with other layers

- **Value layer.** `Value.fromKeywordId` / `fromSymbolId` do not
  validate an id; validity is this module's invariant. Equality and
  hashing read the id and never consult the interner.
- **Codec.** A keyword or symbol is written as its name and re-interned
  when decoded; ids never leave the process (`docs/CODEC.md`).
- **Collector.** Names are plain allocations, not heap blocks; the
  collector never visits the interner (`docs/GC.md` §2).
- **Namespaces.** Vars and namespaces live in `src/vm.zig`; the
  interner holds only the text of a qualified name.

Symbols carry no metadata (SEMANTICS §7), and strings are not interned.
