//! value.zig — the 16-byte tagged Value, the `Kind` numbers and the
//! immediates' constructors (`docs/VALUE.md`; `=` and hash,
//! `docs/SEMANTICS.md`).
//!
//! An immediate is built only through its constructor here, which
//! enforces its range and canonical form (VALUE.md §3); a heap Value
//! through its kind's module. Zig has no private fields, so this is a
//! convention the tree keeps.

const std = @import("std");
const hash = @import("hash.zig");

// =============================================================================
// Kind discriminator: the numbers are frozen (VALUE.md §2), since the
// dispatcher and the codec use them as table indices and wire tags.
// =============================================================================

/// What each kind is: VALUE.md §2.1-§2.3.
pub const Kind = enum(u8) {
    nil = 0,
    false_ = 1,
    true_ = 2,
    char = 3,
    fixnum = 4,
    float = 5,
    keyword = 6,
    symbol = 7,
    inst = 8,
    // 9..15 reserved for immediates.
    string = 16,
    bignum = 17,
    persistent_map = 18,
    persistent_set = 19,
    persistent_vector = 20,
    list = 21,
    /// Reserved: never constructed. 22, 28 and 29 stay out of use
    /// because kind bytes are the codec's wire tags (CODEC.md §9).
    byte_vector = 22,
    typed_vector = 23,
    function = 24,
    var_ = 25,
    durable_ref = 26,
    transient = 27,
    error_ = 28,
    meta_symbol = 29,
    native_fn = 30,
    db_connection = 31,
    db_write_txn = 32,
    db_read_txn = 33,
    atom = 34,
    record = 35,
    protocol = 36,
    protocol_fn = 37,
    nextomic_conn = 38,
    nextomic_db = 39,
    nextomic_entity = 40,
    sorted_map = 41,
    sorted_set = 42,
    lazy_seq = 43,
    regex = 44,
    matcher = 45,
    uuid = 46,
    // 47..63 reserved for heap kinds.
    /// An upvalue cell block: runtime-private, never a user value
    /// (VALUE.md §2.3).
    cell_internal = 66,
    _,

    /// Does the payload word hold a `*HeapHeader` pointer?
    pub inline fn isHeap(k: Kind) bool {
        const n: u8 = @backingInt(k);
        return n >= 16 and n < 64;
    }
};

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
        return @fromBackingInt(@as(u8, @truncate(self.tag)));
    }

    pub inline fn subkind(self: Value) u16 {
        return @truncate(self.tag >> 16);
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

    pub inline fn isInst(self: Value) bool {
        return self.kind() == .inst;
    }

    pub inline fn isTruthy(self: Value) bool {
        // Only `nil` and `false` are falsy (PLAN §23 #13); they sit at
        // kinds 0 and 1.
        const k = @backingInt(self.kind());
        return k != 0 and k != 1;
    }

    /// Inverse of `isTruthy`. Provided as a named predicate for
    /// jump-handler / cmp-handler / analyzer code paths that read
    /// more naturally as `if (v.isFalsy())` than as
    /// `if (!v.isTruthy())`. Same single-comparison hot path; this
    /// is the language-level truthiness predicate.
    pub inline fn isFalsy(self: Value) bool {
        const k = @backingInt(self.kind());
        return k == 0 or k == 1;
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

    /// An instant's milliseconds since 1970-01-01T00:00:00Z.
    pub inline fn asInstMs(self: Value) i64 {
        std.debug.assert(self.isInst());
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

    /// The `hash.nameHash` of a keyword's or symbol's text, carried in
    /// the payload's high word (VALUE.md §2).
    pub inline fn nameHash(self: Value) u32 {
        std.debug.assert(self.isKeyword() or self.isSymbol());
        return @truncate(self.payload >> 32);
    }

    // ---- identical? — bit equality for immediates ----

    /// Bit-equality on the 16-byte struct. For heap kinds this compares
    /// the pointer word inside the payload (same `HeapHeader*` ⇒
    /// identical). Fast and cheap — single 128-bit compare on NEON/SSE.
    pub inline fn identicalTo(self: Value, other: Value) bool {
        return self.tag == other.tag and self.payload == other.payload;
    }

    /// `=` on two values that are not heap kinds (SEMANTICS §2). Bit
    /// equality, except that `-0.0` and `+0.0` are equal; NaN is
    /// canonical at construction, so it is equal to itself by bits.
    /// Two kinds are never equal: `(= 1 1.0)` is false (PLAN §23 #11).
    /// `dispatch.equal` is the entry point for any Value.
    pub inline fn equalImmediate(self: Value, other: Value) bool {
        std.debug.assert(!self.kind().isHeap() and !other.kind().isHeap());
        if (self.tag != other.tag) return false;
        return self.payload == other.payload or
            (self.kind() == .float and self.asFloat() == other.asFloat());
    }

    // ---- Hash (immediates only; heap kinds hash in dispatch.zig) ----

    /// Immediate-kind semantic hash. Collapses `-0.0 / +0.0`, treats
    /// canonical NaN as reflexive, and mixes the kind byte so
    /// coincidentally-equal raw payload hashes (`fixnum(65)` vs
    /// `symbol(65)` vs `char(65)`) land in disjoint regions of the
    /// 64-bit hash space.
    ///
    /// **Partial function — heap kinds and sentinels panic.** Full
    /// hashing over any Value goes through `dispatch.hashValue(v)`,
    /// which routes immediates here and heap kinds through the per-kind
    /// hashers; `value.zig` stays below the heap-kind modules.
    pub fn hashImmediate(self: Value) u64 {
        const k = self.kind();
        const kind_byte: u8 = @backingInt(k);
        const base: u64 = switch (k) {
            // Singletons get fixed, high-entropy constants. Distinct
            // from the `hashU64(kind_byte)` path so a hypothetical
            // `fixnum(0)` / `fixnum(1)` never collides with false/true.
            .nil => 0xB01D_FACE_B01D_FACE,
            .false_ => 0x0000_0000_0000_0000,
            .true_ => 0x1111_1111_1111_1111,
            .char => hash.hashChar(self.asChar()),
            .fixnum => hash.hashI64(self.asFixnum()),
            .inst => hash.hashI64(self.asInstMs()),
            .float => hash.hashFloat(self.asFloat()),
            // The text, never the intern id: a map's order must not
            // depend on which names a process happened to intern first.
            // The kind byte mixed in below keeps `:foo` and `'foo` apart.
            .keyword, .symbol => hash.hashU64(self.nameHash()),
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
    return Value{ .tag = @backingInt(Kind.nil), .payload = 0 };
}

pub inline fn fromBool(b: bool) Value {
    const k: Kind = if (b) .true_ else .false_;
    return Value{ .tag = @backingInt(k), .payload = 0 };
}

/// UTF-16 surrogate code points are invalid Unicode scalar values and
/// must never appear in a `.char` Value. Returns null on such inputs;
/// callers decide how to surface the error.
pub fn fromChar(scalar: u21) ?Value {
    if (scalar >= 0xD800 and scalar <= 0xDFFF) return null;
    if (scalar > 0x10_FFFF) return null;
    return Value{
        .tag = @backingInt(Kind.char),
        .payload = @as(u64, scalar),
    };
}

/// Out-of-i48-range inputs return null; callers that want promotion
/// build a bignum instead (`bignum.fromI64`).
pub fn fromFixnum(n: i64) ?Value {
    if (!isFixnumRange(n)) return null;
    return Value{
        .tag = @backingInt(Kind.fixnum),
        .payload = @bitCast(n),
    };
}

/// Infallible — every f64 bit pattern maps to a valid `Value`. NaN
/// inputs are collapsed to the canonical quiet-NaN bit pattern so that
/// `(= nan nan)` holds and `hash` is stable (SEMANTICS §2.2 / §3.2).
pub fn fromFloat(f: f64) Value {
    const canonical = hash.canonicalizeFloat(f);
    return Value{
        .tag = @backingInt(Kind.float),
        .payload = @bitCast(canonical),
    };
}

/// Infallible: every i64 is an instant, the milliseconds since
/// 1970-01-01T00:00:00Z (SEMANTICS §2.8).
pub fn fromInst(ms: i64) Value {
    return Value{
        .tag = @backingInt(Kind.inst),
        .payload = @bitCast(ms),
    };
}

/// A keyword from its intern id and the `hash.nameHash` of its text.
/// Both come from the intern table (`Interner.keywordValue`,
/// `internKeywordValue`), which is the one place that pairs them.
pub fn fromKeyword(intern_id: u32, name_hash: u32) Value {
    return Value{
        .tag = @backingInt(Kind.keyword),
        .payload = @as(u64, name_hash) << 32 | intern_id,
    };
}

/// A symbol, as `fromKeyword`. Symbols carry no metadata (SEMANTICS §7).
pub fn fromSymbol(intern_id: u32, name_hash: u32) Value {
    return Value{
        .tag = @backingInt(Kind.symbol),
        .payload = @as(u64, name_hash) << 32 | intern_id,
    };
}

/// A keyword whose name hash is its id, for a test that needs keywords
/// without an intern table; ids and hashes stay consistent as long as
/// the test builds every keyword this way.
pub fn testKeyword(id: u32) Value {
    if (!@import("builtin").is_test) @compileError("testKeyword is for tests");
    return fromKeyword(id, id);
}

/// `testKeyword` for symbols.
pub fn testSymbol(id: u32) Value {
    if (!@import("builtin").is_test) @compileError("testSymbol is for tests");
    return fromSymbol(id, id);
}

/// `=` over immediates, for the tests of the modules below `dispatch`
/// (the collections, the codec, durable refs), with `hashImmediate` as
/// the hash: the same bits, or two zeros. NaN is canonical at
/// construction; a heap value equals only itself.
pub fn testEqual(a: Value, b: Value) bool {
    if (!@import("builtin").is_test) @compileError("testEqual is for tests");
    return a.tag == b.tag and (a.payload == b.payload or (a.kind() == .float and a.asFloat() == b.asFloat()));
}

/// Pack a STATIC `NativeFn` descriptor pointer into a Value of kind `.native_fn`. The
/// descriptor lives in static storage (no heap, no GC, no
/// lifetime concern). The runtime treats the Value as
/// equivalent to a Closure for call dispatch purposes (see
/// `vm.execCallCall`).
pub fn fromNativeFnPtr(descriptor_ptr: *const anyopaque) Value {
    return Value{
        .tag = @backingInt(Kind.native_fn),
        .payload = @intFromPtr(descriptor_ptr),
    };
}

// =============================================================================
// Tests
// =============================================================================

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

test "isFalsy: matches !isTruthy across every immediate kind" {
    // Direct positive checks for the falsy kinds.
    try std.testing.expect(nilValue().isFalsy());
    try std.testing.expect(fromBool(false).isFalsy());
    // Direct negative checks for representative truthy kinds (values
    // users might assume are falsy because they're zero/empty in other
    // languages; SEMANTICS §1).
    try std.testing.expect(!fromBool(true).isFalsy());
    try std.testing.expect(!(fromFixnum(0).?).isFalsy());
    try std.testing.expect(!fromFloat(0.0).isFalsy());
    try std.testing.expect(!fromFloat(-0.0).isFalsy());
    try std.testing.expect(!(fromChar('\x00').?).isFalsy());
    try std.testing.expect(!(fromFixnum(-1).?).isFalsy());
    try std.testing.expect(!(fromFixnum(fixnum_max).?).isFalsy());
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

test "isHeap: the heap kinds, not the immediates or the sentinels" {
    try std.testing.expect(!Kind.nil.isHeap() and Kind.string.isHeap() and Kind.matcher.isHeap() and !Kind.cell_internal.isHeap());
    try std.testing.expect(!Kind.inst.isHeap() and Kind.uuid.isHeap());
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
    const sy = testSymbol(65).hashImmediate();
    const kw = testKeyword(65).hashImmediate();
    const in = fromInst(65).hashImmediate();
    try std.testing.expect(in != fx and in != ch and in != sy and in != kw);
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
    try std.testing.expect(pos.equalImmediate(neg));
    try std.testing.expectEqual(pos.hashImmediate(), neg.hashImmediate());
}

/// One of each immediate kind, with the edge cases of `=`: both
/// zeros, NaN, and a keyword and a symbol sharing an intern id.
fn immediateSamples() [19]Value {
    return .{
        nilValue(),      fromBool(true),   fromBool(false),
        fromChar('a').?, fromChar('b').?,  fromFixnum(0).?,
        fromFixnum(1).?, fromFixnum(-1).?, fromFloat(0.0),
        fromFloat(-0.0), fromFloat(1.0),   fromFloat(std.math.nan(f64)),
        testKeyword(1),  testKeyword(2),   testSymbol(1),
        testSymbol(2),   fromInst(0),      fromInst(1),
        fromInst(-1),
    };
}

test "fromInst: every i64 is an instant, and its milliseconds come back" {
    for ([_]i64{ std.math.minInt(i64), -1, 0, 1, std.math.maxInt(i64) }) |ms| {
        const v = fromInst(ms);
        try std.testing.expect(v.isInst() and v.isTruthy());
        try std.testing.expectEqual(ms, v.asInstMs());
        try std.testing.expect(v.equalImmediate(fromInst(ms)));
    }
    try std.testing.expect(!fromInst(1).equalImmediate(fromFixnum(1).?));
}

test "equalImmediate is an equivalence, and equal values hash equal" {
    const samples = immediateSamples();
    for (samples) |a| {
        try std.testing.expect(a.equalImmediate(a));
        for (samples) |b| {
            try std.testing.expectEqual(a.equalImmediate(b), b.equalImmediate(a));
            if (a.equalImmediate(b)) try std.testing.expectEqual(a.hashImmediate(), b.hashImmediate());
            for (samples) |c| {
                if (a.equalImmediate(b) and b.equalImmediate(c)) try std.testing.expect(a.equalImmediate(c));
            }
        }
    }
}

test "equalImmediate: no cross-kind equality, NaN reflexive, the zeros fold" {
    try std.testing.expect(!fromFixnum(1).?.equalImmediate(fromFloat(1.0)));
    try std.testing.expect(!testKeyword(7).equalImmediate(testSymbol(7)));
    try std.testing.expect(!fromBool(false).equalImmediate(nilValue()));
    try std.testing.expect(!fromChar(65).?.equalImmediate(fromFixnum(65).?));
    try std.testing.expect(fromFloat(std.math.nan(f64)).equalImmediate(fromFloat(@bitCast(@as(u64, 0x7FFF_FFFF_FFFF_FFFF)))));
    try std.testing.expect(fromFloat(-0.0).equalImmediate(fromFloat(0.0)));
    try std.testing.expect(!fromFloat(1.0).equalImmediate(fromFloat(-1.0)));
}
