const std = @import("std");
const chasen = @import("chasen");
const content_fingerprint = @import("../content_fingerprint.zig");
const repository_path = @import("path.zig");

pub const max_bytes: usize = 16 * 1024 * 1024;
pub const max_paths: usize = 200_000;
pub const max_path_bytes: usize = repository_path.max_bytes;

pub const ParseError = error{
    OutOfMemory,
    ManifestTooLarge,
    TooManyPaths,
    PathTooLong,
    MissingTerminator,
    EmptyPath,
    DuplicatePath,
    AbsolutePath,
    InvalidComponent,
};

/// Owns the exact NUL-delimited output of `git ls-files` and a sorted table of
/// slices into it. Path identity stays byte-exact; display escaping is a
/// separate, injective projection and must never be used to open a file.
pub const Document = struct {
    bytes: []u8,
    paths: []const []const u8,
    fingerprint: content_fingerprint.Fingerprint,

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        allocator.free(self.paths);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Parses an owned backend buffer. On failure this function consumes and
/// releases `bytes`, making task-result cleanup single-owner on every path.
pub fn parseOwned(allocator: std.mem.Allocator, bytes: []u8) ParseError!Document {
    errdefer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.ManifestTooLarge;
    if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.MissingTerminator;

    var path_count: usize = 0;
    var start: usize = 0;
    while (start < bytes.len) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse return error.MissingTerminator;
        try repository_path.validate(bytes[start..end]);
        path_count += 1;
        if (path_count > max_paths) return error.TooManyPaths;
        start = end + 1;
    }

    const paths = try allocator.alloc([]const u8, path_count);
    errdefer allocator.free(paths);
    start = 0;
    var index: usize = 0;
    while (start < bytes.len) : (index += 1) {
        const end = std.mem.indexOfScalarPos(u8, bytes, start, 0).?;
        paths[index] = bytes[start..end];
        start = end + 1;
    }
    std.mem.sort([]const u8, paths, {}, repositoryPathLessThan);
    if (paths.len > 1) {
        for (paths[1..], paths[0 .. paths.len - 1]) |current, previous| {
            if (std.mem.eql(u8, current, previous)) return error.DuplicatePath;
        }
    }

    return .{
        .bytes = bytes,
        .paths = paths,
        .fingerprint = content_fingerprint.Fingerprint.init(bytes),
    };
}

/// Orders each directory level as directories first, then files, with bytewise
/// ordering inside each group. This is not plain full-path byte ordering:
/// `src/a` intentionally precedes a root file named `README`.
fn repositoryPathLessThan(_: void, left: []const u8, right: []const u8) bool {
    var left_start: usize = 0;
    var right_start: usize = 0;
    while (true) {
        const left_end = std.mem.indexOfScalarPos(u8, left, left_start, '/') orelse left.len;
        const right_end = std.mem.indexOfScalarPos(u8, right, right_start, '/') orelse right.len;
        const left_is_directory = left_end < left.len;
        const right_is_directory = right_end < right.len;
        if (left_is_directory != right_is_directory) return left_is_directory;

        switch (std.mem.order(u8, left[left_start..left_end], right[right_start..right_end])) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
        if (!left_is_directory) return false;
        left_start = left_end + 1;
        right_start = right_end + 1;
    }
}

pub const DisplayWindow = struct {
    storage: []u8,
    len: usize,

    pub fn text(self: DisplayWindow) []const u8 {
        return self.storage[0..self.len];
    }

    pub fn deinit(self: *DisplayWindow, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }
};

const EscapedDisplayToken = struct {
    bytes: [8]u8 = undefined,
    len: usize,
    columns: usize,
    consumed: usize,
};

const DisplayUnitResult = enum {
    continue_scanning,
    window_complete,
};

/// Produces only the requested terminal-cell window of a raw path identity.
/// The allocation is bounded by `4 * width + 8`, independent of raw path
/// length, control-byte expansion, horizontal skip, or combining characters.
/// Printable valid UTF-8 is measured, skipped, and copied as complete extended
/// grapheme clusters, matching `chasen.text`. A single adversarial grapheme
/// that cannot fit the bounded storage is omitted whole rather than fragmented.
pub fn displayWindowAlloc(
    allocator: std.mem.Allocator,
    raw: []const u8,
    skip_columns: usize,
    width: usize,
) !DisplayWindow {
    const capacity = try std.math.add(usize, try std.math.mul(usize, width, 4), 8);
    const storage = try allocator.alloc(u8, capacity);
    errdefer allocator.free(storage);
    if (width == 0) return .{ .storage = storage, .len = 0 };

    var raw_index: usize = 0;
    var skipped = skip_columns;
    var columns: usize = 0;
    var output_len: usize = 0;
    while (raw_index < raw.len) {
        const printable_len = printablePrefixLen(raw[raw_index..]);
        if (printable_len > 0) {
            const printable = raw[raw_index .. raw_index + printable_len];
            var iter = chasen.text.graphemeIterator(printable);
            while (iter.next()) |grapheme| {
                const bytes = grapheme.bytes(printable);
                const result = appendDisplayUnit(
                    storage,
                    bytes,
                    chasen.text.displayWidth(bytes),
                    &skipped,
                    &columns,
                    &output_len,
                    width,
                );
                if (result == .window_complete) {
                    return .{ .storage = storage, .len = output_len };
                }
            }
            raw_index += printable_len;
            continue;
        }

        const token = escapedDisplayToken(raw[raw_index..]);
        raw_index += token.consumed;
        const result = appendDisplayUnit(
            storage,
            token.bytes[0..token.len],
            token.columns,
            &skipped,
            &columns,
            &output_len,
            width,
        );
        if (result == .window_complete) break;
    }
    return .{ .storage = storage, .len = output_len };
}

fn appendDisplayUnit(
    storage: []u8,
    bytes: []const u8,
    unit_columns: usize,
    skipped: *usize,
    columns: *usize,
    output_len: *usize,
    width: usize,
) DisplayUnitResult {
    if (skipped.* > 0) {
        if (unit_columns <= skipped.*) {
            skipped.* -= unit_columns;
            return .continue_scanning;
        }
        // A horizontal offset inside a wide unit snaps after the whole unit.
        skipped.* = 0;
        return .continue_scanning;
    }
    if (unit_columns > width - columns.*) return .window_complete;
    if (bytes.len > storage.len - output_len.*) return .window_complete;
    @memcpy(storage[output_len.* .. output_len.* + bytes.len], bytes);
    output_len.* += bytes.len;
    columns.* += unit_columns;
    if (columns.* == width and unit_columns > 0) return .window_complete;
    return .continue_scanning;
}

/// Returns the longest prefix that can be passed to Chasen's grapheme
/// iterator without exposing raw controls, invalid UTF-8, or the display escape
/// introducer. Scanning maximal runs keeps the full operation linear.
fn printablePrefixLen(raw: []const u8) usize {
    var index: usize = 0;
    while (index < raw.len) {
        const byte = raw[index];
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) break;
        if (byte <= 0x7e) {
            index += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch break;
        const end = index + @as(usize, sequence_len);
        if (end > raw.len or !std.unicode.utf8ValidateSlice(raw[index..end])) break;
        const scalar = std.unicode.utf8Decode(raw[index..end]) catch break;
        if (scalar >= 0x80 and scalar <= 0x9f) break;
        index = end;
    }
    return index;
}

fn escapedDisplayToken(raw: []const u8) EscapedDisplayToken {
    const byte = raw[0];
    if (byte == '\\') {
        var token = EscapedDisplayToken{ .len = 2, .columns = 2, .consumed = 1 };
        token.bytes[0..2].* = "\\\\".*;
        return token;
    }
    if (byte >= 0x80) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch return escapedByteToken(byte);
        const end: usize = sequence_len;
        if (end <= raw.len and std.unicode.utf8ValidateSlice(raw[0..end])) {
            const scalar = std.unicode.utf8Decode(raw[0..end]) catch return escapedByteToken(byte);
            if (scalar >= 0x80 and scalar <= 0x9f) {
                var token = EscapedDisplayToken{ .len = end * 4, .columns = end * 4, .consumed = end };
                for (raw[0..end], 0..) |sequence_byte, index| {
                    writeEscapedByte(token.bytes[index * 4 ..][0..4], sequence_byte);
                }
                return token;
            }
        }
    }
    return escapedByteToken(byte);
}

fn escapedByteToken(byte: u8) EscapedDisplayToken {
    var token = EscapedDisplayToken{ .len = 4, .columns = 4, .consumed = 1 };
    writeEscapedByte(token.bytes[0..4], byte);
    return token;
}

fn writeEscapedByte(output: []u8, byte: u8) void {
    std.debug.assert(output.len == 4);
    _ = std.fmt.bufPrint(output, "\\x{X:0>2}", .{byte}) catch unreachable;
}

test "repository manifest parses and sorts NUL paths" {
    const bytes = try std.testing.allocator.dupe(u8, "src/main.zig\x00README.md\x00");
    var document = try parseOwned(std.testing.allocator, bytes);
    defer document.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), document.paths.len);
    try std.testing.expectEqualStrings("src/main.zig", document.paths[0]);
    try std.testing.expectEqualStrings("README.md", document.paths[1]);
}

test "repository manifest rejects malformed and unsafe paths" {
    const cases = [_]struct { bytes: []const u8, expected: ParseError }{
        .{ .bytes = "missing", .expected = error.MissingTerminator },
        .{ .bytes = "\x00", .expected = error.EmptyPath },
        .{ .bytes = "/absolute\x00", .expected = error.AbsolutePath },
        .{ .bytes = "a/../b\x00", .expected = error.InvalidComponent },
        .{ .bytes = ".git/config\x00", .expected = error.InvalidComponent },
        .{ .bytes = "same\x00same\x00", .expected = error.DuplicatePath },
    };
    for (cases) |case| {
        const owned = try std.testing.allocator.dupe(u8, case.bytes);
        try std.testing.expectError(case.expected, parseOwned(std.testing.allocator, owned));
    }
}

test "repository manifest empty output is valid" {
    const bytes = try std.testing.allocator.alloc(u8, 0);
    var document = try parseOwned(std.testing.allocator, bytes);
    defer document.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), document.paths.len);
}

test "repository manifest enforces byte path and record limits before materialization" {
    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    try std.testing.expectError(error.ManifestTooLarge, parseOwned(std.testing.allocator, oversized));

    const long_path = try std.testing.allocator.alloc(u8, max_path_bytes + 2);
    @memset(long_path, 'a');
    long_path[long_path.len - 1] = 0;
    try std.testing.expectError(error.PathTooLong, parseOwned(std.testing.allocator, long_path));

    const too_many = try std.testing.allocator.alloc(u8, (max_paths + 1) * 2);
    for (0..max_paths + 1) |index| {
        too_many[index * 2] = 'a';
        too_many[index * 2 + 1] = 0;
    }
    try std.testing.expectError(error.TooManyPaths, parseOwned(std.testing.allocator, too_many));
}

test "repository manifest display escaping is injective for escape syntax" {
    var literal = try displayWindowAlloc(std.testing.allocator, "\\x1B", 0, 32);
    defer literal.deinit(std.testing.allocator);
    var control = try displayWindowAlloc(std.testing.allocator, "\x1b", 0, 32);
    defer control.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("\\\\x1B", literal.text());
    try std.testing.expectEqualStrings("\\x1B", control.text());
    try std.testing.expect(!std.mem.eql(u8, literal.text(), control.text()));
}

test "repository manifest display escaping preserves valid UTF-8 and escapes invalid bytes" {
    var escaped = try displayWindowAlloc(std.testing.allocator, "日本語\xff", 0, 32);
    defer escaped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("日本語\\xFF", escaped.text());
}

test "repository manifest display escaping rejects encoded C1 controls" {
    var escaped = try displayWindowAlloc(std.testing.allocator, "前\x7f\u{0080}中\u{0085}後\u{009f}", 0, 80);
    defer escaped.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("前\\x7F\\xC2\\x80中\\xC2\\x85後\\xC2\\x9F", escaped.text());
}

test "repository manifest display window preserves combining grapheme at boundary" {
    var window = try displayWindowAlloc(std.testing.allocator, "e\u{301}x", 0, 1);
    defer window.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("e\u{301}", window.text());
}

test "repository manifest display window skips complete combining grapheme" {
    var window = try displayWindowAlloc(std.testing.allocator, "e\u{301}x", 1, 1);
    defer window.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("x", window.text());
}

test "repository manifest display window preserves ZWJ grapheme only when it fits" {
    var exact = try displayWindowAlloc(std.testing.allocator, "👩‍🚀x", 0, 2);
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("👩‍🚀", exact.text());

    var insufficient = try displayWindowAlloc(std.testing.allocator, "👩‍🚀x", 0, 1);
    defer insufficient.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", insufficient.text());
}

test "repository manifest display window omits overlong grapheme without fragment" {
    const combining = "\u{301}";
    const combining_count = 32;
    var raw: [1 + combining.len * combining_count + 1]u8 = undefined;
    raw[0] = 'e';
    for (0..combining_count) |index| {
        const start = 1 + index * combining.len;
        @memcpy(raw[start .. start + combining.len], combining);
    }
    raw[raw.len - 1] = 'x';

    var window = try displayWindowAlloc(std.testing.allocator, &raw, 0, 1);
    defer window.deinit(std.testing.allocator);
    try std.testing.expect(window.storage.len <= 1 * 4 + 8);
    try std.testing.expectEqualStrings("", window.text());
}

test "repository manifest display window stays viewport bounded for maximum path" {
    const raw = try std.testing.allocator.alloc(u8, max_path_bytes);
    defer std.testing.allocator.free(raw);
    @memset(raw, 0x01);
    var window = try displayWindowAlloc(std.testing.allocator, raw, 100, 20);
    defer window.deinit(std.testing.allocator);
    try std.testing.expect(window.storage.len <= 20 * 4 + 8);
    try std.testing.expect(window.text().len <= 20 * 4);
    try std.testing.expect(chasen.text.displayWidth(window.text()) <= 20);
}
