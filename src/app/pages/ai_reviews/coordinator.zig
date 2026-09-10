//! AI Reviews input, task, and completion coordination.
//!
//! The controller is a short-lived composition over the retained AI Reviews page
//! and a read-only repository snapshot. It owns task terminals and translates
//! page-local commands into typed clipboard effects without importing App.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const effect_origin = @import("../../effect_origin.zig");
const repo_session = @import("../../repo_session.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_selection = @import("../../../diff/selection.zig");
const diff_view_model = @import("../../../diff/view_model.zig");
const finding_card = @import("../../../ai_review/finding_card.zig");
const finding_projection = @import("../../../ai_review/finding_projection.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const ai_reviews_page = @import("../ai_reviews.zig");
const ai_reviews_input = @import("input.zig");
const ai_reviews_navigation = @import("navigation.zig");
const finding_card_view = @import("finding_card_view.zig");
const review_store = @import("../../../review_store.zig");
const human_review_session = @import("../../human_review_session.zig");
const review_store_operations = @import("../../review_store_operations.zig");
const committed_review = @import("../../../committed_review.zig");
const delete_confirmation = @import("delete_confirmation.zig");

const HistoryScanTask = app_load.AiReviewScanTask(app_message.Msg);
const HistorySelectionTask = app_load.AiReviewSelectionTask(app_message.Msg);
const DeleteTask = delete_confirmation.Task(app_message.Msg);

pub const Redraw = enum {
    default,
    skip,
};

pub const HistorySelectionFinish = struct {
    redraw: Redraw,
    loaded: bool = false,
};

/// Clipboard text may borrow the accepted AI Reviews snapshot or own a short
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
    page_state: *ai_reviews_page.AiReviewsPageState,
    repo: repo_session.View,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    env_map: ?*std.process.Environ.Map,
    store: ?*const review_store.ConfiguredStore = null,
    sessions: *human_review_session.Owner,
    operations: ?*review_store_operations.Owner = null,

    pub fn navigation(self: Controller) ai_reviews_navigation.Controller {
        return .{
            .page = self.page_state,
            .repo_root = self.repo.activeRoot(),
            .repo_epoch = self.repo.epoch(),
            .root_identity = self.repo.activeIdentity(),
            .layout = self.layout,
            .mode_toggle_hint_width = self.mode_toggle_hint_width,
        };
    }

    pub fn navigationView(self: Controller) ai_reviews_navigation.View {
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
        msg: ai_reviews_input.Msg,
    ) !UpdateOutcome {
        if (self.page_state.delete_confirmation.isOpen()) switch (msg) {
            .cancel_run_delete, .confirm_run_delete, .delete_owned_noop => {},
            else => return .{},
        };
        self.ensureFindingPresentationCache();
        switch (msg) {
            .common => |common_msg| switch (common_msg) {
                .shared => |shared_msg| return self.updateShared(ctx, shared_msg),
                .copy_current_line => return self.copyCurrentLine(),
                .copy_current_hunk => return self.copyCurrentHunk(ctx.allocator()),
                .branch_switch_unavailable => self.page_state.status.set("branch switching is not available in AI Reviews", .{}),
            },
            .open_picker => try self.startHistoryScan(ctx, false),
            .close_picker => self.page_state.picker.close(ctx.allocator()),
            .picker_cancel_loading => self.page_state.picker.cancelLoading(ctx.allocator()),
            .picker_enter_query => self.page_state.picker.enterQuery(),
            .picker_leave_query => self.page_state.picker.leaveQuery(),
            .picker_clear_query_or_leave => self.page_state.picker.clearQueryOrLeave(ctx.allocator()) catch
                self.page_state.status.set("Could not update AI review filter", .{}),
            .picker_insert => |codepoint| self.page_state.picker.insertQuery(ctx.allocator(), codepoint) catch
                self.page_state.status.set("Could not update AI review filter", .{}),
            .picker_backspace => self.page_state.picker.backspaceQuery(ctx.allocator()) catch
                self.page_state.status.set("Could not update AI review filter", .{}),
            .picker_previous => self.page_state.picker.moveSelection(-1),
            .picker_next => self.page_state.picker.moveSelection(1),
            .picker_activate => try self.activateSelection(ctx),
            .picker_refresh_or_retry => try self.retryPicker(ctx),
            .open_run_delete => try self.openRunDelete(ctx.allocator()),
            .cancel_run_delete => _ = self.page_state.delete_confirmation.cancel(ctx.allocator()),
            .confirm_run_delete => try self.confirmRunDelete(ctx),
            .close_selected_run => self.closeSelectedRun(ctx.allocator()),
            .delete_owned_noop => {},
            .open_human_review_decision => try self.openHumanReviewDecision(ctx.allocator()),
            .human_review_decision => |decision_msg| {
                if (decision_msg == .close) {
                    self.page_state.human_review_decision.close();
                    return .{};
                }
                const presentation = self.currentHumanReviewPresentation() orelse {
                    self.page_state.human_review_decision.markBindingUnavailable();
                    self.page_state.status.set("Selected human review session is unavailable", .{});
                    return .{};
                };
                const action = try self.page_state.human_review_decision.apply(decision_msg, presentation);
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
            .finding_card => |card_msg| return self.updateFindingCard(ctx, card_msg),
            .finding_pointer => |pointer| return self.updateFindingPointer(ctx, pointer),
        }
        return .{};
    }

    fn updateShared(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        shared_msg: diff_surface.message.Msg,
    ) !UpdateOutcome {
        const base_navigation_view = self.navigationView();
        var finding_frame = base_navigation_view.cachedFindingCardFrame();
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
        finding_frame: ?*ai_reviews_navigation.FindingCardFrame,
    ) !UpdateOutcome {
        const base_navigation_view = self.navigationView();
        const changes_basis = sharedMessageMayChangeFindingCardBasis(shared_msg);
        var incoming_preparation = if (changes_basis)
            try base_navigation_view.prepareFindingCardFrame(ctx.allocator())
        else
            null;
        defer if (incoming_preparation) |*preparation| preparation.deinit();
        const raw_scroll_before = if (changes_basis) self.page_state.diff.viewer.diff_scroll else undefined;
        const selected_target_before = if (changes_basis) self.page_state.diff.viewer.selected_target else undefined;
        const effective_mode_before = if (changes_basis) base_navigation_view.view().effectiveDisplayMode() else undefined;
        const layout_revision_before = if (changes_basis) self.page_state.diff.selection_layout_revision else undefined;
        const source_scroll_before = if (changes_basis) blk: {
            var outgoing_view = base_navigation_view.withPresentationRows(
                if (finding_frame) |frame| &frame.presentation_rows else null,
            );
            var resolver = outgoing_view.resolver();
            const source_scroll = outgoing_view.bodyView(&resolver).sourceAnchorAtOrBeforePresentation(raw_scroll_before) orelse 0;
            self.page_state.diff.viewer.diff_scroll = source_scroll;
            break :blk source_scroll;
        } else undefined;
        var navigation_controller = self.navigation();
        navigation_controller.presentation_rows = if (!changes_basis and finding_frame != null)
            &finding_frame.?.presentation_rows
        else
            null;
        var update_adapter = navigation_controller.updateAdapter();
        var page_update = update_adapter.shared().apply(ctx.allocator(), shared_msg) catch |err| {
            if (changes_basis) self.page_state.diff.viewer.diff_scroll = raw_scroll_before;
            return err;
        };
        defer page_update.deinit(ctx.allocator());
        update_adapter.applyRetentionTransition(ctx.allocator(), page_update.retention_transition);
        self.reconcileFindingCardVisibility();
        if (changes_basis) {
            const source_scroll_after = self.page_state.diff.viewer.diff_scroll;
            var incoming_frame = if (incoming_preparation) |*preparation|
                preparation.fill(self.navigationView(), self.page_state.finding_card)
            else
                null;
            var incoming_controller = self.navigation();
            incoming_controller.presentation_rows = if (incoming_frame) |*frame| &frame.presentation_rows else null;
            var incoming_adapter = incoming_controller.updateAdapter();
            const incoming_body = incoming_adapter.bodyController();
            const mapping_changed = !std.meta.eql(selected_target_before, self.page_state.diff.viewer.selected_target) or
                effective_mode_before != incoming_controller.view().view().effectiveDisplayMode() or
                !sameFindingCardPresentationRows(
                    if (finding_frame) |frame| &frame.presentation_rows else null,
                    if (incoming_frame) |*frame| &frame.presentation_rows else null,
                );
            self.page_state.diff.viewer.diff_scroll = if (!mapping_changed and source_scroll_after == source_scroll_before)
                raw_scroll_before
            else
                incoming_body.view().sourceToPresentationOffset(source_scroll_after) orelse source_scroll_after;
            incoming_body.clampDiffNavigation();
            if (mapping_changed and self.page_state.diff.selection_layout_revision == layout_revision_before) {
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
        const selected = self.page_state.selectedRunConst() orelse return null;
        const presentation = self.sessions.currentPresentation() orelse return null;
        if (!selected.binding().eql(presentation.binding)) return null;
        return presentation;
    }

    fn openHumanReviewDecision(self: Controller, allocator: std.mem.Allocator) !void {
        if (self.page_state.picker.isOpen()) {
            self.page_state.status.set("Close the AI Reviews picker before finalizing", .{});
            return;
        }
        const presentation = self.currentHumanReviewPresentation() orelse {
            self.page_state.status.set("Selected AI review session is unavailable", .{});
            return;
        };
        self.page_state.human_review_decision.open(allocator, presentation) catch |err| {
            if (err == error.SessionUnavailable) {
                self.page_state.status.set("Selected AI review session has no review snapshot", .{});
                return;
            }
            return err;
        };
        self.page_state.status.clearIfEphemeral();
    }

    pub fn refresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.page_state.delete_confirmation.isOpen()) return;
        if (self.page_state.selectedRunConst() == null) {
            self.page_state.status.set("Select an AI review before refreshing", .{});
            return;
        }
        try self.startSelectedRefresh(ctx);
    }

    pub fn finishHistoryScan(
        self: Controller,
        allocator: std.mem.Allocator,
        result: app_load.AiReviewScanFinished,
    ) Redraw {
        var finished = result;
        defer finished.deinit(allocator);
        const store = self.configuredStore() orelse return .skip;
        const accepted = self.page_state.picker.acceptScan(
            allocator,
            self.repo.epoch(),
            self.repo.activeIdentity(),
            store.identity(),
            &self.page_state.activation,
            &finished,
        );
        return if (accepted and self.page_state.activation.currentIdentity() != null) .default else .skip;
    }

    pub fn finishHistorySelection(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: app_load.AiReviewSelectionFinished,
    ) !HistorySelectionFinish {
        var finished = result;
        defer finished.deinit(ctx.allocator());
        if (self.page_state.delete_confirmation.isOpen()) return .{ .redraw = .skip };
        const store = self.configuredStore() orelse return .{ .redraw = .skip };
        if (!self.page_state.picker.acceptsSelection(
            self.repo.epoch(),
            self.repo.activeIdentity(),
            store.identity(),
            &self.page_state.activation,
            finished,
        )) return .{ .redraw = .skip };
        const direct = switch (self.page_state.picker.phase) {
            .selection_loading => |loading| loading.direct,
            else => return .{ .redraw = .skip },
        };
        const visible = self.page_state.activation.currentIdentity() != null;
        var loaded = false;

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
                    self.failSelectionStatic(ctx.allocator(), finished.review_id, direct, "Could not own AI review session");
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
                    self.failSelectionStatic(ctx.allocator(), finished.review_id, direct, "AI review has unsaved recovery state");
                    return err;
                };
                defer install.deinit();

                self.page_state.commitSelectedRun(
                    ctx.allocator(),
                    self.repo.epoch(),
                    self.repo.activeRoot(),
                    self.repo.activeIdentity(),
                    bundle,
                ) catch |err| {
                    self.failSelectionStatic(ctx.allocator(), finished.review_id, direct, "Could not apply AI review");
                    return err;
                };
                self.sessions.commitInstall(&install);
                finished.result = .empty;
                self.page_state.picker.close(ctx.allocator());
                self.initializeAcceptedBody(ctx.allocator(), direct);
                self.reconcileFindingCardVisibility();
                if (self.page_state.activation.currentIdentity()) |identity| {
                    _ = self.page_state.activation.finishMember(identity, .source, .immutable);
                }
                loaded = true;
            },
            .selection_failed => |failure| {
                self.failSelection(ctx.allocator(), finished.review_id, direct, failure);
                self.page_state.diff.clearReloadAnchor(ctx.allocator());
                if (self.page_state.activation.currentIdentity()) |identity| {
                    _ = self.page_state.activation.finishMember(identity, .source, .failed);
                }
            },
            .failed_static => |message| {
                self.failSelectionStatic(ctx.allocator(), finished.review_id, direct, message);
                self.page_state.diff.clearReloadAnchor(ctx.allocator());
                if (self.page_state.activation.currentIdentity()) |identity| {
                    _ = self.page_state.activation.finishMember(identity, .source, .failed);
                }
            },
            .empty => {
                self.failSelectionStatic(ctx.allocator(), finished.review_id, direct, "Could not load AI review");
                self.page_state.diff.clearReloadAnchor(ctx.allocator());
                if (self.page_state.activation.currentIdentity()) |identity| {
                    _ = self.page_state.activation.finishMember(identity, .source, .failed);
                }
            },
        }
        return .{
            .redraw = if (visible) .default else .skip,
            .loaded = loaded,
        };
    }

    pub fn finishDelete(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        result: delete_confirmation.Finished,
    ) !Redraw {
        var finished = result;
        defer finished.deinit(ctx.allocator());
        const store = self.configuredStore() orelse return .skip;
        const accepted = self.page_state.delete_confirmation.accept(
            ctx.allocator(),
            self.repo.epoch(),
            self.repo.activeIdentity(),
            store.identity(),
            self.page_state.activation.acceptsPageInstance(finished.identity, self.repo.epoch()),
            finished,
        ) orelse return .skip;

        switch (accepted.result) {
            .failed_static => |message| self.page_state.status.set("Could not delete AI review: {s}", .{message}),
            .result => |delete_result| switch (delete_result) {
                .failure => |failure| self.page_state.status.set(
                    "Could not delete AI review: {s}",
                    .{deleteFailureText(failure)},
                ),
                .deleted => |cleanup| {
                    switch (cleanup) {
                        .complete => self.page_state.status.set("Deleted AI review Run", .{}),
                        .pending => |failure| self.page_state.status.set(
                            "Deleted AI review Run; cleanup pending: {s}",
                            .{deleteFailureText(failure)},
                        ),
                    }
                    try self.startHistoryScanPreferred(ctx, accepted.fallback_review_id, true);
                },
            },
        }
        return .default;
    }

    pub fn prepareModalRedraw(self: Controller, io: std.Io) void {
        self.page_state.picker.prepareModalRedraw(io);
    }

    fn openRunDelete(self: Controller, allocator: std.mem.Allocator) !void {
        if (self.page_state.delete_confirmation.isOpen()) return;
        switch (self.page_state.picker.phase) {
            .ready, .selection_failed => {},
            .scan_loading, .selection_loading => {
                self.page_state.status.set("Wait for the current AI review load before deleting", .{});
                return;
            },
            .closed, .empty, .scan_failed => return,
        }
        const row = self.page_state.picker.selectedRow() orelse return;
        const store = self.page_state.picker.selectedStoreSnapshot() orelse return;
        if (self.deleteBlocked(store.review_repository_id, row.review_id)) return;
        try self.page_state.delete_confirmation.begin(
            allocator,
            store,
            row,
            self.page_state.picker.adjacentSelectedReviewId(),
        );
    }

    fn confirmRunDelete(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const summary = self.page_state.delete_confirmation.summary() orelse return;
        const repository_id = summary.request.store.review_repository_id;
        const review_id = summary.request.review_id;
        if (self.deleteBlocked(repository_id, review_id)) return;
        const identity = self.page_state.activation.currentIdentity() orelse {
            self.page_state.status.set("Could not delete AI review: page unavailable", .{});
            return;
        };
        const root_identity = self.repo.activeIdentity() orelse {
            self.page_state.status.set("Could not delete AI review: repository unavailable", .{});
            return;
        };
        const store = self.configuredStore() orelse {
            self.page_state.status.set("Could not delete AI review: Store unavailable", .{});
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.status.set("Could not delete AI review: repository unavailable", .{});
            return;
        };
        const request = self.page_state.delete_confirmation.confirm(
            identity,
            root_identity,
            store.identity(),
        ) orelse return;
        const task = ctx.allocator().create(DeleteTask) catch |err| {
            self.page_state.delete_confirmation.restoreConfirmation();
            self.page_state.status.set("Could not allocate AI review deletion", .{});
            return err;
        };
        task.* = DeleteTask.init(
            request,
            store,
            capability.*,
            self.env_map,
            ctx.allocator(),
        ) catch |err| {
            ctx.allocator().destroy(task);
            self.page_state.delete_confirmation.restoreConfirmation();
            self.page_state.status.set("Could not prepare AI review deletion", .{});
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = DeleteTask.run, .failed = DeleteTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.delete_confirmation.restoreConfirmation();
            self.page_state.status.set("Could not start AI review deletion", .{});
            return err;
        };
    }

    fn deleteBlocked(
        self: Controller,
        repository_id: committed_review.ReviewRepositoryId,
        review_id: committed_review.ReviewId,
    ) bool {
        if (self.page_state.selectedRunConst()) |selected| {
            const binding = selected.binding();
            if (binding.review_repository_id.eql(repository_id) and binding.review_id.eql(review_id)) {
                self.page_state.status.set("Close the selected Run with c before deleting it", .{});
                return true;
            }
        }
        if (self.sessions.holdsRun(repository_id, review_id)) {
            self.page_state.status.set("Close the active or recovery session before deleting this Run", .{});
            return true;
        }
        if (self.operations) |operations| {
            if (operations.holdsRun(repository_id, review_id)) {
                self.page_state.status.set("Finish the pending review save before deleting this Run", .{});
                return true;
            }
        }
        return false;
    }

    fn closeSelectedRun(self: Controller, allocator: std.mem.Allocator) void {
        if (self.page_state.picker.loading()) {
            self.page_state.status.set("Wait for the current AI review load before closing the selected Run", .{});
            return;
        }
        const selected = self.page_state.selectedRunConst() orelse {
            self.page_state.status.set("No selected AI review Run to close", .{});
            return;
        };
        const binding = selected.binding();
        if (self.operations) |operations| {
            if (operations.holdsRun(binding.review_repository_id, binding.review_id)) {
                self.page_state.status.set("Finish the pending review save before closing this Run", .{});
                return;
            }
        }
        if (self.sessions.detachedHoldsRun(binding.review_repository_id, binding.review_id)) {
            self.page_state.status.set("This Run has retained recovery state and cannot be closed here", .{});
            return;
        }
        if (self.sessions.currentSessionConst() != null and
            !self.sessions.currentHoldsRun(binding.review_repository_id, binding.review_id))
        {
            self.page_state.status.set("Selected Run session ownership is inconsistent", .{});
            return;
        }
        const plan = self.sessions.prepareClear() catch {
            self.page_state.status.set("Save or resolve this Run before closing it", .{});
            return;
        };
        if (plan == .detach) {
            self.page_state.status.set("This Run has recovery state and cannot be closed here", .{});
            return;
        }
        self.sessions.commitClear(plan);
        self.page_state.closeSelectedRun(allocator);
        self.page_state.status.set("Closed selected AI review Run", .{});
    }

    /// Common update-tail admission for the one selected-Run presentation
    /// cache. Rendering remains read-only and never reconstructs a frame.
    pub fn ensureFindingPresentationCache(self: Controller) void {
        self.navigation().ensureFindingPresentationCache();
        self.ensureVisibleFindingBodyCache();
    }

    fn ensureVisibleFindingBodyCache(self: Controller) void {
        const base_view = self.navigationView();
        const frame = base_view.cachedFindingCardFrame() orelse return;
        const model = focusedFindingCard(frame.row_plan, self.page_state.finding_card) orelse return;
        if (!self.page_state.finding_card.expanded(model)) return;
        const card_index = focusedFindingCardIndex(frame.row_plan, self.page_state.finding_card) orelse return;
        const card_start = frame.presentation_rows.cardStart(card_index) orelse return;
        const body_start = std.math.add(usize, card_start, finding_card.body_start_row) catch return;
        const body_end = std.math.add(usize, body_start, finding_card.body_rows) catch return;
        const viewport_start = self.page_state.diff.viewer.diff_scroll;
        const viewport_end = std.math.add(
            usize,
            viewport_start,
            base_view.view().diffVisibleRows(),
        ) catch std.math.maxInt(usize);
        if (body_start >= viewport_end or body_end <= viewport_start) return;

        const width = ai_reviews_page.findingCardContentWidth(base_view.findingCardRowWidth(model));
        if (width == 0 or self.page_state.cachedFindingBody(model, width) != null) return;
        const content = self.page_state.contentForFindingCard(model) orelse return;
        const finding_id = finding_card.FindingId.init(model.finding_id) orelse return;
        const pinned = self.page_state.selectedRun() orelse return;
        const cache = if (pinned.finding_presentation_cache) |*value| value else return;
        cache.invalidateBody();
        const text = ai_reviews_page.findingCardDisplayTextInto(cache.body_display, content);
        const row_count = finding_card_view.prepareWrappedRows(text, width, cache.body_row_starts);
        cache.body_text_len = text.len;
        cache.body_row_count = row_count;
        cache.body_key = .{ .finding_id = finding_id, .width = width };
    }

    fn startHistoryScan(self: Controller, ctx: *chasen.Ctx(app_message.Msg), retain_query: bool) !void {
        const preferred = if (retain_query)
            if (self.page_state.picker.selectedRow()) |row| row.review_id else self.page_state.activeReviewId()
        else
            self.page_state.activeReviewId();
        try self.startHistoryScanPreferred(ctx, preferred, retain_query);
    }

    fn startHistoryScanPreferred(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        preferred: ?committed_review.ReviewId,
        retain_query: bool,
    ) !void {
        const identity = self.page_state.activation.currentIdentity() orelse return;
        const root_identity = self.repo.activeIdentity() orelse {
            self.page_state.status.set("AI reviews require a repository", .{});
            return;
        };
        const request = self.page_state.picker.beginScan(
            ctx.allocator(),
            identity,
            root_identity,
            preferred,
            retain_query,
        );
        const store = self.configuredStore() orelse {
            self.page_state.picker.markScanFailure("Could not load AI reviews: Store unavailable");
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.picker.markScanFailure("Could not load AI reviews: repository unavailable");
            return;
        };
        const task = ctx.allocator().create(HistoryScanTask) catch |err| {
            self.page_state.picker.markScanFailure("Could not allocate AI review scan");
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
            self.page_state.picker.markScanFailure("Could not prepare AI review scan");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = HistoryScanTask.run, .failed = HistoryScanTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.picker.markScanFailure("Could not start AI review scan");
            return err;
        };
    }

    fn activateSelection(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        switch (self.page_state.picker.beginSelectedRun()) {
            .none => {},
            .unavailable => self.page_state.status.set("Review target unavailable; restore objects and press r", .{}),
            .request => |request| try self.spawnSelection(ctx, request),
        }
    }

    fn startSelectedRefresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const selected = self.page_state.selectedRun() orelse return;
        const identity = self.page_state.activation.currentIdentity() orelse return;
        const root_identity = self.repo.activeIdentity() orelse return;
        const anchor = try self.navigationView().captureAnchor(ctx.allocator());
        self.page_state.diff.replaceReloadAnchor(ctx.allocator(), anchor);
        self.page_state.activation.markPending(.source);
        const request = self.page_state.picker.beginDirectSelection(
            ctx.allocator(),
            identity,
            root_identity,
            selected.selection.snapshot,
            selected.reviewId(),
            review_store.ArtifactSnapshot.fromLoaded(&selected.selection.artifacts),
        );
        try self.spawnSelection(ctx, request);
    }

    fn spawnSelection(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        request: ai_reviews_page.AiReviewSelectionRequest,
    ) !void {
        const store = self.configuredStore() orelse {
            self.failSelectionStatic(ctx.allocator(), request.review_id, request.direct, "Could not load AI review: Store unavailable");
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.failSelectionStatic(ctx.allocator(), request.review_id, request.direct, "Could not load AI review: repository unavailable");
            return;
        };
        const task = ctx.allocator().create(HistorySelectionTask) catch |err| {
            self.failSelectionStatic(ctx.allocator(), request.review_id, request.direct, "Could not allocate AI review load");
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
            self.failSelectionStatic(ctx.allocator(), request.review_id, request.direct, "Could not prepare AI review load");
            return err;
        };
        ctx.task().spawnWith(.{ .ctx = task, .run = HistorySelectionTask.run, .failed = HistorySelectionTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.failSelectionStatic(ctx.allocator(), request.review_id, request.direct, "Could not start AI review load");
            return err;
        };
    }

    fn failSelection(
        self: Controller,
        allocator: std.mem.Allocator,
        review_id: committed_review.ReviewId,
        direct: bool,
        failure: review_store.SelectionFailure,
    ) void {
        self.page_state.picker.failSelection(review_id, failure);
        if (!direct) return;
        const message = switch (self.page_state.picker.phase) {
            .selection_failed => |value| value.message,
            else => return,
        };
        self.page_state.status.set("{s}", .{message});
        self.page_state.picker.close(allocator);
    }

    fn failSelectionStatic(
        self: Controller,
        allocator: std.mem.Allocator,
        review_id: committed_review.ReviewId,
        direct: bool,
        message: []const u8,
    ) void {
        self.page_state.picker.failSelectionStatic(review_id, message);
        if (!direct) return;
        self.page_state.status.set("{s}", .{message});
        self.page_state.picker.close(allocator);
    }

    fn retryPicker(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        switch (self.page_state.picker.phase) {
            .scan_loading, .ready, .empty, .scan_failed => try self.startHistoryScan(ctx, true),
            .selection_loading => |loading| {
                if (loading.direct) return self.startSelectedRefresh(ctx);
                switch (self.page_state.picker.retrySelectedRun()) {
                    .request => |request| try self.spawnSelection(ctx, request),
                    .unavailable => self.page_state.status.set("Review target unavailable; restore objects and press r", .{}),
                    .none => try self.startHistoryScan(ctx, true),
                }
            },
            .selection_failed => |failure| {
                if (failure.direct) return self.startSelectedRefresh(ctx);
                try self.startHistoryScan(ctx, true);
            },
            .closed => {},
        }
    }

    fn initializeAcceptedBody(self: Controller, allocator: std.mem.Allocator, restore_anchor: bool) void {
        const navigation_controller = self.navigation();
        var update_adapter = navigation_controller.updateAdapter();
        var body = update_adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            if (restore_anchor) {
                if (self.page_state.diff.takeReloadAnchor()) |anchor_value| {
                    var anchor = anchor_value;
                    defer anchor.deinit(allocator);
                    _ = body.restoreReloadAnchor(loaded, &anchor);
                } else {
                    body.controller.syncSidebarNodeToSelectedFile(loaded);
                    body.initializeDiffCursorForSelectedFile();
                }
            } else {
                self.page_state.diff.clearReloadAnchor(allocator);
                body.controller.syncSidebarNodeToSelectedFile(loaded);
                body.initializeDiffCursorForSelectedFile();
            }
            body.clampDiffNavigation();
            body.refreshSearchForSelectedFile();
            body.controller.rebuildFileSearchProjection(allocator);
        } else {
            self.page_state.diff.clearReloadAnchor(allocator);
        }
    }

    fn configuredStore(self: Controller) ?*const review_store.ConfiguredStore {
        const store = self.store orelse return null;
        return if (store.isConfigured()) store else null;
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
        msg: ai_reviews_input.FindingCardMsg,
    ) !UpdateOutcome {
        if (msg == .owned_noop) return .{};
        const allocator = ctx.allocator();

        const base_view = self.navigationView();
        var current_frame = base_view.cachedFindingCardFrame() orelse {
            self.clearFindingCardFocus();
            return .{};
        };

        var current_view = base_view.withPresentationRows(&current_frame.presentation_rows);
        var current_resolver = current_view.resolver();
        const current_body = current_view.bodyView(&current_resolver);
        const source_anchor = current_body.sourceAnchorAtOrBeforePresentation(self.page_state.diff.viewer.diff_scroll);
        var next_state = self.page_state.finding_card;
        var action: finding_card.Action = .none;

        switch (msg) {
            .focus_or_cycle => {
                const source_offset = current_body.selectedDiffCursorOffset() orelse return .{};
                const next = nextFindingCardAtSourceOffset(&current_frame, source_offset, next_state) orelse return .{};
                action = next_state.apply(.{ .cycle = next });
            },
            .toggle => {
                if (!current_frame.containsFocused(next_state)) return .{};
                action = next_state.apply(.toggle);
            },
            .scroll_up, .scroll_down => {
                const model = focusedFindingCard(current_frame.row_plan, next_state) orelse return .{};
                const content_width = ai_reviews_page.findingCardContentWidth(base_view.findingCardRowWidth(model));
                const body = self.page_state.cachedFindingBody(model, content_width) orelse return .{};
                const max_scroll = body.rowCount() -| finding_card.body_rows;
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
                    try self.refresh(ctx);
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
        base_view: ai_reviews_navigation.View,
        current_frame: *const ai_reviews_navigation.FindingCardFrame,
        source_anchor: ?usize,
        next_state: finding_card.State,
        action: finding_card.Action,
    ) !bool {
        var next_frame = (try base_view.buildFindingCardFrameForState(allocator, next_state)) orelse return false;
        defer next_frame.deinit(allocator);
        const transition = findingCardScrollTransition(
            current_frame,
            &next_frame,
            self.page_state.diff.viewer.diff_scroll,
            source_anchor,
            base_view.view().diffVisibleRows(),
            next_state,
            action,
        );
        if (transition.mapping_changed) {
            self.page_state.advanceSelectionLayoutRevision();
        }
        self.page_state.finding_card = next_state;
        self.page_state.diff.viewer.diff_scroll = transition.scroll;
        return true;
    }

    fn updateFindingPointer(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        pointer: ai_reviews_input.FindingPointerEvent,
    ) !UpdateOutcome {
        const shared_msg = findingPointerSharedMessage(pointer);
        const allocator = ctx.allocator();
        const base_view = self.navigationView();
        const frame_optional = base_view.cachedFindingCardFrame();
        if (frame_optional == null) return try self.updateSharedWithFindingFrame(ctx, shared_msg, null);
        var current_frame = frame_optional.?;

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
                        if (card_hit.local_row == finding_card.footer_row and
                            self.page_state.finding_card.expanded(model))
                        {
                            const target = finding_card_view.footerCopyTarget(base_view.findingCardRowWidth(model)) orelse return .{};
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
                        const source_anchor = body.sourceAnchorAtOrBeforePresentation(self.page_state.diff.viewer.diff_scroll);
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
                        self.page_state.diff.viewer.focus = .diff;
                        return .{};
                    },
                    .wheel_up, .wheel_down => {
                        if (!self.page_state.finding_card.expanded(model)) {
                            return try self.updateSharedWithFindingFrame(ctx, shared_msg, &current_frame);
                        }
                        const content_width = ai_reviews_page.findingCardContentWidth(base_view.findingCardRowWidth(model));
                        const cached_body = self.page_state.cachedFindingBody(model, content_width) orelse {
                            self.page_state.status.set("Could not resolve Finding pointer", .{});
                            return .{};
                        };
                        const max_scroll = cached_body.rowCount() -| finding_card.body_rows;
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
        intent: ai_reviews_input.FindingNavigationIntent,
    ) UpdateOutcome {
        const pinned = self.page_state.selectedRunConst() orelse return .{};
        const base_view = self.navigationView();
        const effective_mode = base_view.view().effectiveDisplayMode();
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
            (effective_mode == .side_by_side and diff_view_model.sideBySideRenderedOffsetForLineOnSide(
                target_file.hunks[target.span.hunk_ordinal].lines,
                target.span.last_diff_line_ordinal,
                switch (target.side) {
                    .before => .old,
                    .after => .new,
                },
            ) == null) or
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
            self.page_state.diff.viewer.selected_node;
        if (switches_file and
            (target_node >= loaded.tree.nodes.len or
                (loaded.visibleNodeCount() > 0 and loaded.visibleRowOfNode(target_node) == null) or
                (loaded.visibleNodeCount() == 0 and target_node != exact_file_node)))
        {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        }

        var outgoing_frame = base_view.cachedFindingCardFrame();
        var preparation = (base_view.prepareFindingCardFrame(allocator) catch {
            self.page_state.status.set("Could not prepare Finding navigation", .{});
            return .{};
        }) orelse {
            self.page_state.status.set("Finding target is unavailable", .{});
            return .{};
        };
        defer preparation.deinit();

        const raw_scroll_before = self.page_state.diff.viewer.diff_scroll;
        const selected_target_before = self.page_state.diff.viewer.selected_target;
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
            self.page_state.diff.viewer.selected_node = target_node;
            body.resetDiffPosition();
        }
        self.page_state.diff.viewer.focus = .diff;
        mutable_loaded.setHunkFolded(target.span.file_ordinal, target.span.hunk_ordinal, false);
        body.updateSearchMatchOffset();
        self.page_state.diff.viewer.diff_cursor = .{ .hunk_line = .{
            .hunk_index = target.span.hunk_ordinal,
            .line_index = target.span.last_diff_line_ordinal,
        } };
        var next_state = self.page_state.finding_card;
        const focus_action = next_state.apply(.{ .focus = target });
        std.debug.assert(focus_action == .ensure_visible);
        self.page_state.finding_card = next_state;

        var incoming_frame = preparation.fill(self.navigationView(), next_state) orelse unreachable;
        const mapping_changed = !std.meta.eql(selected_target_before, self.page_state.diff.viewer.selected_target) or
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
        self.page_state.diff.viewer.diff_scroll = @min(scroll, max_scroll);
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
            .page_id = .ai_reviews,
            .repo_epoch = if (identity) |value| value.repo_epoch else self.repo.epoch(),
            .activation_id = if (identity) |value| value.activation_id else self.page_state.activation.next_activation_id,
        };
    }
};

fn findingNavigationEntryIndex(
    projection: *const finding_projection.FindingProjectionIndex,
    ordered: []const usize,
    state: finding_card.State,
    direction: ai_reviews_input.FindingNavigationIntent.Direction,
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

fn findingPointerSharedMessage(pointer: ai_reviews_input.FindingPointerEvent) diff_surface.message.Msg {
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

fn nextFindingCardAtSourceOffset(
    frame: *const ai_reviews_navigation.FindingCardFrame,
    source_offset: usize,
    state: finding_card.State,
) ?finding_card.FindingCardModel {
    var first: ?finding_card.FindingCardModel = null;
    var choose_next = false;
    for (frame.presentation_rows.blocks) |block| {
        if (block.after_source_offset != source_offset) continue;
        const card_index = switch (block.kind) {
            .card => |value| value,
            .spacer => continue,
        };
        if (card_index >= frame.row_plan.cards.len) return null;
        const model = frame.row_plan.cards[card_index];
        if (first == null) first = model;
        if (choose_next) return model;
        if (state.matches(model)) choose_next = true;
    }
    return first;
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
    current_frame: *const ai_reviews_navigation.FindingCardFrame,
    next_frame: *const ai_reviews_navigation.FindingCardFrame,
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
    content: ai_reviews_page.FindingCardContent,
) std.mem.Allocator.Error![]u8 {
    if (content.suggestion) |suggestion| return std.fmt.allocPrint(
        allocator,
        "{s}\n\n{s}\n\nSuggestion:\n{s}",
        .{ content.title, content.body, suggestion },
    );
    return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ content.title, content.body });
}

fn deleteFailureText(failure: review_store.MaintenanceFailure) []const u8 {
    return switch (failure) {
        .not_found => "Run not found",
        .conflict => "Run changed",
        .unfinished => "Run is unfinished",
        .binding_changed => "repository binding changed",
        .run_invalid => "Run is invalid",
        .permission_denied => "permission denied",
        .io_failed => "I/O failed",
        .store_unavailable => "Store unavailable",
        .unsupported => "unsupported filesystem",
    };
}
