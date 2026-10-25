//! Bounded, byte-exact Repository tree change state.
//!
//! This model answers whether Git porcelain reports a current path as changed.
//! It intentionally differs from `change_map.zig`, which compares one displayed
//! source snapshot with a pinned HEAD blob. Raw paths remain repository-relative
//! identities; they are never passed through diff-prefix normalization.

const std = @import("std");
const content_fingerprint = @import("../content_fingerprint.zig");
const repository_path = @import("path.zig");

pub const max_bytes: usize = 8 * 1024 * 1024;
pub const max_records: usize = 400_000;
pub const aggregate_allocation_limit: usize = 32 * 1024 * 1024;

pub const Kind = enum(u8) { added, modified };

pub const Entry = struct {
    path: []const u8,
    kind: Kind,
};

pub const ParseError = error{
    OutOfMemory,
    StatusTooLarge,
    TooManyRecords,
    MaterializationTooLarge,
    MissingTerminator,
    InvalidRecord,
    MissingRenamePath,
    InvalidPath,
    UnknownStatus,
};

/// Owns the raw porcelain bytes and exact-size entry storage. `len` may be
/// smaller than `storage.len` after deterministic duplicate compaction; deinit
/// always releases the original allocation.
pub const Index = struct {
    bytes: []u8,
    storage: []Entry,
    len: usize,
    fingerprint: content_fingerprint.Fingerprint,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn entries(self: *const Index) []const Entry {
        return self.storage[0..self.len];
    }

    pub fn kindForPath(self: *const Index, path: []const u8) ?Kind {
        var low: usize = 0;
        var high = self.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const entry = self.storage[middle];
            switch (std.mem.order(u8, entry.path, path)) {
                .lt => low = middle + 1,
                .gt => high = middle,
                .eq => return entry.kind,
            }
        }
        return null;
    }
};

/// Parses and consumes owned porcelain-v1 `-z` bytes. Every failure releases
/// the input so async task cleanup has one terminal regardless of parse phase.
pub fn parseOwned(allocator: std.mem.Allocator, bytes: []u8) ParseError!Index {
    errdefer allocator.free(bytes);
    if (bytes.len > max_bytes) return error.StatusTooLarge;
    const measured = try scan(bytes, null);
    const allocation_bytes = std.math.add(
        usize,
        bytes.len,
        std.math.mul(usize, measured.eligible_count, @sizeOf(Entry)) catch return error.MaterializationTooLarge,
    ) catch return error.MaterializationTooLarge;
    if (allocation_bytes > aggregate_allocation_limit) return error.MaterializationTooLarge;

    const storage = try allocator.alloc(Entry, measured.eligible_count);
    errdefer allocator.free(storage);
    const filled = try scan(bytes, storage);
    std.debug.assert(filled.eligible_count == storage.len);
    std.mem.sort(Entry, storage, {}, entryLessThan);
    const compact_len = compactDuplicates(storage);
    return .{
        .bytes = bytes,
        .storage = storage,
        .len = compact_len,
        .fingerprint = .init(bytes),
    };
}

const ScanResult = struct { eligible_count: usize };

fn scan(bytes: []const u8, output: ?[]Entry) ParseError!ScanResult {
    if (bytes.len > 0 and bytes[bytes.len - 1] != 0) return error.MissingTerminator;
    var offset: usize = 0;
    var record_count: usize = 0;
    var eligible_count: usize = 0;
    while (offset < bytes.len) {
        const field = nextField(bytes, &offset) orelse return error.MissingTerminator;
        if (field.len < 4 or field[2] != ' ') return error.InvalidRecord;
        record_count += 1;
        if (record_count > max_records) return error.TooManyRecords;

        const raw = [2]u8{ field[0], field[1] };
        const path = field[3..];
        repository_path.validate(path) catch return error.InvalidPath;
        if (isRenameOrCopy(raw)) {
            const old_path = nextField(bytes, &offset) orelse return error.MissingRenamePath;
            repository_path.validate(old_path) catch return error.InvalidPath;
        }
        if (try classify(raw)) |kind| {
            if (output) |entries| entries[eligible_count] = .{ .path = path, .kind = kind };
            eligible_count += 1;
        }
    }
    return .{ .eligible_count = eligible_count };
}

fn nextField(bytes: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= bytes.len) return null;
    const start = offset.*;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse return null;
    offset.* = end + 1;
    return bytes[start..end];
}

fn isRenameOrCopy(raw: [2]u8) bool {
    return raw[0] == 'R' or raw[0] == 'C' or raw[1] == 'R' or raw[1] == 'C';
}

/// Eligibility is decided before color. The exact unmerged table cannot be
/// inferred with normal X/Y column rules (`UD`, for example, has a current
/// conflict object despite containing `D`). Unknown pairs fail the whole
/// optional index instead of guessing whether a current file exists.
fn classify(raw: [2]u8) ParseError!?Kind {
    if (raw[0] == '?' and raw[1] == '?') return .added;
    if (raw[0] == '!' and raw[1] == '!') return null;

    if (unmergedClassification(raw)) |classification| return switch (classification) {
        .excluded => null,
        .kind => |kind| kind,
    };
    if (containsUnmergedCode(raw)) return error.UnknownStatus;

    if (raw[1] == 'D' and std.mem.indexOfScalar(u8, " MTADRC", raw[0]) != null) return null;
    if (raw[0] == 'D' and raw[1] == ' ') return null;

    if (raw[0] == ' ') return switch (raw[1]) {
        'A', 'C' => .added,
        'M', 'T', 'R' => .modified,
        else => error.UnknownStatus,
    };
    if (raw[0] == 'A' or raw[0] == 'C') return switch (raw[1]) {
        ' ', 'M', 'T' => .added,
        else => error.UnknownStatus,
    };
    if (raw[0] == 'M' or raw[0] == 'T' or raw[0] == 'R') return switch (raw[1]) {
        ' ', 'M', 'T' => .modified,
        else => error.UnknownStatus,
    };
    return error.UnknownStatus;
}

const UnmergedClassification = union(enum) {
    excluded,
    kind: Kind,
};

fn unmergedClassification(raw: [2]u8) ?UnmergedClassification {
    const code = (@as(u16, raw[0]) << 8) | raw[1];
    return switch (code) {
        (@as(u16, 'D') << 8) | 'D' => .excluded,
        (@as(u16, 'A') << 8) | 'U',
        (@as(u16, 'U') << 8) | 'D',
        (@as(u16, 'U') << 8) | 'A',
        (@as(u16, 'D') << 8) | 'U',
        (@as(u16, 'A') << 8) | 'A',
        (@as(u16, 'U') << 8) | 'U',
        => .{ .kind = .modified },
        else => null,
    };
}

fn containsUnmergedCode(raw: [2]u8) bool {
    return raw[0] == 'U' or raw[1] == 'U' or
        (raw[0] == 'D' and raw[1] == 'D') or
        (raw[0] == 'A' and raw[1] == 'A');
}

fn entryLessThan(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn compactDuplicates(entries: []Entry) usize {
    var length: usize = 0;
    for (entries) |entry| {
        if (length > 0 and std.mem.eql(u8, entries[length - 1].path, entry.path)) {
            if (entry.kind == .modified) entries[length - 1].kind = .modified;
            continue;
        }
        entries[length] = entry;
        length += 1;
    }
    return length;
}

test "repository change index classifies the complete documented XY groups" {
    var expected = [_]u8{0} ** (256 * 256);
    const mark = struct {
        fn one(table: []u8, raw: [2]u8, value: u8) void {
            table[@as(usize, raw[0]) * 256 + raw[1]] = value;
        }
    }.one;
    mark(&expected, .{ '?', '?' }, 2);
    mark(&expected, .{ '!', '!' }, 1);
    mark(&expected, .{ 'D', 'D' }, 1);
    for ([_][2]u8{ .{ 'A', 'U' }, .{ 'U', 'D' }, .{ 'U', 'A' }, .{ 'D', 'U' }, .{ 'A', 'A' }, .{ 'U', 'U' } }) |raw| mark(&expected, raw, 3);
    for ([_]u8{ 'A', 'C' }) |y| mark(&expected, .{ ' ', y }, 2);
    for ([_]u8{ 'M', 'T', 'R' }) |y| mark(&expected, .{ ' ', y }, 3);
    for ([_]u8{ 'A', 'C' }) |x| for ([_]u8{ ' ', 'M', 'T' }) |y| mark(&expected, .{ x, y }, 2);
    for ([_]u8{ 'M', 'T', 'R' }) |x| for ([_]u8{ ' ', 'M', 'T' }) |y| mark(&expected, .{ x, y }, 3);
    for ([_]u8{ ' ', 'A', 'M', 'T', 'R', 'C', 'D' }) |x| mark(&expected, .{ x, 'D' }, 1);
    mark(&expected, .{ 'D', ' ' }, 1);

    for (0..256) |x| for (0..256) |y| {
        const raw = [2]u8{ @intCast(x), @intCast(y) };
        const actual = classify(raw);
        switch (expected[x * 256 + y]) {
            0 => try std.testing.expectError(error.UnknownStatus, actual),
            1 => try std.testing.expect((try actual) == null),
            2 => try std.testing.expectEqual(Kind.added, (try actual).?),
            3 => try std.testing.expectEqual(Kind.modified, (try actual).?),
            else => unreachable,
        }
    };
}

test "repository change index owns exact paths and merges duplicate kinds" {
    const allocator = std.testing.allocator;
    var index = try parseOwned(allocator, try allocator.dupe(u8, "?? a/path\x00" ++
        " M a/path\x00" ++
        " R new-path\x00old-path\x00" ++
        "?? opaque-\xff\x00" ++
        "?? --leading\x00" ++
        "?? :(magic)\x00" ++
        "?? line\nname\x00"));
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 6), index.entries().len);
    try std.testing.expectEqual(Kind.modified, index.kindForPath("a/path").?);
    try std.testing.expectEqual(Kind.modified, index.kindForPath("new-path").?);
    try std.testing.expectEqual(Kind.added, index.kindForPath("opaque-\xff").?);
    try std.testing.expectEqual(Kind.added, index.kindForPath("--leading").?);
    try std.testing.expectEqual(Kind.added, index.kindForPath(":(magic)").?);
    try std.testing.expectEqual(Kind.added, index.kindForPath("line\nname").?);
    try std.testing.expect(index.kindForPath("old-path") == null);
}

test "repository change index excludes no-current-file records before duplicate merge" {
    const allocator = std.testing.allocator;
    var index = try parseOwned(allocator, try allocator.dupe(u8, "AD added-deleted\x00" ++
        "MD modified-deleted\x00" ++
        "D  recreated\x00" ++
        "?? recreated\x00" ++
        "DD both-deleted\x00"));
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), index.entries().len);
    try std.testing.expectEqual(Kind.added, index.kindForPath("recreated").?);
}

test "repository change index consumes malformed and missing rename owners" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.MissingTerminator, parseOwned(allocator, try allocator.dupe(u8, " M path")));
    try std.testing.expectError(error.MissingRenamePath, parseOwned(allocator, try allocator.dupe(u8, "R  new\x00")));
    try std.testing.expectError(error.InvalidPath, parseOwned(allocator, try allocator.dupe(u8, " M ../escape\x00")));
}

const AllocationFixture = struct {
    fn exercise(allocator: std.mem.Allocator) !void {
        var index = try parseOwned(allocator, try allocator.dupe(u8, " A intent\x00 M tracked\x00"));
        defer index.deinit(allocator);
    }
};

test "repository change index releases every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, AllocationFixture.exercise, .{});
}

test "repository change index declared maximum fits aggregate ceiling" {
    try std.testing.expect(max_bytes + max_records * @sizeOf(Entry) <= aggregate_allocation_limit);
}
