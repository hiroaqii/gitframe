//! Typed Changes-sidebar cursor ownership across Git action refreshes.
//!
//! A Changes action can rebuild only Git status or both the diff source and Git
//! status. This owner keeps the tree cursor independent from the sticky diff
//! target and binds final restoration to the exact action and required loader
//! generations which produced the successor projection. A later explicit
//! sidebar selection revokes restoration without discarding loader cleanup.

const std = @import("std");

const root_capability = @import("../../../repo/root_capability.zig");

pub const TargetKind = enum {
    repository_root,
    directory,
    file,
};

pub const Target = struct {
    kind: TargetKind,
    path_key: []u8,
    visible_row: usize,

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        if (self.path_key.len > 0) allocator.free(self.path_key);
        self.* = undefined;
    }
};

/// Fully allocated cursor intent prepared before an async action is launched.
/// Binding the returned action generation and publishing it are allocation-free.
pub const Prepared = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    target: Target,

    pub fn init(
        allocator: std.mem.Allocator,
        repo_epoch: u64,
        root_identity: root_capability.Identity,
        kind: TargetKind,
        path_key: []const u8,
        visible_row: usize,
    ) !Prepared {
        return .{
            .repo_epoch = repo_epoch,
            .root_identity = root_identity,
            .target = .{
                .kind = kind,
                .path_key = if (path_key.len == 0) &.{} else try allocator.dupe(u8, path_key),
                .visible_row = visible_row,
            },
        };
    }

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.* = undefined;
    }

    fn intoOwner(self: *Prepared, action_generation: u64) Owner {
        std.debug.assert(action_generation != 0);
        const owner: Owner = .{
            .action_generation = action_generation,
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
            .target = self.target,
        };
        self.* = undefined;
        return owner;
    }
};

pub const Member = enum {
    source,
    status,
};

pub const RefreshRequirement = enum {
    status_only,
    source_and_status,
};

pub const RestoreAuthority = enum {
    active,
    superseded,
};

pub const Terminal = enum {
    not_started,
    pending,
    succeeded,
    failed,
    rejected_spawn,

    pub fn isBounded(self: Terminal) bool {
        return switch (self) {
            .succeeded, .failed, .rejected_spawn => true,
            .not_started, .pending => false,
        };
    }
};

/// Authority captured before applying an already-delivered task completion.
/// Keeping the action generation in this token prevents error cleanup from
/// closing a newer owner even if application partially mutates page state.
pub const CompletionToken = struct {
    action_generation: u64,
    repo_epoch: u64,
    member: Member,
    generation: u64,
};

pub const MemberState = struct {
    generation: ?u64 = null,
    terminal: Terminal = .not_started,

    fn start(self: *MemberState, generation: u64) bool {
        if (generation == 0 or self.terminal != .not_started) return false;
        self.* = .{ .generation = generation, .terminal = .pending };
        return true;
    }

    fn failBeforeStart(self: *MemberState) bool {
        if (self.terminal != .not_started) return false;
        self.* = .{ .terminal = .failed };
        return true;
    }

    fn rejectSpawn(self: *MemberState, generation: u64) bool {
        if (self.terminal != .pending or self.generation != generation) return false;
        self.terminal = .rejected_spawn;
        return true;
    }

    fn finish(self: *MemberState, generation: u64, succeeded: bool) bool {
        if (self.terminal != .pending or self.generation != generation) return false;
        self.terminal = if (succeeded) .succeeded else .failed;
        return true;
    }
};

pub const SourceAndStatusMembers = struct {
    source: MemberState = .{},
    status: MemberState = .{},
};

/// Required work is a tagged shape rather than two states with a fabricated
/// terminal for a loader which was intentionally never started.
pub const ActionRefreshBasis = union(RefreshRequirement) {
    status_only: MemberState,
    source_and_status: SourceAndStatusMembers,

    fn init(requirement: RefreshRequirement) ActionRefreshBasis {
        return switch (requirement) {
            .status_only => .{ .status_only = .{} },
            .source_and_status => .{ .source_and_status = .{} },
        };
    }

    fn member(self: *ActionRefreshBasis, which: Member) ?*MemberState {
        return switch (self.*) {
            .status_only => |*status| switch (which) {
                .source => null,
                .status => status,
            },
            .source_and_status => |*members| switch (which) {
                .source => &members.source,
                .status => &members.status,
            },
        };
    }

    pub fn memberState(self: ActionRefreshBasis, which: Member) ?MemberState {
        return switch (self) {
            .status_only => |status| switch (which) {
                .source => null,
                .status => status,
            },
            .source_and_status => |members| switch (which) {
                .source => members.source,
                .status => members.status,
            },
        };
    }

    pub fn terminal(self: ActionRefreshBasis) bool {
        return switch (self) {
            .status_only => |status| status.terminal.isBounded(),
            .source_and_status => |members| members.source.terminal.isBounded() and members.status.terminal.isBounded(),
        };
    }
};

pub const Phase = union(enum) {
    awaiting_action,
    awaiting_action_refresh: ActionRefreshBasis,
};

pub const Owner = struct {
    action_generation: u64,
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    target: Target,
    phase: Phase = .awaiting_action,
    restore_authority: RestoreAuthority = .active,

    pub fn deinit(self: *Owner, allocator: std.mem.Allocator) void {
        self.target.deinit(allocator);
        self.* = undefined;
    }

    fn matches(self: Owner, action_generation: u64, repo_epoch: u64, root_identity: root_capability.Identity) bool {
        return self.action_generation == action_generation and
            self.repo_epoch == repo_epoch and
            self.root_identity.eql(root_identity);
    }

    pub fn mayRestore(self: Owner) bool {
        return self.restore_authority == .active;
    }
};

pub const State = struct {
    owner: ?Owner = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.* = .{};
    }

    pub fn install(
        self: *State,
        allocator: std.mem.Allocator,
        prepared: *Prepared,
        action_generation: u64,
    ) void {
        self.clear(allocator);
        self.owner = prepared.intoOwner(action_generation);
    }

    pub fn clear(self: *State, allocator: std.mem.Allocator) void {
        if (self.owner) |*owner| owner.deinit(allocator);
        self.owner = null;
    }

    pub fn clearMatchingAction(self: *State, allocator: std.mem.Allocator, action_generation: u64) bool {
        const owner = self.owner orelse return false;
        if (owner.action_generation != action_generation) return false;
        self.clear(allocator);
        return true;
    }

    pub fn hasOwner(self: State) bool {
        return self.owner != null;
    }

    pub fn actionGeneration(self: State) ?u64 {
        return if (self.owner) |owner| owner.action_generation else null;
    }

    pub fn awaitingRefresh(self: State) bool {
        const owner = self.owner orelse return false;
        return owner.phase == .awaiting_action_refresh;
    }

    pub fn ownsRefresh(self: State, action_generation: u64) bool {
        const owner = self.owner orelse return false;
        return owner.action_generation == action_generation and owner.phase == .awaiting_action_refresh;
    }

    pub fn target(self: *const State) ?*const Target {
        const owner = if (self.owner) |*value| value else return null;
        return &owner.target;
    }

    pub fn restoreTarget(self: *const State) ?*const Target {
        const owner = if (self.owner) |*value| value else return null;
        if (!owner.mayRestore()) return null;
        return &owner.target;
    }

    pub fn hasRestoreAuthority(self: State) bool {
        const owner = self.owner orelse return false;
        return owner.mayRestore();
    }

    /// Later user intent wins only over path restoration. The matching action
    /// and every required loader member continue to their exact terminal so no
    /// result or allocation owner is abandoned.
    pub fn supersedeRestore(self: *State) bool {
        const owner = if (self.owner) |*value| value else return false;
        if (owner.restore_authority == .superseded) return false;
        owner.restore_authority = .superseded;
        return true;
    }

    pub fn promote(
        self: *State,
        action_generation: u64,
        repo_epoch: u64,
        root_identity: root_capability.Identity,
        requirement: RefreshRequirement,
    ) bool {
        const owner = if (self.owner) |*value| value else return false;
        if (!owner.matches(action_generation, repo_epoch, root_identity)) return false;
        if (owner.phase != .awaiting_action) return false;
        owner.phase = .{ .awaiting_action_refresh = ActionRefreshBasis.init(requirement) };
        return true;
    }

    pub fn startMember(self: *State, action_generation: u64, which: Member, generation: u64) bool {
        const basis = self.refreshBasis(action_generation) orelse return false;
        const member = basis.member(which) orelse return false;
        return member.start(generation);
    }

    pub fn failMemberBeforeStart(self: *State, action_generation: u64, which: Member) bool {
        const basis = self.refreshBasis(action_generation) orelse return false;
        const member = basis.member(which) orelse return false;
        return member.failBeforeStart();
    }

    pub fn rejectMemberSpawn(self: *State, action_generation: u64, which: Member, generation: u64) bool {
        const basis = self.refreshBasis(action_generation) orelse return false;
        const member = basis.member(which) orelse return false;
        return member.rejectSpawn(generation);
    }

    pub fn finishMember(
        self: *State,
        action_generation: u64,
        repo_epoch: u64,
        which: Member,
        generation: u64,
        succeeded: bool,
    ) bool {
        const owner = if (self.owner) |*value| value else return false;
        // The shell advances repo_epoch and clears this page owner before it
        // can commit a different physical root identity. Exact generation +
        // epoch therefore identifies a result from the root captured above;
        // activation id is intentionally excluded so an inactive Changes page
        // can still reconcile its retained state.
        if (owner.action_generation != action_generation or owner.repo_epoch != repo_epoch) return false;
        const basis = switch (owner.phase) {
            .awaiting_action => return false,
            .awaiting_action_refresh => |*value| value,
        };
        const member = basis.member(which) orelse return false;
        return member.finish(generation, succeeded);
    }

    pub fn captureCompletion(self: State, repo_epoch: u64, which: Member, generation: u64) ?CompletionToken {
        const owner = self.owner orelse return null;
        if (owner.repo_epoch != repo_epoch) return null;
        const basis = switch (owner.phase) {
            .awaiting_action => return null,
            .awaiting_action_refresh => |value| value,
        };
        const state = basis.memberState(which) orelse return null;
        if (state.terminal != .pending or state.generation != generation) return null;
        return .{
            .action_generation = owner.action_generation,
            .repo_epoch = repo_epoch,
            .member = which,
            .generation = generation,
        };
    }

    pub fn finishCompletion(self: *State, token: CompletionToken, succeeded: bool) bool {
        return self.finishMember(
            token.action_generation,
            token.repo_epoch,
            token.member,
            token.generation,
            succeeded,
        );
    }

    pub fn terminal(self: State) bool {
        const owner = self.owner orelse return false;
        return switch (owner.phase) {
            .awaiting_action => false,
            .awaiting_action_refresh => |basis| basis.terminal(),
        };
    }

    pub fn takeTerminal(self: *State) ?Owner {
        if (!self.terminal()) return null;
        const owner = self.owner.?;
        self.owner = null;
        return owner;
    }

    fn refreshBasis(self: *State, action_generation: u64) ?*ActionRefreshBasis {
        const owner = if (self.owner) |*value| value else return null;
        if (owner.action_generation != action_generation) return null;
        return switch (owner.phase) {
            .awaiting_action => null,
            .awaiting_action_refresh => |*basis| basis,
        };
    }
};

test "action cursor binds exact refresh members and closes partial start" {
    const allocator = std.testing.allocator;
    var prepared = try Prepared.init(allocator, 3, .{ .device = 5, .inode = 8 }, .directory, "src", 4);
    var state: State = .{};
    defer state.deinit(allocator);
    state.install(allocator, &prepared, 7);

    try std.testing.expect(state.promote(7, 3, .{ .device = 5, .inode = 8 }, .source_and_status));
    try std.testing.expect(state.startMember(7, .status, 11));
    try std.testing.expect(state.failMemberBeforeStart(7, .source));
    try std.testing.expect(!state.terminal());
    try std.testing.expect(!state.finishMember(7, 3, .status, 10, true));
    try std.testing.expect(state.finishMember(7, 3, .status, 11, true));
    try std.testing.expect(state.terminal());

    var terminal = state.takeTerminal().?;
    defer terminal.deinit(allocator);
    try std.testing.expectEqual(TargetKind.directory, terminal.target.kind);
    try std.testing.expectEqualStrings("src", terminal.target.path_key);
}

test "new owner supersedes and frees the previous refresh owner" {
    const allocator = std.testing.allocator;
    var first = try Prepared.init(allocator, 1, .{ .device = 2, .inode = 3 }, .file, "old.zig", 1);
    var second = try Prepared.init(allocator, 1, .{ .device = 2, .inode = 3 }, .repository_root, "", 0);
    var state: State = .{};
    defer state.deinit(allocator);

    state.install(allocator, &first, 4);
    try std.testing.expect(state.promote(4, 1, .{ .device = 2, .inode = 3 }, .source_and_status));
    try std.testing.expect(state.startMember(4, .source, 9));
    const old_completion = state.captureCompletion(1, .source, 9) orelse return error.ExpectedCompletionToken;
    state.install(allocator, &second, 5);

    try std.testing.expect(!state.finishCompletion(old_completion, true));
    try std.testing.expectEqual(@as(u64, 5), state.owner.?.action_generation);
    try std.testing.expectEqual(TargetKind.repository_root, state.owner.?.target.kind);
}

test "cursor allocation failure leaves no owner to outlive a rejected action launch" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        Prepared.init(
            failing.allocator(),
            1,
            .{ .device = 2, .inode = 3 },
            .directory,
            "src",
            0,
        ),
    );

    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    try std.testing.expect(!state.hasOwner());
}

test "status-only refresh has no synthetic source member" {
    const allocator = std.testing.allocator;
    var prepared = try Prepared.init(allocator, 3, .{ .device = 5, .inode = 8 }, .file, "src/a.zig", 2);
    var state: State = .{};
    defer state.deinit(allocator);
    state.install(allocator, &prepared, 7);

    try std.testing.expect(state.promote(7, 3, .{ .device = 5, .inode = 8 }, .status_only));
    try std.testing.expect(!state.startMember(7, .source, 10));
    try std.testing.expect(!state.failMemberBeforeStart(7, .source));
    try std.testing.expect(state.startMember(7, .status, 11));
    try std.testing.expect(!state.terminal());
    try std.testing.expect(state.finishMember(7, 3, .status, 11, true));
    try std.testing.expect(state.terminal());
}

test "explicit selection supersedes restoration without abandoning refresh cleanup" {
    const allocator = std.testing.allocator;
    var prepared = try Prepared.init(allocator, 3, .{ .device = 5, .inode = 8 }, .file, "src/a.zig", 2);
    var state: State = .{};
    defer state.deinit(allocator);
    state.install(allocator, &prepared, 7);

    // Selection can change while the Git task itself is still pending. Its
    // later successful result may promote the owner, but must not reactivate
    // restoration of the action target.
    try std.testing.expect(state.restoreTarget() != null);
    try std.testing.expect(state.supersedeRestore());
    try std.testing.expect(state.promote(7, 3, .{ .device = 5, .inode = 8 }, .status_only));
    try std.testing.expect(state.startMember(7, .status, 11));
    try std.testing.expect(!state.supersedeRestore());
    try std.testing.expect(state.restoreTarget() == null);
    try std.testing.expectEqualStrings("src/a.zig", state.target().?.path_key);
    try std.testing.expect(state.finishMember(7, 3, .status, 11, true));
    try std.testing.expect(state.terminal());
}
