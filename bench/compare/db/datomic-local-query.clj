; bench/compare/db/datomic-local-query.clj — the Datomic Local twin of
; nexis-query.nx: reopen the database datomic-local-load.clj built and
; time the same operations (docs/BENCH.md §12). The client API has no
; entity and no pull-many: a lookup is a pull of one attribute, and
; pull-10k is one pull per entity. Every transaction is Datomic's one
; commit mode, which syncs the log (fdatasync); the first batch is its
; default row, the second its durable row, and the third, which has no
; counterpart, runs untimed so the history matches the other twins'.
; Usage: clojure -M:datomic-local datomic-local-query.clj STORAGE-DIR

(require '[datomic.client.api :as d]
         '[datomic.local])

(def storage-dir (first *command-line-args*))

(defn report [phase ns answer]
  (println (str "phase=" phase " ns=" ns " answer=" answer)))

(defn email [i] (str "p" i "@x.org"))

; The entity id a lookup ref names, from AVET: the client API has no
; entid, and a pull of [:db/id] alone through a lookup ref is about a
; hundred times slower than this in Datomic Local 1.0.291.
(defn entid [db [a v]] (:e (first (d/datoms db {:index :avet :components [a v]}))))

(def t-open (System/nanoTime))
(def client (d/client {:server-type :datomic-local :system "bench" :storage-dir storage-dir}))
(def conn (d/connect client {:db-name "people"}))
(def db0 (d/db conn))
(report "open" (- (System/nanoTime) t-open) (some? (entid db0 [:dept/name "d0"])))

(let [t0 (System/nanoTime)
      total (loop [i 0 acc 0]
              (if (< i 10000)
                (recur (inc i) (+ acc (:person/age (d/pull db0 [:person/age] [:person/email (email (* i 10))]))))
                acc))]
  (report "lookup-10k" (- (System/nanoTime) t0) total))

(let [t0 (System/nanoTime)
      total (loop [k 0 acc 0]
              (if (< k 20)
                (recur (inc k)
                       (+ acc (count (d/q '[:find ?p ?name :in $ ?dn
                                            :where [?d :dept/name ?dn] [?p :person/dept ?d] [?p :person/name ?name]]
                                          db0 (str "d" k)))))
                acc))]
  (report "join3-20x" (- (System/nanoTime) t0) total))

(let [t0 (System/nanoTime)
      rows (d/q '[:find ?dn (sum ?s) :with ?p
                  :where [?p :person/dept ?d] [?d :dept/name ?dn] [?p :person/salary ?s]]
                db0)]
  (report "aggregate" (- (System/nanoTime) t0) (str (count rows) "/" (reduce + (map second rows)))))

(let [eids (mapv (fn [i] (entid db0 [:person/email (email (* i 10))])) (range 10000))
      pattern [:person/name :person/age {:person/dept [:dept/name]}]
      t0 (System/nanoTime)
      res (mapv (fn [e] (d/pull db0 pattern e)) eids)]
  (report "pull-10k" (- (System/nanoTime) t0) (str (count res) "/" (reduce + (map :person/age res)) "/"
                                                 (count (filter (fn [r] (:dept/name (:person/dept r))) res)))))

; The lookups and the pull again over other people (offset p = 1..9,
; nine passes), each pass timed: the median pass, and the answers'
; total. Neither goes through a query, so no result cache applies; a
; JVM has compiled the paths by then.
(defn median [xs] (nth (vec (sort xs)) (quot (dec (count xs)) 2)))

(let [passes (mapv (fn [p]
                     (let [t0 (System/nanoTime)
                           total (loop [i 0 acc 0]
                                   (if (< i 10000)
                                     (recur (inc i) (+ acc (:person/age (d/pull db0 [:person/age] [:person/email (email (+ p (* i 10)))]))))
                                     acc))]
                       [(- (System/nanoTime) t0) total]))
                   (range 1 10))]
  (report "lookup-10k-warm" (median (map first passes)) (reduce + (map second passes))))

(let [pattern [:person/name :person/age {:person/dept [:dept/name]}]
      passes (mapv (fn [p]
                     (let [eids (mapv (fn [i] (entid db0 [:person/email (email (+ p (* i 10)))])) (range 10000))
                           t0 (System/nanoTime)
                           res (mapv (fn [e] (d/pull db0 pattern e)) eids)
                           ns (- (System/nanoTime) t0)]
                       [ns (reduce + (map :person/age res))]))
                   (range 1 10))]
  (report "pull-10k-warm" (median (map first passes)) (reduce + (map second passes))))

(def salary-sum-q
  '[:find (sum ?s) :with ?p :in $ [?em ...] :where [?p :person/email ?em] [?p :person/salary ?s]])
(def first-1000 (mapv email (range 1000)))
(defn salary-sum [db] (ffirst (d/q salary-sum-q db first-1000)))

(def t-before (:t (d/db conn)))
(let [t0 (System/nanoTime)]
  (dotimes [i 1000]
    (d/transact conn {:tx-data [[:db/add [:person/email (email i)] :person/salary (inc i)]]}))
  (report "tx-1k-default" (- (System/nanoTime) t0) (salary-sum (d/db conn))))

(let [t0 (System/nanoTime)]
  (dotimes [i 1000]
    (d/transact conn {:tx-data [[:db/add [:person/email (email i)] :person/salary (+ 2 i)]]}))
  (report "tx-1k-durable" (- (System/nanoTime) t0) (salary-sum (d/db conn))))

(dotimes [i 1000]
  (d/transact conn {:tx-data [[:db/add [:person/email (email i)] :person/salary (+ 3 i)]]}))

(let [t0 (System/nanoTime)
      db (d/db conn)
      before (salary-sum (d/as-of db t-before))
      hist (ffirst (d/q '[:find (count ?s) :with ?p ?tx ?added :in $ [?em ...]
                          :where [?p :person/email ?em] [?p :person/salary ?s ?tx ?added]]
                        (d/history db) first-1000))]
  (report "as-of+history" (- (System/nanoTime) t0) (str before "/" hist)))

(datomic.local/release-db {:system "bench" :db-name "people" :storage-dir storage-dir})
(shutdown-agents)
(System/exit 0)
