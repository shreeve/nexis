//! nextomic_fx.zig — the fixture the Nextomic integration tests share:
//! a connection under a temporary directory, a heap and an arena, a
//! reader from source text to VM values, transactions from source, and
//! the user functions a query may call.

const std = @import("std");
const nextomic = @import("nextomic");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const string_mod = @import("string");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ = @import("champ");
const dispatch = @import("dispatch");
const reader_mod = @import("reader");

const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = value.Value;
const Heap = heap_mod.Heap;
const Interner = intern_mod.Interner;
const query = nextomic.query;
const pull = nextomic.pull;
const DbValue = nextomic.DbValue;
const TestConn = nextomic.db.TestConn;

pub const Fx = struct {
    tc: *TestConn,
    heap: Heap,
    arena_state: std.heap.ArenaAllocator,
    diag: pull.Diag = .{},
    /// The allocator behind the heap, the arena and each pull's
    /// scratch: the testing allocator, or a plain one for a benchmark.
    gpa: Allocator,

    pub fn init(name: []const u8) !*Fx {
        return initWith(name, testing.allocator);
    }

    pub fn initWith(name: []const u8, gpa: Allocator) !*Fx {
        const self = try testing.allocator.create(Fx);
        self.* = .{
            .tc = try TestConn.init(name),
            .heap = Heap.init(gpa),
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
        };
        return self;
    }

    pub fn deinit(self: *Fx) void {
        self.arena_state.deinit();
        self.heap.deinit();
        self.tc.deinit();
        testing.allocator.destroy(self);
    }

    pub fn arena(self: *Fx) Allocator {
        return self.arena_state.allocator();
    }

    pub fn interner(self: *Fx) *Interner {
        return &self.tc.interner;
    }

    pub fn conn(self: *Fx) *nextomic.Conn {
        return self.tc.conn;
    }

    /// Read one form of source text into a VM value.
    pub fn read(self: *Fx, src: []const u8) !Value {
        var parsed = try reader_mod.parser.parseProgram(testing.allocator, src);
        defer parsed.parser.deinit();
        var rdr = reader_mod.Reader.init(testing.allocator, src);
        defer rdr.deinit();
        const forms = try rdr.readProgram(parsed.sexp);
        try testing.expectEqual(@as(usize, 1), forms.len);
        return self.formToValue(forms[0]);
    }

    pub fn formToValue(self: *Fx, form: *const reader_mod.Form) anyerror!Value {
        const a = self.arena();
        return switch (form.datum) {
            .nil => value.nilValue(),
            .bool_ => |b| value.fromBool(b),
            .int => |n| value.fromFixnum(n).?,
            .real => |d| value.fromFloat(d),
            .string => |s| try string_mod.fromBytes(&self.heap, s),
            .keyword => |name| try self.interner().internKeywordValue(try joinName(a, name)),
            .symbol => |name| try self.interner().internSymbolValue(try joinName(a, name)),
            .list => |items| blk: {
                const vals = try a.alloc(Value, items.len);
                for (items, vals) |it, *v| v.* = try self.formToValue(it);
                break :blk try list_mod.fromSlice(&self.heap, vals);
            },
            .vector => |items| blk: {
                const vals = try a.alloc(Value, items.len);
                for (items, vals) |it, *v| v.* = try self.formToValue(it);
                break :blk try vector_mod.fromSlice(&self.heap, vals);
            },
            .map => |items| blk: {
                var m = try champ.mapEmpty(&self.heap);
                var i: usize = 0;
                while (i < items.len) : (i += 2) {
                    m = try champ.mapAssoc(&self.heap, m, try self.formToValue(items[i]), try self.formToValue(items[i + 1]), &dispatch.hashValue, &dispatch.equal);
                }
                break :blk m;
            },
            .set => |items| blk: {
                var s = try champ.setEmpty(&self.heap);
                for (items) |it| s = try champ.setConj(&self.heap, s, try self.formToValue(it), &dispatch.hashValue, &dispatch.equal);
                break :blk s;
            },
            else => error.UnsupportedForm,
        };
    }

    pub fn joinName(a: Allocator, name: anytype) ![]const u8 {
        if (name.ns) |ns| return std.fmt.allocPrint(a, "{s}/{s}", .{ ns, name.name });
        return name.name;
    }

    pub fn transact(self: *Fx, src: []const u8) !nextomic.Report {
        const tx = try self.read(src);
        return nextomic.transact.transact(self.conn(), self.arena(), tx, .{});
    }

    pub fn db(self: *Fx) !DbValue {
        return self.conn().db();
    }

    /// A keyword by name, as a value and as its intern id.
    pub fn kw(self: *Fx, name: []const u8) !Value {
        return self.interner().internKeywordValue(name);
    }

    pub fn kwId(self: *Fx, name: []const u8) !u32 {
        return self.interner().internKeyword(name);
    }

    pub fn pullSrc(self: *Fx, dbv: DbValue, pattern: []const u8, entity: []const u8) anyerror!Value {
        return pull.pull(self.gpa, self.interner(), &self.heap, dbv, try self.read(pattern), try self.read(entity), &self.diag);
    }

    pub fn getName(self: *Fx, m: Value, name: []const u8) !?Value {
        return switch (champ.mapGet(m, try self.kw(name), &dispatch.hashValue, &dispatch.equal)) {
            .present => |v| v,
            .absent => null,
        };
    }

    pub fn q(self: *Fx, dbv: DbValue, src: []const u8) anyerror!Value {
        var diag: query.Diag = .{};
        return query.q(testing.allocator, self.interner(), &self.heap, try self.read(src), dbv, &.{value.nilValue()}, &diag, .{});
    }

    pub fn str(self: *Fx, s: []const u8) !Value {
        return string_mod.fromBytes(&self.heap, s);
    }

    pub fn hook(self: *Fx) query.CallHook {
        return .{ .ctx = @ptrCast(self), .call = &hookCall, .apply = &hookApply };
    }

    /// A value in function position: a symbol names one of the
    /// functions below, a keyword looks itself up in a map argument,
    /// anything else is not callable.
    pub fn hookApply(ctx: *anyopaque, f: Value, args: []const Value) anyerror!Value {
        switch (f.kind()) {
            .symbol => return hookCall(ctx, f.asSymbolId(), args),
            .keyword => {
                if (args.len == 0 or args[0].kind() != .persistent_map) return error.NotCallable;
                return switch (champ.mapGet(args[0], f, &dispatch.hashValue, &dispatch.equal)) {
                    .present => |v| v,
                    .absent => value.nilValue(),
                };
            },
            else => return error.NotCallable,
        }
    }

    /// The test's user functions.
    pub fn hookCall(ctx: *anyopaque, sym_id: u32, args: []const Value) anyerror!Value {
        const self: *Fx = @ptrCast(@alignCast(ctx));
        const name = self.interner().symbolName(sym_id);
        const a = self.arena();
        if (std.mem.eql(u8, name, "identity")) return args[0];
        if (std.mem.eql(u8, name, "inc")) return value.fromFixnum(args[0].asFixnum() + 1).?;
        if (std.mem.eql(u8, name, "add")) return value.fromFixnum(args[0].asFixnum() + args[1].asFixnum()).?;
        if (std.mem.eql(u8, name, "even?")) return value.fromBool(@mod(args[0].asFixnum(), 2) == 0);
        if (std.mem.eql(u8, name, "str")) {
            var out: std.ArrayList(u8) = .empty;
            for (args) |x| switch (x.kind()) {
                .string => try out.appendSlice(a, string_mod.asBytes(x)),
                .fixnum => try out.print(a, "{d}", .{x.asFixnum()}),
                .keyword => try out.print(a, ":{s}", .{self.interner().keywordName(x.asKeywordId())}),
                else => try out.appendSlice(a, "?"),
            };
            return string_mod.fromBytes(&self.heap, out.items);
        }
        if (std.mem.eql(u8, name, "upper")) {
            const s = string_mod.asBytes(args[0]);
            const out = try a.alloc(u8, s.len);
            for (s, out) |c, *o| o.* = std.ascii.toUpper(c);
            return string_mod.fromBytes(&self.heap, out);
        }
        if (std.mem.eql(u8, name, "range")) {
            const n: usize = @intCast(args[0].asFixnum());
            const vals = try a.alloc(Value, n);
            for (vals, 0..) |*v, i| v.* = value.fromFixnum(@intCast(i)).?;
            return vector_mod.fromSlice(&self.heap, vals);
        }
        if (std.mem.eql(u8, name, "pair")) return vector_mod.fromSlice(&self.heap, args[0..2]);
        if (std.mem.eql(u8, name, "count")) return value.fromFixnum(@intCast(string_mod.asBytes(args[0]).len)).?;
        if (std.mem.eql(u8, name, "subs")) {
            const s = string_mod.asBytes(args[0]);
            const from: usize = @intCast(args[1].asFixnum());
            const to: usize = if (args.len > 2) @intCast(args[2].asFixnum()) else s.len;
            return string_mod.fromBytes(&self.heap, s[from..to]);
        }
        if (std.mem.eql(u8, name, "halves")) {
            // [[n 0] [n 1]]
            const rows = try a.alloc(Value, 2);
            rows[0] = try vector_mod.fromSlice(&self.heap, &.{ args[0], value.fromFixnum(0).? });
            rows[1] = try vector_mod.fromSlice(&self.heap, &.{ args[0], value.fromFixnum(1).? });
            return vector_mod.fromSlice(&self.heap, rows);
        }
        if (std.mem.eql(u8, name, "maybe")) return if (args[0].asFixnum() > 30) args[0] else value.nilValue();
        if (std.mem.eql(u8, name, "total")) {
            // A custom aggregate: the sum of a vector of integers.
            var sum: i64 = 0;
            var it = vector_mod.Cursor.init(args[0]);
            while (it.next()) |x| sum += x.asFixnum();
            return value.fromFixnum(sum).?;
        }
        if (std.mem.eql(u8, name, "boom")) return error.ControlTransferred;
        return error.UnknownFunction;
    }
};
