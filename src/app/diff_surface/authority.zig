//! Shared diff-page action authority vocabulary.
//!
//! Requirements are evaluated against the current page activation and member
//! freshness vector. Every diff page retains independent lifecycle state.

const std = @import("std");
const auto_reload = @import("../auto_reload.zig");
const page = @import("../page.zig");

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

/// Changes operations name the members they actually consume. Keeping this
/// table separate from target construction prevents a later page activation
/// change from accidentally turning an unrelated member failure into a global
/// Changes lockout.
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

    pub fn satisfiesAction(self: ActivationState, action: Action) bool {
        return self.satisfies(action.requirements());
    }
};

pub const Member = enum {
    source,
    status,
    branch,
};

/// The diff pages which may own this lifecycle.
///
/// Keeping this narrower than `page.Id` prevents Repository or Config request
/// identities from being admitted accidentally.
pub const Owner = enum {
    changes,
    compare,
    ai_reviews,

    fn identity(self: Owner, repo_epoch: u64, activation_id: u64) page.RequestIdentity {
        return switch (self) {
            .changes => page.RequestIdentity.changes(repo_epoch, activation_id),
            .compare => page.RequestIdentity.compare(repo_epoch, activation_id),
            .ai_reviews => page.RequestIdentity.aiReviews(repo_epoch, activation_id),
        };
    }

    fn matches(self: Owner, origin: page.Id) bool {
        return switch (self) {
            .changes => origin == .changes,
            .compare => origin == .compare,
            .ai_reviews => origin == .ai_reviews,
        };
    }
};

/// Persistent diff-page activation owner.
///
/// Retained documents and reload fingerprints live outside this value. Leaving
/// the owning page therefore revokes action authority without destroying last-good
/// display state. A completion may mutate its retained page owner only when
/// its repo epoch, activation id, and page origin identify the latest instance.
pub const Lifecycle = struct {
    owner: Owner,
    state: ActivationState = .inactive,
    next_activation_id: u64 = 0,
    revalidation_requested: ?u64 = null,
    action_terminal_revalidation_requested: ?u64 = null,

    pub fn init(owner: Owner) Lifecycle {
        return .{ .owner = owner };
    }

    pub fn activate(
        self: *Lifecycle,
        repo_epoch: u64,
        source: MemberFreshness,
        status: MemberFreshness,
        branch: MemberFreshness,
    ) u64 {
        self.next_activation_id +%= 1;
        if (self.next_activation_id == 0) self.next_activation_id = 1;
        const activation_id = self.next_activation_id;
        self.state = .{ .active = .{
            .activation_id = activation_id,
            .repo_epoch = repo_epoch,
            .members = .{ .source = source, .status = status, .branch = branch },
        } };
        self.revalidation_requested = null;
        self.action_terminal_revalidation_requested = null;
        return activation_id;
    }

    /// Re-enters a retained page without minting a new request owner.
    ///
    /// AI Reviews uses this when a direct refresh may finish while the page is
    /// hidden. The completion remains owned by the same page instance, while
    /// repository replacement still changes the epoch and rejects it.
    pub fn reactivateRetained(
        self: *Lifecycle,
        repo_epoch: u64,
        source: MemberFreshness,
        status: MemberFreshness,
        branch: MemberFreshness,
    ) u64 {
        std.debug.assert(self.next_activation_id != 0);
        const activation_id = self.next_activation_id;
        self.state = .{ .active = .{
            .activation_id = activation_id,
            .repo_epoch = repo_epoch,
            .members = .{ .source = source, .status = status, .branch = branch },
        } };
        self.revalidation_requested = null;
        self.action_terminal_revalidation_requested = null;
        return activation_id;
    }

    pub fn deactivate(self: *Lifecycle) void {
        self.state = .inactive;
        self.revalidation_requested = null;
        self.action_terminal_revalidation_requested = null;
    }

    pub fn currentIdentity(self: Lifecycle) ?page.RequestIdentity {
        return switch (self.state) {
            .inactive => null,
            .active => |active| self.owner.identity(active.repo_epoch, active.activation_id),
        };
    }

    pub fn queueRevalidation(self: *Lifecycle) void {
        self.revalidation_requested = switch (self.state) {
            .inactive => null,
            .active => |active| active.activation_id,
        };
    }

    pub fn queueActionTerminalRevalidation(self: *Lifecycle) void {
        self.action_terminal_revalidation_requested = switch (self.state) {
            .inactive => null,
            .active => |active| active.activation_id,
        };
    }

    pub fn hasQueuedFullRevalidation(self: Lifecycle) bool {
        const activation_id = switch (self.state) {
            .inactive => return false,
            .active => |active| active.activation_id,
        };
        return self.revalidation_requested == activation_id or
            self.action_terminal_revalidation_requested == activation_id;
    }

    pub fn consumeAcceptedFullRevalidation(self: *Lifecycle) void {
        const activation_id = switch (self.state) {
            .inactive => return,
            .active => |active| active.activation_id,
        };
        if (self.revalidation_requested == activation_id) {
            self.revalidation_requested = null;
        }
        if (self.action_terminal_revalidation_requested == activation_id) {
            self.action_terminal_revalidation_requested = null;
        }
    }

    pub fn consumeAcceptedTerminalRevalidation(self: *Lifecycle) void {
        const activation_id = switch (self.state) {
            .inactive => return,
            .active => |active| active.activation_id,
        };
        if (self.action_terminal_revalidation_requested == activation_id) {
            self.action_terminal_revalidation_requested = null;
        }
    }

    pub fn discardTerminalRevalidation(self: *Lifecycle) void {
        self.consumeAcceptedTerminalRevalidation();
    }

    pub fn markPending(self: *Lifecycle, member: Member) void {
        switch (self.state) {
            .inactive => {},
            .active => |*active| memberPtr(&active.members, member).* = .pending,
        }
    }

    pub fn finishMember(
        self: *Lifecycle,
        identity: page.RequestIdentity,
        member: Member,
        freshness: MemberFreshness,
    ) bool {
        if (!self.owner.matches(identity.origin)) return false;
        switch (self.state) {
            .inactive => return false,
            .active => |*active| {
                if (active.repo_epoch != identity.repo_epoch or active.activation_id != identity.activation_id) return false;
                memberPtr(&active.members, member).* = freshness;
                return true;
            },
        }
    }

    pub fn acceptsRepoEpoch(self: Lifecycle, identity: page.RequestIdentity, repo_epoch: u64) bool {
        return self.owner.matches(identity.origin) and identity.repo_epoch == repo_epoch;
    }

    /// Accepts work issued by the latest activation of this page instance,
    /// including its retained inactive state, but rejects work from an older
    /// activation after the page has been reopened in the same repository.
    pub fn acceptsPageInstance(self: Lifecycle, identity: page.RequestIdentity, repo_epoch: u64) bool {
        return self.owner.matches(identity.origin) and
            identity.repo_epoch == repo_epoch and
            identity.activation_id != 0 and
            identity.activation_id == self.next_activation_id;
    }

    fn memberPtr(vector: *MemberVector, member: Member) *MemberFreshness {
        return switch (member) {
            .source => &vector.source,
            .status => &vector.status,
            .branch => &vector.branch,
        };
    }
};

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

test "lifecycle rejects completion from an older activation" {
    var lifecycle = Lifecycle.init(.changes);
    const first = lifecycle.activate(4, .pending, .pending, .pending);
    lifecycle.deactivate();
    const second = lifecycle.activate(4, .pending, .pending, .pending);
    try std.testing.expect(first != second);
    try std.testing.expect(!lifecycle.finishMember(page.RequestIdentity.changes(4, first), .source, .fresh));
    try std.testing.expect(lifecycle.finishMember(page.RequestIdentity.changes(4, second), .source, .fresh));
    try std.testing.expect(lifecycle.state.satisfiesAction(.read_diff));
}

test "lifecycle identity authority is isolated by diff page owner" {
    var changes = Lifecycle.init(.changes);
    const changes_activation = changes.activate(4, .pending, .pending, .pending);
    const changes_identity = changes.currentIdentity().?;
    const compare_for_changes = page.RequestIdentity.compare(4, changes_activation);
    try std.testing.expectEqual(page.Id.changes, changes_identity.origin);
    try std.testing.expect(changes.finishMember(changes_identity, .source, .fresh));
    try std.testing.expect(!changes.finishMember(compare_for_changes, .source, .failed));
    try std.testing.expect(changes.acceptsRepoEpoch(changes_identity, 4));
    try std.testing.expect(!changes.acceptsRepoEpoch(compare_for_changes, 4));

    var compare = Lifecycle.init(.compare);
    const compare_activation = compare.activate(4, .pending, .unavailable, .unavailable);
    const compare_identity = compare.currentIdentity().?;
    const changes_for_compare = page.RequestIdentity.changes(4, compare_activation);
    const ai_for_compare = page.RequestIdentity.aiReviews(4, compare_activation);
    try std.testing.expectEqual(page.Id.compare, compare_identity.origin);
    try std.testing.expect(compare.finishMember(compare_identity, .source, .immutable));
    try std.testing.expect(!compare.finishMember(changes_for_compare, .source, .failed));
    try std.testing.expect(!compare.finishMember(ai_for_compare, .source, .failed));
    try std.testing.expect(compare.acceptsRepoEpoch(compare_identity, 4));
    try std.testing.expect(!compare.acceptsRepoEpoch(changes_for_compare, 4));

    var ai_reviews = Lifecycle.init(.ai_reviews);
    _ = ai_reviews.activate(4, .unavailable, .unavailable, .unavailable);
    const ai_identity = ai_reviews.currentIdentity().?;
    try std.testing.expectEqual(page.Id.ai_reviews, ai_identity.origin);
    try std.testing.expect(!ai_reviews.acceptsRepoEpoch(compare_identity, 4));
}

test "retained reactivation preserves page-instance completion authority" {
    var lifecycle = Lifecycle.init(.ai_reviews);
    const activation_id = lifecycle.activate(4, .immutable, .unavailable, .unavailable);
    const identity = lifecycle.currentIdentity().?;
    lifecycle.deactivate();

    try std.testing.expect(lifecycle.acceptsPageInstance(identity, 4));
    try std.testing.expectEqual(
        activation_id,
        lifecycle.reactivateRetained(4, .pending, .unavailable, .unavailable),
    );
    try std.testing.expect(std.meta.eql(identity, lifecycle.currentIdentity().?));
    try std.testing.expect(!lifecycle.acceptsPageInstance(identity, 5));
}

test "queued revalidation belongs to the current activation" {
    var lifecycle = Lifecycle.init(.changes);
    _ = lifecycle.activate(2, .pending, .pending, .pending);
    lifecycle.queueRevalidation();
    try std.testing.expect(lifecycle.hasQueuedFullRevalidation());
    lifecycle.consumeAcceptedFullRevalidation();
    try std.testing.expect(!lifecycle.hasQueuedFullRevalidation());

    _ = lifecycle.activate(2, .pending, .pending, .pending);
    lifecycle.queueRevalidation();
    lifecycle.queueActionTerminalRevalidation();
    lifecycle.deactivate();
    try std.testing.expect(!lifecycle.hasQueuedFullRevalidation());
    try std.testing.expect(lifecycle.revalidation_requested == null);
    try std.testing.expect(lifecycle.action_terminal_revalidation_requested == null);
}

test "full and terminal revalidation consumption remain distinct" {
    var lifecycle = Lifecycle.init(.changes);
    const activation_id = lifecycle.activate(3, .fresh, .fresh, .fresh);
    lifecycle.queueRevalidation();
    lifecycle.queueActionTerminalRevalidation();

    lifecycle.consumeAcceptedTerminalRevalidation();
    try std.testing.expectEqual(@as(?u64, activation_id), lifecycle.revalidation_requested);
    try std.testing.expect(lifecycle.action_terminal_revalidation_requested == null);
    try std.testing.expect(lifecycle.hasQueuedFullRevalidation());

    lifecycle.queueActionTerminalRevalidation();
    lifecycle.consumeAcceptedFullRevalidation();
    try std.testing.expect(lifecycle.revalidation_requested == null);
    try std.testing.expect(lifecycle.action_terminal_revalidation_requested == null);
    try std.testing.expect(!lifecycle.hasQueuedFullRevalidation());
}
