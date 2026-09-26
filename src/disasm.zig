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
//! The opcode names live in the tables below, one per dispatched
//! group, indexed by variant number. A test walks every variant
//! enum `vm.zig` defines and fails when a variant has no name here,
//! so an opcode cannot be added without one. The decoders are the
//! VM's own (`Inst`, `Operand`, `Group`); nothing here is consulted
//! while instructions execute.

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

/// Every group of VM.md §10 by number. A group the VM does not
/// dispatch still has a name so its instructions disassemble.
const group_names = [_][]const u8{
    "jump", "cmp", "math", "mov", "call", "closure", "var", "coll", "transient", "hash", "tx", "ctrl", "io", "simd",
};

const jump_names = [_]?[]const u8{ "jmp", "if-true", "if-false" };
const cmp_names = [_]?[]const u8{ "lt", "lte", "gt", "gte", "eq-num" };
const math_names = [_]?[]const u8{ "add", "sub", "mul", "div", "idiv", "mod", "pow", "neg", "abs" };
const mov_names = [_]?[]const u8{ "move", "load-const", "load-nil", "load-true", "load-false" };
const call_names = [_]?[]const u8{ "call", "tailcall", "return", "return-nil" };
const closure_names = [_]?[]const u8{ "make", "box-local", "new-cell", "init-cell", "get-cell" };
const var_names = [_]?[]const u8{ "load-var", "store-var", "var-object" };
const coll_names = [_]?[]const u8{ "list", "concat", "vector", "map", "set" };
const ctrl_names = [_]?[]const u8{ "try-enter", "try-exit", "finally-exit", "throw", null, "halt" };

/// The name of group number `group`, or null for a number outside
/// VM.md §10.
fn groupName(group: u6) ?[]const u8 {
    if (group >= group_names.len) return null;
    return group_names[group];
}

/// The name of `variant` within `group`, or null when the group
/// defines no such variant.
fn variantName(group: vm.Group, variant: u6) ?[]const u8 {
    const table: []const ?[]const u8 = switch (group) {
        .jump => &jump_names,
        .cmp => &cmp_names,
        .math => &math_names,
        .mov => &mov_names,
        .call => &call_names,
        .closure => &closure_names,
        .var_ => &var_names,
        .coll => &coll_names,
        .ctrl => &ctrl_names,
        .transient, .hash, .tx, .io, .simd => &.{},
        _ => &.{},
    };
    if (variant >= table.len) return null;
    return table[variant];
}

/// Whether operand B of an instruction is a raw immediate (VM.md
/// §4.5): an argument count whose kind bits the handler ignores.
fn immediateB(group: vm.Group, variant: u6) bool {
    return switch (group) {
        .call => variant == @intFromEnum(vm.Call.call) or variant == @intFromEnum(vm.Call.tailcall),
        .coll => true,
        else => false,
    };
}

/// What an instruction's wide field names (VM.md §3), or null when
/// it has operands B and C instead.
const Wide = enum { pc, constant, var_, capture, try_ };

fn wideField(group: vm.Group, variant: u6) ?Wide {
    return switch (group) {
        .jump => .pc,
        .ctrl => switch (@as(vm.CtrlOp, @enumFromInt(variant))) {
            .try_enter => .try_,
            .try_exit => .pc,
            else => null,
        },
        .mov => if (variant == @intFromEnum(vm.Mov.load_const)) .constant else null,
        .var_ => .var_,
        .closure => if (variant == @intFromEnum(vm.Closure_.make)) .capture else null,
        else => null,
    };
}

// =============================================================================
// Printing
// =============================================================================

/// Disassemble `routine` and, after it, every routine its capture
/// descriptors build, depth first. `interner` names keywords,
/// symbols and Vars; a null interner prints them by id.
pub fn disassemble(routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
    try disassembleRoutine(routine, interner, writer);
    for (routine.capture_descs) |d| {
        try writer.writeAll("\n");
        try disassemble(d.routine, interner, writer);
    }
}

/// One routine: a header line, then one line per instruction.
///
///   routine NAME (PATH:LINE:COL) slots=N arity=A upvalues=U
///     0000  mov:load-const  s1  c0=42  -   ; 4:9
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
        const group: vm.Group = @enumFromInt(inst.group);
        try writeOperand(inst.a, routine, interner, false, writer);
        try writer.writeAll("  ");
        if (wideField(group, inst.variant)) |wide| {
            try writeWide(wide, inst.wide(), routine, interner, writer);
        } else {
            try writeOperand(inst.b, routine, interner, immediateB(group, inst.variant), writer);
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

/// `group:variant`, padded to a column; an unnamed group or variant
/// prints its number after `?`.
fn writeOpcode(inst: vm.Inst, writer: *Writer) Writer.Error!void {
    var buf: [32]u8 = undefined;
    var fixed = Writer.fixed(&buf);
    if (groupName(inst.group)) |g| {
        fixed.writeAll(g) catch unreachable;
    } else {
        fixed.print("?{d}", .{inst.group}) catch unreachable;
    }
    fixed.writeAll(":") catch unreachable;
    const group: vm.Group = @enumFromInt(inst.group);
    if (variantName(group, inst.variant)) |v| {
        fixed.writeAll(v) catch unreachable;
    } else {
        fixed.print("?{d}", .{inst.variant}) catch unreachable;
    }
    const text = fixed.buffered();
    try writer.writeAll(text);
    var pad: usize = text.len;
    while (pad < 18) : (pad += 1) try writer.writeAll(" ");
}

/// A wide field: a pc as `jNNNN`, a constant as `cN=value`, a Var
/// as `vN=name`, a try as `#N<catch jNNNN finally jNNNN>`, and a
/// capture descriptor as `#N<routine NAME>[...]` with where each
/// captured cell comes from, `sN` for a cell in this frame's slot N
/// and `uN` for this closure's upvalue N (VM.md §6).
fn writeWide(wide: Wide, w: u32, routine: *const vm.Routine, interner: ?*const intern_mod.Interner, writer: *Writer) Writer.Error!void {
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
            try writer.print("<routine {s}>[", .{desc.routine.name});
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
    if (index < routine.var_table.len) try writer.print("={s}", .{routine.var_table[index].name});
}

/// One operand: its kind letter and index, then what the index
/// names when the routine can say (`c0=42`, `v1=inc`); `-` for an
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
    var cut = std.mem.lastIndexOfScalar(u8, text[0..max_constant_width], ' ') orelse max_constant_width;
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

test "every group the VM defines has a name" {
    inline for (@typeInfo(vm.Group).@"enum".fields) |field| {
        const g: vm.Group = @enumFromInt(field.value);
        const name = groupName(@intFromEnum(g)) orelse return error.TestFailed;
        // `var_` is spelled `var` in bytecode listings; every other
        // group name is its tag.
        const expected = if (g == .var_) "var" else field.name;
        try testing.expectEqualStrings(expected, name);
    }
    try testing.expect(groupName(group_names.len) == null);
}

/// Every named variant of each dispatched group's enum has a name,
/// and the tables name nothing the enums do not define.
fn expectVariantsNamed(comptime E: type, group: vm.Group) !void {
    var highest: u6 = 0;
    inline for (@typeInfo(E).@"enum".fields) |field| {
        const v: u6 = @intCast(field.value);
        try testing.expect(variantName(group, v) != null);
        if (v > highest) highest = v;
    }
    var v: u6 = 0;
    while (v <= highest) : (v += 1) {
        const defined = std.enums.tagName(E, @as(E, @enumFromInt(v))) != null;
        try testing.expectEqual(defined, variantName(group, v) != null);
    }
    try testing.expect(variantName(group, highest + 1) == null);
}

test "every variant of every dispatched group has a name, and nothing else does" {
    try expectVariantsNamed(vm.Jump, .jump);
    try expectVariantsNamed(vm.Cmp, .cmp);
    try expectVariantsNamed(vm.Math, .math);
    try expectVariantsNamed(vm.Mov, .mov);
    try expectVariantsNamed(vm.Call, .call);
    try expectVariantsNamed(vm.Closure_, .closure);
    try expectVariantsNamed(vm.VarOp, .var_);
    try expectVariantsNamed(vm.CollOp, .coll);
    try expectVariantsNamed(vm.CtrlOp, .ctrl);
    try testing.expect(variantName(.transient, 0) == null);
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
        .{ .kind = .primary, .group = @intFromEnum(vm.Group.math), .variant = 20, .a = vm.Operand.slot(0), .b = vm.Operand.none, .c = vm.Operand.none },
        .{ .kind = .primary, .group = 40, .variant = 1, .a = vm.Operand.none, .b = vm.Operand.none, .c = vm.Operand.none },
    };
    const routine = vm.Routine{ .code = &code, .consts = &.{}, .slot_count = 1, .name = "t" };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try disassemble(&routine, null, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "math:?20") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "?40:?1") != null);
}
