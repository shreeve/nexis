;; Generates test/regex/corpus.json, the differential corpus of the
;; regex engine (docs/REGEX.md §7): random patterns from a grammar of
;; the constructs nexis supports and random inputs, each run through
;; java.util.regex's find loop by the JVM that runs this script.
;; Run from the repository root (the run is deterministic per seed):
;;   bb test/regex/corpus.clj > test/regex/corpus.json
;; Each line is [pattern, input, result]: result is the list of every
;; find's groups (null for a group that did not take part), "ERR" when
;; Java refuses the pattern, or "TIMEOUT" when Java runs past a second.

(require '[cheshire.core :as json])

(def seeds [7 11 13])
(def per-seed 3000)

(def ^:dynamic ^java.util.Random *rng* nil)
(defn pick [xs] (nth xs (.nextInt *rng* (count xs))))
(defn chance [n] (zero? (.nextInt *rng* n)))

(def atoms
  ["a" "b" "x" "é" "É" "😀" "\\n" "\\r" "." "[ab]" "[^a]" "[a-c&&[^b]]" "\\w" "\\s" "\\d" "\\W" "\\v" "\\h"
   "\\R" "\\p{Alpha}" "[\\w&&[^\\d]]" "[é😀]" "[^é]" "\\x{1F600}" "\\Q.x\\E" "\\p{L}" "\\p{Lu}" "\\pN" "\\P{L}"
   "[\\p{L}&&[^a]]" "\\u0301" "(?i:a)" "(?i:É)" "(?iu:é)" "(?iu:ſ)" "(?iu:[r-t])" "(?iu:ß)" "(?iu:xς)" "K"])
(def asserts ["^" "$" "\\b" "\\B" "\\A" "\\z" "\\Z" "\\G"])
(def quants ["*" "+" "?" "{2}" "{1,}" "{0,2}" "{1,3}"])
(def flag-groups ["(?m:" "(?s:" "(?d:" "(?-i:" "(?i:" "(?x:" "(?iu:"])

(def names (atom 0))

(defn gen [depth]
  (let [r (.nextInt *rng* 10)]
    (cond
      (or (<= depth 0) (< r 4)) (if (chance 5) (pick asserts) (pick atoms))
      (< r 6) (apply str (repeatedly (inc (.nextInt *rng* 3)) #(gen (dec depth))))
      (< r 7) (str (gen (dec depth)) "|" (gen (dec depth)))
      (< r 9) (let [q (pick quants)]
                (str (pick [(str "(" (gen (dec depth)) ")")
                            (str "(?:" (gen (dec depth)) ")")
                            (pick atoms)])
                     q (if (chance 3) "?" "")))
      :else (str (pick ["(" "(?:" (str "(?<n" (swap! names inc) ">") (pick flag-groups)])
                 (gen (dec depth)) ")"))))

(def pieces ["a" "b" "x" "1" " " "é" "É" "😀" "\n" "\r\n" "\r" " " "A" "́" "ſ" "ß" "ẞ" "ς" "Σ" "K"])

(defn deadline-seq [^String s ^long until]
  (reify CharSequence
    (length [_] (.length s))
    (charAt [_ i]
      (when (> (System/nanoTime) until) (throw (ex-info "timeout" {:timeout true})))
      (.charAt s i))
    (subSequence [_ a b] (.subSequence s a b))
    (toString [_] s)))

(defn high? [^String s i] (and (pos? i) (< i (count s)) (Character/isHighSurrogate (.charAt s (dec i)))))

(defn run-java [p ^String s]
  (try
    (let [m (re-matcher (re-pattern p) (deadline-seq s (+ (System/nanoTime) 1000000000)))]
      (loop [acc []]
        (if (.find m)
          (let [st (.start m) en (.end m)]
            (cond
              ;; An empty match inside a surrogate pair: nexis steps by code points.
              (and (= st en) (high? s st)) (recur acc)
              (or (high? s st) (high? s en)) :skip
              :else (recur (conj acc (vec (for [i (range (inc (.groupCount m)))] (.group m (int i))))))))
          acc)))
    (catch java.util.regex.PatternSyntaxException _ "ERR")
    (catch clojure.lang.ExceptionInfo e (if (:timeout (ex-data e)) "TIMEOUT" (throw e)))))

;; Regressions the grammar rarely reaches, run after the random cases.
(def hand-written
  [;; Every thread dies at an assertion before the first-byte prefilter skips.
   ["(?:\\ba)*\\bc" "ab c ab c"]])

(doseq [seed seeds]
  (binding [*rng* (java.util.Random. seed)]
    (loop [n 0]
      (when (< n per-seed)
        (let [p (gen 5)
              s (apply str (repeatedly (.nextInt *rng* 8) #(pick pieces)))
              r (run-java p s)]
          (if (= r :skip)
            (recur n)
            (do (println (json/generate-string [p s r])) (recur (inc n)))))))))

(doseq [[p s] hand-written]
  (println (json/generate-string [p s (run-java p s)])))
