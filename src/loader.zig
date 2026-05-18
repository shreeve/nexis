// =============================================================================
// src/loader.zig — Phase 3.6 namespace loader
// =============================================================================
//
// Per peer-AI turns 69 + 71: `(require ...)` resolves a namespace
// name to a `.nx` file, parses + compiles + evaluates it in its
// own declared namespace, and returns control to the caller's
// namespace. Idempotent: re-requiring an already-loaded ns is a
// no-op. Cycle detection via a `loading` set.
//
// v1 SCOPE (peer-AI turn 71 §2):
//   - `(require 'my.ns)` and `(require '[my.ns :as alias])`
//   - Ns-to-file mapping: `my.app.foo` → `my/app/foo.nx`
//   - Load path: each entry is a directory to search
//   - Idempotent (`loaded_set`) + cycle detection (`loading_set`)
//   - Caller's current namespace restored after load
//   - Required file's `(ns ...)` declaration MUST match the
//     requested name (else `LoadError.NamespaceMismatch`)
//
// DEFERRED:
//   - `:refer`, `:rename`, `:exclude`, `:reload`
//   - Relative requires
//   - Private vars
//   - Classpath / package semantics
//
// The loader is wired into the expander via a callback on
// `ExpandContext.load_callback` (set by the CLI / test harness).
// Approach mirrors the compile-eval callback pattern from Phase
// 3.2: the expander doesn't depend on compile/loader machinery
// directly; just calls through an opaque user_data pointer.

const std = @import("std");
const reader_mod = @import("reader");
const intern_mod = @import("intern");
const expand_mod = @import("expand");
const compile_mod = @import("compile");
const vm_mod = @import("vm");
const value_mod = @import("value");

pub const LoadError = error{
    /// The requested namespace name could not be mapped to a
    /// readable file on any entry of the load path.
    FileNotFound,
    /// File found but I/O error reading it.
    FileReadError,
    /// `(require ...)` was passed a malformed argument (not a
    /// quoted symbol or quoted `[ns :as alias]` vector).
    MalformedRequire,
    /// `(require ...)` would form a cycle (namespace is already
    /// in the loading set). v1 surfaces this; future commits may
    /// add reload-detection semantics.
    CyclicRequire,
    /// The loaded file's `(ns ...)` declaration differs from
    /// the requested namespace name. Catches typos and rename
    /// errors early.
    NamespaceMismatch,
    /// Underlying compile / parse / runtime error during load.
    LoadCompileFailed,
    OutOfMemory,
};

/// Phase 3.6: stable load context. Owns the loaded-set and
/// loading-set across all `(require ...)` calls in a compilation
/// session. CLI creates one at startup; tests can create their
/// own. The expander invokes `loadNamespaceCallback` indirectly
/// through `ExpandContext.load_callback`.
pub const Loader = struct {
    allocator: std.mem.Allocator,
    /// Allocator for compiled artifacts that must outlive the
    /// per-form arena. Typically `vm.runtime_arena.allocator()`.
    persistent_allocator: std.mem.Allocator,
    /// Zig 0.16 I/O context (needed for std.Io.Dir file ops).
    io: std.Io,
    /// Directories to search for `.nx` files (in order).
    load_paths: []const []const u8,
    /// Shared VM + registry + interner + macros.
    vm: *vm_mod.VM,
    interner: *intern_mod.Interner,
    registry: *vm_mod.NamespaceRegistry,
    host_macros: *const expand_mod.HostMacroTable,
    /// Idempotent-load set: ns names already fully loaded.
    /// Keys are arena-owned (we dupe on insertion).
    loaded: std.StringHashMap(void),
    /// Cycle detection set: ns names currently in the middle
    /// of loading. A nested `(require ...)` for a name already
    /// here raises `CyclicRequire`.
    loading: std.StringHashMap(void),

    pub fn init(
        allocator: std.mem.Allocator,
        persistent_allocator: std.mem.Allocator,
        io: std.Io,
        load_paths: []const []const u8,
        vm: *vm_mod.VM,
        interner: *intern_mod.Interner,
        registry: *vm_mod.NamespaceRegistry,
        host_macros: *const expand_mod.HostMacroTable,
    ) Loader {
        return .{
            .allocator = allocator,
            .persistent_allocator = persistent_allocator,
            .io = io,
            .load_paths = load_paths,
            .vm = vm,
            .interner = interner,
            .registry = registry,
            .host_macros = host_macros,
            .loaded = std.StringHashMap(void).init(allocator),
            .loading = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Loader) void {
        self.loaded.deinit();
        self.loading.deinit();
        self.* = undefined;
    }

    /// Load `ns_name` from disk into the registry. Idempotent.
    /// On success the namespace is registered AND populated.
    /// The caller's current namespace is preserved (saved before
    /// load, restored after).
    pub fn loadNamespace(self: *Loader, ns_name: []const u8) LoadError!void {
        // Already loaded → no-op.
        if (self.loaded.contains(ns_name)) return;
        // Already loading → cycle.
        if (self.loading.contains(ns_name)) return LoadError.CyclicRequire;

        // Map ns name to file: dots → slashes, ".nx" suffix.
        const rel_path = nsNameToRelPath(self.allocator, ns_name) catch return LoadError.OutOfMemory;
        defer self.allocator.free(rel_path);

        // Search load paths for the file.
        const file_path = searchLoadPaths(self.allocator, self.io, self.load_paths, rel_path) catch return LoadError.OutOfMemory;
        const path = file_path orelse return LoadError.FileNotFound;
        defer self.allocator.free(path);

        // Read the file source via Zig 0.16 std.Io.Dir API.
        const source = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(16 * 1024 * 1024),
        ) catch return LoadError.FileReadError;
        defer self.allocator.free(source);

        // Dupe ns_name into a stable storage so `loaded` set
        // entries outlive the requesting expander's call (the
        // borrowed `ns_name` slice may be in a per-form arena).
        const stable_name = self.persistent_allocator.dupe(u8, ns_name) catch return LoadError.OutOfMemory;
        self.loading.put(stable_name, {}) catch return LoadError.OutOfMemory;
        // On any return path, unconditionally remove from loading.
        defer _ = self.loading.remove(stable_name);

        // Save caller's current namespace; restore on exit.
        const saved_current = self.registry.current;
        defer self.registry.current = saved_current;

        // Compile + evaluate each top-level form in the source
        // file. The file's `(ns ...)` form (which we require) is
        // the FIRST form; it must set the current ns to the
        // requested name. We verify after.
        try self.evalFile(stable_name, source, path);

        // Mark as loaded.
        self.loaded.put(stable_name, {}) catch return LoadError.OutOfMemory;
    }

    fn evalFile(self: *Loader, ns_name: []const u8, source: []const u8, path: []const u8) LoadError!void {
        _ = path;
        var parse_result = reader_mod.parser.parseProgram(self.allocator, source) catch return LoadError.LoadCompileFailed;
        defer parse_result.parser.deinit();
        var rdr = reader_mod.Reader.init(self.allocator, source);
        defer rdr.deinit();
        const forms = rdr.readProgram(parse_result.sexp) catch return LoadError.LoadCompileFailed;

        // Validate first form is `(ns NAME)` matching ns_name.
        if (forms.len == 0) return LoadError.NamespaceMismatch;
        if (!firstFormIsNs(forms[0], ns_name)) return LoadError.NamespaceMismatch;

        // Use the persistent allocator as the compile arena so
        // every def'd Var + Closure + Routine outlives the load.
        const ra = self.persistent_allocator;

        for (forms) |form| {
            const current_ns = self.registry.current;
            const compiled = compile_mod.compileFormFullWithMacrosSpanPersistentRegistry(
                ra,
                form,
                current_ns,
                self.interner,
                self.host_macros,
                null,
                ra,
                self.registry,
            ) catch return LoadError.LoadCompileFailed;
            const routine = compiled.toRoutine("loader");
            self.vm.frames.items[0].routine = &routine;
            self.vm.frames.items[0].pc = 0;
            self.vm.frames.items[0].slot_count = routine.slot_count;
            self.vm.halted = false;
            if (self.vm.stack.items.len < routine.slot_count) {
                self.vm.stack.appendNTimes(self.vm.allocator, value_mod.nilValue(), routine.slot_count - self.vm.stack.items.len) catch return LoadError.OutOfMemory;
            }
            _ = self.vm.run() catch return LoadError.LoadCompileFailed;
        }
    }

    /// Phase 3.6 callback: expander's `ExpandContext.load_callback`
    /// is set to this. Translates the opaque `user_data` back to
    /// `*Loader` + invokes `loadNamespace`.
    pub fn loadCallback(user_data: *anyopaque, ns_name: []const u8) anyerror!void {
        const self: *Loader = @ptrCast(@alignCast(user_data));
        try self.loadNamespace(ns_name);
    }
};

/// Map `my.app.foo` → `my/app/foo.nx`. Caller owns returned slice.
fn nsNameToRelPath(allocator: std.mem.Allocator, ns_name: []const u8) ![]u8 {
    // Output length = input length (dots → slashes, same chars)
    //                 + len(".nx") = +3.
    var buf = try allocator.alloc(u8, ns_name.len + 3);
    var i: usize = 0;
    while (i < ns_name.len) : (i += 1) {
        buf[i] = if (ns_name[i] == '.') '/' else ns_name[i];
    }
    @memcpy(buf[ns_name.len..], ".nx");
    return buf;
}

/// Search `load_paths` for `rel_path`. Returns the first
/// existing path, or null if not found. Caller owns the
/// returned slice.
fn searchLoadPaths(allocator: std.mem.Allocator, io: std.Io, load_paths: []const []const u8, rel_path: []const u8) !?[]u8 {
    for (load_paths) |dir| {
        const candidate = try std.fs.path.join(allocator, &.{ dir, rel_path });
        // Try to stat via Zig 0.16 std.Io.Dir API. If accessible, return.
        std.Io.Dir.cwd().access(io, candidate, .{}) catch {
            allocator.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Returns true iff `form` is `(ns NAME)` where NAME (as an
/// unqualified symbol) equals `expected_ns_name`. Used to
/// validate that a required file declares the namespace the
/// caller asked for.
fn firstFormIsNs(form: *const reader_mod.Form, expected_ns_name: []const u8) bool {
    if (form.datum != .list) return false;
    const items = form.datum.list;
    if (items.len != 2) return false;
    const head = items[0];
    const name = items[1];
    if (head.datum != .symbol or head.datum.symbol.ns != null) return false;
    if (!std.mem.eql(u8, head.datum.symbol.name, "ns")) return false;
    if (name.datum != .symbol or name.datum.symbol.ns != null) return false;
    return std.mem.eql(u8, name.datum.symbol.name, expected_ns_name);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "loader: nsNameToRelPath" {
    const cases = .{
        .{ "foo", "foo.nx" },
        .{ "foo.bar", "foo/bar.nx" },
        .{ "a.b.c.d", "a/b/c/d.nx" },
    };
    inline for (cases) |c| {
        const out = try nsNameToRelPath(testing.allocator, c[0]);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(c[1], out);
    }
}
