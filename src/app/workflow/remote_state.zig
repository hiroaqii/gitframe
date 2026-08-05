//! Owned state shared by the remote workflow controller and repository
//! replacement invalidation. The state vocabulary is lower-level than either
//! coordinator, so both callers keep typed access without importing a peer.

const std = @import("std");

const app_push_retry = @import("../push_retry.zig");
const app_state = @import("../state.zig");

pub const State = struct {
    push_confirmation: ?app_state.PushConfirmation = null,
    pull_confirmation: ?app_state.PullConfirmation = null,
    push_error_message: ?[]u8 = null,
    push_retry: app_push_retry.Model = .{},
    branch_switch: app_state.BranchSwitchState = .{},
    branch_switch_load_generation: u64 = 0,
    branch_switch_load_pending: ?u64 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.push_confirmation) |*confirmation| confirmation.deinit(allocator);
        if (self.pull_confirmation) |*confirmation| confirmation.deinit(allocator);
        self.push_retry.deinit(allocator);
        if (self.push_error_message) |message| allocator.free(message);
        if (self.branch_switch.hasState()) self.branch_switch.deinit(allocator);
        self.* = .{};
    }

    pub fn repositoryInvalidationPort(
        self: *State,
        overlay: *app_state.OverlayState,
    ) RepositoryInvalidationPort {
        return .{ .state = self, .overlay = overlay };
    }

    pub fn clearBranchSwitch(
        self: *State,
        allocator: std.mem.Allocator,
        overlay: *app_state.OverlayState,
    ) void {
        if (self.branch_switch.hasState()) self.branch_switch.deinit(allocator);
        self.branch_switch_load_pending = null;
        if (overlay.isSwitchBranch()) overlay.close();
    }

    fn invalidateBeforeRepositoryReplacement(
        self: *State,
        allocator: std.mem.Allocator,
        overlay: *app_state.OverlayState,
    ) void {
        if (self.push_error_message) |message| allocator.free(message);
        self.push_error_message = null;
        if (overlay.isPushError() or overlay.isPushCredentials()) overlay.close();
        switch (self.push_retry.state) {
            .available, .inspecting, .credential_prompt => self.push_retry.state.deinit(allocator),
            .idle, .foreground => {},
        }
        self.clearBranchSwitch(allocator, overlay);
    }
};

/// Narrow synchronous capability for repository-session invalidation. The
/// root composes this short-lived port; consumers cannot reach unrelated
/// remote workflow operations or retain a whole application context.
pub const RepositoryInvalidationPort = struct {
    state: *State,
    overlay: *app_state.OverlayState,

    pub fn clearBranchSwitch(
        self: RepositoryInvalidationPort,
        allocator: std.mem.Allocator,
    ) void {
        self.state.clearBranchSwitch(allocator, self.overlay);
    }

    pub fn invalidateBeforeRepositoryReplacement(
        self: RepositoryInvalidationPort,
        allocator: std.mem.Allocator,
    ) void {
        self.state.invalidateBeforeRepositoryReplacement(allocator, self.overlay);
    }
};
