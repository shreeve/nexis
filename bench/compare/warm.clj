; bench/compare/warm.clj — the warm JVM Clojure run of a language
; workload (docs/BENCH.md §12). PROGRAM is the same file `bb` and
; `clojure -M` run cold: prelude.clj and a lang/*.clj body. Its forms
; but the last are evaluated once; the last, the timed `let`, becomes a
; function, called WARMUP times and then TIMED times with `report`
; recording instead of printing. Prints `phase=warm` with the median of
; the timed calls and their one answer.
; Usage: clojure -M warm.clj PROGRAM WARMUP TIMED

(require '[clojure.java.io :as io])

(let [[path warmup timed] *command-line-args*
      warmup (parse-long warmup)
      timed (parse-long timed)
      forms (with-open [r (java.io.PushbackReader. (io/reader path))]
              (doall (take-while #(not= % ::eof) (repeatedly #(read {:eof ::eof} r)))))
      _ (doseq [f (butlast forms)] (eval f))
      body (eval (list 'fn [] (last forms)))
      result (atom nil)]
  (intern 'user 'report (fn [t0 answer] (reset! result [(- (System/nanoTime) t0) answer])))
  (dotimes [_ warmup] (body))
  (let [runs (vec (for [_ (range timed)] (do (body) @result)))
        ns (vec (sort (map first runs)))
        answers (distinct (map (comp str second) runs))]
    (when (not= 1 (count answers))
      (println "warm runs disagree:" answers)
      (System/exit 1))
    (println (str "phase=warm ns=" (nth ns (quot (dec (count ns)) 2)) " answer=" (first answers)))))
