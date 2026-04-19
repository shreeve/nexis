//! heap.zig — runtime heap allocator + `HeapHeader` storage (Phase 1).
//!
//! Authoritative layout contract: `docs/VALUE.md` §4 (HeapHeader) and
//! `docs/HEAP.md` (allocator + object-enumeration + minimal sweep).
//!
//! This is the bedrock every heap-kind Value sits on. String, bignum,
//! CHAMP map/set, persistent vector, cons list, transient wrapper, Var,
//! durable-ref — all of them land on a `*HeapHeader` returned from
//! `Heap.alloc`. Full garbage collection (root enumeration, precise
//! tracing, trigger policy) lands later in `src/gc.zig`; this file
//! delivers the allocation + enumeration + mark-sweep scaffold the
//! collector will build on top of.
//!
//! Frozen invariants (VALUE.md §4 + HEAP.md §1):
//!   - Returned `*HeapHeader` is 16-byte aligned.
//!   - `HeapHeader` size is 16; field order matches VALUE.md §4 exactly.
//!   - Fresh allocations are zero-initialized except `kind`.
//!   - `HeapHeader.hash == 0` means "not yet computed".
//!   - Double-free is a runtime bug; debug builds panic via a poisoned-
//!     kind sentinel set on free.
//!
//! Peer-AI review (conversation `nexis-phase-1` turn 4) established
//! the prefix-block strategy over an external registry to avoid a
//! dual source of truth for live objects.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value");

const Allocator = std.mem.Allocator;

// nexis v1 is pinned to 64-bit single-isolate targets (PLAN §16). Every
// layout assert below assumes 8-byte pointers and 8-byte `usize`; state
// that assumption explicitly so a 32-bit build would fail fast and
// loudly rather than silently mis-size `Block`.
comptime {
    std.debug.assert(builtin.target.ptrBitWidth() == 64);
    std.debug.assert(@sizeOf(usize) == 8);
    std.debug.assert(@sizeOf(?*HeapHeader) == 8);
}

// =============================================================================
// HeapHeader — 16 bytes, layout frozen by VALUE.md §4.
// =============================================================================

pub const HeapHeader = extern struct {
    /// Finer-grained than `Value.tag.kind`. Mirrors the same `Kind` enum
    /// for the "what is this?" dimension; extra width allows future
    /// sub-kind packing if needed without another indirection.
    kind: u16 align(16),
    /// GC bits. See `mark_bit_*` constants.
    mark: u8,
    /// Heap-object flags. See `flag_*` constants.
    flags: u8,
    /// Cached hash; 0 = "not yet computed". VALUE.md §4 explicitly
    /// accepts the (rare) recompute cost when a real hash value is 0.
    hash: u32,
    /// Optional metadata map (always a persistent-map heap object when
    /// non-null). When null, `flag_has_meta` must also be 0.
    meta: ?*HeapHeader,

    comptime {
        std.debug.assert(@sizeOf(HeapHeader) == 16);
        // 16-byte *type*-level alignment keeps casts between
        // `*HeapHeader` and `[*]align(16) u8` lossless — no `@alignCast`
        // noise at every call site. Runtime alignment is guaranteed by
        // the allocator via `.@"16"` at alloc time (HEAP.md §1 invariant 1).
        std.debug.assert(@alignOf(HeapHeader) == 16);
        // Field offsets pinned to match VALUE.md §4 exactly.
        std.debug.assert(@offsetOf(HeapHeader, "kind") == 0);
        std.debug.assert(@offsetOf(HeapHeader, "mark") == 2);
        std.debug.assert(@offsetOf(HeapHeader, "flags") == 3);
        std.debug.assert(@offsetOf(HeapHeader, "hash") == 4);
        std.debug.assert(@offsetOf(HeapHeader, "meta") == 8);
    }

    // ---- Mark bits ----

    pub inline fn isMarked(self: *const HeapHeader) bool {
        return (self.mark & mark_bit_marked) != 0;
    }
    pub inline fn setMarked(self: *HeapHeader) void {
        self.mark |= mark_bit_marked;
    }
    pub inline fn clearMarked(self: *HeapHeader) void {
        self.mark &= ~mark_bit_marked;
    }
    pub inline fn isPinned(self: *const HeapHeader) bool {
        return (self.mark & mark_bit_pinned) != 0;
    }
    pub inline fn setPinned(self: *HeapHeader) void {
        self.mark |= mark_bit_pinned;
    }
    pub inline fn clearPinned(self: *HeapHeader) void {
        self.mark &= ~mark_bit_pinned;
    }

    // ---- Metadata ----

    pub inline fn hasMeta(self: *const HeapHeader) bool {
        return (self.flags & flag_has_meta) != 0;
    }

    /// Returns the metadata pointer. In safe builds, asserts that
    /// `flag_has_meta` is consistent with `meta != null` — raw field
    /// writes that desync the two will trip here rather than silently
    /// corrupt downstream behavior.
    pub inline fn getMeta(self: *const HeapHeader) ?*HeapHeader {
        if (std.debug.runtime_safety) {
            std.debug.assert(self.hasMeta() == (self.meta != null));
        }
        return self.meta;
    }

    /// Canonical way to set metadata. Keeps `flag_has_meta` in lockstep
    /// with the pointer. Raw field writes to `meta` are discouraged —
    /// use this helper to keep the invariant intact.
    pub inline fn setMeta(self: *HeapHeader, m: ?*HeapHeader) void {
        self.meta = m;
        if (m == null) {
            self.flags &= ~flag_has_meta;
        } else {
            self.flags |= flag_has_meta;
        }
    }

    // ---- Cached hash ----
    //
    // VALUE.md §4 accepts the "hash == 0 means uncomputed" sentinel:
    // a genuine computed-zero hash recomputes on next access. This
    // saves one flag bit per heap object. Peer-AI review raised the
    // information-loss concern; the spec decision stands. If a per-
    // kind hasher produces output with a non-trivial 0-collision rate
    // (e.g. identity hashes over small domains), that kind's hasher
    // should remap 0 to 1 in its own finalizer before calling
    // `setCachedHash`.

    pub inline fn cachedHash(self: *const HeapHeader) ?u32 {
        return if (self.hash == 0) null else self.hash;
    }
    pub inline fn setCachedHash(self: *HeapHeader, h: u32) void {
        self.hash = h;
    }
};

// =============================================================================
// Bit constants
// =============================================================================

pub const mark_bit_marked: u8 = 1 << 0;
pub const mark_bit_pinned: u8 = 1 << 1;
// Bits 2..7 reserved for future tri-color / generational / remembered-set use.

pub const flag_has_meta: u8 = 1 << 0;
pub const flag_interned: u8 = 1 << 1;
pub const flag_immutable: u8 = 1 << 2;
pub const flag_zero_copy: u8 = 1 << 3;
// Bits 4..7 reserved.

// =============================================================================
// Block — private prefix; users never see it.
// =============================================================================

/// Allocation prefix. Sits immediately before `HeapHeader` in every
/// block. 16-byte aligned (both because `Block` itself is 16 bytes and
/// because the allocator is asked for 16-byte alignment at alloc time),
/// so `block.header` lands at a 16-byte boundary too.
const Block = extern struct {
    /// Singly-linked list of live blocks. Alloc prepends.
    next: ?*Block align(16),
    /// Total allocation bytes: `@sizeOf(Block) + body_size`. Stored so
    /// `free` can reconstruct the backing slice for `allocator.free`.
    total_size: usize,
    /// User-visible header. VALUE.md §4.
    header: HeapHeader,
    // body follows.

    comptime {
        std.debug.assert(@sizeOf(Block) == 16 + 16);
        std.debug.assert(@alignOf(Block) == 16);
        std.debug.assert(@offsetOf(Block, "next") == 0);
        std.debug.assert(@offsetOf(Block, "total_size") == 8);
        std.debug.assert(@offsetOf(Block, "header") == 16);
    }
};

const header_and_body_offset: usize = @sizeOf(Block);

/// Debug sentinel written to `block.header.kind` at free time, used to
/// detect double-free on subsequent free attempts. Chosen outside the
/// valid `Kind` range (0..255 valid) but inside the u16 space.
const poisoned_kind: u16 = 0xDEAD;

inline fn blockOf(h: *HeapHeader) *Block {
    return @fieldParentPtr("header", h);
}

// =============================================================================
// Heap — the allocator facade.
// =============================================================================

pub const Heap = struct {
    backing: Allocator,
    live_head: ?*Block = null,

    pub fn init(backing: Allocator) Heap {
        return .{ .backing = backing };
    }

    /// Frees every block still on the live list. Typically called at
    /// runtime teardown. After this call the Heap is unusable.
    pub fn deinit(self: *Heap) void {
        var cur = self.live_head;
        while (cur) |b| {
            const next = b.next;
            const slice = blockSlice(b);
            self.backing.free(slice);
            cur = next;
        }
        self.* = undefined;
    }

    pub fn alloc(self: *Heap, kind: value.Kind, body_size: usize) !*HeapHeader {
        std.debug.assert(kind.isHeap());
        // Overflow-safe: on a 32-bit usize + near-maxInt body_size we'd
        // wrap and under-allocate silently in non-safe release builds.
        // `std.math.add` returns `error.Overflow`; the caller's error
        // set subsumes it via the inferred `!*HeapHeader`.
        const total = try std.math.add(usize, header_and_body_offset, body_size);
        const buf = try self.backing.alignedAlloc(u8, .@"16", total);
        // Zero-init the whole allocation so downstream code can rely on
        // header.mark == 0, header.flags == 0, header.hash == 0 (uncomputed),
        // header.meta == null, and all body bytes == 0. The kind byte
        // overwrites the zero immediately below.
        @memset(buf, 0);

        const block: *Block = @ptrCast(buf.ptr);
        block.next = self.live_head;
        block.total_size = total;
        block.header.kind = @intFromEnum(kind);
        // mark / flags / hash / meta are already 0 from the memset.

        self.live_head = block;
        return &block.header;
    }

    pub fn free(self: *Heap, h: *HeapHeader) void {
        const block = blockOf(h);

        if (std.debug.runtime_safety) {
            if (h.kind == poisoned_kind) {
                std.debug.panic("heap.free: double-free detected on *HeapHeader {*}", .{h});
            }
        }

        // Unlink from the live list. O(n) in v1; acceptable at Phase 1
        // scale and replaced wholesale by the eventual slab allocator.
        if (self.live_head == block) {
            self.live_head = block.next;
        } else {
            var prev: *Block = self.live_head orelse {
                std.debug.panic("heap.free: block {*} not on any live list (empty heap)", .{block});
            };
            while (prev.next) |next| {
                if (next == block) {
                    prev.next = block.next;
                    break;
                }
                prev = next;
            } else {
                std.debug.panic("heap.free: block {*} not found on live list", .{block});
            }
        }

        h.kind = poisoned_kind;
        const slice = blockSlice(block);
        self.backing.free(slice);
    }

    // ---- Body accessors ----

    /// Typed body pointer. The body sits at a 16-byte-aligned address
    /// (header starts at a 16-byte boundary and is itself 16 bytes), so
    /// any `Body` with alignment ≤ 16 is safe. Kinds that need >16-byte
    /// alignment (rare) would require an alloc API that takes explicit
    /// body alignment — intentionally out of scope for v1 because no
    /// current or committed heap kind needs it.
    pub inline fn bodyOf(comptime Body: type, h: *HeapHeader) *Body {
        comptime std.debug.assert(@alignOf(Body) <= 16);
        const body_ptr: [*]u8 = @as([*]u8, @ptrCast(h)) + @sizeOf(HeapHeader);
        return @ptrCast(@alignCast(body_ptr));
    }

    pub fn bodyBytes(h: *HeapHeader) []u8 {
        const block = blockOf(h);
        const body_len = block.total_size - header_and_body_offset;
        const body_ptr: [*]u8 = @as([*]u8, @ptrCast(h)) + @sizeOf(HeapHeader);
        return body_ptr[0..body_len];
    }

    // ---- Value ↔ *HeapHeader ----

    pub fn valueFromHeader(kind: value.Kind, h: *HeapHeader) value.Value {
        std.debug.assert(kind.isHeap());
        return .{
            .tag = @as(u64, @intFromEnum(kind)),
            .payload = @intFromPtr(h),
        };
    }

    pub fn asHeapHeader(v: value.Value) *HeapHeader {
        std.debug.assert(v.kind().isHeap());
        // Heap-kind Values must carry a non-zero, 16-byte-aligned
        // pointer in their payload (HEAP.md §1 invariant 1). Catching
        // corruption here gives a line-level diagnosis; without these
        // asserts a corrupted Value manifests as an alignment trap or
        // null-deref on the first body/header access, far from the
        // cause.
        std.debug.assert(v.payload != 0);
        std.debug.assert((v.payload & 0xF) == 0);
        return @ptrFromInt(v.payload);
    }

    // ---- Enumeration ----

    pub fn liveCount(self: *const Heap) usize {
        var n: usize = 0;
        var cur = self.live_head;
        while (cur) |b| : (cur = b.next) n += 1;
        return n;
    }

    /// Read-only traversal. Invokes `visitor.visit(*HeapHeader)` for
    /// every live block, strictly for observation — diagnostics, GC
    /// mark-phase tracing, stats collection. The visitor must NOT call
    /// `heap.free` / `heap.alloc` / `heap.sweepUnmarked` during the
    /// walk; mutation invalidates the iterator. Use `forEachLiveMut`
    /// if you need to free the currently-visited block.
    pub fn forEachLive(self: *const Heap, visitor: anytype) void {
        var cur = self.live_head;
        while (cur) |b| {
            const next = b.next;
            visitor.visit(&b.header);
            cur = next;
        }
    }

    /// Mutation-aware traversal. The visitor is permitted to call
    /// `heap.free(h)` on the **currently-visited block only** — the
    /// iterator captures `next` before the callback so the current
    /// block's storage becoming invalid mid-walk is safe.
    ///
    /// **NOT guaranteed safe:**
    ///   - Freeing a different live block during the walk (breaks the
    ///     iterator's `prev → next` chain).
    ///   - Allocating a new block during the walk (the new block
    ///     prepends to `live_head`; whether it's visited this walk is
    ///     unspecified).
    ///   - Calling `sweepUnmarked` from inside a visitor.
    ///
    /// Use `sweepUnmarked` directly when you want bulk mutation driven
    /// by the mark bits.
    pub fn forEachLiveMut(self: *Heap, visitor: anytype) void {
        var cur = self.live_head;
        while (cur) |b| {
            const next = b.next;
            visitor.visit(&b.header);
            cur = next;
        }
    }

    // ---- Minimal sweep ----

    /// Free every block with `marked == 0`. Clear the `marked` bit on
    /// survivors so the next cycle starts fresh. Does NOT enumerate
    /// roots or trace reachability — that's `gc.zig`'s job. Returns the
    /// number of blocks freed.
    ///
    /// `pinned` blocks survive regardless of mark state (PLAN §10.5):
    /// open transactions, durable-ref handles, REPL history, etc.
    pub fn sweepUnmarked(self: *Heap) usize {
        var freed: usize = 0;
        var prev: ?*Block = null;
        var cur = self.live_head;
        while (cur) |b| {
            const next = b.next;
            const survive = b.header.isMarked() or b.header.isPinned();
            if (survive) {
                b.header.clearMarked();
                prev = b;
            } else {
                if (prev) |p| p.next = next else self.live_head = next;
                b.header.kind = poisoned_kind;
                self.backing.free(blockSlice(b));
                freed += 1;
            }
            cur = next;
        }
        return freed;
    }
};

// =============================================================================
// Private helpers
// =============================================================================

fn blockSlice(b: *Block) []align(16) u8 {
    const ptr: [*]align(16) u8 = @ptrCast(b);
    return ptr[0..b.total_size];
}

// =============================================================================
// Tests — storage-layout, alloc/free, enumeration, sweep smoke test.
// =============================================================================

const testing = std.testing;

test "HeapHeader layout is exactly VALUE.md §4" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(HeapHeader));
    try testing.expectEqual(@as(usize, 0), @offsetOf(HeapHeader, "kind"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(HeapHeader, "mark"));
    try testing.expectEqual(@as(usize, 3), @offsetOf(HeapHeader, "flags"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(HeapHeader, "hash"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(HeapHeader, "meta"));
}

test "Block prefix is 16 bytes; header lands 16 bytes in" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(Block));
    try testing.expectEqual(@as(usize, 16), @offsetOf(Block, "header"));
}

test "Heap.init/deinit on empty heap" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "alloc: returns 16-byte-aligned *HeapHeader; header zero-init except kind" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const h = try heap.alloc(.string, 0);
    const addr = @intFromPtr(h);
    try testing.expectEqual(@as(usize, 0), addr % 16);

    try testing.expectEqual(@as(u16, @intFromEnum(value.Kind.string)), h.kind);
    try testing.expectEqual(@as(u8, 0), h.mark);
    try testing.expectEqual(@as(u8, 0), h.flags);
    try testing.expectEqual(@as(u32, 0), h.hash);
    try testing.expectEqual(@as(?*HeapHeader, null), h.meta);
    try testing.expect(h.cachedHash() == null);
    try testing.expect(!h.isMarked());
    try testing.expect(!h.isPinned());

    try testing.expectEqual(@as(usize, 1), heap.liveCount());
}

test "alloc: body is zero-initialized and the right size" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const h = try heap.alloc(.string, 64);
    const body = Heap.bodyBytes(h);
    try testing.expectEqual(@as(usize, 64), body.len);
    for (body) |b| try testing.expectEqual(@as(u8, 0), b);

    // Body alignment is the same as the header's — 16 bytes past a 16-byte-aligned base.
    try testing.expectEqual(@as(usize, 0), @intFromPtr(body.ptr) % 16);
}

test "bodyOf: typed pointer with compile-time alignment" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const Payload = extern struct { a: u32, b: u32 };
    const h = try heap.alloc(.byte_vector, @sizeOf(Payload));
    const p = Heap.bodyOf(Payload, h);
    p.* = .{ .a = 0xCAFE, .b = 0xBABE };

    const p2 = Heap.bodyOf(Payload, h);
    try testing.expectEqual(@as(u32, 0xCAFE), p2.a);
    try testing.expectEqual(@as(u32, 0xBABE), p2.b);
}

test "Value ↔ *HeapHeader pointer round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const h = try heap.alloc(.list, 0);
    const v = Heap.valueFromHeader(.list, h);
    try testing.expect(v.kind() == .list);
    try testing.expectEqual(@intFromPtr(h), v.payload);
    const back = Heap.asHeapHeader(v);
    try testing.expectEqual(h, back);
}

test "free: removes from live list; liveCount drops" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.alloc(.string, 0);
    const b = try heap.alloc(.bignum, 0);
    const c = try heap.alloc(.list, 0);
    try testing.expectEqual(@as(usize, 3), heap.liveCount());

    heap.free(b);
    try testing.expectEqual(@as(usize, 2), heap.liveCount());
    heap.free(a);
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
    heap.free(c);
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "mark / pinned helpers round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = try heap.alloc(.string, 0);

    try testing.expect(!h.isMarked());
    h.setMarked();
    try testing.expect(h.isMarked());
    h.clearMarked();
    try testing.expect(!h.isMarked());

    try testing.expect(!h.isPinned());
    h.setPinned();
    try testing.expect(h.isPinned());
    // Marked and pinned are independent bits.
    h.setMarked();
    try testing.expect(h.isPinned() and h.isMarked());
    h.clearPinned();
    try testing.expect(!h.isPinned() and h.isMarked());

    heap.free(h);
}

test "meta helpers update has_meta flag in lockstep" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try heap.alloc(.persistent_map, 0);
    const b = try heap.alloc(.string, 0);

    try testing.expectEqual(@as(?*HeapHeader, null), a.getMeta());
    try testing.expect((a.flags & flag_has_meta) == 0);

    a.setMeta(b);
    try testing.expectEqual(@as(?*HeapHeader, b), a.getMeta());
    try testing.expect((a.flags & flag_has_meta) != 0);

    a.setMeta(null);
    try testing.expectEqual(@as(?*HeapHeader, null), a.getMeta());
    try testing.expect((a.flags & flag_has_meta) == 0);
}

test "cachedHash: 0 means uncomputed; round-trip otherwise" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = try heap.alloc(.string, 0);

    try testing.expect(h.cachedHash() == null);
    h.setCachedHash(0);
    try testing.expect(h.cachedHash() == null);
    h.setCachedHash(0xDEADBEEF);
    try testing.expectEqual(@as(?u32, 0xDEADBEEF), h.cachedHash());
}

test "sweepUnmarked: unmarked freed, marked survive and are reset" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.alloc(.string, 8);
    _ = try heap.alloc(.bignum, 8); // unmarked -> will be freed
    const c = try heap.alloc(.list, 8);

    a.setMarked();
    c.setMarked();

    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 1), freed);
    try testing.expectEqual(@as(usize, 2), heap.liveCount());

    // Survivors had their marked bit cleared.
    try testing.expect(!a.isMarked());
    try testing.expect(!c.isMarked());
}

test "sweepUnmarked: pinned objects always survive" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const pinned = try heap.alloc(.durable_ref, 0);
    const transient_obj = try heap.alloc(.string, 0);
    pinned.setPinned();
    // Neither is marked.

    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 1), freed);
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
    try testing.expect(pinned.isPinned());
    _ = transient_obj; // freed
}

test "sweepUnmarked: all unmarked -> fully drained heap" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    _ = try heap.alloc(.string, 0);
    _ = try heap.alloc(.string, 0);
    _ = try heap.alloc(.string, 0);
    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 3), freed);
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "forEachLive visits every live block exactly once" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const a = try heap.alloc(.string, 0);
    const b = try heap.alloc(.bignum, 0);
    const c = try heap.alloc(.list, 0);

    const Counter = struct {
        seen_a: bool = false,
        seen_b: bool = false,
        seen_c: bool = false,
        count: usize = 0,
        target_a: *HeapHeader,
        target_b: *HeapHeader,
        target_c: *HeapHeader,

        pub fn visit(self: *@This(), h: *HeapHeader) void {
            self.count += 1;
            if (h == self.target_a) self.seen_a = true;
            if (h == self.target_b) self.seen_b = true;
            if (h == self.target_c) self.seen_c = true;
        }
    };

    var counter: Counter = .{ .target_a = a, .target_b = b, .target_c = c };
    heap.forEachLive(&counter);
    try testing.expectEqual(@as(usize, 3), counter.count);
    try testing.expect(counter.seen_a and counter.seen_b and counter.seen_c);
}

test "deinit frees every remaining live block (no leak via testing allocator)" {
    var heap = Heap.init(testing.allocator);
    _ = try heap.alloc(.string, 64);
    _ = try heap.alloc(.bignum, 128);
    _ = try heap.alloc(.list, 16);
    heap.deinit();
    // testing.allocator would trip a leak assertion at test teardown
    // if deinit missed anything.
}

test "alloc: body_size = 0 is legal" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = try heap.alloc(.list, 0);
    try testing.expectEqual(@as(usize, 0), Heap.bodyBytes(h).len);
    heap.free(h);
}

test "alloc: overflow in total_size rejects with error.Overflow" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const result = heap.alloc(.string, std.math.maxInt(usize));
    try testing.expectError(error.Overflow, result);
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
}

test "bodyOf: alignment contract holds up to 16" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const Aligned16 = extern struct { a: u64, b: u64 }; // @alignOf = 8, ok
    const h = try heap.alloc(.string, @sizeOf(Aligned16));
    const p = Heap.bodyOf(Aligned16, h);
    p.* = .{ .a = 1, .b = 2 };
    try testing.expectEqual(@as(u64, 1), p.a);
    try testing.expectEqual(@as(u64, 2), p.b);
}

test "hasMeta: stays coherent with flag_has_meta through setMeta" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const a = try heap.alloc(.persistent_map, 0);
    const m = try heap.alloc(.persistent_map, 0);

    try testing.expect(!a.hasMeta());
    a.setMeta(m);
    try testing.expect(a.hasMeta());
    // getMeta's debug assert: set flag matches non-null pointer.
    try testing.expectEqual(@as(?*HeapHeader, m), a.getMeta());
    a.setMeta(null);
    try testing.expect(!a.hasMeta());
    try testing.expectEqual(@as(?*HeapHeader, null), a.getMeta());
}

test "sweepUnmarked: free head + next consecutively, survivor preserved" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Alloc order prepends to head; so this writes head = c -> b -> a.
    const a = try heap.alloc(.string, 0);
    _ = try heap.alloc(.bignum, 0); // b — head->next after c is allocated
    _ = try heap.alloc(.list, 0); // c — current head

    // Mark only `a` (the tail). Head (c) and its next (b) both sweep.
    a.setMarked();
    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 2), freed);
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
    try testing.expect(!a.isMarked()); // mark cleared on survivor
}

test "sweepUnmarked: alternating survive / free / survive / free" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var hs: [4]*HeapHeader = undefined;
    for (&hs) |*slot| {
        slot.* = try heap.alloc(.string, 0);
    }
    // Alternate: mark even indices; odd get swept.
    hs[0].setMarked();
    hs[2].setMarked();

    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 2), freed);
    try testing.expectEqual(@as(usize, 2), heap.liveCount());
    try testing.expect(!hs[0].isMarked());
    try testing.expect(!hs[2].isMarked());
}

test "sweepUnmarked: pinned + marked stays pinned, mark clears" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = try heap.alloc(.durable_ref, 0);
    h.setPinned();
    h.setMarked();
    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 0), freed);
    try testing.expect(h.isPinned());
    try testing.expect(!h.isMarked());
}

test "forEachLive: read-only traversal is callable through *const Heap" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    _ = try heap.alloc(.string, 0);
    _ = try heap.alloc(.bignum, 0);
    _ = try heap.alloc(.list, 0);

    // Read-only visitor: counts observed blocks and sums their kind
    // bytes. No heap mutation.
    const ReadOnlyCounter = struct {
        count: usize = 0,
        sum_kind: u32 = 0,
        pub fn visit(self: *@This(), h: *HeapHeader) void {
            self.count += 1;
            self.sum_kind += h.kind;
        }
    };

    // Intentionally pass via *const to prove the receiver is truly
    // read-only at the type level.
    const heap_ref: *const Heap = &heap;
    var counter: ReadOnlyCounter = .{};
    heap_ref.forEachLive(&counter);
    try testing.expectEqual(@as(usize, 3), counter.count);
    try testing.expect(counter.sum_kind > 0);
}

test "forEachLiveMut: visitor may free the currently-visited block" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    _ = try heap.alloc(.string, 0);
    const b = try heap.alloc(.bignum, 0);
    _ = try heap.alloc(.list, 0);

    // Visitor that frees one specific block during the walk.
    const Killer = struct {
        heap_ptr: *Heap,
        target: *HeapHeader,
        visited: usize = 0,

        pub fn visit(self: *@This(), h: *HeapHeader) void {
            self.visited += 1;
            if (h == self.target) self.heap_ptr.free(h);
        }
    };

    var killer: Killer = .{ .heap_ptr = &heap, .target = b };
    heap.forEachLiveMut(&killer);
    try testing.expectEqual(@as(usize, 3), killer.visited);
    try testing.expectEqual(@as(usize, 2), heap.liveCount());
}

test "alloc stress: 256 allocations, sweep half, deinit the rest" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    var headers: [256]*HeapHeader = undefined;
    for (&headers, 0..) |*slot, i| {
        slot.* = try heap.alloc(.string, @intCast(i % 32));
    }
    try testing.expectEqual(@as(usize, 256), heap.liveCount());

    // Mark every other one.
    for (headers, 0..) |h, i| {
        if (i % 2 == 0) h.setMarked();
    }
    const freed = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 128), freed);
    try testing.expectEqual(@as(usize, 128), heap.liveCount());
    // Remaining are unmarked (cleared by sweep).
    for (headers, 0..) |h, i| {
        if (i % 2 == 0) try testing.expect(!h.isMarked());
    }
}
