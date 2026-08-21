//! Concrete transport vocabulary shared by the application shell and its
//! responsibility coordinators. This module depends only on leaf payloads;
//! it never reaches application state.

const std = @import("std");
const chasen = @import("chasen");
const actions = @import("actions.zig");
const command_line = @import("command_line.zig");
const load = @import("load.zig");
const page = @import("page.zig");
const push_retry = @import("push_retry.zig");
const review_input = @import("pages/review/input.zig");
const diff_surface = @import("diff_surface.zig");
const drag_auto_scroll = @import("drag_auto_scroll.zig");
const repository_page = @import("pages/repository.zig");
const repository_layout = @import("pages/repository/layout.zig");
const changes_message = @import("pages/changes/message.zig");
const review_store_mutation = @import("../review_store/mutation.zig");

pub const LoadFinished = load.ReadFinished;

pub const ActionFinished = union(enum) {
    stage_file: actions.StageFileFinished,
    stage_hunk: actions.StageHunkFinished,
    unstage_file: actions.UnstageFileFinished,
    unstage_hunk: actions.UnstageHunkFinished,
    discard_file: actions.DiscardFileFinished,
    commit: actions.CommitFinished,
    assist_commit_message: actions.CommitMessageAssistFinished,
    amend: actions.AmendFinished,
    push: actions.PushFinished,
    pull: actions.PullFinished,
    fetch: actions.FetchFinished,
    switch_branch: actions.SwitchBranchFinished,
    push_foreground: chasen.ForegroundCommandResult,

    pub fn deinit(self: *ActionFinished, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .push_foreground => {},
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const ClipboardCopyOutcome = union(enum) {
    sent,
    unsupported_runtime,
    write_failed: []const u8,
};

pub const ClipboardCopyFinished = struct {
    request_id: chasen.ClipboardCopyRequestId,
    outcome: ClipboardCopyOutcome,
};

pub const ShellEffectFinished = union(enum) {
    editor: chasen.ForegroundCommandResult,
    clipboard: ClipboardCopyFinished,
};

pub const MouseSelectionTarget = union(enum) {
    changes: ?changes_message.MousePoint,
    review: ?diff_surface.MousePoint,
    repository: ?repository_layout.BodyPoint,
};

pub const MouseSelectionContinuation = struct {
    pointer: drag_auto_scroll.PointerSample,
    target: MouseSelectionTarget,
};

pub const ReviewStoreOperationId = u64;

pub const ReviewStoreOperationKind = enum { draft, result };

pub const ReviewStoreOperationResult = union(enum) {
    draft: review_store_mutation.DraftResult,
    result: review_store_mutation.ResultResult,

    pub fn deinit(self: *ReviewStoreOperationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .draft => |*value| value.deinit(allocator),
            .result => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn failure(self: *const ReviewStoreOperationResult) ?review_store_mutation.Failure {
        return switch (self.*) {
            .draft => |*value| switch (value.*) {
                .committed => null,
                .failure => |value_failure| value_failure,
            },
            .result => |*value| switch (value.*) {
                .committed => null,
                .failure => |value_failure| value_failure,
            },
        };
    }

    pub fn committedRevision(self: *const ReviewStoreOperationResult) ?u64 {
        return switch (self.*) {
            .draft => |*value| switch (value.*) {
                .committed => |commit| commit.revision,
                .failure => null,
            },
            .result => |*value| switch (value.*) {
                .committed => |commit| commit.revision,
                .failure => null,
            },
        };
    }
};

pub const ReviewStoreOperationFinished = struct {
    operation_id: ReviewStoreOperationId,
    binding: review_store_mutation.RunBinding,
    kind: ReviewStoreOperationKind,
    result: ReviewStoreOperationResult,

    pub fn deinit(self: *ReviewStoreOperationFinished, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

pub const Msg = union(enum) {
    pub const undelivered_policy = .deinit;

    terminal_resized: chasen.Size,
    switch_page: page.Id,
    load_finished: LoadFinished,
    action_finished: ActionFinished,
    push_inspection_finished: push_retry.Finished,
    push_upstream_finalize_finished: push_retry.FinalizeFinished,
    shell_effect_finished: ShellEffectFinished,
    review_store_operation_finished: ReviewStoreOperationFinished,
    changes: changes_message.Msg,
    review: review_input.Msg,
    repository: repository_page.Msg,
    command_line: command_line.Msg,
    mouse_selection_drag: MouseSelectionContinuation,
    mouse_selection_release: MouseSelectionContinuation,
    drag_auto_scroll_tick: u64,
    cancel_commit_panel,
    submit_commit_panel,
    assist_commit_message,
    copy_commit_message,
    commit_panel_tab,
    commit_panel_enter,
    commit_panel_insert: u21,
    /// Borrowed from `chasen.Event.paste`; valid only during synchronous dispatch.
    commit_panel_paste: []const u8,
    commit_panel_backspace,
    commit_panel_move_left,
    commit_panel_move_right,
    commit_panel_move_up,
    commit_panel_move_down,
    enter_repo_picker,
    cancel_repo_picker,
    close_repo_picker,
    submit_repo_picker,
    repo_picker_enter_filter_input,
    repo_picker_enter_path_input,
    repo_picker_back,
    repo_picker_remove_recent,
    repo_picker_insert: u21,
    /// Borrowed from `chasen.Event.paste`; valid only during synchronous dispatch.
    repo_picker_paste: []const u8,
    repo_picker_backspace,
    repo_picker_move_previous,
    repo_picker_move_next,
    repo_picker_move_left,
    repo_picker_move_right,
    open_help,
    close_help,
    help_scroll_up,
    help_scroll_down,
    help_page_up,
    help_page_down,
    push_error_scroll_up,
    push_error_scroll_down,
    push_error_page_up,
    push_error_page_down,
    copy_popup,
    copy_footer_status,
    confirm_discard_file,
    cancel_discard_file,
    confirm_amend,
    cancel_amend,
    confirm_push,
    cancel_push,
    confirm_pull,
    cancel_pull,
    branch_switch_move_previous,
    branch_switch_move_next,
    confirm_branch_switch,
    cancel_branch_switch,
    close_push_error,
    run_interactive_push,
    reload,
    auto_reload_tick,
    focus_lost,
    git_action_spinner_tick,
    cancel_remote_action,
    quit,

    pub fn loadFinished(inner: LoadFinished) Msg {
        return .{ .load_finished = inner };
    }

    pub fn actionFinished(inner: ActionFinished) Msg {
        return .{ .action_finished = inner };
    }

    pub fn pushInspectionFinished(inner: push_retry.Finished) Msg {
        return .{ .push_inspection_finished = inner };
    }

    pub fn pushUpstreamFinalizeFinished(inner: push_retry.FinalizeFinished) Msg {
        return .{ .push_upstream_finalize_finished = inner };
    }

    pub fn editorFinished(result: chasen.ForegroundCommandResult) Msg {
        return .{ .shell_effect_finished = .{ .editor = result } };
    }

    pub fn pushForegroundFinished(result: chasen.ForegroundCommandResult) Msg {
        return actionFinished(.{ .push_foreground = result });
    }

    pub fn clipboardFinished(result: chasen.ClipboardCopyResult) Msg {
        return .{ .shell_effect_finished = .{ .clipboard = .{
            .request_id = result.request_id,
            .outcome = switch (result.outcome) {
                .sent => .sent,
                .unsupported_runtime => .unsupported_runtime,
                .write_failed => |err| .{ .write_failed = err },
            },
        } } };
    }

    /// Releases messages that the runtime cannot deliver during shutdown.
    pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .load_finished => |*finished| finished.deinit(allocator),
            .action_finished => |*finished| finished.deinit(allocator),
            .push_inspection_finished => |*finished| finished.deinit(allocator),
            .review_store_operation_finished => |*finished| finished.deinit(allocator),
            .repository => |*repository_msg| repository_msg.deinitUndelivered(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

/// System and completion messages preserve transient status text because they
/// do not represent a new user intent. All other messages begin a fresh user
/// interaction and clear ephemeral diagnostics at the root boundary.
pub fn keepsEphemeralStatus(msg: Msg) bool {
    return switch (msg) {
        .terminal_resized,
        .load_finished,
        .action_finished,
        .push_inspection_finished,
        .push_upstream_finalize_finished,
        .shell_effect_finished,
        .review_store_operation_finished,
        .auto_reload_tick,
        .drag_auto_scroll_tick,
        .focus_lost,
        .git_action_spinner_tick,
        // The copy handler must resolve and queue the currently visible text
        // before clearing its ephemeral status owner.
        .copy_footer_status,
        .command_line,
        => true,
        .repository => |repository_msg| switch (repository_msg) {
            .manifest_finished, .branch_finished, .path_history_finished => true,
            else => false,
        },
        else => false,
    };
}

test "Repository path history completion preserves root diagnostics while navigation does not" {
    // Root classification runs before page admission, so one exact variant
    // must cover later-known, unavailable, and stale completion outcomes.
    try std.testing.expect(keepsEphemeralStatus(.{
        .repository = .{ .path_history_finished = undefined },
    }));
    try std.testing.expect(!keepsEphemeralStatus(.{ .repository = .move_down }));
    try std.testing.expect(!keepsEphemeralStatus(.{ .repository = .{ .source_search_insert = 'x' } }));
}

test "footer status copy preserves its ephemeral payload until update" {
    try std.testing.expect(keepsEphemeralStatus(.copy_footer_status));
}

test "command line input preserves status until its own terminal decides it" {
    try std.testing.expect(keepsEphemeralStatus(.{ .command_line = .submit }));
    try std.testing.expect(keepsEphemeralStatus(.{ .command_line = .{ .insert = '1' } }));
}

test "undelivered action result releases owned payloads" {
    var msg = Msg.actionFinished(.{ .stage_file = .{
        .pending = .{ .generation = 1, .kind = .stage_file },
        .path = try std.testing.allocator.dupe(u8, "src/app.zig"),
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "failed") },
    } });

    msg.deinitUndelivered(std.testing.allocator);
}

test "undelivered diff and status loads release owned payloads" {
    const test_support = @import("test_support.zig");

    var diff_msg = Msg.loadFinished(.{ .changes = .{ .source = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .loaded = try load.buildLoadedBundle(std.testing.allocator, test_support.diff_one) },
    } } });
    diff_msg.deinitUndelivered(std.testing.allocator);

    var status_msg = Msg.loadFinished(.{ .changes = .{ .status = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 2,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "status failed") },
    } } });
    status_msg.deinitUndelivered(std.testing.allocator);
}

test "undelivered repo and projection loads release owned payloads" {
    const changes_projection = @import("changes_projection.zig");

    var repo_msg = Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "discovery failed") },
    } } });
    repo_msg.deinitUndelivered(std.testing.allocator);

    const request = try changes_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.changes(0, 1),
        7,
        "/repo",
        "src/app.zig",
        .generated_added_file,
        .cached,
        3,
        4,
    );
    var projection_msg = Msg.loadFinished(.{ .changes = .{ .projection = .{
        .request = request,
        .result = .{ .failed = try changes_projection.statusBodyAlloc(
            std.testing.allocator,
            "src/app.zig",
            "{s}",
            .{"projection failed"},
        ) },
    } } });
    projection_msg.deinitUndelivered(std.testing.allocator);
}

test "undelivered remaining read routes release owned payloads" {
    const allocator = std.testing.allocator;

    var branch_status_msg = Msg.loadFinished(.{ .changes = .{ .branch_status = .{
        .identity = page.RequestIdentity.changes(0, 1),
        .generation = 1,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "branch status failed") },
    } } });
    branch_status_msg.deinitUndelivered(allocator);

    var repo_path_msg = Msg.loadFinished(.{ .shell = .{ .repo_path_discovery = .{
        .generation = 2,
        .submitted_path = try allocator.dupe(u8, "/workspace"),
        .result = .{ .failed = try allocator.dupe(u8, "path discovery failed") },
    } } });
    repo_path_msg.deinitUndelivered(allocator);

    var branch_list_msg = Msg.loadFinished(.{ .shell = .{ .branch_list = .{
        .origin = .changes,
        .repo_epoch = 3,
        .activation_id = 5,
        .generation = 4,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "branch list failed") },
    } } });
    branch_list_msg.deinitUndelivered(allocator);

    var review_msg = Msg.loadFinished(.{ .review = .{ .source = .{
        .identity = page.RequestIdentity.review(3, 5),
        .generation = 4,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{
                    .full_ref = try allocator.dupe(u8, "refs/heads/main"),
                    .display_name = try allocator.dupe(u8, "main"),
                    .kind = .local,
                },
                .head_display = try allocator.dupe(u8, "feature"),
                .target = .{
                    .object_format = .sha1,
                    .source_kind = .branch_range,
                    .base_oid = .{},
                    .head_oid = .{},
                    .diff_base_oid = .{},
                },
                .ahead_count = 1,
            },
            .diff = .empty,
        } },
    } } });
    review_msg.deinitUndelivered(allocator);
}

test "AI Reviews picker undelivered task terminals release every owned store path" {
    const allocator = std.testing.allocator;
    const identity = page.RequestIdentity.review(3, 5);

    var scan = Msg.loadFinished(.{ .review = .{ .history_scan = .{
        .identity = identity,
        .generation = 1,
        .store_root = try allocator.dupe(u8, "/store"),
        .result = .{ .failed_static = "scan failed" },
    } } });
    scan.deinitUndelivered(allocator);

    var selection = Msg.loadFinished(.{ .review = .{ .history_selection = .{
        .identity = identity,
        .generation = 2,
        .store_root = try allocator.dupe(u8, "/store"),
        .review_id = undefined,
        .result = .{ .failed_static = "selection failed" },
    } } });
    selection.deinitUndelivered(allocator);

    var normal = Msg.loadFinished(.{ .review = .{ .history_normal_return = .{
        .identity = identity,
        .generation = 3,
        .store_root = try allocator.dupe(u8, "/store"),
        .result = .{ .failed_static = "normal failed" },
    } } });
    normal.deinitUndelivered(allocator);
}

test "undelivered plain root message is a no-op" {
    var msg: Msg = .quit;
    msg.deinitUndelivered(std.testing.allocator);

    const foreground: chasen.ForegroundCommandResult = .{
        .request_id = .{ .id = 17 },
        .outcome = .{ .exited = 0 },
    };
    var editor = Msg.editorFinished(foreground);
    try std.testing.expectEqual(@as(u64, 17), editor.shell_effect_finished.editor.request_id.id);
    editor.deinitUndelivered(std.testing.allocator);
    const push = Msg.pushForegroundFinished(foreground);
    try std.testing.expectEqual(@as(u64, 17), push.action_finished.push_foreground.request_id.id);
    var clipboard = Msg.clipboardFinished(.{
        .request_id = .{ .id = 23 },
        .outcome = .unsupported_runtime,
    });
    try std.testing.expectEqual(@as(u64, 23), clipboard.shell_effect_finished.clipboard.request_id.id);
    try std.testing.expect(clipboard.shell_effect_finished.clipboard.outcome == .unsupported_runtime);
    clipboard.deinitUndelivered(std.testing.allocator);
}
