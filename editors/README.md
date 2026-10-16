# Editor support for nexis

Syntax highlighting for nexis source files in VS Code, Vim, highlight.js
and rip print. The grammars are generated from `nexis.grammar` by Nexus
(`nexus --highlight`), from its `@highlight` section; never edit a
generated file by hand. Each starts with a header naming the grammar it
came from.

| Directory | What it is |
|---|---|
| `vscode/` | A VS Code extension: `syntaxes/nexis.tmLanguage.json` and `language-configuration.json` (generated), `package.json`, `README.md` |
| `vim/` | A Vim plugin: `syntax/nexis.vim` (generated), `ftdetect/nexis.vim`, `ftplugin/nexis.vim` |
| `highlightjs/` | `nexis.js`, a highlight.js language module (generated) |

nexis's scanner is hand-written (`src/nexis.zig`), so every `@highlight`
entry is a pattern that follows it. An editor sees no parse: the special
forms and core macros are coloured where they head a form, after `(`.

## After a change to nexis.grammar's @highlight

Run these from the top of the repository, with Nexus checked out beside
it (`../nexus`).

1. Regenerate the editor files:

   ```sh
   ../nexus/bin/nexus --highlight all nexis.grammar editors
   ```

2. Check that all three colour the sample as `sample.nx.hl` says (the
   TextMate grammar through a vscode-textmate reference, the highlight.js
   language, and Vim itself). With `--update` before the paths, the check
   rewrites `sample.nx.hl` from the TextMate colouring; review that diff:

   ```sh
   python3 ../nexus/test/lib/highlight ../nexus/docs/GRAMMAR.md \
       editors/vscode/syntaxes/nexis.tmLanguage.json editors/highlightjs/nexis.js \
       editors/vim/syntax/nexis.vim test/highlight/sample.nx test/highlight/sample.nx.hl
   ```

## Installing

- VS Code: `cd editors/vscode && npx @vscode/vsce package`, then
  `code --install-extension vscode-nexis-0.1.0.vsix`; or link the
  directory into `~/.vscode/extensions/` while developing.
- Vim: add `editors/vim` to `runtimepath` (or link it into a pathogen
  `bundle/`).
- rip print: link `editors/highlightjs/nexis.js` into
  `~/.config/rip/print/languages/`.
