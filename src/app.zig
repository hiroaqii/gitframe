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
const ai_reviews_page = @import("app/pages/ai_reviews.zig");
const ai_reviews_coordinator = @import("app/pages/ai_reviews/coordinator.zig");
const ai_reviews_input = @import("app/pages/ai_reviews/input.zig");
const ai_reviews_navigation = @import("app/pages/ai_reviews/navigation.zig");
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
const repo_session = @import("app/repo_session.zig");
const app_state = @import("app/state.zig");
const app_view = @import("app/view.zig");
const action_lifecycle = @import("app/workflow/action_lifecycle.zig");
const workflow_local = @import("app/workflow/local.zig");
const workflow_remote = @import("app/workflow/remote.zig");
const shell_effects = @import("app/shell_effects.zig");
const human_review_session_mod = @import("app/human_review_session.zig");
const review_store_operations_mod = @import("app/review_store_operations.zig");
const context = @import("context.zig");
const config_mod = @import("config.zig");
const diff_surface = @import("app/diff_surface.zig");
const diff_render = @import("diff/render.zig");
const diff_selection = @import("diff/selection.zig");
const diff_source = @import("diff/source.zig");
const keymap = @import("keymap");
const theme = @import("theme");
const review_store = @import("review_store.zig");
const committed_review = @import("committed_review.zig");

const auto_reload_timer_id = "gitframe.auto_reload";
const CliConfig = diff_source.CliConfig;

const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const LoadFinishedMsg = app_message.LoadFinished;
const ActionFinishedMsg = app_message.ActionFinished;
const ShellEffectFinishedMsg = app_message.ShellEffectFinished;

comptime {
    if (human_review_session_mod.max_detached_sessions != review_store_operations_mod.max_active_runs) {
        @compileError("human Review recovery and mutation queue capacities must remain equal");
    }
}

const PageStates = struct {
    changes: changes_page.ChangesPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    history: history_page.HistoryPageState = .{},
    compare: compare_page.ComparePageState = .{},
    ai_reviews: ai_reviews_page.AiReviewsPageState = .{},
    config: page.LazyPlaceholder = .{},
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

pub const HumanReviewSaveOutcome = union(enum) {
    no_change,
    accepted: app_message.ReviewStoreOperationId,
    rejected: human_review_session_mod.AdmissionFailure,
};

pub const HumanReviewFinalizeOutcome = union(enum) {
    accepted: struct {
        draft_operation_id: ?app_message.ReviewStoreOperationId,
        result_operation_id: app_message.ReviewStoreOperationId,
    },
    rejected: human_review_session_mod.AdmissionFailure,
};

pub const App = struct {
    active_page: page.Id = .changes,
    repo_session: repo_session.State = .{},
    pages: PageStates = .{},
    config: CliConfig = .{},
    user_config: config_mod.Config = .{},
    configured_review_store: ?review_store.ConfiguredStore = null,
    keymap: keymap.Effective = .{},
    theme: theme.Palette = .default(),
    env_map: ?*std.process.Environ.Map = null,
    /// Absolute running executable path borrowed from the startup arena.
    /// Failure to resolve it is represented by `null` in the handoff modal.
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
    overlay: app_state.OverlayState = .{},
    shell_effects_state: shell_effects.State = .{},
    human_review_sessions: human_review_session_mod.Owner = .{},
    review_store_operations: review_store_operations_mod.Owner = .{},
    /// Retains the user's quit intent after Store drain success until the
    /// existing Git action lifecycle is also terminal.
    quit_after_store_drain: bool = false,
    drag_auto_scroll: drag_auto_scroll.State = .{},
    command_session: CommandSession = .inactive,

    const PopupCopyTarget = struct {
        label: []const u8,
        text: []const u8,
    };

    pub const Msg = app_message.Msg;

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
        self.configured_review_store = try review_store.ConfiguredStore.init(
            ctx.allocator(),
            self.user_config.ai_review.store_root,
            self.env_map,
        );
        self.local_workflow = workflow_local.LocalState.init(ctx.allocator());
        self.pages.changes.init(self.config.auto_reload, self.user_config.reload, self.config.source);
        _ = self.pageCoordinator().activateChanges();
        if (self.pages.changes.auto_reload.enabled()) {
            try ctx.timer().every(auto_reload_timer_id, self.pages.changes.auto_reload.interval_ns, .auto_reload_tick);
        }
        if (diff_source.sourceRequiresRepo(self.config.source)) {
            try self.changesRead().startRepoDiscovery(ctx, null);
        } else {
            try self.changesRead().startDiffLoad(ctx, .initial);
        }
    }

    pub fn deinit(self: *App, deinit_ctx: chasen.AppDeinitContext) void {
        if (self.allocator == null) self.allocator = deinit_ctx.allocator;
        self.pages.changes.deinit(deinit_ctx.allocator);
        self.pages.repository.deinit(deinit_ctx.allocator);
        self.pages.history.deinit(deinit_ctx.allocator);
        self.pages.compare.deinit(deinit_ctx.allocator);
        self.pages.ai_reviews.deinit(deinit_ctx.allocator);
        if (self.configured_review_store) |*store| store.deinit(deinit_ctx.allocator);
        self.repo_session.deinit(deinit_ctx.allocator);
        self.local_workflow.deinit(deinit_ctx.allocator);
        self.remote_workflow.deinit(deinit_ctx.allocator);
        self.shell_effects_state.deinit(deinit_ctx.allocator);
        self.review_store_operations.deinit(deinit_ctx.allocator);
        self.human_review_sessions.deinit();
    }

    /// Prepare, checked-admit, and infallibly track the current session's
    /// complete working snapshot before starting Store work.
    pub fn saveHumanReviewSession(
        self: *App,
        ctx: *chasen.Ctx(Msg),
    ) !HumanReviewSaveOutcome {
        const session = self.human_review_sessions.currentSession() orelse
            return error.NoHumanReviewSession;
        if (self.aiReviewDeletionHolds(session.binding)) return .{ .rejected = .admission_closed };
        const token = self.review_store_operations.queueToken(session.binding);
        const preparation = session.prepareSave(ctx.allocator(), token, .dirty_only) catch |err| {
            self.recordHumanReviewPreparationFailure(ctx, session, &token, .draft, null, err);
            return err;
        };
        switch (preparation) {
            .no_change => return .no_change,
            .ready => |value| {
                var prepared = value;
                defer prepared.deinit();
                const store = if (self.configured_review_store) |*configured| configured else {
                    session.rejectDraft(&prepared, .store_unavailable);
                    return .{ .rejected = .store_unavailable };
                };
                if (!store.isConfigured()) {
                    session.rejectDraft(&prepared, .store_unavailable);
                    return .{ .rejected = .store_unavailable };
                }
                const admission = try self.enqueuePreparedHumanReviewDraft(
                    ctx.allocator(),
                    store,
                    session,
                    &prepared,
                );
                switch (admission) {
                    .rejected => |reason| {
                        const mapped = mapHumanReviewAdmissionFailure(reason);
                        session.rejectDraft(&prepared, mapped);
                        return .{ .rejected = mapped };
                    },
                    .accepted => |accepted| {
                        session.commitDraft(
                            &prepared,
                            accepted.operation_id,
                            accepted.superseded_operation_id,
                        );
                        self.pumpReviewStoreOperations(ctx);
                        return .{ .accepted = accepted.operation_id };
                    },
                }
            },
        }
    }

    /// Admit an optional exact draft followed by one result bound to the
    /// revision that draft is guaranteed to commit. Pumping happens only
    /// after every accepted operation has an infallible session ledger entry.
    pub fn finalizeHumanReviewSession(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        decision: @import("committed_review.zig").ReviewResultValue,
    ) !HumanReviewFinalizeOutcome {
        const session = self.human_review_sessions.currentSession() orelse
            return error.NoHumanReviewSession;
        if (self.aiReviewDeletionHolds(session.binding)) return .{ .rejected = .admission_closed };
        const store = if (self.configured_review_store) |*value| value else {
            session.markAdmissionFailure(.result, decision, .store_unavailable);
            return .{ .rejected = .store_unavailable };
        };
        if (!store.isConfigured()) {
            session.markAdmissionFailure(.result, decision, .store_unavailable);
            return .{ .rejected = .store_unavailable };
        }

        var draft_operation_id: ?app_message.ReviewStoreOperationId = null;
        var pump_on_return = false;
        defer if (pump_on_return) self.pumpReviewStoreOperations(ctx);

        const draft_token = self.review_store_operations.queueToken(session.binding);
        const draft_preparation = session.prepareSave(
            ctx.allocator(),
            draft_token,
            .ensure_persisted,
        ) catch |err| {
            self.recordHumanReviewPreparationFailure(ctx, session, &draft_token, .draft, decision, err);
            return err;
        };
        switch (draft_preparation) {
            .no_change => {},
            .ready => |value| {
                var prepared = value;
                defer prepared.deinit();
                const admission = try self.enqueuePreparedHumanReviewDraft(
                    ctx.allocator(),
                    store,
                    session,
                    &prepared,
                );
                switch (admission) {
                    .rejected => |reason| {
                        const mapped = mapHumanReviewAdmissionFailure(reason);
                        session.rejectDraft(&prepared, mapped);
                        return .{ .rejected = mapped };
                    },
                    .accepted => |accepted| {
                        session.commitDraft(
                            &prepared,
                            accepted.operation_id,
                            accepted.superseded_operation_id,
                        );
                        draft_operation_id = accepted.operation_id;
                        pump_on_return = true;
                    },
                }
            },
        }

        const result_token = self.review_store_operations.queueToken(session.binding);
        var prepared_result = session.prepareResult(
            ctx.allocator(),
            result_token,
            decision,
        ) catch |err| {
            self.recordHumanReviewPreparationFailure(ctx, session, &result_token, .result, decision, err);
            return err;
        };
        defer prepared_result.deinit();
        const result_admission = try self.enqueuePreparedHumanReviewResult(
            ctx.allocator(),
            store,
            session,
            &prepared_result,
        );
        return switch (result_admission) {
            .rejected => |reason| blk: {
                const mapped = mapHumanReviewAdmissionFailure(reason);
                session.rejectResult(&prepared_result, mapped);
                break :blk .{ .rejected = mapped };
            },
            .accepted => |accepted| blk: {
                session.commitResult(
                    &prepared_result,
                    accepted.operation_id,
                );
                pump_on_return = true;
                break :blk .{ .accepted = .{
                    .draft_operation_id = draft_operation_id,
                    .result_operation_id = accepted.operation_id,
                } };
            },
        };
    }

    /// Test-only raw bridge retained for mutation-owner discrimination.
    fn persistReviewDraft(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        request: review_store.DraftSaveRequest,
    ) !review_store_operations_mod.Admission {
        if (self.aiReviewDeletionHolds(request.binding)) return .{ .rejected = .admission_closed };
        const store = if (self.configured_review_store) |*value| value else return .{ .rejected = .store_unavailable };
        if (!store.isConfigured()) return .{ .rejected = .store_unavailable };
        const admission = try self.review_store_operations.enqueueDraft(
            ctx.allocator(),
            store,
            self.repoSessionView().activeCapability(),
            self.env_map,
            request,
        );
        self.pumpReviewStoreOperations(ctx);
        return admission;
    }

    /// Admit create-once completion behind any accepted draft for the Run.
    fn persistReviewResult(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        request: review_store.ReviewResultCreateRequest,
    ) !review_store_operations_mod.Admission {
        if (self.aiReviewDeletionHolds(request.binding)) return .{ .rejected = .admission_closed };
        const store = if (self.configured_review_store) |*value| value else return .{ .rejected = .store_unavailable };
        if (!store.isConfigured()) return .{ .rejected = .store_unavailable };
        const admission = try self.review_store_operations.enqueueResult(
            ctx.allocator(),
            store,
            self.repoSessionView().activeCapability(),
            self.env_map,
            request,
        );
        self.pumpReviewStoreOperations(ctx);
        return admission;
    }

    fn repoSessionView(self: *const App) repo_session.View {
        return self.repo_session.view();
    }

    fn aiReviewDeletionHolds(self: *const App, binding: review_store.ReviewRunBinding) bool {
        return self.pages.ai_reviews.delete_confirmation.holdsRun(
            binding.review_repository_id,
            binding.review_id,
        );
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
            .action_pending = self.actionLifecycleView().hasPending() or
                self.pages.ai_reviews.delete_confirmation.isOpen(),
            .changes = self.changesRead().repositorySessionPort(),
            .repository = .{ .page = &self.pages.repository },
            .history = .{ .page = &self.pages.history },
            .compare = .{ .page = &self.pages.compare },
            .ai_reviews = .{ .page = &self.pages.ai_reviews },
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

    fn aiReviewsCoordinator(self: *App) ai_reviews_coordinator.Controller {
        const body_size = self.shellLayout().bodySize();
        return .{
            .page_state = &self.pages.ai_reviews,
            .repo = self.repoSessionView(),
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.ai_reviews),
            .env_map = self.env_map,
            .store = if (self.configured_review_store) |*value| value else null,
            .sessions = &self.human_review_sessions,
            .operations = &self.review_store_operations,
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
            .executable_path = self.executable_path,
            .handoff_overlay_size = self.shellLayout().contentSize(),
        };
    }

    fn humanReviewPresentation(self: *const App) ?human_review_session_mod.Presentation {
        const selected = self.pages.ai_reviews.selectedRunConst() orelse return null;
        const presentation = self.human_review_sessions.currentPresentation() orelse return null;
        if (!selected.binding().eql(presentation.binding)) return null;
        return presentation;
    }

    fn pageCoordinator(self: *App) page_coordinator.Controller {
        return .{
            .active_page = &self.active_page,
            .changes = &self.pages.changes,
            .repository = &self.pages.repository,
            .history = &self.pages.history,
            .compare = &self.pages.compare,
            .ai_reviews = &self.pages.ai_reviews,
            .config_page = &self.pages.config,
            .repo = self.repoSessionView(),
            .source = self.config.source,
            .body_size = self.shellLayout().bodySize(),
            .status = &self.status,
            .shell_blockers = .{
                .help = self.overlay.isHelp(),
                .commit_input = self.localWorkflowView().commitPanelOpen(),
                .confirmation = self.overlay.isDiscardFile() or self.overlay.isAmendCommit() or
                    self.overlay.isPushBranch() or self.overlay.isPullBranch() or
                    self.pages.ai_reviews.delete_confirmation.isOpen(),
                .branch_switch = self.overlay.isSwitchBranch(),
                .push_error = self.overlay.isPushError(),
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
            .history_refresh => try self.historyCoordinator().startPending(ctx),
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
            .ai_reviews => !self.pages.ai_reviews.diff.search.mode and
                !self.pages.ai_reviews.diff.file_search.mode and
                !self.pages.ai_reviews.picker.isPickerVisible(),
            .history => self.pages.history.current_view == .diff and
                !self.pages.history.diff.search.mode and
                !self.pages.history.diff.file_search.mode,
            .repository, .config => false,
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
            .user_config = &self.user_config,
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
            .repo = self.repoSessionView(),
            .current_changes_root = self.currentChangesActionRoot(),
            .env_map = self.env_map,
            .active_page = self.active_page,
            .changes_origin = origins.changes(),
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
        const ai_reviews_identity = self.pages.ai_reviews.activation.currentIdentity();
        return .{
            .snapshot = .{
                .active_page = self.active_page,
                .repo_epoch = repo_epoch,
                .changes_activation_id = self.pages.changes.activation.next_activation_id,
                .repository_activation_id = self.pages.repository.activation_id,
                .history_activation_id = self.pages.history.activation.next_activation_id,
                .compare_activation_id = self.pages.compare.activation.next_activation_id,
                .ai_reviews_activation_id = self.pages.ai_reviews.activation.next_activation_id,
                .push_error_instance_id = if (self.overlay.isPushError()) self.overlay.push_error_instance_id else null,
                .commit_panel_instance_id = self.localWorkflowView().commitPanelInstanceId(),
                .compare_ai_review_handoff = if (self.pages.compare.ai_review_handoff.currentCopyAuthority()) |authority| .{
                    .modal_instance_id = authority.modal_instance_id,
                    .copy_generation = authority.copy_generation,
                } else null,
            },
            .changes_repo_epoch = if (changes_identity) |identity| identity.repo_epoch else repo_epoch,
            .repository_repo_epoch = self.pages.repository.repo_epoch,
            .history_repo_epoch = if (history_identity) |identity| identity.repo_epoch else self.pages.history.repo_epoch,
            .compare_repo_epoch = if (compare_identity) |identity| identity.repo_epoch else repo_epoch,
            .ai_reviews_repo_epoch = if (ai_reviews_identity) |identity| identity.repo_epoch else repo_epoch,
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
                .compare_ai_review_handoff = self.pages.compare.ai_review_handoff.statusMessage(),
                .ai_reviews = &self.pages.ai_reviews.status,
            },
            .redraw = .{ .skip_requested = &self.redraw_plan.skip_requested },
        };
    }

    fn currentChangesActionRoot(self: *const App) ?[]const u8 {
        if (self.active_page != .changes or
            self.pages.changes.activation.currentIdentity() == null or
            diff_source.sourceIsOneShotInput(self.config.source)) return null;
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

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        self.redraw_plan = .{};
        defer if (self.redraw_plan.resolvesToSkip()) ctx.redraw().skip();
        defer self.reconcileDragAutoScroll(ctx);
        self.clearEphemeralStatusForUserAction(msg);

        switch (msg) {
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
                const changes_selection_anchor = self.changesNavigation().captureSelectionViewportAnchor();
                const previous_compare_view = self.compareCoordinator().navigationView();
                var previous_compare_resolver = previous_compare_view.resolver();
                const previous_compare_body = previous_compare_view.bodyView(&previous_compare_resolver);
                const compare_selection_anchor = previous_compare_body.captureSelectionViewportAnchor();
                const previous_ai_reviews_base_view = self.aiReviewsCoordinator().navigationView();
                const resize_allocator = self.allocator;
                var previous_ai_reviews_frame = if (resize_allocator) |allocator|
                    try previous_ai_reviews_base_view.buildFindingCardFrame(allocator)
                else
                    null;
                defer if (previous_ai_reviews_frame) |*frame| frame.deinit(resize_allocator.?);
                const previous_ai_reviews_view = previous_ai_reviews_base_view.withPresentationRows(
                    if (previous_ai_reviews_frame) |*frame| &frame.presentation_rows else null,
                );
                var previous_ai_reviews_adapter = previous_ai_reviews_view.resolver();
                const previous_ai_reviews_body = previous_ai_reviews_view.bodyView(&previous_ai_reviews_adapter);
                const ai_reviews_selection_anchor = previous_ai_reviews_body.captureSelectionViewportAnchor();
                const repository_selection_anchor = self.pages.repository.captureSelectionViewportAnchor();
                const previous_width = self.changesNavigationView().diffPaneWidth();
                const previous_mode = self.changesNavigationView().effectiveDisplayMode();
                const previous_compare_width = previous_compare_body.view.diffPaneWidth();
                const previous_compare_mode = previous_compare_body.view.effectiveDisplayMode();
                const previous_ai_reviews_width = previous_ai_reviews_body.view.diffPaneWidth();
                const previous_ai_reviews_display_mode = previous_ai_reviews_body.view.effectiveDisplayMode();
                var incoming_ai_reviews_preparation = if (resize_allocator) |allocator|
                    try previous_ai_reviews_base_view.prepareFindingCardFrame(allocator)
                else
                    null;
                defer if (incoming_ai_reviews_preparation) |*preparation| preparation.deinit();

                self.drag_auto_scroll.clear();
                self.changesNavigation().clearMouseDiffSelection();
                if (self.pages.compare.diff.selection_owner.activeMouseSelection()) {
                    self.pages.compare.diff.selection_owner = .none;
                }
                if (self.pages.history.diff.selection_owner.activeMouseSelection()) {
                    self.pages.history.diff.selection_owner = .none;
                }
                if (self.pages.ai_reviews.diff.selection_owner.activeMouseSelection()) {
                    self.pages.ai_reviews.diff.selection_owner = .none;
                }
                self.pages.repository.cancelMouseOwner();
                self.terminal_size = size;
                self.compareCoordinator().clampAiReviewHandoffViewport();
                self.changesNavigation().resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
                if (previous_mode != self.changesNavigationView().effectiveDisplayMode()) {
                    self.changesNavigation().clearMouseDiffSelection();
                    self.changesNavigation().clearKeyboardSideChoice();
                    self.pages.changes.advanceSelectionLayoutRevision();
                }
                if (changes_selection_anchor) |anchor| self.changesNavigation().restoreSelectionViewportAnchor(anchor);
                self.changesNavigation().clampSidebarHorizontalScroll();
                self.changesNavigation().clampDiffNavigationKeepingHunkVisible();
                self.changesNavigation().updateSearchMatchOffset();
                self.changesNavigation().scrollSearchMatchIntoView();
                self.changesNavigation().clampDiffNavigation();
                var compare_adapter = self.compareCoordinator().navigation().updateAdapter();
                var compare_body = compare_adapter.bodyController();
                compare_body.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_compare_width);
                if (previous_compare_mode != compare_body.controller.view().effectiveDisplayMode()) {
                    compare_body.controller.clearMouseDiffSelection();
                    compare_body.controller.clearKeyboardSideChoice();
                    self.pages.compare.diff.advanceSelectionLayoutRevision();
                }
                if (compare_selection_anchor) |anchor| compare_body.restoreSelectionViewportAnchor(anchor);
                compare_body.controller.clampSidebarHorizontalScroll();
                compare_body.clampDiffNavigationKeepingHunkVisible();
                compare_body.updateSearchMatchOffset();
                compare_body.controller.scrollSearchMatchIntoView();
                compare_body.clampDiffNavigation();
                self.aiReviewsCoordinator().reconcileFindingCardVisibility();
                const current_ai_reviews_view = self.aiReviewsCoordinator().navigationView();
                var current_ai_reviews_frame = if (incoming_ai_reviews_preparation) |*preparation|
                    preparation.fill(current_ai_reviews_view, self.pages.ai_reviews.finding_card)
                else
                    null;
                var ai_reviews_controller = self.aiReviewsCoordinator().navigation();
                ai_reviews_controller.presentation_rows = if (current_ai_reviews_frame) |*frame| &frame.presentation_rows else null;
                var ai_reviews_adapter = ai_reviews_controller.updateAdapter();
                var ai_reviews_body = ai_reviews_adapter.bodyController();
                ai_reviews_body.controller.resetDiffHorizontalScrollIfPaneWidthChanged(previous_ai_reviews_width);
                if (previous_ai_reviews_display_mode != ai_reviews_body.controller.view().effectiveDisplayMode()) {
                    ai_reviews_body.controller.clearMouseDiffSelection();
                    ai_reviews_body.controller.clearKeyboardSideChoice();
                    self.pages.ai_reviews.advanceSelectionLayoutRevision();
                }
                if (ai_reviews_selection_anchor) |anchor| ai_reviews_body.restoreSelectionViewportAnchor(anchor);
                ai_reviews_body.controller.clampSidebarHorizontalScroll();
                ai_reviews_body.clampDiffNavigationKeepingHunkVisible();
                ai_reviews_body.updateSearchMatchOffset();
                ai_reviews_body.controller.scrollSearchMatchIntoView();
                ai_reviews_body.clampDiffNavigation();
                const repository_body_size = self.shellLayout().bodySize();
                if (repository_selection_anchor) |anchor|
                    self.pages.repository.restoreSelectionViewportAnchor(anchor, repository_body_size)
                else
                    self.pages.repository.clampForBodySize(repository_body_size);
                self.pages.history.catalog.clamp(@import("app/pages/history/catalog.zig").visibleRows(repository_body_size.height));
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
            .review_store_operation_finished => |finished| self.finishReviewStoreOperation(ctx, finished),
            .ai_review_delete_finished => |finished| {
                if (try self.aiReviewsCoordinator().finishDelete(ctx, finished) == .skip) {
                    self.redraw_plan.requestSkip();
                }
            },
            .changes => |changes_msg| _ = try self.updateChanges(ctx, changes_msg),
            .compare => |compare_msg| _ = try self.updateCompare(ctx, compare_msg),
            .ai_reviews => |ai_reviews_msg| _ = try self.updateAiReviews(ctx, ai_reviews_msg),
            .repository => |repository_msg| _ = self.updateRepository(ctx, repository_msg),
            .history => |history_msg| _ = try self.updateHistory(ctx, history_msg),
            .command_line => |command_msg| self.updateCommandLine(command_msg),
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
                if (self.active_page == .repository) {
                    self.pages.repository.clearLiveSelectionPreservingViewport(self.shellLayout().bodySize());
                }
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
                if (self.active_page == .changes) self.changesNavigation().clearMouseDiffSelection();
                if (self.active_page == .compare and self.pages.compare.diff.selection_owner.activeMouseSelection()) {
                    self.pages.compare.diff.selection_owner = .none;
                }
                if (self.active_page == .history and self.pages.history.diff.selection_owner.activeMouseSelection()) {
                    self.pages.history.diff.selection_owner = .none;
                }
                if (self.active_page == .ai_reviews and self.pages.ai_reviews.diff.selection_owner.activeMouseSelection()) {
                    self.pages.ai_reviews.diff.selection_owner = .none;
                }
                if (self.active_page == .repository) {
                    self.pages.repository.clearLiveSelectionPreservingViewport(self.shellLayout().bodySize());
                }
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
                .changes => {
                    switch (self.changesRead().prepareManualReload()) {
                        .blocked => {},
                        .ready => {
                            self.remoteWorkflow().clearBranchSwitch(ctx.allocator());
                            try self.changesRead().startPreparedManualReload(ctx);
                        },
                    }
                },
                .repository => self.repositoryCoordinator().requestReload(),
                .history => self.historyCoordinator().refresh(),
                .compare => try self.compareCoordinator().refresh(ctx),
                .ai_reviews => try self.aiReviewsCoordinator().refresh(ctx),
                .config => self.status.set("reload is not available on this page yet", .{}),
            },
            .auto_reload_tick => try self.changesRead().autoReloadTick(ctx),
            .focus_lost => {
                self.drag_auto_scroll.clear();
                self.command_session = .inactive;
                switch (self.active_page) {
                    .changes => self.changesNavigation().clearDiffSelection(),
                    .repository => self.pages.repository.clearLiveSelectionPreservingViewport(self.shellLayout().bodySize()),
                    .history => self.pages.history.diff.selection_owner = .none,
                    .compare => self.pages.compare.diff.selection_owner = .none,
                    .ai_reviews => self.pages.ai_reviews.diff.selection_owner = .none,
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
        self.changesRead().retireSupersededActionCursor(ctx, self.actionLifecycleView().generation());
        try self.changesRead().applyDeferredSourceIfReady(ctx);
        try self.changesRead().applyDeferredProjectionIfReady(ctx);
        if (try self.compareCoordinator().applyDeferred(ctx) == .skip) self.redraw_plan.requestSkip();
        try self.changesRead().maybeStartQueuedRevalidation(ctx);
        try self.repositoryCoordinator().startPending(ctx);
        try self.historyCoordinator().startPending(ctx);
        self.reconcileCommandLine();
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
            try self.changesRead().maybeStartQueuedRevalidation(ctx);
        }
        self.actionLifecycle().reconcileSpinner(ctx);
        self.pumpReviewStoreOperations(ctx);
        self.resumeQuitAfterStoreDrain(ctx);
        if (!self.redraw_plan.resolvesToSkip() and self.active_page == .ai_reviews) {
            self.aiReviewsCoordinator().ensureFindingPresentationCache();
        }
        if (!self.redraw_plan.resolvesToSkip() and
            self.active_page == .ai_reviews and
            self.pages.ai_reviews.picker.isPickerVisible())
        {
            self.aiReviewsCoordinator().prepareModalRedraw(ctx.io());
        }
        if (!self.redraw_plan.resolvesToSkip() and self.active_page == .compare and self.pages.compare.base_picker.open) {
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
        switch (self.review_store_operations.requestQuit()) {
            .ready => {
                self.quit_after_store_drain = false;
                self.teardown_requested = true;
                ctx.quit();
            },
            .draining => {
                self.quit_after_store_drain = true;
                // Store scans/selections are read generations, not accepted
                // mutations. Invalidate them while retaining the selected
                // Run presentation and keep the event loop responsive.
                self.pages.ai_reviews.picker.close(ctx.allocator());
                self.setStatus("finishing AI review save before quitting", .{});
            },
            .failed => |failure| {
                self.quit_after_store_drain = false;
                self.setStatus(
                    "cannot quit while AI review save needs reconciliation: {s}",
                    .{@tagName(failure)},
                );
            },
        }
    }

    fn pumpReviewStoreOperations(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (!self.review_store_operations.hasWork()) return;
        _ = self.review_store_operations.pump(ctx) catch {
            if (self.review_store_operations.isDraining()) {
                self.review_store_operations.cancelDrain(.io_failed);
                self.quit_after_store_drain = false;
                self.setStatus("AI review save failed: io_failed", .{});
                return;
            }
            self.setStatus("could not start AI review save", .{});
        };
    }

    fn enqueuePreparedHumanReviewDraft(
        self: *App,
        allocator: std.mem.Allocator,
        store: *const review_store.ConfiguredStore,
        session: *human_review_session_mod.Session,
        prepared: *const human_review_session_mod.PreparedDraft,
    ) !review_store_operations_mod.Admission {
        return self.review_store_operations.enqueueDraftChecked(
            allocator,
            store,
            self.repoSessionView().activeCapability(),
            self.env_map,
            prepared.request(),
            prepared.token,
        ) catch |err| {
            session.rejectDraft(prepared, .preparation_failed);
            return err;
        };
    }

    fn enqueuePreparedHumanReviewResult(
        self: *App,
        allocator: std.mem.Allocator,
        store: *const review_store.ConfiguredStore,
        session: *human_review_session_mod.Session,
        prepared: *const human_review_session_mod.PreparedResult,
    ) !review_store_operations_mod.Admission {
        return self.review_store_operations.enqueueResultChecked(
            allocator,
            store,
            self.repoSessionView().activeCapability(),
            self.env_map,
            prepared.request(),
            prepared.token,
        ) catch |err| {
            session.rejectResult(prepared, .preparation_failed);
            return err;
        };
    }

    fn recordHumanReviewPreparationFailure(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        session: *human_review_session_mod.Session,
        token: *const human_review_session_mod.QueueToken,
        kind: human_review_session_mod.OperationKind,
        decision: ?@import("committed_review.zig").ReviewResultValue,
        err: anyerror,
    ) void {
        if (err != error.QueueMismatch) {
            session.markPreparationFailure(token, kind, decision);
            return;
        }
        const binding = session.binding;
        session.markQueueMismatch(kind, decision);
        const retired = self.review_store_operations.retireUnstarted(
            ctx.allocator(),
            binding,
            .run_invalid,
            self.reviewStorePresentationMatches(binding),
        );
        for (retired.dependentTerminals()) |terminal| {
            _ = self.human_review_sessions.reduce(humanReviewCompletion(terminal));
        }
        if (retired.quit_canceled) self.quit_after_store_drain = false;
    }

    fn finishReviewStoreOperation(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        completion: app_message.ReviewStoreOperationFinished,
    ) void {
        var finished = completion;
        const presentation_matches = self.reviewStorePresentationMatches(finished.binding);
        const kind = finished.kind;
        const outcome = self.review_store_operations.finish(
            ctx.allocator(),
            &finished,
            presentation_matches,
        );
        if (!outcome.accepted) return;
        var reconciliation_required = false;
        var reconciliation_current = false;
        if (outcome.direct_terminal) |terminal| {
            const routed = self.human_review_sessions.reduce(humanReviewCompletion(terminal));
            reconciliation_required = routed.reduction == .reconciliation_required;
            reconciliation_current = reconciliation_required and routed.current_match;
        }
        for (outcome.dependentTerminals()) |terminal| {
            const routed = self.human_review_sessions.reduce(humanReviewCompletion(terminal));
            reconciliation_required = reconciliation_required or
                routed.reduction == .reconciliation_required;
            reconciliation_current = reconciliation_current or
                (routed.reduction == .reconciliation_required and routed.current_match);
        }
        var reconciliation_quit_canceled = false;
        if (reconciliation_required) {
            const retired = self.review_store_operations.retireUnstarted(
                ctx.allocator(),
                completion.binding,
                .run_invalid,
                presentation_matches,
            );
            for (retired.dependentTerminals()) |terminal| {
                _ = self.human_review_sessions.reduce(humanReviewCompletion(terminal));
            }
            reconciliation_quit_canceled = retired.quit_canceled or outcome.quit_ready;
            self.review_store_operations.reopenAfterReconciliation();
            self.quit_after_store_drain = false;
            if (reconciliation_current and presentation_matches) {
                const reason = if (outcome.failure) |failure| @tagName(failure) else "internal_mismatch";
                self.setStatus("AI review save requires exact reload: {s}", .{reason});
            }
        }
        if (outcome.quit_canceled or reconciliation_quit_canceled) self.quit_after_store_drain = false;
        if (!reconciliation_required) {
            if (outcome.failure) |failure| {
                if (presentation_matches or outcome.quit_canceled) {
                    if (outcome.dependent_terminal_count == 0) {
                        self.setStatus("AI review save failed: {s}", .{@tagName(failure)});
                    } else {
                        self.setStatus(
                            "AI review save failed: {s}; canceled {d} dependent save(s)",
                            .{ @tagName(failure), outcome.dependent_terminal_count },
                        );
                    }
                }
            } else if (presentation_matches) {
                switch (kind) {
                    .draft => self.pages.ai_reviews.status.set("AI review draft saved", .{}),
                    .result => self.pages.ai_reviews.status.set("AI review result saved", .{}),
                }
            }
        }
        if (outcome.quit_ready and !reconciliation_required) self.resumeQuitAfterStoreDrain(ctx);
    }

    fn resumeQuitAfterStoreDrain(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (!self.quit_after_store_drain or
            self.review_store_operations.isDraining() or
            self.review_store_operations.hasWork()) return;
        if (self.actionLifecycleView().hasPending()) {
            self.setStatus("finish current git action before quitting", .{});
            return;
        }
        self.quit_after_store_drain = false;
        self.teardown_requested = true;
        ctx.quit();
    }

    fn reviewStorePresentationMatches(
        self: *const App,
        binding: review_store.ReviewRunBinding,
    ) bool {
        if (self.active_page != .ai_reviews) return false;
        const selected = self.pages.ai_reviews.selectedRunConst() orelse return false;
        const manifest = &selected.selection.artifacts.manifest.value;
        return manifest.review_repository_id.eql(binding.review_repository_id) and
            manifest.review_id.eql(binding.review_id) and
            manifest.target.eql(&binding.target) and
            manifest.findings_digest.eql(binding.findings_digest);
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
            .ai_reviews => |point| blk: {
                if (self.active_page != .ai_reviews) break :blk .ai_reviews;
                _ = try self.updateAiReviews(ctx, .{ .common = .{ .shared = .{ .mouse_diff_drag = point } } });
                break :blk .ai_reviews;
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
            .changes => |point| {
                if (self.active_page == .changes) _ = try self.updateChanges(ctx, .{ .mouse_diff_release = point });
            },
            .compare => |point| {
                if (self.active_page == .compare) _ = try self.updateCompare(ctx, .{ .common = .{ .shared = .{ .mouse_diff_release = point } } });
            },
            .history => |point| {
                if (self.active_page == .history) _ = try self.updateHistory(ctx, .{ .common = .{ .shared = .{ .mouse_diff_release = point } } });
            },
            .ai_reviews => |point| {
                if (self.active_page == .ai_reviews) _ = try self.updateAiReviews(ctx, .{ .common = .{ .shared = .{ .mouse_diff_release = point } } });
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
            .changes => try self.updateChanges(ctx, .{ .mouse_diff_auto_scroll_step = active.intent }),
            .history => try self.updateHistory(ctx, .{ .common = .{ .shared = .{ .mouse_diff_auto_scroll_step = active.intent } } }),
            .compare => try self.updateCompare(ctx, .{ .common = .{ .shared = .{ .mouse_diff_auto_scroll_step = active.intent } } }),
            .ai_reviews => try self.updateAiReviews(ctx, .{ .common = .{ .shared = .{ .mouse_diff_auto_scroll_step = active.intent } } }),
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
            .changes => page.Id.changes,
            .history => page.Id.history,
            .compare => page.Id.compare,
            .ai_reviews => page.Id.ai_reviews,
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
            .ai_reviews => blk: {
                var adapter = self.aiReviewsCoordinator().navigation().updateAdapter();
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
            .request_branch_switch => try self.requestRemoteBranchSwitch(ctx),
            .open_selected_file_in_editor => try self.openSelectedFileInEditor(ctx),
            .copy_current_line => self.copyCurrentLine(ctx),
            .copy_current_hunk => try self.copyCurrentHunk(ctx),
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

    fn updateAiReviews(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        msg: ai_reviews_input.Msg,
    ) !?drag_auto_scroll.StepOutcome {
        var outcome = try self.aiReviewsCoordinator().update(ctx, msg);
        defer outcome.deinit(ctx.allocator());
        const auto_scroll = outcome.auto_scroll;
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
        if (outcome.takeHumanReviewSave()) {
            const saved = self.saveHumanReviewSession(ctx) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.setStatus("AI review save could not be prepared: {s}", .{@errorName(err)});
                return auto_scroll;
            };
            switch (saved) {
                .no_change, .accepted => {},
                .rejected => |reason| self.setStatus("AI review save rejected: {s}", .{@tagName(reason)}),
            }
        }
        if (outcome.takeHumanReviewFinalize()) |decision| {
            const finalized = self.finalizeHumanReviewSession(ctx, decision) catch |err| {
                self.pages.ai_reviews.human_review_decision.markFinalizeError(err);
                if (err == error.OutOfMemory) return err;
                return auto_scroll;
            };
            switch (finalized) {
                .accepted => self.pages.ai_reviews.human_review_decision.markFinalizeAccepted(),
                .rejected => |reason| self.pages.ai_reviews.human_review_decision.markFinalizeRejected(reason),
            }
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
                    if (try self.historyCoordinator().finishCatalog(ctx.allocator(), &result) == .discarded)
                        self.redraw_plan.requestSkip();
                },
                .diff => |result_value| {
                    var result = result_value;
                    defer result.deinit(ctx.allocator());
                    if (try self.historyCoordinator().finishDiff(ctx.allocator(), &result) == .discarded)
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
            .ai_reviews => |review_result| switch (review_result) {
                .history_scan => |result| {
                    if (self.aiReviewsCoordinator().finishHistoryScan(ctx.allocator(), result) == .skip) {
                        self.redraw_plan.requestSkip();
                    }
                },
                .history_selection => |result| {
                    const outcome = try self.aiReviewsCoordinator().finishHistorySelection(ctx, result);
                    if (outcome.redraw == .skip) {
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
            .editor => |result| if (self.shellEffects().finishEditor(result) == .reload_changes) {
                try self.changesRead().reloadAfterEditor(ctx);
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
        if (outcome.reload != .none) {
            try self.changesRead().applyEffectReload(ctx, outcome.reload);
        }
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
    fn reconcileCommandLine(self: *App) void {
        const execution = switch (self.command_session) {
            .inactive => return,
            .active => |active| active.context,
        };
        switch (execution) {
            .repository_source => |target| {
                if (self.active_page != .repository) {
                    self.command_session = .inactive;
                    return;
                }
                if (self.pages.repository.commandSourceTargetMatches(target)) return;
                self.command_session = .inactive;
                self.pages.repository.status.set("command source is no longer available", .{});
            },
        }
    }

    fn clearEphemeralStatusForUserAction(self: *App, msg: Msg) void {
        if (app_message.keepsEphemeralStatus(msg)) return;
        self.status.clearIfEphemeral();
        if (self.active_page == .changes) self.pages.changes.status.clearIfEphemeral();
        if (self.active_page == .compare) self.pages.compare.status.clearIfEphemeral();
        if (self.active_page == .ai_reviews) self.pages.ai_reviews.status.clearIfEphemeral();
        if (self.active_page == .repository) self.pages.repository.status.clearIfEphemeral();
        if (self.active_page == .history) self.pages.history.status.clearIfEphemeral();
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
            .ai_reviews = .{
                .page = &self.pages.ai_reviews,
                .human_review = self.humanReviewPresentation(),
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
            .terminal_size = self.terminal_size,
            .action = self.actionLifecycleView(),
            .remote_cancelable = remote.canCancel(self.actionLifecycleView().acceptedPending()),
            .remote_canceling = remote.canceling(),
            .status = &self.status,
            .page_status = self.activePageStatus(),
            .command_line = self.commandLineView(),
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
        const ai_reviews_navigation_view: ai_reviews_navigation.View = .{
            .page = &self.pages.ai_reviews,
            .repo_root = repo.activeRoot(),
            .repo_epoch = repo.epoch(),
            .root_identity = repo.activeIdentity(),
            .layout = .{ .width = body_size.width, .height = body_size.height },
            .mode_toggle_hint_width = self.displayModeToggleHintWidth(.ai_reviews),
        };
        var ai_reviews_body_adapter = ai_reviews_navigation_view.resolver();
        const ai_reviews_body_view = ai_reviews_navigation_view.bodyView(&ai_reviews_body_adapter);
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
                        .keymap = self.keymap,
                    },
                    .base_picker_open = self.pages.compare.base_picker.open,
                    .base_picker_query_mode = self.pages.compare.base_picker.input_mode == .query,
                    .base_picker_query_len = self.pages.compare.base_picker.query.len,
                    .ai_review_handoff_open = self.pages.compare.ai_review_handoff.open,
                },
                .selection_owner = &self.pages.compare.diff.selection_owner,
                .loaded = compare_navigation_view.view().activeLoadedDiffConst(),
                .selected_node = self.pages.compare.diff.viewer.selected_node,
                .sidebar_hidden = self.pages.compare.diff.viewer.sidebar_hidden,
                .sidebar_width = self.pages.compare.diff.viewer.sidebar_width,
            },
            .ai_reviews = .{
                .key = .{
                    .common = .{
                        .search_mode = self.pages.ai_reviews.diff.search.mode,
                        .file_search_mode = self.pages.ai_reviews.diff.file_search.mode,
                        .search_query_len = self.pages.ai_reviews.diff.search.query.len,
                        .focus = self.pages.ai_reviews.diff.viewer.focus,
                        .sidebar_hidden = self.pages.ai_reviews.diff.viewer.sidebar_hidden,
                        .side_by_side = ai_reviews_navigation_view.view().effectiveDisplayMode() == .side_by_side,
                        .selection_owner = diff_surface.input.selectionOwnerKind(self.pages.ai_reviews.diff.selection_owner),
                        .retained_selection_action_available = ai_reviews_body_view.retainedSelectionActionAvailable(),
                        .keymap = self.keymap,
                    },
                    .picker_open = self.pages.ai_reviews.picker.isPickerVisible(),
                    .picker_query_mode = self.pages.ai_reviews.picker.queryMode(),
                    .picker_query_len = self.pages.ai_reviews.picker.query.len,
                    .picker_loading = self.pages.ai_reviews.picker.loading(),
                    .delete_confirmation_open = self.pages.ai_reviews.delete_confirmation.isOpen(),
                    .delete_confirmation_deleting = self.pages.ai_reviews.delete_confirmation.isDeleting(),
                    .selected_run = self.pages.ai_reviews.selectedRunConst() != null,
                    .human_review = self.pages.ai_reviews.human_review_decision.inputContext(
                        self.humanReviewPresentation(),
                    ),
                    .finding_card_focused = self.pages.ai_reviews.finding_card.isFocused(),
                    .finding_card_at_cursor = ai_reviews_navigation_view.findingCardAtCursor(),
                },
                .selection_owner = &self.pages.ai_reviews.diff.selection_owner,
                .loaded = ai_reviews_body_view.view.activeLoadedDiffConst(),
                .selected_node = self.pages.ai_reviews.diff.viewer.selected_node,
                .sidebar_hidden = self.pages.ai_reviews.diff.viewer.sidebar_hidden,
                .sidebar_width = self.pages.ai_reviews.diff.viewer.sidebar_width,
            },
            .repository = .{
                .key = self.pages.repository.inputContext(self.keymap),
                .page_state = &self.pages.repository,
            },
            .history = .{
                .key = history_key,
                .selection_owner = &self.pages.history.diff.selection_owner,
                .loaded = if (self.pages.history.current_view == .diff)
                    history_body_view.view.activeLoadedDiffConst()
                else
                    null,
                .selected_node = self.pages.history.diff.viewer.selected_node,
                .sidebar_hidden = self.pages.history.diff.viewer.sidebar_hidden,
                .sidebar_width = self.pages.history.diff.viewer.sidebar_width,
            },
            .commit_panel_mode = self.localWorkflowView().commitPanelOpen(),
            .repo_picker_mode = picker.model.mode,
            .repo_picker_input_mode = picker.model.input_mode,
            .remote_action_cancelable = self.remoteWorkflowView().canCancel(self.actionLifecycleView().acceptedPending()),
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
            .ai_reviews => &self.pages.ai_reviews.status,
            .config => null,
        };
    }

    fn activePageStatusMut(self: *App) ?*app_state.StatusMessage {
        return switch (self.active_page) {
            .changes => &self.pages.changes.status,
            .repository => &self.pages.repository.status,
            .history => &self.pages.history.status,
            .compare => &self.pages.compare.status,
            .ai_reviews => &self.pages.ai_reviews.status,
            .config => null,
        };
    }

    fn overlayScroll(self: *App) shell_input.OverlayScrollController {
        return .{
            .overlay = &self.overlay,
            .content_size = self.shellLayout().contentSize(),
            .help_page = self.active_page,
            .push_error_message = self.remoteWorkflowView().pushErrorMessage(),
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
        const text = self.changesContent().currentLineCopyText() orelse {
            self.setChangesStatus("no diff line selected", .{});
            return;
        };
        self.shellEffects().queueClipboard(ctx, .{
            .origin = .{ .page = self.shellEffects().changesOrigin() },
            .label = "current line",
            .text = text,
        });
    }

    fn copyCurrentHunk(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        var content = try self.changesContent().selectedHunkCopyText(ctx.allocator());
        defer content.deinit(ctx.allocator());
        switch (content) {
            .ready => |text| self.shellEffects().queueClipboard(ctx, .{
                .origin = .{ .page = self.shellEffects().changesOrigin() },
                .label = "current hunk",
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
            .ai_reviews => {
                var adapter = self.aiReviewsCoordinator().navigation().updateAdapter();
                if (adapter.bodyController().clearCompletedSelectionAfterCopy(
                    allocator,
                    completion.generation,
                )) self.pages.ai_reviews.diff.pinned_selection_basis = null;
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
            .config => {},
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
            .changes => effects.changesOrigin(),
            .repository => effects.repositoryOrigin(),
            .history => effects.historyOrigin(),
            .compare => effects.compareOrigin(),
            .ai_reviews => effects.aiReviewsOrigin(),
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

    fn setChangesStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.pages.changes.status.set(fmt, args);
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
    /// still-authoritative Changes, Compare, or AI Reviews page.
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
            try self.applyRepoSessionCommit(ctx, outcome);
            return;
        }

        try self.changesRead().acceptRepoDiscoveryCommit(ctx);
        if (outcome == .changed and (self.active_page == .compare or self.active_page == .ai_reviews)) {
            try self.applyRepoSessionCommit(ctx, outcome);
        }
    }

    fn applyRepoSessionCommit(self: *App, ctx: *chasen.Ctx(Msg), outcome: repo_session.CommitOutcome) !void {
        switch (outcome) {
            .changed => {
                const session_transition = self.human_review_sessions.prepareClear() catch null;
                try self.applyPageCoordinationIntent(
                    ctx,
                    self.pageCoordinator().acceptedRepositoryChange(self.allocator orelse ctx.allocator()),
                );
                if (session_transition) |plan| {
                    self.human_review_sessions.commitClear(plan);
                } else if (self.human_review_sessions.currentSessionConst() != null) {
                    self.setStatus("AI review has unsaved state; reselect it to reconcile", .{});
                }
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

fn mapHumanReviewAdmissionFailure(
    reason: review_store_operations_mod.Rejection,
) human_review_session_mod.AdmissionFailure {
    return switch (reason) {
        .admission_closed => .admission_closed,
        .capacity => .capacity,
        .incompatible_queue => .incompatible_queue,
        .store_unavailable => .store_unavailable,
        .queue_changed => .queue_changed,
    };
}

fn humanReviewCompletion(
    terminal: review_store_operations_mod.CompletionRecord,
) human_review_session_mod.Completion {
    return .{
        .operation_id = terminal.operation_id,
        .binding = terminal.binding,
        .kind = terminal.kind,
        .expected_revision = terminal.expected_revision,
        .committed_revision = terminal.committed_revision,
        .completed_at = terminal.completed_at,
        .failure = terminal.failure,
    };
}

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

    app.reconcileCommandLine();

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
    var tc: chasen.testing.TestCtx(App.Msg) = .{};
    defer tc.resetTransient();

    app.updateCommandLine(.open);
    app.updateCommandLine(.{ .paste = "2🐈" });
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 12 } }, &tc.ctx);
    try std.testing.expectEqualStrings("2🐈", app.commandLineView().?.input.slice());

    try app.update(.focus_lost, &tc.ctx);
    try std.testing.expect(app.commandLineView() == null);

    app.updateCommandLine(.open);
    try std.testing.expect(app.commandLineView() != null);
    try app.update(.{ .switch_page = .config }, &tc.ctx);
    try std.testing.expect(app.commandLineView() == null);
}

fn installReviewStoreRepositoryForTest(app: *App, allocator: std.mem.Allocator) !void {
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(path);
    app.repo_session.repo_state.root = try @import("repo/root_capability.zig").RootCapability.openCanonical(path);
}

test "review state persistence App quit drains accepted mutation and reopens after failure" {
    const allocator = std.testing.allocator;
    const committed = @import("committed_review.zig");
    const repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oid = try committed.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const binding: review_store.ReviewRunBinding = .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        },
        .findings_digest = committed.Sha256Digest.hash("findings\n"),
    };
    var app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
        .allocator = allocator,
    };
    try installReviewStoreRepositoryForTest(&app, allocator);
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();

    const admission = try app.persistReviewDraft(&ctx, .{
        .binding = binding,
        .expected_revision = 0,
        .summary = "dirty caller-owned draft",
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    });
    try std.testing.expect(admission == .accepted);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);

    try app.update(.quit, &ctx);
    try std.testing.expect(app.review_store_operations.isDraining());
    try std.testing.expect(!ctx.shouldQuit());
    const queued = ctx.takePendingTasksWith();
    const completion = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    try app.update(completion, &ctx);

    try std.testing.expect(!app.review_store_operations.isDraining());
    try std.testing.expect(app.review_store_operations.admissionsOpen());
    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expectEqualStrings("AI review save failed: io_failed", app.status.text());

    const saved = try app.persistReviewDraft(&ctx, .{
        .binding = binding,
        .expected_revision = 0,
        .summary = "retry after reconciliation",
        .finding_dispositions = &.{},
        .anchored_notes = &.{},
    });
    try app.update(.quit, &ctx);
    try std.testing.expect(app.quit_after_store_drain);
    const store_tasks = ctx.takePendingTasksWith();
    var abandoned = store_tasks[0].failed(store_tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);

    // Admit an exact existing Git lifecycle owner after Store drain began.
    // Store success must return through the common quit coordinator instead
    // of bypassing this later owner.
    const prepared = app.actionLifecycle().prepare(.stage_file);
    const accepted_action = app.actionLifecycle().acceptSpawn(allocator, prepared);
    try std.testing.expect(app.actionLifecycleView().isAccepted(accepted_action.pending));

    try app.update(.{ .review_store_operation_finished = .{
        .operation_id = saved.accepted.operation_id,
        .binding = binding,
        .kind = .draft,
        .result = .{ .draft = .{ .committed = .{
            .revision = 1,
            .canonical_bytes = try allocator.dupe(u8, "draft\n"),
        } } },
    } }, &ctx);
    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(app.quit_after_store_drain);
    try std.testing.expect(app.actionLifecycleView().isAccepted(accepted_action.pending));
    try std.testing.expectEqualStrings("finish current git action before quitting", app.status.text());

    try app.update(App.Msg.actionFinished(.{ .stage_file = .{
        .pending = accepted_action.pending,
        .path = try allocator.dupe(u8, "late-action"),
        .result = .{ .failed_static = "fixture terminal" },
    } }), &ctx);
    try std.testing.expect(!app.actionLifecycleView().hasPending());
    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(app.teardown_requested);
    try std.testing.expect(!app.quit_after_store_drain);
}

test "human review result session App bridge tracks every accepted draft and result before pump" {
    const allocator = std.testing.allocator;
    const committed = @import("committed_review.zig");
    const repository_id = try committed.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    const review_id = try committed.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    const oid = try committed.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    const binding: review_store.ReviewRunBinding = .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        },
        .findings_digest = committed.Sha256Digest.hash("findings\n"),
    };
    const findings: committed.FindingSet = .{
        .schema_version = committed.limits.schema_version,
        .review_id = review_id,
        .created_at = "2026-08-27T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = binding.target,
        .producer = .{ .name = "test" },
        .findings = &.{},
    };
    var app: App = .{
        .active_page = .ai_reviews,
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
        .allocator = allocator,
    };
    try installReviewStoreRepositoryForTest(&app, allocator);
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    defer app.human_review_sessions.deinit();
    defer app.pages.ai_reviews.deinit(allocator);
    _ = app.pages.ai_reviews.activate(0);
    app.human_review_sessions.current = try human_review_session_mod.Session.init(
        allocator,
        binding,
        &findings,
        null,
        null,
    );
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();

    var delete_row: review_store.RunSummary = .{
        .review_id = review_id,
        .target = binding.target,
        .status = .draft,
        .created_at = "2026-08-27T00:00:00Z".*,
        .created_at_unix = 0,
        .producer_name = @constCast("test"),
        .producer_model = null,
        .base_label = null,
        .head_label = null,
        .finding_count = 0,
        .availability = .available,
        .artifact_snapshot = .{
            .manifest_digest = committed.Sha256Digest.hash("manifest"),
            .findings_digest = binding.findings_digest,
            .draft_state = .valid,
            .draft_digest = committed.Sha256Digest.hash("draft"),
            .result_digest = null,
        },
    };
    try app.pages.ai_reviews.delete_confirmation.begin(
        allocator,
        humanReviewTestStoreSnapshot(repository_id),
        &delete_row,
        null,
    );
    try app.human_review_sessions.currentSession().?.editSummary(allocator, "blocked");
    try std.testing.expect((try app.saveHumanReviewSession(&ctx)) == .rejected);
    try app.update(.{ .switch_page = .config }, &ctx);
    try std.testing.expectEqual(page.Id.ai_reviews, app.active_page);
    try std.testing.expectEqualStrings("finish confirmation before switching pages", app.status.text());

    _ = app.pages.ai_reviews.delete_confirmation.confirm(
        app.pages.ai_reviews.activation.currentIdentity().?,
        .{ .device = 5, .inode = 6 },
        app.configured_review_store.?.identity(),
    ).?;
    try app.repoSession().enterPicker(allocator);
    try std.testing.expect(!app.repo_session.repo_picker.mode);
    try std.testing.expectEqualStrings("finish current git action before switching repos", app.status.text());
    try std.testing.expect((try app.saveHumanReviewSession(&ctx)) == .rejected);
    try std.testing.expectEqual(
        human_review_session_mod.AdmissionFailure.admission_closed,
        (try app.finalizeHumanReviewSession(&ctx, .needs_changes)).rejected,
    );
    try std.testing.expectEqual(@as(usize, 0), app.human_review_sessions.currentSessionConst().?.operationCount());
    app.pages.ai_reviews.delete_confirmation.restoreConfirmation();
    try std.testing.expect(app.pages.ai_reviews.delete_confirmation.cancel(allocator));

    try app.human_review_sessions.currentSession().?.editSummary(allocator, "first");
    const first = try app.saveHumanReviewSession(&ctx);
    try std.testing.expect(first == .accepted);
    try std.testing.expectEqual(@as(usize, 1), app.human_review_sessions.currentSessionConst().?.operationCount());
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);

    try app.human_review_sessions.currentSession().?.editSummary(allocator, "second");
    const second = try app.saveHumanReviewSession(&ctx);
    try std.testing.expect(second == .accepted);
    try app.human_review_sessions.currentSession().?.editSummary(allocator, "final");
    const finalized = try app.finalizeHumanReviewSession(&ctx, .needs_changes);
    try std.testing.expect(finalized == .accepted);
    try std.testing.expect(finalized.accepted.draft_operation_id != null);
    try std.testing.expectEqual(
        @as(usize, 3),
        app.human_review_sessions.currentSessionConst().?.operationCount(),
    );
    try std.testing.expectEqual(human_review_session_mod.Lifecycle.finalizing, app.human_review_sessions.currentSessionConst().?.lifecycle());

    var active_tasks = ctx.takePendingTasksWith();
    var abandoned = active_tasks[0].failed(active_tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
    try app.update(.{ .review_store_operation_finished = .{
        .operation_id = first.accepted,
        .binding = binding,
        .kind = .draft,
        .result = .{ .draft = .{ .committed = .{
            .revision = 1,
            .canonical_bytes = try allocator.dupe(u8, "draft-1\n"),
        } } },
    } }, &ctx);

    active_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), active_tasks.len);
    abandoned = active_tasks[0].failed(active_tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
    try app.update(.{ .review_store_operation_finished = .{
        .operation_id = finalized.accepted.draft_operation_id.?,
        .binding = binding,
        .kind = .draft,
        .result = .{ .draft = .{ .committed = .{
            .revision = 2,
            .canonical_bytes = try allocator.dupe(u8, "draft-2\n"),
        } } },
    } }, &ctx);

    active_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), active_tasks.len);
    abandoned = active_tasks[0].failed(active_tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
    try app.update(.{ .review_store_operation_finished = .{
        .operation_id = finalized.accepted.result_operation_id,
        .binding = binding,
        .kind = .result,
        .result = .{ .result = .{ .committed = .{
            .revision = 2,
            .completed_at = "2026-08-27T12:00:00Z".*,
            .canonical_bytes = try allocator.dupe(u8, "result\n"),
        } } },
    } }, &ctx);
    try std.testing.expectEqual(human_review_session_mod.Lifecycle.completed, app.human_review_sessions.currentSessionConst().?.lifecycle());
    try std.testing.expect(!app.review_store_operations.hasWork());
}

test "Finding disposition App bridge immediately admits the existing draft save" {
    const allocator = std.testing.allocator;
    const binding = try humanReviewTestBinding(31);
    const finding: committed_review.Finding = .{
        .finding_id = .{ .bytes = "F-1" },
        .anchor = .{
            .path_bytes = "src/main.zig",
            .side = .after,
            .start_line = 1,
            .end_line = 1,
            .content_digest = committed_review.Sha256Digest.hash("line\n"),
        },
        .severity = .warning,
        .title = "fixture",
        .body = "fixture body",
    };
    const findings: committed_review.FindingSet = .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = binding.review_id,
        .created_at = "2026-09-04T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = binding.target,
        .producer = .{ .name = "test" },
        .findings = &.{finding},
    };
    var app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
        .allocator = allocator,
    };
    try installReviewStoreRepositoryForTest(&app, allocator);
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    defer app.human_review_sessions.deinit();
    app.human_review_sessions.current = try human_review_session_mod.Session.init(
        allocator,
        binding,
        &findings,
        null,
        null,
    );
    const session = app.human_review_sessions.currentSession().?;
    try session.editDisposition(allocator, .{ .bytes = "F-1" }, .accepted);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();
    const saved = try app.saveHumanReviewSession(&ctx);
    try std.testing.expect(saved == .accepted);
    try std.testing.expectEqual(@as(usize, 1), session.operationCount());
    try std.testing.expectEqual(
        committed_review.FindingDispositionValue.accepted,
        session.workingSnapshot().?.finding_dispositions[0].disposition,
    );
    const tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    var abandoned = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

test "human review result session App admission faults preserve exact prepared intents" {
    const allocator = std.testing.allocator;
    const binding = try humanReviewTestBinding(14);
    const findings = humanReviewTestFindings(binding);
    var app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
        .allocator = allocator,
    };
    try installReviewStoreRepositoryForTest(&app, allocator);
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    defer app.human_review_sessions.deinit();
    defer app.pages.ai_reviews.deinit(allocator);
    app.human_review_sessions.current = try human_review_session_mod.Session.init(
        allocator,
        binding,
        &findings,
        null,
        null,
    );
    const session = app.human_review_sessions.currentSession().?;
    const store = &app.configured_review_store.?;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();

    try session.editSummary(allocator, "first");
    try app.pages.ai_reviews.human_review_decision.open(allocator, session.presentation());
    _ = try app.pages.ai_reviews.human_review_decision.apply(.focus_next, session.presentation());
    _ = try app.pages.ai_reviews.human_review_decision.apply(.activate, session.presentation());
    _ = try app.pages.ai_reviews.human_review_decision.apply(.focus_next, session.presentation());
    _ = try app.pages.ai_reviews.human_review_decision.apply(.focus_next, session.presentation());
    _ = try app.pages.ai_reviews.human_review_decision.apply(.activate, session.presentation());
    const initial_generation = session.generation;
    const draft_preparation_token = app.review_store_operations.queueToken(binding);
    var draft_preparation_failing = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        session.prepareSave(
            draft_preparation_failing.allocator(),
            draft_preparation_token,
            .dirty_only,
        ),
    );
    app.recordHumanReviewPreparationFailure(
        &ctx,
        session,
        &draft_preparation_token,
        .draft,
        null,
        error.OutOfMemory,
    );
    const queue_after_draft_preparation = app.review_store_operations.queueToken(binding);
    try std.testing.expect(draft_preparation_token.eql(&queue_after_draft_preparation));
    try std.testing.expectEqual(@as(usize, 0), session.operationCount());
    try std.testing.expectEqual(@as(u64, 0), session.last_failure.?.expected_revision);
    try std.testing.expectEqual(initial_generation, session.last_failure.?.submitted_generation);
    try std.testing.expectEqual(human_review_session_mod.OperationKind.draft, session.last_failure.?.kind);

    const initial_token = app.review_store_operations.queueToken(binding);
    const initial_preparation = try session.prepareSave(allocator, initial_token, .dirty_only);
    var initial = initial_preparation.ready;
    defer initial.deinit();
    const initial_queue = app.review_store_operations.queueToken(binding);
    var initial_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        app.enqueuePreparedHumanReviewDraft(
            initial_failing.allocator(),
            store,
            session,
            &initial,
        ),
    );
    const queue_after_initial_admission = app.review_store_operations.queueToken(binding);
    try std.testing.expect(initial_queue.eql(&queue_after_initial_admission));
    try std.testing.expectEqual(@as(usize, 0), session.operationCount());
    try std.testing.expectEqual(@as(u64, 0), session.last_failure.?.expected_revision);
    try std.testing.expectEqual(initial_generation, session.last_failure.?.submitted_generation);
    try std.testing.expectEqual(
        human_review_session_mod.AdmissionFailure.preparation_failed,
        session.last_failure.?.reason.admission,
    );

    const initial_admission = try app.enqueuePreparedHumanReviewDraft(
        allocator,
        store,
        session,
        &initial,
    );
    session.commitDraft(
        &initial,
        initial_admission.accepted.operation_id,
        initial_admission.accepted.superseded_operation_id,
    );
    app.pumpReviewStoreOperations(&ctx);

    try session.editSummary(allocator, "second");
    const pending_token = app.review_store_operations.queueToken(binding);
    const pending_preparation = try session.prepareSave(allocator, pending_token, .dirty_only);
    var pending = pending_preparation.ready;
    defer pending.deinit();
    const pending_admission = try app.enqueuePreparedHumanReviewDraft(
        allocator,
        store,
        session,
        &pending,
    );
    session.commitDraft(
        &pending,
        pending_admission.accepted.operation_id,
        pending_admission.accepted.superseded_operation_id,
    );

    try session.editSummary(allocator, "third");
    const replacement_generation = session.generation;
    const replacement_token = app.review_store_operations.queueToken(binding);
    const replacement_preparation = try session.prepareSave(
        allocator,
        replacement_token,
        .dirty_only,
    );
    var replacement = replacement_preparation.ready;
    defer replacement.deinit();
    const replacement_queue = app.review_store_operations.queueToken(binding);
    var replacement_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        app.enqueuePreparedHumanReviewDraft(
            replacement_failing.allocator(),
            store,
            session,
            &replacement,
        ),
    );
    const queue_after_replacement_admission = app.review_store_operations.queueToken(binding);
    try std.testing.expect(replacement_queue.eql(&queue_after_replacement_admission));
    try std.testing.expectEqual(@as(usize, 2), session.operationCount());
    try std.testing.expectEqual(@as(u64, 1), session.last_failure.?.expected_revision);
    try std.testing.expectEqual(replacement_generation, session.last_failure.?.submitted_generation);

    const replacement_admission = try app.enqueuePreparedHumanReviewDraft(
        allocator,
        store,
        session,
        &replacement,
    );
    session.commitDraft(
        &replacement,
        replacement_admission.accepted.operation_id,
        replacement_admission.accepted.superseded_operation_id,
    );

    const result_token = app.review_store_operations.queueToken(binding);
    const result_generation = session.generation;
    var preparation_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        session.prepareResult(preparation_failing.allocator(), result_token, .needs_changes),
    );
    app.recordHumanReviewPreparationFailure(
        &ctx,
        session,
        &result_token,
        .result,
        .needs_changes,
        error.OutOfMemory,
    );
    const queue_after_result_preparation = app.review_store_operations.queueToken(binding);
    try std.testing.expect(result_token.eql(&queue_after_result_preparation));
    try std.testing.expectEqual(@as(usize, 2), session.operationCount());
    try std.testing.expectEqual(@as(u64, 2), session.last_failure.?.expected_revision);
    try std.testing.expectEqual(result_generation, session.last_failure.?.submitted_generation);
    try std.testing.expectEqual(
        committed_review.ReviewResultValue.needs_changes,
        session.last_failure.?.decision.?,
    );

    const saving_after_preparation_failure = session.presentation();
    try std.testing.expectEqual(human_review_session_mod.Lifecycle.saving, saving_after_preparation_failure.lifecycle);
    try std.testing.expect(app.pages.ai_reviews.human_review_decision.inputContext(saving_after_preparation_failure).read_only);
    const focus_before_blocked_input = app.pages.ai_reviews.human_review_decision.focus();
    const decision_before_blocked_input = app.pages.ai_reviews.human_review_decision.selectedDecision();
    const queue_before_blocked_input = app.review_store_operations.queueToken(binding);
    const operation_count_before_blocked_input = session.operationCount();
    const generation_before_blocked_input = session.generation;
    try std.testing.expect((try app.pages.ai_reviews.human_review_decision.apply(
        .{ .summary_paste = "must not replace accepted draft bytes" },
        saving_after_preparation_failure,
    )) == .none);
    try std.testing.expect((try app.pages.ai_reviews.human_review_decision.apply(
        .focus_next,
        saving_after_preparation_failure,
    )) == .none);
    try std.testing.expect((try app.pages.ai_reviews.human_review_decision.apply(
        .activate,
        saving_after_preparation_failure,
    )) == .none);
    try std.testing.expectEqual(focus_before_blocked_input, app.pages.ai_reviews.human_review_decision.focus());
    try std.testing.expectEqual(decision_before_blocked_input, app.pages.ai_reviews.human_review_decision.selectedDecision());
    try std.testing.expectEqualStrings("first", app.pages.ai_reviews.human_review_decision.submittedSummary().?);
    try std.testing.expectEqualStrings("third", session.workingSnapshot().?.summary.?);
    try std.testing.expectEqual(generation_before_blocked_input, session.generation);
    try std.testing.expectEqual(operation_count_before_blocked_input, session.operationCount());
    const queue_after_blocked_input = app.review_store_operations.queueToken(binding);
    try std.testing.expect(queue_before_blocked_input.eql(&queue_after_blocked_input));
    app.pages.ai_reviews.human_review_decision.close();
    try std.testing.expect(!app.pages.ai_reviews.human_review_decision.isOpen());
    try app.pages.ai_reviews.human_review_decision.open(allocator, saving_after_preparation_failure);
    try std.testing.expect(app.pages.ai_reviews.human_review_decision.inputContext(saving_after_preparation_failure).read_only);
    try std.testing.expect((try app.pages.ai_reviews.human_review_decision.apply(
        .activate,
        saving_after_preparation_failure,
    )) == .none);
    try std.testing.expect(app.pages.ai_reviews.human_review_decision.selectedDecision() == null);
    app.pages.ai_reviews.human_review_decision.close();

    var result = try session.prepareResult(allocator, result_token, .needs_changes);
    defer result.deinit();
    const result_queue = app.review_store_operations.queueToken(binding);
    var result_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        app.enqueuePreparedHumanReviewResult(
            result_failing.allocator(),
            store,
            session,
            &result,
        ),
    );
    const queue_after_result_admission = app.review_store_operations.queueToken(binding);
    try std.testing.expect(result_queue.eql(&queue_after_result_admission));
    try std.testing.expectEqual(@as(usize, 2), session.operationCount());
    try std.testing.expectEqual(@as(u64, 2), session.last_failure.?.expected_revision);
    try std.testing.expectEqual(result_generation, session.last_failure.?.submitted_generation);
    try std.testing.expectEqual(
        committed_review.ReviewResultValue.needs_changes,
        session.last_failure.?.decision.?,
    );

    const saving_after_admission_failure = session.presentation();
    try std.testing.expectEqual(human_review_session_mod.Lifecycle.saving, saving_after_admission_failure.lifecycle);
    const queue_before_reopen = app.review_store_operations.queueToken(binding);
    try app.pages.ai_reviews.human_review_decision.open(allocator, saving_after_admission_failure);
    try std.testing.expect((try app.pages.ai_reviews.human_review_decision.apply(
        .activate,
        saving_after_admission_failure,
    )) == .none);
    try std.testing.expectEqualStrings("third", app.pages.ai_reviews.human_review_decision.submittedSummary().?);
    try std.testing.expect(app.pages.ai_reviews.human_review_decision.selectedDecision() == null);
    app.pages.ai_reviews.human_review_decision.close();
    const queue_after_reopen = app.review_store_operations.queueToken(binding);
    try std.testing.expect(queue_before_reopen.eql(&queue_after_reopen));

    const tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), tasks.len);
    var abandoned = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

test "human review result session App bridge keeps detached failure on original Run" {
    const allocator = std.testing.allocator;
    const binding_a = try humanReviewTestBinding(11);
    const binding_b = try humanReviewTestBinding(12);
    const findings_a = humanReviewTestFindings(binding_a);
    const findings_b = humanReviewTestFindings(binding_b);
    var app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
        .allocator = allocator,
    };
    try installReviewStoreRepositoryForTest(&app, allocator);
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    defer app.human_review_sessions.deinit();
    app.human_review_sessions.current = try human_review_session_mod.Session.init(
        allocator,
        binding_a,
        &findings_a,
        null,
        null,
    );
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.human_review_sessions.currentSession().?.editSummary(allocator, "A recovery bytes");
    const save = try app.saveHumanReviewSession(&ctx);
    try std.testing.expect(save == .accepted);
    var session_b = try human_review_session_mod.Session.init(
        allocator,
        binding_b,
        &findings_b,
        null,
        null,
    );
    var install_b = try app.human_review_sessions.prepareInstall(&session_b);
    defer install_b.deinit();
    app.human_review_sessions.commitInstall(&install_b);
    app.status.set("B status stays", .{});

    const tasks = ctx.takePendingTasksWith();
    const failed = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    try app.update(failed, &ctx);
    try std.testing.expectEqualStrings("B status stays", app.status.text());
    try std.testing.expect(app.human_review_sessions.currentSessionConst().?.binding.eql(binding_b));
    try std.testing.expectEqual(@as(usize, 1), app.human_review_sessions.detached_len);
    try std.testing.expectEqual(@as(usize, 1), app.human_review_sessions.detached[0].recoveryCount());
    try std.testing.expectEqual(
        @as(u64, 0),
        app.human_review_sessions.detached[0].last_failure.?.expected_revision,
    );

    var fresh_a = try human_review_session_mod.Session.init(
        allocator,
        binding_a,
        &findings_a,
        null,
        null,
    );
    var reattach = try app.human_review_sessions.prepareInstall(&fresh_a);
    defer reattach.deinit();
    app.human_review_sessions.commitInstall(&reattach);
    try std.testing.expect(app.human_review_sessions.currentSessionConst().?.binding.eql(binding_a));
    try std.testing.expectEqual(human_review_session_mod.Lifecycle.failed, app.human_review_sessions.currentSessionConst().?.lifecycle());
    try std.testing.expectEqualStrings(
        "A recovery bytes",
        app.human_review_sessions.currentSessionConst().?.workingSnapshot().?.summary.?,
    );
}

test "human review result session App mismatch cancels quit and requires exact reload" {
    const allocator = std.testing.allocator;
    const binding = try humanReviewTestBinding(13);
    const findings = humanReviewTestFindings(binding);
    var app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(allocator, "/unused"),
        .allocator = allocator,
    };
    try installReviewStoreRepositoryForTest(&app, allocator);
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    defer app.human_review_sessions.deinit();
    app.human_review_sessions.current = try human_review_session_mod.Session.init(
        allocator,
        binding,
        &findings,
        null,
        null,
    );
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = std.testing.io };
    defer ctx.runtimeClearPendingEffectCopies();

    try app.human_review_sessions.currentSession().?.editSummary(allocator, "unconfirmed");
    const save = try app.saveHumanReviewSession(&ctx);
    try app.update(.quit, &ctx);
    try std.testing.expect(app.review_store_operations.isDraining());
    const tasks = ctx.takePendingTasksWith();
    var abandoned = tasks[0].failed(tasks[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
    try app.update(.{ .review_store_operation_finished = .{
        .operation_id = save.accepted,
        .binding = binding,
        .kind = .draft,
        .result = .{ .draft = .{ .committed = .{
            .revision = 9,
            .canonical_bytes = try allocator.dupe(u8, "unexpected\n"),
        } } },
    } }, &ctx);
    try std.testing.expect(!ctx.shouldQuit());
    try std.testing.expect(!app.quit_after_store_drain);
    try std.testing.expect(app.review_store_operations.admissionsOpen());
    try std.testing.expectEqual(
        human_review_session_mod.Reconciliation.reload_required,
        app.human_review_sessions.currentSessionConst().?.reconciliation,
    );
    try std.testing.expectEqual(@as(?u64, 0), app.human_review_sessions.currentSessionConst().?.confirmedRevision());
    try std.testing.expectEqual(@as(usize, 1), app.human_review_sessions.currentSessionConst().?.recoveryCount());
}

fn humanReviewTestBinding(suffix: u8) !review_store.ReviewRunBinding {
    var repository_id = try committed_review.ReviewRepositoryId.parse("123e4567-e89b-42d3-a456-426614174000");
    repository_id.bytes[15] = suffix;
    var review_id = try committed_review.ReviewId.parse("223e4567-e89b-42d3-a456-426614174000");
    review_id.bytes[15] = suffix;
    const oid = try committed_review.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    return .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        },
        .findings_digest = committed_review.Sha256Digest.hash(&.{suffix}),
    };
}

fn humanReviewTestStoreSnapshot(
    repository_id: committed_review.ReviewRepositoryId,
) review_store.StoreSnapshot {
    const display = review_store.RepositoryDisplayName.fromStored("repository") catch unreachable;
    return .{
        .root_device = 1,
        .root_inode = 2,
        .namespace_device = 3,
        .namespace_inode = 4,
        .repository_instance_id = committed_review.RepositoryInstanceId.parse("123e4567-e89b-42d3-a456-426614174010") catch unreachable,
        .review_repository_id = repository_id,
        .repository_display_name = display,
        .repository_directory_name = review_store.RepositoryDirectoryName.format(&display, repository_id),
    };
}

fn humanReviewTestFindings(binding: review_store.ReviewRunBinding) committed_review.FindingSet {
    return .{
        .schema_version = committed_review.limits.schema_version,
        .review_id = binding.review_id,
        .created_at = "2026-08-27T00:00:00Z",
        .timing = .{ .duration_ms = 1 },
        .target = binding.target,
        .producer = .{ .name = "test" },
        .findings = &.{},
    };
}

test "human review result session App and Store keep an in-flight revert on one completed snapshot" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = try HumanReviewStoreFixture.init(allocator, io, tmp.dir, "store");
    defer fixture.deinit(allocator);

    var loaded = try committed_review.ReviewDraftState.parseStrict(
        allocator,
        fixture.draft_bytes,
    );
    defer loaded.deinit();

    var app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(
            allocator,
            fixture.store_root,
        ),
        .allocator = allocator,
    };
    app.repo_session.repo_state.root = try fixture.repository_root.duplicate();
    defer app.repo_session.repo_state.root.?.deinit();
    defer app.configured_review_store.?.deinit(allocator);
    defer app.review_store_operations.deinit(allocator);
    defer app.human_review_sessions.deinit();
    app.human_review_sessions.current = try human_review_session_mod.Session.init(
        allocator,
        fixture.binding,
        &fixture.findings,
        &loaded.value,
        null,
    );
    const session = app.human_review_sessions.currentSession().?;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    defer ctx.runtimeClearPendingEffectCopies();

    try session.editSummary(allocator, "B");
    const b_save = try app.saveHumanReviewSession(&ctx);
    try std.testing.expect(b_save == .accepted);
    try session.editSummary(allocator, "A");
    const finalized = try app.finalizeHumanReviewSession(&ctx, .approved);
    try std.testing.expect(finalized == .accepted);
    try std.testing.expect(finalized.accepted.draft_operation_id != null);
    try std.testing.expectEqual(@as(usize, 3), session.operationCount());

    const b_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), b_tasks.len);
    const b_message = b_tasks[0].run(b_tasks[0].ctx, allocator, io);
    try std.testing.expect(b_message == .review_store_operation_finished);
    try std.testing.expect(b_message.review_store_operation_finished.result == .draft);
    try std.testing.expect(b_message.review_store_operation_finished.result.draft == .committed);
    var durable_b = try committed_review.ReviewDraftState.parseStrict(
        allocator,
        b_message.review_store_operation_finished.result.draft.committed.canonical_bytes,
    );
    defer durable_b.deinit();
    try std.testing.expectEqualStrings("B", durable_b.value.summary.?);
    try app.update(b_message, &ctx);
    try std.testing.expectEqualStrings("A", session.workingSnapshot().?.summary.?);

    const corrective_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), corrective_tasks.len);
    const corrective_message = corrective_tasks[0].run(corrective_tasks[0].ctx, allocator, io);
    try std.testing.expect(corrective_message == .review_store_operation_finished);
    try std.testing.expect(corrective_message.review_store_operation_finished.result == .draft);
    try std.testing.expect(corrective_message.review_store_operation_finished.result.draft == .committed);
    var durable_a = try committed_review.ReviewDraftState.parseStrict(
        allocator,
        corrective_message.review_store_operation_finished.result.draft.committed.canonical_bytes,
    );
    defer durable_a.deinit();
    try std.testing.expectEqual(@as(u64, 3), durable_a.value.revision);
    try std.testing.expectEqualStrings("A", durable_a.value.summary.?);
    try app.update(corrective_message, &ctx);

    const result_tasks = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), result_tasks.len);
    const result_message = result_tasks[0].run(result_tasks[0].ctx, allocator, io);
    try std.testing.expect(result_message == .review_store_operation_finished);
    try std.testing.expect(result_message.review_store_operation_finished.result == .result);
    try std.testing.expect(result_message.review_store_operation_finished.result.result == .committed);
    var durable_result = try committed_review.RevisionReviewResult.parseStrict(
        allocator,
        result_message.review_store_operation_finished.result.result.committed.canonical_bytes,
    );
    defer durable_result.deinit();
    try std.testing.expectEqual(
        @as(u64, 3),
        result_message.review_store_operation_finished.result.result.committed.revision,
    );
    try std.testing.expectEqualStrings("A", durable_result.value.summary.?);
    try app.update(result_message, &ctx);

    try std.testing.expectEqual(human_review_session_mod.Lifecycle.completed, session.lifecycle());
    try std.testing.expectEqualStrings(
        durable_result.value.summary.?,
        session.completedSnapshot().?.summary.?,
    );
    try std.testing.expect(!app.review_store_operations.hasWork());

    try tmp.dir.createDir(io, "switch-case", .fromMode(0o700));
    var switch_parent = try tmp.dir.openDir(io, "switch-case", .{});
    defer switch_parent.close(io);
    var switch_fixture = try HumanReviewStoreFixture.init(allocator, io, switch_parent, "store");
    defer switch_fixture.deinit(allocator);
    var switch_app: App = .{
        .configured_review_store = try review_store.ConfiguredStore.initConfigured(
            allocator,
            switch_fixture.store_root,
        ),
        .allocator = allocator,
    };
    switch_app.repo_session.repo_state.root = try switch_fixture.repository_root.duplicate();
    defer switch_app.repo_session.repo_state.root.?.deinit();
    defer switch_app.configured_review_store.?.deinit(allocator);
    defer switch_app.review_store_operations.deinit(allocator);
    const accepted = try switch_app.review_store_operations.enqueueDraft(
        allocator,
        &switch_app.configured_review_store.?,
        &switch_app.repo_session.repo_state.root.?,
        null,
        .{
            .binding = switch_fixture.binding,
            .expected_revision = 1,
            .summary = "captured original",
            .finding_dispositions = &.{},
            .anchored_notes = &.{},
        },
    );
    try std.testing.expect(accepted == .accepted);
    try switch_parent.createDir(io, "other", .fromMode(0o700));
    var other = try switch_parent.openDir(io, "other", .{});
    defer other.close(io);
    const initialized = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "init", "--initial-branch=main" },
        .cwd = .{ .dir = other },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(initialized.stdout);
    defer allocator.free(initialized.stderr);
    if (initialized.term != .exited or initialized.term.exited != 0) return error.GitCommandFailed;
    const other_path = try switch_parent.realPathFileAlloc(io, "other", allocator);
    defer allocator.free(other_path);
    switch_app.repo_session.repo_state.root.?.deinit();
    switch_app.repo_session.repo_state.root = try @import("repo/root_capability.zig").RootCapability.openCanonical(other_path);
    var switch_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    defer switch_ctx.runtimeClearPendingEffectCopies();
    try std.testing.expectEqual(@as(usize, 1), try switch_app.review_store_operations.pump(&switch_ctx));
    const captured_tasks = switch_ctx.takePendingTasksWith();
    var captured_message = captured_tasks[0].run(captured_tasks[0].ctx, allocator, io);
    var captured_finished = captured_message.review_store_operation_finished;
    captured_message = undefined;
    try std.testing.expect(captured_finished.result.draft == .committed);
    const captured_outcome = switch_app.review_store_operations.finish(allocator, &captured_finished, false);
    try std.testing.expect(captured_outcome.accepted);

    _ = try switch_app.review_store_operations.enqueueDraft(
        allocator,
        &switch_app.configured_review_store.?,
        &switch_fixture.repository_root,
        null,
        .{
            .binding = switch_fixture.binding,
            .expected_revision = 2,
            .summary = "must fail on marker drift",
            .finding_dispositions = &.{},
            .anchored_notes = &.{},
        },
    );
    var original = try switch_parent.openDir(io, "repository", .{});
    defer original.close(io);
    try original.deleteFile(io, ".git/gitframe/repository-id-v1");
    try original.writeFile(io, .{
        .sub_path = ".git/gitframe/repository-id-v1",
        .data = "923e4567-e89b-42d3-a456-426614174010\n",
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    try std.testing.expectEqual(@as(usize, 1), try switch_app.review_store_operations.pump(&switch_ctx));
    const drift_tasks = switch_ctx.takePendingTasksWith();
    var drift_message = drift_tasks[0].run(drift_tasks[0].ctx, allocator, io);
    var drift_finished = drift_message.review_store_operation_finished;
    drift_message = undefined;
    try std.testing.expectEqual(review_store.PersistenceFailure.binding_changed, drift_finished.result.draft.failure);
    const drift_outcome = switch_app.review_store_operations.finish(allocator, &drift_finished, false);
    try std.testing.expect(drift_outcome.accepted);
    try std.testing.expectEqual(review_store.PersistenceFailure.binding_changed, drift_outcome.failure.?);
    try std.testing.expect(!switch_app.review_store_operations.hasWork());
}

const HumanReviewStoreFixture = struct {
    store_root: [:0]u8,
    repository_root: @import("repo/root_capability.zig").RootCapability,
    binding: review_store.ReviewRunBinding,
    findings: committed_review.FindingSet,
    draft_bytes: []u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        parent: std.Io.Dir,
        name: []const u8,
    ) !HumanReviewStoreFixture {
        const repository_id = try committed_review.ReviewRepositoryId.parse(
            "123e4567-e89b-42d3-a456-426614174000",
        );
        const review_id = try committed_review.ReviewId.parse(
            "223e4567-e89b-42d3-a456-426614174000",
        );
        const oid = try committed_review.ObjectId.parse(
            .sha1,
            "0123456789abcdef0123456789abcdef01234567",
        );
        const review_target: committed_review.CommittedReviewTarget = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = oid,
            .head_oid = oid,
            .diff_base_oid = oid,
        };
        const findings: committed_review.FindingSet = .{
            .schema_version = committed_review.limits.schema_version,
            .review_id = review_id,
            .created_at = "2026-08-28T00:00:00Z",
            .timing = .{ .duration_ms = 1 },
            .target = review_target,
            .producer = .{ .name = "test" },
            .findings = &.{},
        };
        const findings_bytes = try findings.writeCanonical(allocator);
        defer allocator.free(findings_bytes);
        const findings_digest = committed_review.Sha256Digest.hash(findings_bytes);
        const manifest: committed_review.ReviewRunManifest = .{
            .schema_version = committed_review.limits.schema_version,
            .review_id = review_id,
            .review_repository_id = repository_id,
            .target = review_target,
            .created_at = findings.created_at,
            .display = null,
            .finding_count = 0,
            .producer = findings.producer,
            .findings_digest = findings_digest,
        };
        const manifest_bytes = try manifest.writeCanonical(allocator);
        defer allocator.free(manifest_bytes);
        const draft: committed_review.ReviewDraftState = .{
            .schema_version = committed_review.limits.schema_version,
            .review_id = review_id,
            .target = review_target,
            .findings_digest = findings_digest,
            .revision = 1,
            .summary = "A",
            .finding_dispositions = &.{},
            .anchored_notes = &.{},
        };
        const draft_bytes = try draft.writeCanonical(allocator);
        errdefer allocator.free(draft_bytes);

        try parent.createDir(io, "repository", .fromMode(0o700));
        var repository = try parent.openDir(io, "repository", .{});
        defer repository.close(io);
        const initialized = try std.process.run(allocator, io, .{
            .argv = &.{ "git", "init", "--initial-branch=main" },
            .cwd = .{ .dir = repository },
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer allocator.free(initialized.stdout);
        defer allocator.free(initialized.stderr);
        switch (initialized.term) {
            .exited => |code| if (code != 0) return error.GitCommandFailed,
            else => return error.GitCommandFailed,
        }
        try repository.createDir(io, ".git/gitframe", .fromMode(0o700));
        try repository.writeFile(io, .{
            .sub_path = ".git/gitframe/repository-id-v1",
            .data = "123e4567-e89b-42d3-a456-426614174010\n",
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        const repository_path = try parent.realPathFileAlloc(io, "repository", allocator);
        defer allocator.free(repository_path);
        const common_path = try repository.realPathFileAlloc(io, ".git", allocator);
        defer allocator.free(common_path);
        var repository_root = try @import("repo/root_capability.zig").RootCapability.openCanonical(repository_path);
        errdefer repository_root.deinit();

        try parent.createDir(io, name, .fromMode(0o700));
        var store = try parent.openDir(io, name, .{});
        defer store.close(io);
        try store.createDir(io, ".locks", .fromMode(0o700));
        var locks = try store.openDir(io, ".locks", .{});
        defer locks.close(io);
        const repository_text = repository_id.canonical();
        try locks.createDir(io, &repository_text, .fromMode(0o700));
        try store.createDir(io, "repository-123e4567", .fromMode(0o700));
        var namespace = try store.openDir(io, "repository-123e4567", .{});
        defer namespace.close(io);
        const run_directory_name = "20260828-0000-test-223e4567";
        try namespace.createDir(io, run_directory_name, .fromMode(0o700));
        var run = try namespace.openDir(io, run_directory_name, .{});
        defer run.close(io);
        try writeHumanReviewFixtureFile(io, run, "manifest.json", manifest_bytes);
        try writeHumanReviewFixtureFile(io, run, "findings.json", findings_bytes);
        try writeHumanReviewFixtureFile(io, run, "review_state.json", draft_bytes);
        try writeHumanReviewFixtureFile(
            io,
            namespace,
            ".run-223e4567-e89b-42d3-a456-426614174000",
            "{\"schema_version\":1,\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"directory_name\":\"20260828-0000-test-223e4567\"}\n",
        );
        const registry_bytes = try std.fmt.allocPrint(
            allocator,
            "{{\"schema_version\":1,\"bindings\":[{{\"repository_instance_id\":\"123e4567-e89b-42d3-a456-426614174010\",\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"repository_display_name\":\"repository\",\"directory_name\":\"repository-123e4567\",\"last_seen_path\":{{\"encoding\":\"utf8\",\"value\":\"{s}\"}}}}]}}\n",
            .{common_path},
        );
        defer allocator.free(registry_bytes);
        try writeHumanReviewFixtureFile(io, store, "registry.json", registry_bytes);
        return .{
            .store_root = try parent.realPathFileAlloc(io, name, allocator),
            .repository_root = repository_root,
            .binding = .{
                .review_repository_id = repository_id,
                .review_id = review_id,
                .target = review_target,
                .findings_digest = findings_digest,
            },
            .findings = findings,
            .draft_bytes = draft_bytes,
        };
    }

    fn deinit(self: *HumanReviewStoreFixture, allocator: std.mem.Allocator) void {
        self.repository_root.deinit();
        allocator.free(self.draft_bytes);
        allocator.free(self.store_root);
        self.* = undefined;
    }
};

fn writeHumanReviewFixtureFile(
    io: std.Io,
    directory: std.Io.Dir,
    name: []const u8,
    bytes: []const u8,
) !void {
    try directory.writeFile(io, .{
        .sub_path = name,
        .data = bytes,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
}
