//! reader.zig — Sexp → Form normalizer.
//!
//! Consumes the raw `Sexp` tree produced by the nexus-generated parser
//! (`nexis.grammar`, scanner `src/nexis.zig`) and produces the canonical
//! `Form` tree documented in `docs/FORMS.md`. All normalization rules
//! from PLAN §28.3 / FORMS.md §3 are enforced here; anything that requires
//! namespace resolution or macro context is left for later stages
//! (`src/expand.zig`, `src/compile.zig`).
//!
//!   - Parse atom text into typed datums (int, bigint, real, char, string,
//!     keyword, symbol) and nil/true/false from symbol text.
//!   - Reject what FORMS.md §3 calls reader errors (`ErrorKind`), with the
//!     span of the offending form or token.
//!   - Merge stacked metadata into one map; an outer `^` overrides an inner.
//!   - Store `#(...)` as the `anon_fn` datum, rejecting nesting.
//!   - Read `#'x` as the list `(var x)`.
//!   - Tag `(syntax-quote x)` only: auto-qualification, auto-gensym and
//!     unquote expansion live in the macroexpander (MACROEXPAND.md).
//!
//! `readOneForm` calls `stack.check` on entry, so input nested past the stack's
//! budget is `:nesting-too-deep`, and each Form's span comes from its
//! tokens in O(1). An integer literal beyond i64, in any radix, is a
//! `bigint` carrying canonical decimal text, so the compiler lifts it into
//! a bignum without re-reading the radix.

const std = @import("std");
/// The generated parser, for the callers that parse before reading.
pub const parser = @import("parser.zig");
const nexis = @import("nexis.zig");
const stack = @import("stack.zig");
const string_mod = @import("string.zig");
const regex = @import("regex.zig");

pub const Tag = nexis.Tag;
pub const Sexp = parser.Sexp;

// -----------------------------------------------------------------------------
// Form, Datum, Span, Error
// -----------------------------------------------------------------------------

pub const SrcSpan = struct {
    pos: u32,
    len: u32,
};

/// The longest source text the reader takes: every position in it is
/// a `u32` byte offset. The loader refuses a longer one up front.
pub const max_source_len: usize = std.math.maxInt(u32);

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
    /// An integer beyond i64, as canonical decimal text: an optional
    /// `-`, then digits with no leading zero. `int` and `bigint` never
    /// overlap, so literal equality is text equality.
    bigint: []const u8,
    real: f64,
    char: u21,
    /// Decoded UTF-8 bytes (escapes processed). Owned by the reader arena.
    string: []const u8,
    /// A regex literal's text between `#"` and `"`, with no escape
    /// processing (a backslash and the byte after it as written),
    /// borrowed from the source. Checked to compile.
    regex: []const u8,
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
};

/// What to write instead of a Clojure number literal nexis does not
/// read, for the report of a `bad_number_literal` whose text is
/// `text`: a ratio (`1/3`) or a BigDecimal (`1.5M`); null for any
/// other text. In `allocator`.
pub fn numberLiteralHint(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!?[]const u8 {
    const digits = struct {
        fn all(t: []const u8) bool {
            if (t.len == 0) return false;
            for (t) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
    }.all;
    const sign: usize = @intFromBool(text.len > 0 and (text[0] == '-' or text[0] == '+'));
    if (std.mem.findScalar(u8, text, '/')) |slash| {
        if (digits(text[sign..slash]) and digits(text[slash + 1 ..]))
            return try allocator.print("nexis has no ratios: (/ {s} {s}) divides, to a double when inexact", .{ text[0..slash], text[slash + 1 ..] });
    }
    if (text.len > 1 and text[text.len - 1] == 'M') {
        if (std.fmt.parseFloat(f64, text[0 .. text.len - 1])) |_| {
            return try allocator.print("nexis has no BigDecimal: {s} is a double", .{text[0 .. text.len - 1]});
        } else |_| {}
    }
    return null;
}

/// What to write instead of a Clojure tagged literal nexis does not
/// read, for the report of a parse error at `token` (`#inst`, `#uuid`,
/// any `#tag`); null for any other token.
pub fn taggedLiteralHint(token: []const u8) ?[]const u8 {
    if (token.len < 2 or token[0] != '#' or !std.ascii.isAlphabetic(token[1])) return null;
    if (std.mem.eql(u8, token, "#inst")) return "nexis has no #inst literal: (nexis.time/parse \"2026-10-09T12:00:00Z\") is an instant";
    if (std.mem.eql(u8, token, "#uuid")) return "nexis has no #uuid literal: a UUID is its canonical string";
    return "nexis reads no tagged literals";
}

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
    invalid_symbol,
    invalid_keyword,
    unknown_reader_construct,
    /// A string, symbol or keyword's bytes are not UTF-8.
    invalid_utf8,
    /// Nesting deeper than the native stack's budget (`src/stack.zig`).
    nesting_too_deep,
    /// A regex literal that does not compile (`docs/REGEX.md` §2).
    invalid_regex,
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
        return try self.readFormsList(tree.items()[1..]);
    }

    // -------------------------------------------------------------------------
    // Core dispatch
    // -------------------------------------------------------------------------

    /// Every list the grammar builds is a tag followed by its tokens and
    /// forms: an atom holds its one token, a compound its children
    /// between its delimiter tokens, a prefix form its token and its
    /// target (`nexis.grammar`).
    pub fn readOneForm(self: *Reader, s: Sexp) ReaderError!*Form {
        stack.check() catch return self.fail(.nesting_too_deep, sexpSpan(s), null);
        const items = s.items();
        if (items.len < 2 or items[0] != .tag or items[1] != .src)
            return self.fail(.unknown_reader_construct, sexpSpan(s), null);
        const tag: Tag = items[0].tag;
        switch (tag) {
            .int, .real, .string, .regex, .char, .keyword, .symbol => {
                const span = tokenSpan(items[1].src);
                const text = self.source[span.pos..][0..span.len];
                return switch (tag) {
                    .int => self.readInt(text, span),
                    .real => self.readReal(text, span),
                    .string => self.readString(text, span),
                    .regex => self.readRegex(text, span),
                    .char => self.readChar(text, span),
                    .keyword => self.readKeyword(text, span),
                    .symbol => self.readSymbol(text, span),
                    else => unreachable,
                };
            },
            .list, .vector, .map, .set, .@"anon-fn" => {
                const span = sexpSpan(s);
                const children = items[2 .. items.len - 1];
                return switch (tag) {
                    .list => self.makeForm(.{ .list = try self.readFormsList(children) }, span),
                    .vector => self.makeForm(.{ .vector = try self.readFormsList(children) }, span),
                    .map => self.readMap(children, span),
                    .set => self.readSet(children, span),
                    .@"anon-fn" => self.readAnonFn(children, span),
                    else => unreachable,
                };
            },
            .quote, .deref, .@"syntax-quote", .unquote, .@"unquote-splicing" => return self.readPrefix(tag, s),
            .@"with-meta-raw" => return self.readWithMetaRaw(s),
            .@"var-quote" => return self.readVarQuote(s),
            .program => return self.fail(.unknown_reader_construct, sexpSpan(s), "nested (program ...) not allowed"),
        }
    }

    fn readFormsList(self: *Reader, items: []const Sexp) ReaderError![]const *Form {
        const out = try self.allocator().alloc(*Form, items.len);
        for (items, out) |item, *f| f.* = try self.readOneForm(item);
        return out;
    }

    // -------------------------------------------------------------------------
    // Atom readers
    // -------------------------------------------------------------------------

    /// An integer token's text is the whole run the lexer took, so a
    /// malformed literal (`1abc`, `1-2`, `1/2`, `0x`) fails here with
    /// the text as detail. Clojure's `N` suffix names an arbitrary-
    /// precision integer; nexis has one integer domain (SEMANTICS.md
    /// §2), so `42N` reads exactly as `42` does.
    fn readInt(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const digits = if (text.len > 1 and text[text.len - 1] == 'N') text[0 .. text.len - 1] else text;
        if (parseIntLiteral(digits)) |value| return try self.makeForm(.{ .int = value }, span);
        const decimal = self.bigIntLiteral(digits) orelse
            return self.fail(.bad_number_literal, span, text);
        return try self.makeForm(.{ .bigint = decimal }, span);
    }

    /// The canonical decimal text of an integer literal beyond i64
    /// (`-?` then a `0x`/`0b` radix prefix or plain digits), in the
    /// reader's arena; `null` when the text is not an integer literal.
    fn bigIntLiteral(self: *Reader, text: []const u8) ?[]const u8 {
        const lit = splitIntLiteral(text) orelse return null;
        const alloc = self.allocator();
        var n = std.math.big.int.Managed.init(alloc) catch return null;
        n.setString(lit.base, lit.digits) catch return null;
        if (lit.negative) n.negate();
        return n.toString(alloc, 10, .lower) catch null;
    }

    fn readReal(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        // The symbolic floats `##Inf`, `##-Inf`, `##NaN` (FORMS.md §2).
        if (std.mem.startsWith(u8, text, "##")) {
            const symbolic: f64 = if (std.mem.eql(u8, text, "##Inf"))
                std.math.inf(f64)
            else if (std.mem.eql(u8, text, "##-Inf"))
                -std.math.inf(f64)
            else
                std.math.nan(f64);
            return try self.makeForm(.{ .real = symbolic }, span);
        }
        // Zig's parser takes `_` between digits; a nexis literal has none.
        if (std.mem.findScalar(u8, text, '_') != null) return self.fail(.bad_number_literal, span, text);
        const value = std.fmt.parseFloat(f64, text) catch
            return self.fail(.bad_number_literal, span, text);
        return try self.makeForm(.{ .real = value }, span);
    }

    /// The scanner's string token runs from its `"` to its closing one.
    fn readString(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const decoded = try self.decodeStringEscapes(text[1 .. text.len - 1], span);
        return try self.makeForm(.{ .string = decoded }, span);
    }

    /// `#"..."`: the text between the quotes as it is, as Clojure's
    /// `RegexReader` passes it to `Pattern.compile`; compiled once here
    /// so a bad pattern is a reader error at the literal, its detail
    /// the compiler's sentence and the code-point index it stopped at.
    fn readRegex(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const body = text[2 .. text.len - 1];
        if (!std.unicode.utf8ValidateSlice(body)) return self.fail(.invalid_utf8, span, null);
        var scratch: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
        defer scratch.deinit();
        const compiled = regex.compile(scratch.allocator(), body, .{}) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.StackOverflow => self.fail(.nesting_too_deep, span, null),
        };
        switch (compiled) {
            .ok => return try self.makeForm(.{ .regex = body }, span),
            .err => |e| {
                const index = std.unicode.utf8CountCodepoints(body[0..e.offset]) catch e.offset;
                const detail = try scratch.allocator().print("{s} at index {d}", .{ e.msg, index });
                return self.fail(.invalid_regex, span, detail);
            },
        }
    }

    /// The scanner's char token is `\` and at least one byte.
    fn readChar(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const scalar = parseCharLiteral(text[1..]) orelse
            return self.fail(.invalid_char_literal, span, text);
        return try self.makeForm(.{ .char = scalar }, span);
    }

    /// The scanner's keyword token is `:` and at least one byte.
    fn readKeyword(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        if (!std.unicode.utf8ValidateSlice(text)) return self.fail(.invalid_utf8, span, null);
        const name = splitNamespace(text[1..]) orelse
            return self.fail(.invalid_keyword, span, text);
        return try self.makeForm(.{ .keyword = name }, span);
    }

    fn readSymbol(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const raw = text;
        // nil / true / false are lexed as symbols and normalized here
        // (FORMS.md §3 — also PLAN §28.2).
        if (std.mem.eql(u8, raw, "nil")) return try self.makeForm(.nil, span);
        if (std.mem.eql(u8, raw, "true")) return try self.makeForm(.{ .bool_ = true }, span);
        if (std.mem.eql(u8, raw, "false")) return try self.makeForm(.{ .bool_ = false }, span);
        if (!std.unicode.utf8ValidateSlice(raw)) return self.fail(.invalid_utf8, span, null);
        const name = splitNamespace(raw) orelse
            return self.fail(.invalid_symbol, span, raw);
        return try self.makeForm(.{ .symbol = name }, span);
    }

    // -------------------------------------------------------------------------
    // Compound readers
    // -------------------------------------------------------------------------

    fn readMap(self: *Reader, items: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const children = try self.readFormsList(items);
        if (children.len % 2 != 0) {
            return self.fail(.map_odd_count, span, null);
        }
        if (try self.firstDuplicate(children, 2)) |k|
            return self.fail(.duplicate_literal_key, span, try self.formatLiteralKey(k));
        return try self.makeForm(.{ .map = children }, span);
    }

    fn readSet(self: *Reader, items: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const children = try self.readFormsList(items);
        if (try self.firstDuplicate(children, 1)) |e|
            return self.fail(.duplicate_literal_element, span, try self.formatLiteralKey(e));
        return try self.makeForm(.{ .set = children }, span);
    }

    /// The first literal among `forms[0]`, `forms[stride]`, ... equal
    /// to an earlier one (FORMS.md §3, "Duplicate detection rule").
    fn firstDuplicate(self: *Reader, forms: []const *Form, stride: usize) ReaderError!?*const Form {
        var seen: LiteralSet = .empty;
        defer seen.deinit(self.allocator());
        var i: usize = 0;
        while (i < forms.len) : (i += stride) {
            if (!isLiteralKey(forms[i])) continue;
            if ((try seen.getOrPut(self.allocator(), forms[i])).found_existing) return forms[i];
        }
        return null;
    }

    // -------------------------------------------------------------------------
    // Reader macros
    // -------------------------------------------------------------------------

    /// `'x`, `@x`, `` `x ``, `~x`, `~@x`: the span runs from the prefix
    /// token to the end of the target, known once the target is read.
    fn readPrefix(self: *Reader, tag: Tag, s: Sexp) ReaderError!*Form {
        const items = s.items();
        switch (tag) {
            .@"syntax-quote" => self.syntax_quote_depth += 1,
            .unquote, .@"unquote-splicing" => {
                if (self.syntax_quote_depth == 0) {
                    const kind: ErrorKind = if (tag == .unquote) .unquote_outside_syntax_quote else .unquote_splice_outside_syntax_quote;
                    return self.fail(kind, sexpSpan(s), null);
                }
                // The target of `~`/`~@` leaves syntax-quote scope, as in
                // Clojure's reader.
                self.syntax_quote_depth -= 1;
            },
            else => {},
        }
        defer switch (tag) {
            .@"syntax-quote" => self.syntax_quote_depth -= 1,
            .unquote, .@"unquote-splicing" => self.syntax_quote_depth += 1,
            else => {},
        };
        const inner = try self.readOneForm(items[2]);
        const datum: Datum = switch (tag) {
            .quote => .{ .quote = inner },
            .deref => .{ .deref = inner },
            .@"syntax-quote" => .{ .syntax_quote = inner },
            .unquote => .{ .unquote = inner },
            .@"unquote-splicing" => .{ .unquote_splicing = inner },
            else => unreachable,
        };
        return try self.makeForm(datum, spanTo(items[1].src.pos, inner.origin));
    }

    /// `#'x` is the list `(var x)`, as Clojure's reader makes it: no
    /// datum of its own, so quoting it yields the list and `var`
    /// rejects a non-symbol target at compile time. `var` spans `#'`.
    fn readVarQuote(self: *Reader, s: Sexp) ReaderError!*Form {
        const items = s.items();
        const head = try self.makeForm(.{ .symbol = .{ .ns = null, .name = "var" } }, tokenSpan(items[1].src));
        const inner = try self.readOneForm(items[2]);
        const list = try self.allocator().dupe(*Form, &.{ head, inner });
        return try self.makeForm(.{ .list = list }, spanTo(items[1].src.pos, inner.origin));
    }

    fn readAnonFn(self: *Reader, items: []const Sexp, span: SrcSpan) ReaderError!*Form {
        if (self.anon_fn_depth > 0) {
            return self.fail(.nested_anon_fn, span, null);
        }
        self.anon_fn_depth += 1;
        defer self.anon_fn_depth -= 1;
        const body = try self.readFormsList(items);
        return try self.makeForm(.{ .anon_fn = body }, span);
    }

    /// `^M1 ^M2 x` arrives as `(with-meta-raw ^ (with-meta-raw ^ x M2) M1)`:
    /// the chain is unwound to its innermost target, and the with-meta
    /// Form spans from the first `^` to the end of that target.
    fn readWithMetaRaw(self: *Reader, s: Sexp) ReaderError!*Form {
        var metas: std.ArrayList(Sexp) = .empty;
        defer metas.deinit(self.allocator());
        var current = s;
        while (current.isKind(.@"with-meta-raw")) {
            const items = current.items();
            try metas.append(self.allocator(), items[3]);
            current = items[2];
        }
        const target = try self.readOneForm(current);
        const span = spanTo(s.items()[1].src.pos, target.origin);
        const merged = try self.mergeMetaChain(metas.items, span);
        return try self.makeForm(.{ .with_meta = .{ .target = target, .meta = merged } }, span);
    }

    /// Merge a `^` chain's metadata into one map. `raw_metas` is outer
    /// (source-leftmost) first. As Clojure's reader assoc's each outer
    /// `^` onto the metadata of the form it wraps, the entries are
    /// gathered innermost first and a literal key keeps its value from
    /// its last occurrence, at that occurrence's place.
    fn mergeMetaChain(self: *Reader, raw_metas: []const Sexp, span: SrcSpan) ReaderError!*Form {
        const alloc = self.allocator();
        var entries: std.ArrayList(*Form) = .empty;
        var i = raw_metas.len;
        while (i > 0) {
            i -= 1;
            const m = try self.readOneForm(raw_metas[i]);
            try self.appendMetaEntries(&entries, m, span);
        }
        // Walk the pairs from the end, keeping each literal key's last
        // occurrence, then restore source order.
        var seen: LiteralSet = .empty;
        defer seen.deinit(alloc);
        const merged = try alloc.alloc(*Form, entries.items.len);
        var n: usize = merged.len;
        var j = entries.items.len;
        while (j > 0) : (j -= 2) {
            const k = entries.items[j - 2];
            if (isLiteralKey(k) and (try seen.getOrPut(alloc, k)).found_existing) continue;
            n -= 2;
            merged[n] = k;
            merged[n + 1] = entries.items[j - 1];
        }
        return try self.makeForm(.{ .map = merged[n..] }, span);
    }

    /// Accept `^:kw`, `^{...}`, `^sym`, `^"string"` or `^[...]` and
    /// append the resulting key/value pairs to `entries`.
    fn appendMetaEntries(self: *Reader, entries: *std.ArrayList(*Form), m: *Form, span: SrcSpan) ReaderError!void {
        switch (m.datum) {
            .keyword => {
                try entries.append(self.allocator(), m);
                const tr = try self.makeForm(.{ .bool_ = true }, span);
                try entries.append(self.allocator(), tr);
            },
            // `^String x` and `^"String" x` are a `:tag`, `^[long]
            // f` Clojure's `:param-tags`.
            .symbol, .string, .vector => {
                const key = if (m.datum == .vector) "param-tags" else "tag";
                try entries.append(self.allocator(), try self.makeForm(.{ .keyword = .{ .ns = null, .name = key } }, span));
                try entries.append(self.allocator(), m);
            },
            .map => |kv| {
                if (kv.len % 2 != 0) return self.fail(.map_odd_count, m.origin, null);
                for (kv) |p| try entries.append(self.allocator(), p);
            },
            else => return self.fail(.unknown_reader_construct, m.origin, "metadata must be a keyword, map, symbol, string or vector"),
        }
    }

    // -------------------------------------------------------------------------
    // String / character / number decoding helpers
    // -------------------------------------------------------------------------

    /// A string body with its escapes decoded (FORMS.md §3). The bytes
    /// must be UTF-8; an escape that fails is the error's detail.
    fn decodeStringEscapes(self: *Reader, body: []const u8, span: SrcSpan) ReaderError![]const u8 {
        if (!std.unicode.utf8ValidateSlice(body)) return self.fail(.invalid_utf8, span, null);
        // Every escape is at least as long as the bytes it stands for.
        var out = try std.ArrayList(u8).initCapacity(self.allocator(), body.len);
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, body, i, '\\')) |at| {
            out.appendSliceAssumeCapacity(body[i..at]);
            i = @min(at + 2, body.len);
            const simple: ?u8 = if (at + 1 == body.len) null else switch (body[at + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'b' => 0x08,
                'f' => 0x0C,
                '\\' => '\\',
                '"' => '"',
                else => null,
            };
            if (simple) |b| {
                out.appendAssumeCapacity(b);
                continue;
            }
            // Clojure's octal escape: one to three octal digits, at
            // most `\377`.
            if (at + 1 < body.len and body[at + 1] >= '0' and body[at + 1] <= '7') {
                var end = at + 1;
                while (end < body.len and end < at + 4 and body[end] >= '0' and body[end] <= '7') end += 1;
                i = end;
                const unit = std.fmt.parseInt(u21, body[at + 1 .. end], 8) catch unreachable;
                if (unit > 0o377) return self.fail(.invalid_string_escape, span, body[at..end]);
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(unit, &utf8) catch unreachable;
                out.appendSliceAssumeCapacity(utf8[0..n]);
                continue;
            }
            if (body[i - 1] != 'u')
                return self.fail(.invalid_string_escape, span, body[at..i]);
            if (i == body.len or body[i] != '{') {
                // Clojure's `\uXXXX` names a UTF-16 unit: a high
                // surrogate must pair with a `\uXXXX` low one.
                const escape = body[at..@min(body.len, at + 6)];
                const unit = hex4(body[i..@min(body.len, i + 4)]) orelse
                    return self.fail(.invalid_string_escape, span, escape);
                i += 4;
                var scalar = unit;
                if (unit >= 0xD800 and unit <= 0xDBFF) {
                    const low = if (i + 6 <= body.len and body[i] == '\\' and body[i + 1] == 'u') hex4(body[i + 2 .. i + 6]) else null;
                    if (low == null or low.? < 0xDC00 or low.? > 0xDFFF)
                        return self.fail(.invalid_string_escape, span, escape);
                    scalar = 0x10000 + ((unit - 0xD800) << 10) + (low.? - 0xDC00);
                    i += 6;
                }
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(scalar, &utf8) catch
                    return self.fail(.invalid_string_escape, span, escape);
                out.appendSliceAssumeCapacity(utf8[0..n]);
                continue;
            }
            const close = std.mem.findScalarPos(u8, body, i, '}') orelse
                return self.fail(.invalid_string_escape, span, body[at..@min(body.len, at + 16)]);
            const escape = body[at .. close + 1];
            i = close + 1;
            const digits = body[at + 3 .. close];
            for (digits) |c| if (!std.ascii.isHex(c)) return self.fail(.invalid_string_escape, span, escape);
            const scalar = std.fmt.parseInt(u21, digits, 16) catch
                return self.fail(.invalid_string_escape, span, escape);
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(scalar, &utf8) catch
                return self.fail(.invalid_string_escape, span, escape);
            out.appendSliceAssumeCapacity(utf8[0..n]);
        }
        out.appendSliceAssumeCapacity(body[i..]);
        return out.items;
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

    fn formatLiteralKey(self: *Reader, f: *const Form) ReaderError![]const u8 {
        var al: std.Io.Writer.Allocating = .init(self.allocator());
        writeForm(f, &al.writer) catch return error.OutOfMemory;
        return try al.toOwnedSlice();
    }
};

// -----------------------------------------------------------------------------
// Pure helpers (no Reader state)
// -----------------------------------------------------------------------------

/// The innermost delimiter (`(`, `[`, `{`, `#{`, `#(`) the scanner's
/// tokens before `pos` leave open, which a parse error at `pos` reports
/// as the one unclosed or mismatched.
pub fn openDelimiter(allocator: std.mem.Allocator, text: []const u8, pos: u32) error{OutOfMemory}!?SrcSpan {
    var lexer = nexis.Lexer.init(text);
    var open: std.ArrayList(SrcSpan) = .empty;
    defer open.deinit(allocator);
    while (true) {
        const t = lexer.next();
        if (t.cat == .eof or t.pos >= pos) break;
        switch (t.cat) {
            .lparen, .lbracket, .lbrace, .hash_lbrace, .hash_lparen => try open.append(allocator, .{ .pos = t.pos, .len = t.len }),
            .rparen, .rbracket, .rbrace => _ = open.pop(),
            else => {},
        }
    }
    return open.pop();
}

/// The literal a `"` or `#"` at `pos` opens that no quote closes,
/// which a parse error at `pos` reports as unterminated (more input
/// may close it); null for any other text at `pos`.
pub fn unterminatedLiteral(text: []const u8, pos: u32) ?enum { string, regex } {
    var lexer = nexis.Lexer.init(text);
    lexer.base.pos = pos;
    const t = lexer.next();
    if (t.cat != .err or t.pos != pos) return null;
    const token = text[t.pos..][0..t.len];
    if (std.mem.eql(u8, token, "\"")) return .string;
    if (std.mem.eql(u8, token, "#\"")) return .regex;
    return null;
}

/// Where the first form of `text` ends, by the scanner's tokens: past
/// its last token, with the `#_` discards and `^meta` before it; null
/// when the text ends first or holds a token the scanner rejects.
/// `read-string` parses and reads just this much, so the text after
/// the first form is never scanned, as Clojure never reads it.
pub fn firstFormEnd(text: []const u8) ?u32 {
    var lexer = nexis.Lexer.init(text);
    // Forms still to come before the first one is complete: a `^`
    // takes two (the metadata and the target), a `#_` one more.
    var need: usize = 1;
    var depth: usize = 0;
    while (true) {
        const t = lexer.next();
        switch (t.cat) {
            .eof, .err => return null,
            .lparen, .lbracket, .lbrace, .hash_lbrace, .hash_lparen => {
                depth += 1;
                continue;
            },
            .rparen, .rbracket, .rbrace => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth > 0) continue;
            },
            .caret, .hash_discard => {
                if (depth == 0) need += 1;
                continue;
            },
            .quote_tok, .syntax_quote_tok, .unquote_tok, .unquote_splicing_tok, .deref_tok, .var_quote_tok => continue,
            else => if (depth > 0) continue,
        }
        need -= 1;
        if (need == 0) return lexer.base.pos;
    }
}

fn tokenSpan(r: parser.Src) SrcSpan {
    return .{ .pos = r.pos, .len = nexis.srcLen(r) };
}

/// From `pos` to the end of `last`.
fn spanTo(pos: u32, last: SrcSpan) SrcSpan {
    return .{ .pos = pos, .len = last.pos + last.len - pos };
}

/// The span of a raw form, from its first token to its last: an atom's
/// token, a compound's delimiters, a prefix token to the end of its
/// target. Only a chain of prefixes walks, one step per prefix.
fn sexpSpan(s: Sexp) SrcSpan {
    if (s == .src) return tokenSpan(s.src);
    const items = s.items();
    if (items.len < 2 or items[1] != .src) return .{ .pos = 0, .len = 0 };
    var last = s;
    while (true) {
        const it = last.items();
        if (it[it.len - 1] == .src) return spanTo(items[1].src.pos, tokenSpan(it[it.len - 1].src));
        // A prefix form's target, or with-meta-raw's (the meta is last).
        last = it[2];
    }
}

const IntLiteral = struct { negative: bool, base: u8, digits: []const u8 };

/// Split an integer literal into sign (`-` or `+`), radix and digits;
/// `null` unless every digit is valid for the radix.
fn splitIntLiteral(text: []const u8) ?IntLiteral {
    if (text.len == 0) return null;
    var t = text;
    const negative = t[0] == '-';
    if (t[0] == '-' or t[0] == '+') {
        if (t.len == 1) return null;
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
    for (t) |c| {
        const digit = std.fmt.charToDigit(c, base) catch return null;
        _ = digit;
    }
    return .{ .negative = negative, .base = base, .digits = t };
}

/// Parse an integer literal with explicit radix support into i64.
/// Returns null for malformed input or for a value outside i64;
/// `bigIntLiteral` tells the two apart.
fn parseIntLiteral(text: []const u8) ?i64 {
    const lit = splitIntLiteral(text) orelse return null;
    const negative = lit.negative;
    const mag = std.fmt.parseInt(u64, lit.digits, lit.base) catch return null;
    if (negative) {
        const neg_limit: u64 = @as(u64, @intCast(std.math.maxInt(i64))) + 1;
        if (mag > neg_limit) return null;
        if (mag == neg_limit) return std.math.minInt(i64);
        return -@as(i64, @intCast(mag));
    }
    if (mag > std.math.maxInt(i64)) return null;
    return @intCast(mag);
}

/// The scalar a char token's text after `\` names: `u{HEX}`, Clojure's
/// `uXXXX` (exactly four hex digits), one character (a valid UTF-8
/// sequence), or a name of FORMS.md §3's named set. `null` for anything
/// else, surrogates and scalars past U+10FFFF included; Clojure's octal
/// `oNNN` is not accepted.
fn parseCharLiteral(body: []const u8) ?u21 {
    if (body.len == 0) return null;
    if (body.len >= 3 and body[0] == 'u' and body[1] == '{' and body[body.len - 1] == '}') {
        const v = std.fmt.parseInt(u21, body[2 .. body.len - 1], 16) catch return null;
        return if (isScalar(v)) v else null;
    }
    if (body.len == 5 and body[0] == 'u') {
        const v = hex4(body[1..5]) orelse return null;
        return if (isScalar(v)) v else null;
    }
    const n = std.unicode.utf8ByteSequenceLength(body[0]) catch return null;
    if (n == body.len) return (string_mod.decodeAt(body, 0) catch return null).scalar;
    const names = [_]struct { []const u8, u21 }{
        .{ "newline", '\n' }, .{ "space", ' ' },     .{ "tab", '\t' },
        .{ "return", '\r' },  .{ "formfeed", 0x0C }, .{ "backspace", 0x08 },
    };
    for (names) |entry| if (std.mem.eql(u8, body, entry[0])) return entry[1];
    return null;
}

fn isScalar(v: u21) bool {
    return v <= 0x10FFFF and !(v >= 0xD800 and v <= 0xDFFF);
}

/// The value of exactly four hex digits, as Clojure's `\uXXXX` reads
/// them (no sign, no underscore).
fn hex4(digits: []const u8) ?u21 {
    if (digits.len != 4) return null;
    var v: u21 = 0;
    for (digits) |c| v = v * 16 + (std.fmt.charToDigit(c, 16) catch return null);
    return v;
}

fn splitNamespace(text: []const u8) ?Name {
    if (text.len == 0) return null;
    // `/` by itself is the division symbol (only valid unqualified name
    // that is itself a slash); `ns//` is it qualified, as syntax-quote
    // writes `nexis.core//` and Clojure reads `clojure.core//`.
    if (std.mem.eql(u8, text, "/")) {
        return Name{ .ns = null, .name = text };
    }
    if (text.len > 2 and std.mem.endsWith(u8, text, "//")) {
        const ns = text[0 .. text.len - 2];
        if (std.mem.findScalar(u8, ns, '/') != null) return null;
        return Name{ .ns = ns, .name = "/" };
    }
    const first = std.mem.findScalar(u8, text, '/') orelse {
        return Name{ .ns = null, .name = text };
    };
    const last = std.mem.findScalarLast(u8, text, '/').?;
    // At most one `/` separator is permitted; multi-slash names like
    // `foo/bar/baz` are rejected here and surface as :invalid-symbol /
    // :invalid-keyword.
    if (first != last) return null;
    if (first == 0 or first == text.len - 1) return null;
    return Name{ .ns = text[0..first], .name = text[first + 1 ..] };
}

/// A Form is a "literal key" eligible for static duplicate detection iff it
/// is an atom (nil/bool/int/real/char/string/keyword/symbol) AND its value
/// is compile-time known. Every atom is treated as literal.
pub fn isLiteralKey(f: *const Form) bool {
    return switch (f.datum) {
        .nil, .bool_, .int, .bigint, .real, .char, .string, .keyword, .symbol => true,
        else => false,
    };
}

/// Literal forms (`isLiteralKey`) under the reader's literal equality
/// (`formLiteralEq`).
pub const LiteralSet = std.HashMapUnmanaged(*const Form, void, struct {
    pub fn hash(_: @This(), f: *const Form) u64 {
        var h = std.hash.Wyhash.init(@backingInt(f.datum));
        switch (f.datum) {
            .nil => {},
            .bool_ => |b| h.update(&.{@intFromBool(b)}),
            .int => |v| h.update(std.mem.asBytes(&v)),
            .bigint, .string => |t| h.update(t),
            // 0.0 and -0.0 are equal under `==`, so they hash alike.
            .real => |r| h.update(std.mem.asBytes(&(if (r == 0) @as(f64, 0) else if (std.math.isNan(r)) std.math.nan(f64) else r))),
            .char => |c| h.update(std.mem.asBytes(&@as(u32, c))),
            .keyword, .symbol => |n| {
                h.update(n.ns orelse "");
                h.update("/");
                h.update(n.name);
            },
            else => unreachable,
        }
        return h.final();
    }
    pub fn eql(_: @This(), a: *const Form, b: *const Form) bool {
        return formLiteralEq(a, b);
    }
}, std.hash_map.default_max_load_percentage);

/// Whether the atoms `a` and `b` are the same literal; false for
/// anything else.
pub fn formLiteralEq(a: *const Form, b: *const Form) bool {
    return switch (a.datum) {
        .nil => b.datum == .nil,
        .bool_ => |ab| b.datum == .bool_ and b.datum.bool_ == ab,
        .int => |ai| b.datum == .int and b.datum.int == ai,
        .bigint => |at| b.datum == .bigint and std.mem.eql(u8, at, b.datum.bigint),
        .real => |ar| b.datum == .real and (b.datum.real == ar or (std.math.isNan(ar) and std.math.isNan(b.datum.real))), // `=` makes NaN equal NaN
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
        .bigint => |t| try w.print("(bigint {s})", .{t}),
        .real => |r| try writeReal(r, w),
        .char => |c| try writeCharAtom(c, w),
        .string => |s| try writeStringAtom("string", s, w),
        .regex => |s| try writeStringAtom("regex", s, w),
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
    // onto indented new lines otherwise. There is no width-aware
    // wrapping (FORMS.md §5).
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

fn writeStringAtom(tag: []const u8, s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("({s} \"", .{tag});
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

test "number token boundary: a digit-led run is one token the reader rejects" {
    const allocator = std.testing.allocator;
    // Each source holds one malformed number; the error spans exactly
    // that token and carries its text (FORMS.md §3, "Number token
    // boundary").
    const cases = [_]struct { src: []const u8, pos: u32, text: []const u8 }{
        .{ .src = "1abc", .pos = 0, .text = "1abc" },
        .{ .src = "(println 1-2)", .pos = 9, .text = "1-2" },
        .{ .src = "[1.5x]", .pos = 1, .text = "1.5x" },
        .{ .src = "-1abc", .pos = 0, .text = "-1abc" },
        .{ .src = "1/2", .pos = 0, .text = "1/2" },
        .{ .src = "0x", .pos = 0, .text = "0x" },
        .{ .src = "0b12", .pos = 0, .text = "0b12" },
        .{ .src = "1.", .pos = 0, .text = "1." },
        .{ .src = "1e", .pos = 0, .text = "1e" },
        .{ .src = "1:a", .pos = 0, .text = "1:a" },
        .{ .src = "1'", .pos = 0, .text = "1'" },
        .{ .src = "3.14M", .pos = 0, .text = "3.14M" },
        .{ .src = "1.5N", .pos = 0, .text = "1.5N" },
        .{ .src = "1_000", .pos = 0, .text = "1_000" },
        .{ .src = "1.0_5", .pos = 0, .text = "1.0_5" },
        .{ .src = "1e1_0", .pos = 0, .text = "1e1_0" },
        .{ .src = "+1x", .pos = 0, .text = "+1x" },
    };
    for (cases) |c| {
        var p = parser.Parser.init(allocator, c.src);
        defer p.deinit();
        const tree = try p.parseProgram();
        var rd = Reader.init(allocator, c.src);
        defer rd.deinit();
        try std.testing.expectError(error.ReaderFailure, rd.readProgram(tree));
        const e = rd.err orelse return error.TestUnexpectedResult;
        try std.testing.expect(e.kind == .bad_number_literal);
        try std.testing.expectEqualStrings(c.text, e.detail.?);
        try std.testing.expectEqual(c.pos, e.span.pos);
        try std.testing.expectEqual(@as(u32, @intCast(c.text.len)), e.span.len);
    }

    // A reader macro character or a delimiter ends the number, as it
    // would end a symbol: `1@x` is `1` then `(deref x)`.
    const two = "(1@x)";
    var p = parser.Parser.init(allocator, two);
    defer p.deinit();
    var rd = Reader.init(allocator, two);
    defer rd.deinit();
    const forms = try rd.readProgram(try p.parseProgram());
    try std.testing.expectEqual(@as(usize, 1), forms.len);
    const items = forms[0].datum.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].datum.int);
    try std.testing.expect(items[1].datum == .deref);
}

test "signed numbers and digit-led keywords read as in Clojure" {
    try expectReads("[+5 +0x10 -0x10 +1.5 +9223372036854775808 :1 :2a + +a]",
        \\(vector (int 5) (int 16) (int -16) (real 1.5) (bigint 9223372036854775808) (keyword :1) (keyword :2a) (symbol +) (symbol +a))
        \\
    );
}

test "metadata: a string is a :tag, a vector :param-tags" {
    try expectReads("^\"String\" x ^[long] f",
        \\(with-meta
        \\  (symbol x)
        \\  (map (keyword :tag) (string "String")))
        \\(with-meta
        \\  (symbol f)
        \\  (map
        \\    (keyword :param-tags)
        \\    (vector (symbol long))))
        \\
    );
}

test "parsing is linear: a list of n forms costs O(n) parser memory" {
    const allocator = std.testing.allocator;
    inline for (.{ "[", "" }, .{ "]", "" }) |open, close| {
        var reserved: [2]usize = undefined;
        for (&reserved, [_]usize{ 4000, 16000 }) |*bytes, n| {
            var src: std.ArrayList(u8) = .empty;
            defer src.deinit(allocator);
            try src.appendSlice(allocator, open);
            for (0..n) |i| try src.print(allocator, "{d} ", .{i});
            try src.appendSlice(allocator, close);
            var p = parser.Parser.init(allocator, src.items);
            defer p.deinit();
            _ = try p.parseProgram();
            bytes.* = p.arena.queryCapacity();
        }
        // Linear: four times the forms take under eight times the
        // memory the parser reserves. A list that copied itself on every
        // append would hold n²/2 Sexps and take sixteen times.
        try std.testing.expect(reserved[1] < 8 * reserved[0]);
    }
}

test "a token longer than 64 KiB reads whole" {
    const allocator = std.testing.allocator;
    const n = 70_000;
    const body = try allocator.alloc(u8, n);
    defer allocator.free(body);
    @memset(body, 'a');
    const shapes = [_][]const u8{ "(\"{s}\")", "(x{s} 1)", "(:k{s} 1)", "(1{s} 1)" };
    inline for (shapes, 0..) |shape, i| {
        const src = try allocator.print(shape, .{body});
        defer allocator.free(src);
        var p = parser.Parser.init(allocator, src);
        defer p.deinit();
        var rd = Reader.init(allocator, src);
        defer rd.deinit();
        const result = rd.readProgram(try p.parseProgram());
        if (i == 3) {
            // The number token runs to the delimiter and is rejected whole.
            try std.testing.expectError(error.ReaderFailure, result);
            try std.testing.expectEqual(@as(u32, n + 1), rd.err.?.span.len);
            continue;
        }
        const items = (try result)[0].datum.list;
        const first = items[0];
        try std.testing.expectEqual(@as(u32, @intCast(src.len - 2 - (if (i == 0) 0 else 2))), first.origin.len);
        switch (i) {
            0 => try std.testing.expectEqual(@as(usize, n), first.datum.string.len),
            1 => try std.testing.expectEqual(@as(usize, n + 1), first.datum.symbol.name.len),
            2 => try std.testing.expectEqual(@as(usize, n + 1), first.datum.keyword.name.len),
            else => unreachable,
        }
        try std.testing.expectEqual(@as(u32, @intCast(src.len)), (try result)[0].origin.len);
    }
}

test "N suffix: an integer literal of any radix or size reads as the integer" {
    try expectReads("1N -7N 0xFFN 0b101N 18446744073709551616N", "(int 1)\n(int -7)\n(int 255)\n(int 5)\n(bigint 18446744073709551616)\n");
}

test "bigint literals: beyond i64 in any radix, as canonical decimal text" {
    const cases = [_]struct { src: []const u8, decimal: []const u8 }{
        .{ .src = "9223372036854775808", .decimal = "9223372036854775808" },
        .{ .src = "-9223372036854775809", .decimal = "-9223372036854775809" },
        .{ .src = "0x10000000000000000", .decimal = "18446744073709551616" },
        .{ .src = "-0X10000000000000000", .decimal = "-18446744073709551616" },
        .{ .src = "0b10000000000000000000000000000000000000000000000000000000000000000", .decimal = "18446744073709551616" },
        .{ .src = "000123456789012345678901234567890", .decimal = "123456789012345678901234567890" },
    };
    for (cases) |c| {
        var rdr = Reader.init(std.testing.allocator, c.src);
        defer rdr.deinit();
        try std.testing.expectEqualStrings(c.decimal, rdr.bigIntLiteral(c.src).?);
    }
    var rdr = Reader.init(std.testing.allocator, "");
    defer rdr.deinit();
    try std.testing.expect(rdr.bigIntLiteral("12345678901234567890x") == null);
    try std.testing.expect(rdr.bigIntLiteral("0x") == null);
    try std.testing.expect(rdr.bigIntLiteral("-") == null);
}

test "integer radix normalization" {
    try std.testing.expectEqual(@as(i64, 42), parseIntLiteral("42").?);
    try std.testing.expectEqual(@as(i64, -1), parseIntLiteral("-1").?);
    try std.testing.expectEqual(@as(i64, 42), parseIntLiteral("0x2A").?);
    try std.testing.expectEqual(@as(i64, 5), parseIntLiteral("0b101").?);
    try std.testing.expectEqual(@as(i64, -255), parseIntLiteral("-0xFF").?);
    // Boundary: i64.min/max are representable.
    try std.testing.expectEqual(std.math.minInt(i64), parseIntLiteral("-9223372036854775808").?);
    try std.testing.expectEqual(std.math.maxInt(i64), parseIntLiteral("9223372036854775807").?);
    // Out-of-range is rejected.
    try std.testing.expect(parseIntLiteral("9223372036854775808") == null);
    try std.testing.expect(parseIntLiteral("-9223372036854775809") == null);
    try std.testing.expect(parseIntLiteral("1_000") == null);
    // Malformed.
    try std.testing.expect(parseIntLiteral("") == null);
    try std.testing.expect(parseIntLiteral("-") == null);
    try std.testing.expect(parseIntLiteral("0xG") == null);
}

test "nil / true / false only match unqualified symbols" {
    try expectReads("nil true false foo/nil foo/true :nil :true", "nil\n(bool true)\n(bool false)\n(symbol foo/nil)\n(symbol foo/true)\n(keyword :nil)\n(keyword :true)\n");
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

    // The division symbol qualified, as syntax-quote prints it.
    const d = splitNamespace("nexis.core//").?;
    try std.testing.expectEqualStrings("nexis.core", d.ns.?);
    try std.testing.expectEqualStrings("/", d.name);
    try std.testing.expect(splitNamespace("a/b//") == null);
    try std.testing.expect(splitNamespace("//") == null);
}

test "char literal parsing" {
    try std.testing.expectEqual(@as(u21, 'a'), parseCharLiteral("a").?);
    try std.testing.expectEqual(@as(u21, '\n'), parseCharLiteral("newline").?);
    try std.testing.expectEqual(@as(u21, 0x2603), parseCharLiteral("u{2603}").?);
    try std.testing.expectEqual(@as(u21, 0x2603), parseCharLiteral("u2603").?);
    try std.testing.expectEqual(@as(u21, 'A'), parseCharLiteral("u0041").?);
    try std.testing.expect(parseCharLiteral("uD800") == null);
    try std.testing.expect(parseCharLiteral("u041") == null);
    try std.testing.expect(parseCharLiteral("u00411") == null);
    try std.testing.expect(parseCharLiteral("") == null);
    try std.testing.expect(parseCharLiteral("u{}") == null);
}

/// `src` fails to read with `kind`, its detail `detail`.
fn expectReaderError(src: []const u8, kind: ErrorKind, detail: ?[]const u8) !void {
    const allocator = std.testing.allocator;
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    try std.testing.expectError(error.ReaderFailure, rd.readProgram(try p.parseProgram()));
    try std.testing.expectEqual(kind, rd.err.?.kind);
    if (detail) |d| try std.testing.expectEqualStrings(d, rd.err.?.detail.?);
}

test "strings: may span lines, must be UTF-8, fail at their bad escape" {
    try expectReads("\"Line one.\n  Line two.\"", "(string \"Line one.\\n  Line two.\")\n");
    try expectReads("\"é\\u{2603}\"", "(string \"\\u{C3}\\u{A9}\\u{E2}\\u{98}\\u{83}\")\n");
    try expectReaderError("\"a\xffb\"", .invalid_utf8, null);
    try expectReaderError("\"\xc3\"", .invalid_utf8, null);
    // The detail is the escape that fails, not the whole string.
    try expectReaderError("\"abc \\q def\"", .invalid_string_escape, "\\q");
    try expectReaderError("\"abc \\u{110000} def\"", .invalid_string_escape, "\\u{110000}");
    try expectReaderError("\"abc \\u{D800}\"", .invalid_string_escape, "\\u{D800}");
    // Clojure's `\uXXXX`: exactly four hex digits; a UTF-16 surrogate
    // pair spells one scalar, a lone surrogate is an error.
    try expectReads("\"\\u0041\\u00e9!\"", "(string \"A\\u{C3}\\u{A9}!\")\n");
    try expectReads("\"\\uD83D\\uDE00\"", "(string \"\\u{F0}\\u{9F}\\u{98}\\u{80}\")\n");
    try expectReaderError("\"abc \\u41\"", .invalid_string_escape, "\\u41");
    try expectReaderError("\"abc \\u004g\"", .invalid_string_escape, "\\u004g");
    try expectReaderError("\"\\uD800\"", .invalid_string_escape, "\\uD800");
    try expectReaderError("\"\\uDE00\\uD83D\"", .invalid_string_escape, "\\uDE00");
    try expectReaderError("\"\\uD83Dx\"", .invalid_string_escape, "\\uD83D");
    // `\b`, `\f` and Clojure's octal escapes, at most `\377`; a
    // `\u{...}` body is hex digits alone.
    try expectReads("\"\\b\\f\\101\\0\\12x\"", "(string \"\\u{8}\\u{C}A\\u{0}\\nx\")\n");
    try expectReads("\"\\1234\"", "(string \"S4\")\n");
    try expectReaderError("\"\\400\"", .invalid_string_escape, "\\400");
    try expectReaderError("\"\\u{+41}\"", .invalid_string_escape, "\\u{+41}");
    try expectReaderError("\"\\u{4_1}\"", .invalid_string_escape, "\\u{4_1}");
    // An unterminated string is a parse error at its opening quote.
    const allocator = std.testing.allocator;
    const src = "(println \"never closed\n(+ 1 2)";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    try std.testing.expectError(error.ParseError, p.parseProgram());
    try std.testing.expectEqual(parser.Span{ .start = 9, .end = 10 }, p.lastError().?.span);
}

test "char literals: one token to the next delimiter, judged whole" {
    try expectReads("[\\u{41} \\newline \\a \\é \\☃ \\( \\\\ \\u \\o]", "(vector (char \\A) (char \\newline) (char \\a) (char \\u{E9}) (char \\u{2603}) (char \\() (char \\\\) (char \\u) (char \\o))\n");
    try expectReads("[\\u0041 \\u2603]", "(vector (char \\A) (char \\u{2603}))\n");
    // A delimiter or reader macro character ends the token.
    try expectReads("(\\a)[\\b@c]", "(list (char \\a))\n(vector\n  (char \\b)\n  (deref (symbol c)))\n");
    // `\u` without exactly four hex digits, Clojure's `\oNNN`, a
    // letter or digit run after a char, a surrogate and a scalar past
    // U+10FFFF are errors over the whole token, never a char followed
    // by more forms.
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "\\u041", "\\u00411", "\\uD800", "\\o101", "\\a1", "\\ab", "\\é1", "\\u{D800}", "\\u{110000}", "\\u{41}x" }) |src| {
        var p = parser.Parser.init(allocator, src);
        defer p.deinit();
        var rd = Reader.init(allocator, src);
        defer rd.deinit();
        try std.testing.expectError(error.ReaderFailure, rd.readProgram(try p.parseProgram()));
        try std.testing.expect(rd.err.?.kind == .invalid_char_literal);
        try std.testing.expectEqualStrings(src, rd.err.?.detail.?);
        try std.testing.expectEqual(@as(u32, @intCast(src.len)), rd.err.?.span.len);
    }
}

test "discard applies uniformly across aggregator contexts" {
    // Discard consumes its next form including any reader sugar
    // attached to it (metadata, deref, quote, anon-fn): the prefixed
    // form is one form.
    try expectReads("#_ ^:m x y #_ @a b #_ '(+ 1 2) keep #_ #(+ % 1) z [#_ x y] #{#_ x :a}",
        \\(symbol y)
        \\(symbol b)
        \\(symbol keep)
        \\(symbol z)
        \\(vector (symbol y))
        \\(set (keyword :a))
        \\
    );
}

test "discard inside a map affects key/value arity" {
    // `{:a 1 #_ :b 2}` drops `:b`, leaving three forms: the arity check
    // after the discard reports it, never silently.
    try expectReaderError("{:a 1 #_ :b 2}", .map_odd_count, null);
}

test "stacked discard drops siblings in source order" {
    // Each `#_` consumes one form, and the form it consumes may itself
    // begin with `#_`, as in Clojure's reader.
    try expectReads("#_ x y", "(symbol y)\n");
    try expectReads("#_ #_ x y z", "(symbol z)\n");
    try expectReads("#_ #_ #_ a b c d", "(symbol d)\n");
    try expectReads("[#_ #_ x y z] (+ #_ #_ x y 3 4)", "(vector (symbol z))\n(list (symbol +) (int 3) (int 4))\n");
}

/// `src` read as a program, each form printed as the goldens print it.
fn expectReads(src: []const u8, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    const forms = try rd.readProgram(try p.parseProgram());
    var al: std.Io.Writer.Allocating = .init(allocator);
    defer al.deinit();
    for (forms) |f| {
        try writeForm(f, &al.writer);
        try al.writer.writeByte('\n');
    }
    try std.testing.expectEqualStrings(expected, al.written());
}

test "a UTF-8 byte-order mark is skipped at the start of the source only" {
    try expectReads("\xEF\xBB\xBF(a)", "(list (symbol a))\n");
    try expectReads("\xEF\xBB\xBF", "");
    // Anywhere else it is a symbol constituent, as in Clojure.
    try expectReads("a\xEF\xBB\xBF", "(symbol a\xEF\xBB\xBF)\n");
}

test "discard: #_ drops the next form wherever a form may stand" {
    // A prefix reads the form after the discarded one, as Clojure's
    // reader does.
    try expectReads("'#_ x y", "(quote (symbol y))\n");
    try expectReads("@#_ #_ x y z", "(deref (symbol z))\n");
    try expectReads("^:m #_ x y", "(with-meta\n  (symbol y)\n  (map (keyword :m) (bool true)))\n");
    try expectReads("^#_ x :m y", "(with-meta\n  (symbol y)\n  (map (keyword :m) (bool true)))\n");
    try expectReads("(a #_ b) #_ c", "(list (symbol a))\n");
    try expectReads("#_ x", "");
    // A discard with no form to discard is a parse error.
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "(+ #_ #_ 1)", "#_", "'#_ x", "[#_]" }) |src| {
        var p = parser.Parser.init(allocator, src);
        defer p.deinit();
        try std.testing.expectError(error.ParseError, p.parseProgram());
    }
    // One form, with discards on either side of it.
    for ([_][]const u8{ "x #_ y", "#_ y x", "#_ #_ a b x #_ c" }) |src| {
        var p = parser.Parser.init(allocator, src);
        defer p.deinit();
        var rd = Reader.init(allocator, src);
        defer rd.deinit();
        const f = try rd.readOneForm(try p.parseForm());
        try std.testing.expectEqualStrings("x", f.datum.symbol.name);
    }
}

test "firstFormEnd: the first form's tokens, discards and metadata included, and no further" {
    const cases = [_]struct { text: []const u8, end: ?usize }{
        .{ .text = "1 2", .end = 1 },
        .{ .text = "  (a [b] {c d}) )))", .end = 15 },
        .{ .text = "#_ x y z", .end = 6 },
        .{ .text = "^:k ^{:a 1} [1] tail", .end = 15 },
        .{ .text = "'#_a b c", .end = 6 },
        .{ .text = "@x #(", .end = 2 },
        .{ .text = "\\u{110000} x", .end = 10 },
        .{ .text = "\"a b\" c", .end = 5 },
        .{ .text = "{:a 1 :a 2} unreadable \"", .end = 11 },
        .{ .text = "", .end = null },
        .{ .text = "; only a comment", .end = null },
        .{ .text = "(a b", .end = null },
        .{ .text = ") x", .end = null },
        .{ .text = "#_ #_ a", .end = null },
        .{ .text = "\"open", .end = null },
    };
    for (cases) |c| {
        const end = firstFormEnd(c.text);
        if (c.end) |e| {
            try std.testing.expectEqual(@as(?u32, @intCast(e)), end);
        } else try std.testing.expectEqual(@as(?u32, null), end);
    }
}

test "nesting past the stack budget is a reader error, not a fault" {
    const allocator = std.testing.allocator;
    stack.armIfUnarmed(stack.main_thread_budget);
    const depth = 200_000;
    inline for (.{ "(", "[", "'", "@", "^(" }, .{ ")", "]", "", "", ") y" }) |open, close| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(allocator);
        for (0..depth) |_| try src.appendSlice(allocator, open);
        try src.append(allocator, 'x');
        for (0..depth) |_| try src.appendSlice(allocator, close);
        var p = parser.Parser.init(allocator, src.items);
        defer p.deinit();
        var rd = Reader.init(allocator, src.items);
        defer rd.deinit();
        try std.testing.expectError(error.ReaderFailure, rd.readProgram(try p.parseProgram()));
        try std.testing.expect(rd.err.?.kind == .nesting_too_deep);
    }
}

test "spans: a form covers its first token to its last" {
    const allocator = std.testing.allocator;
    const src = " ( a [b] '#_ x @c ^:m #_ q {d 1} #(e) `~f ) ";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    const forms = try rd.readProgram(try p.parseProgram());
    const text = struct {
        fn of(f: *const Form) []const u8 {
            return src[f.origin.pos..][0..f.origin.len];
        }
    }.of;
    try std.testing.expectEqualStrings("( a [b] '#_ x @c ^:m #_ q {d 1} #(e) `~f )", text(forms[0]));
    const items = forms[0].datum.list;
    const expected = [_][]const u8{ "a", "[b]", "'#_ x @c", "^:m #_ q {d 1}", "#(e)", "`~f" };
    try std.testing.expectEqual(expected.len, items.len);
    for (expected, items) |e, f| try std.testing.expectEqualStrings(e, text(f));
    try std.testing.expectEqualStrings("@c", text(items[2].datum.quote));
    try std.testing.expectEqualStrings("{d 1}", text(items[3].datum.with_meta.target));
    try std.testing.expectEqualStrings("~f", text(items[5].datum.syntax_quote));
}

test "stacked metadata: an outer ^ overrides an inner one, key order by last occurrence" {
    try expectReads("^{:x 1 :z 0} ^{:x 2 :y 3} v", "(with-meta\n  (symbol v)\n  (map (keyword :y) (int 3) (keyword :x) (int 1) (keyword :z) (int 0)))\n");
    try expectReads("^:a ^{[1] 1} ^{[1] 2} ^:a v", "(with-meta\n  (symbol v)\n  (map\n    (vector (int 1))\n    (int 2)\n    (vector (int 1))\n    (int 1)\n    (keyword :a)\n    (bool true)))\n");
}

test "duplicate literal detection is linear in the literal's size" {
    const allocator = std.testing.allocator;
    const n = 40_000;
    // A set, a map and a metadata chain of n distinct literals, each
    // with one duplicate at the end that must be found.
    inline for (.{ "#{", "{", "" }, .{ "}", "}", "v" }, .{ "", " 0", "" }, .{ "", "", "^" }) |open, close, value, prefix| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(allocator);
        try src.appendSlice(allocator, open);
        for (0..n) |i| try src.print(allocator, prefix ++ ":k{d}" ++ value ++ " ", .{i});
        try src.appendSlice(allocator, prefix ++ ":k7" ++ value ++ " " ++ close);
        var p = parser.Parser.init(allocator, src.items);
        defer p.deinit();
        var rd = Reader.init(allocator, src.items);
        defer rd.deinit();
        const result = rd.readProgram(try p.parseProgram());
        if (prefix.len > 0) {
            // Metadata merges its duplicates instead of rejecting them.
            try std.testing.expectEqual(@as(usize, 2 * n), (try result)[0].datum.with_meta.meta.datum.map.len);
        } else {
            try std.testing.expectError(error.ReaderFailure, result);
            try std.testing.expectEqualStrings("(keyword :k7)", rd.err.?.detail.?);
        }
    }
}

test "var-quote: #'x reads as the list (var x), whatever form follows" {
    // Clojure's VarReader reads the next form, so whitespace and a
    // discard may stand between, and a non-symbol target reads (the
    // compiler rejects it).
    try expectReads("#'x", "(list (symbol var) (symbol x))\n");
    try expectReads("#'foo/bar", "(list (symbol var) (symbol foo/bar))\n");
    try expectReads("#' x", "(list (symbol var) (symbol x))\n");
    try expectReads("#'#_ x y", "(list (symbol var) (symbol y))\n");
    try expectReads("#'(f)", "(list\n  (symbol var)\n  (list (symbol f)))\n");
    try expectReads("'#'x", "(quote\n  (list (symbol var) (symbol x)))\n");
    try expectReads("(f #'x)", "(list\n  (symbol f)\n  (list (symbol var) (symbol x)))\n");
    // The list spans `#'` through its target; `var` spans `#'`.
    const allocator = std.testing.allocator;
    const src: []const u8 = "( #' #_ q x )";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    var rd = Reader.init(allocator, src);
    defer rd.deinit();
    const forms = try rd.readProgram(try p.parseProgram());
    const vq = forms[0].datum.list[0];
    try std.testing.expectEqualStrings("#' #_ q x", src[vq.origin.pos..][0..vq.origin.len]);
    const head = vq.datum.list[0];
    try std.testing.expectEqualStrings("#'", src[head.origin.pos..][0..head.origin.len]);
    // `#'` with no form after it is a parse error.
    for ([_][]const u8{ "#'", "(#')", "#' #_ x" }) |bad| {
        var bp = parser.Parser.init(allocator, bad);
        defer bp.deinit();
        try std.testing.expectError(error.ParseError, bp.parseProgram());
    }
}

test "##Inf, ##-Inf and ##NaN are the symbolic floats" {
    try expectReads("[##Inf ##-Inf ##NaN]", "(vector (real +inf) (real -inf) (real +nan))\n");
    try expectReads("(f ##-Inf)", "(list (symbol f) (real -inf))\n");
    // `=` makes NaN equal NaN, so a literal holds it once.
    try expectReaderError("#{##NaN ##NaN}", .duplicate_literal_element, "(real +nan)");
    try expectReaderError("{##Inf 1 ##Inf 2}", .duplicate_literal_key, "(real +inf)");
}

test "an unsupported construct is one err token, so the parse error names it" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "#\"a.*", "#\"" },      .{ "##Infinity", "##Infinity" },
        .{ "::k", "::k" },         .{ "#?(:clj 1)", "#?" },
        .{ "# x", "#" },           .{ "##inf", "##inf" },
        .{ "(##NaN1)", "##NaN1" },
    };
    for (cases) |c| {
        var p = parser.Parser.init(allocator, c[0]);
        defer p.deinit();
        try std.testing.expectError(error.ParseError, p.parseProgram());
        const span = p.lastError().?.span;
        try std.testing.expectEqualStrings(c[1], c[0][span.start..span.end]);
    }
}

test "a regex literal keeps its text as written and must compile" {
    try expectReads("#\"a\\d+\" #\"\\\"\" #\"é\"", "(regex \"a\\\\d+\")\n(regex \"\\\\\\\"\")\n(regex \"\\u{C3}\\u{A9}\")\n");
    try expectReaderError("#\"(\"", .invalid_regex, "Unclosed group at index 1");
    try expectReaderError("#\"é{2,1}\"", .invalid_regex, "Illegal repetition range at index 5");
    try expectReaderError("#\"(?=a)\"", .invalid_regex, "lookahead and lookbehind are not supported at index 0");
    try expectReaderError("#\"a\xff\"", .invalid_utf8, null);
}

test "a Clojure literal nexis does not read is reported with what to write instead" {
    const a = std.testing.allocator;
    const ratio = (try numberLiteralHint(a, "-1/3")).?;
    defer a.free(ratio);
    try std.testing.expectEqualStrings("nexis has no ratios: (/ -1 3) divides, to a double when inexact", ratio);
    const decimal = (try numberLiteralHint(a, "1.5M")).?;
    defer a.free(decimal);
    try std.testing.expectEqualStrings("nexis has no BigDecimal: 1.5 is a double", decimal);
    for ([_][]const u8{ "1abc", "1/", "/2", "1/2/3", "1.5x", "M", "1.5N" }) |text| try std.testing.expect((try numberLiteralHint(a, text)) == null);
    try std.testing.expectEqualStrings("nexis has no #uuid literal: a UUID is its canonical string", taggedLiteralHint("#uuid").?);
    try std.testing.expectEqualStrings("nexis reads no tagged literals", taggedLiteralHint("#js").?);
    for ([_][]const u8{ "#", "#(", "#{", "#_", ")", "inst" }) |token| try std.testing.expect(taggedLiteralHint(token) == null);
}

test "symbols and keywords take any UTF-8 character" {
    try expectReads("(λ ns.é/π :ключ :a/ß)", "(list (symbol λ) (symbol ns.é/π) (keyword :ключ) (keyword :a/ß))\n");
    try expectReaderError("1é", .bad_number_literal, "1é");
    try expectReaderError("(a\xff)", .invalid_utf8, null);
    try expectReaderError(":k\xc3", .invalid_utf8, null);
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
