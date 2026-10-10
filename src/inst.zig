//! inst.zig — the calendar and text of the `inst` kind, whose payload
//! is the milliseconds since 1970-01-01T00:00:00Z on the proleptic
//! Gregorian calendar, in UTC, without leap seconds (docs/STDLIB.md
//! §12, SEMANTICS.md §2.8).
//!
//! One parser and two writers over the same calendar: `parse` reads
//! Clojure's `#inst` grammar and the spellings Java's
//! `Instant.toString` writes; `write` writes Clojure's `#inst` text
//! (`.literal`, the printer's) or `Instant.toString`'s (`.iso`, the
//! text of `str`, `nexis.time/format` and JSON). Each reads back as the
//! instant it was written from.

const std = @import("std");

pub const ms_per_day = 86_400_000;

/// The longest text `write` makes: a signed nine-digit year and the
/// literal style's fraction and offset.
pub const max_text_len = 40;

/// The days from 1970-01-01 to the date `year-month-day` (Hinnant's
/// `days_from_civil`, exact for every year an i64 instant reaches).
pub fn daysFromCivil(year: i64, month: u32, day: u32) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

pub const Civil = struct { year: i64, month: u32, day: u32 };

/// The date `days` after 1970-01-01 (`civil_from_days`).
pub fn civilFromDays(days: i64) Civil {
    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = yoe + era * 400 + @intFromBool(month <= 2),
        .month = @intCast(month),
        .day = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1),
    };
}

pub fn daysInMonth(year: i64, month: u32) u32 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub const Style = enum {
    /// Clojure's `#inst` text, `2026-10-09T10:30:15.123-00:00`: always
    /// the milliseconds and the offset `-00:00`.
    literal,
    /// Java's `Instant.toString` to the millisecond,
    /// `2026-10-09T10:30:15.123Z`: the fraction left out when it is
    /// zero.
    iso,
};

/// The instant `ms` as text in `style`. A year before 0 is written
/// with a `-` and one past 9999 with a `+`, each with at least four
/// digits, so the text reads back through `parse`.
pub fn write(w: *std.Io.Writer, ms: i64, style: Style) std.Io.Writer.Error!void {
    const in_day: u64 = @intCast(@mod(ms, ms_per_day));
    const date = civilFromDays(@divFloor(ms, ms_per_day));
    if (date.year < 0) try w.writeByte('-') else if (date.year > 9999) try w.writeByte('+');
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{ @abs(date.year), date.month, date.day, in_day / 3_600_000, in_day / 60_000 % 60, in_day / 1000 % 60 });
    switch (style) {
        .literal => try w.print(".{d:0>3}-00:00", .{in_day % 1000}),
        .iso => {
            if (in_day % 1000 != 0) try w.print(".{d:0>3}", .{in_day % 1000});
            try w.writeByte('Z');
        },
    }
}

/// The instant the text `s` names, in epoch milliseconds, or null when
/// it names none or one past the i64 range. The grammar is Clojure's
/// `#inst` (`instant.clj`), with a signed or longer year, a lower-case
/// `T` or `Z` and an offset without its colon also read:
///
///     instant = year [ "-" MM [ "-" DD [ T HH [ ":" mm [ ":" ss [ "." 1*DIGIT ] ] ] ] ] ] [ offset ]
///     year    = [ "+" / "-" ] 4*9DIGIT
///     T       = "T" / "t"
///     offset  = "Z" / "z" / ( "+" / "-" ) HH [ ":" ] mm
///
/// A month is 1–12, a day 1 to the month's length, an hour 0–23, a
/// minute 0–59 and a second 0–59, or 60 in minute 59, which rolls into
/// the next minute as Clojure's does. The first three digits of a
/// fraction are the milliseconds; the rest are ignored.
pub fn parse(s: []const u8) ?i64 {
    const Scan = struct {
        s: []const u8,
        i: usize = 0,

        fn eat(p: *@This(), set: []const u8) bool {
            if (p.i >= p.s.len or std.mem.findScalar(u8, set, p.s[p.i]) == null) return false;
            p.i += 1;
            return true;
        }

        fn digits(p: *@This(), n: usize) ?u32 {
            if (p.s.len - p.i < n) return null;
            var v: u32 = 0;
            for (p.s[p.i..][0..n]) |c| {
                if (!std.ascii.isDigit(c)) return null;
                v = v * 10 + (c - '0');
            }
            p.i += n;
            return v;
        }

        /// The run of digits at the cursor, which moves past it.
        fn run(p: *@This()) []const u8 {
            const start = p.i;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
            return p.s[start..p.i];
        }
    };
    var p: Scan = .{ .s = s };
    const negative = p.eat("-");
    if (!negative) _ = p.eat("+");
    // Nine digits pass every year an i64 instant reaches.
    const year_text = p.run();
    if (year_text.len < 4 or year_text.len > 9) return null;
    const magnitude = std.fmt.parseInt(i64, year_text, 10) catch return null;
    const year = if (negative) -magnitude else magnitude;
    var month: u32 = 1;
    var day: u32 = 1;
    var hour: u32 = 0;
    var minute: u32 = 0;
    var second: u32 = 0;
    var milli: u32 = 0;
    if (p.eat("-")) {
        month = p.digits(2) orelse return null;
        if (p.eat("-")) {
            day = p.digits(2) orelse return null;
            if (p.eat("Tt")) {
                hour = p.digits(2) orelse return null;
                if (p.eat(":")) {
                    minute = p.digits(2) orelse return null;
                    if (p.eat(":")) {
                        second = p.digits(2) orelse return null;
                        if (p.eat(".")) {
                            const fraction = p.run();
                            if (fraction.len == 0) return null;
                            for (0..3) |k| milli = milli * 10 + if (k < fraction.len) fraction[k] - '0' else 0;
                        }
                    }
                }
            }
        }
    }
    var offset: i64 = 0;
    if (!p.eat("Zz") and p.i < s.len and (s[p.i] == '+' or s[p.i] == '-')) {
        const sign: i64 = if (s[p.i] == '-') -1 else 1;
        p.i += 1;
        const oh = p.digits(2) orelse return null;
        _ = p.eat(":");
        const om = p.digits(2) orelse return null;
        if (oh > 23 or om > 59) return null;
        offset = sign * (oh * 60 + om);
    }
    if (p.i != s.len) return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > @as(u32, if (minute == 59) 60 else 59)) return null;
    const seconds = (@as(i64, hour) * 60 + minute - offset) * 60 + second;
    // The day's start may lie past the i64 range when the instant does not.
    return std.math.cast(i64, @as(i128, daysFromCivil(year, month, day)) * ms_per_day + seconds * 1000 + milli);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn textOf(buf: *[max_text_len]u8, ms: i64, style: Style) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, ms, style) catch unreachable;
    return w.buffered();
}

test "inst: the civil calendar agrees with std.time.epoch and walks day by day" {
    var day: i64 = 0;
    while (day < 60_000) : (day += 1) {
        const yd = (std.time.epoch.EpochDay{ .day = @intCast(day) }).calculateYearDay();
        const md = yd.calculateMonthDay();
        const c = civilFromDays(day);
        try testing.expectEqual(@as(i64, yd.year), c.year);
        try testing.expectEqual(@as(u32, @backingInt(md.month)), c.month);
        try testing.expectEqual(@as(u32, md.day_index) + 1, c.day);
    }
    // Every day of years -2500 to 6500 follows the one before it.
    var prev = civilFromDays(-1_633_000);
    day = -1_632_999;
    while (day < 1_660_000) : (day += 1) {
        const c = civilFromDays(day);
        try testing.expectEqual(day, daysFromCivil(c.year, c.month, c.day));
        if (c.day == 1) {
            try testing.expectEqual(daysInMonth(prev.year, prev.month), prev.day);
            try testing.expectEqual(if (c.month == 1) prev.year + 1 else prev.year, c.year);
        } else try testing.expectEqual(prev.day + 1, c.day);
        prev = c;
    }
}

test "inst: parse reads Clojure's #inst grammar and its superset" {
    const ok = [_]struct { []const u8, i64 }{
        .{ "2020", 1_577_836_800_000 },
        .{ "2020-01-01T10", 1_577_872_800_000 },
        .{ "2026-10-09T12:30:15.123+02:00", 1_791_541_815_123 },
        .{ "2026-10-09T12:30:15.123+0200", 1_791_541_815_123 },
        .{ "2026-10-09t10:30:15.123z", 1_791_541_815_123 },
        .{ "2020-01-01T10:00:00.123456789012", 1_577_872_800_123 },
        // A leap second rolls into the next minute.
        .{ "2020-01-01T23:59:60", 1_577_923_200_000 },
        .{ "2020-01-01T22:59:60", 1_577_919_600_000 },
        .{ "10000-01-01", 253_402_300_800_000 },
        .{ "+10000-01-01", 253_402_300_800_000 },
        .{ "-0001-01-01", -62_198_755_200_000 },
        .{ "0000-01-01", -62_167_219_200_000 },
    };
    for (ok) |c| testing.expectEqual(@as(?i64, c[1]), parse(c[0])) catch |err| {
        std.debug.print("\n  parse \"{s}\"\n", .{c[0]});
        return err;
    };
    const refused = [_][]const u8{ "", "202", "2020-13", "2020-1-01", "2020-02-30", "2020-01-01T24:00", "2020-01-01T22:58:60", "2020-01-01T10:00:00.", "2020-01-01T10:00+24:00", "2020-01-01Z ", "999999999-01-01", "-999999999-01-01", "+1000000000" };
    for (refused) |s| testing.expectEqual(@as(?i64, null), parse(s)) catch |err| {
        std.debug.print("\n  parse \"{s}\"\n", .{s});
        return err;
    };
}

test "inst: write gives Clojure's #inst text and Instant.toString's" {
    var buf: [max_text_len]u8 = undefined;
    const cases = [_]struct { i64, []const u8, []const u8 }{
        .{ 0, "1970-01-01T00:00:00.000-00:00", "1970-01-01T00:00:00Z" },
        .{ -1, "1969-12-31T23:59:59.999-00:00", "1969-12-31T23:59:59.999Z" },
        .{ 1_791_541_815_123, "2026-10-09T10:30:15.123-00:00", "2026-10-09T10:30:15.123Z" },
        .{ -62_167_219_200_000, "0000-01-01T00:00:00.000-00:00", "0000-01-01T00:00:00Z" },
        .{ 253_402_300_800_000, "+10000-01-01T00:00:00.000-00:00", "+10000-01-01T00:00:00Z" },
        .{ std.math.maxInt(i64), "+292278994-08-17T07:12:55.807-00:00", "+292278994-08-17T07:12:55.807Z" },
        .{ std.math.minInt(i64), "-292275055-05-16T16:47:04.192-00:00", "-292275055-05-16T16:47:04.192Z" },
    };
    for (cases) |c| {
        try testing.expectEqualStrings(c[1], textOf(&buf, c[0], .literal));
        try testing.expectEqualStrings(c[2], textOf(&buf, c[0], .iso));
    }
}

test "inst: every instant's text in either style reads back as the instant" {
    var buf: [max_text_len]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(0x1505);
    for (0..20_000) |i| {
        const ms: i64 = switch (i) {
            0 => std.math.minInt(i64),
            1 => std.math.maxInt(i64),
            2 => -1,
            3 => 0,
            else => if (i % 2 == 0) rng.random().int(i64) else rng.random().intRangeAtMost(i64, -1 << 47, 1 << 47),
        };
        for ([_]Style{ .literal, .iso }) |style| {
            try testing.expectEqual(@as(?i64, ms), parse(textOf(&buf, ms, style)));
        }
    }
}
