//! coll/lazy.zig — the `lazy_seq` heap kind: lazy blocks, cons cells
//! with a lazy rest, and chunked cons cells.
//!
//! Authoritative spec: `docs/LAZY.md` (§2 the shapes, §3 the trace).
//! Physical storage: `src/heap.zig`. Semantics: `docs/SEMANTICS.md`
//! §2.6 (a lazy seq is sequential) and §3.3.
//!
//! This file knows the bodies and nothing about running code: building
//! the shapes, reading them, walking a realized chain (`Cursor`, which
//! stops with `error.Unrealized` at a block whose body has not run) and
//! tracing. Realizing a block needs a VM: `src/seq.zig` does it in
//! native context, and `isolated` is the hook through which `=` and
//! `hash` (`dispatch.zig`, which has no VM) realize one (LAZY.md §6).
//!
//! Shapes, in the header's flags bits 1–2 and in the Value's subkind
//! (LAZY.md §2):
//!   - 0 lazy — `{ result, op, state, argc, args[argc] }`: Clojure's
//!     `LazySeq`. `op` 0 runs `args[0]` with no arguments; any other op
//!     is a producer of `src/seq.zig` whose state is `args`.
//!   - 1 cons — `{ first, more }`: `more` is nil, a list or a lazy seq.
//!   - 2 chunked cons — `{ more, count, cap, items[cap] }`, a chunk of
//!     up to 32 elements in front of `more`; the offset of its first
//!     element in the Value's tag bits 32..63, as a list view's.

const std = @import("std");
const value = @import("../value.zig");
const heap_mod = @import("../heap.zig");
const list = @import("list.zig");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

const testing = std.testing;

// =============================================================================
// Shapes
// =============================================================================

pub const Shape = enum(u2) { lazy = 0, cons = 1, chunked = 2 };

/// The shape lives in the header's flags bits 1–2 (bit 0 is
/// `has_meta`), where the collector, which sees a header and not a
/// Value, reads it.
const shape_shift = 1;
const shape_mask: u8 = 0b11 << shape_shift;

pub fn shapeOfHeader(h: *const HeapHeader) Shape {
    return @fromBackingInt(@intCast((h.flags & shape_mask) >> shape_shift));
}

fn setShape(h: *HeapHeader, s: Shape) void {
    h.flags = (h.flags & ~shape_mask) | (@as(u8, @backingInt(s)) << shape_shift);
}

pub inline fn shapeOf(v: Value) Shape {
    std.debug.assert(v.kind() == .lazy_seq);
    return @fromBackingInt(@intCast(@as(u2, @intCast(v.subkind()))));
}

/// A lazy block's state (LAZY.md §4).
pub const State = enum(u8) {
    /// The body has not run, or ran and threw.
    unrealized = 0,
    /// The body returned another lazy block, `result`, whose own body
    /// is running or has run: this block's seq is that block's.
    forwarding = 1,
    /// `result` is nil or a non-empty seq: a non-empty list, a cons or
    /// a chunked cons.
    realized = 2,
};

const LazyBody = extern struct {
    result: Value,
    op: u16,
    state: State,
    argc: u8,
    _pad0: u32 = 0,
    _pad1: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(LazyBody) == 32);
    }

    fn args(self: *LazyBody) []Value {
        const base: [*]Value = @ptrCast(@as([*]LazyBody, @ptrCast(self)) + 1);
        return base[0..self.argc];
    }
};

const ConsBody = extern struct {
    first: Value,
    more: Value,

    comptime {
        std.debug.assert(@sizeOf(ConsBody) == 32);
    }
};

/// A chunked cons: its chunk inline, one block for both.
const ChunkedBody = extern struct {
    more: Value,
    count: u32,
    cap: u32,
    _pad: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(ChunkedBody) == 32);
    }

    fn items(self: *ChunkedBody) []Value {
        const base: [*]Value = @ptrCast(@as([*]ChunkedBody, @ptrCast(self)) + 1);
        return base[0..self.cap];
    }
};

/// The most elements a chunk holds, as Clojure's chunked seqs do.
pub const chunk_size = 32;

/// The most arguments a producer keeps in its block.
pub const max_args = 6;

// =============================================================================
// Constructors
// =============================================================================

fn valueOf(h: *HeapHeader, s: Shape) Value {
    return .{
        .tag = @as(u64, @backingInt(Kind.lazy_seq)) | (@as(u64, @backingInt(s)) << 16),
        .payload = @intFromPtr(h),
    };
}

/// An unrealized block that runs producer `op` over `args` (op 0: a
/// `lazy-seq` body, `args[0]` the function to call).
pub fn unrealized(heap: *Heap, op_code: u16, state_args: []const Value) !Value {
    std.debug.assert(state_args.len <= max_args);
    const h = try heap.alloc(.lazy_seq, @sizeOf(LazyBody) + state_args.len * @sizeOf(Value));
    setShape(h, .lazy);
    const body = Heap.bodyOf(LazyBody, h);
    body.op = op_code;
    body.argc = @intCast(state_args.len);
    @memcpy(body.args(), state_args);
    return valueOf(h, .lazy);
}

/// A realized block whose seq is `s` (nil or a non-empty seq),
/// carrying `meta`: what `with-meta` returns (LAZY.md §4).
pub fn realizedWithMeta(heap: *Heap, s: Value, meta: ?*HeapHeader) !Value {
    std.debug.assert(isSeqResult(s));
    const h = try heap.alloc(.lazy_seq, @sizeOf(LazyBody));
    setShape(h, .lazy);
    const body = Heap.bodyOf(LazyBody, h);
    body.result = s;
    body.state = .realized;
    h.setMeta(meta);
    return valueOf(h, .lazy);
}

/// `first` in front of `more`: nil, a list or a lazy seq, which is not
/// realized.
pub fn cons(heap: *Heap, first_v: Value, more_v: Value) !Value {
    std.debug.assert(isMore(more_v));
    const h = try heap.alloc(.lazy_seq, @sizeOf(ConsBody));
    setShape(h, .cons);
    Heap.bodyOf(ConsBody, h).* = .{ .first = first_v, .more = more_v };
    return valueOf(h, .cons);
}

/// A fresh chunked cons with room for `cap` elements, every slot nil,
/// its count 0 and its `more` nil. A producer fills it in place
/// (`chunkItems`, then `finishChunked`) while it is reachable from the
/// producer's block (`setScratch`), so a collection in the middle of
/// the fill marks every slot.
pub fn allocChunked(heap: *Heap, cap: usize) !Value {
    std.debug.assert(cap > 0 and cap <= std.math.maxInt(u32));
    const h = try heap.alloc(.lazy_seq, @sizeOf(ChunkedBody) + cap * @sizeOf(Value));
    setShape(h, .chunked);
    Heap.bodyOf(ChunkedBody, h).cap = @intCast(cap);
    return valueOf(h, .chunked);
}

/// Close the fill of `c`: its first `n` (at least one) elements, then
/// `more`.
pub fn finishChunked(c: Value, n: usize, more_v: Value) void {
    std.debug.assert(isMore(more_v));
    const body = chunkedBody(c);
    std.debug.assert(n > 0 and n <= body.cap);
    body.count = @intCast(n);
    body.more = more_v;
}

/// A copy of `items` (at least one) in front of `more`.
pub fn chunkedOf(heap: *Heap, items: []const Value, more_v: Value) !Value {
    const c = try allocChunked(heap, items.len);
    @memcpy(chunkItems(c)[0..items.len], items);
    finishChunked(c, items.len, more_v);
    return c;
}

// =============================================================================
// Accessors
// =============================================================================

fn lazyBody(v: Value) *LazyBody {
    std.debug.assert(shapeOf(v) == .lazy);
    return Heap.bodyOf(LazyBody, Heap.asHeapHeader(v));
}

fn consBody(v: Value) *ConsBody {
    std.debug.assert(shapeOf(v) == .cons);
    return Heap.bodyOf(ConsBody, Heap.asHeapHeader(v));
}

fn chunkedBody(c: Value) *ChunkedBody {
    std.debug.assert(shapeOf(c) == .chunked);
    return Heap.bodyOf(ChunkedBody, Heap.asHeapHeader(c));
}

/// Whether `v` may be the `more` of a cons: nil, a list or a lazy seq.
pub fn isMore(v: Value) bool {
    return switch (v.kind()) {
        .nil, .list, .lazy_seq => true,
        else => false,
    };
}

/// Whether `s` may be a realized block's result: nil or a non-empty
/// seq (LAZY.md §4, the normal form).
pub fn isSeqResult(s: Value) bool {
    return switch (s.kind()) {
        .nil => true,
        .list => !list.isEmpty(s),
        .lazy_seq => shapeOf(s) == .cons or shapeOf(s) == .chunked,
        else => false,
    };
}

pub fn state(lz: Value) State {
    return lazyBody(lz).state;
}

pub fn result(lz: Value) Value {
    return lazyBody(lz).result;
}

pub fn op(lz: Value) u16 {
    return lazyBody(lz).op;
}

/// A producer's state, read and written in place.
pub fn args(lz: Value) []Value {
    return lazyBody(lz).args();
}

/// Root `v` in the result field of `lz`, a block whose body has not
/// run: what a producer fills while it runs, so a collection inside a
/// call marks it (a step that throws leaves it there, garbage the next
/// run replaces).
pub fn setScratch(lz: Value, v: Value) void {
    std.debug.assert(state(lz) == .unrealized);
    lazyBody(lz).result = v;
}

/// `lz` forwards to `next`, an unrealized or forwarding block, whose
/// body runs in its stead; `lz`'s own state is dropped.
pub fn setForwarding(lz: Value, next: Value) void {
    std.debug.assert(next.kind() == .lazy_seq and shapeOf(next) == .lazy);
    const body = lazyBody(lz);
    body.result = next;
    body.state = .forwarding;
    @memset(body.args(), value.nilValue());
}

/// `lz`'s body has run to `s`; its state is dropped, so what it held
/// is garbage once nothing else holds it.
pub fn setRealized(lz: Value, s: Value) void {
    std.debug.assert(isSeqResult(s));
    const body = lazyBody(lz);
    body.result = s;
    body.state = .realized;
    @memset(body.args(), value.nilValue());
}

pub fn first(c: Value) Value {
    if (shapeOf(c) == .cons) return consBody(c).first;
    return chunkItems(c)[chunkOffset(c)];
}

/// What follows a cons, or a chunked cons's chunk.
pub fn more(c: Value) Value {
    if (shapeOf(c) == .cons) return consBody(c).more;
    return chunkedBody(c).more;
}

pub fn chunkOffset(c: Value) usize {
    std.debug.assert(shapeOf(c) == .chunked);
    return @intCast(c.tag >> 32);
}

/// The chunked cons `c` at `offset` into its chunk: the same block, so
/// a `rest` inside a chunk allocates nothing.
pub fn atOffset(c: Value, offset: usize) Value {
    std.debug.assert(shapeOf(c) == .chunked and offset < chunkedCount(c));
    return .{ .tag = (c.tag & 0xFFFF_FFFF) | (@as(u64, @as(u32, @intCast(offset))) << 32), .payload = c.payload };
}

/// The elements a chunked cons holds from its offset on.
pub fn chunkRest(c: Value) []const Value {
    return chunkItems(c)[chunkOffset(c)..chunkedCount(c)];
}

/// Every slot of a chunked cons's chunk, its capacity's worth.
pub fn chunkItems(c: Value) []Value {
    return chunkedBody(c).items();
}

/// How many elements a chunked cons's chunk holds.
pub fn chunkedCount(c: Value) usize {
    return chunkedBody(c).count;
}

// =============================================================================
// Isolated realization (LAZY.md §6)
// =============================================================================

/// The innermost running VM, as `dispatch` reaches it: `=` and `hash`
/// realize a block they meet through `isolated.realize`, which runs
/// the block's body with collection held and any throw caught and
/// parked on the VM. Null outside a run: a block that would have to
/// run spoils the answer.
pub const Host = struct {
    ctx: *anyopaque,
    /// The seq of the lazy block `lz`, or null when realizing it
    /// failed (the failure is parked on the host).
    realize: *const fn (ctx: *anyopaque, lz: Value) ?Value,
};

pub threadlocal var host: ?Host = null;

/// Realize the lazy block `lz` in isolation: its seq, or null.
pub fn realizeIsolated(lz: Value) ?Value {
    std.debug.assert(shapeOf(lz) == .lazy);
    if (state(lz) == .realized) return result(lz);
    const h = host orelse return null;
    return h.realize(h.ctx, lz);
}

// =============================================================================
// Cursor — walking a realized chain
// =============================================================================

/// The elements of a seq: nil, a list or a lazy seq. `next` stops with
/// `error.Unrealized` at a lazy block whose body has not run, leaving
/// it in `rest`; whoever walks realizes it (`seq.force` in native
/// context, `realizeIsolated` under `=` and `hash`) and calls `next`
/// again, which then walks into the block's cached seq. A chunk's
/// elements step inline in the caller's loop; once the walk reaches a
/// list it steps the list's cursor.
pub const Cursor = struct {
    /// What follows `items`: nil, a list, or a lazy seq.
    rest: Value,
    /// The elements of a chunk still to be yielded.
    items: []const Value = &.{},
    list_cursor: ?list.Cursor = null,

    pub fn init(v: Value) Cursor {
        std.debug.assert(isMore(v));
        return .{ .rest = v };
    }

    pub inline fn next(self: *Cursor) error{Unrealized}!?Value {
        if (self.items.len > 0) {
            const x = self.items[0];
            self.items = self.items[1..];
            return x;
        }
        if (self.list_cursor) |*c| return c.next();
        return self.nextCell();
    }

    fn nextCell(self: *Cursor) error{Unrealized}!?Value {
        while (true) switch (self.rest.kind()) {
            .nil => return null,
            .list => {
                self.list_cursor = list.Cursor.init(self.rest);
                return self.list_cursor.?.next();
            },
            .lazy_seq => switch (shapeOf(self.rest)) {
                .lazy => switch (state(self.rest)) {
                    .unrealized => return error.Unrealized,
                    .forwarding, .realized => self.rest = result(self.rest),
                },
                .cons => {
                    const body = consBody(self.rest);
                    self.rest = body.more;
                    return body.first;
                },
                .chunked => {
                    const items = chunkRest(self.rest);
                    self.items = items[1..];
                    self.rest = more(self.rest);
                    return items[0];
                },
            },
            else => unreachable,
        };
    }

    /// The unrealized block `next` stopped at.
    pub fn pending(self: *const Cursor) Value {
        return self.rest;
    }
};

// =============================================================================
// GC trace (LAZY.md §3, GC.md §5)
// =============================================================================

/// Walk the chain that starts at `h` in a loop, as `list.trace` walks
/// a cons chain: each block's elements and producer state are marked
/// as values, and the next block of the chain (a cons's `more`, a lazy
/// block's `result`) is marked here, through `markInternal`, instead
/// of handed back, so a chain of any length costs no worklist and no
/// recursion. The walk stops at the end, at a list (marked as a value,
/// whose own trace walks its cells) or at a block already marked. A
/// chunk marks every slot of its capacity: unwritten slots are nil.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    var cell = h;
    while (true) {
        const next: Value = switch (shapeOfHeader(cell)) {
            .lazy => blk: {
                const body = Heap.bodyOf(LazyBody, cell);
                for (body.args()) |a| if (a.kind().isHeap()) visitor.markValue(a);
                break :blk body.result;
            },
            .cons => blk: {
                const body = Heap.bodyOf(ConsBody, cell);
                if (body.first.kind().isHeap()) visitor.markValue(body.first);
                break :blk body.more;
            },
            // Its elements every slot of the chunk's capacity (unwritten
            // ones are nil), immediates skipped inline as a vector leaf's
            // are.
            .chunked => blk: {
                const body = Heap.bodyOf(ChunkedBody, cell);
                for (body.items()) |x| if (x.kind().isHeap()) visitor.markValue(x);
                break :blk body.more;
            },
        };
        if (next.kind() != .lazy_seq) return visitor.markValue(next);
        const nh = Heap.asHeapHeader(next);
        if (!visitor.markInternal(nh)) return;
        if (nh.meta) |m| visitor.mark(m);
        cell = nh;
    }
}

// =============================================================================
// Tests
// =============================================================================

fn fx(n: i64) Value {
    return value.fromFixnum(n).?;
}

/// The elements of a realized seq, in a fixed buffer.
fn collect(v: Value, buf: []Value) ![]Value {
    var c = Cursor.init(v);
    var n: usize = 0;
    while (try c.next()) |x| : (n += 1) buf[n] = x;
    return buf[0..n];
}

test "shapes: a cons, a chunked cons and a realized block walk as their elements" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const tail = try list.fromSlice(&heap, &.{ fx(5), fx(6) });
    const cc = try chunkedOf(&heap, &.{ fx(2), fx(3), fx(4) }, tail);
    const block = try realizedWithMeta(&heap, cc, null);
    const c = try cons(&heap, fx(1), block);
    var buf: [8]Value = undefined;
    const got = try collect(c, &buf);
    try testing.expectEqual(@as(usize, 6), got.len);
    for (got, 1..) |x, i| try testing.expectEqual(@as(i64, @intCast(i)), x.asFixnum());
    // A chunked cons past its first element is the same block.
    const at2 = atOffset(cc, 2);
    try testing.expectEqual(cc.payload, at2.payload);
    try testing.expectEqual(@as(i64, 4), first(at2).asFixnum());
    try testing.expectEqual(@as(usize, 3), (try collect(at2, &buf)).len);
}

test "Cursor: an unrealized block stops the walk and stays pending" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const lz = try unrealized(&heap, 0, &.{value.nilValue()});
    const c = try cons(&heap, fx(1), lz);
    var cur = Cursor.init(c);
    try testing.expectEqual(@as(i64, 1), (try cur.next()).?.asFixnum());
    try testing.expectError(error.Unrealized, cur.next());
    try testing.expect(cur.pending().identicalTo(lz));
    setRealized(lz, try list.fromSlice(&heap, &.{fx(2)}));
    try testing.expectEqual(@as(i64, 2), (try cur.next()).?.asFixnum());
    try testing.expectEqual(@as(?Value, null), try cur.next());
}
