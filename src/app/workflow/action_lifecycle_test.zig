const std = @import("std");

const app_actions = @import("../actions.zig");
const changes_page = @import("../pages/changes.zig");
const action_fence = @import("../pages/changes/action_fence.zig");
const action_lifecycle = @import("action_lifecycle.zig");

const Harness = struct {
    runtime: action_lifecycle.ActionRuntime = .{},
    changes: changes_page.ChangesPageState = .{},

    fn controller(self: *Harness) action_lifecycle.Controller {
        return .{
            .runtime = &self.runtime,
            .fence = self.fence(),
        };
    }

    fn fence(self: *Harness) action_fence.Controller {
        return .{
            .read_authority = &self.changes.repository_read_authority,
            .activation = &self.changes.activation,
            .action_cursor = &self.changes.action_cursor,
            .auto_reload = &self.changes.auto_reload,
            .changes_projection = &self.changes.changes_projection,
            .deferred_projection_apply = &self.changes.deferred_projection_apply,
        };
    }

    fn finish(self: *Harness, pending: app_actions.PendingAction) bool {
        return switch (self.controller().finishExact(
            std.testing.allocator,
            pending,
            "",
            null,
        )) {
            .rejected => false,
            .accepted => true,
        };
    }
};

test "action terminal coordinator accepts every exact launched action once" {
    const action_kinds = [_]app_actions.ActionKind{
        .stage_file,
        .unstage_file,
        .stage_hunk,
        .unstage_hunk,
        .discard_file,
        .commit,
        .assist_commit_message,
        .amend,
        .push,
        .pull,
        .fetch,
        .switch_branch,
        .create_stash,
    };
    try std.testing.expectEqual(@typeInfo(app_actions.ActionKind).@"enum".fields.len, action_kinds.len);

    var harness: Harness = .{};
    for (action_kinds) |kind| {
        const prepared = harness.controller().prepare(kind);
        const pending = prepared.pending;
        try std.testing.expect(!harness.finish(pending));
        try std.testing.expect(harness.runtime.view().isCurrent(pending));

        _ = harness.controller().acceptSpawn(std.testing.allocator, prepared);
        try std.testing.expect(harness.finish(pending));
        try std.testing.expect(!harness.finish(pending));
    }

    const current_prepared = harness.controller().prepare(.pull);
    const current = harness.controller().acceptSpawn(std.testing.allocator, current_prepared).pending;
    const stale: app_actions.PendingAction = .{
        .generation = current.generation - 1,
        .kind = .stage_file,
    };

    try std.testing.expect(!harness.finish(stale));
    try std.testing.expect(harness.runtime.view().isAccepted(current));
    try std.testing.expect(harness.finish(current));
}
