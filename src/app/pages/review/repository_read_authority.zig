//! Review repository-read publication and launch authority.
//!
//! This owner is intentionally independent from repository identity and the
//! accepted source-session lifetime. A mutating action can invalidate reads
//! derived from the same repository/source identities, while its closed phase
//! also prevents a replacement read from starting before that action reaches
//! an exact terminal.

const std = @import("std");
const actions = @import("../../actions.zig");
pub const ReviewRepositoryReadEpoch = @import("../../review_read_epoch.zig").ReviewRepositoryReadEpoch;

pub const Phase = union(enum) {
    open,
    mutation_in_flight: actions.PendingAction,
};

/// Page-owned authority for repository-derived reads.
///
/// P6b1 defines and tests this state machine without connecting it to action
/// routes. Runtime fencing is enabled atomically in P6b2d after every request,
/// result, and launch route carries the required vocabulary.
pub const ReviewRepositoryReadAuthority = struct {
    epoch: ReviewRepositoryReadEpoch = .{},
    phase: Phase = .open,

    pub fn mayStartRepositoryRead(self: ReviewRepositoryReadAuthority) bool {
        return self.phase == .open;
    }

    /// Read publication requires both the exact namespace and an open phase.
    pub fn acceptsRead(self: ReviewRepositoryReadAuthority, epoch: ReviewRepositoryReadEpoch) bool {
        return epoch.isValid() and self.mayStartRepositoryRead() and self.epoch.eql(epoch);
    }

    /// Advance and close exactly once for a concrete mutating launch.
    /// Non-mutating assistance and an already-owned mutation are inert.
    pub fn closeForMutation(
        self: *ReviewRepositoryReadAuthority,
        pending: actions.PendingAction,
    ) bool {
        if (!pending.kind.blocksBackgroundAcceptance()) return false;
        if (!self.mayStartRepositoryRead()) return false;
        self.epoch = self.epoch.next();
        self.phase = .{ .mutation_in_flight = pending };
        return true;
    }

    pub fn ownsMutation(
        self: ReviewRepositoryReadAuthority,
        pending: actions.PendingAction,
    ) bool {
        return switch (self.phase) {
            .open => false,
            .mutation_in_flight => |current| exactPending(current, pending),
        };
    }

    /// Only the exact action generation which closed this authority may reopen
    /// it. Stale, mismatched, and duplicate terminals are no-ops.
    pub fn reopenForMutation(
        self: *ReviewRepositoryReadAuthority,
        pending: actions.PendingAction,
    ) bool {
        if (!self.ownsMutation(pending)) return false;
        self.phase = .open;
        return true;
    }
};

fn exactPending(left: actions.PendingAction, right: actions.PendingAction) bool {
    return left.generation == right.generation and left.kind == right.kind;
}

test "repository read epoch is nonzero and skips zero on wrap" {
    const initial: ReviewRepositoryReadEpoch = .{};
    try std.testing.expect(initial.isValid());
    try std.testing.expect(initial.eql(.{ .value = 1 }));
    try std.testing.expect(initial.next().eql(.{ .value = 2 }));

    const wrapped = (ReviewRepositoryReadEpoch{ .value = std.math.maxInt(u64) }).next();
    try std.testing.expect(wrapped.eql(.{ .value = 1 }));
    try std.testing.expect(wrapped.isValid());
}

test "repository read authority closes and reopens only for the exact mutation" {
    var authority: ReviewRepositoryReadAuthority = .{};
    const original_epoch = authority.epoch;
    const owner: actions.PendingAction = .{ .generation = 7, .kind = .stage_hunk };

    try std.testing.expect(authority.mayStartRepositoryRead());
    try std.testing.expect(authority.acceptsRead(original_epoch));
    try std.testing.expect(!authority.acceptsRead(.{ .value = 0 }));
    try std.testing.expect(authority.closeForMutation(owner));
    try std.testing.expect(!authority.mayStartRepositoryRead());
    try std.testing.expect(!authority.acceptsRead(original_epoch));
    try std.testing.expect(!authority.acceptsRead(authority.epoch));
    try std.testing.expect(authority.ownsMutation(owner));
    try std.testing.expect(!authority.closeForMutation(owner));
    try std.testing.expect(!authority.closeForMutation(.{ .generation = 8, .kind = .stage_hunk }));

    try std.testing.expect(!authority.reopenForMutation(.{ .generation = 6, .kind = .stage_hunk }));
    try std.testing.expect(!authority.reopenForMutation(.{ .generation = 7, .kind = .unstage_hunk }));
    try std.testing.expect(!authority.mayStartRepositoryRead());
    try std.testing.expect(authority.reopenForMutation(owner));
    try std.testing.expect(authority.mayStartRepositoryRead());
    try std.testing.expect(authority.acceptsRead(authority.epoch));
    try std.testing.expect(!authority.acceptsRead(original_epoch));
    try std.testing.expect(!authority.reopenForMutation(owner));
}

test "non-mutating assistance cannot close repository read authority" {
    var authority: ReviewRepositoryReadAuthority = .{};
    const epoch = authority.epoch;
    try std.testing.expect(!authority.closeForMutation(.{
        .generation = 3,
        .kind = .assist_commit_message,
    }));
    try std.testing.expect(authority.mayStartRepositoryRead());
    try std.testing.expect(authority.epoch.eql(epoch));
}
