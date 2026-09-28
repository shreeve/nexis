; bench/compare/prelude.clj — prepended to every lang/*.clj body for
; babashka and JVM Clojure (docs/BENCH.md §12); the twin of prelude.nx.
(require '[clojure.string :as s])
(defn now [] (System/nanoTime))
(defn split-comma [x] (s/split x #","))
(defn report [t0 answer]
  (println (str "phase=main ns=" (- (now) t0) " answer=" answer)))
