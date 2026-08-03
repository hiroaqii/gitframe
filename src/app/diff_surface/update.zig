//! Page-independent semantic updates for a diff surface.
//!
const std = @import("std");
const context = @import("../../context.zig");
const diff_selection = @import("../../diff/selection.zig");
const navigation = @import("navigation.zig");
const message = @import("message.zig");
const selection = @import("selection.zig");

/// Owned output which a page adapter translates into its physical effect.
pub const Effect = union(enum) {
    copy_diff_selection: []u8,
    copy_diff_header_path: diff_selection.HeaderPathSelection,

    pub fn deinit(self: *Effect, allocator: ?std.mem.Allocator) void {
        switch (self.*) {
            .copy_diff_selection => |text| (allocator orelse unreachable).free(text),
            .copy_diff_header_path => |*header| (allocator orelse unreachable).free(header.identity.path_key),
        }
        self.* = undefined;
    }
};

/// One handled shared transition and the value-only facts needed by page-local
/// epilogues. The effect remains owned here until a page adapter takes it.
pub const Update = struct {
    effect: ?Effect = null,
    explicit_sidebar_selection_changed: bool = false,
    display_navigation_changed: bool = false,

    pub fn deinit(self: *Update, allocator: ?std.mem.Allocator) void {
        if (self.effect) |*effect| effect.deinit(allocator);
        self.* = .{};
    }

    pub fn takeEffect(self: *Update) ?Effect {
        const effect = self.effect;
        self.effect = null;
        return effect;
    }
};

pub const Hook = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque) void,

    pub fn call(self: Hook) void {
        self.callback(self.ctx);
    }
};

pub const Controller = struct {
    navigation: navigation.BodyController,
    /// Review retains a richer mixed-stage fold presentation policy. Compare
    /// can use the shared body operation directly.
    toggle_hunk_fold: ?Hook = null,

    pub fn apply(self: Controller, allocator: ?std.mem.Allocator, msg: message.Msg) !Update {
        const tracks_navigation = tracksDisplayNavigation(msg);
        const before = if (tracks_navigation) self.navigation.view().view.displayNavigationSnapshot() else undefined;
        const tracks_sidebar_selection = tracksExplicitSidebarSelection(msg);
        const sidebar_before = if (tracks_sidebar_selection) sidebarSelectionSnapshot(self.navigation) else undefined;

        var result: Update = .{};
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
            .scroll_sidebar_left => self.navigation.controller.scrollSidebarHorizontal(.left),
            .scroll_sidebar_right => self.navigation.controller.scrollSidebarHorizontal(.right),
            .page_diff_up => self.navigation.moveDiffCursorPage(.up),
            .page_diff_down => self.navigation.moveDiffCursorPage(.down),
            .select_previous_hunk => self.navigation.selectHunkDelta(-1),
            .select_next_hunk => self.navigation.selectHunkDelta(1),
            .toggle_hunk_fold => if (self.toggle_hunk_fold) |hook| hook.call() else self.navigation.toggleSelectedHunkFold(),
            .select_first_file => self.navigation.selectFileAbsolute(0),
            .select_last_file => self.navigation.selectLastFile(),
            .toggle_focus => {
                if (!self.navigation.controller.surface.viewer.sidebar_hidden) {
                    self.navigation.controller.surface.viewer.focus = self.navigation.controller.surface.viewer.focus.toggled();
                }
            },
            .toggle_sidebar_visibility => self.navigation.toggleSidebarVisibility(),
            .decrease_sidebar_width => self.navigation.adjustSidebarWidth(.shrink),
            .increase_sidebar_width => self.navigation.adjustSidebarWidth(.grow),
            .focus_sidebar => {
                if (!self.navigation.controller.surface.viewer.sidebar_hidden) self.navigation.controller.surface.viewer.focus = .sidebar;
            },
            .focus_diff => self.navigation.controller.surface.viewer.focus = .diff,
            .sidebar_click_node => |node_index| try self.navigation.clickSidebarNode(node_index),
            .mouse_sidebar_wheel_up => {
                if (!self.navigation.controller.surface.viewer.sidebar_hidden) self.navigation.controller.surface.viewer.focus = .sidebar;
                self.navigation.selectFileDelta(-1);
            },
            .mouse_sidebar_wheel_down => {
                if (!self.navigation.controller.surface.viewer.sidebar_hidden) self.navigation.controller.surface.viewer.focus = .sidebar;
                self.navigation.selectFileDelta(1);
            },
            .mouse_diff_wheel_up => {
                self.navigation.controller.surface.viewer.focus = .diff;
                self.navigation.scrollDiff(.up);
            },
            .mouse_diff_wheel_down => {
                self.navigation.controller.surface.viewer.focus = .diff;
                self.navigation.scrollDiff(.down);
            },
            .mouse_diff_wheel_left => {
                self.navigation.controller.surface.viewer.focus = .diff;
                self.navigation.scrollDiffHorizontal(.left);
            },
            .mouse_diff_wheel_right => {
                self.navigation.controller.surface.viewer.focus = .diff;
                self.navigation.scrollDiffHorizontal(.right);
            },
            .mouse_diff_press => |point| self.navigation.pressDiffMouse(point),
            .mouse_diff_drag => |point| self.navigation.dragDiffMouse(point),
            .mouse_diff_release => result.effect = try self.releaseDiffMouse(allocator orelse return error.MissingAllocator),
            .toggle_display_mode => {
                self.navigation.controller.clearDiffSelection();
                const old_mode = self.navigation.controller.view().effectiveDisplayMode();
                const old_scroll = self.navigation.controller.surface.viewer.diff_scroll;
                self.navigation.controller.surface.viewer.display_mode = self.navigation.controller.surface.viewer.display_mode.toggled();
                const new_mode = self.navigation.controller.view().effectiveDisplayMode();
                self.navigation.controller.surface.viewer.diff_scroll = self.navigation.view().remapDiffScrollForModeChange(old_mode, new_mode, old_scroll);
                self.navigation.controller.resetDiffHorizontalScroll();
                self.navigation.updateSearchMatchOffset();
                self.navigation.controller.scrollSearchMatchIntoView();
                self.navigation.applyDiffCursorScrolloff();
                self.navigation.clampDiffNavigation();
            },
            .toggle_line_numbers => {
                self.navigation.controller.surface.viewer.view_options.toggleLineNumbers();
                self.navigation.clampDiffHorizontalScrollToVisibleRows();
            },
            .enter_search => self.navigation.enterSearchMode(),
            .cancel_search => self.navigation.controller.cancelSearchMode(),
            .clear_search => self.navigation.controller.clearSearch(),
            .submit_search => self.navigation.submitSearch(),
            .search_insert => |codepoint| self.navigation.controller.surface.search.input.insert(codepoint) catch {
                self.navigation.controller.setStatus("search query is too long", .{});
            },
            .search_paste => |text| self.navigation.controller.surface.search.input.insertSlice(text) catch {
                self.navigation.controller.setStatus("search query is too long", .{});
            },
            .search_backspace => self.navigation.controller.surface.search.input.backspace(),
            .search_move_left => self.navigation.controller.surface.search.input.moveLeft(),
            .search_move_right => self.navigation.controller.surface.search.input.moveRight(),
            .select_next_search_match => self.navigation.selectSearchMatch(.forward),
            .select_previous_search_match => self.navigation.selectSearchMatch(.backward),
            .enter_file_search => self.navigation.controller.enterFileSearchMode(allocator orelse return error.MissingAllocator),
            .cancel_file_search => self.navigation.controller.cancelFileSearchMode(allocator orelse return error.MissingAllocator),
            .submit_file_search => self.navigation.submitFileSearch(allocator orelse return error.MissingAllocator),
            .file_search_previous => self.navigation.controller.surface.file_search.move(-1),
            .file_search_next => self.navigation.controller.surface.file_search.move(1),
            // Prepare fixed-capacity edits by value so overflow and a missing
            // allocator cannot publish input ahead of its candidate projection.
            .file_search_insert => |codepoint| insert: {
                var prepared = self.navigation.controller.surface.file_search.input;
                prepared.insert(codepoint) catch {
                    self.navigation.controller.setStatus("file search query is too long", .{});
                    break :insert;
                };
                const owner = allocator orelse return error.MissingAllocator;
                self.navigation.controller.surface.file_search.input = prepared;
                self.navigation.controller.rebuildFileSearchProjection(owner);
            },
            .file_search_paste => |text| paste: {
                var prepared = self.navigation.controller.surface.file_search.input;
                prepared.insertSlice(text) catch {
                    self.navigation.controller.setStatus("file search query is too long", .{});
                    break :paste;
                };
                const owner = allocator orelse return error.MissingAllocator;
                self.navigation.controller.surface.file_search.input = prepared;
                self.navigation.controller.rebuildFileSearchProjection(owner);
            },
            .file_search_backspace => {
                var prepared = self.navigation.controller.surface.file_search.input;
                prepared.backspace();
                const owner = allocator orelse return error.MissingAllocator;
                self.navigation.controller.surface.file_search.input = prepared;
                self.navigation.controller.rebuildFileSearchProjection(owner);
            },
            .toggle_reviewed_file => try self.navigation.toggleReviewedFile(allocator orelse return error.MissingAllocator),
            .toggle_hide_reviewed_files => try self.navigation.toggleHideReviewedFiles(allocator orelse return error.MissingAllocator),
            .cycle_changed_file_filter => try self.navigation.cycleChangedFileFilter(allocator orelse return error.MissingAllocator),
        }

        if (tracks_sidebar_selection) {
            result.explicit_sidebar_selection_changed = !std.meta.eql(sidebar_before, sidebarSelectionSnapshot(self.navigation));
        }
        if (tracks_navigation) {
            result.display_navigation_changed = !std.meta.eql(before, self.navigation.view().view.displayNavigationSnapshot());
        }
        return result;
    }

    fn releaseDiffMouse(self: Controller, allocator: std.mem.Allocator) !?Effect {
        const owner = self.navigation.controller.surface.selection_owner.*;
        return switch (owner) {
            .none => null,
            .diff => |drag| blk: {
                if (!drag.moved) {
                    self.navigation.controller.clearDiffSelection();
                    break :blk null;
                }

                var candidate = self.buildCompletedSelection(allocator, drag) catch {
                    if (self.navigation.controller.surface.completed_selection.*) |*prior| prior.deinit(allocator);
                    self.navigation.controller.surface.completed_selection.* = null;
                    self.navigation.controller.clearDiffSelection();
                    break :blk null;
                };
                if (self.navigation.controller.surface.completed_selection.*) |*prior| prior.deinit(allocator);
                self.navigation.controller.surface.completed_selection.* = candidate;
                candidate = undefined;
                self.navigation.controller.clearDiffSelection();

                const clipboard = self.navigation.controller.surface.completed_selection.*.?.clipboardText(allocator) catch break :blk null;
                break :blk .{ .copy_diff_selection = clipboard };
            },
            .diff_header => |header| blk: {
                const effect: Effect = .{ .copy_diff_header_path = try cloneHeaderSelection(allocator, header) };
                self.navigation.controller.clearDiffSelection();
                break :blk effect;
            },
        };
    }

    fn buildCompletedSelection(self: Controller, allocator: std.mem.Allocator, drag: diff_selection.DragSelection) !selection.CompletedSelection {
        const token = self.navigation.view().currentContentToken() orelse return error.StaleSelection;
        return switch (drag.identity) {
            .loaded_file, .projection_file => blk: {
                const target = self.navigation.view().parsedSelectionTarget(drag.identity) orelse return error.StaleSelection;
                break :blk try selection.buildParsed(allocator, token, target.file, drag);
            },
            .generated_file => |generated| blk: {
                const body = self.navigation.view().generatedBody() orelse return error.StaleSelection;
                if (!std.mem.eql(u8, generated.path_key, body.path)) return error.StaleSelection;
                break :blk try selection.buildGenerated(allocator, token, body.path, body.source, drag);
            },
        };
    }
};

const SidebarSelectionSnapshot = struct {
    selected_target: ?context.SelectedTarget,
    selected_node: usize,
};

fn sidebarSelectionSnapshot(controller: navigation.BodyController) SidebarSelectionSnapshot {
    return .{
        .selected_target = controller.controller.surface.viewer.selected_target,
        .selected_node = controller.controller.surface.viewer.selected_node,
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

fn cloneHeaderSelection(allocator: std.mem.Allocator, header: diff_selection.HeaderPathSelection) !diff_selection.HeaderPathSelection {
    var cloned = header;
    cloned.identity.path_key = try allocator.dupe(u8, header.identity.path_key);
    return cloned;
}

test "update deinit releases untaken selection text effect" {
    var update: Update = .{ .effect = .{
        .copy_diff_selection = try std.testing.allocator.dupe(u8, "selected text"),
    } };
    update.deinit(std.testing.allocator);
    try std.testing.expect(update.effect == null);
}

test "update deinit releases untaken header path effect" {
    var update: Update = .{ .effect = .{ .copy_diff_header_path = .{
        .identity = .{
            .kind = .loaded_file,
            .path_key = try std.testing.allocator.dupe(u8, "src/app.zig"),
        },
        .moved = true,
    } } };
    update.deinit(std.testing.allocator);
    try std.testing.expect(update.effect == null);
}

test "takeEffect transfers the sole payload owner" {
    var update: Update = .{ .effect = .{
        .copy_diff_selection = try std.testing.allocator.dupe(u8, "transferred text"),
    } };
    var effect = update.takeEffect() orelse return error.ExpectedEffect;
    defer effect.deinit(std.testing.allocator);

    update.deinit(std.testing.allocator);
    switch (effect) {
        .copy_diff_selection => |text| try std.testing.expectEqualStrings("transferred text", text),
        .copy_diff_header_path => return error.ExpectedSelectionEffect,
    }
}
