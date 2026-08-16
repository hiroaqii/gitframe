//! Value vocabulary for correlating asynchronous effects with the page or
//! shell surface that requested them.

const page = @import("page.zig");

pub const PageOrigin = struct {
    page_id: page.Id,
    repo_epoch: u64,
    activation_id: u64,

    pub fn eql(left: PageOrigin, right: PageOrigin) bool {
        return left.page_id == right.page_id and
            left.repo_epoch == right.repo_epoch and
            left.activation_id == right.activation_id;
    }
};

pub const ShellSurface = enum {
    push_error,
    commit_panel,
};

pub const ShellSurfaceOrigin = struct {
    surface: ShellSurface,
    instance_id: u64,
};

pub const Origin = union(enum) {
    page: PageOrigin,
    shell_surface: ShellSurfaceOrigin,
};

pub const Liveness = enum {
    stale,
    live_inactive,
    live_active,
};

/// Current identities needed to classify a captured origin. The snapshot is
/// borrowed and is never retained by an asynchronous request.
pub const Snapshot = struct {
    active_page: page.Id,
    repo_epoch: u64,
    changes_activation_id: u64,
    repository_activation_id: u64,
    review_activation_id: u64,
    push_error_instance_id: ?u64,
    commit_panel_instance_id: ?u64,
};

pub fn classify(origin: Origin, current: Snapshot) Liveness {
    return switch (origin) {
        .page => |captured| blk: {
            const activation_matches = switch (captured.page_id) {
                .changes => captured.activation_id == current.changes_activation_id,
                .repository => captured.activation_id == current.repository_activation_id,
                .review => captured.activation_id == current.review_activation_id,
                .config => true,
            };
            if (captured.repo_epoch != current.repo_epoch or !activation_matches) break :blk .stale;
            break :blk if (captured.page_id == current.active_page) .live_active else .live_inactive;
        },
        .shell_surface => |captured| blk: {
            const current_instance = switch (captured.surface) {
                .push_error => current.push_error_instance_id,
                .commit_panel => current.commit_panel_instance_id,
            };
            if (current_instance == null or current_instance.? != captured.instance_id) break :blk .stale;
            break :blk .live_active;
        },
    };
}

test "repository selection inactive page accepts same-instance clipboard completion" {
    const current: Snapshot = .{
        .active_page = .changes,
        .repo_epoch = 4,
        .changes_activation_id = 9,
        .repository_activation_id = 5,
        .review_activation_id = 7,
        .push_error_instance_id = null,
        .commit_panel_instance_id = null,
    };
    try @import("std").testing.expectEqual(
        Liveness.live_inactive,
        classify(.{ .page = .{ .page_id = .repository, .repo_epoch = 4, .activation_id = 5 } }, current),
    );
    try @import("std").testing.expectEqual(
        Liveness.live_active,
        classify(.{ .page = .{ .page_id = .changes, .repo_epoch = 4, .activation_id = 9 } }, current),
    );
    try @import("std").testing.expectEqual(
        Liveness.stale,
        classify(.{ .page = .{ .page_id = .repository, .repo_epoch = 3, .activation_id = 5 } }, current),
    );
    try @import("std").testing.expectEqual(
        Liveness.stale,
        classify(.{ .page = .{ .page_id = .repository, .repo_epoch = 4, .activation_id = 6 } }, current),
    );
    try @import("std").testing.expectEqual(
        Liveness.live_inactive,
        classify(.{ .page = .{ .page_id = .config, .repo_epoch = 4, .activation_id = 999 } }, current),
    );
}

test "reopened shell surface rejects prior clipboard completion" {
    const current: Snapshot = .{
        .active_page = .changes,
        .repo_epoch = 4,
        .changes_activation_id = 9,
        .repository_activation_id = 5,
        .review_activation_id = 7,
        .push_error_instance_id = 12,
        .commit_panel_instance_id = 18,
    };
    try @import("std").testing.expectEqual(
        Liveness.live_active,
        classify(.{ .shell_surface = .{ .surface = .push_error, .instance_id = 12 } }, current),
    );
    try @import("std").testing.expectEqual(
        Liveness.live_active,
        classify(.{ .shell_surface = .{ .surface = .commit_panel, .instance_id = 18 } }, current),
    );
    try @import("std").testing.expectEqual(
        Liveness.stale,
        classify(.{ .shell_surface = .{ .surface = .push_error, .instance_id = 11 } }, current),
    );
    var missing = current;
    missing.push_error_instance_id = null;
    missing.commit_panel_instance_id = null;
    try @import("std").testing.expectEqual(
        Liveness.stale,
        classify(.{ .shell_surface = .{ .surface = .push_error, .instance_id = 12 } }, missing),
    );
    try @import("std").testing.expectEqual(
        Liveness.stale,
        classify(.{ .shell_surface = .{ .surface = .commit_panel, .instance_id = 18 } }, missing),
    );
}
