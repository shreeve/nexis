# FileMan on Nextomic — a design note

A proposal, not a module spec: how VistA's FileMan data, kept in MUMPS
globals by em, can gain Nextomic's time model (every fact kept,
every past state readable, provenance on every change) without
changing VistA. Nothing here is built; `TODO.md` tracks it.

---

## 1. Why

FileMan keeps the current value of each field. History exists only
where someone switched on field auditing (`^DIA`) for that field, and
only in the shape the audit file records. Clinical, laboratory and
billing questions are about time:

- What did the chart show when the order was signed?
- Which results did the 09:00 interface feed change, and to what?
- What did last month's report see, exactly?

Nextomic answers each with one call (`as-of`, `history`, a transaction
entity carrying who and why), because a fact is never overwritten: a
change adds a datom and retracts the old one, and both stay readable
(`docs/NEXTOMIC.md` §4).

## 2. The mapping

FileMan is already a schema-driven entity–attribute–value store, so the
mapping is nearly one to one.

| FileMan | Nextomic |
|---|---|
| File number and name (`^DIC`), e.g. PATIENT (#2) | an attribute namespace, `:patient/...`, and a `:fm/file` fact on each entity |
| Entry (IEN) in a file | an entity; `:fm/ien` and `:fm/file` together are its unique identity (a tuple, or a composed string `"2,1001"` while tuples are absent) |
| Field (`^DD(file,field)`) | an attribute named from the field's name, carrying `:fm/field` (the number) and `:db/doc` (the description) |
| Free text, word processing | `:db.type/string` (a word-processing field: one string, lines joined) |
| Numeric | `:db.type/long` or `:db.type/double` by the field's decimal digits |
| Date/time (FileMan internal `YYYMMDD.HHMMSS`) | `:db.type/instant`, converted; the original kept in a `:fm/...-raw` attribute where imprecise dates (month or year only) occur |
| Set of codes | `:db.type/keyword`, one keyword per code |
| Pointer to a file | `:db.type/ref` to the target file's entity |
| Variable pointer | `:db.type/ref`; the target file is the target entity's own `:fm/file` |
| Multiple (sub-file) | component entities (`:db/isComponent`) referenced from the parent, or a cardinality-many attribute for a single-field multiple |
| Computed field | not stored: computed on read, as FileMan does |
| Cross-references ("B", "AC", ...) | the AVET and VAET indexes (`:db/index true`); `:db/unique` only where the file truly forbids duplicates |
| Field audit (`^DIA`) | every attribute's history, always on; who and why on the transaction entity |

The schema is generated, not written: a reader walks `^DD` for each file
and emits Nextomic schema transactions, and a later change to `^DD`
becomes a schema transaction too, so the data dictionary itself has a
history.

## 3. Three ways to combine them

From least to most invasive.

### 3.1 A temporal mirror (the first step)

VistA and FileMan run unchanged. Every FileMan write is captured and
transacted into a Nextomic store beside em's `mumps.db`, each
transaction tagged with its provenance (`:audit/user` the DUZ,
`:audit/option`, `:audit/source` such as an HL7 message control id,
`:audit/at`).

Capture, in order of preference:

1. **em's own write path**: a hook on global SET and KILL for the files
   being mirrored, appending `(global, subscripts, old, new, $J, DUZ)`
   records to a journal the mirror reads. This is an em feature (em's
   repo, em's owner); nexis only consumes the journal.
2. **FileMan's API**: a wrapper around `FILE^DIE` and `UPDATE^DIE` that
   records each call's FDA. It misses direct global sets, which VistA
   code does make.
3. **Snapshot diffs**: read the globals at intervals and diff. It needs
   no hook but loses order inside an interval and misses values that
   came and went between reads.

The mirror is one nexis program: read `^DD`, generate the schema, read
the journal, translate node changes into datoms (a FileMan node holds
several fields as `^`-pieces, so one SET can be several datoms), and
transact. The store is a separate file: em sizes its pages by platform
(16 KB on Apple silicon, 4 KB on x86_64 Linux) and nexis pins 16 KB, and
emdb fixes a file's page size for its life, so the two never share a
file.

What it gives, on real VistA data, read-only: as-of reads of any mirrored
file, per-field history with provenance, Datalog across files, and `with`
to trial a correction.

### 3.2 FileMan's API over Nextomic

`$$GET1^DIQ`, `GETS^DIQ`, `FILE^DIE` and `UPDATE^DIE` implemented over a
Nextomic store, so FileMan-aware code reads and writes facts and gains
time travel with no change of its own. The effort is FileMan's long tail:
input transforms, MUMPS-code cross-references, triggers, and code that
bypasses the API. A later step, if 3.1 proves the value.

### 3.3 History-keeping globals in em

If em kept a history for global nodes, as Nextomic keeps history trees
beside its current ones, every M application, FileMan included, could
read a global as of a past time with no application change. The most
powerful option and the most invasive: it is em's design, decided in
em's repository.

## 4. A first demonstration

1. Generate the schema for PATIENT (#2) and a laboratory results file
   from their `^DD`.
2. Load a test VistA's entries for those files as the first transaction.
3. Replay a day of changes (a journal, or a scripted day of FileMan
   edits) as tagged transactions.
4. Show: a result's value at 09:00 and at 15:00; the history of one
   field with who changed it and from which HL7 message; a cross-file
   Datalog query ("patients with a critical potassium whose result was
   later corrected"); a `with` trial of a correction.

## 5. Open questions

- **Identity across files**: `:fm/file` plus `:fm/ien` as a composed
  unique string until Nextomic has tuple attributes.
- **Imprecise dates**: FileMan stores month-only and year-only dates;
  an instant loses that, so keep the raw form beside it.
- **Word processing**: one string per field, or one entity per line
  (FileMan keeps lines); one string reads better, lines diff better.
- **Deletion of protected health information**: a store that never
  forgets needs a retention policy; Nextomic's excision
  (`d/excise!`, `docs/NEXTOMIC.md` §4) removes an entity's datoms from
  every index and the transaction log, and a mirror must apply it when
  VistA purges.
- **Volume**: the history grows with every edit; measure on a real day's
  journal before choosing which files to mirror.
- **Capture point**: which of §3.1's three, which depends on what em
  can expose and on the deployment.
