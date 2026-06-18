const std = @import("std");

/// Git operation categories that can become App-facing actions.
///
/// This is intentionally a taxonomy, not an executable backend API. Concrete
/// requests/results live next to the first implementation of each operation.
pub const ActionKind = enum {
    refresh_status,
    stage_file,
    unstage_file,
    stage_hunk,
    unstage_hunk,
    discard_file,
    commit,
    amend,
    push,
    pull,
    switch_branch,
};

pub const PendingAction = struct {
    generation: u64,
    kind: ActionKind,
};

/// Small App-facing receiver for future Git actions.
///
/// Keep this limited to in-flight ownership. Result text remains in App's
/// status message until concrete operation result ownership exists.
pub const ActionState = struct {
    pending: ?PendingAction = null,
    generation: u64 = 0,

    pub fn begin(self: *ActionState, kind: ActionKind) PendingAction {
        self.generation +%= 1;
        const pending: PendingAction = .{
            .generation = self.generation,
            .kind = kind,
        };
        self.pending = pending;
        return pending;
    }

    pub fn isCurrent(self: *const ActionState, pending: PendingAction) bool {
        const current = self.pending orelse return false;
        return current.generation == pending.generation and current.kind == pending.kind;
    }

    pub fn finish(self: *ActionState, pending: PendingAction) bool {
        if (!self.isCurrent(pending)) return false;
        self.pending = null;
        return true;
    }

    pub fn clear(self: *ActionState) void {
        self.pending = null;
    }
};

test "ActionState tracks current pending action" {
    var state: ActionState = .{};

    const first = state.begin(.refresh_status);
    try std.testing.expect(state.isCurrent(first));

    const second = state.begin(.stage_file);
    try std.testing.expect(!state.isCurrent(first));
    try std.testing.expect(state.isCurrent(second));

    try std.testing.expect(!state.finish(first));
    try std.testing.expect(state.finish(second));
    try std.testing.expect(state.pending == null);
}
