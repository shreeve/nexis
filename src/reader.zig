//! reader.zig — Sexp → Form normalizer.
//!
//! Consumes the raw `Sexp` tree produced by the nexus-generated parser and
//! produces the canonical `Form` tree documented in `docs/FORMS.md`. All
//! normalization rules from PLAN §28.3 / FORMS.md §3 are enforced here;
//! anything that requires namespace resolution or macro context is left for
//! later stages (`src/macroexpand.zig`, `src/resolve.zig`).
//!
//! Phase 0 scope:
//!   - Parse atom text into typed datums (int, real, char, string, kw, sym).
//!   - Detect nil/true/false from symbol text.
//!   - Recognize and reject reader errors per FORMS.md §3:
//!       * `:duplicate-literal-key`
//!       * `:map-odd-count`
//!       * `:duplicate-literal-element`
//!       * `:nested-anon-fn`
//!       * `:unquote-outside-syntax-quote`
//!       * `:unquote-splice-outside-syntax-quote`
//!       * `:invalid-char-literal`
//!       * `:invalid-string-escape`
//!       * `:bad-number-literal`
//!   - Merge stacked metadata (rightmost wins on duplicate keys).
//!   - Lower `(anon-fn body)` → `(#%anon-fn body)` (reserved symbol).
//!   - Drop `(discard x)` forms from their enclosing `forms` list.
//!
//! Scope boundary (PLAN §14.2 / FORMS.md §4): `(syntax-quote x)` is emitted
//! as a structural tag only. Auto-qualification, auto-gensym, and
//! unquote/splice expansion live in the macroexpander, not here.
//!
//! Integers are parsed into `i64`. Values outside the i64 range are rejected
//! with `:bignum-out-of-phase-0-range`; full bignum support lands in Phase 1
//! alongside the runtime Value layer (PLAN §21, Phase 1 gate test #1).

const std = @import("std");
const parser = @import("parser.zig");
const nexis = @import("nexis.zig");

pub const Tag = nexis.Tag;
pub const Sexp = parser.Sexp;

// -----------------------------------------------------------------------------
// Form, Datum, Span, Error
// -----------------------------------------------------------------------------

pub const SrcSpan = struct {
    pos: u32,
    len: u32,
};

pub const Name = struct {
    /// namespace (null = unqualified); text portion is borrowed from source.
    ns: ?[]const u8,
    /// local name (never empty); borrowed from source.
    name: []const u8,
};

/// Reserved symbol literal used by the pretty-printer to render the head
/// of an anon-fn compound. **Internal — not part of the stored AST.** The
/// `Datum.anon_fn` variant stores body forms only; the `#%anon-fn` head is
/// a rendering convention that makes golden output readable and matches
/// the macroexpander's lowering target (PLAN §28.2 / FORMS.md §2). User
/// code cannot construct this symbol at the reader level because the
/// lexer rejects `#%` as a standalone sequence.
pub const anon_fn_symbol_name: []const u8 = "#%anon-fn";

pub const Datum = union(enum) {
    nil: void,
    bool_: bool,
    int: i64,
    real: f64,
    char: u21,
    /// Decoded UTF-8 bytes (escapes processed). Owned by the reader arena.
    string: []const u8,
    keyword: Name,
    symbol: Name,
    list: []const *Form,
    vector: []const *Form,
    map: []const *Form, // flat k,v,k,v,...
    set: []const *Form,
    /// `(with-meta TARGET META-MAP)` compound. Rendered by the pretty-
    /// printer as a 2-child compound.
    with_meta: WithMeta,
    /// `(#%anon-fn body...)` — body forms only. The reserved
    /// `#%anon-fn` head is synthesized by the pretty-printer; the tag
    /// itself identifies the construct, so embedding a redundant head
    /// symbol in the AST would encode identity twice.
    anon_fn: []const *Form,
    quote: *Form,
    syntax_quote: *Form,
    unquote: *Form,
    unquote_splicing: *Form,
    deref: *Form,
};

pub const WithMeta = struct {
    target: *Form,
    meta: *Form, // always a `(map ...)` Form after normalization
};

pub const Form = struct {
    datum: Datum,
    origin: SrcSpan,
};

pub const ReaderError = error{
    ReaderFailure,
    OutOfMemory,
    InvalidUtf8,
};

pub const ErrorKind = enum {
    duplicate_literal_key,
    duplicate_literal_element,
    map_odd_count,
    nested_anon_fn,
    unquote_outside_syntax_quote,
    unquote_splice_outside_syntax_quote,
    invalid_char_literal,
    invalid_string_escape,
    bad_number_literal,
    bignum_out_of_phase_0_range,
    invalid_symbol,
    invalid_keyword,
    unknown_reader_construct,
};

pub const Error = struct {
    kind: ErrorKind,
    span: SrcSpan,
    /// Optional diagnostic detail — e.g. for `duplicate_literal_key` the
    /// offending key's pretty-printed form. Borrowed from the arena.
    detail: ?[]const u8 = null,
};

/// Reader owns an arena allocator and an error sink. Callers construct a
/// `Reader`, feed it a `Sexp` tree, and receive a `Form` tree on success or
/// an `Error` on the first failure (the reader fails fast — no partial
/// Forms emitted on error).
pub const Reader = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    err: ?Error = null,
    /// Depth counter for syntax-quote scope (>0 inside `` `...` ``).
    syntax_quote_depth: u32 = 0,
    /// Depth counter for anon-fn scope (detects nested `#(...)`).
    anon_fn_depth: u32 = 0,

    pub fn init(backing: std.mem.Allocator, source: []const u8) Reader {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing),
            .source = source,
        };
    }

    pub fn deinit(self: *Reader) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *Reader) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Normalize a top-level `(program forms...)` sexp into a slice of
    /// Forms.
    pub fn readProgram(self: *Reader, tree: Sexp) ReaderError![]const *Form {
        const items = try self.requireCompound(tree, .program);
        return try self.readFormsList(items);
    }

    /// Normalize a single `form` sexp into one `*Form`.
    pub fn readOneForm(self: *Reader, tree: Sexp) ReaderError!*Form {
        return try self.readForm(tree);
    }

    // -------------------------------------------------------------------------
    // Core dispatch
    // -------------------------------------------------------------------------

    fn readForm(self: *Reader, s: Sexp) ReaderError!*Form {
        const items = switch (s) {
            .list => |it| it,
            else => return self.fail(.unknown_reader_construct, srcSpan(s), null),
        };
        if (items.len == 0 or items[0] != .tag) {
            return self.fail(.unknown_reader_construct, srcSpan(s), null);
        }
        const tag: Tag = items[0].tag;
        const args = items[1..];
        return switch (tag) {
            .int => try self.readInt(args, srcSpan(s)),
            .real => try self.readReal(args, srcSpan(s)),
            .string => try self.readString(args, srcSpan(s)),
            .char => try self.readChar(args, srcSpan(s)),
            .keyword => try self.readKeyword(args, srcSpan(s)),
            .symbol => try self.readSymbol(args, srcSpan(s)),
            .list => try self.readCollection(.list, args, srcSpan(s)),
            .vector => try self.readCollection(.vector, args, srcSpan(s)),
            .map => try self.readMap(args, srcSpan(s)),
            .set => try self.readSet(args, srcSpan(s)),
            .quote => try self.readReaderMacro(.quote, args, srcSpan(s)),
            .@"syntax-quote" => try self.readSyntaxQuote(args, srcSpan(s)),
            .unquote => try self.readUnquote(.unquote, args, srcSpan(s)),
            .@"unquote-splicing" => try self.readUnquote(.@"unquote-splicing", args, srcSpan(s)),
            .deref => try self.readReaderMacro(.deref, args, srcSpan(s)),
            .@"anon-fn" => try self.readAnonFn(args, srcSpan(s)),
            .discard => self.fail(.unknown_reader_construct, srcSpan(s), "discard at single-form context — must appear inside a forms list"),
            .@"with-meta-raw" => try self.readWithMetaRaw(args, srcSpan(s)),
            .program => self.fail(.unknown_reader_construct, srcSpan(s), "nested (program ...) not allowed"),
        };
    }

    /// Read a `forms` list, skipping `(discard X)` entries per Clojure's
    /// sequential reader semantics.
    ///
    /// Stacked `#_` is subtle. Source `#_ #_ x y z` means "discard x, then
    /// discard y, keep z" — two source forms consumed. Our LALR grammar
    /// parses it as `[(discard (discard x)), y, z]`, which bundles `x`
    /// inside the compound. A naive "drop any discard compound" pass drops
    /// just the compound, keeping `y` incorrectly. The fix: a discard
    /// chain of nesting depth N consumed N source forms; exactly one of
    /// those is captured inside the compound (the innermost non-discard
    /// payload), so (N−1) additional siblings must also be dropped from
    /// the current iteration.
    fn readFormsList(self: *Reader, items: []const Sexp) ReaderError![]const *Form {
        var out: std.ArrayList(*Form) = .empty;
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const item = items[i];
            if (self.isCompoundWithTag(item, .discard)) {
                const extra_siblings = discardChainDepth(item) - 1;
                i += extra_siblings;
                continue;
            }
            const f = try self.readForm(item);
            try out.append(self.allocator(), f);
        }
        return try out.toOwnedSlice(self.allocator());
    }

    // -------------------------------------------------------------------------
    // Atom readers
    // -------------------------------------------------------------------------

    fn readInt(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const text = expectSrcText(self, args, span) catch |e| return e;
        const value = parseIntLiteral(text) orelse
            return self.fail(.bad_number_literal, span, text);
        return try self.makeForm(.{ .int = value }, span);
    }

    fn readReal(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const text = try expectSrcText(self, args, span);
        const value = std.fmt.parseFloat(f64, text) catch
            return self.fail(.bad_number_literal, span, text);
        return try self.makeForm(.{ .real = value }, span);
    }

    fn readString(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const raw = try expectSrcText(self, args, span);
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
            return self.fail(.invalid_string_escape, span, raw);
        }
        const body = raw[1 .. raw.len - 1];
        const decoded = try self.decodeStringEscapes(body, span);
        return try self.makeForm(.{ .string = decoded }, span);
    }

    fn readChar(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const raw = try expectSrcText(self, args, span);
        if (raw.len < 2 or raw[0] != '\\') {
            return self.fail(.invalid_char_literal, span, raw);
        }
        const body = raw[1..];
        const scalar = parseCharLiteral(body) orelse
            return self.fail(.invalid_char_literal, span, raw);
        return try self.makeForm(.{ .char = scalar }, span);
    }

    fn readKeyword(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const raw = try expectSrcText(self, args, span);
        if (raw.len < 2 or raw[0] != ':') {
            return self.fail(.invalid_keyword, span, raw);
        }
        const body = raw[1..];
        const name = splitNamespace(body) orelse
            return self.fail(.invalid_keyword, span, raw);
        return try self.makeForm(.{ .keyword = name }, span);
    }

    fn readSymbol(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const raw = try expectSrcText(self, args, span);
        // nil / true / false are lexed as symbols and normalized here
        // (FORMS.md §3 — also PLAN §28.2).
        if (std.mem.eql(u8, raw, "nil")) return try self.makeForm(.nil, span);
        if (std.mem.eql(u8, raw, "true")) return try self.makeForm(.{ .bool_ = true }, span);
        if (std.mem.eql(u8, raw, "false")) return try self.makeForm(.{ .bool_ = false }, span);
        const name = splitNamespace(raw) orelse
            return self.fail(.invalid_symbol, span, raw);
        return try self.makeForm(.{ .symbol = name }, span);
    }

    // -------------------------------------------------------------------------
    // Compound readers
    // -------------------------------------------------------------------------

    fn readCollection(self: *Reader, comptime kind: @TypeOf(.list), args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const children = try self.readFormsList(args);
        const datum: Datum = switch (kind) {
            .list => .{ .list = children },
            .vector => .{ .vector = children },
            else => unreachable,
        };
        return try self.makeForm(datum, span);
    }

    fn readMap(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const children = try self.readFormsList(args);
        if (children.len % 2 != 0) {
            return self.fail(.map_odd_count, span, null);
        }
        // Duplicate-literal-key check: look at every even-index key form; if
        // it's a compile-time literal, ensure no earlier key equals it
        // under the reader's literal-equality rules.
        var i: usize = 0;
        while (i < children.len) : (i += 2) {
            const k = children[i];
            if (!isLiteralKey(k)) continue;
            var j: usize = 0;
            while (j < i) : (j += 2) {
                const prior = children[j];
                if (!isLiteralKey(prior)) continue;
                if (formLiteralEq(prior, k)) {
                    const detail = try self.formatLiteralKey(k);
                    return self.fail(.duplicate_literal_key, span, detail);
                }
            }
        }
        return try self.makeForm(.{ .map = children }, span);
    }

    fn readSet(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const children = try self.readFormsList(args);
        // Duplicate-literal-element check (same rules as map keys).
        for (children, 0..) |c, i| {
            if (!isLiteralKey(c)) continue;
            for (children[0..i]) |p| {
                if (!isLiteralKey(p)) continue;
                if (formLiteralEq(p, c)) {
                    const detail = try self.formatLiteralKey(c);
                    return self.fail(.duplicate_literal_element, span, detail);
                }
            }
        }
        return try self.makeForm(.{ .set = children }, span);
    }

    // -------------------------------------------------------------------------
    // Reader macros
    // -------------------------------------------------------------------------

    fn readReaderMacro(self: *Reader, comptime kind: @TypeOf(.quote), args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        if (args.len != 1) {
            return self.fail(.unknown_reader_construct, span, "reader-macro arity");
        }
        const inner = try self.readForm(args[0]);
        const datum: Datum = switch (kind) {
            .quote => .{ .quote = inner },
            .deref => .{ .deref = inner },
            else => unreachable,
        };
        return try self.makeForm(datum, span);
    }

    fn readSyntaxQuote(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        if (args.len != 1) {
            return self.fail(.unknown_reader_construct, span, "syntax-quote arity");
        }
        self.syntax_quote_depth += 1;
        defer self.syntax_quote_depth -= 1;
        const inner = try self.readForm(args[0]);
        return try self.makeForm(.{ .syntax_quote = inner }, span);
    }

    fn readUnquote(self: *Reader, comptime kind: @TypeOf(.unquote), args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        if (args.len != 1) {
            return self.fail(.unknown_reader_construct, span, "unquote arity");
        }
        if (self.syntax_quote_depth == 0) {
            const error_kind: ErrorKind = switch (kind) {
                .unquote => .unquote_outside_syntax_quote,
                .@"unquote-splicing" => .unquote_splice_outside_syntax_quote,
                else => unreachable,
            };
            return self.fail(error_kind, span, null);
        }
        // Inside `~`/`~@` the form "leaves" syntax-quote scope for its child
        // (matching Clojure's reader).
        self.syntax_quote_depth -= 1;
        defer self.syntax_quote_depth += 1;
        const inner = try self.readForm(args[0]);
        const datum: Datum = switch (kind) {
            .unquote => .{ .unquote = inner },
            .@"unquote-splicing" => .{ .unquote_splicing = inner },
            else => unreachable,
        };
        return try self.makeForm(datum, span);
    }

    fn readAnonFn(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        if (self.anon_fn_depth > 0) {
            return self.fail(.nested_anon_fn, span, null);
        }
        self.anon_fn_depth += 1;
        defer self.anon_fn_depth -= 1;
        const body = try self.readFormsList(args);
        return try self.makeForm(.{ .anon_fn = body }, span);
    }

    fn readWithMetaRaw(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError!*Form {
        if (args.len != 2) {
            return self.fail(.unknown_reader_construct, span, "with-meta-raw arity");
        }
        const target_raw = args[0];
        const meta_raw = args[1];

        // Walk through stacked (with-meta-raw) forms left-to-right in source
        // order, accumulating metadata maps; the innermost target is the
        // final target. FORMS.md §3 specifies rightmost-wins on duplicate
        // keys, which matches the order we encounter them because nested
        // metadata grammar wraps outside-in.
        var metas: std.ArrayList(Sexp) = .empty;
        defer metas.deinit(self.allocator());
        try metas.append(self.allocator(), meta_raw);

        var current = target_raw;
        while (self.isCompoundWithTag(current, .@"with-meta-raw")) {
            const inner_items = try self.requireCompound(current, .@"with-meta-raw");
            if (inner_items.len != 2) {
                return self.fail(.unknown_reader_construct, srcSpan(current), "nested with-meta-raw arity");
            }
            try metas.append(self.allocator(), inner_items[1]);
            current = inner_items[0];
        }
        const target = try self.readForm(current);
        const merged = try self.mergeMetaChain(metas.items, span);
        return try self.makeForm(.{ .with_meta = .{ .target = target, .meta = merged } }, span);
    }

    fn mergeMetaChain(self: *Reader, raw_metas: []const Sexp, span: SrcSpan) ReaderError!*Form {
        // raw_metas is in grammar nesting order (outer-first). For `^A ^B x`
        // the grammar gives (with-meta-raw (with-meta-raw x B) A), which
        // unwound above yields raw_metas = [A, B]. Source order is B-then-A
        // textually, but per FORMS.md §3 rightmost (= latest source) wins,
        // and the pretty-printer example in PLAN §28.5 (^:dynamic ^{:doc
        // "hi"} *out* → {:dynamic true, :doc "hi"}) tells us the source-
        // leftmost metadata goes first, rightmost overrides. Applying raw_
        // metas in REVERSE gives source-left-first, source-right-last —
        // exactly the "rightmost wins" semantics.
        var entries: std.ArrayList(*Form) = .empty;
        errdefer entries.deinit(self.allocator());
        var i = raw_metas.len;
        while (i > 0) {
            i -= 1;
            const m = try self.readForm(raw_metas[i]);
            try self.appendMetaEntries(&entries, m, span);
        }
        // Deduplicate by key — later entries (rightmost) win.
        var deduped: std.ArrayList(*Form) = .empty;
        errdefer deduped.deinit(self.allocator());
        var idx: usize = 0;
        while (idx < entries.items.len) : (idx += 2) {
            const k = entries.items[idx];
            const v = entries.items[idx + 1];
            var last_v = v;
            var j = idx + 2;
            while (j < entries.items.len) : (j += 2) {
                if (formLiteralEq(entries.items[j], k)) {
                    last_v = entries.items[j + 1];
                }
            }
            // Skip if this key appears later — it'll be emitted at its last
            // occurrence.
            var found_later = false;
            j = idx + 2;
            while (j < entries.items.len) : (j += 2) {
                if (formLiteralEq(entries.items[j], k)) {
                    found_later = true;
                    break;
                }
            }
            if (found_later) continue;
            try deduped.append(self.allocator(), k);
            try deduped.append(self.allocator(), last_v);
        }
        return try self.makeForm(.{ .map = try deduped.toOwnedSlice(self.allocator()) }, span);
    }

    /// Accept `^:kw`, `^{...}`, or `^sym` and append the resulting
    /// key/value pairs to `entries`.
    fn appendMetaEntries(self: *Reader, entries: *std.ArrayList(*Form), m: *Form, span: SrcSpan) ReaderError!void {
        switch (m.datum) {
            .keyword => {
                try entries.append(self.allocator(), m);
                const tr = try self.makeForm(.{ .bool_ = true }, span);
                try entries.append(self.allocator(), tr);
            },
            .symbol => {
                const tag_kw = try self.makeForm(.{ .keyword = .{ .ns = null, .name = "tag" } }, span);
                try entries.append(self.allocator(), tag_kw);
                try entries.append(self.allocator(), m);
            },
            .map => |kv| {
                if (kv.len % 2 != 0) return self.fail(.map_odd_count, m.origin, null);
                for (kv) |p| try entries.append(self.allocator(), p);
            },
            else => return self.fail(.unknown_reader_construct, m.origin, "metadata must be a keyword, map, or symbol"),
        }
    }

    // -------------------------------------------------------------------------
    // String / character / number decoding helpers
    // -------------------------------------------------------------------------

    fn decodeStringEscapes(self: *Reader, body: []const u8, span: SrcSpan) ReaderError![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator());
        var i: usize = 0;
        while (i < body.len) {
            const ch = body[i];
            if (ch != '\\') {
                try out.append(self.allocator(), ch);
                i += 1;
                continue;
            }
            if (i + 1 >= body.len) {
                return self.fail(.invalid_string_escape, span, body);
            }
            const esc = body[i + 1];
            switch (esc) {
                'n' => {
                    try out.append(self.allocator(), '\n');
                    i += 2;
                },
                't' => {
                    try out.append(self.allocator(), '\t');
                    i += 2;
                },
                'r' => {
                    try out.append(self.allocator(), '\r');
                    i += 2;
                },
                '\\' => {
                    try out.append(self.allocator(), '\\');
                    i += 2;
                },
                '"' => {
                    try out.append(self.allocator(), '"');
                    i += 2;
                },
                'u' => {
                    if (i + 2 >= body.len or body[i + 2] != '{') {
                        return self.fail(.invalid_string_escape, span, body);
                    }
                    const hex_start = i + 3;
                    var hex_end = hex_start;
                    while (hex_end < body.len and body[hex_end] != '}') : (hex_end += 1) {}
                    if (hex_end == body.len or hex_end == hex_start) {
                        return self.fail(.invalid_string_escape, span, body);
                    }
                    const codepoint = std.fmt.parseInt(u32, body[hex_start..hex_end], 16) catch
                        return self.fail(.invalid_string_escape, span, body);
                    if (codepoint > 0x10FFFF) {
                        return self.fail(.invalid_string_escape, span, body);
                    }
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(codepoint), &utf8_buf) catch
                        return self.fail(.invalid_string_escape, span, body);
                    try out.appendSlice(self.allocator(), utf8_buf[0..n]);
                    i = hex_end + 1;
                },
                else => return self.fail(.invalid_string_escape, span, body),
            }
        }
        return try out.toOwnedSlice(self.allocator());
    }

    fn fail(self: *Reader, kind: ErrorKind, span: SrcSpan, detail: ?[]const u8) ReaderError {
        const owned_detail = if (detail) |d| self.arena.allocator().dupe(u8, d) catch null else null;
        self.err = .{ .kind = kind, .span = span, .detail = owned_detail };
        return error.ReaderFailure;
    }

    fn makeForm(self: *Reader, datum: Datum, span: SrcSpan) ReaderError!*Form {
        const f = try self.allocator().create(Form);
        f.* = .{ .datum = datum, .origin = span };
        return f;
    }

    fn requireCompound(self: *Reader, s: Sexp, expected: Tag) ReaderError![]const Sexp {
        const items = switch (s) {
            .list => |it| it,
            else => return self.fail(.unknown_reader_construct, srcSpan(s), null),
        };
        if (items.len == 0 or items[0] != .tag or items[0].tag != expected) {
            return self.fail(.unknown_reader_construct, srcSpan(s), null);
        }
        return items[1..];
    }

    fn isCompoundWithTag(_: *const Reader, s: Sexp, expected: Tag) bool {
        return switch (s) {
            .list => |it| it.len > 0 and it[0] == .tag and it[0].tag == expected,
            else => false,
        };
    }

    fn formatLiteralKey(self: *Reader, f: *const Form) ReaderError![]const u8 {
        var al: std.Io.Writer.Allocating = .init(self.allocator());
        writeForm(f, &al.writer) catch return error.OutOfMemory;
        return try al.toOwnedSlice();
    }
};

// -----------------------------------------------------------------------------
// Pure helpers (no Reader state)
// -----------------------------------------------------------------------------

/// How many nested `(discard ...)` layers wrap this sexp (at least 1 when
/// called on a discard compound). Equal to the number of source forms the
/// original `#_` chain consumed.
fn discardChainDepth(s: Sexp) usize {
    var depth: usize = 0;
    var cur = s;
    while (true) {
        if (cur != .list) break;
        const it = cur.list;
        if (it.len < 2 or it[0] != .tag or it[0].tag != .discard) break;
        depth += 1;
        cur = it[1];
    }
    return depth;
}

fn srcSpan(s: Sexp) SrcSpan {
    return switch (s) {
        .src => |r| .{ .pos = r.pos, .len = r.len },
        .list => |it| blk: {
            // Actions like (with-meta-raw 3 2) reorder positional children
            // relative to source order; the compound's logical span is the
            // min/max envelope over all descendant source positions.
            var lo: u32 = std.math.maxInt(u32);
            var hi: u32 = 0;
            var any = false;
            for (it) |c| {
                if (c == .tag) continue;
                const s2 = srcSpan(c);
                if (s2.len == 0 and s2.pos == 0) continue;
                if (s2.pos < lo) lo = s2.pos;
                const end = s2.pos + s2.len;
                if (end > hi) hi = end;
                any = true;
            }
            if (!any) break :blk .{ .pos = 0, .len = 0 };
            break :blk .{ .pos = lo, .len = hi - lo };
        },
        else => .{ .pos = 0, .len = 0 },
    };
}

fn expectSrcText(self: *Reader, args: []const Sexp, span: SrcSpan) ReaderError![]const u8 {
    if (args.len != 1) return self.fail(.unknown_reader_construct, span, "atom must wrap exactly one src");
    const a = args[0];
    return switch (a) {
        .src => |r| self.source[r.pos..][0..r.len],
        else => self.fail(.unknown_reader_construct, span, "atom expected .src child"),
    };
}

/// Parse an integer literal with explicit radix support and strict i64
/// range enforcement. Returns null for malformed input OR for values that
/// are syntactically valid but outside i64 range — callers report the
/// out-of-range case separately so Phase 1's bignum promotion can light up
/// without disturbing the bad-number-literal path.
fn parseIntLiteral(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var negative = false;
    var t = text;
    if (t[0] == '-') {
        if (t.len == 1) return null;
        negative = true;
        t = t[1..];
    }
    var base: u8 = 10;
    if (t.len >= 2 and t[0] == '0') {
        if (t[1] == 'x' or t[1] == 'X') {
            base = 16;
            t = t[2..];
        } else if (t[1] == 'b' or t[1] == 'B') {
            base = 2;
            t = t[2..];
        }
    }
    if (t.len == 0) return null;
    const mag = std.fmt.parseInt(u64, t, base) catch return null;
    if (negative) {
        const neg_limit: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
        if (mag > neg_limit) return null;
        if (mag == neg_limit) return std.math.minInt(i64);
        return -@as(i64, @intCast(mag));
    }
    if (mag > std.math.maxInt(i64)) return null;
    return @intCast(mag);
}

fn parseCharLiteral(body: []const u8) ?u21 {
    if (body.len == 0) return null;
    // `u{HEX}` form.
    if (body.len >= 4 and body[0] == 'u' and body[1] == '{' and body[body.len - 1] == '}') {
        const hex = body[2 .. body.len - 1];
        if (hex.len == 0) return null;
        const v = std.fmt.parseInt(u32, hex, 16) catch return null;
        if (v > 0x10FFFF) return null;
        return @intCast(v);
    }
    // Named character set (PLAN §7.2).
    if (body.len > 1) {
        if (std.mem.eql(u8, body, "newline")) return '\n';
        if (std.mem.eql(u8, body, "space")) return ' ';
        if (std.mem.eql(u8, body, "tab")) return '\t';
        if (std.mem.eql(u8, body, "return")) return '\r';
        if (std.mem.eql(u8, body, "formfeed")) return 0x0C;
        if (std.mem.eql(u8, body, "backspace")) return 0x08;
        return null;
    }
    // Single-byte literal (ASCII). Multi-byte UTF-8 chars need broader
    // handling; Phase 0 accepts ASCII directly and `\u{HEX}` for the rest.
    return body[0];
}

fn splitNamespace(text: []const u8) ?Name {
    if (text.len == 0) return null;
    // `/` by itself is the division symbol (only valid unqualified name
    // that is itself a slash).
    if (std.mem.eql(u8, text, "/")) {
        return Name{ .ns = null, .name = text };
    }
    const first = std.mem.indexOfScalar(u8, text, '/') orelse {
        return Name{ .ns = null, .name = text };
    };
    const last = std.mem.lastIndexOfScalar(u8, text, '/').?;
    // At most one `/` separator is permitted; multi-slash names like
    // `foo/bar/baz` are rejected here and surface as :invalid-symbol /
    // :invalid-keyword.
    if (first != last) return null;
    if (first == 0 or first == text.len - 1) return null;
    return Name{ .ns = text[0..first], .name = text[first + 1 ..] };
}

/// A Form is a "literal key" eligible for static duplicate detection iff it
/// is an atom (nil/bool/int/real/char/string/keyword/symbol) AND its value
/// is compile-time known. For Phase 0 we treat every atom as literal.
fn isLiteralKey(f: *const Form) bool {
    return switch (f.datum) {
        .nil, .bool_, .int, .real, .char, .string, .keyword, .symbol => true,
        else => false,
    };
}

fn formLiteralEq(a: *const Form, b: *const Form) bool {
    return switch (a.datum) {
        .nil => b.datum == .nil,
        .bool_ => |ab| b.datum == .bool_ and b.datum.bool_ == ab,
        .int => |ai| b.datum == .int and b.datum.int == ai,
        .real => |ar| b.datum == .real and b.datum.real == ar, // naive; NaN semantics in Phase 1
        .char => |ac| b.datum == .char and b.datum.char == ac,
        .string => |s| b.datum == .string and std.mem.eql(u8, s, b.datum.string),
        .keyword => |ak| b.datum == .keyword and nameEq(ak, b.datum.keyword),
        .symbol => |ak| b.datum == .symbol and nameEq(ak, b.datum.symbol),
        else => false,
    };
}

fn nameEq(a: Name, b: Name) bool {
    const ns_eq = if (a.ns) |an|
        (b.ns != null and std.mem.eql(u8, an, b.ns.?))
    else
        (b.ns == null);
    return ns_eq and std.mem.eql(u8, a.name, b.name);
}

// -----------------------------------------------------------------------------
// Pretty-printer (canonical Form serialization per FORMS.md §5)
// -----------------------------------------------------------------------------

/// Render a Form tree to a writer using the canonical pretty-printer
/// format documented in FORMS.md §5.
pub fn writeForm(f: *const Form, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeFormIndent(f, w, 0);
}

/// Render a program (top-level) as the implicit outer `(program ...)`.
pub fn writeProgram(forms: []const *Form, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("(program");
    for (forms) |f| {
        try w.writeAll("\n  ");
        try writeFormIndent(f, w, 2);
    }
    try w.writeAll(")\n");
}

fn writeFormIndent(f: *const Form, w: *std.Io.Writer, indent: u32) std.Io.Writer.Error!void {
    switch (f.datum) {
        .nil => try w.writeAll("nil"),
        .bool_ => |b| try w.writeAll(if (b) "(bool true)" else "(bool false)"),
        .int => |i| try w.print("(int {d})", .{i}),
        .real => |r| try writeReal(r, w),
        .char => |c| try writeCharAtom(c, w),
        .string => |s| try writeStringAtom(s, w),
        .keyword => |k| try writeKeywordAtom(k, w),
        .symbol => |s| try writeSymbolAtom(s, w),
        .list => |xs| try writeCompound("list", xs, w, indent),
        .vector => |xs| try writeCompound("vector", xs, w, indent),
        .map => |xs| try writeCompound("map", xs, w, indent),
        .set => |xs| try writeCompound("set", xs, w, indent),
        .anon_fn => |xs| try writeCompound(anon_fn_symbol_name, xs, w, indent),
        .quote => |inner| try writeCompound("quote", &[_]*const Form{inner}, w, indent),
        .syntax_quote => |inner| try writeCompound("syntax-quote", &[_]*const Form{inner}, w, indent),
        .unquote => |inner| try writeCompound("unquote", &[_]*const Form{inner}, w, indent),
        .unquote_splicing => |inner| try writeCompound("unquote-splicing", &[_]*const Form{inner}, w, indent),
        .deref => |inner| try writeCompound("deref", &[_]*const Form{inner}, w, indent),
        .with_meta => |wm| try writeCompound("with-meta", &[_]*const Form{ wm.target, wm.meta }, w, indent),
    }
}

fn writeCompound(tag: []const u8, children: []const *const Form, w: *std.Io.Writer, indent: u32) std.Io.Writer.Error!void {
    try w.writeByte('(');
    try w.writeAll(tag);
    if (children.len == 0) {
        try w.writeByte(')');
        return;
    }
    // Inline when all children are atoms (single-line compound); break
    // onto indented new lines otherwise. Width-aware wrapping is a future
    // tooling pass — FORMS.md §5 calls this out.
    if (allAtoms(children)) {
        for (children) |c| {
            try w.writeByte(' ');
            try writeFormIndent(c, w, indent);
        }
        try w.writeByte(')');
        return;
    }
    const child_indent = indent + 2;
    for (children) |c| {
        try w.writeByte('\n');
        try writePadding(w, child_indent);
        try writeFormIndent(c, w, child_indent);
    }
    try w.writeByte(')');
}

fn writePadding(w: *std.Io.Writer, cols: u32) std.Io.Writer.Error!void {
    var i: u32 = 0;
    while (i < cols) : (i += 1) try w.writeByte(' ');
}

fn allAtoms(children: []const *const Form) bool {
    for (children) |c| {
        switch (c.datum) {
            .list, .vector, .map, .set, .anon_fn, .quote, .syntax_quote, .unquote, .unquote_splicing, .deref, .with_meta => return false,
            else => {},
        }
    }
    return true;
}

fn writeReal(r: f64, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.math.isNan(r)) {
        try w.writeAll("(real +nan)");
        return;
    }
    if (std.math.isPositiveInf(r)) {
        try w.writeAll("(real +inf)");
        return;
    }
    if (std.math.isNegativeInf(r)) {
        try w.writeAll("(real -inf)");
        return;
    }
    try w.print("(real {d})", .{r});
}

fn writeCharAtom(c: u21, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("(char ");
    switch (c) {
        '\n' => try w.writeAll("\\newline"),
        ' ' => try w.writeAll("\\space"),
        '\t' => try w.writeAll("\\tab"),
        '\r' => try w.writeAll("\\return"),
        0x0C => try w.writeAll("\\formfeed"),
        0x08 => try w.writeAll("\\backspace"),
        else => {
            if (c >= 0x21 and c <= 0x7E) {
                try w.print("\\{c}", .{@as(u8, @intCast(c))});
            } else {
                try w.print("\\u{{{X}}}", .{c});
            }
        },
    }
    try w.writeByte(')');
}

fn writeStringAtom(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("(string \"");
    for (s) |b| {
        switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            '\r' => try w.writeAll("\\r"),
            else => {
                if (b >= 0x20 and b < 0x7F) {
                    try w.writeByte(b);
                } else {
                    try w.print("\\u{{{X}}}", .{b});
                }
            },
        }
    }
    try w.writeAll("\")");
}

fn writeKeywordAtom(k: Name, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("(keyword :");
    if (k.ns) |ns| {
        try w.writeAll(ns);
        try w.writeByte('/');
    }
    try w.writeAll(k.name);
    try w.writeByte(')');
}

fn writeSymbolAtom(s: Name, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("(symbol ");
    if (s.ns) |ns| {
        try w.writeAll(ns);
        try w.writeByte('/');
    }
    try w.writeAll(s.name);
    try w.writeByte(')');
}

// -----------------------------------------------------------------------------
// Inline tests — structural sanity checks; golden tests cover the surface.
// -----------------------------------------------------------------------------

test "integer radix normalization" {
    try std.testing.expectEqual(@as(i64, 42), parseIntLiteral("42").?);
    try std.testing.expectEqual(@as(i64, -1), parseIntLiteral("-1").?);
    try std.testing.expectEqual(@as(i64, 42), parseIntLiteral("0x2A").?);
    try std.testing.expectEqual(@as(i64, 5), parseIntLiteral("0b101").?);
    try std.testing.expectEqual(@as(i64, -255), parseIntLiteral("-0xFF").?);
    // Boundary: i64.min/max are representable.
    try std.testing.expectEqual(std.math.minInt(i64), parseIntLiteral("-9223372036854775808").?);
    try std.testing.expectEqual(std.math.maxInt(i64), parseIntLiteral("9223372036854775807").?);
    // Out-of-range is rejected (Phase 1 promotes to bignum).
    try std.testing.expect(parseIntLiteral("9223372036854775808") == null);
    try std.testing.expect(parseIntLiteral("-9223372036854775809") == null);
    // Malformed.
    try std.testing.expect(parseIntLiteral("") == null);
    try std.testing.expect(parseIntLiteral("-") == null);
    try std.testing.expect(parseIntLiteral("0xG") == null);
}

test "nil / true / false only match unqualified symbols" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{ "nil", "true", "false", "foo/nil", "foo/true", "foo/false", ":nil", ":true" };
    const expect_atomic = [_]bool{ true, true, true, false, false, false, false, false };
    for (cases, expect_atomic) |src, want_atomic| {
        var p = parser.Parser.init(allocator, src);
        defer p.deinit();
        const tree = try p.parseProgram();
        var rd = Reader.init(allocator, src);
        defer rd.deinit();
        const forms = try rd.readProgram(tree);
        try std.testing.expect(forms.len == 1);
        const is_atomic = switch (forms[0].datum) {
            .nil, .bool_ => true,
            else => false,
        };
        try std.testing.expectEqual(want_atomic, is_atomic);
    }
}

test "namespace split" {
    const a = splitNamespace("foo").?;
    try std.testing.expect(a.ns == null);
    try std.testing.expectEqualStrings("foo", a.name);

    const b = splitNamespace("ns/foo").?;
    try std.testing.expectEqualStrings("ns", b.ns.?);
    try std.testing.expectEqualStrings("foo", b.name);

    // `/` division symbol
    const c = splitNamespace("/").?;
    try std.testing.expect(c.ns == null);
    try std.testing.expectEqualStrings("/", c.name);

    // Trailing or leading `/` is invalid
    try std.testing.expect(splitNamespace("foo/") == null);
    try std.testing.expect(splitNamespace("/foo") == null);

    // Multi-slash is invalid (at most one separator)
    try std.testing.expect(splitNamespace("foo/bar/baz") == null);
    try std.testing.expect(splitNamespace("a/b/c/d") == null);
}

test "char literal parsing" {
    try std.testing.expectEqual(@as(u21, 'a'), parseCharLiteral("a").?);
    try std.testing.expectEqual(@as(u21, '\n'), parseCharLiteral("newline").?);
    try std.testing.expectEqual(@as(u21, 0x2603), parseCharLiteral("u{2603}").?);
    try std.testing.expect(parseCharLiteral("") == null);
    try std.testing.expect(parseCharLiteral("u{}") == null);
}

test "discard applies uniformly across aggregator contexts" {
    const allocator = std.testing.allocator;
    // Discard consumes its next form INCLUDING any attached reader sugar
    // (metadata, deref, quote, anon-fn). The grammar treats the prefixed
    // form as a single child, so the reader's drop logic handles this
    // without special casing.
    const cases = [_]struct { src: []const u8, expected_len: usize }{
        .{ .src = "#_ ^:m x y", .expected_len = 1 }, // ^:m x is one form
        .{ .src = "#_ @a b", .expected_len = 1 }, // @a is one form
        .{ .src = "#_ '(+ 1 2) keep", .expected_len = 1 }, // quoted list is one form
        .{ .src = "#_ #(+ % 1) z", .expected_len = 1 }, // anon-fn is one form
        .{ .src = "[#_ x y]", .expected_len = 1 }, // discard inside vector
        .{ .src = "#{#_ x :a}", .expected_len = 1 }, // discard inside set
    };
    for (cases) |c| {
        var p = parser.Parser.init(allocator, c.src);
        defer p.deinit();
        const tree = try p.parseProgram();
        var rd = Reader.init(allocator, c.src);
        defer rd.deinit();
        const forms = try rd.readProgram(tree);
        try std.testing.expectEqual(c.expected_len, forms.len);
    }
}

test "discard inside a map affects key/value arity" {
    // `{:a 1 #_ :b 2}` drops `:b`, leaving `[:a, 1, 2]` (3 forms, odd) —
    // the map reader correctly reports :map-odd-count. This pins the
    // behavior: discards reshape map contents and the error surfaces at
    // the post-discard arity check, not silently.
    const allocator = std.testing.allocator;
    const src: []const u8 = "{:a 1 #_ :b 2}";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    const tree = try p.parseProgram();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    try std.testing.expectError(error.ReaderFailure, rd.readProgram(tree));
    try std.testing.expect(rd.err.?.kind == .map_odd_count);
}

test "stacked discard drops siblings in source order" {
    // `#_ #_ x y z` must yield `[z]` at top level (drops x and y) per
    // Clojure's procedural reader semantics. Depth-N discard chain consumes
    // N source forms.
    const allocator = std.testing.allocator;
    const cases = [_]struct { src: []const u8, expected_count: usize, first_atom: ?[]const u8 }{
        .{ .src = "#_ x y", .expected_count = 1, .first_atom = "y" },
        .{ .src = "#_ #_ x y z", .expected_count = 1, .first_atom = "z" },
        .{ .src = "#_ #_ #_ a b c d", .expected_count = 1, .first_atom = "d" },
        .{ .src = "[#_ #_ x y z]", .expected_count = 1, .first_atom = null }, // wrapped
        .{ .src = "(+ #_ #_ x y 3 4)", .expected_count = 1, .first_atom = null },
    };
    for (cases) |c| {
        var p = parser.Parser.init(allocator, c.src);
        defer p.deinit();
        const tree = try p.parseProgram();
        var rd = Reader.init(allocator, c.src);
        defer rd.deinit();
        const forms = try rd.readProgram(tree);
        try std.testing.expectEqual(c.expected_count, forms.len);
        if (c.first_atom) |name| {
            try std.testing.expect(forms[0].datum == .symbol);
            try std.testing.expectEqualStrings(name, forms[0].datum.symbol.name);
        }
    }
}

test "keyword starting with `-` is accepted" {
    const allocator = std.testing.allocator;
    const src: []const u8 = ":-foo :-> :-";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    const tree = try p.parseProgram();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    const forms = try rd.readProgram(tree);
    try std.testing.expectEqual(@as(usize, 3), forms.len);
    for (forms) |f| try std.testing.expect(f.datum == .keyword);
    try std.testing.expectEqualStrings("-foo", forms[0].datum.keyword.name);
    try std.testing.expectEqualStrings("->", forms[1].datum.keyword.name);
    try std.testing.expectEqualStrings("-", forms[2].datum.keyword.name);
}

test "multi-slash qualified names are rejected" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{ "foo/bar/baz", ":foo/bar/baz" };
    for (cases) |src| {
        var p = parser.Parser.init(allocator, src);
        defer p.deinit();
        const tree = try p.parseProgram();
        var rd = Reader.init(allocator, src);
        defer rd.deinit();
        try std.testing.expectError(error.ReaderFailure, rd.readProgram(tree));
    }
}

test "anon-fn stores body only (no synthetic head)" {
    const allocator = std.testing.allocator;
    const src: []const u8 = "#(+ % 1)";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    const tree = try p.parseProgram();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    const forms = try rd.readProgram(tree);
    try std.testing.expectEqual(@as(usize, 1), forms.len);
    try std.testing.expect(forms[0].datum == .anon_fn);
    // Body is exactly the source forms — no pre-pended `#%anon-fn` symbol.
    const body = forms[0].datum.anon_fn;
    try std.testing.expectEqual(@as(usize, 3), body.len);
    try std.testing.expect(body[0].datum == .symbol);
    try std.testing.expectEqualStrings("+", body[0].datum.symbol.name);
    try std.testing.expect(body[1].datum == .symbol);
    try std.testing.expectEqualStrings("%", body[1].datum.symbol.name);
    try std.testing.expect(body[2].datum == .int);
    try std.testing.expectEqual(@as(i64, 1), body[2].datum.int);
}

test "end-to-end: simple reader + pretty-print round trip" {
    const allocator = std.testing.allocator;
    const source: []const u8 = "(def x 42)";
    var p = parser.Parser.init(allocator, source);
    defer p.deinit();
    const tree = try p.parseProgram();

    var rd = Reader.init(allocator, source);
    defer rd.deinit();

    const forms = try rd.readProgram(tree);

    var al: std.Io.Writer.Allocating = .init(allocator);
    defer al.deinit();
    try writeProgram(forms, &al.writer);
    const out = al.written();

    const expected =
        \\(program
        \\  (list (symbol def) (symbol x) (int 42)))
        \\
    ;
    try std.testing.expectEqualStrings(expected, out);
}
