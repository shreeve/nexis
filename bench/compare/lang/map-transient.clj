; The same 1M-entry map built through a transient, then read back.
(let [t0 (now)
      m (persistent! (reduce (fn [m i] (assoc! m i (* 2 i))) (transient {}) (range 1000000)))
      total (reduce (fn [acc i] (+ acc (get m i))) 0 (range 1000000))]
  (report t0 (str (count m) "/" total)))
