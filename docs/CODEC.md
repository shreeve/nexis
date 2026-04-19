## CODEC.md — Durable Wire Format (STUB)

**Status**: Phase 0 **stub**. Frozen in Phase 4 (PLAN §21). This document pins
down the *scope* of serialization now — the exact byte layout, varint choice,
and versioning tag format will land alongside Phase 4 once the runtime Value
layer is real.

Derivative from `PLAN.md` §15.6 and §15.10. PLAN.md wins on conflict.

The codec is the **single gateway** between runtime Values and durable bytes
(PLAN §15.10 non-negotiable scoping rule). It is deliberately narrow. Adding
a kind to the "Serializable" list requires a PLAN.md amendment.

---

### 1. Wire-format shape (to be fleshed out in Phase 4)

Self-describing, tagged (PLAN §15.6):

```
[kind:u8] [flags:u8] [len:varint] [payload...]
```

- `kind` matches `Value.tag.kind` where applicable; heap sub-kinds are
  encoded in the first byte of payload for heap-allocated forms.
- `len` is a varint-encoded length of `payload`. Whether we use LEB128,
  ZigZag, or a fixed encoding is a Phase 4 decision; note that integers
  inside collections may have their own length prefix.
- Integers use **ZigZag varint** (pending Phase 4 confirmation).
- Floats are **IEEE 754 big-endian**, with the canonical NaN bit pattern
  (SEMANTICS §2.2 / §3.2).
- Strings are UTF-8, length-prefixed.
- Keywords/symbols are emitted in **textual form** — never as intern ids.
  The receiver re-interns on decode.
- Collections are length-prefixed and recursive.
- Durable refs encode the identity triple `{store-id, tree-id, key-bytes}`.

The top-level encoded blob starts with a **version tag** so Phase 4+ can
evolve the format without breaking readers of prior data. Exact tag shape
(`u8 major ; u8 minor` vs `varint`) is TBD.

---

### 2. Serializable kinds (v1 scope — FROZEN)

From PLAN §15.10. Encoder guarantees round-trip for every kind in this
list; anything else throws `:unserializable`.

| Value kind | Notes |
|---|---|
| `nil` | single sentinel byte |
| `bool` | single byte |
| `char` | UTF-8-encoded Unicode scalar |
| `fixnum` | zig-zag varint |
| `bignum` | length-prefixed big-endian magnitude + sign byte |
| `float` (f64) | IEEE 754 big-endian, canonical NaN |
| `string` | UTF-8 bytes, length-prefixed |
| `keyword`, `symbol` | **textual form**, not intern id |
| `list`, `vector`, `map`, `set` | length-prefixed, recursive |
| `byte-vector` | raw bytes, length-prefixed |
| `typed-vector` | element type tag + little-endian element bytes |
| `durable-ref` | identity triple |

---

### 3. Non-serializable kinds (v1 — FROZEN)

| Value kind | Reason |
|---|---|
| `function` / closure | Code, upvalues, and captured VM state are process-local. |
| `var` | Identity + mutation machinery are process-local. Serialize the root value instead. |
| `transient` | Mutable by definition. Only `persistent!`-ed results cross the codec. |
| `namespace` | Process-local binding table. |
| `tx handle` / `emdb.Env` connection | Open OS resources. |
| `error` | Stack traces carry process-local frame references. |
| Any handle to files/devices/cursors | OS resources. |
| `record` (deferred) | Not defined in v1. |

Attempting to encode any of these throws `:unserializable {:kind <k>
:reason ...}`. The error kind is stable so tooling can match on it. No
silent stubs, no lossy round-trips.

---

### 4. Round-trip invariant (formal)

For every value `v` in the Serializable table:

- `(= v (codec/decode (codec/encode v)))` — value equality preserved.
- `(= (hash v) (hash (codec/decode (codec/encode v))))` — hash preserved.
- `(= v (codec/decode-bytes (codec/encode-to-bytes v)))` — byte-level
  stability.

This is **Phase 1 gate property test #5**, exercised on 10k+ randomized
values (PLAN §20.2).

---

### 5. What is **not** in this stub

- Exact byte layout per kind.
- Varint choice.
- Versioning byte(s).
- Schema-aware encoder shortcuts.
- Keyed ordering collation (those live in emdb's key encoder, reused
  verbatim per PLAN §2).

All of the above are Phase 4 deliverables. Phase 0 exists to prevent scope
creep before then.
