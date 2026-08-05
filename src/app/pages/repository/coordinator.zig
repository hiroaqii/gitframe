//! Repository-page task and update coordination.
//!
//! This short-lived controller owns no retained state. It translates page
//! updates into typed shell effects and closes every allocation/spawn terminal
//! for the five Repository read members without access to the root App.

const std = @import("std");
const chasen = @import("chasen");
const app_message = @import("../../message.zig");
const effect_origin = @import("../../effect_origin.zig");
const page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const repository_page = @import("../repository.zig");

const ManifestTask = repository_page.ManifestTask(app_message.Msg);
const BranchTask = repository_page.BranchTask(app_message.Msg);
const DocumentTask = repository_page.DocumentTask(app_message.Msg);
const SyntaxTask = repository_page.SyntaxTask(app_message.Msg);
const ChangeMapTask = repository_page.ChangeMapTask(app_message.Msg);

pub const Redraw = enum {
    default,
    skip,
};

pub const ClipboardEffect = struct {
    origin: effect_origin.Origin,
    label: []const u8,
    text: []u8,

    pub fn deinit(self: *ClipboardEffect, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const UpdateOutcome = struct {
    redraw: Redraw = .default,
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
                const outcome = self.page_state.applyBranchFinished(&owned);
                const quiet = self.active_page != .repository or switch (outcome) {
                    .changed, .failed => false,
                    .discarded, .unchanged => true,
                };
                return .{ .redraw = if (quiet) .skip else .default };
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
                const command = page_update.takeCommand() orelse return .{};
                return .{ .clipboard = switch (command) {
                    .copy_source_selection => |text| .{
                        .origin = .{ .page = self.effectOrigin() },
                        .label = "source selection",
                        .text = text,
                    },
                    .copy_source_header_path => |text| .{
                        .origin = .{ .page = self.effectOrigin() },
                        .label = "file path",
                        .text = text,
                    },
                } };
            },
        }
    }

    pub fn requestReload(self: Controller) void {
        self.page_state.requestReload(self.repo.activeRoot() != null);
    }

    /// Starts pending members in the established primary/auxiliary order.
    /// Manifest and document failures propagate; bounded auxiliary failures
    /// remain page-local so they cannot fail the primary Repository update.
    pub fn startPending(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        try self.maybeStartManifest(ctx);
        self.maybeStartBranch(ctx);
        try self.maybeStartDocument(ctx);
        try self.maybeStartSyntax(ctx);
        self.maybeStartChangeMap(ctx);
    }

    fn maybeStartManifest(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .repository or !self.page_state.wantsManifestRequest()) return;
        const repo_root = self.repo.activeRoot() orelse {
            self.page_state.requestReload(false);
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.requestReload(false);
            return;
        };

        var request = self.page_state.prepareRequest(ctx.allocator(), repo_root, capability) catch |err| {
            self.page_state.markRequestPreparationFailed(err);
            return err;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(ManifestTask) catch |err| {
            self.page_state.rejectSpawn(generation);
            return err;
        };
        task.* = .{ .request = request };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = ManifestTask.run, .failed = ManifestTask.failed }) catch |err| {
            task.destroy(ctx.allocator());
            self.page_state.rejectSpawn(generation);
            return err;
        };
    }

    fn maybeStartDocument(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) !void {
        if (self.active_page != .repository or !self.page_state.wantsDocumentRequest()) return;
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markDocumentCapabilityUnavailable();
            return;
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
    }

    fn maybeStartBranch(self: Controller, ctx: *chasen.Ctx(app_message.Msg)) void {
        if (self.active_page != .repository or !self.page_state.wantsBranchRequest()) return;
        const repo_root = self.repo.activeRoot() orelse {
            self.page_state.markBranchRequestPreparationFailed();
            return;
        };
        const capability = self.repo.activeCapability() orelse {
            self.page_state.markBranchRequestPreparationFailed();
            return;
        };

        var request = self.page_state.prepareBranchRequest(ctx.allocator(), repo_root, capability) catch {
            self.page_state.markBranchRequestPreparationFailed();
            return;
        };
        var request_consumed = false;
        defer if (!request_consumed) request.deinit(ctx.allocator());
        const generation = request.generation;
        const task = ctx.allocator().create(BranchTask) catch {
            self.page_state.rejectBranchSpawn(generation);
            return;
        };
        task.* = .{ .request = request, .env_map = self.env_map };
        request_consumed = true;
        ctx.task().spawnWith(.{ .ctx = task, .run = BranchTask.run, .failed = BranchTask.failed }) catch {
            task.request.deinit(ctx.allocator());
            ctx.allocator().destroy(task);
            self.page_state.rejectBranchSpawn(generation);
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
        const task = ctx.allocator().create(ChangeMapTask) catch {
            self.page_state.rejectChangeMapSpawn(generation);
            return;
        };
        task.* = .{ .request = request };
        request_consumed = true;
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
