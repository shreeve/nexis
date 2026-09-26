; Join 170,000 numbers into a 1.08 MB comma-separated string, split it
; back apart and total the piece lengths.
(let [t0 (now)
      big (s/join "," (map str (range 170000)))
      parts (split-comma big)
      total (reduce (fn [acc p] (+ acc (count p))) 0 parts)]
  (report t0 (str (count big) "/" (count parts) "/" total)))
