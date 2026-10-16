# nexis for VS Code

Syntax highlighting for nexis source files (`.nx`): comments, strings and
regex literals, characters, keywords, numbers (`##Inf` and `##NaN` too),
`nil`/`true`/`false`, tags such as `#inst`, reader macros, brackets, and
the special forms and core macros where they head a form, with the name a
`def`, `defn` or `defmacro` defines.

The grammar and language configuration are generated from nexis's
`nexis.grammar` by Nexus (`nexus --highlight all nexis.grammar editors`);
see `editors/README.md` in the nexis repository.
