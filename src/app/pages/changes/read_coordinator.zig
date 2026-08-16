//! Sole shell-side coordinator for Changes repository reads.
//!
//! The page-local reload owner prepares and reconciles model transitions;
//! this short-lived controller owns task allocation/spawn, completion routing,
//! deferred application, revalidation scheduling, and redraw effects. It has
//! no access to the root `App` or action-workflow state.

const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const app_actions = @import("../../actions.zig");
const app_auto_reload = @import("../../auto_reload.zig");
const diff_surface = @import("../../diff_surface.zig");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const app_page = @import("../../page.zig");
const app_changes_projection = @import("../../changes_projection.zig");
const repo_session = @import("../../repo_session.zig");
const changes_page = @import("../changes.zig");
const action_fence = @import("action_fence.zig");
const changes_navigation = @import("navigation.zig");
const changes_reload = @import("reload.zig");
const changes_repository_session = @import("repository_session.zig");
const diff_source = @import("../../../diff/source.zig");
const git_command = @import("../../../git/command.zig");
const git_read = @import("../../../git/read.zig");
const repo_discovery = @import("../../../repo/discovery.zig");
const repo_root_capability = @import("../../../repo/root_capability.zig");
const source_syntax_runtime = @import("../../../syntax/source_runtime.zig");

const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(app_message.Msg);
const StatusLoadFinished = app_load.StatusLoadFinished;
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const BranchStatusLoadFinished = app_load.BranchStatusLoadFinished;
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const ChangesProjectionFinished = app_load.ChangesProjectionFinished;
const ChangesProjectionTask = app_load.ChangesProjectionTask(app_message.Msg);
const GeneratedSyntaxTask = app_load.GeneratedSyntaxTask(app_message.Msg);

pub const RedrawSink = struct {
    skip_requested: *bool,
    frame_required: *bool,

    fn requestSkip(self: RedrawSink) void {
        self.skip_requested.* = true;
    }

    fn requireFrame(self: RedrawSink) void {
        self.frame_required.* = true;
    }
};

pub const ShellBlockers = struct {
    commit_panel: bool = false,
    action_pending: bool = false,
};

const DiffLoadStartOptions = struct {
    clear_visible_state: bool,
    kind: changes_page.ReloadKind,
    background_cycle_id: ?u64 = null,
    action_cursor_generation: ?u64 = null,

    fn sourceOptions(self: DiffLoadStartOptions) changes_reload.SourceLoadOptions {
        return .{
            .clear_visible_state = self.clear_visible_state,
            .kind = self.kind,
            .background_cycle_id = self.background_cycle_id,
        };
    }
};

const ClosedAuthorityConsequence = enum { queue_revalidation, drop };

const ReloadStart = enum {
    one_shot_source,
    authority_closed,
    needs_repo_discovery,
    no_repo_root,
    source_started,
};

const RevalidationStartDisposition = enum {
    accepted_source,
    accepted_repo_discovery,
    rejected_start,
    unsupported,
};

pub const ManualReloadDisposition = enum {
    blocked,
    ready,
};

pub const PendingDiscoveryCommit = struct {
    identity: app_page.RequestIdentity,
    generation: u64,
    discovery: ?repo_discovery.DiscoveryResult,

    pub fn deinit(self: *PendingDiscoveryCommit, allocator: std.mem.Allocator) void {
        if (self.discovery) |*owned| owned.deinit(allocator);
        self.discovery = null;
    }

    pub fn takeDiscovery(self: *PendingDiscoveryCommit) repo_discovery.DiscoveryResult {
        const discovery = self.discovery orelse unreachable;
        self.discovery = null;
        return discovery;
    }
};

pub const Controller = struct {
    page_state: *changes_page.ChangesPageState,
    fence: action_fence.View,
    active_page: app_page.Id,
    repo: repo_session.View,
    source: diff_source.SourceMode,
    layout: diff_surface.Layout,
    env_map: ?*std.process.Environ.Map,
    allocator: ?std.mem.Allocator,
    redraw: RedrawSink,
    shell_blockers: ShellBlockers,

    fn setStatus(self: Controller, comptime fmt: []const u8, args: anytype) void {
        self.page_state.status.set(fmt, args);
    }

    fn navigationOwner(self: Controller) changes_navigation.Controller {
        return .{
            .page = self.page_state,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = self.source,
            .layout = self.layout,
            .diagnostics = .{ .target = &self.page_state.status },
        };
    }

    fn reloadOwner(self: Controller) changes_reload.Controller {
        return .{
            .page = self.page_state,
            .navigation = self.navigationOwner(),
            .source = self.source,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
        };
    }

    pub fn repositorySessionPort(self: Controller) changes_repository_session.Controller {
        return .{
            .page = self.page_state,
            .navigation = self.navigationOwner(),
            .reload = self.reloadOwner(),
        };
    }

    pub fn captureDisplayOverride(self: Controller, allocator: std.mem.Allocator) !void {
        try self.reloadOwner().captureDisplayOverride(allocator);
    }

    pub fn retireSupersededActionCursor(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        action_generation: u64,
    ) void {
        if (self.page_state.action_cursor.actionGeneration()) |generation| {
            if (action_generation > generation) self.navigationOwner().clearActionCursor(ctx.allocator());
        }
    }

    fn readBusy(self: Controller) bool {
        return !self.fence.mayStartRepositoryRead() or
            self.fence.hasActionCursor() or
            self.page_state.auto_reload.background_cycle != null or
            self.page_state.load.hasPending() or self.page_state.load.state == .loading or
            self.page_state.status_load.isPending() or self.page_state.branch_status_load.isPending() or
            self.page_state.deferred_source_apply != null;
    }

    pub fn hasQueuedFullRevalidation(self: Controller) bool {
        return self.fence.hasQueuedFullRevalidation();
    }

    pub fn requestRevalidation(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .changes) return;
        if (diff_source.sourceIsOneShotInput(self.source)) return;
        self.page_state.activation.queueRevalidation();
        if (self.readBusy()) return;
        try self.startRevalidation(ctx);
    }

    fn startRevalidation(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .changes) return;
        var cycle_id = self.page_state.auto_reload.beginCycle();
        errdefer if (cycle_id) |id| self.page_state.auto_reload.discardEmptyCycle(id);
        const outcome = try self.startReload(ctx, .{
            .clear_visible_state = self.page_state.load.state == .idle,
            .kind = .watch,
            .background_cycle_id = cycle_id,
        }, .queue_revalidation);
        if (cycle_id) |id| {
            self.page_state.auto_reload.discardEmptyCycle(id);
            cycle_id = null;
        }
        if (outcome == .needs_repo_discovery) try self.startRepoDiscovery(ctx, null);
    }

    pub fn maybeStartQueuedRevalidation(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .changes or self.readBusy()) return;
        if (!self.page_state.activation.hasQueuedFullRevalidation()) return;
        if (diff_source.sourceIsOneShotInput(self.source)) {
            self.page_state.activation.discardTerminalRevalidation();
            return;
        }
        self.startRevalidation(ctx) catch {};
    }

    pub fn startRepoDiscovery(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        background_cycle_id: ?u64,
    ) !void {
        if (!self.fence.mayStartRepositoryRead()) return;
        var changes_update = try self.reloadOwner().prepareRepoDiscovery(ctx.allocator(), background_cycle_id);
        defer changes_update.deinit(ctx.allocator());
        var command = changes_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const discovery = &command.repo_discovery;
        const generation = discovery.generation;
        var environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch |err| {
            self.reloadOwner().rejectRepoDiscoverySpawn(generation);
            return err;
        };
        var environment_consumed = false;
        defer if (!environment_consumed) environment.deinit();
        const task = ctx.allocator().create(RepoDiscoveryTask) catch |err| {
            self.reloadOwner().rejectRepoDiscoverySpawn(generation);
            return err;
        };
        task.* = .{
            .identity = discovery.identity,
            .generation = discovery.generation,
            .background_cycle_id = discovery.background_cycle_id,
            .environment = environment,
        };
        environment_consumed = true;
        command_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = RepoDiscoveryTask.run, .failed = RepoDiscoveryTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.reloadOwner().rejectRepoDiscoverySpawn(generation);
            try self.reloadOwner().replaceSourceFailure(ctx.allocator(), "Could not start repo discovery task");
            return err;
        };
        self.reloadOwner().acceptRepoDiscoverySpawn(background_cycle_id);
    }

    pub fn finishRepoDiscovery(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: RepoDiscoveryFinished,
    ) !?PendingDiscoveryCommit {
        var completion_admitted = false;
        defer if (self.active_page != .changes and !completion_admitted) self.redraw.requestSkip();
        var result = finished;
        defer result.deinit(allocator);
        const identity = result.identity;
        const generation = result.generation;

        var applied = self.reloadOwner().applyRepoDiscoveryFinished(allocator, &result) catch |err| {
            _ = self.reloadOwner().rejectAppliedRepoDiscovery(identity, generation);
            return err;
        };
        defer applied.deinit(allocator);
        if (applied.commit_discovery == null) return null;
        completion_admitted = true;
        return .{
            .identity = identity,
            .generation = generation,
            .discovery = applied.takeCommitDiscovery(),
        };
    }

    pub fn rejectAppliedRepoDiscovery(
        self: Controller,
        identity: app_page.RequestIdentity,
        generation: u64,
    ) void {
        _ = self.reloadOwner().rejectAppliedRepoDiscovery(identity, generation);
    }

    pub fn acceptRepoDiscoveryCommit(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        switch (self.reloadOwner().applyRepoDiscoveryCommit(
            ctx.allocator(),
            self.repo.activeRoot() != null,
            self.active_page == .changes,
        )) {
            .none => {},
            .start_initial_read => try self.startDiffLoad(ctx, .initial),
        }
    }

    pub fn startDiffLoad(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        kind: changes_page.ReloadKind,
    ) !void {
        if (!self.fence.mayStartRepositoryRead()) return;
        const repo_root = self.repo.rootForSource(self.source) catch {
            self.reloadOwner().replaceMissingRepository(ctx.allocator());
            return;
        };
        try self.startDiffLoadWithRepoRoot(ctx, repo_root, .{
            .clear_visible_state = true,
            .kind = kind,
        });
    }

    fn startReload(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        options: DiffLoadStartOptions,
        closed_authority: ClosedAuthorityConsequence,
    ) !ReloadStart {
        if (diff_source.sourceIsOneShotInput(self.source)) return .one_shot_source;
        if (!self.fence.mayStartRepositoryRead()) {
            switch (closed_authority) {
                .queue_revalidation => self.page_state.activation.queueRevalidation(),
                .drop => {},
            }
            return .authority_closed;
        }
        if (diff_source.sourceRequiresRepo(self.source) and self.repo.needsDiscovery()) {
            return .needs_repo_discovery;
        }
        const repo_root = self.repo.rootForSource(self.source) catch return .no_repo_root;
        try self.startDiffLoadWithRepoRoot(ctx, repo_root, options);
        return .source_started;
    }

    /// Performs the read-side admission check before the shell clears any
    /// unrelated overlay state. The caller consumes `.ready` synchronously in
    /// the same update turn.
    pub fn prepareManualReload(self: Controller) ManualReloadDisposition {
        if (!self.fence.mayStartRepositoryRead() or self.fence.hasActionCursor()) {
            self.page_state.activation.queueRevalidation();
            self.redraw.requestSkip();
            return .blocked;
        }
        return .ready;
    }

    pub fn startPreparedManualReload(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        switch (try self.startReload(
            ctx,
            .{ .clear_visible_state = true, .kind = .manual },
            .queue_revalidation,
        )) {
            .one_shot_source, .authority_closed => self.redraw.requestSkip(),
            .needs_repo_discovery => try self.startRepoDiscovery(ctx, null),
            .no_repo_root => self.reloadOwner().replaceMissingRepository(ctx.allocator()),
            .source_started => {},
        }
    }

    fn startDiffLoadWithRepoRoot(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_root: ?[]const u8,
        options: DiffLoadStartOptions,
    ) !void {
        if (!self.fence.mayStartRepositoryRead()) return;
        const action_cursor_generation = if (options.action_cursor_generation) |generation|
            if (self.page_state.action_cursor.ownsRefresh(generation)) generation else null
        else
            null;
        if (options.action_cursor_generation == null and self.page_state.action_cursor.awaitingRefresh()) {
            self.navigationOwner().clearActionCursor(ctx.allocator());
        }
        defer if (action_cursor_generation != null) {
            _ = self.navigationOwner().finalizeActionCursor(ctx.allocator());
        };

        var changes_update = self.reloadOwner().prepareSourceLoad(
            ctx.allocator(),
            repo_root,
            options.sourceOptions(),
        ) catch |err| {
            if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.failMemberBeforeStart(generation, .source);
                _ = self.page_state.action_cursor.failMemberBeforeStart(generation, .status);
            }
            self.reloadOwner().failActiveMember(.source);
            return err;
        };
        defer changes_update.deinit(ctx.allocator());
        var command = changes_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const source_read = &command.source_load;
        const generation = source_read.generation;
        var status_receipt: ?app_auto_reload.AuxiliaryTerminal = null;
        var branch_receipt: ?app_auto_reload.AuxiliaryTerminal = null;
        var source_accepted = false;
        defer if (!source_accepted) self.retireRejectedFullStartAuxiliaries(status_receipt, branch_receipt);

        if (repo_root) |root| {
            status_receipt = self.startStatusLoadTracked(
                ctx,
                root,
                if (options.kind == .watch) .background else .foreground,
                options.background_cycle_id,
                action_cursor_generation,
            ) catch |err| {
                _ = self.reloadOwner().rejectSourceSpawn(ctx.allocator(), generation);
                if (action_cursor_generation) |action_generation| {
                    _ = self.page_state.action_cursor.failMemberBeforeStart(action_generation, .source);
                }
                return err;
            };
            branch_receipt = self.startBranchStatusLoad(ctx, root, options.background_cycle_id);
        } else {
            if (action_cursor_generation) |action_generation| {
                _ = self.page_state.action_cursor.failMemberBeforeStart(action_generation, .status);
            }
            self.reloadOwner().dropStatusSnapshot(ctx.allocator());
            self.reloadOwner().invalidateBranchStatusSnapshot();
        }

        if (action_cursor_generation) |action_generation| {
            _ = self.page_state.action_cursor.startMember(action_generation, .source, generation);
        }
        var authority = self.loadAuthorityForSource(ctx.allocator(), source_read.request.source) catch |err| {
            _ = self.reloadOwner().rejectSourceSpawn(ctx.allocator(), generation);
            if (action_cursor_generation) |action_generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(action_generation, .source, generation);
            }
            return err;
        };
        var authority_consumed = false;
        defer if (!authority_consumed) authority.deinit();
        const task = ctx.allocator().create(DiffLoadTask) catch |err| {
            _ = self.reloadOwner().rejectSourceSpawn(ctx.allocator(), generation);
            if (action_cursor_generation) |action_generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(action_generation, .source, generation);
            }
            return err;
        };
        task.* = .{
            .identity = source_read.identity,
            .read_epoch = source_read.read_epoch,
            .request = source_read.request,
            .authority = authority,
            .generation = source_read.generation,
            .expected_fingerprint = source_read.expected_fingerprint,
            .background_cycle_id = source_read.background_cycle_id,
        };
        authority_consumed = true;
        command_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = DiffLoadTask.run, .failed = DiffLoadTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            const retained_publication = self.reloadOwner().rejectSourceSpawn(ctx.allocator(), generation);
            if (action_cursor_generation) |action_generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(action_generation, .source, generation);
            }
            if (!retained_publication) {
                try self.reloadOwner().replaceSourceFailure(ctx.allocator(), "Could not start diff load task");
            }
            return err;
        };
        self.reloadOwner().acceptSourceSpawn(options.background_cycle_id);
        source_accepted = true;
    }

    fn startStatusLoadTracked(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_root: []const u8,
        origin: git_read.ReadOrigin,
        background_cycle_id: ?u64,
        action_cursor_generation: ?u64,
    ) !app_auto_reload.AuxiliaryTerminal {
        if (!self.fence.mayStartRepositoryRead()) return error.RepositoryReadAuthorityClosed;
        var changes_update = self.reloadOwner().prepareStatusLoad(
            ctx.allocator(),
            repo_root,
            origin,
            background_cycle_id,
        ) catch |err| {
            if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.failMemberBeforeStart(generation, .status);
            }
            self.reloadOwner().failActiveMember(.status);
            self.setStatus("could not allocate status repo root", .{});
            return err;
        };
        defer changes_update.deinit(ctx.allocator());
        var command = changes_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const status_read = &command.status_load;
        if (action_cursor_generation) |generation| {
            _ = self.page_state.action_cursor.startMember(generation, .status, status_read.generation);
        }
        const capability = self.repo.activeCapability() orelse {
            self.reloadOwner().rejectStatusSpawn(background_cycle_id);
            return error.RepositoryReadAuthorityClosed;
        };
        var root = capability.duplicate() catch |err| {
            self.reloadOwner().rejectStatusSpawn(background_cycle_id);
            if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(generation, .status, status_read.generation);
            }
            return err;
        };
        var root_consumed = false;
        defer if (!root_consumed) root.deinit();
        var environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch |err| {
            self.reloadOwner().rejectStatusSpawn(background_cycle_id);
            if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(generation, .status, status_read.generation);
            }
            return err;
        };
        var environment_consumed = false;
        defer if (!environment_consumed) environment.deinit();
        const task = ctx.allocator().create(StatusLoadTask) catch |err| {
            self.reloadOwner().rejectStatusSpawn(background_cycle_id);
            if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(generation, .status, status_read.generation);
            }
            self.setStatus("could not allocate status load task", .{});
            return err;
        };
        task.* = .{
            .identity = status_read.identity,
            .read_epoch = status_read.read_epoch,
            .repo_root = status_read.repo_root,
            .root = root,
            .environment = environment,
            .generation = status_read.generation,
            .origin = status_read.origin,
            .background_cycle_id = status_read.background_cycle_id,
        };
        root_consumed = true;
        environment_consumed = true;
        command_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = StatusLoadTask.run, .failed = StatusLoadTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.reloadOwner().rejectStatusSpawn(background_cycle_id);
            if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.rejectMemberSpawn(generation, .status, status_read.generation);
            }
            self.setStatus("could not start status load task", .{});
            return err;
        };
        self.reloadOwner().acceptStatusSpawn(background_cycle_id);
        return .{
            .generation = status_read.generation,
            .read_epoch = status_read.read_epoch,
            .background_cycle_id = status_read.background_cycle_id,
        };
    }

    fn loadAuthorityForSource(
        self: Controller,
        allocator: std.mem.Allocator,
        source: diff_source.SourceMode,
    ) !app_load.LoadAuthority {
        return switch (source) {
            .unstaged, .cached, .range => blk: {
                const capability = self.repo.activeCapability() orelse return error.RepositoryReadAuthorityClosed;
                break :blk try app_load.LoadAuthority.initRepository(allocator, capability.*, self.env_map);
            },
            .no_index => app_load.LoadAuthority.initNonRepository(allocator, self.env_map),
            .stdin, .pager, .patch_file => .none,
        };
    }

    fn startBranchStatusLoad(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_root: []const u8,
        background_cycle_id: ?u64,
    ) ?app_auto_reload.AuxiliaryTerminal {
        if (!self.fence.mayStartRepositoryRead()) return null;
        var changes_update = self.reloadOwner().prepareBranchStatusLoad(
            ctx.allocator(),
            repo_root,
            background_cycle_id,
        ) catch {
            self.reloadOwner().failActiveMember(.branch);
            self.setStatus("could not allocate branch status repo root", .{});
            return null;
        };
        defer changes_update.deinit(ctx.allocator());
        var command = changes_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const branch_read = &command.branch_status_load;
        const capability = self.repo.activeCapability() orelse {
            self.reloadOwner().rejectBranchStatusSpawn(background_cycle_id);
            self.setStatus("could not prepare branch status authority", .{});
            return null;
        };
        var root = capability.duplicate() catch {
            self.reloadOwner().rejectBranchStatusSpawn(background_cycle_id);
            self.setStatus("could not prepare branch status authority", .{});
            return null;
        };
        var root_consumed = false;
        defer if (!root_consumed) root.deinit();
        var environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch {
            self.reloadOwner().rejectBranchStatusSpawn(background_cycle_id);
            self.setStatus("could not prepare branch status environment", .{});
            return null;
        };
        var environment_consumed = false;
        defer if (!environment_consumed) environment.deinit();
        const task = ctx.allocator().create(BranchStatusLoadTask) catch {
            self.reloadOwner().rejectBranchStatusSpawn(background_cycle_id);
            self.setStatus("could not allocate branch status load task", .{});
            return null;
        };
        task.* = .{
            .identity = branch_read.identity,
            .read_epoch = branch_read.read_epoch,
            .repo_root = branch_read.repo_root,
            .root = root,
            .environment = environment,
            .generation = branch_read.generation,
            .background_cycle_id = branch_read.background_cycle_id,
        };
        root_consumed = true;
        environment_consumed = true;
        command_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = BranchStatusLoadTask.run, .failed = BranchStatusLoadTask.failed }) catch {
            task.destroy(ctx.allocator());
            self.reloadOwner().rejectBranchStatusSpawn(background_cycle_id);
            self.setStatus("could not start branch status load task", .{});
            return null;
        };
        self.reloadOwner().acceptBranchStatusSpawn(background_cycle_id);
        return .{
            .generation = branch_read.generation,
            .read_epoch = branch_read.read_epoch,
            .background_cycle_id = branch_read.background_cycle_id,
        };
    }

    fn retireRejectedFullStartAuxiliaries(
        self: Controller,
        status: ?app_auto_reload.AuxiliaryTerminal,
        branch: ?app_auto_reload.AuxiliaryTerminal,
    ) void {
        if (status) |terminal| _ = self.reloadOwner().supersedeAcceptedStatusSpawn(terminal);
        if (branch) |terminal| _ = self.reloadOwner().supersedeAcceptedBranchStatusSpawn(terminal);
    }

    pub fn applyDeferredSourceIfReady(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        if (self.page_state.selection_owner.activeMouseSelection() or
            self.page_state.deferred_source_apply == null)
        {
            return;
        }
        var applied = try self.reloadOwner().applyDeferredSource(
            ctx.allocator(),
            !self.fence.mayStartRepositoryRead(),
        ) orelse return;
        defer applied.deinit(ctx.allocator());
        self.applySourceOutcome(applied.source);
        if (self.active_page == .changes and applied.source.redraw == .normal) self.redraw.requireFrame();
    }

    pub fn applyDeferredProjectionIfReady(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        if (self.page_state.selection_owner.activeMouseSelection() or
            self.page_state.deferred_projection_apply == null)
        {
            return;
        }
        if (try self.reloadOwner().applyDeferredProjection(ctx.allocator())) self.redraw.requireFrame();
    }

    pub fn ensureProjection(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        if (!self.fence.mayStartRepositoryRead()) return;
        var changes_update = try self.reloadOwner().prepareProjection(self.allocator);
        if (changes_update.display_changed) self.redraw.requireFrame();
        if (changes_update.takeCommand()) |command| {
            const allocator = ctx.allocator();
            var owned_command = command;
            var command_consumed = false;
            defer if (!command_consumed) owned_command.deinit(allocator);

            switch (owned_command) {
                .repo_discovery, .source_load, .status_load, .branch_status_load => unreachable,
                .changes_projection => |*request| {
                    const request_id = request.id;
                    const capability = self.repo.activeCapability() orelse {
                        self.reloadOwner().rejectProjectionSpawn(allocator, request_id);
                        return;
                    };
                    if (!request.matchesRootIdentity(capability.identity)) {
                        self.reloadOwner().rejectProjectionSpawn(allocator, request_id);
                        return;
                    }
                    var root = capability.duplicate() catch |err| {
                        self.reloadOwner().rejectProjectionSpawn(allocator, request_id);
                        return err;
                    };
                    var root_consumed = false;
                    defer if (!root_consumed) root.deinit();
                    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, self.env_map) catch |err| {
                        self.reloadOwner().rejectProjectionSpawn(allocator, request_id);
                        return err;
                    };
                    var environment_consumed = false;
                    defer if (!environment_consumed) environment.deinit();
                    const task = allocator.create(ChangesProjectionTask) catch |err| {
                        self.reloadOwner().rejectProjectionSpawn(allocator, request_id);
                        return err;
                    };
                    task.* = .{ .request = request.*, .root = root, .environment = environment };
                    root_consumed = true;
                    environment_consumed = true;
                    request.* = undefined;
                    command_consumed = true;
                    ctx.task().spawnWith(.{ .ctx = task, .run = ChangesProjectionTask.run, .failed = ChangesProjectionTask.failed }) catch |err| {
                        task.destroy(allocator);
                        self.reloadOwner().rejectProjectionSpawn(allocator, request_id);
                        return err;
                    };
                    return;
                },
            }
        }
        if (source_syntax_runtime.enabled) self.ensureGeneratedProjectionSyntax(ctx);
    }

    fn ensureGeneratedProjectionSyntax(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) void {
        const allocator = self.allocator orelse return;
        var request = self.reloadOwner().prepareGeneratedSyntax(allocator) catch return orelse return;
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(allocator);
        const request_id = request.id;
        const capability = self.repo.activeCapability() orelse {
            self.reloadOwner().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
        if (!capability.identity.eql(request.root_identity)) {
            self.reloadOwner().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        }
        var root = capability.duplicate() catch {
            self.reloadOwner().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
        var root_consumed = false;
        defer if (!root_consumed) root.deinit();
        const task = allocator.create(GeneratedSyntaxTask) catch {
            self.reloadOwner().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
        task.* = .{ .request = request, .root = root };
        request_consumed = true;
        root_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = GeneratedSyntaxTask.run, .failed = GeneratedSyntaxTask.failed }) catch {
            task.destroy(allocator);
            self.reloadOwner().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
    }

    fn promoteActionCursorRefresh(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
        active_matches: bool,
        intent: action_fence.ReloadIntent,
    ) ?u64 {
        if (!active_matches) {
            _ = self.page_state.action_cursor.clearMatchingAction(allocator, pending.generation);
            return null;
        }
        const root_identity = self.repo.activeIdentity() orelse {
            _ = self.page_state.action_cursor.clearMatchingAction(allocator, pending.generation);
            return null;
        };
        const requirement: changes_page.action_cursor.RefreshRequirement = switch (intent) {
            .none => {
                _ = self.page_state.action_cursor.clearMatchingAction(allocator, pending.generation);
                return null;
            },
            .status => .status_only,
            .source_and_aux, .source_and_aux_clear_visible => .source_and_status,
        };
        if (!self.page_state.action_cursor.promote(
            pending.generation,
            self.repo.epoch(),
            root_identity,
            requirement,
        )) {
            _ = self.page_state.action_cursor.clearMatchingAction(allocator, pending.generation);
            return null;
        }
        return pending.generation;
    }

    fn startActionResultRevalidation(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        action_cursor_generation: ?u64,
        clear_visible_state: bool,
    ) RevalidationStartDisposition {
        const outcome = self.startReload(ctx, .{
            .clear_visible_state = clear_visible_state,
            .kind = .action_result,
            .action_cursor_generation = action_cursor_generation,
        }, .queue_revalidation) catch return .rejected_start;
        switch (outcome) {
            .one_shot_source => {
                if (action_cursor_generation) |generation| {
                    _ = self.page_state.action_cursor.clearMatchingAction(ctx.allocator(), generation);
                }
                self.page_state.activation.discardTerminalRevalidation();
                self.redraw.requestSkip();
                return .unsupported;
            },
            .authority_closed => {
                if (action_cursor_generation) |generation| {
                    _ = self.page_state.action_cursor.clearMatchingAction(ctx.allocator(), generation);
                }
                self.redraw.requestSkip();
                return .rejected_start;
            },
            .needs_repo_discovery => {
                if (action_cursor_generation) |generation| {
                    _ = self.page_state.action_cursor.clearMatchingAction(ctx.allocator(), generation);
                }
                self.startRepoDiscovery(ctx, null) catch return .rejected_start;
                return .accepted_repo_discovery;
            },
            .no_repo_root => {
                if (action_cursor_generation) |generation| {
                    _ = self.page_state.action_cursor.clearMatchingAction(ctx.allocator(), generation);
                }
                self.redraw.requestSkip();
                return .unsupported;
            },
            .source_started => return .accepted_source,
        }
    }

    fn applyReloadIntent(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        intent: action_fence.ReloadIntent,
        action_cursor_generation: ?u64,
    ) !void {
        switch (intent) {
            .none => if (action_cursor_generation) |generation| {
                _ = self.page_state.action_cursor.clearMatchingAction(ctx.allocator(), generation);
            },
            .source_and_aux => {
                _ = self.startActionResultRevalidation(
                    ctx,
                    action_cursor_generation,
                    false,
                );
            },
            .source_and_aux_clear_visible => {
                _ = self.startActionResultRevalidation(
                    ctx,
                    action_cursor_generation,
                    true,
                );
            },
            .status => |repo_root| {
                defer if (action_cursor_generation != null) {
                    _ = self.navigationOwner().finalizeActionCursor(ctx.allocator());
                };
                const accepted = self.startStatusLoadTracked(
                    ctx,
                    repo_root,
                    .foreground,
                    null,
                    action_cursor_generation,
                ) catch null;
                if (accepted != null) self.page_state.activation.consumeAcceptedTerminalRevalidation();
            },
        }
    }

    /// Atomically promotes any exact action cursor and starts the read work
    /// selected by the accepted Changes-local outcome. No half-promoted state
    /// is observable by the shell between these two transitions.
    pub fn applyActionOutcome(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        pending: app_actions.PendingAction,
        active_matches: bool,
        intent: action_fence.ReloadIntent,
    ) !void {
        const cursor_generation = self.promoteActionCursorRefresh(
            ctx.allocator(),
            pending,
            active_matches,
            intent,
        );
        try self.applyReloadIntent(ctx, intent, cursor_generation);
    }

    /// Bridges a shell/action effect through the same typed reload vocabulary
    /// without exposing raw read-start options or dispositions.
    pub fn applyEffectReload(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        intent: action_fence.ReloadIntent,
    ) !void {
        try self.applyReloadIntent(ctx, intent, null);
    }

    pub fn reloadAfterEditor(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
    ) !void {
        switch (try self.startReload(ctx, .{
            .clear_visible_state = self.page_state.load.state == .idle,
            .kind = .action_result,
        }, .queue_revalidation)) {
            .one_shot_source, .authority_closed, .no_repo_root => self.redraw.requestSkip(),
            .needs_repo_discovery => try self.startRepoDiscovery(ctx, null),
            .source_started => {},
        }
    }

    pub fn autoReloadTick(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .changes) {
            self.redraw.requestSkip();
            return;
        }
        if (!self.page_state.auto_reload.enabled()) return;
        if (diff_source.sourceIsOneShotInput(self.source)) return;
        if (!self.fence.mayStartRepositoryRead()) {
            self.redraw.requestSkip();
            return;
        }
        if (self.repo.picker().model.mode or self.page_state.search.mode or self.page_state.file_search.mode or
            self.shell_blockers.commit_panel or self.page_state.selection_owner.activeMouseSelection() or
            self.shell_blockers.action_pending or self.fence.hasActionCursor())
        {
            self.redraw.requestSkip();
            return;
        }
        if (self.page_state.auto_reload.background_cycle != null or self.page_state.load.hasPending() or
            self.page_state.load.state == .loading or self.page_state.status_load.isPending() or
            self.page_state.branch_status_load.isPending() or self.page_state.changes_projection.hasPending())
        {
            self.redraw.requestSkip();
            return;
        }

        if (diff_source.sourceRequiresRepo(self.source) and self.repo.needsDiscovery()) {
            if (self.page_state.auto_reload.activation != .forced) {
                self.redraw.requestSkip();
                return;
            }
            const cycle_id = self.page_state.auto_reload.beginCycle() orelse {
                self.redraw.requestSkip();
                return;
            };
            errdefer self.page_state.auto_reload.discardEmptyCycle(cycle_id);
            try self.startRepoDiscovery(ctx, cycle_id);
            self.page_state.auto_reload.discardEmptyCycle(cycle_id);
        } else {
            const cycle_id = self.page_state.auto_reload.beginCycle() orelse {
                self.redraw.requestSkip();
                return;
            };
            errdefer self.page_state.auto_reload.discardEmptyCycle(cycle_id);
            switch (try self.startReload(ctx, .{
                .clear_visible_state = self.page_state.load.state == .idle,
                .kind = .watch,
                .background_cycle_id = cycle_id,
            }, .drop)) {
                .no_repo_root, .source_started => {},
                .one_shot_source, .authority_closed, .needs_repo_discovery => unreachable,
            }
            self.page_state.auto_reload.discardEmptyCycle(cycle_id);
        }
        self.redraw.requestSkip();
    }

    fn finishActionCursorCompletion(
        self: Controller,
        allocator: std.mem.Allocator,
        token: changes_page.action_cursor.CompletionToken,
        succeeded: bool,
    ) !bool {
        if (!self.page_state.action_cursor.finishCompletion(token, succeeded)) return false;
        if (!self.page_state.action_cursor.terminal()) return false;
        self.reloadOwner().applyStatusProjection(allocator, false, .terminal_action) catch |err| {
            _ = self.navigationOwner().finalizeActionCursor(allocator);
            return err;
        };
        return self.navigationOwner().finalizeActionCursor(allocator);
    }

    pub fn finishDiffLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: DiffLoadFinished,
    ) !void {
        var result = finished;
        var result_transferred = false;
        defer if (!result_transferred) result.deinit(allocator);

        const action_completion = self.page_state.action_cursor.captureCompletion(
            result.identity.repo_epoch,
            .source,
            result.generation,
        );
        errdefer if (action_completion) |completion| {
            _ = self.finishActionCursorCompletion(allocator, completion, false) catch false;
        };

        var applied = try self.reloadOwner().applySourceFinished(
            allocator,
            &result,
            self.fence.blocksBackgroundAcceptance(result.background_cycle_id),
        );
        result_transferred = applied.result_transferred;
        if (applied.terminal_admitted) {
            if (action_completion) |completion| {
                const source_succeeded = switch (result.result) {
                    .empty, .unchanged, .loaded => true,
                    .failed, .failed_static => false,
                };
                if (try self.finishActionCursorCompletion(allocator, completion, source_succeeded)) {
                    applied.redraw = .normal;
                }
            }
        }
        self.applySourceOutcome(applied);
    }

    fn applySourceOutcome(self: Controller, applied: changes_reload.SourceApply) void {
        var recovered_failure_cleared = false;
        if (applied.recovered_failure) |failure| {
            recovered_failure_cleared = self.page_state.status.clearSourceReloadFailure(failure.digest);
        }
        if (applied.auto_reload_failure) |failure| {
            self.page_state.status.setSourceReloadFailure(
                failure.identity.digest,
                "auto reload failed: {s}",
                .{failure.message},
            );
        }
        if (self.active_page != .changes) {
            self.redraw.requestSkip();
            return;
        }
        switch (applied.redraw) {
            .normal => {},
            .skip => self.redraw.requestSkip(),
            .skip_unless_recovered_failure_cleared => if (!recovered_failure_cleared) self.redraw.requestSkip(),
        }
    }

    pub fn finishStatusLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: StatusLoadFinished,
    ) !void {
        var result = finished;
        defer result.deinit(allocator);

        const action_completion = self.page_state.action_cursor.captureCompletion(
            result.identity.repo_epoch,
            .status,
            result.generation,
        );
        errdefer if (action_completion) |completion| {
            _ = self.finishActionCursorCompletion(allocator, completion, false) catch false;
        };

        const applied = try self.reloadOwner().applyStatusFinished(
            allocator,
            &result,
            self.fence.blocksBackgroundAcceptance(result.background_cycle_id),
        );
        if (applied.project_status) |prefer_first| {
            try self.reloadOwner().applyStatusProjection(allocator, prefer_first, .accepted_status);
        }
        const finalized_action_cursor = if (!applied.terminal_admitted)
            false
        else if (action_completion) |completion| blk: {
            const status_succeeded = switch (result.result) {
                .empty, .loaded => true,
                .failed, .failed_static => false,
            };
            break :blk try self.finishActionCursorCompletion(allocator, completion, status_succeeded);
        } else false;
        if (applied.diagnostic) |diagnostic| switch (diagnostic) {
            .status_load_failed => |message| self.setStatus("status load failed: {s}", .{message}),
            else => unreachable,
        };
        if ((applied.skip_redraw and !finalized_action_cursor) or self.active_page != .changes) self.redraw.requestSkip();
    }

    pub fn finishBranchStatusLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: BranchStatusLoadFinished,
    ) void {
        var result = finished;
        defer result.deinit(allocator);
        const applied = self.reloadOwner().applyBranchStatusFinished(
            &result,
            self.fence.blocksBackgroundAcceptance(result.background_cycle_id),
        );
        if (applied.diagnostic) |diagnostic| switch (diagnostic) {
            .branch_status_load_failed => |message| self.setStatus("branch status load failed: {s}", .{message}),
            .branch_status_parse_failed => self.setStatus("branch status parse failed", .{}),
            else => unreachable,
        };
        if (applied.skip_redraw or self.active_page != .changes) self.redraw.requestSkip();
    }

    pub fn finishProjectionLoad(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: ChangesProjectionFinished,
    ) !void {
        var result = finished;
        var result_transferred = false;
        defer if (!result_transferred) result.deinit(allocator);
        const applied = try self.reloadOwner().applyProjectionFinished(allocator, &result);
        result_transferred = applied.result_transferred;
        if (applied.skip_redraw or self.active_page != .changes) self.redraw.requestSkip();
    }

    pub fn finishGeneratedProjectionSyntax(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: app_changes_projection.GeneratedSyntaxFinished,
    ) void {
        var result = finished;
        defer result.deinit(allocator);
        const applied = self.reloadOwner().applyGeneratedSyntaxFinished(allocator, &result);
        if (applied.skip_redraw or self.active_page != .changes) self.redraw.requestSkip();
    }
};

pub const testing = if (builtin.is_test) struct {
    pub const StartOptions = struct {
        clear_visible_state: bool,
        kind: changes_page.ReloadKind,
        background_cycle_id: ?u64 = null,
        action_cursor_generation: ?u64 = null,
    };

    pub fn readBusy(controller: Controller) bool {
        return controller.readBusy();
    }

    pub fn startDiffLoadWithRepoRoot(
        controller: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_root: ?[]const u8,
        options: StartOptions,
    ) !void {
        return controller.startDiffLoadWithRepoRoot(ctx, repo_root, .{
            .clear_visible_state = options.clear_visible_state,
            .kind = options.kind,
            .background_cycle_id = options.background_cycle_id,
            .action_cursor_generation = options.action_cursor_generation,
        });
    }

    pub fn startStatusLoadTracked(
        controller: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_root: []const u8,
        origin: git_read.ReadOrigin,
        background_cycle_id: ?u64,
        action_cursor_generation: ?u64,
    ) !app_auto_reload.AuxiliaryTerminal {
        return controller.startStatusLoadTracked(
            ctx,
            repo_root,
            origin,
            background_cycle_id,
            action_cursor_generation,
        );
    }

    pub fn startBranchStatusLoad(
        controller: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        repo_root: []const u8,
        background_cycle_id: ?u64,
    ) ?app_auto_reload.AuxiliaryTerminal {
        return controller.startBranchStatusLoad(ctx, repo_root, background_cycle_id);
    }
} else struct {};
