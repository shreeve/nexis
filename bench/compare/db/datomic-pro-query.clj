; bench/compare/db/datomic-pro-query.clj — the Datomic Pro twin of
; nexis-query.nx: a new peer connects to the database
; datomic-pro-load.clj built and times the same operations
; (docs/BENCH.md §12). Every transaction is Datomic's one commit mode:
; with dev storage the transactor acknowledges it without a sync, so
; the first batch is its default row, and the second and third, which
; have no counterpart, run untimed so the history matches the other
; twins'.
; Usage: java -cp PEER-CLASSPATH clojure.main datomic-pro-query.clj URI

(require '[datomic.api :as d])

(def uri (first *command-line-args*))

(defn report [phase ns answer]
  (println (str "phase=" phase " ns=" ns " answer=" answer)))

(defn email [i] (str "p" i "@x.org"))

(def t-open (System/nanoTime))
(def conn (d/connect uri))
(def db0 (d/db conn))
(report "open" (- (System/nanoTime) t-open) (some? (d/entid db0 [:dept/name "d0"])))

(let [t0 (System/nanoTime)
      total (loop [i 0 acc 0]
              (if (< i 10000)
                (recur (inc i) (+ acc (:person/age (d/entity db0 [:person/email (email (* i 10))]))))
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

(let [eids (mapv (fn [i] (d/entid db0 [:person/email (email (* i 10))])) (range 10000))
      t0 (System/nanoTime)
      res (d/pull-many db0 [:person/name :person/age {:person/dept [:dept/name]}] eids)]
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
                                     (recur (inc i) (+ acc (:person/age (d/entity db0 [:person/email (email (+ p (* i 10)))]))))
                                     acc))]
                       [(- (System/nanoTime) t0) total]))
                   (range 1 10))]
  (report "lookup-10k-warm" (median (map first passes)) (reduce + (map second passes))))

(let [pattern [:person/name :person/age {:person/dept [:dept/name]}]
      passes (mapv (fn [p]
                     (let [eids (mapv (fn [i] (d/entid db0 [:person/email (email (+ p (* i 10)))])) (range 10000))
                           t0 (System/nanoTime)
                           res (d/pull-many db0 pattern eids)
                           ns (- (System/nanoTime) t0)]
                       [ns (reduce + (map :person/age res))]))
                   (range 1 10))]
  (report "pull-10k-warm" (median (map first passes)) (reduce + (map second passes))))

(def salary-sum-q
  '[:find (sum ?s) . :with ?p :in $ [?em ...] :where [?p :person/email ?em] [?p :person/salary ?s]])
(def first-1000 (mapv email (range 1000)))

(def t-before (d/basis-t (d/db conn)))
(let [t0 (System/nanoTime)]
  (dotimes [i 1000]
    @(d/transact conn [[:db/add [:person/email (email i)] :person/salary (inc i)]]))
  (report "tx-1k-default" (- (System/nanoTime) t0) (d/q salary-sum-q (d/db conn) first-1000)))

(dotimes [i 1000]
  @(d/transact conn [[:db/add [:person/email (email i)] :person/salary (+ 2 i)]]))
(dotimes [i 1000]
  @(d/transact conn [[:db/add [:person/email (email i)] :person/salary (+ 3 i)]]))

; The entity batches of nexis-query.nx: 1,000 new people, then 1,000
; upserts through the unique email.
(def dept-eids (let [db (d/db conn)] (mapv (fn [k] (d/entid db [:dept/name (str "d" k)])) (range 100))))
(defn person [i salary]
  {:person/email (email i) :person/name (str "name-" i) :person/age (+ 18 (mod (* i 7) 60))
   :person/dept (nth dept-eids (mod i 100)) :person/salary salary})
(def upserted (mapv email (range 1000 2000)))

(let [t0 (System/nanoTime)]
  (dotimes [i 1000]
    @(d/transact conn [(person (+ 100000 i) (+ 30000 i))]))
  (report "tx-entity-1k" (- (System/nanoTime) t0) (d/q '[:find (count ?e) . :where [?e :person/email]] (d/db conn))))

(let [t0 (System/nanoTime)]
  (dotimes [i 1000]
    @(d/transact conn [(person (+ 1000 i) (+ 4 i))]))
  (report "tx-upsert-1k" (- (System/nanoTime) t0) (d/q salary-sum-q (d/db conn) upserted)))

(let [t0 (System/nanoTime)
      db (d/db conn)
      before (d/q salary-sum-q (d/as-of db t-before) first-1000)
      hist (d/q '[:find (count ?s) . :with ?p ?tx ?added :in $ [?em ...]
                  :where [?p :person/email ?em] [?p :person/salary ?s ?tx ?added]]
                (d/history db) first-1000)]
  (report "as-of+history" (- (System/nanoTime) t0) (str before "/" hist)))

(d/release conn)
(d/shutdown true)
