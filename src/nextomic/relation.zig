//! relation.zig — the columnar Relation of the query pipeline
//! (NEXTOMIC.md §5 "Relation").
//!
//! A relation is a set of rows over an ordered list of variables. It
//! lives in the query arena and is never a VM value; results are copied
//! into the VM heap by `query/exec.zig`. Invariants:
//!   - `vars` are unique; column `i` holds the values of `vars[i]`.
//!   - Every column has exactly `rows` entries.
//!   - An `int` column holds only integers (entity ids, refs, longs,
//!     instants, transaction entities); it widens to a `cell` column on
//!     the first value of another kind and never narrows back.
//!   - Rows are not deduplicated on append; `dedup` makes the relation
//!     a set. Row equality is cell-wise `Cell.eql`; `Cell.hash` agrees
//!     with it.
//!   - `sort` orders rows by `Cell.order` column by column, so two
//!     relations over the same variables with the same row set compare
//!     equal row by row after sorting.

const std = @import("std");
const value = @import("value");
const string_mod = @import("string");
const dispatch = @import("dispatch");
const hash_mod = @import("hash");
const key = @import("key.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;

/// A variable, as an index into the plan's variable table. Relations
/// carry variables by this index; the table maps it to the VM symbol.
pub const Var = u32;

// =============================================================================
// Cell — one value in a relation
// =============================================================================

/// A relation value in the VM's own terms: every integer-valued datom
/// component (entity id, ref, long, instant, transaction entity) is
/// `int`, keywords carry the VM intern id, strings borrow arena bytes
/// (uuids as their canonical text, byte arrays as their bytes), and
/// every other VM value rides in `vm`. `Cell.fromValue` maps a VM value
/// onto the first six arms, so `vm` never holds a fixnum, float,
/// boolean, keyword or string; cross-arm equality is therefore always
/// false without loss.
pub const Cell = union(enum) {
    nil,
    int: i64,
    double: f64,
    boolean: bool,
    /// VM keyword intern id.
    keyword: u32,
    str: []const u8,
    vm: Value,

    pub fn fromValue(v: Value) Cell {
        return switch (v.kind()) {
            .nil => .nil,
            .fixnum => .{ .int = v.asFixnum() },
            .float => .{ .double = v.asFloat() },
            .true_, .false_ => .{ .boolean = v.asBool() },
            .keyword => .{ .keyword = v.asKeywordId() },
            .string => .{ .str = string_mod.asBytes(v) },
            else => .{ .vm = v },
        };
    }

    pub fn eql(a: Cell, b: Cell) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .nil => true,
            .int => |x| x == b.int,
            .double => |x| normalize(x) == normalize(b.double),
            .boolean => |x| x == b.boolean,
            .keyword => |x| x == b.keyword,
            .str => |x| std.mem.eql(u8, x, b.str),
            .vm => |x| dispatch.equal(x, b.vm),
        };
    }

    pub fn hash(self: Cell) u64 {
        const tag: u64 = @intFromEnum(std.meta.activeTag(self));
        const base: u64 = switch (self) {
            .nil => 0xB01D_FACE_B01D_FACE,
            .int => |x| hash_mod.hashI64(x),
            .double => |x| hash_mod.hashFloat(normalize(x)),
            .boolean => |x| @intFromBool(x),
            .keyword => |x| hash_mod.hashU64(x),
            .str => |x| std.hash.Wyhash.hash(0, x),
            .vm => |x| dispatch.hashValue(x),
        };
        return hash_mod.hashU64(base ^ (tag *% 0x9E37_79B9_7F4A_7C15));
    }

    /// Rank of the arm in the cross-type order used by `order`.
    fn rank(self: Cell) u8 {
        return switch (self) {
            .nil => 0,
            .boolean => 1,
            .int, .double => 2,
            .str => 3,
            .keyword => 4,
            .vm => 5,
        };
    }

    /// A total order: nil < booleans < numbers < strings < keywords <
    /// other VM values. Numbers compare numerically across int and
    /// double; strings by bytes; keywords by intern id; VM values by
    /// hash (a stable tie-break, not a semantic order).
    pub fn order(a: Cell, b: Cell) std.math.Order {
        const ra = a.rank();
        const rb = b.rank();
        if (ra != rb) return std.math.order(ra, rb);
        return switch (a) {
            .nil => .eq,
            .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
            .int => |x| switch (b) {
                .int => |y| std.math.order(x, y),
                .double => |y| orderNum(@floatFromInt(x), y),
                else => unreachable,
            },
            .double => |x| switch (b) {
                .int => |y| orderNum(x, @floatFromInt(y)),
                .double => |y| orderNum(x, y),
                else => unreachable,
            },
            .str => |x| std.mem.order(u8, x, b.str),
            .keyword => |x| std.math.order(x, b.keyword),
            .vm => |x| std.math.order(dispatch.hashValue(x), dispatch.hashValue(b.vm)),
        };
    }

    fn orderNum(x: f64, y: f64) std.math.Order {
        if (x < y) return .lt;
        if (x > y) return .gt;
        return .eq;
    }

    /// The integer of an `int` cell, or null.
    pub fn asInt(self: Cell) ?i64 {
        return if (self == .int) self.int else null;
    }

    /// The entity id of an `int` cell in id range, or null.
    pub fn asEid(self: Cell) ?u64 {
        const n = self.asInt() orelse return null;
        if (n < 0 or n > key.id_max) return null;
        return @intCast(n);
    }
};

fn normalize(d: f64) f64 {
    return if (d == 0.0) 0.0 else d;
}

// =============================================================================
// Column
// =============================================================================

/// One variable's values. Starts as an `int` column and widens to
/// `cell` on the first value of another kind.
pub const Column = union(enum) {
    int: std.ArrayList(i64),
    cell: std.ArrayList(Cell),

    pub const empty: Column = .{ .int = .empty };

    pub fn len(self: *const Column) usize {
        return switch (self.*) {
            .int => |c| c.items.len,
            .cell => |c| c.items.len,
        };
    }

    pub fn get(self: *const Column, i: usize) Cell {
        return switch (self.*) {
            .int => |c| .{ .int = c.items[i] },
            .cell => |c| c.items[i],
        };
    }

    pub fn append(self: *Column, arena: Allocator, v: Cell) !void {
        switch (self.*) {
            .int => |*c| {
                if (v == .int) return c.append(arena, v.int);
                var wide: std.ArrayList(Cell) = .empty;
                try wide.ensureTotalCapacity(arena, c.items.len + 1);
                for (c.items) |n| wide.appendAssumeCapacity(.{ .int = n });
                wide.appendAssumeCapacity(v);
                self.* = .{ .cell = wide };
            },
            .cell => |*c| try c.append(arena, v),
        }
    }
};

// =============================================================================
// Relation
// =============================================================================

pub const Relation = struct {
    arena: Allocator,
    vars: []const Var,
    cols: []Column,
    rows: usize = 0,

    /// An empty relation over `vars`, which are copied.
    pub fn init(arena: Allocator, vars: []const Var) !Relation {
        const cols = try arena.alloc(Column, vars.len);
        for (cols) |*c| c.* = .empty;
        return .{ .arena = arena, .vars = try arena.dupe(Var, vars), .cols = cols };
    }

    /// The relation with no variables and one row: the identity of the
    /// join, from which a query with no inputs starts.
    pub fn unit(arena: Allocator) !Relation {
        var r = try init(arena, &.{});
        r.rows = 1;
        return r;
    }

    pub fn colOf(self: *const Relation, v: Var) ?usize {
        for (self.vars, 0..) |x, i| {
            if (x == v) return i;
        }
        return null;
    }

    pub fn has(self: *const Relation, v: Var) bool {
        return self.colOf(v) != null;
    }

    pub fn cell(self: *const Relation, row: usize, col: usize) Cell {
        return self.cols[col].get(row);
    }

    /// The cell of variable `v` in `row`, or null when the relation has
    /// no such variable.
    pub fn get(self: *const Relation, row: usize, v: Var) ?Cell {
        const c = self.colOf(v) orelse return null;
        return self.cell(row, c);
    }

    /// Append one row given as cells in `vars` order.
    pub fn append(self: *Relation, cells: []const Cell) !void {
        std.debug.assert(cells.len == self.cols.len);
        for (self.cols, cells) |*c, v| try c.append(self.arena, v);
        self.rows += 1;
    }

    /// Append row `row` of `src`, whose variables are a superset of
    /// this relation's, in this relation's column order.
    pub fn appendFrom(self: *Relation, src: *const Relation, row: usize, map: []const usize) !void {
        std.debug.assert(map.len == self.cols.len);
        for (self.cols, map) |*c, sc| try c.append(self.arena, src.cell(row, sc));
        self.rows += 1;
    }

    /// Column indexes in `src` of this relation's variables.
    pub fn mapFrom(self: *const Relation, src: *const Relation) ![]usize {
        const map = try self.arena.alloc(usize, self.vars.len);
        for (self.vars, map) |v, *m| m.* = src.colOf(v) orelse return error.MissingVar;
        return map;
    }

    /// Gather one row into `out`.
    pub fn rowInto(self: *const Relation, row: usize, out: []Cell) void {
        std.debug.assert(out.len == self.cols.len);
        for (self.cols, out) |*c, *o| o.* = c.get(row);
    }

    pub fn rowHash(self: *const Relation, row: usize) u64 {
        var h: u64 = 0x1234_5678_9ABC_DEF0;
        for (self.cols) |*c| h = hash_mod.hashU64(h ^ c.get(row).hash());
        return h;
    }

    pub fn rowsEql(self: *const Relation, a: usize, other: *const Relation, b: usize) bool {
        std.debug.assert(self.cols.len == other.cols.len);
        for (self.cols, other.cols) |*x, *y| {
            if (!x.get(a).eql(y.get(b))) return false;
        }
        return true;
    }

    /// The set of distinct row indexes of `self`, as a hash index from
    /// row hash to the first row with that content.
    const RowSet = struct {
        rel: *const Relation,
        map: std.AutoHashMapUnmanaged(u64, std.ArrayList(usize)) = .empty,

        fn contains(self: *RowSet, other: *const Relation, row: usize, h: u64) bool {
            const bucket = self.map.getPtr(h) orelse return false;
            for (bucket.items) |r| {
                if (self.rel.rowsEql(r, other, row)) return true;
            }
            return false;
        }

        /// Insert row `row` of `self.rel`; false when an equal row was
        /// already present.
        fn insert(self: *RowSet, arena: Allocator, row: usize) !bool {
            const h = self.rel.rowHash(row);
            const gop = try self.map.getOrPut(arena, h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |r| {
                if (self.rel.rowsEql(r, self.rel, row)) return false;
            }
            try gop.value_ptr.append(arena, row);
            return true;
        }
    };

    /// A copy with duplicate rows removed, first occurrence kept.
    pub fn dedup(self: *const Relation) !Relation {
        var out = try init(self.arena, self.vars);
        var seen: RowSet = .{ .rel = &out };
        var i: usize = 0;
        while (i < self.rows) : (i += 1) {
            const map = identityMap(self.cols.len);
            try out.appendFrom(self, i, map[0..self.cols.len]);
            if (!try seen.insert(self.arena, out.rows - 1)) try out.dropLast();
        }
        return out;
    }

    fn dropLast(self: *Relation) !void {
        for (self.cols) |*c| switch (c.*) {
            .int => |*x| _ = x.pop(),
            .cell => |*x| _ = x.pop(),
        };
        self.rows -= 1;
    }

    /// The projection of `self` onto `vars` (each of which `self` has),
    /// deduplicated when `distinct`.
    pub fn project(self: *const Relation, vars: []const Var, distinct: bool) !Relation {
        var out = try init(self.arena, vars);
        const map = try out.mapFrom(self);
        var seen: RowSet = .{ .rel = &out };
        var i: usize = 0;
        while (i < self.rows) : (i += 1) {
            try out.appendFrom(self, i, map);
            if (distinct and !try seen.insert(self.arena, out.rows - 1)) try out.dropLast();
        }
        return out;
    }

    /// `self ∪ other`, both over the same variables (in any order);
    /// the result is distinct.
    pub fn unionWith(self: *const Relation, other: *const Relation) !Relation {
        var out = try init(self.arena, self.vars);
        var seen: RowSet = .{ .rel = &out };
        const self_map = try out.mapFrom(self);
        var i: usize = 0;
        while (i < self.rows) : (i += 1) {
            try out.appendFrom(self, i, self_map);
            if (!try seen.insert(self.arena, out.rows - 1)) try out.dropLast();
        }
        const other_map = try out.mapFrom(other);
        i = 0;
        while (i < other.rows) : (i += 1) {
            try out.appendFrom(other, i, other_map);
            if (!try seen.insert(self.arena, out.rows - 1)) try out.dropLast();
        }
        return out;
    }

    /// The rows of `self` whose values on `on` do not appear in
    /// `other` (the anti-join). `other` must have every variable in
    /// `on`; the result keeps `self`'s columns and order.
    pub fn difference(self: *const Relation, other: *const Relation, on: []const Var) !Relation {
        const probe = try other.project(on, true);
        var index: RowSet = .{ .rel = &probe };
        var i: usize = 0;
        while (i < probe.rows) : (i += 1) _ = try index.insert(self.arena, i);

        const keyed = try self.project(on, false);
        var out = try init(self.arena, self.vars);
        const map = identityMap(self.cols.len);
        i = 0;
        while (i < self.rows) : (i += 1) {
            if (!index.contains(&keyed, i, keyed.rowHash(i))) try out.appendFrom(self, i, map[0..self.cols.len]);
        }
        return out;
    }

    /// The rows of `self` whose values on `on` appear in `other`
    /// (the semi-join).
    pub fn semiJoin(self: *const Relation, other: *const Relation, on: []const Var) !Relation {
        const probe = try other.project(on, true);
        var index: RowSet = .{ .rel = &probe };
        var i: usize = 0;
        while (i < probe.rows) : (i += 1) _ = try index.insert(self.arena, i);

        const keyed = try self.project(on, false);
        var out = try init(self.arena, self.vars);
        const map = identityMap(self.cols.len);
        i = 0;
        while (i < self.rows) : (i += 1) {
            if (index.contains(&keyed, i, keyed.rowHash(i))) try out.appendFrom(self, i, map[0..self.cols.len]);
        }
        return out;
    }

    /// The variables of `other` that `self` lacks.
    pub fn newVars(self: *const Relation, other: *const Relation) ![]Var {
        var out: std.ArrayList(Var) = .empty;
        for (other.vars) |v| {
            if (!self.has(v)) try out.append(self.arena, v);
        }
        return out.toOwnedSlice(self.arena);
    }

    /// The variables both relations have.
    pub fn sharedVars(self: *const Relation, other: *const Relation) ![]Var {
        var out: std.ArrayList(Var) = .empty;
        for (self.vars) |v| {
            if (other.has(v)) try out.append(self.arena, v);
        }
        return out.toOwnedSlice(self.arena);
    }

    /// The natural join of `self` and `other` on their shared variables
    /// (a cross product when they share none). `other` is hashed on
    /// the shared variables; the result's columns are `self`'s followed
    /// by `other`'s new variables.
    pub fn hashJoin(self: *const Relation, other: *const Relation) !Relation {
        const on = try self.sharedVars(other);
        const extra = try self.newVars(other);
        const out_vars = try std.mem.concat(self.arena, Var, &.{ self.vars, extra });
        var out = try init(self.arena, out_vars);
        if (self.rows == 0 or other.rows == 0) return out;

        const other_key = try other.project(on, false);
        var index: std.AutoHashMapUnmanaged(u64, std.ArrayList(usize)) = .empty;
        var i: usize = 0;
        while (i < other.rows) : (i += 1) {
            const gop = try index.getOrPut(self.arena, other_key.rowHash(i));
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(self.arena, i);
        }

        const self_key = try self.project(on, false);
        const extra_map = try self.arena.alloc(usize, extra.len);
        for (extra, extra_map) |v, *m| m.* = other.colOf(v).?;
        const self_map = identityMap(self.cols.len);

        i = 0;
        while (i < self.rows) : (i += 1) {
            const bucket = index.get(self_key.rowHash(i)) orelse continue;
            for (bucket.items) |j| {
                if (!self_key.rowsEql(i, &other_key, j)) continue;
                for (out.cols[0..self.cols.len], self_map[0..self.cols.len]) |*c, sc| try c.append(self.arena, self.cell(i, sc));
                for (out.cols[self.cols.len..], extra_map) |*c, oc| try c.append(self.arena, other.cell(j, oc));
                out.rows += 1;
            }
        }
        return out;
    }

    /// Sort rows lexicographically by `Cell.order` over the columns in
    /// order. In place.
    pub fn sort(self: *Relation) !void {
        const perm = try self.arena.alloc(usize, self.rows);
        for (perm, 0..) |*p, i| p.* = i;
        const ctx = SortCtx{ .rel = self };
        std.mem.sort(usize, perm, ctx, SortCtx.lessThan);
        for (self.cols) |*c| {
            switch (c.*) {
                .int => |*x| {
                    const copy = try self.arena.dupe(i64, x.items);
                    for (perm, 0..) |p, i| x.items[i] = copy[p];
                },
                .cell => |*x| {
                    const copy = try self.arena.dupe(Cell, x.items);
                    for (perm, 0..) |p, i| x.items[i] = copy[p];
                },
            }
        }
    }

    const SortCtx = struct {
        rel: *const Relation,
        fn lessThan(ctx: SortCtx, a: usize, b: usize) bool {
            for (ctx.rel.cols) |*c| {
                switch (c.get(a).order(c.get(b))) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
            }
            return false;
        }
    };

    /// Do two relations over the same variables (same order) hold the
    /// same rows in the same order?
    pub fn eqlRows(self: *const Relation, other: *const Relation) bool {
        if (self.rows != other.rows or self.vars.len != other.vars.len) return false;
        var i: usize = 0;
        while (i < self.rows) : (i += 1) {
            if (!self.rowsEql(i, other, i)) return false;
        }
        return true;
    }
};

const max_identity = 64;
const identity_table = blk: {
    var t: [max_identity]usize = undefined;
    for (&t, 0..) |*x, i| x.* = i;
    break :blk t;
};

/// `0..n` as a slice; relations have at most `max_identity` columns.
fn identityMap(n: usize) []const usize {
    std.debug.assert(n <= max_identity);
    return identity_table[0..n];
}

/// The largest number of variables one relation can carry.
pub const max_vars = max_identity;

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn rel(arena: Allocator, vars: []const Var, rows: []const []const Cell) !Relation {
    var r = try Relation.init(arena, vars);
    for (rows) |row| try r.append(row);
    return r;
}

test "cells: equality, hash agreement, order" {
    const a: Cell = .{ .int = 3 };
    const b: Cell = .{ .double = 3.0 };
    try testing.expect(!a.eql(b));
    try testing.expect(a.order(b) == .eq);
    try testing.expect(a.eql(.{ .int = 3 }));
    try testing.expectEqual(a.hash(), (Cell{ .int = 3 }).hash());
    try testing.expect((Cell{ .str = "abc" }).eql(.{ .str = "abc" }));
    try testing.expectEqual((Cell{ .str = "abc" }).hash(), (Cell{ .str = "abc" }).hash());
    try testing.expect((Cell{ .double = 0.0 }).eql(.{ .double = -0.0 }));
    try testing.expectEqual((Cell{ .double = 0.0 }).hash(), (Cell{ .double = -0.0 }).hash());
    try testing.expect((Cell{ .int = 1 }).order(.{ .str = "a" }) == .lt);
    try testing.expect((Cell{ .str = "a" }).order(.{ .keyword = 0 }) == .lt);
    try testing.expect((Cell{ .nil = {} }).order(.{ .boolean = false }) == .lt);
    try testing.expect((Cell{ .int = 2 }).order(.{ .double = 1.5 }) == .gt);
    try testing.expect(Cell.fromValue(value.fromFixnum(7).?).eql(.{ .int = 7 }));
    try testing.expect(Cell.fromValue(value.nilValue()) == .nil);
    try testing.expect(Cell.fromValue(value.fromChar('x').?) == .vm);
    try testing.expectEqual(@as(?u64, 5), (Cell{ .int = 5 }).asEid());
    try testing.expect((Cell{ .int = -5 }).asEid() == null);
}

test "column widens from int to cell" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var c: Column = .empty;
    try c.append(arena, .{ .int = 1 });
    try c.append(arena, .{ .int = 2 });
    try testing.expect(c == .int);
    try c.append(arena, .{ .str = "x" });
    try testing.expect(c == .cell);
    try testing.expectEqual(@as(usize, 3), c.len());
    try testing.expect(c.get(0).eql(.{ .int = 1 }));
    try testing.expect(c.get(2).eql(.{ .str = "x" }));
}

test "dedup, project, union, difference, sort" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try rel(arena, &.{ 0, 1 }, &.{
        &.{ .{ .int = 1 }, .{ .str = "a" } },
        &.{ .{ .int = 2 }, .{ .str = "b" } },
        &.{ .{ .int = 1 }, .{ .str = "a" } },
        &.{ .{ .int = 1 }, .{ .str = "c" } },
    });
    const d = try r.dedup();
    try testing.expectEqual(@as(usize, 3), d.rows);
    const p = try r.project(&.{0}, true);
    try testing.expectEqual(@as(usize, 2), p.rows);
    const p2 = try r.project(&.{ 1, 0 }, false);
    try testing.expectEqual(@as(usize, 4), p2.rows);
    try testing.expect(p2.cell(0, 0).eql(.{ .str = "a" }));

    const s = try rel(arena, &.{ 1, 0 }, &.{
        &.{ .{ .str = "z" }, .{ .int = 9 } },
        &.{ .{ .str = "a" }, .{ .int = 1 } },
    });
    const u = try d.unionWith(&s);
    try testing.expectEqual(@as(usize, 4), u.rows);
    try testing.expectEqualSlices(Var, &.{ 0, 1 }, u.vars);

    const diff = try r.difference(&s, &.{0});
    try testing.expectEqual(@as(usize, 1), diff.rows);
    try testing.expect(diff.cell(0, 0).eql(.{ .int = 2 }));
    const semi = try r.semiJoin(&s, &.{0});
    try testing.expectEqual(@as(usize, 3), semi.rows);

    var sorted = try r.dedup();
    try sorted.sort();
    try testing.expect(sorted.cell(0, 0).eql(.{ .int = 1 }) and sorted.cell(0, 1).eql(.{ .str = "a" }));
    try testing.expect(sorted.cell(1, 0).eql(.{ .int = 1 }) and sorted.cell(1, 1).eql(.{ .str = "c" }));
    try testing.expect(sorted.cell(2, 0).eql(.{ .int = 2 }));
    var again = try r.dedup();
    try again.sort();
    try testing.expect(sorted.eqlRows(&again));
}

test "hash join on shared vars and cross product" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const people = try rel(arena, &.{ 0, 1 }, &.{
        &.{ .{ .int = 1 }, .{ .str = "ann" } },
        &.{ .{ .int = 2 }, .{ .str = "bob" } },
        &.{ .{ .int = 3 }, .{ .str = "cy" } },
    });
    const ages = try rel(arena, &.{ 2, 0 }, &.{
        &.{ .{ .int = 30 }, .{ .int = 1 } },
        &.{ .{ .int = 31 }, .{ .int = 1 } },
        &.{ .{ .int = 40 }, .{ .int = 3 } },
        &.{ .{ .int = 50 }, .{ .int = 7 } },
    });
    var j = try people.hashJoin(&ages);
    try testing.expectEqualSlices(Var, &.{ 0, 1, 2 }, j.vars);
    try testing.expectEqual(@as(usize, 3), j.rows);
    try j.sort();
    try testing.expect(j.cell(0, 2).eql(.{ .int = 30 }));
    try testing.expect(j.cell(2, 1).eql(.{ .str = "cy" }));

    const flags = try rel(arena, &.{5}, &.{ &.{.{ .boolean = true }}, &.{.{ .boolean = false }} });
    const cross = try people.hashJoin(&flags);
    try testing.expectEqual(@as(usize, 6), cross.rows);

    const unit = try Relation.unit(arena);
    const seeded = try unit.hashJoin(&people);
    try testing.expectEqual(@as(usize, 3), seeded.rows);
    try testing.expectEqualSlices(Var, &.{ 0, 1 }, seeded.vars);
}
