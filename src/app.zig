const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const ui = if (builtin.is_test) @import("chasen_ui") else struct {};
const app_actions = @import("app/actions.zig");
const app_auto_reload = if (builtin.is_test) @import("app/auto_reload.zig") else struct {};
const app_commit_panel = @import("app/commit_panel.zig");
const app_input = @import("app/input.zig");
const app_load_state = @import("app/load_state.zig");
const app_load = @import("app/load.zig");
const app_message = @import("app/message.zig");
const effect_origin = @import("app/effect_origin.zig");
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
const review_selection_model = if (builtin.is_test) @import("app/diff_surface/selection.zig") else struct {};
const review_page_update = @import("app/pages/review/update.zig");
const review_view = @import("app/pages/review/view.zig");
const repository_page = @import("app/pages/repository.zig");
const repository_coordinator = @import("app/pages/repository/coordinator.zig");
const repository_selection = if (builtin.is_test) @import("app/pages/repository/selection.zig") else struct {};
const app_projection_component = if (builtin.is_test) @import("app/projection_component.zig") else struct {};
const app_push_retry = @import("app/push_retry.zig");
const repo_session = @import("app/repo_session.zig");
const app_review_projection = if (builtin.is_test) @import("app/review_projection.zig") else struct {};
const app_state = @import("app/state.zig");
const app_test_support = if (builtin.is_test) @import("app/test_support.zig") else struct {};
const app_view = @import("app/view.zig");
const app_git_requests = @import("app/git_requests.zig");
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
const editor = @import("editor.zig");
const file_tree = @import("file_tree.zig");
const git_ops = @import("app/git_ops.zig");
const git_backend = @import("git/backend.zig");
const git_branch_status = if (builtin.is_test) @import("git/branch_status.zig") else struct {};
const git_status = @import("git/status.zig");
const keymap = @import("keymap");
const loaded_diff = @import("loaded_diff.zig");
const repo_discovery = @import("repo/discovery.zig");
const repo_root_capability = @import("repo/root_capability.zig");
const review_session = @import("review/session.zig");
const theme = @import("theme");

const auto_reload_timer_id = "gitframe.auto_reload";
const git_action_spinner_timer_id = "gitframe.git_action_spinner";
const git_action_spinner_interval_ns = 120 * std.time.ns_per_ms;

const ActionTerminalTarget = enum {
    rejected_terminal,
    current_review_target,
    detached_review_target,
};
const SourceMode = diff_source.SourceMode;
const CliConfig = diff_source.CliConfig;

const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(app_message.Msg);
const EmptyReason = app_load_state.EmptyReason;
const SessionHunkMarkMutation = git_ops.SessionHunkMarkMutation;
const LoadedDiff = loaded_diff.LoadedDiff;
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(app_message.Msg);
const BranchStatusLoadFinished = app_load.BranchStatusLoadFinished;
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(app_message.Msg);
const BranchListLoadFinished = app_load.BranchListLoadFinished;
const BranchListLoadTask = app_load.BranchListLoadTask(app_message.Msg);
const CompareLoadFinished = app_load.CompareLoadFinished;
const StatusLoadFinished = app_load.StatusLoadFinished;
const StatusLoadTask = app_load.StatusLoadTask(app_message.Msg);
const ReviewProjectionFinished = app_load.ReviewProjectionFinished;
const ReviewProjectionTask = app_load.ReviewProjectionTask(app_message.Msg);
const GeneratedSyntaxTask = app_load.GeneratedSyntaxTask(app_message.Msg);
const AmendFinished = app_actions.AmendFinished;
const CommitFinished = app_actions.CommitFinished;
const CommitMessageAssistFinished = app_actions.CommitMessageAssistFinished;
const DiscardFileFinished = app_actions.DiscardFileFinished;
const FetchFinished = app_actions.FetchFinished;
const PullFinished = app_actions.PullFinished;
const PushFinished = app_actions.PushFinished;
const SwitchBranchFinished = app_actions.SwitchBranchFinished;
const StageHunkFinished = app_actions.StageHunkFinished;
const StageFileFinished = app_actions.StageFileFinished;
const TargetKind = git_ops.TargetKind;
const ToggleStageOperation = git_ops.ToggleStageOperation;
const UnstageFileFinished = app_actions.UnstageFileFinished;
const UnstageHunkFinished = app_actions.UnstageHunkFinished;
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
const ClipboardCopyFinished = app_message.ClipboardCopyFinished;

const EffectOrigin = effect_origin.Origin;
const PageEffectOrigin = effect_origin.PageOrigin;

const EditorForegroundState = struct {
    request_id: chasen.ForegroundCommandRequestId,
    origin: PageEffectOrigin,
};

const ClipboardCopyState = struct {
    origin: EffectOrigin,
    label: []const u8,
};

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
    actions: app_actions.ActionState = .{},
    git_action_spinner_tick: u8 = 0,
    git_action_spinner_timer_running: bool = false,
    status: app_state.StatusMessage = .{},
    commit_panel: app_commit_panel.State = .{},
    overlay: app_state.OverlayState = .{},
    discard_confirmation: ?app_state.DiscardFileConfirmation = null,
    amend_confirmation: ?app_state.AmendConfirmation = null,
    push_confirmation: ?app_state.PushConfirmation = null,
    pull_confirmation: ?app_state.PullConfirmation = null,
    push_error_message: ?[]u8 = null,
    push_retry: app_push_retry.Model = .{},
    editor_foreground_request: ?EditorForegroundState = null,
    /// Correlates shell-owned clipboard completions with semantic metadata
    /// captured at request time. Values own no storage; the map allocation is
    /// released during App teardown.
    clipboard_copy_states: std.AutoHashMapUnmanaged(u64, ClipboardCopyState) = .empty,
    branch_switch: app_state.BranchSwitchState = .{},
    branch_switch_load_generation: u64 = 0,
    branch_switch_load_pending: ?u64 = null,

    const CopyRequest = struct {
        origin: EffectOrigin,
        label: []const u8,
        text: []const u8,
    };

    const PopupCopyTarget = struct {
        label: []const u8,
        text: []const u8,
    };

    pub const Msg = app_message.Msg;

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
        self.commit_panel = app_commit_panel.State.init(ctx.allocator());
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
        self.commit_panel.deinit();
        self.cancelDiscardConfirmation(deinit_ctx.allocator);
        self.cancelAmendConfirmation(deinit_ctx.allocator);
        self.cancelPushConfirmation(deinit_ctx.allocator);
        self.cancelPullConfirmation(deinit_ctx.allocator);
        self.push_retry.deinit(deinit_ctx.allocator);
        self.clipboard_copy_states.deinit(deinit_ctx.allocator);
        self.clearPushError(deinit_ctx.allocator);
        self.clearBranchSwitch(deinit_ctx.allocator);
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
            .action_pending = app_git_requests.hasPendingAction(self.actions),
            .review = self.reviewRead().repositorySessionPort(),
            .repository = .{ .page = &self.pages.repository },
            .compare = .{ .page = &self.pages.compare },
            .shell = .{
                .retry = &self.push_retry,
                .push_error_message = &self.push_error_message,
                .overlay = &self.overlay,
                .branch_switch = &self.branch_switch,
                .branch_switch_load_pending = &self.branch_switch_load_pending,
            },
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
                .commit_input = self.commit_panel.is_open,
                .confirmation = self.overlay.isDiscardFile() or self.overlay.isAmendCommit() or
                    self.overlay.isPushBranch() or self.overlay.isPullBranch(),
                .credential_input = self.overlay.isPushCredentials(),
                .branch_switch = self.overlay.isSwitchBranch(),
                .push_error = self.overlay.isPushError(),
                .git_action = app_git_requests.hasPendingAction(self.actions),
                .foreground_command = self.push_retry.state.hasForeground() or self.editor_foreground_request != null,
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
                .commit_panel = self.commit_panel.is_open,
                .action_pending = app_git_requests.hasPendingAction(self.actions),
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
            .push_inspection_finished => |finished| try self.finishPushInspection(ctx, finished),
            .clipboard_copy_finished => |finished| self.finishClipboardCopy(ctx, finished),
            .review => |review_msg| try self.updateReview(ctx, review_msg),
            .compare => |compare_msg| {
                var outcome = try self.compareCoordinator().update(ctx, compare_msg);
                defer outcome.deinit(ctx.allocator());
                if (outcome.takeClipboard()) |taken| {
                    var effect = taken;
                    defer effect.deinit(ctx.allocator());
                    self.queueClipboardCopy(ctx, .{
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
                    self.queueClipboardCopy(ctx, .{
                        .origin = effect.origin,
                        .label = effect.label,
                        .text = effect.text,
                    });
                }
            },
            .cancel_commit_panel => self.closeCommitPanel(),
            .submit_commit_panel => try self.submitCommitPanel(ctx),
            .assist_commit_message => try self.assistCommitMessage(ctx),
            .copy_commit_message => self.copyCommitMessage(ctx),
            .commit_panel_tab => self.commit_panel.toggleField(),
            .commit_panel_enter => self.commit_panel.enter(),
            .commit_panel_insert => |codepoint| self.commit_panel.insert(codepoint),
            .commit_panel_paste => |text| self.commit_panel.paste(text),
            .commit_panel_backspace => self.commit_panel.backspace(),
            .commit_panel_move_left => self.commit_panel.moveLeft(),
            .commit_panel_move_right => self.commit_panel.moveRight(),
            .commit_panel_move_up => self.commit_panel.moveUp(),
            .commit_panel_move_down => self.commit_panel.moveDown(),
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
            .push_credential_tab => self.togglePushCredentialField(),
            .push_credential_submit => try self.submitPushCredentials(ctx),
            .push_credential_cancel => self.cancelPushCredentialPrompt(ctx.allocator()),
            .push_credential_insert => |codepoint| self.insertPushCredential(codepoint),
            .push_credential_paste => |text| self.pastePushCredential(text),
            .push_credential_backspace => self.backspacePushCredential(),
            .push_credential_move_left => self.movePushCredentialLeft(),
            .push_credential_move_right => self.movePushCredentialRight(),
            .confirm_discard_file => try self.confirmDiscardFile(ctx),
            .cancel_discard_file => self.cancelDiscardConfirmation(ctx.allocator()),
            .confirm_amend => try self.confirmAmend(ctx),
            .cancel_amend => self.cancelAmendConfirmation(ctx.allocator()),
            .confirm_push => try self.confirmPush(ctx),
            .cancel_push => self.cancelPushConfirmation(ctx.allocator()),
            .confirm_pull => try self.confirmPull(ctx),
            .cancel_pull => self.cancelPullConfirmation(ctx.allocator()),
            .branch_switch_move_previous => self.moveBranchSwitchSelection(-1),
            .branch_switch_move_next => self.moveBranchSwitchSelection(1),
            .confirm_branch_switch => try self.confirmBranchSwitch(ctx),
            .cancel_branch_switch => self.clearBranchSwitch(ctx.allocator()),
            .close_push_error => self.clearPushError(ctx.allocator()),
            .open_push_credentials => try self.openPushCredentialPrompt(ctx),
            .run_interactive_push => try self.runInteractivePush(ctx),
            .reload => switch (self.active_page) {
                .review => {
                    switch (self.reviewRead().prepareManualReload()) {
                        .blocked => {},
                        .ready => {
                            self.clearBranchSwitch(ctx.allocator());
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
            .git_action_spinner_tick => self.gitActionSpinnerTick(ctx),
            .quit => self.requestQuit(ctx),
        }
        self.reviewRead().retireSupersededActionCursor(ctx, self.actions.generation);
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
        self.reconcileGitActionSpinnerTimer(ctx);
    }

    fn requestQuit(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (app_git_requests.hasPendingAction(self.actions)) {
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
            .enter_commit_panel => self.enterCommitPanelMode(.commit),
            .enter_amend_panel => self.enterCommitPanelMode(.amend),
            .toggle_selected_file => try self.toggleSelectedFileStage(ctx),
            .toggle_selected_hunk => try self.toggleSelectedHunkStage(ctx),
            .request_discard_selected_file => try self.requestDiscardSelectedFile(ctx.allocator()),
            .request_push => try self.requestPush(ctx.allocator()),
            .request_pull => try self.requestPull(ctx.allocator()),
            .request_fetch => try self.requestFetch(ctx),
            .request_branch_switch => try self.requestBranchSwitch(ctx),
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
                .branch_list => |result| try self.finishBranchListLoad(ctx, result),
            },
            .coordinator => |coordinator_result| switch (coordinator_result) {
                .repo_discovery => |result| try self.finishReviewRepoDiscovery(ctx, result),
            },
        }
    }

    fn finishActionResult(self: *App, ctx: *chasen.Ctx(Msg), finished: ActionFinishedMsg) !void {
        switch (finished) {
            .stage_file => |result| try self.finishStageFile(ctx, result),
            .stage_hunk => |result| try self.finishStageHunk(ctx, result),
            .unstage_file => |result| try self.finishUnstageFile(ctx, result),
            .unstage_hunk => |result| try self.finishUnstageHunk(ctx, result),
            .discard_file => |result| try self.finishDiscardFile(ctx, result),
            .commit => |result| try self.finishCommit(ctx, result),
            .assist_commit_message => |result| self.finishCommitMessageAssist(ctx, result),
            .amend => |result| try self.finishAmend(ctx, result),
            .push => |result| try self.finishPush(ctx, result),
            .pull => |result| try self.finishPull(ctx, result),
            .fetch => |result| try self.finishFetch(ctx, result),
            .switch_branch => |result| try self.finishSwitchBranch(ctx, result),
            .push_foreground => |result| try self.finishPushForeground(ctx, result),
            .editor => |result| try self.finishEditorCommand(ctx, result),
        }
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
            .clipboard_copy_finished,
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

    fn gitActionSpinnerTick(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.actions.pending == null) {
            self.git_action_spinner_tick = 0;
            self.git_action_spinner_timer_running = false;
            ctx.timer().cancel(git_action_spinner_timer_id) catch {};
            self.redraw_plan.requestSkip();
            return;
        }
        self.git_action_spinner_tick +%= 1;
    }

    fn reconcileGitActionSpinnerTimer(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.actions.pending != null) {
            if (self.git_action_spinner_timer_running) return;
            ctx.timer().every(git_action_spinner_timer_id, git_action_spinner_interval_ns, .git_action_spinner_tick) catch return;
            self.git_action_spinner_timer_running = true;
            return;
        }

        if (!self.git_action_spinner_timer_running) return;
        self.git_action_spinner_timer_running = false;
        self.git_action_spinner_tick = 0;
        ctx.timer().cancel(git_action_spinner_timer_id) catch {};
    }

    pub fn view(self: *const App, surface: *chasen.Surface) !void {
        return app_view.view(self.shellViewContext(), surface);
    }

    fn shellViewContext(self: *const App) app_view.Context {
        const body_size = self.shellLayout().bodySize();
        const repo_view = self.repoSessionView();
        const picker = repo_view.picker();
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
            .actions = &self.actions,
            .status = &self.status,
            .page_status = self.activePageStatus(),
            .commit_panel = &self.commit_panel,
            .repo_picker = picker.model,
            .repo_picker_pending_workspace_root = picker.pending_workspace_root,
            .repo_picker_items = picker.items,
            .repo_picker_has_recent = picker.has_recent,
            .overlay = &self.overlay,
            .committed_repo_discovery_kind = picker.committed_discovery_kind,
            .active_repo_index = picker.active_index,
            .has_active_repo = repo_view.activeRoot() != null,
            .discard_confirmation = self.discard_confirmation,
            .amend_confirmation = self.amend_confirmation,
            .push_confirmation = self.push_confirmation,
            .pull_confirmation = self.pull_confirmation,
            .push_error_message = self.push_error_message,
            .push_retry_target = self.push_retry.state.availableTarget(),
            .push_retry_credentials_available = self.push_retry.state.credentialsAvailable(),
            .push_retry_inspecting = self.push_retry.state == .inspecting,
            .push_credential_prompt = self.push_retry.state.credentialPrompt(),
            .branch_switch = &self.branch_switch,
            .git_action_spinner_tick = self.git_action_spinner_tick,
            .staged_summary = self.stagedSummaryForActiveRepo(),
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
            self.commit_panel.is_open or self.repoSessionView().picker().model.mode) return null;
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
            .commit_panel_mode = self.commit_panel.is_open,
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
        const rows = @max(@as(usize, app_view.pushErrorVisibleRows(self.layoutSize(), self.push_error_message)), 1);
        const delta: isize = if (pages < 0)
            -@as(isize, @intCast(rows))
        else
            @as(isize, @intCast(rows));
        self.scrollPushError(delta);
    }

    fn clampPushErrorScroll(self: *App) void {
        self.overlay.push_error_scroll = @min(self.overlay.push_error_scroll, app_view.pushErrorMaxScroll(self.layoutSize(), self.push_error_message));
    }

    /// Atomically commit one concrete action launch and, for a mutation, close
    /// Review repository-read authority before control returns to the caller.
    fn acceptActionLaunch(self: *App, pending: app_actions.PendingAction) void {
        if (!self.actions.acceptLaunch(pending)) {
            @panic("action launch acceptance did not match its preparing owner");
        }
        if (!pending.kind.blocksBackgroundAcceptance()) return;

        const allocator = self.allocator orelse
            @panic("accepted mutating action requires App allocator");
        if (!self.reviewActionFence().closeForAcceptedMutation(allocator, pending)) {
            @panic("accepted mutating action could not close Review read authority");
        }
    }

    /// Accept one delivered terminal for the exact current launched action.
    /// Mutations reopen their matching Review read fence and queue the
    /// activation-scoped recovery intent before the action owner is retired.
    fn acceptActionTerminal(self: *App, pending: app_actions.PendingAction) bool {
        if (!self.actions.isAccepted(pending)) return false;
        if (pending.kind.blocksBackgroundAcceptance() and
            !self.reviewActionFence().reopenForExactTerminal(pending))
        {
            @panic("exact mutating action terminal could not reopen Review read authority");
        }
        return self.actions.finish(pending);
    }

    fn acceptActionTerminalForTarget(
        self: *App,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
        repo_root: []const u8,
    ) ActionTerminalTarget {
        if (!self.acceptActionTerminal(pending)) return .rejected_terminal;
        std.debug.assert(pending.kind.blocksBackgroundAcceptance());

        const current_target = self.active_page == .review and
            self.pages.review.activation.currentIdentity() != null and
            !diff_source.sourceIsOneShotInput(self.config.source) and
            self.repoSessionView().activeRootMatches(repo_root);
        if (current_target) return .current_review_target;

        self.reviewActionFence().discardDetachedTerminal(allocator, pending);
        return .detached_review_target;
    }

    fn stageSelectedFile(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.reviewOperations().stageTarget()) {
            .ready => |target| target,
            .already_staged => |path| {
                self.setReviewStatus("already staged: {s}", .{path});
                return;
            },
            .stale_status => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setReviewStatus("source is stale; press r to reload", .{});
                return;
            },
            .conflict_unsupported => |path| {
                self.setReviewStatus("conflict under selection: {s}", .{path});
                return;
            },
            .no_stageable_content => |path| {
                self.setReviewStatus("no stageable files under: {s}", .{path});
                return;
            },
            .unavailable_source, .no_repo => {
                self.setReviewStatus("stage unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setReviewStatus("no stageable file selected", .{});
                return;
            },
        };
        var proposal = try self.reviewOperations().ownStageFileProposal(ctx.allocator(), target);
        defer proposal.deinit(ctx.allocator());
        const owned = proposal.stage_file;
        const root_identity = self.repoSessionView().activeIdentity() orelse {
            self.setReviewStatus("stage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.reviewNavigation().prepareActionCursor(
            ctx.allocator(),
            self.repoSessionView().epoch(),
            root_identity,
            reviewActionCursorKind(owned.kind),
            owned.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());

        const pending = app_git_requests.startStageFile(Msg, ctx, &self.actions, .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .kind = owned.kind,
            .label = owned.label,
        }) catch |err| {
            self.setReviewStatus("could not start stage task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);
        self.reviewNavigation().installActionCursor(ctx.allocator(), &cursor, pending.generation);
        cursor_owned = false;
        self.setReviewStatus("staging: {s}", .{owned.label});
    }

    fn toggleSelectedFileStage(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        switch (self.reviewOperations().toggleStageTarget()) {
            .operation => |operation| switch (operation) {
                .stage => try self.stageSelectedFile(ctx),
                .unstage => try self.unstageSelectedFile(ctx),
            },
            .unavailable_source, .no_repo => self.setReviewStatus("stage toggle unavailable for this source", .{}),
            .no_path => self.setReviewStatus("no file selected", .{}),
            .stale_status => self.setReviewStatus("status is still loading", .{}),
            .stale_source => self.setReviewStatus("source is stale; press r to reload", .{}),
            .conflict_unsupported => |target| {
                if (target.kind == .directory) {
                    self.setReviewStatus("conflict under directory: {s}", .{target.path});
                } else {
                    self.setReviewStatus("conflict stage toggle is not supported yet", .{});
                }
            },
            .no_content => |target| {
                if (target.kind == .directory) {
                    self.setReviewStatus("no stageable or staged files under: {s}", .{target.path});
                } else {
                    self.setReviewStatus("no stageable or staged content selected", .{});
                }
            },
        }
    }

    fn stageSelectedHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }
        var target = switch (self.reviewOperations().selectedHunkStageTarget(ctx.allocator())) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setReviewStatus("hunk stage unavailable for this source", .{});
                return;
            },
            .no_file => {
                self.setReviewStatus("no file selected", .{});
                return;
            },
            .no_path => {
                self.setReviewStatus("hunk stage unavailable for status-only file", .{});
                return;
            },
            .no_hunk => {
                self.setReviewStatus("no hunk selected", .{});
                return;
            },
            .inert_invalid_utf8 => {
                self.setReviewStatus(git_ops.inert_hunk_action_message, .{});
                return;
            },
            .offscreen_cursor => {
                self.setReviewStatus("cursor is offscreen; move cursor first", .{});
                return;
            },
            .stale_status => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setReviewStatus("source is stale; press r to reload", .{});
                return;
            },
            .conflict_unsupported => {
                self.setReviewStatus("conflict hunk stage is not supported yet", .{});
                return;
            },
            .binary_unsupported => {
                self.setReviewStatus("binary hunk stage is not supported", .{});
                return;
            },
            .unsupported_file_state => {
                self.setReviewStatus("hunk stage supports modified files only", .{});
                return;
            },
            .already_staged_hunk => {
                self.setReviewStatus("hunk already staged", .{});
                return;
            },
            .patch_failed => {
                self.setReviewStatus("could not build hunk patch", .{});
                return;
            },
        };

        var proposal = try self.reviewOperations().ownStageHunkProposal(ctx.allocator(), &target);
        defer proposal.deinit(ctx.allocator());
        const owned = &proposal.stage_hunk;
        const root_identity = self.repoSessionView().activeIdentity() orelse {
            self.setReviewStatus("hunk stage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.reviewNavigation().prepareActionCursor(
            ctx.allocator(),
            self.repoSessionView().epoch(),
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
        owned.patch = &.{};
        const pending = app_git_requests.startStageHunk(Msg, ctx, &self.actions, &task_target) catch |err| {
            self.setReviewStatus("could not start hunk stage task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);
        self.reviewNavigation().installActionCursor(ctx.allocator(), &cursor, pending.generation);
        cursor_owned = false;
        self.setReviewStatus("staging hunk: {s}", .{owned.path});
    }

    fn toggleSelectedHunkStage(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        switch (self.reviewOperations().selectedHunkToggleOperation()) {
            .operation => |operation| switch (operation) {
                .stage => try self.stageSelectedHunk(ctx),
                .unstage => try self.unstageSelectedHunk(ctx),
            },
            .unavailable_source, .no_repo => self.setReviewStatus("hunk stage toggle unavailable for this source", .{}),
            .no_file => self.setReviewStatus("no file selected", .{}),
            .no_path => self.setReviewStatus("hunk stage toggle unavailable for status-only file", .{}),
            .no_hunk => self.setReviewStatus("no hunk selected", .{}),
            .inert_invalid_utf8 => self.setReviewStatus(git_ops.inert_hunk_action_message, .{}),
            .offscreen_cursor => self.setReviewStatus("cursor is offscreen; move cursor first", .{}),
            .stale_status => self.setReviewStatus("status is still loading", .{}),
            .stale_source => self.setReviewStatus("source is stale; press r to reload", .{}),
        }
    }

    fn unstageSelectedHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }
        var target = switch (self.reviewOperations().selectedHunkUnstageTarget(ctx.allocator())) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setReviewStatus("hunk unstage unavailable for this source", .{});
                return;
            },
            .no_file => {
                self.setReviewStatus("no file selected", .{});
                return;
            },
            .no_path => {
                self.setReviewStatus("hunk unstage unavailable for status-only file", .{});
                return;
            },
            .no_hunk => {
                self.setReviewStatus("no hunk selected", .{});
                return;
            },
            .inert_invalid_utf8 => {
                self.setReviewStatus(git_ops.inert_hunk_action_message, .{});
                return;
            },
            .offscreen_cursor => {
                self.setReviewStatus("cursor is offscreen; move cursor first", .{});
                return;
            },
            .not_staged_hunk => {
                self.setReviewStatus("hunk is not staged", .{});
                return;
            },
            .binary_unsupported => {
                self.setReviewStatus("binary hunk unstage is not supported", .{});
                return;
            },
            .unsupported_file_state => {
                self.setReviewStatus("hunk unstage supports modified files only", .{});
                return;
            },
            .patch_failed => {
                self.setReviewStatus("could not build hunk patch", .{});
                return;
            },
            .stale_status => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setReviewStatus("source is stale; press r to reload", .{});
                return;
            },
        };

        var proposal = try self.reviewOperations().ownUnstageHunkProposal(ctx.allocator(), &target);
        defer proposal.deinit(ctx.allocator());
        const owned = &proposal.unstage_hunk;
        const root_identity = self.repoSessionView().activeIdentity() orelse {
            self.setReviewStatus("hunk unstage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.reviewNavigation().prepareActionCursor(
            ctx.allocator(),
            self.repoSessionView().epoch(),
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
        owned.patch = &.{};
        const pending = app_git_requests.startUnstageHunk(Msg, ctx, &self.actions, &task_target) catch |err| {
            self.setReviewStatus("could not start hunk unstage task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);
        self.reviewNavigation().installActionCursor(ctx.allocator(), &cursor, pending.generation);
        cursor_owned = false;
        self.setReviewStatus("unstaging hunk: {s}", .{owned.path});
    }

    fn unstageSelectedFile(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }
        const target = switch (self.reviewOperations().unstageTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setReviewStatus("unstage unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setReviewStatus("no file selected", .{});
                return;
            },
            .stale_status => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setReviewStatus("source is stale; press r to reload", .{});
                return;
            },
            .conflict_unsupported => |target_path| {
                if (target_path.kind == .directory or target_path.kind == .repository) {
                    self.setReviewStatus("conflict under selection: {s}", .{target_path.path});
                } else {
                    self.setReviewStatus("conflict unstage is not supported yet", .{});
                }
                return;
            },
            .no_staged_content => |target_path| {
                if (target_path.kind == .directory or target_path.kind == .repository) {
                    self.setReviewStatus("no staged files under: {s}", .{target_path.path});
                } else {
                    self.setReviewStatus("no staged content selected", .{});
                }
                return;
            },
        };

        var proposal = try self.reviewOperations().ownUnstageFileProposal(ctx.allocator(), target);
        defer proposal.deinit(ctx.allocator());
        const owned = proposal.unstage_file;
        const root_identity = self.repoSessionView().activeIdentity() orelse {
            self.setReviewStatus("unstage unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.reviewNavigation().prepareActionCursor(
            ctx.allocator(),
            self.repoSessionView().epoch(),
            root_identity,
            reviewActionCursorKind(owned.kind),
            owned.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());

        const pending = app_git_requests.startUnstageFile(Msg, ctx, &self.actions, .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .kind = owned.kind,
            .label = owned.label,
        }) catch |err| {
            self.setReviewStatus("could not start unstage task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);
        self.reviewNavigation().installActionCursor(ctx.allocator(), &cursor, pending.generation);
        cursor_owned = false;
        self.setReviewStatus("unstaging: {s}", .{owned.label});
    }

    fn requestDiscardSelectedFile(self: *App, allocator: std.mem.Allocator) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.reviewOperations().discardTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setReviewStatus("discard unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setReviewStatus("no file selected", .{});
                return;
            },
            .stale_status => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .stale_source => {
                self.setReviewStatus("source is stale; press r to reload", .{});
                return;
            },
            .directory_unsupported => {
                self.setReviewStatus("directory discard is not supported yet", .{});
                return;
            },
            .conflict_unsupported => {
                self.setReviewStatus("conflict discard is not supported yet", .{});
                return;
            },
            .untracked_unsupported => {
                self.setReviewStatus("untracked discard is not supported yet", .{});
                return;
            },
            .no_unstaged_content => {
                self.setReviewStatus("no unstaged changes selected", .{});
                return;
            },
        };

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        var proposal = try self.reviewOperations().ownDiscardProposal(allocator, target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(allocator);
        const owned = proposal.discard;
        self.discard_confirmation = .{ .repo_root = owned.repo_root, .path = owned.path };
        proposal_consumed = true;
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openDiscardFile();
    }

    fn confirmDiscardFile(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const confirmation = self.discard_confirmation orelse return;
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const root_identity = self.repoSessionView().activeIdentity() orelse {
            self.setReviewStatus("discard unavailable: repository identity changed", .{});
            return;
        };
        var cursor = try self.reviewNavigation().prepareActionCursor(
            ctx.allocator(),
            self.repoSessionView().epoch(),
            root_identity,
            .file,
            confirmation.path,
        );
        var cursor_owned = true;
        defer if (cursor_owned) cursor.deinit(ctx.allocator());

        const pending = app_git_requests.startDiscardFile(Msg, ctx, &self.actions, confirmation.repo_root, confirmation.path) catch |err| {
            self.setReviewStatus("could not start discard task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);
        self.reviewNavigation().installActionCursor(ctx.allocator(), &cursor, pending.generation);
        cursor_owned = false;

        self.setReviewStatus("discarding: {s}", .{confirmation.path});
        self.cancelDiscardConfirmation(ctx.allocator());
    }

    fn cancelDiscardConfirmation(self: *App, allocator: std.mem.Allocator) void {
        if (self.discard_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.discard_confirmation = null;
        if (self.overlay.isDiscardFile()) self.overlay.close();
    }

    fn enterCommitPanelMode(self: *App, mode: app_commit_panel.Mode) void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("finish current git action before committing", .{});
            return;
        }
        if (!self.reviewOperations().canOpenCommitPanel()) {
            self.setReviewStatus("commit unavailable for this source", .{});
            return;
        }

        self.cancelDiscardConfirmation(self.allocator.?);
        self.cancelAmendConfirmation(self.allocator.?);
        self.cancelPushConfirmation(self.allocator.?);
        self.cancelPullConfirmation(self.allocator.?);
        self.overlay.close();
        self.reviewNavigation().clearDiffSelection();
        self.commit_panel.open(mode);
    }

    fn closeCommitPanel(self: *App) void {
        if (self.actions.pending) |pending| {
            if (pending.token.kind == .assist_commit_message) self.actions.clear();
        }
        self.commit_panel.close();
    }

    fn submitCommitPanel(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.commit_panel.commit_error = .action_pending;
            self.setReviewStatus("finish current git action before committing", .{});
            return;
        }

        if (self.commit_panel.validateSubmit(self.stagedSummaryForActiveRepo())) |err| {
            self.commit_panel.commit_error = err;
            return;
        }

        const repo_root = self.repoSessionView().activeRoot() orelse {
            self.commit_panel.commit_error = .status_unavailable;
            self.setReviewStatus("commit unavailable for this source", .{});
            return;
        };

        if (self.commit_panel.mode == .amend) {
            try self.openAmendConfirmation(ctx.allocator(), repo_root);
            return;
        }

        try self.startCommitTask(ctx, repo_root);
    }

    fn assistCommitMessage(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.commit_panel.commit_error = .action_pending;
            self.setReviewStatus("finish current git action before assisting commit message", .{});
            return;
        }
        if (!self.commit_panel.is_open or self.commit_panel.mode != .commit) {
            self.setReviewStatus("commit message assist is only available in commit mode", .{});
            return;
        }
        switch (self.stagedSummaryForActiveRepo()) {
            .ready => |ready| if (ready.count == 0) {
                self.commit_panel.commit_error = .no_staged_changes;
                return;
            },
            .loading_or_stale => {
                self.commit_panel.commit_error = .status_loading;
                return;
            },
            .unavailable => {
                self.commit_panel.commit_error = .status_unavailable;
                return;
            },
        }

        const repo_root = self.repoSessionView().activeRoot() orelse {
            self.commit_panel.commit_error = .status_unavailable;
            return;
        };

        const draft_empty = self.commit_panel.draftIsEmpty();
        const action = if (draft_empty)
            self.resolveGenerateCommitMessageAction() catch |err| {
                self.setReviewStatus("{s}", .{commitMessageActionResolveMessage(.generate, err)});
                return;
            }
        else
            self.resolveImproveCommitMessageAction() catch |err| {
                self.setReviewStatus("{s}", .{commitMessageActionResolveMessage(.improve, err)});
                return;
            };

        const mode = if (draft_empty)
            app_actions.CommitMessageAssistMode.generate
        else
            app_actions.CommitMessageAssistMode{ .improve = self.buildDraftSnapshot(ctx.allocator()) catch |err| {
                self.commit_panel.commit_error = .input_allocation_failed;
                self.setReviewStatus("could not snapshot commit message draft: {s}", .{@errorName(err)});
                return err;
            } };

        var request = self.buildCommitMessageAssistRequest(ctx.allocator(), repo_root, action, mode) catch |err| {
            self.commit_panel.commit_error = .input_allocation_failed;
            self.setReviewStatus("could not prepare commit message action: {s}", .{@errorName(err)});
            return err;
        };

        const pending = app_git_requests.startCommitMessageAssist(Msg, ctx, &self.actions, &request) catch |err| {
            self.commit_panel.commit_error = .assist_failed;
            self.setReviewStatus("could not start commit message action", .{});
            return err;
        };
        self.acceptActionLaunch(pending);

        if (draft_empty) {
            self.setReviewStatus("generating commit message...", .{});
        } else {
            self.setReviewStatus("improving commit message...", .{});
        }
    }

    const CommitMessageActionResolveError = error{
        Missing,
        Multiple,
    };

    fn resolveGenerateCommitMessageAction(self: *const App) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        var found: ?config_mod.ExternalActionConfig = null;
        for (self.user_config.actions.slice()) |action| {
            if (action.stdin == .staged_diff) {
                if (found != null) return error.Multiple;
                found = action;
            }
        }
        return found orelse error.Missing;
    }

    fn resolveImproveCommitMessageAction(self: *const App) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        var found: ?config_mod.ExternalActionConfig = null;
        for (self.user_config.actions.slice()) |action| {
            if (action.stdin == .commit_message_context) {
                if (found != null) return error.Multiple;
                found = action;
            }
        }
        return found orelse error.Missing;
    }

    const CommitMessageAssistResolveMode = enum { generate, improve };

    fn commitMessageActionResolveMessage(mode: CommitMessageAssistResolveMode, err: CommitMessageActionResolveError) []const u8 {
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

    fn buildDraftSnapshot(self: *const App, allocator: std.mem.Allocator) !app_actions.DraftSnapshot {
        var parts = try self.commit_panel.formatMessageParts(allocator);
        errdefer parts.deinit(allocator);
        const body = if (parts.body) |body_text| body_text else try allocator.dupe(u8, "");
        parts.body = null;
        return .{
            .subject = parts.subject,
            .body = body,
        };
    }

    fn buildCommitMessageAssistRequest(
        self: *const App,
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
        errdefer {
            for (argv[0..owned_count]) |arg| allocator.free(arg);
        }
        for (argv_src, 0..) |arg, index| {
            argv[index] = try expandCommitActionArgv(allocator, arg, repo_root);
            owned_count += 1;
        }

        return .{
            .repo_root = owned_root,
            .action_id = owned_id,
            .argv = argv,
            .launch_revision = self.commit_panel.draft_revision,
            .mode = owned_mode,
        };
    }

    fn expandCommitActionArgv(allocator: std.mem.Allocator, template: []const u8, repo_root: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();

        var cursor: usize = 0;
        while (std.mem.indexOfScalarPos(u8, template, cursor, '{')) |open| {
            try out.writer.writeAll(template[cursor..open]);
            const close = std.mem.indexOfScalarPos(u8, template, open + 1, '}') orelse return error.UnknownPlaceholder;
            const placeholder = template[open .. close + 1];
            if (!std.mem.eql(u8, placeholder, "{repo_root}")) return error.UnknownPlaceholder;
            try out.writer.writeAll(repo_root);
            cursor = close + 1;
        }
        if (std.mem.indexOfScalarPos(u8, template, cursor, '}') != null) return error.UnknownPlaceholder;
        try out.writer.writeAll(template[cursor..]);
        return try out.toOwnedSlice();
    }

    fn startCommitTask(self: *App, ctx: *chasen.Ctx(Msg), repo_root: []const u8) !void {
        var parts = self.commit_panel.formatMessageParts(ctx.allocator()) catch {
            self.commit_panel.commit_error = .input_allocation_failed;
            return;
        };
        errdefer parts.deinit(ctx.allocator());

        const owned_root = try ctx.allocator().dupe(u8, repo_root);

        var request: app_git_requests.CommitRequest = .{
            .repo_root = owned_root,
            .subject = parts.subject,
            .body = parts.body,
        };
        parts = .{ .subject = &.{}, .body = null };

        const pending = app_git_requests.startCommit(Msg, ctx, &self.actions, &request) catch |err| {
            self.commit_panel.commit_error = .commit_failed;
            self.setReviewStatus("could not start commit task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);

        self.setReviewStatus("committing...", .{});
    }

    fn openAmendConfirmation(self: *App, allocator: std.mem.Allocator, repo_root: []const u8) !void {
        var parts = self.commit_panel.formatMessageParts(allocator) catch {
            self.commit_panel.commit_error = .input_allocation_failed;
            return;
        };
        errdefer parts.deinit(allocator);

        const owned_root = try allocator.dupe(u8, repo_root);
        errdefer allocator.free(owned_root);

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        self.amend_confirmation = .{
            .repo_root = owned_root,
            .subject = parts.subject,
            .body = parts.body,
        };
        parts = .{ .subject = &.{}, .body = null };
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openAmendCommit();
    }

    fn confirmAmend(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }
        var confirmation = self.amend_confirmation orelse return;
        self.amend_confirmation = null;

        const pending = app_git_requests.startAmend(Msg, ctx, &self.actions, &confirmation) catch |err| {
            if (self.overlay.isAmendCommit()) self.overlay.close();
            self.commit_panel.commit_error = .amend_failed;
            self.setReviewStatus("could not start amend task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);

        self.overlay.close();
        self.setReviewStatus("amending...", .{});
    }

    fn cancelAmendConfirmation(self: *App, allocator: std.mem.Allocator) void {
        if (self.amend_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.amend_confirmation = null;
        if (self.overlay.isAmendCommit()) self.overlay.close();
    }

    fn requestPush(self: *App, allocator: std.mem.Allocator) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.reviewOperations().pushTarget()) {
            .ready => |target| target,
            .unavailable_source => {
                self.setReviewStatus("push unavailable for this source", .{});
                return;
            },
            .no_repo => {
                self.setReviewStatus("push unavailable: no repository", .{});
                return;
            },
            .loading_branch_status => {
                self.setReviewStatus("branch status is still loading", .{});
                return;
            },
            .detached_head => {
                self.setReviewStatus("push unavailable on detached HEAD", .{});
                return;
            },
            .branch_unavailable => {
                self.setReviewStatus("push unavailable: branch is unknown", .{});
                return;
            },
            .no_upstream => {
                self.setReviewStatus("push unavailable: no upstream branch", .{});
                return;
            },
            .upstream_not_remote_branch => {
                self.setReviewStatus("push unavailable: unsupported upstream", .{});
                return;
            },
            .branch_status_unavailable => {
                self.setReviewStatus("push unavailable: branch status is incomplete", .{});
                return;
            },
            .pull_first => {
                self.setReviewStatus("push blocked: pull/rebase remote changes first", .{});
                return;
            },
            .nothing_to_push => {
                self.setReviewStatus("nothing to push", .{});
                return;
            },
        };

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        self.clearPushError(allocator);

        var proposal = try self.reviewOperations().ownPushProposal(allocator, target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(allocator);
        const owned = proposal.push;
        self.push_confirmation = .{
            .mode = owned.mode,
            .repo_root = owned.repo_root,
            .branch = owned.branch,
            .remote = owned.remote,
            .remote_branch = owned.remote_branch,
            .oid = owned.oid,
            .ahead_behind = owned.ahead_behind,
        };
        proposal_consumed = true;
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openPushBranch();
    }

    fn confirmPush(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        var confirmation = self.push_confirmation orelse return;
        self.push_confirmation = null;

        self.setReviewStatus("pushing: {s} -> {s}/{s}", .{ confirmation.branch, confirmation.remote, confirmation.remote_branch });

        const pending = app_git_requests.startPush(Msg, ctx, &self.actions, self.env_map, &confirmation) catch |err| {
            self.setReviewStatus("could not start push task", .{});
            if (self.overlay.isPushBranch()) self.overlay.close();
            return err;
        };
        self.acceptActionLaunch(pending);

        self.overlay.close();
    }

    fn cancelPushConfirmation(self: *App, allocator: std.mem.Allocator) void {
        if (self.push_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.push_confirmation = null;
        if (self.overlay.isPushBranch()) self.overlay.close();
    }

    fn requestPull(self: *App, allocator: std.mem.Allocator) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.reviewOperations().pullTarget()) {
            .ready => |target| target,
            .unavailable_source => {
                self.setReviewStatus("pull unavailable for this source", .{});
                return;
            },
            .no_repo => {
                self.setReviewStatus("pull unavailable: no repository", .{});
                return;
            },
            .loading_branch_status => {
                self.setReviewStatus("branch status is still loading", .{});
                return;
            },
            .detached_head => {
                self.setReviewStatus("pull unavailable on detached HEAD", .{});
                return;
            },
            .branch_unavailable => {
                self.setReviewStatus("pull unavailable: branch is unknown", .{});
                return;
            },
            .no_upstream => {
                self.setReviewStatus("pull unavailable: no upstream branch", .{});
                return;
            },
            .upstream_not_remote_branch => {
                self.setReviewStatus("pull unavailable: unsupported upstream", .{});
                return;
            },
            .branch_status_unavailable => {
                self.setReviewStatus("pull unavailable: branch status is incomplete", .{});
                return;
            },
            .status_loading => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .status_stale => {
                self.setReviewStatus("pull unavailable: status is stale", .{});
                return;
            },
            .dirty_worktree => {
                self.setReviewStatus("pull blocked: commit, stage, or discard local changes first", .{});
                return;
            },
            .untracked_files_present => {
                self.setReviewStatus("pull blocked: untracked files present", .{});
                return;
            },
        };

        self.cancelDiscardConfirmation(allocator);
        self.cancelAmendConfirmation(allocator);
        self.cancelPushConfirmation(allocator);
        self.cancelPullConfirmation(allocator);
        self.clearPushError(allocator);

        var proposal = try self.reviewOperations().ownPullProposal(allocator, target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(allocator);
        const owned = proposal.pull;
        self.pull_confirmation = .{
            .repo_root = owned.repo_root,
            .branch = owned.branch,
            .remote = owned.remote,
            .remote_branch = owned.remote_branch,
            .oid = owned.oid,
            .ahead = owned.ahead,
            .behind = owned.behind,
        };
        proposal_consumed = true;
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openPullBranch();
    }

    fn confirmPull(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        var confirmation = self.pull_confirmation orelse return;
        self.pull_confirmation = null;

        self.setReviewStatus("pulling: {s} <- {s}/{s}", .{ confirmation.branch, confirmation.remote, confirmation.remote_branch });

        const pending = app_git_requests.startPull(Msg, ctx, &self.actions, self.env_map, &confirmation) catch |err| {
            self.setReviewStatus("could not start pull task", .{});
            if (self.overlay.isPullBranch()) self.overlay.close();
            return err;
        };
        self.acceptActionLaunch(pending);

        self.overlay.close();
    }

    fn cancelPullConfirmation(self: *App, allocator: std.mem.Allocator) void {
        if (self.pull_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.pull_confirmation = null;
        if (self.overlay.isPullBranch()) self.overlay.close();
    }

    fn requestFetch(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.reviewOperations().fetchTarget()) {
            .ready => |target| target,
            .unavailable_source => {
                self.setReviewStatus("fetch unavailable for this source", .{});
                return;
            },
            .no_repo => {
                self.setReviewStatus("fetch unavailable: no repository", .{});
                return;
            },
            .loading_branch_status => {
                self.setReviewStatus("branch status is still loading", .{});
                return;
            },
            .detached_head => {
                self.setReviewStatus("fetch unavailable on detached HEAD", .{});
                return;
            },
            .branch_unavailable => {
                self.setReviewStatus("fetch unavailable: branch is unknown", .{});
                return;
            },
            .no_upstream => {
                self.setReviewStatus("fetch unavailable: no upstream remote", .{});
                return;
            },
            .upstream_not_remote => {
                self.setReviewStatus("fetch unavailable: unsupported upstream", .{});
                return;
            },
        };

        var proposal = try self.reviewOperations().ownFetchProposal(ctx.allocator(), target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(ctx.allocator());
        const owned = proposal.fetch;
        var request: app_git_requests.FetchRequest = .{
            .repo_root = owned.repo_root,
            .remote = owned.remote,
        };
        proposal_consumed = true;

        self.setReviewStatus("fetching: {s}", .{target.remote});
        const pending = app_git_requests.startFetch(Msg, ctx, &self.actions, self.env_map, &request) catch |err| {
            self.setReviewStatus("could not start fetch task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);
    }

    fn requestBranchSwitch(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const target = switch (self.reviewOperations().branchSwitchTarget()) {
            .ready => |target| target,
            .unavailable_source => {
                self.setReviewStatus("branch switch unavailable for this source", .{});
                return;
            },
            .no_repo => {
                self.setReviewStatus("branch switch unavailable: no repository", .{});
                return;
            },
            .loading_branch_status => {
                self.setReviewStatus("branch status is still loading", .{});
                return;
            },
            .detached_head => {
                self.setReviewStatus("branch switch unavailable on detached HEAD", .{});
                return;
            },
            .branch_unavailable => {
                self.setReviewStatus("branch switch unavailable: branch is unknown", .{});
                return;
            },
            .branch_status_unavailable => {
                self.setReviewStatus("branch switch unavailable: branch status is incomplete", .{});
                return;
            },
            .status_loading => {
                self.setReviewStatus("status is still loading", .{});
                return;
            },
            .status_stale => {
                self.setReviewStatus("branch switch unavailable: status is stale", .{});
                return;
            },
            .dirty_worktree => {
                self.setReviewStatus("branch switch blocked: commit, stage, or discard local changes first", .{});
                return;
            },
            .untracked_files_present => {
                self.setReviewStatus("branch switch blocked: untracked files present", .{});
                return;
            },
        };

        self.cancelDiscardConfirmation(ctx.allocator());
        self.cancelAmendConfirmation(ctx.allocator());
        self.cancelPushConfirmation(ctx.allocator());
        self.cancelPullConfirmation(ctx.allocator());
        self.clearPushError(ctx.allocator());
        self.clearBranchSwitch(ctx.allocator());

        self.branch_switch_load_generation +%= 1;
        const generation = self.branch_switch_load_generation;

        var proposal = try self.reviewOperations().ownBranchSwitchProposal(ctx.allocator(), target);
        var proposal_consumed = false;
        defer if (!proposal_consumed) proposal.deinit(ctx.allocator());
        const owned = proposal.switch_branch;
        self.branch_switch = .{
            .repo_root = owned.repo_root,
            .current_branch = owned.branch,
            .current_oid = owned.oid,
            .generation = generation,
            .loading = true,
        };
        proposal_consumed = true;
        self.branch_switch_load_pending = generation;
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openSwitchBranch();
        errdefer self.clearBranchSwitch(ctx.allocator());

        const task = try ctx.allocator().create(BranchListLoadTask);
        task.* = .{
            .origin = .review,
            .repo_epoch = self.repoSessionView().epoch(),
            .activation_id = self.pages.review.activation.next_activation_id,
            .repo_root = &.{},
            .generation = generation,
        };
        errdefer task.destroy(ctx.allocator());
        task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        try ctx.task().spawnWith(.{ .ctx = task, .run = BranchListLoadTask.run, .failed = BranchListLoadTask.failed });
    }

    fn moveBranchSwitchSelection(self: *App, delta: isize) void {
        if (!self.branch_switch.hasState() or self.branch_switch.loading or self.branch_switch.branches.len == 0) return;
        self.branch_switch.selected_index = wrapIndex(self.branch_switch.selected_index, self.branch_switch.branches.len, delta);
    }

    fn confirmBranchSwitch(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (!self.branch_switch.hasState()) return;
        if (self.branch_switch.loading) {
            self.setReviewStatus("branch list is still loading", .{});
            return;
        }
        if (self.branch_switch.branches.len == 0) {
            self.setReviewStatus("branch switch unavailable: no local branches", .{});
            return;
        }
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        const selected = self.branch_switch.branches[self.branch_switch.selected_index];
        if (selected.current or std.mem.eql(u8, selected.name, self.branch_switch.current_branch)) {
            self.setReviewStatus("already on branch: {s}", .{self.branch_switch.current_branch});
            self.clearBranchSwitch(ctx.allocator());
            return;
        }

        var request: app_git_requests.SwitchBranchRequest = .{
            .repo_root = &.{},
            .expected_branch = &.{},
            .expected_oid = &.{},
            .target_branch = &.{},
            .target_oid = &.{},
        };
        errdefer request.deinit(ctx.allocator());
        request.repo_root = try ctx.allocator().dupe(u8, self.branch_switch.repo_root);
        request.expected_branch = try ctx.allocator().dupe(u8, self.branch_switch.current_branch);
        request.expected_oid = try ctx.allocator().dupe(u8, self.branch_switch.current_oid);
        request.target_branch = try ctx.allocator().dupe(u8, selected.name);
        request.target_oid = try ctx.allocator().dupe(u8, selected.oid);

        self.setReviewStatus("switching branch: {s} -> {s}", .{ self.branch_switch.current_branch, selected.name });
        const pending = app_git_requests.startSwitchBranch(Msg, ctx, &self.actions, &request) catch |err| {
            self.setReviewStatus("could not start branch switch task", .{});
            return err;
        };
        self.acceptActionLaunch(pending);

        self.clearBranchSwitch(ctx.allocator());
    }

    fn setPushError(self: *App, allocator: std.mem.Allocator, message: []const u8) !void {
        try self.setPushErrorWithRetry(allocator, message, null, false);
    }

    fn setPushErrorWithRetry(self: *App, allocator: std.mem.Allocator, message: []const u8, retry_target: ?app_state.PushRetryTarget, credentials_available: bool) !void {
        self.clearPushError(allocator);
        self.push_error_message = try allocator.dupe(u8, message);
        if (retry_target) |target| {
            self.push_retry.state = .{ .available = .{
                .target = target,
                .credentials_available = credentials_available,
            } };
        }
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openPushError();
    }

    fn clearPushError(self: *App, allocator: std.mem.Allocator) void {
        self.clearPushErrorPresentation(allocator);
        self.push_retry.state.deinit(allocator);
    }

    fn clearPushErrorPresentation(self: *App, allocator: std.mem.Allocator) void {
        if (self.push_error_message) |message| allocator.free(message);
        self.push_error_message = null;
        if (self.overlay.isPushError()) self.overlay.close();
    }

    fn clearBranchSwitch(self: *App, allocator: std.mem.Allocator) void {
        if (self.branch_switch.hasState()) self.branch_switch.deinit(allocator);
        self.branch_switch_load_pending = null;
        if (self.overlay.isSwitchBranch()) self.overlay.close();
    }

    fn restorePushRetryTarget(self: *App, allocator: std.mem.Allocator, target: app_state.PushRetryTarget, credentials_available: bool) void {
        self.push_retry.restoreAvailable(allocator, target, credentials_available);
        self.reviewNavigation().clearDiffSelection();
        self.overlay.openPushError();
    }

    fn clearPushForeground(self: *App, allocator: std.mem.Allocator) void {
        if (self.push_retry.state == .foreground) self.push_retry.state.deinit(allocator);
    }

    fn startPushInspection(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        kind: app_push_retry.InspectionKind,
        unavailable_message: []const u8,
    ) !void {
        if (self.push_retry.state == .inspecting) {
            self.setReviewStatus("push retry inspection already running", .{});
            return;
        }
        var started = self.push_retry.beginInspection(kind, self.reviewPageEffectOrigin()) orelse {
            self.setReviewStatus("{s}", .{unavailable_message});
            return;
        };

        app_push_retry.startInspection(
            Msg,
            ctx,
            started.metadata,
            &started.target,
            started.credentials_available,
        ) catch |err| {
            self.restorePushRetryTarget(ctx.allocator(), started.target.take(), started.credentials_available);
            self.setReviewStatus("could not start push retry inspection", .{});
            return err;
        };
        switch (kind) {
            .verify_snapshot => self.setReviewStatus("checking push retry target...", .{}),
            .lookup_remote => self.setReviewStatus("reading push remote URL...", .{}),
        }
    }

    fn finishPushInspection(self: *App, ctx: *chasen.Ctx(Msg), finished: app_push_retry.Finished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const inspecting = switch (self.push_retry.state) {
            .inspecting => |inspecting| inspecting,
            else => return,
        };
        if (!inspecting.accepts(result)) return;
        self.push_retry.state = .idle;

        // Repository supersession invalidates an otherwise matching task. The
        // returned target remains result-owned and is released by the defer.
        if (result.repo_epoch != self.repoSessionView().epoch()) return;

        const diagnostic_origin: EffectOrigin = .{ .page = result.origin };
        // A matching inactive Review instance may retain its diagnostic, but a
        // later activation is a distinct semantic owner. Direct/future routes
        // must not open a prompt or foreground process in that newer instance.
        if (!self.effectOriginIsLive(diagnostic_origin)) {
            self.clearPushErrorPresentation(ctx.allocator());
            return;
        }
        switch (result.outcome) {
            .snapshot_valid => {
                if (result.kind != .verify_snapshot) {
                    self.restorePushRetryTarget(ctx.allocator(), result.target.take(), result.credentials_available);
                    self.setEffectStatus(diagnostic_origin, "push retry inspection returned an invalid result", .{});
                } else {
                    try self.startInteractivePushAfterInspection(ctx, result.origin, result.target.take(), result.credentials_available);
                }
            },
            .snapshot_changed => {
                self.restorePushRetryTarget(ctx.allocator(), result.target.take(), result.credentials_available);
                self.setEffectStatus(diagnostic_origin, "push retry unavailable: branch changed; reload and try again", .{});
            },
            .remote_ready => {
                if (result.kind != .lookup_remote or result.target.remote_url == null) {
                    self.restorePushRetryTarget(ctx.allocator(), result.target.take(), result.credentials_available);
                    self.setEffectStatus(diagnostic_origin, "push retry inspection returned an invalid remote", .{});
                } else {
                    const prompt = ctx.allocator().create(app_state.PushCredentialPrompt) catch |err| {
                        self.restorePushRetryTarget(ctx.allocator(), result.target.take(), result.credentials_available);
                        self.setEffectStatus(diagnostic_origin, "could not open push credential prompt", .{});
                        return err;
                    };
                    prompt.* = .{ .target = result.target.take() };
                    self.push_retry.state = .{ .credential_prompt = prompt };
                    self.clearPushErrorPresentation(ctx.allocator());
                    self.reviewNavigation().clearDiffSelection();
                    self.overlay.openPushCredentials();
                }
            },
            .remote_not_https => {
                self.restorePushRetryTarget(ctx.allocator(), result.target.take(), result.credentials_available);
                self.setEffectStatus(diagnostic_origin, "credential prompt is only available for HTTPS remotes", .{});
            },
            .inspection_failed => |message| {
                self.restorePushRetryTarget(ctx.allocator(), result.target.take(), result.credentials_available);
                self.setEffectStatus(diagnostic_origin, "{s}", .{message});
            },
        }
        if (self.active_page != result.origin.page_id) self.redraw_plan.requestSkip();
    }

    fn startInteractivePushAfterInspection(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        origin: PageEffectOrigin,
        owned_target: app_state.PushRetryTarget,
        credentials_available: bool,
    ) !void {
        var target = owned_target;
        errdefer target.deinit(ctx.allocator());

        if (app_git_requests.hasPendingAction(self.actions)) {
            self.restorePushRetryTarget(ctx.allocator(), target.take(), credentials_available);
            self.setEffectStatus(.{ .page = origin }, "another git action is running", .{});
            return;
        }

        // Use the snapshotted commit as the refspec source. A branch-name
        // source can be resolved by Git after a prompt and would weaken the
        // inspection guarantee.
        const refspec = std.fmt.allocPrint(ctx.allocator(), "{s}:refs/heads/{s}", .{ target.oid, target.remote_branch }) catch |err| {
            self.restorePushRetryTarget(ctx.allocator(), target.take(), credentials_available);
            return err;
        };
        defer ctx.allocator().free(refspec);

        const argv = [_][]const u8{ "git", "push", target.remote, refspec };
        const pending = self.actions.begin(.push);
        const request_id = ctx.terminal().runForegroundCommand(.{
            .argv = &argv,
            .cwd = target.repo_root,
            .finished = Msg.pushForegroundFinished,
        }) catch |err| {
            _ = self.actions.cancelPreparing(pending);
            self.restorePushRetryTarget(ctx.allocator(), target.take(), credentials_available);
            switch (err) {
                error.ForegroundCommandLimitExceeded => self.setEffectStatus(.{ .page = origin }, "interactive push already queued", .{}),
                error.ForegroundCommandEmptyArgv => self.setEffectStatus(.{ .page = origin }, "interactive push command is empty", .{}),
                error.OutOfMemory => return err,
            }
            return;
        };
        self.acceptActionLaunch(pending);

        self.push_retry.state = .{ .foreground = .{
            .request_id = request_id,
            .pending = pending,
            .origin = origin,
            .target = target.take(),
        } };
        const foreground = &self.push_retry.state.foreground;
        self.clearPushErrorPresentation(ctx.allocator());
        self.setEffectStatus(.{ .page = origin }, "running interactive push: {s} -> {s}/{s}", .{ foreground.target.branch, foreground.target.remote, foreground.target.remote_branch });
    }

    fn runInteractivePush(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }
        try self.startPushInspection(ctx, .verify_snapshot, "interactive push retry is not available for this failure");
    }

    fn openPushCredentialPrompt(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (!self.push_retry.state.credentialsAvailable()) {
            self.setReviewStatus("credential retry is not available for this push failure", .{});
            return;
        }
        try self.startPushInspection(ctx, .lookup_remote, "credential retry target is no longer available");
    }

    fn cancelPushCredentialPrompt(self: *App, allocator: std.mem.Allocator) void {
        if (self.push_retry.state == .credential_prompt) self.push_retry.state.deinit(allocator);
        if (self.overlay.isPushCredentials()) self.overlay.close();
    }

    fn mutablePushCredentialPrompt(self: *App) ?*app_state.PushCredentialPrompt {
        return switch (self.push_retry.state) {
            .credential_prompt => |prompt| prompt,
            else => null,
        };
    }

    fn activePushCredentialInput(self: *App) ?*app_state.SecretInput {
        const prompt = self.mutablePushCredentialPrompt() orelse return null;
        return switch (prompt.active_field) {
            .username => &prompt.username,
            .password => &prompt.password,
        };
    }

    fn togglePushCredentialField(self: *App) void {
        const prompt = self.mutablePushCredentialPrompt() orelse return;
        prompt.active_field = switch (prompt.active_field) {
            .username => .password,
            .password => .username,
        };
    }

    fn insertPushCredential(self: *App, codepoint: u21) void {
        const input = self.activePushCredentialInput() orelse return;
        input.insert(codepoint) catch {
            self.setReviewStatus("credential field is too long", .{});
        };
    }

    fn pastePushCredential(self: *App, text: []const u8) void {
        const input = self.activePushCredentialInput() orelse return;
        input.insertSlice(text) catch {
            self.setReviewStatus("credential field is too long", .{});
        };
    }

    fn backspacePushCredential(self: *App) void {
        const input = self.activePushCredentialInput() orelse return;
        input.backspace();
    }

    fn movePushCredentialLeft(self: *App) void {
        const input = self.activePushCredentialInput() orelse return;
        input.moveLeft();
    }

    fn movePushCredentialRight(self: *App) void {
        const input = self.activePushCredentialInput() orelse return;
        input.moveRight();
    }

    fn submitPushCredentials(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const prompt = self.mutablePushCredentialPrompt() orelse return;
        if (prompt.active_field == .username) {
            prompt.active_field = .password;
            return;
        }
        if (prompt.username.len == 0) {
            self.setReviewStatus("Username is required", .{});
            prompt.active_field = .username;
            return;
        }
        if (prompt.password.len == 0) {
            self.setReviewStatus("Password or token is required", .{});
            prompt.active_field = .password;
            return;
        }
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("another git action is running", .{});
            return;
        }

        var username = try ctx.allocator().dupe(u8, prompt.username.secret());
        errdefer app_actions.secureFree(ctx.allocator(), username);
        var password = try ctx.allocator().dupe(u8, prompt.password.secret());
        errdefer app_actions.secureFree(ctx.allocator(), password);
        var credentials: app_actions.PushCredentials = .{
            .username = username,
            .password = password,
        };
        // Ownership moves into `credentials`; clear the local slices so their
        // errdefer cleanup cannot wipe/free the same buffers after the task
        // launcher has consumed them.
        username = &.{};
        password = &.{};

        var target = prompt.target.take();
        self.setReviewStatus("retrying push with credentials: {s} -> {s}/{s}", .{ target.branch, target.remote, target.remote_branch });
        self.cancelPushCredentialPrompt(ctx.allocator());

        const pending = app_git_requests.startCredentialedPush(Msg, ctx, &self.actions, self.env_map, &target, &credentials) catch |err| {
            target.deinit(ctx.allocator());
            return err;
        };
        self.acceptActionLaunch(pending);
    }

    fn stagedSummaryForActiveRepo(self: *const App) app_commit_panel.StagedSummary {
        return switch (self.reviewOperations().commitSummary()) {
            .unavailable => .unavailable,
            .loading_or_stale => .loading_or_stale,
            .ready => |ready| .{ .ready = .{ .count = ready.count } },
        };
    }

    fn finishStageFile(self: *App, ctx: *chasen.Ctx(Msg), finished: StageFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        if (self.setActionFailureStatus("stage", result.result)) {
            _ = self.reviewActionFence().clearMatchingActionCursor(ctx.allocator(), result.pending.generation);
            return;
        }

        self.setReviewStatus("staged: {s}", .{result.path});
        const applied = self.reviewOperationController().applyAcceptedOutcome(
            ctx.allocator(),
            .stage_file,
            active_matches,
        );
        try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
    }

    fn finishStageHunk(self: *App, ctx: *chasen.Ctx(Msg), finished: StageHunkFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        if (self.setActionFailureStatus("hunk stage", result.result)) {
            _ = self.reviewActionFence().clearMatchingActionCursor(ctx.allocator(), result.pending.generation);
            return;
        }

        const applied = self.reviewOperationController().applyAcceptedOutcome(ctx.allocator(), .{ .stage_hunk = .{
            .repo_root = result.repo_root,
            .path = result.path,
            .hunk_index = result.hunk_index,
            .session_mark_mutation = result.session_mark_mutation,
        } }, active_matches);
        if (applied.local_effect_failure == .staged_hunk_mark_record) {
            self.setReviewStatus("staged hunk {d}: {s}; could not record local staged-hunk mark", .{ result.hunk_index + 1, result.path });
        } else {
            self.setReviewStatus("staged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
        }
        try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
    }

    fn finishUnstageFile(self: *App, ctx: *chasen.Ctx(Msg), finished: UnstageFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        if (self.setActionFailureStatus("unstage", result.result)) {
            _ = self.reviewActionFence().clearMatchingActionCursor(ctx.allocator(), result.pending.generation);
            return;
        }

        self.setReviewStatus("unstaged: {s}", .{result.path});
        const applied = self.reviewOperationController().applyAcceptedOutcome(
            ctx.allocator(),
            .unstage_file,
            active_matches,
        );
        try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
    }

    fn finishUnstageHunk(self: *App, ctx: *chasen.Ctx(Msg), finished: UnstageHunkFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        if (self.setActionFailureStatus("hunk unstage", result.result)) {
            _ = self.reviewActionFence().clearMatchingActionCursor(ctx.allocator(), result.pending.generation);
            return;
        }

        self.setReviewStatus("unstaged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
        const applied = self.reviewOperationController().applyAcceptedOutcome(ctx.allocator(), .{ .unstage_hunk = .{
            .repo_root = result.repo_root,
            .path = result.path,
            .hunk_index = result.hunk_index,
            .session_mark_mutation = result.session_mark_mutation,
            .reload_after_success = result.reload_after_success,
        } }, active_matches);
        try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
    }

    fn finishDiscardFile(self: *App, ctx: *chasen.Ctx(Msg), finished: DiscardFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        if (self.setActionFailureStatus("discard", result.result)) {
            _ = self.reviewActionFence().clearMatchingActionCursor(ctx.allocator(), result.pending.generation);
            return;
        }

        const applied = self.reviewOperationController().applyAcceptedOutcome(ctx.allocator(), .{ .discard_file = .{
            .repo_root = result.repo_root,
            .path = result.path,
        } }, active_matches);
        if (applied.local_effect_failure == .reviewed_mark_clear) {
            self.setReviewStatus("discarded: {s}; could not clear reviewed mark", .{result.path});
            try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
            return;
        }
        self.setReviewStatus("discarded: {s}", .{result.path});
        try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
    }

    fn setActionFailureStatus(self: *App, comptime prefix: []const u8, result: app_actions.FileActionTaskResult) bool {
        switch (result) {
            .ok, .ok_static => return false,
            .failed => |message| self.setReviewStatus(prefix ++ " failed: {s}", .{git_ops.trimGitOutput(message)}),
            .failed_static => |message| self.setReviewStatus(prefix ++ " failed: {s}", .{message}),
        }
        return true;
    }

    fn finishCommit(self: *App, ctx: *chasen.Ctx(Msg), finished: CommitFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        switch (result.result) {
            .ok, .ok_static => {
                const applied = self.reviewOperationController().applyAcceptedOutcome(
                    ctx.allocator(),
                    .{ .commit = .{ .repo_root = result.repo_root } },
                    active_matches,
                );
                self.commit_panel.close();

                if (active_matches) {
                    if (applied.local_effect_failure == .reviewed_mark_clear) {
                        self.setReviewStatus("committed; could not clear reviewed marks", .{});
                    } else {
                        self.setReviewStatus("committed", .{});
                    }
                    try self.reviewRead().applyActionOutcome(ctx, result.pending, active_matches, applied.reload);
                } else {
                    if (applied.local_effect_failure == .reviewed_mark_clear) {
                        self.setReviewStatus("committed: {s}; could not clear reviewed marks", .{result.repo_root});
                    } else {
                        self.setReviewStatus("committed: {s}", .{result.repo_root});
                    }
                }
            },
            .failed, .failed_static => {
                self.commit_panel.commit_error = .commit_failed;
                _ = self.setActionFailureStatus("commit", result.result);
            },
        }
    }

    fn finishCommitMessageAssist(self: *App, ctx: *chasen.Ctx(Msg), finished: CommitMessageAssistFinished) void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.acceptActionTerminal(result.pending)) return;
        if (!self.commit_panel.is_open or self.commit_panel.mode != .commit) return;
        if (!self.repoSessionView().activeRootMatches(result.repo_root)) return;

        switch (result.result) {
            .ok => |message| {
                if (self.commit_panel.draft_revision != result.launch_revision) {
                    switch (result.mode) {
                        .generate => self.setReviewStatus("generated commit message ignored; draft changed", .{}),
                        .improve => self.setReviewStatus("improved commit message ignored; draft changed", .{}),
                    }
                    return;
                }
                self.commit_panel.replaceDraft(message.subject, message.body);
                if (self.commit_panel.commit_error) |_| {
                    self.setReviewStatus("commit message could not be inserted", .{});
                    return;
                }
                switch (result.mode) {
                    .generate => if (message.truncated) {
                        self.setReviewStatus("generated commit message from truncated staged diff", .{});
                    } else {
                        self.setReviewStatus("generated commit message", .{});
                    },
                    .improve => if (message.truncated) {
                        self.setReviewStatus("improved commit message from truncated staged diff", .{});
                    } else {
                        self.setReviewStatus("improved commit message", .{});
                    },
                }
            },
            .failed => |message| {
                self.commit_panel.commit_error = .assist_failed;
                self.setReviewStatus("{s}", .{message});
            },
            .failed_static => |message| {
                self.commit_panel.commit_error = .assist_failed;
                self.setReviewStatus("{s}", .{message});
            },
        }
    }

    fn finishAmend(self: *App, ctx: *chasen.Ctx(Msg), finished: AmendFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        switch (result.result) {
            .ok, .ok_static => {
                const reviewed_clear_failed = if (self.pages.review.reviewed_store.clearForRepo(ctx.allocator(), result.repo_root)) |_| false else |_| true;
                self.commit_panel.close();
                self.cancelAmendConfirmation(ctx.allocator());

                if (active_matches) {
                    if (reviewed_clear_failed) {
                        self.setReviewStatus("amended; could not clear reviewed marks", .{});
                    } else {
                        self.setReviewStatus("amended", .{});
                    }
                    try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
                } else {
                    if (reviewed_clear_failed) {
                        self.setReviewStatus("amended: {s}; could not clear reviewed marks", .{result.repo_root});
                    } else {
                        self.setReviewStatus("amended: {s}", .{result.repo_root});
                    }
                }
            },
            .failed, .failed_static => {
                self.commit_panel.commit_error = .amend_failed;
                _ = self.setActionFailureStatus("amend", result.result);
            },
        }
    }

    fn finishPush(self: *App, ctx: *chasen.Ctx(Msg), finished: PushFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        switch (result.result) {
            .ok, .ok_static => {
                if (active_matches) {
                    self.setReviewStatus("pushed: {s} -> {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                    try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
                } else {
                    self.setReviewStatus("pushed: {s}", .{result.repo_root});
                }
            },
            .failed => |message| {
                const detail = git_ops.trimGitOutput(message);
                const status_message = git_ops.pushFailureHint(detail) orelse detail;
                self.setReviewStatus("push failed: {s}", .{status_message});
                const retry_target = try pushRetryTargetFromFinished(ctx.allocator(), result);
                errdefer {
                    var target = retry_target;
                    target.deinit(ctx.allocator());
                }
                try self.setPushErrorWithRetry(ctx.allocator(), detail, retry_target, pushCredentialFailureLikely(detail));
            },
            .failed_static => |message| {
                self.setReviewStatus("push failed: {s}", .{message});
                try self.setPushError(ctx.allocator(), message);
            },
        }
    }

    fn finishPull(self: *App, ctx: *chasen.Ctx(Msg), finished: PullFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        switch (result.result) {
            .ok => {
                if (active_matches) {
                    self.setReviewStatus("pulled: {s} <- {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                    try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
                } else {
                    self.setReviewStatus("pulled: {s}", .{result.repo_root});
                }
            },
            .ok_static => |message| {
                if (active_matches) {
                    self.setReviewStatus("{s}", .{message});
                    try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
                } else {
                    self.setReviewStatus("{s}: {s}", .{ message, result.repo_root });
                }
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("pull", result.result);
                // A failed pull may still have fetched remote-tracking refs
                // before `--ff-only` or another later step failed, so refresh
                // the active repo when it still matches the completed task.
                if (active_matches) try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
            },
        }
    }

    fn finishFetch(self: *App, ctx: *chasen.Ctx(Msg), finished: FetchFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        switch (result.result) {
            .ok, .ok_static => {
                if (active_matches) {
                    self.setReviewStatus("fetched: {s}", .{result.remote});
                    try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
                } else {
                    self.setReviewStatus("fetched: {s}", .{result.repo_root});
                }
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("fetch", result.result);
                // Git can update some refs before reporting an overall fetch
                // failure. Reload only the still-active matching repo so the UI
                // sees those side effects without disturbing a repo switch.
                if (active_matches) try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
            },
        }
    }

    fn finishSwitchBranch(self: *App, ctx: *chasen.Ctx(Msg), finished: SwitchBranchFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            result.pending,
            result.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        switch (result.result) {
            .ok, .ok_static => {
                const reviewed_clear_failed = if (self.pages.review.reviewed_store.clearForRepo(ctx.allocator(), result.repo_root)) |_| false else |_| true;
                self.pages.review.staged_hunks.clearRepo(ctx.allocator(), result.repo_root);
                if (active_matches) {
                    self.reviewNavigation().clearActionCursor(ctx.allocator());
                    self.reviewNavigation().clearSearch();
                    self.setReviewStatus("switched branch: {s} -> {s}", .{ result.old_branch, result.new_branch });
                    if (reviewed_clear_failed) self.setReviewStatus("switched branch: {s} -> {s}; could not clear reviewed marks", .{ result.old_branch, result.new_branch });
                    try self.reviewRead().applyEffectReload(ctx, .source_and_aux_clear_visible);
                } else {
                    self.setReviewStatus("switched branch: {s}", .{result.repo_root});
                }
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("branch switch", result.result);
                if (active_matches) try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
            },
        }
    }

    fn finishBranchListLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: BranchListLoadFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (result.repo_epoch != self.repoSessionView().epoch()) return;

        switch (app_load_state.acceptBranchListResult(
            &self.branch_switch_load_pending,
            self.branch_switch.hasState(),
            self.branch_switch.generation,
            self.branch_switch.repo_root,
            result.generation,
            result.repo_root,
        )) {
            .accepted => {},
            .no_pending, .stale_pending_generation, .missing_state, .stale_state_generation, .repo_mismatch => return,
        }
        const diagnostic_origin: EffectOrigin = .{ .page = .{
            .page_id = result.origin,
            .repo_epoch = result.repo_epoch,
            .activation_id = result.activation_id,
        } };
        const diagnostic_is_live = self.effectOriginIsLive(diagnostic_origin);

        switch (result.result) {
            .loaded => |list| {
                const branches = try copyBranchSwitchItems(ctx.allocator(), list.branches);
                errdefer {
                    for (branches) |*item| item.deinit(ctx.allocator());
                    ctx.allocator().free(branches);
                }
                for (self.branch_switch.branches) |*item| item.deinit(ctx.allocator());
                ctx.allocator().free(self.branch_switch.branches);
                self.branch_switch.branches = branches;
                self.branch_switch.loading = false;
                self.branch_switch.selected_index = branchSwitchInitialSelection(branches);
            },
            .failed => |message| {
                if (diagnostic_is_live) self.setEffectStatus(diagnostic_origin, "branch list load failed: {s}", .{git_ops.trimGitOutput(message)});
                self.clearBranchSwitch(ctx.allocator());
            },
            .failed_static => |message| {
                if (diagnostic_is_live) self.setEffectStatus(diagnostic_origin, "branch list load failed: {s}", .{message});
                self.clearBranchSwitch(ctx.allocator());
            },
            .empty => {
                if (diagnostic_is_live) self.setEffectStatus(diagnostic_origin, "branch list load failed", .{});
                self.clearBranchSwitch(ctx.allocator());
            },
        }
        if (self.active_page != result.origin) self.redraw_plan.requestSkip();
    }

    fn finishPushForeground(self: *App, ctx: *chasen.Ctx(Msg), result: chasen.ForegroundCommandResult) !void {
        var foreground = switch (self.push_retry.state) {
            .foreground => |foreground| foreground,
            else => return,
        };
        if (foreground.request_id.id != result.request_id.id) return;
        self.push_retry.state = .idle;
        defer foreground.deinit(ctx.allocator());

        const terminal_target = self.acceptActionTerminalForTarget(
            ctx.allocator(),
            foreground.pending,
            foreground.target.repo_root,
        );
        if (terminal_target == .rejected_terminal) return;
        const active_matches = terminal_target == .current_review_target;

        const diagnostic_origin: EffectOrigin = .{ .page = foreground.origin };
        if (!self.effectOriginIsLive(diagnostic_origin)) {
            self.redraw_plan.requestSkip();
            return;
        }
        switch (result.outcome) {
            .exited => |code| {
                if (code == 0) {
                    if (active_matches) {
                        self.setEffectStatus(diagnostic_origin, "pushed interactively: {s} -> {s}/{s}", .{ foreground.target.branch, foreground.target.remote, foreground.target.remote_branch });
                    } else {
                        self.setEffectStatus(diagnostic_origin, "pushed interactively: {s}", .{foreground.target.repo_root});
                    }
                } else {
                    if (active_matches) {
                        self.setEffectStatus(diagnostic_origin, "interactive push exited: {d}", .{code});
                    } else {
                        self.setEffectStatus(diagnostic_origin, "interactive push exited for {s}: {d}", .{ foreground.target.repo_root, code });
                    }
                }
            },
            .signaled => |signal| {
                if (active_matches) {
                    self.setEffectStatus(diagnostic_origin, "interactive push signal: {d}", .{signal});
                } else {
                    self.setEffectStatus(diagnostic_origin, "interactive push signal for {s}: {d}", .{ foreground.target.repo_root, signal });
                }
            },
            .spawn_failed => |err| {
                if (active_matches) {
                    self.setEffectStatus(diagnostic_origin, "interactive push spawn failed: {s}", .{err});
                } else {
                    self.setEffectStatus(diagnostic_origin, "interactive push spawn failed for {s}: {s}", .{ foreground.target.repo_root, err });
                }
            },
            .wait_failed => |err| {
                if (active_matches) {
                    self.setEffectStatus(diagnostic_origin, "interactive push wait failed: {s}", .{err});
                } else {
                    self.setEffectStatus(diagnostic_origin, "interactive push wait failed for {s}: {s}", .{ foreground.target.repo_root, err });
                }
            },
        }

        if (self.active_page != foreground.origin.page_id) {
            self.redraw_plan.requestSkip();
            return;
        }

        if (active_matches) {
            // Foreground output is intentionally not captured, so GitFrame
            // cannot infer what changed from stderr/stdout. Refresh even after
            // non-zero exits because interactive helpers may still update local
            // refs, credential state, or branch status before failing.
            try self.reviewRead().applyEffectReload(ctx, .source_and_aux);
        }
    }

    fn pushRetryTargetFromFinished(allocator: std.mem.Allocator, finished: PushFinished) !app_state.PushRetryTarget {
        var target: app_state.PushRetryTarget = .{
            .mode = finished.mode,
            .repo_root = try allocator.dupe(u8, finished.repo_root),
            .branch = &.{},
            .remote = &.{},
            .remote_branch = &.{},
            .oid = &.{},
        };
        errdefer target.deinit(allocator);
        target.branch = try allocator.dupe(u8, finished.branch);
        target.remote = try allocator.dupe(u8, finished.remote);
        target.remote_branch = try allocator.dupe(u8, finished.remote_branch);
        target.oid = try allocator.dupe(u8, finished.oid);
        return target;
    }

    fn pushCredentialFailureLikely(detail: []const u8) bool {
        const needles = [_][]const u8{
            "could not read Username",
            "could not read Password",
            "Authentication failed",
            "terminal prompts disabled",
            "HTTP Basic: Access denied",
            "Support for password authentication was removed",
            "The requested URL returned error: 403",
        };
        for (needles) |needle| {
            if (std.mem.indexOf(u8, detail, needle) != null) return true;
        }
        return false;
    }

    fn openSelectedFileInEditor(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setReviewStatus("finish current git action before opening editor", .{});
            return;
        }

        const target = switch (self.reviewContent().editorTarget()) {
            .ready => |target| target,
            .unavailable_source, .no_repo => {
                self.setReviewStatus("editor unavailable for this source", .{});
                return;
            },
            .no_path => {
                self.setReviewStatus("no file selected", .{});
                return;
            },
            .stale_source => {
                self.setReviewStatus("source is stale; press r to reload", .{});
                return;
            },
            .directory_unsupported => {
                self.setReviewStatus("directories cannot be opened in editor", .{});
                return;
            },
            .deleted_file => {
                self.setReviewStatus("deleted files cannot be opened", .{});
                return;
            },
        };

        var argv = editor.build(ctx.allocator(), self.user_config.editor, self.env_map, .{
            .repo_root = target.repo_root,
            .path = target.path,
            .line = target.line,
            .column = 1,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.EmptyArgv => {
                self.setReviewStatus("editor command is empty", .{});
                return;
            },
            error.MissingPathPlaceholder, error.UnknownPlaceholder, error.TooManyArguments => {
                self.setReviewStatus("editor config invalid: {s}", .{@errorName(err)});
                return;
            },
        };
        defer argv.deinit(ctx.allocator());
        if (argv.argv.len == 0) {
            self.setReviewStatus("editor command is empty", .{});
            return;
        }

        const request_id = ctx.terminal().runForegroundCommand(.{
            .argv = argv.argv,
            .cwd = target.repo_root,
            .finished = Msg.editorFinished,
        }) catch |err| switch (err) {
            error.ForegroundCommandLimitExceeded => {
                self.setReviewStatus("editor command already queued", .{});
                return;
            },
            error.ForegroundCommandEmptyArgv => {
                self.setReviewStatus("editor command is empty", .{});
                return;
            },
            error.OutOfMemory => return err,
        };
        self.editor_foreground_request = .{
            .request_id = request_id,
            .origin = self.reviewPageEffectOrigin(),
        };
        self.setReviewStatus("opening editor: {s}", .{target.path});
    }

    fn finishEditorCommand(self: *App, ctx: *chasen.Ctx(Msg), result: chasen.ForegroundCommandResult) !void {
        const foreground = self.editor_foreground_request orelse return;
        if (foreground.request_id.id != result.request_id.id) return;
        self.editor_foreground_request = null;
        const diagnostic_origin: EffectOrigin = .{ .page = foreground.origin };
        if (!self.effectOriginIsLive(diagnostic_origin)) {
            self.redraw_plan.requestSkip();
            return;
        }
        switch (result.outcome) {
            .exited => |code| {
                if (code == 0) {
                    self.setEffectStatus(diagnostic_origin, "editor closed", .{});
                } else {
                    self.setEffectStatus(diagnostic_origin, "editor exited: {d}", .{code});
                }
            },
            .signaled => |signal| self.setEffectStatus(diagnostic_origin, "editor signal: {d}", .{signal}),
            .spawn_failed => |err| self.setEffectStatus(diagnostic_origin, "editor spawn failed: {s}", .{err}),
            .wait_failed => |err| self.setEffectStatus(diagnostic_origin, "editor wait failed: {s}", .{err}),
        }

        if (self.active_page != foreground.origin.page_id) {
            self.redraw_plan.requestSkip();
            return;
        }
        if (foreground.origin.page_id != .review or foreground.origin.repo_epoch != self.repoSessionView().epoch()) return;

        try self.reviewRead().reloadAfterEditor(ctx);
    }

    fn copyCurrentLine(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const text = self.reviewContent().currentLineCopyText() orelse {
            self.setReviewStatus("no diff line selected", .{});
            return;
        };
        self.queueClipboardCopy(ctx, .{
            .origin = .{ .page = self.reviewPageEffectOrigin() },
            .label = "current line",
            .text = text,
        });
    }

    fn copyCurrentHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        var content = try self.reviewContent().selectedHunkCopyText(ctx.allocator());
        defer content.deinit(ctx.allocator());
        switch (content) {
            .ready => |text| self.queueClipboardCopy(ctx, .{
                .origin = .{ .page = self.reviewPageEffectOrigin() },
                .label = "current hunk",
                .text = text,
            }),
            .no_hunk => self.setReviewStatus("no hunk selected", .{}),
            .no_new_side => self.setReviewStatus("no new-side text in selected hunk", .{}),
        }
    }

    fn copyDiffSelection(self: *App, ctx: *chasen.Ctx(Msg), text: []const u8) void {
        self.queueClipboardCopy(ctx, .{
            .origin = .{ .page = self.reviewPageEffectOrigin() },
            .label = "diff selection",
            .text = text,
        });
    }

    fn copySourceSelection(self: *App, ctx: *chasen.Ctx(Msg), text: []const u8) void {
        self.queueClipboardCopy(ctx, .{
            .origin = .{ .page = self.repositoryPageEffectOrigin() },
            .label = "source selection",
            .text = text,
        });
    }

    fn copySourceHeaderPath(self: *App, ctx: *chasen.Ctx(Msg), path: []const u8) void {
        self.queueClipboardCopy(ctx, .{
            .origin = .{ .page = self.repositoryPageEffectOrigin() },
            .label = "file path",
            .text = path,
        });
    }

    fn copyDiffHeaderPath(self: *App, ctx: *chasen.Ctx(Msg), selection: diff_selection.HeaderPathSelection) void {
        const path = self.reviewContent().diffHeaderPath(selection) orelse return;
        self.queueClipboardCopy(ctx, .{
            .origin = .{ .page = self.reviewPageEffectOrigin() },
            .label = "file path",
            .text = path,
        });
    }

    fn copyPopup(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const target = self.popupCopyTarget() orelse {
            self.setStatus("nothing to copy: popup", .{});
            return;
        };
        self.queueClipboardCopy(ctx, .{
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
            const message = self.push_error_message orelse return null;
            return .{
                .label = "push error",
                .text = message,
            };
        }
        return null;
    }

    fn copyCommitMessage(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (!self.commit_panel.is_open) {
            self.setStatus("nothing to copy: commit message", .{});
            return;
        }
        const text = self.commit_panel.formatMessage(ctx.allocator()) catch {
            self.commit_panel.commit_error = .input_allocation_failed;
            self.setStatus("could not prepare commit message copy", .{});
            return;
        };
        defer ctx.allocator().free(text);

        self.queueClipboardCopy(ctx, .{
            .origin = .{ .shell_surface = .{
                .surface = .commit_panel,
                .instance_id = self.commit_panel.instance_id,
            } },
            .label = "commit message",
            .text = text,
        });
    }

    fn queueClipboardCopy(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        request: CopyRequest,
    ) void {
        if (request.text.len == 0) {
            self.setEffectStatus(request.origin, "nothing to copy: {s}", .{request.label});
            return;
        }
        self.clipboard_copy_states.ensureUnusedCapacity(ctx.allocator(), 1) catch {
            self.setEffectStatus(request.origin, "could not track clipboard copy", .{});
            return;
        };
        const request_id = ctx.terminal().copyToClipboard(.{
            .text = request.text,
            .finished = Msg.clipboardFinished,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                self.setEffectStatus(request.origin, "could not prepare clipboard copy", .{});
                return;
            },
            error.ClipboardCopyLimitExceeded => {
                self.setEffectStatus(request.origin, "clipboard copy already queued", .{});
                return;
            },
        };
        self.clipboard_copy_states.putAssumeCapacity(request_id.id, .{
            .origin = request.origin,
            .label = request.label,
        });
    }

    fn finishClipboardCopy(self: *App, ctx: *chasen.Ctx(Msg), finished: ClipboardCopyFinished) void {
        _ = ctx;
        const removed = self.clipboard_copy_states.fetchRemove(finished.request_id.id) orelse {
            self.redraw_plan.requestSkip();
            return;
        };
        const state = removed.value;
        if (!self.effectOriginIsLive(state.origin)) {
            self.redraw_plan.requestSkip();
            return;
        }
        switch (finished.outcome) {
            .sent => self.setEffectStatus(state.origin, "clipboard copy sent: {s}", .{state.label}),
            .unsupported_runtime => self.setEffectStatus(state.origin, "clipboard copy unavailable: {s}", .{state.label}),
            .write_failed => |err| self.setEffectStatus(state.origin, "clipboard copy failed: {s}: {s}", .{ state.label, err }),
        }
        switch (state.origin) {
            .page => |origin_page| if (self.active_page != origin_page.page_id) self.redraw_plan.requestSkip(),
            .shell_surface => {},
        }
    }

    fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.status.set(fmt, args);
    }

    fn setReviewStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.pages.review.status.set(fmt, args);
    }

    fn effectOriginIsLive(self: *const App, origin: EffectOrigin) bool {
        return effect_origin.classify(origin, self.effectOriginSnapshot()) != .stale;
    }

    fn effectOriginSnapshot(self: *const App) effect_origin.Snapshot {
        return .{
            .active_page = self.active_page,
            .repo_epoch = self.repoSessionView().epoch(),
            .review_activation_id = self.pages.review.activation.next_activation_id,
            .repository_activation_id = self.pages.repository.activation_id,
            .compare_activation_id = self.pages.compare.activation.next_activation_id,
            .push_error_instance_id = if (self.overlay.isPushError()) self.overlay.push_error_instance_id else null,
            .commit_panel_instance_id = if (self.commit_panel.is_open) self.commit_panel.instance_id else null,
        };
    }

    fn setEffectStatus(self: *App, origin: EffectOrigin, comptime fmt: []const u8, args: anytype) void {
        switch (origin) {
            .page => |origin_page| switch (origin_page.page_id) {
                .review => self.setReviewStatus(fmt, args),
                .repository => self.pages.repository.status.set(fmt, args),
                .compare => self.pages.compare.status.set(fmt, args),
                // Config later replaces this placeholder with its own
                // diagnostic slot without changing the effect completion tag.
                .config => self.setStatus(fmt, args),
            },
            .shell_surface => self.setStatus(fmt, args),
        }
    }

    fn reviewPageEffectOrigin(self: *const App) PageEffectOrigin {
        const identity = self.pages.review.activation.currentIdentity();
        return .{
            .page_id = .review,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repoSessionView().epoch(),
            // `next_activation_id` retains the most recent Review instance
            // while inactive. A later reactivation increments it, so old
            // completions cannot present in the new page instance.
            .activation_id = if (identity) |value| value.activation_id else self.pages.review.activation.next_activation_id,
        };
    }

    fn repositoryPageEffectOrigin(self: *const App) PageEffectOrigin {
        return .{
            .page_id = .repository,
            .repo_epoch = self.pages.repository.repo_epoch,
            .activation_id = self.pages.repository.activation_id,
        };
    }

    fn comparePageEffectOrigin(self: *const App) PageEffectOrigin {
        const identity = self.pages.compare.activation.currentIdentity();
        return .{
            .page_id = .compare,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repoSessionView().epoch(),
            .activation_id = if (identity) |value| value.activation_id else self.pages.compare.activation.next_activation_id,
        };
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
        if (app_git_requests.hasPendingAction(self.actions)) {
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
        const pending = app.actions.begin(kind);
        app.acceptActionLaunch(pending);
        return pending;
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

fn wrapIndex(current: usize, len: usize, delta: isize) usize {
    if (len == 0) return 0;
    const len_signed: isize = @intCast(len);
    var next = @as(isize, @intCast(current)) + delta;
    next = @mod(next, len_signed);
    return @intCast(next);
}

fn copyBranchSwitchItems(allocator: std.mem.Allocator, source: []const git_backend.BranchListItem) ![]app_state.BranchSwitchItem {
    const items = try allocator.alloc(app_state.BranchSwitchItem, source.len);
    errdefer allocator.free(items);

    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
    }

    for (source, 0..) |branch, index| {
        items[index] = .{
            .name = try allocator.dupe(u8, branch.name),
            .oid = try allocator.dupe(u8, branch.oid),
            .current = branch.current,
        };
        initialized += 1;
    }
    return items;
}

fn branchSwitchInitialSelection(branches: []const app_state.BranchSwitchItem) usize {
    for (branches, 0..) |branch, index| {
        if (!branch.current) return index;
    }
    return 0;
}

fn sidebarWidth(total_width: u16, preferred_width: ?u16) u16 {
    return review_layout.sidebarWidth(total_width, preferred_width);
}

fn pathLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn reviewActionCursorKind(kind: git_ops.TargetKind) review_page.action_cursor.TargetKind {
    return switch (kind) {
        .repository => .repository_root,
        .directory => .directory,
        .file => .file,
    };
}

const test_action_root_identity: repo_root_capability.Identity = .{ .device = 41, .inode = 73 };

/// Test-only shorthand for the owner pair created by `prepareSourceLoad`.
/// Direct completion fixtures must model both identities now that Review
/// retires and admits source terminals independently.
fn ownTestSourceRead(app: *App, generation: u64, kind: review_page.ReloadKind) void {
    app.pages.review.load.generation = generation;
    app.pages.review.load.pending = .{ .diff_load = generation };
    if (app.pages.review.pending_reload) |*pending| {
        std.debug.assert(pending.generation == generation);
        pending.read_epoch = app.pages.review.repository_read_authority.epoch;
    } else {
        app.pages.review.pending_reload = .{
            .generation = generation,
            .read_epoch = app.pages.review.repository_read_authority.epoch,
            .kind = kind,
        };
    }
}

/// Test fixtures model a task which has already crossed the concrete launch
/// boundary before delivering its completion to App.
fn beginAcceptedTestAction(app: *App, kind: app_actions.ActionKind) app_actions.PendingAction {
    if (app.allocator == null) app.allocator = std.testing.allocator;
    const pending = app.actions.begin(kind);
    app.acceptActionLaunch(pending);
    return pending;
}

test "action terminal coordinator accepts every exact launched action once" {
    const action_kinds = [_]app_actions.ActionKind{
        .stage_file,
        .unstage_file,
        .stage_hunk,
        .unstage_hunk,
        .discard_file,
        .commit,
        .assist_commit_message,
        .amend,
        .push,
        .pull,
        .fetch,
        .switch_branch,
    };
    try std.testing.expectEqual(@typeInfo(app_actions.ActionKind).@"enum".fields.len, action_kinds.len);

    var app: App = .{ .allocator = std.testing.allocator };
    for (action_kinds) |kind| {
        const pending = app.actions.begin(kind);
        try std.testing.expect(!app.acceptActionTerminal(pending));
        try std.testing.expect(app.actions.isCurrent(pending));

        app.acceptActionLaunch(pending);
        try std.testing.expect(app.acceptActionTerminal(pending));
        try std.testing.expect(!app.acceptActionTerminal(pending));
    }

    const current = app.actions.begin(.pull);
    app.acceptActionLaunch(current);
    const stale: app_actions.PendingAction = .{
        .generation = current.generation - 1,
        .kind = .stage_file,
    };

    try std.testing.expect(!app.acceptActionTerminal(stale));
    try std.testing.expect(app.actions.isAccepted(current));
    try std.testing.expect(app.acceptActionTerminal(current));
}

fn mutationFenceRepoTestApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !App {
    var app: App = .{
        .allocator = allocator,
        .active_page = .review,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, repo_root) },
        },
    };
    errdefer app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    _ = app.pageCoordinator().activateReview();
    return app;
}

fn replaceMutationFenceTestRepo(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !void {
    app.repo_session.repo_state.deinit(allocator);
    app.repo_session.repo_state = .{
        .discovery = try testSingleRepoDiscovery(allocator, repo_root),
    };
    errdefer {
        app.repo_session.repo_state.deinit(allocator);
        app.repo_session.repo_state = .{};
    }
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    app.repo_session.repo_epoch +%= 1;
    app.pages.review.activation.deactivate();
    _ = app.pageCoordinator().activateReview();
}

fn installInteractivePushRetryForFenceTest(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    oid: []const u8,
) !void {
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .set_upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, oid),
    }, true);
}

test "Review mutation read fence follows interactive foreground queue and terminal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    const DummyForeground = struct {
        fn done(_: chasen.ForegroundCommandResult) App.Msg {
            return .quit;
        }
    };

    // Queue rejection never crosses the accepted action/fence boundary.
    {
        var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearPushError(allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        const epoch_before_rejection =
            app.pages.review.repository_read_authority.epoch;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        _ = try ctx.terminal().runForegroundCommand(.{
            .argv = &.{"true"},
            .cwd = repo.repo_root,
            .finished = DummyForeground.done,
        });

        try app.runInteractivePush(&ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

        try std.testing.expect(app.actions.pending == null);
        try std.testing.expect(app.push_retry.state.availableTarget() != null);
        try std.testing.expect(
            app.pages.review.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expect(
            app.pages.review.repository_read_authority.epoch.eql(
                epoch_before_rejection,
            ),
        );
        try std.testing.expectEqual(
            @as(u8, 1),
            ctx._pending_foreground_commands_len,
        );
    }

    // An accepted foreground command closes the fence only after the runtime
    // queue owns it. Its exact completion reopens before starting the matching
    // repository replacement.
    {
        var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearPushError(allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        const epoch_before_launch =
            app.pages.review.repository_read_authority.epoch;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try app.runInteractivePush(&ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);
        const fence_closed =
            !app.pages.review.repository_read_authority.mayStartRepositoryRead();
        const epoch_advanced =
            app.pages.review.repository_read_authority.epoch.eql(
                epoch_before_launch.next(),
            );
        const entry =
            ctx._pending_foreground_commands[0..ctx._pending_foreground_commands_len][0];
        const completion = entry.finished(.{
            .request_id = entry.request_id,
            .outcome = .{ .exited = 1 },
        });
        ctx.runtimeClearPendingEffectCopies();
        try app.update(completion, &ctx);

        try std.testing.expect(fence_closed);
        try std.testing.expect(epoch_advanced);
        try std.testing.expect(app.actions.pending == null);
        try std.testing.expect(app.push_retry.state == .idle);
        try std.testing.expect(
            app.pages.review.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    }

    // The same accepted foreground owner can become detached before delivery.
    // Its exact terminal still reopens, but must discard the action fallback
    // before the common postlude can target the newly active repository.
    {
        var roots = try TestRepoPair.init();
        defer roots.deinit();
        var app = try mutationFenceRepoTestApp(allocator, repo.repo_root);
        defer app.pages.review.deinit(allocator);
        defer app.repo_session.repo_state.deinit(allocator);
        defer app.clearPushError(allocator);
        try installInteractivePushRetryForFenceTest(
            &app,
            allocator,
            repo.repo_root,
            repo.oid,
        );
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
        defer ctx.runtimeClearPendingEffectCopies();
        defer clearPendingRepositoryTasks(&ctx, allocator);

        try app.runInteractivePush(&ctx);
        try runOnlyPushInspectionTaskForTest(&app, &ctx, io);
        const fence_closed =
            !app.pages.review.repository_read_authority.mayStartRepositoryRead();
        const entry =
            ctx._pending_foreground_commands[0..ctx._pending_foreground_commands_len][0];
        const completion = entry.finished(.{
            .request_id = entry.request_id,
            .outcome = .{ .exited = 1 },
        });
        ctx.runtimeClearPendingEffectCopies();
        try replaceMutationFenceTestRepo(&app, allocator, roots.a);
        try app.update(completion, &ctx);

        try std.testing.expect(fence_closed);
        try std.testing.expect(app.actions.pending == null);
        try std.testing.expect(app.push_retry.state == .idle);
        try std.testing.expect(
            app.pages.review.repository_read_authority.mayStartRepositoryRead(),
        );
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
        try std.testing.expectEqualStrings(roots.a, app.repoSessionView().activeRoot().?);
    }
}

test "Review mutation read fence follows credentialed push queue acceptance" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.pages.review.deinit(allocator);
    defer app.clearPushError(allocator);
    _ = app.pageCoordinator().activateReview();
    try installPushCredentialPromptForTest(&app, allocator);
    const epoch_before_launch = app.pages.review.repository_read_authority.epoch;

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    try app.submitPushCredentials(&ctx);
    const owner = app.actions.pending orelse return error.ExpectedPendingAction;
    const fence_closed =
        !app.pages.review.repository_read_authority.mayStartRepositoryRead();
    const epoch_advanced =
        app.pages.review.repository_read_authority.epoch.eql(epoch_before_launch.next());

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const completion = queued[0].failed(
        queued[0].ctx,
        .runtime_abandoned,
        allocator,
    );
    try app.update(completion, &ctx);

    try std.testing.expectEqual(app_actions.ActionKind.push, owner.token.kind);
    try std.testing.expect(fence_closed);
    try std.testing.expect(epoch_advanced);
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "Review mutation read fence ignores rejected hunk task launch" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);
    const epoch_before_rejection = app.pages.review.repository_read_authority.epoch;

    var ctx: chasen.Ctx(App.Msg) = .{
        ._allocator = allocator,
        ._pending_tasks_with_len = 16,
    };
    try std.testing.expectError(error.TaskLimitExceeded, app.stageSelectedHunk(&ctx));
    ctx._pending_tasks_with_len = 0;

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expect(app.pages.review.repository_read_authority.mayStartRepositoryRead());
    try std.testing.expect(
        app.pages.review.repository_read_authority.epoch.eql(epoch_before_rejection),
    );
}

fn installTestActionCursor(
    app: *App,
    allocator: std.mem.Allocator,
    kind: review_page.action_cursor.TargetKind,
    path_key: []const u8,
    action_generation: u64,
) !void {
    const identity = app.repoSessionView().activeIdentity() orelse test_action_root_identity;
    var prepared = try app.reviewNavigation().prepareActionCursor(
        allocator,
        app.repo_session.repo_epoch,
        identity,
        kind,
        path_key,
    );
    app.reviewNavigation().installActionCursor(allocator, &prepared, action_generation);
}

fn promoteTestActionCursor(app: *App, action_generation: u64) !void {
    return promoteTestActionCursorWithRequirement(app, action_generation, .source_and_status);
}

fn promoteTestActionCursorWithRequirement(
    app: *App,
    action_generation: u64,
    requirement: review_page.action_cursor.RefreshRequirement,
) !void {
    const owner = app.pages.review.action_cursor.owner orelse return error.ExpectedActionCursorOwner;
    try std.testing.expect(app.pages.review.action_cursor.promote(
        action_generation,
        owner.repo_epoch,
        owner.root_identity,
        requirement,
    ));
}

test "Review Git target kinds map to typed action cursor kinds" {
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.repository_root, reviewActionCursorKind(.repository));
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.directory, reviewActionCursorKind(.directory));
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.file, reviewActionCursorKind(.file));
}

test "file and hunk action repository mismatch clear only their matching cursor owner" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.reviewNavigation().clearActionCursor(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const stage_pending = beginAcceptedTestAction(&app, .stage_file);
    try installTestActionCursor(&app, allocator, .file, "src/stage.zig", stage_pending.generation);
    try app.finishStageFile(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/stage.zig"),
        .result = .ok,
    });
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    const unstage_pending = beginAcceptedTestAction(&app, .unstage_file);
    try installTestActionCursor(&app, allocator, .file, "src/unstage.zig", unstage_pending.generation);
    try app.finishUnstageFile(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/unstage.zig"),
        .result = .ok,
    });
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    const hunk_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "src/hunk.zig", hunk_pending.generation);
    try app.finishStageHunk(&ctx, .{
        .pending = hunk_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/hunk.zig"),
        .hunk_index = 0,
        .session_mark_mutation = .none,
        .result = .ok,
    });
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "successful file action binds the exact source and status generations started by its refresh" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer reviewReloadForTest(&app).clearPendingReload(allocator);
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.reviewNavigation().clearActionCursor(allocator);
    _ = app.pageCoordinator().activateReview();

    const pending = beginAcceptedTestAction(&app, .stage_file);
    try installTestActionCursor(&app, allocator, .directory, "src", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try app.finishStageFile(&ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "src"),
        .result = .ok,
    });

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
    const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(pending.generation, app.pages.review.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(status_task.generation, basis.memberState(.status).?.generation.?);
    try std.testing.expectEqual(source_task.generation, basis.memberState(.source).?.generation.?);
    try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);
    try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.source).?.terminal);
}

test "successful hunk action binds an exact status-only refresh" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.reviewNavigation().clearActionCursor(allocator);
    _ = app.pageCoordinator().activateReview();

    const pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);
    try app.finishStageHunk(&ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(review_page.action_cursor.RefreshRequirement.status_only, std.meta.activeTag(basis));
    try std.testing.expect(basis.memberState(.source) == null);
    try std.testing.expectEqual(status_task.generation, basis.memberState(.status).?.generation.?);
    try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);
}

fn initStageHunkLaunchApp(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) !App {
    var root = try repo_root_capability.RootCapability.openCanonical(repo_root);
    var root_owned = true;
    errdefer if (root_owned) root.deinit();
    var discovery = try testSingleRepoDiscovery(allocator, repo_root);
    var discovery_owned = true;
    errdefer if (discovery_owned) discovery.deinit(allocator);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var arena_owned = true;
    errdefer if (arena_owned) arena.deinit();
    var loaded = app_test_support.loadedDiffTwo();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{
                .discovery = discovery,
                .root = root,
            },
        },
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .focus = .diff,
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 0 },
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    root_owned = false;
    discovery_owned = false;
    arena_owned = false;
    errdefer {
        app.pages.review.deinit(allocator);
        app.repo_session.repo_state.deinit(allocator);
    }
    var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
    defer status.deinit();
    try app.pages.review.git_status.replace(repo_root, &status);
    acceptTestSource(&app);
    return app;
}

test "hunk tasks launch exact typed file owners for stage and unstage" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.stageSelectedHunk(&ctx);
    const pending = app.actions.pending orelse return error.ExpectedPendingHunkAction;
    try std.testing.expectEqual(app_actions.ActionKind.stage_hunk, pending.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, pending.launch);
    try std.testing.expectEqual(pending.token.generation, app.pages.review.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.file, app.pages.review.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("a", app.pages.review.action_cursor.target().?.path_key);

    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());

    try addCurrentTestSessionHunkMark(&app, allocator, roots.a, "a", 0);
    try app.unstageSelectedHunk(&ctx);
    const unstage_pending = app.actions.pending orelse return error.ExpectedPendingHunkAction;
    try std.testing.expectEqual(app_actions.ActionKind.unstage_hunk, unstage_pending.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, unstage_pending.launch);
    try std.testing.expectEqual(unstage_pending.token.generation, app.pages.review.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.file, app.pages.review.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("a", app.pages.review.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
}

test "hunk task spawn rejection leaves no action or cursor owner" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };

    try std.testing.expectError(error.TaskLimitExceeded, app.stageSelectedHunk(&ctx));
    ctx._pending_tasks_with_len = 0;
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
}

test "accepted hunk stage local mark allocation failure bounds its refresh owner" {
    const backing = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();

    var fail_offset: usize = 0;
    while (fail_offset < 3) : (fail_offset += 1) {
        var app = try initStageHunkLaunchApp(backing, roots.a);
        defer app.repo_session.repo_state.deinit(backing);
        defer app.pages.review.deinit(backing);

        const pending = beginAcceptedTestAction(&app, .stage_hunk);
        try installTestActionCursor(&app, backing, .file, "a", pending.generation);

        var failing = std.testing.FailingAllocator.init(backing, .{});
        const allocator = failing.allocator();
        const owned_root = try allocator.dupe(u8, roots.a);
        const owned_path = try allocator.dupe(u8, "a");
        failing.fail_index = failing.alloc_index + fail_offset;
        var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

        try app.finishStageHunk(&ctx, .{
            .pending = pending,
            .repo_root = owned_root,
            .path = owned_path,
            .hunk_index = 0,
            .session_mark_mutation = .{ .add = try currentTestSessionHunkMarkKey(&app, 0) },
            .result = .ok,
        });

        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expect(app.actions.pending == null);
        try std.testing.expect(app.pages.review.status_load.pending == null);
        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
        try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    }
}

test "cached hunk unstage binds exact source and status refresh members" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);

    const pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try app.finishUnstageHunk(&ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .reload_after_success = true,
        .result = .ok,
    });

    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
    const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
    try std.testing.expectEqual(review_page.action_cursor.RefreshRequirement.source_and_status, std.meta.activeTag(basis));
    try std.testing.expectEqual(status_task.generation, basis.memberState(.status).?.generation.?);
    try std.testing.expectEqual(source_task.generation, basis.memberState(.source).?.generation.?);
}

test "status-only hunk refresh spawn rejection closes its exact owner" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app = try initStageHunkLaunchApp(allocator, roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);

    const pending = beginAcceptedTestAction(&app, .stage_hunk);
    try installTestActionCursor(&app, allocator, .file, "a", pending.generation);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    try app.finishStageHunk(&ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });
    ctx._pending_tasks_with_len = 0;

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.status_load.pending == null);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
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

test "clipboard copy result status uses best-effort wording" {
    var app: App = .{};
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    const origin: EffectOrigin = .{ .page = app.reviewPageEffectOrigin() };

    try app.clipboard_copy_states.put(std.testing.allocator, 1, .{ .origin = origin, .label = "current line" });
    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 1 }, .outcome = .sent });
    try std.testing.expectEqualStrings("clipboard copy sent: current line", app.pages.review.status.text());

    try app.clipboard_copy_states.put(std.testing.allocator, 2, .{ .origin = origin, .label = "current hunk" });
    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 2 }, .outcome = .unsupported_runtime });
    try std.testing.expectEqualStrings("clipboard copy unavailable: current hunk", app.pages.review.status.text());

    try app.clipboard_copy_states.put(std.testing.allocator, 3, .{ .origin = origin, .label = "current line" });
    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 3 }, .outcome = .{ .write_failed = "BrokenPipe" } });
    try std.testing.expectEqualStrings("clipboard copy failed: current line: BrokenPipe", app.pages.review.status.text());
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
}

test "inactive Review clipboard completion retains diagnostic without redraw" {
    var app: App = .{ .active_page = .repository };
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.clipboard_copy_states.put(std.testing.allocator, 4, .{
        .origin = .{ .page = app.reviewPageEffectOrigin() },
        .label = "current line",
    });

    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 4 }, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: current line", app.pages.review.status.text());
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "repository selection copy uses Repository origin without opening AI UI" {
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
        } },
    };
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.copySourceSelection(&ctx, "selected source");

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("selected source", entry.text);
    const state = app.clipboard_copy_states.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(page.Id.repository, state.origin.page.page_id);
    try std.testing.expectEqual(@as(u64, 4), state.origin.page.repo_epoch);
    try std.testing.expectEqual(@as(u64, 5), state.origin.page.activation_id);
    try std.testing.expectEqual(app_state.OverlayKind.none, app.overlay.kind);
}

test "repository source header copy uses byte-exact Repository clipboard effect" {
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
        } },
    };
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    const path = "src/\xff-main.zig";

    app.copySourceHeaderPath(&ctx, path);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualSlices(u8, path, entry.text);
    const state = app.clipboard_copy_states.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqualStrings("file path", state.label);
    try std.testing.expectEqual(page.Id.repository, state.origin.page.page_id);
    try std.testing.expectEqual(@as(u64, 4), state.origin.page.repo_epoch);
    try std.testing.expectEqual(@as(u64, 5), state.origin.page.activation_id);
    try std.testing.expectEqual(app_state.OverlayKind.none, app.overlay.kind);
}

test "repository selection clipboard queue failure retains page candidate" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
            .completed_selection = .{
                .token = .{
                    .repo_epoch = 4,
                    .root_identity = .{ .device = 6, .inode = 7 },
                    .path = try allocator.dupe(u8, "main.zig"),
                    .source_fingerprint = .init("selected source"),
                },
                .mode = .line,
                .range = .{
                    .start = repository_selection.pointFromLine(0),
                    .end = repository_selection.pointFromLine(0),
                },
                .source_start = 1,
                .source_end = 1,
                .line_count = 1,
                .text = try allocator.dupe(u8, "selected source"),
            },
        } },
    };
    defer app.pages.repository.deinit(allocator);
    defer app.clipboard_copy_states.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    for (0..4) |_| {
        _ = try ctx.terminal().copyToClipboard(.{
            .text = "occupied",
            .finished = App.Msg.clipboardFinished,
        });
    }

    app.copySourceSelection(&ctx, app.pages.repository.completed_selection.?.text);

    try std.testing.expectEqual(@as(u8, 4), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("selected source", app.pages.repository.completed_selection.?.text);
    try std.testing.expectEqualStrings("clipboard copy already queued", app.pages.repository.status.text());
}

test "repository selection late clipboard completion cannot target a new page instance" {
    var app: App = .{
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 5,
            .repo_epoch = 4,
        } },
    };
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();
    app.copySourceSelection(&ctx, "selected source");
    app.copySourceSelection(&ctx, "selected source");
    const inactive_request_id = ctx._pending_clipboard_copies[0].request_id;
    const stale_request_id = ctx._pending_clipboard_copies[1].request_id;
    app.pages.repository.deactivate();
    app.active_page = .review;

    app.finishClipboardCopy(&ctx, .{ .request_id = inactive_request_id, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: source selection", app.pages.repository.status.text());
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.pages.repository.status.clear();
    app.redraw_plan = .{};
    app.pages.repository.activation_id = 6;

    app.finishClipboardCopy(&ctx, .{ .request_id = stale_request_id, .outcome = .sent });

    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("", app.pages.repository.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "copyPopup queues push error message text" {
    var app: App = .{
        .push_error_message = try std.testing.allocator.dupe(u8, "  fatal\nline two  "),
    };
    defer std.testing.allocator.free(app.push_error_message.?);
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    app.overlay.openPushError();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.copyPopup(&ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("  fatal\nline two  ", entry.text);
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.Msg.clipboardFinished), entry.finished);
    const state = app.clipboard_copy_states.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(app.overlay.push_error_instance_id, state.origin.shell_surface.instance_id);
}

test "closed shell surface discards clipboard completion presentation" {
    var app: App = .{};
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    app.overlay.openPushError();
    const instance_id = app.overlay.push_error_instance_id;
    app.overlay.close();
    try app.clipboard_copy_states.put(std.testing.allocator, 5, .{
        .origin = .{ .shell_surface = .{ .surface = .push_error, .instance_id = instance_id } },
        .label = "push error",
    });
    try app.clipboard_copy_states.put(std.testing.allocator, 7, .{
        .origin = .{ .shell_surface = .{ .surface = .push_error, .instance_id = instance_id } },
        .label = "old push error",
    });

    app.finishClipboardCopy(&ctx, .{
        .request_id = .{ .id = 5 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    app.overlay.openPushError();
    try std.testing.expect(app.overlay.push_error_instance_id != instance_id);
    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 7 }, .outcome = .sent });
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
}

test "live shell surface owns clipboard completion presentation" {
    var app: App = .{};
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    app.overlay.openPushError();
    try app.clipboard_copy_states.put(std.testing.allocator, 6, .{
        .origin = .{ .shell_surface = .{
            .surface = .push_error,
            .instance_id = app.overlay.push_error_instance_id,
        } },
        .label = "push error",
    });

    app.finishClipboardCopy(&ctx, .{
        .request_id = .{ .id = 6 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("clipboard copy sent: push error", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
}

test "clipboard completion rejects unknown id and superseded page instance" {
    var app: App = .{};
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    const old_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    try app.clipboard_copy_states.put(std.testing.allocator, 8, .{
        .origin = .{ .page = .{ .page_id = .review, .repo_epoch = 0, .activation_id = old_activation } },
        .label = "old page",
    });
    _ = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 999 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 1), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());

    app.redraw_plan = .{};
    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 8 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "copyPopup reports empty target outside copyable popup" {
    var app: App = .{};
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.copyPopup(&ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: popup", app.status.text());
}

test "copyCommitMessage queues formatted commit message text" {
    var app: App = .{
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.commit_panel.open(.commit);
    app.commit_panel.replaceDraft("  subject  ", "  body\n\nline two  ");

    app.copyCommitMessage(&ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    const entry = ctx._pending_clipboard_copies[0];
    try std.testing.expectEqualStrings("subject\n\nbody\n\nline two", entry.text);
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.Msg.clipboardFinished), entry.finished);
    const state = app.clipboard_copy_states.get(entry.request_id.id) orelse return error.ExpectedClipboardState;
    try std.testing.expectEqual(app.commit_panel.instance_id, state.origin.shell_surface.instance_id);
}

test "copyCommitMessage uses same commit panel state for amend mode" {
    var app: App = .{
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.commit_panel.open(.amend);
    app.commit_panel.replaceDraft("amend subject", null);

    app.copyCommitMessage(&ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("amend subject", ctx._pending_clipboard_copies[0].text);
}

test "copyCommitMessage preserves body-only formatMessage shape" {
    var app: App = .{
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.commit_panel.open(.commit);
    app.commit_panel.replaceDraft("", "body");

    app.copyCommitMessage(&ctx);

    try std.testing.expectEqual(@as(u8, 1), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("\n\nbody", ctx._pending_clipboard_copies[0].text);
}

test "copyCommitMessage reports empty draft and closed panel" {
    var app: App = .{
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer ctx.runtimeClearPendingEffectCopies();

    app.copyCommitMessage(&ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: commit message", app.status.text());

    app.commit_panel.open(.commit);
    app.copyCommitMessage(&ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqualStrings("nothing to copy: commit message", app.status.text());
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

test "inert diff hunk command reports bounded encoding diagnostic" {
    const eligibility = [_]loaded_diff.FileTextEligibility{.inert_invalid_utf8};
    var loaded = app_test_support.loadedDiffOne();
    loaded.file_text_eligibility = &eligibility;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(loaded),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .review = .toggle_selected_hunk }, &ctx);

    try std.testing.expectEqualStrings(git_ops.inert_hunk_action_message, app.pages.review.status.text());
    try std.testing.expect(std.mem.indexOfScalar(u8, app.pages.review.status.text(), 0xff) == null);
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
    app.git_action_spinner_timer_running = true;

    try app.update(.git_action_spinner_tick, undefined);

    try std.testing.expectEqualStrings("pushing: main -> origin/main", app.status.text());
    try std.testing.expectEqual(@as(u8, 1), app.git_action_spinner_tick);
}

test "git action spinner starts when pending action is visible after update" {
    var app: App = .{};
    _ = beginAcceptedTestAction(&app, .push);
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, &tc.ctx);

    try std.testing.expect(app.git_action_spinner_timer_running);
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
}

test "git action spinner self-cancels stale ticks without redraw" {
    var app: App = .{ .git_action_spinner_timer_running = true };
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    try app.update(.git_action_spinner_tick, &tc.ctx);

    try std.testing.expect(!app.git_action_spinner_timer_running);
    try std.testing.expectEqual(@as(u8, 0), app.git_action_spinner_tick);
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

test "opening amend confirmation cancels active discard confirmation" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.cancelAmendConfirmation(std.testing.allocator);
    defer app.cancelDiscardConfirmation(std.testing.allocator);

    app.discard_confirmation = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .path = try std.testing.allocator.dupe(u8, "src/app.zig"),
    };
    app.overlay.openDiscardFile();
    app.commit_panel.open(.amend);
    app.commit_panel.insert('x');

    try app.openAmendConfirmation(std.testing.allocator, "/repo");

    try std.testing.expect(app.discard_confirmation == null);
    try std.testing.expect(app.amend_confirmation != null);
    try std.testing.expectEqual(OverlayKind.amend_commit, app.overlay.kind);
}

test "canceling amend confirmation keeps commit panel draft" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.cancelAmendConfirmation(std.testing.allocator);

    app.commit_panel.open(.amend);
    app.commit_panel.insert('x');
    try app.openAmendConfirmation(std.testing.allocator, "/repo");

    app.cancelAmendConfirmation(std.testing.allocator);

    try std.testing.expect(app.amend_confirmation == null);
    try std.testing.expectEqual(OverlayKind.none, app.overlay.kind);
    try std.testing.expect(app.commit_panel.is_open);
    try std.testing.expectEqual(app_commit_panel.Mode.amend, app.commit_panel.mode);
    try std.testing.expectEqualStrings("x", app.commit_panel.subject.slice());
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
        .push_error_message = try std.testing.allocator.dupe(u8, long_message),
    };
    defer app.clearPushError(std.testing.allocator);
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
        .push_error_message = try std.testing.allocator.dupe(u8, long_message),
        .overlay = .{ .kind = .push_error, .push_error_scroll = 99 },
    };
    defer app.clearPushError(std.testing.allocator);

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, undefined);

    try std.testing.expect(app.overlay.push_error_scroll <= app_view.pushErrorMaxScroll(app.layoutSize(), app.push_error_message));
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

const rooted_nested_action_refresh_diff =
    \\diff --git a/src/a b/src/a
    \\index 1..2 100644
    \\--- a/src/a
    \\+++ b/src/a
    \\@@ -1 +1 @@
    \\-old a
    \\+new a
    \\diff --git a/src/b b/src/b
    \\index 1..2 100644
    \\--- a/src/b
    \\+++ b/src/b
    \\@@ -1 +1 @@
    \\-old b
    \\+new b
    \\
;

fn buildRootedNestedActionBundle(allocator: std.mem.Allocator) !app_load.LoadedDiffBundle {
    var bundle = try app_load.buildLoadedBundle(allocator, rooted_nested_action_refresh_diff);
    errdefer bundle.deinit();
    const arena = bundle.arena.?.allocator();
    bundle.loaded.tree = try file_tree.buildWithOptions(
        arena,
        bundle.loaded.document,
        .{ .entries = &.{} },
        .{ .root = .{ .name = "repo" } },
    );
    try bundle.loaded.rebuildVisibleNodes(arena, false, .all);
    return bundle;
}

const LaterSidebarSelection = enum {
    directory,
    repo_root,
};

const SupersededRefreshOrder = enum {
    status_only,
    source_first,
    status_first,
};

fn expectLaterSidebarIdentity(app: *const App, selection: LaterSidebarSelection) !void {
    const identity = app.reviewNavigationView().selectedSidebarIdentity() orelse return error.ExpectedSidebarIdentity;
    switch (selection) {
        .directory => {
            try std.testing.expect(identity == .directory);
            try std.testing.expectEqualStrings("src", identity.directory);
        },
        .repo_root => try std.testing.expect(identity == .repo_root),
    }
    try std.testing.expectEqualStrings("src/a", app.reviewNavigationView().selectedStagePathKey().?);
}

fn expectLaterDirectoryLikeSelectionAcrossRefresh(
    order: SupersededRefreshOrder,
    selection: LaterSidebarSelection,
) !void {
    const allocator = std.testing.allocator;
    var initial = try buildRootedNestedActionBundle(allocator);
    defer initial.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, "/repo");
    app.pages.review.load.replaceLoaded(allocator, .{
        .arena = initial.takeArena(),
        .loaded = initial.loaded,
        .reviewed_files_owned = false,
    });
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);

    const activation_id = app.pageCoordinator().activateReview();
    const loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const selected_file = review_navigation.findFileNodeByPathKey(loaded, "src/a") orelse return error.ExpectedSelectedFile;
    app.reviewNavigation().selectSidebarNode(loaded, selected_file);

    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    if (order != .status_only) {
        app.pages.review.load.generation = 2;
        app.pages.review.load.pending = .{ .diff_load = 2 };
        app.pages.review.pending_reload = .{ .generation = 2, .kind = .action_result };
    }
    try installTestActionCursor(&app, allocator, .file, "src/a", 9);
    try promoteTestActionCursorWithRequirement(
        &app,
        9,
        if (order == .status_only) .status_only else .source_and_status,
    );
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    if (order != .status_only) {
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    }

    const selection_node = switch (selection) {
        .directory => review_navigation.findNodeBySidebarIdentity(loaded, .{ .directory = "src" }),
        .repo_root => review_navigation.findNodeBySidebarIdentity(loaded, .repo_root),
    } orelse return error.ExpectedDirectoryLikeNode;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    try app.updateReview(&ctx, .{ .sidebar_click_node = selection_node });
    try std.testing.expect(!app.pages.review.action_cursor.hasRestoreAuthority());
    try expectLaterSidebarIdentity(&app, selection);

    if (order == .source_first) {
        const successor = try buildRootedNestedActionBundle(allocator);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try expectLaterSidebarIdentity(&app, selection);
    }

    if (order == .status_only or order == .status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00 M src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try expectLaterSidebarIdentity(&app, selection);
    }

    if (order == .status_first) {
        const successor = try buildRootedNestedActionBundle(allocator);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try expectLaterSidebarIdentity(&app, selection);
    } else if (order == .source_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00 M src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try expectLaterSidebarIdentity(&app, selection);
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
}

test "later directory and root selections survive every hunk action refresh order" {
    for ([_]SupersededRefreshOrder{ .status_only, .source_first, .status_first }) |order| {
        for ([_]LaterSidebarSelection{ .directory, .repo_root }) |selection| {
            try expectLaterDirectoryLikeSelectionAcrossRefresh(order, selection);
        }
    }
}

fn expectDirectoryCursorAfterActionRefresh(status_first: bool) !void {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    var current = app_test_support.loadedDiffRootedNested();
    try current.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    defer reviewReloadForTest(&app).clearPendingReload(allocator);
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    try installTestActionCursor(&app, allocator, .directory, "src", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    if (status_first) {
        const status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status_bundle },
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .empty,
        });
    } else {
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .empty,
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        const status_bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status_bundle },
        });
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    const loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const directory_node = review_navigation.findNodeBySidebarIdentity(
        loaded,
        .{ .directory = "src" },
    ) orelse return error.ExpectedDirectoryNode;
    try std.testing.expectEqual(file_tree.Node.Kind.directory, loaded.tree.nodes[directory_node].kind);
    try std.testing.expectEqual(directory_node, app.pages.review.viewer.selected_node);
    // Directory restoration owns only the sidebar cursor. The body remains a
    // file/status target rather than being converted into a fake directory body.
    try std.testing.expect(app.pages.review.viewer.selected_target != null);
}

test "source-first action refresh restores directory after exact status completion" {
    try expectDirectoryCursorAfterActionRefresh(false);
}

test "status-first action refresh restores directory after exact source completion" {
    try expectDirectoryCursorAfterActionRefresh(true);
}

fn expectTerminalActionRefreshRepublishesFileSearch(status_first: bool) !void {
    const allocator = std.testing.allocator;
    var initial = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
    defer initial.deinit();
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    app.pages.review.load.replaceLoaded(allocator, .{
        .arena = initial.takeArena(),
        .loaded = initial.loaded,
        .reviewed_files_owned = false,
    });
    defer reviewReloadForTest(&app).clearPendingReload(allocator);
    defer reviewReloadForTest(&app).clearLoadedDiff(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    var old_status = try git_status.StatusBundle.parseOwned(allocator, "?? legacy.zig\x00");
    try app.pages.review.git_status.replace("/repo", &old_status);
    try reviewReloadForTest(&app).applyStatusProjection(allocator, false, .accepted_status);
    app.pages.review.file_search.mode = true;
    try app.pages.review.file_search.input.insertSlice("legacy");
    app.reviewNavigation().rebuildFileSearchProjection(allocator);
    try std.testing.expectEqual(
        review_page.file_search.TargetKind.status_only,
        app.pages.review.file_search.focusedCandidate().?.target_kind,
    );

    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    app.pages.review.pending_reload = .{ .generation = 2, .kind = .action_result };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    if (status_first) {
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .empty,
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!app.pages.review.file_search.projection_available);

        const successor = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
    } else {
        const successor = try app_load.buildLoadedBundle(allocator, app_test_support.diff_one);
        try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 2,
            .result = .{ .loaded = successor },
        });
        try std.testing.expect(app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!app.pages.review.file_search.projection_available);

        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(0, 1),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .empty,
        });
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    const loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    for (loaded.tree.nodes) |node| {
        try std.testing.expect(!std.mem.eql(u8, node.path_key, "legacy.zig"));
    }
    try std.testing.expect(app.pages.review.file_search.mode);
    try std.testing.expectEqualStrings("legacy", app.pages.review.file_search.input.slice());
    try std.testing.expect(app.pages.review.file_search.projection_available);
    try std.testing.expect(app.pages.review.file_search.no_match);
    try std.testing.expect(app.pages.review.file_search.focusedCandidate() == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.file_search.candidates.len);
    try std.testing.expectEqual(
        app.pages.review.accepted_sidebar_revision,
        app.pages.review.file_search.basis.?.accepted_sidebar_revision,
    );
}

test "source-first action refresh republishes file search from terminal empty status tree" {
    try expectTerminalActionRefreshRepublishesFileSearch(false);
}

test "status-first action refresh republishes file search from terminal source tree" {
    try expectTerminalActionRefreshRepublishesFileSearch(true);
}

test "inactive Review consumes matching action refresh terminals without shell redraw" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .repository,
        .pages = .{ .review = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = allocator,
    };
    defer reviewReloadForTest(&app).clearPendingReload(allocator);
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.reviewNavigation().clearActionCursor(allocator);
    try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "source failed" },
    });
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "status failed" },
    });

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

const ActionCursorPeerState = enum {
    pending,
    terminal,
};

test "source apply allocation failure closes exact action cursor member for pending and terminal peers" {
    const backing = std.testing.allocator;
    for ([_]ActionCursorPeerState{ .pending, .terminal }) |peer_state| {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const allocator = failing.allocator();
        var app: App = .{
            .allocator = allocator,
            .config = .{ .source = .unstaged },
            .pages = .{ .review = .{
                .load = .{ .generation = 1, .pending = .{ .diff_load = 1 } },
                .status_load = if (peer_state == .pending)
                    .{ .generation = 2, .pending = .{ .generation = 2 } }
                else
                    .{},
            } },
        };
        const activation_id = app.pageCoordinator().activateReview();
        defer reviewReloadForTest(&app).clearLoadedDiff(allocator);
        defer app.pages.review.git_status.deinit();
        defer app.reviewNavigation().clearActionCursor(allocator);

        try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
        try promoteTestActionCursor(&app, 9);
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 1));
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 2));
        if (peer_state == .terminal) {
            try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 2, false));
        }
        ownTestSourceRead(&app, 1, .action_result);
        app.pages.review.activation.queueRevalidation();

        // applySourceFailure has already consumed the task generation before
        // storing its owned diagnostic. Fail that allocation and prove the
        // captured completion still becomes a failure terminal.
        failing.fail_index = failing.alloc_index;
        var failing_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        try std.testing.expectError(error.OutOfMemory, app.reviewRead().finishDiffLoad(failing_ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 1,
            .result = .{ .failed_static = "source apply failed" },
        }));
        try std.testing.expect(failing.has_induced_failure);

        if (peer_state == .pending) {
            const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
            try std.testing.expectEqual(review_page.action_cursor.Terminal.failed, basis.memberState(.source).?.terminal);
            try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.status).?.terminal);

            var peer_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = backing };
            try app.reviewRead().finishStatusLoad(peer_ctx.allocator(), .{
                .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
                .generation = 2,
                .repo_root = try backing.dupe(u8, "/repo"),
                .result = .{ .failed_static = "status failed" },
            });
        }

        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
        try std.testing.expect(app.pages.review.activation.hasQueuedFullRevalidation());
    }
}

test "status apply allocation failure closes exact action cursor member for pending and terminal peers" {
    const backing = std.testing.allocator;
    for ([_]ActionCursorPeerState{ .pending, .terminal }) |peer_state| {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const allocator = failing.allocator();
        var app: App = .{
            .allocator = allocator,
            .config = .{ .source = .unstaged },
            .pages = .{ .review = .{
                .load = if (peer_state == .pending)
                    .{ .generation = 1, .pending = .{ .diff_load = 1 } }
                else
                    .{},
                .status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
            } },
        };
        const activation_id = app.pageCoordinator().activateReview();
        defer reviewReloadForTest(&app).clearLoadedDiff(allocator);
        defer app.pages.review.git_status.deinit();
        defer app.reviewNavigation().clearActionCursor(allocator);

        try installTestActionCursor(&app, allocator, .file, "src/main.zig", 9);
        try promoteTestActionCursor(&app, 9);
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 1));
        try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 2));
        if (peer_state == .terminal) {
            try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .source, 1, false));
        } else {
            ownTestSourceRead(&app, 1, .action_result);
        }
        app.pages.review.activation.queueRevalidation();

        var bundle = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
        var bundle_owned = true;
        defer if (bundle_owned) bundle.deinit();
        const repo_root = try allocator.alloc(u8, 64 * 1024);
        var repo_root_owned = true;
        defer if (repo_root_owned) allocator.free(repo_root);
        @memset(repo_root, 'r');
        // GitStatusState.replace must copy this root into the result arena.
        // Its size forces a fresh arena allocation, which is the next and
        // deliberately failing allocation below.
        failing.fail_index = failing.alloc_index;
        var failing_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
        bundle_owned = false;
        repo_root_owned = false;
        try std.testing.expectError(error.OutOfMemory, app.reviewRead().finishStatusLoad(failing_ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 2,
            .repo_root = repo_root,
            .result = .{ .loaded = bundle },
        }));
        try std.testing.expect(failing.has_induced_failure);

        if (peer_state == .pending) {
            const basis = app.pages.review.action_cursor.owner.?.phase.awaiting_action_refresh;
            try std.testing.expectEqual(review_page.action_cursor.Terminal.pending, basis.memberState(.source).?.terminal);
            try std.testing.expectEqual(review_page.action_cursor.Terminal.failed, basis.memberState(.status).?.terminal);

            var peer_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = backing };
            try app.reviewRead().finishDiffLoad(peer_ctx.allocator(), .{
                .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
                .generation = 1,
                .result = .{ .failed_static = "source failed" },
            });
        }

        try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
        try std.testing.expect(!review_read.testing.readBusy(app.reviewRead()));
        try std.testing.expect(app.pages.review.activation.hasQueuedFullRevalidation());
    }
}

fn expectStatusOnlyHunkRefreshPath(later_selection: bool) !void {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffTwo();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    const activation_id = app.pageCoordinator().activateReview();
    defer reviewReloadForTest(&app).clearLoadedDiff(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    app.pages.review.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(8, .status, 6));
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = mixed_status },
    });
    mixed_status = undefined;
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    if (later_selection) {
        try app.updateReview(&ctx, .select_next_file);
        try std.testing.expectEqualStrings("b", app.reviewNavigationView().selectedStagePathKey().?);
        try std.testing.expect(!app.pages.review.action_cursor.hasRestoreAuthority());
    }

    var status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status },
    });
    status = undefined;

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqualStrings(if (later_selection) "b" else "a", app.reviewNavigationView().selectedStagePathKey().?);
}

test "mixed and final status-only hunk transitions retain their exact selected path" {
    try expectStatusOnlyHunkRefreshPath(false);
}

test "final hunk stage retains exact path through cached projection acceptance" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffFileOneFirst();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{
            .review = .{
                .load = app_test_support.loadStateWithArena(arena, loaded),
                .viewer = .{
                    .selected_target = .{ .diff_file = 0 },
                    // The neighboring file `b` is row zero; path restoration must
                    // not fall back to that ordinal when `a` becomes status-only.
                    .selected_node = 1,
                },
            },
        },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.repo_session.repo_state.discovery = try testSingleRepoDiscovery(allocator, "/repo");
    defer app.repo_session.repo_state.deinit(allocator);
    defer app.pages.review.deinit(allocator);
    const activation_id = app.pageCoordinator().activateReview();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try addCurrentTestSessionHunkMark(&app, allocator, "/repo", "a", 0);
    app.pages.review.status_load = .{ .generation = 6, .pending = .{ .generation = 6 } };
    try installTestActionCursor(&app, allocator, .file, "a", 8);
    try promoteTestActionCursorWithRequirement(&app, 8, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(8, .status, 6));
    var mixed_status = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 6,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = mixed_status },
    });
    mixed_status = undefined;
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    try addCurrentTestSessionHunkMark(&app, allocator, "/repo", "a", 1);
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursorWithRequirement(&app, 9, .status_only);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));
    var staged_status = try git_status.StatusBundle.parseOwned(allocator, "M  a\x00 M b\x00");
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = staged_status },
    });
    staged_status = undefined;

    // The status snapshot changes before the watched unstaged source catches
    // up, so `a` remains the selected source file for this brief interval.
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    app.pages.review.load.generation = 10;
    app.pages.review.load.pending = .{ .diff_load = 10 };
    try reviewReloadForTest(&app).beginPendingReload(allocator, 10, .watch);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 10,
        .result = .{ .loaded = try app_load.buildLoadedBundle(allocator, cached_projection_b_diff) },
    });

    // The successor source no longer contains `a`; status projection now
    // materializes its staged-only row and reapplies the retained path anchor.
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);
    const current_loaded = app.reviewNavigation().activeLoadedDiff() orelse return error.ExpectedLoadedDiff;
    const original_a_node = review_navigation.findFileNodeByPathKey(current_loaded, "a") orelse return error.ExpectedActionFileNode;
    const original_b_node = review_navigation.findFileNodeByPathKey(current_loaded, "b") orelse return error.ExpectedNeighborFileNode;
    const tree_allocator = app.reviewNavigation().loadArenaAllocator() orelse return error.ExpectedLoadArena;
    const reordered_nodes = try tree_allocator.alloc(file_tree.Node, 2);
    reordered_nodes[0] = current_loaded.tree.nodes[original_b_node];
    reordered_nodes[1] = current_loaded.tree.nodes[original_a_node];
    current_loaded.tree.nodes = reordered_nodes;
    try current_loaded.rebuildVisibleNodes(tree_allocator, false, .all);
    app.pages.review.viewer.selected_node = 1;
    const a_node = review_navigation.findFileNodeByPathKey(current_loaded, "a") orelse return error.ExpectedActionFileNode;
    const b_node = review_navigation.findFileNodeByPathKey(current_loaded, "b") orelse return error.ExpectedNeighborFileNode;
    try std.testing.expect(b_node < a_node);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    try app.reviewRead().ensureProjection(&ctx);
    const pending = app.pages.review.review_projection.pending orelse return error.ExpectedCachedProjection;
    try std.testing.expectEqual(app_review_projection.Kind.cached_diff, pending.kind);
    try std.testing.expectEqualStrings("a", pending.path_key);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);

    const result_request = try app_review_projection.testing.cloneRequest(
        allocator,
        pending.identity,
        pending.id,
        pending.repo_root,
        pending.path_key,
        pending.kind,
        pending.source_kind,
        pending.source_session_revision,
        pending.status_snapshot_revision,
    );
    try app.reviewRead().finishProjectionLoad(ctx.allocator(), .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
    try std.testing.expectEqualStrings("a", app.reviewNavigationView().selectedStagePathKey().?);
}

test "later keyboard selection wins while status-only hunk refresh completes" {
    try expectStatusOnlyHunkRefreshPath(true);
}

const reordered_action_refresh_diff =
    \\diff --git a/b b/b
    \\index 1..2 100644
    \\--- a/b
    \\+++ b/b
    \\@@ -1 +1 @@
    \\-old b
    \\+new b
    \\diff --git a/a b/a
    \\index 1..2 100644
    \\--- a/a
    \\+++ b/a
    \\@@ -1 +1 @@
    \\-old a
    \\+new a
    \\
;

const cached_projection_b_diff =
    \\diff --git a/b b/b
    \\index 1..2 100644
    \\--- a/b
    \\+++ b/b
    \\@@ -1 +1 @@
    \\-old b
    \\+new b
    \\
;

fn expectSelectionAcrossSourceAndStatus(status_first: bool, later_selection: bool) !void {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    var loaded = app_test_support.loadedDiffTwo();
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .all);
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, loaded),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    const activation_id = app.pageCoordinator().activateReview();
    defer reviewReloadForTest(&app).clearPendingReload(allocator);
    defer reviewReloadForTest(&app).clearLoadedDiff(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(allocator);

    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7 } };
    app.pages.review.pending_reload = .{ .generation = 2, .kind = .action_result };
    try installTestActionCursor(&app, allocator, .file, "a", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    if (later_selection) {
        try app.updateReview(&ctx, .select_next_file);
        try std.testing.expectEqualStrings("b", app.reviewNavigationView().selectedStagePathKey().?);
        try std.testing.expect(!app.pages.review.action_cursor.hasRestoreAuthority());
    }
    const expected_path = if (later_selection) "b" else "a";

    if (status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
        try std.testing.expectEqualStrings(expected_path, app.reviewNavigationView().selectedStagePathKey().?);
    }

    const successor = try app_load.buildLoadedBundle(allocator, reordered_action_refresh_diff);
    try app.reviewRead().finishDiffLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
        .generation = 2,
        .result = .{ .loaded = successor },
    });
    try std.testing.expectEqualStrings(expected_path, app.reviewNavigationView().selectedStagePathKey().?);

    if (!status_first) {
        var status = try git_status.StatusBundle.parseOwned(allocator, " M a\x00 M b\x00");
        try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
            .identity = page.RequestIdentity.review(app.repo_session.repo_epoch, activation_id),
            .generation = 7,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .result = .{ .loaded = status },
        });
        status = undefined;
    }

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqualStrings(expected_path, app.reviewNavigationView().selectedStagePathKey().?);
}

test "cached hunk unstage retains exact path through source-first refresh" {
    try expectSelectionAcrossSourceAndStatus(false, false);
}

test "cached hunk unstage retains exact path through status-first refresh" {
    try expectSelectionAcrossSourceAndStatus(true, false);
}

test "later selection survives source-first hunk action refresh with reordered files" {
    try expectSelectionAcrossSourceAndStatus(false, true);
}

test "later selection survives status-first hunk action refresh with reordered files" {
    try expectSelectionAcrossSourceAndStatus(true, true);
}

test "action cursor waits for the exact status member after source is terminal" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "b", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 1));
    try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .source, 2, true));
    app.pages.review.status_load.pending = .{ .generation = 1 };

    // The source half may complete first. Retained pre-action status is not a
    // coherent final projection and therefore cannot consume the owner.
    try reviewReloadForTest(&app).applyStatusProjection(std.testing.allocator, false, .accepted_source);
    try std.testing.expect(app.pages.review.action_cursor.hasOwner());

    app.pages.review.status_load.pending = null;
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try reviewReloadForTest(&app).applyStatusProjection(std.testing.allocator, false, .accepted_status);
    try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 1, true));
    try std.testing.expect(app.reviewNavigation().finalizeActionCursor(std.testing.allocator));

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
}

test "staged summary distinguishes pending missing and ready status snapshots" {
    var app: App = .{
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

    try std.testing.expectEqual(app_commit_panel.StagedSummary.unavailable, app.stagedSummaryForActiveRepo());

    app.pages.review.status_load.pending = .{ .generation = 1 };
    syncTestActivation(&app);
    try std.testing.expectEqual(app_commit_panel.StagedSummary.loading_or_stale, app.stagedSummaryForActiveRepo());

    app.pages.review.status_load.pending = null;
    syncTestActivation(&app);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  staged.zig\x00 M unstaged.zig\x00?? new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    try std.testing.expectEqual(app_commit_panel.StagedSummary{ .ready = .{ .count = 1 } }, app.stagedSummaryForActiveRepo());
}

fn testAppWithCommitPanel() App {
    return .{
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
}

fn commitMessageAssistFinished(
    allocator: std.mem.Allocator,
    pending: app_actions.PendingAction,
    launch_revision: u64,
    mode: app_actions.CommitMessageAssistMode,
    result: app_actions.CommitMessageActionResult,
) !CommitMessageAssistFinished {
    const repo_root = try allocator.dupe(u8, "/repo");
    errdefer allocator.free(repo_root);
    const action_id = try allocator.dupe(u8, "commit-message");
    return .{
        .pending = pending,
        .repo_root = repo_root,
        .action_id = action_id,
        .launch_revision = launch_revision,
        .mode = mode,
        .result = result,
    };
}

test "finishCommitMessageAssist inserts generated editable draft and truncated warning" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.commit_panel.draft_revision;
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = try std.testing.allocator.dupe(u8, "Generated body"),
        .truncated = true,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("Generated subject", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("Generated body", app.commit_panel.body.slice());
    try std.testing.expectEqualStrings("generated commit message from truncated staged diff", app.pages.review.status.text());
}

test "finishCommitMessageAssist ignores stale result after popup close" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.commit_panel.draft_revision;
    app.commit_panel.close();
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!app.commit_panel.is_open);
    try std.testing.expectEqualStrings("", app.commit_panel.subject.slice());
}

test "finishCommitMessageAssist ignores generated draft after user edit" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    const launch_revision = app.commit_panel.draft_revision;
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    app.commit_panel.insert('x');
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("x", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("generated commit message ignored; draft changed", app.pages.review.status.text());
}

test "finishCommitMessageAssist failure keeps draft unchanged" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.commit_panel.draft_revision;
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{
        .failed = try std.testing.allocator.dupe(u8, "commit-message: failed"),
    });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqual(app_commit_panel.CommitError.assist_failed, app.commit_panel.commit_error.?);
    try std.testing.expectEqualStrings("", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("commit-message: failed", app.pages.review.status.text());
}

test "finishCommitMessageAssist rejects long subject without mutating draft" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.commit_panel.draft_revision;
    var long_subject: [app_commit_panel.max_subject_chars + 1]u8 = undefined;
    @memset(&long_subject, 'a');
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, &long_subject),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqual(app_commit_panel.CommitError.subject_too_long, app.commit_panel.commit_error.?);
    try std.testing.expectEqualStrings("", app.commit_panel.subject.slice());
}

test "finishCommitMessageAssist replaces unchanged improved draft" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    app.commit_panel.paste("Draft subject");
    const snapshot = try app.buildDraftSnapshot(std.testing.allocator);
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const launch_revision = app.commit_panel.draft_revision;
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = try std.testing.allocator.dupe(u8, "Improved body"),
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("Improved subject", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("Improved body", app.commit_panel.body.slice());
    try std.testing.expectEqualStrings("improved commit message", app.pages.review.status.text());
}

test "finishCommitMessageAssist ignores improved draft after user edit" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    app.commit_panel.paste("Draft subject");
    const snapshot = try app.buildDraftSnapshot(std.testing.allocator);
    const launch_revision = app.commit_panel.draft_revision;
    app.commit_panel.paste(" edited");
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("Draft subject edited", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("improved commit message ignored; draft changed", app.pages.review.status.text());
}

test "finishCommitMessageAssist ignores generated draft after edit then clear" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    const launch_revision = app.commit_panel.draft_revision;
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    app.commit_panel.insert('x');
    app.commit_panel.backspace();
    try std.testing.expect(app.commit_panel.draftIsEmpty());
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .generate, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Generated subject"),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("generated commit message ignored; draft changed", app.pages.review.status.text());
}

test "finishCommitMessageAssist ignores improved draft after edit then restore" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    app.commit_panel.paste("Draft subject");
    const snapshot = try app.buildDraftSnapshot(std.testing.allocator);
    const launch_revision = app.commit_panel.draft_revision;
    app.commit_panel.insert('x');
    app.commit_panel.backspace();
    try std.testing.expectEqualStrings("Draft subject", app.commit_panel.subject.slice());
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("Draft subject", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("improved commit message ignored; draft changed", app.pages.review.status.text());
}

test "finishCommitMessageAssist ignores improved draft after close and reopen" {
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    var app = testAppWithCommitPanel();
    defer app.commit_panel.deinit();

    app.commit_panel.open(.commit);
    app.commit_panel.paste("Draft subject");
    const snapshot = try app.buildDraftSnapshot(std.testing.allocator);
    const launch_revision = app.commit_panel.draft_revision;
    const pending = beginAcceptedTestAction(&app, .assist_commit_message);
    app.commit_panel.close();
    app.commit_panel.open(.commit);
    app.commit_panel.paste("Draft subject");
    const finished = try commitMessageAssistFinished(std.testing.allocator, pending, launch_revision, .{ .improve = snapshot }, .{ .ok = .{
        .subject = try std.testing.allocator.dupe(u8, "Improved subject"),
        .body = null,
        .truncated = false,
    } });

    app.finishCommitMessageAssist(&ctx, finished);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expectEqualStrings("Draft subject", app.commit_panel.subject.slice());
    try std.testing.expectEqualStrings("improved commit message ignored; draft changed", app.pages.review.status.text());
}

test "resolveCommitMessageAction resolves minimal configs and reports missing or multiple" {
    var missing = testAppWithCommitPanel();
    defer missing.commit_panel.deinit();
    try std.testing.expectError(error.Missing, missing.resolveGenerateCommitMessageAction());
    try std.testing.expectError(error.Missing, missing.resolveImproveCommitMessageAction());

    var multiple = testAppWithCommitPanel();
    defer multiple.commit_panel.deinit();
    var action: config_mod.ExternalActionConfig = .{};
    action.id = "commit-message-a";
    action.argv[0] = "helper";
    action.argv_len = 1;
    action.stdin = .staged_diff;
    var other = action;
    other.id = "commit-message-b";
    multiple.user_config.actions.items[0] = action;
    multiple.user_config.actions.len = 1;
    try std.testing.expectEqualStrings(
        "commit-message-a",
        (try multiple.resolveGenerateCommitMessageAction()).id,
    );

    multiple.user_config.actions.items[1] = other;
    multiple.user_config.actions.len = 2;
    try std.testing.expectError(error.Multiple, multiple.resolveGenerateCommitMessageAction());

    multiple.user_config.actions.items[0].stdin = .commit_message_context;
    multiple.user_config.actions.items[1].stdin = .commit_message_context;
    try std.testing.expectError(error.Multiple, multiple.resolveImproveCommitMessageAction());
    multiple.user_config.actions.len = 1;
    try std.testing.expectEqualStrings(
        "commit-message-a",
        (try multiple.resolveImproveCommitMessageAction()).id,
    );
}

test "action cursor survives exact status projection while source member is pending" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 1,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "b", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .source, 2));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 1));
    try std.testing.expect(app.pages.review.action_cursor.finishMember(9, app.repo_session.repo_epoch, .status, 1, true));
    app.pages.review.load.pending = .{ .diff_load = app.pages.review.load.generation + 1 };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try reviewReloadForTest(&app).applyStatusProjection(std.testing.allocator, false, .accepted_status);

    try std.testing.expect(app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
}

test "action cursor closes after status completion when source failed before generation" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
            },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearActionCursor(std.testing.allocator);

    try installTestActionCursor(&app, std.testing.allocator, .file, "missing.zig", 9);
    try promoteTestActionCursor(&app, 9);
    try std.testing.expect(app.pages.review.action_cursor.failMemberBeforeStart(9, .source));
    try std.testing.expect(app.pages.review.action_cursor.startMember(9, .status, 7));

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.reviewRead().finishStatusLoad(ctx.allocator(), .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
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

fn setupPushRetryRepoForTest(allocator: std.mem.Allocator, io: std.Io, tmp: *std.testing.TmpDir) !struct { repo_root: []u8, oid: []u8 } {
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);

    try runAppTestGit(allocator, io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "README.md", .data = "hello\n" });
    try runAppTestGit(allocator, io, &.{ "git", "add", "README.md" }, work);
    try runAppTestGit(allocator, io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "initial" }, work);

    const repo_root_z = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root_z);
    const repo_root = try allocator.dupe(u8, repo_root_z);
    errdefer allocator.free(repo_root);
    const oid_output = try appGitOutputAlloc(allocator, io, work, &.{ "git", "rev-parse", "--verify", "HEAD" });
    errdefer allocator.free(oid_output);
    const oid = try allocator.dupe(u8, std.mem.trim(u8, oid_output, " \t\r\n"));
    allocator.free(oid_output);
    return .{ .repo_root = repo_root, .oid = oid };
}

fn installPushCredentialPromptForTest(app: *App, allocator: std.mem.Allocator) !void {
    var target = app_state.PushRetryTarget.empty();
    var target_owned = true;
    defer if (target_owned) target.deinit(allocator);
    target.repo_root = try allocator.dupe(u8, "/repo");
    target.branch = try allocator.dupe(u8, "main");
    target.remote = try allocator.dupe(u8, "origin");
    target.remote_branch = try allocator.dupe(u8, "main");
    target.oid = try allocator.dupe(u8, "abc123");
    target.remote_url = try allocator.dupe(u8, "https://example.test/owner/repo.git");

    const prompt = try allocator.create(app_state.PushCredentialPrompt);
    var prompt_owned = true;
    defer if (prompt_owned) {
        prompt.deinit(allocator);
        allocator.destroy(prompt);
    };
    prompt.* = .{
        .target = target,
        .active_field = .password,
    };
    target_owned = false;
    try prompt.username.insertSlice("alice");
    try prompt.password.insertSlice("secret-token");

    app.push_retry.state = .{ .credential_prompt = prompt };
    prompt_owned = false;
}

fn runOnlyPushInspectionTaskForTest(app: *App, ctx: *chasen.Ctx(App.Msg), io: std.Io) !void {
    const pending = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    const msg = pending[0].run(pending[0].ctx, ctx.allocator(), io);
    try app.update(msg, ctx);
}

fn deinitOnlyPushInspectionTaskForTest(ctx: *chasen.Ctx(App.Msg), io: std.Io) !void {
    const pending = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    var msg = pending[0].run(pending[0].ctx, ctx.allocator(), io);
    msg.deinitUndelivered(ctx.allocator());
}

fn runAppTestGit(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}

fn appGitOutputAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    allocator.free(result.stdout);
    return error.GitCommandFailed;
}

test "requestPush snapshots the active branch target" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 2,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.overlay.isPushBranch());
    const confirmation = app.push_confirmation orelse return error.ExpectedPushConfirmation;
    try std.testing.expectEqualStrings("/repo", confirmation.repo_root);
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("main", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expectEqual(git_ops.PushMode.upstream, confirmation.mode);
    try std.testing.expectEqual(@as(u32, 2), confirmation.ahead_behind.?.ahead);
}

test "requestPush snapshots set-upstream target for branch without upstream" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature/topic",
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.overlay.isPushBranch());
    const confirmation = app.push_confirmation orelse return error.ExpectedPushConfirmation;
    try std.testing.expectEqual(git_ops.PushMode.set_upstream, confirmation.mode);
    try std.testing.expectEqualStrings("/repo", confirmation.repo_root);
    try std.testing.expectEqualStrings("feature/topic", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("feature/topic", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expect(confirmation.ahead_behind == null);
}

test "requestPull snapshots the active branch target" {
    var app: App = .{
        .allocator = std.testing.allocator,
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
    defer app.cancelPullConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 0,
        .behind = 2,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    try app.requestPull(std.testing.allocator);

    try std.testing.expect(app.overlay.isPullBranch());
    const confirmation = app.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expectEqualStrings("/repo", confirmation.repo_root);
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqualStrings("origin", confirmation.remote);
    try std.testing.expectEqualStrings("main", confirmation.remote_branch);
    try std.testing.expectEqualStrings("abc123", confirmation.oid);
    try std.testing.expectEqual(@as(u32, 0), confirmation.ahead);
    try std.testing.expectEqual(@as(u32, 2), confirmation.behind);
}

test "requestPull opens confirmation before remote refresh regardless of stale ahead behind" {
    var app: App = .{
        .allocator = std.testing.allocator,
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
    defer app.cancelPullConfirmation(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    try app.requestPull(std.testing.allocator);

    const confirmation = app.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expectEqualStrings("feature", confirmation.branch);
    try std.testing.expectEqual(@as(u32, 1), confirmation.ahead);
    try std.testing.expectEqual(@as(u32, 0), confirmation.behind);
}

test "requestBranchSwitch opens loading popup and starts identity scoped list task" {
    var app: App = .{
        .allocator = std.testing.allocator,
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
    defer app.clearBranchSwitch(std.testing.allocator);

    var branch_bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
    });
    try app.pages.review.branch_status.replace("/repo", &branch_bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingBranchListTasks(&ctx, std.testing.allocator);

    try app.requestBranchSwitch(&ctx);

    try std.testing.expect(app.overlay.isSwitchBranch());
    try std.testing.expect(app.branch_switch.loading);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const task: *BranchListLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0..ctx._pending_tasks_with_len][0].ctx));
    try std.testing.expectEqual(page.Id.review, task.origin);
    try std.testing.expectEqual(app.repo_session.repo_epoch, task.repo_epoch);
    try std.testing.expectEqual(app.pages.review.activation.next_activation_id, task.activation_id);
    try std.testing.expectEqualStrings("/repo", task.repo_root);
    try std.testing.expectEqual(app.branch_switch.generation, task.generation);
}

test "requestBranchSwitch rejects untracked-only status distinctly" {
    var app: App = .{
        .allocator = std.testing.allocator,
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

    var branch_bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "main",
    });
    try app.pages.review.branch_status.replace("/repo", &branch_bundle);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.txt\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    syncTestActivation(&app);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.requestBranchSwitch(&ctx);

    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expectEqualStrings("branch switch blocked: untracked files present", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "finishBranchListLoad ignores stale result and accepts matching generation" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .branch_switch = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .current_branch = try std.testing.allocator.dupe(u8, "main"),
            .current_oid = try std.testing.allocator.dupe(u8, "abc123"),
            .generation = 3,
            .loading = true,
        },
        .branch_switch_load_pending = 3,
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(std.testing.allocator);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 0,
        .activation_id = 0,
        .generation = 2,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = try branchListForTest(std.testing.allocator, &.{
            .{ .name = "main", .oid = "abc123", .current = true },
        }),
    });
    try std.testing.expect(app.branch_switch.loading);
    try std.testing.expectEqual(@as(usize, 0), app.branch_switch.branches.len);

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 0,
        .activation_id = 0,
        .generation = 3,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = try branchListForTest(std.testing.allocator, &.{
            .{ .name = "main", .oid = "abc123", .current = true },
            .{ .name = "feature/topic", .oid = "def456", .current = false },
        }),
    });

    try std.testing.expect(!app.branch_switch.loading);
    try std.testing.expectEqual(@as(usize, 2), app.branch_switch.branches.len);
    try std.testing.expectEqual(@as(usize, 1), app.branch_switch.selected_index);
    try std.testing.expectEqualStrings("feature/topic", app.branch_switch.branches[1].name);
}

test "finishBranchListLoad rejects matching operation from stale repo epoch" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_epoch = 4,
        },
        .branch_switch = .{
            .repo_root = try allocator.dupe(u8, "/repo"),
            .current_branch = try allocator.dupe(u8, "main"),
            .current_oid = try allocator.dupe(u8, "abc123"),
            .generation = 3,
            .loading = true,
        },
        .branch_switch_load_pending = 3,
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(allocator);
    app.pages.review.status.set("retained", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 3,
        .activation_id = 1,
        .generation = 3,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "stale failure") },
    });

    try std.testing.expectEqual(@as(?u64, 3), app.branch_switch_load_pending);
    try std.testing.expect(app.branch_switch.loading);
    try std.testing.expectEqual(@as(usize, 0), app.branch_switch.branches.len);
    try std.testing.expectEqualStrings("retained", app.pages.review.status.text());
}

test "stale branch-list diagnostic does not overwrite reactivated Review" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .branch_switch = .{
            .repo_root = try allocator.dupe(u8, "/repo"),
            .current_branch = try allocator.dupe(u8, "main"),
            .current_oid = try allocator.dupe(u8, "abc123"),
            .generation = 3,
            .loading = true,
        },
        .branch_switch_load_pending = 3,
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(allocator);
    const old_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    const new_activation = app.pages.review.activation.activate(0, .fresh, .fresh, .fresh);
    try std.testing.expect(old_activation != new_activation);
    app.pages.review.status.set("new Review diagnostic", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.finishBranchListLoad(&ctx, .{
        .origin = .review,
        .repo_epoch = 0,
        .activation_id = old_activation,
        .generation = 3,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "old operation failure") },
    });

    try std.testing.expect(app.branch_switch_load_pending == null);
    try std.testing.expect(!app.branch_switch.hasState());
    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expectEqualStrings("new Review diagnostic", app.pages.review.status.text());
    try std.testing.expect(!app.redraw_plan.resolvesToSkip());
}

test "confirmBranchSwitch treats current branch as no-op without clearing state" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .branch_switch = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .current_branch = try std.testing.allocator.dupe(u8, "main"),
            .current_oid = try std.testing.allocator.dupe(u8, "abc123"),
            .generation = 3,
            .loading = false,
            .branches = try branchSwitchItemsForTest(std.testing.allocator, &.{
                .{ .name = "main", .oid = "abc123", .current = true },
                .{ .name = "feature", .oid = "def456", .current = false },
            }),
        },
        .overlay = .{ .kind = .switch_branch },
    };
    defer app.clearBranchSwitch(std.testing.allocator);
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);

    const mark_key = testSessionHunkMarkKey(1, 0);
    try app.pages.review.staged_hunks.addExact(std.testing.allocator, "/repo", "a", mark_key);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmBranchSwitch(&ctx);

    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expect(app.branch_switch.branches.len == 0);
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqualStrings("already on branch: main", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.actions.pending == null);
}

test "finishSwitchBranch success clears repo-local review state and reloads matching repo" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    defer app.pages.review.reviewed_store.deinit(allocator);
    defer app.pages.review.staged_hunks.deinit(allocator);
    defer app.reviewNavigation().clearActionCursor(allocator);
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);

    try app.pages.review.reviewed_store.set(allocator, app.repoSessionView().activeRoot(), app_test_support.files_two[0], true);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", testSessionHunkMarkKey(1, 0));
    try installTestActionCursor(&app, allocator, .file, "a", 99);
    setDiffSearchQuery(&app, "needle");

    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.finishSwitchBranch(&ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .ok,
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!try app.pages.review.reviewed_store.containsFile(allocator, app.repoSessionView().activeRoot(), app_test_support.files_two[0]));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.search.query.len);
    try std.testing.expectEqualStrings("switched branch: main -> feature", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
}

test "finishSwitchBranch success clears completed repo marks when active repo changed" {
    const allocator = std.testing.allocator;
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "old", .display_path = "/repo", .canonical_root = "/repo" },
        .{ .label = "new", .display_path = "/other", .canonical_root = "/other" },
    };
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .workspace = .{
                .current_root = "/workspace",
                .repos = &repos,
            } }, .active_index = 1 },
        },
    };
    defer app.pages.review.reviewed_store.deinit(allocator);
    defer app.pages.review.staged_hunks.deinit(allocator);

    try app.pages.review.reviewed_store.set(allocator, "/repo", app_test_support.files_two[0], true);
    try app.pages.review.reviewed_store.set(allocator, "/other", app_test_support.files_two[1], true);
    const old_key = testSessionHunkMarkKey(1, 0);
    const new_key = testSessionHunkMarkKey(1, 1);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", old_key);
    try app.pages.review.staged_hunks.addExact(allocator, "/other", "b", new_key);

    const pending = beginAcceptedTestAction(&app, .switch_branch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.finishSwitchBranch(&ctx, .{
        .pending = pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .old_branch = try allocator.dupe(u8, "main"),
        .new_branch = try allocator.dupe(u8, "feature"),
        .result = .ok,
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(!try app.pages.review.reviewed_store.containsFile(allocator, "/repo", app_test_support.files_two[0]));
    try std.testing.expect(try app.pages.review.reviewed_store.containsFile(allocator, "/other", app_test_support.files_two[1]));
    try std.testing.expect(!app.pages.review.staged_hunks.containsExact("/repo", "a", old_key));
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/other", "b", new_key));
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("switched branch: /repo", app.pages.review.status.text());
}

test "requestPush clears previous push error details" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.branch_status.deinit();
    defer app.cancelPushConfirmation(std.testing.allocator);
    defer app.clearPushError(std.testing.allocator);

    var bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc123",
        .branch = "feature",
        .upstream = "origin/main",
        .ahead = 2,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &bundle);
    syncTestActivation(&app);
    try app.setPushError(std.testing.allocator, "old push failure");

    try app.requestPush(std.testing.allocator);

    try std.testing.expect(app.push_error_message == null);
    try std.testing.expect(app.overlay.isPushBranch());
    try std.testing.expect(app.push_confirmation != null);
}

test "requestPush rejects while another action is pending" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .push_confirmation = .{
            .mode = .upstream,
            .repo_root = try std.testing.allocator.dupe(u8, "/old"),
            .branch = try std.testing.allocator.dupe(u8, "old-feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "old-main"),
            .oid = try std.testing.allocator.dupe(u8, "old123"),
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        },
        .overlay = .{ .kind = .push_branch },
    };
    defer app.cancelPushConfirmation(std.testing.allocator);
    app.actions.pending = .{ .token = .{ .generation = 1, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();

    try app.requestPush(std.testing.allocator);

    const confirmation = app.push_confirmation orelse return error.ExpectedPushConfirmation;
    try std.testing.expectEqualStrings("/old", confirmation.repo_root);
    try std.testing.expectEqualStrings("old-feature", confirmation.branch);
    try std.testing.expect(app.overlay.isPushBranch());
    try std.testing.expect(app.actions.pending != null);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "requestPull rejects while another action is pending" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pull_confirmation = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/old"),
            .branch = try std.testing.allocator.dupe(u8, "old-feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "old-main"),
            .oid = try std.testing.allocator.dupe(u8, "old123"),
            .ahead = 0,
            .behind = 1,
        },
        .overlay = .{ .kind = .pull_branch },
    };
    defer app.cancelPullConfirmation(std.testing.allocator);
    app.actions.pending = .{ .token = .{ .generation = 1, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();

    try app.requestPull(std.testing.allocator);

    const confirmation = app.pull_confirmation orelse return error.ExpectedPullConfirmation;
    try std.testing.expectEqualStrings("/old", confirmation.repo_root);
    try std.testing.expectEqualStrings("old-feature", confirmation.branch);
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expect(app.actions.pending != null);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "requestFetch rejects while another action is pending" {
    var app: App = .{ .allocator = std.testing.allocator };
    app.actions.pending = .{ .token = .{ .generation = 1, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.requestFetch(&ctx);

    try std.testing.expect(app.actions.pending != null);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "confirmPush keeps confirmation when another action is pending" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .push_confirmation = .{
            .mode = .upstream,
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .branch = try std.testing.allocator.dupe(u8, "feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "main"),
            .oid = try std.testing.allocator.dupe(u8, "abc123"),
            .ahead_behind = .{ .ahead = 1, .behind = 0 },
        },
        .overlay = .{ .kind = .push_branch },
    };
    defer app.cancelPushConfirmation(std.testing.allocator);
    app.actions.pending = .{ .token = .{ .generation = 1, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmPush(&ctx);

    try std.testing.expect(app.push_confirmation != null);
    try std.testing.expect(app.overlay.isPushBranch());
    try std.testing.expect(app.actions.pending != null);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "confirmPull keeps confirmation when another action is pending" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .pull_confirmation = .{
            .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
            .branch = try std.testing.allocator.dupe(u8, "feature"),
            .remote = try std.testing.allocator.dupe(u8, "origin"),
            .remote_branch = try std.testing.allocator.dupe(u8, "main"),
            .oid = try std.testing.allocator.dupe(u8, "abc123"),
            .ahead = 0,
            .behind = 1,
        },
        .overlay = .{ .kind = .pull_branch },
    };
    defer app.cancelPullConfirmation(std.testing.allocator);
    app.actions.pending = .{ .token = .{ .generation = 1, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmPull(&ctx);

    try std.testing.expect(app.pull_confirmation != null);
    try std.testing.expect(app.overlay.isPullBranch());
    try std.testing.expect(app.actions.pending != null);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "openSelectedFileInEditor blocks while git action is pending" {
    var app: App = .{
        .allocator = std.testing.allocator,
    };
    app.actions.pending = .{ .token = .{ .generation = 7, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.openSelectedFileInEditor(&ctx);

    try std.testing.expectEqualStrings("finish current git action before opening editor", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    const pending = app.actions.pending orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(u64, 7), pending.token.generation);
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, pending.token.kind);
}

test "quit waits for pending git action" {
    var app: App = .{ .allocator = std.testing.allocator };
    app.actions.pending = .{ .token = .{ .generation = 7, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.requestQuit(&ctx);

    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(app.actions.pending != null);
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
    app.actions.pending = .{ .token = .{ .generation = 7, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishReview(&ctx, .canceled);

    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(!output.ready);
    try std.testing.expect(app.actions.pending != null);
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
    try std.testing.expect(normal.commit_panel.is_open);
    try std.testing.expect(help.commit_panel.is_open);
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

test "finishPush does not reload a stale active repository" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "other",
                .display_path = "/other",
                .canonical_root = "/other",
            } } },
        },
    };
    const pending = beginAcceptedTestAction(&app, .push);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishPush(&ctx, .{
        .pending = pending,
        .mode = .set_upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .ok,
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expectEqualStrings("pushed: /repo", app.pages.review.status.text());
}

test "finishPull does not reload a stale active repository" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "other",
                .display_path = "/other",
                .canonical_root = "/other",
            } } },
        },
    };
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishPull(&ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .ok,
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expectEqualStrings("pulled: /repo", app.pages.review.status.text());
}

test "finishPull reloads matching active repo after up-to-date success" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.finishPull(&ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .ok_static = "nothing to pull" },
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.load.pending != null);
    try std.testing.expectEqualStrings("nothing to pull", app.pages.review.status.text());
}

test "finishPull reloads matching active repo after failure" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    const pending = beginAcceptedTestAction(&app, .pull);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.finishPull(&ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .failed_static = "remote unavailable" },
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.load.pending != null);
    try std.testing.expectEqualStrings("pull failed: remote unavailable", app.pages.review.status.text());
}

test "finishFetch does not reload a stale active repository" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "other",
                .display_path = "/other",
                .canonical_root = "/other",
            } } },
        },
    };
    const pending = beginAcceptedTestAction(&app, .fetch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishFetch(&ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .result = .ok,
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expectEqualStrings("fetched: /repo", app.pages.review.status.text());
}

test "finishFetch reloads matching active repo after failure" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    const pending = beginAcceptedTestAction(&app, .fetch);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.finishFetch(&ctx, .{
        .pending = pending,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .result = .{ .failed_static = "remote unavailable" },
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.load.pending != null);
    try std.testing.expectEqualStrings("fetch failed: remote unavailable", app.pages.review.status.text());
}

test "finishPush failed preserves retry target oid for credential prompt" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.clearPushError(std.testing.allocator);
    const pending = beginAcceptedTestAction(&app, .push);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishPush(&ctx, .{
        .pending = pending,
        .mode = .set_upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "fatal: could not read Username for 'https://host': terminal prompts disabled") },
    });

    const target = app.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    try std.testing.expectEqual(git_ops.PushMode.set_upstream, target.mode);
    try std.testing.expectEqualStrings("abc123", target.oid);
    try std.testing.expect(app.push_retry.state.credentialsAvailable());
}

test "credentialed push launch and runtime failure cross common action boundaries" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try installPushCredentialPromptForTest(&app, allocator);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    try app.submitPushCredentials(&ctx);

    try std.testing.expect(app.push_retry.state == .idle);
    const owner = app.actions.pending orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(app_actions.ActionKind.push, owner.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, owner.launch);

    const queued = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    const Task = app_actions.PushTask(App.Msg);
    const task: *Task = @ptrCast(@alignCast(queued[0].ctx));
    try std.testing.expectEqual(owner.token.generation, task.pending.generation);
    try std.testing.expectEqual(owner.token.kind, task.pending.kind);
    const credentials = task.credentials orelse return error.ExpectedPushCredentials;
    try std.testing.expectEqualStrings("alice", credentials.username);
    try std.testing.expectEqualStrings("secret-token", credentials.password);

    const message = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    try app.update(message, &ctx);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.push_error_message != null);
}

test "credentialed push queue failure never creates accepted action ownership" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try installPushCredentialPromptForTest(&app, allocator);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) App.Msg {
            return .quit;
        }

        fn failed(_: chasen.TaskFailure) App.Msg {
            return .quit;
        }
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    for (0..16) |_| try ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });

    try std.testing.expectError(error.TaskLimitExceeded, app.submitPushCredentials(&ctx));

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expectEqual(@as(usize, 0), ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), ctx.takePendingTasks().len);
}

test "clearPushError frees retained retry target" {
    var app: App = .{ .allocator = std.testing.allocator };
    try app.setPushErrorWithRetry(std.testing.allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "feature"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
    }, true);

    app.clearPushError(std.testing.allocator);

    try std.testing.expect(app.push_error_message == null);
    try std.testing.expect(app.push_retry.state == .idle);
}

test "runInteractivePush rejects while another action is pending" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.clearPushError(std.testing.allocator);
    try app.setPushErrorWithRetry(std.testing.allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .branch = try std.testing.allocator.dupe(u8, "main"),
        .remote = try std.testing.allocator.dupe(u8, "origin"),
        .remote_branch = try std.testing.allocator.dupe(u8, "main"),
        .oid = try std.testing.allocator.dupe(u8, "abc123"),
    }, true);
    app.actions.pending = .{ .token = .{ .generation = 7, .kind = .stage_file }, .launch = .accepted };
    defer app.actions.clear();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.runInteractivePush(&ctx);

    const pending = app.actions.pending orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(u64, 7), pending.token.generation);
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, pending.token.kind);
    try std.testing.expect(app.push_retry.state.availableTarget() != null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expectEqualStrings("another git action is running", app.pages.review.status.text());
}

test "push retry inspection rejects duplicate requests without losing task ownership" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, true);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.push_retry.state == .inspecting);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("push retry inspection already running", app.pages.review.status.text());

    app.clearPushError(allocator);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "push retry inspection spawn rollback restores the sole target" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, true);
    var ctx: chasen.Ctx(App.Msg) = .{
        ._allocator = allocator,
        ._io = std.testing.io,
        ._pending_tasks_with_len = 16,
    };

    try std.testing.expectError(error.TaskLimitExceeded, app.runInteractivePush(&ctx));
    ctx._pending_tasks_with_len = 0;

    const restored = app.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    try std.testing.expectEqualStrings("abc123", restored.oid);
    try std.testing.expect(app.push_retry.state.credentialsAvailable());
    try std.testing.expectEqualStrings("could not start push retry inspection", app.pages.review.status.text());
}

test "closing push error invalidates an in-flight inspection result" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.clearPushError(allocator);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expect(app.push_error_message == null);
    try std.testing.expect(!app.overlay.isPushError());
}

test "repository supersession invalidates an in-flight push inspection" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .allocator = allocator };
    defer app.repo_session.deinit(allocator);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    _ = app.pageCoordinator().activateReview();
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try std.testing.expectEqual(repo_session.CommitOutcome.changed, try app_testing.commitDiscovery(
        &app,
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expectEqualStrings(roots.b, app.repoSessionView().activeRoot().?);
    try std.testing.expect(app.push_error_message == null);
}

test "undelivered push inspection completion releases its returned target" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);

    // The App retains only non-owning correlation metadata until its own
    // teardown; the undelivered Msg was the sole owner of the returned target.
    try std.testing.expect(app.push_retry.state == .inspecting);
}

test "direct root quit remains allowed while push inspection is running" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try app.update(.quit, &ctx);

    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(app.push_retry.state == .inspecting);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "push inspection surface blocks page switching until canceled" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    _ = app.pageCoordinator().activateReview();
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    try app.update(.{ .switch_page = .repository }, &ctx);

    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("close push error before switching pages", app.status.text());
    app.clearPushError(allocator);
    try deinitOnlyPushInspectionTaskForTest(&ctx, std.testing.io);
}

test "inactive Review accepts push inspection diagnostic without redraw" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    _ = app.pageCoordinator().activateReview();
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.active_page = .repository;
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.push_retry.state.availableTarget() != null);
    try std.testing.expectEqualStrings("could not verify push retry target", app.pages.review.status.text());
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "Review reactivation discards an old push inspection completion" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    _ = app.pageCoordinator().activateReview();
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, "/missing/repo"),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };

    try app.runInteractivePush(&ctx);
    app.pages.review.activation.deactivate();
    _ = app.pageCoordinator().activateReview();
    app.setReviewStatus("new Review activation", .{});
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expectEqualStrings("new Review activation", app.pages.review.status.text());
    try std.testing.expect(app.push_error_message == null);
    try std.testing.expect(!app.overlay.isPushError());
}

test "runInteractivePush queues foreground oid refspec and owns retry target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var app: App = .{ .allocator = allocator };
    defer app.clearPushForeground(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .set_upstream,
        .repo_root = try allocator.dupe(u8, repo.repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, repo.oid),
    }, true);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.runInteractivePush(&ctx);

    try std.testing.expect(app.push_retry.state == .inspecting);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expect(app.push_error_message == null);
    try std.testing.expect(app.push_retry.state == .foreground);
    try std.testing.expectEqual(page.Id.review, app.push_retry.state.foreground.origin.page_id);
    try std.testing.expectEqual(app.repo_session.repo_epoch, app.push_retry.state.foreground.origin.repo_epoch);
    const action_owner = app.actions.pending orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(app_actions.ActionKind.push, action_owner.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, action_owner.launch);
    try std.testing.expectEqual(action_owner.token.generation, app.push_retry.state.foreground.pending.generation);
    try std.testing.expectEqual(action_owner.token.kind, app.push_retry.state.foreground.pending.kind);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_foreground_commands_len);

    const entry = ctx._pending_foreground_commands[0..ctx._pending_foreground_commands_len][0];
    try std.testing.expectEqualStrings(repo.repo_root, entry.cwd.?);
    try std.testing.expectEqualStrings("git", entry.argv[0]);
    try std.testing.expectEqualStrings("push", entry.argv[1]);
    try std.testing.expectEqualStrings("origin", entry.argv[2]);
    try std.testing.expectEqual(@as(usize, 4), entry.argv.len);
    const expected_refspec = try std.fmt.allocPrint(allocator, "{s}:refs/heads/main", .{repo.oid});
    defer allocator.free(expected_refspec);
    try std.testing.expectEqualStrings(expected_refspec, entry.argv[3]);
}

test "runInteractivePush keeps retry target when foreground queue is full" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    defer ctx.runtimeClearPendingEffectCopies();

    const done = &struct {
        fn done(_: chasen.ForegroundCommandResult) App.Msg {
            return .quit;
        }
    }.done;
    _ = try ctx.terminal().runForegroundCommand(.{
        .argv = &.{ "sh", "-c", "true" },
        .cwd = repo.repo_root,
        .finished = done,
    });

    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo.repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, repo.oid),
    }, true);

    try app.runInteractivePush(&ctx);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.push_retry.state.credentialsAvailable());
    try std.testing.expect(app.overlay.isPushError());
    try std.testing.expectEqualStrings("interactive push already queued", app.pages.review.status.text());
}

test "runInteractivePush stale snapshot does not queue foreground command" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try setupPushRetryRepoForTest(allocator, io, &tmp);
    defer allocator.free(repo.repo_root);
    defer allocator.free(repo.oid);

    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo.repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "not-current"),
    }, false);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.runInteractivePush(&ctx);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.push_retry.state.availableTarget() != null);
    try std.testing.expectEqualStrings("push retry unavailable: branch changed; reload and try again", app.pages.review.status.text());
}

test "finishPushForeground reloads matching active repo after failure" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    const pending = beginAcceptedTestAction(&app, .push);
    app.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 9 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = app.repo_session.repo_epoch, .activation_id = app.pages.review.activation.next_activation_id },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 9 },
        .outcome = .{ .exited = 1 },
    });

    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("interactive push exited: 1", app.pages.review.status.text());
}

test "finishPushForeground ignores stale request id" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushForeground(allocator);
    defer app.actions.clear();

    const pending = beginAcceptedTestAction(&app, .push);
    app.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 2 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = app.repo_session.repo_epoch, .activation_id = app.pages.review.activation.next_activation_id },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 1 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.actions.pending != null);
    try std.testing.expect(app.push_retry.state == .foreground);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "finishPushForeground stale and duplicate terminals preserve newer action owner" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushForeground(allocator);
    defer app.actions.clear();
    app.pages.review.status.set("unchanged", .{});

    const stale = beginAcceptedTestAction(&app, .push);
    app.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 7 },
        .pending = stale,
        .origin = .{ .page_id = .review, .repo_epoch = app.repo_session.repo_epoch, .activation_id = app.pages.review.activation.next_activation_id },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    try std.testing.expect(app.acceptActionTerminal(stale));
    const current = app.actions.begin(.pull);
    app.acceptActionLaunch(current);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expect(app.actions.isAccepted(current));
    try std.testing.expectEqualStrings("unchanged", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expect(app.actions.isAccepted(current));
    try std.testing.expectEqualStrings("unchanged", app.pages.review.status.text());
    try std.testing.expect(app.acceptActionTerminal(current));
}

test "inactive Review foreground completions retain diagnostics without effects" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_session = .{
            .repo_epoch = 3,
        },
    };
    const pending = beginAcceptedTestAction(&app, .push);
    app.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 7 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = 3, .activation_id = 0 },
        .target = .{
            .mode = .upstream,
            .repo_root = try allocator.dupe(u8, "/repo"),
            .branch = try allocator.dupe(u8, "main"),
            .remote = try allocator.dupe(u8, "origin"),
            .remote_branch = try allocator.dupe(u8, "main"),
            .oid = try allocator.dupe(u8, "abc123"),
        },
    } };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.finishPushForeground(&ctx, .{
        .request_id = .{ .id = 7 },
        .outcome = .{ .exited = 1 },
    });

    try std.testing.expectEqualStrings("interactive push exited for /repo: 1", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());

    app.redraw_plan = .{};
    app.editor_foreground_request = .{
        .request_id = .{ .id = 8 },
        .origin = .{ .page_id = .review, .repo_epoch = 3, .activation_id = 0 },
    };
    try app.finishEditorCommand(&ctx, .{
        .request_id = .{ .id = 8 },
        .outcome = .{ .exited = 0 },
    });

    try std.testing.expectEqualStrings("editor closed", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.redraw_plan.resolvesToSkip());
}

test "push remote inspection rejects non-HTTPS and restores retry target" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "work", .default_dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);

    const init_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);
    const remote_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote", "add", "origin", "http://example.test/owner/repo.git" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(remote_result.stdout);
    allocator.free(remote_result.stderr);

    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, true);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.openPushCredentialPrompt(&ctx);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    try std.testing.expect(app.push_retry.state.availableTarget() != null);
    try std.testing.expect(app.push_retry.state.credentialPrompt() == null);
    try std.testing.expectEqualStrings("credential prompt is only available for HTTPS remotes", app.pages.review.status.text());
}

test "push remote inspection transfers HTTPS URL into credential prompt" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "work", .default_dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);

    const init_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);
    const remote_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote", "add", "origin", "https://example.test/owner/repo.git" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(remote_result.stdout);
    allocator.free(remote_result.stderr);

    var app: App = .{ .allocator = allocator };
    defer app.cancelPushCredentialPrompt(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, true);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };

    try app.openPushCredentialPrompt(&ctx);
    try runOnlyPushInspectionTaskForTest(&app, &ctx, io);

    const prompt = app.push_retry.state.credentialPrompt() orelse return error.ExpectedPushCredentialPrompt;
    try std.testing.expectEqualStrings("https://example.test/owner/repo.git", prompt.target.remote_url.?);
    try std.testing.expect(app.overlay.isPushCredentials());
    try std.testing.expect(app.push_error_message == null);
}

test "prompt allocation failure restores and later replaces owned remote URL" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "work", .default_dir);
    const repo_root = try tmp.dir.realPathFileAlloc(io, "work", allocator);
    defer allocator.free(repo_root);

    const init_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);
    const remote_result = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "remote", "add", "origin", "https://example.test/owner/repo.git" },
        .cwd = .{ .path = repo_root },
    });
    allocator.free(remote_result.stdout);
    allocator.free(remote_result.stderr);

    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    try app.setPushErrorWithRetry(allocator, "failed", .{
        .mode = .upstream,
        .repo_root = try allocator.dupe(u8, repo_root),
        .branch = try allocator.dupe(u8, "main"),
        .remote = try allocator.dupe(u8, "origin"),
        .remote_branch = try allocator.dupe(u8, "main"),
        .oid = try allocator.dupe(u8, "abc123"),
    }, true);

    var first_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.openPushCredentialPrompt(&first_ctx);
    const first_pending = first_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), first_pending.len);
    const first_msg = first_pending[0].run(first_pending[0].ctx, allocator, io);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var failing_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator(), ._io = io };
    try std.testing.expectError(error.OutOfMemory, app.update(first_msg, &failing_ctx));

    const restored = app.push_retry.state.availableTarget() orelse return error.ExpectedPushRetryTarget;
    const old_remote_url = restored.remote_url orelse return error.ExpectedRemoteUrl;
    try std.testing.expectEqualStrings("https://example.test/owner/repo.git", old_remote_url);
    try std.testing.expect(app.overlay.isPushError());

    var second_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.openPushCredentialPrompt(&second_ctx);
    try runOnlyPushInspectionTaskForTest(&app, &second_ctx, io);

    const prompt = app.push_retry.state.credentialPrompt() orelse return error.ExpectedPushCredentialPrompt;
    try std.testing.expectEqualStrings("https://example.test/owner/repo.git", prompt.target.remote_url.?);
    app.cancelPushCredentialPrompt(allocator);
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
        .commit_panel = app_commit_panel.State.init(std.testing.allocator),
    };
    defer app.commit_panel.deinit();
    defer app.cancelAmendConfirmation(std.testing.allocator);

    app.commit_panel.open(.amend);
    app.commit_panel.insert('x');
    try app.openAmendConfirmation(std.testing.allocator, "/repo");

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

test "selectedSidebarActionTarget resolves status-only path without loaded diff" {
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
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const target = app.reviewOperations().selectedSidebarActionTarget() orelse return error.ExpectedActionTarget;
    try std.testing.expectEqual(git_ops.TargetKind.file, target.kind);
    try std.testing.expectEqualStrings("src/new.zig", target.path);
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

test "selectedStageToggleOperation resolves directory operation from descendants" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{ .selected_node = 0 },
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
    acceptTestSource(&app);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00A  src/b\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    switch (app.reviewOperations().toggleStageTarget()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.stage, operation),
        else => return error.ExpectedDirectoryToggleStage,
    }

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "A  src/a\x00M  src/b\x00");
    try app.pages.review.git_status.replace("/repo", &staged_bundle);
    switch (app.reviewOperations().toggleStageTarget()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.unstage, operation),
        else => return error.ExpectedDirectoryToggleUnstage,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "UU src/a\x00");
    try app.pages.review.git_status.replace("/repo", &conflict_bundle);
    switch (app.reviewOperations().toggleStageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqual(TargetKind.directory, target.kind);
            try std.testing.expectEqualStrings("src", target.path);
        },
        else => return error.ExpectedDirectoryToggleConflict,
    }
}

test "selectedHunkUnstageTarget requires a visible session-staged hunk" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
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
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    acceptTestSource(&app);

    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedHunk,
    }

    try addCurrentTestSessionHunkMark(&app, std.testing.allocator, "/repo", "a", 0);
    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.patch.len > 0);
            try std.testing.expect(target.session_mark_mutation == .remove);
        },
        else => return error.ExpectedReadyHunkUnstageTarget,
    }

    app.pages.review.viewer.diff_scroll = 100;
    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .offscreen_cursor => {},
        else => return error.ExpectedOffscreenHunkUnstageTarget,
    }
}

test "selectedHunkUnstageTarget supports cached source without session mark" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
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

    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(SessionHunkMarkMutation.none, target.session_mark_mutation);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
        },
        else => return error.ExpectedCachedHunkUnstageTarget,
    }
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

const CanonicalPublicationAction = enum {
    stage_file,
    unstage_file,
    discard_file,
    commit,

    fn actionKind(self: CanonicalPublicationAction) app_actions.ActionKind {
        return switch (self) {
            .stage_file => .stage_file,
            .unstage_file => .unstage_file,
            .discard_file => .discard_file,
            .commit => .commit,
        };
    }
};

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

test "projected hunk actions route through original cached and unstaged origins" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
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
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);
    acceptTestSource(&app);

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

    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.unstage, operation),
        else => return error.ExpectedProjectedToggleUnstage,
    }
    switch (app.reviewOperations().selectedHunkStageTarget(std.testing.allocator)) {
        .already_staged_hunk => {},
        else => return error.ExpectedAlreadyStagedProjectedHunk,
    }
    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expectEqual(SessionHunkMarkMutation.none, target.session_mark_mutation);
        },
        else => return error.ExpectedReadyProjectedUnstage,
    }

    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 1 };
    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.stage, operation),
        else => return error.ExpectedProjectedToggleStage,
    }
    switch (app.reviewOperations().selectedHunkStageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(@as(usize, 1), target.hunk_index);
            try std.testing.expectEqual(SessionHunkMarkMutation.none, target.session_mark_mutation);
        },
        else => return error.ExpectedReadyProjectedStage,
    }
    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedProjectedHunk,
    }

    // Stage chrome and patch authority are separate contracts. A corrupt or
    // cross-generation-mismatched action origin must fail closed without
    // changing the fresh stage-state decision shown by the toggle UI.
    const live = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    @constCast(live.hunkActionOrigins())[1] = .{ .cached = 0 };
    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .operation => |operation| try std.testing.expectEqual(ToggleStageOperation.stage, operation),
        else => return error.ExpectedProjectedToggleStage,
    }
    switch (app.reviewOperations().selectedHunkStageTarget(std.testing.allocator)) {
        .no_hunk => {},
        else => return error.ExpectedMismatchedActionOriginToFailClosed,
    }

    @constCast(&live.authority.status_snapshot_revision).* +%= 1;
    try std.testing.expect(app.reviewOperations().selectedHunkToggleOperation() == .stale_status);
}

test "hunk stage presentation keeps fresh staged authority without clearing action marks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 10 },
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.review.git_status.deinit();
    acceptTestSource(&app);

    try addCurrentTestSessionHunkMark(&app, std.testing.allocator, "/repo", "a", 0);
    try addCurrentTestSessionHunkMark(&app, std.testing.allocator, "/repo", "a", 1);

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &staged_bundle);
    const presentation = try app.reviewNavigationView().hunkStagePresentation(arena.allocator(), 0);
    try std.testing.expect(presentation == .all_staged);

    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
        },
        else => return error.ExpectedReadyHunkUnstageTarget,
    }
}

test "hunk action results mutate session staged marks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.staged_hunks.deinit(allocator);
    acceptTestSource(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);
    const mark_key = try currentTestSessionHunkMarkKey(&app, 1);

    const stage_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try app.finishStageHunk(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .{ .add = mark_key },
        .result = .ok,
    });

    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.staged_hunks.items.items.len);

    const unstage_pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .{ .remove = mark_key },
        .result = .ok,
    });

    try std.testing.expect(!app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
}

test "hunk action none effect reloads status without adding a session mark" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    defer app.pages.review.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const stage_pending = beginAcceptedTestAction(&app, .stage_hunk);
    try app.finishStageHunk(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
    try std.testing.expect(app.pages.review.status_load.isPending());
}

test "hunk action none effect reloads status without removing a session mark" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    defer app.pages.review.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const mark_key = try currentTestSessionHunkMarkKey(&app, 1);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    const unstage_pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .result = .ok,
    });

    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.staged_hunks.items.items.len);
    try std.testing.expect(app.pages.review.status_load.isPending());
}

test "cached source hunk unstage reload decision travels with task result" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    _ = app.pageCoordinator().activateReview();
    defer app.pages.review.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    const mark_key = try currentTestSessionHunkMarkKey(&app, 1);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    const unstage_pending = beginAcceptedTestAction(&app, .unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .session_mark_mutation = .none,
        .reload_after_success = true,
        .result = .ok,
    });

    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));
    switch (app.pages.review.load.pending orelse return error.ExpectedReloadAfterCachedHunkUnstage) {
        .diff_load => {},
        .repo_discovery => return error.ExpectedReloadAfterCachedHunkUnstage,
    }
    try std.testing.expectEqual(@as(usize, 3), ctx._pending_tasks_with[0..ctx._pending_tasks_with_len].len);
}

test "clearLoadedDiff clears session staged hunk marks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .repo_session = .{
            .repo_state = .{ .discovery = .{ .single_repo = .{
                .label = "repo",
                .display_path = "/repo",
                .canonical_root = "/repo",
            } } },
        },
    };
    defer app.pages.review.staged_hunks.deinit(allocator);

    const mark_key = testSessionHunkMarkKey(1, 0);
    try app.pages.review.staged_hunks.addExact(allocator, "/repo", "a", mark_key);
    try std.testing.expect(app.pages.review.staged_hunks.containsExact("/repo", "a", mark_key));

    reviewReloadForTest(&app).clearLoadedDiff(app.allocator);

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
}

test "directory stage target uses sidebar cursor and status subtree" {
    var app: App = .{
        .pages = .{
            .review = .{
                .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
                .viewer = .{
                    // The diff pane still points at a file, but the sidebar cursor is
                    // on the directory. Directory actions must use the cursor target.
                    .selected_target = .{ .diff_file = 1 },
                    .selected_node = 0,
                },
            },
        },
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

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00?? src/b\x00M  other.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    switch (app.reviewOperations().stageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryStageTarget,
    }

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00");
    try app.pages.review.git_status.replace("/repo", &staged_bundle);
    switch (app.reviewOperations().stageTarget()) {
        .no_stageable_content => |path| try std.testing.expectEqualStrings("src", path),
        else => return error.ExpectedNoDirectoryStageableContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00UU src/b\x00");
    try app.pages.review.git_status.replace("/repo", &conflict_bundle);
    switch (app.reviewOperations().stageTarget()) {
        .conflict_unsupported => |path| try std.testing.expectEqualStrings("src", path),
        else => return error.ExpectedDirectoryConflictStageReject,
    }
}

test "directory unstage target scans staged subtree" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
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
    acceptTestSource(&app);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00AM src/b\x00 M other.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    switch (app.reviewOperations().unstageTarget()) {
        .ready => |target| {
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryUnstageTarget,
    }

    var unstaged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a\x00?? src/b\x00");
    try app.pages.review.git_status.replace("/repo", &unstaged_bundle);
    switch (app.reviewOperations().unstageTarget()) {
        .no_staged_content => |target| {
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedNoDirectoryStagedContent,
    }

    var conflict_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  src/a\x00UU src/b\x00");
    try app.pages.review.git_status.replace("/repo", &conflict_bundle);
    switch (app.reviewOperations().unstageTarget()) {
        .conflict_unsupported => |target| {
            try std.testing.expectEqualStrings("src", target.path);
            try std.testing.expect(target.kind == .directory);
        },
        else => return error.ExpectedDirectoryConflictUnstageReject,
    }
}

fn abandonSingleQueuedAction(app: *App, ctx: *chasen.Ctx(App.Msg)) !void {
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const message = entries[0].failed(entries[0].ctx, .runtime_abandoned, ctx.allocator());
    try app.update(message, ctx);

    const revalidation = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 3), revalidation.len);
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(revalidation[0].ctx));
    const branch_task: *BranchStatusLoadTask = @ptrCast(@alignCast(revalidation[1].ctx));
    const source_task: *DiffLoadTask = @ptrCast(@alignCast(revalidation[2].ctx));
    const status_terminal: app_auto_reload.AuxiliaryTerminal = .{
        .generation = status_task.generation,
        .read_epoch = status_task.read_epoch,
        .background_cycle_id = status_task.background_cycle_id,
    };
    const branch_terminal: app_auto_reload.AuxiliaryTerminal = .{
        .generation = branch_task.generation,
        .read_epoch = branch_task.read_epoch,
        .background_cycle_id = branch_task.background_cycle_id,
    };
    const source_generation = source_task.generation;

    for (revalidation) |entry| {
        var completion = entry.failed(
            entry.ctx,
            .runtime_abandoned,
            ctx.allocator(),
        );
        completion.deinitUndelivered(ctx.allocator());
    }

    _ = reviewReloadForTest(&app).rejectSourceSpawn(ctx.allocator(), source_generation);
    _ = app.pages.review.status_load.finishTerminal(status_terminal);
    _ = app.pages.review.branch_status_load.finishTerminal(branch_terminal);
    app.pages.review.status_load.markSuccess();
    app.pages.review.branch_status_load.markSuccess();
    app.pages.review.canonical_status_drain = null;
    syncTestActivation(app);
}

test "stage unstage and discard launch typed action cursor owners with task generations" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffNested()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_node = 0,
            },
        } },
        .repo_session = .{
            .repo_state = .{ .discovery = try testSingleRepoDiscovery(allocator, roots.a) },
        },
    };
    app.repo_session.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer app.repo_session.repo_state.deinit(allocator);
    defer reviewReloadForTest(&app).clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.reviewNavigation().clearActionCursor(allocator);
    acceptTestSource(&app);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    var stageable = try git_status.StatusBundle.parseOwned(allocator, " M src/a\x00?? src/b\x00");
    try app.pages.review.git_status.replace(roots.a, &stageable);
    try app.stageSelectedFile(&ctx);
    const stage_pending = app.actions.pending orelse return error.ExpectedStageAction;
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, stage_pending.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, stage_pending.launch);
    try std.testing.expectEqual(stage_pending.token.generation, app.pages.review.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.directory, app.pages.review.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("src", app.pages.review.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());

    var staged = try git_status.StatusBundle.parseOwned(allocator, "M  src/a\x00M  src/b\x00");
    try app.pages.review.git_status.replace(roots.a, &staged);
    try app.unstageSelectedFile(&ctx);
    const unstage_pending = app.actions.pending orelse return error.ExpectedUnstageAction;
    try std.testing.expectEqual(app_actions.ActionKind.unstage_file, unstage_pending.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, unstage_pending.launch);
    try std.testing.expectEqual(unstage_pending.token.generation, app.pages.review.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.directory, app.pages.review.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("src", app.pages.review.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());

    app.discard_confirmation = .{
        .repo_root = try allocator.dupe(u8, roots.a),
        .path = try allocator.dupe(u8, "src/a"),
    };
    app.overlay.openDiscardFile();
    try app.confirmDiscardFile(&ctx);
    const discard_pending = app.actions.pending orelse return error.ExpectedDiscardAction;
    try std.testing.expectEqual(app_actions.ActionKind.discard_file, discard_pending.token.kind);
    try std.testing.expectEqual(app_actions.ActionLaunchPhase.accepted, discard_pending.launch);
    try std.testing.expectEqual(discard_pending.token.generation, app.pages.review.action_cursor.actionGeneration().?);
    try std.testing.expectEqual(review_page.action_cursor.TargetKind.file, app.pages.review.action_cursor.target().?.kind);
    try std.testing.expectEqualStrings("src/a", app.pages.review.action_cursor.target().?.path_key);
    try abandonSingleQueuedAction(&app, &ctx);
    try std.testing.expect(!app.pages.review.action_cursor.hasOwner());
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

test "fresh status-only targets fail closed without accepted source" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
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
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "AM src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try reviewReloadForTest(&app).createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);

    try std.testing.expectEqual(git_ops.StageTargetResult.stale_source, app.reviewOperations().stageTarget());
    try std.testing.expectEqual(git_ops.UnstageTargetResult.stale_source, app.reviewOperations().unstageTarget());
    try std.testing.expectEqual(git_ops.DiscardTargetResult.stale_source, app.reviewOperations().discardTarget());
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

fn testSessionHunkMarkKey(source_session_revision: u64, display_hunk_index: usize) git_ops.SessionHunkMarkKey {
    return .{
        .content = .{
            .repo_epoch = 0,
            .root_identity = null,
            .source = review_selection_model.SourceBasis.init(.unstaged),
            .source_session_revision = source_session_revision,
            .display = .{ .loaded = .init("test diff") },
        },
        .display_hunk_index = display_hunk_index,
    };
}

fn currentTestSessionHunkMarkKey(app: *const App, display_hunk_index: usize) !git_ops.SessionHunkMarkKey {
    return .{
        .content = app.reviewNavigationView().currentContentToken() orelse return error.ExpectedReviewContentToken,
        .display_hunk_index = display_hunk_index,
    };
}

fn addCurrentTestSessionHunkMark(
    app: *App,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    path: []const u8,
    display_hunk_index: usize,
) !void {
    try app.pages.review.staged_hunks.addExact(
        allocator,
        repo_root,
        path,
        try currentTestSessionHunkMarkKey(app, display_hunk_index),
    );
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

fn clearPendingStatusTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    // finishStageHunk queues a status refresh. These tests assert the App-side
    // state transition only, so clean up the queued task context explicitly.
    for (ctx.takePendingTasksWith()) |entry| {
        const task: *StatusLoadTask = @ptrCast(@alignCast(entry.ctx));
        allocator.free(task.repo_root);
        allocator.destroy(task);
    }
}

fn clearPendingRepositoryTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

fn clearPendingBranchListTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        const task: *BranchListLoadTask = @ptrCast(@alignCast(entry.ctx));
        allocator.free(task.repo_root);
        allocator.destroy(task);
    }
}

fn clearPendingStatusAndDiffTasks(ctx: *chasen.Ctx(App.Msg), allocator: std.mem.Allocator) void {
    for (ctx.takePendingTasksWith()) |entry| {
        var message = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        message.deinitUndelivered(allocator);
    }
}

const BranchListItemSpec = struct {
    name: []const u8,
    oid: []const u8,
    current: bool = false,
};

fn branchListForTest(allocator: std.mem.Allocator, specs: []const BranchListItemSpec) !app_load.BranchListLoadTaskResult {
    const items = try allocator.alloc(git_backend.BranchListItem, specs.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
    }
    for (specs, 0..) |spec, index| {
        const full_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{spec.name});
        errdefer allocator.free(full_ref);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const oid = try allocator.dupe(u8, spec.oid);
        errdefer allocator.free(oid);
        items[index] = .{
            .full_ref = full_ref,
            .name = name,
            .kind = .local,
            .oid = oid,
            .current = spec.current,
        };
        initialized += 1;
    }
    return .{ .loaded = .{ .branches = items } };
}

fn branchSwitchItemsForTest(allocator: std.mem.Allocator, specs: []const BranchListItemSpec) ![]app_state.BranchSwitchItem {
    const items = try allocator.alloc(app_state.BranchSwitchItem, specs.len);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer {
        for (items[0..initialized]) |*item| item.deinit(allocator);
    }
    for (specs, 0..) |spec, index| {
        items[index] = .{
            .name = try allocator.dupe(u8, spec.name),
            .oid = try allocator.dupe(u8, spec.oid),
            .current = spec.current,
        };
        initialized += 1;
    }
    return items;
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
