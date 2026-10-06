#!/usr/bin/env bb
;; bench/micro/run.clj — the interpreter's micro kit (docs/BENCH.md §13):
;; what one iteration, call or element of a micro program costs, in
;; machine instructions retired and cycles, for one or more builds of
;; bin/nexis side by side.
;;
;;   bb bench/micro/run.clj [--rounds 5] [--programs count,fib,...]
;;                          [--out FILE.json] BIN [BIN...]
;;
;; Every program runs at two sizes; its cost per unit is
;; (I(hi) - I(lo)) / units, so startup, compilation and the printing
;; cancel. A unit is an iteration or an element, a call for fib.nx.
;; Rounds interleave: each round runs every (binary, program, size)
;; once, the order rotated by one each round, and the cost is the
;; median over the rounds of each round's pair, with the range. The
;; callback programs also print their cost less cbbase's, the setup
;; they share, when cbbase runs too. Counters come from `/usr/bin/time
;; -l` (macOS only). Run it under the machine's core queue and keep the
;; load average beside the numbers: it prints the load at the start and
;; the end. --out writes every run's counters as JSON.

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def here (str (fs/parent (fs/absolutize *file*))))

(def programs
  "Each program and its two sizes."
  (let [m5 [5000000 10000000] cb [1000000 2000000]]
    (array-map "count" m5 "acc" m5 "fib" [27 30] "gcall" m5 "lc" m5 "lv" m5
               "mv" m5 "kw" m5 "leaf" m5 "getnl" m5
               "cbbase" cb "cbsum" cb "cbred" cb "cb" cb "lazy" cb
               "lazy3" [1500000 3000000])))

(def callback-programs #{"cbsum" "cbred" "cb" "lazy"})

(defn fib-calls
  "The calls (fib n) makes, itself included: 2 F(n+1) - 1."
  [n]
  (loop [i 0 a 0 b 1] (if (> i n) (dec (* 2 a)) (recur (inc i) b (+ a b)))))

(defn units [prog lo hi]
  (if (= prog "fib") (- (fib-calls hi) (fib-calls lo)) (- hi lo)))

(defn parse-args [args]
  (loop [o {:rounds 5 :programs (keys programs) :bins []} [a & more] args]
    (case a
      nil o
      "--rounds" (recur (assoc o :rounds (parse-long (first more))) (rest more))
      "--programs" (recur (assoc o :programs (str/split (first more) #",")) (rest more))
      "--out" (recur (assoc o :out (first more)) (rest more))
      (recur (update o :bins conj a) more))))

(def opts (parse-args *command-line-args*))
(when (or (empty? (:bins opts)) (not= "Mac OS X" (System/getProperty "os.name")))
  (binding [*out* *err*]
    (println "usage: bb bench/micro/run.clj [--rounds N] [--programs a,b] [--out FILE.json] BIN [BIN...]  (macOS)"))
  (System/exit 2))
(when-let [bad (seq (remove programs (:programs opts)))]
  (binding [*out* *err*] (println "unknown programs:" (str/join "," bad) "; known:" (str/join "," (keys programs))))
  (System/exit 2))

(defn load-avg [] (str/trim (:out (p/sh "sysctl" "-n" "vm.loadavg"))))

(defn counter [err label]
  (some-> (re-find (re-pattern (str "(\\d+)\\s+" label)) err) second parse-long))

(defn run-one [bin prog size]
  (let [t0 (System/nanoTime)
        r (p/sh "/usr/bin/time" "-l" bin "run" (str here "/" prog ".nx") (str size))
        wall (- (System/nanoTime) t0)]
    (when-not (zero? (:exit r))
      (throw (ex-info (str bin " " prog " " size " exited " (:exit r) ": " (:err r)) {})))
    {:ins (counter (:err r) "instructions retired")
     :cyc (counter (:err r) "cycles elapsed")
     :rss (counter (:err r) "maximum resident set size")
     :wall wall
     :out (str/trim (:out r))}))

(defn median [xs] (let [s (vec (sort xs)) n (count s)]
                    (if (odd? n) (s (quot n 2)) (/ (+ (s (dec (quot n 2))) (s (quot n 2))) 2.0))))

(def jobs (vec (for [b (:bins opts) prog (:programs opts) size (programs prog)] [b prog size])))
(def load-start (load-avg))

(def results
  (reduce (fn [acc r]
            (let [k (mod r (count jobs))]
              (reduce (fn [acc [b prog size]] (update acc [b prog size] (fnil conj []) (run-one b prog size)))
                      acc (concat (subvec jobs k) (subvec jobs 0 k)))))
          {} (range (:rounds opts))))

(def load-end (load-avg))

(defn per-unit
  "Each round's cost per unit of `metric` for bin and prog."
  [b prog metric]
  (let [[lo hi] (programs prog)
        n (units prog lo hi)]
    (mapv (fn [l h] (/ (- (metric h) (metric l)) (double n)))
          (results [b prog lo]) (results [b prog hi]))))

(defn label [b] (let [parts (str/split b #"/")] (if (> (count parts) 2) (nth parts (- (count parts) 3)) b)))

(defn fmt-range [xs] (format "%.1f [%.1f-%.1f]" (double (median xs)) (double (apply min xs)) (double (apply max xs))))

(doseq [prog (:programs opts) size (programs prog)
        :let [answers (set (for [b (:bins opts) r (results [b prog size])] (:out r)))]
        :when (not= 1 (count answers))]
  (println (str "answers differ: " prog " " size " " (pr-str answers))))
(println (str "rounds " (:rounds opts) "; load at start " load-start ", at end " load-end))
(println "| binary | program | units | instructions / unit | cycles / unit | wall at hi (median) | max RSS at hi |")
(println "|---|---|---:|---:|---:|---:|---:|")
(doseq [b (:bins opts) prog (:programs opts)]
  (let [[lo hi] (programs prog)
        his (results [b prog hi])
        row (fn [name ins cyc]
              (println (format "| %s | %s | %d | %s | %s | %.2f ms | %.1f MB |" (label b) name (units prog lo hi)
                               (fmt-range ins) (fmt-range cyc)
                               (/ (median (map :wall his)) 1e6) (/ (apply max (map :rss his)) 1e6))))]
    (row prog (per-unit b prog :ins) (per-unit b prog :cyc))
    (when (and (callback-programs prog) (some #{"cbbase"} (:programs opts)))
      (row (str prog " - cbbase")
           (mapv - (per-unit b prog :ins) (per-unit b "cbbase" :ins))
           (mapv - (per-unit b prog :cyc) (per-unit b "cbbase" :cyc))))))

(when-let [out (:out opts)]
  (spit out (json/generate-string
             {:rounds (:rounds opts) :load_start load-start :load_end load-end
              :runs (for [[[b prog size] runs] results] {:bin b :program prog :size size :runs runs})}
             {:pretty true})))
