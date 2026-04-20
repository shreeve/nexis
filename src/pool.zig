//! pool.zig — size-class pool allocator (Phase 1 performance lift).
//!
//! Authoritative spec: `docs/POOL.md`. Derivative from
//! `docs/PERF.md` §5.12 (allocator is the single largest
//! performance lever before the Phase 2 compiler lands) and
//! peer-AI turn 26 design review.
//!
//! Single-threaded by design. nexis is single-isolate per
//! PLAN §16.1; this allocator has NO locking. Using it from
//! multiple threads simultaneously is undefined behavior.
//!
//! Lifecycle (POOL.md §7):
//!
//!     var pool = PoolAllocator.init(backing);
//!     defer pool.deinit();       // frees slabs; (2) runs last
//!
//!     var heap = Heap.init(pool.allocator());
//!     defer heap.deinit();       // returns blocks to pool; (1) runs first
//!
//! Delegation (POOL.md §4.5):
//!   - alloc size > 4096 OR alignment > 16  → backing
//!   - all other  → pool
//!
//! Size classes are comptime-generated; see `class_sizes`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

// =============================================================================
// Size classes (POOL.md §2)
// =============================================================================

pub const class_sizes = [_]usize{
    16,    32,    48,    64,    96,    128,   192,   256,
    384,   512,   768,   1024,  1536,  2048,  3072,  4096,
};

pub const NUM_CLASSES = class_sizes.len;
pub const MAX_CLASS_SIZE = class_sizes[NUM_CLASSES - 1];
pub const MAX_POOL_ALIGN: usize = 16;

/// Comptime-generated lookup table mapping `(size+15)/16 - 1` to
/// the class index. 256 entries cover sizes 16..4096. For sizes
/// above 4096, the pool bypasses the table and uses the backing.
const LOOKUP_TABLE: [256]u8 = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u8 = undefined;
    for (0..256) |i| {
        const requested = (i + 1) * 16;
        var chosen: u8 = 255;
        for (class_sizes, 0..) |cs, ci| {
            if (cs >= requested) {
                chosen = @intCast(ci);
                break;
            }
        }
        table[i] = chosen;
    }
    break :blk table;
};

// Compile-time sanity: class sizes are all 16-multiples and
// strictly increasing.
comptime {
    for (class_sizes) |cs| std.debug.assert(cs % 16 == 0);
    for (1..class_sizes.len) |i| std.debug.assert(class_sizes[i] > class_sizes[i - 1]);
    std.debug.assert(MAX_CLASS_SIZE == 4096);
}

/// Look up the class index for a requested size. Returns `null`
/// if `size > MAX_CLASS_SIZE` (caller should use backing).
inline fn classOfSize(size: usize) ?u8 {
    if (size == 0) return 0;
    if (size > MAX_CLASS_SIZE) return null;
    const idx = (size + 15) / 16 - 1;
    return LOOKUP_TABLE[idx];
}

// =============================================================================
// Size class state (POOL.md §4.2)
// =============================================================================

const FreeNode = struct { next: ?*FreeNode };

const SizeClass = struct {
    block_size: usize,
    free_list: ?*FreeNode = null,
    /// Bump pointer into the current slab. Valid when
    /// `remaining >= block_size`; otherwise undefined.
    current: [*]u8 = undefined,
    /// Bytes left in the current slab.
    remaining: usize = 0,
    /// All slabs this class has allocated from backing. Retained
    /// for deinit; never individually reclaimed in v1
    /// (POOL.md §8). Aligned-slice type is preserved so the free
    /// path passes the matching alignment back to backing.
    slabs: std.ArrayListUnmanaged([]align(16) u8) = .empty,
    /// Size of the NEXT slab to allocate. Starts at 16 KB, doubles
    /// per slab until 256 KB, then stays. POOL.md §4.4.
    next_slab_size: usize = 16 * 1024,

    fn initFor(block_size: usize) SizeClass {
        return .{ .block_size = block_size };
    }

    fn growSlab(self: *SizeClass, backing: Allocator) !void {
        const slab_size = self.next_slab_size;
        const slab: []align(16) u8 = try backing.alignedAlloc(u8, Alignment.@"16", slab_size);
        errdefer backing.free(slab);
        try self.slabs.append(backing, slab);
        self.current = slab.ptr;
        self.remaining = slab_size;
        // 16 KB → 32 KB → 64 KB → 128 KB → 256 KB (cap).
        const SLAB_CAP: usize = 256 * 1024;
        self.next_slab_size = @min(self.next_slab_size * 2, SLAB_CAP);
    }

    fn deinit(self: *SizeClass, backing: Allocator) void {
        for (self.slabs.items) |slab| backing.free(slab);
        self.slabs.deinit(backing);
        self.* = undefined;
    }
};

// =============================================================================
// Pool allocator (POOL.md §4.1 + §5)
// =============================================================================

pub const PoolAllocator = struct {
    backing: Allocator,
    classes: [NUM_CLASSES]SizeClass,

    pub fn init(backing: Allocator) PoolAllocator {
        var pool: PoolAllocator = .{
            .backing = backing,
            .classes = undefined,
        };
        for (class_sizes, 0..) |cs, i| {
            pool.classes[i] = SizeClass.initFor(cs);
        }
        return pool;
    }

    /// Releases every slab back to the backing allocator. After
    /// deinit the pool is unusable and any outstanding block is
    /// invalid regardless of whether it was freed.
    pub fn deinit(self: *PoolAllocator) void {
        for (&self.classes) |*c| c.deinit(self.backing);
        self.* = undefined;
    }

    /// Wrap the pool as a `std.mem.Allocator`. Safe to call
    /// multiple times; each call returns a fresh struct pointing
    /// at this same pool.
    pub fn allocator(self: *PoolAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    // -------------------------------------------------------------------------
    // vtable implementation (POOL.md §5 + §6)
    // -------------------------------------------------------------------------

    const vtable: Allocator.VTable = .{
        .alloc = vt_alloc,
        .resize = vt_resize,
        .remap = vt_remap,
        .free = vt_free,
    };

    fn vt_alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        // Passthrough: large or high-alignment.
        if (len > MAX_CLASS_SIZE or alignment.toByteUnits() > MAX_POOL_ALIGN) {
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }
        const class_idx = classOfSize(len) orelse return self.backing.rawAlloc(len, alignment, ret_addr);
        const c = &self.classes[class_idx];

        // Fast path: free-list pop.
        if (c.free_list) |node| {
            c.free_list = node.next;
            return @ptrCast(node);
        }

        // Bump path: carve from current slab.
        if (c.remaining < c.block_size) {
            c.growSlab(self.backing) catch return null;
        }
        const ptr = c.current;
        c.current = c.current + c.block_size;
        c.remaining -= c.block_size;
        return ptr;
    }

    fn vt_resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        if (buf.len > MAX_CLASS_SIZE or alignment.toByteUnits() > MAX_POOL_ALIGN) {
            return self.backing.rawResize(buf, alignment, new_len, ret_addr);
        }
        // Same-class resize succeeds without moving.
        const old_class = classOfSize(buf.len) orelse return false;
        if (new_len == 0) return true;
        if (new_len > MAX_CLASS_SIZE) return false;
        const new_class = classOfSize(new_len) orelse return false;
        return old_class == new_class;
    }

    fn vt_remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        if (buf.len > MAX_CLASS_SIZE or alignment.toByteUnits() > MAX_POOL_ALIGN) {
            return self.backing.rawRemap(buf, alignment, new_len, ret_addr);
        }
        const old_class = classOfSize(buf.len) orelse return null;
        if (new_len == 0) return null;
        if (new_len > MAX_CLASS_SIZE) return null;
        const new_class = classOfSize(new_len) orelse return null;
        if (old_class == new_class) return buf.ptr;
        return null;
    }

    fn vt_free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *PoolAllocator = @ptrCast(@alignCast(ctx));
        if (buf.len > MAX_CLASS_SIZE or alignment.toByteUnits() > MAX_POOL_ALIGN) {
            self.backing.rawFree(buf, alignment, ret_addr);
            return;
        }
        const class_idx = classOfSize(buf.len) orelse {
            // Shouldn't happen given the guards above, but if a
            // caller ever presents a zero-length slice we simply
            // drop it.
            return;
        };
        const c = &self.classes[class_idx];
        const node: *FreeNode = @ptrCast(@alignCast(buf.ptr));
        node.next = c.free_list;
        c.free_list = node;
    }
};

// =============================================================================
// Inline tests
// =============================================================================

const testing = std.testing;

test "classOfSize: boundaries" {
    // Exact class sizes.
    try testing.expectEqual(@as(?u8, 0), classOfSize(16));
    try testing.expectEqual(@as(?u8, 1), classOfSize(32));
    try testing.expectEqual(@as(?u8, 2), classOfSize(48));
    try testing.expectEqual(@as(?u8, 3), classOfSize(64));
    try testing.expectEqual(@as(?u8, 15), classOfSize(4096));
    // Above-exact: round up.
    try testing.expectEqual(@as(?u8, 2), classOfSize(33));
    try testing.expectEqual(@as(?u8, 2), classOfSize(40));
    try testing.expectEqual(@as(?u8, 15), classOfSize(4000));
    // Sub-16 rounds up to 16.
    try testing.expectEqual(@as(?u8, 0), classOfSize(1));
    try testing.expectEqual(@as(?u8, 0), classOfSize(8));
    // Over-ceiling: null (passthrough).
    try testing.expectEqual(@as(?u8, null), classOfSize(4097));
    try testing.expectEqual(@as(?u8, null), classOfSize(10_000));
}

test "alloc/free round trip: same address reused from free list (LIFO)" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const b1 = try a.alloc(u8, 48);
    a.free(b1);
    const b2 = try a.alloc(u8, 48);
    try testing.expectEqual(b1.ptr, b2.ptr);
    a.free(b2);
}

test "allocations within the same class reuse free list" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // 40 and 48 both land in class 2 (size 48).
    const b1 = try a.alloc(u8, 40);
    a.free(b1);
    const b2 = try a.alloc(u8, 48);
    try testing.expectEqual(b1.ptr, b2.ptr);
    a.free(b2);
}

test "multiple classes operate independently" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const x = try a.alloc(u8, 48);
    const y = try a.alloc(u8, 96);
    try testing.expect(x.ptr != y.ptr);
    // Different classes: freeing one doesn't affect the other.
    a.free(x);
    const z = try a.alloc(u8, 96);
    try testing.expect(z.ptr != x.ptr);
    a.free(y);
    a.free(z);
}

test "large allocation passthrough: freed through backing" {
    // std.testing.allocator detects leaks on its end; if the
    // large-alloc passthrough is wrong, pool.deinit() would
    // leave the large block dangling.
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const big = try a.alloc(u8, 10_000);
    try testing.expectEqual(@as(usize, 10_000), big.len);
    a.free(big);
}

test "high-alignment passthrough" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const aligned = try a.alignedAlloc(u8, Alignment.@"64", 48);
    // 64-byte alignment guaranteed by backing.
    try testing.expect(@intFromPtr(aligned.ptr) % 64 == 0);
    a.free(aligned);
}

test "resize within same class: true; across class: false" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    const buf_ptr = try a.alloc(u8, 48); // class 2 (size 48)
    defer a.free(buf_ptr);

    // 32 and 48 are different classes (1 and 2); resize across
    // classes returns false.
    try testing.expect(!a.resize(buf_ptr, 32));

    // 48 → 48: same class, same block — true.
    try testing.expect(a.resize(buf_ptr, 48));

    // 48 → 96: different class (3) — false.
    try testing.expect(!a.resize(buf_ptr, 96));
}

test "many allocations across classes: pool.deinit() releases everything" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // Allocate ~2000 blocks spanning several classes. Leak
    // detection in testing.allocator catches any slab not freed
    // by pool.deinit().
    const sizes = [_]usize{ 16, 48, 128, 384, 1024, 3072 };
    var list: std.ArrayListUnmanaged([]u8) = .empty;
    defer list.deinit(testing.allocator);

    for (0..2000) |i| {
        const s = sizes[i % sizes.len];
        const b = try a.alloc(u8, s);
        try list.append(testing.allocator, b);
    }
    // Free half to exercise the free list; retain the other half
    // to prove deinit cleans up live slabs too.
    for (list.items, 0..) |b, i| {
        if (i % 2 == 0) a.free(b);
    }
    // pool.deinit (via defer) is the only cleanup path for the
    // remaining half.
}

test "stress: round-trip pattern exercises free list + slab growth" {
    var pool = PoolAllocator.init(testing.allocator);
    defer pool.deinit();
    const a = pool.allocator();

    // Alloc batch, free batch, realloc — should reuse free list.
    var batch: [200][]u8 = undefined;
    for (&batch) |*slot| slot.* = try a.alloc(u8, 64);
    for (batch) |b| a.free(b);
    // Second round should entirely come from the free list.
    for (&batch) |*slot| slot.* = try a.alloc(u8, 64);
    for (batch) |b| a.free(b);
}
