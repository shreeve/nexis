//! test/integration/db_layer.zig — `src/db.zig` against real store
//! files (docs/DB.md): opening and sharing a file, durability, the held
//! snapshot, transactions, walks, trees, refs and the collector's sweep.

const std = @import("std");
const nx = @import("nexis");
const db = nx.db;
const emdb = nx.emdb;
const value = nx.value;
const Value = value.Value;
const Kind = value.Kind;
const Heap = nx.heap.Heap;
const Interner = nx.intern.Interner;

const testing = std.testing;

/// A store path in a fresh directory under `.zig-cache/tmp/`, so
/// concurrent runs never share a file; `cleanupDb` removes the
/// directory with the store in it.
fn tmpDbPath(allocator: std.mem.Allocator, suffix: []const u8) ![:0]u8 {
    var tmp = std.testing.tmpDir(.{});
    tmp.dir.close(std.testing.io);
    tmp.parent_dir.close(std.testing.io);
    return allocator.printSentinel(".zig-cache/tmp/{s}/{s}.emdb", .{ tmp.sub_path, suffix }, 0);
}

fn cleanupDb(path: [:0]const u8) void {
    const dir = std.Io.Dir.path.dirname(path) orelse return;
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
}

/// A store path in a fresh directory, and the heap and interner its
/// connections decode into; `deinit` shuts down every connection on
/// the heap and removes the directory.
const Fixture = struct {
    path: [:0]u8,
    heap: Heap,
    interner: Interner,

    fn init(name: []const u8) !Fixture {
        return .{ .path = try tmpDbPath(testing.allocator, name), .heap = Heap.init(testing.allocator), .interner = Interner.init(testing.allocator) };
    }

    fn deinit(f: *Fixture) void {
        db.shutdownHeap(&f.heap);
        f.interner.deinit();
        f.heap.deinit();
        cleanupDb(f.path);
        testing.allocator.free(f.path);
    }

    fn connect(f: *Fixture) !*db.Connection {
        return f.connectAt(f.path);
    }

    fn connectAt(f: *Fixture, path: [*:0]const u8) !*db.Connection {
        return db.open(testing.allocator, &f.heap, &f.interner, path);
    }
};

const synthHash = Value.hashImmediate;
const synthEq = value.testEqual;

test "open / close: round-trip with a tiny file" {
    var fx = try Fixture.init("open_close");
    defer fx.deinit();

    const conn = try fx.connect();

    try testing.expect(conn.open_flag);
    const sid = conn.storeId();
    try testing.expect(sid != 0);
}

test "open: store_id comes from the canonical path, however the path is spelled" {
    var fx = try Fixture.init("canon");
    defer fx.deinit();

    const a = try fx.connect();
    const sid = a.storeId();
    try testing.expect(std.Io.Dir.path.isAbsolute(a.file.path));
    try db.close(a);
    const dotted = try testing.allocator.printSentinel("./{s}", .{fx.path}, 0);
    defer testing.allocator.free(dotted);
    const b = try fx.connectAt(dotted.ptr);
    try testing.expectEqual(sid, b.storeId());
}

test "open: every spelling of one file shares its environment; a second writer is refused, never waited on" {
    var fx = try Fixture.init("shared");
    defer fx.deinit();

    const a = try fx.connect();
    const dotted = try testing.allocator.printSentinel("./{s}", .{fx.path}, 0);
    defer testing.allocator.free(dotted);
    const link = try testing.allocator.printSentinel("{s}/link.emdb", .{std.Io.Dir.path.dirname(fx.path).?}, 0);
    defer testing.allocator.free(link);
    try std.Io.Dir.cwd().symLink(testing.io, std.Io.Dir.path.basename(fx.path), link, .{});

    const same = try fx.connect();
    const b = try fx.connectAt(dotted.ptr);
    const c = try fx.connectAt(link.ptr);
    // Checked before any second write begins: on separate environments
    // it would wait on this thread's own lock.
    try testing.expect(same.file == a.file and b.file == a.file and c.file == a.file);
    try testing.expectEqual(@as(u32, 4), a.file.refs);
    try testing.expectEqual(a.storeId(), c.storeId());
    // One lock file, beside the file the link names.
    const link_lock = try testing.allocator.printSentinel("{s}-lock", .{link}, 0);
    defer testing.allocator.free(link_lock);
    try testing.expect(std.c.access(link_lock.ptr, std.c.F_OK) != 0);

    var w = try db.beginWrite(a);
    try testing.expectError(error.WriterActive, db.beginWrite(same));
    try testing.expectError(error.WriterActive, db.beginWrite(c));
    try db.put(&w, "t", "k", value.fromFixnum(1).?);
    try db.commit(&w);

    // The file stays open while any connection holds it.
    try db.close(a);
    try db.close(same);
    var r = try db.beginRead(c);
    const got = try db.get(&r, "t", "k", synthHash, synthEq);
    db.abortRead(&r);
    try testing.expectEqual(@as(i64, 1), got.?.asFixnum());
    var w2 = try db.beginWrite(b);
    try db.commit(&w2);
}

test "open: a copy of a store is another file, written beside the original" {
    var fx = try Fixture.init("original");
    defer fx.deinit();

    const a = try fx.connect();
    var w = try db.beginWrite(a);
    try db.put(&w, "t", "k", value.fromFixnum(1).?);
    try db.commit(&w);
    const copy = try testing.allocator.printSentinel("{s}/copy.emdb", .{std.Io.Dir.path.dirname(fx.path).?}, 0);
    defer testing.allocator.free(copy);
    try std.Io.Dir.cwd().copyFile(fx.path, std.Io.Dir.cwd(), copy, testing.io, .{});

    const b = try fx.connectAt(copy.ptr);
    try testing.expect(a.file != b.file);
    try testing.expect(a.storeId() != b.storeId());
    var wa = try db.beginWrite(a);
    var wb = try db.beginWrite(b);
    try db.put(&wa, "t", "k", value.fromFixnum(2).?);
    try db.put(&wb, "t", "k", value.fromFixnum(3).?);
    try db.commit(&wa);
    try db.commit(&wb);
    var ra = try db.beginRead(a);
    defer db.abortRead(&ra);
    var rb = try db.beginRead(b);
    defer db.abortRead(&rb);
    try testing.expectEqual(@as(i64, 2), (try db.get(&ra, "t", "k", synthHash, synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 3), (try db.get(&rb, "t", "k", synthHash, synthEq)).?.asFixnum());
}

test "open: a store file with a second hard link is refused under either name" {
    var fx = try Fixture.init("linked");
    defer fx.deinit();

    const a = try fx.connect();
    const other = try testing.allocator.printSentinel("{s}/other.emdb", .{std.Io.Dir.path.dirname(fx.path).?}, 0);
    defer testing.allocator.free(other);
    try testing.expectEqual(@as(c_int, 0), std.c.link(fx.path.ptr, other.ptr));
    // Already open here, and not yet open anywhere: both refused.
    try testing.expectError(error.HardLinked, fx.connect());
    try db.close(a);
    try testing.expectError(error.HardLinked, fx.connectAt(other.ptr));
    try testing.expectError(error.HardLinked, fx.connect());
    try testing.expectEqualStrings("db/hard-linked", db.failureName(error.HardLinked));
    // A directory has links of its own, and is no store.
    const dir = try testing.allocator.dupeSentinel(u8, std.Io.Dir.path.dirname(fx.path).?, 0);
    defer testing.allocator.free(dir);
    try testing.expectError(error.OpenFailed, fx.connectAt(dir.ptr));
    // One name again: the file opens.
    try testing.expectEqual(@as(c_int, 0), std.c.unlink(other.ptr));
    _ = try fx.connect();
}

test "open: a symlink to no file creates the file it names, and the lock file is named after that file" {
    var fx = try Fixture.init("target");
    defer fx.deinit();
    const link = try testing.allocator.printSentinel("{s}/dangling.emdb", .{std.Io.Dir.path.dirname(fx.path).?}, 0);
    defer testing.allocator.free(link);
    try std.Io.Dir.cwd().symLink(testing.io, std.Io.Dir.path.basename(fx.path), link, .{});

    const a = try fx.connectAt(link.ptr);
    const sid = a.storeId();
    var w = try db.beginWrite(a);
    try db.put(&w, "t", "k", value.fromFixnum(1).?);
    try db.commit(&w);
    try db.close(a);
    const link_lock = try testing.allocator.printSentinel("{s}-lock", .{link}, 0);
    defer testing.allocator.free(link_lock);
    try testing.expect(std.c.access(link_lock.ptr, std.c.F_OK) != 0);
    const b = try fx.connect();
    try testing.expectEqual(sid, b.storeId());
}

test "open: a symlink or a non-regular file where the lock file goes is refused, and what it names is left alone" {
    var fx = try Fixture.init("planted");
    defer fx.deinit();
    const dir = std.Io.Dir.path.dirname(fx.path).?;
    const victim = try testing.allocator.printSentinel("{s}/victim.txt", .{dir}, 0);
    defer testing.allocator.free(victim);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = victim, .data = "precious\n" });
    const lock = try testing.allocator.printSentinel("{s}-lock", .{fx.path}, 0);
    defer testing.allocator.free(lock);
    try std.Io.Dir.cwd().symLink(testing.io, "victim.txt", lock, .{});
    try testing.expectError(error.OpenFailed, fx.connect());
    const kept = try std.Io.Dir.cwd().readFileAlloc(testing.io, victim, testing.allocator, .unlimited);
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings("precious\n", kept);

    try testing.expectEqual(@as(c_int, 0), std.c.unlink(lock.ptr));
    try std.Io.Dir.cwd().createDir(testing.io, lock, .default_dir);
    try testing.expectError(error.OpenFailed, fx.connect());
}

test "open: a file this process may only read opens read-only; a write is TxnReadOnly" {
    var fx = try Fixture.init("readonly");
    defer fx.deinit();
    {
        const a = try fx.connect();
        defer db.shutdown(a);
        var w = try db.beginWrite(a);
        try db.put(&w, "t", "k", value.fromFixnum(7).?);
        try db.commit(&w);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(fx.path.ptr, 0o444));
    defer _ = std.c.chmod(fx.path.ptr, 0o644);
    const conn = try fx.connect();
    var r = try db.beginRead(conn);
    defer db.abortRead(&r);
    try testing.expectEqual(@as(i64, 7), (try db.get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    try testing.expectError(error.TxnReadOnly, db.beginWrite(conn));
}

test "close: a refusal ends none of the language's transactions" {
    var fx = try Fixture.init("close_refused");
    defer fx.deinit();

    const conn = try fx.connect();
    const h = try db.Handle.create(.{ .read = try db.beginRead(conn) });
    var zig_level = try db.beginRead(conn);
    try testing.expectError(db.DbError.TransactionsOpen, db.close(conn));
    try testing.expect(h.active);
    db.abortRead(&zig_level);
    try db.close(conn);
    try testing.expect(!h.active);
}

test "sweepHandles: a closed connection is freed once no Value, marked durable ref or handle names it" {
    var fx = try Fixture.init("swept");
    defer fx.deinit();
    const base = db.connectionCount();
    _ = try fx.connect();
    const named = try fx.connect();
    const reffed = try fx.connect();
    const handled = try fx.connect();
    const dropped = try fx.connect();
    const r = try db.ref(&fx.heap, reffed, "t", "k");
    const h = try db.Handle.create(.{ .read = try db.beginRead(handled) });
    for ([_]*db.Connection{ named, reffed, handled, dropped }) |c| try db.close(c);
    try testing.expectEqual(base + 5, db.connectionCount());
    // Marks that may be incomplete free nothing.
    db.sweepHandles(&fx.heap, false);
    try testing.expectEqual(base + 5, db.connectionCount());
    db.mark(.{ .tag = @backingInt(Kind.db_connection), .payload = @intFromPtr(named) });
    db.mark(.{ .tag = @backingInt(Kind.db_read_txn), .payload = @intFromPtr(h) });
    Heap.asHeapHeader(r).setMarked();
    db.sweepHandles(&fx.heap, true);
    try testing.expectEqual(base + 4, db.connectionCount());
    // Nothing reached: the handle goes, then every closed connection.
    Heap.asHeapHeader(r).clearMarked();
    db.sweepHandles(&fx.heap, true);
    try testing.expectEqual(base + 1, db.connectionCount());
}

test "has: whether a key is present, its value never read" {
    var fx = try Fixture.init("has");
    defer fx.deinit();

    const conn = try fx.connect();
    {
        // Bytes no decoder takes.
        const txn = try conn.file.env.beginWriteWith(.{ .sync = .none });
        try txn.putInTree(try txn.openTree("t", true), "k", "\xff\xff");
        try txn.commit();
    }
    var r = try db.beginRead(conn);
    defer db.abortRead(&r);
    try testing.expect(try db.has(&r, "t", "k"));
    try testing.expect(!try db.has(&r, "t", "j"));
    try testing.expect(!try db.has(&r, "none", "k"));
    if (db.get(&r, "t", "k", synthHash, synthEq)) |_| return error.TestUnexpectedResult else |_| {}
}

test "close: refused while a transaction is open; the connection stays a closed struct" {
    var fx = try Fixture.init("close_busy");
    defer fx.deinit();

    const conn = try fx.connect();
    var rtxn = try db.beginRead(conn);
    try testing.expectError(db.DbError.TransactionsOpen, db.close(conn));
    db.abortRead(&rtxn);
    try db.close(conn);
    try db.close(conn);
    try testing.expect(!conn.open_flag);
    try testing.expectError(db.DbError.ConnectionUnavailable, db.beginRead(conn));
}

test "durability commit: a commit is seen at once and syncs nothing; close syncs the file once" {
    var fx = try Fixture.init("commit_mode");
    defer fx.deinit();

    const a = try fx.connect();
    a.durability = .commit;
    const b = try fx.connect();

    const before = db.engineSyncs();
    var w = try db.beginWrite(a);
    try db.put(&w, "t", "k", value.fromFixnum(7).?);
    try db.commit(&w);
    try testing.expectEqual(before, db.engineSyncs());
    try testing.expect(a.file.unsynced);
    {
        var r = try db.beginRead(b);
        defer db.abortRead(&r);
        try testing.expectEqual(@as(i64, 7), (try db.get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    }
    // An abort writes nothing, so it leaves nothing more to sync.
    var aborted = try db.beginWrite(a);
    db.abortWrite(&aborted);
    try db.close(a);
    try testing.expectEqual(before + 1, db.engineSyncs());
    try testing.expect(!b.file.unsynced);
    try db.close(b);
    try testing.expectEqual(before + 1, db.engineSyncs());
}

test "durability durable: every commit syncs, which leaves nothing for close; a read-only program never syncs" {
    var fx = try Fixture.init("durable_mode");
    defer fx.deinit();

    const conn = try fx.connect();
    conn.durability = .commit;
    var w = try db.beginWrite(conn);
    try db.put(&w, "t", "k", value.fromFixnum(1).?);
    try db.commit(&w);
    try testing.expect(conn.file.unsynced);
    // A durable commit makes every commit before it durable too.
    conn.durability = .durable;
    const before = db.engineSyncs();
    w = try db.beginWrite(conn);
    try db.put(&w, "t", "k", value.fromFixnum(2).?);
    try db.commit(&w);
    try testing.expect(db.engineSyncs() > before);
    try testing.expect(!conn.file.unsynced);
    const after_commit = db.engineSyncs();
    try db.close(conn);
    try testing.expectEqual(after_commit, db.engineSyncs());

    const reader = try fx.connect();
    var r = try db.beginRead(reader);
    try testing.expectEqual(@as(i64, 2), (try db.get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    db.abortRead(&r);
    try db.close(reader);
    try testing.expectEqual(after_commit, db.engineSyncs());
}

/// Fails the meta sync of the next commit on the data file `fd`: once
/// the commit is published, `fd` names a pipe, which no sync takes,
/// until `restore`.
const MetaSyncFailure = struct {
    fd: std.c.fd_t,
    saved: std.c.fd_t = -1,
    pipe: [2]std.c.fd_t = undefined,

    fn notify(ctx: *anyopaque, step: emdb.txn.CommitStep) void {
        const self: *MetaSyncFailure = @ptrCast(@alignCast(ctx));
        if (step != .metaWritten) return;
        self.saved = std.c.dup(self.fd);
        _ = std.c.dup2(self.pipe[0], self.fd);
    }

    fn restore(self: *MetaSyncFailure) void {
        _ = std.c.dup2(self.saved, self.fd);
        for ([_]std.c.fd_t{ self.saved, self.pipe[0], self.pipe[1] }) |fd| _ = std.c.close(fd);
    }
};

test "durability durable: after a commit's meta sync fails, the file syncs nothing until it is reopened, and keeps the commits that published" {
    var fx = try Fixture.init("meta_sync");
    defer fx.deinit();

    var conn = try fx.connect();
    conn.durability = .durable;
    // A second holder shares the file's environment, and its failure.
    const other = try fx.connect();
    other.durability = .commit;

    var failure = MetaSyncFailure{ .fd = conn.file.env.inner.dataFile.fd };
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&failure.pipe));
    conn.file.env.inner.commitObserver = .{ .ctx = &failure, .notify = MetaSyncFailure.notify };
    var w = try db.beginWrite(conn);
    try db.put(&w, "t", "a", value.fromFixnum(5).?);
    const committed = db.commit(&w);
    conn.file.env.inner.commitObserver = null;
    failure.restore();
    try testing.expectError(error.DurabilityUnknown, committed);
    try testing.expectEqualStrings("db/durability-unknown", db.failureName(error.DurabilityUnknown));
    try testing.expect(conn.file.unsynced);
    try testing.expect(conn.file.syncFailed());

    // Nothing syncs again: a sync fails on every connection, and a
    // commit that would sync fails before it writes anything, while one
    // that syncs nothing commits.
    const before = db.engineSyncs();
    try testing.expectError(error.SyncFailed, db.sync(conn));
    try testing.expectError(error.SyncFailed, db.sync(other));
    try testing.expectEqualStrings("db/sync-failed", db.failureName(error.SyncFailed));
    w = try db.beginWrite(conn);
    try db.put(&w, "t", "b", value.fromFixnum(6).?);
    try testing.expectError(error.SyncFailed, db.commit(&w));
    try testing.expectEqual(@as(u32, 0), conn.open_txns);
    w = try db.beginWrite(other);
    try db.put(&w, "t", "c", value.fromFixnum(7).?);
    try db.commit(&w);
    {
        var r = try db.beginRead(conn);
        defer db.abortRead(&r);
        try testing.expectEqual(@as(i64, 5), (try db.get(&r, "t", "a", synthHash, synthEq)).?.asFixnum());
        try testing.expect((try db.get(&r, "t", "b", synthHash, synthEq)) == null);
        try testing.expectEqual(@as(i64, 7), (try db.get(&r, "t", "c", synthHash, synthEq)).?.asFixnum());
    }

    // A close syncs nothing and raises nothing. A connection opened
    // while another holds the file shares its environment, so its
    // syncs fail too; the last close lets the environment go.
    try db.close(conn);
    conn = try fx.connect();
    try testing.expectError(error.SyncFailed, db.sync(conn));
    try db.close(conn);
    db.StoreFile.syncAll();
    try db.close(other);
    try testing.expectEqual(before, db.engineSyncs());

    // Reopened, the file syncs again and holds exactly the commits
    // that published.
    conn = try fx.connect();
    conn.durability = .durable;
    try testing.expect(!conn.file.syncFailed());
    {
        var r = try db.beginRead(conn);
        defer db.abortRead(&r);
        try testing.expectEqual(@as(i64, 5), (try db.get(&r, "t", "a", synthHash, synthEq)).?.asFixnum());
        try testing.expect((try db.get(&r, "t", "b", synthHash, synthEq)) == null);
        try testing.expectEqual(@as(i64, 7), (try db.get(&r, "t", "c", synthHash, synthEq)).?.asFixnum());
    }
    w = try db.beginWrite(conn);
    try db.put(&w, "t", "b", value.fromFixnum(6).?);
    try db.commit(&w);
    try testing.expect(db.engineSyncs() > before);
    try db.sync(conn);
    try db.close(conn);
}

test "syncAll: one sync for each file written without one; shutdown syncs a file it releases last" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    var paths: [3][:0]u8 = undefined;
    var conns: [3]*db.Connection = undefined;
    for (&paths, &conns, 0..) |*p, *c, i| {
        p.* = try tmpDbPath(testing.allocator, &.{'a' + @as(u8, @intCast(i))});
        c.* = try db.open(testing.allocator, &heap, &interner, p.*.ptr);
        c.*.durability = .commit;
    }
    defer for (paths) |p| {
        cleanupDb(p);
        testing.allocator.free(p);
    };
    defer for (conns[0..2]) |c| db.shutdown(c);
    for (conns[0..2]) |c| {
        var w = try db.beginWrite(c);
        try db.put(&w, "t", "k", value.fromFixnum(1).?);
        try db.commit(&w);
    }
    const before = db.engineSyncs();
    db.StoreFile.syncAll();
    try testing.expectEqual(before + 2, db.engineSyncs());
    db.StoreFile.syncAll();
    try testing.expectEqual(before + 2, db.engineSyncs());

    var w = try db.beginWrite(conns[2]);
    try db.put(&w, "t", "k", value.fromFixnum(1).?);
    try db.commit(&w);
    db.shutdown(conns[2]);
    try testing.expectEqual(before + 3, db.engineSyncs());
}

test "held snapshot: kept while it is the latest commit; a commit passing it, a write, a collection and the last release let it go" {
    var fx = try Fixture.init("held");
    defer fx.deinit();

    const conn = try fx.connect();
    const file = conn.file;
    try testing.expect(file.takeHeld() == null);

    // Kept, and handed out again while no commit has passed it.
    const first = try file.env.beginRead();
    file.keep(first);
    try testing.expectEqual(first, file.takeHeld().?);
    try testing.expect(file.takeHeld() == null);
    // One is held at a time: a second read ends.
    const second = try file.env.beginRead();
    file.keep(first);
    file.keep(second);
    try testing.expectEqual(first, file.held.?);

    // A commit the file's own writer did not begin, as another
    // process's is, passes it: the next take ends it.
    const other = try file.env.beginWriteWith(.{ .sync = .none });
    try other.putInTree(try other.openTree("t", true), "a", "b");
    try other.commit();
    try testing.expect(file.takeHeld() == null);
    try testing.expect(file.held == null);

    // A read that a commit passed while it ran is not kept.
    const stale = try file.env.beginRead();
    var w = try db.beginWrite(conn);
    try db.put(&w, "t", "k", value.fromFixnum(1).?);
    try db.commit(&w);
    file.keep(stale);
    try testing.expect(file.held == null);

    // This process's own write lets it go before it begins.
    file.keep(try file.env.beginRead());
    try testing.expect(file.held != null);
    w = try db.beginWrite(conn);
    try testing.expect(file.held == null);
    db.abortWrite(&w);

    // So does a collection's sweep.
    file.keep(try file.env.beginRead());
    db.sweepHandles(&fx.heap, true);
    try testing.expect(file.held == null);

    // The last release ends one still held (the allocator and emdb
    // would report a transaction outliving its environment).
    file.keep(try file.env.beginRead());
    try testing.expect(file.held != null);
}

test "durability commit: a commit survives its process ending without a sync or a close" {
    var fx = try Fixture.init("crash");
    defer fx.deinit();

    // The child commits and ends at once, as a killed process does:
    // no sync, no close, no exit handlers.
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        const conn = fx.connect() catch std.c._exit(1);
        conn.durability = .commit;
        var w = db.beginWrite(conn) catch std.c._exit(2);
        db.put(&w, "t", "k", value.fromFixnum(42).?) catch std.c._exit(3);
        const before = db.engineSyncs();
        db.commit(&w) catch std.c._exit(4);
        std.c._exit(if (db.engineSyncs() == before) 0 else 5);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    try testing.expectEqual(@as(c_int, 0), status);

    const conn = try fx.connect();
    var r = try db.beginRead(conn);
    defer db.abortRead(&r);
    try testing.expectEqual(@as(i64, 42), (try db.get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
}

test "open: a new store has 16 KiB pages and the pinned tree capacity" {
    var fx = try Fixture.init("pagesize");
    defer fx.deinit();

    const conn = try fx.connect();

    try testing.expectEqual(db.page_size, conn.file.env.info().pageSize);
    try testing.expectEqual(db.page_size, conn.file.env.options.pageSize);
    try testing.expectEqual(db.max_named_trees, conn.file.env.options.maxNamedTrees);
    try testing.expectEqual(emdb.btree.maxKeySize(db.page_size), conn.file.env.maxKeySize());
    try testing.expectEqual(db.map_grow_step, conn.file.env.options.growStep);
    try testing.expect(conn.file.env.info().mapSize <= db.initial_map_size);
}

test "open: the reader table has reader_slots slots, so more than emdb's default 126 reads run at once" {
    var fx = try Fixture.init("readers");
    defer fx.deinit();

    const conn = try fx.connect();
    try testing.expectEqual(db.reader_slots, conn.file.env.info().maxReaders);
    var reads: [200]db.ReadTxn = undefined;
    for (&reads) |*r| r.* = try db.beginRead(conn);
    for (&reads) |*r| db.abortRead(r);
}

test "open: failure in a missing directory releases everything it took" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    // `std.testing.allocator` reports the leak if the canonical path
    // survives the failed open, and the double free if it is
    // released twice.
    const path: [:0]const u8 = "test_nexis_db_no_such_dir/missing/store.emdb";
    try testing.expectError(
        error.OpenFailed,
        db.open(testing.allocator, &heap, &interner, path.ptr),
    );
}

test "open: a file that is not an emdb store is refused without leaking" {
    var fx = try Fixture.init("notastore");
    defer fx.deinit();

    // Two pages of 0xFF: a non-zero size with no valid meta page.
    {
        const io = std.testing.io;
        const file = try std.Io.Dir.cwd().createFile(io, fx.path, .{});
        defer file.close(io);
        const junk: [2 * db.page_size]u8 = @splat(0xFF);
        try file.writeStreamingAll(io, &junk);
    }

    if (fx.connect()) |conn| {
        db.shutdown(conn);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "put / get / del: single-tree round-trip of a scalar" {
    var fx = try Fixture.init("putget");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try db.beginWrite(conn);
    try db.put(&wtxn, "users", "alice", value.fromFixnum(42).?);
    try db.commit(&wtxn);

    var rtxn = try db.beginRead(conn);
    defer db.abortRead(&rtxn);
    const got = try db.get(&rtxn, "users", "alice", &synthHash, &synthEq);
    try testing.expect(got != null);
    try testing.expect(got.?.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 42), got.?.asFixnum());

    // Absent key.
    const miss = try db.get(&rtxn, "users", "bob", &synthHash, &synthEq);
    try testing.expect(miss == null);
}

test "put / get: multiple named trees are independent" {
    var fx = try Fixture.init("multitree");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try db.beginWrite(conn);
    try db.put(&wtxn, "treeA", "k0", value.fromFixnum(1).?);
    try db.put(&wtxn, "treeB", "k0", value.fromFixnum(2).?);
    try db.put(&wtxn, "treeC", "k0", value.fromFixnum(3).?);
    try db.commit(&wtxn);

    var rtxn = try db.beginRead(conn);
    defer db.abortRead(&rtxn);
    try testing.expectEqual(@as(i64, 1), (try db.get(&rtxn, "treeA", "k0", &synthHash, &synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 2), (try db.get(&rtxn, "treeB", "k0", &synthHash, &synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 3), (try db.get(&rtxn, "treeC", "k0", &synthHash, &synthEq)).?.asFixnum());
}

test "del: removes the key, subsequent get returns null" {
    var fx = try Fixture.init("del");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try db.beginWrite(conn);
    try db.put(&wtxn, "t", "k", value.fromFixnum(99).?);
    try db.commit(&wtxn);

    var wtxn2 = try db.beginWrite(conn);
    const removed = try db.del(&wtxn2, "t", "k");
    try testing.expect(removed);
    try db.commit(&wtxn2);

    var rtxn = try db.beginRead(conn);
    defer db.abortRead(&rtxn);
    try testing.expect((try db.get(&rtxn, "t", "k", &synthHash, &synthEq)) == null);
}

test "treeId: one handle per name, remembered across transactions, loaded once per transaction" {
    var fx = try Fixture.init("treeids");
    defer fx.deinit();

    const conn = try fx.connect();

    // Unknown tree, no create: nothing resolved, nothing cached.
    {
        var rtxn = try db.beginRead(conn);
        defer db.abortRead(&rtxn);
        try testing.expect((try db.treeId(&rtxn, "users", false)) == null);
        try testing.expectEqual(@as(usize, 0), conn.tree_ids.count());
    }

    var first_id: emdb.TreeId = undefined;
    {
        var wtxn = try db.beginWrite(conn);
        first_id = (try db.treeId(&wtxn, "users", true)).?;
        try testing.expect(wtxn.opened.isSet(first_id));
        try testing.expectEqual(first_id, (try db.treeId(&wtxn, "users", true)).?);
        try db.put(&wtxn, "users", "alice", value.fromFixnum(1).?);
        try db.commit(&wtxn);
    }
    try testing.expectEqual(@as(usize, 1), conn.tree_ids.count());
    try testing.expectEqual(first_id, conn.tree_ids.get("users").?);

    // A later transaction starts with nothing loaded and resolves
    // the same handle.
    {
        var rtxn = try db.beginRead(conn);
        defer db.abortRead(&rtxn);
        try testing.expect(!rtxn.opened.isSet(first_id));
        try testing.expectEqual(first_id, (try db.treeId(&rtxn, "users", false)).?);
        try testing.expect(rtxn.opened.isSet(first_id));
        try testing.expectEqual(@as(i64, 1), (try db.get(&rtxn, "users", "alice", &synthHash, &synthEq)).?.asFixnum());
    }
    try testing.expectEqual(@as(usize, 1), conn.tree_ids.count());
}

test "treeId: a tree created by an aborted transaction reads as empty afterwards" {
    var fx = try Fixture.init("treeabort");
    defer fx.deinit();

    const conn = try fx.connect();

    {
        var wtxn = try db.beginWrite(conn);
        try db.put(&wtxn, "scratch", "k", value.fromFixnum(7).?);
        db.abortWrite(&wtxn);
    }
    {
        var rtxn = try db.beginRead(conn);
        defer db.abortRead(&rtxn);
        try testing.expect((try db.get(&rtxn, "scratch", "k", &synthHash, &synthEq)) == null);
    }
    {
        var wtxn = try db.beginWrite(conn);
        defer db.abortWrite(&wtxn);
        try testing.expect(!(try db.del(&wtxn, "scratch", "k")));
    }
}

/// A store at `fx.path` whose tree `t` holds `a`, a value of `big`
/// bytes of `x` on overflow pages under `b`, and `c`; with `damage`,
/// one byte in the middle of `b`'s value is changed on the disk, so its
/// page fails its check.
fn walkStore(fx: *Fixture, big: usize, damage: bool) !void {
    {
        const conn = try fx.connect();
        defer db.shutdown(conn);
        const txn = try conn.file.env.beginWriteWith(.{ .sync = .none });
        errdefer txn.abort();
        const t = try txn.openTree("t", true);
        const bytes = try testing.allocator.alloc(u8, big);
        defer testing.allocator.free(bytes);
        @memset(bytes, 'x');
        try txn.putInTree(t, "a", "1");
        try txn.putInTree(t, "b", bytes);
        try txn.putInTree(t, "c", "3");
        try txn.commit();
    }
    if (!damage) return;
    const io = testing.io;
    const data = try std.Io.Dir.cwd().readFileAlloc(io, fx.path, testing.allocator, .unlimited);
    defer testing.allocator.free(data);
    const run: [64]u8 = @splat('x');
    const at = std.mem.find(u8, data, &run).? + big / 2;
    const file = try std.Io.Dir.cwd().openFile(io, fx.path, .{ .mode = .read_write });
    defer file.close(io);
    try file.writePositionalAll(io, "y", at);
}

test "Walk: a page that fails its check ends the walk with its error, never as a shorter walk" {
    var fx = try Fixture.init("walk_damaged");
    defer fx.deinit();
    try walkStore(&fx, 1 << 20, true);
    const conn = try fx.connect();

    var r = try db.beginRead(conn);
    defer db.abortRead(&r);
    var walk: db.Walk = undefined;
    try testing.expect(try walk.begin(&r, "t"));
    defer walk.end();
    try testing.expectEqualStrings("a", (try walk.first(null)).?.key);
    try testing.expectError(error.InvalidPage, walk.next());

    // A write under a walk copies the rest of it, and meets the same page.
    var w = try db.beginWrite(conn);
    defer db.abortWrite(&w);
    var over: db.Walk = undefined;
    try testing.expect(try over.begin(&w, "t"));
    defer over.end();
    _ = (try over.first(null)).?;
    try testing.expectError(error.InvalidPage, db.put(&w, "u", "k", value.fromFixnum(1).?));
}

test "Walk: a write to any tree of the transaction copies the rest first; values come whole from overflow pages" {
    var fx = try Fixture.init("walk_copy");
    defer fx.deinit();
    try walkStore(&fx, 3 * db.page_size, false);
    const conn = try fx.connect();

    var w = try db.beginWrite(conn);
    defer db.abortWrite(&w);
    var walk: db.Walk = undefined;
    try testing.expect(try walk.begin(&w, "t"));
    defer walk.end();
    try testing.expectEqualStrings("1", (try walk.first(null)).?.value);
    try testing.expect(walk.rest == null);
    // Another tree: the cursor may not step past a change anywhere in
    // the transaction (emdb API-C06A).
    try db.put(&w, "u", "k", value.fromFixnum(1).?);
    try testing.expect(walk.rest != null);
    try testing.expect(try db.del(&w, "t", "c"));
    const b = (try walk.next()).?;
    try testing.expectEqualStrings("b", b.key);
    try testing.expectEqual(@as(usize, 3 * db.page_size), b.value.len);
    try testing.expect(std.mem.allEqual(u8, b.value, 'x'));
    try testing.expectEqualStrings("c", (try walk.next()).?.key);
    try testing.expect(try walk.next() == null);
}

test "put / get: container values (list, map, set) codec round-trip" {
    const list_mod = nx.list;
    const champ = nx.champ;

    var fx = try Fixture.init("containers");
    defer fx.deinit();

    const conn = try fx.connect();

    // List
    const lst = try list_mod.fromSlice(&fx.heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    // Map (use interned keywords so codec can emit textual form).
    const kw = try fx.interner.internKeywordValue("alpha");
    var m = try champ.mapEmpty(&fx.heap);
    m = try champ.mapAssoc(&fx.heap, m, kw, value.fromFixnum(100).?, &synthHash, &synthEq);

    // Set
    var s = try champ.setEmpty(&fx.heap);
    s = try champ.setConj(&fx.heap, s, value.fromFixnum(10).?, &synthHash, &synthEq);
    s = try champ.setConj(&fx.heap, s, value.fromFixnum(20).?, &synthHash, &synthEq);

    var wtxn = try db.beginWrite(conn);
    try db.put(&wtxn, "objects", "list", lst);
    try db.put(&wtxn, "objects", "map", m);
    try db.put(&wtxn, "objects", "set", s);
    try db.commit(&wtxn);

    var rtxn = try db.beginRead(conn);
    defer db.abortRead(&rtxn);

    const got_lst = try db.get(&rtxn, "objects", "list", &synthHash, &synthEq);
    try testing.expect(got_lst != null and got_lst.?.kind() == .list);
    try testing.expectEqual(@as(usize, 3), list_mod.count(got_lst.?));

    const got_m = try db.get(&rtxn, "objects", "map", &synthHash, &synthEq);
    try testing.expect(got_m != null and got_m.?.kind() == .persistent_map);
    try testing.expectEqual(@as(usize, 1), champ.mapCount(got_m.?));

    const got_s = try db.get(&rtxn, "objects", "set", &synthHash, &synthEq);
    try testing.expect(got_s != null and got_s.?.kind() == .persistent_set);
    try testing.expectEqual(@as(usize, 2), champ.setCount(got_s.?));
}

test "reopen-connection readback: values survive conn close/reopen" {
    var fx = try Fixture.init("reopen");
    defer fx.deinit();

    // Session 1: write.
    {
        const conn = try fx.connect();
        defer db.shutdown(conn);

        var wtxn = try db.beginWrite(conn);
        try db.put(&wtxn, "persistent", "answer", value.fromFixnum(42).?);
        try db.put(&wtxn, "persistent", "pi", value.fromFloat(3.14));
        try db.commit(&wtxn);
    }

    // Session 2: reopen + read.
    {
        const conn = try fx.connect();
        defer db.shutdown(conn);

        var rtxn = try db.beginRead(conn);
        defer db.abortRead(&rtxn);
        const ans = try db.get(&rtxn, "persistent", "answer", &synthHash, &synthEq);
        try testing.expect(ans != null and ans.?.kind() == .fixnum);
        try testing.expectEqual(@as(i64, 42), ans.?.asFixnum());

        const pi = try db.get(&rtxn, "persistent", "pi", &synthHash, &synthEq);
        try testing.expect(pi != null and pi.?.kind() == .float);
        try testing.expectEqual(@as(f64, 3.14), pi.?.asFloat());
    }
}

test "ref: identity triple populated; conn pointer attached" {
    var fx = try Fixture.init("refinit");
    defer fx.deinit();

    const conn = try fx.connect();

    const r = try db.ref(&fx.heap, conn, "users", "alice");
    try testing.expect(r.kind() == .durable_ref);
    try testing.expectEqual(conn.storeId(), db.refStoreId(r));
    try testing.expectEqualStrings("users", db.refTreeName(r));
    try testing.expectEqualStrings("alice", db.refKeyBytes(r));
    try testing.expectEqual(@as(?*db.Connection, conn), db.refConn(r));
}

test "putRef / getRef / delRef: round-trip via ref" {
    var fx = try Fixture.init("refio");
    defer fx.deinit();

    const conn = try fx.connect();

    const r = try db.ref(&fx.heap, conn, "users", "alice");

    var wtxn = try db.beginWrite(conn);
    try db.putRef(&wtxn, r, value.fromFixnum(123).?);
    try db.commit(&wtxn);

    {
        var rtxn = try db.beginRead(conn);
        defer db.abortRead(&rtxn);
        const got = try db.getRef(&rtxn, r, &synthHash, &synthEq);
        try testing.expect(got != null and got.?.kind() == .fixnum);
        try testing.expectEqual(@as(i64, 123), got.?.asFixnum());
    }

    var wtxn2 = try db.beginWrite(conn);
    const removed = try db.delRef(&wtxn2, r);
    try testing.expect(removed);
    try db.commit(&wtxn2);
}

test "getRef: nullconn ref → ConnectionUnavailable" {
    var fx = try Fixture.init("nullconn");
    defer fx.deinit();

    const conn = try fx.connect();

    // Ref constructed from bytes (no conn).
    const r = try db.refFromBytes(&fx.heap, 999, "t", "k");

    var rtxn = try db.beginRead(conn);
    defer db.abortRead(&rtxn);
    try testing.expectError(db.DbError.ConnectionUnavailable, db.getRef(&rtxn, r, &synthHash, &synthEq));
}

test "getRef: cross-store ref → StoreMismatch" {
    var fx = try Fixture.init("xstore");
    defer fx.deinit();

    const conn = try fx.connect();

    // A ref made on a connection to another store.
    var other = conn.*;
    other.store_id_lo = 0xBAD_BAD_BAD_BAD_0000;
    const r = try db.ref(&fx.heap, &other, "t", "k");

    var rtxn = try db.beginRead(conn);
    defer db.abortRead(&rtxn);
    try testing.expectError(db.DbError.StoreMismatch, db.getRef(&rtxn, r, &synthHash, &synthEq));
}

test "invalid tree name / key: surfaces InvalidTreeName / InvalidKey" {
    var fx = try Fixture.init("invalid");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try db.beginWrite(conn);
    defer db.abortWrite(&wtxn);
    try testing.expectError(db.DbError.InvalidTreeName, db.put(&wtxn, "", "k", value.nilValue()));
    try testing.expectError(db.DbError.InvalidKey, db.put(&wtxn, "t", "", value.nilValue()));
}
