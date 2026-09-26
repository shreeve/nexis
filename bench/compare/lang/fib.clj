; Naive doubly recursive fib 30: function calls and fixnum arithmetic.
(defn fib [n] (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
(let [t0 (now)] (report t0 (fib 30)))
