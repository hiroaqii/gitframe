//! Correlation identity for repository-bound remote operations.

const root_capability = @import("../repo/root_capability.zig");

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
