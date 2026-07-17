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
const review_selection = @import("selection.zig");
const diff_selection = @import("../../../diff/selection.zig");
const root_capability = @import("../../../repo/root_capability.zig");
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
    repo_epoch: u64 = 0,
    root_identity: ?root_capability.Identity = null,

    /// `allocator` may be null only for transitions that neither allocate nor
    /// return an owned command. Runtime App initialization always supplies one;
    /// the optional form keeps pure page transitions independent of Chasen Ctx.
    pub fn apply(self: Controller, allocator: ?std.mem.Allocator, msg: message.Msg) !ReviewUpdate {
        const tracks_navigation = tracksDisplayNavigation(msg);
        const before = if (tracks_navigation) self.navigation.view().displayNavigationSnapshot() else undefined;

        var result: ReviewUpdate = .{};
        switch (msg) {
            .select_previous_file => self.navigation.selectFileDelta(-1),
            .select_next_file => self.navigation.selectFileDelta(1),
            .toggle_directory => try self.navigation.toggleSelectedDirectory(),
            .expand_directory => try self.navigation.expandSelectedDirectory(),
            .collapse_or_parent_directory => try self.navigation.collapseOrSelectParentDirectory(),
            .scroll_diff_up => self.navigation.moveDiffCursorRows(.up),
            .scroll_diff_down => self.navigation.moveDiffCursorRows(.down),
            .scroll_diff_left => self.navigation.scrollDiffHorizontal(.left),
            .scroll_diff_right => self.navigation.scrollDiffHorizontal(.right),
            .scroll_sidebar_left => self.navigation.scrollSidebarHorizontal(.left),
            .scroll_sidebar_right => self.navigation.scrollSidebarHorizontal(.right),
            .page_diff_up => self.navigation.moveDiffCursorPage(.up),
            .page_diff_down => self.navigation.moveDiffCursorPage(.down),
            .select_previous_hunk => self.navigation.selectHunkDelta(-1),
            .select_next_hunk => self.navigation.selectHunkDelta(1),
            .toggle_hunk_fold => self.navigation.toggleSelectedHunkFold(),
            .select_first_file => self.navigation.selectFileAbsolute(0),
            .select_last_file => self.navigation.selectLastFile(),
            .toggle_focus => {
                if (!self.navigation.page.viewer.sidebar_hidden) {
                    self.navigation.page.viewer.focus = self.navigation.page.viewer.focus.toggled();
                }
            },
            .toggle_sidebar_visibility => self.navigation.toggleSidebarVisibility(),
            .decrease_sidebar_width => self.navigation.adjustSidebarWidth(.shrink),
            .increase_sidebar_width => self.navigation.adjustSidebarWidth(.grow),
            .focus_sidebar => {
                if (!self.navigation.page.viewer.sidebar_hidden) self.navigation.page.viewer.focus = .sidebar;
            },
            .focus_diff => self.navigation.page.viewer.focus = .diff,
            .sidebar_click_node => |node_index| try self.navigation.clickSidebarNode(node_index),
            .mouse_sidebar_wheel_up => {
                if (!self.navigation.page.viewer.sidebar_hidden) self.navigation.page.viewer.focus = .sidebar;
                self.navigation.selectFileDelta(-1);
            },
            .mouse_sidebar_wheel_down => {
                if (!self.navigation.page.viewer.sidebar_hidden) self.navigation.page.viewer.focus = .sidebar;
                self.navigation.selectFileDelta(1);
            },
            .mouse_diff_wheel_up => {
                self.navigation.page.viewer.focus = .diff;
                self.navigation.scrollDiff(.up);
            },
            .mouse_diff_wheel_down => {
                self.navigation.page.viewer.focus = .diff;
                self.navigation.scrollDiff(.down);
            },
            .mouse_diff_wheel_left => {
                self.navigation.page.viewer.focus = .diff;
                self.navigation.scrollDiffHorizontal(.left);
            },
            .mouse_diff_wheel_right => {
                self.navigation.page.viewer.focus = .diff;
                self.navigation.scrollDiffHorizontal(.right);
            },
            .mouse_diff_press => |point| self.navigation.pressDiffMouse(point),
            .mouse_diff_drag => |point| self.navigation.dragDiffMouse(point),
            .mouse_diff_release => result.command = try self.releaseDiffMouse(allocator orelse return error.MissingAllocator),
            .toggle_display_mode => {
                self.navigation.clearDiffSelection();
                const old_mode = self.navigation.view().effectiveDisplayMode();
                const old_scroll = self.navigation.page.viewer.diff_scroll;
                self.navigation.page.viewer.display_mode = self.navigation.page.viewer.display_mode.toggled();
                const new_mode = self.navigation.view().effectiveDisplayMode();
                self.navigation.page.viewer.diff_scroll = self.navigation.view().remapDiffScrollForModeChange(old_mode, new_mode, old_scroll);
                self.navigation.resetDiffHorizontalScroll();
                self.navigation.updateSearchMatchOffset();
                self.navigation.scrollSearchMatchIntoView();
                self.navigation.applyDiffCursorScrolloff();
                self.navigation.clampDiffNavigation();
            },
            .toggle_line_numbers => {
                self.navigation.page.viewer.view_options.toggleLineNumbers();
                self.navigation.clampDiffHorizontalScrollToVisibleRows();
            },
            .enter_search => self.navigation.enterSearchMode(),
            .cancel_search => self.navigation.cancelSearchMode(),
            .clear_search => self.navigation.clearSearch(),
            .submit_search => self.navigation.submitSearch(),
            .search_insert => |codepoint| self.navigation.page.search.input.insert(codepoint) catch {
                self.navigation.page.status.set("search query is too long", .{});
            },
            .search_paste => |text| self.navigation.page.search.input.insertSlice(text) catch {
                self.navigation.page.status.set("search query is too long", .{});
            },
            .search_backspace => self.navigation.page.search.input.backspace(),
            .search_move_left => self.navigation.page.search.input.moveLeft(),
            .search_move_right => self.navigation.page.search.input.moveRight(),
            .select_next_search_match => self.navigation.selectSearchMatch(.forward),
            .select_previous_search_match => self.navigation.selectSearchMatch(.backward),
            .enter_file_search => self.navigation.enterFileSearchMode(),
            .cancel_file_search => self.navigation.cancelFileSearchMode(allocator orelse return error.MissingAllocator),
            .submit_file_search => try self.navigation.submitFileSearch(allocator orelse return error.MissingAllocator),
            .file_search_insert => |codepoint| {
                self.navigation.page.file_search.resetNoMatch();
                self.navigation.page.file_search.input.insert(codepoint) catch {
                    self.navigation.page.status.set("file search query is too long", .{});
                };
            },
            .file_search_paste => |text| {
                self.navigation.page.file_search.resetNoMatch();
                self.navigation.page.file_search.input.insertSlice(text) catch {
                    self.navigation.page.status.set("file search query is too long", .{});
                };
            },
            .file_search_backspace => {
                self.navigation.page.file_search.resetNoMatch();
                self.navigation.page.file_search.input.backspace();
            },
            .toggle_reviewed_file => try self.navigation.toggleReviewedFile(allocator orelse return error.MissingAllocator),
            .toggle_hide_reviewed_files => try self.navigation.toggleHideReviewedFiles(allocator orelse return error.MissingAllocator),
            .cycle_changed_file_filter => try self.navigation.cycleChangedFileFilter(allocator orelse return error.MissingAllocator),
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
        const token = self.contentToken(selection) orelse return error.StaleSelection;
        return switch (selection.identity) {
            .loaded_file, .projection_file => blk: {
                const target = self.navigation.view().parsedSelectionTarget(selection.identity) orelse return error.StaleSelection;
                break :blk try review_selection.buildParsed(allocator, token, target.file, selection);
            },
            .generated_file => |generated| blk: {
                const bundle = self.navigation.view().activeGeneratedFileProjection() orelse return error.StaleSelection;
                if (!std.mem.eql(u8, generated.path_key, bundle.path)) return error.StaleSelection;
                break :blk try review_selection.buildGenerated(allocator, token, bundle.path, &bundle.source, selection);
            },
        };
    }

    fn contentToken(self: Controller, selection: diff_selection.DragSelection) ?review_selection.ReviewContentToken {
        const page = self.navigation.page;
        const display: review_selection.DisplayBasis = switch (self.navigation.view().displayedReviewBody()) {
            .primary => |primary| .{ .loaded = .init(primary.loaded.text) },
            .cached => |bundle| .{ .cached_projection = .{
                .status_snapshot_revision = page.status_snapshot_revision,
                .cached = bundle.fingerprint,
            } },
            .combined => |bundle| .{ .combined_projection = .{
                .status_snapshot_revision = page.status_snapshot_revision,
                .cached = bundle.cached_bundle.fingerprint,
                .unstaged = bundle.unstaged_bundle.fingerprint,
            } },
            .generated => |bundle| .{ .generated_untracked = .{
                .status_snapshot_revision = page.status_snapshot_revision,
                .source = bundle.fingerprint(),
            } },
            .none, .inert_invalid_utf8, .status, .pending => return null,
        };
        _ = selection;
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .source = review_selection.SourceBasis.init(self.navigation.source),
            .source_session_revision = page.source_session_revision,
            .display = display,
        };
    }
};

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
