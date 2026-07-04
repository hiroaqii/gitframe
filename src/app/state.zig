const std = @import("std");
const loaded_diff = @import("../loaded_diff.zig");
const text_edit = @import("text_edit.zig");

pub const OverlayKind = enum {
    none,
    help,
    discard_file,
    amend_commit,
    push_branch,
    push_error,
    push_credentials,
};

pub const OverlayMouseMode = enum {
    passthrough,
    block,
    scroll_help,
    scroll_push_error,
};

/// App-owned modal/overlay state.
///
/// Overlay-specific viewport state lives with the overlay selector so opening,
/// closing, and future overlays do not add more primitive fields to `App`.
pub const OverlayState = struct {
    kind: OverlayKind = .none,
    help_scroll: usize = 0,
    push_error_scroll: usize = 0,

    pub fn isHelp(self: OverlayState) bool {
        return self.kind == .help;
    }

    pub fn isDiscardFile(self: OverlayState) bool {
        return self.kind == .discard_file;
    }

    pub fn isAmendCommit(self: OverlayState) bool {
        return self.kind == .amend_commit;
    }

    pub fn isPushBranch(self: OverlayState) bool {
        return self.kind == .push_branch;
    }

    pub fn isPushError(self: OverlayState) bool {
        return self.kind == .push_error;
    }

    pub fn isPushCredentials(self: OverlayState) bool {
        return self.kind == .push_credentials;
    }

    pub fn mouseMode(self: OverlayState) OverlayMouseMode {
        return switch (self.kind) {
            .none => .passthrough,
            .help => .scroll_help,
            .push_error => .scroll_push_error,
            .discard_file, .amend_commit, .push_branch, .push_credentials => .block,
        };
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

    pub fn openPushBranch(self: *OverlayState) void {
        self.kind = .push_branch;
    }

    pub fn openPushError(self: *OverlayState) void {
        self.kind = .push_error;
        self.push_error_scroll = 0;
    }

    pub fn openPushCredentials(self: *OverlayState) void {
        self.kind = .push_credentials;
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

/// Owned snapshot for push confirmation.
///
/// Branch status can reload while the popup is open, so the displayed and
/// executed remote target must be copied when the prompt is created.
pub const PushConfirmation = struct {
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    ahead: u32,
    behind: u32,

    pub fn deinit(self: *PushConfirmation, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = undefined;
    }
};

/// Secret text input for short-lived credentials.
///
/// This is intentionally separate from normal bounded text inputs: callers
/// should pass it by pointer only and avoid whole-value copies. `clear` and
/// `deinit` zero the whole backing buffer with `std.crypto.secureZero`.
///
/// Normal text inputs are value types and are fine to copy in tests/UI state.
/// That pattern is unsafe for secrets because each copy leaves another buffer
/// that would also need explicit wiping.
pub const SecretInput = struct {
    pub const InsertError = error{BufferFull};

    buffer: [512]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0,

    pub fn secret(self: *const SecretInput) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn insert(self: *SecretInput, codepoint: u21) InsertError!void {
        var bytes: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(codepoint, &bytes) catch unreachable;
        try self.insertSlice(bytes[0..written]);
    }

    pub fn insertSlice(self: *SecretInput, text: []const u8) InsertError!void {
        if (text.len == 0) return;
        std.debug.assert(std.unicode.utf8ValidateSlice(text));
        if (self.len + text.len > self.buffer.len) return error.BufferFull;
        std.mem.copyBackwards(u8, self.buffer[self.cursor + text.len .. self.len + text.len], self.buffer[self.cursor..self.len]);
        @memcpy(self.buffer[self.cursor .. self.cursor + text.len], text);
        self.len += text.len;
        self.cursor += text.len;
    }

    pub fn backspace(self: *SecretInput) void {
        if (self.cursor == 0) return;
        const previous = text_edit.previousBoundary(self.secret(), self.cursor);
        std.mem.copyForwards(u8, self.buffer[previous .. self.len - (self.cursor - previous)], self.buffer[self.cursor..self.len]);
        self.len -= self.cursor - previous;
        self.cursor = previous;
    }

    pub fn moveLeft(self: *SecretInput) void {
        self.cursor = text_edit.previousBoundary(self.secret(), self.cursor);
    }

    pub fn moveRight(self: *SecretInput) void {
        self.cursor = text_edit.nextBoundary(self.secret(), self.cursor);
    }

    pub fn clear(self: *SecretInput) void {
        std.crypto.secureZero(u8, self.buffer[0..]);
        self.len = 0;
        self.cursor = 0;
    }

    pub fn deinit(self: *SecretInput) void {
        self.clear();
    }
};

pub const PushCredentialField = enum {
    username,
    password,
};

pub const PushRetryTarget = struct {
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    remote_url: ?[]u8 = null,

    pub fn deinit(self: *PushRetryTarget, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        if (self.branch.len > 0) allocator.free(self.branch);
        if (self.remote.len > 0) allocator.free(self.remote);
        if (self.remote_branch.len > 0) allocator.free(self.remote_branch);
        if (self.oid.len > 0) allocator.free(self.oid);
        if (self.remote_url) |remote_url| allocator.free(remote_url);
        self.* = undefined;
    }
};

/// Heap-owned so opening/closing overlays does not copy `SecretInput` buffers.
pub const PushCredentialPrompt = struct {
    target: PushRetryTarget,
    username: SecretInput = .{},
    password: SecretInput = .{},
    active_field: PushCredentialField = .username,

    pub fn deinit(self: *PushCredentialPrompt, allocator: std.mem.Allocator) void {
        self.username.deinit();
        self.password.deinit();
        self.target.deinit(allocator);
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
    clear_on_next_input: bool = false,

    pub fn set(self: *StatusMessage, comptime fmt: []const u8, args: anytype) void {
        const formatted = std.fmt.bufPrint(&self.buf, fmt, args) catch {
            self.len = validUtf8PrefixLen(&self.buf);
            self.clear_on_next_input = true;
            return;
        };
        self.len = formatted.len;
        self.clear_on_next_input = true;
    }

    pub fn clear(self: *StatusMessage) void {
        self.len = 0;
        self.clear_on_next_input = false;
    }

    pub fn clearIfEphemeral(self: *StatusMessage) void {
        if (self.clear_on_next_input) self.clear();
    }

    pub fn text(self: *const StatusMessage) []const u8 {
        return self.buf[0..self.len];
    }
};

fn validUtf8PrefixLen(bytes: []const u8) usize {
    var len = bytes.len;
    while (len > 0 and !std.unicode.utf8ValidateSlice(bytes[0..len])) : (len -= 1) {}
    return len;
}

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
    try std.testing.expect(status.clear_on_next_input);
}

test "StatusMessage truncates overflow instead of replacing text" {
    var status: StatusMessage = .{};
    status.set("prefix {s}", .{"abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"});

    try std.testing.expect(std.mem.startsWith(u8, status.text(), "prefix abc"));
    try std.testing.expect(!std.mem.eql(u8, status.text(), "status formatting failed"));
    try std.testing.expect(status.text().len <= status.buf.len);
}

test "StatusMessage truncates on UTF-8 boundary" {
    var status: StatusMessage = .{};
    status.set("{s}", .{"あいうえおかきくけこさしすせそたちつてとあいうえおかきくけこさしすせそたちつてと"});

    try std.testing.expect(std.unicode.utf8ValidateSlice(status.text()));
    try std.testing.expect(status.text().len <= status.buf.len);
}

test "StatusMessage remains self-contained after value copy" {
    var status: StatusMessage = .{};
    status.set("loaded {d}", .{3});

    const copied = status;

    try std.testing.expectEqualStrings("loaded 3", copied.text());
}

test "StatusMessage clears only ephemeral text" {
    var status: StatusMessage = .{};

    status.set("loaded {d}", .{3});
    status.clearIfEphemeral();

    try std.testing.expectEqualStrings("", status.text());
    try std.testing.expect(!status.clear_on_next_input);
}

test "ReviewDisplayState defaults to showing all files" {
    const review_display: ReviewDisplayState = .{};

    try std.testing.expect(!review_display.hide_reviewed_files);
    try std.testing.expectEqual(loaded_diff.ChangedFileFilter.all, review_display.changed_file_filter);
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

test "SecretInput clear zeroes backing buffer" {
    var input: SecretInput = .{};
    try input.insertSlice("token");
    input.clear();

    try std.testing.expectEqual(@as(usize, 0), input.len);
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
    for (input.buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
