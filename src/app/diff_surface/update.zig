//! Page-independent semantic updates for a diff surface.
//!
//! Until S2c3 introduces the shared message vocabulary, `apply` accepts the
//! page message structurally and returns `null` for page-only extensions.

const std = @import("std");
const navigation = @import("navigation.zig");

/// Distinguishes one handled shared transition from a page-only message. S2b4b2
/// adds owned effects and value-only epilogue classification to this type.
pub const Update = struct {};

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

    /// Returns null only when `msg` is a page extension or the selection-release
    /// effect retained by the page adapter until S2b4b2.
    pub fn apply(self: Controller, allocator: ?std.mem.Allocator, msg: anytype) !?Update {
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
            else => return null,
        }
        return .{};
    }
};
