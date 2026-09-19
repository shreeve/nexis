## BIGNUM.md — Arbitrary-Precision Integer Heap Kind

Authoritative body-layout and semantic contract for the `bignum` heap kind. Derivative from `PLAN.md` §8.3,
`docs/VALUE.md` §2.2, `docs/SEMANTICS.md` §2.2 / §3.2, and `docs/HEAP.md`.
Those documents win on conflict. This doc pins the rules that are specific
to bignums — most importantly the **canonicalization invariant** that
makes the integer tower's equality and hash consistent without any
cross-kind comparison — and the arithmetic contract (§9) that the VM's
numeric tower (`docs/VM.md` §10.3, `src/vm.zig`) builds on.

The module ships construction, canonical form, equality, hash, the
arithmetic `add sub mul quot rem mod neg abs`, ordering, conversion
to and from f64 and i64, and decimal parsing and printing. GCD,
bitwise operations and modular exponentiation are not part of v1
(PLAN §8.3).

---

### 1. The canonicalization invariant (central)

**For integers, the runtime guarantees that two mathematically-equal
integers are always represented by exactly one runtime kind/value form
in v1.** Everything else in this document is in service of that rule.

Consequences that the implementation must enforce without exception:

1. **No bignum whose magnitude fits in i48 may exist.** Fixnum range
   (per `src/value.zig`) is `[-(2⁴⁷), 2⁴⁷ - 1]` inclusive — asymmetric
   bounds as in standard two's-complement i48.
2. **No bignum with magnitude zero may exist.** Any zero magnitude —
   regardless of sign input — collapses to `fixnum(0)`.
3. **No bignum with trailing zero limbs may exist.** Canonical magnitude
   has the highest-index limb non-zero.

Every code path that could construct a bignum goes through exactly
one canonicalization function (§3). Arithmetic results, codec decode
and direct API constructors all funnel there. If any path
bypasses it, integer equality silently breaks.

---

### 2. Body layout (subkind 0)

```zig
// Private body prefix. 8 bytes, followed by a variable number of
// u64 limbs. Total body size = 8 + limb_count * 8.
const BignumBody = extern struct {
    negative: u8,     // 0 = non-negative, 1 = negative. Never any other value.
    _pad: [7]u8,      // align limbs to 8; NEVER hashed, NEVER compared
    // limbs: [limb_count]u64 follow immediately; limb[0] is LSW
};
```

- **Little-endian limb order** — `limb[0]` is least-significant.
- **u64 limbs** — natural on the 64-bit-only target.
- **`negative` is a byte holding 0 or 1 only**; `isNegative(v)` reads this byte and safe-asserts the value is in `{0, 1}`.
- **Limb count is inferred** from body length: `limb_count = (body.len - 8) / 8`. No redundant count field in the body.
- **`_pad` is semantically invisible** — hashing and equality explicitly ignore it (hashing raw body bytes would bake layout detail into the hash output).

**Canonical constraints** (every bignum on the heap satisfies all of these):

- `body.len >= 8`
- `(body.len - 8) % 8 == 0`
- `body.len >= 16` (at least one limb, because zero magnitudes don't exist)
- `limbs[limb_count - 1] != 0` (no trailing zero limbs)
- Magnitude computed from the limbs is **strictly outside** the fixnum range.

Structural validity of a heap-loaded bignum is safe-asserted at traversal entry; canonicality is asserted at construction time, not re-checked on every read.

---

### 3. Canonicalization — the only construction path

```zig
/// Private. Takes possibly-non-canonical input; returns either a
/// fixnum Value or a bignum Value. This is the ONLY place that
/// decides which kind to produce.
fn canonicalizeToValue(
    heap: *Heap,
    negative: bool,
    limbs: []const u64, // may have trailing zeros; may be empty
) !Value;
```

Steps, in order (each step short-circuits):

1. **Trim trailing zero limbs.** Scan `limbs` high-to-low; drop zeros.
2. **Zero magnitude → `fixnum(0)`**. If all limbs were zero (including empty input slice), return `Value.fromFixnum(0).?` regardless of the input `negative` flag. This is the enforcement point for "no signed zero in the integer tower" (SEMANTICS §2.2).
3. **Fixnum-range magnitude → fixnum.** If trimmed length is 1 and the single limb fits in i48 with the given sign, return a fixnum. Sign-aware range check:
   - `negative == false`: representable iff `limb[0] <= fixnum_max` = `2⁴⁷ - 1`.
   - `negative == true`:  representable iff `limb[0] <= |fixnum_min|` = `2⁴⁷`.
   Note the asymmetry: the magnitude `2⁴⁷` (exactly) is representable as `fixnum(-2⁴⁷)` but not as any positive fixnum.
4. **Otherwise — allocate a bignum**. One allocation of exactly `8 + trimmed_limb_count * 8` bytes. Copy the trimmed limbs into the body. Set `negative` byte. Return the heap-backed Value.

The first three steps are pure (no allocation). Step 4 is the only path that touches the heap. This makes OOM handling clean: the first three branches are infallible; only step 4 returns an error.

**Debug assertion after step 4**: the freshly-constructed bignum satisfies every constraint in §2. If this fails, the canonicalizer itself has a bug.

---

### 4. Public API

Lives in `src/bignum.zig`.

```zig
/// Integer-tower-aware constructor. Returns either a fixnum or a
/// bignum Value depending on magnitude; callers never see the
/// distinction at this layer. Handles i64.min (|i64.min| = 2⁶³,
/// which fits in a single u64 limb) via two's-complement negation.
pub fn fromI64(heap: *Heap, n: i64) !value.Value;

/// Construct from a sign + little-endian u64-limb magnitude. Input
/// may have trailing zero limbs, may be empty. Canonicalizes
/// (§3) before returning. An empty `limbs` slice returns `fixnum(0)`
/// regardless of `negative`.
pub fn fromLimbs(
    heap: *Heap,
    negative: bool,
    limbs: []const u64,
) !value.Value;

/// Bignum-only accessors. All safe-assert `v.kind() == .bignum`.
pub fn isNegative(v: value.Value) bool;
pub fn limbs(v: value.Value) []const u64;
pub fn limbCount(v: value.Value) usize;

/// Per-kind hash entry point. Called by `dispatch.heapHashBase` via
/// the kind switch. Cached in `HeapHeader.hash` with the cache-if-
/// nonzero pattern (VALUE.md §4).
pub fn hashHeader(h: *HeapHeader) u32;

/// Per-kind equality entry point. Called by `dispatch.heapEqual`
/// after the cross-kind rule and bit-identity fast path have been
/// ruled out.
pub fn limbsEqual(a: *HeapHeader, b: *HeapHeader) bool;
```

**Error set.** Whatever `heap.alloc` returns (`error.OutOfMemory`,
`error.Overflow` from `std.math.add` when computing total size). No
bignum-specific error conditions.

---


**Arithmetic, ordering and conversion** (§9). Every integer operand
may be a fixnum or a bignum; every result is canonical.

```zig
pub const Limb = std.math.big.Limb;        // u64 on the 64-bit target
pub fn view(v: Value, scratch: *[1]Limb) std.math.big.int.Const;
pub fn isInteger(v: Value) bool;
pub fn fromI128(heap: *Heap, n: i128) !Value;
pub fn add(heap: *Heap, a: Value, b: Value) !Value;
pub fn sub(heap: *Heap, a: Value, b: Value) !Value;
pub fn mul(heap: *Heap, a: Value, b: Value) !Value;
pub fn quot(heap: *Heap, a: Value, b: Value) !Value;   // truncated quotient
pub fn quotExact(heap: *Heap, a: Value, b: Value) !?Value; // quotient iff exact
pub fn rem(heap: *Heap, a: Value, b: Value) !Value;    // dividend's sign
pub fn mod(heap: *Heap, a: Value, b: Value) !Value;    // divisor's sign
pub fn neg(heap: *Heap, a: Value) !Value;
pub fn abs(heap: *Heap, a: Value) !Value;
pub fn compare(a: Value, b: Value) std.math.Order;
pub fn isEven(v: Value) bool;
pub fn toF64(v: Value) f64;
pub fn fromF64(heap: *Heap, f: f64) !?Value;           // null for NaN / ±Inf
pub fn toI64(v: Value) ?i64;
pub fn formatDecimal(v: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void;
pub fn parseDecimal(heap: *Heap, text: []const u8) !?Value;
```

### 5. Hash — semantic bytes only

SEMANTICS.md §3.2: "xxHash3-32 over the canonical magnitude byte stream
plus sign byte." Concretely:

```
hash_input := [negative_byte] ++ limbs_as_little_endian_bytes
```

Where `limbs_as_little_endian_bytes` is `std.mem.sliceAsBytes(limbs)` on
our LE-only target. The `_pad` bytes from the body are **not** fed into
the hash: hashing raw body memory would
leak the 7 pad bytes into the hash output and couple hash stability to
layout detail.

Implementation:

```zig
var hasher = XxHash3.init(seed);
hasher.update(&[_]u8{ if (isNegative(h)) 1 else 0 });
hasher.update(std.mem.sliceAsBytes(bignumLimbs(h)));
const raw: u32 = @truncate(hasher.final());
if (raw != 0) h.setCachedHash(raw); // cache-if-nonzero (VALUE.md §4)
return raw;
```

---

### 6. Equality — semantic bytes only

Two canonical bignums are equal iff:

1. Their `negative` bytes match.
2. Their limb counts match.
3. Their limb byte streams match.

`limbsEqual(a, b)` returns the conjunction. Because canonical form has no
trailing zero limbs, step 2 implies equal magnitude ranges; `std.mem.eql`
on the limb byte slice covers the actual value comparison.

**Padding bytes are not compared.** Same rationale as hashing — they're
layout detail, not semantics.

### 6.1 What does NOT need to be true

- Two Values with `kind == .bignum` may have distinct `*HeapHeader`s but
  be structurally equal. `identical?` is pointer-based; `=` is
  structural.
- Bignums are not content-deduplicated. Constructing the same large
  value twice produces two distinct heap allocations that compare `=`.

---

### 7. `i64.min` magnitude conversion

Classic footgun: `-i64.min` overflows because `|i64.min| = 2⁶³ > i64.max`.

In `fromI64`:
- If `n >= 0`: `magnitude = @intCast(u64, n)`.
- If `n < 0`: `magnitude = (~@as(u64, @bitCast(n))) +% 1` — two's-complement
  negation in u64 space. For `n == i64.min`, this yields `2⁶³` correctly
  (fits in one u64 limb without overflow).

After magnitude is computed, the result flows through `canonicalizeToValue`
which handles the fixnum-range check (`-2⁴⁷` is representable as
`fixnum(-2⁴⁷)`; `-2⁶³` is not, so it allocates a bignum).

---

### 8. Dispatch integration

Two one-line additions to `src/dispatch.zig`:

- `heapHashBase` kind switch gains `.bignum => @as(u64, bignum.hashHeader(h)),`.
- `heapEqual` kind switch gains `.bignum => bignum.limbsEqual(ah, bh),`.

No changes to `eqCategory` (bignum is kind-local per SEMANTICS §2.6)
and no new domain byte — bignum uses the kind-byte domain like string.

---

### 9. Arithmetic

The limb arithmetic is `std.math.big.int`. A heap bignum's body —
sign byte, padding, little-endian `u64` limbs — is read in place as a
`big.int.Const` (`view`); a fixnum is viewed through a one-limb
scratch cell. Results are computed into a scratch buffer (on the
stack up to 64 limbs, from the heap's backing allocator beyond) and
copied onto the heap once through `canonicalizeToValue`, so every
result obeys §1 by construction: `(- (+ a b) b)` is a fixnum again
whenever `a` was, and a zero result is `fixnum(0)` whatever the signs
of the operands.

Semantics, matching Clojure's `Numbers` for BigInt:

- `add`, `sub`, `mul`: exact.
- `quot`: truncated quotient; `rem`: remainder of truncated division,
  the dividend's sign; `mod`: remainder of floored division, the
  divisor's sign. A zero divisor is the caller's error to raise
  (`:divide-by-zero`); the functions assert it away.
- `neg`, `abs`: `(neg fixnum_min)` and `(abs fixnum_min)` are the
  fixnum inputs whose results promote (2⁴⁷).
- `compare`: exact ordering of any two integers.
- `toF64`: the nearest double, ties to even; an infinity beyond
  f64's range. `fromF64`: the integer part of a finite double
  (toward zero), `null` for NaN and the infinities.
- `toI64`: the value when it fits, `null` otherwise.
- `formatDecimal` / `parseDecimal`: decimal text with a leading `-`
  for a negative value and no suffix; the parser accepts exactly
  `-?[0-9]+` and returns `null` for anything else.

The VM's tower (`src/vm.zig` `numAdd` … `numCompare`) keeps the
fixnum × fixnum fast path in `i64` and reaches this module only when
a result leaves the fixnum range or an operand is already a bignum;
any float operand takes the f64 path instead (SEMANTICS §2.2
contagion), with `toF64` widening a bignum operand.

### 10. Property test coverage

Alongside the module:

- `test/prop/bignum.zig` with ~8 properties:
  1. Round-trip: `fromI64(n)` for random i64 produces either a fixnum
     (if in range) or a bignum whose reconstructed magnitude equals `|n|`.
  2. Canonicalization: `fromLimbs(false, &.{5})` returns a fixnum, not a
     bignum.
  3. Canonicalization: `fromLimbs(true, &.{0, 0, 0})` returns `fixnum(0)`.
  4. No trailing zero limbs: every bignum escaping `fromLimbs` passes
     the invariant check.
  5. Equality reflexivity / symmetry / transitivity over random bignums.
  6. `equal ⇒ hash equal` (bedrock) over 500 random bignum pairs built
     from the same limb sequences in different allocations.
  7. Cross-kind: a bignum is never `=` to a fixnum, keyword, string,
     etc.; full `dispatch.hashValue` is different across categories.
  8. `i64.min` specifically round-trips: `fromI64(-9223372036854775808)`
     produces a bignum (out of fixnum range, magnitude = 2⁶³); its
     limb representation matches `{ negative = true, limbs = [2⁶³] }`.

---

### 11. What BIGNUM.md does not cover

- **Multi-precision floats, rationals, decimals.** Not in v1 per
  PLAN §8.3.
- **Interned small bignums.** Not applicable — canonicalization
  prevents small-magnitude bignums from existing at all.
- **Metadata.** Bignums are not metadata-attachable per PLAN §8.5 /
  SEMANTICS §7.
- **Literals.** The reader and compiler own the literal path
  (`docs/FORMS.md` §3, `docs/SEMANTICS.md` §6); this module only
  parses the decimal text they hand it.
