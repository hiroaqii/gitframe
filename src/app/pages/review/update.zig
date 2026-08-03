//! Review-local semantic update ownership.
//!
//! Shell input, mouse hit-testing, and future Session API producers all route the
//! same `message.Msg` through this controller. State-only transitions terminate
//! here. Operations requiring overlays, processes, clipboard, Git tasks, or app
//! teardown return an explicit command to the App shell.

const std = @import("std");
const builtin = @import("builtin");
const message = @import("message.zig");
const navigation = @import("navigation.zig");
const context = @import("../../../context.zig");
const review_page = @import("../review.zig");
const review_selection = @import("selection.zig");
const diff_selection = @import("../../../diff/selection.zig");
const file_tree = if (builtin.is_test) @import("../../../file_tree.zig") else struct {};
const review_session = @import("../../../review/session.zig");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

pub const Command = union(enum) {
    enter_commit_panel,
    enter_amend_panel,
    toggle_selected_file,
    toggle_selected_hunk,
    request_discard_selected_file,
    request_push,
    request_pull,
    request_fetch,
    request_branch_switch,
    open_selected_file_in_editor,
    copy_current_line,
    copy_current_hunk,
    /// Separately owned clipboard bytes assembled from the installed page
    /// candidate. They never borrow the displayed diff/source owner.
    copy_diff_selection: []u8,
    /// Owns the cloned identity path until App consumes/deinitializes it.
    copy_diff_header_path: diff_selection.HeaderPathSelection,
    finish_review: review_session.Decision,

    pub fn deinit(self: *Command, allocator: ?std.mem.Allocator) void {
        switch (self.*) {
            .copy_diff_selection => |text| (allocator orelse unreachable).free(text),
            .copy_diff_header_path => |*selection| (allocator orelse unreachable).free(selection.identity.path_key),
            else => {},
        }
        self.* = undefined;
    }
};

pub const ReviewUpdate = struct {
    command: ?Command = null,
    capture_display_override: bool = false,

    pub fn deinit(self: *ReviewUpdate, allocator: ?std.mem.Allocator) void {
        if (self.command) |*command| command.deinit(allocator);
        self.* = .{};
    }

    pub fn takeCommand(self: *ReviewUpdate) ?Command {
        const command = self.command;
        self.command = null;
        return command;
    }
};

pub const Controller = struct {
    navigation: navigation.Controller,

    /// `allocator` may be null only for transitions that neither allocate nor
    /// return an owned command. Runtime App initialization always supplies one;
    /// the optional form keeps pure page transitions independent of Chasen Ctx.
    pub fn apply(self: Controller, allocator: ?std.mem.Allocator, msg: message.Msg) !ReviewUpdate {
        const tracks_navigation = tracksDisplayNavigation(msg);
        const before = if (tracks_navigation) self.navigation.view().displayNavigationSnapshot() else undefined;
        const tracks_sidebar_selection = tracksExplicitSidebarSelection(msg);
        const sidebar_before = if (tracks_sidebar_selection) sidebarSelectionSnapshot(self.navigation) else undefined;

        var result: ReviewUpdate = .{};
        var adapter = self.navigation.updateAdapter();
        if (try adapter.shared().apply(allocator, msg) == null) {
            switch (msg) {
                .mouse_diff_release => result.command = try self.releaseDiffMouse(allocator orelse return error.MissingAllocator),
                .enter_commit_panel => result.command = .enter_commit_panel,
                .enter_amend_panel => result.command = .enter_amend_panel,
                .toggle_selected_file => result.command = .toggle_selected_file,
                .toggle_selected_hunk => result.command = .toggle_selected_hunk,
                .request_discard_selected_file => result.command = .request_discard_selected_file,
                .request_push => result.command = .request_push,
                .request_pull => result.command = .request_pull,
                .request_fetch => result.command = .request_fetch,
                .request_branch_switch => result.command = .request_branch_switch,
                .open_selected_file_in_editor => result.command = .open_selected_file_in_editor,
                .copy_current_line => result.command = .copy_current_line,
                .copy_current_hunk => result.command = .copy_current_hunk,
                .finish_review_approved => result.command = .{ .finish_review = .approved },
                .finish_review_needs_changes => result.command = .{ .finish_review = .needs_changes },
                .finish_review_canceled => result.command = .{ .finish_review = .canceled },
                else => unreachable,
            }
        }

        // This boundary sees semantic Review input after it has either changed
        // the sidebar/file intent or proved to be a no-op. Internal tree
        // rebuild/remap helpers never pass through here, so they cannot revoke
        // an action's restoration authority accidentally.
        if (tracks_sidebar_selection) {
            const sidebar_after = sidebarSelectionSnapshot(self.navigation);
            if (!std.meta.eql(sidebar_before, sidebar_after)) {
                _ = self.navigation.page.action_cursor.supersedeRestore();
            }
        }

        if (tracks_navigation) {
            const after = self.navigation.view().displayNavigationSnapshot();
            if (!std.meta.eql(before, after)) {
                self.navigation.page.display_navigation_input_revision +%= 1;
                result.capture_display_override = self.navigation.page.pending_display_navigation_restore != null;
            }
        }
        return result;
    }

    fn releaseDiffMouse(self: Controller, allocator: std.mem.Allocator) !?Command {
        const owner = self.navigation.page.selection_owner;
        return switch (owner) {
            .none => null,
            .diff => |selection| blk: {
                if (!selection.moved) {
                    self.navigation.clearDiffSelection();
                    break :blk null;
                }

                var candidate = self.buildCompletedSelection(allocator, selection) catch {
                    if (self.navigation.page.completed_selection) |*prior| prior.deinit(allocator);
                    self.navigation.page.completed_selection = null;
                    self.navigation.clearDiffSelection();
                    break :blk null;
                };
                if (self.navigation.page.completed_selection) |*prior| prior.deinit(allocator);
                self.navigation.page.completed_selection = candidate;
                candidate = undefined;
                self.navigation.clearDiffSelection();

                const clipboard = self.navigation.page.completed_selection.?.clipboardText(allocator) catch break :blk null;
                break :blk .{ .copy_diff_selection = clipboard };
            },
            .diff_header => |selection| blk: {
                const command: Command = .{ .copy_diff_header_path = try cloneHeaderSelection(allocator, selection) };
                self.navigation.clearDiffSelection();
                break :blk command;
            },
        };
    }

    fn buildCompletedSelection(self: Controller, allocator: std.mem.Allocator, selection: diff_selection.DragSelection) !review_selection.CompletedSelection {
        const token = self.navigation.view().currentContentToken() orelse return error.StaleSelection;
        return switch (selection.identity) {
            .loaded_file, .projection_file => blk: {
                const target = self.navigation.view().parsedSelectionTarget(selection.identity) orelse return error.StaleSelection;
                break :blk try review_selection.buildParsed(allocator, token, target.file, selection);
            },
            .generated_file => |generated| blk: {
                const body = self.navigation.view().generatedBody() orelse return error.StaleSelection;
                if (!std.mem.eql(u8, generated.path_key, body.path)) return error.StaleSelection;
                break :blk try review_selection.buildGenerated(allocator, token, body.path, body.source, selection);
            },
        };
    }
};

const SidebarSelectionSnapshot = struct {
    selected_target: ?context.SelectedTarget,
    selected_node: usize,
};

fn sidebarSelectionSnapshot(controller: navigation.Controller) SidebarSelectionSnapshot {
    return .{
        .selected_target = controller.page.viewer.selected_target,
        .selected_node = controller.page.viewer.selected_node,
    };
}

fn tracksExplicitSidebarSelection(msg: message.Msg) bool {
    return switch (msg) {
        .select_previous_file,
        .select_next_file,
        .select_first_file,
        .select_last_file,
        .toggle_directory,
        .expand_directory,
        .collapse_or_parent_directory,
        .sidebar_click_node,
        .mouse_sidebar_wheel_up,
        .mouse_sidebar_wheel_down,
        .submit_file_search,
        => true,
        else => false,
    };
}

fn tracksDisplayNavigation(msg: message.Msg) bool {
    return switch (msg) {
        .select_previous_file,
        .select_next_file,
        .toggle_directory,
        .expand_directory,
        .collapse_or_parent_directory,
        .scroll_diff_up,
        .scroll_diff_down,
        .scroll_diff_left,
        .scroll_diff_right,
        .scroll_sidebar_left,
        .scroll_sidebar_right,
        .page_diff_up,
        .page_diff_down,
        .select_previous_hunk,
        .select_next_hunk,
        .toggle_hunk_fold,
        .select_first_file,
        .select_last_file,
        .sidebar_click_node,
        .mouse_sidebar_wheel_up,
        .mouse_sidebar_wheel_down,
        .mouse_diff_wheel_up,
        .mouse_diff_wheel_down,
        .mouse_diff_wheel_left,
        .mouse_diff_wheel_right,
        .toggle_display_mode,
        .clear_search,
        .submit_search,
        .select_next_search_match,
        .select_previous_search_match,
        .submit_file_search,
        => true,
        else => false,
    };
}

fn cloneHeaderSelection(allocator: std.mem.Allocator, selection: diff_selection.HeaderPathSelection) !diff_selection.HeaderPathSelection {
    var cloned = selection;
    cloned.identity.path_key = try allocator.dupe(u8, selection.identity.path_key);
    return cloned;
}

test "review update owns state transition and shell intent" {
    var page: @import("../review.zig").ReviewPageState = .{};
    var controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var state_update = try controller.apply(std.testing.allocator, .toggle_focus);
    defer state_update.deinit(std.testing.allocator);
    try std.testing.expectEqual(@import("../review.zig").Focus.diff, page.viewer.focus);
    try std.testing.expect(state_update.command == null);

    var shell_update = try controller.apply(std.testing.allocator, .request_push);
    defer shell_update.deinit(std.testing.allocator);
    try std.testing.expectEqual(Command.request_push, shell_update.command.?);
}

fn installUpdateTestActionCursor(
    page: *review_page.ReviewPageState,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var prepared = try review_page.action_cursor.Prepared.init(
        allocator,
        3,
        .{ .device = 5, .inode = 8 },
        .file,
        path,
        0,
    );
    page.action_cursor.install(allocator, &prepared, 7);
}

test "explicit sidebar update supersedes action restore while internal remap does not" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadStateWithArena(arena, loaded),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_node = 0 },
    };
    defer page.deinit(allocator);
    try installUpdateTestActionCursor(&page, allocator, "a");

    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = "/repo",
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    controller.navigation.selectSidebarNode(controller.navigation.activeLoadedDiff().?, 1);
    controller.navigation.selectSidebarNode(controller.navigation.activeLoadedDiff().?, 0);
    try std.testing.expect(page.action_cursor.hasRestoreAuthority());

    var explicit = try controller.apply(null, .select_next_file);
    explicit.deinit(null);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, page.viewer.selected_target.?);
    try std.testing.expect(!page.action_cursor.hasRestoreAuthority());
    try std.testing.expect(page.action_cursor.hasOwner());

    try std.testing.expect(page.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .status_only));
    try std.testing.expect(page.action_cursor.startMember(7, .status, 11));
    try std.testing.expect(page.action_cursor.finishMember(7, 3, .status, 11, true));
    try std.testing.expect(controller.navigation.finalizeActionCursor(allocator));
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, page.viewer.selected_target.?);
}

test "file search supersedes action restore only when submit changes selection" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadStateWithArena(arena, loaded),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_node = 0 },
        .source_session_revision = 5,
        .accepted_sidebar_revision = 7,
    };
    defer page.deinit(allocator);
    try installUpdateTestActionCursor(&page, allocator, "a");
    const controller: Controller = .{
        .navigation = .{
            .page = &page,
            .repo_root = "/repo",
            .repo_epoch = 3,
            .source = .unstaged,
            .layout = .{ .width = 80, .height = 20 },
            .diagnostics = .{ .target = &page.status },
        },
    };

    var enter_same = try controller.apply(allocator, .enter_file_search);
    enter_same.deinit(allocator);
    var submit_same = try controller.apply(allocator, .submit_file_search);
    submit_same.deinit(allocator);
    try std.testing.expect(page.action_cursor.hasRestoreAuthority());

    var enter_other = try controller.apply(allocator, .enter_file_search);
    enter_other.deinit(allocator);
    var move_candidate = try controller.apply(null, .file_search_next);
    move_candidate.deinit(null);
    try std.testing.expect(page.action_cursor.hasRestoreAuthority());
    var submit_other = try controller.apply(allocator, .submit_file_search);
    submit_other.deinit(allocator);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, page.viewer.selected_target.?);
    try std.testing.expect(!page.action_cursor.hasRestoreAuthority());

    // The superseded action still reaches its exact terminal and cleans up.
    try std.testing.expect(page.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .status_only));
    try std.testing.expect(page.action_cursor.startMember(7, .status, 11));
    try std.testing.expect(page.action_cursor.finishMember(7, 3, .status, 11, true));
    try std.testing.expect(controller.navigation.finalizeActionCursor(allocator));

    // Wheel selection uses the same post-transition authority boundary while
    // a later action is already waiting for its status refresh.
    try installUpdateTestActionCursor(&page, allocator, "b");
    try std.testing.expect(page.action_cursor.promote(7, 3, .{ .device = 5, .inode = 8 }, .status_only));
    try std.testing.expect(page.action_cursor.startMember(7, .status, 12));
    var wheel = try controller.apply(null, .mouse_sidebar_wheel_up);
    wheel.deinit(null);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, page.viewer.selected_target.?);
    try std.testing.expect(!page.action_cursor.hasRestoreAuthority());
    try std.testing.expect(page.action_cursor.finishMember(7, 3, .status, 12, true));
    try std.testing.expect(controller.navigation.finalizeActionCursor(allocator));
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, page.viewer.selected_target.?);
}

test "explicit parent selection supersedes file action restore" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = test_support.loadedDiffRootedNested();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var page: review_page.ReviewPageState = .{
        .load = test_support.loadStateWithArena(arena, loaded),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .selected_node = 2 },
    };
    defer page.deinit(allocator);
    try installUpdateTestActionCursor(&page, allocator, "src/a");
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = "/repo",
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var parent = try controller.apply(allocator, .collapse_or_parent_directory);
    parent.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), page.viewer.selected_node);
    try std.testing.expect(!page.action_cursor.hasRestoreAuthority());
}

const file_search_input_nodes = [_]file_tree.Node{
    .{ .kind = .file, .name = "a", .path = "a", .path_key = "a", .depth = 0, .status = .modified, .target = .{ .diff_file = 0 } },
    .{ .kind = .file, .name = "b", .path = "b", .path_key = "b", .depth = 0, .status = .added, .target = .{ .diff_file = 1 } },
};

test "review file search publishes candidates from enter and input edits" {
    const allocator = std.testing.allocator;
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    var page: @import("../review.zig").ReviewPageState = .{
        .load = test_support.loadState(loaded),
        .source_session_revision = 5,
        .accepted_sidebar_revision = 7,
    };
    defer page.deinit(allocator);
    const controller: Controller = .{
        .navigation = .{
            .page = &page,
            .repo_root = null,
            .repo_epoch = 3,
            .source = .unstaged,
            .layout = .{ .width = 80, .height = 20 },
            .diagnostics = .{ .target = &page.status },
        },
    };

    var entered = try controller.apply(allocator, .enter_file_search);
    entered.deinit(allocator);
    try std.testing.expect(page.file_search.mode);
    try std.testing.expect(page.file_search.projection_available);
    try std.testing.expectEqualStrings("", page.file_search.input.slice());
    try std.testing.expectEqual(@as(usize, 2), page.file_search.candidates.len);
    try std.testing.expectEqualStrings("a", page.file_search.focusedCandidate().?.path_key);
    try std.testing.expect(page.file_search.basis.?.eql(.{
        .repo_epoch = 3,
        .source_session_revision = 5,
        .accepted_sidebar_revision = 7,
    }));

    const basis_before_movement = page.file_search.basis.?;
    var previous_at_start = try controller.apply(null, .file_search_previous);
    previous_at_start.deinit(null);
    try std.testing.expectEqualStrings("a", page.file_search.focusedCandidate().?.path_key);

    var next = try controller.apply(null, .file_search_next);
    next.deinit(null);
    try std.testing.expectEqualStrings("b", page.file_search.focusedCandidate().?.path_key);

    var next_at_end = try controller.apply(null, .file_search_next);
    next_at_end.deinit(null);
    try std.testing.expectEqualStrings("b", page.file_search.focusedCandidate().?.path_key);

    var previous = try controller.apply(null, .file_search_previous);
    previous.deinit(null);
    try std.testing.expectEqualStrings("a", page.file_search.focusedCandidate().?.path_key);
    try std.testing.expectEqualStrings("", page.file_search.input.slice());
    try std.testing.expect(page.file_search.basis.?.eql(basis_before_movement));

    var inserted = try controller.apply(allocator, .{ .file_search_insert = 'b' });
    inserted.deinit(allocator);
    try std.testing.expectEqualStrings("b", page.file_search.input.slice());
    try std.testing.expectEqual(@as(usize, 1), page.file_search.candidates.len);
    try std.testing.expectEqualStrings("b", page.file_search.focusedCandidate().?.path_key);

    var erased = try controller.apply(allocator, .file_search_backspace);
    erased.deinit(allocator);
    try std.testing.expectEqualStrings("", page.file_search.input.slice());
    try std.testing.expectEqual(@as(usize, 2), page.file_search.candidates.len);
    try std.testing.expectEqualStrings("a", page.file_search.focusedCandidate().?.path_key);

    var pasted = try controller.apply(allocator, .{ .file_search_paste = "missing" });
    pasted.deinit(allocator);
    try std.testing.expectEqualStrings("missing", page.file_search.input.slice());
    try std.testing.expect(page.file_search.projection_available);
    try std.testing.expect(page.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
    try std.testing.expect(page.file_search.focusedCandidate() == null);

    var no_match_movement = try controller.apply(null, .file_search_next);
    no_match_movement.deinit(null);
    try std.testing.expectEqualStrings("missing", page.file_search.input.slice());
    try std.testing.expect(page.file_search.no_match);
    try std.testing.expect(page.file_search.focusedCandidate() == null);

    var suffix: [512]u8 = undefined;
    @memset(&suffix, 'x');
    const remaining = page.file_search.input.buffer.len - page.file_search.input.len;
    var filled = try controller.apply(allocator, .{ .file_search_paste = suffix[0..remaining] });
    filled.deinit(allocator);
    const basis_before_overflow = page.file_search.basis.?;
    try std.testing.expectEqual(page.file_search.input.buffer.len, page.file_search.input.len);
    try std.testing.expect(page.file_search.no_match);

    // A rejected fixed-capacity edit is not a new query generation. It must
    // not require an allocator or disturb the projection for the old input.
    var overflow_insert = try controller.apply(null, .{ .file_search_insert = 'z' });
    overflow_insert.deinit(null);
    try std.testing.expectEqual(page.file_search.input.buffer.len, page.file_search.input.len);
    try std.testing.expect(page.file_search.no_match);
    try std.testing.expect(page.file_search.basis.?.eql(basis_before_overflow));
    try std.testing.expectEqualStrings("file search query is too long", page.status.text());

    page.status.clear();
    var overflow_paste = try controller.apply(null, .{ .file_search_paste = "z" });
    overflow_paste.deinit(null);
    try std.testing.expectEqual(page.file_search.input.buffer.len, page.file_search.input.len);
    try std.testing.expect(page.file_search.no_match);
    try std.testing.expect(page.file_search.basis.?.eql(basis_before_overflow));
    try std.testing.expectEqualStrings("file search query is too long", page.status.text());
}

test "review file search candidate failure retains edited input as unavailable" {
    const allocator = std.testing.allocator;
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    var page: @import("../review.zig").ReviewPageState = .{
        .load = test_support.loadState(loaded),
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var entered = try controller.apply(allocator, .enter_file_search);
    entered.deinit(allocator);
    try std.testing.expect(page.file_search.projection_available);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var inserted = try controller.apply(failing.allocator(), .{ .file_search_insert = 'b' });
    inserted.deinit(failing.allocator());

    // Prompt editing is fixed-capacity and already committed before the
    // separately-owned candidate projection is prepared. Allocation failure
    // must not roll the text back or leave candidates from the old query live.
    try std.testing.expectEqualStrings("b", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(!page.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.candidates.len);
    try std.testing.expect(page.file_search.basis == null);
    try std.testing.expect(page.file_search.focusedCandidate() == null);

    var unavailable_movement = try controller.apply(null, .file_search_next);
    unavailable_movement.deinit(null);
    try std.testing.expectEqualStrings("b", page.file_search.input.slice());
    try std.testing.expect(!page.file_search.projection_available);
    try std.testing.expect(page.file_search.focusedCandidate() == null);
}

test "review file search missing allocator preserves the published query generation" {
    const allocator = std.testing.allocator;
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    var page: @import("../review.zig").ReviewPageState = .{
        .load = test_support.loadState(loaded),
        .source_session_revision = 5,
        .accepted_sidebar_revision = 7,
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .repo_epoch = 3,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var entered = try controller.apply(allocator, .enter_file_search);
    entered.deinit(allocator);
    const empty_basis = page.file_search.basis.?;
    for ([_]message.Msg{
        .{ .file_search_insert = 'b' },
        .{ .file_search_paste = "b" },
    }) |edit| {
        try std.testing.expectError(error.MissingAllocator, controller.apply(null, edit));
        try std.testing.expectEqualStrings("", page.file_search.input.slice());
        try std.testing.expect(page.file_search.projection_available);
        try std.testing.expect(!page.file_search.no_match);
        try std.testing.expectEqual(@as(usize, 2), page.file_search.candidates.len);
        try std.testing.expectEqual(@as(usize, 0), page.file_search.filter.list.focusedIndex());
        try std.testing.expectEqualStrings("a", page.file_search.focusedCandidate().?.path_key);
        try std.testing.expect(page.file_search.basis.?.eql(empty_basis));
    }

    var inserted = try controller.apply(allocator, .{ .file_search_insert = 'a' });
    inserted.deinit(allocator);
    const a_basis = page.file_search.basis.?;
    try std.testing.expectError(error.MissingAllocator, controller.apply(null, .file_search_backspace));
    try std.testing.expectEqualStrings("a", page.file_search.input.slice());
    try std.testing.expect(page.file_search.projection_available);
    try std.testing.expect(!page.file_search.no_match);
    try std.testing.expectEqual(@as(usize, 1), page.file_search.candidates.len);
    try std.testing.expectEqual(@as(usize, 0), page.file_search.filter.list.focusedIndex());
    try std.testing.expectEqualStrings("a", page.file_search.focusedCandidate().?.path_key);
    try std.testing.expect(page.file_search.basis.?.eql(a_basis));
}

test "review mouse release returns one owned copy command" {
    var page: @import("../review.zig").ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
    };
    defer page.deinit(std.testing.allocator);
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    } };
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var update = try controller.apply(std.testing.allocator, .{ .mouse_diff_release = null });
    defer update.deinit(std.testing.allocator);
    try std.testing.expectEqual(diff_selection.Owner.none, page.selection_owner);

    var command = update.takeCommand() orelse return error.ExpectedCopyCommand;
    defer command.deinit(std.testing.allocator);
    switch (command) {
        .copy_diff_selection => |text| try std.testing.expectEqualStrings("one\ntwo\nnew\n", text),
        else => return error.ExpectedCopyCommand,
    }
    try std.testing.expect(page.completed_selection != null);

    const retained_token = page.completed_selection.?.token;
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 0 },
        .moved = false,
    } };
    var click = try controller.apply(std.testing.allocator, .{ .mouse_diff_release = null });
    defer click.deinit(std.testing.allocator);
    try std.testing.expect(click.command == null);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.completed_selection.?.token.eql(retained_token));
}

test "failed moved release clears prior candidate without emitting clipboard work" {
    const allocator = std.testing.allocator;
    var page: @import("../review.zig").ReviewPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var accepted = try controller.apply(allocator, .{ .mouse_diff_release = null });
    defer accepted.deinit(allocator);
    try std.testing.expect(page.completed_selection != null);

    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "different" } },
        .side = .new,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var rejected = try controller.apply(allocator, .{ .mouse_diff_release = null });
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.command == null);
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expect(page.selection_owner == .none);
}

test "clipboard allocation failure retains the accepted candidate" {
    const backing = std.testing.allocator;
    var observed_clipboard_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 16 and !observed_clipboard_failure) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = fail_index });
        var page: @import("../review.zig").ReviewPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
        };
        defer page.deinit(failing.allocator());
        page.selection_owner = .{ .diff = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .side = .new,
            .anchor = .{ .hunk_index = 0, .line_index = 0 },
            .focus = .{ .hunk_index = 0, .line_index = 1 },
            .moved = true,
        } };
        const controller: Controller = .{ .navigation = .{
            .page = &page,
            .repo_root = null,
            .source = .unstaged,
            .layout = .{ .width = 80, .height = 20 },
            .diagnostics = .{ .target = &page.status },
        } };

        var update = try controller.apply(failing.allocator(), .{ .mouse_diff_release = null });
        defer update.deinit(failing.allocator());
        if (page.completed_selection != null and update.command == null) {
            observed_clipboard_failure = true;
            try std.testing.expect(page.selection_owner == .none);
        }
    }
    try std.testing.expect(observed_clipboard_failure);
}
