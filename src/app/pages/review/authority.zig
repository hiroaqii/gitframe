//! Import-path shim: the module body moved to `src/app/diff_surface/authority.zig`
//! so the shared diff surface can reference the activation lifecycle without
//! importing Review page namespaces.

const shared = @import("../../diff_surface/authority.zig");

pub const MemberFreshness = shared.MemberFreshness;
pub const Requirement = shared.Requirement;
pub const Requirements = shared.Requirements;
pub const Action = shared.Action;
pub const MemberVector = shared.MemberVector;
pub const ActivationState = shared.ActivationState;
pub const Member = shared.Member;
pub const Lifecycle = shared.Lifecycle;
pub const auxiliaryMember = shared.auxiliaryMember;

test {
    _ = shared;
}
