const std = @import("std");

const app_actions = @import("../actions.zig");
const review_page = @import("../pages/review.zig");
const action_fence = @import("../pages/review/action_fence.zig");
const action_lifecycle = @import("action_lifecycle.zig");

const Harness = struct {
    runtime: action_lifecycle.ActionRuntime = .{},
    review: review_page.ReviewPageState = .{},

    fn controller(self: *Harness) action_lifecycle.Controller {
        return .{
            .runtime = &self.runtime,
            .fence = self.fence(),
        };
    }

    fn fence(self: *Harness) action_fence.Controller {
        return .{
            .read_authority = &self.review.repository_read_authority,
            .activation = &self.review.activation,
            .action_cursor = &self.review.action_cursor,
            .auto_reload = &self.review.auto_reload,
            .review_projection = &self.review.review_projection,
            .deferred_projection_apply = &self.review.deferred_projection_apply,
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
