//! db.zig — durable identities + emdb integration.
//!
//! Authoritative spec: `docs/DB.md`. Derivative from PLAN §23 #6,
//! #7 (explicit transactions; durable refs are identities),
//! `docs/CODEC.md` (value-bytes serialization), `docs/VALUE.md`
//! §2.2 (kind 26 `durable_ref`), `docs/SEMANTICS.md` §2.6 / §3.2
//! (identity-triple equality + hash).
//!
//! Responsibilities:
//!   - `StoreFile`: the one `emdb.Env` of a store file in this
//!     process, shared by every connection and Nextomic store of it.
//!   - `Connection` type over a `StoreFile` with
//!     `store_id = xxHash3-128(realpath(file))`.
//!   - `durable_ref` heap Value kind (VALUE.md §2.2 kind 26) with
//!     self-contained identity triple (store_id, tree_name,
//!     key_bytes) and an advisory non-identity `conn: ?*Connection`
//!     pointer.
//!   - `WriteTxn` / `ReadTxn` wrappers around `emdb.Txn`, and the
//!     `Handle` the language holds one by, which `close` and the
//!     collector end.
//!   - `Walk`: a tree walk that a write under it cannot disturb.
//!   - `put` / `get` / `del` by `(tree_name, key_bytes, value)` —
//!     keys are **opaque byte slices**, values
//!     are codec-encoded via `src/codec.zig`.
//!   - `putRef` / `getRef` / `delRef` ref-based convenience.
//!   - Per-kind hash / equality / trace helpers consumed by
//!     `src/dispatch.zig` and `src/gc.zig`.
//!
//! Scope (DB.md §1): explicit-transaction primitives. No `alter!`,
//! no as-of, no with-tx macro live here.
//!
//! Module graph (one-way terminal):
//!
//!     src/db.zig
//!     ├── @import("std")
//!     ├── @import("value.zig")
//!     ├── @import("heap.zig")
//!     ├── @import("intern.zig")
//!     ├── @import("hash.zig")
//!     ├── @import("codec.zig")
//!     └── @import("emdb")
//!
//! Importers (DB.md §11): `dispatch.zig` / `gc.zig` at their
//! `.durable_ref` arms, `gc.zig` to mark and sweep transaction
//! handles, `format.zig` to print refs and handles, `stdlib.zig` for
//! the natives, and Nextomic for `StoreFile` and the geometry
//! constants.

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
/// level (DB.md §8). Each emdb error set with a distinct cause gets
/// its own name; the rest share `:db-error`. A value of a kind with
/// no serialized form is `:unserializable`; bytes that do not decode
/// are `:codec-failed`.
pub fn failureName(err: anyerror) []const u8 {
    return switch (err) {
        error.KeyTooLarge => "db/key-too-large",
        error.ValueTooLarge => "db/value-too-large",
        error.MaxDbsReached => "db/max-trees",
        error.NotFound => "db/not-found",
        error.Corrupted, error.InvalidPage, error.FormatVersionMismatch => "db/corrupted",
        error.DatabaseFull => "db/map-full",
        error.MmapFailed => "db/mmap-failed",
        error.OpenFailed => "db/open-failed",
        error.PageSizeMismatch, error.InvalidPageSize => "db/page-size-mismatch",
        error.WriterActive, error.EnvBusy, error.TransactionsOpen => "db/busy",
        error.ReaderTableFull => "db/readers-full",
        error.HardLinked => "db/hard-linked",
        error.TxnAborted => "db/txn-aborted",
        error.TxnReadOnly => "db/read-only",
        error.SyncFailed => "db/sync-failed",
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

    /// The open file at `path`, or the file opened (or created) now
    /// with `options` and `reader_slots` reader slots. A file this
    /// process may read but not write opens read-only.
    pub fn acquire(path: [*:0]const u8, env_options: emdb.EnvOptions) !*StoreFile {
        var options = env_options;
        options.maxReaders = reader_slots;
        const allocator = options.allocator;
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

    /// Drop one hold; the last syncs what is unsynced, closes the
    /// environment and frees the file.
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
        try txn.commit();
        self.unsynced = switch (self.write_sync) {
            // nexis never opens an environment with emdb's `noSync`
            // or `noMetaSync`, so its own setting is a full sync.
            .full, .inherit => false,
            .none, .noMeta => true,
        };
    }

    /// Make every commit so far durable with one full sync of the
    /// file, when a commit since the last sync was left without one.
    pub fn sync(self: *StoreFile) !void {
        if (!self.unsynced) return;
        try self.env.sync();
        self.unsynced = false;
    }

    /// `sync` where no caller can take its error: teardown and exit.
    fn syncOrWarn(self: *StoreFile) void {
        self.sync() catch |err| std.debug.print("nexis: syncing {s} failed ({s}); its latest commits may be lost if the system crashes\n", .{ self.path, @errorName(err) });
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

    /// Whether `txn` reads the file's newest commit, by this process
    /// or any other.
    fn latest(self: *StoreFile, txn: *emdb.Txn) bool {
        return txn.txnId == self.env.inner.activeMeta().loadTxnId();
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

/// The device and inode that name a file whatever path reaches it.
const FileId = struct {
    dev: u64,
    ino: u64,
    /// A regular file with a second name (`StoreFile`). A directory's
    /// links are its entries; emdb refuses it as a store.
    hard_linked: bool,

    /// The file at `path` relative to the directory `fd`, or the file
    /// open as `fd` when `path` is empty; null when it cannot be
    /// examined. Zig's `std.c` declares no `stat` family for Linux,
    /// whose glibc versions those symbols, so Linux asks the kernel's
    /// `statx`.
    fn of(fd: std.c.fd_t, path: [*:0]const u8) ?FileId {
        if (builtin.os.tag == .linux) {
            const linux = std.os.linux;
            var sx: linux.Statx = undefined;
            const flags: u32 = if (path[0] == 0) linux.AT.EMPTY_PATH else 0;
            if (linux.errno(linux.statx(fd, path, flags, .{ .TYPE = true, .NLINK = true, .INO = true }, &sx)) != .SUCCESS) return null;
            return .{
                .dev = @as(u64, sx.dev_major) << 32 | sx.dev_minor,
                .ino = sx.ino,
                .hard_linked = linux.S.ISREG(sx.mode) and sx.nlink > 1,
            };
        }
        var st: std.c.Stat = undefined;
        const rc = if (path[0] == 0) std.c.fstat(fd, &st) else std.c.fstatat(fd, path, &st, 0);
        if (rc != 0) return null;
        return .{
            .dev = @bitCast(@as(i64, st.dev)),
            .ino = st.ino,
            .hard_linked = std.c.S.ISREG(st.mode) and st.nlink > 1,
        };
    }
};

/// The absolute path of `path` with every symlink resolved; for a file
/// not yet created, its resolved directory joined with its name.
fn canonicalPath(allocator: std.mem.Allocator, path: [*:0]const u8) ![:0]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (std.c.realpath(path, &buf)) |resolved| return allocator.dupeZ(u8, std.mem.sliceTo(resolved, 0));
    const slice = std.mem.sliceTo(path, 0);
    const dir_z = try allocator.dupeZ(u8, std.fs.path.dirname(slice) orelse ".");
    defer allocator.free(dir_z);
    const dir = std.c.realpath(dir_z.ptr, &buf) orelse return error.OpenFailed;
    return std.fs.path.joinZ(allocator, &.{ std.mem.sliceTo(dir, 0), std.fs.path.basename(slice) });
}

// =============================================================================
// Connection (DB.md §3)
//
// NOT a runtime Value kind. Plain Zig struct allocated on the
// caller's allocator. Caller owns the lifetime via explicit
// `close()`. Multiple durable-refs may point at one Connection via
// their advisory `conn` pointer; the Connection is not
// reference-counted.
// =============================================================================

pub const Connection = struct {
    /// Non-owning: caller guarantees lifetime ≥ Connection's.
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

    /// Is the env open? Set true by `open()`, false by
    /// `close()`. Used to defend against double-close + to signal
    /// `ConnectionUnavailable` for subsequent ops.
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

/// Reader slots in a store's lock file, 64 bytes each: how many read
/// transactions every process sharing the file can hold at once. A
/// table in use keeps the size its first opener gave it until every
/// process has closed it (emdb INV-T14E).
pub const reader_slots: u32 = 4096;

/// How a commit reaches the disk (DB.md §3.3). Every commit is atomic
/// and seen at once by every connection and process sharing the file.
pub const Durability = enum {
    /// A commit syncs nothing; the file is synced once when its
    /// connection closes, at `db/sync` and `nextomic/sync`, and when
    /// the process ends. A crash of the process loses nothing; a crash
    /// of the system can lose the commits since the last sync.
    commit,
    /// Every commit syncs data and meta.
    durable,

    pub fn parse(text: []const u8) ?Durability {
        return std.meta.stringToEnum(Durability, text);
    }

    /// `NEXIS_DURABILITY`, or `commit` when it is unset. `bin/nexis`
    /// refuses any other value at start, so an unknown one reaches
    /// here only from an embedding, and reads as unset.
    pub fn process() Durability {
        const text = std.c.getenv("NEXIS_DURABILITY") orelse return .commit;
        return parse(std.mem.span(text)) orelse .commit;
    }

    pub fn syncOverride(self: Durability) emdb.SyncOverride {
        return switch (self) {
            .commit => .none,
            .durable => .full,
        };
    }
};

/// Open (or create) a database file at `path`. `allocator` /
/// `heap` / `interner` are non-owning references; caller
/// guarantees their lifetimes. `options` is passed through to
/// `emdb.Env.open` with `pageSize` and `maxNamedTrees` pinned to
/// `page_size` / `max_named_trees`; a file already open in this
/// process is shared as it is (`StoreFile`).
pub fn open(
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,
    path: [*:0]const u8,
    options: emdb.EnvOptions,
) !Connection {
    var env_options = options;
    env_options.pageSize = page_size;
    env_options.maxNamedTrees = max_named_trees;
    const file = try StoreFile.acquire(path, env_options);

    // store_id = two xxHash3-64 halves over the canonical path, the
    // second salted so the halves are independent.
    const hash_lo = hash_mod.hashBytes(file.path);
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    hasher.update("store-id");
    hasher.update(file.path);
    const hash_hi = hasher.final();

    return Connection{
        .allocator = allocator,
        .heap = heap,
        .interner = interner,
        .file = file,
        .store_id_lo = hash_lo,
        .store_id_hi = hash_hi,
        .open_flag = true,
        .tree_ids = .empty,
        .durability = Durability.process(),
    };
}

/// Close the connection, aborting every transaction the language
/// holds on it (DB.md §3), and sync the file when a commit left it
/// unsynced. A closed connection stays a valid struct:
/// refs and handles that name it read `open_flag` and report it
/// closed. A second close does nothing. A close while a native holds
/// one of the connection's transactions for a callback, or while a
/// Zig-level transaction is open, is refused, so no emdb transaction
/// outlives its env. A failed sync is returned once the connection is
/// closed.
pub fn close(self: *Connection) (DbError || emdb.Error)!void {
    if (!self.open_flag) return;
    var it = Handle.all;
    while (it) |h| : (it = h.next) {
        if (h.conn() == self and h.held != 0) return DbError.TransactionsOpen;
    }
    it = Handle.all;
    while (it) |h| : (it = h.next) {
        if (h.conn() == self) h.end();
    }
    if (self.open_txns != 0) return DbError.TransactionsOpen;
    const synced = self.file.sync();
    release(self);
    return synced;
}

/// Make every commit to the connection's file durable (`db/sync`).
pub fn sync(self: *Connection) !void {
    if (!self.open_flag) return DbError.ConnectionUnavailable;
    try self.file.sync();
}

/// Teardown of the whole VM, when nothing can use the connection
/// again: end and free its handles and close it whatever is open.
pub fn shutdown(self: *Connection) void {
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
pub const TreeSet = std.bit_set.StaticBitSet(emdb.txn.coreTreeCount + max_named_trees);

pub const WriteTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
    /// Trees this transaction has loaded; see `treeId`.
    opened: TreeSet = TreeSet.initEmpty(),
    /// Walks in progress over this transaction's trees; a write to a
    /// walked tree copies what the walk has yet to visit first.
    walks: ?*Walk = null,
};

pub const ReadTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
    /// Trees this transaction has loaded; see `treeId`.
    opened: TreeSet = TreeSet.initEmpty(),
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

/// The collector reached a Value of the handle (GC.md §5).
pub fn markHandle(v: Value) void {
    handleOf(v).reached = true;
}

/// After a mark phase over `heap`: end and free every handle of a
/// connection on `heap` that no Value reached, unless a native holds
/// it, and let every held snapshot go (DB.md §3.4). `complete` is false
/// when the marks are incomplete, which only clears them. Ending a
/// transaction allocates nothing on the heap.
pub fn sweepHandles(heap: *Heap, complete: bool) void {
    StoreFile.dropAllHeld();
    var link = &Handle.all;
    while (link.*) |h| {
        const c = h.conn();
        if (c.heap != heap or !complete or h.reached or h.held != 0) {
            if (c.heap == heap) h.reached = false;
            link = &h.next;
            continue;
        }
        h.end();
        link.* = h.next;
        c.allocator.destroy(h);
    }
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
/// and `db/reduce-tree`. emdb leaves undefined what a cursor sees once
/// its own tree is written under it, so a write through the
/// transaction to a tree being walked first copies the entries the
/// walk has yet to visit (`WriteTxn.walks`): the walk sees the tree as
/// it was when it began, whatever its callback writes, and a walk no
/// callback writes under copies nothing. A walk lives on its caller's
/// stack between `begin` and `end`.
pub const Walk = struct {
    cursor: emdb.Cursor,
    tree: emdb.TreeId,
    allocator: std.mem.Allocator,
    /// The write transaction the walk is registered on.
    owner: ?*WriteTxn,
    next_walk: ?*Walk = null,
    /// The entries still to visit once the tree was written: key and
    /// value bytes back to back, and where each key and value ends.
    rest: ?struct {
        bytes: std.ArrayList(u8) = .empty,
        ends: std.ArrayList([2]usize) = .empty,
        at: usize = 0,
    } = null,

    pub const Entry = emdb.Cursor.KeyValue;

    /// Start a walk over `tree_name` in `txn` (a `*WriteTxn` or
    /// `*ReadTxn`); false when the tree does not exist, and then no
    /// `end` is due.
    pub fn begin(self: *Walk, txn: anytype, tree_name: []const u8) !bool {
        try validateTreeName(tree_name);
        const id = (try treeId(txn, tree_name, false)) orelse return false;
        self.* = .{
            .cursor = try txn.inner.openCursorForTree(id),
            .tree = id,
            .allocator = txn.conn.allocator,
            .owner = null,
        };
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
        if (self.rest) |*r| {
            r.bytes.deinit(self.allocator);
            r.ends.deinit(self.allocator);
        }
    }

    /// The first entry, or the first at or after `start`.
    pub fn first(self: *Walk, start: ?[]const u8) ?Entry {
        return if (start) |s| self.cursor.setRange(s) else self.cursor.first();
    }

    pub fn next(self: *Walk) ?Entry {
        const r = if (self.rest) |*r| r else return self.cursor.next();
        if (r.at == r.ends.items.len) return null;
        const from = if (r.at == 0) 0 else r.ends.items[r.at - 1][1];
        const e = r.ends.items[r.at];
        r.at += 1;
        return .{ .key = r.bytes.items[from..e[0]], .value = r.bytes.items[e[0]..e[1]] };
    }

    /// Copy what the cursor has yet to visit, before the tree changes
    /// under it. Each value is copied before the cursor moves: a
    /// multi-page value lives in the transaction's buffer until the
    /// next multi-page read.
    fn copyRest(self: *Walk) !void {
        self.rest = .{};
        const r = &self.rest.?;
        while (self.cursor.next()) |kv| {
            try r.bytes.appendSlice(self.allocator, kv.key);
            const key_end = r.bytes.items.len;
            try r.bytes.appendSlice(self.allocator, kv.value);
            try r.ends.append(self.allocator, .{ key_end, r.bytes.items.len });
        }
    }
};

/// Before `txn` writes tree `id`: every walk over it copies what it
/// has yet to visit.
fn beforeWrite(txn: *WriteTxn, id: emdb.TreeId) !void {
    var it = txn.walks;
    while (it) |w| : (it = w.next_walk) {
        if (w.tree == id and w.rest == null) try w.copyRest();
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
    const tree_id = (try treeId(txn, tree_name, true)).?;
    // Encode the value via codec, pass the bytes to emdb, free the
    // codec buffer.
    const encoded = try codec_mod.encode(txn.conn.allocator, txn.conn.interner, v);
    defer txn.conn.allocator.free(encoded);
    try beforeWrite(txn, tree_id);
    try txn.inner.putInTree(tree_id, key_bytes, encoded);
}

/// Read a value by `(tree_name, key_bytes)`. Accepts either a
/// `*WriteTxn` or `*ReadTxn` via duck-typing (both have
/// `.conn: *Connection` and `.inner: *emdb.Txn`).
///
/// `elementHash` / `elementEq` are the hash and equality functions
/// the codec uses to rebuild decoded map / set / vector collections.
/// They MUST be the authoritative runtime hash and equality for all
/// codec-serializable kinds — callers almost always pass
/// `&dispatch.hashValue, &dispatch.equal`.
///
/// Why the caller passes them instead of `src/db.zig` importing
/// `src/dispatch.zig` directly: `dispatch.zig` already imports
/// `db.zig` (for the `.durable_ref` arms), so `db.zig` importing
/// `dispatch.zig` would create a module-graph cycle. The
/// parameterized seam keeps the graph one-way terminal while
/// letting production callers supply full dispatch semantics. Inline
/// tests that work with a restricted Value alphabet may pass
/// narrower stand-ins.
///
/// Using non-dispatch callbacks is unsound for decoded CHAMP-shaped
/// maps / sets (>8 entries with heap-kind keys): the internal trie
/// placement depends on hash bits, and a subsequent lookup through
/// `dispatch.hashValue` would miss entries placed under an
/// alternative hash. Small array-maps (≤8 entries) tolerate
/// mismatched callbacks because they probe purely via equality.
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

pub fn del(
    txn: *WriteTxn,
    tree_name: []const u8,
    key_bytes: []const u8,
) !bool {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const tree_id = (try treeId(txn, tree_name, false)) orelse return false;
    try beforeWrite(txn, tree_id);
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

/// Construct a durable-ref heap Value from an active Connection.
/// The ref's identity triple (`store_id`, `tree_name`, `key_bytes`)
/// is fixed at construction; the advisory `conn` pointer is set to
/// the supplied Connection.
pub fn ref(
    heap: *Heap,
    conn: *Connection,
    tree_name: []const u8,
    key_bytes: []const u8,
) !Value {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const body_size = @sizeOf(DurableRefBody) + tree_name.len + key_bytes.len;
    const h = try heap.alloc(.durable_ref, body_size);
    const body = bodyOf(h);
    body.conn = conn;
    body.store_id_lo = conn.store_id_lo;
    body.store_id_hi = conn.store_id_hi;
    body.tree_name_len = @intCast(tree_name.len);
    body.key_bytes_len = @intCast(key_bytes.len);
    const inline_bytes = inlineBytesOf(h);
    @memcpy(inline_bytes[0..tree_name.len], tree_name);
    @memcpy(inline_bytes[tree_name.len..][0..key_bytes.len], key_bytes);
    return heap_mod.Heap.valueFromHeader(.durable_ref, h);
}

/// Construct a durable-ref from bytes (no live Connection
/// context). The `conn` pointer is null, so I/O through this ref is
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

fn bodyOfConst(h: *HeapHeader) *const DurableRefBody {
    return bodyOf(h);
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
    const body = bodyOfConst(refHeader(r));
    return (@as(u128, body.store_id_hi) << 64) | @as(u128, body.store_id_lo);
}

pub fn refTreeName(r: Value) []const u8 {
    const h = refHeader(r);
    const body = bodyOfConst(h);
    const inline_bytes = inlineBytesOf(h);
    return inline_bytes[0..body.tree_name_len];
}

pub fn refKeyBytes(r: Value) []const u8 {
    const h = refHeader(r);
    const body = bodyOfConst(h);
    const inline_bytes = inlineBytesOf(h);
    return inline_bytes[body.tree_name_len..][0..body.key_bytes_len];
}

pub fn refConn(r: Value) ?*Connection {
    const body = bodyOfConst(refHeader(r));
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
// Per-kind hash / equality / trace (DB.md §7)
//
// Consumed by `src/dispatch.zig` at the `.durable_ref` arm and by
// `src/gc.zig` at the same arm.
// =============================================================================

/// Identity-triple hash: xxHash3 over (store_id LE bytes ++
/// tree_name ++ key_bytes). `conn` NOT consulted. Kind-local hash
/// domain applied by `dispatch.hashValue` on the way out.
pub fn hashHeader(h: *HeapHeader) u32 {
    if (h.cachedHash()) |cached| return cached;
    const body = bodyOfConst(h);
    const inline_bytes = inlineBytesOf(h);
    var hasher = std.hash.XxHash3.init(hash_mod.seed);
    // store_id_lo + store_id_hi as LE bytes.
    var store_id_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, store_id_bytes[0..8], body.store_id_lo, .little);
    std.mem.writeInt(u64, store_id_bytes[8..16], body.store_id_hi, .little);
    hasher.update(&store_id_bytes);
    hasher.update(inline_bytes[0..body.tree_name_len]);
    hasher.update(inline_bytes[body.tree_name_len..][0..body.key_bytes_len]);
    const full = hasher.final();
    const truncated: u32 = @truncate(full);
    if (truncated != 0) h.setCachedHash(truncated);
    return truncated;
}

/// Identity-triple equality: byte-for-byte on (store_id,
/// tree_name, key_bytes). `conn` NOT consulted.
pub fn refsEqual(a: *HeapHeader, b: *HeapHeader) bool {
    if (a == b) return true;
    const ab = bodyOfConst(a);
    const bb = bodyOfConst(b);
    if (ab.store_id_lo != bb.store_id_lo) return false;
    if (ab.store_id_hi != bb.store_id_hi) return false;
    if (ab.tree_name_len != bb.tree_name_len) return false;
    if (ab.key_bytes_len != bb.key_bytes_len) return false;
    const a_bytes = inlineBytesOf(a);
    const b_bytes = inlineBytesOf(b);
    const total_len = ab.tree_name_len + ab.key_bytes_len;
    return std.mem.eql(u8, a_bytes[0..total_len], b_bytes[0..total_len]);
}

/// GC trace — no-op per DB.md §7.3. `conn` is not a heap Value;
/// tree_name and key_bytes are inline body bytes. Metadata is
/// handled centrally by the collector.
pub fn trace(h: *HeapHeader, visitor: anytype) void {
    _ = h;
    _ = visitor;
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
    return std.fmt.allocPrintSentinel(allocator, ".zig-cache/tmp/{s}/{s}.emdb", .{ tmp.sub_path, suffix }, 0);
}

fn cleanupDb(path: [:0]const u8) void {
    const dir = std.fs.path.dirname(path) orelse return;
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
}

fn synthHash(v: Value) u64 {
    return v.hashImmediate();
}

fn synthEq(a: Value, b: Value) bool {
    if (a.tag == b.tag and a.payload == b.payload) return true;
    if (a.kind() != b.kind()) return false;
    return switch (a.kind()) {
        .nil, .false_, .true_ => true,
        .fixnum => a.asFixnum() == b.asFixnum(),
        .keyword => a.asKeywordId() == b.asKeywordId(),
        .char => a.asChar() == b.asChar(),
        else => false,
    };
}

test "DurableRefBody layout: 32 bytes header" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(DurableRefBody));
}

test "open / close: round-trip with a tiny file" {
    const path = try tmpDbPath(testing.allocator, "open_close");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    try testing.expect(conn.open_flag);
    const sid = conn.storeId();
    try testing.expect(sid != 0);
}

test "open: store_id comes from the canonical path, however the path is spelled" {
    const path = try tmpDbPath(testing.allocator, "canon");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var a = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    const sid = a.storeId();
    try testing.expect(std.fs.path.isAbsolute(a.file.path));
    try close(&a);
    const dotted = try std.fmt.allocPrintSentinel(testing.allocator, "./{s}", .{path}, 0);
    defer testing.allocator.free(dotted);
    var b = try open(testing.allocator, &heap, &interner, dotted.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&b);
    try testing.expectEqual(sid, b.storeId());
}

test "open: every spelling of one file shares its environment; a second writer is refused, never waited on" {
    const path = try tmpDbPath(testing.allocator, "shared");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var a = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&a);
    const dotted = try std.fmt.allocPrintSentinel(testing.allocator, "./{s}", .{path}, 0);
    defer testing.allocator.free(dotted);
    const link = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/link.emdb", .{std.fs.path.dirname(path).?}, 0);
    defer testing.allocator.free(link);
    try std.Io.Dir.cwd().symLink(testing.io, std.fs.path.basename(path), link, .{});

    var same = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&same);
    var b = try open(testing.allocator, &heap, &interner, dotted.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&b);
    var c = try open(testing.allocator, &heap, &interner, link.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&c);
    // Checked before any second write begins: on separate environments
    // it would wait on this thread's own lock.
    try testing.expect(same.file == a.file and b.file == a.file and c.file == a.file);
    try testing.expectEqual(@as(u32, 4), a.file.refs);
    try testing.expectEqual(a.storeId(), c.storeId());
    // One lock file, beside the file the link names.
    const link_lock = try std.fmt.allocPrintSentinel(testing.allocator, "{s}-lock", .{link}, 0);
    defer testing.allocator.free(link_lock);
    try testing.expect(std.c.access(link_lock.ptr, std.c.F_OK) != 0);

    var w = try beginWrite(&a);
    try testing.expectError(error.WriterActive, beginWrite(&same));
    try testing.expectError(error.WriterActive, beginWrite(&c));
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);

    // The file stays open while any connection holds it.
    try close(&a);
    try close(&same);
    var r = try beginRead(&c);
    const got = try get(&r, "t", "k", synthHash, synthEq);
    abortRead(&r);
    try testing.expectEqual(@as(i64, 1), got.?.asFixnum());
    var w2 = try beginWrite(&b);
    try commit(&w2);
}

test "open: a copy of a store is another file, written beside the original" {
    const path = try tmpDbPath(testing.allocator, "original");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var a = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&a);
    var w = try beginWrite(&a);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    const copy = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/copy.emdb", .{std.fs.path.dirname(path).?}, 0);
    defer testing.allocator.free(copy);
    try std.Io.Dir.cwd().copyFile(path, std.Io.Dir.cwd(), copy, testing.io, .{});

    var b = try open(testing.allocator, &heap, &interner, copy.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&b);
    try testing.expect(a.file != b.file);
    try testing.expect(a.storeId() != b.storeId());
    var wa = try beginWrite(&a);
    var wb = try beginWrite(&b);
    try put(&wa, "t", "k", value.fromFixnum(2).?);
    try put(&wb, "t", "k", value.fromFixnum(3).?);
    try commit(&wa);
    try commit(&wb);
    var ra = try beginRead(&a);
    defer abortRead(&ra);
    var rb = try beginRead(&b);
    defer abortRead(&rb);
    try testing.expectEqual(@as(i64, 2), (try get(&ra, "t", "k", synthHash, synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 3), (try get(&rb, "t", "k", synthHash, synthEq)).?.asFixnum());
}

test "open: a store file with a second hard link is refused under either name" {
    const path = try tmpDbPath(testing.allocator, "linked");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var a = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&a);
    const other = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/other.emdb", .{std.fs.path.dirname(path).?}, 0);
    defer testing.allocator.free(other);
    try testing.expectEqual(@as(c_int, 0), std.c.link(path.ptr, other.ptr));
    // Already open here, and not yet open anywhere: both refused.
    try testing.expectError(error.HardLinked, open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator }));
    try close(&a);
    try testing.expectError(error.HardLinked, open(testing.allocator, &heap, &interner, other.ptr, .{ .allocator = testing.allocator }));
    try testing.expectError(error.HardLinked, open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator }));
    try testing.expectEqualStrings("db/hard-linked", failureName(error.HardLinked));
    // A directory has links of its own, and is no store.
    const dir = try testing.allocator.dupeZ(u8, std.fs.path.dirname(path).?);
    defer testing.allocator.free(dir);
    try testing.expectError(error.OpenFailed, open(testing.allocator, &heap, &interner, dir.ptr, .{ .allocator = testing.allocator }));
    // One name again: the file opens.
    try testing.expectEqual(@as(c_int, 0), std.c.unlink(other.ptr));
    var b = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&b);
}

test "open: a file this process may only read opens read-only; a write is TxnReadOnly" {
    const path = try tmpDbPath(testing.allocator, "readonly");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    {
        var a = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
        defer shutdown(&a);
        var w = try beginWrite(&a);
        try put(&w, "t", "k", value.fromFixnum(7).?);
        try commit(&w);
    }
    try testing.expectEqual(@as(c_int, 0), std.c.chmod(path.ptr, 0o444));
    defer _ = std.c.chmod(path.ptr, 0o644);
    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);
    var r = try beginRead(&conn);
    defer abortRead(&r);
    try testing.expectEqual(@as(i64, 7), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    try testing.expectError(error.TxnReadOnly, beginWrite(&conn));
}

test "close: refused while a transaction is open; the connection stays a closed struct" {
    const path = try tmpDbPath(testing.allocator, "close_busy");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);
    var rtxn = try beginRead(&conn);
    try testing.expectError(DbError.TransactionsOpen, close(&conn));
    abortRead(&rtxn);
    try close(&conn);
    try close(&conn);
    try testing.expect(!conn.open_flag);
    try testing.expectError(DbError.ConnectionUnavailable, beginRead(&conn));
}

/// Syncs the engine has issued in this process (data and meta alike).
fn engineSyncs() u64 {
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
    const path = try tmpDbPath(testing.allocator, "commit_mode");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var a = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&a);
    a.durability = .commit;
    var b = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&b);

    const before = engineSyncs();
    var w = try beginWrite(&a);
    try put(&w, "t", "k", value.fromFixnum(7).?);
    try commit(&w);
    try testing.expectEqual(before, engineSyncs());
    try testing.expect(a.file.unsynced);
    {
        var r = try beginRead(&b);
        defer abortRead(&r);
        try testing.expectEqual(@as(i64, 7), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    }
    // An abort writes nothing, so it leaves nothing more to sync.
    var aborted = try beginWrite(&a);
    abortWrite(&aborted);
    try close(&a);
    try testing.expectEqual(before + 1, engineSyncs());
    try testing.expect(!b.file.unsynced);
    try close(&b);
    try testing.expectEqual(before + 1, engineSyncs());
}

test "durability durable: every commit syncs, which leaves nothing for close; a read-only program never syncs" {
    const path = try tmpDbPath(testing.allocator, "durable_mode");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);
    conn.durability = .commit;
    var w = try beginWrite(&conn);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    try testing.expect(conn.file.unsynced);
    // A durable commit makes every commit before it durable too.
    conn.durability = .durable;
    const before = engineSyncs();
    w = try beginWrite(&conn);
    try put(&w, "t", "k", value.fromFixnum(2).?);
    try commit(&w);
    try testing.expect(engineSyncs() > before);
    try testing.expect(!conn.file.unsynced);
    const after_commit = engineSyncs();
    try close(&conn);
    try testing.expectEqual(after_commit, engineSyncs());

    var reader = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&reader);
    var r = try beginRead(&reader);
    try testing.expectEqual(@as(i64, 2), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
    abortRead(&r);
    try close(&reader);
    try testing.expectEqual(after_commit, engineSyncs());
}

test "syncAll: one sync for each file written without one; shutdown syncs a file it releases last" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();
    var paths: [3][:0]u8 = undefined;
    var conns: [3]Connection = undefined;
    for (&paths, &conns, 0..) |*p, *c, i| {
        p.* = try tmpDbPath(testing.allocator, &.{'a' + @as(u8, @intCast(i))});
        c.* = try open(testing.allocator, &heap, &interner, p.*.ptr, .{ .allocator = testing.allocator });
        c.durability = .commit;
    }
    defer for (&paths, &conns) |p, *c| {
        shutdown(c);
        cleanupDb(p);
        testing.allocator.free(p);
    };
    for (conns[0..2]) |*c| {
        var w = try beginWrite(c);
        try put(&w, "t", "k", value.fromFixnum(1).?);
        try commit(&w);
    }
    const before = engineSyncs();
    StoreFile.syncAll();
    try testing.expectEqual(before + 2, engineSyncs());
    StoreFile.syncAll();
    try testing.expectEqual(before + 2, engineSyncs());

    var w = try beginWrite(&conns[2]);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    shutdown(&conns[2]);
    try testing.expectEqual(before + 3, engineSyncs());
}

test "held snapshot: kept while it is the latest commit; a commit passing it, a write, a collection and the last release let it go" {
    const path = try tmpDbPath(testing.allocator, "held");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);
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
    var w = try beginWrite(&conn);
    try put(&w, "t", "k", value.fromFixnum(1).?);
    try commit(&w);
    file.keep(stale);
    try testing.expect(file.held == null);

    // This process's own write lets it go before it begins.
    file.keep(try file.env.beginRead());
    try testing.expect(file.held != null);
    w = try beginWrite(&conn);
    try testing.expect(file.held == null);
    abortWrite(&w);

    // So does a collection's sweep.
    file.keep(try file.env.beginRead());
    sweepHandles(&heap, true);
    try testing.expect(file.held == null);

    // The last release ends one still held (the allocator and emdb
    // would report a transaction outliving its environment).
    file.keep(try file.env.beginRead());
    try testing.expect(file.held != null);
}

test "durability commit: a commit survives its process ending without a sync or a close" {
    const path = try tmpDbPath(testing.allocator, "crash");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    // The child commits and ends at once, as a killed process does:
    // no sync, no close, no exit handlers.
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        var conn = open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator }) catch std.c._exit(1);
        conn.durability = .commit;
        var w = beginWrite(&conn) catch std.c._exit(2);
        put(&w, "t", "k", value.fromFixnum(42).?) catch std.c._exit(3);
        const before = engineSyncs();
        commit(&w) catch std.c._exit(4);
        std.c._exit(if (engineSyncs() == before) 0 else 5);
    }
    var status: c_int = 0;
    try testing.expectEqual(pid, std.c.waitpid(pid, &status, 0));
    try testing.expectEqual(@as(c_int, 0), status);

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);
    var r = try beginRead(&conn);
    defer abortRead(&r);
    try testing.expectEqual(@as(i64, 42), (try get(&r, "t", "k", synthHash, synthEq)).?.asFixnum());
}

test "open: a new store has 16 KiB pages and the pinned tree capacity" {
    const path = try tmpDbPath(testing.allocator, "pagesize");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    // Caller-supplied geometry does not leak through.
    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{
        .allocator = testing.allocator,
        .pageSize = 4096,
        .maxNamedTrees = 8,
    });
    defer shutdown(&conn);

    try testing.expectEqual(page_size, conn.file.env.info().pageSize);
    try testing.expectEqual(page_size, conn.file.env.options.pageSize);
    try testing.expectEqual(max_named_trees, conn.file.env.options.maxNamedTrees);
    try testing.expectEqual(emdb.btree.maxKeySize(page_size), conn.file.env.maxKeySize());
}

test "open: the reader table has reader_slots slots, so more than emdb's default 126 reads run at once" {
    const path = try tmpDbPath(testing.allocator, "readers");
    defer testing.allocator.free(path);
    defer cleanupDb(path);
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator, .maxReaders = 8 });
    defer shutdown(&conn);
    try testing.expectEqual(reader_slots, conn.file.env.info().maxReaders);
    var reads: [200]ReadTxn = undefined;
    for (&reads) |*r| r.* = try beginRead(&conn);
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
        open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator }),
    );
}

test "open: a file that is not an emdb store is refused without leaking" {
    const path = try tmpDbPath(testing.allocator, "notastore");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    // Two pages of 0xFF: a non-zero size with no valid meta page.
    {
        const io = std.testing.io;
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        const junk = [_]u8{0xFF} ** (2 * page_size);
        try file.writeStreamingAll(io, &junk);
    }

    if (open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator })) |conn| {
        var opened = conn;
        shutdown(&opened);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "put / get / del: single-tree round-trip of a scalar" {
    const path = try tmpDbPath(testing.allocator, "putget");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    var wtxn = try beginWrite(&conn);
    try put(&wtxn, "users", "alice", value.fromFixnum(42).?);
    try commit(&wtxn);

    var rtxn = try beginRead(&conn);
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
    const path = try tmpDbPath(testing.allocator, "multitree");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    var wtxn = try beginWrite(&conn);
    try put(&wtxn, "treeA", "k0", value.fromFixnum(1).?);
    try put(&wtxn, "treeB", "k0", value.fromFixnum(2).?);
    try put(&wtxn, "treeC", "k0", value.fromFixnum(3).?);
    try commit(&wtxn);

    var rtxn = try beginRead(&conn);
    defer abortRead(&rtxn);
    try testing.expectEqual(@as(i64, 1), (try get(&rtxn, "treeA", "k0", &synthHash, &synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 2), (try get(&rtxn, "treeB", "k0", &synthHash, &synthEq)).?.asFixnum());
    try testing.expectEqual(@as(i64, 3), (try get(&rtxn, "treeC", "k0", &synthHash, &synthEq)).?.asFixnum());
}

test "del: removes the key, subsequent get returns null" {
    const path = try tmpDbPath(testing.allocator, "del");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    var wtxn = try beginWrite(&conn);
    try put(&wtxn, "t", "k", value.fromFixnum(99).?);
    try commit(&wtxn);

    var wtxn2 = try beginWrite(&conn);
    const removed = try del(&wtxn2, "t", "k");
    try testing.expect(removed);
    try commit(&wtxn2);

    var rtxn = try beginRead(&conn);
    defer abortRead(&rtxn);
    try testing.expect((try get(&rtxn, "t", "k", &synthHash, &synthEq)) == null);
}

test "treeId: one handle per name, remembered across transactions, loaded once per transaction" {
    const path = try tmpDbPath(testing.allocator, "treeids");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    // Unknown tree, no create: nothing resolved, nothing cached.
    {
        var rtxn = try beginRead(&conn);
        defer abortRead(&rtxn);
        try testing.expect((try treeId(&rtxn, "users", false)) == null);
        try testing.expectEqual(@as(usize, 0), conn.tree_ids.count());
    }

    var first_id: emdb.TreeId = undefined;
    {
        var wtxn = try beginWrite(&conn);
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
        var rtxn = try beginRead(&conn);
        defer abortRead(&rtxn);
        try testing.expect(!rtxn.opened.isSet(first_id));
        try testing.expectEqual(first_id, (try treeId(&rtxn, "users", false)).?);
        try testing.expect(rtxn.opened.isSet(first_id));
        try testing.expectEqual(@as(i64, 1), (try get(&rtxn, "users", "alice", &synthHash, &synthEq)).?.asFixnum());
    }
    try testing.expectEqual(@as(usize, 1), conn.tree_ids.count());
}

test "treeId: a tree created by an aborted transaction reads as empty afterwards" {
    const path = try tmpDbPath(testing.allocator, "treeabort");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    {
        var wtxn = try beginWrite(&conn);
        try put(&wtxn, "scratch", "k", value.fromFixnum(7).?);
        abortWrite(&wtxn);
    }
    {
        var rtxn = try beginRead(&conn);
        defer abortRead(&rtxn);
        try testing.expect((try get(&rtxn, "scratch", "k", &synthHash, &synthEq)) == null);
    }
    {
        var wtxn = try beginWrite(&conn);
        defer abortWrite(&wtxn);
        try testing.expect(!(try del(&wtxn, "scratch", "k")));
    }
}

test "put / get: container values (list, map, set) codec round-trip" {
    const list_mod = @import("coll/list.zig");
    const champ = @import("coll/champ.zig");

    const path = try tmpDbPath(testing.allocator, "containers");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    // List
    const lst = try list_mod.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    // Map (use interned keywords so codec can emit textual form).
    const kw = try interner.internKeywordValue("alpha");
    var m = try champ.mapEmpty(&heap);
    m = try champ.mapAssoc(&heap, m, kw, value.fromFixnum(100).?, &synthHash, &synthEq);

    // Set
    var s = try champ.setEmpty(&heap);
    s = try champ.setConj(&heap, s, value.fromFixnum(10).?, &synthHash, &synthEq);
    s = try champ.setConj(&heap, s, value.fromFixnum(20).?, &synthHash, &synthEq);

    var wtxn = try beginWrite(&conn);
    try put(&wtxn, "objects", "list", lst);
    try put(&wtxn, "objects", "map", m);
    try put(&wtxn, "objects", "set", s);
    try commit(&wtxn);

    var rtxn = try beginRead(&conn);
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
    const path = try tmpDbPath(testing.allocator, "reopen");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    // Session 1: write.
    {
        var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
        defer shutdown(&conn);

        var wtxn = try beginWrite(&conn);
        try put(&wtxn, "persistent", "answer", value.fromFixnum(42).?);
        try put(&wtxn, "persistent", "pi", value.fromFloat(3.14));
        try commit(&wtxn);
    }

    // Session 2: reopen + read.
    {
        var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
        defer shutdown(&conn);

        var rtxn = try beginRead(&conn);
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
    const path = try tmpDbPath(testing.allocator, "refinit");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    const r = try ref(&heap, &conn, "users", "alice");
    try testing.expect(r.kind() == .durable_ref);
    try testing.expectEqual(conn.storeId(), refStoreId(r));
    try testing.expectEqualStrings("users", refTreeName(r));
    try testing.expectEqualStrings("alice", refKeyBytes(r));
    try testing.expectEqual(@as(?*Connection, &conn), refConn(r));
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
    const path = try tmpDbPath(testing.allocator, "refio");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    const r = try ref(&heap, &conn, "users", "alice");

    var wtxn = try beginWrite(&conn);
    try putRef(&wtxn, r, value.fromFixnum(123).?);
    try commit(&wtxn);

    {
        var rtxn = try beginRead(&conn);
        defer abortRead(&rtxn);
        const got = try getRef(&rtxn, r, &synthHash, &synthEq);
        try testing.expect(got != null and got.?.kind() == .fixnum);
        try testing.expectEqual(@as(i64, 123), got.?.asFixnum());
    }

    var wtxn2 = try beginWrite(&conn);
    const removed = try delRef(&wtxn2, r);
    try testing.expect(removed);
    try commit(&wtxn2);
}

test "getRef: nullconn ref → ConnectionUnavailable" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const path = try tmpDbPath(testing.allocator, "nullconn");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    // Ref constructed from bytes (no conn).
    const r = try refFromBytes(&heap, 999, "t", "k");

    var rtxn = try beginRead(&conn);
    defer abortRead(&rtxn);
    try testing.expectError(DbError.ConnectionUnavailable, getRef(&rtxn, r, &synthHash, &synthEq));
}

test "getRef: cross-store ref → StoreMismatch" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();

    const path = try tmpDbPath(testing.allocator, "xstore");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    // Ref tagged with a DIFFERENT store_id than conn's, and a
    // different (fake) Connection pointer. `assertRefMatchesConn`
    // should detect the store_id mismatch.
    var fake_conn = conn; // same struct, so same storeId and conn-pointer match
    fake_conn.store_id_lo = 0xBAD_BAD_BAD_BAD_0000;
    // Construct a ref referencing the fake_conn (different
    // store_id + different pointer identity).
    const r = try ref(&heap, &fake_conn, "t", "k");

    var rtxn = try beginRead(&conn);
    defer abortRead(&rtxn);
    try testing.expectError(DbError.StoreMismatch, getRef(&rtxn, r, &synthHash, &synthEq));
}

test "invalid tree name / key: surfaces InvalidTreeName / InvalidKey" {
    const path = try tmpDbPath(testing.allocator, "invalid");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer shutdown(&conn);

    var wtxn = try beginWrite(&conn);
    defer abortWrite(&wtxn);
    try testing.expectError(DbError.InvalidTreeName, put(&wtxn, "", "k", value.nilValue()));
    try testing.expectError(DbError.InvalidKey, put(&wtxn, "t", "", value.nilValue()));
}
