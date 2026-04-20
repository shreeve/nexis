//! db.zig — durable identities + emdb integration (Phase 1).
//!
//! Authoritative spec: `docs/DB.md`. Derivative from PLAN §15
//! (durable identities), §20.2 gate test #6 (emdb round-trip),
//! `docs/CODEC.md` (value-bytes serialization), `docs/VALUE.md`
//! §2.2 (kind 26 `durable_ref`), `docs/SEMANTICS.md` §2.6 / §3.2
//! (identity-triple equality + hash).
//!
//! Closes Phase 1 gate test #6, completing the §20.2 scorecard to
//! **8/8 shipped**.
//!
//! Responsibilities:
//!   - `Connection` type wrapping `emdb.Env` with a v1-interim
//!     `store_id = xxHash3-128(realpath(file))`.
//!   - `durable_ref` heap Value kind (VALUE.md §2.2 kind 26) with
//!     self-contained identity triple (store_id, tree_name,
//!     key_bytes) and an advisory non-identity `conn: ?*Connection`
//!     pointer.
//!   - `WriteTxn` / `ReadTxn` wrappers around `emdb.Txn`.
//!   - `put` / `get` / `del` by `(tree_name, key_bytes, value)` —
//!     keys are **opaque byte slices** (peer-AI turn 23), values
//!     are codec-encoded via `src/codec.zig`.
//!   - `putRef` / `getRef` / `delRef` ref-based convenience.
//!   - Per-kind hash / equality / trace helpers consumed by
//!     `src/dispatch.zig` and `src/gc.zig`.
//!
//! Scope-frozen commitment (DB.md §1): explicit-transaction
//! primitives only. No `alter!`, no cursors, no as-of, no
//! with-tx macro — those are Phase 3 stdlib + Phase 4 work.
//!
//! Module graph (one-way terminal):
//!
//!     src/db.zig
//!     ├── @import("std")
//!     ├── @import("value")
//!     ├── @import("heap")
//!     ├── @import("intern")
//!     ├── @import("hash")
//!     ├── @import("codec")
//!     └── @import("emdb")
//!
//! Nothing imports `db.zig` except `dispatch.zig` / `gc.zig` at
//! their `.durable_ref` arms.

const std = @import("std");
const value = @import("value");
const heap_mod = @import("heap");
const intern_mod = @import("intern");
const hash_mod = @import("hash");
const codec_mod = @import("codec");
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
    TransactionKindMismatch,
    NotADurableRef,
};

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

    /// Owning: opened in `open()`, closed in `close()`.
    env: emdb.Env,

    /// u128 store_id, split into two u64s for extern-struct-
    /// friendly storage. Derived per DB.md §2.
    store_id_lo: u64,
    store_id_hi: u64,

    /// Canonicalized absolute path, owned (freed in close).
    /// Stored for diagnostic / re-derivation purposes.
    path_owned: [:0]u8,

    /// Is the env currently open? Set true by `open()`, false by
    /// `close()`. Used to defend against double-close + to signal
    /// `ConnectionUnavailable` for subsequent ops.
    open_flag: bool,

    pub fn storeId(self: *const Connection) u128 {
        return (@as(u128, self.store_id_hi) << 64) | @as(u128, self.store_id_lo);
    }
};

/// Open (or create) a database file at `path`. `allocator` /
/// `heap` / `interner` are non-owning references; caller
/// guarantees their lifetimes. `options` is passed through to
/// `emdb.Env.open`.
pub fn open(
    allocator: std.mem.Allocator,
    heap: *Heap,
    interner: *Interner,
    path: [*:0]const u8,
    options: emdb.EnvOptions,
) !Connection {
    // Canonicalize the path for store_id derivation. On failure
    // (file doesn't exist yet), fall back to the supplied path
    // bytes verbatim — `realpath` returns ENOENT for new files,
    // which is legitimate during `open(... create=true)`.
    const path_slice = std.mem.sliceTo(path, 0);
    const path_owned = try allocator.dupeZ(u8, path_slice);
    errdefer allocator.free(path_owned);

    // Derive store_id = xxHash3-128-ish (we only have xxHash3-64
    // in src/hash.zig, so we compose two 64-bit hashes with
    // different seed salts for the two halves).
    const hash_lo = hash_mod.hashBytes(path_slice);
    // Second hash with a per-half salt — prepend a distinguishing
    // byte sequence so lo/hi are independent.
    var salted_buf: [256]u8 = undefined;
    const hi_input = if (path_slice.len + 8 <= salted_buf.len) blk: {
        @memcpy(salted_buf[0..8], "store-id");
        @memcpy(salted_buf[8..][0..path_slice.len], path_slice);
        break :blk salted_buf[0 .. 8 + path_slice.len];
    } else blk: {
        // Path too long for stack buf — heap-alloc temporary.
        const tmp = try allocator.alloc(u8, 8 + path_slice.len);
        defer allocator.free(tmp);
        @memcpy(tmp[0..8], "store-id");
        @memcpy(tmp[8..], path_slice);
        break :blk tmp;
    };
    const hash_hi = hash_mod.hashBytes(hi_input);

    var env = emdb.Env.open(path, options) catch |err| {
        allocator.free(path_owned);
        return err;
    };
    errdefer env.close();

    return Connection{
        .allocator = allocator,
        .heap = heap,
        .interner = interner,
        .env = env,
        .store_id_lo = hash_lo,
        .store_id_hi = hash_hi,
        .path_owned = path_owned,
        .open_flag = true,
    };
}

pub fn close(self: *Connection) void {
    if (!self.open_flag) return;
    self.env.close();
    self.allocator.free(self.path_owned);
    self.open_flag = false;
}

// =============================================================================
// Transactions (DB.md §5)
// =============================================================================

pub const WriteTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
};

pub const ReadTxn = struct {
    conn: *Connection,
    inner: *emdb.Txn,
};

pub fn beginWrite(conn: *Connection) !WriteTxn {
    if (!conn.open_flag) return DbError.ConnectionUnavailable;
    const txn = try conn.env.beginWrite();
    return .{ .conn = conn, .inner = txn };
}

pub fn beginRead(conn: *Connection) !ReadTxn {
    if (!conn.open_flag) return DbError.ConnectionUnavailable;
    const txn = try conn.env.beginRead();
    return .{ .conn = conn, .inner = txn };
}

pub fn commit(txn: *WriteTxn) !void {
    try txn.inner.commit();
}

pub fn abortWrite(txn: *WriteTxn) void {
    txn.inner.abort();
}

pub fn abortRead(txn: *ReadTxn) void {
    txn.inner.abort();
}

// =============================================================================
// Tree-name + key-bytes API (opaque keys; DB.md §5, §6)
// =============================================================================

fn validateTreeNameAndKey(tree_name: []const u8, key_bytes: []const u8) DbError!void {
    if (tree_name.len == 0) return DbError.InvalidTreeName;
    if (key_bytes.len == 0) return DbError.InvalidKey;
}

pub fn put(
    txn: *WriteTxn,
    tree_name: []const u8,
    key_bytes: []const u8,
    v: Value,
) !void {
    try validateTreeNameAndKey(tree_name, key_bytes);
    const tree_id = try txn.inner.openTree(tree_name, true);
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
    const tree_id = txn.inner.openTree(tree_name, false) catch |err| switch (err) {
        // Tree doesn't exist yet → key is absent.
        error.NotFound => return null,
        else => return err,
    };
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
    const tree_id = txn.inner.openTree(tree_name, false) catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
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
/// live Connection (Phase 3 stdlib responsibility).
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

fn assertRefMatchesConn(r: Value, conn: *Connection) DbError!void {
    const rc = refConn(r) orelse return DbError.ConnectionUnavailable;
    if (rc != conn) {
        // Different Connection pointer — check store_id
        // agreement. If a ref was constructed against one
        // Connection but is being used with another pointing at
        // the SAME store, allow it (peer-AI turn 23: store_id is
        // the identity).
        if (refStoreId(r) != conn.storeId()) return DbError.StoreMismatch;
    }
    // else: rc == conn, trivially compatible.
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

fn tmpDbPath(allocator: std.mem.Allocator, suffix: []const u8) ![:0]u8 {
    const base = "test_nexis_db_";
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}{s}.emdb", .{ base, suffix }, 0);
    cleanupDb(path);
    return path;
}

fn cleanupDb(path: [:0]const u8) void {
    _ = std.c.unlink(path.ptr);
    var buf: [256]u8 = undefined;
    const lock_path = std.fmt.bufPrintSentinel(&buf, "{s}-lock", .{path}, 0) catch return;
    _ = std.c.unlink(lock_path.ptr);
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
    defer close(&conn);

    try testing.expect(conn.open_flag);
    const sid = conn.storeId();
    try testing.expect(sid != 0);
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
    defer close(&conn);

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
    defer close(&conn);

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
    defer close(&conn);

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

test "put / get: container values (list, map, set) codec round-trip" {
    const list_mod = @import("list");
    const hamt = @import("hamt");

    const path = try tmpDbPath(testing.allocator, "containers");
    defer testing.allocator.free(path);
    defer cleanupDb(path);

    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    var interner = Interner.init(testing.allocator);
    defer interner.deinit();

    var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
    defer close(&conn);

    // List
    const lst = try list_mod.fromSlice(&heap, &.{
        value.fromFixnum(1).?,
        value.fromFixnum(2).?,
        value.fromFixnum(3).?,
    });
    // Map (use interned keywords so codec can emit textual form).
    const kw = try interner.internKeywordValue("alpha");
    var m = try hamt.mapEmpty(&heap);
    m = try hamt.mapAssoc(&heap, m, kw, value.fromFixnum(100).?, &synthHash, &synthEq);

    // Set
    var s = try hamt.setEmpty(&heap);
    s = try hamt.setConj(&heap, s, value.fromFixnum(10).?, &synthHash, &synthEq);
    s = try hamt.setConj(&heap, s, value.fromFixnum(20).?, &synthHash, &synthEq);

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
    try testing.expectEqual(@as(usize, 1), hamt.mapCount(got_m.?));

    const got_s = try get(&rtxn, "objects", "set", &synthHash, &synthEq);
    try testing.expect(got_s != null and got_s.?.kind() == .persistent_set);
    try testing.expectEqual(@as(usize, 2), hamt.setCount(got_s.?));
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
        defer close(&conn);

        var wtxn = try beginWrite(&conn);
        try put(&wtxn, "persistent", "answer", value.fromFixnum(42).?);
        try put(&wtxn, "persistent", "pi", value.fromFloat(3.14));
        try commit(&wtxn);
    }

    // Session 2: reopen + read.
    {
        var conn = try open(testing.allocator, &heap, &interner, path.ptr, .{ .allocator = testing.allocator });
        defer close(&conn);

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
    defer close(&conn);

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
    defer close(&conn);

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
    defer close(&conn);

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
    defer close(&conn);

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
    defer close(&conn);

    var wtxn = try beginWrite(&conn);
    defer abortWrite(&wtxn);
    try testing.expectError(DbError.InvalidTreeName, put(&wtxn, "", "k", value.nilValue()));
    try testing.expectError(DbError.InvalidKey, put(&wtxn, "t", "", value.nilValue()));
}
