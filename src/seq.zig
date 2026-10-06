//! seq.zig — realizing lazy seqs and walking any seqable, with a VM.
//!
//! Authoritative spec: `docs/LAZY.md` (§4 the realization protocol,
//! §5 walking). The shapes are `src/coll/lazy.zig`'s; this file runs
//! their bodies. Everything here is native context (LAZY.md §6): the
//! caller is a native or an opcode with a VM in hand, realizing may
//! run any code and collect, and errors are ordinary `VmError`s. What a
//! caller holds across a call here must be reachable from its
//! arguments or on a root scope (docs/GC.md §11.5, class 5); a realized
//! chain is cached in the block that heads it, so the cells a walk has
//! passed stay reachable from the argument it started at.

const std = @import("std");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");
const list_mod = @import("coll/list.zig");
const lazy = @import("coll/lazy.zig");
const vector_mod = @import("coll/vector.zig");
const typed_vector_mod = @import("coll/typed_vector.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const string_mod = @import("string.zig");
const record_mod = @import("record.zig");
const stack_guard = @import("stack.zig");
const vm_mod = @import("vm.zig");

const Value = value_mod.Value;
const Kind = value_mod.Kind;
const VM = vm_mod.VM;
const VmError = vm_mod.VmError;

// =============================================================================
// Hooks
// =============================================================================

/// The map of a Nextomic entity's attributes, read in one pass; set
/// by the Nextomic natives when they are installed, which sit above
/// this file. Null until then: an entity is no seqable.
pub var entity_map: ?*const fn (vm: *VM, ent: Value) VmError!Value = null;

// =============================================================================
// Producers
// =============================================================================

/// A block's step: the raw result of running its body once, which
/// `force` brings to normal form (LAZY.md §4). Its state is the
/// block's `args`.
const Step = *const fn (vm: *VM, lz: Value) VmError!Value;

pub const op_thunk: u16 = 0;

const steps = [_]Step{
    stepThunk,
};

/// `(lazy-seq body...)`: the body's function, called with no arguments.
fn stepThunk(vm: *VM, lz: Value) VmError!Value {
    return vm.callValue(lazy.args(lz)[0], &.{});
}

/// A new unrealized block running producer `op` over `args`.
pub fn make(vm: *VM, op: u16, args: []const Value) VmError!Value {
    return lazy.unrealized(vm.ensureHeap(), op, args) catch VmError.OutOfMemory;
}

// =============================================================================
// The realization protocol (LAZY.md §4)
// =============================================================================

/// The seq of the lazy block `lz`: nil or a non-empty seq. The first
/// call runs the block's body and caches what it returned in normal
/// form; a body that returns another lazy block forwards to it, so a
/// run of blocks that each return the next (a `filter` skipping, a
/// `lazy-seq` returning a `lazy-seq`) costs no native stack. A body
/// that throws leaves its block unrealized, and the next force runs it
/// again (`LazySeq.java` 1.12.0).
pub fn force(vm: *VM, lz: Value) VmError!Value {
    if (lazy.state(lz) == .realized) return lazy.result(lz);
    stack_guard.check() catch return VmError.StackOverflow;
    var cur = forwardEnd(lz);
    const raw: Value = while (true) {
        if (lazy.state(cur) == .realized) break lazy.result(cur);
        const r = try steps[lazy.op(cur)](vm, cur);
        if (r.kind() != .lazy_seq or lazy.shapeOf(r) != .lazy) break r;
        if (lazy.state(r) == .realized) break lazy.result(r);
        // A body that returns its own block, or one before it in the
        // chain, is the empty seq, as `LazySeq.sval` finds it.
        const end = forwardEnd(r);
        if (end.identicalTo(cur)) break value_mod.nilValue();
        lazy.setForwarding(cur, r);
        cur = end;
    };
    const s = try seqOf(vm, raw);
    var b = lz;
    while (true) {
        const was = lazy.state(b);
        const after = lazy.result(b);
        lazy.setRealized(b, s);
        if (b.identicalTo(cur) or was != .forwarding) break;
        b = after;
    }
    return s;
}

/// The block a forwarding chain from `lz` ends at.
fn forwardEnd(lz: Value) Value {
    var b = lz;
    while (lazy.state(b) == .forwarding) b = lazy.result(b);
    return b;
}

/// `(seq x)`: nil for nil or an empty seqable, otherwise a non-empty
/// seq. A non-empty list, a cons and a chunked cons are themselves; a
/// lazy block is its forced seq; a vector is an O(1) view
/// (`docs/LIST.md` §1); any other seqable is a fresh list of its
/// elements. Anything else is `:kind-mismatch`.
pub fn seqOf(vm: *VM, x: Value) VmError!Value {
    switch (x.kind()) {
        .nil => return x,
        .list => return if (list_mod.isEmpty(x)) value_mod.nilValue() else x,
        .lazy_seq => return switch (lazy.shapeOf(x)) {
            .lazy => force(vm, x),
            .cons, .chunked => x,
            .chunk => VmError.KindMismatch,
        },
        .persistent_vector => return if (vector_mod.isEmpty(x))
            value_mod.nilValue()
        else
            list_mod.ofVector(vm.ensureHeap(), x, 0) catch VmError.OutOfMemory,
        else => {},
    }
    // Iterating a map, set, string or the like runs no code, and
    // `Heap.alloc` never collects: the gathered elements need no root.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    var it = try SeqIter.init(vm, x);
    while (try it.next()) |e| items.append(vm.allocator, e) catch return VmError.OutOfMemory;
    if (items.items.len == 0) return value_mod.nilValue();
    return list_mod.build(vm.ensureHeap(), items.items) catch VmError.OutOfMemory;
}

/// `(first x)`.
pub fn first(vm: *VM, x: Value) VmError!Value {
    const s = try seqOf(vm, x);
    return switch (s.kind()) {
        .nil => s,
        .list => list_mod.head(s),
        else => lazy.first(s),
    };
}

/// `(rest x)`: never nil; `()` when nothing follows. The rest is not
/// forced: `rest` of a cons is its `more` as it stands.
pub fn rest(vm: *VM, x: Value) VmError!Value {
    const s = try seqOf(vm, x);
    const r: Value = switch (s.kind()) {
        .nil => value_mod.nilValue(),
        .list => return list_mod.tail(s),
        else => switch (lazy.shapeOf(s)) {
            .cons => lazy.more(s),
            .chunked => blk: {
                const at = lazy.chunkOffset(s) + 1;
                if (at < lazy.chunkCount(lazy.chunkOfCons(s))) return lazy.atOffset(s, at);
                break :blk lazy.more(s);
            },
            else => unreachable,
        },
    };
    if (r.isNil()) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    return r;
}

/// `(next x)`: `(seq (rest x))`, nil when nothing follows.
pub fn next(vm: *VM, x: Value) VmError!Value {
    return seqOf(vm, try rest(vm, x));
}

/// How many elements `x` has, walking (and realizing) it.
pub fn countOf(vm: *VM, x: Value) VmError!usize {
    var it = try SeqIter.init(vm, x);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// The element at `i` of a seq, or null past its end.
pub fn nthOf(vm: *VM, x: Value, i: usize) VmError!?Value {
    var it = try SeqIter.init(vm, x);
    for (0..i) |_| _ = (try it.next()) orelse return null;
    return it.next();
}

/// Realize `x`'s spine: `doall` and `dorun`. With a `limit`, as
/// Clojure's `(dorun n coll)`: `next` `limit` times, which realizes the
/// step after the last element walked.
pub fn realizeSpine(vm: *VM, x: Value, limit: ?usize) VmError!void {
    const n = limit orelse {
        var it = try SeqIter.init(vm, x);
        while (try it.next()) |_| {}
        return;
    };
    var xs = x;
    for (0..n) |_| {
        const s = try seqOf(vm, xs);
        if (s.isNil()) return;
        xs = try next(vm, s);
    }
}

/// Realize every lazy seq inside `root`, at any depth: the elements of
/// its seqs, vectors, maps, sets and records, walked with an explicit
/// stack. What code that runs no code needs before it walks a value
/// (the codec, the Nextomic natives, a macro's result made a form).
/// `root` must be rooted; everything the walk holds is reachable from
/// it.
pub fn realizeAll(vm: *VM, root: Value) VmError!void {
    if (!mayHoldLazy(root.kind())) return;
    var work: std.ArrayList(Value) = .empty;
    defer work.deinit(vm.allocator);
    var seen: std.AutoHashMapUnmanaged(u128, void) = .empty;
    defer seen.deinit(vm.allocator);
    work.append(vm.allocator, root) catch return VmError.OutOfMemory;
    while (work.pop()) |v| {
        const key = @as(u128, v.tag) << 64 | v.payload;
        if ((seen.getOrPut(vm.allocator, key) catch return VmError.OutOfMemory).found_existing) continue;
        switch (v.kind()) {
            .persistent_map, .sorted_map, .record => {
                var it = champOrSorted(v);
                while (it.next()) |e| {
                    if (mayHoldLazy(e.key.kind())) work.append(vm.allocator, e.key) catch return VmError.OutOfMemory;
                    if (mayHoldLazy(e.value.kind())) work.append(vm.allocator, e.value) catch return VmError.OutOfMemory;
                }
            },
            else => {
                var it = try SeqIter.init(vm, v);
                while (try it.next()) |x| if (mayHoldLazy(x.kind())) work.append(vm.allocator, x) catch return VmError.OutOfMemory;
            },
        }
    }
}

fn mayHoldLazy(k: Kind) bool {
    return switch (k) {
        .lazy_seq, .list, .persistent_vector, .persistent_map, .persistent_set, .sorted_map, .sorted_set, .record => true,
        else => false,
    };
}

const Entries = union(enum) {
    champ: champ_mod.MapIter,
    sorted: sorted_mod.Iter,

    fn next(self: *Entries) ?struct { key: Value, value: Value } {
        switch (self.*) {
            .champ => |*it| {
                const e = it.next() orelse return null;
                return .{ .key = e.key, .value = e.value };
            },
            .sorted => |*it| {
                const e = it.next() orelse return null;
                return .{ .key = e.key, .value = e.value };
            },
        }
    }
};

fn champOrSorted(v: Value) Entries {
    return switch (v.kind()) {
        .persistent_map => .{ .champ = champ_mod.mapIter(v) },
        .record => .{ .champ = champ_mod.mapIter(record_mod.fieldsOf(v)) },
        else => .{ .sorted = sorted_mod.Iter.init(v, true) },
    };
}

// =============================================================================
// SeqIter — walking any seqable (LAZY.md §5)
// =============================================================================

/// Walks any seqable: nil, list, lazy seq, vector, typed vector, map or
/// record (as `[k v]` entries), lazy entity, set, sorted map and set,
/// string (as chars).
///
/// A lazy seq is walked through its realized chain, each block forced
/// as the walk reaches it: native context, so a step may collect. The
/// iterator holds only positions inside a chain its argument heads,
/// which the forced blocks cache, so it roots nothing of its own. A
/// map entry and a boxed typed-vector element are built by the
/// iterator, so no argument reaches them (docs/GC.md §11.5): a native
/// that keeps one across a call back into the VM, or across the next
/// step of a lazy walk, iterates with `rooted`, which pushes each on
/// its `RootScope`.
pub const SeqIter = struct {
    vm: *VM,
    state: union(enum) {
        empty,
        list: list_mod.Cursor,
        lazy: lazy.Cursor,
        vector: vector_mod.Cursor,
        typed: struct { v: Value, idx: usize, count: usize },
        map: champ_mod.MapIter,
        set: champ_mod.SetIter,
        sorted: sorted_mod.Iter,
        string: std.unicode.Utf8Iterator,
    },
    roots: ?vm_mod.RootScope = null,

    /// Every seqable receiver. A string that is not valid UTF-8 is
    /// `:utf8-error`, as for every other string operation.
    pub fn init(vm: *VM, coll: Value) VmError!SeqIter {
        return .{ .vm = vm, .state = switch (coll.kind()) {
            .nil => .empty,
            .list => if (list_mod.viewCursor(coll)) |c| .{ .vector = c } else .{ .list = list_mod.Cursor.init(coll) },
            .lazy_seq => if (lazy.shapeOf(coll) == .chunk) return VmError.KindMismatch else .{ .lazy = lazy.Cursor.init(coll) },
            .persistent_vector => .{ .vector = vector_mod.Cursor.init(coll) },
            .typed_vector => .{ .typed = .{ .v = coll, .idx = 0, .count = typed_vector_mod.count(coll) } },
            .persistent_map => .{ .map = champ_mod.mapIter(coll) },
            .record => .{ .map = champ_mod.mapIter(record_mod.fieldsOf(coll)) },
            .nextomic_entity => .{ .map = champ_mod.mapIter(try (entity_map orelse return VmError.KindMismatch)(vm, coll)) },
            .persistent_set => .{ .set = champ_mod.setIter(coll) },
            .sorted_map, .sorted_set => .{ .sorted = sorted_mod.Iter.init(coll, true) },
            .string => .{
                .string = (std.unicode.Utf8View.init(string_mod.asBytes(coll)) catch return VmError.Utf8Error).iterator(),
            },
            else => return VmError.KindMismatch,
        } };
    }

    /// `init` whose built values stay rooted in `scope`.
    pub fn rooted(vm: *VM, coll: Value, scope: vm_mod.RootScope) VmError!SeqIter {
        var it = try init(vm, coll);
        it.roots = scope;
        return it;
    }

    /// The next element, null at the end. A vector, a list and a
    /// chunk's elements step inline, in the caller's loop; every other
    /// state steps in `nextOther`.
    pub inline fn next(self: *SeqIter) VmError!?Value {
        switch (self.state) {
            .vector => |*c| return c.next(),
            .list => |*c| return c.next(),
            .lazy => |*c| if (c.items.len > 0) {
                const x = c.items[0];
                c.items = c.items[1..];
                return x;
            } else return self.nextOther(),
            else => return self.nextOther(),
        }
    }

    fn nextOther(self: *SeqIter) VmError!?Value {
        switch (self.state) {
            .empty => return null,
            .list => |*c| return c.next(),
            .vector => |*c| return c.next(),
            .lazy => |*c| while (true) {
                return c.next() catch {
                    _ = try force(self.vm, c.pending());
                    continue;
                };
            },
            .typed => |*tv| {
                if (tv.idx >= tv.count) return null;
                const e = typed_vector_mod.nth(self.vm.ensureHeap(), tv.v, tv.idx) catch return VmError.OutOfMemory;
                tv.idx += 1;
                return try self.built(e);
            },
            .map => |*it| {
                const e = it.next() orelse return null;
                return try self.built(vector_mod.fromSlice(self.vm.ensureHeap(), &.{ e.key, e.value }) catch return VmError.OutOfMemory);
            },
            .set => |*it| return it.next(),
            .sorted => |*it| {
                const e = it.next() orelse return null;
                if (!it.is_map) return e.key;
                return try self.built(vector_mod.fromSlice(self.vm.ensureHeap(), &.{ e.key, e.value }) catch return VmError.OutOfMemory);
            },
            .string => |*utf8| {
                const scalar = utf8.nextCodepoint() orelse return null;
                return value_mod.fromChar(scalar) orelse VmError.Utf8Error;
            },
        }
    }

    fn built(self: *SeqIter, v: Value) VmError!Value {
        if (self.roots) |scope| try scope.push(v);
        return v;
    }
};

// =============================================================================
// The ops vm.zig reaches (it sits below this file)
// =============================================================================

fn realizeSpineAll(vm: *VM, x: Value) VmError!void {
    return realizeSpine(vm, x, null);
}

pub const ops: vm_mod.LazyOps = .{
    .force = &force,
    .realize_spine = &realizeSpineAll,
    .realize_all = &realizeAll,
};
