//! Compare input, task, and completion coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const repo_session = @import("../../repo_session.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const effect_origin = @import("../../effect_origin.zig");
const compare_page = @import("../compare.zig");
const compare_input = @import("input.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");
const committed_diff_coordinator = @import("../committed_diff/coordinator.zig");

const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const BranchListTask = app_load.CompareBranchListLoadTask(app_message.Msg);

pub const Redraw = diff_surface.update.Redraw;
pub const DeferredApply = enum { none, visible, discarded };
pub const ClipboardEffect = committed_diff_coordinator.ClipboardEffect;
pub const UpdateOutcome = struct {
    clipboard: ?ClipboardEffect = null,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,
    redraw: Redraw = .default,

    pub fn deinit(self: *UpdateOutcome, allocator: std.mem.Allocator) void {
        if (self.clipboard) |*effect| effect.deinit(allocator);
        self.* = .{};
    }

    pub fn takeClipboard(self: *UpdateOutcome) ?ClipboardEffect {
        const effect = self.clipboard;
        self.clipboard = null;
        return effect;
    }
};

pub const Controller = struct {
    page_state: *compare_page.ComparePageState,
    repo: repo_session.View,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    env_map: ?*std.process.Environ.Map,

    pub fn navigation(self: Controller) committed_diff_navigation.Controller {
        return .{
            .diff = &self.page_state.diff,
            .activation = &self.page_state.activation,
            .status = &self.page_state.status,
            .current_target = self.page_state.currentTarget(),
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .source = compare_page.selection_source,
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
            .live_drag_deferred_source = self.page_state.deferred_load_apply != null,
        };
    }

    pub fn navigationView(self: Controller) committed_diff_navigation.View {
        return self.navigation().view();
    }

    pub fn update(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        msg: compare_input.Msg,
    ) !UpdateOutcome {
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
            .open_base_picker => try self.startBasePicker(ctx),
            .close_base_picker => self.page_state.closeBasePicker(ctx.allocator()),
            .base_picker_enter_query => self.page_state.base_picker.enterQuery(),
            .base_picker_leave_query => self.page_state.base_picker.leaveQuery(),
            .base_picker_clear_query => self.page_state.base_picker.clearQuery(ctx.allocator()) catch
                self.page_state.status.set("Could not clear Compare base search", .{}),
            .base_picker_insert => |codepoint| self.page_state.base_picker.insertQuery(ctx.allocator(), codepoint) catch
                self.page_state.status.set("Could not update Compare base search", .{}),
            .base_picker_backspace => self.page_state.base_picker.backspaceQuery(ctx.allocator()) catch
                self.page_state.status.set("Could not update Compare base search", .{}),
            .base_picker_previous => self.page_state.base_picker.moveSelection(-1),
            .base_picker_next => self.page_state.base_picker.moveSelection(1),
            .choose_base => if (try self.page_state.chooseBasePickerTarget(ctx.allocator())) try self.refresh(ctx),
        }
        return .{};
    }

    pub fn branchSwitchFinished(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        self.page_state.diff.selection_owner = .none;
        if (self.page_state.deferred_load_apply) |*deferred| deferred.deinit(ctx.allocator());
        self.page_state.deferred_load_apply = null;
        try self.refresh(ctx);
    }

    pub fn refresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markNoRepository(ctx.allocator());
            return;
        };
        // Retire the old generation before fallible preparation, so a late
        // result cannot restore the comparison from before checkout.
        const request = self.page_state.beginRefresh() orelse return;
        const anchor = self.navigationView().captureAnchor(ctx.allocator()) catch |err| {
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not retain Compare viewport");
            return err;
        };
        self.page_state.diff.replaceReloadAnchor(ctx.allocator(), anchor);
        self.page_state.clearRefreshFailure(ctx.allocator());

        const task = ctx.allocator().create(CompareLoadTask) catch |err| {
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not allocate Compare load task");
            return err;
        };
        task.* = CompareLoadTask.init(
            request.identity,
            request.generation,
            capability.*,
            self.page_state.base_target,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not prepare Compare load task");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = CompareLoadTask.run, .failed = CompareLoadTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not start Compare load task");
            return err;
        };
    }

    pub fn finishLoad(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: app_load.CompareLoadFinished,
    ) !Redraw {
        var finished = result;
        defer finished.deinit(ctx.allocator());
        const visible = self.page_state.activation.currentIdentity() != null;
        if (self.page_state.diff.selection_owner.activeMouseSelection() and
            self.page_state.acceptsFinished(self.repo.epoch(), finished))
        {
            self.page_state.replaceDeferredLoad(ctx.allocator(), finished);
            finished.result = .empty;
            return if (visible) .default else .skip;
        }

        if (self.page_state.acceptsFinished(self.repo.epoch(), finished)) {
            if (self.page_state.diff.reload_anchor) |*anchor| {
                const view = self.navigationView();
                var resolver = view.resolver();
                anchor.selection_viewport = view.bodyView(&resolver).captureSelectionViewportAnchor();
            }
        }
        const outcome = self.page_state.applyLoadFinished(
            ctx.allocator(),
            self.repo.epoch(),
            self.repo.activeRoot(),
            self.repo.activeIdentity(),
            &finished,
        ) catch |err| {
            self.page_state.failRefresh(ctx.allocator(), .{
                .identity = finished.identity,
                .generation = finished.generation,
            }, self.repo.epoch(), "Could not apply Compare load");
            self.page_state.diff.clearReloadAnchor(ctx.allocator());
            return err;
        };
        if (outcome == .stale) return .skip;
        if (outcome != .loaded) {
            self.page_state.diff.clearReloadAnchor(ctx.allocator());
            return if (visible) .default else .skip;
        }

        var adapter = self.navigation().updateAdapter();
        const cleanup = adapter.selectionMappingCleanup(ctx.allocator());
        const body = adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            if (self.page_state.diff.takeReloadAnchor()) |anchor_value| {
                var anchor = anchor_value;
                defer anchor.deinit(ctx.allocator());
                _ = body.restoreReloadAnchor(cleanup, loaded, &anchor);
            } else {
                body.controller.syncSidebarNodeToSelectedFile(loaded);
                body.initializeDiffCursorForSelectedFile();
                body.clampDiffNavigation();
                body.refreshSearchForSelectedFile(cleanup);
            }
            body.controller.rebuildFileSearchProjection(ctx.allocator());
        } else {
            self.page_state.diff.clearReloadAnchor(ctx.allocator());
        }
        return if (visible) .default else .skip;
    }

    pub fn finishBranchList(
        self: Controller,
        allocator: std.mem.Allocator,
        result: app_load.CompareBranchListFinished,
    ) Redraw {
        var finished = result;
        defer finished.deinit(allocator);
        const visible = self.page_state.activation.currentIdentity() != null;
        const accepted = self.page_state.base_picker.acceptFinished(
            allocator,
            self.repo.epoch(),
            &self.page_state.activation,
            &finished,
        );
        return if (accepted and visible) .default else .skip;
    }

    pub fn applyDeferred(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !DeferredApply {
        if (self.page_state.diff.selection_owner.activeMouseSelection()) return .none;
        const deferred = self.page_state.deferred_load_apply orelse return .none;
        self.page_state.deferred_load_apply = null;
        return switch (try self.finishLoad(ctx, deferred.finished)) {
            .default => .visible,
            .skip => .discarded,
        };
    }

    pub fn prepareModalRedraw(self: Controller, io: std.Io) void {
        self.page_state.base_picker.prepareModalRedraw(io);
    }

    fn startBasePicker(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const request = self.page_state.beginBasePicker(ctx.allocator()) orelse return;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Compare base picker requires a repository");
            return;
        };
        const task = ctx.allocator().create(BranchListTask) catch |err| {
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Could not allocate Compare base list task");
            return err;
        };
        task.* = BranchListTask.init(
            request.identity,
            request.generation,
            capability.*,
            self.env_map,
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Could not prepare Compare base list task");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = BranchListTask.run, .failed = BranchListTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Could not start Compare base list task");
            return err;
        };
    }

    fn commonCoordinator(self: Controller) committed_diff_coordinator.Controller {
        return .{
            .navigation = self.navigation(),
            .effect_origin = self.pageOrigin(),
        };
    }

    fn pageOrigin(self: Controller) effect_origin.PageOrigin {
        const identity = self.page_state.activation.currentIdentity();
        return .{
            .page_id = .compare,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repo.epoch(),
            .activation_id = if (identity) |value| value.activation_id else self.page_state.activation.next_activation_id,
        };
    }
};
