; frequencies and group-by over 1M ints; the input is built before the
; clock starts.
(let [xs (mapv (fn [i] (mod (* i 7919) 1000003)) (range 1000000))
      t0 (now)
      f (frequencies (map (fn [x] (mod x 1000)) xs))
      g (group-by (fn [x] (mod x 100)) xs)]
  (report t0 (str (count f) "/" (get f 7) "/" (count g) "/" (count (get g 3)))))
