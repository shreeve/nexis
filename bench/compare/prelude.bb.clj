; bench/compare/prelude.bb.clj — prepended to every lang/*.clj body for
; babashka (docs/BENCH.md §12); the twin of prelude.nx.
(require '[clojure.string :as s])
(defn now [] (System/nanoTime))
(defn split-comma [x] (s/split x #","))
(defn report [t0 answer]
  (println (str "phase=main ns=" (- (now) t0) " answer=" answer)))
