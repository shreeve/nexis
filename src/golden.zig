//! golden.zig — Phase 0 golden test runner.
//!
//! Usage:
//!   nexis-golden --verify <dir>     (default via `zig build golden`)
//!   nexis-golden --update <dir>     (via `zig build golden -Dupdate=true`)
//!
//! Walks <dir> looking for `*.nx` source files and two expected shapes:
//!
//!   Happy-path: `<name>.nx` + `<name>.sexp`
//!       Reader should succeed; pretty-printed Form program must match
//!       `<name>.sexp` byte-for-byte.
//!
//!   Error path: `<dir>/errors/<name>.nx` + `<name>.err`
//!       Reader must fail with `:<kind>` (optionally ` :detail "..."`).
//!
//! Mismatches print a diff to stderr and exit 1. In update mode, expected
//! files are rewritten in place and the runner exits 0.

const std = @import("std");
const parser = @import("parser.zig");
const reader = @import("reader.zig");

const Mode = enum { verify, update };

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: Mode = .verify;
    var dir_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verify")) mode = .verify
        else if (std.mem.eql(u8, arg, "--update")) mode = .update
        else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("unknown flag: {s}\n", .{arg});
            return 2;
        } else dir_path = arg;
    }
    const root = dir_path orelse {
        std.debug.print("usage: nexis-golden [--verify|--update] <dir>\n", .{});
        return 2;
    };

    var stats: Stats = .{};
    try walkDir(gpa, io, root, mode, &stats, false);

    const errors_sub = try std.fs.path.join(gpa, &.{ root, "errors" });
    defer gpa.free(errors_sub);
    walkDir(gpa, io, errors_sub, mode, &stats, true) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    std.debug.print("golden: ok={d} updated={d} failed={d} missing={d}\n", .{ stats.ok, stats.updated, stats.failed, stats.missing });
    // Missing expected files are a verification failure — silent greens on
    // absent `.sexp` / `.err` files would let whole test cases disappear
    // unnoticed. In `--update` mode the runner regenerates them instead
    // and `missing` is zero by construction.
    if (stats.failed > 0 or stats.missing > 0) return 1;
    return 0;
}

const Stats = struct {
    ok: u32 = 0,
    updated: u32 = 0,
    failed: u32 = 0,
    missing: u32 = 0,
};

fn walkDir(gpa: std.mem.Allocator, io: std.Io, path: []const u8, mode: Mode, stats: *Stats, is_errors: bool) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        else => return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".nx")) continue;
        const stem = entry.name[0 .. entry.name.len - 3];
        try runCase(gpa, io, path, stem, mode, stats, is_errors);
    }
}

fn runCase(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, stem: []const u8, mode: Mode, stats: *Stats, is_errors: bool) !void {
    const src_name = try std.fmt.allocPrint(gpa, "{s}.nx", .{stem});
    defer gpa.free(src_name);
    const src_path = try std.fs.path.join(gpa, &.{ dir, src_name });
    defer gpa.free(src_path);

    const source = try std.Io.Dir.cwd().readFileAlloc(io, src_path, gpa, .limited(1 << 20));
    defer gpa.free(source);

    var p = parser.Parser.init(gpa, source);
    defer p.deinit();

    var rd = reader.Reader.init(gpa, source);
    defer rd.deinit();

    if (is_errors) return runErrorCase(gpa, io, dir, stem, mode, stats, &p, &rd);

    const tree = p.parseProgram() catch |pe| {
        std.debug.print("✗ {s}.nx — parser error: {s}\n", .{ stem, @errorName(pe) });
        stats.failed += 1;
        return;
    };

    const forms = rd.readProgram(tree) catch {
        const e = rd.err orelse unreachable;
        std.debug.print("✗ {s}.nx — unexpected reader error :{s}\n", .{ stem, @tagName(e.kind) });
        stats.failed += 1;
        return;
    };

    var al: std.Io.Writer.Allocating = .init(gpa);
    defer al.deinit();
    try reader.writeProgram(forms, &al.writer);
    const actual = al.written();

    const sexp_name = try std.fmt.allocPrint(gpa, "{s}.sexp", .{stem});
    defer gpa.free(sexp_name);
    const sexp_path = try std.fs.path.join(gpa, &.{ dir, sexp_name });
    defer gpa.free(sexp_path);

    const expected = std.Io.Dir.cwd().readFileAlloc(io, sexp_path, gpa, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => {
            if (mode == .update) {
                try writeFile(io, sexp_path, actual);
                std.debug.print("＋ {s}.sexp (new)\n", .{stem});
                stats.updated += 1;
                return;
            }
            std.debug.print("? {s}.sexp — missing\n", .{stem});
            stats.missing += 1;
            return;
        },
        else => return e,
    };
    defer gpa.free(expected);

    if (std.mem.eql(u8, expected, actual)) {
        std.debug.print("✓ {s}.nx\n", .{stem});
        stats.ok += 1;
        return;
    }
    if (mode == .update) {
        try writeFile(io, sexp_path, actual);
        std.debug.print("↻ {s}.sexp (updated)\n", .{stem});
        stats.updated += 1;
        return;
    }
    std.debug.print("✗ {s}.nx — sexp mismatch\n--- expected ---\n{s}\n--- actual ---\n{s}\n", .{ stem, expected, actual });
    stats.failed += 1;
}

fn runErrorCase(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, stem: []const u8, mode: Mode, stats: *Stats, p: *parser.Parser, rd: *reader.Reader) !void {
    const tree = p.parseProgram() catch |pe| {
        const actual = try std.fmt.allocPrint(gpa, ":parser-error {s}", .{@errorName(pe)});
        defer gpa.free(actual);
        try compareErr(gpa, io, dir, stem, actual, mode, stats);
        return;
    };

    _ = rd.readProgram(tree) catch |err| switch (err) {
        error.ReaderFailure => {
            const e = rd.err orelse unreachable;
            var al: std.Io.Writer.Allocating = .init(gpa);
            defer al.deinit();
            // Kebab-case the error kind so `.err` files read naturally
            // alongside FORMS.md's examples. The Zig enum names are
            // snake_case by necessity.
            try al.writer.writeByte(':');
            for (@tagName(e.kind)) |ch| {
                try al.writer.writeByte(if (ch == '_') '-' else ch);
            }
            if (e.detail) |d| try al.writer.print(" :detail \"{s}\"", .{d});
            try compareErr(gpa, io, dir, stem, al.written(), mode, stats);
            return;
        },
        else => return err,
    };

    std.debug.print("✗ errors/{s}.nx — expected reader error, got success\n", .{stem});
    stats.failed += 1;
}

fn compareErr(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, stem: []const u8, actual: []const u8, mode: Mode, stats: *Stats) !void {
    const err_name = try std.fmt.allocPrint(gpa, "{s}.err", .{stem});
    defer gpa.free(err_name);
    const err_path = try std.fs.path.join(gpa, &.{ dir, err_name });
    defer gpa.free(err_path);

    const expected = std.Io.Dir.cwd().readFileAlloc(io, err_path, gpa, .limited(1 << 10)) catch |e| switch (e) {
        error.FileNotFound => {
            if (mode == .update) {
                const with_newline = try std.mem.concat(gpa, u8, &.{ actual, "\n" });
                defer gpa.free(with_newline);
                try writeFile(io, err_path, with_newline);
                std.debug.print("＋ errors/{s}.err (new)\n", .{stem});
                stats.updated += 1;
                return;
            }
            std.debug.print("? errors/{s}.err — missing\n", .{stem});
            stats.missing += 1;
            return;
        },
        else => return e,
    };
    defer gpa.free(expected);
    const exp_trim = std.mem.trimEnd(u8, expected, "\n \t");

    if (std.mem.eql(u8, exp_trim, actual)) {
        std.debug.print("✓ errors/{s}.nx\n", .{stem});
        stats.ok += 1;
        return;
    }
    if (mode == .update) {
        const with_newline = try std.mem.concat(gpa, u8, &.{ actual, "\n" });
        defer gpa.free(with_newline);
        try writeFile(io, err_path, with_newline);
        std.debug.print("↻ errors/{s}.err (updated)\n", .{stem});
        stats.updated += 1;
        return;
    }
    std.debug.print("✗ errors/{s}.nx mismatch\n  expected: {s}\n  actual:   {s}\n", .{ stem, exp_trim, actual });
    stats.failed += 1;
}

fn writeFile(io: std.Io, path: []const u8, body: []const u8) !void {
    var f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}
