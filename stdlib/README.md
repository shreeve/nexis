# stdlib

The standard library's nexis sources are in `src/stdlib/` (`core.nx`,
`nextomic.nx`, `walk.nx`, `edn.nx`, `test.nx`, `pprint.nx`, `math.nx`,
`string.nx`, `set.nx`); its natives are in `src/stdlib.zig`, and the
image the build makes of them in `src/image.zig` and `src/imagegen.zig`. `docs/STDLIB.md` §1
describes the namespaces, the boot order and the rules for the
embedded sources.
