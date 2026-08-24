//! Review-page input, task, and completion coordination.
//!
//! The controller is a short-lived composition over the retained Review page
//! and a read-only repository snapshot. It owns task terminals and translates
//! page-local commands into typed clipboard effects without importing App.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const diff_basis = @import("../../diff_basis.zig");
const effect_origin = @import("../../effect_origin.zig");
const page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const diff_selection = @import("../../../diff/selection.zig");
const review_page = @import("../review.zig");
const review_input = @import("input.zig");
const review_navigation = @import("navigation.zig");
const review_store = @import("../../../review_store.zig");

const ReviewLoadTask = app_load.ReviewLoadTask(app_message.Msg);
const BranchListTask = app_load.ReviewBranchListLoadTask(app_message.Msg);
const HistoryScanTask = app_load.ReviewHistoryScanTask(app_message.Msg);
const HistorySelectionTask = app_load.ReviewHistorySelectionTask(app_message.Msg);
const HistoryNormalReturnTask = app_load.ReviewHistoryNormalReturnTask(app_message.Msg);

pub const Redraw = enum {
    default,
    skip,
};

/// Clipboard text may borrow the accepted Review snapshot or own a short
/// allocation. Root consumes the effect synchronously before `deinit`.
pub const ClipboardEffect = struct {
    origin: effect_origin.Origin,
    label: []const u8,
    text: []const u8,
    owned_text: ?[]u8 = null,
    selection_generation: ?u64 = null,

    pub fn deinit(self: *ClipboardEffect, allocator: std.mem.Allocator) void {
        if (self.owned_text) |owned| allocator.free(owned);
        self.* = undefined;
    }
};

pub const UpdateOutcome = struct {
    clipboard: ?ClipboardEffect = null,
    auto_scroll: ?drag_auto_scroll.StepOutcome = null,

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
    page_state: *review_page.ReviewPageState,
    repo: repo_session.View,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    env_map: ?*std.process.Environ.Map,
    store: ?*const review_store.ConfiguredStore = null,

    pub fn navigation(self: Controller) review_navigation.Controller {
        return .{
            .page = self.page_state,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
        };
    }

    pub fn navigationView(self: Controller) review_navigation.View {
        return .{
            .page = self.page_state,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
        };
    }

    pub fn update(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        msg: review_input.Msg,
    ) !UpdateOutcome {
        switch (msg) {
            .shared => |shared_msg| {
                const navigation_controller = self.navigation();
                var update_adapter = navigation_controller.updateAdapter();
                var page_update = try update_adapter.shared().apply(ctx.allocator(), shared_msg);
                defer page_update.deinit(ctx.allocator());
                update_adapter.applyRetentionTransition(ctx.allocator(), page_update.retention_transition);
                const auto_scroll = page_update.auto_scroll;
                const effect = page_update.takeEffect() orelse return .{ .auto_scroll = auto_scroll };
                return switch (effect) {
                    .copy_diff_selection => |copy| .{
                        .clipboard = self.ownedSelectionClipboard("diff selection", copy),
                        .auto_scroll = auto_scroll,
                    },
                    .copy_diff_header_path => |selection_value| blk: {
                        const selection = selection_value;
                        defer ctx.allocator().free(selection.identity.path_key);
                        const navigation_view = navigation_controller.view();
                        var content_adapter = navigation_view.resolver();
                        const path = navigation_view.contentView(&content_adapter).diffHeaderPath(selection) orelse break :blk .{};
                        break :blk .{
                            .clipboard = self.borrowedClipboard("file path", path),
                            .auto_scroll = auto_scroll,
                        };
                    },
                };
            },
            .open_base_picker => try self.startBasePicker(ctx),
            .close_base_picker => self.page_state.closeBasePicker(ctx.allocator()),
            .base_picker_enter_query => self.page_state.base_picker.enterQuery(),
            .base_picker_leave_query => self.page_state.base_picker.leaveQuery(),
            .base_picker_clear_query => self.page_state.base_picker.clearQuery(ctx.allocator()) catch
                self.page_state.status.set("Could not clear Review base search", .{}),
            .base_picker_insert => |codepoint| self.page_state.base_picker.insertQuery(ctx.allocator(), codepoint) catch
                self.page_state.status.set("Could not update Review base search", .{}),
            .base_picker_backspace => self.page_state.base_picker.backspaceQuery(ctx.allocator()) catch
                self.page_state.status.set("Could not update Review base search", .{}),
            .base_picker_previous => self.page_state.base_picker.moveSelection(-1),
            .base_picker_next => self.page_state.base_picker.moveSelection(1),
            .choose_base => if (try self.page_state.chooseBasePickerTarget(ctx.allocator())) try self.refresh(ctx),
            .open_ai_reviews => try self.startHistoryScan(ctx, false),
            .close_ai_reviews => self.page_state.ai_reviews.close(ctx.allocator()),
            .ai_reviews_cancel_loading => self.page_state.ai_reviews.cancelLoading(ctx.allocator()),
            .ai_reviews_enter_query => self.page_state.ai_reviews.enterQuery(),
            .ai_reviews_leave_query => self.page_state.ai_reviews.leaveQuery(),
            .ai_reviews_clear_query_or_leave => self.page_state.ai_reviews.clearQueryOrLeave(ctx.allocator()) catch
                self.page_state.status.set("Could not update AI review filter", .{}),
            .ai_reviews_insert => |codepoint| self.page_state.ai_reviews.insertQuery(ctx.allocator(), codepoint) catch
                self.page_state.status.set("Could not update AI review filter", .{}),
            .ai_reviews_backspace => self.page_state.ai_reviews.backspaceQuery(ctx.allocator()) catch
                self.page_state.status.set("Could not update AI review filter", .{}),
            .ai_reviews_previous => self.page_state.ai_reviews.moveSelection(-1),
            .ai_reviews_next => self.page_state.ai_reviews.moveSelection(1),
            .ai_reviews_activate => try self.activateAiReviewSelection(ctx),
            .ai_reviews_refresh_or_retry => try self.retryAiReviews(ctx),
            .return_to_normal_review => try self.startNormalReturn(ctx, true),
            .copy_current_line => return self.copyCurrentLine(),
            .copy_current_hunk => return try self.copyCurrentHunk(ctx.allocator()),
            .branch_switch_unavailable => self.page_state.status.set("branch switching is not available in Review", .{}),
        }
        return .{};
    }

    pub fn refresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.page_state.isPinnedAi()) return self.startPinnedRefresh(ctx);
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markNoRepository(ctx.allocator());
            return;
        };
        const anchor = try self.navigationView().captureAnchor(ctx.allocator());
        self.page_state.replaceRefreshAnchor(ctx.allocator(), anchor);
        self.page_state.clearRefreshFailure(ctx.allocator());

        const request = self.page_state.beginRefresh() orelse return;
        const task = ctx.allocator().create(ReviewLoadTask) catch |err| {
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not allocate Review load task");
            return err;
        };
        task.* = ReviewLoadTask.init(
            request.identity,
            request.generation,
            capability.*,
            self.page_state.base_target,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not prepare Review load task");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = ReviewLoadTask.run, .failed = ReviewLoadTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.failRefresh(ctx.allocator(), request, self.repo.epoch(), "Could not start Review load task");
            return err;
        };
    }

    pub fn finishLoad(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: app_load.ReviewLoadFinished,
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

        if (self.page_state.acceptsFinished(self.repo.epoch(), finished)) {
            if (self.page_state.refresh_anchor) |*anchor| {
                const navigation_view = self.navigationView();
                var resolver = navigation_view.resolver();
                anchor.selection_viewport = navigation_view.bodyView(&resolver).captureSelectionViewportAnchor();
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
            }, self.repo.epoch(), "Could not apply Review load");
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
        result: app_load.ReviewBranchListFinished,
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

    pub fn finishHistoryScan(
        self: Controller,
        allocator: std.mem.Allocator,
        result: app_load.ReviewHistoryScanFinished,
    ) Redraw {
        var finished = result;
        defer finished.deinit(allocator);
        const store = self.configuredStore() orelse return .skip;
        const accepted = self.page_state.ai_reviews.acceptScan(
            allocator,
            self.repo.epoch(),
            self.repo.activeIdentity(),
            store.identity(),
            &self.page_state.activation,
            &finished,
        );
        return if (accepted) .default else .skip;
    }

    pub fn finishHistorySelection(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: app_load.ReviewHistorySelectionFinished,
    ) !Redraw {
        var finished = result;
        defer finished.deinit(ctx.allocator());
        const store = self.configuredStore() orelse return .skip;
        if (!self.page_state.ai_reviews.acceptsSelection(
            self.repo.epoch(),
            self.repo.activeIdentity(),
            store.identity(),
            &self.page_state.activation,
            finished,
        )) return .skip;

        switch (finished.result) {
            .loaded => |*bundle| {
                self.page_state.commitPinnedAi(
                    ctx.allocator(),
                    self.repo.epoch(),
                    self.repo.activeRoot(),
                    self.repo.activeIdentity(),
                    bundle,
                ) catch |err| {
                    self.page_state.ai_reviews.failSelectionStatic(finished.review_id, "Could not apply AI review");
                    return err;
                };
                finished.result = .empty;
                self.page_state.ai_reviews.close(ctx.allocator());
                self.initializeAcceptedBody(ctx.allocator());
            },
            .selection_failed => |failure| self.page_state.ai_reviews.failSelection(finished.review_id, failure),
            .failed_static => |message| self.page_state.ai_reviews.failSelectionStatic(finished.review_id, message),
            .empty => self.page_state.ai_reviews.failSelectionStatic(finished.review_id, "Could not load AI review"),
        }
        return .default;
    }

    pub fn finishHistoryNormalReturn(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: app_load.ReviewHistoryNormalReturnFinished,
    ) !Redraw {
        var finished = result;
        defer finished.deinit(ctx.allocator());
        const store = self.configuredStore() orelse return .skip;
        if (!self.page_state.ai_reviews.acceptsNormalReturn(
            self.repo.epoch(),
            self.repo.activeIdentity(),
            store.identity(),
            &self.page_state.activation,
            finished,
        )) return .skip;

        switch (finished.result) {
            .loaded => |*bundle| {
                self.page_state.commitNormalReturn(
                    ctx.allocator(),
                    self.repo.epoch(),
                    self.repo.activeRoot(),
                    self.repo.activeIdentity(),
                    bundle,
                ) catch |err| {
                    self.page_state.ai_reviews.failNormalReturn("Could not apply normal Review");
                    return err;
                };
                finished.result = .empty;
                self.page_state.ai_reviews.close(ctx.allocator());
                self.initializeAcceptedBody(ctx.allocator());
            },
            .basis_failed => self.page_state.ai_reviews.failNormalReturn("Could not return to normal Review: base unavailable"),
            .failed => |message| self.page_state.ai_reviews.failNormalReturn(message),
            .failed_static => |message| self.page_state.ai_reviews.failNormalReturn(message),
            .empty => self.page_state.ai_reviews.failNormalReturn("Could not return to normal Review"),
        }
        return .default;
    }

    pub fn applyDeferred(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !Redraw {
        if (self.page_state.selection_owner.activeMouseSelection()) return .default;
        const deferred = self.page_state.deferred_load_apply orelse return .default;
        self.page_state.deferred_load_apply = null;
        return self.finishLoad(ctx, deferred.finished);
    }

    pub fn prepareModalRedraw(self: Controller, io: std.Io) void {
        self.page_state.base_picker.prepareModalRedraw(io);
        self.page_state.ai_reviews.prepareModalRedraw(io);
    }

    fn startHistoryScan(self: Controller, ctx: *chasen.Ctx(app_message.Msg), retain_query: bool) !void {
        const identity = self.page_state.activation.currentIdentity() orelse return;
        const root_identity = self.repo.activeIdentity() orelse {
            self.page_state.status.set("AI reviews require a repository", .{});
            return;
        };
        const preferred = if (retain_query)
            if (self.page_state.ai_reviews.selectedRow()) |row| row.review_id else self.page_state.activeAiReviewId()
        else
            self.page_state.activeAiReviewId();
        const request = self.page_state.ai_reviews.beginScan(
            ctx.allocator(),
            identity,
            root_identity,
            preferred,
            retain_query,
        );
        const store = self.configuredStore() orelse {
            self.page_state.ai_reviews.markScanFailure("Could not load AI reviews: Store unavailable");
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.ai_reviews.markScanFailure("Could not load AI reviews: repository unavailable");
            return;
        };
        const task = ctx.allocator().create(HistoryScanTask) catch |err| {
            self.page_state.ai_reviews.markScanFailure("Could not allocate AI review scan");
            return err;
        };
        task.* = HistoryScanTask.init(
            request.identity,
            request.generation,
            store,
            capability.*,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.ai_reviews.markScanFailure("Could not prepare AI review scan");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = HistoryScanTask.run, .failed = HistoryScanTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.ai_reviews.markScanFailure("Could not start AI review scan");
            return err;
        };
    }

    fn activateAiReviewSelection(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.page_state.ai_reviews.selectedIsNormal()) {
            if (!self.page_state.isPinnedAi()) {
                self.page_state.ai_reviews.close(ctx.allocator());
                return;
            }
            return self.startNormalReturn(ctx, false);
        }
        switch (self.page_state.ai_reviews.beginSelectedRun()) {
            .none => {},
            .unavailable => self.page_state.status.set("Review target unavailable; restore objects and press r", .{}),
            .request => |request| try self.spawnSelection(ctx, request),
        }
    }

    fn startPinnedRefresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const pinned = self.page_state.pinnedAi() orelse return;
        const identity = self.page_state.activation.currentIdentity() orelse return;
        const root_identity = self.repo.activeIdentity() orelse return;
        const request = self.page_state.ai_reviews.beginDirectSelection(
            ctx.allocator(),
            identity,
            root_identity,
            pinned.selection.snapshot,
            pinned.reviewId(),
            review_store.ArtifactSnapshot.fromLoaded(&pinned.selection.artifacts),
        );
        try self.spawnSelection(ctx, request);
    }

    fn spawnSelection(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        request: review_page.AiReviewSelectionRequest,
    ) !void {
        const store = self.configuredStore() orelse {
            self.page_state.ai_reviews.failSelectionStatic(request.review_id, "Could not load AI review: Store unavailable");
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.ai_reviews.failSelectionStatic(request.review_id, "Could not load AI review: repository unavailable");
            return;
        };
        const task = ctx.allocator().create(HistorySelectionTask) catch |err| {
            self.page_state.ai_reviews.failSelectionStatic(request.review_id, "Could not allocate AI review load");
            return err;
        };
        task.* = HistorySelectionTask.init(
            request.request.identity,
            request.request.generation,
            store,
            capability.*,
            self.env_map,
            request.store,
            request.review_id,
            request.artifacts,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.ai_reviews.failSelectionStatic(request.review_id, "Could not prepare AI review load");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = HistorySelectionTask.run, .failed = HistorySelectionTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.ai_reviews.failSelectionStatic(request.review_id, "Could not start AI review load");
            return err;
        };
    }

    fn startNormalReturn(self: Controller, ctx: *chasen.Ctx(app_message.Msg), direct: bool) !void {
        if (!self.page_state.isPinnedAi()) {
            if (!direct) self.page_state.ai_reviews.close(ctx.allocator());
            if (direct) try self.startBasePicker(ctx);
            return;
        }
        const identity = self.page_state.activation.currentIdentity() orelse return;
        const root_identity = self.repo.activeIdentity() orelse return;
        const request = if (direct)
            self.page_state.ai_reviews.beginDirectNormalReturn(ctx.allocator(), identity, root_identity)
        else
            self.page_state.ai_reviews.beginNormalReturn(false) orelse return;
        const store = self.configuredStore() orelse {
            self.page_state.ai_reviews.failNormalReturn("Could not return to normal Review: Store unavailable");
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.ai_reviews.failNormalReturn("Could not return to normal Review: repository unavailable");
            return;
        };
        const task = ctx.allocator().create(HistoryNormalReturnTask) catch |err| {
            self.page_state.ai_reviews.failNormalReturn("Could not allocate normal Review load");
            return err;
        };
        task.* = HistoryNormalReturnTask.init(
            request.identity,
            request.generation,
            store,
            capability.*,
            self.page_state.base_target,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.ai_reviews.failNormalReturn("Could not prepare normal Review load");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = HistoryNormalReturnTask.run, .failed = HistoryNormalReturnTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.ai_reviews.failNormalReturn("Could not start normal Review load");
            return err;
        };
    }

    fn retryAiReviews(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        switch (self.page_state.ai_reviews.phase) {
            .scan_loading => try self.startHistoryScan(ctx, true),
            .selection_loading => |loading| {
                if (loading.direct) return self.startPinnedRefresh(ctx);
                switch (self.page_state.ai_reviews.retrySelectedRun()) {
                    .request => |request| try self.spawnSelection(ctx, request),
                    .unavailable => self.page_state.status.set("Review target unavailable; restore objects and press r", .{}),
                    .none => try self.startHistoryScan(ctx, true),
                }
            },
            .return_loading => |loading| try self.startNormalReturn(ctx, loading.direct),
            .ready, .empty, .scan_failed => try self.startHistoryScan(ctx, true),
            .selection_failed => |failure| {
                if (failure.direct) return self.startPinnedRefresh(ctx);
                try self.startHistoryScan(ctx, true);
            },
            .return_failed => |failure| try self.startNormalReturn(ctx, failure.direct),
            else => {},
        }
    }

    fn initializeAcceptedBody(self: Controller, allocator: std.mem.Allocator) void {
        const navigation_controller = self.navigation();
        var update_adapter = navigation_controller.updateAdapter();
        var body = update_adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            body.controller.syncSidebarNodeToSelectedFile(loaded);
            body.initializeDiffCursorForSelectedFile();
            body.clampDiffNavigation();
            body.refreshSearchForSelectedFile();
            body.controller.rebuildFileSearchProjection(allocator);
        }
    }

    fn configuredStore(self: Controller) ?*const review_store.ConfiguredStore {
        const store = self.store orelse return null;
        return if (store.isConfigured()) store else null;
    }

    fn startBasePicker(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const request = self.page_state.beginBasePicker(ctx.allocator()) orelse return;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Review base picker requires a repository");
            return;
        };
        const task = ctx.allocator().create(BranchListTask) catch |err| {
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Could not allocate Review base list task");
            return err;
        };
        task.* = BranchListTask.init(
            request.identity,
            request.generation,
            capability.*,
            self.env_map,
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Could not prepare Review base list task");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = BranchListTask.run, .failed = BranchListTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.base_picker.markStaticFailure(ctx.allocator(), "Could not start Review base list task");
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

    fn ownedSelectionClipboard(
        self: Controller,
        label: []const u8,
        copy: diff_surface.update.SelectionCopy,
    ) ClipboardEffect {
        var effect = self.ownedClipboard(label, copy.text);
        effect.selection_generation = copy.generation;
        return effect;
    }

    fn effectOrigin(self: Controller) effect_origin.PageOrigin {
        const identity = self.page_state.activation.currentIdentity();
        return .{
            .page_id = .review,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repo.epoch(),
            .activation_id = if (identity) |value| value.activation_id else self.page_state.activation.next_activation_id,
        };
    }
};

const semantic_viewport_test_diff =
    "diff --git a/src/compare.zig b/src/compare.zig\n" ++
    "--- a/src/compare.zig\n" ++
    "+++ b/src/compare.zig\n" ++
    "@@ -1,8 +1,8 @@\n" ++
    " context one\n" ++
    "-old two\n" ++
    "+new two\n" ++
    " context three\n" ++
    " context four\n" ++
    " context five\n" ++
    " context six\n" ++
    " context seven\n" ++
    " context eight\n";

fn semanticViewportTestOid(byte: u8) diff_basis.Oid {
    var oid: diff_basis.Oid = .{ .len = 40 };
    @memset(oid.bytes[0..40], byte);
    return oid;
}

fn semanticViewportLoadedFinished(
    allocator: std.mem.Allocator,
    identity: page.RequestIdentity,
    generation: u64,
    base_byte: u8,
    head_byte: u8,
) !app_load.ReviewLoadFinished {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    const display_name = try allocator.dupe(u8, "main");
    errdefer allocator.free(display_name);
    const head_display = try allocator.dupe(u8, "topic");
    errdefer allocator.free(head_display);
    return .{
        .identity = identity,
        .generation = generation,
        .result = .{ .loaded = .{
            .basis = .{
                .base = .{
                    .full_ref = full_ref,
                    .display_name = display_name,
                    .kind = .local,
                },
                .head_display = head_display,
                .target = .{
                    .object_format = .sha1,
                    .source_kind = .branch_range,
                    .base_oid = semanticViewportTestOid(base_byte),
                    .head_oid = semanticViewportTestOid(head_byte),
                    .diff_base_oid = semanticViewportTestOid(base_byte),
                },
                .ahead_count = 1,
            },
            .diff = .{ .loaded = try app_load.buildLoadedBundle(allocator, semantic_viewport_test_diff) },
        } },
    };
}

test "Review changed reload restores semantic viewport after removing retained actions" {
    const allocator = std.testing.allocator;
    var repo: repo_session.State = .{};
    defer repo.deinit(allocator);
    var review: review_page.ReviewPageState = .{};
    defer review.deinit(allocator);
    _ = review.activate(repo.repo_epoch);
    const controller: Controller = .{
        .page_state = &review,
        .repo = repo.view(),
        .layout = .{ .width = 80, .height = 9 },
        .env_map = null,
    };
    var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

    const initial = review.beginRefresh().?;
    try std.testing.expectEqual(
        Redraw.default,
        try controller.finishLoad(&ctx, try semanticViewportLoadedFinished(
            allocator,
            initial.identity,
            initial.generation,
            'a',
            'b',
        )),
    );
    review.viewer.selected_target = .{ .diff_file = 0 };
    review.viewer.selected_node = 0;
    review.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 5 } };
    review.selection_owner = .{ .diff = diff_selection.DragSelection{
        .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "src/compare.zig" } },
        .side = .new,
        .mode = .line,
        .anchor = .{ .hunk_index = 0, .line_index = 0 },
        .focus = .{ .hunk_index = 0, .line_index = 5 },
        .moved = true,
    } };
    const outgoing_view = controller.navigationView();
    review.replaceRefreshAnchor(allocator, try outgoing_view.captureAnchor(allocator));
    const replacement = review.beginRefresh().?;
    try std.testing.expectEqual(
        Redraw.default,
        try controller.finishLoad(&ctx, try semanticViewportLoadedFinished(
            allocator,
            replacement.identity,
            replacement.generation,
            'c',
            'd',
        )),
    );
    try std.testing.expect(review.deferred_load_apply != null);
    try std.testing.expect(review.completed_selection == null);

    const scroll_before_auto = review.viewer.diff_scroll;
    var auto = try controller.update(&ctx, .{ .shared = .{ .mouse_diff_auto_scroll_step = .{
        .direction = .down,
        .endpoint = .{ .col = 20, .row = 8 },
    } } });
    defer auto.deinit(allocator);
    try std.testing.expectEqual(drag_auto_scroll.StepOutcome.moved, auto.auto_scroll.?);
    try std.testing.expectEqual(scroll_before_auto + 1, review.viewer.diff_scroll);
    try std.testing.expect(review.deferred_load_apply != null);

    var release = try controller.update(&ctx, .{ .shared = .{ .mouse_diff_release = null } });
    defer release.deinit(allocator);
    try std.testing.expect(review.completed_selection != null);
    try std.testing.expect(review.pinned_selection_basis != null);

    var outgoing_resolver = outgoing_view.resolver();
    const outgoing_body = outgoing_view.bodyView(&outgoing_resolver);
    review.viewer.diff_scroll = @min(
        outgoing_body.selectedDiffCursorOffset() orelse 0,
        outgoing_body.sourceDiffLineCount() -| outgoing_body.view.diffVisibleRows(),
    );
    const outgoing_anchor = outgoing_body.captureSelectionViewportAnchor() orelse return error.ExpectedSelectionViewport;
    try std.testing.expectEqual(
        Redraw.default,
        try controller.applyDeferred(&ctx),
    );
    try std.testing.expect(review.deferred_load_apply == null);
    try std.testing.expect(review.completed_selection == null);
    try std.testing.expect(review.pinned_selection_basis == null);

    const incoming_view = controller.navigationView();
    var incoming_resolver = incoming_view.resolver();
    const incoming_body = incoming_view.bodyView(&incoming_resolver);
    const expected_scroll = incoming_body.restoreSelectionViewportAnchor(outgoing_anchor);
    try std.testing.expectEqual(outgoing_anchor.raw_presentation_scroll, expected_scroll);
    try std.testing.expectEqual(expected_scroll, review.viewer.diff_scroll);
}

test "Review deferred exact and stale completions reconcile only after release" {
    const allocator = std.testing.allocator;

    {
        var repo: repo_session.State = .{};
        defer repo.deinit(allocator);
        var review: review_page.ReviewPageState = .{};
        defer review.deinit(allocator);
        _ = review.activate(repo.repo_epoch);
        const controller: Controller = .{
            .page_state = &review,
            .repo = repo.view(),
            .layout = .{ .width = 80, .height = 9 },
            .env_map = null,
        };
        var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

        const initial = review.beginRefresh().?;
        try std.testing.expectEqual(
            Redraw.default,
            try controller.finishLoad(&ctx, try semanticViewportLoadedFinished(
                allocator,
                initial.identity,
                initial.generation,
                'a',
                'b',
            )),
        );
        review.viewer.selected_target = .{ .diff_file = 0 };
        review.viewer.selected_node = 0;
        review.viewer.diff_cursor = .{ .hunk_line = .{ .hunk_index = 0, .line_index = 5 } };
        review.selection_owner = .{ .diff = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "src/compare.zig" } },
            .side = .new,
            .mode = .line,
            .anchor = .{ .hunk_index = 0, .line_index = 0 },
            .focus = .{ .hunk_index = 0, .line_index = 5 },
            .moved = true,
        } };
        review.replaceRefreshAnchor(allocator, try controller.navigationView().captureAnchor(allocator));
        const exact = review.beginRefresh().?;
        try std.testing.expectEqual(
            Redraw.default,
            try controller.finishLoad(&ctx, try semanticViewportLoadedFinished(
                allocator,
                exact.identity,
                exact.generation,
                'a',
                'b',
            )),
        );
        try std.testing.expect(review.deferred_load_apply != null);

        var release = try controller.update(&ctx, .{ .shared = .{ .mouse_diff_release = null } });
        defer release.deinit(allocator);
        const retained_ptr = review.completed_selection.?.value.parsed_diff.fragments.items[0].text.ptr;
        const retained_token = review.completed_selection.?.token;
        const retained_pin = review.pinned_selection_basis.?;
        try std.testing.expectEqual(
            Redraw.default,
            try controller.applyDeferred(&ctx),
        );
        try std.testing.expect(review.deferred_load_apply == null);
        try std.testing.expectEqual(
            retained_ptr,
            review.completed_selection.?.value.parsed_diff.fragments.items[0].text.ptr,
        );
        try std.testing.expect(review.completed_selection.?.token.source_session_revision > retained_token.source_session_revision);
        try std.testing.expectEqual(
            review.source_session_revision,
            review.completed_selection.?.token.source_session_revision,
        );
        try std.testing.expect(review.pinned_selection_basis.?.eql(retained_pin));
        try std.testing.expect(review.retainedSelectionAdmitted());
    }

    {
        var repo: repo_session.State = .{};
        defer repo.deinit(allocator);
        var review: review_page.ReviewPageState = .{};
        defer review.deinit(allocator);
        _ = review.activate(repo.repo_epoch);
        const controller: Controller = .{
            .page_state = &review,
            .repo = repo.view(),
            .layout = .{ .width = 80, .height = 9 },
            .env_map = null,
        };
        var ctx: chasen.Ctx(app_message.Msg) = .{ ._allocator = allocator };

        const initial = review.beginRefresh().?;
        try std.testing.expectEqual(
            Redraw.default,
            try controller.finishLoad(&ctx, try semanticViewportLoadedFinished(
                allocator,
                initial.identity,
                initial.generation,
                'a',
                'b',
            )),
        );
        review.viewer.selected_target = .{ .diff_file = 0 };
        review.viewer.selected_node = 0;
        review.selection_owner = .{ .diff = .{
            .identity = .{ .loaded_file = .{ .file_index = 0, .path_key = "src/compare.zig" } },
            .side = .new,
            .mode = .line,
            .anchor = .{ .hunk_index = 0, .line_index = 0 },
            .focus = .{ .hunk_index = 0, .line_index = 5 },
            .moved = true,
        } };
        review.replaceRefreshAnchor(allocator, try controller.navigationView().captureAnchor(allocator));
        const old = review.beginRefresh().?;
        try std.testing.expectEqual(
            Redraw.default,
            try controller.finishLoad(&ctx, try semanticViewportLoadedFinished(
                allocator,
                old.identity,
                old.generation,
                'c',
                'd',
            )),
        );
        try std.testing.expect(review.deferred_load_apply != null);
        _ = review.beginRefresh().?;

        var release = try controller.update(&ctx, .{ .shared = .{ .mouse_diff_release = null } });
        defer release.deinit(allocator);
        const retained_ptr = review.completed_selection.?.value.parsed_diff.fragments.items[0].text.ptr;
        const retained_token = review.completed_selection.?.token;
        const retained_pin = review.pinned_selection_basis.?;
        const retained_revision = review.source_session_revision;
        try std.testing.expectEqual(Redraw.skip, try controller.applyDeferred(&ctx));
        try std.testing.expect(review.deferred_load_apply == null);
        try std.testing.expectEqual(
            retained_ptr,
            review.completed_selection.?.value.parsed_diff.fragments.items[0].text.ptr,
        );
        try std.testing.expect(review.completed_selection.?.token.eql(retained_token));
        try std.testing.expect(review.pinned_selection_basis.?.eql(retained_pin));
        try std.testing.expectEqual(retained_revision, review.source_session_revision);
        try std.testing.expect(review.refresh_anchor != null);
        try std.testing.expect(review.retainedSelectionAdmitted());
    }
}
