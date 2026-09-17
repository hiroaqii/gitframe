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
const committed_diff_coordinator = @import("../committed_diff/coordinator.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");

const CatalogTask = app_load.HistoryCatalogTask(app_message.Msg);
const DiffTask = app_load.HistoryDiffTask(app_message.Msg);

pub const UpdateOutcome = struct {
    clipboard: ?committed_diff_coordinator.ClipboardEffect = null,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,

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
                };
            },
            .load_diff => try self.startDiff(ctx),
            .open_picker => self.page_state.openPicker(ctx.allocator()),
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
        const outcome = try self.page_state.applyDiffFinished(
            allocator,
            self.repo.activeRoot(),
            identity,
            self.repo.activeIdentity(),
            finished,
        );
        if (outcome == .changed) self.commonCoordinator().initializeAcceptedBody(allocator);
        return outcome;
    }

    pub fn startPending(self: Controller, ctx: *chasen.Ctx(@import("../../message.zig").Msg)) !void {
        if (self.active_page != .history) return;
        const request = self.page_state.nextRequest() orelse return;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.rejectPreparation();
            return;
        };
        const root_identity = self.repo.activeIdentity() orelse {
            self.page_state.rejectPreparation();
            return;
        };
        const identity = self.currentIdentity() orelse {
            self.page_state.rejectPreparation();
            return;
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
