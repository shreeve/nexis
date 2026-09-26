; conj 1M ints onto a persistent vector, then nth every index.
(let [t0 (now)
      v (reduce conj [] (range 1000000))
      total (reduce (fn [acc i] (+ acc (nth v i))) 0 (range 1000000))]
  (report t0 (str (count v) "/" total)))
