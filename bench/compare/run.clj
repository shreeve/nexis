#!/usr/bin/env bb
;; bench/compare/run.clj — the cross-implementation comparison harness
;; (docs/BENCH.md §12): nexis against babashka on language workloads,
;; Nextomic against Datalevin on database workloads.
;;
;;   bb bench/compare/run.clj --out DIR [--n 10] [--only lang,db]
;;                            [--workloads fib,sort,...] [--no-build]
;;                            [--max-load 4] [--smoke]
;;
;; Builds bin/nexis ReleaseFast, runs every workload once per
;; implementation to warm the file cache (discarded), then --n rounds,
;; the implementations alternating with the order rotated each round.
;; Every run is one process under /usr/bin/time -l; the script prints
;; `phase=NAME ns=N answer=A` lines timed inside the process, the
;; runner adds the process wall time and peak RSS. Every phase's
;; answer must be the same on every run of every implementation. A
;; workload whose 1-minute load average rose above --max-load while it
;; ran is discarded and repeated (up to 3 attempts, all kept in the
;; JSON); before a workload the runner waits for the load to fall.
;; --smoke allows --n below 10 and marks the report as a check, not a
;; measurement. Writes DIR/results.md, DIR/results.json and DIR/src/ (the exact
;; programs run).

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def here (fs/parent (fs/absolutize *file*)))
(def root (str (fs/parent (fs/parent here))))
(def nexis-bin (str root "/bin/nexis"))

;; ---------------------------------------------------------------- args

(defn parse-args [args]
  (loop [[a & more] args, o {:n 10 :max-load 4.0 :build true :only #{"lang" "db"}}]
    (case a
      nil o
      "--out" (recur (rest more) (assoc o :out (first more)))
      "--n" (recur (rest more) (assoc o :n (parse-long (first more))))
      "--max-load" (recur (rest more) (assoc o :max-load (parse-double (first more))))
      "--only" (recur (rest more) (assoc o :only (set (str/split (first more) #","))))
      "--workloads" (recur (rest more) (assoc o :workloads (set (str/split (first more) #","))))
      "--no-build" (recur more (assoc o :build false))
      "--smoke" (recur more (assoc o :smoke true))
      (do (println "unknown argument" a) (System/exit 2)))))

(def opts (parse-args *command-line-args*))
(when-not (:out opts)
  (println "usage: bb bench/compare/run.clj --out DIR [--n 10] [--only lang,db] [--workloads a,b] [--no-build] [--max-load 4]")
  (System/exit 2))
(when (and (< (:n opts) 10) (not (:smoke opts)))
  (println "--n below 10 is not a measurement (docs/BENCH.md §3); --smoke runs it as a check")
  (System/exit 2))

(def out-dir (str (fs/absolutize (:out opts))))
(def src-dir (str out-dir "/src"))
(def store-dir (str out-dir "/stores"))
(fs/create-dirs src-dir)

;; ---------------------------------------------------------------- host

(defn sh-out [& cmd]
  (str/trim (:out (p/sh cmd {:dir root}))))

(defn load-avg []
  ;; "{ 1.23 2.34 3.45 }"
  (let [[a b c] (map parse-double (re-seq #"[\d.]+" (sh-out "sysctl" "-n" "vm.loadavg")))]
    {:one a :five b :fifteen c}))

(defn host-info []
  {:cpu (sh-out "sysctl" "-n" "machdep.cpu.brand_string")
   :cores (parse-long (sh-out "sysctl" "-n" "hw.ncpu"))
   :ram_bytes (parse-long (sh-out "sysctl" "-n" "hw.memsize"))
   :os (str "macOS " (sh-out "sw_vers" "-productVersion") " (" (sh-out "sw_vers" "-buildVersion") ")")
   :kernel (sh-out "uname" "-r")})

(defn versions []
  {:nexis_commit (sh-out "git" "rev-parse" "HEAD")
   :nexis_dirty (not (str/blank? (sh-out "git" "status" "--porcelain" "--" "src" "build.zig" "build.zig.zon")))
   :nexis_optimize "ReleaseFast"
   :zig (sh-out "zig" "version")
   :bb (sh-out "bb" "--version")
   :dtlv (sh-out "dtlv" "--version")})

;; ---------------------------------------------------------------- workloads

(defn gen-lang [name]
  (let [body (slurp (str here "/lang/" name ".clj"))
        nx (str src-dir "/" name ".nx")
        bb (str src-dir "/" name ".clj")]
    (spit nx (str (slurp (str here "/prelude.nx")) "\n" body))
    (spit bb (str (slurp (str here "/prelude.bb.clj")) "\n" body))
    {:nexis {:runs [[nexis-bin "run" nx]]}
     :bb {:runs [["bb" bb]]}}))

(def lang-workloads
  (concat
   [{:name "startup" :kind :lang :rounds-factor 3
     :doc "process start to first output, -e '(+ 1 2)'"
     :impls (constantly {:nexis {:runs [[nexis-bin "-e" "(+ 1 2)"]] :answer-from-stdout true}
                         :bb {:runs [["bb" "-e" "(+ 1 2)"]] :answer-from-stdout true}})}]
   (for [f (sort (map str (fs/list-dir (str here "/lang"))))
         :let [name (str/replace (fs/file-name f) #"\.clj$" "")]]
     {:name name :kind :lang :impls (fn [] (gen-lang name))})))

(defn gen-dtlv [script store mode]
  (let [code (-> (slurp (str here "/db/" script))
                 (str/replace "@STORE@" store)
                 (str/replace "@MODE@" mode))
        f (str src-dir "/" (str/replace script #"\.clj$" "") (when (= mode "nosync") "-nosync") ".clj")]
    (spit f code)
    ["dtlv" "exec" code]))

(defn db-impls []
  (let [nx-store (str store-dir "/nexis/store.edb")
        nx-nosync (str store-dir "/nexis-nosync/store.edb")
        dl-store (str store-dir "/datalevin/db")
        dl-nosync (str store-dir "/datalevin-nosync/db")]
    {:nexis {:fresh [(str store-dir "/nexis") (str store-dir "/nexis-nosync")]
             :runs [[nexis-bin "run" (str here "/db/nexis-load.nx") nx-store "durable"]
                    [:size (str store-dir "/nexis")]
                    [nexis-bin "run" (str here "/db/nexis-query.nx") nx-store]
                    [nexis-bin "run" (str here "/db/nexis-load.nx") nx-nosync "nosync"]]}
     :datalevin {:fresh [(str store-dir "/datalevin") (str store-dir "/datalevin-nosync")]
                 :runs [(gen-dtlv "dtlv-load.clj" dl-store "durable")
                        [:size (str store-dir "/datalevin")]
                        (gen-dtlv "dtlv-query.clj" dl-store "durable")
                        (gen-dtlv "dtlv-load.clj" dl-nosync "nosync")]}}))

(def db-workloads
  [{:name "nextomic-vs-datalevin" :kind :db :impls db-impls}])

(def workloads
  (filter (fn [w] (and (contains? (:only opts) (name (:kind w)))
                       (or (nil? (:workloads opts)) (contains? (:workloads opts) (:name w)))))
          (concat lang-workloads db-workloads)))

;; ---------------------------------------------------------------- running

(defn parse-phases
  "The phase lines of a run's stdout as [name {:ns :answer}] pairs in
  order; `dtlv exec` may print a line more than once."
  [s]
  (distinct (for [[_ ph ns ans] (re-seq #"phase=(\S+) ns=(\d+) answer=([^\"\s]+)" s)]
              [ph {:ns (parse-long ns) :answer ans}])))

(defn du-bytes [path]
  ;; allocated blocks (du -k) and apparent size (sum of file lengths)
  {:allocated_bytes (* 1024 (parse-long (first (str/split (sh-out "du" "-sk" path) #"\s+"))))
   :apparent_bytes (reduce + (map fs/size (filter fs/regular-file? (file-seq (fs/file path)))))})

(defn run-process [cmd]
  (let [t0 (System/nanoTime)
        r (p/sh (into ["/usr/bin/time" "-l"] cmd) {:dir root})
        wall (- (System/nanoTime) t0)
        rss (some->> (re-find #"(\d+)\s+maximum resident set size" (:err r)) second parse-long)]
    {:cmd (let [c (vec cmd)] (if (= "exec" (get c 1)) ["dtlv" "exec" "<src>"] c))
     :exit (:exit r)
     :wall_ns wall
     :max_rss_bytes rss
     :phases (parse-phases (:out r))
     :stdout (:out r)
     :stderr (when-not (zero? (:exit r)) (:err r))}))

(defn run-impl
  "One run of an implementation: its processes in order, fresh stores
  first. Returns {:processes [...] :phases {...} :sizes {...}}."
  [{:keys [runs fresh answer-from-stdout]}]
  (doseq [d fresh] (fs/delete-tree d) (fs/create-dirs d))
  (let [procs (for [cmd runs :when (not= :size (first cmd))] cmd)
        result (reduce
                (fn [acc cmd]
                  (if (= :size (first cmd))
                    (assoc acc :size (du-bytes (second cmd)))
                    (let [pr (run-process cmd)
                          phases (if answer-from-stdout
                                   [["wall" {:ns (:wall_ns pr) :answer (str/trim (:stdout pr))}]]
                                   (:phases pr))]
                      (-> acc
                          (update :processes conj (dissoc pr :stdout :phases))
                          (update :phases into phases)
                          (update :phase_order into (map first phases))))))
                {:processes [] :phases {} :phase_order []}
                runs)]
    (doseq [d fresh] (fs/delete-tree d))
    (assert (= (count procs) (count (:processes result))))
    result))

(defn wait-for-load [max-load]
  (loop [waited 0]
    (let [l (:one (load-avg))]
      (if (or (<= l max-load) (>= waited 1800))
        waited
        (do (println (format "  load %.2f > %.1f, waiting" l max-load))
            (Thread/sleep 15000)
            (recur (+ waited 15)))))))

(defn run-workload [{:keys [name impls rounds-factor]}]
  (let [n (* (:n opts) (or rounds-factor 1))
        spec (impls)
        order (vec (keys spec))]
    (loop [attempt 1, discarded []]
      (let [waited (wait-for-load (:max-load opts))
            load-before (load-avg)
            _ (println (format "%s (attempt %d, load %.2f): warm-up" name attempt (:one load-before)))
            warm (into {} (for [i order] [i (run-impl (spec i))]))
            runs (vec (for [r (range n)
                            :let [k (mod r (count order))
                                  ord (concat (drop k order) (take k order))]
                            i ord]
                        (let [l (:one (load-avg))
                              res (run-impl (spec i))]
                          (assoc res :impl i :round r :load_one_before l))))
            load-after (load-avg)
            max-load (apply max (:one load-after) (map :load_one_before runs))
            attempt-rec {:attempt attempt :waited_s waited :load_before load-before
                         :load_after load-after :max_load_one max-load}]
        (println (format "  done, max 1-min load %.2f" max-load))
        (if (and (> max-load (:max-load opts)) (< attempt 3))
          (do (println "  load exceeded; repeating")
              (recur (inc attempt) (conj discarded (assoc attempt-rec :runs runs))))
          {:name name :impls order :n n :warmup warm :runs runs
           :discarded_attempts discarded
           :load_exceeded (> max-load (:max-load opts))
           :attempt attempt-rec})))))

;; ---------------------------------------------------------------- stats

(defn nearest-rank [sorted p]
  (nth sorted (max 0 (dec (long (Math/ceil (* p (count sorted))))))))

(defn stats [xs]
  (when (seq xs)
    (let [s (vec (sort xs))]
      {:n (count s) :min (first s) :median (nearest-rank s 0.5) :p95 (nearest-rank s 0.95)
       :max (peek s)})))

(defn summarize [{:keys [runs impls warmup] :as w}]
  (let [phases (distinct (mapcat :phase_order (concat (vals warmup) runs)))
        by-impl (group-by :impl runs)]
    (assoc w :summary
           (vec (for [ph phases]
                  (let [answers (for [r (concat runs (map (fn [[i r]] (assoc r :impl i)) warmup))
                                      :let [a (get-in r [:phases ph :answer])] :when a]
                                  [(:impl r) a])]
                    {:phase ph
                     :answers (into {} (for [[i as] (group-by first answers)] [i (vec (distinct (map second as)))]))
                     :answers_match (= 1 (count (distinct (map second answers))))
                     :impls (into {} (for [i impls
                                           :let [ns (keep #(get-in % [:phases ph :ns]) (by-impl i))]
                                           :when (seq ns)]
                                       [i {:ns (stats ns)}]))})))
           :process
           (into {} (for [i impls]
                      [i (vec (for [k (range (count (:processes (first (by-impl i)))))]
                                {:cmd (get-in (first (by-impl i)) [:processes k :cmd])
                                 :wall_ns (stats (map #(get-in % [:processes k :wall_ns]) (by-impl i)))
                                 :max_rss_bytes (stats (keep #(get-in % [:processes k :max_rss_bytes]) (by-impl i)))
                                 :exit_codes (distinct (map #(get-in % [:processes k :exit]) (by-impl i)))}))]))
           :size (into {} (for [i impls
                                :let [ss (keep :size (by-impl i))]
                                :when (seq ss)]
                            [i {:allocated_bytes (stats (map :allocated_bytes ss))
                                :apparent_bytes (stats (map :apparent_bytes ss))}])))))

;; ---------------------------------------------------------------- report

(defn fmt-ns [ns]
  (cond (nil? ns) "—"
        (>= ns 1e9) (format "%.2f s" (/ ns 1e9))
        (>= ns 1e8) (format "%.0f ms" (/ ns 1e6))
        (>= ns 1e7) (format "%.1f ms" (/ ns 1e6))
        (>= ns 1e6) (format "%.2f ms" (/ ns 1e6))
        :else (format "%.0f μs" (/ ns 1e3))))

(defn fmt-mb [b] (if b (format "%.0f MB" (/ b 1e6)) "—"))

(defn cell [st]
  (if st
    (format "%s [%s–%s]" (fmt-ns (:median st)) (fmt-ns (:min st)) (fmt-ns (:p95 st)))
    "n/a"))

(defn ratio [a b]
  (if (and a b) (format "%.2f" (double (/ (:median a) (:median b)))) "—"))

(defn md-report [host vers res]
  (let [sb (StringBuilder.)
        line (fn [& xs] (.append sb (str (apply str xs) "\n")))
        lang (filter #(= :lang (:kind %)) res)
        db (filter #(= :db (:kind %)) res)]
    (line "# nexis comparison run")
    (line)
    (when (:smoke opts) (line "**SMOKE RUN: a check of the harness, not a measurement.**") (line))
    (line "- date: " (:date host))
    (line "- host: " (:cpu host) ", " (:cores host) " cores, " (quot (:ram_bytes host) (* 1024 1024 1024)) " GiB, " (:os host))
    (line "- load average (1/5/15 min) before: " (str/join " " (vals (:load_before host)))
          ", after: " (str/join " " (vals (:load_after host))))
    (line "- nexis " (:nexis_commit vers) (when (:nexis_dirty vers) " (dirty)") ", " (:nexis_optimize vers)
          ", zig " (:zig vers) "; " (:bb vers) "; " (:dtlv vers))
    (line "- rounds: " (:n opts) " (startup " (* 3 (:n opts)) "), alternating, after one discarded warm-up run each")
    (line "- cells: median [min–p95] of the time measured inside the process; ratio = nexis median ÷ other median (above 1, nexis is slower)")
    (line)
    (when (seq lang)
      (line "## Language: nexis vs babashka")
      (line)
      (line "| Workload | nexis | babashka | ratio | nexis wall | bb wall | nexis RSS | bb RSS | answers |")
      (line "|---|---:|---:|---:|---:|---:|---:|---:|---|")
      (doseq [w lang
              s (:summary w)]
        (let [pn (get-in w [:process :nexis 0])
              pb (get-in w [:process :bb 0])]
          (line "| " (:name w) (when (:load_exceeded w) " (load > limit)")
                " | " (cell (get-in s [:impls :nexis :ns]))
                " | " (cell (get-in s [:impls :bb :ns]))
                " | " (ratio (get-in s [:impls :nexis :ns]) (get-in s [:impls :bb :ns]))
                " | " (fmt-ns (get-in pn [:wall_ns :median]))
                " | " (fmt-ns (get-in pb [:wall_ns :median]))
                " | " (fmt-mb (get-in pn [:max_rss_bytes :max]))
                " | " (fmt-mb (get-in pb [:max_rss_bytes :max]))
                " | " (if (:answers_match s) "equal" (str "DIFFER " (pr-str (:answers s)))) " |")))
      (line))
    (doseq [w db]
      (line "## Database: Nextomic (nexis) vs Datalevin")
      (line)
      (line "| Phase | Nextomic | Datalevin | ratio | answers |")
      (line "|---|---:|---:|---:|---|")
      (doseq [s (:summary w)]
        (line "| " (:phase s) " | " (cell (get-in s [:impls :nexis :ns]))
              " | " (cell (get-in s [:impls :datalevin :ns]))
              " | " (ratio (get-in s [:impls :nexis :ns]) (get-in s [:impls :datalevin :ns]))
              " | " (cond (not (get-in s [:impls :datalevin])) (str "nexis only: " (first (vals (:answers s))))
                          (:answers_match s) (str "equal " (first (first (vals (:answers s)))))
                          :else (str "DIFFER " (pr-str (:answers s)))) " |"))
      (line)
      (line "| Store after the load | Nextomic | Datalevin |")
      (line "|---|---:|---:|")
      (line "| allocated (du) | " (fmt-mb (get-in w [:size :nexis :allocated_bytes :median]))
            " | " (fmt-mb (get-in w [:size :datalevin :allocated_bytes :median])) " |")
      (line "| apparent (file lengths) | " (fmt-mb (get-in w [:size :nexis :apparent_bytes :median]))
            " | " (fmt-mb (get-in w [:size :datalevin :apparent_bytes :median])) " |")
      (line)
      (line "| Process | Nextomic wall | Nextomic RSS | Datalevin wall | Datalevin RSS |")
      (line "|---|---:|---:|---:|---:|")
      (doseq [[k label] [[0 "load (durable)"] [1 "query"] [2 "load (sync off)"]]]
        (let [pn (get-in w [:process :nexis k]) pd (get-in w [:process :datalevin k])]
          (line "| " label " | " (fmt-ns (get-in pn [:wall_ns :median])) " | " (fmt-mb (get-in pn [:max_rss_bytes :max]))
                " | " (fmt-ns (get-in pd [:wall_ns :median])) " | " (fmt-mb (get-in pd [:max_rss_bytes :max])) " |")))
      (line))
    (str sb)))

;; ---------------------------------------------------------------- main

(when (:build opts)
  (println "building bin/nexis ReleaseFast")
  (p/shell {:dir root} "zig" "build" "install" "-Doptimize=ReleaseFast"))

(def host (assoc (host-info)
                 :date (str (java.time.ZonedDateTime/now))
                 :load_before (load-avg)))
(def vers (versions))
(def results (mapv (fn [w] (merge (select-keys w [:name :kind :doc]) (summarize (run-workload w)))) workloads))
(def host* (assoc host :load_after (load-avg)))

(spit (str out-dir "/results.json")
      (json/generate-string {:schema "nexis-compare/1" :host host* :versions vers
                             :options (update opts :only vec) :workloads results}
                            {:pretty true}))
(spit (str out-dir "/results.md") (md-report host* vers results))
(fs/delete-tree store-dir)
(println (slurp (str out-dir "/results.md")))
(let [bad (for [w results s (:summary w)
                :when (not (:answers_match s))]
            [(:name w) (:phase s)])]
  (when (seq bad)
    (println "ANSWERS DIFFER:" (vec bad))
    (System/exit 1)))
