const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const ui = if (builtin.is_test) @import("chasen_ui") else struct {};
const app_actions = @import("app/actions.zig");
const app_commit_panel = @import("app/commit_panel.zig");
const app_input = @import("app/input.zig");
const app_load = @import("app/load.zig");
const app_message = @import("app/message.zig");
const page = @import("app/page.zig");
const page_coordinator = @import("app/page_coordinator.zig");
const app_shell_layout = @import("app/shell_layout.zig");
const compare_page = @import("app/pages/compare.zig");
const compare_coordinator = @import("app/pages/compare/coordinator.zig");
const compare_navigation = @import("app/pages/compare/navigation.zig");
const diff_surface = @import("app/diff_surface.zig");
const diff_basis = @import("app/diff_basis.zig");
const review_page = @import("app/pages/review.zig");
const review_content = @import("app/pages/review/content.zig");
const review_action_fence = @import("app/pages/review/action_fence.zig");
const review_layout = @import("app/pages/review/layout.zig");
const review_message = @import("app/pages/review/message.zig");
const review_navigation = @import("app/pages/review/navigation.zig");
const review_authority = if (builtin.is_test) @import("app/diff_surface/authority.zig") else struct {};
const review_operations = @import("app/pages/review/operations.zig");
const review_read = @import("app/pages/review/read_coordinator.zig");
const review_reload = if (builtin.is_test) @import("app/pages/review/reload.zig") else struct {};
const review_page_update = @import("app/pages/review/update.zig");
const review_view = @import("app/pages/review/view.zig");
const repository_page = @import("app/pages/repository.zig");
const repository_coordinator = @import("app/pages/repository/coordinator.zig");
const app_projection_component = if (builtin.is_test) @import("app/projection_component.zig") else struct {};
const repo_session = @import("app/repo_session.zig");
const app_review_projection = if (builtin.is_test) @import("app/review_projection.zig") else struct {};
const app_state = @import("app/state.zig");
const app_test_support = if (builtin.is_test) @import("app/test_support.zig") else struct {};
const app_view = @import("app/view.zig");
const action_lifecycle = @import("app/workflow/action_lifecycle.zig");
const workflow_local = @import("app/workflow/local.zig");
const workflow_remote = @import("app/workflow/remote.zig");
const shell_effects = @import("app/shell_effects.zig");
const context = @import("context.zig");
const context_export = @import("context_export.zig");
const config_mod = @import("config.zig");
const content_fingerprint = @import("content_fingerprint.zig");
const diff_presentation_identity = if (builtin.is_test) @import("diff/presentation_identity.zig") else struct {};
const diff_file = @import("diff/file.zig");
const diff_hunk_projection = if (builtin.is_test) @import("diff/hunk_projection.zig") else struct {};
const diff_render = if (builtin.is_test) @import("diff/render.zig") else struct {};
const diff_selection = @import("diff/selection.zig");
const diff_source = @import("diff/source.zig");
const file_tree = @import("file_tree.zig");
const git_ops = @import("app/git_ops.zig");
const git_branch_status = if (builtin.is_test) @import("git/branch_status.zig") else struct {};
const git_status = @import("git/status.zig");
const keymap = @import("keymap");
const loaded_diff = @import("loaded_diff.zig");
const repo_discovery = @import("repo/discovery.zig");
const repo_root_capability = @import("repo/root_capability.zig");
const review_session = @import("review/session.zig");
const theme = @import("theme");

const auto_reload_timer_id = "gitframe.auto_reload";
const SourceMode = diff_source.SourceMode;
const CliConfig = diff_source.CliConfig;

const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const LoadedDiff = loaded_diff.LoadedDiff;
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(app_message.Msg);
const BranchStatusLoadFinished = app_load.BranchStatusLoadFinished;
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const CompareLoadFinished = app_load.CompareLoadFinished;
const StatusLoadFinished = app_load.StatusLoadFinished;
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const ReviewProjectionFinished = app_load.ReviewProjectionFinished;
const ReviewProjectionTask = app_load.ReviewProjectionTask(app_message.Msg);
const GeneratedSyntaxTask = app_load.GeneratedSyntaxTask(app_message.Msg);
const AmendFinished = app_actions.AmendFinished;
const CommitFinished = app_actions.CommitFinished;
const DiscardFileFinished = app_actions.DiscardFileFinished;
const TargetKind = git_ops.TargetKind;
const MousePane = enum {
    sidebar,
    diff,
};

const ActiveDiffSelectionOwner = union(enum) {
    review: *const diff_selection.Owner,
    compare: *const diff_selection.Owner,

    fn active(self: ActiveDiffSelectionOwner) bool {
        return switch (self) {
            inline .review, .compare => |owner| owner.activeMouseSelection(),
        };
    }
};

const MousePoint = diff_surface.MousePoint;

const LoadFinishedMsg = app_message.LoadFinished;
const ActionFinishedMsg = app_message.ActionFinished;
const ShellEffectFinishedMsg = app_message.ShellEffectFinished;

const OverlayKind = app_state.OverlayKind;

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
                .credential_input = self.overlay.isPushCredentials(),
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
        };
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
            .repo_epoch = self.repoSessionView().epoch(),
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
        self.clearEphemeralStatusForUserAction(msg);

        switch (msg) {
            .switch_page => |target| try self.applyPageCoordinationIntent(
                ctx,
                self.pageCoordinator().requestSwitch(self.allocator orelse ctx.allocator(), target),
            ),
            .terminal_resized => |size| {
                // Mouse coordinates are relative to the old geometry. End the
                // borrow before changing layout, then drain deferred owners at
                // the common post-update boundary below.
                self.reviewNavigation().clearDiffSelection();
                self.pages.compare.selection_owner = .none;
                self.pages.repository.cancelMouseOwner();
                const previous_width = self.reviewNavigationView().diffPaneWidth();
                const previous_mode = self.reviewNavigationView().effectiveDisplayMode();
                const previous_compare_view = self.compareCoordinator().navigationView();
                var previous_compare_adapter = previous_compare_view.resolver();
                const previous_compare_body = previous_compare_view.bodyView(&previous_compare_adapter);
                const previous_compare_width = previous_compare_body.view.diffPaneWidth();
                const previous_compare_mode = previous_compare_body.view.effectiveDisplayMode();
                self.terminal_size = size;
                self.reviewNavigation().resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
                if (previous_mode != self.reviewNavigationView().effectiveDisplayMode()) self.reviewNavigation().clearDiffSelection();
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
                }
                compare_body.controller.clampSidebarHorizontalScroll();
                compare_body.clampDiffNavigationKeepingHunkVisible();
                compare_body.updateSearchMatchOffset();
                compare_body.controller.scrollSearchMatchIntoView();
                compare_body.clampDiffNavigation();
                self.pages.repository.clampForBodySize(self.shellLayout().bodySize());
                self.clampHelpScroll();
                self.clampPushErrorScroll();
            },
            .load_finished => |finished| try self.finishLoadResult(ctx, finished),
            .action_finished => |finished| try self.finishActionResult(ctx, finished),
            .push_inspection_finished => |finished| try self.remoteWorkflow().finishPushInspection(ctx, finished),
            .shell_effect_finished => |finished| try self.finishShellEffect(ctx, finished),
            .review => |review_msg| try self.updateReview(ctx, review_msg),
            .compare => |compare_msg| {
                var outcome = try self.compareCoordinator().update(ctx, compare_msg);
                defer outcome.deinit(ctx.allocator());
                if (outcome.takeClipboard()) |taken| {
                    var effect = taken;
                    defer effect.deinit(ctx.allocator());
                    self.shellEffects().queueClipboard(ctx, .{
                        .origin = effect.origin,
                        .label = effect.label,
                        .text = effect.text,
                    });
                }
            },
            .repository => |repository_msg| {
                var outcome = self.repositoryCoordinator().update(ctx, repository_msg);
                defer outcome.deinit(ctx.allocator());
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
            },
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
                if (self.active_page == .review) self.reviewNavigation().clearDiffSelection();
                if (self.active_page == .compare) self.pages.compare.selection_owner = .none;
                if (self.active_page == .repository) self.pages.repository.cancelMouseOwner();
                self.overlay.openHelpForPage(self.active_page);
            },
            .close_help => self.overlay.close(),
            .help_scroll_up => self.scrollHelp(-1),
            .help_scroll_down => self.scrollHelp(1),
            .help_page_up => self.pageHelp(-1),
            .help_page_down => self.pageHelp(1),
            .push_error_scroll_up => self.scrollPushError(-1),
            .push_error_scroll_down => self.scrollPushError(1),
            .push_error_page_up => self.pagePushError(-1),
            .push_error_page_down => self.pagePushError(1),
            .copy_popup => self.copyPopup(ctx),
            .push_credential_tab => self.remoteWorkflow().togglePushCredentialField(),
            .push_credential_submit => try self.remoteWorkflow().submitPushCredentials(ctx),
            .push_credential_cancel => self.remoteWorkflow().cancelPushCredentialPrompt(ctx.allocator()),
            .push_credential_insert => |codepoint| self.remoteWorkflow().insertPushCredential(codepoint),
            .push_credential_paste => |text| self.remoteWorkflow().pastePushCredential(text),
            .push_credential_backspace => self.remoteWorkflow().backspacePushCredential(),
            .push_credential_move_left => self.remoteWorkflow().movePushCredentialLeft(),
            .push_credential_move_right => self.remoteWorkflow().movePushCredentialRight(),
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
            .open_push_credentials => try self.remoteWorkflow().openPushCredentialPrompt(ctx),
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
            .focus_lost => switch (self.active_page) {
                .review => self.reviewNavigation().clearDiffSelection(),
                .repository => self.pages.repository.cancelMouseOwner(),
                .compare => self.pages.compare.selection_owner = .none,
                .config => {},
            },
            .git_action_spinner_tick => if (self.actionLifecycle().tick(ctx)) self.redraw_plan.requestSkip(),
            .quit => self.requestQuit(ctx),
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
    }

    fn requestQuit(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.actionLifecycleView().hasPending()) {
            self.setStatus("finish current git action before quitting", .{});
            return;
        }
        self.teardown_requested = true;
        ctx.quit();
    }

    fn updateReview(self: *App, ctx: *chasen.Ctx(Msg), msg: review_message.Msg) !void {
        var page_update = try (review_page_update.Controller{
            .navigation = self.reviewNavigation(),
        }).apply(self.allocator, msg);
        defer page_update.deinit(self.allocator);

        if (page_update.capture_display_override) {
            try self.reviewRead().captureDisplayOverride(ctx.allocator());
        }

        var command = page_update.takeCommand() orelse return;
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
            .push_foreground => |result| try self.applyRemoteOutcome(ctx, self.remoteWorkflow().finishPushForeground(ctx.allocator(), result)),
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
        if (msgKeepsEphemeralStatus(msg)) return;
        self.status.clearIfEphemeral();
        if (self.active_page == .review) self.pages.review.status.clearIfEphemeral();
        if (self.active_page == .compare) self.pages.compare.status.clearIfEphemeral();
        if (self.active_page == .repository) self.pages.repository.status.clearIfEphemeral();
    }

    fn msgKeepsEphemeralStatus(msg: Msg) bool {
        return switch (msg) {
            .terminal_resized,
            .load_finished,
            .action_finished,
            .push_inspection_finished,
            .shell_effect_finished,
            .auto_reload_tick,
            .focus_lost,
            .git_action_spinner_tick,
            => true,
            .repository => |repository_msg| switch (repository_msg) {
                .manifest_finished, .branch_finished => true,
                else => false,
            },
            else => false,
        };
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
            },
            .repository = .{
                .page_state = &self.pages.repository,
                .palette = self.theme,
                .keymap = self.keymap,
                .repo_root = self.repoSessionView().activeRoot(),
            },
            .active_page = self.active_page,
            .page_bar_visible = true,
            .theme = self.theme,
            .keymap = self.keymap,
            .terminal_size = self.terminal_size,
            .action = self.actionLifecycleView(),
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
            .push_retry_credentials_available = remote.pushRetryCredentialsAvailable(),
            .push_retry_inspecting = remote.pushRetryInspecting(),
            .push_credential_prompt = remote.pushCredentialPrompt(),
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
        return switch (event) {
            .mouse => |mouse| self.mouseToMsg(mouse),
            .focus_out => .focus_lost,
            else => app_input.eventToMsg(Msg, self.keyContext(), event),
        };
    }

    fn mouseToMsg(self: *const App, mouse: anytype) ?Msg {
        if (self.activeDiffSelectionOwner()) |selection| {
            if (selection.active()) switch (selection) {
                .review => switch (mouse.type) {
                    .drag => return .{ .review = .{ .mouse_diff_drag = self.bodyMousePoint(mouse) } },
                    .release => return .{ .review = .{ .mouse_diff_release = self.bodyMousePoint(mouse) } },
                    else => {},
                },
                .compare => switch (mouse.type) {
                    .drag => return .{ .compare = .{ .shared = .{ .mouse_diff_drag = self.bodyMousePoint(mouse) } } },
                    .release => return .{ .compare = .{ .shared = .{ .mouse_diff_release = self.bodyMousePoint(mouse) } } },
                    else => {},
                },
            };
        }
        if (self.pages.repository.activeMouseOwner()) {
            const body_point: ?repository_page.BodyPoint = if (self.bodyMousePoint(mouse)) |point|
                .{ .col = point.col, .row = point.row }
            else
                null;
            const source_point = repository_page.sourceGesturePoint(
                body_point,
                self.shellLayout().bodySize(),
                self.pages.repository.viewer.tree_width,
                self.pages.repository.viewer.tree_hidden,
            );
            switch (mouse.type) {
                .drag => return .{ .repository = .{ .mouse_owner_drag = source_point } },
                .release => return .{ .repository = .{ .mouse_owner_release = source_point } },
                else => {},
            }
        }

        if ((self.active_page == .review and (self.pages.review.search.mode or self.pages.review.file_search.mode)) or
            (self.active_page == .compare and (self.pages.compare.search.mode or self.pages.compare.file_search.mode or self.pages.compare.base_picker.open)) or
            (self.active_page == .repository and (self.pages.repository.source_search.mode or self.pages.repository.file_search.mode)) or
            self.localWorkflowView().commitPanelOpen() or self.repoSessionView().picker().model.mode) return null;
        if (mouse.type != .press) return null;

        switch (self.overlay.mouseMode()) {
            .passthrough => {},
            .block => return null,
            .scroll_help => return switch (mouse.button) {
                .wheel_up => .help_scroll_up,
                .wheel_down => .help_scroll_down,
                else => null,
            },
            .scroll_push_error => return switch (mouse.button) {
                .wheel_up => .push_error_scroll_up,
                .wheel_down => .push_error_scroll_down,
                else => null,
            },
        }

        if (mouse.button == .left) {
            const layout = self.shellLayout();
            if (layout.page_bar) |bar| {
                if (layout.terminalToContent(mouse.col, mouse.row)) |point| {
                    if (point.row == app_shell_layout.page_bar_label_row) {
                        const compact = layout.body.height == 0 or layout.footer.height == 0;
                        const target = if (compact)
                            if (point.col >= 1 and point.col < @min(bar.width, self.active_page.label().len + 3)) self.active_page else null
                        else
                            page.tabAtColumn(bar.width, point.col);
                        if (target) |id| return .{ .switch_page = id };
                        return null;
                    }
                }
            }
        }

        // Page-bar presses above still reach the common blocker and explain
        // why the switch was rejected. Inside the Repository body, a second
        // press or wheel event cannot replace the active gesture implicitly.
        if (self.pages.repository.activeMouseOwner()) return null;
        if (self.active_page == .repository) {
            const point = self.shellLayout().terminalToBody(mouse.col, mouse.row) orelse return null;
            const button: repository_page.MouseButton = switch (mouse.button) {
                .left => .left,
                .wheel_up => .wheel_up,
                .wheel_down => .wheel_down,
                else => return null,
            };
            const repository_msg = self.pages.repository.mouseToMsg(
                .{ .col = point.col, .row = point.row },
                button,
                self.shellLayout().bodySize(),
            ) orelse return null;
            return .{ .repository = repository_msg };
        }
        if (self.active_page == .compare) {
            const pane = self.compareMousePane(mouse) orelse return null;
            return switch (mouse.button) {
                .left => switch (pane) {
                    .sidebar => .{ .compare = .{ .shared = self.compareSidebarClickToMsg(mouse) } },
                    .diff => .{ .compare = .{ .shared = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } } },
                },
                .wheel_up => .{ .compare = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_up else .mouse_diff_wheel_up } },
                .wheel_down => .{ .compare = .{ .shared = if (pane == .sidebar) .mouse_sidebar_wheel_down else .mouse_diff_wheel_down } },
                .wheel_left => if (pane == .diff) .{ .compare = .{ .shared = .mouse_diff_wheel_left } } else null,
                .wheel_right => if (pane == .diff) .{ .compare = .{ .shared = .mouse_diff_wheel_right } } else null,
                else => null,
            };
        }
        if (self.active_page != .review) return null;

        const pane = self.mousePane(mouse) orelse return null;
        return switch (mouse.button) {
            .left => switch (pane) {
                .sidebar => .{ .review = self.sidebarClickToMsg(mouse) },
                .diff => .{ .review = .{ .mouse_diff_press = self.bodyMousePoint(mouse) orelse return null } },
            },
            .wheel_up => switch (pane) {
                .sidebar => .{ .review = .mouse_sidebar_wheel_up },
                .diff => .{ .review = .mouse_diff_wheel_up },
            },
            .wheel_down => switch (pane) {
                .sidebar => .{ .review = .mouse_sidebar_wheel_down },
                .diff => .{ .review = .mouse_diff_wheel_down },
            },
            .wheel_left => switch (pane) {
                .sidebar => null,
                .diff => .{ .review = .mouse_diff_wheel_left },
            },
            .wheel_right => switch (pane) {
                .sidebar => null,
                .diff => .{ .review = .mouse_diff_wheel_right },
            },
            else => null,
        };
    }

    fn activeDiffSelectionOwner(self: *const App) ?ActiveDiffSelectionOwner {
        return switch (self.active_page) {
            .review => .{ .review = &self.pages.review.selection_owner },
            .compare => .{ .compare = &self.pages.compare.selection_owner },
            .repository, .config => null,
        };
    }

    fn compareMousePane(self: *const App, mouse: anytype) ?MousePane {
        const body_size = self.shellLayout().bodySize();
        const navigation_view: compare_navigation.View = .{
            .page = &self.pages.compare,
            .repo_root = self.repoSessionView().activeRoot(),
            .repo_epoch = self.repoSessionView().epoch(),
            .root_identity = self.repoSessionView().activeIdentity(),
            .layout = .{ .width = body_size.width, .height = body_size.height },
        };
        _ = navigation_view.view().activeLoadedDiffConst() orelse return null;
        const point = self.bodyMousePoint(mouse) orelse return null;
        const size = self.layoutSize();
        if (self.pages.compare.viewer.sidebar_hidden) return .diff;
        const sidebar_width = sidebarWidth(size.width, self.pages.compare.viewer.sidebar_width);
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn compareSidebarClickToMsg(self: *const App, mouse: anytype) diff_surface.message.Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = self.shellLayout().body.height;
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;
        const loaded = switch (self.pages.compare.load.state) {
            .loaded => |session| &session.loaded,
            else => return .focus_sidebar,
        };
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(self.pages.compare.viewer.selected_node, visible_rows, body_row) orelse return .focus_sidebar;
        return .{ .sidebar_click_node = node_index };
    }

    fn mousePane(self: *const App, mouse: anytype) ?MousePane {
        _ = self.reviewNavigationView().activeLoadedDiffConst() orelse return null;

        const point = self.bodyMousePoint(mouse) orelse return null;
        const size = self.layoutSize();
        if (self.pages.review.viewer.sidebar_hidden) return .diff;

        const sidebar_width = sidebarWidth(size.width, self.pages.review.viewer.sidebar_width);
        if (point.col < sidebar_width) return .sidebar;
        if (point.col == sidebar_width) return null;
        return .diff;
    }

    fn sidebarClickToMsg(self: *const App, mouse: anytype) review_message.Msg {
        const point = self.bodyMousePoint(mouse) orelse return .focus_sidebar;
        const body_height = self.shellLayout().body.height;
        if (point.row < sidebar_header_rows or body_height <= sidebar_header_rows) return .focus_sidebar;

        const loaded = self.reviewNavigationView().activeLoadedDiffConst() orelse return .focus_sidebar;
        const visible_rows: usize = body_height - sidebar_header_rows;
        const body_row: usize = point.row - sidebar_header_rows;
        const node_index = loaded.sidebarNodeAtBodyRow(self.pages.review.viewer.selected_node, visible_rows, body_row) orelse return .focus_sidebar;
        return .{ .sidebar_click_node = node_index };
    }

    /// Single termination boundary for every mouse-selection lifetime. Update
    /// resolves a deferred background source result after this becomes idle;
    /// deinit discards that result explicitly.
    fn bodyMousePoint(self: *const App, mouse: anytype) ?MousePoint {
        const point = self.shellLayout().terminalToBody(mouse.col, mouse.row) orelse return null;
        return .{ .col = point.col, .row = point.row };
    }

    fn keyContext(self: *const App) app_input.KeyContext {
        return .{
            .active_page = self.active_page,
            .review = .{
                .search_mode = self.pages.review.search.mode,
                .file_search_mode = self.pages.review.file_search.mode,
                .search_query_len = self.pages.review.search.query.len,
                .focus = self.pages.review.viewer.focus,
                .sidebar_hidden = self.pages.review.viewer.sidebar_hidden,
                .review_mode = self.config.review_mode,
                .keymap = self.keymap,
            },
            .compare = .{
                .search_mode = self.pages.compare.search.mode,
                .file_search_mode = self.pages.compare.file_search.mode,
                .search_query_len = self.pages.compare.search.query.len,
                .focus = self.pages.compare.viewer.focus,
                .sidebar_hidden = self.pages.compare.viewer.sidebar_hidden,
                .base_picker_open = self.pages.compare.base_picker.open,
                .keymap = self.keymap,
            },
            .repository = self.pages.repository.inputContext(self.keymap),
            .commit_panel_mode = self.localWorkflowView().commitPanelOpen(),
            .repo_picker_mode = self.repoSessionView().picker().model.mode,
            .repo_picker_input_mode = self.repoSessionView().picker().model.input_mode,
            .help_mode = self.overlay.isHelp(),
            .discard_confirmation_mode = self.overlay.isDiscardFile(),
            .amend_confirmation_mode = self.overlay.isAmendCommit(),
            .push_confirmation_mode = self.overlay.isPushBranch(),
            .pull_confirmation_mode = self.overlay.isPullBranch(),
            .branch_switch_mode = self.overlay.isSwitchBranch(),
            .push_error_mode = self.overlay.isPushError(),
            .push_credential_mode = self.overlay.isPushCredentials(),
            .keymap = self.keymap,
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

    fn scrollHelp(self: *App, delta: isize) void {
        self.overlay.help_scroll = applySignedScroll(self.overlay.help_scroll, delta);
        self.clampHelpScroll();
    }

    fn pageHelp(self: *App, pages: isize) void {
        const rows = @max(@as(usize, app_view.helpVisibleRows(self.layoutSize())), 1);
        const delta: isize = if (pages < 0)
            -@as(isize, @intCast(rows))
        else
            @as(isize, @intCast(rows));
        self.scrollHelp(delta);
    }

    fn clampHelpScroll(self: *App) void {
        self.overlay.help_scroll = @min(self.overlay.help_scroll, app_view.helpMaxScroll(self.layoutSize()));
    }

    fn scrollPushError(self: *App, delta: isize) void {
        self.overlay.push_error_scroll = applySignedScroll(self.overlay.push_error_scroll, delta);
        self.clampPushErrorScroll();
    }

    fn pagePushError(self: *App, pages: isize) void {
        const rows = @max(@as(usize, app_view.pushErrorVisibleRows(self.layoutSize(), self.remoteWorkflowView().pushErrorMessage())), 1);
        const delta: isize = if (pages < 0)
            -@as(isize, @intCast(rows))
        else
            @as(isize, @intCast(rows));
        self.scrollPushError(delta);
    }

    fn clampPushErrorScroll(self: *App) void {
        self.overlay.push_error_scroll = @min(self.overlay.push_error_scroll, app_view.pushErrorMaxScroll(self.layoutSize(), self.remoteWorkflowView().pushErrorMessage()));
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

    pub fn exportInitialSelectionContextJson(allocator: std.mem.Allocator, io: std.Io, config: CliConfig, writer: *std.Io.Writer) !void {
        var discovery: ?repo_discovery.DiscoveryResult = null;
        defer if (discovery) |*result| result.deinit(allocator);

        const repo_root = if (diff_source.sourceRequiresRepo(config.source)) blk: {
            discovery = try repo_discovery.discover(allocator, io);
            const discovered_root = try activeRootFromDiscovery(discovery.?);
            break :blk discovered_root orelse return error.MissingRepoRoot;
        } else null;

        var load_result = app_load.runLoad(.{ .source = config.source, .repo_root = repo_root }, allocator, io);
        defer load_result.deinit(allocator);

        var status_result: ?app_load.StatusLoadTaskResult = null;
        defer if (status_result) |*result| result.deinit(allocator);

        const selection = switch (load_result) {
            .unchanged => unreachable,
            .empty => blk: {
                status_result = initialStatusLoadResultIfNeeded(config.source, repo_root, allocator, io);
                break :blk initialSelectionContext(config.source, repo_root, null, initialStatusDocument(optionalStatusResultPtr(&status_result)));
            },
            .loaded => |*bundle| blk: {
                const loaded_selection = initialSelection(&bundle.loaded);
                if (loaded_selection != null) break :blk initialSelectionContextWithSelection(config.source, repo_root, loaded_selection);
                status_result = initialStatusLoadResultIfNeeded(config.source, repo_root, allocator, io);
                break :blk initialSelectionContext(config.source, repo_root, &bundle.loaded, initialStatusDocument(optionalStatusResultPtr(&status_result)));
            },
            .failed, .failed_static => return error.ExportContextLoadFailed,
        };

        try context_export.writeSelectionContext(writer, selection);
    }

    fn initialStatusLoadResultIfNeeded(source: SourceMode, repo_root: ?[]const u8, allocator: std.mem.Allocator, io: std.Io) ?app_load.StatusLoadTaskResult {
        if (!diff_source.sourceRequiresRepo(source)) return null;
        const root = repo_root orelse return null;
        return app_load.runStatusLoad(root, allocator, io);
    }

    fn optionalStatusResultPtr(result: *?app_load.StatusLoadTaskResult) ?*app_load.StatusLoadTaskResult {
        if (result.*) |*value| return value;
        return null;
    }

    fn initialStatusDocument(result: ?*app_load.StatusLoadTaskResult) ?git_status.StatusDocument {
        const status = result orelse return null;
        return switch (status.*) {
            .loaded => |bundle| bundle.document,
            .empty, .failed, .failed_static => null,
        };
    }

    fn initialSelectionContext(source: SourceMode, repo_root: ?[]const u8, loaded: ?*const LoadedDiff, status: ?git_status.StatusDocument) context.SelectionContext {
        return initialSelectionContextWithSelection(source, repo_root, if (loaded) |active_loaded| initialSelection(active_loaded) orelse initialStatusOnlySelection(status) else initialStatusOnlySelection(status));
    }

    fn initialSelectionContextWithSelection(source: SourceMode, repo_root: ?[]const u8, selected: ?context.Selection) context.SelectionContext {
        return .{
            .repo_root = repo_root,
            .source = sourceContext(source),
            .selected = selected,
        };
    }

    fn initialSelection(loaded: *const LoadedDiff) ?context.Selection {
        if (loaded.document.files.len == 0) return null;
        const file = loaded.document.files[0];
        return .{ .diff_file = .{
            .file_index = 0,
            .display_path = diff_file.displayPath(file),
            .path_key = diff_file.canonicalPathKey(file),
            .hunk_index = if (file.hunks.len > 0) 0 else null,
        } };
    }

    fn initialStatusOnlySelection(status: ?git_status.StatusDocument) ?context.Selection {
        const document = status orelse return null;
        for (document.entries, 0..) |entry, status_index| {
            if (entry.isIgnored()) continue;
            const path_key = entry.canonicalPathKey() orelse continue;
            // status_index is advisory for consumers; path_key is the stable identity.
            return .{ .status_only = .{
                .status_index = status_index,
                .path_key = path_key,
            } };
        }
        return null;
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
        return .{
            .repo_root = self.repoSessionView().activeRoot(),
            .source = sourceContext(self.config.source),
            .selected = self.reviewNavigationView().currentSelection(),
        };
    }

    fn sourceContext(source: SourceMode) context.SourceContext {
        // Labels intentionally mirror CliConfig.sourceLabel(); this helper is
        // the boundary where CLI source modes become neutral context data.
        return switch (source) {
            .unstaged => .{ .kind = .unstaged, .label = "unstaged changes" },
            .cached => .{ .kind = .cached, .label = "staged changes" },
            .stdin => .{ .kind = .stdin, .label = "stdin diff" },
            .pager => .{ .kind = .pager, .label = "pager diff" },
            .patch_file => |path| .{ .kind = .patch_file, .label = "patch file", .detail = path },
            .range => |range| .{ .kind = .range, .label = "range", .detail = range },
            .no_index => |paths| .{
                .kind = .no_index,
                .label = "difftool",
                .left_path = paths.left,
                .right_path = paths.right,
            },
        };
    }

    fn activeRootFromDiscovery(result: repo_discovery.DiscoveryResult) !?[]const u8 {
        return switch (result) {
            .single_repo => |entry| entry.canonical_root,
            .workspace => error.AmbiguousWorkspaceExport,
            .none => null,
        };
    }

    fn layoutSize(self: *const App) chasen.Size {
        return app_shell_layout.contentSize(self.terminal_size);
    }
};

pub const testing = if (builtin.is_test) struct {
    /// Installs an already-queued action fixture for tests whose subject starts
    /// after launch acceptance. Terminal delivery must still use `App.update`.
    pub fn installAcceptedActionFixture(
        app: *App,
        kind: app_actions.ActionKind,
    ) app_actions.PendingAction {
        if (app.allocator == null) app.allocator = std.testing.allocator;
        const prepared = app.actionLifecycle().prepare(kind);
        return app.actionLifecycle().acceptSpawn(app.allocator.?, prepared).pending;
    }

    pub fn actionView(app: *const App) action_lifecycle.View {
        return app.actionLifecycleView();
    }

    pub fn repoView(app: *const App) repo_session.View {
        return app.repoSessionView();
    }

    pub fn activateReview(app: *App) void {
        _ = app.pageCoordinator().activateReview();
    }

    pub fn clearActionCursor(app: *App, allocator: std.mem.Allocator) void {
        app.reviewNavigation().clearActionCursor(allocator);
    }

    pub fn installActionCursor(
        app: *App,
        allocator: std.mem.Allocator,
        kind: review_page.action_cursor.TargetKind,
        path_key: []const u8,
        action_generation: u64,
        fallback_identity: repo_root_capability.Identity,
    ) !void {
        const identity = app.repoSessionView().activeIdentity() orelse fallback_identity;
        var prepared = try app.reviewNavigation().prepareActionCursor(
            allocator,
            app.repoSessionView().epoch(),
            identity,
            kind,
            path_key,
        );
        app.reviewNavigation().installActionCursor(allocator, &prepared, action_generation);
    }

    pub fn clearPushError(app: *App, allocator: std.mem.Allocator) void {
        app.remoteWorkflow().clearPushError(allocator);
    }

    pub fn setPushErrorWithRetry(
        app: *App,
        allocator: std.mem.Allocator,
        message: []const u8,
        retry_target: ?app_state.PushRetryTarget,
        credentials_available: bool,
    ) !void {
        try workflow_remote.testing.setPushErrorWithRetry(
            app.remoteWorkflow(),
            allocator,
            message,
            retry_target,
            credentials_available,
        );
    }

    pub fn runInteractivePush(app: *App, ctx: *chasen.Ctx(App.Msg)) !void {
        try app.update(.run_interactive_push, ctx);
    }

    pub fn requestRemotePush(app: *App, ctx: *chasen.Ctx(App.Msg)) !void {
        try app.requestRemotePush(ctx);
    }

    pub fn requestRemoteBranchSwitch(app: *App, ctx: *chasen.Ctx(App.Msg)) !void {
        try app.requestRemoteBranchSwitch(ctx);
    }

    pub fn submitPushCredentials(app: *App, ctx: *chasen.Ctx(App.Msg)) !void {
        try app.update(.push_credential_submit, ctx);
    }

    pub fn copySourceSelection(app: *App, ctx: *chasen.Ctx(App.Msg), text: []const u8) void {
        app.copySourceSelection(ctx, text);
    }

    pub fn copySourceHeaderPath(app: *App, ctx: *chasen.Ctx(App.Msg), path: []const u8) void {
        app.copySourceHeaderPath(ctx, path);
    }

    pub fn copyPopup(app: *App, ctx: *chasen.Ctx(App.Msg)) void {
        app.copyPopup(ctx);
    }

    pub fn copyCommitMessage(app: *App, ctx: *chasen.Ctx(App.Msg)) void {
        app.copyCommitMessage(ctx);
    }

    pub fn finishSwitchBranch(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        result: app_actions.SwitchBranchFinished,
    ) !void {
        try app.update(.{ .action_finished = .{ .switch_branch = result } }, ctx);
    }

    pub fn finishPush(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        result: app_actions.PushFinished,
    ) !void {
        try app.update(.{ .action_finished = .{ .push = result } }, ctx);
    }

    pub fn finishPull(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        result: app_actions.PullFinished,
    ) !void {
        try app.update(.{ .action_finished = .{ .pull = result } }, ctx);
    }

    pub fn finishFetch(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        result: app_actions.FetchFinished,
    ) !void {
        try app.update(.{ .action_finished = .{ .fetch = result } }, ctx);
    }

    pub fn finishPushForeground(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        result: chasen.ForegroundCommandResult,
    ) !void {
        try app.update(.{ .action_finished = .{ .push_foreground = result } }, ctx);
    }

    pub fn finishEditorCommand(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        result: chasen.ForegroundCommandResult,
    ) !void {
        try app.update(.{ .shell_effect_finished = .{ .editor = result } }, ctx);
    }

    pub fn clearActionFixture(app: *App) void {
        action_lifecycle.testing.clear(&app.action_runtime);
    }

    pub fn applyRepoSessionCommit(
        app: *App,
        ctx: *chasen.Ctx(App.Msg),
        outcome: repo_session.CommitOutcome,
    ) !void {
        try app.applyRepoSessionCommit(ctx, outcome);
    }

    /// Exercises the production repository-session admission path while
    /// allowing App integration tests to install an explicit discovery.
    pub fn commitDiscovery(
        app: *App,
        allocator: std.mem.Allocator,
        result: repo_discovery.DiscoveryResult,
        active_index: usize,
        origin: repo_session.CommitOrigin,
    ) !repo_session.CommitOutcome {
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        return app.repoSession().commitDiscovered(&ctx, result, active_index, origin);
    }
} else struct {};

const app_testing = testing;

fn mutableTestApp(handle: anytype) *App {
    const Handle = @TypeOf(handle);
    if (Handle == *App) return handle;
    if (Handle == **App or Handle == *const *App) return handle.*;
    @compileError("expected mutable App test handle");
}

/// Test-only fixture constructor kept outside `App`, so production root code
/// has no compatibility route to the page-local reload owner.
fn reviewReloadForTest(handle: anytype) review_reload.Controller {
    const app = mutableTestApp(handle);
    return .{
        .page = &app.pages.review,
        .navigation = app.reviewNavigation(),
        .source = app.config.source,
        .repo_root = app.repoSessionView().activeRoot(),
        .repo_epoch = app.repoSessionView().epoch(),
        .root_identity = app.repoSessionView().activeIdentity(),
    };
}

const sidebar_header_rows: u16 = review_layout.sidebar_header_rows;

fn terminalBodyHeight(terminal_height: u16) u16 {
    return app_shell_layout.bodyHeight(terminal_height);
}

fn applySignedScroll(current: usize, delta: isize) usize {
    if (delta < 0) {
        const amount: usize = @intCast(-(delta + 1));
        return current -| (amount + 1);
    }
    return current +| @as(usize, @intCast(delta));
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return review_layout.sidebarWidth(total_width, preferred_width);
}

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

/// Test fixtures model a task which has already crossed the concrete launch
/// boundary before delivering its completion to App.
fn beginAcceptedTestAction(app: *App, kind: app_actions.ActionKind) app_actions.PendingAction {
    if (app.allocator == null) app.allocator = std.testing.allocator;
    return app_testing.installAcceptedActionFixture(app, kind);
}

test "countLines handles empty and trailing newline inputs" {
    try std.testing.expectEqual(@as(usize, 0), app_load.countLines(""));
    try std.testing.expectEqual(@as(usize, 1), app_load.countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), app_load.countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 2), app_load.countLines("one\ntwo"));
}

test "display mode and search navigation reset horizontal scroll" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .unified,
                .diff_horizontal_scroll = 16,
            },
        } },
        .terminal_size = .{ .width = 120, .height = 8 },
    };

    try app.update(.{ .review = .toggle_display_mode }, undefined);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_horizontal_scroll);

    app.pages.review.viewer.diff_horizontal_scroll = 16;
    setDiffSearchQuery(&app, "wide");
    app.reviewNavigation().submitSearch();
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.diff_horizontal_scroll);
}

test "line number toggle clamps horizontal scroll without changing vertical scroll" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 2,
                .diff_horizontal_scroll = 999,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 8 },
    };

    const old_scroll = app.pages.review.viewer.diff_scroll;
    try app.update(.{ .review = .toggle_line_numbers }, undefined);

    try std.testing.expect(!app.pages.review.viewer.view_options.line_numbers);
    try std.testing.expectEqual(old_scroll, app.pages.review.viewer.diff_scroll);
    try std.testing.expect(app.pages.review.viewer.diff_horizontal_scroll <= app.reviewNavigationView().visibleBodyTextMaxHorizontalScroll());
}

test "display mode toggle keeps nearby vertical scroll position" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .diff_scroll = 8,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 140, .height = 8 },
    };
    app.pages.review.viewer.diff_cursor = app.reviewNavigationView().selectedCoordinateAtOffset(app.pages.review.viewer.diff_scroll) orelse app.pages.review.viewer.diff_cursor;

    try app.update(.{ .review = .toggle_display_mode }, undefined);

    try std.testing.expectEqual(diff_render.DisplayMode.side_by_side, app.reviewNavigationView().effectiveDisplayMode());
    try std.testing.expect(app.pages.review.viewer.diff_scroll > 0);
    try std.testing.expect(app.pages.review.viewer.diff_scroll <= app.reviewNavigationView().selectedFileLineIndex(app.reviewNavigationView().effectiveDisplayMode()).lineCount());
}

test "diff mouse selection owner is resolved from the active page surface" {
    var app: App = .{ .terminal_size = .{ .width = 80, .height = 20 } };
    app.pages.review.selection_owner = .{ .diff_header = .{
        .identity = .{ .kind = .loaded_file, .path_key = "a" },
    } };

    const drag = app.handleEvent(app_test_support.mouseEventTyped(4, 4, .left, .drag)) orelse return error.ExpectedDiffSelectionOwner;
    switch (drag) {
        .review => |review_msg| switch (review_msg) {
            .mouse_diff_drag => {},
            else => return error.ExpectedReviewDiffDrag,
        },
        else => return error.ExpectedReviewDiffDrag,
    }

    app.active_page = .repository;
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(4, 4, .left, .drag)) == null);
}

test "display mode toggle brings cursor back into view after wheel scroll" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .diff_scroll = 12,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 9 },
    };

    try std.testing.expect(app.reviewNavigationView().visibleDiffCursorOffset() == null);

    try app.update(.{ .review = .toggle_display_mode }, undefined);

    try std.testing.expect(app.reviewNavigationView().visibleDiffCursorOffset() != null);
}

test "mouse wheel routes through diff scroll cursor sync" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .unified,
                .sidebar_hidden = true,
                .focus = .sidebar,
                .diff_scroll = 12,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 140, .height = 9 },
    };

    try app.update(.{ .review = .mouse_diff_wheel_down }, undefined);

    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expect(app.reviewNavigationView().visibleDiffCursorOffset() != null);
}

test "diff mouse drag supports unified fallback and clears on invalidation" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .display_mode = .side_by_side,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 50, .height = 10 },
    };

    app.reviewNavigation().pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() != null);

    app.terminal_size.width = 140;
    app.reviewNavigation().pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() != null);

    try app.update(.{ .review = .toggle_display_mode }, undefined);
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);

    app.pages.review.viewer.display_mode = .side_by_side;
    app.reviewNavigation().pressDiffMouse(.{ .col = 4, .row = diff_render.body_start_row + 1 });
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() != null);
    reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);
}

test "terminal resize cancels live drag before geometry and retains completed selection" {
    const allocator = std.testing.allocator;
    const review_selection = @import("app/diff_surface/selection.zig");
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 20 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(allocator);

    const selection: diff_selection.DragSelection = .{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "a" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 1 },
        .moved = true,
    };
    app.pages.review.completed_selection = try review_selection.buildParsed(allocator, .{
        .repo_epoch = 0,
        .root_identity = null,
        .source = review_selection.SourceBasis.init(.unstaged),
        .source_session_revision = app.pages.review.source_session_revision,
        .display = .{ .loaded = content_fingerprint.Fingerprint.init("") },
    }, app_test_support.loadedDiffOne().document.files[0], selection);
    const retained_token = app.pages.review.completed_selection.?.token;
    app.pages.review.selection_owner = .{ .diff = selection };
    app.pages.compare.selection_owner = .{ .diff = selection };

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, undefined);

    try std.testing.expect(app.pages.review.selection_owner == .none);
    try std.testing.expect(app.pages.compare.selection_owner == .none);
    try std.testing.expect(app.pages.review.completed_selection != null);
    try std.testing.expect(app.pages.review.completed_selection.?.token.eql(retained_token));
    try std.testing.expectEqual(chasen.Size{ .width = 120, .height = 30 }, app.terminal_size);
}

test "hidden sidebar keeps tab from changing focus" {
    var app: App = .{
        .pages = .{ .review = .{
            .viewer = .{
                .focus = .diff,
                .sidebar_hidden = true,
            },
        } },
    };

    try app.update(.{ .review = .toggle_focus }, undefined);

    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "user actions clear previous ephemeral status" {
    var app: App = .{};
    app.setStatus("staged: {s}", .{"src/app.zig"});

    try app.update(.{ .review = .toggle_focus }, undefined);

    try std.testing.expectEqualStrings("", app.status.text());
}

test "system events keep previous ephemeral status" {
    var app: App = .{};
    app.setStatus("staged: {s}", .{"src/app.zig"});

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, undefined);

    try std.testing.expectEqualStrings("staged: src/app.zig", app.status.text());
}

test "git action spinner ticks keep previous ephemeral status" {
    var app: App = .{};
    app.setStatus("pushing: {s}", .{"main -> origin/main"});
    _ = beginAcceptedTestAction(&app, .push);
    action_lifecycle.testing.setSpinner(&app.action_runtime, 0, true);

    try app.update(.git_action_spinner_tick, undefined);

    try std.testing.expectEqualStrings("pushing: main -> origin/main", app.status.text());
    try std.testing.expectEqual(@as(u8, 1), action_lifecycle.testing.spinnerTick(&app.action_runtime));
}

test "git action spinner starts when pending action is visible after update" {
    var app: App = .{};
    _ = beginAcceptedTestAction(&app, .push);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, &tc.ctx);

    try std.testing.expect(action_lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
}

test "git action spinner self-cancels stale ticks without redraw" {
    var app: App = .{};
    action_lifecycle.testing.setSpinner(&app.action_runtime, 0, true);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.git_action_spinner_tick, &tc.ctx);

    try std.testing.expect(!action_lifecycle.testing.spinnerTimerRunning(&app.action_runtime));
    try std.testing.expectEqual(@as(u8, 0), action_lifecycle.testing.spinnerTick(&app.action_runtime));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expect(tc.redrawSuppressed());
}

test "grouped result messages keep previous ephemeral status" {
    try std.testing.expect(App.msgKeepsEphemeralStatus(.{ .load_finished = undefined }));
    try std.testing.expect(App.msgKeepsEphemeralStatus(.{ .action_finished = undefined }));
    try std.testing.expect(App.msgKeepsEphemeralStatus(.git_action_spinner_tick));
}

test "modal transitions clear previous ephemeral status" {
    var app: App = .{};
    app.setStatus("staged: {s}", .{"src/app.zig"});

    try app.update(.open_help, undefined);

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);
}

test "help overlay opens and closes before normal shortcuts" {
    var app: App = .{};

    const open_msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedOpenHelp;
    try app.update(open_msg, undefined);
    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);

    const scroll_msg = app.handleEvent(.{ .key_press = .{ .codepoint = 'j' } }) orelse return error.ExpectedHelpScroll;
    try std.testing.expectEqual(App.Msg.help_scroll_down, scroll_msg);

    const close_msg = app.handleEvent(.{ .key_press = .{ .codepoint = 'q' } }) orelse return error.ExpectedCloseHelp;
    try std.testing.expectEqual(App.Msg.close_help, close_msg);
    try app.update(close_msg, undefined);
    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
}

test "help overlay reopen resets help scroll" {
    var app: App = .{
        .terminal_size = .{ .width = 120, .height = 12 },
        .overlay = .{ .kind = .help, .help_scroll = 5 },
    };

    try app.update(.close_help, undefined);
    try app.update(.open_help, undefined);

    try std.testing.expectEqual(OverlayKind.help, app.overlay.kind);
    try std.testing.expectEqual(@as(usize, 0), app.overlay.help_scroll);
}

test "prompt input stays above help overlay" {
    var app: App = .{
        .pages = .{ .review = .{
            .search = .{ .mode = true },
        } },
    };

    const msg = app.handleEvent(.{ .key_press = .{ .codepoint = '?' } }) orelse return error.ExpectedPromptInput;
    try app.update(msg, undefined);

    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
    try std.testing.expectEqualStrings("?", app.pages.review.search.input.slice());
}

test "mouse click focuses sidebar and diff panes" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const sidebar_event = app_test_support.mouseEvent(content.col + 1, content.row + 2, .left);
    const sidebar_msg = app.handleEvent(sidebar_event) orelse return error.ExpectedSidebarMouseMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);

    const diff_col = content.col + sidebarWidth(app.layoutSize().width, app.pages.review.viewer.sidebar_width) + 1;
    const diff_event = app_test_support.mouseEvent(diff_col, content.row + 2, .left);
    const diff_msg = app.handleEvent(diff_event) orelse return error.ExpectedDiffMouseMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "mouse click selects sidebar file rows" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows + 1;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "mouse click toggles sidebar directory rows" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, app_test_support.loadedDiffNested()),
            .viewer = .{ .focus = .diff, .selected_node = 1 },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarDirectoryClickMessage;
    try app.update(msg, undefined);

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(file_tree.isCollapsed(&loaded.collapsed_dirs, "src"));
}

test "mouse click on sidebar header or blank body focuses only" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const header_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + app_shell_layout.page_bar_rows, .left)) orelse return error.ExpectedSidebarHeaderClickMessage;
    try app.update(header_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);

    app.pages.review.viewer.focus = .diff;
    const blank_row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows + 2;
    const blank_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, blank_row, .left)) orelse return error.ExpectedSidebarBlankClickMessage;
    try app.update(blank_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
}

test "mouse click uses filtered sidebar projection" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    loaded.reviewed_files = try arena.allocator().alloc(bool, loaded.document.files.len);
    @memset(loaded.reviewed_files, false);
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .deleted);

    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{ .focus = .diff, .selected_node = 0 },
            .review_display = .{ .changed_file_filter = .deleted },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedFilteredSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
}

test "mouse wheel scrolls the pane under the pointer" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{ .focus = .diff },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const sidebar_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedSidebarWheelMessage;
    try app.update(sidebar_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);

    app.reviewNavigation().selectFileAbsolute(0);
    const diff_col = content.col + sidebarWidth(app.layoutSize().width, app.pages.review.viewer.sidebar_width) + 1;
    const diff_msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_down)) orelse return error.ExpectedDiffWheelMessage;
    try app.update(diff_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expect(app.pages.review.viewer.diff_scroll > 0);
}

test "mouse uses full body as diff pane while sidebar is hidden" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{
                .focus = .sidebar,
                .sidebar_hidden = true,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) orelse return error.ExpectedHiddenSidebarMouseMessage;
    try app.update(msg, undefined);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
}

test "help overlay wheel scrolls help and ignores clicks" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .overlay = .{ .kind = .help },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedHelpWheelMessage;
    try std.testing.expectEqual(App.Msg.help_scroll_down, msg);
    try app.update(msg, undefined);
    try std.testing.expect(app.overlay.help_scroll > 0);

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
}

test "push error overlay wheel scrolls details and ignores clicks" {
    const long_message =
        "line 1\nline 2\nline 3\nline 4\nline 5\n" ++
        "line 6\nline 7\nline 8\nline 9\nline 10\n";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .remote_workflow = .{ .push_error_message = try std.testing.allocator.dupe(u8, long_message) },
    };
    defer app.remoteWorkflow().clearPushError(std.testing.allocator);
    app.overlay.openPushError();

    const content = app_shell_layout.contentRect(app.terminal_size);
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) orelse return error.ExpectedPushErrorWheelMessage;
    try std.testing.expectEqual(App.Msg.push_error_scroll_down, msg);
    try app.update(msg, undefined);
    try std.testing.expect(app.overlay.push_error_scroll > 0);

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
}

test "confirmation overlay blocks mouse clicks and wheels" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .focus = .diff,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .overlay = .{ .kind = .push_branch },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) == null);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
}

test "terminal resize clamps push error scroll" {
    const long_message =
        "line 1\nline 2\nline 3\nline 4\nline 5\n" ++
        "line 6\nline 7\nline 8\nline 9\nline 10\n";
    var app: App = .{
        .terminal_size = .{ .width = 40, .height = 8 },
        .remote_workflow = .{ .push_error_message = try std.testing.allocator.dupe(u8, long_message) },
        .overlay = .{ .kind = .push_error, .push_error_scroll = 99 },
    };
    defer app.remoteWorkflow().clearPushError(std.testing.allocator);

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, undefined);

    try std.testing.expect(app.overlay.push_error_scroll <= app_view.pushErrorMaxScroll(app.layoutSize(), app.remote_workflow.push_error_message));
}

test "mouse horizontal wheel scrolls diff pane horizontally" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffWide()),
            .viewer = .{
                .focus = .sidebar,
                .display_mode = .unified,
            },
        } },
        .terminal_size = .{ .width = 80, .height = 12 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    const diff_col = content.col + sidebarWidth(app.layoutSize().width, app.pages.review.viewer.sidebar_width) + 1;
    const msg = app.handleEvent(app_test_support.mouseEvent(diff_col, content.row + 2, .wheel_right)) orelse return error.ExpectedHorizontalWheelMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expect(app.pages.review.viewer.diff_horizontal_scroll > 0);
}

test "mouse events are ignored outside body and prompt modes" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(-1, 1, .left)) == null);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const footer_row: i16 = @intCast(content.row + terminalBodyHeight(app.layoutSize().height));
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, footer_row, .left)) == null);

    app.pages.review.search.mode = true;
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 1, .left)) == null);
}

test "mouse release and motion events are ignored" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(content.col + 1, content.row + 1, .left, .release)) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEventTyped(content.col + 1, content.row + 1, .left, .motion)) == null);
}

test "search overflow reports query status for insert and paste" {
    var app: App = .{
        .pages = .{ .review = .{ .search = .{ .mode = true } } },
    };
    @memset(&app.pages.review.search.input.buffer, 'x');
    app.pages.review.search.input.len = app.pages.review.search.input.buffer.len;
    app.pages.review.search.input.cursor = app.pages.review.search.input.buffer.len;

    try app.update(.{ .review = .{ .search_insert = 'y' } }, undefined);
    try std.testing.expectEqualStrings("search query is too long", app.pages.review.status.text());

    app.status.clear();
    try app.update(.{ .review = .{ .search_paste = "y" } }, undefined);
    try std.testing.expectEqualStrings("search query is too long", app.pages.review.status.text());
}

test "file search overflow reports query status for insert and paste" {
    var app: App = .{
        .pages = .{ .review = .{ .file_search = .{ .mode = true } } },
    };
    @memset(&app.pages.review.file_search.input.buffer, 'x');
    app.pages.review.file_search.input.len = app.pages.review.file_search.input.buffer.len;
    app.pages.review.file_search.input.cursor = app.pages.review.file_search.input.buffer.len;

    try app.update(.{ .review = .{ .file_search_insert = 'y' } }, undefined);
    try std.testing.expectEqualStrings("file search query is too long", app.pages.review.status.text());

    app.status.clear();
    try app.update(.{ .review = .{ .file_search_paste = "y" } }, undefined);
    try std.testing.expectEqualStrings("file search query is too long", app.pages.review.status.text());
}

test "repo picker filter overflow reports status for insert and paste" {
    var app: App = .{
        .repo_session = .{
            .repo_picker = .{
                .mode = true,
                .input_mode = .filter,
            },
        },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    @memset(&app.repo_session.repo_picker.list.input.buffer, 'x');
    app.repo_session.repo_picker.list.input.len = app.repo_session.repo_picker.list.input.buffer.len;
    app.repo_session.repo_picker.list.input.cursor = app.repo_session.repo_picker.list.input.buffer.len;

    try app.update(.{ .repo_picker_insert = 'y' }, &ctx);
    try std.testing.expectEqualStrings("repository filter is too long", app.status.text());

    app.status.clear();
    try app.update(.{ .repo_picker_paste = "y" }, &ctx);
    try std.testing.expectEqualStrings("repository filter is too long", app.status.text());
}

test "sidebar navigation keeps status-only target through clamp" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/status-only.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try reviewReloadForTest(&app).applyStatusProjection(std.testing.allocator, false, .accepted_status);

    const loaded = app.reviewNavigation().activeLoadedDiff().?;
    const status_node = blk: {
        for (loaded.tree.nodes, 0..) |node, index| {
            switch (node.target) {
                .status_entry => break :blk index,
                else => {},
            }
        }
        return error.ExpectedStatusOnlyNode;
    };

    app.reviewNavigation().selectSidebarNode(loaded, status_node);
    app.reviewNavigation().clampSelection(loaded.document.files.len);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(app.reviewNavigationView().selectedFileIndex(loaded) == null);
    try std.testing.expect(app.reviewNavigationView().selectedStatusEntry() != null);
}

test "sidebar navigation moves between status-only nodes" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a.zig\x00?? b.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try reviewReloadForTest(&app).createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    const first_node = app.pages.review.viewer.selected_node;

    app.reviewNavigation().selectFileDelta(1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(app.pages.review.viewer.selected_node != first_node);

    app.reviewNavigation().selectFileDelta(-1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(first_node, app.pages.review.viewer.selected_node);
}

const BranchStatusBundleSpec = struct {
    oid: ?[]const u8 = null,
    branch: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: ?u32 = null,
    behind: ?u32 = null,
};

fn branchStatusBundleForTest(allocator: std.mem.Allocator, spec: BranchStatusBundleSpec) !git_branch_status.BranchStatusBundle {
    var builder = git_branch_status.Builder.init(allocator);
    errdefer builder.deinit();

    if (spec.oid) |oid| try builder.setOid(oid);
    if (spec.branch) |branch| {
        try builder.setBranchHead(branch);
    } else {
        builder.setDetached();
    }
    if (spec.upstream) |upstream| try builder.setUpstream(upstream);
    if (spec.ahead) |ahead| builder.setAheadBehind(ahead, spec.behind orelse 0);

    return builder.finish();
}

test "quit waits for pending git action" {
    var app: App = .{ .allocator = std.testing.allocator };
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 7, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.requestQuit(&ctx);

    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("finish current git action before quitting", app.status.text());
}

test "quit exits when no git action is pending" {
    var app: App = .{ .allocator = std.testing.allocator };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.requestQuit(&ctx);

    try std.testing.expect(ctx.shouldQuit());
}

test "page bar rule is dead chrome in normal and compact layouts" {
    var app: App = .{ .terminal_size = .{ .width = 100, .height = 20 } };
    const normal = app.shellLayout();
    const normal_bar = normal.page_bar orelse return error.ExpectedPageBar;
    try std.testing.expectEqual(app_shell_layout.page_bar_rows, normal_bar.height);
    const repository_tab = page.tab(.repository);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        normal_bar.col + repository_tab.col,
        normal_bar.row + app_shell_layout.page_bar_rule_row,
        .left,
    )) == null);

    app.terminal_size = .{ .width = 20, .height = 3 };
    const compact = app.shellLayout();
    const compact_bar = compact.page_bar orelse return error.ExpectedCompactPageBar;
    try std.testing.expectEqual(@as(u16, 0), compact.body.height);
    try std.testing.expectEqual(App.Msg{ .switch_page = .review }, app.handleEvent(app_test_support.mouseEvent(
        compact_bar.col + 1,
        compact_bar.row + app_shell_layout.page_bar_label_row,
        .left,
    )).?);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        compact_bar.col + repository_tab.col,
        compact_bar.row + app_shell_layout.page_bar_label_row,
        .left,
    )) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(
        compact_bar.col + 1,
        compact_bar.row + app_shell_layout.page_bar_rule_row,
        .left,
    )) == null);
}

fn testSingleRepoDiscovery(allocator: std.mem.Allocator, root: []const u8) !repo_discovery.DiscoveryResult {
    return testNamedSingleRepoDiscovery(allocator, std.fs.path.basename(root), root);
}

fn testNamedSingleRepoDiscovery(allocator: std.mem.Allocator, label: []const u8, root: []const u8) !repo_discovery.DiscoveryResult {
    return .{ .single_repo = .{
        .label = try allocator.dupe(u8, label),
        .display_path = try allocator.dupe(u8, root),
        .canonical_root = try allocator.dupe(u8, root),
    } };
}

const TestRepoPair = struct {
    tmp: std.testing.TmpDir,
    a: [:0]u8,
    b: [:0]u8,

    fn init() !TestRepoPair {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "a", .default_dir);
        try tmp.dir.createDir(std.testing.io, "b", .default_dir);
        const a = try tmp.dir.realPathFileAlloc(std.testing.io, "a", std.testing.allocator);
        errdefer std.testing.allocator.free(a);
        const b = try tmp.dir.realPathFileAlloc(std.testing.io, "b", std.testing.allocator);
        return .{ .tmp = tmp, .a = a, .b = b };
    }

    fn deinit(self: *TestRepoPair) void {
        std.testing.allocator.free(self.a);
        std.testing.allocator.free(self.b);
        self.tmp.cleanup();
        self.* = undefined;
    }
};

test "review cancel remains available when source validation failed" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .review_output = &output,
    };
    _ = app.pages.review.activation.activate(0, .failed, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishReview(&ctx, .approved);
    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(!output.ready);
    try std.testing.expectEqualStrings("review source is still being validated", app.pages.review.status.text());

    try app.finishReview(&ctx, .canceled);
    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 130), output.exit_code);
}

test "finishReview waits for pending git action before writing output" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .review_output = &output,
    };
    action_lifecycle.testing.installAccepted(&app.action_runtime, .{ .generation = 7, .kind = .stage_file });
    defer action_lifecycle.testing.clear(&app.action_runtime);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishReview(&ctx, .canceled);

    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(!output.ready);
    try std.testing.expect(app.actionLifecycleView().hasPending());
    try std.testing.expectEqualStrings("finish current git action before finishing review", app.pages.review.status.text());
}

test "finishReview writes output and quits when no git action is pending" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .review_output = &output,
    };
    _ = app.pages.review.activation.activate(0, .fresh, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishReview(&ctx, .approved);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.json.items, "\"decision\":\"approved\"") != null);
}

test "direct nested Review message uses the same update owner as keyboard input" {
    var direct: App = .{ .allocator = std.testing.allocator };
    var keyboard: App = .{ .allocator = std.testing.allocator };
    var direct_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var keyboard_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try direct.update(.{ .review = .toggle_focus }, &direct_ctx);
    const keyboard_msg = keyboard.handleEvent(.{ .key_press = .{ .codepoint = chasen.Key.tab } }) orelse return error.ExpectedReviewMessage;
    try std.testing.expectEqual(App.Msg{ .review = .toggle_focus }, keyboard_msg);
    try keyboard.update(keyboard_msg, &keyboard_ctx);

    try std.testing.expectEqual(review_page.Focus.diff, direct.pages.review.viewer.focus);
    try std.testing.expectEqual(direct.pages.review.viewer.focus, keyboard.pages.review.viewer.focus);
}

test "normal and help commit keys use the same nested Review adapter" {
    const repo: repo_discovery.RepoEntry = .{
        .label = "repo",
        .display_path = "/repo",
        .canonical_root = "/repo",
    };
    var normal: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = repo } },
        },
    };
    var help: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = repo } },
        },
    };
    help.overlay.openHelpForPage(.review);
    var normal_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var help_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const normal_msg = normal.handleEvent(.{ .key_press = .{ .codepoint = 'c' } }) orelse return error.ExpectedReviewMessage;
    const help_msg = help.handleEvent(.{ .key_press = .{ .codepoint = 'c' } }) orelse return error.ExpectedReviewMessage;
    try std.testing.expectEqual(App.Msg{ .review = .enter_commit_panel }, normal_msg);
    try std.testing.expectEqual(normal_msg, help_msg);

    try normal.update(normal_msg, &normal_ctx);
    try help.update(help_msg, &help_ctx);
    try std.testing.expect(normal.local_workflow.commit_panel.is_open);
    try std.testing.expect(help.local_workflow.commit_panel.is_open);
    try std.testing.expect(!help.overlay.isHelp());
}

test "review session q writes structured canceled output before quitting" {
    var output: review_session.Output = .{};
    defer output.deinit(std.testing.allocator);
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .review_mode = true },
        .review_output = &output,
    };
    _ = app.pages.review.activation.activate(0, .fresh, .unavailable, .unavailable);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const msg = app.handleEvent(.{ .key_press = .{ .codepoint = 'q' } }) orelse return error.ExpectedReviewCancel;
    try std.testing.expectEqual(App.Msg{ .review = .finish_review_canceled }, msg);
    try app.update(msg, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(output.ready);
    try std.testing.expectEqual(@as(u8, 130), output.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, output.json.items, "\"decision\":\"canceled\"") != null);
}

fn paletteWithOverride(role: theme.Role, color: theme.ColorValue) theme.Palette {
    const FakeConfig = struct {
        role: theme.Role,
        color: theme.ColorValue,

        pub fn get(self: @This(), requested: theme.Role) ?theme.ColorValue {
            if (requested == self.role) return self.color;
            return null;
        }
    };

    return theme.Palette.fromConfig(FakeConfig{ .role = role, .color = color });
}

test "amend confirmation chrome follows amend role override" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 30);
    defer ts.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 30 },
        .theme = paletteWithOverride(.amend, .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } }),
        .local_workflow = .{ .commit_panel = app_commit_panel.State.init(std.testing.allocator) },
    };
    defer app.local_workflow.commit_panel.deinit();
    defer app.localWorkflow().cancelAmendConfirmation(std.testing.allocator);

    app.local_workflow.commit_panel.open(.amend);
    app.local_workflow.commit_panel.insert('x');
    try workflow_local.testing.openAmendConfirmation(app.localWorkflow(), std.testing.allocator, "/repo");

    try app.view(&ts.surface);

    const content_rect = app_shell_layout.contentRect(ts.surface.size());
    const dialog_rect = ui.Modal.dialogRectFor(content_rect, .{
        .dialog_width = @min(content_rect.width, @as(u16, 72)),
        .dialog_height = @min(content_rect.height, @as(u16, 9)),
    });

    try ts.expectCellText(dialog_rect.col, dialog_rect.row, "╭");
    try std.testing.expect(ts.surface.readCell(dialog_rect.col, dialog_rect.row).?.style.fg.eql(.{ .rgb = .{ 7, 8, 9 } }));
}

test "selectionContext keeps status-only selection while status load is pending" {
    var app: App = .{
        .pages = .{ .review = .{
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
            .status_load = .{ .generation = 9, .pending = .{ .generation = 9 } },
        } },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const selection = app.selectionContext();
    const status = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 0), status.status_index);
    try std.testing.expectEqualStrings("src/new.zig", status.path_key.?);
}

test "selectionContext rejects stale status-only identities" {
    var app: App = .{
        .pages = .{ .review = .{
            .viewer = .{ .selected_target = .{ .status_only = 0 } },
        } },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.git_status.deinit();

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/other", &status_bundle);
    try std.testing.expect(app.selectionContext().selected == null);

    app.pages.review.git_status.deinit();
    var matching = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &matching);
    app.pages.review.viewer.selected_target = .{ .status_only = 1 };
    try std.testing.expect(app.selectionContext().selected == null);
}

test "selectedEditorTarget accepts status-only file rows" {
    const status_nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "staged.zig",
            .path = "src/staged.zig",
            .path_key = "src/staged.zig",
            .depth = 0,
            .target = .{ .status_entry = 0 },
        },
    };
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &.{} },
                .file_text_eligibility = &.{},
                .tree = .{ .nodes = &status_nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_target = .{ .status_only = 0 },
            },
        } },
        .config = .{ .source = .cached },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.git_status.deinit();
    acceptTestSource(&app);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/staged.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    switch (app.reviewContent().editorTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src/staged.zig", target.path);
        },
        else => return error.ExpectedEditorTarget,
    }
}

test "selectedEditorTarget rejects deleted and historical sources" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwoWithStatuses()),
            .viewer = .{
                .selected_node = 1,
                .selected_target = .{ .diff_file = 1 },
            },
        } },
        .config = .{ .source = .cached },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    acceptTestSource(&app);

    try std.testing.expectEqual(review_content.EditorTargetResult.deleted_file, app.reviewContent().editorTarget());

    app.config.source = .{ .range = "main...HEAD" };
    try std.testing.expectEqual(review_content.EditorTargetResult.unavailable_source, app.reviewContent().editorTarget());
}

test "selectedEditorTarget rejects deleted status-only file rows from fresh status" {
    const status_nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "deleted.zig",
            .path = "src/deleted.zig",
            .path_key = "src/deleted.zig",
            .depth = 0,
            .target = .{ .status_entry = 0 },
        },
    };
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(.{
                .text = "",
                .document = .{ .files = &.{} },
                .file_text_eligibility = &.{},
                .tree = .{ .nodes = &status_nodes },
                .collapsed_dirs = .{},
                .bytes = 0,
                .lines = 0,
            }),
            .viewer = .{
                .selected_node = 0,
                .selected_target = .{ .status_only = 0 },
            },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.git_status.deinit();
    acceptTestSource(&app);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " D src/deleted.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    try std.testing.expectEqual(review_content.EditorTargetResult.deleted_file, app.reviewContent().editorTarget());
}

test "selectedEditorTarget rejects live sources without active repo" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .config = .{ .source = .unstaged },
    };
    acceptTestSource(&app);

    try std.testing.expectEqual(review_content.EditorTargetResult.no_repo, app.reviewContent().editorTarget());
}

test "selectedEditorTarget rejects directory rows" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 0 },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    acceptTestSource(&app);

    try std.testing.expectEqual(review_content.EditorTargetResult.directory_unsupported, app.reviewContent().editorTarget());
}

test "active diff display uses ready combined projection by identity" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const request = try app_review_projection.testing.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .combined_hunks,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    var frame_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer frame_arena.deinit();
    const display = (try app.reviewNavigationView().activeDiffDisplay(frame_arena.allocator(), .unified)) orelse return error.ExpectedActiveDisplay;
    try std.testing.expect(display == .combined_projection);
    try std.testing.expectEqual(@as(usize, 2), display.combined_projection.file.hunks.len);
    const stages = display.hunkStagePresentation();
    try std.testing.expect(stages == .per_hunk);
    try std.testing.expectEqual(diff_render.HunkStageState.staged, stages.stateForHunk(0));
    try std.testing.expectEqual(diff_render.HunkStageState.unstaged, stages.stateForHunk(1));
    const bundle = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    switch (display.syntaxView()) {
        .combined => |syntax| {
            try std.testing.expect(syntax.origins.ptr == bundle.presentation.projection.presentation_syntax_origins.ptr);
            try std.testing.expect(syntax.cached == &bundle.presentation.cached_bundle.loaded.syntax_spans);
            try std.testing.expect(syntax.unstaged == &bundle.presentation.unstaged_bundle.loaded.syntax_spans);
        },
        .direct => return error.ExpectedCombinedSyntaxView,
    }
}

test "explicit interim navigation creates override but automatic state does not" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 31,
            .status_load = .{ .freshness = .stale_refresh },
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .metadata = 0 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);

    app.reviewNavigation().initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(@as(?usize, 0), app.reviewNavigationView().selectedDiffCursorOffset());

    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_cursor_offset = 5,
            .diff_scroll = 4,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.update(.{ .review = .scroll_diff_up }, &ctx);
    try std.testing.expectEqual(@as(u64, 0), app.pages.review.display_navigation_input_revision);
    try std.testing.expect(app.pages.review.pending_display_navigation_restore.?.override == null);

    try app.update(.{ .review = .scroll_diff_down }, &ctx);

    try std.testing.expectEqual(@as(u64, 1), app.pages.review.display_navigation_input_revision);
    var restore = app.pages.review.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    var override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.review.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(app.reviewNavigationView().selectedDiffCursorOffset(), override.diff_cursor_offset);

    try app.update(.{ .review = .scroll_diff_down }, &ctx);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.display_navigation_input_revision);
    restore = app.pages.review.pending_display_navigation_restore orelse return error.ExpectedPendingDisplayRestore;
    override = restore.override orelse return error.ExpectedNavigationOverride;
    try std.testing.expectEqual(app.pages.review.viewer.diff_cursor, override.diff_cursor);
    try std.testing.expectEqual(app.reviewNavigationView().selectedDiffCursorOffset(), override.diff_cursor_offset);

    const revision_before_clamp = app.pages.review.display_navigation_input_revision;
    app.reviewNavigation().clampDiffNavigation();
    try std.testing.expectEqual(revision_before_clamp, app.pages.review.display_navigation_input_revision);
}

test "initialSelectionContext selects first diff file and hunk" {
    const loaded = app_test_support.loadedDiffTwo();
    const selection = App.initialSelectionContext(.{ .patch_file = "changes.diff" }, null, &loaded, null);

    try std.testing.expect(selection.repo_root == null);
    try std.testing.expectEqual(context.SourceKind.patch_file, selection.source.kind);
    try std.testing.expectEqualStrings("changes.diff", selection.source.detail.?);

    const file = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), file.file_index);
    try std.testing.expectEqualStrings("a", file.path_key.?);
    try std.testing.expectEqual(@as(?usize, 0), file.hunk_index);
}

test "initialSelectionContext prefers diff file before status-only selection" {
    const loaded = app_test_support.loadedDiffTwo();
    const doc = try git_status.parse(std.testing.allocator, "?? src/status-only.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    const selection = App.initialSelectionContext(.unstaged, "/repo", &loaded, doc);

    const file = selection.selected.?.diff_file;
    try std.testing.expectEqual(@as(usize, 0), file.file_index);
    try std.testing.expectEqualStrings("a", file.path_key.?);
}

test "initialSelectionContext falls back to first selectable status entry" {
    const empty_loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &.{} },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
    const doc = try git_status.parse(std.testing.allocator, "!! ignored.tmp\x00?? src/new.zig\x00 M src/changed.zig\x00");
    defer std.testing.allocator.free(doc.entries);

    const selection = App.initialSelectionContext(.unstaged, "/repo", &empty_loaded, doc);

    const status = selection.selected.?.status_only;
    try std.testing.expectEqual(@as(usize, 1), status.status_index);
    try std.testing.expectEqualStrings("src/new.zig", status.path_key.?);
}

test "initialSelectionContext returns null when diff and status have no selectable entry" {
    const empty_loaded: LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &.{} },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
    const doc = try git_status.parse(std.testing.allocator, "!! ignored.tmp\x00");
    defer std.testing.allocator.free(doc.entries);

    const selection = App.initialSelectionContext(.unstaged, "/repo", &empty_loaded, doc);

    try std.testing.expect(selection.selected == null);
}

test "activeRootFromDiscovery rejects ambiguous workspace export" {
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "one", .display_path = "one", .canonical_root = "/work/one" },
        .{ .label = "two", .display_path = "two", .canonical_root = "/work/two" },
    };

    try std.testing.expectError(error.AmbiguousWorkspaceExport, App.activeRootFromDiscovery(.{ .workspace = .{
        .current_root = "/work",
        .repos = &repos,
    } }));
}

test "load empty state shows actionable no changes message" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(82, 18);
    defer ts.deinit();

    const app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 82, .height = 18 },
    };

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No changes");
    try app_test_support.expectSnapshotContains(&ts, "Press r to reload or q to quit.");
}

test "clean empty state shows branch status chrome" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 100, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "feature/topic");
    try app_test_support.expectSnapshotContains(&ts, "0 files / 0 hunks");
}

test "clean empty state hides stale branch status chrome" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 100, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/other", &bundle);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotNotContains(&ts, "feature/topic");
    try app_test_support.expectSnapshotContains(&ts, "0 files / 0 hunks");
}

test "clean empty state advertises pull only when clean status snapshot is fresh" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(110, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 110, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.view(&ts.surface);
    try app_test_support.expectSnapshotNotContains(&ts, "U to fetch + fast-forward");

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    var ts_ready: chasen.testing.TestSurface = undefined;
    try ts_ready.init(110, 18);
    defer ts_ready.deinit();
    try app.view(&ts_ready.surface);
    try app_test_support.expectSnapshotContains(&ts_ready, "U to fetch + fast-forward");
}

test "clean empty state shows bound fetch key from effective keymap" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 18);
    defer ts.deinit();

    var fetch_config: keymap.Config = .{};
    fetch_config.set(.fetch, .{ .ctrl = .s });
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 120, .height = 18 },
        .keymap = keymap.Effective.fromConfig(fetch_config),
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "Ctrl+s to fetch");
}

test "clean empty state omits fetch hint when unbound or target is not ready" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 18);
    defer ts.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 120, .height = 18 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);

    try app.view(&ts.surface);
    try app_test_support.expectSnapshotNotContains(&ts, "Ctrl+s to fetch");

    app.pages.review.branch_status.clear();
    var fetch_config: keymap.Config = .{};
    fetch_config.set(.fetch, .{ .ctrl = .s });
    app.keymap = keymap.Effective.fromConfig(fetch_config);

    var ts_not_ready: chasen.testing.TestSurface = undefined;
    try ts_not_ready.init(120, 18);
    defer ts_not_ready.deinit();
    try app.view(&ts_not_ready.surface);
    try app_test_support.expectSnapshotNotContains(&ts_not_ready, "Ctrl+s to fetch");
}

test "clean empty stdin source does not advertise remote actions" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(120, 18);
    defer ts.deinit();

    var fetch_config: keymap.Config = .{};
    fetch_config.set(.fetch, .{ .ctrl = .s });
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_changes } },
        } },
        .terminal_size = .{ .width = 120, .height = 18 },
        .config = .{ .source = .stdin },
        .keymap = keymap.Effective.fromConfig(fetch_config),
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.pages.review.git_status.deinit();

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "main");
    try app_test_support.expectSnapshotNotContains(&ts, "U to fetch + fast-forward");
    try app_test_support.expectSnapshotNotContains(&ts, "Ctrl+s to fetch");
}

test "load empty state distinguishes missing repository" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 18);
    defer ts.deinit();

    const app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .empty = .no_repository } },
        } },
        .terminal_size = .{ .width = 90, .height = 18 },
    };

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No Git repository");
    try app_test_support.expectSnapshotContains(&ts, "Press q to quit.");
}

test "load failed state shows first error line and retry hint" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 18);
    defer ts.deinit();

    var app: App = .{
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 90, .height = 18 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    try app.pages.review.load.replaceFailed(std.testing.allocator, "git diff failed\nsecond line");

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "Could not load diff");
    try app_test_support.expectSnapshotContains(&ts, "git diff failed");
    try app_test_support.expectSnapshotContains(&ts, "Press r to retry or q to quit.");
    try app_test_support.expectSnapshotNotContains(&ts, "second line");
}

test "loaded diff with empty visible filter shows local empty state" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(100, 18);
    defer ts.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    var loaded = app_test_support.loadedDiffTwoWithStatuses();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .binary);

    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .review_display = .{ .changed_file_filter = .binary },
        } },
        .terminal_size = .{ .width = 100, .height = 18 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No files match current filters");
    try app_test_support.expectSnapshotContains(&ts, "Press F to change filter or r to reload.");
}

test "focus loss terminates selection without a deferred result" {
    var app: App = .{
        .pages = .{ .review = .{
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .config = .{ .source = .{ .no_index = .{ .left = "left", .right = "right" } } },
    };
    _ = app.pageCoordinator().activateReview();
    app.pages.review.auto_reload = .init(.inherit, .{}, app.config.source);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try std.testing.expectEqual(App.Msg.focus_lost, app.handleEvent(.focus_out).?);
    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.review.selection_owner.activeMouseSelection());
    try std.testing.expect(app.pages.review.deferred_source_apply == null);

    try app.reviewRead().autoReloadTick(&ctx);
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const cycle_id = task.background_cycle_id.?;
    const generation = task.generation;
    diff_source.freeLoadRequest(std.testing.allocator, task.request);
    std.testing.allocator.destroy(task);
    _ = app.pages.review.load.clearPendingIfCurrent(.{ .diff_load = generation });
    reviewReloadForTest(&app).clearPendingReloadIfGeneration(std.testing.allocator, generation);
    app.pages.review.auto_reload.finishMember(cycle_id, .source);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "repo switch clears pending reload anchor" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "repo", .default_dir);
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "repo", allocator);
    defer allocator.free(root);
    var app: App = .{
        .pages = .{ .review = .{
            .pending_reload = .{
                .generation = 9,
                .kind = .manual,
                .anchor = .{
                    .path_key = try std.testing.allocator.dupe(u8, "a"),
                    .sidebar_identity = .{ .file = try std.testing.allocator.dupe(u8, "a") },
                    .selected_target_tag = .diff_file,
                    .visible_sidebar_row = 0,
                    .diff_cursor = .{ .metadata = 0 },
                    .diff_cursor_offset = 0,
                    .diff_scroll = 0,
                    .diff_horizontal_scroll = 0,
                    .sidebar_horizontal_scroll = 0,
                    .search_coordinate = null,
                },
            },
        } },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_session.deinit(allocator);

    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, root),
        0,
        .external_selection,
    ));

    try std.testing.expect(app.pages.review.pending_reload == null);
}

fn setDiffSearchQuery(app: *App, query: []const u8) void {
    @memcpy(app.pages.review.search.query.buffer[0..query.len], query);
    app.pages.review.search.query.len = query.len;
    app.pages.review.search.query.cursor = query.len;
    setDiffSearchInput(app, query);
}

fn setDiffSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.pages.review.search.input.buffer[0..query.len], query);
    app.pages.review.search.input.len = query.len;
    app.pages.review.search.input.cursor = query.len;
}

fn acceptTestSource(app: *App) void {
    app.pages.review.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("test source"));
    syncTestActivation(app);
}

fn syncTestActivation(app: *App) void {
    const source: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(app.config.source))
        .immutable
    else if (app.pages.review.auto_reload.sourceIsActionable())
        .fresh
    else if (app.pages.review.load.hasPending())
        .pending
    else
        .unavailable;
    _ = app.pages.review.activation.activate(
        app.repo_session.repo_epoch,
        source,
        review_authority.auxiliaryMember(app.pages.review.status_load),
        review_authority.auxiliaryMember(app.pages.review.branch_status_load),
    );
}

fn testCombinedHunkBundle(allocator: std.mem.Allocator) !app_review_projection.CombinedHunkBundle {
    var cached_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection);
    errdefer cached_bundle.deinit();

    var unstaged_bundle = try app_load.buildLoadedBundle(allocator, app_test_support.diff_unstaged_projection);
    errdefer unstaged_bundle.deinit();

    var cached_authority = try app_projection_component.ParsedComponent.parse(allocator, app_test_support.diff_cached_projection);
    errdefer cached_authority.deinit();
    var unstaged_authority = try app_projection_component.ParsedComponent.parse(allocator, app_test_support.diff_unstaged_projection);
    errdefer unstaged_authority.deinit();

    var presentation_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer presentation_arena.deinit();
    var authority_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer authority_arena.deinit();
    const projection = try diff_hunk_projection.buildWithAllocators(
        presentation_arena.allocator(),
        authority_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );

    return .{
        .presentation = .{
            .arena = presentation_arena,
            .projection = projection.presentation,
            .cached_bundle = cached_bundle,
            .unstaged_bundle = unstaged_bundle,
            .fingerprint = diff_presentation_identity.fingerprint(projection.presentation.file),
            .content_token = .init(1),
        },
        .authority = .{
            .arena = authority_arena,
            .projection = projection.authority,
            .cached_component = cached_authority,
            .unstaged_component = unstaged_authority,
            .status_snapshot_revision = 0,
        },
    };
}
