//! query/parse.zig — query value to IR (NEXTOMIC.md §5 "Parse").
//!
//! Accepts the vector form `[:find ... :in ... :with ... :where ...]`
//! and the map form `{:find [...] :in [...] :with [...] :where [...]}`.
//! Every syntax error is `error.QuerySyntax` with the clause index and
//! a message left in the caller's `Diag`. Invariants:
//!   - The IR is pure syntax (see `ir.zig`); nothing here touches a
//!     store, so a parsed query is reusable across dbs and bases.
//!   - Every `find` and `with` variable is bound by `in` or `where`.
//!   - `in` variables are unique; `$` and `%` appear at most once.
//!   - `or` branches bind the same variables; `not` mentions at least
//!     one variable.
//!   - Rules with one name share one arity and one required count.
//!
//! `Cache` memoises parses per query value: by heap identity first
//! (the query literal's pointer), then by structural hash and
//! equality. Heap pointers are stable for the process's life because
//! nothing moves or frees a value while a cache references it; a
//! collector that frees values must `clear` the cache.

const std = @import("std");
const value = @import("value");
const intern_mod = @import("intern");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const dispatch = @import("dispatch");
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

pub const Error = error{ QuerySyntax, OutOfMemory };

/// Where a syntax error was found. `clause` is the index into `:where`
/// (or into the rule vector for rule parsing) when the error is inside
/// a clause.
pub const Diag = struct {
    clause: ?usize = null,
    message: []const u8 = "",
    /// The attribute an `UnknownAttribute` names, as the query wrote it.
    attr: ?Value = null,
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
        .where = &.{},
    };
    errdefer out.arena_state.deinit();
    var p = Parser{ .arena = out.arena_state.allocator(), .interner = interner, .diag = diag };
    try p.parseQuery(query, out);
    out.vars = try p.vars.toOwnedSlice(p.arena);
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
    clause_index: ?usize = null,

    fn fail(self: *Parser, message: []const u8) Error {
        self.diag.* = .{ .clause = self.clause_index, .message = message };
        return error.QuerySyntax;
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
                        section = if (self.keywordIs(k, "find")) &find else if (self.keywordIs(k, "in")) &in else if (self.keywordIs(k, "with")) &with else if (self.keywordIs(k, "where")) &where else return self.fail("unknown query section");
                        continue;
                    }
                    try acc.append(self.arena, items[i]);
                }
            },
            .persistent_map => {
                var it = champ.mapIter(query);
                while (it.next()) |e| {
                    const k = e.key;
                    const target: *?[]Value = if (self.keywordIs(k, "find")) &find else if (self.keywordIs(k, "in")) &in else if (self.keywordIs(k, "with")) &with else if (self.keywordIs(k, "where")) &where else return self.fail("unknown query section");
                    target.* = try self.elems(e.value);
                }
            },
            else => return self.fail("query must be a vector or a map"),
        }

        const find_items = find orelse return self.fail("query has no :find");
        if (find_items.len == 0) return self.fail(":find is empty");
        try self.parseFind(find_items, out);

        out.in = if (in) |items| try self.parseIn(items) else try self.arena.dupe(ir.InBinding, &.{.src});

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

    fn parseFind(self: *Parser, items: []Value, out: *Ir) Error!void {
        // `[?a .]`, `[[?a ...]]`, `[[?a ?b]]`, else relation.
        if (items.len == 2 and self.isSym(items[1], ".")) {
            out.find_spec = .scalar;
            out.find = try self.arena.dupe(ir.FindElem, &.{try self.parseFindElem(items[0])});
            return;
        }
        if (items.len == 1 and items[0].kind() == .persistent_vector) {
            const inner = try self.elems(items[0]);
            if (inner.len == 2 and self.isSym(inner[1], "...")) {
                out.find_spec = .collection;
                out.find = try self.arena.dupe(ir.FindElem, &.{try self.parseFindElem(inner[0])});
                return;
            }
            if (inner.len == 0) return self.fail("empty :find tuple");
            out.find_spec = .tuple;
            const fs = try self.arena.alloc(ir.FindElem, inner.len);
            for (inner, fs) |x, *f| f.* = try self.parseFindElem(x);
            out.find = fs;
            return;
        }
        out.find_spec = .relation;
        const fs = try self.arena.alloc(ir.FindElem, items.len);
        for (items, fs) |x, *f| f.* = try self.parseFindElem(x);
        out.find = fs;
    }

    fn parseFindElem(self: *Parser, v: Value) Error!ir.FindElem {
        if (self.isVarSym(v)) return .{ .variable = try self.varOf(v.asSymbolId()) };
        if (v.kind() == .list) {
            const parts = try self.elems(v);
            if (parts.len != 2 or !self.isVarSym(parts[1])) return self.fail("aggregate takes one variable");
            const name = self.symName(parts[0]) orelse return self.fail("aggregate head must be a symbol");
            const op = ir.AggOp.fromName(name) orelse return self.fail("unknown aggregate");
            return .{ .agg = .{ .op = op, .arg = try self.varOf(parts[1].asSymbolId()) } };
        }
        return self.fail(":find takes variables and aggregates");
    }

    fn parseIn(self: *Parser, items: []Value) Error![]ir.InBinding {
        var out: std.ArrayList(ir.InBinding) = .empty;
        var seen: std.ArrayList(Var) = .empty;
        var has_src = false;
        var has_rules = false;
        for (items) |x| {
            if (self.isSym(x, "$")) {
                if (has_src) return self.fail("more than one $ in :in");
                has_src = true;
                try out.append(self.arena, .src);
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
        if (!has_src) return self.fail(":in must include $");
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
        try ir.boundVars(self.arena, out.where, &bound);
        self.clause_index = null;
        for (out.find) |f| {
            if (!ir.containsVar(bound.items, f.variable_of())) return self.fail(":find variable is not bound by :in or :where");
        }
        for (out.with) |w| {
            if (!ir.containsVar(bound.items, w)) return self.fail(":with variable is not bound by :in or :where");
        }
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
                    try out.append(self.arena, .{ .@"or" = .{ .join = join, .branches = try self.parseBranches(parts[2..]) } });
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

    fn checkOrBranches(self: *Parser, branches: []const ir.Branch) Error!void {
        var first: std.ArrayList(Var) = .empty;
        try ir.allVars(self.arena, branches[0], &first);
        for (branches[1..]) |b| {
            var vs: std.ArrayList(Var) = .empty;
            try ir.allVars(self.arena, b, &vs);
            if (vs.items.len != first.items.len) return self.fail("or branches must use the same variables");
            for (vs.items) |v| if (!ir.containsVar(first.items, v)) return self.fail("or branches must use the same variables");
        }
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
        if (parts.len > 0 and self.isSym(parts[0], "$")) parts = parts[1..];
        if (parts.len == 0 or parts.len > 5) return self.fail("data pattern takes 1 to 5 positions");
        var terms: [5]ir.Term = .{ .blank, .blank, .blank, .blank, .blank };
        for (parts, 0..) |x, i| terms[i] = try self.parseTerm(x);
        if (terms[3] == .constant and terms[3].constant == .lookup) return self.fail("tx position takes an entity id or a variable");
        if (terms[4] == .constant and (terms[4].constant != .cell or terms[4].constant.cell != .boolean)) return self.fail("added position takes a boolean or a variable");
        return .{ .e = terms[0], .a = terms[1], .v = terms[2], .tx = terms[3], .added = terms[4] };
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
        const name = self.symName(call_parts[0]) orelse return self.fail("function name must be a symbol");
        const f: ir.FnRef = if (ir.Builtin.fromName(name)) |b| .{ .builtin = b } else .{ .user = call_parts[0].asSymbolId() };
        const call: ir.Call = .{ .f = f, .args = try self.parseArgs(call_parts[1..], false) };
        if (f == .builtin) try self.checkBuiltin(f.builtin, call.args, parts.len == 1);
        if (parts.len == 1) return .{ .pred = call };
        if (parts.len != 2) return self.fail("function clause is [(f args) binding]");
        return .{ .bind = .{ .call = call, .out = try self.parseBinding(parts[1]) } };
    }

    /// A built-in's arity and role: predicates stand alone, functions
    /// need a binding form.
    fn checkBuiltin(self: *Parser, b: ir.Builtin, args: []const ir.Arg, predicate: bool) Error!void {
        switch (b) {
            .lt, .le, .gt, .ge, .eq, .ne => {
                if (!predicate) return self.fail("a comparison is a predicate; it binds nothing");
                if (args.len < 2) return self.fail("a comparison needs at least two arguments");
            },
            .missing => {
                if (!predicate) return self.fail("missing? is a predicate; it binds nothing");
                if (args.len != 3 or args[0] != .src) return self.fail("missing? is (missing? $ ?e :attr)");
            },
            .ground => {
                if (predicate) return self.fail("ground needs a binding form");
                if (args.len != 1) return self.fail("ground takes one value");
            },
            .get_else => {
                if (predicate) return self.fail("get-else needs a binding form");
                if (args.len != 4 or args[0] != .src) return self.fail("get-else is (get-else $ ?e :attr default)");
            },
            .tuple => {
                if (predicate) return self.fail("tuple needs a binding form");
            },
            .untuple => {
                if (predicate) return self.fail("untuple needs a binding form");
                if (args.len != 1) return self.fail("untuple takes one tuple");
            },
        }
    }

    fn parseArgs(self: *Parser, items: []Value, rule_call: bool) Error![]ir.Arg {
        const out = try self.arena.alloc(ir.Arg, items.len);
        for (items, out) |x, *a| {
            if (x.isSymbol()) {
                if (self.isSym(x, "$")) {
                    a.* = .src;
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
            const body = try self.parseClauses(parts[1..], false);
            try out.append(self.arena, .{ .name = name, .required = required, .head = try vars.toOwnedSlice(self.arena), .body = body });
        }
        // Group the bodies of one rule: `RuleSet.byName` is one slice.
        // The sort is stable, so bodies keep their source order.
        std.mem.sort(ir.Rule, out.items, {}, ruleNameLess);
        return out.toOwnedSlice(self.arena);
    }

    fn ruleNameLess(_: void, a: ir.Rule, b: ir.Rule) bool {
        return a.name < b.name;
    }
};

// =============================================================================
// Cache
// =============================================================================

fn CacheOf(comptime T: type, comptime parseFn: anytype) type {
    return struct {
        const Self = @This();
        const Entry = struct { query: Value, parsed: *T };

        gpa: Allocator,
        by_ptr: std.AutoHashMapUnmanaged(u64, *T) = .empty,
        by_hash: std.AutoHashMapUnmanaged(u64, std.ArrayList(Entry)) = .empty,

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.clear();
            self.by_ptr.deinit(self.gpa);
            self.by_hash.deinit(self.gpa);
        }

        /// Drop every entry.
        pub fn clear(self: *Self) void {
            var it = self.by_hash.valueIterator();
            while (it.next()) |bucket| {
                for (bucket.items) |e| e.parsed.deinit();
                bucket.deinit(self.gpa);
            }
            self.by_hash.clearRetainingCapacity();
            self.by_ptr.clearRetainingCapacity();
        }

        pub fn count(self: *const Self) usize {
            return self.by_ptr.count();
        }

        /// The parse of `query`, parsing on a miss. The result is owned
        /// by the cache.
        pub fn get(self: *Self, interner: *Interner, query: Value, diag: *Diag) Error!*T {
            const is_heap = query.kind().isHeap();
            if (is_heap) {
                if (self.by_ptr.get(query.payload)) |p| return p;
            }
            const h = dispatch.hashValue(query);
            const gop = try self.by_hash.getOrPut(self.gpa, h);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (gop.value_ptr.items) |e| {
                if (dispatch.equal(e.query, query)) {
                    if (is_heap) try self.by_ptr.put(self.gpa, query.payload, e.parsed);
                    return e.parsed;
                }
            }
            const parsed = try parseFn(self.gpa, interner, query, diag);
            errdefer parsed.deinit();
            try gop.value_ptr.append(self.gpa, .{ .query = query, .parsed = parsed });
            if (is_heap) try self.by_ptr.put(self.gpa, query.payload, parsed);
            return parsed;
        }
    };
}

pub const Cache = CacheOf(Ir, parse);
pub const RulesCache = CacheOf(RuleSet, parseRules);

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const heap_mod = @import("heap");

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

    // [:find ?n (count ?e) :in $ ?age [?tag ...] [[?a ?b]] %
    //  :with ?w
    //  :where [?e :user/name ?n] [?e :user/age ?age] [?e :user/tags ?tag]
    //         [(< ?age 40)] [(str ?n "!") ?w] (not [?e :user/bio _])
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
        b.kw("with"),
        b.sym("?w"),
        b.kw("where"),
        b.vec(&.{ b.sym("?e"), b.kw("user/name"), b.sym("?n") }),
        b.vec(&.{ b.sym("?e"), b.kw("user/age"), b.sym("?age") }),
        b.vec(&.{ b.sym("?e"), b.kw("user/tags"), b.sym("?tag") }),
        b.vec(&.{b.lst(&.{ b.sym("<"), b.sym("?age"), b.int(40) })}),
        b.vec(&.{ b.lst(&.{ b.sym("str"), b.sym("?n"), b.str("!") }), b.sym("?w") }),
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
    try testing.expect(parsed.find[1] == .agg and parsed.find[1].agg.op == .count);
    try testing.expectEqual(@as(usize, 5), parsed.in.len);
    try testing.expect(parsed.in[0] == .src and parsed.in[1] == .scalar and parsed.in[2] == .collection and parsed.in[3] == .relation and parsed.in[4] == .rules);
    try testing.expectEqual(@as(usize, 1), parsed.with.len);
    try testing.expectEqual(@as(usize, 10), parsed.where.len);
    try testing.expect(parsed.where[3] == .pred and parsed.where[3].pred.f.builtin == .lt);
    try testing.expect(parsed.where[4] == .bind and parsed.where[4].bind.call.f == .user);
    try testing.expect(parsed.where[5] == .not and parsed.where[5].not.join == null);
    try testing.expect(parsed.where[6] == .@"or" and parsed.where[6].@"or".branches.len == 2 and parsed.where[6].@"or".branches[1].len == 2);
    try testing.expect(parsed.where[7] == .rule);
    const last = parsed.where[9].pattern;
    try testing.expect(last.e == .constant and last.e.constant == .lookup);
    try testing.expect(last.v == .blank and last.tx == .variable and last.added.constant.cell.boolean);
    try testing.expectEqualStrings("?e", interner.symbolName(parsed.vars[1].sym));
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

    // or branches with different vars.
    const q6 = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.lst(&.{ b.sym("or"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?z") }) }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q6, &diag));

    // Unknown section.
    const q7 = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("keys"), b.sym("e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, q7, &diag));

    // Built-in arity and role are checked here, with a reason.
    for ([_]Value{
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("<"), b.sym("?v") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("<"), b.sym("?v"), b.int(3) }), b.sym("?x") }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("missing?"), b.sym("?e"), b.kw("a") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("ground"), b.int(1), b.int(2) }), b.sym("?x") }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("get-else"), b.sym("?e"), b.kw("a"), b.int(0) }), b.sym("?x") }) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{b.lst(&.{ b.sym("tuple"), b.sym("?v") })}) }),
        b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.sym("?v") }), b.vec(&.{ b.lst(&.{ b.sym("untuple"), b.sym("?v"), b.sym("?v") }), b.vec(&.{ b.sym("?x"), b.sym("?y") }) }) }),
    }) |bad_call| {
        try testing.expectError(error.QuerySyntax, parse(testing.allocator, &interner, bad_call, &diag));
        try testing.expect(diag.message.len > 0);
        try testing.expectEqual(@as(?usize, 1), diag.clause);
    }

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
    const p1 = try cache.get(&interner, q, &diag);
    const p2 = try cache.get(&interner, q, &diag);
    try testing.expect(p1 == p2);
    const q_again = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(1) }) });
    const p3 = try cache.get(&interner, q_again, &diag);
    try testing.expect(p1 == p3);
    try testing.expectEqual(@as(usize, 2), cache.count());
    const q_other = b.vec(&.{ b.kw("find"), b.sym("?e"), b.kw("where"), b.vec(&.{ b.sym("?e"), b.kw("a"), b.int(2) }) });
    const p4 = try cache.get(&interner, q_other, &diag);
    try testing.expect(p1 != p4);
}
