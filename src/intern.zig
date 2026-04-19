//! intern.zig — keyword + symbol intern tables (Phase 1).
//!
//! Authoritative contract: `docs/INTERN.md`. Physical layout of the
//! `Value` ids produced here is pinned in `docs/VALUE.md`. The hash
//! domain separation between keyword and symbol lives in the Value
//! layer (`mixKindDomain`), not here; this file only maps
//! textual names to dense process-local `u32` ids.
//!
//! Invariants (INTERN.md §1 — frozen):
//!   - Dense-from-0 ids per table; never reused, never renumbered.
//!   - No reserved sentinel id.
//!   - Idempotent: interning the same byte sequence twice returns the
//!     original id.
//!   - Byte-exact round-trip: `name(intern(s)) == s`.
//!   - Keyword and symbol tables have independent id spaces.
//!   - Interner owns name bytes (`gpa.dupe` on first intern); freed in
//!     `deinit`.
//!   - Empty names rejected at the intern API boundary.
//!   - `maxInt(u32)` entry cap per table; exceeding returns
//!     `error.InternTableFull`.
//!
//! Errdefer discipline is structured so a mid-insert allocator failure
//! leaves no duped bytes leaked and no half-committed map entries.

const std = @import("std");
const value = @import("value");

const Allocator = std.mem.Allocator;

// =============================================================================
// Errors
// =============================================================================

pub const InternError = error{
    OutOfMemory,
    EmptyName,
    InternTableFull,
};

pub const SplitError = error{
    EmptyName,
    EmptyNamespace,
    EmptyLocalName,
    MultipleSlashes,
};

// =============================================================================
// Private table — shared shape for keyword + symbol
// =============================================================================

const Table = struct {
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *Table, gpa: Allocator) void {
        // Lockstep invariant: `by_name` keys are borrowed slices into
        // the duped bytes owned via `names`. Check before teardown so
        // future changes to the mutation paths can't silently break it.
        std.debug.assert(self.by_name.count() == self.names.items.len);
        // Free each duped name buffer, then drop both containers.
        // Order matters: `by_name.deinit` does NOT free its keys, so
        // the name bytes must be freed explicitly via `names`.
        for (self.names.items) |n| gpa.free(n);
        self.names.deinit(gpa);
        self.by_name.deinit(gpa);
    }
};

/// Shared insertion logic. Factored into a helper so keyword and symbol
/// tables cannot drift (INTERN.md §4; peer-AI review point E).
fn internInto(table: *Table, gpa: Allocator, name: []const u8) InternError!u32 {
    if (name.len == 0) return error.EmptyName;

    if (table.by_name.get(name)) |existing| return existing;

    if (table.names.items.len >= std.math.maxInt(u32)) {
        return error.InternTableFull;
    }
    const id: u32 = @intCast(table.names.items.len);

    // `dup` owns the name bytes for the lifetime of the interner.
    // Both `names` (id -> slice) and `by_name` (slice -> id) point at
    // the same buffer; the map key must NOT be a slice into the
    // `names.items` array, which can relocate on growth.
    const dup = try gpa.dupe(u8, name);
    errdefer gpa.free(dup);

    try table.names.append(gpa, dup);
    errdefer _ = table.names.pop();

    try table.by_name.put(gpa, dup, id);

    std.debug.assert(table.by_name.count() == table.names.items.len);
    return id;
}

/// Look up `id` in `table`. Panics unconditionally on out-of-range
/// ids in every build mode: an invalid id is a runtime-bug leak
/// upstream, matching the fail-fast discipline `eq.zig` uses for
/// sentinel escape. Contract is pinned in `docs/INTERN.md` §2.
fn nameFrom(table: *const Table, id: u32) []const u8 {
    if (id >= table.names.items.len) {
        std.debug.panic(
            "intern.nameFrom: id {d} out of range (table holds {d} entries)",
            .{ id, table.names.items.len },
        );
    }
    return table.names.items[id];
}

// =============================================================================
// Interner — public API
// =============================================================================

pub const Interner = struct {
    gpa: Allocator,
    keyword: Table = .{},
    symbol: Table = .{},

    pub fn init(gpa: Allocator) Interner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Interner) void {
        self.keyword.deinit(self.gpa);
        self.symbol.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- Raw intern: name -> id ----

    pub fn internKeyword(self: *Interner, name: []const u8) InternError!u32 {
        return internInto(&self.keyword, self.gpa, name);
    }

    pub fn internSymbol(self: *Interner, name: []const u8) InternError!u32 {
        return internInto(&self.symbol, self.gpa, name);
    }

    // ---- Convenience: name -> Value ----

    pub fn internKeywordValue(self: *Interner, name: []const u8) InternError!value.Value {
        const id = try self.internKeyword(name);
        return value.fromKeywordId(id);
    }

    pub fn internSymbolValue(self: *Interner, name: []const u8) InternError!value.Value {
        const id = try self.internSymbol(name);
        return value.fromSymbolId(id);
    }

    // ---- Accessors: id -> name ----
    //
    // Panic (via assert) on out-of-range id. An invalid id here is a
    // runtime-bug leak upstream, never a user-surfaceable condition.
    // Matches the fail-fast discipline in `eq.zig` for sentinel escape.

    pub fn keywordName(self: *const Interner, id: u32) []const u8 {
        return nameFrom(&self.keyword, id);
    }

    pub fn symbolName(self: *const Interner, id: u32) []const u8 {
        return nameFrom(&self.symbol, id);
    }

    pub fn keywordCount(self: *const Interner) u32 {
        return @intCast(self.keyword.names.items.len);
    }

    pub fn symbolCount(self: *const Interner) u32 {
        return @intCast(self.symbol.names.items.len);
    }

    // ---- GC-root tracing seam (PLAN §10.5) ----
    //
    // v1 implementation is a no-op: name bytes are plain allocations,
    // not heap objects with a `HeapHeader`. This seam exists so the
    // future GC wiring can register the interner as a root without
    // reshaping the public struct. When heap-owned names arrive (e.g.
    // if interned names ever move to the runtime heap), iterate
    // `self.keyword.names` and `self.symbol.names` and call
    // `visitor.visit(entry)` here.
    pub fn trace(self: *Interner, visitor: anytype) void {
        _ = self;
        _ = visitor;
    }
};

// =============================================================================
// split — namespace/local decomposition
//
// Pure function; reachable outside the reader. Robust against
// malformed raw inputs per INTERN.md §3.
// =============================================================================

pub const Qualified = struct {
    ns: ?[]const u8,
    local: []const u8,
};

pub fn split(name: []const u8) SplitError!Qualified {
    if (name.len == 0) return error.EmptyName;

    // Bare "/" is the division symbol — an unqualified name whose
    // local part literally is "/". This is INTENTIONAL: it matches
    // nexis.grammar (which permits bare `/` as a legal symbol) and
    // Clojure's `clojure.core//` convention. Without this carve-out,
    // `"/"` would fall through to the single-slash path and error as
    // `EmptyNamespace` / `EmptyLocalName`. Pinned in INTERN.md §3.
    if (name.len == 1 and name[0] == '/') {
        return .{ .ns = null, .local = name };
    }

    var slash_count: usize = 0;
    var slash_at: usize = 0;
    for (name, 0..) |c, i| {
        if (c == '/') {
            slash_count += 1;
            if (slash_count > 1) return error.MultipleSlashes;
            slash_at = i;
        }
    }

    if (slash_count == 0) return .{ .ns = null, .local = name };

    // Exactly one slash.
    const ns = name[0..slash_at];
    const local = name[slash_at + 1 ..];
    if (ns.len == 0) return error.EmptyNamespace;
    if (local.len == 0) return error.EmptyLocalName;
    return .{ .ns = ns, .local = local };
}

// =============================================================================
// Tests — inline. Randomized property sweeps live in test/prop/intern.zig.
// =============================================================================

const testing = std.testing;

test "Interner: init/deinit round-trip with no interns" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();
    try testing.expectEqual(@as(u32, 0), it.keywordCount());
    try testing.expectEqual(@as(u32, 0), it.symbolCount());
}

test "internKeyword: idempotent and dense-from-0" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();

    const foo1 = try it.internKeyword("foo");
    const bar1 = try it.internKeyword("bar");
    const foo2 = try it.internKeyword("foo");
    try testing.expectEqual(@as(u32, 0), foo1);
    try testing.expectEqual(@as(u32, 1), bar1);
    try testing.expectEqual(foo1, foo2);
    try testing.expectEqual(@as(u32, 2), it.keywordCount());
}

test "internSymbol: independent id space from keyword" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();

    const kw_foo = try it.internKeyword("foo");
    const sym_foo = try it.internSymbol("foo");
    // Both start at 0 in their own tables.
    try testing.expectEqual(@as(u32, 0), kw_foo);
    try testing.expectEqual(@as(u32, 0), sym_foo);

    const kw_bar = try it.internKeyword("bar");
    const sym_bar = try it.internSymbol("bar");
    try testing.expectEqual(@as(u32, 1), kw_bar);
    try testing.expectEqual(@as(u32, 1), sym_bar);
}

test "byte-exact round-trip via keywordName/symbolName" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();

    const names = [_][]const u8{ "a", "foo", "ns/foo", "+", "/", "λ", "你好" };
    for (names) |n| {
        const kid = try it.internKeyword(n);
        const sid = try it.internSymbol(n);
        try testing.expectEqualStrings(n, it.keywordName(kid));
        try testing.expectEqualStrings(n, it.symbolName(sid));
    }
}

test "internKeyword / internSymbol: empty name rejected" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();
    try testing.expectError(error.EmptyName, it.internKeyword(""));
    try testing.expectError(error.EmptyName, it.internSymbol(""));
    // Nothing was interned.
    try testing.expectEqual(@as(u32, 0), it.keywordCount());
    try testing.expectEqual(@as(u32, 0), it.symbolCount());
}

test "internKeywordValue / internSymbolValue: Value-level plumbing" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();

    const v_kw = try it.internKeywordValue("foo");
    const v_sym = try it.internSymbolValue("foo");
    try testing.expect(v_kw.isKeyword());
    try testing.expect(v_sym.isSymbol());
    try testing.expectEqual(@as(u32, 0), v_kw.asKeywordId());
    try testing.expectEqual(@as(u32, 0), v_sym.asSymbolId());
    // Same text in disjoint tables: hashes differ by Value-layer
    // kind-domain mixing (SEMANTICS §3.2).
    try testing.expect(v_kw.hashImmediate() != v_sym.hashImmediate());
}

test "transient input slice: interner holds its own copy" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();

    var buf: [8]u8 = undefined;
    @memcpy(buf[0..3], "foo");
    const id = try it.internKeyword(buf[0..3]);
    // Overwrite the source buffer — the interned name must be unaffected.
    @memset(&buf, 0xAA);
    try testing.expectEqualStrings("foo", it.keywordName(id));
}

test "split: canonical cases" {
    {
        const q = try split("foo");
        try testing.expect(q.ns == null);
        try testing.expectEqualStrings("foo", q.local);
    }
    {
        const q = try split("+");
        try testing.expect(q.ns == null);
        try testing.expectEqualStrings("+", q.local);
    }
    {
        const q = try split("/");
        try testing.expect(q.ns == null);
        try testing.expectEqualStrings("/", q.local);
    }
    {
        const q = try split("ns/foo");
        try testing.expectEqualStrings("ns", q.ns.?);
        try testing.expectEqualStrings("foo", q.local);
    }
}

test "split: malformed input returns specific errors" {
    try testing.expectError(error.EmptyName, split(""));
    try testing.expectError(error.EmptyNamespace, split("/foo"));
    try testing.expectError(error.EmptyLocalName, split("foo/"));
    try testing.expectError(error.MultipleSlashes, split("a//b"));
    try testing.expectError(error.MultipleSlashes, split("a/b/c"));
}

test "trace seam exists and is callable as a no-op" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();
    _ = try it.internKeyword("foo");
    const NullVisitor = struct {};
    var v: NullVisitor = .{};
    it.trace(&v);
}

test "by_name lookups survive names reallocation" {
    // Force enough inserts to grow `names` past its initial capacity
    // (ArrayListUnmanaged grows geometrically). Every previously-returned
    // id must still resolve, and every name must still be found. This
    // exercises the claim in `docs/INTERN.md` §4 that map keys point at
    // the duped byte buffers, not into `names.items`.
    var it = Interner.init(testing.allocator);
    defer it.deinit();

    var names_list: std.ArrayList([]u8) = .empty;
    defer {
        for (names_list.items) |s| testing.allocator.free(s);
        names_list.deinit(testing.allocator);
    }

    const N: u32 = 256; // well past the initial ArrayList capacity.
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "name-{d}", .{i}) catch unreachable;
        const owned = try testing.allocator.dupe(u8, s);
        try names_list.append(testing.allocator, owned);
        const id = try it.internKeyword(owned);
        try testing.expectEqual(i, id);
    }

    // Every previously-interned id still round-trips byte-exact, and
    // a second intern of the same name still returns the same id
    // after all the reallocs.
    for (names_list.items, 0..) |s, idx| {
        const id: u32 = @intCast(idx);
        try testing.expectEqualStrings(s, it.keywordName(id));
        try testing.expectEqual(id, try it.internKeyword(s));
    }
    try testing.expectEqual(N, it.keywordCount());
}

test "id stability: mid-sequence dup reuse does not affect order" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();
    const a = try it.internKeyword("a");
    const b = try it.internKeyword("b");
    const a2 = try it.internKeyword("a");
    const c = try it.internKeyword("c");
    try testing.expectEqual(@as(u32, 0), a);
    try testing.expectEqual(@as(u32, 1), b);
    try testing.expectEqual(a, a2);
    try testing.expectEqual(@as(u32, 2), c);
    try testing.expectEqual(@as(u32, 3), it.keywordCount());
}
