; bench/compare/db/datomic-pro-load.clj — the Datomic Pro twin of
; nexis-load.nx: create a database and load 100 departments and
; 100,000 people with five attributes each, in batches of 1,000
; entities (docs/BENCH.md §12). This process is a peer (datomic.api);
; the transactor the runner started writes to dev storage. `load`
; ends when the last transaction is acknowledged; `index` then asks
; the transactor to index everything (request-index, sync-index), so
; the store's size and the query process see indexed data. Every
; transaction is Datomic's one commit mode.
; Usage: java -cp PEER-CLASSPATH clojure.main datomic-pro-load.clj URI

(require '[datomic.api :as d])

(def uri (first *command-line-args*))
(def n-people 100000)
(def batch 1000)

; ns is taken before the answer is computed: arguments evaluate left
; to right, so a check query after the work stays outside the time.
(defn report [phase ns answer]
  (println (str "phase=" phase " ns=" ns " answer=" answer)))

(def schema
  [{:db/ident :dept/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one
    :db/unique :db.unique/identity}
   {:db/ident :person/email :db/valueType :db.type/string :db/cardinality :db.cardinality/one
    :db/unique :db.unique/identity}
   {:db/ident :person/name :db/valueType :db.type/string :db/cardinality :db.cardinality/one}
   {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one
    :db/index true}
   {:db/ident :person/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
   {:db/ident :person/salary :db/valueType :db.type/long :db/cardinality :db.cardinality/one}])

(defn person [i dept-eids]
  {:person/email (str "p" i "@x.org")
   :person/name (str "name-" i)
   :person/age (+ 18 (mod (* i 7) 60))
   :person/dept (nth dept-eids (mod i 100))
   :person/salary (+ 30000 (mod (* i 7919) 90001))})

(let [t0 (System/nanoTime)
      _ (d/create-database uri)
      conn (d/connect uri)
      _ @(d/transact conn schema)
      _ @(d/transact conn (mapv (fn [k] {:dept/name (str "d" k)}) (range 100)))
      dept-map (into {} (d/q '[:find ?n ?e :where [?e :dept/name ?n]] (d/db conn)))
      dept-eids (mapv (fn [k] (get dept-map (str "d" k))) (range 100))]
  (report "create" (- (System/nanoTime) t0) (count dept-eids))
  (let [t1 (System/nanoTime)]
    (loop [start 0]
      (when (< start n-people)
        @(d/transact conn (mapv (fn [i] (person i dept-eids)) (range start (+ start batch))))
        (recur (+ start batch))))
    (report "load" (- (System/nanoTime) t1) (d/q '[:find (count ?e) . :where [?e :person/email]] (d/db conn))))
  (let [t2 (System/nanoTime)
        t (d/basis-t (d/db conn))]
    (d/request-index conn)
    @(d/sync-index conn t)
    (report "index" (- (System/nanoTime) t2) (d/q '[:find (count ?e) . :where [?e :person/email]] (d/db conn))))
  (d/release conn))

(d/shutdown true)
