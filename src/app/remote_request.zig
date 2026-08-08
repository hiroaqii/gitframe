//! Correlation identity for repository-bound remote operations.

const std = @import("std");
const process_runner = @import("../process/runner.zig");
const root_capability = @import("../repo/root_capability.zig");

/// Stable App-owned cancellation authority for background remote actions.
/// Tasks borrow only the atomic cancellation view; the App retains this value
/// until runtime teardown has drained or abandoned every task.
pub const RemoteActionControl = struct {
    generation: std.atomic.Value(u64) = .init(0),
    canceled_generation: std.atomic.Value(u64) = .init(0),

    pub fn begin(self: *RemoteActionControl, operation_generation: u64) void {
        std.debug.assert(operation_generation != 0);
        std.debug.assert(self.generation.load(.acquire) == 0);
        self.canceled_generation.store(0, .release);
        self.generation.store(operation_generation, .release);
    }

    /// Idempotently requests cancellation for the exact active generation.
    /// Returns true only for the first accepted request.
    pub fn requestCancel(self: *RemoteActionControl, operation_generation: u64) bool {
        if (operation_generation == 0 or self.generation.load(.acquire) != operation_generation) return false;
        return self.canceled_generation.cmpxchgStrong(0, operation_generation, .acq_rel, .acquire) == null;
    }

    pub fn isCanceling(self: *const RemoteActionControl, operation_generation: u64) bool {
        return operation_generation != 0 and
            self.generation.load(.acquire) == operation_generation and
            self.canceled_generation.load(.acquire) == operation_generation;
    }

    pub fn isActive(self: *const RemoteActionControl, operation_generation: u64) bool {
        return operation_generation != 0 and self.generation.load(.acquire) == operation_generation;
    }

    pub fn cancellationView(self: *const RemoteActionControl, operation_generation: u64) process_runner.CancellationView {
        std.debug.assert(self.generation.load(.acquire) == operation_generation);
        return .{
            .canceled_generation = &self.canceled_generation,
            .generation = operation_generation,
        };
    }

    pub fn finish(self: *RemoteActionControl, operation_generation: u64) bool {
        if (operation_generation == 0 or self.generation.load(.acquire) != operation_generation) return false;
        self.generation.store(0, .release);
        self.canceled_generation.store(0, .release);
        return true;
    }
};

/// Repository authority captured before a remote operation may outlive the
/// synchronous App dispatch that admitted it.
pub const RepositoryIdentity = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,

    pub fn eql(left: RepositoryIdentity, right: RepositoryIdentity) bool {
        return left.repo_epoch == right.repo_epoch and
            left.root_identity.eql(right.root_identity);
    }
};

/// Exact identity of one admitted remote operation.
pub const RemoteRequestIdentity = struct {
    repo_epoch: u64,
    root_identity: root_capability.Identity,
    operation_generation: u64,

    pub fn repository(self: RemoteRequestIdentity) RepositoryIdentity {
        return .{
            .repo_epoch = self.repo_epoch,
            .root_identity = self.root_identity,
        };
    }

    pub fn eql(left: RemoteRequestIdentity, right: RemoteRequestIdentity) bool {
        return left.operation_generation == right.operation_generation and
            left.repository().eql(right.repository());
    }
};

test "remote request identity requires repository and operation generation" {
    const base: RemoteRequestIdentity = .{
        .repo_epoch = 4,
        .root_identity = .{ .device = 7, .inode = 9 },
        .operation_generation = 11,
    };
    try @import("std").testing.expect(base.eql(base));

    var changed = base;
    changed.repo_epoch += 1;
    try @import("std").testing.expect(!base.eql(changed));
    changed = base;
    changed.root_identity.inode += 1;
    try @import("std").testing.expect(!base.eql(changed));
    changed = base;
    changed.operation_generation += 1;
    try @import("std").testing.expect(!base.eql(changed));
}

test "remote cancel signal is exact and idempotent" {
    var control: RemoteActionControl = .{};
    control.begin(17);
    const view = control.cancellationView(17);
    try std.testing.expect(!view.requested());
    try std.testing.expect(!control.requestCancel(18));
    try std.testing.expect(control.requestCancel(17));
    try std.testing.expect(!control.requestCancel(17));
    try std.testing.expect(view.requested());
    try std.testing.expect(control.finish(17));
    try std.testing.expect(!control.isCanceling(17));
}
