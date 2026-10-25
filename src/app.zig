//! Root application shell.
//!
//! `App` owns state composition, the Chasen lifecycle, exhaustive root message
//! dispatch, cross-owner outcome bridges, and process-facing boundaries. Page,
//! workflow, read, input, and foreground-effect details live in lower modules;
//! those modules consume short-lived typed views/controllers and never import
//! this root back.

const std = @import("std");
const screen_transition = @import("app/screen_transition.zig");
const chasen = @import("chasen");
const initial_selection = @import("app/initial_selection.zig");
const command_line = @import("app/command_line.zig");
const app_load = @import("app/load.zig");
const app_message = @import("app/message.zig");
const drag_auto_scroll = @import("app/drag_auto_scroll.zig");
const page = @import("app/page.zig");
const page_coordinator = @import("app/page_coordinator.zig");
const shell_input = @import("app/shell_input.zig");
const app_shell_layout = @import("app/shell_layout.zig");
const compare_page = @import("app/pages/compare.zig");
const compare_coordinator = @import("app/pages/compare/coordinator.zig");
const compare_input = @import("app/pages/compare/input.zig");
const committed_diff_navigation = @import("app/pages/committed_diff/navigation.zig");
const changes_page = @import("app/pages/changes.zig");
const changes_content = @import("app/pages/changes/content.zig");
const changes_action_fence = @import("app/pages/changes/action_fence.zig");
const changes_message = @import("app/pages/changes/message.zig");
const changes_navigation = @import("app/pages/changes/navigation.zig");
const changes_operations = @import("app/pages/changes/operations.zig");
const changes_read = @import("app/pages/changes/read_coordinator.zig");
const changes_page_update = @import("app/pages/changes/update.zig");
const changes_view = @import("app/pages/changes/view.zig");
const repository_page = @import("app/pages/repository.zig");
const repository_coordinator = @import("app/pages/repository/coordinator.zig");
const repository_layout = @import("app/pages/repository/layout.zig");
const history_page = @import("app/pages/history.zig");
const history_coordinator = @import("app/pages/history/coordinator.zig");
const history_view = @import("app/pages/history/view.zig");
const repo_session = @import("app/repo_session.zig");
const app_state = @import("app/state.zig");
const app_view = @import("app/view.zig");
const action_lifecycle = @import("app/workflow/action_lifecycle.zig");
const workflow_local = @import("app/workflow/local.zig");
const workflow_remote = @import("app/workflow/remote.zig");
const workflow_stash = @import("app/workflow/stash.zig");
const shell_effects = @import("app/shell_effects.zig");
const context = @import("context.zig");
const config_mod = @import("config.zig");
const diff_surface = @import("app/diff_surface.zig");
const diff_render = @import("diff/render.zig");
const diff_selection = @import("diff/selection.zig");
const diff_source = @import("diff/source.zig");
const keymap = @import("keymap");
const theme = @import("theme");

const auto_reload = @import("app/auto_reload.zig");
const CliConfig = diff_source.CliConfig;

const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const LoadFinishedMsg = app_message.LoadFinished;
const ActionFinishedMsg = app_message.ActionFinished;
const ShellEffectFinishedMsg = app_message.ShellEffectFinished;

const PageStates = struct {
    changes: changes_page.ChangesPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    history: history_page.HistoryPageState = .{},
    compare: compare_page.ComparePageState = .{},
};

const ExecutionContext = union(enum) {
    repository_source: repository_page.SourceTarget,
};

const CommandSession = union(enum) {
    inactive,
    active: struct {
        input: command_line.Active,
        context: ExecutionContext,
    },
};

const PendingCommand = struct {
    submission: command_line.Submission,
    context: ExecutionContext,
};

/// Composition of redraw intent for one update cycle: a required frame
/// always wins over any number of skip requests, and silence means redraw
/// (the runtime default).
pub const RedrawPlan = struct {
    skip_requested: bool = false,
    frame_required: bool = false,

    pub fn requestSkip(self: *RedrawPlan) void {
        self.skip_requested = true;
    }

    pub fn requireFrame(self: *RedrawPlan) void {
        self.frame_required = true;
    }

    pub fn resolvesToSkip(self: RedrawPlan) bool {
        return self.skip_requested and !self.frame_required;
    }
};

pub const App = struct {
    active_page: page.Id = .changes,
    repo_session: repo_session.State = .{},
    pages: PageStates = .{},
    config: CliConfig = .{},
    user_config: config_mod.Config = .{},
    keymap: keymap.Effective = .{},
    theme: theme.Palette = .default(),
    env_map: ?*std.process.Environ.Map = null,
    /// Absolute running executable path borrowed from the startup arena.
    executable_path: ?[]const u8 = null,
    /// Set immediately before handing terminal ownership to Chasen teardown.
    /// The event loop normally stops at once; retaining the bit also makes the
    /// transition matrix total for direct/future Session API requests.
    teardown_requested: bool = false,
    allocator: ?std.mem.Allocator = null,
    terminal_size: chasen.Size = .{ .width = 0, .height = 0 },
    /// Per-update redraw disposition owned by this root orchestrator.
    /// Handlers and tail code record intent; `update` resets the plan on
    /// entry and applies the resolved decision to the runtime exactly once.
    redraw_plan: RedrawPlan = .{},
    action_runtime: action_lifecycle.ActionRuntime = .{},
    status: app_state.StatusMessage = .{},
    local_workflow: workflow_local.LocalState = .{},
    remote_workflow: workflow_remote.State = .{},
    stash_workflow: workflow_stash.State = .{},
    overlay: app_state.OverlayState = .{},
    shell_effects_state: shell_effects.State = .{},
    drag_auto_scroll: drag_auto_scroll.State = .{},
    command_session: CommandSession = .inactive,
    screen_transition: screen_transition.State = .idle,

    const PopupCopyTarget = struct {
        label: []const u8,
        text: []const u8,
    };

    pub const Msg = app_message.Msg;

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
        self.local_workflow = workflow_local.LocalState.init(ctx.allocator());
        self.pages.changes.init(self.config.auto_reload, self.user_config.reload);
        _ = self.pageCoordinator().activateChanges();
        if (self.config.transitions) self.screen_transition.arm(self.transitionIdentity().?);
        if (self.pages.changes.auto_reload.enabled()) {
            ctx.timer().every(auto_reload.timer_id, self.pages.changes.auto_reload.interval_ns, .auto_reload, auto_reload.timerNotice) catch {
                self.autoReloadTimerFailed();
            };
        }
        if (diff_source.sourceRequiresRepo(self.config.source)) {
            try self.changesRead().startRepoDiscovery(ctx, null);
        } else {
            try self.changesRead().startDiffLoad(ctx, .initial);
        }
    }

    fn autoReloadTimerFailed(self: *App) void {
        self.pages.changes.auto_reload.timerFailed();
        self.status.set("Automatic reload unavailable; use manual reload", .{});
    }

    pub fn deinit(self: *App, deinit_ctx: chasen.AppDeinitContext) void {
        _ = self.screen_transition.cancel();
        if (self.allocator == null) self.allocator = deinit_ctx.allocator;
        self.pages.changes.deinit(deinit_ctx.allocator);
        self.pages.repository.deinit(deinit_ctx.allocator);
        self.pages.history.deinit(deinit_ctx.allocator);
        self.pages.compare.deinit(deinit_ctx.allocator);
        self.repo_session.deinit(deinit_ctx.allocator);
        self.local_workflow.deinit(deinit_ctx.allocator);
        self.remote_workflow.deinit(deinit_ctx.allocator);
        self.stash_workflow.deinit(deinit_ctx.allocator);
        self.shell_effects_state.deinit(deinit_ctx.allocator);
    }

    fn repoSessionView(self: *const App) repo_session.View {
        return self.repo_session.view();
    }

    fn repoSession(self: *App) repo_session.Controller {
        const home = if (self.env_map) |map| blk: {
            const value = map.get("HOME") orelse break :blk null;
            break :blk if (value.len == 0) null else value;
        } else null;
        return .{
            .state = &self.repo_session,
            .status = &self.status,
            .active_page = self.active_page,
            .source = self.config.source,
            .home = home,
            .env_map = self.env_map,
            .action_pending = self.actionLifecycleView().hasPending() or self.overlay.isCreateStash() or self.overlay.isStashes(),
            .changes = self.changesRead().repositorySessionPort(),
            .repository = .{ .page = &self.pages.repository },
            .history = .{ .page = &self.pages.history },
            .compare = .{ .page = &self.pages.compare },
            .shell = self.remote_workflow.repositoryInvalidationPort(&self.overlay),
        };
    }

    fn repositoryCoordinator(self: *App) repository_coordinator.Controller {
        return .{
            .page_state = &self.pages.repository,
            .active_page = self.active_page,
            .repo = self.repoSessionView(),
            .body_size = self.shellLayout().bodySize(),
            .env_map = self.env_map,
        };
    }

    fn historyCoordinator(self: *App) history_coordinator.Controller {
        const body_size = self.shellLayout().bodySize();
        return .{
            .page_state = &self.pages.history,
            .active_page = self.active_page,
            .repo = self.repoSessionView(),
            .body_size = body_size,
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.history),
            .env_map = self.env_map,
        };
    }

    fn compareCoordinator(self: *App) compare_coordinator.Controller {
        const body_size = self.shellLayout().bodySize();
        return .{
            .page_state = &self.pages.compare,
            .repo = self.repoSessionView(),
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.compare),
            .env_map = self.env_map,
        };
    }

    fn pageCoordinator(self: *App) page_coordinator.Controller {
        return .{
            .active_page = &self.active_page,
            .changes = &self.pages.changes,
            .repository = &self.pages.repository,
            .history = &self.pages.history,
            .compare = &self.pages.compare,
            .repo = self.repoSessionView(),
            .source = self.config.source,
            .body_size = self.shellLayout().bodySize(),
            .status = &self.status,
            .shell_blockers = .{
                .help = self.overlay.isHelp(),
                .commit_input = self.localWorkflowView().commitPanelOpen(),
                .confirmation = self.overlay.isDiscardFile() or self.overlay.isAmendCommit() or
                    self.overlay.isPushBranch() or self.overlay.isPullBranch() or self.overlay.isCreateStash() or self.overlay.isStashes(),
                .branch_switch = self.overlay.isSwitchBranch(),
                .remote_error = self.overlay.isRemoteError(),
                .git_action = self.actionLifecycleView().hasPending(),
                .foreground_command = self.remoteWorkflowView().hasForeground() or self.shellEffectsView().hasEditorForeground(),
                .teardown = self.teardown_requested,
            },
        };
    }

    fn applyPageCoordinationIntent(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        intent: page_coordinator.Intent,
    ) !void {
        switch (intent) {
            .none => {},
            .changes_revalidation => try self.changesRead().requestRevalidation(ctx),
            .changes_repository_changed => try self.changesRead().startDiffLoad(ctx, .repo_switch),
            .history_refresh => _ = try self.historyCoordinator().startPending(ctx),
            .compare_refresh => try self.compareCoordinator().refresh(ctx),
        }
    }

    /// Builds the concrete Changes navigation owner with only the shell inputs
    /// needed by Changes-local cursor/search/selection logic. The controller
    /// deliberately cannot reach App, overlays, processes, or async effects.
    fn changesNavigation(self: *App) changes_navigation.Controller {
        const size = self.shellLayout().bodySize();
        return .{
            .page = &self.pages.changes,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = .{ .width = size.width, .height = size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.changes),
            .diagnostics = .{ .target = &self.pages.changes.status },
        };
    }

    fn changesNavigationView(self: *const App) changes_navigation.View {
        const size = self.shellLayout().bodySize();
        return .{
            .page = &self.pages.changes,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = .{ .width = size.width, .height = size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.changes),
        };
    }

    fn displayModeToggleHintWidth(self: *const App, target: page.Id) u16 {
        const reachable = switch (target) {
            .changes => !self.pages.changes.search.mode and !self.pages.changes.file_search.mode,
            .compare => !self.pages.compare.diff.search.mode and
                !self.pages.compare.diff.file_search.mode and
                !self.pages.compare.base_picker.open,
            .history => self.pages.history.current_view == .diff and
                !self.pages.history.diff.search.mode and
                !self.pages.history.diff.file_search.mode,
            .repository => false,
        };
        if (!reachable) return 0;

        var key_buffer: [16]u8 = undefined;
        return diff_render.modeToggleHintWidth(
            self.keymap.display(.toggle_display_mode, key_buffer[0..]),
        );
    }

    fn changesOperations(self: *const App) changes_operations.View {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.changes.activation.state,
        };
    }

    fn changesContent(self: *const App) changes_content.View {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
        };
    }

    fn changesOperationController(self: *App) changes_operations.Controller {
        return .{
            .page = &self.pages.changes,
            .navigation = self.changesNavigation(),
            .view_state = self.changesOperations(),
        };
    }

    fn changesActionFence(self: *App) changes_action_fence.Controller {
        return .{
            .read_authority = &self.pages.changes.repository_read_authority,
            .activation = &self.pages.changes.activation,
            .action_cursor = &self.pages.changes.action_cursor,
            .auto_reload = &self.pages.changes.auto_reload,
            .changes_projection = &self.pages.changes.changes_projection,
            .deferred_projection_apply = &self.pages.changes.deferred_projection_apply,
        };
    }

    fn actionLifecycleView(self: *const App) action_lifecycle.View {
        return self.action_runtime.view();
    }

    fn actionLifecycle(self: *App) action_lifecycle.Controller {
        return .{
            .runtime = &self.action_runtime,
            .fence = self.changesActionFence(),
        };
    }

    fn localWorkflowView(self: *const App) workflow_local.View {
        return self.local_workflow.view();
    }

    fn localWorkflow(self: *App) workflow_local.Controller {
        return .{
            .state = &self.local_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.changesOperationController(),
            .repo = self.repoSessionView(),
            .current_changes_root = self.currentChangesActionRoot(),
            .env_map = self.env_map,
            .status = &self.pages.changes.status,
            .overlay = &self.overlay,
        };
    }

    fn stashWorkflow(self: *App) workflow_stash.Controller {
        return .{
            .state = &self.stash_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.changesOperationController(),
            .repo = self.repoSessionView(),
            .current_changes_root = self.currentChangesActionRoot(),
            .may_open = self.active_page == .changes and
                !self.localWorkflowView().commitPanelOpen() and !self.repoSessionView().picker().model.mode and
                !self.pages.changes.search.mode and !self.pages.changes.file_search.mode and
                self.pages.changes.selection_owner == .none,
            .env_map = self.env_map,
            .status = &self.pages.changes.status,
            .overlay = &self.overlay,
        };
    }

    fn remoteWorkflowView(self: *const App) workflow_remote.View {
        return .{ .state = &self.remote_workflow };
    }

    fn remoteWorkflow(self: *App) workflow_remote.Controller {
        const origins = self.shellEffectOrigins();
        return .{
            .state = &self.remote_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.changesOperationController(),
            .remote_context = if (self.active_page == .repository) self.pages.repository.remoteActionContext(self.repoSessionView().activeRoot(), self.repoSessionView().epoch(), self.repoSessionView().activeIdentity()) else self.changesOperationController().view().remoteActionContext(),
            .repo = self.repoSessionView(),
            .current_changes_root = self.currentChangesActionRoot(),
            .env_map = self.env_map,
            .active_page = self.active_page,
            .branch_origin = switch (self.active_page) {
                .changes => origins.changes(),
                .repository => origins.repository(),
                .history => origins.history(),
                .compare => origins.compare(),
            },
            .repository_status = &self.pages.repository.status,
            .history_status = &self.pages.history.status,
            .compare_status = &self.pages.compare.status,
            .effect_snapshot = origins.snapshot,
            .status = &self.pages.changes.status,
            .overlay = &self.overlay,
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn shellEffectsView(self: *const App) shell_effects.View {
        return self.shell_effects_state.view();
    }

    fn shellEffectOrigins(self: *const App) shell_effects.OriginContext {
        const repo_epoch = self.repoSessionView().epoch();
        const changes_identity = self.pages.changes.activation.currentIdentity();
        const history_identity = self.pages.history.activation.currentIdentity();
        const compare_identity = self.pages.compare.activation.currentIdentity();
        return .{
            .snapshot = .{
                .active_page = self.active_page,
                .repo_epoch = repo_epoch,
                .changes_activation_id = self.pages.changes.activation.next_activation_id,
                .repository_activation_id = self.pages.repository.activation_id,
                .history_activation_id = self.pages.history.activation.next_activation_id,
                .compare_activation_id = self.pages.compare.activation.next_activation_id,
                .history_preview = if (self.pages.history.preview_state.currentCopyAuthority()) |authority| .{
                    .selection_generation = authority.selection_generation,
                    .copy_generation = authority.copy_generation,
                } else null,
                .remote_error_instance_id = if (self.overlay.isRemoteError()) self.overlay.remote_error_instance_id else null,
                .commit_panel_instance_id = self.localWorkflowView().commitPanelInstanceId(),
            },
            .changes_repo_epoch = if (changes_identity) |identity| identity.repo_epoch else repo_epoch,
            .repository_repo_epoch = self.pages.repository.repo_epoch,
            .history_repo_epoch = if (history_identity) |identity| identity.repo_epoch else self.pages.history.repo_epoch,
            .compare_repo_epoch = if (compare_identity) |identity| identity.repo_epoch else repo_epoch,
        };
    }

    fn shellEffects(self: *App) shell_effects.Controller {
        return .{
            .state = &self.shell_effects_state,
            .user_config = &self.user_config,
            .env_map = self.env_map,
            .origins = self.shellEffectOrigins(),
            .diagnostics = .{
                .shell = &self.status,
                .changes = &self.pages.changes.status,
                .repository = &self.pages.repository.status,
                .history = &self.pages.history.status,
                .compare = &self.pages.compare.status,
            },
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn currentChangesActionRoot(self: *const App) ?[]const u8 {
        if (self.active_page != .changes or
            self.pages.changes.activation.currentIdentity() == null) return null;
        return self.repoSessionView().activeRoot();
    }

    fn changesRead(self: *App) changes_read.Controller {
        const body_size = self.shellLayout().bodySize();
        return .{
            .page_state = &self.pages.changes,
            .fence = self.changesActionFence().view(),
            .active_page = self.active_page,
            .repo = self.repoSessionView(),
            .source = self.config.source,
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .env_map = self.env_map,
            .allocator = self.allocator,
            .redraw = .{
                .skip_requested = &self.redraw_plan.skip_requested,
                .frame_required = &self.redraw_plan.frame_required,
            },
            .shell_blockers = .{
                .commit_panel = self.localWorkflowView().commitPanelOpen(),
                .action_pending = self.actionLifecycleView().hasPending(),
            },
        };
    }

    pub fn update(self: *App, incoming: Msg, ctx: *chasen.Ctx(Msg)) !void {
        self.redraw_plan = .{};
        self.clearTransitionPublications();
        errdefer {
            _ = self.screen_transition.cancel();
            self.clearTransitionPublications();
        }
        const msg = if (incoming == .transition_input) blk: {
            if (self.screen_transition.cancel()) self.redraw_plan.requireFrame();
            break :blk self.shellInputView().handleEvent(incoming.transition_input) orelse .transition_cancel;
        } else incoming;
        const interrupts_transition = switch (msg) {
            .terminal_resized => |size| self.terminal_size.width != 0 and !std.meta.eql(size, self.terminal_size),
            .focus_lost => true,
            .mouse_selection_drag, .mouse_selection_release => false,
            else => !app_message.keepsEphemeralStatus(msg),
        };
        if (interrupts_transition and self.screen_transition.cancel()) self.redraw_plan.requireFrame();
        var update_succeeded = false;
        defer if (update_succeeded and self.redraw_plan.resolvesToSkip()) ctx.redraw().skip();
        defer self.reconcileDragAutoScroll(ctx);
        if (self.clearEphemeralStatusForUserAction(msg)) self.redraw_plan.requireFrame();

        switch (msg) {
            .transition_input => unreachable,
            .transition_cancel => {},
            .transition_frame => {
                if (self.screen_transition.step()) self.redraw_plan.requireFrame() else self.redraw_plan.requestSkip();
                if (self.screen_transition == .running) ctx.frame().request();
            },
            .switch_page => |target| {
                self.drag_auto_scroll.clear();
                self.command_session = .inactive;
                try self.applyPageCoordinationIntent(
                    ctx,
                    self.pageCoordinator().requestSwitch(self.allocator orelse ctx.allocator(), target),
                );
            },
            .terminal_resized => |size| {
                // Mouse coordinates are relative to the old geometry. End the
                // borrow before changing layout, then drain deferred owners at
                // the common post-update boundary below.
                var previous_changes_adapter = self.changesNavigation().updateAdapter();
                const previous_changes_body = previous_changes_adapter.bodyController();
                var previous_compare_adapter = self.compareCoordinator().navigation().updateAdapter();
                const previous_compare_body = previous_compare_adapter.bodyController();
                var previous_history_adapter = self.historyCoordinator().navigation().updateAdapter();
                const previous_history_body = previous_history_adapter.bodyController();
                const changes_selection_anchor = previous_changes_body.captureSelectionViewportAnchor();
                const compare_selection_anchor = previous_compare_body.captureSelectionViewportAnchor();
                const history_selection_anchor = previous_history_body.captureSelectionViewportAnchor();
                const repository_selection_anchor = self.pages.repository.captureSelectionViewportAnchor();
                const previous_width = previous_changes_body.controller.view().diffPaneWidth();
                const previous_mode = previous_changes_body.controller.view().effectiveDisplayMode();
                const previous_compare_width = previous_compare_body.controller.view().diffPaneWidth();
                const previous_compare_mode = previous_compare_body.controller.view().effectiveDisplayMode();
                const previous_history_width = previous_history_body.controller.view().diffPaneWidth();
                const previous_history_mode = previous_history_body.controller.view().effectiveDisplayMode();
                const next_body_size = app_shell_layout.compute(size, .{ .page_bar_visible = true }).bodySize();
                const next_layout: diff_surface.Layout = .{ .width = next_body_size.width, .height = next_body_size.height };
                const changes_mode_changes = previous_mode != diff_surface.navigation.effectiveDisplayModeForLayout(
                    &self.pages.changes.viewer,
                    next_layout,
                );
                const compare_mode_changes = previous_compare_mode != diff_surface.navigation.effectiveDisplayModeForLayout(
                    &self.pages.compare.diff.viewer,
                    next_layout,
                );
                const history_mode_changes = previous_history_mode != diff_surface.navigation.effectiveDisplayModeForLayout(
                    &self.pages.history.diff.viewer,
                    next_layout,
                );
                const needs_mapping_allocator =
                    (changes_mode_changes and self.pages.changes.completed_selection != null) or
                    (compare_mode_changes and self.pages.compare.diff.completed_selection != null) or
                    (history_mode_changes and self.pages.history.diff.completed_selection != null);
                const allocator = self.allocator orelse if (needs_mapping_allocator)
                    ctx.allocator()
                else
                    std.heap.page_allocator;
                const changes_cleanup = previous_changes_adapter.selectionMappingCleanup(allocator);
                const compare_cleanup = previous_compare_adapter.selectionMappingCleanup(allocator);
                const history_cleanup = previous_history_adapter.selectionMappingCleanup(allocator);
                const changes_mapping = if (changes_mode_changes)
                    changes_cleanup.prepare(previous_changes_body)
                else
                    null;
                const compare_mapping = if (compare_mode_changes)
                    compare_cleanup.prepare(previous_compare_body)
                else
                    null;
                const history_mapping = if (history_mode_changes)
                    history_cleanup.prepare(previous_history_body)
                else
                    null;

                self.drag_auto_scroll.clear();
                if (!changes_mode_changes) previous_changes_body.controller.clearMouseDiffSelection();
                if (!compare_mode_changes) previous_compare_body.controller.clearMouseDiffSelection();
                if (!history_mode_changes) previous_history_body.controller.clearMouseDiffSelection();
                self.pages.repository.cancelMouseOwner();
                self.terminal_size = size;
                try self.historyCoordinator().reflowPreview(allocator);
                var changes_adapter = self.changesNavigation().updateAdapter();
                var changes_body = changes_adapter.bodyController();
                changes_body.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
                if (changes_mapping) |prepared|
                    changes_cleanup.complete(changes_body, prepared)
                else if (changes_selection_anchor) |anchor|
                    changes_body.restoreSelectionViewportAnchor(anchor);
                changes_body.controller.clampSidebarHorizontalScroll();
                changes_body.clampDiffNavigationKeepingHunkVisible();
                changes_body.updateSearchMatchOffset();
                changes_body.controller.scrollSearchMatchIntoView();
                changes_body.clampDiffNavigation();
                var compare_adapter = self.compareCoordinator().navigation().updateAdapter();
                var compare_body = compare_adapter.bodyController();
                compare_body.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_compare_width);
                if (compare_mapping) |prepared|
                    compare_cleanup.complete(compare_body, prepared)
                else if (compare_selection_anchor) |anchor|
                    compare_body.restoreSelectionViewportAnchor(anchor);
                compare_body.controller.clampSidebarHorizontalScroll();
                compare_body.clampDiffNavigationKeepingHunkVisible();
                compare_body.updateSearchMatchOffset();
                compare_body.controller.scrollSearchMatchIntoView();
                compare_body.clampDiffNavigation();
                var history_adapter = self.historyCoordinator().navigation().updateAdapter();
                var history_body = history_adapter.bodyController();
                history_body.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_history_width);
                if (history_mapping) |prepared|
                    history_cleanup.complete(history_body, prepared)
                else if (history_selection_anchor) |anchor|
                    history_body.restoreSelectionViewportAnchor(anchor);
                history_body.controller.clampSidebarHorizontalScroll();
                history_body.clampDiffNavigationKeepingHunkVisible();
                history_body.updateSearchMatchOffset();
                history_body.controller.scrollSearchMatchIntoView();
                history_body.clampDiffNavigation();
                const repository_body_size = self.shellLayout().bodySize();
                if (repository_selection_anchor) |anchor|
                    self.pages.repository.restoreSelectionViewportAnchor(anchor, repository_body_size)
                else
                    self.pages.repository.clampForBodySize(repository_body_size);
                self.pages.history.catalog.clamp(@import("app/pages/history/catalog.zig").visibleRows(repository_body_size.height));
                self.overlayScroll().clampHelp();
                self.overlayScroll().clampRemoteError();
            },
            .load_finished => |finished| try self.finishLoadResult(ctx, finished),
            .action_finished => |finished| try self.finishActionResult(ctx, finished),
            .push_inspection_finished => |finished| try self.remoteWorkflow().finishPushInspection(ctx, finished),
            .push_upstream_finalize_finished => |finished| try self.applyRemoteOutcome(
                ctx,
                self.remoteWorkflow().finishPushUpstreamFinalize(ctx.allocator(), finished),
            ),
            .shell_effect_finished => |finished| try self.finishShellEffect(ctx, finished),
            .changes => |changes_msg| _ = try self.updateChanges(ctx, changes_msg),
            .compare => |compare_msg| _ = try self.updateCompare(ctx, compare_msg),
            .repository => |repository_msg| _ = try self.updateRepository(ctx, repository_msg),
            .history => |history_msg| _ = try self.updateHistory(ctx, history_msg),
            .command_line => |command_msg| self.updateCommandLine(command_msg),
            .stash => |stash_msg| try self.stashWorkflow().update(ctx, stash_msg),
            .mouse_selection_drag => |continuation| try self.updateMouseSelectionDrag(ctx, continuation),
            .mouse_selection_release => |continuation| try self.updateMouseSelectionRelease(ctx, continuation),
            .drag_auto_scroll_tick => |generation| try self.updateDragAutoScrollTick(ctx, generation),
            .drag_auto_scroll_timer_failed => |generation| self.drag_auto_scroll.timerFailed(generation),
            .cancel_commit_panel => self.localWorkflow().closeCommitPanel(),
            .submit_commit_panel => {
                if (self.localWorkflowView().commitPanel().mode == .amend) {
                    self.remoteWorkflow().cancelPushConfirmation(ctx.allocator());
                    self.remoteWorkflow().cancelPullConfirmation(ctx.allocator());
                }
                try self.localWorkflow().submitCommitPanel(ctx);
            },
            .copy_commit_message => self.copyCommitMessage(ctx),
            .commit_panel_tab => self.localWorkflow().toggleCommitPanelField(),
            .commit_panel_enter => self.localWorkflow().commitPanelEnter(),
            .commit_panel_insert => |codepoint| self.localWorkflow().commitPanelInsert(codepoint),
            .commit_panel_paste => |text| self.localWorkflow().commitPanelPaste(text),
            .commit_panel_backspace => self.localWorkflow().commitPanelBackspace(),
            .commit_panel_move_left => self.localWorkflow().commitPanelMoveLeft(),
            .commit_panel_move_right => self.localWorkflow().commitPanelMoveRight(),
            .commit_panel_move_up => self.localWorkflow().commitPanelMoveUp(),
            .commit_panel_move_down => self.localWorkflow().commitPanelMoveDown(),
            .enter_repo_picker => {
                self.drag_auto_scroll.clear();
                if (self.active_page == .repository) {
                    self.pages.repository.clearLiveSelectionPreservingViewport(self.shellLayout().bodySize());
                }
                try self.repoSession().enterPicker(ctx.allocator());
            },
            .cancel_repo_picker => try self.repoSession().cancelPicker(ctx.allocator()),
            .close_repo_picker => self.repoSession().closePicker(ctx.allocator()),
            .submit_repo_picker => {
                if (try self.repoSession().submitPicker(ctx)) |outcome| {
                    try self.applyRepoSessionCommit(ctx, outcome, true);
                }
            },
            .repo_picker_enter_filter_input => try self.repoSession().enterPickerFilterInput(ctx.allocator()),
            .repo_picker_enter_path_input => self.repoSession().enterPickerPathInput(),
            .repo_picker_back => try self.repoSession().backPicker(ctx.allocator()),
            .repo_picker_remove_recent => try self.repoSession().removeSelectedRecent(ctx),
            .repo_picker_insert => |codepoint| {
                try self.repoSession().insertPickerCodepoint(ctx.allocator(), codepoint);
            },
            .repo_picker_paste => |text| {
                try self.repoSession().insertPickerSlice(ctx.allocator(), text);
            },
            .repo_picker_backspace => {
                try self.repoSession().backspacePicker(ctx.allocator());
            },
            .repo_picker_move_previous => self.repoSession().movePickerPrevious(),
            .repo_picker_move_next => self.repoSession().movePickerNext(),
            .repo_picker_move_left => self.repoSession().movePickerCursorLeft(),
            .repo_picker_move_right => self.repoSession().movePickerCursorRight(),
            .open_help => {
                self.drag_auto_scroll.clear();
                if (self.active_page == .changes) self.changesNavigation().clearMouseDiffSelection();
                if (self.active_page == .compare and self.pages.compare.diff.selection_owner.activeMouseSelection()) {
                    self.pages.compare.diff.selection_owner = .none;
                }
                if (self.active_page == .history and self.pages.history.diff.selection_owner.activeMouseSelection()) {
                    self.pages.history.diff.selection_owner = .none;
                }
                if (self.active_page == .repository) {
                    self.pages.repository.clearLiveSelectionPreservingViewport(self.shellLayout().bodySize());
                }
                self.overlay.openHelpForPage(self.active_page);
            },
            .close_help => self.overlay.close(),
            .help_scroll_up => if (!self.overlayScroll().scrollHelp(-1)) self.redraw_plan.requestSkip(),
            .help_scroll_down => if (!self.overlayScroll().scrollHelp(1)) self.redraw_plan.requestSkip(),
            .help_page_up => self.overlayScroll().pageHelp(-1),
            .help_page_down => self.overlayScroll().pageHelp(1),
            .remote_error_scroll_up => if (!self.overlayScroll().scrollRemoteError(-1)) self.redraw_plan.requestSkip(),
            .remote_error_scroll_down => if (!self.overlayScroll().scrollRemoteError(1)) self.redraw_plan.requestSkip(),
            .remote_error_page_up => self.overlayScroll().pageRemoteError(-1),
            .remote_error_page_down => self.overlayScroll().pageRemoteError(1),
            .copy_popup => self.copyPopup(ctx),
            .copy_footer_status => self.copyFooterStatus(ctx),
            .confirm_discard_file => try self.localWorkflow().confirmDiscardFile(ctx),
            .cancel_discard_file => self.localWorkflow().cancelDiscardConfirmation(ctx.allocator()),
            .confirm_amend => try self.localWorkflow().confirmAmend(ctx),
            .cancel_amend => self.localWorkflow().cancelAmendConfirmation(ctx.allocator()),
            .confirm_push => try self.remoteWorkflow().confirmPush(ctx),
            .cancel_push => self.remoteWorkflow().cancelPushConfirmation(ctx.allocator()),
            .confirm_pull => try self.remoteWorkflow().confirmPull(ctx),
            .cancel_pull => self.remoteWorkflow().cancelPullConfirmation(ctx.allocator()),
            .branch_switch_move_previous => self.remoteWorkflow().moveBranchSwitchSelection(-1),
            .branch_switch_move_next => self.remoteWorkflow().moveBranchSwitchSelection(1),
            .branch_switch_enter_query => self.remoteWorkflow().editBranchSwitchQuery(ctx.allocator(), .enter),
            .branch_switch_leave_query => self.remoteWorkflow().editBranchSwitchQuery(ctx.allocator(), .leave),
            .branch_switch_clear_query => self.remoteWorkflow().editBranchSwitchQuery(ctx.allocator(), .clear),
            .branch_switch_insert => |codepoint| self.remoteWorkflow().editBranchSwitchQuery(ctx.allocator(), .{ .insert = codepoint }),
            .branch_switch_backspace => self.remoteWorkflow().editBranchSwitchQuery(ctx.allocator(), .backspace),
            .request_branch_switch => try self.requestRemoteBranchSwitch(ctx),
            .confirm_branch_switch => try self.remoteWorkflow().confirmBranchSwitch(ctx),
            .cancel_branch_switch => self.remoteWorkflow().clearBranchSwitch(ctx.allocator()),
            .close_remote_error => {
                const return_to_stashes = self.remote_workflow.remote_error_operation == .drop_stash;
                self.remoteWorkflow().clearRemoteError(ctx.allocator());
                if (return_to_stashes) self.stashWorkflow().restoreList(ctx.allocator());
            },
            .run_interactive_push => try self.remoteWorkflow().runInteractivePush(ctx),
            .reload => switch (self.active_page) {
                .changes => {
                    switch (self.changesRead().prepareManualReload()) {
                        .blocked => {},
                        .ready => {
                            self.remoteWorkflow().clearBranchSwitch(ctx.allocator());
                            try self.changesRead().startPreparedManualReload(ctx);
                        },
                    }
                },
                .repository => self.repositoryCoordinator().requestReload(.manual),
                .history => self.historyCoordinator().refresh(self.allocator orelse ctx.allocator()),
                .compare => try self.compareCoordinator().refresh(ctx),
            },
            .auto_reload_tick => try self.changesRead().autoReloadTick(ctx),
            .auto_reload_timer_failed => self.autoReloadTimerFailed(),
            .focus_lost => {
                self.drag_auto_scroll.clear();
                self.command_session = .inactive;
                switch (self.active_page) {
                    .changes => self.changesNavigation().clearDiffSelection(),
                    .repository => self.pages.repository.clearLiveSelectionPreservingViewport(self.shellLayout().bodySize()),
                    .history => self.pages.history.diff.selection_owner = .none,
                    .compare => self.pages.compare.diff.selection_owner = .none,
                }
            },
            .git_action_spinner_tick => |generation| if (self.actionLifecycle().tick(generation)) self.redraw_plan.requestSkip(),
            .git_action_spinner_timer_failed => |generation| self.actionLifecycle().timerFailed(generation),
            .cancel_remote_action => _ = self.remoteWorkflow().cancelActiveRemote(false),
            .quit => {
                self.drag_auto_scroll.clear();
                self.requestQuit(ctx);
            },
        }
        if (self.changesRead().retireSupersededActionCursor(ctx, self.actionLifecycleView().generation())) {
            self.redraw_plan.requireFrame();
        }
        try self.changesRead().applyDeferredSourceIfReady(ctx);
        try self.changesRead().applyDeferredProjectionIfReady(ctx);
        switch (try self.compareCoordinator().applyDeferred(ctx)) {
            .none, .discarded => {},
            .visible => self.redraw_plan.requireFrame(),
        }
        if (try self.changesRead().maybeStartQueuedRevalidation(ctx)) self.redraw_plan.requireFrame();
        if (try self.repositoryCoordinator().startPending(ctx)) self.redraw_plan.requireFrame();
        if (try self.historyCoordinator().startPending(ctx)) self.redraw_plan.requireFrame();
        if (self.reconcileCommandLine()) self.redraw_plan.requireFrame();
        const revalidation_queued_before_projection = self.changesRead().hasQueuedFullRevalidation();
        if (self.active_page == .changes) try self.changesRead().ensureProjection(ctx);
        // Boundary inert retention queues its repair revalidation inside
        // ensureChangesProjection, after the consumption point above already
        // ran. Consume a queue born in this tail so the repair starts in the
        // same cycle even with watch off and no further input. Pre-existing
        // queued intent keeps its single consumption point above.
        if (!revalidation_queued_before_projection and
            self.changesRead().hasQueuedFullRevalidation())
        {
            if (try self.changesRead().maybeStartQueuedRevalidation(ctx)) self.redraw_plan.requireFrame();
        }
        self.actionLifecycle().reconcileSpinner(ctx);
        if (self.config.transitions and self.screen_transition.publish(self.transitionIdentity(), switch (self.active_page) {
            .changes => self.pages.changes.transition_publication,
            .repository => self.pages.repository.transition_publication,
            .history => self.pages.history.transition_publication,
            .compare => self.pages.compare.transition_publication,
        })) {
            ctx.frame().request();
            self.redraw_plan.requireFrame();
        }
        self.clearTransitionPublications();
        if (self.screen_transition == .running) self.redraw_plan.requireFrame();
        if (!self.redraw_plan.resolvesToSkip() and self.active_page == .compare and self.pages.compare.base_picker.open) {
            self.compareCoordinator().prepareModalRedraw(ctx.io());
        }
        if (!self.redraw_plan.resolvesToSkip() and self.overlay.isSwitchBranch()) {
            self.remoteWorkflow().prepareBranchSwitchModalRedraw(ctx.io());
        }
        update_succeeded = true;
    }

    fn requestQuit(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.actionLifecycleView().hasPending()) {
            if (self.remoteWorkflow().cancelActiveRemote(true)) return;
            self.setStatus("finish current git action before quitting", .{});
            return;
        }
        _ = self.screen_transition.cancel();
        self.teardown_requested = true;
        ctx.quit();
    }

    fn updateMouseSelectionDrag(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        continuation: app_message.MouseSelectionContinuation,
    ) !void {
        const target: drag_auto_scroll.Target = switch (continuation.target) {
            .changes => |point| blk: {
                if (self.active_page != .changes) break :blk .changes;
                _ = try self.updateChanges(ctx, .{ .mouse_diff_drag = point });
                break :blk .changes;
            },
            .compare => |point| blk: {
                if (self.active_page != .compare) break :blk .compare;
                _ = try self.updateCompare(ctx, .{ .common = .{ .shared = .{ .mouse_diff_drag = point } } });
                break :blk .compare;
            },
            .history => |point| blk: {
                if (self.active_page != .history) break :blk .history;
                _ = try self.updateHistory(ctx, .{ .common = .{ .shared = .{ .mouse_diff_drag = point } } });
                break :blk .history;
            },
            .repository => |point| blk: {
                if (self.active_page != .repository) break :blk .repository;
                _ = try self.updateRepository(ctx, .{ .mouse_owner_drag = point });
                break :blk .repository;
            },
        };
        const viewport = self.dragAutoScrollViewport(target) orelse {
            self.drag_auto_scroll.clear();
            return;
        };
        self.drag_auto_scroll.observe(target, continuation.pointer, viewport);
    }

    fn updateMouseSelectionRelease(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        continuation: app_message.MouseSelectionContinuation,
    ) !void {
        // Root intent ends before page completion can install/copy a candidate
        // or drain a deferred replacement source.
        self.drag_auto_scroll.clear();
        switch (continuation.target) {
            .changes => |point| {
                if (self.active_page == .changes) _ = try self.updateChanges(ctx, .{ .mouse_diff_release = point });
            },
            .compare => |point| {
                if (self.active_page == .compare) _ = try self.updateCompare(ctx, .{ .common = .{ .shared = .{ .mouse_diff_release = point } } });
            },
            .history => |point| {
                if (self.active_page == .history) _ = try self.updateHistory(ctx, .{ .common = .{ .shared = .{ .mouse_diff_release = point } } });
            },
            .repository => |point| {
                if (self.active_page == .repository) _ = try self.updateRepository(ctx, .{ .mouse_owner_release = point });
            },
        }
    }

    fn updateDragAutoScrollTick(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        generation: u64,
    ) !void {
        const active = self.drag_auto_scroll.acceptedTick(generation) orelse {
            self.redraw_plan.requestSkip();
            return;
        };
        _ = self.dragAutoScrollViewport(active.target) orelse {
            self.drag_auto_scroll.clear();
            self.redraw_plan.requestSkip();
            return;
        };

        const outcome: ?drag_auto_scroll.StepOutcome = switch (active.target) {
            .changes => try self.updateChanges(ctx, .{ .mouse_diff_auto_scroll_step = active.intent }),
            .history => try self.updateHistory(ctx, .{ .common = .{ .shared = .{ .mouse_diff_auto_scroll_step = active.intent } } }),
            .compare => try self.updateCompare(ctx, .{ .common = .{ .shared = .{ .mouse_diff_auto_scroll_step = active.intent } } }),
            .repository => blk: {
                const body_size = self.shellLayout().bodySize();
                const body_point: repository_layout.BodyPoint = .{
                    .col = active.intent.endpoint.col,
                    .row = active.intent.endpoint.row,
                };
                const source_point = repository_layout.sourceGesturePoint(
                    body_point,
                    body_size,
                    self.pages.repository.viewer.tree_width,
                    self.pages.repository.viewer.tree_hidden,
                ) orelse break :blk null;
                break :blk try self.updateRepository(ctx, .{ .mouse_source_auto_scroll_step = .{
                    .direction = active.intent.direction,
                    .endpoint = .{ .col = source_point.col, .row = source_point.row },
                } });
            },
        };
        self.drag_auto_scroll.complete(generation, outcome orelse .stale_owner);
    }

    fn dragAutoScrollViewport(
        self: *App,
        target: drag_auto_scroll.Target,
    ) ?drag_auto_scroll.Viewport {
        if (self.active_page != switch (target) {
            .changes => page.Id.changes,
            .history => page.Id.history,
            .compare => page.Id.compare,
            .repository => page.Id.repository,
        }) return null;

        return switch (target) {
            .changes => blk: {
                var adapter = self.changesNavigation().updateAdapter();
                break :blk diffAutoScrollViewport(adapter.shared().navigation);
            },
            .history => blk: {
                var adapter = self.historyCoordinator().navigation().updateAdapter();
                break :blk diffAutoScrollViewport(adapter.bodyController());
            },
            .compare => blk: {
                var adapter = self.compareCoordinator().navigation().updateAdapter();
                break :blk diffAutoScrollViewport(adapter.bodyController());
            },
            .repository => self.pages.repository.sourceAutoScrollViewport(self.shellLayout().bodySize()),
        };
    }

    fn reconcileDragAutoScroll(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.drag_auto_scroll.active) |active| {
            if (self.dragAutoScrollViewport(active.target) == null) self.drag_auto_scroll.clear();
        }

        const desired = if (self.drag_auto_scroll.active) |active| active.generation else null;
        if (self.drag_auto_scroll.scheduled_generation == desired) return;

        if (self.drag_auto_scroll.scheduled_generation != null) {
            ctx.timer().cancel(drag_auto_scroll.timer_id) catch return;
            self.drag_auto_scroll.scheduled_generation = null;
        }

        const active = self.drag_auto_scroll.active orelse return;
        ctx.timer().every(
            drag_auto_scroll.timer_id,
            drag_auto_scroll.interval_ns,
            .{ .drag_scroll = active.generation },
            drag_auto_scroll.timerNotice,
        ) catch {
            if (self.drag_auto_scroll.active) |current| {
                if (current.generation == active.generation) self.drag_auto_scroll.clear();
            }
            return;
        };
        self.drag_auto_scroll.scheduled_generation = active.generation;
    }

    fn updateChanges(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: changes_message.Msg,
    ) !?drag_auto_scroll.StepOutcome {
        var page_update = try (changes_page_update.Controller{
            .navigation = self.changesNavigation(),
        }).apply(self.allocator, msg);
        defer page_update.deinit(self.allocator);
        const auto_scroll = page_update.auto_scroll;
        if (page_update.redraw == .skip) self.redraw_plan.requestSkip();

        if (page_update.capture_display_override) {
            try self.changesRead().captureDisplayOverride(ctx.allocator());
        }

        var command = page_update.takeCommand() orelse return auto_scroll;
        const allocator = self.allocator orelse ctx.allocator();
        defer command.deinit(allocator);
        switch (command) {
            .enter_commit_panel => {
                self.remoteWorkflow().cancelPushConfirmation(ctx.allocator());
                self.remoteWorkflow().cancelPullConfirmation(ctx.allocator());
                self.localWorkflow().enterCommitPanelMode(ctx.allocator(), .commit);
            },
            .enter_amend_panel => {
                self.remoteWorkflow().cancelPushConfirmation(ctx.allocator());
                self.remoteWorkflow().cancelPullConfirmation(ctx.allocator());
                self.localWorkflow().enterCommitPanelMode(ctx.allocator(), .amend);
            },
            .toggle_selected_file => try self.localWorkflow().toggleSelectedFileStage(ctx),
            .toggle_selected_hunk => try self.localWorkflow().toggleSelectedHunkStage(ctx),
            .request_discard_selected_file => {
                self.remoteWorkflow().cancelPushConfirmation(ctx.allocator());
                self.remoteWorkflow().cancelPullConfirmation(ctx.allocator());
                try self.localWorkflow().requestDiscardSelectedFile(ctx.allocator());
            },
            .request_push => try self.requestRemotePush(ctx),
            .request_pull => try self.requestRemotePull(ctx),
            .request_fetch => try self.remoteWorkflow().requestFetch(ctx),
            .open_selected_file_in_editor => try self.openSelectedFileInEditor(ctx),
            .copy_current_line => self.copyCurrentLine(ctx),
            .copy_current_hunk => try self.copyCurrentHunk(ctx),
            .copy_hunk_diff => |text| self.shellEffects().queueClipboard(ctx, .{
                .origin = .{ .page = self.shellEffects().changesOrigin() },
                .label = "current hunk diff",
                .text = text,
            }),
            .copy_diff_selection => |copy| self.copyDiffSelection(ctx, copy),
            .copy_diff_header_path => |selection| self.copyDiffHeaderPath(ctx, selection),
        }
        return auto_scroll;
    }

    fn updateCompare(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: compare_input.Msg,
    ) !?drag_auto_scroll.StepOutcome {
        var outcome = try self.compareCoordinator().update(ctx, msg);
        defer outcome.deinit(ctx.allocator());
        const auto_scroll = outcome.auto_scroll;
        if (outcome.redraw == .skip) self.redraw_plan.requestSkip();
        if (outcome.takeClipboard()) |taken| {
            var effect = taken;
            defer effect.deinit(ctx.allocator());
            self.shellEffects().queueClipboard(ctx, .{
                .origin = effect.origin,
                .label = effect.label,
                .text = effect.text,
                .selection_generation = effect.selection_generation,
            });
        }
        return auto_scroll;
    }

    fn updateHistory(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: history_page.Msg,
    ) !?drag_auto_scroll.StepOutcome {
        var outcome = try self.historyCoordinator().update(ctx, msg);
        defer outcome.deinit(ctx.allocator());
        const auto_scroll = outcome.auto_scroll;
        if (outcome.redraw == .skip) self.redraw_plan.requestSkip();
        if (outcome.takeClipboard()) |taken| {
            var effect = taken;
            defer effect.deinit(ctx.allocator());
            self.shellEffects().queueClipboard(ctx, .{
                .origin = effect.origin,
                .label = effect.label,
                .text = effect.text,
                .selection_generation = effect.selection_generation,
            });
        }
        return auto_scroll;
    }

    fn updateRepository(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: repository_page.Msg,
    ) !?drag_auto_scroll.StepOutcome {
        var outcome = self.repositoryCoordinator().update(ctx, msg);
        defer outcome.deinit(ctx.allocator());
        if (outcome.remote_action) |action| switch (action) {
            .push => try self.requestRemotePush(ctx),
            .pull => try self.requestRemotePull(ctx),
        };
        if (outcome.editor_target) |target| try self.shellEffects().requestEditor(
            ctx,
            target,
            self.actionLifecycleView().hasPending(),
            self.shellEffects().repositoryOrigin(),
        );
        const auto_scroll = outcome.auto_scroll;
        if (outcome.redraw == .skip) self.redraw_plan.requestSkip();
        if (outcome.takeClipboard()) |taken| {
            var effect = taken;
            defer effect.deinit(ctx.allocator());
            self.shellEffects().queueClipboard(ctx, .{
                .origin = effect.origin,
                .label = effect.label,
                .text = effect.text,
                .selection_generation = effect.selection_generation,
            });
        }
        return auto_scroll;
    }

    fn finishLoadResult(self: *App, ctx: *chasen.Ctx(Msg), finished: LoadFinishedMsg) !void {
        switch (finished) {
            .changes => |changes_result| switch (changes_result) {
                .source => |result| try self.changesRead().finishDiffLoad(ctx.allocator(), result),
                .status => |result| try self.changesRead().finishStatusLoad(ctx.allocator(), result),
                .branch_status => |result| self.changesRead().finishBranchStatusLoad(ctx.allocator(), result),
                .projection => |result| try self.changesRead().finishProjectionLoad(ctx.allocator(), result),
                .projection_syntax => |result| self.changesRead().finishGeneratedProjectionSyntax(ctx.allocator(), result),
            },
            .history => |history_result| switch (history_result) {
                .catalog => |result_value| {
                    var result = result_value;
                    defer result.deinit(ctx.allocator());
                    const history = self.historyCoordinator();
                    switch (try history.finishCatalog(ctx.allocator(), &result)) {
                        .discarded => self.redraw_plan.requestSkip(),
                        .changed => _ = try history.requestPreview(ctx),
                        .failed => {},
                    }
                },
                .diff => |result_value| {
                    var result = result_value;
                    defer result.deinit(ctx.allocator());
                    if (try self.historyCoordinator().finishDiff(ctx.allocator(), &result) == .discarded)
                        self.redraw_plan.requestSkip();
                },
                .preview => |result_value| {
                    var result = result_value;
                    defer result.deinit(ctx.allocator());
                    if (try self.historyCoordinator().finishPreview(ctx, &result) == .discarded)
                        self.redraw_plan.requestSkip();
                },
            },
            .compare => |compare_result| switch (compare_result) {
                .source => |result| {
                    if (try self.compareCoordinator().finishLoad(ctx, result) == .skip) {
                        self.redraw_plan.requestSkip();
                    }
                },
                .branch_list => |result| {
                    if (self.compareCoordinator().finishBranchList(ctx.allocator(), result) == .skip) {
                        self.redraw_plan.requestSkip();
                    }
                },
            },
            .shell => |shell_result| switch (shell_result) {
                .repo_path_discovery => |result| {
                    if (try self.repoSession().finishPathDiscovery(ctx, result)) |outcome| {
                        try self.applyRepoSessionCommit(ctx, outcome, true);
                    }
                },
                .branch_list => |result| try self.remoteWorkflow().finishBranchListLoad(ctx.allocator(), result),
                .stash_list => |result| self.stashWorkflow().finishList(ctx.allocator(), result),
                .worktree_switch => |result| {
                    if (self.remoteWorkflow().finishWorktreeSwitch(ctx.allocator(), result)) |validated| {
                        const caller_status = self.remoteWorkflow().branchStatus(result.owner.origin.page_id);
                        const outcome = try self.repoSession().commitWorktree(ctx, validated, caller_status);
                        if (outcome == .changed) try self.applyRepoSessionCommit(ctx, outcome, true);
                    }
                },
            },
            .coordinator => |coordinator_result| switch (coordinator_result) {
                .repo_discovery => |result| try self.finishChangesRepoDiscovery(ctx, result),
            },
        }
    }

    fn finishActionResult(self: *App, ctx: *chasen.Ctx(Msg), finished: ActionFinishedMsg) !void {
        switch (finished) {
            .stage_file => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishStageFile(ctx.allocator(), result)),
            .stage_hunk => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishStageHunk(ctx.allocator(), result)),
            .unstage_file => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishUnstageFile(ctx.allocator(), result)),
            .unstage_hunk => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishUnstageHunk(ctx.allocator(), result)),
            .discard_file => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishDiscardFile(ctx.allocator(), result)),
            .commit => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishCommit(ctx.allocator(), result)),
            .amend => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishAmend(ctx.allocator(), result)),
            .push => |result| try self.applyRemoteOutcome(ctx, try self.remoteWorkflow().finishPush(ctx.allocator(), result)),
            .pull => |result| try self.applyRemoteOutcome(ctx, try self.remoteWorkflow().finishPull(ctx.allocator(), result)),
            .fetch => |result| try self.applyRemoteOutcome(ctx, self.remoteWorkflow().finishFetch(ctx.allocator(), result)),
            .switch_branch => |result| {
                // Capture before finishSwitchBranch releases the result text.
                const changed = result.result == .ok and !std.mem.eql(u8, result.old_branch, result.new_branch);
                const outcome = try self.remoteWorkflow().finishSwitchBranch(ctx.allocator(), result);
                if (self.config.transitions and changed) {
                    // Only an accepted, still-live caller receives branch_reload.
                    // Failed/stale completions must never arm an animation.
                    if (outcome.branch_reload) |reload| {
                        const target: page.Id = switch (reload) {
                            .changes => .changes,
                            .repository => .repository,
                            .history => .history,
                            .compare => .compare,
                        };
                        if (target == self.active_page) self.screen_transition.arm(self.transitionIdentity().?);
                    }
                }
                try self.applyRemoteOutcome(ctx, outcome);
            },
            .create_stash => |value| {
                var result = value;
                defer result.deinit(ctx.allocator());
                if (self.stashWorkflow().finish(ctx.allocator(), &result)) |outcome| {
                    if (outcome.error_message) |detail| {
                        defer ctx.allocator().free(detail);
                        self.remoteWorkflow().setRemoteErrorWithRetry(ctx.allocator(), .create_stash, detail, null, .changes) catch {};
                    }
                    try self.applyLocalActionIntent(ctx, outcome.intent);
                }
            },
            .stash_selection => |value| {
                var result = value;
                defer result.deinit(ctx.allocator());
                if (self.stashWorkflow().finishSelection(ctx.allocator(), &result)) |outcome| {
                    if (outcome.error_message) |detail| {
                        defer ctx.allocator().free(detail);
                        self.remoteWorkflow().setRemoteErrorWithRetry(ctx.allocator(), if (result.confirmation.action == .apply) .apply_stash else .drop_stash, detail, null, .changes) catch {};
                    }
                    try self.applyLocalActionIntent(ctx, outcome.intent);
                }
            },
            .push_foreground => |result| try self.applyRemoteOutcome(ctx, try self.remoteWorkflow().finishPushForeground(ctx, result)),
        }
    }

    fn finishShellEffect(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        finished: ShellEffectFinishedMsg,
    ) !void {
        switch (finished) {
            .editor => |result| switch (self.shellEffects().finishEditor(result)) {
                .none => {},
                .reload_changes => try self.changesRead().reloadAfterEditor(ctx),
                .reload_repository => self.repositoryCoordinator().requestReload(.editor),
            },
            .clipboard => |result| if (self.shellEffects().finishClipboard(result)) |completion| {
                self.finishSelectionCopy(ctx.allocator(), completion);
            },
        }
    }

    fn applyRemoteOutcome(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        outcome: workflow_remote.Outcome,
    ) !void {
        if (outcome.cancel_local_confirmations) {
            self.localWorkflow().cancelConfirmations(ctx.allocator());
        }
        switch (outcome.repository_reload) {
            .none => {},
            .branch => self.pages.repository.invalidateRemoteBranch(self.repoSessionView().activeRoot() != null),
            .full => self.repositoryCoordinator().requestReload(.remote_operation),
        }
        if (outcome.reload != .none) {
            try self.changesRead().applyEffectReload(ctx, outcome.reload);
        }
        if (outcome.branch_reload) |reload| switch (reload) {
            .changes => |intent| try self.changesRead().applyEffectReload(ctx, intent),
            .repository => self.repositoryCoordinator().requestReload(.branch_switch),
            .history => |succeeded| self.pages.history.branchSwitchFinished(ctx.allocator(), succeeded),
            .compare => try self.compareCoordinator().branchSwitchFinished(ctx),
        };
        if (outcome.quit_after_terminal) {
            self.requestQuit(ctx);
        }
    }

    fn requestRemotePush(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const outcome = self.remoteWorkflow().requestPush(ctx.allocator()) catch |err| {
            // Request errors are possible only after target preflight. Cancel
            // here too so successful and failed ownership transfers share the
            // same local/remote confirmation exclusivity boundary.
            self.localWorkflow().cancelConfirmations(ctx.allocator());
            return err;
        };
        try self.applyRemoteOutcome(ctx, outcome);
    }

    fn requestRemotePull(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const outcome = self.remoteWorkflow().requestPull(ctx.allocator()) catch |err| {
            self.localWorkflow().cancelConfirmations(ctx.allocator());
            return err;
        };
        try self.applyRemoteOutcome(ctx, outcome);
    }

    fn requestRemoteBranchSwitch(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const outcome = self.remoteWorkflow().requestBranchSwitch(ctx) catch |err| {
            self.localWorkflow().cancelConfirmations(ctx.allocator());
            return err;
        };
        try self.applyRemoteOutcome(ctx, outcome);
    }

    fn applyLocalActionIntent(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        maybe_intent: ?workflow_local.ActionReloadIntent,
    ) !void {
        const intent = maybe_intent orelse return;
        try self.changesRead().applyActionOutcome(
            ctx,
            intent.pending,
            intent.active_matches,
            intent.reload,
        );
    }

    fn commandLineView(self: *const App) ?*const command_line.Active {
        return switch (self.command_session) {
            .inactive => null,
            .active => |*active| &active.input,
        };
    }

    fn commandLineInput(self: *App) ?*command_line.Active {
        return switch (self.command_session) {
            .inactive => null,
            .active => |*active| &active.input,
        };
    }

    fn repositoryCommandAvailable(self: *const App) bool {
        if (self.active_page != .repository or self.commandLineView() != null) return false;
        if (self.teardown_requested or
            self.actionLifecycleView().hasPending() or
            self.localWorkflowView().commitPanelOpen() or
            self.repoSessionView().picker().model.mode or
            self.overlay.kind != .none or
            self.remoteWorkflowView().hasForeground() or
            self.shellEffectsView().hasEditorForeground())
        {
            return false;
        }
        return self.pages.repository.commandSourceTarget() != null;
    }

    fn updateCommandLine(self: *App, msg: command_line.Msg) void {
        switch (msg) {
            .open => {
                if (self.commandLineView() != null) return;
                if (!self.repositoryCommandAvailable()) {
                    self.pages.repository.status.set("command source is no longer available", .{});
                    return;
                }
                const target = self.pages.repository.commandSourceTarget() orelse {
                    self.pages.repository.status.set("command source is no longer available", .{});
                    return;
                };
                self.command_session = .{ .active = .{
                    .input = .{},
                    .context = .{ .repository_source = target },
                } };
            },
            .cancel => self.command_session = .inactive,
            .submit => self.submitCommandLine(),
            .insert => |codepoint| {
                const active = self.commandLineInput() orelse return;
                active.input.insert(codepoint) catch {};
            },
            .paste => |text| {
                const active = self.commandLineInput() orelse return;
                if (std.unicode.utf8ValidateSlice(text)) active.input.insertSlice(text) catch {};
            },
            .backspace => if (self.commandLineInput()) |active| active.input.backspace(),
            .move_left => if (self.commandLineInput()) |active| active.input.moveLeft(),
            .move_right => if (self.commandLineInput()) |active| active.input.moveRight(),
            .owned_noop => {},
        }
    }

    fn submitCommandLine(self: *App) void {
        const pending: PendingCommand = switch (self.command_session) {
            .inactive => return,
            .active => |active| .{
                .submission = active.input.submission(),
                .context = active.context,
            },
        };
        self.command_session = .inactive;

        switch (pending.submission.parse()) {
            .empty => {},
            .invalid_line_number => self.commandStatus(pending.context).set("invalid line number", .{}),
            .unknown_command => |raw| self.commandStatus(pending.context).set("unknown command: {s}", .{raw}),
            .command => |command| self.executeCommand(pending.context, command),
        }
    }

    fn executeCommand(self: *App, execution: ExecutionContext, command: command_line.Command) void {
        switch (execution) {
            .repository_source => |target| switch (command) {
                .goto_line => |line| switch (self.pages.repository.applySourceLineCommand(
                    target,
                    line,
                    self.shellLayout().bodySize(),
                )) {
                    .moved => self.pages.repository.status.clearIfEphemeral(),
                    .stale_target => self.pages.repository.status.set("command source is no longer available", .{}),
                    .empty_source => self.pages.repository.status.set("source is empty", .{}),
                    .out_of_range => |line_count| self.pages.repository.status.set(
                        "line {d} out of range (1-{d})",
                        .{ line, line_count },
                    ),
                },
            },
        }
    }

    fn commandStatus(self: *App, execution: ExecutionContext) *app_state.StatusMessage {
        return switch (execution) {
            .repository_source => &self.pages.repository.status,
        };
    }

    /// Async source publication and repository replacement can invalidate an
    /// otherwise idle command between input events. Close it at the common
    /// update tail before any later Enter can reuse the stale target.
    fn reconcileCommandLine(self: *App) bool {
        const execution = switch (self.command_session) {
            .inactive => return false,
            .active => |active| active.context,
        };
        switch (execution) {
            .repository_source => |target| {
                if (self.active_page != .repository) {
                    self.command_session = .inactive;
                    return true;
                }
                if (self.pages.repository.commandSourceTargetMatches(target)) return false;
                self.command_session = .inactive;
                self.pages.repository.status.set("command source is no longer available", .{});
                return true;
            },
        }
    }

    fn clearEphemeralStatusForUserAction(self: *App, msg: Msg) bool {
        if (app_message.keepsEphemeralStatus(msg)) return false;
        var changed = self.status.clear_on_next_input;
        self.status.clearIfEphemeral();
        if (self.activePageStatusMut()) |active_status| {
            changed = changed or active_status.clear_on_next_input;
            active_status.clearIfEphemeral();
        }
        return changed;
    }

    pub fn view(self: *const App, surface: *chasen.Surface) !void {
        try app_view.view(self.shellViewContext(), surface);
        if (self.config.transitions) {
            self.screen_transition.render(surface);
        }
    }

    fn transitionIdentity(self: *const App) ?page.RequestIdentity {
        return switch (self.active_page) {
            .changes => self.pages.changes.activation.currentIdentity(),
            .repository => if (self.pages.repository.active) .{
                .origin = .repository,
                .repo_epoch = self.pages.repository.repo_epoch,
                .activation_id = self.pages.repository.activation_id,
            } else null,
            .history => self.pages.history.activation.currentIdentity(),
            .compare => self.pages.compare.activation.currentIdentity(),
        };
    }

    fn clearTransitionPublications(self: *App) void {
        self.pages.changes.transition_publication = .none;
        self.pages.repository.transition_publication = .none;
        self.pages.history.transition_publication = .none;
        self.pages.compare.transition_publication = .none;
    }

    fn shellViewContext(self: *const App) app_view.Context {
        const body_size = self.shellLayout().bodySize();
        const repo_view = self.repoSessionView();
        const picker = repo_view.picker();
        const local = self.localWorkflowView();
        const remote = self.remoteWorkflowView();
        return .{
            .changes = self.changesViewContext(),
            .compare = .{
                .page = &self.pages.compare,
                .palette = self.theme,
                .repo_root = repo_view.activeRoot(),
                .repo_epoch = repo_view.epoch(),
                .root_identity = repo_view.activeIdentity(),
                .layout = .{ .width = body_size.width, .height = body_size.height },
                .keymap = self.keymap,
            },
            .repository = .{
                .page_state = &self.pages.repository,
                .palette = self.theme,
                .keymap = self.keymap,
                .command_line = self.commandLineView(),
                .repo_root = self.repoSessionView().activeRoot(),
            },
            .history = .{
                .page_state = &self.pages.history,
                .palette = self.theme,
                .repo_root = repo_view.activeRoot(),
                .repo_epoch = repo_view.epoch(),
                .root_identity = repo_view.activeIdentity(),
                .layout = .{ .width = body_size.width, .height = body_size.height },
                .keymap = self.keymap,
            },
            .active_page = self.active_page,
            .page_bar_visible = true,
            .theme = self.theme,
            .keymap = self.keymap,
            .action = self.actionLifecycleView(),
            .remote_cancelable = remote.canCancel(self.actionLifecycleView().acceptedPending()),
            .remote_canceling = remote.canceling(),
            .status = &self.status,
            .page_status = self.activePageStatus(),
            .commit_panel = local.commitPanel(),
            .repo_picker = picker.model,
            .repo_picker_pending_workspace_root = picker.pending_workspace_root,
            .repo_picker_items = picker.items,
            .repo_picker_has_recent = picker.has_recent,
            .overlay = &self.overlay,
            .committed_repo_discovery_kind = picker.committed_discovery_kind,
            .active_repo_index = picker.active_index,
            .has_active_repo = repo_view.activeRoot() != null,
            .discard_confirmation = local.discardConfirmation(),
            .amend_confirmation = local.amendConfirmation(),
            .push_confirmation = remote.pushConfirmation(),
            .pull_confirmation = remote.pullConfirmation(),
            .remote_error_operation = remote.remoteErrorOperation(),
            .remote_error_message = remote.remoteErrorMessage(),
            .push_retry_target = remote.pushRetryTarget(),
            .push_retry_inspecting = remote.pushRetryInspecting(),
            .branch_switch = remote.branchSwitch(),
            .create_stash = self.stash_workflow.dialog(),
            .stash_catalog = if (self.overlay.isStashes()) self.stash_workflow.list() else null,
            .stash_target = self.changesOperations().stashTarget(true),
            .staged_summary = switch (self.changesOperations().commitSummary()) {
                .unavailable => .unavailable,
                .loading_or_stale => .loading_or_stale,
                .ready => |ready| .{ .ready = .{ .count = ready.count } },
            },
        };
    }

    fn changesEmptyRemoteActionHints(self: *const App) changes_view.EmptyRemoteActionHints {
        var hints: changes_view.EmptyRemoteActionHints = .{
            .show_repo_picker = self.repoSessionView().hasWorkspace(),
        };
        // The empty-state hint is only a display projection, but `U` is still a
        // mutating operation. Keep it tied to the same target gate as the real
        // request path so stale or missing clean-status snapshots cannot be
        // advertised as safe pull capability.
        if (self.changesOperations().pullTarget() == .ready) hints.show_pull = true;
        if (self.changesOperations().fetchTarget() == .ready) {
            hints.show_fetch = true;
        }
        return hints;
    }

    fn changesViewContext(self: *const App) changes_view.Context {
        return changes_view.Context.init(
            &self.pages.changes,
            self.changesNavigationView(),
            self.theme,
            self.keymap,
            self.config.sourceLabel(),
            self.config.source,
            self.repoSessionView().activeRoot(),
            self.changesEmptyRemoteActionHints(),
        );
    }

    pub fn handleEvent(self: *const App, event: chasen.Event) ?Msg {
        if (event == .frame) return if (self.config.transitions) .transition_frame else null;
        // Before publication, let the normal router ignore unmapped input.
        // Once visible, a new key, click, scroll or paste interrupts. Releasing
        // the click that started a page transition must not cancel it.
        if (self.screen_transition == .running) switch (event) {
            .key_press, .paste => return .{ .transition_input = event },
            .mouse => |mouse| if (mouse.type == .press) return .{ .transition_input = event },
            else => {},
        };
        return self.shellInputView().handleEvent(event);
    }

    fn shellInputView(self: *const App) shell_input.View {
        const layout = self.shellLayout();
        const body_size = layout.bodySize();
        const repo = self.repoSessionView();
        const picker = repo.picker();
        const compare_navigation_view: committed_diff_navigation.View = .{
            .diff = &self.pages.compare.diff,
            .activation = &self.pages.compare.activation,
            .status = &self.pages.compare.status,
            .current_target = self.pages.compare.currentTarget(),
            .repo_root = repo.activeRoot(),
            .repo_epoch = repo.epoch(),
            .root_identity = repo.activeIdentity(),
            .source = compare_page.selection_source,
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.compare),
            .live_drag_deferred_source = self.pages.compare.deferred_load_apply != null,
        };
        var compare_body_adapter = compare_navigation_view.resolver();
        const compare_body_view = compare_navigation_view.bodyView(&compare_body_adapter);
        const history_navigation_view: committed_diff_navigation.View = .{
            .diff = &self.pages.history.diff,
            .activation = &self.pages.history.activation,
            .status = &self.pages.history.status,
            .current_target = null,
            .presentation_identity = self.pages.history.currentPresentationIdentity(),
            .repo_root = repo.activeRoot(),
            .repo_epoch = repo.epoch(),
            .root_identity = repo.activeIdentity(),
            .source = history_page.selection_source,
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.history),
            .live_drag_deferred_source = false,
        };
        var history_body_adapter = history_navigation_view.resolver();
        const history_body_view = history_navigation_view.bodyView(&history_body_adapter);
        var history_key = self.pages.history.inputContext(self.keymap);
        history_key.common.side_by_side = history_navigation_view.view().effectiveDisplayMode() == .side_by_side;
        history_key.common.context_copy_available = history_body_view.contextCopyAvailable();
        const history_picker_range = self.pages.history.catalog.visibleRange(body_size.height);
        const changes_navigation_view = self.changesNavigationView();
        return .{
            .active_page = self.active_page,
            .changes = .{
                .key = .{
                    .search_mode = self.pages.changes.search.mode,
                    .file_search_mode = self.pages.changes.file_search.mode,
                    .search_query_len = self.pages.changes.search.query.len,
                    .focus = self.pages.changes.viewer.focus,
                    .sidebar_hidden = self.pages.changes.viewer.sidebar_hidden,
                    .side_by_side = changes_navigation_view.effectiveDisplayMode() == .side_by_side,
                    .selection_owner = diff_surface.input.selectionOwnerKind(self.pages.changes.selection_owner),
                    .retained_selection_action_available = changes_navigation_view.retainedSelectionActionAvailable(),
                    .keymap = self.keymap,
                },
                .selection_owner = &self.pages.changes.selection_owner,
                .loaded = changes_navigation_view.activeLoadedDiffConst(),
                .selected_node = self.pages.changes.viewer.selected_node,
                .sidebar_hidden = self.pages.changes.viewer.sidebar_hidden,
                .sidebar_width = self.pages.changes.viewer.sidebar_width,
            },
            .compare = .{
                .key = .{
                    .common = .{
                        .search_mode = self.pages.compare.diff.search.mode,
                        .file_search_mode = self.pages.compare.diff.file_search.mode,
                        .search_query_len = self.pages.compare.diff.search.query.len,
                        .focus = self.pages.compare.diff.viewer.focus,
                        .sidebar_hidden = self.pages.compare.diff.viewer.sidebar_hidden,
                        .side_by_side = compare_navigation_view.view().effectiveDisplayMode() == .side_by_side,
                        .selection_owner = diff_surface.input.selectionOwnerKind(self.pages.compare.diff.selection_owner),
                        .retained_selection_action_available = compare_body_view.retainedSelectionActionAvailable(),
                        .context_copy_available = compare_body_view.contextCopyAvailable(),
                        .keymap = self.keymap,
                    },
                    .base_picker_open = self.pages.compare.base_picker.open,
                    .base_picker_query_mode = self.pages.compare.base_picker.input_mode == .query,
                    .base_picker_query_len = self.pages.compare.base_picker.query.len,
                },
                .selection_owner = &self.pages.compare.diff.selection_owner,
                .loaded = compare_navigation_view.view().activeLoadedDiffConst(),
                .selected_node = self.pages.compare.diff.viewer.selected_node,
                .sidebar_hidden = self.pages.compare.diff.viewer.sidebar_hidden,
                .sidebar_width = self.pages.compare.diff.viewer.sidebar_width,
            },
            .repository = .{
                .key = self.pages.repository.inputContext(self.keymap),
                .page_state = &self.pages.repository,
            },
            .history = .{
                .key = history_key,
                .picker_layout = if (history_key.diff_view)
                    null
                else
                    history_view.pickerLayout(body_size, self.pages.history.interaction_state),
                .picker_visible_start = history_picker_range.start,
                .picker_visible_end = history_picker_range.end,
                .selection_owner = &self.pages.history.diff.selection_owner,
                .loaded = if (self.pages.history.current_view == .diff)
                    history_body_view.view.activeLoadedDiffConst()
                else
                    null,
                .selected_node = self.pages.history.diff.viewer.selected_node,
                .sidebar_hidden = self.pages.history.diff.viewer.sidebar_hidden,
                .sidebar_width = self.pages.history.diff.viewer.sidebar_width,
            },
            .create_stash = self.stash_workflow.dialog(),
            .stash_catalog = if (self.overlay.isStashes()) self.stash_workflow.list() else null,
            .commit_panel_mode = self.localWorkflowView().commitPanelOpen(),
            .repo_picker_mode = picker.model.mode,
            .repo_picker_input_mode = picker.model.input_mode,
            .branch_switch_query_mode = self.remote_workflow.branch_switch.query_mode,
            .branch_switch_query_len = self.remote_workflow.branch_switch.query.len,
            .branch_switch_pending = self.remote_workflow.branch_switch.worktree_pending,
            .remote_action_cancelable = self.remoteWorkflowView().canCancel(self.actionLifecycleView().acceptedPending()),
            .remote_error_interactive = self.remoteWorkflowView().pushRetryTarget() != null,
            .command_line_active = self.commandLineView() != null,
            .repository_command_available = self.repositoryCommandAvailable(),
            .keymap = self.keymap,
            .overlay = &self.overlay,
            .layout = layout,
            .footer_status_target = app_view.footerStatusTarget(self.shellViewContext(), layout.footer.width),
        };
    }

    fn shellLayout(self: *const App) app_shell_layout.Layout {
        return app_shell_layout.compute(self.terminal_size, .{ .page_bar_visible = true });
    }

    fn activePageStatus(self: *const App) ?*const app_state.StatusMessage {
        return switch (self.active_page) {
            .changes => &self.pages.changes.status,
            .repository => &self.pages.repository.status,
            .history => &self.pages.history.status,
            .compare => &self.pages.compare.status,
        };
    }

    fn activePageStatusMut(self: *App) ?*app_state.StatusMessage {
        return switch (self.active_page) {
            .changes => &self.pages.changes.status,
            .repository => &self.pages.repository.status,
            .history => &self.pages.history.status,
            .compare => &self.pages.compare.status,
        };
    }

    fn overlayScroll(self: *App) shell_input.OverlayScrollController {
        return .{
            .overlay = &self.overlay,
            .content_size = self.shellLayout().contentSize(),
            .help = app_view.helpContext(self.shellViewContext()),
            .remote_error_message = self.remoteWorkflowView().remoteErrorMessage(),
            .remote_error_operation = self.remoteWorkflowView().remoteErrorOperation(),
        };
    }

    fn openSelectedFileInEditor(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        try self.shellEffects().requestEditor(
            ctx,
            self.changesContent().editorTarget(),
            self.actionLifecycleView().hasPending(),
            self.shellEffects().changesOrigin(),
        );
    }

    fn copyCurrentLine(self: *App, ctx: *chasen.Ctx(Msg)) void {
        var content = self.changesContent().currentLineCopyText(ctx.allocator()) catch {
            self.setChangesStatus("could not prepare diff line for copying", .{});
            return;
        } orelse {
            self.setChangesStatus("no diff line selected", .{});
            return;
        };
        defer content.deinit(ctx.allocator());
        const unified = self.changesNavigationView().effectiveDisplayMode() == .unified;
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().changesOrigin() },
            .label = if (unified) "current diff line" else "current line",
            .text = content.text(),
        });
    }

    fn copyCurrentHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        var content = try self.changesContent().selectedHunkCopyText(ctx.allocator());
        defer content.deinit(ctx.allocator());
        const unified = self.changesNavigationView().effectiveDisplayMode() == .unified;
        switch (content) {
            .ready => |text| self.shellEffects().queueClipboard(ctx, .{
                .origin = .{ .page = self.shellEffects().changesOrigin() },
                .label = if (unified) "current hunk diff" else "current hunk",
                .text = text,
            }),
            .no_hunk => self.setChangesStatus("no hunk selected", .{}),
            .no_new_side => self.setChangesStatus("no new-side text in selected hunk", .{}),
        }
    }

    fn copyDiffSelection(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        copy: diff_surface.update.SelectionCopy,
    ) void {
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().changesOrigin() },
            .label = "diff selection",
            .text = copy.text,
            .selection_generation = copy.generation,
        });
    }

    fn finishSelectionCopy(
        self: *App,
        allocator: std.mem.Allocator,
        completion: shell_effects.SelectionCopyCompletion,
    ) void {
        switch (completion.origin.page_id) {
            .changes => _ = self.changesNavigation().clearCompletedSelectionAfterCopy(
                allocator,
                completion.generation,
            ),
            .compare => {
                var adapter = self.compareCoordinator().navigation().updateAdapter();
                if (adapter.bodyController().clearCompletedSelectionAfterCopy(
                    allocator,
                    completion.generation,
                )) self.pages.compare.diff.pinned_selection_basis = null;
            },
            .repository => _ = self.pages.repository.clearCompletedSelectionAfterCopy(
                allocator,
                completion.generation,
            ),
            .history => {
                var adapter = self.historyCoordinator().navigation().updateAdapter();
                if (adapter.bodyController().clearCompletedSelectionAfterCopy(
                    allocator,
                    completion.generation,
                )) self.pages.history.diff.pinned_selection_basis = null;
            },
        }
    }

    fn copySourceHeaderPath(self: *App, ctx: *chasen.Ctx(Msg), path: []const u8) void {
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().repositoryOrigin() },
            .label = "file path",
            .text = path,
        });
    }

    fn copyDiffHeaderPath(self: *App, ctx: *chasen.Ctx(Msg), selection: diff_selection.HeaderPathSelection) void {
        const path = self.changesContent().diffHeaderPath(selection) orelse return;
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().changesOrigin() },
            .label = "file path",
            .text = path,
        });
    }

    fn copyPopup(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const target = self.popupCopyTarget() orelse {
            self.setStatus("nothing to copy: popup", .{});
            return;
        };
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .shell_surface = .{
                .surface = .remote_error,
                .instance_id = self.overlay.remote_error_instance_id,
            } },
            .label = target.label,
            .text = target.text,
        });
    }

    fn copyFooterStatus(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const visible = app_state.resolveVisibleStatus(&self.status, self.activePageStatus()) orelse return;
        const source = visible.source;
        const target_status = switch (source) {
            .shell => &self.status,
            .page => self.activePageStatusMut() orelse return,
        };

        const effects = self.shellEffects();
        const origin = switch (self.active_page) {
            .changes => effects.changesOrigin(),
            .repository => effects.repositoryOrigin(),
            .history => effects.historyOrigin(),
            .compare => effects.compareOrigin(),
        };
        const queued = effects.queueClipboardAccepted(ctx, .{
            .origin = .{ .page = origin },
            .label = "status message",
            .text = visible.text,
        });

        // The runtime owns clipboard bytes once queueClipboard succeeds. On a
        // synchronous failure, the page-owned diagnostic already replaced a
        // page target; a shell target must still be cleared to reveal it.
        if (queued or source == .shell) target_status.clear();
    }

    fn popupCopyTarget(self: *const App) ?PopupCopyTarget {
        if (self.overlay.isRemoteError()) {
            const operation = self.remoteWorkflowView().remoteErrorOperation() orelse return null;
            const message = self.remoteWorkflowView().remoteErrorMessage() orelse return null;
            return .{
                .label = switch (operation) {
                    .push => "push error",
                    .pull => "pull error",
                    .switch_branch => "branch switch error",
                    .create_stash => "stash creation error",
                    .apply_stash => "stash apply error",
                    .drop_stash => "stash drop error",
                },
                .text = message,
            };
        }
        return null;
    }

    fn copyCommitMessage(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const panel = self.localWorkflowView().commitPanel();
        if (!panel.is_open) {
            self.setStatus("nothing to copy: commit message", .{});
            return;
        }
        const text = self.localWorkflow().formatCommitMessage(ctx.allocator()) catch {
            self.localWorkflow().markCommitCopyAllocationFailed();
            self.setStatus("could not prepare commit message copy", .{});
            return;
        };
        defer ctx.allocator().free(text);

        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .shell_surface = .{
                .surface = .commit_panel,
                .instance_id = panel.instance_id,
            } },
            .label = "commit message",
            .text = text,
        });
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.status.set(fmt, args);
    }

    fn setChangesStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.pages.changes.status.set(fmt, args);
    }

    /// Applies only the shell effects authorized by a completed repository
    /// commitment. A rejected capability open must not reload or reset the
    /// still-authoritative Changes or Compare page.
    fn finishChangesRepoDiscovery(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        finished: RepoDiscoveryFinished,
    ) !void {
        var pending = try self.changesRead().finishRepoDiscovery(ctx.allocator(), finished) orelse return;
        defer pending.deinit(ctx.allocator());
        const identity = pending.identity;
        const generation = pending.generation;
        const outcome = self.repoSession().commitDiscovered(
            ctx,
            pending.takeDiscovery(),
            0,
            .discovery_completion,
        ) catch |err| {
            self.changesRead().rejectAppliedRepoDiscovery(identity, generation);
            return err;
        };
        if (outcome == .rejected) {
            self.changesRead().rejectAppliedRepoDiscovery(identity, generation);
            try self.applyRepoSessionCommit(ctx, outcome, false);
            return;
        }

        if (self.transitionIdentity()) |current| self.screen_transition.rebindStartup(current);
        try self.changesRead().acceptRepoDiscoveryCommit(ctx);
        if (outcome == .changed and self.active_page == .compare) {
            try self.applyRepoSessionCommit(ctx, outcome, false);
        }
    }

    fn applyRepoSessionCommit(self: *App, ctx: *chasen.Ctx(Msg), outcome: repo_session.CommitOutcome, animate: bool) !void {
        switch (outcome) {
            .changed => {
                const intent = self.pageCoordinator().acceptedRepositoryChange(self.allocator orelse ctx.allocator());
                if (animate and self.config.transitions) {
                    if (self.transitionIdentity()) |identity| self.screen_transition.arm(identity);
                }
                try self.applyPageCoordinationIntent(ctx, intent);
            },
            .unchanged => {},
            .rejected => self.setStatus("Repository root could not be opened safely", .{}),
        }
    }

    pub fn selectionContext(self: *const App) context.SelectionContext {
        return initial_selection.contextForSelection(
            self.config.source,
            self.repoSessionView().activeRoot(),
            self.changesNavigationView().currentSelection(),
        );
    }
};

fn diffAutoScrollViewport(
    body: diff_surface.navigation.BodyController,
) ?drag_auto_scroll.Viewport {
    const body_view = body.view();
    const drag = body_view.view.surface.selection_owner.*.activeDiff() orelse return null;
    if (!body_view.dragSelectionIdentityCurrent(drag)) return null;
    const raw = body_view.view.rawDiffPaneGeometry() orelse return null;
    const visible_rows = body_view.view.diffVisibleRows();
    if (raw.width == 0 or visible_rows < 2) return null;
    const last_row_value = @as(usize, diff_render.body_start_row) + visible_rows - 1;
    if (last_row_value > std.math.maxInt(u16)) return null;
    return .{
        .first_col = raw.col,
        .last_col = raw.col + raw.width - 1,
        .first_row = diff_render.body_start_row,
        .last_row = @intCast(last_row_value),
    };
}

fn commandSessionForTest(text: []const u8) !CommandSession {
    var input: command_line.Active = .{};
    try input.input.insertSlice(text);
    return .{ .active = .{
        .input = input,
        .context = .{ .repository_source = .{
            .repo_epoch = 3,
            .activation_id = 2,
            .manifest_revision = 6,
            .source_revision = 7,
        } },
    } };
}

fn installCommandSourceForTest(app: *App, content: []const u8) !void {
    const source_document = @import("repository/source.zig");
    const content_fingerprint = @import("content_fingerprint.zig");
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, content);
    var document = try source_document.Document.initOwnedOrFree(
        allocator,
        bytes,
        content_fingerprint.Fingerprint.init(bytes),
    );
    errdefer document.deinit(allocator);
    const path = try allocator.dupe(u8, "command_demo.zig");
    errdefer allocator.free(path);

    app.active_page = .repository;
    app.terminal_size = .{ .width = 8, .height = 6 };
    app.pages.repository = .{
        .active = true,
        .activation_id = 2,
        .repo_epoch = 3,
        .root_identity = .{ .device = 4, .inode = 5 },
        .freshness = .fresh,
        .load_state = .loaded,
        .manifest_revision = 6,
        .source_revision = 7,
        .selected_path = path,
        .displayed_document = .{
            .path = path,
            .manifest_revision = 6,
            .source_revision = 7,
            .authority = .accepted,
            .value = .{ .source = document },
        },
        .viewer = .{
            .focus = .source,
            .tree_hidden = true,
            .source_horizontal_scroll = 2,
        },
    };
}

test "command line submission snapshots diagnostics and empty submit preserves status" {
    var app: App = .{};
    app.pages.repository.status.set("preserved", .{});
    app.command_session = try commandSessionForTest("");
    app.submitCommandLine();
    try std.testing.expect(app.commandLineView() == null);
    try std.testing.expectEqualStrings("preserved", app.pages.repository.status.text());

    app.command_session = try commandSessionForTest("0");
    app.submitCommandLine();
    try std.testing.expectEqualStrings("invalid line number", app.pages.repository.status.text());

    app.command_session = try commandSessionForTest("hoge");
    app.submitCommandLine();
    try std.testing.expectEqualStrings("unknown command: hoge", app.pages.repository.status.text());
}

test "command line stale target reconciliation closes without execution" {
    var app: App = .{ .active_page = .repository };
    app.command_session = try commandSessionForTest("20");

    _ = app.reconcileCommandLine();

    try std.testing.expect(app.commandLineView() == null);
    try std.testing.expectEqualStrings(
        "command source is no longer available",
        app.pages.repository.status.text(),
    );
}

test "command line root input reaches exact Repository jump and blocks mouse" {
    const allocator = std.testing.allocator;
    var app: App = .{};
    try installCommandSourceForTest(&app, "0123456789abcdef\n" ** 30);
    defer app.pages.repository.deinit(allocator);

    const open = app.handleEvent(.{ .key_press = .{ .codepoint = ':' } }) orelse
        return error.ExpectedCommandOpen;
    try std.testing.expect(open.command_line == .open);
    app.updateCommandLine(open.command_line);
    try std.testing.expect(app.commandLineView() != null);

    const mouse = chasen.Event{ .mouse = .{
        .col = 1,
        .row = 1,
        .button = .left,
        .mods = .{},
        .type = .press,
    } };
    try std.testing.expect(app.handleEvent(mouse) == null);

    for ("20") |digit| {
        const insert = app.handleEvent(.{ .key_press = .{ .codepoint = digit } }) orelse
            return error.ExpectedCommandInsert;
        app.updateCommandLine(insert.command_line);
    }
    const submit = app.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.enter } }) orelse
        return error.ExpectedCommandSubmit;
    app.updateCommandLine(submit.command_line);

    try std.testing.expect(app.commandLineView() == null);
    try std.testing.expectEqual(@as(usize, 19), app.pages.repository.viewer.source_cursor);
    try std.testing.expectEqual(@as(usize, 2), app.pages.repository.viewer.source_horizontal_scroll);
}

test "command line keeps input across resize and cancels on focus or page transition" {
    const allocator = std.testing.allocator;
    var app: App = .{};
    try installCommandSourceForTest(&app, "one\ntwo\nthree\n");
    defer app.pages.repository.deinit(allocator);
    var tc: chasen.testing.TestCtx(App.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    defer tc.resetTransient();

    app.updateCommandLine(.open);
    app.updateCommandLine(.{ .paste = "2🐈" });
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &tc.ctx);
    try std.testing.expectEqualStrings("2🐈", app.commandLineView().?.input.slice());

    try app.update(.focus_lost, &tc.ctx);
    try std.testing.expect(app.commandLineView() == null);

    app.updateCommandLine(.open);
    try std.testing.expect(app.commandLineView() != null);
    try app.update(.{ .switch_page = .compare }, &tc.ctx);
    try std.testing.expect(app.commandLineView() == null);
}
