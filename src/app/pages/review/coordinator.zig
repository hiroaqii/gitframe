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
const diff_render = @import("../../../diff/render.zig");
const diff_selection = @import("../../../diff/selection.zig");
const finding_card = @import("../../../ai_review/finding_card.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const review_page = @import("../review.zig");
const review_input = @import("input.zig");
const review_navigation = @import("navigation.zig");
const finding_card_view = @import("finding_card_view.zig");
const review_store = @import("../../../review_store.zig");
const human_review_session = @import("../../human_review_session.zig");
const committed_review = @import("../../../committed_review.zig");

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
    human_review_save: bool = false,
    human_review_finalize: ?committed_review.ReviewResultValue = null,

    pub fn deinit(self: *UpdateOutcome, allocator: std.mem.Allocator) void {
        if (self.clipboard) |*effect| effect.deinit(allocator);
        self.* = .{};
    }

    pub fn takeClipboard(self: *UpdateOutcome) ?ClipboardEffect {
        const effect = self.clipboard;
        self.clipboard = null;
        return effect;
    }

    pub fn takeHumanReviewFinalize(self: *UpdateOutcome) ?committed_review.ReviewResultValue {
        const decision = self.human_review_finalize;
        self.human_review_finalize = null;
        return decision;
    }

    pub fn takeHumanReviewSave(self: *UpdateOutcome) bool {
        const requested = self.human_review_save;
        self.human_review_save = false;
        return requested;
    }
};

pub const Controller = struct {
    page_state: *review_page.ReviewPageState,
    repo: repo_session.View,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    env_map: ?*std.process.Environ.Map,
    store: ?*const review_store.ConfiguredStore = null,
    sessions: *human_review_session.Owner,

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
            .shared => |shared_msg| return try self.updateShared(ctx, shared_msg),
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
            .open_human_review_decision => try self.openHumanReviewDecision(ctx.allocator()),
            .human_review_decision => |decision_msg| {
                switch (decision_msg) {
                    .close => {
                        self.page_state.human_review_decision.close();
                        return .{};
                    },
                    else => {},
                }
                const presentation = self.currentHumanReviewPresentation() orelse {
                    self.page_state.human_review_decision.markBindingUnavailable();
                    self.page_state.status.set("Pinned human review session is unavailable", .{});
                    return .{};
                };
                const action = try self.page_state.human_review_decision.apply(
                    decision_msg,
                    presentation,
                );
                switch (action) {
                    .none => {},
                    .submit => |decision| {
                        const session = self.sessions.currentSession() orelse {
                            self.page_state.human_review_decision.markBindingUnavailable();
                            return .{};
                        };
                        if (!session.binding.eql(presentation.binding)) {
                            self.page_state.human_review_decision.markBindingUnavailable();
                            return .{};
                        }
                        session.editSummary(
                            ctx.allocator(),
                            self.page_state.human_review_decision.submittedSummary(),
                        ) catch |err| {
                            self.page_state.human_review_decision.markFinalizeError(err);
                            if (err == error.OutOfMemory) return err;
                            return .{};
                        };
                        return .{ .human_review_finalize = decision };
                    },
                }
            },
            .finding_navigation => |intent| return self.updateFindingNavigation(ctx.allocator(), intent),
            .finding_card => |card_msg| return try self.updateFindingCard(ctx, card_msg),
            .finding_pointer => |pointer| return try self.updateFindingPointer(ctx, pointer),
        }
        return .{};
    }

    fn updateShared(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        shared_msg: diff_surface.message.Msg,
    ) !UpdateOutcome {
        const base_navigation_view = self.navigationView();
        var finding_frame = try base_navigation_view.buildFindingCardFrame(ctx.allocator());
        defer if (finding_frame) |*frame| frame.deinit(ctx.allocator());
        return self.updateSharedWithFindingFrame(
            ctx,
            shared_msg,
            if (finding_frame) |*frame| frame else null,
        );
    }

    fn updateSharedWithFindingFrame(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        shared_msg: diff_surface.message.Msg,
        finding_frame: ?*review_navigation.FindingCardFrame,
    ) !UpdateOutcome {
        const base_navigation_view = self.navigationView();
        const changes_basis = sharedMessageMayChangeFindingCardBasis(shared_msg);
        var incoming_preparation = if (changes_basis)
            try base_navigation_view.prepareFindingCardFrame(ctx.allocator())
        else
            null;
        defer if (incoming_preparation) |*preparation| preparation.deinit();
        const raw_scroll_before = if (changes_basis) self.page_state.viewer.diff_scroll else undefined;
        const selected_target_before = if (changes_basis) self.page_state.viewer.selected_target else undefined;
        const effective_mode_before = if (changes_basis) base_navigation_view.view().effectiveDisplayMode() else undefined;
        const layout_revision_before = if (changes_basis) self.page_state.selection_layout_revision else undefined;
        const source_scroll_before = if (changes_basis) blk: {
            var outgoing_view = base_navigation_view.withPresentationRows(
                if (finding_frame) |frame| &frame.presentation_rows else null,
            );
            var resolver = outgoing_view.resolver();
            const source_scroll = outgoing_view.bodyView(&resolver).sourceAnchorAtOrBeforePresentation(raw_scroll_before) orelse 0;
            self.page_state.viewer.diff_scroll = source_scroll;
            break :blk source_scroll;
        } else undefined;
        var navigation_controller = self.navigation();
        navigation_controller.presentation_rows = if (!changes_basis and finding_frame != null)
            &finding_frame.?.presentation_rows
        else
            null;
        var update_adapter = navigation_controller.updateAdapter();
        var page_update = update_adapter.shared().apply(ctx.allocator(), shared_msg) catch |err| {
            if (changes_basis) self.page_state.viewer.diff_scroll = raw_scroll_before;
            return err;
        };
        defer page_update.deinit(ctx.allocator());
        update_adapter.applyRetentionTransition(ctx.allocator(), page_update.retention_transition);
        self.reconcileFindingCardVisibility();
        if (changes_basis) {
            const source_scroll_after = self.page_state.viewer.diff_scroll;
            var incoming_frame = if (incoming_preparation) |*preparation|
                preparation.fill(self.navigationView(), self.page_state.finding_card)
            else
                null;
            var incoming_controller = self.navigation();
            incoming_controller.presentation_rows = if (incoming_frame) |*frame| &frame.presentation_rows else null;
            var incoming_adapter = incoming_controller.updateAdapter();
            const incoming_body = incoming_adapter.bodyController();
            const mapping_changed = !std.meta.eql(selected_target_before, self.page_state.viewer.selected_target) or
                effective_mode_before != incoming_controller.view().view().effectiveDisplayMode() or
                !sameFindingCardPresentationRows(
                    if (finding_frame) |frame| &frame.presentation_rows else null,
                    if (incoming_frame) |*frame| &frame.presentation_rows else null,
                );
            self.page_state.viewer.diff_scroll = if (!mapping_changed and source_scroll_after == source_scroll_before)
                raw_scroll_before
            else
                incoming_body.view().sourceToPresentationOffset(source_scroll_after) orelse source_scroll_after;
            incoming_body.clampDiffNavigation();
            if (mapping_changed and self.page_state.selection_layout_revision == layout_revision_before) {
                self.page_state.advanceSelectionLayoutRevision();
            }
        }
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
    }

    pub fn currentHumanReviewPresentation(self: Controller) ?human_review_session.Presentation {
        const pinned = self.page_state.pinnedAiConst() orelse return null;
        const presentation = self.sessions.currentPresentation() orelse return null;
        if (!pinned.binding().eql(presentation.binding)) return null;
        return presentation;
    }

    fn openHumanReviewDecision(self: Controller, allocator: std.mem.Allocator) !void {
        if (self.page_state.base_picker.open or self.page_state.ai_reviews.isOpen()) {
            self.page_state.status.set("Close the Review picker before finalizing", .{});
            return;
        }
        const presentation = self.currentHumanReviewPresentation() orelse {
            self.page_state.status.set("Pinned human review session is unavailable", .{});
            return;
        };
        self.page_state.human_review_decision.open(allocator, presentation) catch |err| {
            if (err == error.SessionUnavailable) {
                self.page_state.status.set("Pinned human review session has no review snapshot", .{});
                return;
            }
            return err;
        };
        self.page_state.status.clearIfEphemeral();
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
        const direct = switch (self.page_state.ai_reviews.phase) {
            .selection_loading => |loading| loading.direct,
            else => return .skip,
        };

        switch (finished.result) {
            .loaded => |*bundle| {
                const artifacts = &bundle.selection.artifacts;
                const manifest = &artifacts.manifest.value;
                var candidate = human_review_session.Session.init(
                    ctx.allocator(),
                    .{
                        .review_repository_id = manifest.review_repository_id,
                        .review_id = manifest.review_id,
                        .target = manifest.target,
                        .findings_digest = manifest.findings_digest,
                    },
                    &artifacts.findings.value,
                    if (artifacts.draft) |*draft| &draft.value else null,
                    if (artifacts.result) |*review_result| &review_result.value else null,
                ) catch |err| {
                    self.page_state.ai_reviews.failSelectionStatic(finished.review_id, "Could not own AI review session");
                    return err;
                };
                const reload_current = if (self.sessions.currentSessionConst()) |current|
                    direct and current.binding.eql(candidate.binding) and
                        current.reconciliation == .reload_required
                else
                    false;
                var install = (if (reload_current)
                    self.sessions.prepareReload(&candidate)
                else
                    self.sessions.prepareInstall(&candidate)) catch |err| {
                    candidate.deinit();
                    self.page_state.ai_reviews.failSelectionStatic(finished.review_id, "AI review has unsaved recovery state");
                    return err;
                };
                defer install.deinit();
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
                self.sessions.commitInstall(&install);
                finished.result = .empty;
                self.page_state.ai_reviews.close(ctx.allocator());
                self.initializeAcceptedBody(ctx.allocator());
                self.reconcileFindingCardVisibility();
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
                const clear_plan = self.sessions.prepareClear() catch |err| {
                    self.page_state.ai_reviews.failNormalReturn("AI review has unsaved recovery state");
                    return err;
                };
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
                self.sessions.commitClear(clear_plan);
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
            request.direct,
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

    fn updateFindingCard(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        msg: review_input.FindingCardMsg,
    ) !UpdateOutcome {
        if (msg == .owned_noop) return .{};
        const allocator = ctx.allocator();

        const base_view = self.navigationView();
        var current_frame = (try base_view.buildFindingCardFrame(allocator)) orelse {
            self.clearFindingCardFocus();
            return .{};
        };
        defer current_frame.deinit(allocator);

        var current_view = base_view.withPresentationRows(&current_frame.presentation_rows);
        var current_resolver = current_view.resolver();
        const current_body = current_view.bodyView(&current_resolver);
        const source_anchor = current_body.sourceAnchorAtOrBeforePresentation(self.page_state.viewer.diff_scroll);
        var next_state = self.page_state.finding_card;
        var action: finding_card.Action = .none;

        switch (msg) {
            .focus_or_cycle => {
                const cursor = switch (self.page_state.viewer.diff_cursor) {
                    .hunk_line => |line| line,
                    else => return .{},
                };
                const group = current_frame.row_plan.groupAtOrigin(cursor.hunk_index, cursor.line_index) orelse return .{};
                const cards = current_frame.row_plan.cardsForGroup(group);
                if (cards.len == 0) return .{};
                var next_index: usize = 0;
                for (cards, 0..) |model, index| {
                    if (!next_state.matches(model)) continue;
                    next_index = (index + 1) % cards.len;
                    break;
                }
                action = next_state.apply(.{ .cycle = cards[next_index] });
            },
            .toggle => {
                if (!current_frame.containsFocused(next_state)) return .{};
                action = next_state.apply(.toggle);
            },
            .scroll_up, .scroll_down => {
                const model = focusedFindingCard(current_frame.row_plan, next_state) orelse return .{};
                const content = self.page_state.contentForFindingCard(model) orelse return .{};
                const content_width = review_page.findingCardContentWidth(current_body.view.diffPaneWidth());
                const max_scroll = try review_page.findingCardMaxBodyScroll(allocator, content, content_width);
                _ = next_state.apply(.{ .scroll = .{
                    .direction = if (msg == .scroll_up) .up else .down,
                    .max_scroll = max_scroll,
                } });
                self.page_state.finding_card = next_state;
                return .{};
            },
            .copy => {
                const model = focusedFindingCard(current_frame.row_plan, next_state) orelse return .{};
                const content = self.page_state.contentForFindingCard(model) orelse return .{};
                if (next_state.apply(.copy) != .copy_requested) return .{};
                const text = try findingCardCopyText(allocator, content);
                return .{ .clipboard = self.ownedClipboard("Finding", text) };
            },
            .accept, .dismiss, .unreview => {
                const model = focusedFindingCard(current_frame.row_plan, next_state) orelse return .{};
                const presentation = self.currentHumanReviewPresentation() orelse {
                    self.page_state.status.set("Finding disposition is unavailable", .{});
                    return .{};
                };
                const current = findingDisposition(presentation, model) orelse {
                    self.page_state.status.set("Finding disposition is unavailable", .{});
                    return .{};
                };
                const desired: committed_review.FindingDispositionValue = switch (msg) {
                    .accept => .accepted,
                    .dismiss => .dismissed,
                    .unreview => .unreviewed,
                    else => unreachable,
                };
                if (current == desired) return .{};
                const session = self.sessions.currentSession() orelse {
                    self.page_state.status.set("Finding disposition is unavailable", .{});
                    return .{};
                };
                if (!session.binding.eql(presentation.binding)) {
                    self.page_state.status.set("Finding disposition is unavailable", .{});
                    return .{};
                }
                session.editDisposition(
                    allocator,
                    .{ .bytes = model.finding_id },
                    desired,
                ) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    self.page_state.status.set("Finding disposition update is unavailable", .{});
                    return .{};
                };
                return .{ .human_review_save = true };
            },
            .retry => {
                const model = focusedFindingCard(current_frame.row_plan, next_state) orelse return .{};
                const presentation = self.currentHumanReviewPresentation() orelse return .{};
                if (findingDisposition(presentation, model) == null) return .{};
                const session = self.sessions.currentSession() orelse return .{};
                if (!session.binding.eql(presentation.binding)) return .{};
                if (session.reconciliation == .reload_required) {
                    try self.startPinnedRefresh(ctx);
                    return .{};
                }
                if (session.lifecycle() != .failed) return .{};
                const failure = session.last_failure orelse return .{};
                if (failure.kind != .draft) return .{};
                return .{ .human_review_save = true };
            },
            .leave => {
                action = next_state.apply(.leave);
            },
            .owned_noop => unreachable,
        }

        _ = try self.commitFindingCardTransition(
            allocator,
            base_view,
            &current_frame,
            source_anchor,
            next_state,
            action,
        );
        return .{};
    }

    fn commitFindingCardTransition(
        self: Controller,
        allocator: std.mem.Allocator,
        base_view: review_navigation.View,
        current_frame: *const review_navigation.FindingCardFrame,
        source_anchor: ?usize,
        next_state: finding_card.State,
        action: finding_card.Action,
    ) !bool {
        var next_frame = (try base_view.buildFindingCardFrameForState(allocator, next_state)) orelse return false;
        defer next_frame.deinit(allocator);
        const transition = findingCardScrollTransition(
            current_frame,
            &next_frame,
            self.page_state.viewer.diff_scroll,
            source_anchor,
            base_view.view().diffVisibleRows(),
            next_state,
            action,
        );
        if (transition.mapping_changed) {
            self.page_state.advanceSelectionLayoutRevision();
        }
        self.page_state.finding_card = next_state;
        self.page_state.viewer.diff_scroll = transition.scroll;
        return true;
    }

    fn updateFindingPointer(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        pointer: review_input.FindingPointerEvent,
    ) !UpdateOutcome {
        const shared_msg = findingPointerSharedMessage(pointer);
        const allocator = ctx.allocator();
        const base_view = self.navigationView();
        const frame_optional = base_view.buildFindingCardFrame(allocator) catch {
            self.page_state.status.set("Could not resolve Finding pointer", .{});
            return .{};
        };
        if (frame_optional == null) return try self.updateSharedWithFindingFrame(ctx, shared_msg, null);
        var current_frame = frame_optional.?;
        defer current_frame.deinit(allocator);

        var current_view = base_view.withPresentationRows(&current_frame.presentation_rows);
        var resolver = current_view.resolver();
        const body = current_view.bodyView(&resolver);
        const hit = body.presentationCellHit(pointer.point) orelse
            return try self.updateSharedWithFindingFrame(ctx, shared_msg, &current_frame);
        switch (hit) {
            .source => return try self.updateSharedWithFindingFrame(ctx, shared_msg, &current_frame),
            .spacer => switch (pointer.button) {
                .wheel_up, .wheel_down => return try self.updateSharedWithFindingFrame(ctx, shared_msg, &current_frame),
                .left, .wheel_left, .wheel_right => return .{},
            },
            .card => |card_hit| {
                if (card_hit.token >= current_frame.row_plan.cards.len) {
                    self.page_state.status.set("Could not resolve Finding pointer", .{});
                    return .{};
                }
                const model = current_frame.row_plan.cards[card_hit.token];
                switch (pointer.button) {
                    .left => {
                        if (card_hit.local_row == finding_card.expanded_rows - 1 and
                            self.page_state.finding_card.expanded(model))
                        {
                            const target = finding_card_view.footerCopyTarget(body.view.diffPaneWidth()) orelse return .{};
                            if (!target.contains(card_hit.local_col)) return .{};
                            const content = self.page_state.contentForFindingCard(model) orelse {
                                self.page_state.status.set("Could not resolve Finding pointer", .{});
                                return .{};
                            };
                            var copy_state = self.page_state.finding_card;
                            if (copy_state.apply(.copy) != .copy_requested) return .{};
                            const text = try findingCardCopyText(allocator, content);
                            return .{ .clipboard = self.ownedClipboard("Finding", text) };
                        }
                        if (card_hit.local_row != 0) return .{};
                        const source_anchor = body.sourceAnchorAtOrBeforePresentation(self.page_state.viewer.diff_scroll);
                        var next_state = self.page_state.finding_card;
                        const action = if (next_state.matches(model))
                            next_state.apply(.toggle)
                        else
                            next_state.apply(.{ .focus = model });
                        const committed = self.commitFindingCardTransition(
                            allocator,
                            base_view,
                            &current_frame,
                            source_anchor,
                            next_state,
                            action,
                        ) catch {
                            self.page_state.status.set("Could not resolve Finding pointer", .{});
                            return .{};
                        };
                        if (!committed) {
                            self.page_state.status.set("Could not resolve Finding pointer", .{});
                            return .{};
                        }
                        self.page_state.viewer.focus = .diff;
                        return .{};
                    },
                    .wheel_up, .wheel_down => {
                        if (!self.page_state.finding_card.expanded(model)) {
                            return try self.updateSharedWithFindingFrame(ctx, shared_msg, &current_frame);
                        }
                        const content = self.page_state.contentForFindingCard(model) orelse {
                            self.page_state.status.set("Could not resolve Finding pointer", .{});
                            return .{};
                        };
                        const content_width = review_page.findingCardContentWidth(body.view.diffPaneWidth());
                        const max_scroll = review_page.findingCardMaxBodyScroll(
                            allocator,
                            content,
                            content_width,
                        ) catch {
                            self.page_state.status.set("Could not resolve Finding pointer", .{});
                            return .{};
                        };
                        var next_state = self.page_state.finding_card;
                        _ = next_state.apply(.{ .scroll = .{
                            .direction = if (pointer.button == .wheel_up) .up else .down,
                            .max_scroll = max_scroll,
                        } });
                        self.page_state.finding_card = next_state;
                        return .{};
                    },
                    .wheel_left, .wheel_right => return .{},
                }
            },
        }
    }

    fn updateFindingNavigation(
        self: Controller,
        allocator: std.mem.Allocator,
        intent: review_input.FindingNavigationIntent,
    ) UpdateOutcome {
        const pinned = self.page_state.pinnedAiConst() orelse return .{};
        const base_view = self.navigationView();
        if (base_view.view().effectiveDisplayMode() != .unified) {
            self.page_state.status.set("Finding navigation is unavailable in side-by-side view", .{});
            return .{};
        }
        const loaded = base_view.view().activeLoadedDiffConst() orelse {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        };
        const projection = &pinned.selection.finding_projection;
        const selected_file = base_view.view().selectedDiffFileTarget();
        const ordered = switch (intent.scope) {
            .current_file => blk: {
                const file_index = selected_file orelse {
                    self.page_state.status.set("Finding target is unavailable", .{});
                    return .{};
                };
                if (file_index >= loaded.document.files.len or file_index >= projection.files.len) {
                    self.page_state.status.set("Finding target is unavailable", .{});
                    return .{};
                }
                break :blk projection.files[file_index].mapped_entry_indices;
            },
            .all_files => projection.mapped_entry_indices,
        };
        if (ordered.len == 0) {
            switch (intent.scope) {
                .current_file => self.page_state.status.set("No mapped Findings in this file", .{}),
                .all_files => self.page_state.status.set("No mapped Findings in this review", .{}),
            }
            return .{};
        }

        const entry_index = findingNavigationEntryIndex(
            projection,
            ordered,
            self.page_state.finding_card,
            intent.direction,
        );
        const target = finding_card.FindingCardModel.init(projection, entry_index) orelse {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        };
        if (intent.scope == .current_file and
            (selected_file == null or selected_file.? != target.span.file_ordinal))
        {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        }
        if (target.span.file_ordinal >= loaded.document.files.len or
            target.span.file_ordinal >= projection.files.len or
            !loaded.fileTextSelectable(target.span.file_ordinal) or
            self.page_state.contentForFindingCard(target) == null)
        {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        }
        const target_file = loaded.document.files[target.span.file_ordinal];
        if (target.span.hunk_ordinal >= target_file.hunks.len or
            target.span.first_diff_line_ordinal > target.span.last_diff_line_ordinal or
            target.span.first_diff_line_ordinal >= target_file.hunks[target.span.hunk_ordinal].lines.len or
            target.span.last_diff_line_ordinal >= target_file.hunks[target.span.hunk_ordinal].lines.len or
            finding_card.FindingId.init(target.finding_id) == null or
            !findingNavigationFileContainsEntry(projection, target.span.file_ordinal, entry_index))
        {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        }
        const exact_file_node = loaded.tree.selectedNodeIndex(target.span.file_ordinal) orelse {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        };
        if (exact_file_node >= loaded.tree.nodes.len or
            loaded.tree.nodes[exact_file_node].diffFileIndex() != target.span.file_ordinal)
        {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        }
        const switches_file = selected_file == null or selected_file.? != target.span.file_ordinal;
        const target_node = if (intent.scope == .all_files and switches_file)
            findingNavigationSidebarNode(loaded, exact_file_node)
        else
            self.page_state.viewer.selected_node;
        if (switches_file and
            (target_node >= loaded.tree.nodes.len or
                (loaded.visibleNodeCount() > 0 and loaded.visibleRowOfNode(target_node) == null) or
                (loaded.visibleNodeCount() == 0 and target_node != exact_file_node)))
        {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        }

        var outgoing_frame = base_view.buildFindingCardFrame(allocator) catch {
            self.page_state.status.set("Could not prepare Finding navigation", .{});
            return .{};
        };
        defer if (outgoing_frame) |*frame| frame.deinit(allocator);
        var preparation = (base_view.prepareFindingCardFrame(allocator) catch {
            self.page_state.status.set("Could not prepare Finding navigation", .{});
            return .{};
        }) orelse {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        };
        defer preparation.deinit();

        const raw_scroll_before = self.page_state.viewer.diff_scroll;
        const selected_target_before = self.page_state.viewer.selected_target;
        var outgoing_view = base_view.withPresentationRows(if (outgoing_frame) |*frame|
            &frame.presentation_rows
        else
            null);
        var outgoing_resolver = outgoing_view.resolver();
        const source_anchor = outgoing_view.bodyView(&outgoing_resolver).sourceAnchorAtOrBeforePresentation(raw_scroll_before);
        // No allocation or fallible operation is permitted below this point.
        var navigation_controller = self.navigation();
        var update_adapter = navigation_controller.updateAdapter();
        var body = update_adapter.bodyController();
        const mutable_loaded = body.controller.activeLoadedDiff().?;
        if (switches_file) {
            body.controller.setSelectedDiffFile(target.span.file_ordinal);
            self.page_state.viewer.selected_node = target_node;
            body.resetDiffPosition();
        }
        self.page_state.viewer.focus = .diff;
        mutable_loaded.setHunkFolded(target.span.file_ordinal, target.span.hunk_ordinal, false);
        body.updateSearchMatchOffset();
        self.page_state.viewer.diff_cursor = .{ .hunk_line = .{
            .hunk_index = target.span.hunk_ordinal,
            .line_index = target.span.last_diff_line_ordinal,
        } };
        var next_state = self.page_state.finding_card;
        const focus_action = next_state.apply(.{ .focus = target });
        std.debug.assert(focus_action == .ensure_visible);
        self.page_state.finding_card = next_state;

        var incoming_frame = preparation.fill(self.navigationView(), next_state) orelse unreachable;
        const mapping_changed = !std.meta.eql(selected_target_before, self.page_state.viewer.selected_target) or
            !sameFindingCardPresentationRows(
                if (outgoing_frame) |*frame| &frame.presentation_rows else null,
                &incoming_frame.presentation_rows,
            );
        var scroll = if (switches_file)
            0
        else if (source_anchor) |anchor|
            incoming_frame.presentation_rows.sourceToPresentation(anchor) orelse raw_scroll_before
        else
            raw_scroll_before;
        const visible_rows = base_view.view().diffVisibleRows();
        const max_scroll = incoming_frame.presentation_rows.total_rows -| visible_rows;
        scroll = @min(scroll, max_scroll);
        const card_index = incoming_frame.row_plan.cardIndex(target) orelse unreachable;
        const card_start = incoming_frame.presentation_rows.cardStart(card_index) orelse unreachable;
        const card_height = next_state.cardRows(target);
        if (card_start < scroll) {
            scroll = card_start;
        } else if (visible_rows > 0 and card_start + card_height > scroll + visible_rows) {
            scroll = if (card_height >= visible_rows)
                card_start
            else
                card_start + card_height - visible_rows;
        }
        self.page_state.viewer.diff_scroll = @min(scroll, max_scroll);
        if (mapping_changed) self.page_state.advanceSelectionLayoutRevision();
        self.page_state.status.clearIfEphemeral();
        return .{};
    }

    pub fn reconcileFindingCardVisibility(self: Controller) void {
        const view = self.navigationView();
        if (view.focusedFindingCardVisible()) return;
        self.clearFindingCardFocus();
        var navigation_controller = self.navigation();
        var adapter = navigation_controller.updateAdapter();
        adapter.bodyController().clampDiffNavigation();
    }

    fn clearFindingCardFocus(self: Controller) void {
        const layout_changed = findingCardStateExpanded(self.page_state.finding_card);
        self.page_state.finding_card = .unfocused;
        if (layout_changed) self.page_state.advanceSelectionLayoutRevision();
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

fn findingNavigationEntryIndex(
    projection: *const finding_projection.FindingProjectionIndex,
    ordered: []const usize,
    state: finding_card.State,
    direction: review_input.FindingNavigationIntent.Direction,
) usize {
    std.debug.assert(ordered.len > 0);
    var focused_position: ?usize = null;
    for (ordered, 0..) |entry_index, position| {
        const model = finding_card.FindingCardModel.init(projection, entry_index) orelse continue;
        if (!state.matches(model)) continue;
        focused_position = position;
        break;
    }
    const position = if (focused_position) |current| switch (direction) {
        .previous => if (current == 0) ordered.len - 1 else current - 1,
        .next => (current + 1) % ordered.len,
    } else switch (direction) {
        .previous => ordered.len - 1,
        .next => 0,
    };
    return ordered[position];
}

fn findingNavigationFileContainsEntry(
    projection: *const finding_projection.FindingProjectionIndex,
    file_index: usize,
    entry_index: usize,
) bool {
    for (projection.files[file_index].mapped_entry_indices) |candidate| {
        if (candidate == entry_index) return true;
    }
    return false;
}

fn findingNavigationSidebarNode(loaded: *const loaded_diff.LoadedDiff, exact_file_node: usize) usize {
    if (loaded.visibleRowOfNode(exact_file_node) != null) return exact_file_node;
    if (loaded.visibleAncestorOrSelf(exact_file_node)) |node_index| return node_index;
    return loaded.visibleNodeAt(0) orelse exact_file_node;
}

fn findingPointerSharedMessage(pointer: review_input.FindingPointerEvent) diff_surface.message.Msg {
    return switch (pointer.button) {
        .left => .{ .mouse_diff_press = pointer.point },
        .wheel_up => .mouse_diff_wheel_up,
        .wheel_down => .mouse_diff_wheel_down,
        .wheel_left => .mouse_diff_wheel_left,
        .wheel_right => .mouse_diff_wheel_right,
    };
}

fn sharedMessageMayChangeFindingCardBasis(msg: diff_surface.message.Msg) bool {
    return switch (msg) {
        .select_previous_file,
        .select_next_file,
        .select_first_file,
        .select_last_file,
        .sidebar_click_node,
        .mouse_sidebar_wheel_up,
        .mouse_sidebar_wheel_down,
        .submit_file_search,
        .toggle_hunk_fold,
        .submit_search,
        .select_next_search_match,
        .select_previous_search_match,
        .toggle_display_mode,
        .toggle_sidebar_visibility,
        .decrease_sidebar_width,
        .increase_sidebar_width,
        .toggle_reviewed_file,
        .toggle_hide_reviewed_files,
        .cycle_changed_file_filter,
        => true,
        else => false,
    };
}

fn sameFindingCardPresentationRows(
    left: ?*const diff_render.PresentationRows,
    right: ?*const diff_render.PresentationRows,
) bool {
    if (left == null or right == null) return left == null and right == null;
    if (left.?.source_rows != right.?.source_rows or
        left.?.total_rows != right.?.total_rows or
        left.?.blocks.len != right.?.blocks.len) return false;
    for (left.?.blocks, right.?.blocks) |left_block, right_block| {
        if (!std.meta.eql(left_block, right_block)) return false;
    }
    return true;
}

fn focusedFindingCard(plan: finding_card.RowPlan, state: finding_card.State) ?finding_card.FindingCardModel {
    const index = focusedFindingCardIndex(plan, state) orelse return null;
    return plan.cards[index];
}

fn findingDisposition(
    presentation: human_review_session.Presentation,
    model: finding_card.FindingCardModel,
) ?committed_review.FindingDispositionValue {
    if (!presentation.binding.review_repository_id.eql(model.identity.review_repository_id) or
        !presentation.binding.review_id.eql(model.identity.review_id) or
        !presentation.binding.target.eql(&model.identity.target) or
        !presentation.binding.findings_digest.eql(model.identity.findings_digest)) return null;
    const snapshot = presentation.snapshot orelse return null;
    for (snapshot.finding_dispositions) |value| {
        if (std.mem.eql(u8, value.finding_id.bytes, model.finding_id)) return value.disposition;
    }
    return null;
}

fn focusedFindingCardIndex(plan: finding_card.RowPlan, state: finding_card.State) ?usize {
    for (plan.cards, 0..) |model, index| if (state.matches(model)) return index;
    return null;
}

fn findingCardStateExpanded(state: finding_card.State) bool {
    return switch (state) {
        .unfocused => false,
        .focused => |focused| switch (focused.view) {
            .collapsed => false,
            .expanded => true,
        },
    };
}

const FindingCardScrollTransition = struct {
    scroll: usize,
    mapping_changed: bool,
};

fn findingCardScrollTransition(
    current_frame: *const review_navigation.FindingCardFrame,
    next_frame: *const review_navigation.FindingCardFrame,
    current_scroll: usize,
    source_anchor: ?usize,
    visible_rows: usize,
    next_state: finding_card.State,
    action: finding_card.Action,
) FindingCardScrollTransition {
    const max_scroll = next_frame.presentation_rows.total_rows -| visible_rows;
    const mapping_changed = current_frame.presentation_rows.total_rows != next_frame.presentation_rows.total_rows;
    var next_scroll = if (!mapping_changed)
        current_scroll
    else if (source_anchor) |anchor|
        next_frame.presentation_rows.sourceToPresentation(anchor) orelse current_scroll
    else
        current_scroll;
    next_scroll = @min(next_scroll, max_scroll);
    if (action == .ensure_visible) {
        if (focusedFindingCardIndex(next_frame.row_plan, next_state)) |card_index| {
            const start = next_frame.presentation_rows.cardStart(card_index) orelse next_scroll;
            const height = next_state.cardRows(next_frame.row_plan.cards[card_index]);
            if (start < next_scroll) {
                next_scroll = start;
            } else if (visible_rows > 0 and height < visible_rows and start + height > next_scroll + visible_rows) {
                next_scroll = start + height - visible_rows;
            } else if (visible_rows > 0 and height >= visible_rows) {
                next_scroll = start;
            }
            next_scroll = @min(next_scroll, max_scroll);
        }
    }
    return .{ .scroll = next_scroll, .mapping_changed = mapping_changed };
}

fn findingCardCopyText(
    allocator: std.mem.Allocator,
    content: review_page.FindingCardContent,
) std.mem.Allocator.Error![]u8 {
    if (content.suggestion) |suggestion| return std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}\n\nSuggestion:\n{s}",
        .{ content.title, content.body, suggestion },
    );
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ content.title, content.body });
}

test "Review inline Finding copy bytes are width and scroll independent" {
    const allocator = std.testing.allocator;
    const without = try findingCardCopyText(allocator, .{
        .producer = "agent",
        .model = null,
        .title = "Title",
        .body = "Body\nline",
        .suggestion = null,
    });
    defer allocator.free(without);
    try std.testing.expectEqualStrings("Title\n\nBody\nline", without);

    const with = try findingCardCopyText(allocator, .{
        .producer = "agent",
        .model = "model",
        .title = "Title",
        .body = "Body",
        .suggestion = "replace exactly",
    });
    defer allocator.free(with);
    try std.testing.expectEqualStrings("Title\n\nBody\n\nSuggestion:\nreplace exactly", with);
}

test "Review inline Finding coordinator preserves raw scroll until card row geometry changes" {
    var repository_id: committed_review.ReviewRepositoryId = .{ .bytes = [_]u8{0} ** 16 };
    var review_id: committed_review.ReviewId = .{ .bytes = [_]u8{0} ** 16 };
    var digest: committed_review.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 };
    repository_id.bytes[0] = 1;
    review_id.bytes[0] = 2;
    digest.bytes[0] = 3;
    const identity: finding_projection.Identity = .{
        .review_repository_id = repository_id,
        .review_id = review_id,
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = .{},
            .head_oid = .{},
            .diff_base_oid = .{},
        },
        .findings_digest = digest,
    };
    var cards = [_]finding_card.FindingCardModel{
        .{
            .identity = identity,
            .entry_index = 0,
            .finding_id = "first",
            .span = .{ .file_ordinal = 0, .hunk_ordinal = 0, .first_diff_line_ordinal = 1, .last_diff_line_ordinal = 1 },
            .severity = .warning,
        },
        .{
            .identity = identity,
            .entry_index = 1,
            .finding_id = "second",
            .span = .{ .file_ordinal = 0, .hunk_ordinal = 0, .first_diff_line_ordinal = 1, .last_diff_line_ordinal = 1 },
            .severity = .warning,
        },
    };
    var groups = [_]finding_card.Group{.{
        .hunk_ordinal = 0,
        .last_diff_line_ordinal = 1,
        .card_start = 0,
        .card_count = cards.len,
    }};
    const row_plan: finding_card.RowPlan = .{ .groups = &groups, .cards = &cards };
    const collapsed_inputs = [_]diff_render.InlineBlockInput{
        .{ .after_source_offset = 1, .height = 1, .kind = .{ .card = 0 } },
        .{ .after_source_offset = 1, .height = 1, .kind = .{ .card = 1 } },
        .{ .after_source_offset = 1, .height = 1, .kind = .spacer },
    };
    const expanded_inputs = [_]diff_render.InlineBlockInput{
        .{ .after_source_offset = 1, .height = finding_card.expanded_rows, .kind = .{ .card = 0 } },
        .{ .after_source_offset = 1, .height = 1, .kind = .{ .card = 1 } },
        .{ .after_source_offset = 1, .height = 1, .kind = .spacer },
    };
    var collapsed_rows = try diff_render.PresentationRows.init(std.testing.allocator, 6, &collapsed_inputs);
    defer collapsed_rows.deinit(std.testing.allocator);
    var expanded_rows = try diff_render.PresentationRows.init(std.testing.allocator, 6, &expanded_inputs);
    defer expanded_rows.deinit(std.testing.allocator);
    const collapsed_frame: review_navigation.FindingCardFrame = .{ .row_plan = row_plan, .presentation_rows = collapsed_rows };
    const expanded_frame: review_navigation.FindingCardFrame = .{ .row_plan = row_plan, .presentation_rows = expanded_rows };

    var state: finding_card.State = .unfocused;
    _ = state.apply(.{ .focus = cards[0] });
    _ = state.apply(.{ .cycle = cards[1] });
    const cycled = findingCardScrollTransition(&collapsed_frame, &collapsed_frame, 2, 1, 4, state, .ensure_visible);
    try std.testing.expect(!cycled.mapping_changed);
    try std.testing.expectEqual(@as(usize, 2), cycled.scroll);

    _ = state.apply(.leave);
    const left = findingCardScrollTransition(&collapsed_frame, &collapsed_frame, 5, 1, 4, state, .none);
    try std.testing.expect(!left.mapping_changed);
    try std.testing.expectEqual(@as(usize, 5), left.scroll);

    _ = state.apply(.{ .focus = cards[0] });
    _ = state.apply(.toggle);
    const expanded = findingCardScrollTransition(&collapsed_frame, &expanded_frame, 3, 1, 4, state, .ensure_visible);
    try std.testing.expect(expanded.mapping_changed);
    try std.testing.expectEqual(@as(usize, 2), expanded.scroll);

    _ = state.apply(.toggle);
    const collapsed = findingCardScrollTransition(&expanded_frame, &collapsed_frame, 6, 1, 4, state, .ensure_visible);
    try std.testing.expect(collapsed.mapping_changed);
    try std.testing.expectEqual(@as(usize, 1), collapsed.scroll);

    var unresolved = cards[0];
    unresolved.entry_index = 2;
    unresolved.finding_id = "unresolved";
    _ = state.apply(.{ .focus = unresolved });
    try std.testing.expect(focusedFindingCard(row_plan, state) == null);
    try std.testing.expect(state.reconcileVisible(row_plan.cards));
    try std.testing.expect(!state.isFocused());
}

test "Review inline Finding copy reports allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, findingCardCopyText(failing.allocator(), .{
        .producer = "agent",
        .model = null,
        .title = "Title",
        .body = "Body",
        .suggestion = null,
    }));
}

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
    var sessions: human_review_session.Owner = .{};
    defer sessions.deinit();
    _ = review.activate(repo.repo_epoch);
    const controller: Controller = .{
        .page_state = &review,
        .repo = repo.view(),
        .layout = .{ .width = 80, .height = 9 },
        .env_map = null,
        .sessions = &sessions,
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
        var sessions: human_review_session.Owner = .{};
        defer sessions.deinit();
        _ = review.activate(repo.repo_epoch);
        const controller: Controller = .{
            .page_state = &review,
            .repo = repo.view(),
            .layout = .{ .width = 80, .height = 9 },
            .env_map = null,
            .sessions = &sessions,
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
        var sessions: human_review_session.Owner = .{};
        defer sessions.deinit();
        _ = review.activate(repo.repo_epoch);
        const controller: Controller = .{
            .page_state = &review,
            .repo = repo.view(),
            .layout = .{ .width = 80, .height = 9 },
            .env_map = null,
            .sessions = &sessions,
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
