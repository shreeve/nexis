//! test/prop/compile.zig — randomized properties covering COMPILER.md
//! §9.4 gate items 3 and 4.
//!
//! Gate item 3 (closure capture depth-10):
//!   Build N-level-deep nested fn* expressions where the innermost
//!   fn captures a binding from the outermost scope. Verify that
//!   for N in 1..10, the captured value round-trips correctly
//!   regardless of nesting depth. Exercises the pre-analysis
//!   capture machinery + CaptureSource chaining (`inherited_upvalue`).
//!
//! Gate item 4 (syntax-quote structural equality):
//!   Generate random list-valued Forms; compare the runtime list
//!   produced by syntax-quoting them in the `user` namespace against
//!   the runtime list produced by quoting the same forms with every
//!   symbol written `user/...`. Exercises the syntax-quote walker's
//!   segment-and-concat logic and its symbol qualification against
//!   the simpler `(quote ...)` lowering.
//!
//! Deterministic PRNG seeds so failures reproduce.

const std = @import("std");
const nx = @import("nexis");
const value_mod = nx.value;
const vm = nx.vm;
const compile = nx.compile;
const expand_mod = nx.expand;
const list_mod = nx.list;
const harness = @import("harness");

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
    try v.retargetTop(&routine);
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

test "prop capture depth: closure capture depth 1..10 round-trips value" {
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

test "prop capture depth: independent captures don't interfere" {
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
        try testing.expectEqual(a + b, r.result.asFixnum());
    }
}

// =============================================================================
// Gate item 4: syntax-quote structural equality
// =============================================================================
//
// For each random Form shape, evaluate `` `SHAPE `` (syntax-quote
// with no unquotes) and `(quote SHAPE)` with its symbols qualified the
// way syntax-quote qualifies them. Both must produce structurally
// equal runtime list values.

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

test "prop syntax-quote: syntax-quote ≡ quote of the namespace-qualified shape" {
    var prng = std.Random.DefaultPrng.init(sq_prng_seed);
    const rand = prng.random();

    // One program for every trial, so interned symbols compare by
    // identity; syntax-quote qualifies in its namespace, `user`.
    var program: harness.Program = undefined;
    try program.init();
    defer program.deinit();

    var trial: u32 = 0;
    while (trial < 100) : (trial += 1) {
        var shape: std.array_list.Managed(u8) = .init(testing.allocator);
        defer shape.deinit();
        try writeRandomShape(&shape, rand, 3);

        //   q:  (quote SHAPE) with every symbol leaf written user/symN
        //   sq: `SHAPE
        const qualified = try std.mem.replaceOwned(u8, testing.allocator, shape.items, "sym", "user/sym");
        defer testing.allocator.free(qualified);
        const q_src = try std.fmt.allocPrint(testing.allocator, "(quote {s})", .{qualified});
        defer testing.allocator.free(q_src);
        const sq_src = try std.fmt.allocPrint(testing.allocator, "`{s}", .{shape.items});
        defer testing.allocator.free(sq_src);

        const q_result = try program.run(q_src);
        const sq_result = try program.run(sq_src);
        testing.expect(listEq(q_result, sq_result)) catch |err| {
            std.debug.print("\n  shape: {s}\n", .{shape.items});
            return err;
        };
    }
}

test "prop syntax-quote: syntax-quote with unquoted integer matches hand-built list" {
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

// =============================================================================
// Inlined core arithmetic (COMPILER.md §4.3 rule 2)
// =============================================================================

test "inlining: an operator inlines only when it names nexis.core's Var" {
    // A namespace's own definition wins in every call shape.
    try harness.expectOutput(
        \\(ns foo)
        \\(defn + [a b] 42)
        \\[(+ 1 2) (apply + [1 2]) (let [p +] (p 1 2))]
    , "[42 42 42]");
    try harness.expectOutput(
        \\(ns foo)
        \\(defn < [a b] :mine)
        \\[(< 1 2) (apply < [1 2])]
    , "[:mine :mine]");
    // A definition in the same form counts from its own definition on.
    try harness.expectCheckedOutput("(do (def + (fn* [a b] 42)) (+ 1 2))", "42");
    // Every other namespace still gets core's.
    try harness.expectOutput(
        \\(ns foo)
        \\(defn + [a b] 42)
        \\(ns bar)
        \\(+ 1 2)
    , "3");
}
