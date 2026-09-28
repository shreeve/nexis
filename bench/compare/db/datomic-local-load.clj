; bench/compare/db/datomic-local-load.clj — the Datomic Local twin of
; nexis-load.nx: create a database and load 100 departments and
; 100,000 people with five attributes each, in batches of 1,000
; entities (docs/BENCH.md §12). Datomic Local (com.datomic/local) runs
; in this process over files under STORAGE-DIR; its API is the client
; API, whose :find takes relations only, so a scalar answer is the
; first of the first tuple. It has no `:db/index`: every attribute is
; in AVET. Every transaction is Datomic's one commit mode.
; Usage: clojure -M:datomic-local datomic-local-load.clj STORAGE-DIR

(require '[datomic.client.api :as d]
         '[datomic.local])

(def storage-dir (first *command-line-args*))
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
   {:db/ident :person/age :db/valueType :db.type/long :db/cardinality :db.cardinality/one}
   {:db/ident :person/dept :db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
   {:db/ident :person/salary :db/valueType :db.type/long :db/cardinality :db.cardinality/one}])

(defn person [i dept-eids]
  {:person/email (str "p" i "@x.org")
   :person/name (str "name-" i)
   :person/age (+ 18 (mod (* i 7) 60))
   :person/dept (nth dept-eids (mod i 100))
   :person/salary (+ 30000 (mod (* i 7919) 90001))})

(def arg-map {:system "bench" :db-name "people" :storage-dir storage-dir})

(let [t0 (System/nanoTime)
      client (d/client {:server-type :datomic-local :system "bench" :storage-dir storage-dir})
      _ (d/create-database client {:db-name "people"})
      conn (d/connect client {:db-name "people"})
      _ (d/transact conn {:tx-data schema})
      _ (d/transact conn {:tx-data (mapv (fn [k] {:dept/name (str "d" k)}) (range 100))})
      dept-map (into {} (d/q '[:find ?n ?e :where [?e :dept/name ?n]] (d/db conn)))
      dept-eids (mapv (fn [k] (get dept-map (str "d" k))) (range 100))]
  (report "create" (- (System/nanoTime) t0) (count dept-eids))
  (let [t1 (System/nanoTime)]
    (loop [start 0]
      (when (< start n-people)
        (d/transact conn {:tx-data (mapv (fn [i] (person i dept-eids)) (range start (+ start batch)))})
        (recur (+ start batch))))
    (report "load" (- (System/nanoTime) t1)
            (ffirst (d/q '[:find (count ?e) :where [?e :person/email]] (d/db conn)))))
  (datomic.local/release-db arg-map))

(shutdown-agents)
(System/exit 0)
