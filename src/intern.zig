//! intern.zig — the keyword and symbol intern tables (`docs/INTERN.md`):
//! a name's dense process-local `u32` id and its text hash, both of
//! which its Value carries (VALUE.md §2). Ids are dense from 0, never
//! reused; the tables own the names; an empty name is refused, and a
//! table past `maxInt(u32)` names is full (INTERN.md §1).

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
    /// By id: the name, whose bytes the table owns and `by_name`'s
    /// keys borrow, and its `hash.nameHash`.
    entries: std.ArrayList(struct { name: []const u8, hash: u32 }) = .empty,

    fn deinit(self: *Table, gpa: Allocator) void {
        for (self.entries.items) |e| gpa.free(e.name);
        self.entries.deinit(gpa);
        self.by_name.deinit(gpa);
    }
};

/// The id of `name` in `table`, interned on first sight; keywords and
/// symbols share this one path (INTERN.md §4). A failure leaves the
/// table as it was.
fn internInto(table: *Table, gpa: Allocator, name: []const u8) InternError!u32 {
    if (name.len == 0) return error.EmptyName;
    // A plain `get` on the hit every name after its first takes: a
    // `getOrPut` there costs more than the second hash a miss pays.
    if (table.by_name.get(name)) |id| return id;
    if (table.entries.items.len >= std.math.maxInt(u32)) return error.InternTableFull;
    const id: u32 = @intCast(table.entries.items.len);
    const dup = try gpa.dupe(u8, name);
    errdefer gpa.free(dup);
    try table.entries.append(gpa, .{ .name = dup, .hash = hash.nameHash(name) });
    errdefer _ = table.entries.pop();
    try table.by_name.put(gpa, dup, id);
    return id;
}

/// Look up `id` in `table`. Panics unconditionally on out-of-range
/// ids in every build mode: every id comes from this table, so an
/// invalid one is a runtime bug upstream. Contract is pinned in
/// `docs/INTERN.md` §2.
fn nameFrom(table: *const Table, id: u32) []const u8 {
    if (id >= table.entries.items.len) {
        std.debug.panic(
            "intern.nameFrom: id {d} out of range (table holds {d} entries)",
            .{ id, table.entries.items.len },
        );
    }
    return table.entries.items[id].name;
}

// =============================================================================
// Interner — public API
// =============================================================================

/// Names by a dense per-VM id; an empty slice for an id not yet named.
const IdNames = struct {
    names: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *IdNames, gpa: Allocator) void {
        for (self.names.items) |name| gpa.free(name);
        self.names.deinit(gpa);
    }

    /// Name `id` `ns`, `sep` and `name`, or `name` alone when `ns` is
    /// empty; naming an id again renames it.
    fn set(self: *IdNames, gpa: Allocator, id: u32, ns: []const u8, sep: u8, name: []const u8) Allocator.Error!void {
        const full = if (ns.len == 0) try gpa.dupe(u8, name) else try gpa.print("{s}{c}{s}", .{ ns, sep, name });
        errdefer gpa.free(full);
        while (self.names.items.len <= id) try self.names.append(gpa, &.{});
        gpa.free(self.names.items[id]);
        self.names.items[id] = full;
    }

    fn get(self: *const IdNames, id: u32) ?[]const u8 {
        if (id >= self.names.items.len or self.names.items[id].len == 0) return null;
        return self.names.items[id];
    }
};

pub const Interner = struct {
    gpa: Allocator,
    keyword: Table = .{},
    symbol: Table = .{},
    /// `ns.Type` of each record type and `ns/Name` of each protocol, by
    /// its dense per-VM id: what the printer writes (INTERN.md §2).
    record_types: IdNames = .{},
    protocols: IdNames = .{},

    pub fn init(gpa: Allocator) Interner {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Interner) void {
        self.keyword.deinit(self.gpa);
        self.symbol.deinit(self.gpa);
        self.record_types.deinit(self.gpa);
        self.protocols.deinit(self.gpa);
        self.* = undefined;
    }

    // ---- Record type and protocol names ----

    /// Name record type `type_id` `ns.name`, as Clojure prints a
    /// record's class.
    pub fn nameRecordType(self: *Interner, type_id: u32, ns: []const u8, name: []const u8) Allocator.Error!void {
        return self.record_types.set(self.gpa, type_id, ns, '.', name);
    }

    /// The `ns.Type` name of record type `type_id`, or null when the
    /// type was never named.
    pub fn recordTypeName(self: *const Interner, type_id: u32) ?[]const u8 {
        return self.record_types.get(type_id);
    }

    /// Name protocol `protocol_id` `ns/Name`, as its Var is named.
    pub fn nameProtocol(self: *Interner, protocol_id: u32, ns: []const u8, name: []const u8) Allocator.Error!void {
        return self.protocols.set(self.gpa, protocol_id, ns, '/', name);
    }

    /// The `ns/Name` of protocol `protocol_id`, or null when it was
    /// never named.
    pub fn protocolName(self: *const Interner, protocol_id: u32) ?[]const u8 {
        return self.protocols.get(protocol_id);
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
        return self.keywordValue(try self.internQualified(&self.keyword, ns, name));
    }

    /// `internQualifiedKeyword` for symbols.
    pub fn internQualifiedSymbol(self: *Interner, ns: ?[]const u8, name: []const u8) InternError!value.Value {
        return self.symbolValue(try self.internQualified(&self.symbol, ns, name));
    }

    fn internQualified(self: *Interner, table: *Table, ns: ?[]const u8, name: []const u8) InternError!u32 {
        const ns_prefix = ns orelse return internInto(table, self.gpa, name);
        const full = try self.gpa.print("{s}/{s}", .{ ns_prefix, name });
        defer self.gpa.free(full);
        return internInto(table, self.gpa, full);
    }

    /// Split an interned `ns/name` text back into its parts at its
    /// first slash, as Clojure's `namespace` and `name` do; `ns` is
    /// null for an unqualified name. The bare division symbol `/` is
    /// an unqualified name (INTERN.md §3).
    pub fn splitQualified(full: []const u8) struct { ns: ?[]const u8, name: []const u8 } {
        if (std.mem.eql(u8, full, "/")) return .{ .ns = null, .name = full };
        const slash = std.mem.findScalar(u8, full, '/') orelse return .{ .ns = null, .name = full };
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
        return value.fromKeyword(id, self.keyword.entries.items[id].hash);
    }

    /// `keywordValue` for symbols.
    pub fn symbolValue(self: *const Interner, id: u32) value.Value {
        _ = nameFrom(&self.symbol, id);
        return value.fromSymbol(id, self.symbol.entries.items[id].hash);
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
        return @intCast(self.keyword.entries.items.len);
    }

    pub fn symbolCount(self: *const Interner) u32 {
        return @intCast(self.symbol.entries.items.len);
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

test "record type and protocol names: named ids give ns.Type and ns/Name, others null" {
    var it = Interner.init(testing.allocator);
    defer it.deinit();
    try testing.expect(it.recordTypeName(0) == null);
    try it.nameRecordType(2, "my.app", "Point");
    try testing.expectEqualStrings("my.app.Point", it.recordTypeName(2).?);
    try testing.expect(it.recordTypeName(0) == null);
    try testing.expect(it.recordTypeName(3) == null);
    try it.nameRecordType(2, "user", "P");
    try testing.expectEqualStrings("user.P", it.recordTypeName(2).?);
    try it.nameProtocol(1, "user", "Shape");
    try testing.expectEqualStrings("user/Shape", it.protocolName(1).?);
    try testing.expect(it.protocolName(0) == null and it.protocolName(2) == null);
    try it.nameProtocol(0, "", "Bare");
    try testing.expectEqualStrings("Bare", it.protocolName(0).?);
}

test "by_name lookups survive names reallocation" {
    // Force enough inserts to grow `names` past its initial capacity
    // (ArrayList grows geometrically). Every previously-returned
    // id must still resolve, and every name must still be found. This
    // exercises the claim in `docs/INTERN.md` §4 that map keys point at
    // the duped byte buffers, not into `entries.items`.
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
        const s = std.mem.print(&buf, "name-{d}", .{i}) catch unreachable;
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
