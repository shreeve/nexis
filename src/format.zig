//! format.zig — Value → text, the one printer: `.display` (print,
//! println, str of a string or char) and `.readable` (pr, prn,
//! pr-str, the REPL, error reports). The contract, every kind's
//! spelling and who uses which mode, is `docs/STDLIB.md` §5; which
//! kinds read back is SEMANTICS.md §6. The codec (`src/codec.zig`) is
//! the serialization layer; this is presentation.
//!
//! Invariants:
//!   §F1. `format(.display, nil)` writes `"nil"`. `str`/`join`/`spit`
//!        each layer their own nil → empty wrapping on top of format;
//!        format itself never special-cases nil.
//!   §F2. Readable strings always quote and escape; a string holding
//!        malformed UTF-8 is `error.Utf8Error` in readable mode
//!        (display writes the bytes unchanged, STRING.md §2).
//!   §F3. Recursion is bounded by the native stack, not by a depth
//!        cap. Persistent collections cannot cycle without an atom in
//!        the way, and atoms print opaquely; a realized lazy seq can be
//!        a cycle (`(repeat x)`), and its walk stops with `...` when it
//!        meets a cell again, so every print ends. A collection nested
//!        past the stack guard prints `#<too deep>` and counts an
//!        overflow, which the VM raises as `:stack-overflow`
//!        (SEMANTICS §2.7).

const std = @import("std");
const value_mod = @import("value.zig");
const intern_mod = @import("intern.zig");
const list_mod = @import("coll/list.zig");
const lazy_mod = @import("coll/lazy.zig");
const vector_mod = @import("coll/vector.zig");
const champ_mod = @import("coll/champ.zig");
const sorted_mod = @import("coll/sorted.zig");
const string_mod = @import("string.zig");
const heap_mod = @import("heap.zig");
const vm_mod = @import("vm.zig");
const atom_mod = @import("atom.zig");
const regex_mod = @import("regex.zig");
const bignum_mod = @import("bignum.zig");
const typed_vector_mod = @import("coll/typed_vector.zig");
const db_mod = @import("db.zig");
const record_mod = @import("record.zig");
const protocol_mod = @import("protocol.zig");
const nextomic_handle = @import("nextomic/handle.zig");
const dispatch = @import("dispatch.zig");
const stack = @import("stack.zig");

const Value = value_mod.Value;
const Kind = value_mod.Kind;

const testing = std.testing;

// =============================================================================
// Public API
// =============================================================================

pub const FormatMode = enum { display, readable };

/// Explicit error set for the recursive formatter. Inferred error
/// sets across `format`/`formatList`/... created a dependency
/// loop (Zig can't infer through recursive calls), so we pin the
/// union here: writer failures + our own UTF-8 validation error.
/// Callers map these to runtime catchable errors at the language
/// boundary (typically `:io-error` for `WriteFailed`, `:utf8-error`
/// for `Utf8Error`).
pub const Error = std.Io.Writer.Error || error{Utf8Error};

/// Format any Value into `writer` according to `mode`. `interner`
/// is required for keyword and symbol names and names record types;
/// if the value tree contains none of those a null interner is safe.
///
/// `writer` is `*std.Io.Writer` (Zig's canonical writer
/// interface). Callers obtain one from `std.Io.Writer.fixed(&buf)`,
/// `std.Io.Writer.Allocating.init(...)`, or any other
/// `Writer.VTable`-backed adapter (stdout, file, etc.).
pub fn format(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    switch (v.kind()) {
        .nil => try writer.writeAll("nil"),
        .true_ => try writer.writeAll("true"),
        .false_ => try writer.writeAll("false"),
        .fixnum => try writer.print("{d}", .{v.asFixnum()}),
        .keyword => {
            // Null interner is a programmer error here, not a
            // user-visible runtime path. Caller guarantees the
            // interner outlives the Value tree being formatted.
            const it = interner.?;
            const id: u32 = v.asKeywordId();
            try writer.print(":{s}", .{it.keywordName(id)});
        },
        .symbol => {
            const it = interner.?;
            const id: u32 = v.asSymbolId();
            try writer.print("{s}", .{it.symbolName(id)});
        },
        .char => try formatChar(v.asChar(), mode, writer),
        .string => try formatString(string_mod.asBytes(v), mode, writer),
        .list, .lazy_seq, .persistent_vector, .persistent_map, .persistent_set, .record, .sorted_map, .sorted_set => {
            stack.check() catch {
                dispatch.noteSpoiled();
                return writer.writeAll("#<too deep>");
            };
            switch (v.kind()) {
                .list => {
                    var it = list_mod.Cursor.init(v);
                    try formatItems(&it, "(", ")", .item, mode, writer, interner);
                },
                .lazy_seq => try formatLazy(v, mode, writer, interner),
                .persistent_vector => {
                    var it = vector_mod.Cursor.init(v);
                    try formatItems(&it, "[", "]", .item, mode, writer, interner);
                },
                .persistent_map => try formatMap(v, mode, writer, interner),
                .persistent_set => {
                    var it = champ_mod.setIter(v);
                    try formatItems(&it, "#{", "}", .item, mode, writer, interner);
                },
                .sorted_map => {
                    var it = sorted_mod.Iter.init(v, true);
                    try formatItems(&it, "{", "}", .entry, mode, writer, interner);
                },
                .sorted_set => {
                    var it = sorted_mod.Iter.init(v, true);
                    try formatItems(&it, "#{", "}", .key, mode, writer, interner);
                },
                else => try formatRecord(v, mode, writer, interner),
            }
        },
        .function => try writer.writeAll("#<fn>"),
        .var_ => {
            const var_obj = vm_mod.VM.asVar(v);
            if (var_obj.ns.len > 0) try writer.print("#'{s}/{s}", .{ var_obj.ns, var_obj.name }) else try writer.print("#'{s}", .{var_obj.name});
        },
        .native_fn => {
            const nf = vm_mod.asNativeFn(v);
            try writer.print("#<native-fn {s}>", .{nf.name});
        },
        // Identity-valued kinds format opaquely in both modes: they
        // have no source form, so readable output does not read
        // back. The codec refuses them as `:unserializable`.
        .atom => try writer.writeAll("#<atom>"),
        // A protocol's name lives in the VM's protocol registry,
        // which the printer is not given, so both print their ids.
        .protocol => try writer.print("#<protocol id={d}>", .{protocol_mod.protocolId(v)}),
        .protocol_fn => try writer.print(
            "#<protocol-fn proto={d} method={d}>",
            .{
                protocol_mod.protocolFnProtocolId(v),
                protocol_mod.protocolFnMethodNameId(v),
            },
        ),
        .durable_ref => try formatDurableRef(v, writer),
        .db_connection => try writer.writeAll("#<db-connection>"),
        // The path as a string literal, escaped, in both modes.
        .nextomic_conn => {
            try writer.writeAll("#nextomic/conn ");
            try formatString(nextomic_handle.connPath(v), .readable, writer);
        },
        .nextomic_db => try nextomic_handle.formatDb(v, writer),
        .nextomic_entity => try nextomic_handle.formatEntity(v, writer),
        .db_write_txn => try writer.writeAll("#<db-write-txn>"),
        .db_read_txn => try writer.writeAll("#<db-read-txn>"),
        .transient => try writer.writeAll("#<transient>"),
        .float => try formatFloat(v.asFloat(), writer),
        .bignum => try bignum_mod.formatDecimal(v, writer),
        // `#i64[1 2 3]` / `#f64[1.0 2.0]` in both modes; the reader
        // has no such dispatch, so the text does not read back.
        .typed_vector => try typed_vector_mod.format(v, writer, formatFloat),
        // `#"source"` in both modes, as Clojure prints a pattern; it
        // reads back as a new pattern, never an `=` one (identity).
        .regex => try regex_mod.writeLiteral(writer, regex_mod.sourceOf(v)),
        .matcher => {
            try writer.writeAll("#<matcher ");
            try regex_mod.writeLiteral(writer, regex_mod.sourceOf(regex_mod.matcherBox(v).pattern));
            try writer.writeByte('>');
        },
        else => try writer.print("#<value kind={d}>", .{@backingInt(v.kind())}),
    }
}

// =============================================================================
// Per-kind helpers
// =============================================================================

/// Floats print the way Clojure prints doubles in either mode
/// (SEMANTICS §6.3): the shortest round-trip decimal with a
/// mandatory fraction (`1.0`, `2.5`, `-0.0`), switching to
/// `1.0E10` / `1.5E-7` exponent form at or above 1e7 and below
/// 1e-3, and the reader's `##NaN`, `##Inf` and `##-Inf`.
fn formatFloat(f: f64, writer: *std.Io.Writer) Error!void {
    if (std.math.isNan(f)) return writer.writeAll("##NaN");
    if (std.math.isInf(f)) return writer.writeAll(if (f > 0) "##Inf" else "##-Inf");
    return formatFloatJava(f, writer);
}

/// A float as Java's `Double.toString` writes it, the spelling
/// `str` and `%s` give a bare float: `NaN`, `Infinity` and
/// `-Infinity` for the special values.
pub fn formatFloatJava(f: f64, writer: *std.Io.Writer) Error!void {
    if (std.math.isNan(f)) return writer.writeAll("NaN");
    if (std.math.isInf(f)) return writer.writeAll(if (f > 0) "Infinity" else "-Infinity");
    // Both spellings of a finite f64 fit comfortably: the
    // shortest round-trip mantissa is at most 17 digits.
    var buf: [64]u8 = undefined;
    const mag = @abs(f);
    if (mag != 0 and (mag >= 1e7 or mag < 1e-3)) {
        var text = std.mem.print(&buf, "{e}", .{f}) catch unreachable;
        // A one-digit shortest form: Java takes the closest of the
        // one- and two-digit decimals that read back as `f`. Only the
        // least subnormals tell them apart: 4.9E-324, not 5.0E-324.
        const sign_len: usize = @intFromBool(f < 0);
        if (std.mem.findScalar(u8, text, 'e').? == sign_len + 1) {
            var exp = std.fmt.parseInt(i32, text[sign_len + 2 ..], 10) catch unreachable;
            // `mag` over 10^(exp - 1), in f128, whose range and
            // precision hold it closely enough to round to two digits;
            // the one-digit form may have rounded up a power of ten.
            var scale: f128 = 1;
            for (0..@abs(exp - 1)) |_| scale *= 10;
            var scaled = if (exp - 1 < 0) @as(f128, mag) * scale else @as(f128, mag) / scale;
            if (scaled < 10) {
                scaled *= 10;
                exp -= 1;
            }
            var digits: u32 = @intFromFloat(@round(scaled));
            if (digits == 100) {
                digits = 10;
                exp += 1;
            }
            var two_buf: [32]u8 = undefined;
            const two = std.mem.print(&two_buf, "{s}{d}.{d}e{d}", .{ text[0..sign_len], digits / 10, digits % 10, exp }) catch unreachable;
            if ((std.fmt.parseFloat(f64, two) catch f + 1) == f) {
                @memcpy(buf[0..two.len], two);
                text = buf[0..two.len];
            }
        }
        const e_idx = std.mem.findScalar(u8, text, 'e').?;
        const mantissa = text[0..e_idx];
        try writer.writeAll(mantissa);
        if (std.mem.findScalar(u8, mantissa, '.') == null) try writer.writeAll(".0");
        try writer.writeByte('E');
        try writer.writeAll(text[e_idx + 1 ..]);
        return;
    }
    const text = std.mem.print(&buf, "{d}", .{f}) catch unreachable;
    try writer.writeAll(text);
    if (std.mem.findScalar(u8, text, '.') == null) try writer.writeAll(".0");
}

fn formatString(bytes: []const u8, mode: FormatMode, writer: *std.Io.Writer) Error!void {
    if (mode == .display) {
        // Display: raw byte view. Storage is byte-blob (STRING.md §2),
        // so invalid-UTF-8 strings round-trip unchanged. This is the
        // canonical str/print contract.
        try writer.writeAll(bytes);
        return;
    }
    // Readable: validate UTF-8 first (§F2). The reader cannot
    // construct a malformed string Value, but a corrupt codec / fuzzer
    // could; refusing to emit invalid source is the safer policy.
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Utf8Error;
    try writer.writeByte('"');
    // Each run of bytes that need no escape goes out in one write.
    var run: usize = 0;
    for (bytes, 0..) |b, i| {
        const named: ?[]const u8 = switch (b) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\t' => "\\t",
            '\r' => "\\r",
            else => null,
        };
        if (named == null and b >= 0x20 and b != 0x7F) continue;
        try writer.writeAll(bytes[run..i]);
        run = i + 1;
        // The other ASCII controls and DEL as the reader's `\u{HEX}`
        // escape (PLAN §23 #26).
        if (named) |e| try writer.writeAll(e) else try writer.print("\\u{{{X}}}", .{b});
    }
    try writer.writeAll(bytes[run..]);
    try writer.writeByte('"');
}

fn formatChar(scalar: u21, mode: FormatMode, writer: *std.Io.Writer) Error!void {
    if (mode == .display) {
        var utf8_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(scalar, &utf8_buf) catch return error.Utf8Error;
        if (n > 0) try writer.writeAll(utf8_buf[0..n]);
        return;
    }
    // Readable: named tokens for common whitespace + backslash;
    // printable ASCII and every non-ASCII scalar as `\x`, as Clojure
    // prints them; the other ASCII controls and DEL hex-escaped, as in
    // a string. STDLIB.md §5 pins the exact set.
    switch (scalar) {
        ' ' => try writer.writeAll("\\space"),
        '\n' => try writer.writeAll("\\newline"),
        '\t' => try writer.writeAll("\\tab"),
        '\r' => try writer.writeAll("\\return"),
        0x0C => try writer.writeAll("\\formfeed"),
        0x08 => try writer.writeAll("\\backspace"),
        '\\' => try writer.writeAll("\\\\"),
        // Printable ASCII (excluding the whitespace + backslash
        // handled above): bare `\x`.
        0x21...0x5B, 0x5D...0x7E => try writer.print("\\{c}", .{@as(u8, @intCast(scalar))}),
        // NUL, the other ASCII controls and DEL: hex-escape.
        0x00...0x07, 0x0B, 0x0E...0x1F, 0x7F => try writer.print("\\u{{{X}}}", .{scalar}),
        // Past ASCII: the scalar's UTF-8, which the reader takes back
        // after `\` (FORMS.md §2).
        else => {
            var utf8_buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(scalar, &utf8_buf) catch return error.Utf8Error;
            try writer.writeByte('\\');
            try writer.writeAll(utf8_buf[0..n]);
        },
    }
}

/// The items of `it` between `open` and `close`: each value
/// (`.item`), each entry as `k v` with entries separated by `, `
/// (`.entry`), or each entry's key (`.key`, a sorted set's).
fn formatItems(
    it: anytype,
    open: []const u8,
    close: []const u8,
    comptime shape: enum { item, entry, key },
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    try writer.writeAll(open);
    var first = true;
    while (it.next()) |x| : (first = false) {
        if (!first) try writer.writeAll(if (shape == .entry) ", " else " ");
        switch (shape) {
            .item => try format(x, mode, writer, interner),
            .key => try format(x.key, mode, writer, interner),
            .entry => {
                try format(x.key, mode, writer, interner);
                try writer.writeByte(' ');
                try format(x.value, mode, writer, interner);
            },
        }
    }
    try writer.writeAll(close);
}

fn formatMap(v: Value, mode: FormatMode, writer: *std.Io.Writer, interner: ?*const intern_mod.Interner) Error!void {
    var it = champ_mod.mapIter(v);
    try formatItems(&it, "{", "}", .entry, mode, writer, interner);
}

/// A lazy seq prints as a list of its elements. Up to a block whose
/// body has not run, which the printer never runs: there it writes
/// `...` and closes the list. A realized chain may be a cycle (`(repeat
/// x)` is one cell whose rest is its own block, as is a seq whose body
/// returns itself), so the walk also stops with `...` once it comes
/// back to a cell it passed: Brent's cycle finding, which keeps one
/// marked cell and moves it at each power of two, so the print ends
/// within three times the length of the cycle and the cells before it
/// (§F3).
fn formatLazy(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    try writer.writeByte('(');
    var it = lazy_mod.Cursor.init(v);
    var mark = it.rest;
    var power: usize = 1;
    var steps: usize = 0;
    var first = true;
    while (true) : (first = false) {
        const x = it.next() catch {
            if (!first) try writer.writeByte(' ');
            try writer.writeAll("...");
            break;
        } orelse break;
        if (!first) try writer.writeByte(' ');
        try format(x, mode, writer, interner);
        // Between cells: past a chunk's elements, and before a list,
        // which ends.
        if (it.items.len > 0 or it.list_cursor != null or it.rest.kind() != .lazy_seq) continue;
        if (it.rest.identicalTo(mark)) {
            try writer.writeAll(" ...");
            break;
        }
        steps += 1;
        if (steps == power) {
            mark = it.rest;
            power *= 2;
            steps = 0;
        }
    }
    try writer.writeByte(')');
}

/// `#ns.Type{:k v, ...}`, as Clojure prints a record, when the
/// interner names the type (`Interner.nameRecordType`); the opaque
/// `#<record type-id=N>` otherwise.
fn formatRecord(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    const type_id = record_mod.typeId(v);
    const name = if (interner) |it| it.recordTypeName(type_id) else null;
    if (name) |n| {
        try writer.print("#{s}", .{n});
        try formatMap(record_mod.fieldsOf(v), mode, writer, interner);
    } else try writer.print("#<record type-id={d}>", .{type_id});
}

fn formatDurableRef(v: Value, writer: *std.Io.Writer) Error!void {
    // The tree name and the key bytes may hold any byte, so neither
    // is printed raw: a control character, a space, `>` or invalid
    // UTF-8 would break the one-line opaque token. The key is hex;
    // the tree, usually a plain name, keeps its printable ASCII and
    // writes any other byte, and `\`, as `\xHH`.
    try writer.writeAll("#<durable-ref :");
    for (db_mod.refTreeName(v)) |b| switch (b) {
        '!'...'=', '?'...'[', ']'...'~' => try writer.writeByte(b),
        else => try writer.print("\\x{X:0>2}", .{b}),
    };
    try writer.writeAll(" hex:");
    for (db_mod.refKeyBytes(v)) |b| try writer.print("{X:0>2}", .{b});
    try writer.writeByte('>');
}

// =============================================================================
// Inline tests
// =============================================================================

/// `v` printed in `mode`, as an owned slice of `testing.allocator`.
fn formatForTest(v: Value, mode: FormatMode, interner: ?*const intern_mod.Interner) ![]u8 {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer w.deinit();
    try format(v, mode, &w.writer, interner);
    return try w.toOwnedSlice();
}

fn expectFormat(v: Value, mode: FormatMode, interner: ?*const intern_mod.Interner, want: []const u8) !void {
    const got = try formatForTest(v, mode, interner);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

/// A realized block whose seq is `items`, as cons cells or one chunk,
/// followed by the block itself: a cycle, as `(repeat x)` makes one.
fn cycleForTest(heap: *heap_mod.Heap, items: []const Value, chunked: bool) !Value {
    const head = try lazy_mod.unrealized(heap, 0, &.{value_mod.nilValue()});
    var s = head;
    if (chunked) {
        s = try lazy_mod.chunkedOf(heap, items, head);
    } else {
        var i = items.len;
        while (i > 0) {
            i -= 1;
            s = try lazy_mod.cons(heap, items[i], s);
        }
    }
    lazy_mod.setRealized(head, s);
    return head;
}

fn fx(n: i64) Value {
    return value_mod.fromFixnum(n).?;
}

test "a chunked cons prints its offset onward; an unrealized block, or a cell met again, prints as ..." {
    var heap = heap_mod.Heap.init(std.testing.allocator);
    defer heap.deinit();
    const cc = try lazy_mod.chunkedOf(&heap, &.{ fx(1), fx(2), fx(3) }, try list_mod.fromSlice(&heap, &.{fx(4)}));
    const pending = try lazy_mod.unrealized(&heap, 0, &.{value_mod.nilValue()});
    const cases = [_]struct { v: Value, expect: []const u8 }{
        .{ .v = cc, .expect = "(1 2 3 4)" },
        .{ .v = lazy_mod.atOffset(cc, 2), .expect = "(3 4)" },
        .{ .v = try lazy_mod.realizedWithMeta(&heap, value_mod.nilValue(), null), .expect = "()" },
        .{ .v = try lazy_mod.cons(&heap, fx(0), pending), .expect = "(0 ...)" },
        .{ .v = pending, .expect = "(...)" },
        .{ .v = try cycleForTest(&heap, &.{fx(1)}, false), .expect = "(1 ...)" },
        .{ .v = try cycleForTest(&heap, &.{ fx(1), fx(2) }, false), .expect = "(1 2 1 ...)" },
        .{ .v = try cycleForTest(&heap, &.{ fx(1), fx(2), fx(3) }, true), .expect = "(1 2 3 ...)" },
        .{ .v = try lazy_mod.cons(&heap, fx(0), try cycleForTest(&heap, &.{ fx(1), fx(2), fx(3) }, false)), .expect = "(0 1 2 3 1 2 ...)" },
    };
    for (cases) |c| try expectFormat(c.v, .readable, null, c.expect);
}

test "scalars and bignums print the same in both modes" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const cases = [_]struct { v: Value, expect: []const u8 }{
        .{ .v = value_mod.nilValue(), .expect = "nil" },
        .{ .v = value_mod.fromBool(true), .expect = "true" },
        .{ .v = value_mod.fromBool(false), .expect = "false" },
        .{ .v = fx(42), .expect = "42" },
        .{ .v = fx(-7), .expect = "-7" },
        .{ .v = (try bignum_mod.parseDecimal(&heap, "-340282366920938463463374607431768211456")).?, .expect = "-340282366920938463463374607431768211456" },
    };
    for (cases) |c| for ([_]FormatMode{ .display, .readable }) |mode| try expectFormat(c.v, mode, null, c.expect);
}

test "floats: NaN and the infinities print as the reader reads them in either mode; formatFloatJava is Java's spelling" {
    const cases = [_]struct { f: f64, printed: []const u8, java: []const u8 }{
        .{ .f = std.math.inf(f64), .printed = "##Inf", .java = "Infinity" },
        .{ .f = -std.math.inf(f64), .printed = "##-Inf", .java = "-Infinity" },
        .{ .f = std.math.nan(f64), .printed = "##NaN", .java = "NaN" },
        .{ .f = 2.5, .printed = "2.5", .java = "2.5" },
        .{ .f = 5e-324, .printed = "4.9E-324", .java = "4.9E-324" },
        .{ .f = -1e-323, .printed = "-9.9E-324", .java = "-9.9E-324" },
        .{ .f = 1.5e-323, .printed = "1.5E-323", .java = "1.5E-323" },
        .{ .f = 1e-5, .printed = "1.0E-5", .java = "1.0E-5" },
        .{ .f = 1e23, .printed = "1.0E23", .java = "1.0E23" },
        .{ .f = 1.7976931348623157e308, .printed = "1.7976931348623157E308", .java = "1.7976931348623157E308" },
    };
    for (cases) |c| {
        for ([_]FormatMode{ .display, .readable }) |mode| try expectFormat(value_mod.fromFloat(c.f), mode, null, c.printed);
        var buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try formatFloatJava(c.f, &w);
        try testing.expectEqualStrings(c.java, w.buffered());
    }
}

test "strings: display writes the bytes; readable quotes, escapes, hex-escapes the other controls and refuses malformed UTF-8" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var it = intern_mod.Interner.init(testing.allocator);
    defer it.deinit();
    const s = try string_mod.fromBytes(&heap, "a\"b\nc\\d\té");
    try expectFormat(s, .display, null, "a\"b\nc\\d\té");
    try expectFormat(s, .readable, null, "\"a\\\"b\\nc\\\\d\\té\"");
    try expectFormat(try string_mod.fromBytes(&heap, &.{ 0x01, 0x7F, 0x1F, '\r' }), .readable, null, "\"\\u{1}\\u{7F}\\u{1F}\\r\"");
    try expectFormat(try string_mod.fromBytes(&heap, ""), .readable, null, "\"\"");
    try expectFormat(try it.internKeywordValue("hello"), .display, &it, ":hello");
    try expectFormat(try it.internSymbolValue("world"), .readable, &it, "world");
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try testing.expectError(error.Utf8Error, format(try string_mod.fromBytes(&heap, &.{0xC3}), .readable, &w.writer, null));
}

test "chars: display writes the UTF-8; readable a named token, \\x, or a hex escape" {
    const cases = [_]struct { c: u21, display: []const u8, readable: []const u8 }{
        .{ .c = 'a', .display = "a", .readable = "\\a" },
        .{ .c = ' ', .display = " ", .readable = "\\space" },
        .{ .c = '\n', .display = "\n", .readable = "\\newline" },
        .{ .c = 0, .display = "\x00", .readable = "\\u{0}" },
        .{ .c = 0x7F, .display = "\x7F", .readable = "\\u{7F}" },
        .{ .c = 0xE9, .display = "é", .readable = "\\é" },
        .{ .c = 0x1F980, .display = "\u{1F980}", .readable = "\\\u{1F980}" },
    };
    for (cases) |c| {
        try expectFormat(value_mod.fromChar(c.c).?, .display, null, c.display);
        try expectFormat(value_mod.fromChar(c.c).?, .readable, null, c.readable);
    }
}

test "collections: a list, vector, set and map in both modes" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var it = intern_mod.Interner.init(testing.allocator);
    defer it.deinit();
    const elems = [_]Value{ fx(1), try it.internKeywordValue("a"), try string_mod.fromBytes(&heap, "x") };
    const vec = try vector_mod.fromSlice(&heap, &elems);
    try expectFormat(vec, .display, &it, "[1 :a x]");
    try expectFormat(vec, .readable, &it, "[1 :a \"x\"]");
    try expectFormat(try list_mod.fromSlice(&heap, &elems), .readable, &it, "(1 :a \"x\")");
    try expectFormat(try list_mod.fromSlice(&heap, &.{}), .readable, &it, "()");
    var set = try champ_mod.setEmpty(&heap);
    set = try champ_mod.setConj(&heap, set, fx(1), &dispatch.hashValue, &dispatch.equal);
    set = try champ_mod.setConj(&heap, set, fx(2), &dispatch.hashValue, &dispatch.equal);
    try expectFormat(set, .readable, &it, "#{1 2}");
    var map = try champ_mod.mapEmpty(&heap);
    map = try champ_mod.mapAssoc(&heap, map, elems[1], elems[2], &dispatch.hashValue, &dispatch.equal);
    map = try champ_mod.mapAssoc(&heap, map, fx(1), vec, &dispatch.hashValue, &dispatch.equal);
    try expectFormat(map, .readable, &it, "{:a \"x\", 1 [1 :a \"x\"]}");
    try expectFormat(map, .display, &it, "{:a x, 1 [1 :a x]}");
}

test "records: #ns.Type{...} in both modes once the interner names the type; opaque otherwise" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var it = intern_mod.Interner.init(testing.allocator);
    defer it.deinit();
    var fields = try champ_mod.mapEmpty(&heap);
    fields = try champ_mod.mapAssoc(&heap, fields, try it.internKeywordValue("x"), fx(1), &dispatch.hashValue, &dispatch.equal);
    fields = try champ_mod.mapAssoc(&heap, fields, try it.internKeywordValue("y"), try string_mod.fromBytes(&heap, "a"), &dispatch.hashValue, &dispatch.equal);
    const r = try record_mod.make(&heap, 0, fields);
    try expectFormat(r, .readable, &it, "#<record type-id=0>");
    try it.nameRecordType(0, "user", "P");
    try expectFormat(r, .readable, &it, "#user.P{:x 1, :y \"a\"}");
    try expectFormat(r, .display, &it, "#user.P{:x 1, :y a}");
}

test "a durable ref prints its tree's odd bytes escaped and its key in hex" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    try expectFormat(try db_mod.refFromBytes(&heap, 1, "users", "k1"), .readable, null, "#<durable-ref :users hex:6B31>");
    try expectFormat(try db_mod.refFromBytes(&heap, 1, "a b>\\\n\u{e9}", "\x00>"), .readable, null, "#<durable-ref :a\\x20b\\x3E\\x5C\\x0A\\xC3\\xA9 hex:003E>");
}

test "a pattern prints as #\"...\" with Clojure's escaping in both modes; a matcher as #<matcher ...>" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    const cases = [_]struct { source: []const u8, expect: []const u8 }{
        .{ .source = "a\\d+", .expect = "#\"a\\d+\"" },
        .{ .source = "a\"b", .expect = "#\"a\\\"b\"" },
        .{ .source = "a\\\"b", .expect = "#\"a\\\"b\"" },
        .{ .source = "\\Q\"\\E\"", .expect = "#\"\\Q\\E\\\"\\Q\\E\\\"\"" },
        .{ .source = "é😀", .expect = "#\"é😀\"" },
    };
    for (cases) |c| {
        const v = (try regex_mod.make(&heap, testing.allocator, c.source)).ok;
        for ([_]FormatMode{ .display, .readable }) |mode| try expectFormat(v, mode, null, c.expect);
    }
    const p = (try regex_mod.make(&heap, testing.allocator, "x\"")).ok;
    try expectFormat(try regex_mod.makeMatcher(&heap, p, try string_mod.fromBytes(&heap, "x")), .readable, null, "#<matcher #\"x\\\"\">");
}

test "a collection nested past the stack guard prints #<too deep> and counts an overflow" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var v = value_mod.nilValue();
    for (0..20_000) |_| v = try vector_mod.fromSlice(&heap, &.{v});

    defer stack.arm(stack.main_thread_budget);
    stack.arm(64 * 1024);
    const before = dispatch.spoilCount();
    const got = try formatForTest(v, .readable, null);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.find(u8, got, "[#<too deep>]") != null);
    try testing.expect(std.mem.startsWith(u8, got, "[[[") and std.mem.endsWith(u8, got, "]]]"));
    try testing.expect(dispatch.spoilCount() > before);
}
