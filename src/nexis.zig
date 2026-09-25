//! nexis language module: the `@lang = "nexis"` companion of
//! `nexis.grammar`.
//!
//!   - `Tag`: every tag the grammar's actions put at the head of a list;
//!     `src/reader.zig` consumes exactly this set.
//!   - `Lexer`: the scanner, which replaces the generated one entirely.
//!     Clojure's token boundaries (a number, char or symbol token runs to
//!     the next delimiter) are written here once, and the generated parser
//!     drives `next()` as it would its own lexer.

const std = @import("std");
const parser = @import("parser.zig");

/// Tag enum mirroring the canonical S-expression schema emitted by
/// `nexis.grammar`. Every variant corresponds to a tagged sexp the generated
/// parser produces; `src/reader.zig` consumes exactly this set.
pub const Tag = enum(u8) {
    // Top-level wrappers
    program,

    // Atom leaves (Appendix C §28.2 — atom datum variants)
    int,
    real,
    string,
    char,
    keyword,
    symbol,

    // Compound collection literals
    list,
    vector,
    map,
    set,

    // Reader macros (user-visible conventional tags from PLAN §28.2)
    quote,
    @"syntax-quote",
    unquote,
    @"unquote-splicing",
    deref,

    // Internal reader-stage tags consumed and rewritten by src/reader.zig
    @"anon-fn",
    @"with-meta-raw",
};

/// The byte length of a leaf the parser built from a `Lexer` token (see
/// `Lexer.finish`).
pub fn srcLen(s: parser.Src) u32 {
    return @as(u32, s.id) << 16 | s.len;
}

// =============================================================================
// Lexer — full hand-written replacement
// =============================================================================

const Token = parser.Token;
const TokenCat = parser.TokenCat;

pub const Lexer = struct {
    base: parser.BaseLexer,

    pub fn init(source: []const u8) Lexer {
        return .{ .base = parser.BaseLexer.init(source) };
    }

    pub fn text(self: *const Lexer, tok: Token) []const u8 {
        return self.base.text(tok);
    }

    pub fn reset(self: *Lexer) void {
        self.base.reset();
    }

    pub fn next(self: *Lexer) Token {
        const src = self.base.source;

        // Skip whitespace (spaces, tabs, CR, LF, commas) and line
        // comments, and a UTF-8 byte-order mark that starts the source,
        // which some editors write.
        const ws_start: u32 = self.base.pos;
        if (self.base.pos == 0 and std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) self.base.pos = 3;
        while (true) {
            while (self.base.pos < src.len) : (self.base.pos += 1) {
                switch (src[self.base.pos]) {
                    ' ', '\t', '\r', '\n', ',' => {},
                    else => break,
                }
            }
            if (self.base.pos < src.len and src[self.base.pos] == ';') {
                while (self.base.pos < src.len and src[self.base.pos] != '\n') : (self.base.pos += 1) {}
                continue;
            }
            break;
        }
        const pre: u8 = @intCast(@min(self.base.pos - ws_start, 255));

        if (self.base.pos >= src.len) {
            return .{ .cat = .eof, .pre = pre, .pos = self.base.pos, .len = 0 };
        }

        const start = self.base.pos;
        const c = src[start];

        switch (c) {
            '(' => return self.single(.lparen, start, pre),
            ')' => return self.single(.rparen, start, pre),
            '[' => return self.single(.lbracket, start, pre),
            ']' => return self.single(.rbracket, start, pre),
            '{' => return self.single(.lbrace, start, pre),
            '}' => return self.single(.rbrace, start, pre),
            '\'' => return self.single(.quote_tok, start, pre),
            '`' => return self.single(.syntax_quote_tok, start, pre),
            '@' => return self.single(.deref_tok, start, pre),
            '^' => return self.single(.caret, start, pre),
            '~' => {
                if (start + 1 < src.len and src[start + 1] == '@') {
                    self.base.pos += 2;
                    return .{ .cat = .unquote_splicing_tok, .pre = pre, .pos = start, .len = 2 };
                }
                return self.single(.unquote_tok, start, pre);
            },
            '#' => {
                if (start + 1 < src.len) {
                    switch (src[start + 1]) {
                        '{' => {
                            self.base.pos += 2;
                            return .{ .cat = .hash_lbrace, .pre = pre, .pos = start, .len = 2 };
                        },
                        '(' => {
                            self.base.pos += 2;
                            return .{ .cat = .hash_lparen, .pre = pre, .pos = start, .len = 2 };
                        },
                        '_' => {
                            self.base.pos += 2;
                            return .{ .cat = .hash_discard, .pre = pre, .pos = start, .len = 2 };
                        },
                        ' ', '\t', '\r', '\n', ',' => {},
                        // An unsupported dispatch (`#'x`, `#"`, `##Inf`,
                        // `#?`) is one err token, so the parse error
                        // names the construct.
                        else => |after| {
                            self.base.pos = start + 2;
                            if (isIdentCont(after)) self.skipConstituents();
                            return self.finish(.err, start, pre);
                        },
                    }
                }
                return self.single(.err, start, pre);
            },
            '"' => return self.scanString(start, pre),
            '\\' => return self.scanChar(start, pre),
            ':' => return self.scanKeyword(start, pre),
            '0'...'9' => return self.scanNumber(start, pre, false),
            '-' => {
                // `-` followed by digit begins a negative number.
                if (start + 1 < src.len and isAsciiDigit(src[start + 1])) {
                    return self.scanNumber(start, pre, true);
                }
                return self.scanIdent(start, pre);
            },
            else => {
                if (isIdentStart(c)) return self.scanIdent(start, pre);
                return self.single(.err, start, pre);
            },
        }
    }

    /// The token from `start` to the scan position. Token and Src carry a
    /// u16 length; the high half goes through `aux`, which the parser
    /// copies into the leaf's `src.id` (`srcLen` puts the halves together).
    fn finish(self: *Lexer, cat: TokenCat, start: u32, pre: u8) Token {
        const len = self.base.pos - start;
        self.base.aux = @intCast(len >> 16);
        return .{ .cat = cat, .pre = pre, .pos = start, .len = @truncate(len) };
    }

    inline fn single(self: *Lexer, cat: TokenCat, start: u32, pre: u8) Token {
        self.base.pos = start + 1;
        return .{ .cat = cat, .pre = pre, .pos = start, .len = 1 };
    }

    inline fn isAsciiDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    inline fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }

    inline fn isBinDigit(c: u8) bool {
        return c == '0' or c == '1';
    }

    /// Clojure-style symbol start: letters, underscore, the accepted
    /// symbolic chars, and every byte of a non-ASCII UTF-8 character
    /// (the reader validates the sequence). `-` is handled at the
    /// dispatch level so we can disambiguate negative numbers.
    inline fn isIdentStart(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '_', '!', '$', '%', '&', '*', '+', '.', '/', '<', '=', '>', '?', 0x80...0xFF => true,
            else => false,
        };
    }

    inline fn isIdentCont(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '!', '$', '%', '&', '*', '+', '-', '.', '/', ':', '<', '=', '>', '?', '\'', '#', 0x80...0xFF => true,
            else => false,
        };
    }

    /// A string token runs to the closing `"`, across lines; the reader
    /// decodes the escapes. An unterminated string is an `err` token of
    /// its opening quote alone, so the parse error points there.
    fn scanString(self: *Lexer, start: u32, pre: u8) Token {
        const src = self.base.source;
        var pos = start + 1;
        while (pos < src.len) : (pos += 1) {
            switch (src[pos]) {
                '"' => {
                    self.base.pos = pos + 1;
                    return self.finish(.string, start, pre);
                },
                '\\' => pos += 1,
                else => {},
            }
        }
        return self.single(.err, start, pre);
    }

    /// A char token: `\`, one character (a whole UTF-8 sequence, or
    /// any byte, a delimiter included), then every symbol constituent
    /// that follows, as a number token runs (FORMS.md §3). `\u{HEX}`
    /// runs to its `}` first. The reader judges the text, so `\a1` and
    /// `\u0041` are each one token it rejects, never a char followed by
    /// another form.
    fn scanChar(self: *Lexer, start: u32, pre: u8) Token {
        const src = self.base.source;
        var pos = start + 1;
        if (pos >= src.len) return self.single(.err, start, pre);
        if (src[pos] == 'u' and pos + 1 < src.len and src[pos + 1] == '{') {
            pos += 2;
            while (pos < src.len and isHexDigit(src[pos])) pos += 1;
            if (pos >= src.len or src[pos] != '}') {
                self.base.pos = pos;
                return self.finish(.err, start, pre);
            }
            pos += 1;
        } else {
            const n = std.unicode.utf8ByteSequenceLength(src[pos]) catch 1;
            pos = @min(pos + n, @as(u32, @intCast(src.len)));
        }
        while (pos < src.len and isIdentCont(src[pos])) pos += 1;
        self.base.pos = pos;
        return self.finish(.char, start, pre);
    }

    fn scanKeyword(self: *Lexer, start: u32, pre: u8) Token {
        const src = self.base.source;
        // start points at ':'. Accept any of the symbolic start chars; `-`
        // is admissible here even though the top-level dispatch excludes it
        // (the top level reserves `-` for negative numbers). After `:`
        // there is no negative-number ambiguity, so `:-foo` is just a
        // keyword whose body starts with `-` — matching Clojure.
        self.base.pos = start + 1;
        if (self.base.pos >= src.len) {
            return .{ .cat = .err, .pre = pre, .pos = start, .len = 1 };
        }
        const first = src[self.base.pos];
        if (first == ':') {
            // `::k`, an auto-resolved keyword, is not supported: one err
            // token over it names it in the parse error.
            self.skipConstituents();
            return self.finish(.err, start, pre);
        }
        if (!isIdentStart(first) and first != '-') return self.single(.err, start, pre);
        self.skipConstituents();
        return self.finish(.keyword, start, pre);
    }

    fn skipConstituents(self: *Lexer) void {
        const src = self.base.source;
        while (self.base.pos < src.len and isIdentCont(src[self.base.pos])) : (self.base.pos += 1) {}
    }

    fn scanIdent(self: *Lexer, start: u32, pre: u8) Token {
        const src = self.base.source;
        self.base.pos = start + 1;
        while (self.base.pos < src.len and isIdentCont(src[self.base.pos])) : (self.base.pos += 1) {}
        return self.finish(.ident, start, pre);
    }

    /// A number token: `-?`, then `0x`/`0b` and radix digits, or decimal
    /// digits with an optional fraction and exponent. The token ends
    /// where a symbol would, at whitespace, a delimiter or a reader
    /// macro character; the symbol constituents that follow the digits
    /// belong to the token. `1abc`, `1-2`, `1.5x`, `1/2`, `1N` and `0x`
    /// each reach the reader as one number-shaped token, never as a
    /// number followed by a symbol, and the reader judges the text
    /// (FORMS.md §3, "Number token boundary").
    fn scanNumber(self: *Lexer, start: u32, pre: u8, has_minus: bool) Token {
        const src = self.base.source;
        self.base.pos = if (has_minus) start + 1 else start;
        var is_real = false;

        // Hex `0x...` / binary `0b...`.
        var radix = false;
        if (self.base.pos + 1 < src.len and src[self.base.pos] == '0') {
            const d = src[self.base.pos + 1];
            if (d == 'x' or d == 'X') {
                radix = true;
                self.base.pos += 2;
                while (self.base.pos < src.len and isHexDigit(src[self.base.pos])) : (self.base.pos += 1) {}
            } else if (d == 'b' or d == 'B') {
                radix = true;
                self.base.pos += 2;
                while (self.base.pos < src.len and isBinDigit(src[self.base.pos])) : (self.base.pos += 1) {}
            }
        }

        // Decimal integer / real.
        if (!radix) {
            while (self.base.pos < src.len and isAsciiDigit(src[self.base.pos])) : (self.base.pos += 1) {}
            if (self.base.pos < src.len and src[self.base.pos] == '.') {
                const after = self.base.pos + 1;
                if (after < src.len and isAsciiDigit(src[after])) {
                    is_real = true;
                    self.base.pos = after;
                    while (self.base.pos < src.len and isAsciiDigit(src[self.base.pos])) : (self.base.pos += 1) {}
                }
            }
            if (self.base.pos < src.len and (src[self.base.pos] == 'e' or src[self.base.pos] == 'E')) {
                var pp = self.base.pos + 1;
                if (pp < src.len and (src[pp] == '+' or src[pp] == '-')) pp += 1;
                if (pp < src.len and isAsciiDigit(src[pp])) {
                    is_real = true;
                    self.base.pos = pp + 1;
                    while (self.base.pos < src.len and isAsciiDigit(src[self.base.pos])) : (self.base.pos += 1) {}
                }
            }
        }

        // Whatever symbol constituents follow stay in the token.
        while (self.base.pos < src.len and isIdentCont(src[self.base.pos])) : (self.base.pos += 1) {}
        return self.finish(if (is_real) .real else .integer, start, pre);
    }
};
