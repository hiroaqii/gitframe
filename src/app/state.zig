const std = @import("std");
const git_branch_status = @import("../git/branch_status.zig");
const git_push = @import("../git/push.zig");
const loaded_diff = @import("../loaded_diff.zig");
const review_selection = @import("diff_surface/selection.zig");
const session_hunk_mark = @import("pages/review/session_hunk_mark.zig");
const text_edit = @import("text_edit.zig");
const page = @import("page.zig");

pub const OverlayKind = enum {
    none,
    help,
    discard_file,
    amend_commit,
    push_branch,
    pull_branch,
    switch_branch,
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
    owner_page: ?page.Id = null,
    help_scroll: usize = 0,
    push_error_scroll: usize = 0,
    /// Identifies one concrete push-error surface across close/reopen cycles.
    /// Async results captured by an older surface must not present in a newer
    /// popup merely because both have the same overlay kind.
    push_error_instance_id: u64 = 0,

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

    pub fn isPullBranch(self: OverlayState) bool {
        return self.kind == .pull_branch;
    }

    pub fn isSwitchBranch(self: OverlayState) bool {
        return self.kind == .switch_branch;
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
            .discard_file, .amend_commit, .push_branch, .pull_branch, .switch_branch, .push_credentials => .block,
        };
    }

    pub fn openHelp(self: *OverlayState) void {
        self.openHelpForPage(.review);
    }

    pub fn openHelpForPage(self: *OverlayState, owner_page: page.Id) void {
        self.kind = .help;
        self.owner_page = owner_page;
        self.help_scroll = 0;
    }

    pub fn openDiscardFile(self: *OverlayState) void {
        self.kind = .discard_file;
        self.owner_page = .review;
    }

    pub fn openAmendCommit(self: *OverlayState) void {
        self.kind = .amend_commit;
        self.owner_page = .review;
    }

    pub fn openPushBranch(self: *OverlayState) void {
        self.kind = .push_branch;
        self.owner_page = .review;
    }

    pub fn openPullBranch(self: *OverlayState) void {
        self.kind = .pull_branch;
        self.owner_page = .review;
    }

    pub fn openSwitchBranch(self: *OverlayState) void {
        self.kind = .switch_branch;
        self.owner_page = .review;
    }

    pub fn openPushError(self: *OverlayState) void {
        self.push_error_instance_id +%= 1;
        if (self.push_error_instance_id == 0) self.push_error_instance_id = 1;
        self.kind = .push_error;
        self.owner_page = .review;
        self.push_error_scroll = 0;
    }

    pub fn openPushCredentials(self: *OverlayState) void {
        self.kind = .push_credentials;
        self.owner_page = .review;
    }

    pub fn close(self: *OverlayState) void {
        self.kind = .none;
        self.owner_page = null;
    }

    pub fn visibleOn(self: OverlayState, active_page: page.Id) bool {
        return self.kind != .none and self.owner_page == active_page;
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
    mode: git_push.Mode,
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    ahead_behind: ?git_branch_status.AheadBehind,

    pub fn deinit(self: *PushConfirmation, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = undefined;
    }
};

/// Owned snapshot for pull confirmation.
///
/// Branch status and file status can reload while the popup is open, so the
/// displayed target is copied. The backend then fetches the confirmed remote
/// and re-checks branch/upstream/clean state before deciding whether to
/// fast-forward.
pub const PullConfirmation = struct {
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    ahead: u32,
    behind: u32,

    pub fn deinit(self: *PullConfirmation, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.branch);
        allocator.free(self.remote);
        allocator.free(self.remote_branch);
        allocator.free(self.oid);
        self.* = undefined;
    }
};

pub const BranchSwitchItem = struct {
    name: []u8,
    oid: []u8,
    current: bool,

    pub fn deinit(self: *BranchSwitchItem, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.oid);
        self.* = undefined;
    }
};

pub const BranchSwitchState = struct {
    repo_root: []u8 = &.{},
    current_branch: []u8 = &.{},
    current_oid: []u8 = &.{},
    generation: u64 = 0,
    loading: bool = false,
    selected_index: usize = 0,
    branches: []BranchSwitchItem = &.{},

    pub fn deinit(self: *BranchSwitchState, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        if (self.current_branch.len > 0) allocator.free(self.current_branch);
        if (self.current_oid.len > 0) allocator.free(self.current_oid);
        for (self.branches) |*item| item.deinit(allocator);
        allocator.free(self.branches);
        self.* = .{};
    }

    pub fn hasState(self: BranchSwitchState) bool {
        return self.repo_root.len > 0;
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
    mode: git_push.Mode,
    repo_root: []u8,
    branch: []u8,
    remote: []u8,
    remote_branch: []u8,
    oid: []u8,
    remote_url: ?[]u8 = null,

    pub fn empty() PushRetryTarget {
        return .{
            .mode = .upstream,
            .repo_root = &.{},
            .branch = &.{},
            .remote = &.{},
            .remote_branch = &.{},
            .oid = &.{},
            .remote_url = null,
        };
    }

    pub fn take(self: *PushRetryTarget) PushRetryTarget {
        const owned = self.*;
        self.* = empty();
        return owned;
    }

    pub fn deinit(self: *PushRetryTarget, allocator: std.mem.Allocator) void {
        if (self.repo_root.len > 0) allocator.free(self.repo_root);
        if (self.branch.len > 0) allocator.free(self.branch);
        if (self.remote.len > 0) allocator.free(self.remote);
        if (self.remote_branch.len > 0) allocator.free(self.remote_branch);
        if (self.oid.len > 0) allocator.free(self.oid);
        if (self.remote_url) |remote_url| allocator.free(remote_url);
        self.* = empty();
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
pub const StatusProvenance = union(enum) {
    general,
    source_reload_failure: [32]u8,
};

pub const StatusMessage = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    clear_on_next_input: bool = false,
    provenance: StatusProvenance = .general,

    pub fn set(self: *StatusMessage, comptime fmt: []const u8, args: anytype) void {
        self.provenance = .general;
        self.setText(fmt, args);
    }

    pub fn setSourceReloadFailure(self: *StatusMessage, identity: [32]u8, comptime fmt: []const u8, args: anytype) void {
        self.provenance = .{ .source_reload_failure = identity };
        self.setText(fmt, args);
    }

    fn setText(self: *StatusMessage, comptime fmt: []const u8, args: anytype) void {
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
        self.provenance = .general;
    }

    pub fn clearIfEphemeral(self: *StatusMessage) void {
        if (self.clear_on_next_input) self.clear();
    }

    /// Clear a recovered source failure only when the visible message still
    /// belongs to that exact failure. Auxiliary failures may replace it while
    /// the source read is in flight and must not be erased by source recovery.
    pub fn clearSourceReloadFailure(self: *StatusMessage, identity: [32]u8) bool {
        switch (self.provenance) {
            .general => return false,
            .source_reload_failure => |current| {
                if (!std.mem.eql(u8, &current, &identity)) return false;
            },
        }
        self.clear();
        return true;
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

pub const StagedHunkMark = struct {
    repo_root: []u8,
    path_key: []u8,
    key: session_hunk_mark.Key,

    pub fn deinit(self: *StagedHunkMark, allocator: std.mem.Allocator) void {
        allocator.free(self.repo_root);
        allocator.free(self.path_key);
        self.* = undefined;
    }
};

/// Session-only marks for hunks staged from the review pane.
///
/// Git reloads expose only unstaged hunks, but review needs staged hunks to
/// remain visible with local stage presentation while fresh projection/status
/// catches up. A display ordinal is meaningful only inside its exact content
/// token; callers must explicitly rebind or clear a path lineage when an exact
/// presentation boundary is accepted.
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

    pub fn clearRepo(self: *StagedHunkMarks, allocator: std.mem.Allocator, repo_root: []const u8) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            if (!std.mem.eql(u8, self.items.items[index].repo_root, repo_root)) {
                index += 1;
                continue;
            }
            self.items.items[index].deinit(allocator);
            _ = self.items.swapRemove(index);
        }
    }

    pub fn addExact(
        self: *StagedHunkMarks,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        path_key: []const u8,
        key: session_hunk_mark.Key,
    ) !void {
        if (self.containsExact(repo_root, path_key, key)) return;

        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        const owned_path = try allocator.dupe(u8, path_key);
        errdefer allocator.free(owned_path);

        try self.items.append(allocator, .{
            .repo_root = owned_root,
            .path_key = owned_path,
            .key = key,
        });
    }

    pub fn containsExact(
        self: StagedHunkMarks,
        repo_root: []const u8,
        path_key: []const u8,
        key: session_hunk_mark.Key,
    ) bool {
        for (self.items.items) |item| {
            if (item.key.eql(key) and
                std.mem.eql(u8, item.repo_root, repo_root) and
                std.mem.eql(u8, item.path_key, path_key))
            {
                return true;
            }
        }
        return false;
    }

    pub fn removeExact(
        self: *StagedHunkMarks,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        path_key: []const u8,
        key: session_hunk_mark.Key,
    ) bool {
        for (self.items.items, 0..) |*item, index| {
            if (item.key.eql(key) and
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

    pub fn clearPathLineage(
        self: *StagedHunkMarks,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        path_key: []const u8,
        content: review_selection.ReviewContentToken,
    ) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            const item = &self.items.items[index];
            if (!std.mem.eql(u8, item.repo_root, repo_root) or
                !std.mem.eql(u8, item.path_key, path_key) or
                !item.key.content.eql(content))
            {
                index += 1;
                continue;
            }
            item.deinit(allocator);
            _ = self.items.swapRemove(index);
        }
    }

    pub fn rebindPathLineage(
        self: *StagedHunkMarks,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        path_key: []const u8,
        from: review_selection.ReviewContentToken,
        to: review_selection.ReviewContentToken,
    ) void {
        if (from.eql(to)) return;

        var index: usize = 0;
        while (index < self.items.items.len) {
            const item = &self.items.items[index];
            if (!std.mem.eql(u8, item.repo_root, repo_root) or
                !std.mem.eql(u8, item.path_key, path_key) or
                !item.key.content.eql(from))
            {
                index += 1;
                continue;
            }

            const rebound: session_hunk_mark.Key = .{
                .content = to,
                .display_hunk_index = item.key.display_hunk_index,
            };
            if (self.containsExact(repo_root, path_key, rebound)) {
                item.deinit(allocator);
                _ = self.items.swapRemove(index);
                continue;
            }
            item.key.content = to;
            index += 1;
        }
    }
};

test "OverlayState opens help and resets its scroll" {
    var overlay: OverlayState = .{ .kind = .help, .help_scroll = 5 };

    overlay.close();
    try std.testing.expectEqual(OverlayKind.none, overlay.kind);
    try std.testing.expect(overlay.owner_page == null);
    try std.testing.expectEqual(@as(usize, 5), overlay.help_scroll);

    overlay.openHelp();
    try std.testing.expectEqual(OverlayKind.help, overlay.kind);
    try std.testing.expectEqual(page.Id.review, overlay.owner_page.?);
    try std.testing.expectEqual(@as(usize, 0), overlay.help_scroll);

    overlay.openHelpForPage(.repository);
    try std.testing.expect(overlay.visibleOn(.repository));
    try std.testing.expect(!overlay.visibleOn(.review));
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

test "StatusMessage clears only the matching source reload failure" {
    var status: StatusMessage = .{};
    const first = [_]u8{1} ** 32;
    const second = [_]u8{2} ** 32;

    status.setSourceReloadFailure(first, "source failed", .{});
    try std.testing.expect(!status.clearSourceReloadFailure(second));
    try std.testing.expectEqualStrings("source failed", status.text());
    try std.testing.expect(status.clearSourceReloadFailure(first));
    try std.testing.expectEqualStrings("", status.text());

    status.setSourceReloadFailure(first, "source failed", .{});
    status.set("status failed", .{});
    try std.testing.expect(!status.clearSourceReloadFailure(first));
    try std.testing.expectEqualStrings("status failed", status.text());
}

test "ReviewDisplayState defaults to showing all files" {
    const review_display: ReviewDisplayState = .{};

    try std.testing.expect(!review_display.hide_reviewed_files);
    try std.testing.expectEqual(loaded_diff.ChangedFileFilter.all, review_display.changed_file_filter);
}

fn testHunkMarkKey(source_session_revision: u64, display_hunk_index: usize) session_hunk_mark.Key {
    return .{
        .content = .{
            .repo_epoch = 1,
            .root_identity = null,
            .source = review_selection.SourceBasis.init(.unstaged),
            .source_session_revision = source_session_revision,
            .display = .{ .loaded = .init("diff") },
        },
        .display_hunk_index = display_hunk_index,
    };
}

test "StagedHunkMarks owns paths and deduplicates exact lineage keys" {
    var marks: StagedHunkMarks = .{};
    defer marks.deinit(std.testing.allocator);

    const key = testHunkMarkKey(7, 2);
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", key);
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", key);

    try std.testing.expectEqual(@as(usize, 1), marks.items.items.len);
    try std.testing.expect(marks.containsExact("/repo", "src/app.zig", key));
    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", testHunkMarkKey(7, 3)));
    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", testHunkMarkKey(8, 2)));
    try std.testing.expect(!marks.containsExact("/other", "src/app.zig", key));

    try std.testing.expect(!marks.removeExact(std.testing.allocator, "/repo", "src/app.zig", testHunkMarkKey(8, 2)));
    try std.testing.expect(marks.removeExact(std.testing.allocator, "/repo", "src/app.zig", key));
    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", key));
    try std.testing.expectEqual(@as(usize, 0), marks.items.items.len);
}

test "StagedHunkMarks clearRepo removes only matching repository marks" {
    var marks: StagedHunkMarks = .{};
    defer marks.deinit(std.testing.allocator);

    const app_key = testHunkMarkKey(7, 2);
    const other_key = testHunkMarkKey(7, 1);
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", app_key);
    try marks.addExact(std.testing.allocator, "/other", "src/app.zig", app_key);
    try marks.addExact(std.testing.allocator, "/repo", "src/other.zig", other_key);

    marks.clearRepo(std.testing.allocator, "/repo");

    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", app_key));
    try std.testing.expect(!marks.containsExact("/repo", "src/other.zig", other_key));
    try std.testing.expect(marks.containsExact("/other", "src/app.zig", app_key));
    try std.testing.expectEqual(@as(usize, 1), marks.items.items.len);
}

test "StagedHunkMarks deduplicates rebind and preserves unrelated exact lineages" {
    var marks: StagedHunkMarks = .{};
    defer marks.deinit(std.testing.allocator);

    const from = testHunkMarkKey(7, 1).content;
    const to = testHunkMarkKey(8, 1).content;
    const unrelated = testHunkMarkKey(9, 1).content;

    // Keep the second source mark last. Removing the first source/destination
    // collision swap-moves it into the current index, proving the loop still
    // visits every matching mark after deduplication.
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", .{ .content = from, .display_hunk_index = 1 });
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", .{ .content = to, .display_hunk_index = 1 });
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", .{ .content = unrelated, .display_hunk_index = 1 });
    try marks.addExact(std.testing.allocator, "/repo", "src/other.zig", .{ .content = from, .display_hunk_index = 1 });
    try marks.addExact(std.testing.allocator, "/other", "src/app.zig", .{ .content = from, .display_hunk_index = 1 });
    try marks.addExact(std.testing.allocator, "/repo", "src/app.zig", .{ .content = from, .display_hunk_index = 2 });

    marks.rebindPathLineage(std.testing.allocator, "/repo", "src/app.zig", from, to);

    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", .{ .content = from, .display_hunk_index = 1 }));
    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", .{ .content = from, .display_hunk_index = 2 }));
    try std.testing.expect(marks.containsExact("/repo", "src/app.zig", .{ .content = to, .display_hunk_index = 1 }));
    try std.testing.expect(marks.containsExact("/repo", "src/app.zig", .{ .content = to, .display_hunk_index = 2 }));
    try std.testing.expect(marks.containsExact("/repo", "src/app.zig", .{ .content = unrelated, .display_hunk_index = 1 }));
    try std.testing.expect(marks.containsExact("/repo", "src/other.zig", .{ .content = from, .display_hunk_index = 1 }));
    try std.testing.expect(marks.containsExact("/other", "src/app.zig", .{ .content = from, .display_hunk_index = 1 }));
    try std.testing.expectEqual(@as(usize, 5), marks.items.items.len);

    marks.clearPathLineage(std.testing.allocator, "/repo", "src/app.zig", to);
    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", .{ .content = to, .display_hunk_index = 1 }));
    try std.testing.expect(!marks.containsExact("/repo", "src/app.zig", .{ .content = to, .display_hunk_index = 2 }));
    try std.testing.expect(marks.containsExact("/repo", "src/app.zig", .{ .content = unrelated, .display_hunk_index = 1 }));
    try std.testing.expect(marks.containsExact("/repo", "src/other.zig", .{ .content = from, .display_hunk_index = 1 }));
    try std.testing.expect(marks.containsExact("/other", "src/app.zig", .{ .content = from, .display_hunk_index = 1 }));
    try std.testing.expectEqual(@as(usize, 3), marks.items.items.len);
}

test "SecretInput clear zeroes backing buffer" {
    var input: SecretInput = .{};
    try input.insertSlice("token");
    input.clear();

    try std.testing.expectEqual(@as(usize, 0), input.len);
    try std.testing.expectEqual(@as(usize, 0), input.cursor);
    for (input.buffer) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
