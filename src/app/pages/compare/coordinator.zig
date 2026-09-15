//! Compare input, task, and completion coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_message = @import("../../message.zig");
const repo_session = @import("../../repo_session.zig");
const committed_review = @import("../../../committed_review.zig");
const diff_surface = @import("../../diff_surface.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const diff_basis = @import("../../diff_basis.zig");
const effect_origin = @import("../../effect_origin.zig");
const compare_page = @import("../compare.zig");
const compare_input = @import("input.zig");
const compare_view = @import("view.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");
const committed_diff_coordinator = @import("../committed_diff/coordinator.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const repo_discovery = @import("../../../repo/discovery.zig");

const CompareLoadTask = app_load.CompareLoadTask(app_message.Msg);
const BranchListTask = app_load.CompareBranchListLoadTask(app_message.Msg);

pub const Redraw = enum { default, skip };
pub const ClipboardEffect = committed_diff_coordinator.ClipboardEffect;
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
    page_state: *compare_page.ComparePageState,
    repo: repo_session.View,
    layout: diff_surface.Layout,
    mode_toggle_hint_width: u16 = 0,
    env_map: ?*std.process.Environ.Map,
    executable_path: ?[]const u8 = null,
    handoff_overlay_size: chasen.Size = .{ .width = 0, .height = 0 },

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
            .open_ai_review_handoff => self.openAiReviewHandoff(ctx.allocator()),
            .close_ai_review_handoff => self.page_state.closeAiReviewHandoff(ctx.allocator()),
            .copy_ai_review_handoff => return self.copyAiReviewHandoff(),
            .scroll_ai_review_handoff => |action| self.page_state.ai_review_handoff.scroll(
                action,
                compare_view.aiReviewHandoffPromptSize(self.handoff_overlay_size),
            ),
        }
        return .{};
    }

    pub fn refresh(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markNoRepository(ctx.allocator());
            return;
        };
        const anchor = try self.navigationView().captureAnchor(ctx.allocator());
        self.page_state.diff.replaceReloadAnchor(ctx.allocator(), anchor);
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
        var body = adapter.bodyController();
        if (body.controller.activeLoadedDiff()) |loaded| {
            if (self.page_state.diff.takeReloadAnchor()) |anchor_value| {
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

    pub fn applyDeferred(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !Redraw {
        if (self.page_state.diff.selection_owner.activeMouseSelection()) return .default;
        const deferred = self.page_state.deferred_load_apply orelse return .default;
        self.page_state.deferred_load_apply = null;
        return self.finishLoad(ctx, deferred.finished);
    }

    pub fn prepareModalRedraw(self: Controller, io: std.Io) void {
        self.page_state.base_picker.prepareModalRedraw(io);
    }

    pub fn clampAiReviewHandoffViewport(self: Controller) void {
        self.page_state.ai_review_handoff.clampViewport(
            compare_view.aiReviewHandoffPromptSize(self.handoff_overlay_size),
        );
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
            .branch_unavailable_message = "branch switching is not available in Compare",
        };
    }

    fn openAiReviewHandoff(self: Controller, allocator: std.mem.Allocator) void {
        const repository_path = self.validRepositoryPath();
        const target = if (repository_path != null) self.acceptedTarget() else null;
        self.page_state.beginAiReviewHandoff(allocator, .{
            .executable_path = self.executable_path,
            .repository_path = repository_path,
            .target = target,
        });
    }

    fn copyAiReviewHandoff(self: Controller) UpdateOutcome {
        const copy = self.page_state.ai_review_handoff.beginCopy() orelse return .{};
        return .{ .clipboard = .{
            .origin = .{ .compare_ai_review_handoff = .{
                .page = self.pageOrigin(),
                .modal_instance_id = copy.modal_instance_id,
                .copy_generation = copy.copy_generation,
            } },
            .label = "AI review handoff prompt",
            .text = copy.prompt,
        } };
    }

    fn validRepositoryPath(self: Controller) ?[]const u8 {
        const repository_path = self.repo.activeRoot() orelse return null;
        const identity = self.repo.activeIdentity() orelse return null;
        const capability = self.repo.activeCapability() orelse return null;
        if (!capability.identity.eql(identity) or !root_capability.pathMatches(repository_path, identity)) return null;
        return repository_path;
    }

    fn acceptedTarget(self: Controller) ?@import("../../../committed_review.zig").CommittedReviewTarget {
        const identity = self.repo.activeIdentity() orelse return null;
        const accepted_repository = self.page_state.diff.accepted_repository_identity orelse return null;
        if (!accepted_repository.matches(self.repo.epoch(), identity) or !self.page_state.hasAcceptedDisplay()) return null;
        const basis = self.page_state.basis orelse return null;
        const selected_base = self.page_state.base_target orelse return null;
        if (selected_base.kind != basis.base.kind or
            !std.mem.eql(u8, selected_base.full_ref, basis.base.full_ref)) return null;
        basis.target.validate() catch return null;
        return basis.target;
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

fn handoffTestTarget() committed_review.CommittedReviewTarget {
    const base = committed_review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111") catch unreachable;
    const head = committed_review.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222") catch unreachable;
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = base,
        .head_oid = head,
        .diff_base_oid = base,
    };
}

fn handoffTestDiscovery(allocator: std.mem.Allocator, repository_path: []const u8) !repo_discovery.DiscoveryResult {
    const label = try allocator.dupe(u8, "repo");
    errdefer allocator.free(label);
    const display_path = try allocator.dupe(u8, repository_path);
    errdefer allocator.free(display_path);
    return .{ .single_repo = .{
        .label = label,
        .display_path = display_path,
        .canonical_root = try allocator.dupe(u8, repository_path),
    } };
}

fn handoffTestBasis(allocator: std.mem.Allocator, target: committed_review.CommittedReviewTarget) !diff_basis.BranchDiffBasis {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    const display_name = try allocator.dupe(u8, "main");
    errdefer allocator.free(display_name);
    return .{
        .base = .{
            .full_ref = full_ref,
            .display_name = display_name,
            .kind = .local,
        },
        .head_display = try allocator.dupe(u8, "feature"),
        .target = target,
        .ahead_count = 1,
    };
}

fn handoffTestBaseTarget(allocator: std.mem.Allocator) !diff_basis.BaseTarget {
    const full_ref = try allocator.dupe(u8, "refs/heads/main");
    errdefer allocator.free(full_ref);
    return .{
        .full_ref = full_ref,
        .display_name = try allocator.dupe(u8, "main"),
        .kind = .local,
    };
}

test "AI Review Handoff coordinator admits one exact accepted target and rejects stale or absent targets" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repository_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(repository_path);

    var session: repo_session.State = .{};
    defer session.deinit(allocator);
    session.repo_epoch = 7;
    session.repo_state.discovery = try handoffTestDiscovery(allocator, repository_path);
    session.repo_state.root = try root_capability.RootCapability.openCanonical(repository_path);

    const target = handoffTestTarget();
    var page_state: compare_page.ComparePageState = .{};
    defer page_state.deinit(allocator);
    _ = page_state.activate(session.repo_epoch);
    page_state.diff.load.state = .{ .empty = .no_changes };
    page_state.diff.accepted_repository_identity = .{
        .repo_epoch = session.repo_epoch,
        .root_identity = session.repo_state.root.?.identity,
    };
    page_state.basis = try handoffTestBasis(allocator, target);
    page_state.base_target = try handoffTestBaseTarget(allocator);

    const controller: Controller = .{
        .page_state = &page_state,
        .repo = session.view(),
        .layout = .{ .width = 120, .height = 32 },
        .env_map = null,
        .executable_path = "/opt/gitframe/bin/gitframe",
        .handoff_overlay_size = .{ .width = 120, .height = 32 },
    };
    var test_context: chasen.testing.TestCtx(app_message.Msg) = .{};
    defer test_context.resetTransient();

    var opened = try controller.update(&test_context.ctx, .open_ai_review_handoff);
    opened.deinit(allocator);
    const ready = page_state.ai_review_handoff.ready().?;
    try std.testing.expect(ready.snapshot.target.eql(&target));
    const expected_prompt = try allocator.dupe(u8, ready.snapshot.canonical_prompt);
    defer allocator.free(expected_prompt);

    page_state.basis.?.target.head_oid = target.base_oid;
    var copied = try controller.update(&test_context.ctx, .copy_ai_review_handoff);
    const effect = copied.clipboard.?;
    try std.testing.expectEqualStrings(expected_prompt, effect.text);
    try std.testing.expect(effect.text.ptr == page_state.ai_review_handoff.ready().?.snapshot.canonical_prompt.ptr);
    switch (effect.origin) {
        .compare_ai_review_handoff => |origin| {
            try std.testing.expectEqual(page_state.ai_review_handoff.instance_id, origin.modal_instance_id);
            try std.testing.expectEqual(@as(u64, 1), origin.copy_generation);
        },
        else => return error.ExpectedHandoffClipboardOrigin,
    }
    copied.deinit(allocator);

    page_state.diff.accepted_repository_identity.?.repo_epoch += 1;
    var stale = try controller.update(&test_context.ctx, .open_ai_review_handoff);
    stale.deinit(allocator);
    try std.testing.expectEqual(
        @import("ai_review_handoff.zig").UnavailableReason.comparison_unavailable_or_stale,
        page_state.ai_review_handoff.unavailableReason().?,
    );
    try std.testing.expect(page_state.ai_review_handoff.ready() == null);

    page_state.diff.accepted_repository_identity.?.repo_epoch = session.repo_epoch;
    const owned_basis = page_state.basis.?;
    page_state.basis = null;
    var absent = try controller.update(&test_context.ctx, .open_ai_review_handoff);
    absent.deinit(allocator);
    try std.testing.expectEqual(
        @import("ai_review_handoff.zig").UnavailableReason.comparison_unavailable_or_stale,
        page_state.ai_review_handoff.unavailableReason().?,
    );
    page_state.basis = owned_basis;
}
