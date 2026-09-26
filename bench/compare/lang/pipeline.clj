; map/filter/reduce over 1M small maps, built before the clock starts.
; nexis sequences are eager (PLAN §23 #14): each stage builds its whole
; result; babashka's are lazy and chunked.
(let [rows (mapv (fn [i] {:id i :group (mod i 10) :score (mod (* i 31) 1000)}) (range 1000000))
      t0 (now)
      r (->> rows
             (filter (fn [row] (even? (:group row))))
             (map :score)
             (map inc)
             (reduce +))]
  (report t0 r))
