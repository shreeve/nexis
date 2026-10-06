//! golden.zig — the reader golden printer (`zig build golden`).
//!
//! `nexis-golden FILE` reads FILE as a program and prints to stdout
//! what the reader made of it: the Form program (`reader.writeProgram`,
//! docs/FORMS.md §5) and status 0, or the refusal as one line,
//! `:kind` with ` :detail "..."` when the reader gave one, and status
//! 3, the CLI's status for a reader error. The build pins stdout to
//! `test/golden/<name>.sexp` or `test/golden/errors/<name>.err` and
//! the status to the case's directory.

const std = @import("std");
const parser = @import("parser.zig");
const reader = @import("reader.zig");
const stack = @import("stack.zig");

pub fn main(init: std.process.Init) !u8 {
    // The reader recurses on nesting; the guard turns input nested
    // past the main thread's stack into :nesting-too-deep.
    stack.arm(stack.main_thread_budget);
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: nexis-golden FILE\n", .{});
        return 2;
    }
    const source = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .unlimited);
    defer gpa.free(source);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const status = try print(gpa, source, &out.writer);
    try std.Io.File.stdout().writeStreamingAll(io, out.written());
    return status;
}

fn print(gpa: std.mem.Allocator, source: []const u8, w: *std.Io.Writer) !u8 {
    var p = parser.Parser.init(gpa, source);
    defer p.deinit();
    const tree = p.parseProgram() catch |err| {
        try w.print(":parser-error {t}\n", .{err});
        return 3;
    };
    var rd = reader.Reader.init(gpa, source);
    defer rd.deinit();
    const forms = rd.readProgram(tree) catch |err| {
        const e = rd.err orelse return err;
        // Kebab case, as FORMS.md spells the kinds; the Zig names are
        // snake case.
        try w.writeByte(':');
        for (@tagName(e.kind)) |ch| try w.writeByte(if (ch == '_') '-' else ch);
        if (e.detail) |d| try w.print(" :detail \"{s}\"", .{d});
        try w.writeByte('\n');
        return 3;
    };
    try reader.writeProgram(forms, w);
    return 0;
}
