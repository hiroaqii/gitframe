//! Review action authority vocabulary introduced by Phase 9 A3.
//!
//! A3 derives this vector from the currently reachable Review state so existing
//! action behavior remains unchanged. Phase 9 C will make activation identity and
//! deactivation/re-entry transitions persistent runtime state.

const std = @import("std");
const auto_reload = @import("../../auto_reload.zig");

pub const MemberFreshness = enum {
    pending,
    fresh,
    failed,
    immutable,
    unavailable,

    pub fn satisfies(self: MemberFreshness, requirement: Requirement) bool {
        return switch (requirement) {
            .unused => true,
            .readable => self == .fresh or self == .immutable,
            .fresh => self == .fresh,
        };
    }
};

pub const Requirement = enum {
    unused,
    readable,
    fresh,
};

pub const Requirements = struct {
    source: Requirement = .unused,
    status: Requirement = .unused,
    branch: Requirement = .unused,
};

/// Review operations name the members they actually consume. Keeping this
/// table separate from target construction prevents a later page activation
/// change from accidentally turning an unrelated member failure into a global
/// Review lockout.
pub const Action = enum {
    read_diff,
    stage_file,
    unstage_file,
    discard_file,
    stage_hunk,
    unstage_hunk,
    commit,
    push,
    pull,
    fetch,
    switch_branch,

    pub fn requirements(self: Action) Requirements {
        return switch (self) {
            .read_diff => .{ .source = .readable },
            .stage_hunk, .unstage_hunk => .{ .source = .fresh, .status = .fresh },
            .stage_file, .unstage_file, .discard_file, .commit => .{ .source = .fresh, .status = .fresh },
            .push, .fetch => .{ .branch = .fresh },
            .pull, .switch_branch => .{ .status = .fresh, .branch = .fresh },
        };
    }
};

pub const MemberVector = struct {
    source: MemberFreshness,
    status: MemberFreshness,
    branch: MemberFreshness,

    pub fn satisfies(self: MemberVector, requirements: Requirements) bool {
        return self.source.satisfies(requirements.source) and
            self.status.satisfies(requirements.status) and
            self.branch.satisfies(requirements.branch);
    }
};

pub const ActivationState = union(enum) {
    inactive,
    active: struct {
        activation_id: u64,
        repo_epoch: u64,
        members: MemberVector,
    },

    pub fn members(self: ActivationState) ?MemberVector {
        return switch (self) {
            .inactive => null,
            .active => |active| active.members,
        };
    }

    pub fn satisfies(self: ActivationState, requirements: Requirements) bool {
        const vector = self.members() orelse return false;
        return vector.satisfies(requirements);
    }
};

pub fn fromCurrent(
    repo_epoch: u64,
    source: MemberFreshness,
    status: auto_reload.AuxiliaryTracker,
    branch: auto_reload.AuxiliaryTracker,
) ActivationState {
    return .{
        .active = .{
            // Review is the only reachable page in A3. C replaces this compatibility
            // identity with a monotonically increasing activation id.
            .activation_id = 0,
            .repo_epoch = repo_epoch,
            .members = .{
                .source = source,
                .status = auxiliaryMember(status),
                .branch = auxiliaryMember(branch),
            },
        },
    };
}

pub fn auxiliaryMember(tracker: auto_reload.AuxiliaryTracker) MemberFreshness {
    if (tracker.isPending()) return .pending;
    return switch (tracker.freshness) {
        .fresh => .fresh,
        .missing => .unavailable,
        .stale_refresh => .failed,
    };
}

test "authority requirements inspect only consumed members" {
    const vector: MemberVector = .{
        .source = .fresh,
        .status = .failed,
        .branch = .fresh,
    };
    try std.testing.expect(vector.satisfies(.{ .source = .readable }));
    try std.testing.expect(vector.satisfies(.{ .branch = .fresh }));
    try std.testing.expect(!vector.satisfies(.{ .source = .fresh, .status = .fresh }));
}

test "immutable source satisfies readable but not mutable authority" {
    const vector: MemberVector = .{
        .source = .immutable,
        .status = .unavailable,
        .branch = .unavailable,
    };
    try std.testing.expect(vector.satisfies(.{ .source = .readable }));
    try std.testing.expect(!vector.satisfies(.{ .source = .fresh }));
}

test "current A3 activation derives auxiliary member states" {
    var status: auto_reload.AuxiliaryTracker = .{};
    status.freshness = .stale_refresh;
    var branch: auto_reload.AuxiliaryTracker = .{};
    branch.begin(null);

    const activation = fromCurrent(7, .fresh, status, branch);
    const active = activation.active;
    try std.testing.expectEqual(@as(u64, 0), active.activation_id);
    try std.testing.expectEqual(@as(u64, 7), active.repo_epoch);
    try std.testing.expectEqual(MemberFreshness.failed, active.members.status);
    try std.testing.expectEqual(MemberFreshness.pending, active.members.branch);
}

test "action requirements do not globally couple auxiliary members" {
    try std.testing.expectEqual(
        Requirements{ .branch = .fresh },
        Action.push.requirements(),
    );
    try std.testing.expectEqual(
        Requirements{ .status = .fresh, .branch = .fresh },
        Action.pull.requirements(),
    );
    try std.testing.expectEqual(
        Requirements{ .source = .readable },
        Action.read_diff.requirements(),
    );
}
