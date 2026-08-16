//! Sole owner of the active repository identity and repository-selection
//! session state. Controllers borrow this state only for one synchronous
//! application dispatch.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const app_message = @import("message.zig");
const app_state = @import("state.zig");
const config = @import("../config.zig");
const diff_source = @import("../diff/source.zig");
const git_command = @import("../git/command.zig");
const git_ops = @import("git_ops.zig");
const load = @import("load.zig");
const page = @import("page.zig");
const prompt = @import("prompt.zig");
const repo_picker = @import("repo_picker.zig");
const changes_repository_session = @import("pages/changes/repository_session.zig");
const changes_navigation = if (builtin.is_test) @import("pages/changes/navigation.zig") else struct {};
const changes_page = if (builtin.is_test) @import("pages/changes.zig") else struct {};
const changes_reload = if (builtin.is_test) @import("pages/changes/reload.zig") else struct {};
const review_page = @import("pages/review.zig");
const repository_page = @import("pages/repository.zig");
const discovery = @import("../repo/discovery.zig");
const root_capability = @import("../repo/root_capability.zig");
const repo_state = @import("../repo/state.zig");
const remote_state = @import("workflow/remote_state.zig");

const PendingRecentPathDiscovery = struct {
    kind: repo_state.RecentKind,
    index: usize,
};

pub const CommitOrigin = enum {
    discovery_completion,
    external_selection,
};

pub const CommitOutcome = enum {
    unchanged,
    changed,
    rejected,
};

const PreparedDiscovery = struct {
    result: ?discovery.DiscoveryResult,
    candidate: ?root_capability.RootCapability,
    active_index: usize,
    origin: CommitOrigin,
    changed: bool,

    fn deinit(self: *PreparedDiscovery, allocator: std.mem.Allocator) void {
        if (self.result) |*result| result.deinit(allocator);
        if (self.candidate) |*candidate| candidate.deinit();
        self.* = undefined;
    }
};

const PreparedWorkspace = struct {
    candidate: ?root_capability.RootCapability,
    active_index: usize,
    changed: bool,

    fn deinit(self: *PreparedWorkspace) void {
        if (self.candidate) |*candidate| candidate.deinit();
        self.* = undefined;
    }
};

pub const State = struct {
    repo_epoch: u64 = 0,
    state_path: ?[]const u8 = null,
    repo_picker: prompt.RepoPickerState = .{},
    /// Workspace discovered from path input but not yet selected.
    repo_picker_discovery: ?discovery.DiscoveryResult = null,
    repo_picker_items: repo_picker.ItemList = .empty,
    recent_repos: repo_state.RecentStore = .{},
    pending_repo_path_recent_source: ?PendingRecentPathDiscovery = null,
    repo_state: repo_state.State = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.repo_state.deinit(allocator);
        self.repo_picker.deinit(allocator);
        if (self.repo_picker_discovery) |*owned| owned.deinit(allocator);
        self.repo_picker_discovery = null;
        repo_picker.deinitItems(&self.repo_picker_items, allocator);
        self.recent_repos.deinit(allocator);
        self.pending_repo_path_recent_source = null;
    }

    pub fn view(self: *const State) View {
        return View.init(self);
    }

    fn clearPickerItems(self: *State, allocator: std.mem.Allocator) void {
        repo_picker.clearItems(&self.repo_picker_items, allocator);
    }

    fn clearPickerDiscovery(self: *State, allocator: std.mem.Allocator) void {
        if (self.repo_picker_discovery) |*owned| owned.deinit(allocator);
        self.repo_picker_discovery = null;
    }
};

pub const PickerView = struct {
    model: *const prompt.RepoPickerState,
    pending_workspace_root: ?[]const u8,
    items: []const repo_picker.Item,
    has_recent: bool,
    committed_discovery_kind: repo_picker.DiscoveryKind,
    active_index: usize,
};

pub const View = struct {
    epoch_value: u64,
    active_root: ?[]const u8,
    active_identity: ?root_capability.Identity,
    active_capability: ?*const root_capability.RootCapability,
    has_workspace: bool,
    needs_discovery: bool,
    picker_view: PickerView,

    fn init(state: *const State) View {
        return .{
            .epoch_value = state.repo_epoch,
            .active_root = state.repo_state.activeRoot(),
            .active_identity = state.repo_state.activeIdentity(),
            .active_capability = state.repo_state.activeCapability(),
            .has_workspace = state.repo_state.workspaceRepos() != null,
            .needs_discovery = state.repo_state.needsDiscovery(),
            .picker_view = .{
                .model = &state.repo_picker,
                .pending_workspace_root = pendingWorkspaceRoot(state.repo_picker_discovery),
                .items = state.repo_picker_items.items,
                .has_recent = state.recent_repos.entries.items.len > 0,
                .committed_discovery_kind = repo_picker.discoveryKind(state.repo_state.discovery),
                .active_index = state.repo_state.active_index,
            },
        };
    }

    pub fn epoch(self: View) u64 {
        return self.epoch_value;
    }

    pub fn activeRoot(self: View) ?[]const u8 {
        return self.active_root;
    }

    pub fn activeIdentity(self: View) ?root_capability.Identity {
        return self.active_identity;
    }

    pub fn activeCapability(self: View) ?*const root_capability.RootCapability {
        return self.active_capability;
    }

    pub fn hasWorkspace(self: View) bool {
        return self.has_workspace;
    }

    pub fn needsDiscovery(self: View) bool {
        return self.needs_discovery;
    }

    pub fn picker(self: View) PickerView {
        return self.picker_view;
    }

    pub fn rootForSource(self: View, source: diff_source.SourceMode) error{MissingRepoRoot}!?[]const u8 {
        if (!diff_source.sourceRequiresRepo(source)) return null;
        return self.activeRoot() orelse error.MissingRepoRoot;
    }

    pub fn activeRootMatches(self: View, root: []const u8) bool {
        const active = self.activeRoot() orelse return false;
        return std.mem.eql(u8, active, root);
    }
};

const RepoPathDiscoveryTask = load.RepoPathDiscoveryTask(app_message.Msg);
const RepoPathDiscoveryFinished = load.RepoPathDiscoveryFinished;

/// Narrow Repository capability used only to invalidate an identity after a
/// replacement has passed capability preflight.
pub const RepositoryInvalidationPort = struct {
    page: *repository_page.RepositoryPageState,

    fn invalidateBeforeReplacement(
        self: RepositoryInvalidationPort,
        allocator: std.mem.Allocator,
        next_epoch: u64,
        identity: ?root_capability.Identity,
    ) void {
        self.page.repositoryChanged(allocator, next_epoch, identity);
    }
};

/// Narrow Review capability used only to discard state tied to the old repo.
pub const ReviewInvalidationPort = struct {
    page: *review_page.ReviewPageState,

    fn invalidateBeforeReplacement(self: ReviewInvalidationPort, allocator: std.mem.Allocator) void {
        self.page.deinit(allocator);
    }
};

pub const Controller = struct {
    state: *State,
    status: *app_state.StatusMessage,
    active_page: page.Id,
    source: diff_source.SourceMode,
    home: ?[]const u8,
    env_map: ?*const std.process.Environ.Map = null,
    action_pending: bool,
    changes: changes_repository_session.Controller,
    repository: RepositoryInvalidationPort,
    review: ReviewInvalidationPort,
    shell: remote_state.RepositoryInvalidationPort,

    fn view(self: Controller) View {
        return self.state.view();
    }

    /// Commits repository identity only after the root capability preflight
    /// succeeds. Old reads and page state are invalidated before the epoch and
    /// active identity advance.
    fn commitDiscovery(
        self: Controller,
        allocator: std.mem.Allocator,
        result: discovery.DiscoveryResult,
        active_index: usize,
        origin: CommitOrigin,
    ) CommitOutcome {
        var prepared = self.prepareDiscovery(allocator, result, active_index, origin) orelse return .rejected;
        defer prepared.deinit(allocator);
        return self.commitPreparedDiscovery(allocator, &prepared);
    }

    pub fn commitDiscovered(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: discovery.DiscoveryResult,
        active_index: usize,
        origin: CommitOrigin,
    ) !CommitOutcome {
        var prepared = self.prepareDiscovery(ctx.allocator(), result, active_index, origin) orelse return .rejected;
        defer prepared.deinit(ctx.allocator());
        try self.state.recent_repos.rememberDiscovery(ctx.allocator(), prepared.result.?);
        self.persistRecent(ctx);
        return self.commitPreparedDiscovery(ctx.allocator(), &prepared);
    }

    fn prepareDiscovery(
        self: Controller,
        allocator: std.mem.Allocator,
        result: discovery.DiscoveryResult,
        active_index: usize,
        origin: CommitOrigin,
    ) ?PreparedDiscovery {
        if (!validDiscoveryIndex(result, active_index)) {
            var rejected = result;
            rejected.deinit(allocator);
            return null;
        }
        const proposed_root = discoveryRootAt(result, active_index);
        const candidate: ?root_capability.RootCapability = if (proposed_root) |root|
            root_capability.RootCapability.openCanonical(root) catch {
                var rejected = result;
                rejected.deinit(allocator);
                return null;
            }
        else
            null;
        const changed = !sameIdentity(
            self.view().activeRoot(),
            self.view().activeIdentity(),
            proposed_root,
            if (candidate) |root| root.identity else null,
        );
        return .{
            .result = result,
            .candidate = candidate,
            .active_index = active_index,
            .origin = origin,
            .changed = changed,
        };
    }

    fn commitPreparedDiscovery(
        self: Controller,
        allocator: std.mem.Allocator,
        prepared: *PreparedDiscovery,
    ) CommitOutcome {
        const changed = prepared.changed;
        const origin = prepared.origin;
        if (changed) self.changes.supersedeReads(allocator);
        if (!changed and origin == .external_selection) {
            self.changes.supersedeRepositoryDiscovery();
            self.finishUnchangedExplicitSelection(allocator);
        }
        if (changed) {
            const next_epoch = nextEpoch(self.state.repo_epoch);
            self.shell.invalidateBeforeRepositoryReplacement(allocator);
            self.changes.invalidateBeforeReplacement(allocator);
            self.review.invalidateBeforeReplacement(allocator);
            self.repository.invalidateBeforeReplacement(
                allocator,
                next_epoch,
                if (prepared.candidate) |root| root.identity else null,
            );
            self.state.repo_epoch = next_epoch;
        }
        const result = prepared.result.?;
        prepared.result = null;
        if (changed) {
            const committed_root = prepared.candidate;
            prepared.candidate = null;
            self.state.repo_state.replaceCommitted(allocator, result, prepared.active_index, committed_root);
        } else {
            if (prepared.candidate) |*root| root.deinit();
            prepared.candidate = null;
            self.state.repo_state.replaceDiscoveryKeepingRoot(allocator, result, prepared.active_index);
        }
        if (changed) self.changes.commitIdentity(
            self.source,
            self.state.repo_epoch,
            self.active_page == .changes,
            self.view().activeRoot() != null,
        );
        return if (changed) .changed else .unchanged;
    }

    fn commitWorkspaceIndex(
        self: Controller,
        allocator: std.mem.Allocator,
        active_index: usize,
    ) CommitOutcome {
        var prepared = self.prepareWorkspace(active_index) orelse return .rejected;
        defer prepared.deinit();
        return self.commitPreparedWorkspace(allocator, &prepared);
    }

    fn commitWorkspaceIndexRemembering(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        active_index: usize,
    ) !CommitOutcome {
        var prepared = self.prepareWorkspace(active_index) orelse return .rejected;
        defer prepared.deinit();
        const repos = self.state.repo_state.workspaceRepos() orelse return .rejected;
        try self.state.recent_repos.rememberRepo(ctx.allocator(), repos[active_index].canonical_root);
        self.persistRecent(ctx);
        return self.commitPreparedWorkspace(ctx.allocator(), &prepared);
    }

    fn prepareWorkspace(self: Controller, active_index: usize) ?PreparedWorkspace {
        const repos = self.state.repo_state.workspaceRepos() orelse return null;
        if (active_index >= repos.len) {
            return null;
        }
        const new_root = repos[active_index].canonical_root;
        const candidate = root_capability.RootCapability.openCanonical(new_root) catch return null;
        const changed = !sameIdentity(
            self.view().activeRoot(),
            self.view().activeIdentity(),
            new_root,
            candidate.identity,
        );
        return .{ .candidate = candidate, .active_index = active_index, .changed = changed };
    }

    fn commitPreparedWorkspace(
        self: Controller,
        allocator: std.mem.Allocator,
        prepared: *PreparedWorkspace,
    ) CommitOutcome {
        const changed = prepared.changed;
        if (changed) self.changes.supersedeReads(allocator);
        if (!changed) {
            self.changes.supersedeRepositoryDiscovery();
            self.finishUnchangedExplicitSelection(allocator);
        }
        if (changed) {
            const next_epoch = nextEpoch(self.state.repo_epoch);
            self.shell.invalidateBeforeRepositoryReplacement(allocator);
            self.changes.invalidateBeforeReplacement(allocator);
            self.review.invalidateBeforeReplacement(allocator);
            self.repository.invalidateBeforeReplacement(allocator, next_epoch, prepared.candidate.?.identity);
            self.state.repo_epoch = next_epoch;
            const committed = prepared.candidate.?;
            prepared.candidate = null;
            self.state.repo_state.selectWorkspaceRoot(prepared.active_index, committed);
            self.changes.commitIdentity(
                self.source,
                self.state.repo_epoch,
                self.active_page == .changes,
                self.view().activeRoot() != null,
            );
        } else {
            prepared.candidate.?.deinit();
            prepared.candidate = null;
            self.state.repo_state.selectWorkspaceIndexKeepingRoot(prepared.active_index);
        }
        return if (changed) .changed else .unchanged;
    }

    pub fn enterPicker(self: Controller, allocator: std.mem.Allocator) !void {
        if (self.action_pending) {
            self.setStatus("finish current git action before switching repos", .{});
            return;
        }
        self.shell.clearBranchSwitch(allocator);
        if (self.active_page == .changes) self.changes.clearDiffSelection();
        try self.refreshPickerFilterWith(allocator, null, &self.state.recent_repos, "");
        self.state.repo_picker.mode = true;
        self.state.repo_picker.input_mode = .list;
        self.state.repo_picker.list.mode = true;
        self.state.repo_picker.list.input = .{};
        self.state.repo_picker.path_input = .{};
        self.state.repo_picker.list.resetNoMatch();
        self.state.repo_picker.clearPathStatus();
        self.state.clearPickerDiscovery(allocator);
        self.focusPickerOnActive();
    }

    pub fn cancelPicker(self: Controller, allocator: std.mem.Allocator) !void {
        switch (self.state.repo_picker.input_mode) {
            .list => {},
            .filter => {
                try self.refreshPickerFilterWith(allocator, self.state.repo_picker_discovery, &self.state.recent_repos, "");
                self.state.repo_picker.input_mode = .list;
                self.state.repo_picker.list.input = .{};
                self.state.repo_picker.list.resetNoMatch();
                self.focusPickerOnActive();
                return;
            },
            .path_input => {
                self.state.repo_picker.input_mode = .list;
                self.state.repo_picker.invalidatePathDiscovery();
                self.state.pending_repo_path_recent_source = null;
                self.state.repo_picker.list.resetNoMatch();
                return;
            },
        }
        if (self.state.repo_picker_discovery != null) {
            try self.refreshPickerFilterWith(allocator, null, &self.state.recent_repos, "");
            self.state.clearPickerDiscovery(allocator);
            self.focusPickerOnActive();
            return;
        }
        self.closePicker(allocator);
    }

    pub fn closePicker(self: Controller, allocator: std.mem.Allocator) void {
        self.state.repo_picker.deinit(allocator);
        self.state.pending_repo_path_recent_source = null;
        self.state.clearPickerDiscovery(allocator);
        self.state.clearPickerItems(allocator);
    }

    pub fn submitPicker(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !?CommitOutcome {
        if (self.state.repo_picker.input_mode == .path_input) {
            try self.submitPickerPath(ctx);
            return null;
        }
        const source = repo_picker.resolveSelection(
            &self.state.repo_picker,
            self.state.repo_picker_items.items,
        ) orelse {
            self.state.repo_picker.list.no_match = true;
            return null;
        };
        switch (source) {
            .active_repo => {
                self.closePickerAfterSelection(ctx.allocator());
                return null;
            },
            .workspace_repo => |repo_index| {
                const repos = self.state.repo_state.workspaceRepos() orelse return null;
                if (repo_index >= repos.len) {
                    self.state.repo_picker.list.no_match = true;
                    return null;
                }
                const outcome = try self.commitWorkspaceIndexRemembering(ctx, repo_index);
                self.closePickerAfterSelection(ctx.allocator());
                return outcome;
            },
            .pending_workspace_repo => |repo_index| return try self.acceptPendingWorkspace(ctx, repo_index),
            .recent_repo => |recent_index| {
                if (recent_index >= self.state.recent_repos.entries.items.len) return null;
                try self.startPathDiscovery(ctx, self.state.recent_repos.entries.items[recent_index].path, .{
                    .kind = .repo,
                    .index = recent_index,
                });
                return null;
            },
            .recent_workspace => |recent_index| {
                if (recent_index >= self.state.recent_repos.entries.items.len) return null;
                try self.startPathDiscovery(ctx, self.state.recent_repos.entries.items[recent_index].path, .{
                    .kind = .workspace,
                    .index = recent_index,
                });
                return null;
            },
        }
    }

    pub fn enterPickerFilterInput(self: Controller, allocator: std.mem.Allocator) !void {
        if (!self.state.repo_picker.mode) return;
        self.state.repo_picker.input_mode = .filter;
        self.state.repo_picker.list.resetNoMatch();
        try self.refreshPickerFilter(allocator);
    }

    pub fn enterPickerPathInput(self: Controller) void {
        if (!self.state.repo_picker.mode) return;
        self.state.repo_picker.input_mode = .path_input;
        self.state.repo_picker.invalidatePathDiscovery();
        self.state.pending_repo_path_recent_source = null;
    }

    pub fn insertPickerCodepoint(self: Controller, allocator: std.mem.Allocator, codepoint: u21) !void {
        try self.applyPickerEdit(allocator, repo_picker.insertCodepoint(&self.state.repo_picker, codepoint));
    }

    pub fn insertPickerSlice(self: Controller, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.applyPickerEdit(allocator, repo_picker.insertSlice(&self.state.repo_picker, text));
    }

    pub fn backspacePicker(self: Controller, allocator: std.mem.Allocator) !void {
        try self.applyPickerEdit(allocator, repo_picker.backspace(&self.state.repo_picker));
    }

    pub fn movePickerCursorLeft(self: Controller) void {
        repo_picker.moveLeft(&self.state.repo_picker);
    }

    pub fn movePickerCursorRight(self: Controller) void {
        repo_picker.moveRight(&self.state.repo_picker);
    }

    pub fn movePickerPrevious(self: Controller) void {
        self.state.repo_picker.list.filter.update(.move_prev);
    }

    pub fn movePickerNext(self: Controller) void {
        self.state.repo_picker.list.filter.update(.move_next);
    }

    pub fn backPicker(self: Controller, allocator: std.mem.Allocator) !void {
        if (self.state.repo_picker.input_mode != .list) {
            try self.cancelPicker(allocator);
            return;
        }
        if (self.state.repo_picker_discovery != null) {
            try self.refreshPickerFilterWith(allocator, null, &self.state.recent_repos, "");
            self.state.clearPickerDiscovery(allocator);
            self.focusPickerOnActive();
        }
    }

    pub fn removeSelectedRecent(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        if (!self.state.repo_picker.mode or self.state.repo_picker.input_mode != .list) return;
        const item = repo_picker.selectedItem(
            &self.state.repo_picker,
            self.state.repo_picker_items.items,
        ) orelse return;
        const recent = recentSourceIdentity(item.source) orelse {
            self.setStatus("only recent repositories can be removed", .{});
            return;
        };
        if (!self.state.recent_repos.entryMatches(recent.index, recent.kind, item.detail)) {
            self.setStatus("recent repository changed; refresh and try again", .{});
            return;
        }
        const focused = self.state.repo_picker.list.filter.list.focusedIndex();
        var next = (try self.state.recent_repos.prepareRemoval(
            ctx.allocator(),
            recent.index,
            recent.kind,
            item.detail,
        )) orelse return;
        defer next.deinit(ctx.allocator());
        try self.installPreparedRecent(ctx, &next);
        repo_picker.focusVisibleIndex(&self.state.repo_picker, focused);
        self.state.repo_picker.clearPathStatus();
        self.setStatus("removed recent repository", .{});
    }

    pub fn finishPathDiscovery(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        finished: RepoPathDiscoveryFinished,
    ) !?CommitOutcome {
        var result = finished;
        defer result.deinit(ctx.allocator());
        if (!self.state.repo_picker.finishPathDiscovery(result.generation)) return null;
        if (!self.state.repo_picker.isCurrentPathDiscovery(result.generation)) return null;
        return switch (result.result) {
            .empty => unreachable,
            .discovered => |owned| blk: {
                self.state.pending_repo_path_recent_source = null;
                result.result = .empty;
                break :blk try self.acceptPathDiscovery(ctx, owned);
            },
            .input_error => |err| blk: {
                if (try self.removeStaleRecentAfterPathError(ctx, err, result.submitted_path)) break :blk null;
                self.state.pending_repo_path_recent_source = null;
                self.state.repo_picker.path_error = prompt.repoPickerPathErrorFromDiscovery(err);
                break :blk null;
            },
            .failed => |message| blk: {
                self.state.pending_repo_path_recent_source = null;
                self.setStatus("repo path discovery failed: {s}", .{git_ops.trimGitOutput(message)});
                break :blk null;
            },
            .failed_static => |message| blk: {
                self.state.pending_repo_path_recent_source = null;
                self.setStatus("repo path discovery failed: {s}", .{message});
                break :blk null;
            },
        };
    }

    fn submitPickerPath(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const path = std.mem.trim(u8, self.state.repo_picker.path_input.slice(), " \t\r\n");
        if (path.len == 0) {
            self.state.repo_picker.path_error = .no_git_repositories_found;
            return;
        }
        try self.startPathDiscovery(ctx, path, null);
    }

    fn startPathDiscovery(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        path: []const u8,
        recent_source: ?PendingRecentPathDiscovery,
    ) !void {
        if (self.action_pending) {
            self.setStatus("finish current git action before switching repos", .{});
            return;
        }
        const task = try ctx.allocator().create(RepoPathDiscoveryTask);
        const owned_path = expandUserPath(ctx.allocator(), path, self.home) catch |err| {
            ctx.allocator().destroy(task);
            return err;
        };
        const environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch |err| {
            ctx.allocator().free(owned_path);
            ctx.allocator().destroy(task);
            return err;
        };
        const generation = self.state.repo_picker.beginPathDiscovery();
        task.* = .{
            .path = owned_path,
            .generation = generation,
            .environment = environment,
        };
        self.state.pending_repo_path_recent_source = recent_source;
        ctx.task().spawnWith(.{
            .ctx = task,
            .run = RepoPathDiscoveryTask.run,
            .failed = RepoPathDiscoveryTask.failed,
        }) catch |err| {
            task.destroy(ctx.allocator());
            _ = self.state.repo_picker.finishPathDiscovery(generation);
            self.state.pending_repo_path_recent_source = null;
            self.setStatus("could not start repo path discovery task", .{});
            return err;
        };
    }

    fn acceptPathDiscovery(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: discovery.DiscoveryResult,
    ) !?CommitOutcome {
        var owned: ?discovery.DiscoveryResult = result;
        errdefer if (owned) |*value| value.deinit(ctx.allocator());
        switch (owned.?) {
            .single_repo => {
                const consumed = owned.?;
                owned = null;
                const outcome = try self.commitDiscovered(ctx, consumed, 0, .external_selection);
                self.state.clearPickerDiscovery(ctx.allocator());
                self.closePickerAfterSelection(ctx.allocator());
                return outcome;
            },
            .workspace => |workspace| {
                var next_recent = try self.state.recent_repos.prepareRememberWorkspace(ctx.allocator(), workspace.current_root);
                defer next_recent.deinit(ctx.allocator());
                try self.refreshPickerFilterWith(ctx.allocator(), owned.?, &next_recent, "");

                var previous_recent = self.state.recent_repos;
                self.state.recent_repos = next_recent;
                next_recent = .{};
                previous_recent.deinit(ctx.allocator());
                self.persistRecent(ctx);
                self.state.clearPickerDiscovery(ctx.allocator());
                self.state.repo_picker_discovery = owned.?;
                owned = null;
                self.state.repo_picker.input_mode = .list;
                self.state.repo_picker.list.mode = true;
                self.state.repo_picker.list.input = .{};
                repo_picker.clearPathInput(&self.state.repo_picker);
                self.state.repo_picker.list.resetNoMatch();
                self.state.repo_picker.clearPathStatus();
                self.focusPickerOnActive();
                return null;
            },
            .none => unreachable,
        }
    }

    fn acceptPendingWorkspace(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_index: usize,
    ) !?CommitOutcome {
        const pending = self.state.repo_picker_discovery orelse return null;
        const workspace = switch (pending) {
            .workspace => |workspace| workspace,
            .single_repo, .none => return null,
        };
        if (repo_index >= workspace.repos.len) {
            self.state.repo_picker.list.no_match = true;
            return null;
        }
        const owned = self.state.repo_picker_discovery orelse unreachable;
        self.state.repo_picker_discovery = null;
        var prepared = self.prepareDiscovery(ctx.allocator(), owned, repo_index, .external_selection) orelse {
            self.closePickerAfterSelection(ctx.allocator());
            return .rejected;
        };
        defer prepared.deinit(ctx.allocator());
        self.state.recent_repos.rememberRepo(ctx.allocator(), workspace.repos[repo_index].canonical_root) catch |err| {
            self.state.repo_picker_discovery = prepared.result.?;
            prepared.result = null;
            return err;
        };
        self.persistRecent(ctx);
        const outcome = self.commitPreparedDiscovery(ctx.allocator(), &prepared);
        self.closePickerAfterSelection(ctx.allocator());
        return outcome;
    }

    fn removeStaleRecentAfterPathError(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        err: discovery.PathDiscoveryError,
        submitted_path: []const u8,
    ) !bool {
        if (!isStaleRecentPathError(err)) return false;
        const pending = self.state.pending_repo_path_recent_source orelse return false;
        self.state.pending_repo_path_recent_source = null;
        const focused = self.state.repo_picker.list.filter.list.focusedIndex();
        var next = (try self.state.recent_repos.prepareRemoval(
            ctx.allocator(),
            pending.index,
            pending.kind,
            submitted_path,
        )) orelse {
            self.state.repo_picker.clearPathStatus();
            return true;
        };
        defer next.deinit(ctx.allocator());
        try self.installPreparedRecent(ctx, &next);
        repo_picker.focusVisibleIndex(&self.state.repo_picker, focused);
        self.state.repo_picker.clearPathStatus();
        self.setStatus("removed stale recent repository", .{});
        return true;
    }

    fn refreshPickerFilter(self: Controller, allocator: std.mem.Allocator) !void {
        const query = if (self.state.repo_picker.input_mode == .filter)
            self.state.repo_picker.list.input.slice()
        else
            "";
        try self.refreshPickerFilterWith(
            allocator,
            self.state.repo_picker_discovery,
            &self.state.recent_repos,
            query,
        );
    }

    fn refreshPickerFilterWith(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: ?discovery.DiscoveryResult,
        recent: *const repo_state.RecentStore,
        query: []const u8,
    ) !void {
        try repo_picker.refreshFilter(
            allocator,
            &self.state.repo_picker,
            &self.state.repo_picker_items,
            pending,
            self.state.repo_state.discovery,
            recent,
            query,
        );
    }

    fn installPreparedRecent(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        next: *repo_state.RecentStore,
    ) !void {
        try self.refreshPickerFilterWith(
            ctx.allocator(),
            self.state.repo_picker_discovery,
            next,
            if (self.state.repo_picker.input_mode == .filter) self.state.repo_picker.list.input.slice() else "",
        );
        var previous = self.state.recent_repos;
        self.state.recent_repos = next.*;
        next.* = .{};
        previous.deinit(ctx.allocator());
        self.persistRecent(ctx);
    }

    fn focusPickerOnActive(self: Controller) void {
        repo_picker.focusOnActive(
            &self.state.repo_picker,
            self.state.repo_picker_items.items,
            self.state.repo_state.active_index,
        );
    }

    fn applyPickerEdit(self: Controller, allocator: std.mem.Allocator, result: repo_picker.EditResult) !void {
        switch (result) {
            .none => {},
            .refresh_filter => try self.refreshPickerFilter(allocator),
            .filter_too_long => self.setStatus("repository filter is too long", .{}),
            .path_changed => {
                if (self.state.repo_picker.path_pending) {
                    self.state.repo_picker.invalidatePathDiscovery();
                    self.state.pending_repo_path_recent_source = null;
                }
                if (self.state.repo_picker_discovery != null) {
                    try self.refreshPickerFilterWith(allocator, null, &self.state.recent_repos, "");
                    self.state.clearPickerDiscovery(allocator);
                    self.focusPickerOnActive();
                }
            },
        }
    }

    fn closePickerAfterSelection(self: Controller, allocator: std.mem.Allocator) void {
        self.state.repo_picker.deinit(allocator);
        self.state.pending_repo_path_recent_source = null;
        self.state.clearPickerItems(allocator);
    }

    fn persistRecent(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) void {
        const path = self.state.state_path orelse return;
        saveRecentRepositoriesState(ctx.io(), path, &self.state.recent_repos) catch {
            self.setStatus("could not save recent repositories", .{});
        };
    }

    fn finishUnchangedExplicitSelection(self: Controller, allocator: std.mem.Allocator) void {
        self.changes.finishUnchangedExplicitSelection(allocator);
        self.shell.clearBranchSwitch(allocator);
    }

    fn setStatus(self: Controller, comptime format: []const u8, args: anytype) void {
        self.status.set(format, args);
    }
};

fn saveRecentRepositoriesState(
    io: std.Io,
    path: []const u8,
    recent_repos: *const repo_state.RecentStore,
) !void {
    const parent = std.fs.path.dirname(path) orelse ".";
    const basename = std.fs.path.basename(path);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    var atomic_file = try dir.createFileAtomic(io, basename, .{ .make_path = false, .replace = true });
    defer atomic_file.deinit(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try writeStateJson(&file_writer.interface, recent_repos);
    try file_writer.flush();
    try atomic_file.replace(io);
}

fn writeStateJson(writer: *std.Io.Writer, recent_repos: *const repo_state.RecentStore) !void {
    var stringify: std.json.Stringify = .{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };
    try stringify.beginObject();
    try stringify.objectField("schema_version");
    try stringify.write(config.supported_schema_version);
    try stringify.objectField("recent_repositories");
    try repo_state.writeRecentRepositoriesJson(recent_repos, &stringify);
    try stringify.endObject();
}

fn expandUserPath(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    const home_path = home orelse return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, home_path);
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(allocator, &.{ home_path, path[2..] });
    return allocator.dupe(u8, path);
}

const RepoSessionTestPages = struct {
    changes: changes_page.ChangesPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    review: review_page.ReviewPageState = .{},
};

/// Exact test assembly for this owner. It mirrors the root's short-lived
/// adapter without importing or retaining the root App.
const RepoSessionTestApp = struct {
    allocator: ?std.mem.Allocator = null,
    env_map: ?*const std.process.Environ.Map = null,
    repo_session: State = .{},
    status: app_state.StatusMessage = .{},
    active_page: page.Id = .changes,
    source: diff_source.SourceMode = .unstaged,
    pages: RepoSessionTestPages = .{},
    remote: remote_state.State = .{},
    overlay: app_state.OverlayState = .{},

    fn repoSessionView(self: *const RepoSessionTestApp) View {
        return self.repo_session.view();
    }

    fn activateChanges(self: *RepoSessionTestApp) u64 {
        return self.pages.changes.activation.activate(
            self.repoSessionView().epoch(),
            .pending,
            .pending,
            .pending,
        );
    }

    fn changesNavigation(self: *RepoSessionTestApp) changes_navigation.Controller {
        const view = self.repoSessionView();
        return .{
            .page = &self.pages.changes,
            .repo_root = view.activeRoot(),
            .repo_epoch = view.epoch(),
            .root_identity = view.activeIdentity(),
            .source = self.source,
            .layout = .{ .width = 80, .height = 20 },
            .diagnostics = .{ .target = &self.pages.changes.status },
        };
    }

    fn changesReload(self: *RepoSessionTestApp) changes_reload.Controller {
        const view = self.repoSessionView();
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .source = self.source,
            .repo_root = view.activeRoot(),
            .repo_epoch = view.epoch(),
            .root_identity = view.activeIdentity(),
        };
    }

    fn repoSession(self: *RepoSessionTestApp) Controller {
        return .{
            .state = &self.repo_session,
            .status = &self.status,
            .active_page = self.active_page,
            .source = self.source,
            .home = null,
            .env_map = self.env_map,
            .action_pending = false,
            .changes = .{
                .page = &self.pages.changes,
                .navigation = self.changesNavigation(),
                .reload = self.changesReload(),
            },
            .repository = .{ .page = &self.pages.repository },
            .review = .{ .page = &self.pages.review },
            .shell = self.remote.repositoryInvalidationPort(&self.overlay),
        };
    }
};

fn testRepoSessionSingleDiscovery(allocator: std.mem.Allocator, root: []const u8) !discovery.DiscoveryResult {
    return .{ .single_repo = .{
        .label = try allocator.dupe(u8, std.fs.path.basename(root)),
        .display_path = try allocator.dupe(u8, root),
        .canonical_root = try allocator.dupe(u8, root),
    } };
}

const RepoSessionTestRepoPair = struct {
    tmp: std.testing.TmpDir,
    a: [:0]u8,
    b: [:0]u8,

    fn init() !RepoSessionTestRepoPair {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "a", .default_dir);
        try tmp.dir.createDir(std.testing.io, "b", .default_dir);
        const a = try tmp.dir.realPathFileAlloc(std.testing.io, "a", std.testing.allocator);
        errdefer std.testing.allocator.free(a);
        const b = try tmp.dir.realPathFileAlloc(std.testing.io, "b", std.testing.allocator);
        return .{ .tmp = tmp, .a = a, .b = b };
    }

    fn deinit(self: *RepoSessionTestRepoPair) void {
        std.testing.allocator.free(self.a);
        std.testing.allocator.free(self.b);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

fn installRepoSessionTestActionCursor(
    app: *RepoSessionTestApp,
    allocator: std.mem.Allocator,
    kind: changes_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    const identity = app.repoSessionView().activeIdentity() orelse return error.ExpectedRepositoryIdentity;
    var prepared = try app.changesNavigation().prepareActionCursor(
        allocator,
        app.repoSessionView().epoch(),
        identity,
        kind,
        path_key,
    );
    app.changesNavigation().installActionCursor(allocator, &prepared, action_generation);
}

test "workspace repository commitments advance one authoritative epoch" {
    const allocator = std.testing.allocator;
    var roots = try RepoSessionTestRepoPair.init();
    defer roots.deinit();
    const repos = try allocator.alloc(discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "a"),
        .display_path = try allocator.dupe(u8, roots.a),
        .canonical_root = try allocator.dupe(u8, roots.a),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "b"),
        .display_path = try allocator.dupe(u8, roots.b),
        .canonical_root = try allocator.dupe(u8, roots.b),
    };
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .workspace = .{
                .current_root = try allocator.dupe(u8, "/workspace"),
                .repos = repos,
            } } },
        },
    };
    app.repo_session.repo_state.root = try root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.deinit(allocator);
    defer app.pages.changes.deinit(allocator);
    defer app.remote.deinit(allocator);
    _ = app.activateChanges();

    app.pages.changes.pending_reload = .{ .generation = 17, .kind = .manual };
    try installRepoSessionTestActionCursor(&app, allocator, .file, "src/app.zig", 18);
    app.remote.branch_switch = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .generation = 19,
        .loading = true,
    };
    app.remote.branch_switch_load_pending = 19;
    app.overlay.openSwitchBranch();
    try std.testing.expectEqual(CommitOutcome.unchanged, app.repoSession().commitWorkspaceIndex(allocator, 0));
    try std.testing.expectEqual(@as(u64, 0), app.repoSessionView().epoch());
    try std.testing.expect(app.pages.changes.pending_reload == null);
    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
    try std.testing.expect(!app.remote.branch_switch.hasState());
    try std.testing.expect(app.remote.branch_switch_load_pending == null);
    try std.testing.expect(!app.overlay.isSwitchBranch());

    app.remote.push_error_message = try allocator.dupe(u8, "old repository push failure");
    app.overlay.openPushError();
    const deferred_identity = app.pages.changes.activation.currentIdentity().?;
    app.pages.changes.deferred_source_apply = .{
        .finished = .{
            .identity = deferred_identity,
            .generation = 51,
            .result = .empty,
        },
        .cycle_id = 0,
    };
    app.pages.changes.deferred_projection_apply = .{ .finished = .{
        .request = .{
            .identity = deferred_identity,
            .id = 52,
            .read_epoch = .{},
            .repo_root = try allocator.dupe(u8, roots.a),
            .path_key = try allocator.dupe(u8, "src/app.zig"),
            .kind = .cached_diff,
            .source_kind = .unstaged,
            .source_session_revision = 0,
            .status_snapshot_revision = 0,
        },
        .result = .{ .failed_static = "stale projection" },
    } };
    try std.testing.expectEqual(CommitOutcome.changed, app.repoSession().commitWorkspaceIndex(allocator, 1));
    try std.testing.expectEqual(@as(u64, 1), app.repoSessionView().epoch());
    try std.testing.expectEqualStrings(roots.b, app.repoSessionView().activeRoot().?);
    try std.testing.expect(app.remote.push_error_message == null);
    try std.testing.expect(!app.overlay.isPushError());
    try std.testing.expect(app.pages.changes.deferred_source_apply == null);
    try std.testing.expect(app.pages.changes.deferred_projection_apply == null);

    app.pages.changes.load.generation = 23;
    app.pages.changes.load.pending = .{ .diff_load = 23 };
    app.pages.changes.load.state = .loading;
    app.pages.changes.pending_reload = .{ .generation = 23, .kind = .manual };
    try std.testing.expectEqual(CommitOutcome.unchanged, app.repoSession().commitWorkspaceIndex(allocator, 1));
    try std.testing.expect(app.pages.changes.load.pending.? == .diff_load);
    try std.testing.expectEqual(@as(u64, 23), app.pages.changes.load.pending.?.generation());
    try std.testing.expectEqual(@as(u64, 23), app.pages.changes.pending_reload.?.generation);

    try std.testing.expectEqual(CommitOutcome.changed, app.repoSession().commitWorkspaceIndex(allocator, 0));
    try std.testing.expectEqual(@as(u64, 2), app.repoSessionView().epoch());
    try std.testing.expectEqualStrings(roots.a, app.repoSessionView().activeRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.pages.changes.activation.state.active.repo_epoch);
}

test "same repository path with a new filesystem object advances epoch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var app: RepoSessionTestApp = .{ .allocator = allocator };
    defer app.repo_session.deinit(allocator);

    try std.testing.expectEqual(CommitOutcome.changed, app.repoSession().commitDiscovery(
        allocator,
        try testRepoSessionSingleDiscovery(allocator, root_path),
        0,
        .external_selection,
    ));
    const first_identity = app.repoSessionView().activeIdentity().?;
    try std.testing.expectEqual(@as(u64, 1), app.repoSessionView().epoch());

    try tmp.dir.rename("repo", tmp.dir, "old-repo", io);
    try tmp.dir.createDir(io, "repo", .default_dir);
    try std.testing.expectEqual(CommitOutcome.changed, app.repoSession().commitDiscovery(
        allocator,
        try testRepoSessionSingleDiscovery(allocator, root_path),
        0,
        .external_selection,
    ));
    try std.testing.expect(!first_identity.eql(app.repoSessionView().activeIdentity().?));
    try std.testing.expectEqual(@as(u64, 2), app.repoSessionView().epoch());
}

test "repository capability commit failure leaves prior identity unchanged" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var roots = try RepoSessionTestRepoPair.init();
    defer roots.deinit();
    try roots.tmp.dir.symLink(io, "b", "linked", .{ .is_directory = true });
    const linked = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(roots.a).?, "linked" });
    defer allocator.free(linked);
    var app: RepoSessionTestApp = .{ .allocator = allocator };
    defer app.repo_session.deinit(allocator);
    try std.testing.expectEqual(CommitOutcome.changed, app.repoSession().commitDiscovery(
        allocator,
        try testRepoSessionSingleDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    const identity = app.repoSessionView().activeIdentity().?;

    try std.testing.expectEqual(CommitOutcome.rejected, app.repoSession().commitDiscovery(
        allocator,
        try testRepoSessionSingleDiscovery(allocator, roots.b),
        1,
        .external_selection,
    ));
    try std.testing.expectEqual(@as(u64, 1), app.repoSessionView().epoch());
    try std.testing.expectEqualStrings(roots.a, app.repoSessionView().activeRoot().?);
    try std.testing.expect(identity.eql(app.repoSessionView().activeIdentity().?));

    try std.testing.expectEqual(CommitOutcome.rejected, app.repoSession().commitDiscovery(
        allocator,
        try testRepoSessionSingleDiscovery(allocator, linked),
        0,
        .external_selection,
    ));
    try std.testing.expectEqual(@as(u64, 1), app.repoSessionView().epoch());
    try std.testing.expectEqualStrings(roots.a, app.repoSessionView().activeRoot().?);
    try std.testing.expect(identity.eql(app.repoSessionView().activeIdentity().?));
}

test "repo picker focuses active workspace repository" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "one"),
        .display_path = try allocator.dupe(u8, "one"),
        .canonical_root = try allocator.dupe(u8, "/work/one"),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "two"),
        .display_path = try allocator.dupe(u8, "two"),
        .canonical_root = try allocator.dupe(u8, "/work/two"),
    };

    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_state = .{
                .discovery = .{ .workspace = .{
                    .current_root = try allocator.dupe(u8, "/work"),
                    .repos = repos,
                } },
                .active_index = 1,
            },
        },
    };
    defer app.repo_session.deinit(allocator);

    try app.repoSession().enterPicker(allocator);

    try std.testing.expect(app.repo_session.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 2), app.repo_session.repo_picker.list.filter.labels.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.repo_picker.list.filter.list.focusedIndex());
}

test "repo picker opens for a single repository" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "repo"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/repo"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);

    try app.repoSession().enterPicker(allocator);

    try std.testing.expect(app.repo_session.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("repo", app.repo_session.repo_picker.list.filter.labels[0]);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 3 });
    try std.testing.expectError(error.OutOfMemory, app.repoSession().refreshPickerFilter(failing.allocator()));
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.repo_picker_items.items.len);
    try std.testing.expectEqualStrings("repo", app.repo_session.repo_picker_items.items[0].label);
    try std.testing.expectEqualStrings("repo", app.repo_session.repo_picker.list.filter.labels[0]);
}

test "repo picker removes selected recent entry only" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "active"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/active"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    try app.repo_session.recent_repos.rememberRepo(allocator, "/work/recent");
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    try app.repoSession().enterPicker(allocator);
    try std.testing.expectEqual(@as(usize, 2), app.repo_session.repo_picker.list.filter.labels.len);

    try app.repoSession().removeSelectedRecent(&ctx);
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.recent_repos.entries.items.len);

    app.repo_session.repo_picker.list.filter.update(.move_next);
    try app.repoSession().removeSelectedRecent(&ctx);
    try std.testing.expectEqual(@as(usize, 0), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("active", app.repo_session.repo_picker.list.filter.labels[0]);
}

test "repo picker removes stale recent entry after path discovery error" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "active"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/active"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    try app.repo_session.recent_repos.rememberRepo(allocator, "/gone/repo");
    try app.repoSession().enterPicker(allocator);
    const failed_generation = app.repo_session.repo_picker.beginPathDiscovery();
    app.repo_session.pending_repo_path_recent_source = .{ .kind = .repo, .index = 0 };

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = failing.allocator() };
    var failed_refresh = RepoPathDiscoveryFinished{
        .generation = failed_generation,
        .submitted_path = try allocator.dupe(u8, "/gone/repo"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    try std.testing.expectError(error.OutOfMemory, app.repoSession().finishPathDiscovery(&failing_ctx, failed_refresh));
    failed_refresh = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.repo_session.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("/gone/repo", app.repo_session.recent_repos.entries.items[0].path);

    const generation = app.repo_session.repo_picker.beginPathDiscovery();
    app.repo_session.pending_repo_path_recent_source = .{ .kind = .repo, .index = 0 };

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/gone/repo"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 0), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(?prompt.RepoPickerPathError, null), app.repo_session.repo_picker.path_error);
    try std.testing.expectEqual(@as(usize, 1), app.repo_session.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("active", app.repo_session.repo_picker.list.filter.labels[0]);
}

test "repo picker keeps recent entry for non-stale path discovery error" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "active"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/active"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    try app.repo_session.recent_repos.rememberRepo(allocator, "/mounted/repo");
    try app.repoSession().enterPicker(allocator);
    const generation = app.repo_session.repo_picker.beginPathDiscovery();
    app.repo_session.pending_repo_path_recent_source = .{ .kind = .repo, .index = 0 };

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/mounted/repo"),
        .result = .{ .input_error = error.CannotAccessPath },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 1), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expectEqual(prompt.RepoPickerPathError.cannot_access_path, app.repo_session.repo_picker.path_error.?);
}

test "repo picker removes stale recent workspace after no repos remain" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "active"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/active"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    try app.repo_session.recent_repos.rememberWorkspace(allocator, "/gone/workspace");
    try app.repoSession().enterPicker(allocator);
    const generation = app.repo_session.repo_picker.beginPathDiscovery();
    app.repo_session.pending_repo_path_recent_source = .{ .kind = .workspace, .index = 0 };

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/gone/workspace"),
        .result = .{ .input_error = error.NoGitRepositoriesFound },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 0), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(?prompt.RepoPickerPathError, null), app.repo_session.repo_picker.path_error);
}

test "repo picker path input errors do not remove recent history" {
    const allocator = std.testing.allocator;
    var parent_environment = try std.testing.environ.createMap(allocator);
    defer parent_environment.deinit();
    try parent_environment.put("GiT_path_selector", "redirect");
    try parent_environment.put("GITFRAME_S1_CANARY", "preserved");
    var app: RepoSessionTestApp = .{
        .env_map = &parent_environment,
        .repo_session = .{
            .repo_picker = .{ .mode = true, .input_mode = .path_input },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "active"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/active"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    try app.repo_session.recent_repos.rememberRepo(allocator, "/kept/repo");
    try app.repoSession().enterPicker(allocator);
    try app.repoSession().startPathDiscovery(&ctx, "/typed/missing", null);
    const pending_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending_tasks.len);
    const task: *RepoPathDiscoveryTask = @ptrCast(@alignCast(pending_tasks[0].ctx));
    const generation = task.generation;
    try std.testing.expectEqualStrings(
        "preserved",
        task.environment.borrow().get("GITFRAME_S1_CANARY").?,
    );
    try std.testing.expect(task.environment.borrow().get("GiT_path_selector") == null);
    var abandoned = pending_tasks[0].failed(pending_tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/typed/missing"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 1), app.repo_session.recent_repos.entries.items.len);
    try std.testing.expectEqualStrings("/kept/repo", app.repo_session.recent_repos.entries.items[0].path);
    try std.testing.expectEqual(prompt.RepoPickerPathError.path_does_not_exist, app.repo_session.repo_picker.path_error.?);
}

test "repo picker stale recent removal falls back to matching path after index shift" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "active"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/work/active"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    try app.repo_session.recent_repos.rememberRepo(allocator, "/old/first");
    try app.repo_session.recent_repos.rememberRepo(allocator, "/old/second");
    try app.repoSession().enterPicker(allocator);
    const generation = app.repo_session.repo_picker.beginPathDiscovery();
    app.repo_session.pending_repo_path_recent_source = .{ .kind = .repo, .index = 1 };
    try std.testing.expect(app.repo_session.recent_repos.removeAt(allocator, 0));

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/old/first"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 0), app.repo_session.recent_repos.entries.items.len);
}

test "workspace path discovery keeps picker open for explicit repo selection" {
    const allocator = std.testing.allocator;
    var roots = try RepoSessionTestRepoPair.init();
    defer roots.deinit();
    const repos = try allocator.alloc(discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "chasen"),
        .display_path = try allocator.dupe(u8, "chasen"),
        .canonical_root = try allocator.dupe(u8, roots.a),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "gitframe"),
        .display_path = try allocator.dupe(u8, "gitframe"),
        .canonical_root = try allocator.dupe(u8, roots.b),
    };

    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "current"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/current/repo"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    _ = try app.repoSession().acceptPathDiscovery(&ctx, .{ .workspace = .{
        .current_root = try allocator.dupe(u8, "/work"),
        .repos = repos,
    } });

    try std.testing.expect(app.repo_session.repo_picker.mode);
    try std.testing.expectEqual(prompt.RepoPickerInputMode.list, app.repo_session.repo_picker.input_mode);
    try std.testing.expectEqualStrings("/current/repo", app.repo_session.repo_state.activeRoot().?);
    try std.testing.expectEqual(@as(usize, 2), app.repo_session.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("chasen", app.repo_session.repo_picker.list.filter.labels[0]);
    try std.testing.expectEqualStrings("gitframe", app.repo_session.repo_picker.list.filter.labels[1]);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, app.repoSession().acceptPendingWorkspace(&failing_ctx, 0));
    try std.testing.expect(app.repo_session.repo_picker_discovery != null);
    try std.testing.expect(app.repo_session.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 2), app.repo_session.repo_picker_items.items.len);
    try std.testing.expectEqualStrings("chasen", app.repo_session.repo_picker.list.filter.labels[0]);
}

test "closed repo picker rejects stale path discovery result after reopen" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "current"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/current/repo"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    const old_generation = app.repo_session.repo_picker.beginPathDiscovery();
    try app.repoSession().cancelPicker(allocator);
    try app.repoSession().enterPicker(allocator);
    const new_generation = app.repo_session.repo_picker.beginPathDiscovery();

    var stale = RepoPathDiscoveryFinished{
        .generation = old_generation,
        .submitted_path = try allocator.dupe(u8, "/old/repo"),
        .result = .{ .discovered = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "old"),
            .display_path = try allocator.dupe(u8, "."),
            .canonical_root = try allocator.dupe(u8, "/old/repo"),
        } } },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, stale);
    stale = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expect(new_generation != old_generation);
    try std.testing.expectEqualStrings("/current/repo", app.repo_session.repo_state.activeRoot().?);
}

test "repo picker path cancel rejects stale discovery result" {
    const allocator = std.testing.allocator;
    var app: RepoSessionTestApp = .{
        .repo_session = .{
            .repo_picker = .{ .mode = true, .input_mode = .path_input },
            .repo_state = .{
                .discovery = .{ .single_repo = .{
                    .label = try allocator.dupe(u8, "current"),
                    .display_path = try allocator.dupe(u8, "."),
                    .canonical_root = try allocator.dupe(u8, "/current/repo"),
                } },
            },
        },
    };
    defer app.repo_session.deinit(allocator);
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    const edit_stale_generation = app.repo_session.repo_picker.beginPathDiscovery();
    app.repo_session.pending_repo_path_recent_source = .{ .kind = .repo, .index = 0 };
    try app.repoSession().insertPickerSlice(allocator, "new-path");
    try std.testing.expect(!app.repo_session.repo_picker.path_pending);
    try std.testing.expect(app.repo_session.pending_repo_path_recent_source == null);

    var edit_stale = RepoPathDiscoveryFinished{
        .generation = edit_stale_generation,
        .submitted_path = try allocator.dupe(u8, "/edited/old/repo"),
        .result = .{ .discovered = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "edited-old"),
            .display_path = try allocator.dupe(u8, "."),
            .canonical_root = try allocator.dupe(u8, "/edited/old/repo"),
        } } },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, edit_stale);
    edit_stale = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };
    try std.testing.expectEqualStrings("/current/repo", app.repo_session.repo_state.activeRoot().?);

    const stale_generation = app.repo_session.repo_picker.beginPathDiscovery();
    try app.repoSession().cancelPicker(allocator);

    var stale = RepoPathDiscoveryFinished{
        .generation = stale_generation,
        .submitted_path = try allocator.dupe(u8, "/old/repo"),
        .result = .{ .discovered = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "old"),
            .display_path = try allocator.dupe(u8, "."),
            .canonical_root = try allocator.dupe(u8, "/old/repo"),
        } } },
    };
    _ = try app.repoSession().finishPathDiscovery(&ctx, stale);
    stale = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(prompt.RepoPickerInputMode.list, app.repo_session.repo_picker.input_mode);
    try std.testing.expect(!app.repo_session.repo_picker.path_pending);
    try std.testing.expectEqualStrings("/current/repo", app.repo_session.repo_state.activeRoot().?);
}

test "repository switch clears the Changes action cursor owner" {
    const allocator = std.testing.allocator;
    var roots = try RepoSessionTestRepoPair.init();
    defer roots.deinit();
    const repos = try allocator.alloc(discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "one"),
        .display_path = try allocator.dupe(u8, roots.a),
        .canonical_root = try allocator.dupe(u8, roots.a),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "two"),
        .display_path = try allocator.dupe(u8, roots.b),
        .canonical_root = try allocator.dupe(u8, roots.b),
    };

    var app: RepoSessionTestApp = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{
                .discovery = .{ .workspace = .{
                    .current_root = try allocator.dupe(u8, "/work"),
                    .repos = repos,
                } },
                .active_index = 0,
            },
        },
    };
    app.repo_session.repo_state.root = try root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.deinit(allocator);
    defer app.changesNavigation().clearActionCursor(allocator);

    try installRepoSessionTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
    try std.testing.expectEqual(
        CommitOutcome.changed,
        app.repoSession().commitWorkspaceIndex(allocator, 1),
    );

    try std.testing.expect(!app.pages.changes.action_cursor.hasOwner());
}

test "expandUserPath expands current user's home shorthand" {
    const allocator = std.testing.allocator;
    const home = "/home/tester";

    const bare_home = try expandUserPath(allocator, "~", home);
    defer allocator.free(bare_home);
    try std.testing.expectEqualStrings(home, bare_home);

    const child = try expandUserPath(allocator, "~/dev/repo", home);
    defer allocator.free(child);
    try std.testing.expectEqualStrings("/home/tester/dev/repo", child);

    const named_user = try expandUserPath(allocator, "~someone/repo", home);
    defer allocator.free(named_user);
    try std.testing.expectEqualStrings("~someone/repo", named_user);
}

test "saveRecentRepositoriesState writes reloadable state atomically" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(root);
    const path = try std.fs.path.join(allocator, &.{ root, "nested", "state.json" });
    defer allocator.free(path);

    var store: repo_state.RecentStore = .{};
    defer store.deinit(allocator);
    try store.rememberWorkspace(allocator, "/tmp/work");
    try store.rememberRepo(allocator, "/tmp/work/repo");

    try saveRecentRepositoriesState(std.testing.io, path, &store);

    var loaded = config.loadState(allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expect(loaded.warning == null);
    try std.testing.expectEqual(@as(usize, 2), loaded.state.value.recent_repositories.entries.len);
    try std.testing.expectEqual(config.RecentRepositoryKind.repo, loaded.state.value.recent_repositories.entries[0].kind);
    try std.testing.expectEqualStrings("/tmp/work/repo", loaded.state.value.recent_repositories.entries[0].path);
    try std.testing.expectEqual(config.RecentRepositoryKind.workspace, loaded.state.value.recent_repositories.entries[1].kind);
    try std.testing.expectEqualStrings("/tmp/work", loaded.state.value.recent_repositories.entries[1].path);
}

fn sameIdentity(
    left_path: ?[]const u8,
    left_object: ?root_capability.Identity,
    right_path: ?[]const u8,
    right_object: ?root_capability.Identity,
) bool {
    if (left_path == null or right_path == null) return left_path == null and right_path == null;
    if (!std.mem.eql(u8, left_path.?, right_path.?)) return false;
    if (left_object == null or right_object == null) return left_object == null and right_object == null;
    return left_object.?.eql(right_object.?);
}

fn discoveryRootAt(result: discovery.DiscoveryResult, active_index: usize) ?[]const u8 {
    return switch (result) {
        .single_repo => |entry| entry.canonical_root,
        .workspace => |workspace| if (active_index < workspace.repos.len) workspace.repos[active_index].canonical_root else null,
        .none => null,
    };
}

fn validDiscoveryIndex(result: discovery.DiscoveryResult, active_index: usize) bool {
    return switch (result) {
        .single_repo, .none => active_index == 0,
        .workspace => |workspace| active_index < workspace.repos.len,
    };
}

fn pendingWorkspaceRoot(result: ?discovery.DiscoveryResult) ?[]const u8 {
    const pending = result orelse return null;
    return switch (pending) {
        .workspace => |workspace| workspace.current_root,
        .single_repo, .none => null,
    };
}

fn nextEpoch(current: u64) u64 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn recentSourceIdentity(source: repo_picker.ItemSource) ?PendingRecentPathDiscovery {
    return switch (source) {
        .recent_repo => |index| .{ .kind = .repo, .index = index },
        .recent_workspace => |index| .{ .kind = .workspace, .index = index },
        .active_repo, .workspace_repo, .pending_workspace_repo => null,
    };
}

fn isStaleRecentPathError(err: discovery.PathDiscoveryError) bool {
    return switch (err) {
        error.PathDoesNotExist,
        error.PathIsNotDirectory,
        error.NoGitRepositoriesFound,
        => true,
        error.CannotAccessPath,
        error.OutOfMemory,
        error.SpawnFailed,
        error.StreamTooLong,
        => false,
    };
}
