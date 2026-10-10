//! vm.zig — the bytecode interpreter.
//!
//! Spec: `docs/VM.md`. This file holds:
//!
//!   - The 64-bit instruction encoding (`Inst`, `Operand`), the
//!     opcode groups, and the threaded dispatch through `op_table`.
//!   - `Routine`, a unit of compiled code with its constant pool,
//!     and `Closure`, a routine plus captured upvalue cells.
//!   - `Frame`s that window one shared backing `stack`; a call
//!     grows the stack into the callee's window and a return or an
//!     unwind restores the length the frame recorded on entry.
//!   - The handler stack behind `try`/`catch`/`finally`/`throw`,
//!     shared by bytecode throws and by natives (`throwValue`).
//!   - The numeric tower (`numAdd` … `numCompare`): the single
//!     implementation behind the `math:*` and `cmp:*` opcodes and
//!     the arithmetic natives.
//!   - `lookup`, the one implementation of `get`, `(:k m)`,
//!     `(m :k)`, `(s x)` and `(v i)`.
//!   - Namespaces, Vars and the namespace registry.

const std = @import("std");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");
const gc_mod = @import("gc.zig");
const bignum_mod = @import("bignum.zig");
const list_mod = @import("coll/list.zig");
const lazy_mod = @import("coll/lazy.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const transient_mod = @import("coll/transient.zig");
const dispatch_mod = @import("dispatch.zig");
const intern_mod = @import("intern.zig");
const string_mod = @import("string.zig");
const protocol_mod = @import("protocol.zig");
const record_mod = @import("record.zig");
const nextomic_handle = @import("nextomic/handle.zig");
const stack_guard = @import("stack.zig");
const build_options = @import("build_options");
const builtin = @import("builtin");
const Value = value_mod.Value;

// =============================================================================
// Instruction encoding (VM.md §3, §4): an instruction is 64 bits,
// [kind:4][group:6][variant:6][opA:16][opB:16][opC:16], an operand
// [kind:4][index:12], and B and C read together are the wide field.
// =============================================================================

/// An operand's kind (VM.md §4); `intern` and `durable` are reserved,
/// and any other bit pattern is `BytecodeCorruption`.
pub const OpKind = enum(u4) {
    slot = 0,
    constant = 1,
    var_ = 2,
    upvalue = 3,
    intern = 4,
    durable = 6,
    unused = 15,
    _,
};

pub const Operand = packed struct(u16) {
    kind: OpKind,
    index: u12,

    pub const none: Operand = .{ .kind = .unused, .index = 0 };

    pub fn slot(i: u12) Operand {
        return .{ .kind = .slot, .index = i };
    }
    pub fn constant(i: u12) Operand {
        return .{ .kind = .constant, .index = i };
    }
    pub fn upvalue(i: u12) Operand {
        return .{ .kind = .upvalue, .index = i };
    }
    pub fn varRef(i: u12) Operand {
        return .{ .kind = .var_, .index = i };
    }
};

/// `primary` is the one format; any other kind is `BytecodeCorruption`.
pub const InstKind = enum(u4) {
    primary = 0,
    _,
};

/// The opcode groups and each group's variants (VM.md §10, whose tables
/// say what each does). `transient`, `hash`, `tx`, `io` and `simd`
/// have no variants: an instruction in one traps `UnimplementedOpcode`,
/// as do the reserved `call:tailcall`, `math:pow` and `ctrl:halt`.
pub const Group = enum(u6) {
    jump = 0,
    cmp = 1,
    math = 2,
    mov = 3,
    call = 4,
    closure = 5,
    var_ = 6,
    coll = 7,
    transient = 8,
    hash = 9,
    tx = 10,
    ctrl = 11,
    io = 12,
    simd = 13,
    _,
};

pub const Mov = enum(u6) { move = 0, load_const = 1, load_nil = 2, load_true = 3, load_false = 4, move_clear = 5, _ };

pub const Call = enum(u6) { call = 0, tailcall = 1, @"return" = 2, return_nil = 3, self_ = 4, lookup = 5, lookup_or = 6, _ };

pub const Closure_ = enum(u6) { make = 0, box_local = 1, new_cell = 2, init_cell = 3, get_cell = 4, _ };

pub const Jump = enum(u6) { jmp = 0, if_true = 1, if_false = 2, _ };

/// Variant 4 is unassigned.
pub const CtrlOp = enum(u6) { try_enter = 0, try_exit = 1, finally_exit = 2, throw_ = 3, halt_ = 5, _ };

pub const CollOp = enum(u6) { list = 0, concat = 1, vector = 2, map = 3, set = 4, _ };

pub const VarOp = enum(u6) { load_var = 0, store_var = 1, var_object = 2, _ };

/// The variants share their numbers with `NumCmp`.
pub const Cmp = enum(u6) { lt = 0, lte = 1, gt = 2, gte = 3, eq_num = 4, _ };

pub const Math = enum(u6) { add = 0, sub = 1, mul = 2, div = 3, idiv = 4, mod = 5, pow = 6, neg = 7, abs = 8, _ };

/// A quickened variant (VM.md §10.10): a hot opcode specialized to
/// the operand kinds `quicken` found it with, so its fast handler
/// decodes no operand kind. It reads the operands of its base opcode,
/// whose general handler runs it past the fast handler's case, and
/// verification proves what the specialization promises (§5).
pub const Quick = struct {
    /// The base opcode's variant.
    base: u6,
    form: Form,
    then: Then = .none,
    /// A counting loop's step: the quickened comparison after a
    /// `math:add` of a slot and a fixnum constant, reading the sum as
    /// its B, which the add runs with the comparison's jump (`then`)
    /// as one dispatch.
    step: ?Step = null,

    pub const Form = enum(u3) {
        /// `mov:move` and `call:return`: the value read is a slot.
        slot,
        /// `math` and `cmp`: B and C are slots.
        slot_slot,
        /// `math` and `cmp`: B is a slot, C a constant holding a fixnum.
        slot_fixnum,
        /// `math`: B is a constant holding a fixnum, C a slot.
        fixnum_slot,
        /// `mov:move`: the value read is an upvalue.
        upvalue,
    };

    /// The conditional jump after a quickened comparison, testing the
    /// comparison's slot: the pair it runs as one dispatch (§8).
    pub const Then = enum(u2) { none, if_true, if_false };

    /// The comparison a step runs: an ordered one, of slots or of a
    /// slot and a fixnum constant.
    pub const Step = struct { cmp: NumCmp, form: Form };

    /// The `math` variants with quickened forms: those with a fast
    /// handler.
    const math_bases = [_]Math{ .add, .sub, .mul, .idiv, .mod };

    /// The variant `q` takes in `group`, or null when `group` has no
    /// such quickened variant. `math` keeps its steps at 16-31, `math`,
    /// `mov` and `call` their other quickened variants at 32-63 and
    /// `cmp` at 16-63, so each group's base variants keep the numbers
    /// below.
    pub fn variant(group: Group, q: Quick) ?u6 {
        if (q.step != null and group != .math) return null;
        switch (group) {
            .math => {
                if (q.step) |s| {
                    if (q.base != @backingInt(Math.add) or q.form != .slot_fixnum or q.then == .none or
                        @backingInt(s.cmp) > @backingInt(NumCmp.gte) or (s.form != .slot_slot and s.form != .slot_fixnum)) return null;
                    const k: u6 = (@as(u6, @backingInt(q.then)) - 1) * 2 + @intFromBool(s.form == .slot_fixnum);
                    return 16 + 4 * k + @backingInt(s.cmp);
                }
                if (q.then != .none or std.mem.findScalar(Math, &math_bases, @fromBackingInt(q.base)) == null) return null;
                return switch (q.form) {
                    .slot_slot => 32 + q.base,
                    .fixnum_slot => 40 + q.base,
                    .slot_fixnum => 48 + q.base,
                    .slot, .upvalue => null,
                };
            },
            .cmp => {
                if (q.base > @backingInt(Cmp.eq_num) or (q.form != .slot_slot and q.form != .slot_fixnum)) return null;
                const k: u6 = @as(u6, @backingInt(q.then)) * 2 + @intFromBool(q.form == .slot_fixnum);
                return 16 + 8 * k + q.base;
            },
            .mov => return if (q.base != @backingInt(Mov.move) or q.then != .none) null else switch (q.form) {
                .slot => 32,
                .upvalue => 33,
                else => null,
            },
            .call => return if (q.base == @backingInt(Call.@"return") and q.form == .slot and q.then == .none) 32 else null,
            else => return null,
        }
    }

    /// Every quickened variant by opcode index (`VM.opIndex`).
    const table: [4096]?Quick = blk: {
        @setEvalBranchQuota(100_000);
        var t: [4096]?Quick = @splat(null);
        for ([_]Group{ .math, .cmp, .mov, .call }) |g| {
            for (0..64) |base| for (std.meta.tags(Form)) |form| for (std.meta.tags(Then)) |then| {
                const q = Quick{ .base = base, .form = form, .then = then };
                if (variant(g, q)) |v| t[@as(u12, @backingInt(g)) | @as(u12, v) << 6] = q;
            };
        }
        for ([_]Then{ .if_true, .if_false }) |then| for ([_]Form{ .slot_slot, .slot_fixnum }) |form| for (std.meta.tags(NumCmp)) |c| {
            const q = Quick{ .base = @backingInt(Math.add), .form = .slot_fixnum, .then = then, .step = .{ .cmp = c, .form = form } };
            if (variant(.math, q)) |v| t[@as(u12, @backingInt(Group.math)) | @as(u12, v) << 6] = q;
        };
        break :blk t;
    };

    /// The quickened comparison a step runs, with its jump.
    pub fn stepCmp(q: Quick) ?Quick {
        const s = q.step orelse return null;
        return .{ .base = @backingInt(s.cmp), .form = s.form, .then = q.then };
    }

    /// The quickened variant at opcode index `op`, or null for any
    /// other opcode.
    pub fn of(op: u12) ?Quick {
        return table[op];
    }
};

/// Rewrite each instruction of `code` whose operands a quickened
/// variant takes into that variant (VM.md §10.10): a `math` or `cmp`
/// instruction of slots, or of a slot and a fixnum constant from
/// `consts` (a comparison followed by a conditional jump on its slot
/// says so too), a `math` instruction of a fixnum constant and a
/// slot, a `mov:move` reading a slot or an upvalue, and a
/// `call:return` reading a slot; then each `math:add` of a slot and a
/// fixnum constant followed by a quickened ordered comparison of its
/// sum with its jump, a counting loop's step and bottom test, into the
/// step that runs the three.
/// Only the variant changes: an instruction keeps its operands, so
/// its pc, span and trace are the ones it had.
pub fn quicken(code: []Inst, consts: []const Value) void {
    for (code, 0..) |*inst, pc| {
        if (inst.kind != .primary) continue;
        const group = inst.groupOf();
        var q = Quick{ .base = inst.variant, .form = .slot };
        switch (group) {
            .mov => q.form = switch (inst.b.kind) {
                .slot => .slot,
                .upvalue => .upvalue,
                else => continue,
            },
            .call => if (inst.a.kind != .slot) continue,
            .math, .cmp => {
                const fixnum = struct {
                    fn at(op: Operand, pool: []const Value) bool {
                        return op.kind == .constant and op.index < pool.len and pool[op.index].isFixnum();
                    }
                }.at;
                const b = inst.b;
                const c = inst.c;
                q.form = if (b.kind == .slot and c.kind == .slot)
                    .slot_slot
                else if (b.kind == .slot and fixnum(c, consts))
                    .slot_fixnum
                else if (fixnum(b, consts) and c.kind == .slot)
                    .fixnum_slot
                else
                    continue;
                if (group == .cmp and pc + 1 < code.len) {
                    const next: u32 = @truncate(@as(u64, @bitCast(code[pc + 1])));
                    if (next == VM.condJumpKey(.if_true, inst.a)) q.then = .if_true;
                    if (next == VM.condJumpKey(.if_false, inst.a)) q.then = .if_false;
                }
            },
            else => continue,
        }
        inst.variant = Quick.variant(group, q) orelse continue;
    }
    if (code.len < 2) return;
    for (code[0 .. code.len - 1], code[1..]) |*inst, next| {
        const q = Quick.of(VM.opIndex(inst.*)) orelse continue;
        const c = Quick.of(VM.opIndex(next)) orelse continue;
        if (inst.groupOf() != .math or next.groupOf() != .cmp or c.then == .none) continue;
        if (@as(u16, @bitCast(next.b)) != @as(u16, @bitCast(inst.a))) continue;
        const step = Quick{ .base = q.base, .form = q.form, .then = c.then, .step = .{ .cmp = @fromBackingInt(c.base), .form = c.form } };
        inst.variant = Quick.variant(.math, step) orelse continue;
    }
}

/// Packed 64-bit instruction. Field order matches VM.md §3:
/// [kind:4][group:6][variant:6][opA:16][opB:16][opC:16].
pub const Inst = packed struct(u64) {
    kind: InstKind,
    group: u6,
    variant: u6,
    a: Operand,
    b: Operand,
    c: Operand,

    pub fn primary(g: Group, v: anytype, a: Operand, b: Operand, c: Operand) Inst {
        return .{
            .kind = .primary,
            .group = @backingInt(g),
            .variant = @intCast(@backingInt(v)),
            .a = a,
            .b = b,
            .c = c,
        };
    }

    /// An instruction whose B and C carry the 32-bit field `w`.
    pub fn primaryWide(g: Group, v: anytype, a: Operand, w: u32) Inst {
        var inst = primary(g, v, a, Operand.none, Operand.none);
        inst.setWide(w);
        return inst;
    }

    /// B and C read as one 32-bit field, B the low half (VM.md §3):
    /// a pc, or an index into the constants, the Var table or the
    /// capture descriptors.
    pub inline fn wide(self: Inst) u32 {
        return @truncate(@as(u64, @bitCast(self)) >> 32);
    }

    pub fn setWide(self: *Inst, w: u32) void {
        const bits: u64 = @bitCast(self.*);
        self.* = @bitCast((bits & 0xFFFF_FFFF) | (@as(u64, w) << 32));
    }

    pub fn groupOf(self: Inst) Group {
        return @fromBackingInt(@intCast(self.group));
    }
};

comptime {
    std.debug.assert(@sizeOf(Inst) == 8);
    std.debug.assert(@sizeOf(Operand) == 2);
}

// =============================================================================
// Routine (VM.md §5): a plain struct, not a heap value
// =============================================================================

/// Where one upvalue cell of a closure comes from (VM.md §6): the cell
/// in a slot of the frame making it, or one of the frame's own.
pub const CaptureSource = union(enum) {
    local_cell_slot: u12,
    inherited_upvalue: u12,
};

/// One `try` form of a routine: where its catch body starts and,
/// when it has one, its finally body. `ctrl:try-enter` names it by
/// index, since one instruction carries one 32-bit pc.
pub const Try = struct {
    catch_pc: u32,
    finally_pc: ?u32 = null,
};

/// What one `closure:make` builds: a closure over `routine` whose
/// upvalue cells come from `sources`, one per upvalue, in order.
pub const CaptureDescriptor = struct {
    routine: *const Routine,
    sources: []const CaptureSource,
};

/// The clauses of a multi-arity `fn`, one routine each (VM.md §5):
/// `fixed[i]` is the clause taking exactly `i` arguments, null where
/// none does, and `rest` the clause with a rest parameter. Every
/// member points at the table; a closure names its first clause, and
/// a call enters the member its argument count picks (§6).
pub const Arities = struct {
    fixed: []const ?*const Routine,
    rest: ?*const Routine = null,

    /// Every member, by arity, the rest clause last.
    pub fn members(self: *const Arities) Members {
        return .{ .table = self };
    }

    pub const Members = struct {
        table: *const Arities,
        i: usize = 0,

        pub fn next(it: *Members) ?*const Routine {
            const fixed = it.table.fixed;
            while (it.i < fixed.len) {
                it.i += 1;
                if (fixed[it.i - 1]) |r| return r;
            }
            if (it.i > fixed.len) return null;
            it.i += 1;
            return it.table.rest;
        }
    };
};

/// A byte range of a source text: the span the reader gives a Form,
/// carried by the compiler to the instructions lowered from it.
pub const SourceSpan = struct {
    pos: u32,
    len: u32,
};

/// One run of instructions lowered from the same form: every pc
/// from `pc` up to the next entry's pc carries `span`.
pub const SpanEntry = struct {
    pc: u32,
    span: SourceSpan,
};

/// The text a routine was compiled from and the path it is reported
/// under. Owned by whoever compiled the routine and outlives it.
pub const SourceInfo = struct {
    path: []const u8,
    text: []const u8,
    /// The text is the standard library's (`stdlib.embedded`): an
    /// error value is placed at the program's call into it instead
    /// (`VM.raiseSite`).
    library: bool = false,

    pub const LineCol = struct { line: u32, col: u32 };

    /// 1-based line and column of byte offset `pos`, the column in
    /// code points and past a leading byte-order mark, as an error
    /// report shows it; an offset past the end lands on the last
    /// position.
    pub fn lineCol(self: *const SourceInfo, pos: u32) LineCol {
        const before = self.text[0..@min(pos, self.text.len)];
        return .{ .line = @intCast(1 + std.mem.count(u8, before, "\n")), .col = columnOf(before) };
    }

    /// `lineCol(pos)` found from `from`, the place of `from_pos`: only
    /// the text between the two positions is scanned, or the text
    /// before `pos` when that is shorter, so places found one from the
    /// last cost the distance moved.
    pub fn lineColFrom(self: *const SourceInfo, from_pos: u32, from: LineCol, pos: u32) LineCol {
        const a = @min(from_pos, self.text.len);
        const b = @min(pos, self.text.len);
        // Near the start, a byte-order mark included, from 0.
        if (@min(a, b) <= bom.len or (b < a and b <= a - b)) return self.lineCol(pos);
        const between = if (a <= b) self.text[a..b] else self.text[b..a];
        const lines: u32 = @intCast(std.mem.count(u8, between, "\n"));
        if (a <= b) return .{ .line = from.line + lines, .col = if (lines == 0) from.col + codePoints(between) else columnOf(between) };
        return .{ .line = from.line - lines, .col = if (lines == 0) from.col - codePoints(between) else columnOf(self.text[0..b]) };
    }

    const bom = "\xEF\xBB\xBF";

    /// The column at the end of `before`, a text from its start.
    fn columnOf(before: []const u8) u32 {
        const start = if (std.mem.findScalarLast(u8, before, '\n')) |nl| nl + 1 else if (std.mem.startsWith(u8, before, bom)) bom.len else 0;
        return 1 + codePoints(before[start..]);
    }

    fn codePoints(bytes: []const u8) u32 {
        var n: u32 = 0;
        for (bytes) |c| n += @intFromBool(c & 0xC0 != 0x80);
        return n;
    }
};

/// The fields are VM.md §5's table.
pub const Routine = struct {
    code: []const Inst,
    consts: []const Value,
    capture_descs: []const CaptureDescriptor = &.{},
    tries: []const Try = &.{},
    slot_count: u16,
    fixed_arity: u16 = 0,
    /// A rest parameter at slot `fixed_arity`.
    variadic: bool = false,
    arities: ?*const Arities = null,
    upvalue_count: u16 = 0,
    var_table: []const *Var = &.{},
    name: []const u8 = "<anonymous>",
    /// Ascending by pc, empty for a routine built by hand; only the
    /// error path and the disassembler read it.
    spans: []const SpanEntry = &.{},
    origin: ?SourceSpan = null,
    source: ?*const SourceInfo = null,

    /// Prove the routine, the other members of its arity table, and
    /// every routine their capture descriptors build, fit to run (VM.md
    /// §5): every instruction `primary` with an assigned opcode, every
    /// operand inside the table it indexes and of a kind its position
    /// takes, every call or collection block inside the frame, every
    /// jump, `try` and capture inside the routine, the last instruction
    /// one that never falls through, so execution cannot run off the
    /// code, and the arity table one a call can pick from. The dispatch
    /// trusts all of it (§8). On an error `failure` names the routine
    /// and the instruction. Whatever the routine holds, verification
    /// returns an error and never traps.
    pub fn verify(self: *const Routine, failure: *VerifyFailure) VmError!void {
        failure.* = .{ .routine = self, .pc = 0 };
        stack_guard.check() catch return VmError.StackOverflow;
        try self.verifyClause(failure);
        // A closure over this routine runs whichever member its call
        // picks; `verifyAlone` proved this one sits in the table.
        const a = self.arities orelse return;
        var members = a.members();
        while (members.next()) |r| if (r != self) try r.verifyClause(failure);
    }

    /// `verifyAlone`, then `verify` of every routine the capture
    /// descriptors build.
    fn verifyClause(self: *const Routine, failure: *VerifyFailure) VmError!void {
        try self.verifyAlone(failure);
        for (self.capture_descs) |desc| try desc.routine.verify(failure);
    }

    /// `verify` of this routine without the routines its capture
    /// descriptors build or the other members of its table, whose
    /// shape it does prove: for a loader that verifies every routine
    /// it made, each once (`image.zig`).
    pub fn verifyAlone(self: *const Routine, failure: *VerifyFailure) VmError!void {
        const code = self.code;
        failure.* = .{ .routine = self, .pc = 0 };
        // A pc is 32 bits (§3): a longer routine is refused before any
        // of it is read.
        if (code.len > std.math.maxInt(u32)) return VmError.BytecodeCorruption;
        if (self.arities) |a| try self.verifyTable(a);
        // The code's end is reported at its last instruction, as a run
        // that falls off it is (§13).
        failure.* = .{ .routine = self, .pc = @intCast(code.len -| 1) };
        if (code.len == 0 or !neverFallsThrough(code[code.len - 1])) return VmError.BytecodeExhausted;
        for (code, 0..) |inst, i| {
            failure.pc = @intCast(i);
            try self.verifyInst(inst, i);
        }
    }

    /// The arity table `a`, as a member sees it (§5): the member sits
    /// in it at its own arity, or as its rest clause; every member
    /// points at it and carries the member's upvalue count; each fixed
    /// entry takes exactly its index and the last is a clause; the rest
    /// clause takes at least every fixed count (Clojure's rule); and
    /// the table has two members at least.
    fn verifyTable(self: *const Routine, a: *const Arities) VmError!void {
        const home = if (self.variadic) a.rest else if (self.fixed_arity < a.fixed.len) a.fixed[self.fixed_arity] else null;
        if (home == null or home.? != self) return VmError.BytecodeCorruption;
        if (a.fixed.len > 0 and a.fixed[a.fixed.len - 1] == null) return VmError.BytecodeCorruption;
        var members: usize = 0;
        for (a.fixed, 0..) |entry, i| {
            const m = entry orelse continue;
            if (m.variadic or m.fixed_arity != i) return VmError.BytecodeCorruption;
            try self.verifySibling(m, a);
            members += 1;
        }
        if (a.rest) |m| {
            if (!m.variadic or @as(usize, m.fixed_arity) + 1 < a.fixed.len) return VmError.BytecodeCorruption;
            try self.verifySibling(m, a);
            members += 1;
        }
        if (members < 2) return VmError.BytecodeCorruption;
    }

    fn verifySibling(self: *const Routine, m: *const Routine, a: *const Arities) VmError!void {
        if (m.arities != a) return VmError.BytecodeCorruption;
        // One closure's cells serve every member.
        if (m.upvalue_count != self.upvalue_count) return VmError.CaptureCountMismatch;
    }

    /// The fixed-arity routine that takes exactly `argc` arguments:
    /// this one, as for a routine with one arity, or a member of its
    /// table; null when none does. The direct call paths (§8) ask only
    /// this.
    pub inline fn memberFor(self: *const Routine, argc: usize) ?*const Routine {
        if (argc == self.fixed_arity and !self.variadic) return self;
        const a = self.arities orelse return null;
        return if (argc < a.fixed.len) a.fixed[argc] else null;
    }

    /// The routine a call of a closure over this one enters with
    /// `argc` arguments (§6): the fixed-arity member that takes them,
    /// else the rest clause when `argc` reaches its fixed arity; null
    /// when none takes `argc`.
    pub fn entryFor(self: *const Routine, argc: usize) ?*const Routine {
        if (self.memberFor(argc)) |m| return m;
        const rest = if (self.arities) |a| a.rest orelse return null else if (self.variadic) self else return null;
        return if (argc >= rest.fixed_arity) rest else null;
    }

    /// The argument counts a closure over this routine takes, as an
    /// arity error names them (§13): `1 argument`, `at least 2
    /// arguments`, `0 to 2 arguments`, `1, 3 or at least 5 arguments`.
    pub fn arityPhrase(self: *const Routine) ArityPhrase {
        return .{ .routine = self };
    }

    fn neverFallsThrough(inst: Inst) bool {
        const op = baseOp(VM.opIndex(inst));
        return op == VM.opcode(.jump, Jump.jmp) or op == VM.opcode(.call, Call.@"return") or
            op == VM.opcode(.call, Call.return_nil) or op == VM.opcode(.ctrl, CtrlOp.throw_) or
            op == VM.opcode(.ctrl, CtrlOp.try_exit) or op == VM.opcode(.ctrl, CtrlOp.finally_exit);
    }

    /// The base opcode of a quickened one (§10.10), else `op` itself.
    fn baseOp(op: u12) u12 {
        const q = Quick.of(op) orelse return op;
        return (op & 0x3F) | @as(u12, q.base) << 6;
    }

    /// What an operand position holds: nothing read, a destination
    /// slot, a slot read as such (a call block's base, a cell), a value
    /// read through any operand kind, a raw count (§4.5), a keyword or
    /// symbol constant, a constant holding a fixnum, or an upvalue.
    pub const Role = enum { none, dst, slot, src, raw, key, fixnum, upvalue };
    /// What a wide field (§3) indexes.
    pub const WideRole = enum { pc, constant, var_, capture, try_ };
    /// `block`: A and B name a call or collection block; `pair`: B
    /// names two slots; `then`: the next instruction is the
    /// conditional jump on A that a quickened comparison runs; `step`:
    /// the next instruction is the quickened comparison at this opcode
    /// index, reading A as its B, that a step runs.
    pub const Shape = struct { a: Role = .none, b: Role = .none, c: Role = .none, wide: ?WideRole = null, block: bool = false, pair: bool = false, then: Quick.Then = .none, step: ?u12 = null };

    /// The shape of the opcode at `op`, null for one with no
    /// operands to prove: an unimplemented one traps where it runs. A
    /// quickened opcode has its base's shape with the kinds its form
    /// promises (§10.10).
    pub fn shapeOf(op: u12) ?Shape {
        if (Quick.of(op)) |q| {
            var shape = baseShapeOf(baseOp(op)).?;
            switch (q.form) {
                .slot => if (shape.b == .src) {
                    shape.b = .slot;
                } else {
                    shape.a = .slot;
                },
                .upvalue => shape.b = .upvalue,
                .slot_slot => shape = .{ .a = .dst, .b = .slot, .c = .slot },
                .slot_fixnum => shape = .{ .a = .dst, .b = .slot, .c = .fixnum },
                .fixnum_slot => shape = .{ .a = .dst, .b = .fixnum, .c = .slot },
            }
            shape.then = q.then;
            if (Quick.stepCmp(q)) |c| {
                shape.then = .none;
                shape.step = @as(u12, @backingInt(Group.cmp)) | @as(u12, Quick.variant(.cmp, c).?) << 6;
            }
            return shape;
        }
        return baseShapeOf(op);
    }

    fn baseShapeOf(op: u12) ?Shape {
        const g: Group = @fromBackingInt(@as(u6, @truncate(op)));
        const v: u6 = @truncate(op >> 6);
        return switch (g) {
            .jump => switch (@as(Jump, @fromBackingInt(v))) {
                .jmp => .{ .wide = .pc },
                .if_true, .if_false => .{ .a = .src, .wide = .pc },
                _ => null,
            },
            .cmp => .{ .a = .dst, .b = .src, .c = .src },
            .math => switch (@as(Math, @fromBackingInt(v))) {
                .neg, .abs => .{ .a = .dst, .b = .src },
                .pow, _ => null,
                else => .{ .a = .dst, .b = .src, .c = .src },
            },
            .mov => switch (@as(Mov, @fromBackingInt(v))) {
                .move => .{ .a = .dst, .b = .src },
                .move_clear => .{ .a = .dst, .b = .slot },
                .load_const => .{ .a = .dst, .wide = .constant },
                .load_nil, .load_true, .load_false => .{ .a = .dst },
                _ => null,
            },
            .call => switch (@as(Call, @fromBackingInt(v))) {
                .call, .self_ => .{ .a = .slot, .b = .raw, .c = .dst, .block = true },
                .lookup => .{ .a = .dst, .b = .src, .c = .key },
                .lookup_or => .{ .a = .dst, .b = .slot, .c = .key, .pair = true },
                .@"return" => .{ .a = .src },
                .return_nil, .tailcall, _ => null,
            },
            .closure => switch (@as(Closure_, @fromBackingInt(v))) {
                .make => .{ .a = .dst, .wide = .capture },
                .box_local, .new_cell => .{ .a = .slot },
                .init_cell => .{ .a = .slot, .b = .src },
                .get_cell => .{ .a = .dst, .b = .slot },
                _ => null,
            },
            .var_ => switch (@as(VarOp, @fromBackingInt(v))) {
                .load_var, .var_object => .{ .a = .dst, .wide = .var_ },
                .store_var => .{ .a = .src, .wide = .var_ },
                _ => null,
            },
            .coll => .{ .a = .slot, .b = .raw, .c = .dst, .block = true },
            .ctrl => switch (@as(CtrlOp, @fromBackingInt(v))) {
                .try_enter => .{ .a = .slot, .wide = .try_ },
                .try_exit => .{ .wide = .pc },
                .throw_ => .{ .a = .src },
                .finally_exit, .halt_, _ => null,
            },
            else => null,
        };
    }

    fn verifyInst(self: *const Routine, inst: Inst, pc: usize) VmError!void {
        if (inst.kind != .primary) return VmError.BytecodeCorruption;
        const op = VM.opIndex(inst);
        if (VM.op_table[op] == &VM.opCorrupt) return VmError.BytecodeCorruption;
        const shape = shapeOf(op) orelse return;
        try self.verifyOperand(inst.a, shape.a);
        if (shape.then != .none) {
            const variant: Jump = if (shape.then == .if_true) .if_true else .if_false;
            if (pc + 1 >= self.code.len) return VmError.BytecodeExhausted;
            if (@as(u32, @truncate(@as(u64, @bitCast(self.code[pc + 1])))) != VM.condJumpKey(variant, inst.a)) return VmError.BytecodeCorruption;
        }
        // The comparison's own form proves its operands and its jump.
        if (shape.step) |cmp| {
            if (pc + 1 >= self.code.len) return VmError.BytecodeExhausted;
            const next = self.code[pc + 1];
            if (VM.opIndex(next) != cmp or @as(u16, @bitCast(next.b)) != @as(u16, @bitCast(inst.a))) return VmError.BytecodeCorruption;
        }
        if (shape.wide) |w| {
            const i = inst.wide();
            const len = switch (w) {
                .pc => self.code.len,
                .constant => self.consts.len,
                .var_ => self.var_table.len,
                .capture => self.capture_descs.len,
                .try_ => self.tries.len,
            };
            if (i >= len) return VmError.OperandOutOfRange;
            if (w == .try_) {
                const t = self.tries[i];
                if (t.catch_pc >= self.code.len or (t.finally_pc orelse 0) >= self.code.len) return VmError.OperandOutOfRange;
            }
            if (w == .capture) {
                const desc = self.capture_descs[i];
                if (desc.sources.len != desc.routine.upvalue_count) return VmError.CaptureCountMismatch;
                for (desc.sources) |source| switch (source) {
                    .local_cell_slot => |slot| if (slot >= self.slot_count) return VmError.OperandOutOfRange,
                    .inherited_upvalue => |u| if (u >= self.upvalue_count) return VmError.UpvalueOutOfRange,
                };
            }
            return;
        }
        try self.verifyOperand(inst.b, shape.b);
        try self.verifyOperand(inst.c, shape.c);
        // `call:call`'s callee and arguments, `call:self`'s arguments, a
        // `coll` opcode's elements.
        if (shape.block) {
            const is_call = inst.groupOf() == .call;
            const self_call = op == VM.opcode(.call, Call.self_);
            const end = @as(u32, inst.a.index) + inst.b.index + @intFromBool(is_call and !self_call);
            if (end > self.slot_count) return if (is_call) VmError.CallBlockOutOfRange else VmError.OperandOutOfRange;
            // A self-call enters a fixed arity of this routine's table,
            // its own or a sibling's; `verifyTable` proved the table.
            if (self_call and self.memberFor(inst.b.index) == null) return VmError.BytecodeCorruption;
        }
        if (shape.pair and @as(u32, inst.b.index) + 2 > self.slot_count) return VmError.OperandOutOfRange;
    }

    fn verifyOperand(self: *const Routine, op: Operand, role: Role) VmError!void {
        switch (role) {
            .none, .raw => {},
            .dst, .slot => {
                if (op.kind != .slot) return VmError.InvalidOperandKind;
                if (op.index >= self.slot_count) return VmError.OperandOutOfRange;
            },
            .key, .fixnum => {
                if (op.kind != .constant) return VmError.InvalidOperandKind;
                if (op.index >= self.consts.len) return VmError.OperandOutOfRange;
                const k = self.consts[op.index].kind();
                if (if (role == .key) k != .keyword and k != .symbol else k != .fixnum) return VmError.InvalidOperandKind;
            },
            .upvalue => {
                if (op.kind != .upvalue) return VmError.InvalidOperandKind;
                if (op.index >= self.upvalue_count) return VmError.UpvalueOutOfRange;
            },
            // Another kind traps where it is read, as `resolveOther`
            // says.
            .src => switch (op.kind) {
                .slot => if (op.index >= self.slot_count) return VmError.OperandOutOfRange,
                .constant => if (op.index >= self.consts.len) return VmError.OperandOutOfRange,
                .var_ => if (op.index >= self.var_table.len) return VmError.OperandOutOfRange,
                .upvalue => if (op.index >= self.upvalue_count) return VmError.UpvalueOutOfRange,
                else => {},
            },
        }
    }

    /// The source span of the instruction at `pc`, or null when the
    /// table has no entry at or before it.
    pub fn spanAt(self: *const Routine, pc: u32) ?SourceSpan {
        var lo: usize = 0;
        var hi: usize = self.spans.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.spans[mid].pc <= pc) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        return self.spans[lo - 1].span;
    }
};

/// `Routine.arityPhrase`: the counts a closure over `routine` takes,
/// for `{f}`, each less `hidden`, the leading parameters a caller
/// passes unseen (a macro's `&form` and `&env`).
pub const ArityPhrase = struct {
    routine: *const Routine,
    hidden: u8 = 0,

    const Item = union(enum) { one: usize, range: [2]usize, at_least: usize };

    /// The phrase's items in order: a run of three or more fixed counts
    /// as a range, any other fixed count alone, then the rest clause's
    /// bound, which takes in the fixed counts just below it.
    const Items = struct {
        table: ?[]const ?*const Routine,
        /// The one count of a routine with no table and no rest.
        only: usize,
        /// The fixed counts listed are those below `limit`.
        limit: usize,
        rest: ?usize,
        i: usize = 0,

        fn init(r: *const Routine) Items {
            const a = r.arities orelse return if (r.variadic)
                .{ .table = null, .only = 0, .limit = 0, .rest = r.fixed_arity }
            else
                .{ .table = null, .only = r.fixed_arity, .limit = @as(usize, r.fixed_arity) + 1, .rest = null };
            var it: Items = .{ .table = a.fixed, .only = 0, .limit = a.fixed.len, .rest = null };
            if (a.rest) |v| {
                var n: usize = v.fixed_arity;
                while (n > 0 and it.has(n - 1)) n -= 1;
                it.limit = n;
                it.rest = n;
            }
            return it;
        }

        fn has(it: *const Items, n: usize) bool {
            return if (it.table) |t| n < t.len and t[n] != null else n == it.only;
        }

        fn next(it: *Items) ?Item {
            while (it.i < it.limit and !it.has(it.i)) it.i += 1;
            if (it.i < it.limit) {
                const lo = it.i;
                var hi = lo;
                while (hi + 1 < it.limit and it.has(hi + 1)) hi += 1;
                if (hi - lo >= 2) {
                    it.i = hi + 1;
                    return .{ .range = .{ lo, hi } };
                }
                it.i = lo + 1;
                return .{ .one = lo };
            }
            const n = it.rest orelse return null;
            it.rest = null;
            return .{ .at_least = n };
        }
    };

    pub fn format(self: ArityPhrase, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const h = self.hidden;
        var it = Items.init(self.routine);
        var count: usize = 0;
        var singular = false;
        while (it.next()) |item| : (count += 1) singular = switch (item) {
            .one, .at_least => |n| n -| h == 1,
            .range => false,
        };
        it = Items.init(self.routine);
        var i: usize = 0;
        while (it.next()) |item| : (i += 1) {
            if (i > 0) try w.writeAll(if (i + 1 == count) " or " else ", ");
            switch (item) {
                .one => |n| try w.print("{d}", .{n -| h}),
                .range => |r| try w.print("{d} to {d}", .{ r[0] -| h, r[1] -| h }),
                .at_least => |n| try w.print("at least {d}", .{n -| h}),
            }
        }
        try w.writeAll(if (count == 1 and singular) " argument" else " arguments");
    }
};

/// Where `Routine.verify` found a routine unfit to run: the routine and
/// the instruction.
pub const VerifyFailure = struct { routine: *const Routine, pc: u32 };

/// A namespace's mutable binding of a name (VM.md §10.7): `def` of
/// the name again updates the same Var, so code compiled against it
/// sees the new root, and a forward reference compiles against a Var
/// still unbound, which traps `:unbound-var` only if read before its
/// `def`. A Var lives in `VM.runtime_arena` for the VM's life and the
/// Value is the raw `*Var`: Vars are immortal, and the collector reaches
/// their values through the namespaces (GC.md §3).
pub const Var = struct {
    /// The name, owned by the Var's namespace.
    name: []const u8,
    /// The namespace's name, for `#'ns/name`; empty for a bare
    /// `Namespace`.
    ns: []const u8 = "",
    root: Value = value_mod.nilValue(),
    /// Set once `def` has set the root: a nil root may be bound.
    bound: bool = false,
    /// Set by `defmacro` alone: the expander calls the Var's value at
    /// compile time (MACROEXPAND.md §1.2).
    macro: bool = false,
    /// The metadata map, or nil.
    meta: Value = value_mod.nilValue(),
    /// Set once the metadata has carried `:dynamic true`, never cleared
    /// (VM.md §6.5).
    dynamic: bool = false,
    /// The binding in force when `thread_bound` (VM.md §6.5).
    thread_value: Value = value_mod.nilValue(),
    thread_bound: bool = false,

    /// The value in force: the binding under `binding`, else the
    /// root; null while unbound. A load, a call through the Var and
    /// `deref` all read this.
    pub fn current(self: *const Var) ?Value {
        if (self.thread_bound) return self.thread_value;
        return if (self.bound) self.root else null;
    }
};

/// Names to Vars (STDLIB.md §8). A VM's namespaces live in its
/// `NamespaceRegistry`; a bare `Namespace` with no registry is the one
/// namespace of a VM built by hand. The Vars and names live in
/// `var_allocator` (the VM's runtime arena), the maps in
/// `map_allocator`.
pub const Namespace = struct {
    /// Empty for a bare namespace.
    name: []const u8 = "",
    /// Where `lookup` goes for a name this namespace does not hold:
    /// `nexis.core`, referred into every namespace. `intern` never
    /// goes there, so a forward reference lands here.
    parent: ?*Namespace = null,
    /// The registry, which resolves `other/x` for any namespace;
    /// null for a bare one.
    registry: ?*NamespaceRegistry = null,
    /// `(require '[my.app :as m])`'s aliases, this namespace's own:
    /// alias name to namespace name.
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    map_allocator: std.mem.Allocator,
    var_allocator: std.mem.Allocator,
    vars: std.StringHashMapUnmanaged(*Var) = .empty,

    pub fn init(map_allocator: std.mem.Allocator, var_allocator: std.mem.Allocator) Namespace {
        return .{ .map_allocator = map_allocator, .var_allocator = var_allocator };
    }

    pub fn deinit(self: *Namespace) void {
        self.vars.deinit(self.map_allocator);
        self.aliases.deinit(self.map_allocator);
        self.* = undefined;
    }

    /// Map `alias_name` to `target_ns_name`, replacing any earlier
    /// alias of the name; both are copied, since a caller's may live
    /// in a per-form arena.
    pub fn putAlias(self: *Namespace, alias_name: []const u8, target_ns_name: []const u8) !void {
        const owned_alias = try self.var_allocator.dupe(u8, alias_name);
        const owned_target = try self.var_allocator.dupe(u8, target_ns_name);
        try self.aliases.put(self.map_allocator, owned_alias, owned_target);
    }

    /// The namespace name `name` is an alias of here, if it is one.
    pub fn lookupAlias(self: *const Namespace, name: []const u8) ?[]const u8 {
        return self.aliases.get(name);
    }

    /// The Var of `name` here or, failing that, in `parent`.
    pub fn lookup(self: *const Namespace, name: []const u8) ?*Var {
        if (self.vars.get(name)) |v| return v;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }

    /// The Var of `name` here alone.
    pub fn lookupLocal(self: *const Namespace, name: []const u8) ?*Var {
        return self.vars.get(name);
    }

    /// The Var of `name` here, made unbound when there is none; the
    /// name is copied, since a caller's may live in a per-form arena.
    pub fn intern(self: *Namespace, name: []const u8) !*Var {
        if (self.vars.get(name)) |v| return v;
        const owned_name = try self.var_allocator.dupe(u8, name);
        const new_var = try self.var_allocator.create(Var);
        new_var.* = .{ .name = owned_name, .ns = self.name };
        try self.vars.put(self.map_allocator, owned_name, new_var);
        return new_var;
    }
};

/// A VM's namespaces by name, with `nexis.core`, referred into every
/// namespace, and the current one, where `def` installs (STDLIB.md §8).
/// The namespaces live in `var_allocator`, the map in `map_allocator`.
pub const NamespaceRegistry = struct {
    map_allocator: std.mem.Allocator,
    var_allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(*Namespace) = .empty,
    core: *Namespace = undefined,
    current: *Namespace = undefined,
    /// The heap the compiler lowers string and bignum literals onto
    /// (`VM.ensureRegistry` sets it); with none, a `.string` form is
    /// `UnsupportedFeature`.
    heap: ?*heap_mod.Heap = null,
    /// The VM that owns this registry (`VM.ensureRegistry` sets it):
    /// the expander reaches it through a namespace to give a macro's
    /// sub-VM the registries of the VM it compiles for (§9.1).
    vm: ?*VM = null,

    /// An empty registry; `setupDefaults` fills it once it is where it
    /// stays, since each namespace points back at it.
    pub fn initEmpty(map_allocator: std.mem.Allocator, var_allocator: std.mem.Allocator) NamespaceRegistry {
        return .{ .map_allocator = map_allocator, .var_allocator = var_allocator };
    }

    /// `nexis.core` and `user`, the current namespace.
    pub fn setupDefaults(self: *NamespaceRegistry) !void {
        self.core = try self.makeNamespace("nexis.core", null);
        self.current = try self.makeNamespace("user", self.core);
    }

    pub fn deinit(self: *NamespaceRegistry) void {
        var it = self.map.valueIterator();
        while (it.next()) |ns| ns.*.deinit();
        self.map.deinit(self.map_allocator);
        self.* = undefined;
    }

    /// The namespace `name`, made with `parent` when there is none.
    pub fn getOrCreate(self: *NamespaceRegistry, name: []const u8, parent: ?*Namespace) !*Namespace {
        if (self.map.get(name)) |existing| return existing;
        return try self.makeNamespace(name, parent);
    }

    pub fn lookupNs(self: *const NamespaceRegistry, name: []const u8) ?*Namespace {
        return self.map.get(name);
    }

    /// Make `name` current, as Clojure's `(ns NAME)`: a new one refers
    /// `nexis.core`.
    pub fn switchTo(self: *NamespaceRegistry, name: []const u8) !void {
        self.current = try self.getOrCreate(name, self.core);
    }

    /// Set the root of `nexis.core/*ns*`, once `core.nx` defines it,
    /// to the current namespace's name symbol (a namespace is its
    /// name, STDLIB.md §8). The compiler calls this before it
    /// expands each form and `in-ns` after it switches, so a macro
    /// and the code a form runs read the namespace the form is
    /// compiled in.
    pub fn publishCurrent(self: *NamespaceRegistry, interner: *intern_mod.Interner) !void {
        const v = self.core.lookupLocal("*ns*") orelse return;
        v.root = try interner.internSymbolValue(self.current.name);
    }

    /// The name is copied, since a caller's may live in a per-form
    /// arena.
    fn makeNamespace(self: *NamespaceRegistry, name: []const u8, parent: ?*Namespace) !*Namespace {
        const owned_name = try self.var_allocator.dupe(u8, name);
        const ns = try self.var_allocator.create(Namespace);
        ns.* = Namespace.init(self.map_allocator, self.var_allocator);
        ns.name = owned_name;
        ns.parent = parent;
        ns.registry = self;
        try self.map.put(self.map_allocator, owned_name, ns);
        return ns;
    }
};

/// A captured binding's cell (VM.md §6), the body of a `cell_internal`
/// block: the `.cell_internal` Value a slot holds and the `*UpvalCell`
/// a closure or frame holds name the same block.
pub const UpvalCell = struct {
    value: Value,
    initialized: bool,
};

/// A closure (VM.md §6), the body of a `function` block whose tail
/// holds the cell pointers `upvalues` names: the collector never moves
/// a block.
pub const Closure = struct {
    routine: *const Routine,
    upvalues: []const *UpvalCell,
};

/// The block header of a cell reached through its body pointer.
inline fn cellHeader(cell: *UpvalCell) *heap_mod.HeapHeader {
    return @ptrFromInt(@intFromPtr(cell) - @sizeOf(heap_mod.HeapHeader));
}

/// A Zig function as a value: a `.native_fn` Value is a pointer to its
/// static descriptor, which nothing frees or collects.
pub const NativeFn = struct {
    name: []const u8,
    min_arity: u16,
    /// Null for no upper bound.
    max_arity: ?u16,
    call: *const fn (vm: *VM, args: []const Value) VmError!Value,
    /// A leaf never re-enters the VM and never compares, hashes or
    /// prints nested data, so no collection, stack growth or deep-data
    /// overflow can happen under it: a caller passes its arguments in
    /// place, unrooted, and skips the stack guard and the overflow
    /// check (VM.md §6).
    leaf: bool = false,
    /// A leaf's full body, which a call that is not a leaf call runs
    /// instead of `call`, when its leaf body refuses some receivers
    /// with `VmError.NeedsReentry` (`nth` of a lazy seq, which may run
    /// code): a leaf call site re-issues such a call through the
    /// general path, arguments copied and rooted (VM.md §6). Null on a
    /// native that is not a leaf.
    general: ?*const fn (vm: *VM, args: []const Value) VmError!Value = null,
    /// The native walks its last argument to the end, or until it is
    /// done with it, and keeps the walk rooted itself (`SeqIter.cursor`):
    /// `call:call` clears the argument's slot once it has copied the
    /// arguments, so the head of a lazy seq passed straight in is not
    /// held by the caller's block while the walk realizes the rest
    /// (docs/GC.md §11.5).
    consumes: bool = false,

    /// Whether the native takes `argc` arguments.
    pub inline fn takes(self: *const NativeFn, argc: usize) bool {
        return argc >= self.min_arity and argc <= (self.max_arity orelse argc);
    }
};

/// What realizing a lazy seq takes, which `src/seq.zig` implements
/// above this file (docs/LAZY.md §6): set once, when the core natives
/// are installed.
pub const LazyOps = struct {
    force: *const fn (vm: *VM, lz: Value) VmError!Value,
    realize_spine: *const fn (vm: *VM, x: Value) VmError!void,
    realize_all: *const fn (vm: *VM, x: Value) VmError!void,
};

pub var lazy_ops: ?*const LazyOps = null;

// =============================================================================
// Dispatch and native-call counts (`-Dopcodes=true`, docs/TOOLING.md §1)
// =============================================================================

/// Whether this build counts every dispatch by opcode and every native
/// call by native. Off, the counting is compiled out.
pub const counting = build_options.opcodes;

/// Dispatches by opcode index (`group | variant << 6`, VM.md §8). A
/// comparison that runs its branch is one dispatch.
pub var opcode_counts: [4096]u64 = @splat(0);

/// Native calls by native, an open-addressed table keyed by the
/// descriptor's address; a native past its capacity goes uncounted.
pub var native_counts: [2048]NativeCount = @splat(.{});

pub const NativeCount = struct { native: ?*const NativeFn = null, calls: u64 = 0 };

pub fn resetCounts() void {
    opcode_counts = @splat(0);
    native_counts = @splat(.{});
}

inline fn countNative(native: *const NativeFn) void {
    if (!counting) return;
    var i = (@intFromPtr(native) >> 3) % native_counts.len;
    for (0..native_counts.len) |_| {
        const e = &native_counts[i];
        if (e.native == null) e.native = native;
        if (e.native == native) {
            e.calls += 1;
            return;
        }
        i = (i + 1) % native_counts.len;
    }
}

/// What an isolated realization failed with: a thrown value, or an
/// error its barrier could not catch (docs/LAZY.md §6).
pub const ParkedRealize = union(enum) {
    thrown: Value,
    err: VmError,
};

/// Unpack the descriptor pointer from a `.native_fn` Value.
pub fn asNativeFn(v: Value) *const NativeFn {
    std.debug.assert(v.kind() == .native_fn);
    return @ptrFromInt(v.payload);
}

/// Build a `.native_fn` Value from a static `NativeFn`
/// descriptor. Typical use: `vm_mod.nativeFnValue(&native_first)`.
pub fn nativeFnValue(descriptor: *const NativeFn) Value {
    return value_mod.fromNativeFnPtr(@ptrCast(descriptor));
}

/// A path argument of `slurp`, `spit`, `db/open` and
/// `nextomic/connect`: a string, not empty, with no NUL byte
/// (`:invalid-path`): an open would stop at the NUL and name a shorter
/// path than the program checked (DB.md §2).
pub fn pathArg(v: Value) VmError![]const u8 {
    if (v.kind() != .string) return VmError.KindMismatch;
    const path = string_mod.asBytes(v);
    if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return VmError.InvalidPath;
    return path;
}

// =============================================================================
// Frame (VM.md §7): a window on the one backing stack, so a slice of
// `vm.stack.items` or a `*Frame` is one-shot, invalid once the stack
// or the frames grow. A callee's window may end below a caller's, so
// each frame records the stack length its pop restores: the extent
// the frames beneath it need.
// =============================================================================

pub const Frame = struct {
    routine: *const Routine,
    /// Slot `i` is `vm.stack.items[base_slot + i]`.
    base_slot: u32,
    /// The stack length before the frame's window grew it, which its
    /// pop, by return or unwind, restores.
    entry_stack_len: u32,
    /// The next instruction; under a frame it called, its return point.
    pc: u32 = 0,
    /// The caller's slot the return writes.
    return_dst: u16 = 0,
    /// The closure's cells; empty for the top-level frame.
    upvalues: []const *UpvalCell = &.{},
    /// The closure the frame runs, nil for the top-level frame: a root
    /// that keeps its block, cells and routine alive.
    closure: Value = value_mod.nilValue(),
    /// For a frame `callValue`, `runRoutine` or a `Callback` pushed:
    /// the cell its return writes instead of a caller's slot. The
    /// return pops the frame, but for a batch's, which starts the next
    /// element in it (VM.md §6).
    host_result: ?*HostCallResult = null,

    // A cache line: a call writes one, and a frame's address is its
    // index shifted.
    comptime {
        std.debug.assert(@sizeOf(Frame) == 64);
    }
};

/// The cell a host's frame returns into (`Frame.host_result`).
pub const HostCallResult = struct {
    done: bool = false,
    value: Value = value_mod.nilValue(),
    /// For the cell of a `Callback` running a batch, the part its
    /// frame's return goes on to, which starts the next element
    /// (`VM.batchNext`).
    step: ?VM.OpHandler = null,

    /// The returned value, once the loop is back at the call's depth:
    /// without a return, a throw went past the call. Read a word at a
    /// time, the width the return stored it (§8).
    inline fn get(self: *const HostCallResult) VmError!Value {
        if (!self.done) return VmError.ControlTransferred;
        return VM.loadWords(&self.value);
    }
};

/// One frame of `VM.error_trace`: the routine that was running,
/// the index of the instruction it was executing (for a caller
/// frame, the call), that instruction's source span when the
/// routine carries a span table, and the source the span indexes.
/// The marker frame a long chain is cut at counts the frames it
/// stands for in `elided`; its name is fixed text for a host that
/// does not read the count.
pub const TraceFrame = struct {
    name: []const u8,
    pc: u32,
    span: ?SourceSpan,
    source: ?*const SourceInfo,
    elided: usize = 0,
};

/// Where a throw a handler took was raised (VM.md §12): the value, the
/// runtime error it was translated from, that error's detail and the
/// frame chain at the raise. A catch that rethrows the value, or a
/// finally that resumes the throw, carries the origin on, so a throw
/// that finally escapes is reported where it began.
pub const ThrowOrigin = struct {
    value: Value,
    err: ?VmError,
    detail_buf: [160]u8 = undefined,
    detail_len: usize = 0,
    trace: [VM.trace_capacity]TraceFrame = undefined,
    trace_len: usize = 0,
};

// =============================================================================
// Errors
// =============================================================================

/// What a native needs from the compiler at run time. `user_data`
/// belongs to the installer (the CLI runtime, a test harness); the
/// functions run on the calling VM and build their results on its
/// heap.
pub const CompilerHooks = struct {
    user_data: *anyopaque,
    /// One macro step on `form`: the expansion when `form` is a
    /// macro call, null when it is not. Expansion failures throw.
    expand_once: *const fn (*anyopaque, *VM, Value) VmError!?Value,
    /// The first form of `source` as a value, null when it holds
    /// none (only whitespace, comments and discards); a form that
    /// does not read throws `:reader-error`.
    read_string: *const fn (*anyopaque, *VM, []const u8) VmError!?Value,
    /// `form` macroexpanded and compiled in the current namespace
    /// and run on this VM as a nested call (`runRoutine`); the
    /// value it returns. A form that does not compile throws. Null
    /// in a macro's sub-VM (§9.1), where `eval` throws `:no-compiler`.
    eval: ?*const fn (*anyopaque, *VM, Value) VmError!Value,
    /// The first form of `source` compiled as read, as a file's form
    /// is, so a syntax-quote in it compiles, and run as `eval` runs
    /// one: its value and the byte its text ends at. Null when
    /// `source` holds no form; text that does not read throws
    /// `:reader-error`, a form that does not compile as in `eval`.
    /// Null where `eval` is.
    load: ?*const fn (*anyopaque, *VM, []const u8) VmError!?Loaded,

    pub const Loaded = struct { value: Value, end: usize };
};

/// A `defrecord` type (PROTOCOLS.md §3.1), its names owned by the VM.
pub const RecordTypeEntry = struct {
    id: u32,
    ns_name: []const u8,
    type_name: []const u8,
    field_names: []const []const u8,
};

/// A `defprotocol` (PROTOCOLS.md §3), its names owned by the VM.
pub const ProtocolEntry = struct {
    id: u32,
    ns_name: []const u8,
    name: []const u8,
    methods: std.ArrayList(ProtocolMethod) = .empty,

    /// The method named by the interned id `name_id`.
    pub fn method(self: *ProtocolEntry, name_id: u32) ?*ProtocolMethod {
        for (self.methods.items) |*m| if (m.name_id == name_id) return m;
        return null;
    }
};

pub const ProtocolMethod = struct {
    /// The interned keyword id of the name, and the name for reports.
    name_id: u32,
    name: []const u8,
    /// The callable each dispatch key extends the method with, called
    /// with the receiver first; `default_impl` is `extend-protocol` on
    /// `:any`'s.
    impls: std.AutoHashMapUnmanaged(DispatchKey, Value) = .empty,
    default_impl: ?Value = null,
};

/// A method `registerProtocol` declares; the VM copies the name.
pub const ProtocolMethodSpec = struct {
    name_id: u32,
    name: []const u8,
};

/// What protocol dispatch finds an impl by (PROTOCOLS.md §3.2): a
/// record's type id, or a built-in kind, the integer tower one kind.
pub const DispatchKey = struct {
    tag: Tag,
    id: u32,

    pub const Tag = enum(u8) {
        builtin = 0,
        record = 1,
    };

    pub fn ofValue(v: value_mod.Value) DispatchKey {
        if (v.kind() == .record) return .{ .tag = .record, .id = record_mod.typeId(v) };
        return canonical(.{ .tag = .builtin, .id = @backingInt(v.kind()) });
    }

    /// A bignum dispatches on the fixnum's key (SEMANTICS §2.2).
    pub fn canonical(key: DispatchKey) DispatchKey {
        if (key.tag == .builtin and key.id == @backingInt(value_mod.Kind.bignum)) {
            return .{ .tag = .builtin, .id = @backingInt(value_mod.Kind.fixnum) };
        }
        return key;
    }
};

pub const VmError = error{
    // Not catchable: compiler bugs and corrupt bytecode, most refused
    // by verification (§5).
    UnimplementedOpcode,
    OperandOutOfRange,
    InvalidOperandKind,
    BytecodeExhausted,
    BytecodeCorruption,
    CallBlockOutOfRange,
    CaptureCountMismatch,
    UpvalueOutOfRange,
    ExpectedCell,
    InvalidCellState,
    UninitializedCell,
    InvalidHandlerState,
    OutOfMemory,
    // Catchable (`vmErrorToKeywordName`).
    KindMismatch,
    ArithmeticOverflow,
    DivideByZero,
    ArityMismatch,
    NotCallable,
    IndexOutOfBounds,
    DbError,
    DbClosed,
    InvalidDurableRef,
    CodecFailed,
    TxClosed,
    NotDerefable,
    UnboundVar,
    NotDynamic,
    NoThreadBinding,
    AtomReEntry,
    TransientUsedAfterPersistent,
    Utf8Error,
    InvalidArgument,
    IoError,
    FileNotFound,
    InvalidPath,
    NotARecord,
    NoProtocolImpl,
    NoProtocolMethod,
    StackOverflow,
    // Control signals (§12). A throw no handler takes, its value in
    // `VM.unhandled_throw`.
    UncaughtThrow,
    /// A native's throw was caught below it: frames and pc are at the
    /// handler, and every native between returns this unchanged so the
    /// loop resumes there.
    ControlTransferred,
    /// A leaf body refusing a receiver it could handle only by running
    /// code: its call site re-issues the call through the general path
    /// (§6). Never escapes a call site.
    NeedsReentry,
};

// =============================================================================
// Try / catch / throw (VM.md §12)
// =============================================================================

/// `try_` while a `try` body runs; `cleanup` while its catch body runs,
/// keeping its finally for the catch's `try-exit` and passing a throw
/// from the catch body on.
pub const HandlerKind = enum { try_, cleanup };

/// A handler on `VM.handlers`, one stack for the VM keyed by frame
/// index, which stays valid since frames pop only from the top.
pub const Handler = struct {
    kind: HandlerKind,
    frame_index: usize,
    /// `try_` alone: where a throw goes, and the slot that takes it.
    catch_pc: u32,
    binding_slot: u12,
    finally_pc: ?u32 = null,
    /// `finally_stack`'s length when the try was entered: the
    /// continuations above it are of finally bodies inside the try,
    /// which a throw it takes abandons.
    finally_depth: usize,
    /// On a `cleanup`: the origin of the throw its catch handles
    /// (`VM.origins`), which a rethrow keeps.
    origin: ?u32 = null,
};

/// What a finally body goes on to: the pc after its `try`, or a throw
/// it resumes.
pub const FinallyReason = union(enum) {
    normal: u32,
    throwing: Value,
};

pub const FinallyContinuation = struct {
    /// The frame of the handler, which `finally-exit` checks.
    frame_index: usize,
    reason: FinallyReason,
    /// With `.throwing`: the origin of the throw the finally resumes.
    origin: ?u32 = null,
};

/// The collector's trigger settings (GC.md §7). `default` is what
/// a VM starts with; `stress` is what `NEXIS_GC_STRESS` in the
/// environment selects so a run collects every few kilobytes and
/// every rooting gap shows. Its 2 % keeps that true for any heap
/// under about 200 KiB live (a booted standard library leaves 95 KiB)
/// and spaces cycles out over a large live
/// set, which every 4 KiB cycle would otherwise re-mark and re-sweep.
pub const GcPolicy = struct {
    /// Bytes allocated since the last cycle before the next is due,
    /// at least.
    threshold: usize,
    /// The next cycle is also no sooner than this percentage of the
    /// bytes that survived the last one, so a large live set is not
    /// re-marked every few kilobytes.
    growth_percent: usize,

    pub const default: GcPolicy = .{ .threshold = 16 * 1024 * 1024, .growth_percent = 100 };
    pub const stress: GcPolicy = .{ .threshold = 4096, .growth_percent = 2 };
};

/// One entry of the dynamic-binding stack: what `v`'s thread
/// binding was before the frame that holds this entry rebound it.
pub const DynSave = struct {
    v: *Var,
    value: Value,
    bound: bool,
};

/// One callee a native calls many times with the same number of
/// arguments from the same place (`map`, `filter`, `reduce`, ...):
/// `VM.callValue` with what cannot change between those calls decided
/// at the first one (VM.md §6, "Repeated calls"). Each call has
/// `callValue`'s effect, errors and rooting. A prepared `Callback`
/// is not moved: its frame names its own result cell.
pub const Callback = struct {
    vm: *VM,
    callee: Value,
    argc: u16,
    mode: Mode = .unprepared,
    /// For `.closure`: the frame chain's depth and the stack's length
    /// at the first call, which every later call from the same native
    /// finds again; where the callee's locals begin and how many there
    /// are, which each call nils, and where its window ends; and the
    /// frame each call pushes.
    depth: usize = 0,
    base: usize = 0,
    locals: usize = 0,
    nil_count: usize = 0,
    window_end: usize = 0,
    frame: Frame = undefined,
    /// The callee's first instruction and its handler, where each call
    /// enters the chain.
    first: Inst = undefined,
    first_handler: VM.OpHandler = undefined,
    /// The cell the prepared frame returns into: a callee that
    /// re-enters the native makes a `Callback` and a cell of its own.
    result: HostCallResult = .{},
    /// The pass `each`, `fold` or `foldRange` is running.
    batch: Batch = undefined,

    const Mode = enum { unprepared, general, leaf, lookup, closure };

    /// The calls `each`, `fold` or `foldRange` makes in one pass of the
    /// chain, in the callee's frame (VM.md §6, "Batched calls").
    const Batch = struct {
        step: Step,
        /// The element running, from 0 (once the pass is over, how many
        /// ran), and how many the pass runs.
        i: usize,
        n: usize,
        /// `each` and `fold`: the elements.
        items: [*]const Value = undefined,
        /// `each`: where the results go.
        out: Out = undefined,
        /// `fold_range`: the element running, and the step to the next
        /// (0 for a repeat).
        x: Value = undefined,
        by: i64 = 0,

        /// What a return does with the value: `each`'s by where the
        /// results go.
        const Step = enum { each_slots, each_roots, fold, fold_range };

        /// A fold's first element.
        fn head(b: Batch) Value {
            return if (b.step == .fold_range) b.x else b.items[0];
        }
    };

    /// Where `each` puts its results, the one for element `i` at `i`:
    /// slots of a block a root reaches, or of a buffer whose values
    /// only their kinds are read from (a cycle may free what they
    /// point at); or slots of the root stack from an index, never by
    /// pointer, since a native the callee calls may grow it (GC.md
    /// §11.5).
    pub const Out = union(enum) {
        slots: [*]Value,
        roots: usize,

        inline fn put(self: Out, vm: *VM, i: usize, v: Value) void {
            switch (self) {
                .slots => |p| VM.storeWords(&p[i], v),
                .roots => |base| vm.roots.items[base + i] = v,
            }
        }
    };

    /// What `fold` and `foldRange` end with: the accumulator, and how
    /// many elements made it.
    pub const Folded = struct { acc: Value, used: usize };

    pub fn init(vm: *VM, callee: Value, argc: u16) Callback {
        return .{ .vm = vm, .callee = callee, .argc = argc };
    }

    /// `callee` applied to `args`, of which there are `argc`.
    pub inline fn call(self: *Callback, args: []const Value) VmError!Value {
        return self.callWith(args.len, args);
    }

    /// `call` of a callback of one argument, which a closure's call
    /// stores straight from the native's registers into the window.
    pub inline fn call1(self: *Callback, x: Value) VmError!Value {
        return self.callWith(1, [1]Value{x});
    }

    /// `call` of a callback of two arguments.
    pub inline fn call2(self: *Callback, a: Value, b: Value) VmError!Value {
        return self.callWith(2, [2]Value{ a, b });
    }

    /// `args` a slice, or an array of `n` values held in registers.
    inline fn callWith(self: *Callback, n: usize, args: anytype) VmError!Value {
        std.debug.assert(n == self.argc);
        const by_value = @TypeOf(args) != []const Value;
        switch (self.mode) {
            .leaf => return self.callLeaf(asNativeFn(self.callee), if (by_value) &args else args),
            .lookup => if (lookupInPlace(self.callee, args[0], value_mod.nilValue())) |v| return v,
            .closure => if (self.ready()) {
                // The arguments go where the window begins, past the
                // stack's end, within the capacity the first call made,
                // a word at a time, as the callee's handlers read them
                // (§8).
                const w = self.window();
                if (by_value) {
                    inline for (args, 0..) |arg, i| VM.storeWords(&w[i], arg);
                } else for (args, w[0..args.len]) |*arg, *slot| {
                    VM.copyWords(slot, arg);
                }
                try self.vm.callPrepared(self);
                return self.result.get();
            },
            .unprepared => return self.firstCall(if (by_value) &args else args),
            .general => {},
        }
        return self.vm.callGeneral(self.callee, if (by_value) &args else args);
    }

    /// The first call, out of line: a loop of calls keeps no test of
    /// the mode but `callWith`'s switch.
    fn firstCall(self: *Callback, args: []const Value) VmError!Value {
        try self.prepare();
        return self.callWith(args.len, args);
    }

    /// How many locals `callPrepared` nils in one run.
    const nil_run = 4;

    /// Decide the mode before the first call, at the depth and stack
    /// length every call from here finds: a leaf within its arity, a
    /// keyword or symbol of one argument, a closure the count enters at
    /// a fixed arity, whose frame is built here, or the general call.
    fn prepare(self: *Callback) VmError!void {
        const vm = self.vm;
        self.mode = .general;
        switch (self.callee.kind()) {
            .native_fn => {
                const native = asNativeFn(self.callee);
                if (native.leaf and native.takes(self.argc)) self.mode = .leaf;
            },
            .keyword, .symbol => if (self.argc == 1) {
                self.mode = .lookup;
            },
            .function => {
                const closure = VM.asClosure(self.callee);
                const routine = closure.routine.memberFor(self.argc) orelse return;
                if (routine.slot_count < self.argc) return;
                // Every later call starts at this depth of the native
                // stack, so the guard's answer holds for them all
                // (§13.1).
                try vm.checkNesting();
                const depth = vm.frames.items.len;
                const base = vm.stack.items.len;
                const window_end = base + routine.slot_count;
                if (depth >= vm.max_frames) return;
                vm.frames.ensureUnusedCapacity(vm.allocator, 1) catch return VmError.OutOfMemory;
                // Room for the locals `callPrepared` nils four at once.
                const reach = @max(window_end, base + self.argc + nil_run);
                vm.stack.ensureTotalCapacity(vm.allocator, reach) catch return VmError.OutOfMemory;
                vm.noteHighWater(depth + 1, window_end);
                self.depth = depth;
                self.base = base;
                self.locals = base + self.argc;
                self.nil_count = routine.slot_count - self.argc;
                self.window_end = window_end;
                self.first = routine.code[0];
                self.first_handler = VM.fast_table[VM.opIndex(self.first)];
                self.frame = VM.calleeFrame(self.callee, routine, base, base, .{ .host_result = &self.result });
                self.mode = .closure;
            },
            else => {},
        }
    }

    /// A leaf native's call, in place while no cycle is due, else (or
    /// when it asks to re-enter) the general call.
    inline fn callLeaf(self: *Callback, native: *const NativeFn, args: []const Value) VmError!Value {
        return self.vm.callNativeLeaf(native, args, self.callee);
    }

    /// Whether a closure's call can take the prepared frame now: the
    /// native is at the depth and stack length of the first call.
    inline fn ready(self: *const Callback) bool {
        return self.mode == .closure and self.vm.frames.items.len == self.depth and self.vm.stack.items.len == self.base;
    }

    /// The callee's window, past the stack's end while it is ready.
    inline fn window(self: *const Callback) [*]Value {
        return self.vm.stack.items.ptr + self.base;
    }

    /// `out[i] = callee(items[i])` for each element in turn, `argc` 1:
    /// a closure's calls in one pass of the chain (VM.md §6, "Batched
    /// calls"), anything else's as `call1` makes them, with the same
    /// results, errors and rooting.
    pub fn each(self: *Callback, items: []const Value, out: Out) VmError!void {
        std.debug.assert(self.argc == 1);
        if (items.len == 0) return;
        if (self.mode == .unprepared) try self.prepare();
        if (self.ready()) {
            self.batch = .{ .step = if (out == .slots) .each_slots else .each_roots, .i = 0, .n = items.len, .items = items.ptr, .out = out };
            VM.storeWords(&self.window()[0], items[0]);
            return self.vm.callBatch(self);
        }
        // A leaf takes its argument where it lies, the mode tested once.
        if (self.mode == .leaf) {
            const native = asNativeFn(self.callee);
            for (items, 0..) |*x, i| out.put(self.vm, i, try self.callLeaf(native, x[0..1]));
        } else for (items, 0..) |x, i| out.put(self.vm, i, try self.call1(x));
    }

    /// `acc = callee(acc, items[i])` for each element in turn, `argc`
    /// 2, as `each` makes the calls, stopping after a result that is a
    /// record, which may be `reduced`.
    /// Inline: its one caller, `reduce`, keeps the loop of a leaf's
    /// calls in its own frame.
    pub inline fn fold(self: *Callback, acc: Value, items: []const Value) VmError!Folded {
        return self.foldOver(acc, .{ .step = .fold, .i = 0, .n = items.len, .items = items.ptr }, .fold);
    }

    /// `fold` over the `n` fixnums from `x` by `by`, or over `n` times
    /// `x` when `by` is 0: an unrealized range or repeat, whose elements
    /// are computed, not read. The caller vouches that every element is
    /// a fixnum when `by` is not 0.
    pub fn foldRange(self: *Callback, acc: Value, x: Value, by: i64, n: usize) VmError!Folded {
        return self.foldOver(acc, .{ .step = .fold_range, .i = 0, .n = n, .x = x, .by = by }, .fold_range);
    }

    inline fn foldOver(self: *Callback, acc: Value, batch: Batch, comptime step: Batch.Step) VmError!Folded {
        std.debug.assert(self.argc == 2);
        if (batch.n == 0) return .{ .acc = acc, .used = 0 };
        if (self.mode == .unprepared) try self.prepare();
        if (self.ready()) {
            self.batch = batch;
            const w = self.window();
            VM.storeWords(&w[0], acc);
            VM.storeWords(&w[1], batch.head());
            try self.vm.callBatch(self);
            return .{ .acc = VM.loadWords(&self.result.value), .used = self.batch.i };
        }
        const leaf: ?*const NativeFn = if (self.mode == .leaf) asNativeFn(self.callee) else null;
        var a = acc;
        var e = batch.head();
        var i: usize = 0;
        while (true) {
            a = if (leaf) |native| try self.callLeaf(native, &.{ a, e }) else try self.call2(a, e);
            i += 1;
            if (a.kind() == .record or i == batch.n) return .{ .acc = a, .used = i };
            e = if (step == .fold) batch.items[i] else rangeNext(e, batch.by);
        }
    }

    /// The element after `x` in a range of step `by`: a fixnum's
    /// payload is its value, and a repeat's step is 0.
    inline fn rangeNext(x: Value, by: i64) Value {
        return .{ .tag = x.tag, .payload = x.payload +% @as(u64, @bitCast(by)) };
    }
};

/// A window on the VM's root stack for a native that keeps values
/// across a call back into the VM: `push` what must survive a
/// collection, `release` (normally deferred) drops everything the
/// scope pushed. Scopes nest as calls do.
pub const RootScope = struct {
    vm: *VM,
    base: usize,

    /// Push `v`; within the root stack's capacity, in the caller's
    /// loop.
    pub inline fn push(self: RootScope, v: Value) VmError!void {
        const roots = &self.vm.roots;
        if (roots.items.len < roots.capacity) return roots.appendAssumeCapacity(v);
        roots.append(self.vm.allocator, v) catch return VmError.OutOfMemory;
    }

    pub fn pushAll(self: RootScope, vs: []const Value) VmError!void {
        self.vm.roots.appendSlice(self.vm.allocator, vs) catch return VmError.OutOfMemory;
    }

    pub fn release(self: RootScope) void {
        self.vm.roots.shrinkRetainingCapacity(self.base);
    }
};

// =============================================================================
// VM
// =============================================================================

pub const VM = struct {
    allocator: std.mem.Allocator,
    /// The backing stack every frame windows (§7).
    stack: std.ArrayList(Value) = .empty,
    /// The frame chain, the top-level frame at 0.
    frames: std.ArrayList(Frame) = .empty,
    /// What lives as long as the VM outside the heap: Vars, namespaces.
    runtime_arena: std.heap.ArenaAllocator,
    /// The collected heap (§9), made on first use.
    heap: ?heap_mod.Heap = null,
    /// The owner's heap a macro's sub-VM allocates on (§9.1), so what a
    /// macro stores in a Var outlives it; a VM over one never collects.
    borrowed_heap: ?*heap_mod.Heap = null,
    gc_enabled: bool = true,
    /// The trigger (GC.md §7): a cycle is due once the heap has
    /// allocated `gc_next_at` bytes since the last, which each cycle
    /// sets from `gc_threshold` and `gc_growth_percent` of what
    /// survived (`GcPolicy`).
    gc_threshold: usize = GcPolicy.default.threshold,
    gc_growth_percent: usize = GcPolicy.default.growth_percent,
    gc_next_at: usize = GcPolicy.default.threshold,
    gc_cycles: usize = 0,
    /// While nonzero no cycle is due: a lazy block is being realized in
    /// isolation under `=` or `hash` (LAZY.md §6).
    gc_hold: u32 = 0,
    /// The failure of an isolated realization, a root until the call
    /// that compared or hashed raises it (`checkDeepData`) or drops it
    /// (`dropSpoils`); the first wins (LAZY.md §6).
    parked_realize: ?ParkedRealize = null,
    /// The spoil count it was parked at.
    parked_at: u64 = 0,
    /// The collector's gray worklist, its capacity kept between cycles
    /// (GC.md §4).
    gc_gray: std.ArrayList(*heap_mod.HeapHeader) = .empty,
    /// The large routines whose constants this cycle has marked
    /// (`markClauseConsts`).
    gc_routines: std.AutoHashMapUnmanaged(*const Routine, void) = .empty,
    /// The root stack (GC.md §3, §11.5): what natives hold across a
    /// call back into the VM (`RootScope`).
    roots: std.ArrayList(Value) = .empty,
    /// The dynamic bindings (§6.5): the binding each rebinding replaced,
    /// and where each `binding` frame's saves start.
    dyn_saves: std.ArrayList(DynSave) = .empty,
    dyn_frames: std.ArrayList(u32) = .empty,
    /// The one namespace of a VM with no registry, built by hand.
    namespace: ?Namespace = null,
    registry: ?NamespaceRegistry = null,
    /// Shuts down every db connection on the VM's heap at teardown
    /// (`db.shutdownHeap`); set by the first `db/open`, so this file
    /// needs no import of db.zig.
    db_close_callback: ?*const fn (*heap_mod.Heap) void = null,
    /// Open Nextomic connections and the natives' Nextomic state,
    /// closed at `deinit` through the callbacks their natives set; the
    /// natives own the casts, so this file needs no import.
    nextomic_connections: std.ArrayList(*anyopaque) = .empty,
    nextomic_close_callback: ?*const fn (*anyopaque) void = null,
    /// Parsed-query caches and finished `with` scopes, marked by every
    /// cycle through `nextomic_query_mark`.
    nextomic_query_state: ?*anyopaque = null,
    nextomic_query_close: ?*const fn (*anyopaque) void = null,
    nextomic_query_mark: ?*const fn (*anyopaque, *gc_mod.Collector) void = null,
    /// The natives' way to the outside world, which the CLI sets; null
    /// in a test harness, where printing raises `:io-error`.
    io: ?std.Io = null,
    /// The VM whose registries a macro's sub-VM uses (§9.1); it has no
    /// owner of its own and outlives this one.
    owner: ?*VM = null,
    /// The `defrecord` and `defprotocol` registries (PROTOCOLS.md §3),
    /// by dense id.
    record_registry: std.ArrayList(RecordTypeEntry) = .empty,
    protocol_registry: std.ArrayList(ProtocolEntry) = .empty,
    /// The handlers and pending finally continuations (§12).
    handlers: std.ArrayList(Handler) = .empty,
    finally_stack: std.ArrayList(FinallyContinuation) = .empty,
    /// The value of the throw that left a run as `UncaughtThrow`.
    unhandled_throw: ?Value = null,
    /// Where the last failing run failed (§13), and with what: a host
    /// that learns of a failure indirectly (a `require` while a form
    /// compiled) names it from here.
    error_trace: std.ArrayList(TraceFrame) = .empty,
    traced_error: ?VmError = null,
    interner: ?intern_mod.Interner = null,
    /// The compile-time interner a macro's sub-VM shares (§9.1).
    borrowed_interner: ?*intern_mod.Interner = null,
    /// What `eval`, `read-string` and `macroexpand-1` reach; with none
    /// they throw `:no-compiler`.
    compiler_hooks: ?CompilerHooks = null,
    reduced_type_id: ?u32 = null,
    /// The value the top-level frame returned, and whether it has.
    result: Value = value_mod.nilValue(),
    halted: bool = false,
    /// The depth of the innermost `loop` running (`running`).
    loop_depth: usize = 0,
    /// The most frames and stack slots a run has had, kept in safe
    /// builds alone (`track_high_water`), where tests prove a `recur`
    /// loop runs in constant space (§11).
    stack_high_water: usize = 0,
    frame_high_water: usize = 0,
    /// The deepest frame chain and the most run loops nested on the
    /// native stack before `StackOverflow` (§13, §13.1).
    max_frames: usize = default_max_frames,
    max_nested_runs: usize = default_max_nested_runs,
    nested_runs: usize = 0,
    /// The last runtime error's sentence (§13), in `detail_buf`; empty
    /// when the raise site had none, cleared when a run starts and when
    /// a handler takes the error.
    error_detail: []const u8 = "",
    detail_buf: [160]u8 = undefined,
    /// The last place `placeOf` found.
    place_cache: struct { text: []const u8 = "", pos: u32 = 0, place: SourceInfo.LineCol = .{ .line = 0, .col = 0 } } = .{},
    /// The origins of the throws handlers hold (§12), by index.
    origins: std.ArrayList(ThrowOrigin) = .empty,
    /// The origin of the throw that left a run uncaught.
    escaped_origin: ?u32 = null,
    /// `ErrorKey`s as keywords, interned on first use (`errorKey`).
    error_keys: [6]?Value = @splat(null),

    pub const track_high_water = builtin.optimize.runtimeSafety();
    pub const default_max_frames = 1 << 20;
    pub const default_max_nested_runs = 100_000;
    /// A trace keeps this many innermost frames and
    /// `trace_outermost` outermost ones; a marker frame counts the
    /// rest.
    const trace_innermost = 32;
    const trace_outermost = 8;
    pub const trace_capacity = trace_innermost + trace_outermost + 1;

    /// Build a VM around `routine`, allocating a single top-level
    /// frame with `routine.slot_count` slots zero-initialized to nil.
    /// Caller owns the lifetime of `routine`; VM owns the stack,
    /// frames, and runtime arena and frees them in `deinit`.
    pub fn init(allocator: std.mem.Allocator, routine: *const Routine) !VM {
        // A host that runs the runtime on its own stack arms the guard
        // first (the CLI does); otherwise assume a main thread's
        // (docs/VM.md §13.1).
        stack_guard.armIfUnarmed(stack_guard.main_thread_budget);
        var stack: std.ArrayList(Value) = .empty;
        errdefer stack.deinit(allocator);
        try stack.appendNTimes(allocator, value_mod.nilValue(), routine.slot_count);

        var frames: std.ArrayList(Frame) = .empty;
        errdefer frames.deinit(allocator);
        try frames.append(allocator, .{
            .routine = routine,
            .base_slot = 0,
            .entry_stack_len = 0,
            .pc = 0,
        });

        const policy: GcPolicy = if (std.c.getenv("NEXIS_GC_STRESS") != null) .stress else .default;
        return .{
            .allocator = allocator,
            .stack = stack,
            .frames = frames,
            .runtime_arena = std.heap.ArenaAllocator.init(allocator),
            .gc_threshold = policy.threshold,
            .gc_growth_percent = policy.growth_percent,
            .gc_next_at = policy.threshold,
            .stack_high_water = stack.items.len,
            .frame_high_water = frames.items.len,
        };
    }

    pub fn deinit(self: *VM) void {
        // A binding frame still open (a sub-VM abandoned by an
        // error before its `finally` ran) is popped so the Vars,
        // which outlive this VM, keep no binding of its making.
        while (self.dyn_frames.items.len > 0) self.popBindings();
        self.dyn_saves.deinit(self.allocator);
        self.dyn_frames.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.gc_gray.deinit(self.allocator);
        self.gc_routines.deinit(self.allocator);
        // Free handler + finally stack backing storage. Both
        // contain POD entries.
        self.handlers.deinit(self.allocator);
        self.finally_stack.deinit(self.allocator);
        self.origins.deinit(self.allocator);
        self.error_trace.deinit(self.allocator);
        // Interner owns hash maps allocated via self.allocator;
        // free explicitly.
        if (self.interner) |*it| it.deinit();
        // Registry owns its outer HashMap + per-ns
        // HashMaps (both via self.allocator). Free explicitly;
        // Namespace structs themselves are arena-backed.
        if (self.registry) |*reg| reg.deinit();
        if (self.namespace) |*ns| ns.deinit();
        if (self.db_close_callback) |close_fn| if (self.heap) |*h| close_fn(h);
        if (self.nextomic_close_callback) |close_fn| {
            for (self.nextomic_connections.items) |conn_ptr| close_fn(conn_ptr);
        }
        self.nextomic_connections.deinit(self.allocator);
        if (self.nextomic_query_state) |state| {
            if (self.nextomic_query_close) |close_fn| close_fn(state);
        }
        // Free record-registry storage (the entry
        // structs + their interned-name slices live in
        // self.allocator).
        for (self.record_registry.items) |entry| {
            self.allocator.free(entry.ns_name);
            self.allocator.free(entry.type_name);
            for (entry.field_names) |fname| self.allocator.free(fname);
            self.allocator.free(entry.field_names);
        }
        self.record_registry.deinit(self.allocator);
        // Free protocol-registry storage.
        for (self.protocol_registry.items) |*proto| {
            self.allocator.free(proto.ns_name);
            self.allocator.free(proto.name);
            for (proto.methods.items) |*method| {
                self.allocator.free(method.name);
                method.impls.deinit(self.allocator);
            }
            proto.methods.deinit(self.allocator);
        }
        self.protocol_registry.deinit(self.allocator);
        // The heap is backed by `allocator`: free every block still
        // live. A borrowed heap belongs to another VM.
        if (self.heap) |*h| h.deinit();
        self.runtime_arena.deinit();
        self.stack.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }

    /// The current namespace. If a NamespaceRegistry exists
    /// (via `ensureRegistry`), this returns `registry.current`
    /// (the namespace where `def`/`defn`/`defmacro` install).
    /// Otherwise it lazily initializes and returns the
    /// single-namespace slot used by ad-hoc test callers.
    pub fn ensureNamespace(self: *VM) *Namespace {
        if (self.owner) |o| return o.ensureNamespace();
        if (self.registry) |*reg| return reg.current;
        if (self.namespace == null) {
            self.namespace = Namespace.init(self.allocator, self.runtime_arena.allocator());
        }
        return &self.namespace.?;
    }

    /// Lazy-initialize a NamespaceRegistry with the
    /// conventional `nexis.core` (auto-referred) and `user`
    /// (default current) namespaces.
    pub fn ensureRegistry(self: *VM) !*NamespaceRegistry {
        if (self.owner) |o| return o.ensureRegistry();
        if (self.registry == null) {
            self.registry = NamespaceRegistry.initEmpty(
                self.allocator,
                self.runtime_arena.allocator(),
            );
            errdefer {
                self.registry.?.deinit();
                self.registry = null;
            }
            // Populate AFTER storage so back-pointers are stable.
            try self.registry.?.setupDefaults();
            // Make the VM heap reachable from the registry so
            // compile.zig's Form
            // lowering can allocate string-literal Values into
            // it via `namespace.registry.heap`.
            self.registry.?.heap = self.ensureHeap();
            self.registry.?.vm = self;
        }
        return &self.registry.?;
    }

    /// The VM whose registries this one uses: its owner, else itself.
    pub fn home(self: *VM) *VM {
        return self.owner orelse self;
    }

    /// Make this fresh VM, which runs a macro over `owner`'s heap and
    /// interner, use `owner`'s registries too (§9.1). It gets the
    /// owner's compiler hooks without `eval` and `load`:
    /// `macroexpand-1` and `read-string` touch nothing that outlives
    /// the call, while a compile would go into this VM's runtime arena
    /// and could load a file that runs the owner's collector.
    pub fn borrowRegistries(self: *VM, owner: *VM) void {
        self.owner = owner.home();
        if (self.owner.?.compiler_hooks) |hooks| {
            self.compiler_hooks = hooks;
            self.compiler_hooks.?.eval = null;
            self.compiler_hooks.?.load = null;
        }
    }

    /// The record type `id` names, or null when no `defrecord`
    /// registered it.
    pub fn recordType(self: *VM, id: u32) ?*const RecordTypeEntry {
        const types = self.home().record_registry.items;
        return if (id < types.len) &types[id] else null;
    }

    /// Lazy-initialize the shared Interner on first
    /// use. The Interner owns hash maps that need realloc/free,
    /// so it's backed by `self.allocator`, NOT runtime_arena.
    /// Symbol/keyword names are owned by the Interner (it
    /// dupes on intern). Interner.deinit in `VM.deinit` frees
    /// every interned name.
    pub fn ensureInterner(self: *VM) *intern_mod.Interner {
        if (self.borrowed_interner) |shared| return shared;
        if (self.interner == null) {
            self.interner = intern_mod.Interner.init(self.allocator);
        }
        return &self.interner.?;
    }

    /// The heap this VM allocates on: the borrowed one when set,
    /// else its own, initialized on first use: `Heap.init` maps no
    /// slab, so a VM that never builds a value pays nothing.
    pub fn ensureHeap(self: *VM) *heap_mod.Heap {
        if (self.borrowed_heap) |h| return h;
        if (self.heap == null) {
            self.heap = heap_mod.Heap.init(self.allocator);
        }
        return &self.heap.?;
    }

    /// A root scope starting at the top of the root stack.
    pub fn rootScope(self: *VM) RootScope {
        return .{ .vm = self, .base = self.roots.items.len };
    }

    /// `err`, with `error_detail` set to the formatted sentence (cut
    /// to nothing if it does not fit the buffer).
    pub fn fail(self: *VM, err: VmError, comptime fmt: []const u8, args: anytype) VmError {
        self.error_detail = std.mem.print(&self.detail_buf, fmt, args) catch blk: {
            // Too long for the buffer: keep what fits, cut at a
            // character boundary, and mark the cut.
            var w: std.Io.Writer = .fixed(&self.detail_buf);
            w.print(fmt, args) catch {};
            const mark = "…";
            var end = self.detail_buf.len - mark.len;
            while (end > 0 and self.detail_buf[end] & 0xC0 == 0x80) end -= 1;
            @memcpy(self.detail_buf[end..][0..mark.len], mark);
            break :blk self.detail_buf[0 .. end + mark.len];
        };
        return err;
    }

    /// `ArityMismatch` for a closure over `routine` called with `argc`
    /// arguments, which no member of its table takes.
    fn closureArityError(self: *VM, routine: *const Routine, argc: usize) VmError {
        return self.fail(VmError.ArityMismatch, "{s} takes {f}, got {d}", .{ routine.name, routine.arityPhrase(), argc });
    }

    /// `ArityMismatch` for `name`, which takes `min` to `max`
    /// arguments (`max` null: no upper bound), called with `argc`.
    fn arityError(self: *VM, name: []const u8, min: usize, max: ?usize, argc: usize) VmError {
        const noun = if (min == 1) "argument" else "arguments";
        const e = VmError.ArityMismatch;
        if (max == null) return self.fail(e, "{s} takes at least {d} {s}, got {d}", .{ name, min, noun, argc });
        if (max.? == min) return self.fail(e, "{s} takes {d} {s}, got {d}", .{ name, min, noun, argc });
        return self.fail(e, "{s} takes {d} to {d} arguments, got {d}", .{ name, min, max.?, argc });
    }

    // -------------------------------------------------------------------------
    // The collector's host (VM.md §9, GC.md §3)
    // -------------------------------------------------------------------------

    /// Trigger by `policy` from here on: the next cycle is due after
    /// `policy.threshold` bytes.
    pub fn setGcPolicy(self: *VM, policy: GcPolicy) void {
        self.gc_threshold = policy.threshold;
        self.gc_growth_percent = policy.growth_percent;
        self.gc_next_at = policy.threshold;
    }

    /// Whether a cycle is due at this safe point: the VM collects,
    /// owns its heap, and the heap has allocated `gc_next_at` bytes
    /// since the last cycle.
    inline fn gcDue(self: *VM) bool {
        // The counter first: below the limit, as at nearly every safe
        // point, nothing else is read.
        const h = &(self.heap orelse return false);
        if (h.allocated_since_collect < self.gc_next_at) return false;
        return self.gc_enabled and self.borrowed_heap == null and self.gc_hold == 0;
    }

    /// Run one collection cycle over this VM's heap from this VM's
    /// roots, then size the next window. Callable from a safe point
    /// only: between two instructions, when every live value is in
    /// a slot, a frame, a Var, the root stack or one of the other
    /// roots `gcRoots` walks. Tests call it directly to force a
    /// cycle.
    pub fn collectGarbage(self: *VM) void {
        std.debug.assert(self.borrowed_heap == null);
        const heap = self.ensureHeap();
        var collector = gc_mod.Collector.init(heap);
        collector.host = .{ .ctx = @ptrCast(self), .roots = &gcRoots, .trace = &gcTrace };
        collector.gray = self.gc_gray;
        self.gc_routines.clearRetainingCapacity();
        _ = collector.collect(&.{});
        self.gc_gray = collector.gray;
        self.gc_cycles += 1;
        const by_growth = heap.live_bytes / 100 * self.gc_growth_percent;
        self.gc_next_at = @max(self.gc_threshold, by_growth);
    }

    /// Every root this VM holds (GC.md §3): the backing stack in
    /// full (a stale slot above a popped frame retains its value
    /// until the slot is reused, which is sound), every frame's
    /// closure or, without one, routine constants, every Var of every
    /// namespace (root, metadata, thread binding), the saved
    /// bindings of every open `binding` frame, the root stack,
    /// pending `finally` throws, the unhandled throw, the halt
    /// result, the protocol registry's implementations, and the query
    /// values the Nextomic caches hold.
    fn gcRoots(ctx: *anyopaque, c: *gc_mod.Collector) void {
        const self: *VM = @ptrCast(@alignCast(ctx));
        for (self.stack.items) |v| c.markValue(v);
        // A frame running a closure reaches its cells and routine
        // through the closure block (`gcTrace`), marked once however
        // many frames run it; any other frame has no cells.
        for (self.frames.items) |*f| {
            if (f.closure.isNil()) self.markRoutineConsts(c, f.routine) else c.markValue(f.closure);
        }
        if (self.registry) |*reg| {
            var it = reg.map.valueIterator();
            while (it.next()) |ns| markNamespaceVars(c, ns.*);
        }
        if (self.namespace) |*ns| markNamespaceVars(c, ns);
        for (self.dyn_saves.items) |save| c.markValue(save.value);
        for (self.roots.items) |v| c.markValue(v);
        for (self.finally_stack.items) |cont| switch (cont.reason) {
            .throwing => |v| c.markValue(v),
            .normal => {},
        };
        if (self.unhandled_throw) |v| c.markValue(v);
        if (self.parked_realize) |p| switch (p) {
            .thrown => |v| c.markValue(v),
            .err => {},
        };
        for (self.origins.items) |o| c.markValue(o.value);
        c.markValue(self.result);
        for (self.protocol_registry.items) |*proto| {
            for (proto.methods.items) |*method| {
                var impls = method.impls.valueIterator();
                while (impls.next()) |impl| c.markValue(impl.*);
                if (method.default_impl) |d| c.markValue(d);
            }
        }
        if (self.nextomic_query_state) |state| self.nextomic_query_mark.?(state, c);
    }

    fn markNamespaceVars(c: *gc_mod.Collector, ns: *const Namespace) void {
        var it = ns.vars.valueIterator();
        while (it.next()) |v| {
            c.markValue(v.*.root);
            c.markValue(v.*.meta);
            c.markValue(v.*.thread_value);
        }
    }

    /// The heap constants of `routine`, of every member of its arity
    /// table and, recursively, of the routines in their pools: string
    /// and bignum literals live on the heap and a routine is reachable
    /// from every frame running it and every closure over it. A member
    /// is reached only through its table: a closure names the first
    /// clause, and a frame running another member roots the closure.
    fn markRoutineConsts(self: *VM, c: *gc_mod.Collector, routine: *const Routine) void {
        const a = routine.arities orelse return self.markClauseConsts(c, routine);
        var members = a.members();
        while (members.next()) |r| self.markClauseConsts(c, r);
    }

    /// `markRoutineConsts` of one routine. One with more than a few
    /// constants or nested routines is walked once per cycle, however
    /// many closures reach it; a small one costs less to walk again
    /// than to look up.
    fn markClauseConsts(self: *VM, c: *gc_mod.Collector, routine: *const Routine) void {
        if (routine.consts.len + routine.capture_descs.len > 8) {
            const seen = self.gc_routines.getOrPut(self.allocator, routine) catch null;
            if (seen) |entry| if (entry.found_existing) return;
        }
        for (routine.consts) |v| c.markValue(v);
        for (routine.capture_descs) |d| self.markRoutineConsts(c, d.routine);
    }

    /// Trace a closure (its cells and its routine's constants) or a
    /// cell (its value); the collector has marked `h` already.
    fn gcTrace(ctx: *anyopaque, h: *heap_mod.HeapHeader, c: *gc_mod.Collector) void {
        const self: *VM = @ptrCast(@alignCast(ctx));
        const k: value_mod.Kind = @fromBackingInt(@intCast(h.kind));
        switch (k) {
            .function => {
                const closure = heap_mod.Heap.bodyOf(Closure, h);
                for (closure.upvalues) |cell| c.mark(cellHeader(cell));
                self.markRoutineConsts(c, closure.routine);
            },
            .cell_internal => c.markValue(heap_mod.Heap.bodyOf(UpvalCell, h).value),
            else => unreachable,
        }
    }

    // -------------------------------------------------------------------------
    // Dynamic bindings (VM.md §6.5)
    // -------------------------------------------------------------------------

    /// Open a binding frame: every `(var, value)` pair rebinds a
    /// dynamic Var for the frame's extent, saving the binding it
    /// replaces. A Var that is not dynamic is `NotDynamic` and
    /// nothing is pushed. `binding` pairs the call with
    /// `popBindings` in a `finally`.
    pub fn pushBindings(self: *VM, vars: []const *Var, values: []const Value) VmError!void {
        std.debug.assert(vars.len == values.len);
        for (vars) |v| if (!v.dynamic) return VmError.NotDynamic;
        self.dyn_saves.ensureUnusedCapacity(self.allocator, vars.len) catch return VmError.OutOfMemory;
        self.dyn_frames.append(self.allocator, @intCast(self.dyn_saves.items.len)) catch return VmError.OutOfMemory;
        for (vars, values) |v, value| {
            self.dyn_saves.appendAssumeCapacity(.{ .v = v, .value = v.thread_value, .bound = v.thread_bound });
            v.thread_value = value;
            v.thread_bound = true;
        }
    }

    /// Close the innermost binding frame, restoring each Var's
    /// previous binding in reverse order. With no frame open it
    /// does nothing.
    pub fn popBindings(self: *VM) void {
        const start = self.dyn_frames.pop() orelse return;
        while (self.dyn_saves.items.len > start) {
            const save = self.dyn_saves.pop().?;
            save.v.thread_value = save.value;
            save.v.thread_bound = save.bound;
        }
    }

    /// Register a new record type in the per-VM record registry and
    /// name it in the interner for printing. Returns the dense `u32`
    /// type_id. Redefining `(ns, name)` registers a new type, as
    /// Clojure's `defrecord` makes a new class: values built before
    /// keep the old type. Names are duped into `self.allocator` for
    /// the VM's lifetime. PROTOCOLS.md §3.1.
    pub fn registerRecordType(
        self: *VM,
        ns_name: []const u8,
        type_name: []const u8,
        field_names: []const []const u8,
    ) !u32 {
        if (self.owner) |o| return o.registerRecordType(ns_name, type_name, field_names);
        const new_id: u32 = @intCast(self.record_registry.items.len);
        const ns_dup = try self.allocator.dupe(u8, ns_name);
        errdefer self.allocator.free(ns_dup);
        const name_dup = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(name_dup);
        const fields_dup = try self.allocator.alloc([]const u8, field_names.len);
        errdefer self.allocator.free(fields_dup);
        var initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < initialized) : (i += 1) self.allocator.free(fields_dup[i]);
        }
        for (field_names, 0..) |fname, i| {
            fields_dup[i] = try self.allocator.dupe(u8, fname);
            initialized = i + 1;
        }
        // Nothing fails once the entry is in: it owns the names.
        try self.record_registry.ensureUnusedCapacity(self.allocator, 1);
        try self.ensureInterner().nameRecordType(new_id, ns_name, type_name);
        self.record_registry.appendAssumeCapacity(.{
            .id = new_id,
            .ns_name = ns_dup,
            .type_name = name_dup,
            .field_names = fields_dup,
        });
        return new_id;
    }

    /// The type id of `nexis.core/Reduced`, the one-field record
    /// (`:val`) that `reduced` builds and `reduce` stops on.
    pub fn ensureReducedType(self: *VM) !u32 {
        if (self.owner) |o| return o.ensureReducedType();
        if (self.reduced_type_id) |id| return id;
        const id = try self.registerRecordType("nexis.core", "Reduced", &.{"val"});
        self.reduced_type_id = id;
        return id;
    }

    /// Register a new protocol in
    /// the per-VM protocol registry. Method-spec is a slice of
    /// (interned-method-name-id, method-name-string) pairs;
    /// extend-protocol fills `impls` later. Returns the dense
    /// `u32` protocol id. Redefining `(ns, name)` registers a new
    /// protocol with no impls, as Clojure's `defprotocol` does.
    pub fn registerProtocol(
        self: *VM,
        ns_name: []const u8,
        protocol_name: []const u8,
        method_specs: []const ProtocolMethodSpec,
    ) !u32 {
        if (self.owner) |o| return o.registerProtocol(ns_name, protocol_name, method_specs);
        const new_id: u32 = @intCast(self.protocol_registry.items.len);
        const ns_dup = try self.allocator.dupe(u8, ns_name);
        errdefer self.allocator.free(ns_dup);
        const name_dup = try self.allocator.dupe(u8, protocol_name);
        errdefer self.allocator.free(name_dup);

        var methods: std.ArrayList(ProtocolMethod) = try .initCapacity(self.allocator, method_specs.len);
        errdefer {
            for (methods.items) |m| self.allocator.free(m.name);
            methods.deinit(self.allocator);
        }
        for (method_specs) |spec| {
            methods.appendAssumeCapacity(.{ .name_id = spec.name_id, .name = try self.allocator.dupe(u8, spec.name) });
        }
        try self.protocol_registry.append(self.allocator, .{
            .id = new_id,
            .ns_name = ns_dup,
            .name = name_dup,
            .methods = methods,
        });
        return new_id;
    }

    pub fn protocolById(self: *VM, id: u32) ?*ProtocolEntry {
        const protocols = self.home().protocol_registry.items;
        return if (id < protocols.len) &protocols[id] else null;
    }

    /// Register an impl `(protocol_id, method_name_id,
    /// dispatch_key) → impl`. Used by `extend-protocol` and by
    /// inline `defrecord` impls.
    pub fn extendProtocol(
        self: *VM,
        protocol_id: u32,
        method_name_id: u32,
        key: DispatchKey,
        impl: Value,
    ) !void {
        const proto = self.protocolById(protocol_id) orelse return error.NoProtocolMethod;
        const method = proto.method(method_name_id) orelse return error.NoProtocolMethod;
        try method.impls.put(self.home().allocator, key.canonical(), impl);
    }

    /// Call the protocol fn `callee` with `args`: find the impl for
    /// the receiver's (`args[0]`) dispatch key, or the protocol's
    /// default, and call it. `NoProtocolImpl` when there is neither.
    pub fn dispatchProtocolMethod(
        self: *VM,
        callee: Value,
        args: []const Value,
    ) VmError!Value {
        std.debug.assert(callee.kind() == .protocol_fn);
        const protocol_id = protocol_mod.protocolFnProtocolId(callee);
        const method_name_id = protocol_mod.protocolFnMethodNameId(callee);
        const proto = self.protocolById(protocol_id) orelse return VmError.NoProtocolImpl;
        const method = proto.method(method_name_id) orelse return VmError.NoProtocolMethod;
        if (args.len == 0) return self.arityError(method.name, 1, null, 0);

        // Look up impl by dispatch key (receiver is args[0]).
        const key = DispatchKey.ofValue(args[0]);
        const impl_v: Value = blk: {
            if (method.impls.get(key)) |impl| break :blk impl;
            if (method.default_impl) |dflt| break :blk dflt;
            return self.fail(VmError.NoProtocolImpl, "no impl of {s} for {s}", .{ method.name, kindPhrase(args[0].kind()) });
        };

        // Invoke. callValue handles closures, native_fns, etc.
        return try self.callValue(impl_v, args);
    }

    /// Allocate a closure block on the heap with room for
    /// `upvalue_count` cell pointers in its tail and return the
    /// `.function` Value naming it. The tail is the closure's
    /// `upvalues` array; the caller fills it before the Value can
    /// reach a slot. `asClosure()` is the matched accessor. The
    /// dispatch trusts `routine` (§8) and a call trusts the closure to
    /// carry a cell for each of its upvalues (§6), so the caller makes
    /// sure of both: `closure:make` takes a descriptor of a routine
    /// verified with every routine under it, and the image loader
    /// verifies what it made once the image is whole (§5).
    pub fn allocClosure(self: *VM, routine: *const Routine, upvalue_count: usize) !Value {
        const heap = self.ensureHeap();
        const body_size = @sizeOf(Closure) + upvalue_count * @sizeOf(*UpvalCell);
        const h = try heap.alloc(.function, body_size);
        const body = heap_mod.Heap.bodyOf(Closure, h);
        const tail: [*]*UpvalCell = @ptrCast(@alignCast(@as([*]u8, @ptrCast(body)) + @sizeOf(Closure)));
        body.* = .{ .routine = routine, .upvalues = tail[0..upvalue_count] };
        return heap_mod.Heap.valueFromHeader(.function, h);
    }

    /// The closure body of a `.function` Value. Asserts the kind in
    /// safety builds; in release the cast is direct.
    pub fn asClosure(v: Value) *const Closure {
        std.debug.assert(v.kind() == .function);
        return heap_mod.Heap.bodyOf(Closure, heap_mod.Heap.asHeapHeader(v));
    }

    /// The writable cell-pointer tail of a closure block; only
    /// `closure:make` writes it, once, right after `allocClosure`.
    fn closureUpvaluesMut(v: Value) []*UpvalCell {
        const body = heap_mod.Heap.bodyOf(Closure, heap_mod.Heap.asHeapHeader(v));
        return @constCast(body.upvalues);
    }

    /// Call any callable with `args` from a native (VM.md §6, "Native
    /// re-entry"). `args`, which must not point into `vm.stack`, are
    /// rooted for the call: in a closure's window, else on the root
    /// stack; what the native keeps across the call is its own to root
    /// (GC.md §11.5). A throw caught below the call is
    /// `ControlTransferred`, which the native returns unchanged.
    pub fn callValue(self: *VM, callee: Value, args: []const Value) VmError!Value {
        if (callee.kind() == .native_fn) {
            const native = asNativeFn(callee);
            if (native.leaf and native.takes(args.len)) return self.callNativeLeaf(native, args, callee);
        }
        return self.callGeneral(callee, args);
    }

    /// A leaf's call on `args` as they lie, unrooted, while no cycle is
    /// due (§6): once one is, since a leaf allocates and cannot collect,
    /// and when the leaf body refuses the receiver (`NeedsReentry`), the
    /// call goes the general way, rooted, past a safe point.
    inline fn callNativeLeaf(self: *VM, native: *const NativeFn, args: []const Value, callee: Value) VmError!Value {
        if (!self.gcDue()) {
            if (native.call(self, args)) |r| {
                countNative(native);
                return r;
            } else |err| if (err != VmError.NeedsReentry) return err;
        }
        return self.callGeneral(callee, args);
    }

    /// `callValue` past its leaf call: a closure entered and run by the
    /// loop, anything else called with its arguments rooted.
    fn callGeneral(self: *VM, callee: Value, args: []const Value) VmError!Value {
        try self.checkNesting();
        if (callee.kind() != .function) {
            const scope = self.rootScope();
            defer scope.release();
            try scope.push(callee);
            try scope.pushAll(args);
            // A native called from a native reaches no closure frame's
            // safe point, so a loop of them (`(reduce conj #{} xs)`)
            // would otherwise run to the end without collecting; the
            // arguments are rooted and the caller keeps what it holds
            // on its own root scope (GC.md §7, §11.5).
            if (self.gcDue()) self.collectGarbage();
            return self.callDirect(callee, args);
        }
        const base = self.stack.items.len;
        var result_cell = HostCallResult{};
        const depth = self.frames.items.len;
        const link: Link = .{ .host_result = &result_cell };
        // The arguments go past the stack's end, where the callee's
        // window begins.
        const direct = base + args.len <= self.stack.capacity and blk: {
            for (args, self.stack.items.ptr[base..][0..args.len]) |arg, *slot| slot.* = arg;
            break :blk self.enterClosureDirect(callee, base, args.len, link) != null;
        };
        if (!direct) {
            self.stack.appendSlice(self.allocator, args) catch return VmError.OutOfMemory;
            self.enterClosure(callee, base, args.len, base, link) catch |err| {
                self.stack.shrinkRetainingCapacity(base);
                return err;
            };
        }
        try self.loop(depth);
        return result_cell.get();
    }

    /// Every re-entry nests a native call, and most a run loop, on the
    /// native stack: past the guard or `max_nested_runs` it is
    /// `StackOverflow` (§13.1).
    inline fn checkNesting(self: *VM) VmError!void {
        stack_guard.check() catch return VmError.StackOverflow;
        if (self.nested_runs >= self.max_nested_runs) return VmError.StackOverflow;
    }

    /// A `Callback`'s call of its closure, from the depth and stack
    /// length it was prepared at, its arguments already in the window:
    /// the locals start nil, the prepared frame is pushed and runs
    /// until it returns into the callback's cell, as `callValue`'s
    /// would under `loop`. The loop's first pass is entered here at
    /// the callee's first instruction, after the safe point `loop`'s
    /// entry is: the frame is the one it would run, so the pass needs
    /// no test. A pass that ends without an error has returned, or a
    /// throw went past the frame, which leaves the cell's `done` unset;
    /// only an error goes on to the loop, which takes it as its own
    /// pass would. The value is read from the cell by the caller, a
    /// word at a time as the return wrote it.
    fn callPrepared(self: *VM, cb: *Callback) VmError!void {
        const depth = cb.depth;
        nilLocals(self.stack.items.ptr + cb.locals, cb.nil_count);
        self.stack.items.len = cb.window_end;
        self.frames.items.len = depth + 1;
        const frame = &self.frames.items[depth];
        frame.* = cb.frame;
        std.debug.assert(frame.host_result == &cb.result);
        cb.result.done = false;
        const outer = self.loop_depth;
        self.loop_depth = depth;
        self.nested_runs += 1;
        defer {
            self.loop_depth = outer;
            self.nested_runs -= 1;
        }
        if (self.gcDue()) self.collectGarbage();
        if (counting) opcode_counts[opIndex(cb.first)] += 1;
        const status = cb.first_handler(self, frame, cb.first, 1);
        if (status != .ok) {
            try self.settle(status.err());
            try self.drive();
        }
    }

    /// A prepared call's locals, nil: the usual handful in one run,
    /// whatever their count, since a slot past the window is past the
    /// stack's length, dead.
    inline fn nilLocals(locals: [*]Value, nil_count: usize) void {
        locals[0..Callback.nil_run].* = @splat(value_mod.nilValue());
        if (nil_count > Callback.nil_run) nilSlots(locals[Callback.nil_run..nil_count]);
    }

    /// `callPrepared` of a batch's first element, its arguments in the
    /// window: every later element runs in the same pass, started by
    /// the return of the one before (`batchNext`). Without a return of
    /// the last, a throw went past the native.
    fn callBatch(self: *VM, cb: *Callback) VmError!void {
        cb.result.step = switch (cb.batch.step) {
            inline else => |step| batchNext(step),
        };
        defer cb.result.step = null;
        try self.callPrepared(cb);
        if (!cb.result.done) return VmError.ControlTransferred;
    }

    /// The return of a batch's element into its cell: its result to its
    /// place (an accumulator stays in the window), then, in the same
    /// frame, the next element's arguments and the locals nil. False
    /// when the batch is over, after its last element or a `fold`'s
    /// record, whose value is in the cell. Each element is a call of
    /// its own, at the depth the first one ran at, in the frame the
    /// first one pushed, which nothing a call runs changes but its
    /// `pc`: its pop and the next one's push in one (VM.md §6).
    inline fn batchStep(self: *VM, frame: *Frame, hr: *HostCallResult, comptime step: Callback.Batch.Step) bool {
        const cb: *Callback = @fieldParentPtr("result", hr);
        const b = &cb.batch;
        std.debug.assert(b.step == step and self.frames.items.len == cb.depth + 1 and frame == &self.frames.items[cb.depth]);
        std.debug.assert(frame.routine == cb.frame.routine and frame.base_slot == cb.frame.base_slot and frame.entry_stack_len == cb.frame.entry_stack_len);
        // The value may sit in the window's slots, which the next
        // element's arguments overwrite.
        const r = loadWords(&hr.value);
        const i = b.i + 1;
        b.i = i;
        switch (step) {
            .each_slots => storeWords(&b.out.slots[i - 1], r),
            .each_roots => self.roots.items[b.out.roots + i - 1] = r,
            .fold, .fold_range => if (r.kind() == .record) return false,
        }
        if (i == b.n) return false;
        const w = self.stack.items.ptr + cb.base;
        switch (step) {
            .each_slots, .each_roots => storeWords(&w[0], b.items[i]),
            .fold => {
                storeWords(&w[0], r);
                storeWords(&w[1], b.items[i]);
            },
            .fold_range => {
                b.x = Callback.rangeNext(b.x, b.by);
                storeWords(&w[0], r);
                storeWords(&w[1], b.x);
            },
        }
        nilLocals(w + @as(usize, if (step == .fold or step == .fold_range) 2 else 1), cb.nil_count);
        self.stack.items.len = cb.window_end;
        return true;
    }

    /// Call `callee`, anything but a closure, with `args`, to
    /// completion on the native stack: a native (after its arity
    /// check), a protocol fn (dispatched on `args[0]`), a Var (its
    /// value in force, as Clojure's `Var.invoke`), or a lookup
    /// (`callLookup`). Anything else is `NotCallable`.
    fn callDirect(self: *VM, callee: Value, args: []const Value) VmError!Value {
        const overflows = dispatch_mod.spoilCount();
        // A call that fails spoils nothing its caller sees, so the
        // overflows under it are consumed with it.
        errdefer self.dropSpoils(overflows);
        const result = switch (callee.kind()) {
            .native_fn => blk: {
                const native = asNativeFn(callee);
                if (!native.takes(args.len)) return self.arityError(native.name, native.min_arity, if (native.max_arity) |m| m else null, args.len);
                countNative(native);
                break :blk try (native.general orelse native.call)(self, args);
            },
            .protocol_fn => try self.dispatchProtocolMethod(callee, args),
            .var_ => try self.callValue(asVar(callee).current() orelse return VmError.UnboundVar, args),
            else => blk: {
                if (!isLookupCallable(callee.kind())) {
                    return self.fail(VmError.NotCallable, "{s} is not callable", .{kindPhrase(callee.kind())});
                }
                break :blk try callLookupIn(self, callee, args);
            },
        };
        try self.checkDeepData(overflows);
        return result;
    }

    /// `=`, `hash` and printing answer `false`, `0` or `#<too deep>`
    /// past the stack guard, or at a lazy block they could not realize,
    /// and count a spoil (dispatch.zig); a call or opcode that compared
    /// or hashed across one raises instead of returning that answer: the
    /// parked failure of the isolated realization (docs/LAZY.md §6), a
    /// thrown value or an error, else the catchable `:stack-overflow`
    /// (SEMANTICS §2.7). The raise consumes the spoils it reports, so an
    /// enclosing native whose callback caught the throw does not raise
    /// it again.
    pub inline fn checkDeepData(self: *VM, spoils_before: u64) VmError!void {
        // Inline, the common case costs a read of the counter; the raise
        // saves the registers it needs only when it runs.
        if (dispatch_mod.spoilCount() != spoils_before) return self.raiseDeepData(spoils_before);
    }

    /// Consume the spoils counted since `spoils_before` for a call that
    /// fails for another reason, with the failure an isolated
    /// realization parked under it: left parked, it would make every
    /// later isolated realization fail and be raised by an unrelated
    /// call (docs/LAZY.md §6). A failure parked before the snapshot
    /// belongs to an enclosing call and stays.
    pub fn dropSpoils(self: *VM, spoils_before: u64) void {
        dispatch_mod.rewindSpoils(spoils_before);
        if (self.parked_realize != null and self.parked_at >= spoils_before) self.parked_realize = null;
    }

    noinline fn raiseDeepData(self: *VM, spoils_before: u64) VmError {
        dispatch_mod.rewindSpoils(spoils_before);
        if (self.parked_realize) |p| {
            self.parked_realize = null;
            return switch (p) {
                .thrown => |v| self.throwValue(v),
                .err => |e| e,
            };
        }
        return self.fail(VmError.StackOverflow, "a value nests too deeply to compare, hash or print", .{});
    }

    // -------------------------------------------------------------------------
    // Realizing lazy seqs (docs/LAZY.md §6)
    // -------------------------------------------------------------------------

    /// Make this VM the one `=` and `hash` realize a lazy block on, until
    /// the returned host is restored.
    pub fn installLazyHost(self: *VM) ?lazy_mod.Host {
        const saved = lazy_mod.host;
        lazy_mod.host = .{ .ctx = @ptrCast(self), .realize = &realizeIsolated };
        return saved;
    }

    /// The seq of `lz`, realized in isolation for `dispatch`, which has
    /// no VM and no error path and whose callers hold unrooted nodes: no
    /// cycle runs while the body does, and its throw is caught by the
    /// barrier `nexis.core/realize-caught`, a closure, and parked with
    /// any error the barrier cannot catch. Null on a failure, at once
    /// while one is parked. The barrier's answer is checked, not
    /// trusted, since a program can rebind its Var: `[false thrown]`
    /// parks the throw, else the seq is the block's own once it is
    /// realized, and anything else is `KindMismatch`.
    fn realizeIsolated(ctx: *anyopaque, lz: Value) ?Value {
        const self: *VM = @ptrCast(@alignCast(ctx));
        if (self.parked_realize != null) return null;
        const barrier = blk: {
            const registry = if (self.home().registry) |*r| r else break :blk null;
            const v = registry.core.lookupLocal("realize-caught") orelse break :blk null;
            break :blk v.current();
        } orelse return self.park(.{ .err = VmError.UnboundVar });
        self.gc_hold += 1;
        defer self.gc_hold -= 1;
        const r = self.callValue(barrier, &.{lz}) catch |err| return self.park(.{ .err = err });
        if (r.kind() == .persistent_vector and vector_mod.count(r) == 2 and vector_mod.nth(r, 0).isFalsy()) {
            return self.park(.{ .thrown = vector_mod.nth(r, 1) });
        }
        if (lazy_mod.state(lz) == .realized) return lazy_mod.result(lz);
        return self.park(.{ .err = VmError.KindMismatch });
    }

    /// Park `failure`, which the caller counts as a spoil next.
    fn park(self: *VM, failure: ParkedRealize) ?Value {
        self.parked_realize = failure;
        self.parked_at = dispatch_mod.spoilCount();
        return null;
    }

    /// Realize every lazy seq in `v`, a value the host holds outside
    /// any run (a REPL or `-e` result it is about to print, a test's
    /// result): with this VM installed for `=` and `hash` and the error
    /// trace recorded as a failing run's would be.
    pub fn realizeOutside(self: *VM, v: Value) VmError!void {
        const ops = lazy_ops orelse return;
        const scope = self.rootScope();
        defer scope.release();
        try scope.push(v);
        const saved = self.installLazyHost();
        defer lazy_mod.host = saved;
        ops.realize_all(self, v) catch |err| {
            self.recordErrorTrace(err);
            return err;
        };
    }

    /// Where a closure frame's value goes when it returns.
    const Link = struct {
        return_dst: u16 = 0,
        host_result: ?*HostCallResult = null,
    };

    /// Enter `callee`, a closure whose `argc` arguments sit in
    /// `stack[base..base + argc]`, the one entry path for `call:call`,
    /// `callValue`: pick the routine the count enters, the closure's own
    /// or a member of its arity table, else raise the arity error, check
    /// the routine's shape, grow the stack over the callee's window,
    /// pack the arguments past the fixed ones into the rest list (nil
    /// when there are none, as in Clojure), nil every other slot the
    /// window and the arguments cover, and push the frame.
    /// `entry_stack_len` is the stack length its pop restores.
    fn enterClosure(self: *VM, callee: Value, base: usize, argc: usize, entry_stack_len: usize, link: Link) VmError!void {
        const closure = asClosure(callee);
        const routine = closure.routine.entryFor(argc) orelse return self.closureArityError(closure.routine, argc);
        const fixed: usize = routine.fixed_arity;
        // A variadic routine needs a slot for its rest parameter.
        if (routine.slot_count < fixed + @intFromBool(routine.variadic)) return VmError.BytecodeCorruption;

        // Every check that can refuse the call runs before the stack
        // or the frames change, so a refused call leaves both as they
        // were.
        if (self.frames.items.len >= self.max_frames) return VmError.StackOverflow;
        if (self.frames.items.len == self.frames.capacity) {
            self.frames.ensureUnusedCapacity(self.allocator, 1) catch return VmError.OutOfMemory;
        }
        const window_end = base + routine.slot_count;
        const args_end = base + argc;
        if (window_end > self.stack.items.len) {
            if (window_end > self.stack.capacity) {
                self.stack.ensureTotalCapacity(self.allocator, window_end) catch return VmError.OutOfMemory;
            }
            // The slots this uncovers are nil'd below with the rest.
            self.stack.items.len = window_end;
        }
        errdefer self.stack.shrinkRetainingCapacity(entry_stack_len);
        // The rest list is built while the excess arguments still
        // hold their values.
        var live_end = args_end;
        if (routine.variadic) {
            var rest = value_mod.nilValue();
            if (argc > fixed) {
                const heap = self.ensureHeap();
                rest = list_mod.empty(heap) catch return VmError.OutOfMemory;
                var j = args_end;
                while (j > base + fixed) {
                    j -= 1;
                    rest = list_mod.cons(heap, self.stack.items[j], rest) catch return VmError.OutOfMemory;
                }
            }
            self.stack.items[base + fixed] = rest;
            live_end = base + fixed + 1;
        }
        // Locals start nil, and so do excess argument slots past the
        // window: whatever they held is dead.
        nilSlots(self.stack.items[live_end..@max(args_end, window_end)]);
        // An argument list longer than the window was appended by
        // `callValue` and ends at the window.
        const extent = @max(entry_stack_len, window_end);
        if (self.stack.items.len > extent) self.stack.shrinkRetainingCapacity(extent);
        self.frames.appendAssumeCapacity(calleeFrame(callee, routine, base, entry_stack_len, link));
        self.noteHighWater(self.frames.items.len, self.stack.items.len);
    }

    /// The frame of a call of the closure `callee` entering `routine`
    /// with its window at `base`.
    inline fn calleeFrame(callee: Value, routine: *const Routine, base: usize, entry_stack_len: usize, link: Link) Frame {
        return .{
            .routine = routine,
            .base_slot = @intCast(base),
            .entry_stack_len = @intCast(entry_stack_len),
            .return_dst = link.return_dst,
            .upvalues = asClosure(callee).upvalues,
            .closure = callee,
            .host_result = link.host_result,
        };
    }

    /// The high-water marks (§11) past a push to `frames` frames and a
    /// stack `stack` long, in builds that keep them.
    inline fn noteHighWater(self: *VM, frames: usize, stack: usize) void {
        if (!track_high_water) return;
        self.frame_high_water = @max(self.frame_high_water, frames);
        self.stack_high_water = @max(self.stack_high_water, stack);
    }

    /// `enterClosure` for the common call, a closure called with a
    /// fixed arity of its own or of a member of its arity table, where
    /// the frame chain and the stack's capacity have room: the frame is
    /// pushed without allocating or growing anything. Returns the new
    /// frame, or null, having changed nothing, for a call
    /// `enterClosure` has to make. The arguments sit at
    /// `stack[base..base + argc]`, at or past the stack's length, and
    /// the frame's pop restores the length as it is.
    inline fn enterClosureDirect(self: *VM, callee: Value, base: usize, argc: usize, link: Link) ?*Frame {
        const routine = asClosure(callee).routine.memberFor(argc) orelse return null;
        return self.pushDirect(callee, routine, base, argc, link);
    }

    /// `enterClosureDirect` past its arity test: `callee` called with
    /// `argc` arguments, the fixed arity of `routine`, the member of its
    /// table it enters.
    inline fn pushDirect(self: *VM, callee: Value, routine: *const Routine, base: usize, argc: usize, link: Link) ?*Frame {
        const depth = self.frames.items.len;
        if (depth >= self.max_frames or depth == self.frames.capacity) return null;
        const args_end = base + argc;
        const window_end = base + routine.slot_count;
        if (window_end < args_end or window_end > self.stack.capacity) return null;
        const entry_stack_len = self.stack.items.len;
        if (window_end > entry_stack_len) self.stack.items.len = window_end;
        nilSlots(self.stack.items[args_end..window_end]);
        self.frames.items.len = depth + 1;
        self.noteHighWater(depth + 1, self.stack.items.len);
        const frame = &self.frames.items[depth];
        frame.* = calleeFrame(callee, routine, base, entry_stack_len, link);
        return frame;
    }

    /// The most arguments `opCall` passes a native from its own buffer.
    const max_native_args = 8;

    /// Set `slots` to nil: a callee's locals, usually a handful, so
    /// they are written in place rather than through a `memset` call.
    inline fn nilSlots(slots: []Value) void {
        var rest = slots;
        while (rest.len >= 4) : (rest = rest[4..]) rest[0..4].* = @splat(value_mod.nilValue());
        switch (rest.len) {
            0 => {},
            1 => rest[0] = value_mod.nilValue(),
            2 => rest[0..2].* = @splat(value_mod.nilValue()),
            3 => rest[0..3].* = @splat(value_mod.nilValue()),
            else => unreachable,
        }
    }

    /// Run a compiled top-level `routine` to its `return` as a
    /// nested call: a frame above whatever is executing, on the
    /// stack above its slots, so the loader can run a required
    /// file's forms from inside a running program (a `require`
    /// reached through the compiler hooks) without retargeting the
    /// frame that is executing. The VM is left as it was found,
    /// idle or mid-execution; a throw the routine does not catch
    /// propagates as `UncaughtThrow` or, when the caller's handler
    /// (one installed beneath the nested frame) takes it,
    /// `ControlTransferred`, exactly as `callValue` reports it.
    pub fn runRoutine(self: *VM, routine: *const Routine) VmError!Value {
        try self.checkNesting();
        const saved = self.installLazyHost();
        defer lazy_mod.host = saved;
        try self.verifyTop(routine);
        const base_slot: usize = self.stack.items.len;
        self.stack.appendNTimes(self.allocator, value_mod.nilValue(), routine.slot_count) catch return VmError.OutOfMemory;
        var result_cell = HostCallResult{};
        const initial_depth = self.frames.items.len;
        try self.pushFrame(.{
            .routine = routine,
            .base_slot = @intCast(base_slot),
            .entry_stack_len = @intCast(base_slot),
            .pc = 0,
            .host_result = &result_cell,
        });
        self.loop(initial_depth) catch |err| {
            self.recordErrorTrace(err);
            return err;
        };
        return result_cell.get();
    }

    /// The fetch-and-dispatch loop, the only one: until the VM
    /// halts when `depth` is 0 (`run`), or until the frame chain is
    /// back to `depth` frames (`callValue`, `runRoutine`, which
    /// pushed the frame above it). A recoverable error becomes a
    /// keyword throw when a handler is in force
    /// (`handleRuntimeError`); any other error, or one with no
    /// handler, leaves the loop with the frames as they stood. When a
    /// throw unwinds past `depth` the loop ends without its frame's
    /// return, which the caller detects through its result cell.
    /// Each pass enters the dispatch chain (§8), which runs until the
    /// loop's frame returns or an instruction fails.
    fn loop(self: *VM, depth: usize) VmError!void {
        const outer = self.loop_depth;
        self.loop_depth = depth;
        self.nested_runs += 1;
        defer {
            self.loop_depth = outer;
            self.nested_runs -= 1;
        }
        try self.drive();
    }

    /// `loop`'s passes through the chain, at the depth it set.
    fn drive(self: *VM) VmError!void {
        while (self.running()) {
            const status = opEnter(self, self.currentFrame(), undefined, undefined);
            if (status != .ok) try self.settle(status.err());
        }
    }

    /// What ends a pass with `err`: the throw a handler takes it as, or
    /// the error the loop leaves with.
    inline fn settle(self: *VM, err: VmError) VmError!void {
        switch (err) {
            // A native's throw was caught below it: frames and pc are
            // already at the handler.
            VmError.ControlTransferred => {},
            else => try self.handleRuntimeError(err),
        }
    }

    /// Whether the innermost `loop` has more to run: until the VM
    /// halts at depth 0, else until its frame has returned.
    inline fn running(self: *const VM) bool {
        return if (self.loop_depth == 0) !self.halted else self.frames.items.len > self.loop_depth;
    }

    /// Pack a `*Var` into a `Value` of kind `.var_`.
    /// Used by `var:store-var` (returns the Var object so
    /// `(def x 5)` evaluates to the Var, not the value 5) and
    /// by `var:var-object` (Clojure's `(var x)` reader form).
    /// The payload is the raw `*Var`, not a `*HeapHeader`: Vars
    /// are immortal arena objects the collector never sweeps.
    pub fn varToValue(v: *Var) Value {
        return Value{
            .tag = @as(u64, @backingInt(value_mod.Kind.var_)),
            .payload = @intFromPtr(v),
        };
    }

    pub fn asVar(v: Value) *Var {
        std.debug.assert(v.kind() == .var_);
        return @ptrFromInt(v.payload);
    }

    /// Allocate an UpvalCell block on the heap and return the
    /// VM-private `Value` of kind `.cell_internal` whose payload is
    /// the block header. When the compiler determines a binding is
    /// captured, it emits `closure:box-local s`, which boxes
    /// `slot[s]` and replaces it with the returned cell-value.
    pub fn allocCell(self: *VM, initial: Value, initialized: bool) !Value {
        const h = try self.ensureHeap().alloc(.cell_internal, @sizeOf(UpvalCell));
        heap_mod.Heap.bodyOf(UpvalCell, h).* = .{ .value = initial, .initialized = initialized };
        return Value{
            .tag = @as(u64, @backingInt(value_mod.Kind.cell_internal)),
            .payload = @intFromPtr(h),
        };
    }

    /// Decode a `.cell_internal` Value to its underlying
    /// `*UpvalCell`. Returns `ExpectedCell` if the Value's kind
    /// is anything else (the `:expected-cell` runtime trap).
    pub fn asCell(v: Value) VmError!*UpvalCell {
        if (v.kind() != value_mod.Kind.cell_internal) return VmError.ExpectedCell;
        return heap_mod.Heap.bodyOf(UpvalCell, @ptrFromInt(v.payload));
    }

    /// Pointer to the currently-executing frame. **Single-shot use
    /// only**: a `frames.append()` in any code path between fetch
    /// and use will invalidate this pointer. For multi-step access,
    /// read the relevant fields into locals or the frame's index.
    inline fn currentFrame(self: *VM) *Frame {
        // Empty frame stack is a VM invariant violation, not a
        // recoverable runtime condition.
        std.debug.assert(self.frames.items.len > 0);
        return &self.frames.items[self.frames.items.len - 1];
    }

    /// Slot `slot_index` of `frame`, `OperandOutOfRange` past the
    /// frame's `slot_count`, which bounds what the frame sees of the
    /// stack it shares (§7). One-shot: growing the stack moves it.
    inline fn slotPtrIn(self: *VM, frame: *const Frame, slot_index: u12) VmError!*Value {
        if (slot_index >= frame.routine.slot_count) return VmError.OperandOutOfRange;
        return self.slotAt(frame, slot_index);
    }

    /// Slot `slot_index` of `frame`, which the caller has checked
    /// against `frame.routine.slot_count`.
    inline fn slotAt(self: *VM, frame: *const Frame, slot_index: usize) *Value {
        const absolute: usize = @as(usize, frame.base_slot) + slot_index;
        std.debug.assert(absolute < self.stack.items.len);
        return &self.stack.items.ptr[absolute];
    }

    /// The value operand `op` reads in `frame` (VM.md §4): a `u` operand
    /// reads its cell's contents, never the cell.
    inline fn resolveIn(self: *VM, frame: *const Frame, op: Operand) VmError!Value {
        var tmp: Value = undefined;
        return (try self.operandPtr(frame, op, &tmp)).*;
    }

    /// Where `resolveIn(frame, op)` reads its value: the slot, the
    /// constant, the initialized cell or the bound Var in place, found
    /// inline, or `tmp`, which every other operand is resolved into
    /// out of line, its trap included. The hot handlers read
    /// through the pointer, so the value never passes through an
    /// error union.
    inline fn operandPtr(self: *VM, frame: *const Frame, op: Operand, tmp: *Value) VmError!*const Value {
        if (self.peek(frame, op)) |p| return p;
        try self.resolveOther(frame, op, tmp);
        return tmp;
    }

    /// Where an operand that needs no work is read in place: a slot, a
    /// constant, an initialized upvalue or a bound Var; null for every
    /// other operand, which `resolveOther` reads, its trap included.
    inline fn peek(self: *VM, frame: *const Frame, op: Operand) ?*const Value {
        if (op.kind == .slot and op.index < frame.routine.slot_count) return self.slotAt(frame, op.index);
        if (op.kind == .constant and op.index < frame.routine.consts.len) return &frame.routine.consts[op.index];
        if (op.kind == .upvalue and op.index < frame.upvalues.len) {
            const cell = frame.upvalues[op.index];
            if (cell.initialized) return &cell.value;
        }
        if (op.kind == .var_ and op.index < frame.routine.var_table.len) {
            const v = frame.routine.var_table[op.index];
            if (v.thread_bound) return &v.thread_value;
            if (v.bound) return &v.root;
        }
        return null;
    }

    /// A value read a word at a time. A handler stores a value as two
    /// 8-byte words, and a load that takes a whole word, or both, gets
    /// it from the store while it is in flight; a load of part of a
    /// word (the kind byte) or of both words at once waits until the
    /// store reaches the cache, which a loop carrying a value through
    /// its slots pays at every instruction. Volatile, or the optimizer
    /// narrows the tag's load to its byte and joins a copy's words
    /// into one 16-byte load (em `src/runtime.zig` storeNum and
    /// loadWords make the same point).
    inline fn loadWords(src: *const Value) Value {
        return .{ .tag = @as(*const volatile u64, &src.tag).*, .payload = @as(*const volatile u64, &src.payload).* };
    }

    /// `dst.* = v` a word at a time (`loadWords`).
    inline fn storeWords(dst: *Value, v: Value) void {
        @as(*volatile u64, &dst.tag).* = v.tag;
        @as(*volatile u64, &dst.payload).* = v.payload;
    }

    /// `dst.* = src.*` a word at a time (`loadWords`).
    inline fn copyWords(dst: *Value, src: *const Value) void {
        storeWords(dst, loadWords(src));
    }

    /// Whether a value a native may read is stored whole. Compiled Zig
    /// reads a whole value, a native's argument among them, with one
    /// 16-byte load, which on x86-64 takes its data from one 16-byte
    /// store in flight and waits for two 8-byte stores to reach the
    /// cache; a handler's 8-byte loads take theirs from either, a cycle
    /// later from the 16-byte one, so a value whose reader is a handler
    /// on the dispatch's chain (a callee, a return) is stored a word at
    /// a time (§8).
    const wide_stores = builtin.target.cpu.arch == .x86_64;

    /// `storeWords`, as one 16-byte store on x86-64 (`wide_stores`).
    inline fn storeWide(dst: *Value, v: Value) void {
        if (!wide_stores) return storeWords(dst, v);
        const pair: @Vector(2, u64) = .{ v.tag, v.payload };
        @as(*align(8) volatile @Vector(2, u64), @ptrCast(dst)).* = pair;
    }

    /// `copyWords`, stored as one 16-byte store on x86-64.
    inline fn copyWide(dst: *Value, src: *const Value) void {
        storeWide(dst, loadWords(src));
    }

    /// A value a native returned through memory, where it lies: on
    /// x86-64 read a word at a time, the width the native stored it.
    inline fn returned(src: *const Value) Value {
        return if (wide_stores) loadWords(src) else src.*;
    }

    /// `dst.* = src.*` of a value a native returned, for a native to
    /// read (`returned`, `storeWide`).
    inline fn storeResult(dst: *Value, src: *const Value) void {
        if (wide_stores) copyWide(dst, src) else dst.* = src.*;
    }

    /// `@memcpy(dst, src)` for a native to read: on x86-64 a value at a
    /// time (`copyWide`).
    fn copyRun(dst: []Value, src: []const Value) void {
        if (!wide_stores) return copySlots(dst, src);
        for (dst, src) |*d, *s| copyWide(d, s);
    }

    /// A call of its own, which the optimizer cannot fold an inline
    /// copy beside it into.
    noinline fn copySlots(dst: []Value, src: []const Value) void {
        @memcpy(dst, src);
    }

    /// `copyRun` of key, value pairs, each stored as one 32-byte vector
    /// on x86-64, the width a map's constructor reads it (two 16-byte
    /// stores on a target without AVX, the release's `x86_64_v2`).
    fn copyEntries(dst: []Value, src: []const Value) void {
        if (!wide_stores) return copyRun(dst, src);
        var i: usize = 0;
        while (i + 2 <= dst.len) : (i += 2) {
            const k = loadWords(&src[i]);
            const v = loadWords(&src[i + 1]);
            const entry: @Vector(4, u64) = .{ k.tag, k.payload, v.tag, v.payload };
            @as(*align(8) volatile @Vector(4, u64), @ptrCast(&dst[i])).* = entry;
        }
        if (i < dst.len) copyWide(&dst[i], &src[i]);
    }

    /// A fact verification proved (§5), asserted by debug and safe
    /// builds and not assumed by a release build: assumed, a bound
    /// through the frame's routine changes the fast handlers' code, and
    /// the counting loop ran half as many cycles again (docs/PERF.md
    /// §3.21).
    inline fn proved(ok: bool) void {
        if (comptime builtin.optimize.runtimeSafety()) std.debug.assert(ok);
    }

    /// Slot `op` of `frame`, an operand verification proved a slot
    /// inside the frame (§5).
    inline fn verifiedSlot(self: *VM, frame: *const Frame, op: Operand) *Value {
        proved(op.kind == .slot and op.index < frame.routine.slot_count);
        return self.slotAt(frame, op.index);
    }

    /// `peek` for a fast handler, of an operand verification proved
    /// inside its table, whose every other operand goes to the general
    /// handler. A flag, not a null pointer, says which: the pointers
    /// are never tested for null.
    inline fn fastOperand(self: *VM, frame: *const Frame, op: Operand) struct { ptr: *const Value, ok: bool } {
        if (op.kind == .slot) return .{ .ptr = self.verifiedSlot(frame, op), .ok = true };
        if (op.kind == .constant) return .{ .ptr = &frame.routine.consts[op.index], .ok = true };
        if (op.kind == .upvalue) {
            const cell = frame.upvalues[op.index];
            if (cell.initialized) return .{ .ptr = &cell.value, .ok = true };
        }
        if (op.kind == .var_) {
            const v = frame.routine.var_table[op.index];
            if (v.thread_bound) return .{ .ptr = &v.thread_value, .ok = true };
            if (v.bound) return .{ .ptr = &v.root, .ok = true };
        }
        return .{ .ptr = undefined, .ok = false };
    }

    /// `resolveIn` of the operands its inline cases leave, into `out`.
    noinline fn resolveOther(self: *VM, frame: *const Frame, op: Operand, out: *Value) VmError!void {
        out.* = switch (op.kind) {
            .slot => (try self.slotPtrIn(frame, op.index)).*,
            .constant => blk: {
                const consts = frame.routine.consts;
                if (op.index >= consts.len) return VmError.OperandOutOfRange;
                break :blk consts[op.index];
            },
            .upvalue => blk: {
                if (op.index >= frame.upvalues.len) return VmError.UpvalueOutOfRange;
                const cell = frame.upvalues[op.index];
                if (!cell.initialized) return VmError.UninitializedCell;
                break :blk cell.value;
            },
            // V operand kind resolves through the
            // current routine's var_table to the Var's root
            // value. Unbound Vars (`!bound`) trap
            // `:unbound-var` — this is what makes forward
            // references work: compile time creates the Var,
            // runtime traps only if the Var is read before
            // any `def` has bound it.
            .var_ => blk: {
                const var_table = frame.routine.var_table;
                if (op.index >= var_table.len) return VmError.OperandOutOfRange;
                break :blk var_table[op.index].current() orelse return VmError.UnboundVar;
            },
            // Kinds no opcode reads through `resolve`.
            .intern, .durable => return VmError.UnimplementedOpcode,
            // `unused` is a sentinel emitted by the assembler for
            // operand slots the opcode doesn't consume; calling
            // `resolve` on one is an opcode-handler bug.
            .unused => return VmError.InvalidOperandKind,
            // Unrecognized kind bit pattern — bytecode corruption.
            _ => return VmError.BytecodeCorruption,
        };
    }

    /// Store `v` through the destination `op` of `frame`: a slot, as
    /// VM.md §4 allows; a slot in range inline, every other case out
    /// of line.
    inline fn storeIn(self: *VM, frame: *const Frame, op: Operand, v: Value) VmError!void {
        if (op.kind == .slot and op.index < frame.routine.slot_count) {
            self.slotAt(frame, op.index).* = v;
            return;
        }
        return storeOther(self, frame, op, v);
    }

    /// `storeIn` of the operands its inline case leaves.
    noinline fn storeOther(self: *VM, frame: *const Frame, op: Operand, v: Value) VmError!void {
        switch (op.kind) {
            .slot => (try self.slotPtrIn(frame, op.index)).* = v,
            .upvalue => return VmError.UnimplementedOpcode,
            .constant, .var_, .intern, .durable, .unused => return VmError.InvalidOperandKind,
            _ => return VmError.BytecodeCorruption,
        }
    }

    const idle_code = [_]Inst{asm_.returnNil()};
    /// What the top frame points at between runs: a routine that
    /// returns nil and owns nothing, so the stack-local routine a
    /// runner passed to `retargetTop` is never referenced after its
    /// run, and a collection between runs marks nothing dead.
    pub const idle_routine: Routine = .{ .code = &idle_code, .consts = &.{}, .slot_count = 1, .name = "<idle>" };

    /// Point the top-level frame at `routine` and clear the halt
    /// flag so the next `run` executes it from its first
    /// instruction. The frame keeps its base slot; the backing
    /// stack is grown when the routine needs more slots than the
    /// previous one. This is how the REPL, the file runner, the
    /// loader and the tests run a sequence of compiled top-level
    /// forms on one VM whose namespaces, interner and runtime
    /// values persist between them.
    pub fn retargetTop(self: *VM, routine: *const Routine) VmError!void {
        // A failed run leaves its frames for the trace; a host that
        // did not discard them has them discarded here.
        if (self.frames.items.len > 1) self.resetAfterError();
        const top = &self.frames.items[0];
        top.routine = routine;
        top.pc = 0;
        self.halted = false;
        // Only the top frame stands, so every slot is dead: the form
        // starts on nils and keeps nothing an earlier one left alive.
        @memset(self.stack.items, value_mod.nilValue());
        if (self.stack.items.len < routine.slot_count) {
            self.stack.appendNTimes(self.allocator, value_mod.nilValue(), routine.slot_count - self.stack.items.len) catch return VmError.OutOfMemory;
        }
    }

    /// Run bytecode to completion (halt). Returns the VM's `result`
    /// slot. If bytecode exhausts without a `return`, returns
    /// `BytecodeExhausted`. Any error that leaves the run records
    /// the frame chain in `error_trace` first.
    pub fn run(self: *VM) VmError!Value {
        self.error_detail = "";
        try self.verifyTop(self.frames.items[0].routine);
        const saved = self.installLazyHost();
        defer lazy_mod.host = saved;
        self.loop(0) catch |err| {
            self.recordErrorTrace(err);
            return err;
        };
        self.frames.items[0].routine = &idle_routine;
        return self.result;
    }

    /// Verify a routine that runs as a top-level frame, which has no
    /// upvalues, and every routine under it (`Routine.verify`), before
    /// any of it runs: a failure is reported as a run's error is, its
    /// trace one frame naming the instruction.
    fn verifyTop(self: *VM, routine: *const Routine) VmError!void {
        if (routine.upvalue_count != 0) return VmError.CaptureCountMismatch;
        var failure: VerifyFailure = undefined;
        routine.verify(&failure) catch |err| {
            self.error_trace.clearRetainingCapacity();
            self.traced_error = err;
            const r = failure.routine;
            self.error_trace.append(self.allocator, .{ .name = r.name, .pc = failure.pc, .span = r.spanAt(failure.pc), .source = r.source }) catch {};
            return err;
        };
    }

    /// Where `err` left the run: every frame, innermost first, with
    /// the instruction it was executing. Every frame's `pc` is
    /// already past that instruction (the loop increments before it
    /// dispatches), so the failing index is `pc - 1`. Frames are
    /// intact here: an uncaught throw and an untranslated `VmError`
    /// both leave the chain as it was. A parked top frame (one
    /// resting on `idle_routine`) is not part of any run and is
    /// left out. A chain longer than `trace_capacity` keeps both
    /// ends and one marker frame counting the frames between them.
    fn recordErrorTrace(self: *VM, err: VmError) void {
        self.error_trace.clearRetainingCapacity();
        self.traced_error = err;
        if (err == VmError.UncaughtThrow) if (self.escapedOrigin()) |o| {
            // The throw began below the frames still standing: report
            // the error, detail and chain it was raised with.
            if (o.err) |raised| self.traced_error = raised;
            @memcpy(self.detail_buf[0..o.detail_len], o.detail_buf[0..o.detail_len]);
            self.error_detail = self.detail_buf[0..o.detail_len];
            self.error_trace.appendSlice(self.allocator, o.trace[0..o.trace_len]) catch return;
            return;
        };
        var buf: [trace_capacity]TraceFrame = undefined;
        const n = self.captureTrace(&buf);
        self.error_trace.appendSlice(self.allocator, buf[0..n]) catch return;
    }

    /// The frame chain as `recordErrorTrace` reports it, into `out`;
    /// returns how many entries it wrote.
    fn captureTrace(self: *VM, out: []TraceFrame) usize {
        const frames = self.frames.items;
        const lowest = self.lowestLiveFrame();
        const depth = frames.len - lowest;
        const elided = if (depth > trace_capacity) depth - (trace_innermost + trace_outermost) else 0;
        var n: usize = 0;
        var i = frames.len;
        while (i > lowest and n < out.len) {
            i -= 1;
            if (elided > 0 and i == frames.len - 1 - trace_innermost) {
                out[n] = .{ .name = "<more frames elided>", .pc = 0, .span = null, .source = null, .elided = elided };
                n += 1;
                i -= elided - 1;
                continue;
            }
            out[n] = traceFrameOf(frames[i]);
            n += 1;
        }
        return n;
    }

    /// The origin of a throw of `value`. A throw of the value a live
    /// catch is handling is that throw again and keeps its origin.
    /// Otherwise the throw begins here, recorded when a handler is in
    /// force to take it (with none, it leaves `run` with its frames
    /// standing and `recordErrorTrace` sees them). `err` is the runtime
    /// error the value was translated from, if any; its detail is
    /// `error_detail`.
    /// The origin is for the report only: with no memory to record it
    /// the throw goes on without one.
    fn originFor(self: *VM, value: Value, err: ?VmError) ?u32 {
        if (err == null) if (self.rethrownOrigin(value)) |o| return o;
        if (self.findThrowTarget() == null) return null;
        self.dropUnreferencedOrigins();
        const o = self.origins.addOne(self.allocator) catch return null;
        o.* = .{ .value = value, .err = err };
        const detail = self.error_detail[0..@min(self.error_detail.len, o.detail_buf.len)];
        @memcpy(o.detail_buf[0..detail.len], detail);
        o.detail_len = detail.len;
        o.trace_len = self.captureTrace(&o.trace);
        return @intCast(self.origins.items.len - 1);
    }

    /// The origin of the innermost live catch holding `value`.
    fn rethrownOrigin(self: *VM, value: Value) ?u32 {
        var i = self.handlers.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.handlers.items[i];
            if (h.kind != .cleanup) continue;
            const o = h.origin orelse continue;
            if (o < self.origins.items.len and self.origins.items[o].value.identicalTo(value)) return o;
        }
        return null;
    }

    /// Truncate `origins` past the last entry a handler or finally
    /// continuation still names.
    fn dropUnreferencedOrigins(self: *VM) void {
        var keep: usize = 0;
        for (self.handlers.items) |h| if (h.origin) |o| {
            keep = @max(keep, o + 1);
        };
        for (self.finally_stack.items) |c| if (c.origin) |o| {
            keep = @max(keep, o + 1);
        };
        if (keep < self.origins.items.len) self.origins.shrinkRetainingCapacity(keep);
    }

    /// The origin of the throw that left the run, if it still names
    /// the value that left.
    fn escapedOrigin(self: *VM) ?*const ThrowOrigin {
        const i = self.escaped_origin orelse return null;
        self.escaped_origin = null;
        if (i >= self.origins.items.len) return null;
        const o = &self.origins.items[i];
        const thrown = self.unhandled_throw orelse return null;
        if (!o.value.identicalTo(thrown)) return null;
        return o;
    }

    /// Discard what a failed run left behind (the frames above the
    /// top-level one, handlers, pending finallys, the dynamic
    /// bindings a `binding` form had in force, the unhandled throw and
    /// `traced_error`) so the next `retargetTop` starts from a clean
    /// VM and a later failure outside a run never reports this one.
    /// The error trace stays until the next failing run replaces it.
    pub fn resetAfterError(self: *VM) void {
        while (self.frames.items.len > 1) _ = self.popFrame();
        self.handlers.clearRetainingCapacity();
        self.finally_stack.clearRetainingCapacity();
        self.origins.clearRetainingCapacity();
        self.escaped_origin = null;
        while (self.dyn_frames.items.len > 0) self.popBindings();
        self.unhandled_throw = null;
        self.traced_error = null;
        self.parked_realize = null;
        self.frames.items[0].routine = &idle_routine;
        @memset(self.stack.items, value_mod.nilValue());
        // A runaway recursion grew the frame chain and the stack far
        // past what a form needs; nothing holds into them between
        // runs, so the memory goes back.
        if (self.frames.capacity > reset_frames_kept) self.frames.shrinkAndFree(self.allocator, self.frames.items.len);
        if (self.stack.capacity > reset_frames_kept * 4) self.stack.shrinkAndFree(self.allocator, self.stack.items.len);
    }

    /// The frames, and four times as many stack slots, whose
    /// capacity `resetAfterError` keeps.
    const reset_frames_kept = 4096;

    /// Runtime error translation to a user-throwable Value.
    /// Recoverable errors (VM.md §13's catchable table) become
    /// error maps (`errorValue`) routed through `unwindThrow`;
    /// non-recoverable errors (bytecode corruption, OOM, etc.)
    /// bubble back out unchanged.
    ///
    /// Note: throw machinery via unwindThrow may itself raise
    /// UncaughtThrow (if no handler catches the translated
    /// payload). That propagates back to the dispatch caller
    /// just like a user-level `(throw)`.
    fn handleRuntimeError(self: *VM, err: VmError) VmError!void {
        const kw_name = vmErrorToKeywordName(err) orelse return err;
        // Translate to a throwable Value only when a handler is
        // in force to take it; otherwise the raw VmError
        // propagates, so a program that does not opt into
        // try/catch sees the original error taxonomy.
        if (self.findThrowTarget() == null) return err;
        const tag = self.ensureInterner().internKeywordValue(kw_name) catch return err;
        const payload = self.errorValue(tag, self.error_detail, self.raiseSite());
        const origin = self.originFor(payload, err);
        self.error_detail = "";
        try self.unwindThrow(payload, origin);
    }

    /// The value a handler takes for the runtime error `tag` (VM.md
    /// §13): the map `{:error tag :message m :fn name :file path
    /// :line l :column c}`. `m` is `detail`, or the tag's name in
    /// words when the raise site gave none (`:index-out-of-bounds`
    /// says "index out of bounds"); the place is `at`, the frame that
    /// raised it, each key present only when known. Nothing here
    /// can fail: when memory is exhausted the value is `tag` itself,
    /// the bare keyword, which `catch` takes as it takes the map.
    pub fn errorValue(self: *VM, tag: Value, detail: []const u8, at: ?TraceFrame) Value {
        return self.buildErrorMap(tag, detail, at) catch tag;
    }

    fn buildErrorMap(self: *VM, tag: Value, detail: []const u8, at: ?TraceFrame) !Value {
        var m = try self.putKey(try champ_mod.mapEmpty(self.ensureHeap()), .@"error", tag);
        var words: [96]u8 = undefined;
        const message = if (detail.len > 0) detail else blk: {
            const name = self.ensureInterner().keywordName(tag.asKeywordId());
            for ([_][2][]const u8{
                .{ "atom-re-entry", "atom re-entry" },
                .{ "transient-used-after-persistent", "transient used after persistent!" },
            }) |pair| if (std.mem.eql(u8, name, pair[0])) break :blk pair[1];
            // `:db/key-too-large` says "db key too large".
            const n = @min(name.len, words.len);
            for (name[0..n], words[0..n]) |c, *w| w.* = if (c == '-' or c == '/') ' ' else c;
            break :blk words[0..n];
        };
        m = try self.putKey(m, .message, try string_mod.fromBytes(self.ensureHeap(), message));
        return self.addPlace(m, at);
    }

    /// `m` with the place of `at`: `:fn`, `:file`, `:line` and
    /// `:column`, each when known.
    fn addPlace(self: *VM, map: Value, at: ?TraceFrame) !Value {
        const frame = at orelse return map;
        const heap = self.ensureHeap();
        var m = try self.putKey(map, .@"fn", try string_mod.fromBytes(heap, frame.name));
        const source = frame.source orelse return m;
        m = try self.putKey(m, .file, try string_mod.fromBytes(heap, source.path));
        const span = frame.span orelse return m;
        const place = self.placeOf(source, span.pos);
        m = try self.putKey(m, .line, value_mod.fromFixnum(place.line).?);
        return self.putKey(m, .column, value_mod.fromFixnum(place.col).?);
    }

    /// The keys of an error map (§13).
    pub const ErrorKey = enum { @"error", message, @"fn", file, line, column };

    /// The keyword `key` names, interned once: a handler taking errors
    /// in a loop builds a map at each.
    fn errorKey(self: *VM, key: ErrorKey) !Value {
        const slot = &self.error_keys[@backingInt(key)];
        if (slot.* == null) slot.* = try self.ensureInterner().internKeywordValue(@tagName(key));
        return slot.*.?;
    }

    /// `m` with the error-map key `key` mapped to `v`: what a native
    /// building an error map of its own (`throwErrorMap`) adds with.
    pub fn putKey(self: *VM, m: Value, key: ErrorKey, v: Value) !Value {
        return champ_mod.mapAssoc(self.ensureHeap(), m, try self.errorKey(key), v, &dispatch_mod.hashValue, &dispatch_mod.equal);
    }

    /// `throwValue` of an error map a native built (`{:error tag
    /// ...}`), placed as `errorValue` places a runtime error when a
    /// handler is in force to take it; as it is when none is, or when
    /// memory is exhausted.
    pub fn throwErrorMap(self: *VM, map: Value) VmError {
        if (self.findThrowTarget() == null) return self.throwValue(map);
        return self.throwValue(self.addPlace(map, self.raiseSite()) catch map);
    }

    /// Where an error value says a runtime error was raised: the
    /// innermost frame running the program's own code (any routine
    /// whose source is not the library's, one with no source, as
    /// `eval` compiles, included), so an error
    /// inside a library function (`update`, `map`'s step) is placed
    /// at the program's call of it; the innermost frame when no frame
    /// is the program's. Null outside any run.
    pub fn raiseSite(self: *VM) ?TraceFrame {
        const frames = self.frames.items;
        const lowest = self.lowestLiveFrame();
        if (frames.len == lowest) return null;
        var i = frames.len;
        const at = while (i > lowest) {
            i -= 1;
            const source = frames[i].routine.source orelse break i;
            if (!source.library) break i;
        } else frames.len - 1;
        return traceFrameOf(frames[at]);
    }

    /// The index of the outermost frame a run stands on: past a top
    /// frame parked on `idle_routine`, which is part of none.
    fn lowestLiveFrame(self: *const VM) usize {
        return @intFromBool(self.frames.items[0].routine == &idle_routine);
    }

    /// `f` in a trace: the instruction it was executing, the one before
    /// its `pc` (§8), and that instruction's span.
    fn traceFrameOf(f: Frame) TraceFrame {
        const pc: u32 = f.pc -| 1;
        return .{ .name = f.routine.name, .pc = pc, .span = f.routine.spanAt(pc), .source = f.routine.source };
    }

    /// `source.lineCol(pos)`, found from the last place found in the
    /// same text (`SourceInfo.lineColFrom`): a handler taking errors in
    /// a loop is at one place, and the expansions of a file placing
    /// their `&form`s walk it in order.
    pub fn placeOf(self: *VM, source: *const SourceInfo, pos: u32) SourceInfo.LineCol {
        const c = &self.place_cache;
        if (c.text.ptr != source.text.ptr or c.text.len != source.text.len) {
            c.* = .{ .text = source.text, .pos = pos, .place = source.lineCol(pos) };
        } else if (c.pos != pos) {
            c.place = source.lineColFrom(c.pos, c.place, pos);
            c.pos = pos;
        }
        return c.place;
    }

    // -------------------------------------------------------------------------
    // Dispatch (VM.md §8): threaded code through two tables, each
    // handler fetching its successor and tail-calling it, and returning
    // only to leave the chain, its error as a `Status`.
    // -------------------------------------------------------------------------

    const OpHandler = *const fn (*VM, *Frame, Inst, usize) callconv(handler_cc) Status;

    /// Every handler's calling convention (§8). On x86-64,
    /// `preserve_none`, under which no general register but the stack
    /// and frame pointers is the callee's to save: a handler keeps
    /// what it needs past System V's nine scratch registers without
    /// saving the caller's first, and a part out of line keeps its own
    /// across a native's call in the registers the native saves. On
    /// arm64 every handler fits AAPCS64's scratch registers.
    const handler_cc: std.lang.CallingConvention = if (builtin.target.cpu.arch == .x86_64) .{ .x86_64_preserve_none = .{} } else .auto;

    /// What a handler returns: `ok` when the chain ends with no error,
    /// else the error it ends with, by its number. Its own type rather
    /// than `VmError!void`, which a calling convention but `.auto` does
    /// not allow; it comes back in the register an error union's error
    /// would.
    const Status = enum(@Int(.unsigned, @bitSizeOf(anyerror))) {
        ok = 0,
        _,

        /// The chain ends with `e`.
        inline fn of(e: VmError) Status {
            return @fromBackingInt(@intFromError(e));
        }

        /// The error a chain that did not end `ok` ended with.
        fn err(status: Status) VmError {
            std.debug.assert(status != .ok);
            return @errorCast(@errorFromInt(@backingInt(status)));
        }
    };

    /// An instruction's index into the tables: its group and variant
    /// bits, `group | variant << 6`.
    pub inline fn opIndex(inst: Inst) u12 {
        return @truncate(@as(u64, @bitCast(inst)) >> 4);
    }

    fn opcode(g: Group, variant: anytype) u12 {
        return @as(u12, @backingInt(g)) | @as(u12, @backingInt(variant)) << 6;
    }

    /// The general handler of every opcode: its group's, which
    /// switches on the variant, or one of its own for the hot
    /// variants. A group outside the enum, or a variant outside its
    /// group's enum that is not quickened, is corrupt, which is what
    /// verification refuses (§5, §10); the groups with no executed
    /// variant trap.
    const op_table: [4096]OpHandler = blk: {
        @setEvalBranchQuota(20_000);
        var t: [4096]OpHandler = @splat(&opCorrupt);
        // A group's handler takes its variants without one of their
        // own: every variant of `jump`, `cmp`, `mov` and `call` but
        // the reserved `tailcall` has one.
        const groups = .{
            .{ Group.math, Math, &opMath },
            .{ Group.closure, Closure_, &opClosure },
            .{ Group.var_, VarOp, &opVar },
            .{ Group.coll, CollOp, &opColl },
            .{ Group.ctrl, CtrlOp, &opCtrl },
        };
        for (groups) |g| {
            for (std.meta.tags(g[1])) |v| t[opcode(g[0], v)] = g[2];
        }
        for ([_]Group{ .transient, .hash, .tx, .io, .simd }) |g| {
            for (0..64) |v| t[@as(u12, @backingInt(g)) | @as(u12, v) << 6] = &opUnimplemented;
        }
        t[opcode(.mov, Mov.move)] = &opMove;
        // Verification leaves these no case but their fast handler's.
        t[opcode(.mov, Mov.move_clear)] = &fastMoveClear;
        t[opcode(.mov, Mov.load_const)] = &fastLoadConst;
        t[opcode(.mov, Mov.load_nil)] = fastLoad(value_mod.nilValue());
        t[opcode(.mov, Mov.load_true)] = fastLoad(value_mod.fromBool(true));
        t[opcode(.mov, Mov.load_false)] = fastLoad(value_mod.fromBool(false));
        t[opcode(.jump, Jump.jmp)] = &fastJmp;
        t[opcode(.jump, Jump.if_false)] = branchHandler(false);
        t[opcode(.jump, Jump.if_true)] = branchHandler(true);
        for (std.meta.tags(NumCmp)) |c| t[opcode(.cmp, c)] = cmpHandler(c);
        t[opcode(.var_, VarOp.load_var)] = &opLoadVar;
        t[opcode(.closure, Closure_.get_cell)] = &opGetCell;
        t[opcode(.call, Call.call)] = &opCall;
        t[opcode(.call, Call.self_)] = &opCallSelf;
        t[opcode(.call, Call.lookup)] = &opLookup;
        t[opcode(.call, Call.lookup_or)] = &opLookup;
        t[opcode(.call, Call.@"return")] = &opReturn;
        t[opcode(.call, Call.return_nil)] = &opReturn;
        t[opcode(.call, Call.tailcall)] = &opUnimplemented;
        for (0..4096) |op| {
            if (Quick.of(op) != null) t[op] = &opQuickened;
        }
        break :blk t;
    };

    /// The table the fetch dispatches through: `op_table` with the
    /// fast handlers over it.
    const fast_table: [4096]OpHandler = blk: {
        @setEvalBranchQuota(20_000);
        var t = op_table;
        t[opcode(.mov, Mov.move)] = &fastMove;
        t[opcode(.jump, Jump.if_false)] = fastBranch(false);
        t[opcode(.jump, Jump.if_true)] = fastBranch(true);
        for (std.meta.tags(NumCmp)) |c| t[opcode(.cmp, c)] = fastCmp(c);
        for ([_]Math{ .add, .sub, .mul, .idiv, .mod }) |m| t[opcode(.math, m)] = fastMath(m);
        t[opcode(.var_, VarOp.load_var)] = &fastLoadVar;
        t[opcode(.closure, Closure_.get_cell)] = &fastGetCell;
        t[opcode(.call, Call.call)] = &fastCall;
        t[opcode(.call, Call.self_)] = &fastCallSelf;
        t[opcode(.call, Call.lookup)] = &fastLookup;
        t[opcode(.call, Call.lookup_or)] = &fastLookup;
        t[opcode(.call, Call.@"return")] = &fastReturn;
        t[opcode(.call, Call.return_nil)] = &fastReturnNil;
        for (0..4096) |op| {
            const q = Quick.of(op) orelse continue;
            t[op] = switch (@as(Group, @fromBackingInt(@as(u6, @truncate(op))))) {
                .math => if (q.step) |s| switch (s.form) {
                    inline .slot_slot, .slot_fixnum => |form| switch (q.then) {
                        inline .if_true, .if_false => |then| switch (s.cmp) {
                            inline .lt, .lte, .gt, .gte => |c| fastStep(c, form, then),
                            .eq => unreachable,
                        },
                        .none => unreachable,
                    },
                    else => unreachable,
                } else switch (q.form) {
                    inline .slot_slot, .slot_fixnum, .fixnum_slot => |form| switch (@as(Math, @fromBackingInt(q.base))) {
                        inline .add, .sub, .mul, .idiv, .mod => |m| fastMathQuick(m, form),
                        else => unreachable,
                    },
                    .slot, .upvalue => unreachable,
                },
                .cmp => switch (q.form) {
                    inline .slot_slot, .slot_fixnum => |form| switch (q.then) {
                        inline else => |then| switch (@as(NumCmp, @fromBackingInt(q.base))) {
                            inline else => |c| fastCmpQuick(c, form, then),
                        },
                    },
                    else => unreachable,
                },
                .mov => if (q.form == .upvalue) &fastMoveUpvalue else &fastMoveSlot,
                .call => &fastReturnSlot,
                else => unreachable,
            };
        }
        break :blk t;
    };

    /// Fetch the instruction at `frame.pc` and tail-call its handler:
    /// the fetch of a handler that worked on `frame.pc` (§8).
    inline fn next(self: *VM, frame: *Frame) Status {
        return self.nextAt(frame, frame.pc);
    }

    /// Fetch the instruction at `pc` and tail-call its handler with
    /// the pc after it. The frame's `pc` is written only on the way out
    /// with an error, so the trace names the instruction as §13 says.
    inline fn nextAt(self: *VM, frame: *Frame, pc: usize) Status {
        const inst = frame.routine.code[pc];
        std.debug.assert(inst.kind == .primary);
        if (counting) opcode_counts[opIndex(inst)] += 1;
        return @call(.always_tail, fast_table[opIndex(inst)], .{ self, frame, inst, pc + 1 });
    }

    /// `next` after an instruction that could allocate: the safe
    /// point (§9).
    inline fn nextSafe(self: *VM, frame: *Frame) Status {
        return self.nextSafeAt(frame, frame.pc);
    }

    inline fn nextSafeAt(self: *VM, frame: *Frame, pc: usize) Status {
        if (self.gcDue()) self.collectGarbage();
        return self.nextAt(frame, pc);
    }

    /// `next` after an instruction that could pop or unwind frames or
    /// halt: the chain ends when the loop's frame has returned.
    inline fn nextFrame(self: *VM) Status {
        if (!self.running()) return .ok;
        if (self.gcDue()) self.collectGarbage();
        return self.next(self.currentFrame());
    }

    /// The fast handlers' section and alignment: together, apart from
    /// the rest of the code, each on a cache line of its own, so code
    /// growing elsewhere does not move them against each other.
    const hot_section = if (builtin.target.os.tag.isDarwin()) "__TEXT,__text_hot,regular,pure_instructions" else ".text.hot";
    const hot_align = 64;

    /// How a fast handler hands its instruction to a part of its own
    /// kept out of line, one that calls out and so needs a stack frame
    /// (em `src/runtime.zig` `outOfLine`): a call in return position
    /// never inlined, which a release build makes a tail call; inlined,
    /// the part's frame would be the fast handler's. A debug build
    /// makes a tail call only when told to.
    const out_of_line: std.lang.CallModifier = if (builtin.optimize == .debug) .always_tail else .never_inline;

    /// A fast handler's way out: `inst`'s general handler, which takes
    /// the case from the start.
    inline fn general(self: *VM, frame: *Frame, inst: Inst, pc: usize) Status {
        return @call(.always_tail, op_table[opIndex(inst)], .{ self, frame, inst, pc });
    }

    /// Where `loop` enters the chain: a safe point, then the current
    /// frame's next instruction.
    fn opEnter(self: *VM, frame: *Frame, _: Inst, _: usize) callconv(handler_cc) Status {
        return self.nextSafe(frame);
    }

    /// A quickened instruction past its fast handler's case: its base
    /// opcode's general handler, which reads the same operands (§10.10).
    fn opQuickened(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        var base = inst;
        base.variant = @truncate(Routine.baseOp(opIndex(inst)) >> 6);
        return @call(.always_tail, op_table[opIndex(base)], .{ self, frame, base, pc });
    }

    fn opCorrupt(_: *VM, frame: *Frame, _: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        return .of(VmError.BytecodeCorruption);
    }

    fn opUnimplemented(_: *VM, frame: *Frame, _: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        return .of(VmError.UnimplementedOpcode);
    }

    // The group handlers. `mov`, `cmp`, `jump` and `var` neither
    // allocate nor push or pop a frame, so they run against the
    // frame the fetch took and skip the safe point; `math`, `closure`
    // and `coll` allocate on the heap only; `call` and `ctrl` may
    // change the frame chain.

    fn opVar(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execVar(frame, inst) catch |e| return .of(e);
        return self.next(frame);
    }

    fn opMath(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execMath(frame, inst) catch |e| return .of(e);
        return self.nextSafe(frame);
    }

    fn opClosure(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execClosure(frame, inst) catch |e| return .of(e);
        return self.nextSafe(frame);
    }

    fn opColl(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execColl(inst) catch |e| return .of(e);
        // Hashing a lazy key realizes it, which may grow the frames.
        return self.nextSafe(self.currentFrame());
    }

    fn opCtrl(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execCtrl(inst) catch |e| return .of(e);
        return self.nextFrame();
    }

    // The general handlers of the hot variants: the same effect and
    // traps as their group's, without its switch.

    fn opMove(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        var tmp: Value = undefined;
        const src = self.operandPtr(frame, inst.b, &tmp) catch |e| return .of(e);
        self.storeIn(frame, inst.a, src.*) catch |e| return .of(e);
        return self.next(frame);
    }

    /// `jump:if-true` (`when`) and `jump:if-false`.
    fn branchHandler(comptime when: bool) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
                frame.pc = @intCast(pc);
                var tmp: Value = undefined;
                const v = self.operandPtr(frame, inst.a, &tmp) catch |e| return .of(e);
                if (v.isTruthy() == when) applyJump(frame, inst.wide()) catch |e| return .of(e);
                return self.next(frame);
            }
        }.run;
    }

    fn opGetCell(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execClosureGetCell(frame, inst) catch |e| return .of(e);
        return self.next(frame);
    }

    fn opLoadVar(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execVarLoadVar(frame, inst) catch |e| return .of(e);
        return self.next(frame);
    }

    /// The low half of a conditional jump testing `test_op`: what a
    /// comparison looks for after it.
    fn condJumpKey(variant: Jump, test_op: Operand) u32 {
        const lo: u32 = @truncate(@as(u64, @bitCast(Inst.primaryWide(.jump, variant, Operand.none, 0))));
        return (lo & 0xFFFF) | @as(u32, @as(u16, @bitCast(test_op))) << 16;
    }

    /// `op` of two fixnums when the result is a fixnum; null for a
    /// promotion or a zero divisor, which the numeric tower takes. The
    /// operands are i48: a sum or difference cannot leave i64, a
    /// product that does is not a fixnum, and only `(quot fixnum_min
    /// -1)` leaves i48 by division.
    inline fn fixnumResult(comptime op: Math, x: i64, y: i64) ?Value {
        const r = switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => blk: {
                const p = @mulWithOverflow(x, y);
                if (p[1] != 0) return null;
                break :blk p[0];
            },
            .idiv => if (y != 0) @divTrunc(x, y) else return null,
            .mod => if (y != 0) @mod(x, y) else return null,
            else => comptime unreachable,
        };
        return value_mod.fromFixnum(r);
    }

    /// `cmp:<c>` through the numeric tower. When the next instruction
    /// is a conditional jump on the slot just written, the compiler's
    /// lowering of an `if` on a comparison, it runs here too: the pair
    /// costs one dispatch, and pc, the slot and every trap are what
    /// running the two in turn leaves.
    fn cmpHandler(comptime c: NumCmp) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
                frame.pc = @intCast(pc);
                var lhs_tmp: Value = undefined;
                var rhs_tmp: Value = undefined;
                const lhs = self.operandPtr(frame, inst.b, &lhs_tmp) catch |e| return .of(e);
                const rhs = self.operandPtr(frame, inst.c, &rhs_tmp) catch |e| return .of(e);
                const holds_ = self.compareNumbers(c, lhs.*, rhs.*) catch |e| return .of(e);
                self.storeIn(frame, inst.a, value_mod.fromBool(holds_)) catch |e| return .of(e);
                const code = frame.routine.code;
                if (frame.pc < code.len) {
                    const j = code[frame.pc];
                    const lo: u32 = @truncate(@as(u64, @bitCast(j)));
                    const taken = if (lo == condJumpKey(.if_false, inst.a))
                        !holds_
                    else if (lo == condJumpKey(.if_true, inst.a))
                        holds_
                    else
                        return self.next(frame);
                    frame.pc += 1;
                    if (taken) applyJump(frame, j.wide()) catch |e| return .of(e);
                }
                return self.next(frame);
            }
        }.run;
    }

    /// `call:call` past the fast handler's cases, through the general
    /// entry of §6 with its traps.
    fn opCall(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        self.execCallCall(frame, inst) catch |e| return .of(e);
        // A call pushes a frame or runs a callee to completion, so the
        // loop's frame is still running.
        return self.nextSafe(self.currentFrame());
    }

    /// `call:self` past the fast handler's case, through the closure
    /// entry of §6 with its traps, which picks the member the count
    /// names.
    fn opCallSelf(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        // Only a closure's frame runs one: a top-level routine's has
        // no closure to call.
        if (frame.closure.kind() != .function) return .of(VmError.BytecodeCorruption);
        const base = @as(usize, frame.base_slot) + inst.a.index;
        self.enterClosure(frame.closure, base, inst.b.index, self.stack.items.len, .{ .return_dst = inst.c.index }) catch |e| return .of(e);
        return self.nextSafe(self.currentFrame());
    }

    /// `call:lookup` and `call:lookup-or` past the in-place cases: the
    /// key called on the target, with the default, as `call:call` calls
    /// it (§6), the same function with the same errors.
    fn opLookup(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        const key = self.resolveIn(frame, inst.c) catch |e| return .of(e);
        var args: [2]Value = undefined;
        var argc: usize = 1;
        if (inst.variant == @backingInt(Call.lookup_or)) {
            if (inst.b.kind != .slot) return .of(VmError.InvalidOperandKind);
            const at = @as(usize, inst.b.index);
            if (at + 2 > frame.routine.slot_count) return .of(VmError.OperandOutOfRange);
            args = .{ self.slotAt(frame, at).*, self.slotAt(frame, at + 1).* };
            argc = 2;
        } else args[0] = self.resolveIn(frame, inst.b) catch |e| return .of(e);
        // A target read from a Var or a cell is held only here while a
        // sorted collection's comparator runs. The scope is released
        // before the chain goes on, not by a `defer`, which would run
        // only once the tail call returned.
        const scope = self.rootScope();
        scope.push(args[0]) catch |e| return .of(e);
        const result = self.callDirect(key, args[0..argc]);
        scope.release();
        const value = result catch |e| return .of(e);
        // A comparator may have grown `frames`.
        const caller = self.currentFrame();
        self.storeIn(caller, inst.a, value) catch |e| return .of(e);
        return self.nextSafe(caller);
    }

    /// `call:return` and `call:return-nil`. The value is read before
    /// the frame pops, which frees its slots.
    fn opReturn(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        frame.pc = @intCast(pc);
        const v = if (inst.variant == @backingInt(Call.return_nil)) value_mod.nilValue() else self.resolveIn(frame, inst.a) catch |e| return .of(e);
        self.returnValue(v) catch |e| return .of(e);
        if (!self.running()) return .ok;
        return self.next(self.currentFrame());
    }

    // The fast handlers. Each reads its operands in place
    // (`fastOperand`), stores only to a slot of its frame, calls
    // nothing and allocates nothing, so it ends at no safe point, and
    // hands any other case to its general handler, or to a part of its
    // own out of line, before it has changed anything. `pc` stays in a
    // register: the frame's `pc` is written only before a frame is
    // pushed or a native called, where a return or an error trace
    // reads it.

    fn fastMove(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const dst = self.verifiedSlot(frame, inst.a);
        const v = self.fastOperand(frame, inst.b);
        if (!v.ok) return self.general(frame, inst, pc);
        copyWide(dst, v.ptr);
        return self.nextAt(frame, pc);
    }

    fn fastLoadConst(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        copyWide(self.verifiedSlot(frame, inst.a), &frame.routine.consts[inst.wide()]);
        return self.nextAt(frame, pc);
    }

    fn fastLoad(comptime v: Value) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                self.verifiedSlot(frame, inst.a).* = v;
                return self.nextAt(frame, pc);
            }
        }.run;
    }

    fn fastJmp(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        _ = pc;
        return self.nextAt(frame, inst.wide());
    }

    /// `jump:if-true` (`when`) and `jump:if-false`.
    fn fastBranch(comptime when: bool) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                const v = self.fastOperand(frame, inst.a);
                if (!v.ok) return self.general(frame, inst, pc);
                return self.nextAt(frame, if (loadWords(v.ptr).isTruthy() == when) inst.wide() else pc);
            }
        }.run;
    }

    /// Two fixnums, with the branch that follows as `cmpHandler` runs
    /// it.
    fn fastCmp(comptime c: NumCmp) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                const dst = self.verifiedSlot(frame, inst.a);
                const lhs = self.fastOperand(frame, inst.b);
                if (!lhs.ok) return self.general(frame, inst, pc);
                const rhs = self.fastOperand(frame, inst.c);
                if (!rhs.ok) return self.general(frame, inst, pc);
                const l = loadWords(lhs.ptr);
                const r = loadWords(rhs.ptr);
                if (!l.isFixnum() or !r.isFixnum()) return self.general(frame, inst, pc);
                const holds_ = ordered(i64, c, l.asFixnum(), r.asFixnum());
                // A comparison never ends the code (§5).
                const j = frame.routine.code[pc];
                const lo: u32 = @truncate(@as(u64, @bitCast(j)));
                const if_true = lo == condJumpKey(.if_true, inst.a);
                var after = pc;
                if (if_true or lo == condJumpKey(.if_false, inst.a)) after = if (holds_ == if_true) j.wide() else pc + 1;
                dst.* = value_mod.fromBool(holds_);
                return self.nextAt(frame, after);
            }
        }.run;
    }

    /// `math:<op>` of two fixnums whose result is a fixnum.
    fn fastMath(comptime op: Math) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                const dst = self.verifiedSlot(frame, inst.a);
                const lhs = self.fastOperand(frame, inst.b);
                if (!lhs.ok) return self.general(frame, inst, pc);
                const rhs = self.fastOperand(frame, inst.c);
                if (!rhs.ok) return self.general(frame, inst, pc);
                const l = loadWords(lhs.ptr);
                const r = loadWords(rhs.ptr);
                if (!l.isFixnum() or !r.isFixnum()) return self.general(frame, inst, pc);
                dst.* = fixnumResult(op, l.asFixnum(), r.asFixnum()) orelse return self.general(frame, inst, pc);
                return self.nextAt(frame, pc);
            }
        }.run;
    }

    /// An operand of a quickened `math` or `cmp` (§10.10) as a fixnum:
    /// the constant verification proved one (`constant`), else a
    /// slot's value when it holds one, null when it does not.
    inline fn quickFixnum(self: *VM, frame: *const Frame, op: Operand, comptime constant: bool) ?i64 {
        if (constant) {
            const c = &frame.routine.consts[op.index];
            proved(op.kind == .constant and c.isFixnum());
            return @bitCast(c.payload);
        }
        const v = loadWords(self.verifiedSlot(frame, op));
        return if (v.isFixnum()) v.asFixnum() else null;
    }

    /// `fastMath` of a quickened instruction, whose operands it reads
    /// with no kind to decode.
    fn fastMathQuick(comptime op: Math, comptime form: Quick.Form) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                const dst = self.verifiedSlot(frame, inst.a);
                const l = self.quickFixnum(frame, inst.b, form == .fixnum_slot) orelse return self.general(frame, inst, pc);
                const r = self.quickFixnum(frame, inst.c, form == .slot_fixnum) orelse return self.general(frame, inst, pc);
                dst.* = fixnumResult(op, l, r) orelse return self.general(frame, inst, pc);
                return self.nextAt(frame, pc);
            }
        }.run;
    }

    /// `fastCmp` of a quickened instruction: no kind to decode, and the
    /// jump after it, when its form says there is one, run without
    /// looking for it.
    fn fastCmpQuick(comptime c: NumCmp, comptime form: Quick.Form, comptime then: Quick.Then) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                const dst = self.verifiedSlot(frame, inst.a);
                const l = self.quickFixnum(frame, inst.b, false) orelse return self.general(frame, inst, pc);
                const r = self.quickFixnum(frame, inst.c, form == .slot_fixnum) orelse return self.general(frame, inst, pc);
                const holds_ = ordered(i64, c, l, r);
                const after = switch (then) {
                    .none => pc,
                    .if_true => if (holds_) frame.routine.code[pc].wide() else pc + 1,
                    .if_false => if (holds_) pc + 1 else frame.routine.code[pc].wide(),
                };
                dst.* = value_mod.fromBool(holds_);
                return self.nextAt(frame, after);
            }
        }.run;
    }

    /// A counting loop's step (§10.10): the `math:add` of a slot and a
    /// fixnum constant, then the comparison `c` after it, of the sum
    /// and the comparison's C in `form`, then its jump, `then`, as one
    /// dispatch. A sum that is not a fixnum goes to the add's general
    /// handler; a C slot not holding a fixnum leaves the sum stored and
    /// the comparison to run as its own instruction, as the two would
    /// run in turn.
    fn fastStep(comptime c: NumCmp, comptime form: Quick.Form, comptime then: Quick.Then) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
                const dst = self.verifiedSlot(frame, inst.a);
                const l = self.quickFixnum(frame, inst.b, false) orelse return self.general(frame, inst, pc);
                const k = self.quickFixnum(frame, inst.c, true) orelse return self.general(frame, inst, pc);
                const sum = l + k;
                dst.* = value_mod.fromFixnum(sum) orelse return self.general(frame, inst, pc);
                const code = frame.routine.code;
                const cmp = code[pc];
                proved(@as(u16, @bitCast(cmp.b)) == @as(u16, @bitCast(inst.a)));
                const r = self.quickFixnum(frame, cmp.c, form == .slot_fixnum) orelse return self.nextAt(frame, pc);
                const holds_ = ordered(i64, c, sum, r);
                self.verifiedSlot(frame, cmp.a).* = value_mod.fromBool(holds_);
                return self.nextAt(frame, if (holds_ == (then == .if_true)) code[pc + 1].wide() else pc + 2);
            }
        }.run;
    }

    fn fastMoveSlot(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        copyWide(self.verifiedSlot(frame, inst.a), self.verifiedSlot(frame, inst.b));
        return self.nextAt(frame, pc);
    }

    /// Both slots are found before anything is stored, or the stores
    /// would make the optimizer read the frame and the stack again.
    /// Nil is the all-zero value, so the clear is one store of a pair
    /// of zero words: nothing reads the slot before it is written
    /// again, so no load waits on it (`loadWords`).
    fn fastMoveClear(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const dst = self.verifiedSlot(frame, inst.a);
        const src = self.verifiedSlot(frame, inst.b);
        const v = loadWords(src);
        src.* = comptime value_mod.nilValue();
        storeWide(dst, v);
        return self.nextAt(frame, pc);
    }

    fn fastMoveUpvalue(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        proved(inst.b.kind == .upvalue and inst.b.index < frame.upvalues.len);
        const cell = frame.upvalues[inst.b.index];
        if (!cell.initialized) return self.general(frame, inst, pc);
        copyWide(self.verifiedSlot(frame, inst.a), &cell.value);
        return self.nextAt(frame, pc);
    }

    fn fastReturnSlot(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        return self.returnFast(frame, inst, pc, self.verifiedSlot(frame, inst.a));
    }

    fn fastLoadVar(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const v = frame.routine.var_table[inst.wide()];
        // Through a pointer: a choice between two values is copied
        // through the stack.
        const value: *const Value = if (v.thread_bound) &v.thread_value else if (v.bound) &v.root else return self.general(frame, inst, pc);
        copyWords(self.verifiedSlot(frame, inst.a), value);
        return self.nextAt(frame, pc);
    }

    fn fastGetCell(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const cell_v = loadWords(self.verifiedSlot(frame, inst.b));
        if (cell_v.kind() != .cell_internal) return self.general(frame, inst, pc);
        const cell = heap_mod.Heap.bodyOf(UpvalCell, @ptrFromInt(cell_v.payload));
        if (!cell.initialized) return self.general(frame, inst, pc);
        copyWide(self.verifiedSlot(frame, inst.a), &cell.value);
        return self.nextAt(frame, pc);
    }

    /// `call:call` of a closure with its fixed arity where the frame
    /// chain and the stack's capacity have room, whose frame is pushed
    /// without allocating, so its callee starts without a safe point.
    /// A native and a keyword or symbol go on to handlers of their own,
    /// out of line: each calls out, and a call needs a stack frame.
    fn fastCall(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const call_base: u32 = inst.a.index;
        const argc: u32 = inst.b.index;
        proved(call_base + 1 + argc <= frame.routine.slot_count);
        const callee = loadWords(self.verifiedSlot(frame, inst.a));
        // A closure, the common callee, is tested first.
        if (callee.kind() != .function) switch (callee.kind()) {
            .native_fn => return @call(out_of_line, callLeaf, .{ self, frame, inst, pc }),
            .keyword, .symbol => return @call(out_of_line, callLookup, .{ self, frame, inst, pc }),
            else => return self.general(frame, inst, pc),
        };
        const base: usize = @as(usize, frame.base_slot) + call_base + 1;
        const routine = asClosure(callee).routine.memberFor(argc) orelse return self.general(frame, inst, pc);
        const callee_frame = self.pushDirect(callee, routine, base, argc, .{
            .return_dst = inst.c.index,
        }) orelse return self.general(frame, inst, pc);
        return self.enterFirst(frame, pc, callee_frame, routine);
    }

    /// The fast call's way into the frame it pushed: the caller's `pc`
    /// set, for a trace through the callee and for its return, and the
    /// callee's first instruction fetched through the routine in hand
    /// rather than the frame just written.
    inline fn enterFirst(self: *VM, frame: *Frame, pc: usize, callee_frame: *Frame, routine: *const Routine) Status {
        frame.pc = @intCast(pc);
        const first = routine.code[0];
        if (counting) opcode_counts[opIndex(first)] += 1;
        return @call(.always_tail, fast_table[opIndex(first)], .{ self, callee_frame, first, 1 });
    }

    /// `call:self` where the frame chain and the stack's capacity have
    /// room: the callee is the frame's own closure, and verification
    /// proved the count the fixed arity of the frame's routine or of a
    /// member of its table, so the frame is pushed as `fastCall` pushes
    /// a closure's with no callee to read or test.
    fn fastCallSelf(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const callee = loadWords(&frame.closure);
        if (callee.kind() != .function) return self.general(frame, inst, pc);
        const argc: u32 = inst.b.index;
        const own = frame.routine;
        proved(own.memberFor(argc) != null and inst.a.index + argc <= own.slot_count);
        const routine = if (argc == own.fixed_arity and !own.variadic) own else own.arities.?.fixed[argc].?;
        const base: usize = @as(usize, frame.base_slot) + inst.a.index;
        const callee_frame = self.pushDirect(callee, routine, base, argc, .{
            .return_dst = inst.c.index,
        }) orelse return self.general(frame, inst, pc);
        return self.enterFirst(frame, pc, callee_frame, routine);
    }

    /// `fastCall` of a leaf native within its arity, on its arguments
    /// in place: nothing can grow the stack under a leaf. Any other
    /// native goes on to `callBuffered`.
    fn callLeaf(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        const native = asNativeFn(self.verifiedSlot(frame, inst.a).*);
        if (!native.leaf) return @call(out_of_line, callBuffered, .{ self, frame, inst, pc });
        const argc: u32 = inst.b.index;
        if (!native.takes(argc)) return self.general(frame, inst, pc);
        const base: usize = @as(usize, frame.base_slot) + inst.a.index + 1;
        frame.pc = @intCast(pc);
        const result = native.call(self, self.stack.items[base..][0..argc]) catch |err| switch (err) {
            VmError.NeedsReentry => return self.general(frame, inst, pc),
            else => return .of(err),
        };
        countNative(native);
        storeResult(self.verifiedSlot(frame, inst.c), &result);
        return self.nextSafeAt(frame, pc);
    }

    /// `callLeaf` of a native that is not a leaf, within its arity and
    /// `max_native_args` arguments, on a copy of them in a buffer on
    /// the native stack: it may re-enter the VM and grow the stack,
    /// whose slots keep them rooted.
    fn callBuffered(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        const native = asNativeFn(self.verifiedSlot(frame, inst.a).*);
        // Only a leaf has a general body (`NativeFn.general`).
        std.debug.assert(native.general == null);
        const argc: u32 = inst.b.index;
        if (!native.takes(argc) or argc > max_native_args) return self.general(frame, inst, pc);
        const base: usize = @as(usize, frame.base_slot) + inst.a.index + 1;
        frame.pc = @intCast(pc);
        // On arm64 a whole buffer copies inline where the stack's
        // capacity covers it, and the other copy is a call of its own
        // (`copySlots`); on x86-64 each value goes as one store.
        var buf: [max_native_args]Value = undefined;
        if (!wide_stores and base + max_native_args <= self.stack.capacity) {
            buf = self.stack.items.ptr[base..][0..max_native_args].*;
        } else copyRun(buf[0..argc], self.stack.items[base..][0..argc]);
        if (native.consumes and argc > 0) self.stack.items[base + argc - 1] = value_mod.nilValue();
        countNative(native);
        const overflows = dispatch_mod.spoilCount();
        const result = native.call(self, buf[0..argc]) catch |err| {
            self.dropSpoils(overflows);
            return .of(err);
        };
        self.checkDeepData(overflows) catch |e| return .of(e);
        // The native may have grown `frames`: the caller is the current
        // frame again, not necessarily at `frame`.
        const caller = self.currentFrame();
        // The arguments are dead once the call returns (§6); the callee
        // is a native, which holds no heap value.
        for (self.stack.items.ptr[base..][0..argc]) |*slot| slot.* = value_mod.nilValue();
        storeResult(self.slotAt(caller, inst.c.index), &result);
        return self.nextSafe(caller);
    }

    /// `fastCall` of a keyword or symbol, `(:k m)`, `(:k m d)`, `('s m)`,
    /// on a map, a record or nil: the lookup `callLookupIn` makes. An
    /// immediate key hashes and compares without the callbacks, so
    /// nothing is allocated and no data is walked.
    fn callLookup(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        const argc: u32 = inst.b.index;
        if (argc != 1 and argc != 2) return self.general(frame, inst, pc);
        const callee = self.slotAt(frame, inst.a.index).*;
        const base: usize = @as(usize, frame.base_slot) + inst.a.index + 1;
        const default = if (argc == 2) self.stack.items[base + 1] else value_mod.nilValue();
        const result = lookupInPlace(callee, self.stack.items[base], default) orelse return self.general(frame, inst, pc);
        storeResult(self.slotAt(frame, inst.c.index), &result);
        return self.nextAt(frame, pc);
    }

    /// `call:lookup` and `call:lookup-or` of a target read in place: on
    /// to `lookupPart`, out of line, since a map's search is a call.
    /// Verification proved the key a keyword or symbol constant and
    /// `call:lookup-or`'s target a slot.
    fn fastLookup(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        if (!self.fastOperand(frame, inst.b).ok) return self.general(frame, inst, pc);
        return @call(out_of_line, lookupPart, .{ self, frame, inst, pc });
    }

    /// `fastLookup` of a map, a record or nil: the lookup `callLookupIn`
    /// makes, with no copy and no safe point, since an immediate key
    /// hashes and compares without the callbacks.
    fn lookupPart(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        const key = frame.routine.consts[inst.c.index];
        const target = loadWords(self.fastOperand(frame, inst.b).ptr);
        const default = if (inst.variant == @backingInt(Call.lookup_or)) self.slotAt(frame, @as(usize, inst.b.index) + 1).* else value_mod.nilValue();
        const result = lookupInPlace(key, target, default) orelse return self.general(frame, inst, pc);
        storeResult(self.verifiedSlot(frame, inst.a), &result);
        return self.nextAt(frame, pc);
    }

    /// `call:return` from any frame but the top-level one: pop it, and
    /// write the caller's slot and continue in the caller, whose `pc`
    /// the call left at its return point, or fill the host's cell.
    fn fastReturn(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        const v = self.fastOperand(frame, inst.a);
        if (!v.ok) return self.general(frame, inst, pc);
        return self.returnFast(frame, inst, pc, v.ptr);
    }

    fn fastReturnNil(self: *VM, frame: *Frame, inst: Inst, pc: usize) align(hot_align) linksection(hot_section) callconv(handler_cc) Status {
        return self.returnFast(frame, inst, pc, &nil_value);
    }

    const nil_value = value_mod.nilValue();

    /// The returned value by pointer: the slot it is read from stays
    /// in place while the frame pops, and a value passed by copy goes
    /// through the stack.
    inline fn returnFast(self: *VM, frame: *Frame, inst: Inst, pc: usize, v: *const Value) Status {
        const n = self.frames.items.len;
        if (frame.host_result != null or n < 2) {
            @branchHint(.unlikely);
            // A frame `callValue`, `runRoutine` or a `Callback` pushed
            // hands its value to its cell, and the chain ends with the
            // loop's frame.
            const hr = frame.host_result orelse return self.general(frame, inst, pc);
            copyWords(&hr.value, v);
            if (hr.step) |step| return @call(.always_tail, step, .{ self, frame, inst, pc });
            hr.done = true;
            self.stack.items.len = frame.entry_stack_len;
            self.frames.items.len = n - 1;
            // The host runs the loop at the depth it pushed the frame at,
            // so the frame was the loop's.
            std.debug.assert(!self.running());
            return .ok;
        }
        const caller = &self.frames.items[n - 2];
        const dst = frame.return_dst;
        proved(dst < caller.routine.slot_count);
        const resume_pc = caller.pc;
        self.stack.items.len = frame.entry_stack_len;
        self.frames.items.len = n - 1;
        copyWords(self.slotAt(caller, dst), v);
        // A frame a call pushed sits above the loop's, which is still
        // running.
        std.debug.assert(self.running());
        return self.nextAt(caller, resume_pc);
    }

    /// `returnFast` of a batch's frame, its value in the cell, for a
    /// batch of `step`: the next element starts at its first
    /// instruction in the same frame, past the safe point a call's
    /// entry is, or the batch is over and the frame pops, ending the
    /// chain as a host's frame does.
    fn batchNext(comptime step: Callback.Batch.Step) OpHandler {
        return &struct {
            fn run(self: *VM, frame: *Frame, _: Inst, _: usize) callconv(handler_cc) Status {
                const hr = frame.host_result.?;
                if (!self.batchStep(frame, hr, step)) {
                    hr.done = true;
                    self.stack.items.len = frame.entry_stack_len;
                    self.frames.items.len -= 1;
                    std.debug.assert(!self.running());
                    return .ok;
                }
                const cb: *Callback = @fieldParentPtr("result", hr);
                if (counting) opcode_counts[opIndex(cb.first)] += 1;
                if (self.gcDue()) return @call(out_of_line, collectThen, .{ self, frame, cb.first, 1 });
                return @call(.always_tail, cb.first_handler, .{ self, frame, cb.first, 1 });
            }
        }.run;
    }

    /// A cycle, then `inst`: a batch's safe point, out of line.
    fn collectThen(self: *VM, frame: *Frame, inst: Inst, pc: usize) callconv(handler_cc) Status {
        self.collectGarbage();
        return @call(.always_tail, fast_table[opIndex(inst)], .{ self, frame, inst, pc });
    }

    // -------------------------------------------------------------------------
    // Group `call` (VM.md §10.2)
    // -------------------------------------------------------------------------

    /// `call:call A=base B=argc C=dst` (VM.md §6): a closure gets a frame
    /// over its arguments, any other callee runs to completion here.
    fn execCallCall(self: *VM, caller: *Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot or inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const call_base: u32 = inst.a.index;
        const argc: u32 = inst.b.index;
        const result_dst: u12 = inst.c.index;

        if (call_base + 1 + argc > caller.routine.slot_count) return VmError.CallBlockOutOfRange;
        if (result_dst >= caller.routine.slot_count) return VmError.OperandOutOfRange;
        var callee = (try self.slotPtrIn(caller, @intCast(call_base))).*;
        const args_base: usize = @as(usize, caller.base_slot) + call_base + 1;
        if (args_base + argc > self.stack.items.len) return VmError.BytecodeCorruption;
        // A Var calls the value in force (Clojure's `Var.invoke`); a
        // closure there gets a frame like any other, so a recursion
        // through `#'f` costs no native stack.
        if (callee.kind() == .var_) callee = asVar(callee).current() orelse return VmError.UnboundVar;

        if (callee.kind() == .function) {
            // `caller.pc` is already past this instruction: the return
            // point.
            return self.enterClosure(callee, args_base, argc, self.stack.items.len, .{ .return_dst = result_dst });
        }
        // The arguments are copied off the stack: the callee may
        // re-enter the VM and grow it. The slots keep them rooted.
        var buf: [max_native_args]Value = undefined;
        const args: []Value = if (argc <= buf.len)
            buf[0..argc]
        else
            self.allocator.alloc(Value, argc) catch return VmError.OutOfMemory;
        defer if (argc > buf.len) self.allocator.free(args);
        copyRun(args, self.stack.items[args_base..][0..argc]);
        if (callee.kind() == .native_fn and asNativeFn(callee).consumes and argc > 0) self.stack.items[args_base + argc - 1] = value_mod.nilValue();
        const result = try self.callDirect(callee, args);
        // The block is dead once the call returns (§6): the compiler
        // never reads a block after its call (`COMPILER.md` §4.4), so
        // it keeps nothing it held alive until a later call reuses it.
        nilSlots(self.stack.items[args_base - 1 ..][0 .. argc + 1]);
        storeResult(try self.slotPtrIn(self.currentFrame(), result_dst), &result);
    }

    /// Push `frame`. The caller has already grown the stack into
    /// the frame's window and recorded the length it found before
    /// doing so in `frame.entry_stack_len`; `popFrame` restores
    /// exactly that length.
    /// On failure the stack is restored to that length, as if the
    /// call had never started.
    fn pushFrame(self: *VM, frame: Frame) VmError!void {
        errdefer self.stack.shrinkRetainingCapacity(frame.entry_stack_len);
        if (self.frames.items.len >= self.max_frames) return VmError.StackOverflow;
        self.frames.append(self.allocator, frame) catch return VmError.OutOfMemory;
        self.noteHighWater(self.frames.items.len, self.stack.items.len);
    }

    /// Pop the top frame and restore the stack to the length it
    /// recorded on entry. The top-level frame is never popped.
    fn popFrame(self: *VM) Frame {
        std.debug.assert(self.frames.items.len > 1);
        const frame = self.frames.pop().?;
        self.stack.shrinkRetainingCapacity(frame.entry_stack_len);
        return frame;
    }

    /// The current frame's return of `return_value` (§6): into its
    /// host's cell, the halt of the top-level frame, or the caller's
    /// slot, the frame popped. A corrupt frame is refused before
    /// anything changes.
    fn returnValue(self: *VM, return_value: Value) VmError!void {
        const n = self.frames.items.len;
        const callee = &self.frames.items[n - 1];
        if (callee.host_result) |hr| {
            storeWords(&hr.value, return_value);
            // A batch's next element starts in the same frame, at the
            // `pc` the caller's fetch goes on from, past the safe point.
            if (hr.step != null) {
                const cb: *Callback = @fieldParentPtr("result", hr);
                const going = switch (cb.batch.step) {
                    inline else => |step| self.batchStep(callee, hr, step),
                };
                if (going) {
                    callee.pc = 0;
                    if (self.gcDue()) self.collectGarbage();
                    return;
                }
            }
            hr.done = true;
            _ = self.popFrame();
            return;
        }
        if (n == 1) {
            self.result = return_value;
            self.halted = true;
            return;
        }
        const caller = &self.frames.items[n - 2];
        if (callee.return_dst >= caller.routine.slot_count) return VmError.OperandOutOfRange;
        const absolute: usize = @as(usize, caller.base_slot) + callee.return_dst;
        self.stack.shrinkRetainingCapacity(callee.entry_stack_len);
        self.frames.items.len = n - 1;
        self.stack.items[absolute] = return_value;
    }

    // -------------------------------------------------------------------------
    // Group `closure` (VM.md §10.5)
    // -------------------------------------------------------------------------

    fn execClosure(self: *VM, frame: *const Frame, inst: Inst) VmError!void {
        const variant: Closure_ = @fromBackingInt(@intCast(inst.variant));
        switch (variant) {
            .make => try self.execClosureMake(frame, inst),
            .box_local => try self.execClosureBoxLocal(frame, inst),
            // `op_table` routes `get-cell` to `opGetCell`.
            .get_cell => unreachable,
            .new_cell => try self.execClosureNewCell(frame, inst),
            .init_cell => try self.execClosureInitCell(frame, inst),
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `closure:box-local A`: `slot[A]`'s value into a fresh cell, in
    /// its place. Allocating a cell leaves `vm.stack` as it is.
    fn execClosureBoxLocal(self: *VM, frame: *const Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const ptr = try self.slotPtrIn(frame, inst.a.index);
        if (ptr.kind() == .cell_internal) return VmError.InvalidCellState;
        ptr.* = self.allocCell(ptr.*, true) catch return VmError.OutOfMemory;
    }

    /// `closure:get-cell A B`: the contents of the cell in `slot[B]`.
    fn execClosureGetCell(self: *VM, frame: *const Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        if (inst.b.kind != .slot) return VmError.InvalidOperandKind;
        const cell = try VM.asCell((try self.slotPtrIn(frame, inst.b.index)).*);
        if (!cell.initialized) return VmError.UninitializedCell;
        try self.storeIn(frame, inst.a, cell.value);
    }

    /// `closure:new-cell A`: a placeholder cell, `init-cell` to fill.
    fn execClosureNewCell(self: *VM, frame: *const Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const cell_v = self.allocCell(value_mod.nilValue(), false) catch return VmError.OutOfMemory;
        try self.storeIn(frame, inst.a, cell_v);
    }

    /// `closure:init-cell A B`: `resolve(B)` into the placeholder cell
    /// in `slot[A]`. The cell is checked before B is read, so a cell
    /// filled twice is `InvalidCellState` whatever B is.
    fn execClosureInitCell(self: *VM, frame: *const Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const cell = try VM.asCell((try self.slotPtrIn(frame, inst.a.index)).*);
        if (cell.initialized) return VmError.InvalidCellState;
        cell.value = try self.resolveIn(frame, inst.b);
        cell.initialized = true;
    }

    /// `closure:make A W`: a closure over descriptor W's routine, its
    /// cells copied from the descriptor's sources (VM.md §6). Nothing
    /// allocates between the block and its cells, so the block is
    /// whole before a safe point can see it.
    fn execClosureMake(self: *VM, frame: *const Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const cap_idx = inst.wide();
        if (cap_idx >= frame.routine.capture_descs.len) return VmError.OperandOutOfRange;
        const desc = frame.routine.capture_descs[cap_idx];
        if (desc.sources.len != desc.routine.upvalue_count) return VmError.CaptureCountMismatch;
        const closure_v = self.allocClosure(desc.routine, desc.sources.len) catch return VmError.OutOfMemory;
        const upvalues = closureUpvaluesMut(closure_v);
        for (desc.sources, upvalues) |source, *cell| cell.* = switch (source) {
            .local_cell_slot => |slot| try VM.asCell((try self.slotPtrIn(frame, slot)).*),
            // The cell itself, not its contents as a `u` operand reads.
            .inherited_upvalue => |u| if (u < frame.upvalues.len) frame.upvalues[u] else return VmError.UpvalueOutOfRange,
        };
        try self.storeIn(frame, inst.a, closure_v);
    }

    // -------------------------------------------------------------------------
    // Group `jump` (VM.md §10.6)
    // -------------------------------------------------------------------------

    /// Move the frame to `pc`, inside its code: the compiler's unpatched
    /// placeholder, `maxInt(u32)`, fails here.
    fn applyJump(frame: *Frame, pc: u32) VmError!void {
        if (pc >= frame.routine.code.len) return VmError.OperandOutOfRange;
        frame.pc = pc;
    }

    // -------------------------------------------------------------------------
    // Group `math` (VM.md §10.3): the numeric tower below
    // -------------------------------------------------------------------------

    fn execMath(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const variant: Math = @fromBackingInt(@intCast(inst.variant));
        // The variant traps before any operand is read (§10.3).
        switch (variant) {
            .pow => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
            else => {},
        }
        // Resolve every source operand BEFORE storing so that
        // dst/src aliasing (e.g., math:add s0, s0, c0) is correct.
        const lhs = try self.resolveIn(frame, inst.b);
        const rhs = switch (variant) {
            .neg, .abs => value_mod.fromFixnum(0).?,
            else => try self.resolveIn(frame, inst.c),
        };
        try self.storeIn(frame, inst.a, try self.arithmetic(variant, lhs, rhs));
    }

    /// The `math:<variant>` of `lhs` and `rhs` (`rhs` ignored by the
    /// unary variants) through the numeric tower.
    fn arithmetic(self: *VM, variant: Math, lhs: Value, rhs: Value) VmError!Value {
        const heap = self.ensureHeap();
        return switch (variant) {
            .add => numAdd(heap, lhs, rhs),
            .sub => numSub(heap, lhs, rhs),
            .mul => numMul(heap, lhs, rhs),
            .div => numDiv(heap, lhs, rhs),
            .idiv => numQuot(heap, lhs, rhs),
            .mod => numMod(heap, lhs, rhs),
            .neg => numNeg(heap, lhs),
            .abs => numAbs(heap, lhs),
            .pow => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
        } catch |err| return self.numericError(err, switch (variant) {
            .add => "+",
            .sub, .neg => "-",
            .mul => "*",
            .div => "/",
            .idiv => "quot",
            .mod => "mod",
            else => "abs",
        }, lhs, rhs);
    }

    // -------------------------------------------------------------------------
    // Group `cmp` (VM.md §10.4)
    // -------------------------------------------------------------------------

    /// `numCompare`, with the report naming the operator.
    fn compareNumbers(self: *VM, cmp: NumCmp, lhs: Value, rhs: Value) VmError!bool {
        return numCompare(cmp, lhs, rhs) catch |err| return self.numericError(err, switch (cmp) {
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .eq => "==",
        }, lhs, rhs);
    }

    /// `err` from the numeric operation `op` on `lhs` and `rhs`; a
    /// `KindMismatch` names the operand that is not a number.
    fn numericError(self: *VM, err: VmError, op: []const u8, lhs: Value, rhs: Value) VmError {
        if (err != VmError.KindMismatch) return err;
        const bad = if (isNumber(lhs)) rhs else lhs;
        return self.fail(err, "{s} expects numbers, got {s}", .{ op, kindPhrase(bad.kind()) });
    }

    // -------------------------------------------------------------------------
    // Group `var` (VM.md §10.7)
    // -------------------------------------------------------------------------

    fn execVar(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const variant: VarOp = @fromBackingInt(@intCast(inst.variant));
        switch (variant) {
            // `op_table` routes `load-var` to `opLoadVar`.
            .load_var => unreachable,
            .store_var => try self.execVarStoreVar(frame, inst),
            .var_object => try self.execVarVarObject(frame, inst),
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// The Var at the wide field's index in the routine's Var table.
    inline fn wideVar(frame: *const Frame, inst: Inst) VmError!*Var {
        const var_table = frame.routine.var_table;
        const i = inst.wide();
        if (i >= var_table.len) return VmError.OperandOutOfRange;
        return var_table[i];
    }

    /// `var:load-var A=dst_slot W=var_index` — the Var's binding in
    /// force, else its root, into `slot[A]`; `:unbound-var` if it
    /// has neither. A `v` operand reads the same way in place.
    fn execVarLoadVar(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const v = (try wideVar(frame, inst)).current() orelse return VmError.UnboundVar;
        try self.storeIn(frame, inst.a, v);
    }

    /// `var:store-var A=value W=var_index` — the Var's root
    /// `:= resolve(A)`, marked bound and not a macro. Redefining a
    /// name updates the same Var, so code compiled against it sees
    /// the new root.
    fn execVarStoreVar(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        const target = try wideVar(frame, inst);
        target.root = try self.resolveIn(frame, inst.a);
        target.bound = true;
        target.macro = false;
    }

    /// `var:var-object A=dst_slot W=var_index` — the Var object
    /// itself into `slot[A]`; an unbound Var does not trap
    /// (Clojure's `(var x)` / `#'x`).
    fn execVarVarObject(self: *VM, frame: *Frame, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        try self.storeIn(frame, inst.a, VM.varToValue(try wideVar(frame, inst)));
    }

    // -------------------------------------------------------------------------
    // Group `coll` (VM.md §10.8)
    // -------------------------------------------------------------------------

    /// `coll:<op> A=base B=argc C=dst`. `Heap.alloc` never collects
    /// (§9), so what the construction allocates needs no rooting.
    fn execColl(self: *VM, inst: Inst) VmError!void {
        const variant: CollOp = @fromBackingInt(@intCast(inst.variant));
        if (inst.a.kind != .slot or inst.c.kind != .slot) return VmError.InvalidOperandKind;
        const frame = self.currentFrame();
        const argc: usize = inst.b.index;
        if (inst.a.index + argc > frame.routine.slot_count) return VmError.OperandOutOfRange;
        const start = @as(usize, frame.base_slot) + inst.a.index;
        if (start + argc > self.stack.items.len) return VmError.BytecodeCorruption;
        // Hashing or comparing a lazy seq realizes it in isolation, which
        // runs code that may grow the stack and the frames (docs/LAZY.md
        // §6): the arguments are copied off the stack, which keeps them
        // rooted, and the frame is read again after.
        var buf: [16]Value = undefined;
        const args: []Value = if (argc <= buf.len)
            buf[0..argc]
        else
            self.allocator.alloc(Value, argc) catch return VmError.OutOfMemory;
        defer if (argc > buf.len) self.allocator.free(args);
        // A map's constructor reads each key and value as one entry.
        if (variant == .map) copyEntries(args, self.stack.items[start..][0..argc]) else copyRun(args, self.stack.items[start..][0..argc]);
        const heap = self.ensureHeap();
        const hash = &dispatch_mod.hashValue;
        const eql = &dispatch_mod.equal;
        const overflows = dispatch_mod.spoilCount();
        errdefer self.dropSpoils(overflows);
        // Each result is read a word at a time where it is returned.
        const result: Value = switch (variant) {
            .list => returned(&(list_mod.fromSlice(heap, args) catch return VmError.OutOfMemory)),
            .vector => returned(&(vector_mod.fromSlice(heap, args) catch return VmError.OutOfMemory)),
            .map => blk: {
                if (argc % 2 != 0) return VmError.BytecodeCorruption;
                // Flat key, value pairs are `Entry`s laid end to end.
                const entries: [*]const champ_mod.Entry = @ptrCast(args.ptr);
                break :blk returned(&(champ_mod.mapFromEntries(heap, entries[0 .. argc / 2], hash, eql) catch return VmError.OutOfMemory));
            },
            .set => returned(&(champ_mod.setFromElements(heap, args, hash, eql) catch return VmError.OutOfMemory)),
            .concat => blk: {
                // A lazy part's spine is realized before anything is
                // gathered: realizing runs code that may collect, and
                // the gathered elements are rooted by nothing.
                for (args) |arg| if (arg.kind() == .lazy_seq) {
                    const ops = lazy_ops orelse return VmError.KindMismatch;
                    try ops.realize_spine(self, arg);
                };
                var elements: std.ArrayList(Value) = .empty;
                defer elements.deinit(self.allocator);
                for (args) |arg| self.appendSeqable(&elements, arg) catch |err| return switch (err) {
                    error.KindMismatch => VmError.KindMismatch,
                    else => VmError.OutOfMemory,
                };
                break :blk returned(&(list_mod.fromSlice(heap, elements.items) catch return VmError.OutOfMemory));
            },
            _ => return VmError.BytecodeCorruption,
        };
        try self.checkDeepData(overflows);
        storeWide(try self.slotPtrIn(self.currentFrame(), inst.c.index), result);
    }

    /// Append the elements of the seqable `v` to `out`; a map
    /// contributes `[k v]` entry vectors.
    fn appendSeqable(self: *VM, out: *std.ArrayList(Value), v: Value) !void {
        switch (v.kind()) {
            .nil => {},
            .list => {
                var node = v;
                while (node.kind() == .list and !list_mod.isEmpty(node)) : (node = list_mod.tail(node)) try out.append(self.allocator, list_mod.head(node));
            },
            // Realized by `execColl` before it gathers.
            .lazy_seq => {
                var c = lazy_mod.Cursor.init(v);
                while (c.next() catch return error.KindMismatch) |x| try out.append(self.allocator, x);
            },
            .persistent_vector => {
                const n = vector_mod.count(v);
                try out.ensureUnusedCapacity(self.allocator, n);
                for (0..n) |j| out.appendAssumeCapacity(vector_mod.nth(v, j));
            },
            .persistent_map => {
                var it = champ_mod.mapIter(v);
                while (it.next()) |e| try out.append(self.allocator, try vector_mod.fromSlice(self.ensureHeap(), &.{ e.key, e.value }));
            },
            .persistent_set => {
                var it = champ_mod.setIter(v);
                while (it.next()) |e| try out.append(self.allocator, e);
            },
            .sorted_map, .sorted_set => {
                var it = sorted_mod.Iter.init(v, true);
                while (it.next()) |e| try out.append(self.allocator, if (v.kind() == .sorted_map) try vector_mod.fromSlice(self.ensureHeap(), &.{ e.key, e.value }) else e.key);
            },
            else => return error.KindMismatch,
        }
    }

    // -------------------------------------------------------------------------
    // Group `ctrl` (VM.md §10.9, §12)
    // -------------------------------------------------------------------------

    fn execCtrl(self: *VM, inst: Inst) VmError!void {
        const variant: CtrlOp = @fromBackingInt(@intCast(inst.variant));
        switch (variant) {
            .try_enter => try self.execCtrlTryEnter(inst),
            .try_exit => try self.execCtrlTryExit(inst),
            .throw_ => try self.execCtrlThrow(inst),
            .finally_exit => try self.execCtrlFinallyExit(inst),
            .halt_ => return VmError.UnimplementedOpcode,
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// `ctrl:try-enter A=binding W=try`: a `try_` handler for
    /// `routine.tries[W]`.
    fn execCtrlTryEnter(self: *VM, inst: Inst) VmError!void {
        if (inst.a.kind != .slot) return VmError.InvalidOperandKind;
        const frame_index = self.frames.items.len - 1;
        const tries = self.frames.items[frame_index].routine.tries;
        const i = inst.wide();
        if (i >= tries.len) return VmError.OperandOutOfRange;
        // A continuation is pushed only as a handler pops, so this is
        // room for every one a throw may need: a throw allocates
        // nothing a handler cannot do without (§12, §13).
        try self.finally_stack.ensureTotalCapacity(self.allocator, self.handlers.items.len + 1 + self.finally_stack.items.len);
        try self.handlers.append(self.allocator, .{
            .kind = .try_,
            .frame_index = frame_index,
            .catch_pc = tries[i].catch_pc,
            .binding_slot = inst.a.index,
            .finally_pc = tries[i].finally_pc,
            .finally_depth = self.finally_stack.items.len,
        });
    }

    /// `ctrl:try-exit W=post_pc`: pop this frame's handler and go to
    /// `post_pc`, through its finally when it has one.
    fn execCtrlTryExit(self: *VM, inst: Inst) VmError!void {
        const post_pc = inst.wide();

        const top = self.handlers.last() orelse return VmError.InvalidHandlerState;
        const frame_index = self.frames.items.len - 1;
        if (top.frame_index != frame_index) return VmError.InvalidHandlerState;

        _ = self.handlers.pop();
        const frame = self.currentFrame();
        if (top.finally_pc) |fpc| {
            try self.finally_stack.append(self.allocator, .{
                .frame_index = frame_index,
                .reason = .{ .normal = post_pc },
            });
            frame.pc = fpc;
        } else {
            frame.pc = post_pc;
        }
    }

    /// `ctrl:finally-exit`: go on as the innermost continuation says.
    fn execCtrlFinallyExit(self: *VM, _: Inst) VmError!void {
        if (self.finally_stack.items.len == 0) return VmError.InvalidHandlerState;
        const cont = self.finally_stack.pop().?;
        const frame_index = self.frames.items.len - 1;
        if (cont.frame_index != frame_index) return VmError.InvalidHandlerState;
        switch (cont.reason) {
            .normal => |post_pc| {
                const frame = self.currentFrame();
                frame.pc = post_pc;
            },
            .throwing => |value| {
                try self.unwindThrow(value, cont.origin);
            },
        }
    }

    fn execCtrlThrow(self: *VM, inst: Inst) VmError!void {
        const value = try self.resolveIn(self.currentFrame(), inst.a);
        try self.unwindThrow(value, self.originFor(value, null));
    }

    /// The innermost handler a throw goes to: a `try_`, which catches,
    /// or a `cleanup` with a finally, which runs it first; null when
    /// none is in force.
    fn findThrowTarget(self: *VM) ?usize {
        var i: usize = self.handlers.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.handlers.items[i];
            switch (h.kind) {
                .try_ => return i,
                .cleanup => if (h.finally_pc != null) return i,
            }
        }
        return null;
    }

    /// Throw `value` from a native as `ctrl:throw` does (§12): the
    /// native returns what this returns, `ControlTransferred` when a
    /// handler took it, `UncaughtThrow` when none is in force.
    pub fn throwValue(self: *VM, value: Value) VmError {
        self.unwindThrow(value, self.originFor(value, null)) catch |err| return err;
        return VmError.ControlTransferred;
    }

    /// `throwValue` of the error named `name`, as a runtime error
    /// travels (VM.md §13): the map `errorValue` builds, located at
    /// the frame that called the native, when a handler is in force
    /// to take it; the bare keyword when none is, which the host's
    /// report names.
    pub fn throwKeyword(self: *VM, name: []const u8) VmError {
        const kw = self.ensureInterner().internKeywordValue(name) catch return VmError.OutOfMemory;
        if (self.findThrowTarget() == null) return self.throwValue(kw);
        return self.throwValue(self.errorValue(kw, "", self.raiseSite()));
    }

    /// The throw of `value`, from `ctrl:throw`, a native or a finally
    /// resuming one (§12): every handler, continuation and frame above
    /// the handler that takes it goes, each popped frame restoring its
    /// stack length; a `try_` becomes the `cleanup` its catch body runs
    /// under, with the value in its slot, and a `cleanup` runs its
    /// finally, which resumes the throw.
    fn unwindThrow(self: *VM, value: Value, origin: ?u32) VmError!void {
        const handler_idx = self.findThrowTarget() orelse {
            self.unhandled_throw = value;
            self.escaped_origin = origin;
            return VmError.UncaughtThrow;
        };
        const matched = self.handlers.items[handler_idx];
        self.handlers.shrinkRetainingCapacity(handler_idx);
        self.finally_stack.shrinkRetainingCapacity(matched.finally_depth);
        while (self.frames.items.len - 1 > matched.frame_index) _ = self.popFrame();
        const frame = self.currentFrame();
        switch (matched.kind) {
            .try_ => {
                try self.handlers.append(self.allocator, .{
                    .kind = .cleanup,
                    .frame_index = matched.frame_index,
                    .catch_pc = 0,
                    .binding_slot = 0,
                    .finally_pc = matched.finally_pc,
                    .finally_depth = matched.finally_depth,
                    .origin = origin,
                });
                if (matched.binding_slot >= frame.routine.slot_count) return VmError.InvalidHandlerState;
                self.slotAt(frame, matched.binding_slot).* = value;
                frame.pc = matched.catch_pc;
            },
            .cleanup => {
                const fpc = matched.finally_pc orelse return VmError.InvalidHandlerState;
                try self.finally_stack.append(self.allocator, .{
                    .frame_index = matched.frame_index,
                    .reason = .{ .throwing = value },
                    .origin = origin,
                });
                frame.pc = fpc;
            },
        }
    }
};

/// The keyword name of a catchable error (VM.md §13): its tag in
/// kebab case, `KindMismatch` as `kind-mismatch`. Null for the rest,
/// compiler bugs, corrupt bytecode, memory and the control signals,
/// which leave a run as they are.
pub fn vmErrorToKeywordName(err: VmError) ?[]const u8 {
    return switch (err) {
        VmError.UncaughtThrow,
        VmError.BytecodeCorruption,
        VmError.BytecodeExhausted,
        VmError.UnimplementedOpcode,
        VmError.OperandOutOfRange,
        VmError.InvalidOperandKind,
        VmError.OutOfMemory,
        VmError.CaptureCountMismatch,
        VmError.UpvalueOutOfRange,
        VmError.ExpectedCell,
        VmError.InvalidCellState,
        VmError.UninitializedCell,
        VmError.CallBlockOutOfRange,
        VmError.InvalidHandlerState,
        VmError.ControlTransferred,
        VmError.NeedsReentry,
        => null,
        inline else => |e| comptime kebab(@errorName(e)),
    };
}

/// `name` in kebab case: a `-` before each upper-case letter but the
/// first, every letter lower case.
fn kebab(comptime name: []const u8) []const u8 {
    @setEvalBranchQuota(10_000);
    var out: []const u8 = "";
    for (name, 0..) |c, i| {
        if (i > 0 and std.ascii.isUpper(c)) out = out ++ "-";
        out = out ++ .{std.ascii.toLower(c)};
    }
    return out;
}

// =============================================================================
// Lookup (SEMANTICS.md §4, VM.md §6)
//
// `get` and the invocable-as-lookup kinds share one lookup so that
// `(get m k)`, `(:k m)` and `(m :k)` cannot drift apart.
// =============================================================================

/// `(get coll key default)`. Maps and records look the key up,
/// sets return the element itself when present, vectors index by
/// fixnum, a lazy entity reads the attribute from its view, nil
/// yields the default. Any other receiver is a `KindMismatch`. A
/// sorted collection with no VM to call its comparator through is
/// searched by `=` (`lookupIn`).
pub fn lookup(coll: Value, key: Value, default: Value) VmError!Value {
    return lookupIn(null, coll, key, default);
}

/// `lookup` with the VM a sorted collection's comparator runs on
/// (SORTED.md §8): an incomparable key is `KindMismatch` and a
/// comparator's throw propagates, as in Clojure.
pub fn lookupIn(vm: ?*VM, coll: Value, key: Value, default: Value) VmError!Value {
    return switch (coll.kind()) {
        .nil => default,
        .sorted_map, .sorted_set => {
            const e = (try sortedFind(vm, coll, key)) orelse return default;
            return if (coll.kind() == .sorted_map) e.value else e.key;
        },
        .persistent_map => mapLookup(coll, key, default),
        .record => mapLookup(record_mod.fieldsOf(coll), key, default),
        // A lazy entity reads the attribute through the hook its box
        // carries (docs/NEXTOMIC.md §6.1); the hook returns only errors
        // of this set.
        .nextomic_entity => nextomic_handle.entityLookup(coll, key, default) catch |err| return @as(VmError, @errorCast(err)),
        // The element the set holds, which may differ from an equal key.
        .persistent_set => champ_mod.setGet(coll, key, &dispatch_mod.hashValue, &dispatch_mod.equal) orelse default,
        .persistent_vector => blk: {
            if (key.kind() != .fixnum) break :blk default;
            const idx = key.asFixnum();
            if (idx < 0 or @as(usize, @intCast(idx)) >= vector_mod.count(coll)) break :blk default;
            break :blk vector_mod.nth(coll, @intCast(idx));
        },
        .transient => (try transientLookup(coll, key)) orelse default,
        else => VmError.KindMismatch,
    };
}

/// The value at `k` in transient map `t`, the element `k` of a
/// transient set or the element at index `k` of a transient vector;
/// null when absent (TRANSIENT.md §7).
pub fn transientLookup(t: Value, k: Value) VmError!?Value {
    return transientFind(t, k) catch |err| switch (err) {
        error.TransientFrozen => VmError.TransientUsedAfterPersistent,
        else => VmError.KindMismatch,
    };
}

fn transientFind(t: Value, k: Value) transient_mod.TransientError!?Value {
    switch (t.subkind()) {
        transient_mod.subkind_transient_map => return switch (try transient_mod.mapGetBang(t, k, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
            .present => |v| v,
            .absent => null,
        },
        transient_mod.subkind_transient_set => return transient_mod.setGetBang(t, k, &dispatch_mod.hashValue, &dispatch_mod.equal),
        else => {
            if (k.kind() != .fixnum or k.asFixnum() < 0 or @as(usize, @intCast(k.asFixnum())) >= try transient_mod.vectorCountBang(t)) return null;
            return try transient_mod.vectorNthBang(t, @intCast(k.asFixnum()));
        },
    }
}

/// The entry of sorted `coll` whose key its order finds equal to
/// `key`; without a VM, the entry whose key is `=` to it.
pub fn sortedFind(vm: ?*VM, coll: Value, key: Value) VmError!?sorted_mod.Entry {
    if (vm) |v| return sorted_mod.find(coll, key, SortedOrder.of(v, coll));
    var it = sorted_mod.Iter.init(coll, true);
    while (it.next()) |e| if (dispatch_mod.equal(e.key, key)) return e;
    return null;
}

/// A sorted collection's order as `sorted.zig` takes it (SORTED.md
/// §4, §6): the natural order, or the comparator function coerced as
/// Clojure's `AFunction.compare` coerces one. The comparator re-enters
/// the VM and may collect.
pub const SortedOrder = struct {
    vm: *VM,
    /// The function, or nil for the natural order.
    comparator: Value,

    pub const Error = VmError;

    pub fn of(vm: *VM, coll: Value) SortedOrder {
        return .{ .vm = vm, .comparator = sorted_mod.comparatorOf(coll) };
    }

    pub fn order(self: SortedOrder, a: Value, b: Value) VmError!std.math.Order {
        if (self.comparator.isNil()) return naturalOrder(self.vm, a, b);
        const r = try self.vm.callValue(self.comparator, &.{ a, b });
        return switch (r.kind()) {
            .true_ => .lt,
            // A predicate: `(f b a)` tells greater from equal.
            .false_, .nil => if ((try self.vm.callValue(self.comparator, &.{ b, a })).isTruthy()) .gt else .eq,
            .fixnum => std.math.order(r.asFixnum(), 0),
            // Java's `intValue`: toward zero, NaN to zero.
            .float => if (std.math.isNan(r.asFloat())) .eq else std.math.order(@trunc(r.asFloat()), 0),
            .bignum => if (bignum_mod.isNegative(r)) .lt else .gt,
            else => VmError.KindMismatch,
        };
    }
};

/// Clojure's `compare` (SORTED.md §6).
pub fn naturalOrder(vm: *VM, a: Value, b: Value) VmError!std.math.Order {
    return sorted_mod.naturalOrder(vm.ensureInterner(), a, b) catch |err| switch (err) {
        error.KindMismatch => VmError.KindMismatch,
        error.StackOverflow => VmError.StackOverflow,
    };
}

/// What a sorted-collection update can fail with.
pub const SortedUpdateError = VmError || sorted_mod.AllocError;

/// A sorted-collection update's failure as the VM reports it: the
/// comparator's own error, or memory.
pub fn sortedFailure(err: SortedUpdateError) VmError {
    return switch (err) {
        error.Overflow => VmError.OutOfMemory,
        else => |e| @errorCast(e),
    };
}

fn mapLookup(m: Value, key: Value, default: Value) Value {
    return switch (champ_mod.mapGet(m, key, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
        .present => |v| v,
        .absent => default,
    };
}

/// How an error report names a value of kind `k`: as the language
/// presents it, the integer tower one kind.
pub fn kindPhrase(k: value_mod.Kind) []const u8 {
    return switch (k) {
        .nil => "nil",
        .false_, .true_ => "a boolean",
        .fixnum, .bignum => "an integer",
        .inst => "an instant",
        .uuid => "a UUID",
        .persistent_map => "a map",
        .persistent_set => "a set",
        .sorted_map => "a sorted map",
        .sorted_set => "a sorted set",
        .persistent_vector => "a vector",
        .function, .native_fn, .protocol_fn => "a function",
        .var_ => "a var",
        .atom => "an atom",
        .db_write_txn => "a db write transaction",
        .db_read_txn => "a db read transaction",
        .nextomic_conn => "a Nextomic connection",
        .nextomic_db => "a Nextomic db",
        .nextomic_entity => "a Nextomic entity",
        .cell_internal => "a cell",
        else => {
            const info = @typeInfo(value_mod.Kind).@"enum";
            inline for (info.field_names, info.field_values) |name, value| {
                // The tag name with its underscores as spaces:
                // "a typed vector", "a durable ref".
                const phrase = comptime blk: {
                    var buf: [name.len]u8 = name[0..name.len].*;
                    for (&buf) |*c| if (c.* == '_') {
                        c.* = ' ';
                    };
                    const final = buf;
                    break :blk "a " ++ &final;
                };
                if (@backingInt(k) == value) return phrase;
            }
            return "a value";
        },
    };
}

/// Kinds a `call:call` treats as a lookup rather than a function.
/// `(k target default)` for a keyword or symbol `k` where it needs no
/// callback: `target` nil, a hash map or a record; null otherwise.
inline fn lookupInPlace(k: Value, target: Value, default: Value) ?Value {
    return switch (target.kind()) {
        .nil => default,
        .persistent_map => mapLookup(target, k, default),
        .record => mapLookup(record_mod.fieldsOf(target), k, default),
        else => null,
    };
}

pub fn isLookupCallable(k: value_mod.Kind) bool {
    return switch (k) {
        .keyword, .symbol, .persistent_map, .persistent_set, .persistent_vector, .transient, .sorted_map, .sorted_set => true,
        else => false,
    };
}

/// Invoke a keyword or collection as a function.
///
///   (:k x)      → (get x :k)       nil when `x` is not a lookup target
///   (:k x d)    → (get x :k d)     a symbol, `('s x)`, alike
///   (m k), (m k d) → (get m k d)
///   (s x)       → (get s x)       sets take exactly one argument
///   (v i)       → (nth v i)       vectors take exactly one fixnum;
///                                 out of range is an error
///
/// A transient map, set or vector is called, and looked up by a
/// keyword, as its persistent kind is (TRANSIENT.md §7); a sorted map
/// or set as a map or set is, through its comparator on `vm`. Any
/// other arity is `ArityMismatch` (VM.md §6). A caller with no VM
/// reaches a sorted key by `=` (`lookupIn`).
pub fn callLookupIn(vm: *VM, callee: Value, args: []const Value) VmError!Value {
    const phrase = kindPhrase(callee.kind());
    // A set and a transient vector or set take the key alone.
    const max: usize = switch (callee.kind()) {
        .persistent_set, .sorted_set, .persistent_vector => 1,
        .transient => if (callee.subkind() == transient_mod.subkind_transient_map) 2 else 1,
        else => 2,
    };
    if (args.len < 1 or args.len > max) return vm.arityError(phrase, 1, max, args.len);
    const default = if (args.len == 2) args[1] else value_mod.nilValue();
    return switch (callee.kind()) {
        .keyword, .symbol => switch (args[0].kind()) {
            .nil, .persistent_map, .record, .persistent_set, .persistent_vector, .nextomic_entity, .transient, .sorted_map, .sorted_set => lookupIn(vm, args[0], callee, default),
            else => default,
        },
        .persistent_map, .sorted_map, .persistent_set, .sorted_set => lookupIn(vm, callee, args[0], default),
        .transient => switch (callee.subkind()) {
            transient_mod.subkind_transient_map, transient_mod.subkind_transient_set => lookup(callee, args[0], default),
            else => blk: {
                if (args[0].kind() != .fixnum) return vm.fail(VmError.KindMismatch, "{s} takes an integer index, got {s}", .{ phrase, kindPhrase(args[0].kind()) });
                break :blk (try transientLookup(callee, args[0])) orelse vm.fail(VmError.IndexOutOfBounds, "index {d} is out of bounds for {s}", .{ args[0].asFixnum(), phrase });
            },
        },
        .persistent_vector => blk: {
            if (args[0].kind() != .fixnum) return vm.fail(VmError.KindMismatch, "{s} takes an integer index, got {s}", .{ phrase, kindPhrase(args[0].kind()) });
            const idx = args[0].asFixnum();
            const n = vector_mod.count(callee);
            if (idx < 0 or @as(usize, @intCast(idx)) >= n) return vm.fail(VmError.IndexOutOfBounds, "index {d} is out of bounds for a vector of {d}", .{ idx, n });
            break :blk vector_mod.nth(callee, @intCast(idx));
        },
        else => VmError.NotCallable,
    };
}

// =============================================================================
// Numeric tower (SEMANTICS §2.2, BIGNUM.md §8)
//
// Three runtime number kinds take part in arithmetic: `fixnum`
// (i48), `bignum` and `float` (f64). Contagion follows Clojure: an
// operation with any float operand is carried out in f64 and yields
// a float; an operation on integers is exact, promoting to a bignum
// when a result leaves the i48 range and demoting to a fixnum when
// one fits (BIGNUM.md §1), so `=` and `hash` agree for every integer
// whatever its history. Two fixnums stay in i64 and touch the heap
// only on promotion. `/` on two integers yields an integer when the
// division is exact and the float nearest the quotient otherwise
// (there are no rationals, PLAN §23 #10). `/`, `quot`, `rem` and
// `mod` raise `DivideByZero` for a zero divisor of either kind.
//
// These are the single implementation behind the `math:*` and
// `cmp:*` opcodes and the arithmetic natives in stdlib.zig. The heap
// is the VM's (`ensureHeap`), where a promoted result lives.
// =============================================================================

/// Any operand kind arithmetic accepts.
pub fn isNumber(v: value_mod.Value) bool {
    return v.isFixnum() or v.isFloat() or v.kind() == .bignum;
}

/// Any member of the integer tower.
pub fn isInteger(v: value_mod.Value) bool {
    return bignum_mod.isInteger(v);
}

/// Widen a number to f64 for a contagious operation.
fn toFloat(v: value_mod.Value) VmError!f64 {
    return switch (v.kind()) {
        .fixnum => @floatFromInt(v.asFixnum()),
        .float => v.asFloat(),
        .bignum => bignum_mod.toF64(v),
        else => VmError.KindMismatch,
    };
}

/// An i64 result of a fixnum × fixnum operation in canonical form:
/// a fixnum when it fits, a bignum otherwise.
fn integerResult(heap: *heap_mod.Heap, n: i64) VmError!value_mod.Value {
    return value_mod.fromFixnum(n) orelse (bignum_mod.fromI64(heap, n) catch VmError.OutOfMemory);
}

fn isZero(v: value_mod.Value) bool {
    return (v.isFixnum() and v.asFixnum() == 0) or (v.isFloat() and v.asFloat() == 0);
}

const IntOp = enum { add, sub, mul };

/// One contagious binary operation. Two fixnums stay in i64 (a
/// product of two i48 values fits i96, so i128 is exact) and the
/// result is canonicalized; any float operand widens both sides to
/// f64; any other pair of integers goes through bignum arithmetic.
fn arith(comptime op: IntOp, heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (a.isFixnum() and b.isFixnum()) {
        const x = a.asFixnum();
        const y = b.asFixnum();
        return switch (op) {
            .add => integerResult(heap, x + y),
            .sub => integerResult(heap, x - y),
            .mul => blk: {
                const p = @as(i128, x) * @as(i128, y);
                if (p >= value_mod.fixnum_min and p <= value_mod.fixnum_max) break :blk value_mod.fromFixnum(@intCast(p)).?;
                break :blk bignum_mod.fromI128(heap, p) catch VmError.OutOfMemory;
            },
        };
    }
    if (a.isFloat() or b.isFloat()) {
        const x = try toFloat(a);
        const y = try toFloat(b);
        return value_mod.fromFloat(switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
        });
    }
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    return (switch (op) {
        .add => bignum_mod.add(heap, a, b),
        .sub => bignum_mod.sub(heap, a, b),
        .mul => bignum_mod.mul(heap, a, b),
    }) catch VmError.OutOfMemory;
}

const DivOp = enum { quot, rem, mod };

/// The division family: a zero divisor of either kind raises before
/// the operation is chosen. `quot` truncates; `rem` takes the
/// dividend's sign; `mod` is floored and takes the divisor's sign.
fn divLike(comptime op: DivOp, heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (isZero(b)) return VmError.DivideByZero;
    if (a.isFixnum() and b.isFixnum()) {
        const x = a.asFixnum();
        const y = b.asFixnum();
        // Only `(quot fixnum_min -1)` leaves the fixnum range.
        return integerResult(heap, switch (op) {
            .quot => @divTrunc(x, y),
            .rem => @rem(x, y),
            .mod => @mod(x, y),
        });
    }
    if (a.isFloat() or b.isFloat()) {
        const x = try toFloat(a);
        const y = try toFloat(b);
        return value_mod.fromFloat(switch (op) {
            .quot => @trunc(x / y),
            .rem => @rem(x, y),
            .mod => blk: {
                const r = @rem(x, y);
                break :blk if (r != 0 and (r < 0) != (y < 0)) r + y else r;
            },
        });
    }
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    return (switch (op) {
        .quot => bignum_mod.quot(heap, a, b),
        .rem => bignum_mod.rem(heap, a, b),
        .mod => bignum_mod.mod(heap, a, b),
    }) catch VmError.OutOfMemory;
}

pub fn numAdd(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return arith(.add, heap, a, b);
}

pub fn numSub(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return arith(.sub, heap, a, b);
}

pub fn numMul(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return arith(.mul, heap, a, b);
}

/// `/`: an exact integer quotient stays an integer, anything else
/// is f64.
pub fn numDiv(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    if (a.isFixnum() and b.isFixnum()) {
        const x = a.asFixnum();
        const y = b.asFixnum();
        if (y == 0) return VmError.DivideByZero;
        if (@rem(x, y) == 0) return integerResult(heap, @divTrunc(x, y));
        return value_mod.fromFloat(@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(y)));
    }
    if (a.isFloat() or b.isFloat()) {
        // Clojure's `Numbers.divide`: a NaN operand is the result,
        // then a zero divisor raises, a float's as an integer's.
        const x = try toFloat(a);
        const y = try toFloat(b);
        if (std.math.isNan(x)) return a;
        if (std.math.isNan(y)) return b;
        if (y == 0) return VmError.DivideByZero;
        return value_mod.fromFloat(x / y);
    }
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    if (isZero(b)) return VmError.DivideByZero;
    const exact = bignum_mod.quotExact(heap, a, b) catch return VmError.OutOfMemory;
    if (exact) |q| return q;
    return value_mod.fromFloat(bignum_mod.quotientF64(heap, a, b) catch return VmError.OutOfMemory);
}

/// `quot`: truncated division. A zero divisor of either kind raises.
pub fn numQuot(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return divLike(.quot, heap, a, b);
}

/// `rem`: remainder of truncated division, sign of the dividend.
pub fn numRem(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return divLike(.rem, heap, a, b);
}

/// `mod`: remainder of floored division, sign of the divisor.
pub fn numMod(heap: *heap_mod.Heap, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return divLike(.mod, heap, a, b);
}

pub fn numNeg(heap: *heap_mod.Heap, a: value_mod.Value) VmError!value_mod.Value {
    return switch (a.kind()) {
        .fixnum => integerResult(heap, -a.asFixnum()),
        .float => value_mod.fromFloat(-a.asFloat()),
        .bignum => bignum_mod.neg(heap, a) catch VmError.OutOfMemory,
        else => VmError.KindMismatch,
    };
}

pub fn numAbs(heap: *heap_mod.Heap, a: value_mod.Value) VmError!value_mod.Value {
    return switch (a.kind()) {
        .fixnum => integerResult(heap, @intCast(@abs(a.asFixnum()))),
        .float => value_mod.fromFloat(@abs(a.asFloat())),
        .bignum => bignum_mod.abs(heap, a) catch VmError.OutOfMemory,
        else => VmError.KindMismatch,
    };
}

/// The comparison predicates of the tower. The variants share
/// their values with the `cmp` opcode group so `cmpHandler` needs no
/// mapping.
pub const NumCmp = enum(u6) { lt, lte, gt, gte, eq };

comptime {
    for (std.meta.tags(NumCmp)) |tag| {
        const op: Cmp = @fromBackingInt(@intCast(@backingInt(tag)));
        std.debug.assert(std.mem.startsWith(u8, @tagName(op), @tagName(tag)));
    }
}

/// Ordered comparison across the tower. Two integers compare
/// exactly at any size; any float operand widens both sides to f64,
/// so `(< 1 1.5)` holds and `(== 1 1.0)` holds. NaN compares false
/// under every predicate, as IEEE specifies.
pub fn numCompare(cmp: NumCmp, a: value_mod.Value, b: value_mod.Value) VmError!bool {
    if (a.isFixnum() and b.isFixnum()) return ordered(i64, cmp, a.asFixnum(), b.asFixnum());
    if (a.isFloat() or b.isFloat()) return ordered(f64, cmp, try toFloat(a), try toFloat(b));
    return holds(cmp, try integerOrder(a, b));
}

fn ordered(comptime T: type, cmp: NumCmp, x: T, y: T) bool {
    return switch (cmp) {
        .lt => x < y,
        .lte => x <= y,
        .gt => x > y,
        .gte => x >= y,
        .eq => x == y,
    };
}

fn holds(cmp: NumCmp, ord: std.math.Order) bool {
    return switch (cmp) {
        .lt => ord == .lt,
        .lte => ord != .gt,
        .gt => ord == .gt,
        .gte => ord != .lt,
        .eq => ord == .eq,
    };
}

/// Exact order of two integers of any size.
fn integerOrder(a: value_mod.Value, b: value_mod.Value) VmError!std.math.Order {
    if (!isInteger(a) or !isInteger(b)) return VmError.KindMismatch;
    if (a.isFixnum() and b.isFixnum()) return std.math.order(a.asFixnum(), b.asFixnum());
    return bignum_mod.compare(a, b);
}

/// Sign tests shared by `zero?`, `pos?` and `neg?`: the order of
/// the number against zero, or `null` for NaN, which is neither
/// positive, negative nor zero (Clojure's `isZero`, `isPos` and
/// `isNeg` are all false on it). Negative zero is zero.
pub fn numSign(a: value_mod.Value) VmError!?std.math.Order {
    return switch (a.kind()) {
        .fixnum => std.math.order(a.asFixnum(), 0),
        .bignum => if (bignum_mod.isNegative(a)) .lt else .gt,
        .float => blk: {
            const f = a.asFloat();
            if (f > 0) break :blk .gt;
            if (f < 0) break :blk .lt;
            if (f == 0) break :blk .eq;
            break :blk null;
        },
        else => VmError.KindMismatch,
    };
}

/// `even?` / `odd?`: integers only, as in Clojure.
pub fn numEven(a: value_mod.Value) VmError!bool {
    if (a.isFixnum()) return a.asFixnum() & 1 == 0;
    if (!isInteger(a)) return VmError.KindMismatch;
    return bignum_mod.isEven(a);
}

/// `long`: a number as an integer. An integer is itself; a finite
/// float is its integer part (toward zero), a bignum when that is
/// wide; NaN and the infinities have no integer and raise
/// `InvalidArgument`.
pub fn numLong(heap: *heap_mod.Heap, a: value_mod.Value) VmError!value_mod.Value {
    if (isInteger(a)) return a;
    if (!a.isFloat()) return VmError.KindMismatch;
    const converted = bignum_mod.fromF64(heap, a.asFloat()) catch return VmError.OutOfMemory;
    return converted orelse VmError.InvalidArgument;
}

/// `double`: a number as an f64, a bignum through its nearest double.
pub fn numDouble(a: value_mod.Value) VmError!value_mod.Value {
    return value_mod.fromFloat(try toFloat(a));
}

/// `max`/`min` over two operands: the winning operand itself, of
/// its own kind (`(max 2 1.0)` is 2); on a tie the second, as
/// Clojure's `(if (> x y) x y)`; NaN wins.
/// The winner is read a word at a time into the result: a choice
/// between two values returned whole is assembled in a temporary and
/// copied out with loads wider than its stores (`VM.loadWords`).
pub fn numExtremum(want_max: bool, a: value_mod.Value, b: value_mod.Value) VmError!value_mod.Value {
    return VM.loadWords(if (try extremumIsFirst(want_max, a, b)) &a else &b);
}

fn extremumIsFirst(want_max: bool, a: value_mod.Value, b: value_mod.Value) VmError!bool {
    if (a.isFloat() or b.isFloat()) {
        const x = try toFloat(a);
        const y = try toFloat(b);
        if (std.math.isNan(x)) return true;
        if (std.math.isNan(y)) return false;
        return if (want_max) x > y else x < y;
    }
    return try integerOrder(a, b) == (if (want_max) std.math.Order.gt else std.math.Order.lt);
}
// =============================================================================
// Hand-assembled bytecode: one encoder per instruction the compiler
// emits (VM.md §10), for the compiler and the tests.
// =============================================================================

pub fn makeRoutine(code: []const Inst, consts: []const Value, slot_count: u16, name: []const u8) Routine {
    return .{ .code = code, .consts = consts, .slot_count = slot_count, .name = name };
}

pub const asm_ = struct {
    const s = Operand.slot;
    const none = Operand.none;

    pub fn loadConst(dst: u12, w: u32) Inst {
        return Inst.primaryWide(.mov, Mov.load_const, s(dst), w);
    }
    pub fn move(dst: u12, src: u12) Inst {
        return Inst.primary(.mov, Mov.move, s(dst), s(src), none);
    }
    /// `mov:move` from any operand kind `resolve` reads.
    pub fn moveFrom(dst: u12, src: Operand) Inst {
        return Inst.primary(.mov, Mov.move, s(dst), src, none);
    }
    pub fn moveClear(dst: u12, src: u12) Inst {
        return Inst.primary(.mov, Mov.move_clear, s(dst), s(src), none);
    }
    pub fn loadNil(dst: u12) Inst {
        return Inst.primary(.mov, Mov.load_nil, s(dst), none, none);
    }
    pub fn loadTrue(dst: u12) Inst {
        return Inst.primary(.mov, Mov.load_true, s(dst), none, none);
    }
    pub fn loadFalse(dst: u12) Inst {
        return Inst.primary(.mov, Mov.load_false, s(dst), none, none);
    }
    pub fn returnSlot(src: u12) Inst {
        return Inst.primary(.call, Call.@"return", s(src), none, none);
    }
    pub fn returnNil() Inst {
        return Inst.primary(.call, Call.return_nil, none, none, none);
    }
    pub fn mathAdd(dst: u12, lhs: Operand, rhs: Operand) Inst {
        return Inst.primary(.math, Math.add, s(dst), lhs, rhs);
    }
    pub fn cmpLt(dst: u12, lhs: Operand, rhs: Operand) Inst {
        return Inst.primary(.cmp, Cmp.lt, s(dst), lhs, rhs);
    }
    pub fn varLoadVar(dst: u12, w: u32) Inst {
        return Inst.primaryWide(.var_, VarOp.load_var, s(dst), w);
    }
    pub fn varStoreVar(w: u32, value: Operand) Inst {
        return Inst.primaryWide(.var_, VarOp.store_var, value, w);
    }
    pub fn varVarObject(dst: u12, w: u32) Inst {
        return Inst.primaryWide(.var_, VarOp.var_object, s(dst), w);
    }
    /// `coll:<op>` of the `argc` slots from `base`, the count an
    /// immediate (VM.md §4.5).
    pub fn coll(op: CollOp, base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(.coll, op, s(base), s(argc), s(dst));
    }
    /// `coll(.vector, ...)`, as `compile.zig`'s tests spell it.
    pub fn collVector(base: u12, argc: u12, dst: u12) Inst {
        return coll(.vector, base, argc, dst);
    }
    pub fn tryEnter(w: u32, binding: u12) Inst {
        return Inst.primaryWide(.ctrl, CtrlOp.try_enter, s(binding), w);
    }
    pub fn tryExit(post_pc: u32) Inst {
        return Inst.primaryWide(.ctrl, CtrlOp.try_exit, none, post_pc);
    }
    pub fn finallyExit() Inst {
        return Inst.primary(.ctrl, CtrlOp.finally_exit, none, none, none);
    }
    pub fn throwOp(value: Operand) Inst {
        return Inst.primary(.ctrl, CtrlOp.throw_, value, none, none);
    }
    pub fn jumpJmp(target: u32) Inst {
        return Inst.primaryWide(.jump, Jump.jmp, none, target);
    }
    pub fn jumpIfTrue(target: u32, test_op: Operand) Inst {
        return Inst.primaryWide(.jump, Jump.if_true, test_op, target);
    }
    pub fn jumpIfFalse(target: u32, test_op: Operand) Inst {
        return Inst.primaryWide(.jump, Jump.if_false, test_op, target);
    }
    pub fn closureMake(w: u32, dst: u12) Inst {
        return Inst.primaryWide(.closure, Closure_.make, s(dst), w);
    }
    pub fn closureBoxLocal(slot: u12) Inst {
        return Inst.primary(.closure, Closure_.box_local, s(slot), none, none);
    }
    pub fn closureGetCell(dst: u12, cell: u12) Inst {
        return Inst.primary(.closure, Closure_.get_cell, s(dst), s(cell), none);
    }
    pub fn closureNewCell(slot: u12) Inst {
        return Inst.primary(.closure, Closure_.new_cell, s(slot), none, none);
    }
    pub fn closureInitCell(cell: u12, value: Operand) Inst {
        return Inst.primary(.closure, Closure_.init_cell, s(cell), value, none);
    }
    pub fn callCall(base: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(.call, Call.call, s(base), s(argc), s(dst));
    }
    pub fn callSelf(window: u12, argc: u12, dst: u12) Inst {
        return Inst.primary(.call, Call.self_, s(window), s(argc), s(dst));
    }
    pub fn callLookup(dst: u12, target: Operand, key: u12) Inst {
        return Inst.primary(.call, Call.lookup, s(dst), target, Operand.constant(key));
    }
    pub fn callLookupOr(dst: u12, pair: u12, key: u12) Inst {
        return Inst.primary(.call, Call.lookup_or, s(dst), s(pair), Operand.constant(key));
    }
};

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

const repeat = string_mod.repeat;

test "Inst size: exactly 64 bits packed" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(Inst));
    try testing.expectEqual(@as(usize, 2), @sizeOf(Operand));
}

test "Operand helpers build the right bits" {
    const s = Operand.slot(7);
    try testing.expectEqual(OpKind.slot, s.kind);
    try testing.expectEqual(@as(u12, 7), s.index);

    const c = Operand.constant(42);
    try testing.expectEqual(OpKind.constant, c.kind);
    try testing.expectEqual(@as(u12, 42), c.index);
}

test "VM frames: a VM starts on one frame over its routine's slots, nil" {
    const routine = makeRoutine(&.{asm_.returnNil()}, &.{}, 5, "init-shape");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectEqual(@as(usize, 5), vm.stack.items.len);
    try testing.expectEqual(@as(usize, 1), vm.frames.items.len);
    try testing.expectEqual(@as(u32, 0), vm.frames.items[0].base_slot);
    for (vm.stack.items) |v| try testing.expect(v.isNil());
    try testing.expectEqual(&vm.stack.items[4], try vm.slotPtrIn(vm.currentFrame(), 4));
    try testing.expectError(VmError.OperandOutOfRange, vm.slotPtrIn(vm.currentFrame(), 5));
}

/// One hand-assembled routine and what running it on a fresh VM
/// yields.
const RunCase = struct {
    name: []const u8,
    code: []const Inst,
    consts: []const Value = &.{},
    tries: []const Try = &.{},
    caps: []const CaptureDescriptor = &.{},
    /// The Var table: a fresh Var each, with a root and a binding in
    /// force where given.
    vars: []const struct { root: ?Value = null, binding: ?Value = null } = &.{},
    slots: u16 = 1,
    want: union(enum) {
        /// The result, by `dispatch.equal`.
        value: Value,
        /// An integer result in decimal (the bignum promotions).
        decimal: []const u8,
        /// A list of these fixnums.
        list: []const i64,
        /// A value of this kind: a closure, a cell.
        kind: value_mod.Kind,
        /// The Var at this index of the table.
        var_at: usize,
        err: VmError,
        /// An uncaught throw of this value.
        thrown: Value,
    },
};

fn expectRuns(cases: []const RunCase) !void {
    for (cases) |case| {
        errdefer std.debug.print("run case \"{s}\" failed\n", .{case.name});
        var routine = makeRoutine(case.code, case.consts, case.slots, case.name);
        routine.tries = case.tries;
        routine.capture_descs = case.caps;
        var vm = try VM.init(testing.allocator, &routine);
        defer vm.deinit();
        var vars: [4]*Var = undefined;
        for (case.vars, vars[0..case.vars.len], 0..) |init, *v, i| {
            v.* = try vm.ensureNamespace().intern(&.{'a' + @as(u8, @intCast(i))});
            if (init.root) |root| {
                v.*.root = root;
                v.*.bound = true;
            }
            if (init.binding) |b| {
                v.*.thread_value = b;
                v.*.thread_bound = true;
            }
        }
        routine.var_table = vars[0..case.vars.len];
        switch (case.want) {
            .err => |e| {
                try testing.expectError(e, vm.run());
                continue;
            },
            .thrown => |v| {
                try testing.expectError(VmError.UncaughtThrow, vm.run());
                try testing.expect(dispatch_mod.equal(v, vm.unhandled_throw.?));
                continue;
            },
            .value => |v| try testing.expect(dispatch_mod.equal(v, try vm.run())),
            .decimal => |d| try expectDecimal(d, try vm.run()),
            .kind => |k| try testing.expectEqual(k, (try vm.run()).kind()),
            .var_at => |i| try testing.expectEqual(vars[i], VM.asVar(try vm.run())),
            .list => |xs| {
                var cur = try vm.run();
                for (xs) |x| {
                    try testing.expect(cur.kind() == .list and !list_mod.isEmpty(cur));
                    try testing.expectEqual(x, list_mod.head(cur).asFixnum());
                    cur = list_mod.tail(cur);
                }
                try testing.expect(list_mod.isEmpty(cur));
            },
        }
        // A run that returns leaves no handler, continuation or
        // frame behind.
        try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
        try testing.expectEqual(@as(usize, 0), vm.finally_stack.items.len);
        try testing.expectEqual(@as(usize, 1), vm.frames.items.len);
    }
}

const nil_v = value_mod.nilValue();
const true_v = value_mod.fromBool(true);
const false_v = value_mod.fromBool(false);
const sl = Operand.slot;
const kn = Operand.constant;

fn raw(g: Group, variant: u6, a: Operand, b: Operand, c: Operand) Inst {
    return .{ .kind = .primary, .group = @backingInt(g), .variant = variant, .a = a, .b = b, .c = c };
}

/// The instruction of quickened variant `q` of group `g`.
fn quickInst(g: Group, q: Quick, a: Operand, b: Operand, c: Operand) Inst {
    return raw(g, Quick.variant(g, q).?, a, b, c);
}

test "SourceInfo.lineCol: columns count code points, past a byte-order mark" {
    const info = SourceInfo{ .path = "t.nx", .text = "(str \"\u{e9}\u{e9}\u{e9}\u{e9}\" (/ 1 0))\n\u{20ac}x" };
    try testing.expectEqual(SourceInfo.LineCol{ .line = 1, .col = 13 }, info.lineCol(16));
    try testing.expectEqual(SourceInfo.LineCol{ .line = 2, .col = 2 }, info.lineCol(@intCast(info.text.len - 1)));
    try testing.expectEqual(SourceInfo.LineCol{ .line = 2, .col = 3 }, info.lineCol(1000));
    const marked = SourceInfo{ .path = "t.nx", .text = "\xEF\xBB\xBF(x)" };
    try testing.expectEqual(SourceInfo.LineCol{ .line = 1, .col = 1 }, marked.lineCol(3));
}

test "SourceInfo.lineColFrom: a place found from any other is the place found from the start" {
    const texts = [_][]const u8{
        "\xEF\xBB\xBF(a \"\u{e9}\u{20ac}\")\r\n  (b\n\n\u{1F600} c)\n",
        "(str \"\u{e9}\u{e9}\") (x)\n\u{20ac}x",
        "\n\n\n",
        "\xEF\xBB\xBF",
        "",
    };
    for (texts) |text| {
        const info = SourceInfo{ .path = "t.nx", .text = text };
        const end: u32 = @intCast(text.len + 2);
        for (0..end) |a| for (0..end) |b| {
            const from: u32 = @intCast(a);
            const to: u32 = @intCast(b);
            try testing.expectEqual(info.lineCol(to), info.lineColFrom(from, info.lineCol(from), to));
        };
    }
}

test "VM opcodes: mov, return and operand resolution" {
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "load-nil", .code = &.{ asm_.loadNil(0), asm_.returnSlot(0) }, .want = .{ .value = nil_v } },
        .{ .name = "load-true", .code = &.{ asm_.loadTrue(0), asm_.returnSlot(0) }, .want = .{ .value = true_v } },
        .{ .name = "load-false", .code = &.{ asm_.loadFalse(0), asm_.returnSlot(0) }, .want = .{ .value = false_v } },
        .{ .name = "load-const", .code = &.{ asm_.loadConst(0, 0), asm_.returnSlot(0) }, .consts = &.{fx(12345)}, .want = .{ .value = fx(12345) } },
        .{ .name = "move copies a slot", .code = &.{ asm_.loadConst(0, 0), asm_.move(1, 0), asm_.returnSlot(1) }, .consts = &.{fx(77)}, .slots = 2, .want = .{ .value = fx(77) } },
        .{ .name = "multi-step round trip through slots", .code = &.{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), asm_.loadConst(2, 2), asm_.move(3, 1), asm_.returnSlot(3) }, .consts = &.{ fx(10), fx(20), fx(30) }, .slots = 4, .want = .{ .value = fx(20) } },
        .{ .name = "move-clear moves a slot", .code = &.{ asm_.loadConst(0, 0), asm_.moveClear(1, 0), asm_.returnSlot(1) }, .consts = &.{fx(77)}, .slots = 2, .want = .{ .value = fx(77) } },
        .{ .name = "move-clear leaves nil behind", .code = &.{ asm_.loadConst(0, 0), asm_.moveClear(1, 0), asm_.returnSlot(0) }, .consts = &.{fx(77)}, .slots = 2, .want = .{ .value = nil_v } },
        .{ .name = "move-clear of a slot onto itself is a move", .code = &.{ asm_.loadConst(0, 0), asm_.moveClear(0, 0), asm_.returnSlot(0) }, .consts = &.{fx(77)}, .want = .{ .value = fx(77) } },
        .{ .name = "return-nil reads no slot", .code = &.{asm_.returnNil()}, .slots = 0, .want = .{ .value = nil_v } },
        .{ .name = "slot out of range", .code = &.{asm_.returnSlot(5)}, .want = .{ .err = VmError.OperandOutOfRange } },
        .{ .name = "constant out of range", .code = &.{ asm_.loadConst(0, 9), asm_.returnSlot(0) }, .want = .{ .err = VmError.OperandOutOfRange } },
        .{ .name = "resolve of an unused operand", .code = &.{ raw(.mov, @backingInt(Mov.move), sl(0), Operand.none, Operand.none), asm_.returnNil() }, .want = .{ .err = VmError.InvalidOperandKind } },
        .{ .name = "no return: bytecode exhausted", .code = &.{asm_.loadNil(0)}, .want = .{ .err = VmError.BytecodeExhausted } },
        .{ .name = "known group with no variants", .code = &.{ raw(.transient, 0, sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.UnimplementedOpcode } },
        .{ .name = "unrecognized group 60", .code = &.{ .{ .kind = .primary, .group = 60, .variant = 0, .a = Operand.none, .b = Operand.none, .c = Operand.none }, asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "call:call on a fixnum", .code = &.{ asm_.loadConst(0, 0), asm_.callCall(0, 0, 1), asm_.returnSlot(1) }, .consts = &.{fx(42)}, .slots = 2, .want = .{ .err = VmError.NotCallable } },
        // The index is 32 bits: its high half is not ignored.
        .{ .name = "constant index past 65,535", .code = &.{ asm_.loadConst(0, 0x1_0000), asm_.returnSlot(0) }, .consts = &.{fx(1)}, .want = .{ .err = VmError.OperandOutOfRange } },
        .{ .name = "an instruction of an unassigned kind", .code = &.{ .{ .kind = @fromBackingInt(@intCast(1)), .group = 0, .variant = 0, .a = Operand.none, .b = Operand.none, .c = Operand.none }, asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
    });
}

test "VM opcodes: coll" {
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "empty list", .code = &.{ asm_.coll(.list, 0, 0, 0), asm_.returnSlot(0) }, .want = .{ .list = &.{} } },
        .{ .name = "list of three", .code = &.{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), asm_.loadConst(2, 2), asm_.coll(.list, 0, 3, 3), asm_.returnSlot(3) }, .consts = &.{ fx(1), fx(2), fx(3) }, .slots = 4, .want = .{ .list = &.{ 1, 2, 3 } } },
        .{ .name = "empty concat", .code = &.{ asm_.coll(.concat, 0, 0, 0), asm_.returnSlot(0) }, .want = .{ .list = &.{} } },
        .{ .name = "concat (1 2) (3)", .code = &.{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), asm_.loadConst(2, 2), asm_.coll(.list, 0, 2, 3), asm_.coll(.list, 2, 1, 4), asm_.coll(.concat, 3, 2, 5), asm_.returnSlot(5) }, .consts = &.{ fx(1), fx(2), fx(3) }, .slots = 6, .want = .{ .list = &.{ 1, 2, 3 } } },
        .{ .name = "concat (1 2) [3] nil", .code = &.{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), asm_.loadConst(2, 2), asm_.coll(.list, 0, 2, 3), asm_.coll(.vector, 2, 1, 4), asm_.loadNil(5), asm_.coll(.concat, 3, 3, 6), asm_.returnSlot(6) }, .consts = &.{ fx(1), fx(2), fx(3) }, .slots = 7, .want = .{ .list = &.{ 1, 2, 3 } } },
        .{ .name = "concat of a non-seqable", .code = &.{ asm_.loadConst(0, 0), asm_.coll(.concat, 0, 1, 1), asm_.returnSlot(1) }, .consts = &.{fx(99)}, .slots = 2, .want = .{ .err = VmError.KindMismatch } },
        .{ .name = "odd map argc", .code = &.{ asm_.coll(.map, 0, 1, 0), asm_.returnSlot(0) }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "args past the frame", .code = &.{ asm_.coll(.vector, 0, 2, 0), asm_.returnSlot(0) }, .want = .{ .err = VmError.OperandOutOfRange } },
    });
}

test "VM opcodes: coll:map and coll:set keep the first key and the last value" {
    // {1 :a 2 :b 1 :c} is {1 :c 2 :b}, in association order; #{3 1 3}
    // is #{3 1}.
    var vm = try VM.init(testing.allocator, &VM.idle_routine);
    defer vm.deinit();
    const kw = vm.ensureInterner();
    const a = try kw.internKeywordValue("a");
    const b = try kw.internKeywordValue("b");
    const c = try kw.internKeywordValue("c");
    const consts = [_]Value{ fx(1), a, fx(2), b, c, fx(3) };
    const code = [_]Inst{
        asm_.loadConst(0, 0), asm_.loadConst(1, 1), asm_.loadConst(2, 2),     asm_.loadConst(3, 3),
        asm_.loadConst(4, 0), asm_.loadConst(5, 4), asm_.coll(.map, 0, 6, 6), asm_.loadConst(0, 5),
        asm_.loadConst(1, 0), asm_.loadConst(2, 5), asm_.coll(.set, 0, 3, 7), asm_.coll(.vector, 6, 2, 0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 8, "coll-dupes");
    try vm.retargetTop(&routine);
    const result = try vm.run();
    const m = vector_mod.nth(result, 0);
    try testing.expectEqual(@as(usize, 2), champ_mod.mapCount(m));
    var it = champ_mod.mapIter(m);
    const first = it.next().?;
    try testing.expectEqual(@as(i64, 1), first.key.asFixnum());
    try testing.expect(first.value.identicalTo(c));
    const second = it.next().?;
    try testing.expectEqual(@as(i64, 2), second.key.asFixnum());
    try testing.expect(second.value.identicalTo(b));
    const set = vector_mod.nth(result, 1);
    try testing.expectEqual(@as(usize, 2), champ_mod.setCount(set));
    var sit = champ_mod.setIter(set);
    try testing.expectEqual(@as(i64, 3), sit.next().?.asFixnum());
    try testing.expectEqual(@as(i64, 1), sit.next().?.asFixnum());
}

test "VM opcodes: math and cmp" {
    const add = asm_.mathAdd;
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "(+ 1 2) from constants", .code = &.{ add(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2) }, .want = .{ .value = fx(3) } },
        .{ .name = "(+ 10 32) from slots", .code = &.{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), add(2, sl(0), sl(1)), asm_.returnSlot(2) }, .consts = &.{ fx(10), fx(32) }, .slots = 3, .want = .{ .value = fx(42) } },
        .{ .name = "(+ -7 -5)", .code = &.{ add(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(-7), fx(-5) }, .want = .{ .value = fx(-12) } },
        .{ .name = "a sum past i48 promotes", .code = &.{ add(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(value_mod.fixnum_max), fx(1) }, .want = .{ .decimal = "140737488355328" } },
        .{ .name = "a sum below i48 promotes", .code = &.{ add(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(value_mod.fixnum_min), fx(-1) }, .want = .{ .decimal = "-140737488355329" } },
        .{ .name = "a float operand is contagious", .code = &.{ add(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fl(1.5), fx(2) }, .want = .{ .value = fl(3.5) } },
        .{ .name = "a non-numeric operand", .code = &.{ add(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ true_v, fx(2) }, .want = .{ .err = VmError.KindMismatch } },
        // Both sources are read before the destination is written.
        .{ .name = "dst aliases lhs", .code = &.{ asm_.loadConst(0, 0), add(0, sl(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(40) }, .want = .{ .value = fx(41) } },
        .{ .name = "dst aliases rhs", .code = &.{ asm_.loadConst(0, 1), add(0, kn(0), sl(0)), asm_.returnSlot(0) }, .consts = &.{ fx(40), fx(1) }, .want = .{ .value = fx(41) } },
        .{ .name = "slot+const and const+slot", .code = &.{ asm_.loadConst(0, 0), add(1, sl(0), kn(0)), add(2, kn(0), sl(1)), asm_.returnSlot(2) }, .consts = &.{fx(100)}, .slots = 3, .want = .{ .value = fx(300) } },
        .{ .name = "a constant destination", .code = &.{ raw(.math, @backingInt(Math.add), kn(0), kn(0), kn(1)), asm_.returnNil() }, .consts = &.{ fx(1), fx(2) }, .want = .{ .err = VmError.InvalidOperandKind } },
        .{ .name = "math:pow is reserved", .code = &.{ raw(.math, @backingInt(Math.pow), sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.UnimplementedOpcode } },
        .{ .name = "math:pow traps before its operands are read", .code = &.{ raw(.math, @backingInt(Math.pow), sl(0), Operand.none, Operand.none), asm_.returnNil() }, .want = .{ .err = VmError.UnimplementedOpcode } },
        .{ .name = "math 15", .code = &.{ raw(.math, 15, sl(0), Operand.none, Operand.none), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "1 < 2", .code = &.{ asm_.cmpLt(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2) }, .want = .{ .value = true_v } },
        .{ .name = "2 < 1", .code = &.{ asm_.cmpLt(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(2), fx(1) }, .want = .{ .value = false_v } },
        .{ .name = "2 < 2 is strict", .code = &.{ asm_.cmpLt(0, kn(0), kn(0)), asm_.returnSlot(0) }, .consts = &.{fx(2)}, .want = .{ .value = false_v } },
        .{ .name = "-5 < 3", .code = &.{ asm_.cmpLt(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(-5), fx(3) }, .want = .{ .value = true_v } },
        .{ .name = "true < 1", .code = &.{ asm_.loadTrue(0), asm_.loadConst(1, 0), asm_.cmpLt(2, sl(0), sl(1)), asm_.returnSlot(2) }, .consts = &.{fx(1)}, .slots = 3, .want = .{ .err = VmError.KindMismatch } },
        .{ .name = "cmp into a constant", .code = &.{ raw(.cmp, @backingInt(Cmp.lt), kn(0), kn(0), kn(0)), asm_.returnNil() }, .consts = &.{fx(1)}, .want = .{ .err = VmError.InvalidOperandKind } },
        .{ .name = "cmp variant 9", .code = &.{ raw(.cmp, 9, sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
    });
}

test "VM opcodes: jump" {
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "jmp skips an instruction", .code = &.{ asm_.loadConst(0, 0), asm_.jumpJmp(3), asm_.loadConst(0, 1), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(99) }, .want = .{ .value = fx(1) } },
        .{ .name = "if-false branches on nil", .code = &.{ asm_.loadNil(0), asm_.jumpIfFalse(3, sl(0)), asm_.returnNil(), asm_.loadTrue(0), asm_.returnSlot(0) }, .want = .{ .value = true_v } },
        .{ .name = "if-false branches on false", .code = &.{ asm_.loadFalse(0), asm_.jumpIfFalse(3, sl(0)), asm_.returnNil(), asm_.loadTrue(0), asm_.returnSlot(0) }, .want = .{ .value = true_v } },
        .{ .name = "if-false falls through on true", .code = &.{ asm_.loadTrue(0), asm_.jumpIfFalse(3, sl(0)), asm_.returnSlot(0), asm_.loadNil(0), asm_.returnSlot(0) }, .want = .{ .value = true_v } },
        // 0 is truthy (SEMANTICS.md §1).
        .{ .name = "if-false falls through on 0", .code = &.{ asm_.loadConst(0, 0), asm_.jumpIfFalse(3, sl(0)), asm_.returnSlot(0), asm_.loadNil(0), asm_.returnSlot(0) }, .consts = &.{fx(0)}, .want = .{ .value = fx(0) } },
        .{ .name = "if-false on a constant test", .code = &.{ asm_.jumpIfFalse(3, kn(0)), asm_.returnNil(), asm_.returnNil(), asm_.loadTrue(0), asm_.returnSlot(0) }, .consts = &.{false_v}, .want = .{ .value = true_v } },
        .{ .name = "if-true branches on true", .code = &.{ asm_.loadTrue(0), asm_.jumpIfTrue(3, sl(0)), asm_.returnNil(), asm_.loadFalse(0), asm_.returnSlot(0) }, .want = .{ .value = false_v } },
        .{ .name = "if-true falls through on nil", .code = &.{ asm_.loadNil(0), asm_.jumpIfTrue(3, sl(0)), asm_.returnSlot(0), asm_.loadTrue(0), asm_.returnSlot(0) }, .want = .{ .value = nil_v } },
        // pc is past the jump before it runs, so a jump not taken
        // falls through instead of looping on itself.
        .{ .name = "a jump to itself not taken", .code = &.{ asm_.loadFalse(0), asm_.jumpIfTrue(1, sl(0)), asm_.returnSlot(0) }, .want = .{ .value = false_v } },
        .{ .name = "target past the code", .code = &.{ asm_.jumpJmp(5), asm_.returnNil() }, .want = .{ .err = VmError.OperandOutOfRange } },
        .{ .name = "target at the code's end", .code = &.{ asm_.jumpJmp(2), asm_.returnNil() }, .want = .{ .err = VmError.OperandOutOfRange } },
        // The target is 32 bits: its high half is not ignored, and
        // the compiler's unpatched placeholder fails cleanly.
        .{ .name = "target past 65,535", .code = &.{ asm_.jumpJmp(0x1_0001), asm_.returnNil() }, .want = .{ .err = VmError.OperandOutOfRange } },
        .{ .name = "placeholder target", .code = &.{ asm_.jumpIfFalse(std.math.maxInt(u32), kn(0)), asm_.returnNil() }, .consts = &.{nil_v}, .want = .{ .err = VmError.OperandOutOfRange } },
    });
}

test "VM dispatch: a variant outside its group's enum" {
    const none = Operand.none;
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "mov 9", .code = &.{ raw(.mov, 9, sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "call:tailcall", .code = &.{ raw(.call, @backingInt(Call.tailcall), sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.UnimplementedOpcode } },
        .{ .name = "call 9", .code = &.{ raw(.call, 9, sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "jump 9", .code = &.{ raw(.jump, 9, sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "math 20", .code = &.{ raw(.math, 20, sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "var 9", .code = &.{ raw(.var_, 9, sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "closure 9", .code = &.{ raw(.closure, 9, sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "coll 9", .code = &.{ raw(.coll, 9, sl(0), sl(0), sl(0)), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "ctrl 4", .code = &.{ raw(.ctrl, 4, sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.BytecodeCorruption } },
        .{ .name = "ctrl:halt", .code = &.{ raw(.ctrl, @backingInt(CtrlOp.halt_), sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.UnimplementedOpcode } },
        .{ .name = "simd 0", .code = &.{ raw(.simd, 0, sl(0), none, none), asm_.returnNil() }, .want = .{ .err = VmError.UnimplementedOpcode } },
    });
}

test "VM dispatch: a comparison and the conditional jump on its slot" {
    const lt = asm_.cmpLt;
    try expectRuns(comptime &[_]RunCase{
        // (if (< 1 2) 10 20), and the pair not taken.
        .{ .name = "if-false not taken", .code = &.{ lt(0, kn(0), kn(1)), asm_.jumpIfFalse(3, sl(0)), asm_.returnSlot(0), asm_.loadConst(0, 2), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2), fx(20) }, .want = .{ .value = true_v } },
        .{ .name = "if-false taken", .code = &.{ lt(0, kn(1), kn(0)), asm_.jumpIfFalse(3, sl(0)), asm_.returnSlot(0), asm_.loadConst(0, 2), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2), fx(20) }, .want = .{ .value = fx(20) } },
        .{ .name = "if-true taken", .code = &.{ lt(0, kn(0), kn(1)), asm_.jumpIfTrue(3, sl(0)), asm_.returnSlot(0), asm_.loadConst(0, 2), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2), fx(20) }, .want = .{ .value = fx(20) } },
        .{ .name = "if-true not taken", .code = &.{ lt(0, kn(1), kn(0)), asm_.jumpIfTrue(3, sl(0)), asm_.returnSlot(0), asm_.loadConst(0, 2), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2), fx(20) }, .want = .{ .value = false_v } },
        // A loop tested at its bottom, as a `recur` that repeats its
        // loop's test lowers: the branch taken goes back.
        .{ .name = "a branch back while it holds", .code = &.{ asm_.loadConst(0, 0), asm_.mathAdd(0, sl(0), kn(1)), lt(1, sl(0), kn(2)), asm_.jumpIfTrue(1, sl(1)), asm_.returnSlot(0) }, .consts = &.{ fx(0), fx(1), fx(5) }, .slots = 2, .want = .{ .value = fx(5) } },
        // The jump taken still leaves the comparison in its slot.
        .{ .name = "the slot keeps the boolean", .code = &.{ lt(0, kn(0), kn(1)), asm_.jumpIfTrue(2, sl(0)), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2) }, .want = .{ .value = true_v } },
        // Floats compare through the tower, then branch the same way.
        .{ .name = "float operands", .code = &.{ lt(0, kn(0), kn(1)), asm_.jumpIfFalse(3, sl(0)), asm_.returnSlot(0), asm_.loadConst(0, 2), asm_.returnSlot(0) }, .consts = &.{ fl(2.5), fx(2), fx(20) }, .want = .{ .value = fx(20) } },
        // A jump testing another slot tests that slot.
        .{ .name = "a jump on another slot", .code = &.{ asm_.loadNil(1), lt(0, kn(0), kn(1)), asm_.jumpIfFalse(4, sl(1)), asm_.returnSlot(0), asm_.loadConst(0, 2), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2), fx(20) }, .slots = 2, .want = .{ .value = fx(20) } },
        .{ .name = "a comparison ending the code", .code = &.{lt(0, kn(0), kn(1))}, .consts = &.{ fx(1), fx(2) }, .want = .{ .err = VmError.BytecodeExhausted } },
        .{ .name = "the jump's target past the code", .code = &.{ lt(0, kn(1), kn(0)), asm_.jumpIfFalse(9, sl(0)), asm_.returnSlot(0) }, .consts = &.{ fx(1), fx(2) }, .want = .{ .err = VmError.OperandOutOfRange } },
        .{ .name = "a non-number before the jump", .code = &.{ lt(0, kn(0), kn(1)), asm_.jumpIfFalse(2, sl(0)), asm_.returnSlot(0) }, .consts = &.{ true_v, fx(2) }, .want = .{ .err = VmError.KindMismatch } },
    });
}

test "VM dispatch: a trap in a fused pair names its own instruction" {
    // The jump's target is past the code: the trace names the jump
    // (pc 1), not the comparison it ran with.
    const bad_jump = [_]Inst{ asm_.cmpLt(0, kn(1), kn(0)), asm_.jumpIfFalse(9, sl(0)), asm_.returnSlot(0) };
    // A non-number: the trace names the comparison (pc 0).
    const bad_cmp = [_]Inst{ asm_.cmpLt(0, kn(2), kn(0)), asm_.jumpIfFalse(2, sl(0)), asm_.returnSlot(0) };
    const consts = [_]Value{ fx(1), fx(2), true_v };
    for ([_]struct { []const Inst, VmError, u32 }{
        .{ &bad_jump, VmError.OperandOutOfRange, 1 },
        .{ &bad_cmp, VmError.KindMismatch, 0 },
    }) |case| {
        const routine = makeRoutine(case[0], &consts, 1, "fused");
        var vm = try VM.init(testing.allocator, &routine);
        defer vm.deinit();
        try testing.expectError(case[1], vm.run());
        try testing.expectEqual(@as(usize, 1), vm.error_trace.items.len);
        try testing.expectEqual(case[2], vm.error_trace.items[0].pc);
    }
}

test "VM dispatch: fixnum arithmetic that leaves i48 promotes" {
    const op = struct {
        fn of(comptime m: Math) fn (u12, Operand, Operand) Inst {
            return struct {
                fn f(dst: u12, lhs: Operand, rhs: Operand) Inst {
                    return Inst.primary(.math, m, Operand.slot(dst), lhs, rhs);
                }
            }.f;
        }
    };
    const mul = op.of(.mul);
    const sub = op.of(.sub);
    const quot = op.of(.idiv);
    const mod = op.of(.mod);
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "a product past i48", .code = &.{ mul(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(value_mod.fixnum_max), fx(2) }, .want = .{ .decimal = "281474976710654" } },
        // Past i64 too: the fast path's overflow check hands it on.
        .{ .name = "a product past i64", .code = &.{ mul(0, kn(0), kn(0)), asm_.returnSlot(0) }, .consts = &.{fx(value_mod.fixnum_min)}, .want = .{ .decimal = "19807040628566084398385987584" } },
        .{ .name = "a difference below i48", .code = &.{ sub(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(value_mod.fixnum_min), fx(1) }, .want = .{ .decimal = "-140737488355329" } },
        .{ .name = "a product in range", .code = &.{ mul(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(-12), fx(12) }, .want = .{ .value = fx(-144) } },
        .{ .name = "the one quotient past i48", .code = &.{ quot(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(value_mod.fixnum_min), fx(-1) }, .want = .{ .decimal = "140737488355328" } },
        .{ .name = "a quotient truncates", .code = &.{ quot(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(-7), fx(2) }, .want = .{ .value = fx(-3) } },
        .{ .name = "a modulus takes the divisor's sign", .code = &.{ mod(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(-7), fx(2) }, .want = .{ .value = fx(1) } },
        .{ .name = "a zero divisor", .code = &.{ mod(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(7), fx(0) }, .want = .{ .err = VmError.DivideByZero } },
        .{ .name = "a zero quotient divisor", .code = &.{ quot(0, kn(0), kn(1)), asm_.returnSlot(0) }, .consts = &.{ fx(7), fx(0) }, .want = .{ .err = VmError.DivideByZero } },
    });
}

test "vmErrorToKeywordName: a catchable error's tag in kebab case, null for the rest" {
    try testing.expectEqualStrings("kind-mismatch", vmErrorToKeywordName(VmError.KindMismatch).?);
    try testing.expectEqualStrings("utf8-error", vmErrorToKeywordName(VmError.Utf8Error).?);
    try testing.expectEqualStrings("atom-re-entry", vmErrorToKeywordName(VmError.AtomReEntry).?);
    try testing.expectEqualStrings("not-a-record", vmErrorToKeywordName(VmError.NotARecord).?);
    try testing.expectEqualStrings("transient-used-after-persistent", vmErrorToKeywordName(VmError.TransientUsedAfterPersistent).?);
    try testing.expect(vmErrorToKeywordName(VmError.OutOfMemory) == null);
}

test "VM dispatch: a handler's status carries every VmError and back" {
    inline for (@typeInfo(VmError).error_set.error_names.?) |name| {
        const err = @field(VmError, name);
        const status = VM.Status.of(err);
        try testing.expect(status != .ok);
        try testing.expectEqual(err, status.err());
    }
}

test "quicken: the instructions it specializes, and those it leaves" {
    const consts = [_]Value{ fx(1), fl(1.5), true_v };
    const sub = Inst.primary(.math, Math.sub, sl(0), sl(1), kn(0));
    const div = Inst.primary(.math, Math.div, sl(0), sl(1), sl(2));
    const lte = Inst.primary(.cmp, Cmp.lte, sl(0), sl(1), kn(0));
    const Case = struct { Inst, ?Quick, ?Inst };
    for ([_]Case{
        .{ asm_.mathAdd(0, sl(1), sl(2)), .{ .base = @backingInt(Math.add), .form = .slot_slot }, null },
        .{ sub, .{ .base = @backingInt(Math.sub), .form = .slot_fixnum }, null },
        .{ asm_.cmpLt(0, sl(1), sl(2)), .{ .base = @backingInt(Cmp.lt), .form = .slot_slot }, null },
        .{ lte, .{ .base = @backingInt(Cmp.lte), .form = .slot_fixnum, .then = .if_true }, asm_.jumpIfTrue(0, sl(0)) },
        .{ lte, .{ .base = @backingInt(Cmp.lte), .form = .slot_fixnum, .then = .if_false }, asm_.jumpIfFalse(0, sl(0)) },
        .{ asm_.move(0, 1), .{ .base = @backingInt(Mov.move), .form = .slot }, null },
        .{ asm_.moveFrom(0, Operand.upvalue(0)), .{ .base = @backingInt(Mov.move), .form = .upvalue }, null },
        .{ Inst.primary(.math, Math.mul, sl(0), kn(0), sl(1)), .{ .base = @backingInt(Math.mul), .form = .fixnum_slot }, null },
        .{ asm_.returnSlot(1), .{ .base = @backingInt(Call.@"return"), .form = .slot }, null },
        // A jump testing another slot is not the comparison's.
        .{ lte, .{ .base = @backingInt(Cmp.lte), .form = .slot_fixnum }, asm_.jumpIfTrue(0, sl(1)) },
        // Left as they are: an operand of another kind, a constant not
        // a fixnum or past the pool, an opcode with no fast handler.
        .{ asm_.mathAdd(0, kn(0), kn(0)), null, null },
        .{ asm_.cmpLt(0, kn(0), sl(1)), null, null },
        .{ asm_.mathAdd(0, sl(1), kn(1)), null, null },
        .{ asm_.cmpLt(0, sl(1), kn(2)), null, null },
        .{ asm_.cmpLt(0, sl(1), kn(3)), null, null },
        .{ asm_.mathAdd(0, sl(1), Operand.varRef(0)), null, null },
        .{ asm_.moveFrom(0, kn(0)), null, null },
        .{ Inst.primary(.call, Call.@"return", kn(0), Operand.none, Operand.none), null, null },
        .{ div, null, null },
        .{ asm_.loadNil(0), null, null },
    }) |case| {
        var code = [_]Inst{ case[0], case[2] orelse asm_.returnNil() };
        quicken(&code, &consts);
        const after = code[0];
        try testing.expectEqual(@as(u64, @bitCast(case[0])) >> 16, @as(u64, @bitCast(after)) >> 16);
        try testing.expectEqual(case[1], Quick.of(VM.opIndex(after)));
        if (case[1]) |q| try testing.expectEqual(q.base, @as(u6, @truncate(Routine.baseOp(VM.opIndex(after)) >> 6)));
        // Quickening twice changes nothing more.
        quicken(&code, &consts);
        try testing.expectEqual(after, code[0]);
    }
}

test "Quick: every quickened opcode decodes to its form and back" {
    var n: usize = 0;
    for (0..4096) |op| {
        const q = Quick.of(@intCast(op)) orelse continue;
        const group: Group = @fromBackingInt(@as(u6, @truncate(op)));
        try testing.expectEqual(@as(?u6, @truncate(op >> 6)), Quick.variant(group, q));
        // The base is an opcode with a fast handler of its own.
        const base = Routine.baseOp(@intCast(op));
        try testing.expect(VM.op_table[base] != &VM.opCorrupt and VM.fast_table[base] != VM.op_table[base]);
        try testing.expect(VM.op_table[op] == &VM.opQuickened);
        n += 1;
    }
    // math: five operators in three forms and the steps, four
    // comparisons in two forms with two jumps; cmp: five in six;
    // mov:move in two and call:return in one.
    try testing.expectEqual(@as(usize, 5 * 3 + 4 * 2 * 2 + 5 * 6 + 3), n);
}

test "VM dispatch: a quickened instruction runs as its base, every case and trap" {
    // Each operator over operand pairs that take the fast handler and
    // pairs that leave it (a promotion, a zero divisor, a float, a
    // non-number), run as written and quickened: the result, or the
    // error, its detail and the instruction it names, are the same.
    const values = [_]Value{ fx(0), fx(1), fx(-7), fx(7), fx(value_mod.fixnum_max), fx(value_mod.fixnum_min), fl(2.5), true_v, nil_v };
    var quickened: usize = 0;
    // B and C slots, C a fixnum constant, B a fixnum constant.
    for (values) |x| for (values) |y| for ([_]u2{ 0, 1, 2 }) |layout| {
        if (layout == 1 and !y.isFixnum() or layout == 2 and !x.isFixnum()) continue;
        const consts = [_]Value{ x, y, fx(99) };
        const lhs = if (layout == 2) kn(0) else sl(0);
        const rhs = if (layout == 1) kn(1) else sl(1);
        var ops: [5 + 5 * 3][4]Inst = undefined;
        var k: usize = 0;
        for ([_]Math{ .add, .sub, .mul, .idiv, .mod }) |m| {
            ops[k] = .{ Inst.primary(.math, m, sl(2), lhs, rhs), asm_.returnSlot(2), asm_.returnNil(), asm_.returnNil() };
            k += 1;
        }
        // A comparison has no form for a constant B.
        if (layout != 2) for (std.meta.tags(Cmp)) |c| {
            const cmp = Inst.primary(.cmp, c, sl(2), sl(0), rhs);
            // The jump goes to pc 5 of the routine below, which loads 99.
            ops[k] = .{ cmp, asm_.returnSlot(2), asm_.returnNil(), asm_.returnNil() };
            ops[k + 1] = .{ cmp, asm_.jumpIfTrue(5, sl(2)), asm_.returnSlot(2), asm_.returnNil() };
            ops[k + 2] = .{ cmp, asm_.jumpIfFalse(5, sl(2)), asm_.returnSlot(2), asm_.returnNil() };
            k += 3;
        };
        for (ops[0..k]) |body| {
            var code = [_]Inst{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), body[0], body[1], body[2], asm_.loadConst(2, 2), asm_.returnSlot(2) };
            const plain = try StepOutcome.of(&code, &consts);
            quicken(&code, &consts);
            try testing.expect(Quick.of(VM.opIndex(code[2])) != null);
            quickened += 1;
            errdefer std.debug.print("quickened {any} of {any} and {any}\n", .{ Quick.of(VM.opIndex(code[2])), x, y });
            try StepOutcome.expectSame(plain, try StepOutcome.of(&code, &consts));
        }
    };
    try testing.expect(quickened > 1000);
}

test "Routine.verify: a quickened instruction proves what its form promises" {
    const r = asm_.returnNil();
    const consts = [_]Value{ fx(1), fl(1.5) };
    const quick = quickInst;
    const add_ss: Quick = .{ .base = @backingInt(Math.add), .form = .slot_slot };
    const add_sc: Quick = .{ .base = @backingInt(Math.add), .form = .slot_fixnum };
    const lt_then: Quick = .{ .base = @backingInt(Cmp.lt), .form = .slot_slot, .then = .if_false };
    const move_s: Quick = .{ .base = @backingInt(Mov.move), .form = .slot };
    const move_u: Quick = .{ .base = @backingInt(Mov.move), .form = .upvalue };
    const mul_cs: Quick = .{ .base = @backingInt(Math.mul), .form = .fixnum_slot };
    const return_s: Quick = .{ .base = @backingInt(Call.@"return"), .form = .slot };
    const none = Operand.none;
    const Case = struct { name: []const u8, code: []const Inst, err: ?VmError };
    for ([_]Case{
        .{ .name = "slots and a fixnum", .code = &.{ quick(.math, add_ss, sl(0), sl(0), sl(1)), quick(.math, add_sc, sl(0), sl(1), kn(0)), r }, .err = null },
        .{ .name = "a comparison and its jump", .code = &.{ quick(.cmp, lt_then, sl(0), sl(0), sl(1)), asm_.jumpIfFalse(2, sl(0)), r }, .err = null },
        .{ .name = "a move and a return of slots", .code = &.{ quick(.mov, move_s, sl(0), sl(1), none), quick(.call, return_s, sl(0), none, none) }, .err = null },
        .{ .name = "a constant where a slot is promised", .code = &.{ quick(.math, add_ss, sl(0), sl(0), kn(0)), r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a slot past the frame", .code = &.{ quick(.math, add_ss, sl(0), sl(2), sl(0)), r }, .err = VmError.OperandOutOfRange },
        .{ .name = "a constant not a fixnum", .code = &.{ quick(.math, add_sc, sl(0), sl(0), kn(1)), r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a slot where a fixnum constant is promised", .code = &.{ quick(.math, add_sc, sl(0), sl(0), sl(1)), r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a fixnum constant past the pool", .code = &.{ quick(.math, add_sc, sl(0), sl(0), kn(2)), r }, .err = VmError.OperandOutOfRange },
        .{ .name = "no jump after the comparison", .code = &.{ quick(.cmp, lt_then, sl(0), sl(0), sl(1)), asm_.loadNil(0), r }, .err = VmError.BytecodeCorruption },
        .{ .name = "the other jump", .code = &.{ quick(.cmp, lt_then, sl(0), sl(0), sl(1)), asm_.jumpIfTrue(2, sl(0)), r }, .err = VmError.BytecodeCorruption },
        .{ .name = "a jump on another slot", .code = &.{ quick(.cmp, lt_then, sl(0), sl(0), sl(1)), asm_.jumpIfFalse(2, sl(1)), r }, .err = VmError.BytecodeCorruption },
        .{ .name = "a move of a constant", .code = &.{ quick(.mov, move_s, sl(0), kn(0), none), r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a fixnum and a slot", .code = &.{ quick(.math, mul_cs, sl(0), kn(0), sl(1)), r }, .err = null },
        .{ .name = "a slot where a fixnum constant leads", .code = &.{ quick(.math, mul_cs, sl(0), sl(0), sl(1)), r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a move of an upvalue the routine has not", .code = &.{ quick(.mov, move_u, sl(0), Operand.upvalue(0), none), r }, .err = VmError.UpvalueOutOfRange },
        .{ .name = "a move of a slot where an upvalue is promised", .code = &.{ quick(.mov, move_u, sl(0), sl(0), none), r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a return of a constant", .code = &.{quick(.call, return_s, kn(0), none, none)}, .err = VmError.InvalidOperandKind },
    }) |case| {
        errdefer std.debug.print("verify case \"{s}\" failed\n", .{case.name});
        const routine = Routine{ .code = case.code, .consts = &consts, .slot_count = 2, .name = "t" };
        var failure: VerifyFailure = undefined;
        if (case.err) |err| {
            try testing.expectError(err, routine.verify(&failure));
            try testing.expectEqual(@as(u32, 0), failure.pc);
        } else try routine.verify(&failure);
    }
}

test "quicken: a counting loop's step, and the adds it leaves" {
    const consts = [_]Value{ fx(1), fx(10), fl(1.5) };
    const step = struct {
        fn of(c: NumCmp, form: Quick.Form, then: Quick.Then) Quick {
            return .{ .base = @backingInt(Math.add), .form = .slot_fixnum, .then = then, .step = .{ .cmp = c, .form = form } };
        }
    }.of;
    const cmp = struct {
        fn of(c: Cmp, b: Operand, limit: Operand) Inst {
            return Inst.primary(.cmp, c, sl(1), b, limit);
        }
    }.of;
    const add = asm_.mathAdd(0, sl(0), kn(0));
    const if_true = asm_.jumpIfTrue(0, sl(1));
    const if_false = asm_.jumpIfFalse(0, sl(1));
    const Case = struct { [3]Inst, ?Quick };
    for ([_]Case{
        .{ .{ add, cmp(.lt, sl(0), sl(2)), if_true }, step(.lt, .slot_slot, .if_true) },
        .{ .{ add, cmp(.gte, sl(0), kn(1)), if_false }, step(.gte, .slot_fixnum, .if_false) },
        .{ .{ asm_.mathAdd(0, sl(2), kn(0)), cmp(.lte, sl(0), kn(1)), if_true }, step(.lte, .slot_fixnum, .if_true) },
        .{ .{ add, cmp(.gt, sl(0), sl(0)), if_false }, step(.gt, .slot_slot, .if_false) },
        // Left an add of its own form: a comparison with no jump, of
        // another slot, of a constant not a fixnum, or `==`.
        .{ .{ add, cmp(.lt, sl(0), sl(2)), asm_.returnSlot(1) }, null },
        .{ .{ add, cmp(.lt, sl(2), sl(0)), if_true }, null },
        .{ .{ add, cmp(.lt, sl(0), kn(2)), if_true }, null },
        .{ .{ add, cmp(.eq_num, sl(0), sl(2)), if_true }, null },
        .{ .{ add, asm_.loadNil(1), if_true }, null },
        // Another operator, or an add of other kinds.
        .{ .{ Inst.primary(.math, Math.sub, sl(0), sl(0), kn(0)), cmp(.lt, sl(0), sl(2)), if_true }, null },
        .{ .{ asm_.mathAdd(0, sl(0), sl(2)), cmp(.lt, sl(0), sl(2)), if_true }, null },
        .{ .{ asm_.mathAdd(0, kn(0), sl(2)), cmp(.lt, sl(0), sl(2)), if_true }, null },
    }) |case| {
        var code = case[0] ++ [_]Inst{asm_.returnNil()};
        quicken(&code, &consts);
        var alone = case[0][1..3].* ++ [_]Inst{asm_.returnNil()};
        quicken(&alone, &consts);
        // Only the add's variant changes: the comparison and its jump
        // are quickened as they are alone, and the add keeps its
        // operands.
        try testing.expectEqualSlices(Inst, &alone, code[1..]);
        try testing.expectEqual(@as(u64, @bitCast(case[0][0])) >> 16, @as(u64, @bitCast(code[0])) >> 16);
        const q = Quick.of(VM.opIndex(code[0]));
        if (case[1]) |want| {
            try testing.expectEqual(want, q.?);
            try testing.expectEqual(VM.opcode(.math, Math.add), Routine.baseOp(VM.opIndex(code[0])));
        } else if (q) |got| try testing.expect(got.step == null);
        // Quickening twice changes nothing more.
        const once = code;
        quicken(&code, &consts);
        try testing.expectEqualSlices(Inst, &once, &code);
    }
}

test "VM dispatch: a counting loop's step runs as the add, the comparison and the jump" {
    // A step from each value by each constant, compared with each
    // limit by each operator, through either jump: run as written and
    // quickened, the result, or the error, its detail and the
    // instruction it names, are the same. The jump goes to pc 7, which
    // returns the sum; not taken, pc 5 returns the boolean.
    const fixnum_max = value_mod.fixnum_max;
    const values = [_]Value{ fx(0), fx(1), fx(-7), fx(fixnum_max), fx(value_mod.fixnum_min), fl(2.5), true_v, nil_v };
    const limits = [_]Value{ fx(0), fx(1), fx(2), fx(fixnum_max), fl(1.5), true_v };
    var steps: usize = 0;
    for (values) |x| for ([_]i64{ 1, -1, 2 }) |k| for (limits) |y| for ([_]bool{ false, true }) |constant| {
        if (constant and !y.isFixnum()) continue;
        const consts = [_]Value{ x, fx(k), y };
        const limit = if (constant) kn(2) else sl(2);
        for (std.meta.tags(Cmp)) |c| for ([_]Jump{ .if_true, .if_false }) |j| {
            var code = [_]Inst{
                asm_.loadConst(0, 0),
                asm_.loadConst(2, 2),
                asm_.mathAdd(0, sl(0), kn(1)),
                Inst.primary(.cmp, c, sl(1), sl(0), limit),
                Inst.primaryWide(.jump, j, sl(1), 7),
                asm_.returnSlot(1),
                asm_.returnNil(),
                asm_.returnSlot(0),
            };
            const plain = try StepOutcome.of(&code, &consts);
            quicken(&code, &consts);
            if (c != .eq_num) {
                try testing.expect(Quick.of(VM.opIndex(code[2])).?.step != null);
                steps += 1;
            }
            errdefer std.debug.print("step {any} from {any} by {d} against {any}\n", .{ Quick.of(VM.opIndex(code[2])), x, k, y });
            try StepOutcome.expectSame(plain, try StepOutcome.of(&code, &consts));
        };
    };
    try testing.expect(steps > 1000);
}

/// What a run of a hand-built routine came to, compared across its
/// code as written and quickened.
const StepOutcome = struct {
    value: ?Value = null,
    err: ?VmError = null,
    detail: [96]u8 = undefined,
    detail_len: usize = 0,
    pc: u32 = 0,
    span: ?SourceSpan = null,

    fn of(code: []const Inst, consts: []const Value) !StepOutcome {
        return ofRoutine(makeRoutine(code, consts, 3, "q"));
    }

    fn ofRoutine(routine: Routine) !StepOutcome {
        var vm = try VM.init(testing.allocator, &routine);
        defer vm.deinit();
        var out: StepOutcome = .{};
        const v = vm.run() catch |err| {
            out.err = err;
            out.detail_len = @min(vm.error_detail.len, out.detail.len);
            @memcpy(out.detail[0..out.detail_len], vm.error_detail[0..out.detail_len]);
            out.pc = vm.error_trace.items[0].pc;
            out.span = vm.error_trace.items[0].span;
            return out;
        };
        // A bignum lives on the VM's heap: compare it as text.
        out.value = if (v.isFixnum() or v.isFloat() or v.isBool()) v else blk: {
            var w = std.Io.Writer.fixed(&out.detail);
            try bignum_mod.formatDecimal(v, &w);
            out.detail_len = w.buffered().len;
            break :blk nil_v;
        };
        return out;
    }

    fn expectSame(a: StepOutcome, b: StepOutcome) !void {
        try testing.expectEqual(a.err, b.err);
        try testing.expectEqual(a.pc, b.pc);
        try testing.expectEqual(a.span, b.span);
        try testing.expectEqualStrings(a.detail[0..a.detail_len], b.detail[0..b.detail_len]);
        if (a.value) |v| try testing.expect(dispatch_mod.equal(v, b.value.?)) else try testing.expect(b.value == null);
    }
};

test "VM dispatch: a counting loop runs through its step to each boundary" {
    // (loop [i x] (if (< i limit) (recur (+ i k)) i)), its test at the
    // bottom: past i48, against a limit not a fixnum (a float, and a
    // bignum the routine makes, i48's top plus 3), by steps of 1, 2 and
    // -1, as written and quickened.
    const max = value_mod.fixnum_max;
    const Case = struct { x: i64, k: i64, c: Cmp, limit: Value, past: i64 = 0, want: []const u8 };
    for ([_]Case{
        .{ .x = 0, .k = 1, .c = .lt, .limit = fx(1000), .want = "1000" },
        .{ .x = 0, .k = 2, .c = .lte, .limit = fx(999), .want = "1000" },
        .{ .x = 1000, .k = -1, .c = .gt, .limit = fx(0), .want = "0" },
        .{ .x = max - 3, .k = 1, .c = .lt, .limit = fx(max), .past = 3, .want = "140737488355330" },
        .{ .x = 0, .k = 1, .c = .lt, .limit = fl(9.5), .want = "10" },
    }) |case| {
        const consts = [_]Value{ fx(case.x), fx(case.k), case.limit, fx(case.past) };
        var code = [_]Inst{
            asm_.loadConst(0, 0),
            asm_.loadConst(2, 2),
            asm_.mathAdd(2, sl(2), kn(3)),
            asm_.mathAdd(0, sl(0), kn(1)),
            Inst.primary(.cmp, case.c, sl(1), sl(0), sl(2)),
            asm_.jumpIfTrue(3, sl(1)),
            asm_.returnSlot(0),
        };
        const plain = try StepOutcome.of(&code, &consts);
        quicken(&code, &consts);
        try testing.expect(Quick.of(VM.opIndex(code[3])).?.step != null);
        const quick = try StepOutcome.of(&code, &consts);
        try StepOutcome.expectSame(plain, quick);
        var buf: [24]u8 = undefined;
        const got = if (quick.value.?.isFixnum()) try std.mem.print(&buf, "{d}", .{quick.value.?.asFixnum()}) else quick.detail[0..quick.detail_len];
        try testing.expectEqualStrings(case.want, got);
    }
}

test "VM dispatch: an error through a counting loop's step names its own instruction" {
    // (loop [i 0 n 3] (if (< i n) (recur (inc i) (if (== i 2) true n)) i)),
    // the limit or the counter a boolean on the third pass: the trace
    // names the comparison (pc 6) or the add (pc 5) and its span.
    const spans = [_]SpanEntry{
        .{ .pc = 0, .span = .{ .pos = 0, .len = 40 } },
        .{ .pc = 5, .span = .{ .pos = 20, .len = 7 } },
        .{ .pc = 6, .span = .{ .pos = 10, .len = 7 } },
        .{ .pc = 8, .span = .{ .pos = 0, .len = 40 } },
    };
    const consts = [_]Value{ fx(0), fx(3), fx(2), fx(1) };
    for ([_]struct { u12, u32, SourceSpan }{ .{ 2, 6, spans[2].span }, .{ 0, 5, spans[1].span } }) |case| {
        var code = [_]Inst{
            asm_.loadConst(0, 0),
            asm_.loadConst(2, 1),
            Inst.primary(.cmp, Cmp.eq_num, sl(1), sl(0), kn(2)),
            asm_.jumpIfFalse(5, sl(1)),
            asm_.loadTrue(case[0]),
            asm_.mathAdd(0, sl(0), kn(3)),
            asm_.cmpLt(1, sl(0), sl(2)),
            asm_.jumpIfTrue(2, sl(1)),
            asm_.returnSlot(0),
        };
        var routine = makeRoutine(&code, &consts, 3, "loop");
        routine.spans = &spans;
        const plain = try StepOutcome.ofRoutine(routine);
        quicken(&code, &consts);
        try testing.expect(Quick.of(VM.opIndex(code[5])).?.step != null);
        const quick = try StepOutcome.ofRoutine(routine);
        try StepOutcome.expectSame(plain, quick);
        try testing.expectEqual(VmError.KindMismatch, quick.err.?);
        try testing.expectEqual(case[1], quick.pc);
        try testing.expectEqual(case[2], quick.span.?);
    }
}

test "Routine.verify: a step proves the comparison it runs" {
    const r = asm_.returnNil();
    const consts = [_]Value{ fx(1), fl(1.5) };
    const quick = quickInst;
    const step: Quick = .{ .base = @backingInt(Math.add), .form = .slot_fixnum, .then = .if_true, .step = .{ .cmp = .lt, .form = .slot_slot } };
    const lt_ss: Quick = Quick.stepCmp(step).?;
    const gt: Quick = .{ .base = @backingInt(Cmp.gt), .form = .slot_slot, .then = .if_true };
    const lt_sc: Quick = .{ .base = @backingInt(Cmp.lt), .form = .slot_fixnum, .then = .if_true };
    const lt_else: Quick = .{ .base = @backingInt(Cmp.lt), .form = .slot_slot, .then = .if_false };
    const add = quick(.math, step, sl(0), sl(0), kn(0));
    const jump = asm_.jumpIfTrue(0, sl(1));
    const Case = struct { name: []const u8, code: []const Inst, err: ?VmError, pc: u32 = 0 };
    for ([_]Case{
        .{ .name = "an add, its comparison and its jump", .code = &.{ add, quick(.cmp, lt_ss, sl(1), sl(0), sl(2)), jump, r }, .err = null },
        .{ .name = "no comparison after it", .code = &.{ add, asm_.loadNil(1), jump, r }, .err = VmError.BytecodeCorruption },
        .{ .name = "the comparison not quickened", .code = &.{ add, asm_.cmpLt(1, sl(0), sl(2)), jump, r }, .err = VmError.BytecodeCorruption },
        .{ .name = "another comparison", .code = &.{ add, quick(.cmp, gt, sl(1), sl(0), sl(2)), jump, r }, .err = VmError.BytecodeCorruption },
        .{ .name = "the comparison in another form", .code = &.{ add, quick(.cmp, lt_sc, sl(1), sl(0), kn(0)), jump, r }, .err = VmError.BytecodeCorruption },
        .{ .name = "the comparison with the other jump", .code = &.{ add, quick(.cmp, lt_else, sl(1), sl(0), sl(2)), asm_.jumpIfFalse(0, sl(1)), r }, .err = VmError.BytecodeCorruption },
        .{ .name = "a comparison of another slot", .code = &.{ add, quick(.cmp, lt_ss, sl(1), sl(2), sl(0)), jump, r }, .err = VmError.BytecodeCorruption },
        .{ .name = "a slot where the step's fixnum constant is promised", .code = &.{ quick(.math, step, sl(0), sl(0), sl(1)), quick(.cmp, lt_ss, sl(1), sl(0), sl(2)), jump, r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a step's constant not a fixnum", .code = &.{ quick(.math, step, sl(0), sl(0), kn(1)), quick(.cmp, lt_ss, sl(1), sl(0), sl(2)), jump, r }, .err = VmError.InvalidOperandKind },
        .{ .name = "a step ending the code", .code = &.{add}, .err = VmError.BytecodeExhausted },
        // The comparison's own form proves its jump.
        .{ .name = "the comparison with no jump", .code = &.{ add, quick(.cmp, lt_ss, sl(1), sl(0), sl(2)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
    }) |case| {
        errdefer std.debug.print("verify case \"{s}\" failed\n", .{case.name});
        const routine = Routine{ .code = case.code, .consts = &consts, .slot_count = 3, .name = "t" };
        var failure: VerifyFailure = undefined;
        if (case.err) |err| {
            try testing.expectError(err, routine.verify(&failure));
            try testing.expectEqual(case.pc, failure.pc);
        } else try routine.verify(&failure);
    }
}

test "VM jump: targets and constants past the 16-bit range" {
    // 70,000 instructions: the jump at pc 0 lands at pc 69,997,
    // which loads constant 69,000 and returns it.
    const n = 70_000;
    const code = try testing.allocator.alloc(Inst, n);
    defer testing.allocator.free(code);
    for (code) |*inst| inst.* = asm_.returnNil();
    code[0] = asm_.jumpJmp(n - 3);
    code[n - 3] = asm_.loadConst(0, 69_000);
    code[n - 2] = asm_.jumpIfTrue(n - 1, sl(0));
    code[n - 1] = asm_.returnSlot(0);
    const consts = try testing.allocator.alloc(Value, n);
    defer testing.allocator.free(consts);
    for (consts, 0..) |*c, i| c.* = fx(@intCast(i));
    const routine = makeRoutine(code, consts, 1, "wide");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 69_000), (try vm.run()).asFixnum());
}

test "VM error detail: a sentence longer than the buffer is cut with an ellipsis, not dropped" {
    var vm = try VM.init(testing.allocator, &VM.idle_routine);
    defer vm.deinit();
    const name = repeat("é", 150);
    try testing.expectEqual(VmError.ArityMismatch, vm.arityError(name, 1, 1, 0));
    try testing.expect(std.mem.startsWith(u8, vm.error_detail, "éé"));
    try testing.expect(std.mem.endsWith(u8, vm.error_detail, "é…"));
    try testing.expect(vm.error_detail.len <= vm.detail_buf.len);
    try testing.expect(std.unicode.utf8ValidateSlice(vm.error_detail));
    // One that fits is whole.
    try testing.expectEqual(VmError.ArityMismatch, vm.arityError("f", 1, 1, 0));
    try testing.expectEqualStrings("f takes 1 argument, got 0", vm.error_detail);
}

test "VM error value: a map of tag, message and place; the bare keyword when memory is exhausted" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var vm = try VM.init(failing.allocator(), &VM.idle_routine);
    defer vm.deinit();
    const tag = try vm.ensureInterner().internKeywordValue("index-out-of-bounds");
    // Nothing more can be allocated, the map's keys not yet interned:
    // the tag alone, which a catch by `:index-out-of-bounds` takes as
    // it takes the map.
    failing.fail_index = failing.alloc_index;
    try testing.expect(vm.errorValue(tag, "a sentence", null).identicalTo(tag));
    failing.fail_index = std.math.maxInt(usize);
    const m = vm.errorValue(tag, "", null);
    try testing.expectEqualStrings("index-out-of-bounds", try caughtTag(&vm, m));
    const message = try lookup(m, try vm.ensureInterner().internKeywordValue("message"), value_mod.nilValue());
    try testing.expectEqualStrings("index out of bounds", string_mod.asBytes(message));
}

test "VM error value: a handler takes a runtime error when memory is exhausted, through a finally too" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const a = failing.allocator();
    var vm = try VM.init(a, &VM.idle_routine);
    defer vm.deinit();
    const it = vm.ensureInterner();
    const k = try it.internKeywordValue("k");
    _ = try it.internKeywordValue("kind-mismatch");
    try vm.handlers.ensureTotalCapacity(a, 4);
    // Two trys with a finally entered and left standing grow what
    // a throw through them needs; none is thrown through yet.
    const enter = [_]Inst{ asm_.tryEnter(0, 0), asm_.tryEnter(0, 0), asm_.returnNil() };
    var warm = makeRoutine(&enter, &.{}, 1, "warm");
    warm.tries = &.{.{ .catch_pc = 2, .finally_pc = 2 }};
    try vm.retargetTop(&warm);
    _ = try vm.run();
    vm.resetAfterError();
    // (try (try (+ :k 1) (catch any e (throw e)) (finally)) (catch any e e)),
    // every allocation failing from the run on: the error map is the
    // bare keyword, the throw has no origin to record, and the finally
    // resumes it into the outer catch.
    const code = [_]Inst{
        asm_.tryEnter(0, 1),
        asm_.tryEnter(1, 2),
        asm_.mathAdd(3, kn(0), kn(1)),
        asm_.tryExit(9),
        asm_.throwOp(sl(2)), // 4: inner catch
        asm_.finallyExit(), //  5: inner finally
        asm_.move(3, 1), //     6: outer catch
        asm_.tryExit(9),
        asm_.returnNil(),
        asm_.returnSlot(3), //  9
    };
    var routine = makeRoutine(&code, &.{ k, fx(1) }, 4, "oom");
    routine.tries = &.{ .{ .catch_pc = 6 }, .{ .catch_pc = 4, .finally_pc = 5 } };
    try vm.retargetTop(&routine);
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqualStrings("kind-mismatch", try caughtTag(&vm, try vm.run()));
}

test "VM ctrl: a try's finally body runs after its catch; try-enter names a try of the routine" {
    // (try (throw 7) (catch any e e) (finally <s2 := 1>)), returning
    // the list of s0 (the result), s1 (the binding) and s2.
    try expectRuns(comptime &[_]RunCase{
        .{
            .name = "catch, then finally",
            .code = &.{
                asm_.loadNil(2),
                asm_.tryEnter(0, 1), //   1
                asm_.throwOp(kn(0)), //   2
                asm_.move(0, 1), //       3: catch
                asm_.tryExit(8), //       4
                asm_.returnNil(), //      5: unreached
                asm_.loadConst(2, 1), //  6: finally
                asm_.finallyExit(), //    7
                asm_.coll(.list, 0, 3, 3), // 8
                asm_.returnSlot(3),
            },
            .consts = &.{ fx(7), fx(1) },
            .tries = &.{.{ .catch_pc = 3, .finally_pc = 6 }},
            .slots = 4,
            .want = .{ .list = &.{ 7, 7, 1 } },
        },
        .{ .name = "try index past the table", .code = &.{ asm_.tryEnter(1, 0), asm_.returnNil() }, .tries = &.{.{ .catch_pc = 1 }}, .want = .{ .err = VmError.OperandOutOfRange } },
        // (try 42 (catch any _ 99)), (try (throw 7) (catch any e e)).
        .{ .name = "try-exit with nothing thrown", .code = &.{ asm_.tryEnter(0, 1), asm_.loadConst(0, 0), asm_.tryExit(5), asm_.loadConst(0, 1), asm_.tryExit(5), asm_.returnSlot(0) }, .consts = &.{ fx(42), fx(99) }, .tries = &.{.{ .catch_pc = 3 }}, .slots = 2, .want = .{ .value = fx(42) } },
        .{ .name = "a throw caught", .code = &.{ asm_.tryEnter(0, 1), asm_.throwOp(kn(0)), asm_.move(0, 1), asm_.tryExit(4), asm_.returnSlot(0) }, .consts = &.{fx(7)}, .tries = &.{.{ .catch_pc = 2 }}, .slots = 2, .want = .{ .value = fx(7) } },
        .{ .name = "a throw with no handler", .code = &.{ asm_.throwOp(kn(0)), asm_.returnNil() }, .consts = &.{fx(13)}, .want = .{ .thrown = fx(13) } },
        // The catch body's throw passes the handler that caught the first.
        .{ .name = "a throw from the catch body", .code = &.{ asm_.tryEnter(0, 1), asm_.throwOp(kn(0)), asm_.throwOp(kn(1)), asm_.tryExit(4), asm_.returnNil() }, .consts = &.{ fx(1), fx(2) }, .tries = &.{.{ .catch_pc = 2 }}, .slots = 2, .want = .{ .thrown = fx(2) } },
    });
}

// ---- numeric tower ----

/// The tag of a value a handler took: a keyword's name, or the name
/// of an error map's `:error`.
fn caughtTag(vm: *VM, v: Value) ![]const u8 {
    const interner = vm.ensureInterner();
    const tag = if (v.kind() == .persistent_map) try lookup(v, try interner.internKeywordValue("error"), value_mod.nilValue()) else v;
    if (tag.kind() != .keyword) return error.TestUnexpectedResult;
    return interner.keywordName(tag.asKeywordId());
}

fn fx(n: i64) value_mod.Value {
    return value_mod.fromFixnum(n).?;
}

fn fl(f: f64) value_mod.Value {
    return value_mod.fromFloat(f);
}

fn expectDecimal(expected: []const u8, v: value_mod.Value) !void {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try bignum_mod.formatDecimal(v, &w.writer);
    try testing.expectEqualStrings(expected, w.written());
}

test "numeric tower: contagion, exact division and integer results" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try testing.expectEqual(@as(i64, 7), (try numAdd(h, fx(3), fx(4))).asFixnum());
    try testing.expectEqual(@as(f64, 7.5), (try numAdd(h, fx(3), fl(4.5))).asFloat());
    try testing.expectEqual(@as(f64, 7.5), (try numAdd(h, fl(3.5), fx(4))).asFloat());
    try testing.expectEqual(@as(f64, -1.0), (try numSub(h, fl(3.0), fx(4))).asFloat());
    try testing.expectEqual(@as(i64, 12), (try numMul(h, fx(3), fx(4))).asFixnum());
    try testing.expectEqual(@as(f64, 1.5), (try numMul(h, fl(0.5), fx(3))).asFloat());
    // `/` of two fixnums: exact stays fixnum, inexact is f64.
    try testing.expectEqual(@as(i64, 2), (try numDiv(h, fx(6), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, -2), (try numDiv(h, fx(6), fx(-3))).asFixnum());
    try testing.expectEqual(@as(f64, 2.5), (try numDiv(h, fx(5), fx(2))).asFloat());
    try testing.expectEqual(@as(f64, 2.5), (try numDiv(h, fl(5.0), fx(2))).asFloat());
    // A zero divisor raises whatever the kinds; a NaN operand is the
    // result first.
    try testing.expectError(VmError.DivideByZero, numDiv(h, fl(1.0), fx(0)));
    try testing.expectError(VmError.DivideByZero, numDiv(h, fx(1), fl(0.0)));
    try testing.expectError(VmError.DivideByZero, numDiv(h, fl(0.0), fl(-0.0)));
    try testing.expect(std.math.isNan((try numDiv(h, fl(std.math.nan(f64)), fx(0))).asFloat()));
    try testing.expect(std.math.isNan((try numDiv(h, fx(0), fl(std.math.nan(f64)))).asFloat()));
    // quot / rem / mod: truncated vs floored.
    try testing.expectEqual(@as(i64, -2), (try numQuot(h, fx(-7), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, -1), (try numRem(h, fx(-7), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, 2), (try numMod(h, fx(-7), fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, -2), (try numMod(h, fx(7), fx(-3))).asFixnum());
    try testing.expectEqual(@as(f64, -2.0), (try numQuot(h, fl(-7.0), fx(3))).asFloat());
    try testing.expectEqual(@as(f64, -1.0), (try numRem(h, fl(-7.0), fx(3))).asFloat());
    try testing.expectEqual(@as(f64, 2.0), (try numMod(h, fl(-7.0), fx(3))).asFloat());
    try testing.expectEqual(@as(f64, -0.5), (try numMod(h, fl(7.5), fx(-2))).asFloat());
    try testing.expectEqual(@as(f64, -1.0), (try numMod(h, fx(5), fl(-1.5))).asFloat());
    try testing.expectEqual(@as(f64, 0.0), (try numMod(h, fl(6.0), fx(-2))).asFloat());
    try testing.expectEqual(@as(i64, -3), (try numNeg(h, fx(3))).asFixnum());
    try testing.expectEqual(@as(i64, 3), (try numAbs(h, fx(-3))).asFixnum());
    try testing.expectEqual(@as(f64, 3.5), (try numAbs(h, fl(-3.5))).asFloat());
    // Nothing above left the fixnum range, so nothing touched the heap.
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "numeric tower: results that leave i48 promote and results that fit demote" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try expectDecimal("140737488355328", try numAdd(h, fx(value_mod.fixnum_max), fx(1)));
    try expectDecimal("-140737488355329", try numSub(h, fx(value_mod.fixnum_min), fx(1)));
    try expectDecimal("1152921504606846976", try numMul(h, fx(1 << 30), fx(1 << 30)));
    try expectDecimal("19807040628565802923409276929", try numMul(h, fx(value_mod.fixnum_max), fx(value_mod.fixnum_max)));
    try expectDecimal("140737488355328", try numNeg(h, fx(value_mod.fixnum_min)));
    try expectDecimal("140737488355328", try numAbs(h, fx(value_mod.fixnum_min)));
    try expectDecimal("140737488355328", try numDiv(h, fx(value_mod.fixnum_min), fx(-1)));
    try expectDecimal("140737488355328", try numQuot(h, fx(value_mod.fixnum_min), fx(-1)));
    // Back across the boundary: the reverse step is a fixnum again.
    const over = try numAdd(h, fx(value_mod.fixnum_max), fx(1));
    try testing.expect(over.kind() == .bignum);
    const back = try numSub(h, over, fx(1));
    try testing.expect(back.kind() == .fixnum);
    try testing.expectEqual(value_mod.fixnum_max, back.asFixnum());
    // Bignum × bignum, and the division family on bignums.
    const sq = try numMul(h, over, over);
    try expectDecimal("19807040628566084398385987584", sq);
    try testing.expect(dispatch_mod.equal(try numDiv(h, sq, over), over));
    try testing.expect((try numDiv(h, sq, fx(3))).isFloat());
    try testing.expectEqual(@as(i64, 0), (try numRem(h, sq, over)).asFixnum());
    try testing.expectEqual(@as(i64, 1), (try numRem(h, try numAdd(h, sq, fx(1)), over)).asFixnum());
    try testing.expect(dispatch_mod.equal(try numQuot(h, try numAdd(h, sq, fx(1)), over), over));
    const neg_sq = try numNeg(h, sq);
    try testing.expectEqual(@as(i64, -1), (try numRem(h, try numSub(h, neg_sq, fx(1)), over)).asFixnum());
    try testing.expect(dispatch_mod.equal(try numMod(h, try numSub(h, neg_sq, fx(1)), over), try numSub(h, over, fx(1))));
    try testing.expect(dispatch_mod.equal(try numAbs(h, neg_sq), sq));
    // Contagion with a bignum operand.
    try testing.expectEqual(@as(f64, 140737488355328.5), (try numAdd(h, over, fl(0.5))).asFloat());
    try testing.expectEqual(@as(f64, 70368744177664.0), (try numDiv(h, over, fl(2.0))).asFloat());
    try testing.expectError(VmError.KindMismatch, numAdd(h, over, value_mod.nilValue()));
    try testing.expectError(VmError.KindMismatch, numMod(h, value_mod.nilValue(), over));
    // The same magnitudes are fine as floats.
    const big = try numMul(h, fl(@floatFromInt(value_mod.fixnum_max)), fx(value_mod.fixnum_max));
    try testing.expect(big.isFloat());
    try testing.expect(std.math.isInf((try numMul(h, fl(1e308), fx(10))).asFloat()));
}

test "numeric tower: division by zero" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try testing.expectError(VmError.DivideByZero, numDiv(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numQuot(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numRem(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numMod(h, fx(1), fx(0)));
    try testing.expectError(VmError.DivideByZero, numQuot(h, fl(1.0), fl(0.0)));
    try testing.expectError(VmError.DivideByZero, numMod(h, fx(1), fl(0.0)));
    const over = try numAdd(h, fx(value_mod.fixnum_max), fx(1));
    try testing.expectError(VmError.DivideByZero, numDiv(h, over, fx(0)));
    try testing.expectError(VmError.DivideByZero, numQuot(h, over, fx(0)));
    try testing.expectError(VmError.DivideByZero, numMod(h, over, fx(0)));
    // A float `/` raises as an integer one does.
    try testing.expectError(VmError.DivideByZero, numDiv(h, fl(1.0), fx(0)));
    try testing.expectError(VmError.DivideByZero, numDiv(h, fx(-1), fl(0.0)));
    try testing.expectError(VmError.DivideByZero, numDiv(h, fl(0.0), fl(0.0)));
    try testing.expectError(VmError.DivideByZero, numDiv(h, over, fl(0.0)));
}

test "numeric tower: comparison across kinds and NaN" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const h = &heap;
    try testing.expect(try numCompare(.lt, fx(1), fl(1.5)));
    try testing.expect(try numCompare(.gt, fl(1.5), fx(1)));
    try testing.expect(try numCompare(.lte, fx(2), fl(2.0)));
    try testing.expect(try numCompare(.gte, fl(2.0), fx(2)));
    try testing.expect(try numCompare(.eq, fx(1), fl(1.0)));
    try testing.expect(!try numCompare(.eq, fx(1), fl(1.5)));
    try testing.expect(try numCompare(.lt, fx(value_mod.fixnum_min), fx(value_mod.fixnum_max)));
    const nan = fl(std.math.nan(f64));
    try testing.expect(!try numCompare(.lt, nan, fx(1)));
    try testing.expect(!try numCompare(.gte, nan, fx(1)));
    try testing.expect(!try numCompare(.eq, nan, nan));
    try testing.expectError(VmError.KindMismatch, numCompare(.lt, fx(1), value_mod.nilValue()));
    try testing.expectError(VmError.KindMismatch, numAdd(h, fx(1), value_mod.fromBool(true)));
    // Bignums order exactly against fixnums, floats and each other.
    const over = try numAdd(h, fx(value_mod.fixnum_max), fx(1));
    const under = try numSub(h, fx(value_mod.fixnum_min), fx(1));
    try testing.expect(try numCompare(.gt, over, fx(value_mod.fixnum_max)));
    try testing.expect(try numCompare(.lt, under, fx(value_mod.fixnum_min)));
    try testing.expect(try numCompare(.lt, under, over));
    try testing.expect(try numCompare(.eq, over, try numAdd(h, fx(1), fx(value_mod.fixnum_max))));
    try testing.expect(try numCompare(.lt, over, try numAdd(h, over, fx(1))));
    try testing.expect(try numCompare(.eq, over, fl(140737488355328.0)));
    try testing.expect(try numCompare(.gt, over, fl(1.5)));
    try testing.expect(!try numCompare(.lt, nan, over));
    try testing.expectError(VmError.KindMismatch, numCompare(.lt, over, value_mod.nilValue()));
    // Sign and extremum.
    try testing.expectEqual(std.math.Order.lt, (try numSign(fl(-0.5))).?);
    try testing.expectEqual(std.math.Order.eq, (try numSign(fl(-0.0))).?);
    try testing.expectEqual(std.math.Order.gt, (try numSign(fx(3))).?);
    try testing.expectEqual(std.math.Order.gt, (try numSign(over)).?);
    try testing.expectEqual(std.math.Order.lt, (try numSign(under)).?);
    try testing.expectEqual(@as(?std.math.Order, null), try numSign(nan));
    try testing.expectError(VmError.KindMismatch, numSign(value_mod.nilValue()));
    try testing.expectEqual(@as(i64, 4), (try numExtremum(true, fx(3), fx(4))).asFixnum());
    try testing.expectEqual(@as(f64, 4.0), (try numExtremum(true, fx(3), fl(4.0))).asFloat());
    try testing.expectEqual(@as(i64, 3), (try numExtremum(false, fx(3), fl(4.0))).asFixnum());
    try testing.expectEqual(@as(i64, 2), (try numExtremum(true, fx(2), fl(1.0))).asFixnum());
    try testing.expectEqual(@as(f64, 1.0), (try numExtremum(true, fx(1), fl(1.0))).asFloat());
    try testing.expect(std.math.isNan((try numExtremum(true, nan, fx(4))).asFloat()));
    try testing.expect(dispatch_mod.equal(try numExtremum(true, fx(4), over), over));
    try testing.expect(dispatch_mod.equal(try numExtremum(false, fx(4), over), fx(4)));
    try testing.expect(dispatch_mod.equal(try numExtremum(true, under, over), over));
    try testing.expect(dispatch_mod.equal(try numExtremum(false, under, over), under));
    const over1 = try numAdd(h, over, fx(1));
    try testing.expect(dispatch_mod.equal(try numExtremum(true, over, over1), over1));
    // Conversions.
    try testing.expect(dispatch_mod.equal(try numLong(h, over), over));
    try testing.expectEqual(@as(i64, 3), (try numLong(h, fl(3.99))).asFixnum());
    try testing.expectEqual(@as(i64, -3), (try numLong(h, fl(-3.99))).asFixnum());
    try testing.expect(dispatch_mod.equal(try numLong(h, fl(140737488355328.0)), over));
    try testing.expectError(VmError.InvalidArgument, numLong(h, nan));
    try testing.expectError(VmError.InvalidArgument, numLong(h, fl(std.math.inf(f64))));
    try testing.expectError(VmError.KindMismatch, numLong(h, value_mod.nilValue()));
    try testing.expectEqual(@as(f64, 140737488355328.0), (try numDouble(over)).asFloat());
    try testing.expectEqual(@as(f64, 3.0), (try numDouble(fx(3))).asFloat());
    try testing.expectEqual(@as(f64, 1.5), (try numDouble(fl(1.5))).asFloat());
    try testing.expectError(VmError.KindMismatch, numDouble(value_mod.fromBool(true)));
    // Parity.
    try testing.expect(try numEven(over));
    try testing.expect(!try numEven(over1));
    try testing.expect(!try numEven(under));
    try testing.expect(try numEven(fx(0)));
    try testing.expectError(VmError.KindMismatch, numEven(fl(2.0)));
}

test "callValue: keywords, maps, sets and vectors are invocable as lookups" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "lookup"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    const k = vm.ensureInterner().internKeywordValue("k") catch unreachable;
    const other = vm.ensureInterner().internKeywordValue("other") catch unreachable;
    var m = try champ_mod.mapEmpty(heap);
    m = try champ_mod.mapAssoc(heap, m, k, fx(1), &dispatch_mod.hashValue, &dispatch_mod.equal);
    var set = try champ_mod.setEmpty(heap);
    set = try champ_mod.setConj(heap, set, fx(5), &dispatch_mod.hashValue, &dispatch_mod.equal);
    const vec = try vector_mod.fromSlice(heap, &.{ fx(10), fx(20) });

    // (:k m) / (:k m default) / (:other m default) / (:k nil) / (:k 5)
    try testing.expectEqual(@as(i64, 1), (try vm.callValue(k, &.{m})).asFixnum());
    try testing.expectEqual(@as(i64, 1), (try vm.callValue(k, &.{ m, fx(9) })).asFixnum());
    try testing.expectEqual(@as(i64, 9), (try vm.callValue(other, &.{ m, fx(9) })).asFixnum());
    try testing.expect((try vm.callValue(k, &.{value_mod.nilValue()})).isNil());
    try testing.expect((try vm.callValue(k, &.{fx(5)})).isNil());
    try testing.expectError(VmError.ArityMismatch, vm.callValue(k, &.{}));
    try testing.expectError(VmError.ArityMismatch, vm.callValue(k, &.{ m, m, m }));
    // (m :k) / (m :other :d)
    try testing.expectEqual(@as(i64, 1), (try vm.callValue(m, &.{k})).asFixnum());
    try testing.expectEqual(@as(i64, 9), (try vm.callValue(m, &.{ other, fx(9) })).asFixnum());
    // (s 5) / (s 6)
    try testing.expectEqual(@as(i64, 5), (try vm.callValue(set, &.{fx(5)})).asFixnum());
    try testing.expect((try vm.callValue(set, &.{fx(6)})).isNil());
    try testing.expectError(VmError.ArityMismatch, vm.callValue(set, &.{ fx(5), fx(6) }));
    // (v 1) / (v 2) / (v :k)
    try testing.expectEqual(@as(i64, 20), (try vm.callValue(vec, &.{fx(1)})).asFixnum());
    try testing.expectError(VmError.IndexOutOfBounds, vm.callValue(vec, &.{fx(2)}));
    try testing.expectError(VmError.KindMismatch, vm.callValue(vec, &.{k}));
    // Numbers stay uncallable.
    try testing.expectError(VmError.NotCallable, vm.callValue(fx(1), &.{fx(2)}));
}

test "VM opcodes: every math and cmp variant" {
    const op = struct {
        fn of(g: Group, variant: anytype, b: Operand, c: Operand) []const Inst {
            return &.{ Inst.primary(g, variant, sl(0), b, c), asm_.returnSlot(0) };
        }
    }.of;
    const none = Operand.none;
    try expectRuns(comptime &[_]RunCase{
        .{ .name = "sub", .code = op(.math, Math.sub, kn(0), kn(1)), .consts = &.{ fx(7), fx(2) }, .want = .{ .value = fx(5) } },
        .{ .name = "mul", .code = op(.math, Math.mul, kn(0), kn(1)), .consts = &.{ fx(7), fx(2) }, .want = .{ .value = fx(14) } },
        .{ .name = "div", .code = op(.math, Math.div, kn(0), kn(1)), .consts = &.{ fx(10), fx(2) }, .want = .{ .value = fx(5) } },
        .{ .name = "idiv", .code = op(.math, Math.idiv, kn(0), kn(1)), .consts = &.{ fx(7), fx(2) }, .want = .{ .value = fx(3) } },
        .{ .name = "mod", .code = op(.math, Math.mod, kn(0), kn(1)), .consts = &.{ fx(7), fx(2) }, .want = .{ .value = fx(1) } },
        .{ .name = "neg", .code = op(.math, Math.neg, kn(0), none), .consts = &.{fx(1)}, .want = .{ .value = fx(-1) } },
        .{ .name = "abs", .code = op(.math, Math.abs, kn(0), none), .consts = &.{fx(-1)}, .want = .{ .value = fx(1) } },
        .{ .name = "lte", .code = op(.cmp, Cmp.lte, kn(0), kn(1)), .consts = &.{ fx(1), fx(2) }, .want = .{ .value = true_v } },
        .{ .name = "gt", .code = op(.cmp, Cmp.gt, kn(0), kn(1)), .consts = &.{ fx(1), fl(0.5) }, .want = .{ .value = true_v } },
        .{ .name = "gte", .code = op(.cmp, Cmp.gte, kn(0), kn(1)), .consts = &.{ fl(0.5), fx(1) }, .want = .{ .value = false_v } },
        .{ .name = "eq-num", .code = op(.cmp, Cmp.eq_num, kn(0), kn(1)), .consts = &.{ fx(5), fl(5.0) }, .want = .{ .value = true_v } },
    });
}

test "Namespace.intern makes an unbound Var once" {
    var vm = try VM.init(testing.allocator, &VM.idle_routine);
    defer vm.deinit();
    const ns = vm.ensureNamespace();
    const x = try ns.intern("x");
    try testing.expect(!x.bound and x.current() == null);
    try testing.expectEqual(x, try ns.intern("x"));
    try testing.expect(ns.lookup("y") == null);
}

test "VM opcodes: var" {
    const v = Operand.varRef;
    try expectRuns(&[_]RunCase{
        .{ .name = "load-var of a bound Var", .code = &.{ asm_.varLoadVar(0, 0), asm_.returnSlot(0) }, .vars = &.{.{ .root = fx(42) }}, .want = .{ .value = fx(42) } },
        .{ .name = "load-var of an unbound Var", .code = &.{ asm_.varLoadVar(0, 0), asm_.returnSlot(0) }, .vars = &.{.{}}, .want = .{ .err = VmError.UnboundVar } },
        .{ .name = "v operands read the binding in force, else the root", .code = &.{ asm_.mathAdd(0, v(0), v(1)), asm_.returnSlot(0) }, .vars = &.{ .{ .root = fx(40) }, .{ .root = fx(1), .binding = fx(2) } }, .want = .{ .value = fx(42) } },
        .{ .name = "a v operand of an unbound Var", .code = &.{ asm_.moveFrom(0, v(0)), asm_.returnSlot(0) }, .vars = &.{.{}}, .want = .{ .err = VmError.UnboundVar } },
        .{ .name = "store-var binds the root", .code = &.{ asm_.varStoreVar(0, kn(0)), asm_.varLoadVar(0, 0), asm_.returnSlot(0) }, .consts = &.{fx(42)}, .vars = &.{.{}}, .want = .{ .value = fx(42) } },
        // A Var's identity holds across stores; `def` is store-var
        // then var-object.
        .{ .name = "store-var twice", .code = &.{ asm_.varStoreVar(0, kn(0)), asm_.varStoreVar(0, kn(1)), asm_.varLoadVar(0, 0), asm_.returnSlot(0) }, .consts = &.{ fx(5), fx(10) }, .vars = &.{.{}}, .want = .{ .value = fx(10) } },
        .{ .name = "var-object after store-var", .code = &.{ asm_.varStoreVar(0, kn(0)), asm_.varVarObject(0, 0), asm_.returnSlot(0) }, .consts = &.{fx(42)}, .vars = &.{.{}}, .want = .{ .var_at = 0 } },
        .{ .name = "var-object of an unbound Var", .code = &.{ asm_.varVarObject(0, 0), asm_.returnSlot(0) }, .vars = &.{.{}}, .want = .{ .var_at = 0 } },
        .{ .name = "var-object binds nothing", .code = &.{ asm_.varVarObject(0, 0), asm_.varLoadVar(0, 0), asm_.returnSlot(0) }, .vars = &.{.{}}, .want = .{ .err = VmError.UnboundVar } },
    });
}

test "VM jump: setWide back-patches a target and keeps the test operand" {
    var inst = asm_.jumpIfFalse(std.math.maxInt(u32), sl(3));
    inst.setWide(70_000);
    try testing.expectEqual(@as(u32, 70_000), inst.wide());
    try testing.expectEqual(sl(3), inst.a);
    try testing.expectEqual(Group.jump, inst.groupOf());
}

test "VM opcodes: closures, cells and calls" {
    const ret42 = Routine{ .code = &.{ asm_.loadConst(0, 0), asm_.returnSlot(0) }, .consts = &.{fx(42)}, .slot_count = 1, .name = "ret42" };
    const add1 = Routine{ .code = &.{ asm_.mathAdd(1, sl(0), kn(0)), asm_.returnSlot(1) }, .consts = &.{fx(1)}, .slot_count = 2, .fixed_arity = 1, .name = "add1" };
    const add2 = Routine{ .code = &.{ asm_.mathAdd(2, sl(0), sl(1)), asm_.returnSlot(2) }, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .name = "add2" };
    // Returns a local it never wrote.
    const local = Routine{ .code = &.{asm_.returnSlot(2)}, .consts = &.{}, .slot_count = 3, .fixed_arity = 1, .name = "local" };
    // Returns its one upvalue's contents.
    const upval = Routine{ .code = &.{ asm_.moveFrom(0, Operand.upvalue(0)), asm_.returnSlot(0) }, .consts = &.{}, .slot_count = 1, .upvalue_count = 1, .name = "upval" };
    const cell_of_s0 = [_]CaptureSource{.{ .local_cell_slot = 0 }};
    const make = asm_.closureMake(0, 0);
    try expectRuns(&[_]RunCase{
        .{ .name = "closure:make", .code = &.{ make, asm_.returnSlot(0) }, .caps = &.{.{ .routine = &ret42, .sources = &.{} }}, .want = .{ .kind = .function } },
        .{ .name = "a call of none", .code = &.{ make, asm_.callCall(0, 0, 0), asm_.returnSlot(0) }, .caps = &.{.{ .routine = &ret42, .sources = &.{} }}, .want = .{ .value = fx(42) } },
        .{ .name = "a call of one", .code = &.{ make, asm_.loadConst(1, 0), asm_.callCall(0, 1, 2), asm_.returnSlot(2) }, .consts = &.{fx(5)}, .caps = &.{.{ .routine = &add1, .sources = &.{} }}, .slots = 3, .want = .{ .value = fx(6) } },
        .{ .name = "a call of two", .code = &.{ make, asm_.loadConst(1, 0), asm_.loadConst(2, 1), asm_.callCall(0, 2, 3), asm_.returnSlot(3) }, .consts = &.{ fx(3), fx(4) }, .caps = &.{.{ .routine = &add2, .sources = &.{} }}, .slots = 4, .want = .{ .value = fx(7) } },
        .{ .name = "one closure called twice", .code = &.{ make, asm_.loadConst(1, 0), asm_.callCall(0, 1, 4), asm_.loadConst(1, 1), asm_.callCall(0, 1, 5), asm_.mathAdd(6, sl(4), sl(5)), asm_.returnSlot(6) }, .consts = &.{ fx(5), fx(10) }, .caps = &.{.{ .routine = &add1, .sources = &.{} }}, .slots = 7, .want = .{ .value = fx(17) } },
        .{ .name = "too few arguments", .code = &.{ make, asm_.loadConst(1, 0), asm_.callCall(0, 1, 2), asm_.returnSlot(2) }, .consts = &.{fx(1)}, .caps = &.{.{ .routine = &add2, .sources = &.{} }}, .slots = 3, .want = .{ .err = VmError.ArityMismatch } },
        .{ .name = "too many arguments", .code = &.{ make, asm_.loadConst(1, 0), asm_.loadConst(2, 0), asm_.callCall(0, 2, 3), asm_.returnSlot(3) }, .consts = &.{fx(1)}, .caps = &.{.{ .routine = &add1, .sources = &.{} }}, .slots = 4, .want = .{ .err = VmError.ArityMismatch } },
        // The callee's window overlaps the caller's slots 2 and 3.
        .{ .name = "a callee's locals start nil", .code = &.{ asm_.loadConst(2, 0), asm_.loadConst(3, 0), make, asm_.loadConst(1, 0), asm_.callCall(0, 1, 4), asm_.returnSlot(4) }, .consts = &.{fx(99)}, .caps = &.{.{ .routine = &local, .sources = &.{} }}, .slots = 5, .want = .{ .value = nil_v } },
        .{ .name = "box-local", .code = &.{ asm_.loadConst(0, 0), asm_.closureBoxLocal(0), asm_.returnSlot(0) }, .consts = &.{fx(42)}, .want = .{ .kind = .cell_internal } },
        .{ .name = "box-local of a boxed slot", .code = &.{ asm_.loadConst(0, 0), asm_.closureBoxLocal(0), asm_.closureBoxLocal(0), asm_.returnSlot(0) }, .consts = &.{fx(7)}, .want = .{ .err = VmError.InvalidCellState } },
        .{ .name = "get-cell", .code = &.{ asm_.loadConst(0, 0), asm_.closureBoxLocal(0), asm_.closureGetCell(1, 0), asm_.returnSlot(1) }, .consts = &.{fx(99)}, .slots = 2, .want = .{ .value = fx(99) } },
        .{ .name = "get-cell of a value", .code = &.{ asm_.loadConst(0, 0), asm_.closureGetCell(1, 0), asm_.returnSlot(1) }, .consts = &.{fx(5)}, .slots = 2, .want = .{ .err = VmError.ExpectedCell } },
        // A `u` operand reads a cell's contents, never the cell.
        .{ .name = "a captured cell read through u", .code = &.{ asm_.loadConst(0, 0), asm_.closureBoxLocal(0), asm_.closureMake(0, 1), asm_.callCall(1, 0, 2), asm_.returnSlot(2) }, .consts = &.{fx(123)}, .caps = &.{.{ .routine = &upval, .sources = &cell_of_s0 }}, .slots = 3, .want = .{ .value = fx(123) } },
        .{ .name = "new-cell", .code = &.{ asm_.closureNewCell(0), asm_.returnSlot(0) }, .want = .{ .kind = .cell_internal } },
        .{ .name = "init-cell, then get-cell", .code = &.{ asm_.closureNewCell(0), asm_.closureInitCell(0, kn(0)), asm_.closureGetCell(1, 0), asm_.returnSlot(1) }, .consts = &.{fx(42)}, .slots = 2, .want = .{ .value = fx(42) } },
        .{ .name = "init-cell of a filled cell", .code = &.{ asm_.closureNewCell(0), asm_.closureInitCell(0, kn(0)), asm_.closureInitCell(0, kn(0)), asm_.returnNil() }, .consts = &.{fx(1)}, .want = .{ .err = VmError.InvalidCellState } },
        .{ .name = "init-cell of a value", .code = &.{ asm_.loadConst(0, 0), asm_.closureInitCell(0, kn(0)), asm_.returnNil() }, .consts = &.{fx(7)}, .want = .{ .err = VmError.ExpectedCell } },
        // `(fn* f [] f)`: the closure captures the placeholder cell it
        // fills, and calling it returns it.
        .{ .name = "a closure over its own cell", .code = &.{ asm_.closureNewCell(0), asm_.closureMake(0, 1), asm_.closureInitCell(0, sl(1)), asm_.callCall(1, 0, 2), asm_.returnSlot(2) }, .caps = &.{.{ .routine = &upval, .sources = &cell_of_s0 }}, .slots = 3, .want = .{ .kind = .function } },
    });
}

test "VM cells: a u operand of a placeholder cell traps, quickened or not" {
    var upval_code = [_]Inst{ asm_.moveFrom(0, Operand.upvalue(0)), asm_.returnSlot(0) };
    const upval = Routine{ .code = &upval_code, .consts = &.{}, .slot_count = 1, .upvalue_count = 1, .name = "upval" };
    const caps = [_]CaptureDescriptor{.{ .routine = &upval, .sources = &.{.{ .local_cell_slot = 0 }} }};
    var routine = makeRoutine(&.{ asm_.closureNewCell(0), asm_.closureMake(0, 1), asm_.callCall(1, 0, 2), asm_.returnSlot(2) }, &.{}, 3, "top");
    routine.capture_descs = &caps;
    // As written, then with the read quickened (`mov:move.u`, §10.10).
    for (0..2) |pass| {
        if (pass == 1) {
            quicken(&upval_code, &.{});
            try testing.expect(Quick.of(VM.opIndex(upval_code[0])).?.form == .upvalue);
        }
        var vm = try VM.init(testing.allocator, &routine);
        defer vm.deinit();
        try testing.expectError(VmError.UninitializedCell, vm.run());
        try testing.expectEqual(@as(u32, 0), vm.error_trace.items[0].pc);
    }
}

test "VM dispatch: calls and closures under a collection every few kilobytes" {
    // A closure over a boxed 1, made and called 500 times: each
    // iteration allocates a closure, so the stress policy collects
    // between calls, and the cell, the closures in flight and the
    // frames must all survive it.
    const child_code = [_]Inst{ asm_.mathAdd(1, sl(0), Operand.upvalue(0)), asm_.returnSlot(1) };
    const child = Routine{ .code = &child_code, .consts = &.{}, .slot_count = 2, .fixed_arity = 1, .upvalue_count = 1 };
    const caps = [_]CaptureDescriptor{.{ .routine = &child, .sources = &[_]CaptureSource{.{ .local_cell_slot = 0 }} }};
    const code = [_]Inst{
        asm_.loadConst(0, 2), // s0 = 1, boxed
        asm_.closureBoxLocal(0),
        asm_.loadConst(1, 0), // i
        asm_.loadConst(2, 0), // acc
        asm_.cmpLt(3, sl(1), kn(1)), // 4
        asm_.jumpIfFalse(12, sl(3)),
        asm_.closureMake(0, 3),
        asm_.move(4, 1),
        asm_.callCall(3, 1, 4), // s4 = i + 1
        asm_.mathAdd(2, sl(2), sl(4)),
        asm_.mathAdd(1, sl(1), kn(2)),
        asm_.jumpJmp(4),
        asm_.returnSlot(2), // 12
    };
    const consts = [_]Value{ fx(0), fx(500), fx(1) };
    var routine = makeRoutine(&code, &consts, 5, "gc-calls");
    routine.capture_descs = &caps;
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    vm.setGcPolicy(.stress);
    try testing.expectEqual(@as(i64, 125_250), (try vm.run()).asFixnum());
    try testing.expect(vm.gc_cycles > 0);
}

test "VM mov:move-clear: the slot it reads roots the value no more" {
    const natives = struct {
        fn live(vm: *VM, _: []const Value) VmError!Value {
            vm.collectGarbage();
            return fx(@intCast(vm.ensureHeap().liveCount()));
        }
        const native = NativeFn{ .name = "live", .min_arity = 0, .max_arity = 0, .call = &live };
    };
    // A vector built in s1 and moved to s2, which then drops it: only
    // s1 can still hold it when the native collects.
    var live: [2]i64 = undefined;
    for ([_]Inst{ asm_.move(2, 1), asm_.moveClear(2, 1) }, &live) |moved, *n| {
        const code = [_]Inst{
            asm_.loadConst(0, 1),
            asm_.coll(.vector, 0, 1, 1),
            moved,
            asm_.loadNil(2),
            asm_.loadConst(3, 0),
            asm_.callCall(3, 0, 4),
            asm_.returnSlot(4),
        };
        const consts = [_]Value{ nativeFnValue(&natives.native), fx(7) };
        var vm = try VM.init(testing.allocator, &makeRoutine(&code, &consts, 5, "clear"));
        defer vm.deinit();
        n.* = (try vm.run()).asFixnum();
    }
    try testing.expect(live[0] > 0);
    try testing.expectEqual(@as(i64, 0), live[1]);
}

test "GcPolicy.stress: a large live set spaces the next cycle out by its size" {
    // Collecting every 4 KiB re-marks and re-sweeps whatever is live, so
    // a program holding a large set would make the stress run quadratic.
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    vm.setGcPolicy(.stress);
    const heap = vm.ensureHeap();
    const items = try testing.allocator.alloc(Value, 100_000);
    defer testing.allocator.free(items);
    for (items, 0..) |*x, i| x.* = fx(@intCast(i));
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(try vector_mod.fromSlice(heap, items));
    vm.collectGarbage();
    try testing.expect(heap.live_bytes > 1 << 20);
    try testing.expectEqual(heap.live_bytes / 100 * GcPolicy.stress.growth_percent, vm.gc_next_at);
    try testing.expect(vm.gc_next_at > 4 * GcPolicy.stress.threshold);
}

const dispatch_test_natives = struct {
    fn boom(vm: *VM, _: []const Value) VmError!Value {
        return vm.throwKeyword("boom");
    }
    fn callArg(vm: *VM, args: []const Value) VmError!Value {
        return vm.callValue(args[0], args[1..]);
    }
    fn sub(_: *VM, args: []const Value) VmError!Value {
        return fx(args[0].asFixnum() - args[1].asFixnum());
    }
    fn refuse(_: *VM, _: []const Value) VmError!Value {
        return VmError.KindMismatch;
    }
    const native_boom = NativeFn{ .name = "boom", .min_arity = 0, .max_arity = 0, .call = &boom };
    const native_call = NativeFn{ .name = "call", .min_arity = 1, .max_arity = null, .call = &callArg };
    const native_sub = NativeFn{ .name = "sub", .min_arity = 2, .max_arity = 2, .call = &sub, .leaf = true };
    const native_refuse = NativeFn{ .name = "refuse", .min_arity = 1, .max_arity = 1, .call = &refuse, .leaf = true };
};

test "Routine.verify: the routines it refuses, each at its instruction" {
    // What the dispatch trusts once a routine is verified (§5, §8):
    // each case breaks one promise, and `run` refuses it before any
    // instruction runs, with a trace naming the instruction.
    const r = asm_.returnNil();
    const bad_kind: Inst = @bitCast(@as(u64, @bitCast(asm_.loadNil(0))) | 1);
    const child_bad = Routine{ .code = &.{ asm_.move(0, 7), r }, .consts = &.{}, .slot_count = 1, .name = "child" };
    const child_caps = [_]CaptureDescriptor{.{ .routine = &child_bad, .sources = &.{} }};
    const counted = Routine{ .code = &.{r}, .consts = &.{}, .slot_count = 1, .upvalue_count = 1, .name = "counted" };
    const counted_caps = [_]CaptureDescriptor{.{ .routine = &counted, .sources = &.{} }};
    const tries = [_]Try{.{ .catch_pc = 5 }};
    const consts = [_]Value{fx(1)};
    const keyed = [_]Value{value_mod.testKeyword(1)};
    const Case = struct { name: []const u8, code: []const Inst, slots: u16 = 2, caps: []const CaptureDescriptor = &.{}, keyed: bool = false, err: VmError, where: []const u8 = "t", pc: u32 };
    for ([_]Case{
        .{ .name = "no code", .code = &.{}, .err = VmError.BytecodeExhausted, .pc = 0 },
        .{ .name = "the code falls off its end", .code = &.{ asm_.loadNil(0), asm_.loadNil(1) }, .err = VmError.BytecodeExhausted, .pc = 1 },
        .{ .name = "a comparison ends the code", .code = &.{asm_.cmpLt(0, kn(0), kn(0))}, .err = VmError.BytecodeExhausted, .pc = 0 },
        .{ .name = "not a primary instruction", .code = &.{ bad_kind, r }, .err = VmError.BytecodeCorruption, .pc = 0 },
        .{ .name = "a jump variant outside its group", .code = &.{ r, raw(.jump, 9, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a cmp variant outside its group", .code = &.{ r, raw(.cmp, 9, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a math variant outside its group", .code = &.{ r, raw(.math, 20, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a mov variant outside its group", .code = &.{ r, raw(.mov, 9, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a call variant outside its group", .code = &.{ r, raw(.call, 9, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a closure variant outside its group", .code = &.{ r, raw(.closure, 9, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a var variant outside its group", .code = &.{ r, raw(.var_, 9, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a coll variant outside its group", .code = &.{ r, raw(.coll, 30, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a ctrl variant outside its group", .code = &.{ r, raw(.ctrl, 4, sl(0), sl(0), sl(0)), r }, .err = VmError.BytecodeCorruption, .pc = 1 },
        .{ .name = "a jump past the code", .code = &.{ asm_.jumpJmp(2), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a branch past the code", .code = &.{ asm_.jumpIfTrue(9, kn(0)), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a destination past the frame", .code = &.{ asm_.loadNil(2), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a destination not a slot", .code = &.{ asm_.moveFrom(0, sl(0)), Inst.primary(.mov, Mov.move, kn(0), sl(0), Operand.none), r }, .err = VmError.InvalidOperandKind, .pc = 1 },
        .{ .name = "a move-clear of a constant", .code = &.{ Inst.primary(.mov, Mov.move_clear, sl(0), kn(0), Operand.none), r }, .err = VmError.InvalidOperandKind, .pc = 0 },
        .{ .name = "a move-clear of a slot past the frame", .code = &.{ asm_.moveClear(0, 2), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a slot read past the frame", .code = &.{ asm_.mathAdd(0, sl(0), sl(2)), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a constant past the pool", .code = &.{ asm_.moveFrom(0, kn(1)), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a wide constant past the pool", .code = &.{ asm_.loadConst(0, 1), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a Var past the table", .code = &.{ asm_.varLoadVar(0, 0), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "an upvalue the routine has not", .code = &.{ asm_.moveFrom(0, Operand.upvalue(0)), r }, .err = VmError.UpvalueOutOfRange, .pc = 0 },
        .{ .name = "a call block past the frame", .code = &.{ asm_.callCall(0, 2, 0), r }, .err = VmError.CallBlockOutOfRange, .pc = 0 },
        .{ .name = "a self-call's arguments past the frame", .code = &.{ asm_.callSelf(1, 2, 0), r }, .err = VmError.CallBlockOutOfRange, .pc = 0 },
        .{ .name = "a self-call of a count no member of the routine's table takes", .code = &.{ asm_.callSelf(0, 1, 0), r }, .err = VmError.BytecodeCorruption, .pc = 0 },
        .{ .name = "a lookup key not a constant", .code = &.{ Inst.primary(.call, Call.lookup, sl(0), sl(0), sl(1)), r }, .err = VmError.InvalidOperandKind, .pc = 0 },
        .{ .name = "a lookup key neither keyword nor symbol", .code = &.{ asm_.callLookup(0, sl(0), 0), r }, .err = VmError.InvalidOperandKind, .pc = 0 },
        .{ .name = "a lookup key past the pool", .code = &.{ asm_.callLookup(0, sl(0), 1), r }, .keyed = true, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a lookup's target and default past the frame", .code = &.{ asm_.callLookupOr(0, 1, 0), r }, .keyed = true, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a collection block past the frame", .code = &.{ asm_.coll(.list, 1, 2, 0), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a try past the table", .code = &.{ asm_.tryEnter(1, 0), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a catch past the code", .code = &.{ r, asm_.tryEnter(0, 0), r }, .err = VmError.OperandOutOfRange, .pc = 1 },
        .{ .name = "a capture count that is not the routine's", .code = &.{ asm_.closureMake(0, 0), r }, .caps = &counted_caps, .err = VmError.CaptureCountMismatch, .pc = 0 },
        .{ .name = "a capture descriptor past the table", .code = &.{ asm_.closureMake(0, 0), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a call block's base not a slot", .code = &.{ Inst.primary(.call, Call.call, kn(0), sl(0), sl(0)), r }, .err = VmError.InvalidOperandKind, .pc = 0 },
        .{ .name = "a call's result not a slot", .code = &.{ Inst.primary(.call, Call.call, sl(0), sl(0), kn(0)), r }, .err = VmError.InvalidOperandKind, .pc = 0 },
        .{ .name = "a cell not a slot", .code = &.{ Inst.primary(.closure, Closure_.init_cell, kn(0), kn(0), Operand.none), r }, .err = VmError.InvalidOperandKind, .pc = 0 },
        .{ .name = "a v operand past the table", .code = &.{ asm_.moveFrom(0, Operand.varRef(0)), r }, .err = VmError.OperandOutOfRange, .pc = 0 },
        .{ .name = "a routine under it", .code = &.{ asm_.closureMake(0, 0), r }, .caps = &child_caps, .err = VmError.OperandOutOfRange, .where = "child", .pc = 0 },
    }) |case| {
        errdefer std.debug.print("verify case \"{s}\" failed\n", .{case.name});
        const routine = Routine{ .code = case.code, .consts = if (case.keyed) &keyed else &consts, .capture_descs = case.caps, .tries = &tries, .slot_count = case.slots, .name = "t" };
        var failure: VerifyFailure = undefined;
        try testing.expectError(case.err, routine.verify(&failure));
        try testing.expectEqualStrings(case.where, failure.routine.name);
        try testing.expectEqual(case.pc, failure.pc);
        var vm = try VM.init(testing.allocator, &routine);
        defer vm.deinit();
        try testing.expectError(case.err, vm.run());
        try testing.expectEqual(@as(usize, 1), vm.error_trace.items.len);
        try testing.expectEqual(case.pc, vm.error_trace.items[0].pc);
    }
    // A top-level routine has no upvalues to read.
    var vm = try VM.init(testing.allocator, &counted);
    defer vm.deinit();
    try testing.expectError(VmError.CaptureCountMismatch, vm.run());
}

test "Routine.verify: any routine at all passes or is refused, never a trap" {
    var failure: VerifyFailure = undefined;
    // More instructions than a pc can name: refused before any is read
    // (the slice runs far past the one instruction behind it).
    const one = [_]Inst{asm_.returnNil()};
    const huge = Routine{ .code = @as([*]const Inst, &one)[0 .. @as(usize, std.math.maxInt(u32)) + 2], .consts = &.{}, .slot_count = 1, .name = "huge" };
    try testing.expectError(VmError.BytecodeCorruption, huge.verify(&failure));
    try testing.expectEqualStrings("huge", failure.routine.name);
    // A routine whose capture builds itself, which no compiler makes:
    // `verify` descends until the stack guard stops it, `verifyAlone`
    // proves the routine itself.
    stack_guard.armIfUnarmed(stack_guard.main_thread_budget);
    var cyclic = Routine{ .code = &.{ asm_.closureMake(0, 0), asm_.returnNil() }, .consts = &.{}, .slot_count = 1, .name = "cyclic" };
    const cyclic_caps = [_]CaptureDescriptor{.{ .routine = &cyclic, .sources = &.{} }};
    cyclic.capture_descs = &cyclic_caps;
    try testing.expectError(VmError.StackOverflow, cyclic.verify(&failure));
    try cyclic.verifyAlone(&failure);
    // Random words, biased toward primary instructions of assigned
    // groups with small operands so every check is reached; a refusal
    // names an instruction of the routine.
    var prng = std.Random.DefaultPrng.init(0x7e51f1ed);
    const rand = prng.random();
    const consts = [_]Value{ fx(1), fx(2) };
    const tries = [_]Try{ .{ .catch_pc = 3 }, .{ .catch_pc = 70, .finally_pc = 1 } };
    const leaf = Routine{ .code = &.{asm_.returnNil()}, .consts = &.{}, .slot_count = 1, .upvalue_count = 1, .name = "leaf" };
    var sources: [2]CaptureSource = undefined;
    const caps = [_]CaptureDescriptor{.{ .routine = &leaf, .sources = sources[0..1] }};
    var code: [48]Inst = undefined;
    var verified: usize = 0;
    for (0..20_000) |_| {
        const len = rand.uintAtMost(usize, code.len);
        for (code[0..len]) |*inst| {
            var bits = rand.int(u64);
            if (rand.uintLessThan(u8, 8) != 0) {
                const op: u64 = rand.uintLessThan(u64, 14) | rand.uintLessThan(u64, 10) << 6;
                bits = bits & ~@as(u64, 0xFFFF) | op << 4;
            }
            if (rand.boolean()) bits &= 0x00F3_00F3_00F3_FFFF;
            inst.* = @bitCast(bits);
        }
        if (len > 0 and rand.boolean()) code[len - 1] = asm_.returnNil();
        for (&sources) |*s| s.* = if (rand.boolean()) .{ .local_cell_slot = rand.int(u4) } else .{ .inherited_upvalue = rand.int(u2) };
        const routine = Routine{
            .code = code[0..len],
            .consts = &consts,
            .capture_descs = &caps,
            .tries = &tries,
            .slot_count = rand.uintAtMost(u16, 20),
            .upvalue_count = rand.uintAtMost(u16, 3),
            .name = "random",
        };
        routine.verify(&failure) catch {
            try testing.expect(failure.pc < @max(len, 1));
            continue;
        };
        verified += 1;
    }
    try testing.expect(verified > 0);
}

test "Routine.verify: past the stack guard a run is refused with StackOverflow, and a closure is still made" {
    // A routine is verified once, where it runs as a top-level frame
    // (§5): a closure made over it below the guard checks nothing, and
    // verification that reaches the guard names the routine it was in.
    const routine = Routine{ .code = &.{asm_.returnNil()}, .consts = &.{}, .slot_count = 1, .name = "deep" };
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    stack_guard.arm(0);
    defer stack_guard.arm(stack_guard.main_thread_budget);
    try testing.expectEqual(.function, (try vm.allocClosure(&routine, 0)).kind());
    try testing.expectError(VmError.StackOverflow, vm.run());
    try testing.expectEqual(@as(usize, 1), vm.error_trace.items.len);
    try testing.expectEqualStrings("deep", vm.error_trace.items[0].name);
    try testing.expectEqual(@as(u32, 0), vm.error_trace.items[0].pc);
}

test "VM dispatch: a trap after fast instructions names its instruction in every frame" {
    // The fast handlers keep pc in a register (§8): whatever ran fast
    // before a trap, each frame of the trace is one past its own
    // instruction (§13). The child adds a fixnum, then `true`, which
    // the fast handler hands to the general one.
    const child_code = [_]Inst{
        asm_.loadConst(1, 0),
        asm_.mathAdd(2, sl(0), sl(1)),
        asm_.mathAdd(2, sl(2), kn(1)),
        asm_.returnSlot(2),
    };
    const child_consts = [_]Value{ fx(1), true_v };
    const child = Routine{ .code = &child_code, .consts = &child_consts, .slot_count = 3, .fixed_arity = 1, .name = "child" };
    const caps = [_]CaptureDescriptor{.{ .routine = &child, .sources = &.{} }};
    const consts = [_]Value{ fx(5), true_v, nativeFnValue(&dispatch_test_natives.native_refuse) };
    // A trap in a callee the fast call:call entered: the caller is at
    // its call.
    const in_callee = [_]Inst{ asm_.closureMake(0, 0), asm_.loadConst(1, 0), asm_.jumpJmp(3), asm_.callCall(0, 1, 2), asm_.returnSlot(2) };
    // The callee returns (a mov in place of its trap) and the caller
    // traps after it: the return resumed the caller's pc.
    const child_ok_code = [_]Inst{ asm_.loadConst(1, 0), asm_.mathAdd(2, sl(0), sl(1)), asm_.returnSlot(2) };
    const child_ok = Routine{ .code = &child_ok_code, .consts = &child_consts, .slot_count = 3, .fixed_arity = 1, .name = "child" };
    const caps_ok = [_]CaptureDescriptor{.{ .routine = &child_ok, .sources = &.{} }};
    const after_return = [_]Inst{ asm_.closureMake(0, 0), asm_.loadConst(1, 0), asm_.callCall(0, 1, 2), asm_.mathAdd(3, sl(2), kn(0)), asm_.mathAdd(3, sl(3), kn(1)), asm_.returnSlot(3) };
    // A leaf native that refuses its argument, called by the fast call:call.
    const in_leaf = [_]Inst{ asm_.loadConst(0, 2), asm_.loadConst(1, 0), asm_.callCall(0, 1, 2), asm_.returnSlot(2) };
    // The code runs out after fast instructions.
    const exhausted = [_]Inst{ asm_.loadNil(0), asm_.loadConst(1, 0), asm_.move(2, 1) };
    for ([_]struct { []const Inst, []const CaptureDescriptor, VmError, []const struct { []const u8, u32 } }{
        .{ &in_callee, &caps, VmError.KindMismatch, &.{ .{ "child", 2 }, .{ "parent", 3 } } },
        .{ &after_return, &caps_ok, VmError.KindMismatch, &.{.{ "parent", 4 }} },
        .{ &in_leaf, &.{}, VmError.KindMismatch, &.{.{ "parent", 2 }} },
        .{ &exhausted, &.{}, VmError.BytecodeExhausted, &.{.{ "parent", 2 }} },
    }) |case| {
        const routine = Routine{ .code = case[0], .consts = &consts, .capture_descs = case[1], .slot_count = 4, .name = "parent" };
        var vm = try VM.init(testing.allocator, &routine);
        defer vm.deinit();
        try testing.expectError(case[2], vm.run());
        try testing.expectEqual(case[3].len, vm.error_trace.items.len);
        for (case[3], vm.error_trace.items) |want, got| {
            try testing.expectEqualStrings(want[0], got.name);
            try testing.expectEqual(want[1], got.pc);
        }
    }
}

test "VM.copyRun and VM.copyEntries: every value, at any count" {
    // The copies the native boundary makes a word, or an entry, at a
    // time (§8): each element lands whole, an odd count's last value
    // as one, and nothing past the count is written.
    var src: [7]Value = undefined;
    for (&src, 0..) |*v, i| v.* = if (i % 2 == 0) fx(@intCast(i)) else value_mod.fromFloat(@floatFromInt(i));
    for (0..src.len + 1) |n| {
        for ([_]*const fn ([]Value, []const Value) void{ &VM.copyRun, &VM.copyEntries }) |copy| {
            var dst: [8]Value = @splat(true_v);
            copy(dst[0..n], src[0..n]);
            for (dst[0..n], src[0..n]) |d, e| try testing.expectEqual(e, d);
            for (dst[n..]) |d| try testing.expectEqual(true_v, d);
        }
    }
}

test "VM dispatch: a leaf native reads its arguments in place and keeps its arity" {
    // (sub 50 8) by call:call and by callValue; then (sub 1) by each.
    const code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 1),
        asm_.loadConst(2, 2),
        asm_.callCall(0, 2, 3),
        asm_.returnSlot(3),
    };
    const consts = [_]Value{ nativeFnValue(&dispatch_test_natives.native_sub), fx(50), fx(8) };
    const routine = makeRoutine(&code, &consts, 4, "leaf");
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectEqual(@as(i64, 42), (try vm.run()).asFixnum());
    try testing.expectEqual(@as(i64, 42), (try vm.callValue(consts[0], &.{ fx(50), fx(8) })).asFixnum());
    try testing.expectError(VmError.ArityMismatch, vm.callValue(consts[0], &.{fx(1)}));
    try testing.expectEqualStrings("sub takes 2 arguments, got 1", vm.error_detail);
    const short = [_]Inst{ asm_.loadConst(0, 0), asm_.loadConst(1, 1), asm_.callCall(0, 1, 2), asm_.returnSlot(2) };
    const short_routine = makeRoutine(&short, &consts, 3, "leaf-short");
    try vm.retargetTop(&short_routine);
    try testing.expectError(VmError.ArityMismatch, vm.run());
    try testing.expectEqualStrings("sub takes 2 arguments, got 1", vm.error_detail);
}

test "VM dispatch: a keyword or symbol called on a map or nil looks up in place, with no safe point" {
    // [(:k m) (:other m 9) ('s m) (:k nil 7)] with a cycle due at every
    // safe point: the loop's entry and the vector's construction
    // collect, and none of the four lookups, which allocate nothing,
    // is a safe point (§8, §9).
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    const k = try interner.internKeywordValue("k");
    const other = try interner.internKeywordValue("other");
    const s = try interner.internSymbolValue("s");
    var m = try champ_mod.mapEmpty(heap);
    m = try champ_mod.mapAssoc(heap, m, k, fx(1), &dispatch_mod.hashValue, &dispatch_mod.equal);
    m = try champ_mod.mapAssoc(heap, m, s, fx(2), &dispatch_mod.hashValue, &dispatch_mod.equal);
    const code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 3),
        asm_.callCall(0, 1, 5), // s5 = (:k m)
        asm_.loadConst(0, 1),
        asm_.loadConst(1, 3),
        asm_.loadConst(2, 4),
        asm_.callCall(0, 2, 6), // s6 = (:other m 9)
        asm_.loadConst(0, 2),
        asm_.loadConst(1, 3),
        asm_.callCall(0, 1, 7), // s7 = ('s m)
        asm_.loadConst(0, 0),
        asm_.loadNil(1),
        asm_.loadConst(2, 5),
        asm_.callCall(0, 2, 8), // s8 = (:k nil 7)
        Inst.primary(.coll, CollOp.vector, sl(5), Operand.slot(4), sl(0)),
        asm_.returnSlot(0),
    };
    const consts = [_]Value{ k, other, s, m, fx(9), fx(7) };
    const routine = makeRoutine(&code, &consts, 9, "lookups");
    try vm.retargetTop(&routine);
    vm.gc_threshold = 0;
    vm.gc_growth_percent = 0;
    vm.gc_next_at = 0;
    const result = try vm.run();
    try testing.expectEqual(@as(usize, 2), vm.gc_cycles);
    try testing.expectEqual(@as(usize, 4), vector_mod.count(result));
    for ([_]i64{ 1, 9, 2, 7 }, 0..) |want, i| try testing.expectEqual(want, vector_mod.nth(result, i).asFixnum());
}

test "VM dispatch: call:lookup and call:lookup-or look up in place with no safe point, and go general past it" {
    // [(:k m) (:other m 9) ('s m) (:k nil 7) (:k [1])] with a cycle due
    // at every safe point: the loop's entry, the general lookup of the
    // vector and the vector's construction collect; the four lookups
    // in place, which allocate nothing, are no safe point (§8, §9).
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    const interner = vm.ensureInterner();
    const k = try interner.internKeywordValue("k");
    const other = try interner.internKeywordValue("other");
    const s = try interner.internSymbolValue("s");
    var m = try champ_mod.mapEmpty(heap);
    m = try champ_mod.mapAssoc(heap, m, k, fx(1), &dispatch_mod.hashValue, &dispatch_mod.equal);
    m = try champ_mod.mapAssoc(heap, m, s, fx(2), &dispatch_mod.hashValue, &dispatch_mod.equal);
    const v = try vector_mod.fromSlice(heap, &.{fx(1)});
    const code = [_]Inst{
        asm_.callLookup(5, kn(3), 0), // s5 = (:k m), m read in place
        asm_.loadConst(1, 3),
        asm_.loadConst(2, 4),
        asm_.callLookupOr(6, 1, 1), // s6 = (:other m 9)
        asm_.callLookup(7, sl(1), 2), // s7 = ('s m)
        asm_.loadNil(1),
        asm_.loadConst(2, 5),
        asm_.callLookupOr(8, 1, 0), // s8 = (:k nil 7)
        asm_.callLookup(9, kn(6), 0), // s9 = (:k [1]), the general way
        Inst.primary(.coll, CollOp.vector, sl(5), Operand.slot(5), sl(0)),
        asm_.returnSlot(0),
    };
    const consts = [_]Value{ k, other, s, m, fx(9), fx(7), v };
    const routine = makeRoutine(&code, &consts, 10, "lookups");
    try vm.retargetTop(&routine);
    vm.gc_threshold = 0;
    vm.gc_growth_percent = 0;
    vm.gc_next_at = 0;
    const result = try vm.run();
    try testing.expectEqual(@as(usize, 3), vm.gc_cycles);
    try testing.expectEqual(@as(usize, 5), vector_mod.count(result));
    for ([_]i64{ 1, 9, 2, 7 }, 0..) |want, i| try testing.expectEqual(want, vector_mod.nth(result, i).asFixnum());
    try testing.expect(vector_mod.nth(result, 4).isNil());
}

test "Callback: repeated calls have callValue's results, errors and frame bookkeeping" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    // (fn [x] (+ x 1)) with a local past its argument, entered through
    // a prepared frame a thousand times.
    const inc_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.move(2, 1), asm_.returnSlot(2) };
    const inc_consts = [_]Value{fx(1)};
    const inc_routine = Routine{ .code = &inc_code, .consts = &inc_consts, .slot_count = 3, .fixed_arity = 1, .name = "inc1" };
    const inc_fn = try vm.allocClosure(&inc_routine, 0);
    const frames = vm.frames.items.len;
    const stack = vm.stack.items.len;
    var cb = Callback.init(&vm, inc_fn, 1);
    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        try testing.expectEqual(i + 1, (try cb.call1(fx(i))).asFixnum());
        try testing.expectEqual(frames, vm.frames.items.len);
        try testing.expectEqual(stack, vm.stack.items.len);
    }
    if (VM.track_high_water) {
        try testing.expectEqual(frames + 1, vm.frame_high_water);
        try testing.expect(vm.stack_high_water >= stack + inc_routine.slot_count);
    }

    // A closure of another arity, a leaf native given the wrong count
    // and a non-callable fail as callValue fails, detail included.
    var wrong = Callback.init(&vm, inc_fn, 2);
    try testing.expectError(VmError.ArityMismatch, wrong.call(&.{ fx(1), fx(2) }));
    try testing.expectEqualStrings("inc1 takes 1 argument, got 2", vm.error_detail);
    var leaf_short = Callback.init(&vm, nativeFnValue(&dispatch_test_natives.native_sub), 1);
    try testing.expectError(VmError.ArityMismatch, leaf_short.call(&.{fx(1)}));
    try testing.expectEqualStrings("sub takes 2 arguments, got 1", vm.error_detail);
    var number = Callback.init(&vm, fx(5), 1);
    try testing.expectError(VmError.NotCallable, number.call(&.{fx(1)}));
    try testing.expectEqualStrings("an integer is not callable", vm.error_detail);

    // A leaf native, and a keyword over every kind of receiver.
    var sub = Callback.init(&vm, nativeFnValue(&dispatch_test_natives.native_sub), 2);
    try testing.expectEqual(@as(i64, 42), (try sub.call2(fx(50), fx(8))).asFixnum());
    try testing.expectEqual(@as(i64, -1), (try sub.call(&.{ fx(1), fx(2) })).asFixnum());
    const k = try vm.ensureInterner().internKeywordValue("k");
    var m = try champ_mod.mapEmpty(heap);
    m = try champ_mod.mapAssoc(heap, m, k, fx(1), &dispatch_mod.hashValue, &dispatch_mod.equal);
    var set = try champ_mod.setEmpty(heap);
    set = try champ_mod.setConj(heap, set, k, &dispatch_mod.hashValue, &dispatch_mod.equal);
    var get_k = Callback.init(&vm, k, 1);
    try testing.expectEqual(@as(i64, 1), (try get_k.call(&.{m})).asFixnum());
    try testing.expect((try get_k.call(&.{value_mod.nilValue()})).isNil());
    try testing.expect((try get_k.call(&.{fx(5)})).isNil());
    try testing.expectEqual(k, try get_k.call(&.{set}));
}

test "Callback: an error in the callee is caught where a handler stands, else leaves its frame standing" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    // (fn [x] (try (+ x 1) (catch any e e))): the error leaves the
    // callee's first pass, and the loop runs the catch to the return.
    const caught_code = [_]Inst{
        asm_.tryEnter(0, 1),
        asm_.mathAdd(2, sl(0), kn(0)),
        asm_.tryExit(5),
        asm_.move(2, 1), // 3: the catch
        asm_.tryExit(5),
        asm_.returnSlot(2),
    };
    const one = [_]Value{fx(1)};
    const tries = [_]Try{.{ .catch_pc = 3 }};
    const caught = Routine{ .code = &caught_code, .consts = &one, .tries = &tries, .slot_count = 3, .fixed_arity = 1, .name = "caught" };
    var cb = Callback.init(&vm, try vm.allocClosure(&caught, 0), 1);
    const frames = vm.frames.items.len;
    try testing.expectEqual(@as(i64, 6), (try cb.call(&.{fx(5)})).asFixnum());
    const kw = try cb.call(&.{value_mod.nilValue()});
    try testing.expectEqualStrings("kind-mismatch", try caughtTag(&vm, kw));
    try testing.expectEqual(@as(i64, 8), (try cb.call(&.{fx(7)})).asFixnum());
    try testing.expectEqual(frames, vm.frames.items.len);
    try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loop_depth);
    try testing.expectEqual(@as(usize, 0), vm.nested_runs);

    // (fn [x] (+ x 1)) given nil, with no handler: the error leaves with
    // the callee's frame standing at the failing instruction, as a run
    // loop leaves it for the trace.
    const plain_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.returnSlot(1) };
    const plain = Routine{ .code = &plain_code, .consts = &one, .slot_count = 2, .fixed_arity = 1, .name = "plain" };
    var bad = Callback.init(&vm, try vm.allocClosure(&plain, 0), 1);
    try testing.expectEqual(@as(i64, 3), (try bad.call(&.{fx(2)})).asFixnum());
    try testing.expectError(VmError.KindMismatch, bad.call(&.{value_mod.nilValue()}));
    try testing.expectEqual(frames + 1, vm.frames.items.len);
    try testing.expectEqual(&plain, vm.frames.items[frames].routine);
    try testing.expectEqual(@as(u32, 1), vm.frames.items[frames].pc);
    try testing.expectEqual(@as(usize, 0), vm.loop_depth);
    try testing.expectEqual(@as(usize, 0), vm.nested_runs);
}

/// Natives that call a closure through a `Callback`, for the tests
/// below: `twice` applies its first argument to its second and then to
/// the result; `pair` applies it to its second and then its third
/// argument, recording the error the second call ends with.
const callback_test_natives = struct {
    var second_error: ?VmError = null;
    fn twice(vm: *VM, args: []const Value) VmError!Value {
        var cb = Callback.init(vm, args[0], 1);
        const once = try cb.call1(args[1]);
        return cb.call1(once);
    }
    fn pair(vm: *VM, args: []const Value) VmError!Value {
        var cb = Callback.init(vm, args[0], 1);
        _ = try cb.call1(args[1]);
        return cb.call1(args[2]) catch |err| {
            second_error = err;
            return err;
        };
    }
    /// The sum of `(f x)` for `x` from `n` to `n + 2`, through `each`.
    fn eachSum(vm: *VM, args: []const Value) VmError!Value {
        var cb = Callback.init(vm, args[0], 1);
        const n = args[1].asFixnum();
        const items = [_]Value{ fx(n), fx(n + 1), fx(n + 2) };
        var out: [3]Value = undefined;
        try cb.each(&items, .{ .slots = &out });
        var sum: i64 = 0;
        for (out) |v| sum += v.asFixnum();
        return fx(sum);
    }
    /// `each` of its first argument over the rest, recording the error.
    fn eachAll(vm: *VM, args: []const Value) VmError!Value {
        var cb = Callback.init(vm, args[0], 1);
        var out: [8]Value = undefined;
        cb.each(args[1..], .{ .slots = &out }) catch |err| {
            second_error = err;
            return err;
        };
        return out[args.len - 2];
    }
    fn inc(_: *VM, args: []const Value) VmError!Value {
        return fx(args[0].asFixnum() + 1);
    }
    fn add(_: *VM, args: []const Value) VmError!Value {
        return fx(args[0].asFixnum() + args[1].asFixnum());
    }
    fn first(_: *VM, args: []const Value) VmError!Value {
        return args[0];
    }
    const native_twice = NativeFn{ .name = "twice", .min_arity = 2, .max_arity = 2, .call = &twice };
    const native_pair = NativeFn{ .name = "pair", .min_arity = 3, .max_arity = 3, .call = &pair };
    const native_each_sum = NativeFn{ .name = "each-sum", .min_arity = 2, .max_arity = 2, .call = &eachSum };
    const native_each_all = NativeFn{ .name = "each-all", .min_arity = 2, .max_arity = 9, .call = &eachAll };
    const native_inc = NativeFn{ .name = "inc", .min_arity = 1, .max_arity = 1, .call = &inc, .leaf = true };
    const native_add = NativeFn{ .name = "add", .min_arity = 2, .max_arity = 2, .call = &add, .leaf = true };
    /// Not a leaf: called through `callValue`.
    const native_first = NativeFn{ .name = "first", .min_arity = 1, .max_arity = 2, .call = &first };
};

/// What every batch test checks after a pass: the frames, the stack
/// and the loop's bookkeeping as they were.
fn expectBatchClean(vm: *const VM, frames: usize, stack: usize) !void {
    try testing.expectEqual(frames, vm.frames.items.len);
    try testing.expectEqual(stack, vm.stack.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loop_depth);
    try testing.expectEqual(@as(usize, 0), vm.nested_runs);
    try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
}

test "Callback batches: each, fold and foldRange give call's results in every mode" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    const one = [_]Value{fx(1)};
    // (fn [x] (+ x 1)) with a local past its argument, and (fn [a x] (+ a x)).
    const inc_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.move(2, 1), asm_.returnSlot(2) };
    const inc_routine = Routine{ .code = &inc_code, .consts = &one, .slot_count = 3, .fixed_arity = 1, .name = "inc1" };
    const add_code = [_]Inst{ asm_.mathAdd(2, sl(0), sl(1)), asm_.returnSlot(2) };
    const add_routine = Routine{ .code = &add_code, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .name = "add2" };
    const inc_fn = try vm.allocClosure(&inc_routine, 0);
    const add_fn = try vm.allocClosure(&add_routine, 0);
    const frames = vm.frames.items.len;
    const stack = vm.stack.items.len;
    var items: [1000]Value = undefined;
    for (&items, 0..) |*x, i| x.* = fx(@intCast(i));
    var out: [1000]Value = undefined;

    // `each` of a closure, of a leaf native, of a native that is not a
    // leaf, and of a closure called from another stack length, which
    // takes `call`'s path for every element.
    for ([_]Value{ inc_fn, nativeFnValue(&callback_test_natives.native_inc) }) |f| {
        var cb = Callback.init(&vm, f, 1);
        @memset(&out, value_mod.nilValue());
        try cb.each(&items, .{ .slots = &out });
        for (out, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i + 1)), v.asFixnum());
        try expectBatchClean(&vm, frames, stack);
    }
    var general = Callback.init(&vm, nativeFnValue(&callback_test_natives.native_first), 1);
    try general.each(&items, .{ .slots = &out });
    for (out, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i)), v.asFixnum());
    try testing.expect(general.mode == .general);
    var moved = Callback.init(&vm, inc_fn, 1);
    try moved.each(items[0..1], .{ .slots = &out });
    vm.stack.appendAssumeCapacity(value_mod.nilValue());
    try moved.each(items[0..100], .{ .slots = &out });
    for (out[0..100], 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i + 1)), v.asFixnum());
    vm.stack.items.len -= 1;
    try expectBatchClean(&vm, frames, stack);
    if (VM.track_high_water) try testing.expectEqual(frames + 1, vm.frame_high_water);

    // Into the root stack, by index.
    {
        const scope = vm.rootScope();
        defer scope.release();
        for (0..items.len) |_| try scope.push(value_mod.nilValue());
        var cb = Callback.init(&vm, inc_fn, 1);
        try cb.each(&items, .{ .roots = scope.base });
        for (vm.roots.items[scope.base..], 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(i + 1)), v.asFixnum());
    }

    // A keyword over maps and nil.
    const k = try vm.ensureInterner().internKeywordValue("k");
    var m = try champ_mod.mapEmpty(heap);
    m = try champ_mod.mapAssoc(heap, m, k, fx(7), &dispatch_mod.hashValue, &dispatch_mod.equal);
    var get_k = Callback.init(&vm, k, 1);
    try get_k.each(&.{ m, value_mod.nilValue(), m }, .{ .slots = &out });
    try testing.expectEqual(@as(i64, 7), out[0].asFixnum());
    try testing.expect(out[1].isNil());
    try testing.expectEqual(@as(i64, 7), out[2].asFixnum());

    // `fold` and `foldRange` of a closure and of a leaf, in pieces:
    // the first call prepares, and a later fold carries the
    // accumulator on.
    for ([_]Value{ add_fn, nativeFnValue(&callback_test_natives.native_add) }) |f| {
        var cb = Callback.init(&vm, f, 2);
        var folded = try cb.fold(fx(0), items[0..1]);
        try testing.expectEqual(@as(usize, 1), folded.used);
        folded = try cb.fold(folded.acc, items[1..]);
        try testing.expectEqual(@as(usize, 999), folded.used);
        try testing.expectEqual(@as(i64, 499500), folded.acc.asFixnum());
        var range = Callback.init(&vm, f, 2);
        folded = try range.foldRange(fx(0), fx(0), 1, 1000);
        try testing.expectEqual(@as(usize, 1000), folded.used);
        try testing.expectEqual(@as(i64, 499500), folded.acc.asFixnum());
        folded = try range.foldRange(fx(5), fx(10), -3, 4);
        try testing.expectEqual(@as(i64, 5 + 10 + 7 + 4 + 1), folded.acc.asFixnum());
        folded = try range.foldRange(fx(0), fx(2), 0, 1000);
        try testing.expectEqual(@as(i64, 2000), folded.acc.asFixnum());
        folded = try range.foldRange(fx(3), fx(2), 0, 0);
        try testing.expectEqual(@as(usize, 0), folded.used);
        try testing.expectEqual(@as(i64, 3), folded.acc.asFixnum());
        try expectBatchClean(&vm, frames, stack);
    }
}

test "Callback batches: a record stops a fold after it, whether reduced or not" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const heap = vm.ensureHeap();
    // (fn [a x] x)
    const second_code = [_]Inst{asm_.returnSlot(1)};
    const second = Routine{ .code = &second_code, .consts = &.{}, .slot_count = 2, .fixed_arity = 2, .name = "second" };
    const f = try vm.allocClosure(&second, 0);
    const type_id = try vm.registerRecordType("t", "R", &.{});
    const rec = try record_mod.make(heap, type_id, try champ_mod.mapEmpty(heap));
    const frames = vm.frames.items.len;
    const stack = vm.stack.items.len;
    for ([_]usize{ 0, 31, 32, 33 }) |k| {
        var items: [64]Value = undefined;
        for (&items, 0..) |*x, i| x.* = if (i == k) rec else fx(@intCast(i));
        var cb = Callback.init(&vm, f, 2);
        var folded = try cb.fold(fx(-1), &items);
        try testing.expectEqual(k + 1, folded.used);
        try testing.expectEqual(rec, folded.acc);
        folded = try cb.fold(folded.acc, items[folded.used..]);
        try testing.expectEqual(items.len - k - 1, folded.used);
        try testing.expectEqual(@as(i64, 63), folded.acc.asFixnum());
        try expectBatchClean(&vm, frames, stack);
    }
}

test "Callback batches: an element's error caught inside the callee, the batch goes on" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    // (fn [x] (try (+ x 1) (catch any e e)))
    const caught_code = [_]Inst{
        asm_.tryEnter(0, 1),
        asm_.mathAdd(2, sl(0), kn(0)),
        asm_.tryExit(5),
        asm_.move(2, 1), // 3: the catch
        asm_.tryExit(5),
        asm_.returnSlot(2),
    };
    const one = [_]Value{fx(1)};
    const tries = [_]Try{.{ .catch_pc = 3 }};
    const caught = Routine{ .code = &caught_code, .consts = &one, .tries = &tries, .slot_count = 3, .fixed_arity = 1, .name = "caught" };
    const f = try vm.allocClosure(&caught, 0);
    const frames = vm.frames.items.len;
    const stack = vm.stack.items.len;
    for ([_]usize{ 0, 31, 32, 63 }) |k| {
        var items: [64]Value = undefined;
        for (&items, 0..) |*x, i| x.* = if (i == k) value_mod.nilValue() else fx(@intCast(i));
        var out: [64]Value = undefined;
        var cb = Callback.init(&vm, f, 1);
        // Prepared by a call of its own, so element 0 is a batch's too.
        _ = try cb.call1(fx(0));
        try cb.each(&items, .{ .slots = &out });
        for (out, 0..) |v, i| if (i == k) {
            try testing.expectEqualStrings("kind-mismatch", try caughtTag(&vm, v));
        } else try testing.expectEqual(@as(i64, @intCast(i + 1)), v.asFixnum());
        try expectBatchClean(&vm, frames, stack);
    }
}

test "Callback batches: an element's error with no handler leaves its frame, one past it ends the native's call" {
    const plain_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.returnSlot(1) };
    const one = [_]Value{fx(1)};
    const plain = Routine{ .code = &plain_code, .consts = &one, .slot_count = 2, .fixed_arity = 1, .name = "plain" };
    {
        var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
        defer vm.deinit();
        const frames = vm.frames.items.len;
        var cb = Callback.init(&vm, try vm.allocClosure(&plain, 0), 1);
        var out: [3]Value = undefined;
        try testing.expectError(VmError.KindMismatch, cb.each(&.{ fx(1), fx(2), value_mod.nilValue() }, .{ .slots = &out }));
        try testing.expectEqual(@as(i64, 3), out[1].asFixnum());
        try testing.expectEqual(frames + 1, vm.frames.items.len);
        try testing.expectEqual(&plain, vm.frames.items[frames].routine);
        try testing.expectEqual(@as(u32, 1), vm.frames.items[frames].pc);
        try testing.expectEqual(@as(usize, 0), vm.loop_depth);
        try testing.expectEqual(@as(usize, 0), vm.nested_runs);
        try testing.expect(cb.result.step == null);
    }
    // (try (each-all (fn [x] (+ x 1)) 2 3 nil 4) (catch any e e))
    const caps = [_]CaptureDescriptor{.{ .routine = &plain, .sources = &.{} }};
    const code = [_]Inst{
        asm_.tryEnter(0, 1),
        asm_.loadConst(2, 0),
        asm_.closureMake(0, 3),
        asm_.loadConst(4, 1),
        asm_.loadConst(5, 2),
        asm_.loadNil(6),
        asm_.loadConst(7, 1),
        asm_.callCall(2, 5, 8),
        asm_.returnSlot(8),
        asm_.move(0, 1), // 9: the catch
        asm_.tryExit(11),
        asm_.returnSlot(0), // 11
    };
    const consts = [_]Value{ nativeFnValue(&callback_test_natives.native_each_all), fx(2), fx(3) };
    var routine = makeRoutine(&code, &consts, 9, "throw-past");
    routine.capture_descs = &caps;
    routine.tries = &.{.{ .catch_pc = 9 }};
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    callback_test_natives.second_error = null;
    const result = try vm.run();
    try testing.expectEqualStrings("kind-mismatch", try caughtTag(&vm, result));
    try testing.expectEqual(VmError.ControlTransferred, callback_test_natives.second_error.?);
    try expectBatchClean(&vm, 1, vm.stack.items.len);
}

test "Callback batches: a callee that runs a batch of its own nests it a frame deeper" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const one = [_]Value{fx(1)};
    const inc_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.returnSlot(1) };
    const inc_routine = Routine{ .code = &inc_code, .consts = &one, .slot_count = 2, .fixed_arity = 1, .name = "inc" };
    // (fn [x] (each-sum inc x)): 3x + 6.
    const outer_code = [_]Inst{
        asm_.loadConst(1, 0),
        asm_.loadConst(2, 1),
        asm_.move(3, 0),
        asm_.callCall(1, 2, 4),
        asm_.returnSlot(4),
    };
    const outer_consts = [_]Value{ nativeFnValue(&callback_test_natives.native_each_sum), try vm.allocClosure(&inc_routine, 0) };
    const outer = Routine{ .code = &outer_code, .consts = &outer_consts, .slot_count = 5, .fixed_arity = 1, .name = "outer" };
    const frames = vm.frames.items.len;
    const stack = vm.stack.items.len;
    var items: [100]Value = undefined;
    for (&items, 0..) |*x, i| x.* = fx(@intCast(i));
    var out: [100]Value = undefined;
    var cb = Callback.init(&vm, try vm.allocClosure(&outer, 0), 1);
    try cb.each(&items, .{ .slots = &out });
    for (out, 0..) |v, i| try testing.expectEqual(@as(i64, @intCast(3 * i + 6)), v.asFixnum());
    try expectBatchClean(&vm, frames, stack);
    if (VM.track_high_water) try testing.expectEqual(frames + 2, vm.frame_high_water);
}

test "Callback batches: a cycle at every element frees nothing a batch holds" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    // (fn [x] [x x]) and (fn [a x] [a x]): every call allocates.
    const pair_code = [_]Inst{ asm_.move(1, 0), asm_.coll(.vector, 0, 2, 2), asm_.returnSlot(2) };
    const pair = Routine{ .code = &pair_code, .consts = &.{}, .slot_count = 3, .fixed_arity = 1, .name = "pair" };
    const nest_code = [_]Inst{ asm_.coll(.vector, 0, 2, 2), asm_.returnSlot(2) };
    const nest = Routine{ .code = &nest_code, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .name = "nest" };
    const pair_fn = try vm.allocClosure(&pair, 0);
    const nest_fn = try vm.allocClosure(&nest, 0);
    const scope = vm.rootScope();
    defer scope.release();
    try scope.push(pair_fn);
    try scope.push(nest_fn);
    const n = 300;
    for (0..n) |_| try scope.push(value_mod.nilValue());
    var items: [n]Value = undefined;
    for (&items, 0..) |*x, i| x.* = fx(@intCast(i));
    vm.gc_threshold = 0;
    vm.gc_growth_percent = 0;
    vm.gc_next_at = 0;
    const cycles = vm.gc_cycles;
    var each = Callback.init(&vm, pair_fn, 1);
    try each.each(&items, .{ .roots = scope.base + 2 });
    var fold = Callback.init(&vm, nest_fn, 2);
    const folded = try fold.fold(value_mod.nilValue(), &items);
    // A cycle before every element but the first.
    try testing.expect(vm.gc_cycles - cycles >= 2 * (n - 1));
    for (vm.roots.items[scope.base + 2 ..], 0..) |v, i| {
        try testing.expectEqual(@as(i64, @intCast(i)), vector_mod.nth(v, 0).asFixnum());
        try testing.expectEqual(@as(i64, @intCast(i)), vector_mod.nth(v, 1).asFixnum());
    }
    var acc = folded.acc;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        try testing.expectEqual(@as(i64, @intCast(i)), vector_mod.nth(acc, 1).asFixnum());
        acc = vector_mod.nth(acc, 0);
    }
    try testing.expect(acc.isNil());
}

test "Callback batches: the general return starts the next element in the same frame" {
    // The general `call:return`, which the fast one hands an operand it
    // cannot read in place, through `returnValue`: element by element,
    // the result to its place and the frame reset to the first call's,
    // its pc 0, until the last pops it.
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const one = [_]Value{fx(1)};
    const inc_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.move(2, 1), asm_.returnSlot(2) };
    const inc_routine = Routine{ .code = &inc_code, .consts = &one, .slot_count = 3, .fixed_arity = 1, .name = "inc1" };
    var cb = Callback.init(&vm, try vm.allocClosure(&inc_routine, 0), 1);
    _ = try cb.call1(fx(0));
    const frames = vm.frames.items.len;
    const items = [_]Value{ fx(4), fx(5), fx(6) };
    var out: [3]Value = undefined;
    cb.batch = .{ .step = .each_slots, .i = 0, .n = 3, .items = &items, .out = .{ .slots = &out } };
    cb.result.step = VM.batchNext(.each_slots);
    cb.result.done = false;
    // The first element's frame, as `callPrepared` pushes it.
    cb.window()[0] = items[0];
    VM.nilLocals(vm.stack.items.ptr + cb.locals, cb.nil_count);
    vm.stack.items.len = cb.window_end;
    vm.frames.appendAssumeCapacity(cb.frame);
    for (0..3) |i| {
        vm.frames.items[frames].pc = 2;
        vm.stack.items[cb.base + 1] = fx(9);
        try vm.returnValue(fx(@intCast(10 + i)));
        try testing.expectEqual(@as(i64, @intCast(10 + i)), out[i].asFixnum());
        if (i < 2) {
            try testing.expectEqual(frames + 1, vm.frames.items.len);
            try testing.expectEqual(@as(u32, 0), vm.frames.items[frames].pc);
            try testing.expectEqual(items[i + 1], vm.stack.items[cb.base]);
            try testing.expect(vm.stack.items[cb.base + 1].isNil());
            try testing.expect(!cb.result.done);
        }
    }
    try testing.expect(cb.result.done);
    try testing.expectEqual(@as(i64, 12), cb.result.value.asFixnum());
    try testing.expectEqual(frames, vm.frames.items.len);
    try testing.expectEqual(cb.base, vm.stack.items.len);
}

test "Callback: a callee that calls a native with a Callback of its own nests a frame deeper" {
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    // (fn [x] (+ x 1)), and (fn [x] (twice inc x)) over it.
    const inc_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.returnSlot(1) };
    const one = [_]Value{fx(1)};
    const inc_routine = Routine{ .code = &inc_code, .consts = &one, .slot_count = 2, .fixed_arity = 1, .name = "inc" };
    const inc_fn = try vm.allocClosure(&inc_routine, 0);
    const outer_code = [_]Inst{
        asm_.loadConst(1, 0),
        asm_.loadConst(2, 1),
        asm_.move(3, 0),
        asm_.callCall(1, 2, 4),
        asm_.returnSlot(4),
    };
    const outer_consts = [_]Value{ nativeFnValue(&callback_test_natives.native_twice), inc_fn };
    const outer = Routine{ .code = &outer_code, .consts = &outer_consts, .slot_count = 5, .fixed_arity = 1, .name = "outer" };
    const frames = vm.frames.items.len;
    const stack = vm.stack.items.len;
    var cb = Callback.init(&vm, try vm.allocClosure(&outer, 0), 1);
    var i: i64 = 0;
    while (i < 1000) : (i += 1) {
        try testing.expectEqual(i + 2, (try cb.call1(fx(i))).asFixnum());
        try testing.expectEqual(frames, vm.frames.items.len);
        try testing.expectEqual(stack, vm.stack.items.len);
        try testing.expectEqual(@as(usize, 0), vm.loop_depth);
        try testing.expectEqual(@as(usize, 0), vm.nested_runs);
    }
    try testing.expect(cb.mode == .closure);
    // The inner callback's frame stood on the outer's.
    if (VM.track_high_water) try testing.expectEqual(frames + 2, vm.frame_high_water);
}

test "Callback: a throw past the native ends its call with ControlTransferred and the frames below" {
    // (try (pair (fn [x] (+ x 1)) 2 nil) (catch any e e)): the first
    // call returns, the second's error is a throw the handler beneath
    // the native takes.
    const plain_code = [_]Inst{ asm_.mathAdd(1, sl(0), kn(0)), asm_.returnSlot(1) };
    const one = [_]Value{fx(1)};
    const plain = Routine{ .code = &plain_code, .consts = &one, .slot_count = 2, .fixed_arity = 1, .name = "plain" };
    const caps = [_]CaptureDescriptor{.{ .routine = &plain, .sources = &.{} }};
    const code = [_]Inst{
        asm_.tryEnter(0, 1),
        asm_.loadConst(2, 0),
        asm_.closureMake(0, 3),
        asm_.loadConst(4, 1),
        asm_.loadNil(5),
        asm_.callCall(2, 3, 6),
        asm_.returnSlot(6),
        asm_.move(0, 1), // 7: the catch
        asm_.tryExit(9),
        asm_.returnSlot(0), // 9
    };
    const consts = [_]Value{ nativeFnValue(&callback_test_natives.native_pair), fx(2) };
    var routine = makeRoutine(&code, &consts, 7, "throw-past");
    routine.capture_descs = &caps;
    routine.tries = &.{.{ .catch_pc = 7 }};
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    callback_test_natives.second_error = null;
    const result = try vm.run();
    try testing.expectEqualStrings("kind-mismatch", try caughtTag(&vm, result));
    try testing.expectEqual(VmError.ControlTransferred, callback_test_natives.second_error.?);
    try testing.expectEqual(@as(usize, 1), vm.frames.items.len);
    try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
    try testing.expectEqual(@as(usize, 0), vm.loop_depth);
    try testing.expectEqual(@as(usize, 0), vm.nested_runs);
}

test "VM dispatch: a native's throw two loops deep reaches the handler below" {
    // (try (call (fn [] (boom))) (catch any e e)), then a call after
    // the catch: the throw leaves the nested run `callValue` started
    // and the native that started it, and the outer run carries on.
    const child_code = [_]Inst{ asm_.loadConst(0, 0), asm_.callCall(0, 0, 1), asm_.returnSlot(1) };
    const child_consts = [_]Value{nativeFnValue(&dispatch_test_natives.native_boom)};
    const child = Routine{ .code = &child_code, .consts = &child_consts, .slot_count = 2 };
    const ret7_code = [_]Inst{ asm_.loadConst(0, 0), asm_.returnSlot(0) };
    const ret7_consts = [_]Value{fx(7)};
    const ret7 = Routine{ .code = &ret7_code, .consts = &ret7_consts, .slot_count = 1 };
    const caps = [_]CaptureDescriptor{ .{ .routine = &child, .sources = &.{} }, .{ .routine = &ret7, .sources = &.{} } };
    const code = [_]Inst{
        asm_.tryEnter(0, 1),
        asm_.loadConst(2, 0),
        asm_.closureMake(0, 3),
        asm_.callCall(2, 1, 4),
        asm_.returnNil(),
        asm_.move(0, 1), // 5: the catch
        asm_.tryExit(7),
        asm_.closureMake(1, 2), // 7
        asm_.callCall(2, 0, 1),
        Inst.primary(.coll, CollOp.vector, sl(0), Operand.slot(2), sl(4)), // [e 7]
        asm_.returnSlot(4),
    };
    const consts = [_]Value{nativeFnValue(&dispatch_test_natives.native_call)};
    var routine = makeRoutine(&code, &consts, 5, "two-loops");
    routine.capture_descs = &caps;
    routine.tries = &.{.{ .catch_pc = 5 }};
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(usize, 2), vector_mod.count(result));
    try testing.expectEqualStrings("boom", try caughtTag(&vm, vector_mod.nth(result, 0)));
    try testing.expectEqual(@as(i64, 7), vector_mod.nth(result, 1).asFixnum());
    try testing.expectEqual(@as(usize, 0), vm.loop_depth);
    try testing.expectEqual(@as(usize, 1), vm.frames.items.len);
    try testing.expectEqual(@as(usize, 0), vm.handlers.items.len);
}

test "VM dispatch: recursion stops at max_frames on the direct call path" {
    // (letfn [(f [] (f))] (f)) with room for 50 frames.
    const child_code = [_]Inst{ asm_.moveFrom(0, Operand.upvalue(0)), asm_.callCall(0, 0, 1), asm_.returnSlot(1) };
    const child = Routine{ .code = &child_code, .consts = &.{}, .slot_count = 2, .upvalue_count = 1 };
    const caps = [_]CaptureDescriptor{.{ .routine = &child, .sources = &[_]CaptureSource{.{ .local_cell_slot = 0 }} }};
    const code = [_]Inst{
        asm_.closureNewCell(0),
        asm_.closureMake(0, 1),
        asm_.closureInitCell(0, sl(1)),
        asm_.callCall(1, 0, 2),
        asm_.returnSlot(2),
    };
    var routine = makeRoutine(&code, &.{}, 3, "runaway");
    routine.capture_descs = &caps;
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    vm.max_frames = 50;
    try testing.expectError(VmError.StackOverflow, vm.run());
    try testing.expectEqual(@as(usize, 50), vm.frames.items.len);
    if (VM.track_high_water) try testing.expectEqual(@as(usize, 50), vm.frame_high_water);
}

test "VM dispatch: call:self calls the frame's closure, on the direct path and past it" {
    // (fn* sum [n] (if (< n 1) n (+ n (sum (- n 1))))), 10000 deep: the
    // frames and the stack outgrow their capacity, so the general
    // handler takes the calls that grow them.
    const child_code = [_]Inst{
        asm_.cmpLt(1, sl(0), kn(0)),
        asm_.jumpIfFalse(3, sl(1)),
        asm_.returnSlot(0),
        Inst.primary(.math, Math.sub, sl(2), sl(0), kn(0)),
        asm_.callSelf(2, 1, 2),
        asm_.mathAdd(1, sl(0), sl(2)),
        asm_.returnSlot(1),
    };
    const child_consts = [_]Value{fx(1)};
    const child = Routine{ .code = &child_code, .consts = &child_consts, .slot_count = 3, .fixed_arity = 1, .name = "sum" };
    const caps = [_]CaptureDescriptor{.{ .routine = &child, .sources = &.{} }};
    const consts = [_]Value{fx(10_000)};
    const code = [_]Inst{ asm_.closureMake(0, 0), asm_.loadConst(1, 0), asm_.callCall(0, 1, 2), asm_.returnSlot(2) };
    var routine = makeRoutine(&code, &consts, 3, "top");
    routine.capture_descs = &caps;
    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    try testing.expectEqual(fx(50_005_000), try vm.run());
    // Runaway, it stops at `max_frames` with every frame standing.
    vm.max_frames = 50;
    try vm.retargetTop(&routine);
    try testing.expectError(VmError.StackOverflow, vm.run());
    try testing.expectEqual(@as(usize, 50), vm.frames.items.len);
    try testing.expectEqualStrings("sum", vm.error_trace.items[0].name);
    try testing.expectEqual(@as(u32, 4), vm.error_trace.items[0].pc);
    // A top-level frame has no closure to call.
    const lone = makeRoutine(&.{ asm_.callSelf(0, 0, 0), asm_.returnNil() }, &.{}, 1, "lone");
    var vm2 = try VM.init(testing.allocator, &lone);
    defer vm2.deinit();
    try testing.expectError(VmError.BytecodeCorruption, vm2.run());
}

/// Point every member of `table` at it, as the compiler links the
/// clauses of a multi-arity `fn` (§5).
fn linkTable(table: *const Arities) void {
    var members = table.members();
    while (members.next()) |m| @constCast(m).arities = table;
}

/// `(fn ([] 100) ([a] 101) ([a b] 102) ([a b c d & m] m))`, its closure
/// naming the two-argument clause.
const TestClauses = struct {
    none: Routine = .{ .code = &.{ asm_.loadConst(0, 0), asm_.returnSlot(0) }, .consts = &.{fx(100)}, .slot_count = 1, .name = "f" },
    one: Routine = .{ .code = &.{ asm_.loadConst(1, 0), asm_.returnSlot(1) }, .consts = &.{fx(101)}, .slot_count = 2, .fixed_arity = 1, .name = "f" },
    two: Routine = .{ .code = &.{ asm_.loadConst(2, 0), asm_.returnSlot(2) }, .consts = &.{fx(102)}, .slot_count = 3, .fixed_arity = 2, .name = "f" },
    rest: Routine = .{ .code = &.{asm_.returnSlot(4)}, .consts = &.{}, .slot_count = 5, .fixed_arity = 4, .variadic = true, .name = "f" },
    fixed: [3]?*const Routine = undefined,
    table: Arities = undefined,

    fn link(t: *TestClauses) void {
        t.fixed = .{ &t.none, &t.one, &t.two };
        t.table = .{ .fixed = &t.fixed, .rest = &t.rest };
        linkTable(&t.table);
    }

    /// What a call with `argc` arguments 0, 1, ... returns.
    fn expect(argc: usize, got: anyerror!Value) !void {
        errdefer std.debug.print("a call with {d} arguments\n", .{argc});
        switch (argc) {
            0, 1, 2 => try testing.expectEqual(fx(100 + @as(i64, @intCast(argc))), try got),
            3 => try testing.expectError(VmError.ArityMismatch, got),
            4 => try testing.expect((try got).isNil()),
            else => {
                const m = try got;
                try testing.expectEqual(argc - 4, list_mod.count(m));
                try testing.expectEqual(fx(4), list_mod.head(m));
            },
        }
    }
};

test "VM closure call: a call enters the member of the arity table its count picks, on every path" {
    var t: TestClauses = .{};
    t.link();
    const sentence = "f takes 0 to 2 or at least 4 arguments, got 3";
    // call:call, twice each: the first grows the stack through the
    // general entry, the second takes the direct path.
    const caps = [_]CaptureDescriptor{.{ .routine = &t.two, .sources = &.{} }};
    const consts = [_]Value{ fx(0), fx(1), fx(2), fx(3), fx(4), fx(5), fx(6) };
    for (0..8) |argc| {
        var code: [24]Inst = undefined;
        var n: usize = 0;
        code[n] = asm_.closureMake(0, 0);
        n += 1;
        for (0..2) |round| {
            for (0..argc) |i| {
                code[n] = asm_.loadConst(@intCast(1 + i), @intCast(i));
                n += 1;
            }
            code[n] = asm_.callCall(0, @intCast(argc), @intCast(9 + round));
            n += 1;
        }
        code[n] = asm_.coll(.list, 9, 2, 9);
        code[n + 1] = asm_.returnSlot(9);
        var top = makeRoutine(code[0 .. n + 2], &consts, 11, "top");
        top.capture_descs = &caps;
        var vm = try VM.init(testing.allocator, &top);
        defer vm.deinit();
        const both = vm.run();
        if (argc == 3) {
            try TestClauses.expect(argc, both);
            try testing.expectEqualStrings(sentence, vm.error_detail);
            // Raised in the caller, before a frame is pushed.
            try testing.expectEqual(@as(usize, 1), vm.error_trace.items.len);
            try testing.expectEqualStrings("top", vm.error_trace.items[0].name);
            continue;
        }
        const pair = try both;
        try TestClauses.expect(argc, list_mod.head(pair));
        try TestClauses.expect(argc, list_mod.head(list_mod.tail(pair)));
    }
    // callValue and a Callback, three calls each.
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    const f = try vm.allocClosure(&t.two, 0);
    for (0..8) |argc| {
        var cb = Callback.init(&vm, f, @intCast(argc));
        for (0..3) |_| {
            try TestClauses.expect(argc, vm.callValue(f, consts[0..argc]));
            try TestClauses.expect(argc, cb.call(consts[0..argc]));
        }
        if (argc == 3) try testing.expectEqualStrings(sentence, vm.error_detail);
        // A fixed member is called through a prepared frame.
        try testing.expectEqual(argc <= 2, cb.mode == .closure);
    }
}

test "VM error detail: an arity sentence names every count a closure takes" {
    // Members of every arity up to 200, as many tables need.
    var members: [201]Routine = undefined;
    for (&members, 0..) |*m, i| m.* = .{ .code = &.{asm_.returnNil()}, .consts = &.{}, .slot_count = @intCast(i + 1), .fixed_arity = @intCast(i), .name = "f" };
    var rests: [8]Routine = undefined;
    for (&rests, 0..) |*m, i| m.* = .{ .code = &.{asm_.returnNil()}, .consts = &.{}, .slot_count = @intCast(i + 1), .fixed_arity = @intCast(i), .variadic = true, .name = "f" };
    const Case = struct { fixed: []const u8, rest: ?usize = null, want: []const u8 };
    var fixed: [201]?*const Routine = undefined;
    var vm = try VM.init(testing.allocator, &makeRoutine(&[_]Inst{asm_.returnNil()}, &.{}, 1, "idle"));
    defer vm.deinit();
    for ([_]Case{
        .{ .fixed = &.{ 1, 2 }, .want = "1 or 2 arguments" },
        .{ .fixed = &.{ 0, 1, 2 }, .want = "0 to 2 arguments" },
        .{ .fixed = &.{ 0, 1, 2, 5 }, .want = "0 to 2 or 5 arguments" },
        .{ .fixed = &.{ 0, 2, 3, 4, 7 }, .want = "0, 2 to 4 or 7 arguments" },
        .{ .fixed = &.{ 1, 3 }, .rest = 5, .want = "1, 3 or at least 5 arguments" },
        .{ .fixed = &.{1}, .rest = 2, .want = "at least 1 argument" },
        .{ .fixed = &.{ 0, 2 }, .rest = 2, .want = "0 or at least 2 arguments" },
        .{ .fixed = &.{ 1, 2 }, .rest = 2, .want = "at least 1 argument" },
        .{ .fixed = &.{ 0, 1, 3 }, .rest = 5, .want = "0, 1, 3 or at least 5 arguments" },
    }) |case| {
        const len = @as(usize, case.fixed[case.fixed.len - 1]) + 1;
        @memset(fixed[0..len], null);
        for (case.fixed) |n| fixed[n] = &members[n];
        const table: Arities = .{ .fixed = fixed[0..len], .rest = if (case.rest) |n| &rests[n] else null };
        linkTable(&table);
        var failure: VerifyFailure = undefined;
        try members[case.fixed[0]].verify(&failure);
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(case.want, try std.mem.print(&buf, "{f}", .{members[case.fixed[0]].arityPhrase()}));
    }
    // A routine with one arity says what `arityError` says.
    for ([_]struct { Routine, []const u8 }{
        .{ members[0], "0 arguments" },
        .{ members[1], "1 argument" },
        .{ rests[1], "at least 1 argument" },
        .{ rests[2], "at least 2 arguments" },
    }) |case| {
        var r = case[0];
        r.arities = null;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(case[1], try std.mem.print(&buf, "{f}", .{r.arityPhrase()}));
    }
    // Hidden leading parameters (a macro's `&form` and `&env`) are not
    // counted.
    for ([_]struct { Routine, []const u8 }{
        .{ members[2], "0 arguments" },
        .{ members[3], "1 argument" },
        .{ rests[4], "at least 2 arguments" },
    }) |case| {
        var r = case[0];
        r.arities = null;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings(case[1], try std.mem.print(&buf, "{f}", .{ArityPhrase{ .routine = &r, .hidden = 2 }}));
    }
    // Every other count up to 200: past the detail's 160 bytes, the
    // sentence is cut at a character and marked.
    @memset(&fixed, null);
    var i: usize = 0;
    while (i <= 200) : (i += 2) fixed[i] = &members[i];
    const table: Arities = .{ .fixed = &fixed };
    linkTable(&table);
    try testing.expectEqual(VmError.ArityMismatch, vm.closureArityError(&members[0], 1));
    try testing.expect(std.mem.startsWith(u8, vm.error_detail, "f takes 0, 2, 4, 6, "));
    try testing.expect(std.mem.endsWith(u8, vm.error_detail, "…"));
    try testing.expect(vm.error_detail.len <= vm.detail_buf.len);
}

test "Routine.verify: an arity table a call cannot pick from is refused" {
    const r = asm_.returnNil();
    var none = Routine{ .code = &.{r}, .consts = &.{}, .slot_count = 1, .name = "none" };
    var one = Routine{ .code = &.{r}, .consts = &.{}, .slot_count = 1, .fixed_arity = 1, .name = "one" };
    var two = Routine{ .code = &.{r}, .consts = &.{}, .slot_count = 2, .fixed_arity = 2, .name = "two" };
    var rest = Routine{ .code = &.{r}, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .variadic = true, .name = "rest" };
    var stray = Routine{ .code = &.{r}, .consts = &.{}, .slot_count = 2, .fixed_arity = 1, .name = "stray" };
    var fixed = [_]?*const Routine{ &none, &one };
    var table: Arities = .{ .fixed = &fixed, .rest = &rest };
    const other: Arities = .{ .fixed = &fixed, .rest = &rest };
    const Case = struct { name: []const u8, err: VmError, where: []const u8 };
    var failure: VerifyFailure = undefined;
    for ([_]Case{
        .{ .name = "a member at another arity's place", .err = VmError.BytecodeCorruption, .where = "one" },
        .{ .name = "a member its table does not hold", .err = VmError.BytecodeCorruption, .where = "stray" },
        .{ .name = "a member of another table", .err = VmError.BytecodeCorruption, .where = "one" },
        .{ .name = "members of unequal upvalue counts", .err = VmError.CaptureCountMismatch, .where = "one" },
        .{ .name = "a table ending in no clause", .err = VmError.BytecodeCorruption, .where = "one" },
        .{ .name = "a rest clause below a fixed arity", .err = VmError.BytecodeCorruption, .where = "one" },
        .{ .name = "a rest clause with no rest parameter", .err = VmError.BytecodeCorruption, .where = "one" },
        .{ .name = "a table of one", .err = VmError.BytecodeCorruption, .where = "one" },
        .{ .name = "a member that does not verify", .err = VmError.BytecodeExhausted, .where = "rest" },
    }, 0..) |case, i| {
        errdefer std.debug.print("table case \"{s}\" failed\n", .{case.name});
        var three: [3]?*const Routine = .{ &none, &one, null };
        table = .{ .fixed = &fixed, .rest = &rest };
        fixed = .{ &none, &one };
        linkTable(&table);
        stray.arities = &table;
        var checked: *const Routine = &one;
        switch (i) {
            0 => fixed = .{ &one, &none },
            1 => checked = &stray,
            2 => one.arities = &other,
            3 => rest.upvalue_count = 1,
            4 => table.fixed = &three,
            5 => {
                three[2] = &two;
                two.arities = &table;
                table.fixed = &three;
                rest.fixed_arity = 1;
            },
            6 => {
                rest.variadic = false;
                rest.fixed_arity = 3;
            },
            7 => {
                table.fixed = fixed[1..];
                table.rest = null;
                one.fixed_arity = 0;
            },
            8 => rest.code = &.{asm_.loadNil(0)},
            else => unreachable,
        }
        defer {
            rest = .{ .code = &.{r}, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .variadic = true, .name = "rest" };
            one.fixed_arity = 1;
        }
        try testing.expectError(case.err, checked.verify(&failure));
        try testing.expectEqualStrings(case.where, failure.routine.name);
    }
    // A sound table verifies from any member, and a member of a
    // table does from a top-level routine's descriptor.
    table = .{ .fixed = &fixed, .rest = &rest };
    fixed = .{ &none, &one };
    linkTable(&table);
    try none.verify(&failure);
    try rest.verify(&failure);
    const caps = [_]CaptureDescriptor{.{ .routine = &one, .sources = &.{} }};
    var top = makeRoutine(&.{ asm_.closureMake(0, 0), asm_.returnSlot(0) }, &.{}, 1, "top");
    top.capture_descs = &caps;
    try top.verify(&failure);
    rest.code = &.{asm_.loadNil(0)};
    try testing.expectError(VmError.BytecodeExhausted, top.verify(&failure));
    try testing.expectEqualStrings("rest", failure.routine.name);
}

test "VM dispatch: a member's constants live while the member runs and allocates under collection" {
    // (fn ([] nil) ([x] (dotimes [_ 1000] (list x)) "keep")): the string
    // is a constant of the one-argument member alone, which the
    // closure, naming the other member, reaches only through the table.
    var keep_consts = [_]Value{ nil_v, fx(0), fx(1000), fx(1) };
    var keep = Routine{
        .code = &.{
            asm_.loadConst(1, 1),
            asm_.cmpLt(2, sl(1), kn(2)),
            asm_.jumpIfFalse(6, sl(2)),
            asm_.coll(.list, 0, 1, 3),
            asm_.mathAdd(1, sl(1), kn(3)),
            asm_.jumpJmp(1),
            asm_.loadConst(4, 0),
            asm_.returnSlot(4),
        },
        .consts = &keep_consts,
        .slot_count = 5,
        .fixed_arity = 1,
        .name = "f",
    };
    var none = Routine{ .code = &.{asm_.returnNil()}, .consts = &.{}, .slot_count = 1, .name = "f" };
    const fixed = [_]?*const Routine{ &none, &keep };
    const table: Arities = .{ .fixed = &fixed };
    linkTable(&table);
    const caps = [_]CaptureDescriptor{.{ .routine = &none, .sources = &.{} }};
    var top = makeRoutine(&.{ asm_.closureMake(0, 0), asm_.loadConst(1, 0), asm_.callCall(0, 1, 2), asm_.returnSlot(2) }, &.{fx(5)}, 3, "top");
    top.capture_descs = &caps;
    var vm = try VM.init(testing.allocator, &top);
    defer vm.deinit();
    keep_consts[0] = try string_mod.fromBytes(vm.ensureHeap(), "keep");
    vm.setGcPolicy(.stress);
    try testing.expectEqualStrings("keep", string_mod.asBytes(try vm.run()));
    try testing.expect(vm.gc_cycles > 0);
}

/// `(fn f ([n] (if (< n 1) 0 (+ n (f (- n 1) n)))) ([n _] (f n)) ([n _ & _] (f n)))`:
/// every call switches arity through `call:self`, the rest clause's to
/// a fixed sibling.
const SelfClauses = struct {
    one: Routine = .{
        .code = &.{
            asm_.cmpLt(1, sl(0), kn(0)),
            asm_.jumpIfFalse(4, sl(1)),
            asm_.loadConst(1, 1),
            asm_.returnSlot(1),
            Inst.primary(.math, Math.sub, sl(2), sl(0), kn(0)),
            asm_.move(3, 0),
            asm_.callSelf(2, 2, 2),
            asm_.mathAdd(1, sl(0), sl(2)),
            asm_.returnSlot(1),
        },
        .consts = &.{ fx(1), fx(0) },
        .slot_count = 4,
        .fixed_arity = 1,
        .name = "f",
    },
    two: Routine = .{ .code = &.{ asm_.move(2, 0), asm_.callSelf(2, 1, 2), asm_.returnSlot(2) }, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .name = "f" },
    rest: Routine = .{ .code = &.{ asm_.move(3, 0), asm_.callSelf(3, 1, 3), asm_.returnSlot(3) }, .consts = &.{}, .slot_count = 4, .fixed_arity = 2, .variadic = true, .name = "f" },
    fixed: [3]?*const Routine = undefined,
    table: Arities = undefined,

    fn link(t: *SelfClauses) void {
        t.fixed = .{ null, &t.one, &t.two };
        t.table = .{ .fixed = &t.fixed, .rest = &t.rest };
        linkTable(&t.table);
    }
};

test "VM dispatch: call:self enters any fixed member of its routine's table, on the direct path and past it" {
    var t: SelfClauses = .{};
    t.link();
    // 10000 deep, so the frames and the stack outgrow their capacity
    // and the general handler takes the calls that grow them; entered
    // at each member.
    const caps = [_]CaptureDescriptor{.{ .routine = &t.one, .sources = &.{} }};
    const consts = [_]Value{ fx(10_000), fx(0) };
    for (1..4) |argc| {
        var code: [6]Inst = undefined;
        code[0] = asm_.closureMake(0, 0);
        for (0..argc) |i| code[1 + i] = asm_.loadConst(@intCast(1 + i), @min(i, 1));
        code[1 + argc] = asm_.callCall(0, @intCast(argc), 0);
        code[2 + argc] = asm_.returnSlot(0);
        var top = makeRoutine(code[0 .. 3 + argc], &consts, 4, "top");
        top.capture_descs = &caps;
        var vm = try VM.init(testing.allocator, &top);
        defer vm.deinit();
        try testing.expectEqual(fx(50_005_000), try vm.run());
        // One frame per call, two calls per step down.
        if (VM.track_high_water) try testing.expectEqual(20_002 + @as(usize, @intFromBool(argc > 1)), vm.frame_high_water);
    }
}

test "Routine.verify: call:self names a fixed member of the routine's table, never a count only the rest clause takes" {
    var t: SelfClauses = .{};
    t.link();
    var failure: VerifyFailure = undefined;
    try t.one.verify(&failure);
    // A count with no fixed member, and one only the rest clause takes.
    t.two.slot_count = 6;
    for ([_]u12{ 0, 3 }) |argc| {
        t.two.code = &.{ asm_.move(2, 0), asm_.callSelf(2, argc, 2), asm_.returnSlot(2) };
        try testing.expectError(VmError.BytecodeCorruption, t.one.verify(&failure));
        try testing.expectEqualStrings("f", failure.routine.name);
        try testing.expectEqual(@as(u32, 1), failure.pc);
    }
}
test "registerRecordType and registerProtocol free exactly what they took when an allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, registerTypeAndProtocol, .{});
}

fn registerTypeAndProtocol(allocator: std.mem.Allocator) !void {
    var vm = try VM.init(allocator, &VM.idle_routine);
    defer vm.deinit();
    _ = try vm.registerRecordType("user", "Point", &.{ "x", "y" });
    _ = try vm.registerProtocol("user", "Shape", &.{ .{ .name_id = 0, .name = "area" }, .{ .name_id = 1, .name = "scale" } });
}
