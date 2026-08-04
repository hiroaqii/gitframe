//! Page-independent Git reference vocabulary shared by loaders and consumers.

pub const BranchKind = enum {
    local,
    remote_tracking,
};
