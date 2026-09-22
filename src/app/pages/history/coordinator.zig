//! History catalog, committed-diff task, and shared-surface coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const app_page = @import("../../page.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const effect_origin = @import("../../effect_origin.zig");
const repo_session = @import("../../repo_session.zig");
const history_page = @import("../history.zig");
const history_view = @import("view.zig");
const committed_diff_coordinator = @import("../committed_diff/coordinator.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");

const CatalogTask = app_load.HistoryCatalogTask(app_message.Msg);
const DiffTask = app_load.HistoryDiffTask(app_message.Msg);
const PreviewDebounceTask = app_load.HistoryPreviewDebounceTask(app_message.Msg);
const PreviewReadTask = app_load.HistoryPreviewReadTask(app_message.Msg);

pub const UpdateOutcome = struct {
    clipboard: ?committed_diff_coordinator.ClipboardEffect = null,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,
    redraw: diff_surface.update.Redraw = .default,

    pub fn deinit(self: *UpdateOutcome, allocator: std.mem.Allocator) void {
        if (self.clipboard) |*effect| effect.deinit(allocator);
        self.* = .{};
    }

    pub fn takeClipboard(self: *UpdateOutcome) ?committed_diff_coordinator.ClipboardEffect {
        const effect = self.clipboard;
        self.clipboard = null;
        return effect;
    }
};

pub const Controller = struct {
    page_state: *history_page.HistoryPageState,
    active_page: app_page.Id,
    repo: repo_session.View,
    body_size: chasen.Size,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    env_map: ?*const std.process.Environ.Map,

    pub fn refresh(self: Controller, allocator: std.mem.Allocator) void {
        self.page_state.requestReload(allocator);
    }

    pub fn navigation(self: Controller) committed_diff_navigation.Controller {
        return .{
            .diff = &self.page_state.diff,
            .activation = &self.page_state.activation,
            .status = &self.page_state.status,
            .current_target = null,
            .presentation_identity = self.page_state.currentPresentationIdentity(),
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = history_page.selection_source,
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .live_drag_deferred_source = false,
        };
    }

    pub fn navigationView(self: Controller) committed_diff_navigation.View {
        return self.navigation().view();
    }

    pub fn update(self: Controller, ctx: *chasen.Ctx(app_message.Msg), msg: history_page.Msg) !UpdateOutcome {
        switch (msg) {
            .common => |common| {
                var outcome = try self.commonCoordinator().update(ctx.allocator(), common);
                defer outcome.deinit(ctx.allocator());
                return .{
                    .clipboard = outcome.takeClipboard(),
                    .auto_scroll = outcome.auto_scroll,
                    .redraw = outcome.redraw,
                };
            },
            .load_diff => try self.startDiff(ctx),
            .open_picker => self.page_state.openPicker(ctx.allocator()),
            .focus_next => self.page_state.interaction_state.focusNext(),
            .focus_previous => self.page_state.interaction_state.focusPrevious(),
            .move_detail => |action| try history_view.moveDetail(
                self.page_state,
                ctx.allocator(),
                self.body_size,
                action,
            ),
            .move_files => |action| history_view.moveFiles(self.page_state, self.body_size, action),
            .scroll_files => |action| try history_view.scrollFiles(
                self.page_state,
                ctx.allocator(),
                self.body_size,
                action,
            ),
            .adjust_width => |action| {
                self.page_state.interaction_state.adjustWidth(self.body_size.width, action);
                try history_view.reflowPreview(self.page_state, ctx.allocator(), self.body_size);
            },
            else => self.page_state.applyInput(msg, self.body_size.height),
        }
        return .{};
    }

    pub fn finishCatalog(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: *app_load.HistoryCatalogFinished,
    ) !history_page.ApplyOutcome {
        const identity = self.currentIdentity() orelse return .discarded;
        const outcome = try self.page_state.applyFinished(
            allocator,
            identity,
            self.repo.activeIdentity(),
            finished,
        );
        if (outcome == .changed) {
            self.page_state.catalog.clamp(@import("catalog.zig").visibleRows(self.body_size.height));
        }
        return outcome;
    }

    pub fn finishDiff(
        self: Controller,
        allocator: std.mem.Allocator,
        finished: *app_load.HistoryDiffFinished,
    ) !history_page.ApplyOutcome {
        const identity = self.currentIdentity() orelse return .discarded;
        const previous_view = self.navigationView();
        var previous_resolver = previous_view.resolver();
        const transferred_viewport = previous_view.bodyView(&previous_resolver).captureSelectionViewportAnchor();
        const outcome = try self.page_state.applyDiffFinished(
            allocator,
            self.repo.activeRoot(),
            identity,
            self.repo.activeIdentity(),
            finished,
        );
        if (outcome == .changed) self.commonCoordinator().initializeAcceptedBody(allocator, transferred_viewport);
        return outcome;
    }

    /// Queue the current selection and start the preview debounce task when the
    /// state machine requests one.
    pub fn requestPreview(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !?history_page.preview.QueueOutcome {
        if (self.active_page != .history) return null;
        const outcome = self.page_state.queueCurrentPreview(ctx.allocator()) orelse return null;
        if (outcome == .start_debounce) try self.startPreviewDebounce(ctx);
        return outcome;
    }

    pub fn finishPreview(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        finished: *app_load.HistoryPreviewFinished,
    ) !history_page.ApplyOutcome {
        return switch (finished.*) {
            .debounce => |debounce| switch (self.page_state.preview_state.finishDebounce(
                debounce.stamp,
                debounce.result,
            )) {
                .discarded => .discarded,
                .settled => .failed,
                .start_debounce => blk: {
                    try self.startPreviewDebounce(ctx);
                    break :blk .changed;
                },
                .start_reader => |latest| blk: {
                    try self.startPreviewReader(ctx, latest);
                    break :blk .changed;
                },
            },
            .read => |*read| switch (self.page_state.preview_state.finishReader(
                ctx.allocator(),
                read.key,
                &read.result,
            )) {
                .discarded => .discarded,
                .settled => .changed,
                .start_debounce => blk: {
                    try self.startPreviewDebounce(ctx);
                    break :blk .changed;
                },
            },
        };
    }

    pub fn startPending(self: Controller, ctx: *chasen.Ctx(@import("../../message.zig").Msg)) !bool {
        if (self.active_page != .history) return false;
        const request = self.page_state.nextRequest() orelse return false;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.rejectPreparation();
            return true;
        };
        const root_identity = self.repo.activeIdentity() orelse {
            self.page_state.rejectPreparation();
            return true;
        };
        const identity = self.currentIdentity() orelse {
            self.page_state.rejectPreparation();
            return true;
        };
        const generation = self.page_state.reserveGeneration();
        const task = try ctx.allocator().create(CatalogTask);
        task.* = CatalogTask.init(
            identity,
            generation,
            capability,
            request,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.rejectPreparation();
            return err;
        };
        self.page_state.armCatalog(.{
            .identity = identity,
            .root_identity = root_identity,
            .generation = generation,
            .request = request,
        });
        ctx.task().spawnWith(.{ .ctx = task, .run = CatalogTask.run, .failed = CatalogTask.failed }) catch |err| {
            CatalogTask.destroy(task, ctx.allocator());
            self.page_state.rejectSpawn(generation);
            return err;
        };
        return true;
    }

    pub fn reflowPreview(self: Controller, allocator: std.mem.Allocator) !void {
        try history_view.reflowPreview(self.page_state, allocator, self.body_size);
    }

    fn startDiff(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .history) return;
        const request = self.page_state.beginDiffRequest() orelse return;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.rejectDiffPreparation("History diff requires a repository");
            return;
        };
        const root_identity = self.repo.activeIdentity() orelse {
            self.page_state.rejectDiffPreparation("History diff requires a repository");
            return;
        };
        const identity = self.currentIdentity() orelse {
            self.page_state.rejectDiffPreparation("History diff is no longer active");
            return;
        };
        const generation = self.page_state.reserveGeneration();
        const task = ctx.allocator().create(DiffTask) catch |err| {
            self.page_state.rejectDiffPreparation("History diff task could not be allocated");
            return err;
        };
        task.* = DiffTask.init(
            identity,
            generation,
            capability,
            request,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.rejectDiffPreparation("History diff task could not be prepared");
            return err;
        };
        self.page_state.armDiff(.{
            .identity = identity,
            .root_identity = root_identity,
            .generation = generation,
            .request = request,
        });
        ctx.task().spawnWith(.{ .ctx = task, .run = DiffTask.run, .failed = DiffTask.failed }) catch |err| {
            DiffTask.destroy(task, ctx.allocator());
            self.page_state.rejectDiffSpawn(generation, "History diff task could not be started");
            return err;
        };
    }

    fn startPreviewDebounce(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const stamp = self.page_state.preview_state.reserveDebounce() orelse return;
        const task = ctx.allocator().create(PreviewDebounceTask) catch |err| {
            self.page_state.preview_state.rejectDebouncePreparation(stamp, .allocation);
            return err;
        };
        task.* = .{ .stamp = stamp };
        self.page_state.preview_state.armDebounce(stamp);
        ctx.task().spawnWith(.{
            .ctx = task,
            .run = PreviewDebounceTask.run,
            .failed = PreviewDebounceTask.failed,
        }) catch |err| {
            PreviewDebounceTask.destroy(task, ctx.allocator());
            self.page_state.preview_state.rejectDebounceStart(stamp, .task_start);
            return err;
        };
    }

    fn startPreviewReader(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        latest: history_page.preview.LatestRequest,
    ) !void {
        self.page_state.preview_state.armReader(latest.key);
        const capability = self.repo.activeCapability() orelse {
            self.page_state.preview_state.rejectReaderStart(latest.key, .task_start);
            return;
        };
        if (!capability.identity.eql(latest.key.identity.root)) {
            self.page_state.preview_state.rejectReaderStart(latest.key, .task_start);
            return;
        }
        const task = ctx.allocator().create(PreviewReadTask) catch |err| {
            self.page_state.preview_state.rejectReaderStart(latest.key, .allocation);
            return err;
        };
        task.* = PreviewReadTask.init(
            latest.key,
            latest.request,
            capability,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.preview_state.rejectReaderStart(
                latest.key,
                if (err == error.OutOfMemory) .allocation else .task_start,
            );
            return err;
        };
        ctx.task().spawnWith(.{
            .ctx = task,
            .run = PreviewReadTask.run,
            .failed = PreviewReadTask.failed,
        }) catch |err| {
            PreviewReadTask.destroy(task, ctx.allocator());
            self.page_state.preview_state.rejectReaderStart(latest.key, .task_start);
            return err;
        };
    }

    fn commonCoordinator(self: Controller) committed_diff_coordinator.Controller {
        return .{
            .navigation = self.navigation(),
            .effect_origin = self.pageOrigin(),
            .branch_unavailable_message = "branch switching is not available in History",
        };
    }

    fn currentIdentity(self: Controller) ?app_page.RequestIdentity {
        return self.page_state.activation.currentIdentity();
    }

    fn pageOrigin(self: Controller) effect_origin.PageOrigin {
        const identity = self.page_state.activation.currentIdentity();
        return .{
            .page_id = .history,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repo.epoch(),
            .activation_id = if (identity) |value| value.activation_id else self.page_state.activation.next_activation_id,
        };
    }
};
