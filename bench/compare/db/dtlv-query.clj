; bench/compare/db/dtlv-query.clj — the Datalevin twin of
; nexis-query.nx: reopen the store dtlv-load.clj built and time the
; same operations. Datalevin keeps no history, so there is no
; as-of/history phase (docs/BENCH.md §12). Run as dtlv-load.clj is.

(def path "@STORE@")
(def out (atom []))

; ns is taken before the answer is computed: arguments evaluate left
; to right, so a check query after the work stays outside the time.
(defn report [phase ns answer]
  (swap! out conj (str "phase=" phase " ns=" ns " answer=" answer))
  nil)

(defn email [i] (str "p" i "@x.org"))

(def t-open (system-time))
(def conn (get-conn path))
(def db0 (db conn))
(report "open" (- (system-time) t-open) (some? (entid db0 [:dept/name "d0"])))

(let [t0 (system-time)
      total (loop [i 0 acc 0]
              (if (< i 10000)
                (recur (inc i) (+ acc (:person/age (entity db0 [:person/email (email (* i 10))]))))
                acc))]
  (report "lookup-10k" (- (system-time) t0) total))

(let [t0 (system-time)
      total (loop [k 0 acc 0]
              (if (< k 20)
                (recur (inc k)
                       (+ acc (count (q (quote [:find ?p ?name :in $ ?dn
                                                :where [?d :dept/name ?dn] [?p :person/dept ?d] [?p :person/name ?name]])
                                        db0 (str "d" k)))))
                acc))]
  (report "join3-20x" (- (system-time) t0) total))

(let [t0 (system-time)
      rows (q (quote [:find ?dn (sum ?s) :with ?p
                      :where [?p :person/dept ?d] [?d :dept/name ?dn] [?p :person/salary ?s]])
              db0)]
  (report "aggregate" (- (system-time) t0) (str (count rows) "/" (reduce + (map second rows)))))

(let [eids (mapv (fn [i] (entid db0 [:person/email (email (* i 10))])) (range 10000))
      t0 (system-time)
      res (pull-many db0 [:person/name :person/age {:person/dept [:dept/name]}] eids)]
  (report "pull-10k" (- (system-time) t0) (str (count res) "/" (reduce + (map :person/age res)) "/"
                             (count (filter (fn [r] (:dept/name (:person/dept r))) res)))))

; The lookups and the pull again over other people (offset p = 1..9,
; nine passes), each pass timed: the median pass, and the answers'
; total. Neither goes through a query, so no result cache applies; a
; JVM has compiled the paths by then.
(defn median [xs] (nth (vec (sort xs)) (quot (dec (count xs)) 2)))

(let [passes (mapv (fn [p]
                     (let [t0 (system-time)
                           total (loop [i 0 acc 0]
                                   (if (< i 10000)
                                     (recur (inc i) (+ acc (:person/age (entity db0 [:person/email (email (+ p (* i 10)))]))))
                                     acc))]
                       [(- (system-time) t0) total]))
                   (range 1 10))]
  (report "lookup-10k-warm" (median (map first passes)) (reduce + (map second passes))))

(let [pattern [:person/name :person/age {:person/dept [:dept/name]}]
      passes (mapv (fn [p]
                     (let [eids (mapv (fn [i] (entid db0 [:person/email (email (+ p (* i 10)))])) (range 10000))
                           t0 (system-time)
                           res (pull-many db0 pattern eids)
                           ns (- (system-time) t0)]
                       [ns (reduce + (map :person/age res))]))
                   (range 1 10))]
  (report "pull-10k-warm" (median (map first passes)) (reduce + (map second passes))))

(def salary-sum-q
  (quote [:find (sum ?s) . :with ?p :in $ [?em ...] :where [?p :person/email ?em] [?p :person/salary ?s]]))
(def first-1000 (mapv email (range 1000)))

; The three batches of nexis-query.nx, the same writes: Datalevin's
; default commit, which syncs; the same again, its durable row; and
; with the :nosync flag and one sync at the end.
(let [t0 (system-time)]
  (dotimes [i 1000]
    (transact! conn [[:db/add [:person/email (email i)] :person/salary (inc i)]]))
  (report "tx-1k-default" (- (system-time) t0) (q salary-sum-q (db conn) first-1000)))

(let [t0 (system-time)]
  (dotimes [i 1000]
    (transact! conn [[:db/add [:person/email (email i)] :person/salary (+ 2 i)]]))
  (report "tx-1k-durable" (- (system-time) t0) (q salary-sum-q (db conn) first-1000)))

(let [t0 (system-time)
      kv (datalog-kv conn)]
  (set-env-flags kv #{:nosync} true)
  (dotimes [i 1000]
    (transact! conn [[:db/add [:person/email (email i)] :person/salary (+ 3 i)]]))
  (datalevin.core/sync kv)
  (set-env-flags kv #{:nosync} false)
  (report "tx-1k-nosync" (- (system-time) t0) (q salary-sum-q (db conn) first-1000)))

; The entity batches of nexis-query.nx, in Datalevin's default commit:
; 1,000 new people, then 1,000 upserts through the unique email.
(def dept-eids (let [d (db conn)] (mapv (fn [k] (entid d [:dept/name (str "d" k)])) (range 100))))
(defn person [i salary]
  {:person/email (email i) :person/name (str "name-" i) :person/age (+ 18 (mod (* i 7) 60))
   :person/dept (nth dept-eids (mod i 100)) :person/salary salary})
(def upserted (mapv email (range 1000 2000)))

(let [t0 (system-time)]
  (dotimes [i 1000]
    (transact! conn [(person (+ 100000 i) (+ 30000 i))]))
  (report "tx-entity-1k" (- (system-time) t0) (q (quote [:find (count ?e) . :where [?e :person/email]]) (db conn))))

(let [t0 (system-time)]
  (dotimes [i 1000]
    (transact! conn [(person (+ 1000 i) (+ 4 i))]))
  (report "tx-upsert-1k" (- (system-time) t0) (q salary-sum-q (db conn) upserted)))

(close conn)
@out
