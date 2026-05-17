# examples

Reserved for end-user-facing `.nx` example programs. Empty for now.

This directory will populate once step #7 (reader.Form integration)
lands and `.nx` source files compile end-to-end. Initial targets:

- `hello.nx` — `(println "hello, world")`
- `fact.nx` — recursive factorial via `defn` + `recur`
- `closures.nx` — `(let [counter (let [c 0] (fn [] ...))] ...)` style
- `defn.nx` — multi-fn programs showing forward references via Vars

See `PLAN.md` §21 Phase 3 for the larger roadmap that includes example
programs and the standard library bootstrap.
