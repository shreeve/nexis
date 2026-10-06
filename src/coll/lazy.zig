//! coll/lazy.zig — the `lazy_seq` heap kind: lazy blocks, cons cells
//! with a lazy rest, chunked cons cells and their chunks.
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
//!   - 2 chunked cons — `{ chunk, more }`, the offset into the chunk in
//!     the Value's tag bits 32..63, as a list view's.
//!   - 3 chunk — `{ count, cap, items[cap] }`, held by chunked cons
//!     cells and never a user value.

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

pub const Shape = enum(u2) { lazy = 0, cons = 1, chunked = 2, chunk = 3 };

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
    /// The first element, or a chunked cons's chunk.
    first: Value,
    more: Value,

    comptime {
        std.debug.assert(@sizeOf(ConsBody) == 32);
    }
};

const ChunkBody = extern struct {
    count: u32,
    cap: u32,
    _pad: u64 = 0,

    comptime {
        std.debug.assert(@sizeOf(ChunkBody) == 16);
    }

    fn items(self: *ChunkBody) []Value {
        const base: [*]Value = @ptrCast(@as([*]ChunkBody, @ptrCast(self)) + 1);
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

/// A fresh chunk with room for `cap` elements, every slot nil and its
/// count 0. A producer fills it in place (`chunkItems`, `setChunkCount`)
/// while it is reachable from the producer's block, so a collection in
/// the middle of the fill marks every slot.
pub fn allocChunk(heap: *Heap, cap: usize) !Value {
    std.debug.assert(cap > 0 and cap <= std.math.maxInt(u32));
    const h = try heap.alloc(.lazy_seq, @sizeOf(ChunkBody) + cap * @sizeOf(Value));
    setShape(h, .chunk);
    Heap.bodyOf(ChunkBody, h).cap = @intCast(cap);
    return valueOf(h, .chunk);
}

/// A chunk holding a copy of `items`.
pub fn chunkOf(heap: *Heap, items: []const Value) !Value {
    const c = try allocChunk(heap, items.len);
    @memcpy(chunkItems(c)[0..items.len], items);
    setChunkCount(c, items.len);
    return c;
}

/// The chunk `c` (at least one element) in front of `more`, its first
/// element first.
pub fn chunkedCons(heap: *Heap, c: Value, more_v: Value) !Value {
    std.debug.assert(shapeOf(c) == .chunk and chunkCount(c) > 0);
    std.debug.assert(isMore(more_v));
    const h = try heap.alloc(.lazy_seq, @sizeOf(ConsBody));
    setShape(h, .chunked);
    Heap.bodyOf(ConsBody, h).* = .{ .first = c, .more = more_v };
    return valueOf(h, .chunked);
}

// =============================================================================
// Accessors
// =============================================================================

fn lazyBody(v: Value) *LazyBody {
    std.debug.assert(shapeOf(v) == .lazy);
    return Heap.bodyOf(LazyBody, Heap.asHeapHeader(v));
}

fn consBody(v: Value) *ConsBody {
    std.debug.assert(shapeOf(v) == .cons or shapeOf(v) == .chunked);
    return Heap.bodyOf(ConsBody, Heap.asHeapHeader(v));
}

fn chunkBody(c: Value) *ChunkBody {
    std.debug.assert(shapeOf(c) == .chunk);
    return Heap.bodyOf(ChunkBody, Heap.asHeapHeader(c));
}

/// Whether `v` may be the `more` of a cons: nil, a list, or a lazy seq
/// that is not a chunk.
pub fn isMore(v: Value) bool {
    return switch (v.kind()) {
        .nil, .list => true,
        .lazy_seq => shapeOf(v) != .chunk,
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
    const body = consBody(c);
    return if (shapeOf(c) == .cons) body.first else chunkItems(body.first)[chunkOffset(c)];
}

/// What follows a cons, or a chunked cons's chunk.
pub fn more(c: Value) Value {
    return consBody(c).more;
}

/// The chunk of a chunked cons.
pub fn chunkOfCons(c: Value) Value {
    std.debug.assert(shapeOf(c) == .chunked);
    return consBody(c).first;
}

pub fn chunkOffset(c: Value) usize {
    std.debug.assert(shapeOf(c) == .chunked);
    return @intCast(c.tag >> 32);
}

/// The chunked cons `c` at `offset` into its chunk: the same block, so
/// a `rest` inside a chunk allocates nothing.
pub fn atOffset(c: Value, offset: usize) Value {
    std.debug.assert(shapeOf(c) == .chunked and offset < chunkCount(chunkOfCons(c)));
    return .{ .tag = (c.tag & 0xFFFF_FFFF) | (@as(u64, @as(u32, @intCast(offset))) << 32), .payload = c.payload };
}

/// The elements a chunked cons holds from its offset on.
pub fn chunkRest(c: Value) []const Value {
    const ch = chunkOfCons(c);
    return chunkItems(ch)[chunkOffset(c)..chunkCount(ch)];
}

pub fn chunkItems(c: Value) []Value {
    return chunkBody(c).items();
}

pub fn chunkCount(c: Value) usize {
    return chunkBody(c).count;
}

pub fn setChunkCount(c: Value, n: usize) void {
    std.debug.assert(n <= chunkBody(c).cap);
    chunkBody(c).count = @intCast(n);
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
                .chunk => unreachable,
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
                for (body.args()) |a| visitor.markValue(a);
                break :blk body.result;
            },
            .cons => blk: {
                const body = Heap.bodyOf(ConsBody, cell);
                visitor.markValue(body.first);
                break :blk body.more;
            },
            .chunked => blk: {
                const body = Heap.bodyOf(ConsBody, cell);
                visitor.markValue(body.first);
                break :blk body.more;
            },
            .chunk => {
                for (Heap.bodyOf(ChunkBody, cell).items()) |x| visitor.markValue(x);
                return;
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
    const ch = try chunkOf(&heap, &.{ fx(2), fx(3), fx(4) });
    const cc = try chunkedCons(&heap, ch, tail);
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
