#!/usr/bin/env bb
;; bench/compare/run.clj — the cross-implementation comparison harness
;; (docs/BENCH.md §12): nexis against babashka and JVM Clojure on
;; language workloads, Nextomic against Datalevin, Datomic Local and
;; Datomic Pro on database workloads.
;;
;;   bb bench/compare/run.clj --out DIR [--n 10] [--only lang,db]
;;                            [--impls nexis,bb,clojure,datalevin,datomic-local,datomic-pro]
;;                            [--workloads fib,sort,...] [--no-build]
;;                            [--max-load 4] [--pin CPUS] [--smoke]
;;                            [--datomic-pro DIR] [--warmup 20] [--timed 10]
;;                            [--nexis-commit SHA] [--emdb-commit SHA]
;;
;; Builds bin/nexis ReleaseFast, runs every workload once per
;; implementation to warm the file cache (discarded), then --n rounds,
;; the implementations alternating with the order rotated each round.
;; Every run is one process under /usr/bin/time (-l on macOS, -v on
;; Linux), under `taskset -c CPUS` with --pin (Linux); the script prints
;; `phase=NAME ns=N answer=A` lines timed inside the process, the
;; runner adds the process wall time and peak RSS. Every phase's
;; answer must be the same on every run of every implementation. A
;; workload whose 1-minute load average rose above --max-load while it
;; ran is discarded and repeated (up to 3 attempts, all kept in the
;; JSON); before a workload the runner waits for the load to fall.
;; --smoke allows --n below 10 and marks the report as a check, not a
;; measurement. Writes DIR/results.md, DIR/results.json and DIR/src/
;; (the exact programs run).
;;
;; --impls chooses the implementations (default nexis,bb,datalevin).
;; `clojure` (language) runs each program with `clojure -M` from this
;; directory's deps.edn twice: once cold, as the others run, and once
;; through warm.clj, --warmup calls and then the median of --timed.
;; `datomic-local` runs the Datomic Local twins with `clojure
;; -M:datomic-local`; `datomic-pro` runs the peer twins against a dev
;; transactor from the Datomic Pro distribution at --datomic-pro, which
;; the runner starts before the load and again before the queries, and
;; stops after each.

(require '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def here (str (fs/parent (fs/absolutize *file*))))
(def root (str (fs/parent (fs/parent here))))
(def nexis-bin (str root "/bin/nexis"))
(def linux? (= "Linux" (System/getProperty "os.name")))

;; ---------------------------------------------------------------- args

(defn parse-args [args]
  (loop [[a & more] args, o {:n 10 :max-load 4.0 :build true :only #{"lang" "db"}
                             :impls ["nexis" "bb" "datalevin"] :warmup 20 :timed 10}]
    (case a
      nil o
      "--out" (recur (rest more) (assoc o :out (first more)))
      "--n" (recur (rest more) (assoc o :n (parse-long (first more))))
      "--max-load" (recur (rest more) (assoc o :max-load (parse-double (first more))))
      "--only" (recur (rest more) (assoc o :only (set (str/split (first more) #","))))
      "--impls" (recur (rest more) (assoc o :impls (str/split (first more) #",")))
      "--workloads" (recur (rest more) (assoc o :workloads (set (str/split (first more) #","))))
      "--pin" (recur (rest more) (assoc o :pin (first more)))
      "--datomic-pro" (recur (rest more) (assoc o :datomic-pro (str (fs/absolutize (first more)))))
      "--warmup" (recur (rest more) (assoc o :warmup (parse-long (first more))))
      "--timed" (recur (rest more) (assoc o :timed (parse-long (first more))))
      "--nexis-commit" (recur (rest more) (assoc o :nexis-commit (first more)))
      "--emdb-commit" (recur (rest more) (assoc o :emdb-commit (first more)))
      "--no-build" (recur more (assoc o :build false))
      "--smoke" (recur more (assoc o :smoke true))
      (do (println "unknown argument" a) (System/exit 2)))))

(def opts (parse-args *command-line-args*))
(def impls (set (map keyword (:impls opts))))
(when-not (:out opts)
  (println "usage: bb bench/compare/run.clj --out DIR [--n 10] [--only lang,db] [--impls a,b] [--workloads a,b] [--no-build] [--max-load 4] [--pin CPUS] [--datomic-pro DIR]")
  (System/exit 2))
(when (and (< (:n opts) 10) (not (:smoke opts)))
  (println "--n below 10 is not a measurement (docs/BENCH.md §3); --smoke runs it as a check")
  (System/exit 2))
(when-let [bad (seq (remove #{:nexis :bb :clojure :datalevin :datomic-local :datomic-pro} impls))]
  (println "unknown implementations" (vec bad))
  (System/exit 2))
(when (and (:pin opts) (not linux?))
  (println "--pin needs taskset (Linux)")
  (System/exit 2))
(when (and (impls :datomic-pro) (not (:datomic-pro opts)))
  (println "datomic-pro needs --datomic-pro DIR, the unpacked Datomic Pro distribution")
  (System/exit 2))

(def out-dir (str (fs/absolutize (:out opts))))
(def src-dir (str out-dir "/src"))
(def store-dir (str out-dir "/stores"))
(fs/create-dirs src-dir)

;; Every JVM the runner starts: the JDK's defaults (G1, heap sized from
;; the RAM) with the performance-data file off and temporary files
;; under TMPDIR, so nothing is written to /tmp.
(def tmp-dir (or (System/getenv "TMPDIR") (str out-dir "/tmp")))
(fs/create-dirs tmp-dir)
(def jvm-flags ["-XX:-UsePerfData" (str "-Djava.io.tmpdir=" tmp-dir)])
(def clj-flags (mapv #(str "-J" %) jvm-flags))
(def jvm-env {"CLJ_JVM_OPTS" (or (System/getenv "CLJ_JVM_OPTS") (str/join " " jvm-flags))})

;; ---------------------------------------------------------------- host

(defn sh-out [& cmd]
  (str/trim (:out (p/sh cmd {:dir root}))))

(defn try-out [& cmd]
  (try (let [r (p/sh cmd {:dir root})]
         (when (zero? (:exit r)) (str/trim (str (:out r) (:err r)))))
       (catch Exception _ nil)))

;; /proc and /sys files report a size of zero, which slurp refuses under
;; bb; cat reads them.
(defn read-sys [path]
  (let [r (p/sh ["cat" path])]
    (when (zero? (:exit r)) (:out r))))

(defn load-avg []
  (let [[a b c] (map parse-double
                     (if linux?
                       (take 3 (str/split (str/trim (read-sys "/proc/loadavg")) #"\s+"))
                       ;; "{ 1.23 2.34 3.45 }"
                       (re-seq #"[\d.]+" (sh-out "sysctl" "-n" "vm.loadavg"))))]
    {:one a :five b :fifteen c}))

(defn cpu-max-mhz [cpu]
  (some-> (read-sys (str "/sys/devices/system/cpu/cpu" cpu "/cpufreq/cpuinfo_max_freq"))
          str/trim parse-long (quot 1000)))

(defn expand-cpus [spec]
  (vec (mapcat (fn [part]
                 (let [[a b] (map parse-long (str/split part #"-"))]
                   (range a (inc (or b a)))))
               (str/split spec #","))))

(defn host-info []
  (if linux?
    (let [cpuinfo (read-sys "/proc/cpuinfo")
          meminfo (read-sys "/proc/meminfo")
          os (second (re-find #"(?m)^PRETTY_NAME=\"?([^\"\n]+)" (slurp "/etc/os-release")))]
      {:cpu (second (re-find #"(?m)^model name\s*:\s*(.+)$" cpuinfo))
       :cores (count (re-seq #"(?m)^processor\s*:" cpuinfo))
       :ram_bytes (* 1024 (parse-long (second (re-find #"MemTotal:\s+(\d+)" meminfo))))
       :os os
       :kernel (sh-out "uname" "-r")
       :governor (some-> (read-sys "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor") str/trim)
       :pin (:pin opts)
       :pinned_cpus_max_mhz (when-let [s (:pin opts)]
                              (into (sorted-map) (for [c (expand-cpus s)] [c (cpu-max-mhz c)])))})
    {:cpu (sh-out "sysctl" "-n" "machdep.cpu.brand_string")
     :cores (parse-long (sh-out "sysctl" "-n" "hw.ncpu"))
     :ram_bytes (parse-long (sh-out "sysctl" "-n" "hw.memsize"))
     :os (str "macOS " (sh-out "sw_vers" "-productVersion") " (" (sh-out "sw_vers" "-buildVersion") ")")
     :kernel (sh-out "uname" "-r")}))

(defn datomic-pro-version []
  (str/trim (slurp (str (:datomic-pro opts) "/VERSION"))))

(defn versions []
  (let [commit (try-out "git" "rev-parse" "HEAD")]
    (cond-> {:nexis_commit (or commit (:nexis-commit opts))
             :nexis_commit_source (if commit "git" "--nexis-commit")
             :nexis_dirty (when commit
                            (not (str/blank? (sh-out "git" "status" "--porcelain" "--" "src" "build.zig" "build.zig.zon"))))
             :emdb_commit (or (try-out "git" "-C" (str root "/../emdb") "rev-parse" "HEAD") (:emdb-commit opts))
             :nexis_optimize "ReleaseFast"
             :zig (sh-out "zig" "version")}
      (impls :bb) (assoc :bb (sh-out "bb" "--version"))
      (impls :datalevin) (assoc :dtlv (sh-out "dtlv" "--version"))
      (some impls [:clojure :datomic-local :datomic-pro])
      (assoc :java (first (str/split-lines (:err (p/sh ["java" "-version"]))))
             :jvm_flags jvm-flags)
      (some impls [:clojure :datomic-local])
      (assoc :clojure_cli (sh-out "clojure" "--version")
             :deps_edn (slurp (str here "/deps.edn")))
      (impls :datomic-pro)
      (assoc :datomic_pro (datomic-pro-version)))))

;; ---------------------------------------------------------------- workloads

(defn clojure-cmd [& args]
  (into (into ["clojure"] clj-flags) args))

(defn gen-lang [name]
  (let [body (slurp (str here "/lang/" name ".clj"))
        nx (str src-dir "/" name ".nx")
        clj (str src-dir "/" name ".clj")]
    (spit nx (str (slurp (str here "/prelude.nx")) "\n" body))
    (spit clj (str (slurp (str here "/prelude.clj")) "\n" body))
    {:nexis {:runs [{:label "run" :cmd [nexis-bin "run" nx]}]}
     :bb {:runs [{:label "run" :cmd ["bb" clj]}]}
     :clojure {:dir here :env jvm-env
               :runs [{:label "cold" :cmd (clojure-cmd "-M" clj)}
                      {:label "warm" :cmd (clojure-cmd "-M" (str here "/warm.clj") clj
                                                       (str (:warmup opts)) (str (:timed opts)))}]}}))

(def lang-workloads
  (concat
   [{:name "startup" :kind :lang :rounds-factor 3
     :doc "process start to first output, -e '(+ 1 2)'"
     :impls (constantly {:nexis {:runs [{:label "run" :cmd [nexis-bin "-e" "(+ 1 2)"]}] :answer-from-stdout true}
                         :bb {:runs [{:label "run" :cmd ["bb" "-e" "(+ 1 2)"]}] :answer-from-stdout true}
                         :clojure {:dir here :env jvm-env :answer-from-stdout true
                                   :runs [{:label "cold" :cmd (clojure-cmd "-M" "-e" "(+ 1 2)")}]}})}]
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

(defn pro-classpath []
  (let [d (:datomic-pro opts)]
    (str d "/datomic-transactor-pro-" (datomic-pro-version) ".jar:" d "/lib/*")))

(defn pro-peer [script uri]
  (-> ["java"]
      (into jvm-flags)
      (into [(str "-Dlogback.configurationFile=" here "/db/logback.xml")
             "-cp" (pro-classpath) "clojure.main" (str here "/db/" script) uri])))

(defn db-impls []
  (let [s (fn [& xs] (apply str store-dir "/" xs))
        pro-uri "datomic:dev://localhost:4334/people"
        spec {:nexis
              #(do {:fresh [(s "nexis") (s "nexis-durable") (s "nexis-nosync")]
                    :runs [{:label "load" :cmd [nexis-bin "run" (str here "/db/nexis-load.nx") (s "nexis/store.edb") "default"]}
                           {:op :size :path (s "nexis")}
                           {:label "query" :cmd [nexis-bin "run" (str here "/db/nexis-query.nx") (s "nexis/store.edb")]}
                           {:label "load (durable)" :cmd [nexis-bin "run" (str here "/db/nexis-load.nx") (s "nexis-durable/store.edb") "durable"]}
                           {:label "load (sync off)" :cmd [nexis-bin "run" (str here "/db/nexis-load.nx") (s "nexis-nosync/store.edb") "nosync"]}]})
              :datalevin
              #(do {:fresh [(s "datalevin") (s "datalevin-nosync")]
                    :runs [{:label "load" :cmd (gen-dtlv "dtlv-load.clj" (s "datalevin/db") "default")}
                           {:op :size :path (s "datalevin")}
                           {:label "query" :cmd (gen-dtlv "dtlv-query.clj" (s "datalevin/db") "default")}
                           {:label "load (sync off)" :cmd (gen-dtlv "dtlv-load.clj" (s "datalevin-nosync/db") "nosync")}]})
              :datomic-local
              #(do {:fresh [(s "datomic-local")] :dir here :env jvm-env
                    :runs [{:label "load" :cmd (clojure-cmd "-M:datomic-local" (str here "/db/datomic-local-load.clj") (s "datomic-local"))}
                           {:op :size :path (s "datomic-local")}
                           {:label "query" :cmd (clojure-cmd "-M:datomic-local" (str here "/db/datomic-local-query.clj") (s "datomic-local"))}]})
              :datomic-pro
              #(do {:fresh [(s "datomic-pro")]
                    :runs [{:op :transactor-start :dir (s "datomic-pro")}
                           {:label "load" :cmd (pro-peer "datomic-pro-load.clj" pro-uri)}
                           {:op :transactor-stop}
                           {:op :size :path (s "datomic-pro/data")}
                           {:op :transactor-start :dir (s "datomic-pro")}
                           {:label "query" :cmd (pro-peer "datomic-pro-query.clj" pro-uri)}
                           {:op :transactor-stop}]})}]
    (into {} (for [[k f] spec :when (impls k)] [k (f)]))))

(def db-workloads
  [{:name "database" :kind :db :impls db-impls}])

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

(def pin-prefix (if (:pin opts) ["taskset" "-c" (:pin opts)] []))
(def time-prefix (if linux? ["/usr/bin/time" "-v"] ["/usr/bin/time" "-l"]))

(defn max-rss [err]
  (if linux?
    (some->> (re-find #"Maximum resident set size \(kbytes\): (\d+)" err) second parse-long (* 1024))
    (some->> (re-find #"(\d+)\s+maximum resident set size" err) second parse-long)))

(defn run-process [{:keys [cmd label]} {:keys [dir env]}]
  (let [t0 (System/nanoTime)
        r (p/sh (-> pin-prefix (into time-prefix) (into cmd))
                (cond-> {:dir (or dir root)} env (assoc :extra-env env)))
        wall (- (System/nanoTime) t0)]
    {:label label
     :cmd (let [c (vec cmd)] (if (= "exec" (get c 1)) ["dtlv" "exec" "<src>"] c))
     :exit (:exit r)
     :wall_ns wall
     :max_rss_bytes (max-rss (:err r))
     :phases (parse-phases (:out r))
     :stdout (:out r)
     :stderr (when-not (zero? (:exit r)) (:err r))}))

;; The Datomic Pro dev transactor: its own process on the same host,
;; pinned as the others are, with the distribution's own JVM options
;; (bin/transactor's -Xms1g -Xmx1g, G1, a 50 ms pause goal) and the
;; runner's; data and logs under DIR. Its peak RSS is VmHWM from
;; /proc (Linux), read just before it is stopped.

(def transactor (atom nil))

;; A runner that stops early stops its transactor too.
(.addShutdownHook (Runtime/getRuntime)
                  (Thread. (fn [] (when-let [t @transactor] (p/destroy (:proc t))))))

(defn transactor-start [dir]
  (let [props (str dir "/transactor.properties")]
    (fs/create-dirs dir)
    (spit props (str/join "\n" ["protocol=dev" "host=localhost" "port=4334"
                                (str "data-dir=" dir "/data") (str "log-dir=" dir "/log")
                                ;; the values of config/samples/dev-transactor-template.properties
                                "memory-index-threshold=32m" "memory-index-max=256m" "object-cache-max=128m" ""]))
    (let [t0 (System/nanoTime)
          out (str dir "/transactor.out")
          proc (p/process (-> pin-prefix
                              (into ["bin/transactor" "-Xms1g" "-Xmx1g" "--enable-native-access=ALL-UNNAMED"
                                     "-XX:+UseG1GC" "-XX:MaxGCPauseMillis=50"])
                              (into jvm-flags)
                              (conj props))
                          {:dir (:datomic-pro opts) :out (fs/file out) :err :out
                           :extra-env {"DATOMIC_LOG_DIR" (str dir "/log")}})]
      (loop [waited 0]
        (cond (str/includes? (try (slurp out) (catch Exception _ "")) "System started") nil
              (or (not (p/alive? proc)) (> waited 120000))
              (do (p/destroy proc)
                  (throw (ex-info "the transactor did not start" {:out (slurp out)})))
              :else (do (Thread/sleep 200) (recur (+ waited 200)))))
      (reset! transactor {:proc proc :start_ns (- (System/nanoTime) t0)}))))

(defn transactor-stop []
  (let [{:keys [proc start_ns]} @transactor
        pid (.pid (:proc proc))
        hwm (when linux?
              (some->> (read-sys (str "/proc/" pid "/status"))
                       (re-find #"VmHWM:\s+(\d+) kB") second parse-long (* 1024)))]
    (p/destroy proc)
    (let [exit (:exit @proc)]
      (reset! transactor nil)
      {:start_ns start_ns :max_rss_bytes hwm :exit exit})))

(defn run-impl
  "One run of an implementation: its processes in order, fresh stores
  first. Returns {:processes [...] :phases {...} :size {...}}."
  [{:keys [runs fresh answer-from-stdout] :as spec}]
  (doseq [d fresh] (fs/delete-tree d) (fs/create-dirs d))
  (let [result (reduce
                (fn [acc run]
                  (case (:op run)
                    :size (assoc acc :size (du-bytes (:path run)))
                    :transactor-start (do (transactor-start (:dir run)) acc)
                    :transactor-stop (update acc :transactor conj (transactor-stop))
                    (let [pr (run-process run spec)
                          phases (if answer-from-stdout
                                   [["wall" {:ns (:wall_ns pr) :answer (str/trim (:stdout pr))}]]
                                   (:phases pr))]
                      (when-not (zero? (:exit pr))
                        (println "  exit" (:exit pr) (:label pr) (:cmd pr) "\n" (:stderr pr)))
                      (-> acc
                          (update :processes conj (dissoc pr :stdout :phases))
                          (update :phases into phases)
                          (update :phase_order into (map first phases))))))
                {:processes [] :phases {} :phase_order [] :transactor []}
                runs)]
    (doseq [d fresh] (fs/delete-tree d))
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
        spec (select-keys (impls) (map keyword (:impls opts)))
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

(defn summarize [{:keys [runs impls warmup kind] :as w}]
  (let [phases (distinct (mapcat :phase_order (concat (vals warmup) runs)))
        by-impl (group-by :impl runs)
        all-runs (concat runs (map (fn [[i r]] (assoc r :impl i)) warmup))
        ;; a language workload has one answer whatever the phase (main,
        ;; warm, wall); a database phase's answer is compared by phase
        lang-answers (when (= :lang kind)
                       (distinct (for [r all-runs [_ {:keys [answer]}] (:phases r)] answer)))]
    (assoc w :summary
           (vec (for [ph phases]
                  (let [answers (for [r all-runs
                                      :let [a (get-in r [:phases ph :answer])] :when a]
                                  [(:impl r) a])]
                    {:phase ph
                     :answers (into {} (for [[i as] (group-by first answers)] [i (vec (distinct (map second as)))]))
                     :answers_match (if (= :lang kind)
                                      (= 1 (count lang-answers))
                                      (= 1 (count (distinct (map second answers)))))
                     :impls (into {} (for [i impls
                                           :let [ns (keep #(get-in % [:phases ph :ns]) (by-impl i))]
                                           :when (seq ns)]
                                       [i {:ns (stats ns)}]))})))
           :process
           (into {} (for [i impls]
                      [i (vec (for [k (range (count (:processes (first (by-impl i)))))]
                                {:label (get-in (first (by-impl i)) [:processes k :label])
                                 :cmd (get-in (first (by-impl i)) [:processes k :cmd])
                                 :wall_ns (stats (map #(get-in % [:processes k :wall_ns]) (by-impl i)))
                                 :max_rss_bytes (stats (keep #(get-in % [:processes k :max_rss_bytes]) (by-impl i)))
                                 :exit_codes (distinct (map #(get-in % [:processes k :exit]) (by-impl i)))}))]))
           :transactor
           (into {} (for [i impls
                          :let [ts (mapcat :transactor (by-impl i))]
                          :when (seq ts)]
                      [i {:start_ns (stats (map :start_ns ts))
                          :max_rss_bytes (stats (keep :max_rss_bytes ts))}]))
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

(def labels {:nexis "nexis" :bb "babashka" :clojure "Clojure" :datalevin "Datalevin"
             :datomic-local "Datomic Local" :datomic-pro "Datomic Pro"})

(def durability
  {:nexis (str "Nextomic: `create`, `load`, `tx-1k-default` commit with `:commit`, which syncs nothing "
               "(atomic, survives a crash of the process; the file is synced at `release`, outside the time); "
               "`create-durable`, `load-durable`, `tx-1k-durable` through a connection opened "
               "`{:durability :durable}`, every commit syncing data and meta ("
               (if linux? "two `fdatasync`" "two `F_FULLFSYNC`") "); "
               "the `-nosync` rows with `:sync :none` and one sync at the end")
   :datalevin (str "Datalevin: every row but the `-nosync` ones in its default commit, LMDB's sync per commit; "
                   "`tx-1k-durable` is a second batch in that mode; the `-nosync` rows with the `:nosync` flag "
                   "and one sync at the end")
   :datomic-local (str "Datomic Local: its one commit mode, `fdatasync` of its log per transaction; "
                       "`tx-1k-durable` is a second batch in that mode; no `-nosync` counterpart "
                       "(the third batch runs untimed)")
   :datomic-pro (str "Datomic Pro, dev transactor: its one commit mode; with dev storage (H2) the transactor "
                     "acknowledges a transaction without a sync, so only `tx-1k-default` is reported "
                     "(the second and third batches run untimed); `index` is request-index and sync-index "
                     "after the load")})

(defn md-report [host vers res]
  (let [sb (StringBuilder.)
        line (fn [& xs] (.append sb (str (apply str xs) "\n")))
        lang (filter #(= :lang (:kind %)) res)
        db (filter #(= :db (:kind %)) res)]
    (line "# nexis comparison run")
    (line)
    (when (:smoke opts) (line "**SMOKE RUN: a check of the harness, not a measurement.**") (line))
    (line "- date: " (:date host))
    (line "- host: " (:cpu host) ", " (:cores host) " logical CPUs, " (quot (:ram_bytes host) (* 1024 1024 1024)) " GiB, "
          (:os host) ", kernel " (:kernel host) (when (:governor host) (str ", governor " (:governor host))))
    (when (:pin host)
      (line "- pinned: every process under `taskset -c " (:pin host) "` (max MHz by CPU: "
            (str/join ", " (for [[c m] (:pinned_cpus_max_mhz host)] (str c ":" m))) ")"))
    (line "- load average (1/5/15 min) before: " (str/join " " (vals (:load_before host)))
          ", after: " (str/join " " (vals (:load_after host))) "; --max-load " (:max-load opts))
    (line "- nexis " (:nexis_commit vers) (when (:nexis_dirty vers) " (dirty)") ", emdb " (:emdb_commit vers)
          ", " (:nexis_optimize vers) ", zig " (:zig vers))
    (doseq [k [:bb :dtlv :java :clojure_cli]]
      (when-let [v (get vers k)] (line "- " v)))
    (when (:jvm_flags vers)
      (line "- JVM flags: " (str/join " " (:jvm_flags vers)) " (otherwise the JDK's defaults); Clojure and Datomic Local from bench/compare/deps.edn"))
    (when (:datomic_pro vers) (line "- Datomic Pro " (:datomic_pro vers) ", dev transactor"))
    (line "- rounds: " (:n opts) " (startup " (* 3 (:n opts)) "), alternating, after one discarded warm-up run each")
    (line "- cells: median [min–p95] of the time measured inside the process; ratio = nexis median ÷ other median (above 1, nexis is slower)")
    (line)
    (when (seq lang)
      (let [present (filter impls [:nexis :bb :clojure])
            cols (concat (for [i present] [i "main" (labels i)])
                         (when (impls :clojure) [[:clojure "warm" "Clojure warm"]]))
            cols (map (fn [[i ph l]] [i ph (if (= [i ph] [:clojure "main"]) "Clojure cold" l)]) cols)
            others (remove #(= :nexis (first %)) cols)]
        (line "## Language")
        (line)
        (when (impls :clojure)
          (line "Clojure cold is the program's one run in a fresh JVM, as the others run it; Clojure warm is the median of "
                (:timed opts) " runs in one JVM after " (:warmup opts) " discarded ones (warm.clj). Startup includes "
                "the `clojure` launcher's classpath step (a cached classpath).")
          (line))
        (line "| Workload | " (str/join " | " (map #(nth % 2) cols)) " | "
              (str/join " | " (for [c others] (str "nexis ÷ " (nth c 2)))) " | answers |")
        (line "|---|" (str/join (repeat (+ (count cols) (count others)) "---:|")) "---|")
        (doseq [w lang]
          (let [cellf (fn [[i ph]] (get-in (first (filter #(= ph (:phase %)) (:summary w)))
                                           [:impls i :ns]))
                ph (if (= "startup" (:name w)) "wall" "main")
                cellf (fn [[i p]] (cellf [i (if (= p "main") ph p)]))
                nx (cellf [:nexis "main"])
                ok (every? :answers_match (:summary w))]
            (line "| " (:name w) (when (:load_exceeded w) " (load > limit)")
                  " | " (str/join " | " (map (comp cell cellf) cols))
                  " | " (str/join " | " (for [c others] (ratio nx (cellf c))))
                  " | " (if ok (str "equal " (first (vals (:answers (first (:summary w))))))
                            (str "DIFFER " (pr-str (map :answers (:summary w))))) " |")))
        (line)
        (let [pcols (distinct (for [w lang i present pr (get-in w [:process i])] [i (:label pr)]))]
          (line "| Workload | " (str/join " | " (for [[i l] pcols]
                                                 (str (labels i) (when (= :clojure i) (str " " l)) " wall / RSS")))
                " |")
          (line "|---|" (str/join (repeat (count pcols) "---:|")))
          (doseq [w lang]
            (line "| " (:name w) " | "
                  (str/join " | " (for [[i l] pcols
                                        :let [pr (first (filter #(= l (:label %)) (get-in w [:process i])))]]
                                    (if pr
                                      (str (fmt-ns (get-in pr [:wall_ns :median])) " / " (fmt-mb (get-in pr [:max_rss_bytes :max])))
                                      "—")))
                  " |")))
        (line)))
    (doseq [w db]
      (let [present (filter impls [:nexis :datalevin :datomic-local :datomic-pro])
            others (remove #{:nexis} present)
            label (fn [i] (if (= i :nexis) "Nextomic" (labels i)))]
        (line "## Database: Nextomic against " (str/join ", " (map label others)))
        (line)
        (line "| Phase | " (str/join " | " (map label present)) " | "
              (str/join " | " (for [o others] (str "÷ " (label o)))) " | answers |")
        (line "|---|" (str/join (repeat (+ (count present) (count others)) "---:|")) "---|")
        (doseq [s (:summary w)]
          (let [have (keys (:impls s))]
            (line "| " (:phase s) " | " (str/join " | " (for [i present] (cell (get-in s [:impls i :ns]))))
                  " | " (str/join " | " (for [o others] (ratio (get-in s [:impls :nexis :ns]) (get-in s [:impls o :ns]))))
                  " | " (cond (not (:answers_match s)) (str "DIFFER " (pr-str (:answers s)))
                              (= 1 (count have)) (str (label (first have)) " only: " (first (first (vals (:answers s)))))
                              :else (str "equal " (first (first (vals (:answers s)))))) " |")))
        (line)
        (line "Durability of each row:")
        (line)
        (doseq [i present] (line "- " (durability i)))
        (line)
        (line "| Store after the load | " (str/join " | " (map label present)) " |")
        (line "|---|" (str/join (repeat (count present) "---:|")))
        (line "| allocated (du) | " (str/join " | " (for [i present] (fmt-mb (get-in w [:size i :allocated_bytes :median])))) " |")
        (line "| apparent (file lengths) | " (str/join " | " (for [i present] (fmt-mb (get-in w [:size i :apparent_bytes :median])))) " |")
        (line)
        (line "| Process | wall | peak RSS |")
        (line "|---|---:|---:|")
        (doseq [i present
                pr (get-in w [:process i])]
          (line "| " (label i) " " (:label pr) " | " (fmt-ns (get-in pr [:wall_ns :median]))
                " | " (fmt-mb (get-in pr [:max_rss_bytes :max])) " |"))
        (when-let [t (get-in w [:transactor :datomic-pro])]
          (line "| Datomic Pro transactor (separate process; start to ready, peak RSS over its run) | "
                (fmt-ns (get-in t [:start_ns :median])) " | " (fmt-mb (get-in t [:max_rss_bytes :max])) " |"))
        (line)))
    (str sb)))

;; ---------------------------------------------------------------- main

(when (:build opts)
  (println "building bin/nexis ReleaseFast")
  (p/shell {:dir root} "zig" "build" "install" "-Doptimize=ReleaseFast"))

;; Resolve the JVM classpaths before anything is timed.
(when (some impls [:clojure :datomic-local])
  (p/shell {:dir here :extra-env jvm-env} "clojure" "-P" "-M:datomic-local"))

;; The exact programs, beside the generated ones.
(doseq [f (concat ["prelude.nx" "prelude.clj" "warm.clj" "deps.edn"]
                  (map #(str "db/" %) ["nexis-load.nx" "nexis-query.nx" "datomic-local-load.clj"
                                       "datomic-local-query.clj" "datomic-pro-load.clj"
                                       "datomic-pro-query.clj" "logback.xml"]))]
  (fs/copy (str here "/" f) (str src-dir "/" (fs/file-name f)) {:replace-existing true}))

(def host (assoc (host-info)
                 :date (str (java.time.ZonedDateTime/now))
                 :load_before (load-avg)))
(def vers (versions))
(def results (mapv (fn [w] (merge (select-keys w [:name :kind :doc]) (summarize (merge w (run-workload w))))) workloads))
(def host* (assoc host :load_after (load-avg)))

(spit (str out-dir "/results.json")
      (json/generate-string {:schema "nexis-compare/2" :host host* :versions vers
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
