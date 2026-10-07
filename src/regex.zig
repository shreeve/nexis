//! regex.zig — regular expressions in Java's syntax, matched in linear time.
//!
//! Authoritative spec: `docs/REGEX.md`. `compile` parses a pattern
//! into an AST in an arena, resolving every character class to a
//! sorted list of code-point ranges (case folding, negation and
//! intersection included), and lowers the AST to a flat program of
//! 12-byte instructions over code points. `Vm` runs a program as a
//! Pike VM: a Thompson NFA simulated over the UTF-8 input with
//! per-thread capture slots, in leftmost-first priority order.
//! Nothing backtracks: a search adds each (instruction, position)
//! pair at most once, so it costs O(n·m·k) for n input bytes, m
//! instructions and k slots, and the limits `compile` enforces bound
//! m and m·k. Constructs that need backtracking are refused when the
//! pattern compiles, with a sentence naming them.
//!
//! The Unicode data, the case mappings `(?iu)` folds by and the
//! general categories, are generated from Java's own tables
//! (`src/regex_tables.zig`, `test/regex/tables.clj`).

const std = @import("std");
const builtin = @import("builtin");
const stack = @import("stack.zig");
const string = @import("string.zig");
const tables = @import("regex_tables.zig");
const value_mod = @import("value.zig");
const heap_mod = @import("heap.zig");

const Allocator = std.mem.Allocator;
const Value = value_mod.Value;
const Heap = heap_mod.Heap;
const HeapHeader = heap_mod.HeapHeader;

/// The largest bound a counted repetition may name.
pub const max_repeat = 1000;
/// The largest program, counted after every repetition is expanded.
pub const max_insts = 10_000;
/// The most AST nodes the compiler visits, after every repetition is
/// expanded: a body that compiles to nothing still costs its nodes.
pub const max_nodes = 1_000_000;
/// The largest program size times capture slots: one thread list's slot words.
pub const max_slot_words = 1 << 20;
/// The most code-point ranges the classes of one program store, each
/// distinct set once.
pub const max_ranges = 1 << 16;
/// The memory compiling a pattern may take: this, plus `budget_per_byte`
/// for each byte of the pattern, so a literal of any length compiles.
pub const budget_base = 16 << 20;
pub const budget_per_byte = 32;
/// The deepest nesting of groups and character classes.
pub const max_nest = 250;

/// Java's inline flags; `(?U)` and `(?c)` are refused.
pub const Flags = packed struct(u8) {
    i: bool = false, // CASE_INSENSITIVE: ASCII letters fold.
    d: bool = false, // UNIX_LINES: `\n` is the only line terminator.
    m: bool = false, // MULTILINE: `^` and `$` hold at line boundaries.
    s: bool = false, // DOTALL: `.` matches line terminators.
    u: bool = false, // UNICODE_CASE: with `i`, every cased code point folds.
    x: bool = false, // COMMENTS: whitespace and `#` comments are ignored.
    _: u2 = 0,
};

/// An inclusive range of code points.
pub const Range = [2]u32;

pub const Op = enum(u8) {
    char, // a: a code point.
    class, // a: offset into the range table, b: range count.
    split, // a: the preferred pc, b: the other.
    jmp, // a: pc.
    save, // a: slot.
    mark, // a: hidden slot: where the current iteration of a nullable loop began.
    if_empty, // a: hidden slot, b: the loop's exit, taken when the iteration consumed nothing.
    assert, // a: an `Assert`.
    match,
};

pub const Inst = extern struct { op: Op, _pad: [3]u8 = @splat(0), a: u32 = 0, b: u32 = 0 };

pub const Assert = enum(u8) {
    begin, // `\A`, `^`
    end, // `\z`
    dollar, // `\Z`, `$`
    dollar_m, // `(?m)$`
    dollar_unix, // `(?d)$`
    dollar_unix_m, // `(?dm)$`
    caret_m, // `(?m)^`
    caret_unix_m, // `(?dm)^`
    word, // `\b`
    not_word, // `\B`
    last_end, // `\G`: the end of the previous match.
    not_lf, // Internal: no `\n` follows, for the atomic `\R`.
};

pub const Program = struct {
    insts: []const Inst,
    ranges: []const Range,
    /// Each named group as a u32 group number, a u32 length and the
    /// name's bytes, little-endian.
    names: []const u8,
    ngroups: u32,
    nhidden: u32,
    /// The whole pattern is this literal: found without the VM, and
    /// `insts` is empty.
    literal: ?[]const u8,
    /// Every match starts with these bytes (two or more), else empty.
    prefix: []const u8,
    /// The bytes a match can start with; null when it can start with
    /// any ASCII byte or be empty.
    first_bytes: ?std.bit_set.Static(256),
    /// Every match starts at offset 0.
    anchored: bool,

    /// The number of the group named `name`.
    pub fn groupIndex(p: *const Program, name: []const u8) ?u32 {
        return findName(p.names, name);
    }
};

pub const SyntaxError = struct {
    msg: []const u8,
    /// The byte offset in the source where the error was found.
    offset: usize,
};

pub const Compiled = union(enum) { ok: Program, err: SyntaxError };

/// Compile `source` with `flags`, allocating in `arena`. A syntax
/// error or a pattern past a limit is `.err`, never a Zig error.
pub fn compile(arena: Allocator, source: []const u8, flags: Flags) (Allocator.Error || stack.Error)!Compiled {
    var budget: Budget = .{ .child = arena, .left = budget_base +| budget_per_byte *| source.len };
    return compileIn(budget.allocator(), source, flags) catch |e| switch (e) {
        error.OutOfMemory => if (budget.spent) .{ .err = .{ .msg = "the pattern needs too much memory to compile", .offset = 0 } } else e,
        else => e,
    };
}

/// An allocator that refuses past `left` bytes: what one pattern's
/// sets and nodes may take while it compiles (docs/REGEX.md §4).
const Budget = struct {
    child: Allocator,
    left: usize,
    spent: bool = false,

    fn allocator(b: *Budget) Allocator {
        return .{ .ptr = b, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn take(b: *Budget, n: usize) bool {
        if (n > b.left) {
            b.spent = true;
            return false;
        }
        b.left -= n;
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        return if (b.take(len)) b.child.rawAlloc(len, alignment, ret) else null;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        return (len <= memory.len or b.take(len - memory.len)) and b.child.rawResize(memory, alignment, len, ret);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        return if (len <= memory.len or b.take(len - memory.len)) b.child.rawRemap(memory, alignment, len, ret) else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const b: *Budget = @ptrCast(@alignCast(ctx));
        b.child.rawFree(memory, alignment, ret);
    }
};

fn compileIn(arena: Allocator, source: []const u8, flags: Flags) (Allocator.Error || stack.Error)!Compiled {
    if (!std.unicode.utf8ValidateSlice(source)) return .{ .err = .{ .msg = "the pattern is not valid UTF-8", .offset = 0 } };
    var p: Parser = .{ .arena = arena, .src = source, .flags = flags };
    try p.unquote();
    const root = p.parse() catch |e| return switch (e) {
        error.Syntax => .{ .err = p.err },
        error.OutOfMemory => error.OutOfMemory,
        error.StackOverflow => error.StackOverflow,
    };
    if (try literalOf(arena, root)) |lit| return .{ .ok = .{
        .insts = &.{},
        .ranges = &.{},
        .names = &.{},
        .ngroups = 0,
        .nhidden = 0,
        .literal = lit,
        .prefix = lit,
        .first_bytes = null,
        .anchored = false,
    } };
    var c: Compiler = .{ .arena = arena };
    const prog = c.program(root, p.ngroups, p.names.items) catch |e| return switch (e) {
        error.TooBig => .{ .err = .{ .msg = "the pattern compiles to more than 10000 instructions", .offset = 0 } },
        error.TooManySlots => .{ .err = .{ .msg = "the pattern has too many groups for its size", .offset = 0 } },
        error.TooManyNodes => .{ .err = .{ .msg = "the pattern expands to more than 1000000 nodes", .offset = 0 } },
        error.TooManyRanges => .{ .err = .{ .msg = "the pattern's classes hold more than 65536 ranges", .offset = 0 } },
        error.OutOfMemory => error.OutOfMemory,
        error.StackOverflow => error.StackOverflow,
    };
    return .{ .ok = prog };
}

// =============================================================================
// Code points and sets
// =============================================================================

const Cp = struct { c: u21, len: u3 };

/// Not a code point: what `decode` gives for a malformed byte, which
/// no instruction accepts.
const bad: u21 = 0x1FFFFF;

/// The code point at `s[i]`. A malformed byte decodes as `bad`, one
/// byte long, so a search over invalid input ends without faulting.
fn decode(s: []const u8, i: usize) Cp {
    const b = s[i];
    if (b < 0x80) return .{ .c = b, .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .c = bad, .len = 1 };
    if (i + n > s.len) return .{ .c = bad, .len = 1 };
    const c = std.unicode.utf8Decode(s[i..][0..n]) catch return .{ .c = bad, .len = 1 };
    return .{ .c = c, .len = n };
}

/// The start of the code point that ends at `i` (`i > 0`).
fn prevStart(s: []const u8, i: usize) usize {
    var q = i - 1;
    while (q > 0 and i - q < 4 and s[q] & 0xC0 == 0x80) q -= 1;
    return q;
}

fn isTerminator(c: u21) bool {
    return c == '\n' or c == '\r' or c == 0x85 or c == 0x2028 or c == 0x2029;
}

fn inSet(ranges: []const Range, c: u32) bool {
    var lo: usize = 0;
    var hi = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (ranges[mid][1] < c) lo = mid + 1 else hi = mid;
    }
    return lo < ranges.len and ranges[lo][0] <= c;
}

fn lessThan(_: void, a: Range, b: Range) bool {
    return a[0] < b[0];
}

/// Sort `rs` and merge overlapping and adjacent ranges, in place.
fn normalize(rs: []Range) []Range {
    if (rs.len == 0) return rs;
    std.mem.sortUnstable(Range, rs, {}, lessThan);
    var n: usize = 0;
    for (rs[1..]) |r| {
        if (r[0] <= rs[n][1] +| 1) {
            rs[n][1] = @max(rs[n][1], r[1]);
        } else {
            n += 1;
            rs[n] = r;
        }
    }
    return rs[0 .. n + 1];
}

/// A union built one operand at a time, null until the first (an
/// empty union differs from none). Operands are appended and merged
/// when the list has doubled, so a class of n items costs O(n log n),
/// not a copy of the union per item.
const Union = struct {
    list: ?std.ArrayList(Range) = null,
    merged: usize = 0,

    fn add(u: *Union, arena: Allocator, set: []const Range) Allocator.Error!void {
        if (u.list == null) u.list = .empty;
        const l = &u.list.?;
        try l.appendSlice(arena, set);
        if (l.items.len > 2 * u.merged + 64) {
            l.items = normalize(l.items);
            u.merged = l.items.len;
        }
    }

    /// The union so far, a copy later operands leave alone.
    fn get(u: *Union, arena: Allocator) Allocator.Error!?[]const Range {
        const l = if (u.list) |*l| l else return null;
        l.items = normalize(l.items);
        u.merged = l.items.len;
        return try arena.dupe(Range, l.items);
    }
};

fn intersect(arena: Allocator, a: []const Range, b: []const Range) Allocator.Error![]const Range {
    var out: std.ArrayList(Range) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const lo = @max(a[i][0], b[j][0]);
        const hi = @min(a[i][1], b[j][1]);
        if (lo <= hi) try out.append(arena, .{ lo, hi });
        if (a[i][1] < b[j][1]) i += 1 else j += 1;
    }
    return out.items;
}

fn complement(arena: Allocator, a: []const Range) Allocator.Error![]const Range {
    var out: std.ArrayList(Range) = .empty;
    var next: u32 = 0;
    for (a) |r| {
        if (r[0] > next) try out.append(arena, .{ next, r[0] - 1 });
        next = r[1] + 1;
    }
    if (next <= 0x10FFFF) try out.append(arena, .{ next, 0x10FFFF });
    return out.items;
}

fn one(arena: Allocator, lo: u32, hi: u32) Allocator.Error![]const Range {
    const out = try arena.alloc(Range, 1);
    out[0] = .{ lo, hi };
    return out;
}

const sets = struct {
    const all = [_]Range{.{ 0, 0x10FFFF }};
    const digit = [_]Range{.{ '0', '9' }};
    const word = [_]Range{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } };
    const space = [_]Range{ .{ '\t', '\r' }, .{ ' ', ' ' } };
    const hspace = [_]Range{ .{ '\t', '\t' }, .{ ' ', ' ' }, .{ 0xA0, 0xA0 }, .{ 0x1680, 0x1680 }, .{ 0x180E, 0x180E }, .{ 0x2000, 0x200A }, .{ 0x202F, 0x202F }, .{ 0x205F, 0x205F }, .{ 0x3000, 0x3000 } };
    const vspace = [_]Range{ .{ '\n', '\r' }, .{ 0x85, 0x85 }, .{ 0x2028, 0x2029 } };
    /// `\R`'s single code points other than `\r`.
    const line_end = [_]Range{ .{ '\n', 0x0C }, .{ 0x85, 0x85 }, .{ 0x2028, 0x2029 } };
    const dot = [_]Range{ .{ 0, 9 }, .{ 0x0B, 0x0C }, .{ 0x0E, 0x84 }, .{ 0x86, 0x2027 }, .{ 0x202A, 0x10FFFF } };
    const dot_unix = [_]Range{ .{ 0, 9 }, .{ 0x0B, 0x10FFFF } };
    const latin1 = [_]Range{.{ 0, 0xFF }};
    const alpha = [_]Range{ .{ 'A', 'Z' }, .{ 'a', 'z' } };
    /// The POSIX classes, ASCII as Java's are.
    const posix = [_]struct { []const u8, []const Range }{
        .{ "Lower", &.{.{ 'a', 'z' }} },
        .{ "Upper", &.{.{ 'A', 'Z' }} },
        .{ "ASCII", &.{.{ 0, 0x7F }} },
        .{ "Alpha", &alpha },
        .{ "Digit", &digit },
        .{ "Alnum", &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ 'a', 'z' } } },
        .{ "Punct", &.{ .{ '!', '/' }, .{ ':', '@' }, .{ '[', '`' }, .{ '{', '~' } } },
        .{ "Graph", &.{.{ '!', '~' }} },
        .{ "Print", &.{.{ ' ', '~' }} },
        .{ "Blank", &.{ .{ '\t', '\t' }, .{ ' ', ' ' } } },
        .{ "Cntrl", &.{ .{ 0, 0x1F }, .{ 0x7F, 0x7F } } },
        .{ "XDigit", &.{ .{ '0', '9' }, .{ 'A', 'F' }, .{ 'a', 'f' } } },
        .{ "Space", &space },
    };
};

// =============================================================================
// Unicode: case mappings and general categories (Java's)
// =============================================================================

fn mapRun(runs: []const tables.Run, c: u21) u21 {
    var lo: usize = 0;
    var hi = runs.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (runs[mid][0] <= c) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return c;
    const r = runs[lo - 1];
    if (c > r[1] or (c - r[0]) % r[2] != 0) return c;
    return @intCast(@as(i32, c) + r[3]);
}

/// `Character.toUpperCase`.
fn upper(c: u21) u21 {
    return mapRun(&tables.upper, c);
}

/// `Character.toLowerCase(Character.toUpperCase(c))`.
fn fold(c: u21) u21 {
    return mapRun(&tables.fold, c);
}

/// Append the code points `runs` maps into `[lo, hi]` (other than to themselves).
fn preimage(arena: Allocator, out: *std.ArrayList(Range), runs: []const tables.Run, lo: u32, hi: u32) Allocator.Error!void {
    for (runs) |r| {
        const first: i64 = r[0];
        const s_lo = @max(first, @as(i64, lo) - r[3]);
        const s_hi = @min(@as(i64, r[1]), @as(i64, hi) - r[3]);
        if (s_lo > s_hi) continue;
        if (r[2] == 1) {
            try out.append(arena, .{ @intCast(s_lo), @intCast(s_hi) });
        } else {
            var s = s_lo + @mod(s_lo - first, 2);
            while (s <= s_hi) : (s += 2) try out.append(arena, .{ @intCast(s), @intCast(s) });
        }
    }
}

const mn = 6; // NON_SPACING_MARK

/// `Character.getType`.
fn category(c: u21) u5 {
    const t = &tables.categories;
    var lo: usize = 0;
    var hi = t.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (t[mid] >> 5 <= c) lo = mid + 1 else hi = mid;
    }
    return @truncate(t[lo - 1]);
}

/// `Character.isLetterOrDigit`: Lu Ll Lt Lm Lo Nd.
fn isLetterOrDigit(c: u21) bool {
    return (@as(u32, 1) << category(c)) & 0b10_0011_1110 != 0;
}

/// Java's general-category names, numbered as `Character.getType`.
const category_names = [_][]const u8{ "Cn", "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Me", "Mc", "Nd", "Nl", "No", "Zs", "Zl", "Zp", "Cc", "Cf", "", "Co", "Cs", "Pd", "Ps", "Pe", "Pc", "Po", "Sm", "Sc", "Sk", "So", "Pi", "Pf" };

fn bits(comptime cats: []const u5) u32 {
    var m: u32 = 0;
    for (cats) |c| m |= @as(u32, 1) << c;
    return m;
}

const cased = bits(&.{ 1, 2, 3 });
const category_groups = [_]struct { []const u8, u32 }{
    .{ "L", bits(&.{ 1, 2, 3, 4, 5 }) },
    .{ "M", bits(&.{ 6, 7, 8 }) },
    .{ "N", bits(&.{ 9, 10, 11 }) },
    .{ "Z", bits(&.{ 12, 13, 14 }) },
    .{ "C", bits(&.{ 0, 15, 16, 18, 19 }) },
    .{ "P", bits(&.{ 20, 21, 22, 23, 24, 29, 30 }) },
    .{ "S", bits(&.{ 25, 26, 27, 28 }) },
    .{ "LC", cased },
    .{ "LD", bits(&.{ 1, 2, 3, 4, 5, 9 }) },
};

fn categoryMask(name: []const u8) ?u32 {
    for (category_names, 0..) |n, i| if (n.len > 0 and std.mem.eql(u8, n, name)) return @as(u32, 1) << @intCast(i);
    for (category_groups) |g| if (std.mem.eql(u8, g[0], name)) return g[1];
    return null;
}

// =============================================================================
// The AST
// =============================================================================

const inf = std.math.maxInt(u32);

const Fold = enum { none, ascii, unicode };

const Node = union(enum) {
    empty,
    /// A run of literal code points: Java's slice when it holds two or
    /// more, which `(?iu)` folds by a different rule than one.
    lit: struct { cps: []const u21, fold: Fold },
    class: []const Range,
    assert: Assert,
    /// `\R`.
    line_end,
    /// Group 0 is a non-capturing group.
    group: struct { index: u32, body: *Node },
    concat: []*Node,
    alt: []*Node,
    repeat: Repeat,
};

const Repeat = struct {
    body: *Node,
    min: u32,
    max: u32,
    greedy: bool,
    /// Written `?`: Java compiles it as a plain branch, without the
    /// empty-iteration rule of its loops.
    ques: bool,
    /// The hidden slot of a nullable body, shared by every copy.
    hidden: ?u32 = null,
    /// The body can match empty; it is `deterministic`. Found once,
    /// when the repetition is parsed, so neither walks a body again.
    body_nullable: bool,
    body_deterministic: bool,
};

fn nullable(n: *const Node) stack.Error!bool {
    try stack.check();
    return switch (n.*) {
        .empty, .assert => true,
        .lit => |l| l.cps.len == 0,
        .class, .line_end => false,
        .group => |g| nullable(g.body),
        .concat => |items| for (items) |i| {
            if (!try nullable(i)) break false;
        } else true,
        .alt => |items| for (items) |i| {
            if (try nullable(i)) break true;
        } else false,
        .repeat => |r| r.min == 0 or r.body_nullable,
    };
}

/// Java's notion: no alternation and no variable repetition, so the
/// body of a repetition is matched as one atomic unit.
fn deterministic(n: *const Node) stack.Error!bool {
    try stack.check();
    return switch (n.*) {
        .empty, .lit, .class, .assert, .line_end => true,
        .group => |g| deterministic(g.body),
        .concat => |items| for (items) |i| {
            if (!try deterministic(i)) break false;
        } else true,
        .alt => false,
        .repeat => |r| !r.ques and r.min == r.max and r.body_deterministic,
    };
}

/// The whole pattern as literal bytes, when it is one.
fn literalOf(arena: Allocator, root: *const Node) Allocator.Error!?[]const u8 {
    const items: []const *const Node = switch (root.*) {
        .lit => (&root)[0..1],
        .concat => |items| items,
        else => return null,
    };
    var out: std.ArrayList(u8) = .empty;
    for (items) |n| {
        if (n.* != .lit or n.lit.fold != .none) return null;
        for (n.lit.cps) |c| {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(c, &buf) catch return null;
            try out.appendSlice(arena, buf[0..len]);
        }
    }
    return if (out.items.len > 0) out.items else null;
}

fn findName(names: []const u8, name: []const u8) ?u32 {
    var i: usize = 0;
    while (i + 8 <= names.len) {
        const index = std.mem.readInt(u32, names[i..][0..4], .little);
        const len = std.mem.readInt(u32, names[i + 4 ..][0..4], .little);
        if (std.mem.eql(u8, names[i + 8 ..][0..len], name)) return index;
        i += 8 + len;
    }
    return null;
}

// =============================================================================
// The parser
// =============================================================================

const unsupported_property = "Unicode scripts, blocks and binary properties are not supported";
const lookaround = "lookahead and lookbehind are not supported";

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    /// The caller's offset of each byte of `src`, and of its end, when
    /// `\Q...\E` was rewritten.
    map: ?[]const u32 = null,
    pos: usize = 0,
    flags: Flags,
    depth: u32 = 0,
    ngroups: u32 = 0,
    names: std.ArrayList(u8) = .empty,
    categories: std.ArrayList(struct { u32, []const Range }) = .empty,
    err: SyntaxError = undefined,

    const Fail = error{ Syntax, OutOfMemory, StackOverflow };

    fn fail(p: *Parser, at: usize, msg: []const u8) Fail {
        const offset = if (p.map) |m| m[@min(at, m.len - 1)] else at;
        p.err = .{ .msg = msg, .offset = offset };
        return error.Syntax;
    }

    fn failf(p: *Parser, at: usize, comptime fmt: []const u8, args: anytype) Fail {
        return p.fail(at, try p.arena.print(fmt, args));
    }

    /// The code point before `cursor`: where Java reports most of its
    /// errors, its index being one less than its cursor.
    fn before(p: *const Parser, cursor: usize) usize {
        return if (cursor == 0) 0 else prevStart(p.src, cursor);
    }

    fn node(p: *Parser, n: Node) Fail!*Node {
        const r = try p.arena.create(Node);
        r.* = n;
        return r;
    }

    /// Rewrite `\Q...\E` into escaped characters, as Java does before
    /// parsing: a quoted letter or non-ASCII character stays, any other
    /// gains a backslash, and a digit that opens the quote becomes `\x3d`
    /// so an escape before the quote cannot absorb it.
    fn unquote(p: *Parser) Allocator.Error!void {
        const s = p.src;
        var i: usize = 0;
        while (i + 1 < s.len) : (i += 1) {
            if (s[i] != '\\') continue;
            if (s[i + 1] == 'Q') break;
            i += 1;
        }
        if (i + 1 >= s.len) return;
        var out: std.ArrayList(u8) = .empty;
        var map: std.ArrayList(u32) = .empty;
        const emit = struct {
            fn f(a: Allocator, o: *std.ArrayList(u8), m: *std.ArrayList(u32), bytes: []const u8, at: usize) Allocator.Error!void {
                try o.appendSlice(a, bytes);
                for (bytes) |_| try m.append(a, @intCast(at));
            }
        }.f;
        try emit(p.arena, &out, &map, s[0..i], 0);
        for (map.items, 0..) |*m, k| m.* = @intCast(k);
        i += 2;
        var quoting = true;
        var begin = true;
        while (i < s.len) {
            const n = decode(s, i).len;
            if (quoting) {
                if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == 'E') {
                    quoting = false;
                    i += 2;
                    continue;
                }
                const b = s[i];
                if (b >= 0x80 or std.ascii.isAlphabetic(b)) {
                    try emit(p.arena, &out, &map, s[i..][0..n], i);
                } else if (std.ascii.isDigit(b)) {
                    if (begin) try emit(p.arena, &out, &map, "\\x3", i);
                    try emit(p.arena, &out, &map, s[i..][0..1], i);
                } else {
                    try emit(p.arena, &out, &map, &.{ '\\', b }, i);
                }
                begin = false;
                i += n;
            } else if (s[i] == '\\' and i + 1 < s.len) {
                if (s[i + 1] == 'Q') {
                    quoting = true;
                    begin = true;
                    i += 2;
                    continue;
                }
                const len = 1 + @as(usize, decode(s, i + 1).len);
                try emit(p.arena, &out, &map, s[i..][0..len], i);
                i += len;
            } else {
                try emit(p.arena, &out, &map, s[i..][0..n], i);
                i += n;
            }
        }
        try map.append(p.arena, @intCast(s.len));
        p.src = out.items;
        p.map = map.items;
    }

    /// Skip whitespace and `#` comments in comments mode.
    fn skipSpace(p: *Parser) void {
        if (!p.flags.x) return;
        while (p.pos < p.src.len) switch (p.src[p.pos]) {
            ' ', '\t', '\n', 0x0B, 0x0C, '\r' => p.pos += 1,
            '#' => while (p.pos < p.src.len) {
                const cp = decode(p.src, p.pos);
                p.pos += cp.len;
                if (cp.c == '\n' or (!p.flags.d and (cp.c == '\r' or cp.c == 0x2028 or cp.c == 0x2029))) break;
            },
            else => return,
        };
    }

    /// The next code point, after any whitespace comments mode skips.
    fn peek(p: *Parser) ?u21 {
        p.skipSpace();
        return if (p.pos < p.src.len) decode(p.src, p.pos).c else null;
    }

    /// Step past the code point `peek` returned.
    fn advance(p: *Parser) void {
        p.pos += decode(p.src, p.pos).len;
    }

    fn rawIs(p: *Parser, at: usize, b: u8) bool {
        return at < p.src.len and p.src[at] == b;
    }

    fn foldMode(p: *const Parser) Fold {
        return if (!p.flags.i) .none else if (p.flags.u) .unicode else .ascii;
    }

    fn parse(p: *Parser) Fail!*Node {
        const root = try p.alternation();
        if (p.peek() != null) return p.fail(p.before(p.pos), "Unmatched closing ')'");
        return root;
    }

    fn alternation(p: *Parser) Fail!*Node {
        try stack.check();
        var branches: std.ArrayList(*Node) = .empty;
        while (true) {
            try branches.append(p.arena, try p.sequence());
            if (p.peek() != '|') break;
            p.pos += 1;
        }
        if (branches.items.len == 1) return branches.items[0];
        return p.node(.{ .alt = branches.items });
    }

    fn sequence(p: *Parser) Fail!*Node {
        var items: std.ArrayList(*Node) = .empty;
        while (p.peek()) |c| {
            const atom = switch (c) {
                '|', ')' => break,
                '(' => (try p.group()) orelse continue,
                '[' => blk: {
                    p.pos += 1;
                    break :blk try p.classNode(try p.class(true));
                },
                '.' => blk: {
                    p.pos += 1;
                    break :blk try p.classNode(if (p.flags.s) &sets.all else if (p.flags.d) &sets.dot_unix else &sets.dot);
                },
                '^' => blk: {
                    p.pos += 1;
                    break :blk try p.node(.{ .assert = if (!p.flags.m) .begin else if (p.flags.d) .caret_unix_m else .caret_m });
                },
                '$' => blk: {
                    p.pos += 1;
                    break :blk try p.node(.{ .assert = if (p.flags.d)
                        (if (p.flags.m) .dollar_unix_m else .dollar_unix)
                    else if (p.flags.m) .dollar_m else .dollar });
                },
                '*', '+', '?' => {
                    p.pos += 1;
                    p.skipSpace();
                    return p.failf(p.before(p.pos), "Dangling meta character '{c}'", .{@as(u8, @intCast(c))});
                },
                // Java reads an empty atom here, which a valid bound repeats.
                '{' => try p.node(.empty),
                else => try p.run(),
            };
            try items.append(p.arena, try p.quantifier(atom));
        }
        return switch (items.items.len) {
            0 => p.node(.empty),
            1 => items.items[0],
            else => p.node(.{ .concat = items.items }),
        };
    }

    fn classNode(p: *Parser, set: []const Range) Fail!*Node {
        return p.node(.{ .class = set });
    }

    /// A run of literal characters, as Java's `atom` collects one: it
    /// ends at a metacharacter or a non-literal escape, and gives back
    /// its last character when a quantifier follows, so the quantifier
    /// applies to that character alone. A run that starts with a
    /// non-literal escape is that escape's node.
    fn run(p: *Parser) Fail!*Node {
        var cps: std.ArrayList(u21) = .empty;
        var last = p.pos;
        while (p.peek()) |c| {
            switch (c) {
                '*', '+', '?', '{' => {
                    if (cps.items.len > 1) {
                        p.pos = last;
                        cps.items.len -= 1;
                    }
                    break;
                },
                '$', '.', '^', '(', '[', '|', ')' => break,
                '\\' => {
                    const at = p.pos;
                    if (p.rawIs(at + 1, 'p') or p.rawIs(at + 1, 'P')) {
                        if (cps.items.len > 0) break;
                        return p.classNode(try p.family());
                    }
                    switch (try p.escape(false, false)) {
                        .lit => |cp| {
                            last = at;
                            try cps.append(p.arena, cp);
                        },
                        .set => |s| {
                            if (cps.items.len > 0) {
                                p.pos = at;
                                break;
                            }
                            return p.classNode(s);
                        },
                        .node => |n| {
                            if (cps.items.len > 0) {
                                p.pos = at;
                                break;
                            }
                            return n;
                        },
                    }
                },
                else => {
                    last = p.pos;
                    try cps.append(p.arena, c);
                    p.advance();
                },
            }
        }
        return p.node(.{ .lit = .{ .cps = cps.items, .fold = p.foldMode() } });
    }

    const Escape = union(enum) { lit: u21, set: []const Range, node: *Node };

    /// The escape at `p.pos` (its backslash). `range` reads `\v` as
    /// VT, as Java does where the escape bounds a class range.
    fn escape(p: *Parser, in_class: bool, range: bool) Fail!Escape {
        const at = p.pos;
        p.pos += 1;
        if (p.pos >= p.src.len) return p.fail(p.pos, "Unescaped trailing backslash");
        const cp = decode(p.src, p.pos);
        p.pos += cp.len;
        if (!in_class) switch (cp.c) {
            '1'...'9', 'k' => return p.fail(at, "backreferences are not supported"),
            'A' => return .{ .node = try p.node(.{ .assert = .begin }) },
            'z' => return .{ .node = try p.node(.{ .assert = .end }) },
            'Z' => return .{ .node = try p.node(.{ .assert = if (p.flags.d) .dollar_unix else .dollar }) },
            'G' => return .{ .node = try p.node(.{ .assert = .last_end }) },
            'B' => return .{ .node = try p.node(.{ .assert = .not_word }) },
            'b' => {
                if (std.mem.startsWith(u8, p.src[p.pos..], "{g}")) return p.fail(at, "\\b{g} (grapheme boundaries) is not supported");
                return .{ .node = try p.node(.{ .assert = .word }) };
            },
            'R' => return .{ .node = try p.node(.line_end) },
            'X' => return p.fail(at, "\\X (grapheme clusters) is not supported"),
            'N' => return p.fail(at, "\\N{...} (named characters) is not supported"),
            else => {},
        };
        const set: []const Range = switch (cp.c) {
            '0' => return .{ .lit = try p.octal() },
            'a' => return .{ .lit = 0x07 },
            'e' => return .{ .lit = 0x1B },
            'f' => return .{ .lit = 0x0C },
            'n' => return .{ .lit = '\n' },
            'r' => return .{ .lit = '\r' },
            't' => return .{ .lit = '\t' },
            'x' => return .{ .lit = try p.hex() },
            'u' => return .{ .lit = try p.unicode() },
            'c' => {
                if (p.pos >= p.src.len) return p.fail(p.before(p.pos), "Illegal control escape sequence");
                const d = decode(p.src, p.pos);
                p.pos += d.len;
                return .{ .lit = d.c ^ 64 };
            },
            'v' => if (range) return .{ .lit = 0x0B } else &sets.vspace,
            'd' => &sets.digit,
            's' => &sets.space,
            'w' => &sets.word,
            'h' => &sets.hspace,
            'D' => try complement(p.arena, &sets.digit),
            'S' => try complement(p.arena, &sets.space),
            'W' => try complement(p.arena, &sets.word),
            'H' => try complement(p.arena, &sets.hspace),
            'V' => try complement(p.arena, &sets.vspace),
            else => if (cp.c < 0x80 and std.ascii.isAlphanumeric(@intCast(cp.c)))
                return p.fail(p.before(p.pos), "Illegal/unsupported escape sequence")
            else
                return .{ .lit = cp.c },
        };
        return .{ .set = set };
    }

    fn digit(p: *Parser, max: u8) ?u21 {
        if (p.pos >= p.src.len) return null;
        const b = p.src[p.pos];
        const v: u21 = if (std.ascii.isDigit(b)) b - '0' else if (std.ascii.isHex(b)) (b | 0x20) - 'a' + 10 else return null;
        if (v >= max) return null;
        p.pos += 1;
        return v;
    }

    /// `\0n`, `\0nn`, `\0mnn` (m at most 3).
    fn octal(p: *Parser) Fail!u21 {
        const n = p.digit(8) orelse return p.fail(p.pos, "Illegal octal escape sequence");
        const m = p.digit(8) orelse return n;
        if (n <= 3) if (p.digit(8)) |o| return n * 64 + m * 8 + o;
        return n * 8 + m;
    }

    /// `\xhh` or `\x{h...}`.
    fn hex(p: *Parser) Fail!u21 {
        if (p.digit(16)) |n| {
            const m = p.digit(16) orelse return p.fail(p.pos, "Illegal hexadecimal escape sequence");
            return n * 16 + m;
        }
        if (!p.rawIs(p.pos, '{') or p.pos + 1 >= p.src.len or !std.ascii.isHex(p.src[p.pos + 1]))
            return p.fail(p.pos, "Illegal hexadecimal escape sequence");
        p.pos += 1;
        var v: u32 = 0;
        while (p.digit(16)) |d| {
            v = v * 16 + d;
            if (v > 0x10FFFF) return p.fail(p.before(p.pos), "Hexadecimal codepoint is too big");
        }
        if (!p.rawIs(p.pos, '}')) return p.fail(p.pos, "Unclosed hexadecimal escape sequence");
        p.pos += 1;
        return @intCast(v);
    }

    /// `\uhhhh`; a high surrogate followed by a `\u` low surrogate is one code point.
    fn unicode(p: *Parser) Fail!u21 {
        const n = try p.hex4();
        if (n < 0xD800 or n > 0xDBFF or !std.mem.startsWith(u8, p.src[p.pos..], "\\u")) return n;
        const save = p.pos;
        p.pos += 2;
        const m = try p.hex4();
        if (m >= 0xDC00 and m <= 0xDFFF) return 0x10000 + ((n - 0xD800) << 10) + (m - 0xDC00);
        p.pos = save;
        return n;
    }

    fn hex4(p: *Parser) Fail!u21 {
        var v: u21 = 0;
        for (0..4) |_| v = v * 16 + (p.digit(16) orelse return p.fail(p.pos, "Illegal Unicode escape sequence"));
        return v;
    }

    fn quantifier(p: *Parser, atom: *Node) Fail!*Node {
        const c = p.peek() orelse return atom;
        const at = p.pos;
        var min: u32 = 0;
        var max: u32 = inf;
        switch (c) {
            '?' => max = 1,
            '*' => {},
            '+' => min = 1,
            '{' => {
                if (at + 1 >= p.src.len or !std.ascii.isDigit(p.src[at + 1])) return p.fail(at + 1, "Illegal repetition");
                p.pos += 1;
                min = try p.count();
                max = min;
                if (p.peek() == ',') {
                    p.pos += 1;
                    const d = p.peek();
                    max = if (d) |v| (if (v >= '0' and v <= '9') try p.count() else inf) else inf;
                }
                if (p.peek() != '}') return p.fail(p.pos, "Unclosed counted closure");
                if (max < min) return p.fail(p.pos, "Illegal repetition range");
            },
            else => return atom,
        }
        p.pos += 1;
        var greedy = true;
        if (p.peek() == '?') {
            p.pos += 1;
            greedy = false;
        } else if (p.peek() == '+') return p.fail(p.pos, "possessive quantifiers are not supported");
        if (min > max_repeat or (max != inf and max > max_repeat)) return p.fail(at, "repetition count exceeds 1000");
        return p.node(.{ .repeat = .{
            .body = atom,
            .min = min,
            .max = max,
            .greedy = greedy,
            .ques = c == '?',
            .body_nullable = try nullable(atom),
            .body_deterministic = try deterministic(atom),
        } });
    }

    fn count(p: *Parser) Fail!u32 {
        var v: u64 = 0;
        while (p.peek()) |d| {
            if (d >= 0x80 or !std.ascii.isDigit(@intCast(d))) break;
            v = v * 10 + (d - '0');
            if (v > std.math.maxInt(i32)) return p.fail(p.pos, "Illegal repetition range");
            p.pos += 1;
        }
        return @intCast(v);
    }

    /// A group at `(`; null for a group that only sets flags, whose
    /// flags hold to the end of the enclosing group.
    fn group(p: *Parser) Fail!?*Node {
        try stack.check();
        const at = p.pos;
        p.pos += 1;
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > max_nest) return p.fail(at, "groups nest too deeply");
        const saved = p.flags;
        var index: u32 = 0;
        if (p.peek() == '?') {
            p.pos += 1;
            const c: u21 = if (p.pos < p.src.len) decode(p.src, p.pos).c else 0;
            switch (c) {
                ':' => p.pos += 1,
                '=', '!' => return p.fail(at, lookaround),
                '>' => return p.fail(at, "atomic groups are not supported"),
                '<' => {
                    p.pos += 1;
                    if (p.rawIs(p.pos, '=') or p.rawIs(p.pos, '!')) return p.fail(at, lookaround);
                    index = try p.groupName();
                },
                '$', '@' => return p.fail(p.pos, "Unknown group type"),
                else => {
                    try p.inlineFlags();
                    if (p.peek() == ')') {
                        p.pos += 1;
                        return null;
                    }
                    if (p.peek() != ':') return p.fail(p.pos, "Unknown inline modifier");
                    p.pos += 1;
                },
            }
        } else {
            p.ngroups += 1;
            index = p.ngroups;
        }
        const body = try p.alternation();
        if (p.peek() != ')') return p.fail(p.pos, "Unclosed group");
        p.pos += 1;
        p.flags = saved;
        return try p.node(.{ .group = .{ .index = index, .body = body } });
    }

    fn inlineFlags(p: *Parser) Fail!void {
        var on = true;
        while (p.peek()) |c| {
            switch (c) {
                'i' => p.flags.i = on,
                'd' => p.flags.d = on,
                'm' => p.flags.m = on,
                's' => p.flags.s = on,
                'u' => p.flags.u = on,
                'x' => p.flags.x = on,
                'U' => if (on) return p.fail(p.pos, "the U flag (UNICODE_CHARACTER_CLASS) is not supported") else {
                    p.flags.u = false;
                },
                'c' => if (on) return p.fail(p.pos, "the c flag (CANON_EQ) is not supported"),
                '-' => if (on) {
                    on = false;
                } else return,
                else => return,
            }
            p.pos += 1;
        }
    }

    fn groupName(p: *Parser) Fail!u32 {
        const start = p.pos;
        if (p.pos >= p.src.len or !std.ascii.isAlphabetic(p.src[p.pos]))
            return p.fail(p.pos, "capturing group name does not start with a Latin letter");
        while (p.pos < p.src.len and std.ascii.isAlphanumeric(p.src[p.pos])) p.pos += 1;
        const name = p.src[start..p.pos];
        if (!p.rawIs(p.pos, '>')) return p.fail(p.pos, "named capturing group is missing trailing '>'");
        p.pos += 1;
        if (findName(p.names.items, name) != null) return p.failf(p.before(p.pos), "Named capturing group <{s}> is already defined", .{name});
        p.ngroups += 1;
        var head: [8]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], p.ngroups, .little);
        std.mem.writeInt(u32, head[4..8], @intCast(name.len), .little);
        try p.names.appendSlice(p.arena, &head);
        try p.names.appendSlice(p.arena, name);
        return p.ngroups;
    }

    /// A character class, after its `[` when `bracket`, else an
    /// operand of `&&`. A port of Java's `clazz`: single characters
    /// below 256 gather in `bits`, which joins the result at `&&` and
    /// at `]`, and an empty right operand of `&&` intersects with the
    /// last operand, as in Java (`[-\w&&]` is `\w`).
    fn class(p: *Parser, bracket: bool) Fail![]const Range {
        try stack.check();
        const at = p.pos;
        p.depth += 1;
        defer p.depth -= 1;
        if (p.depth > max_nest) return p.fail(at, "groups nest too deeply");
        var prev: Union = .{};
        var curr: ?[]const Range = null;
        var gathered: Union = .{};
        var has_bits = false;
        var negate = false;
        if (bracket and p.rawIs(p.pos, '^')) {
            p.pos += 1;
            negate = true;
        }
        while (true) {
            const c = p.peek() orelse return p.fail(p.before(p.src.len), "Unclosed character class");
            switch (c) {
                '[' => {
                    p.pos += 1;
                    const inner = try p.class(true);
                    curr = inner;
                    try prev.add(p.arena, inner);
                    continue;
                },
                '&' => if (p.rawIs(p.pos + 1, '&')) {
                    p.pos += 2;
                    var right: Union = .{};
                    while (true) {
                        const d = p.peek() orelse return p.fail(p.before(p.src.len), "Unclosed character class");
                        if (d == ']' or d == '&') break;
                        const operand = if (d == '[') blk: {
                            p.pos += 1;
                            break :blk try p.class(true);
                        } else try p.class(false);
                        try right.add(p.arena, operand);
                    }
                    const low = try gathered.get(p.arena) orelse &.{};
                    if (has_bits) {
                        if (prev.list == null) curr = low;
                        try prev.add(p.arena, low);
                        has_bits = false;
                    }
                    if (try right.get(p.arena)) |r| curr = r;
                    if (try prev.get(p.arena)) |pv| {
                        prev = .{};
                        try prev.add(p.arena, try intersect(p.arena, pv, curr orelse low));
                    } else if (right.list != null) prev = right else return p.fail(p.before(p.pos), "Bad class syntax");
                    continue;
                },
                ']' => if (prev.list != null or has_bits) {
                    if (bracket) p.pos += 1;
                    if (has_bits) try prev.add(p.arena, try gathered.get(p.arena) orelse &.{});
                    const set = try prev.get(p.arena) orelse &.{};
                    return if (negate) try complement(p.arena, set) else set;
                },
                else => {},
            }
            const item = try p.classItem(c);
            if (item.bits) {
                try gathered.add(p.arena, item.set);
                has_bits = true;
            } else {
                curr = item.set;
                try prev.add(p.arena, item.set);
            }
        }
    }

    /// A character, a range or a predefined set inside a class.
    fn classItem(p: *Parser, c: u21) Fail!struct { set: []const Range, bits: bool } {
        var lo: u21 = c;
        if (c == '\\') {
            if (p.rawIs(p.pos + 1, 'p') or p.rawIs(p.pos + 1, 'P')) return .{ .set = try p.family(), .bits = false };
            switch (try p.escape(true, p.rawIs(p.pos + 2, '-'))) {
                .lit => |cp| lo = cp,
                .set => |s| return .{ .set = s, .bits = false },
                .node => return p.fail(p.pos, "Illegal/unsupported escape sequence"),
            }
        } else p.advance();
        if (p.peek() == '-' and !p.rawIs(p.pos + 1, '[') and !p.rawIs(p.pos + 1, ']')) {
            p.pos += 1;
            const d = p.peek() orelse return p.fail(p.pos, "Illegal character range");
            var hi: u21 = d;
            if (d == '\\') {
                switch (try p.escape(true, true)) {
                    .lit => |cp| hi = cp,
                    else => return p.fail(p.before(p.pos), "Illegal character range"),
                }
            } else p.advance();
            if (hi < lo) return p.fail(p.before(p.pos), "Illegal character range");
            return .{ .set = try p.foldRange(lo, hi), .bits = false };
        }
        // Java's BitClass takes these unless (?iu) must fold them past Latin-1.
        const special = p.flags.i and p.flags.u and switch (lo) {
            0xFF, 0xB5, 'I', 'i', 'S', 's', 'K', 'k', 0xC5, 0xE5 => true,
            else => false,
        };
        return .{ .set = try p.foldSingle(lo, false), .bits = lo < 256 and !special };
    }

    /// A single character under the flags in force: Java's `single`,
    /// or, for a character of a run of two or more under `(?iu)`, its
    /// slice rule (every code point with the same `fold`).
    fn foldSingle(p: *Parser, c: u21, slice: bool) Allocator.Error![]const Range {
        return foldChar(p.arena, c, p.foldMode(), slice);
    }

    /// A class range under the flags in force: Java's `CIRange` and `CIRangeU`.
    fn foldRange(p: *Parser, lo: u21, hi: u21) Allocator.Error![]const Range {
        var out: std.ArrayList(Range) = .empty;
        try out.append(p.arena, .{ lo, hi });
        if (p.flags.i and p.flags.u) {
            try preimage(p.arena, &out, &tables.upper, lo, hi);
            try preimage(p.arena, &out, &tables.fold, lo, hi);
        } else if (p.flags.i) {
            for ([_]Range{ .{ 'A', 'Z' }, .{ 'a', 'z' } }) |r| {
                const a = @max(lo, r[0]);
                const b = @min(hi, r[1]);
                if (a <= b) try out.append(p.arena, .{ a ^ 0x20, b ^ 0x20 });
            }
        }
        return normalize(out.items);
    }

    /// `\p{...}`, `\P{...}`, `\pX` at `p.pos` (the backslash).
    fn family(p: *Parser) Fail![]const Range {
        const at = p.pos;
        const negate = p.src[p.pos + 1] == 'P';
        p.pos += 2;
        var name: []const u8 = undefined;
        if (p.peek() == '{') {
            p.pos += 1;
            const close = std.mem.findScalarPos(u8, p.src, p.pos, '}') orelse return p.fail(p.src.len, "Unclosed character family");
            if (close == p.pos) return p.fail(close, "Empty character family");
            name = p.src[p.pos..close];
            p.pos = close + 1;
        } else {
            if (p.pos >= p.src.len) return p.fail(p.pos, "Unknown character property name {}");
            const len = decode(p.src, p.pos).len;
            name = p.src[p.pos..][0..len];
            p.pos += len;
        }
        const set = try p.property(name, at);
        return if (negate) try complement(p.arena, set) else set;
    }

    fn property(p: *Parser, name: []const u8, at: usize) Fail![]const Range {
        if (std.mem.findScalar(u8, name, '=')) |i| {
            const key = name[0..i];
            const value = name[i + 1 ..];
            if (std.ascii.eqlIgnoreCase(key, "gc") or std.ascii.eqlIgnoreCase(key, "general_category")) {
                if (try p.named(value)) |s| return s;
            } else for ([_][]const u8{ "sc", "script", "blk", "block" }) |k| {
                if (std.ascii.eqlIgnoreCase(key, k)) return p.fail(at, unsupported_property);
            }
            return p.failf(p.before(p.pos), "Unknown Unicode property {{name=<{s}>, value=<{s}>}}", .{ try std.ascii.allocLowerString(p.arena, key), value });
        }
        if (std.mem.startsWith(u8, name, "In") or std.mem.startsWith(u8, name, "java")) return p.fail(at, unsupported_property);
        if (std.mem.startsWith(u8, name, "Is")) return (try p.categorySet(name[2..])) orelse return p.fail(at, unsupported_property);
        return (try p.named(name)) orelse return p.failf(p.before(p.pos), "Unknown character property name {{{s}}}", .{name});
    }

    /// A general category, a POSIX class or `all`, by the names Java's
    /// `CharPredicates.forProperty` knows. Under `(?i)` the cased
    /// categories become `LC` and `Lower` and `Upper` become `Alpha`.
    fn named(p: *Parser, name: []const u8) Allocator.Error!?[]const Range {
        if (try p.categorySet(name)) |s| return s;
        if (std.mem.eql(u8, name, "all")) return &sets.all;
        for (sets.posix) |entry| {
            if (!std.mem.eql(u8, entry[0], name)) continue;
            if (p.flags.i and (std.mem.eql(u8, name, "Lower") or std.mem.eql(u8, name, "Upper"))) return &sets.alpha;
            return entry[1];
        }
        return null;
    }

    fn categorySet(p: *Parser, name: []const u8) Allocator.Error!?[]const Range {
        if (std.mem.eql(u8, name, "L1")) return &sets.latin1;
        var mask = categoryMask(name) orelse return null;
        if (p.flags.i and mask & cased == mask) mask = cased;
        for (p.categories.items) |entry| if (entry[0] == mask) return entry[1];
        var out: std.ArrayList(Range) = .empty;
        const t = &tables.categories;
        for (t, 0..) |e, i| {
            if ((mask >> @truncate(e)) & 1 == 0) continue;
            const lo = e >> 5;
            const hi = if (i + 1 < t.len) (t[i + 1] >> 5) - 1 else 0x10FFFF;
            if (out.items.len > 0 and out.items[out.items.len - 1][1] + 1 == lo) {
                out.items[out.items.len - 1][1] = hi;
            } else try out.append(p.arena, .{ lo, hi });
        }
        try p.categories.append(p.arena, .{ mask, out.items });
        return out.items;
    }
};

/// The set one literal character `c` matches under `fold`. `slice`:
/// the character is one of a run of two or more, whose `(?iu)` rule
/// is Java's `SliceU`; otherwise Java's `single`.
fn foldChar(arena: Allocator, c: u21, how: Fold, slice: bool) Allocator.Error![]const Range {
    switch (how) {
        .none => return one(arena, c, c),
        .ascii => {
            if (c >= 0x80 or !std.ascii.isAlphabetic(@intCast(c))) return one(arena, c, c);
            const out = try arena.alloc(Range, 2);
            out[0] = .{ c & ~@as(u21, 0x20), c & ~@as(u21, 0x20) };
            out[1] = .{ c | 0x20, c | 0x20 };
            return out;
        },
        .unicode => {
            const l = fold(c);
            var out: std.ArrayList(Range) = .empty;
            if (slice) {
                if (fold(l) == l) try out.append(arena, .{ l, l });
            } else {
                if (upper(c) == l) return one(arena, c, c);
                try out.append(arena, .{ l, l });
            }
            try preimage(arena, &out, &tables.fold, l, l);
            return normalize(out.items);
        },
    }
}

// =============================================================================
// The compiler
// =============================================================================

const Compiler = struct {
    arena: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    ranges: std.ArrayList(Range) = .empty,
    /// The offset in `ranges` of each distinct set, keyed by its bytes.
    sets: std.array_hash_map.String(u32) = .empty,
    nhidden: u32 = 0,
    nodes: u32 = 0,

    const Fail = error{ TooBig, TooManySlots, TooManyNodes, TooManyRanges, OutOfMemory, StackOverflow };

    fn emit(c: *Compiler, inst: Inst) Fail!u32 {
        if (c.insts.items.len >= max_insts) return error.TooBig;
        try c.insts.append(c.arena, inst);
        return @intCast(c.insts.items.len - 1);
    }

    fn here(c: *const Compiler) u32 {
        return @intCast(c.insts.items.len);
    }

    fn program(c: *Compiler, root: *Node, ngroups: u32, names: []const u8) Fail!Program {
        _ = try c.emit(.{ .op = .save, .a = 0 });
        try c.node(root, false);
        _ = try c.emit(.{ .op = .save, .a = 1 });
        _ = try c.emit(.{ .op = .match });
        // Slots: the match, then the hidden marks, then two per group.
        const h = c.nhidden;
        for (c.insts.items) |*in| switch (in.op) {
            .save => if (in.a >= 2) {
                in.a += h;
            },
            .mark, .if_empty => in.a += 2,
            else => {},
        };
        if (c.insts.items.len * (2 + h + 2 * @as(usize, ngroups)) > max_slot_words) return error.TooManySlots;
        const insts = c.insts.items;
        return .{
            .insts = insts,
            .ranges = c.ranges.items,
            .names = names,
            .ngroups = ngroups,
            .nhidden = h,
            .literal = null,
            .prefix = try prefixOf(c.arena, insts),
            .first_bytes = try firstBytes(c.arena, insts, c.ranges.items),
            .anchored = try anchoredAt(c.arena, insts),
        };
    }

    /// `atomic`: the node ends the body of a repetition Java matches as
    /// one unit, where a trailing `\R` takes `\r\n` whenever it can.
    fn node(c: *Compiler, n: *Node, atomic: bool) Fail!void {
        try stack.check();
        c.nodes += 1;
        if (c.nodes > max_nodes) return error.TooManyNodes;
        switch (n.*) {
            .empty => {},
            .lit => |l| for (l.cps) |cp| {
                const set = try foldChar(c.arena, cp, l.fold, l.cps.len > 1);
                if (set.len == 1 and set[0][0] == set[0][1]) {
                    _ = try c.emit(.{ .op = .char, .a = set[0][0] });
                } else try c.class(set);
            },
            .class => |set| try c.class(set),
            .assert => |a| _ = try c.emit(.{ .op = .assert, .a = @backingInt(a) }),
            .line_end => try c.lineEnd(atomic),
            .group => |g| {
                if (g.index > 0) _ = try c.emit(.{ .op = .save, .a = 2 * g.index });
                try c.node(g.body, atomic);
                if (g.index > 0) _ = try c.emit(.{ .op = .save, .a = 2 * g.index + 1 });
            },
            .concat => |items| for (items, 0..) |item, i| try c.node(item, atomic and i == items.len - 1),
            .alt => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                for (branches[0 .. branches.len - 1]) |b| {
                    const s = try c.emit(.{ .op = .split });
                    c.insts.items[s].a = c.here();
                    try c.node(b, false);
                    try jumps.append(c.arena, try c.emit(.{ .op = .jmp }));
                    c.insts.items[s].b = c.here();
                }
                try c.node(branches[branches.len - 1], false);
                for (jumps.items) |j| c.insts.items[j].a = c.here();
            },
            .repeat => |*r| try c.repeat(r),
        }
    }

    /// A class instruction over `set`, which the range table holds once
    /// however many instructions test it.
    fn class(c: *Compiler, set: []const Range) Fail!void {
        const gop = try c.sets.getOrPut(c.arena, std.mem.sliceAsBytes(set));
        if (!gop.found_existing) {
            if (c.ranges.items.len + set.len > max_ranges) return error.TooManyRanges;
            gop.value_ptr.* = @intCast(c.ranges.items.len);
            try c.ranges.appendSlice(c.arena, set);
        }
        _ = try c.emit(.{ .op = .class, .a = gop.value_ptr.*, .b = @intCast(set.len) });
    }

    /// `\r\n | [\n\x0B\f\r\x85  ]`; atomic, `\r` alone only
    /// where no `\n` follows.
    fn lineEnd(c: *Compiler, atomic: bool) Fail!void {
        const s = try c.emit(.{ .op = .split, .a = c.here() + 1 });
        _ = try c.emit(.{ .op = .char, .a = '\r' });
        _ = try c.emit(.{ .op = .char, .a = '\n' });
        const j = try c.emit(.{ .op = .jmp });
        c.insts.items[s].b = c.here();
        if (atomic) {
            const s2 = try c.emit(.{ .op = .split, .a = c.here() + 1 });
            _ = try c.emit(.{ .op = .char, .a = '\r' });
            _ = try c.emit(.{ .op = .assert, .a = @backingInt(Assert.not_lf) });
            const j2 = try c.emit(.{ .op = .jmp });
            c.insts.items[s2].b = c.here();
            try c.class(&sets.line_end);
            c.insts.items[j2].a = c.here();
        } else try c.class(&sets.vspace);
        c.insts.items[j].a = c.here();
    }

    /// A split whose body side is `target` and whose exit side is the
    /// end of the repetition, patched by `repeat`.
    fn loopSplit(c: *Compiler, target: u32, greedy: bool, exits: *std.ArrayList(u32)) Fail!void {
        const s = try c.emit(if (greedy) .{ .op = .split, .a = target } else .{ .op = .split, .b = target });
        try exits.append(c.arena, s);
    }

    /// Java's loop rules (docs/REGEX.md §3.3). A `?` is a plain branch.
    /// A zero-width deterministic body repeats only its mandatory
    /// copies. A nullable body's every iteration is `mark; X;
    /// if_empty`, which leaves the repetition when the iteration
    /// consumed nothing, and its unbounded loop alternates two copies
    /// of X, so the iteration after a consuming one runs through
    /// instructions its predecessor did not visit at that position.
    fn repeat(c: *Compiler, r: *Repeat) Fail!void {
        const body = r.body;
        const atomic = body.* == .line_end or (body.* == .group and !r.ques and r.body_deterministic);
        var exits: std.ArrayList(u32) = .empty;
        if (r.ques) {
            try c.loopSplit(c.here() + 1, r.greedy, &exits);
            try c.node(body, atomic);
        } else if (r.body_nullable and r.body_deterministic) {
            for (0..r.min) |_| try c.node(body, atomic);
            // Java tries one more greedy iteration, which cannot move the
            // match: it keeps the captures of groups inside the body and
            // drops the repeated group's own.
            if (r.greedy and r.max > r.min) {
                try c.loopSplit(c.here() + 1, true, &exits);
                try c.node(if (body.* == .group) body.group.body else body, atomic);
            }
        } else {
            const hidden: ?u32 = if (!r.body_nullable) null else r.hidden orelse blk: {
                r.hidden = c.nhidden;
                c.nhidden += 1;
                break :blk r.hidden;
            };
            const mandatory = if (r.max == inf and r.min > 0) r.min - 1 else r.min;
            for (0..mandatory) |_| try c.copy(body, atomic, hidden, &exits);
            if (r.max == inf) {
                if (r.min == 0) try c.loopSplit(c.here() + 1, r.greedy, &exits);
                const first = c.here();
                try c.copy(body, atomic, hidden, &exits);
                if (hidden != null) {
                    try c.loopSplit(c.here() + 1, r.greedy, &exits);
                    try c.copy(body, atomic, hidden, &exits);
                }
                try c.loopSplit(first, r.greedy, &exits);
            } else for (r.min..r.max) |_| {
                try c.loopSplit(c.here() + 1, r.greedy, &exits);
                try c.copy(body, atomic, hidden, &exits);
            }
        }
        const end = c.here();
        for (exits.items) |pc| {
            const in = &c.insts.items[pc];
            if (in.op == .if_empty or r.greedy) in.b = end else in.a = end;
        }
    }

    fn copy(c: *Compiler, body: *Node, atomic: bool, hidden: ?u32, exits: *std.ArrayList(u32)) Fail!void {
        const h = hidden orelse return c.node(body, atomic);
        _ = try c.emit(.{ .op = .mark, .a = h });
        try c.node(body, atomic);
        try exits.append(c.arena, try c.emit(.{ .op = .if_empty, .a = h }));
    }
};

/// The bytes every match starts with: the `char` run after `save 0`.
fn prefixOf(arena: Allocator, insts: []const Inst) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (insts[1..]) |in| switch (in.op) {
        .save, .mark, .assert => {},
        .char => {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(in.a), &buf) catch break;
            try out.appendSlice(arena, buf[0..n]);
        },
        else => break,
    };
    return if (out.items.len >= 2) out.items else "";
}

/// The first byte of every UTF-8 sequence that encodes a code point
/// of `[lo, hi]`.
fn addLeads(set: *std.bit_set.Static(256), lo: u32, hi: u32) void {
    const bounds = [_]u32{ 0x7F, 0x7FF, 0xFFFF, 0x10FFFF };
    var a = lo;
    for (bounds, 0..) |top, n| {
        if (a > hi) break;
        if (a > top) continue;
        const b = @min(hi, top);
        const shift: u5 = @intCast(6 * n);
        const mark: u32 = ([_]u32{ 0, 0xC0, 0xE0, 0xF0 })[n];
        set.setRangeValue(.{ .start = mark | (a >> shift), .end = (mark | (b >> shift)) + 1 }, true);
        a = top + 1;
    }
}

fn firstBytes(arena: Allocator, insts: []const Inst, ranges: []const Range) Allocator.Error!?std.bit_set.Static(256) {
    var set: std.bit_set.Static(256) = .empty;
    const seen = try arena.alloc(bool, insts.len);
    @memset(seen, false);
    var todo: std.ArrayList(u32) = .empty;
    try todo.append(arena, 0);
    while (todo.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        const in = insts[pc];
        switch (in.op) {
            .char => addLeads(&set, in.a, in.a),
            .class => for (ranges[in.a..][0..in.b]) |r| addLeads(&set, r[0], r[1]),
            .match => return null,
            .split => try todo.appendSlice(arena, &.{ in.a, in.b }),
            .jmp => try todo.append(arena, in.a),
            .if_empty => try todo.appendSlice(arena, &.{ pc + 1, in.b }),
            .save, .mark, .assert => try todo.append(arena, pc + 1),
        }
    }
    var ascii = true;
    for (0..0x80) |b| ascii = ascii and set.isSet(b);
    return if (ascii) null else set;
}

/// Every path from the start passes `\A` or `^` before it consumes a
/// code point or matches, so a match can start only at offset 0.
fn anchoredAt(arena: Allocator, insts: []const Inst) Allocator.Error!bool {
    const seen = try arena.alloc(bool, insts.len);
    @memset(seen, false);
    var todo: std.ArrayList(u32) = .empty;
    try todo.append(arena, 1);
    while (todo.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        const in = insts[pc];
        switch (in.op) {
            .char, .class, .match => return false,
            .assert => if (in.a != @backingInt(Assert.begin)) try todo.append(arena, pc + 1),
            .split => try todo.appendSlice(arena, &.{ in.a, in.b }),
            .jmp => try todo.append(arena, in.a),
            .if_empty => try todo.appendSlice(arena, &.{ pc + 1, in.b }),
            .save, .mark => try todo.append(arena, pc + 1),
        }
    }
    return true;
}

// =============================================================================
// The Pike VM
// =============================================================================

/// A slot no position has written.
pub const none = std.math.maxInt(usize);

const explore = std.math.maxInt(u32);

const Frame = struct { pc: u32 = 0, slot: u32 = explore, old: usize = 0 };

const List = struct {
    /// `seen[pc] == gen`: the closure at this list's position reached pc.
    seen: []u32,
    gen: u32 = 0,
    /// The resting threads, highest priority first, at a `char`, `class` or `match`.
    pcs: []u32,
    len: usize = 0,
    /// `k` slots per resting thread.
    slots: []usize,

    fn clear(l: *List) void {
        l.len = 0;
        l.gen +%= 1;
        if (l.gen == 0) {
            @memset(l.seen, 0);
            l.gen = 1;
        }
    }
};

/// A run `[lo, hi)` of non-spacing marks whose base character is (or
/// is not) a letter or digit, for `\b`.
pub const Marks = struct { lo: usize = 1, hi: usize = 0, base: bool = false };

/// The scratch space of searches with one program, reused across them.
pub const Vm = struct {
    prog: *const Program,
    /// Slots per thread: the span and the hidden marks, and with
    /// groups two per group.
    k: usize,
    lists: [2]List,
    cap: []usize,
    stack: []Frame,
    /// The slots of the last match.
    best: []usize,
    /// The `\b` cache of the input `marks_of`, kept across its
    /// searches so a find loop walks back over a run of marks once.
    marks: Marks = .{},
    marks_of: []const u8 = &.{},
    /// Closure steps and steps back over marks, counted in tests to
    /// pin the linear bound.
    visits: u64 = 0,

    /// `groups`: record every group, else only the whole match.
    pub fn init(gpa: Allocator, prog: *const Program, groups: bool) Allocator.Error!Vm {
        const k = 2 + prog.nhidden + if (groups) 2 * prog.ngroups else 0;
        const m = prog.insts.len;
        const empty: List = .{ .seen = &.{}, .pcs = &.{}, .slots = &.{} };
        var vm: Vm = .{ .prog = prog, .k = k, .lists = .{ empty, empty }, .cap = &.{}, .stack = &.{}, .best = &.{} };
        errdefer vm.deinit(gpa);
        vm.best = try gpa.alloc(usize, k);
        vm.cap = try gpa.alloc(usize, k);
        vm.stack = try gpa.alloc(Frame, m + 1);
        for (&vm.lists) |*l| {
            l.seen = try gpa.alloc(u32, m);
            @memset(l.seen, 0);
            l.pcs = try gpa.alloc(u32, m);
            l.slots = try gpa.alloc(usize, m * k);
        }
        return vm;
    }

    pub fn deinit(vm: *Vm, gpa: Allocator) void {
        gpa.free(vm.best);
        gpa.free(vm.cap);
        gpa.free(vm.stack);
        for (&vm.lists) |*l| {
            gpa.free(l.seen);
            gpa.free(l.pcs);
            gpa.free(l.slots);
        }
    }

    /// The leftmost-first match in `hay` starting at or after `from`,
    /// with `\G` holding at `last_end`; `whole` asks for a match of all
    /// of `hay[from..]` (Java's `matches`). Assertions see all of `hay`.
    pub fn exec(vm: *Vm, hay: []const u8, from: usize, last_end: usize, whole: bool) bool {
        const prog = vm.prog;
        if (from > hay.len) return false;
        if (prog.literal) |lit| {
            const at = if (whole)
                (if (std.mem.eql(u8, hay[from..], lit)) from else null)
            else
                string.indexOf(hay, lit, from);
            vm.best[0] = at orelse return false;
            vm.best[1] = vm.best[0] + lit.len;
            return true;
        }
        if (vm.marks_of.ptr != hay.ptr or vm.marks_of.len != hay.len) {
            vm.marks = .{};
            vm.marks_of = hay;
        }
        const k = vm.k;
        var clist = &vm.lists[0];
        var nlist = &vm.lists[1];
        clist.clear();
        const anchored = whole or prog.anchored;
        var pos = from;
        var matched = false;
        while (true) {
            if (!matched and (pos == from or !anchored)) {
                if (clist.len == 0 and !anchored) {
                    // Threads that died at `pos` marked the list; at
                    // another position those marks are stale.
                    const next = vm.skip(hay, pos) orelse break;
                    if (next != pos) clist.clear();
                    pos = next;
                }
                @memset(vm.cap, none);
                vm.add(clist, 0, hay, pos, last_end);
            }
            if (clist.len == 0) {
                if (matched or anchored or pos >= hay.len) break;
                pos += decode(hay, pos).len;
                clist.clear();
                continue;
            }
            const at_end = pos >= hay.len;
            const cp: Cp = if (at_end) .{ .c = bad, .len = 1 } else decode(hay, pos);
            nlist.clear();
            for (clist.pcs[0..clist.len], 0..) |pc, i| {
                const t = clist.slots[i * k ..][0..k];
                const in = prog.insts[pc];
                const ok = switch (in.op) {
                    .match => {
                        if (whole and pos != hay.len) continue;
                        @memcpy(vm.best, t);
                        matched = true;
                        break;
                    },
                    .char => cp.c == in.a,
                    .class => inSet(prog.ranges[in.a..][0..in.b], cp.c),
                    else => false,
                };
                if (ok) {
                    @memcpy(vm.cap, t);
                    vm.add(nlist, pc + 1, hay, pos + cp.len, last_end);
                }
            }
            if (at_end) break;
            std.mem.swap(*List, &clist, &nlist);
            pos += cp.len;
        }
        return matched;
    }

    /// The span of group `g` (0: the whole match) of the last match,
    /// or null when the group did not take part or was not recorded.
    pub fn group(vm: *const Vm, g: usize) ?[2]usize {
        const i = if (g == 0) 0 else 2 * g + vm.prog.nhidden;
        if (i + 1 >= vm.k) return null;
        if (vm.best[i] == none or vm.best[i + 1] == none) return null;
        return .{ vm.best[i], vm.best[i + 1] };
    }

    /// The next position at or after `pos` where a match can start.
    fn skip(vm: *Vm, hay: []const u8, pos: usize) ?usize {
        const prog = vm.prog;
        if (prog.prefix.len > 0) return string.indexOf(hay, prog.prefix, pos);
        const set = prog.first_bytes orelse return pos;
        var i = pos;
        while (i < hay.len and !set.isSet(hay[i])) i += 1;
        return if (i < hay.len) i else null;
    }

    /// Add the thread at `pc0` with the slots in `vm.cap` to `l`,
    /// following every epsilon instruction at `pos` in priority order.
    /// A pc the closure already reached at this position is not
    /// entered again: the linear bound.
    fn add(vm: *Vm, l: *List, pc0: u32, hay: []const u8, pos: usize, last_end: usize) void {
        const insts = vm.prog.insts;
        var sp: usize = 1;
        vm.stack[0] = .{ .pc = pc0 };
        while (sp > 0) {
            sp -= 1;
            const f = vm.stack[sp];
            if (f.slot != explore) {
                vm.cap[f.slot] = f.old;
                continue;
            }
            var pc = f.pc;
            while (l.seen[pc] != l.gen) {
                l.seen[pc] = l.gen;
                if (builtin.is_test) vm.visits += 1;
                const in = insts[pc];
                switch (in.op) {
                    .jmp => pc = in.a,
                    .split => {
                        vm.stack[sp] = .{ .pc = in.b };
                        sp += 1;
                        pc = in.a;
                    },
                    .save, .mark => {
                        if (in.a < vm.k) {
                            vm.stack[sp] = .{ .slot = in.a, .old = vm.cap[in.a] };
                            sp += 1;
                            vm.cap[in.a] = pos;
                        }
                        pc += 1;
                    },
                    .if_empty => pc = if (vm.cap[in.a] == pos) in.b else pc + 1,
                    .assert => {
                        if (!vm.holds(@fromBackingInt(@as(u8, @intCast(in.a))), hay, pos, last_end)) break;
                        pc += 1;
                    },
                    .char, .class, .match => {
                        l.pcs[l.len] = pc;
                        @memcpy(l.slots[l.len * vm.k ..][0..vm.k], vm.cap);
                        l.len += 1;
                        break;
                    },
                }
            }
        }
    }

    /// Java's anchor and boundary nodes (docs/REGEX.md §3.4).
    fn holds(vm: *Vm, kind: Assert, hay: []const u8, pos: usize, last_end: usize) bool {
        const n = hay.len;
        return switch (kind) {
            .begin => pos == 0,
            .end => pos == n,
            .last_end => pos == last_end,
            .not_lf => pos == n or hay[pos] != '\n',
            .caret_m => pos < n and (pos == 0 or
                (isTerminator(decode(hay, prevStart(hay, pos)).c) and !(hay[pos - 1] == '\r' and hay[pos] == '\n'))),
            .caret_unix_m => pos < n and (pos == 0 or hay[pos - 1] == '\n'),
            .dollar, .dollar_m => {
                if (pos == n) return true;
                const multi = kind == .dollar_m;
                if (!multi and std.mem.eql(u8, hay[pos..], "\r\n")) return true;
                const cp = decode(hay, pos);
                if (!multi and pos + cp.len != n) return false;
                if (cp.c == '\n') return pos == 0 or hay[pos - 1] != '\r';
                return isTerminator(cp.c);
            },
            .dollar_unix => pos == n or (pos + 1 == n and hay[pos] == '\n'),
            .dollar_unix_m => pos == n or hay[pos] == '\n',
            .word, .not_word => {
                const left = pos > 0 and vm.wordAt(hay, prevStart(hay, pos));
                const right = pos < n and vm.wordAt(hay, pos);
                return (left != right) == (kind == .word);
            },
        };
    }

    /// Java's `\b` word test: an ASCII word character, or a non-spacing
    /// mark whose base character is a letter or digit.
    fn wordAt(vm: *Vm, hay: []const u8, at: usize) bool {
        const cp = decode(hay, at);
        if (cp.c < 0x80) return cp.c == '_' or std.ascii.isAlphanumeric(@intCast(cp.c));
        if (category(cp.c) != mn) return false;
        // Walking back to the base would make a run of marks quadratic;
        // the run already walked answers for every mark in it.
        const m = &vm.marks;
        if (m.lo <= at and at <= m.hi) {
            m.hi = @max(m.hi, at + cp.len);
            return m.base;
        }
        var q = at;
        var base = false;
        while (q > 0) {
            if (builtin.is_test) vm.visits += 1;
            const s = prevStart(hay, q);
            if (m.lo <= s and s < m.hi) {
                base = m.base;
                q = m.lo;
                break;
            }
            const c = decode(hay, s).c;
            if (category(c) != mn) {
                base = isLetterOrDigit(c);
                break;
            }
            q = s;
        }
        m.* = .{ .lo = q, .hi = at + cp.len, .base = base };
        return base;
    }
};

/// Java's find loop over one input: each search starts where the last
/// match ended, one code point later after an empty match, and `\G`
/// holds at the last match's end.
pub const Finder = struct {
    vm: *Vm,
    hay: []const u8,
    next: usize = 0,
    last_end: usize = 0,
    done: bool = false,
    /// A literal program's occurrences, found a 32-byte block at a time
    /// across finds rather than from each find's start again, so
    /// `split` and `replace` on `#","` cost what they cost on `","`.
    occurrences: ?string.Matches = null,

    pub fn find(f: *Finder) bool {
        if (f.vm.prog.literal) |lit| if (lit.len > 0) return f.findLiteral(lit);
        if (f.done or f.next > f.hay.len or !f.vm.exec(f.hay, f.next, f.last_end, false)) {
            f.done = true;
            return false;
        }
        const s = f.vm.best[0];
        const e = f.vm.best[1];
        f.last_end = e;
        f.next = if (s != e) e else if (e < f.hay.len) e + decode(f.hay, e).len else e + 1;
        return true;
    }

    /// A non-empty literal never matches empty, so each search starts
    /// where the last occurrence ended, as the iterator does.
    fn findLiteral(f: *Finder, lit: []const u8) bool {
        if (f.done) return false;
        if (f.occurrences == null) f.occurrences = .init(f.hay, lit, @min(f.next, f.hay.len));
        const at = f.occurrences.?.next() orelse {
            f.done = true;
            return false;
        };
        f.vm.best[0] = at;
        f.vm.best[1] = at + lit.len;
        f.last_end = at + lit.len;
        f.next = f.last_end;
        return true;
    }
};

// =============================================================================
// Patterns and matchers as values (docs/REGEX.md §8)
// =============================================================================

/// The body of a `regex` block: the program, whose slices point into
/// the same block after it (a block never moves, docs/GC.md §1), and
/// the source text. A leaf: it holds no Value.
const PatternBody = struct {
    prog: Program,
    source: []const u8,
};

pub const Made = union(enum) { ok: Value, err: SyntaxError };

/// Compile `source` in a scratch arena on `gpa` and copy the program
/// and the source into one `regex` block. A syntax error is `.err`,
/// its message allocated on `gpa` and owned by the caller: the
/// sentence may be formatted in the arena, which dies here.
pub fn make(heap: *Heap, gpa: Allocator, source: []const u8) (Allocator.Error || stack.Error)!Made {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = switch (try compile(arena.allocator(), source, .{})) {
        .ok => |p| p,
        .err => |e| return .{ .err = .{ .msg = try gpa.dupe(u8, e.msg), .offset = e.offset } },
    };
    const literal = p.literal orelse &.{};
    const size = @sizeOf(PatternBody) + p.insts.len * @sizeOf(Inst) + p.ranges.len * @sizeOf(Range) +
        source.len + p.names.len + literal.len + p.prefix.len;
    const h = heap.alloc(.regex, size) catch return error.OutOfMemory;
    const body = Heap.bodyOf(PatternBody, h);
    var tail: [*]u8 = @as([*]u8, @ptrCast(body)) + @sizeOf(PatternBody);
    body.* = .{ .prog = p, .source = &.{} };
    body.prog.insts = copyInto(Inst, &tail, p.insts);
    body.prog.ranges = copyInto(Range, &tail, p.ranges);
    body.source = copyInto(u8, &tail, source);
    body.prog.names = copyInto(u8, &tail, p.names);
    if (p.literal != null) body.prog.literal = copyInto(u8, &tail, literal);
    body.prog.prefix = copyInto(u8, &tail, p.prefix);
    return .{ .ok = Heap.valueFromHeader(.regex, h) };
}

/// `items` copied to `tail`, which moves past them. Instructions and
/// ranges come first, so `tail` is aligned for them.
fn copyInto(comptime T: type, tail: *[*]u8, items: []const T) []const T {
    const dst: [*]T = @ptrCast(@alignCast(tail.*));
    @memcpy(dst[0..items.len], items);
    tail.* += items.len * @sizeOf(T);
    return dst[0..items.len];
}

/// The program of the pattern `v`.
pub fn programOf(v: Value) *const Program {
    std.debug.assert(v.kind() == .regex);
    return &Heap.bodyOf(PatternBody, Heap.asHeapHeader(v)).prog;
}

/// The source text of the pattern `v`, as written.
pub fn sourceOf(v: Value) []const u8 {
    std.debug.assert(v.kind() == .regex);
    return Heap.bodyOf(PatternBody, Heap.asHeapHeader(v)).source;
}

/// The body of a `matcher` block, followed by `2 * (ngroups + 1)`
/// slots: the spans of the last match's groups, `none` for a group
/// that did not take part. `pattern` and `input` never change, so
/// `re-find` updates the block in place.
pub const MatcherBox = extern struct {
    pattern: Value,
    /// A string, validated as UTF-8 when the matcher is made.
    input: Value,
    /// Where the next search starts.
    next: u64,
    /// The end of the last match, where `\G` holds.
    last_end: u64,
    /// The `\b` cache of the input (`Marks`), carried from one
    /// `re-find` to the next.
    marks_lo: u64 = 1,
    marks_hi: u64 = 0,
    state: State,
    marks_base: bool = false,
    _pad: [6]u8 = @splat(0),

    pub const State = enum(u8) { fresh, matched, failed };
};

/// A fresh matcher of `pattern` over the string `input`.
pub fn makeMatcher(heap: *Heap, pattern: Value, input: Value) Allocator.Error!Value {
    const nslots = 2 * (programOf(pattern).ngroups + 1);
    const h = heap.alloc(.matcher, @sizeOf(MatcherBox) + nslots * @sizeOf(u64)) catch return error.OutOfMemory;
    Heap.bodyOf(MatcherBox, h).* = .{ .pattern = pattern, .input = input, .next = 0, .last_end = 0, .state = .fresh };
    return Heap.valueFromHeader(.matcher, h);
}

pub fn matcherBox(v: Value) *MatcherBox {
    std.debug.assert(v.kind() == .matcher);
    return Heap.bodyOf(MatcherBox, Heap.asHeapHeader(v));
}

/// The span slots of the matcher `v`'s last match.
fn matcherSlots(v: Value) []u64 {
    const b = matcherBox(v);
    const n = 2 * (programOf(b.pattern).ngroups + 1);
    const slots: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(b)) + @sizeOf(MatcherBox)));
    return slots[0..n];
}

/// Java's `Matcher.find` on the matcher `v`: the next match, recorded
/// in the matcher, or false. A matcher whose search failed fails every
/// later search, as Java's does.
pub fn matcherFind(gpa: Allocator, v: Value) Allocator.Error!bool {
    const b = matcherBox(v);
    if (b.state == .failed) return false;
    var vm: Vm = try .init(gpa, programOf(b.pattern), true);
    defer vm.deinit(gpa);
    const hay = string.asBytes(b.input);
    vm.marks = .{ .lo = b.marks_lo, .hi = b.marks_hi, .base = b.marks_base };
    vm.marks_of = hay;
    var f: Finder = .{ .vm = &vm, .hay = hay, .next = b.next, .last_end = b.last_end };
    const found = f.find();
    b.marks_lo = vm.marks.lo;
    b.marks_hi = vm.marks.hi;
    b.marks_base = vm.marks.base;
    if (!found) {
        b.state = .failed;
        return false;
    }
    b.next = f.next;
    b.last_end = f.last_end;
    b.state = .matched;
    const slots = matcherSlots(v);
    for (0..slots.len / 2) |g| {
        const span = vm.group(g) orelse .{ none, none };
        slots[2 * g] = span[0];
        slots[2 * g + 1] = span[1];
    }
    return true;
}

/// The span of group `g` of the matcher `v`'s last match, or null when
/// the group did not take part. The matcher has matched.
pub fn matcherGroup(v: Value, g: usize) ?[2]usize {
    std.debug.assert(matcherBox(v).state == .matched);
    const slots = matcherSlots(v);
    if (slots[2 * g] == none) return null;
    return .{ slots[2 * g], slots[2 * g + 1] };
}

/// The collector's walk of a matcher: its pattern and its string.
pub fn traceMatcher(h: *HeapHeader, visitor: anytype) void {
    const b = Heap.bodyOf(MatcherBox, h);
    visitor.markValue(b.pattern);
    visitor.markValue(b.input);
}

// =============================================================================
// Replacement strings (docs/REGEX.md §11)
// =============================================================================

/// A piece of a parsed replacement: literal text, or a group's match.
pub const Piece = union(enum) { text: []const u8, group: u32 };

pub const Parsed = union(enum) { ok: []const Piece, err: []const u8 };

/// `repl` as `Matcher.appendReplacement` reads it against `prog`:
/// `$n` the longest run of digits naming a group (the first digit
/// always counts), `${name}` a named group, `\x` the code point `x`
/// itself, anything else as it is. An error is Java's sentence,
/// allocated in `arena` with the pieces.
pub fn parseReplacement(arena: Allocator, prog: *const Program, repl: []const u8) Allocator.Error!Parsed {
    var pieces: std.ArrayList(Piece) = .empty;
    var i: usize = 0;
    var run: usize = 0;
    while (i < repl.len) {
        const c = repl[i];
        if (c != '\\' and c != '$') {
            i += 1;
            continue;
        }
        if (run < i) try pieces.append(arena, .{ .text = repl[run..i] });
        i += 1;
        if (c == '\\') {
            if (i == repl.len) return .{ .err = "character to be escaped is missing" };
            const n = decode(repl, i).len;
            try pieces.append(arena, .{ .text = repl[i..][0..n] });
            i += n;
        } else {
            if (i == repl.len) return .{ .err = "Illegal group reference: group index is missing" };
            var g: u32 = undefined;
            if (repl[i] == '{') {
                const start = i + 1;
                i = start;
                while (i < repl.len and std.ascii.isAlphanumeric(repl[i])) i += 1;
                const name = repl[start..i];
                if (name.len == 0) return .{ .err = "named capturing group has 0 length name" };
                if (i == repl.len or repl[i] != '}') return .{ .err = "named capturing group is missing trailing '}'" };
                if (std.ascii.isDigit(name[0])) return .{ .err = try arena.print("capturing group name {{{s}}} starts with digit character", .{name}) };
                g = prog.groupIndex(name) orelse return .{ .err = try arena.print("No group with name {{{s}}}", .{name}) };
                i += 1;
            } else {
                if (!std.ascii.isDigit(repl[i])) return .{ .err = "Illegal group reference" };
                g = repl[i] - '0';
                i += 1;
                while (i < repl.len and std.ascii.isDigit(repl[i])) : (i += 1) {
                    const longer = @as(u64, g) * 10 + (repl[i] - '0');
                    if (longer > prog.ngroups) break;
                    g = @intCast(longer);
                }
                if (g > prog.ngroups) return .{ .err = try arena.print("No group {d}", .{g}) };
            }
            try pieces.append(arena, .{ .group = g });
        }
        run = i;
    }
    if (run < repl.len) try pieces.append(arena, .{ .text = repl[run..] });
    return .{ .ok = pieces.items };
}

/// Java's `Matcher.quoteReplacement`: `s` with a backslash before each
/// `\` and `$`, so a replacement reads it literally.
pub fn quoteReplacement(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (s) |c| {
        if (c == '\\' or c == '$') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Clojure's `print-method` for a pattern: `#"`, the source with each
/// backslash and the character after it as they are and a bare `"`
/// escaped (`\E\"\Q` inside `\Q...\E`), then `"`.
pub fn writeLiteral(w: *std.Io.Writer, source: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("#\"");
    var quoted = false;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (c == '\\' and i + 1 < source.len) {
            const e = source[i + 1];
            try w.writeAll(source[i..][0..2]);
            quoted = if (quoted) e != 'E' else e == 'Q';
            i += 1;
        } else if (c == '"') {
            try w.writeAll(if (quoted) "\\E\\\"\\Q" else "\\\"");
        } else try w.writeByte(c);
    }
    try w.writeByte('"');
}

// =============================================================================
// Tests (expected results are java.util.regex's, through bb)
// =============================================================================

const testing = std.testing;

fn writeEdn(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |b| switch (b) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x0C => try w.writeAll("\\f"),
        0x08 => try w.writeAll("\\b"),
        else => try w.writeByte(b),
    };
    try w.writeByte('"');
}

/// Every match of `pattern` in `hay` with its groups, printed as
/// Clojure prints `(re-seq ...)`'s groups, or `ERR` and the sentence.
fn finds(gpa: Allocator, pattern: []const u8, hay: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    switch (try compile(arena.allocator(), pattern, .{})) {
        .err => |e| try w.print("ERR {s}", .{e.msg}),
        .ok => |prog| {
            var vm: Vm = try .init(gpa, &prog, true);
            defer vm.deinit(gpa);
            var f: Finder = .{ .vm = &vm, .hay = hay };
            try w.writeByte('[');
            var first = true;
            while (f.find()) : (first = false) {
                try w.writeAll(if (first) "[" else " [");
                for (0..prog.ngroups + 1) |g| {
                    if (g > 0) try w.writeByte(' ');
                    if (vm.group(g)) |s| try writeEdn(w, hay[s[0]..s[1]]) else try w.writeAll("nil");
                }
                try w.writeByte(']');
            }
            try w.writeByte(']');
        },
    }
    return out.toOwnedSlice();
}

fn expectFinds(cases: []const [3][]const u8) !void {
    var failed = false;
    for (cases) |case| {
        const got = try finds(testing.allocator, case[0], case[1]);
        defer testing.allocator.free(got);
        if (std.mem.eql(u8, case[2], got)) continue;
        std.debug.print("pattern {s}: want {s}, got {s}\n", .{ case[0], case[2], got });
        failed = true;
    }
    if (failed) return error.TestExpectedEqual;
}

test "regex: matches, groups and the find loop agree with Java" {
    try expectFinds(&.{
        .{ "abc", "xabcabc", "[[\"abc\"] [\"abc\"]]" },
        .{ "a.c", "abc a\nc", "[[\"abc\"]]" },
        .{ "(?s)a.c", "a\nc", "[[\"a\\nc\"]]" },
        .{ "a|ab", "ab", "[[\"a\"]]" },
        .{ "(a|ab)(c|bcd)(d*)", "abcd", "[[\"abcd\" \"a\" \"bcd\" \"\"]]" },
        .{ "a*", "baaa", "[[\"\"] [\"aaa\"] [\"\"]]" },
        .{ "a+?", "aaa", "[[\"a\"] [\"a\"] [\"a\"]]" },
        .{ "a{2,3}", "aaaaaaa", "[[\"aaa\"] [\"aaa\"]]" },
        .{ "a{2,}?", "aaaa", "[[\"aa\"] [\"aa\"]]" },
        .{ "a{0}", "a", "[[\"\"] [\"\"]]" },
        .{ "(a*)*", "b", "[[\"\" \"\"] [\"\" \"\"]]" },
        .{ "(a*)+", "b", "[[\"\" \"\"] [\"\" \"\"]]" },
        .{ "(a?)+", "aa", "[[\"aa\" \"\"] [\"\" \"\"]]" },
        .{ "(|a)*", "aa", "[[\"\" \"\"] [\"\" \"\"] [\"\" \"\"]]" },
        .{ "(|a)+", "aa", "[[\"\" \"\"] [\"\" \"\"] [\"\" \"\"]]" },
        .{ "(a|b)*", "ab", "[[\"ab\" \"b\"] [\"\" nil]]" },
        .{ "(\\A)*", "a", "[[\"\" nil] [\"\" nil]]" },
        .{ "(\\A)?", "a", "[[\"\" \"\"] [\"\" nil]]" },
        .{ "()*", "a", "[[\"\" nil] [\"\" nil]]" },
        .{ "(a*)*b", "aab", "[[\"aab\" \"\"]]" },
        .{ "((a)|b)+", "ab", "[[\"ab\" \"b\" \"a\"]]" },
        .{ "(a)|b", "b", "[[\"b\" nil]]" },
        .{ "x*", "éx", "[[\"\"] [\"x\"] [\"\"]]" },
        .{ ".", "😀a", "[[\"😀\"] [\"a\"]]" },
        .{ "", "aé", "[[\"\"] [\"\"] [\"\"]]" },
        .{ "[^a]", "aé😀", "[[\"é\"] [\"😀\"]]" },
        .{ "[é😀]+", "xé😀", "[[\"é😀\"]]" },
        .{ "[\\x{1F600}-\\x{1F64F}]", "😁", "[[\"😁\"]]" },
        .{ "^a", "aa", "[[\"a\"]]" },
        .{ "a$", "aa\n", "[[\"a\"]]" },
        .{ "$", "a\r\n", "[[\"\"] [\"\"]]" },
        .{ "(?m)^", "a\nb\r\nc", "[[\"\"] [\"\"] [\"\"]]" },
        .{ "(?m)$", "a\nb\r\nc", "[[\"\"] [\"\"] [\"\"]]" },
        .{ "(?m)^", "", "[]" },
        .{ "\\Z", "a\n", "[[\"\"] [\"\"]]" },
        .{ "\\z", "a\n", "[[\"\"]]" },
        .{ "\\Aa", "aa", "[[\"a\"]]" },
        .{ "\\G\\w", "ab c", "[[\"a\"] [\"b\"]]" },
        .{ "\\bx\\b", "x xx x", "[[\"x\"] [\"x\"]]" },
        .{ "\\B", "ab c", "[[\"\"]]" },
        .{ "(?d)$", "a\r\n", "[[\"\"] [\"\"]]" },
        .{ "(?d)(?m)^.", "a\rb\nc", "[[\"a\"] [\"c\"]]" },
        .{ "(?d).", "\r", "[[\"\\r\"]]" },
        .{ ".", "\u{85}\u{2028}x", "[[\"x\"]]" },
        .{ "\\R", "\r\n\n\r", "[[\"\\r\\n\"] [\"\\n\"] [\"\\r\"]]" },
        .{ "\\R{2,}", "\r\n", "[]" },
        .{ "\\R\\n", "\r\n", "[[\"\\r\\n\"]]" },
        .{ "(?:\\R)?\\n", "\r\n", "[[\"\\r\\n\"]]" },
        .{ "(\\R){2}", "\r\n\n", "[[\"\\r\\n\\n\" \"\\n\"]]" },
        .{ "\\d+\\s\\w+", "12 ab_c", "[[\"12 ab_c\"]]" },
        .{ "\\D\\S\\W", "a b!", "[[\" b!\"]]" },
        .{ "\\h\\v", " \n", "[[\" \\n\"]]" },
        .{ "[\\w&&[^\\d]]+", "ab12c", "[[\"ab\"] [\"c\"]]" },
        .{ "[a-z&&[^aeiou]]+", "hello", "[[\"h\"] [\"ll\"]]" },
        .{ "[^a-c]", "abcd", "[[\"d\"]]" },
        .{ "[]a]", "]", "[[\"]\"]]" },
        .{ "[a-]", "-", "[[\"-\"]]" },
        .{ "[\\d-z]", "-z", "[[\"-\"] [\"z\"]]" },
        .{ "[-\\w&&]", "-a", "[[\"a\"]]" },
        .{ "[a&&&&b]", "ab", "[]" },
        .{ "[^a[b]]", "abc", "[[\"c\"]]" },
        .{ "[a[^b]]", "bc", "[[\"c\"]]" },
        .{ "\\p{Lower}+", "abC", "[[\"ab\"]]" },
        .{ "\\p{Punct}", "a!", "[[\"!\"]]" },
        .{ "\\P{Alpha}", "a1", "[[\"1\"]]" },
        .{ "\\p{XDigit}+", "0fG", "[[\"0f\"]]" },
        .{ "[\\p{Digit}x]+", "1x2y", "[[\"1x2\"]]" },
        .{ "(?i)abc", "ABC aBc", "[[\"ABC\"] [\"aBc\"]]" },
        .{ "(?i)[a-c]+", "AbCd", "[[\"AbC\"]]" },
        .{ "(?i)[^a]", "Ab", "[[\"b\"]]" },
        .{ "(?i)\\u00e9", "É", "[]" },
        .{ "(?i)k", "K", "[]" },
        .{ "(?:a(?i)b)B", "aBB", "[[\"aBB\"]]" },
        .{ "(a(?i)b)c", "aBc", "[[\"aBc\" \"aB\"]]" },
        .{ "(?i:a)b", "AbAB", "[[\"Ab\"]]" },
        .{ "(?-i:a)", "A", "[]" },
        .{ "(?x) a b # c\n c", "abc", "[[\"abc\"]]" },
        .{ "(?x)[a b]", " b", "[[\"b\"]]" },
        .{ "(?x)a\\ b", "a b", "[[\"a b\"]]" },
        .{ "\\Qa.b\\E.", "a.bc", "[[\"a.bc\"]]" },
        .{ "\\Qab\\E*", "abbb", "[[\"abbb\"]]" },
        .{ "[\\Qa-c\\E]", "b-", "[[\"-\"]]" },
        .{ "\\x31\\Q2\\E", "12", "[[\"12\"]]" },
        .{ "\\Qa", "a", "[[\"a\"]]" },
        .{ "\\t\\n\\x41\\u0042\\0101\\cA\\x{43}", "\t\nABA\x01C", "[[\"\\t\\nABA\x01C\"]]" },
        .{ "\\ud83d\\ude00", "😀", "[[\"😀\"]]" },
        .{ "\\0400", " 0", "[[\" 0\"]]" },
        .{ "a\\.", "a.ab", "[[\"a.\"]]" },
        .{ "\\_", "_", "[[\"_\"]]" },
        .{ "(?<year>\\d{4})-(?<mon>\\d\\d)", "2024-05", "[[\"2024-05\" \"2024\" \"05\"]]" },
        .{ "{1}", "a", "[[\"\"] [\"\"]]" },
        .{ "a{2}{3}", "aaaaaa", "[[\"aa\"] [\"aa\"] [\"aa\"]]" },
        .{ "^*a", "a", "[[\"a\"]]" },
        .{ "\\b*", "a", "[[\"\"] [\"\"]]" },
        .{ "(x+x+)+y", "xxxxxxxxxxxxxxxxxxxx", "[]" },
        .{ "(a|aa)*c", "aaaaaaaaaaaaaaaaaaaaaaaaab", "[]" },
    });
}

test "regex: (?iu) folds by Java's case mappings, and \\p names general categories" {
    try expectFinds(&.{
        .{ "(?iu)É", "é", "[[\"é\"]]" },
        .{ "(?iu)k", "K", "[[\"K\"]]" },
        .{ "(?i)É", "é", "[]" },
        .{ "(?iu)[à-ê]", "Ê", "[[\"Ê\"]]" },
        .{ "(?iu)[^é]", "Éx", "[[\"x\"]]" },
        .{ "(?iu)s", "ſS", "[[\"ſ\"] [\"S\"]]" },
        .{ "(?iu)[s]", "ſ", "[[\"ſ\"]]" },
        .{ "(?iu)[r-t]", "ſ", "[[\"ſ\"]]" },
        .{ "(?iu)ß", "ẞ", "[]" },
        .{ "(?iu)xß", "xẞ", "[[\"xẞ\"]]" },
        .{ "(?iu)ẞ", "ß", "[[\"ß\"]]" },
        .{ "(?iu)[ß]", "ẞ", "[]" },
        .{ "(?iu)[ß-ß]", "ẞ", "[[\"ẞ\"]]" },
        .{ "(?iu)σ", "ςΣ", "[[\"ς\"] [\"Σ\"]]" },
        .{ "(?iu)xς", "xσxΣ", "[[\"xσ\"] [\"xΣ\"]]" },
        .{ "(?iu)ǅ", "ǆǄ", "[[\"ǆ\"] [\"Ǆ\"]]" },
        .{ "(?iu)[Ǆ-ǆ]", "ǅ", "[[\"ǅ\"]]" },
        .{ "(?iu)[\\w]", "ſK", "[[\"K\"]]" },
        .{ "(?iu)\\p{Lower}", "Aé", "[[\"A\"]]" },
        .{ "(?iu)i", "İıI", "[[\"İ\"] [\"ı\"] [\"I\"]]" },
        .{ "(?iu)İ", "iıI", "[[\"i\"] [\"ı\"] [\"I\"]]" },
        .{ "(?iu)[ÿ]", "Ÿ", "[[\"Ÿ\"]]" },
        .{ "(?iu)µ", "Μμ", "[[\"Μ\"] [\"μ\"]]" },
        .{ "\\p{L}+", "aé中1", "[[\"aé中\"]]" },
        .{ "\\p{Lu}", "aÉ", "[[\"É\"]]" },
        .{ "\\pL", "1x", "[[\"x\"]]" },
        .{ "\\pLu", "Lu xu", "[[\"Lu\"] [\"xu\"]]" },
        .{ "\\p{IsL}", "1é", "[[\"é\"]]" },
        .{ "\\p{gc=Lu}", "aB", "[[\"B\"]]" },
        .{ "\\p{general_category=Nd}", "a٣", "[[\"٣\"]]" },
        .{ "\\P{L}", "a1", "[[\"1\"]]" },
        .{ "[\\p{L}&&[^a]]", "ab", "[[\"b\"]]" },
        .{ "(?i)\\p{Lu}", "a", "[[\"a\"]]" },
        .{ "(?i)\\p{IsLt}", "a", "[[\"a\"]]" },
        .{ "\\p{LC}", "ǅʰ", "[[\"ǅ\"]]" },
        .{ "\\p{LD}", "_٣", "[[\"٣\"]]" },
        .{ "\\p{L1}", "Āÿ", "[[\"ÿ\"]]" },
        .{ "\\p{all}", "\n", "[[\"\\n\"]]" },
        .{ "\\p{Cn}", "a\u{378}", "[[\"\u{378}\"]]" },
        .{ "\\p{Zs}", "a\u{3000}", "[[\"\u{3000}\"]]" },
        .{ "\\p{Mn}", "a\u{301}", "[[\"\u{301}\"]]" },
        .{ "\\p{Sc}", "$€", "[[\"$\"] [\"€\"]]" },
        .{ "\\p{Pi}", "«", "[[\"«\"]]" },
        .{ "\\p{IsN}+", "1½Ⅷ", "[[\"1½Ⅷ\"]]" },
        .{ "\\p{gc=Alpha}", "éa", "[[\"a\"]]" },
        .{ "[^\\p{IsZ}\\p{C}]", " \x00a", "[[\"a\"]]" },
        .{ "\\b\u{301}", "a\u{301}", "[]" },
        .{ "\\b", "a\u{301} \u{301}", "[[\"\"] [\"\"]]" },
        .{ "\u{301}\\b", "é\u{301} x\u{301}\u{301}.", "[[\"\u{301}\"] [\"\u{301}\"]]" },
        .{ "\\B", "\u{301}\u{301}", "[[\"\"] [\"\"] [\"\"]]" },
    });
}

test "regex: captures come from the matching path, where Java's can leak from a failed one" {
    try expectFinds(&.{
        // Java: group 1 "a", kept from the failed first branch.
        .{ "(?:(a))+x|ab", "ab", "[[\"ab\" nil]]" },
        // Java: group 2 "a".
        .{ "((a)b)+x|ab", "ab", "[[\"ab\" nil nil]]" },
        // Java: group 2 "ß", from an iteration it backed out of.
        .{ "((.)+){2}", "1ßK", "[[\"1ßK\" \"K\" \"K\"]]" },
    });
}

test "regex: refused constructs and syntax errors are errors with a sentence" {
    const cases = [_][2][]const u8{
        .{ "(?=a)", "lookahead and lookbehind are not supported" },
        .{ "(?<!a)b", "lookahead and lookbehind are not supported" },
        .{ "(a)\\1", "backreferences are not supported" },
        .{ "(?<n>a)\\k<n>", "backreferences are not supported" },
        .{ "a++", "possessive quantifiers are not supported" },
        .{ "a{1,2}+", "possessive quantifiers are not supported" },
        .{ "(?>a)", "atomic groups are not supported" },
        .{ "\\p{IsLatin}", unsupported_property },
        .{ "\\p{InGreek}", unsupported_property },
        .{ "\\p{IsAlphabetic}", unsupported_property },
        .{ "\\p{sc=Latin}", unsupported_property },
        .{ "\\p{javaLowerCase}", unsupported_property },
        .{ "(?U)a", "the U flag (UNICODE_CHARACTER_CLASS) is not supported" },
        .{ "(?c)a", "the c flag (CANON_EQ) is not supported" },
        .{ "\\X", "\\X (grapheme clusters) is not supported" },
        .{ "\\N{LATIN SMALL LETTER A}", "\\N{...} (named characters) is not supported" },
        .{ "\\b{g}", "\\b{g} (grapheme boundaries) is not supported" },
        .{ "a{1001}", "repetition count exceeds 1000" },
        .{ "a{0,1001}", "repetition count exceeds 1000" },
        .{ "a{99999999999}", "Illegal repetition range" },
        .{ "(", "Unclosed group" },
        .{ ")", "Unmatched closing ')'" },
        .{ "a)", "Unmatched closing ')'" },
        .{ "[", "Unclosed character class" },
        .{ "[]", "Unclosed character class" },
        .{ "[^]", "Unclosed character class" },
        .{ "*a", "Dangling meta character '*'" },
        .{ "a|+", "Dangling meta character '+'" },
        .{ "a**", "Dangling meta character '*'" },
        .{ "a{", "Illegal repetition" },
        .{ "{", "Illegal repetition" },
        .{ "a{,2}", "Illegal repetition" },
        .{ "a{1", "Unclosed counted closure" },
        .{ "a{2,1}", "Illegal repetition range" },
        .{ "[z-a]", "Illegal character range" },
        .{ "[a-\\d]", "Illegal character range" },
        .{ "[&&]", "Bad class syntax" },
        .{ "(?i", "Unknown inline modifier" },
        .{ "(?$)", "Unknown group type" },
        .{ "\\", "Unescaped trailing backslash" },
        .{ "\\c", "Illegal control escape sequence" },
        .{ "\\xg", "Illegal hexadecimal escape sequence" },
        .{ "\\x{110000}", "Hexadecimal codepoint is too big" },
        .{ "\\x{41", "Unclosed hexadecimal escape sequence" },
        .{ "\\u12", "Illegal Unicode escape sequence" },
        .{ "\\08", "Illegal octal escape sequence" },
        .{ "\\y", "Illegal/unsupported escape sequence" },
        .{ "\\E", "Illegal/unsupported escape sequence" },
        .{ "[\\b]", "Illegal/unsupported escape sequence" },
        .{ "[\\1]", "Illegal/unsupported escape sequence" },
        .{ "\\p{}", "Empty character family" },
        .{ "\\p{L", "Unclosed character family" },
        .{ "\\pX", "Unknown character property name {X}" },
        .{ "\\p{gc=X}", "Unknown Unicode property {name=<gc>, value=<X>}" },
        .{ "\\p{Foo=L}", "Unknown Unicode property {name=<foo>, value=<L>}" },
        .{ "(?<1x>a)", "capturing group name does not start with a Latin letter" },
        .{ "(?<x_y>a)", "named capturing group is missing trailing '>'" },
        .{ "(?<x>a)(?<x>b)", "Named capturing group <x> is already defined" },
        .{ "a\xff", "the pattern is not valid UTF-8" },
    };
    for (cases) |case| {
        const got = try finds(testing.allocator, case[0], "");
        defer testing.allocator.free(got);
        const want = try testing.allocator.print("ERR {s}", .{case[1]});
        defer testing.allocator.free(want);
        testing.expectEqualStrings(want, got) catch |e| {
            std.debug.print("pattern {s}\n", .{case[0]});
            return e;
        };
    }
}

test "regex: a syntax error's offset is the code point Java's index names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Each index is java.util.regex's, through bb.
    const cases = [_]struct { []const u8, usize }{
        .{ "a)", 0 },        .{ "\u{e9})", 0 },         .{ "(?x) a )", 6 },        .{ "*a", 0 },
        .{ "a**", 2 },       .{ "\u{e9}+?*", 3 },       .{ "(?x) * ", 6 },         .{ "\\c", 1 },
        .{ "\u{e9}\\c", 2 }, .{ "\\y", 1 },             .{ "[\\y]", 2 },           .{ "\\E", 1 },
        .{ "[\\A]", 2 },     .{ "\\x{110000}", 8 },     .{ "(?<a>x)(?<a>y)", 11 }, .{ "[^]", 2 },
        .{ "[a&&", 3 },      .{ "[\u{e9}", 1 },         .{ "[\u{1F600}", 1 },      .{ "[&&]", 2 },
        .{ "[z-a]", 3 },     .{ "[\u{fc}-\u{e9}]", 3 }, .{ "[z-\\x{61}]", 8 },     .{ "[a-\\d]", 4 },
        .{ "\\pQ", 2 },      .{ "\\p{Foo}", 6 },        .{ "[\\p{Foo}]", 7 },      .{ "\\p{gc=Foo}", 9 },
        .{ "\\p{gc=}", 6 },  .{ "(", 1 },               .{ "a{2,1}", 5 },          .{ "\\x{12", 5 },
        .{ "\\u12", 4 },     .{ "(?<1a>x)", 3 },        .{ "\\p{", 3 },            .{ "x{2147483648}", 11 },
    };
    for (cases) |case| {
        const e = (try compile(arena.allocator(), case[0], .{})).err;
        testing.expectEqual(case[1], try std.unicode.utf8CountCodepoints(case[0][0..e.offset])) catch |err| {
            std.debug.print("pattern {s}: {s}\n", .{ case[0], e.msg });
            return err;
        };
    }
    try testing.expectEqualStrings("Unknown Unicode property {name=<foo>, value=<Bar>}", (try compile(arena.allocator(), "\\p{Foo=Bar}", .{})).err.msg);
}

fn nested(a: Allocator, open: []const u8, close: []const u8, n: usize) ![]const u8 {
    const out = try a.alloc(u8, 2 * n);
    @memset(out[0..n], open[0]);
    @memset(out[n..], close[0]);
    return out;
}

test "regex: the limits refuse a pattern one step past them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try compile(a, "a{1000}", .{}) == .ok);
    try testing.expectEqualStrings("the pattern compiles to more than 10000 instructions", (try compile(a, "(?:a{1000}){10}", .{})).err.msg);
    const groups = try a.alloc(u8, 3 * 600);
    for (0..600) |i| @memcpy(groups[3 * i ..][0..3], "(a)");
    try testing.expectEqualStrings("the pattern has too many groups for its size", (try compile(a, groups, .{})).err.msg);
    try testing.expect(try compile(a, try nested(a, "(", ")", max_nest), .{}) == .ok);
    try testing.expectEqualStrings("groups nest too deeply", (try compile(a, try nested(a, "(", ")", max_nest + 1), .{})).err.msg);
    try testing.expectEqualStrings("groups nest too deeply", (try compile(a, try nested(a, "[", "]", 300), .{})).err.msg);
    // A body that compiles to nothing still costs its nodes, every copy.
    try testing.expect(try compile(a, "(?:(?:){1000}){499}", .{}) == .ok);
    for ([_][]const u8{ "(?:(?:){1000}){500}", "(?:(?:(?:){1000}){1000}){1000}", "(?:(?:(?:(?:x{0}){1000}){1000}){1000}){1000}" }) |p|
        try testing.expectEqualStrings("the pattern expands to more than 1000000 nodes", (try compile(a, p, .{})).err.msg);
    // A class's ranges are stored once however often it is written,
    // and the distinct ones are limited.
    const pl = (try compile(a, "\\PL", .{})).ok.ranges.len;
    var many: std.ArrayList(u8) = .empty;
    for (0..1000) |_| try many.appendSlice(a, "\\PL");
    try testing.expectEqual(pl, (try compile(a, many.items, .{})).ok.ranges.len);
    many.clearRetainingCapacity();
    for (0..max_ranges / pl + 2) |i| try many.print(a, "[\\PL\\x{{{X}}}]", .{0x4E00 + 2 * i});
    try testing.expectEqualStrings("the pattern's classes hold more than 65536 ranges", (try compile(a, many.items, .{})).err.msg);
    // A class's items are united once, not copied per item; the sets
    // a pattern builds while it compiles are bounded by its size.
    many.clearRetainingCapacity();
    try many.append(a, '[');
    for (0..50_000) |i| try many.print(a, "\\x{{{X}}}", .{0x10000 + 2 * i});
    try many.append(a, ']');
    try testing.expectEqual(@as(usize, 50_000), (try compile(a, many.items, .{})).ok.ranges.len);
    many.clearRetainingCapacity();
    for (0..5000) |_| try many.appendSlice(a, "[^\\pL]");
    try testing.expectEqualStrings("the pattern needs too much memory to compile", (try compile(a, many.items, .{})).err.msg);
    // A literal of any length skips the VM and its limits.
    const big = try a.alloc(u8, 1 << 20);
    @memset(big, 'q');
    const lit = try compile(a, big, .{});
    try testing.expectEqual(@as(usize, 1 << 20), lit.ok.literal.?.len);
}

test "regex: a search adds each instruction at most once per position" {
    const gpa = testing.allocator;
    const n = 20_000;
    const hay = try gpa.alloc(u8, n);
    defer gpa.free(hay);
    const patterns = [_][]const u8{ "(a*)*b", "(a|a)*b", "(x+x+)+y", "(a|aa)*c", ".*.*.*=.*", "(\\w+\\s?)*$", "((a+)+)+b", "(a{0,30}){0,30}b" };
    for (patterns) |pattern| {
        @memset(hay, if (pattern[1] == 'x') 'x' else 'a');
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const prog = (try compile(arena.allocator(), pattern, .{})).ok;
        var vm: Vm = try .init(gpa, &prog, true);
        defer vm.deinit(gpa);
        _ = vm.exec(hay, 0, 0, false);
        try testing.expect(vm.visits <= prog.insts.len * (n + 1));
    }
}

test "regex: \\b and \\B walk back over a run of marks once in a find loop" {
    const gpa = testing.allocator;
    const n = 4000;
    const hay = try gpa.alloc(u8, 1 + 2 * n);
    defer gpa.free(hay);
    hay[0] = 'a';
    for (0..n) |i| @memcpy(hay[1 + 2 * i ..][0..2], "\u{301}");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_]struct { []const u8, usize }{ .{ "\\B", n }, .{ "\\b", 2 } }) |case| {
        const prog = (try compile(arena.allocator(), case[0], .{})).ok;
        var vm: Vm = try .init(gpa, &prog, false);
        defer vm.deinit(gpa);
        var f: Finder = .{ .vm = &vm, .hay = hay };
        var found: usize = 0;
        while (f.find()) found += 1;
        try testing.expectEqual(case[1], found);
        try testing.expect(vm.visits <= 8 * hay.len);
    }
}

test "regex: a matcher carries the \\b cache from one find to the next" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    const pattern = (try make(&heap, testing.allocator, "\\B")).ok;
    const m = try makeMatcher(&heap, pattern, try string.fromBytes(&heap, "a\u{301}\u{301}\u{301}"));
    for ([_]usize{ 1, 3, 5 }) |at| {
        try testing.expect(try matcherFind(testing.allocator, m));
        try testing.expectEqual(at, matcherGroup(m, 0).?[0]);
        try testing.expectEqual(@as(u64, 1), matcherBox(m).marks_lo);
    }
    try testing.expect(!try matcherFind(testing.allocator, m));
}

test "regex: prefilters and anchors find what the VM alone finds" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("abc", (try compile(a, "abc+", .{})).ok.prefix[0..2] ++ "c");
    try testing.expect((try compile(a, "\\Aab|x", .{})).ok.anchored == false);
    try testing.expect((try compile(a, "^ab", .{})).ok.anchored);
    for ([_][]const u8{ "^a|^b", "(?:^a|(^b))c", "\\b^a|\\A", "(?:^a)+" }) |p| try testing.expect((try compile(a, p, .{})).ok.anchored);
    for ([_][]const u8{ "^a|b", "(?:^a)*b", "(?m)^a", "(?:^a)?b" }) |p| try testing.expect(!(try compile(a, p, .{})).ok.anchored);
    try testing.expect((try compile(a, "[xy]z", .{})).ok.first_bytes != null);
    try testing.expect((try compile(a, "a*", .{})).ok.first_bytes == null);
    try expectFinds(&.{
        .{ "abc+", "xxabxabcc", "[[\"abcc\"]]" },
        .{ "[xy]z", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaxzyz", "[[\"xz\"] [\"yz\"]]" },
        .{ "[é😀]z", "aaaaé😀z", "[[\"😀z\"]]" },
        .{ "^ab", "abab", "[[\"ab\"]]" },
        .{ "^a|^b", "bab", "[[\"b\"]]" },
        .{ "^a|^b", "xab", "[]" },
        .{ "(?:^a|(^b))c", "bcac", "[[\"bc\" \"b\"]]" },
        .{ "(?m)^ab", "ab\nab", "[[\"ab\"] [\"ab\"]]" },
        // Every thread dies at an assertion before the prefilter skips.
        .{ "(?:\\ba)*\\bc", "ab c ab c", "[[\"c\"] [\"c\"]]" },
    });
}

test "regex: re-matches needs the whole input and prefers the first such path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { []const u8, []const u8, ?[]const u8 }{
        .{ "a|ab", "ab", "ab" },
        .{ "a*?", "aaa", "aaa" },
        .{ "abc", "abc", "abc" },
        .{ "abc", "abcd", null },
        .{ "(a)(b)?", "a", "a" },
        .{ "\\d+", "12x", null },
    };
    for (cases) |case| {
        const prog = (try compile(arena.allocator(), case[0], .{})).ok;
        var vm: Vm = try .init(testing.allocator, &prog, true);
        defer vm.deinit(testing.allocator);
        if (case[2]) |want| {
            try testing.expect(vm.exec(case[1], 0, 0, true));
            const s = vm.group(0).?;
            try testing.expectEqualStrings(want, case[1][s[0]..s[1]]);
        } else try testing.expect(!vm.exec(case[1], 0, 0, true));
    }
    const prog = (try compile(arena.allocator(), "(a)(b)?", .{})).ok;
    var vm: Vm = try .init(testing.allocator, &prog, true);
    defer vm.deinit(testing.allocator);
    try testing.expect(vm.exec("a", 0, 0, true));
    try testing.expect(vm.group(2) == null);
    try testing.expectEqual(@as(?u32, 1), prog.groupIndex("x") orelse 1);
}

test "regex: a replacement string reads $n, ${name} and escapes as Java's appendReplacement does" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = (try compile(a, "(a)(?<year>\\d+)", .{})).ok;
    const ok = (try parseReplacement(a, &prog, "<$1>${year}\\$$12é")).ok;
    try testing.expectEqual(@as(usize, 7), ok.len);
    try testing.expectEqualStrings("<", ok[0].text);
    try testing.expectEqual(@as(u32, 1), ok[1].group);
    try testing.expectEqualStrings(">", ok[2].text);
    try testing.expectEqual(@as(u32, 2), ok[3].group);
    try testing.expectEqualStrings("$", ok[4].text);
    try testing.expectEqual(@as(u32, 1), ok[5].group);
    try testing.expectEqualStrings("2é", ok[6].text);
    const errors = [_][2][]const u8{
        .{ "$3", "No group 3" },
        .{ "x$", "Illegal group reference: group index is missing" },
        .{ "$x", "Illegal group reference" },
        .{ "x\\", "character to be escaped is missing" },
        .{ "${y}", "No group with name {y}" },
        .{ "${}", "named capturing group has 0 length name" },
        .{ "${1x}", "capturing group name {1x} starts with digit character" },
        .{ "${ab", "named capturing group is missing trailing '}'" },
    };
    for (errors) |e| try testing.expectEqualStrings(e[1], (try parseReplacement(a, &prog, e[0])).err);
    const quoted = try quoteReplacement(testing.allocator, "a$1\\b");
    defer testing.allocator.free(quoted);
    try testing.expectEqualStrings("a\\$1\\\\b", quoted);
}

test "regex: make's syntax error outlives the arena it compiled in" {
    var heap = Heap.init(testing.allocator);
    defer heap.deinit();
    for ([_][2][]const u8{
        .{ "*a", "Dangling meta character '*'" },
        .{ "\\p{Foo}", "Unknown character property name {Foo}" },
        .{ "(", "Unclosed group" },
    }) |case| {
        const e = (try make(&heap, testing.allocator, case[0])).err;
        defer testing.allocator.free(e.msg);
        try testing.expectEqualStrings(case[1], e.msg);
    }
}

test "regex: a named group is found by name" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const prog = (try compile(arena.allocator(), "(a)(?<year>\\d+)(?<m>x)?", .{})).ok;
    try testing.expectEqual(@as(?u32, 2), prog.groupIndex("year"));
    try testing.expectEqual(@as(?u32, 3), prog.groupIndex("m"));
    try testing.expectEqual(@as(?u32, null), prog.groupIndex("y"));
}
