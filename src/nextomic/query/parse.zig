//! query/parse.zig — query value to IR (NEXTOMIC.md §5 "Parse").
//!
//! Accepts the vector form `[:find ... :keys ... :in ... :with ...
//! :where ...]` and the map form `{:find [...] :keys [...] :in [...]
//! :with [...] :where [...]}` (`:strs` and `:syms` in place of `:keys`).
//! Every syntax error is `error.QuerySyntax` with the clause index and
//! a message left in the caller's `Diag`. Invariants:
//!   - The IR is pure syntax (see `ir.zig`); nothing here touches a
//!     store, so a parsed query is reusable across dbs and bases.
//!   - Every `find` and `with` variable is bound by `in` or `where`.
//!   - `in` variables are unique; `$` is the first source when declared,
//!     and every source and `%` appear at most once; a `$name` in a
//!     clause is declared in `in`, and a rule body reads `$` only. `in`
//!     may declare no source at all: the query then runs over its
//!     inputs alone.
//!   - `or` branches bind the same variables; `not` mentions at least
//!     one variable.
//!   - A `?variable` in function position is a `FnRef.variable`; it is
//!     an input of the clause, never something the clause binds.
//!   - Rules with one name share one arity and one required count, and
//!     every call to a rule inside a rule body passes that many
//!     arguments.
//!
//! `Cache` memoises parses per query value: by identity first (the
//! query literal's pointer), then by structural hash and an equality
//! that tells lists from vectors. It keeps at most `cache_capacity`
//! parses that no query is running on, and `mark` keeps every query
//! value it holds reachable, so no address it compares by is reused
//! while it is there.

const std = @import("std");
const value = @import("../../value.zig");
const intern_mod = @import("../../intern.zig");
const string_mod = @import("../../string.zig");
const list_mod = @import("../../coll/list.zig");
const vector_mod = @import("../../coll/vector.zig");
const champ = @import("../../coll/champ.zig");
const dispatch = @import("../../dispatch.zig");
const stack = @import("../../stack.zig");
const gc = @import("../../gc.zig");
const marshal = @import("../marshal.zig");
const ir = @import("ir.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;
const Interner = intern_mod.Interner;
const Var = ir.Var;
const Cell = ir.Cell;
const Clause = ir.Clause;
const Ir = ir.Ir;
const RuleSet = ir.RuleSet;

pub const Error = error{ QuerySyntax, OutOfMemory, StackOverflow };

/// Where a syntax error was found. `clause` is the index into `:where`
/// (or into the rule vector for rule parsing) when the error is inside
/// a clause.
pub const Diag = struct {
    clause: ?usize = null,
    message: []const u8 = "",
    /// The attribute an `UnknownAttribute` names, as the query wrote it.
    attr: ?Value = null,
    /// Backing store of a formatted message, so one that names a
    /// variable outlives the arena of the parse or plan that failed.
    buf: [160]u8 = undefined,

    /// Leave a formatted message for `clause`; a message past the
    /// buffer is cut.
    pub fn set(self: *Diag, clause: ?usize, comptime fmt: []const u8, args: anytype) void {
        self.clause = clause;
        self.attr = null;
        self.message = std.fmt.bufPrint(&self.buf, fmt, args) catch &self.buf;
    }
};

// =============================================================================
// Entry points
// =============================================================================

/// Parse a query value into a fresh `Ir` owned by `gpa`.
pub fn parse(gpa: Allocator, interner: *Interner, query: Value, diag: *Diag) Error!*Ir {
    const out = try gpa.create(Ir);
    errdefer gpa.destroy(out);
    out.* = .{
        .arena_state = std.heap.ArenaAllocator.init(gpa),
        .vars = &.{},
        .find_spec = .relation,
        .find = &.{},
        .with = &.{},
        .in = &.{},
        .sources = &.{},
        .where = &.{},
    };
    errdefer out.arena_state.deinit();
    var p = Parser{ .arena = out.arena_state.allocator(), .interner = interner, .diag = diag };
    try p.parseQuery(query, out);
    out.vars = try p.vars.toOwnedSlice(p.arena);
    out.sources = try p.sources.toOwnedSlice(p.arena);
    return out;
}

/// Parse a `%` input (a vector of rule forms) into a fresh `RuleSet`.
pub fn parseRules(gpa: Allocator, interner: *Interner, rules: Value, diag: *Diag) Error!*RuleSet {
    const out = try gpa.create(RuleSet);
    errdefer gpa.destroy(out);
    out.* = .{ .arena_state = std.heap.ArenaAllocator.init(gpa), .vars = &.{}, .rules = &.{} };
    errdefer out.arena_state.?.deinit();
    var p = Parser{ .arena = out.arena_state.?.allocator(), .interner = interner, .diag = diag };
    out.rules = try p.parseRuleSet(rules);
    out.vars = try p.vars.toOwnedSlice(p.arena);
    return out;
}

// =============================================================================
// Parser
// =============================================================================

const Parser = struct {
    arena: Allocator,
    interner: *Interner,
    diag: *Diag,
    vars: std.ArrayList(ir.VarInfo) = .empty,
    by_sym: std.AutoHashMapUnmanaged(u32, Var) = .empty,
    /// The `:in` sources by symbol id, the first being what `$` and
    /// an unprefixed clause read; empty while parsing a rule set,
    /// whose bodies take only `$`.
    sources: std.ArrayList(u32) = .empty,
    rule_body: bool = false,
    clause_index: ?usize = null,
    /// The `:find` element being parsed, and the source each
    /// `(pull $src ...)` names, resolved once `:in` is known.
    find_index: usize = 0,
    find_elems: []ir.FindElem = &.{},
    pull_srcs: std.ArrayList(struct { find: usize, sym: Value }) = .empty,

    fn fail(self: *Parser, message: []const u8) Error {
        self.diag.* = .{ .clause = self.clause_index, .message = message };
        return error.QuerySyntax;
    }

    fn failFmt(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.diag.set(self.clause_index, fmt, args);
        return error.QuerySyntax;
    }

    fn varName(self: *Parser, v: Var) []const u8 {
        return self.interner.symbolName(self.vars.items[v].sym);
    }

    fn varOf(self: *Parser, sym: u32) !Var {
        const gop = try self.by_sym.getOrPut(self.arena, sym);
        if (gop.found_existing) return gop.value_ptr.*;
        const v: Var = @intCast(self.vars.items.len);
        try self.vars.append(self.arena, .{ .sym = sym });
        gop.value_ptr.* = v;
        return v;
    }

    /// A variable no symbol names (a `_` in a rule argument).
    fn freshVar(self: *Parser, sym: u32) !Var {
        const v: Var = @intCast(self.vars.items.len);
        try self.vars.append(self.arena, .{ .sym = sym });
        return v;
    }

    // ── value helpers ─────────────────────────────────────────────

    fn symName(self: *Parser, v: Value) ?[]const u8 {
        if (!v.isSymbol()) return null;
        return self.interner.symbolName(v.asSymbolId());
    }

    fn isSym(self: *Parser, v: Value, name: []const u8) bool {
        const s = self.symName(v) orelse return false;
        return std.mem.eql(u8, s, name);
    }

    fn isVarSym(self: *Parser, v: Value) bool {
        const s = self.symName(v) orelse return false;
        return s.len > 1 and s[0] == '?';
    }

    fn isSrcSym(self: *Parser, v: Value) bool {
        const s = self.symName(v) orelse return false;
        return s.len > 0 and s[0] == '$';
    }

    /// The source a `$name` symbol names: null for `$` (the first
    /// source, whatever `:in` calls it), its index for a declared
    /// source; an undeclared one, or any name but `$` in a rule body,
    /// is a syntax error.
    fn srcOf(self: *Parser, v: Value) Error!?ir.Src {
        if (self.isSym(v, "$")) return null;
        if (self.rule_body) return self.fail("a rule body reads $ only");
        const sym = v.asSymbolId();
        for (self.sources.items, 0..) |s, i| if (s == sym) return @intCast(i);
        return self.fail("unknown data source; declare it in :in");
    }

    fn isSeq(v: Value) bool {
        return v.kind() == .persistent_vector or v.kind() == .list;
    }

    fn elems(self: *Parser, v: Value) Error![]Value {
        return (try marshal.sequence(self.arena, v)) orelse self.fail("expected a vector or list");
    }

    fn keywordIs(self: *Parser, v: Value, name: []const u8) bool {
        if (!v.isKeyword()) return false;
        return std.mem.eql(u8, self.interner.keywordName(v.asKeywordId()), name);
    }

    // ── query ─────────────────────────────────────────────────────

    fn parseQuery(self: *Parser, query: Value, out: *Ir) Error!void {
        var find: ?[]Value = null;
        var in: ?[]Value = null;
        var with: ?[]Value = null;
        var where: ?[]Value = null;
        var keys: ?[]Value = null;
        var strs: ?[]Value = null;
        var syms: ?[]Value = null;

        switch (query.kind()) {
            .persistent_vector, .list => {
                const items = try self.elems(query);
                var section: ?*?[]Value = null;
                var acc: std.ArrayList(Value) = .empty;
                var i: usize = 0;
                while (i <= items.len) : (i += 1) {
                    const at_end = i == items.len;
                    const is_key = !at_end and items[i].isKeyword();
                    if (at_end or is_key) {
                        if (section) |s| {
                            if (s.* != null) return self.fail("duplicate query section");
                            s.* = try acc.toOwnedSlice(self.arena);
                            acc = .empty;
                        } else if (acc.items.len > 0) return self.fail("query must start with :find");
                        if (at_end) break;
                        const k = items[i];
                        section = self.sectionOf(k, &find, &in, &with, &where, &keys, &strs, &syms) orelse return self.fail("unknown query section");
                        continue;
                    }
                    try acc.append(self.arena, items[i]);
                }
            },
            .persistent_map => {
                var it = champ.mapIter(query);
                while (it.next()) |e| {
                    const k = e.key;
                    const target = self.sectionOf(k, &find, &in, &with, &where, &keys, &strs, &syms) orelse return self.fail("unknown query section");
                    target.* = try self.elems(e.value);
                }
            },
            else => return self.fail("query must be a vector or a map"),
        }

        const find_items = find orelse return self.fail("query has no :find");
        if (find_items.len == 0) return self.fail(":find is empty");
        try self.parseFind(find_items, out);
        try self.parseKeys(out, keys, strs, syms);

        out.in = if (in) |items| try self.parseIn(items) else blk: {
            try self.sources.append(self.arena, self.interner.internSymbol("$") catch return error.OutOfMemory);
            break :blk try self.arena.dupe(ir.InBinding, &.{.{ .src = 0 }});
        };

        if (with) |items| {
            const ws = try self.arena.alloc(Var, items.len);
            for (items, ws) |w, *slot| {
                if (!self.isVarSym(w)) return self.fail(":with takes variables");
                slot.* = try self.varOf(w.asSymbolId());
            }
            out.with = ws;
        }

        const where_items: []Value = where orelse &.{};
        out.where = try self.parseClauses(where_items, true);

        try self.checkBound(out);
    }

    fn sectionOf(self: *Parser, k: Value, find: *?[]Value, in: *?[]Value, with: *?[]Value, where: *?[]Value, keys: *?[]Value, strs: *?[]Value, syms: *?[]Value) ?*?[]Value {
        if (self.keywordIs(k, "find")) return find;
        if (self.keywordIs(k, "in")) return in;
        if (self.keywordIs(k, "with")) return with;
        if (self.keywordIs(k, "where")) return where;
        if (self.keywordIs(k, "keys")) return keys;
        if (self.keywordIs(k, "strs")) return strs;
        if (self.keywordIs(k, "syms")) return syms;
        return null;
    }

    /// At most one of `:keys`, `:strs`, `:syms`: symbols, one per find
    /// element, with the relation find spec.
    fn parseKeys(self: *Parser, out: *Ir, keys: ?[]Value, strs: ?[]Value, syms: ?[]Value) Error!void {
        var given: usize = 0;
        if (keys != null) given += 1;
        if (strs != null) given += 1;
        if (syms != null) given += 1;
        if (given == 0) return;
        if (given > 1) return self.fail("a query takes one of :keys, :strs and :syms");
        const items = keys orelse strs orelse syms.?;
        if (out.find_spec != .relation) return self.fail(":keys, :strs and :syms take the relation find spec");
        if (items.len != out.find.len) return self.fail(":keys, :strs and :syms take one name per :find element");
        const names = try self.arena.alloc(u32, items.len);
        for (items, names) |x, *n| {
            if (!x.isSymbol() or self.isVarSym(x)) return self.fail(":keys, :strs and :syms take symbols");
            n.* = x.asSymbolId();
        }
        out.keys = .{ .kind = if (keys != null) .keyword else if (strs != null) .string else .symbol, .names = names };
    }

    fn parseFind(self: *Parser, items: []Value, out: *Ir) Error!void {
        // `[?a .]`, `[[?a ...]]`, `[[?a ?b]]`, else relation.
        var elems_in = items;
        out.find_spec = .relation;
        if (items.len == 2 and self.isSym(items[1], ".")) {
            out.find_spec = .scalar;
            elems_in = items[0..1];
        } else if (items.len == 1 and items[0].kind() == .persistent_vector) {
            const inner = try self.elems(items[0]);
            if (inner.len == 2 and self.isSym(inner[1], "...")) {
                out.find_spec = .collection;
                elems_in = inner[0..1];
            } else {
                if (inner.len == 0) return self.fail("empty :find tuple");
                out.find_spec = .tuple;
                elems_in = inner;
            }
        }
        const fs = try self.arena.alloc(ir.FindElem, elems_in.len);
        for (elems_in, fs, 0..) |x, *f, i| {
            self.find_index = i;
            f.* = try self.parseFindElem(x);
        }
        out.find = fs;
        self.find_elems = fs;
    }

    fn parseFindElem(self: *Parser, v: Value) Error!ir.FindElem {
        if (self.isVarSym(v)) return .{ .variable = try self.varOf(v.asSymbolId()) };
        if (v.kind() == .list) {
            const parts = try self.elems(v);
            if (parts.len == 0) return self.fail("empty :find element");
            const name = self.symName(parts[0]) orelse return self.fail("aggregate head must be a symbol");
            if (std.mem.eql(u8, name, "pull")) {
                // The source is resolved once `:in` is parsed (`checkBound`).
                const with_src = parts.len == 4 and self.isSrcSym(parts[1]);
                const rest = if (with_src) parts[2..] else parts[1..];
                if (rest.len != 2 or !self.isVarSym(rest[0])) return self.fail("pull is (pull ?e pattern) or (pull $src ?e pattern)");
                const pattern = rest[1];
                var out: ir.Pull = .{ .e = try self.varOf(rest[0].asSymbolId()), .pattern = .{ .value = pattern } };
                if (self.isVarSym(pattern)) {
                    out.pattern = .{ .input = try self.varOf(pattern.asSymbolId()) };
                } else if (pattern.kind() != .persistent_vector) return self.fail("pull takes a pattern vector or a variable bound by :in");
                if (with_src) try self.pull_srcs.append(self.arena, .{ .find = self.find_index, .sym = parts[1] });
                return .{ .pull = out };
            }
            if (self.isVarSym(parts[0])) return self.fail("an aggregate is named by a symbol");
            const op = ir.AggOp.fromName(name) orelse .custom;
            var n: ?u32 = null;
            var arg_at: usize = 1;
            if (op.takesN()) |takes| {
                const given = parts.len == 3;
                if (takes == .required and !given) return self.fail("this aggregate is (op n ?x)");
                if (given) {
                    if (parts[1].kind() != .fixnum or parts[1].asFixnum() < 0) return self.fail("an aggregate's n is a non-negative integer");
                    n = std.math.cast(u32, parts[1].asFixnum()) orelse return self.fail("an aggregate's n is too large");
                    arg_at = 2;
                }
            }
            if (parts.len != arg_at + 1 or !self.isVarSym(parts[arg_at])) return self.fail("aggregate takes one variable");
            return .{ .agg = .{ .op = op, .n = n, .sym = parts[0].asSymbolId(), .arg = try self.varOf(parts[arg_at].asSymbolId()) } };
        }
        return self.fail(":find takes variables, aggregates and pull expressions");
    }

    fn parseIn(self: *Parser, items: []Value) Error![]ir.InBinding {
        var out: std.ArrayList(ir.InBinding) = .empty;
        var seen: std.ArrayList(Var) = .empty;
        var has_rules = false;
        for (items) |x| {
            if (self.isSrcSym(x)) {
                const sym = x.asSymbolId();
                if (self.sources.items.len > 0 and self.isSym(x, "$")) return self.fail("$ names the first data source; declare it first");
                for (self.sources.items) |s| if (s == sym) return self.fail("duplicate data source in :in");
                try out.append(self.arena, .{ .src = @intCast(self.sources.items.len) });
                try self.sources.append(self.arena, sym);
            } else if (self.isSym(x, "%")) {
                if (has_rules) return self.fail("more than one % in :in");
                has_rules = true;
                try out.append(self.arena, .rules);
            } else if (self.isVarSym(x)) {
                try out.append(self.arena, .{ .scalar = try self.inVar(x, &seen) });
            } else if (x.kind() == .persistent_vector) {
                const inner = try self.elems(x);
                if (inner.len == 2 and self.isSym(inner[1], "...")) {
                    if (!self.isVarSym(inner[0])) return self.fail("collection binding takes a variable");
                    try out.append(self.arena, .{ .collection = try self.inVar(inner[0], &seen) });
                } else if (inner.len == 1 and inner[0].kind() == .persistent_vector) {
                    try out.append(self.arena, .{ .relation = try self.inTuple(try self.elems(inner[0]), &seen) });
                } else {
                    try out.append(self.arena, .{ .tuple = try self.inTuple(inner, &seen) });
                }
            } else return self.fail("unknown :in binding form");
        }
        return out.toOwnedSlice(self.arena);
    }

    fn inVar(self: *Parser, x: Value, seen: *std.ArrayList(Var)) Error!Var {
        const v = try self.varOf(x.asSymbolId());
        if (ir.containsVar(seen.items, v)) return self.fail("duplicate :in variable");
        try seen.append(self.arena, v);
        return v;
    }

    fn inTuple(self: *Parser, items: []Value, seen: *std.ArrayList(Var)) Error![]?Var {
        if (items.len == 0) return self.fail("empty tuple binding");
        const out = try self.arena.alloc(?Var, items.len);
        for (items, out) |x, *slot| {
            if (self.isSym(x, "_")) {
                slot.* = null;
            } else if (self.isVarSym(x)) {
                slot.* = try self.inVar(x, seen);
            } else return self.fail("tuple binding takes variables");
        }
        return out;
    }

    /// Every `find` and `with` variable must be bound by `in` or `where`.
    fn checkBound(self: *Parser, out: *Ir) Error!void {
        var bound: std.ArrayList(Var) = .empty;
        for (out.in) |b| switch (b) {
            .scalar, .collection => |v| try ir.addVar(self.arena, &bound, v),
            .tuple, .relation => |ts| for (ts) |t| {
                if (t) |v| try ir.addVar(self.arena, &bound, v);
            },
            .src, .rules => {},
        };
        out.in_vars = try self.arena.dupe(Var, bound.items);
        try ir.boundVars(self.arena, out.where, &bound);
        self.clause_index = null;
        for (self.pull_srcs.items) |ps| self.find_elems[ps.find].pull.src = try self.srcOf(ps.sym);
        for (out.find) |f| {
            if (!ir.containsVar(bound.items, f.variable_of())) return self.fail(":find variable is not bound by :in or :where");
            if (f != .pull) continue;
            if (self.sources.items.len == 0) return self.fail("pull reads a data source, and :in names none");
            switch (f.pull.pattern) {
                .value => {},
                .input => |v| if (!scalarInput(out.in, v)) return self.fail("a pull pattern variable is bound by a scalar :in input"),
            }
        }
        for (out.with) |w| {
            if (!ir.containsVar(bound.items, w)) return self.fail(":with variable is not bound by :in or :where");
        }
    }

    fn scalarInput(in: []const ir.InBinding, v: Var) bool {
        for (in) |b| if (b == .scalar and b.scalar == v) return true;
        return false;
    }

    // ── clauses ───────────────────────────────────────────────────

    fn parseClauses(self: *Parser, items: []Value, top: bool) Error![]Clause {
        var out: std.ArrayList(Clause) = .empty;
        for (items, 0..) |x, i| {
            if (top) self.clause_index = i;
            try self.parseClauseInto(x, &out);
        }
        return out.toOwnedSlice(self.arena);
    }

    fn parseClauseInto(self: *Parser, x: Value, out: *std.ArrayList(Clause)) Error!void {
        try stack.check();
        switch (x.kind()) {
            .persistent_vector => {
                const parts = try self.elems(x);
                if (parts.len == 0) return self.fail("empty clause");
                if (parts[0].kind() == .list) return out.append(self.arena, try self.parseCallClause(parts));
                try out.append(self.arena, .{ .pattern = try self.parsePattern(parts) });
            },
            .list => {
                const parts = try self.elems(x);
                if (parts.len == 0) return self.fail("empty clause");
                const head = self.symName(parts[0]) orelse return self.fail("clause head must be a symbol");
                if (std.mem.eql(u8, head, "and")) {
                    for (parts[1..]) |c| try self.parseClauseInto(c, out);
                } else if (std.mem.eql(u8, head, "not")) {
                    const body = try self.parseBody(parts[1..]);
                    var vs: std.ArrayList(Var) = .empty;
                    try ir.allVars(self.arena, body, &vs);
                    if (vs.items.len == 0) return self.fail("not clause has no variables");
                    try out.append(self.arena, .{ .not = .{ .join = null, .body = body } });
                } else if (std.mem.eql(u8, head, "not-join")) {
                    if (parts.len < 3) return self.fail("not-join takes a variable vector and clauses");
                    const join = try self.joinVars(parts[1]);
                    try out.append(self.arena, .{ .not = .{ .join = join, .body = try self.parseBody(parts[2..]) } });
                } else if (std.mem.eql(u8, head, "or")) {
                    const branches = try self.parseBranches(parts[1..]);
                    try self.checkOrBranches(branches);
                    try out.append(self.arena, .{ .@"or" = .{ .join = null, .branches = branches } });
                } else if (std.mem.eql(u8, head, "or-join")) {
                    if (parts.len < 3) return self.fail("or-join takes a variable vector and clauses");
                    const join = try self.joinVars(parts[1]);
                    try out.append(self.arena, .{ .@"or" = .{ .join = join, .branches = try self.parseBranches(parts[2..]), .required = try self.requiredVars(parts[1]) } });
                } else if (parts[0].isSymbol() and self.isSrcSym(parts[0])) {
                    if (parts.len < 2 or self.symName(parts[1]) == null) return self.fail("a source prefix is followed by a rule name");
                    const src = try self.srcOf(parts[0]);
                    try out.append(self.arena, .{ .rule = .{ .name = parts[1].asSymbolId(), .args = try self.parseArgs(parts[2..], true), .src = src } });
                } else {
                    try out.append(self.arena, .{ .rule = .{ .name = parts[0].asSymbolId(), .args = try self.parseArgs(parts[1..], true) } });
                }
            },
            else => return self.fail("clause must be a vector or a list"),
        }
    }

    fn parseBody(self: *Parser, items: []Value) Error![]Clause {
        if (items.len == 0) return self.fail("empty clause body");
        return self.parseClauses(items, false);
    }

    fn parseBranches(self: *Parser, items: []Value) Error![]ir.Branch {
        if (items.len == 0) return self.fail("or has no branches");
        const out = try self.arena.alloc(ir.Branch, items.len);
        for (items, out) |x, *b| {
            var acc: std.ArrayList(Clause) = .empty;
            try self.parseClauseInto(x, &acc);
            if (acc.items.len == 0) return self.fail("empty or branch");
            b.* = try acc.toOwnedSlice(self.arena);
        }
        return out;
    }

    /// Every `or` branch mentions the same variables; the message names
    /// the first variable one branch has and another lacks.
    fn checkOrBranches(self: *Parser, branches: []const ir.Branch) Error!void {
        var first: std.ArrayList(Var) = .empty;
        try ir.allVars(self.arena, branches[0], &first);
        for (branches[1..], 2..) |b, n| {
            var vs: std.ArrayList(Var) = .empty;
            try ir.allVars(self.arena, b, &vs);
            for (first.items) |v| if (!ir.containsVar(vs.items, v)) return self.failFmt("or branch {d} does not mention {s}, which branch 1 does; every or branch uses the same variables (or-join names the join variables)", .{ n, self.varName(v) });
            for (vs.items) |v| if (!ir.containsVar(first.items, v)) return self.failFmt("or branch {d} mentions {s}, which branch 1 does not; every or branch uses the same variables (or-join names the join variables)", .{ n, self.varName(v) });
        }
    }

    /// The variables of the leading `[?a ...]` group of a join vector:
    /// the ones an `or-join` needs bound before it runs.
    fn requiredVars(self: *Parser, v: Value) Error![]const Var {
        const items = try self.elems(v);
        if (items.len == 0 or items[0].kind() != .persistent_vector) return &.{};
        const group = try self.elems(items[0]);
        const out = try self.arena.alloc(Var, group.len);
        for (group, out) |x, *o| o.* = try self.varOf(x.asSymbolId());
        return out;
    }

    /// `[?a ?b]` or `[[?a] ?b]` (a required-bound group, flattened).
    fn joinVars(self: *Parser, v: Value) Error![]Var {
        if (v.kind() != .persistent_vector) return self.fail("expected a vector of variables");
        var out: std.ArrayList(Var) = .empty;
        for (try self.elems(v)) |x| {
            if (x.kind() == .persistent_vector) {
                for (try self.elems(x)) |y| {
                    if (!self.isVarSym(y)) return self.fail("expected a variable");
                    try ir.addVar(self.arena, &out, try self.varOf(y.asSymbolId()));
                }
            } else {
                if (!self.isVarSym(x)) return self.fail("expected a variable");
                try ir.addVar(self.arena, &out, try self.varOf(x.asSymbolId()));
            }
        }
        if (out.items.len == 0) return self.fail("join variable vector is empty");
        return out.toOwnedSlice(self.arena);
    }

    fn parsePattern(self: *Parser, parts_in: []Value) Error!ir.Pattern {
        var parts = parts_in;
        var src: ?ir.Src = null;
        if (parts.len > 0 and parts[0].isSymbol() and self.isSrcSym(parts[0])) {
            src = try self.srcOf(parts[0]);
            parts = parts[1..];
        }
        if (parts.len == 0 or parts.len > 5) return self.fail("data pattern takes 1 to 5 positions");
        var terms: [5]ir.Term = .{ .blank, .blank, .blank, .blank, .blank };
        for (parts, 0..) |x, i| terms[i] = try self.parseTerm(x);
        if (terms[3] == .constant and terms[3].constant == .lookup) return self.fail("tx position takes an entity id or a variable");
        if (terms[4] == .constant and (terms[4].constant != .cell or terms[4].constant.cell != .boolean)) return self.fail("added position takes a boolean or a variable");
        return .{ .src = src, .e = terms[0], .a = terms[1], .v = terms[2], .tx = terms[3], .added = terms[4] };
    }

    fn parseTerm(self: *Parser, x: Value) Error!ir.Term {
        if (x.isSymbol()) {
            if (self.isSym(x, "_")) return .blank;
            if (self.isVarSym(x)) return .{ .variable = try self.varOf(x.asSymbolId()) };
            return self.fail("unknown symbol in data pattern");
        }
        if (x.kind() == .persistent_vector) return .{ .constant = .{ .lookup = try self.parseLookup(x) } };
        return .{ .constant = .{ .cell = Cell.fromValue(x) } };
    }

    fn parseLookup(self: *Parser, x: Value) Error!ir.Lookup {
        const parts = try self.elems(x);
        if (parts.len != 2 or !parts[0].isKeyword()) return self.fail("lookup ref is [:attr value]");
        if (parts[1].isSymbol() or isSeq(parts[1])) return self.fail("lookup ref value must be a constant");
        return .{ .attr = parts[0].asKeywordId(), .v = Cell.fromValue(parts[1]) };
    }

    /// `[(f args...)]` or `[(f args...) binding]`.
    fn parseCallClause(self: *Parser, parts: []Value) Error!Clause {
        const call_parts = try self.elems(parts[0]);
        if (call_parts.len == 0) return self.fail("empty function call");
        const head = call_parts[0];
        const name = self.symName(head) orelse return self.fail("function position takes a symbol or a variable");
        const f: ir.FnRef = if (self.isVarSym(head)) .{ .variable = try self.varOf(head.asSymbolId()) } else if (ir.Builtin.fromName(name)) |b| .{ .builtin = b } else .{ .user = head.asSymbolId() };
        const call: ir.Call = .{ .f = f, .args = try self.parseArgs(call_parts[1..], false) };
        if (f == .builtin) try self.checkBuiltin(f.builtin, call.args, parts.len == 1);
        if (parts.len == 1) return .{ .pred = call };
        if (parts.len != 2) return self.fail("function clause is [(f args) binding]");
        return .{ .bind = .{ .call = call, .out = try self.parseBinding(parts[1]) } };
    }

    /// A built-in's arity and role: a comparison or `missing?` stands
    /// alone as a predicate or binds its boolean; a function needs a
    /// binding form.
    fn checkBuiltin(self: *Parser, b: ir.Builtin, args: []const ir.Arg, predicate: bool) Error!void {
        switch (b) {
            .lt, .le, .gt, .ge, .eq, .ne => {
                if (args.len < 2) return self.fail("a comparison needs at least two arguments");
            },
            .missing => {
                if (args.len != 3 or args[0] != .src) return self.fail("missing? is (missing? $ ?e :attr)");
            },
            .ground => {
                if (predicate) return self.fail("ground needs a binding form");
                if (args.len != 1) return self.fail("ground takes one value");
            },
            .get_else => {
                if (predicate) return self.fail("get-else needs a binding form");
                if (args.len != 4 or args[0] != .src) return self.fail("get-else is (get-else $ ?e :attr default)");
                if (args[3] == .constant and args[3].constant == .nil) return self.fail("get-else takes a default that is not nil");
            },
            .get_some => {
                if (predicate) return self.fail("get-some needs a binding form");
                if (args.len < 3 or args[0] != .src) return self.fail("get-some is (get-some $ ?e :attr ...)");
                for (args[2..]) |a| if (a != .constant or a.constant != .keyword) return self.fail("get-some takes attribute keywords");
            },
            .tuple => {
                if (predicate) return self.fail("tuple needs a binding form");
            },
            .untuple => {
                if (predicate) return self.fail("untuple needs a binding form");
                if (args.len != 1) return self.fail("untuple takes one tuple");
            },
            .fulltext => {
                if (predicate) return self.fail("fulltext needs a binding form");
                if (args.len != 3 or args[0] != .src) return self.fail("fulltext is (fulltext $ :attr \"needle\")");
            },
        }
    }

    fn parseArgs(self: *Parser, items: []Value, rule_call: bool) Error![]ir.Arg {
        const out = try self.arena.alloc(ir.Arg, items.len);
        for (items, out) |x, *a| {
            if (x.isSymbol()) {
                if (self.isSrcSym(x)) {
                    a.* = .{ .src = try self.srcOf(x) };
                } else if (self.isVarSym(x)) {
                    a.* = .{ .variable = try self.varOf(x.asSymbolId()) };
                } else if (rule_call and self.isSym(x, "_")) {
                    a.* = .{ .variable = try self.freshVar(x.asSymbolId()) };
                } else return self.fail("unknown symbol in argument position");
            } else {
                a.* = .{ .constant = Cell.fromValue(x) };
            }
        }
        return out;
    }

    fn parseBinding(self: *Parser, x: Value) Error!ir.Binding {
        if (self.isVarSym(x)) return .{ .scalar = try self.varOf(x.asSymbolId()) };
        if (x.kind() != .persistent_vector) return self.fail("binding form is ?x, [?a ?b], [?x ...] or [[?a ?b]]");
        const inner = try self.elems(x);
        if (inner.len == 2 and self.isSym(inner[1], "...")) {
            if (!self.isVarSym(inner[0])) return self.fail("collection binding takes a variable");
            return .{ .collection = try self.varOf(inner[0].asSymbolId()) };
        }
        if (inner.len == 1 and inner[0].kind() == .persistent_vector) {
            return .{ .relation = try self.bindTuple(try self.elems(inner[0])) };
        }
        return .{ .tuple = try self.bindTuple(inner) };
    }

    fn bindTuple(self: *Parser, items: []Value) Error![]?Var {
        if (items.len == 0) return self.fail("empty tuple binding");
        const out = try self.arena.alloc(?Var, items.len);
        for (items, out, 0..) |x, *slot, i| {
            if (self.isSym(x, "_")) {
                slot.* = null;
            } else if (self.isVarSym(x)) {
                const v = try self.varOf(x.asSymbolId());
                for (out[0..i]) |prev| if (prev == v) return self.fail("duplicate variable in tuple binding");
                slot.* = v;
            } else return self.fail("tuple binding takes variables");
        }
        return out;
    }

    // ── rules ─────────────────────────────────────────────────────

    fn parseRuleSet(self: *Parser, rules: Value) Error![]ir.Rule {
        if (!isSeq(rules)) return self.fail("rules must be a vector of rule forms");
        const items = try self.elems(rules);
        var out: std.ArrayList(ir.Rule) = .empty;
        for (items, 0..) |x, i| {
            self.clause_index = i;
            if (x.kind() != .persistent_vector) return self.fail("rule form is [(name args...) clauses...]");
            const parts = try self.elems(x);
            if (parts.len < 2 or parts[0].kind() != .list) return self.fail("rule form is [(name args...) clauses...]");
            const head = try self.elems(parts[0]);
            if (head.len == 0 or self.symName(head[0]) == null) return self.fail("rule name must be a symbol");
            const name = head[0].asSymbolId();
            var vars: std.ArrayList(Var) = .empty;
            var required: usize = 0;
            for (head[1..], 0..) |h, j| {
                if (h.kind() == .persistent_vector) {
                    if (j != 0) return self.fail("required variables must come first in a rule head");
                    for (try self.elems(h)) |r| {
                        if (!self.isVarSym(r)) return self.fail("rule head takes variables");
                        try vars.append(self.arena, try self.varOf(r.asSymbolId()));
                    }
                    required = vars.items.len;
                } else {
                    if (!self.isVarSym(h)) return self.fail("rule head takes variables");
                    try vars.append(self.arena, try self.varOf(h.asSymbolId()));
                }
            }
            for (vars.items, 0..) |v, j| {
                if (ir.containsVar(vars.items[j + 1 ..], v)) return self.fail("duplicate variable in rule head");
            }
            for (out.items) |prev| {
                if (prev.name == name and (prev.head.len != vars.items.len or prev.required != required)) return self.fail("rules with one name must share an arity");
            }
            self.rule_body = true;
            const body = try self.parseClauses(parts[1..], false);
            try out.append(self.arena, .{ .name = name, .required = required, .head = try vars.toOwnedSlice(self.arena), .body = body });
        }
        for (out.items, 0..) |r, i| {
            self.clause_index = i;
            try self.checkCalls(out.items, r.body);
        }
        // Group the bodies of one rule: `RuleSet.byName` is one slice.
        // The sort is stable, so bodies keep their source order.
        std.mem.sort(ir.Rule, out.items, {}, ruleNameLess);
        return out.toOwnedSlice(self.arena);
    }

    /// Every call in `body` to a rule of the set passes as many
    /// arguments as its head has.
    fn checkCalls(self: *Parser, rules: []const ir.Rule, body: []const Clause) Error!void {
        try stack.check();
        for (body) |c| switch (c) {
            .rule => |call| for (rules) |def| {
                if (def.name != call.name) continue;
                if (def.head.len != call.args.len) return self.fail("a rule is called with the wrong number of arguments");
                break;
            },
            .not => |n| try self.checkCalls(rules, n.body),
            .@"or" => |o| for (o.branches) |br| try self.checkCalls(rules, br),
            else => {},
        };
    }

    fn ruleNameLess(_: void, a: ir.Rule, b: ir.Rule) bool {
        return a.name < b.name;
    }
};

// =============================================================================
// Cache
// =============================================================================

/// The parses a cache keeps before a miss replaces the least recently
/// used one that no query is running on.
pub const cache_capacity = 128;

fn CacheOf(comptime T: type, comptime parseFn: anytype) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            query: Value,
            hash: u64,
            parsed: *T,
            /// The cache's clock at the entry's last use.
            used: u64,
            /// Queries running on the parse; a pinned entry stays.
            pins: u32 = 0,
        };

        gpa: Allocator,
        entries: std.ArrayList(Entry) = .empty,
        clock: u64 = 0,

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |e| e.parsed.deinit();
            self.entries.deinit(self.gpa);
        }

        pub fn count(self: *const Self) usize {
            return self.entries.items.len;
        }

        /// Mark every query value the cache holds, from the VM's root
        /// walk (GC.md §3). A parse borrows from its query value
        /// (string constants' bytes, opaque and lookup-ref constants,
        /// pull patterns and their defaults), so the collector must see
        /// each one for as long as the cache holds it.
        pub fn mark(self: *const Self, c: *gc.Collector) void {
            for (self.entries.items) |e| c.markValue(e.query);
        }

        /// The parse of `query`, parsing on a miss, pinned until
        /// `release`. A hit is the same value, or one equal to it with
        /// lists and vectors told apart (`sameShape`), since the parser
        /// reads them differently.
        pub fn acquire(self: *Self, interner: *Interner, query: Value, diag: *Diag) Error!*T {
            self.clock += 1;
            const e = try self.find(interner, query, diag);
            e.used = self.clock;
            e.pins += 1;
            return e.parsed;
        }

        pub fn release(self: *Self, parsed: *const T) void {
            for (self.entries.items) |*e| if (e.parsed == parsed) {
                e.pins -= 1;
                return;
            };
            unreachable;
        }

        fn find(self: *Self, interner: *Interner, query: Value, diag: *Diag) Error!*Entry {
            for (self.entries.items) |*e| if (e.query.tag == query.tag and e.query.payload == query.payload) return e;
            const h = dispatch.hashValue(query);
            for (self.entries.items) |*e| if (e.hash == h and try sameShape(e.query, query)) return e;
            const parsed = try parseFn(self.gpa, interner, query, diag);
            errdefer parsed.deinit();
            const slot = self.victim() orelse self.entries.items.len;
            const entry: Entry = .{ .query = query, .hash = h, .parsed = parsed, .used = self.clock };
            if (slot == self.entries.items.len) {
                try self.entries.append(self.gpa, entry);
            } else {
                self.entries.items[slot].parsed.deinit();
                self.entries.items[slot] = entry;
            }
            return &self.entries.items[slot];
        }

        /// The entry a miss replaces: the least recently used unpinned
        /// one once the cache is full, else null (append).
        fn victim(self: *const Self) ?usize {
            if (self.entries.items.len < cache_capacity) return null;
            var best: ?usize = null;
            for (self.entries.items, 0..) |e, i| {
                if (e.pins > 0) continue;
                if (best == null or e.used < self.entries.items[best.?].used) best = i;
            }
            return best;
        }
    };
}

/// `=` over query values with lists and vectors told apart at every
/// depth: `[?e :a (:b 1)]` and `[?e :a [:b 1]]` are equal as data but
/// parse to different clauses. Anything that is not a list, vector or
/// map compares by `=`.
fn sameShape(a: Value, b: Value) error{StackOverflow}!bool {
    try stack.check();
    if (a.kind() != b.kind()) return false;
    switch (a.kind()) {
        .persistent_vector => {
            const n = vector_mod.count(a);
            if (n != vector_mod.count(b)) return false;
            for (0..n) |i| if (!try sameShape(vector_mod.nth(a, i), vector_mod.nth(b, i))) return false;
            return true;
        },
        .list => {
            var x = list_mod.Cursor.init(a);
            var y = list_mod.Cursor.init(b);
            while (true) {
                const p = x.next();
                const q = y.next();
                if (p == null or q == null) return p == null and q == null;
                if (!try sameShape(p.?, q.?)) return false;
            }
        },
        .persistent_map => {
            if (champ.mapCount(a) != champ.mapCount(b)) return false;
            var it = champ.mapIter(a);
            while (it.next()) |e| switch (champ.mapGet(b, e.key, &dispatch.hashValue, &dispatch.equal)) {
                .absent => return false,
                .present => |v| if (!try sameShape(e.value, v)) return false,
            };
            return true;
        },
        else => return dispatch.equal(a, b),
    }
}

pub const Cache = CacheOf(Ir, parse);
pub const RulesCache = CacheOf(RuleSet, parseRules);

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const heap_mod = @import("../../heap.zig");

/// Builds query values in tests: `v.sym("?e")`, `v.vec(&.{...})`.
const Builder = struct {
    heap: *heap_mod.Heap,
    interner: *Interner,

    fn sym(self: Builder, name: []const u8) Value {
        return self.interner.internSymbolValue(name) catch unreachable;
    }
    fn kw(self: Builder, name: []const u8) Value {
        return self.interner.internKeywordValue(name) catch unreachable;
    }
    fn vec(self: Builder, items: []const Value) Value {
        return vector_mod.fromSlice(self.heap, items) catch unreachable;
    }
    fn lst(self: Builder, items: []const Value) Value {
        return list_mod.fromSlice(self.heap, items) catch unreachable;
    }
    fn str(self: Builder, s: []const u8) Value {
        return string_mod.fromBytes(self.heap, s) catch unreachable;
    }
    fn int(_: Builder, n: i64) Value {
        return value.fromFixnum(n).?;
    }
};

test "vector form: find specs, in bindings, where clause kinds" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    const b = Builder{ .heap = &heap, .interner = &interner };

    // [:find ?n (count ?e) :in $ ?age [?tag ...] [[?a ?b]] % ?pred ?f
    //  :with ?w
    //  :where [?e :user/name ?n] [?e :user/age ?age] [?e :user/tags ?tag]
    //         [(< ?age 40)] [(str ?n "!") ?w] [(?pred ?age)] [(?f ?n) ?fn] (not [?e :user/bio _])
    //         (or-join [?e] [?e :user/x 1] (and [?e :user/y ?a] [?e :user/z ?b]))
    //         (friend ?e ?f) [?f :user/name "Q"] [[:user/email "a@x"] :user/age _ ?tx true]]
    const q = b.vec(&.{
        b.kw("find"),
        b.sym("?n"),
        b.lst(&.{ b.sym("count"), b.sym("?e") }),
        b.kw("in"),
        b.sym("$"),
        b.sym("?age"),
        b.vec(&.{ b.sym("?tag"), b.sym("...") }),
        b.vec(&.{b.vec(&.{ b.sym("?a"), b.sym("?b") })}),
        b.sym("%"),
        b.sym("?pred"),
        b.sym("?f"),
        b.kw("with"),
        b.sym("?w"),
        b.kw("where"),
        b.vec(&.{ b.sym("?e"), b.kw("user/name"), b.sym("?n") }),
        b.vec(&.{ b.sym("?e"), b.kw("user/age"), b.sym("?age") }),
        b.vec(&.{ b.sym("?e"), b.kw("user/tags"), b.sym("?tag") }),
        b.vec(&.{b.lst(&.{ b.sym("<"), b.sym("?age"), b.int(40) })}),
        b.vec(&.{ b.lst(&.{ b.sym("str"), b.sym("?n"), b.str("!") }), b.sym("?w") }),
        b.vec(&.{b.lst(&.{ b.sym("?pred"), b.sym("?age") })}),
        b.vec(&.{ b.lst(&.{ b.sym("?f"), b.sym("?n") }), b.sym("?fn") }),
        b.lst(&.{ b.sym("not"), b.vec(&.{ b.sym("?e"), b.kw("user/bio"), b.sym("_") }) }),
        b.lst(&.{ b.sym("or-join"), b.vec(&.{b.sym("?e")}), b.vec(&.{ b.sym("?e"), b.kw("user/x"), b.int(1) }), b.lst(&.{ b.sym("and"), b.vec(&.{ b.sym("?e"), b.kw("user/y"), b.sym("?a") }), b.vec(&.{ b.sym("?e"), b.kw("user/z"), b.sym("?b") }) }) }),
        b.lst(&.{ b.sym("friend"), b.sym("?e"), b.sym("?f") }),
        b.vec(&.{ b.sym("?f"), b.kw("user/name"), b.str("Q") }),
        b.vec(&.{ b.vec(&.{ b.kw("user/email"), b.str("a@x") }), b.kw("user/age"), b.sym("_"), b.sym("?tx"), value.fromBool(true) }),
    });
    var diag: Diag = .{};
    const parsed = try parse(testing.allocator, &interner, q, &diag);
    defer parsed.deinit();
    try testing.expectEqual(ir.FindSpec.relation, parsed.find_spec);
    try testing.expectEqual(@as(usize, 2), parsed.find.len);
    try testing.expect(parsed.find[1] == .agg and parsed.find[1].agg.op == .count and parsed.find[1].agg.n == null);
    try testing.expectEqual(@as(usize, 7), parsed.in.len);
    try testing.expect(parsed.in[0] == .src and parsed.in[1] == .scalar and parsed.in[2] == .collection and parsed.in[3] == .relation and parsed.in[4] == .rules);
    try testing.expect(parsed.in[5] == .scalar and parsed.in[6] == .scalar);
    try testing.expectEqual(@as(usize, 1), parsed.with.len);
    try testing.expectEqual(@as(usize, 12), parsed.where.len);
    try testing.expect(parsed.where[3] == .pred and parsed.where[3].pred.f.builtin == .lt);
    try testing.expect(parsed.where[4] == .bind and parsed.where[4].bind.call.f == .user);
    try testing.expect(parsed.where[5] == .pred and parsed.where[5].pred.f == .variable and parsed.where[5].pred.f.variable == parsed.in[5].scalar);
    try testing.expect(parsed.where[6] == .bind and parsed.where[6].bind.call.f == .variable and parsed.where[6].bind.call.f.variable == parsed.in[6].scalar);
    try testing.expect(parsed.where[7] == .not and parsed.where[7].not.join == null);
    try testing.expect(parsed.where[8] == .@"or" and parsed.where[8].@"or".branches.len == 2 and parsed.where[8].@"or".branches[1].len == 2);
    try testing.expect(parsed.where[9] == .rule);
    const last = parsed.where[11].pattern;
    try testing.expect(last.e == .constant and last.e.constant == .lookup);
    try testing.expect(last.v == .blank and last.tx == .variable and last.added.constant.cell.boolean);
    try testing.expectEqualStrings("?e", interner.symbolName(parsed.vars[1].sym));
}

test "sources: $ first, $name prefixes on patterns, calls and rule calls" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    const b = Builder{ .heap = &heap, .interner = &interner };
    var diag: Diag = .{};

    // [:find ?n :in $ $2 :where [?e :a ?n] [$2 ?e :a ?n] [$ ?e :b _]
    //  [(missing? $2 ?e :c)] ($2 r ?e) (r ?e)]
    const q = b.vec(&.{
        b.kw("find"),                                                b.sym("?n"),
        b.kw("in"),                                                  b.sym("$"),
        b.sym("$2"),                                                 b.kw("where"),
        b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?n") }),            b.vec(&.{ b.sym("$2"), b.sym("?e"), b.kw("a"), b.sym("?n") }),
        b.vec(&.{ b.sym("$"), b.sym("?e"), b.kw("b"), b.sym("_") }), b.vec(&.{b.lst(&.{ b.sym("missing?"), b.sym("$2"), b.sym("?e"), b.kw("c") })}),
        b.lst(&.{ b.sym("$2"), b.sym("r"), b.sym("?e") }),           b.lst(&.{ b.sym("r"), b.sym("?e") }),
    });
    const p = try parse(testing.allocator, &interner, q, &diag);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.sources.len);
    try testing.expect(p.in[0] == .src and p.in[0].src == 0 and p.in[1] == .src and p.in[1].src == 1);
    try testing.expect(p.where[0].pattern.src == null);
    try testing.expectEqual(@as(?ir.Src, 1), p.where[1].pattern.src);
    try testing.expect(p.where[2].pattern.src == null);
    try testing.expectEqual(@as(?ir.Src, 1), p.where[3].pred.args[0].src);
    try testing.expectEqual(@as(?ir.Src, 1), p.where[4].rule.src);
    try testing.expect(p.where[5].rule.src == null);

    // The first source may carry any $name; $ and an unprefixed
    // clause read it.
    const named = b.vec(&.{
        b.kw("find"),                                                b.sym("?n"),
        b.kw("in"),                                                  b.sym("$db"),
        b.sym("?e"),                                                 b.kw("where"),
        b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?n") }),            b.vec(&.{ b.sym("$db"), b.sym("?e"), b.kw("b"), b.sym("_") }),
        b.vec(&.{ b.sym("$"), b.sym("?e"), b.kw("c"), b.sym("_") }),
    });
    const pn = try parse(testing.allocator, &interner, named, &diag);
    defer pn.deinit();
    try testing.expectEqual(@as(usize, 1), pn.sources.len);
    try testing.expectEqualStrings("$db", interner.symbolName(pn.sources[0]));
    try testing.expect(pn.in[0] == .src and pn.in[0].src == 0);
    try testing.expect(pn.where[0].pattern.src == null);
    try testing.expectEqual(@as(?ir.Src, 0), pn.where[1].pattern.src);
    try testing.expect(pn.where[2].pattern.src == null);

    // A source may follow other inputs, and a query may have none.
    const late = try parse(testing.allocator, &interner, b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("in"), b.sym("?x"), b.sym("$"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?x") }) }), &diag);
    defer late.deinit();
    try testing.expect(late.in[1] == .src and late.in[1].src == 0);
    const none = try parse(testing.allocator, &interner, b.vec(&.{ b.kw("find"), b.sym("?x"), b.kw("in"), b.sym("?x") }), &diag);
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.sources.len);

    for ([_]Value{
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("in"), b.sym("$2"), b.sym("$"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("in"), b.sym("$"), b.sym("$"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("$2"), b.sym("?e"), b.kw("a"), b.int(1) }) }),
    }) |bad| {
        try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, bad, &diag));
        try testing.expect(diag.message.len > 0);
    }
    // A rule body reads $ only.
    const rules_ok = b.vec(&.{b.vec(&.{ b.lst(&.{ b.sym("r"), b.sym("?a") }), b.vec(&.{ b.sym("$"), b.sym("?a"), b.kw("edge"), b.int(1) }) })});
    const rs = try parseRules(testing.allocator, &interner, rules_ok, &diag);
    defer rs.deinit();
    try testing.expect(rs.rules[0].body[0].pattern.src == null);
    const rules_bad = b.vec(&.{b.vec(&.{ b.lst(&.{ b.sym("r"), b.sym("?a") }), b.vec(&.{ b.sym("$2"), b.sym("?a"), b.kw("edge"), b.int(1) }) })});
    try testing.expectError(error.QuerySyntax, parseRules(testing.allocator, &interner, rules_bad, &diag));
}

test "map form, scalar/collection/tuple find, default :in, errors carry clause index" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    const b = Builder{ .heap = &heap, .interner = &interner };

    const where = b.vec(&.{b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") })});
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, b.kw("find"), b.vec(&.{ b.sym("?v"), b.sym(".") }), &dispatch.hashValue, &dispatch.equal);
    m = try champ.mapAssoc(&heap, m, b.kw("where"), where, &dispatch.hashValue, &dispatch.equal);
    var diag: Diag = .{};
    const p1 = try parse(testing.allocator, &interner, m, &diag);
    defer p1.deinit();
    try testing.expectEqual(ir.FindSpec.scalar, p1.find_spec);
    try testing.expectEqual(@as(usize, 1), p1.in.len);
    try testing.expect(p1.in[0] == .src);

    const q2 = b.vec(&.{ b.kw("find"), b.vec(&.{ b.sym("?v"), b.sym("...") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) });
    const p2 = try parse(testing.allocator, &interner, q2, &diag);
    defer p2.deinit();
    try testing.expectEqual(ir.FindSpec.collection, p2.find_spec);

    const q3 = b.vec(&.{ b.kw("find"), b.vec(&.{ b.sym("?e"), b.sym("?v") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) });
    const p3 = try parse(testing.allocator, &interner, q3, &diag);
    defer p3.deinit();
    try testing.expectEqual(ir.FindSpec.tuple, p3.find_spec);

    // Unbound find var.
    const q4 = b.vec(&.{ b.kw("find"), b.sym("?x"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q4, &diag));
    try testing.expect(diag.clause == null);

    // Bad clause at index 1.
    const q5 = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.sym("?e"), b.sym("bogus") }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q5, &diag));
    try testing.expectEqual(@as(?usize, 1), diag.clause);
    try testing.expectEqualStrings("unknown symbol in data pattern", diag.message);

    // or branches with different vars: the message names the variable
    // and the branch, and the clause index is kept.
    const q6 = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }), b.lst(&.{ b.sym("or"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?z") }) }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q6, &diag));
    try testing.expectEqual(@as(?usize, 1), diag.clause);
    try testing.expectEqualStrings("or branch 2 mentions ?z, which branch 1 does not; every or branch uses the same variables (or-join names the join variables)", diag.message);

    // Unknown section.
    const q7 = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("keyz"), b.sym("e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q7, &diag));

    // Aggregates with a count, custom aggregates, and their errors.
    const q_agg = b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("max"), b.int(2), b.sym("?v") }), b.lst(&.{ b.sym("sample"), b.int(3), b.sym("?v") }), b.lst(&.{ b.sym("my/total"), b.sym("?v") }), b.lst(&.{ b.sym("median"), b.sym("?v") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) });
    const pa = try parse(testing.allocator, &interner, q_agg, &diag);
    defer pa.deinit();
    try testing.expect(pa.find[0].agg.op == .max and pa.find[0].agg.n.? == 2);
    try testing.expect(pa.find[1].agg.op == .sample and pa.find[1].agg.n.? == 3);
    try testing.expect(pa.find[2].agg.op == .custom and pa.find[2].agg.sym == b.sym("my/total").asSymbolId());
    try testing.expect(pa.find[3].agg.op == .median and pa.find[3].agg.n == null);
    for ([_]Value{
        b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("sample"), b.sym("?v") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) }),
        b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("rand"), b.int(-1), b.sym("?v") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) }),
        b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("sum"), b.int(2), b.sym("?v") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) }),
        b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("?f"), b.sym("?v") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }) }),
    }) |bad| {
        try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, bad, &diag));
        try testing.expect(diag.message.len > 0);
    }

    // :keys / :strs / :syms name every find element; pull expressions.
    const q_keys = b.vec(&.{ b.kw("find"), b.sym("?e"), b.lst(&.{ b.sym("pull"), b.sym("?e"), b.vec(&.{b.kw("a")}) }), b.kw("keys"), b.sym("id"), b.sym("row"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    const pk = try parse(testing.allocator, &interner, q_keys, &diag);
    defer pk.deinit();
    try testing.expect(pk.keys.?.kind == .keyword and pk.keys.?.names.len == 2);
    try testing.expect(pk.find[1] == .pull and pk.find[1].pull.e == pk.find[0].variable);
    const q_syms = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("syms"), b.sym("id"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    const ps = try parse(testing.allocator, &interner, q_syms, &diag);
    defer ps.deinit();
    try testing.expect(ps.keys.?.kind == .symbol);
    for ([_]Value{
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("keys"), b.sym("a"), b.sym("b"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.sym("."), b.kw("strs"), b.sym("a"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("keys"), b.kw("a"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("keys"), b.sym("a"), b.kw("syms"), b.sym("a"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("pull"), b.sym("?e") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
        b.vec(&.{ b.kw("find"), b.lst(&.{ b.sym("pull"), b.sym("?e"), b.kw("a") }), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) }),
    }) |bad| {
        try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, bad, &diag));
        try testing.expect(diag.message.len > 0);
    }

    // Built-in arity and role are checked here, with a reason.
    for ([_]Value{
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("<"), b.sym("?v") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("missing?"), b.sym("?e"), b.kw("a") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("ground"), b.int(1), b.int(2) }), b.sym("?x") }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("get-else"), b.sym("?e"), b.kw("a"), b.int(0) }), b.sym("?x") }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("tuple"), b.sym("?v") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("untuple"), b.sym("?v"), b.sym("?v") }), b.vec(&.{ b.sym("?x"), b.sym("?y") }) }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("fulltext"), b.sym("$"), b.kw("a"), b.sym("?v") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("fulltext"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.vec(&.{ b.sym("?x"), b.sym("?y") })}) }) }),
    }) |bad_call| {
        try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, bad_call, &diag));
        try testing.expect(diag.message.len > 0);
        try testing.expectEqual(@as(?usize, 1), diag.clause);
    }

    // A comparison with a binding form binds its boolean.
    const lt_bind = try parse(testing.allocator, &interner, b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("<"), b.sym("?v"), b.int(3) }), b.sym("?x") }) }), &diag);
    defer lt_bind.deinit();
    try testing.expect(lt_bind.where[1] == .bind and lt_bind.where[1].bind.call.f.builtin == .lt);

    // A variable twice in one tuple binding.
    const q8 = b.vec(&.{ b.kw("find"), b.sym("?x"), b.kw("where"), b.vec(&.{ b.lst(&.{ b.sym("f"), b.int(1) }), b.vec(&.{ b.sym("?x"), b.sym("?x") }) }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q8, &diag));
    try testing.expectEqualStrings("duplicate variable in tuple binding", diag.message);
}

test "rules parse with required groups and arity checks; caches hit by identity and structure" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    const b = Builder{ .heap = &heap, .interner = &interner };

    const rules = b.vec(&.{
        b.vec(&.{ b.lst(&.{ b.sym("reach"), b.vec(&.{b.sym("?a")}), b.sym("?b") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.sym("?b") }) }),
        b.vec(&.{ b.lst(&.{ b.sym("reach"), b.vec(&.{b.sym("?a")}), b.sym("?b") }), b.lst(&.{ b.sym("reach"), b.sym("?a"), b.sym("?m") }), b.vec(&.{ b.sym("?m"), b.kw("edge"), b.sym("?b") }) }),
    });
    var diag: Diag = .{};
    const rs = try parseRules(testing.allocator, &interner, rules, &diag);
    defer rs.deinit();
    try testing.expectEqual(@as(usize, 2), rs.rules.len);
    try testing.expectEqual(@as(usize, 1), rs.rules[0].required);
    try testing.expectEqual(@as(usize, 2), rs.rules[1].head.len);
    try testing.expectEqual(@as(usize, 2), rs.byName(rs.rules[0].name).?.len);

    // Interleaved names are grouped, bodies in source order, and the
    // empty set frees nothing.
    const mixed = b.vec(&.{
        b.vec(&.{ b.lst(&.{ b.sym("r"), b.sym("?a") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.int(1) }) }),
        b.vec(&.{ b.lst(&.{ b.sym("s"), b.sym("?a") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.int(2) }) }),
        b.vec(&.{ b.lst(&.{ b.sym("r"), b.sym("?a") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.int(3) }) }),
        b.vec(&.{ b.lst(&.{ b.sym("s"), b.sym("?a") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.int(4) }) }),
    });
    const ms = try parseRules(testing.allocator, &interner, mixed, &diag);
    defer ms.deinit();
    const r_name = (try interner.internSymbol("r"));
    const s_name = (try interner.internSymbol("s"));
    const rs_r = ms.byName(r_name).?;
    const rs_s = ms.byName(s_name).?;
    try testing.expectEqual(@as(usize, 2), rs_r.len);
    try testing.expectEqual(@as(usize, 2), rs_s.len);
    try testing.expectEqual(@as(i64, 1), rs_r[0].body[0].pattern.v.constant.cell.int);
    try testing.expectEqual(@as(i64, 3), rs_r[1].body[0].pattern.v.constant.cell.int);
    try testing.expectEqual(@as(i64, 2), rs_s[0].body[0].pattern.v.constant.cell.int);
    try testing.expectEqual(@as(i64, 4), rs_s[1].body[0].pattern.v.constant.cell.int);
    try testing.expect(ms.byName(try interner.internSymbol("t")) == null);
    var empty = ir.no_rules;
    empty.deinit();

    const bad = b.vec(&.{
        b.vec(&.{ b.lst(&.{ b.sym("r"), b.sym("?a") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.int(1) }) }),
        b.vec(&.{ b.lst(&.{ b.sym("r"), b.sym("?a"), b.sym("?b") }), b.vec(&.{ b.sym("?a"), b.kw("edge"), b.sym("?b") }) }),
    });
    try testing.expectError(error.QuerySyntax, parseRules(testing.allocator, &interner, bad, &diag));
    try testing.expectEqual(@as(?usize, 1), diag.clause);

    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    const q = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    const p1 = try cache.acquire(&interner, q, &diag);
    const p2 = try cache.acquire(&interner, q, &diag);
    try testing.expect(p1 == p2);
    const q_again = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    const p3 = try cache.acquire(&interner, q_again, &diag);
    try testing.expect(p1 == p3);
    try testing.expectEqual(@as(usize, 1), cache.count());
    const q_other = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(2) }) });
    const p4 = try cache.acquire(&interner, q_other, &diag);
    try testing.expect(p1 != p4);
    for ([_]*Ir{ p1, p2, p3, p4 }) |p| cache.release(p);

    // A list constant and a lookup-ref vector are `=` but parse apart.
    const as_list = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.lst(&.{ b.kw("b"), b.int(1) }) }) });
    const as_vec = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.vec(&.{ b.kw("b"), b.int(1) }) }) });
    try testing.expect(dispatch.equal(as_list, as_vec));
    const pl = try cache.acquire(&interner, as_list, &diag);
    const pv = try cache.acquire(&interner, as_vec, &diag);
    try testing.expect(pl.where[0].pattern.v.constant == .cell);
    try testing.expect(pv.where[0].pattern.v.constant == .lookup);
    cache.release(pl);
    cache.release(pv);
}

test "clauses nested past the stack guard are StackOverflow" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    const b = Builder{ .heap = &heap, .interner = &interner };
    var clause = b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) });
    for (0..5000) |_| clause = b.lst(&.{ b.sym("not"), clause });
    const q = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), clause });
    stack.arm(64 * 1024);
    defer stack.arm(stack.main_thread_budget);
    var diag: Diag = .{};
    try testing.expectError(error.StackOverflow, parse(testing.allocator, &interner, q, &diag));
}

test "a full cache replaces its least recently used unpinned parse and marks what it holds" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    const b = Builder{ .heap = &heap, .interner = &interner };
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    var diag: Diag = .{};
    const queryOf = struct {
        fn f(bb: Builder, n: i64) Value {
            return bb.vec(&.{ bb.kw("find"), bb.sym("?e"), bb.kw("where"), bb.vec(&.{ bb.sym("?e"), bb.kw("a"), bb.int(n) }) });
        }
    }.f;
    // The first query stays pinned; the second is the oldest unpinned.
    const pinned = try cache.acquire(&interner, queryOf(b, 0), &diag);
    var i: i64 = 1;
    while (i < cache_capacity) : (i += 1) cache.release(try cache.acquire(&interner, queryOf(b, i), &diag));
    try testing.expectEqual(@as(usize, cache_capacity), cache.count());
    const newest = try cache.acquire(&interner, queryOf(b, 1000), &diag);
    cache.release(newest);
    try testing.expectEqual(@as(usize, cache_capacity), cache.count());

    // A collection rooted only by the cache frees the replaced query
    // and keeps the rest: an equal query built afresh finds each.
    const Walk = struct {
        fn roots(ctx: *anyopaque, c: *gc.Collector) void {
            const self: *const Cache = @ptrCast(@alignCast(ctx));
            self.mark(c);
        }
        fn trace(_: *anyopaque, _: *heap_mod.HeapHeader, _: *gc.Collector) void {
            unreachable;
        }
    };
    var collector = gc.Collector.init(&heap);
    defer collector.deinit();
    collector.host = .{ .ctx = @ptrCast(&cache), .roots = &Walk.roots, .trace = &Walk.trace };
    try testing.expect(collector.collect(&.{}) > 0);
    try testing.expect(pinned == try cache.acquire(&interner, queryOf(b, 0), &diag));
    try testing.expect(newest == try cache.acquire(&interner, queryOf(b, 1000), &diag));
    i = 2;
    while (i < cache_capacity) : (i += 1) cache.release(try cache.acquire(&interner, queryOf(b, i), &diag));
    try testing.expectEqual(@as(usize, cache_capacity), cache.count());
    cache.release(newest);
    cache.release(pinned);
    cache.release(pinned);
}
