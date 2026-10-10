;; Generates test/regex/corpus.json, the differential corpus of the
;; regex engine (docs/REGEX.md §7): random patterns from a grammar of
;; the constructs nexis supports and random inputs, each run through
;; java.util.regex's find loop by the JVM that runs this script.
;; Run from the repository root (the run is deterministic per seed):
;;   bb test/regex/corpus.clj > test/regex/corpus.json
;; Each line is [pattern, input, result]: result is the list of every
;; find's groups (null for a group that did not take part), "ERR" when
;; Java refuses the pattern, or "TIMEOUT" when Java runs past a second.

(require '[cheshire.core :as json])

(def seeds [7 11 13])
(def per-seed 3000)

(def ^:dynamic ^java.util.Random *rng* nil)
(defn pick [xs] (nth xs (.nextInt *rng* (count xs))))
(defn chance [n] (zero? (.nextInt *rng* n)))

(def atoms
  ["a" "b" "x" "é" "É" "😀" "\\n" "\\r" "." "[ab]" "[^a]" "[a-c&&[^b]]" "\\w" "\\s" "\\d" "\\W" "\\v" "\\h"
   "\\R" "\\p{Alpha}" "[\\w&&[^\\d]]" "[é😀]" "[^é]" "\\x{1F600}" "\\Q.x\\E" "\\p{L}" "\\p{Lu}" "\\pN" "\\P{L}"
   "[\\p{L}&&[^a]]" "\\u0301" "(?i:a)" "(?i:É)" "(?iu:é)" "(?iu:ſ)" "(?iu:[r-t])" "(?iu:ß)" "(?iu:xς)" "K"])
(def asserts ["^" "$" "\\b" "\\B" "\\A" "\\z" "\\Z" "\\G"])
(def quants ["*" "+" "?" "{2}" "{1,}" "{0,2}" "{1,3}"])
(def flag-groups ["(?m:" "(?s:" "(?d:" "(?-i:" "(?i:" "(?x:" "(?iu:"])

(def names (atom 0))

(defn gen [depth]
  (let [r (.nextInt *rng* 10)]
    (cond
      (or (<= depth 0) (< r 4)) (if (chance 5) (pick asserts) (pick atoms))
      (< r 6) (apply str (repeatedly (inc (.nextInt *rng* 3)) #(gen (dec depth))))
      (< r 7) (str (gen (dec depth)) "|" (gen (dec depth)))
      (< r 9) (let [q (pick quants)]
                (str (pick [(str "(" (gen (dec depth)) ")")
                            (str "(?:" (gen (dec depth)) ")")
                            (pick atoms)])
                     q (if (chance 3) "?" "")))
      :else (str (pick ["(" "(?:" (str "(?<n" (swap! names inc) ">") (pick flag-groups)])
                 (gen (dec depth)) ")"))))

(def pieces ["a" "b" "x" "1" " " "é" "É" "😀" "\n" "\r\n" "\r" " " "A" "́" "ſ" "ß" "ẞ" "ς" "Σ" "K"])

(defn deadline-seq [^String s ^long until]
  (reify CharSequence
    (length [_] (.length s))
    (charAt [_ i]
      (when (> (System/nanoTime) until) (throw (ex-info "timeout" {:timeout true})))
      (.charAt s i))
    (subSequence [_ a b] (.subSequence s a b))
    (toString [_] s)))

(defn high? [^String s i] (and (pos? i) (< i (count s)) (Character/isHighSurrogate (.charAt s (dec i)))))

(defn run-java [p ^String s]
  (try
    (let [m (re-matcher (re-pattern p) (deadline-seq s (+ (System/nanoTime) 1000000000)))]
      (loop [acc []]
        (if (.find m)
          (let [st (.start m) en (.end m)]
            (cond
              ;; An empty match inside a surrogate pair: nexis steps by code points.
              (and (= st en) (high? s st)) (recur acc)
              (or (high? s st) (high? s en)) :skip
              :else (recur (conj acc (vec (for [i (range (inc (.groupCount m)))] (.group m (int i))))))))
          acc)))
    (catch java.util.regex.PatternSyntaxException _ "ERR")
    (catch clojure.lang.ExceptionInfo e (if (:timeout (ex-data e)) "TIMEOUT" (throw e)))))

;; Constructs the grammar does not generate and regressions it rarely
;; reaches, run after the random cases.
(def hand-written
  [;; Every thread dies at an assertion before the first-byte prefilter skips.
   ["(?:\\ba)*\\bc" "ab c ab c"]
   ;; Classes, escapes, assertions, flags and the find loop.
   ["abc" "xabcabc"]
   ["a.c" "abc a\nc"]
   ["(?s)a.c" "a\nc"]
   ["a|ab" "ab"]
   ["(a|ab)(c|bcd)(d*)" "abcd"]
   ["a*" "baaa"]
   ["a+?" "aaa"]
   ["a{2,3}" "aaaaaaa"]
   ["a{2,}?" "aaaa"]
   ["a{0}" "a"]
   ["(a*)*" "b"]
   ["(a*)+" "b"]
   ["(a?)+" "aa"]
   ["(|a)*" "aa"]
   ["(|a)+" "aa"]
   ["(a|b)*" "ab"]
   ["(\\A)*" "a"]
   ["(\\A)?" "a"]
   ["()*" "a"]
   ["(a*)*b" "aab"]
   ["((a)|b)+" "ab"]
   ["(a)|b" "b"]
   ["x*" "éx"]
   ["." "😀a"]
   ["" "aé"]
   ["[^a]" "aé😀"]
   ["[é😀]+" "xé😀"]
   ["[\\x{1F600}-\\x{1F64F}]" "😁"]
   ["^a" "aa"]
   ["a$" "aa\n"]
   ["$" "a\r\n"]
   ["(?m)^" "a\nb\r\nc"]
   ["(?m)$" "a\nb\r\nc"]
   ["(?m)^" ""]
   ["\\Z" "a\n"]
   ["\\z" "a\n"]
   ["\\Aa" "aa"]
   ["\\G\\w" "ab c"]
   ["\\bx\\b" "x xx x"]
   ["\\B" "ab c"]
   ["(?d)$" "a\r\n"]
   ["(?d)(?m)^." "a\rb\nc"]
   ["(?d)." "\r"]
   ["." "\u0085\u2028x"]
   ["\\R" "\r\n\n\r"]
   ["\\R{2,}" "\r\n"]
   ["\\R\\n" "\r\n"]
   ["(?:\\R)?\\n" "\r\n"]
   ["(\\R){2}" "\r\n\n"]
   ["\\d+\\s\\w+" "12 ab_c"]
   ["\\D\\S\\W" "a b!"]
   ["\\h\\v" " \n"]
   ["[\\w&&[^\\d]]+" "ab12c"]
   ["[a-z&&[^aeiou]]+" "hello"]
   ["[^a-c]" "abcd"]
   ["[]a]" "]"]
   ["[a-]" "-"]
   ["[\\d-z]" "-z"]
   ["[-\\w&&]" "-a"]
   ["[a&&&&b]" "ab"]
   ["[^a[b]]" "abc"]
   ["[a[^b]]" "bc"]
   ["\\p{Lower}+" "abC"]
   ["\\p{Punct}" "a!"]
   ["\\P{Alpha}" "a1"]
   ["\\p{XDigit}+" "0fG"]
   ["[\\p{Digit}x]+" "1x2y"]
   ["(?i)abc" "ABC aBc"]
   ["(?i)[a-c]+" "AbCd"]
   ["(?i)[^a]" "Ab"]
   ["(?i)\\u00e9" "É"]
   ["(?i)k" "K"]
   ["(?:a(?i)b)B" "aBB"]
   ["(a(?i)b)c" "aBc"]
   ["(?i:a)b" "AbAB"]
   ["(?-i:a)" "A"]
   ["(?x) a b # c\n c" "abc"]
   ["(?x)[a b]" " b"]
   ["(?x)a\\ b" "a b"]
   ["\\Qa.b\\E." "a.bc"]
   ["\\Qab\\E*" "abbb"]
   ["[\\Qa-c\\E]" "b-"]
   ["\\x31\\Q2\\E" "12"]
   ["\\Qa" "a"]
   ["\\t\\n\\x41\\u0042\\0101\\cA\\x{43}" "\t\nABA\u0001C"]
   ["\\ud83d\\ude00" "😀"]
   ["\\0400" " 0"]
   ["a\\." "a.ab"]
   ["\\_" "_"]
   ["(?<year>\\d{4})-(?<mon>\\d\\d)" "2024-05"]
   ["{1}" "a"]
   ["a{2}{3}" "aaaaaa"]
   ["^*a" "a"]
   ["\\b*" "a"]
   ["(x+x+)+y" "xxxxxxxxxxxxxxxxxxxx"]
   ["(a|aa)*c" "aaaaaaaaaaaaaaaaaaaaaaaaab"]
   ;; (?iu) folds by Java's case mappings; \p names general categories.
   ["(?iu)É" "é"]
   ["(?iu)k" "K"]
   ["(?i)É" "é"]
   ["(?iu)[à-ê]" "Ê"]
   ["(?iu)[^é]" "Éx"]
   ["(?iu)s" "ſS"]
   ["(?iu)[s]" "ſ"]
   ["(?iu)[r-t]" "ſ"]
   ["(?iu)ß" "ẞ"]
   ["(?iu)xß" "xẞ"]
   ["(?iu)ẞ" "ß"]
   ["(?iu)[ß]" "ẞ"]
   ["(?iu)[ß-ß]" "ẞ"]
   ["(?iu)σ" "ςΣ"]
   ["(?iu)xς" "xσxΣ"]
   ["(?iu)ǅ" "ǆǄ"]
   ["(?iu)[Ǆ-ǆ]" "ǅ"]
   ["(?iu)[\\w]" "ſK"]
   ["(?iu)\\p{Lower}" "Aé"]
   ["(?iu)i" "İıI"]
   ["(?iu)İ" "iıI"]
   ["(?iu)[ÿ]" "Ÿ"]
   ["(?iu)µ" "Μμ"]
   ["\\p{L}+" "aé中1"]
   ["\\p{Lu}" "aÉ"]
   ["\\pL" "1x"]
   ["\\pLu" "Lu xu"]
   ["\\p{IsL}" "1é"]
   ["\\p{gc=Lu}" "aB"]
   ["\\p{general_category=Nd}" "a٣"]
   ["\\P{L}" "a1"]
   ["[\\p{L}&&[^a]]" "ab"]
   ["(?i)\\p{Lu}" "a"]
   ["(?i)\\p{IsLt}" "a"]
   ["\\p{LC}" "ǅʰ"]
   ["\\p{LD}" "_٣"]
   ["\\p{L1}" "Āÿ"]
   ["\\p{all}" "\n"]
   ["\\p{Cn}" "a\u0378"]
   ["\\p{Zs}" "a\u3000"]
   ["\\p{Mn}" "a\u0301"]
   ["\\p{Sc}" "$€"]
   ["\\p{Pi}" "«"]
   ["\\p{IsN}+" "1½Ⅷ"]
   ["\\p{gc=Alpha}" "éa"]
   ["[^\\p{IsZ}\\p{C}]" " \u0000a"]
   ["\\b\u0301" "a\u0301"]
   ["\\b" "a\u0301 \u0301"]
   ["\u0301\\b" "é\u0301 x\u0301\u0301."]
   ["\\B" "\u0301\u0301"]
   ;; The literal prefix, the first-byte prefilter and anchoring find what the VM alone finds.
   ["abc+" "xxabxabcc"]
   ["[xy]z" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaxzyz"]
   ["[é😀]z" "aaaaé😀z"]
   ["^ab" "abab"]
   ["^a|^b" "bab"]
   ["^a|^b" "xab"]
   ["(?:^a|(^b))c" "bcac"]
   ["(?m)^ab" "ab\nab"]])

(doseq [seed seeds]
  (binding [*rng* (java.util.Random. seed)]
    (loop [n 0]
      (when (< n per-seed)
        (let [p (gen 5)
              s (apply str (repeatedly (.nextInt *rng* 8) #(pick pieces)))
              r (run-java p s)]
          (if (= r :skip)
            (recur n)
            (do (println (json/generate-string [p s r])) (recur (inc n)))))))))

(doseq [[p s] hand-written]
  (println (json/generate-string [p s (run-java p s)])))
