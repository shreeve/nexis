//! intern.zig — keyword + symbol intern tables.
//!
//! Authoritative contract: `docs/INTERN.md`. Physical layout of the
//! `Value` ids produced here is pinned in `docs/VALUE.md`. The hash
//! domain separation between keyword and symbol lives in the Value
//! layer (`mixKindDomain`), not here; this file maps textual names to
//! dense process-local `u32` ids and keeps each name's text hash, which
//! every keyword and symbol Value carries.
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
const value = @import("value.zig");
const hash = @import("hash.zig");

const Allocator = std.mem.Allocator;

// =============================================================================
// Errors
// =============================================================================

pub const InternError = error{
    OutOfMemory,
    EmptyName,
    InternTableFull,
};

// =============================================================================
// Private table — shared shape for keyword + symbol
// =============================================================================

const Table = struct {
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    /// `hash.nameHash` of each name, by id.
    hashes: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *Table, gpa: Allocator) void {
        // Lockstep invariant: `by_name` keys are borrowed slices into
        // the duped bytes owned via `names`. Check before teardown so
        // a mutation path can't silently break it.
        std.debug.assert(self.by_name.count() == self.names.items.len);
        // Free each duped name buffer, then drop both containers.
        // Order matters: `by_name.deinit` does NOT free its keys, so
        // the name bytes must be freed explicitly via `names`.
        for (self.names.items) |n| gpa.free(n);
        self.names.deinit(gpa);
        self.hashes.deinit(gpa);
        self.by_name.deinit(gpa);
    }
};

/// Shared insertion logic. Factored into a helper so keyword and symbol
/// tables cannot drift (INTERN.md §4).
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
    try table.hashes.append(gpa, hash.nameHash(name));
    errdefer _ = table.hashes.pop();

    try table.by_name.put(gpa, dup, id);

    std.debug.assert(table.by_name.count() == table.names.items.len and table.hashes.items.len == table.names.items.len);
    return id;
}

/// Look up `id` in `table`. Panics unconditionally on out-of-range
/// ids in every build mode: every id comes from this table, so an
/// invalid one is a runtime bug upstream. Contract is pinned in
/// `docs/INTERN.md` §2.
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
    /// `ns.Type` of each record type, by its dense per-VM type id; an
    /// empty slice for an id not yet named. The printer's source for
    /// `#ns.Type{...}` (INTERN.md §2).
    record_types: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init(gpa: Allocator) Interner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Interner) void {
        self.keyword.deinit(self.gpa);
        self.symbol.deinit(self.gpa);
        for (self.record_types.items) |name| self.gpa.free(name);
        self.record_types.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- Record type names ----

    /// Name record type `type_id` as `ns.name`, the way Clojure
    /// prints a record's class.
    pub fn nameRecordType(self: *Interner, type_id: u32, ns: []const u8, name: []const u8) Allocator.Error!void {
        const full = try std.fmt.allocPrint(self.gpa, "{s}.{s}", .{ ns, name });
        errdefer self.gpa.free(full);
        while (self.record_types.items.len <= type_id) try self.record_types.append(self.gpa, &.{});
        self.gpa.free(self.record_types.items[type_id]);
        self.record_types.items[type_id] = full;
    }

    /// The `ns.Type` name of record type `type_id`, or null when the
    /// type was never named.
    pub fn recordTypeName(self: *const Interner, type_id: u32) ?[]const u8 {
        if (type_id >= self.record_types.items.len) return null;
        const name = self.record_types.items[type_id];
        return if (name.len == 0) null else name;
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
        return self.keywordValue(try self.internKeyword(name));
    }

    /// A keyword's full text is `ns/name` when it is qualified;
    /// `splitQualified` is the inverse.
    pub fn internQualifiedKeyword(self: *Interner, ns: ?[]const u8, name: []const u8) InternError!value.Value {
        const ns_prefix = ns orelse return self.internKeywordValue(name);
        const full = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ ns_prefix, name });
        defer self.gpa.free(full);
        return self.internKeywordValue(full);
    }

    /// `internQualifiedKeyword` for symbols.
    pub fn internQualifiedSymbol(self: *Interner, ns: ?[]const u8, name: []const u8) InternError!value.Value {
        const ns_prefix = ns orelse return self.internSymbolValue(name);
        const full = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ ns_prefix, name });
        defer self.gpa.free(full);
        return self.internSymbolValue(full);
    }

    /// Split an interned `ns/name` text back into its parts at its
    /// first slash, as Clojure's `namespace` and `name` do; `ns` is
    /// null for an unqualified name. The bare division symbol `/` is
    /// an unqualified name (INTERN.md §3).
    pub fn splitQualified(full: []const u8) struct { ns: ?[]const u8, name: []const u8 } {
        if (std.mem.eql(u8, full, "/")) return .{ .ns = null, .name = full };
        const slash = std.mem.indexOfScalar(u8, full, '/') orelse return .{ .ns = null, .name = full };
        return .{ .ns = full[0..slash], .name = full[slash + 1 ..] };
    }

    /// Clojure's order of symbol or keyword texts, which `compare` and
    /// Nextomic's queries share: an unqualified name before any
    /// qualified one, then by namespace, then by name.
    pub fn compareNames(a: []const u8, b: []const u8) std.math.Order {
        const pa = splitQualified(a);
        const pb = splitQualified(b);
        if (pa.ns == null and pb.ns != null) return .lt;
        if (pa.ns != null and pb.ns == null) return .gt;
        if (pa.ns) |na| {
            const o = std.mem.order(u8, na, pb.ns.?);
            if (o != .eq) return o;
        }
        return std.mem.order(u8, pa.name, pb.name);
    }

    pub fn internSymbolValue(self: *Interner, name: []const u8) InternError!value.Value {
        return self.symbolValue(try self.internSymbol(name));
    }

    // ---- Accessors: id -> Value ----

    /// The keyword Value of interned id `id`: the id and its name's
    /// hash (VALUE.md §2). Panics on an out-of-range id, as `keywordName`.
    pub fn keywordValue(self: *const Interner, id: u32) value.Value {
        _ = nameFrom(&self.keyword, id);
        return value.fromKeyword(id, self.keyword.hashes.items[id]);
    }

    /// `keywordValue` for symbols.
    pub fn symbolValue(self: *const Interner, id: u32) value.Value {
        _ = nameFrom(&self.symbol, id);
        return value.fromSymbol(id, self.symbol.hashes.items[id]);
    }

    // ---- Accessors: id -> name ----
    //
    // Panic on an out-of-range id: a runtime bug upstream, never a
    // user-surfaceable condition.

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
};

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

test "splitQualified: first slash; bare / is unqualified" {
    const cases = [_]struct { full: []const u8, ns: ?[]const u8, name: []const u8 }{
        .{ .full = "foo", .ns = null, .name = "foo" },
        .{ .full = "/", .ns = null, .name = "/" },
        .{ .full = "ns/foo", .ns = "ns", .name = "foo" },
        .{ .full = "a/b/c", .ns = "a", .name = "b/c" },
        .{ .full = "nexis.core//", .ns = "nexis.core", .name = "/" },
    };
    for (cases) |c| {
        const got = Interner.splitQualified(c.full);
        if (c.ns) |ns| try testing.expectEqualStrings(ns, got.ns.?) else try testing.expect(got.ns == null);
        try testing.expectEqualStrings(c.name, got.name);
    }
}

test "compareNames: unqualified first, then namespace, then name" {
    const sorted = [_][]const u8{ "/", "ab", "b", "c", "a/b", "a/z", "b/a", "nexis.core//" };
    for (sorted, 0..) |a, i| for (sorted, 0..) |b, j| {
        try testing.expectEqual(std.math.order(i, j), Interner.compareNames(a, b));
    };
}

test "record type names: named ids print as ns.Type, others are null" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();
    try testing.expect(it.recordTypeName(0) == null);
    try it.nameRecordType(2, "my.app", "Point");
    try testing.expectEqualStrings("my.app.Point", it.recordTypeName(2).?);
    try testing.expect(it.recordTypeName(0) == null);
    try testing.expect(it.recordTypeName(3) == null);
    try it.nameRecordType(2, "user", "P");
    try testing.expectEqualStrings("user.P", it.recordTypeName(2).?);
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
