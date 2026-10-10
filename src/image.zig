//! image.zig — the standard library as a precompiled image.
//!
//! The build boots the embedded `src/stdlib/*.nx` sources once, on the
//! host, and writes what they leave behind (`write`): every namespace
//! and the entries of its map, every Var with its root, metadata and
//! flags, the protocols and record types, the routines the closures
//! run, and the heap values all of these reach. Every binary embeds
//! that image, and `stdlib.boot` loads it (`load`) instead of reading,
//! expanding, compiling and running the sources (docs/STDLIB.md §1).
//!
//! The image is a build product, never read by another build: it is
//! not the codec (PLAN §23 #25) and has no compatibility to keep. Its
//! header names the format and fingerprints the sources it was made
//! from and the layouts below (`fingerprint`); `matches` refuses any
//! other image, and the caller boots the sources instead. A value the
//! writer cannot carry (a kind outside `ObjTag`, a list view, a Var
//! inside a `binding`) fails the build, and `verify` compares a loaded
//! image with the boot that wrote it, so a difference fails the build
//! too instead of loading silently.
//!
//! Layout, little-endian, in the order `load` reads it:
//!
//!   header       magic, version, fingerprint, the gensyms the boot
//!                made (`Counted`), the totals the loader allocates up
//!                front (`Totals`)
//!   names        keyword and symbol texts, interned in order
//!   namespaces   name and parent, parents first
//!   types        record types and protocols, registered in order
//!   vars         every Var the image names: home namespace and name
//!   entries      per namespace, its map's capacity and its entries
//!                in the order that puts each back in its slot
//!   natives      the Var each native was installed in, and its name
//!   objects      heap blocks, each after the blocks it reaches; a
//!                cell or atom first as an empty shell (`fills`)
//!   routines     code, constants, Var table, captures, tries, spans,
//!                arity table
//!   arities      each arity table: its fixed members and rest clause
//!   fills        each shell's contents
//!   states       each Var's root, metadata and flags
//!   aliases      per namespace
//!   impls        each protocol method's implementations
//!
//! A value is a `RefTag` and its operand: an immediate's bits, a name
//! or Var or native or object index.

const std = @import("std");
const stack = @import("stack.zig");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");
const intern_mod = @import("intern.zig");
const string_mod = @import("string.zig");
const regex_mod = @import("regex.zig");
const atom_mod = @import("atom.zig");
const vector_mod = @import("coll/vector.zig");
const list_mod = @import("coll/list.zig");
const bignum_mod = @import("bignum.zig");
const protocol_mod = @import("protocol.zig");
const champ_mod = @import("coll/champ.zig");
const record_mod = @import("record.zig");
const dispatch_mod = @import("dispatch.zig");
const vm_mod = @import("vm.zig");

const Allocator = std.mem.Allocator;
const Value = value_mod.Value;
const Kind = value_mod.Kind;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;
const VM = vm_mod.VM;
const Var = vm_mod.Var;
const Namespace = vm_mod.Namespace;
const Routine = vm_mod.Routine;
const NativeFn = vm_mod.NativeFn;
const UpvalCell = vm_mod.UpvalCell;

/// An embedded source and the namespace it boots into.
pub const Source = struct { ns: []const u8, info: vm_mod.SourceInfo };

const magic = "nexisimg";
const version: u32 = 3;

// The structs the image carries field by field. A field added to one
// of them must be carried (or deliberately left at its default) here
// before the tree compiles again, so no image ever drops one.
comptime {
    expectFields(Routine, &.{ "code", "consts", "capture_descs", "tries", "slot_count", "fixed_arity", "variadic", "arities", "upvalue_count", "var_table", "name", "spans", "origin", "source" });
    expectFields(Var, &.{ "name", "ns", "root", "bound", "macro", "meta", "dynamic", "thread_value", "thread_bound" });
    expectFields(vm_mod.CaptureDescriptor, &.{ "routine", "sources" });
    expectFields(vm_mod.Arities, &.{ "fixed", "rest" });
    expectFields(vm_mod.Try, &.{ "catch_pc", "finally_pc" });
    expectFields(vm_mod.SpanEntry, &.{ "pc", "span" });
    expectFields(UpvalCell, &.{ "value", "initialized" });
    expectFields(atom_mod.AtomBox, &.{ "value", "validator", "watches", "in_flight", "_pad" });
    expectFields(vm_mod.ProtocolMethod, &.{ "name_id", "name", "impls", "default_impl" });
    expectFields(vm_mod.ProtocolEntry, &.{ "id", "ns_name", "name", "methods" });
    expectFields(vm_mod.RecordTypeEntry, &.{ "id", "ns_name", "type_name", "field_names" });
    expectFields(Namespace, &.{ "name", "parent", "registry", "aliases", "map_allocator", "var_allocator", "vars" });
    expectFields(vm_mod.Closure, &.{ "routine", "upvalues" });
    expectFields(record_mod.RecordBody, &.{ "type_id", "_pad", "fields" });
    std.debug.assert(@import("builtin").target.cpu.arch.endian() == .little);
    std.debug.assert(@sizeOf(vm_mod.Inst) == 8);
}

fn expectFields(comptime T: type, comptime names: []const []const u8) void {
    const have = @typeInfo(T).@"struct".field_names;
    if (have.len != names.len) @compileError("image.zig: " ++ @typeName(T) ++ " changed shape; carry its fields in the image (docs/STDLIB.md §1)");
    for (have, names) |h, n| if (!std.mem.eql(u8, h, n)) @compileError("image.zig: " ++ @typeName(T) ++ " has field " ++ h ++ "; carry it in the image (docs/STDLIB.md §1)");
}

/// The image's identity: its format, the sources it boots, and the
/// shapes it writes. Any change to one is another image.
pub fn fingerprint(sources: []const Source) u64 {
    var h = std.hash.Wyhash.init(version);
    for (sources) |s| for ([_][]const u8{ s.ns, s.info.path, s.info.text }) |part| {
        h.update(std.mem.asBytes(&@as(u64, part.len)));
        h.update(part);
    };
    const shapes = .{ Routine, Var, vm_mod.Inst, Value, HeapHeader, atom_mod.AtomBox, Kind };
    inline for (shapes) |T| h.update(std.mem.asBytes(&@as(u64, @sizeOf(T))));
    inline for (@typeInfo(Kind).@"enum".field_names) |name| h.update(name);
    return h.final();
}

/// The names a boot of the sources generates: the expander's
/// auto-gensyms and the `gensym` calls. Both counters are the
/// process's, and a boot from the image advances them by as many.
pub const Counted = struct { auto_gensyms: u64, gensyms: u64 };

/// What `load` allocates once for the whole image.
const Totals = struct {
    routines: u32 = 0,
    code: u32 = 0,
    consts: u32 = 0,
    var_refs: u32 = 0,
    captures: u32 = 0,
    capture_sources: u32 = 0,
    tries: u32 = 0,
    spans: u32 = 0,
    arities: u32 = 0,
    arity_slots: u32 = 0,
    objects: u32 = 0,
};

const header_len = magic.len + 4 + 8 + 16 + @typeInfo(Totals).@"struct".field_names.len * 4;

/// Whether `bytes` is an image of `sources` that this build wrote.
pub fn matches(bytes: []const u8, sources: []const Source) bool {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return false;
    var in: In = .{ .bytes = bytes, .pos = magic.len };
    const v = in.int(u32) catch return false;
    const f = in.int(u64) catch return false;
    return v == version and f == fingerprint(sources);
}

const RefTag = enum(u8) { nil, immediate, keyword, symbol, object, native, var_ };
const ObjTag = enum(u8) { cell, atom, string, bignum, regex, vector, empty_list, cons, map, set, function, protocol, protocol_fn, record };
const EntryTag = enum(u8) {
    /// A Var keyed by its own name storage: the namespace's own.
    named,
    /// Another namespace's Var under a name of this namespace.
    referral,
};
const no_index = std.math.maxInt(u32);

// =============================================================================
// Reading and writing bytes
// =============================================================================

pub const LoadError = error{
    OutOfMemory,
    /// The image is not well formed, or does not describe this
    /// runtime: an image from this build never is.
    Corrupt,
    /// A routine the image carries does not verify (docs/VM.md §5).
    UnfitRoutine,
};

const In = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *In, n: usize) LoadError![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Corrupt;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }

    fn int(self: *In, comptime T: type) LoadError!T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn byte(self: *In) LoadError!u8 {
        return (try self.take(1))[0];
    }

    fn str(self: *In) LoadError![]const u8 {
        return self.take(try self.int(u32));
    }

    fn index(self: *In, len: usize) LoadError!u32 {
        const i = try self.int(u32);
        if (i >= len) return error.Corrupt;
        return i;
    }

    fn tag(self: *In, comptime T: type) LoadError!T {
        return std.enums.fromInt(T, try self.byte()) orelse error.Corrupt;
    }
};

const Out = struct {
    gpa: Allocator,
    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *Out) void {
        self.list.deinit(self.gpa);
    }

    fn int(self: *Out, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.list.appendSlice(self.gpa, &b);
    }

    fn byte(self: *Out, b: u8) !void {
        try self.list.append(self.gpa, b);
    }

    fn str(self: *Out, s: []const u8) !void {
        try self.int(u32, @intCast(s.len));
        try self.list.appendSlice(self.gpa, s);
    }

    fn count(self: *Out, n: usize) !void {
        try self.int(u32, @intCast(n));
    }
};

// =============================================================================
// Writing
// =============================================================================

/// Where each native was installed: the Var the native tables bound
/// it to, before any source ran. The writer names a native by that
/// Var; `load` reads the native back out of it before the image sets
/// any root.
pub const NativeIndex = struct {
    map: std.AutoHashMapUnmanaged(*const NativeFn, *Var) = .empty,

    pub fn scan(gpa: Allocator, registry: *vm_mod.NamespaceRegistry) !NativeIndex {
        var self: NativeIndex = .{};
        errdefer self.deinit(gpa);
        var namespaces = registry.map.valueIterator();
        while (namespaces.next()) |ns| {
            var vars = ns.*.vars.valueIterator();
            while (vars.next()) |v| if (v.*.bound and v.*.root.kind() == .native_fn) {
                const gop = try self.map.getOrPut(gpa, vm_mod.asNativeFn(v.*.root));
                if (!gop.found_existing) gop.value_ptr.* = v.*;
            };
        }
        return self;
    }

    pub fn deinit(self: *NativeIndex, gpa: Allocator) void {
        self.map.deinit(gpa);
    }

    /// Whether `v` holds what the native tables installed in it and
    /// nothing the sources changed.
    fn untouched(self: *const NativeIndex, v: *const Var) bool {
        if (!v.bound or v.macro or v.dynamic or v.meta.kind() != .nil or v.root.kind() != .native_fn) return false;
        return self.map.get(vm_mod.asNativeFn(v.root)) == v;
    }
};

pub const WriteError = error{
    OutOfMemory,
    StackOverflow,
    /// The boot left a value the image cannot carry; `Writer.why`
    /// says which.
    Unsupported,
};

/// The image of what booting `sources` left in `vm`, which booted
/// them after installing the natives `natives` records. The caller
/// owns the bytes.
pub fn write(gpa: Allocator, vm: *VM, natives: *const NativeIndex, sources: []const Source, counted: Counted, why: *[]const u8) WriteError![]u8 {
    var w: Writer = .{ .gpa = gpa, .vm = vm, .interner = vm.ensureInterner(), .natives = natives, .sources = sources, .counted = counted };
    defer w.deinit();
    const bytes = w.run() catch |err| {
        why.* = w.why;
        return err;
    };
    return bytes;
}

const Writer = struct {
    gpa: Allocator,
    vm: *VM,
    interner: *intern_mod.Interner,
    natives: *const NativeIndex,
    sources: []const Source,
    counted: Counted,
    why: []const u8 = "",
    totals: Totals = .{},

    keywords: Names = .{},
    symbols: Names = .{},
    namespaces: std.ArrayList(*Namespace) = .empty,
    vars: Indexed(*Var) = .{},
    native_refs: Indexed(*const NativeFn) = .{},
    routines: Indexed(*const Routine) = .{},
    arities: Indexed(*const vm_mod.Arities) = .{},
    /// Heap blocks by address, each with the tag of the Values that
    /// name it.
    objects: std.AutoHashMapUnmanaged(usize, struct { id: u32, tag: u64 }) = .empty,
    /// Cells and atoms whose contents `fills` still owes.
    shells: std.ArrayList(Value) = .empty,

    object_out: Out = undefined,
    routine_out: Out = undefined,
    fill_out: Out = undefined,
    state_out: Out = undefined,
    impl_out: Out = undefined,

    const Names = struct {
        ids: std.AutoHashMapUnmanaged(u32, u32) = .empty,
        texts: std.ArrayList([]const u8) = .empty,
    };

    fn Indexed(comptime T: type) type {
        return struct {
            ids: std.AutoHashMapUnmanaged(T, u32) = .empty,
            items: std.ArrayList(T) = .empty,

            fn deinit(self: *@This(), gpa: Allocator) void {
                self.ids.deinit(gpa);
                self.items.deinit(gpa);
            }

            /// The index of `x`, added when new.
            fn of(self: *@This(), gpa: Allocator, x: T) !u32 {
                const gop = try self.ids.getOrPut(gpa, x);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(self.items.items.len);
                    try self.items.append(gpa, x);
                }
                return gop.value_ptr.*;
            }
        };
    }

    fn deinit(w: *Writer) void {
        inline for (.{ &w.keywords, &w.symbols }) |n| {
            n.ids.deinit(w.gpa);
            n.texts.deinit(w.gpa);
        }
        w.namespaces.deinit(w.gpa);
        w.vars.deinit(w.gpa);
        w.native_refs.deinit(w.gpa);
        w.routines.deinit(w.gpa);
        w.arities.deinit(w.gpa);
        w.objects.deinit(w.gpa);
        w.shells.deinit(w.gpa);
    }

    fn unsupported(w: *Writer, why: []const u8) WriteError {
        w.why = why;
        return error.Unsupported;
    }

    fn run(w: *Writer) WriteError![]u8 {
        const gpa = w.gpa;
        const registry = try w.vm.ensureRegistry();
        w.object_out = .{ .gpa = gpa };
        defer w.object_out.deinit();
        w.routine_out = .{ .gpa = gpa };
        defer w.routine_out.deinit();
        w.fill_out = .{ .gpa = gpa };
        defer w.fill_out.deinit();
        w.state_out = .{ .gpa = gpa };
        defer w.state_out.deinit();
        w.impl_out = .{ .gpa = gpa };
        defer w.impl_out.deinit();
        var entry_out: Out = .{ .gpa = gpa };
        defer entry_out.deinit();
        var alias_out: Out = .{ .gpa = gpa };
        defer alias_out.deinit();

        // Namespaces: the sources' own in boot order, then the rest by
        // name, each after its parent.
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var it = registry.map.keyIterator();
        while (it.next()) |k| try names.append(gpa, k.*);
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        try w.addNamespace(registry.core);
        for (w.sources) |s| try w.addNamespace(registry.lookupNs(s.ns).?);
        for (names.items) |n| try w.addNamespace(registry.lookupNs(n).?);

        // Entries, states and aliases, namespace by namespace. A map's
        // entries go in the order of its slots from the one after an
        // empty slot round to it: inserted in that order into a table
        // of the same capacity, each lands in the slot it had, so the
        // loaded map iterates in the order this one does (`readVars`).
        var states: u32 = 0;
        var slots: std.ArrayList(struct { slot: u32, key: []const u8, v: *Var }) = .empty;
        defer slots.deinit(gpa);
        for (w.namespaces.items) |ns| {
            slots.clearRetainingCapacity();
            var vars = ns.vars.iterator();
            var empty: u32 = 0;
            while (vars.next()) |e| {
                const slot = vars.index - 1;
                if (slot == empty) empty += 1;
                try slots.append(gpa, .{ .slot = slot, .key = e.key_ptr.*, .v = e.value_ptr.* });
            }
            const first = for (slots.items, 0..) |e, i| {
                if (e.slot > empty) break i;
            } else slots.items.len;
            try entry_out.int(u32, ns.vars.capacity());
            try entry_out.count(slots.items.len);
            for (slots.items[first..]) |e| try w.entry(&entry_out, ns, e.key, e.v, &states);
            for (slots.items[0..first]) |e| try w.entry(&entry_out, ns, e.key, e.v, &states);
            try alias_out.count(ns.aliases.count());
            var aliases = ns.aliases.iterator();
            while (aliases.next()) |a| {
                try alias_out.str(a.key_ptr.*);
                try alias_out.str(a.value_ptr.*);
            }
        }

        // Protocol implementations.
        for (w.vm.protocol_registry.items) |*p| for (p.methods.items) |*m| {
            try w.impl_out.count(m.impls.count());
            var impls = m.impls.iterator();
            while (impls.next()) |i| {
                try w.impl_out.byte(@backingInt(i.key_ptr.tag));
                try w.impl_out.int(u32, i.key_ptr.id);
                try w.ref(&w.impl_out, i.value_ptr.*);
            }
            try w.impl_out.byte(@intFromBool(m.default_impl != null));
            if (m.default_impl) |d| try w.ref(&w.impl_out, d);
        };

        // What the values above reached: routine bodies and shell
        // contents, until neither adds more.
        var fills: u32 = 0;
        var done_routines: usize = 0;
        while (true) {
            if (done_routines < w.routines.items.items.len) {
                try w.routineBody(w.routines.items.items[done_routines]);
                done_routines += 1;
            } else if (w.shells.pop()) |shell| {
                fills += 1;
                try w.fill(shell);
            } else break;
        }
        w.totals.routines = @intCast(w.routines.items.items.len);
        w.totals.arities = @intCast(w.arities.items.items.len);

        // Each arity table, its members by index: every one was
        // enqueued, and so written, with the first.
        var arity_out: Out = .{ .gpa = gpa };
        defer arity_out.deinit();
        for (w.arities.items.items) |a| {
            try arity_out.count(a.fixed.len);
            for (a.fixed) |m| try arity_out.int(u32, if (m) |r| w.routines.ids.get(r).? else no_index);
            try arity_out.int(u32, if (a.rest) |r| w.routines.ids.get(r).? else no_index);
            w.totals.arity_slots += @intCast(a.fixed.len);
        }

        // The last names and Vars, before the tables that list them.
        var method_names: std.ArrayList(u32) = .empty;
        defer method_names.deinit(gpa);
        for (w.vm.protocol_registry.items) |p| for (p.methods.items) |m| try method_names.append(gpa, try w.keyword(m.name_id));
        var native_vars: std.ArrayList(u32) = .empty;
        defer native_vars.deinit(gpa);
        for (w.native_refs.items.items) |d| try native_vars.append(gpa, try w.varIndex(w.natives.map.get(d) orelse return w.unsupported("a native no table installs")));

        // Assemble.
        var out: Out = .{ .gpa = gpa };
        errdefer out.deinit();
        try out.list.appendSlice(gpa, magic);
        try out.int(u32, version);
        try out.int(u64, fingerprint(w.sources));
        try out.int(u64, w.counted.auto_gensyms);
        try out.int(u64, w.counted.gensyms);
        inline for (@typeInfo(Totals).@"struct".field_names) |f| try out.int(u32, @field(w.totals, f));
        inline for (.{ &w.keywords, &w.symbols }) |names_| {
            try out.count(names_.texts.items.len);
            for (names_.texts.items) |t| try out.str(t);
        }
        try out.count(w.namespaces.items.len);
        for (w.namespaces.items) |ns| {
            try out.str(ns.name);
            try out.int(u32, if (ns.parent) |p| w.namespaceIndex(p) else no_index);
        }
        try out.count(w.vm.record_registry.items.len);
        for (w.vm.record_registry.items) |r| {
            try out.str(r.ns_name);
            try out.str(r.type_name);
            try out.count(r.field_names.len);
            for (r.field_names) |f| try out.str(f);
        }
        try out.int(u32, w.vm.reduced_type_id orelse no_index);
        try out.count(w.vm.protocol_registry.items.len);
        var next_method: usize = 0;
        for (w.vm.protocol_registry.items) |p| {
            try out.str(p.ns_name);
            try out.str(p.name);
            try out.count(p.methods.items.len);
            for (p.methods.items) |m| {
                try out.int(u32, method_names.items[next_method]);
                next_method += 1;
                try out.str(m.name);
            }
        }
        try out.count(w.vars.items.items.len);
        for (w.vars.items.items) |v| {
            try out.int(u32, w.namespaceIndex(registry.lookupNs(v.ns) orelse return w.unsupported("a Var outside every namespace")));
            try out.str(v.name);
        }
        try out.list.appendSlice(gpa, entry_out.list.items);
        try out.count(w.native_refs.items.items.len);
        for (w.native_refs.items.items, native_vars.items) |d, v| {
            try out.int(u32, v);
            try out.str(d.name);
        }
        try out.list.appendSlice(gpa, w.object_out.list.items);
        try out.list.appendSlice(gpa, w.routine_out.list.items);
        try out.list.appendSlice(gpa, arity_out.list.items);
        try out.count(fills);
        try out.list.appendSlice(gpa, w.fill_out.list.items);
        try out.count(states);
        try out.list.appendSlice(gpa, w.state_out.list.items);
        try out.list.appendSlice(gpa, alias_out.list.items);
        try out.list.appendSlice(gpa, w.impl_out.list.items);
        return out.list.toOwnedSlice(gpa);
    }

    /// Append the entry `key` → `v` of `ns`, and the state of `v` when
    /// it is the namespace's own and the sources changed it.
    fn entry(w: *Writer, out: *Out, ns: *Namespace, key: []const u8, v: *Var, states: *u32) WriteError!void {
        const keyed_by_name = key.ptr == v.name.ptr;
        const own = keyed_by_name and v.ns.ptr == ns.name.ptr;
        try out.byte(@backingInt(if (keyed_by_name) EntryTag.named else EntryTag.referral));
        try out.int(u32, try w.varIndex(v));
        if (!keyed_by_name) try out.str(key);
        if (!own or w.natives.untouched(v)) return;
        if (v.thread_bound) return w.unsupported("a Var bound by `binding`");
        states.* += 1;
        try w.state_out.int(u32, try w.varIndex(v));
        try w.state_out.byte(@as(u8, @intFromBool(v.bound)) | @as(u8, @intFromBool(v.macro)) << 1 | @as(u8, @intFromBool(v.dynamic)) << 2);
        try w.ref(&w.state_out, v.root);
        try w.ref(&w.state_out, v.meta);
    }

    fn addNamespace(w: *Writer, ns: *Namespace) !void {
        for (w.namespaces.items) |have| if (have == ns) return;
        if (ns.parent) |p| try w.addNamespace(p);
        try w.namespaces.append(w.gpa, ns);
    }

    fn namespaceIndex(w: *Writer, ns: *const Namespace) u32 {
        for (w.namespaces.items, 0..) |have, i| if (have == ns) return @intCast(i);
        unreachable;
    }

    fn varIndex(w: *Writer, v: *Var) !u32 {
        return w.vars.of(w.gpa, v);
    }

    fn keyword(w: *Writer, id: u32) !u32 {
        return name(w.gpa, &w.keywords, id, w.interner.keywordName(id));
    }

    fn symbol(w: *Writer, id: u32) !u32 {
        return name(w.gpa, &w.symbols, id, w.interner.symbolName(id));
    }

    fn name(gpa: Allocator, names: *Names, id: u32, text: []const u8) !u32 {
        const gop = try names.ids.getOrPut(gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(names.texts.items.len);
            try names.texts.append(gpa, text);
        }
        return gop.value_ptr.*;
    }

    /// Append `v` to `out` as a reference, writing whatever it reaches
    /// first.
    fn ref(w: *Writer, out: *Out, v: Value) WriteError!void {
        switch (v.kind()) {
            .nil => try out.byte(@backingInt(RefTag.nil)),
            .false_, .true_, .char, .fixnum, .float => {
                try out.byte(@backingInt(RefTag.immediate));
                try out.int(u64, v.tag);
                try out.int(u64, v.payload);
            },
            .keyword => {
                try out.byte(@backingInt(RefTag.keyword));
                try out.int(u32, try w.keyword(v.asKeywordId()));
            },
            .symbol => {
                try out.byte(@backingInt(RefTag.symbol));
                try out.int(u32, try w.symbol(v.asSymbolId()));
            },
            .native_fn => {
                try out.byte(@backingInt(RefTag.native));
                try out.int(u32, try w.native_refs.of(w.gpa, vm_mod.asNativeFn(v)));
            },
            .var_ => {
                try out.byte(@backingInt(RefTag.var_));
                try out.int(u32, try w.varIndex(VM.asVar(v)));
            },
            else => {
                const id = try w.object(v);
                try out.byte(@backingInt(RefTag.object));
                try out.int(u32, id);
            },
        }
    }

    /// The object index of the heap value `v`, its record written
    /// after the records of everything it reaches.
    fn object(w: *Writer, v: Value) WriteError!u32 {
        if (!v.kind().isHeap()) return w.unsupported("a runtime-private value");
        const h = Heap.asHeapHeader(v);
        if (w.objects.get(@intFromPtr(h))) |o| {
            if (o.tag != v.tag) return w.unsupported("two Values of one block with different tags (a list view)");
            return o.id;
        }
        try stack.check();
        var body: Out = .{ .gpa = w.gpa };
        defer body.deinit();
        const tag: ObjTag = switch (v.kind()) {
            .atom => {
                try w.shells.append(w.gpa, v);
                return w.record(v, .atom, &body);
            },
            .string => blk: {
                try body.str(string_mod.asBytes(v));
                break :blk .string;
            },
            .bignum => blk: {
                try body.byte(@intFromBool(bignum_mod.isNegative(v)));
                const limbs = bignum_mod.limbs(v);
                try body.count(limbs.len);
                for (limbs) |l| try body.int(u64, l);
                break :blk .bignum;
            },
            .regex => blk: {
                try body.str(regex_mod.sourceOf(v));
                break :blk .regex;
            },
            .persistent_vector => blk: {
                const n = vector_mod.count(v);
                try body.count(n);
                for (0..n) |i| try w.ref(&body, vector_mod.nth(v, i));
                break :blk .vector;
            },
            .list => return w.list(v),
            .persistent_map => blk: {
                try body.count(champ_mod.mapCount(v));
                var entries = champ_mod.mapIter(v);
                while (entries.next()) |e| {
                    try w.ref(&body, e.key);
                    try w.ref(&body, e.value);
                }
                break :blk .map;
            },
            .persistent_set => blk: {
                try body.count(champ_mod.setCount(v));
                var elems = champ_mod.setIter(v);
                while (elems.next()) |e| try w.ref(&body, e);
                break :blk .set;
            },
            .function => blk: {
                const c = VM.asClosure(v);
                try body.int(u32, try w.routines.of(w.gpa, c.routine));
                try body.count(c.upvalues.len);
                for (c.upvalues) |up| try body.int(u32, try w.cell(up));
                break :blk .function;
            },
            .protocol => blk: {
                try body.int(u32, protocol_mod.protocolId(v));
                break :blk .protocol;
            },
            .protocol_fn => blk: {
                try body.int(u32, protocol_mod.protocolFnProtocolId(v));
                try body.int(u32, try w.keyword(protocol_mod.protocolFnMethodNameId(v)));
                break :blk .protocol_fn;
            },
            .record => blk: {
                try body.int(u32, record_mod.typeId(v));
                try w.ref(&body, record_mod.fieldsOf(v));
                break :blk .record;
            },
            else => |k| return w.unsupported(@tagName(k)),
        };
        return w.record(v, tag, &body);
    }

    /// Append the record of `v`: its tag, its Value tag, its metadata
    /// (a shell's comes with its fill) and `body`.
    fn record(w: *Writer, v: Value, tag: ObjTag, body: *const Out) WriteError!u32 {
        const h = header(v);
        var meta: Out = .{ .gpa = w.gpa };
        defer meta.deinit();
        if (tag != .atom and tag != .cell) try w.ref(&meta, dispatch_mod.metaOf(h));
        const id = w.totals.objects;
        w.totals.objects += 1;
        try w.objects.put(w.gpa, @intFromPtr(h), .{ .id = id, .tag = v.tag });
        try w.object_out.byte(@backingInt(tag));
        try w.object_out.int(u64, v.tag);
        try w.object_out.list.appendSlice(w.gpa, meta.list.items);
        try w.object_out.list.appendSlice(w.gpa, body.list.items);
        return id;
    }

    /// A list: its cons cells from the last one not yet written
    /// forward, each after its tail, so a long list costs no
    /// recursion.
    fn list(w: *Writer, v: Value) WriteError!u32 {
        var cells: std.ArrayList(Value) = .empty;
        defer cells.deinit(w.gpa);
        var cur = v;
        while (!w.objects.contains(@intFromPtr(Heap.asHeapHeader(cur)))) {
            switch (cur.subkind()) {
                list_mod.subkind_cons => {},
                list_mod.subkind_empty => {
                    var none: Out = .{ .gpa = w.gpa };
                    _ = try w.record(cur, .empty_list, &none);
                    break;
                },
                else => return w.unsupported("a list view"),
            }
            try cells.append(w.gpa, cur);
            cur = list_mod.tail(cur);
        }
        var i = cells.items.len;
        while (i > 0) {
            i -= 1;
            const c = cells.items[i];
            var body: Out = .{ .gpa = w.gpa };
            defer body.deinit();
            try w.ref(&body, list_mod.head(c));
            try body.int(u32, try w.object(list_mod.tail(c)));
            _ = try w.record(c, .cons, &body);
        }
        return w.object(v);
    }

    fn cell(w: *Writer, c: *UpvalCell) WriteError!u32 {
        const v = Value{ .tag = @backingInt(Kind.cell_internal), .payload = @intFromPtr(c) - @sizeOf(HeapHeader) };
        if (w.objects.get(v.payload)) |o| return o.id;
        try w.shells.append(w.gpa, v);
        var none: Out = .{ .gpa = w.gpa };
        return w.record(v, .cell, &none);
    }

    fn fill(w: *Writer, shell: Value) WriteError!void {
        const h = header(shell);
        try w.fill_out.int(u32, w.objects.get(@intFromPtr(h)).?.id);
        if (shell.kind() == .cell_internal) {
            const c = Heap.bodyOf(UpvalCell, h);
            try w.fill_out.byte(@intFromBool(c.initialized));
            return w.ref(&w.fill_out, c.value);
        }
        const a = atom_mod.body(shell);
        if (a.in_flight != 0) return w.unsupported("an atom in the middle of a swap");
        try w.ref(&w.fill_out, dispatch_mod.metaOf(h));
        try w.ref(&w.fill_out, a.value);
        try w.ref(&w.fill_out, a.validator);
        try w.ref(&w.fill_out, a.watches);
    }

    fn routineBody(w: *Writer, r: *const Routine) WriteError!void {
        const out = &w.routine_out;
        try out.str(r.name);
        try out.int(u16, r.slot_count);
        try out.int(u16, r.fixed_arity);
        try out.byte(@intFromBool(r.variadic));
        try out.int(u16, r.upvalue_count);
        try out.byte(@intFromBool(r.origin != null));
        if (r.origin) |o| {
            try out.int(u32, o.pos);
            try out.int(u32, o.len);
        }
        try out.int(u32, if (r.source) |s| w.sourceIndex(s) orelse return w.unsupported("a routine compiled from no embedded source") else no_index);
        try out.count(r.code.len);
        try out.list.appendSlice(w.gpa, std.mem.sliceAsBytes(r.code));
        try out.count(r.consts.len);
        // A constant can reach a routine-free value only; its records
        // go to `object_out`, its reference here.
        for (r.consts) |c| try w.ref(out, c);
        try out.count(r.var_table.len);
        for (r.var_table) |v| try out.int(u32, try w.varIndex(v));
        try out.count(r.capture_descs.len);
        for (r.capture_descs) |d| {
            try out.int(u32, try w.routines.of(w.gpa, d.routine));
            try out.count(d.sources.len);
            for (d.sources) |s| switch (s) {
                .local_cell_slot => |i| try out.int(u16, i),
                .inherited_upvalue => |i| try out.int(u16, @as(u16, i) | 0x8000),
            };
            w.totals.capture_sources += @intCast(d.sources.len);
        }
        try out.count(r.tries.len);
        for (r.tries) |t| {
            try out.int(u32, t.catch_pc);
            try out.int(u32, t.finally_pc orelse no_index);
        }
        try out.count(r.spans.len);
        for (r.spans) |s| {
            try out.int(u32, s.pc);
            try out.int(u32, s.span.pos);
            try out.int(u32, s.span.len);
        }
        // A closure names one member of a table; the table names the
        // rest, each written once.
        if (r.arities) |a| {
            const known = w.arities.ids.contains(a);
            try out.int(u32, try w.arities.of(w.gpa, a));
            if (!known) {
                var members = a.members();
                while (members.next()) |m| _ = try w.routines.of(w.gpa, m);
            }
        } else try out.int(u32, no_index);
        w.totals.code += @intCast(r.code.len);
        w.totals.consts += @intCast(r.consts.len);
        w.totals.var_refs += @intCast(r.var_table.len);
        w.totals.captures += @intCast(r.capture_descs.len);
        w.totals.tries += @intCast(r.tries.len);
        w.totals.spans += @intCast(r.spans.len);
    }

    fn sourceIndex(w: *Writer, info: *const vm_mod.SourceInfo) ?u32 {
        for (w.sources, 0..) |s, i| if (s.info.text.ptr == info.text.ptr and s.info.text.len == info.text.len) return @intCast(i);
        return null;
    }
};

/// The block of `v`, a heap value or a cell.
fn header(v: Value) *HeapHeader {
    return @ptrFromInt(v.payload);
}

// =============================================================================
// Loading
// =============================================================================

/// Whether `load` verifies every routine it read (docs/STDLIB.md §1):
/// in debug and safe builds, the build's generator among them, which
/// loads every image a binary embeds before the binary is built. A
/// release build loads only those bytes (`matches` refuses any other
/// image) and trusts them; verifying costs it 0.35 M instructions, 1.6%
/// of a start (docs/PERF.md §3.18).
pub const verify_routines = @import("builtin").optimize.runtimeSafety();

/// Load the image `bytes`, which `matches` accepted for `sources`,
/// into `vm`, whose natives are installed and which has run nothing:
/// afterwards it holds what booting `sources` would have left.
/// Nothing in it reaches a safe point, so nothing it builds needs
/// rooting until the Vars hold it. Its closures are made before the
/// routines they run are read, so each routine is verified once the
/// image is whole (`verify_routines`), and one that does not verify,
/// or a closure whose cells are not one for each upvalue of its
/// routine, fails the load with `UnfitRoutine`. Returns what the boot
/// generated, for the caller to advance its counters by.
pub fn load(vm: *VM, bytes: []const u8, sources: []const Source) LoadError!Counted {
    var scratch: std.heap.ArenaAllocator = .init(vm.allocator);
    defer scratch.deinit();
    var l: Loader = .{
        .vm = vm,
        .heap = vm.ensureHeap(),
        .interner = vm.ensureInterner(),
        .registry = vm.ensureRegistry() catch return error.OutOfMemory,
        .arena = vm.runtime_arena.allocator(),
        .scratch = scratch.allocator(),
        .in = .{ .bytes = bytes, .pos = magic.len + 4 + 8 },
        .sources = sources,
    };
    return l.run();
}

const Loader = struct {
    vm: *VM,
    heap: *Heap,
    interner: *intern_mod.Interner,
    registry: *vm_mod.NamespaceRegistry,
    arena: Allocator,
    scratch: Allocator,
    in: In,
    sources: []const Source,

    keywords: []Value = &.{},
    symbols: []Value = &.{},
    namespaces: []*Namespace = &.{},
    record_types: []u32 = &.{},
    protocols: []u32 = &.{},
    vars: []*Var = &.{},
    natives: []Value = &.{},
    objects: []Value = &.{},
    /// How many of `objects` are made: a reference names one of them,
    /// so an object refers only to those written before it.
    built: usize = 0,
    routines: []Routine = &.{},
    /// The arity table each routine names, by index, until
    /// `readArities` makes them.
    routine_arities: []u32 = &.{},

    fn run(l: *Loader) LoadError!Counted {
        const counted: Counted = .{ .auto_gensyms = try l.in.int(u64), .gensyms = try l.in.int(u64) };
        var totals: Totals = .{};
        inline for (@typeInfo(Totals).@"struct".field_names) |f| @field(totals, f) = try l.in.int(u32);
        l.keywords = try l.names(.keyword);
        l.symbols = try l.names(.symbol);
        try l.readNamespaces();
        try l.readTypes();
        try l.readVars();
        try l.readNatives();
        try l.readObjects(totals);
        try l.readRoutines(totals);
        try l.readArities(totals);
        try l.readFills();
        try l.readStates();
        try l.readAliases();
        try l.readImpls();
        if (l.in.pos != l.in.bytes.len) return error.Corrupt;
        if (verify_routines) {
            for (l.routines) |*r| {
                var failure: vm_mod.VerifyFailure = undefined;
                r.verifyAlone(&failure) catch return error.UnfitRoutine;
            }
            // A call trusts a closure to carry a cell for each upvalue
            // of its routine (docs/VM.md §6).
            for (l.objects) |o| if (o.kind() == .function) {
                const closure = VM.asClosure(o);
                if (closure.upvalues.len != closure.routine.upvalue_count) return error.UnfitRoutine;
            };
        }
        return counted;
    }

    fn names(l: *Loader, comptime kind: enum { keyword, symbol }) LoadError![]Value {
        const out = try l.scratch.alloc(Value, try l.in.int(u32));
        for (out) |*v| {
            const text = try l.in.str();
            v.* = (switch (kind) {
                .keyword => l.interner.internKeywordValue(text),
                .symbol => l.interner.internSymbolValue(text),
            }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Corrupt;
        }
        return out;
    }

    fn readNamespaces(l: *Loader) LoadError!void {
        l.namespaces = try l.scratch.alloc(*Namespace, try l.in.int(u32));
        for (l.namespaces, 0..) |*ns, i| {
            const name = try l.in.str();
            const parent = try l.in.int(u32);
            if (parent != no_index and parent >= i) return error.Corrupt;
            ns.* = try l.registry.getOrCreate(name, if (parent == no_index) null else l.namespaces[parent]);
        }
    }

    fn readTypes(l: *Loader) LoadError!void {
        l.record_types = try l.scratch.alloc(u32, try l.in.int(u32));
        for (l.record_types) |*id| {
            const ns = try l.in.str();
            const name = try l.in.str();
            const fields = try l.scratch.alloc([]const u8, try l.in.int(u32));
            for (fields) |*f| f.* = try l.in.str();
            id.* = try mem(l.vm.registerRecordType(ns, name, fields));
        }
        const reduced = try l.in.int(u32);
        if (reduced != no_index) l.vm.reduced_type_id = l.record_types[try check(reduced, l.record_types.len)];
        l.protocols = try l.scratch.alloc(u32, try l.in.int(u32));
        for (l.protocols) |*id| {
            const ns = try l.in.str();
            const name = try l.in.str();
            const methods = try l.scratch.alloc(vm_mod.ProtocolMethodSpec, try l.in.int(u32));
            for (methods) |*m| m.* = .{ .name_id = (try l.keyword()).asKeywordId(), .name = try l.in.str() };
            id.* = try mem(l.vm.registerProtocol(ns, name, methods));
        }
    }

    /// Every Var the image names, then each namespace's map, rebuilt at
    /// the capacity it had from entries in the order `Writer.run`
    /// gives them, so it iterates as it did after the boot. A Var is
    /// made when its namespace does not hold it yet, as
    /// `Namespace.intern` makes one.
    fn readVars(l: *Loader) LoadError!void {
        l.vars = try l.scratch.alloc(*Var, try l.in.int(u32));
        for (l.vars) |*v| {
            const home = l.namespaces[try l.in.index(l.namespaces.len)];
            const name = try l.in.str();
            v.* = home.lookupLocal(name) orelse made: {
                const made = try home.var_allocator.create(Var);
                made.* = .{ .name = try home.var_allocator.dupe(u8, name), .ns = home.name };
                break :made made;
            };
        }
        for (l.namespaces) |ns| {
            const capacity = try l.in.int(u32);
            const n = try l.in.int(u32);
            const map = &ns.vars;
            if (capacity < map.capacity() or n > @as(u64, capacity) * 4 / 5 or (n > 0) != (capacity > 0)) return error.Corrupt;
            map.clearRetainingCapacity();
            // The size whose table has exactly `capacity` slots.
            if (capacity > map.capacity()) try map.ensureTotalCapacity(ns.map_allocator, @intCast((@as(u64, capacity) - 1) * 4 / 5));
            if (map.capacity() != capacity) return error.Corrupt;
            for (0..n) |_| {
                const tag = try l.in.tag(EntryTag);
                const v = l.vars[try l.in.index(l.vars.len)];
                const key = if (tag == .referral) try ns.var_allocator.dupe(u8, try l.in.str()) else v.name;
                const gop = map.getOrPutAssumeCapacity(key);
                if (gop.found_existing) return error.Corrupt;
                gop.value_ptr.* = v;
            }
        }
    }

    /// Each native, read out of the Var the tables installed it in
    /// before any root of the image is set.
    fn readNatives(l: *Loader) LoadError!void {
        l.natives = try l.scratch.alloc(Value, try l.in.int(u32));
        for (l.natives) |*n| {
            const v = l.vars[try l.in.index(l.vars.len)];
            const name = try l.in.str();
            if (!v.bound or v.root.kind() != .native_fn or !std.mem.eql(u8, vm_mod.asNativeFn(v.root).name, name)) return error.Corrupt;
            n.* = v.root;
        }
    }

    fn readObjects(l: *Loader, totals: Totals) LoadError!void {
        // Each routine is empty until `readRoutines` reads it.
        l.routines = try l.arena.alloc(Routine, totals.routines);
        @memset(l.routines, .{ .code = &.{}, .consts = &.{}, .slot_count = 0 });
        l.objects = try l.scratch.alloc(Value, totals.objects);
        var elems: std.ArrayList(Value) = .empty;
        var entries: std.ArrayList(champ_mod.Entry) = .empty;
        for (l.objects, 0..) |*o, i| {
            l.built = i;
            const tag = try l.in.tag(ObjTag);
            const vtag = try l.in.int(u64);
            if (tag == .cell or tag == .atom) {
                o.* = try l.shell(tag);
            } else {
                const meta = try l.ref();
                o.* = switch (tag) {
                    .cell, .atom => unreachable,
                    .string => try mem(string_mod.fromBytes(l.heap, try l.in.str())),
                    .bignum => blk: {
                        const negative = try l.in.byte() != 0;
                        const limbs = try l.scratch.alloc(u64, try l.in.int(u32));
                        for (limbs) |*limb| limb.* = try l.in.int(u64);
                        break :blk try mem(bignum_mod.fromLimbs(l.heap, negative, limbs));
                    },
                    .regex => switch (try mem(regex_mod.make(l.heap, l.vm.allocator, try l.in.str()))) {
                        .ok => |v| v,
                        .err => return error.Corrupt,
                    },
                    .vector => blk: {
                        try l.refs(&elems, try l.in.int(u32));
                        break :blk try mem(if (elems.items.len == 0) vector_mod.empty(l.heap) else vector_mod.fromSlice(l.heap, elems.items));
                    },
                    .empty_list => try mem(list_mod.empty(l.heap)),
                    .cons => blk: {
                        const head = try l.ref();
                        const tail = l.objects[try l.in.index(i)];
                        break :blk try mem(list_mod.cons(l.heap, head, tail));
                    },
                    .map => blk: {
                        entries.clearRetainingCapacity();
                        for (0..try l.in.int(u32)) |_| try entries.append(l.scratch, .{ .key = try l.ref(), .value = try l.ref() });
                        break :blk try mem(champ_mod.mapFromEntries(l.heap, entries.items, &dispatch_mod.hashValue, &dispatch_mod.equal));
                    },
                    .set => blk: {
                        try l.refs(&elems, try l.in.int(u32));
                        break :blk try mem(champ_mod.setFromElements(l.heap, elems.items, &dispatch_mod.hashValue, &dispatch_mod.equal));
                    },
                    .function => blk: {
                        const routine = &l.routines[try l.in.index(l.routines.len)];
                        const n = try l.in.int(u32);
                        const f = try mem(l.vm.allocClosure(routine, n));
                        const cells: []*UpvalCell = @constCast(VM.asClosure(f).upvalues);
                        for (cells) |*c| {
                            const cell = l.objects[try l.in.index(i)];
                            if (cell.kind() != .cell_internal) return error.Corrupt;
                            c.* = VM.asCell(cell) catch unreachable;
                        }
                        break :blk f;
                    },
                    .protocol => try mem(protocol_mod.makeProtocol(l.heap, l.protocols[try l.in.index(l.protocols.len)])),
                    .protocol_fn => try mem(protocol_mod.makeProtocolFn(l.heap, l.protocols[try l.in.index(l.protocols.len)], (try l.keyword()).asKeywordId())),
                    .record => blk: {
                        const type_id = l.record_types[try l.in.index(l.record_types.len)];
                        const fields = try l.ref();
                        if (fields.kind() != .persistent_map) return error.Corrupt;
                        break :blk try mem(record_mod.make(l.heap, type_id, fields));
                    },
                };
                try setMeta(o.*, meta);
            }
            // A rebuilt block is the block that was written, down to
            // its subkind, or the image does not describe this runtime.
            if (o.tag != vtag) return error.Corrupt;
        }
        l.built = l.objects.len;
        elems.deinit(l.scratch);
        entries.deinit(l.scratch);
    }

    fn shell(l: *Loader, tag: ObjTag) LoadError!Value {
        return switch (tag) {
            .cell => try mem(l.vm.allocCell(value_mod.nilValue(), false)),
            .atom => try mem(atom_mod.make(l.heap, value_mod.nilValue())),
            else => unreachable,
        };
    }

    fn readRoutines(l: *Loader, totals: Totals) LoadError!void {
        var code = try l.arena.alloc(vm_mod.Inst, totals.code);
        var consts = try l.arena.alloc(Value, totals.consts);
        var var_refs = try l.arena.alloc(*Var, totals.var_refs);
        var captures = try l.arena.alloc(vm_mod.CaptureDescriptor, totals.captures);
        var capture_sources = try l.arena.alloc(vm_mod.CaptureSource, totals.capture_sources);
        var tries = try l.arena.alloc(vm_mod.Try, totals.tries);
        var spans = try l.arena.alloc(vm_mod.SpanEntry, totals.spans);
        l.routine_arities = try l.scratch.alloc(u32, l.routines.len);
        for (l.routines, l.routine_arities) |*r, *table| {
            r.* = .{ .code = &.{}, .consts = &.{}, .slot_count = 0 };
            r.name = try l.in.str();
            r.slot_count = try l.in.int(u16);
            r.fixed_arity = try l.in.int(u16);
            r.variadic = try l.in.byte() != 0;
            r.upvalue_count = try l.in.int(u16);
            if (try l.in.byte() != 0) r.origin = .{ .pos = try l.in.int(u32), .len = try l.in.int(u32) };
            const source = try l.in.int(u32);
            if (source != no_index) r.source = &l.sources[try check(source, l.sources.len)].info;

            const n_code = try l.in.int(u32);
            if (n_code > code.len) return error.Corrupt;
            @memcpy(std.mem.sliceAsBytes(code[0..n_code]), try l.in.take(n_code * @sizeOf(vm_mod.Inst)));
            r.code = take(vm_mod.Inst, &code, n_code);

            const n_consts = try l.in.int(u32);
            if (n_consts > consts.len) return error.Corrupt;
            for (consts[0..n_consts]) |*c| c.* = try l.ref();
            r.consts = take(Value, &consts, n_consts);

            const n_vars = try l.in.int(u32);
            if (n_vars > var_refs.len) return error.Corrupt;
            for (var_refs[0..n_vars]) |*v| v.* = l.vars[try l.in.index(l.vars.len)];
            r.var_table = take(*Var, &var_refs, n_vars);

            const n_caps = try l.in.int(u32);
            if (n_caps > captures.len) return error.Corrupt;
            for (captures[0..n_caps]) |*d| {
                const routine = &l.routines[try l.in.index(l.routines.len)];
                const n = try l.in.int(u32);
                if (n > capture_sources.len) return error.Corrupt;
                for (capture_sources[0..n]) |*s| {
                    const raw = try l.in.int(u16);
                    const i: u12 = @truncate(raw);
                    s.* = if (raw & 0x8000 != 0) .{ .inherited_upvalue = i } else .{ .local_cell_slot = i };
                }
                d.* = .{ .routine = routine, .sources = take(vm_mod.CaptureSource, &capture_sources, n) };
            }
            r.capture_descs = take(vm_mod.CaptureDescriptor, &captures, n_caps);

            const n_tries = try l.in.int(u32);
            if (n_tries > tries.len) return error.Corrupt;
            for (tries[0..n_tries]) |*t| {
                t.catch_pc = try l.in.int(u32);
                const f = try l.in.int(u32);
                t.finally_pc = if (f == no_index) null else f;
            }
            r.tries = take(vm_mod.Try, &tries, n_tries);

            const n_spans = try l.in.int(u32);
            if (n_spans > spans.len) return error.Corrupt;
            for (spans[0..n_spans]) |*s| s.* = .{ .pc = try l.in.int(u32), .span = .{ .pos = try l.in.int(u32), .len = try l.in.int(u32) } };
            r.spans = take(vm_mod.SpanEntry, &spans, n_spans);

            table.* = try l.in.int(u32);
        }
    }

    /// The arity tables, once every routine they name exists, and the
    /// table of each routine that names one. Whether each is one a call
    /// can pick from is the routines' verification.
    fn readArities(l: *Loader, totals: Totals) LoadError!void {
        const tables = try l.arena.alloc(vm_mod.Arities, totals.arities);
        var slots = try l.arena.alloc(?*const Routine, totals.arity_slots);
        for (tables) |*a| {
            const n = try l.in.int(u32);
            if (n > slots.len) return error.Corrupt;
            for (slots[0..n]) |*m| m.* = try l.member();
            a.* = .{ .fixed = take(?*const Routine, &slots, n), .rest = try l.member() };
        }
        for (l.routines, l.routine_arities) |*r, i| {
            if (i != no_index) r.arities = &tables[try check(i, tables.len)];
        }
    }

    fn member(l: *Loader) LoadError!?*const Routine {
        const i = try l.in.int(u32);
        return if (i == no_index) null else &l.routines[try check(i, l.routines.len)];
    }

    fn readFills(l: *Loader) LoadError!void {
        for (0..try l.in.int(u32)) |_| {
            const shell_v = l.objects[try l.in.index(l.objects.len)];
            switch (shell_v.kind()) {
                .cell_internal => {
                    const c = VM.asCell(shell_v) catch unreachable;
                    c.initialized = try l.in.byte() != 0;
                    c.value = try l.ref();
                },
                .atom => {
                    try setMeta(shell_v, try l.ref());
                    const a = atom_mod.body(shell_v);
                    a.value = try l.ref();
                    a.validator = try l.ref();
                    a.watches = try l.ref();
                },
                else => return error.Corrupt,
            }
        }
    }

    fn readStates(l: *Loader) LoadError!void {
        for (0..try l.in.int(u32)) |_| {
            const v = l.vars[try l.in.index(l.vars.len)];
            const flags = try l.in.byte();
            v.bound = flags & 1 != 0;
            v.macro = flags & 2 != 0;
            v.dynamic = flags & 4 != 0;
            v.root = try l.ref();
            v.meta = try l.ref();
        }
    }

    fn readAliases(l: *Loader) LoadError!void {
        for (l.namespaces) |ns| for (0..try l.in.int(u32)) |_| {
            try ns.putAlias(try l.in.str(), try l.in.str());
        };
    }

    fn readImpls(l: *Loader) LoadError!void {
        for (l.protocols) |id| for (l.vm.protocolById(id).?.methods.items) |*m| {
            for (0..try l.in.int(u32)) |_| {
                const key_tag = try l.in.tag(vm_mod.DispatchKey.Tag);
                const raw = try l.in.int(u32);
                const key: vm_mod.DispatchKey = .{ .tag = key_tag, .id = if (key_tag == .record) l.record_types[try check(raw, l.record_types.len)] else raw };
                try m.impls.put(l.vm.home().allocator, key, try l.ref());
            }
            if (try l.in.byte() != 0) m.default_impl = try l.ref();
        };
    }

    fn symbol(l: *Loader) LoadError!Value {
        return l.symbols[try l.in.index(l.symbols.len)];
    }

    fn keyword(l: *Loader) LoadError!Value {
        return l.keywords[try l.in.index(l.keywords.len)];
    }

    fn ref(l: *Loader) LoadError!Value {
        return switch (try l.in.tag(RefTag)) {
            .nil => value_mod.nilValue(),
            .immediate => try immediate(.{ .tag = try l.in.int(u64), .payload = try l.in.int(u64) }),
            .keyword => try l.keyword(),
            .symbol => try l.symbol(),
            .object => l.objects[try l.in.index(l.built)],
            .native => l.natives[try l.in.index(l.natives.len)],
            .var_ => VM.varToValue(l.vars[try l.in.index(l.vars.len)]),
        };
    }

    fn refs(l: *Loader, out: *std.ArrayList(Value), n: u32) LoadError!void {
        out.clearRetainingCapacity();
        try out.ensureTotalCapacity(l.scratch, n);
        for (0..n) |_| out.appendAssumeCapacity(try l.ref());
    }
};

/// `v` when it is an immediate the runtime's constructors make: a
/// boolean, a char, a fixnum or a float, nothing past its kind byte,
/// its payload in range. A reserved kind, a surrogate or a char past
/// U+10FFFF, a fixnum outside i48 or a NaN other than the canonical
/// one is `Corrupt` (VALUE.md §3).
fn immediate(v: Value) LoadError!Value {
    const made: ?Value = switch (v.kind()) {
        .false_, .true_ => value_mod.fromBool(v.kind() == .true_),
        .char => if (v.payload > std.math.maxInt(u21)) null else value_mod.fromChar(@intCast(v.payload)),
        .fixnum => value_mod.fromFixnum(@bitCast(v.payload)),
        .float => value_mod.fromFloat(@bitCast(v.payload)),
        else => null,
    };
    const m = made orelse return error.Corrupt;
    return if (m.identicalTo(v)) v else error.Corrupt;
}

/// `i` when it is below `len`, the length of the table it indexes.
fn check(i: u32, len: usize) LoadError!u32 {
    return if (i < len) i else error.Corrupt;
}

/// The first `n` items of `buf`, which moves past them.
fn take(comptime T: type, buf: *[]T, n: usize) []T {
    defer buf.* = buf.*[n..];
    return buf.*[0..n];
}

/// The result of a heap or registry call: out of memory as itself, any
/// other failure an image that does not describe this runtime.
fn mem(result: anytype) LoadError!@typeInfo(@TypeOf(result)).error_union.payload {
    return result catch |err| if (err == error.OutOfMemory) error.OutOfMemory else error.Corrupt;
}

fn setMeta(v: Value, meta: Value) LoadError!void {
    switch (meta.kind()) {
        .nil => {},
        .persistent_map => Heap.asHeapHeader(v).setMeta(Heap.asHeapHeader(meta)),
        else => return error.Corrupt,
    }
}

// =============================================================================
// Verifying
// =============================================================================

/// Fail with `error.Mismatch`, `why` saying where, unless `b`, which
/// loaded an image of what `a` booted, holds what `a` holds: the same
/// namespaces with the same entries in the same order, Vars, protocols
/// and record types, and values of the same shape and sharing down to
/// every routine's code. The build runs it on every image it writes.
/// `why` is the caller's to free.
pub fn verify(gpa: Allocator, a: *VM, b: *VM, why: *[]const u8) error{ Mismatch, OutOfMemory }!void {
    var v: Verifier = .{ .gpa = gpa, .a = a, .b = b, .ia = a.ensureInterner(), .ib = b.ensureInterner() };
    defer v.pairs.deinit(gpa);
    v.run() catch |err| {
        if (err == error.Mismatch) why.* = try gpa.dupe(u8, v.why);
        return err;
    };
}

const Verifier = struct {
    gpa: Allocator,
    a: *VM,
    b: *VM,
    ia: *intern_mod.Interner,
    ib: *intern_mod.Interner,
    /// Each block, cell and routine of `a` already compared, and its
    /// counterpart in `b`.
    pairs: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    why: []const u8 = "",
    buf: [256]u8 = undefined,

    const Error = error{ Mismatch, OutOfMemory };

    fn fail(v: *Verifier, comptime fmt: []const u8, args: anytype) Error {
        v.why = std.mem.print(&v.buf, fmt, args) catch fmt;
        return error.Mismatch;
    }

    fn run(v: *Verifier) Error!void {
        const ra = try v.a.ensureRegistry();
        const rb = try v.b.ensureRegistry();
        if (ra.map.count() != rb.map.count()) return v.fail("{d} namespaces, {d} loaded", .{ ra.map.count(), rb.map.count() });
        var it = ra.map.valueIterator();
        while (it.next()) |p| try v.namespace(p.*, rb.lookupNs(p.*.name) orelse return v.fail("no namespace {s}", .{p.*.name}));
        if (v.a.record_registry.items.len != v.b.record_registry.items.len or v.a.reduced_type_id != v.b.reduced_type_id) return v.fail("record types differ", .{});
        for (v.a.record_registry.items, v.b.record_registry.items) |x, y| {
            if (!std.mem.eql(u8, x.ns_name, y.ns_name) or !std.mem.eql(u8, x.type_name, y.type_name) or x.field_names.len != y.field_names.len) return v.fail("record type {s}", .{x.type_name});
            for (x.field_names, y.field_names) |f, g| if (!std.mem.eql(u8, f, g)) return v.fail("record type {s}", .{x.type_name});
        }
        if (v.a.protocol_registry.items.len != v.b.protocol_registry.items.len) return v.fail("protocols differ", .{});
        for (v.a.protocol_registry.items, v.b.protocol_registry.items) |x, y| {
            if (!std.mem.eql(u8, x.ns_name, y.ns_name) or !std.mem.eql(u8, x.name, y.name) or x.methods.items.len != y.methods.items.len) return v.fail("protocol {s}", .{x.name});
            for (x.methods.items, y.methods.items) |m, n| {
                if (!std.mem.eql(u8, m.name, n.name) or !std.mem.eql(u8, v.ia.keywordName(m.name_id), v.ib.keywordName(n.name_id)) or m.impls.count() != n.impls.count()) return v.fail("protocol method {s}", .{m.name});
                var impls = m.impls.iterator();
                while (impls.next()) |e| try v.value(e.value_ptr.*, n.impls.get(e.key_ptr.*) orelse return v.fail("protocol method {s}", .{m.name}));
                if ((m.default_impl == null) != (n.default_impl == null)) return v.fail("protocol method {s}", .{m.name});
                if (m.default_impl) |d| try v.value(d, n.default_impl.?);
            }
        }
    }

    fn namespace(v: *Verifier, x: *Namespace, y: *Namespace) Error!void {
        const px = if (x.parent) |p| p.name else "";
        const py = if (y.parent) |p| p.name else "";
        if (!std.mem.eql(u8, px, py)) return v.fail("{s}: parent {s}, loaded {s}", .{ x.name, px, py });
        if (x.aliases.count() != y.aliases.count()) return v.fail("{s}: aliases differ", .{x.name});
        var aliases = x.aliases.iterator();
        while (aliases.next()) |e| if (!std.mem.eql(u8, e.value_ptr.*, y.aliases.get(e.key_ptr.*) orelse "")) return v.fail("{s}: alias {s}", .{ x.name, e.key_ptr.* });
        if (x.vars.count() != y.vars.count()) return v.fail("{s}: {d} entries, {d} loaded", .{ x.name, x.vars.count(), y.vars.count() });
        var ex = x.vars.iterator();
        var ey = y.vars.iterator();
        while (ex.next()) |e| {
            const f = ey.next().?;
            if (!std.mem.eql(u8, e.key_ptr.*, f.key_ptr.*)) return v.fail("{s}: entry {s} where {s} was", .{ x.name, f.key_ptr.*, e.key_ptr.* });
            const vx = e.value_ptr.*;
            const vy = f.value_ptr.*;
            try v.sameVar(vx, vy);
            if ((e.key_ptr.*.ptr == vx.name.ptr) != (f.key_ptr.*.ptr == vy.name.ptr)) return v.fail("{s}: entry {s} keyed differently", .{ x.name, e.key_ptr.* });
            if (vx.ns.ptr != x.name.ptr) continue;
            if (vx.bound != vy.bound or vx.macro != vy.macro or vx.dynamic != vy.dynamic or vx.thread_bound != vy.thread_bound) return v.fail("{s}/{s}: flags differ", .{ x.name, vx.name });
            v.value(vx.root, vy.root) catch |err| return v.context(err, x.name, vx.name, "root");
            v.value(vx.meta, vy.meta) catch |err| return v.context(err, x.name, vx.name, "metadata");
        }
    }

    fn context(v: *Verifier, err: Error, ns: []const u8, name: []const u8, what: []const u8) Error {
        if (err == error.Mismatch) {
            var inner: [256]u8 = undefined;
            const was = inner[0..v.why.len];
            @memcpy(was, v.why);
            v.why = std.mem.print(&v.buf, "{s}/{s} {s}: {s}", .{ ns, name, what, was }) catch v.why;
        }
        return err;
    }

    fn sameVar(v: *Verifier, x: *const Var, y: *const Var) Error!void {
        if (!std.mem.eql(u8, x.ns, y.ns) or !std.mem.eql(u8, x.name, y.name)) return v.fail("Var {s}/{s}, loaded {s}/{s}", .{ x.ns, x.name, y.ns, y.name });
    }

    /// Whether `x` was paired before; pair it with `y` if not.
    fn seen(v: *Verifier, x: usize, y: usize) Error!bool {
        const gop = try v.pairs.getOrPut(v.gpa, x);
        if (gop.found_existing) {
            if (gop.value_ptr.* != y) return v.fail("sharing differs", .{});
            return true;
        }
        gop.value_ptr.* = y;
        return false;
    }

    fn value(v: *Verifier, x: Value, y: Value) Error!void {
        stack.check() catch return v.fail("too deep to compare", .{});
        if (x.kind() != y.kind()) return v.fail("{t}, loaded {t}", .{ x.kind(), y.kind() });
        switch (x.kind()) {
            .keyword => if (!std.mem.eql(u8, v.ia.keywordName(x.asKeywordId()), v.ib.keywordName(y.asKeywordId()))) return v.fail("keyword {s}", .{v.ia.keywordName(x.asKeywordId())}),
            .symbol => if (!std.mem.eql(u8, v.ia.symbolName(x.asSymbolId()), v.ib.symbolName(y.asSymbolId()))) return v.fail("symbol {s}", .{v.ia.symbolName(x.asSymbolId())}),
            .var_ => try v.sameVar(VM.asVar(x), VM.asVar(y)),
            .native_fn => if (x.payload != y.payload) return v.fail("native {s}", .{vm_mod.asNativeFn(x).name}),
            else => |k| if (!k.isHeap()) {
                if (x.tag != y.tag or x.payload != y.payload) return v.fail("{t} differs", .{k});
            } else {
                if (x.tag != y.tag) return v.fail("{t}: tag differs", .{k});
                try v.block(x, y);
            },
        }
    }

    fn block(v: *Verifier, x: Value, y: Value) Error!void {
        const hx = Heap.asHeapHeader(x);
        const hy = Heap.asHeapHeader(y);
        if (try v.seen(@intFromPtr(hx), @intFromPtr(hy))) return;
        try v.value(dispatch_mod.metaOf(hx), dispatch_mod.metaOf(hy));
        switch (x.kind()) {
            .string, .bignum, .regex => if (!std.mem.eql(u8, Heap.bodyBytes(hx), Heap.bodyBytes(hy)) and !(x.kind() == .regex and std.mem.eql(u8, regex_mod.sourceOf(x), regex_mod.sourceOf(y)))) return v.fail("{t} differs", .{x.kind()}),
            .persistent_vector => {
                const n = vector_mod.count(x);
                if (n != vector_mod.count(y)) return v.fail("vector length", .{});
                for (0..n) |i| try v.value(vector_mod.nth(x, i), vector_mod.nth(y, i));
            },
            .list => {
                var cx = x;
                var cy = y;
                while (cx.subkind() == list_mod.subkind_cons) {
                    try v.value(list_mod.head(cx), list_mod.head(cy));
                    cx = list_mod.tail(cx);
                    cy = list_mod.tail(cy);
                    if (cx.tag != cy.tag) return v.fail("list shape", .{});
                    const tx = Heap.asHeapHeader(cx);
                    const ty = Heap.asHeapHeader(cy);
                    if (try v.seen(@intFromPtr(tx), @intFromPtr(ty))) return;
                    try v.value(dispatch_mod.metaOf(tx), dispatch_mod.metaOf(ty));
                }
            },
            .persistent_map => {
                if (champ_mod.mapCount(x) != champ_mod.mapCount(y)) return v.fail("map size", .{});
                var ix = champ_mod.mapIter(x);
                var iy = champ_mod.mapIter(y);
                while (ix.next()) |e| {
                    const f = iy.next().?;
                    try v.value(e.key, f.key);
                    try v.value(e.value, f.value);
                }
            },
            .persistent_set => {
                if (champ_mod.setCount(x) != champ_mod.setCount(y)) return v.fail("set size", .{});
                var ix = champ_mod.setIter(x);
                var iy = champ_mod.setIter(y);
                while (ix.next()) |e| try v.value(e, iy.next().?);
            },
            .function => {
                const fx = VM.asClosure(x);
                const fy = VM.asClosure(y);
                try v.routine(fx.routine, fy.routine);
                if (fx.upvalues.len != fy.upvalues.len) return v.fail("closure of {s}: upvalues", .{fx.routine.name});
                for (fx.upvalues, fy.upvalues) |cx, cy| {
                    if (try v.seen(@intFromPtr(cx), @intFromPtr(cy))) continue;
                    if (cx.initialized != cy.initialized) return v.fail("closure of {s}: cell", .{fx.routine.name});
                    try v.value(cx.value, cy.value);
                }
            },
            .atom => {
                const ax = atom_mod.body(x);
                const ay = atom_mod.body(y);
                try v.value(ax.value, ay.value);
                try v.value(ax.validator, ay.validator);
                try v.value(ax.watches, ay.watches);
            },
            .protocol => if (protocol_mod.protocolId(x) != protocol_mod.protocolId(y)) return v.fail("protocol id", .{}),
            .protocol_fn => if (protocol_mod.protocolFnProtocolId(x) != protocol_mod.protocolFnProtocolId(y) or
                !std.mem.eql(u8, v.ia.keywordName(protocol_mod.protocolFnMethodNameId(x)), v.ib.keywordName(protocol_mod.protocolFnMethodNameId(y))))
                return v.fail("protocol fn", .{}),
            .record => {
                if (record_mod.typeId(x) != record_mod.typeId(y)) return v.fail("record type", .{});
                try v.value(record_mod.fieldsOf(x), record_mod.fieldsOf(y));
            },
            else => |k| return v.fail("{t} cannot be compared", .{k}),
        }
    }

    fn routine(v: *Verifier, x: *const Routine, y: *const Routine) Error!void {
        if (try v.seen(@intFromPtr(x), @intFromPtr(y))) return;
        if (!std.mem.eql(u8, x.name, y.name) or x.slot_count != y.slot_count or x.fixed_arity != y.fixed_arity or
            x.variadic != y.variadic or x.upvalue_count != y.upvalue_count or (x.source == null) != (y.source == null) or
            (x.arities == null) != (y.arities == null) or
            (x.source != null and x.source.?.text.ptr != y.source.?.text.ptr) or
            !std.meta.eql(x.origin, y.origin) or
            !std.mem.eql(u8, std.mem.sliceAsBytes(x.code), std.mem.sliceAsBytes(y.code)) or
            x.consts.len != y.consts.len or x.var_table.len != y.var_table.len or x.capture_descs.len != y.capture_descs.len or
            x.tries.len != y.tries.len or x.spans.len != y.spans.len)
            return v.fail("routine {s} differs", .{x.name});
        for (x.consts, y.consts) |c, d| try v.value(c, d);
        for (x.var_table, y.var_table) |c, d| try v.sameVar(c, d);
        for (x.capture_descs, y.capture_descs) |c, d| {
            try v.routine(c.routine, d.routine);
            if (c.sources.len != d.sources.len) return v.fail("routine {s}: captures", .{x.name});
            for (c.sources, d.sources) |s, t| if (!std.meta.eql(s, t)) return v.fail("routine {s}: captures", .{x.name});
        }
        for (x.tries, y.tries) |s, t| if (!std.meta.eql(s, t)) return v.fail("routine {s}: tries", .{x.name});
        for (x.spans, y.spans) |s, t| if (!std.meta.eql(s, t)) return v.fail("routine {s}: spans", .{x.name});
        if (x.arities) |a| {
            const b = y.arities.?;
            if (a.fixed.len != b.fixed.len) return v.fail("routine {s}: arities", .{x.name});
            for (a.fixed, b.fixed) |m, n| try v.member(x, m, n);
            try v.member(x, a.rest, b.rest);
        }
    }

    fn member(v: *Verifier, of: *const Routine, x: ?*const Routine, y: ?*const Routine) Error!void {
        if ((x == null) != (y == null)) return v.fail("routine {s}: arities", .{of.name});
        if (x) |m| try v.routine(m, y.?);
    }
};

// =============================================================================
// Tests
// =============================================================================

/// An image of `namespaces` (each a name and its map's capacity and
/// entry count, with no entries) and of `objects`, records in the
/// image's own form, with nothing else in it.
fn testImage(out: *Out, namespaces: []const struct { []const u8, u32, u32 }, objects: []const []const u8) ![]const u8 {
    try out.list.appendNTimes(out.gpa, 0, magic.len + 4 + 8 + 16);
    for (0..@typeInfo(Totals).@"struct".field_names.len - 1) |_| try out.int(u32, 0);
    try out.count(objects.len);
    try out.count(0); // keywords
    try out.count(0); // symbols
    try out.count(namespaces.len);
    for (namespaces) |ns| {
        try out.str(ns[0]);
        try out.int(u32, no_index);
    }
    try out.count(0); // record types
    try out.int(u32, no_index); // the reduced type
    try out.count(0); // protocols
    try out.count(0); // Vars
    for (namespaces) |ns| {
        try out.int(u32, ns[1]);
        try out.int(u32, ns[2]);
    }
    try out.count(0); // natives
    for (objects) |o| try out.list.appendSlice(out.gpa, o);
    for ([_]u32{ 0, 0 }) |n| try out.int(u32, n); // fills, Var states
    for (namespaces) |_| try out.count(0); // aliases
    return out.list.items;
}

/// The record of an object with no metadata: its tag, the Value tag
/// `v` carries and `body`.
fn testObject(gpa: Allocator, tag: ObjTag, v: Value, body: []const u8) ![]u8 {
    var out: Out = .{ .gpa = gpa };
    errdefer out.deinit();
    try out.byte(@backingInt(tag));
    try out.int(u64, v.tag);
    try out.byte(@backingInt(RefTag.nil));
    try out.list.appendSlice(gpa, body);
    return out.list.toOwnedSlice(gpa);
}

test "load: an object naming one written after it is Corrupt, never an unmade Value" {
    const gpa = std.testing.allocator;
    var vm = try VM.init(gpa, &VM.idle_routine);
    defer vm.deinit();
    const heap = vm.ensureHeap();
    // Object 0, a vector holding object 1, a string: well formed but
    // for the order.
    var elem: Out = .{ .gpa = gpa };
    defer elem.deinit();
    try elem.count(1);
    try elem.byte(@backingInt(RefTag.object));
    try elem.int(u32, 1);
    const vector = try testObject(gpa, .vector, try vector_mod.fromSlice(heap, &.{value_mod.nilValue()}), elem.list.items);
    defer gpa.free(vector);
    const string = try testObject(gpa, .string, try string_mod.fromBytes(heap, "s"), &.{ 1, 0, 0, 0, 's' });
    defer gpa.free(string);
    var out: Out = .{ .gpa = gpa };
    defer out.deinit();
    try std.testing.expectError(error.Corrupt, load(&vm, try testImage(&out, &.{}, &.{ vector, string }), &.{}));
    // In the other order the image loads.
    var vm2 = try VM.init(gpa, &VM.idle_routine);
    defer vm2.deinit();
    elem.list.items[elem.list.items.len - 4] = 0;
    const vector_after = try testObject(gpa, .vector, try vector_mod.fromSlice(heap, &.{value_mod.nilValue()}), elem.list.items);
    defer gpa.free(vector_after);
    var ordered: Out = .{ .gpa = gpa };
    defer ordered.deinit();
    _ = try load(&vm2, try testImage(&ordered, &.{}, &.{ string, vector_after }), &.{});
}

test "load: a namespace map of any capacity is read or Corrupt, never an overflow" {
    const gpa = std.testing.allocator;
    var vm = try VM.init(gpa, &VM.idle_routine);
    defer vm.deinit();
    var out: Out = .{ .gpa = gpa };
    defer out.deinit();
    const max = std.math.maxInt(u32);
    try std.testing.expectError(error.Corrupt, load(&vm, try testImage(&out, &.{.{ "image.test", max, max }}, &.{}), &.{}));
}

/// Load an image of one vector holding the immediate reference `tag`
/// and `payload`.
fn loadImmediate(tag: u64, payload: u64) !void {
    const gpa = std.testing.allocator;
    var vm = try VM.init(gpa, &VM.idle_routine);
    defer vm.deinit();
    var elem: Out = .{ .gpa = gpa };
    defer elem.deinit();
    try elem.count(1);
    try elem.byte(@backingInt(RefTag.immediate));
    try elem.int(u64, tag);
    try elem.int(u64, payload);
    const vector = try testObject(gpa, .vector, try vector_mod.fromSlice(vm.ensureHeap(), &.{value_mod.nilValue()}), elem.list.items);
    defer gpa.free(vector);
    var out: Out = .{ .gpa = gpa };
    defer out.deinit();
    _ = try load(&vm, try testImage(&out, &.{}, &.{vector}), &.{});
}

test "load: an immediate of every kind the runtime makes is read" {
    for ([_]Value{
        value_mod.fromBool(false),
        value_mod.fromBool(true),
        value_mod.fromChar(0x10_FFFF).?,
        value_mod.fromFixnum(value_mod.fixnum_min).?,
        value_mod.fromFixnum(value_mod.fixnum_max).?,
        value_mod.fromFloat(std.math.nan(f64)),
        value_mod.fromFloat(-0.0),
    }) |v| try loadImmediate(v.tag, v.payload);
}

test "load: an immediate of a reserved or non-immediate kind is Corrupt" {
    for ([_]u64{ @backingInt(Kind.nil), 8, 15, @backingInt(Kind.string), @backingInt(Kind.cell_internal), 0xff }) |tag|
        try std.testing.expectError(error.Corrupt, loadImmediate(tag, 0));
    // A known kind with stray bits above its kind byte.
    try std.testing.expectError(error.Corrupt, loadImmediate(@as(u64, 1) << 16 | @backingInt(Kind.fixnum), 0));
}

test "load: a char outside Unicode's scalar values is Corrupt" {
    const char: u64 = @backingInt(Kind.char);
    for ([_]u64{ 0xD800, 0xDFFF, 0x11_0000, 0x20_0041, 1 << 63 }) |payload|
        try std.testing.expectError(error.Corrupt, loadImmediate(char, payload));
}

test "load: a fixnum outside i48 is Corrupt" {
    const fixnum: u64 = @backingInt(Kind.fixnum);
    for ([_]i64{ value_mod.fixnum_max + 1, value_mod.fixnum_min - 1, std.math.maxInt(i64), std.math.minInt(i64) }) |n|
        try std.testing.expectError(error.Corrupt, loadImmediate(fixnum, @bitCast(n)));
}

test "load: a float whose NaN is not the canonical one, or a boolean with a payload, is Corrupt" {
    try std.testing.expectError(error.Corrupt, loadImmediate(@backingInt(Kind.float), 0x7FF0_0000_0000_0001));
    try std.testing.expectError(error.Corrupt, loadImmediate(@backingInt(Kind.true_), 1));
}

/// A multi-arity fn as a table of three members: no argument (a
/// string constant), one (itself), and at least three (the rest list).
/// The closure names the one-argument member, so the others are
/// reached only through the table.
const TestArities = struct {
    none: Routine,
    one: Routine,
    rest: Routine,
    consts: [1]Value = undefined,
    fixed: [2]?*const Routine = undefined,
    table: vm_mod.Arities = undefined,

    fn init(t: *TestArities, constant: Value) void {
        t.consts = .{constant};
        t.none = .{ .code = &none_code, .consts = &t.consts, .slot_count = 1, .name = "f" };
        t.one = .{ .code = &one_code, .consts = &.{}, .slot_count = 1, .fixed_arity = 1, .name = "f" };
        t.rest = .{ .code = &rest_code, .consts = &.{}, .slot_count = 4, .fixed_arity = 3, .variadic = true, .name = "f" };
        t.fixed = .{ &t.none, &t.one };
        t.table = .{ .fixed = &t.fixed, .rest = &t.rest };
        inline for (.{ &t.none, &t.one, &t.rest }) |m| m.arities = &t.table;
    }

    const none_code = [_]vm_mod.Inst{ vm_mod.asm_.loadConst(0, 0), vm_mod.asm_.returnSlot(0) };
    const one_code = [_]vm_mod.Inst{vm_mod.asm_.returnSlot(0)};
    const rest_code = [_]vm_mod.Inst{vm_mod.asm_.returnSlot(3)};
};

/// Make `nexis.core/image-test-f` of `a` a closure over `t`'s
/// one-argument member.
fn defineTestArities(a: *VM, t: *TestArities) !void {
    t.init(try string_mod.fromBytes(a.ensureHeap(), "zero"));
    const f = try (try a.ensureRegistry()).core.intern("image-test-f");
    f.root = try a.allocClosure(&t.one, 0);
    f.bound = true;
}

/// The image of what `a`, which booted no sources, holds.
fn testWrite(gpa: Allocator, a: *VM) ![]u8 {
    var natives = try NativeIndex.scan(gpa, try a.ensureRegistry());
    defer natives.deinit(gpa);
    var why: []const u8 = "";
    return write(gpa, a, &natives, &.{}, .{ .auto_gensyms = 0, .gensyms = 0 }, &why);
}

test "load: an arity table comes back whole, every member written and run" {
    const gpa = std.testing.allocator;
    var a = try VM.init(gpa, &VM.idle_routine);
    defer a.deinit();
    var t: TestArities = undefined;
    try defineTestArities(&a, &t);
    const bytes = try testWrite(gpa, &a);
    defer gpa.free(bytes);
    var b = try VM.init(gpa, &VM.idle_routine);
    defer b.deinit();
    _ = try load(&b, bytes, &.{});
    var why: []const u8 = "";
    verify(gpa, &a, &b, &why) catch |err| {
        std.debug.print("image differs: {s}\n", .{why});
        gpa.free(why);
        return err;
    };
    const f = (try b.ensureRegistry()).core.lookupLocal("image-test-f").?.root;
    const loaded = VM.asClosure(f).routine;
    try std.testing.expect(loaded.arities != null and loaded.arities.?.rest.?.arities == loaded.arities);
    try std.testing.expectEqualStrings("zero", string_mod.asBytes(try b.callValue(f, &.{})));
    const seven = value_mod.fromFixnum(7).?;
    try std.testing.expectEqual(seven, try b.callValue(f, &.{seven}));
    const rest = try b.callValue(f, &.{ seven, seven, seven, seven });
    try std.testing.expectEqual(@as(usize, 1), list_mod.count(rest));
    try std.testing.expectError(error.ArityMismatch, b.callValue(f, &.{ seven, seven }));
    try std.testing.expectEqualStrings("f takes 0, 1 or at least 3 arguments, got 2", b.error_detail);
}

test "load: an arity table a call cannot pick from is refused, not loaded" {
    if (!verify_routines) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // A member at another arity's place, and a rest clause below a
    // fixed arity.
    for (0..2) |case| {
        var a = try VM.init(gpa, &VM.idle_routine);
        defer a.deinit();
        var t: TestArities = undefined;
        try defineTestArities(&a, &t);
        if (case == 0) t.fixed = .{ &t.one, &t.none } else t.rest.fixed_arity = 0;
        const bytes = try testWrite(gpa, &a);
        defer gpa.free(bytes);
        var b = try VM.init(gpa, &VM.idle_routine);
        defer b.deinit();
        try std.testing.expectError(error.UnfitRoutine, load(&b, bytes, &.{}));
    }
}
