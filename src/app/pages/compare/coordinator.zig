//! Compare-page input, task, and completion coordination.
//!
//! The controller is a short-lived composition over the retained Compare page
//! and a read-only repository snapshot. It owns task terminals and translates
//! page-local commands into typed clipboard effects without importing App.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const effect_origin = @import("../../effect_origin.zig");
const repo_session = @import("../../repo_session.zig");
const diff_surface = @import("../../diff_surface.zig");
const compare_page = @import("../compare.zig");
const compare_input = @import("input.zig");
const compare_navigation = @import("navigation.zig");

const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const BranchListTask = app_load.CompareBranchListLoadTask(app_message.Msg);

pub const Redraw = enum {
    default,
    skip,
};

/// Clipboard text may borrow the accepted Compare snapshot or own a short
/// allocation. Root consumes the effect synchronously before `deinit`.
pub const ClipboardEffect = struct {
    origin: effect_origin.Origin,
    label: []const u8,
    text: []const u8,
    owned_text: ?[]u8 = null,

    pub fn deinit(self: *ClipboardEffect, allocator: std.mem.Allocator) void {
        if (self.owned_text) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

pub const UpdateOutcome = struct {
    clipboard: ?ClipboardEffect = null,

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
    env_map: ?*std.process.Environ.Map,

    pub fn navigation(self: Controller) compare_navigation.Controller {
        return .{
            .page = self.page_state,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .layout = self.layout,
        };
    }

    pub fn navigationView(self: Controller) compare_navigation.View {
        return .{
            .page = self.page_state,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .layout = self.layout,
        };
    }

    pub fn update(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        msg: compare_input.Msg,
    ) !UpdateOutcome {
        switch (msg) {
            .shared => |shared_msg| {
                const navigation_controller = self.navigation();
                var update_adapter = navigation_controller.updateAdapter();
                var page_update = try update_adapter.shared().apply(ctx.allocator(), shared_msg);
                defer page_update.deinit(ctx.allocator());
                const effect = page_update.takeEffect() orelse return .{};
                return switch (effect) {
                    .copy_diff_selection => |text| .{ .clipboard = self.ownedClipboard("diff selection", text) },
                    .copy_diff_header_path => |selection_value| blk: {
                        const selection = selection_value;
                        defer ctx.allocator().free(selection.identity.path_key);
                        const navigation_view = navigation_controller.view();
                        var content_adapter = navigation_view.resolver();
                        const path = navigation_view.contentView(&content_adapter).diffHeaderPath(selection) orelse break :blk .{};
                        break :blk .{ .clipboard = self.borrowedClipboard("file path", path) };
                    },
                };
            },
            .open_base_picker => try self.startBasePicker(ctx),
            .close_base_picker => self.page_state.closeBasePicker(ctx.allocator()),
            .base_picker_previous => self.page_state.base_picker.moveSelection(-1),
            .base_picker_next => self.page_state.base_picker.moveSelection(1),
            .choose_base => if (try self.page_state.chooseBasePickerTarget(ctx.allocator())) try self.refresh(ctx),
            .copy_current_line => return self.copyCurrentLine(),
            .copy_current_hunk => return try self.copyCurrentHunk(ctx.allocator()),
            .branch_switch_unavailable => self.page_state.status.set("branch switching is not available in Compare", .{}),
        }
        return .{};
    }

    pub fn refresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markNoRepository(ctx.allocator());
            return;
        };
        const anchor = try self.navigationView().captureAnchor(ctx.allocator());
        self.page_state.replaceRefreshAnchor(ctx.allocator(), anchor);
        self.page_state.clearRefreshFailure(ctx.allocator());

        const request = self.page_state.beginRefresh() orelse return;
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
        if (self.page_state.selection_owner.activeMouseSelection() and
            self.page_state.acceptsFinished(self.repo.epoch(), finished))
        {
            self.page_state.replaceDeferredLoad(ctx.allocator(), finished);
            finished.result = .empty;
            return .default;
        }

        const outcome = self.page_state.applyLoadFinished(
            ctx.allocator(),
            self.repo.epoch(),
            self.repo.activeRoot(),
            &finished,
        ) catch |err| {
            self.page_state.failRefresh(ctx.allocator(), .{
                .identity = finished.identity,
                .generation = finished.generation,
            }, self.repo.epoch(), "Could not apply Compare load");
            self.clearRefreshAnchor(ctx.allocator());
            return err;
        };
        if (outcome == .stale) return .skip;
        if (outcome != .loaded) {
            self.clearRefreshAnchor(ctx.allocator());
            return .default;
        }

        const navigation_controller = self.navigation();
        var update_adapter = navigation_controller.updateAdapter();
        var body = update_adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            if (self.page_state.takeRefreshAnchor()) |anchor_value| {
                var anchor = anchor_value;
                defer anchor.deinit(ctx.allocator());
                _ = body.restoreReloadAnchor(loaded, &anchor);
            } else {
                body.controller.syncSidebarNodeToSelectedFile(loaded);
                body.initializeDiffCursorForSelectedFile();
                body.clampDiffNavigation();
                body.refreshSearchForSelectedFile();
            }
            body.controller.rebuildFileSearchProjection(ctx.allocator());
        } else {
            self.clearRefreshAnchor(ctx.allocator());
        }
        return .default;
    }

    pub fn finishBranchList(
        self: Controller,
        allocator: std.mem.Allocator,
        result: app_load.CompareBranchListFinished,
    ) Redraw {
        var finished = result;
        defer finished.deinit(allocator);
        const accepted = self.page_state.base_picker.acceptFinished(
            allocator,
            self.repo.epoch(),
            &self.page_state.activation,
            &finished,
        );
        return if (accepted) .default else .skip;
    }

    pub fn applyDeferred(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !Redraw {
        if (self.page_state.selection_owner.activeMouseSelection()) return .default;
        const deferred = self.page_state.deferred_load_apply orelse return .default;
        self.page_state.deferred_load_apply = null;
        return self.finishLoad(ctx, deferred.finished);
    }

    fn startBasePicker(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const request = self.page_state.beginBasePicker(ctx.allocator()) orelse return;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.base_picker.markFailure(ctx.allocator(), "Compare base picker requires a repository");
            return;
        };
        const task = ctx.allocator().create(BranchListTask) catch |err| {
            self.page_state.base_picker.markFailure(ctx.allocator(), "Could not allocate Compare base list task");
            return err;
        };
        task.* = BranchListTask.init(
            request.identity,
            request.generation,
            capability.*,
            self.env_map,
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.base_picker.markFailure(ctx.allocator(), "Could not prepare Compare base list task");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = BranchListTask.run, .failed = BranchListTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.base_picker.markFailure(ctx.allocator(), "Could not start Compare base list task");
            return err;
        };
    }

    fn copyCurrentLine(self: Controller) UpdateOutcome {
        const navigation_view = self.navigationView();
        var adapter = navigation_view.resolver();
        const text = navigation_view.contentView(&adapter).currentLineCopyText() orelse {
            self.page_state.status.set("no diff line selected", .{});
            return .{};
        };
        return .{ .clipboard = self.borrowedClipboard("current line", text) };
    }

    fn copyCurrentHunk(self: Controller, allocator: std.mem.Allocator) !UpdateOutcome {
        const navigation_view = self.navigationView();
        var adapter = navigation_view.resolver();
        var content = try navigation_view.contentView(&adapter).selectedHunkCopyText(allocator);
        defer content.deinit(allocator);
        switch (content) {
            .ready => |text| {
                content = .no_hunk;
                return .{ .clipboard = self.ownedClipboard("current hunk", text) };
            },
            .no_hunk => self.page_state.status.set("no hunk selected", .{}),
            .no_new_side => self.page_state.status.set("no new-side text in selected hunk", .{}),
        }
        return .{};
    }

    fn clearRefreshAnchor(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page_state.takeRefreshAnchor()) |anchor_value| {
            var anchor = anchor_value;
            anchor.deinit(allocator);
        }
    }

    fn borrowedClipboard(self: Controller, label: []const u8, text: []const u8) ClipboardEffect {
        return .{
            .origin = .{ .page = self.effectOrigin() },
            .label = label,
            .text = text,
        };
    }

    fn ownedClipboard(self: Controller, label: []const u8, text: []u8) ClipboardEffect {
        return .{
            .origin = .{ .page = self.effectOrigin() },
            .label = label,
            .text = text,
            .owned_text = text,
        };
    }

    fn effectOrigin(self: Controller) effect_origin.PageOrigin {
        const identity = self.page_state.activation.currentIdentity();
        return .{
            .page_id = .compare,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repo.epoch(),
            .activation_id = if (identity) |value| value.activation_id else self.page_state.activation.next_activation_id,
        };
    }
};
