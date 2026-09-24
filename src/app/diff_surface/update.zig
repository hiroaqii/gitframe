//! Page-independent semantic updates for a diff surface.
//!
const std = @import("std");
const diff_surface = @import("../diff_surface.zig");
const context = @import("../../context.zig");
const diff_selection = @import("../../diff/selection.zig");
const drag_auto_scroll = @import("../drag_auto_scroll.zig");
const content_view = @import("content.zig");
const navigation = @import("navigation.zig");
const message = @import("message.zig");
const selection = @import("selection.zig");
const selection_action = @import("../selection_action.zig");

pub const SelectionCopy = struct {
    text: []u8,
    generation: u64,
};

pub const Redraw = enum { default, skip };

/// Owned output which a page adapter translates into its physical effect.
pub const Effect = union(enum) {
    copy_diff_selection: SelectionCopy,
    copy_hunk_diff: []u8,
    copy_diff_header_path: diff_selection.HeaderPathSelection,

    pub fn deinit(self: *Effect, allocator: ?std.mem.Allocator) void {
        switch (self.*) {
            .copy_diff_selection => |copy| (allocator orelse unreachable).free(copy.text),
            .copy_hunk_diff => |text| (allocator orelse unreachable).free(text),
            .copy_diff_header_path => |*header| (allocator orelse unreachable).free(header.identity.path_key),
        }
        self.* = undefined;
    }
};

/// One handled shared transition and the value-only facts needed by page-local
/// epilogues. The effect remains owned here until a page adapter takes it.
pub const Update = struct {
    effect: ?Effect = null,
    retention_transition: RetentionTransition = .none,
    explicit_sidebar_selection_changed: bool = false,
    display_navigation_changed: bool = false,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,
    redraw: Redraw = .default,

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

pub const RetentionTransition = enum {
    none,
    installed,
    cleared,
};

pub const Hook = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque, cleanup: navigation.SelectionMappingCleanup) void,

    pub fn call(self: Hook, cleanup: navigation.SelectionMappingCleanup) void {
        self.callback(self.ctx, cleanup);
    }
};

pub const InstallHook = struct {
    ctx: *anyopaque,
    callback: *const fn (ctx: *anyopaque) bool,

    pub fn install(self: InstallHook) bool {
        return self.callback(self.ctx);
    }
};

pub const Controller = struct {
    navigation: navigation.BodyController,
    /// Changes retains a richer mixed-stage fold presentation policy. Review
    /// can use the shared body operation directly.
    toggle_hunk_fold: ?Hook = null,
    retained_selection_install: ?InstallHook = null,
    selection_mapping_residual: ?navigation.ResidualSelectionOwner = null,

    pub fn apply(self: Controller, allocator: ?std.mem.Allocator, msg: message.Msg) !Update {
        const retained_before = self.navigation.controller.surface.completed_selection.* != null;
        const cleanup: ?navigation.SelectionMappingCleanup = if (allocator) |owner|
            .{
                .allocator = owner,
                .residual_owner = self.selection_mapping_residual,
            }
        else
            null;
        var result = try self.applyWithMappingCleanup(allocator, cleanup, msg);
        if (retained_before and self.navigation.controller.surface.completed_selection.* == null) {
            result.retention_transition = .cleared;
        }
        return result;
    }

    fn applyWithMappingCleanup(
        self: Controller,
        allocator: ?std.mem.Allocator,
        mapping_cleanup: ?navigation.SelectionMappingCleanup,
        msg: message.Msg,
    ) !Update {
        const tracks_wheel_redraw = isMouseWheel(msg);
        const wheel_before = if (tracks_wheel_redraw) wheelSnapshot(self.navigation) else undefined;
        const tracks_navigation = tracksDisplayNavigation(msg);
        const before = if (tracks_navigation) self.navigation.view().view.displayNavigationSnapshot() else undefined;
        const tracks_sidebar_selection = tracksExplicitSidebarSelection(msg);
        const sidebar_before = if (tracks_sidebar_selection) sidebarSelectionSnapshot(self.navigation) else undefined;
        const viewport_anchor = self.navigation.captureSelectionViewportAnchor();
        const selected_target_before = self.navigation.controller.surface.viewer.selected_target;
        const requested_mode_before = self.navigation.controller.surface.viewer.display_mode;
        const source_rows_before = self.navigation.view().sourceDiffLineCount();
        const layout_revision_before = self.navigation.controller.surface.selection_layout_revision.*;

        var result: Update = .{};
        switch (msg) {
            .select_previous_file => self.navigation.selectFileDelta(mapping_cleanup orelse return error.MissingAllocator, -1),
            .select_next_file => self.navigation.selectFileDelta(mapping_cleanup orelse return error.MissingAllocator, 1),
            .toggle_directory => try self.navigation.toggleSelectedDirectory(),
            .expand_directory => try self.navigation.expandSelectedDirectory(),
            .collapse_or_parent_directory => try self.navigation.collapseOrSelectParentDirectory(),
            .scroll_diff_up => self.navigation.moveDiffCursorRows(.up),
            .scroll_diff_down => self.navigation.moveDiffCursorRows(.down),
            .scroll_diff_left => self.navigation.scrollDiffHorizontal(.left),
            .scroll_diff_right => self.navigation.scrollDiffHorizontal(.right),
            .scroll_sidebar_left => self.navigation.controller.scrollSidebarHorizontal(.left),
            .scroll_sidebar_right => self.navigation.controller.scrollSidebarHorizontal(.right),
            .document_first => self.navigation.moveDiffCursorFirst(),
            .document_last => self.navigation.moveDiffCursorLast(),
            .half_page_up => self.navigation.moveDiffCursorHalfPage(.up),
            .half_page_down => self.navigation.moveDiffCursorHalfPage(.down),
            .page_diff_up => self.navigation.moveDiffCursorPage(.up),
            .page_diff_down => self.navigation.moveDiffCursorPage(.down),
            .select_previous_hunk => self.navigation.selectHunkDelta(-1),
            .select_next_hunk => self.navigation.selectHunkDelta(1),
            .toggle_hunk_fold => if (self.navigation.view().bodyAllowsHunkFold())
                self.navigation.toggleSelectedHunkFold(mapping_cleanup orelse return error.MissingAllocator)
            else if (self.toggle_hunk_fold) |hook|
                hook.call(mapping_cleanup orelse return error.MissingAllocator),
            .select_first_file => self.navigation.selectFileAbsolute(mapping_cleanup orelse return error.MissingAllocator, 0),
            .select_last_file => self.navigation.selectLastFile(mapping_cleanup orelse return error.MissingAllocator),
            .toggle_focus => {
                if (!self.navigation.controller.surface.viewer.sidebar_hidden) {
                    self.navigation.controller.surface.viewer.focus = self.navigation.controller.surface.viewer.focus.toggled();
                    if (self.navigation.controller.surface.viewer.focus != .diff) {
                        self.navigation.controller.clearKeyboardSideChoice();
                    }
                }
            },
            .toggle_sidebar_visibility => self.navigation.toggleSidebarVisibility(mapping_cleanup orelse return error.MissingAllocator),
            .decrease_sidebar_width => self.navigation.adjustSidebarWidth(mapping_cleanup orelse return error.MissingAllocator, .shrink),
            .increase_sidebar_width => self.navigation.adjustSidebarWidth(mapping_cleanup orelse return error.MissingAllocator, .grow),
            .focus_sidebar => _ = self.navigation.controller.focusSidebar(),
            .focus_diff => self.navigation.controller.surface.viewer.focus = .diff,
            .sidebar_click_node => |node_index| try self.navigation.clickSidebarNode(
                mapping_cleanup orelse return error.MissingAllocator,
                node_index,
            ),
            .mouse_sidebar_wheel_up => {
                _ = self.navigation.controller.focusSidebar();
                self.navigation.selectFileDelta(mapping_cleanup orelse return error.MissingAllocator, -1);
            },
            .mouse_sidebar_wheel_down => {
                _ = self.navigation.controller.focusSidebar();
                self.navigation.selectFileDelta(mapping_cleanup orelse return error.MissingAllocator, 1);
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
            .mouse_diff_press => |point| {
                if (self.navigation.view().selectionActionHit(point)) |hit| {
                    self.navigation.controller.surface.viewer.focus = .diff;
                    if (hit.target) |target| self.applyStatusSelectionAction(
                        allocator orelse return error.MissingAllocator,
                        target,
                        &result,
                    );
                } else {
                    self.navigation.pressDiffMouse(point);
                }
            },
            .mouse_diff_drag => |point| self.navigation.dragDiffMouse(point),
            .mouse_diff_auto_scroll_step => |step| result.auto_scroll = self.navigation.autoScrollDiffMouse(step),
            .mouse_diff_release => {
                const release = try self.releaseDiffMouse(allocator orelse return error.MissingAllocator);
                result.effect = release.effect;
                result.retention_transition = release.retention_transition;
            },
            .selection_action => |action| self.applyCompletedSelectionAction(
                allocator orelse return error.MissingAllocator,
                action,
                &result,
            ),
            .selection_owned_noop => {},
            .choose_keyboard_selection_side => |side| if (!self.navigation.chooseKeyboardSelectionSide(side)) {
                self.navigation.controller.setStatus("No selectable code line for keyboard selection", .{});
            },
            .switch_keyboard_selection_side => |side| {
                const active = self.navigation.controller.surface.selection_owner.activeDiff();
                if (!self.navigation.switchKeyboardSelectionSide(side) and
                    active != null and active.?.origin == .keyboard_line and
                    active.?.selected_line_count == 1 and active.?.selectedSide() != side)
                {
                    self.navigation.controller.setStatus("No matching line on that selection side", .{});
                }
            },
            .begin_keyboard_line_selection => switch (self.navigation.beginKeyboardLineSelection()) {
                .started, .choosing_side => {},
                .unavailable => self.navigation.controller.setStatus("No selectable code line for keyboard selection", .{}),
            },
            .keyboard_line_selection_move => |direction| _ = self.navigation.moveKeyboardLineSelection(direction),
            .selection_action_unavailable => self.navigation.controller.setStatus("Ask is not available for this selection", .{}),
            .toggle_display_mode => {
                const cleanup = mapping_cleanup orelse return error.MissingAllocator;
                const prepared = cleanup.prepare(self.navigation);
                const old_mode = self.navigation.controller.view().effectiveDisplayMode();
                const old_scroll = self.navigation.view().renderDiffScroll();
                self.navigation.controller.surface.viewer.display_mode = self.navigation.controller.surface.viewer.display_mode.toggled();
                const new_mode = self.navigation.controller.view().effectiveDisplayMode();
                self.navigation.controller.surface.viewer.diff_scroll = self.navigation.view().remapDiffScrollForModeChange(old_mode, new_mode, old_scroll);
                cleanup.complete(self.navigation, prepared);
                self.navigation.controller.resetDiffHorizontalScroll();
                self.navigation.updateSearchMatchOffset();
                self.navigation.scrollSearchMatchIntoView();
                self.navigation.keepDiffCursorVisible();
            },
            .toggle_line_numbers => {
                self.navigation.controller.surface.viewer.view_options.toggleLineNumbers();
                self.navigation.clampDiffHorizontalScrollToVisibleRows();
            },
            .enter_search => {
                if (self.navigation.controller.surface.selection_owner.* != .none) {
                    self.navigation.controller.clearDiffSelection();
                }
                self.navigation.enterSearchMode();
            },
            .cancel_search => self.navigation.controller.cancelSearchMode(),
            .clear_search => self.navigation.controller.clearSearch(),
            .submit_search => self.navigation.submitSearch(mapping_cleanup orelse return error.MissingAllocator),
            .search_insert => |codepoint| self.navigation.controller.surface.search.input.insert(codepoint) catch {
                self.navigation.controller.setStatus("search query is too long", .{});
            },
            .search_paste => |text| self.navigation.controller.surface.search.input.insertSlice(text) catch {
                self.navigation.controller.setStatus("search query is too long", .{});
            },
            .search_backspace => self.navigation.controller.surface.search.input.backspace(),
            .search_move_left => self.navigation.controller.surface.search.input.moveLeft(),
            .search_move_right => self.navigation.controller.surface.search.input.moveRight(),
            .select_next_search_match => self.navigation.selectSearchMatch(mapping_cleanup orelse return error.MissingAllocator, .forward),
            .select_previous_search_match => self.navigation.selectSearchMatch(mapping_cleanup orelse return error.MissingAllocator, .backward),
            .enter_file_search => self.navigation.controller.enterFileSearchMode(allocator orelse return error.MissingAllocator),
            .cancel_file_search => self.navigation.controller.cancelFileSearchMode(allocator orelse return error.MissingAllocator),
            .submit_file_search => self.navigation.submitFileSearch(
                mapping_cleanup orelse return error.MissingAllocator,
                allocator orelse return error.MissingAllocator,
            ),
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
            .toggle_reviewed_file => try self.navigation.toggleReviewedFile(
                mapping_cleanup orelse return error.MissingAllocator,
                allocator orelse return error.MissingAllocator,
            ),
            .toggle_hide_reviewed_files => try self.navigation.toggleHideReviewedFiles(
                mapping_cleanup orelse return error.MissingAllocator,
                allocator orelse return error.MissingAllocator,
            ),
            .cycle_changed_file_filter => try self.navigation.cycleChangedFileFilter(
                mapping_cleanup orelse return error.MissingAllocator,
                allocator orelse return error.MissingAllocator,
            ),
        }

        if (!std.meta.eql(selected_target_before, self.navigation.controller.surface.viewer.selected_target) or
            requested_mode_before != self.navigation.controller.surface.viewer.display_mode or
            source_rows_before != self.navigation.view().sourceDiffLineCount())
        {
            if (self.navigation.controller.surface.selection_layout_revision.* == layout_revision_before) {
                advanceLayoutRevision(self.navigation.controller.surface.selection_layout_revision);
                if (viewport_anchor) |anchor| self.navigation.restoreSelectionViewportAnchor(anchor);
            }
        }

        if (tracks_sidebar_selection) {
            result.explicit_sidebar_selection_changed = !std.meta.eql(sidebar_before, sidebarSelectionSnapshot(self.navigation));
        }
        if (tracks_navigation) {
            result.display_navigation_changed = !std.meta.eql(before, self.navigation.view().view.displayNavigationSnapshot());
        }
        if (tracks_wheel_redraw and std.meta.eql(wheel_before, wheelSnapshot(self.navigation))) {
            result.redraw = .skip;
        }
        return result;
    }

    const Release = struct {
        effect: ?Effect = null,
        retention_transition: RetentionTransition = .none,
    };

    fn releaseDiffMouse(self: Controller, allocator: std.mem.Allocator) !Release {
        const owner = self.navigation.controller.surface.selection_owner.*;
        return switch (owner) {
            .none => .{},
            .keyboard_side_choice => .{},
            .diff => |drag| blk: {
                if (drag.origin != .mouse) break :blk .{};
                if (!drag.moved) {
                    self.navigation.controller.clearDiffSelection();
                    break :blk .{};
                }

                if (self.navigation.controller.surface.selection_completion_policy == .retain_with_actions and
                    !self.navigation.controller.surface.retained_selection_install_available)
                {
                    self.navigation.controller.clearDiffSelection();
                    self.navigation.controller.setStatus("Could not retain selected text", .{});
                    break :blk .{};
                }

                var candidate = self.buildCompletedSelection(allocator, drag) catch {
                    if (self.navigation.controller.surface.selection_completion_policy == .copy_on_release) {
                        if (self.navigation.controller.surface.completed_selection.*) |*prior| prior.deinit(allocator);
                        self.navigation.controller.surface.completed_selection.* = null;
                        self.navigation.controller.clearDiffSelection();
                        break :blk .{};
                    }
                    self.navigation.controller.clearDiffSelection();
                    self.navigation.controller.setStatus("Could not retain selected text", .{});
                    break :blk .{};
                };
                if (self.navigation.controller.surface.selection_completion_policy == .retain_with_actions and
                    !self.commitRetainedSelectionInstall())
                {
                    candidate.deinit(allocator);
                    self.navigation.controller.clearDiffSelection();
                    self.navigation.controller.setStatus("Could not retain selected text", .{});
                    break :blk .{};
                }
                if (self.navigation.controller.surface.completed_selection.*) |*prior| prior.deinit(allocator);
                self.navigation.controller.surface.completed_selection.* = candidate;
                const generation = selection_action.advanceGeneration(
                    self.navigation.controller.surface.selection_generation,
                );
                candidate = undefined;
                self.navigation.controller.clearDiffSelection();

                if (self.navigation.controller.surface.selection_completion_policy == .retain_with_actions) {
                    break :blk .{ .retention_transition = .installed };
                }
                const clipboard = self.navigation.controller.surface.completed_selection.*.?.clipboardText(allocator) catch break :blk .{};
                break :blk .{ .effect = .{ .copy_diff_selection = .{
                    .text = clipboard,
                    .generation = generation,
                } } };
            },
            .diff_header => |header| blk: {
                const effect: Effect = .{ .copy_diff_header_path = try cloneHeaderSelection(allocator, header) };
                self.navigation.controller.clearDiffSelection();
                break :blk .{ .effect = effect };
            },
        };
    }

    fn applyCompletedSelectionAction(
        self: Controller,
        allocator: std.mem.Allocator,
        action: selection_action.Action,
        result: *Update,
    ) void {
        // Source context is enabled by page owners, never by widget reuse.
        if (action == .copy_context) return;
        if (action == .copy and self.completeKeyboardSelection(allocator, result)) return;

        const Adapter = struct {
            controller: Controller,

            pub fn available(adapter: *@This()) bool {
                return adapter.controller.navigation.controller.surface.selection_owner.* != .none or
                    adapter.controller.navigation.controller.surface.completed_selection.* != null;
            }

            pub fn copy(adapter: *@This(), owner: std.mem.Allocator) selection_action.CopyError![]u8 {
                if (!adapter.controller.navigation.view().retainedSelectionActionAvailable()) {
                    return error.AuthorityInvalid;
                }
                const completed = adapter.controller.navigation.controller.surface.completed_selection.* orelse
                    return error.AuthorityInvalid;
                return completed.clipboardText(owner) catch return error.OutOfMemory;
            }

            pub fn clear(adapter: *@This(), owner: std.mem.Allocator) void {
                adapter.controller.navigation.controller.clearCompletedSelectionWithViewport(
                    adapter.controller.navigation.resolver,
                    owner,
                );
            }
        };
        var adapter: Adapter = .{ .controller = self };
        switch (selection_action.dispatch(allocator, action, &adapter)) {
            .none => {},
            .copy => |text| result.effect = .{ .copy_diff_selection = .{
                .text = text,
                .generation = self.navigation.controller.surface.selection_generation.*,
            } },
            .cleared => result.retention_transition = .cleared,
            .authority_invalid => {
                result.retention_transition = .cleared;
                self.navigation.controller.setStatus("Retained selection is no longer available", .{});
            },
            .preparation_failed => self.navigation.controller.setStatus("Could not prepare selected text for copying", .{}),
        }
    }

    fn applyStatusSelectionAction(
        self: Controller,
        allocator: std.mem.Allocator,
        action: selection_action.StatusAction,
        result: *Update,
    ) void {
        if (action.retained()) |retained| {
            self.applyCompletedSelectionAction(allocator, retained, result);
            return;
        }
        switch (action) {
            .copy, .copy_context, .clear => unreachable,
            .copy_hunk => {},
        }

        const presentation = self.navigation.view().selectionPresentation() orelse return;
        if (presentation.view.content != .unified_diff) return;
        var content = (content_view.View{ .navigation = self.navigation.view() }).selectedHunkCopyText(allocator) catch {
            self.navigation.controller.setStatus("Could not prepare hunk diff for copying", .{});
            return;
        };
        defer content.deinit(allocator);
        switch (content) {
            .ready => |text| {
                content = .no_hunk;
                result.effect = .{ .copy_hunk_diff = text };
            },
            .no_hunk => self.navigation.controller.setStatus("no hunk selected", .{}),
            .no_new_side => unreachable,
        }
    }

    fn completeKeyboardSelection(self: Controller, allocator: std.mem.Allocator, result: *Update) bool {
        const drag = self.navigation.controller.surface.selection_owner.activeDiff() orelse return false;
        if (drag.origin != .keyboard_line) return false;
        if (self.navigation.controller.surface.selection_completion_policy == .retain_with_actions and
            !self.navigation.controller.surface.retained_selection_install_available)
        {
            self.navigation.controller.setStatus("Could not retain selected text; press y to retry", .{});
            return true;
        }

        var candidate = self.buildCompletedSelection(allocator, drag) catch {
            self.navigation.controller.setStatus("Could not retain selected text; press y to retry", .{});
            return true;
        };
        if (candidate.lineCount() != drag.selected_line_count) {
            candidate.deinit(allocator);
            self.navigation.controller.setStatus("Could not validate selected text; press y to retry", .{});
            return true;
        }
        if (self.navigation.controller.surface.selection_completion_policy == .retain_with_actions and
            !self.commitRetainedSelectionInstall())
        {
            candidate.deinit(allocator);
            self.navigation.controller.setStatus("Could not retain selected text; press y to retry", .{});
            return true;
        }

        if (self.navigation.controller.surface.completed_selection.*) |*prior| prior.deinit(allocator);
        self.navigation.controller.surface.completed_selection.* = candidate;
        const generation = selection_action.advanceGeneration(
            self.navigation.controller.surface.selection_generation,
        );
        candidate = undefined;
        self.navigation.controller.clearDiffSelection();
        if (self.navigation.controller.surface.selection_completion_policy == .retain_with_actions) {
            result.retention_transition = .installed;
        }

        const clipboard = self.navigation.controller.surface.completed_selection.*.?.clipboardText(allocator) catch {
            self.navigation.controller.setStatus("Could not prepare selected text for copying; press y to retry", .{});
            return true;
        };
        result.effect = .{ .copy_diff_selection = .{
            .text = clipboard,
            .generation = generation,
        } };
        return true;
    }

    fn commitRetainedSelectionInstall(self: Controller) bool {
        if (!self.navigation.controller.surface.retained_selection_install_available) return false;
        const install = self.retained_selection_install orelse return true;
        return install.install();
    }

    fn buildCompletedSelection(self: Controller, allocator: std.mem.Allocator, drag: diff_selection.DragSelection) !selection.CompletedSelection {
        const token = self.navigation.view().currentContentToken() orelse return error.StaleSelection;
        return switch (drag.identity) {
            .loaded_file, .projection_file => blk: {
                const target = self.navigation.view().parsedSelectionTarget(drag.identity) orelse return error.StaleSelection;
                break :blk try selection.buildParsedFolded(
                    allocator,
                    token,
                    target.file,
                    target.folded_hunks,
                    self.navigation.controller.surface.selection_layout_revision.*,
                    drag,
                );
            },
            .generated_file => |generated| blk: {
                const body = self.navigation.view().generatedBody() orelse return error.StaleSelection;
                if (!std.mem.eql(u8, generated.path_key, body.path)) return error.StaleSelection;
                break :blk try selection.buildGeneratedForLayout(
                    allocator,
                    token,
                    body.path,
                    body.source,
                    self.navigation.controller.surface.selection_layout_revision.*,
                    drag,
                );
            },
        };
    }
};

const WheelSnapshot = struct {
    navigation: diff_surface.DisplayNavigationSnapshot,
    focus: diff_surface.Focus,
    selection_owner: diff_selection.Owner,
};

fn wheelSnapshot(controller: navigation.BodyController) WheelSnapshot {
    return .{
        .navigation = controller.view().view.displayNavigationSnapshot(),
        .focus = controller.controller.surface.viewer.focus,
        .selection_owner = controller.controller.surface.selection_owner.*,
    };
}

fn isMouseWheel(msg: message.Msg) bool {
    return switch (msg) {
        .mouse_sidebar_wheel_up,
        .mouse_sidebar_wheel_down,
        .mouse_diff_wheel_up,
        .mouse_diff_wheel_down,
        .mouse_diff_wheel_left,
        .mouse_diff_wheel_right,
        => true,
        else => false,
    };
}

fn advanceLayoutRevision(revision: *u64) void {
    revision.* +%= 1;
    if (revision.* == 0) revision.* = 1;
}

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
        .document_first,
        .document_last,
        .half_page_up,
        .half_page_down,
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
        .mouse_diff_auto_scroll_step,
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
        .copy_diff_selection = .{
            .text = try std.testing.allocator.dupe(u8, "selected text"),
            .generation = 7,
        },
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
        .copy_diff_selection = .{
            .text = try std.testing.allocator.dupe(u8, "transferred text"),
            .generation = 8,
        },
    } };
    var effect = update.takeEffect() orelse return error.ExpectedEffect;
    defer effect.deinit(std.testing.allocator);

    update.deinit(std.testing.allocator);
    switch (effect) {
        .copy_diff_selection => |copy| {
            try std.testing.expectEqualStrings("transferred text", copy.text);
            try std.testing.expectEqual(@as(u64, 8), copy.generation);
        },
        .copy_hunk_diff => return error.ExpectedSelectionEffect,
        .copy_diff_header_path => return error.ExpectedSelectionEffect,
    }
}
