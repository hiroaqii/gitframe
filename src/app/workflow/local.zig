//! Changes-local Git workflow owner.
//!
//! This module owns commit-panel and local confirmation state, prepares local
//! operation tasks through the shared action lifecycle, and interprets exact
//! local terminals. It returns typed reload requests; only the root shell
//! bridges those requests into Changes read coordination.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");

const app_actions = @import("../actions.zig");
const app_commit_panel = @import("../commit_panel.zig");
const app_git_requests = @import("../git_requests.zig");
const app_message = @import("../message.zig");
const app_state = @import("../state.zig");
const changes_action_fence = @import("../pages/changes/action_fence.zig");
const changes_operations = @import("../pages/changes/operations.zig");
const repo_session = @import("../repo_session.zig");
const action_lifecycle = @import("action_lifecycle.zig");
const config_mod = @import("../../config.zig");
const git_ops = @import("../git_ops.zig");

pub const LocalState = struct {
    commit_panel: app_commit_panel.State = .{},
    discard_confirmation: ?app_state.DiscardFileConfirmation = null,
    amend_confirmation: ?app_state.AmendConfirmation = null,

    pub fn init(allocator: std.mem.Allocator) LocalState {
        return .{ .commit_panel = app_commit_panel.State.init(allocator) };
    }

    pub fn view(self: *const LocalState) View {
        return .{ .state = self };
    }

    pub fn deinit(self: *LocalState, allocator: std.mem.Allocator) void {
        self.commit_panel.deinit();
        if (self.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
        if (self.amend_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.* = .{};
    }
};

pub const View = struct {
    state: *const LocalState,

    pub fn commitPanel(self: View) *const app_commit_panel.State {
        return &self.state.commit_panel;
    }

    pub fn commitPanelOpen(self: View) bool {
        return self.state.commit_panel.is_open;
    }

    pub fn commitPanelInstanceId(self: View) ?u64 {
        return if (self.state.commit_panel.is_open) self.state.commit_panel.instance_id else null;
    }

    pub fn discardConfirmation(self: View) ?app_state.DiscardFileConfirmation {
        return self.state.discard_confirmation;
    }

    pub fn amendConfirmation(self: View) ?app_state.AmendConfirmation {
        return self.state.amend_confirmation;
    }
};

pub const ActionReloadIntent = struct {
    pending: app_actions.PendingAction,
    active_matches: bool,
    reload: changes_action_fence.ReloadIntent,
};

pub const Controller = struct {
    state: *LocalState,
    lifecycle: action_lifecycle.Controller,
    operations: changes_operations.Controller,
    repo: repo_session.View,
    current_changes_root: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
    user_config: *const config_mod.Config,
    status: *app_state.StatusMessage,
    overlay: *app_state.OverlayState,

    pub fn view(self: Controller) View {
        return self.state.view();
    }

    fn setStatus(self: Controller, comptime fmt: []const u8, args: anytype) void {
        self.status.set(fmt, args);
    }

    pub fn stageSelectedFile(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.operations.view().stageTarget()) {
            .ready => |target| target,
            .already_staged => |path| {
                self.setStatus("already staged: {s}", .{path});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setStatus("source is stale; press r to reload", .{});
                return;
            },
            .conflict_unsupported => |path| {
                self.setStatus("conflict under selection: {s}", .{path});
                return;
            },
            .no_stageable_content => |path| {
                self.setStatus("no stageable files under: {s}", .{path});
                return;
            },
            .unavailable_source, .no_repo => {
                self.setStatus("stage unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setStatus("no stageable file selected", .{});
                return;
            },
        };
        var proposal = try self.operations.view().ownStageFileProposal(ctx.allocator(), target);
        defer proposal.deinit(ctx.allocator());
        const owned = proposal.stage_file;
        const root_identity = self.repo.activeIdentity() orelse {
            self.setStatus("stage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.operations.navigation.prepareActionCursor(
            ctx.allocator(),
            self.repo.epoch(),
            root_identity,
            actionCursorKind(owned.kind),
            owned.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());

        const prepared = self.lifecycle.prepare(.stage_file);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("stage unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startStageFile(app_message.Msg, ctx, prepared.pending, .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .kind = owned.kind,
            .label = owned.label,
        }, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start stage task", .{});
            return err;
        };
        const accepted = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.operations.navigation.installActionCursor(ctx.allocator(), &cursor, accepted.pending.generation);
        cursor_owned = false;
        self.setStatus("staging: {s}", .{owned.label});
    }

    pub fn toggleSelectedFileStage(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }

        switch (self.operations.view().toggleStageTarget()) {
            .operation => |operation| switch (operation) {
                .stage => try self.stageSelectedFile(ctx),
                .unstage => try self.unstageSelectedFile(ctx),
            },
            .unavailable_source, .no_repo => self.setStatus("stage toggle unavailable for this source", .{}),
            .no_path => self.setStatus("no file selected", .{}),
            .stale_status => self.setStatus("status is still loading", .{}),
            .stale_source => self.setStatus("source is stale; press r to reload", .{}),
            .conflict_unsupported => |target| {
                if (target.kind == .directory) {
                    self.setStatus("conflict under directory: {s}", .{target.path});
                } else {
                    self.setStatus("conflict stage toggle is not supported yet", .{});
                }
            },
            .no_content => |target| {
                if (target.kind == .directory) {
                    self.setStatus("no stageable or staged files under: {s}", .{target.path});
                } else {
                    self.setStatus("no stageable or staged content selected", .{});
                }
            },
        }
    }

    pub fn stageSelectedHunk(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        var target = switch (self.operations.view().selectedHunkStageTarget(ctx.allocator())) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("hunk stage unavailable for this source", .{});
                return;
            },
            .no_file => {
                self.setStatus("no file selected", .{});
                return;
            },
            .no_path => {
                self.setStatus("hunk stage unavailable for status-only file", .{});
                return;
            },
            .no_hunk => {
                self.setStatus("no hunk selected", .{});
                return;
            },
            .inert_invalid_utf8 => {
                self.setStatus(git_ops.inert_hunk_action_message, .{});
                return;
            },
            .offscreen_cursor => {
                self.setStatus("cursor is offscreen; move cursor first", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setStatus("source is stale; press r to reload", .{});
                return;
            },
            .conflict_unsupported => {
                self.setStatus("conflict hunk stage is not supported yet", .{});
                return;
            },
            .binary_unsupported => {
                self.setStatus("binary hunk stage is not supported", .{});
                return;
            },
            .unsupported_file_state => {
                self.setStatus("hunk stage supports modified files only", .{});
                return;
            },
            .already_staged_hunk => {
                self.setStatus("hunk already staged", .{});
                return;
            },
            .patch_failed => {
                self.setStatus("could not build hunk patch", .{});
                return;
            },
        };

        var proposal = try self.operations.view().ownStageHunkProposal(ctx.allocator(), &target);
        defer proposal.deinit(ctx.allocator());
        const owned = &proposal.stage_hunk;
        const root_identity = self.repo.activeIdentity() orelse {
            self.setStatus("hunk stage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.operations.navigation.prepareActionCursor(
            ctx.allocator(),
            self.repo.epoch(),
            root_identity,
            .file,
            owned.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());
        var task_target: git_ops.HunkStageTarget = .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .hunk_index = owned.hunk_index,
            .patch = owned.patch,
            .session_mark_mutation = owned.session_mark_mutation,
            .reload_after_success = owned.reload_after_success,
        };
        defer task_target.deinit(ctx.allocator());
        owned.patch = &.{};
        const prepared = self.lifecycle.prepare(.stage_hunk);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("hunk stage unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startStageHunk(app_message.Msg, ctx, prepared.pending, &task_target, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start hunk stage task", .{});
            return err;
        };
        const accepted = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.operations.navigation.installActionCursor(ctx.allocator(), &cursor, accepted.pending.generation);
        cursor_owned = false;
        self.setStatus("staging hunk: {s}", .{owned.path});
    }

    pub fn toggleSelectedHunkStage(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }

        switch (self.operations.view().selectedHunkToggleOperation()) {
            .operation => |operation| switch (operation) {
                .stage => try self.stageSelectedHunk(ctx),
                .unstage => try self.unstageSelectedHunk(ctx),
            },
            .unavailable_source, .no_repo => self.setStatus("hunk stage toggle unavailable for this source", .{}),
            .no_file => self.setStatus("no file selected", .{}),
            .no_path => self.setStatus("hunk stage toggle unavailable for status-only file", .{}),
            .no_hunk => self.setStatus("no hunk selected", .{}),
            .inert_invalid_utf8 => self.setStatus(git_ops.inert_hunk_action_message, .{}),
            .offscreen_cursor => self.setStatus("cursor is offscreen; move cursor first", .{}),
            .stale_status => self.setStatus("status is still loading", .{}),
            .stale_source => self.setStatus("source is stale; press r to reload", .{}),
        }
    }

    pub fn unstageSelectedHunk(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        var target = switch (self.operations.view().selectedHunkUnstageTarget(ctx.allocator())) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("hunk unstage unavailable for this source", .{});
                return;
            },
            .no_file => {
                self.setStatus("no file selected", .{});
                return;
            },
            .no_path => {
                self.setStatus("hunk unstage unavailable for status-only file", .{});
                return;
            },
            .no_hunk => {
                self.setStatus("no hunk selected", .{});
                return;
            },
            .inert_invalid_utf8 => {
                self.setStatus(git_ops.inert_hunk_action_message, .{});
                return;
            },
            .offscreen_cursor => {
                self.setStatus("cursor is offscreen; move cursor first", .{});
                return;
            },
            .not_staged_hunk => {
                self.setStatus("hunk is not staged", .{});
                return;
            },
            .binary_unsupported => {
                self.setStatus("binary hunk unstage is not supported", .{});
                return;
            },
            .unsupported_file_state => {
                self.setStatus("hunk unstage supports modified files only", .{});
                return;
            },
            .patch_failed => {
                self.setStatus("could not build hunk patch", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setStatus("source is stale; press r to reload", .{});
                return;
            },
        };

        var proposal = try self.operations.view().ownUnstageHunkProposal(ctx.allocator(), &target);
        defer proposal.deinit(ctx.allocator());
        const owned = &proposal.unstage_hunk;
        const root_identity = self.repo.activeIdentity() orelse {
            self.setStatus("hunk unstage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.operations.navigation.prepareActionCursor(
            ctx.allocator(),
            self.repo.epoch(),
            root_identity,
            .file,
            owned.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());
        var task_target: git_ops.HunkUnstageTarget = .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .hunk_index = owned.hunk_index,
            .patch = owned.patch,
            .session_mark_mutation = owned.session_mark_mutation,
            .reload_after_success = owned.reload_after_success,
        };
        defer task_target.deinit(ctx.allocator());
        owned.patch = &.{};
        const prepared = self.lifecycle.prepare(.unstage_hunk);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("hunk unstage unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startUnstageHunk(app_message.Msg, ctx, prepared.pending, &task_target, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start hunk unstage task", .{});
            return err;
        };
        const accepted = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.operations.navigation.installActionCursor(ctx.allocator(), &cursor, accepted.pending.generation);
        cursor_owned = false;
        self.setStatus("unstaging hunk: {s}", .{owned.path});
    }

    pub fn unstageSelectedFile(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.operations.view().unstageTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("unstage unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setStatus("no file selected", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setStatus("source is stale; press r to reload", .{});
                return;
            },
            .conflict_unsupported => |target_path| {
                if (target_path.kind == .directory or target_path.kind == .repository) {
                    self.setStatus("conflict under selection: {s}", .{target_path.path});
                } else {
                    self.setStatus("conflict unstage is not supported yet", .{});
                }
                return;
            },
            .no_staged_content => |target_path| {
                if (target_path.kind == .directory or target_path.kind == .repository) {
                    self.setStatus("no staged files under: {s}", .{target_path.path});
                } else {
                    self.setStatus("no staged content selected", .{});
                }
                return;
            },
        };

        var proposal = try self.operations.view().ownUnstageFileProposal(ctx.allocator(), target);
        defer proposal.deinit(ctx.allocator());
        const owned = proposal.unstage_file;
        const root_identity = self.repo.activeIdentity() orelse {
            self.setStatus("unstage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.operations.navigation.prepareActionCursor(
            ctx.allocator(),
            self.repo.epoch(),
            root_identity,
            actionCursorKind(owned.kind),
            owned.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());

        const prepared = self.lifecycle.prepare(.unstage_file);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("unstage unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startUnstageFile(app_message.Msg, ctx, prepared.pending, .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .kind = owned.kind,
            .label = owned.label,
        }, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start unstage task", .{});
            return err;
        };
        const accepted = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.operations.navigation.installActionCursor(ctx.allocator(), &cursor, accepted.pending.generation);
        cursor_owned = false;
        self.setStatus("unstaging: {s}", .{owned.label});
    }

    pub fn requestDiscardSelectedFile(self: Controller, allocator: std.mem.Allocator) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.operations.view().discardTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setStatus("discard unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setStatus("no file selected", .{});
                return;
            },
            .stale_status => {
                self.setStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setStatus("source is stale; press r to reload", .{});
                return;
            },
            .directory_unsupported => {
                self.setStatus("directory discard is not supported yet", .{});
                return;
            },
            .conflict_unsupported => {
                self.setStatus("conflict discard is not supported yet", .{});
                return;
            },
            .untracked_unsupported => {
                self.setStatus("untracked discard is not supported yet", .{});
                return;
            },
            .no_unstaged_content => {
                self.setStatus("no unstaged changes selected", .{});
                return;
            },
        };

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        var proposal = try self.operations.view().ownDiscardProposal(allocator, target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(allocator);
        const owned = proposal.discard;
        self.state.discard_confirmation = .{ .repo_root = owned.repo_root, .path = owned.path };
        proposal_consumed = true;
        self.operations.navigation.clearDiffSelection();
        self.overlay.openDiscardFile();
    }

    pub fn confirmDiscardFile(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const confirmation = self.state.discard_confirmation orelse return;
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }

        const root_identity = self.repo.activeIdentity() orelse {
            self.setStatus("discard unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.operations.navigation.prepareActionCursor(
            ctx.allocator(),
            self.repo.epoch(),
            root_identity,
            .file,
            confirmation.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());

        const prepared = self.lifecycle.prepare(.discard_file);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("discard unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startDiscardFile(
            app_message.Msg,
            ctx,
            prepared.pending,
            confirmation.repo_root,
            confirmation.path,
            capability,
            self.env_map,
        ) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            self.setStatus("could not start discard task", .{});
            return err;
        };
        const accepted = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.operations.navigation.installActionCursor(ctx.allocator(), &cursor, accepted.pending.generation);
        cursor_owned = false;

        self.setStatus("discarding: {s}", .{confirmation.path});
        self.cancelDiscardConfirmation(ctx.allocator());
    }

    pub fn enterCommitPanelMode(self: Controller, allocator: std.mem.Allocator, mode: app_commit_panel.Mode) void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("finish current git action before committing", .{});
            return;
        }
        if (!self.operations.view().canOpenCommitPanel()) {
            self.setStatus("commit unavailable for this source", .{});
            return;
        }

        self.cancelConfirmations(allocator);
        self.overlay.close();
        self.operations.navigation.clearDiffSelection();
        self.state.commit_panel.open(mode);
    }

    pub fn closeCommitPanel(self: Controller) void {
        _ = self.lifecycle.cancelAcceptedCommitAssist();
        self.state.commit_panel.close();
    }

    pub fn toggleCommitPanelField(self: Controller) void {
        self.state.commit_panel.toggleField();
    }

    pub fn commitPanelEnter(self: Controller) void {
        self.state.commit_panel.enter();
    }

    pub fn commitPanelInsert(self: Controller, codepoint: u21) void {
        self.state.commit_panel.insert(codepoint);
    }

    pub fn commitPanelPaste(self: Controller, text: []const u8) void {
        self.state.commit_panel.paste(text);
    }

    pub fn commitPanelBackspace(self: Controller) void {
        self.state.commit_panel.backspace();
    }

    pub fn commitPanelMoveLeft(self: Controller) void {
        self.state.commit_panel.moveLeft();
    }

    pub fn commitPanelMoveRight(self: Controller) void {
        self.state.commit_panel.moveRight();
    }

    pub fn commitPanelMoveUp(self: Controller) void {
        self.state.commit_panel.moveUp();
    }

    pub fn commitPanelMoveDown(self: Controller) void {
        self.state.commit_panel.moveDown();
    }

    pub fn markCommitCopyAllocationFailed(self: Controller) void {
        self.state.commit_panel.commit_error = .input_allocation_failed;
    }

    pub fn formatCommitMessage(self: Controller, allocator: std.mem.Allocator) ![]u8 {
        return self.state.commit_panel.formatMessage(allocator);
    }

    pub fn stagedSummary(self: Controller) app_commit_panel.StagedSummary {
        return switch (self.operations.view().commitSummary()) {
            .unavailable => .unavailable,
            .loading_or_stale => .loading_or_stale,
            .ready => |ready| .{ .ready = .{ .count = ready.count } },
        };
    }

    pub fn submitCommitPanel(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const panel = &self.state.commit_panel;
        if (self.lifecycle.view().hasPending()) {
            panel.commit_error = .action_pending;
            self.setStatus("finish current git action before committing", .{});
            return;
        }

        if (panel.validateSubmit(self.stagedSummary())) |err| {
            panel.commit_error = err;
            return;
        }

        const repo_root = self.repo.activeRoot() orelse {
            panel.commit_error = .status_unavailable;
            self.setStatus("commit unavailable for this source", .{});
            return;
        };

        if (panel.mode == .amend) {
            try self.openAmendConfirmation(ctx.allocator(), repo_root);
            return;
        }

        try self.startCommitTask(ctx, repo_root);
    }

    pub fn assistCommitMessage(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const panel = &self.state.commit_panel;
        if (self.lifecycle.view().hasPending()) {
            panel.commit_error = .action_pending;
            self.setStatus("finish current git action before assisting commit message", .{});
            return;
        }
        if (!panel.is_open or panel.mode != .commit) {
            self.setStatus("commit message assist is only available in commit mode", .{});
            return;
        }
        switch (self.stagedSummary()) {
            .ready => |ready| if (ready.count == 0) {
                panel.commit_error = .no_staged_changes;
                return;
            },
            .loading_or_stale => {
                panel.commit_error = .status_loading;
                return;
            },
            .unavailable => {
                panel.commit_error = .status_unavailable;
                return;
            },
        }

        const repo_root = self.repo.activeRoot() orelse {
            panel.commit_error = .status_unavailable;
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            panel.commit_error = .status_unavailable;
            return;
        };
        const identity = self.repo.activeIdentity() orelse {
            panel.commit_error = .status_unavailable;
            return;
        };
        if (!capability.identity.eql(identity)) {
            panel.commit_error = .status_unavailable;
            return;
        }

        const draft_empty = panel.draftIsEmpty();
        const action = if (draft_empty)
            self.resolveGenerateCommitMessageAction() catch |err| {
                self.setStatus("{s}", .{commitMessageActionResolveMessage(.generate, err)});
                return;
            }
        else
            self.resolveImproveCommitMessageAction() catch |err| {
                self.setStatus("{s}", .{commitMessageActionResolveMessage(.improve, err)});
                return;
            };

        const mode = if (draft_empty)
            app_actions.CommitMessageAssistMode.generate
        else
            app_actions.CommitMessageAssistMode{ .improve = self.buildDraftSnapshot(ctx.allocator()) catch |err| {
                panel.commit_error = .input_allocation_failed;
                self.setStatus("could not snapshot commit message draft: {s}", .{@errorName(err)});
                return err;
            } };

        var request = self.buildCommitMessageAssistRequest(ctx.allocator(), repo_root, action, mode) catch |err| {
            panel.commit_error = .input_allocation_failed;
            self.setStatus("could not prepare commit message action: {s}", .{@errorName(err)});
            return err;
        };

        const prepared = self.lifecycle.prepare(.assist_commit_message);
        app_git_requests.startCommitMessageAssist(
            app_message.Msg,
            ctx,
            prepared.pending,
            &request,
            capability,
            self.env_map,
        ) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            panel.commit_error = .assist_failed;
            self.setStatus("could not start commit message action", .{});
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);

        if (draft_empty) {
            self.setStatus("generating commit message...", .{});
        } else {
            self.setStatus("improving commit message...", .{});
        }
    }

    fn resolveGenerateCommitMessageAction(self: Controller) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        var found: ?config_mod.ExternalActionConfig = null;
        for (self.user_config.actions.slice()) |action| {
            if (action.stdin == .staged_diff) {
                if (found != null) return error.Multiple;
                found = action;
            }
        }
        return found orelse error.Missing;
    }

    fn resolveImproveCommitMessageAction(self: Controller) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        var found: ?config_mod.ExternalActionConfig = null;
        for (self.user_config.actions.slice()) |action| {
            if (action.stdin == .commit_message_context) {
                if (found != null) return error.Multiple;
                found = action;
            }
        }
        return found orelse error.Missing;
    }

    fn buildDraftSnapshot(self: Controller, allocator: std.mem.Allocator) !app_actions.DraftSnapshot {
        var parts = try self.state.commit_panel.formatMessageParts(allocator);
        errdefer parts.deinit(allocator);
        const body = if (parts.body) |body_text| body_text else try allocator.dupe(u8, "");
        parts.body = null;
        return .{ .subject = parts.subject, .body = body };
    }

    fn buildCommitMessageAssistRequest(
        self: Controller,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
        action: config_mod.ExternalActionConfig,
        mode: app_actions.CommitMessageAssistMode,
    ) !app_git_requests.CommitMessageAssistRequest {
        var owned_mode = mode;
        errdefer owned_mode.deinit(allocator);
        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);
        const owned_id = try allocator.dupe(u8, action.id);
        errdefer allocator.free(owned_id);

        const argv_src = action.argvSlice();
        var argv = try allocator.alloc([]u8, argv_src.len);
        errdefer allocator.free(argv);
        var owned_count: usize = 0;
        errdefer for (argv[0..owned_count]) |arg| allocator.free(arg);
        for (argv_src, 0..) |arg, index| {
            argv[index] = try expandCommitActionArgv(allocator, arg, repo_root);
            owned_count += 1;
        }

        return .{
            .repo_root = owned_root,
            .action_id = owned_id,
            .argv = argv,
            .launch_revision = self.state.commit_panel.draft_revision,
            .mode = owned_mode,
        };
    }

    fn startCommitTask(self: Controller, ctx: *chasen.Ctx(app_message.Msg), repo_root: []const u8) !void {
        const panel = &self.state.commit_panel;
        var parts = panel.formatMessageParts(ctx.allocator()) catch {
            panel.commit_error = .input_allocation_failed;
            return;
        };
        errdefer parts.deinit(ctx.allocator());

        const owned_root = try ctx.allocator().dupe(u8, repo_root);
        var request: app_git_requests.CommitRequest = .{
            .repo_root = owned_root,
            .subject = parts.subject,
            .body = parts.body,
        };
        defer request.deinit(ctx.allocator());
        parts = .{ .subject = &.{}, .body = null };

        const prepared = self.lifecycle.prepare(.commit);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            panel.commit_error = .commit_failed;
            self.setStatus("commit unavailable: repository authority changed", .{});
            return;
        };
        app_git_requests.startCommit(app_message.Msg, ctx, prepared.pending, &request, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            panel.commit_error = .commit_failed;
            self.setStatus("could not start commit task", .{});
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);
        self.setStatus("committing...", .{});
    }

    fn openAmendConfirmation(self: Controller, allocator: std.mem.Allocator, repo_root: []const u8) !void {
        const panel = &self.state.commit_panel;
        var parts = panel.formatMessageParts(allocator) catch {
            panel.commit_error = .input_allocation_failed;
            return;
        };
        errdefer parts.deinit(allocator);

        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);

        self.cancelConfirmations(allocator);
        self.state.amend_confirmation = .{
            .repo_root = owned_root,
            .subject = parts.subject,
            .body = parts.body,
        };
        parts = .{ .subject = &.{}, .body = null };
        self.operations.navigation.clearDiffSelection();
        self.overlay.openAmendCommit();
    }

    pub fn confirmAmend(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.lifecycle.view().hasPending()) {
            self.setStatus("another git action is running", .{});
            return;
        }
        var confirmation = self.state.amend_confirmation orelse return;
        self.state.amend_confirmation = null;

        const prepared = self.lifecycle.prepare(.amend);
        const capability = self.repo.activeCapability() orelse {
            self.lifecycle.rejectSpawn(prepared);
            if (self.overlay.isAmendCommit()) self.overlay.close();
            self.state.commit_panel.commit_error = .amend_failed;
            self.setStatus("amend unavailable: repository authority changed", .{});
            confirmation.deinit(ctx.allocator());
            return;
        };
        app_git_requests.startAmend(app_message.Msg, ctx, prepared.pending, &confirmation, capability, self.env_map) catch |err| {
            self.lifecycle.rejectSpawn(prepared);
            if (self.overlay.isAmendCommit()) self.overlay.close();
            self.state.commit_panel.commit_error = .amend_failed;
            self.setStatus("could not start amend task", .{});
            return err;
        };
        _ = self.lifecycle.acceptSpawn(ctx.allocator(), prepared);

        self.overlay.close();
        self.setStatus("amending...", .{});
    }

    pub fn cancelDiscardConfirmation(self: Controller, allocator: std.mem.Allocator) void {
        if (self.state.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.state.discard_confirmation = null;
        if (self.overlay.isDiscardFile()) self.overlay.close();
    }

    pub fn cancelAmendConfirmation(self: Controller, allocator: std.mem.Allocator) void {
        if (self.state.amend_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.state.amend_confirmation = null;
        if (self.overlay.isAmendCommit()) self.overlay.close();
    }

    pub fn cancelConfirmations(self: Controller, allocator: std.mem.Allocator) void {
        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
    }

    pub fn finishStageFile(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.StageFileFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        if (self.setActionFailureStatus("stage", result.result)) {
            self.lifecycle.clearMatchingActionCursor(allocator, result.pending.generation);
            return null;
        }

        self.setStatus("staged: {s}", .{result.path});
        const applied = self.operations.applyAcceptedOutcome(allocator, .stage_file, terminal.active_matches);
        return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
    }

    pub fn finishStageHunk(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.StageHunkFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        if (self.setActionFailureStatus("hunk stage", result.result)) {
            self.lifecycle.clearMatchingActionCursor(allocator, result.pending.generation);
            return null;
        }

        const applied = self.operations.applyAcceptedOutcome(allocator, .{ .stage_hunk = .{
            .repo_root = result.repo_root,
            .path = result.path,
            .hunk_index = result.hunk_index,
            .session_mark_mutation = result.session_mark_mutation,
        } }, terminal.active_matches);
        if (applied.local_effect_failure == .staged_hunk_mark_record) {
            self.setStatus("staged hunk {d}: {s}; could not record local staged-hunk mark", .{ result.hunk_index + 1, result.path });
        } else {
            self.setStatus("staged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
        }
        return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
    }

    pub fn finishUnstageFile(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.UnstageFileFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        if (self.setActionFailureStatus("unstage", result.result)) {
            self.lifecycle.clearMatchingActionCursor(allocator, result.pending.generation);
            return null;
        }

        self.setStatus("unstaged: {s}", .{result.path});
        const applied = self.operations.applyAcceptedOutcome(allocator, .unstage_file, terminal.active_matches);
        return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
    }

    pub fn finishUnstageHunk(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.UnstageHunkFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        if (self.setActionFailureStatus("hunk unstage", result.result)) {
            self.lifecycle.clearMatchingActionCursor(allocator, result.pending.generation);
            return null;
        }

        self.setStatus("unstaged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
        const applied = self.operations.applyAcceptedOutcome(allocator, .{ .unstage_hunk = .{
            .repo_root = result.repo_root,
            .path = result.path,
            .hunk_index = result.hunk_index,
            .session_mark_mutation = result.session_mark_mutation,
            .reload_after_success = result.reload_after_success,
        } }, terminal.active_matches);
        return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
    }

    pub fn finishDiscardFile(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.DiscardFileFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        if (self.setActionFailureStatus("discard", result.result)) {
            self.lifecycle.clearMatchingActionCursor(allocator, result.pending.generation);
            return null;
        }

        const applied = self.operations.applyAcceptedOutcome(allocator, .{ .discard_file = .{
            .repo_root = result.repo_root,
            .path = result.path,
        } }, terminal.active_matches);
        if (applied.local_effect_failure == .reviewed_mark_clear) {
            self.setStatus("discarded: {s}; could not clear reviewed mark", .{result.path});
        } else {
            self.setStatus("discarded: {s}", .{result.path});
        }
        return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
    }

    pub fn finishCommit(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.CommitFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        switch (result.result) {
            .ok => {
                const applied = self.operations.applyAcceptedOutcome(
                    allocator,
                    .{ .commit = .{ .repo_root = result.repo_root } },
                    terminal.active_matches,
                );
                self.state.commit_panel.close();
                if (terminal.active_matches) {
                    if (applied.local_effect_failure == .reviewed_mark_clear) {
                        self.setStatus("committed; could not clear reviewed marks", .{});
                    } else {
                        self.setStatus("committed", .{});
                    }
                } else if (applied.local_effect_failure == .reviewed_mark_clear) {
                    self.setStatus("committed: {s}; could not clear reviewed marks", .{result.repo_root});
                } else {
                    self.setStatus("committed: {s}", .{result.repo_root});
                }
                return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
            },
            .failed, .failed_static => {
                self.state.commit_panel.commit_error = .commit_failed;
                _ = self.setActionFailureStatus("commit", result.result);
                return null;
            },
        }
    }

    pub fn finishCommitMessageAssist(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.CommitMessageAssistFinished,
    ) void {
        var result = finished;
        defer result.deinit(allocator);

        if (self.acceptTerminal(allocator, result.pending, result.repo_root) == null) return;
        const panel = &self.state.commit_panel;
        if (!panel.is_open or panel.mode != .commit) return;
        if (!self.repo.activeRootMatches(result.repo_root)) return;

        switch (result.result) {
            .ok => |message| {
                if (panel.draft_revision != result.launch_revision) {
                    switch (result.mode) {
                        .generate => self.setStatus("generated commit message ignored; draft changed", .{}),
                        .improve => self.setStatus("improved commit message ignored; draft changed", .{}),
                    }
                    return;
                }
                panel.replaceDraft(message.subject, message.body);
                if (panel.commit_error) |_| {
                    self.setStatus("commit message could not be inserted", .{});
                    return;
                }
                switch (result.mode) {
                    .generate => if (message.truncated)
                        self.setStatus("generated commit message from truncated staged diff", .{})
                    else
                        self.setStatus("generated commit message", .{}),
                    .improve => if (message.truncated)
                        self.setStatus("improved commit message from truncated staged diff", .{})
                    else
                        self.setStatus("improved commit message", .{}),
                }
            },
            .failed => |message| {
                panel.commit_error = .assist_failed;
                self.setStatus("{s}", .{message});
            },
            .failed_static => |message| {
                panel.commit_error = .assist_failed;
                self.setStatus("{s}", .{message});
            },
        }
    }

    pub fn finishAmend(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_actions.AmendFinished,
    ) ?ActionReloadIntent {
        var result = finished;
        defer result.deinit(allocator);

        const terminal = self.acceptTerminal(allocator, result.pending, result.repo_root) orelse return null;
        switch (result.result) {
            .ok => {
                const applied = self.operations.applyAcceptedOutcome(
                    allocator,
                    .{ .commit = .{ .repo_root = result.repo_root } },
                    terminal.active_matches,
                );
                self.state.commit_panel.close();
                self.cancelAmendConfirmation(allocator);
                if (terminal.active_matches) {
                    if (applied.local_effect_failure == .reviewed_mark_clear) {
                        self.setStatus("amended; could not clear reviewed marks", .{});
                    } else {
                        self.setStatus("amended", .{});
                    }
                } else if (applied.local_effect_failure == .reviewed_mark_clear) {
                    self.setStatus("amended: {s}; could not clear reviewed marks", .{result.repo_root});
                } else {
                    self.setStatus("amended: {s}", .{result.repo_root});
                }
                return self.reloadIntent(result.pending, terminal.active_matches, applied.reload);
            },
            .failed, .failed_static => {
                self.state.commit_panel.commit_error = .amend_failed;
                _ = self.setActionFailureStatus("amend", result.result);
                return null;
            },
        }
    }

    const AcceptedTerminal = struct {
        active_matches: bool,
    };

    fn acceptTerminal(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
        repo_root: []const u8,
    ) ?AcceptedTerminal {
        const admission = self.lifecycle.finishExact(
            allocator,
            pending,
            repo_root,
            self.current_changes_root,
        );
        return switch (admission) {
            .rejected => null,
            .accepted => |accepted| .{ .active_matches = accepted.target == .current_changes },
        };
    }

    fn reloadIntent(
        self: Controller,
        pending: app_actions.PendingAction,
        active_matches: bool,
        reload: changes_action_fence.ReloadIntent,
    ) ActionReloadIntent {
        return .{
            .pending = pending,
            .active_matches = active_matches,
            .reload = switch (reload) {
                .status => .{ .status = self.repo.activeRoot() orelse
                    @panic("current Changes status reload requires an active repository") },
                else => reload,
            },
        };
    }

    fn setActionFailureStatus(
        self: Controller,
        comptime prefix: []const u8,
        result: app_actions.FileActionTaskResult,
    ) bool {
        switch (result) {
            .ok => return false,
            .failed => |message| self.setStatus(prefix ++ " failed: {s}", .{git_ops.trimGitOutput(message)}),
            .failed_static => |message| self.setStatus(prefix ++ " failed: {s}", .{message}),
        }
        return true;
    }
};

const CommitMessageActionResolveError = error{
    Missing,
    Multiple,
};

const CommitMessageAssistResolveMode = enum { generate, improve };

fn commitMessageActionResolveMessage(
    mode: CommitMessageAssistResolveMode,
    err: CommitMessageActionResolveError,
) []const u8 {
    return switch (err) {
        error.Missing => switch (mode) {
            .generate => "commit message action is not configured",
            .improve => "commit message improve action is not configured",
        },
        error.Multiple => switch (mode) {
            .generate => "multiple commit message actions configured",
            .improve => "multiple commit message improve actions configured",
        },
    };
}

fn expandCommitActionArgv(
    allocator: std.mem.Allocator,
    template: []const u8,
    repo_root: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, template, cursor, '{')) |open| {
        try out.writer.writeAll(template[cursor..open]);
        const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}') orelse
            return error.UnknownPlaceholder;
        const placeholder = template[open .. close + 1];
        if (!std.mem.eql(u8, placeholder, "{repo_root}")) return error.UnknownPlaceholder;
        try out.writer.writeAll(repo_root);
        cursor = close + 1;
    }
    if (std.mem.indexOfScalarPos(u8, template, cursor, '}') != null) return error.UnknownPlaceholder;
    try out.writer.writeAll(template[cursor..]);
    return try out.toOwnedSlice();
}

fn actionCursorKind(kind: git_ops.TargetKind) @import("../pages/changes/action_cursor.zig").TargetKind {
    return switch (kind) {
        .repository => .repository_root,
        .directory => .directory,
        .file => .file,
    };
}

pub const testing = if (builtin.is_test) struct {
    pub fn actionCursorKindForTest(
        kind: git_ops.TargetKind,
    ) @import("../pages/changes/action_cursor.zig").TargetKind {
        return actionCursorKind(kind);
    }

    pub fn openAmendConfirmation(
        controller: Controller,
        allocator: std.mem.Allocator,
        repo_root: []const u8,
    ) !void {
        try controller.openAmendConfirmation(allocator, repo_root);
    }

    pub fn buildDraftSnapshot(
        controller: Controller,
        allocator: std.mem.Allocator,
    ) !app_actions.DraftSnapshot {
        return controller.buildDraftSnapshot(allocator);
    }

    pub fn resolveGenerateCommitMessageAction(
        controller: Controller,
    ) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        return controller.resolveGenerateCommitMessageAction();
    }

    pub fn resolveImproveCommitMessageAction(
        controller: Controller,
    ) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        return controller.resolveImproveCommitMessageAction();
    }
} else struct {};
