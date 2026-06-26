const std = @import("std");
const loaded_diff = @import("../loaded_diff.zig");

pub const OverlayKind = enum {
    none,
    help,
    discard_file,
    amend_commit,
};

/// App-owned modal/overlay state.
///
/// Overlay-specific viewport state lives with the overlay selector so opening,
/// closing, and future overlays do not add more primitive fields to `App`.
pub const OverlayState = struct {
    kind: OverlayKind = .none,
    help_scroll: usize = 0,

    pub fn isHelp(self: OverlayState) bool {
        return self.kind == .help;
    }

    pub fn isDiscardFile(self: OverlayState) bool {
        return self.kind == .discard_file;
    }

    pub fn isAmendCommit(self: OverlayState) bool {
        return self.kind == .amend_commit;
    }

    pub fn openHelp(self: *OverlayState) void {
        self.kind = .help;
        self.help_scroll = 0;
    }

    pub fn openDiscardFile(self: *OverlayState) void {
        self.kind = .discard_file;
    }

    pub fn openAmendCommit(self: *OverlayState) void {
        self.kind = .amend_commit;
    }

    pub fn close(self: *OverlayState) void {
        self.kind = .none;
    }
};

/// Owned snapshot for a destructive file discard confirmation.
///
/// The selection can move while the confirmation is open, so the exact repo
/// and file path must be copied when the prompt is created.
pub const DiscardFileConfirmation = struct {
    repo_root: []u8,
    path: []u8,

    pub fn deinit(self: *DiscardFileConfirmation, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path);
        self.* = undefined;
    }
};

/// Owned snapshot for an amend confirmation.
///
/// The draft remains editable in the commit panel while this confirmation is
/// open, so the command payload must be copied before asking for confirmation.
pub const AmendConfirmation = struct {
    repo_root: []u8,
    subject: []u8,
    body: ?[]u8 = null,

    pub fn deinit(self: *AmendConfirmation, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.subject);
        if (self.body) |body| allocator.free(body);
        self.* = undefined;
    }
};

/// Short-lived status text shown in the shell header.
///
/// Store the length instead of a slice into `buf`. That keeps the value
/// self-contained even if App state is copied in tests or future snapshots.
pub const StatusMessage = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *StatusMessage, comptime fmt: []const u8, args: anytype) void {
        const formatted = std.fmt.bufPrint(&self.buf, fmt, args) catch "status formatting failed";
        self.len = formatted.len;
    }

    pub fn text(self: *const StatusMessage) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Display-only review filters applied to the active loaded diff.
///
/// The reviewed store remains the source of truth; this state only controls
/// how the active sidebar projection is filtered.
pub const ReviewDisplayState = struct {
    hide_reviewed_files: bool = false,
    changed_file_filter: loaded_diff.ChangedFileFilter = .all,
};

/// Pending selection restore across a Git action triggered reload.
///
/// Git actions can move a file between diff/status projections. Keep the
/// logical path and previous visible row outside the load arena so the next
/// accepted load can restore the user's review position.
pub const PendingSelectionRestore = struct {
    path_key: []u8,
    visible_row: usize,

    pub fn deinit(self: *PendingSelectionRestore, allocator: std.mem.Allocator) void {
        allocator.free(self.path_key);
        self.* = undefined;
    }
};

pub const StagedHunkMark = struct {
    repo_root: []u8,
    path_key: []u8,
    hunk_index: usize,

    pub fn deinit(self: *StagedHunkMark, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }
};

/// Session-only marks for hunks staged from the review pane.
///
/// Git reloads expose only unstaged hunks, but review needs staged hunks to
/// remain visible as dim context. These marks keep that UI projection local to
/// the current session and are cleared on a full diff reload.
pub const StagedHunkMarks = struct {
    items: std.ArrayList(StagedHunkMark) = .empty,

    pub fn deinit(self: *StagedHunkMarks, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.items.deinit(allocator);
    }

    pub fn clear(self: *StagedHunkMarks, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.clearRetainingCapacity();
    }

    pub fn add(self: *StagedHunkMarks, allocator: std.mem.Allocator, repo_root: []const u8, path_key: []const u8, hunk_index: usize) !void {
        if (self.contains(repo_root, path_key, hunk_index)) return;

        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        const owned_path = try allocator.dupe(u8, path_key);
        errdefer allocator.free(owned_path);

        try self.items.append(allocator, .{
            .repo_root = owned_root,
            .path_key = owned_path,
            .hunk_index = hunk_index,
        });
    }

    pub fn contains(self: StagedHunkMarks, repo_root: []const u8, path_key: []const u8, hunk_index: usize) bool {
        for (self.items.items) |item| {
            if (item.hunk_index == hunk_index and
                std.mem.eql(u8, item.repo_root, repo_root) and
                std.mem.eql(u8, item.path_key, path_key))
            {
                return true;
            }
        }
        return false;
    }

    pub fn remove(self: *StagedHunkMarks, allocator: std.mem.Allocator, repo_root: []const u8, path_key: []const u8, hunk_index: usize) bool {
        for (self.items.items, 0..) |*item, index| {
            if (item.hunk_index == hunk_index and
                std.mem.eql(u8, item.repo_root, repo_root) and
                std.mem.eql(u8, item.path_key, path_key))
            {
                item.deinit(allocator);
                _ = self.items.swapRemove(index);
                return true;
            }
        }
        return false;
    }
};

test "OverlayState opens help and resets its scroll" {
    var overlay: OverlayState = .{ .kind = .help, .help_scroll = 5 };

    overlay.close();
    try std.testing.expectEqual(OverlayKind.none, overlay.kind);
    try std.testing.expectEqual(@as(usize, 5), overlay.help_scroll);

    overlay.openHelp();
    try std.testing.expectEqual(OverlayKind.help, overlay.kind);
    try std.testing.expectEqual(@as(usize, 0), overlay.help_scroll);
}

test "StatusMessage owns its formatted text buffer" {
    var status: StatusMessage = .{};

    status.set("loaded {d}", .{3});

    try std.testing.expectEqualStrings("loaded 3", status.text());
}

test "StatusMessage remains self-contained after value copy" {
    var status: StatusMessage = .{};
    status.set("loaded {d}", .{3});

    const copied = status;

    try std.testing.expectEqualStrings("loaded 3", copied.text());
}

test "StagedHunkMarks owns keys and deduplicates hunk marks" {
    var marks: StagedHunkMarks = .{};
    defer marks.deinit(std.testing.allocator);

    try marks.add(std.testing.allocator, "/repo", "src/app.zig", 2);
    try marks.add(std.testing.allocator, "/repo", "src/app.zig", 2);

    try std.testing.expectEqual(@as(usize, 1), marks.items.items.len);
    try std.testing.expect(marks.contains("/repo", "src/app.zig", 2));
    try std.testing.expect(!marks.contains("/repo", "src/app.zig", 3));
    try std.testing.expect(!marks.contains("/other", "src/app.zig", 2));

    try std.testing.expect(marks.remove(std.testing.allocator, "/repo", "src/app.zig", 2));
    try std.testing.expect(!marks.contains("/repo", "src/app.zig", 2));
    try std.testing.expectEqual(@as(usize, 0), marks.items.items.len);
}
