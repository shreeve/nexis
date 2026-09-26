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
//!   - A relation is not changed once built: `without`, `rowsAt`,
//!     `beside` and `join` lend its columns to the relations they make
//!     rather than copying them, so only the builder of a relation
//!     appends to it or sorts it.

const std = @import("std");
const value = @import("../value.zig");
const string_mod = @import("../string.zig");
const dispatch = @import("../dispatch.zig");
const hash_mod = @import("../hash.zig");
const bignum = @import("../bignum.zig");
const key = @import("key.zig");
const Interner = @import("../intern.zig").Interner;

const Allocator = std.mem.Allocator;
const Value = value.Value;

/// A variable, as an index into the plan's variable table. Relations
/// carry variables by this index; the table maps it to the VM symbol.
pub const Var = u32;

// =============================================================================
// Cell — one value in a relation
// =============================================================================

/// A relation value in the VM's own terms: every integer-valued datom
/// component (entity id, ref, long, instant, transaction entity) and
/// every integer in i64, fixnum or bignum, is `int`; keywords carry the
/// VM intern id, strings borrow arena bytes (uuids as their canonical
/// text, byte arrays as their bytes), and every other VM value rides in
/// `vm`. `Cell.fromValue` maps a VM value onto the first six arms, so
/// `vm` never holds a fixnum, float, boolean, keyword, string or
/// integer in i64; cross-arm equality is therefore always false without
/// loss. An integer past i64 is a `vm` bignum and orders as a number. A
/// function (a variable in function position holds one) is
/// identity-valued: it hashes and compares by the bits of its value.
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
            .bignum => if (bignum.toI64(v)) |n| .{ .int = n } else .{ .vm = v },
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
            .vm => |x| if (isFunction(x)) x.tag == b.vm.tag and x.payload == b.vm.payload else dispatch.equal(x, b.vm),
        };
    }

    fn isFunction(v: Value) bool {
        return switch (v.kind()) {
            .function, .native_fn => true,
            else => false,
        };
    }

    fn vmHash(v: Value) u64 {
        return if (isFunction(v)) hash_mod.hashU64(v.payload) else dispatch.hashValue(v);
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
            .vm => |x| vmHash(x),
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
            .vm => |v| if (v.kind() == .bignum) 2 else 5,
        };
    }

    /// The order `compare` gives two values of one type (numbers are
    /// one type), or null when they are not comparable here: different
    /// types, or VM values.
    pub fn compare(a: Cell, b: Cell, names: *const Interner) ?std.math.Order {
        if (a.rank() != b.rank() or a.rank() == 5) return null;
        return a.orderBy(b, names);
    }

    /// `order` with keywords by name, as `compare` orders them.
    pub fn orderBy(a: Cell, b: Cell, names: *const Interner) std.math.Order {
        if (a == .keyword and b == .keyword) return Interner.compareNames(names.keywordName(a.keyword), names.keywordName(b.keyword));
        return a.order(b);
    }

    /// A total order: nil < booleans < numbers < strings < keywords <
    /// other VM values. Numbers compare as `compare` orders them:
    /// integers exactly at any size, and in f64 when either is a
    /// double; strings by bytes; keywords by intern id; VM values by
    /// hash. Keywords and VM values are in a stable order, not a
    /// semantic one; `orderBy` orders keywords as the language does.
    pub fn order(a: Cell, b: Cell) std.math.Order {
        const ra = a.rank();
        const rb = b.rank();
        if (ra != rb) return std.math.order(ra, rb);
        if (ra == 2) return orderNumbers(a, b);
        return switch (a) {
            .nil => .eq,
            .boolean => |x| std.math.order(@intFromBool(x), @intFromBool(b.boolean)),
            .str => |x| std.mem.order(u8, x, b.str),
            .keyword => |x| std.math.order(x, b.keyword),
            .vm => |x| std.math.order(vmHash(x), vmHash(b.vm)),
            .int, .double => unreachable,
        };
    }

    fn orderNumbers(a: Cell, b: Cell) std.math.Order {
        if (a == .double or b == .double) return orderNum(a.asNumber().?, b.asNumber().?);
        if (a == .int and b == .int) return std.math.order(a.int, b.int);
        // A bignum cell lies past i64, so its sign places it against an int.
        if (a == .int) return if (bignum.isNegative(b.vm)) .gt else .lt;
        if (b == .int) return if (bignum.isNegative(a.vm)) .lt else .gt;
        return bignum.compare(a.vm, b.vm);
    }

    fn orderNum(x: f64, y: f64) std.math.Order {
        if (x < y) return .lt;
        if (x > y) return .gt;
        return .eq;
    }

    /// A number cell as the nearest double, or null for another cell.
    pub fn asNumber(self: Cell) ?f64 {
        return switch (self) {
            .int => |n| @floatFromInt(n),
            .double => |d| d,
            .vm => |v| if (v.kind() == .bignum) bignum.toF64(v) else null,
            else => null,
        };
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

    /// The values at rows `idx`, in that order.
    fn gather(self: *const Column, arena: Allocator, idx: []const u32) !Column {
        switch (self.*) {
            inline else => |c, tag| {
                const out = try arena.alloc(@TypeOf(c.items[0]), idx.len);
                for (idx, out) |i, *o| o.* = c.items[i];
                return @unionInit(Column, @tagName(tag), .fromOwnedSlice(out));
            },
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
    /// The hash indexes `join` has built over these columns, when the
    /// relation's keeper lets them outlive one join: a query's cached
    /// scans do, since later patterns join with them again.
    indexes: ?*std.ArrayList(Hashed) = null,

    /// A row index by the column positions it hashes.
    pub const Hashed = struct {
        cols: []const usize,
        index: RowIndex,
    };

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

    /// Append row `row` of `src`, whose columns are this relation's
    /// columns in the same order.
    pub fn copyRow(self: *Relation, src: *const Relation, row: usize) !void {
        std.debug.assert(src.cols.len == self.cols.len);
        for (self.cols, 0..) |*c, i| try c.append(self.arena, src.cell(row, i));
        self.rows += 1;
    }

    /// Column indexes in `src` of this relation's variables.
    pub fn mapFrom(self: *const Relation, src: *const Relation) ![]usize {
        const map = try self.arena.alloc(usize, self.vars.len);
        for (self.vars, map) |v, *m| m.* = src.colOf(v) orelse return error.MissingVar;
        return map;
    }

    /// Column indexes of `vars`, each of which this relation has.
    pub fn mapOf(self: *const Relation, vars: []const Var) ![]usize {
        const map = try self.arena.alloc(usize, vars.len);
        for (vars, map) |v, *m| m.* = self.colOf(v) orelse return error.MissingVar;
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

    /// The hash of row `row` over the columns `cols`.
    pub fn rowHashOn(self: *const Relation, cols: []const usize, row: usize) u64 {
        var h: u64 = 0x1234_5678_9ABC_DEF0;
        for (cols) |c| h = hash_mod.hashU64(h ^ self.cols[c].get(row).hash());
        return h;
    }

    /// Cell-wise equality of row `a` over `cols` with row `b` of
    /// `other` over `ocols`.
    pub fn rowsEqlOn(self: *const Relation, cols: []const usize, a: usize, other: *const Relation, ocols: []const usize, b: usize) bool {
        std.debug.assert(cols.len == ocols.len);
        for (cols, ocols) |x, y| {
            if (!self.cols[x].get(a).eql(other.cols[y].get(b))) return false;
        }
        return true;
    }

    /// A hash index over rows: row hash to the chain of rows with that
    /// hash. The row hash mixes every cell already, so the map takes
    /// it as the key as is; a chain is a linked list through `next`,
    /// which costs nothing per row beyond its slot, and reads from the
    /// row added last, so rows added last to first read in row order.
    pub const RowIndex = struct {
        head: std.HashMapUnmanaged(u64, u32, Identity, std.hash_map.default_max_load_percentage) = .empty,
        next: std.ArrayList(u32) = .empty,

        const none = std.math.maxInt(u32);

        const Identity = struct {
            pub fn hash(_: Identity, k: u64) u64 {
                return k;
            }
            pub fn eql(_: Identity, a: u64, b: u64) bool {
                return a == b;
            }
        };

        /// Room for rows `0..n` before any `add`, so the map never
        /// rehashes while it is built.
        fn reserve(self: *RowIndex, arena: Allocator, n: usize) !void {
            try self.head.ensureTotalCapacity(arena, @intCast(n));
            try self.next.resize(arena, n);
        }

        /// The first row in the chain of hash `h`, or null.
        fn first(self: *const RowIndex, h: u64) ?u32 {
            return self.head.get(h);
        }

        /// The row after `row` in its chain, or null.
        fn after(self: *const RowIndex, row: u32) ?u32 {
            const n = self.next.items[row];
            return if (n == none) null else n;
        }

        /// An index over every row of `r` hashed on `cols`, added last
        /// to first so that a chain reads in row order.
        fn over(arena: Allocator, r: *const Relation, cols: []const usize) !RowIndex {
            var index: RowIndex = .{};
            try index.reserve(arena, r.rows);
            var i: usize = r.rows;
            while (i > 0) {
                i -= 1;
                try index.add(arena, @intCast(i), r.rowHashOn(cols, i));
            }
            return index;
        }

        /// Add row `row` with hash `h` at the front of its chain.
        fn add(self: *RowIndex, arena: Allocator, row: u32, h: u64) !void {
            if (row >= self.next.items.len) try self.next.resize(arena, row + 1);
            const gop = try self.head.getOrPut(arena, h);
            self.next.items[row] = if (gop.found_existing) gop.value_ptr.* else none;
            gop.value_ptr.* = row;
        }
    };

    /// The set of distinct rows of `rel`, a `RowIndex` over every row
    /// kept, compared cell-wise.
    const RowSet = struct {
        rel: *const Relation,
        index: RowIndex = .{},

        fn contains(self: *RowSet, other: *const Relation, row: usize, h: u64) bool {
            var r = self.index.first(h);
            while (r) |i| : (r = self.index.after(i)) {
                if (self.rel.rowsEql(i, other, row)) return true;
            }
            return false;
        }

        /// Insert row `row` of `self.rel`, which is its last row; false
        /// when an equal row was already present.
        fn insert(self: *RowSet, arena: Allocator, row: usize) !bool {
            const h = self.rel.rowHash(row);
            if (self.contains(self.rel, row, h)) return false;
            try self.index.add(arena, @intCast(row), h);
            return true;
        }
    };

    /// A copy with duplicate rows removed, first occurrence kept.
    pub fn dedup(self: *const Relation) !Relation {
        var out = try init(self.arena, self.vars);
        var seen: RowSet = .{ .rel = &out };
        var i: usize = 0;
        while (i < self.rows) : (i += 1) {
            try out.copyRow(self, i);
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

    /// The relation without the columns of `drop`; the other columns
    /// are lent, not copied.
    pub fn without(self: *const Relation, drop: []const Var) !Relation {
        if (drop.len == 0) return self.*;
        const vars = try self.arena.alloc(Var, self.vars.len);
        const cols = try self.arena.alloc(Column, vars.len);
        var n: usize = 0;
        for (self.vars, self.cols) |v, c| {
            if (std.mem.indexOfScalar(Var, drop, v) != null) continue;
            vars[n] = v;
            cols[n] = c;
            n += 1;
        }
        return .{ .arena = self.arena, .vars = vars[0..n], .cols = cols[0..n], .rows = self.rows };
    }

    /// The columns of `vars`, each of which the relation has, lent.
    pub fn pick(self: *const Relation, vars: []const Var) !Relation {
        const cols = try self.arena.alloc(Column, vars.len);
        for (vars, cols) |v, *c| c.* = self.cols[self.colOf(v).?];
        return .{ .arena = self.arena, .vars = vars, .cols = cols, .rows = self.rows };
    }

    /// The relation over `v` alone whose rows are the numbers `0..rows`.
    pub fn rowNumbers(arena: Allocator, v: Var, rows: usize) !Relation {
        const numbers = try arena.alloc(i64, rows);
        for (numbers, 0..) |*x, i| x.* = @intCast(i);
        const cols = try arena.alloc(Column, 1);
        cols[0] = .{ .int = .fromOwnedSlice(numbers) };
        return .{ .arena = arena, .vars = try arena.dupe(Var, &.{v}), .cols = cols, .rows = rows };
    }

    /// Rows `idx` of the relation, in that order, without the columns
    /// of `drop`; when `idx` is every row in order the columns are lent.
    pub fn rowsAt(self: *const Relation, idx: []const u32, drop: []const Var) !Relation {
        const kept = try self.without(drop);
        if (isIdentity(idx, self.rows)) return kept;
        const cols = try self.arena.alloc(Column, kept.cols.len);
        for (kept.cols, cols) |*c, *o| o.* = try c.gather(self.arena, idx);
        return .{ .arena = self.arena, .vars = kept.vars, .cols = cols, .rows = idx.len };
    }

    /// The columns of `self` followed by those of `other`, which has as
    /// many rows and none of its variables; both are lent.
    pub fn beside(self: *const Relation, other: *const Relation) !Relation {
        std.debug.assert(self.rows == other.rows);
        return .{
            .arena = self.arena,
            .vars = try std.mem.concat(self.arena, Var, &.{ self.vars, other.vars }),
            .cols = try std.mem.concat(self.arena, Column, &.{ self.cols, other.cols }),
            .rows = self.rows,
        };
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
        var kept: std.ArrayList(u32) = .empty;
        i = 0;
        while (i < self.rows) : (i += 1) {
            if (!index.contains(&keyed, i, keyed.rowHash(i))) try kept.append(self.arena, @intCast(i));
        }
        return self.rowsAt(kept.items, &.{});
    }

    /// `src` seen through `vars`, one per column of `src`: the relation
    /// over the distinct variables whose rows are those of `src` on
    /// which a repeated variable's columns agree. Without repeats it
    /// borrows the columns.
    pub fn viewAs(arena: Allocator, vars: []const Var, src: *const Relation) !Relation {
        std.debug.assert(vars.len == src.cols.len);
        var distinct: std.ArrayList(Var) = .empty;
        for (vars) |v| {
            if (std.mem.indexOfScalar(Var, distinct.items, v) == null) try distinct.append(arena, v);
        }
        if (distinct.items.len == vars.len) return .{ .arena = arena, .vars = vars, .cols = src.cols, .rows = src.rows };
        var out = try init(arena, distinct.items);
        const cells = try arena.alloc(Cell, distinct.items.len);
        var i: usize = 0;
        rows: while (i < src.rows) : (i += 1) {
            for (vars, 0..) |v, pos| {
                const d = std.mem.indexOfScalar(Var, distinct.items, v).?;
                const c = src.cell(i, pos);
                if (std.mem.indexOfScalar(Var, vars, v).? == pos) {
                    cells[d] = c;
                } else if (!cells[d].eql(c)) continue :rows;
            }
            try out.append(cells);
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
    /// (a cross product when they share none), without the columns of
    /// `drop`. The smaller side, or `other` when it keeps its indexes,
    /// is hashed on the shared variables and the other side probes it;
    /// a cross product pairs the rows without an index.
    /// The result's columns are `self`'s followed
    /// by `other`'s new variables, its rows in `self`'s order with the
    /// matches of a row in `other`'s order; a side whose every row comes
    /// out once, in order, lends its columns instead of copying them.
    pub fn join(self: *const Relation, other: *const Relation, drop: []const Var) !Relation {
        const arena = self.arena;
        const on = try self.sharedVars(other);
        const extra = try self.newVars(other);
        const out_vars = try std.mem.concat(arena, Var, &.{ self.vars, extra });
        if (self.rows == 0 or other.rows == 0) return (try init(arena, out_vars)).without(drop);

        const on_self = try self.mapOf(on);
        const on_other = try other.mapOf(on);
        var left: std.ArrayList(u32) = .empty;
        var right: std.ArrayList(u32) = .empty;
        // A relation that keeps its indexes is hashed whatever its size:
        // the index is built once for every join with it.
        const hash_other = other.rows <= self.rows or other.indexes != null;
        // Room for one match per probing row, the common case of a join
        // on a key, so that neither list regrows in the arena; a cross
        // product knows its size.
        const pairs = if (on.len == 0) self.rows * other.rows else if (hash_other) self.rows else other.rows;
        try left.ensureTotalCapacityPrecise(arena, pairs);
        try right.ensureTotalCapacityPrecise(arena, pairs);
        if (on.len == 0) {
            for (0..self.rows) |i| for (0..other.rows) |j| {
                left.appendAssumeCapacity(@intCast(i));
                right.appendAssumeCapacity(@intCast(j));
            };
        } else if (hash_other) {
            // Rows go in last to first, so the matches of a row come out
            // in `other`'s row order and the result's order is settled.
            const index = try other.indexOn(on_other);
            var i: usize = 0;
            while (i < self.rows) : (i += 1) {
                var r = index.first(self.rowHashOn(on_self, i));
                while (r) |j| : (r = index.after(j)) {
                    if (!self.rowsEqlOn(on_self, i, other, on_other, j)) continue;
                    try left.append(arena, @intCast(i));
                    try right.append(arena, j);
                }
            }
        } else {
            const index = try self.indexOn(on_self);
            var j: usize = 0;
            while (j < other.rows) : (j += 1) {
                var r = index.first(other.rowHashOn(on_other, j));
                while (r) |i| : (r = index.after(i)) {
                    if (!self.rowsEqlOn(on_self, i, other, on_other, j)) continue;
                    try left.append(arena, i);
                    try right.append(arena, @intCast(j));
                }
            }
            try sortPairs(arena, self.rows, left.items, right.items);
        }

        const self_whole = isIdentity(left.items, self.rows);
        const other_whole = isIdentity(right.items, other.rows);
        const cols = try arena.alloc(Column, out_vars.len);
        for (self.cols, cols[0..self.cols.len]) |*c, *o| o.* = if (self_whole) c.* else try c.gather(arena, left.items);
        for (extra, cols[self.cols.len..]) |v, *o| {
            const c = &other.cols[other.colOf(v).?];
            o.* = if (other_whole) c.* else try c.gather(arena, right.items);
        }
        const out: Relation = .{ .arena = arena, .vars = out_vars, .cols = cols, .rows = left.items.len };
        return out.without(drop);
    }

    /// The index over every row hashed on `cols`: the one `indexes`
    /// holds, or a new one it then holds.
    fn indexOn(self: *const Relation, cols: []const usize) !*const RowIndex {
        const kept = self.indexes orelse {
            const index = try self.arena.create(RowIndex);
            index.* = try RowIndex.over(self.arena, self, cols);
            return index;
        };
        for (kept.items) |*h| if (std.mem.eql(usize, h.cols, cols)) return &h.index;
        try kept.append(self.arena, .{ .cols = try self.arena.dupe(usize, cols), .index = try RowIndex.over(self.arena, self, cols) });
        return &kept.items[kept.items.len - 1].index;
    }

    /// Does `idx` name each of rows `0..rows` once, in order?
    fn isIdentity(idx: []const u32, rows: usize) bool {
        if (idx.len != rows) return false;
        for (idx, 0..) |x, i| if (x != i) return false;
        return true;
    }

    /// Order the pairs `(left[k], right[k])` by `left`, keeping the
    /// order of pairs with one `left`: a counting sort over `0..rows`.
    fn sortPairs(arena: Allocator, rows: usize, left: []u32, right: []u32) !void {
        const starts = try arena.alloc(u32, rows + 1);
        @memset(starts, 0);
        for (left) |i| starts[i + 1] += 1;
        for (starts[1..], starts[0..rows]) |*s, prev| s.* += prev;
        const l = try arena.dupe(u32, left);
        const r = try arena.dupe(u32, right);
        for (l, r) |i, j| {
            left[starts[i]] = i;
            right[starts[i]] = j;
            starts[i] += 1;
        }
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

/// A growing set of rows: a relation plus a hash index over it, for
/// accumulating a fixpoint total or an `or`'s branches without
/// rescanning it.
pub const Accumulator = struct {
    rel: Relation,
    set: Relation.RowSet,

    pub fn create(arena: Allocator, vars: []const Var) !*Accumulator {
        const self = try arena.create(Accumulator);
        self.* = .{ .rel = try Relation.init(arena, vars), .set = .{ .rel = &self.rel } };
        return self;
    }

    /// Add row `row` of `src` (whose variables cover `rel.vars`);
    /// false when an equal row was already present.
    pub fn add(self: *Accumulator, src: *const Relation, row: usize, map: []const usize) !bool {
        try self.rel.appendFrom(src, row, map);
        if (try self.set.insert(self.rel.arena, self.rel.rows - 1)) return true;
        try self.rel.dropLast();
        return false;
    }
};

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

test "cells: an integer is int in i64 and a number past it" {
    var heap = @import("../heap.zig").Heap.init(testing.allocator);
    defer heap.deinit();
    const max = try bignum.fromI64(&heap, std.math.maxInt(i64));
    try testing.expect(Cell.fromValue(max).eql(.{ .int = std.math.maxInt(i64) }));
    try testing.expect(Cell.fromValue(try bignum.fromI64(&heap, -(1 << 47) - 1)).eql(.{ .int = -(1 << 47) - 1 }));
    const past = Cell.fromValue(try bignum.fromI128(&heap, @as(i128, std.math.maxInt(i64)) + 1));
    const below = Cell.fromValue(try bignum.fromI128(&heap, @as(i128, std.math.minInt(i64)) - 1));
    try testing.expect(past == .vm and below == .vm);
    var names = Interner.init(testing.allocator);
    defer names.deinit();
    try testing.expect(past.compare(.{ .int = std.math.maxInt(i64) }, &names) == .gt);
    try testing.expect((Cell{ .int = std.math.minInt(i64) }).compare(below, &names) == .gt);
    try testing.expect(below.compare(past, &names) == .lt);
    try testing.expect(past.compare(.{ .double = 1.0e19 }, &names) == .lt);
    try testing.expect(past.compare(.{ .str = "a" }, &names) == null);
    try testing.expect(past.order(.{ .str = "a" }) == .lt);
    try testing.expect(past.order(.{ .boolean = true }) == .gt);
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
    try testing.expect(c.get(0).eql(.{ .int = 1 }));
    try testing.expect(c.get(2).eql(.{ .str = "x" }));
}

test "dedup, project, difference, sort" {
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

    const diff = try r.difference(&s, &.{0});
    try testing.expectEqual(@as(usize, 1), diff.rows);
    try testing.expect(diff.cell(0, 0).eql(.{ .int = 2 }));

    var sorted = try r.dedup();
    try sorted.sort();
    try testing.expect(sorted.cell(0, 0).eql(.{ .int = 1 }) and sorted.cell(0, 1).eql(.{ .str = "a" }));
    try testing.expect(sorted.cell(1, 0).eql(.{ .int = 1 }) and sorted.cell(1, 1).eql(.{ .str = "c" }));
    try testing.expect(sorted.cell(2, 0).eql(.{ .int = 2 }));
    var again = try r.dedup();
    try again.sort();
    try testing.expect(sorted.eqlRows(&again));
}

test "viewAs collapses repeated variables" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src = try rel(arena, &.{ 0, 1, 2 }, &.{
        &.{ .{ .int = 1 }, .{ .int = 1 }, .{ .int = 3 } },
        &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } },
        &.{ .{ .int = 2 }, .{ .int = 2 }, .{ .int = 2 } },
    });
    const same = try Relation.viewAs(arena, &.{ 7, 8, 9 }, &src);
    try testing.expectEqual(@as(usize, 3), same.rows);
    try testing.expectEqualSlices(Var, &.{ 7, 8, 9 }, same.vars);
    const folded = try Relation.viewAs(arena, &.{ 7, 7, 9 }, &src);
    try testing.expectEqual(@as(usize, 2), folded.rows);
    try testing.expectEqualSlices(Var, &.{ 7, 9 }, folded.vars);
    try testing.expect(folded.cell(1, 1).eql(.{ .int = 2 }));
    const all = try Relation.viewAs(arena, &.{ 7, 7, 7 }, &src);
    try testing.expectEqual(@as(usize, 1), all.rows);
}

test "a relation has no column cap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const n = 100;
    var vars: [n]Var = undefined;
    for (&vars, 0..) |*v, i| v.* = @intCast(i);
    var row: [n]Cell = undefined;
    for (&row, 0..) |*c, i| c.* = .{ .int = @intCast(i) };
    var r = try Relation.init(arena, &vars);
    try r.append(&row);
    try r.append(&row);
    const d = try r.dedup();
    try testing.expectEqual(@as(usize, 1), d.rows);
    const none = try rel(arena, vars[0..1], &.{});
    const diff = try d.difference(&none, vars[0..1]);
    try testing.expectEqual(@as(usize, 1), diff.rows);
    const j = try d.join(&d, &.{});
    try testing.expectEqual(@as(usize, 1), j.rows);
    try testing.expectEqual(@as(usize, n), j.cols.len);
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
    var j = try people.join(&ages, &.{});
    try testing.expectEqualSlices(Var, &.{ 0, 1, 2 }, j.vars);
    try testing.expectEqual(@as(usize, 3), j.rows);
    // Rows in `people` order, the matches of a row in `ages` order.
    try testing.expect(j.cell(0, 2).eql(.{ .int = 30 }));
    try testing.expect(j.cell(1, 2).eql(.{ .int = 31 }));
    try testing.expect(j.cell(2, 2).eql(.{ .int = 40 }));
    try j.sort();
    try testing.expect(j.cell(0, 2).eql(.{ .int = 30 }));
    try testing.expect(j.cell(2, 1).eql(.{ .str = "cy" }));

    const flags = try rel(arena, &.{5}, &.{ &.{.{ .boolean = true }}, &.{.{ .boolean = false }} });
    const cross = try people.join(&flags, &.{});
    try testing.expectEqual(@as(usize, 6), cross.rows);

    const unit = try Relation.unit(arena);
    const seeded = try unit.join(&people, &.{});
    try testing.expectEqual(@as(usize, 3), seeded.rows);
    try testing.expectEqualSlices(Var, &.{ 0, 1 }, seeded.vars);
    // Every row of `people` comes out once, in order: its columns are lent.
    try testing.expectEqual(people.cols[1].cell.items.ptr, seeded.cols[1].cell.items.ptr);
}

test "join: either side hashed gives one order; dropped columns are not built" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var small = try Relation.init(arena, &.{ 0, 1 });
    var big = try Relation.init(arena, &.{ 1, 2 });
    for (0..5) |i| try small.append(&.{ .{ .int = @intCast(i) }, .{ .int = @intCast(i % 2) } });
    for (0..40) |i| try big.append(&.{ .{ .int = @intCast(i % 3) }, .{ .int = @intCast(i) } });
    // `small` probes `big`'s index; `big` probes `small`'s: the rows of
    // either come out grouped by the left side's row, matches in order.
    const a = try small.join(&big, &.{});
    const b = try big.join(&small, &.{});
    try testing.expectEqual(a.rows, b.rows);
    var i: usize = 0;
    var last: i64 = -1;
    while (i < a.rows) : (i += 1) {
        const e = a.cell(i, 0).int;
        try testing.expect(e >= last);
        if (e == last) try testing.expect(a.cell(i, 2).int > a.cell(i - 1, 2).int);
        last = e;
    }
    i = 0;
    while (i < b.rows) : (i += 1) {
        if (i > 0) try testing.expect(b.cell(i, 1).int >= b.cell(i - 1, 1).int);
    }
    const narrow = try small.join(&big, &.{1});
    try testing.expectEqualSlices(Var, &.{ 0, 2 }, narrow.vars);
    try testing.expectEqual(a.rows, narrow.rows);
    try testing.expect(narrow.cell(3, 1).eql(a.cell(3, 2)));
    const bare = try narrow.without(&.{0});
    try testing.expectEqualSlices(Var, &.{2}, bare.vars);
    try testing.expectEqual(narrow.cols[1].int.items.ptr, bare.cols[0].int.items.ptr);
}
