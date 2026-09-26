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
//! `readForm` calls `stack.check` on entry, so input nested past the stack's
//! budget is `:nesting-too-deep`, and each Form's span comes from its
//! tokens in O(1). An integer literal beyond i64, in any radix, is a
//! `bigint` carrying canonical decimal text, so the compiler lifts it into
//! a bignum without re-reading the radix.

const std = @import("std");
/// The generated parser, for the callers that parse before reading.
pub const parser = @import("parser.zig");
const nexis = @import("nexis.zig");
const stack = @import("stack.zig");

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
        if (!tree.isKind(.program)) return self.fail(.unknown_reader_construct, sexpSpan(tree), null);
        return try self.readFormsList(tree.items()[1..]);
    }

    /// Normalize a single `form` sexp into one `*Form`.
    pub fn readOneForm(self: *Reader, tree: Sexp) ReaderError!*Form {
        return try self.readForm(tree);
    }

    // -------------------------------------------------------------------------
    // Core dispatch
    // -------------------------------------------------------------------------

    /// Every list the grammar builds is a tag followed by its tokens and
    /// forms: an atom holds its one token, a compound its children
    /// between its delimiter tokens, a prefix form its token and its
    /// target (`nexis.grammar`).
    fn readForm(self: *Reader, s: Sexp) ReaderError!*Form {
        stack.check() catch return self.fail(.nesting_too_deep, sexpSpan(s), null);
        const items = s.items();
        if (items.len < 2 or items[0] != .tag or items[1] != .src)
            return self.fail(.unknown_reader_construct, sexpSpan(s), null);
        const tag: Tag = items[0].tag;
        switch (tag) {
            .int, .real, .string, .char, .keyword, .symbol => {
                const span = tokenSpan(items[1].src);
                const text = self.source[span.pos..][0..span.len];
                return switch (tag) {
                    .int => self.readInt(text, span),
                    .real => self.readReal(text, span),
                    .string => self.readString(text, span),
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
        for (items, out) |item, *f| f.* = try self.readForm(item);
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
        const value = std.fmt.parseFloat(f64, text) catch
            return self.fail(.bad_number_literal, span, text);
        return try self.makeForm(.{ .real = value }, span);
    }

    fn readString(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const raw = text;
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
            return self.fail(.invalid_string_escape, span, raw);
        }
        const body = raw[1 .. raw.len - 1];
        const decoded = try self.decodeStringEscapes(body, span);
        return try self.makeForm(.{ .string = decoded }, span);
    }

    fn readChar(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const raw = text;
        if (raw.len < 2 or raw[0] != '\\') {
            return self.fail(.invalid_char_literal, span, raw);
        }
        const body = raw[1..];
        const scalar = parseCharLiteral(body) orelse
            return self.fail(.invalid_char_literal, span, raw);
        return try self.makeForm(.{ .char = scalar }, span);
    }

    fn readKeyword(self: *Reader, text: []const u8, span: SrcSpan) ReaderError!*Form {
        const raw = text;
        if (raw.len < 2 or raw[0] != ':') {
            return self.fail(.invalid_keyword, span, raw);
        }
        if (!std.unicode.utf8ValidateSlice(raw)) return self.fail(.invalid_utf8, span, null);
        const body = raw[1..];
        const name = splitNamespace(body) orelse
            return self.fail(.invalid_keyword, span, raw);
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
        const inner = try self.readForm(items[2]);
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
        const inner = try self.readForm(items[2]);
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
        const target = try self.readForm(current);
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
            const m = try self.readForm(raw_metas[i]);
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

    /// A string body with its escapes decoded (FORMS.md §3). The bytes
    /// must be UTF-8; an escape that fails is the error's detail.
    fn decodeStringEscapes(self: *Reader, body: []const u8, span: SrcSpan) ReaderError![]const u8 {
        if (!std.unicode.utf8ValidateSlice(body)) return self.fail(.invalid_utf8, span, null);
        // Every escape is at least as long as the bytes it stands for.
        var out = try std.ArrayList(u8).initCapacity(self.allocator(), body.len);
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, body, i, '\\')) |at| {
            out.appendSliceAssumeCapacity(body[i..at]);
            i = @min(at + 2, body.len);
            const simple: ?u8 = if (at + 1 == body.len) null else switch (body[at + 1]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '"' => '"',
                else => null,
            };
            if (simple) |b| {
                out.appendAssumeCapacity(b);
                continue;
            }
            if (body[i - 1] != 'u' or i == body.len or body[i] != '{')
                return self.fail(.invalid_string_escape, span, body[at..i]);
            const close = std.mem.indexOfScalarPos(u8, body, i, '}') orelse
                return self.fail(.invalid_string_escape, span, body[at..@min(body.len, at + 16)]);
            const escape = body[at .. close + 1];
            i = close + 1;
            const scalar = std.fmt.parseInt(u21, body[at + 3 .. close], 16) catch
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

/// Split an integer literal into sign, radix and digits; `null` unless
/// every digit is valid for the radix.
fn splitIntLiteral(text: []const u8) ?IntLiteral {
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

/// The scalar a char token's text after `\` names: `u{HEX}`, one
/// character (a valid UTF-8 sequence), or a name of FORMS.md §3's named
/// set. `null` for anything else, surrogates and scalars past U+10FFFF
/// included. Clojure's `uXXXX` and `oNNN` spellings are not accepted:
/// `\u{HEX}` is the one escape (PLAN §23 decision 26).
fn parseCharLiteral(body: []const u8) ?u21 {
    if (body.len == 0) return null;
    if (body.len >= 3 and body[0] == 'u' and body[1] == '{' and body[body.len - 1] == '}') {
        const v = std.fmt.parseInt(u21, body[2 .. body.len - 1], 16) catch return null;
        if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return null;
        return v;
    }
    const n = std.unicode.utf8ByteSequenceLength(body[0]) catch return null;
    if (n == body.len) return std.unicode.utf8Decode(body) catch null;
    const names = [_]struct { []const u8, u21 }{
        .{ "newline", '\n' }, .{ "space", ' ' },     .{ "tab", '\t' },
        .{ "return", '\r' },  .{ "formfeed", 0x0C }, .{ "backspace", 0x08 },
    };
    for (names) |entry| if (std.mem.eql(u8, body, entry[0])) return entry[1];
    return null;
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
/// is compile-time known. Every atom is treated as literal.
fn isLiteralKey(f: *const Form) bool {
    return switch (f.datum) {
        .nil, .bool_, .int, .bigint, .real, .char, .string, .keyword, .symbol => true,
        else => false,
    };
}

/// Literal forms under the reader's literal equality (`formLiteralEq`).
const LiteralSet = std.HashMapUnmanaged(*const Form, void, struct {
    pub fn hash(_: @This(), f: *const Form) u64 {
        var h = std.hash.Wyhash.init(@intFromEnum(f.datum));
        switch (f.datum) {
            .nil => {},
            .bool_ => |b| h.update(&.{@intFromBool(b)}),
            .int => |v| h.update(std.mem.asBytes(&v)),
            .bigint, .string => |t| h.update(t),
            // 0.0 and -0.0 are equal under `==`, so they hash alike.
            .real => |r| h.update(std.mem.asBytes(&(if (r == 0) @as(f64, 0) else r))),
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
        .real => |ar| b.datum == .real and b.datum.real == ar, // naive: NaN never equals itself
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

test "parsing is linear: a list of n forms costs O(n) parser memory" {
    const allocator = std.testing.allocator;
    const n = 4000;
    inline for (.{ "[", "" }, .{ "]", "" }) |open, close| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(allocator);
        try src.appendSlice(allocator, open);
        for (0..n) |i| try src.print(allocator, "{d} ", .{i});
        try src.appendSlice(allocator, close);
        var p = parser.Parser.init(allocator, src.items);
        defer p.deinit();
        _ = try p.parseProgram();
        // A few Sexps per element; a list that copied itself on every
        // append would hold n²/2 of them.
        try std.testing.expect(p.arena.queryCapacity() < 256 * n);
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
        const src = try std.fmt.allocPrint(allocator, shape, .{body});
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
    const allocator = std.testing.allocator;
    const ints = [_]struct { src: []const u8, value: i64 }{
        .{ .src = "1N", .value = 1 },
        .{ .src = "-7N", .value = -7 },
        .{ .src = "0xFFN", .value = 255 },
        .{ .src = "0b101N", .value = 5 },
    };
    for (ints) |c| {
        var p = parser.Parser.init(allocator, c.src);
        defer p.deinit();
        var rd = Reader.init(allocator, c.src);
        defer rd.deinit();
        const forms = try rd.readProgram(try p.parseProgram());
        try std.testing.expectEqual(@as(usize, 1), forms.len);
        try std.testing.expectEqual(c.value, forms[0].datum.int);
    }
    const wide = "18446744073709551616N";
    var p = parser.Parser.init(allocator, wide);
    defer p.deinit();
    var rd = Reader.init(allocator, wide);
    defer rd.deinit();
    const forms = try rd.readProgram(try p.parseProgram());
    try std.testing.expectEqualStrings("18446744073709551616", forms[0].datum.bigint);
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
    try expectReaderError("\"abc \\u0041\"", .invalid_string_escape, "\\u");
    // An unterminated string is a parse error at its opening quote.
    const allocator = std.testing.allocator;
    const src = "(println \"never closed\n(+ 1 2)";
    var p = parser.Parser.init(allocator, src);
    defer p.deinit();
    try std.testing.expectError(error.ParseError, p.parseProgram());
    try std.testing.expectEqual(@as(u32, 9), p.current.pos);
    try std.testing.expectEqual(@as(u16, 1), p.current.len);
}

test "char literals: one token to the next delimiter, judged whole" {
    try expectReads("[\\u{41} \\newline \\a \\é \\☃ \\( \\\\ \\u \\o]", "(vector (char \\A) (char \\newline) (char \\a) (char \\u{E9}) (char \\u{2603}) (char \\() (char \\\\) (char \\u) (char \\o))\n");
    // A delimiter or reader macro character ends the token.
    try expectReads("(\\a)[\\b@c]", "(list (char \\a))\n(vector\n  (char \\b)\n  (deref (symbol c)))\n");
    // Clojure's `\uXXXX` and `\oNNN` spellings, a letter or digit run
    // after a char, a surrogate and a scalar past U+10FFFF are errors
    // over the whole token, never a char followed by more forms.
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "\\u0041", "\\o101", "\\a1", "\\ab", "\\é1", "\\u{D800}", "\\u{110000}", "\\u{41}x" }) |src| {
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
    const allocator = std.testing.allocator;
    // Discard consumes its next form including any reader sugar attached
    // to it (metadata, deref, quote, anon-fn): the prefixed form is one form.
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
    // `#_ #_ x y z` yields `[z]` (drops x and y), as Clojure's reader
    // does: each `#_` consumes one form, and the form it consumes may
    // itself begin with `#_`.
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

test "an unsupported construct is one err token, so the parse error names it" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "#\"a.*\"", "#\"" }, .{ "##Inf", "##Inf" },   .{ "#!/usr/bin/env nexis", "#!/usr/bin/env" },
        .{ "::k", "::k" },      .{ "#?(:clj 1)", "#?" }, .{ "# x", "#" },
    };
    for (cases) |c| {
        var p = parser.Parser.init(allocator, c[0]);
        defer p.deinit();
        try std.testing.expectError(error.ParseError, p.parseProgram());
        try std.testing.expectEqualStrings(c[1], c[0][p.current.pos..][0..p.current.len]);
    }
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
