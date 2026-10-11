## BIGNUM.md — Arbitrary-Precision Integer Heap Kind

The contract for the `bignum` heap kind (`src/bignum.zig`): the
canonical form that keeps the integer tower's equality and hash
consistent without a cross-kind rule, the layout, and the arithmetic
the VM's numeric tower builds on (PLAN §23 #10; SEMANTICS §2.2). Kind
number: `docs/VALUE.md` §2.2. Header bits: `docs/HEAP.md`. Equality
category and hash domain: `docs/SEMANTICS.md` §3.3. Serializable:
`docs/CODEC.md` §3.

The module provides construction, canonical form, equality, hash, the
arithmetic `add sub mul quot rem mod neg abs`, ordering, conversion to
and from `f64` and `i64`, and decimal parsing and printing.

**Absent.** GCD, bitwise operations beyond 64 bits (the `bit-*`
natives work on 64-bit two's complement), modular exponentiation,
rationals, multi-precision floats and decimals (PLAN §23 #10); interned
small bignums (§1 forbids them); metadata (`with-meta` is
`:no-metadata-on-immediate`, SEMANTICS §7). Integer literals are the
reader's and compiler's (`docs/FORMS.md` §3); this module parses the
decimal text they hand it.

---

### 1. The canonical form

**Two mathematically equal integers always have one runtime form.**
Concretely:

1. No bignum's value fits the fixnum range, `[-2⁴⁷, 2⁴⁷ - 1]` (i48,
   asymmetric as two's complement is; `value.fixnum_min` /
   `fixnum_max`).
2. No bignum has magnitude zero: every zero, whatever the sign of the
   input, is `fixnum(0)`.
3. No bignum has a trailing zero limb: the highest limb is nonzero.

Every path that produces an integer from limbs (the constructors, the
arithmetic, the codec's decode) goes through the one canonicalizer
(§3). A path that bypassed it would silently break `=` and `hash`
across the fixnum/bignum boundary.

---

### 2. Body layout (subkind 0)

The body is an 8-byte prefix, `negative: u8` (0 or 1, never anything
else) and 7 bytes of `_pad`, followed by the magnitude as `u64` limbs,
least significant first. The limb count is `(body.len - 8) / 8`; there
is no count field. `_pad` is never hashed or compared.

Every bignum on the heap satisfies: `body.len ≥ 16` and `(body.len - 8)
% 8 == 0` (at least one limb), a nonzero top limb, and a value outside
the fixnum range. The canonicalizer asserts the shape at construction
in safe builds, and `headerLimbs` re-asserts it on every read.

---

### 3. Canonicalization

`fromLimbs(heap, negative, limbs)` takes a sign and a possibly
non-canonical little-endian magnitude and is the only place that
decides the kind of a result: every constructor and every operation
ends in it. Its steps, each short-circuiting:

1. Trim trailing zero limbs.
2. An empty magnitude is `fixnum(0)`, whatever `negative` says (no
   signed zero in the integer tower, SEMANTICS §2.2).
3. A one-limb magnitude in range is a fixnum: `limb ≤ 2⁴⁷ - 1` when
   non-negative, `limb ≤ 2⁴⁷` when negative (the magnitude 2⁴⁷ is
   `fixnum(-2⁴⁷)` and no positive fixnum).
4. Otherwise one allocation of `8 + n·8` bytes, sign and trimmed limbs
   copied in.

Steps 1 to 3 never allocate; only step 4 can fail, with `heap.alloc`'s
`error.OutOfMemory` or `error.Overflow`. There is no bignum-specific
error.

---

### 4. Public API (`src/bignum.zig`)

Every integer operand may be a fixnum or a bignum; every integer result
is canonical (§1).

| Function | Contract |
|---|---|
| `fromI64(heap, n)`, `fromI128(heap, n)` | the canonical integer; `i64.min` per §7 |
| `fromLimbs(heap, negative, limbs)` | sign and magnitude, trailing zeros allowed, empty is `fixnum(0)` |
| `isNegative(v)`, `limbs(v)`, `limbCount(v)` | bignum only (asserted); `limbs` borrows the heap body |
| `isInteger(v)` | fixnum or bignum |
| `view(v, scratch)` | the integer as a `std.math.big.int.Const` in place; `scratch` backs a fixnum's one limb |
| `add`, `sub`, `mul` | exact |
| `product(heap, first, rest)` | `first` times every integer of `rest`, exact; the partial products stay in scratch buffers (§8) |
| `quot`, `rem`, `mod` | §8 |
| `quotExact(heap, a, b)` | the quotient when the division is exact, null otherwise |
| `quotientF64(heap, a, b)` | `a / b` as the nearest double, ties to even, for operands of any size (§8) |
| `neg`, `abs` | exact |
| `compare(a, b)`, `isEven(v)` | `std.math.Order`; parity |
| `toF64(v)` | the nearest double, ties to even; an infinity beyond `f64`'s range |
| `fromF64(heap, f)` | the integer part (toward zero) of a finite double; null for NaN and the infinities |
| `toI64(v)` | the value when it fits `i64`, null otherwise |
| `formatDecimal(v, writer)`, `parseDecimal(heap, text)` | §8 |
| `hashHeader(h) u32`, `limbsEqual(a, b)` | §5, §6 |

`Limb` (`std.math.big.Limb`, `u64` on the 64-bit target) and
`subkind_limbs` (0) are public.

---

### 5. Hash

`hashHeader` is `hash.combineOrdered` of the sign (1 negative, 0 not)
and xxHash3 (the runtime seed) of the limb bytes, never the padding; truncated to `u32` and cached in
the header when nonzero (the HEAP.md cache rule).
`dispatch.hashValue` mixes the kind's domain in on top (SEMANTICS
§3.3).

---

### 6. Equality

`limbsEqual` is true for the same header, or the same sign, the same
limb count and equal limbs; the padding is not compared. Canonical form
makes that exactly equality of value. Bignums are not deduplicated:
the same value built twice is two allocations, `=` but not
`identical?`.

---

### 7. `i64.min`

`-i64.min` overflows `i64`, since `|i64.min| = 2⁶³`. `fromI64` negates
in `u64` space instead (`~@as(u64, @bitCast(n)) +% 1`), which gives 2⁶³
in one limb, and hands the sign and magnitude to the canonicalizer:
`-2⁴⁷` becomes a fixnum, `-2⁶³` a one-limb bignum.
`(- -9223372036854775808)` is `9223372036854775808`.

---

### 8. Arithmetic

The limb arithmetic is `std.math.big.int`. A heap bignum's body, sign
byte and little-endian `u64` limbs, is read in place as a
`big.int.Const` (`view`); a fixnum is viewed through a one-limb scratch
cell. A result is computed into a scratch buffer (on the stack up to 64
limbs, from the heap's backing allocator beyond) and copied onto the
heap once through the canonicalizer, so `(- (+ a b) b)` is a fixnum
again whenever `a` was, and a zero result is `fixnum(0)` whatever the
operands' signs. `product` multiplies a run of integers in two scratch
buffers that take turns as the running product, so only the result
reaches the heap: `*` over many integers is one native call, inside
which nothing is collected, and a fold through `mul` would leave every
partial product there. `*` hands it the rest of its arguments once its
product is a bignum and every argument left is an integer.

The semantics match Clojure's `Numbers` for BigInt:

- `quot` truncates; `rem` is the remainder of truncated division, with
  the dividend's sign; `mod` is the remainder of floored division, with
  the divisor's sign. A zero divisor is the caller's to raise
  (`:divide-by-zero`); the functions assert it away.
- `neg` and `abs` of `fixnum_min` promote: 2⁴⁷ is a bignum.
- `parseDecimal` accepts exactly `-?[0-9]+` and returns null for
  anything else. Up to 18 digits it reads an `i64`, and up to 4 000
  `std`'s conversion, one multiply-add over the whole number per 19
  digits. Past that it divides and conquers, so text from outside
  (JSON, `read-string`) of any length costs subquadratic time: the
  digits are `hi · 10^k + lo`, `lo` the last half of them, each half
  read the same way, `10^k` the product of its own halves (cached by
  `k`, two per level), and each product, of two numbers of one size,
  `std`'s Karatsuba multiply. Its time grows as about the 1.6th power
  of the digits: 400 000 digits read in about a tenth of a second
  (`-Doptimize=fast`), where `std`'s conversion alone takes over half
  a second, and a million in under a second.
- `formatDecimal` writes decimal digits with a leading `-` for a
  negative value and no suffix. Past 32 limbs it divides and conquers:
  it splits the value at 10^(9·2^i), the power whose square first
  exceeds it, and writes the quotient and the zero-padded remainder the
  same way, so the whole conversion costs about one division of the
  value by its square root instead of one pass per nine digits; a
  million digits print in about a second (`-Doptimize=fast`). Its
  scratch comes from the page allocator, since a printer holds no heap:
  `NEXIS_MAX_ALLOC` does not bound it, and running out of it is the
  writer's `WriteFailed`.

The VM's tower (`src/vm.zig` `numAdd` through `numCompare`) keeps the
fixnum-by-fixnum fast path in `i64` and calls this module only when a
result leaves the fixnum range or an operand is already a bignum: `(+
140737488355327 1)` is the bignum `140737488355328`. A float operand
takes the `f64` path instead, `toF64` widening a bignum operand
(SEMANTICS §2.2 contagion). `/` of two integers is `quotExact`'s
integer when the division is exact and otherwise `quotientF64`: the
quotient scaled to 55 or 56 bits by a power of two, a sticky bit for
the remainder, rounded once to 53 bits or to the subnormal grid, so
`10^400 / (3·10^399)` is `3.3333333333333335` where two `toF64`s would
give `##Inf / ##Inf`. `long` of a float goes through `fromF64` (0 for
NaN, `:invalid-argument` for the infinities). The arithmetic operators promote and never raise
`:arithmetic-overflow`; a native that needs an `i64` argument (the
`bit-*` operations among them) raises it for a bignum beyond `i64`.

---

### 9. Tests

`test/prop/bignum.zig` holds the properties, `src/bignum.zig` the unit tests of the
canonicalizer, the accessors, conversion and printing, and
`test/integration/numbers.zig` runs the tower end to end through every
operator and predicate.

