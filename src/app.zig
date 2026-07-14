const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const app_actions = @import("app/actions.zig");
const app_auto_reload = @import("app/auto_reload.zig");
const app_commit_panel = @import("app/commit_panel.zig");
const app_direction = @import("app/direction.zig");
const app_input = @import("app/input.zig");
const app_load_state = @import("app/load_state.zig");
const app_load = @import("app/load.zig");
const page = @import("app/page.zig");
const page_link = @import("app/page_link.zig");
const page_transition = @import("app/page_transition.zig");
const app_shell_layout = @import("app/shell_layout.zig");
const review_page = @import("app/pages/review.zig");
const review_content = @import("app/pages/review/content.zig");
const review_layout = @import("app/pages/review/layout.zig");
const review_message = @import("app/pages/review/message.zig");
const review_navigation = @import("app/pages/review/navigation.zig");
const review_authority = @import("app/pages/review/authority.zig");
const review_operations = @import("app/pages/review/operations.zig");
const review_reload = @import("app/pages/review/reload.zig");
const review_page_update = @import("app/pages/review/update.zig");
const review_view = @import("app/pages/review/view.zig");
const repository_page = @import("app/pages/repository.zig");
const repository_selection = @import("app/pages/repository/selection.zig");
const app_prompt = @import("app/prompt.zig");
const app_push_retry = @import("app/push_retry.zig");
const app_repo_picker = @import("app/repo_picker.zig");
const app_review_projection = @import("app/review_projection.zig");
const app_state = @import("app/state.zig");
const app_test_support = if (builtin.is_test) @import("app/test_support.zig") else struct {};
const app_view = @import("app/view.zig");
const app_git_requests = @import("app/git_requests.zig");
const context = @import("context.zig");
const context_export = @import("context_export.zig");
const config_mod = @import("config.zig");
const content_fingerprint = @import("content_fingerprint.zig");
const diff_parser = @import("diff/parser.zig");
const diff_file = @import("diff/file.zig");
const diff_hunk_projection = @import("diff/hunk_projection.zig");
const diff_patch = @import("diff/patch.zig");
const diff_render = @import("diff/render.zig");
const diff_search = @import("diff/search.zig");
const diff_selection = @import("diff/selection.zig");
const diff_source = @import("diff/source.zig");
const diff_view_model = @import("diff/view_model.zig");
const editor = @import("editor.zig");
const file_tree = @import("file_tree.zig");
const git_ops = @import("app/git_ops.zig");
const git_backend = @import("git/backend.zig");
const git_branch_status = @import("git/branch_status.zig");
const git_status = @import("git/status.zig");
const keymap = @import("keymap");
const loaded_diff = @import("loaded_diff.zig");
const repo_discovery = @import("repo/discovery.zig");
const repo_root_capability = @import("repo/root_capability.zig");
const review_session = @import("review/session.zig");
const theme = @import("theme");
const repo_state = @import("repo/state.zig");
const review_state = @import("review/state.zig");
const sidebar_view_model = @import("sidebar/view_model.zig");

const auto_reload_timer_id = "gitframe.auto_reload";
const git_action_spinner_timer_id = "gitframe.git_action_spinner";
const git_action_spinner_interval_ns = 120 * std.time.ns_per_ms;

const PendingRecentPathDiscovery = struct {
    kind: repo_state.RecentKind,
    index: usize,
};

const RepoCommitOutcome = enum { unchanged, changed, rejected };

pub const SourceMode = diff_source.SourceMode;
pub const CliConfig = diff_source.CliConfig;
pub const LoadRequest = diff_source.LoadRequest;
pub const ParseArgsError = diff_source.ParseArgsError;
pub const parseArgs = diff_source.parseArgs;

const DiffLoadFinished = app_load.DiffLoadFinished;
const DiffLoadTask = app_load.DiffLoadTask(App.Msg);
const DiscardTargetResult = git_ops.DiscardTargetResult;
const EmptyReason = app_load_state.EmptyReason;
const HunkMarkSource = git_ops.HunkMarkSource;
const HunkStageTargetResult = git_ops.HunkStageTargetResult;
const HunkUnstageTargetResult = git_ops.HunkUnstageTargetResult;
const HorizontalDirection = app_direction.Horizontal;
const LoadedSession = app_load_state.LoadedSession;
const LoadedDiff = loaded_diff.LoadedDiff;
const LoadRuntimeState = app_load_state.LoadRuntimeState;
const PendingLoad = app_load_state.PendingLoad;
const RepoDiscoveryFinished = app_load.RepoDiscoveryFinished;
const RepoDiscoveryTask = app_load.RepoDiscoveryTask(App.Msg);
const RepoPathDiscoveryFinished = app_load.RepoPathDiscoveryFinished;
const RepoPathDiscoveryTask = app_load.RepoPathDiscoveryTask(App.Msg);
const BranchStatusLoadFinished = app_load.BranchStatusLoadFinished;
const BranchStatusLoadTask = app_load.BranchStatusLoadTask(App.Msg);
const BranchListLoadFinished = app_load.BranchListLoadFinished;
const BranchListLoadTask = app_load.BranchListLoadTask(App.Msg);
const BranchSwitchTargetResult = git_ops.BranchSwitchTargetResult;
const StatusLoadFinished = app_load.StatusLoadFinished;
const StatusLoadTask = app_load.StatusLoadTask(App.Msg);
const PathTarget = git_ops.PathTarget;
const ReviewProjectionFinished = app_load.ReviewProjectionFinished;
const ReviewProjectionTask = app_load.ReviewProjectionTask(App.Msg);
const GeneratedSyntaxTask = app_load.GeneratedSyntaxTask(App.Msg);
const RepositoryManifestTask = repository_page.ManifestTask(App.Msg);
const RepositoryDocumentTask = repository_page.DocumentTask(App.Msg);
const RepositorySyntaxTask = repository_page.SyntaxTask(App.Msg);
const RepositoryChangeMapTask = repository_page.ChangeMapTask(App.Msg);
const source_syntax_runtime = @import("syntax/source_runtime.zig");
const AmendFinished = app_actions.AmendFinished;
const CommitFinished = app_actions.CommitFinished;
const CommitMessageAssistFinished = app_actions.CommitMessageAssistFinished;
const DiscardFileFinished = app_actions.DiscardFileFinished;
const FetchFinished = app_actions.FetchFinished;
const FetchTargetResult = git_ops.FetchTargetResult;
const PullFinished = app_actions.PullFinished;
const PullTargetResult = git_ops.PullTargetResult;
const PushFinished = app_actions.PushFinished;
const PushTargetResult = git_ops.PushTargetResult;
const SwitchBranchFinished = app_actions.SwitchBranchFinished;
const SwitchBranchTask = app_actions.SwitchBranchTask(App.Msg);
const StageHunkFinished = app_actions.StageHunkFinished;
const StageFileFinished = app_actions.StageFileFinished;
const StageTargetResult = git_ops.StageTargetResult;
const SizeDirection = app_direction.Size;
const TargetKind = git_ops.TargetKind;
const ToggleHunkTargetResult = git_ops.ToggleHunkTargetResult;
const ToggleStageTargetResult = git_ops.ToggleStageTargetResult;
const ToggleStageOperation = git_ops.ToggleStageOperation;
const UnstageFileFinished = app_actions.UnstageFileFinished;
const UnstageHunkFinished = app_actions.UnstageHunkFinished;
const UnstageTargetResult = git_ops.UnstageTargetResult;
const VerticalDirection = app_direction.Vertical;
const MousePane = enum {
    sidebar,
    diff,
};

const MousePoint = review_navigation.MousePoint;

const LoadFinishedMsg = app_load.ReadFinished;

const ActionFinishedMsg = union(enum) {
    stage_file: StageFileFinished,
    stage_hunk: StageHunkFinished,
    unstage_file: UnstageFileFinished,
    unstage_hunk: UnstageHunkFinished,
    discard_file: DiscardFileFinished,
    commit: CommitFinished,
    assist_commit_message: CommitMessageAssistFinished,
    amend: AmendFinished,
    push: PushFinished,
    pull: PullFinished,
    fetch: FetchFinished,
    switch_branch: SwitchBranchFinished,
    push_foreground: chasen.ForegroundCommandResult,
    editor: chasen.ForegroundCommandResult,

    fn deinit(self: *ActionFinishedMsg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .push_foreground, .editor => {},
            inline else => |*finished| finished.deinit(allocator),
        }
        self.* = undefined;
    }
};

const DiffLoadStartOptions = review_reload.SourceLoadOptions;

const ShellSurface = enum {
    push_error,
    commit_panel,
};

/// Semantic owner of an effect diagnostic. The shell owns the physical
/// clipboard/process lifecycle, while the captured origin owns presentation.
const EffectOrigin = union(enum) {
    page: PageEffectOrigin,
    shell_surface: ShellSurfaceOrigin,
};

const PageEffectOrigin = app_push_retry.Origin;

const ShellSurfaceOrigin = struct {
    surface: ShellSurface,
    instance_id: u64,
};

const EditorForegroundState = struct {
    request_id: chasen.ForegroundCommandRequestId,
    origin: PageEffectOrigin,
};

const ClipboardCopyState = struct {
    origin: EffectOrigin,
    label: []const u8,
};

fn expandUserPath(allocator: std.mem.Allocator, path: []const u8, home: ?[]const u8) ![]u8 {
    const home_path = home orelse return allocator.dupe(u8, path);
    if (std.mem.eql(u8, path, "~")) return allocator.dupe(u8, home_path);
    if (std.mem.startsWith(u8, path, "~/")) {
        return std.fs.path.join(allocator, &.{ home_path, path[2..] });
    }
    return allocator.dupe(u8, path);
}

const ChangedFileFilter = loaded_diff.ChangedFileFilter;
const OverlayKind = app_state.OverlayKind;

const RepoCommitOrigin = enum {
    discovery_completion,
    external_selection,
};

const PageStates = struct {
    review: review_page.ReviewPageState = .{},
    repository: repository_page.RepositoryPageState = .{},
    history: page.LazyPlaceholder = .{},
    config: page.LazyPlaceholder = .{},
};

pub const App = struct {
    active_page: page.Id = .review,
    repo_epoch: u64 = 0,
    pages: PageStates = .{},
    config: CliConfig = .{},
    user_config: config_mod.Config = .{},
    state_path: ?[]const u8 = null,
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
    actions: app_actions.ActionState = .{},
    git_action_spinner_tick: u8 = 0,
    git_action_spinner_timer_running: bool = false,
    status: app_state.StatusMessage = .{},
    commit_panel: app_commit_panel.State = .{},
    repo_picker: app_prompt.RepoPickerState = .{},
    /// Workspace discovered from path input but not yet selected.
    ///
    /// Keeping this outside repo_state lets the picker show candidates without
    /// changing the active repository until the user presses Enter on a repo.
    repo_picker_discovery: ?repo_discovery.DiscoveryResult = null,
    repo_picker_items: app_repo_picker.ItemList = .empty,
    recent_repos: repo_state.RecentStore = .{},
    pending_repo_path_recent_source: ?PendingRecentPathDiscovery = null,
    overlay: app_state.OverlayState = .{},
    repo_state: repo_state.State = .{},
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

    const ClipboardCopyOutcome = union(enum) {
        sent,
        unsupported_runtime,
        write_failed: []const u8,
    };

    const ClipboardCopyFinished = struct {
        request_id: chasen.ClipboardCopyRequestId,
        outcome: ClipboardCopyOutcome,
    };

    const CopyRequest = struct {
        origin: EffectOrigin,
        label: []const u8,
        text: []const u8,
    };

    const PopupCopyTarget = struct {
        label: []const u8,
        text: []const u8,
    };

    pub const Msg = union(enum) {
        pub const undelivered_policy = .deinit;

        terminal_resized: chasen.Size,
        switch_page: page.Id,
        load_finished: LoadFinishedMsg,
        action_finished: ActionFinishedMsg,
        push_inspection_finished: app_push_retry.Finished,
        clipboard_copy_finished: ClipboardCopyFinished,
        review: review_message.Msg,
        repository: repository_page.Msg,
        cancel_commit_panel,
        submit_commit_panel,
        assist_commit_message,
        copy_commit_message,
        commit_panel_tab,
        commit_panel_enter,
        commit_panel_insert: u21,
        /// Borrowed from `chasen.Event.paste`; valid only in the synchronous handleEvent/update dispatch.
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
        /// Borrowed from `chasen.Event.paste`; valid only in the synchronous handleEvent/update dispatch.
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
        push_credential_tab,
        push_credential_submit,
        push_credential_cancel,
        push_credential_insert: u21,
        push_credential_paste: []const u8,
        push_credential_backspace,
        push_credential_move_left,
        push_credential_move_right,
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
        open_push_credentials,
        run_interactive_push,
        reload,
        auto_reload_tick,
        focus_lost,
        git_action_spinner_tick,
        quit,

        pub fn loadFinished(inner: LoadFinishedMsg) @This() {
            return .{ .load_finished = inner };
        }

        pub fn actionFinished(inner: ActionFinishedMsg) @This() {
            return .{ .action_finished = inner };
        }

        pub fn pushInspectionFinished(inner: app_push_retry.Finished) @This() {
            return .{ .push_inspection_finished = inner };
        }

        /// Releases messages that the Chasen runtime cannot deliver to
        /// `App.update`, most notably task results completed during shutdown.
        /// Synchronous borrowed paste variants and timer/control variants own
        /// no storage and therefore require no action here.
        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .load_finished => |*finished| finished.deinit(allocator),
                .action_finished => |*finished| finished.deinit(allocator),
                .push_inspection_finished => |*finished| finished.deinit(allocator),
                .repository => |*repository_msg| repository_msg.deinitUndelivered(allocator),
                // Most owned async results stay grouped under load_finished or
                // action_finished so exhaustive inner switches force
                // classification. Shell lifecycle completions with their own
                // state machine, such as push inspection, remain explicit.
                else => {},
            }
            self.* = undefined;
        }
    };

    pub fn init(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        self.allocator = ctx.allocator();
        self.commit_panel = app_commit_panel.State.init(ctx.allocator());
        self.pages.review.init(self.config.auto_reload, self.user_config.reload, self.config.source);
        _ = self.activateReview();
        if (self.pages.review.auto_reload.enabled()) {
            try ctx.timer().every(auto_reload_timer_id, self.pages.review.auto_reload.interval_ns, .auto_reload_tick);
        }
        if (diff_source.sourceRequiresRepo(self.config.source)) {
            try self.startRepoDiscovery(ctx, null);
        } else {
            try self.startDiffLoad(ctx, .initial);
        }
    }

    pub fn deinit(self: *App, deinit_ctx: chasen.AppDeinitContext) void {
        if (self.allocator == null) self.allocator = deinit_ctx.allocator;
        self.pages.review.deinit(deinit_ctx.allocator);
        self.pages.repository.deinit(deinit_ctx.allocator);
        self.repo_state.deinit(deinit_ctx.allocator);
        self.commit_panel.deinit();
        self.repo_picker.deinit(deinit_ctx.allocator);
        self.clearRepoPickerDiscovery(deinit_ctx.allocator);
        self.deinitRepoPickerItems(deinit_ctx.allocator);
        self.recent_repos.deinit(deinit_ctx.allocator);
        self.cancelDiscardConfirmation(deinit_ctx.allocator);
        self.cancelAmendConfirmation(deinit_ctx.allocator);
        self.cancelPushConfirmation(deinit_ctx.allocator);
        self.cancelPullConfirmation(deinit_ctx.allocator);
        self.push_retry.deinit(deinit_ctx.allocator);
        self.clipboard_copy_states.deinit(deinit_ctx.allocator);
        self.clearPushError(deinit_ctx.allocator);
        self.clearBranchSwitch(deinit_ctx.allocator);
    }

    /// Builds the concrete Review navigation owner with only the shell inputs
    /// needed by Review-local cursor/search/selection logic. The controller
    /// deliberately cannot reach App, overlays, processes, or async effects.
    fn reviewNavigation(self: *App) review_navigation.Controller {
        const size = self.shellLayout().bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.activeRepoRoot(),
            .source = self.config.source,
            .layout = .{ .width = size.width, .height = size.height },
            .diagnostics = .{ .target = &self.pages.review.status },
        };
    }

    fn reviewNavigationView(self: *const App) review_navigation.View {
        const size = self.shellLayout().bodySize();
        return .{
            .page = &self.pages.review,
            .repo_root = self.activeRepoRoot(),
            .source = self.config.source,
            .layout = .{ .width = size.width, .height = size.height },
        };
    }

    fn reviewOperations(self: *const App) review_operations.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.activeRepoRoot(),
            .activation_state = self.pages.review.activation.state,
        };
    }

    fn reviewContent(self: *const App) review_content.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.activeRepoRoot(),
        };
    }

    fn reviewOperationController(self: *App) review_operations.Controller {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigation(),
            .view_state = self.reviewOperations(),
        };
    }

    fn reviewReload(self: *App) review_reload.Controller {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigation(),
            .source = self.config.source,
            .repo_root = self.activeRepoRoot(),
            .repo_epoch = self.repo_epoch,
            .root_identity = self.repo_state.activeIdentity(),
        };
    }

    fn reviewReloadView(self: *const App) review_reload.View {
        return .{
            .page = &self.pages.review,
            .navigation = self.reviewNavigationView(),
            .source = self.config.source,
            .repo_root = self.activeRepoRoot(),
        };
    }

    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        self.clearEphemeralStatusForUserAction(msg);

        switch (msg) {
            .switch_page => |target| try self.requestPageSwitch(ctx, target),
            .terminal_resized => |size| {
                // Mouse coordinates are relative to the old geometry. End the
                // borrow before changing layout, then drain deferred owners at
                // the common post-update boundary below.
                self.reviewNavigation().terminateDiffSelection();
                self.pages.repository.cancelSourceSelection();
                const previous_width = self.reviewNavigationView().diffPaneWidth();
                const previous_mode = self.reviewNavigationView().effectiveDisplayMode();
                self.terminal_size = size;
                self.reviewNavigation().resetDiffHorizontalScrollIfPaneWidthChanged(previous_width);
                if (previous_mode != self.reviewNavigationView().effectiveDisplayMode()) self.reviewNavigation().clearDiffSelection();
                self.reviewNavigation().clampSidebarHorizontalScroll();
                self.reviewNavigation().clampDiffNavigationKeepingHunkVisible();
                self.reviewNavigation().updateSearchMatchOffset();
                self.reviewNavigation().scrollSearchMatchIntoView();
                self.reviewNavigation().clampDiffNavigation();
                self.pages.repository.clampForBodySize(self.shellLayout().bodySize());
                self.clampHelpScroll();
                self.clampPushErrorScroll();
            },
            .load_finished => |finished| try self.finishLoadResult(ctx, finished),
            .action_finished => |finished| try self.finishActionResult(ctx, finished),
            .push_inspection_finished => |finished| try self.finishPushInspection(ctx, finished),
            .clipboard_copy_finished => |finished| self.finishClipboardCopy(ctx, finished),
            .review => |review_msg| try self.updateReview(ctx, review_msg),
            .repository => |repository_msg| try self.updateRepository(ctx, repository_msg),
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
                if (self.active_page == .repository) self.pages.repository.cancelSourceSelection();
                try self.enterRepoPickerMode(ctx.allocator());
            },
            .cancel_repo_picker => try self.cancelRepoPickerMode(ctx.allocator()),
            .close_repo_picker => self.closeRepoPickerMode(ctx.allocator()),
            .submit_repo_picker => try self.submitRepoPicker(ctx),
            .repo_picker_enter_filter_input => try self.enterRepoPickerFilterInput(ctx.allocator()),
            .repo_picker_enter_path_input => self.enterRepoPickerPathInput(),
            .repo_picker_back => try self.backRepoPicker(ctx.allocator()),
            .repo_picker_remove_recent => try self.removeSelectedRecentRepository(ctx),
            .repo_picker_insert => |codepoint| {
                try self.insertRepoPickerCodepoint(ctx.allocator(), codepoint);
            },
            .repo_picker_paste => |text| {
                try self.insertRepoPickerSlice(ctx.allocator(), text);
            },
            .repo_picker_backspace => {
                try self.backspaceRepoPicker(ctx.allocator());
            },
            .repo_picker_move_previous => self.repo_picker.list.filter.update(.move_prev),
            .repo_picker_move_next => self.repo_picker.list.filter.update(.move_next),
            .repo_picker_move_left => self.moveRepoPickerCursorLeft(),
            .repo_picker_move_right => self.moveRepoPickerCursorRight(),
            .open_help => {
                if (self.active_page == .review) self.reviewNavigation().clearDiffSelection();
                if (self.active_page == .repository) self.pages.repository.cancelSourceSelection();
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
                    self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());
                    self.clearBranchSwitch(ctx.allocator());
                    if (diff_source.sourceIsOneShotInput(self.config.source)) {
                        ctx.redraw().skip();
                    } else if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
                        try self.startRepoDiscovery(ctx, null);
                    } else {
                        try self.startDiffLoad(ctx, .manual);
                    }
                },
                .repository => self.pages.repository.requestReload(self.activeRepoRoot() != null),
                .history, .config => self.status.set("reload is not available on this page yet", .{}),
            },
            .auto_reload_tick => try self.autoReloadTick(ctx),
            .focus_lost => switch (self.active_page) {
                .review => self.reviewNavigation().terminateDiffSelection(),
                .repository => self.pages.repository.cancelSourceSelection(),
                .history, .config => {},
            },
            .git_action_spinner_tick => self.gitActionSpinnerTick(ctx),
            .quit => self.requestQuit(ctx),
        }
        if (!self.pages.review.selection_owner.activeMouseSelection() and self.pages.review.deferred_source_apply != null) {
            try self.applyDeferredSource(ctx);
        }
        if (!self.pages.review.selection_owner.activeMouseSelection() and self.pages.review.deferred_projection_apply != null) {
            try self.reviewReload().applyDeferredProjection(ctx.allocator());
        }
        try self.maybeStartQueuedReviewRevalidation(ctx);
        try self.maybeStartRepositoryManifest(ctx);
        try self.maybeStartRepositoryDocument(ctx);
        try self.maybeStartRepositorySyntax(ctx);
        self.maybeStartRepositoryChangeMap(ctx);
        if (self.active_page == .review) try self.ensureReviewProjection(ctx);
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
            .repo_epoch = self.repo_epoch,
            .root_identity = self.repo_state.activeIdentity(),
        }).apply(self.allocator, msg);
        defer page_update.deinit(self.allocator);

        if (page_update.capture_display_override) {
            try self.reviewReload().captureDisplayOverride(ctx.allocator());
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

    fn updateRepository(self: *App, ctx: *chasen.Ctx(Msg), msg: repository_page.Msg) !void {
        switch (msg) {
            .manifest_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.pages.repository.applyFinished(ctx.allocator(), &owned);
                if (self.active_page != .repository or outcome == .discarded or outcome == .unchanged) ctx.redraw().skip();
            },
            .document_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.pages.repository.applyDocumentFinished(ctx.allocator(), &owned);
                if (self.active_page != .repository or outcome == .discarded or outcome == .unchanged) ctx.redraw().skip();
            },
            .syntax_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.pages.repository.applySyntaxFinished(ctx.allocator(), &owned);
                if (self.active_page != .repository or outcome != .changed) ctx.redraw().skip();
            },
            .change_map_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.pages.repository.applyChangeMapFinished(ctx.allocator(), &owned);
                if (self.active_page != .repository or outcome != .changed) ctx.redraw().skip();
            },
            else => {
                if (self.active_page != .repository) {
                    ctx.redraw().skip();
                    return;
                }
                var page_update = self.pages.repository.applyNavigation(ctx.allocator(), msg, self.shellLayout().bodySize());
                defer page_update.deinit(ctx.allocator());
                var command = page_update.takeCommand() orelse return;
                defer command.deinit(ctx.allocator());
                switch (command) {
                    .copy_source_selection => |text| self.copySourceSelection(ctx, text),
                }
            },
        }
    }

    fn maybeStartRepositoryManifest(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .repository or !self.pages.repository.wantsManifestRequest()) return;
        const repo_root = self.activeRepoRoot() orelse {
            self.pages.repository.requestReload(false);
            return;
        };
        const capability = self.repo_state.activeCapability() orelse {
            self.pages.repository.requestReload(false);
            return;
        };

        var request = self.pages.repository.prepareRequest(ctx.allocator(), repo_root, capability) catch |err| {
            self.pages.repository.markRequestPreparationFailed(err);
            return err;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(RepositoryManifestTask) catch |err| {
            self.pages.repository.rejectSpawn(generation);
            return err;
        };
        task.* = .{
            .identity = request.identity,
            .generation = request.generation,
            .root_path = request.root_path,
            .root = request.root,
            .expected_fingerprint = request.expected_fingerprint,
            .expected_status_fingerprint = request.expected_status_fingerprint,
        };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = RepositoryManifestTask.run, .failed = RepositoryManifestTask.failed }) catch |err| {
            ctx.allocator().free(task.root_path);
            task.root.deinit();
            ctx.allocator().destroy(task);
            self.pages.repository.rejectSpawn(generation);
            return err;
        };
    }

    fn maybeStartRepositoryDocument(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .repository or !self.pages.repository.wantsDocumentRequest()) return;
        const capability = self.repo_state.activeCapability() orelse {
            self.pages.repository.markDocumentCapabilityUnavailable();
            return;
        };
        var request = self.pages.repository.prepareDocumentRequest(ctx.allocator(), capability) catch |err| {
            self.pages.repository.markDocumentRequestPreparationFailed(err);
            return err;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(RepositoryDocumentTask) catch |err| {
            self.pages.repository.rejectDocumentSpawn(generation);
            return err;
        };
        task.* = .{
            .identity = request.identity,
            .generation = request.generation,
            .manifest_revision = request.manifest_revision,
            .path = request.path,
            .root = request.root,
        };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = RepositoryDocumentTask.run, .failed = RepositoryDocumentTask.failed }) catch |err| {
            ctx.allocator().free(task.path);
            task.root.deinit();
            ctx.allocator().destroy(task);
            self.pages.repository.rejectDocumentSpawn(generation);
            return err;
        };
    }

    fn maybeStartRepositorySyntax(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .repository or !self.pages.repository.wantsSyntaxRequest()) return;
        const capability = self.repo_state.activeCapability() orelse return;
        var request = self.pages.repository.prepareSyntaxRequest(ctx.allocator(), capability) catch {
            self.pages.repository.markSyntaxRequestPreparationFailed();
            return;
        };
        // Ownership changes only after the task captures both path and root.
        // Before that point the request defer is the single cleanup path; after
        // it, spawn rejection must dismantle the concrete task context itself.
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(RepositorySyntaxTask) catch {
            self.pages.repository.rejectSyntaxSpawn(generation);
            return;
        };
        task.* = .{
            .identity = request.identity,
            .generation = request.generation,
            .manifest_revision = request.manifest_revision,
            .source_revision = request.source_revision,
            .expected_fingerprint = request.expected_fingerprint,
            .path = request.path,
            .root = request.root,
        };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = RepositorySyntaxTask.run, .failed = RepositorySyntaxTask.failed }) catch {
            ctx.allocator().free(task.path);
            task.root.deinit();
            ctx.allocator().destroy(task);
            self.pages.repository.rejectSyntaxSpawn(generation);
        };
    }

    fn maybeStartRepositoryChangeMap(self: *App, ctx: *chasen.Ctx(Msg)) void {
        if (self.active_page != .repository or !self.pages.repository.wantsChangeMapRequest()) return;
        const capability = self.repo_state.activeCapability() orelse return;
        var request = self.pages.repository.prepareChangeMapRequest(
            ctx.allocator(),
            capability,
            self.repositoryChangeTempBase(),
        ) catch {
            self.pages.repository.markChangeMapRequestPreparationFailed();
            return;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(RepositoryChangeMapTask) catch {
            self.pages.repository.rejectChangeMapSpawn(generation);
            return;
        };
        task.* = .{
            .identity = request.identity,
            .generation = request.generation,
            .manifest_revision = request.manifest_revision,
            .source_revision = request.source_revision,
            .expected_fingerprint = request.expected_fingerprint,
            .expected_content_line_count = request.expected_content_line_count,
            .path = request.path,
            .root = request.root,
            .temp_base_path = request.temp_base_path,
        };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = RepositoryChangeMapTask.run, .failed = RepositoryChangeMapTask.failed }) catch {
            ctx.allocator().free(task.path);
            task.root.deinit();
            ctx.allocator().free(task.temp_base_path);
            ctx.allocator().destroy(task);
            self.pages.repository.rejectChangeMapSpawn(generation);
        };
    }

    fn repositoryChangeTempBase(self: *const App) []const u8 {
        const map = self.env_map orelse return "/tmp";
        const configured = map.get("XDG_RUNTIME_DIR") orelse return "/tmp";
        return if (std.fs.path.isAbsolute(configured)) configured else "/tmp";
    }

    fn finishLoadResult(self: *App, ctx: *chasen.Ctx(Msg), finished: LoadFinishedMsg) !void {
        switch (finished) {
            .review => |review_result| switch (review_result) {
                .source => |result| try self.finishDiffLoad(ctx, result),
                .status => |result| try self.finishStatusLoad(ctx, result),
                .branch_status => |result| self.finishBranchStatusLoad(ctx, result),
                .projection => |result| try self.finishReviewProjectionLoad(ctx, result),
                .projection_syntax => |result| self.finishGeneratedProjectionSyntax(ctx, result),
            },
            .shell => |shell_result| switch (shell_result) {
                .repo_path_discovery => |result| try self.finishRepoPathDiscovery(ctx, result),
                .branch_list => |result| try self.finishBranchListLoad(ctx, result),
            },
            .coordinator => |coordinator_result| switch (coordinator_result) {
                .repo_discovery => |result| try self.finishRepoDiscovery(ctx, result),
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
                .manifest_finished => true,
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
            ctx.redraw().skip();
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
        return .{
            .review = self.reviewViewContext(),
            .repository = .{ .page_state = &self.pages.repository, .palette = self.theme },
            .active_page = self.active_page,
            .page_bar_visible = true,
            .theme = self.theme,
            .keymap = self.keymap,
            .terminal_size = self.terminal_size,
            .actions = &self.actions,
            .status = &self.status,
            .page_status = self.activePageStatus(),
            .commit_panel = &self.commit_panel,
            .repo_picker = &self.repo_picker,
            .repo_picker_discovery = self.repo_picker_discovery,
            .repo_picker_items = &self.repo_picker_items,
            .recent_repos = &self.recent_repos,
            .overlay = &self.overlay,
            .repo_state = &self.repo_state,
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
            .show_repo_picker = self.repo_state.workspaceRepos() != null,
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
            self.activeRepoRoot(),
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
        if (self.pages.review.selection_owner.activeMouseSelection()) {
            switch (mouse.type) {
                .drag => return .{ .review = .{ .mouse_diff_drag = self.bodyMousePoint(mouse) } },
                .release => return .{ .review = .{ .mouse_diff_release = self.bodyMousePoint(mouse) } },
                else => {},
            }
        }
        if (self.pages.repository.activeSourceSelection()) {
            const body_point: ?repository_page.BodyPoint = if (self.bodyMousePoint(mouse)) |point|
                .{ .col = point.col, .row = point.row }
            else
                null;
            const source_point = repository_page.sourceGesturePoint(body_point, self.shellLayout().bodySize());
            switch (mouse.type) {
                .drag => return .{ .repository = .{ .mouse_source_drag = source_point } },
                .release => return .{ .repository = .{ .mouse_source_release = source_point } },
                else => {},
            }
        }

        if ((self.active_page == .review and (self.pages.review.search.mode or self.pages.review.file_search.mode)) or
            (self.active_page == .repository and (self.pages.repository.source_search.mode or self.pages.repository.file_search.mode)) or
            self.commit_panel.is_open or self.repo_picker.mode) return null;
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
                    if (point.row == 0) {
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
        if (self.pages.repository.activeSourceSelection()) return null;
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

    fn contentMousePoint(self: *const App, mouse: anytype) ?MousePoint {
        const point = self.shellLayout().terminalToContent(mouse.col, mouse.row) orelse return null;
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
            .repository = self.pages.repository.inputContext(self.keymap),
            .commit_panel_mode = self.commit_panel.is_open,
            .repo_picker_mode = self.repo_picker.mode,
            .repo_picker_input_mode = self.repo_picker.input_mode,
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
            .history, .config => null,
        };
    }

    fn activateReview(self: *App) u64 {
        const source_member: review_authority.MemberFreshness = if (diff_source.sourceIsOneShotInput(self.config.source))
            switch (self.pages.review.load.state) {
                .loaded, .empty => .immutable,
                .loading => .pending,
                .failed => .failed,
                .idle => .pending,
            }
        else
            .pending;
        const has_repo = self.activeRepoRoot() != null;
        const auxiliary: review_authority.MemberFreshness = if (diff_source.sourceRequiresRepo(self.config.source) and has_repo)
            .pending
        else
            .unavailable;
        return self.pages.review.activation.activate(self.repo_epoch, source_member, auxiliary, auxiliary);
    }

    fn pageTransitionSnapshot(self: *const App) page_transition.Snapshot {
        return .{
            .review_mouse_selection = self.pages.review.selection_owner.activeMouseSelection(),
            .repository_mouse_selection = self.pages.repository.activeSourceSelection(),
            .review_deferred_apply = self.pages.review.deferred_source_apply != null,
            .review_search = self.pages.review.search.mode,
            .review_file_search = self.pages.review.file_search.mode,
            .repository_source_search = self.pages.repository.source_search.mode,
            .repository_file_search = self.pages.repository.file_search.mode,
            .repo_picker = self.repo_picker.mode,
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
        };
    }

    /// Single page-transition entry point for keyboard, mouse, and future
    /// Session API requests. It applies the policy before mutating either page.
    fn requestPageSwitch(self: *App, ctx: *chasen.Ctx(Msg), target: page.Id) !void {
        switch (page_transition.disposition(self.active_page, target, self.pageTransitionSnapshot())) {
            .unchanged => {
                self.status.clearIfEphemeral();
                return;
            },
            .blocked => |blocker| {
                self.status.set("{s}", .{blocker.message()});
                return;
            },
            .allowed => {},
        }

        self.status.clearIfEphemeral();
        if (self.active_page == .review) self.pages.review.activation.deactivate();
        if (self.active_page == .repository) self.pages.repository.deactivate();
        self.active_page = target;
        switch (target) {
            .review => {
                _ = self.activateReview();
                try self.requestReviewRevalidation(ctx);
            },
            .repository => self.pages.repository.activate(self.repo_epoch, self.repo_state.activeIdentity()),
            .history => self.pages.history.ensureInitialized(),
            .config => self.pages.config.ensureInitialized(),
        }
    }

    fn reviewReadBusy(self: *const App) bool {
        return self.pages.review.auto_reload.background_cycle != null or
            self.pages.review.load.hasPending() or self.pages.review.load.state == .loading or
            self.pages.review.status_load.isPending() or self.pages.review.branch_status_load.isPending() or
            self.pages.review.deferred_source_apply != null;
    }

    fn requestReviewRevalidation(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .review) return;
        if (diff_source.sourceIsOneShotInput(self.config.source)) return;
        if (self.reviewReadBusy()) {
            self.pages.review.activation.queueRevalidation();
            return;
        }
        try self.startReviewRevalidation(ctx);
    }

    fn startReviewRevalidation(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .review) return;
        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx, null);
            return;
        }
        const cycle_id = self.pages.review.auto_reload.beginCycle();
        errdefer if (cycle_id) |id| self.pages.review.auto_reload.discardEmptyCycle(id);
        try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
            if (cycle_id) |id| self.pages.review.auto_reload.discardEmptyCycle(id);
            return;
        }, .{
            .clear_visible_state = self.pages.review.load.state == .idle,
            .kind = .watch,
            .background_cycle_id = cycle_id,
        });
        if (cycle_id) |id| self.pages.review.auto_reload.discardEmptyCycle(id);
    }

    fn maybeStartQueuedReviewRevalidation(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .review or self.reviewReadBusy()) return;
        if (!self.pages.review.activation.takeQueuedRevalidation()) return;
        try self.startReviewRevalidation(ctx);
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

    fn startRepoDiscovery(self: *App, ctx: *chasen.Ctx(Msg), background_cycle_id: ?u64) !void {
        var review_update = try self.reviewReload().prepareRepoDiscovery(ctx.allocator(), background_cycle_id);
        defer review_update.deinit(ctx.allocator());
        var command = review_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const discovery = &command.repo_discovery;
        const generation = discovery.generation;
        const task = ctx.allocator().create(RepoDiscoveryTask) catch |err| {
            self.reviewReload().rejectRepoDiscoverySpawn(generation);
            return err;
        };
        task.* = .{
            .identity = discovery.identity,
            .generation = discovery.generation,
            .background_cycle_id = discovery.background_cycle_id,
        };
        command_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = RepoDiscoveryTask.run, .failed = RepoDiscoveryTask.failed }) catch |err| {
            ctx.allocator().destroy(task);
            self.reviewReload().rejectRepoDiscoverySpawn(generation);
            try self.reviewReload().storeFailedMessage(ctx.allocator(), "Could not start repo discovery task");
            return err;
        };
        self.reviewReload().acceptRepoDiscoverySpawn(background_cycle_id);
    }

    fn finishRepoDiscovery(self: *App, ctx: *chasen.Ctx(Msg), finished: RepoDiscoveryFinished) !void {
        defer if (self.active_page != .review) ctx.redraw().skip();
        var result = finished;
        defer result.deinit(ctx.allocator());

        var applied = try self.reviewReload().applyRepoDiscoveryFinished(ctx.allocator(), &result);
        defer applied.deinit(ctx.allocator());
        const discovery = applied.commit_discovery orelse return;

        try self.recent_repos.rememberDiscovery(ctx.allocator(), discovery);
        self.persistRecentRepositories(ctx);
        const owned_discovery = applied.takeCommitDiscovery() orelse unreachable;
        _ = self.commitRepoDiscovery(ctx.allocator(), owned_discovery, 0, .discovery_completion);

        switch (self.reviewReload().applyRepoDiscoveryCommit(
            ctx.allocator(),
            self.activeRepoRoot() != null,
            self.active_page == .review,
        )) {
            .none => {},
            .start_initial_read => try self.startDiffLoad(ctx, .initial),
        }
    }

    fn startDiffLoad(self: *App, ctx: *chasen.Ctx(Msg), kind: review_page.ReloadKind) !void {
        const repo_root = self.repoRootForCurrentSource() catch {
            self.reviewReload().replaceMissingRepository(ctx.allocator());
            return;
        };

        try self.startDiffLoadWithRepoRoot(ctx, repo_root, .{ .clear_visible_state = true, .kind = kind });
    }

    fn startDiffLoadWithRepoRoot(self: *App, ctx: *chasen.Ctx(Msg), repo_root: ?[]const u8, options: DiffLoadStartOptions) !void {
        if (repo_root) |root| {
            self.startStatusLoad(ctx, root, if (options.kind == .watch) .background else .foreground, options.background_cycle_id);
            self.startBranchStatusLoad(ctx, root, options.background_cycle_id);
        } else {
            self.reviewReload().dropStatusSnapshot(ctx.allocator());
            self.reviewReload().invalidateBranchStatusSnapshot();
        }

        var review_update = self.reviewReload().prepareSourceLoad(ctx.allocator(), repo_root, options) catch |err| {
            self.reviewReload().failActiveMember(.source);
            return err;
        };
        defer review_update.deinit(ctx.allocator());
        var command = review_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const source = &command.source_load;
        const generation = source.generation;
        const task = ctx.allocator().create(DiffLoadTask) catch |err| {
            self.reviewReload().rejectSourceSpawn(ctx.allocator(), generation);
            return err;
        };
        task.* = .{
            .identity = source.identity,
            .request = source.request,
            .generation = source.generation,
            .expected_fingerprint = source.expected_fingerprint,
            .background_cycle_id = source.background_cycle_id,
        };
        command_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = DiffLoadTask.run, .failed = DiffLoadTask.failed }) catch |err| {
            diff_source.freeLoadRequest(ctx.allocator(), task.request);
            ctx.allocator().destroy(task);
            self.reviewReload().rejectSourceSpawn(ctx.allocator(), generation);
            try self.reviewReload().storeFailedMessage(ctx.allocator(), "Could not start diff load task");
            return err;
        };
        self.reviewReload().acceptSourceSpawn(options.background_cycle_id);
    }

    fn startStatusLoad(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        repo_root: []const u8,
        origin: git_backend.ReadOrigin,
        background_cycle_id: ?u64,
    ) void {
        var review_update = self.reviewReload().prepareStatusLoad(
            ctx.allocator(),
            repo_root,
            origin,
            background_cycle_id,
        ) catch {
            self.reviewReload().failActiveMember(.status);
            self.setReviewStatus("could not allocate status repo root", .{});
            return;
        };
        defer review_update.deinit(ctx.allocator());
        var command = review_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const status_read = &command.status_load;
        const task = ctx.allocator().create(StatusLoadTask) catch {
            self.reviewReload().rejectStatusSpawn(ctx.allocator(), background_cycle_id);
            self.setReviewStatus("could not allocate status load task", .{});
            return;
        };
        task.* = .{
            .identity = status_read.identity,
            .repo_root = status_read.repo_root,
            .generation = status_read.generation,
            .origin = status_read.origin,
            .background_cycle_id = status_read.background_cycle_id,
        };
        command_consumed = true;

        ctx.task().spawnWith(.{ .ctx = task, .run = StatusLoadTask.run, .failed = StatusLoadTask.failed }) catch {
            // Status is auxiliary data. Keep the diff load going even if this
            // task cannot start; the invalidated generation prevents any older
            // in-flight status result from restoring a stale snapshot.
            ctx.allocator().free(task.repo_root);
            ctx.allocator().destroy(task);
            self.reviewReload().rejectStatusSpawn(ctx.allocator(), background_cycle_id);
            self.setReviewStatus("could not start status load task", .{});
            return;
        };
        self.reviewReload().acceptStatusSpawn(background_cycle_id);
    }

    fn startBranchStatusLoad(self: *App, ctx: *chasen.Ctx(Msg), repo_root: []const u8, background_cycle_id: ?u64) void {
        var review_update = self.reviewReload().prepareBranchStatusLoad(
            ctx.allocator(),
            repo_root,
            background_cycle_id,
        ) catch {
            self.reviewReload().failActiveMember(.branch);
            self.setReviewStatus("could not allocate branch status repo root", .{});
            return;
        };
        defer review_update.deinit(ctx.allocator());
        var command = review_update.takeCommand() orelse unreachable;
        var command_consumed = false;
        defer if (!command_consumed) command.deinit(ctx.allocator());
        const branch_read = &command.branch_status_load;
        const task = ctx.allocator().create(BranchStatusLoadTask) catch {
            self.reviewReload().rejectBranchStatusSpawn(background_cycle_id);
            self.setReviewStatus("could not allocate branch status load task", .{});
            return;
        };
        task.* = .{
            .identity = branch_read.identity,
            .repo_root = branch_read.repo_root,
            .generation = branch_read.generation,
            .background_cycle_id = branch_read.background_cycle_id,
        };
        command_consumed = true;

        ctx.task().spawnWith(.{ .ctx = task, .run = BranchStatusLoadTask.run, .failed = BranchStatusLoadTask.failed }) catch {
            ctx.allocator().free(task.repo_root);
            ctx.allocator().destroy(task);
            self.reviewReload().rejectBranchStatusSpawn(background_cycle_id);
            self.setReviewStatus("could not start branch status load task", .{});
            return;
        };
        self.reviewReload().acceptBranchStatusSpawn(background_cycle_id);
    }

    fn applyDeferredSource(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        var applied = try self.reviewReload().applyDeferredSource(
            ctx.allocator(),
            self.backgroundActionBlocksAcceptance(),
        ) orelse return;
        defer applied.deinit(ctx.allocator());
        self.applySourceShellOutcome(ctx, applied.source);
    }

    fn ensureReviewProjection(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        var review_update = try self.reviewReload().prepareProjection(self.allocator);
        if (review_update.takeCommand()) |command| {
            const allocator = ctx.allocator();
            var owned_command = command;
            var command_consumed = false;
            defer if (!command_consumed) owned_command.deinit(allocator);

            switch (owned_command) {
                .repo_discovery, .source_load, .status_load, .branch_status_load => unreachable,
                .review_projection => |*request| {
                    const request_id = request.id;
                    var root: ?repo_root_capability.RootCapability = null;
                    if (request.kind == .generated_added_file) {
                        const capability = self.repo_state.activeCapability() orelse {
                            self.reviewReload().rejectProjectionSpawn(allocator, request_id);
                            return;
                        };
                        if (!request.matchesRootIdentity(capability.identity)) {
                            self.reviewReload().rejectProjectionSpawn(allocator, request_id);
                            return;
                        }
                        root = capability.duplicate() catch |err| {
                            self.reviewReload().rejectProjectionSpawn(allocator, request_id);
                            return err;
                        };
                    }
                    errdefer if (root) |*owned| owned.deinit();
                    const task = allocator.create(ReviewProjectionTask) catch |err| {
                        self.reviewReload().rejectProjectionSpawn(allocator, request_id);
                        return err;
                    };
                    task.* = .{ .request = request.*, .root = root };
                    root = null;
                    request.* = undefined;
                    command_consumed = true;

                    ctx.task().spawnWith(.{ .ctx = task, .run = ReviewProjectionTask.run, .failed = ReviewProjectionTask.failed }) catch |err| {
                        task.request.deinit(allocator);
                        if (task.root) |*owned| owned.deinit();
                        allocator.destroy(task);
                        self.reviewReload().rejectProjectionSpawn(allocator, request_id);
                        return err;
                    };
                    return;
                },
            }
        }
        if (source_syntax_runtime.enabled) self.ensureGeneratedProjectionSyntax(ctx);
    }

    /// Best-effort decoration for an already usable generated-file preview.
    ///
    /// The primary projection has established the plain display before this
    /// path runs. Allocation, root duplication, and task-queue failures must
    /// therefore leave that display usable and retryable instead of turning an
    /// optional syntax enhancement into an application-level failure.
    fn ensureGeneratedProjectionSyntax(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const allocator = self.allocator orelse return;
        var request = self.reviewReload().prepareGeneratedSyntax(allocator) catch return orelse return;
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(allocator);
        const request_id = request.id;
        const capability = self.repo_state.activeCapability() orelse {
            self.reviewReload().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
        if (!capability.identity.eql(request.root_identity)) {
            self.reviewReload().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        }
        var root = capability.duplicate() catch {
            self.reviewReload().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
        var root_consumed = false;
        defer if (!root_consumed) root.deinit();
        const task = allocator.create(GeneratedSyntaxTask) catch {
            self.reviewReload().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
        task.* = .{ .request = request, .root = root };
        request_consumed = true;
        root_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = GeneratedSyntaxTask.run, .failed = GeneratedSyntaxTask.failed }) catch {
            task.request.deinit(allocator);
            task.root.deinit();
            allocator.destroy(task);
            self.reviewReload().rejectGeneratedSyntaxSpawn(allocator, request_id);
            return;
        };
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
        try self.reviewNavigation().setPendingSelectionRestore(ctx.allocator(), owned.path);
        errdefer self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());

        app_git_requests.startStageFile(Msg, ctx, &self.actions, .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .kind = owned.kind,
            .label = owned.label,
        }) catch |err| {
            self.setReviewStatus("could not start stage task", .{});
            return err;
        };
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
        var task_target: git_ops.HunkStageTarget = .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .hunk_index = owned.hunk_index,
            .patch = owned.patch,
            .mark_source = owned.mark_source,
            .reload_after_success = owned.reload_after_success,
        };
        owned.patch = &.{};
        app_git_requests.startStageHunk(Msg, ctx, &self.actions, &task_target) catch |err| {
            self.setReviewStatus("could not start hunk stage task", .{});
            return err;
        };
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
        var task_target: git_ops.HunkUnstageTarget = .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .hunk_index = owned.hunk_index,
            .patch = owned.patch,
            .mark_source = owned.mark_source,
            .reload_after_success = owned.reload_after_success,
        };
        owned.patch = &.{};
        app_git_requests.startUnstageHunk(Msg, ctx, &self.actions, &task_target) catch |err| {
            self.setReviewStatus("could not start hunk unstage task", .{});
            return err;
        };
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
        try self.reviewNavigation().setPendingSelectionRestore(ctx.allocator(), owned.path);
        errdefer self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());

        app_git_requests.startUnstageFile(Msg, ctx, &self.actions, .{
            .repo_root = owned.repo_root,
            .path = owned.path,
            .kind = owned.kind,
            .label = owned.label,
        }) catch |err| {
            self.setReviewStatus("could not start unstage task", .{});
            return err;
        };
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

        try self.reviewNavigation().setPendingSelectionRestore(ctx.allocator(), confirmation.path);
        errdefer self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());

        app_git_requests.startDiscardFile(Msg, ctx, &self.actions, confirmation.repo_root, confirmation.path) catch |err| {
            self.setReviewStatus("could not start discard task", .{});
            return err;
        };

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
            if (pending.kind == .assist_commit_message) self.actions.clear();
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

        const repo_root = self.activeRepoRoot() orelse {
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

        const repo_root = self.activeRepoRoot() orelse {
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

        app_git_requests.startCommitMessageAssist(Msg, ctx, &self.actions, &request) catch |err| {
            self.commit_panel.commit_error = .assist_failed;
            self.setReviewStatus("could not start commit message action", .{});
            return err;
        };

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
            if (action.scope == .commit and action.stdin == .staged_diff and action.output == .commit_message) {
                if (found != null) return error.Multiple;
                found = action;
            }
        }
        return found orelse error.Missing;
    }

    fn resolveImproveCommitMessageAction(self: *const App) CommitMessageActionResolveError!config_mod.ExternalActionConfig {
        var found: ?config_mod.ExternalActionConfig = null;
        for (self.user_config.actions.slice()) |action| {
            if (action.scope == .commit and action.stdin == .commit_message_context and action.output == .commit_message) {
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

        app_git_requests.startCommit(Msg, ctx, &self.actions, &request) catch |err| {
            self.commit_panel.commit_error = .commit_failed;
            self.setReviewStatus("could not start commit task", .{});
            return err;
        };

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

        app_git_requests.startAmend(Msg, ctx, &self.actions, &confirmation) catch |err| {
            if (self.overlay.isAmendCommit()) self.overlay.close();
            self.commit_panel.commit_error = .amend_failed;
            self.setReviewStatus("could not start amend task", .{});
            return err;
        };

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

        app_git_requests.startPush(Msg, ctx, &self.actions, self.env_map, &confirmation) catch |err| {
            self.setReviewStatus("could not start push task", .{});
            if (self.overlay.isPushBranch()) self.overlay.close();
            return err;
        };

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

        app_git_requests.startPull(Msg, ctx, &self.actions, self.env_map, &confirmation) catch |err| {
            self.setReviewStatus("could not start pull task", .{});
            if (self.overlay.isPullBranch()) self.overlay.close();
            return err;
        };

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
        app_git_requests.startFetch(Msg, ctx, &self.actions, self.env_map, &request) catch |err| {
            self.setReviewStatus("could not start fetch task", .{});
            return err;
        };
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
            .repo_epoch = self.repo_epoch,
            .activation_id = self.pages.review.activation.next_activation_id,
            .repo_root = &.{},
            .generation = generation,
        };
        errdefer ctx.allocator().destroy(task);
        task.repo_root = try ctx.allocator().dupe(u8, target.repo_root);
        errdefer ctx.allocator().free(task.repo_root);
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
        app_git_requests.startSwitchBranch(Msg, ctx, &self.actions, &request) catch |err| {
            self.setReviewStatus("could not start branch switch task", .{});
            return err;
        };

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
        if (result.repo_epoch != self.repo_epoch) return;

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
        if (self.active_page != result.origin.page_id) ctx.redraw().skip();
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
            .finished = pushForegroundDone,
        }) catch |err| {
            _ = self.actions.finish(pending);
            self.restorePushRetryTarget(ctx.allocator(), target.take(), credentials_available);
            switch (err) {
                error.ForegroundCommandLimitExceeded => self.setEffectStatus(.{ .page = origin }, "interactive push already queued", .{}),
                error.ForegroundCommandEmptyArgv => self.setEffectStatus(.{ .page = origin }, "interactive push command is empty", .{}),
                error.OutOfMemory => return err,
            }
            return;
        };

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

        app_git_requests.startCredentialedPush(Msg, ctx, &self.actions, self.env_map, &target, &credentials) catch |err| {
            target.deinit(ctx.allocator());
            return err;
        };
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

        if (!self.actions.finish(result.pending)) return;

        if (self.setActionFailureStatus("stage", result.result)) {
            self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());
            return;
        }

        self.setReviewStatus("staged: {s}", .{result.path});
        const applied = try self.reviewOperationController().applyAcceptedOutcome(
            ctx.allocator(),
            .stage_file,
            self.activeRepoMatches(result.repo_root),
        );
        try self.applyReviewReloadIntent(ctx, applied.reload);
    }

    fn finishStageHunk(self: *App, ctx: *chasen.Ctx(Msg), finished: StageHunkFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        if (self.setActionFailureStatus("hunk stage", result.result)) return;

        const active_matches = self.activeRepoMatches(result.repo_root);
        self.setReviewStatus("staged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
        const applied = try self.reviewOperationController().applyAcceptedOutcome(ctx.allocator(), .{ .stage_hunk = .{
            .repo_root = result.repo_root,
            .path = result.path,
            .hunk_index = result.hunk_index,
            .mark_source = result.mark_source,
        } }, active_matches);
        try self.applyReviewReloadIntent(ctx, applied.reload);
    }

    fn finishUnstageFile(self: *App, ctx: *chasen.Ctx(Msg), finished: UnstageFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        if (self.setActionFailureStatus("unstage", result.result)) {
            self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());
            return;
        }

        self.setReviewStatus("unstaged: {s}", .{result.path});
        const applied = try self.reviewOperationController().applyAcceptedOutcome(
            ctx.allocator(),
            .unstage_file,
            self.activeRepoMatches(result.repo_root),
        );
        try self.applyReviewReloadIntent(ctx, applied.reload);
    }

    fn finishUnstageHunk(self: *App, ctx: *chasen.Ctx(Msg), finished: UnstageHunkFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        if (self.setActionFailureStatus("hunk unstage", result.result)) return;

        const active_matches = self.activeRepoMatches(result.repo_root);
        self.setReviewStatus("unstaged hunk {d}: {s}", .{ result.hunk_index + 1, result.path });
        const applied = try self.reviewOperationController().applyAcceptedOutcome(ctx.allocator(), .{ .unstage_hunk = .{
            .repo_root = result.repo_root,
            .path = result.path,
            .hunk_index = result.hunk_index,
            .mark_source = result.mark_source,
            .reload_after_success = result.reload_after_success,
        } }, active_matches);
        try self.applyReviewReloadIntent(ctx, applied.reload);
    }

    fn finishDiscardFile(self: *App, ctx: *chasen.Ctx(Msg), finished: DiscardFileFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        if (self.setActionFailureStatus("discard", result.result)) {
            self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());
            return;
        }

        const applied = try self.reviewOperationController().applyAcceptedOutcome(ctx.allocator(), .{ .discard_file = .{
            .repo_root = result.repo_root,
            .path = result.path,
        } }, self.activeRepoMatches(result.repo_root));
        if (applied.reviewed_clear_failed) {
            self.setReviewStatus("discarded: {s}; could not clear reviewed mark", .{result.path});
            try self.applyReviewReloadIntent(ctx, applied.reload);
            return;
        }
        self.setReviewStatus("discarded: {s}", .{result.path});
        try self.applyReviewReloadIntent(ctx, applied.reload);
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

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok, .ok_static => {
                const active_matches = self.activeRepoMatches(result.repo_root);
                const applied = try self.reviewOperationController().applyAcceptedOutcome(
                    ctx.allocator(),
                    .{ .commit = .{ .repo_root = result.repo_root } },
                    active_matches,
                );
                self.commit_panel.close();

                if (active_matches) {
                    if (applied.reviewed_clear_failed) {
                        self.setReviewStatus("committed; could not clear reviewed marks", .{});
                    } else {
                        self.setReviewStatus("committed", .{});
                    }
                    try self.applyReviewReloadIntent(ctx, applied.reload);
                } else {
                    if (applied.reviewed_clear_failed) {
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

        if (!self.actions.finish(result.pending)) return;
        if (!self.commit_panel.is_open or self.commit_panel.mode != .commit) return;
        if (!self.activeRepoMatches(result.repo_root)) return;

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

        if (!self.actions.finish(result.pending)) return;

        switch (result.result) {
            .ok, .ok_static => {
                const reviewed_clear_failed = if (self.pages.review.reviewed_store.clearForRepo(ctx.allocator(), result.repo_root)) |_| false else |_| true;
                const active_matches = self.activeRepoMatches(result.repo_root);
                self.commit_panel.close();
                self.cancelAmendConfirmation(ctx.allocator());

                if (active_matches) {
                    if (reviewed_clear_failed) {
                        self.setReviewStatus("amended; could not clear reviewed marks", .{});
                    } else {
                        self.setReviewStatus("amended", .{});
                    }
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
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

        if (!self.actions.finish(result.pending)) return;

        const active_matches = self.activeRepoMatches(result.repo_root);

        switch (result.result) {
            .ok, .ok_static => {
                if (active_matches) {
                    self.setReviewStatus("pushed: {s} -> {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
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

        if (!self.actions.finish(result.pending)) return;

        const active_matches = self.activeRepoMatches(result.repo_root);

        switch (result.result) {
            .ok => {
                if (active_matches) {
                    self.setReviewStatus("pulled: {s} <- {s}/{s}", .{ result.branch, result.remote, result.remote_branch });
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
                } else {
                    self.setReviewStatus("pulled: {s}", .{result.repo_root});
                }
            },
            .ok_static => |message| {
                if (active_matches) {
                    self.setReviewStatus("{s}", .{message});
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
                } else {
                    self.setReviewStatus("{s}: {s}", .{ message, result.repo_root });
                }
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("pull", result.result);
                // A failed pull may still have fetched remote-tracking refs
                // before `--ff-only` or another later step failed, so refresh
                // the active repo when it still matches the completed task.
                if (active_matches) try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
            },
        }
    }

    fn finishFetch(self: *App, ctx: *chasen.Ctx(Msg), finished: FetchFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        const active_matches = self.activeRepoMatches(result.repo_root);

        switch (result.result) {
            .ok, .ok_static => {
                if (active_matches) {
                    self.setReviewStatus("fetched: {s}", .{result.remote});
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
                } else {
                    self.setReviewStatus("fetched: {s}", .{result.repo_root});
                }
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("fetch", result.result);
                // Git can update some refs before reporting an overall fetch
                // failure. Reload only the still-active matching repo so the UI
                // sees those side effects without disturbing a repo switch.
                if (active_matches) try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
            },
        }
    }

    fn finishSwitchBranch(self: *App, ctx: *chasen.Ctx(Msg), finished: SwitchBranchFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.actions.finish(result.pending)) return;

        const active_matches = self.activeRepoMatches(result.repo_root);

        switch (result.result) {
            .ok, .ok_static => {
                const reviewed_clear_failed = if (self.pages.review.reviewed_store.clearForRepo(ctx.allocator(), result.repo_root)) |_| false else |_| true;
                self.pages.review.staged_hunks.clearRepo(ctx.allocator(), result.repo_root);
                if (active_matches) {
                    self.reviewNavigation().clearPendingSelectionRestore(ctx.allocator());
                    self.reviewNavigation().clearSearch();
                    self.setReviewStatus("switched branch: {s} -> {s}", .{ result.old_branch, result.new_branch });
                    if (reviewed_clear_failed) self.setReviewStatus("switched branch: {s} -> {s}; could not clear reviewed marks", .{ result.old_branch, result.new_branch });
                    try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = true, .kind = .action_result });
                } else {
                    self.setReviewStatus("switched branch: {s}", .{result.repo_root});
                }
            },
            .failed, .failed_static => {
                _ = self.setActionFailureStatus("branch switch", result.result);
                if (active_matches) try self.startDiffLoadWithRepoRoot(ctx, result.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
            },
        }
    }

    fn finishBranchListLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: BranchListLoadFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (result.repo_epoch != self.repo_epoch) return;

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
        if (self.active_page != result.origin) ctx.redraw().skip();
    }

    fn finishPushForeground(self: *App, ctx: *chasen.Ctx(Msg), result: chasen.ForegroundCommandResult) !void {
        var foreground = switch (self.push_retry.state) {
            .foreground => |foreground| foreground,
            else => return,
        };
        if (foreground.request_id.id != result.request_id.id) return;
        self.push_retry.state = .idle;
        defer foreground.deinit(ctx.allocator());

        if (!self.actions.finish(foreground.pending)) return;

        const diagnostic_origin: EffectOrigin = .{ .page = foreground.origin };
        if (!self.effectOriginIsLive(diagnostic_origin)) {
            ctx.redraw().skip();
            return;
        }
        const active_matches = foreground.origin.repo_epoch == self.repo_epoch and
            self.activeRepoMatches(foreground.target.repo_root);

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
            ctx.redraw().skip();
            return;
        }

        if (active_matches) {
            // Foreground output is intentionally not captured, so GitFrame
            // cannot infer what changed from stderr/stdout. Refresh even after
            // non-zero exits because interactive helpers may still update local
            // refs, credential state, or branch status before failing.
            try self.startDiffLoadWithRepoRoot(ctx, foreground.target.repo_root, .{ .clear_visible_state = false, .kind = .action_result });
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

    fn reloadAfterGitAction(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (diff_source.sourceIsOneShotInput(self.config.source)) {
            ctx.redraw().skip();
            return;
        }
        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx, null);
            return;
        }
        // Commit/amend can change HEAD and ahead/behind counts; this reload
        // path must continue to refresh branch status for remote workflow gates.
        try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
            ctx.redraw().skip();
            return;
        }, .{ .clear_visible_state = false, .kind = .action_result });
    }

    /// Shell effect adapter for Review-local action outcomes. Review decides
    /// which member must be revalidated; App owns the actual async spawn.
    fn applyReviewReloadIntent(self: *App, ctx: *chasen.Ctx(Msg), intent: review_operations.ReloadIntent) !void {
        switch (intent) {
            .none => {},
            .source_and_aux => try self.reloadAfterGitAction(ctx),
            .status => |repo_root| self.startStatusLoad(ctx, repo_root, .foreground, null),
        }
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
            .finished = editorDone,
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
            ctx.redraw().skip();
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
            ctx.redraw().skip();
            return;
        }
        if (foreground.origin.page_id != .review or foreground.origin.repo_epoch != self.repo_epoch) return;

        if (diff_source.sourceIsOneShotInput(self.config.source)) {
            ctx.redraw().skip();
            return;
        }
        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            try self.startRepoDiscovery(ctx, null);
        } else {
            try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
                ctx.redraw().skip();
                return;
            }, .{ .clear_visible_state = self.pages.review.load.state == .idle, .kind = .action_result });
        }
    }

    fn editorDone(result: chasen.ForegroundCommandResult) Msg {
        return Msg.actionFinished(.{ .editor = result });
    }

    fn pushForegroundDone(result: chasen.ForegroundCommandResult) Msg {
        return Msg.actionFinished(.{ .push_foreground = result });
    }

    fn clipboardCopyDone(result: chasen.ClipboardCopyResult) Msg {
        return .{ .clipboard_copy_finished = .{
            .request_id = result.request_id,
            .outcome = clipboardCopyOutcome(result.outcome),
        } };
    }

    fn clipboardCopyOutcome(outcome: chasen.ClipboardCopyOutcome) ClipboardCopyOutcome {
        return switch (outcome) {
            .sent => .sent,
            .unsupported_runtime => .unsupported_runtime,
            .write_failed => |err| .{ .write_failed = err },
        };
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
            .finished = clipboardCopyDone,
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
        const removed = self.clipboard_copy_states.fetchRemove(finished.request_id.id) orelse {
            ctx.redraw().skip();
            return;
        };
        const state = removed.value;
        if (!self.effectOriginIsLive(state.origin)) {
            ctx.redraw().skip();
            return;
        }
        switch (finished.outcome) {
            .sent => self.setEffectStatus(state.origin, "clipboard copy sent: {s}", .{state.label}),
            .unsupported_runtime => self.setEffectStatus(state.origin, "clipboard copy unavailable: {s}", .{state.label}),
            .write_failed => |err| self.setEffectStatus(state.origin, "clipboard copy failed: {s}: {s}", .{ state.label, err }),
        }
        switch (state.origin) {
            .page => |origin_page| if (self.active_page != origin_page.page_id) ctx.redraw().skip(),
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
        return switch (origin) {
            .page => |origin_page| switch (origin_page.page_id) {
                .review => origin_page.repo_epoch == self.repo_epoch and
                    origin_page.activation_id == self.pages.review.activation.next_activation_id,
                .repository => origin_page.repo_epoch == self.repo_epoch and
                    origin_page.activation_id == self.pages.repository.activation_id,
                .history, .config => origin_page.repo_epoch == self.repo_epoch,
            },
            .shell_surface => |origin_surface| switch (origin_surface.surface) {
                .push_error => self.overlay.isPushError() and
                    self.overlay.push_error_instance_id == origin_surface.instance_id,
                .commit_panel => self.commit_panel.is_open and
                    self.commit_panel.instance_id == origin_surface.instance_id,
            },
        };
    }

    fn setEffectStatus(self: *App, origin: EffectOrigin, comptime fmt: []const u8, args: anytype) void {
        switch (origin) {
            .page => |origin_page| switch (origin_page.page_id) {
                .review => self.setReviewStatus(fmt, args),
                .repository => self.pages.repository.status.set(fmt, args),
                // Later page owners replace these placeholders with their own
                // diagnostic slots without changing the effect completion tag.
                .history, .config => self.setStatus(fmt, args),
            },
            .shell_surface => self.setStatus(fmt, args),
        }
    }

    fn reviewPageEffectOrigin(self: *const App) PageEffectOrigin {
        const identity = self.pages.review.activation.currentIdentity();
        return .{
            .page_id = .review,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repo_epoch,
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

    fn persistRecentRepositories(self: *App, ctx: *chasen.Ctx(Msg)) void {
        const path = self.state_path orelse return;
        saveRecentRepositoriesState(ctx.io(), path, &self.recent_repos) catch {
            self.setStatus("could not save recent repositories", .{});
        };
    }

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
        try stringify.write(config_mod.supported_schema_version);
        try stringify.objectField("recent_repositories");
        try repo_state.writeRecentRepositoriesJson(recent_repos, &stringify);
        try stringify.endObject();
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

    fn activeRootFromDiscovery(discovery: repo_discovery.DiscoveryResult) !?[]const u8 {
        return switch (discovery) {
            .single_repo => |entry| entry.canonical_root,
            .workspace => error.AmbiguousWorkspaceExport,
            .none => null,
        };
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

    fn autoReloadTick(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.active_page != .review) {
            ctx.redraw().skip();
            return;
        }
        if (!self.pages.review.auto_reload.enabled()) return;
        if (diff_source.sourceIsOneShotInput(self.config.source)) return;
        if (self.repo_picker.mode or self.pages.review.search.mode or self.pages.review.file_search.mode or self.commit_panel.is_open or
            self.pages.review.selection_owner.activeMouseSelection() or app_git_requests.hasPendingAction(self.actions))
        {
            ctx.redraw().skip();
            return;
        }
        if (self.pages.review.auto_reload.background_cycle != null or self.pages.review.load.hasPending() or self.pages.review.load.state == .loading or
            self.pages.review.status_load.isPending() or self.pages.review.branch_status_load.isPending() or self.pages.review.review_projection.hasPending())
        {
            ctx.redraw().skip();
            return;
        }

        if (diff_source.sourceRequiresRepo(self.config.source) and self.needsRepoDiscovery()) {
            if (self.pages.review.auto_reload.activation != .forced) {
                ctx.redraw().skip();
                return;
            }
            const cycle_id = self.pages.review.auto_reload.beginCycle() orelse {
                ctx.redraw().skip();
                return;
            };
            errdefer self.pages.review.auto_reload.discardEmptyCycle(cycle_id);
            try self.startRepoDiscovery(ctx, cycle_id);
            self.pages.review.auto_reload.discardEmptyCycle(cycle_id);
        } else {
            const cycle_id = self.pages.review.auto_reload.beginCycle() orelse {
                ctx.redraw().skip();
                return;
            };
            errdefer self.pages.review.auto_reload.discardEmptyCycle(cycle_id);
            try self.startDiffLoadWithRepoRoot(ctx, self.repoRootForCurrentSource() catch {
                self.pages.review.auto_reload.discardEmptyCycle(cycle_id);
                ctx.redraw().skip();
                return;
            }, .{
                .clear_visible_state = self.pages.review.load.state == .idle,
                .kind = .watch,
                .background_cycle_id = cycle_id,
            });
            self.pages.review.auto_reload.discardEmptyCycle(cycle_id);
        }
        ctx.redraw().skip();
    }

    fn backgroundAcceptanceBlocked(self: *const App, background_cycle_id: ?u64) bool {
        _ = background_cycle_id orelse return false;
        return self.backgroundActionBlocksAcceptance();
    }

    fn backgroundActionBlocksAcceptance(self: *const App) bool {
        const pending = self.actions.pending orelse return false;
        return pending.kind.blocksBackgroundAcceptance();
    }

    fn repoRootForCurrentSource(self: *const App) error{MissingRepoRoot}!?[]const u8 {
        if (!diff_source.sourceRequiresRepo(self.config.source)) return null;
        return self.activeRepoRoot() orelse error.MissingRepoRoot;
    }

    fn activeRepoRoot(self: *const App) ?[]const u8 {
        return self.repo_state.activeRoot();
    }

    fn sameRepoIdentity(
        left_path: ?[]const u8,
        left_object: ?repo_root_capability.Identity,
        right_path: ?[]const u8,
        right_object: ?repo_root_capability.Identity,
    ) bool {
        if (left_path == null or right_path == null) return left_path == null and right_path == null;
        if (!std.mem.eql(u8, left_path.?, right_path.?)) return false;
        if (left_object == null or right_object == null) return left_object == null and right_object == null;
        return left_object.?.eql(right_object.?);
    }

    fn discoveryRootAt(discovery: repo_discovery.DiscoveryResult, active_index: usize) ?[]const u8 {
        return switch (discovery) {
            .single_repo => |entry| entry.canonical_root,
            .workspace => |workspace| if (active_index < workspace.repos.len) workspace.repos[active_index].canonical_root else null,
            .none => null,
        };
    }

    /// The only mutation boundary for committed active-repository identity.
    /// The epoch advances before old page work can observe the new state.
    fn commitRepoDiscovery(
        self: *App,
        allocator: std.mem.Allocator,
        discovery: repo_discovery.DiscoveryResult,
        active_index: usize,
        origin: RepoCommitOrigin,
    ) RepoCommitOutcome {
        const proposed_root = discoveryRootAt(discovery, active_index);
        var candidate: ?repo_root_capability.RootCapability = if (proposed_root) |root|
            repo_root_capability.RootCapability.openCanonical(root) catch {
                var rejected = discovery;
                rejected.deinit(allocator);
                self.pages.repository.repositoryCommitFailed();
                return .rejected;
            }
        else
            null;
        const changed = !sameRepoIdentity(
            self.activeRepoRoot(),
            self.repo_state.activeIdentity(),
            proposed_root,
            if (candidate) |root| root.identity else null,
        );
        // An explicit picker/path selection is a repository-state commitment
        // even when its canonical root is unchanged. Supersede older discovery
        // generations so an earlier same-epoch result cannot restore stale
        // workspace metadata after the user's later selection.
        if (changed or origin == .external_selection) self.supersedeRepoBoundReads(allocator);
        if (changed) self.invalidateReviewForRepoChange(allocator);
        if (changed) self.advanceRepoEpoch();
        if (changed) {
            const committed_root = candidate;
            candidate = null;
            self.repo_state.replaceCommitted(allocator, discovery, active_index, committed_root);
        } else {
            if (candidate) |*root| root.deinit();
            self.repo_state.replaceDiscoveryKeepingRoot(allocator, discovery, active_index);
        }
        if (changed) self.pages.repository.repositoryChanged(allocator, self.repo_epoch, self.repo_state.activeIdentity());
        if (changed) self.finishRepoIdentityCommit();
        return if (changed) .changed else .unchanged;
    }

    fn commitWorkspaceRepoIndex(self: *App, active_index: usize) RepoCommitOutcome {
        const repos = self.repo_state.workspaceRepos() orelse return .unchanged;
        if (active_index >= repos.len) {
            self.pages.repository.repositoryCommitFailed();
            return .rejected;
        }
        const new_root = repos[active_index].canonical_root;
        var candidate: ?repo_root_capability.RootCapability = repo_root_capability.RootCapability.openCanonical(new_root) catch {
            self.pages.repository.repositoryCommitFailed();
            return .rejected;
        };
        const changed = !sameRepoIdentity(
            self.activeRepoRoot(),
            self.repo_state.activeIdentity(),
            new_root,
            if (candidate) |root| root.identity else null,
        );
        if (changed) {
            self.supersedeRepoBoundReads(self.allocator);
            self.invalidateReviewForRepoChange(self.allocator);
        }
        if (changed) self.advanceRepoEpoch();
        if (changed) {
            const committed = candidate.?;
            candidate = null;
            self.repo_state.selectWorkspaceRoot(active_index, committed);
        } else {
            if (candidate) |*root| root.deinit();
            self.repo_state.selectWorkspaceIndexKeepingRoot(active_index);
        }
        if (changed) self.pages.repository.repositoryChanged(self.allocator, self.repo_epoch, self.repo_state.activeIdentity());
        if (changed) self.finishRepoIdentityCommit();
        return if (changed) .changed else .unchanged;
    }

    /// Applies only the shell effects authorized by a completed repository
    /// commitment. A rejected capability open must not reload or reset the
    /// still-authoritative Review page.
    fn finishRepoPickerCommit(self: *App, ctx: *chasen.Ctx(Msg), outcome: RepoCommitOutcome) !void {
        switch (outcome) {
            .changed => {
                if (self.active_page == .review) try self.startDiffLoad(ctx, .repo_switch);
                self.reviewNavigation().resetAfterRepositorySwitch();
            },
            .unchanged => {},
            .rejected => self.setStatus("Repository root could not be opened safely", .{}),
        }
    }

    fn advanceRepoEpoch(self: *App) void {
        self.repo_epoch +%= 1;
        if (self.repo_epoch == 0) self.repo_epoch = 1;
    }

    fn finishRepoIdentityCommit(self: *App) void {
        self.pages.review.status.clear();
        if (self.active_page == .review) {
            _ = self.activateReview();
        } else {
            self.pages.review.activation.deactivate();
        }
    }

    fn supersedeRepoBoundReads(self: *App, allocator: ?std.mem.Allocator) void {
        self.pages.review.load.supersedePending();
        _ = self.pages.review.status_load.prepare(false);
        _ = self.pages.review.branch_status_load.prepare(false);
        self.pages.review.auto_reload.supersedeCycle();
        if (allocator) |owner| {
            self.pages.review.review_projection.clearPending(owner);
            self.pages.review.review_projection.clearSyntaxPending(owner);
        } else {
            std.debug.assert(!self.pages.review.review_projection.hasPending());
            std.debug.assert(!self.pages.review.review_projection.hasSyntaxPending());
        }
    }

    /// A repository identity change is destructive source supersession, not a
    /// page deactivation. Retaining the old document/fingerprint would let an
    /// equal fingerprint in the new repository return `unchanged` and grant
    /// fresh authority to the old display.
    fn invalidateReviewForRepoChange(self: *App, allocator: ?std.mem.Allocator) void {
        if (allocator) |owner| {
            switch (self.push_retry.state) {
                .available, .inspecting, .credential_prompt => self.clearPushError(owner),
                .idle, .foreground => {},
            }
            self.reviewReload().clearPendingReload(owner);
            self.reviewNavigation().clearPendingSelectionRestore(owner);
        } else {
            std.debug.assert(self.push_retry.state == .idle or self.push_retry.state == .foreground);
            std.debug.assert(self.pages.review.pending_reload == null);
            std.debug.assert(self.pages.review.pending_selection_restore == null);
        }
        self.reviewReload().clearSourceDisplay(allocator);
        self.reviewReload().dropStatusSnapshot(allocator);
        self.reviewReload().invalidateBranchStatusSnapshot();
    }

    fn activeRepoMatches(self: *const App, repo_root: []const u8) bool {
        const active_root = self.activeRepoRoot() orelse return false;
        return std.mem.eql(u8, active_root, repo_root);
    }

    fn needsRepoDiscovery(self: *const App) bool {
        return self.repo_state.needsDiscovery();
    }

    fn finishDiffLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: DiffLoadFinished) !void {
        if (self.allocator == null) self.allocator = ctx.allocator();
        var result = finished;
        var result_transferred = false;
        defer if (!result_transferred) result.deinit(ctx.allocator());

        const applied = try self.reviewReload().applySourceFinished(
            ctx.allocator(),
            &result,
            self.backgroundAcceptanceBlocked(result.background_cycle_id),
        );
        result_transferred = applied.result_transferred;

        self.applySourceShellOutcome(ctx, applied);
    }

    fn applySourceShellOutcome(self: *App, ctx: *chasen.Ctx(Msg), applied: review_reload.SourceApply) void {
        var recovered_failure_cleared = false;
        if (applied.recovered_failure) |failure| {
            recovered_failure_cleared = self.pages.review.status.clearSourceReloadFailure(failure.digest);
        }
        if (applied.auto_reload_failure) |failure| {
            self.pages.review.status.setSourceReloadFailure(
                failure.identity.digest,
                "auto reload failed: {s}",
                .{failure.message},
            );
        }
        if (self.active_page != .review) {
            ctx.redraw().skip();
            return;
        }
        switch (applied.redraw) {
            .normal => {},
            .skip => ctx.redraw().skip(),
            .skip_unless_recovered_failure_cleared => if (!recovered_failure_cleared) ctx.redraw().skip(),
        }
    }

    fn finishStatusLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: StatusLoadFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());
        const applied = try self.reviewReload().applyStatusFinished(
            ctx.allocator(),
            &result,
            self.backgroundAcceptanceBlocked(result.background_cycle_id),
        );
        if (applied.project_status) |prefer_first| try self.reviewReload().applyStatusProjection(ctx.allocator(), prefer_first);
        if (applied.diagnostic) |diagnostic| switch (diagnostic) {
            .status_load_failed => |message| self.setReviewStatus("status load failed: {s}", .{message}),
            else => unreachable,
        };
        if (applied.skip_redraw or self.active_page != .review) ctx.redraw().skip();
    }

    fn finishBranchStatusLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: BranchStatusLoadFinished) void {
        var result = finished;
        defer result.deinit(ctx.allocator());
        const applied = self.reviewReload().applyBranchStatusFinished(
            &result,
            self.backgroundAcceptanceBlocked(result.background_cycle_id),
        );
        if (applied.diagnostic) |diagnostic| switch (diagnostic) {
            .branch_status_load_failed => |message| self.setReviewStatus("branch status load failed: {s}", .{message}),
            .branch_status_parse_failed => self.setReviewStatus("branch status parse failed", .{}),
            else => unreachable,
        };
        if (applied.skip_redraw or self.active_page != .review) ctx.redraw().skip();
    }

    fn finishReviewProjectionLoad(self: *App, ctx: *chasen.Ctx(Msg), finished: ReviewProjectionFinished) !void {
        var result = finished;
        var result_transferred = false;
        defer if (!result_transferred) result.deinit(ctx.allocator());
        result_transferred = (try self.reviewReload().applyProjectionFinished(ctx.allocator(), &result)).result_transferred;
        if (self.active_page != .review) ctx.redraw().skip();
    }

    fn finishGeneratedProjectionSyntax(
        self: *App,
        ctx: *chasen.Ctx(Msg),
        finished: app_review_projection.GeneratedSyntaxFinished,
    ) void {
        var result = finished;
        defer result.deinit(ctx.allocator());
        self.reviewReload().applyGeneratedSyntaxFinished(ctx.allocator(), &result);
        if (self.active_page != .review) ctx.redraw().skip();
    }

    fn enterRepoPickerMode(self: *App, allocator: std.mem.Allocator) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setStatus("finish current git action before switching repos", .{});
            return;
        }

        self.clearBranchSwitch(allocator);
        if (self.active_page == .review) self.reviewNavigation().clearDiffSelection();
        self.repo_picker.mode = true;
        self.repo_picker.input_mode = .list;
        self.repo_picker.list.mode = true;
        self.repo_picker.list.input = .{};
        self.repo_picker.path_input = .{};
        self.repo_picker.list.resetNoMatch();
        self.repo_picker.clearPathStatus();
        self.clearRepoPickerDiscovery(allocator);
        try self.refreshRepoPickerFilter(allocator);
        self.focusRepoPickerOnActive();
    }

    fn cancelRepoPickerMode(self: *App, allocator: std.mem.Allocator) !void {
        switch (self.repo_picker.input_mode) {
            .list => {},
            .filter => {
                self.repo_picker.input_mode = .list;
                self.repo_picker.list.input = .{};
                self.repo_picker.list.resetNoMatch();
                try self.refreshRepoPickerFilter(allocator);
                self.focusRepoPickerOnActive();
                return;
            },
            .path_input => {
                self.repo_picker.input_mode = .list;
                self.repo_picker.invalidatePathDiscovery();
                self.pending_repo_path_recent_source = null;
                self.repo_picker.list.resetNoMatch();
                return;
            },
        }
        if (self.repo_picker_discovery != null) {
            self.clearRepoPickerDiscovery(allocator);
            try self.refreshRepoPickerFilter(allocator);
            self.focusRepoPickerOnActive();
            return;
        }
        self.closeRepoPickerMode(allocator);
    }

    fn closeRepoPickerMode(self: *App, allocator: std.mem.Allocator) void {
        self.repo_picker.deinit(allocator);
        self.pending_repo_path_recent_source = null;
        self.clearRepoPickerDiscovery(allocator);
        self.clearRepoPickerItems(allocator);
    }

    fn submitRepoPicker(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (self.repo_picker.input_mode == .path_input) {
            try self.submitRepoPickerPath(ctx);
            return;
        }

        const source = app_repo_picker.resolveSelection(&self.repo_picker, self.repo_picker_items.items) orelse {
            self.repo_picker.list.no_match = true;
            return;
        };

        switch (source) {
            .active_repo => {
                self.repo_picker.deinit(ctx.allocator());
                self.clearRepoPickerItems(ctx.allocator());
            },
            .workspace_repo => |repo_index| {
                const repos = self.repo_state.workspaceRepos() orelse return;
                if (repo_index >= repos.len) {
                    self.repo_picker.list.no_match = true;
                    return;
                }

                self.closeRepoPickerForSwitch(ctx.allocator());
                try self.recent_repos.rememberRepo(ctx.allocator(), repos[repo_index].canonical_root);
                self.persistRecentRepositories(ctx);
                if (repo_index == self.repo_state.active_index) return;

                try self.finishRepoPickerCommit(ctx, self.commitWorkspaceRepoIndex(repo_index));
            },
            .pending_workspace_repo => |repo_index| {
                try self.acceptPendingRepoPickerWorkspace(ctx, repo_index);
            },
            .recent_repo => |recent_index| {
                if (recent_index >= self.recent_repos.entries.items.len) return;
                try self.startRepoPathDiscovery(ctx, self.recent_repos.entries.items[recent_index].path, .{
                    .kind = .repo,
                    .index = recent_index,
                });
            },
            .recent_workspace => |recent_index| {
                if (recent_index >= self.recent_repos.entries.items.len) return;
                try self.startRepoPathDiscovery(ctx, self.recent_repos.entries.items[recent_index].path, .{
                    .kind = .workspace,
                    .index = recent_index,
                });
            },
        }
    }

    fn refreshRepoPickerFilter(self: *App, allocator: std.mem.Allocator) !void {
        try app_repo_picker.refreshFilter(
            allocator,
            &self.repo_picker,
            &self.repo_picker_items,
            self.repo_picker_discovery,
            self.repo_state.discovery,
            &self.recent_repos,
        );
    }

    fn focusRepoPickerOnActive(self: *App) void {
        app_repo_picker.focusOnActive(&self.repo_picker, self.repo_picker_items.items, self.repo_state.active_index);
    }

    fn enterRepoPickerFilterInput(self: *App, allocator: std.mem.Allocator) !void {
        if (!self.repo_picker.mode) return;
        self.repo_picker.input_mode = .filter;
        self.repo_picker.list.resetNoMatch();
        try self.refreshRepoPickerFilter(allocator);
    }

    fn enterRepoPickerPathInput(self: *App) void {
        if (!self.repo_picker.mode) return;
        self.repo_picker.input_mode = .path_input;
        self.repo_picker.invalidatePathDiscovery();
        self.pending_repo_path_recent_source = null;
    }

    fn insertRepoPickerCodepoint(self: *App, allocator: std.mem.Allocator, codepoint: u21) !void {
        try self.applyRepoPickerEditResult(allocator, app_repo_picker.insertCodepoint(&self.repo_picker, codepoint));
    }

    fn insertRepoPickerSlice(self: *App, allocator: std.mem.Allocator, text: []const u8) !void {
        try self.applyRepoPickerEditResult(allocator, app_repo_picker.insertSlice(&self.repo_picker, text));
    }

    fn backspaceRepoPicker(self: *App, allocator: std.mem.Allocator) !void {
        try self.applyRepoPickerEditResult(allocator, app_repo_picker.backspace(&self.repo_picker));
    }

    fn moveRepoPickerCursorLeft(self: *App) void {
        app_repo_picker.moveLeft(&self.repo_picker);
    }

    fn moveRepoPickerCursorRight(self: *App) void {
        app_repo_picker.moveRight(&self.repo_picker);
    }

    fn backRepoPicker(self: *App, allocator: std.mem.Allocator) !void {
        if (self.repo_picker.input_mode != .list) {
            try self.cancelRepoPickerMode(allocator);
            return;
        }
        if (self.repo_picker_discovery != null) {
            self.clearRepoPickerDiscovery(allocator);
            try self.refreshRepoPickerFilter(allocator);
            self.focusRepoPickerOnActive();
        }
    }

    fn recentSourceIdentity(source: app_repo_picker.ItemSource) ?PendingRecentPathDiscovery {
        return switch (source) {
            .recent_repo => |index| .{ .kind = .repo, .index = index },
            .recent_workspace => |index| .{ .kind = .workspace, .index = index },
            .active_repo, .workspace_repo, .pending_workspace_repo => null,
        };
    }

    fn removeSelectedRecentRepository(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        if (!self.repo_picker.mode or self.repo_picker.input_mode != .list) return;
        const item = app_repo_picker.selectedItem(&self.repo_picker, self.repo_picker_items.items) orelse return;
        const recent = recentSourceIdentity(item.source) orelse {
            self.setStatus("only recent repositories can be removed", .{});
            return;
        };
        if (!self.recent_repos.entryMatches(recent.index, recent.kind, item.detail)) {
            self.setStatus("recent repository changed; refresh and try again", .{});
            return;
        }

        const focused = self.repo_picker.list.filter.list.focusedIndex();
        if (!self.recent_repos.removeAt(ctx.allocator(), recent.index)) return;
        self.persistRecentRepositories(ctx);
        try self.refreshRepoPickerFilter(ctx.allocator());
        app_repo_picker.focusVisibleIndex(&self.repo_picker, focused);
        self.repo_picker.clearPathStatus();
        self.setStatus("removed recent repository", .{});
    }

    fn applyRepoPickerEditResult(self: *App, allocator: std.mem.Allocator, result: app_repo_picker.EditResult) !void {
        switch (result) {
            .none => {},
            .refresh_filter => try self.refreshRepoPickerFilter(allocator),
            .filter_too_long => self.setStatus("repository filter is too long", .{}),
            .path_changed => {
                if (self.repo_picker_discovery != null) {
                    self.clearRepoPickerDiscovery(allocator);
                    try self.refreshRepoPickerFilter(allocator);
                    self.focusRepoPickerOnActive();
                }
            },
        }
    }

    fn closeRepoPickerForSwitch(self: *App, allocator: std.mem.Allocator) void {
        self.repo_picker.deinit(allocator);
        self.pending_repo_path_recent_source = null;
        self.clearRepoPickerItems(allocator);
        self.reviewNavigation().clearPendingSelectionRestore(allocator);
        self.reviewReload().clearPendingReload(allocator);
        self.clearBranchSwitch(allocator);
    }

    fn submitRepoPickerPath(self: *App, ctx: *chasen.Ctx(Msg)) !void {
        const path = std.mem.trim(u8, self.repo_picker.path_input.slice(), " \t\r\n");
        if (path.len == 0) {
            self.repo_picker.path_error = .no_git_repositories_found;
            return;
        }
        try self.startRepoPathDiscovery(ctx, path, null);
    }

    fn startRepoPathDiscovery(self: *App, ctx: *chasen.Ctx(Msg), path: []const u8, recent_source: ?PendingRecentPathDiscovery) !void {
        if (app_git_requests.hasPendingAction(self.actions)) {
            self.setStatus("finish current git action before switching repos", .{});
            return;
        }

        const task = try ctx.allocator().create(RepoPathDiscoveryTask);
        errdefer ctx.allocator().destroy(task);

        const owned_path = try expandUserPath(ctx.allocator(), path, self.homeDir());
        errdefer ctx.allocator().free(owned_path);

        task.* = .{
            .path = owned_path,
            .generation = self.repo_picker.beginPathDiscovery(),
        };
        self.pending_repo_path_recent_source = recent_source;

        ctx.task().spawnWith(.{ .ctx = task, .run = RepoPathDiscoveryTask.run, .failed = RepoPathDiscoveryTask.failed }) catch |err| {
            _ = self.repo_picker.finishPathDiscovery(task.generation);
            self.pending_repo_path_recent_source = null;
            self.setStatus("could not start repo path discovery task", .{});
            return err;
        };
    }

    fn homeDir(self: *const App) ?[]const u8 {
        const map = self.env_map orelse return null;
        const home = map.get("HOME") orelse return null;
        if (home.len == 0) return null;
        return home;
    }

    fn finishRepoPathDiscovery(self: *App, ctx: *chasen.Ctx(Msg), finished: RepoPathDiscoveryFinished) !void {
        var result = finished;
        defer result.deinit(ctx.allocator());

        if (!self.repo_picker.finishPathDiscovery(result.generation)) return;
        if (!self.repo_picker.isCurrentPathDiscovery(result.generation)) return;

        switch (result.result) {
            .empty => unreachable,
            .discovered => |discovery| {
                self.pending_repo_path_recent_source = null;
                result.result = .empty;
                try self.acceptRepoPathDiscovery(ctx, discovery);
            },
            .input_error => |err| {
                if (try self.removeStaleRecentAfterPathError(ctx, err, result.submitted_path)) return;
                self.pending_repo_path_recent_source = null;
                self.repo_picker.path_error = app_prompt.repoPickerPathErrorFromDiscovery(err);
            },
            .failed => |message| {
                self.pending_repo_path_recent_source = null;
                self.setStatus("repo path discovery failed: {s}", .{git_ops.trimGitOutput(message)});
            },
            .failed_static => |message| {
                self.pending_repo_path_recent_source = null;
                self.setStatus("repo path discovery failed: {s}", .{message});
            },
        }
    }

    fn removeStaleRecentAfterPathError(self: *App, ctx: *chasen.Ctx(Msg), err: repo_discovery.PathDiscoveryError, submitted_path: []const u8) !bool {
        if (!isStaleRecentPathError(err)) return false;
        const pending = self.pending_repo_path_recent_source orelse return false;
        self.pending_repo_path_recent_source = null;

        const focused = self.repo_picker.list.filter.list.focusedIndex();
        const removed = if (self.recent_repos.entryMatches(pending.index, pending.kind, submitted_path))
            self.recent_repos.removeAt(ctx.allocator(), pending.index)
        else
            self.recent_repos.removeFirstMatching(ctx.allocator(), pending.kind, submitted_path);
        if (!removed) {
            self.repo_picker.clearPathStatus();
            return true;
        }

        self.persistRecentRepositories(ctx);
        try self.refreshRepoPickerFilter(ctx.allocator());
        app_repo_picker.focusVisibleIndex(&self.repo_picker, focused);
        self.repo_picker.clearPathStatus();
        self.setStatus("removed stale recent repository", .{});
        return true;
    }

    fn isStaleRecentPathError(err: repo_discovery.PathDiscoveryError) bool {
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

    fn acceptRepoPathDiscovery(self: *App, ctx: *chasen.Ctx(Msg), discovery: repo_discovery.DiscoveryResult) !void {
        var owned_discovery = discovery;
        errdefer owned_discovery.deinit(ctx.allocator());

        switch (owned_discovery) {
            .single_repo => |entry| {
                try self.recent_repos.rememberRepo(ctx.allocator(), entry.canonical_root);
                self.persistRecentRepositories(ctx);
                self.closeRepoPickerForSwitch(ctx.allocator());
                self.clearRepoPickerDiscovery(ctx.allocator());
                const outcome = self.commitRepoDiscovery(ctx.allocator(), owned_discovery, 0, .external_selection);
                owned_discovery = .{ .none = .{ .current_root = "" } };
                try self.finishRepoPickerCommit(ctx, outcome);
            },
            .workspace => |workspace| {
                try self.recent_repos.rememberWorkspace(ctx.allocator(), workspace.current_root);
                self.persistRecentRepositories(ctx);
                self.clearRepoPickerDiscovery(ctx.allocator());
                self.repo_picker_discovery = owned_discovery;
                owned_discovery = .{ .none = .{ .current_root = "" } };
                self.repo_picker.input_mode = .list;
                self.repo_picker.list.mode = true;
                self.repo_picker.list.input = .{};
                app_repo_picker.clearPathInput(&self.repo_picker);
                self.repo_picker.list.resetNoMatch();
                self.repo_picker.clearPathStatus();
                try self.refreshRepoPickerFilter(ctx.allocator());
                self.focusRepoPickerOnActive();
            },
            .none => unreachable,
        }
    }

    fn acceptPendingRepoPickerWorkspace(self: *App, ctx: *chasen.Ctx(Msg), repo_index: usize) !void {
        var discovery = self.repo_picker_discovery orelse return;
        self.repo_picker_discovery = null;
        errdefer discovery.deinit(ctx.allocator());

        const workspace = switch (discovery) {
            .workspace => |workspace| workspace,
            .single_repo, .none => return,
        };
        if (repo_index >= workspace.repos.len) {
            discovery.deinit(ctx.allocator());
            self.repo_picker.list.no_match = true;
            return;
        }

        try self.recent_repos.rememberRepo(ctx.allocator(), workspace.repos[repo_index].canonical_root);
        self.persistRecentRepositories(ctx);
        self.closeRepoPickerForSwitch(ctx.allocator());
        const outcome = self.commitRepoDiscovery(ctx.allocator(), discovery, repo_index, .external_selection);
        discovery = .{ .none = .{ .current_root = "" } };
        try self.finishRepoPickerCommit(ctx, outcome);
    }

    fn clearRepoPickerItems(self: *App, allocator: std.mem.Allocator) void {
        app_repo_picker.clearItems(&self.repo_picker_items, allocator);
    }

    fn deinitRepoPickerItems(self: *App, allocator: std.mem.Allocator) void {
        app_repo_picker.deinitItems(&self.repo_picker_items, allocator);
    }

    fn clearRepoPickerDiscovery(self: *App, allocator: std.mem.Allocator) void {
        if (self.repo_picker_discovery) |*discovery| discovery.deinit(allocator);
        self.repo_picker_discovery = null;
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
        self.pages.review.reviewed_store.appendPathKeysForRepo(ctx.allocator(), self.activeRepoRoot(), &reviewed_paths) catch {
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
            .repo_root = self.activeRepoRoot(),
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

    fn layoutSize(self: *const App) chasen.Size {
        return app_shell_layout.contentSize(self.terminal_size);
    }
};

const footer_rows: u16 = app_shell_layout.footer_rows;
const sidebar_header_rows: u16 = review_layout.sidebar_header_rows;
const diff_body_start_row: u16 = review_layout.diff_body_start_row;

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

test "file action repo mismatch clears pending selection restore without reload" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewNavigation().clearPendingSelectionRestore(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.reviewNavigation().setPendingSelectionRestore(allocator, "src/stage.zig");
    const stage_pending = app.actions.begin(.stage_file);
    try app.finishStageFile(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/stage.zig"),
        .result = .ok,
    });
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.pending_selection_restore == null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    try app.reviewNavigation().setPendingSelectionRestore(allocator, "src/unstage.zig");
    const unstage_pending = app.actions.begin(.unstage_file);
    try app.finishUnstageFile(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/other"),
        .path = try allocator.dupe(u8, "src/unstage.zig"),
        .result = .ok,
    });
    try std.testing.expect(app.actions.pending == null);
    try std.testing.expect(app.pages.review.pending_selection_restore == null);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "read task spawn failure rejects status branch and projection page state" {
    const allocator = std.testing.allocator;

    var status_app: App = .{ .allocator = allocator };
    _ = status_app.activateReview();
    var status_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    status_app.startStatusLoad(&status_ctx, "/repo", .foreground, null);
    status_ctx._pending_tasks_with_len = 0;
    try std.testing.expect(status_app.pages.review.status_load.pending == null);
    try std.testing.expectEqualStrings("could not start status load task", status_app.pages.review.status.text());

    var branch_app: App = .{ .allocator = allocator };
    _ = branch_app.activateReview();
    var branch_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    branch_app.startBranchStatusLoad(&branch_ctx, "/repo", null);
    branch_ctx._pending_tasks_with_len = 0;
    try std.testing.expect(branch_app.pages.review.branch_status_load.pending == null);
    try std.testing.expectEqualStrings("could not start branch status load task", branch_app.pages.review.status.text());

    var projection_app: App = .{
        .allocator = allocator,
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = projection_app.activateReview();
    defer projection_app.reviewReload().clearLoadedDiff(projection_app.allocator);
    defer projection_app.pages.review.git_status.deinit();
    var staged = try git_status.StatusBundle.parseOwned(allocator, "MM a\x00");
    try projection_app.pages.review.git_status.replace("/repo", &staged);
    var projection_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._pending_tasks_with_len = 16 };
    try std.testing.expectError(error.TaskLimitExceeded, projection_app.ensureReviewProjection(&projection_ctx));
    projection_ctx._pending_tasks_with_len = 0;
    try std.testing.expect(projection_app.pages.review.review_projection.pending == null);
}

test "read task allocation failure rejects source status branch and projection page state" {
    const backing = std.testing.allocator;

    var source_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    var source_app: App = .{
        .allocator = source_failing.allocator(),
        .config = .{ .source = .stdin },
    };
    _ = source_app.activateReview();
    var source_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = source_failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, source_app.startDiffLoadWithRepoRoot(
        &source_ctx,
        null,
        .{ .clear_visible_state = true, .kind = .manual },
    ));
    try std.testing.expect(source_app.pages.review.load.pending == null);
    try std.testing.expect(source_app.pages.review.pending_reload == null);

    var status_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    var status_app: App = .{ .allocator = status_failing.allocator() };
    _ = status_app.activateReview();
    var status_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = status_failing.allocator() };
    status_app.startStatusLoad(&status_ctx, "/repo", .foreground, null);
    try std.testing.expect(status_app.pages.review.status_load.pending == null);
    try std.testing.expectEqualStrings("could not allocate status load task", status_app.pages.review.status.text());

    var branch_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    var branch_app: App = .{ .allocator = branch_failing.allocator() };
    _ = branch_app.activateReview();
    var branch_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = branch_failing.allocator() };
    branch_app.startBranchStatusLoad(&branch_ctx, "/repo", null);
    try std.testing.expect(branch_app.pages.review.branch_status_load.pending == null);
    try std.testing.expectEqualStrings("could not allocate branch status load task", branch_app.pages.review.status.text());

    var projection_failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 4 });
    var projection_app: App = .{
        .allocator = projection_failing.allocator(),
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = projection_app.activateReview();
    defer projection_app.reviewReload().clearLoadedDiff(projection_app.allocator);
    defer projection_app.pages.review.git_status.deinit();
    var mixed = try git_status.StatusBundle.parseOwned(backing, "MM a\x00");
    try projection_app.pages.review.git_status.replace("/repo", &mixed);
    var projection_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = projection_failing.allocator() };
    try std.testing.expectError(error.OutOfMemory, projection_app.ensureReviewProjection(&projection_ctx));
    try std.testing.expect(projection_app.pages.review.review_projection.pending == null);
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
    try std.testing.expect(ctx._redraw_suppressed);
}

test "repository selection slice C copy uses Repository origin without opening AI UI" {
    var app: App = .{
        .active_page = .repository,
        .repo_epoch = 4,
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

test "repository selection slice C clipboard queue failure retains page candidate" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .active_page = .repository,
        .repo_epoch = 4,
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
            .finished = App.clipboardCopyDone,
        });
    }

    app.copySourceSelection(&ctx, app.pages.repository.completed_selection.?.text);

    try std.testing.expectEqual(@as(u8, 4), ctx._pending_clipboard_copies_len);
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("selected source", app.pages.repository.completed_selection.?.text);
    try std.testing.expectEqualStrings("clipboard copy already queued", app.pages.repository.status.text());
}

test "repository selection slice C late clipboard completion cannot target a new page instance" {
    var app: App = .{
        .active_page = .repository,
        .repo_epoch = 4,
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
    const request_id = ctx._pending_clipboard_copies[0].request_id;
    app.pages.repository.activation_id = 6;

    app.finishClipboardCopy(&ctx, .{ .request_id = request_id, .outcome = .sent });

    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("", app.pages.repository.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
}

test "repository selection slice C inactive page accepts same-instance clipboard completion" {
    var app: App = .{
        .active_page = .repository,
        .repo_epoch = 4,
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
    const request_id = ctx._pending_clipboard_copies[0].request_id;
    app.pages.repository.deactivate();
    app.active_page = .review;

    app.finishClipboardCopy(&ctx, .{ .request_id = request_id, .outcome = .sent });

    try std.testing.expectEqualStrings("clipboard copy sent: source selection", app.pages.repository.status.text());
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
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
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.clipboardCopyDone), entry.finished);
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

    app.finishClipboardCopy(&ctx, .{
        .request_id = .{ .id = 5 },
        .outcome = .sent,
    });

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
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

test "reopened shell surface rejects prior clipboard completion" {
    var app: App = .{};
    defer app.clipboard_copy_states.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.overlay.openPushError();
    const old_instance = app.overlay.push_error_instance_id;
    try app.clipboard_copy_states.put(std.testing.allocator, 7, .{
        .origin = .{ .shell_surface = .{ .surface = .push_error, .instance_id = old_instance } },
        .label = "old push error",
    });
    app.overlay.close();
    app.overlay.openPushError();
    try std.testing.expect(app.overlay.push_error_instance_id != old_instance);

    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 7 }, .outcome = .sent });

    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
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

    ctx._redraw_suppressed = false;
    app.finishClipboardCopy(&ctx, .{ .request_id = .{ .id = 8 }, .outcome = .sent });
    try std.testing.expectEqual(@as(usize, 0), app.clipboard_copy_states.count());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
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
    try std.testing.expectEqual(@as(chasen.Ctx(App.Msg).ClipboardCopyFinishedFn, App.clipboardCopyDone), entry.finished);
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
        .terminal_size = .{ .width = 140, .height = 8 },
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
        .terminal_size = .{ .width = 140, .height = 8 },
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
    app.reviewReload().clearLoadedDiff(app.allocator);
    try std.testing.expect(app.pages.review.selection_owner.activeDiff() == null);
}

test "terminal resize cancels live drag before geometry and retains completed selection" {
    const allocator = std.testing.allocator;
    const review_selection = @import("app/pages/review/selection.zig");
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .terminal_size = .{ .width = 80, .height = 20 },
    };
    defer app.reviewReload().clearLoadedDiff(allocator);

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

    try app.update(.{ .terminal_resized = .{ .width = 120, .height = 30 } }, undefined);

    try std.testing.expect(app.pages.review.selection_owner == .none);
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
    defer app.reviewReload().clearLoadedDiff(std.testing.allocator);
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
    _ = app.actions.begin(.push);
    app.git_action_spinner_timer_running = true;

    try app.update(.git_action_spinner_tick, undefined);

    try std.testing.expectEqualStrings("pushing: main -> origin/main", app.status.text());
    try std.testing.expectEqual(@as(u8, 1), app.git_action_spinner_tick);
}

test "git action spinner starts when pending action is visible after update" {
    var app: App = .{};
    _ = app.actions.begin(.push);
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

test "undelivered action result releases owned payloads" {
    var msg = App.Msg.actionFinished(.{ .stage_file = .{
        .pending = .{ .generation = 1, .kind = .stage_file },
        .path = try std.testing.allocator.dupe(u8, "src/app.zig"),
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "failed") },
    } });

    msg.deinitUndelivered(std.testing.allocator);
}

test "undelivered diff and status loads release owned payloads" {
    var diff_msg = App.Msg.loadFinished(.{ .review = .{ .source = .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one) },
    } } });
    diff_msg.deinitUndelivered(std.testing.allocator);

    var status_msg = App.Msg.loadFinished(.{ .review = .{ .status = .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "status failed") },
    } } });
    status_msg.deinitUndelivered(std.testing.allocator);
}

test "undelivered repo and projection loads release owned payloads" {
    var repo_msg = App.Msg.loadFinished(.{ .coordinator = .{ .repo_discovery = .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .failed = try std.testing.allocator.dupe(u8, "discovery failed") },
    } } });
    repo_msg.deinitUndelivered(std.testing.allocator);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        7,
        "/repo",
        "src/app.zig",
        .generated_added_file,
        .cached,
        3,
        4,
    );
    var projection_msg = App.Msg.loadFinished(.{ .review = .{ .projection = .{
        .request = request,
        .result = .{ .failed = try app_review_projection.statusBodyAlloc(
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

    var branch_status_msg = App.Msg.loadFinished(.{ .review = .{ .branch_status = .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "branch status failed") },
    } } });
    branch_status_msg.deinitUndelivered(allocator);

    var repo_path_msg = App.Msg.loadFinished(.{ .shell = .{ .repo_path_discovery = .{
        .generation = 2,
        .submitted_path = try allocator.dupe(u8, "/workspace"),
        .result = .{ .failed = try allocator.dupe(u8, "path discovery failed") },
    } } });
    repo_path_msg.deinitUndelivered(allocator);

    var branch_list_msg = App.Msg.loadFinished(.{ .shell = .{ .branch_list = .{
        .origin = .review,
        .repo_epoch = 3,
        .activation_id = 5,
        .generation = 4,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .failed = try allocator.dupe(u8, "branch list failed") },
    } } });
    branch_list_msg.deinitUndelivered(allocator);
}

test "undelivered plain root message is a no-op" {
    var msg: App.Msg = .quit;
    msg.deinitUndelivered(std.testing.allocator);
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
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
}

test "mouse click toggles sidebar directory rows" {
    const arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(arena, app_test_support.loadedDiffNested()),
            .viewer = .{ .focus = .diff, .selected_node = 1, .selected_file = 0 },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedSidebarDirectoryClickMessage;
    try app.update(msg, undefined);

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
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
    const header_msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 1, .left)) orelse return error.ExpectedSidebarHeaderClickMessage;
    try app.update(header_msg, undefined);
    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);

    app.pages.review.viewer.focus = .diff;
    const blank_row = content.row + sidebar_header_rows + 2;
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
            .viewer = .{ .focus = .diff, .selected_node = 0, .selected_file = 0 },
            .review_display = .{ .changed_file_filter = .deleted },
        } },
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);

    const content = app_shell_layout.contentRect(app.terminal_size);
    const row = content.row + app_shell_layout.page_bar_rows + sidebar_header_rows;
    const msg = app.handleEvent(app_test_support.mouseEvent(content.col + 1, row, .left)) orelse return error.ExpectedFilteredSidebarClickMessage;
    try app.update(msg, undefined);

    try std.testing.expectEqual(review_page.Focus.sidebar, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);
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
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_file);

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
                .selected_file = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 8 },
        .overlay = .{ .kind = .push_branch },
    };

    const content = app_shell_layout.contentRect(app.terminal_size);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .left)) == null);
    try std.testing.expect(app.handleEvent(app_test_support.mouseEvent(content.col + 1, content.row + 2, .wheel_down)) == null);
    try std.testing.expectEqual(review_page.Focus.diff, app.pages.review.viewer.focus);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_file);
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
        .repo_picker = .{
            .mode = true,
            .input_mode = .filter,
        },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    @memset(&app.repo_picker.list.input.buffer, 'x');
    app.repo_picker.list.input.len = app.repo_picker.list.input.buffer.len;
    app.repo_picker.list.input.cursor = app.repo_picker.list.input.buffer.len;

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
                .selected_file = 0,
                .selected_node = 0,
            },
        } },
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/status-only.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false);

    const loaded = app.reviewNavigation().loadedDiff().?;
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a.zig\x00?? b.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);

    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    const first_node = app.pages.review.viewer.selected_node;

    app.reviewNavigation().selectFileDelta(1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expect(app.pages.review.viewer.selected_node != first_node);

    app.reviewNavigation().selectFileDelta(-1);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(first_node, app.pages.review.viewer.selected_node);
}

test "pending selection restore waits for status projection after stage" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "b");
    app.pages.review.status_load.pending = .{ .generation = 1 };

    // Diff reload can finish before the status reload. In that intermediate
    // tree the staged file is absent, so do not consume the pending restore yet.
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false);
    try std.testing.expect(app.pages.review.pending_selection_restore != null);

    app.pages.review.status_load.pending = null;
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false);

    try std.testing.expect(app.pages.review.pending_selection_restore == null);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target.?);
}

test "staged summary distinguishes pending missing and ready status snapshots" {
    var app: App = .{
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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
    const pending = app.actions.begin(.assist_commit_message);
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

test "resolveCommitMessageAction reports missing and multiple configs" {
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
    action.scope = .commit;
    action.output = .commit_message;
    var other = action;
    other.id = "commit-message-b";
    multiple.user_config.actions.items[0] = action;
    multiple.user_config.actions.items[1] = other;
    multiple.user_config.actions.len = 2;

    try std.testing.expectError(error.Multiple, multiple.resolveGenerateCommitMessageAction());

    multiple.user_config.actions.items[0].stdin = .commit_message_context;
    multiple.user_config.actions.items[1].stdin = .commit_message_context;
    try std.testing.expectError(error.Multiple, multiple.resolveImproveCommitMessageAction());
}

test "pending selection restore survives status projection while diff reload is pending" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 1,
            },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "b");
    app.pages.review.load.pending = .{ .diff_load = app.pages.review.load.generation + 1 };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().applyStatusProjection(std.testing.allocator, false);

    try std.testing.expect(app.pages.review.pending_selection_restore != null);
    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
}

test "pending selection restore clears when status finishes empty after reload" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadStateWithArena(.init(std.testing.allocator), app_test_support.loadedDiffOne()),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
            },
            .status_load = .{ .generation = 7 },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "missing.zig");

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.pending_selection_restore == null);
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

test "stale branch status result is ignored" {
    var app: App = .{
        .pages = .{ .review = .{
            .branch_status_load = .{ .generation = 2, .pending = .{ .generation = 2 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.pages.review.branch_status.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try branchStatusBundleForTest(std.testing.allocator, .{
        .branch = "stale",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });

    app.finishBranchStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.branch_status.repo_root == null);
    try std.testing.expect(std.meta.eql(git_branch_status.Head.unknown, app.pages.review.branch_status.status.head));
    try std.testing.expectEqual(@as(?u64, 2), if (app.pages.review.branch_status_load.pending) |pending| pending.generation else null);
}

test "background branch failure retains display and identical recovery restores freshness" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.pages.review.branch_status.deinit();
    var current = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    try app.pages.review.branch_status.replace("/repo", &current);
    const root_ptr = app.pages.review.branch_status.repo_root.?.ptr;

    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .branch));
    const generation = app.pages.review.branch_status_load.prepare(true);
    app.pages.review.branch_status_load.begin(cycle_id);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    app.finishBranchStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "transient branch failure" },
    });

    try std.testing.expectEqualStrings("/repo", app.pages.review.branch_status.repo_root.?);
    try std.testing.expect(!app.pages.review.branch_status_load.isFresh());
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);

    const recovery_generation = app.pages.review.branch_status_load.prepare(true);
    app.pages.review.branch_status_load.begin(null);
    const same = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "abc",
        .branch = "main",
        .upstream = "origin/main",
        .ahead = 1,
        .behind = 0,
    });
    app.finishBranchStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = recovery_generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });
    try std.testing.expect(app.pages.review.branch_status_load.isFresh());
    try std.testing.expectEqual(root_ptr, app.pages.review.branch_status.repo_root.?.ptr);
}

test "background branch completion during repository action is discarded and releases cycle" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.pages.review.branch_status.deinit();
    var current = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "old-oid",
        .branch = "old-branch",
    });
    try app.pages.review.branch_status.replace("/repo", &current);

    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .branch));
    const generation = app.pages.review.branch_status_load.prepare(true);
    app.pages.review.branch_status_load.begin(cycle_id);
    _ = app.actions.begin(.stage_file);
    const changed = try branchStatusBundleForTest(std.testing.allocator, .{
        .oid = "new-oid",
        .branch = "new-branch",
    });
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.finishBranchStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = changed },
    });

    try std.testing.expectEqualStrings("old-branch", app.pages.review.branch_status.status.branchName().?);
    try std.testing.expect(!app.pages.review.branch_status_load.isPending());
    try std.testing.expectEqual(app_auto_reload.AuxiliaryFreshness.stale_refresh, app.pages.review.branch_status_load.freshness);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "requestPush snapshots the active branch target" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
    try std.testing.expectEqual(app.repo_epoch, task.repo_epoch);
    try std.testing.expectEqual(app.pages.review.activation.next_activation_id, task.activation_id);
    try std.testing.expectEqualStrings("/repo", task.repo_root);
    try std.testing.expectEqual(app.branch_switch.generation, task.generation);
}

test "requestBranchSwitch rejects untracked-only status distinctly" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_epoch = 4,
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
    try std.testing.expect(!ctx._redraw_suppressed);
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

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.confirmBranchSwitch(&ctx);

    try std.testing.expect(!app.overlay.isSwitchBranch());
    try std.testing.expect(app.branch_switch.branches.len == 0);
    try std.testing.expect(app.pages.review.staged_hunks.contains("/repo", "a", 0));
    try std.testing.expectEqualStrings("already on branch: main", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(app.actions.pending == null);
}

test "finishSwitchBranch success clears repo-local review state and reloads matching repo" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .terminal_size = .{ .width = 100, .height = 12 },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    defer app.pages.review.reviewed_store.deinit(allocator);
    defer app.pages.review.staged_hunks.deinit(allocator);
    defer app.reviewNavigation().clearPendingSelectionRestore(allocator);
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);

    try app.pages.review.reviewed_store.set(allocator, app.activeRepoRoot(), app_test_support.files_two[0], true);
    try app.pages.review.staged_hunks.add(allocator, "/repo", "a", 0);
    try app.reviewNavigation().setPendingSelectionRestore(allocator, "a");
    setDiffSearchQuery(&app, "needle");

    const pending = app.actions.begin(.switch_branch);
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
    try std.testing.expect(!try app.pages.review.reviewed_store.containsFile(allocator, app.activeRepoRoot(), app_test_support.files_two[0]));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
    try std.testing.expect(app.pages.review.pending_selection_restore == null);
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
        .repo_state = .{ .discovery = .{ .workspace = .{
            .current_root = "/workspace",
            .repos = &repos,
        } }, .active_index = 1 },
    };
    defer app.pages.review.reviewed_store.deinit(allocator);
    defer app.pages.review.staged_hunks.deinit(allocator);

    try app.pages.review.reviewed_store.set(allocator, "/repo", app_test_support.files_two[0], true);
    try app.pages.review.reviewed_store.set(allocator, "/other", app_test_support.files_two[1], true);
    try app.pages.review.staged_hunks.add(allocator, "/repo", "a", 0);
    try app.pages.review.staged_hunks.add(allocator, "/other", "b", 1);

    const pending = app.actions.begin(.switch_branch);
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
    try std.testing.expect(!app.pages.review.staged_hunks.contains("/repo", "a", 0));
    try std.testing.expect(app.pages.review.staged_hunks.contains("/other", "b", 1));
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqualStrings("switched branch: /repo", app.pages.review.status.text());
}

test "requestPush clears previous push error details" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
    app.actions.pending = .{ .generation = 1, .kind = .stage_file };
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
    app.actions.pending = .{ .generation = 1, .kind = .stage_file };
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
    app.actions.pending = .{ .generation = 1, .kind = .stage_file };
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
    app.actions.pending = .{ .generation = 1, .kind = .stage_file };
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
    app.actions.pending = .{ .generation = 1, .kind = .stage_file };
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
    app.actions.pending = .{ .generation = 7, .kind = .stage_file };
    defer app.actions.clear();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.openSelectedFileInEditor(&ctx);

    try std.testing.expectEqualStrings("finish current git action before opening editor", app.pages.review.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_foreground_commands_len);
    const pending = app.actions.pending orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(u64, 7), pending.generation);
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, pending.kind);
}

test "quit waits for pending git action" {
    var app: App = .{ .allocator = std.testing.allocator };
    app.actions.pending = .{ .generation = 7, .kind = .stage_file };
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

test "keyboard and page bar mouse share the page switch transition" {
    var app: App = .{
        .config = .{ .source = .stdin },
        .terminal_size = .{ .width = 100, .height = 20 },
        .pages = .{ .review = .{ .load = .{ .state = .{ .empty = .no_changes } } } },
    };
    _ = app.activateReview();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const keyboard = app.handleEvent(.{ .key_press = .{ .codepoint = '2' } }) orelse return error.ExpectedPageSwitch;
    try std.testing.expectEqual(App.Msg{ .switch_page = .repository }, keyboard);
    try app.update(keyboard, &ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.initialized);
    try std.testing.expect(app.pages.review.activation.state == .inactive);

    try app.update(.reload, &ctx);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("Repository required", app.pages.repository.status.text());
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    const layout = app.shellLayout();
    const review_tab = page.tab(.review);
    const bar = layout.page_bar orelse return error.ExpectedPageBar;
    const mouse = app.handleEvent(app_test_support.mouseEvent(
        bar.col + review_tab.col,
        bar.row,
        .left,
    )) orelse return error.ExpectedPageSwitch;
    try std.testing.expectEqual(App.Msg{ .switch_page = .review }, mouse);
    try app.update(mouse, &ctx);
    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expect(app.pages.review.activation.state.satisfiesAction(.read_diff));
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

fn repositoryLiveSelectionForTest() repository_selection.DragSelection {
    return .init(
        .{
            .repo_epoch = 1,
            .root_identity = .{ .device = 2, .inode = 3 },
            .path = "main.zig",
            .source_fingerprint = content_fingerprint.Fingerprint.init("source"),
        },
        .character,
        .{ .line_index = 0, .leading_byte = 0, .trailing_byte = 1 },
    );
}

test "repository selection slice B drag routes first and outside release terminates" {
    var app: App = .{
        .active_page = .repository,
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.pages.repository.source_selection = repositoryLiveSelectionForTest();
    const shell = app.shellLayout();
    const body_size = shell.bodySize();
    const tree_width = repository_page.bodyLayout(body_size).tree_width;
    const drag = app.handleEvent(app_test_support.mouseEventTyped(
        shell.body.col + tree_width + 1 + 4,
        shell.body.row + 2,
        .left,
        .drag,
    )) orelse return error.ExpectedRepositoryDrag;
    switch (drag) {
        .repository => |message| switch (message) {
            .mouse_source_drag => |point| try std.testing.expectEqual(
                repository_page.BodyPoint{ .col = 4, .row = 2 },
                point.?,
            ),
            else => return error.ExpectedRepositoryDrag,
        },
        else => return error.ExpectedRepositoryDrag,
    }

    const release = app.handleEvent(app_test_support.mouseEventTyped(0, 0, .left, .release)) orelse
        return error.ExpectedRepositoryRelease;
    switch (release) {
        .repository => |message| switch (message) {
            .mouse_source_release => |point| try std.testing.expect(point == null),
            else => return error.ExpectedRepositoryRelease,
        },
        else => return error.ExpectedRepositoryRelease,
    }
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.update(release, &ctx);
    try std.testing.expect(!app.pages.repository.activeSourceSelection());
}

test "repository selection slice B shell blocks transition and cancels on focus or resize" {
    var app: App = .{
        .active_page = .repository,
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    app.pages.repository.source_selection = repositoryLiveSelectionForTest();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .switch_page = .history }, &ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.activeSourceSelection());
    try std.testing.expectEqualStrings("finish Repository mouse selection before switching pages", app.status.text());

    app.status.clear();
    const shell = app.shellLayout();
    const bar = shell.page_bar orelse return error.ExpectedPageBar;
    const review_tab = page.tab(.review);
    const mouse_switch = app.handleEvent(app_test_support.mouseEvent(bar.col + review_tab.col, bar.row, .left)) orelse
        return error.ExpectedPageSwitch;
    try app.update(mouse_switch, &ctx);
    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expect(app.pages.repository.activeSourceSelection());
    try std.testing.expectEqualStrings("finish Repository mouse selection before switching pages", app.status.text());

    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.repository.activeSourceSelection());

    app.pages.repository.source_selection = repositoryLiveSelectionForTest();
    try app.update(.{ .terminal_resized = .{ .width = 70, .height = 12 } }, &ctx);
    try std.testing.expect(!app.pages.repository.activeSourceSelection());
    try std.testing.expectEqual(chasen.Size{ .width = 70, .height = 12 }, app.terminal_size);
}

test "repository activation and manual reload route to page-owned manifest tasks" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = roots.a,
            .canonical_root = roots.a,
        } } },
    };
    app.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer if (app.repo_state.root) |*root| root.deinit();
    defer app.pages.repository.deinit(std.testing.allocator);
    _ = app.activateReview();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingRepositoryTasks(&ctx, std.testing.allocator);

    try app.update(.{ .switch_page = .repository }, &ctx);
    try std.testing.expectEqual(@as(u8, 1), ctx._pending_tasks_with_len);
    const first: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[0].ctx));
    try std.testing.expectEqual(page.Id.repository, first.identity.origin);
    try std.testing.expectEqual(app.repo_epoch, first.identity.repo_epoch);
    const first_generation = first.generation;

    try app.update(.reload, &ctx);
    try std.testing.expectEqual(@as(u8, 2), ctx._pending_tasks_with_len);
    const second: *RepositoryManifestTask = @ptrCast(@alignCast(ctx._pending_tasks_with[1].ctx));
    try std.testing.expect(second.generation > first_generation);
    try std.testing.expectEqual(second.generation, app.pages.repository.pending_generation.?);
}

test "repository transition B2b2a missing document capability closes incoming owner" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 2,
            .repo_epoch = 3,
            .root_identity = .{ .device = 5, .inode = 8 },
            .manifest_revision = 13,
            .selected_path = "main.zig",
            .needs_document_revalidation = true,
        } },
    };
    defer app.pages.repository.deinit(allocator);
    var incoming = try page_link.RepositoryIncoming.initOwned(
        allocator,
        app.pages.repository.repo_epoch,
        app.pages.repository.root_identity.?,
        .{ .location = .{ .path = "main.zig", .line = 2 } },
    );
    const owned_address = @intFromPtr(incoming.location.path.ptr);
    app.pages.repository.acceptIncoming(allocator, &incoming);
    try std.testing.expect(app.pages.repository.incoming.advanceToDocument(
        app.pages.repository.manifest_revision,
    ));
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.maybeStartRepositoryDocument(&ctx);

    const unavailable = app.pages.repository.incomingUnavailable().?;
    try std.testing.expectEqual(page_link.RepositoryUnavailableReason.request_failed, unavailable.reason);
    try std.testing.expectEqual(owned_address, @intFromPtr(unavailable.path.ptr));
    try std.testing.expect(!app.pages.repository.needs_document_revalidation);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "repository transition B2b2a ordinary document capability loss preserves retry" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .pages = .{ .repository = .{
            .active = true,
            .activation_id = 2,
            .repo_epoch = 3,
            .root_identity = .{ .device = 5, .inode = 8 },
            .manifest_revision = 13,
            .selected_path = "main.zig",
            .needs_document_revalidation = true,
        } },
    };
    app.pages.repository.status.set("retained diagnostic", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.maybeStartRepositoryDocument(&ctx);

    try std.testing.expect(app.pages.repository.needs_document_revalidation);
    try std.testing.expectEqualStrings("retained diagnostic", app.pages.repository.status.text());
    try std.testing.expect(app.pages.repository.incoming == .none);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
}

test "page transition blocker leaves page and Review state unchanged" {
    var app: App = .{};
    app.pages.review.search.mode = true;
    const activation_id = app.activateReview();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .switch_page = .history }, &ctx);

    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expect(app.pages.review.search.mode);
    try std.testing.expectEqual(activation_id, app.pages.review.activation.state.active.activation_id);
    try std.testing.expectEqualStrings("finish search before switching pages", app.status.text());
    try std.testing.expect(!app.pages.history.initialized);
}

test "live review waiter blocks direct keyboard and mouse page switches with one reason" {
    var output: review_session.Output = .{};
    var app: App = .{
        .review_output = &output,
        .terminal_size = .{ .width = 100, .height = 20 },
    };
    _ = app.activateReview();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.update(.{ .switch_page = .repository }, &ctx);
    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("finish review session before switching pages", app.status.text());

    app.status.clear();
    const keyboard = app.handleEvent(.{ .key_press = .{ .codepoint = '3' } }) orelse return error.ExpectedPageSwitch;
    try app.update(keyboard, &ctx);
    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("finish review session before switching pages", app.status.text());

    app.status.clear();
    const layout = app.shellLayout();
    const config_tab = page.tab(.config);
    const bar = layout.page_bar orelse return error.ExpectedPageBar;
    const mouse = app.handleEvent(app_test_support.mouseEvent(bar.col + config_tab.col, bar.row, .left)) orelse
        return error.ExpectedPageSwitch;
    try app.update(mouse, &ctx);
    try std.testing.expectEqual(page.Id.review, app.active_page);
    try std.testing.expectEqualStrings("finish review session before switching pages", app.status.text());
}

test "inactive page timer starts no Review work" {
    var app: App = .{
        .active_page = .repository,
        .pages = .{ .review = .{ .auto_reload = .{
            .activation = .automatic,
            .interval_ns = 3 * std.time.ns_per_s,
        } } },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.autoReloadTick(&ctx);

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expect(ctx._redraw_suppressed);
}

test "Review re-entry queues one revalidation behind an older read and leaving cancels it" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .loading, .generation = 1, .pending = .{ .diff_load = 1 } },
        } },
    };
    const first_activation = app.activateReview();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.requestPageSwitch(&ctx, .repository);
    try app.requestPageSwitch(&ctx, .review);
    const second_activation = app.pages.review.activation.state.active.activation_id;
    try std.testing.expect(first_activation != second_activation);
    try std.testing.expectEqual(@as(?u64, second_activation), app.pages.review.activation.revalidation_requested);
    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);

    try app.requestPageSwitch(&ctx, .config);
    try std.testing.expect(app.pages.review.activation.state == .inactive);
    try std.testing.expect(app.pages.review.activation.revalidation_requested == null);
}

test "Review re-entry starts immediate fingerprint revalidation even when polling is disabled" {
    var app: App = .{
        .active_page = .repository,
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
        .pages = .{ .review = .{ .load = .{ .state = .{ .empty = .no_changes } } } },
    };
    app.pages.review.auto_reload.acceptSource(content_fingerprint.Fingerprint.init("retained"));
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, std.testing.allocator);

    try app.requestPageSwitch(&ctx, .review);

    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    const entries = ctx._pending_tasks_with[0..ctx._pending_tasks_with_len];
    const status_task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const branch_task: *BranchStatusLoadTask = @ptrCast(@alignCast(entries[1].ctx));
    const diff_task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
    const active = app.pages.review.activation.state.active;
    try std.testing.expectEqual(active.activation_id, status_task.identity.activation_id);
    try std.testing.expectEqual(active.activation_id, branch_task.identity.activation_id);
    try std.testing.expectEqual(active.activation_id, diff_task.identity.activation_id);
    try std.testing.expect(diff_task.expected_fingerprint != null);
}

test "workspace repository commitments advance one authoritative epoch" {
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var repos = [_]repo_discovery.RepoEntry{
        .{ .label = "a", .display_path = roots.a, .canonical_root = roots.a },
        .{ .label = "b", .display_path = roots.b, .canonical_root = roots.b },
    };
    var app: App = .{ .repo_state = .{ .discovery = .{ .workspace = .{
        .current_root = "/workspace",
        .repos = &repos,
    } } } };
    app.repo_state.root = try repo_root_capability.RootCapability.openCanonical(roots.a);
    defer if (app.repo_state.root) |*root| root.deinit();
    _ = app.activateReview();

    try std.testing.expectEqual(RepoCommitOutcome.unchanged, app.commitWorkspaceRepoIndex(0));
    try std.testing.expectEqual(@as(u64, 0), app.repo_epoch);
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitWorkspaceRepoIndex(1));
    try std.testing.expectEqual(@as(u64, 1), app.repo_epoch);
    try std.testing.expectEqualStrings(roots.b, app.activeRepoRoot().?);
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitWorkspaceRepoIndex(0));
    try std.testing.expectEqual(@as(u64, 2), app.repo_epoch);
    try std.testing.expectEqualStrings(roots.a, app.activeRepoRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.activation.state.active.repo_epoch);
}

test "same repository path with a new filesystem object advances epoch" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var app: App = .{ .allocator = allocator };
    defer app.repo_state.deinit(allocator);

    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, root_path),
        0,
        .external_selection,
    ));
    const first_identity = app.repo_state.activeIdentity().?;
    try std.testing.expectEqual(@as(u64, 1), app.repo_epoch);

    try tmp.dir.rename("repo", tmp.dir, "old-repo", io);
    try tmp.dir.createDir(io, "repo", .default_dir);
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, root_path),
        0,
        .external_selection,
    ));
    try std.testing.expect(!first_identity.eql(app.repo_state.activeIdentity().?));
    try std.testing.expectEqual(@as(u64, 2), app.repo_epoch);
}

test "repository capability commit failure leaves prior identity unchanged" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    try roots.tmp.dir.symLink(io, "b", "linked", .{ .is_directory = true });
    const linked = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(roots.a).?, "linked" });
    defer allocator.free(linked);
    var app: App = .{ .allocator = allocator };
    defer app.repo_state.deinit(allocator);
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    const identity = app.repo_state.activeIdentity().?;

    try std.testing.expectEqual(RepoCommitOutcome.rejected, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, linked),
        0,
        .external_selection,
    ));
    try std.testing.expectEqual(@as(u64, 1), app.repo_epoch);
    try std.testing.expectEqualStrings(roots.a, app.activeRepoRoot().?);
    try std.testing.expect(identity.eql(app.repo_state.activeIdentity().?));
}

test "repo picker capability rejection preserves Review navigation and does not reload" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    try roots.tmp.dir.symLink(io, "b", "linked", .{ .is_directory = true });
    const linked = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(roots.a).?, "linked" });
    defer allocator.free(linked);

    var app: App = .{ .allocator = allocator, .repo_picker = .{ .mode = true } };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    const prior_epoch = app.repo_epoch;
    const prior_identity = app.repo_state.activeIdentity().?;
    app.pages.review.viewer.selected_target = .{ .diff_file = 3 };
    app.pages.review.viewer.selected_file = 3;
    app.pages.review.viewer.selected_node = 7;
    app.pages.review.search.mode = true;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.acceptRepoPathDiscovery(&ctx, try testSingleRepoDiscovery(allocator, linked));

    try std.testing.expectEqual(@as(u8, 0), ctx._pending_tasks_with_len);
    try std.testing.expectEqual(prior_epoch, app.repo_epoch);
    try std.testing.expectEqualStrings(roots.a, app.activeRepoRoot().?);
    try std.testing.expect(prior_identity.eql(app.repo_state.activeIdentity().?));
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.selected_file);
    try std.testing.expectEqual(@as(usize, 7), app.pages.review.viewer.selected_node);
    try std.testing.expect(app.pages.review.search.mode);
    try std.testing.expectEqualStrings("Repository root could not be opened safely", app.status.text());
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

test "repo discovery remains owned when recent-store update fails" {
    const backing = std.testing.allocator;
    var app: App = .{ .active_page = .repository };
    const activation_id = app.pages.review.activation.activate(0, .pending, .unavailable, .unavailable);
    const generation = app.pages.review.load.beginRepoDiscovery();
    const discovery = try testSingleRepoDiscovery(backing, "/repo/owned-until-commit");

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    defer app.repo_state.deinit(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try std.testing.expectError(error.OutOfMemory, app.finishRepoDiscovery(&ctx, .{
        .identity = page.RequestIdentity.review(0, activation_id),
        .generation = generation,
        .result = .{ .discovered = discovery },
    }));

    try std.testing.expect(app.repo_state.discovery == null);
    try std.testing.expectEqual(@as(usize, 0), app.recent_repos.entries.items.len);
}

test "repo discovery completion cannot overwrite a newer repository commitment" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .active_page = .repository };
    defer app.repo_state.deinit(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const first_activation = app.pages.review.activation.activate(0, .pending, .unavailable, .unavailable);
    const first_generation = app.pages.review.load.beginRepoDiscovery();
    try app.finishRepoDiscovery(&ctx, .{
        .identity = page.RequestIdentity.review(0, first_activation),
        .generation = first_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.a) },
    });
    try std.testing.expectEqualStrings(roots.a, app.activeRepoRoot().?);
    try std.testing.expectEqual(@as(u64, 1), app.repo_epoch);

    const same_activation = app.pages.review.activation.activate(app.repo_epoch, .pending, .pending, .pending);
    const same_generation = app.pages.review.load.beginRepoDiscovery();
    try app.finishRepoDiscovery(&ctx, .{
        .identity = page.RequestIdentity.review(1, same_activation),
        .generation = same_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.a) },
    });
    try std.testing.expectEqual(@as(u64, 1), app.repo_epoch);

    const same_epoch_stale_activation = app.pages.review.activation.activate(app.repo_epoch, .pending, .pending, .pending);
    const same_epoch_stale_generation = app.pages.review.load.beginRepoDiscovery();
    try std.testing.expectEqual(RepoCommitOutcome.unchanged, app.commitRepoDiscovery(
        allocator,
        try testNamedSingleRepoDiscovery(allocator, "fresh selection", roots.a),
        0,
        .external_selection,
    ));
    try std.testing.expect(!app.pages.review.load.hasPending());
    try app.finishRepoDiscovery(&ctx, .{
        .identity = page.RequestIdentity.review(1, same_epoch_stale_activation),
        .generation = same_epoch_stale_generation,
        .result = .{ .discovered = try testNamedSingleRepoDiscovery(allocator, "stale completion", roots.a) },
    });
    const committed = app.repo_state.discovery orelse return error.ExpectedSingleRepository;
    switch (committed) {
        .single_repo => |entry| try std.testing.expectEqualStrings("fresh selection", entry.label),
        else => return error.ExpectedSingleRepository,
    }
    try std.testing.expectEqual(@as(u64, 1), app.repo_epoch);

    const stale_activation = app.pages.review.activation.activate(app.repo_epoch, .pending, .pending, .pending);
    const stale_generation = app.pages.review.load.beginRepoDiscovery();
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(allocator, try testSingleRepoDiscovery(allocator, roots.b), 0, .external_selection));
    try std.testing.expectEqual(@as(u64, 2), app.repo_epoch);
    try std.testing.expect(!app.pages.review.load.hasPending());

    try app.finishRepoDiscovery(&ctx, .{
        .identity = page.RequestIdentity.review(1, stale_activation),
        .generation = stale_generation,
        .result = .{ .discovered = try testSingleRepoDiscovery(allocator, roots.a) },
    });
    try std.testing.expectEqualStrings(roots.b, app.activeRepoRoot().?);
    try std.testing.expectEqual(@as(u64, 2), app.repo_epoch);

    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(allocator, try testSingleRepoDiscovery(allocator, roots.a), 0, .external_selection));
    try std.testing.expectEqualStrings(roots.a, app.activeRepoRoot().?);
    try std.testing.expectEqual(@as(u64, 3), app.repo_epoch);
}

test "inactive repository change invalidates retained source before equal-fingerprint re-entry" {
    const allocator = std.testing.allocator;
    var roots = try TestRepoPair.init();
    defer roots.deinit();
    var app: App = .{ .active_page = .repository, .allocator = allocator };
    defer app.repo_state.deinit(allocator);

    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));

    var retained = app_test_support.loadedDiffOne();
    retained.text = app_test_support.diff_one;
    app.pages.review.load = app_test_support.loadState(retained);
    const shared_fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    app.pages.review.auto_reload.acceptSource(shared_fingerprint);

    const source_revision = app.pages.review.source_session_revision;
    const status_revision = app.pages.review.status_snapshot_revision;
    app.pages.review.review_projection.installReady(.{
        .request = try app_review_projection.cloneRequest(
            allocator,
            page.RequestIdentity.review(app.repo_epoch, 1),
            1,
            roots.a,
            "cached-a",
            .generated_added_file,
            .unstaged,
            source_revision,
            status_revision,
        ),
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(allocator, "cached-a", "cached\n") },
    });
    app.pages.review.review_projection.cacheOrClearDisplayed(
        allocator,
        roots.a,
        .unstaged,
        source_revision,
        status_revision,
    );
    app.pages.review.review_projection.installReady(.{
        .request = try app_review_projection.cloneRequest(
            allocator,
            page.RequestIdentity.review(app.repo_epoch, 1),
            2,
            roots.a,
            "displayed-a",
            .generated_added_file,
            .unstaged,
            source_revision,
            status_revision,
        ),
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(allocator, "displayed-a", "displayed\n") },
    });
    app.pages.review.review_projection.pending = try app_review_projection.cloneRequest(
        allocator,
        page.RequestIdentity.review(app.repo_epoch, 1),
        3,
        roots.a,
        "pending-a",
        .generated_added_file,
        .unstaged,
        source_revision,
        status_revision,
    );
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.review_projection.cacheLen());

    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    try std.testing.expectEqualStrings(roots.b, app.activeRepoRoot().?);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.review.load.state == .idle);
    try std.testing.expect(app.reviewNavigation().loadedDiff() == null);
    try std.testing.expect(app.pages.review.review_projection.pending == null);
    try std.testing.expect(!app.pages.review.review_projection.hasDisplayed());
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.review_projection.cacheLen());
    try std.testing.expect(!app.pages.review.review_projection.cacheHas(
        roots.a,
        "cached-a",
        .generated_added_file,
        .unstaged,
        source_revision,
        status_revision,
    ));

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);
    try app.requestPageSwitch(&ctx, .review);

    try std.testing.expectEqual(@as(u8, 3), ctx._pending_tasks_with_len);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.review_projection.cacheLen());
    const diff_task: *DiffLoadTask = @ptrCast(@alignCast(ctx._pending_tasks_with[2].ctx));
    try std.testing.expect(diff_task.expected_fingerprint == null);
    try std.testing.expectEqual(app.repo_epoch, diff_task.identity.repo_epoch);
}

test "inactive Review failure stays page scoped and skips redraw" {
    var app: App = .{
        .active_page = .repository,
        .repo_epoch = 5,
        .pages = .{ .review = .{ .status_load = .{
            .generation = 1,
            .pending = .{ .generation = 1 },
        } } },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(5, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "offline" },
    }) catch unreachable;

    try std.testing.expectEqual(page.Id.repository, app.active_page);
    try std.testing.expectEqualStrings("", app.status.text());
    try std.testing.expectEqualStrings("status load failed: offline", app.pages.review.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
}

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
    app.actions.pending = .{ .generation = 7, .kind = .stage_file };
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
        .repo_state = .{ .discovery = .{ .single_repo = repo } },
    };
    var help: App = .{
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = repo } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "other",
            .display_path = "/other",
            .canonical_root = "/other",
        } } },
    };
    const pending = app.actions.begin(.push);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "other",
            .display_path = "/other",
            .canonical_root = "/other",
        } } },
    };
    const pending = app.actions.begin(.pull);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    const pending = app.actions.begin(.pull);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    const pending = app.actions.begin(.pull);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "other",
            .display_path = "/other",
            .canonical_root = "/other",
        } } },
    };
    const pending = app.actions.begin(.fetch);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    const pending = app.actions.begin(.fetch);
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
    const pending = app.actions.begin(.push);
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
    app.actions.pending = .{ .generation = 7, .kind = .stage_file };
    defer app.actions.clear();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.runInteractivePush(&ctx);

    const pending = app.actions.pending orelse return error.ExpectedPendingAction;
    try std.testing.expectEqual(@as(u64, 7), pending.generation);
    try std.testing.expectEqual(app_actions.ActionKind.stage_file, pending.kind);
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
    defer app.repo_state.deinit(allocator);
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, roots.a),
        0,
        .external_selection,
    ));
    _ = app.activateReview();
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
    try std.testing.expectEqual(RepoCommitOutcome.changed, app.commitRepoDiscovery(
        allocator,
        try testSingleRepoDiscovery(allocator, roots.b),
        0,
        .external_selection,
    ));
    try runOnlyPushInspectionTaskForTest(&app, &ctx, std.testing.io);

    try std.testing.expect(app.push_retry.state == .idle);
    try std.testing.expectEqualStrings(roots.b, app.activeRepoRoot().?);
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
    _ = app.activateReview();
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
    _ = app.activateReview();
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
    try std.testing.expect(ctx._redraw_suppressed);
}

test "Review reactivation discards an old push inspection completion" {
    const allocator = std.testing.allocator;
    var app: App = .{ .allocator = allocator };
    defer app.clearPushError(allocator);
    _ = app.activateReview();
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
    _ = app.activateReview();
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
    try std.testing.expectEqual(app.repo_epoch, app.push_retry.state.foreground.origin.repo_epoch);
    try std.testing.expect(app.actions.pending != null);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    const pending = app.actions.begin(.push);
    app.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 9 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = app.repo_epoch, .activation_id = app.pages.review.activation.next_activation_id },
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

    const pending = app.actions.begin(.push);
    app.push_retry.state = .{ .foreground = .{
        .request_id = .{ .id = 2 },
        .pending = pending,
        .origin = .{ .page_id = .review, .repo_epoch = app.repo_epoch, .activation_id = app.pages.review.activation.next_activation_id },
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

test "inactive Review foreground completions retain diagnostics without effects" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
        .repo_epoch = 3,
    };
    const pending = app.actions.begin(.push);
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
    try std.testing.expect(ctx._redraw_suppressed);

    ctx._redraw_suppressed = false;
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
    try std.testing.expect(ctx._redraw_suppressed);
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

test "manual reload clears action selection restore" {
    var app: App = .{
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
    };
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "src/main.zig");

    try app.update(.reload, &ctx);

    try std.testing.expect(app.pages.review.pending_selection_restore == null);
}

test "repository syntax task allocation and spawn failures release owners and remain retryable" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_state.deinit(allocator);
    app.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    const source_bytes = try allocator.dupe(u8, "const value = 1;\n");
    var source_transferred = false;
    var source_value = @import("repository/source.zig").Document.initOwned(
        allocator,
        source_bytes,
        .init(source_bytes),
    ) catch |err| {
        allocator.free(source_bytes);
        return err;
    };
    errdefer if (!source_transferred) source_value.deinit(allocator);
    const displayed_path = try allocator.dupe(u8, "main.zig");
    errdefer if (!source_transferred) allocator.free(displayed_path);
    app.pages.repository = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = app.repo_state.root.?.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .load_state = .loaded,
        .selected_path = "main.zig",
        .needs_syntax_request = true,
        .displayed_document = .{
            .path = displayed_path,
            .manifest_revision = 5,
            .source_revision = 6,
            .value = .{ .source = source_value },
        },
    };
    source_transferred = true;

    // prepareSyntaxRequest allocates the path first; fail the following task
    // object allocation and let the unconsumed request defer release path/root.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    var allocation_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator(), ._io = io };
    try app.maybeStartRepositorySyntax(&allocation_ctx);
    try std.testing.expect(app.pages.repository.wantsSyntaxRequest());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.takePendingTasksWith().len);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) App.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskFailure) App.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    for (0..16) |_| try spawn_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    try app.maybeStartRepositorySyntax(&spawn_ctx);
    try std.testing.expect(app.pages.repository.wantsSyntaxRequest());
    try std.testing.expectEqual(@as(usize, 0), spawn_ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.takePendingTasks().len);

    var retry_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.maybeStartRepositorySyntax(&retry_ctx);
    const queued = retry_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

test "repository change map task allocation and spawn failures release owners and remain retryable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: App = .{
        .allocator = allocator,
        .active_page = .repository,
    };
    defer app.pages.repository.deinit(allocator);
    defer app.repo_state.deinit(allocator);
    app.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    const source_bytes = try allocator.dupe(u8, "const value = 1;\n");
    var source_transferred = false;
    var source_value = @import("repository/source.zig").Document.initOwned(
        allocator,
        source_bytes,
        .init(source_bytes),
    ) catch |err| {
        allocator.free(source_bytes);
        return err;
    };
    errdefer if (!source_transferred) source_value.deinit(allocator);
    const displayed_path = try allocator.dupe(u8, "main.zig");
    errdefer if (!source_transferred) allocator.free(displayed_path);
    app.pages.repository = .{
        .active = true,
        .repo_epoch = 3,
        .activation_id = 4,
        .root_identity = app.repo_state.root.?.identity,
        .manifest_revision = 5,
        .source_revision = 6,
        .load_state = .loaded,
        .selected_path = "main.zig",
        .needs_change_map_request = true,
        .displayed_document = .{
            .path = displayed_path,
            .manifest_revision = 5,
            .source_revision = 6,
            .value = .{ .source = source_value },
            .change_decoration = .eligible,
        },
    };
    source_transferred = true;

    // Request preparation owns path/temp-base/root. Fail the following task
    // allocation and prove the request defer returns all three owners.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    var allocation_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = failing.allocator(), ._io = io };
    app.maybeStartRepositoryChangeMap(&allocation_ctx);
    try std.testing.expect(app.pages.repository.wantsChangeMapRequest());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.takePendingTasksWith().len);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) App.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskFailure) App.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    for (0..16) |_| try spawn_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    app.maybeStartRepositoryChangeMap(&spawn_ctx);
    try std.testing.expect(app.pages.repository.wantsChangeMapRequest());
    try std.testing.expectEqual(@as(usize, 0), spawn_ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.takePendingTasks().len);

    var retry_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    app.maybeStartRepositoryChangeMap(&retry_ctx);
    const queued = retry_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

test "generated projection syntax start failures preserve plain display and remain retryable" {
    if (!source_syntax_runtime.enabled) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);

    var app: App = .{
        .allocator = allocator,
        .active_page = .review,
        .config = .{ .source = .unstaged },
    };
    defer app.pages.review.deinit(allocator);
    defer app.repo_state.deinit(allocator);
    app.repo_state.discovery = try testSingleRepoDiscovery(allocator, root_path);
    app.repo_state.root = try repo_root_capability.RootCapability.openCanonical(root_path);
    app.pages.review.load = app_test_support.loadState(app_test_support.loadedDiffOne());
    app.pages.review.viewer.selected_target = .{ .status_only = 0 };
    _ = app.pages.review.activation.activate(0, .pending, .pending, .pending);
    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "?? new.zig\x00");
    try app.pages.review.git_status.replace(root_path, &status_bundle);
    app.pages.review.review_projection.installReady(.{
        .request = try app_review_projection.cloneRequestWithRootIdentity(
            allocator,
            app.pages.review.activation.currentIdentity().?,
            11,
            root_path,
            "new.zig",
            .generated_added_file,
            .unstaged,
            0,
            0,
            app.repo_state.root.?.identity,
        ),
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(
            allocator,
            "new.zig",
            "const value = 1;\n",
        ) },
    });

    // Failure while preparing the two owned request clones must not escape
    // App.update's best-effort decoration tail or leave a pending owner behind.
    var prepare_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    app.allocator = prepare_failing.allocator();
    var prepare_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = prepare_failing.allocator(), ._io = io };
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &prepare_ctx);
    app.allocator = allocator;
    try std.testing.expect(!app.pages.review.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), prepare_ctx.takePendingTasksWith().len);
    try expectGeneratedProjectionEligible(&app);

    // Four string allocations build the page/task request clones. Fail the
    // following task-object allocation and verify both clones are reclaimed.
    var task_failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 4 });
    app.allocator = task_failing.allocator();
    var allocation_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = task_failing.allocator(), ._io = io };
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &allocation_ctx);
    app.allocator = allocator;
    try std.testing.expect(!app.pages.review.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), allocation_ctx.takePendingTasksWith().len);
    try expectGeneratedProjectionEligible(&app);

    const DummyTask = struct {
        fn run(_: std.mem.Allocator, _: std.Io) App.Msg {
            return .quit;
        }
        fn failed(_: chasen.TaskFailure) App.Msg {
            return .quit;
        }
    };
    var spawn_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    for (0..16) |_| try spawn_ctx.task().spawn(.{ .run = DummyTask.run, .failed = DummyTask.failed });
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &spawn_ctx);
    try std.testing.expect(!app.pages.review.review_projection.hasSyntaxPending());
    try std.testing.expectEqual(@as(usize, 0), spawn_ctx.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 16), spawn_ctx.takePendingTasks().len);
    try expectGeneratedProjectionEligible(&app);

    var retry_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator, ._io = io };
    try app.update(.{ .terminal_resized = .{ .width = 80, .height = 24 } }, &retry_ctx);
    const queued = retry_ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), queued.len);
    try std.testing.expect(app.pages.review.review_projection.hasSyntaxPending());
    try expectGeneratedProjectionEligible(&app);
    var abandoned = queued[0].failed(queued[0].ctx, .runtime_abandoned, allocator);
    abandoned.deinitUndelivered(allocator);
}

fn expectGeneratedProjectionEligible(app: *const App) !void {
    const ready = switch (app.pages.review.review_projection.displayed) {
        .ready => |ready| ready,
        .idle, .failed => return error.ExpectedGeneratedProjection,
    };
    const bundle = switch (ready.value) {
        .generated_added_file => |bundle| bundle,
        else => return error.ExpectedGeneratedProjection,
    };
    try std.testing.expect(bundle.decoration == .eligible);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    acceptTestSource(&app);

    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedHunk,
    }

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
            try std.testing.expect(target.patch.len > 0);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    acceptTestSource(&app);

    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .ready => |target| {
            defer std.testing.allocator.free(target.patch);
            try std.testing.expectEqual(HunkMarkSource.projection, target.mark_source);
            try std.testing.expectEqualStrings("/repo", target.repo_root);
            try std.testing.expectEqualStrings("a", target.path);
            try std.testing.expectEqual(@as(usize, 0), target.hunk_index);
        },
        else => return error.ExpectedCachedHunkUnstageTarget,
    }
}

test "combined projection target is requested for mixed modified unstaged files" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.git_status.deinit();

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const target = app.reviewReloadView().projectionTarget() orelse return error.ExpectedCombinedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.combined_hunks, target.kind);
    try std.testing.expectEqual(app_review_projection.SourceKind.unstaged, target.source_kind);
    try std.testing.expectEqualStrings("/repo", target.repo_root);
    try std.testing.expectEqualStrings("a", target.path_key);

    app.config.source = .cached;
    try std.testing.expect(app.reviewReloadView().projectionTarget() == null);
}

test "active diff display uses ready combined projection by identity" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .diff_file = 0 } },
        } },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const request = try app_review_projection.cloneRequest(
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
    try std.testing.expectEqual(@as(usize, 2), display.combined_projection.staged_flags.len);
    try std.testing.expect(display.combined_projection.staged_flags[0]);
    try std.testing.expect(!display.combined_projection.staged_flags[1]);
}

test "background status refresh retains combined projection while cursor moves" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 11,
            .status_snapshot_revision = 13,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    const request = try app_review_projection.cloneRequest(
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
    acceptTestSource(&app);

    const projection_before = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    const hunks_before = projection_before.projection.file.hunks.ptr;
    const cursor_before = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(cursor_before > 0);

    _ = app.pages.review.status_load.prepare(true);
    syncTestActivation(&app);
    app.pages.review.load.generation +%= 1;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.ensureReviewProjection(&ctx);

    const retained = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedRetainedProjection;
    try std.testing.expectEqual(hunks_before, retained.projection.file.hunks.ptr);
    app.reviewNavigation().moveDiffCursorRows(.down);
    const cursor_after = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(cursor_after > cursor_before);
    try std.testing.expect(cursor_after != 0);
    switch (app.reviewOperations().selectedHunkToggleOperation()) {
        .stale_status => {},
        else => return error.ExpectedStaleProjectedHunkAuthority,
    }
}

test "unchanged full cycle preserves projection semantic identity" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 17,
            .status_snapshot_revision = 19,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 }, .diff_scroll = 2 },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);
    const request = try app_review_projection.cloneRequest(
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

    const projection_before = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    const hunks_before = projection_before.projection.file.hunks.ptr;
    const cursor_before = app.pages.review.viewer.diff_cursor;
    const scroll_before = app.pages.review.viewer.diff_scroll;

    const status_generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(1);
    app.pages.review.load.generation +%= 1;
    try std.testing.expect(app.pages.review.status_load.accept(status_generation));
    app.pages.review.status_load.markSuccess();

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.ensureReviewProjection(&ctx);

    const projection_after = app.reviewNavigationView().activeCombinedProjection() orelse return error.ExpectedCombinedProjection;
    try std.testing.expectEqual(hunks_before, projection_after.projection.file.hunks.ptr);
    try std.testing.expect(!app.pages.review.review_projection.hasPending());
    try std.testing.expectEqual(@as(u64, 17), app.pages.review.source_session_revision);
    try std.testing.expectEqual(@as(u64, 19), app.pages.review.status_snapshot_revision);
    try std.testing.expectEqual(cursor_before, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(scroll_before, app.pages.review.viewer.diff_scroll);
}

test "final projection prefers explicit interim navigation override" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .source_session_revision = 23,
            .status_snapshot_revision = 29,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const state_request = try app_review_projection.cloneRequest(
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
    app.pages.review.review_projection.pending = state_request;
    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 1 },
            .diff_cursor_offset = 5,
            .diff_scroll = 4,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .override = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 4,
    };

    const result_request = try app_review_projection.cloneRequest(
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
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.finishReviewProjectionLoad(&ctx, .{
        .request = result_request,
        .result = .{ .ready = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 0 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(?usize, 0), app.reviewNavigationView().selectedDiffCursorOffset());
}

test "empty watch source carries combined navigation into cached projection" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 }, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } },
            .source_session_revision = 37,
            .status_snapshot_revision = 41,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 }, .diff_scroll = 3 },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var mixed_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_status);
    const displayed_request = try app_review_projection.cloneRequest(
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
        .request = displayed_request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };
    const original_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(original_offset > 0);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });
    try std.testing.expect(app.pages.review.pending_display_navigation_restore != null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() != null);
    try std.testing.expectEqual(@as(usize, 0), app.reviewNavigationView().activeLoadedDiffConst().?.document.files.len);

    const staged_only = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = staged_only },
    });
    const target = app.reviewReloadView().projectionTarget() orelse return error.ExpectedCachedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.cached_diff, target.kind);

    app.pages.review.review_projection.pending = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    const result_request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    try app.finishReviewProjectionLoad(&ctx, .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeCachedDiffProjection() != null);
    const final_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expect(final_offset > 0);
    try std.testing.expect(final_offset <= original_offset);
}

test "empty watch source carries generated navigation into generated projection" {
    var app: App = .{
        .pages = .{ .review = .{
            .source_session_revision = 43,
            .status_snapshot_revision = 47,
        } },
        .allocator = std.testing.allocator,
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var untracked = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a\x00");
    try app.pages.review.git_status.replace("/repo", &untracked);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);
    app.pages.review.viewer.diff_cursor = .{ .metadata = 2 };
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } };
    app.pages.review.pending_reload = .{ .generation = 2, .kind = .watch };

    const displayed_request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .generated_added_file,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.displayed = .{ .ready = .{
        .request = displayed_request,
        .value = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(std.testing.allocator, "a", "one\ntwo\nthree\nfour\n") },
    } };
    const original_offset = app.reviewNavigationView().selectedDiffCursorOffset() orelse return error.ExpectedProjectionCursor;
    try std.testing.expectEqual(@as(usize, 2), original_offset);

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });
    try std.testing.expect(app.pages.review.pending_display_navigation_restore != null);

    const same_untracked = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? a\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same_untracked },
    });
    const target = app.reviewReloadView().projectionTarget() orelse return error.ExpectedGeneratedProjectionTarget;
    try std.testing.expectEqual(app_review_projection.Kind.generated_added_file, target.kind);

    app.pages.review.review_projection.pending = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    const result_request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        target.repo_root,
        target.path_key,
        target.kind,
        target.source_kind,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    try app.finishReviewProjectionLoad(&ctx, .{
        .request = result_request,
        .result = .{ .ready = .{ .generated_added_file = try app_review_projection.generatedFileFromContent(std.testing.allocator, "a", "one\ntwo\nthree\nfour\nfive\n") } },
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeGeneratedFileProjection() != null);
    try std.testing.expectEqual(@as(?usize, 2), app.reviewNavigationView().selectedDiffCursorOffset());
}

test "fresh empty status consumes pending display restore at raw terminal" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2, .pending = .{ .diff_load = 2 }, .state = .{ .loaded = app_test_support.loadedSession(app_test_support.loadedDiffOne()) } },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7, .origin = .background, .background_cycle_id = 1 } },
            .source_session_revision = 53,
            .status_snapshot_revision = 59,
            .viewer = .{ .selected_target = .{ .diff_file = 0 }, .diff_cursor = .{ .hunk_header = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var mixed_status = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_status);
    const displayed_request = try app_review_projection.cloneRequest(
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
        .request = displayed_request,
        .value = .{ .combined_hunks = try testCombinedHunkBundle(std.testing.allocator) },
    } };

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.finishDiffLoad(&ctx, .{ .identity = page.RequestIdentity.review(0, 1), .generation = 2, .result = .empty });
    try std.testing.expect(app.pages.review.pending_display_navigation_restore != null);

    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .background_cycle_id = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);

    app.reviewNavigation().initializeDiffCursorForSelectedFile();
    try std.testing.expectEqual(@as(?usize, 0), app.reviewNavigationView().selectedDiffCursorOffset());

    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
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

test "selected path change supersedes pending display restore" {
    var app: App = .{
        .pages = .{ .review = .{
            .source_session_revision = 61,
            .status_snapshot_revision = 67,
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00M  b\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);
    app.pages.review.viewer.selected_target = .{ .status_only = 1 };
    app.pages.review.pending_display_navigation_restore = .{
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .source_kind = .unstaged,
        .source_session_revision = app.pages.review.source_session_revision,
        .original = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .selected_target_tag = .status_only,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
        .captured_input_revision = 0,
    };
    app.pages.review.review_projection.pending = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        2,
        "/repo",
        "b",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.ensureReviewProjection(&ctx);

    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);
    try std.testing.expect(app.pages.review.review_projection.pending != null);
    try std.testing.expectEqualStrings("b", app.pages.review.review_projection.pending.?.path_key);
}

test "superseded projection completion cannot replace display" {
    var app: App = .{
        .pages = .{ .review = .{
            .source_session_revision = 71,
            .status_snapshot_revision = 73,
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().createStatusOnlyLoadedSession(std.testing.allocator, app.pages.review.git_status.document);
    const stale_status_revision = app.pages.review.status_snapshot_revision - 1;
    app.pages.review.review_projection.pending = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        stale_status_revision,
    );
    const result_request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        stale_status_revision,
    );
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishReviewProjectionLoad(&ctx, .{
        .request = result_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.review.review_projection.pending != null);
    try std.testing.expect(!app.pages.review.review_projection.hasDisplayed());
    try std.testing.expectEqual(stale_status_revision, app.pages.review.review_projection.pending.?.status_snapshot_revision);
}

test "cached preview keeps search input while projection is pending" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 7 },
            .status_load = .{ .generation = 3 },
            .viewer = .{ .selected_target = .{ .status_only = 0 }, .diff_cursor = .{ .hunk_header = 0 } },
        } },
        .terminal_size = .{ .width = 100, .height = 40 },
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    app.pages.review.review_projection.pending = request;

    app.reviewNavigation().enterSearchMode();
    try std.testing.expect(app.pages.review.search.mode);
    setDiffSearchInput(&app, "staged");
    app.reviewNavigation().submitSearch();
    try std.testing.expect(!app.pages.review.search.mode);
    try std.testing.expect(app.pages.review.search.match == null);
    try std.testing.expectEqualStrings("staged", app.pages.review.search.query.slice());

    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    const ready_request = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        app.pages.review.source_session_revision,
        app.pages.review.status_snapshot_revision,
    );
    try app.finishReviewProjectionLoad(&ctx, .{
        .request = ready_request,
        .result = .{ .ready = .{ .cached_diff = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_cached_projection) } },
    });

    try std.testing.expect(app.pages.review.search.match != null);
    try std.testing.expectEqual(@as(?usize, 2), app.pages.review.search.match_offset);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.review_projection.deinit(std.testing.allocator);
    acceptTestSource(&app);

    var mixed_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "MM a\x00");
    try app.pages.review.git_status.replace("/repo", &mixed_bundle);

    const request = try app_review_projection.cloneRequest(
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
            try std.testing.expectEqual(HunkMarkSource.projection, target.mark_source);
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
            try std.testing.expectEqual(HunkMarkSource.projection, target.mark_source);
        },
        else => return error.ExpectedReadyProjectedStage,
    }
    switch (app.reviewOperations().selectedHunkUnstageTarget(std.testing.allocator)) {
        .not_staged_hunk => {},
        else => return error.ExpectedNotStagedProjectedHunk,
    }
}

test "stagedHunkFlagsForFile display normalization does not clear hunk action marks" {
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    defer app.pages.review.git_status.deinit();
    acceptTestSource(&app);

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 1);

    var staged_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "M  a\x00");
    try app.pages.review.git_status.replace("/repo", &staged_bundle);
    try std.testing.expectEqual(@as(usize, 0), (try app.reviewNavigationView().stagedHunkFlagsForFile(arena.allocator(), app_test_support.file_with_hunks)).len);

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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const stage_pending = app.actions.begin(.stage_hunk);
    try app.finishStageHunk(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .result = .ok,
    });

    try std.testing.expect(app.pages.review.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.staged_hunks.items.items.len);

    const unstage_pending = app.actions.begin(.unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .result = .ok,
    });

    try std.testing.expect(!app.pages.review.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
}

test "projection hunk action results reload status without mutating session marks" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffOne()),
        } },
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    defer app.pages.review.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusTasks(&ctx, allocator);

    const stage_pending = app.actions.begin(.stage_hunk);
    try app.finishStageHunk(&ctx, .{
        .pending = stage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .mark_source = .projection,
        .result = .ok,
    });

    try std.testing.expect(!app.pages.review.staged_hunks.contains("/repo", "a", 1));
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.staged_hunks.items.items.len);
    try std.testing.expect(app.pages.review.status_load.isPending());
    clearPendingStatusTasks(&ctx, allocator);

    try app.pages.review.staged_hunks.add(allocator, "/repo", "a", 1);
    const unstage_pending = app.actions.begin(.unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .mark_source = .projection,
        .result = .ok,
    });

    try std.testing.expect(app.pages.review.staged_hunks.contains("/repo", "a", 1));
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    _ = app.activateReview();
    defer app.pages.review.staged_hunks.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };
    defer clearPendingStatusAndDiffTasks(&ctx, allocator);

    try app.pages.review.staged_hunks.add(allocator, "/repo", "a", 1);
    const unstage_pending = app.actions.begin(.unstage_hunk);
    try app.finishUnstageHunk(&ctx, .{
        .pending = unstage_pending,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .path = try allocator.dupe(u8, "a"),
        .hunk_index = 1,
        .mark_source = .projection,
        .reload_after_success = true,
        .result = .ok,
    });

    try std.testing.expect(app.pages.review.staged_hunks.contains("/repo", "a", 1));
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.pages.review.staged_hunks.deinit(allocator);

    try app.pages.review.staged_hunks.add(allocator, "/repo", "a", 0);
    try std.testing.expect(app.pages.review.staged_hunks.contains("/repo", "a", 0));

    app.reviewReload().clearLoadedDiff(app.allocator);

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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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

test "finishDiffLoad applies active changed file filter" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 1 },
            .review_display = .{ .changed_file_filter = .added },
        } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.reviewed_store.deinit(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_added_deleted);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 2), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(?usize, 0), loaded.visibleNodeAt(0));
    try std.testing.expectEqual(@as(?usize, 1), loaded.visibleNodeAt(1));
    try std.testing.expectEqual(file_tree.Status.added, loaded.tree.nodes[1].status.?);
}

test "repo picker focuses active workspace repository" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
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

    var app: App = .{
        .repo_state = .{
            .discovery = .{ .workspace = .{
                .current_root = try allocator.dupe(u8, "/work"),
                .repos = repos,
            } },
            .active_index = 1,
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);

    try app.enterRepoPickerMode(allocator);

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.list.filter.list.focusedIndex());
}

test "repo picker opens for a single repository" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "repo"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);

    try app.enterRepoPickerMode(allocator);

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("repo", app.repo_picker.list.filter.labels[0]);
}

test "repo picker removes selected recent entry only" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "active"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/active"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    try app.recent_repos.rememberRepo(allocator, "/work/recent");
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.enterRepoPickerMode(allocator);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker.list.filter.labels.len);

    try app.removeSelectedRecentRepository(&ctx);
    try std.testing.expectEqual(@as(usize, 1), app.recent_repos.entries.items.len);

    app.repo_picker.list.filter.update(.move_next);
    try app.removeSelectedRecentRepository(&ctx);
    try std.testing.expectEqual(@as(usize, 0), app.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("active", app.repo_picker.list.filter.labels[0]);
}

test "repo picker removes stale recent entry after path discovery error" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "active"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/active"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.recent_repos.rememberRepo(allocator, "/gone/repo");
    try app.enterRepoPickerMode(allocator);
    const generation = app.repo_picker.beginPathDiscovery();
    app.pending_repo_path_recent_source = .{ .kind = .repo, .index = 0 };

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/gone/repo"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    try app.finishRepoPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 0), app.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(?app_prompt.RepoPickerPathError, null), app.repo_picker.path_error);
    try std.testing.expectEqual(@as(usize, 1), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("active", app.repo_picker.list.filter.labels[0]);
}

test "repo picker keeps recent entry for non-stale path discovery error" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "active"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/active"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.recent_repos.rememberRepo(allocator, "/mounted/repo");
    try app.enterRepoPickerMode(allocator);
    const generation = app.repo_picker.beginPathDiscovery();
    app.pending_repo_path_recent_source = .{ .kind = .repo, .index = 0 };

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/mounted/repo"),
        .result = .{ .input_error = error.CannotAccessPath },
    };
    try app.finishRepoPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 1), app.recent_repos.entries.items.len);
    try std.testing.expectEqual(app_prompt.RepoPickerPathError.cannot_access_path, app.repo_picker.path_error.?);
}

test "repo picker removes stale recent workspace after no repos remain" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "active"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/active"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.recent_repos.rememberWorkspace(allocator, "/gone/workspace");
    try app.enterRepoPickerMode(allocator);
    const generation = app.repo_picker.beginPathDiscovery();
    app.pending_repo_path_recent_source = .{ .kind = .workspace, .index = 0 };

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/gone/workspace"),
        .result = .{ .input_error = error.NoGitRepositoriesFound },
    };
    try app.finishRepoPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 0), app.recent_repos.entries.items.len);
    try std.testing.expectEqual(@as(?app_prompt.RepoPickerPathError, null), app.repo_picker.path_error);
}

test "repo picker path input errors do not remove recent history" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true, .input_mode = .path_input },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "active"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/active"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.recent_repos.rememberRepo(allocator, "/kept/repo");
    try app.enterRepoPickerMode(allocator);
    const generation = app.repo_picker.beginPathDiscovery();

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/typed/missing"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    try app.finishRepoPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 1), app.recent_repos.entries.items.len);
    try std.testing.expectEqualStrings("/kept/repo", app.recent_repos.entries.items[0].path);
    try std.testing.expectEqual(app_prompt.RepoPickerPathError.path_does_not_exist, app.repo_picker.path_error.?);
}

test "repo picker stale recent removal falls back to matching path after index shift" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "active"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/work/active"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.recent_repos.rememberRepo(allocator, "/old/first");
    try app.recent_repos.rememberRepo(allocator, "/old/second");
    try app.enterRepoPickerMode(allocator);
    const generation = app.repo_picker.beginPathDiscovery();
    app.pending_repo_path_recent_source = .{ .kind = .repo, .index = 1 };
    try std.testing.expect(app.recent_repos.removeAt(allocator, 0));

    var finished = RepoPathDiscoveryFinished{
        .generation = generation,
        .submitted_path = try allocator.dupe(u8, "/old/first"),
        .result = .{ .input_error = error.PathDoesNotExist },
    };
    try app.finishRepoPathDiscovery(&ctx, finished);
    finished = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(@as(usize, 0), app.recent_repos.entries.items.len);
}

test "workspace path discovery keeps picker open for explicit repo selection" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
    repos[0] = .{
        .label = try allocator.dupe(u8, "chasen"),
        .display_path = try allocator.dupe(u8, "chasen"),
        .canonical_root = try allocator.dupe(u8, "/work/chasen"),
    };
    repos[1] = .{
        .label = try allocator.dupe(u8, "gitframe"),
        .display_path = try allocator.dupe(u8, "gitframe"),
        .canonical_root = try allocator.dupe(u8, "/work/gitframe"),
    };

    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "current"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/current/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.clearRepoPickerDiscovery(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.acceptRepoPathDiscovery(&ctx, .{ .workspace = .{
        .current_root = try allocator.dupe(u8, "/work"),
        .repos = repos,
    } });

    try std.testing.expect(app.repo_picker.mode);
    try std.testing.expectEqual(app_prompt.RepoPickerInputMode.list, app.repo_picker.input_mode);
    try std.testing.expectEqualStrings("/current/repo", app.repo_state.activeRoot().?);
    try std.testing.expectEqual(@as(usize, 2), app.repo_picker.list.filter.labels.len);
    try std.testing.expectEqualStrings("chasen", app.repo_picker.list.filter.labels[0]);
    try std.testing.expectEqualStrings("gitframe", app.repo_picker.list.filter.labels[1]);
}

test "closed repo picker rejects stale path discovery result after reopen" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "current"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/current/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.clearRepoPickerDiscovery(allocator);
    defer app.deinitRepoPickerItems(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const old_generation = app.repo_picker.beginPathDiscovery();
    try app.cancelRepoPickerMode(allocator);
    try app.enterRepoPickerMode(allocator);
    const new_generation = app.repo_picker.beginPathDiscovery();

    var stale = RepoPathDiscoveryFinished{
        .generation = old_generation,
        .submitted_path = try allocator.dupe(u8, "/old/repo"),
        .result = .{ .discovered = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "old"),
            .display_path = try allocator.dupe(u8, "."),
            .canonical_root = try allocator.dupe(u8, "/old/repo"),
        } } },
    };
    try app.finishRepoPathDiscovery(&ctx, stale);
    stale = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expect(new_generation != old_generation);
    try std.testing.expectEqualStrings("/current/repo", app.repo_state.activeRoot().?);
}

test "repo picker path cancel rejects stale discovery result" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .repo_picker = .{ .mode = true, .input_mode = .path_input },
        .repo_state = .{
            .discovery = .{ .single_repo = .{
                .label = try allocator.dupe(u8, "current"),
                .display_path = try allocator.dupe(u8, "."),
                .canonical_root = try allocator.dupe(u8, "/current/repo"),
            } },
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.clearRepoPickerDiscovery(allocator);
    defer app.deinitRepoPickerItems(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    const stale_generation = app.repo_picker.beginPathDiscovery();
    try app.cancelRepoPickerMode(allocator);

    var stale = RepoPathDiscoveryFinished{
        .generation = stale_generation,
        .submitted_path = try allocator.dupe(u8, "/old/repo"),
        .result = .{ .discovered = .{ .single_repo = .{
            .label = try allocator.dupe(u8, "old"),
            .display_path = try allocator.dupe(u8, "."),
            .canonical_root = try allocator.dupe(u8, "/old/repo"),
        } } },
    };
    try app.finishRepoPathDiscovery(&ctx, stale);
    stale = .{ .generation = 0, .submitted_path = &.{}, .result = .empty };

    try std.testing.expectEqual(app_prompt.RepoPickerInputMode.list, app.repo_picker.input_mode);
    try std.testing.expect(!app.repo_picker.path_pending);
    try std.testing.expectEqualStrings("/current/repo", app.repo_state.activeRoot().?);
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

test "repo switch clears action selection restore" {
    const allocator = std.testing.allocator;
    const repos = try allocator.alloc(repo_discovery.RepoEntry, 2);
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

    var app: App = .{
        .allocator = allocator,
        .repo_state = .{
            .discovery = .{ .workspace = .{
                .current_root = try allocator.dupe(u8, "/work"),
                .repos = repos,
            } },
            .active_index = 0,
        },
    };
    defer app.repo_state.deinit(allocator);
    defer app.repo_picker.deinit(allocator);
    defer app.deinitRepoPickerItems(allocator);
    defer app.recent_repos.deinit(allocator);
    defer app.reviewNavigation().clearPendingSelectionRestore(allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    try app.reviewNavigation().setPendingSelectionRestore(allocator, "src/main.zig");
    try app.enterRepoPickerMode(allocator);

    try app.submitRepoPicker(&ctx);

    try std.testing.expect(app.pages.review.pending_selection_restore == null);
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);
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
    defer app.reviewReload().clearLoadedDiff(app.allocator);

    try app.view(&ts.surface);

    try app_test_support.expectSnapshotContains(&ts, "No files match current filters");
    try app_test_support.expectSnapshotContains(&ts, "Press F to change filter or r to reload.");
}

test "load runtime pending tracks task kind and generation" {
    var load: LoadRuntimeState = .{};

    const discovery_generation = load.beginRepoDiscovery();
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(discovery_generation));
    try std.testing.expect(!load.finishPending(.{ .diff_load = discovery_generation }));
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.finishPending(.{ .repo_discovery = discovery_generation }));
    try std.testing.expect(!load.hasPending());

    const diff_generation = load.beginDiffLoad();
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(diff_generation));
    try std.testing.expect(load.clearPendingIfCurrent(.{ .diff_load = diff_generation }));
    try std.testing.expect(!load.hasPending());
}

test "load runtime keeps newer pending when stale task finishes" {
    var load: LoadRuntimeState = .{};

    const stale_generation = load.beginDiffLoad();
    const current_generation = load.beginDiffLoad();

    try std.testing.expect(!load.finishPending(.{ .diff_load = stale_generation }));
    try std.testing.expect(load.hasPending());
    try std.testing.expect(load.isCurrent(current_generation));
    try std.testing.expect(load.finishPending(.{ .diff_load = current_generation }));
    try std.testing.expect(!load.hasPending());
}

test "finishDiffLoad takes current loaded bundle ownership" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.load.state == .loaded);
    try std.testing.expect(app.pages.review.load.state.loaded.loaded.document.files.len > 0);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.load.state.loaded.loaded.document.files.len);
}

test "finishDiffLoad initially selects first visible file node" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.viewer.selected_node);
}

test "finishDiffLoad initially selects first visible file after status projection" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    const loaded = app.reviewNavigationView().activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .repo_root => return error.ExpectedVisibleFileNode,
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.pages.review.viewer.selected_target.?);
}

test "finishDiffLoad keeps initial visible selection intent for later status projection" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 1 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = app_test_support.loadedDiffFileOneFirst(),
    };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.pending_initial_first_visible_selection);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    try std.testing.expect(!app.pages.review.pending_initial_first_visible_selection);

    const loaded = app.reviewNavigationView().activeLoadedDiffConst().?;
    const first_node_index = loaded.firstVisibleFileNode() orelse return error.ExpectedVisibleFileNode;
    const first_node = loaded.tree.nodes[first_node_index];
    const expected_target: context.SelectedTarget = switch (first_node.target) {
        .diff_file => |file_index| .{ .diff_file = file_index },
        .status_entry => |status_index| .{ .status_only = status_index },
        .repo_root => return error.ExpectedVisibleFileNode,
        .directory => return error.ExpectedVisibleFileNode,
    };

    try std.testing.expectEqual(first_node_index, app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(expected_target, app.pages.review.viewer.selected_target.?);
}

test "status projection rebuild keeps selected node on same path key" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const before_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", before_path);

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const after_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", after_path);
}

test "status load skips identical snapshot without rebuilding active tree" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    const tree_ptr = app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr;

    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    try std.testing.expectEqual(tree_ptr, app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr);
}

test "status refresh path skips identical snapshot without rebuilding active tree" {
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(app_test_support.loadedDiffTwo()),
        } },
        .allocator = std.testing.allocator,
    };
    _ = app.activateReview();
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    const tree_ptr = app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr;

    app.startStatusLoad(&ctx, "/repo", .foreground, null);
    try std.testing.expect(app.pages.review.git_status.repo_root != null);
    try std.testing.expectEqual(@as(usize, 1), ctx._pending_tasks_with[0..ctx._pending_tasks_with_len].len);
    clearPendingStatusTasks(&ctx, std.testing.allocator);

    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = app.pages.review.status_load.generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    try std.testing.expectEqual(tree_ptr, app.reviewNavigationView().activeLoadedDiffConst().?.tree.nodes.ptr);
}

test "status refresh drops snapshot when repo root changes" {
    var app: App = .{};
    _ = app.activateReview();
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? old.zig\x00");
    try app.pages.review.git_status.replace("/old", &current);

    app.startStatusLoad(&ctx, "/new", .foreground, null);
    defer clearPendingStatusTasks(&ctx, std.testing.allocator);

    try std.testing.expect(app.pages.review.git_status.repo_root == null);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
}

test "finishStatusLoad keeps clean repository snapshot fresh" {
    var app: App = .{
        .pages = .{ .review = .{
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
        } },
    };
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const clean = try git_status.StatusBundle.parseOwned(std.testing.allocator, "");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expect(!app.pages.review.status_load.isPending());
    try std.testing.expectEqualStrings("/repo", app.pages.review.git_status.repo_root.?);
    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
}

test "background status failure retains display snapshot and marks action freshness stale" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.pages.review.git_status.deinit();
    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);

    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .status));
    const generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(cycle_id);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "transient status failure" },
    });

    try std.testing.expectEqualStrings("/repo", app.pages.review.git_status.repo_root.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.git_status.document.entries.len);
    try std.testing.expect(!app.pages.review.status_load.isFresh());
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);

    const recovery_generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(null);
    const same = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M src/a.zig\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = recovery_generation,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });
    try std.testing.expect(app.pages.review.status_load.isFresh());
}

test "background status completion during repository action is discarded and releases cycle" {
    var app: App = .{ .allocator = std.testing.allocator };
    defer app.pages.review.git_status.deinit();
    var current = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M old.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);

    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .status));
    const generation = app.pages.review.status_load.prepare(true);
    app.pages.review.status_load.begin(cycle_id);
    _ = app.actions.begin(.stage_file);
    const changed = try git_status.StatusBundle.parseOwned(std.testing.allocator, " M new.zig\x00");
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .background_cycle_id = cycle_id,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = changed },
    });

    try std.testing.expectEqualStrings("old.zig", app.pages.review.git_status.document.entries[0].path);
    try std.testing.expect(!app.pages.review.status_load.isPending());
    try std.testing.expectEqual(app_auto_reload.AuxiliaryFreshness.stale_refresh, app.pages.review.status_load.freshness);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "finishDiffLoad frees stale loaded bundle" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 2 } } },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.load.state == .idle);
}

test "auto reload tick skips while auxiliary cycle members or mouse selection are pending" {
    var app: App = .{};
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    app.pages.review.status_load.pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 };
    var status_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.autoReloadTick(&status_ctx);
    try std.testing.expectEqual(@as(usize, 0), status_ctx._pending_tasks_with_len);
    try std.testing.expect(status_ctx._redraw_suppressed);

    app.pages.review.status_load.pending = null;
    app.pages.review.branch_status_load.pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 };
    var branch_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.autoReloadTick(&branch_ctx);
    try std.testing.expectEqual(@as(usize, 0), branch_ctx._pending_tasks_with_len);
    try std.testing.expect(branch_ctx._redraw_suppressed);

    app.pages.review.branch_status_load.pending = null;
    app.pages.review.review_projection.pending = try app_review_projection.cloneRequest(
        std.testing.allocator,
        page.RequestIdentity.review(0, 1),
        1,
        "/repo",
        "a",
        .cached_diff,
        .unstaged,
        1,
        1,
    );
    var projection_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.autoReloadTick(&projection_ctx);
    try std.testing.expectEqual(@as(usize, 0), projection_ctx._pending_tasks_with_len);
    try std.testing.expect(projection_ctx._redraw_suppressed);
    app.pages.review.review_projection.clearPending(std.testing.allocator);

    app.pages.review.selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } };
    var selection_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.autoReloadTick(&selection_ctx);
    try std.testing.expectEqual(@as(usize, 0), selection_ctx._pending_tasks_with_len);
    try std.testing.expect(selection_ctx._redraw_suppressed);

    app.pages.review.selection_owner = .none;
    _ = app.actions.begin(.stage_file);
    var action_ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    try app.autoReloadTick(&action_ctx);
    try std.testing.expectEqual(@as(usize, 0), action_ctx._pending_tasks_with_len);
    try std.testing.expect(action_ctx._redraw_suppressed);
}

test "stale diff result does not clear newer pending reload metadata" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 2 } } },
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.pending_reload = .{
        .generation = 2,
        .kind = .watch,
        .anchor = .{
            .path_key = try std.testing.allocator.dupe(u8, "a"),
            .selected_target_tag = .diff_file,
            .visible_sidebar_row = 0,
            .diff_cursor = .{ .hunk_header = 0 },
            .diff_cursor_offset = 0,
            .diff_scroll = 0,
            .diff_horizontal_scroll = 0,
            .sidebar_horizontal_scroll = 0,
            .search_coordinate = null,
        },
    };

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.pending_reload != null);
    try std.testing.expectEqual(@as(u64, 2), app.pages.review.pending_reload.?.generation);
}

test "watch no-op diff load preserves session view state and staged hunk marks" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = 3,
                .diff_horizontal_scroll = 4,
                .sidebar_horizontal_scroll = 2,
            },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.pages.review.staged_hunks.deinit(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.pages.review.staged_hunks.add(std.testing.allocator, "/repo", "a", 0);
    app.pages.review.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 1 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 3), app.pages.review.viewer.diff_scroll);
    try std.testing.expectEqual(@as(usize, 4), app.pages.review.viewer.diff_horizontal_scroll);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.sidebar_horizontal_scroll);
    try std.testing.expect(app.pages.review.staged_hunks.contains("/repo", "a", 0));
    try std.testing.expect(app.pages.review.pending_reload == null);
}

test "changed watch reload restores acceptance-time navigation instead of launch anchor" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 0 },
            },
            .pending_reload = .{
                .generation = 2,
                .kind = .watch,
                .anchor = .{
                    .path_key = try std.testing.allocator.dupe(u8, "a"),
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
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    const acceptance_cursor = app.pages.review.viewer.diff_cursor;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(acceptance_cursor, app.pages.review.viewer.diff_cursor);
    try std.testing.expect(app.pages.review.pending_reload == null);
    const restore = app.pages.review.pending_display_navigation_restore orelse return error.ExpectedAcceptanceTimeRestore;
    try std.testing.expectEqual(acceptance_cursor, restore.original.diff_cursor);
}

test "unchanged recovery clears its source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{
                .generation = 2,
                .kind = .watch,
                .anchor = .{
                    .path_key = try std.testing.allocator.dupe(u8, "a"),
                    .selected_target_tag = .diff_file,
                    .visible_sidebar_row = 0,
                    .diff_cursor = .{ .hunk_header = 0 },
                    .diff_cursor_offset = 0,
                    .diff_scroll = 0,
                    .diff_horizontal_scroll = 0,
                    .sidebar_horizontal_scroll = 0,
                    .search_coordinate = null,
                },
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "auto reload failed: transient", .{});
    const before = app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
    try std.testing.expectEqual(before, app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!ctx._redraw_suppressed);
}

test "unchanged source recovery preserves a newer auxiliary failure" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("source transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "source failed", .{});
    app.setReviewStatus("status load failed: auxiliary transient", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expectEqualStrings("status load failed: auxiliary transient", app.pages.review.status.text());
    try std.testing.expect(ctx._redraw_suppressed);
}

test "auxiliary failure followed by source failure clears only the recovered source message" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .failed_static = "auxiliary transient" },
    });
    try std.testing.expectEqualStrings("status load failed: auxiliary transient", app.pages.review.status.text());

    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "source transient" },
    });
    try std.testing.expectEqualStrings("auto reload failed: source transient", app.pages.review.status.text());

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .unchanged = fingerprint },
    });
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!ctx._redraw_suppressed);
}

test "ordinary unchanged source completion suppresses redraw" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .unchanged = fingerprint },
    });

    try std.testing.expect(ctx._redraw_suppressed);
}

test "changed loaded recovery clears its matching source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const old_fingerprint = content_fingerprint.Fingerprint.init("old");
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(old_fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("source transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "auto reload failed: source transient", .{});
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!ctx._redraw_suppressed);
}

test "empty recovery clears its matching source failure and redraws" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const old_fingerprint = content_fingerprint.Fingerprint.init("old");
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(old_fingerprint);
    _ = app.pages.review.auto_reload.markSourceFailure("source transient");
    app.pages.review.status.setSourceReloadFailure(app.pages.review.auto_reload.last_failure.?.digest, "auto reload failed: source transient", .{});
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
    try std.testing.expectEqualStrings("", app.pages.review.status.text());
    try std.testing.expect(!ctx._redraw_suppressed);
}

test "destructive action-result failure invalidates accepted source before identical success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .action_result },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "foreground failed" },
    });
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.reviewNavigationView().activeLoadedDiffConst() == null);

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(fingerprint));
}

test "destructive manual failure invalidates accepted source before identical success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .manual },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "manual failed" },
    });
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.review.load.state == .failed);

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(fingerprint));
}

test "diff task start failure invalidates accepted source and next watch cannot return unchanged" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
        } },
        .allocator = std.testing.allocator,
        .config = .{ .source = .stdin },
    };
    _ = app.activateReview();
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.auto_reload.acceptSource(fingerprint);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    ctx._pending_tasks_with_len = 16;

    try std.testing.expectError(error.TaskLimitExceeded, app.startDiffLoadWithRepoRoot(&ctx, null, .{
        .clear_visible_state = true,
        .kind = .manual,
    }));
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);
    try std.testing.expect(app.pages.review.load.state == .failed);

    ctx._pending_tasks_with_len = 0;
    try app.startDiffLoadWithRepoRoot(&ctx, null, .{
        .clear_visible_state = false,
        .kind = .watch,
    });
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    try std.testing.expect(task.expected_fingerprint == null);
    const generation = task.generation;
    diff_source.freeLoadRequest(std.testing.allocator, task.request);
    std.testing.allocator.destroy(task);

    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
}

test "watch failure retains display and blocks source-derived actions until success" {
    var current = app_test_support.loadedDiffOne();
    current.text = app_test_support.diff_one;
    const fingerprint = content_fingerprint.Fingerprint.init(app_test_support.diff_one);
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload.acceptSource(fingerprint);
    const before = app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr;
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .failed_static = "transient failure" },
    });
    try std.testing.expectEqual(before, app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr);
    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .unchanged = fingerprint },
    });
    try std.testing.expect(app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expectEqual(before, app.reviewNavigationView().activeLoadedDiffConst().?.text.ptr);
}

test "changed watch result arriving during mouse selection defers apply until release" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.review.deferred_source_apply != null);
    try std.testing.expectEqualStrings("old", app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle.?.pending.deferred_source_apply);

    app.reviewNavigation().clearDiffSelection();
    try app.applyDeferredSource(&ctx);
    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "background source completion during repository action is discarded and releases cycle" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    const accepted = content_fingerprint.Fingerprint.init("old");
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    app.pages.review.auto_reload.acceptSource(accepted);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    _ = app.actions.begin(.stage_file);
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqualStrings("old", app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(accepted));
    try std.testing.expect(app.pages.review.load.pending == null);
    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);

    app.actions.clear();
    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .action_result };
    const authoritative = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .loaded = authoritative },
    });
    try std.testing.expectEqualStrings(app_test_support.diff_one, app.reviewNavigationView().activeLoadedDiffConst().?.text);
}

test "deferred background source is discarded when a repository action starts" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.review.deferred_source_apply != null);

    _ = app.actions.begin(.stage_file);
    app.reviewNavigation().clearDiffSelection();
    try app.applyDeferredSource(&ctx);

    try std.testing.expectEqualStrings("old", app.reviewNavigationView().activeLoadedDiffConst().?.text);
    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expect(app.pages.review.pending_reload == null);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "deferred changed watch captures navigation when selection ends" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_node = 0,
                .diff_cursor = .{ .metadata = 0 },
            },
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .{ .loaded = bundle },
    });
    try std.testing.expect(app.pages.review.deferred_source_apply != null);
    try std.testing.expect(app.pages.review.pending_display_navigation_restore == null);

    app.pages.review.viewer.diff_cursor = .{ .hunk_header = 0 };
    const navigation_at_apply = app.pages.review.viewer.diff_cursor;
    app.reviewNavigation().clearDiffSelection();
    try app.applyDeferredSource(&ctx);

    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expectEqual(navigation_at_apply, app.pages.review.viewer.diff_cursor);
    const restore = app.pages.review.pending_display_navigation_restore orelse return error.ExpectedAcceptanceTimeRestore;
    try std.testing.expectEqual(navigation_at_apply, restore.original.diff_cursor);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "empty watch result defers during selection and focus loss applies it" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .pending_reload = .{ .generation = 2, .kind = .watch },
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearDeferredSourceApply(std.testing.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.generation = 2;
    app.pages.review.load.pending = .{ .diff_load = 2 };
    app.pages.review.auto_reload = .init(.inherit, .{}, .unstaged);
    const cycle_id = app.pages.review.auto_reload.beginCycle().?;
    try std.testing.expect(app.pages.review.auto_reload.markMemberStarted(cycle_id, .source));
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .background_cycle_id = cycle_id,
        .result = .empty,
    });
    try std.testing.expect(app.pages.review.deferred_source_apply != null);
    try std.testing.expectEqualStrings("old", app.reviewNavigationView().activeLoadedDiffConst().?.text);

    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.review.selection_owner.activeMouseSelection());
    try std.testing.expect(app.pages.review.deferred_source_apply == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "focus loss terminates selection without a deferred result" {
    var app: App = .{
        .pages = .{ .review = .{
            .selection_owner = .{ .diff_header = .{ .identity = .{ .kind = .loaded_file, .path_key = "a" } } },
        } },
        .config = .{ .source = .{ .no_index = .{ .left = "left", .right = "right" } } },
    };
    _ = app.activateReview();
    app.pages.review.auto_reload = .init(.inherit, .{}, app.config.source);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try std.testing.expectEqual(App.Msg.focus_lost, app.handleEvent(.focus_out).?);
    try app.update(.focus_lost, &ctx);
    try std.testing.expect(!app.pages.review.selection_owner.activeMouseSelection());
    try std.testing.expect(app.pages.review.deferred_source_apply == null);

    try app.autoReloadTick(&ctx);
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    const cycle_id = task.background_cycle_id.?;
    const generation = task.generation;
    diff_source.freeLoadRequest(std.testing.allocator, task.request);
    std.testing.allocator.destroy(task);
    _ = app.pages.review.load.clearPendingIfCurrent(.{ .diff_load = generation });
    app.reviewReload().clearPendingReloadIfGeneration(std.testing.allocator, generation);
    app.pages.review.auto_reload.finishMember(cycle_id, .source);
    try std.testing.expect(app.pages.review.auto_reload.background_cycle == null);
}

test "anchored reload keeps cursor when search query is present" {
    var current = app_test_support.loadedDiffOne();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 0 },
                .selected_file = 0,
                .selected_node = 0,
                .diff_cursor = .{ .hunk_header = 1 },
                .diff_scroll = 2,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    setDiffSearchQuery(&app, "new");
    app.pages.review.search.match = .{ .coordinate = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 3 } } };
    app.pages.review.search.match_offset = 4;
    app.pages.review.load.generation = 2;
    try app.reviewReload().beginPendingReload(std.testing.allocator, 2, .manual);

    var changed = app_test_support.loadedDiffOne();
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .hunk_header = 1 }, app.pages.review.viewer.diff_cursor);
    try std.testing.expectEqual(@as(usize, 2), app.pages.review.viewer.diff_scroll);
    try std.testing.expect(app.pages.review.search.match != null);
}

test "manual reload restores anchor after visible state is cleared" {
    var current = app_test_support.loadedDiffTwo();
    current.text = "old";
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 1,
                .diff_cursor = .{ .metadata = 0 },
                .diff_scroll = 2,
            },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.load.generation = 2;
    try app.reviewReload().beginPendingReload(std.testing.allocator, 2, .manual);
    app.reviewReload().clearLoadedDiff(app.allocator);
    app.pages.review.load.state = .loading;

    var changed = app_test_support.loadedDiffTwo();
    changed.text = "changed";
    const bundle = app_load.LoadedDiffBundle{
        .arena = .init(std.testing.allocator),
        .loaded = changed,
    };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    try std.testing.expectEqual(context.SelectedTarget{ .diff_file = 1 }, app.pages.review.viewer.selected_target.?);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.viewer.selected_node);
    try std.testing.expectEqual(diff_view_model.BodyCoordinate{ .metadata = 0 }, app.pages.review.viewer.diff_cursor);
}

test "watch no-op preserves selected path when status finishes before diff" {
    var current = app_test_support.loadedDiffTwo();
    current.text = app_test_support.diff_one;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    app.pages.review.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const selected_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", selected_path);
}

test "watch no-op preserves selected path when status finishes after diff" {
    var current = app_test_support.loadedDiffTwo();
    current.text = app_test_support.diff_one;
    var app: App = .{
        .pages = .{ .review = .{
            .load = app_test_support.loadState(current),
            .viewer = .{
                .selected_target = .{ .diff_file = 1 },
                .selected_file = 1,
                .selected_node = 1,
            },
            .status_load = .{ .generation = 1, .pending = .{ .generation = 1 } },
            .pending_reload = .{ .generation = 2, .kind = .watch },
        } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    defer app.reviewReload().clearPendingReload(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    app.pages.review.load.generation = 2;
    const bundle = try app_load.buildLoadedBundle(std.testing.allocator, app_test_support.diff_one);
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .{ .loaded = bundle },
    });

    const status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? aa\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .repo_root = try std.testing.allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = status_bundle },
    });

    const selected_path = app.reviewNavigationView().selectedStagePathKey() orelse return error.ExpectedSelectedPath;
    try std.testing.expectEqualStrings("b", selected_path);
}

test "repo switch clears pending reload anchor" {
    var app: App = .{
        .pages = .{ .review = .{
            .pending_reload = .{
                .generation = 9,
                .kind = .manual,
                .anchor = .{
                    .path_key = try std.testing.allocator.dupe(u8, "a"),
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
    defer app.reviewReload().clearPendingReload(std.testing.allocator);

    app.closeRepoPickerForSwitch(std.testing.allocator);

    try std.testing.expect(app.pages.review.pending_reload == null);
}

test "finishDiffLoad records empty diff as no changes" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .empty,
    });

    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.review.load.state.empty);
    try std.testing.expectEqual(@as(u64, 1), app.pages.review.load.generation);
}

test "finishDiffLoad projects earlier status snapshot into empty diff" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(std.testing.allocator);
    defer if (app.pages.review.tree_order_scope) |scope| std.testing.allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? src/new.zig\x00");
    try app.pages.review.git_status.replace("/tmp/repo", &status_bundle);

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .empty,
    });

    const loaded = app.reviewNavigation().loadedDiff().?;
    try std.testing.expectEqual(@as(usize, 0), loaded.document.files.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.tree.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), loaded.visibleNodeCount());
    try std.testing.expectEqual(@as(usize, 0), loaded.tree.nodes[1].target.status_entry);
    try std.testing.expectEqual(context.SelectedTarget{ .status_only = 0 }, app.pages.review.viewer.selected_target);
}

test "clean loaded status tears down status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    _ = app.activateReview();
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });
    const empty_fingerprint = content_fingerprint.Fingerprint.init("");

    try std.testing.expect(app.reviewNavigation().loadedDiff() != null);
    try std.testing.expectEqual(@as(usize, 0), app.reviewNavigation().loadedDiff().?.document.files.len);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));

    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
    try std.testing.expect(app.reviewNavigation().loadedDiff() == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.review.load.state.empty);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source.?.fingerprint.eql(empty_fingerprint));
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());

    try app.startDiffLoadWithRepoRoot(&ctx, null, .{
        .clear_visible_state = false,
        .kind = .watch,
    });
    const entries = ctx.takePendingTasksWith();
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const task: *DiffLoadTask = @ptrCast(@alignCast(entries[0].ctx));
    try std.testing.expect(task.expected_fingerprint.?.eql(empty_fingerprint));
    const generation = task.generation;
    diff_source.freeLoadRequest(allocator, task.request);
    allocator.destroy(task);

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = generation,
        .result = .{ .unchanged = empty_fingerprint },
    });
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());
}

test "source failure before clean status-only teardown remains stale" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.finishDiffLoad(&ctx, .{ .identity = page.RequestIdentity.review(0, 1), .generation = 2, .result = .empty });
    try std.testing.expect(app.reviewNavigation().loadedDiff() != null);

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .failed_static = "source transient" },
    });
    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());

    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });

    try std.testing.expect(app.reviewNavigation().loadedDiff() == null);
    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.review.auto_reload.last_failure != null);
    try std.testing.expectEqualStrings("auto reload failed: source transient", app.pages.review.status.text());
}

test "source failure after clean status-only teardown remains stale" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewReload().clearPendingReload(allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.finishDiffLoad(&ctx, .{ .identity = page.RequestIdentity.review(0, 1), .generation = 2, .result = .empty });
    const clean = try git_status.StatusBundle.parseOwned(allocator, "");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = clean },
    });
    try std.testing.expect(app.pages.review.auto_reload.sourceIsFresh());

    app.pages.review.load.generation = 3;
    app.pages.review.load.pending = .{ .diff_load = 3 };
    app.pages.review.pending_reload = .{ .generation = 3, .kind = .watch };
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 3,
        .result = .{ .failed_static = "later source transient" },
    });

    try std.testing.expect(!app.pages.review.auto_reload.sourceIsActionable());
    try std.testing.expect(app.pages.review.auto_reload.last_failure != null);
}

test "fresh status-only targets fail closed without accepted source" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .allocator = allocator,
        .config = .{ .source = .unstaged },
        .repo_state = .{ .discovery = .{ .single_repo = .{
            .label = "repo",
            .display_path = "/repo",
            .canonical_root = "/repo",
        } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);

    var status_bundle = try git_status.StatusBundle.parseOwned(allocator, "AM src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &status_bundle);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);
    try std.testing.expect(app.pages.review.auto_reload.accepted_source == null);

    try std.testing.expectEqual(StageTargetResult.stale_source, app.reviewOperations().stageTarget());
    try std.testing.expectEqual(UnstageTargetResult.stale_source, app.reviewOperations().unstageTarget());
    try std.testing.expectEqual(DiscardTargetResult.stale_source, app.reviewOperations().discardTarget());
}

test "empty status result tears down status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });

    try std.testing.expect(app.reviewNavigation().loadedDiff() != null);

    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .empty,
    });

    try std.testing.expectEqual(@as(usize, 0), app.pages.review.git_status.document.entries.len);
    try std.testing.expect(app.reviewNavigation().loadedDiff() == null);
    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_changes, app.pages.review.load.state.empty);
}

test "identical staged-only status keeps status-only session after empty diff" {
    const allocator = std.testing.allocator;
    var app: App = .{
        .pages = .{ .review = .{
            .load = .{ .generation = 2 },
            .status_load = .{ .generation = 7, .pending = .{ .generation = 7 } },
        } },
        .allocator = allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.pages.review.git_status.deinit();
    defer app.pages.review.tree_order.deinit(allocator);
    defer if (app.pages.review.tree_order_scope) |scope| allocator.free(scope);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = allocator };

    var current = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.pages.review.git_status.replace("/repo", &current);
    try app.reviewReload().createStatusOnlyLoadedSession(allocator, app.pages.review.git_status.document);

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 2,
        .result = .empty,
    });

    const loaded_after_diff = app.reviewNavigation().loadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expectEqual(@as(usize, 0), loaded_after_diff.document.files.len);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.git_status.document.entries.len);

    const same = try git_status.StatusBundle.parseOwned(allocator, "M  src/main.zig\x00");
    try app.finishStatusLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 7,
        .repo_root = try allocator.dupe(u8, "/repo"),
        .result = .{ .loaded = same },
    });

    const loaded_after_status = app.reviewNavigation().loadedDiff() orelse return error.ExpectedLoadedDiff;
    try std.testing.expectEqual(@as(usize, 0), loaded_after_status.document.files.len);
    try std.testing.expect(loaded_after_status.visibleNodeCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), app.pages.review.git_status.document.entries.len);
}

test "finishRepoDiscovery records no repository as empty state" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };
    defer app.repo_state.deinit(std.testing.allocator);

    try app.finishRepoDiscovery(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .discovered = .{ .none = .{
            .current_root = try std.testing.allocator.dupe(u8, "/work"),
        } } },
    });

    try std.testing.expect(app.pages.review.load.state == .empty);
    try std.testing.expectEqual(EmptyReason.no_repository, app.pages.review.load.state.empty);
}

test "finishDiffLoad copies and frees current failed message" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    const message = try std.testing.allocator.dupe(u8, " failed \n");
    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .failed = message },
    });

    try std.testing.expect(app.pages.review.load.state == .failed);
    try std.testing.expectEqualStrings("failed", app.pages.review.load.state.failed.message);
}

test "finishDiffLoad failure clears pending selection restore" {
    var app: App = .{
        .pages = .{ .review = .{ .load = .{ .generation = 1 } } },
        .allocator = std.testing.allocator,
    };
    defer app.reviewReload().clearLoadedDiff(app.allocator);
    defer app.reviewNavigation().clearPendingSelectionRestore(std.testing.allocator);
    var ctx: chasen.Ctx(App.Msg) = .{ ._allocator = std.testing.allocator };

    try app.reviewNavigation().setPendingSelectionRestore(std.testing.allocator, "src/main.zig");

    try app.finishDiffLoad(&ctx, .{
        .identity = page.RequestIdentity.review(0, 1),
        .generation = 1,
        .result = .{ .failed_static = "failed" },
    });

    try std.testing.expect(app.pages.review.pending_selection_restore == null);
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

    try App.saveRecentRepositoriesState(std.testing.io, path, &store);

    var loaded = config_mod.loadState(allocator, std.testing.io, path);
    defer loaded.deinit();
    try std.testing.expect(loaded.warning == null);
    try std.testing.expectEqual(@as(usize, 2), loaded.state.value.recent_repositories.entries.len);
    try std.testing.expectEqual(config_mod.RecentRepositoryKind.repo, loaded.state.value.recent_repositories.entries[0].kind);
    try std.testing.expectEqualStrings("/tmp/work/repo", loaded.state.value.recent_repositories.entries[0].path);
    try std.testing.expectEqual(config_mod.RecentRepositoryKind.workspace, loaded.state.value.recent_repositories.entries[1].kind);
    try std.testing.expectEqualStrings("/tmp/work", loaded.state.value.recent_repositories.entries[1].path);
}

fn expectSearchCoordinate(app: *const App, expected: diff_view_model.BodyCoordinate) !void {
    try std.testing.expect(app.pages.review.search.match != null);
    try std.testing.expect(std.meta.eql(expected, app.pages.review.search.match.?.coordinate));
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

fn setFileSearchInput(app: *App, query: []const u8) void {
    @memcpy(app.pages.review.file_search.input.buffer[0..query.len], query);
    app.pages.review.file_search.input.len = query.len;
    app.pages.review.file_search.input.cursor = query.len;
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
        app.repo_epoch,
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
        const task: *RepositoryManifestTask = @ptrCast(@alignCast(entry.ctx));
        allocator.free(task.root_path);
        task.root.deinit();
        allocator.destroy(task);
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
    const entries = ctx.takePendingTasksWith();
    if (entries.len >= 1) {
        const task: *StatusLoadTask = @ptrCast(@alignCast(entries[0].ctx));
        allocator.free(task.repo_root);
        allocator.destroy(task);
    }
    if (entries.len >= 2) {
        const task: *BranchStatusLoadTask = @ptrCast(@alignCast(entries[1].ctx));
        allocator.free(task.repo_root);
        allocator.destroy(task);
    }
    if (entries.len >= 3) {
        const task: *DiffLoadTask = @ptrCast(@alignCast(entries[2].ctx));
        diff_source.freeLoadRequest(allocator, task.request);
        allocator.destroy(task);
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
            allocator.free(item.name);
            allocator.free(item.oid);
        }
    }
    for (specs, 0..) |spec, index| {
        items[index] = .{
            .name = try allocator.dupe(u8, spec.name),
            .oid = try allocator.dupe(u8, spec.oid),
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

    var projection_arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer projection_arena.deinit();
    const projection = try diff_hunk_projection.build(
        projection_arena.allocator(),
        cached_bundle.loaded.document.files[0],
        unstaged_bundle.loaded.document.files[0],
    );

    return .{
        .arena = projection_arena,
        .projection = projection,
        .cached_bundle = cached_bundle,
        .unstaged_bundle = unstaged_bundle,
    };
}
