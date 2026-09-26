; 1M calls of a function destructuring a map and a vector argument.
(defn step [{:keys [a b]} [x y & more]]
  (+ a b x y (count more)))
(let [t0 (now)
      r (loop [i 0 acc 0]
          (if (< i 1000000)
            (recur (inc i) (+ acc (step {:a i :b 1} [i 2 3])))
            acc))]
  (report t0 r))
