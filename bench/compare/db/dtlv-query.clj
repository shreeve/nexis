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

(def salary-sum-q
  (quote [:find (sum ?s) . :with ?p :in $ [?em ...] :where [?p :person/email ?em] [?p :person/salary ?s]]))
(def first-1000 (mapv email (range 1000)))

(let [t0 (system-time)]
  (dotimes [i 1000]
    (transact! conn [[:db/add [:person/email (email i)] :person/salary (inc i)]]))
  (report "tx-1k-durable" (- (system-time) t0) (q salary-sum-q (db conn) first-1000)))

(let [t0 (system-time)
      kv (datalog-kv conn)]
  (set-env-flags kv #{:nosync} true)
  (dotimes [i 1000]
    (transact! conn [[:db/add [:person/email (email i)] :person/salary (+ 2 i)]]))
  (datalevin.core/sync kv)
  (set-env-flags kv #{:nosync} false)
  (report "tx-1k-nosync" (- (system-time) t0) (q salary-sum-q (db conn) first-1000)))

(close conn)
@out
