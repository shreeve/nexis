//! disasm.zig — bytecode disassembler (docs/TOOLING.md §2).
//!
//! Prints a `Routine` one instruction per line, then every routine
//! its capture descriptors build the same way, so `nexis disasm
//! FILE.nx` shows a file as the VM sees it: pc, `group:variant`,
//! the operands with their kind letters (VM.md §4), or operand A and
//! the wide field (VM.md §3), constants as `pr-str` prints them, jump
//! targets as pcs, and the span table (VM.md §5) as `; line:col`
//! annotations where the span changes.
//!
//! The opcode names are the tags of `vm.zig`'s group and variant
//! enums, and what each operand is comes from the verifier's
//! `Routine.shapeOf`, so a new opcode needs nothing here. Nothing here
//! is consulted while instructions execute.

const std = @import("std");
const vm = @import("vm.zig");
const value_mod = @import("value.zig");
const format_mod = @import("format.zig");
const intern_mod = @import("intern.zig");
const heap_mod = @import("heap.zig");
const vector_mod = @import("coll/vector.zig");
const list_mod = @import("coll/list.zig");
const champ_mod = @import("coll/champ.zig");

const Writer = std.Io.Writer;

// =============================================================================
// Names
// =============================================================================

/// The name of group number `group`, or null for a number outside
/// VM.md §10.
fn groupName(group: u6) ?[]const u8 {
    return tagName(vm.Group, group);
}

/// The name of `variant` within `group`, or null when the group
/// defines no such variant.
fn variantName(group: vm.Group, variant: u6) ?[]const u8 {
    return switch (group) {
        .jump => tagName(vm.Jump, variant),
        .cmp => tagName(vm.Cmp, variant),
        .math => tagName(vm.Math, variant),
        .mov => tagName(vm.Mov, variant),
        .call => tagName(vm.Call, variant),
        .closure => tagName(vm.Closure_, variant),
        .var_ => tagName(vm.VarOp, variant),
        .coll => tagName(vm.CollOp, variant),
        .ctrl => tagName(vm.CtrlOp, variant),
        else => null,
    };
}

/// The tag of `E` numbered `n` as bytecode spells it: `-` for `_`,
/// without a trailing `_` (`eq-num`, `self`, `var`).
fn tagName(comptime E: type, n: u6) ?[]const u8 {
    const info = @typeInfo(E).@"enum";
    inline for (info.field_names, info.field_values) |name, value| if (value == n) return comptime spelled(name);
    return null;
}

fn spelled(comptime tag: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, tag, "_");
    var buf: [trimmed.len]u8 = trimmed[0..trimmed.len].*;
    std.mem.replaceScalar(u8, &buf, '_', '-');
    const name = buf;
    return &name;
}

// =============================================================================
// Printing
// =============================================================================

/// Disassemble `routine`, every member of its arity table by arity
/// with the rest clause last, and after them every routine their
/// capture descriptors build, depth first. `interner` names keywords,
/// symbols and Vars; a null interner prints them by id.
pub fn disassemble(routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    const a = routine.arities orelse {
        try disassembleRoutine(routine, interner, writer);
        return disassembleCaptured(routine, interner, writer);
    };
    var members = a.members();
    var first = true;
    while (members.next()) |m| : (first = false) {
        if (!first) try writer.writeAll("\n");
        try disassembleRoutine(m, interner, writer);
    }
    members = a.members();
    while (members.next()) |m| try disassembleCaptured(m, interner, writer);
}

fn disassembleCaptured(routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    for (routine.capture_descs) |d| {
        try writer.writeAll("\n");
        try disassemble(d.routine, interner, writer);
    }
}

/// One routine: a header line, then one line per instruction.
///
///   routine NAME (PATH:LINE:COL) slots=N arity=A upvalues=U
///     0000  mov:load-const  s1  c0=42  ; 4:9
fn disassembleRoutine(routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    try writer.print("routine {s}", .{routine.name});
    if (routine.source) |src| {
        if (routine.origin) |origin| {
            const loc = src.lineCol(origin.pos);
            try writer.print(" ({s}:{d}:{d})", .{ src.path, loc.line, loc.col });
        } else {
            try writer.print(" ({s})", .{src.path});
        }
    }
    try writer.print(" slots={d} arity={d}", .{ routine.slot_count, routine.fixed_arity });
    if (routine.variadic) try writer.writeAll("+rest");
    try writer.print(" upvalues={d}\n", .{routine.upvalue_count});

    var last_span: ?vm.SourceSpan = null;
    for (routine.code, 0..) |inst, pc| {
        try writer.print("  {d:0>4}  ", .{pc});
        try writeOpcode(inst, writer);
        try writer.writeAll("  ");
        const shape = vm.Routine.shapeOf(vm.VM.opIndex(inst)) orelse vm.Routine.Shape{};
        try writeOperand(inst.a, routine, interner, false, writer);
        try writer.writeAll("  ");
        if (shape.wide) |wide| {
            try writeWide(wide, inst.wide(), routine, interner, writer);
        } else {
            try writeOperand(inst.b, routine, interner, shape.b == .raw, writer);
            try writer.writeAll("  ");
            try writeOperand(inst.c, routine, interner, false, writer);
        }
        if (routine.spanAt(@intCast(pc))) |span| {
            const changed = last_span == null or last_span.?.pos != span.pos or last_span.?.len != span.len;
            if (changed) {
                if (routine.source) |src| {
                    const loc = src.lineCol(span.pos);
                    try writer.print("  ; {d}:{d}", .{ loc.line, loc.col });
                } else {
                    try writer.print("  ; @{d}+{d}", .{ span.pos, span.len });
                }
                last_span = span;
            }
        }
        try writer.writeAll("\n");
    }
}

/// What a quickened variant's name adds to its base's: the operand
/// kinds it proves (`s` a slot, `c` a fixnum constant, `u` an
/// upvalue), and the comparison a step runs with it and the jump a
/// comparison runs (`math:add.sc+lt.ss+if-true`).
fn writeQuickSuffix(q: vm.Quick, writer: *Writer) Writer.Error!void {
    const c = vm.Quick.stepCmp(q) orelse return writer.writeAll(formSuffix(q));
    try writer.print("{s}+{s}{s}", .{ formSuffix(.{ .base = q.base, .form = q.form }), variantName(.cmp, c.base).?, formSuffix(c) });
}

fn formSuffix(q: vm.Quick) []const u8 {
    return switch (q.form) {
        .slot => ".s",
        .upvalue => ".u",
        .fixnum_slot => ".cs",
        .slot_slot => switch (q.then) {
            .none => ".ss",
            .if_true => ".ss+if-true",
            .if_false => ".ss+if-false",
        },
        .slot_fixnum => switch (q.then) {
            .none => ".sc",
            .if_true => ".sc+if-true",
            .if_false => ".sc+if-false",
        },
    };
}

/// `group:variant`, padded to a column, a quickened variant as its
/// base's name and its suffix (`math:add.sc`); an unnamed group or
/// variant prints its number after `?`.
fn writeOpcode(inst: vm.Inst, writer: *Writer) Writer.Error!void {
    var buf: [32]u8 = undefined;
    try writer.print("{s: <18}", .{opcodeName(vm.VM.opIndex(inst), &buf)});
}

/// The name of the opcode at index `op` (group | variant << 6), in
/// `buf`: `group:variant`, a quickened variant as its base's name and
/// its suffix (`math:add.sc`), and `?N` for what the tables do not
/// name. The CLI's `-Dopcodes` histogram names its rows with it.
pub fn opcodeName(op: u12, buf: []u8) []const u8 {
    var fixed = Writer.fixed(buf);
    const group_bits: u6 = @truncate(op);
    const variant: u6 = @truncate(op >> 6);
    if (groupName(group_bits)) |g| {
        fixed.writeAll(g) catch return "?";
    } else {
        fixed.print("?{d}", .{group_bits}) catch return "?";
    }
    fixed.writeAll(":") catch return "?";
    const group: vm.Group = @fromBackingInt(group_bits);
    const quick = vm.Quick.of(op);
    if (variantName(group, if (quick) |q| q.base else variant)) |v| {
        fixed.writeAll(v) catch return "?";
        if (quick) |q| writeQuickSuffix(q, &fixed) catch return "?";
    } else {
        fixed.print("?{d}", .{variant}) catch return "?";
    }
    return fixed.buffered();
}

/// A wide field: a pc as `jNNNN`, a constant as `cN=value`, a Var
/// as `vN=name`, a try as `#N<catch jNNNN finally jNNNN>`, and a
/// capture descriptor as `#N<routine NAME>[...]` with where each
/// captured cell comes from, `sN` for a cell in this frame's slot N
/// and `uN` for this closure's upvalue N (VM.md §6).
fn writeWide(wide: vm.Routine.WideRole, w: u32, routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    switch (wide) {
        .pc => try writer.print("j{d:0>4}", .{w}),
        .constant => try writeConst(w, routine, interner, writer),
        .var_ => try writeVar(w, routine, writer),
        .try_ => {
            try writer.print("#{d}", .{w});
            if (w >= routine.tries.len) return;
            const t = routine.tries[w];
            try writer.print("<catch j{d:0>4}", .{t.catch_pc});
            if (t.finally_pc) |f| try writer.print(" finally j{d:0>4}", .{f});
            try writer.writeAll(">");
        },
        .capture => {
            try writer.print("#{d}", .{w});
            if (w >= routine.capture_descs.len) return;
            const desc = routine.capture_descs[w];
            try writer.print("<routine {s}", .{desc.routine.name});
            if (desc.routine.arities) |a| {
                try writer.writeAll(" arities ");
                var members = a.members();
                var first = true;
                while (members.next()) |m| : (first = false) {
                    if (!first) try writer.writeAll(",");
                    try writer.print("{d}{s}", .{ m.fixed_arity, if (m.variadic) "+rest" else "" });
                }
            }
            try writer.writeAll(">[");
            for (desc.sources, 0..) |source, i| {
                if (i > 0) try writer.writeAll(" ");
                switch (source) {
                    .local_cell_slot => |slot| try writer.print("s{d}", .{slot}),
                    .inherited_upvalue => |u| try writer.print("u{d}", .{u}),
                }
            }
            try writer.writeAll("]");
        },
    }
}

fn writeConst(index: u32, routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    try writer.print("c{d}", .{index});
    if (index >= routine.consts.len) return;
    try writer.writeAll("=");
    try writeConstant(routine.consts[index], interner, writer);
}

fn writeVar(index: u32, routine: *const vm.Routine, writer: *Writer) Writer.Error!void {
    try writer.print("v{d}", .{index});
    if (index >= routine.var_table.len) return;
    // Qualified, so two namespaces' Vars of one name read apart.
    const v = routine.var_table[index];
    if (v.ns.len > 0) try writer.print("={s}/{s}", .{ v.ns, v.name }) else try writer.print("={s}", .{v.name});
}

/// One operand: its kind letter and index, then what the index
/// names when the routine can say (`c0=42`, `v1=nexis.core/inc`); `-` for an
/// unused operand, `#n` for a raw immediate.
fn writeOperand(op: vm.Operand, routine: *const vm.Routine, interner: ?*const intern_mod.Interner, immediate: bool, writer: *Writer) Writer.Error!void {
    if (immediate) {
        try writer.print("#{d}", .{op.index});
        return;
    }
    switch (op.kind) {
        .slot => try writer.print("s{d}", .{op.index}),
        .constant => try writeConst(op.index, routine, interner, writer),
        .var_ => try writeVar(op.index, routine, writer),
        .upvalue => try writer.print("u{d}", .{op.index}),
        .intern => try writer.print("i{d}", .{op.index}),
        .durable => try writer.print("e{d}", .{op.index}),
        .unused => try writer.writeAll("-"),
        _ => try writer.print("?{d}", .{op.index}),
    }
}

/// The most bytes of a constant's printed form a listing shows.
const max_constant_width = 60;

/// `v` as `pr-str` prints it, cut at a space within
/// `max_constant_width` bytes when longer, then ` ...` and, for a
/// collection, its item count: a large literal is one constant
/// (COMPILER.md §4.4) and stays one readable line.
fn writeConstant(v: value_mod.Value, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    var buf: [max_constant_width + 1]u8 = undefined;
    var fixed = Writer.fixed(&buf);
    format_mod.format(v, .readable, &fixed, interner) catch |err| switch (err) {
        error.WriteFailed => {},
        error.Utf8Error => return writer.writeAll("#<invalid utf-8>"),
    };
    const text = fixed.buffered();
    if (text.len <= max_constant_width) return writer.writeAll(text);
    var cut = std.mem.findScalarLast(u8, text[0..max_constant_width], ' ') orelse max_constant_width;
    while (cut > 0 and text[cut] & 0xC0 == 0x80) cut -= 1;
    try writer.print("{s} ...", .{text[0..cut]});
    const items: ?usize = switch (v.kind()) {
        .list => list_mod.count(v),
        .persistent_vector => vector_mod.count(v),
        .persistent_map => champ_mod.mapCount(v),
        .persistent_set => champ_mod.setCount(v),
        else => null,
    };
    if (items) |n| try writer.print("({d} items)", .{n});
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "every group and variant is named as bytecode spells it" {
    try testing.expectEqualStrings("var", groupName(@backingInt(vm.Group.var_)).?);
    try testing.expect(groupName(14) == null);
    try testing.expectEqualStrings("eq-num", variantName(.cmp, @backingInt(vm.Cmp.eq_num)).?);
    try testing.expectEqualStrings("return", variantName(.call, @backingInt(vm.Call.@"return")).?);
    try testing.expectEqualStrings("self", variantName(.call, @backingInt(vm.Call.self_)).?);
    try testing.expectEqualStrings("halt", variantName(.ctrl, @backingInt(vm.CtrlOp.halt_)).?);
    try testing.expect(variantName(.ctrl, 4) == null);
    try testing.expect(variantName(.simd, 0) == null);
}

test "a listing shows every operand kind, immediates, constants and wide fields" {
    const consts = [_]value_mod.Value{ value_mod.fromFixnum(42).?, value_mod.nilValue() };
    const code = [_]vm.Inst{
        vm.asm_.loadConst(0, 0),
        vm.asm_.mathAdd(1, vm.Operand.slot(0), vm.Operand.constant(0)),
        vm.asm_.jumpIfFalse(70_000, vm.Operand.slot(1)),
        vm.asm_.callCall(0, 2, 3),
        vm.asm_.moveFrom(2, vm.Operand.upvalue(0)),
        vm.asm_.loadConst(0, 1),
        vm.asm_.tryEnter(0, 2),
        vm.asm_.tryEnter(1, 2),
        vm.asm_.tryExit(11),
        vm.asm_.jumpJmp(3),
        vm.asm_.returnSlot(1),
    };
    const tries = [_]vm.Try{ .{ .catch_pc = 9 }, .{ .catch_pc = 8, .finally_pc = 10 } };
    const routine = vm.Routine{ .code = &code, .consts = &consts, .tries = &tries, .slot_count = 4, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine t slots=4 arity=0 upvalues=0
        \\  0000  mov:load-const      s0  c0=42
        \\  0001  math:add            s1  s0  c0=42
        \\  0002  jump:if-false       s1  j70000
        \\  0003  call:call           s0  #2  s3
        \\  0004  mov:move            s2  u0  -
        \\  0005  mov:load-const      s0  c1=nil
        \\  0006  ctrl:try-enter      s2  #0<catch j0009>
        \\  0007  ctrl:try-enter      s2  #1<catch j0008 finally j0010>
        \\  0008  ctrl:try-exit       -  j0011
        \\  0009  jump:jmp            -  j0003
        \\  0010  call:return         s1  -  -
        \\
    , out.written());
}

test "a quickened instruction shows its base's name, its form and its operands" {
    const consts = [_]value_mod.Value{value_mod.fromFixnum(1).?};
    var code = [_]vm.Inst{
        vm.asm_.mathAdd(0, vm.Operand.slot(0), vm.Operand.constant(0)),
        vm.asm_.mathAdd(0, vm.Operand.slot(0), vm.Operand.slot(1)),
        vm.asm_.cmpLt(1, vm.Operand.slot(0), vm.Operand.slot(2)),
        vm.asm_.jumpIfTrue(0, vm.Operand.slot(1)),
        vm.asm_.cmpLt(1, vm.Operand.slot(0), vm.Operand.constant(0)),
        vm.asm_.move(2, 0),
        vm.Inst.primary(.math, vm.Math.mul, vm.Operand.slot(2), vm.Operand.constant(0), vm.Operand.slot(1)),
        vm.asm_.moveFrom(2, vm.Operand.upvalue(0)),
        vm.asm_.returnSlot(2),
    };
    vm.quicken(&code, &consts);
    const routine = vm.Routine{ .code = &code, .consts = &consts, .slot_count = 3, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine t slots=3 arity=0 upvalues=0
        \\  0000  math:add.sc         s0  s0  c0=1
        \\  0001  math:add.ss         s0  s0  s1
        \\  0002  cmp:lt.ss+if-true   s1  s0  s2
        \\  0003  jump:if-true        s1  j0000
        \\  0004  cmp:lt.sc           s1  s0  c0=1
        \\  0005  mov:move.s          s2  s0  -
        \\  0006  math:mul.cs         s2  c0=1  s1
        \\  0007  mov:move.u          s2  u0  -
        \\  0008  call:return.s       s2  -  -
        \\
    , out.written());
}

test "a counting loop's step shows the comparison and the jump it runs" {
    const consts = [_]value_mod.Value{ value_mod.fromFixnum(1).?, value_mod.fromFixnum(10).? };
    var code = [_]vm.Inst{
        vm.asm_.mathAdd(0, vm.Operand.slot(0), vm.Operand.constant(0)),
        vm.Inst.primary(.cmp, vm.Cmp.gte, vm.Operand.slot(1), vm.Operand.slot(0), vm.Operand.constant(1)),
        vm.asm_.jumpIfFalse(0, vm.Operand.slot(1)),
        vm.asm_.mathAdd(0, vm.Operand.slot(0), vm.Operand.constant(0)),
        vm.asm_.cmpLt(1, vm.Operand.slot(0), vm.Operand.slot(2)),
        vm.asm_.jumpIfTrue(3, vm.Operand.slot(1)),
        vm.asm_.returnSlot(0),
    };
    vm.quicken(&code, &consts);
    const routine = vm.Routine{ .code = &code, .consts = &consts, .slot_count = 3, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine t slots=3 arity=0 upvalues=0
        \\  0000  math:add.sc+gte.sc+if-false  s0  s0  c0=1
        \\  0001  cmp:gte.sc+if-false  s1  s0  c1=10
        \\  0002  jump:if-false       s1  j0000
        \\  0003  math:add.sc+lt.ss+if-true  s0  s0  c0=1
        \\  0004  cmp:lt.ss+if-true   s1  s0  s2
        \\  0005  jump:if-true        s1  j0003
        \\  0006  call:return.s       s0  -  -
        \\
    , out.written());
}

test "closure:make lists its routine and where each captured cell comes from, then the routine" {
    const inner = vm.Routine{ .code = &.{vm.asm_.returnSlot(0)}, .consts = &.{}, .slot_count = 1, .name = "f", .upvalue_count = 2 };
    const sources = [_]vm.CaptureSource{ .{ .local_cell_slot = 3 }, .{ .inherited_upvalue = 1 } };
    const descs = [_]vm.CaptureDescriptor{ .{ .routine = &inner, .sources = &.{} }, .{ .routine = &inner, .sources = &sources } };
    const code = [_]vm.Inst{ vm.asm_.closureMake(0, 1), vm.asm_.closureMake(1, 2) };
    const routine = vm.Routine{ .code = &code, .consts = &.{}, .capture_descs = &descs, .slot_count = 4, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassembleRoutine(&routine, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine t slots=4 arity=0 upvalues=0
        \\  0000  closure:make        s1  #0<routine f>[]
        \\  0001  closure:make        s2  #1<routine f>[s3 u1]
        \\
    , out.written());
}

test "a multi-arity fn lists every member by arity, the rest clause last, then what they build" {
    const inner = vm.Routine{ .code = &.{vm.asm_.returnNil()}, .consts = &.{}, .slot_count = 1, .name = "g" };
    const descs = [_]vm.CaptureDescriptor{.{ .routine = &inner, .sources = &.{} }};
    var rest = vm.Routine{ .code = &.{vm.asm_.returnSlot(2)}, .consts = &.{}, .slot_count = 3, .fixed_arity = 2, .variadic = true, .name = "f" };
    var one = vm.Routine{ .code = &.{ vm.asm_.closureMake(0, 1), vm.asm_.returnSlot(1) }, .consts = &.{}, .capture_descs = &descs, .slot_count = 2, .fixed_arity = 1, .name = "f" };
    var none = vm.Routine{ .code = &.{vm.asm_.returnNil()}, .consts = &.{}, .slot_count = 1, .name = "f" };
    const fixed = [_]?*const vm.Routine{ &none, &one };
    const table = vm.Arities{ .fixed = &fixed, .rest = &rest };
    inline for (.{ &rest, &one, &none }) |m| m.arities = &table;
    const top_descs = [_]vm.CaptureDescriptor{.{ .routine = &one, .sources = &.{} }};
    const top = vm.Routine{ .code = &.{ vm.asm_.closureMake(0, 0), vm.asm_.returnSlot(0) }, .consts = &.{}, .capture_descs = &top_descs, .slot_count = 1, .name = "<top>" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&top, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine <top> slots=1 arity=0 upvalues=0
        \\  0000  closure:make        s0  #0<routine f arities 0,1,2+rest>[]
        \\  0001  call:return         s0  -  -
        \\
        \\routine f slots=1 arity=0 upvalues=0
        \\  0000  call:return-nil     -  -  -
        \\
        \\routine f slots=2 arity=1 upvalues=0
        \\  0000  closure:make        s1  #0<routine g>[]
        \\  0001  call:return         s1  -  -
        \\
        \\routine f slots=3 arity=2+rest upvalues=0
        \\  0000  call:return         s2  -  -
        \\
        \\routine g slots=1 arity=0 upvalues=0
        \\  0000  call:return-nil     -  -  -
        \\
    , out.written());
}

test "a span table annotates the line and column where it changes" {
    const text = "(+ 1\n   2)";
    const info = vm.SourceInfo{ .path = "t.nx", .text = text };
    const code = [_]vm.Inst{ vm.asm_.loadNil(0), vm.asm_.loadNil(0), vm.asm_.returnSlot(0) };
    const spans = [_]vm.SpanEntry{ .{ .pc = 0, .span = .{ .pos = 1, .len = 3 } }, .{ .pc = 2, .span = .{ .pos = 8, .len = 1 } } };
    const routine = vm.Routine{ .code = &code, .consts = &.{}, .slot_count = 1, .name = "t", .spans = &spans, .origin = .{ .pos = 1, .len = 8 }, .source = &info };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine t (t.nx:1:2) slots=1 arity=0 upvalues=0
        \\  0000  mov:load-nil        s0  -  -  ; 1:2
        \\  0001  mov:load-nil        s0  -  -
        \\  0002  call:return         s0  -  -  ; 2:4
        \\
    , out.written());
}

test "a large constant prints as its first 60 bytes and its item count" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var items: [5000]value_mod.Value = undefined;
    for (&items, 0..) |*item, i| item.* = value_mod.fromFixnum(@intCast(i)).?;
    const consts = [_]value_mod.Value{ try vector_mod.fromSlice(&heap, &items), try vector_mod.fromSlice(&heap, items[0..3]) };
    const code = [_]vm.Inst{ vm.asm_.loadConst(0, 0), vm.asm_.loadConst(0, 1) };
    const routine = vm.Routine{ .code = &code, .consts = &consts, .slot_count = 1, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expectEqualStrings(
        \\routine t slots=1 arity=0 upvalues=0
        \\  0000  mov:load-const      s0  c0=[0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 ...(5000 items)
        \\  0001  mov:load-const      s0  c1=[0 1 2]
        \\
    , out.written());
}

test "an unnamed variant or group prints its number" {
    const code = [_]vm.Inst{
        .{ .kind = .primary, .group = @backingInt(vm.Group.math), .variant = 63, .a = vm.Operand.slot(0), .b = vm.Operand.none, .c = vm.Operand.none },
        .{ .kind = .primary, .group = 40, .variant = 1, .a = vm.Operand.none, .b = vm.Operand.none, .c = vm.Operand.none },
    };
    const routine = vm.Routine{ .code = &code, .consts = &.{}, .slot_count = 1, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expect(std.mem.find(u8, out.written(), "math:?63") != null);
    try testing.expect(std.mem.find(u8, out.written(), "?40:?1") != null);
}
