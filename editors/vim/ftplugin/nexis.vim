" Vim ftplugin for nexis: comments and Lisp indentation.
" Language: nexis

if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal commentstring=;\ %s
setlocal comments=:;;;,:;;,:;
setlocal lisp
setlocal iskeyword+=-,?,!,*,+,/,<,>,=

let b:undo_ftplugin = "setlocal commentstring< comments< lisp< iskeyword<"
