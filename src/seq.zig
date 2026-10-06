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
const transient_mod = @import("coll/transient.zig");
const typed_vector_mod = @import("coll/typed_vector.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const string_mod = @import("string.zig");
const record_mod = @import("record.zig");
const dispatch_mod = @import("dispatch.zig");
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

/// The producers (LAZY.md §7), indexed by a block's `op`.
pub const op_thunk: u16 = 0;
/// A finite range of fixnums, a chunk of 32 at a time: `{start, end, step}`.
pub const op_range: u16 = 1;
/// A finite range over the numeric tower, a chunk of 32 at a time:
/// `{start, end, step}`.
pub const op_range_num: u16 = 2;
/// `(range)`, one element at a time, as Clojure's `(iterate inc' 0)`:
/// `{n}`.
pub const op_range_inf: u16 = 3;
/// `(repeat x)`: `{x}`. Its seq is one cons cell whose rest is the
/// block itself, so walking it allocates nothing.
pub const op_repeat: u16 = 4;
/// `(map f coll)`: `{f, coll}`, a chunk of 32 where the source is
/// chunked (§7).
pub const op_map: u16 = 5;
/// `(filter pred coll)`, `(remove pred coll)`, `(keep f coll)`:
/// `{f, coll}`.
pub const op_filter: u16 = 6;
pub const op_remove: u16 = 7;
pub const op_keep: u16 = 8;
/// `(map-indexed f coll)`, `(keep-indexed f coll)`: `{f, coll, index}`.
pub const op_map_indexed: u16 = 9;
pub const op_keep_indexed: u16 = 10;
/// `(map f c1 c2 ...)`: `{f, c1, c2, ...}`, or `{f, [c1 c2 ...]}` past
/// five colls, one element at a time, as Clojure's.
pub const op_map_n: u16 = 11;
/// `(iterate f x)`: `{f, x}`, whose first element is `x` itself; every
/// later one is `{f, prev}` under `op_iterate_next`, which calls `f`
/// when the element is first needed, as Clojure's `Iterate`.
pub const op_iterate: u16 = 12;
pub const op_iterate_next: u16 = 13;
/// `(repeat n x)`: `{n, x}`, `n` at least 1.
pub const op_repeat_n: u16 = 14;
/// `(repeatedly f)`: `{f}`; `(repeatedly n f)`: `{f, n}`.
pub const op_repeatedly: u16 = 15;
/// `(cycle coll)`: `{all, current}`, both seqs of `coll`; `all` is not
/// nil.
pub const op_cycle: u16 = 16;
/// `(concat ...)`, `(mapcat ...)`: `{coll, colls}`, the coll being
/// walked and the seqable of those after it; a chunked source's chunk
/// is copied into a chunked cons of its own.
pub const op_concat: u16 = 17;
/// `(take n coll)`: `{n, coll}`.
pub const op_take: u16 = 18;
/// `(drop n coll)`: `{n, coll}`; the walk runs at realization.
pub const op_drop: u16 = 19;
/// `(take-while pred coll)`, `(drop-while pred coll)`: `{pred, coll}`.
pub const op_take_while: u16 = 20;
pub const op_drop_while: u16 = 21;
/// `(partition n step coll)`, with a pad, `partition-all`: `{n, step,
/// pad, coll, mode}`, mode 0 `partition`, 1 with a pad, 2
/// `partition-all`.
pub const op_partition: u16 = 22;
/// `(distinct coll)`: `{coll, seen}`, `seen` a persistent set, which a
/// step that throws and runs again finds as it was.
pub const op_distinct: u16 = 23;
/// `(dedupe coll)`: `{coll, last, seen-one}`, 32 elements of output at
/// a time, as Clojure's `sequence` over its transducer.
pub const op_dedupe: u16 = 24;
/// `(sequence xform coll)`: `{rf, coll, done, spread}`, `rf` the
/// transducer applied to `conj!`, `done` true once the source ended or
/// `rf` returned a reduced value, `spread` true when each element is a
/// tuple of the colls to pass `rf` as separate arguments (§10).
pub const op_sequence: u16 = 25;

const steps = [_]Step{
    stepThunk,
    stepRange,
    stepRangeNum,
    stepRangeInf,
    stepRepeat,
    stepSieve(.map),
    stepSieve(.filter),
    stepSieve(.remove),
    stepSieve(.keep),
    stepSieve(.map_indexed),
    stepSieve(.keep_indexed),
    stepMapN,
    stepIterate,
    stepIterateNext,
    stepRepeatN,
    stepRepeatedly,
    stepCycle,
    stepConcat,
    stepTake,
    stepDrop,
    stepTakeWhile,
    stepDropWhile,
    stepPartition,
    stepDistinct,
    stepDedupe,
    stepSequence,
};

/// Whether `v` is a `reduced` value, and the value inside: the record
/// type the VM registers for it (`VM.reduced_type_id`).
fn unreduced(vm: *VM, v: Value) ?Value {
    const id = vm.home().reduced_type_id orelse return null;
    if (v.kind() != .record or record_mod.typeId(v) != id) return null;
    var it = champ_mod.mapIter(record_mod.fieldsOf(v));
    return (it.next() orelse return null).value;
}

/// The transient vector a step accumulates into, rooted in the block's
/// result field; the outputs a step hands out are its elements.
fn stepSequence(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    if (a[2].isTruthy()) return value_mod.nilValue();
    const heap = vm.ensureHeap();
    const empty = vector_mod.empty(heap) catch return VmError.OutOfMemory;
    var acc = transient_mod.transientFrom(heap, empty) catch return VmError.OutOfMemory;
    lazy.setScratch(lz, acc);
    var cur = a[1];
    var done = false;
    var args: [lazy.chunk_size + 1]Value = undefined;
    // Pull inputs until a chunk's worth of outputs waits, the source
    // ends, or `rf` stops the reduction; the position is a local, so a
    // step that throws runs again from the block's own state.
    while (true) {
        if (acc.kind() != .transient) return VmError.KindMismatch;
        const n = transient_mod.vectorCountBang(acc) catch return VmError.KindMismatch;
        if (n >= lazy.chunk_size) break;
        cur = try seqOf(vm, cur);
        if (cur.isNil()) {
            done = true;
            break;
        }
        const fr = firstRest(cur);
        args[0] = acc;
        var argc: usize = 2;
        if (a[3].isTruthy()) {
            const tuple = fr.first;
            const k = vector_mod.count(tuple);
            if (k + 1 > args.len) return VmError.ArityMismatch;
            for (0..k) |i| args[1 + i] = vector_mod.nth(tuple, i);
            argc = k + 1;
        } else args[1] = fr.first;
        const r = try vm.callValue(a[0], args[0..argc]);
        cur = fr.rest;
        if (unreduced(vm, r)) |inner| {
            acc = inner;
            lazy.setScratch(lz, acc);
            done = true;
            break;
        }
        acc = r;
        lazy.setScratch(lz, acc);
    }
    // The completion arity runs once, at the end: `partition-all`'s last
    // part comes out there.
    if (done) {
        acc = try vm.callValue(a[0], &.{acc});
        if (unreduced(vm, acc)) |inner| acc = inner;
        lazy.setScratch(lz, acc);
    }
    if (acc.kind() != .transient) return VmError.KindMismatch;
    const out = transient_mod.persistentBang(acc) catch return VmError.OutOfMemory;
    // Nothing below runs code, and `Heap.alloc` never collects.
    const following = if (done) value_mod.nilValue() else try make(vm, op_sequence, &.{ a[0], cur, value_mod.fromBool(false), a[3] });
    const n = vector_mod.count(out);
    if (n == 0) return following;
    const c = lazy.allocChunked(heap, n) catch return VmError.OutOfMemory;
    var it = vector_mod.Cursor.init(out);
    for (lazy.chunkItems(c)) |*slot| slot.* = it.next().?;
    lazy.finishChunked(c, n, following);
    return c;
}

fn stepConcat(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    // Empty colls are skipped here; what the walk has passed goes back
    // into the block, which keeps it reachable while the next is forced.
    while (true) {
        a[0] = try seqOf(vm, a[0]);
        if (!a[0].isNil()) break;
        a[1] = try seqOf(vm, a[1]);
        if (a[1].isNil()) return a[1];
        const fr = firstRest(a[1]);
        a[0] = fr.first;
        a[1] = fr.rest;
    }
    const s = a[0];
    const heap = vm.ensureHeap();
    if (chunkOf(s)) |ch| {
        const following = try make(vm, op_concat, &.{ ch.after, a[1] });
        return lazy.chunkedOf(heap, ch.items, following) catch VmError.OutOfMemory;
    }
    const fr = firstRest(s);
    const following = try make(vm, op_concat, &.{ fr.rest, a[1] });
    return lazy.cons(heap, fr.first, following) catch VmError.OutOfMemory;
}

fn stepTake(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const n = a[0].asFixnum();
    if (n <= 0) return value_mod.nilValue();
    a[1] = try seqOf(vm, a[1]);
    if (a[1].isNil()) return a[1];
    const fr = firstRest(a[1]);
    const more = if (n > 1) try make(vm, op_take, &.{ fixnum(n - 1), fr.rest }) else value_mod.nilValue();
    return lazy.cons(vm.ensureHeap(), fr.first, more) catch VmError.OutOfMemory;
}

/// `coll` without its first `n` elements, walking: a list's view and
/// an unrealized range or repeat jump at once.
pub fn dropFrom(vm: *VM, coll: Value, n: usize) VmError!Value {
    if (pureOf(coll)) |p| switch (p) {
        .range => |r| {
            const left = rangeCount(r.start, r.end, r.step);
            if (n >= left) return value_mod.nilValue();
            return make(vm, op_range, &.{ fixnum(r.start + @as(i64, @intCast(n)) * r.step), fixnum(r.end), fixnum(r.step) });
        },
        .repeat => return coll,
        .repeat_n => |r| {
            if (n >= r.n) return value_mod.nilValue();
            return make(vm, op_repeat_n, &.{ fixnum(r.n - @as(i64, @intCast(n))), r.x });
        },
        else => {},
    };
    var xs = coll;
    var left = n;
    while (left > 0) {
        const s = try seqOf(vm, xs);
        if (s.isNil()) return s;
        if (s.kind() == .list) return list_mod.drop(s, left);
        xs = firstRest(s).rest;
        left -= 1;
    }
    return xs;
}

fn stepDrop(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    return dropFrom(vm, a[1], @intCast(@max(a[0].asFixnum(), 0)));
}

fn stepTakeWhile(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    a[1] = try seqOf(vm, a[1]);
    if (a[1].isNil()) return a[1];
    const fr = firstRest(a[1]);
    if (!(try vm.callValue(a[0], &.{fr.first})).isTruthy()) return value_mod.nilValue();
    const more = try make(vm, op_take_while, &.{ a[0], fr.rest });
    return lazy.cons(vm.ensureHeap(), fr.first, more) catch VmError.OutOfMemory;
}

fn stepDropWhile(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    var cb = vm_mod.Callback.init(vm, a[0], 1);
    while (true) {
        a[1] = try seqOf(vm, a[1]);
        if (a[1].isNil()) return a[1];
        const fr = firstRest(a[1]);
        if (!(try cb.call(&.{fr.first})).isTruthy()) return a[1];
        a[1] = fr.rest;
    }
}

fn stepPartition(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const n: usize = @intCast(a[0].asFixnum());
    const mode = a[4].asFixnum();
    a[3] = try seqOf(vm, a[3]);
    const s = a[3];
    if (s.isNil()) return s;
    // The part's elements reach from `s`; the pad's from the block.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(vm.allocator);
    var it = try SeqIter.init(vm, s);
    while (items.items.len < n) {
        const x = (try it.next()) orelse break;
        items.append(vm.allocator, x) catch return VmError.OutOfMemory;
    }
    const short = items.items.len < n;
    if (short and mode == 0) return value_mod.nilValue();
    if (short and mode == 1) {
        var pad = try SeqIter.init(vm, a[2]);
        while (items.items.len < n) {
            const x = (try pad.next()) orelse break;
            items.append(vm.allocator, x) catch return VmError.OutOfMemory;
        }
    }
    const after = if (short and mode == 1) value_mod.nilValue() else try dropFrom(vm, s, @intCast(a[1].asFixnum()));
    // Nothing below runs code, and `Heap.alloc` never collects.
    const heap = vm.ensureHeap();
    const elems = list_mod.build(heap, items.items) catch return VmError.OutOfMemory;
    const part = lazy.realizedWithMeta(heap, elems, null) catch return VmError.OutOfMemory;
    if (short and mode == 1) return list_mod.cons(heap, part, list_mod.empty(heap) catch return VmError.OutOfMemory) catch VmError.OutOfMemory;
    const more = try make(vm, op_partition, &.{ a[0], a[1], a[2], after, a[4] });
    return lazy.cons(heap, part, more) catch VmError.OutOfMemory;
}

fn stepDistinct(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const heap = vm.ensureHeap();
    while (true) {
        a[0] = try seqOf(vm, a[0]);
        if (a[0].isNil()) return a[0];
        const fr = firstRest(a[0]);
        if (champ_mod.setContains(a[1], fr.first, &dispatch_mod.hashValue, &dispatch_mod.equal)) {
            a[0] = fr.rest;
            continue;
        }
        const seen = champ_mod.setConj(heap, a[1], fr.first, &dispatch_mod.hashValue, &dispatch_mod.equal) catch return VmError.OutOfMemory;
        const more = try make(vm, op_distinct, &.{ fr.rest, seen });
        return lazy.cons(heap, fr.first, more) catch VmError.OutOfMemory;
    }
}

fn stepDedupe(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const heap = vm.ensureHeap();
    const c = lazy.allocChunked(heap, lazy.chunk_size) catch return VmError.OutOfMemory;
    lazy.setScratch(lz, c);
    const out = lazy.chunkItems(c);
    // The walk's position and the last element are locals: a step that
    // throws runs again from the block's own state. Both reach from it.
    var cur = a[0];
    var last = a[1];
    var seen_one = a[2].isTruthy();
    var n: usize = 0;
    while (n < out.len) {
        cur = try seqOf(vm, cur);
        if (cur.isNil()) break;
        const fr = firstRest(cur);
        if (!seen_one or !dispatch_mod.equal(fr.first, last)) {
            out[n] = fr.first;
            n += 1;
            last = fr.first;
            seen_one = true;
        }
        cur = fr.rest;
    }
    if (n == 0) return value_mod.nilValue();
    const more = if (cur.isNil()) cur else try make(vm, op_dedupe, &.{ cur, last, value_mod.fromBool(true) });
    lazy.finishChunked(c, n, more);
    return c;
}

fn stepIterate(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const heap = vm.ensureHeap();
    const more = try make(vm, op_iterate_next, a[0..2]);
    return lazy.cons(heap, a[1], more) catch VmError.OutOfMemory;
}

fn stepIterateNext(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const y = try vm.callValue(a[0], a[1..2]);
    // `Heap.alloc` never collects: `y` needs no root while the next
    // block and the cell are made.
    const heap = vm.ensureHeap();
    const more = try make(vm, op_iterate_next, &.{ a[0], y });
    return lazy.cons(heap, y, more) catch VmError.OutOfMemory;
}

fn stepRepeatN(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const n = a[0].asFixnum();
    const more = if (n > 1) try make(vm, op_repeat_n, &.{ fixnum(n - 1), a[1] }) else value_mod.nilValue();
    return lazy.cons(vm.ensureHeap(), a[1], more) catch VmError.OutOfMemory;
}

fn stepRepeatedly(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    if (a.len == 2 and a[1].asFixnum() <= 0) return value_mod.nilValue();
    const y = try vm.callValue(a[0], &.{});
    const more = if (a.len == 2) try make(vm, op_repeatedly, &.{ a[0], fixnum(a[1].asFixnum() - 1) }) else try make(vm, op_repeatedly, a[0..1]);
    return lazy.cons(vm.ensureHeap(), y, more) catch VmError.OutOfMemory;
}

fn stepCycle(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    a[1] = try seqOf(vm, a[1]);
    const s = if (a[1].isNil()) a[0] else a[1];
    const fr = firstRest(s);
    const more = try make(vm, op_cycle, &.{ a[0], fr.rest });
    return lazy.cons(vm.ensureHeap(), fr.first, more) catch VmError.OutOfMemory;
}

/// What the chunked one-function producers do with each element.
const Sieve = enum {
    map,
    filter,
    remove,
    keep,
    map_indexed,
    keep_indexed,

    fn op(comptime self: Sieve) u16 {
        return switch (self) {
            .map => op_map,
            .filter => op_filter,
            .remove => op_remove,
            .keep => op_keep,
            .map_indexed => op_map_indexed,
            .keep_indexed => op_keep_indexed,
        };
    }

    fn indexed(comptime self: Sieve) bool {
        return self == .map_indexed or self == .keep_indexed;
    }
};

/// A slice of a chunked seq's elements and the seq after them, read
/// without allocating: the leaf of a vector view from its offset, or a
/// chunked cons's chunk from its offset (LAZY.md §7).
pub const Chunk = struct { items: []const Value, after: Value };

pub fn chunkOf(s: Value) ?Chunk {
    switch (s.kind()) {
        .list => {
            const items = list_mod.viewChunk(s) orelse return null;
            return .{ .items = items, .after = list_mod.drop(s, items.len) };
        },
        .lazy_seq => {
            if (lazy.shapeOf(s) != .chunked) return null;
            return .{ .items = lazy.chunkRest(s), .after = lazy.more(s) };
        },
        else => return null,
    }
}

/// The first element of a non-empty seq and the rest after it, as it
/// stands: nothing is forced and nothing allocated.
fn firstRest(s: Value) struct { first: Value, rest: Value } {
    if (s.kind() == .list) return .{ .first = list_mod.head(s), .rest = list_mod.tail(s) };
    if (lazy.shapeOf(s) == .chunked) {
        const at = lazy.chunkOffset(s) + 1;
        const after = if (at < lazy.chunkedCount(s)) lazy.atOffset(s, at) else lazy.more(s);
        return .{ .first = lazy.first(s), .rest = after };
    }
    return .{ .first = lazy.first(s), .rest = lazy.more(s) };
}

/// The step of `map`, `filter`, `remove`, `keep`, `map-indexed` and
/// `keep-indexed`. Over a chunked source a whole chunk is done at once,
/// through one prepared `vm.Callback`, into a chunk this block holds
/// in its result field while it fills (`lazy.setScratch`), so a cycle
/// inside a call marks what is written. Over any other source, one element; a filter that keeps
/// nothing returns the next block, which `force` runs in its stead
/// (§4), costing no native stack.
fn stepSieve(comptime mode: Sieve) Step {
    return &struct {
        fn step(vm: *VM, lz: Value) VmError!Value {
            const a = lazy.args(lz);
            // The source's seq goes back into the block before any call,
            // which may collect: it is the seq the elements come from.
            a[1] = try seqOf(vm, a[1]);
            const s = a[1];
            if (s.isNil()) return s;
            const heap = vm.ensureHeap();
            var cb = vm_mod.Callback.init(vm, a[0], if (comptime mode.indexed()) 2 else 1);
            var index: i64 = if (comptime mode.indexed()) a[2].asFixnum() else 0;
            if (chunkOf(s)) |whole| {
                // A chunk `chunk-cons` made of a longer vector is taken
                // 32 at a time.
                const ch: Chunk = if (whole.items.len <= lazy.chunk_size) whole else .{
                    .items = whole.items[0..lazy.chunk_size],
                    .after = lazy.atOffset(s, lazy.chunkOffset(s) + lazy.chunk_size),
                };
                var buf: [lazy.chunk_size]Value = undefined;
                const n = switch (comptime mode) {
                    // Every result is kept: they go straight into the
                    // chunk, rooted in the block while it fills.
                    .map, .map_indexed => {
                        const c = lazy.allocChunked(heap, ch.items.len) catch return VmError.OutOfMemory;
                        lazy.setScratch(lz, c);
                        const out = lazy.chunkItems(c);
                        for (ch.items, out) |x, *slot| slot.* = (try apply(mode, &cb, &index, x)).?;
                        const following = try make(vm, mode.op(), &nextArgs(mode, a[0], ch.after, index));
                        lazy.finishChunked(c, ch.items.len, following);
                        return c;
                    },
                    // What is kept is a source element, rooted with the
                    // source: it waits in a buffer, and the chunk is made
                    // to its size.
                    .filter, .remove => blk: {
                        var n: usize = 0;
                        for (ch.items) |x| if (try apply(mode, &cb, &index, x)) |y| {
                            buf[n] = y;
                            n += 1;
                        };
                        break :blk n;
                    },
                    // What is kept is a result: it waits on a root scope.
                    .keep, .keep_indexed => blk: {
                        const scope = vm.rootScope();
                        defer scope.release();
                        for (ch.items) |x| if (try apply(mode, &cb, &index, x)) |y| try scope.push(y);
                        const kept = vm.roots.items[scope.base..];
                        @memcpy(buf[0..kept.len], kept);
                        break :blk kept.len;
                    },
                };
                // `Heap.alloc` never collects: the kept values need no
                // root while the chunk and the next block are made.
                const following = try make(vm, mode.op(), &nextArgs(mode, a[0], ch.after, index));
                if (n == 0) return following;
                return lazy.chunkedOf(heap, buf[0..n], following) catch VmError.OutOfMemory;
            }
            const fr = firstRest(s);
            const kept = try apply(mode, &cb, &index, fr.first);
            // `Heap.alloc` never collects: the kept value needs no root
            // while the next block is made.
            const following = try make(vm, mode.op(), &nextArgs(mode, a[0], fr.rest, index));
            const y = kept orelse return following;
            return lazy.cons(heap, y, following) catch VmError.OutOfMemory;
        }

        fn apply(comptime m: Sieve, cb: *vm_mod.Callback, index: *i64, x: Value) VmError!?Value {
            switch (m) {
                .map => return try cb.call(&.{x}),
                .filter => return if ((try cb.call(&.{x})).isTruthy()) x else null,
                .remove => return if ((try cb.call(&.{x})).isTruthy()) null else x,
                .keep => {
                    const r = try cb.call(&.{x});
                    return if (r.isNil()) null else r;
                },
                .map_indexed, .keep_indexed => {
                    const r = try cb.call(&.{ fixnum(index.*), x });
                    index.* += 1;
                    return if (m == .keep_indexed and r.isNil()) null else r;
                },
            }
        }

        fn nextArgs(comptime m: Sieve, f: Value, src: Value, index: i64) [if (m.indexed()) 3 else 2]Value {
            if (comptime m.indexed()) return .{ f, src, fixnum(index) };
            return .{ f, src };
        }
    }.step;
}

/// `(map f c1 c2 ...)`: the first of every source, or the end at the
/// first empty one. The seqs wait on a root scope while the others are
/// forced, since the seq of a map, a set or a string is a list made
/// here.
fn stepMapN(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    // Up to `lazy.max_args - 1` colls sit in the block itself, each
    // replaced by its seq as the step takes it, which keeps it rooted
    // while the next is forced; more are a vector, whose seqs wait on a
    // root scope.
    const in_block = a.len > 2;
    const n = if (in_block) a.len - 1 else vector_mod.count(a[1]);
    const scope = vm.rootScope();
    defer scope.release();
    var buf: [2 * map_n_inline]Value = undefined;
    const pair = if (2 * n <= buf.len) buf[0 .. 2 * n] else vm.allocator.alloc(Value, 2 * n) catch return VmError.OutOfMemory;
    defer if (2 * n > buf.len) vm.allocator.free(pair);
    const firsts = pair[0..n];
    const rests = pair[n..];
    for (0..n) |i| {
        const s = try seqOf(vm, if (in_block) a[1 + i] else vector_mod.nth(a[1], i));
        if (s.isNil()) return s;
        if (in_block) a[1 + i] = s else try scope.push(s);
    }
    for (0..n) |i| {
        const fr = firstRest(if (in_block) a[1 + i] else vm.roots.items[scope.base + i]);
        firsts[i] = fr.first;
        rests[i] = fr.rest;
    }
    // The rests reach from the seqs; the firsts are the call's arguments.
    const y = try vm.callValue(a[0], firsts);
    // Nothing below runs code, and `Heap.alloc` never collects.
    const heap = vm.ensureHeap();
    const following = if (in_block) blk: {
        var next_args: [lazy.max_args]Value = undefined;
        next_args[0] = a[0];
        @memcpy(next_args[1 .. n + 1], rests);
        break :blk try make(vm, op_map_n, next_args[0 .. n + 1]);
    } else try make(vm, op_map_n, &.{ a[0], vector_mod.fromSlice(heap, rests) catch return VmError.OutOfMemory });
    return lazy.cons(heap, y, following) catch VmError.OutOfMemory;
}

/// How many colls `(map f c1 c2 ...)` keeps in its block.
pub const map_n_inline = lazy.max_args - 1;

/// `(lazy-seq body...)`: the body's function, called with no arguments.
fn stepThunk(vm: *VM, lz: Value) VmError!Value {
    return vm.callValue(lazy.args(lz)[0], &.{});
}

/// How many fixnums `(range start end step)` holds; `step` is not 0.
pub fn rangeCount(start: i64, end: i64, step: i64) u64 {
    if (step > 0) return if (start >= end) 0 else @intCast(@divFloor(end - start - 1, step) + 1);
    return if (start <= end) 0 else @intCast(@divFloor(start - end - 1, -step) + 1);
}

fn fixnum(n: i64) Value {
    return value_mod.fromFixnum(n).?;
}

fn stepRange(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const start = a[0].asFixnum();
    const step = a[2].asFixnum();
    const n = rangeCount(start, a[1].asFixnum(), step);
    const k: usize = @intCast(@min(n, lazy.chunk_size));
    const heap = vm.ensureHeap();
    const c = lazy.allocChunked(heap, k) catch return VmError.OutOfMemory;
    var x = start;
    for (lazy.chunkItems(c)[0..k]) |*slot| {
        slot.* = fixnum(x);
        x += step;
    }
    // `x` is inside the range when elements are left. `Heap.alloc`
    // never collects: the chunk needs no root while the block is made.
    const more = if (n > k) try make(vm, op_range, &.{ fixnum(x), a[1], a[2] }) else value_mod.nilValue();
    lazy.finishChunked(c, k, more);
    return c;
}

fn stepRangeNum(vm: *VM, lz: Value) VmError!Value {
    const a = lazy.args(lz);
    const heap = vm.ensureHeap();
    const ascending = (try vm_mod.numSign(a[2])).? == .gt;
    const c = lazy.allocChunked(heap, lazy.chunk_size) catch return VmError.OutOfMemory;
    const items = lazy.chunkItems(c);
    var x = a[0];
    var k: usize = 0;
    // Nothing here runs code, and `Heap.alloc` never collects: the
    // elements need no root while the chunk fills.
    while (k < items.len and try vm_mod.numCompare(if (ascending) .lt else .gt, x, a[1])) : (k += 1) {
        items[k] = x;
        x = try vm_mod.numAdd(heap, x, a[2]);
    }
    const more_left = try vm_mod.numCompare(if (ascending) .lt else .gt, x, a[1]);
    const more = if (more_left) try make(vm, op_range_num, &.{ x, a[1], a[2] }) else value_mod.nilValue();
    if (k == 0) return more;
    lazy.finishChunked(c, k, more);
    return c;
}

fn stepRangeInf(vm: *VM, lz: Value) VmError!Value {
    const n = lazy.args(lz)[0];
    const heap = vm.ensureHeap();
    const more = try make(vm, op_range_inf, &.{try vm_mod.numAdd(heap, n, fixnum(1))});
    return lazy.cons(heap, n, more) catch VmError.OutOfMemory;
}

fn stepRepeat(vm: *VM, lz: Value) VmError!Value {
    return lazy.cons(vm.ensureHeap(), lazy.args(lz)[0], lz) catch VmError.OutOfMemory;
}

/// What an unrealized block of a pure producer computes, read without
/// realizing it: `reduce`, `count`, `nth`, `drop` and the eager
/// gatherers compute over it directly, allocating and caching nothing,
/// as Clojure's `LongRange`, `Repeat` and `Iterate` reduce (LAZY.md
/// §7). Null for anything else.
pub const Pure = union(enum) {
    range: struct { start: i64, end: i64, step: i64 },
    range_inf: Value,
    repeat: Value,
    repeat_n: struct { n: i64, x: Value },
    iterate: struct { f: Value, x: Value },
    /// A cycle's whole seq, walked again and again.
    cycle: Value,
};

pub fn pureOf(coll: Value) ?Pure {
    if (coll.kind() != .lazy_seq or lazy.shapeOf(coll) != .lazy or lazy.state(coll) != .unrealized) return null;
    const a = lazy.args(coll);
    return switch (lazy.op(coll)) {
        op_range => .{ .range = .{ .start = a[0].asFixnum(), .end = a[1].asFixnum(), .step = a[2].asFixnum() } },
        op_range_inf => .{ .range_inf = a[0] },
        op_repeat => .{ .repeat = a[0] },
        op_repeat_n => .{ .repeat_n = .{ .n = a[0].asFixnum(), .x = a[1] } },
        op_iterate => .{ .iterate = .{ .f = a[0], .x = a[1] } },
        // A cycle that has not begun its walk, where `current` is `all`.
        op_cycle => if (a[1].identicalTo(a[0])) .{ .cycle = a[0] } else null,
        else => null,
    };
}

/// The fixnum range from `start` by `step` up to `end`: `()` when it
/// is empty, else an unrealized block.
pub fn makeRange(vm: *VM, start: i64, end: i64, step: i64) VmError!Value {
    if (rangeCount(start, end, step) == 0) return list_mod.empty(vm.ensureHeap()) catch VmError.OutOfMemory;
    return make(vm, op_range, &.{ fixnum(start), fixnum(end), fixnum(step) });
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
pub inline fn seqOf(vm: *VM, x: Value) VmError!Value {
    switch (x.kind()) {
        .nil => return x,
        .list => return if (list_mod.isEmpty(x)) value_mod.nilValue() else x,
        .lazy_seq => return if (lazy.shapeOf(x) == .lazy) force(vm, x) else x,
        else => return seqOfOther(vm, x),
    }
}

/// `seqOf` of a vector or any other seqable, out of the callers' lines.
fn seqOfOther(vm: *VM, x: Value) VmError!Value {
    switch (x.kind()) {
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
                if (at < lazy.chunkedCount(s)) return lazy.atOffset(s, at);
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
    if (pureOf(x)) |p| switch (p) {
        .range => |r| return @intCast(rangeCount(r.start, r.end, r.step)),
        .repeat_n => |r| return @intCast(r.n),
        else => {},
    };
    var it = try SeqIter.init(vm, x);
    var n: usize = 0;
    while (try it.next()) |_| n += 1;
    return n;
}

/// The element at `i` of a seq, or null past its end.
pub fn nthOf(vm: *VM, x: Value, i: usize) VmError!?Value {
    if (pureOf(x)) |p| switch (p) {
        .range => |r| return if (i < rangeCount(r.start, r.end, r.step)) fixnum(r.start + @as(i64, @intCast(i)) * r.step) else null,
        .repeat => |v| return v,
        .repeat_n => |r| return if (i < r.n) r.x else null,
        else => {},
    };
    var it = try SeqIter.init(vm, x);
    for (0..i) |_| _ = (try it.next()) orelse return null;
    return it.next();
}

/// Realize `x`'s spine: `doall` and `dorun`. With a `limit`, as
/// Clojure's `(dorun n coll)`: `next` `limit` times, which realizes the
/// step after the last element walked.
pub fn realizeSpine(vm: *VM, x: Value, limit: ?usize) VmError!void {
    const n = limit orelse {
        var it = try SeqIter.realizing(vm, x);
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
    _ = try realizeAllFound(vm, root);
}

/// `realizeAll`, answering whether `root` holds a lazy seq.
fn realizeAllFound(vm: *VM, root: Value) VmError!bool {
    if (!mayHoldLazy(root.kind())) return false;
    var work: std.ArrayList(Value) = .empty;
    defer work.deinit(vm.allocator);
    // Shared structure is walked once; the root's elements alone (a
    // vector key of scalars) allocate nothing.
    var seen: std.AutoHashMapUnmanaged(u128, void) = .empty;
    defer seen.deinit(vm.allocator);
    var found = root.kind() == .lazy_seq;
    try pushParts(vm, root, &work, &found);
    while (work.pop()) |v| {
        const key = @as(u128, v.tag) << 64 | v.payload;
        if ((seen.getOrPut(vm.allocator, key) catch return VmError.OutOfMemory).found_existing) continue;
        try pushParts(vm, v, &work, &found);
    }
    return found;
}

/// Walk `v`, realizing it if it is a lazy seq, and push the parts that
/// may hold one.
fn pushParts(vm: *VM, v: Value, work: *std.ArrayList(Value), found: *bool) VmError!void {
    switch (v.kind()) {
        .persistent_map, .sorted_map, .record => {
            var it = champOrSorted(v);
            while (it.next()) |e| {
                for ([_]Value{ e.key, e.value }) |x| if (mayHoldLazy(x.kind())) {
                    if (x.kind() == .lazy_seq) found.* = true;
                    work.append(vm.allocator, x) catch return VmError.OutOfMemory;
                };
            }
        },
        else => {
            var it = try SeqIter.realizing(vm, v);
            while (try it.next()) |x| if (mayHoldLazy(x.kind())) {
                if (x.kind() == .lazy_seq) found.* = true;
                work.append(vm.allocator, x) catch return VmError.OutOfMemory;
            };
        },
    }
}

/// `v` with every lazy seq in it realized and made the list of its
/// elements, at any depth: for code that walks a value as data and
/// knows lists, not lazy seqs (the expander making a macro's result a
/// form, the Nextomic parsers and marshaller; docs/LAZY.md §8). `v`
/// itself when it holds none; otherwise a copy of the collections on
/// the way to one, sharing the rest, each keeping its metadata. A
/// sorted collection is shared as it is: rebuilding one could run its
/// comparator. `v` must be rooted; the copy is not.
pub fn asLists(vm: *VM, v: Value) VmError!Value {
    if (!try realizeAllFound(vm, v)) return v;
    // Nothing below runs code: every lazy seq is realized, and
    // `Heap.alloc` never collects.
    return listify(vm.ensureHeap(), v) catch |err| switch (err) {
        error.StackOverflow => VmError.StackOverflow,
        else => VmError.OutOfMemory,
    };
}

const ListifyError = error{ StackOverflow, OutOfMemory, Unrealized };

fn listify(heap: *heap_mod.Heap, v: Value) ListifyError!Value {
    try stack_guard.check();
    const hash = &dispatch_mod.hashValue;
    const eql = &dispatch_mod.equal;
    switch (v.kind()) {
        .lazy_seq, .list => {
            var items: std.ArrayList(Value) = .empty;
            defer items.deinit(heap.backing);
            var changed = v.kind() == .lazy_seq;
            var c = lazy.Cursor.init(v);
            while (try c.next()) |x| {
                const y = try listify(heap, x);
                changed = changed or !y.identicalTo(x);
                try items.append(heap.backing, y);
            }
            if (!changed) return v;
            const out = list_mod.build(heap, items.items) catch return error.OutOfMemory;
            if (v.kind() == .list) keepMeta(v, out);
            return out;
        },
        .persistent_vector => {
            const n = vector_mod.count(v);
            const items = try heap.backing.alloc(Value, n);
            defer heap.backing.free(items);
            var changed = false;
            for (items, 0..) |*slot, i| {
                const x = vector_mod.nth(v, i);
                slot.* = try listify(heap, x);
                changed = changed or !slot.identicalTo(x);
            }
            if (!changed) return v;
            const out = vector_mod.fromSlice(heap, items) catch return error.OutOfMemory;
            keepMeta(v, out);
            return out;
        },
        .persistent_map, .record => {
            const m = if (v.kind() == .record) record_mod.fieldsOf(v) else v;
            var out = champ_mod.mapEmpty(heap) catch return error.OutOfMemory;
            var changed = false;
            var it = champ_mod.mapIter(m);
            while (it.next()) |e| {
                const k = try listify(heap, e.key);
                const x = try listify(heap, e.value);
                changed = changed or !k.identicalTo(e.key) or !x.identicalTo(e.value);
                out = champ_mod.mapAssoc(heap, out, k, x, hash, eql) catch return error.OutOfMemory;
            }
            if (!changed) return v;
            if (v.kind() == .record) return record_mod.withFields(heap, v, out) catch error.OutOfMemory;
            keepMeta(v, out);
            return out;
        },
        .persistent_set => {
            var out = champ_mod.setEmpty(heap) catch return error.OutOfMemory;
            var changed = false;
            var it = champ_mod.setIter(v);
            while (it.next()) |x| {
                const y = try listify(heap, x);
                changed = changed or !y.identicalTo(x);
                out = champ_mod.setConj(heap, out, y, hash, eql) catch return error.OutOfMemory;
            }
            if (!changed) return v;
            keepMeta(v, out);
            return out;
        },
        else => return v,
    }
}

fn keepMeta(from: Value, to: Value) void {
    heap_mod.Heap.asHeapHeader(to).setMeta(heap_mod.Heap.asHeapHeader(from).getMeta());
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
/// which the forced blocks cache, so it roots nothing of its own. An
/// unrealized fixnum range is computed instead, caching nothing, as
/// Clojure's `LongRange` iterates (LAZY.md §7); `realizing` walks it
/// as any other lazy seq, for `doall` and `realizeAll`. A
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
        range: struct { x: i64, step: i64, left: u64 },
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
        if (pureOf(coll)) |p| if (p == .range) {
            const r = p.range;
            return .{ .vm = vm, .state = .{ .range = .{ .x = r.start, .step = r.step, .left = rangeCount(r.start, r.end, r.step) } } };
        };
        return realizing(vm, coll);
    }

    /// `init` that realizes an unrealized range as it walks it.
    pub fn realizing(vm: *VM, coll: Value) VmError!SeqIter {
        return .{ .vm = vm, .state = switch (coll.kind()) {
            .nil => .empty,
            .list => if (list_mod.viewCursor(coll)) |c| .{ .vector = c } else .{ .list = list_mod.Cursor.init(coll) },
            .lazy_seq => .{ .lazy = lazy.Cursor.init(coll) },
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
            .range => |*r| {
                if (r.left == 0) return null;
                const x = r.x;
                r.x += r.step;
                r.left -= 1;
                return fixnum(x);
            },
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
