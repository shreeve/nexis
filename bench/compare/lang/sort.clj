; sort 1M distinct ints in scrambled order (i * 7919 mod 1000003); the
; input is built before the clock starts.
(let [xs (mapv (fn [i] (mod (* i 7919) 1000003)) (range 1000000))
      t0 (now)
      sorted (sort xs)]
  (report t0 (str (first sorted) "/" (nth (vec sorted) 500000) "/" (last sorted))))
