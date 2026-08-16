//! Changes-owned boundary between mutating actions and repository-derived
//! reads. The action lifecycle may close or reopen the exact mutation owner;
//! read coordination receives only the corresponding read-only view.

const std = @import("std");
const app_actions = @import("../../actions.zig");
const app_auto_reload = @import("../../auto_reload.zig");
const diff_authority = @import("../../diff_surface/authority.zig");
const app_changes_projection = @import("../../changes_projection.zig");
const changes_page = @import("../changes.zig");

pub const ReloadIntent = union(enum) {
    none,
    source_and_aux,
    source_and_aux_clear_visible,
    status: []const u8,
};

pub const View = struct {
    read_authority: *const changes_page.repository_read_authority.ChangesRepositoryReadAuthority,
    activation: *const diff_authority.Lifecycle,
    action_cursor: *const changes_page.action_cursor.State,

    pub fn mayStartRepositoryRead(self: View) bool {
        return self.read_authority.mayStartRepositoryRead();
    }

    pub fn blocksBackgroundAcceptance(self: View, background_cycle_id: ?u64) bool {
        _ = background_cycle_id orelse return false;
        return !self.read_authority.mayStartRepositoryRead();
    }

    pub fn hasActionCursor(self: View) bool {
        return self.action_cursor.hasOwner();
    }

    pub fn hasQueuedFullRevalidation(self: View) bool {
        return self.activation.hasQueuedFullRevalidation();
    }
};

pub const Controller = struct {
    read_authority: *changes_page.repository_read_authority.ChangesRepositoryReadAuthority,
    activation: *diff_authority.Lifecycle,
    action_cursor: *changes_page.action_cursor.State,
    auto_reload: *app_auto_reload.State,
    changes_projection: *app_changes_projection.State,
    deferred_projection_apply: *?changes_page.DeferredProjectionApply,

    pub fn view(self: Controller) View {
        return .{
            .read_authority = self.read_authority,
            .activation = self.activation,
            .action_cursor = self.action_cursor,
        };
    }

    /// Closes the read epoch only after the matching mutation launch has been
    /// accepted, while retaining the currently displayed body.
    pub fn closeForAcceptedMutation(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
    ) bool {
        if (!self.read_authority.closeForMutation(pending)) return false;

        self.auto_reload.supersedeActiveCycleByMutation();
        self.changes_projection.clearPending(allocator);
        self.changes_projection.clearSyntaxPending(allocator);
        if (self.deferred_projection_apply.*) |*deferred| deferred.deinit(allocator);
        self.deferred_projection_apply.* = null;
        return true;
    }

    /// Reopens only the exact mutation owner and queues its activation-scoped
    /// fallback before the action runtime retires the token.
    pub fn reopenForExactTerminal(
        self: Controller,
        pending: app_actions.PendingAction,
    ) bool {
        if (!self.read_authority.reopenForMutation(pending)) return false;
        self.activation.queueActionTerminalRevalidation();
        return true;
    }

    pub fn clearMatchingActionCursor(
        self: Controller,
        allocator: std.mem.Allocator,
        generation: u64,
    ) bool {
        return self.action_cursor.clearMatchingAction(allocator, generation);
    }

    pub fn discardDetachedTerminal(
        self: Controller,
        allocator: std.mem.Allocator,
        pending: app_actions.PendingAction,
    ) void {
        _ = self.clearMatchingActionCursor(allocator, pending.generation);
        self.activation.discardTerminalRevalidation();
    }
};
