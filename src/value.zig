//! value.zig — 16-byte tagged runtime Value (Phase 1, immediates only).
//!
//! Authoritative physical layout spec is `docs/VALUE.md`. Equality and
//! hashing semantics live in `docs/SEMANTICS.md`. This file is the
//! implementation; frozen decisions belong in those docs.
//!
//! Phase 1 commit 1 scope: every immediate kind (nil, bool, char, fixnum,
//! float, keyword, symbol). Heap kinds (string, bignum, collections,
//! var, durable-ref, ...) are defined in the Kind enum but constructors
//! and accessors for them land in the per-module commits that actually
//! allocate the body.
//!
//! Design invariants enforced here (VALUE.md §3):
//!   - One canonical constructor per immediate kind.
//!   - Raw `tag` / `payload` writes are package-private (only `Value`'s
//!     own fns mutate them). Users always build Values through a
//!     constructor that enforces range / canonicalization invariants.
//!   - `nil == Value{}` — the all-zero bit pattern is a valid `nil`.
//!   - Every f64 stored in a `Value.float` is canonical form (SEMANTICS
//!     §3.2). NaN bit patterns are collapsed at construction.
//!   - `fromChar` rejects UTF-16 surrogate codepoints.
//!   - `fromFixnum` rejects values outside i48 range (±140 trillion);
//!     callers that need larger integers must go via the bignum path
//!     once it lands.

const std = @import("std");
const hash = @import("hash");

// =============================================================================
// Kind discriminator
//
// Numeric values are frozen per VALUE.md §2 so the Phase 2 bytecode
// dispatcher and the Phase 4 codec can use them as jump-table indices and
// wire tags with no remapping layer.
// =============================================================================

pub const Kind = enum(u8) {
    // ---- Immediates (payload lives inside the Value) ----
    nil = 0,
    false_ = 1,
    true_ = 2,
    char = 3,
    fixnum = 4,
    float = 5,
    keyword = 6,
    symbol = 7,
    // 8..15 reserved for future immediate kinds.

    // ---- Heap-allocated (payload is *HeapHeader) ----
    string = 16,
    bignum = 17,
    persistent_map = 18,
    persistent_set = 19,
    persistent_vector = 20,
    list = 21,
    byte_vector = 22,
    typed_vector = 23,
    function = 24,
    var_ = 25,
    durable_ref = 26,
    transient = 27,
    error_ = 28,
    meta_symbol = 29,
    // 30..63 reserved for future heap kinds.

    // ---- Runtime-private sentinels (never escape public API) ----
    unbound = 64,
    undef = 65,
    _,

    /// Does this kind store its entire value inside the tag+payload
    /// (no heap pointer)? Pure predicate — safe to use in tight loops.
    pub inline fn isImmediate(k: Kind) bool {
        const n: u8 = @intFromEnum(k);
        return n < 16;
    }

    /// Does the payload word hold a `*HeapHeader` pointer?
    pub inline fn isHeap(k: Kind) bool {
        const n: u8 = @intFromEnum(k);
        return n >= 16 and n < 64;
    }

    /// Private runtime sentinel — must never appear in a user-visible
    /// value position. Hitting this in `=` / `hash` is a runtime bug.
    pub inline fn isSentinel(k: Kind) bool {
        const n: u8 = @intFromEnum(k);
        return n >= 64;
    }
};

// =============================================================================
// Flag bits (tag[8..15])
// =============================================================================

pub const flag_has_meta: u8 = 1 << 0;
pub const flag_hash_cached: u8 = 1 << 1;
pub const flag_durable: u8 = 1 << 2;
// Bits 3..7 reserved.
//
// `flag_interned` was considered and rejected: the information is already
// carried by `kind == .keyword or kind == .symbol` (plus the future
// `meta_symbol` heap kind). A redundant flag creates a perpetual
// consistency invariant to maintain for no measurable speedup. Add it
// back only when a concrete hot path demonstrates it pays rent.

// =============================================================================
// Fixnum range constants (i48)
// =============================================================================

pub const fixnum_min: i64 = -(1 << 47);
pub const fixnum_max: i64 = (1 << 47) - 1;

/// Is `n` representable as a `fixnum` immediate? Callers that want
/// automatic bignum promotion check this first.
pub inline fn isFixnumRange(n: i64) bool {
    return n >= fixnum_min and n <= fixnum_max;
}

// =============================================================================
// Value — the 16-byte tagged cell
// =============================================================================

pub const Value = extern struct {
    tag: u64,
    payload: u64,

    comptime {
        std.debug.assert(@sizeOf(Value) == 16);
        std.debug.assert(@alignOf(Value) >= 8);
    }

    // ---- Accessors ----

    /// Primary discriminator. Cheap bit-shift on the tag word.
    pub inline fn kind(self: Value) Kind {
        return @enumFromInt(@as(u8, @truncate(self.tag)));
    }

    pub inline fn flags(self: Value) u8 {
        return @truncate(self.tag >> 8);
    }

    pub inline fn subkind(self: Value) u16 {
        return @truncate(self.tag >> 16);
    }

    pub inline fn aux(self: Value) u32 {
        return @truncate(self.tag >> 32);
    }

    // ---- Predicates ----

    pub inline fn isNil(self: Value) bool {
        return self.kind() == .nil;
    }

    pub inline fn isBool(self: Value) bool {
        const k = self.kind();
        return k == .true_ or k == .false_;
    }

    pub inline fn isChar(self: Value) bool {
        return self.kind() == .char;
    }

    pub inline fn isFixnum(self: Value) bool {
        return self.kind() == .fixnum;
    }

    pub inline fn isFloat(self: Value) bool {
        return self.kind() == .float;
    }

    pub inline fn isKeyword(self: Value) bool {
        return self.kind() == .keyword;
    }

    pub inline fn isSymbol(self: Value) bool {
        return self.kind() == .symbol;
    }

    pub inline fn isTruthy(self: Value) bool {
        // Only `nil` and `false` are falsy (PLAN §23 #13). Implemented
        // as a single equality check against a packed u16 of
        // `{kind, flags_low}` — nil and false_ sit at kinds 0 and 1
        // so we can check against their raw kind values cheaply.
        const k = @intFromEnum(self.kind());
        return k != 0 and k != 1;
    }

    // ---- Decoders (panic-free on well-constructed values) ----

    pub inline fn asBool(self: Value) bool {
        std.debug.assert(self.isBool());
        return self.kind() == .true_;
    }

    pub inline fn asChar(self: Value) u21 {
        std.debug.assert(self.isChar());
        return @intCast(self.payload & 0x1F_FFFF);
    }

    pub inline fn asFixnum(self: Value) i64 {
        std.debug.assert(self.isFixnum());
        // payload was sign-extended at construction; just bit-cast back.
        return @bitCast(self.payload);
    }

    pub inline fn asFloat(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return @bitCast(self.payload);
    }

    pub inline fn asKeywordId(self: Value) u32 {
        std.debug.assert(self.isKeyword());
        return @truncate(self.payload);
    }

    pub inline fn asSymbolId(self: Value) u32 {
        std.debug.assert(self.isSymbol());
        return @truncate(self.payload);
    }

    // ---- identical? — bit equality for immediates ----

    /// Bit-equality on the 16-byte struct. For heap kinds this compares
    /// the pointer word inside the payload (same `HeapHeader*` ⇒
    /// identical). Fast and cheap — single 128-bit compare on NEON/SSE.
    pub inline fn identicalTo(self: Value, other: Value) bool {
        return self.tag == other.tag and self.payload == other.payload;
    }

    // ---- Hash (immediates only in this commit) ----

    /// Immediate-kind semantic hash. Collapses `-0.0 / +0.0`, treats
    /// canonical NaN as reflexive, and mixes the kind byte so
    /// coincidentally-equal raw payload hashes (`fixnum(65)` vs
    /// `symbol(65)` vs `char(65)`) land in disjoint regions of the
    /// 64-bit hash space.
    ///
    /// **Partial function — heap kinds panic.** The method name carries
    /// the contract: "immediate" = "no heap allocation underneath."
    /// Full hashing over any Value kind goes through
    /// `dispatch.hashValue(v)`, which routes immediates here and heap
    /// kinds through per-kind hashers. `value.zig` stays low-level and
    /// does not import the heap-kind modules; placing the dispatcher
    /// here would create a circular module graph that Zig's test
    /// runner cannot resolve when any cycle member is used as a
    /// test-binary root.
    pub fn hashImmediate(self: Value) u64 {
        const k = self.kind();
        const kind_byte: u8 = @intFromEnum(k);
        const base: u64 = switch (k) {
            // Singletons get fixed, high-entropy constants. Distinct
            // from the `hashU64(kind_byte)` path so a hypothetical
            // `fixnum(0)` / `fixnum(1)` never collides with false/true.
            .nil => 0xB01D_FACE_B01D_FACE,
            .false_ => 0x0000_0000_0000_0000,
            .true_ => 0x1111_1111_1111_1111,
            .char => hash.hashChar(self.asChar()),
            .fixnum => hash.hashI64(self.asFixnum()),
            .float => hash.hashFloat(self.asFloat()),
            .symbol => hash.hashU64(@as(u64, self.asSymbolId())),
            // Keyword domain separation is handled by the generic
            // `mixKindDomain` below — keyword's kind byte differs from
            // symbol's, so same-id kw and sym never collide.
            .keyword => hash.hashU64(@as(u64, self.asKeywordId())),
            else => @panic("value.hashImmediate: heap / sentinel kind — use dispatch.hashValue instead"),
        };
        return hash.mixKindDomain(base, kind_byte);
    }
};

// =============================================================================
// Canonical constructors
//
// Every immediate kind has exactly one public path to construction. Invariants
// are enforced HERE; the raw `tag` / `payload` fields are never written by
// callers.
// =============================================================================

/// The all-zero Value. Freshly-allocated memory therefore contains `nil`
/// without explicit initialization.
pub inline fn nilValue() Value {
    return Value{ .tag = @intFromEnum(Kind.nil), .payload = 0 };
}

pub inline fn fromBool(b: bool) Value {
    const k: Kind = if (b) .true_ else .false_;
    return Value{ .tag = @intFromEnum(k), .payload = 0 };
}

/// UTF-16 surrogate code points are invalid Unicode scalar values and
/// must never appear in a `.char` Value. Returns null on such inputs;
/// callers decide how to surface the error.
pub fn fromChar(scalar: u21) ?Value {
    if (scalar >= 0xD800 and scalar <= 0xDFFF) return null;
    if (scalar > 0x10_FFFF) return null;
    return Value{
        .tag = @intFromEnum(Kind.char),
        .payload = @as(u64, scalar),
    };
}

/// Out-of-i48-range inputs return null; callers route those through the
/// bignum path when it lands.
pub fn fromFixnum(n: i64) ?Value {
    if (!isFixnumRange(n)) return null;
    return Value{
        .tag = @intFromEnum(Kind.fixnum),
        .payload = @bitCast(n),
    };
}

/// Infallible — every f64 bit pattern maps to a valid `Value`. NaN
/// inputs are collapsed to the canonical quiet-NaN bit pattern so that
/// `(= nan nan)` holds and `hash` is stable (SEMANTICS §2.2 / §3.2).
pub fn fromFloat(f: f64) Value {
    const canonical = hash.canonicalizeFloat(f);
    return Value{
        .tag = @intFromEnum(Kind.float),
        .payload = @bitCast(canonical),
    };
}

/// Wrap an already-interned keyword id. Callers obtain the id from the
/// intern table (`src/intern.zig`, future commit).
pub fn fromKeywordId(intern_id: u32) Value {
    return Value{
        .tag = @intFromEnum(Kind.keyword),
        .payload = @as(u64, intern_id),
    };
}

/// Wrap an already-interned (non-metadata-bearing) symbol id.
/// Metadata-bearing symbols use the future `meta_symbol` heap kind.
pub fn fromSymbolId(intern_id: u32) Value {
    return Value{
        .tag = @intFromEnum(Kind.symbol),
        .payload = @as(u64, intern_id),
    };
}

// =============================================================================
// Tests
// =============================================================================

test "Value size and alignment are stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expect(@alignOf(Value) >= 8);
}

test "nil is the all-zero Value" {
    const n = nilValue();
    try std.testing.expect(n.isNil());
    try std.testing.expectEqual(@as(u64, 0), n.tag);
    try std.testing.expectEqual(@as(u64, 0), n.payload);

    // Zero-init memory is nil without an explicit constructor call.
    var buf: [2]Value = undefined;
    @memset(std.mem.asBytes(&buf), 0);
    for (buf) |v| try std.testing.expect(v.isNil());
}

test "truthiness: only nil and false are falsy" {
    try std.testing.expect(!nilValue().isTruthy());
    try std.testing.expect(!fromBool(false).isTruthy());
    try std.testing.expect(fromBool(true).isTruthy());
    try std.testing.expect((fromFixnum(0).?).isTruthy()); // zero is truthy
    try std.testing.expect((fromFloat(0.0)).isTruthy());
    try std.testing.expect((fromChar('a').?).isTruthy());
}

test "fromChar: Unicode range and surrogate rejection" {
    // Valid scalars round-trip.
    try std.testing.expectEqual(@as(u21, 'a'), fromChar('a').?.asChar());
    try std.testing.expectEqual(@as(u21, 0x2603), fromChar(0x2603).?.asChar());
    try std.testing.expectEqual(@as(u21, 0x10_FFFF), fromChar(0x10_FFFF).?.asChar());
    // Surrogates rejected.
    try std.testing.expect(fromChar(0xD800) == null);
    try std.testing.expect(fromChar(0xDFFF) == null);
    // Above the Unicode plane: rejected.
    try std.testing.expect(fromChar(0x11_0000) == null);
}

test "fromFixnum: i48 range check" {
    try std.testing.expectEqual(@as(i64, 0), fromFixnum(0).?.asFixnum());
    try std.testing.expectEqual(@as(i64, 42), fromFixnum(42).?.asFixnum());
    try std.testing.expectEqual(@as(i64, -42), fromFixnum(-42).?.asFixnum());
    try std.testing.expectEqual(fixnum_max, fromFixnum(fixnum_max).?.asFixnum());
    try std.testing.expectEqual(fixnum_min, fromFixnum(fixnum_min).?.asFixnum());
    // Out-of-range: null.
    try std.testing.expect(fromFixnum(fixnum_max + 1) == null);
    try std.testing.expect(fromFixnum(fixnum_min - 1) == null);
    try std.testing.expect(fromFixnum(std.math.maxInt(i64)) == null);
}

test "fromFloat: NaN canonicalization" {
    const nan_a = fromFloat(std.math.nan(f64));
    const nan_b = fromFloat(@bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF)));
    // Bit-level: both stored as the canonical NaN.
    try std.testing.expectEqual(nan_a.payload, nan_b.payload);
    try std.testing.expectEqual(hash.canonical_nan_bits, nan_a.payload);
    // `identical?` on two canonicalized NaNs — reflexive, per SEMANTICS §2.2.
    try std.testing.expect(nan_a.identicalTo(nan_b));
}

test "fromFloat: -0.0 and +0.0 are distinct bit patterns but equal-hashed" {
    const pos = fromFloat(0.0);
    const neg = fromFloat(-0.0);
    // The Value preserves the bit pattern — we do NOT collapse -0.0 to
    // +0.0 at storage time, only at hash time. This matches the
    // SEMANTICS §2.2 rule: `identical?` distinguishes, `=` collapses.
    try std.testing.expect(pos.payload != neg.payload);
    try std.testing.expectEqual(pos.hashImmediate(), neg.hashImmediate());
}

test "keyword and same-named symbol hash into different domains" {
    // A keyword and a symbol with the same intern id must not collide
    // in a mixed-key HAMT. Separation comes from `mixKindDomain` — the
    // keyword and symbol kind bytes differ, so their final hashes do too.
    const kw = fromKeywordId(7);
    const sy = fromSymbolId(7);
    try std.testing.expect(kw.hashImmediate() != sy.hashImmediate());
    // Within-kind: same id ⇒ same hash.
    try std.testing.expectEqual(fromKeywordId(7).hashImmediate(), fromKeywordId(7).hashImmediate());
    try std.testing.expectEqual(fromSymbolId(7).hashImmediate(), fromSymbolId(7).hashImmediate());
}

test "kind predicates cover the immediate family" {
    try std.testing.expect(Kind.nil.isImmediate());
    try std.testing.expect(Kind.fixnum.isImmediate());
    try std.testing.expect(Kind.keyword.isImmediate());
    try std.testing.expect(!Kind.nil.isHeap());
    try std.testing.expect(Kind.string.isHeap());
    try std.testing.expect(!Kind.string.isImmediate());
    try std.testing.expect(Kind.unbound.isSentinel());
    try std.testing.expect(!Kind.unbound.isImmediate());
}

test "identicalTo: bit-equality over the full Value" {
    try std.testing.expect(nilValue().identicalTo(nilValue()));
    try std.testing.expect(fromBool(true).identicalTo(fromBool(true)));
    try std.testing.expect(!fromBool(true).identicalTo(fromBool(false)));
    try std.testing.expect(fromFixnum(42).?.identicalTo(fromFixnum(42).?));
    try std.testing.expect(!fromFixnum(42).?.identicalTo(fromFixnum(43).?));
}

test "coincidentally-equal payload values hash disjointly across kinds" {
    // fixnum(65), char(65), symbol(65), keyword(65) all hash from a
    // u64-looking `65`, but per-kind domain mixing must keep them
    // distinct to protect mixed-key HAMTs from degenerate collisions.
    const fx = fromFixnum(65).?.hashImmediate();
    const ch = fromChar(65).?.hashImmediate();
    const sy = fromSymbolId(65).hashImmediate();
    const kw = fromKeywordId(65).hashImmediate();
    try std.testing.expect(fx != ch);
    try std.testing.expect(fx != sy);
    try std.testing.expect(fx != kw);
    try std.testing.expect(ch != sy);
    try std.testing.expect(ch != kw);
    try std.testing.expect(sy != kw);
}

test "signed zero: identical? distinguishes, = folds, hash matches =" {
    const pos = fromFloat(0.0);
    const neg = fromFloat(-0.0);
    // Representation preserved at storage time.
    try std.testing.expect(pos.payload != neg.payload);
    try std.testing.expect(!pos.identicalTo(neg));
    // Equality folds (tested in eq.zig) — hash must agree with =.
    try std.testing.expectEqual(pos.hashImmediate(), neg.hashImmediate());
}
