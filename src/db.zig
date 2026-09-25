//! db.zig — durable identities + emdb integration.
//!
//! Authoritative spec: `docs/DB.md`. Derivative from PLAN §15
//! (durable identities), §20.2 gate test #6 (emdb round-trip),
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
//!   - `WriteTxn` / `ReadTxn` wrappers around `emdb.Txn`.
//!   - `put` / `get` / `del` by `(tree_name, key_bytes, value)` —
//!     keys are **opaque byte slices**, values
//!     are codec-encoded via `src/codec.zig`.
//!   - `putRef` / `getRef` / `delRef` ref-based convenience.
//!   - Per-kind hash / equality / trace helpers consumed by
//!     `src/dispatch.zig` and `src/gc.zig`.
//!
//! Scope (DB.md §1): explicit-transaction primitives only. No
//! `alter!`, no cursors, no as-of, no with-tx macro live here.
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
//! Nothing imports `db.zig` except `dispatch.zig` / `gc.zig` at
//! their `.durable_ref` arms.

const std = @import("std");
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
    /// `close` of a connection with a transaction still open.
    TransactionsOpen,
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
/// Files are told apart by `(st_dev, st_ino)`, so a symlink, a hard
/// link or `./x` finds the file already open, and a copy is another
/// file. The environment opens at the canonical path, so every
/// process that names the file shares one lock file.
///
/// The runtime is single-threaded, so the list of open files is a
/// plain global. The environment lives on the allocator of the first
/// open, which must outlive every connection to the file.
pub const StoreFile = struct {
    env: emdb.Env,
    /// Canonical absolute path the environment was opened at, owned.
    path: [:0]u8,
    dev: std.c.dev_t,
    ino: std.c.ino_t,
    /// Connections and stores holding the file; the last `release`
    /// closes the environment.
    refs: u32,
    next: ?*StoreFile,

    var open_files: ?*StoreFile = null;

    /// The open file at `path`, or the file opened (or created) now
    /// with `options`. A file this process may read but not write
    /// opens read-only.
    pub fn acquire(path: [*:0]const u8, options: emdb.EnvOptions) !*StoreFile {
        const allocator = options.allocator;
        const canonical = try canonicalPath(allocator, path);
        errdefer allocator.free(canonical);
        var st: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, canonical.ptr, &st, 0) == 0) {
            var it = open_files;
            while (it) |f| : (it = f.next) {
                if (f.dev == st.dev and f.ino == st.ino) {
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
        if (std.c.fstat(self.env.inner.dataFile.fd, &st) != 0) return error.OpenFailed;
        self.path = canonical;
        self.dev = st.dev;
        self.ino = st.ino;
        self.refs = 1;
        self.next = open_files;
        open_files = self;
        return self;
    }

    /// Drop one hold; the last closes the environment and frees the
    /// file.
    pub fn release(self: *StoreFile) void {
        self.refs -= 1;
        if (self.refs > 0) return;
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
        return self.env.beginWriteWith(options);
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

    /// Transactions begun and not yet committed or aborted; `close`
    /// refuses while any is open, so no transaction outlives its env.
    open_txns: u32 = 0,

    /// Named-tree handles this connection has resolved, keyed by
    /// owned copies of the tree names. A `TreeId` is fixed for the
    /// life of the environment (emdb INV-SUB03): the same name
    /// yields the same handle in every transaction. Each
    /// transaction still loads the tree behind a handle once
    /// before using it; `WriteTxn.opened` / `ReadTxn.opened`
    /// track that.
    tree_ids: std.StringHashMapUnmanaged(emdb.TreeId),

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
    };
}

/// Close the connection. A closed connection stays a valid struct:
/// refs and transaction handles that name it read `open_flag` and
/// report it closed. A second close does nothing; a close while a
/// transaction of the connection is open is refused, so no emdb
/// transaction outlives its env.
pub fn close(self: *Connection) DbError!void {
    if (self.open_txns != 0) return DbError.TransactionsOpen;
    shutdown(self);
}

/// Close the connection whatever is still open: teardown of the whole
/// VM, when nothing can use the connection again.
pub fn shutdown(self: *Connection) void {
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
};

pub const ReadTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
    /// Trees this transaction has loaded; see `treeId`.
    opened: TreeSet = TreeSet.initEmpty(),
};

pub fn beginWrite(conn: *Connection) !WriteTxn {
    if (!conn.open_flag) return DbError.ConnectionUnavailable;
    const txn = try conn.file.beginWrite(.{});
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
    txn.inner.commit() catch |err| {
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
/// context). The `conn` pointer is null; I/O ops on this ref will
/// return `error.ConnectionUnavailable` until it's paired with a
/// live Connection (the stdlib's responsibility).
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
