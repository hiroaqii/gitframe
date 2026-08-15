//! Root application shell.
//!
//! `App` owns state composition, the Chasen lifecycle, exhaustive root message
//! dispatch, cross-owner outcome bridges, and process-facing boundaries. Page,
//! workflow, read, input, and foreground-effect details live in lower modules;
//! those modules consume short-lived typed views/controllers and never import
//! this root back.

const std = @import("std");
const chasen = @import("chasen");
const initial_selection = @import("app/initial_selection.zig");
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
const compare_navigation = @import("app/pages/compare/navigation.zig");
const review_page = @import("app/pages/review.zig");
const review_content = @import("app/pages/review/content.zig");
const review_action_fence = @import("app/pages/review/action_fence.zig");
const review_message = @import("app/pages/review/message.zig");
const review_navigation = @import("app/pages/review/navigation.zig");
const review_operations = @import("app/pages/review/operations.zig");
const review_read = @import("app/pages/review/read_coordinator.zig");
const review_page_update = @import("app/pages/review/update.zig");
const review_view = @import("app/pages/review/view.zig");
const repository_page = @import("app/pages/repository.zig");
const repository_coordinator = @import("app/pages/repository/coordinator.zig");
const repository_layout = @import("app/pages/repository/layout.zig");
const repo_session = @import("app/repo_session.zig");
const app_state = @import("app/state.zig");
const app_view = @import("app/view.zig");
const action_lifecycle = @import("app/workflow/action_lifecycle.zig");
const workflow_local = @import("app/workflow/local.zig");
const workflow_remote = @import("app/workflow/remote.zig");
const shell_effects = @import("app/shell_effects.zig");
const context = @import("context.zig");
const config_mod = @import("config.zig");
const diff_surface = @import("app/diff_surface.zig");
const diff_render = @import("diff/render.zig");
const diff_selection = @import("diff/selection.zig");
const diff_source = @import("diff/source.zig");
const keymap = @import("keymap");
const review_session = @import("review/session.zig");
const theme = @import("theme");

const auto_reload_timer_id = "gitframe.auto_reload";
const CliConfig = diff_source.CliConfig;

const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const LoadFinishedMsg = app_message.LoadFinished;
const ActionFinishedMsg = app_message.ActionFinished;
const ShellEffectFinishedMsg = app_message.ShellEffectFinished;

const PageStates = struct {
    review: review_page.ReviewPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    compare: compare_page.ComparePageState = .{},
    config: page.LazyPlaceholder = .{},
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
    active_page: page.Id = .review,
    repo_session: repo_session.State = .{},
    pages: PageStates = .{},
    config: CliConfig = .{},
    user_config: config_mod.Config = .{},
    keymap: keymap.Effective = .{},
    theme: theme.Palette = .default(),
    env_map: ?*std.process.Environ.Map = null,
    review_output: ?*review_session.Output = null,
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
    overlay: app_state.OverlayState = .{},
    shell_effects_state: shell_effects.State = .{},
    drag_auto_scroll: drag_auto_scroll.State = .{},

    const PopupCopyTarget = struct {
        label: []const u8,
        text: []const u8,
    };

    pub const Msg = app_message.Msg;

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
        self.local_workflow = workflow_local.LocalState.init(ctx.allocator());
        self.pages.review.init(self.config.auto_reload, self.user_config.reload, self.config.source);
        _ = self.pageCoordinator().activateReview();
        if (self.pages.review.auto_reload.enabled()) {
            try ctx.timer().every(auto_reload_timer_id, self.pages.review.auto_reload.interval_ns, .auto_reload_tick);
        }
        if (diff_source.sourceRequiresRepo(self.config.source)) {
            try self.reviewRead().startRepoDiscovery(ctx, null);
        } else {
            try self.reviewRead().startDiffLoad(ctx, .initial);
        }
    }

    pub fn deinit(self: *App, deinit_ctx: chasen.AppDeinitContext) void {
        if (self.allocator == null) self.allocator = deinit_ctx.allocator;
        self.pages.review.deinit(deinit_ctx.allocator);
        self.pages.repository.deinit(deinit_ctx.allocator);
        self.pages.compare.deinit(deinit_ctx.allocator);
        self.repo_session.deinit(deinit_ctx.allocator);
        self.local_workflow.deinit(deinit_ctx.allocator);
        self.remote_workflow.deinit(deinit_ctx.allocator);
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
            .action_pending = self.actionLifecycleView().hasPending(),
            .review = self.reviewRead().repositorySessionPort(),
            .repository = .{ .page = &self.pages.repository },
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
            .review = &self.pages.review,
            .repository = &self.pages.repository,
            .compare = &self.pages.compare,
            .config_page = &self.pages.config,
            .repo = self.repoSessionView(),
            .source = self.config.source,
            .body_size = self.shellLayout().bodySize(),
            .status = &self.status,
            .shell_blockers = .{
                .help = self.overlay.isHelp(),
                .commit_input = self.localWorkflowView().commitPanelOpen(),
                .confirmation = self.overlay.isDiscardFile() or self.overlay.isAmendCommit() or
                    self.overlay.isPushBranch() or self.overlay.isPullBranch(),
                .branch_switch = self.overlay.isSwitchBranch(),
                .push_error = self.overlay.isPushError(),
                .git_action = self.actionLifecycleView().hasPending(),
                .foreground_command = self.remoteWorkflowView().hasForeground() or self.shellEffectsView().hasEditorForeground(),
                .live_review_waiter = if (self.review_output) |output| !output.ready else false,
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
            .review_revalidation => try self.reviewRead().requestRevalidation(ctx),
            .review_repository_changed => try self.reviewRead().startDiffLoad(ctx, .repo_switch),
            .compare_refresh => try self.compareCoordinator().refresh(ctx),
        }
    }

    /// Builds the concrete Review navigation owner with only the shell inputs
    /// needed by Review-local cursor/search/selection logic. The controller
    /// deliberately cannot reach App, overlays, processes, or async effects.
    fn reviewNavigation(self: *App) review_navigation.Controller {
        const size = self.shellLayout().bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = .{ .width = size.width, .height = size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.review),
            .diagnostics = .{ .target = &self.pages.review.status },
        };
    }

    fn reviewNavigationView(self: *const App) review_navigation.View {
        const size = self.shellLayout().bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .source = self.config.source,
            .layout = .{ .width = size.width, .height = size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.review),
        };
    }

    fn displayModeToggleHintWidth(self: *const App, target: page.Id) u16 {
        const reachable = switch (target) {
            .review => !self.pages.review.search.mode and !self.pages.review.file_search.mode,
            .compare => !self.pages.compare.search.mode and
                !self.pages.compare.file_search.mode and
                !self.pages.compare.base_picker.open,
            .repository, .config => false,
        };
        if (!reachable) return 0;

        var key_buffer: [16]u8 = undefined;
        return diff_render.modeToggleHintWidth(
            self.keymap.display(.toggle_display_mode, key_buffer[0..]),
        );
    }

    fn reviewOperations(self: *const App) review_operations.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
            .activation_state = self.pages.review.activation.state,
        };
    }

    fn reviewContent(self: *const App) review_content.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.repoSessionView().activeRoot(),
        };
    }

    fn reviewOperationController(self: *App) review_operations.Controller {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigation(),
            .view_state = self.reviewOperations(),
        };
    }

    fn reviewActionFence(self: *App) review_action_fence.Controller {
        return .{
            .read_authority = &self.pages.review.repository_read_authority,
            .activation = &self.pages.review.activation,
            .action_cursor = &self.pages.review.action_cursor,
            .auto_reload = &self.pages.review.auto_reload,
            .review_projection = &self.pages.review.review_projection,
            .deferred_projection_apply = &self.pages.review.deferred_projection_apply,
        };
    }

    fn actionLifecycleView(self: *const App) action_lifecycle.View {
        return self.action_runtime.view();
    }

    fn actionLifecycle(self: *App) action_lifecycle.Controller {
        return .{
            .runtime = &self.action_runtime,
            .fence = self.reviewActionFence(),
        };
    }

    fn localWorkflowView(self: *const App) workflow_local.View {
        return self.local_workflow.view();
    }

    fn localWorkflow(self: *App) workflow_local.Controller {
        return .{
            .state = &self.local_workflow,
            .lifecycle = self.actionLifecycle(),
            .operations = self.reviewOperationController(),
            .repo = self.repoSessionView(),
            .current_review_root = self.currentReviewActionRoot(),
            .env_map = self.env_map,
            .user_config = &self.user_config,
            .status = &self.pages.review.status,
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
            .operations = self.reviewOperationController(),
            .repo = self.repoSessionView(),
            .current_review_root = self.currentReviewActionRoot(),
            .env_map = self.env_map,
            .active_page = self.active_page,
            .review_origin = origins.review(),
            .effect_snapshot = origins.snapshot,
            .status = &self.pages.review.status,
            .overlay = &self.overlay,
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn shellEffectsView(self: *const App) shell_effects.View {
        return self.shell_effects_state.view();
    }

    fn shellEffectOrigins(self: *const App) shell_effects.OriginContext {
        const repo_epoch = self.repoSessionView().epoch();
        const review_identity = self.pages.review.activation.currentIdentity();
        const compare_identity = self.pages.compare.activation.currentIdentity();
        return .{
            .snapshot = .{
                .active_page = self.active_page,
                .repo_epoch = repo_epoch,
                .review_activation_id = self.pages.review.activation.next_activation_id,
                .repository_activation_id = self.pages.repository.activation_id,
                .compare_activation_id = self.pages.compare.activation.next_activation_id,
                .push_error_instance_id = if (self.overlay.isPushError()) self.overlay.push_error_instance_id else null,
                .commit_panel_instance_id = self.localWorkflowView().commitPanelInstanceId(),
            },
            .review_repo_epoch = if (review_identity) |identity| identity.repo_epoch else repo_epoch,
            .repository_repo_epoch = self.pages.repository.repo_epoch,
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
                .review = &self.pages.review.status,
                .repository = &self.pages.repository.status,
                .compare = &self.pages.compare.status,
            },
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn currentReviewActionRoot(self: *const App) ?[]const u8 {
        if (self.active_page != .review or
            self.pages.review.activation.currentIdentity() == null or
            diff_source.sourceIsOneShotInput(self.config.source)) return null;
        return self.repoSessionView().activeRoot();
    }

    fn reviewRead(self: *App) review_read.Controller {
        const body_size = self.shellLayout().bodySize();
        return .{
            .page_state = &self.pages.review,
            .fence = self.reviewActionFence().view(),
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

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        self.redraw_plan = .{};
        defer if (self.redraw_plan.resolvesToSkip()) ctx.redraw().skip();
        defer self.reconcileDragAutoScroll(ctx);
        self.clearEphemeralStatusForUserAction(msg);

        switch (msg) {
            .switch_page => |target| {
                self.drag_auto_scroll.clear();
                try self.applyPageCoordinationIntent(
                    ctx,
                    self.pageCoordinator().requestSwitch(self.allocator orelse ctx.allocator(), target),
                );
            },
            .terminal_resized => |size| {
                // Mouse coordinates are relative to the old geometry. End the
                // borrow before changing layout, then drain deferred owners at
                // the common post-update boundary below.
                self.drag_auto_scroll.clear();
                const review_selection_anchor = self.reviewNavigation().captureSelectionViewportAnchor();
                self.reviewNavigation().clearDiffSelection();
                const previous_compare_view = self.compareCoordinator().navigationView();
                var previous_compare_adapter = previous_compare_view.resolver();
                const previous_compare_body = previous_compare_view.bodyView(&previous_compare_adapter);
                const compare_selection_anchor = previous_compare_body.captureSelectionViewportAnchor();
                self.pages.compare.selection_owner = .none;
                const repository_selection_anchor = self.pages.repository.captureSelectionViewportAnchor();
                self.pages.repository.cancelMouseOwner();
                const previous_width = self.reviewNavigationView().diffPaneWidth();
                const previous_mode = self.reviewNavigationView().effectiveDisplayMode();
                const previous_compare_width = previous_compare_body.view.diffPaneWidth();
                const previous_compare_mode = previous_compare_body.view.effectiveDisplayMode();
                self.terminal_size = size;
                self.reviewNavigation().resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
                if (previous_mode != self.reviewNavigationView().effectiveDisplayMode()) self.reviewNavigation().clearDiffSelection();
                if (review_selection_anchor) |anchor| self.reviewNavigation().restoreSelectionViewportAnchor(anchor);
                self.reviewNavigation().clampSidebarHorizontalScroll();
                self.reviewNavigation().clampDiffNavigationKeepingHunkVisible();
                self.reviewNavigation().updateSearchMatchOffset();
                self.reviewNavigation().scrollSearchMatchIntoView();
                self.reviewNavigation().clampDiffNavigation();
                const compare_controller = self.compareCoordinator().navigation();
                var compare_adapter = compare_controller.updateAdapter();
                var compare_body = compare_adapter.bodyController();
                compare_body.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_compare_width);
                if (previous_compare_mode != compare_body.controller.view().effectiveDisplayMode()) {
                    compare_body.controller.clearDiffSelection();
                    self.pages.compare.advanceSelectionLayoutRevision();
                }
                if (compare_selection_anchor) |anchor| compare_body.restoreSelectionViewportAnchor(anchor);
                compare_body.controller.clampSidebarHorizontalScroll();
                compare_body.clampDiffNavigationKeepingHunkVisible();
                compare_body.updateSearchMatchOffset();
                compare_body.controller.scrollSearchMatchIntoView();
                compare_body.clampDiffNavigation();
                const repository_body_size = self.shellLayout().bodySize();
                if (repository_selection_anchor) |anchor|
                    self.pages.repository.restoreSelectionViewportAnchor(anchor, repository_body_size)
                else
                    self.pages.repository.clampForBodySize(repository_body_size);
                self.overlayScroll().clampHelp();
                self.overlayScroll().clampPushError();
            },
            .load_finished => |finished| try self.finishLoadResult(ctx, finished),
            .action_finished => |finished| try self.finishActionResult(ctx, finished),
            .push_inspection_finished => |finished| try self.remoteWorkflow().finishPushInspection(ctx, finished),
            .push_upstream_finalize_finished => |finished| try self.applyRemoteOutcome(
                ctx,
                self.remoteWorkflow().finishPushUpstreamFinalize(ctx.allocator(), finished),
            ),
            .shell_effect_finished => |finished| try self.finishShellEffect(ctx, finished),
            .review => |review_msg| _ = try self.updateReview(ctx, review_msg),
            .compare => |compare_msg| _ = try self.updateCompare(ctx, compare_msg),
            .repository => |repository_msg| _ = self.updateRepository(ctx, repository_msg),
            .mouse_selection_drag => |continuation| try self.updateMouseSelectionDrag(ctx, continuation),
            .mouse_selection_release => |continuation| try self.updateMouseSelectionRelease(ctx, continuation),
            .drag_auto_scroll_tick => |generation| try self.updateDragAutoScrollTick(ctx, generation),
            .cancel_commit_panel => self.localWorkflow().closeCommitPanel(),
            .submit_commit_panel => {
                if (self.localWorkflowView().commitPanel().mode == .amend) {
                    self.remoteWorkflow().cancelPushConfirmation(ctx.allocator());
                    self.remoteWorkflow().cancelPullConfirmation(ctx.allocator());
                }
                try self.localWorkflow().submitCommitPanel(ctx);
            },
            .assist_commit_message => try self.localWorkflow().assistCommitMessage(ctx),
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
                if (self.active_page == .repository) self.pages.repository.cancelMouseOwner();
                try self.repoSession().enterPicker(ctx.allocator());
            },
            .cancel_repo_picker => try self.repoSession().cancelPicker(ctx.allocator()),
            .close_repo_picker => self.repoSession().closePicker(ctx.allocator()),
            .submit_repo_picker => {
                if (try self.repoSession().submitPicker(ctx)) |outcome| {
                    try self.applyRepoSessionCommit(ctx, outcome);
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
                if (self.active_page == .review) self.reviewNavigation().clearDiffSelection();
                if (self.active_page == .compare) self.pages.compare.selection_owner = .none;
                if (self.active_page == .repository) self.pages.repository.cancelMouseOwner();
                self.overlay.openHelpForPage(self.active_page);
            },
            .close_help => self.overlay.close(),
            .help_scroll_up => self.overlayScroll().scrollHelp(-1),
            .help_scroll_down => self.overlayScroll().scrollHelp(1),
            .help_page_up => self.overlayScroll().pageHelp(-1),
            .help_page_down => self.overlayScroll().pageHelp(1),
            .push_error_scroll_up => self.overlayScroll().scrollPushError(-1),
            .push_error_scroll_down => self.overlayScroll().scrollPushError(1),
            .push_error_page_up => self.overlayScroll().pagePushError(-1),
            .push_error_page_down => self.overlayScroll().pagePushError(1),
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
            .confirm_branch_switch => try self.remoteWorkflow().confirmBranchSwitch(ctx),
            .cancel_branch_switch => self.remoteWorkflow().clearBranchSwitch(ctx.allocator()),
            .close_push_error => self.remoteWorkflow().clearPushError(ctx.allocator()),
            .run_interactive_push => try self.remoteWorkflow().runInteractivePush(ctx),
            .reload => switch (self.active_page) {
                .review => {
                    switch (self.reviewRead().prepareManualReload()) {
                        .blocked => {},
                        .ready => {
                            self.remoteWorkflow().clearBranchSwitch(ctx.allocator());
                            try self.reviewRead().startPreparedManualReload(ctx);
                        },
                    }
                },
                .repository => self.repositoryCoordinator().requestReload(),
                .compare => try self.compareCoordinator().refresh(ctx),
                .config => self.status.set("reload is not available on this page yet", .{}),
            },
            .auto_reload_tick => try self.reviewRead().autoReloadTick(ctx),
            .focus_lost => {
                self.drag_auto_scroll.clear();
                switch (self.active_page) {
                    .review => self.reviewNavigation().clearDiffSelection(),
                    .repository => self.pages.repository.cancelMouseOwner(),
                    .compare => self.pages.compare.selection_owner = .none,
                    .config => {},
                }
            },
            .git_action_spinner_tick => if (self.actionLifecycle().tick(ctx)) self.redraw_plan.requestSkip(),
            .cancel_remote_action => _ = self.remoteWorkflow().cancelActiveRemote(false),
            .quit => {
                self.drag_auto_scroll.clear();
                self.requestQuit(ctx);
            },
        }
        self.reviewRead().retireSupersededActionCursor(ctx, self.actionLifecycleView().generation());
        try self.reviewRead().applyDeferredSourceIfReady(ctx);
        try self.reviewRead().applyDeferredProjectionIfReady(ctx);
        if (try self.compareCoordinator().applyDeferred(ctx) == .skip) self.redraw_plan.requestSkip();
        try self.reviewRead().maybeStartQueuedRevalidation(ctx);
        try self.repositoryCoordinator().startPending(ctx);
        const revalidation_queued_before_projection = self.reviewRead().hasQueuedFullRevalidation();
        if (self.active_page == .review) try self.reviewRead().ensureProjection(ctx);
        // Boundary inert retention queues its repair revalidation inside
        // ensureReviewProjection, after the consumption point above already
        // ran. Consume a queue born in this tail so the repair starts in the
        // same cycle even with watch off and no further input. Pre-existing
        // queued intent keeps its single consumption point above.
        if (!revalidation_queued_before_projection and
            self.reviewRead().hasQueuedFullRevalidation())
        {
            try self.reviewRead().maybeStartQueuedRevalidation(ctx);
        }
        self.actionLifecycle().reconcileSpinner(ctx);
        if (!self.redraw_plan.resolvesToSkip() and
            self.active_page == .compare and
            self.pages.compare.base_picker.open)
        {
            self.compareCoordinator().prepareModalRedraw(ctx.io());
        }
        if (!self.redraw_plan.resolvesToSkip() and self.overlay.isSwitchBranch()) {
            self.remoteWorkflow().prepareBranchSwitchModalRedraw(ctx.io());
        }
    }

    fn requestQuit(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.actionLifecycleView().hasPending()) {
            if (self.remoteWorkflow().cancelActiveRemote(true)) return;
            self.setStatus("finish current git action before quitting", .{});
            return;
        }
        self.teardown_requested = true;
        ctx.quit();
    }

    fn updateMouseSelectionDrag(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        continuation: app_message.MouseSelectionContinuation,
    ) !void {
        const target: drag_auto_scroll.Target = switch (continuation.target) {
            .review => |point| blk: {
                if (self.active_page != .review) break :blk .review;
                _ = try self.updateReview(ctx, .{ .mouse_diff_drag = point });
                break :blk .review;
            },
            .compare => |point| blk: {
                if (self.active_page != .compare) break :blk .compare;
                _ = try self.updateCompare(ctx, .{ .shared = .{ .mouse_diff_drag = point } });
                break :blk .compare;
            },
            .repository => |point| blk: {
                if (self.active_page != .repository) break :blk .repository;
                _ = self.updateRepository(ctx, .{ .mouse_owner_drag = point });
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
            .review => |point| {
                if (self.active_page == .review) _ = try self.updateReview(ctx, .{ .mouse_diff_release = point });
            },
            .compare => |point| {
                if (self.active_page == .compare) _ = try self.updateCompare(ctx, .{ .shared = .{ .mouse_diff_release = point } });
            },
            .repository => |point| {
                if (self.active_page == .repository) _ = self.updateRepository(ctx, .{ .mouse_owner_release = point });
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
            .review => try self.updateReview(ctx, .{ .mouse_diff_auto_scroll_step = active.intent }),
            .compare => try self.updateCompare(ctx, .{ .shared = .{ .mouse_diff_auto_scroll_step = active.intent } }),
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
                break :blk self.updateRepository(ctx, .{ .mouse_source_auto_scroll_step = .{
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
            .review => page.Id.review,
            .compare => page.Id.compare,
            .repository => page.Id.repository,
        }) return null;

        return switch (target) {
            .review => blk: {
                var adapter = self.reviewNavigation().updateAdapter();
                break :blk diffAutoScrollViewport(adapter.shared().navigation);
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
            .{ .drag_auto_scroll_tick = active.generation },
        ) catch {
            if (self.drag_auto_scroll.active) |current| {
                if (current.generation == active.generation) self.drag_auto_scroll.clear();
            }
            return;
        };
        self.drag_auto_scroll.scheduled_generation = active.generation;
    }

    fn updateReview(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: review_message.Msg,
    ) !?drag_auto_scroll.StepOutcome {
        var page_update = try (review_page_update.Controller{
            .navigation = self.reviewNavigation(),
        }).apply(self.allocator, msg);
        defer page_update.deinit(self.allocator);
        const auto_scroll = page_update.auto_scroll;

        if (page_update.capture_display_override) {
            try self.reviewRead().captureDisplayOverride(ctx.allocator());
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
            .request_branch_switch => try self.requestRemoteBranchSwitch(ctx),
            .open_selected_file_in_editor => try self.openSelectedFileInEditor(ctx),
            .copy_current_line => self.copyCurrentLine(ctx),
            .copy_current_hunk => try self.copyCurrentHunk(ctx),
            .copy_diff_selection => |text| self.copyDiffSelection(ctx, text),
            .copy_diff_header_path => |selection| self.copyDiffHeaderPath(ctx, selection),
            .finish_review => |decision| try self.finishReview(ctx, decision),
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
        if (outcome.takeClipboard()) |taken| {
            var effect = taken;
            defer effect.deinit(ctx.allocator());
            self.shellEffects().queueClipboard(ctx, .{
                .origin = effect.origin,
                .label = effect.label,
                .text = effect.text,
            });
        }
        return auto_scroll;
    }

    fn updateRepository(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: repository_page.Msg,
    ) ?drag_auto_scroll.StepOutcome {
        var outcome = self.repositoryCoordinator().update(ctx, msg);
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
            });
        }
        return auto_scroll;
    }

    fn finishLoadResult(self: *App, ctx: *chasen.Ctx(Msg), finished: LoadFinishedMsg) !void {
        switch (finished) {
            .review => |review_result| switch (review_result) {
                .source => |result| try self.reviewRead().finishDiffLoad(ctx.allocator(), result),
                .status => |result| try self.reviewRead().finishStatusLoad(ctx.allocator(), result),
                .branch_status => |result| self.reviewRead().finishBranchStatusLoad(ctx.allocator(), result),
                .projection => |result| try self.reviewRead().finishProjectionLoad(ctx.allocator(), result),
                .projection_syntax => |result| self.reviewRead().finishGeneratedProjectionSyntax(ctx.allocator(), result),
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
                        try self.applyRepoSessionCommit(ctx, outcome);
                    }
                },
                .branch_list => |result| try self.remoteWorkflow().finishBranchListLoad(ctx.allocator(), result),
            },
            .coordinator => |coordinator_result| switch (coordinator_result) {
                .repo_discovery => |result| try self.finishReviewRepoDiscovery(ctx, result),
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
            .assist_commit_message => |result| self.localWorkflow().finishCommitMessageAssist(ctx.allocator(), result),
            .amend => |result| try self.applyLocalActionIntent(ctx, self.localWorkflow().finishAmend(ctx.allocator(), result)),
            .push => |result| try self.applyRemoteOutcome(ctx, try self.remoteWorkflow().finishPush(ctx.allocator(), result)),
            .pull => |result| try self.applyRemoteOutcome(ctx, self.remoteWorkflow().finishPull(ctx.allocator(), result)),
            .fetch => |result| try self.applyRemoteOutcome(ctx, self.remoteWorkflow().finishFetch(ctx.allocator(), result)),
            .switch_branch => |result| try self.applyRemoteOutcome(ctx, self.remoteWorkflow().finishSwitchBranch(ctx.allocator(), result)),
            .push_foreground => |result| try self.applyRemoteOutcome(ctx, try self.remoteWorkflow().finishPushForeground(ctx, result)),
        }
    }

    fn finishShellEffect(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        finished: ShellEffectFinishedMsg,
    ) !void {
        switch (finished) {
            .editor => |result| if (self.shellEffects().finishEditor(result) == .reload_review) {
                try self.reviewRead().reloadAfterEditor(ctx);
            },
            .clipboard => |result| self.shellEffects().finishClipboard(result),
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
        if (outcome.reload != .none) {
            try self.reviewRead().applyEffectReload(ctx, outcome.reload);
        }
        if (outcome.quit_after_terminal) {
            self.teardown_requested = true;
            ctx.quit();
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
        try self.reviewRead().applyActionOutcome(
            ctx,
            intent.pending,
            intent.active_matches,
            intent.reload,
        );
    }

    fn clearEphemeralStatusForUserAction(self: *App, msg: Msg) void {
        if (app_message.keepsEphemeralStatus(msg)) return;
        self.status.clearIfEphemeral();
        if (self.active_page == .review) self.pages.review.status.clearIfEphemeral();
        if (self.active_page == .compare) self.pages.compare.status.clearIfEphemeral();
        if (self.active_page == .repository) self.pages.repository.status.clearIfEphemeral();
    }

    pub fn view(self: *const App, surface: *chasen.Surface) !void {
        return app_view.view(self.shellViewContext(), surface);
    }

    fn shellViewContext(self: *const App) app_view.Context {
        const body_size = self.shellLayout().bodySize();
        const repo_view = self.repoSessionView();
        const picker = repo_view.picker();
        const local = self.localWorkflowView();
        const remote = self.remoteWorkflowView();
        return .{
            .review = self.reviewViewContext(),
            .compare = .{
                .page = &self.pages.compare,
                .palette = self.theme,
                .repo_root = self.repoSessionView().activeRoot(),
                .repo_epoch = self.repoSessionView().epoch(),
                .root_identity = self.repoSessionView().activeIdentity(),
                .layout = .{ .width = body_size.width, .height = body_size.height },
                .keymap = self.keymap,
            },
            .repository = .{
                .page_state = &self.pages.repository,
                .palette = self.theme,
                .keymap = self.keymap,
                .repo_root = self.repoSessionView().activeRoot(),
            },
            .active_page = self.active_page,
            .page_bar_visible = true,
            .review_mode = self.config.review_mode,
            .theme = self.theme,
            .keymap = self.keymap,
            .terminal_size = self.terminal_size,
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
            .push_error_message = remote.pushErrorMessage(),
            .push_retry_target = remote.pushRetryTarget(),
            .push_retry_inspecting = remote.pushRetryInspecting(),
            .branch_switch = remote.branchSwitch(),
            .staged_summary = switch (self.reviewOperations().commitSummary()) {
                .unavailable => .unavailable,
                .loading_or_stale => .loading_or_stale,
                .ready => |ready| .{ .ready = .{ .count = ready.count } },
            },
        };
    }

    fn reviewEmptyRemoteActionHints(self: *const App) review_view.EmptyRemoteActionHints {
        var hints: review_view.EmptyRemoteActionHints = .{
            .show_repo_picker = self.repoSessionView().hasWorkspace(),
        };
        // The empty-state hint is only a display projection, but `U` is still a
        // mutating operation. Keep it tied to the same target gate as the real
        // request path so stale or missing clean-status snapshots cannot be
        // advertised as safe pull capability.
        if (self.reviewOperations().pullTarget() == .ready) hints.show_pull = true;
        if (self.reviewOperations().fetchTarget() == .ready) {
            hints.show_fetch = true;
        }
        return hints;
    }

    fn reviewViewContext(self: *const App) review_view.Context {
        return review_view.Context.init(
            &self.pages.review,
            self.reviewNavigationView(),
            self.theme,
            self.keymap,
            self.config.sourceLabel(),
            self.config.source,
            self.repoSessionView().activeRoot(),
            self.reviewEmptyRemoteActionHints(),
        );
    }

    pub fn handleEvent(self: *const App, event: chasen.Event) ?Msg {
        return self.shellInputView().handleEvent(event);
    }

    fn shellInputView(self: *const App) shell_input.View {
        const layout = self.shellLayout();
        const body_size = layout.bodySize();
        const repo = self.repoSessionView();
        const picker = repo.picker();
        const compare_navigation_view: compare_navigation.View = .{
            .page = &self.pages.compare,
            .repo_root = repo.activeRoot(),
            .repo_epoch = repo.epoch(),
            .root_identity = repo.activeIdentity(),
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.compare),
        };
        var compare_body_adapter = compare_navigation_view.resolver();
        const compare_body_view = compare_navigation_view.bodyView(&compare_body_adapter);
        const review_navigation_view = self.reviewNavigationView();
        return .{
            .active_page = self.active_page,
            .review = .{
                .key = .{
                    .search_mode = self.pages.review.search.mode,
                    .file_search_mode = self.pages.review.file_search.mode,
                    .search_query_len = self.pages.review.search.query.len,
                    .focus = self.pages.review.viewer.focus,
                    .sidebar_hidden = self.pages.review.viewer.sidebar_hidden,
                    .review_mode = self.config.review_mode,
                    .retained_selection_action_available = review_navigation_view.retainedSelectionActionAvailable(),
                    .keymap = self.keymap,
                },
                .selection_owner = &self.pages.review.selection_owner,
                .loaded = review_navigation_view.activeLoadedDiffConst(),
                .selected_node = self.pages.review.viewer.selected_node,
                .sidebar_hidden = self.pages.review.viewer.sidebar_hidden,
                .sidebar_width = self.pages.review.viewer.sidebar_width,
            },
            .compare = .{
                .key = .{
                    .search_mode = self.pages.compare.search.mode,
                    .file_search_mode = self.pages.compare.file_search.mode,
                    .search_query_len = self.pages.compare.search.query.len,
                    .focus = self.pages.compare.viewer.focus,
                    .sidebar_hidden = self.pages.compare.viewer.sidebar_hidden,
                    .base_picker_open = self.pages.compare.base_picker.open,
                    .base_picker_query_mode = self.pages.compare.base_picker.input_mode == .query,
                    .base_picker_query_len = self.pages.compare.base_picker.query.len,
                    .retained_selection_action_available = compare_body_view.retainedSelectionActionAvailable(),
                    .keymap = self.keymap,
                },
                .selection_owner = &self.pages.compare.selection_owner,
                .loaded = compare_body_view.view.activeLoadedDiffConst(),
                .selected_node = self.pages.compare.viewer.selected_node,
                .sidebar_hidden = self.pages.compare.viewer.sidebar_hidden,
                .sidebar_width = self.pages.compare.viewer.sidebar_width,
            },
            .repository = .{
                .key = self.pages.repository.inputContext(self.keymap),
                .page_state = &self.pages.repository,
            },
            .commit_panel_mode = self.localWorkflowView().commitPanelOpen(),
            .repo_picker_mode = picker.model.mode,
            .repo_picker_input_mode = picker.model.input_mode,
            .remote_action_cancelable = self.remoteWorkflowView().canCancel(self.actionLifecycleView().acceptedPending()),
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
            .review => &self.pages.review.status,
            .repository => &self.pages.repository.status,
            .compare => &self.pages.compare.status,
            .config => null,
        };
    }

    fn activePageStatusMut(self: *App) ?*app_state.StatusMessage {
        return switch (self.active_page) {
            .review => &self.pages.review.status,
            .repository => &self.pages.repository.status,
            .compare => &self.pages.compare.status,
            .config => null,
        };
    }

    fn overlayScroll(self: *App) shell_input.OverlayScrollController {
        return .{
            .overlay = &self.overlay,
            .content_size = self.shellLayout().contentSize(),
            .push_error_message = self.remoteWorkflowView().pushErrorMessage(),
        };
    }

    fn openSelectedFileInEditor(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        try self.shellEffects().requestEditor(
            ctx,
            self.reviewContent().editorTarget(),
            self.actionLifecycleView().hasPending(),
            self.shellEffects().reviewOrigin(),
        );
    }

    fn copyCurrentLine(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const text = self.reviewContent().currentLineCopyText() orelse {
            self.setReviewStatus("no diff line selected", .{});
            return;
        };
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().reviewOrigin() },
            .label = "current line",
            .text = text,
        });
    }

    fn copyCurrentHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        var content = try self.reviewContent().selectedHunkCopyText(ctx.allocator());
        defer content.deinit(ctx.allocator());
        switch (content) {
            .ready => |text| self.shellEffects().queueClipboard(ctx, .{
                .origin = .{ .page = self.shellEffects().reviewOrigin() },
                .label = "current hunk",
                .text = text,
            }),
            .no_hunk => self.setReviewStatus("no hunk selected", .{}),
            .no_new_side => self.setReviewStatus("no new-side text in selected hunk", .{}),
        }
    }

    fn copyDiffSelection(self: *App, ctx: *chasen.Ctx(Msg), text: []const u8) void {
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().reviewOrigin() },
            .label = "diff selection",
            .text = text,
        });
    }

    fn copySourceSelection(self: *App, ctx: *chasen.Ctx(Msg), text: []const u8) void {
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().repositoryOrigin() },
            .label = "source selection",
            .text = text,
        });
    }

    fn copySourceHeaderPath(self: *App, ctx: *chasen.Ctx(Msg), path: []const u8) void {
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().repositoryOrigin() },
            .label = "file path",
            .text = path,
        });
    }

    fn copyDiffHeaderPath(self: *App, ctx: *chasen.Ctx(Msg), selection: diff_selection.HeaderPathSelection) void {
        const path = self.reviewContent().diffHeaderPath(selection) orelse return;
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().reviewOrigin() },
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
                .surface = .push_error,
                .instance_id = self.overlay.push_error_instance_id,
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
            .review => effects.reviewOrigin(),
            .repository => effects.repositoryOrigin(),
            .compare => effects.compareOrigin(),
            .config => return,
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
        if (self.overlay.isPushError()) {
            const message = self.remoteWorkflowView().pushErrorMessage() orelse return null;
            return .{
                .label = "push error",
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

    fn setReviewStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.pages.review.status.set(fmt, args);
    }

    pub fn exportInitialSelectionContextJson(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent_environment: ?*const std.process.Environ.Map,
        config: CliConfig,
        writer: *std.Io.Writer,
    ) !void {
        return initial_selection.exportContextJson(allocator, io, parent_environment, config, writer);
    }

    /// Applies only the shell effects authorized by a completed repository
    /// commitment. A rejected capability open must not reload or reset the
    /// still-authoritative Review or Compare page.
    fn finishReviewRepoDiscovery(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        finished: RepoDiscoveryFinished,
    ) !void {
        var pending = try self.reviewRead().finishRepoDiscovery(ctx.allocator(), finished) orelse return;
        defer pending.deinit(ctx.allocator());
        const identity = pending.identity;
        const generation = pending.generation;
        const outcome = self.repoSession().commitDiscovered(
            ctx,
            pending.takeDiscovery(),
            0,
            .discovery_completion,
        ) catch |err| {
            self.reviewRead().rejectAppliedRepoDiscovery(identity, generation);
            return err;
        };
        if (outcome == .rejected) {
            self.reviewRead().rejectAppliedRepoDiscovery(identity, generation);
            try self.applyRepoSessionCommit(ctx, outcome);
            return;
        }

        try self.reviewRead().acceptRepoDiscoveryCommit(ctx);
        if (outcome == .changed and self.active_page == .compare) {
            try self.applyRepoSessionCommit(ctx, outcome);
        }
    }

    fn applyRepoSessionCommit(self: *App, ctx: *chasen.Ctx(Msg), outcome: repo_session.CommitOutcome) !void {
        switch (outcome) {
            .changed => try self.applyPageCoordinationIntent(
                ctx,
                self.pageCoordinator().acceptedRepositoryChange(),
            ),
            .unchanged => {},
            .rejected => self.setStatus("Repository root could not be opened safely", .{}),
        }
    }

    fn finishReview(self: *App, ctx: *chasen.Ctx(Msg), decision: review_session.Decision) !void {
        if (self.actionLifecycleView().hasPending()) {
            self.setReviewStatus("finish current git action before finishing review", .{});
            return;
        }

        if (decision != .canceled and
            (self.active_page != .review or !self.pages.review.activation.state.satisfiesAction(.read_diff)))
        {
            self.setReviewStatus("review source is still being validated", .{});
            return;
        }

        const output = self.review_output orelse {
            self.setReviewStatus("review output is not configured", .{});
            return;
        };

        var reviewed_paths: std.ArrayList([]const u8) = .empty;
        defer reviewed_paths.deinit(ctx.allocator());
        self.pages.review.reviewed_store.appendPathKeysForRepo(ctx.allocator(), self.repoSessionView().activeRoot(), &reviewed_paths) catch {
            self.setReviewStatus("could not finalize review result", .{});
            return;
        };
        std.mem.sort([]const u8, reviewed_paths.items, {}, pathLessThan);

        // Quit only after serialization succeeds; otherwise the TUI remains
        // open and stdout never receives a partial machine-readable result.
        output.set(ctx.allocator(), decision, self.selectionContext(), reviewed_paths.items) catch {
            self.setReviewStatus("could not finalize review result", .{});
            return;
        };
        self.teardown_requested = true;
        ctx.quit();
    }

    pub fn selectionContext(self: *const App) context.SelectionContext {
        return initial_selection.contextForSelection(
            self.config.source,
            self.repoSessionView().activeRoot(),
            self.reviewNavigationView().currentSelection(),
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

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}
