const std = @import("std");
const config = @import("../config.zig");
const content_fingerprint = @import("../content_fingerprint.zig");
const diff_source = @import("../diff/source.zig");
const review_read_epoch = @import("review_read_epoch.zig");

pub const Activation = enum {
    disabled,
    automatic,
    forced,
};

pub const SourceFreshness = enum {
    fresh,
    stale_background_failure,
};

pub const AcceptedSource = struct {
    fingerprint: content_fingerprint.Fingerprint,
    freshness: SourceFreshness = .fresh,
};

pub const CycleMember = enum {
    source,
    status,
    branch,
    deferred_source_apply,
};

pub const PendingMembers = packed struct {
    source: bool = false,
    status: bool = false,
    branch: bool = false,
    deferred_source_apply: bool = false,

    pub fn any(self: PendingMembers) bool {
        return self.source or self.status or self.branch or self.deferred_source_apply;
    }

    pub fn owns(self: PendingMembers, member: CycleMember) bool {
        return switch (member) {
            .source => self.source,
            .status => self.status,
            .branch => self.branch,
            .deferred_source_apply => self.deferred_source_apply,
        };
    }

    fn set(self: *PendingMembers, member: CycleMember, value: bool) void {
        switch (member) {
            .source => self.source = value,
            .status => self.status = value,
            .branch => self.branch = value,
            .deferred_source_apply => self.deferred_source_apply = value,
        }
    }
};

/// Sticky publication authority for one background scheduling cycle.
/// Supersession does not cancel or abandon member ownership; every started
/// member must still drain before the cycle releases its scheduling slot.
pub const CycleAcceptance = enum {
    open,
    superseded_by_mutation,
};

pub const BackgroundCycle = struct {
    id: u64,
    pending: PendingMembers = .{},
    acceptance: CycleAcceptance = .open,
};

pub const FailureIdentity = struct {
    digest: [32]u8,

    pub fn init(message: []const u8) FailureIdentity {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(message, &digest, .{});
        return .{ .digest = digest };
    }

    pub fn eql(lhs: FailureIdentity, rhs: FailureIdentity) bool {
        return std.mem.eql(u8, &lhs.digest, &rhs.digest);
    }
};

pub const AuxiliaryFreshness = enum {
    missing,
    fresh,
    stale_refresh,
};

pub const LoadOrigin = enum {
    foreground,
    background,
};

pub const AuxiliaryPending = struct {
    generation: u64,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch = .{},
    origin: LoadOrigin = .foreground,
    background_cycle_id: ?u64 = null,
    publication_allowed: bool = true,

    pub fn matchesTerminal(self: AuxiliaryPending, terminal: AuxiliaryTerminal) bool {
        return self.generation == terminal.generation and
            self.read_epoch.eql(terminal.read_epoch) and
            self.background_cycle_id == terminal.background_cycle_id;
    }
};

/// Exact provenance returned by one auxiliary status or branch task.
/// Publication admission is a separate page-authority decision; this value
/// only proves which pending owner a completion is allowed to retire.
pub const AuxiliaryTerminal = struct {
    generation: u64,
    read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
    background_cycle_id: ?u64,
};

pub const AuxiliaryTracker = struct {
    generation: u64 = 0,
    pending: ?AuxiliaryPending = null,
    freshness: AuxiliaryFreshness = .fresh,

    pub fn prepare(self: *AuxiliaryTracker, retain_snapshot: bool) u64 {
        self.generation +%= 1;
        self.pending = null;
        self.freshness = if (retain_snapshot) .stale_refresh else .missing;
        return self.generation;
    }

    pub fn begin(
        self: *AuxiliaryTracker,
        background_cycle_id: ?u64,
        read_epoch: review_read_epoch.ReviewRepositoryReadEpoch,
    ) void {
        self.pending = .{
            .generation = self.generation,
            .read_epoch = read_epoch,
            .origin = if (background_cycle_id == null) .foreground else .background,
            .background_cycle_id = background_cycle_id,
        };
    }

    pub fn finishTerminal(self: *AuxiliaryTracker, terminal: AuxiliaryTerminal) bool {
        if (terminal.generation != self.generation) return false;
        const pending = self.pending orelse return false;
        if (!pending.matchesTerminal(terminal)) return false;
        self.pending = null;
        return true;
    }

    pub fn acceptsPublication(
        self: AuxiliaryTracker,
        terminal: AuxiliaryTerminal,
    ) bool {
        if (terminal.generation != self.generation) return false;
        const pending = self.pending orelse return false;
        return pending.matchesTerminal(terminal) and pending.publication_allowed;
    }

    pub fn supersedeTerminal(
        self: *AuxiliaryTracker,
        terminal: AuxiliaryTerminal,
    ) bool {
        if (terminal.generation != self.generation) return false;
        const pending = if (self.pending) |*owned| owned else return false;
        if (!pending.matchesTerminal(terminal)) return false;
        pending.publication_allowed = false;
        return true;
    }

    pub fn markSuccess(self: *AuxiliaryTracker) void {
        self.freshness = .fresh;
    }

    pub fn markFailure(self: *AuxiliaryTracker, retained_background_snapshot: bool) void {
        self.freshness = if (retained_background_snapshot) .stale_refresh else .missing;
    }

    pub fn isPending(self: AuxiliaryTracker) bool {
        return self.pending != null;
    }

    pub fn isFresh(self: AuxiliaryTracker) bool {
        return self.pending == null and self.freshness == .fresh;
    }
};

pub const State = struct {
    activation: Activation = .disabled,
    interval_ns: u64 = 0,
    accepted_source: ?AcceptedSource = null,
    background_cycle: ?BackgroundCycle = null,
    next_cycle_id: u64 = 0,
    last_failure: ?FailureIdentity = null,

    pub fn init(cli: diff_source.AutoReloadOverride, user: config.ReloadConfig, source: diff_source.SourceMode) State {
        const activation: Activation = switch (cli) {
            .enabled => if (diff_source.sourceSupportsWatch(source)) .forced else .disabled,
            .disabled => .disabled,
            .inherit => if (user.auto and diff_source.sourceSupportsWatch(source)) .automatic else .disabled,
        };
        return .{
            .activation = activation,
            .interval_ns = @as(u64, user.interval_seconds) * std.time.ns_per_s,
        };
    }

    pub fn enabled(self: State) bool {
        return self.activation != .disabled;
    }

    pub fn beginCycle(self: *State) ?u64 {
        if (!self.enabled() or self.background_cycle != null) return null;
        self.next_cycle_id +%= 1;
        self.background_cycle = .{ .id = self.next_cycle_id };
        return self.next_cycle_id;
    }

    pub fn markMemberStarted(self: *State, cycle_id: u64, member: CycleMember) bool {
        const cycle = &(self.background_cycle orelse return false);
        if (cycle.id != cycle_id) return false;
        if (cycle.acceptance != .open) return false;
        cycle.pending.set(member, true);
        return true;
    }

    /// Foreground reads have no cycle and pass this half of admission. A
    /// background result must name the exact still-active open cycle; read
    /// epoch/phase admission remains a separate P6b contract.
    pub fn acceptsCycle(self: State, cycle_id: ?u64) bool {
        const id = cycle_id orelse return true;
        const cycle = self.background_cycle orelse return false;
        return cycle.id == id and cycle.acceptance == .open;
    }

    pub fn finishMember(self: *State, cycle_id: ?u64, member: CycleMember) void {
        const id = cycle_id orelse return;
        const cycle = &(self.background_cycle orelse return);
        if (cycle.id != id) return;
        cycle.pending.set(member, false);
        if (!cycle.pending.any()) self.background_cycle = null;
    }

    pub fn moveMember(self: *State, cycle_id: ?u64, from: CycleMember, to: CycleMember) bool {
        const id = cycle_id orelse return false;
        const cycle = &(self.background_cycle orelse return false);
        if (cycle.id != id) return false;
        // A move transfers one existing owner; it must never manufacture work
        // or merge two independently draining owners into a single bit.
        if (!cycle.pending.owns(from) or cycle.pending.owns(to)) return false;
        cycle.pending.set(from, false);
        cycle.pending.set(to, true);
        return true;
    }

    pub fn discardEmptyCycle(self: *State, cycle_id: u64) void {
        const cycle = self.background_cycle orelse return;
        if (cycle.id == cycle_id and !cycle.pending.any()) self.background_cycle = null;
    }

    /// Repository identity replacement destroys the complete old scheduling
    /// namespace, so it may release the cycle immediately. Mutation overlap
    /// uses `supersedeActiveCycleByMutation` and preserves member drain.
    pub fn supersedeCycle(self: *State) void {
        self.background_cycle = null;
    }

    /// Fail closed for every remaining member of the active pre-mutation
    /// cycle. An empty cycle is already drained and can release immediately;
    /// otherwise its sticky state survives arbitrary member arrival order.
    pub fn supersedeActiveCycleByMutation(self: *State) void {
        const cycle = &(self.background_cycle orelse return);
        if (!cycle.pending.any()) {
            self.background_cycle = null;
            return;
        }
        cycle.acceptance = .superseded_by_mutation;
    }

    pub fn acceptSource(self: *State, fingerprint: content_fingerprint.Fingerprint) void {
        self.accepted_source = .{ .fingerprint = fingerprint };
        self.last_failure = null;
    }

    pub fn markSourceFailure(self: *State, message: []const u8) bool {
        if (self.accepted_source) |*accepted| accepted.freshness = .stale_background_failure;
        const next = FailureIdentity.init(message);
        if (self.last_failure) |previous| {
            if (previous.eql(next)) return false;
        }
        self.last_failure = next;
        return true;
    }

    pub fn sourceIsFresh(self: State) bool {
        const accepted = self.accepted_source orelse return false;
        return accepted.freshness == .fresh;
    }

    pub fn sourceIsActionable(self: State) bool {
        const accepted = self.accepted_source orelse return false;
        return accepted.freshness == .fresh;
    }

    /// Invalidate unchanged-skip/action authority while preserving the exact
    /// failure identity needed to clear its status after replacement succeeds.
    pub fn invalidateAcceptedSnapshot(self: *State) void {
        self.accepted_source = null;
    }

    pub fn clearAcceptedSource(self: *State) void {
        self.invalidateAcceptedSnapshot();
        self.last_failure = null;
    }
};

test "policy resolution honors cli config and source eligibility" {
    const defaults = State.init(.inherit, .{}, .unstaged);
    try std.testing.expectEqual(Activation.automatic, defaults.activation);
    try std.testing.expectEqual(@as(u64, 3 * std.time.ns_per_s), defaults.interval_ns);
    try std.testing.expectEqual(Activation.disabled, State.init(.inherit, .{ .auto = false }, .unstaged).activation);
    try std.testing.expectEqual(Activation.forced, State.init(.enabled, .{ .auto = false }, .unstaged).activation);
    try std.testing.expectEqual(Activation.disabled, State.init(.disabled, .{}, .unstaged).activation);
    try std.testing.expectEqual(Activation.disabled, State.init(.inherit, .{}, .stdin).activation);
    try std.testing.expectEqual(Activation.automatic, State.init(.inherit, .{}, .{ .no_index = .{ .left = "a", .right = "b" } }).activation);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s), State.init(.inherit, .{ .interval_seconds = 1 }, .unstaged).interval_ns);
}

test "background cycle remains busy until every member finishes" {
    var state = State.init(.inherit, .{}, .unstaged);
    const id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(id, .source));
    try std.testing.expect(state.markMemberStarted(id, .status));
    try std.testing.expect(state.markMemberStarted(id, .branch));
    state.finishMember(id, .source);
    try std.testing.expect(state.background_cycle != null);
    try std.testing.expect(state.beginCycle() == null);
    state.finishMember(id, .status);
    try std.testing.expect(state.background_cycle != null);
    try std.testing.expect(state.beginCycle() == null);
    state.finishMember(id, .branch);
    try std.testing.expect(state.background_cycle == null);
}

test "deferred source apply keeps its background cycle busy" {
    var state = State.init(.inherit, .{}, .unstaged);
    const id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(id, .source));
    try std.testing.expect(state.moveMember(id, .source, .deferred_source_apply));
    try std.testing.expect(state.background_cycle.?.pending.deferred_source_apply);
    try std.testing.expect(state.beginCycle() == null);
    state.finishMember(id, .deferred_source_apply);
    try std.testing.expect(state.background_cycle == null);
}

test "mutation supersession is sticky until every cycle member drains" {
    var state = State.init(.inherit, .{}, .unstaged);
    const id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(id, .source));
    try std.testing.expect(state.markMemberStarted(id, .status));
    try std.testing.expect(state.markMemberStarted(id, .branch));
    try std.testing.expect(state.acceptsCycle(id));

    state.supersedeActiveCycleByMutation();
    try std.testing.expectEqual(CycleAcceptance.superseded_by_mutation, state.background_cycle.?.acceptance);
    try std.testing.expect(!state.acceptsCycle(id));
    try std.testing.expect(state.acceptsCycle(null));
    try std.testing.expect(state.beginCycle() == null);

    state.finishMember(id, .source);
    try std.testing.expect(state.background_cycle != null);
    state.finishMember(id, .branch);
    try std.testing.expect(state.background_cycle != null);
    state.finishMember(id, .status);
    try std.testing.expect(state.background_cycle == null);

    const next = state.beginCycle().?;
    try std.testing.expect(next != id);
    try std.testing.expect(state.acceptsCycle(next));
    try std.testing.expect(state.markMemberStarted(next, .source));
    try std.testing.expect(!state.acceptsCycle(id));
    state.finishMember(id, .source);
    try std.testing.expectEqual(next, state.background_cycle.?.id);
    state.finishMember(next, .source);
    try std.testing.expect(state.background_cycle == null);
}

test "superseded cycle rejects late starts but permits ownership moves and drain" {
    var state = State.init(.inherit, .{}, .unstaged);
    const id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(id, .source));
    try std.testing.expect(state.markMemberStarted(id, .status));
    state.supersedeActiveCycleByMutation();

    try std.testing.expect(!state.markMemberStarted(id, .branch));
    try std.testing.expect(!state.acceptsCycle(id +% 1));
    state.finishMember(id +% 1, .source);
    try std.testing.expect(state.background_cycle != null);
    try std.testing.expect(state.moveMember(id, .source, .deferred_source_apply));
    try std.testing.expect(state.background_cycle.?.pending.deferred_source_apply);
    state.finishMember(id, .status);
    try std.testing.expect(state.background_cycle != null);
    state.finishMember(id, .deferred_source_apply);
    try std.testing.expect(state.background_cycle == null);
}

test "superseded cycle rejects ownership creation and merging while preserving drain" {
    var state = State.init(.inherit, .{}, .unstaged);
    const missing_source_id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(missing_source_id, .status));
    state.supersedeActiveCycleByMutation();

    const before_missing_move = state.background_cycle.?.pending;
    try std.testing.expect(!state.moveMember(missing_source_id, .source, .deferred_source_apply));
    try std.testing.expectEqual(before_missing_move, state.background_cycle.?.pending);
    state.finishMember(missing_source_id, .status);
    try std.testing.expect(state.background_cycle == null);

    const occupied_target_id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(occupied_target_id, .source));
    try std.testing.expect(state.markMemberStarted(occupied_target_id, .status));
    state.supersedeActiveCycleByMutation();

    const before_occupied_move = state.background_cycle.?.pending;
    try std.testing.expect(!state.moveMember(occupied_target_id, .source, .status));
    try std.testing.expectEqual(before_occupied_move, state.background_cycle.?.pending);
    state.finishMember(occupied_target_id, .source);
    try std.testing.expect(state.background_cycle != null);
    state.finishMember(occupied_target_id, .status);
    try std.testing.expect(state.background_cycle == null);

    try std.testing.expect(state.beginCycle() != null);
}

test "empty mutation cycle and repository supersession release immediately" {
    var state = State.init(.inherit, .{}, .unstaged);
    _ = state.beginCycle().?;
    state.supersedeActiveCycleByMutation();
    try std.testing.expect(state.background_cycle == null);

    const id = state.beginCycle().?;
    try std.testing.expect(state.markMemberStarted(id, .source));
    state.supersedeCycle();
    try std.testing.expect(state.background_cycle == null);
}

test "accepted source failure is deduplicated and unchanged success restores freshness" {
    var state = State.init(.inherit, .{}, .unstaged);
    const fingerprint = content_fingerprint.Fingerprint.init("diff");
    state.acceptSource(fingerprint);
    try std.testing.expect(state.sourceIsFresh());
    try std.testing.expect(state.markSourceFailure("failed"));
    try std.testing.expect(!state.sourceIsFresh());
    try std.testing.expect(!state.markSourceFailure("failed"));
    state.acceptSource(fingerprint);
    try std.testing.expect(state.sourceIsFresh());
}

test "missing accepted source fails closed for diff-derived actions" {
    var state = State.init(.inherit, .{}, .unstaged);
    try std.testing.expect(!state.sourceIsActionable());
    state.acceptSource(content_fingerprint.Fingerprint.init(""));
    try std.testing.expect(state.sourceIsActionable());
    state.clearAcceptedSource();
    try std.testing.expect(!state.sourceIsActionable());
}

test "replacement invalidation preserves failure identity but fails closed" {
    var state = State.init(.inherit, .{}, .unstaged);
    state.acceptSource(content_fingerprint.Fingerprint.init("old"));
    try std.testing.expect(state.markSourceFailure("transient"));
    const failure = state.last_failure.?;

    state.invalidateAcceptedSnapshot();

    try std.testing.expect(state.accepted_source == null);
    try std.testing.expect(!state.sourceIsActionable());
    try std.testing.expect(state.last_failure.?.eql(failure));
}

test "auxiliary tracker keeps read epoch and retained display separate from action freshness" {
    var tracker: AuxiliaryTracker = .{};
    const initial = tracker.prepare(false);
    tracker.begin(null, .{ .value = 17 });
    try std.testing.expect(tracker.isPending());
    try std.testing.expect(tracker.pending.?.read_epoch.eql(.{ .value = 17 }));
    try std.testing.expect(tracker.finishTerminal(.{
        .generation = initial,
        .read_epoch = .{ .value = 17 },
        .background_cycle_id = null,
    }));
    tracker.markSuccess();
    try std.testing.expect(tracker.isFresh());

    const background = tracker.prepare(true);
    tracker.begin(7, .{ .value = 19 });
    try std.testing.expect(!tracker.isFresh());
    try std.testing.expect(tracker.pending.?.read_epoch.eql(.{ .value = 19 }));
    try std.testing.expect(tracker.finishTerminal(.{
        .generation = background,
        .read_epoch = .{ .value = 19 },
        .background_cycle_id = 7,
    }));
    tracker.markFailure(true);
    try std.testing.expect(!tracker.isFresh());

    const recovery = tracker.prepare(true);
    tracker.begin(8, .{ .value = 23 });
    try std.testing.expect(tracker.pending.?.read_epoch.eql(.{ .value = 23 }));
    try std.testing.expect(tracker.finishTerminal(.{
        .generation = recovery,
        .read_epoch = .{ .value = 23 },
        .background_cycle_id = 8,
    }));
    tracker.markSuccess();
    try std.testing.expect(tracker.isFresh());
}

test "auxiliary tracker retires only its exact read terminal" {
    var tracker: AuxiliaryTracker = .{};
    const generation = tracker.prepare(true);
    tracker.begin(11, .{ .value = 29 });

    try std.testing.expect(!tracker.finishTerminal(.{
        .generation = generation + 1,
        .read_epoch = .{ .value = 29 },
        .background_cycle_id = 11,
    }));
    try std.testing.expect(!tracker.finishTerminal(.{
        .generation = generation,
        .read_epoch = .{ .value = 30 },
        .background_cycle_id = 11,
    }));
    try std.testing.expect(!tracker.finishTerminal(.{
        .generation = generation,
        .read_epoch = .{ .value = 29 },
        .background_cycle_id = 12,
    }));
    try std.testing.expect(tracker.isPending());

    const exact: AuxiliaryTerminal = .{
        .generation = generation,
        .read_epoch = .{ .value = 29 },
        .background_cycle_id = 11,
    };
    try std.testing.expect(tracker.finishTerminal(exact));
    try std.testing.expect(!tracker.isPending());
    try std.testing.expect(!tracker.finishTerminal(exact));
}
