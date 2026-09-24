//! Repository-page task and update coordination.
//!
//! This short-lived controller owns no retained state. It translates page
//! updates into typed shell effects and closes every allocation/spawn terminal
//! for the six Repository read members without access to the root App.

const std = @import("std");
const chasen = @import("chasen");
const app_message = @import("../../message.zig");
const drag_auto_scroll = @import("../../drag_auto_scroll.zig");
const effect_origin = @import("../../effect_origin.zig");
const page = @import("../../page.zig");
const git_command = @import("../../../git/command.zig");
const repo_session = @import("../../repo_session.zig");
const repository_page = @import("../repository.zig");
const repository_tasks = @import("tasks.zig");
const selection_context = @import("../../selection_context.zig");

const ManifestTask = repository_tasks.ManifestTask(app_message.Msg);
const BranchTask = repository_tasks.BranchTask(app_message.Msg);
const PathHistoryTask = repository_tasks.PathHistoryTask(app_message.Msg);
const DocumentTask = repository_tasks.DocumentTask(app_message.Msg);
const SyntaxTask = repository_tasks.SyntaxTask(app_message.Msg);
const ChangeMapTask = repository_tasks.ChangeMapTask(app_message.Msg);

pub const Redraw = enum {
    default,
    skip,
};

pub const ClipboardEffect = struct {
    origin: effect_origin.Origin,
    label: []const u8,
    text: []u8,
    selection_generation: ?u64 = null,

    pub fn deinit(self: *ClipboardEffect, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const UpdateOutcome = struct {
    redraw: Redraw = .default,
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
    page_state: *repository_page.RepositoryPageState,
    active_page: page.Id,
    repo: repo_session.View,
    body_size: chasen.Size,
    env_map: ?*std.process.Environ.Map,

    pub fn update(
        self: Controller,
        ctx: *chasen.Ctx(app_message.Msg),
        msg: repository_page.Msg,
    ) UpdateOutcome {
        switch (msg) {
            .manifest_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.page_state.applyFinished(ctx.allocator(), &owned, self.body_size);
                return .{ .redraw = if (self.active_page != .repository or outcome == .discarded or outcome == .unchanged) .skip else .default };
            },
            .branch_finished => |finished| {
                var owned = finished;
                defer owned.deinit();
                const outcome = self.page_state.applyBranchFinished(ctx.allocator(), &owned);
                const quiet = self.active_page != .repository or outcome == .discarded;
                return .{ .redraw = if (quiet) .skip else .default };
            },
            .path_history_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.page_state.applyPathHistoryFinished(ctx.allocator(), &owned);
                return .{ .redraw = if (self.active_page != .repository or outcome == .discarded) .skip else .default };
            },
            .document_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.page_state.applyDocumentFinished(ctx.allocator(), &owned);
                return .{ .redraw = if (self.active_page != .repository or outcome == .discarded or outcome == .unchanged) .skip else .default };
            },
            .syntax_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.page_state.applySyntaxFinished(ctx.allocator(), &owned);
                return .{ .redraw = if (self.active_page != .repository or outcome != .changed) .skip else .default };
            },
            .change_map_finished => |finished| {
                var owned = finished;
                defer owned.deinit(ctx.allocator());
                const outcome = self.page_state.applyChangeMapFinished(ctx.allocator(), &owned);
                return .{ .redraw = if (self.active_page != .repository or outcome != .changed) .skip else .default };
            },
            else => {
                if (self.active_page != .repository) return .{ .redraw = .skip };
                var page_update = self.page_state.applyNavigation(ctx.allocator(), msg, self.body_size);
                defer page_update.deinit(ctx.allocator());
                const auto_scroll = page_update.auto_scroll;
                const redraw: Redraw = if (page_update.wheel_complete_noop) .skip else .default;
                const command = page_update.takeCommand() orelse return .{ .redraw = redraw, .auto_scroll = auto_scroll };
                return .{ .redraw = redraw, .auto_scroll = auto_scroll, .clipboard = switch (command) {
                    .copy_source_selection => |copy| self.selectionClipboard(ctx.allocator(), copy),
                    .copy_source_header_path => |text| .{
                        .origin = .{ .page = self.effectOrigin() },
                        .label = "file path",
                        .text = text,
                    },
                } };
            },
        }
    }

    fn selectionClipboard(
        self: Controller,
        allocator: std.mem.Allocator,
        copy: repository_page.SelectionCopy,
    ) ?ClipboardEffect {
        if (copy.kind == .code) return .{
            .origin = .{ .page = self.effectOrigin() },
            .label = "source selection",
            .text = copy.text,
            .selection_generation = copy.generation,
        };
        defer allocator.free(copy.text);

        const selected = self.page_state.retainedSourceSelection();
        const root = self.repo.activeRoot();
        const identity = self.repo.activeIdentity();
        if (selected == null or root == null or identity == null or
            copy.generation != self.page_state.selection_generation or
            selected.?.token.repo_epoch != self.repo.epoch() or
            !selected.?.token.root_identity.eql(identity.?))
        {
            _ = self.page_state.applyNavigation(allocator, .{ .selection_action = .clear }, self.body_size);
            self.page_state.status.set("Source selection is no longer current", .{});
            return null;
        }

        const text = selection_context.format(allocator, .{
            .repository_root = root.?,
            .path = selected.?.token.path,
            .first_line = selected.?.source_start,
            .last_line = selected.?.source_end,
        }, copy.text) catch {
            self.page_state.status.set("Could not prepare selection context; press Y to retry", .{});
            return null;
        };
        return .{
            .origin = .{ .page = self.effectOrigin() },
            .label = "selection context",
            .text = text,
            .selection_generation = copy.generation,
        };
    }

    pub fn requestReload(self: Controller, cause: repository_page.RepositoryPageState.ReloadCause) void {
        self.page_state.requestReload(self.repo.activeRoot() != null, cause);
    }

    /// Starts pending members in the established primary/auxiliary order.
    /// Manifest and document failures propagate; bounded auxiliary failures
    /// remain page-local so they cannot fail the primary Repository update.
    pub fn startPending(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !bool {
        var visible_changed = try self.maybeStartManifest(ctx);
        visible_changed = self.maybeStartBranch(ctx) or visible_changed;
        self.maybeStartPathHistory(ctx);
        visible_changed = try self.maybeStartDocument(ctx) or visible_changed;
        try self.maybeStartSyntax(ctx);
        self.maybeStartChangeMap(ctx);
        return visible_changed;
    }

    fn maybeStartManifest(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !bool {
        if (self.active_page != .repository or !self.page_state.wantsManifestRequest()) return false;
        const repo_root = self.repo.activeRoot() orelse {
            self.page_state.requestReload(false, .manual);
            return true;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.requestReload(false, .manual);
            return true;
        };

        var request = self.page_state.prepareRequest(ctx.allocator(), repo_root, capability) catch |err| {
            self.page_state.markRequestPreparationFailed(err);
            return err;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        var environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch |err| {
            self.page_state.rejectSpawn(generation);
            return err;
        };
        var environment_consumed = false;
        defer if (!environment_consumed) environment.deinit();
        const task = ctx.allocator().create(ManifestTask) catch |err| {
            self.page_state.rejectSpawn(generation);
            return err;
        };
        task.* = .{ .request = request, .environment = environment };
        request_consumed = true;
        environment_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = ManifestTask.run, .failed = ManifestTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.rejectSpawn(generation);
            return err;
        };
        return true;
    }

    fn maybeStartDocument(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !bool {
        if (self.active_page != .repository or !self.page_state.wantsDocumentRequest()) return false;
        const displayed_present = self.page_state.displayed_document != null;
        const authority_will_change = if (self.page_state.displayed_document) |document| document.authority == .accepted else false;
        const incoming_will_change = self.page_state.incoming != .none;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markDocumentCapabilityUnavailable();
            return authority_will_change or incoming_will_change;
        };
        var request = self.page_state.prepareDocumentRequest(ctx.allocator(), capability) catch |err| {
            self.page_state.markDocumentRequestPreparationFailed(err);
            return err;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(DocumentTask) catch |err| {
            self.page_state.rejectDocumentSpawn(generation);
            return err;
        };
        task.* = .{ .request = request };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = DocumentTask.run, .failed = DocumentTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.rejectDocumentSpawn(generation);
            return err;
        };
        return displayed_present or incoming_will_change;
    }

    fn maybeStartBranch(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) bool {
        if (self.active_page != .repository or !self.page_state.wantsBranchRequest()) return false;
        const freshness_before = self.page_state.branch.freshness;
        const repo_root = self.repo.activeRoot() orelse {
            self.page_state.markBranchRequestPreparationFailed();
            return !std.meta.eql(freshness_before, self.page_state.branch.freshness);
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markBranchRequestPreparationFailed();
            return !std.meta.eql(freshness_before, self.page_state.branch.freshness);
        };

        var request = self.page_state.prepareBranchRequest(ctx.allocator(), repo_root, capability) catch {
            self.page_state.markBranchRequestPreparationFailed();
            return !std.meta.eql(freshness_before, self.page_state.branch.freshness);
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(BranchTask) catch {
            self.page_state.rejectBranchSpawn(generation);
            return !std.meta.eql(freshness_before, self.page_state.branch.freshness);
        };
        task.* = .{ .request = request, .env_map = self.env_map };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = BranchTask.run, .failed = BranchTask.failed }) catch {
            task.destroy(ctx.allocator());
            self.page_state.rejectBranchSpawn(generation);
        };
        return !std.meta.eql(freshness_before, self.page_state.branch.freshness);
    }

    fn maybeStartPathHistory(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) void {
        if (self.active_page != .repository or !self.page_state.wantsPathHistoryRequest()) return;
        const repo_root = self.repo.activeRoot() orelse {
            self.page_state.markPathHistoryRequestPreparationFailed();
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markPathHistoryRequestPreparationFailed();
            return;
        };

        var request = self.page_state.preparePathHistoryRequest(ctx.allocator(), repo_root, capability) catch {
            self.page_state.markPathHistoryRequestPreparationFailed();
            return;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        var environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch {
            self.page_state.rejectPathHistorySpawn(generation);
            return;
        };
        var environment_consumed = false;
        defer if (!environment_consumed) environment.deinit();
        const task = ctx.allocator().create(PathHistoryTask) catch {
            self.page_state.rejectPathHistorySpawn(generation);
            return;
        };
        task.* = .{ .request = request, .environment = environment };
        request_consumed = true;
        environment_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = PathHistoryTask.run, .failed = PathHistoryTask.failed }) catch {
            task.destroy(ctx.allocator());
            self.page_state.rejectPathHistorySpawn(generation);
        };
    }

    fn maybeStartSyntax(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .repository or !self.page_state.wantsSyntaxRequest()) return;
        const capability = self.repo.activeCapability() orelse return;
        var request = self.page_state.prepareSyntaxRequest(ctx.allocator(), capability) catch {
            self.page_state.markSyntaxRequestPreparationFailed();
            return;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(SyntaxTask) catch {
            self.page_state.rejectSyntaxSpawn(generation);
            return;
        };
        task.* = .{ .request = request };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = SyntaxTask.run, .failed = SyntaxTask.failed }) catch {
            task.destroy(ctx.allocator());
            self.page_state.rejectSyntaxSpawn(generation);
        };
    }

    fn maybeStartChangeMap(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) void {
        if (self.active_page != .repository or !self.page_state.wantsChangeMapRequest()) return;
        const capability = self.repo.activeCapability() orelse return;
        var request = self.page_state.prepareChangeMapRequest(
            ctx.allocator(),
            capability,
            self.changeTempBase(),
        ) catch {
            self.page_state.markChangeMapRequestPreparationFailed();
            return;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        var environment = git_command.LocalGitEnvironment.initFromParent(ctx.allocator(), self.env_map) catch {
            self.page_state.rejectChangeMapSpawn(generation);
            return;
        };
        var environment_consumed = false;
        defer if (!environment_consumed) environment.deinit();
        const task = ctx.allocator().create(ChangeMapTask) catch {
            self.page_state.rejectChangeMapSpawn(generation);
            return;
        };
        task.* = .{ .request = request, .environment = environment };
        request_consumed = true;
        environment_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = ChangeMapTask.run, .failed = ChangeMapTask.failed }) catch {
            task.destroy(ctx.allocator());
            self.page_state.rejectChangeMapSpawn(generation);
        };
    }

    fn changeTempBase(self: Controller) []const u8 {
        const map = self.env_map orelse return "/tmp";
        const configured = map.get("XDG_RUNTIME_DIR") orelse return "/tmp";
        return if (std.fs.path.isAbsolute(configured)) configured else "/tmp";
    }

    fn effectOrigin(self: Controller) effect_origin.PageOrigin {
        return .{
            .page_id = .repository,
            .repo_epoch = self.page_state.repo_epoch,
            .activation_id = self.page_state.activation_id,
        };
    }
};
