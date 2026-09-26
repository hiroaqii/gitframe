//! Changes repository-read publication and launch authority.
//!
//! This owner is intentionally independent from repository identity and the
//! accepted source-session lifetime. A mutating action can invalidate reads
//! derived from the same repository/source identities, while its closed phase
//! also prevents a replacement read from starting before that action reaches
//! an exact terminal.

const std = @import("std");
const actions = @import("../../actions.zig");
pub const ChangesRepositoryReadEpoch = @import("../../changes_read_epoch.zig").ChangesRepositoryReadEpoch;

pub const Phase = union(enum) {
    open,
    mutation_in_flight: actions.PendingAction,
};

/// Page-owned authority for repository-derived reads.
///
/// The App action coordinator closes this owner only after a concrete mutating
/// task or foreground command is accepted, and reopens it only for that exact
/// action terminal. Every repository-derived read and publication gate uses
/// the epoch plus phase together.
pub const ChangesRepositoryReadAuthority = struct {
    epoch: ChangesRepositoryReadEpoch = .{},
    phase: Phase = .open,

    pub fn mayStartRepositoryRead(self: ChangesRepositoryReadAuthority) bool {
        return self.phase == .open;
    }

    /// Read publication requires both the exact namespace and an open phase.
    pub fn acceptsRead(self: ChangesRepositoryReadAuthority, epoch: ChangesRepositoryReadEpoch) bool {
        return epoch.isValid() and self.mayStartRepositoryRead() and self.epoch.eql(epoch);
    }

    /// Advance and close exactly once for a concrete mutating launch.
    /// Non-mutating assistance and an already-owned mutation are inert.
    pub fn closeForMutation(
        self: *ChangesRepositoryReadAuthority,
        pending: actions.PendingAction,
    ) bool {
        if (!pending.kind.blocksBackgroundAcceptance()) return false;
        if (!self.mayStartRepositoryRead()) return false;
        self.epoch = self.epoch.next();
        self.phase = .{ .mutation_in_flight = pending };
        return true;
    }

    pub fn ownsMutation(
        self: ChangesRepositoryReadAuthority,
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
        self: *ChangesRepositoryReadAuthority,
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
    const initial: ChangesRepositoryReadEpoch = .{};
    try std.testing.expect(initial.isValid());
    try std.testing.expect(initial.eql(.{ .value = 1 }));
    try std.testing.expect(initial.next().eql(.{ .value = 2 }));

    const wrapped = (ChangesRepositoryReadEpoch{ .value = std.math.maxInt(u64) }).next();
    try std.testing.expect(wrapped.eql(.{ .value = 1 }));
    try std.testing.expect(wrapped.isValid());
}

test "repository read authority closes and reopens only for the exact mutation" {
    var authority: ChangesRepositoryReadAuthority = .{};
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
