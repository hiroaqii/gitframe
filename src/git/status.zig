const std = @import("std");

pub const ParseError = error{
    InvalidRecord,
    MissingRenamePath,
    OutOfMemory,
};

pub const StatusCode = enum {
    unmodified,
    modified,
    added,
    deleted,
    renamed,
    copied,
    untracked,
    ignored,
    unmerged,
    unknown,
};

/// Parsed `git status --porcelain=v1 -z -uall` output.
///
/// `parse` allocates the entries slice, but each path slice borrows from the
/// input text. Use `StatusBundle.parseOwned` when the document must outlive the
/// input buffer, such as async task results stored in app state.
pub const StatusDocument = struct {
    entries: []const StatusEntry,
};

pub const StatusEntry = struct {
    /// Current repo-relative path. For rename/copy entries this is the new path.
    path: []const u8,
    /// Previous repo-relative path for rename/copy entries.
    old_path: ?[]const u8 = null,
    /// Original porcelain XY bytes. Keep this for conflict/unknown display and
    /// action policy without forcing UI code to re-derive it from enums.
    raw: [2]u8,
    index: StatusCode,
    worktree: StatusCode,

    pub fn isStaged(self: StatusEntry) bool {
        return self.index != .unmodified and self.index != .unknown and self.index != .untracked and self.index != .ignored;
    }

    pub fn isUnstaged(self: StatusEntry) bool {
        return self.worktree != .unmodified and self.worktree != .unknown and self.worktree != .ignored;
    }

    pub fn isUntracked(self: StatusEntry) bool {
        return self.worktree == .untracked;
    }

    pub fn isIgnored(self: StatusEntry) bool {
        return self.worktree == .ignored;
    }

    pub fn isConflict(self: StatusEntry) bool {
        return self.index == .unmerged or self.worktree == .unmerged;
    }

    /// Canonical key for cross-model state.
    ///
    /// Porcelain paths are normally repo-relative already, but keep the same
    /// defensive normalization rules as diff file keys.
    pub fn canonicalPathKey(self: StatusEntry) ?[]const u8 {
        return canonicalRepoPath(self.path);
    }
};

/// Owns a status document and the arena backing its copied input and entries.
pub const StatusBundle = struct {
    arena: ?std.heap.ArenaAllocator,
    document: StatusDocument,

    /// Parse status text into an owned bundle.
    ///
    /// The input text is first copied into the bundle arena, then parsed from
    /// that copy. This keeps StatusEntry.path valid after the caller frees the
    /// original status command output.
    pub fn parseOwned(allocator: std.mem.Allocator, text: []const u8) ParseError!StatusBundle {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const copied = try arena_allocator.dupe(u8, text);
        const document = try parse(arena_allocator, copied);
        return .{
            .arena = arena,
            .document = document,
        };
    }

    pub fn deinit(self: *StatusBundle) void {
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
    }

    pub fn takeArena(self: *StatusBundle) std.heap.ArenaAllocator {
        const arena = self.arena.?;
        self.arena = null;
        return arena;
    }
};

/// Active repository status snapshot owned by the app.
///
/// `StatusBundle` is a task-result payload. `GitStatusState` is the long-lived
/// app state form: it owns the arena backing status paths and the copied repo
/// root that identifies which repository the snapshot belongs to.
pub const GitStatusState = struct {
    arena: ?std.heap.ArenaAllocator = null,
    repo_root: ?[]const u8 = null,
    document: StatusDocument = .{ .entries = &.{} },

    pub fn replace(self: *GitStatusState, repo_root: []const u8, bundle: *StatusBundle) ParseError!void {
        var arena = bundle.takeArena();
        errdefer arena.deinit();

        const copied_root = try arena.allocator().dupe(u8, repo_root);
        self.deinit();
        self.arena = arena;
        self.repo_root = copied_root;
        self.document = bundle.document;
    }

    pub fn clear(self: *GitStatusState) void {
        self.deinit();
    }

    pub fn deinit(self: *GitStatusState) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }
};

/// Parse status text while borrowing path slices from `text`.
///
/// The returned entries slice must be freed by the caller. Do not store the
/// resulting StatusDocument beyond the lifetime of `text`; use
/// StatusBundle.parseOwned for app state or async task payloads.
pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!StatusDocument {
    var parser: Parser = .{ .allocator = allocator };
    return parser.parse(text);
}

const Parser = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(StatusEntry) = .empty,

    fn parse(self: *Parser, text: []const u8) ParseError!StatusDocument {
        errdefer self.entries.deinit(self.allocator);

        var offset: usize = 0;
        while (offset < text.len) {
            const field = nextZField(text, &offset) orelse break;
            if (field.len == 0) continue;
            try self.parseEntry(field, text, &offset);
        }

        return .{ .entries = try self.entries.toOwnedSlice(self.allocator) };
    }

    fn parseEntry(self: *Parser, field: []const u8, text: []const u8, offset: *usize) ParseError!void {
        if (field.len < 4 or field[2] != ' ') return error.InvalidRecord;

        const raw = [2]u8{ field[0], field[1] };
        const path = field[3..];
        const old_path = if (isRenameOrCopy(raw)) nextZField(text, offset) orelse return error.MissingRenamePath else null;
        try self.entries.append(self.allocator, .{
            .path = path,
            .old_path = old_path,
            .raw = raw,
            .index = indexStatus(raw),
            .worktree = worktreeStatus(raw),
        });
    }
};

fn nextZField(text: []const u8, offset: *usize) ?[]const u8 {
    if (offset.* >= text.len) return null;
    const start = offset.*;
    const end = std.mem.indexOfScalarPos(u8, text, start, 0) orelse text.len;
    offset.* = if (end < text.len) end + 1 else text.len;
    return text[start..end];
}

fn isRenameOrCopy(raw: [2]u8) bool {
    return raw[0] == 'R' or raw[0] == 'C' or raw[1] == 'R' or raw[1] == 'C';
}

fn indexStatus(raw: [2]u8) StatusCode {
    if (isUntracked(raw) or isIgnored(raw)) return .unmodified;
    if (isUnmerged(raw)) return .unmerged;
    return statusCode(raw[0]);
}

fn worktreeStatus(raw: [2]u8) StatusCode {
    if (isUntracked(raw)) return .untracked;
    if (isIgnored(raw)) return .ignored;
    if (isUnmerged(raw)) return .unmerged;
    return statusCode(raw[1]);
}

fn isUntracked(raw: [2]u8) bool {
    return raw[0] == '?' and raw[1] == '?';
}

fn isIgnored(raw: [2]u8) bool {
    return raw[0] == '!' and raw[1] == '!';
}

fn isUnmerged(raw: [2]u8) bool {
    return (raw[0] == 'D' and raw[1] == 'D') or
        (raw[0] == 'A' and raw[1] == 'U') or
        (raw[0] == 'U' and raw[1] == 'D') or
        (raw[0] == 'U' and raw[1] == 'A') or
        (raw[0] == 'D' and raw[1] == 'U') or
        (raw[0] == 'A' and raw[1] == 'A') or
        (raw[0] == 'U' and raw[1] == 'U');
}

fn statusCode(byte: u8) StatusCode {
    return switch (byte) {
        ' ' => .unmodified,
        'M' => .modified,
        'A' => .added,
        'D' => .deleted,
        'R' => .renamed,
        'C' => .copied,
        'U' => .unmerged,
        else => .unknown,
    };
}

// Keep in sync with diff/file.zig's canonical path normalization. These
// modules are tested as standalone roots, so the normalization is duplicated
// until a lower shared module can be introduced without breaking module tests.
fn canonicalRepoPath(path: []const u8) ?[]const u8 {
    if (isDevNull(path)) return null;
    const stripped = stripGitSidePrefix(path);
    if (isDevNull(stripped) or stripped.len == 0) return null;
    return stripped;
}

fn stripGitSidePrefix(path: []const u8) []const u8 {
    if (path.len >= 2 and (path[0] == 'a' or path[0] == 'b') and path[1] == '/') return path[2..];
    return path;
}

fn isDevNull(path: []const u8) bool {
    return std.mem.eql(u8, path, "/dev/null");
}

test "parse porcelain v1 z modified entries" {
    const doc = try parse(std.testing.allocator, " M src/main.zig\x00M  build.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    try std.testing.expectEqual(@as(usize, 2), doc.entries.len);
    try std.testing.expectEqualStrings("src/main.zig", doc.entries[0].path);
    try std.testing.expectEqual(StatusCode.unmodified, doc.entries[0].index);
    try std.testing.expectEqual(StatusCode.modified, doc.entries[0].worktree);
    try std.testing.expect(doc.entries[0].isUnstaged());
    try std.testing.expectEqualStrings("build.zig", doc.entries[1].path);
    try std.testing.expectEqual(StatusCode.modified, doc.entries[1].index);
    try std.testing.expectEqual(StatusCode.unmodified, doc.entries[1].worktree);
    try std.testing.expect(doc.entries[1].isStaged());
}

test "status entry canonical key normalizes defensive path shapes" {
    const prefixed: StatusEntry = .{
        .path = "a/src/main.zig",
        .raw = .{ ' ', 'M' },
        .index = .unmodified,
        .worktree = .modified,
    };
    try std.testing.expectEqualStrings("src/main.zig", prefixed.canonicalPathKey().?);

    const dev_null: StatusEntry = .{
        .path = "/dev/null",
        .raw = .{ ' ', 'D' },
        .index = .unmodified,
        .worktree = .deleted,
    };
    try std.testing.expect(dev_null.canonicalPathKey() == null);

    const empty: StatusEntry = .{
        .path = "",
        .raw = .{ ' ', 'M' },
        .index = .unmodified,
        .worktree = .modified,
    };
    try std.testing.expect(empty.canonicalPathKey() == null);
}

test "parse untracked and ignored entries as worktree status" {
    const doc = try parse(std.testing.allocator, "?? new file.zig\x00!! ignored.tmp\x00");
    defer std.testing.allocator.free(doc.entries);

    try std.testing.expectEqual(StatusCode.unmodified, doc.entries[0].index);
    try std.testing.expectEqual(StatusCode.untracked, doc.entries[0].worktree);
    try std.testing.expect(doc.entries[0].isUntracked());
    try std.testing.expectEqual(StatusCode.unmodified, doc.entries[1].index);
    try std.testing.expectEqual(StatusCode.ignored, doc.entries[1].worktree);
    try std.testing.expect(doc.entries[1].isIgnored());
}

test "parse rename z format keeps current and old paths" {
    const doc = try parse(std.testing.allocator, "R  src/new name.zig\x00src/old -> name.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    try std.testing.expectEqual(@as(usize, 1), doc.entries.len);
    try std.testing.expectEqual(StatusCode.renamed, doc.entries[0].index);
    try std.testing.expectEqualStrings("src/new name.zig", doc.entries[0].path);
    try std.testing.expectEqualStrings("src/old -> name.zig", doc.entries[0].old_path.?);
}

test "parse paths with newline through z fields" {
    const doc = try parse(std.testing.allocator, " A src/line\nbreak.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    try std.testing.expectEqualStrings("src/line\nbreak.zig", doc.entries[0].path);
}

test "parse unmerged and unknown statuses without panicking" {
    const doc = try parse(std.testing.allocator, "UU conflict.zig\x00Z  odd.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    try std.testing.expect(doc.entries[0].isConflict());
    try std.testing.expectEqual(StatusCode.unknown, doc.entries[1].index);
}

test "parseOwned keeps paths alive after source buffer is freed" {
    const allocator = std.testing.allocator;
    const source = try allocator.dupe(u8, " M src/main.zig\x00");
    var bundle = try StatusBundle.parseOwned(allocator, source);
    allocator.free(source);
    defer bundle.deinit();

    try std.testing.expectEqualStrings("src/main.zig", bundle.document.entries[0].path);
}

test "GitStatusState takes bundle arena and stores repo root" {
    const allocator = std.testing.allocator;
    var bundle = try StatusBundle.parseOwned(allocator, "?? src/new.zig\x00");
    defer bundle.deinit();

    var state: GitStatusState = .{};
    defer state.deinit();

    try state.replace("/repo", &bundle);
    try std.testing.expect(bundle.arena == null);
    try std.testing.expectEqualStrings("/repo", state.repo_root.?);
    try std.testing.expectEqual(@as(usize, 1), state.document.entries.len);
    try std.testing.expectEqualStrings("src/new.zig", state.document.entries[0].path);

    state.clear();
    try std.testing.expect(state.repo_root == null);
    try std.testing.expectEqual(@as(usize, 0), state.document.entries.len);
}

test "parse releases partial entries on malformed input" {
    const result = parse(std.testing.allocator, " M ok.zig\x00R  missing-old.zig\x00");

    try std.testing.expectError(error.MissingRenamePath, result);
}
