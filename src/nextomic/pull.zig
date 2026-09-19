//! pull.zig — Datomic pull patterns over one `Read` (NEXTOMIC.md §6,
//! rows `pull` and `pull-many`).
//!
//! A pattern is a VM value:
//!
//!   pattern = [spec+]
//!   spec    = attr | * | {key sub ...} | (attr opt+) | [attr opt+]
//!   key     = attr | (attr opt+) | [attr opt+]
//!   attr    = :ns/name | :ns/_name        reverse: entities that point
//!                                         at this one through `name`
//!   opt     = :limit n | :limit nil | :default v | :as k
//!   sub     = pattern | ... | depth
//!
//! `(limit attr n)` and `(default attr v)` are accepted as well.
//!
//! Invariants:
//!   - One `Read` serves a whole `pull` or `pullMany` call: the pattern
//!     is resolved against it and every entity is walked in its snapshot.
//!   - `:db/id` is always present; a missing attribute is omitted unless
//!     its spec carries a `:default`.
//!   - Card-many values are vectors in index order, cut at the limit
//!     (1000 unless the spec says otherwise; `:limit nil` is no limit).
//!     Reverse references behave as card-many, except through a
//!     component attribute, whose owner is one entity.
//!   - A ref renders as `{:db/id e}`, plus `:db/ident` when the target
//!     has one, unless the spec names a sub-pattern or the attribute is
//!     a component: a component target is pulled with `[*]`.
//!   - Recursion (`...` or a depth) re-applies the enclosing pattern to
//!     the target; a target already on the recursion path, or past the
//!     depth, renders as a plain ref, so cycles terminate.
//!   - Explicit specs win over `*` for the attributes they name.
//!   - An entity with no datoms in the view pulls as nil.
//!   - Not defined on a history view: `error.HistoryView`.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const dispatch = @import("dispatch");
const key = @import("key.zig");
const db_mod = @import("db.zig");
const schema_mod = @import("schema.zig");
const store_mod = @import("store.zig");
const relation = @import("relation.zig");
const parse_mod = @import("query/parse.zig");
const plan_mod = @import("query/plan.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const DbValue = db_mod.DbValue;
const Read = db_mod.Read;
const Attr = schema_mod.Attr;
const Val = key.Val;
const Cell = relation.Cell;
const boot = store_mod.boot;

pub const Diag = parse_mod.Diag;

pub const Error = error{
    /// Malformed pattern or entity argument; the message is in the `Diag`.
    PullSyntax,
    /// Pull is defined on current, as-of and since views only.
    HistoryView,
};

/// Card-many values are cut here unless the spec says otherwise.
pub const default_limit: u32 = 1000;

// =============================================================================
// Entry points
// =============================================================================

/// Pull `pattern` for the entity `e` (an eid, a lookup ref `[:attr v]`
/// or an ident keyword) in `db`. The result lives in `heap`: a map, or
/// nil when the entity has no datoms in this view.
pub fn pull(gpa: Allocator, interner: *Interner, heap: *Heap, db: DbValue, pattern: Value, e: Value, diag: *Diag) anyerror!Value {
    var run: Run = undefined;
    try run.begin(gpa, interner, heap, db, pattern, diag);
    defer run.deinit();
    return run.one(e);
}

/// Pull `pattern` for every entity of `es`, as a vector in their order.
pub fn pullMany(gpa: Allocator, interner: *Interner, heap: *Heap, db: DbValue, pattern: Value, es: []const Value, diag: *Diag) anyerror!Value {
    var run: Run = undefined;
    try run.begin(gpa, interner, heap, db, pattern, diag);
    defer run.deinit();
    const out = try run.arena().alloc(Value, es.len);
    for (es, out) |e, *v| v.* = try run.one(e);
    return vector_mod.fromSlice(heap, out);
}

/// One call: the arena, the `Read`, the resolved pattern and the
/// puller. Initialised in place, since the arena's allocator and the
/// puller's `Read` pointer refer into it.
const Run = struct {
    arena_state: std.heap.ArenaAllocator,
    read: Read,
    pattern: *const Pattern,
    puller: Puller,

    fn begin(self: *Run, gpa: Allocator, interner: *Interner, heap: *Heap, db: DbValue, pattern: Value, diag: *Diag) anyerror!void {
        if (db.history) return error.HistoryView;
        self.arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer self.arena_state.deinit();
        self.read = try db.beginRead();
        errdefer self.read.close();
        const a = self.arena_state.allocator();
        var parser = try Parser.init(a, &self.read, interner, diag);
        self.pattern = try parser.parsePattern(pattern);
        self.puller = try Puller.init(a, &self.read, heap, interner, diag);
    }

    fn deinit(self: *Run) void {
        self.read.close();
        self.arena_state.deinit();
    }

    fn arena(self: *Run) Allocator {
        return self.arena_state.allocator();
    }

    fn one(self: *Run, e: Value) anyerror!Value {
        const eid = try self.puller.resolveEntity(e);
        return (try self.puller.root(self.pattern, eid)) orelse value.nilValue();
    }
};

// =============================================================================
// Resolved patterns
// =============================================================================

const Sub = union(enum) {
    none,
    pattern: *const Pattern,
    /// Re-apply the enclosing pattern; a null depth is unlimited.
    recurse: ?u32,
};

const Spec = struct {
    attr: Attr,
    reverse: bool,
    /// VM keyword id the value is emitted under.
    key: u32,
    /// Null: no limit.
    limit: ?u32,
    default: ?Value,
    sub: Sub,

    /// Does this spec yield a vector?
    fn many(self: Spec) bool {
        return if (self.reverse) !self.attr.component else self.attr.many();
    }
};

const Pattern = struct {
    wildcard: bool,
    specs: []const Spec,
    /// Remaining depth per spec at entry: the depth of a `.recurse`
    /// spec, null elsewhere.
    budget: []const ?u32,
};

const wildcard_pattern: Pattern = .{ .wildcard = true, .specs = &.{}, .budget = &.{} };

// =============================================================================
// Parser — pattern value to `Pattern`, attributes resolved through the Read
// =============================================================================

const Parser = struct {
    arena: Allocator,
    read: *Read,
    interner: *Interner,
    diag: *Diag,
    /// Index of the top-level spec being parsed, for the `Diag`.
    index: ?usize = null,
    k_limit: u32,
    k_default: u32,
    k_as: u32,
    k_db_id: u32,

    fn init(arena: Allocator, read: *Read, interner: *Interner, diag: *Diag) !Parser {
        return .{
            .arena = arena,
            .read = read,
            .interner = interner,
            .diag = diag,
            .k_limit = try interner.internKeyword("limit"),
            .k_default = try interner.internKeyword("default"),
            .k_as = try interner.internKeyword("as"),
            .k_db_id = try interner.internKeyword("db/id"),
        };
    }

    fn fail(self: *Parser, message: []const u8) error{PullSyntax} {
        self.diag.* = .{ .clause = self.index, .message = message };
        return error.PullSyntax;
    }

    fn elems(self: *Parser, v: Value) ![]Value {
        var out: std.ArrayList(Value) = .empty;
        switch (v.kind()) {
            .persistent_vector => {
                var it = vector_mod.Cursor.init(v);
                while (it.next()) |x| try out.append(self.arena, x);
            },
            .list => {
                var it = list_mod.Cursor.init(v);
                while (it.next()) |x| try out.append(self.arena, x);
            },
            else => return self.fail("pattern must be a vector"),
        }
        return out.toOwnedSlice(self.arena);
    }

    fn isSym(self: *Parser, v: Value, name: []const u8) bool {
        return v.isSymbol() and std.mem.eql(u8, self.interner.symbolName(v.asSymbolId()), name);
    }

    fn parsePattern(self: *Parser, v: Value) anyerror!*Pattern {
        const items = try self.elems(v);
        if (items.len == 0) return self.fail("empty pattern");
        const top = self.index == null;
        var pat = try self.arena.create(Pattern);
        pat.* = .{ .wildcard = false, .specs = &.{}, .budget = &.{} };
        var specs: std.ArrayList(Spec) = .empty;
        for (items, 0..) |item, i| {
            if (top) self.index = i;
            try self.parseSpec(item, pat, &specs);
        }
        if (top) self.index = null;
        pat.specs = try specs.toOwnedSlice(self.arena);
        const budget = try self.arena.alloc(?u32, pat.specs.len);
        for (pat.specs, budget) |s, *b| b.* = if (s.sub == .recurse) s.sub.recurse else null;
        pat.budget = budget;
        return pat;
    }

    fn parseSpec(self: *Parser, v: Value, pat: *Pattern, specs: *std.ArrayList(Spec)) anyerror!void {
        switch (v.kind()) {
            .keyword => {
                if (v.asKeywordId() == self.k_db_id) return;
                try specs.append(self.arena, try self.attrSpec(v.asKeywordId()));
            },
            .symbol => {
                if (!self.isSym(v, "*")) return self.fail("unknown symbol in pattern");
                pat.wildcard = true;
            },
            .string => {
                if (!std.mem.eql(u8, string_mod.asBytes(v), "*")) return self.fail("unknown string in pattern");
                pat.wildcard = true;
            },
            .persistent_map => {
                var it = champ.mapIter(v);
                while (it.next()) |entry| {
                    var spec = try self.parseKey(entry.key);
                    if (spec.attr.value_type != .ref) return self.fail("map specification on a non-ref attribute");
                    spec.sub = try self.parseSub(entry.value);
                    try specs.append(self.arena, spec);
                }
            },
            .list, .persistent_vector => try specs.append(self.arena, try self.parseExpr(v)),
            else => return self.fail("unknown element in pattern"),
        }
    }

    /// A map key: an attribute name or an attribute expression.
    fn parseKey(self: *Parser, v: Value) anyerror!Spec {
        return switch (v.kind()) {
            .keyword => self.attrSpec(v.asKeywordId()),
            .list, .persistent_vector => self.parseExpr(v),
            else => self.fail("map key must be an attribute or an attribute expression"),
        };
    }

    fn parseSub(self: *Parser, v: Value) anyerror!Sub {
        switch (v.kind()) {
            .symbol => {
                if (self.isSym(v, "...")) return .{ .recurse = null };
                return self.fail("map value must be a pattern, ... or a depth");
            },
            .fixnum => {
                const n = v.asFixnum();
                if (n < 0 or n > std.math.maxInt(u32)) return self.fail("recursion depth must be a non-negative integer");
                return .{ .recurse = @intCast(n) };
            },
            .persistent_vector, .list => return .{ .pattern = try self.parsePattern(v) },
            else => return self.fail("map value must be a pattern, ... or a depth"),
        }
    }

    /// `(attr opt+)`, `[attr opt+]`, `(limit attr n)` or `(default attr v)`.
    fn parseExpr(self: *Parser, v: Value) anyerror!Spec {
        const items = try self.elems(v);
        if (items.len == 0) return self.fail("empty attribute expression");
        const head = items[0];
        if (head.isSymbol()) {
            if (items.len != 3 or items[1].kind() != .keyword) return self.fail("expected (limit attr n) or (default attr v)");
            var spec = try self.attrSpec(items[1].asKeywordId());
            if (self.isSym(head, "limit")) {
                spec.limit = try self.limitOf(items[2]);
            } else if (self.isSym(head, "default")) {
                spec.default = items[2];
            } else return self.fail("unknown attribute expression");
            return spec;
        }
        if (head.kind() != .keyword) return self.fail("attribute expression must start with an attribute");
        var spec = try self.attrSpec(head.asKeywordId());
        if ((items.len - 1) % 2 != 0) return self.fail("attribute options come in pairs");
        var i: usize = 1;
        while (i < items.len) : (i += 2) {
            const opt = items[i];
            const arg = items[i + 1];
            if (opt.kind() != .keyword) return self.fail("attribute option must be a keyword");
            const k = opt.asKeywordId();
            if (k == self.k_limit) {
                spec.limit = try self.limitOf(arg);
            } else if (k == self.k_default) {
                spec.default = arg;
            } else if (k == self.k_as) {
                if (arg.kind() != .keyword) return self.fail(":as needs a keyword");
                spec.key = arg.asKeywordId();
            } else return self.fail("unknown attribute option");
        }
        return spec;
    }

    fn limitOf(self: *Parser, v: Value) !?u32 {
        if (v.isNil()) return null;
        if (v.kind() != .fixnum or v.asFixnum() < 0 or v.asFixnum() > std.math.maxInt(u32)) return self.fail(":limit needs a non-negative integer or nil");
        return @intCast(v.asFixnum());
    }

    /// The spec of an attribute name, forward or reverse, with the
    /// default limit and no sub-pattern.
    fn attrSpec(self: *Parser, k: u32) anyerror!Spec {
        const name = self.interner.keywordName(k);
        const slash = std.mem.lastIndexOfScalar(u8, name, '/');
        const local_start = if (slash) |s| s + 1 else 0;
        const reverse = name.len > local_start and name[local_start] == '_';
        const attr_k = if (reverse) blk: {
            const forward = try std.mem.concat(self.arena, u8, &.{ name[0..local_start], name[local_start + 1 ..] });
            break :blk try self.interner.internKeyword(forward);
        } else k;
        const id = (try self.read.db.conn.idents.idOf(self.read.txn, attr_k)) orelse return error.UnknownAttribute;
        const attr = (try self.read.attr(id)) orelse return error.UnknownAttribute;
        if (reverse and attr.value_type != .ref) return self.fail("reverse reference on a non-ref attribute");
        const spec: Spec = .{
            .attr = attr,
            .reverse = reverse,
            .key = k,
            .limit = default_limit,
            .default = null,
            .sub = .none,
        };
        return spec;
    }
};

// =============================================================================
// Puller — walking entities and materialising into the heap
// =============================================================================

const Puller = struct {
    arena: Allocator,
    read: *Read,
    heap: *Heap,
    interner: *Interner,
    diag: *Diag,
    k_db_id: Value,
    k_db_ident: Value,
    /// Entities on the current recursion path, root first.
    path: std.ArrayList(u64) = .empty,

    fn init(arena: Allocator, read: *Read, heap: *Heap, interner: *Interner, diag: *Diag) !Puller {
        return .{
            .arena = arena,
            .read = read,
            .heap = heap,
            .interner = interner,
            .diag = diag,
            .k_db_id = try interner.internKeywordValue("db/id"),
            .k_db_ident = try interner.internKeywordValue("db/ident"),
        };
    }

    fn fail(self: *Puller, message: []const u8) error{PullSyntax} {
        self.diag.* = .{ .message = message };
        return error.PullSyntax;
    }

    /// The eid of an entity argument: an eid, a lookup ref or an ident.
    fn resolveEntity(self: *Puller, e: Value) anyerror!u64 {
        switch (e.kind()) {
            .fixnum => {
                const n = e.asFixnum();
                if (n <= 0 or n > key.id_max) return error.NoEntity;
                return @intCast(n);
            },
            .keyword => return (try self.read.entid(self.arena, .{ .ident = e.asKeywordId() })) orelse error.NoEntity,
            .persistent_vector => {
                if (vector_mod.count(e) != 2 or vector_mod.nth(e, 0).kind() != .keyword) return self.fail("lookup ref must be [attr value]");
                const k = vector_mod.nth(e, 0).asKeywordId();
                const id = (try self.read.db.conn.idents.idOf(self.read.txn, k)) orelse return error.UnknownAttribute;
                const attr = (try self.read.attr(id)) orelse return error.UnknownAttribute;
                const v = (try plan_mod.encodeCell(self.read, Cell.fromValue(vector_mod.nth(e, 1)), attr.value_type)) orelse return error.ValueType;
                return (try self.read.entid(self.arena, .{ .lookup = .{ .a = id, .v = v } })) orelse error.NoEntity;
            },
            else => return self.fail("entity must be an eid, a lookup ref or an ident"),
        }
    }

    fn root(self: *Puller, pat: *const Pattern, e: u64) anyerror!?Value {
        self.path.clearRetainingCapacity();
        try self.path.append(self.arena, e);
        return self.entity(pat, e, pat.budget);
    }

    fn onPath(self: *const Puller, e: u64) bool {
        return std.mem.indexOfScalar(u64, self.path.items, e) != null;
    }

    fn assoc(self: *Puller, m: Value, k: Value, v: Value) !Value {
        return champ.mapAssoc(self.heap, m, k, v, &dispatch.hashValue, &dispatch.equal);
    }

    fn eidValue(e: u64) !Value {
        return value.fromFixnum(@intCast(e)) orelse error.ValueType;
    }

    /// `{:db/id e}` with `:db/ident` when the entity has one; idents
    /// live in the attribute partition, so only those ids are probed.
    fn refMap(self: *Puller, e: u64) anyerror!Value {
        var m = try champ.mapEmpty(self.heap);
        m = try self.assoc(m, self.k_db_id, try eidValue(e));
        if (key.isAttrPartition(e)) {
            if (try self.read.ident(self.arena, e)) |k| m = try self.assoc(m, self.k_db_ident, value.fromKeywordId(k));
        }
        return m;
    }

    /// The pattern applied to `e`: null when the entity has no datoms
    /// in this view. `budget` is the remaining depth per spec.
    fn entity(self: *Puller, pat: *const Pattern, e: u64, budget: []const ?u32) anyerror!?Value {
        var m = try champ.mapEmpty(self.heap);
        m = try self.assoc(m, self.k_db_id, try eidValue(e));
        var any = false;
        var covered: std.AutoHashMapUnmanaged(u32, void) = .empty;

        for (pat.specs, 0..) |*s, i| {
            const k = value.fromKeywordId(s.key);
            if (try self.specValue(pat, s, i, e, budget)) |v| {
                m = try self.assoc(m, k, v);
                any = true;
            } else if (s.default) |d| {
                m = try self.assoc(m, k, d);
            }
            if (pat.wildcard and !s.reverse) try covered.put(self.arena, s.attr.id, {});
        }

        if (!pat.wildcard) {
            if (any) return m;
            // Only whether the entity exists at all.
            var probe = try self.read.scan(self.arena, .eavt, .{ .e = e });
            return if ((try probe.next()) == null) null else m;
        }
        var it = try self.read.scan(self.arena, .eavt, .{ .e = e });
        var vals: std.ArrayList(Val) = .empty;
        var cur: ?u32 = null;
        while (try it.next()) |d| {
            any = true;
            if (cur != null and cur.? != d.a) {
                m = try self.wildAttr(m, cur.?, vals.items, &covered);
                vals.clearRetainingCapacity();
            }
            cur = d.a;
            try vals.append(self.arena, d.v);
        }
        if (cur) |a| m = try self.wildAttr(m, a, vals.items, &covered);
        return if (any) m else null;
    }

    /// One attribute of a `*` pull, as a bare spec.
    fn wildAttr(self: *Puller, m: Value, a: u32, vals: []const Val, covered: *const std.AutoHashMapUnmanaged(u32, void)) anyerror!Value {
        if (covered.contains(a)) return m;
        const attr = (try self.read.attr(a)) orelse return error.Corrupted;
        const k = (try self.read.db.conn.idents.internOf(self.read.txn, a)) orelse return error.Corrupted;
        const spec: Spec = .{ .attr = attr, .reverse = false, .key = k, .limit = default_limit, .default = null, .sub = .none };
        const cut = if (spec.many()) @min(vals.len, default_limit) else 1;
        const v = try self.render(&wildcard_pattern, &spec, 0, &.{}, vals[0..cut]);
        return self.assoc(m, value.fromKeywordId(k), v);
    }

    /// The value of spec `i` of `pat` on `e`, or null when absent.
    fn specValue(self: *Puller, pat: *const Pattern, s: *const Spec, i: usize, e: u64, budget: []const ?u32) anyerror!?Value {
        var vals: std.ArrayList(Val) = .empty;
        const cap: usize = if (s.many()) (s.limit orelse std.math.maxInt(u32)) else 1;
        if (cap == 0) return null;
        if (s.reverse) {
            const vb = try key.valBytes(self.arena, .{ .ref = e });
            var it = try self.read.scan(self.arena, .vaet, .{ .v = vb, .a = s.attr.id });
            while (try it.next()) |d| {
                try vals.append(self.arena, .{ .ref = d.e });
                if (vals.items.len >= cap) break;
            }
        } else {
            var it = try self.read.scan(self.arena, .eavt, .{ .e = e, .a = s.attr.id });
            while (try it.next()) |d| {
                try vals.append(self.arena, d.v);
                if (vals.items.len >= cap) break;
            }
        }
        if (vals.items.len == 0) return null;
        return try self.render(pat, s, i, budget, vals.items);
    }

    /// One value, or a vector of them, for a spec.
    fn render(self: *Puller, pat: *const Pattern, s: *const Spec, i: usize, budget: []const ?u32, vals: []const Val) anyerror!Value {
        if (!s.many()) return self.renderVal(pat, s, i, budget, vals[0]);
        const out = try self.arena.alloc(Value, vals.len);
        for (vals, out) |v, *o| o.* = try self.renderVal(pat, s, i, budget, v);
        return vector_mod.fromSlice(self.heap, out);
    }

    fn renderVal(self: *Puller, pat: *const Pattern, s: *const Spec, i: usize, budget: []const ?u32, v: Val) anyerror!Value {
        if (v == .ref) return self.renderRef(pat, s, i, budget, v.ref);
        return self.read.db.conn.valToValue(self.read.txn, self.heap, v);
    }

    /// A referenced entity: pulled with the spec's sub-pattern, the
    /// enclosing pattern on recursion, `[*]` for a component, else a
    /// plain ref. Anything on the path or past the depth is a plain ref.
    fn renderRef(self: *Puller, pat: *const Pattern, s: *const Spec, i: usize, budget: []const ?u32, target: u64) anyerror!Value {
        switch (s.sub) {
            .pattern => |p| return self.nested(p, target, p.budget),
            .recurse => {
                if (budget[i]) |remaining| {
                    if (remaining == 0) return self.refMap(target);
                    const next = try self.arena.dupe(?u32, budget);
                    next[i] = remaining - 1;
                    return self.nested(pat, target, next);
                }
                return self.nested(pat, target, budget);
            },
            .none => {
                if (s.attr.component) return self.nested(&wildcard_pattern, target, &.{});
                return self.refMap(target);
            },
        }
    }

    fn nested(self: *Puller, pat: *const Pattern, target: u64, budget: []const ?u32) anyerror!Value {
        if (self.onPath(target)) return self.refMap(target);
        try self.path.append(self.arena, target);
        defer _ = self.path.pop();
        return (try self.entity(pat, target, budget)) orelse self.refMap(target);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const transact_mod = @import("transact.zig");
const TestConn = db_mod.TestConn;
const Op = transact_mod.Op;

/// A connection with a heap and value builders for patterns.
const Fx = struct {
    tc: *TestConn,
    heap: Heap,
    arena_state: std.heap.ArenaAllocator,
    diag: Diag = .{},

    fn init(name: []const u8) !*Fx {
        const self = try testing.allocator.create(Fx);
        self.* = .{
            .tc = try TestConn.init(name),
            .heap = Heap.init(testing.allocator),
            .arena_state = std.heap.ArenaAllocator.init(testing.allocator),
        };
        return self;
    }

    fn deinit(self: *Fx) void {
        self.arena_state.deinit();
        self.heap.deinit();
        self.tc.deinit();
        testing.allocator.destroy(self);
    }

    fn arena(self: *Fx) Allocator {
        return self.arena_state.allocator();
    }

    fn kw(self: *Fx, name: []const u8) !Value {
        return self.tc.interner.internKeywordValue(name);
    }

    fn kwId(self: *Fx, name: []const u8) !u32 {
        return self.tc.interner.internKeyword(name);
    }

    fn sym(self: *Fx, name: []const u8) !Value {
        return self.tc.interner.internSymbolValue(name);
    }

    fn str(self: *Fx, s: []const u8) !Value {
        return string_mod.fromBytes(&self.heap, s);
    }

    fn int(n: i64) Value {
        return value.fromFixnum(n).?;
    }

    fn vec(self: *Fx, items: []const Value) !Value {
        return vector_mod.fromSlice(&self.heap, items);
    }

    fn lst(self: *Fx, items: []const Value) !Value {
        return list_mod.fromSlice(&self.heap, items);
    }

    /// A map from alternating keys and values.
    fn map(self: *Fx, kvs: []const Value) !Value {
        var m = try champ.mapEmpty(&self.heap);
        var i: usize = 0;
        while (i < kvs.len) : (i += 2) m = try champ.mapAssoc(&self.heap, m, kvs[i], kvs[i + 1], &dispatch.hashValue, &dispatch.equal);
        return m;
    }

    fn get(m: Value, k: Value) ?Value {
        return switch (champ.mapGet(m, k, &dispatch.hashValue, &dispatch.equal)) {
            .present => |v| v,
            .absent => null,
        };
    }

    fn getName(self: *Fx, m: Value, name: []const u8) !?Value {
        return get(m, try self.kw(name));
    }

    fn db(self: *Fx) !DbValue {
        return self.tc.conn.db();
    }

    fn pullOne(self: *Fx, dbv: DbValue, pattern: Value, e: Value) anyerror!Value {
        return pull(testing.allocator, &self.tc.interner, &self.heap, dbv, pattern, e, &self.diag);
    }

    fn attrId(self: *Fx, name: []const u8) !u32 {
        const txn = try self.tc.conn.store.beginRead();
        defer txn.abort();
        return (try self.tc.conn.idents.idOfName(txn, name)).?;
    }
};

fn attrOps(fx: *Fx, tempid: []const u8, name: []const u8, vt: u32, many: bool, extra: []const Op) ![]Op {
    var out: std.ArrayList(Op) = .empty;
    const t: transact_mod.Entity = .{ .tempid = .{ .string = tempid } };
    try out.append(fx.arena(), .{ .add = .{ .e = t, .a = .{ .id = boot.ident }, .v = .{ .keyword = try fx.kwId(name) } } });
    try out.append(fx.arena(), .{ .add = .{ .e = t, .a = .{ .id = boot.value_type }, .v = .{ .val = .{ .keyword = vt } } } });
    try out.append(fx.arena(), .{ .add = .{ .e = t, .a = .{ .id = boot.cardinality }, .v = .{ .val = .{ .keyword = if (many) boot.card_many else boot.card_one } } } });
    try out.appendSlice(fx.arena(), extra);
    return out.toOwnedSlice(fx.arena());
}

/// `:p/name` string, `:p/email` string unique identity, `:p/tags`
/// keyword many, `:p/friend` ref many, `:p/boss` ref, `:p/home` ref
/// component, `:addr/city` string, `:role/admin` ident.
fn installSchema(fx: *Fx) !void {
    var ops: std.ArrayList(Op) = .empty;
    const a = fx.arena();
    try ops.appendSlice(a, try attrOps(fx, "name", "p/name", boot.type_string, false, &.{}));
    try ops.appendSlice(a, try attrOps(fx, "email", "p/email", boot.type_string, false, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "email" } }, .a = .{ .id = boot.unique }, .v = .{ .val = .{ .keyword = boot.unique_identity } } } },
    }));
    try ops.appendSlice(a, try attrOps(fx, "tags", "p/tags", boot.type_keyword, true, &.{}));
    try ops.appendSlice(a, try attrOps(fx, "friend", "p/friend", boot.type_ref, true, &.{}));
    try ops.appendSlice(a, try attrOps(fx, "boss", "p/boss", boot.type_ref, false, &.{}));
    try ops.appendSlice(a, try attrOps(fx, "home", "p/home", boot.type_ref, false, &.{
        .{ .add = .{ .e = .{ .tempid = .{ .string = "home" } }, .a = .{ .id = boot.is_component }, .v = .{ .val = .{ .boolean = true } } } },
    }));
    try ops.appendSlice(a, try attrOps(fx, "city", "addr/city", boot.type_string, false, &.{}));
    try ops.append(a, .{ .add = .{ .e = .{ .tempid = .{ .string = "admin" } }, .a = .{ .id = boot.ident }, .v = .{ .keyword = try fx.kwId("role/admin") } } });
    _ = try transact_mod.transactOps(fx.tc.conn, a, ops.items, .{});
}

/// ann -friend-> bob, cy; bob -friend-> ann (cycle); bob -boss-> ann;
/// ann -home-> h (city Oslo); ann tags red, blue.
const People = struct { ann: u64, bob: u64, cy: u64, home: u64 };

fn loadPeople(fx: *Fx) !People {
    const a = fx.arena();
    const name = try fx.attrId("p/name");
    const email = try fx.attrId("p/email");
    const tags = try fx.attrId("p/tags");
    const friend = try fx.attrId("p/friend");
    const boss = try fx.attrId("p/boss");
    const home = try fx.attrId("p/home");
    const city = try fx.attrId("addr/city");
    const T = struct {
        fn t(s: []const u8) transact_mod.Entity {
            return .{ .tempid = .{ .string = s } };
        }
    };
    const r = try transact_mod.transactOps(fx.tc.conn, a, &.{
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = name }, .v = .{ .val = .{ .string = "Ann" } } } },
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = email }, .v = .{ .val = .{ .string = "ann@x" } } } },
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = tags }, .v = .{ .keyword = try fx.kwId("red") } } },
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = tags }, .v = .{ .keyword = try fx.kwId("blue") } } },
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = friend }, .v = .{ .entity = T.t("bob") } } },
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = friend }, .v = .{ .entity = T.t("cy") } } },
        .{ .add = .{ .e = T.t("ann"), .a = .{ .id = home }, .v = .{ .entity = T.t("h") } } },
        .{ .add = .{ .e = T.t("h"), .a = .{ .id = city }, .v = .{ .val = .{ .string = "Oslo" } } } },
        .{ .add = .{ .e = T.t("bob"), .a = .{ .id = name }, .v = .{ .val = .{ .string = "Bob" } } } },
        .{ .add = .{ .e = T.t("bob"), .a = .{ .id = email }, .v = .{ .val = .{ .string = "bob@x" } } } },
        .{ .add = .{ .e = T.t("bob"), .a = .{ .id = friend }, .v = .{ .entity = T.t("ann") } } },
        .{ .add = .{ .e = T.t("bob"), .a = .{ .id = boss }, .v = .{ .entity = T.t("ann") } } },
        .{ .add = .{ .e = T.t("cy"), .a = .{ .id = name }, .v = .{ .val = .{ .string = "Cy" } } } },
    }, .{});
    return .{ .ann = r.tempids[0].eid, .bob = r.tempids[1].eid, .cy = r.tempids[2].eid, .home = r.tempids[3].eid };
}

test "wildcard, attribute lists, refs, components, card-many vectors" {
    const fx = try Fx.init("pull_basic");
    defer fx.deinit();
    try installSchema(fx);
    const p = try loadPeople(fx);
    const dbv = try fx.db();

    // [*]: every attribute; home is a component and is pulled through.
    const all = try fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), Fx.int(@intCast(p.ann)));
    try testing.expectEqual(@as(usize, 6), champ.mapCount(all));
    try testing.expectEqual(@as(i64, @intCast(p.ann)), (try fx.getName(all, "db/id")).?.asFixnum());
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(all, "p/name")).?));
    const tags = (try fx.getName(all, "p/tags")).?;
    try testing.expectEqual(value.Kind.persistent_vector, tags.kind());
    try testing.expectEqual(@as(usize, 2), vector_mod.count(tags));
    try testing.expect(vector_mod.nth(tags, 0).kind() == .keyword);
    const friends = (try fx.getName(all, "p/friend")).?;
    try testing.expectEqual(@as(usize, 2), vector_mod.count(friends));
    try testing.expectEqual(@as(usize, 1), champ.mapCount(vector_mod.nth(friends, 0)));
    try testing.expectEqual(@as(i64, @intCast(p.bob)), (try fx.getName(vector_mod.nth(friends, 0), "db/id")).?.asFixnum());
    const home = (try fx.getName(all, "p/home")).?;
    try testing.expectEqualStrings("Oslo", string_mod.asBytes((try fx.getName(home, "addr/city")).?));

    // An attribute list: only what is named, missing attributes omitted.
    const some = try fx.pullOne(dbv, try fx.vec(&.{ try fx.kw("p/name"), try fx.kw("p/boss"), try fx.kw("db/id") }), Fx.int(@intCast(p.ann)));
    try testing.expectEqual(@as(usize, 2), champ.mapCount(some));
    try testing.expect((try fx.getName(some, "p/boss")) == null);
    const bobs = try fx.pullOne(dbv, try fx.vec(&.{try fx.kw("p/boss")}), Fx.int(@intCast(p.bob)));
    try testing.expectEqual(@as(i64, @intCast(p.ann)), (try fx.getName((try fx.getName(bobs, "p/boss")).?, "db/id")).?.asFixnum());

    // A bare component name pulls the component with [*].
    const h = try fx.pullOne(dbv, try fx.vec(&.{try fx.kw("p/home")}), Fx.int(@intCast(p.ann)));
    try testing.expectEqualStrings("Oslo", string_mod.asBytes((try fx.getName((try fx.getName(h, "p/home")).?, "addr/city")).?));

    // Lookup ref and ident entity arguments; a ref to an ident carries :db/ident.
    const by_email = try fx.pullOne(dbv, try fx.vec(&.{try fx.kw("p/name")}), try fx.vec(&.{ try fx.kw("p/email"), try fx.str("bob@x") }));
    try testing.expectEqualStrings("Bob", string_mod.asBytes((try fx.getName(by_email, "p/name")).?));
    const ident_e = try fx.pullOne(dbv, try fx.vec(&.{try fx.kw("db/ident")}), try fx.kw("role/admin"));
    try testing.expect((try fx.getName(ident_e, "db/ident")).?.kind() == .keyword);
    const attr_e = try fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), Fx.int(boot.ident));
    try testing.expectEqual(@as(usize, 6), champ.mapCount(attr_e));

    // An entity with no datoms is nil; unknown things are errors.
    try testing.expect((try fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), Fx.int(1 << 40))).isNil());
    try testing.expectError(error.NoEntity, fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), try fx.vec(&.{ try fx.kw("p/email"), try fx.str("zed@x") })));
    try testing.expectError(error.NoEntity, fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), try fx.kw("role/none")));
    try testing.expectError(error.UnknownAttribute, fx.pullOne(dbv, try fx.vec(&.{try fx.kw("p/nope")}), Fx.int(@intCast(p.ann))));
    try testing.expectError(error.HistoryView, fx.pullOne(dbv.withHistory(), try fx.vec(&.{try fx.sym("*")}), Fx.int(@intCast(p.ann))));
}

test "nested patterns, reverse refs, recursion with cycles, depth" {
    const fx = try Fx.init("pull_nested");
    defer fx.deinit();
    try installSchema(fx);
    const p = try loadPeople(fx);
    const dbv = try fx.db();

    // {:p/friend [:p/name]}
    const nested = try fx.pullOne(dbv, try fx.vec(&.{try fx.map(&.{ try fx.kw("p/friend"), try fx.vec(&.{try fx.kw("p/name")}) })}), Fx.int(@intCast(p.ann)));
    const fr = (try fx.getName(nested, "p/friend")).?;
    try testing.expectEqual(@as(usize, 2), vector_mod.count(fr));
    try testing.expectEqualStrings("Bob", string_mod.asBytes((try fx.getName(vector_mod.nth(fr, 0), "p/name")).?));
    try testing.expectEqual(@as(usize, 2), champ.mapCount(vector_mod.nth(fr, 0)));

    // Reverse: who has ann as a friend / as a boss; who owns the home.
    const rev = try fx.pullOne(dbv, try fx.vec(&.{ try fx.kw("p/_friend"), try fx.kw("p/_boss"), try fx.kw("p/_home") }), Fx.int(@intCast(p.ann)));
    const rf = (try fx.getName(rev, "p/_friend")).?;
    try testing.expectEqual(@as(usize, 1), vector_mod.count(rf));
    try testing.expectEqual(@as(i64, @intCast(p.bob)), (try fx.getName(vector_mod.nth(rf, 0), "db/id")).?.asFixnum());
    try testing.expectEqual(@as(usize, 1), vector_mod.count((try fx.getName(rev, "p/_boss")).?));
    try testing.expect((try fx.getName(rev, "p/_home")) == null);
    const owner = try fx.pullOne(dbv, try fx.vec(&.{try fx.map(&.{ try fx.kw("p/_home"), try fx.vec(&.{try fx.kw("p/name")}) })}), Fx.int(@intCast(p.home)));
    const ow = (try fx.getName(owner, "p/_home")).?;
    try testing.expectEqual(value.Kind.persistent_map, ow.kind());
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(ow, "p/name")).?));

    // {:p/friend ...}: ann -> bob -> ann stops at the cycle; cy has no friends.
    const rec = try fx.pullOne(dbv, try fx.vec(&.{ try fx.kw("p/name"), try fx.map(&.{ try fx.kw("p/friend"), try fx.sym("...") }) }), Fx.int(@intCast(p.ann)));
    const l1 = (try fx.getName(rec, "p/friend")).?;
    const bob = vector_mod.nth(l1, 0);
    try testing.expectEqualStrings("Bob", string_mod.asBytes((try fx.getName(bob, "p/name")).?));
    const l2 = (try fx.getName(bob, "p/friend")).?;
    const ann_again = vector_mod.nth(l2, 0);
    try testing.expectEqual(@as(usize, 1), champ.mapCount(ann_again));
    try testing.expectEqual(@as(i64, @intCast(p.ann)), (try fx.getName(ann_again, "db/id")).?.asFixnum());
    const cy = vector_mod.nth(l1, 1);
    try testing.expect((try fx.getName(cy, "p/friend")) == null);

    // Depth 1: bob is pulled with the pattern, his friends are plain refs.
    const d1 = try fx.pullOne(dbv, try fx.vec(&.{ try fx.kw("p/name"), try fx.map(&.{ try fx.kw("p/friend"), Fx.int(1) }) }), Fx.int(@intCast(p.bob)));
    const ann1 = vector_mod.nth((try fx.getName(d1, "p/friend")).?, 0);
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(ann1, "p/name")).?));
    const bob0 = vector_mod.nth((try fx.getName(ann1, "p/friend")).?, 0);
    try testing.expectEqual(@as(usize, 1), champ.mapCount(bob0));
    // Depth 0 is a plain ref.
    const d0 = try fx.pullOne(dbv, try fx.vec(&.{try fx.map(&.{ try fx.kw("p/friend"), Fx.int(0) })}), Fx.int(@intCast(p.bob)));
    try testing.expectEqual(@as(usize, 1), champ.mapCount(vector_mod.nth((try fx.getName(d0, "p/friend")).?, 0)));

    // A map spec beside * overrides the wildcard for that attribute.
    const mixed = try fx.pullOne(dbv, try fx.vec(&.{ try fx.sym("*"), try fx.map(&.{ try fx.kw("p/friend"), try fx.vec(&.{try fx.kw("p/name")}) }) }), Fx.int(@intCast(p.ann)));
    try testing.expectEqual(@as(usize, 6), champ.mapCount(mixed));
    try testing.expectEqualStrings("Bob", string_mod.asBytes((try fx.getName(vector_mod.nth((try fx.getName(mixed, "p/friend")).?, 0), "p/name")).?));
}

test "limit, default, as, expression forms, pull-many, syntax diagnostics" {
    const fx = try Fx.init("pull_opts");
    defer fx.deinit();
    try installSchema(fx);
    const p = try loadPeople(fx);
    const dbv = try fx.db();
    const ann = Fx.int(@intCast(p.ann));

    // (:p/tags :limit 1), [:p/friend :limit 1 :as :pals], (limit :p/tags 1), (:p/boss :default :nobody), (default :p/boss 0).
    const opts = try fx.vec(&.{
        try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("limit"), Fx.int(1) }),
        try fx.vec(&.{ try fx.kw("p/friend"), try fx.kw("limit"), Fx.int(1), try fx.kw("as"), try fx.kw("pals") }),
        try fx.lst(&.{ try fx.kw("p/boss"), try fx.kw("default"), try fx.kw("nobody") }),
        try fx.lst(&.{ try fx.sym("default"), try fx.kw("p/name"), try fx.str("anon") }),
    });
    const r = try fx.pullOne(dbv, opts, ann);
    try testing.expectEqual(@as(usize, 1), vector_mod.count((try fx.getName(r, "p/tags")).?));
    try testing.expectEqual(@as(usize, 1), vector_mod.count((try fx.getName(r, "pals")).?));
    try testing.expect((try fx.getName(r, "p/friend")) == null);
    try testing.expect((try fx.getName(r, "p/boss")).?.kind() == .keyword);
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(r, "p/name")).?));
    const lim = try fx.pullOne(dbv, try fx.vec(&.{try fx.lst(&.{ try fx.sym("limit"), try fx.kw("p/tags"), Fx.int(1) })}), ann);
    try testing.expectEqual(@as(usize, 1), vector_mod.count((try fx.getName(lim, "p/tags")).?));
    // :limit nil is no limit; :limit 0 omits the attribute.
    const nolim = try fx.pullOne(dbv, try fx.vec(&.{try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("limit"), value.nilValue() })}), ann);
    try testing.expectEqual(@as(usize, 2), vector_mod.count((try fx.getName(nolim, "p/tags")).?));
    const zero = try fx.pullOne(dbv, try fx.vec(&.{try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("limit"), Fx.int(0) })}), ann);
    try testing.expect((try fx.getName(zero, "p/tags")) == null);
    // A limit on a map spec key.
    const lm = try fx.pullOne(dbv, try fx.vec(&.{try fx.map(&.{ try fx.lst(&.{ try fx.kw("p/friend"), try fx.kw("limit"), Fx.int(1) }), try fx.vec(&.{try fx.kw("p/name")}) })}), ann);
    try testing.expectEqual(@as(usize, 1), vector_mod.count((try fx.getName(lm, "p/friend")).?));

    // pull-many keeps order and yields nil for an entity with no datoms.
    const many = try pullMany(testing.allocator, &fx.tc.interner, &fx.heap, dbv, try fx.vec(&.{try fx.kw("p/name")}), &.{ Fx.int(@intCast(p.cy)), Fx.int(1 << 40), ann }, &fx.diag);
    try testing.expectEqual(@as(usize, 3), vector_mod.count(many));
    try testing.expectEqualStrings("Cy", string_mod.asBytes((try fx.getName(vector_mod.nth(many, 0), "p/name")).?));
    try testing.expect(vector_mod.nth(many, 1).isNil());
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(vector_mod.nth(many, 2), "p/name")).?));

    // Diagnostics carry the top-level spec index.
    const Bad = struct { pattern: Value, message: []const u8, clause: ?usize };
    const bad = [_]Bad{
        .{ .pattern = try fx.str("x"), .message = "pattern must be a vector", .clause = null },
        .{ .pattern = try fx.vec(&.{}), .message = "empty pattern", .clause = null },
        .{ .pattern = try fx.vec(&.{ try fx.kw("p/name"), Fx.int(3) }), .message = "unknown element in pattern", .clause = 1 },
        .{ .pattern = try fx.vec(&.{try fx.sym("?x")}), .message = "unknown symbol in pattern", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.map(&.{ try fx.kw("p/name"), try fx.vec(&.{try fx.kw("p/name")}) })}), .message = "map specification on a non-ref attribute", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.map(&.{ try fx.kw("p/friend"), try fx.str("no") })}), .message = "map value must be a pattern, ... or a depth", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.map(&.{ try fx.kw("p/friend"), Fx.int(-1) })}), .message = "recursion depth must be a non-negative integer", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.kw("p/_name")}), .message = "reverse reference on a non-ref attribute", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("limit") })}), .message = "attribute options come in pairs", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("limit"), try fx.str("x") })}), .message = ":limit needs a non-negative integer or nil", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("as"), Fx.int(1) })}), .message = ":as needs a keyword", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.lst(&.{ try fx.kw("p/tags"), try fx.kw("zap"), Fx.int(1) })}), .message = "unknown attribute option", .clause = 0 },
        .{ .pattern = try fx.vec(&.{ try fx.kw("p/name"), try fx.lst(&.{ try fx.sym("zap"), try fx.kw("p/tags"), Fx.int(1) }) }), .message = "unknown attribute expression", .clause = 1 },
        .{ .pattern = try fx.vec(&.{try fx.lst(&.{})}), .message = "empty attribute expression", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.lst(&.{Fx.int(1)})}), .message = "attribute expression must start with an attribute", .clause = 0 },
        .{ .pattern = try fx.vec(&.{try fx.map(&.{ Fx.int(1), try fx.vec(&.{try fx.kw("p/name")}) })}), .message = "map key must be an attribute or an attribute expression", .clause = 0 },
    };
    for (bad) |b| {
        fx.diag = .{};
        try testing.expectError(error.PullSyntax, fx.pullOne(dbv, b.pattern, ann));
        try testing.expectEqualStrings(b.message, fx.diag.message);
        try testing.expectEqual(b.clause, fx.diag.clause);
    }
    try testing.expectError(error.PullSyntax, fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), try fx.str("ann")));
    try testing.expectEqualStrings("entity must be an eid, a lookup ref or an ident", fx.diag.message);
    try testing.expectError(error.PullSyntax, fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), try fx.vec(&.{try fx.kw("p/email")})));
    try testing.expectError(error.ValueType, fx.pullOne(dbv, try fx.vec(&.{try fx.sym("*")}), try fx.vec(&.{ try fx.kw("p/email"), Fx.int(1) })));
}

test "as-of and since views" {
    const fx = try Fx.init("pull_views");
    defer fx.deinit();
    try installSchema(fx);
    const p = try loadPeople(fx);
    const name = try fx.attrId("p/name");
    const r = try transact_mod.transactOps(fx.tc.conn, fx.arena(), &.{
        .{ .add = .{ .e = .{ .eid = p.ann }, .a = .{ .id = name }, .v = .{ .val = .{ .string = "Anne" } } } },
    }, .{});
    const dbv = try fx.db();
    const pat = try fx.vec(&.{try fx.kw("p/name")});
    const ann = Fx.int(@intCast(p.ann));
    try testing.expectEqualStrings("Anne", string_mod.asBytes((try fx.getName(try fx.pullOne(dbv, pat, ann), "p/name")).?));
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(try fx.pullOne(dbv.asOf(r.t - 1), pat, ann), "p/name")).?));
    // At the schema's basis the entity is absent; before it the attribute is unknown.
    try testing.expect((try fx.pullOne(dbv.asOf(2), pat, ann)).isNil());
    try testing.expectError(error.UnknownAttribute, fx.pullOne(dbv.asOf(1), pat, ann));
    // since: only the rename is visible; the entity has one datom.
    const since = try fx.pullOne(dbv.sinceT(r.t - 1), try fx.vec(&.{try fx.sym("*")}), ann);
    try testing.expectEqual(@as(usize, 2), champ.mapCount(since));
    try testing.expectEqualStrings("Anne", string_mod.asBytes((try fx.getName(since, "p/name")).?));
    // A db taken before the rename still answers the old name through the fold.
    const old = DbValue{ .conn = fx.tc.conn, .basis = r.t - 1 };
    try testing.expectEqualStrings("Ann", string_mod.asBytes((try fx.getName(try fx.pullOne(old, pat, ann), "p/name")).?));
}
