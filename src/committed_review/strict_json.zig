//! Committed-review strict-data compatibility facade and domain policy.

const std = @import("std");
const limits = @import("limits.zig");
const neutral = @import("../data/strict_json.zig");

const parser_policy: neutral.Policy = .{
    .max_token_bytes = limits.max_json_token_bytes,
    .max_depth = limits.max_json_depth,
};
pub const Parser = neutral.Parser(parser_policy);
pub const ParseError = neutral.ParseError || error{
    ArtifactTooLarge,
    UnsupportedSchemaVersion,
    UnknownField,
    DuplicateFindingId,
    DuplicateDispositionId,
    DuplicateRelatedFindingId,
};
pub const markSeen = neutral.markSeen;
pub const requireFields = neutral.requireFields;

/// Admit exactly the independent committed-review schema version.
pub fn validateSchemaVersion(value: u64) ParseError!void {
    if (value != limits.schema_version) return error.UnsupportedSchemaVersion;
}

/// Admit one bounded run-local finding identifier.
pub fn validateFindingId(text: []const u8) ParseError!void {
    if (text.len == 0 or text.len > limits.max_finding_id_bytes) return error.InvalidValue;
    if (!std.ascii.isAlphanumeric(text[0])) return error.InvalidValue;
    for (text[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidValue;
        }
    }
}

/// Validate safe UTF-8 and the single-line/multiline control policy.
pub fn validateText(text: []const u8, maximum: usize, multiline: bool) ParseError!void {
    if (text.len == 0 or text.len > maximum) return error.LimitExceeded;
    var iterator = (std.unicode.Utf8View.init(text) catch return error.InvalidValue).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0x00 or codepoint == 0x1b or codepoint == 0x0d or
            codepoint == 0x7f or (codepoint >= 0x80 and codepoint <= 0x9f))
        {
            return error.InvalidValue;
        }
        if (codepoint < 0x20) {
            if (multiline and (codepoint == '\n' or codepoint == '\t')) continue;
            return error.InvalidValue;
        }
    }
}

/// Validate the fixed UTC-seconds timestamp grammar and calendar date.
pub fn validateTimestamp(text: []const u8) ParseError!void {
    if (text.len != 20 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':' or text[19] != 'Z')
    {
        return error.InvalidValue;
    }
    const year = try fixedDecimal(u16, text[0..4]);
    const month = try fixedDecimal(u8, text[5..7]);
    const day = try fixedDecimal(u8, text[8..10]);
    const hour = try fixedDecimal(u8, text[11..13]);
    const minute = try fixedDecimal(u8, text[14..16]);
    const second = try fixedDecimal(u8, text[17..19]);
    if (year == 0 or month == 0 or month > 12 or hour > 23 or minute > 59 or second > 59) {
        return error.InvalidValue;
    }
    const days = [_]u8{ 31, if (isLeapYear(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day == 0 or day > days[month - 1]) return error.InvalidValue;
}

/// Convert the already-fixed UTC-second grammar without normalizing or
/// accepting another timestamp spelling. History sort and display share this
/// exact value-preserving seam.
pub fn timestampToUnixSeconds(text: []const u8) ParseError!i64 {
    try validateTimestamp(text);
    const year: i64 = try fixedDecimal(u16, text[0..4]);
    const month: i64 = try fixedDecimal(u8, text[5..7]);
    const day: i64 = try fixedDecimal(u8, text[8..10]);
    const hour: i64 = try fixedDecimal(u8, text[11..13]);
    const minute: i64 = try fixedDecimal(u8, text[14..16]);
    const second: i64 = try fixedDecimal(u8, text[17..19]);

    // Proleptic Gregorian civil date to days since 1970-01-01. The admitted
    // year range is 0001...9999, so every intermediate is comfortably i64.
    const adjusted_year = year - @intFromBool(month <= 2);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    const days_since_epoch = era * 146_097 + day_of_era - 719_468;
    return days_since_epoch * 86_400 + hour * 3_600 + minute * 60 + second;
}

/// Allocate lossless raw path bytes from canonical unpadded base64url.
/// The returned slice belongs to `allocator` and need not be UTF-8.
pub fn decodeRawPath(allocator: std.mem.Allocator, encoded: []const u8) ParseError![]const u8 {
    if (encoded.len == 0 or encoded.len > limits.max_raw_path_encoded_bytes) return error.LimitExceeded;
    for (encoded) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidValue;
    }
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch return error.InvalidValue;
    if (decoded_len == 0 or decoded_len > limits.max_raw_path_bytes) return error.LimitExceeded;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded) catch return error.InvalidValue;
    if (std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidValue;

    const canonical_len = std.base64.url_safe_no_pad.Encoder.calcSize(decoded.len);
    if (canonical_len != encoded.len) return error.InvalidValue;
    const canonical = try allocator.alloc(u8, canonical_len);
    defer allocator.free(canonical);
    const written = std.base64.url_safe_no_pad.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, written, encoded)) return error.InvalidValue;
    return decoded;
}

fn fixedDecimal(comptime T: type, bytes: []const u8) ParseError!T {
    for (bytes) |byte| if (byte < '0' or byte > '9') return error.InvalidValue;
    return std.fmt.parseInt(T, bytes, 10) catch error.InvalidValue;
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

test "text policy preserves Unicode and multiline LF TAB but rejects terminal controls" {
    try validateText("東京\n\tbody", limits.max_body_bytes, true);
    try std.testing.expectError(error.InvalidValue, validateText("single\nline", limits.max_short_text_bytes, false));
    try std.testing.expectError(error.InvalidValue, validateText("escape\x1b[31m", limits.max_body_bytes, true));
    try std.testing.expectError(error.InvalidValue, validateText("C1\xc2\x9b", limits.max_body_bytes, true));
}

test "timestamp validator enforces Gregorian UTC seconds" {
    try validateTimestamp("2024-02-29T23:59:59Z");
    try std.testing.expectError(error.InvalidValue, validateTimestamp("2023-02-29T23:59:59Z"));
    try std.testing.expectError(error.InvalidValue, validateTimestamp("2024-01-01T00:00:60Z"));
    try std.testing.expectError(error.InvalidValue, validateTimestamp("0000-01-01T00:00:00Z"));
}

test "review history backend timestamp seam preserves exact UTC-second ordering" {
    try std.testing.expectEqual(@as(i64, 0), try timestampToUnixSeconds("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(@as(i64, -1), try timestampToUnixSeconds("1969-12-31T23:59:59Z"));
    try std.testing.expectEqual(@as(i64, 1_709_251_199), try timestampToUnixSeconds("2024-02-29T23:59:59Z"));
    try std.testing.expectError(error.InvalidValue, timestampToUnixSeconds("2024-02-29T23:59:59+00:00"));
}

test "raw paths round trip canonical unpadded base64url losslessly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try decodeRawPath(arena.allocator(), "c3JjL_8uemln");
    try std.testing.expectEqualSlices(u8, "src/\xff.zig", path);
    try std.testing.expectError(error.InvalidValue, decodeRawPath(arena.allocator(), "c3JjL_8uemln="));
}

test "finite decoded text and raw path bounds accept exact and reject plus one" {
    const allocator = std.testing.allocator;
    const short_exact = try allocator.alloc(u8, limits.max_short_text_bytes);
    defer allocator.free(short_exact);
    @memset(short_exact, 'a');
    try validateText(short_exact, limits.max_short_text_bytes, false);
    const short_plus_one = try allocator.alloc(u8, limits.max_short_text_bytes + 1);
    defer allocator.free(short_plus_one);
    @memset(short_plus_one, 'a');
    try std.testing.expectError(error.LimitExceeded, validateText(short_plus_one, limits.max_short_text_bytes, false));

    const body_exact = try allocator.alloc(u8, limits.max_body_bytes);
    defer allocator.free(body_exact);
    @memset(body_exact, 'b');
    try validateText(body_exact, limits.max_body_bytes, true);
    const body_plus_one = try allocator.alloc(u8, limits.max_body_bytes + 1);
    defer allocator.free(body_plus_one);
    @memset(body_plus_one, 'b');
    try std.testing.expectError(error.LimitExceeded, validateText(body_plus_one, limits.max_body_bytes, true));

    const path_exact = try allocator.alloc(u8, limits.max_raw_path_bytes);
    defer allocator.free(path_exact);
    @memset(path_exact, 0xff);
    const encoded_exact = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(path_exact.len));
    defer allocator.free(encoded_exact);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded_exact, path_exact);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try decodeRawPath(arena.allocator(), encoded_exact);
    try std.testing.expectEqualSlices(u8, path_exact, decoded);

    const path_plus_one = try allocator.alloc(u8, limits.max_raw_path_bytes + 1);
    defer allocator.free(path_plus_one);
    @memset(path_plus_one, 0xff);
    const encoded_plus_one = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(path_plus_one.len));
    defer allocator.free(encoded_plus_one);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded_plus_one, path_plus_one);
    try std.testing.expectError(error.LimitExceeded, decodeRawPath(arena.allocator(), encoded_plus_one));
}
