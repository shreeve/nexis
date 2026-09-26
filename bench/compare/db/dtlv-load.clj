; bench/compare/db/dtlv-load.clj — the Datalevin twin of nexis-load.nx:
; create a store, load 100 departments and 100,000 people with five
; attributes each, in batches of 1,000 entities (docs/BENCH.md §12).
; Mode `durable` commits every transaction in Datalevin's default mode;
; `nosync` sets the `:nosync` environment flag and syncs once at the
; end, and names its phases `create-nosync` and `load-nosync`.
; The runner substitutes the store directory for @STORE@ and the mode
; for @MODE@ and passes the text to `dtlv exec`, which prints the value
; of every top-level form; the runner reads the `phase=` strings.

(def path "@STORE@")
(def nosync (= "nosync" "@MODE@"))
(def suffix (if nosync "-nosync" ""))
(def n-people 100000)
(def batch 1000)
(def out (atom []))

; ns is taken before the answer is computed: arguments evaluate left
; to right, so a check query after the work stays outside the time.
(defn report [phase ns answer]
  (swap! out conj (str "phase=" phase suffix " ns=" ns " answer=" answer)))

(def schema
  {:dept/name {:db/valueType :db.type/string :db/cardinality :db.cardinality/one
               :db/unique :db.unique/identity}
   :person/email {:db/valueType :db.type/string :db/cardinality :db.cardinality/one
                  :db/unique :db.unique/identity}
   :person/name {:db/valueType :db.type/string :db/cardinality :db.cardinality/one}
   :person/age {:db/valueType :db.type/long :db/cardinality :db.cardinality/one}
   :person/dept {:db/valueType :db.type/ref :db/cardinality :db.cardinality/one}
   :person/salary {:db/valueType :db.type/long :db/cardinality :db.cardinality/one}})

(defn person [i dept-eids]
  {:person/email (str "p" i "@x.org")
   :person/name (str "name-" i)
   :person/age (+ 18 (mod (* i 7) 60))
   :person/dept (nth dept-eids (mod i 100))
   :person/salary (+ 30000 (mod (* i 7919) 90001))})

(def conn nil)
(def dept-eids nil)

(let [t0 (system-time)
      c (get-conn path schema)
      _ (when nosync (set-env-flags (datalog-kv c) #{:nosync} true))
      _ (transact! c (mapv (fn [k] {:dept/name (str "d" k)}) (range 100)))
      dept-map (into {} (q (quote [:find ?n ?e :where [?e :dept/name ?n]]) (db c)))]
  (def conn c)
  (def dept-eids (mapv (fn [k] (get dept-map (str "d" k))) (range 100)))
  (report "create" (- (system-time) t0) (count dept-eids)))

(let [t1 (system-time)]
  (loop [start 0]
    (when (< start n-people)
      (transact! conn (mapv (fn [i] (person i dept-eids)) (range start (+ start batch))))
      (recur (+ start batch))))
  (when nosync (datalevin.core/sync (datalog-kv conn)))
  (report "load" (- (system-time) t1) (q (quote [:find (count ?e) . :where [?e :person/email]]) (db conn))))

(close conn)
@out
