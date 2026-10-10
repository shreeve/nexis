//! imagegen.zig — the build's standard-library image generator.
//!
//! `nexis-imagegen OUT` boots the embedded sources as a runtime with no
//! image does, writes the image of what they left to OUT, loads that
//! image into a second runtime and compares the two (`image.verify`),
//! so an image that does not reproduce the boot fails the build
//! instead of shipping (docs/STDLIB.md §1). The build runs it on the
//! host and embeds OUT in every binary.

const std = @import("std");
const vm = @import("vm.zig");
const expand_mod = @import("expand.zig");
const loader_mod = @import("loader.zig");
const stdlib = @import("stdlib.zig");
const image = @import("image.zig");

const Runtime = struct {
    v: vm.VM,
    host_macros: expand_mod.HostMacroTable,
    loader: loader_mod.Loader,

    /// In place: the loader keeps pointers into the runtime.
    fn init(rt: *Runtime, gpa: std.mem.Allocator, io: std.Io) !void {
        rt.v = try vm.VM.init(gpa, &vm.VM.idle_routine);
        rt.v.io = io;
        const interner = rt.v.ensureInterner();
        const registry = try rt.v.ensureRegistry();
        rt.host_macros = try expand_mod.defaultMacros(gpa);
        rt.loader = loader_mod.Loader.init(gpa, rt.v.runtime_arena.allocator(), io, &.{}, &rt.v, interner, registry, &rt.host_macros);
    }
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return fail(io, "usage: nexis-imagegen OUT", .{});

    var booted: Runtime = undefined;
    try booted.init(gpa, io);
    var why: []const u8 = "";
    const bytes = stdlib.writeImage(&booted.loader, gpa, &why) catch |err| {
        const d = booted.loader.diagnostic;
        return fail(io, "the stdlib does not boot or has no image: {t} {s}{s}", .{ err, if (d) |x| x.label else "", why });
    };
    if (!image.matches(bytes, &stdlib.embedded)) return fail(io, "the image does not match the sources it was written from", .{});

    var loaded: Runtime = undefined;
    try loaded.init(gpa, io);
    stdlib.bootFrom(&loaded.loader, bytes) catch |err| return fail(io, "the image does not load: {t}", .{err});
    image.verify(gpa, &booted.v, &loaded.v, &why) catch |err| return fail(io, "the loaded image differs from the boot: {t}: {s}", .{ err, why });

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = bytes });
    return 0;
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) u8 {
    var buf: [512]u8 = undefined;
    const msg = std.mem.print(&buf, "nexis-imagegen: " ++ fmt ++ "\n", args) catch "nexis-imagegen: failed\n";
    std.Io.File.stderr().writeStreamingAll(io, msg) catch {};
    return 1;
}
