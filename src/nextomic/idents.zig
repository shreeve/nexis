//! idents.zig — durable keyword <-> id mapping with a per-connection cache.
//!
//! `nx/idents` holds `[0x00][text] -> id`, `[0x01][id] -> text` and, for
//! a name an ident no longer carries, `[0x02][text] -> id`. The cache
//! maps the VM interner's keyword id to the store's ident id and back.
//! Invariants:
//!   - The cache only ever holds committed mappings: everything a write
//!     transaction mints, renames or reads from the tree waits in its
//!     `Minter` and enters the cache through `Minter.commitCache` after
//!     the commit succeeds, into room reserved before it, so the
//!     publication cannot fail. `Idents.idOf` and `internOf` remember
//!     what they read, so they take read transactions only.
//!   - A text names at most one id, and an id has one live text. A
//!     rename (`:db/ident` asserted on an attribute entity) moves the
//!     old text to the retired names, where it stays reserved: it is
//!     never minted again, and only the txlog decoder reads it.
//!   - Every rename bumps the store's ident generation (`sys["ig"]`);
//!     `refresh` at the start of an operation drops a cache loaded under
//!     an older generation, so a second connection or process never
//!     resolves a retired name or prints a stale one.
//!   - Attribute entities and enum keywords share this id space; an
//!     attribute's ident id is its entity id.

const std = @import("std");
const intern_mod = @import("../intern.zig");
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
    /// The ident generation the cache was loaded under.
    gen: u64 = 0,

    pub fn init(gpa: Allocator, store: *Store, interner: *Interner) Idents {
        return .{ .gpa = gpa, .store = store, .interner = interner };
    }

    /// Drop every mapping when the store's ident generation has moved
    /// past the one the cache was loaded under. Called at the start of
    /// every operation, through `txn`.
    pub fn refresh(self: *Idents, txn: *Txn) !void {
        const gen = try self.store.readIdentGen(txn);
        if (gen == self.gen) return;
        self.by_intern.clearRetainingCapacity();
        self.by_ident.clearRetainingCapacity();
        self.gen = gen;
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
        out.gen = self.gen;
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

/// Ident resolution inside one write transaction: looks through this
/// transaction's own mappings, then the cache, then the tree, and mints
/// a new id from `sys["aid"]` when asked to. Nothing reaches the cache
/// before the commit: the tree read through the write transaction holds
/// its uncommitted mints and renames, so what a lookup finds there is
/// kept in `local` and published by `commitCache` only once the commit
/// succeeds. `finish` writes the bumped counter and `reserveCache`
/// makes room in the cache, so the publication cannot fail.
pub const Minter = struct {
    idents: *Idents,
    txn: *Txn,
    arena: Allocator,
    first_aid: u32,
    next_aid: u32,
    /// VM keyword id -> ident id for every keyword this transaction
    /// minted or found in the tree.
    local: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Ident id -> its new VM keyword id, for every rename of this
    /// transaction; the id's old keyword names nothing from the rename on.
    renamed: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Renames written, each of which bumps the store's generation.
    renames: u64 = 0,

    pub const Error = error{
        /// The name was retired by a rename and is never minted again.
        RetiredIdent,
    };

    pub fn init(idents: *Idents, txn: *Txn, arena: Allocator) !Minter {
        const next = try idents.store.readNextAid(txn);
        return .{ .idents = idents, .txn = txn, .arena = arena, .first_aid = next, .next_aid = next };
    }

    /// Existing id of the keyword, or null; never mints. A keyword the
    /// transaction renamed away from is null.
    pub fn lookup(self: *Minter, intern_id: u32) !?u32 {
        const id = self.local.get(intern_id) orelse self.idents.by_intern.get(intern_id) orelse blk: {
            const name = self.idents.interner.keywordName(intern_id);
            const found = (try self.idents.store.identIdByName(self.txn, name)) orelse return null;
            try self.local.put(self.arena, intern_id, found);
            break :blk found;
        };
        if (self.renamed.get(id)) |now| if (now != intern_id) return null;
        return id;
    }

    pub fn lookupName(self: *Minter, name: []const u8) !?u32 {
        const intern_id = try self.idents.interner.internKeyword(name);
        return self.lookup(intern_id);
    }

    /// VM keyword id of ident `id` as this transaction sees it, or null;
    /// for fault payloads, so nothing is cached.
    pub fn keywordOf(self: *Minter, id: u32) !?u32 {
        if (self.renamed.get(id)) |k| return k;
        if (self.idents.by_ident.get(id)) |k| return k;
        const name = (try self.idents.store.identNameById(self.txn, id)) orelse return null;
        return try self.idents.interner.internKeyword(name);
    }

    /// Id of the keyword, minting one when the store has none; a
    /// retired name is `error.RetiredIdent`.
    pub fn resolve(self: *Minter, intern_id: u32) !u32 {
        if (try self.lookup(intern_id)) |id| return id;
        const name = self.idents.interner.keywordName(intern_id);
        if ((try self.idents.store.retiredIdentId(self.txn, name)) != null) return error.RetiredIdent;
        const id = self.next_aid;
        if (id == std.math.maxInt(u32)) return error.DatabaseFull;
        self.next_aid += 1;
        try self.idents.store.putIdent(self.txn, name, id);
        try self.local.put(self.arena, intern_id, id);
        return id;
    }

    /// Give ident `id` the keyword `intern_id`, which must name nothing
    /// yet (`lookup` is null and the name is not retired); the old
    /// name is retired.
    pub fn rename(self: *Minter, id: u32, intern_id: u32) !void {
        const name = self.idents.interner.keywordName(intern_id);
        if ((try self.idents.store.retiredIdentId(self.txn, name)) != null) return error.RetiredIdent;
        try self.idents.store.renameIdent(self.txn, id, name);
        try self.renamed.put(self.arena, id, intern_id);
        self.renames += 1;
    }

    /// Write the bumped counter. Call once before commit.
    pub fn finish(self: *Minter) !void {
        if (self.next_aid != self.first_aid) try self.idents.store.writeNextAid(self.txn, self.next_aid);
    }

    /// Make room in the cache for every mapping `commitCache`
    /// publishes. Call before the commit.
    pub fn reserveCache(self: *Minter) !void {
        try self.idents.reserve(@intCast(self.local.count() + self.renamed.count()));
    }

    /// Publish this transaction's mappings to the room `reserveCache`
    /// made, and take the generation the renames reached. Call only
    /// after a successful commit; cannot fail. A renamed id's mapping
    /// comes from the rename alone, whatever `local` found for it.
    pub fn commitCache(self: *Minter) void {
        var it = self.local.iterator();
        while (it.next()) |m| {
            if (self.renamed.contains(m.value_ptr.*)) continue;
            self.idents.rememberAssumeCapacity(m.key_ptr.*, m.value_ptr.*);
        }
        var rit = self.renamed.iterator();
        while (rit.next()) |r| {
            if (self.idents.by_ident.get(r.key_ptr.*)) |old| _ = self.idents.by_intern.remove(old);
            self.idents.rememberAssumeCapacity(r.value_ptr.*, r.key_ptr.*);
        }
        self.idents.gen += self.renames;
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

test "a rename moves the cache to the new keyword and a second cache reloads by generation" {
    var td = try store_mod.TestDir.init("idents_rename");
    defer td.deinit();
    const store = try Store.open(testing.allocator, td.path.ptr, .{});
    defer store.close();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    var idents = Idents.init(testing.allocator, store, &interner);
    defer idents.deinit();
    var other = Idents.init(testing.allocator, store, &interner);
    defer other.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const k_red = try interner.internKeyword("color/red");
    const k_crimson = try interner.internKeyword("color/crimson");
    var id: u32 = 0;
    {
        const txn = try store.beginWrite(.none);
        var m = try Minter.init(&idents, txn, arena);
        id = try m.resolve(k_red);
        try m.finish();
        try m.reserveCache();
        try txn.commit();
        m.commitCache();
    }
    // The other cache loads the old name.
    {
        const txn = try store.beginRead();
        defer txn.abort();
        try other.refresh(txn);
        try testing.expectEqual(@as(?u32, id), try other.idOf(txn, k_red));
    }
    {
        const txn = try store.beginWrite(.none);
        var m = try Minter.init(&idents, txn, arena);
        try testing.expect((try m.lookup(k_crimson)) == null);
        try m.rename(id, k_crimson);
        // The old name is neither live nor mintable.
        try testing.expectError(error.RetiredIdent, m.resolve(k_red));
        try m.finish();
        try m.reserveCache();
        try txn.commit();
        m.commitCache();
    }
    const txn = try store.beginRead();
    defer txn.abort();
    try testing.expect((try idents.idOf(txn, k_red)) == null);
    try testing.expectEqual(@as(?u32, id), try idents.idOf(txn, k_crimson));
    try testing.expectEqual(@as(?u32, k_crimson), try idents.internOf(txn, id));
    try testing.expectEqual(@as(u64, 1), idents.gen);
    // Without a refresh the other cache still answers the old name; with one it reloads.
    try testing.expectEqual(@as(?u32, id), try other.idOf(txn, k_red));
    try other.refresh(txn);
    try testing.expect((try other.idOf(txn, k_red)) == null);
    try testing.expectEqual(@as(?u32, k_crimson), try other.internOf(txn, id));
    try testing.expectEqual(@as(u64, 1), other.gen);
}
