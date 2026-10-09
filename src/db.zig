//! db.zig — store files, `db/*` connections, transactions and
//! durable refs over emdb (docs/DB.md): the one environment of a store
//! file in the process (`StoreFile`, §3.1), which Nextomic shares;
//! connections, transaction handles and tree walks (§3); the
//! `durable_ref` heap kind and its identity hash and equality (§4, §7).

const std = @import("std");
const builtin = @import("builtin");
const value = @import("value.zig");
const heap_mod = @import("heap.zig");
const intern_mod = @import("intern.zig");
const hash_mod = @import("hash.zig");
const codec_mod = @import("codec.zig");
const emdb = @import("emdb");

const Value = value.Value;
const Kind = value.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;
const Interner = intern_mod.Interner;

const testing = std.testing;

// =============================================================================
// Errors (DB.md §5)
// =============================================================================

pub const DbError = error{
    ConnectionUnavailable,
    StoreMismatch,
    InvalidTreeName,
    InvalidKey,
    /// `close` of a connection while a native holds one of its
    /// transactions, or with a Zig-level transaction still open.
    TransactionsOpen,
    /// A store file with more than one hard link (DB.md §3.1).
    HardLinked,
};

/// The keyword a storage-layer error surfaces as at the language
/// level (DB.md §8). Each emdb error with a distinct cause gets its
/// own name; the rest, which nexis never reaches, share `:db-error`
/// (the inline test "failureName" holds the table to `emdb.Error`). A
/// value of a kind with no serialized form is `:unserializable`; bytes
/// that do not decode are `:codec-failed`.
pub fn failureName(err: anyerror) []const u8 {
    return switch (err) {
        error.KeyTooLarge => "db/key-too-large",
        error.ValueTooLarge => "db/value-too-large",
        error.MaxDbsReached => "db/max-trees",
        error.NotFound => "db/not-found",
        error.Corrupted, error.InvalidPage, error.FormatVersionMismatch => "db/corrupted",
        error.DatabaseFull => "db/map-full",
        error.DiskFull => "db/disk-full",
        error.QuotaExceeded => "db/quota-exceeded",
        error.MmapFailed => "db/mmap-failed",
        error.OpenFailed, error.LockFileMismatch => "db/open-failed",
        error.WriterActive, error.EnvBusy, error.TransactionsOpen => "db/busy",
        error.ReaderTableFull => "db/readers-full",
        error.HardLinked => "db/hard-linked",
        error.TxnBroken => "db/txn-aborted",
        error.TxnReadOnly => "db/read-only",
        error.SyncFailed => "db/sync-failed",
        error.DurabilityUnknown => "db/durability-unknown",
        error.StoreMismatch => "db/store-mismatch",
        error.ConnectionUnavailable => "db/no-connection",
        error.InvalidTreeName, error.InvalidKey => "db/invalid-key",
        error.UnserializableKind => "unserializable",
        error.TruncatedInput,
        error.TrailingBytes,
        error.InvalidVersion,
        error.InvalidKindByte,
        error.InvalidLeb128,
        error.InvalidCharScalar,
        error.MalformedPayload,
        error.Overflow,
        error.InvalidListTail,
        error.EmptyName,
        => "codec-failed",
        else => "db-error",
    };
}

// =============================================================================
// Store files (DB.md §3.1)
// =============================================================================

/// The one emdb environment of a store file in this process, shared by
/// every `Connection` and Nextomic store of the file. emdb's writer
/// lock is per file and waits for the holder, and it is per process:
/// a second environment on a file this process writes would wait on
/// itself forever, and an environment opened through another spelling
/// of the path would take a lock file of its own and write beside the
/// first. One environment per file makes a second writer
/// `error.WriterActive` instead, whichever connection asks.
///
/// Files are told apart by `(st_dev, st_ino)`, so a symlink or `./x`
/// finds the file already open, and a copy is another file. The
/// environment opens at the canonical path, so every process that
/// names the file shares one lock file. emdb names the lock file
/// after the path, and no path is canonical across hard links, so a
/// file with a second hard link is refused (`error.HardLinked`):
/// two processes opening it by two names would write beside each
/// other, each blind to the other's readers.
///
/// The runtime is single-threaded, so the list of open files is a
/// plain global. The environment lives on the allocator of the first
/// open, which must outlive every connection to the file.
pub const StoreFile = struct {
    env: emdb.Env,
    /// Canonical absolute path the environment was opened at, owned.
    path: [:0]u8,
    id: FileId,
    /// Connections and stores holding the file; the last `release`
    /// closes the environment.
    refs: u32,
    next: ?*StoreFile,

    /// A commit since the last sync left without one: the file's
    /// data or meta may still be only in the operating system's cache.
    unsynced: bool,
    /// How the open write transaction's commit syncs.
    write_sync: emdb.SyncOverride,
    /// A Nextomic read transaction, every tree loaded, kept from one
    /// read to the next while it is still the file's latest commit
    /// (DB.md §3.4).
    held: ?*emdb.Txn,

    var open_files: ?*StoreFile = null;

    /// The open file at `path`, or the file opened (or created) now on
    /// `allocator` with the pinned geometry: `page_size`,
    /// `max_named_trees`, `reader_slots`, `initial_map_size` and
    /// `map_grow_step`. A file this process may read but not write
    /// opens read-only.
    pub fn acquire(path: [*:0]const u8, allocator: std.mem.Allocator) !*StoreFile {
        const options: emdb.EnvOptions = .{
            .allocator = allocator,
            .pageSize = page_size,
            .maxNamedTrees = max_named_trees,
            .maxReaders = reader_slots,
            .mapSize = initial_map_size,
            .growStep = map_grow_step,
        };
        const canonical = try canonicalPath(allocator, path);
        errdefer allocator.free(canonical);
        if (FileId.of(std.c.AT.FDCWD, canonical.ptr)) |id| {
            if (id.hard_linked) return DbError.HardLinked;
            var it = open_files;
            while (it) |f| : (it = f.next) {
                if (f.id.dev == id.dev and f.id.ino == id.ino) {
                    allocator.free(canonical);
                    f.refs += 1;
                    return f;
                }
            }
        }
        try checkLockFile(allocator, canonical);
        const self = try allocator.create(StoreFile);
        errdefer allocator.destroy(self);
        self.env = emdb.Env.open(canonical.ptr, options) catch |err| switch (err) {
            error.OpenFailed => blk: {
                if (!readOnlyFile(canonical.ptr)) return err;
                var read_only = options;
                read_only.readOnly = true;
                break :blk emdb.Env.open(canonical.ptr, read_only) catch return err;
            },
            else => return err,
        };
        errdefer self.env.close();
        self.id = FileId.of(self.env.inner.dataFile.fd, "") orelse return error.OpenFailed;
        if (self.id.hard_linked) return DbError.HardLinked;
        self.path = canonical;
        self.refs = 1;
        self.unsynced = false;
        self.write_sync = .full;
        self.held = null;
        self.next = open_files;
        open_files = self;
        return self;
    }

    /// Drop one hold; the last syncs what is unsynced (`closingSync`),
    /// closes the environment and frees the file.
    pub fn release(self: *StoreFile) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        self.dropHeld();
        self.syncOrWarn();
        var link = &open_files;
        while (link.*) |f| : (link = &f.next) {
            if (f == self) {
                link.* = self.next;
                break;
            }
        }
        const allocator = self.env.options.allocator;
        self.env.close();
        allocator.free(self.path);
        allocator.destroy(self);
    }

    /// The file's write transaction: `error.WriterActive` while any
    /// holder of the file has it open, `error.TxnReadOnly` on a file
    /// opened read-only.
    pub fn beginWrite(self: *StoreFile, options: emdb.Env.WriteOptions) !*emdb.Txn {
        if (self.env.options.readOnly) return error.TxnReadOnly;
        // The commit would pass the held snapshot, which would then pin
        // the pages it frees until the next read.
        self.dropHeld();
        const txn = try self.env.beginWriteWith(options);
        self.write_sync = options.sync;
        return txn;
    }

    /// Commit the file's write transaction `txn`. One that syncs data
    /// and meta makes every commit before it durable too; any other
    /// leaves the file unsynced until `sync`.
    pub fn commit(self: *StoreFile, txn: *emdb.Txn) !void {
        txn.commit() catch |err| {
            // Published and seen by every transaction, but its meta
            // page did not sync, and nothing will (`syncFailed`).
            if (err == error.DurabilityUnknown) self.unsynced = true;
            return err;
        };
        self.unsynced = switch (self.write_sync) {
            // nexis never opens an environment with emdb's `noSync`
            // or `noMetaSync`, so its own setting is a full sync.
            .full, .inherit => false,
            .none, .noMeta => true,
        };
    }

    /// Make every commit so far durable with one full sync of the
    /// file, when a commit since the last sync was left without one.
    /// `error.SyncFailed` once a sync of the file has failed
    /// (`syncFailed`), whatever is unsynced.
    pub fn sync(self: *StoreFile) !void {
        if (self.syncFailed()) return error.SyncFailed;
        if (!self.unsynced) return;
        try self.env.sync();
        self.unsynced = false;
    }

    /// Whether a sync of the file's environment has failed: a commit's
    /// data or meta sync (`DurabilityUnknown` among them) or a full
    /// sync. The environment then syncs nothing more until the file is
    /// opened again (emdb INV-SYNC-04), since a failed fsync may have
    /// dropped the pages it could not write and marked them clean: a
    /// commit that would sync fails with `SyncFailed` before it writes
    /// anything, one that syncs nothing still commits, and `sync`
    /// fails (DB.md §3.3).
    pub fn syncFailed(self: *const StoreFile) bool {
        return self.env.inner.syncHasFailed();
    }

    /// The sync of a close: `sync`, but nothing once a sync of the file
    /// has failed, which was reported where it failed. A close cannot
    /// make the file durable then, and raising it again would hide the
    /// error a `finally` or `with-conn` is unwinding with.
    pub fn closingSync(self: *StoreFile) !void {
        if (self.syncFailed()) return;
        try self.sync();
    }

    /// `closingSync` where no caller can take its error: teardown and
    /// exit.
    fn syncOrWarn(self: *StoreFile) void {
        self.closingSync() catch |err| std.debug.print("nexis: syncing {s} failed ({s}); its latest commits may be lost if the system crashes\n", .{ self.path, @errorName(err) });
    }

    /// Sync every open file that needs it and let every held snapshot
    /// go: what a process runs on its way out, where no connection is
    /// closed first (`exit`, an uncaught error in `bin/nexis`).
    pub fn syncAll() void {
        var it = open_files;
        while (it) |f| : (it = f.next) {
            f.dropHeld();
            f.syncOrWarn();
        }
    }

    /// The held read transaction, while no commit has passed it; the
    /// caller ends it with `keep`. Null when none is held, and when the
    /// one held was passed, which ends it.
    pub fn takeHeld(self: *StoreFile) ?*emdb.Txn {
        const txn = self.held orelse return null;
        self.held = null;
        if (self.latest(txn)) return txn;
        txn.abort();
        return null;
    }

    /// End the read `txn`: held for the next read when none is and it
    /// is still the latest commit, aborted otherwise.
    pub fn keep(self: *StoreFile, txn: *emdb.Txn) void {
        if (self.held == null and self.latest(txn)) {
            self.held = txn;
        } else txn.abort();
    }

    pub fn dropHeld(self: *StoreFile) void {
        const txn = self.held orelse return;
        self.held = null;
        txn.abort();
    }

    /// Let every held snapshot go: at each collection and while the
    /// REPL waits for input, so an idle or busy program pins no pages
    /// another process frees.
    pub fn dropAllHeld() void {
        var it = open_files;
        while (it) |f| : (it = f.next) f.dropHeld();
    }

    /// How many open files hold a snapshot (§3.4).
    pub fn heldCount() usize {
        var n: usize = 0;
        var it = open_files;
        while (it) |f| : (it = f.next) {
            if (f.held != null) n += 1;
        }
        return n;
    }

    /// Whether `txn` reads the file's newest commit, by this process
    /// or any other.
    fn latest(self: *StoreFile, txn: *emdb.Txn) bool {
        return txn.txnId == self.env.lastTxnId();
    }

    /// A regular file this process may read but not write: the one
    /// `OpenFailed` that opens again read-only.
    fn readOnlyFile(path: [*:0]const u8) bool {
        if (std.c.access(path, std.c.R_OK) != 0 or std.c.access(path, std.c.W_OK) == 0) return false;
        // A directory reads too, and is never a store.
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
        if (fd >= 0) {
            _ = std.c.close(fd);
            return false;
        }
        return true;
    }
};

/// emdb opens `<path>-lock` for writing, creating it, through any
/// symlink, and sizes and overwrites it: a symlink planted there, or a
/// device or pipe, would have the reader table written over whatever
/// it names. Refused as `OpenFailed`. A link planted after this check
/// is still followed, so a store belongs in a directory only its owner
/// writes (DB.md §3.1).
fn checkLockFile(allocator: std.mem.Allocator, canonical: [:0]const u8) !void {
    const lock = try std.fmt.allocPrintSentinel(allocator, "{s}-lock", .{canonical}, 0);
    defer allocator.free(lock);
    if (isSymlink(lock)) return error.OpenFailed;
    if (FileId.of(std.c.AT.FDCWD, lock.ptr)) |id| if (!id.regular) return error.OpenFailed;
}

fn isSymlink(path: [*:0]const u8) bool {
    var buf: [1]u8 = undefined;
    return std.c.readlink(path, &buf, buf.len) >= 0;
}

/// The device and inode that name a file whatever path reaches it.
const FileId = struct {
    dev: u64,
    ino: u64,
    /// A regular file with a second name (`StoreFile`). A directory's
    /// links are its entries; emdb refuses it as a store.
    hard_linked: bool,
    regular: bool,

    /// The file at `path` relative to the directory `fd`, or the file
    /// open as `fd` when `path` is empty; null when it cannot be
    /// examined. Zig's `std.c` declares no `stat` family for Linux,
    /// whose glibc versions those symbols, so Linux asks the kernel's
    /// `statx`.
    fn of(fd: std.c.fd_t, path: [*:0]const u8) ?FileId {
        if (builtin.target.os.tag == .linux) {
            const linux = std.os.linux;
            var sx: linux.Statx = undefined;
            const flags: u32 = if (path[0] == 0) linux.AT.EMPTY_PATH else 0;
            if (linux.errno(linux.statx(fd, path, flags, .{ .TYPE = true, .NLINK = true, .INO = true }, &sx)) != .SUCCESS) return null;
            return .{
                .dev = @as(u64, sx.dev_major) << 32 | sx.dev_minor,
                .ino = sx.ino,
                .hard_linked = linux.S.ISREG(sx.mode) and sx.nlink > 1,
                .regular = linux.S.ISREG(sx.mode),
            };
        }
        var st: std.c.Stat = undefined;
        const rc = if (path[0] == 0) std.c.fstat(fd, &st) else std.c.fstatat(fd, path, &st, 0);
        if (rc != 0) return null;
        return .{
            .dev = @bitCast(@as(i64, st.dev)),
            .ino = st.ino,
            .hard_linked = std.c.S.ISREG(st.mode) and st.nlink > 1,
            .regular = std.c.S.ISREG(st.mode),
        };
    }
};

/// The absolute path of `path` with every symlink resolved; for a file
/// not yet created, its resolved directory joined with its name. A
/// symlink to no file has the file it names created first: emdb would
/// create it through the link, and name the lock file after the link,
/// where every later opener of the target names it after the target.
fn canonicalPath(allocator: std.mem.Allocator, path: [*:0]const u8) ![:0]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.realpath(path, &buf)) |resolved| return allocator.dupeSentinel(u8, std.mem.sliceTo(resolved, 0), 0);
    if (isSymlink(path)) {
        const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true }, @as(c_uint, 0o644));
        if (fd < 0) return error.OpenFailed;
        _ = std.c.close(fd);
        const resolved = std.c.realpath(path, &buf) orelse return error.OpenFailed;
        return allocator.dupeSentinel(u8, std.mem.sliceTo(resolved, 0), 0);
    }
    const slice = std.mem.sliceTo(path, 0);
    const dir_z = try allocator.dupeSentinel(u8, std.Io.Dir.path.dirname(slice) orelse ".", 0);
    defer allocator.free(dir_z);
    const dir = std.c.realpath(dir_z.ptr, &buf) orelse return error.OpenFailed;
    return std.Io.Dir.path.joinZ(allocator, &.{ std.mem.sliceTo(dir, 0), std.Io.Dir.path.basename(slice) });
}

// =============================================================================
// Connection (DB.md §3)
// =============================================================================

pub const Connection = struct {
    /// What the connection is allocated on; it outlives the connection.
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,

    /// Held from `open()` to `close()`; shared with every other
    /// connection and Nextomic store of the file.
    file: *StoreFile,

    /// u128 store_id, split into two u64s for extern-struct-
    /// friendly storage. Derived per DB.md §2.
    store_id_lo: u64,
    store_id_hi: u64,

    /// Whether this connection holds its file: true from `open` to
    /// `close` (the file's environment may stay open for others). A
    /// second close does nothing; any other use is
    /// `ConnectionUnavailable`.
    open_flag: bool,

    /// Transactions begun and not yet committed or aborted. `close`
    /// ends the language's (`Handle`) and refuses while any other
    /// transaction is open, so none outlives its env.
    open_txns: u32 = 0,

    /// Named-tree handles this connection has resolved, keyed by
    /// owned copies of the tree names. A `TreeId` is fixed for the
    /// life of the environment (emdb INV-SUB03): the same name
    /// yields the same handle in every transaction. Each
    /// transaction still loads the tree behind a handle once
    /// before using it; `WriteTxn.opened` / `ReadTxn.opened`
    /// track that.
    tree_ids: std.StringHashMapUnmanaged(emdb.TreeId),

    /// How this connection's commits sync; `open` sets the process's
    /// (`Durability.process`).
    durability: Durability,

    /// Set by the collector's mark phase when it reaches a Value of the
    /// connection, and by the sweep for a durable ref or a handle that
    /// names it; cleared by the sweep.
    reached: bool = false,
    next: ?*Connection,

    /// Every connection of the process, as `Handle.all`.
    var all: ?*Connection = null;

    pub fn storeId(self: *const Connection) u128 {
        return (@as(u128, self.store_id_hi) << 64) | @as(u128, self.store_id_lo);
    }
};

/// Page size every nexis store is created with. emdb's default is
/// the OS page size, which differs between platforms; the page
/// size fixes the key bound (`Env.maxKeySize`) and the overflow
/// threshold for the life of the file, so a store must carry the
/// same geometry wherever it is created. An existing file keeps
/// the page size it was created with (emdb reads it from the meta
/// page).
pub const page_size: u32 = 16384;

/// Named-tree capacity every nexis store is opened with. Bounds
/// the `TreeId` range, which sizes the per-transaction tree set.
pub const max_named_trees: u32 = 128;

/// The size a new store file starts at, and the step emdb extends a
/// full one by (DB.md §2, NEXTOMIC.md §2): emdb reserves the address
/// space up front, so an extension moves nothing and costs one
/// `ftruncate`; a small store stays small and a large one carries at
/// most one step of unused file.
pub const initial_map_size: u64 = 1 << 20;
pub const map_grow_step: u64 = 8 << 20;

/// Reader slots in a store's lock file, 64 bytes each: how many read
/// transactions every process sharing the file can hold at once. A
/// table in use keeps the size its first opener gave it until every
/// process has closed it (emdb INV-T14E).
pub const reader_slots: u32 = 4096;

/// How a commit reaches the disk (DB.md §3.3). Every commit is atomic
/// and seen at once by every connection and process sharing the file.
pub const Durability = enum {
    /// A commit syncs nothing; the file is synced when its connection
    /// closes, at `db/sync` and `nextomic/sync`, and when the process
    /// ends. What a crash of the system can lose is DB.md §3.3's.
    commit,
    /// Every commit syncs data and meta: it is on the disk when it
    /// returns. The default.
    durable,

    pub fn parse(text: []const u8) ?Durability {
        return std.meta.stringToEnum(Durability, text);
    }

    /// The process's: the durability `NEXIS_DURABILITY` names,
    /// `durable` when it is unset. `bin/nexis` refuses any other value
    /// at start, so an unknown one reaches here only from an embedding,
    /// and reads as unset.
    pub fn process() Durability {
        return parse(std.mem.span(std.c.getenv("NEXIS_DURABILITY") orelse return .durable)) orelse .durable;
    }

    pub fn syncOverride(self: Durability) emdb.SyncOverride {
        return switch (self) {
            .commit => .none,
            .durable => .full,
        };
    }
};

/// Open (or create) the store at `path` (DB.md §3); a file already
/// open in this process is shared as it is (`StoreFile`). The
/// connection lives on `allocator`, which with `heap` and `interner`
/// outlives it, until the first collection on `heap` that finds it
/// closed and unreached (`sweepHandles`) or `shutdown`.
pub fn open(allocator: std.mem.Allocator, heap: *Heap, interner: *Interner, path: [*:0]const u8) !*Connection {
    const file = try StoreFile.acquire(path, allocator);
    errdefer file.release();
    const self = try allocator.create(Connection);

    // store_id = two xxHash3-64 halves over the canonical path, the
    // second salted so the halves are independent.
    const hash_lo = hash_mod.hashBytes(file.path);
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    hasher.update("store-id");
    hasher.update(file.path);
    const hash_hi = hasher.final();

    self.* = .{
        .allocator = allocator,
        .heap = heap,
        .interner = interner,
        .file = file,
        .store_id_lo = hash_lo,
        .store_id_hi = hash_hi,
        .open_flag = true,
        .tree_ids = .empty,
        .durability = Durability.process(),
        .next = Connection.all,
    };
    Connection.all = self;
    // Neither the struct nor the file's environment is on the heap, so
    // a loop of opens and closes would never bring the collection that
    // frees them: each open counts as a page of heap allocation.
    heap.allocated_since_collect += page_size;
    return self;
}

/// Close the connection, aborting every transaction the language
/// holds on it (DB.md §3), and sync the file when a commit left it
/// unsynced and no sync of it has failed (`StoreFile.closingSync`). A
/// closed connection stays a valid struct while anything names it:
/// refs and handles that do read `open_flag` and report it closed. A second close does
/// nothing. A close while a native holds one of the connection's
/// transactions for a callback, or while a Zig-level transaction is
/// open, is refused, so no emdb transaction outlives its env. A sync
/// that fails here is returned once the connection is closed.
pub fn close(self: *Connection) (DbError || emdb.Error)!void {
    if (!self.open_flag) return;
    // Refused before anything ends: a refusal changes nothing.
    var language: u32 = 0;
    var it = Handle.all;
    while (it) |h| : (it = h.next) {
        if (h.conn() != self) continue;
        if (h.held != 0) return DbError.TransactionsOpen;
        language += @intFromBool(h.active);
    }
    if (self.open_txns != language) return DbError.TransactionsOpen;
    it = Handle.all;
    while (it) |h| : (it = h.next) {
        if (h.conn() == self) h.end();
    }
    const synced = self.file.closingSync();
    release(self);
    return synced;
}

/// Make every commit to the connection's file durable (`db/sync`).
pub fn sync(self: *Connection) !void {
    if (!self.open_flag) return DbError.ConnectionUnavailable;
    try self.file.sync();
}

/// Teardown, when nothing can use the connection again: end and free
/// its handles, close it whatever is open, and free it.
pub fn shutdown(self: *Connection) void {
    var link = &Connection.all;
    while (link.*) |c| : (link = &c.next) {
        if (c == self) {
            link.* = self.next;
            break;
        }
    }
    destroy(self);
}

/// `shutdown` of every connection on `heap`: the VM's teardown and
/// `exit`.
pub fn shutdownHeap(heap: *Heap) void {
    var link = &Connection.all;
    while (link.*) |c| {
        if (c.heap != heap) {
            link = &c.next;
            continue;
        }
        link.* = c.next;
        destroy(c);
    }
}

/// `shutdown` of a connection already off `Connection.all`.
fn destroy(self: *Connection) void {
    var link = &Handle.all;
    while (link.*) |h| {
        if (h.conn() != self) {
            link = &h.next;
            continue;
        }
        h.end();
        link.* = h.next;
        self.allocator.destroy(h);
    }
    release(self);
    self.allocator.destroy(self);
}

fn release(self: *Connection) void {
    if (!self.open_flag) return;
    self.file.release();
    var names = self.tree_ids.keyIterator();
    while (names.next()) |name| self.allocator.free(name.*);
    self.tree_ids.deinit(self.allocator);
    self.open_flag = false;
}

// =============================================================================
// Transactions (DB.md §5)
// =============================================================================

/// One bit per `TreeId` slot: the two core trees plus every named
/// tree the pinned capacity admits.
pub const TreeSet = std.bit_set.Static(emdb.txn.coreTreeCount + max_named_trees);

pub const WriteTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
    /// Trees this transaction has loaded; see `treeId`.
    opened: TreeSet = .empty,
    /// Walks in progress over this transaction's trees; a write
    /// through the transaction copies what each has yet to visit first.
    walks: ?*Walk = null,
};

pub const ReadTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
    /// Trees this transaction has loaded; see `treeId`.
    opened: TreeSet = .empty,
};

pub fn beginWrite(conn: *Connection) !WriteTxn {
    if (!conn.open_flag) return DbError.ConnectionUnavailable;
    const txn = try conn.file.beginWrite(.{ .sync = conn.durability.syncOverride() });
    conn.open_txns += 1;
    return .{ .conn = conn, .inner = txn };
}

pub fn beginRead(conn: *Connection) !ReadTxn {
    if (!conn.open_flag) return DbError.ConnectionUnavailable;
    const txn = try conn.file.env.beginRead();
    conn.open_txns += 1;
    return .{ .conn = conn, .inner = txn };
}

/// Commit, or on failure abort: either way the transaction is over.
/// emdb leaves a transaction whose commit failed open, holding the
/// write lock, until it is aborted.
pub fn commit(txn: *WriteTxn) !void {
    txn.conn.open_txns -= 1;
    txn.conn.file.commit(txn.inner) catch |err| {
        txn.inner.abort();
        return err;
    };
}

pub fn abortWrite(txn: *WriteTxn) void {
    txn.conn.open_txns -= 1;
    txn.inner.abort();
}

pub fn abortRead(txn: *ReadTxn) void {
    txn.conn.open_txns -= 1;
    txn.inner.abort();
}

// =============================================================================
// Transaction handles (DB.md §12)
// =============================================================================

/// A transaction as the language holds it: the payload of a
/// `db_write_txn` or `db_read_txn` Value, allocated on the
/// connection's allocator. It ends by commit or abort, by `close` of
/// its connection, or by a collection that finds no Value of it
/// (`markHandle`, `sweepHandles`). The struct outlives its
/// transaction while a Value names it, which then reports the
/// transaction closed, and is freed by the first collection after
/// it becomes unreachable, or at VM teardown (`shutdown`).
pub const Handle = struct {
    txn: union(enum) { write: WriteTxn, read: ReadTxn },
    /// Neither committed nor aborted yet.
    active: bool = true,
    /// Natives running a callback over the transaction: commit, abort
    /// and `close` refuse while any does, so no callback finishes a
    /// transaction a native is still using.
    held: u32 = 0,
    /// Set by the collector's mark phase when it reaches a Value of
    /// the handle; cleared by the sweep.
    reached: bool = false,
    next: ?*Handle,

    /// Every handle of the process. The runtime is single-threaded,
    /// as `StoreFile.open_files` is.
    var all: ?*Handle = null;

    /// A handle over `txn`, just begun; on failure `txn` is aborted.
    pub fn create(txn: @FieldType(Handle, "txn")) !*Handle {
        var t = txn;
        const self = switch (t) {
            inline else => |*x| x.conn.allocator.create(Handle) catch |err| {
                x.conn.open_txns -= 1;
                x.inner.abort();
                return err;
            },
        };
        self.* = .{ .txn = t, .next = all };
        all = self;
        return self;
    }

    pub fn conn(self: *const Handle) *Connection {
        return switch (self.txn) {
            inline else => |x| x.conn,
        };
    }

    /// Abort the transaction if it is still open.
    pub fn end(self: *Handle) void {
        if (!self.active) return;
        switch (self.txn) {
            .write => |*w| abortWrite(w),
            .read => |*r| abortRead(r),
        }
        self.active = false;
    }
};

/// The handle behind a `db_write_txn` or `db_read_txn` Value.
pub fn handleOf(v: Value) *Handle {
    std.debug.assert(v.kind() == .db_write_txn or v.kind() == .db_read_txn);
    return @ptrFromInt(v.payload);
}

/// The collector reached `v`, a Value of no heap block (GC.md §5): a
/// transaction handle or a connection is flagged for the sweep.
pub fn mark(v: Value) void {
    switch (v.kind()) {
        .db_write_txn, .db_read_txn => handleOf(v).reached = true,
        .db_connection => @as(*Connection, @ptrFromInt(v.payload)).reached = true,
        else => {},
    }
}

/// After a mark phase over `heap`: end and free every handle of a
/// connection on `heap` that no Value reached, unless a native holds
/// it; free every closed connection on `heap` that no Value, marked
/// durable ref or remaining handle names; and let every held snapshot
/// go (DB.md §3.2, §3.4). `complete` is false when the marks are
/// incomplete, which only clears them. Nothing here allocates on the
/// heap.
pub fn sweepHandles(heap: *Heap, complete: bool) void {
    StoreFile.dropAllHeld();
    var link = &Handle.all;
    while (link.*) |h| {
        const c = h.conn();
        if (c.heap != heap or !complete or h.reached or h.held != 0) {
            if (c.heap == heap) {
                h.reached = false;
                c.reached = true;
            }
            link = &h.next;
            continue;
        }
        h.end();
        link.* = h.next;
        c.allocator.destroy(h);
    }
    if (complete and unreachedClosed(heap)) {
        // A durable ref is a leaf the collector does not trace, so the
        // marked ones are looked through for the connections they name.
        const Refs = struct {
            pub fn visit(_: @This(), b: *HeapHeader) void {
                if (b.kind != @backingInt(Kind.durable_ref) or !b.isMarked()) return;
                if (bodyOf(b).conn) |c| c.reached = true;
            }
        };
        heap.forEachLive(Refs{});
    }
    var conns = &Connection.all;
    while (conns.*) |c| {
        if (c.heap == heap and complete and !c.open_flag and !c.reached) {
            conns.* = c.next;
            c.allocator.destroy(c);
            continue;
        }
        if (c.heap == heap) c.reached = false;
        conns = &c.next;
    }
}

/// Whether a closed connection on `heap` is so far unreached.
fn unreachedClosed(heap: *Heap) bool {
    var it = Connection.all;
    while (it) |c| : (it = c.next) {
        if (c.heap == heap and !c.open_flag and !c.reached) return true;
    }
    return false;
}

/// Whether a handle a collection on `conn`'s heap could end holds a
/// transaction on `conn`'s file: the one retry a busy writer or a
/// full reader table earns (DB.md §12).
pub fn collectableHandles(conn: *const Connection) bool {
    var it = Handle.all;
    while (it) |h| : (it = h.next) {
        const c = h.conn();
        if (h.active and h.held == 0 and c.heap == conn.heap and c.file == conn.file) return true;
    }
    return false;
}

/// Connections alive in the process, closed or not.
pub fn connectionCount() usize {
    var n: usize = 0;
    var it = Connection.all;
    while (it) |c| : (it = c.next) n += 1;
    return n;
}

/// Handles alive in the process, ended or not.
pub fn handleCount() usize {
    var n: usize = 0;
    var it = Handle.all;
    while (it) |h| : (it = h.next) n += 1;
    return n;
}

// =============================================================================
// Tree walks (DB.md §12)
// =============================================================================

/// A walk over one named tree of a transaction in key order: `db/scan`
/// and `db/reduce-tree`. emdb lets a read cursor in a write transaction
/// step on only while nothing changes the transaction (API-C06A), so
/// any write through the transaction first copies the entries every
/// walk on it has yet to visit (`WriteTxn.walks`): the walk sees the
/// tree as it was when it began, whatever its callback writes, and a
/// walk no callback writes under copies nothing. The cursor reads keys
/// only, and each value is copied into one buffer of the walk, so a
/// walk holds only the largest value and never the transaction's copy
/// of every one (emdb API-C09). A page or a value that cannot be read
/// ends the walk with its error, never as a shorter walk (API-C08). A
/// walk lives on its caller's stack between `begin` and `end`.
pub const Walk = struct {
    cursor: emdb.Cursor,
    allocator: std.mem.Allocator,
    /// The value of the entry last returned.
    value: std.ArrayList(u8) = .empty,
    /// The write transaction the walk is registered on.
    owner: ?*WriteTxn,
    next_walk: ?*Walk = null,
    /// `first` has positioned the cursor.
    started: bool = false,
    /// The entries still to visit once the transaction was written: key
    /// and value bytes back to back, and where each key and value ends.
    rest: ?struct {
        bytes: std.ArrayList(u8) = .empty,
        ends: std.ArrayList([2]usize) = .empty,
        at: usize = 0,
    } = null,

    pub const Entry = emdb.Cursor.KeyValue;

    /// Start a walk over `tree_name` in `txn` (a `*WriteTxn` or
    /// `*ReadTxn`); false when the tree does not exist, and then no
    /// `end` is due. `first` positions it.
    pub fn begin(self: *Walk, txn: anytype, tree_name: []const u8) !bool {
        try validateTreeName(tree_name);
        const id = (try treeId(txn, tree_name, false)) orelse return false;
        self.* = .{
            .cursor = try txn.inner.openCursorForTree(id),
            .allocator = txn.conn.allocator,
            .owner = null,
        };
        self.cursor.keysOnly = true;
        if (@TypeOf(txn) == *WriteTxn) {
            self.owner = txn;
            self.next_walk = txn.walks;
            txn.walks = self;
        }
        return true;
    }

    pub fn end(self: *Walk) void {
        if (self.owner) |w| {
            var link = &w.walks;
            while (link.*) |x| : (link = &x.next_walk) {
                if (x == self) {
                    link.* = self.next_walk;
                    break;
                }
            }
        }
        self.value.deinit(self.allocator);
        if (self.rest) |*r| {
            r.bytes.deinit(self.allocator);
            r.ends.deinit(self.allocator);
        }
    }

    /// The first entry, or the first at or after `start`; null when
    /// there is none. Called once, before `next` and before any write
    /// through the transaction.
    pub fn first(self: *Walk, start: ?[]const u8) !?Entry {
        self.started = true;
        const kv = (if (start) |s| self.cursor.setRange(s) else self.cursor.first()) orelse return self.stopped();
        return try self.entry(kv);
    }

    /// The next entry; null at the end.
    pub fn next(self: *Walk) !?Entry {
        const r = if (self.rest) |*r| r else return self.step();
        if (r.at == r.ends.items.len) return null;
        const from = if (r.at == 0) 0 else r.ends.items[r.at - 1][1];
        const e = r.ends.items[r.at];
        r.at += 1;
        return .{ .key = r.bytes.items[from..e[0]], .value = r.bytes.items[e[0]..e[1]] };
    }

    fn step(self: *Walk) !?Entry {
        const kv = self.cursor.next() orelse return self.stopped();
        return try self.entry(kv);
    }

    /// Null at the real end; the cursor's error when a page or a value
    /// stopped it short.
    fn stopped(self: *Walk) !?Entry {
        if (self.cursor.failure) |err| return err;
        return null;
    }

    /// `kv` with its whole value. A key-only cursor leaves a value on
    /// overflow pages empty; no stored value is empty, as the codec
    /// writes at least its version byte, and one read again is the same.
    fn entry(self: *Walk, kv: Entry) !Entry {
        if (kv.value.len > 0) return kv;
        const v = (try self.cursor.readValueInto(self.allocator, &self.value)) orelse return error.InvalidPage;
        return .{ .key = kv.key, .value = v };
    }

    /// Copy what the cursor has yet to visit, before the transaction
    /// changes under it.
    fn copyRest(self: *Walk) !void {
        // Unpositioned, the cursor would read as at its end.
        std.debug.assert(self.started);
        var r: @typeInfo(@FieldType(Walk, "rest")).optional.child = .{};
        errdefer {
            r.bytes.deinit(self.allocator);
            r.ends.deinit(self.allocator);
        }
        while (try self.step()) |kv| {
            try r.bytes.appendSlice(self.allocator, kv.key);
            const key_end = r.bytes.items.len;
            try r.bytes.appendSlice(self.allocator, kv.value);
            try r.ends.append(self.allocator, .{ key_end, r.bytes.items.len });
        }
        self.rest = r;
    }
};

/// Before `txn` writes: every walk on it copies what it has yet to
/// visit.
fn beforeWrite(txn: *WriteTxn) !void {
    var it = txn.walks;
    while (it) |w| : (it = w.next_walk) {
        if (w.rest == null) try w.copyRest();
    }
}

// =============================================================================
// Tree-name + key-bytes API (opaque keys; DB.md §5, §6)
// =============================================================================

/// A tree `db/*` may name: not empty, and not under `nx/`, where
/// Nextomic keeps its indexes (DB.md §6); a write there would bypass
/// every Nextomic invariant.
pub fn validateTreeName(tree_name: []const u8) DbError!void {
    if (tree_name.len == 0 or std.mem.startsWith(u8, tree_name, "nx/")) return DbError.InvalidTreeName;
}

fn validateTreeNameAndKey(tree_name: []const u8, key_bytes: []const u8) DbError!void {
    try validateTreeName(tree_name);
    if (key_bytes.len == 0) return DbError.InvalidKey;
}

/// Resolve `tree_name` to the handle this transaction can use.
/// Accepts `*WriteTxn` or `*ReadTxn`.
///
/// The connection remembers every handle it has resolved, and a
/// transaction loads the tree behind a handle the first time it
/// touches it (emdb keeps per-transaction tree state, so a handle
/// alone is not enough). Within one transaction every further
/// operation on the tree is a bit test.
///
/// Returns null when the tree does not exist and `create` is
/// false. A tree registered by an aborted transaction stays
/// registered with the environment and reads as empty, which is
/// emdb's own behavior for the name.
pub fn treeId(txn: anytype, tree_name: []const u8, create: bool) !?emdb.TreeId {
    const conn = txn.conn;
    const cached = conn.tree_ids.get(tree_name);
    if (cached) |id| if (txn.opened.isSet(id)) return id;
    const id = txn.inner.openTree(tree_name, create) catch |err| switch (err) {
        error.NotFound => return null,
        else => return err,
    };
    std.debug.assert(id < TreeSet.bit_length);
    if (cached) |known| {
        std.debug.assert(known == id);
    } else {
        const owned_name = try conn.allocator.dupe(u8, tree_name);
        errdefer conn.allocator.free(owned_name);
        try conn.tree_ids.put(conn.allocator, owned_name, id);
    }
    txn.opened.set(id);
    return id;
}

pub fn put(
    txn: *WriteTxn,
    tree_name: []const u8,
    key_bytes: []const u8,
    v: Value,
) !void {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const encoded = try codec_mod.encode(txn.conn.allocator, txn.conn.interner, v);
    defer txn.conn.allocator.free(encoded);
    // Creating the tree changes the transaction too.
    try beforeWrite(txn);
    const tree_id = (try treeId(txn, tree_name, true)).?;
    try txn.inner.putInTree(tree_id, key_bytes, encoded);
}

/// The value under `(tree_name, key_bytes)` in either transaction
/// kind, decoded with the hash and equality `elementHash` and
/// `elementEq`, which must agree with dispatch's (DB.md §5).
pub fn get(
    txn: anytype,
    tree_name: []const u8,
    key_bytes: []const u8,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !?Value {
    try validateTreeNameAndKey(tree_name, key_bytes);
    // No such tree → key is absent.
    const tree_id = (try treeId(txn, tree_name, false)) orelse return null;
    const bytes_opt = try txn.inner.getFromTree(tree_id, key_bytes);
    if (bytes_opt) |bytes| {
        return try codec_mod.decode(
            txn.conn.heap,
            txn.conn.interner,
            bytes,
            elementHash,
            elementEq,
        );
    }
    return null;
}

/// Whether `key_bytes` is in `tree_name`, through either transaction
/// kind; the value is neither read nor decoded.
pub fn has(txn: anytype, tree_name: []const u8, key_bytes: []const u8) !bool {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const tree_id = (try treeId(txn, tree_name, false)) orelse return false;
    var cursor = try txn.inner.openCursorForTree(tree_id);
    cursor.keysOnly = true;
    if (cursor.set(key_bytes) != null) return true;
    if (cursor.failure) |err| return err;
    return false;
}

pub fn del(
    txn: *WriteTxn,
    tree_name: []const u8,
    key_bytes: []const u8,
) !bool {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const tree_id = (try treeId(txn, tree_name, false)) orelse return false;
    try beforeWrite(txn);
    return try txn.inner.delFromTree(tree_id, key_bytes);
}

// =============================================================================
// `durable_ref` heap kind (DB.md §4)
// =============================================================================

const DurableRefBody = extern struct {
    conn: ?*Connection,
    store_id_lo: u64,
    store_id_hi: u64,
    tree_name_len: u32,
    key_bytes_len: u32,
    // Followed by: tree_name bytes (tree_name_len), then key_bytes
    // (key_bytes_len).

    comptime {
        std.debug.assert(@sizeOf(DurableRefBody) == 32);
    }
};

/// A durable ref on `conn`: the identity triple from `conn`'s store,
/// and `conn` as its advisory connection.
pub fn ref(
    heap: *Heap,
    conn: *Connection,
    tree_name: []const u8,
    key_bytes: []const u8,
) !Value {
    const r = try refFromBytes(heap, conn.storeId(), tree_name, key_bytes);
    bodyOf(refHeader(r)).conn = conn;
    return r;
}

/// A durable ref with no connection: I/O through it is
/// `error.ConnectionUnavailable` (DB.md §4).
pub fn refFromBytes(
    heap: *Heap,
    store_id: u128,
    tree_name: []const u8,
    key_bytes: []const u8,
) !Value {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const body_size = @sizeOf(DurableRefBody) + tree_name.len + key_bytes.len;
    const h = try heap.alloc(.durable_ref, body_size);
    const body = bodyOf(h);
    body.conn = null;
    body.store_id_lo = @truncate(store_id);
    body.store_id_hi = @truncate(store_id >> 64);
    body.tree_name_len = @intCast(tree_name.len);
    body.key_bytes_len = @intCast(key_bytes.len);
    const inline_bytes = inlineBytesOf(h);
    @memcpy(inline_bytes[0..tree_name.len], tree_name);
    @memcpy(inline_bytes[tree_name.len..][0..key_bytes.len], key_bytes);
    return heap_mod.Heap.valueFromHeader(.durable_ref, h);
}

fn bodyOf(h: *HeapHeader) *DurableRefBody {
    const body = heap_mod.Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(DurableRefBody));
    return @ptrCast(@alignCast(body.ptr));
}

fn inlineBytesOf(h: *HeapHeader) []u8 {
    const body = heap_mod.Heap.bodyBytes(h);
    std.debug.assert(body.len >= @sizeOf(DurableRefBody));
    return body[@sizeOf(DurableRefBody)..];
}

fn refHeader(v: Value) *HeapHeader {
    std.debug.assert(v.kind() == .durable_ref);
    return heap_mod.Heap.asHeapHeader(v);
}

// --- Identity accessors (for codec + eq/hash + ref-based ops) ---

pub fn refStoreId(r: Value) u128 {
    const body = bodyOf(refHeader(r));
    return (@as(u128, body.store_id_hi) << 64) | @as(u128, body.store_id_lo);
}

pub fn refTreeName(r: Value) []const u8 {
    const h = refHeader(r);
    const body = bodyOf(h);
    const inline_bytes = inlineBytesOf(h);
    return inline_bytes[0..body.tree_name_len];
}

pub fn refKeyBytes(r: Value) []const u8 {
    const h = refHeader(r);
    const body = bodyOf(h);
    const inline_bytes = inlineBytesOf(h);
    return inline_bytes[body.tree_name_len..][0..body.key_bytes_len];
}

pub fn refConn(r: Value) ?*Connection {
    const body = bodyOf(refHeader(r));
    return body.conn;
}

// =============================================================================
// Ref-based I/O (DB.md §5 / §8 failure semantics)
// =============================================================================

/// A ref is used only through a connection to its own store:
/// store_id is the identity, so a ref made on another connection to
/// the same file is accepted and one naming another store is not.
fn assertRefMatchesConn(r: Value, conn: *Connection) DbError!void {
    _ = refConn(r) orelse return DbError.ConnectionUnavailable;
    if (refStoreId(r) != conn.storeId()) return DbError.StoreMismatch;
}

pub fn putRef(txn: *WriteTxn, r: Value, v: Value) !void {
    try assertRefMatchesConn(r, txn.conn);
    return put(txn, refTreeName(r), refKeyBytes(r), v);
}

pub fn getRef(
    txn: anytype,
    r: Value,
    elementHash: *const fn (Value) u64,
    elementEq: *const fn (Value, Value) bool,
) !?Value {
    try assertRefMatchesConn(r, txn.conn);
    return get(txn, refTreeName(r), refKeyBytes(r), elementHash, elementEq);
}

pub fn delRef(txn: *WriteTxn, r: Value) !bool {
    try assertRefMatchesConn(r, txn.conn);
    return del(txn, refTreeName(r), refKeyBytes(r));
}

// =============================================================================
// Per-kind hash / equality (DB.md §7)
// =============================================================================

/// Identity-triple hash: the store id's two halves, then xxHash3 over
/// the tree name and key bytes, through the ordered combine. `conn` NOT
/// consulted. Kind-local hash domain applied by `dispatch.hashValue`
/// on the way out.
pub fn hashHeader(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    const body = bodyOf(h);
    const names = inlineBytesOf(h)[0 .. body.tree_name_len + body.key_bytes_len];
    const ids = hash_mod.combineOrdered(body.store_id_lo, body.store_id_hi);
    const truncated: u32 = @truncate(hash_mod.combineOrdered(ids, hash_mod.hashBytes(names)));
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// Identity-triple equality: byte-for-byte on (store_id,
/// tree_name, key_bytes). `conn` NOT consulted.
pub fn refsEqual(a: *HeapHeader, b: *HeapHeader) bool {
    if (a == b) return true;
    const ab = bodyOf(a);
    const bb = bodyOf(b);
    if (ab.store_id_lo != bb.store_id_lo) return false;
    if (ab.store_id_hi != bb.store_id_hi) return false;
    if (ab.tree_name_len != bb.tree_name_len) return false;
    if (ab.key_bytes_len != bb.key_bytes_len) return false;
    const a_bytes = inlineBytesOf(a);
    const b_bytes = inlineBytesOf(b);
    const total_len = ab.tree_name_len + ab.key_bytes_len;
    return std.mem.eql(u8, a_bytes[0..total_len], b_bytes[0..total_len]);
}

// =============================================================================
// Inline tests
// =============================================================================

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
        shutdownHeap(&f.heap);
        f.interner.deinit();
        f.heap.deinit();
        cleanupDb(f.path);
        testing.allocator.free(f.path);
    }

    fn connect(f: *Fixture) !*Connection {
        return f.connectAt(f.path);
    }

    fn connectAt(f: *Fixture, path: [*:0]const u8) !*Connection {
        return open(testing.allocator, &f.heap, &f.interner, path);
    }
};

const synthHash = Value.hashImmediate;
const synthEq = value.testEqual;

test "failureName: every emdb error nexis can meet has its keyword; every decode error is :codec-failed" {
    // The engine's errors no nexis call can return: options nexis pins
    // or never sets, operations it never calls (prepare, child
    // transactions, backup, restore, dump, rollback), and misuse its
    // callers rule out.
    const unreached = [_][]const u8{
        "InvalidPageSize",   "MapSizeTooLarge",    "PageSizeMismatch", "TxnPrepared",
        "TxnNotPreparable",  "TxnHasChild",        "Incompatible",     "InvalidCursor",
        "BackupFormat",      "BackupBaseMismatch", "DumpFormat",       "NoPreviousSnapshot",
        "TooManyNamedTrees",
    };
    inline for (@typeInfo(emdb.Error).error_set.error_names.?) |name| {
        const named = !std.mem.eql(u8, failureName(@field(emdb.Error, name)), "db-error");
        const listed = for (unreached) |u| {
            if (std.mem.eql(u8, u, name)) break true;
        } else false;
        if (named == listed) {
            std.debug.print("emdb error {s}: keyword {s}\n", .{ name, failureName(@field(emdb.Error, name)) });
            return error.TestUnexpectedResult;
        }
    }
    inline for (@typeInfo(codec_mod.DecodeError).error_set.error_names.?) |name| {
        const expected = if (std.mem.eql(u8, name, "OutOfMemory") or std.mem.eql(u8, name, "InternTableFull"))
            "db-error"
        else if (std.mem.eql(u8, name, "UnserializableKind")) "unserializable" else "codec-failed";
        try testing.expectEqualStrings(expected, failureName(@field(codec_mod.DecodeError, name)));
    }
}

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
    try close(a);
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

    var w = try beginWrite(a);
    try testing.expectError(error.WriterActive, beginWrite(same));
    try testing.expectError(error.WriterActive, beginWrite(c));
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);

    // The file stays open while any connection holds it.
    try close(a);
    try close(same);
    var r = try beginRead(c);
    const got = try get(&r, "t", "k", synthHash, synthEq);
    abortRead(&r);
    try testing.expectEqual(@as(i64, 1), got.?.asFixnum());
    var w2 = try beginWrite(b);
    try commit(&w2);
}

test "open: a copy of a store is another file, written beside the original" {
    var fx = try Fixture.init("original");
    defer fx.deinit();

    const a = try fx.connect();
    var w = try beginWrite(a);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    const copy = try testing.allocator.printSentinel("{s}/copy.emdb", .{std.Io.Dir.path.dirname(fx.path).?}, 0);
    defer testing.allocator.free(copy);
    try std.Io.Dir.cwd().copyFile(fx.path, std.Io.Dir.cwd(), copy, testing.io, .{});

    const b = try fx.connectAt(copy.ptr);
    try testing.expect(a.file != b.file);
    try testing.expect(a.storeId() != b.storeId());
    var wa = try beginWrite(a);
    var wb = try beginWrite(b);
    try put(&wa, "t", "k", value.fromFixnum(2).?);
    try put(&wb, "t", "k", value.fromFixnum(3).?);
    try commit(&wa);
    try commit(&wb);
    var ra = try beginRead(a);
    defer abortRead(&ra);
    var rb = try beginRead(b);
    defer abortRead(&rb);
    try testing.expectEqual(@as(i64, 2), (try get(&ra, "t", "k", synthHash, synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 3), (try get(&rb, "t", "k", synthHash, synthEq)).?.asFixnum());
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
    try close(a);
    try testing.expectError(error.HardLinked, fx.connectAt(other.ptr));
    try testing.expectError(error.HardLinked, fx.connect());
    try testing.expectEqualStrings("db/hard-linked", failureName(error.HardLinked));
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
    var w = try beginWrite(a);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    try close(a);
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
        defer shutdown(a);
        var w = try beginWrite(a);
        try put(&w, "t", "k", value.fromFixnum(7).?);
        try commit(&w);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(fx.path.ptr, 0o444));
    defer _ = std.c.chmod(fx.path.ptr, 0o644);
    const conn = try fx.connect();
    var r = try beginRead(conn);
    defer abortRead(&r);
    try testing.expectEqual(@as(i64, 7), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    try testing.expectError(error.TxnReadOnly, beginWrite(conn));
}

test "close: a refusal ends none of the language's transactions" {
    var fx = try Fixture.init("close_refused");
    defer fx.deinit();

    const conn = try fx.connect();
    const h = try Handle.create(.{ .read = try beginRead(conn) });
    var zig_level = try beginRead(conn);
    try testing.expectError(DbError.TransactionsOpen, close(conn));
    try testing.expect(h.active);
    abortRead(&zig_level);
    try close(conn);
    try testing.expect(!h.active);
}

test "sweepHandles: a closed connection is freed once no Value, marked durable ref or handle names it" {
    var fx = try Fixture.init("swept");
    defer fx.deinit();
    const base = connectionCount();
    _ = try fx.connect();
    const named = try fx.connect();
    const reffed = try fx.connect();
    const handled = try fx.connect();
    const dropped = try fx.connect();
    const r = try ref(&fx.heap, reffed, "t", "k");
    const h = try Handle.create(.{ .read = try beginRead(handled) });
    for ([_]*Connection{ named, reffed, handled, dropped }) |c| try close(c);
    try testing.expectEqual(base + 5, connectionCount());
    // Marks that may be incomplete free nothing.
    sweepHandles(&fx.heap, false);
    try testing.expectEqual(base + 5, connectionCount());
    mark(.{ .tag = @backingInt(Kind.db_connection), .payload = @intFromPtr(named) });
    mark(.{ .tag = @backingInt(Kind.db_read_txn), .payload = @intFromPtr(h) });
    Heap.asHeapHeader(r).setMarked();
    sweepHandles(&fx.heap, true);
    try testing.expectEqual(base + 4, connectionCount());
    // Nothing reached: the handle goes, then every closed connection.
    Heap.asHeapHeader(r).clearMarked();
    sweepHandles(&fx.heap, true);
    try testing.expectEqual(base + 1, connectionCount());
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
    var r = try beginRead(conn);
    defer abortRead(&r);
    try testing.expect(try has(&r, "t", "k"));
    try testing.expect(!try has(&r, "t", "j"));
    try testing.expect(!try has(&r, "none", "k"));
    if (get(&r, "t", "k", synthHash, synthEq)) |_| return error.TestUnexpectedResult else |_| {}
}

test "close: refused while a transaction is open; the connection stays a closed struct" {
    var fx = try Fixture.init("close_busy");
    defer fx.deinit();

    const conn = try fx.connect();
    var rtxn = try beginRead(conn);
    try testing.expectError(DbError.TransactionsOpen, close(conn));
    abortRead(&rtxn);
    try close(conn);
    try close(conn);
    try testing.expect(!conn.open_flag);
    try testing.expectError(DbError.ConnectionUnavailable, beginRead(conn));
}

/// Syncs the engine has issued in this process (data and meta alike),
/// for the tests of durability.
pub fn engineSyncs() u64 {
    return emdb.platform.File.syncCalls.load(.monotonic);
}

test "Durability: parses its two names and nothing else" {
    try testing.expectEqual(Durability.commit, Durability.parse("commit").?);
    try testing.expectEqual(Durability.durable, Durability.parse("durable").?);
    for ([_][]const u8{ "", "batch", "batched", "Durable", "commit " }) |text| {
        try testing.expect(Durability.parse(text) == null);
    }
}

test "durability commit: a commit is seen at once and syncs nothing; close syncs the file once" {
    var fx = try Fixture.init("commit_mode");
    defer fx.deinit();

    const a = try fx.connect();
    a.durability = .commit;
    const b = try fx.connect();

    const before = engineSyncs();
    var w = try beginWrite(a);
    try put(&w, "t", "k", value.fromFixnum(7).?);
    try commit(&w);
    try testing.expectEqual(before, engineSyncs());
    try testing.expect(a.file.unsynced);
    {
        var r = try beginRead(b);
        defer abortRead(&r);
        try testing.expectEqual(@as(i64, 7), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    }
    // An abort writes nothing, so it leaves nothing more to sync.
    var aborted = try beginWrite(a);
    abortWrite(&aborted);
    try close(a);
    try testing.expectEqual(before + 1, engineSyncs());
    try testing.expect(!b.file.unsynced);
    try close(b);
    try testing.expectEqual(before + 1, engineSyncs());
}

test "durability durable: every commit syncs, which leaves nothing for close; a read-only program never syncs" {
    var fx = try Fixture.init("durable_mode");
    defer fx.deinit();

    const conn = try fx.connect();
    conn.durability = .commit;
    var w = try beginWrite(conn);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    try testing.expect(conn.file.unsynced);
    // A durable commit makes every commit before it durable too.
    conn.durability = .durable;
    const before = engineSyncs();
    w = try beginWrite(conn);
    try put(&w, "t", "k", value.fromFixnum(2).?);
    try commit(&w);
    try testing.expect(engineSyncs() > before);
    try testing.expect(!conn.file.unsynced);
    const after_commit = engineSyncs();
    try close(conn);
    try testing.expectEqual(after_commit, engineSyncs());

    const reader = try fx.connect();
    var r = try beginRead(reader);
    try testing.expectEqual(@as(i64, 2), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    abortRead(&r);
    try close(reader);
    try testing.expectEqual(after_commit, engineSyncs());
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
    var w = try beginWrite(conn);
    try put(&w, "t", "a", value.fromFixnum(5).?);
    const committed = commit(&w);
    conn.file.env.inner.commitObserver = null;
    failure.restore();
    try testing.expectError(error.DurabilityUnknown, committed);
    try testing.expectEqualStrings("db/durability-unknown", failureName(error.DurabilityUnknown));
    try testing.expect(conn.file.unsynced);
    try testing.expect(conn.file.syncFailed());

    // Nothing syncs again: a sync fails on every connection, and a
    // commit that would sync fails before it writes anything, while one
    // that syncs nothing commits.
    const before = engineSyncs();
    try testing.expectError(error.SyncFailed, sync(conn));
    try testing.expectError(error.SyncFailed, sync(other));
    try testing.expectEqualStrings("db/sync-failed", failureName(error.SyncFailed));
    w = try beginWrite(conn);
    try put(&w, "t", "b", value.fromFixnum(6).?);
    try testing.expectError(error.SyncFailed, commit(&w));
    try testing.expectEqual(@as(u32, 0), conn.open_txns);
    w = try beginWrite(other);
    try put(&w, "t", "c", value.fromFixnum(7).?);
    try commit(&w);
    {
        var r = try beginRead(conn);
        defer abortRead(&r);
        try testing.expectEqual(@as(i64, 5), (try get(&r, "t", "a", synthHash, synthEq)).?.asFixnum());
        try testing.expect((try get(&r, "t", "b", synthHash, synthEq)) == null);
        try testing.expectEqual(@as(i64, 7), (try get(&r, "t", "c", synthHash, synthEq)).?.asFixnum());
    }

    // A close syncs nothing and raises nothing. A connection opened
    // while another holds the file shares its environment, so its
    // syncs fail too; the last close lets the environment go.
    try close(conn);
    conn = try fx.connect();
    try testing.expectError(error.SyncFailed, sync(conn));
    try close(conn);
    StoreFile.syncAll();
    try close(other);
    try testing.expectEqual(before, engineSyncs());

    // Reopened, the file syncs again and holds exactly the commits
    // that published.
    conn = try fx.connect();
    conn.durability = .durable;
    try testing.expect(!conn.file.syncFailed());
    {
        var r = try beginRead(conn);
        defer abortRead(&r);
        try testing.expectEqual(@as(i64, 5), (try get(&r, "t", "a", synthHash, synthEq)).?.asFixnum());
        try testing.expect((try get(&r, "t", "b", synthHash, synthEq)) == null);
        try testing.expectEqual(@as(i64, 7), (try get(&r, "t", "c", synthHash, synthEq)).?.asFixnum());
    }
    w = try beginWrite(conn);
    try put(&w, "t", "b", value.fromFixnum(6).?);
    try commit(&w);
    try testing.expect(engineSyncs() > before);
    try sync(conn);
    try close(conn);
}

test "syncAll: one sync for each file written without one; shutdown syncs a file it releases last" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    var paths: [3][:0]u8 = undefined;
    var conns: [3]*Connection = undefined;
    for (&paths, &conns, 0..) |*p, *c, i| {
        p.* = try tmpDbPath(testing.allocator, &.{'a' + @as(u8, @intCast(i))});
        c.* = try open(testing.allocator, &heap, &interner, p.*.ptr);
        c.*.durability = .commit;
    }
    defer for (paths) |p| {
        cleanupDb(p);
        testing.allocator.free(p);
    };
    defer for (conns[0..2]) |c| shutdown(c);
    for (conns[0..2]) |c| {
        var w = try beginWrite(c);
        try put(&w, "t", "k", value.fromFixnum(1).?);
        try commit(&w);
    }
    const before = engineSyncs();
    StoreFile.syncAll();
    try testing.expectEqual(before + 2, engineSyncs());
    StoreFile.syncAll();
    try testing.expectEqual(before + 2, engineSyncs());

    var w = try beginWrite(conns[2]);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    shutdown(conns[2]);
    try testing.expectEqual(before + 3, engineSyncs());
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
    var w = try beginWrite(conn);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    file.keep(stale);
    try testing.expect(file.held == null);

    // This process's own write lets it go before it begins.
    file.keep(try file.env.beginRead());
    try testing.expect(file.held != null);
    w = try beginWrite(conn);
    try testing.expect(file.held == null);
    abortWrite(&w);

    // So does a collection's sweep.
    file.keep(try file.env.beginRead());
    sweepHandles(&fx.heap, true);
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
        var w = beginWrite(conn) catch std.c._exit(2);
        put(&w, "t", "k", value.fromFixnum(42).?) catch std.c._exit(3);
        const before = engineSyncs();
        commit(&w) catch std.c._exit(4);
        std.c._exit(if (engineSyncs() == before) 0 else 5);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    try testing.expectEqual(@as(c_int, 0), status);

    const conn = try fx.connect();
    var r = try beginRead(conn);
    defer abortRead(&r);
    try testing.expectEqual(@as(i64, 42), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
}

test "open: a new store has 16 KiB pages and the pinned tree capacity" {
    var fx = try Fixture.init("pagesize");
    defer fx.deinit();

    const conn = try fx.connect();

    try testing.expectEqual(page_size, conn.file.env.info().pageSize);
    try testing.expectEqual(page_size, conn.file.env.options.pageSize);
    try testing.expectEqual(max_named_trees, conn.file.env.options.maxNamedTrees);
    try testing.expectEqual(emdb.btree.maxKeySize(page_size), conn.file.env.maxKeySize());
    try testing.expectEqual(map_grow_step, conn.file.env.options.growStep);
    try testing.expect(conn.file.env.info().mapSize <= initial_map_size);
}

test "open: the reader table has reader_slots slots, so more than emdb's default 126 reads run at once" {
    var fx = try Fixture.init("readers");
    defer fx.deinit();

    const conn = try fx.connect();
    try testing.expectEqual(reader_slots, conn.file.env.info().maxReaders);
    var reads: [200]ReadTxn = undefined;
    for (&reads) |*r| r.* = try beginRead(conn);
    for (&reads) |*r| abortRead(r);
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
        open(testing.allocator, &heap, &interner, path.ptr),
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
        const junk: [2 * page_size]u8 = @splat(0xFF);
        try file.writeStreamingAll(io, &junk);
    }

    if (fx.connect()) |conn| {
        shutdown(conn);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "put / get / del: single-tree round-trip of a scalar" {
    var fx = try Fixture.init("putget");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try beginWrite(conn);
    try put(&wtxn, "users", "alice", value.fromFixnum(42).?);
    try commit(&wtxn);

    var rtxn = try beginRead(conn);
    defer abortRead(&rtxn);
    const got = try get(&rtxn, "users", "alice", &synthHash, &synthEq);
    try testing.expect(got != null);
    try testing.expect(got.?.kind() == .fixnum);
    try testing.expectEqual(@as(i64, 42), got.?.asFixnum());

    // Absent key.
    const miss = try get(&rtxn, "users", "bob", &synthHash, &synthEq);
    try testing.expect(miss == null);
}

test "put / get: multiple named trees are independent" {
    var fx = try Fixture.init("multitree");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try beginWrite(conn);
    try put(&wtxn, "treeA", "k0", value.fromFixnum(1).?);
    try put(&wtxn, "treeB", "k0", value.fromFixnum(2).?);
    try put(&wtxn, "treeC", "k0", value.fromFixnum(3).?);
    try commit(&wtxn);

    var rtxn = try beginRead(conn);
    defer abortRead(&rtxn);
    try testing.expectEqual(@as(i64, 1), (try get(&rtxn, "treeA", "k0", &synthHash, &synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 2), (try get(&rtxn, "treeB", "k0", &synthHash, &synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 3), (try get(&rtxn, "treeC", "k0", &synthHash, &synthEq)).?.asFixnum());
}

test "del: removes the key, subsequent get returns null" {
    var fx = try Fixture.init("del");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try beginWrite(conn);
    try put(&wtxn, "t", "k", value.fromFixnum(99).?);
    try commit(&wtxn);

    var wtxn2 = try beginWrite(conn);
    const removed = try del(&wtxn2, "t", "k");
    try testing.expect(removed);
    try commit(&wtxn2);

    var rtxn = try beginRead(conn);
    defer abortRead(&rtxn);
    try testing.expect((try get(&rtxn, "t", "k", &synthHash, &synthEq)) == null);
}

test "treeId: one handle per name, remembered across transactions, loaded once per transaction" {
    var fx = try Fixture.init("treeids");
    defer fx.deinit();

    const conn = try fx.connect();

    // Unknown tree, no create: nothing resolved, nothing cached.
    {
        var rtxn = try beginRead(conn);
        defer abortRead(&rtxn);
        try testing.expect((try treeId(&rtxn, "users", false)) == null);
        try testing.expectEqual(@as(usize, 0), conn.tree_ids.count());
    }

    var first_id: emdb.TreeId = undefined;
    {
        var wtxn = try beginWrite(conn);
        first_id = (try treeId(&wtxn, "users", true)).?;
        try testing.expect(wtxn.opened.isSet(first_id));
        try testing.expectEqual(first_id, (try treeId(&wtxn, "users", true)).?);
        try put(&wtxn, "users", "alice", value.fromFixnum(1).?);
        try commit(&wtxn);
    }
    try testing.expectEqual(@as(usize, 1), conn.tree_ids.count());
    try testing.expectEqual(first_id, conn.tree_ids.get("users").?);

    // A later transaction starts with nothing loaded and resolves
    // the same handle.
    {
        var rtxn = try beginRead(conn);
        defer abortRead(&rtxn);
        try testing.expect(!rtxn.opened.isSet(first_id));
        try testing.expectEqual(first_id, (try treeId(&rtxn, "users", false)).?);
        try testing.expect(rtxn.opened.isSet(first_id));
        try testing.expectEqual(@as(i64, 1), (try get(&rtxn, "users", "alice", &synthHash, &synthEq)).?.asFixnum());
    }
    try testing.expectEqual(@as(usize, 1), conn.tree_ids.count());
}

test "treeId: a tree created by an aborted transaction reads as empty afterwards" {
    var fx = try Fixture.init("treeabort");
    defer fx.deinit();

    const conn = try fx.connect();

    {
        var wtxn = try beginWrite(conn);
        try put(&wtxn, "scratch", "k", value.fromFixnum(7).?);
        abortWrite(&wtxn);
    }
    {
        var rtxn = try beginRead(conn);
        defer abortRead(&rtxn);
        try testing.expect((try get(&rtxn, "scratch", "k", &synthHash, &synthEq)) == null);
    }
    {
        var wtxn = try beginWrite(conn);
        defer abortWrite(&wtxn);
        try testing.expect(!(try del(&wtxn, "scratch", "k")));
    }
}

/// A store at `fx.path` whose tree `t` holds `a`, a value of `big`
/// bytes of `x` on overflow pages under `b`, and `c`; with `damage`,
/// one byte in the middle of `b`'s value is changed on the disk, so its
/// page fails its check.
fn walkStore(fx: *Fixture, big: usize, damage: bool) !void {
    {
        const conn = try fx.connect();
        defer shutdown(conn);
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

    var r = try beginRead(conn);
    defer abortRead(&r);
    var walk: Walk = undefined;
    try testing.expect(try walk.begin(&r, "t"));
    defer walk.end();
    try testing.expectEqualStrings("a", (try walk.first(null)).?.key);
    try testing.expectError(error.InvalidPage, walk.next());

    // A write under a walk copies the rest of it, and meets the same page.
    var w = try beginWrite(conn);
    defer abortWrite(&w);
    var over: Walk = undefined;
    try testing.expect(try over.begin(&w, "t"));
    defer over.end();
    _ = (try over.first(null)).?;
    try testing.expectError(error.InvalidPage, put(&w, "u", "k", value.fromFixnum(1).?));
}

test "Walk: a write to any tree of the transaction copies the rest first; values come whole from overflow pages" {
    var fx = try Fixture.init("walk_copy");
    defer fx.deinit();
    try walkStore(&fx, 3 * page_size, false);
    const conn = try fx.connect();

    var w = try beginWrite(conn);
    defer abortWrite(&w);
    var walk: Walk = undefined;
    try testing.expect(try walk.begin(&w, "t"));
    defer walk.end();
    try testing.expectEqualStrings("1", (try walk.first(null)).?.value);
    try testing.expect(walk.rest == null);
    // Another tree: the cursor may not step past a change anywhere in
    // the transaction (emdb API-C06A).
    try put(&w, "u", "k", value.fromFixnum(1).?);
    try testing.expect(walk.rest != null);
    try testing.expect(try del(&w, "t", "c"));
    const b = (try walk.next()).?;
    try testing.expectEqualStrings("b", b.key);
    try testing.expectEqual(@as(usize, 3 * page_size), b.value.len);
    try testing.expect(std.mem.allEqual(u8, b.value, 'x'));
    try testing.expectEqualStrings("c", (try walk.next()).?.key);
    try testing.expect(try walk.next() == null);
}

test "put / get: container values (list, map, set) codec round-trip" {
    const list_mod = @import("coll/list.zig");
    const champ = @import("coll/champ.zig");

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

    var wtxn = try beginWrite(conn);
    try put(&wtxn, "objects", "list", lst);
    try put(&wtxn, "objects", "map", m);
    try put(&wtxn, "objects", "set", s);
    try commit(&wtxn);

    var rtxn = try beginRead(conn);
    defer abortRead(&rtxn);

    const got_lst = try get(&rtxn, "objects", "list", &synthHash, &synthEq);
    try testing.expect(got_lst != null and got_lst.?.kind() == .list);
    try testing.expectEqual(@as(usize, 3), list_mod.count(got_lst.?));

    const got_m = try get(&rtxn, "objects", "map", &synthHash, &synthEq);
    try testing.expect(got_m != null and got_m.?.kind() == .persistent_map);
    try testing.expectEqual(@as(usize, 1), champ.mapCount(got_m.?));

    const got_s = try get(&rtxn, "objects", "set", &synthHash, &synthEq);
    try testing.expect(got_s != null and got_s.?.kind() == .persistent_set);
    try testing.expectEqual(@as(usize, 2), champ.setCount(got_s.?));
}

test "reopen-connection readback: values survive conn close/reopen" {
    var fx = try Fixture.init("reopen");
    defer fx.deinit();

    // Session 1: write.
    {
        const conn = try fx.connect();
        defer shutdown(conn);

        var wtxn = try beginWrite(conn);
        try put(&wtxn, "persistent", "answer", value.fromFixnum(42).?);
        try put(&wtxn, "persistent", "pi", value.fromFloat(3.14));
        try commit(&wtxn);
    }

    // Session 2: reopen + read.
    {
        const conn = try fx.connect();
        defer shutdown(conn);

        var rtxn = try beginRead(conn);
        defer abortRead(&rtxn);
        const ans = try get(&rtxn, "persistent", "answer", &synthHash, &synthEq);
        try testing.expect(ans != null and ans.?.kind() == .fixnum);
        try testing.expectEqual(@as(i64, 42), ans.?.asFixnum());

        const pi = try get(&rtxn, "persistent", "pi", &synthHash, &synthEq);
        try testing.expect(pi != null and pi.?.kind() == .float);
        try testing.expectEqual(@as(f64, 3.14), pi.?.asFloat());
    }
}

// ---- durable_ref Value kind ----

test "ref: identity triple populated; conn pointer attached" {
    var fx = try Fixture.init("refinit");
    defer fx.deinit();

    const conn = try fx.connect();

    const r = try ref(&fx.heap, conn, "users", "alice");
    try testing.expect(r.kind() == .durable_ref);
    try testing.expectEqual(conn.storeId(), refStoreId(r));
    try testing.expectEqualStrings("users", refTreeName(r));
    try testing.expectEqualStrings("alice", refKeyBytes(r));
    try testing.expectEqual(@as(?*Connection, conn), refConn(r));
}

test "refFromBytes: conn is null; identity triple preserved" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const r = try refFromBytes(&heap, 0xDEADBEEF_CAFEBABE_F00DFEED_BA5EBA11, "trees/users", "alice");
    try testing.expect(r.kind() == .durable_ref);
    try testing.expectEqual(@as(u128, 0xDEADBEEF_CAFEBABE_F00DFEED_BA5EBA11), refStoreId(r));
    try testing.expectEqualStrings("trees/users", refTreeName(r));
    try testing.expectEqualStrings("alice", refKeyBytes(r));
    try testing.expect(refConn(r) == null);
}

test "refsEqual: same identity triple → true; different → false" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const r1 = try refFromBytes(&heap, 0x1111_2222_3333_4444_5555_6666_7777_8888, "t", "k");
    const r2 = try refFromBytes(&heap, 0x1111_2222_3333_4444_5555_6666_7777_8888, "t", "k");
    const r3 = try refFromBytes(&heap, 0x1111_2222_3333_4444_5555_6666_7777_8888, "t", "k2"); // diff key
    const r4 = try refFromBytes(&heap, 0x1111_2222_3333_4444_5555_6666_7777_8889, "t", "k"); // diff store_id
    const r5 = try refFromBytes(&heap, 0x1111_2222_3333_4444_5555_6666_7777_8888, "u", "k"); // diff tree

    try testing.expect(refsEqual(refHeader(r1), refHeader(r2)));
    try testing.expect(!refsEqual(refHeader(r1), refHeader(r3)));
    try testing.expect(!refsEqual(refHeader(r1), refHeader(r4)));
    try testing.expect(!refsEqual(refHeader(r1), refHeader(r5)));
}

test "hashHeader: equal identity triples → equal hash; different → (almost certainly) different" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const r1 = try refFromBytes(&heap, 42, "users", "alice");
    const r2 = try refFromBytes(&heap, 42, "users", "alice");
    const r3 = try refFromBytes(&heap, 42, "users", "bob");

    try testing.expectEqual(hashHeader(refHeader(r1)), hashHeader(refHeader(r2)));
    try testing.expect(hashHeader(refHeader(r1)) != hashHeader(refHeader(r3)));
}

test "putRef / getRef / delRef: round-trip via ref" {
    var fx = try Fixture.init("refio");
    defer fx.deinit();

    const conn = try fx.connect();

    const r = try ref(&fx.heap, conn, "users", "alice");

    var wtxn = try beginWrite(conn);
    try putRef(&wtxn, r, value.fromFixnum(123).?);
    try commit(&wtxn);

    {
        var rtxn = try beginRead(conn);
        defer abortRead(&rtxn);
        const got = try getRef(&rtxn, r, &synthHash, &synthEq);
        try testing.expect(got != null and got.?.kind() == .fixnum);
        try testing.expectEqual(@as(i64, 123), got.?.asFixnum());
    }

    var wtxn2 = try beginWrite(conn);
    const removed = try delRef(&wtxn2, r);
    try testing.expect(removed);
    try commit(&wtxn2);
}

test "getRef: nullconn ref → ConnectionUnavailable" {
    var fx = try Fixture.init("nullconn");
    defer fx.deinit();

    const conn = try fx.connect();

    // Ref constructed from bytes (no conn).
    const r = try refFromBytes(&fx.heap, 999, "t", "k");

    var rtxn = try beginRead(conn);
    defer abortRead(&rtxn);
    try testing.expectError(DbError.ConnectionUnavailable, getRef(&rtxn, r, &synthHash, &synthEq));
}

test "getRef: cross-store ref → StoreMismatch" {
    var fx = try Fixture.init("xstore");
    defer fx.deinit();

    const conn = try fx.connect();

    // A ref made on a connection to another store.
    var other = conn.*;
    other.store_id_lo = 0xBAD_BAD_BAD_BAD_0000;
    const r = try ref(&fx.heap, &other, "t", "k");

    var rtxn = try beginRead(conn);
    defer abortRead(&rtxn);
    try testing.expectError(DbError.StoreMismatch, getRef(&rtxn, r, &synthHash, &synthEq));
}

test "invalid tree name / key: surfaces InvalidTreeName / InvalidKey" {
    var fx = try Fixture.init("invalid");
    defer fx.deinit();

    const conn = try fx.connect();

    var wtxn = try beginWrite(conn);
    defer abortWrite(&wtxn);
    try testing.expectError(DbError.InvalidTreeName, put(&wtxn, "", "k", value.nilValue()));
    try testing.expectError(DbError.InvalidKey, put(&wtxn, "t", "", value.nilValue()));
}
