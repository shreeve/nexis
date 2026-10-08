# test/portable — stores carried between hosts

`write.nx` writes two stores into the working directory:

- `refs.edb`, a `db/*` store (`docs/DB.md`): a value of every
  serializable kind (`docs/CODEC.md` §3) and the edges of the numeric
  ones, keys up to the 4078-byte bound, a 6000-key tree thinned by
  deletes and overwrites, and values that span overflow pages;
- `nextomic.edb`, a Nextomic store (`docs/NEXTOMIC.md` §2) with data
  in all twelve trees: every value type, out-of-line strings and bytes,
  longs past the fixnum range, card-many and component refs, history
  with retractions, a rename (a retired name in `nx/idents`), two
  excisions, `:db/fulltext` on two attributes, one of them added to a
  populated attribute, and a `retractEntity`.

`read.nx` prints the canonical dump of both: every ref and value of
the small trees and a digest and sample of the large ones, then the
schema, every index current and in history (counts and a hash), the
datoms of the people in full, entities, `q` results, `index-range`,
`pull`, `as-of`, `since`, `history`, fulltext hits from the stored
rows and from a re-tokenised past view, and `tx-range`. The dump is a
function of the stores' contents alone: every instant but the
bootstrap transaction's is explicit, and the digests leave that one
datom out.

`zig build portable` (part of `zig build test`) runs both from a fresh
directory on the host that builds, `NEXIS_GC_STRESS=1`, and compares
their output with `write.out` and `read.out`.

## Across hosts

Proves that a store written on one host reads the same on another. Two
hosts, A and B, each with a checkout at the same commit, `../emdb`
beside it at the same commit, and `zig build install` run in it. On
each host, from the checkout root:

```sh
R=$PWD
D=$HOME/portable-run    # a directory only its owner writes, not /tmp (docs/DB.md §3.1)
rm -rf "$D" && mkdir -p "$D/own" "$D/theirs"
(cd "$D/own" && "$R/bin/nexis" run "$R/test/portable/write.nx")
(cd "$D/own" && "$R/bin/nexis" run "$R/test/portable/read.nx") > "$D/own.dump"
```

Copy each host's two store files, without their `-lock` files, into
the other's `theirs`, from A:

```sh
scp "$D/own/refs.edb" "$D/own/nextomic.edb" B:portable-run/theirs/
scp B:portable-run/own/refs.edb B:portable-run/own/nextomic.edb "$D/theirs/"
```

Then on each host, with `R` and `D` as before, read the other host's
stores with the files read-only, so a write would fail rather than
pass unseen, and check that the read left them as they came:

```sh
chmod a-w "$D/theirs/"*.edb
(cd "$D/theirs" && shasum -a 256 refs.edb nextomic.edb > ../theirs.sha)
(cd "$D/theirs" && "$R/bin/nexis" run "$R/test/portable/read.nx") > "$D/theirs.dump"
(cd "$D/theirs" && shasum -a 256 -c ../theirs.sha)
cmp "$D/own.dump" "$R/test/portable/read.out" && cmp "$D/theirs.dump" "$R/test/portable/read.out"
```

All four dumps (each host's own stores and the other's) must be the
bytes of `read.out`. `sha256sum` stands in for `shasum -a 256` where
only it is installed. A difference is a portability bug: the line
that differs names the tree or the read that sees it.

The hosts of record are macOS arm64 and Linux x86_64; `HANDOFF.md`
§6.4 gives the run.
