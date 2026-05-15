//! compile.zig — Phase 2 step #2 tiny compiler.
//!
//! Authoritative spec: `docs/COMPILER.md` §10 #2.
//!
//! **This commit is the minimum viable compiler.** It accepts a tiny
//! local form representation and emits bytecode for two cases:
//!
//!   - integer literal           →  `mov:load-const + call:return`
//!   - `(+ <int> <int>)`         →  `math:add + call:return` (with
//!                                  the two literal operands lifted
//!                                  into the routine's constant pool)
//!
//! Per `COMPILER.md` §10 #2 the goal of this commit is to **flush
//! out the VM/compiler interface** before the VM grows further. It
//! does NOT integrate with `src/reader.zig` — that wiring lands in
//! step #3 (conditionals), where a real `if`-form starts pulling on
//! the broader Form pipeline. Until then, callers hand-construct
//! `Tiny` values, which keeps the VM/compiler interface flushable
//! in isolation.
//!
//! **Memory model**: per `COMPILER.md` §3, the compile-time arena
//! owns macroexpansion and codegen scratch. This module's `compile`
//! function takes an allocator (typically an arena) and produces
//! `Compiled.code` and `Compiled.consts` slices owned by that
//! allocator. The caller wraps the result in a `vm.Routine` and
//! runs it; once execution completes, the arena can be dropped.
//!
//! **Resolution discipline (peer-AI turn 33)**: this module lowers
//! `Tiny.add` directly to `math:add`. When step #3+ replaces
//! `Tiny` with `reader.Form`, the compiler MUST NOT lower the
//! source symbol `+` to `math:add` blindly — the symbol must
//! first resolve to `nexis.core/+` (the core var). A locally
//! rebound `+` (e.g., `(let [+ my-plus] (+ 1 2))`) must compile
//! to a regular var-call, not a math:add intrinsic. The intrinsic
//! lowering is a peephole over the resolver's output, NOT a
//! syntactic shortcut over the reader's output. This boundary is
//! load-bearing: violating it changes user-observable semantics.
//!
//! **What's deferred to step #3+**:
//!   - Real `reader.Form` input.
//!   - Variadic `+` (`(+ a b c d)` reducing to chained adds).
//!   - Other arithmetic primitives (`-`, `*`, `/`, etc.).
//!   - Any non-literal sub-expressions (e.g., `(+ (+ 1 2) 3)`)
//!     would require slot allocation; we sidestep it by accepting
//!     only literal operands here.
//!   - Conditionals, function definitions, closures, `recur`,
//!     namespaces, macros — all per `COMPILER.md` §10 #3..#11.

const std = @import("std");
const vm = @import("vm");
const value_mod = @import("value");

pub const Inst = vm.Inst;
pub const Routine = vm.Routine;
pub const Operand = vm.Operand;
pub const Value = value_mod.Value;

// =============================================================================
// Tiny form — the input to this commit's compiler.
//
// In step #3 this gets replaced by `reader.Form` (or a thin
// macroexpander-output wrapper around it). The `Tiny` enum below
// encodes exactly the forms `compile` knows how to lower in step #2.
// =============================================================================

pub const Tiny = union(enum) {
    /// Integer literal. Must fit in i48 fixnum range; otherwise
    /// `IntegerOutOfFixnumRange` (bignum literal lifting lands
    /// with bignum Scope B).
    int: i64,

    /// `(+ lhs rhs)` with literal operands.
    add: struct { lhs: i64, rhs: i64 },
};

// =============================================================================
// Errors
// =============================================================================

pub const CompileError = error{
    /// Compiler encountered a `Tiny` variant it doesn't know how to
    /// lower. Step #2's repertoire is `int` and `add`; future
    /// commits widen this. (With the closed-enum `Tiny` definition
    /// in step #2 this is presently unreachable; reserved for
    /// when `Tiny` is replaced by `reader.Form` in step #3, where
    /// arbitrary forms can arrive.)
    UnsupportedForm,

    /// Integer literal exceeds i48 fixnum range. Until bignum
    /// arithmetic Scope B lands and the codegen learns to lift
    /// out-of-range literals into bignum heap values, this is a
    /// hard compile-time error.
    IntegerOutOfFixnumRange,

    OutOfMemory,
};

// =============================================================================
// Output
// =============================================================================

/// The compiler's product. Wrap with `toRoutine(name)` to get a
/// `vm.Routine` ready for `vm.VM.init`.
///
/// **Ownership** (peer-AI turn 33 confirmation): `code` and
/// `consts` are slices allocated through the allocator passed to
/// `compileTiny()` and remain valid until that allocator is reset or
/// destroyed. There is no `deinit` method — the model is
/// "compile-time arena, drop wholesale after execution." Callers
/// using a non-arena allocator must free `code` and `consts`
/// individually. (When step #5's runtime function heap kind
/// lands, the lifecycle target is `Compiled` → heap-Value-of-kind-
/// function via a deep-copy; that conversion is deferred until
/// the heap fn-kind is real, to avoid designing against an
/// imaginary ownership contract.)
pub const Compiled = struct {
    code: []const Inst,
    consts: []const Value,
    slot_count: u16,

    pub fn toRoutine(self: Compiled, name: []const u8) Routine {
        return vm.makeRoutine(self.code, self.consts, self.slot_count, name);
    }
};

// =============================================================================
// Public API
// =============================================================================

/// Compile a `Tiny` form to a `Compiled` artifact.
///
/// **Provisional name** (peer-AI turn 35): `compileTiny` rather
/// than `compile` to make it loud that this is the bootstrap-only
/// entry point that accepts the local `Tiny` representation. When
/// step #3+ replaces `Tiny` with `reader.Form`, the public
/// compile surface evolves; tooling/tests that built against
/// `compileTiny` get a clean rename signal rather than silently
/// continuing to build against an evolved API.
pub fn compileTiny(allocator: std.mem.Allocator, form: Tiny) CompileError!Compiled {
    return switch (form) {
        .int => |n| try compileIntLiteral(allocator, n),
        .add => |args| try compileAdd(allocator, args.lhs, args.rhs),
    };
}

// =============================================================================
// Internal lowering
// =============================================================================

fn compileIntLiteral(allocator: std.mem.Allocator, n: i64) CompileError!Compiled {
    const v = value_mod.fromFixnum(n) orelse
        return CompileError.IntegerOutOfFixnumRange;

    const code = try allocator.alloc(Inst, 2);
    code[0] = vm.asm_.loadConst(0, 0); // s0 := c0
    code[1] = vm.asm_.returnSlot(0); //   return s0

    const consts = try allocator.alloc(Value, 1);
    consts[0] = v;

    return .{ .code = code, .consts = consts, .slot_count = 1 };
}

fn compileAdd(allocator: std.mem.Allocator, lhs: i64, rhs: i64) CompileError!Compiled {
    const v_lhs = value_mod.fromFixnum(lhs) orelse
        return CompileError.IntegerOutOfFixnumRange;
    const v_rhs = value_mod.fromFixnum(rhs) orelse
        return CompileError.IntegerOutOfFixnumRange;

    // Encoding choice (peer-AI turn 32 / VM.md §6 / COMPILER.md
    // §4.4 literal lifting): math:add accepts any operand kind
    // that `vm.resolve` knows about — including `.constant`. For
    // a fully-literal `(+ 1 2)` the compiler can lift both args
    // into the constant pool and emit a single math:add reading
    // them directly. No prelude moves, no temp slots, two
    // instructions total.
    //
    // This is the most compact encoding for the trivial case.
    // Step #3+ codegen for non-literal sub-expressions naturally
    // shifts to slot-based operands (load each sub-expression
    // result into a slot, then math:add slot/slot/slot).
    const code = try allocator.alloc(Inst, 2);
    code[0] = vm.asm_.mathAdd(0, Operand.constant(0), Operand.constant(1));
    code[1] = vm.asm_.returnSlot(0);

    const consts = try allocator.alloc(Value, 2);
    consts[0] = v_lhs;
    consts[1] = v_rhs;

    return .{ .code = code, .consts = consts, .slot_count = 1 };
}

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

test "compile: integer literal evaluates to itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const compiled = try compileTiny(arena.allocator(), .{ .int = 42 });
    const routine = compiled.toRoutine("int-literal");

    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expect(result.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 42), result.asFixnum());
}

test "compile: (+ 1 2) = 3 — the canonical step-#2 result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const compiled = try compileTiny(arena.allocator(), .{ .add = .{ .lhs = 1, .rhs = 2 } });
    const routine = compiled.toRoutine("(+ 1 2)");

    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, 3), result.asFixnum());
}

test "compile: (+ -7 -5) = -12 — negative operands" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const compiled = try compileTiny(arena.allocator(), .{ .add = .{ .lhs = -7, .rhs = -5 } });
    const routine = compiled.toRoutine("(+ -7 -5)");

    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, -12), result.asFixnum());
}

test "compile: (+ 0 0) = 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const compiled = try compileTiny(arena.allocator(), .{ .add = .{ .lhs = 0, .rhs = 0 } });
    const routine = compiled.toRoutine("(+ 0 0)");

    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(@as(i64, 0), result.asFixnum());
}

test "compile: integer literal at i48 boundary compiles" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const compiled = try compileTiny(arena.allocator(), .{ .int = value_mod.fixnum_max });
    const routine = compiled.toRoutine("fixnum-max");

    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const result = try v.run();
    try testing.expectEqual(value_mod.fixnum_max, result.asFixnum());
}

test "compile: integer literal beyond i48 range rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // fixnum_max + 1 doesn't fit; the compiler refuses (until
    // bignum literal lifting in Scope B).
    const res = compileTiny(arena.allocator(), .{ .int = value_mod.fixnum_max + 1 });
    try testing.expectError(CompileError.IntegerOutOfFixnumRange, res);
}

test "compile + run: (+ fixnum_max 1) compiles but VM traps overflow" {
    // Demonstrates that compile-time fixnum-fit checks are
    // independent of runtime overflow detection. Both operands
    // individually fit (fixnum_max and 1), so compile succeeds.
    // The sum overflows i48, so the VM traps at math:add time.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const compiled = try compileTiny(
        arena.allocator(),
        .{ .add = .{ .lhs = value_mod.fixnum_max, .rhs = 1 } },
    );
    const routine = compiled.toRoutine("(+ fixnum_max 1)");

    var v = try vm.VM.init(testing.allocator, &routine);
    defer v.deinit();
    const res = v.run();
    try testing.expectError(vm.VmError.IntegerOverflow, res);
}

test "compile: arena cleanup releases code+consts atomically" {
    // A modest end-to-end allocation discipline check: compile
    // many programs through one arena and confirm they all run
    // correctly before the arena drops. `std.testing.allocator`
    // is the GPA underlying the arena and will scream on leak.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const cases = [_]struct { lhs: i64, rhs: i64, expected: i64 }{
        .{ .lhs = 1, .rhs = 2, .expected = 3 },
        .{ .lhs = 100, .rhs = 200, .expected = 300 },
        .{ .lhs = -1, .rhs = 1, .expected = 0 },
        .{ .lhs = 7, .rhs = 35, .expected = 42 },
    };

    for (cases) |tc| {
        const compiled = try compileTiny(
            arena.allocator(),
            .{ .add = .{ .lhs = tc.lhs, .rhs = tc.rhs } },
        );
        const routine = compiled.toRoutine("batch");
        var v = try vm.VM.init(testing.allocator, &routine);
        defer v.deinit();
        const result = try v.run();
        try testing.expectEqual(tc.expected, result.asFixnum());
    }
}
