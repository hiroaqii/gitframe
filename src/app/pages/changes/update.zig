//! Changes-local semantic update ownership.
//!
//! Shell input, mouse hit-testing, and future Session API producers all route the
//! same `message.Msg` through this controller. State-only transitions terminate
//! here. Operations requiring overlays, processes, clipboard, Git tasks, or app
//! teardown return an explicit command to the App shell.

const std = @import("std");
const builtin = @import("builtin");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const diff_surface_update = @import("../../diff_surface/update.zig");
const diff_surface_navigation = @import("../../diff_surface/navigation.zig");
const selection_action = @import("../../selection_action.zig");
const message = @import("message.zig");
const navigation = @import("navigation.zig");
const context = @import("../../../context.zig");
const changes_page = @import("../changes.zig");
const diff_parser = if (builtin.is_test) @import("../../../diff/parser.zig") else struct {};
const diff_selection = @import("../../../diff/selection.zig");
const diff_render = @import("../../../diff/render.zig");
const file_tree = if (builtin.is_test) @import("../../../file_tree.zig") else struct {};
const loaded_diff = if (builtin.is_test) @import("../../../loaded_diff.zig") else struct {};
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
    open_selected_file_in_editor,
    copy_current_line,
    copy_current_hunk,
    copy_hunk_diff: []u8,
    /// Separately owned clipboard bytes assembled from the installed page
    /// candidate. They never borrow the displayed diff/source owner.
    copy_diff_selection: diff_surface_update.SelectionCopy,
    /// Owns the cloned identity path until App consumes/deinitializes it.
    copy_diff_header_path: diff_selection.HeaderPathSelection,

    pub fn deinit(self: *Command, allocator: ?std.mem.Allocator) void {
        switch (self.*) {
            .copy_diff_selection => |copy| (allocator orelse unreachable).free(copy.text),
            .copy_hunk_diff => |text| (allocator orelse unreachable).free(text),
            .copy_diff_header_path => |*selection| (allocator orelse unreachable).free(selection.identity.path_key),
            else => {},
        }
        self.* = undefined;
    }
};

pub const ChangesUpdate = struct {
    command: ?Command = null,
    capture_display_override: bool = false,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,
    redraw: diff_surface_update.Redraw = .default,

    pub fn deinit(self: *ChangesUpdate, allocator: ?std.mem.Allocator) void {
        if (self.command) |*command| command.deinit(allocator);
        self.* = .{};
    }

    pub fn takeCommand(self: *ChangesUpdate) ?Command {
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
    pub fn apply(self: Controller, allocator: ?std.mem.Allocator, msg: message.Msg) !ChangesUpdate {
        var result: ChangesUpdate = .{};
        var adapter = self.navigation.updateAdapter();
        if (msg.shared()) |shared_msg| {
            var shared_update = try adapter.shared().apply(allocator, shared_msg);
            defer shared_update.deinit(allocator);
            switch (shared_update.retention_transition) {
                .none, .installed, .cleared => {},
            }
            if (shared_update.takeEffect()) |effect| result.command = commandFromEffect(effect);
            result.auto_scroll = shared_update.auto_scroll;
            result.redraw = shared_update.redraw;

            // This boundary sees semantic Changes input after it has either
            // changed the sidebar/file intent or proved to be a no-op. Internal
            // tree rebuild/remap helpers cannot revoke restoration authority.
            if (shared_update.explicit_sidebar_selection_changed) {
                _ = self.navigation.page.action_cursor.supersedeRestore();
            }
            if (shared_update.display_navigation_changed) {
                self.navigation.page.display_navigation_input_revision +%= 1;
                result.capture_display_override = self.navigation.page.pending_display_navigation_restore != null;
            }
        } else {
            switch (msg) {
                .enter_commit_panel => result.command = .enter_commit_panel,
                .enter_amend_panel => result.command = .enter_amend_panel,
                .toggle_selected_file => result.command = .toggle_selected_file,
                .toggle_selected_hunk => result.command = .toggle_selected_hunk,
                .request_discard_selected_file => result.command = .request_discard_selected_file,
                .request_push => result.command = .request_push,
                .request_pull => result.command = .request_pull,
                .request_fetch => result.command = .request_fetch,
                .open_selected_file_in_editor => result.command = .open_selected_file_in_editor,
                .copy_current_line => result.command = .copy_current_line,
                .copy_current_hunk => result.command = .copy_current_hunk,
                else => unreachable,
            }
        }
        return result;
    }
};

fn commandFromEffect(effect: diff_surface_update.Effect) Command {
    return switch (effect) {
        .copy_diff_selection => |copy| .{ .copy_diff_selection = copy },
        .copy_hunk_diff => |text| .{ .copy_hunk_diff = text },
        .copy_diff_header_path => |header| .{ .copy_diff_header_path = header },
    };
}

test "changes update owns state transition and shell intent" {
    var page: @import("../changes.zig").ChangesPageState = .{};
    var controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var state_update = try controller.apply(std.testing.allocator, .toggle_focus);
    defer state_update.deinit(std.testing.allocator);
    try std.testing.expectEqual(@import("../changes.zig").Focus.diff, page.viewer.focus);
    try std.testing.expect(state_update.command == null);

    var shell_update = try controller.apply(std.testing.allocator, .request_push);
    defer shell_update.deinit(std.testing.allocator);
    try std.testing.expectEqual(Command.request_push, shell_update.command.?);
}

test "Changes advances selection layout revision only for mapping mode and fold changes" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = test_support.loadedDiffTwo();
    loaded.collapsed_hunks = try arena.allocator().alloc(bool, loaded.document.totalHunks());
    @memset(loaded.collapsed_hunks, false);
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadStateWithArena(arena, loaded),
        .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = "/repo",
        .source = .unstaged,
        .layout = .{ .width = 120, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    const initial = page.selection_layout_revision;
    var focus = try controller.apply(null, .toggle_focus);
    focus.deinit(null);
    try std.testing.expectEqual(initial, page.selection_layout_revision);

    var mode = try controller.apply(allocator, .toggle_display_mode);
    mode.deinit(null);
    try std.testing.expectEqual(initial + 1, page.selection_layout_revision);

    var file = try controller.apply(allocator, .select_next_file);
    file.deinit(null);
    try std.testing.expectEqual(initial + 2, page.selection_layout_revision);

    page.viewer.selected_target = .{ .diff_file = 0 };
    page.viewer.diff_cursor = .{ .hunk_header = 0 };
    var fold = try controller.apply(allocator, .toggle_hunk_fold);
    fold.deinit(null);
    try std.testing.expectEqual(initial + 3, page.selection_layout_revision);
}

fn installUpdateTestActionCursor(
    page: *changes_page.ChangesPageState,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var prepared = try changes_page.action_cursor.Prepared.init(
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
    var page: changes_page.ChangesPageState = .{
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

    controller.navigation.selectSidebarNode(allocator, controller.navigation.activeLoadedDiff().?, 1);
    controller.navigation.selectSidebarNode(allocator, controller.navigation.activeLoadedDiff().?, 0);
    try std.testing.expect(page.action_cursor.hasRestoreAuthority());

    var explicit = try controller.apply(allocator, .select_next_file);
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
    var page: changes_page.ChangesPageState = .{
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
    var wheel = try controller.apply(allocator, .mouse_sidebar_wheel_up);
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
    var page: changes_page.ChangesPageState = .{
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

test "changes file search publishes candidates from enter and input edits" {
    const allocator = std.testing.allocator;
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    var page: @import("../changes.zig").ChangesPageState = .{
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

test "changes file search candidate failure retains edited input as unavailable" {
    const allocator = std.testing.allocator;
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    var page: @import("../changes.zig").ChangesPageState = .{
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

test "changes file search missing allocator preserves the published query generation" {
    const allocator = std.testing.allocator;
    var loaded = test_support.loadedDiffTwo();
    loaded.tree.nodes = &file_search_input_nodes;
    var page: @import("../changes.zig").ChangesPageState = .{
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

test "changes mouse release retains candidate until explicit copy or clear" {
    var page: @import("../changes.zig").ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
    };
    defer page.deinit(std.testing.allocator);
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
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
    try std.testing.expect(update.command == null);
    try std.testing.expect(page.completed_selection != null);

    var copied = try controller.apply(std.testing.allocator, .{ .selection_action = .copy });
    defer copied.deinit(std.testing.allocator);
    var command = copied.takeCommand() orelse return error.ExpectedCopyCommand;
    defer command.deinit(std.testing.allocator);
    const copy_generation = switch (command) {
        .copy_diff_selection => |copy| blk: {
            try std.testing.expectEqualStrings(" one\n two\n-old\n+new\n", copy.text);
            break :blk copy.generation;
        },
        else => return error.ExpectedCopyCommand,
    };
    try std.testing.expect(page.completed_selection != null);

    const navigation_token = page.completed_selection.?.token;
    for ([_]message.Msg{ .focus_diff, .scroll_diff_down }) |navigation_msg| {
        var navigation_update = try controller.apply(null, navigation_msg);
        navigation_update.deinit(null);
        try std.testing.expect(page.completed_selection != null);
        try std.testing.expect(page.completed_selection.?.token.eql(navigation_token));
        try std.testing.expect(controller.navigation.view().retainedSelectionActionAvailable());
    }

    const retained_token = page.completed_selection.?.token;
    page.viewer.diff_scroll = .{ .logical = 0 };
    page.viewer.diff_cursor = .{ .hunk_header = 0 };
    const raw = controller.navigation.view().rawDiffPaneGeometry().?;
    const content_gutter = raw.width - diff_surface_navigation.contentWidth(raw.width);
    const click_point = diff_surface.MousePoint{
        .col = raw.col + content_gutter + diff_render.cursor_gutter_width + 2,
        .row = diff_render.body_start_row + 2,
    };
    var press = try controller.apply(null, .{ .mouse_diff_press = click_point });
    press.deinit(null);
    try std.testing.expect(page.selection_owner.activeDiff() != null);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.completed_selection.?.token.eql(retained_token));
    switch (page.viewer.diff_cursor) {
        .hunk_line => |line| {
            try std.testing.expectEqual(@as(usize, 0), line.hunk_index);
            try std.testing.expectEqual(@as(usize, 1), line.line_index);
        },
        else => return error.ExpectedHunkLineCursor,
    }
    var click = try controller.apply(std.testing.allocator, .{ .mouse_diff_release = null });
    defer click.deinit(std.testing.allocator);
    try std.testing.expect(click.command == null);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.completed_selection.?.token.eql(retained_token));

    try std.testing.expect(!controller.navigation.clearCompletedSelectionAfterCopy(
        std.testing.allocator,
        copy_generation + 1,
    ));
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(controller.navigation.clearCompletedSelectionAfterCopy(
        std.testing.allocator,
        copy_generation,
    ));
    try std.testing.expect(page.completed_selection == null);
}

test "Changes keyboard line selection locks side moves allocation-free and completes once" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .focus = .diff,
            .sidebar_hidden = true,
            .display_mode = .side_by_side,
        },
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 120, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var begin = try controller.apply(failing.allocator(), .begin_keyboard_line_selection);
    begin.deinit(failing.allocator());
    try std.testing.expect(page.selection_owner.activeKeyboardSideChoice() != null);
    var choose_before = try controller.apply(null, .{ .choose_keyboard_selection_side = .old });
    choose_before.deinit(null);
    const started = page.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Origin.keyboard_line, started.origin);
    try std.testing.expectEqual(diff_selection.Side.old, started.selectedSide().?);
    try std.testing.expectEqual(@as(usize, 1), started.selected_line_count);
    try std.testing.expectEqual(@as(usize, 1), controller.navigation.view().selectionStatusPresentation().?.line_count);

    var search = try controller.apply(null, .enter_search);
    search.deinit(null);
    try std.testing.expect(page.search.mode);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection == null);
    var cancel_search = try controller.apply(null, .cancel_search);
    cancel_search.deinit(null);
    try std.testing.expect(!page.search.mode);
    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var restart_after_search = try controller.apply(failing.allocator(), .begin_keyboard_line_selection);
    restart_after_search.deinit(failing.allocator());
    var choose_after_search = try controller.apply(null, .{ .choose_keyboard_selection_side = .old });
    choose_after_search.deinit(null);
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());

    for (0..2) |_| {
        var moved = try controller.apply(failing.allocator(), .{ .keyboard_line_selection_move = .up });
        moved.deinit(failing.allocator());
    }
    const extended = page.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(diff_selection.Side.old, extended.selectedSide().?);
    try std.testing.expectEqual(@as(usize, 3), extended.selected_line_count);
    try std.testing.expectEqual(@as(usize, 3), controller.navigation.view().selectionStatusPresentation().?.line_count);

    var ask = try controller.apply(null, .selection_action_unavailable);
    ask.deinit(null);
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());
    try std.testing.expectEqualStrings("Ask is not available for this selection", page.status.text());

    var pointer_release = try controller.apply(allocator, .{ .mouse_diff_release = null });
    pointer_release.deinit(allocator);
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());

    var copied = try controller.apply(allocator, .{ .selection_action = .copy });
    defer copied.deinit(allocator);
    var command = copied.takeCommand() orelse return error.ExpectedCopyCommand;
    defer command.deinit(allocator);
    switch (command) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings("one\ntwo\nold\n", copy.text),
        else => return error.ExpectedCopyCommand,
    }
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expectEqual(@as(usize, 3), page.completed_selection.?.lineCount());

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } };
    var cross_hunks = try controller.apply(null, .begin_keyboard_line_selection);
    cross_hunks.deinit(null);
    for (0..5) |_| {
        var moved = try controller.apply(null, .{ .keyboard_line_selection_move = .down });
        moved.deinit(null);
    }
    try std.testing.expectEqual(@as(usize, 6), page.selection_owner.activeDiff().?.selected_line_count);
    var copied_hunks = try controller.apply(allocator, .{ .selection_action = .copy });
    defer copied_hunks.deinit(allocator);
    var hunks_command = copied_hunks.takeCommand() orelse return error.ExpectedCopyCommand;
    defer hunks_command.deinit(allocator);
    switch (hunks_command) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings(
            "one\ntwo\nnew\nfour\nlate one\nlate new\n",
            copy.text,
        ),
        else => return error.ExpectedCopyCommand,
    }

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 4 } };
    var crossing = try controller.apply(null, .begin_keyboard_line_selection);
    crossing.deinit(null);
    var crossing_down = try controller.apply(null, .{ .keyboard_line_selection_move = .down });
    crossing_down.deinit(null);
    try std.testing.expectEqual(@as(usize, 2), page.selection_owner.activeDiff().?.selected_line_count);
    for (0..2) |_| {
        var crossing_up = try controller.apply(null, .{ .keyboard_line_selection_move = .up });
        crossing_up.deinit(null);
    }
    const crossed = page.selection_owner.activeDiff().?;
    try std.testing.expect(crossed.focus.order(crossed.anchor) == .lt);
    try std.testing.expectEqual(@as(usize, 2), crossed.selected_line_count);
    var clear_crossing = try controller.apply(allocator, .{ .selection_action = .clear });
    clear_crossing.deinit(allocator);
    try std.testing.expect(page.completed_selection == null);

    var restart = try controller.apply(null, .begin_keyboard_line_selection);
    restart.deinit(null);
    if (page.selection_owner.activeKeyboardSideChoice() != null) {
        var restart_choose = try controller.apply(null, .{ .choose_keyboard_selection_side = .new });
        restart_choose.deinit(null);
    }
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());
    var retain_restart = try controller.apply(allocator, .{ .selection_action = .copy });
    defer retain_restart.deinit(allocator);
    var restart_command = retain_restart.takeCommand() orelse return error.ExpectedCopyCommand;
    defer restart_command.deinit(allocator);
    var active_before_mode = try controller.apply(null, .begin_keyboard_line_selection);
    active_before_mode.deinit(null);
    try std.testing.expect(page.selection_owner != .none);
    controller.navigation.clearDiffSelection();
    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var choice_before_mode = try controller.apply(null, .begin_keyboard_line_selection);
    choice_before_mode.deinit(null);
    try std.testing.expect(page.selection_owner.activeKeyboardSideChoice() != null);
    var mode_change = try controller.apply(allocator, .toggle_display_mode);
    mode_change.deinit(allocator);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection == null);

    page.viewer.diff_cursor = .{ .metadata = 0 };
    var unified_nearby = try controller.apply(null, .begin_keyboard_line_selection);
    unified_nearby.deinit(null);
    try std.testing.expect(page.selection_owner.activeKeyboardLineSelection());
    switch (page.viewer.diff_cursor) {
        .hunk_line => |line| {
            try std.testing.expectEqual(@as(usize, 0), line.hunk_index);
            try std.testing.expectEqual(@as(usize, 0), line.line_index);
        },
        else => return error.ExpectedHunkLineCursor,
    }
    var clear_nearby = try controller.apply(allocator, .{ .selection_action = .clear });
    clear_nearby.deinit(allocator);

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var removed_begin = try controller.apply(null, .begin_keyboard_line_selection);
    removed_begin.deinit(null);
    try std.testing.expect(page.selection_owner.activeDiff().?.content == .unified_diff);
    var final_clear = try controller.apply(allocator, .{ .selection_action = .clear });
    final_clear.deinit(allocator);
}

test "Changes side-by-side keyboard selection chooses and switches one semantic row" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .focus = .diff,
            .sidebar_hidden = true,
            .display_mode = .side_by_side,
        },
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 120, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    page.viewer.diff_cursor = .{ .metadata = 0 };
    var unavailable = try controller.apply(null, .begin_keyboard_line_selection);
    unavailable.deinit(null);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expectEqualStrings("No selectable code line for keyboard selection", page.status.text());

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } };
    var equal_context = try controller.apply(null, .begin_keyboard_line_selection);
    equal_context.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.new, page.selection_owner.activeDiff().?.selectedSide().?);
    var clear_context = try controller.apply(allocator, .{ .selection_action = .clear });
    clear_context.deinit(allocator);

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var begin = try controller.apply(null, .begin_keyboard_line_selection);
    begin.deinit(null);
    try std.testing.expect(page.selection_owner.activeKeyboardSideChoice() != null);
    try std.testing.expect(controller.navigation.view().keyboardSideChoiceActive());

    var stale_choice = page.selection_owner.activeKeyboardSideChoice().?;
    stale_choice.identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "stale" } };
    page.selection_owner = .{ .keyboard_side_choice = stale_choice };
    var reject_stale = try controller.apply(null, .{ .choose_keyboard_selection_side = .old });
    reject_stale.deinit(null);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expectEqualStrings("No selectable code line for keyboard selection", page.status.text());

    var restart_choice = try controller.apply(null, .begin_keyboard_line_selection);
    restart_choice.deinit(null);
    var enter_file_search = try controller.apply(allocator, .enter_file_search);
    enter_file_search.deinit(allocator);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.file_search.mode);
    var cancel_file_search = try controller.apply(allocator, .cancel_file_search);
    cancel_file_search.deinit(allocator);

    var choice_for_cancel = try controller.apply(null, .begin_keyboard_line_selection);
    choice_for_cancel.deinit(null);
    var cancel_choice = try controller.apply(allocator, .{ .selection_action = .clear });
    cancel_choice.deinit(allocator);
    try std.testing.expect(page.selection_owner == .none);

    var begin_after_cancel = try controller.apply(null, .begin_keyboard_line_selection);
    begin_after_cancel.deinit(null);

    var choose = try controller.apply(null, .{ .choose_keyboard_selection_side = .old });
    choose.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.old, page.selection_owner.activeDiff().?.selectedSide().?);
    try std.testing.expectEqual(selection_action.StatusSide.before, controller.navigation.view().selectionStatusPresentation().?.side);

    var switch_after = try controller.apply(null, .{ .switch_keyboard_selection_side = .new });
    switch_after.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.new, page.selection_owner.activeDiff().?.selectedSide().?);
    try std.testing.expectEqual(@as(usize, 3), page.selection_owner.activeDiff().?.focus.line_index);
    try std.testing.expectEqual(selection_action.StatusSide.after, controller.navigation.view().selectionStatusPresentation().?.side);

    var extend = try controller.apply(null, .{ .keyboard_line_selection_move = .up });
    extend.deinit(null);
    try std.testing.expectEqual(@as(usize, 2), page.selection_owner.activeDiff().?.selected_line_count);
    var locked = try controller.apply(null, .{ .switch_keyboard_selection_side = .old });
    locked.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.new, page.selection_owner.activeDiff().?.selectedSide().?);
    try std.testing.expectEqual(@as(usize, 2), page.selection_owner.activeDiff().?.selected_line_count);

    var shrink = try controller.apply(null, .{ .keyboard_line_selection_move = .down });
    shrink.deinit(null);
    try std.testing.expectEqual(@as(usize, 1), page.selection_owner.activeDiff().?.selected_line_count);
    var switch_before = try controller.apply(null, .{ .switch_keyboard_selection_side = .old });
    switch_before.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.old, page.selection_owner.activeDiff().?.selectedSide().?);
    try std.testing.expectEqual(@as(usize, 2), page.selection_owner.activeDiff().?.focus.line_index);

    var copied = try controller.apply(allocator, .{ .selection_action = .copy });
    defer copied.deinit(allocator);
    var copy_command = copied.takeCommand() orelse return error.ExpectedCopyCommand;
    defer copy_command.deinit(allocator);
    switch (copy_command) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings("old", copy.text),
        else => return error.ExpectedCopyCommand,
    }
    try std.testing.expect(page.selection_owner == .none);

    const OneSided = struct {
        const removed_lines = [_]diff_parser.DiffLine{.{ .kind = .removed, .text = "before only", .old_line = 1 }};
        const added_lines = [_]diff_parser.DiffLine{.{ .kind = .added, .text = "after only", .new_line = 1 }};
        const hunks = [_]diff_parser.Hunk{
            .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0, .section = "removed", .lines = &removed_lines },
            .{ .old_start = 2, .old_count = 0, .new_start = 1, .new_count = 1, .section = "added", .lines = &added_lines },
        };
        const files = [_]diff_parser.FileDiff{.{
            .header = "diff --git a/one b/one",
            .old_path = "one",
            .new_path = "one",
            .metadata = &.{ "--- a/one", "+++ b/one" },
            .hunks = &hunks,
        }};
        const eligibility = [_]loaded_diff.FileTextEligibility{.selectable_utf8};
        const nodes = [_]file_tree.Node{.{ .kind = .file, .name = "one", .path = "one", .depth = 0, .target = .{ .diff_file = 0 } }};
    };
    const one_sided_loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &OneSided.files },
        .file_text_eligibility = &OneSided.eligibility,
        .tree = .{ .nodes = &OneSided.nodes },
        .bytes = 0,
        .lines = 0,
    };
    var one_sided_page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(one_sided_loaded),
        .viewer = .{ .focus = .diff, .sidebar_hidden = true, .display_mode = .side_by_side },
    };
    defer one_sided_page.deinit(allocator);
    const one_sided: Controller = .{ .navigation = .{
        .page = &one_sided_page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 120, .height = 20 },
        .diagnostics = .{ .target = &one_sided_page.status },
    } };

    one_sided_page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } };
    var removed_direct = try one_sided.apply(null, .begin_keyboard_line_selection);
    removed_direct.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.old, one_sided_page.selection_owner.activeDiff().?.selectedSide().?);
    var missing_after = try one_sided.apply(null, .{ .switch_keyboard_selection_side = .new });
    missing_after.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.old, one_sided_page.selection_owner.activeDiff().?.selectedSide().?);
    try std.testing.expectEqualStrings("No matching line on that selection side", one_sided_page.status.text());
    var clear_removed = try one_sided.apply(allocator, .{ .selection_action = .clear });
    clear_removed.deinit(allocator);

    one_sided_page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 1, .line_index = 0 } };
    var added_direct = try one_sided.apply(null, .begin_keyboard_line_selection);
    added_direct.deinit(null);
    try std.testing.expectEqual(diff_selection.Side.new, one_sided_page.selection_owner.activeDiff().?.selectedSide().?);

    var focus_page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffRootedNested()),
        .viewer = .{
            .selected_target = .{ .diff_file = 0 },
            .selected_node = 2,
            .focus = .diff,
            .display_mode = .side_by_side,
        },
    };
    defer focus_page.deinit(allocator);
    const focus_controller: Controller = .{ .navigation = .{
        .page = &focus_page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 120, .height = 20 },
        .diagnostics = .{ .target = &focus_page.status },
    } };

    focus_page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 2 } };
    var same_file_choice = try focus_controller.apply(null, .begin_keyboard_line_selection);
    same_file_choice.deinit(null);
    try std.testing.expect(focus_page.selection_owner.activeKeyboardSideChoice() != null);
    var same_file_click = try focus_controller.apply(allocator, .{ .sidebar_click_node = 2 });
    same_file_click.deinit(null);
    try std.testing.expect(focus_page.selection_owner == .none);
    try std.testing.expectEqual(diff_surface.Focus.sidebar, focus_page.viewer.focus);

    focus_page.viewer.focus = .diff;
    var directory_choice = try focus_controller.apply(null, .begin_keyboard_line_selection);
    directory_choice.deinit(null);
    var directory_click = try focus_controller.apply(allocator, .{ .sidebar_click_node = 1 });
    directory_click.deinit(null);
    try std.testing.expect(focus_page.selection_owner == .none);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, focus_page.viewer.selected_target.?);

    focus_page.viewer.selected_node = 0;
    focus_page.viewer.focus = .diff;
    var boundary_choice = try focus_controller.apply(null, .begin_keyboard_line_selection);
    boundary_choice.deinit(null);
    var boundary_wheel = try focus_controller.apply(allocator, .mouse_sidebar_wheel_up);
    boundary_wheel.deinit(null);
    try std.testing.expect(focus_page.selection_owner == .none);
    try std.testing.expectEqual(@as(usize, 0), focus_page.viewer.selected_node);
}

test "Changes keyboard line selection clipboard preparation failure installs a retryable candidate" {
    const allocator = std.testing.allocator;
    var observed_clipboard_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 32 and !observed_clipboard_failure) : (fail_index += 1) {
        var page: changes_page.ChangesPageState = .{
            .load = test_support.loadState(test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff, .sidebar_hidden = true },
        };
        defer page.deinit(allocator);
        var active = diff_selection.DragSelection.initKeyboardLine(
            .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
            .new,
            .{ .hunk_index = 0, .line_index = 0 },
        );
        active.updateKeyboardLine(.{ .hunk_index = 0, .line_index = 1 }, 2);
        page.selection_owner = .{ .diff = active };
        const controller: Controller = .{ .navigation = .{
            .page = &page,
            .repo_root = null,
            .source = .unstaged,
            .layout = .{ .width = 80, .height = 20 },
            .diagnostics = .{ .target = &page.status },
        } };
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var attempted = try controller.apply(failing.allocator(), .{ .selection_action = .copy });
        defer attempted.deinit(failing.allocator());

        if (page.selection_owner == .none and page.completed_selection != null and attempted.command == null) {
            observed_clipboard_failure = true;
            try std.testing.expectEqualStrings(
                "Could not prepare selected text for copying; press y to retry",
                page.status.text(),
            );
            var retried = try controller.apply(allocator, .{ .selection_action = .copy });
            defer retried.deinit(allocator);
            var command = retried.takeCommand() orelse return error.ExpectedCopyCommand;
            defer command.deinit(allocator);
            switch (command) {
                .copy_diff_selection => |copy| try std.testing.expectEqualStrings("one\ntwo\n", copy.text),
                else => return error.ExpectedCopyCommand,
            }
            try std.testing.expect(page.completed_selection != null);
        }
    }
    try std.testing.expect(observed_clipboard_failure);
}

test "Changes unified keyboard selection omits a folded hunk from count and copy" {
    const Fixture = struct {
        const first_lines = [_]diff_parser.DiffLine{
            .{ .kind = .context, .text = "start", .old_line = 1, .new_line = 1 },
        };
        const hidden_lines = [_]diff_parser.DiffLine{
            .{ .kind = .context, .text = "hidden context", .old_line = 10, .new_line = 10 },
            .{ .kind = .added, .text = "hidden added", .new_line = 11 },
        };
        const last_lines = [_]diff_parser.DiffLine{
            .{ .kind = .context, .text = "end", .old_line = 20, .new_line = 20 },
        };
        const hunks = [_]diff_parser.Hunk{
            .{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1, .section = "first", .lines = &first_lines },
            .{ .old_start = 10, .old_count = 1, .new_start = 10, .new_count = 2, .section = "folded", .lines = &hidden_lines },
            .{ .old_start = 20, .old_count = 1, .new_start = 20, .new_count = 1, .section = "last", .lines = &last_lines },
        };
        const files = [_]diff_parser.FileDiff{.{
            .header = "diff --git a/a b/a",
            .old_path = "a",
            .new_path = "a",
            .metadata = &.{ "index 1..2", "--- a/a", "+++ b/a" },
            .hunks = &hunks,
        }};
        const eligibility = [_]loaded_diff.FileTextEligibility{.selectable_utf8};
        const nodes = [_]file_tree.Node{
            .{ .kind = .file, .name = "a", .path = "a", .depth = 0, .target = .{ .diff_file = 0 } },
        };
    };

    const allocator = std.testing.allocator;
    var folded = [_]bool{ false, true, false };
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &Fixture.files },
        .file_text_eligibility = &Fixture.eligibility,
        .tree = .{ .nodes = &Fixture.nodes },
        .collapsed_hunks = &folded,
        .bytes = 0,
        .lines = 0,
    };
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(loaded),
        .viewer = .{
            .focus = .diff,
            .sidebar_hidden = true,
            .display_mode = .unified,
            .diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } },
        },
    };
    defer page.deinit(allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 12 },
        .diagnostics = .{ .target = &page.status },
    } };

    var begin = try controller.apply(null, .begin_keyboard_line_selection);
    begin.deinit(null);
    var moved = try controller.apply(null, .{ .keyboard_line_selection_move = .down });
    moved.deinit(null);
    const active = page.selection_owner.activeDiff() orelse return error.ExpectedDiffSelection;
    try std.testing.expectEqual(@as(usize, 2), active.focus.hunk_index);
    try std.testing.expectEqual(@as(usize, 2), active.selected_line_count);
    try std.testing.expectEqual(@as(usize, 2), controller.navigation.view().selectionStatusPresentation().?.line_count);

    var copied = try controller.apply(allocator, .{ .selection_action = .copy });
    defer copied.deinit(allocator);
    var command = copied.takeCommand() orelse return error.ExpectedCopyCommand;
    defer command.deinit(allocator);
    switch (command) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings(
            " start\n end\n",
            copy.text,
        ),
        else => return error.ExpectedCopyCommand,
    }
    try std.testing.expectEqual(@as(usize, 2), page.completed_selection.?.lineCount());
}

test "Changes fixed status row routes mouse Copy and Clear without changing body coordinates" {
    const allocator = std.testing.allocator;
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .sidebar_hidden = true, .display_mode = .unified },
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
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 3 },
        .moved = true,
    } };
    var release = try controller.apply(allocator, .{ .mouse_diff_release = null });
    release.deinit(allocator);

    const raw = controller.navigation.view().rawDiffPaneGeometry().?;
    const action_layout = diff_surface.selection_action.statusLayout(
        .{ .col = 1, .width = raw.width - 1 },
        controller.navigation.view().selectionStatusPresentation().?,
    );
    const copy_point = diff_surface.MousePoint{
        .col = raw.col + action_layout.copy.?.col,
        .row = 1,
    };

    var inert = try controller.apply(allocator, .{ .mouse_diff_press = .{
        .col = copy_point.col,
        .row = diff_render.body_start_row,
    } });
    inert.deinit(allocator);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.selection_owner == .none);

    var copied = try controller.apply(allocator, .{ .mouse_diff_press = copy_point });
    defer copied.deinit(allocator);
    var copy_command = copied.takeCommand() orelse return error.ExpectedCopyCommand;
    defer copy_command.deinit(allocator);
    switch (copy_command) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings(" one\n two\n-old\n+new\n", copy.text),
        else => return error.ExpectedCopyCommand,
    }
    try std.testing.expect(page.completed_selection != null);

    const clear_point = diff_surface.MousePoint{
        .col = raw.col + action_layout.clear.?.col,
        .row = copy_point.row,
    };
    var cleared = try controller.apply(allocator, .{ .mouse_diff_press = clear_point });
    cleared.deinit(allocator);
    try std.testing.expect(page.completed_selection == null);

    page.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 0 } };
    var begin_for_clear = try controller.apply(null, .begin_keyboard_line_selection);
    begin_for_clear.deinit(null);
    const active_clear_layout = diff_surface.selection_action.statusLayout(
        .{ .col = 1, .width = raw.width - 1 },
        controller.navigation.view().selectionStatusPresentation().?,
    );
    const active_clear_point = diff_surface.MousePoint{
        .col = raw.col + active_clear_layout.clear.?.col,
        .row = 1,
    };
    var active_cleared = try controller.apply(allocator, .{ .mouse_diff_press = active_clear_point });
    active_cleared.deinit(allocator);
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection == null);

    var begin_for_copy = try controller.apply(null, .begin_keyboard_line_selection);
    begin_for_copy.deinit(null);
    const active_copy_layout = diff_surface.selection_action.statusLayout(
        .{ .col = 1, .width = raw.width - 1 },
        controller.navigation.view().selectionStatusPresentation().?,
    );
    const active_copy_point = diff_surface.MousePoint{
        .col = raw.col + active_copy_layout.copy.?.col,
        .row = 1,
    };
    var active_copied = try controller.apply(allocator, .{ .mouse_diff_press = active_copy_point });
    defer active_copied.deinit(allocator);
    var active_copy_command = active_copied.takeCommand() orelse return error.ExpectedCopyCommand;
    defer active_copy_command.deinit(allocator);
    switch (active_copy_command) {
        .copy_diff_selection => |copy| try std.testing.expectEqualStrings(" one", copy.text),
        else => return error.ExpectedCopyCommand,
    }
    try std.testing.expect(page.selection_owner == .none);
    try std.testing.expect(page.completed_selection != null);
}

test "changes header release returns an independent owned path command" {
    const borrowed_path = "src/app.zig";
    var page: changes_page.ChangesPageState = .{
        .selection_owner = .{ .diff_header = .{
            .identity = .{ .kind = .loaded_file, .path_key = borrowed_path },
            .moved = true,
        } },
    };
    defer page.deinit(std.testing.allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };

    var update = try controller.apply(std.testing.allocator, .{ .mouse_diff_release = null });
    defer update.deinit(std.testing.allocator);
    try std.testing.expect(page.selection_owner == .none);

    var command = update.takeCommand() orelse return error.ExpectedCopyCommand;
    defer command.deinit(std.testing.allocator);
    switch (command) {
        .copy_diff_header_path => |header| {
            try std.testing.expectEqualStrings(borrowed_path, header.identity.path_key);
            try std.testing.expect(header.identity.path_key.ptr != borrowed_path.ptr);
            try std.testing.expect(header.moved);
        },
        else => return error.ExpectedCopyCommand,
    }
}

test "changes header release allocation failure retains active selection" {
    const borrowed_path = "src/app.zig";
    var page: changes_page.ChangesPageState = .{
        .selection_owner = .{ .diff_header = .{
            .identity = .{ .kind = .loaded_file, .path_key = borrowed_path },
            .moved = true,
        } },
    };
    defer page.deinit(std.testing.allocator);
    const controller: Controller = .{ .navigation = .{
        .page = &page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 20 },
        .diagnostics = .{ .target = &page.status },
    } };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });

    try std.testing.expectError(
        error.OutOfMemory,
        controller.apply(failing.allocator(), .{ .mouse_diff_release = null }),
    );
    const retained = switch (page.selection_owner) {
        .diff_header => |header| header,
        else => return error.ExpectedHeaderSelection,
    };
    try std.testing.expectEqualStrings(borrowed_path, retained.identity.path_key);
    try std.testing.expectEqual(borrowed_path.ptr, retained.identity.path_key.ptr);
    try std.testing.expect(retained.moved);
}

test "failed moved release preserves prior candidate without emitting clipboard work" {
    const allocator = std.testing.allocator;
    var page: @import("../changes.zig").ChangesPageState = .{
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
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var accepted = try controller.apply(allocator, .{ .mouse_diff_release = null });
    defer accepted.deinit(allocator);
    try std.testing.expect(page.completed_selection != null);
    const retained_token = page.completed_selection.?.token;

    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "different" } },
        .content = .unified_diff,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    } };
    var rejected = try controller.apply(allocator, .{ .mouse_diff_release = null });
    defer rejected.deinit(allocator);
    try std.testing.expect(rejected.command == null);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.completed_selection.?.token.eql(retained_token));
    try std.testing.expect(page.selection_owner == .none);
}

test "clipboard allocation failure retains the accepted candidate" {
    const allocator = std.testing.allocator;
    var page: @import("../changes.zig").ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
    };
    defer page.deinit(allocator);
    page.selection_owner = .{ .diff = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .content = .unified_diff,
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
    var accepted = try controller.apply(allocator, .{ .mouse_diff_release = null });
    accepted.deinit(allocator);
    const retained_token = page.completed_selection.?.token;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var copy = try controller.apply(failing.allocator(), .{ .selection_action = .copy });
    defer copy.deinit(failing.allocator());
    try std.testing.expect(copy.command == null);
    try std.testing.expect(page.completed_selection != null);
    try std.testing.expect(page.completed_selection.?.token.eql(retained_token));

    page.completed_selection.?.token.source_session_revision +%= 1;
    var stale = try controller.apply(allocator, .{ .selection_action = .copy });
    defer stale.deinit(allocator);
    try std.testing.expect(stale.command == null);
    try std.testing.expect(page.completed_selection == null);
    try std.testing.expectEqualStrings("Retained selection is no longer available", page.status.text());
}
