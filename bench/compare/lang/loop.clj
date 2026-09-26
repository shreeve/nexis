; 1M iterations of loop/recur arithmetic.
(let [t0 (now)
      r (loop [i 0 acc 0]
          (if (< i 1000000)
            (recur (inc i) (+ acc (mod (* i i) 7)))
            acc))]
  (report t0 r))
