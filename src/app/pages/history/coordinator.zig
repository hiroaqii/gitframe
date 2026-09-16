//! History catalog task and update coordination.

const std = @import("std");
const chasen = @import("chasen");
const app_load = @import("../../load.zig");
const app_page = @import("../../page.zig");
const repo_session = @import("../../repo_session.zig");
const history_page = @import("../history.zig");

const CatalogTask = app_load.HistoryCatalogTask(@import("../../message.zig").Msg);

pub const Controller = struct {
    page_state: *history_page.HistoryPageState,
    active_page: app_page.Id,
    repo: repo_session.View,
    body_size: chasen.Size,
    env_map: ?*const std.process.Environ.Map,

    pub fn refresh(self: Controller) void {
        self.page_state.requestReload();
    }

    pub fn update(self: Controller, msg: history_page.Msg) void {
        self.page_state.applyInput(msg, self.body_size.height);
    }

    pub fn finish(
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
        self.page_state.arm(.{
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

    fn currentIdentity(self: Controller) ?app_page.RequestIdentity {
        if (self.page_state.activation_id == 0) return null;
        return app_page.RequestIdentity.history(
            self.page_state.repo_epoch,
            self.page_state.activation_id,
        );
    }
};
