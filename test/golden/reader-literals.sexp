(program
  (int 42)
  (int -7)
  (int 51966)
  (int 22)
  (real 3.14)
  (real -2.5)
  (real 1000000000)
  (real 0.0015)
  (real 15000000000)
  (string "hello")
  (string "tab\there")
  (string "newline\n")
  (string "quote\"inside")
  (string "snowman \u{E2}\u{98}\u{83}")
  (char \a)
  (char \Z)
  (char \0)
  (char \newline)
  (char \space)
  (char \tab)
  (char \return)
  (char \formfeed)
  (char \backspace)
  (char \u{2603})
  (keyword :plain)
  (keyword :ns/name)
  (keyword :some-kw)
  (keyword :?pred)
  (keyword :a.b.c)
  (keyword :-minus)
  (keyword :->>)
  (keyword :-)
  (symbol nexis)
  (symbol nexis.core/foo)
  (symbol ->>)
  (symbol <=)
  (symbol set!)
  (symbol +)
  (symbol -foo)
  (symbol *earmuffs*)
  nil
  (bool true)
  (bool false)
  (list (symbol a) (symbol b) (symbol c))
  (vector (int 1) (int 2) (int 3))
  (map (keyword :a) (int 1) (keyword :b) (int 2))
  (set (keyword :x) (keyword :y) (keyword :z))
  (list)
  (vector)
  (map)
  (set)
  (quote (symbol x))
  (quote
    (list (int 1) (int 2)))
  (syntax-quote
    (list
      (symbol inc)
      (unquote (symbol x))))
  (syntax-quote
    (list
      (symbol inc)
      (unquote-splicing (symbol xs))))
  (deref (symbol r))
  (#%anon-fn (symbol +) (symbol %1) (symbol %2))
  (#%anon-fn (symbol +) (symbol %) (int 1))
  (with-meta
    (symbol x)
    (map (keyword :private) (bool true)))
  (with-meta
    (symbol y)
    (map (keyword :doc) (string "hello")))
  (with-meta
    (symbol z)
    (map (keyword :tag) (symbol String)))
  (with-meta
    (symbol *out*)
    (map (keyword :doc) (string "stacked") (keyword :dynamic) (bool true)))
  (with-meta
    (vector (int 1) (int 2) (int 3))
    (map (keyword :frozen) (bool true)))
  (with-meta
    (map (keyword :a) (int 1))
    (map (keyword :origin) (keyword :user)))
  (with-meta
    (set (keyword :x) (keyword :y))
    (map (keyword :sorted) (bool true)))
  (with-meta
    (list
      (symbol fn)
      (vector (symbol x))
      (symbol x))
    (map (keyword :annotated) (bool true)))
  (list (symbol +) (int 1) (int 2))
  (list (symbol +) (int 3) (int 4))
  (symbol d)
  (vector (int 1) (int 2) (int 3) (int 4))
  (#%anon-fn (symbol %))
  (#%anon-fn (symbol inc) (symbol %))
  (#%anon-fn (symbol +) (symbol %1) (symbol %2) (symbol %&))
  (syntax-quote
    (list
      (symbol a)
      (unquote (symbol b))
      (unquote-splicing (symbol cs))))
  (syntax-quote
    (list
      (symbol outer)
      (syntax-quote
        (list
          (symbol inner)
          (unquote (symbol x)))))))
