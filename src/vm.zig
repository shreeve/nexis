//! vm.zig — Phase 2 VM kernel (first implementation commit).
//!
//! Authoritative spec: `docs/VM.md`. Adapted from `../em/src/{bytecode,
//! runtime}.zig` per the user's latitude to lift + modify em freely.
//!
//! **This commit lands the skeleton only.** Coverage here:
//!
//!   - 64-bit instruction encoding + operand packing (VM.md §3, §4).
//!   - `Routine` (compiled code + constants; plain Zig struct, not a
//!     heap Value yet — heap-kind promotion lands with closures).
//!   - `Frame` (slots + pc + routine pointer); single-frame runtime
//!     for this commit. Multi-frame comes with the `call` opcode
//!     in a subsequent commit.
//!   - `VM` with two-level-switch dispatch (per em; tail-call-threaded
//!     upgrade is deferred).
//!   - 5 opcodes: `mov:load-const`, `mov:move`, `mov:load-nil`,
//!     `mov:load-true`, `mov:load-false`, `call:return`.
//!   - Hand-assembled bytecode tests.
//!
//! What this commit does NOT do:
//!
//!   - No compiler. Bytecode is hand-assembled in tests.
//!   - No `call:call` / `call:tailcall`. Only `call:return` (which
//!     halts the VM with the top-of-frame result slot).
//!   - No closures, no upvalues. Routines run directly; no wrapping.
//!   - No `coll:*`, no `math:*`, no `jump:*`. Those land as
//!     discrete commits per COMPILER.md §10.
//!   - No GC integration yet. Frames + routines use caller-supplied
//!     allocator directly.
//!
//! Implementation sequence recap (COMPILER.md §10):
//!   1. VM kernel (this commit) ← we are here
//!   2. Tiny compiler for (+ 1 2) with math:add
//!   3. Conditionals (jump:*, if lowering)
//!   4. Locals + let*
//!   5. Functions + closures
//!   6. recur + loop*
//!   7. Vars + def
//!   8. Macroexpand + syntax-quote + #%anon-fn
//!   9. try/catch/throw
//!  10. Error-reporting hardening
//!  11. Golden + eval tests

const std = @import("std");
const value_mod = @import("value");
const Value = value_mod.Value;

// =============================================================================
// Instruction encoding (VM.md §3 + §4)
//
// Primary instruction: 64 bits
//   [kind:4][group:6][variant:6][opA:16][opB:16][opC:16]
//
// Each operand is 16 bits: [kind:4][index:12].
//
// Packed structs keep the Zig layout byte-exact across platforms.
// =============================================================================

pub const OpKind = enum(u4) {
    /// S — frame-local slot.
    slot = 0,
    /// C — routine's constant pool.
    constant = 1,
    /// V — namespace Var. Not exercised until the `var` group lands.
    var_ = 2,
    /// U — closure upvalue. Not exercised until closures land.
    upvalue = 3,
    /// I — intern id (keyword/symbol). Not exercised yet.
    intern = 4,
    /// J — bytecode offset (jump target). Used by `jump:*` group.
    jump = 5,
    /// E — durable ref literal. Phase 4 (`tx:*`).
    durable = 6,
    // 7..14 reserved.
    /// Sentinel for "no operand".
    unused = 15,
    /// Non-exhaustive marker: bytecode from a future nexis may
    /// use operand kinds this VM doesn't recognize. Dispatch code
    /// catches those via `_` prong and surfaces BytecodeCorruption.
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
    pub fn jump(i: u12) Operand {
        return .{ .kind = .jump, .index = i };
    }
};

/// Instruction kind discriminator — primary vs extension (per PLAN
/// §12.1). Extension packs 20-bit operand indices for programs that
/// exceed the 12-bit primary-operand range. Extension is NOT
/// implemented in this commit — the `ext` encoding remains reserved.
pub const InstKind = enum(u4) {
    primary = 0,
    extension = 1,
    _,
};

/// Opcode group (6 bits). Full v1 taxonomy per PLAN §12.3 and
/// VM.md §10. Only `mov` and `call` have implemented variants in
/// this commit.
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

/// Variants for the `mov` group. Extends as the compiler grows.
pub const Mov = enum(u6) {
    move = 0,
    load_const = 1,
    load_nil = 2,
    load_true = 3,
    load_false = 4,
    // load_fixnum_inline, load_keyword, load_symbol — later.
    _,
};

/// Variants for the `call` group.
pub const Call = enum(u6) {
    call = 0,
    tailcall = 1,
    @"return" = 2,
    return_nil = 3,
    // apply, invoke_var — later.
    _,
};

/// Packed 64-bit instruction. Field order matches PLAN §12.1:
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
            .group = @intFromEnum(g),
            .variant = @intCast(@intFromEnum(v)),
            .a = a,
            .b = b,
            .c = c,
        };
    }

    pub fn groupOf(self: Inst) Group {
        return @enumFromInt(self.group);
    }
};

comptime {
    std.debug.assert(@sizeOf(Inst) == 8);
    std.debug.assert(@sizeOf(Operand) == 2);
}

// =============================================================================
// Routine (VM.md §5)
//
// For this commit Routine is a plain Zig struct. Once the `fn*`
// lowering + closures land, routines will be wrapped in a heap
// Value of kind 22 (VALUE.md §2.2 `function`).
// =============================================================================

pub const Routine = struct {
    /// Bytecode instructions.
    code: []const Inst,
    /// Per-routine constant pool. Constant operands (`C#`) index into
    /// this array.
    consts: []const Value,
    /// Slot count. The frame reserves this many `Value` slots on
    /// invocation.
    slot_count: u16,
    /// Human-readable name for diagnostics. Non-owning.
    name: []const u8 = "<anonymous>",
};

// =============================================================================
// Frame (VM.md §7)
//
// Single-frame runtime in this commit. A call stack + caller/return
// machinery lands with the `call:call` opcode in a later commit.
// =============================================================================

pub const Frame = struct {
    routine: *const Routine,
    /// Owned slot storage. Allocated at frame construction.
    slots: []Value,
    /// Bytecode offset of the next instruction to execute.
    pc: u32 = 0,
};

// =============================================================================
// Errors
// =============================================================================

pub const VmError = error{
    /// Known opcode / group / variant / operand kind that this VM
    /// commit hasn't wired yet (e.g., math:add before the math
    /// commit; upvalue operand before closures land). Distinct
    /// from corruption — the encoding IS a recognized shape.
    UnimplementedOpcode,
    /// Operand index out of range for the operand's kind (e.g.,
    /// constant index >= routine.consts.len, slot index >=
    /// frame.slots.len).
    OperandOutOfRange,
    /// Operand's kind byte is not valid in this context — e.g.,
    /// `resolve` called on an `.unused` operand, or `store`
    /// called with a non-`.slot` destination. Distinct from
    /// OperandOutOfRange (which is about the index) and from
    /// BytecodeCorruption (which is about totally unrecognized
    /// encoding).
    InvalidOperandKind,
    /// `return` executed at the outermost frame (halt).
    Halt,
    /// Bytecode exhausted without an explicit `return`. Conservative
    /// error for the v1 skeleton; later commits add an implicit
    /// `return nil` at code-end.
    BytecodeExhausted,
    /// Unknown opcode group / variant / operand kind bit pattern
    /// (NOT in any recognized v1 enum space). Indicates
    /// bytecode corruption or bytecode from a newer nexis VM
    /// that this VM doesn't understand.
    BytecodeCorruption,
};

// =============================================================================
// VM
// =============================================================================

pub const VM = struct {
    allocator: std.mem.Allocator,
    frame: Frame,
    /// Where `call:return` stores the returned Value on halt.
    result: Value = value_mod.nilValue(),
    halted: bool = false,

    /// Build a VM around `routine`, allocating a single frame with
    /// `routine.slot_count` slots. Caller owns the lifetime of
    /// `routine`; VM owns the frame's slot storage and frees it in
    /// `deinit`.
    pub fn init(allocator: std.mem.Allocator, routine: *const Routine) !VM {
        const slots = try allocator.alloc(Value, routine.slot_count);
        for (slots) |*s| s.* = value_mod.nilValue();
        return .{
            .allocator = allocator,
            .frame = .{
                .routine = routine,
                .slots = slots,
                .pc = 0,
            },
        };
    }

    pub fn deinit(self: *VM) void {
        self.allocator.free(self.frame.slots);
        self.* = undefined;
    }

    /// Resolve an operand to a `Value` (read side).
    fn resolve(self: *VM, op: Operand) VmError!Value {
        return switch (op.kind) {
            .slot => blk: {
                if (op.index >= self.frame.slots.len) return VmError.OperandOutOfRange;
                break :blk self.frame.slots[op.index];
            },
            .constant => blk: {
                const consts = self.frame.routine.consts;
                if (op.index >= consts.len) return VmError.OperandOutOfRange;
                break :blk consts[op.index];
            },
            // Remaining kinds land with their respective opcode groups.
            .var_, .upvalue, .intern, .jump, .durable => VmError.UnimplementedOpcode,
            // `unused` is a sentinel emitted by the assembler for
            // operand slots the opcode doesn't consume; calling
            // `resolve` on one is an opcode-handler bug.
            .unused => VmError.InvalidOperandKind,
            // Unrecognized kind bit pattern — bytecode corruption.
            _ => VmError.BytecodeCorruption,
        };
    }

    /// Write a `Value` into a slot operand. Only `.slot` is a valid
    /// destination in this commit; other kinds would be writes to
    /// constants/vars/etc., handled by dedicated opcodes later.
    fn store(self: *VM, op: Operand, v: Value) VmError!void {
        switch (op.kind) {
            .slot => {
                if (op.index >= self.frame.slots.len) return VmError.OperandOutOfRange;
                self.frame.slots[op.index] = v;
            },
            // Other kinds are reserved for specific opcode groups
            // (constant pool is read-only; var writes go through
            // `var:store-var`; upvalue writes through `closure:`).
            .constant, .var_, .upvalue, .intern, .jump, .durable => return VmError.UnimplementedOpcode,
            .unused => return VmError.InvalidOperandKind,
            _ => return VmError.BytecodeCorruption,
        }
    }

    /// Run bytecode to completion (halt). Returns the VM's `result`
    /// slot. If bytecode exhausts without a `return`, returns
    /// `BytecodeExhausted`.
    pub fn run(self: *VM) VmError!Value {
        while (!self.halted) {
            if (self.frame.pc >= self.frame.routine.code.len) {
                return VmError.BytecodeExhausted;
            }
            const inst = self.frame.routine.code[self.frame.pc];
            self.frame.pc += 1;

            // Extension instructions are reserved; skip for now.
            if (inst.kind == .extension) return VmError.UnimplementedOpcode;

            try self.dispatch(inst);
        }
        return self.result;
    }

    /// Two-level switch dispatcher. Tail-call-threaded upgrade is
    /// deferred (VM.md §8 contract is "tail-call-threaded"; this
    /// implementation is semantically equivalent via the simpler
    /// switch — latitude per PLAN §12.5 fallback).
    fn dispatch(self: *VM, inst: Inst) VmError!void {
        const g = inst.groupOf();
        switch (g) {
            .mov => try self.execMov(inst),
            .call => try self.execCall(inst),
            // Known but not yet implemented in this commit.
            .jump, .cmp, .math, .closure, .var_, .coll, .transient, .hash, .tx, .ctrl, .io, .simd => return VmError.UnimplementedOpcode,
            // Unrecognized group byte — bytecode corruption.
            _ => return VmError.BytecodeCorruption,
        }
    }

    // -------------------------------------------------------------------------
    // Group `mov` (VM.md §10 #3)
    // -------------------------------------------------------------------------

    fn execMov(self: *VM, inst: Inst) VmError!void {
        const variant: Mov = @enumFromInt(inst.variant);
        switch (variant) {
            .move => {
                // mov:move a b _      ;  slot[a] = resolve(b)
                const v = try self.resolve(inst.b);
                try self.store(inst.a, v);
            },
            .load_const => {
                // mov:load-const a c _  ;  slot[a] = consts[c]
                const v = try self.resolve(inst.b);
                try self.store(inst.a, v);
            },
            .load_nil => {
                try self.store(inst.a, value_mod.nilValue());
            },
            .load_true => {
                try self.store(inst.a, value_mod.fromBool(true));
            },
            .load_false => {
                try self.store(inst.a, value_mod.fromBool(false));
            },
            _ => return VmError.UnimplementedOpcode,
        }
    }

    // -------------------------------------------------------------------------
    // Group `call` (VM.md §10 #4)
    // -------------------------------------------------------------------------

    fn execCall(self: *VM, inst: Inst) VmError!void {
        const variant: Call = @enumFromInt(inst.variant);
        switch (variant) {
            .@"return" => {
                // call:return a _ _   ;  result = slot[a]; halt
                self.result = try self.resolve(inst.a);
                self.halted = true;
            },
            .return_nil => {
                self.result = value_mod.nilValue();
                self.halted = true;
            },
            // call / tailcall land with a proper frame stack.
            .call, .tailcall => return VmError.UnimplementedOpcode,
            _ => return VmError.UnimplementedOpcode,
        }
    }
};

// =============================================================================
// Convenience helpers for hand-assembling bytecode in tests.
// =============================================================================

pub fn makeRoutine(
    code: []const Inst,
    consts: []const Value,
    slot_count: u16,
    name: []const u8,
) Routine {
    return .{
        .code = code,
        .consts = consts,
        .slot_count = slot_count,
        .name = name,
    };
}

/// Encoding helpers. Every opcode used in this commit has a
/// corresponding helper. Keeps hand-assembly readable.
pub const asm_ = struct {
    pub fn loadConst(slot_dst: u12, const_src: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_const,
            Operand.slot(slot_dst),
            Operand.constant(const_src),
            Operand.none,
        );
    }

    pub fn move(slot_dst: u12, slot_src: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.move,
            Operand.slot(slot_dst),
            Operand.slot(slot_src),
            Operand.none,
        );
    }

    pub fn loadNil(slot_dst: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_nil,
            Operand.slot(slot_dst),
            Operand.none,
            Operand.none,
        );
    }

    pub fn loadTrue(slot_dst: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_true,
            Operand.slot(slot_dst),
            Operand.none,
            Operand.none,
        );
    }

    pub fn loadFalse(slot_dst: u12) Inst {
        return Inst.primary(
            .mov,
            Mov.load_false,
            Operand.slot(slot_dst),
            Operand.none,
            Operand.none,
        );
    }

    pub fn returnSlot(slot_src: u12) Inst {
        return Inst.primary(
            .call,
            Call.@"return",
            Operand.slot(slot_src),
            Operand.none,
            Operand.none,
        );
    }

    pub fn returnNil() Inst {
        return Inst.primary(
            .call,
            Call.return_nil,
            Operand.none,
            Operand.none,
            Operand.none,
        );
    }
};

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

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

test "VM: load-nil into slot 0, return slot 0 -> nil" {
    var code = [_]Inst{
        asm_.loadNil(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "load-nil");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .nil);
}

test "VM: load-true into slot 0, return -> true" {
    var code = [_]Inst{
        asm_.loadTrue(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "load-true");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .true_);
}

test "VM: load-false into slot 0, return -> false" {
    var code = [_]Inst{
        asm_.loadFalse(0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "load-false");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .false_);
}

test "VM: load-const pulls a fixnum from the pool" {
    const consts = [_]Value{value_mod.fromFixnum(12345).?};
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &consts, 1, "load-const");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 12345), result.asFixnum());
}

test "VM: move copies one slot into another" {
    const consts = [_]Value{value_mod.fromFixnum(77).?};
    var code = [_]Inst{
        asm_.loadConst(0, 0), // slot[0] = 77
        asm_.move(1, 0), //      slot[1] = slot[0]
        asm_.returnSlot(1), //   return slot[1]
    };
    const routine = makeRoutine(&code, &consts, 2, "move");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 77), result.asFixnum());
}

test "VM: return_nil halts without reading a slot" {
    var code = [_]Inst{
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 0, "return-nil");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expect(result.kind() == .nil);
}

test "VM: reading a slot out of range returns OperandOutOfRange" {
    var code = [_]Inst{
        asm_.returnSlot(5), // frame has 1 slot; slot 5 is out of range
    };
    const routine = makeRoutine(&code, &.{}, 1, "oob");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM: reading a constant out of range returns OperandOutOfRange" {
    var code = [_]Inst{
        asm_.loadConst(0, 9), // pool is empty; const 9 is OOB
        asm_.returnSlot(0),
    };
    const routine = makeRoutine(&code, &.{}, 1, "const-oob");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.OperandOutOfRange, res);
}

test "VM: exhausting bytecode without return surfaces BytecodeExhausted" {
    var code = [_]Inst{
        asm_.loadNil(0),
        // no return — fall off the end
    };
    const routine = makeRoutine(&code, &.{}, 1, "fallthrough");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.BytecodeExhausted, res);
}

test "VM: known-but-not-implemented group returns UnimplementedOpcode" {
    // math group (2) with variant 0 — known group, not wired yet.
    const math_add = Inst.primary(
        .math,
        @as(Mov, @enumFromInt(0)), // reusing Mov tag for a placeholder; we only care about group
        Operand.slot(0),
        Operand.slot(0),
        Operand.slot(0),
    );
    var code = [_]Inst{
        math_add,
        asm_.returnNil(),
    };
    const routine = makeRoutine(&code, &.{}, 1, "unimpl");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.UnimplementedOpcode, res);
}

test "VM: unrecognized group (bit-pattern 60) returns BytecodeCorruption" {
    // Build a raw Inst with a group number outside v1's allocated
    // space (60, well above the 14 v1 groups). The non-exhaustive
    // `Group` enum lets us emit this without aborting; dispatch
    // should detect and surface BytecodeCorruption.
    const raw: Inst = .{
        .kind = .primary,
        .group = 60,
        .variant = 0,
        .a = Operand.none,
        .b = Operand.none,
        .c = Operand.none,
    };
    var code = [_]Inst{ raw, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "corrupt");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.BytecodeCorruption, res);
}

test "VM: resolve on .unused operand returns InvalidOperandKind" {
    // mov:move with source operand B = unused. Handler calls
    // resolve(inst.b), which should surface InvalidOperandKind
    // rather than the ambiguous OperandOutOfRange.
    const bad_move: Inst = .{
        .kind = .primary,
        .group = @intFromEnum(Group.mov),
        .variant = @intFromEnum(Mov.move),
        .a = Operand.slot(0),
        .b = Operand.none, // .unused
        .c = Operand.none,
    };
    var code = [_]Inst{ bad_move, asm_.returnNil() };
    const routine = makeRoutine(&code, &.{}, 1, "unused-operand");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const res = vm.run();
    try testing.expectError(VmError.InvalidOperandKind, res);
}

test "VM: a multi-step routine round-trips values through slots" {
    // Load three fixnum constants into three slots, then pick the
    // middle one as the return value. Exercises the instruction loop
    // across multiple dispatches.
    const consts = [_]Value{
        value_mod.fromFixnum(10).?,
        value_mod.fromFixnum(20).?,
        value_mod.fromFixnum(30).?,
    };
    var code = [_]Inst{
        asm_.loadConst(0, 0),
        asm_.loadConst(1, 1),
        asm_.loadConst(2, 2),
        asm_.move(3, 1),
        asm_.returnSlot(3),
    };
    const routine = makeRoutine(&code, &consts, 4, "multi-step");

    var vm = try VM.init(testing.allocator, &routine);
    defer vm.deinit();
    const result = try vm.run();
    try testing.expectEqual(@as(i64, 20), result.asFixnum());
}
