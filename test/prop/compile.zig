//! test/prop/compile.zig — randomized properties closing COMPILER.md
//! §9.4 Phase 2 gate items 3 and 4.
//!
//! Gate item 3 (closure capture depth-10):
//!   Build N-level-deep nested fn* expressions where the innermost
//!   fn captures a binding from the outermost scope. Verify that
//!   for N in 1..10, the captured value round-trips correctly
//!   regardless of nesting depth. Exercises the pre-analysis
//!   capture machinery + CaptureSource chaining (`inherited_upvalue`)
//!   that lands across step #5.
//!
//! Gate item 4 (syntax-quote structural equality):
//!   Generate random list-valued Forms; compare the runtime list
//!   produced by syntax-quoting them against the runtime list
//!   produced by directly quoting the same forms. Exercises the
//!   syntax-quote walker's segment-and-concat logic (#8c.2) against
//!   the simpler `(quote ...)` lowering (#8c.1).
//!
//! Deterministic PRNG seeds so failures reproduce.

const std = @import("std");
const value_mod = @import("value");
const vm = @import("vm");
const compile = @import("compile");
const intern_mod = @import("intern");
const reader_mod = @import("reader");
const expand_mod = @import("expand");
const list_mod = @import("list");

const testing = std.testing;
const Value = value_mod.Value;

const closure_prng_seed: u64 = 0x636C_6F73_7572_655F; // "closure_"
const sq_prng_seed: u64 = 0x7379_6E71_7572_7465; // "synqurte"

// =============================================================================
// Helpers
// =============================================================================

/// Compile + run `src` against a fresh VM, return the result + VM.
/// Caller owns vm_owned and must call vm_owned.deinit().
fn runSource(src: []const u8) !struct { result: Value, vm_owned: vm.VM } {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
    const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
    var v = try vm.VM.init(testing.allocator, &stub);
    errdefer v.deinit();
    const ns = v.ensureNamespace();
    const interner = v.ensureInterner();
    var host_macros = try expand_mod.defaultMacros(testing.allocator);
    defer host_macros.deinit(testing.allocator);
    const compiled = try compile.compileSourceFullWithMacros(
        arena.allocator(),
        src,
        ns,
        interner,
        &host_macros,
    );
    const routine = compiled.toRoutine("prop");
    v.frames.items[0].routine = &routine;
    v.frames.items[0].pc = 0;
    v.frames.items[0].slot_count = routine.slot_count;
    if (v.stack.items.len < routine.slot_count) {
        try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), routine.slot_count - v.stack.items.len);
    }
    const result = try v.run();
    return .{ .result = result, .vm_owned = v };
}

// =============================================================================
// Gate item 3: closure capture depth-10
// =============================================================================
//
// Build:
//   (let* [x VALUE]
//     ((fn* []           ; depth 1
//       ((fn* []         ; depth 2
//         ...
//           ((fn* [] x)) ; depth N
//         ...)))))
//
// For each N in 1..10, assert the result equals VALUE.

fn buildNestedClosureSource(buf: *std.array_list.Managed(u8), value: i64, depth: u32) !void {
    const prefix = try std.fmt.allocPrint(testing.allocator, "(let* [x {d}] ", .{value});
    defer testing.allocator.free(prefix);
    try buf.appendSlice(prefix);
    var d: u32 = 0;
    while (d < depth) : (d += 1) {
        try buf.appendSlice("((fn* [] ");
    }
    try buf.appendSlice("x");
    d = 0;
    while (d < depth) : (d += 1) {
        try buf.appendSlice("))");
    }
    try buf.appendSlice(")");
}

test "prop #3: closure capture depth 1..10 round-trips value" {
    var prng = std.Random.DefaultPrng.init(closure_prng_seed);
    const rand = prng.random();

    var depth: u32 = 1;
    while (depth <= 10) : (depth += 1) {
        // Run several trials at this depth with random values.
        var trial: u32 = 0;
        while (trial < 10) : (trial += 1) {
            const v: i64 = @intCast(rand.int(i32));
            var src: std.array_list.Managed(u8) = .init(testing.allocator);
            defer src.deinit();
            try buildNestedClosureSource(&src, v, depth);

            var r = try runSource(src.items);
            defer r.vm_owned.deinit();
            try testing.expectEqual(v, r.result.asFixnum());
        }
    }
}

test "prop #3: independent captures don't interfere" {
    // Two separate closures each capturing a different binding.
    // Force them to be called in sequence; both must return their
    // own captured value.
    var prng = std.Random.DefaultPrng.init(closure_prng_seed +% 2);
    const rand = prng.random();

    var trial: u32 = 0;
    while (trial < 20) : (trial += 1) {
        const a: i64 = @intCast(rand.int(i16));
        const b: i64 = @intCast(rand.int(i16));
        var src: std.array_list.Managed(u8) = .init(testing.allocator);
        defer src.deinit();
        const formatted = try std.fmt.allocPrint(
            testing.allocator,
            "(let* [a {d} b {d}] (+ ((fn* [] a)) ((fn* [] b))))",
            .{ a, b },
        );
        defer testing.allocator.free(formatted);
        try src.appendSlice(formatted);

        var r = try runSource(src.items);
        defer r.vm_owned.deinit();
        const expected: i64 = a + b;
        // Sum might overflow i48 for extreme i16 pairs; skip if so.
        if (value_mod.fromFixnum(expected) == null) continue;
        try testing.expectEqual(expected, r.result.asFixnum());
    }
}

// =============================================================================
// Gate item 4: syntax-quote structural equality
// =============================================================================
//
// For each random Form shape, evaluate it as `(quote SHAPE)` and as
// `` `SHAPE `` (syntax-quote with NO unquotes). Both must produce
// structurally-equal runtime list values.

fn listEq(a: Value, b: Value) bool {
    if (a.kind() != b.kind()) return false;
    if (a.kind() != .list) {
        // Cheap eq for the leaves we generate (fixnum / symbol /
        // keyword). Exploit interning for symbol/keyword identity.
        return a.tag == b.tag and a.payload == b.payload;
    }
    var na = a;
    var nb = b;
    while (true) {
        const ea = list_mod.isEmpty(na);
        const eb = list_mod.isEmpty(nb);
        if (ea and eb) return true;
        if (ea or eb) return false;
        if (!listEq(list_mod.head(na), list_mod.head(nb))) return false;
        na = list_mod.tail(na);
        nb = list_mod.tail(nb);
    }
}

fn writeRandomLeaf(buf: *std.array_list.Managed(u8), rand: std.Random) !void {
    const pick = rand.uintLessThan(u8, 4);
    const s = switch (pick) {
        0 => try std.fmt.allocPrint(testing.allocator, "{d}", .{rand.int(i16)}),
        1 => try std.fmt.allocPrint(testing.allocator, "sym{d}", .{rand.uintLessThan(u32, 100)}),
        2 => try std.fmt.allocPrint(testing.allocator, ":kw{d}", .{rand.uintLessThan(u32, 100)}),
        else => try std.fmt.allocPrint(testing.allocator, "{d}", .{rand.int(i8)}),
    };
    defer testing.allocator.free(s);
    try buf.appendSlice(s);
}

fn writeRandomShape(buf: *std.array_list.Managed(u8), rand: std.Random, depth: u32) !void {
    if (depth == 0 or rand.uintLessThan(u8, 3) == 0) {
        try writeRandomLeaf(buf, rand);
        return;
    }
    const n = rand.uintLessThan(u8, 5);
    try buf.append('(');
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try buf.append(' ');
        try writeRandomShape(buf, rand, depth - 1);
    }
    try buf.append(')');
}

test "prop #4: syntax-quote ≡ quote for splice-free shapes" {
    var prng = std.Random.DefaultPrng.init(sq_prng_seed);
    const rand = prng.random();

    var trial: u32 = 0;
    while (trial < 100) : (trial += 1) {
        var shape: std.array_list.Managed(u8) = .init(testing.allocator);
        defer shape.deinit();
        try writeRandomShape(&shape, rand, 3);

        // Construct two parallel source programs:
        //   q:  (quote SHAPE)
        //   sq: `SHAPE
        var q_src: std.array_list.Managed(u8) = .init(testing.allocator);
        defer q_src.deinit();
        try q_src.appendSlice("(quote ");
        try q_src.appendSlice(shape.items);
        try q_src.appendSlice(")");

        var sq_src: std.array_list.Managed(u8) = .init(testing.allocator);
        defer sq_src.deinit();
        try sq_src.append('`');
        try sq_src.appendSlice(shape.items);

        // Run both in the SAME VM so interned symbol identity matches.
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var stub_code = [_]vm.Inst{vm.asm_.returnNil()};
        const stub = vm.Routine{ .code = &stub_code, .consts = &.{}, .slot_count = 1 };
        var v = try vm.VM.init(testing.allocator, &stub);
        defer v.deinit();
        const ns = v.ensureNamespace();
        const interner = v.ensureInterner();
        var host_macros = try expand_mod.defaultMacros(testing.allocator);
        defer host_macros.deinit(testing.allocator);

        const q_compiled = try compile.compileSourceFullWithMacros(
            arena.allocator(),
            q_src.items,
            ns,
            interner,
            &host_macros,
        );
        const q_routine = q_compiled.toRoutine("q");
        v.frames.items[0].routine = &q_routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = q_routine.slot_count;
        if (v.stack.items.len < q_routine.slot_count) {
            try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), q_routine.slot_count - v.stack.items.len);
        }
        const q_result = try v.run();

        const sq_compiled = try compile.compileSourceFullWithMacros(
            arena.allocator(),
            sq_src.items,
            ns,
            interner,
            &host_macros,
        );
        const sq_routine = sq_compiled.toRoutine("sq");
        v.frames.items[0].routine = &sq_routine;
        v.frames.items[0].pc = 0;
        v.frames.items[0].slot_count = sq_routine.slot_count;
        v.halted = false;
        if (v.stack.items.len < sq_routine.slot_count) {
            try v.stack.appendNTimes(v.allocator, value_mod.nilValue(), sq_routine.slot_count - v.stack.items.len);
        }
        const sq_result = try v.run();

        try testing.expect(listEq(q_result, sq_result));
    }
}

test "prop #4: syntax-quote with unquoted integer matches hand-built list" {
    // For each trial, generate a fixed list shape with one
    // integer unquoted; verify the resulting list contains
    // that integer at the expected position.
    var prng = std.Random.DefaultPrng.init(sq_prng_seed +% 1);
    const rand = prng.random();

    var trial: u32 = 0;
    while (trial < 50) : (trial += 1) {
        const v: i64 = @intCast(rand.int(i16));
        var src_buf: std.array_list.Managed(u8) = .init(testing.allocator);
        defer src_buf.deinit();
        const formatted = try std.fmt.allocPrint(
            testing.allocator,
            "(let* [n {d}] `(start ~n end))",
            .{v},
        );
        defer testing.allocator.free(formatted);
        try src_buf.appendSlice(formatted);

        var r = try runSource(src_buf.items);
        defer r.vm_owned.deinit();
        try testing.expect(r.result.kind() == .list);
        // Position 1 = the unquoted n value.
        const second = list_mod.head(list_mod.tail(r.result));
        try testing.expectEqual(v, second.asFixnum());
    }
}
