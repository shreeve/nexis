//! idents.zig — durable keyword <-> id mapping with a per-connection cache.
//!
//! `nx/idents` holds `[0x00][text] -> id` and `[0x01][id] -> text`. The
//! cache maps the VM interner's keyword id to the store's ident id and
//! back. Invariants:
//!   - The cache only ever holds committed mappings: a transaction's
//!     freshly minted idents wait in its `Minter` and enter the cache
//!     through `Minter.commitCache` after the commit succeeds, into room
//!     reserved before it, so the publication cannot fail.
//!   - An ident id, once committed, never changes its text; a text never
//!     changes its id.
//!   - Attribute entities and enum keywords share this id space; an
//!     attribute's ident id is its entity id.

const std = @import("std");
const intern_mod = @import("intern");
const emdb = @import("emdb");
const store_mod = @import("store.zig");

const Allocator = std.mem.Allocator;
const Interner = intern_mod.Interner;
const Store = store_mod.Store;
const Txn = emdb.Txn;

pub const Idents = struct {
    gpa: Allocator,
    store: *Store,
    interner: *Interner,
    by_intern: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    by_ident: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    pub fn init(gpa: Allocator, store: *Store, interner: *Interner) Idents {
        return .{ .gpa = gpa, .store = store, .interner = interner };
    }

    pub fn deinit(self: *Idents) void {
        self.by_intern.deinit(self.gpa);
        self.by_ident.deinit(self.gpa);
        self.* = undefined;
    }

    /// A cache holding the same committed mappings, which then diverges
    /// on its own.
    pub fn clone(self: *const Idents) !Idents {
        var out = Idents.init(self.gpa, self.store, self.interner);
        errdefer out.deinit();
        out.by_intern = try self.by_intern.clone(self.gpa);
        out.by_ident = try self.by_ident.clone(self.gpa);
        return out;
    }

    /// Record a committed mapping.
    pub fn remember(self: *Idents, intern_id: u32, id: u32) !void {
        try self.by_intern.put(self.gpa, intern_id, id);
        try self.by_ident.put(self.gpa, id, intern_id);
    }

    /// Make room for `n` more mappings, so that `rememberAssumeCapacity`
    /// cannot fail.
    pub fn reserve(self: *Idents, n: u32) !void {
        try self.by_intern.ensureUnusedCapacity(self.gpa, n);
        try self.by_ident.ensureUnusedCapacity(self.gpa, n);
    }

    /// Record a committed mapping into room made by `reserve`.
    pub fn rememberAssumeCapacity(self: *Idents, intern_id: u32, id: u32) void {
        self.by_intern.putAssumeCapacity(intern_id, id);
        self.by_ident.putAssumeCapacity(id, intern_id);
    }

    /// Ident id of the VM keyword `intern_id`, or null when the store
    /// has no such ident. Reads through `txn` on a cache miss.
    pub fn idOf(self: *Idents, txn: *Txn, intern_id: u32) !?u32 {
        if (self.by_intern.get(intern_id)) |id| return id;
        const name = self.interner.keywordName(intern_id);
        const id = (try self.store.identIdByName(txn, name)) orelse return null;
        try self.remember(intern_id, id);
        return id;
    }

    /// Ident id of `name`, or null.
    pub fn idOfName(self: *Idents, txn: *Txn, name: []const u8) !?u32 {
        const intern_id = try self.interner.internKeyword(name);
        return self.idOf(txn, intern_id);
    }

    /// VM keyword id of ident `id`, interning its text on first sight,
    /// or null when the store has no such ident.
    pub fn internOf(self: *Idents, txn: *Txn, id: u32) !?u32 {
        if (self.by_ident.get(id)) |k| return k;
        const name = (try self.store.identNameById(txn, id)) orelse return null;
        const intern_id = try self.interner.internKeyword(name);
        try self.remember(intern_id, id);
        return intern_id;
    }

    /// Text of ident `id`; the slice is owned by the VM interner.
    pub fn nameOf(self: *Idents, txn: *Txn, id: u32) !?[]const u8 {
        const k = (try self.internOf(txn, id)) orelse return null;
        return self.interner.keywordName(k);
    }
};

/// Ident resolution inside one write transaction: looks through the
/// cache, then this transaction's mints, then the tree, and mints a new
/// id from `sys["aid"]` when asked to. `finish` writes the bumped
/// counter, `reserveCache` makes room in the cache, and `commitCache`
/// publishes the mints after the commit without allocating.
pub const Minter = struct {
    idents: *Idents,
    txn: *Txn,
    arena: Allocator,
    next_aid: u32,
    minted: std.ArrayList(Mint) = .empty,

    pub const Mint = struct { intern_id: u32, id: u32 };

    pub fn init(idents: *Idents, txn: *Txn, arena: Allocator) !Minter {
        return .{
            .idents = idents,
            .txn = txn,
            .arena = arena,
            .next_aid = try idents.store.readNextAid(txn),
        };
    }

    fn pending(self: *const Minter, intern_id: u32) ?u32 {
        for (self.minted.items) |m| {
            if (m.intern_id == intern_id) return m.id;
        }
        return null;
    }

    /// Existing id of the keyword, or null; never mints.
    pub fn lookup(self: *Minter, intern_id: u32) !?u32 {
        if (self.idents.by_intern.get(intern_id)) |id| return id;
        if (self.pending(intern_id)) |id| return id;
        const name = self.idents.interner.keywordName(intern_id);
        const id = (try self.idents.store.identIdByName(self.txn, name)) orelse return null;
        try self.idents.remember(intern_id, id);
        return id;
    }

    pub fn lookupName(self: *Minter, name: []const u8) !?u32 {
        const intern_id = try self.idents.interner.internKeyword(name);
        return self.lookup(intern_id);
    }

    /// Id of the keyword, minting one when the store has none.
    pub fn resolve(self: *Minter, intern_id: u32) !u32 {
        if (try self.lookup(intern_id)) |id| return id;
        const id = self.next_aid;
        if (id == std.math.maxInt(u32)) return error.DatabaseFull;
        self.next_aid += 1;
        const name = self.idents.interner.keywordName(intern_id);
        try self.idents.store.putIdent(self.txn, name, id);
        try self.minted.append(self.arena, .{ .intern_id = intern_id, .id = id });
        return id;
    }

    /// Did this transaction mint `id`?
    pub fn mintedId(self: *const Minter, id: u32) bool {
        for (self.minted.items) |m| {
            if (m.id == id) return true;
        }
        return false;
    }

    /// Write the bumped counter. Call once before commit.
    pub fn finish(self: *Minter) !void {
        if (self.minted.items.len > 0) try self.idents.store.writeNextAid(self.txn, self.next_aid);
    }

    /// Make room in the cache for every mint. Call before the commit.
    pub fn reserveCache(self: *Minter) !void {
        try self.idents.reserve(@intCast(self.minted.items.len));
    }

    /// Publish the mints to the room `reserveCache` made. Call only after
    /// a successful commit; cannot fail.
    pub fn commitCache(self: *Minter) void {
        for (self.minted.items) |m| self.idents.rememberAssumeCapacity(m.intern_id, m.id);
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "bootstrap idents resolve both ways and new ones mint after commit" {
    var td = try store_mod.TestDir.init("idents");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    var idents = Idents.init(testing.allocator, store, &interner);
    defer idents.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const k_ident = try interner.internKeyword("db/ident");
    const k_color = try interner.internKeyword("color/red");
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(?u32, store_mod.boot.ident), try idents.idOf(txn, k_ident));
        try testing.expect((try idents.idOf(txn, k_color)) == null);
        try testing.expectEqualStrings("db.type/ref", (try idents.nameOf(txn, store_mod.boot.type_ref)).?);
        try testing.expect((try idents.internOf(txn, 4000)) == null);
    }
    // An aborted mint leaves no trace in the cache or the counter.
    {
        const txn = try store.beginWrite(.none);
        var m = try Minter.init(&idents, txn, arena);
        const id = try m.resolve(k_color);
        try testing.expectEqual(store_mod.boot.next_aid, id);
        try testing.expectEqual(id, try m.resolve(k_color));
        try testing.expect(m.mintedId(id));
        try m.finish();
        txn.abort();
        try testing.expect(idents.by_intern.get(k_color) == null);
    }
    {
        const txn = try store.beginWrite(.none);
        var m = try Minter.init(&idents, txn, arena);
        try testing.expectEqual(store_mod.boot.next_aid, try m.resolve(k_color));
        try testing.expectEqual(@as(?u32, store_mod.boot.ident), try m.lookup(k_ident));
        try m.finish();
        try m.reserveCache();
        try txn.commit();
        m.commitCache();
    }
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try testing.expectEqual(@as(?u32, store_mod.boot.next_aid), try idents.idOf(txn, k_color));
        try testing.expectEqual(store_mod.boot.next_aid + 1, try store.readNextAid(txn));
        try testing.expectEqual(@as(?u32, k_color), try idents.internOf(txn, store_mod.boot.next_aid));
    }
}
