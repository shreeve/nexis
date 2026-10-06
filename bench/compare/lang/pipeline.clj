; map/filter/reduce over 1M small maps, built before the clock starts.
; Every implementation's sequences are lazy and chunked by 32.
(let [rows (mapv (fn [i] {:id i :group (mod i 10) :score (mod (* i 31) 1000)}) (range 1000000))
      t0 (now)
      r (->> rows
             (filter (fn [row] (even? (:group row))))
             (map :score)
             (map inc)
             (reduce +))]
  (report t0 r))
