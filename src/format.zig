//! format.zig — Value → text presentation (Phase 5.2c, peer-AI turn 81).
//!
//! Two modes:
//!   - `.display`  strings UNQUOTED; chars as their UTF-8 bytes;
//!                 nil → `"nil"`. Used by REPL/CLI output, `print`,
//!                 `println`, and `str`'s element printer.
//!   - `.readable` strings DOUBLE-QUOTED with `\ " \n \t \r` plus
//!                 `\u{HEX}` for other ASCII controls and DEL;
//!                 chars as `\space` / `\newline` / `\tab` / `\return`
//!                 / `\formfeed` / `\backspace` / `\\` / `\x` for
//!                 printable ASCII / `\u{HEX}` for the rest;
//!                 nil → `"nil"`. Used by `prn` and `pr-str`.
//!
//! Replaces three duplicate `formatValue` helpers from before 5.2c:
//!   - `src/cli.zig` formatValue        (REPL + run output)
//!   - `test/integration/eval_pipeline.zig` formatValue
//!   - `src/stdlib.zig` appendStringified (the 5.2a minimal local)
//!
//! Authoritative contract: `docs/STRING.md` §9 (and the readable
//! escape table). Non-readable value kinds (atom, function, var,
//! native_fn, durable_ref, transient, error_, meta_symbol) format
//! OPAQUELY in both modes — the readable mode output for those
//! is intentionally NOT round-trippable through the reader, because
//! they are identity-valued or process-local and have no canonical
//! source form. The codec (`src/codec.zig`) is the serialization
//! layer; format.zig is presentation.
//!
//! Frozen invariants (peer-AI turn 81):
//!   §F1. `format(.display, nil)` writes `"nil"`. `str`/`join`/`spit`
//!        each layer their OWN nil → empty wrapping ON TOP of
//!        format; format itself never special-cases nil.
//!   §F2. Readable strings always quote + escape; passing a string
//!        Value containing malformed UTF-8 surfaces `error.Utf8Error`
//!        in readable mode (display mode preserves raw bytes
//!        unmodified, since storage is byte-blob per STRING.md §2).
//!   §F3. Recursion has no depth cap in v1. Persistent collections
//!        can't self-cycle without an atom in the way, and atoms
//!        format opaquely — so no infinite recursion is possible
//!        under v1's heap-kind set. A depth cap can land if a
//!        future Kind introduces non-opaque cycles (peer-AI turn 81
//!        §D9 #2).

const std = @import("std");
const value_mod = @import("value");
const intern_mod = @import("intern");
const list_mod = @import("list");
const vector_mod = @import("vector");
const champ_mod = @import("champ");
const string_mod = @import("string");
const heap_mod = @import("heap");
const vm_mod = @import("vm");
const atom_mod = @import("atom");
const db_mod = @import("db");

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
/// is required for keyword/symbol/native-fn names + var names; if
/// the value tree contains none of those a null interner is safe.
///
/// `writer` is `*std.Io.Writer` (Zig 0.16's canonical writer
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
            const id: u32 = @intCast(v.payload);
            try writer.print(":{s}", .{it.keywordName(id)});
        },
        .symbol => {
            const it = interner.?;
            const id: u32 = @intCast(v.payload);
            try writer.print("{s}", .{it.symbolName(id)});
        },
        .char => try formatChar(v.asChar(), mode, writer),
        .string => try formatString(v, mode, writer),
        .list => try formatList(v, mode, writer, interner),
        .persistent_vector => try formatVector(v, mode, writer, interner),
        .persistent_map => try formatMap(v, mode, writer, interner),
        .persistent_set => try formatSet(v, mode, writer, interner),
        .function => try writer.writeAll("#<fn>"),
        .var_ => {
            const var_obj = vm_mod.VM.asVar(v);
            try writer.print("#'{s}", .{var_obj.name});
        },
        .native_fn => {
            const nf = vm_mod.asNativeFn(v);
            try writer.print("#<native-fn {s}>", .{nf.name});
        },
        // Identity-valued kinds format opaquely in BOTH modes per
        // turn 81 §D9 — they have no canonical source form, so
        // readable mode's output is intentionally not reader-
        // round-trippable. The codec is the serialization layer;
        // these kinds throw `:unserializable` there.
        .atom => try writer.writeAll("#<atom>"),
        .durable_ref => try formatDurableRef(v, writer, interner),
        .db_connection => try writer.writeAll("#<db-connection>"),
        .db_write_txn => try writer.writeAll("#<db-write-txn>"),
        .db_read_txn => try writer.writeAll("#<db-read-txn>"),
        .transient => try writer.writeAll("#<transient>"),
        .error_ => try writer.writeAll("#<error>"),
        .meta_symbol => try writer.writeAll("#<meta-symbol>"),
        // Phase 1 numerics beyond fixnum: defer until kinds ship.
        .float, .bignum, .byte_vector, .typed_vector => {
            try writer.print("#<value kind={d}>", .{@intFromEnum(v.kind())});
        },
        else => try writer.print("#<value kind={d}>", .{@intFromEnum(v.kind())}),
    }
}

/// Convenience wrapper for callers that want a fresh heap-string
/// Value built from format-output. Builds bytes into a
/// `std.Io.Writer.Allocating` (Zig 0.16's growable-writer
/// adapter) and hands them to `string_mod.fromBytes`. Used by
/// `str` (display) and `pr-str` (readable).
pub fn formatToString(
    allocator: std.mem.Allocator,
    heap: *heap_mod.Heap,
    v: Value,
    mode: FormatMode,
    interner: ?*const intern_mod.Interner,
) !Value {
    var w = std.Io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try format(v, mode, &w.writer, interner);
    return try string_mod.fromBytes(heap, w.written());
}

// =============================================================================
// Per-kind helpers
// =============================================================================

fn formatString(v: Value, mode: FormatMode, writer: *std.Io.Writer) Error!void {
    const bytes = string_mod.asBytes(v);
    if (mode == .display) {
        // Display: raw byte view. Storage is byte-blob (STRING.md §2),
        // so invalid-UTF-8 strings round-trip unchanged. This is the
        // canonical str/print contract.
        try writer.writeAll(bytes);
        return;
    }
    // Readable: validate UTF-8 first (turn 81 §F2). The reader cannot
    // construct a malformed string Value, but a corrupt codec / fuzzer
    // could; refusing to emit invalid source is the safer policy.
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Utf8Error;
    try writer.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        switch (b) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\t' => try writer.writeAll("\\t"),
            '\r' => try writer.writeAll("\\r"),
            // ASCII controls 0x00..0x1F (minus the named four above)
            // + DEL (0x7F): hex-escape so the output is valid nexis
            // source per FORMS.md §28.3's `\u{HEX}` escape syntax.
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => {
                try writer.print("\\u{{{X}}}", .{b});
            },
            else => try writer.writeByte(b),
        }
    }
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
    // printable ASCII as `\x`; everything else hex-escape. Turn 81
    // §D3 pinned the exact set.
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
        // NUL, other ASCII controls, and all non-ASCII: hex-escape.
        else => try writer.print("\\u{{{X}}}", .{scalar}),
    }
}

fn formatList(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    try writer.writeByte('(');
    var node = v;
    var first = true;
    while (node.kind() == .list and !list_mod.isEmpty(node)) {
        if (!first) try writer.writeByte(' ');
        first = false;
        try format(list_mod.head(node), mode, writer, interner);
        node = list_mod.tail(node);
    }
    try writer.writeByte(')');
}

fn formatVector(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    try writer.writeByte('[');
    const n = vector_mod.count(v);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try writer.writeByte(' ');
        try format(vector_mod.nth(v, i), mode, writer, interner);
    }
    try writer.writeByte(']');
}

fn formatMap(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    try writer.writeByte('{');
    var it = champ_mod.mapIter(v);
    var first = true;
    while (it.next()) |entry| {
        if (!first) try writer.writeAll(", ");
        first = false;
        try format(entry.key, mode, writer, interner);
        try writer.writeByte(' ');
        try format(entry.value, mode, writer, interner);
    }
    try writer.writeByte('}');
}

fn formatSet(
    v: Value,
    mode: FormatMode,
    writer: *std.Io.Writer,
    interner: ?*const intern_mod.Interner,
) Error!void {
    try writer.writeAll("#{");
    var it = champ_mod.setIter(v);
    var first = true;
    while (it.next()) |elem| {
        if (!first) try writer.writeByte(' ');
        first = false;
        try format(elem, mode, writer, interner);
    }
    try writer.writeByte('}');
}

fn formatDurableRef(
    v: Value,
    writer: *std.Io.Writer,
    _: ?*const intern_mod.Interner,
) Error!void {
    // Identity-triple shape: store_id is u128 (large but stable);
    // tree_name + key_bytes are typically short strings. Peer-AI
    // turn 82 §R5: KEY BYTES are arbitrary (any byte 0x00..0xFF
    // is legal), so printing them raw can sneak control chars,
    // `>`, newlines, or invalid UTF-8 into the output and break
    // the opaque-token envelope. Hex-encode them so the printed
    // form is always one-line, single-byte-per-nybble, and safe
    // in any terminal.
    const tree = db_mod.refTreeName(v);
    const key = db_mod.refKeyBytes(v);
    try writer.print("#<durable-ref :{s} hex:", .{tree});
    for (key) |b| try writer.print("{X:0>2}", .{b});
    try writer.writeByte('>');
}

// =============================================================================
// Inline tests
// =============================================================================

/// Test-only convenience: drive `format` into a fresh
/// `Writer.Allocating` and return the bytes for direct comparison.
/// Caller owns the slice (free via `testing.allocator`).
fn formatForTest(v: Value, mode: FormatMode, interner: ?*const intern_mod.Interner) ![]u8 {
    var w = std.Io.Writer.Allocating.init(testing.allocator);
    errdefer w.deinit();
    try format(v, mode, &w.writer, interner);
    return try w.toOwnedSlice();
}

test "display: scalar Values" {
    const cases = [_]struct { v: Value, expect: []const u8 }{
        .{ .v = value_mod.nilValue(), .expect = "nil" },
        .{ .v = value_mod.fromBool(true), .expect = "true" },
        .{ .v = value_mod.fromBool(false), .expect = "false" },
        .{ .v = value_mod.fromFixnum(42).?, .expect = "42" },
        .{ .v = value_mod.fromFixnum(-7).?, .expect = "-7" },
    };
    for (cases) |c| {
        const got = try formatForTest(c.v, .display, null);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.expect, got);
    }
}

test "display: keyword + symbol via interner" {
    var it = intern_mod.Interner.init(testing.allocator);
    defer it.deinit();
    const kw = try it.internKeywordValue("hello");
    const sym = try it.internSymbolValue("world");

    const got_kw = try formatForTest(kw, .display, &it);
    defer testing.allocator.free(got_kw);
    try testing.expectEqualStrings(":hello", got_kw);

    const got_sym = try formatForTest(sym, .display, &it);
    defer testing.allocator.free(got_sym);
    try testing.expectEqualStrings("world", got_sym);
}

test "display: strings unquoted; readable: strings quoted + escaped" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const s = try string_mod.fromBytes(&heap, "a\"b\nc\\d");

    const got_d = try formatForTest(s, .display, null);
    defer testing.allocator.free(got_d);
    try testing.expectEqualStrings("a\"b\nc\\d", got_d);

    const got_r = try formatForTest(s, .readable, null);
    defer testing.allocator.free(got_r);
    try testing.expectEqualStrings("\"a\\\"b\\nc\\\\d\"", got_r);
}

test "readable: control characters hex-escape; DEL hex-escapes" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    // 0x01 (control-A), 0x7F (DEL), and 0x1F (unit separator).
    const s = try string_mod.fromBytes(&heap, &[_]u8{ 0x01, 0x7F, 0x1F });

    const got = try formatForTest(s, .readable, null);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"\\u{1}\\u{7F}\\u{1F}\"", got);
}

test "readable: malformed UTF-8 string surfaces Utf8Error" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    // 0xC3 is a UTF-8 leading byte for a 2-byte sequence; alone
    // it's invalid.
    const s = try string_mod.fromBytes(&heap, &[_]u8{0xC3});

    var w = std.Io.Writer.Allocating.init(testing.allocator);
    defer w.deinit();
    try testing.expectError(error.Utf8Error, format(s, .readable, &w.writer, null));
}

test "display: char as UTF-8 bytes; readable: named token or \\x or hex" {
    const a_d = try formatForTest(value_mod.fromChar('a').?, .display, null);
    defer testing.allocator.free(a_d);
    try testing.expectEqualStrings("a", a_d);

    const a_r = try formatForTest(value_mod.fromChar('a').?, .readable, null);
    defer testing.allocator.free(a_r);
    try testing.expectEqualStrings("\\a", a_r);

    const sp_d = try formatForTest(value_mod.fromChar(' ').?, .display, null);
    defer testing.allocator.free(sp_d);
    try testing.expectEqualStrings(" ", sp_d);

    const sp_r = try formatForTest(value_mod.fromChar(' ').?, .readable, null);
    defer testing.allocator.free(sp_r);
    try testing.expectEqualStrings("\\space", sp_r);

    const nl_r = try formatForTest(value_mod.fromChar('\n').?, .readable, null);
    defer testing.allocator.free(nl_r);
    try testing.expectEqualStrings("\\newline", nl_r);

    const nul_r = try formatForTest(value_mod.fromChar(0).?, .readable, null);
    defer testing.allocator.free(nul_r);
    try testing.expectEqualStrings("\\u{0}", nul_r);

    const e_d = try formatForTest(value_mod.fromChar(0xE9).?, .display, null);
    defer testing.allocator.free(e_d);
    try testing.expectEqualStrings("é", e_d);

    const e_r = try formatForTest(value_mod.fromChar(0xE9).?, .readable, null);
    defer testing.allocator.free(e_r);
    try testing.expectEqualStrings("\\u{E9}", e_r);
}

test "collections: list / vector display + readable round-trip" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();
    var it = intern_mod.Interner.init(testing.allocator);
    defer it.deinit();

    // [1 :a "x"] in both modes.
    const a = value_mod.fromFixnum(1).?;
    const b = try it.internKeywordValue("a");
    const c = try string_mod.fromBytes(&heap, "x");
    const elems = [_]Value{ a, b, c };
    const vec = try vector_mod.fromSlice(&heap, &elems);

    const got_d = try formatForTest(vec, .display, &it);
    defer testing.allocator.free(got_d);
    try testing.expectEqualStrings("[1 :a x]", got_d);

    const got_r = try formatForTest(vec, .readable, &it);
    defer testing.allocator.free(got_r);
    try testing.expectEqualStrings("[1 :a \"x\"]", got_r);
}

test "formatToString: builds a fresh heap-string Value" {
    var heap = heap_mod.Heap.init(testing.allocator);
    defer heap.deinit();

    const v = try formatToString(testing.allocator, &heap, value_mod.fromFixnum(42).?, .display, null);
    try testing.expect(v.kind() == .string);
    try testing.expectEqualStrings("42", string_mod.asBytes(v));
}
