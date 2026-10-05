//! heap.zig — runtime heap allocator + `HeapHeader` storage.
//!
//! Authoritative contract: `docs/HEAP.md` (§1 the header, §2 the
//! size-class slabs and large blocks, §3 the API).
//!
//! Every heap-kind Value sits on a `*HeapHeader` returned from
//! `Heap.alloc`. A block of up to `max_small_block` bytes, header
//! included, is a slot in a slab of its size class; a larger one is a
//! large block from the backing allocator. The collector in
//! `src/gc.zig` marks from roots and sweeps through `sweepUnmarked`;
//! this file owns allocation, enumeration, the byte counters the
//! trigger policy reads and the sweep primitive.
//!
//! Frozen invariants (HEAP.md §1):
//!   - Returned `*HeapHeader` is 16-byte aligned.
//!   - `HeapHeader` size is 16; field order matches HEAP.md §1 exactly.
//!   - Fresh allocations are zero-initialized except `kind`.
//!   - `HeapHeader.hash == 0` means "not yet computed".
//!   - A freed block's kind is poisoned; a second free panics in
//!     safe builds.

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;

// nexis is pinned to 64-bit single-isolate targets (PLAN §23 #5). Every
// layout assert below assumes 8-byte pointers and 8-byte `usize`; state
// that assumption explicitly so a 32-bit build would fail fast and
// loudly rather than silently mis-size a slab or a large block.
comptime {
    std.debug.assert(builtin.target.ptrBitWidth() == 64);
    std.debug.assert(@sizeOf(usize) == 8);
    std.debug.assert(@sizeOf(?*HeapHeader) == 8);
}

// =============================================================================
// HeapHeader — 16 bytes, layout frozen by HEAP.md §1.
// =============================================================================

pub const HeapHeader = extern struct {
    /// Finer-grained than `Value.tag.kind`. Mirrors the same `Kind` enum
    /// for the "what is this?" dimension; the extra width leaves
    /// room for sub-kind packing without another indirection.
    kind: u16 align(16),
    /// GC bits. See `mark_bit_*` constants.
    mark: u8,
    /// Heap-object flags. See `flag_*` constants.
    flags: u8,
    /// Cached hash; 0 = "not yet computed". HEAP.md §1 explicitly
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
        // Field offsets pinned to match HEAP.md §1 exactly.
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

    // ---- Metadata ----

    pub inline fn hasMeta(self: *const HeapHeader) bool {
        return (self.flags & flag_has_meta) != 0;
    }

    /// Returns the metadata pointer. In safe builds, asserts that
    /// `flag_has_meta` is consistent with `meta != null` — raw field
    /// writes that desync the two will trip here rather than silently
    /// corrupt downstream behavior.
    pub inline fn getMeta(self: *const HeapHeader) ?*HeapHeader {
        if (builtin.optimize.runtimeSafety()) {
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
    // HEAP.md §1 accepts the "hash == 0 means uncomputed" sentinel:
    // a genuine computed-zero hash recomputes on next access. This
    // saves one flag bit per heap object. If a per-
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
// An internal collection node's `hash` field (HEAP.md §1)
//
// The internal nodes of a vector, map or set cache no hash. Their `hash`
// holds the edit token of the transient that owns them in its high 26
// bits (0: none) and six bits of the collection's own below: a vector
// tail's claimed length (VECTOR.md §2).
// =============================================================================

pub const edit_token_max: u32 = (1 << 26) - 1;

pub inline fn editTokenOf(h: *const HeapHeader) u32 {
    return h.hash >> 6;
}

/// Whether the transient with token `edit` (nonzero) owns `h`.
pub inline fn ownedBy(h: *const HeapHeader, edit: u32) bool {
    return h.hash >> 6 == edit;
}

/// Stamp a fresh node as the transient's with token `edit`.
pub inline fn stampEdit(h: *HeapHeader, edit: u32) void {
    h.hash = edit << 6;
}

pub inline fn nodeAux(h: *const HeapHeader) u6 {
    return @truncate(h.hash);
}

pub inline fn setNodeAux(h: *HeapHeader, aux: u6) void {
    h.hash = (h.hash & ~@as(u32, 63)) | aux;
}

// =============================================================================
// Bit constants
// =============================================================================

pub const mark_bit_marked: u8 = 1 << 0;
/// The block is a large block (HEAP.md §2): the allocator's own bit,
/// set when the block is allocated and never cleared.
const mark_bit_large: u8 = 1 << 2;
// Bit 1 and bits 3..7 reserved.

pub const flag_has_meta: u8 = 1 << 0;
/// A string's: whether its bytes have been scanned for ASCII, and
/// whether they all were (STRING.md §3).
pub const flag_ascii_known: u8 = 1 << 1;
pub const flag_ascii: u8 = 1 << 2;
// Bits 3..7 reserved.

/// The kind of a free slot and of a swept block: outside the `Kind`
/// range, so a sweep and `forEachLive` tell a free slot from a block.
const poisoned_kind: u16 = 0xDEAD;

// =============================================================================
// Size classes and slabs (HEAP.md §2)
// =============================================================================

/// Every slab is this many bytes, aligned to its size, so the slab of
/// a block is its address with the low bits cleared.
pub const slab_bytes: usize = 256 * 1024;
const slab_alignment: std.mem.Alignment = .fromByteUnits(slab_bytes);

/// The largest block, header included, a slab holds; a larger one is
/// a large block from the backing allocator.
pub const max_small_block: usize = 8192;

/// Block sizes, header included: every multiple of 16 to 528 (a
/// 32-value vector leaf), every multiple of 32 to 1072 (a 32-entry
/// CHAMP node), then steps of an eighth.
const class_sizes: []const u32 = blk: {
    @setEvalBranchQuota(10_000);
    var sizes: []const u32 = &.{};
    var s: u32 = 16;
    while (s < max_small_block) {
        sizes = sizes ++ &[_]u32{s};
        s += if (s < 528) 16 else if (s < 1072) 32 else std.mem.alignForward(u32, s / 8, 16);
    }
    break :blk sizes ++ &[_]u32{max_small_block};
};
pub const class_count = class_sizes.len;

/// Where a class's slots sit in a slab: after the slab header and one
/// `u16` body size per slot. `recip` is `ceil(2^32 / size)`, so a
/// slot's offset times it, shifted down 32, is its index (exact while
/// an offset times `size` stays below 2^32).
const ClassInfo = struct { size: u32, slots: u32, first: u32, recip: u64 };

const slab_header_bytes: usize = std.mem.alignForward(usize, @sizeOf(Slab), 16);

const class_info: [class_count]ClassInfo = blk: {
    @setEvalBranchQuota(100_000);
    var infos: [class_count]ClassInfo = undefined;
    for (class_sizes, &infos) |size, *info| {
        var slots: usize = (slab_bytes - slab_header_bytes) / (size + 2);
        while (std.mem.alignForward(usize, slab_header_bytes + 2 * slots, 16) + slots * size > slab_bytes) slots -= 1;
        info.* = .{
            .size = size,
            .slots = @intCast(slots),
            .first = @intCast(std.mem.alignForward(usize, slab_header_bytes + 2 * slots, 16)),
            .recip = ((@as(u64, 1) << 32) + size - 1) / size,
        };
    }
    break :blk infos;
};

/// The smallest class holding a block of `n * 16` bytes, for `n` up to
/// `max_small_block / 16`.
const class_of: [max_small_block / 16 + 1]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [max_small_block / 16 + 1]u8 = undefined;
    var c: usize = 0;
    for (&table, 0..) |*slot, n| {
        while (class_sizes[c] < n * 16) c += 1;
        slot.* = @intCast(c);
    }
    break :blk table;
};

comptime {
    std.debug.assert(class_count <= 256);
    for (class_info) |info| std.debug.assert(info.slots >= 16 and info.size % 16 == 0);
}

/// A slab's header, at its start; the body sizes of its slots follow,
/// then the slots.
const Slab = struct {
    /// The next slab of the same class.
    next: ?*Slab,
    class: u8,
    /// Slots handed out at least once; the rest have never been used.
    bump: u32,
    /// Slots holding a block.
    live: u32,

    inline fn of(h: *const HeapHeader) *Slab {
        return @ptrFromInt(@intFromPtr(h) & ~(slab_bytes - 1));
    }

    inline fn info(self: *const Slab) ClassInfo {
        return class_info[self.class];
    }

    inline fn sizes(self: *Slab) [*]u16 {
        return @ptrFromInt(@intFromPtr(self) + slab_header_bytes);
    }

    inline fn slot(self: *Slab, i: usize) *HeapHeader {
        const in = self.info();
        return @ptrFromInt(@intFromPtr(self) + in.first + i * in.size);
    }

    inline fn indexOf(self: *Slab, h: *const HeapHeader) usize {
        const in = self.info();
        return @intCast(((@intFromPtr(h) - @intFromPtr(self) - in.first) * in.recip) >> 32);
    }
};

/// The prefix of a large block; its header follows.
const Large = extern struct {
    next: ?*Large align(16),
    /// The allocation's length, prefix included.
    len: usize,
    /// The body's length.
    body: usize,
    _pad: usize = 0,

    comptime {
        std.debug.assert(@sizeOf(Large) == 32);
    }

    inline fn of(h: *HeapHeader) *Large {
        return @ptrFromInt(@intFromPtr(h) - @sizeOf(Large));
    }

    inline fn header(self: *Large) *HeapHeader {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Large));
    }

    fn bytes(self: *Large) []align(16) u8 {
        const ptr: [*]align(16) u8 = @ptrCast(self);
        return ptr[0..self.len];
    }
};

inline fn isLarge(h: *const HeapHeader) bool {
    return h.mark & mark_bit_large != 0;
}

/// Slabs come from the operating system, not the backing allocator,
/// so an empty one handed back leaves the resident set (HEAP.md §2).
const slab_source = std.heap.page_allocator;

/// The slabs of heaps that ended, kept for the next heap, at most
/// `pooled_slabs_max` for the process. Heaps on several threads share
/// it through a try-lock and skip it when another holds the lock, so
/// none ever waits.
const SlabPool = struct {
    lock: std.atomic.Mutex = .unlocked,
    head: ?*Slab = null,
    count: usize = 0,
};

var slab_pool: SlabPool = .{};

pub const pooled_slabs_max = 64;

fn takePooledSlab() ?*Slab {
    if (!slab_pool.lock.tryLock()) return null;
    defer slab_pool.lock.unlock();
    const s = slab_pool.head orelse return null;
    slab_pool.head = s.next;
    slab_pool.count -= 1;
    return s;
}

/// Pool a slab a heap gives up at its end, or hand it back to the
/// operating system when the pool is full or busy.
fn poolSlab(s: *Slab) void {
    if (slab_pool.lock.tryLock()) {
        defer slab_pool.lock.unlock();
        if (slab_pool.count < pooled_slabs_max) {
            s.next = slab_pool.head;
            slab_pool.head = s;
            slab_pool.count += 1;
            return;
        }
    }
    Heap.freeSlab(s);
}

// =============================================================================
// Heap — the allocator facade.
// =============================================================================

pub const Heap = struct {
    /// Large blocks and the collector's worklist come from here.
    backing: Allocator,
    classes: [class_count]Class = @splat(.{}),
    large_head: ?*Large = null,
    /// Empty slabs kept for the next class that needs one, linked
    /// through `next` (`sweepUnmarked` says how many).
    empty_slabs: ?*Slab = null,
    empty_slab_count: usize = 0,
    /// Slabs held, the empty ones kept included.
    slab_count: usize = 0,
    /// Bytes held by every live block: its class's size for a slab
    /// block, the allocation's length for a large one.
    live_bytes: usize = 0,
    /// The largest `live_bytes` has been: the high-water mark a
    /// bounded-memory test asserts against.
    peak_live_bytes: usize = 0,
    /// Bytes allocated since `resetAllocationCounter`: what the
    /// collector's trigger compares against its threshold.
    allocated_since_collect: usize = 0,
    /// The last edit token a transient on this heap took, at most
    /// `edit_token_max` (`docs/TRANSIENT.md` §4).
    edit_clock: u32 = 0,

    const Class = struct {
        /// Free slots of the class's slabs, linked through `meta`.
        free: ?*HeapHeader = null,
        /// The slab never-used slots are carved from.
        carving: ?*Slab = null,
        /// Every slab of the class.
        slabs: ?*Slab = null,
    };

    /// A sweep keeps as many empty slabs as slabs still in use, and
    /// at least this many (16 MiB, the collector's default trigger:
    /// what a program allocates between two cycles), and hands the
    /// rest back. A steady workload then refills kept slabs instead of
    /// mapping fresh ones each cycle; a live set that shrinks gives
    /// its memory back.
    pub const empty_slabs_kept_min = 64;

    pub fn init(backing: Allocator) Heap {
        return .{ .backing = backing };
    }

    /// Frees every block, and pools or hands back every slab. After
    /// this call the Heap is unusable.
    pub fn deinit(self: *Heap) void {
        for (&self.classes) |*cls| {
            var cur = cls.slabs;
            while (cur) |s| {
                cur = s.next;
                poolSlab(s);
            }
        }
        var empty = self.empty_slabs;
        while (empty) |s| {
            empty = s.next;
            poolSlab(s);
        }
        var large = self.large_head;
        while (large) |l| {
            large = l.next;
            self.backing.free(l.bytes());
        }
        self.* = undefined;
    }

    /// Which `Kind`s carry a `*HeapHeader` in `Value.payload`: every
    /// heap kind except the ones whose payload is a pointer the VM
    /// or static storage owns (`native_fn`, `var_`, the three db
    /// handles), plus the `cell_internal` sentinel, whose blocks
    /// hold upvalue cells. The collector marks only these.
    pub fn isBlockKind(kind: value.Kind) bool {
        return switch (kind) {
            .native_fn, .var_, .db_connection, .db_write_txn, .db_read_txn => false,
            .cell_internal => true,
            else => kind.isHeap(),
        };
    }

    pub fn alloc(self: *Heap, kind: value.Kind, body_size: usize) !*HeapHeader {
        std.debug.assert(kind.isHeap() or kind == .cell_internal);
        const total = try std.math.add(usize, @sizeOf(HeapHeader), body_size);
        const h = if (total <= max_small_block) try self.allocSmall(total) else try self.allocLarge(body_size);
        h.kind = @backingInt(kind);
        return h;
    }

    inline fn allocSmall(self: *Heap, total: usize) !*HeapHeader {
        const c = class_of[(total + 15) >> 4];
        const cls = &self.classes[c];
        const h = if (cls.free) |f| blk: {
            cls.free = f.meta;
            break :blk f;
        } else try self.carve(c);
        const slab = Slab.of(h);
        slab.live += 1;
        slab.sizes()[slab.indexOf(h)] = @intCast(total - @sizeOf(HeapHeader));
        const bytes: [*]align(16) u8 = @ptrCast(h);
        @memset(bytes[0..std.mem.alignForward(usize, total, 16)], 0);
        self.count(class_info[c].size);
        return h;
    }

    fn carve(self: *Heap, c: u8) !*HeapHeader {
        const cls = &self.classes[c];
        const slab = if (cls.carving) |s| (if (s.bump < class_info[c].slots) s else try self.newSlab(c)) else try self.newSlab(c);
        slab.bump += 1;
        return slab.slot(slab.bump - 1);
    }

    fn newSlab(self: *Heap, c: u8) !*Slab {
        const slab: *Slab = if (self.empty_slabs) |s| blk: {
            self.empty_slabs = s.next;
            self.empty_slab_count -= 1;
            break :blk s;
        } else blk: {
            const s = takePooledSlab() orelse fresh: {
                const mem = try slab_source.alignedAlloc(u8, slab_alignment, slab_bytes);
                break :fresh @as(*Slab, @ptrCast(mem.ptr));
            };
            self.slab_count += 1;
            break :blk s;
        };
        const cls = &self.classes[c];
        slab.* = .{ .next = cls.slabs, .class = c, .bump = 0, .live = 0 };
        cls.slabs = slab;
        cls.carving = slab;
        return slab;
    }

    fn freeSlab(s: *Slab) void {
        const ptr: [*]align(slab_bytes) u8 = @ptrCast(@alignCast(s));
        slab_source.free(@as([]align(slab_bytes) u8, ptr[0..slab_bytes]));
    }

    fn keepEmptySlab(self: *Heap, s: *Slab) void {
        s.next = self.empty_slabs;
        self.empty_slabs = s;
        self.empty_slab_count += 1;
    }

    /// Hand back the empty slabs past what `empty_slabs_kept_min`
    /// allows.
    fn trimEmptySlabs(self: *Heap) void {
        const keep = @max(empty_slabs_kept_min, self.slab_count - self.empty_slab_count);
        while (self.empty_slab_count > keep) {
            const s = self.empty_slabs.?;
            self.empty_slabs = s.next;
            self.empty_slab_count -= 1;
            self.slab_count -= 1;
            freeSlab(s);
        }
    }

    fn allocLarge(self: *Heap, body_size: usize) !*HeapHeader {
        const len = try std.math.add(usize, @sizeOf(Large) + @sizeOf(HeapHeader), body_size);
        const buf = try self.backing.alignedAlloc(u8, .@"16", len);
        @memset(buf, 0);
        const large: *Large = @ptrCast(buf.ptr);
        large.* = .{ .next = self.large_head, .len = len, .body = body_size };
        self.large_head = large;
        const h = large.header();
        h.mark = mark_bit_large;
        self.count(len);
        return h;
    }

    inline fn count(self: *Heap, bytes: usize) void {
        self.live_bytes += bytes;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
        self.allocated_since_collect += bytes;
    }

    /// Start a new allocation-counting window; the collector calls
    /// this after every cycle.
    pub fn resetAllocationCounter(self: *Heap) void {
        self.allocated_since_collect = 0;
    }

    // ---- Body accessors ----

    /// Typed body pointer. The body sits at a 16-byte-aligned address
    /// (header starts at a 16-byte boundary and is itself 16 bytes), so
    /// any `Body` with alignment ≤ 16 is safe. Kinds that need >16-byte
    /// alignment (rare) would require an alloc API that takes explicit
    /// body alignment — no heap kind needs it.
    pub inline fn bodyOf(comptime Body: type, h: *HeapHeader) *Body {
        comptime std.debug.assert(@alignOf(Body) <= 16);
        const body_ptr: [*]u8 = @as([*]u8, @ptrCast(h)) + @sizeOf(HeapHeader);
        return @ptrCast(@alignCast(body_ptr));
    }

    /// The body, as long as `alloc` or the last `resizeInPlace` made it.
    pub fn bodyBytes(h: *HeapHeader) []u8 {
        const body_ptr: [*]u8 = @as([*]u8, @ptrCast(h)) + @sizeOf(HeapHeader);
        return body_ptr[0..bodySize(h)];
    }

    pub fn bodySize(h: *HeapHeader) usize {
        if (isLarge(h)) return Large.of(h).body;
        const slab = Slab.of(h);
        return slab.sizes()[slab.indexOf(h)];
    }

    /// The longest body `resizeInPlace` can give the block.
    pub fn bodyCapacity(h: *HeapHeader) usize {
        if (isLarge(h)) return Large.of(h).len - @sizeOf(Large) - @sizeOf(HeapHeader);
        return Slab.of(h).info().size - @sizeOf(HeapHeader);
    }

    /// Give the block a body of `new_size` bytes where it stands, when
    /// its capacity allows; bytes a longer body gains are zero. False,
    /// and nothing changed, otherwise.
    pub fn resizeInPlace(h: *HeapHeader, new_size: usize) bool {
        if (new_size > bodyCapacity(h)) return false;
        const old = bodySize(h);
        if (new_size > old) @memset(bodyBytesAt(h)[old..new_size], 0);
        if (isLarge(h)) {
            Large.of(h).body = new_size;
        } else {
            const slab = Slab.of(h);
            slab.sizes()[slab.indexOf(h)] = @intCast(new_size);
        }
        return true;
    }

    inline fn bodyBytesAt(h: *HeapHeader) [*]u8 {
        return @as([*]u8, @ptrCast(h)) + @sizeOf(HeapHeader);
    }

    // ---- Value ↔ *HeapHeader ----

    pub fn valueFromHeader(kind: value.Kind, h: *HeapHeader) value.Value {
        std.debug.assert(kind.isHeap());
        return .{
            .tag = @as(u64, @backingInt(kind)),
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
        for (self.classes) |cls| {
            var cur = cls.slabs;
            while (cur) |s| : (cur = s.next) n += s.live;
        }
        var large = self.large_head;
        while (large) |l| : (large = l.next) n += 1;
        return n;
    }

    /// `visitor.visit(*HeapHeader)` for every live block: `clearMarks`,
    /// the retiring of transient edit tokens, tests and diagnostics.
    /// The visitor may change a block's header bits but must not call
    /// `alloc` or `sweepUnmarked`, which invalidate the walk.
    pub fn forEachLive(self: *const Heap, visitor: anytype) void {
        for (self.classes) |cls| {
            var cur = cls.slabs;
            while (cur) |s| : (cur = s.next) {
                for (0..s.bump) |i| {
                    const h = s.slot(i);
                    if (h.kind != poisoned_kind) visitor.visit(h);
                }
            }
        }
        var large = self.large_head;
        while (large) |l| : (large = l.next) visitor.visit(l.header());
    }

    /// Clear the `marked` bit of every live block: what a cycle that
    /// cannot finish its marking leaves behind (GC.md §4).
    pub fn clearMarks(self: *Heap) void {
        const Clear = struct {
            pub fn visit(_: @This(), h: *HeapHeader) void {
                h.clearMarked();
            }
        };
        self.forEachLive(Clear{});
    }

    // ---- Sweep ----

    /// Free every block with `marked == 0`. Clear the `marked` bit on
    /// survivors so the next cycle starts fresh. Does NOT enumerate
    /// roots or trace reachability — that's `gc.zig`'s job. Returns the
    /// number of blocks freed. Rebuilds each class's free list in
    /// address order within a slab, and keeps or hands back every
    /// slab left empty (HEAP.md §2).
    pub fn sweepUnmarked(self: *Heap) usize {
        var freed: usize = 0;
        for (&self.classes) |*cls| {
            cls.free = null;
            var link = &cls.slabs;
            while (link.*) |slab| {
                const size = slab.info().size;
                var live: u32 = 0;
                var head: ?*HeapHeader = null;
                var tail: ?*HeapHeader = null;
                var i = slab.bump;
                while (i > 0) {
                    i -= 1;
                    const h = slab.slot(i);
                    if (h.kind != poisoned_kind) {
                        if (h.isMarked()) {
                            h.mark &= ~mark_bit_marked;
                            live += 1;
                            continue;
                        }
                        h.kind = poisoned_kind;
                        freed += 1;
                        self.live_bytes -= size;
                    }
                    h.meta = head;
                    head = h;
                    if (tail == null) tail = h;
                }
                slab.live = live;
                if (live == 0) {
                    link.* = slab.next;
                    if (cls.carving == slab) cls.carving = null;
                    self.keepEmptySlab(slab);
                    continue;
                }
                if (tail) |t| {
                    t.meta = cls.free;
                    cls.free = head;
                }
                link = &slab.next;
            }
        }
        var link = &self.large_head;
        while (link.*) |l| {
            const h = l.header();
            if (h.isMarked()) {
                h.mark &= ~mark_bit_marked;
                link = &l.next;
                continue;
            }
            link.* = l.next;
            h.kind = poisoned_kind;
            self.live_bytes -= l.len;
            self.backing.free(l.bytes());
            freed += 1;
        }
        self.trimEmptySlabs();
        return freed;
    }
};

// =============================================================================
// Tests — storage-layout, alloc/free, enumeration, sweep smoke test.
// =============================================================================

const testing = std.testing;

test "HeapHeader layout is exactly HEAP.md §1" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(HeapHeader));
    try testing.expectEqual(@as(usize, 0), @offsetOf(HeapHeader, "kind"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(HeapHeader, "mark"));
    try testing.expectEqual(@as(usize, 3), @offsetOf(HeapHeader, "flags"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(HeapHeader, "hash"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(HeapHeader, "meta"));
}

test "size classes: 16-byte steps to a vector leaf, every block fits its class, slots fit their slab" {
    try testing.expectEqual(@as(u32, 16), class_sizes[0]);
    try testing.expectEqual(@as(u32, 528), class_sizes[class_of[528 / 16]]);
    try testing.expectEqual(@as(u32, max_small_block), class_sizes[class_count - 1]);
    for (1..max_small_block + 1) |total| {
        const size = class_sizes[class_of[(total + 15) >> 4]];
        try testing.expect(size >= total);
        if (total <= 528) try testing.expect(size - total < 16);
        if (total > 1072) try testing.expect(size - total <= total / 8 + 16);
    }
    for (class_info) |info| {
        try testing.expect(info.first >= slab_header_bytes + 2 * info.slots);
        try testing.expect(info.first + info.slots * info.size <= slab_bytes);
        for (0..info.slots) |i| {
            const off: u64 = i * info.size;
            try testing.expectEqual(i, @as(usize, @intCast((off * info.recip) >> 32)));
        }
    }
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

    try testing.expectEqual(@as(u16, @backingInt(value.Kind.string)), h.kind);
    try testing.expectEqual(@as(u8, 0), h.mark);
    try testing.expectEqual(@as(u8, 0), h.flags);
    try testing.expectEqual(@as(u32, 0), h.hash);
    try testing.expectEqual(@as(?*HeapHeader, null), h.meta);
    try testing.expect(h.cachedHash() == null);
    try testing.expect(!h.isMarked());

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

test "mark helpers round-trip" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = try heap.alloc(.string, 0);

    try testing.expect(!h.isMarked());
    h.setMarked();
    try testing.expect(h.isMarked());
    h.clearMarked();
    try testing.expect(!h.isMarked());
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

test "sweepUnmarked: the blocks after the survivor in a slab are freed together" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    // Three neighbouring slots of the 16-byte class.
    const a = try heap.alloc(.string, 0);
    _ = try heap.alloc(.bignum, 0);
    _ = try heap.alloc(.list, 0);

    // Mark only `a`; its two neighbours sweep.
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

test "byte counters: alloc adds, the sweep subtracts, peak holds, the window resets" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    try testing.expectEqual(@as(usize, 0), heap.live_bytes);

    // A block counts its class's size: 16 + 16 and 16 + 48 bytes fill
    // the 32- and 64-byte classes exactly.
    const a = try heap.alloc(.string, 16);
    _ = try heap.alloc(.string, 48);
    try testing.expectEqual(@as(usize, 96), heap.live_bytes);
    try testing.expectEqual(@as(usize, 96), heap.peak_live_bytes);
    try testing.expectEqual(@as(usize, 96), heap.allocated_since_collect);

    heap.resetAllocationCounter();
    try testing.expectEqual(@as(usize, 0), heap.allocated_since_collect);

    _ = try heap.alloc(.list, 0); // unmarked, as b: swept
    a.setMarked();
    _ = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 32), heap.live_bytes);
    try testing.expectEqual(@as(usize, 112), heap.peak_live_bytes);
    try testing.expectEqual(@as(usize, 16), heap.allocated_since_collect);

    // A large block counts its allocation, prefix included.
    _ = try heap.alloc(.string, max_small_block);
    try testing.expectEqual(@as(usize, 32 + @sizeOf(Large) + 16 + max_small_block), heap.live_bytes);
    a.setMarked();
    _ = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 32), heap.live_bytes);
}

test "bodyBytes: the exact size asked for, in every class and for a large block" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var sizes: [40]usize = undefined;
    var hs: [40]*HeapHeader = undefined;
    for (&sizes, &hs, 0..) |*n, *h, i| {
        n.* = i * 331 % (max_small_block + 100);
        h.* = try heap.alloc(.string, n.*);
        @memset(Heap.bodyBytes(h.*), @intCast(i));
    }
    for (sizes, hs, 0..) |n, h, i| {
        try testing.expectEqual(n, Heap.bodyBytes(h).len);
        for (Heap.bodyBytes(h)) |byte| try testing.expectEqual(@as(u8, @intCast(i)), byte);
        try testing.expect(Heap.bodyCapacity(h) >= n);
    }
}

test "resizeInPlace: grows within the class with zeroed bytes, shrinks, refuses past the capacity" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const h = try heap.alloc(.persistent_map, 40); // class 64: capacity 48
    @memset(Heap.bodyBytes(h), 7);
    try testing.expectEqual(@as(usize, 48), Heap.bodyCapacity(h));
    try testing.expect(Heap.resizeInPlace(h, 24));
    try testing.expectEqual(@as(usize, 24), Heap.bodyBytes(h).len);
    try testing.expect(Heap.resizeInPlace(h, 48));
    for (Heap.bodyBytes(h)[0..24]) |byte| try testing.expectEqual(@as(u8, 7), byte);
    for (Heap.bodyBytes(h)[24..]) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expect(!Heap.resizeInPlace(h, 49));
    try testing.expectEqual(@as(usize, 48), Heap.bodyBytes(h).len);

    const big = try heap.alloc(.string, 10_000);
    try testing.expect(Heap.resizeInPlace(big, 9_000));
    try testing.expectEqual(@as(usize, 9_000), Heap.bodyBytes(big).len);
    try testing.expect(Heap.resizeInPlace(big, 10_000));
    try testing.expect(!Heap.resizeInPlace(big, 10_001));
}

test "slabs: a freed slot is reused, a sweep hands empty slabs back beyond the ones it keeps" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const per_slab = class_info[class_of[528 / 16]].slots;
    // A hundred slabs of vector-leaf-sized blocks.
    const n = per_slab * 100;
    var keep: ?*HeapHeader = null;
    for (0..n) |i| {
        const h = try heap.alloc(.persistent_vector, 512);
        if (i == n / 2) keep = h;
    }
    try testing.expectEqual(@as(usize, 100), heap.slab_count);
    try testing.expectEqual(n, heap.liveCount());

    // Everything but one block is garbage: one slab stays, the
    // minimum of empty ones is kept, the rest go back.
    keep.?.setMarked();
    try testing.expectEqual(n - 1, heap.sweepUnmarked());
    try testing.expectEqual(@as(usize, 1), heap.liveCount());
    try testing.expectEqual(@as(usize, 1 + Heap.empty_slabs_kept_min), heap.slab_count);
    try testing.expectEqual(@as(usize, Heap.empty_slabs_kept_min), heap.empty_slab_count);

    // The survivor's slab serves the next allocations from its free
    // slots before any kept slab is taken.
    const again = try heap.alloc(.persistent_vector, 512);
    try testing.expectEqual(Slab.of(keep.?), Slab.of(again));
    try testing.expectEqual(@as(usize, Heap.empty_slabs_kept_min), heap.empty_slab_count);

    // A swept block's slot is the next one handed out in its class.
    keep.?.setMarked();
    try testing.expectEqual(@as(usize, 1), heap.sweepUnmarked());
    try testing.expectEqual(again, try heap.alloc(.persistent_vector, 500));
}

test "slabs: a sweep keeps as many empty slabs as are in use, and hands the rest back once the live set shrinks" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const per_slab = class_info[class_of[528 / 16]].slots;
    var held: std.ArrayList(*HeapHeader) = .empty;
    defer held.deinit(testing.allocator);
    // Three hundred slabs; one block of each of the first two hundred
    // survives.
    for (0..per_slab * 300) |i| {
        const h = try heap.alloc(.persistent_vector, 512);
        if (i < per_slab * 200 and i % per_slab == 0) try held.append(testing.allocator, h);
    }
    for (held.items) |h| h.setMarked();
    _ = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 300), heap.slab_count);
    try testing.expectEqual(@as(usize, 100), heap.empty_slab_count);
    // Nothing survives: all but the minimum go back.
    _ = heap.sweepUnmarked();
    try testing.expectEqual(@as(usize, 0), heap.liveCount());
    try testing.expectEqual(@as(usize, Heap.empty_slabs_kept_min), heap.slab_count);
    try testing.expectEqual(@as(usize, Heap.empty_slabs_kept_min), heap.empty_slab_count);
}

test "slabs: a heap that ends leaves its slabs to the next heap, up to the pool's bound" {
    // Room in the pool for this test's two slabs.
    while (slab_pool.count > pooled_slabs_max - 2) Heap.freeSlab(takePooledSlab().?);
    var a = Heap.init(testing.allocator);
    _ = try a.alloc(.string, 8);
    _ = try a.alloc(.persistent_vector, 512);
    try testing.expectEqual(@as(usize, 2), a.slab_count);
    const slab = Slab.of(try a.alloc(.string, 8));
    const before = slab_pool.count;
    a.deinit();
    try testing.expectEqual(before + 2, slab_pool.count);
    var b = Heap.init(testing.allocator);
    defer b.deinit();
    const h = try b.alloc(.list, 32);
    try testing.expectEqual(before + 1, slab_pool.count);
    try testing.expect(Slab.of(h) == slab or slab_pool.head.? == slab);
    try testing.expectEqual(@as(u8, 0), h.mark);
    for (Heap.bodyBytes(h)) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "slabs: a sweep keeps pinned and marked slots and every class stays consistent" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var hs: std.ArrayList(*HeapHeader) = .empty;
    defer hs.deinit(testing.allocator);
    var rng = std.Random.DefaultPrng.init(0x5eed);
    const r = rng.random();
    for (0..20_000) |_| try hs.append(testing.allocator, try heap.alloc(.string, r.uintLessThan(usize, 2 * max_small_block)));
    for (0..4) |round| {
        var survivors: usize = 0;
        for (hs.items, 0..) |h, i| {
            if ((i + round) % 3 == 0) {
                h.setMarked();
                survivors += 1;
            }
        }
        _ = heap.sweepUnmarked();
        try testing.expectEqual(survivors, heap.liveCount());
        // Keep the survivors, refill with fresh blocks.
        var w: usize = 0;
        for (hs.items, 0..) |h, i| {
            if ((i + round) % 3 == 0) {
                try testing.expect(!h.isMarked());
                hs.items[w] = h;
                w += 1;
            }
        }
        hs.shrinkRetainingCapacity(w);
        while (hs.items.len < 20_000) try hs.append(testing.allocator, try heap.alloc(.string, r.uintLessThan(usize, 2 * max_small_block)));
        try testing.expectEqual(@as(usize, 20_000), heap.liveCount());
    }
}

test "isBlockKind: pointer payloads the collector must not dereference" {
    try testing.expect(Heap.isBlockKind(.string));
    try testing.expect(Heap.isBlockKind(.function));
    try testing.expect(Heap.isBlockKind(.cell_internal));
    try testing.expect(Heap.isBlockKind(.atom));
    try testing.expect(!Heap.isBlockKind(.native_fn));
    try testing.expect(!Heap.isBlockKind(.var_));
    try testing.expect(!Heap.isBlockKind(.db_connection));
    try testing.expect(!Heap.isBlockKind(.db_write_txn));
    try testing.expect(!Heap.isBlockKind(.db_read_txn));
    try testing.expect(!Heap.isBlockKind(.fixnum));
    try testing.expect(!Heap.isBlockKind(.nil));
}
