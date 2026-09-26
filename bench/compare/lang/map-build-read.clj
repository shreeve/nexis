; Build a 1M-entry persistent hash map with int keys by assoc, then
; read every key back.
(let [t0 (now)
      m (reduce (fn [m i] (assoc m i (* 2 i))) {} (range 1000000))
      total (reduce (fn [acc i] (+ acc (get m i))) 0 (range 1000000))]
  (report t0 (str (count m) "/" total)))
