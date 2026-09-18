//! Bounded, allocation-free names persisted by Review Store schema version 1.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const local_time = @import("../local_time.zig");

pub const max_repository_display_bytes: usize = 246;
pub const max_target_label_bytes: usize = 232;
pub const max_component_bytes: usize = 255;

pub const RepositoryNameError = error{InvalidRepositoryName};
pub const RunNameError = error{ InvalidTargetLabel, LocalTimeUnavailable, InvalidRunName };

pub const RepositoryDisplayName = struct {
    bytes: [max_repository_display_bytes]u8 = undefined,
    len: u8,

    /// Build the creation-time display name from Git's main-worktree basename.
    /// Only trailing ASCII hyphens are removed.
    pub fn fromMainWorktreeBasename(raw: []const u8) RepositoryNameError!RepositoryDisplayName {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidRepositoryName;
        if (std.mem.indexOfScalar(u8, raw, '/') != null) return error.InvalidRepositoryName;
        for (raw) |byte| if (byte <= 0x1f or byte == 0x7f) return error.InvalidRepositoryName;

        var end = raw.len;
        while (end > 0 and raw[end - 1] == '-') end -= 1;
        return fromStored(raw[0..end]);
    }

    /// Admit the exact persisted spelling. A stored trailing hyphen is not
    /// canonical and is rejected instead of normalized.
    pub fn fromStored(raw: []const u8) RepositoryNameError!RepositoryDisplayName {
        if (raw.len == 0 or raw.len > max_repository_display_bytes) return error.InvalidRepositoryName;
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidRepositoryName;
        if (std.mem.indexOfScalar(u8, raw, '/') != null) return error.InvalidRepositoryName;
        for (raw) |byte| if (byte <= 0x1f or byte == 0x7f) return error.InvalidRepositoryName;
        if (raw[raw.len - 1] == '-' or
            std.mem.eql(u8, raw, ".") or
            std.mem.eql(u8, raw, "..")) return error.InvalidRepositoryName;

        var result: RepositoryDisplayName = .{ .len = @intCast(raw.len) };
        @memcpy(result.bytes[0..raw.len], raw);
        return result;
    }

    pub fn slice(self: *const RepositoryDisplayName) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const RepositoryDisplayName, other: *const RepositoryDisplayName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const RepositoryDirectoryName = struct {
    bytes: [max_component_bytes]u8 = undefined,
    len: u8,

    pub fn format(
        display: *const RepositoryDisplayName,
        repository_id: committed_review.ReviewRepositoryId,
    ) RepositoryDirectoryName {
        var result: RepositoryDirectoryName = .{ .len = @intCast(display.len + 9) };
        @memcpy(result.bytes[0..display.len], display.slice());
        result.bytes[display.len] = '-';
        const canonical = repository_id.canonical();
        @memcpy(result.bytes[display.len + 1 ..][0..8], canonical[0..8]);
        return result;
    }

    pub fn fromStored(
        raw: []const u8,
        display: *const RepositoryDisplayName,
        repository_id: committed_review.ReviewRepositoryId,
    ) RepositoryNameError!RepositoryDirectoryName {
        const expected = format(display, repository_id);
        if (!std.mem.eql(u8, raw, expected.slice())) return error.InvalidRepositoryName;
        return expected;
    }

    pub fn slice(self: *const RepositoryDirectoryName) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const RepositoryDirectoryName, other: *const RepositoryDirectoryName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// The exact local calendar minute captured when one Run name is fixed.
pub const LocalCalendarMinute = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,

    pub fn fromUnixSeconds(unix_seconds: i64) RunNameError!LocalCalendarMinute {
        return fromLocalCalendar(local_time.fromUnixSeconds(unix_seconds) orelse
            return error.LocalTimeUnavailable);
    }

    fn fromLocalCalendar(calendar: local_time.CalendarSecond) RunNameError!LocalCalendarMinute {
        const value: LocalCalendarMinute = .{
            .year = calendar.year,
            .month = calendar.month,
            .day = calendar.day,
            .hour = calendar.hour,
            .minute = calendar.minute,
        };
        value.validate() catch return error.LocalTimeUnavailable;
        return value;
    }

    fn parseStored(raw: []const u8) RunNameError!LocalCalendarMinute {
        if (raw.len != 13 or raw[8] != '-') return error.InvalidRunName;
        const value: LocalCalendarMinute = .{
            .year = fixedDecimal(u16, raw[0..4]) catch return error.InvalidRunName,
            .month = fixedDecimal(u8, raw[4..6]) catch return error.InvalidRunName,
            .day = fixedDecimal(u8, raw[6..8]) catch return error.InvalidRunName,
            .hour = fixedDecimal(u8, raw[9..11]) catch return error.InvalidRunName,
            .minute = fixedDecimal(u8, raw[11..13]) catch return error.InvalidRunName,
        };
        value.validate() catch return error.InvalidRunName;
        return value;
    }

    fn validate(self: LocalCalendarMinute) error{InvalidCalendarMinute}!void {
        if (self.year == 0 or self.year > 9999 or self.month == 0 or self.month > 12 or
            self.hour > 23 or self.minute > 59) return error.InvalidCalendarMinute;
        const days = [_]u8{ 31, if (isLeapYear(self.year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        if (self.day == 0 or self.day > days[self.month - 1]) return error.InvalidCalendarMinute;
    }

    fn format(self: LocalCalendarMinute) [13]u8 {
        self.validate() catch unreachable;
        var result: [13]u8 = undefined;
        _ = std.fmt.bufPrint(&result, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}", .{
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
        }) catch unreachable;
        return result;
    }
};

/// Canonical target-label bytes used only as one Run path component segment.
pub const TargetLabel = struct {
    bytes: [max_target_label_bytes]u8 = undefined,
    len: u8,

    /// Transform only slash runs and component-edge ASCII hyphens. A present
    /// invalid label never falls back to target identity.
    pub fn fromSaved(raw: []const u8) RunNameError!TargetLabel {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidTargetLabel;
        for (raw) |byte| if (byte <= 0x1f or byte == 0x7f) return error.InvalidTargetLabel;

        var result: TargetLabel = .{ .len = 0 };
        var pending_hyphens: usize = 0;
        var index: usize = 0;
        while (index < raw.len) {
            if (raw[index] == '/') {
                while (index < raw.len and raw[index] == '/') index += 1;
                if (result.len != 0) pending_hyphens += 1;
                continue;
            }
            if (raw[index] == '-') {
                if (result.len != 0) pending_hyphens += 1;
                index += 1;
                continue;
            }
            const sequence_len = std.unicode.utf8ByteSequenceLength(raw[index]) catch
                return error.InvalidTargetLabel;
            const required = @as(usize, result.len) + pending_hyphens + sequence_len;
            if (required > max_target_label_bytes) return error.InvalidTargetLabel;
            @memset(result.bytes[result.len..][0..pending_hyphens], '-');
            result.len += @intCast(pending_hyphens);
            @memcpy(result.bytes[result.len..][0..sequence_len], raw[index..][0..sequence_len]);
            result.len += @intCast(sequence_len);
            pending_hyphens = 0;
            index += sequence_len;
        }
        return validateTargetLabel(result);
    }

    pub fn fromHeadObjectId(head: *const committed_review.ObjectId) TargetLabel {
        var result: TargetLabel = .{ .len = 14 };
        @memcpy(result.bytes[0..7], "commit-");
        @memcpy(result.bytes[7..14], head.short());
        return result;
    }

    pub fn fromStored(raw: []const u8) RunNameError!TargetLabel {
        if (raw.len == 0 or raw.len > max_target_label_bytes or
            !std.unicode.utf8ValidateSlice(raw) or
            std.mem.indexOfScalar(u8, raw, '/') != null or
            raw[0] == '-' or raw[raw.len - 1] == '-') return error.InvalidTargetLabel;
        for (raw) |byte| if (byte <= 0x1f or byte == 0x7f) return error.InvalidTargetLabel;
        var result: TargetLabel = .{ .len = @intCast(raw.len) };
        @memcpy(result.bytes[0..raw.len], raw);
        return validateTargetLabel(result);
    }

    pub fn slice(self: *const TargetLabel) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const RunDirectoryName = struct {
    bytes: [max_component_bytes]u8 = undefined,
    len: u8,

    pub fn format(
        minute: LocalCalendarMinute,
        label: *const TargetLabel,
        review_id: committed_review.ReviewId,
    ) RunDirectoryName {
        const local_text = minute.format();
        const id = review_id.canonical();
        var result: RunDirectoryName = .{ .len = @intCast(local_text.len + 1 + label.len + 1 + 8) };
        var cursor: usize = 0;
        @memcpy(result.bytes[cursor..][0..local_text.len], &local_text);
        cursor += local_text.len;
        result.bytes[cursor] = '-';
        cursor += 1;
        @memcpy(result.bytes[cursor..][0..label.len], label.slice());
        cursor += label.len;
        result.bytes[cursor] = '-';
        cursor += 1;
        @memcpy(result.bytes[cursor..][0..8], id[0..8]);
        return result;
    }

    /// Admit the persisted component without recomputing local time or label.
    pub fn fromStored(raw: []const u8, review_id: committed_review.ReviewId) RunNameError!RunDirectoryName {
        try admitCandidate(raw);
        const id = review_id.canonical();
        if (!std.mem.eql(u8, raw[raw.len - 8 ..], id[0..8])) return error.InvalidRunName;
        var result: RunDirectoryName = .{ .len = @intCast(raw.len) };
        @memcpy(result.bytes[0..raw.len], raw);
        return result;
    }

    pub fn slice(self: *const RunDirectoryName) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const RunDirectoryName, other: *const RunDirectoryName) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    pub fn admitCandidate(raw: []const u8) RunNameError!void {
        if (raw.len < 24 or raw.len > max_component_bytes or !std.unicode.utf8ValidateSlice(raw)) {
            return error.InvalidRunName;
        }
        _ = LocalCalendarMinute.parseStored(raw[0..13]) catch return error.InvalidRunName;
        if (raw[13] != '-' or raw[raw.len - 9] != '-') return error.InvalidRunName;
        _ = TargetLabel.fromStored(raw[14 .. raw.len - 9]) catch return error.InvalidRunName;
        for (raw[raw.len - 8 ..]) |byte| {
            if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) {
                return error.InvalidRunName;
            }
        }
    }
};

fn validateTargetLabel(value: TargetLabel) RunNameError!TargetLabel {
    const raw = value.slice();
    if (raw.len == 0 or std.mem.eql(u8, raw, ".") or std.mem.eql(u8, raw, "..")) {
        return error.InvalidTargetLabel;
    }
    return value;
}

fn fixedDecimal(comptime T: type, raw: []const u8) !T {
    for (raw) |byte| if (byte < '0' or byte > '9') return error.InvalidDecimal;
    return std.fmt.parseInt(T, raw, 10);
}

fn isLeapYear(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

test "review repository name trims only trailing hyphens and keeps UTF-8 case" {
    const display = try RepositoryDisplayName.fromMainWorktreeBasename("GitFrame-枝---");
    try std.testing.expectEqualStrings("GitFrame-枝", display.slice());
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const directory = RepositoryDirectoryName.format(&display, repository_id);
    try std.testing.expectEqualStrings("GitFrame-枝-123e4567", directory.slice());
    const parsed = try RepositoryDirectoryName.fromStored(directory.slice(), &display, repository_id);
    try std.testing.expect(directory.eql(&parsed));
}

test "review repository name rejects malformed and noncanonical values without repair" {
    const invalid = [_][]const u8{ "", "-", "---", ".", "..", "repo/name", "repo\n", "repo\x7f", "bad\xff" };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidRepositoryName, RepositoryDisplayName.fromMainWorktreeBasename(value));
    }
    try std.testing.expectError(error.InvalidRepositoryName, RepositoryDisplayName.fromStored("repo-"));
}

test "review repository name enforces exact 246 and 255 byte boundaries" {
    var maximum = [_]u8{'a'} ** max_repository_display_bytes;
    const display = try RepositoryDisplayName.fromMainWorktreeBasename(&maximum);
    const repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const directory = RepositoryDirectoryName.format(&display, repository_id);
    try std.testing.expectEqual(max_component_bytes, directory.slice().len);

    var oversized = [_]u8{'a'} ** (max_repository_display_bytes + 1);
    try std.testing.expectError(error.InvalidRepositoryName, RepositoryDisplayName.fromMainWorktreeBasename(&oversized));
}

test "review run name applies only the specified target-label formatting" {
    const label = try TargetLabel.fromSaved("--Feature//API/枝---");
    try std.testing.expectEqualStrings("Feature-API-枝", label.slice());
    const review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    const name = RunDirectoryName.format(.{ .year = 2026, .month = 9, .day = 11, .hour = 8, .minute = 37 }, &label, review_id);
    try std.testing.expectEqualStrings("20260911-0837-Feature-API-枝-123e4567", name.slice());
    const stored = try RunDirectoryName.fromStored(name.slice(), review_id);
    try std.testing.expect(name.eql(&stored));
}

test "review run name rejects present-invalid labels without fallback or truncation" {
    const invalid = [_][]const u8{ "", "-", "---", "/", "///", ".", "..", "bad\n", "bad\x7f", "bad\xff" };
    for (invalid) |value| {
        try std.testing.expectError(error.InvalidTargetLabel, TargetLabel.fromSaved(value));
    }
    var maximum = [_]u8{'a'} ** max_target_label_bytes;
    const exact = try TargetLabel.fromSaved(&maximum);
    try std.testing.expectEqual(max_target_label_bytes, exact.slice().len);
    var oversized = [_]u8{'a'} ** (max_target_label_bytes + 1);
    try std.testing.expectError(error.InvalidTargetLabel, TargetLabel.fromSaved(&oversized));
}

test "review run name trims arbitrarily long component-edge hyphens before its byte limit" {
    var raw = [_]u8{'-'} ** 300;
    raw[299] = 'x';
    const label = try TargetLabel.fromSaved(&raw);
    try std.testing.expectEqualStrings("x", label.slice());
}

test "review run name uses fixed target only when the saved label is absent" {
    const oid = try committed_review.ObjectId.parse(.sha1, "235d9d8aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const label = TargetLabel.fromHeadObjectId(&oid);
    try std.testing.expectEqualStrings("commit-235d9d8", label.slice());
}

test "review run name maps the sampled local calendar fields once" {
    var calendar: local_time.CalendarSecond = .{
        .year = 2026,
        .month = 9,
        .day = 13,
        .hour = 19,
        .minute = 42,
        .second = 17,
        .utc_offset_minutes = 9 * 60,
    };
    const minute = try LocalCalendarMinute.fromLocalCalendar(calendar);
    try std.testing.expectEqualStrings("20260913-1942", &minute.format());
    calendar.day = 31;
    calendar.month = 2;
    try std.testing.expectError(error.LocalTimeUnavailable, LocalCalendarMinute.fromLocalCalendar(calendar));
}

test "review run stored component validates calendar label and complete ID suffix relation" {
    const review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000");
    try std.testing.expectError(error.InvalidRunName, RunDirectoryName.fromStored("20260229-0837-feature-123e4567", review_id));
    try std.testing.expectError(error.InvalidRunName, RunDirectoryName.fromStored("20260911-2460-feature-123e4567", review_id));
    try std.testing.expectError(error.InvalidRunName, RunDirectoryName.fromStored("20260911-0837-feature-deadbeef", review_id));
    try std.testing.expectError(error.InvalidRunName, RunDirectoryName.fromStored("20260911-0837--123e4567", review_id));
}
