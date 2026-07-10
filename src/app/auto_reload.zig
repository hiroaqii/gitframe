const std = @import("std");
const config = @import("../config.zig");
const diff_source = @import("../diff/source.zig");

pub const Activation = enum {
    disabled,
    automatic,
    forced,
};

pub const SourceFreshness = enum {
    fresh,
    stale_background_failure,
};

pub const SourceFingerprint = struct {
    byte_len: u64,
    digest: [32]u8,

    pub fn init(bytes: []const u8) SourceFingerprint {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest, .{});
        return .{
            .byte_len = @intCast(bytes.len),
            .digest = digest,
        };
    }

    pub fn eql(lhs: SourceFingerprint, rhs: SourceFingerprint) bool {
        return lhs.byte_len == rhs.byte_len and std.mem.eql(u8, &lhs.digest, &rhs.digest);
    }
};

pub const AcceptedSource = struct {
    fingerprint: SourceFingerprint,
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

    fn set(self: *PendingMembers, member: CycleMember, value: bool) void {
        switch (member) {
            .source => self.source = value,
            .status => self.status = value,
            .branch => self.branch = value,
            .deferred_source_apply => self.deferred_source_apply = value,
        }
    }
};

pub const BackgroundCycle = struct {
    id: u64,
    pending: PendingMembers = .{},
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
    origin: LoadOrigin = .foreground,
    background_cycle_id: ?u64 = null,
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

    pub fn begin(self: *AuxiliaryTracker, background_cycle_id: ?u64) void {
        self.pending = .{
            .generation = self.generation,
            .origin = if (background_cycle_id == null) .foreground else .background,
            .background_cycle_id = background_cycle_id,
        };
    }

    pub fn accept(self: *AuxiliaryTracker, result_generation: u64) bool {
        if (result_generation != self.generation) return false;
        if (self.pending) |pending| {
            if (pending.generation == result_generation) self.pending = null;
        }
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
        cycle.pending.set(member, true);
        return true;
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
        cycle.pending.set(from, false);
        cycle.pending.set(to, true);
        return true;
    }

    pub fn discardEmptyCycle(self: *State, cycle_id: u64) void {
        const cycle = self.background_cycle orelse return;
        if (cycle.id == cycle_id and !cycle.pending.any()) self.background_cycle = null;
    }

    pub fn acceptSource(self: *State, fingerprint: SourceFingerprint) void {
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

test "source fingerprint includes content and length" {
    const first = SourceFingerprint.init("abc");
    try std.testing.expect(first.eql(SourceFingerprint.init("abc")));
    try std.testing.expect(!first.eql(SourceFingerprint.init("abd")));
    try std.testing.expect(!first.eql(SourceFingerprint.init("abc\n")));
    try std.testing.expect(SourceFingerprint.init("").eql(SourceFingerprint.init("")));
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

test "accepted source failure is deduplicated and unchanged success restores freshness" {
    var state = State.init(.inherit, .{}, .unstaged);
    const fingerprint = SourceFingerprint.init("diff");
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
    state.acceptSource(SourceFingerprint.init(""));
    try std.testing.expect(state.sourceIsActionable());
    state.clearAcceptedSource();
    try std.testing.expect(!state.sourceIsActionable());
}

test "replacement invalidation preserves failure identity but fails closed" {
    var state = State.init(.inherit, .{}, .unstaged);
    state.acceptSource(SourceFingerprint.init("old"));
    try std.testing.expect(state.markSourceFailure("transient"));
    const failure = state.last_failure.?;

    state.invalidateAcceptedSnapshot();

    try std.testing.expect(state.accepted_source == null);
    try std.testing.expect(!state.sourceIsActionable());
    try std.testing.expect(state.last_failure.?.eql(failure));
}

test "auxiliary tracker keeps retained display separate from action freshness" {
    var tracker: AuxiliaryTracker = .{};
    const initial = tracker.prepare(false);
    tracker.begin(null);
    try std.testing.expect(tracker.isPending());
    try std.testing.expect(tracker.accept(initial));
    tracker.markSuccess();
    try std.testing.expect(tracker.isFresh());

    const background = tracker.prepare(true);
    tracker.begin(7);
    try std.testing.expect(!tracker.isFresh());
    try std.testing.expect(tracker.accept(background));
    tracker.markFailure(true);
    try std.testing.expect(!tracker.isFresh());

    const recovery = tracker.prepare(true);
    tracker.begin(8);
    try std.testing.expect(tracker.accept(recovery));
    tracker.markSuccess();
    try std.testing.expect(tracker.isFresh());
}
