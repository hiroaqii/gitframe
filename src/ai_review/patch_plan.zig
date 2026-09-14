//! Strict span-preserving parser for committed Git patch payloads.
//!
//! This parser exists beside the display diff parser because AI review needs
//! a stronger property: every input byte is either admitted into exactly one
//! coverage span or the complete plan is rejected. Raw repository paths stay
//! byte-exact while every model-facing text value is bounded UTF-8.

const std = @import("std");
const limits = @import("limits.zig");
const protocol = @import("protocol.zig");
const target_mod = @import("../committed_review/target.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidPatch,
    InvalidPath,
    UnsupportedCombinedDiff,
    UnsupportedBinary,
    UnsupportedFileType,
    UnsupportedContent,
    MetadataOnly,
    LimitExceeded,
    ReviewLineTooLarge,
};

pub const ByteSpan = struct {
    start: u32,
    end_exclusive: u32,

    pub fn len(self: ByteSpan) usize {
        return self.end_exclusive - self.start;
    }
};

pub const Line = struct {
    kind: protocol.DiffLineKind,
    text: []const u8,
    line_ending: protocol.LineEnding,
};

pub const Hunk = struct {
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    section: ?[]const u8,
    lines: []const Line,
    coverage: ByteSpan,
};

pub const File = struct {
    old_path: ?[]const u8,
    new_path: ?[]const u8,
    display_path: []const u8,
    status: protocol.FileStatus,
    metadata_lines: []const []const u8,
    /// Exact file prefix from `diff --git` through the byte before the first
    /// hunk. It is covered only by the file's first unit.
    metadata_coverage: ByteSpan,
    hunks: []const Hunk,
};

pub const Plan = struct {
    files: []const File,
    patch_size: u32,
    hunk_count: u16,
};

const RawLine = struct {
    text: []const u8,
    start: usize,
    end_exclusive: usize,
};

const HunkRange = struct {
    start: u32,
    count: u32,
};

const HunkHeader = struct {
    old: HunkRange,
    new: HunkRange,
    section: ?[]const u8,
};

const git_quote_policy_literal_non_ascii: u2 = 0b01;
const git_quote_policy_octal_non_ascii: u2 = 0b10;
const git_quote_policy_all: u2 = git_quote_policy_literal_non_ascii | git_quote_policy_octal_non_ascii;

const MetadataKind = enum {
    diff_header,
    old_mode,
    new_mode,
    new_file_mode,
    deleted_file_mode,
    index,
    similarity_index,
    dissimilarity_index,
    rename_from,
    rename_to,
    copy_from,
    copy_to,
    old_marker,
    new_marker,
};

const IndexInfo = struct {
    old_zero: bool,
    new_zero: bool,
    oids_equal: bool,
    has_mode: bool,
};

const FileBuilder = struct {
    start: usize,
    diff_header: []const u8,
    old_path: ?[]const u8 = null,
    new_path: ?[]const u8 = null,
    saw_old_header: bool = false,
    saw_new_header: bool = false,
    renamed: bool = false,
    copied: bool = false,
    rename_from: ?[]const u8 = null,
    rename_to: ?[]const u8 = null,
    copy_from: ?[]const u8 = null,
    copy_to: ?[]const u8 = null,
    old_mode: ?[]const u8 = null,
    new_mode: ?[]const u8 = null,
    index_info: ?IndexInfo = null,
    first_hunk_start: ?usize = null,
    metadata: std.ArrayList([]const u8) = .empty,
    metadata_kinds: std.ArrayList(MetadataKind) = .empty,
    hunks: std.ArrayList(Hunk) = .empty,
};

const HunkBuilder = struct {
    start: usize,
    old_start: u32,
    old_count: u32,
    new_start: u32,
    new_count: u32,
    old_seen: u32 = 0,
    new_seen: u32 = 0,
    section: ?[]const u8,
    lines: std.ArrayList(Line) = .empty,

    fn complete(self: HunkBuilder) bool {
        return self.old_seen == self.old_count and self.new_seen == self.new_count;
    }
};

const Parser = struct {
    allocator: std.mem.Allocator,
    object_format: target_mod.ObjectFormat,
    patch: []const u8,
    violation: *?limits.Violation,
    files: std.ArrayList(File) = .empty,
    file: ?FileBuilder = null,
    hunk: ?HunkBuilder = null,
    hunk_count: usize = 0,
    quote_policy_mask: u2 = git_quote_policy_all,

    fn parse(self: *Parser) Error!Plan {
        if (self.patch.len > limits.max_projection_bytes or self.patch.len > std.math.maxInt(u32)) {
            limits.record(self.violation, "projection_bytes", self.patch.len, limits.max_projection_bytes);
            return error.LimitExceeded;
        }
        if (self.patch.len == 0) return .{ .files = &.{}, .patch_size = 0, .hunk_count = 0 };

        var offset: usize = 0;
        while (offset < self.patch.len) {
            const lf = std.mem.indexOfScalarPos(u8, self.patch, offset, '\n') orelse return error.InvalidPatch;
            const raw: RawLine = .{
                .text = self.patch[offset..lf],
                .start = offset,
                .end_exclusive = lf + 1,
            };
            try self.parseLine(raw);
            offset = lf + 1;
        }
        try self.finishHunk(self.patch.len);
        try self.finishFile();
        if (self.files.items.len > limits.max_changed_files) {
            limits.record(self.violation, "changed_files", self.files.items.len, limits.max_changed_files);
            return error.LimitExceeded;
        }
        return .{
            .files = try self.files.toOwnedSlice(self.allocator),
            .patch_size = @intCast(self.patch.len),
            .hunk_count = @intCast(self.hunk_count),
        };
    }

    fn parseLine(self: *Parser, raw: RawLine) Error!void {
        const line = raw.text;
        if (std.mem.startsWith(u8, line, "diff --cc ") or
            std.mem.startsWith(u8, line, "diff --combined ") or
            std.mem.startsWith(u8, line, "@@@ ")) return error.UnsupportedCombinedDiff;

        if (std.mem.startsWith(u8, line, "diff --git ")) {
            try self.finishHunk(raw.start);
            try self.finishFile();
            if (self.files.items.len == limits.max_changed_files) {
                limits.record(self.violation, "changed_files", self.files.items.len + 1, limits.max_changed_files);
                return error.LimitExceeded;
            }
            self.file = .{
                .start = raw.start,
                .diff_header = line,
            };
            try self.appendMetadata(line, .diff_header);
            return;
        }

        if (self.file == null) return error.InvalidPatch;
        if (std.mem.startsWith(u8, line, "@@ ")) {
            try self.finishHunk(raw.start);
            const header = try parseHunkHeader(line, self.violation);
            if (self.file.?.first_hunk_start == null) self.file.?.first_hunk_start = raw.start;
            if (self.hunk_count == limits.max_hunks) {
                limits.record(self.violation, "hunks", self.hunk_count + 1, limits.max_hunks);
                return error.LimitExceeded;
            }
            self.hunk_count += 1;
            self.hunk = .{
                .start = raw.start,
                .old_start = header.old.start,
                .old_count = header.old.count,
                .new_start = header.new.start,
                .new_count = header.new.count,
                .section = header.section,
            };
            return;
        }

        if (self.hunk) |*hunk| {
            if (std.mem.eql(u8, line, "\\ No newline at end of file")) {
                if (hunk.lines.items.len == 0) return error.InvalidPatch;
                const previous = &hunk.lines.items[hunk.lines.items.len - 1];
                if (previous.line_ending == .none) return error.InvalidPatch;
                // If the patch-only separator followed a bare CR byte, the
                // protocol cannot represent that byte as either safe text or
                // a CRLF terminator once Git says no newline exists.
                if (previous.line_ending == .crlf) return error.UnsupportedContent;
                previous.line_ending = .none;
                return;
            }
            if (hunk.complete()) return error.InvalidPatch;
            try self.appendContentLine(line);
            return;
        }

        try self.parseMetadata(line);
    }

    fn parseMetadata(self: *Parser, line: []const u8) Error!void {
        if (std.mem.startsWith(u8, line, "Binary files ") or
            std.mem.eql(u8, line, "GIT binary patch")) return error.UnsupportedBinary;

        const kind: MetadataKind = blk: {
            if (std.mem.startsWith(u8, line, "--- ")) {
                if (self.file.?.saw_old_header) return error.InvalidPatch;
                self.file.?.saw_old_header = true;
                self.file.?.old_path = try parseFileMarkerPath(self.allocator, line[4..], "a/", self.violation, &self.quote_policy_mask);
                break :blk .old_marker;
            } else if (std.mem.startsWith(u8, line, "+++ ")) {
                if (!self.file.?.saw_old_header or self.file.?.saw_new_header) return error.InvalidPatch;
                self.file.?.saw_new_header = true;
                self.file.?.new_path = try parseFileMarkerPath(self.allocator, line[4..], "b/", self.violation, &self.quote_policy_mask);
                break :blk .new_marker;
            } else if (std.mem.startsWith(u8, line, "rename from ")) {
                if (self.file.?.renamed or self.file.?.copied) return error.InvalidPatch;
                self.file.?.renamed = true;
                self.file.?.rename_from = try parseRepositoryPath(self.allocator, line[12..], self.violation, &self.quote_policy_mask);
                break :blk .rename_from;
            } else if (std.mem.startsWith(u8, line, "rename to ")) {
                if (!self.file.?.renamed or self.file.?.rename_to != null) return error.InvalidPatch;
                self.file.?.rename_to = try parseRepositoryPath(self.allocator, line[10..], self.violation, &self.quote_policy_mask);
                break :blk .rename_to;
            } else if (std.mem.startsWith(u8, line, "copy from ")) {
                if (self.file.?.renamed or self.file.?.copied) return error.InvalidPatch;
                self.file.?.copied = true;
                self.file.?.copy_from = try parseRepositoryPath(self.allocator, line[10..], self.violation, &self.quote_policy_mask);
                break :blk .copy_from;
            } else if (std.mem.startsWith(u8, line, "copy to ")) {
                if (!self.file.?.copied or self.file.?.copy_to != null) return error.InvalidPatch;
                self.file.?.copy_to = try parseRepositoryPath(self.allocator, line[8..], self.violation, &self.quote_policy_mask);
                break :blk .copy_to;
            } else if (std.mem.startsWith(u8, line, "old mode ")) {
                if (self.file.?.old_mode != null) return error.InvalidPatch;
                try validateMode(line[9..]);
                self.file.?.old_mode = line[9..];
                break :blk .old_mode;
            } else if (std.mem.startsWith(u8, line, "new mode ")) {
                if (self.file.?.new_mode != null) return error.InvalidPatch;
                try validateMode(line[9..]);
                self.file.?.new_mode = line[9..];
                break :blk .new_mode;
            } else if (std.mem.startsWith(u8, line, "new file mode ")) {
                try validateMode(line[14..]);
                break :blk .new_file_mode;
            } else if (std.mem.startsWith(u8, line, "deleted file mode ")) {
                try validateMode(line[18..]);
                break :blk .deleted_file_mode;
            } else if (std.mem.startsWith(u8, line, "index ")) {
                if (self.file.?.index_info != null) return error.InvalidPatch;
                self.file.?.index_info = try parseIndexInfo(self.object_format, line);
                break :blk .index;
            } else if (std.mem.startsWith(u8, line, "similarity index ")) {
                try validatePercentMetadata(line, "similarity index ");
                break :blk .similarity_index;
            } else if (std.mem.startsWith(u8, line, "dissimilarity index ")) {
                try validatePercentMetadata(line, "dissimilarity index ");
                break :blk .dissimilarity_index;
            }
            return error.InvalidPatch;
        };
        try self.appendMetadata(line, kind);
    }

    fn appendMetadata(self: *Parser, line: []const u8, kind: MetadataKind) Error!void {
        if (self.file.?.metadata.items.len == limits.max_metadata_lines_per_unit) {
            limits.record(self.violation, "metadata_lines_per_unit", self.file.?.metadata.items.len + 1, limits.max_metadata_lines_per_unit);
            return error.LimitExceeded;
        }
        try self.file.?.metadata.append(self.allocator, try safeModelText(self.allocator, line, limits.max_metadata_line_bytes, "metadata_line_bytes", self.violation));
        try self.file.?.metadata_kinds.append(self.allocator, kind);
    }

    fn appendContentLine(self: *Parser, raw: []const u8) Error!void {
        if (raw.len == 0) return error.InvalidPatch;
        var text = raw[1..];
        var ending: protocol.LineEnding = .lf;
        if (text.len > 0 and text[text.len - 1] == '\r') {
            text = text[0 .. text.len - 1];
            ending = .crlf;
        }
        if (text.len > limits.max_diff_line_bytes) {
            limits.record(self.violation, "diff_line_bytes", text.len, limits.max_diff_line_bytes);
            return error.ReviewLineTooLarge;
        }
        try validateContentText(text);
        const kind: protocol.DiffLineKind = switch (raw[0]) {
            ' ' => .context,
            '-' => .removed,
            '+' => .added,
            else => return error.InvalidPatch,
        };
        const hunk = &self.hunk.?;
        switch (kind) {
            .context => {
                hunk.old_seen = std.math.add(u32, hunk.old_seen, 1) catch return error.InvalidPatch;
                hunk.new_seen = std.math.add(u32, hunk.new_seen, 1) catch return error.InvalidPatch;
            },
            .removed => hunk.old_seen = std.math.add(u32, hunk.old_seen, 1) catch return error.InvalidPatch,
            .added => hunk.new_seen = std.math.add(u32, hunk.new_seen, 1) catch return error.InvalidPatch,
        }
        if (hunk.old_seen > hunk.old_count or hunk.new_seen > hunk.new_count) return error.InvalidPatch;
        if (hunk.lines.items.len == limits.max_lines_per_unit) {
            limits.record(self.violation, "lines_per_unit", hunk.lines.items.len + 1, limits.max_lines_per_unit);
            return error.LimitExceeded;
        }
        try hunk.lines.append(self.allocator, .{ .kind = kind, .text = text, .line_ending = ending });
    }

    fn finishHunk(self: *Parser, end: usize) Error!void {
        if (self.hunk) |*hunk| {
            if (!hunk.complete() or hunk.lines.items.len == 0) return error.InvalidPatch;
            if (end <= hunk.start) return error.InvalidPatch;
            try self.file.?.hunks.append(self.allocator, .{
                .old_start = hunk.old_start,
                .old_count = hunk.old_count,
                .new_start = hunk.new_start,
                .new_count = hunk.new_count,
                .section = hunk.section,
                .lines = try hunk.lines.toOwnedSlice(self.allocator),
                .coverage = .{ .start = @intCast(hunk.start), .end_exclusive = @intCast(end) },
            });
        }
        self.hunk = null;
    }

    fn finishFile(self: *Parser) Error!void {
        if (self.file) |*file| {
            if (!file.saw_old_header or !file.saw_new_header or file.first_hunk_start == null or file.hunks.items.len == 0) {
                return error.MetadataOnly;
            }
            try validateHunkSequence(file.hunks.items);
            const status = try resolveFileIdentity(file);
            try validateCanonicalFileRecord(file, status);
            try admitDiffHeader(file, &self.quote_policy_mask);
            const display_source = file.new_path orelse file.old_path orelse return error.InvalidPatch;
            const metadata_end = file.first_hunk_start.?;
            if (metadata_end <= file.start) return error.InvalidPatch;
            try self.files.append(self.allocator, .{
                .old_path = file.old_path,
                .new_path = file.new_path,
                .display_path = try displayPath(self.allocator, display_source, self.violation),
                .status = status,
                .metadata_lines = try file.metadata.toOwnedSlice(self.allocator),
                .metadata_coverage = .{ .start = @intCast(file.start), .end_exclusive = @intCast(metadata_end) },
                .hunks = try file.hunks.toOwnedSlice(self.allocator),
            });
        }
        self.file = null;
    }
};

const SourcePosition = struct {
    line: u64,
    after_line: bool,
};

fn rangeFirst(range: HunkRange) SourcePosition {
    return .{ .line = range.start, .after_line = range.count == 0 };
}

fn rangeLast(range: HunkRange) SourcePosition {
    if (range.count == 0) return rangeFirst(range);
    return .{ .line = @as(u64, range.start) + range.count - 1, .after_line = false };
}

fn positionBefore(left: SourcePosition, right: SourcePosition) bool {
    if (left.line != right.line) return left.line < right.line;
    return !left.after_line and right.after_line;
}

fn validateHunkSequence(hunks: []const Hunk) Error!void {
    var previous_old: ?SourcePosition = null;
    var previous_new: ?SourcePosition = null;
    var old_ended_without_lf = false;
    var new_ended_without_lf = false;
    for (hunks) |hunk| {
        const old_range: HunkRange = .{ .start = hunk.old_start, .count = hunk.old_count };
        const new_range: HunkRange = .{ .start = hunk.new_start, .count = hunk.new_count };
        if (previous_old) |previous| if (!positionBefore(previous, rangeFirst(old_range))) return error.InvalidPatch;
        if (previous_new) |previous| if (!positionBefore(previous, rangeFirst(new_range))) return error.InvalidPatch;
        previous_old = rangeLast(old_range);
        previous_new = rangeLast(new_range);
        for (hunk.lines) |line| {
            const consumes_old = line.kind != .added;
            const consumes_new = line.kind != .removed;
            if ((consumes_old and old_ended_without_lf) or (consumes_new and new_ended_without_lf)) {
                return error.InvalidPatch;
            }
            if (line.line_ending == .none) {
                if (consumes_old) old_ended_without_lf = true;
                if (consumes_new) new_ended_without_lf = true;
            }
        }
    }
}

/// Parse one complete exact projection payload into allocator-owned arrays.
/// All byte/text/path slices live in `allocator`; callers normally use an
/// arena and release the complete plan at once.
pub fn parse(allocator: std.mem.Allocator, object_format: target_mod.ObjectFormat, patch: []const u8) Error!Plan {
    var ignored: ?limits.Violation = null;
    return parseWithLimit(allocator, object_format, patch, &ignored);
}

pub fn parseWithLimit(
    allocator: std.mem.Allocator,
    object_format: target_mod.ObjectFormat,
    patch: []const u8,
    violation: *?limits.Violation,
) Error!Plan {
    violation.* = null;
    var parser: Parser = .{
        .allocator = allocator,
        .object_format = object_format,
        .patch = patch,
        .violation = violation,
    };
    return parser.parse();
}

const ByteMatcher = struct {
    actual: []const u8,
    cursor: usize = 0,

    fn byte(self: *ByteMatcher, expected: u8) bool {
        if (self.cursor >= self.actual.len or self.actual[self.cursor] != expected) return false;
        self.cursor += 1;
        return true;
    }

    fn bytes(self: *ByteMatcher, expected: []const u8) bool {
        if (expected.len > self.actual.len -| self.cursor or
            !std.mem.eql(u8, self.actual[self.cursor .. self.cursor + expected.len], expected)) return false;
        self.cursor += expected.len;
        return true;
    }

    fn complete(self: ByteMatcher) bool {
        return self.cursor == self.actual.len;
    }
};

fn gitPathByteNeedsQuote(byte: u8, quote_non_ascii: bool) bool {
    return byte < 0x20 or byte == '"' or byte == '\\' or byte == 0x7f or
        (quote_non_ascii and byte >= 0x80);
}

fn gitPathNeedsQuote(prefix: []const u8, path: []const u8, quote_non_ascii: bool) bool {
    for (prefix) |byte| if (gitPathByteNeedsQuote(byte, quote_non_ascii)) return true;
    for (path) |byte| if (gitPathByteNeedsQuote(byte, quote_non_ascii)) return true;
    return false;
}

fn matchGitPathPart(matcher: *ByteMatcher, bytes: []const u8, quote_non_ascii: bool) bool {
    for (bytes) |byte| {
        const mnemonic: ?u8 = switch (byte) {
            0x07 => 'a',
            0x08 => 'b',
            '\t' => 't',
            '\n' => 'n',
            0x0b => 'v',
            0x0c => 'f',
            '\r' => 'r',
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (mnemonic) |escaped| {
            if (!matcher.byte('\\') or !matcher.byte(escaped)) return false;
        } else if (byte < 0x20 or byte == 0x7f or (quote_non_ascii and byte >= 0x80)) {
            if (!matcher.byte('\\') or
                !matcher.byte('0' + ((byte >> 6) & 0x03)) or
                !matcher.byte('0' + ((byte >> 3) & 0x07)) or
                !matcher.byte('0' + (byte & 0x07))) return false;
        } else if (!matcher.byte(byte)) return false;
    }
    return true;
}

fn matchGitPath(matcher: *ByteMatcher, prefix: []const u8, path: []const u8, quote_non_ascii: bool) bool {
    const quoted = gitPathNeedsQuote(prefix, path, quote_non_ascii);
    if (quoted and !matcher.byte('"')) return false;
    if (!matchGitPathPart(matcher, prefix, quote_non_ascii) or
        !matchGitPathPart(matcher, path, quote_non_ascii)) return false;
    if (quoted and !matcher.byte('"')) return false;
    return true;
}

fn gitPathPolicyMask(token: []const u8, prefix: []const u8, path: []const u8) u2 {
    var result: u2 = 0;
    var literal: ByteMatcher = .{ .actual = token };
    if (matchGitPath(&literal, prefix, path, false) and literal.complete()) {
        result |= git_quote_policy_literal_non_ascii;
    }
    var octal: ByteMatcher = .{ .actual = token };
    if (matchGitPath(&octal, prefix, path, true) and octal.complete()) {
        result |= git_quote_policy_octal_non_ascii;
    }
    return result;
}

fn narrowGitPathPolicy(policy_mask: *u2, token: []const u8, prefix: []const u8, path: []const u8) Error!void {
    policy_mask.* &= gitPathPolicyMask(token, prefix, path);
    if (policy_mask.* == 0) return error.InvalidPath;
}

fn diffHeaderPolicyMask(line: []const u8, old_path: []const u8, new_path: []const u8) u2 {
    var result: u2 = 0;
    inline for (.{
        .{ false, git_quote_policy_literal_non_ascii },
        .{ true, git_quote_policy_octal_non_ascii },
    }) |policy| {
        var matcher: ByteMatcher = .{ .actual = line };
        if (matcher.bytes("diff --git ") and
            matchGitPath(&matcher, "a/", old_path, policy[0]) and
            matcher.byte(' ') and
            matchGitPath(&matcher, "b/", new_path, policy[0]) and
            matcher.complete())
        {
            result |= policy[1];
        }
    }
    return result;
}

fn admitDiffHeader(file: *const FileBuilder, policy_mask: *u2) Error!void {
    const old_path = file.old_path orelse file.new_path orelse return error.InvalidPatch;
    const new_path = file.new_path orelse file.old_path orelse return error.InvalidPatch;
    policy_mask.* &= diffHeaderPolicyMask(file.diff_header, old_path, new_path);
    if (policy_mask.* == 0) return error.InvalidPatch;
}

fn decodeGitPath(allocator: std.mem.Allocator, token: []const u8, violation: *?limits.Violation) Error![]const u8 {
    if (token.len == 0) return error.InvalidPath;
    if (token[0] != '"') {
        if (token.len > limits.max_raw_path_bytes) {
            limits.record(violation, "raw_path_bytes", token.len, limits.max_raw_path_bytes);
            return error.LimitExceeded;
        }
        return allocator.dupe(u8, token);
    }
    if (token.len < 2 or token[token.len - 1] != '"') return error.InvalidPath;
    var bytes: std.ArrayList(u8) = .empty;
    var index: usize = 1;
    while (index < token.len - 1) {
        const byte = token[index];
        index += 1;
        if (byte != '\\') {
            try bytes.append(allocator, byte);
            continue;
        }
        if (index >= token.len - 1) return error.InvalidPath;
        const escaped = token[index];
        index += 1;
        switch (escaped) {
            '\\', '"' => try bytes.append(allocator, escaped),
            'a' => try bytes.append(allocator, 0x07),
            'b' => try bytes.append(allocator, 0x08),
            't' => try bytes.append(allocator, '\t'),
            'n' => try bytes.append(allocator, '\n'),
            'v' => try bytes.append(allocator, 0x0b),
            'f' => try bytes.append(allocator, 0x0c),
            'r' => try bytes.append(allocator, '\r'),
            '0'...'7' => {
                if (index + 1 >= token.len - 1 or token[index] < '0' or token[index] > '7' or
                    token[index + 1] < '0' or token[index + 1] > '7') return error.InvalidPath;
                const value: u16 = (@as(u16, escaped - '0') << 6) |
                    (@as(u16, token[index] - '0') << 3) | (token[index + 1] - '0');
                if (value > 255) return error.InvalidPath;
                try bytes.append(allocator, @intCast(value));
                index += 2;
            },
            else => return error.InvalidPath,
        }
        if (bytes.items.len > limits.max_raw_path_bytes) {
            limits.record(violation, "raw_path_bytes", bytes.items.len, limits.max_raw_path_bytes);
            return error.LimitExceeded;
        }
    }
    return bytes.toOwnedSlice(allocator);
}

fn parseRepositoryPath(allocator: std.mem.Allocator, token: []const u8, violation: *?limits.Violation, policy_mask: *u2) Error![]const u8 {
    const decoded = try decodeGitPath(allocator, token, violation);
    try validateRepositoryPath(decoded, violation);
    try narrowGitPathPolicy(policy_mask, token, "", decoded);
    return decoded;
}

fn parseFileMarkerPath(allocator: std.mem.Allocator, token: []const u8, prefix: []const u8, violation: *?limits.Violation, policy_mask: *u2) Error!?[]const u8 {
    const has_space_suffix = std.mem.endsWith(u8, token, "\t");
    const spelling = if (has_space_suffix) token[0 .. token.len - 1] else token;
    if (std.mem.eql(u8, spelling, "/dev/null")) {
        if (has_space_suffix) return error.InvalidPath;
        return null;
    }
    if (has_space_suffix != (std.mem.indexOfScalar(u8, spelling, ' ') != null)) return error.InvalidPath;
    const decoded = try decodeGitPath(allocator, spelling, violation);
    try narrowGitPathPolicy(policy_mask, spelling, "", decoded);
    return try stripPrefix(decoded, prefix, violation);
}

fn stripPrefix(path: []const u8, prefix: []const u8, violation: *?limits.Violation) Error![]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return error.InvalidPath;
    const stripped = path[prefix.len..];
    try validateRepositoryPath(stripped, violation);
    return stripped;
}

fn validateRepositoryPath(path: []const u8, violation: *?limits.Violation) Error!void {
    if (path.len > limits.max_raw_path_bytes) {
        limits.record(violation, "raw_path_bytes", path.len, limits.max_raw_path_bytes);
        return error.LimitExceeded;
    }
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
    }
}

fn parseHunkHeader(line: []const u8, violation: *?limits.Violation) Error!HunkHeader {
    var cursor: usize = 0;
    try consumeLiteral(line, &cursor, "@@ ");
    const old = try parseRangeAt(line, &cursor, '-');
    try consumeLiteral(line, &cursor, " ");
    const new = try parseRangeAt(line, &cursor, '+');
    try consumeLiteral(line, &cursor, " @@");
    if (cursor == line.len) return .{ .old = old, .new = new, .section = null };
    try consumeLiteral(line, &cursor, " ");
    if (cursor == line.len) return error.InvalidPatch;
    const section_text = line[cursor..];
    if (section_text.len > limits.max_hunk_section_bytes) {
        limits.record(violation, "hunk_section_bytes", section_text.len, limits.max_hunk_section_bytes);
        return error.LimitExceeded;
    }
    try validateContentText(section_text);
    return .{ .old = old, .new = new, .section = section_text };
}

fn consumeLiteral(input: []const u8, cursor: *usize, literal: []const u8) Error!void {
    if (literal.len > input.len -| cursor.* or
        !std.mem.eql(u8, input[cursor.* .. cursor.* + literal.len], literal)) return error.InvalidPatch;
    cursor.* += literal.len;
}

fn takeCanonicalUnsigned(input: []const u8, cursor: *usize) Error![]const u8 {
    const start = cursor.*;
    while (cursor.* < input.len and std.ascii.isDigit(input[cursor.*])) cursor.* += 1;
    const text = input[start..cursor.*];
    if (!canonicalUnsigned(text)) return error.InvalidPatch;
    return text;
}

fn parseRangeAt(input: []const u8, cursor: *usize, prefix: u8) Error!HunkRange {
    if (cursor.* >= input.len or input[cursor.*] != prefix) return error.InvalidPatch;
    cursor.* += 1;
    const start_text = try takeCanonicalUnsigned(input, cursor);
    var count_text: []const u8 = "1";
    var explicit_count = false;
    if (cursor.* < input.len and input[cursor.*] == ',') {
        cursor.* += 1;
        count_text = try takeCanonicalUnsigned(input, cursor);
        explicit_count = true;
    }
    if (!canonicalUnsigned(start_text) or !canonicalUnsigned(count_text)) return error.InvalidPatch;
    const start = std.fmt.parseInt(u32, start_text, 10) catch return error.InvalidPatch;
    const count = std.fmt.parseInt(u32, count_text, 10) catch return error.InvalidPatch;
    if (explicit_count == (count == 1)) return error.InvalidPatch;
    if (count > 0 and start == 0) return error.InvalidPatch;
    if (count > 0) _ = std.math.add(u32, start, count - 1) catch return error.InvalidPatch;
    return .{ .start = start, .count = count };
}

fn canonicalUnsigned(text: []const u8) bool {
    if (text.len == 0 or (text.len > 1 and text[0] == '0')) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn validateMode(mode: []const u8) Error!void {
    if (mode.len != 6) return error.InvalidPatch;
    for (mode) |byte| if (byte < '0' or byte > '7') return error.InvalidPatch;
    if (std.mem.eql(u8, mode, "100644") or std.mem.eql(u8, mode, "100755")) return;
    if (std.mem.startsWith(u8, mode, "100")) return error.InvalidPatch;
    return error.UnsupportedFileType;
}

fn parseIndexInfo(object_format: target_mod.ObjectFormat, line: []const u8) Error!IndexInfo {
    var parts = std.mem.splitScalar(u8, line, ' ');
    if (!std.mem.eql(u8, parts.next().?, "index")) return error.InvalidPatch;
    const pair = parts.next() orelse return error.InvalidPatch;
    const dots = std.mem.indexOf(u8, pair, "..") orelse return error.InvalidPatch;
    const old_oid = pair[0..dots];
    const new_oid = pair[dots + 2 ..];
    if (old_oid.len < 4 or
        old_oid.len != new_oid.len or
        old_oid.len > object_format.oidHexLength()) return error.InvalidPatch;
    for (old_oid) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidPatch;
    for (new_oid) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) return error.InvalidPatch;
    const mode = parts.next();
    if (mode) |value| try validateMode(value);
    if (parts.next() != null) return error.InvalidPatch;
    const old_zero = allZero(old_oid);
    const new_zero = allZero(new_oid);
    if (old_zero and new_zero) return error.InvalidPatch;
    return .{
        .old_zero = old_zero,
        .new_zero = new_zero,
        .oids_equal = std.mem.eql(u8, old_oid, new_oid),
        .has_mode = mode != null,
    };
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != '0') return false;
    return true;
}

fn validatePercentMetadata(line: []const u8, prefix: []const u8) Error!void {
    if (!std.mem.startsWith(u8, line, prefix)) return error.InvalidPatch;
    const percent = line[prefix.len..];
    if (percent.len < 2 or percent[percent.len - 1] != '%') return error.InvalidPatch;
    const number = percent[0 .. percent.len - 1];
    if (!canonicalUnsigned(number)) return error.InvalidPatch;
    const value = std.fmt.parseInt(u8, number, 10) catch return error.InvalidPatch;
    if (value > 100) return error.InvalidPatch;
}

fn resolveFileIdentity(file: *const FileBuilder) Error!protocol.FileStatus {
    const old_path = file.old_path;
    const new_path = file.new_path;
    if (file.renamed) {
        if (file.rename_from == null or file.rename_to == null or old_path == null or new_path == null or
            std.mem.eql(u8, old_path.?, new_path.?) or
            !std.mem.eql(u8, file.rename_from.?, old_path.?) or !std.mem.eql(u8, file.rename_to.?, new_path.?))
        {
            return error.InvalidPatch;
        }
        return .renamed;
    }
    if (file.copied) {
        if (file.copy_from == null or file.copy_to == null or old_path == null or new_path == null or
            std.mem.eql(u8, old_path.?, new_path.?) or
            !std.mem.eql(u8, file.copy_from.?, old_path.?) or !std.mem.eql(u8, file.copy_to.?, new_path.?))
        {
            return error.InvalidPatch;
        }
        return .copied;
    }
    if (old_path == null and new_path != null) {
        return .added;
    }
    if (old_path != null and new_path == null) {
        return .deleted;
    }
    if (old_path != null and new_path != null and std.mem.eql(u8, old_path.?, new_path.?)) return .modified;
    return error.InvalidPatch;
}

fn validateCanonicalFileRecord(file: *const FileBuilder, status: protocol.FileStatus) Error!void {
    const simple_modified = [_]MetadataKind{ .diff_header, .index, .old_marker, .new_marker };
    const mode_modified = [_]MetadataKind{ .diff_header, .old_mode, .new_mode, .index, .old_marker, .new_marker };
    const added = [_]MetadataKind{ .diff_header, .new_file_mode, .index, .old_marker, .new_marker };
    const deleted = [_]MetadataKind{ .diff_header, .deleted_file_mode, .index, .old_marker, .new_marker };
    const renamed = [_]MetadataKind{ .diff_header, .similarity_index, .rename_from, .rename_to, .index, .old_marker, .new_marker };
    const renamed_mode = [_]MetadataKind{ .diff_header, .old_mode, .new_mode, .similarity_index, .rename_from, .rename_to, .index, .old_marker, .new_marker };
    const copied = [_]MetadataKind{ .diff_header, .similarity_index, .copy_from, .copy_to, .index, .old_marker, .new_marker };
    const copied_mode = [_]MetadataKind{ .diff_header, .old_mode, .new_mode, .similarity_index, .copy_from, .copy_to, .index, .old_marker, .new_marker };

    const kinds = file.metadata_kinds.items;
    const index = file.index_info orelse return error.InvalidPatch;
    if (index.oids_equal) return error.InvalidPatch;
    switch (status) {
        .modified => {
            const mode_change = std.mem.eql(MetadataKind, kinds, &mode_modified);
            if (!mode_change and !std.mem.eql(MetadataKind, kinds, &simple_modified)) return error.InvalidPatch;
            if (index.old_zero or index.new_zero or index.has_mode == mode_change) return error.InvalidPatch;
            if (mode_change and std.mem.eql(u8, file.old_mode.?, file.new_mode.?)) return error.InvalidPatch;
        },
        .added => {
            if (!std.mem.eql(MetadataKind, kinds, &added) or !index.old_zero or index.new_zero or index.has_mode) return error.InvalidPatch;
        },
        .deleted => {
            if (!std.mem.eql(MetadataKind, kinds, &deleted) or index.old_zero or !index.new_zero or index.has_mode) return error.InvalidPatch;
        },
        .renamed => {
            const mode_change = std.mem.eql(MetadataKind, kinds, &renamed_mode);
            if (!mode_change and !std.mem.eql(MetadataKind, kinds, &renamed)) return error.InvalidPatch;
            if (index.old_zero or index.new_zero or index.has_mode == mode_change) return error.InvalidPatch;
            if (mode_change and std.mem.eql(u8, file.old_mode.?, file.new_mode.?)) return error.InvalidPatch;
        },
        .copied => {
            const mode_change = std.mem.eql(MetadataKind, kinds, &copied_mode);
            if (!mode_change and !std.mem.eql(MetadataKind, kinds, &copied)) return error.InvalidPatch;
            if (index.old_zero or index.new_zero or index.has_mode == mode_change) return error.InvalidPatch;
            if (mode_change and std.mem.eql(u8, file.old_mode.?, file.new_mode.?)) return error.InvalidPatch;
        },
    }

    for (file.hunks.items) |hunk| switch (status) {
        .added => if (hunk.old_start != 0 or hunk.old_count != 0) return error.InvalidPatch,
        .deleted => if (hunk.new_start != 0 or hunk.new_count != 0) return error.InvalidPatch,
        else => {},
    };
}

fn validateContentText(text: []const u8) Error!void {
    var iterator = (std.unicode.Utf8View.init(text) catch return error.UnsupportedContent).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0 or codepoint == 0x1b or codepoint == '\n' or codepoint == '\r' or codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f) or (codepoint < 0x20 and codepoint != '\t'))
        {
            return error.UnsupportedContent;
        }
    }
}

fn safeModelText(allocator: std.mem.Allocator, raw: []const u8, maximum: usize, resource: []const u8, violation: *?limits.Violation) Error![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (raw) |byte| {
        const added: usize = if ((byte >= 0x20 and byte <= 0x7e) or byte == '\t') 1 else 4;
        if (result.items.len > maximum -| added) {
            limits.record(violation, resource, result.items.len + added, maximum);
            return error.LimitExceeded;
        }
        if (byte >= 0x20 and byte <= 0x7e) {
            try result.append(allocator, byte);
        } else if (byte == '\t') {
            try result.append(allocator, byte);
        } else {
            try result.appendSlice(allocator, "\\x00");
            result.items[result.items.len - 2] = hexLower(byte >> 4);
            result.items[result.items.len - 1] = hexLower(byte & 0x0f);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn displayPath(allocator: std.mem.Allocator, path: []const u8, violation: *?limits.Violation) Error![]const u8 {
    const result = try safeModelText(allocator, path, limits.max_display_path_bytes, "display_path_bytes", violation);
    if (result.len == 0) return error.InvalidPath;
    return result;
}

fn hexLower(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn testPatchWithHunkSize(allocator: std.mem.Allocator, hunk_size: usize) ![]u8 {
    const metadata = "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n";
    const header = "@@ -1,4 +1,4 @@\n";
    const framing_bytes = header.len + 8 * 2;
    if (hunk_size < framing_bytes) return error.InvalidPatch;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll(metadata);
    try output.writer.writeAll(header);
    var remaining = hunk_size - framing_bytes;
    const filler = try allocator.alloc(u8, (remaining + 7) / 8);
    defer allocator.free(filler);
    @memset(filler, 'x');
    for (0..8) |index| {
        const lines_left = 8 - index;
        const count = (remaining + lines_left - 1) / lines_left;
        try output.writer.writeByte(if (index % 2 == 0) '-' else '+');
        try output.writer.writeAll(filler[0..count]);
        try output.writer.writeByte('\n');
        remaining -= count;
    }
    return output.toOwnedSlice();
}

fn expectPatchRejectedForFormat(object_format: target_mod.ObjectFormat, patch: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    if (parse(arena.allocator(), object_format, patch)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

fn expectPatchRejected(patch: []const u8) !void {
    return expectPatchRejectedForFormat(.sha1, patch);
}

fn expectPatchAcceptedForFormat(object_format: target_mod.ObjectFormat, patch: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parse(arena.allocator(), object_format, patch);
}

fn expectPatchAccepted(patch: []const u8) !void {
    return expectPatchAcceptedForFormat(.sha1, patch);
}

fn expectRequiredByteMutationsRejected(canonical: []const u8, index: usize, allowed_insertions: []const u8) !void {
    std.debug.assert(index < canonical.len);
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        if (byte != canonical[index]) {
            const replaced = try std.testing.allocator.dupe(u8, canonical);
            defer std.testing.allocator.free(replaced);
            replaced[index] = byte;
            try expectPatchRejected(replaced);
        }

        const inserted = try std.testing.allocator.alloc(u8, canonical.len + 1);
        defer std.testing.allocator.free(inserted);
        @memcpy(inserted[0..index], canonical[0..index]);
        inserted[index] = byte;
        @memcpy(inserted[index + 1 ..], canonical[index..]);
        if (std.mem.indexOfScalar(u8, allowed_insertions, byte) == null) {
            try expectPatchRejected(inserted);
        } else {
            try expectPatchAccepted(inserted);
        }
    }

    const deleted = try std.testing.allocator.alloc(u8, canonical.len - 1);
    defer std.testing.allocator.free(deleted);
    @memcpy(deleted[0..index], canonical[0..index]);
    @memcpy(deleted[index..], canonical[index + 1 ..]);
    try expectPatchRejected(deleted);
}

const OidProofRecordKind = enum {
    modified,
    added,
    deleted,
    renamed,
    copied,
};

const oid_proof_records = [_]struct {
    kind: OidProofRecordKind,
    status: protocol.FileStatus,
}{
    .{ .kind = .modified, .status = .modified },
    .{ .kind = .added, .status = .added },
    .{ .kind = .deleted, .status = .deleted },
    .{ .kind = .renamed, .status = .renamed },
    .{ .kind = .copied, .status = .copied },
};

fn oidProofPatchAlloc(
    allocator: std.mem.Allocator,
    kind: OidProofRecordKind,
    old_oid: []const u8,
    new_oid: []const u8,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    switch (kind) {
        .modified => try output.writer.print(
            "diff --git a/a b/a\nindex {s}..{s} 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
            .{ old_oid, new_oid },
        ),
        .added => try output.writer.print(
            "diff --git a/a b/a\nnew file mode 100644\nindex {s}..{s}\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+new\n",
            .{ old_oid, new_oid },
        ),
        .deleted => try output.writer.print(
            "diff --git a/a b/a\ndeleted file mode 100644\nindex {s}..{s}\n--- a/a\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n",
            .{ old_oid, new_oid },
        ),
        .renamed => try output.writer.print(
            "diff --git a/old b/new\nsimilarity index 50%\nrename from old\nrename to new\nindex {s}..{s} 100644\n--- a/old\n+++ b/new\n@@ -1 +1 @@\n-old\n+new\n",
            .{ old_oid, new_oid },
        ),
        .copied => try output.writer.print(
            "diff --git a/old b/new\nsimilarity index 50%\ncopy from old\ncopy to new\nindex {s}..{s} 100644\n--- a/old\n+++ b/new\n@@ -1 +1 @@\n-old\n+new\n",
            .{ old_oid, new_oid },
        ),
    }
    return output.toOwnedSlice();
}

test "AI review input patch planner preserves complete spans and CRLF no-final-LF semantics" {
    const patch =
        "diff --git a/src/a.txt b/src/a.txt\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/src/a.txt\n" ++
        "+++ b/src/a.txt\n" ++
        "@@ -1,2 +1,2 @@ section\n" ++
        " same\r\n" ++
        "-old\n" ++
        "\\ No newline at end of file\n" ++
        "+new\n" ++
        "\\ No newline at end of file\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = try parse(arena.allocator(), .sha1, patch);
    try std.testing.expectEqual(@as(usize, 1), plan.files.len);
    try std.testing.expectEqual(@as(usize, 1), plan.files[0].hunks.len);
    try std.testing.expectEqual(protocol.LineEnding.crlf, plan.files[0].hunks[0].lines[0].line_ending);
    try std.testing.expectEqual(protocol.LineEnding.none, plan.files[0].hunks[0].lines[1].line_ending);
    try std.testing.expectEqual(protocol.LineEnding.none, plan.files[0].hunks[0].lines[2].line_ending);
    try std.testing.expectEqual(@as(usize, patch.len), plan.files[0].metadata_coverage.len() + plan.files[0].hunks[0].coverage.len());
}

test "AI review input patch planner decodes C-quoted raw paths without making them model text" {
    const patch = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/ai-review-producer-v1/input/raw-path.patch", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(patch);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const plan = try parse(arena.allocator(), .sha1, patch);
    try std.testing.expectEqualSlices(u8, &.{ 'r', 'a', 'w', 0xff, '.', 't', 'x', 't' }, plan.files[0].old_path.?);
    try std.testing.expectEqualStrings("raw\\xff.txt", plan.files[0].display_path);
}

test "AI review input patch planner rejects omission-prone forms as complete failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidPatch, parse(arena.allocator(), .sha1, "trailing garbage\n"));
    try std.testing.expectError(error.UnsupportedCombinedDiff, parse(arena.allocator(), .sha1, "diff --cc a.txt\n"));
    const binary = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/ai-review-producer-v1/input/binary.patch", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(binary);
    try std.testing.expectError(error.UnsupportedBinary, parse(arena.allocator(), .sha1, binary));
    const metadata_only = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/ai-review-producer-v1/input/metadata-only.patch", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(metadata_only);
    try std.testing.expectError(error.MetadataOnly, parse(arena.allocator(), .sha1, metadata_only));
    try std.testing.expectError(error.InvalidPatch, parse(arena.allocator(), .sha1, "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n"));
}

test "AI review input patch planner proves finite lexical delimiters paths and ranges" {
    const canonical = "diff --git a/a b/a\n" ++
        "index 1111111..2222222 100644\n" ++
        "--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n";
    const header_separator = std.mem.indexOf(u8, canonical, "a/a b/a").? + "a/a".len;
    const open_separator = std.mem.indexOf(u8, canonical, "@@ -1").? + "@@".len;
    const close_separator = std.mem.indexOf(u8, canonical, "+1 @@").? + "+1".len;
    try expectRequiredByteMutationsRejected(canonical, header_separator, "");
    try expectRequiredByteMutationsRejected(canonical, open_separator, "");
    // Inserting a digit before this separator changes the canonical new start
    // from 1 to 10...19; those are explicit grammar alternatives, not aliases.
    try expectRequiredByteMutationsRejected(canonical, close_separator, "0123456789");

    const malformed = [_][]const u8{
        "diff --git a/a  b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git \"a/a\" \"b/a\"\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- \"a/a\"\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git \"a/\\141\" \"b/\\141\"\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1@@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@section\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@ \n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1,1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -01 +1 @@\n-old\n+new\n",
        "diff --git \"a/raw\\377.txt\" \"b/raw\\377.txt\"\nindex 1111111..2222222 100644\n--- a/raw\xff.txt\n+++ b/raw\xff.txt\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/space name.txt b/space name.txt\nindex 1111111..2222222 100644\n--- a/space name.txt\n+++ b/space name.txt\t\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\t\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\t\n+++ b/a\n@@ -0,0 +1 @@\n+new\n",
    };
    for (malformed) |patch| try expectPatchRejected(patch);

    const valid = [_][]const u8{
        canonical,
        "diff --git a/space name.txt b/space name.txt\nindex 1111111..2222222 100644\n--- a/space name.txt\t\n+++ b/space name.txt\t\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/ space  b/ space \nindex 1111111..2222222 100644\n--- a/ space \t\n+++ b/ space \t\n@@ -1 +1 @@ leading and trailing path spaces\n-old\n+new\n",
        "diff --git \"a/tab\\t space\" \"b/tab\\t space\"\nindex 1111111..2222222 100644\n--- \"a/tab\\t space\"\t\n+++ \"b/tab\\t space\"\t\n@@ -1 +1 @@ quoted marker space\n-old\n+new\n",
        "diff --git a/raw\xff.txt b/raw\xff.txt\nindex 1111111..2222222 100644\n--- a/raw\xff.txt\n+++ b/raw\xff.txt\n@@ -1 +1 @@ section\n-old\n+new\n",
    };
    for (valid) |patch| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const plan = try parse(arena.allocator(), .sha1, patch);
        try std.testing.expectEqual(patch.len, plan.files[0].metadata_coverage.len() + plan.files[0].hunks[0].coverage.len());
    }
}

test "AI review input patch planner rejects non-regular modes and non-UTF-8 content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnsupportedFileType, parse(arena.allocator(), .sha1, "diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+target\n"));
    try std.testing.expectError(error.UnsupportedContent, parse(arena.allocator(), .sha1, "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+\xff\n"));
    try std.testing.expectError(error.UnsupportedContent, parse(arena.allocator(), .sha1, "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\r\n\\ No newline at end of file\n+new\n"));
}

test "AI review input patch planner admits the canonical status and mode metadata matrix" {
    try validatePercentMetadata("similarity index 0%", "similarity index ");
    try validatePercentMetadata("dissimilarity index 100%", "dissimilarity index ");
    try std.testing.expectError(error.InvalidPatch, validatePercentMetadata("similarity index injected 50%", "similarity index "));
    try std.testing.expectError(error.InvalidPatch, validatePercentMetadata("dissimilarity index 50% trailing", "dissimilarity index "));
    const cases = [_]struct { status: protocol.FileStatus, patch: []const u8 }{
        .{ .status = .modified, .patch = "diff --git a/a b/a\n" ++
            "index 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n" },
        .{ .status = .modified, .patch = "diff --git a/a b/a\nold mode 100644\nnew mode 100755\n" ++
            "index 1111111..2222222\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n" },
        .{ .status = .added, .patch = "diff --git a/a b/a\nnew file mode 100755\n" ++
            "index 0000000..2222222\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+new\n" },
        .{ .status = .deleted, .patch = "diff --git a/a b/a\ndeleted file mode 100755\n" ++
            "index 1111111..0000000\n--- a/a\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n" },
        .{ .status = .renamed, .patch = "diff --git a/old b/new\nsimilarity index 50%\nrename from old\nrename to new\n" ++
            "index 1111111..2222222 100644\n--- a/old\n+++ b/new\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n" },
        .{ .status = .renamed, .patch = "diff --git a/old b/new\nold mode 100644\nnew mode 100755\n" ++
            "similarity index 50%\nrename from old\nrename to new\n" ++
            "index 1111111..2222222\n--- a/old\n+++ b/new\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n" },
        .{ .status = .copied, .patch = "diff --git a/old b/new\nsimilarity index 50%\ncopy from old\ncopy to new\n" ++
            "index 1111111..2222222 100644\n--- a/old\n+++ b/new\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n" },
        .{ .status = .copied, .patch = "diff --git a/old b/new\nold mode 100644\nnew mode 100755\n" ++
            "similarity index 50%\ncopy from old\ncopy to new\n" ++
            "index 1111111..2222222\n--- a/old\n+++ b/new\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const plan = try parse(arena.allocator(), .sha1, case.patch);
        try std.testing.expectEqual(@as(usize, 1), plan.files.len);
        try std.testing.expectEqual(case.status, plan.files[0].status);
        try std.testing.expectEqual(case.patch.len, plan.files[0].metadata_coverage.len() + plan.files[0].hunks[0].coverage.len());
    }
}

test "AI review input patch planner finite proof inventory binds all five statuses to target object format OID boundaries" {
    const format_cases = [_]target_mod.ObjectFormat{ .sha1, .sha256 };
    const zeroes = [_]u8{'0'} ** 65;
    const old_nonzero = [_]u8{'1'} ** 65;
    const new_nonzero = [_]u8{'2'} ** 65;

    for (format_cases) |object_format| {
        const maximum = object_format.oidHexLength();
        const widths = [_]struct { width: usize, accepted: bool }{
            .{ .width = 3, .accepted = false },
            .{ .width = 4, .accepted = true },
            .{ .width = maximum, .accepted = true },
            .{ .width = maximum + 1, .accepted = false },
        };
        for (widths) |width_case| for (oid_proof_records) |record| {
            const old_oid = if (record.kind == .added)
                zeroes[0..width_case.width]
            else
                old_nonzero[0..width_case.width];
            const new_oid = if (record.kind == .deleted)
                zeroes[0..width_case.width]
            else
                new_nonzero[0..width_case.width];
            const patch = try oidProofPatchAlloc(std.testing.allocator, record.kind, old_oid, new_oid);
            defer std.testing.allocator.free(patch);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            if (width_case.accepted) {
                const plan = try parse(arena.allocator(), object_format, patch);
                try std.testing.expectEqual(@as(usize, 1), plan.files.len);
                try std.testing.expectEqual(record.status, plan.files[0].status);
                try std.testing.expectEqual(patch.len, plan.files[0].metadata_coverage.len() + plan.files[0].hunks[0].coverage.len());
            } else {
                try std.testing.expectError(error.InvalidPatch, parse(arena.allocator(), object_format, patch));
            }
        };

        for (oid_proof_records) |record| {
            const old_oid = if (record.kind == .added) zeroes[0..4] else old_nonzero[0..4];
            const new_oid = if (record.kind == .deleted) zeroes[0..5] else new_nonzero[0..5];
            const patch = try oidProofPatchAlloc(std.testing.allocator, record.kind, old_oid, new_oid);
            defer std.testing.allocator.free(patch);
            try expectPatchRejectedForFormat(object_format, patch);
        }
    }
}

test "AI review input patch planner admits actual regular modify add delete and rename records" {
    const cases = [_]struct { path: []const u8, status: protocol.FileStatus }{
        .{ .path = "testdata/ai-review-producer-v1/input/valid-modified.patch", .status = .modified },
        .{ .path = "testdata/ai-review-producer-v1/input/valid-added.patch", .status = .added },
        .{ .path = "testdata/ai-review-producer-v1/input/valid-deleted.patch", .status = .deleted },
        .{ .path = "testdata/ai-review-producer-v1/input/valid-renamed.patch", .status = .renamed },
    };
    for (cases) |case| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, case.path, std.testing.allocator, .limited(4096));
        defer std.testing.allocator.free(bytes);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const plan = try parse(arena.allocator(), .sha1, bytes);
        try std.testing.expectEqual(@as(usize, 1), plan.files.len);
        try std.testing.expectEqual(case.status, plan.files[0].status);
        try std.testing.expectEqual(bytes.len, plan.files[0].metadata_coverage.len() + plan.files[0].hunks[0].coverage.len());
    }
}

test "AI review input patch planner rejects contradictory incomplete and noncanonical file records" {
    const invalid = [_][]const u8{
        // Added records bind both diff-header sides to the one new path.
        "diff --git a/evil.txt b/good.txt\n" ++
            "new file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/good.txt\n@@ -0,0 +1 @@\n+good\n",
        // Regular-file evidence cannot be omitted.
        "diff --git a/link b/link\n--- a/link\n+++ b/link\n@@ -1 +1 @@\n-old\n+new\n",
        // An added record cannot consume a before-side line.
        "diff --git a/a b/a\nnew file mode 100644\nindex 0000000..2222222\n--- /dev/null\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        // Metadata is unique and in the exact Git writer order.
        "diff --git a/a b/a\nindex 1111111..2222222 100644\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\n--- a/a\nindex 1111111..2222222 100644\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        // A deleted record cannot consume an after-side line.
        "diff --git a/a b/a\ndeleted file mode 100644\nindex 1111111..0000000\n--- a/a\n+++ /dev/null\n@@ -1 +1 @@\n-old\n+new\n",
        // Added/deleted zero-OID evidence is status-specific.
        "diff --git a/a b/a\nnew file mode 100644\nindex 1111111..2222222\n--- /dev/null\n+++ b/a\n@@ -0,0 +1 @@\n+new\n",
        // Similarity/rename metadata cannot be reordered or duplicated.
        "diff --git a/old b/new\nrename from old\nsimilarity index 50%\nrename to new\nindex 1111111..2222222 100644\n--- a/old\n+++ b/new\n@@ -1 +1 @@\n-old\n+new\n",
        // The mode lines precede similarity and rename/copy identity in Git output.
        "diff --git a/old b/new\nsimilarity index 50%\nrename from old\nrename to new\nold mode 100644\nnew mode 100755\nindex 1111111..2222222\n--- a/old\n+++ b/new\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n",
        "diff --git a/old b/new\nsimilarity index 50%\ncopy from old\ncopy to new\nold mode 100644\nnew mode 100755\nindex 1111111..2222222\n--- a/old\n+++ b/new\n@@ -1,2 +1,2 @@\n same\n-old\n+new\n",
        // Percent metadata is exact, nonzero index sides differ, and every
        // emitted location must fit in u32.
        "diff --git a/old b/new\nsimilarity index injected 50%\nrename from old\nrename to new\nindex 1111111..2222222 100644\n--- a/old\n+++ b/new\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..1111111 100644\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-old\n+new\n",
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -4294967295,2 +1,2 @@\n-old one\n-old two\n+new one\n+new two\n",
    };
    for (invalid) |patch| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try std.testing.expectError(error.InvalidPatch, parse(arena.allocator(), .sha1, patch));
    }
}

test "AI review input patch planner admits over-target whole hunks and rejects cross-hunk overlap" {
    var oversized: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer oversized.deinit();
    try oversized.writer.writeAll(
        "diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n@@ -1,5 +1,5 @@\n",
    );
    const content = [_]u8{'x'} ** limits.max_diff_line_bytes;
    for (0..5) |_| {
        try oversized.writer.writeByte('-');
        try oversized.writer.writeAll(&content);
        try oversized.writer.writeByte('\n');
        try oversized.writer.writeByte('+');
        try oversized.writer.writeAll(&content);
        try oversized.writer.writeByte('\n');
    }
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var violation: ?limits.Violation = null;
    const oversized_plan = try parseWithLimit(arena.allocator(), .sha1, oversized.written(), &violation);
    try std.testing.expect(oversized_plan.files[0].hunks[0].coverage.len() > limits.unit_raw_fragment_target_bytes);
    try std.testing.expect(violation == null);
    var long_line: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer long_line.deinit();
    try long_line.writer.writeAll("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-");
    const too_long = [_]u8{'x'} ** (limits.max_diff_line_bytes + 1);
    try long_line.writer.writeAll(&too_long);
    try long_line.writer.writeAll("\n+new\n");
    violation = null;
    try std.testing.expectError(error.ReviewLineTooLarge, parseWithLimit(arena.allocator(), .sha1, long_line.written(), &violation));
    try std.testing.expectEqualStrings("diff_line_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_diff_line_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_diff_line_bytes, violation.?.allowed);
    try std.testing.expectError(error.InvalidPatch, parse(arena.allocator(), .sha1, "diff --git a/a b/a\n--- a/a\n+++ b/a\n" ++
        "@@ -3 +3 @@\n-old\n+new\n@@ -3 +4 @@\n-old\n+new\n"));
}

test "AI review input patch planner fixes changed-file hunk limits and packing-target boundary" {
    var many_files: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer many_files.deinit();
    var exact_files_end: usize = 0;
    for (0..limits.max_changed_files + 1) |index| {
        try many_files.writer.print(
            "diff --git a/f{d} b/f{d}\nindex 1111111..2222222 100644\n--- a/f{d}\n+++ b/f{d}\n@@ -1 +1 @@\n-old\n+new\n",
            .{ index, index, index, index },
        );
        if (index + 1 == limits.max_changed_files) exact_files_end = many_files.written().len;
    }
    var exact_files_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_files_arena.deinit();
    const exact_files = try parse(exact_files_arena.allocator(), .sha1, many_files.written()[0..exact_files_end]);
    try std.testing.expectEqual(limits.max_changed_files, exact_files.files.len);
    var plus_files_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer plus_files_arena.deinit();
    var violation: ?limits.Violation = null;
    try std.testing.expectError(error.LimitExceeded, parseWithLimit(plus_files_arena.allocator(), .sha1, many_files.written(), &violation));
    try std.testing.expectEqualStrings("changed_files", violation.?.resource);
    try std.testing.expectEqual(limits.max_changed_files + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_changed_files, violation.?.allowed);

    var many_hunks: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer many_hunks.deinit();
    try many_hunks.writer.writeAll("diff --git a/a b/a\nindex 1111111..2222222 100644\n--- a/a\n+++ b/a\n");
    var exact_hunks_end: usize = 0;
    for (0..limits.max_hunks + 1) |index| {
        try many_hunks.writer.print("@@ -{d} +{d} @@\n-old\n+new\n", .{ index + 1, index + 1 });
        if (index + 1 == limits.max_hunks) exact_hunks_end = many_hunks.written().len;
    }
    var exact_hunks_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_hunks_arena.deinit();
    const exact_hunks = try parse(exact_hunks_arena.allocator(), .sha1, many_hunks.written()[0..exact_hunks_end]);
    try std.testing.expectEqual(limits.max_hunks, exact_hunks.hunk_count);
    var plus_hunks_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer plus_hunks_arena.deinit();
    violation = null;
    try std.testing.expectError(error.LimitExceeded, parseWithLimit(plus_hunks_arena.allocator(), .sha1, many_hunks.written(), &violation));
    try std.testing.expectEqualStrings("hunks", violation.?.resource);
    try std.testing.expectEqual(limits.max_hunks + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_hunks, violation.?.allowed);

    const exact_fragment = try testPatchWithHunkSize(std.testing.allocator, limits.unit_raw_fragment_target_bytes);
    defer std.testing.allocator.free(exact_fragment);
    var exact_fragment_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer exact_fragment_arena.deinit();
    const exact_fragment_plan = try parse(exact_fragment_arena.allocator(), .sha1, exact_fragment);
    try std.testing.expectEqual(limits.unit_raw_fragment_target_bytes, exact_fragment_plan.files[0].hunks[0].coverage.len());
    const plus_fragment = try testPatchWithHunkSize(std.testing.allocator, limits.unit_raw_fragment_target_bytes + 1);
    defer std.testing.allocator.free(plus_fragment);
    var plus_fragment_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer plus_fragment_arena.deinit();
    const plus_fragment_plan = try parseWithLimit(plus_fragment_arena.allocator(), .sha1, plus_fragment, &violation);
    try std.testing.expectEqual(limits.unit_raw_fragment_target_bytes + 1, plus_fragment_plan.files[0].hunks[0].coverage.len());
    try std.testing.expect(violation == null);
}
