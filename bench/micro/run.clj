#!/usr/bin/env bb
;; bench/micro/run.clj — the interpreter's micro kit (docs/BENCH.md §13):
;; what one iteration, call or element of a micro program costs, in
;; machine instructions retired and cycles, for one or more builds of
;; bin/nexis side by side.
;;
;;   bb bench/micro/run.clj [--rounds 5] [--programs count,fib,...]
;;                          [--counter time|perf] [--events E,...]
;;                          [--pin CPU] [--out FILE.json] BIN [BIN...]
;;
;; Every program runs at two sizes; its cost per unit is
;; (I(hi) - I(lo)) / units, so startup, compilation and the printing
;; cancel. A unit is an iteration or an element, a call for fib.nx and
;; afib.nx.
;; Rounds interleave: each round runs every (binary, program, size)
;; once, the order rotated by one each round, and the cost is the
;; median over the rounds of each round's pair, with the range. The
;; callback programs also print their cost less cbbase's, the setup
;; they share, when cbbase runs too. Counters come from `/usr/bin/time
;; -l` on macOS (--counter time, the default) or from `perf stat` on
;; Linux (--counter perf), whose --events, comma-separated, are counted
;; too and printed per unit after the instructions and cycles; --pin
;; runs each process on one CPU with taskset (Linux). Run it under the machine's
;; core queue and keep the load average beside the numbers: it prints
;; the load at the start and the end. --out writes every run's counters
;; as JSON.

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def here (str (fs/parent (fs/absolutize *file*))))

(def programs
  "Each program and its two sizes."
  (let [m5 [5000000 10000000] cb [1000000 2000000]]
    (array-map "count" m5 "acc" m5 "fib" [27 30] "gcall" m5 "lc" m5 "lv" m5
               "mv" m5 "mvc" m5 "kw" m5 "leaf" m5 "getnl" m5 "leaf1" m5 "vnth" m5 "vdestr" m5 "pcall" m5 "casek" m5 "mcall" m5
               "acall" m5 "vcall" m5 "afib" [27 30]
               "cbbase" cb "cbsum" cb "cbred" cb "cb" cb "lazy" cb "xform" cb "cbfilt" cb "cbrange" cb
               "lazy3" [1500000 3000000] "lazyl" [1500000 3000000] "lazyf" [1500000 3000000])))

(def callback-programs #{"cbsum" "cbred" "cb" "lazy" "xform" "cbfilt"})

(defn fib-calls
  "The calls (fib n) makes, itself included: 2 F(n+1) - 1."
  [n]
  (loop [i 0 a 0 b 1] (if (> i n) (dec (* 2 a)) (recur (inc i) b (+ a b)))))

(defn units [prog lo hi]
  (case prog
    "fib" (- (fib-calls hi) (fib-calls lo))
    ;; Every step is two calls, one into each clause.
    "afib" (* 2 (- (fib-calls hi) (fib-calls lo)))
    (- hi lo)))

(def perf-events
  "perf's events by default: those of a hybrid Intel core's P-cores."
  "cpu_core/instructions/u,cpu_core/cycles/u,cpu_core/br_misp_retired.indirect/u,cpu_core/ld_blocks.store_forward/u")

(defn parse-args [args]
  (loop [o {:rounds 5 :programs (keys programs) :bins [] :counter "time" :events perf-events} [a & more] args]
    (case a
      nil o
      "--rounds" (recur (assoc o :rounds (parse-long (first more))) (rest more))
      "--programs" (recur (assoc o :programs (str/split (first more) #",")) (rest more))
      "--counter" (recur (assoc o :counter (first more)) (rest more))
      "--events" (recur (assoc o :events (first more)) (rest more))
      "--pin" (recur (assoc o :pin (first more)) (rest more))
      "--out" (recur (assoc o :out (first more)) (rest more))
      (recur (update o :bins conj a) more))))

(def opts (parse-args *command-line-args*))
(def os (case (System/getProperty "os.name") "Mac OS X" "time" "Linux" "perf" nil))
(when (or (empty? (:bins opts)) (not= os (:counter opts)))
  (binding [*out* *err*]
    (println "usage: bb bench/micro/run.clj [--rounds N] [--programs a,b] [--counter time|perf] [--events E,...] [--pin CPU] [--out FILE.json] BIN [BIN...]")
    (println "  --counter time (the default) runs on macOS, --counter perf on Linux"))
  (System/exit 2))
(when-let [bad (seq (remove programs (:programs opts)))]
  (binding [*out* *err*] (println "unknown programs:" (str/join "," bad) "; known:" (str/join "," (keys programs))))
  (System/exit 2))

(defn load-avg []
  (str/trim (if (= os "time")
              (:out (p/sh "sysctl" "-n" "vm.loadavg"))
              ;; slurp reads nothing from /proc.
              (str/join " " (take 3 (str/split (:out (p/sh "cat" "/proc/loadavg")) #" "))))))

(defn counter [err label]
  (some-> (re-find (re-pattern (str "(\\d+)\\s+" label)) err) second parse-long))

(def events (when (= "perf" (:counter opts)) (str/split (:events opts) #",")))

(defn event-name
  "An event's column name: without its PMU and modifiers."
  [e]
  (-> e (str/replace #"^[a-z_]+/" "") (str/replace #"[/:][a-z]*$" "")))

(def extra-events
  "The events printed after the instructions and cycles."
  (remove #{"instructions" "cycles"} (map event-name events)))

(defn read-perf
  "perf stat -x, output: each event's count by its column name."
  [text]
  (into {} (for [line (str/split-lines text)
                 :let [[v _ e] (str/split line #",")]
                 :when (and e (not (str/starts-with? line "#")))]
             [(event-name e) (parse-long v)])))

(def tmp (str (fs/create-temp-dir {:prefix "micro-"})))

(defn command [bin prog size]
  (let [run [bin "run" (str here "/" prog ".nx") (str size)]
        pin (if-let [cpu (:pin opts)] ["taskset" "-c" cpu] [])]
    (if (= os "time")
      (concat pin ["/usr/bin/time" "-l"] run)
      (concat ["/usr/bin/time" "-f" "%M" "-o" (str tmp "/rss")] pin
              ["perf" "stat" "-x," "-e" (:events opts) "-o" (str tmp "/perf")] run))))

(defn run-one [bin prog size]
  (let [t0 (System/nanoTime)
        r (apply p/sh (command bin prog size))
        wall (- (System/nanoTime) t0)]
    (when-not (zero? (:exit r))
      (throw (ex-info (str bin " " prog " " size " exited " (:exit r) ": " (:err r)) {})))
    (merge
     {:wall wall :out (str/trim (:out r))}
     (if (= os "time")
       {:ins (counter (:err r) "instructions retired")
        :cyc (counter (:err r) "cycles elapsed")
        :rss (counter (:err r) "maximum resident set size")}
       (let [c (read-perf (slurp (str tmp "/perf")))]
         {:ins (c "instructions")
          :cyc (c "cycles")
          ;; GNU time's %M is in KiB.
          :rss (* 1024 (parse-long (str/trim (last (str/split-lines (slurp (str tmp "/rss")))))))
          :events (select-keys c extra-events)})))))

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
(defn fmt-small [xs] (format "%.3f [%.3f-%.3f]" (double (median xs)) (double (apply min xs)) (double (apply max xs))))

(println (str "| binary | program | units | instructions / unit | cycles / unit | "
              (str/join (map #(str % " / unit | ") extra-events))
              "wall at hi (median) | max RSS at hi |"))
(println (str "|---|---|---:|---:|---:|" (str/join (repeat (count extra-events) "---:|")) "---:|---:|"))
(doseq [b (:bins opts) prog (:programs opts)]
  (let [[lo hi] (programs prog)
        his (results [b prog hi])
        metrics (concat [:ins :cyc] (map (fn [e] #(get-in % [:events e])) extra-events))
        row (fn [name [ins cyc & more]]
              (println (format "| %s | %s | %d | %s | %s | %s%.2f ms | %.1f MB |" (label b) name (units prog lo hi)
                               (fmt-range ins) (fmt-range cyc)
                               (str/join (map #(str (fmt-small %) " | ") more))
                               (/ (median (map :wall his)) 1e6) (/ (apply max (map :rss his)) 1e6))))]
    (row prog (map #(per-unit b prog %) metrics))
    (when (and (callback-programs prog) (some #{"cbbase"} (:programs opts)))
      (row (str prog " - cbbase")
           (map #(mapv - (per-unit b prog %) (per-unit b "cbbase" %)) metrics)))))

(fs/delete-tree tmp)

(when-let [out (:out opts)]
  (spit out (json/generate-string
             {:rounds (:rounds opts) :load_start load-start :load_end load-end
              :runs (for [[[b prog size] runs] results] {:bin b :program prog :size size :runs runs})}
             {:pretty true})))
