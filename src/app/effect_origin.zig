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

pub const HistoryPreviewAuthority = struct {
    selection_generation: u64,
    copy_generation: u64,

    pub fn eql(left: HistoryPreviewAuthority, right: HistoryPreviewAuthority) bool {
        return left.selection_generation == right.selection_generation and
            left.copy_generation == right.copy_generation;
    }
};

pub const HistoryPreviewOrigin = struct {
    page: PageOrigin,
    authority: HistoryPreviewAuthority,
};

pub const Origin = union(enum) {
    page: PageOrigin,
    history_preview: HistoryPreviewOrigin,
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
    history_activation_id: u64 = 0,
    compare_activation_id: u64,
    history_preview: ?HistoryPreviewAuthority = null,
    push_error_instance_id: ?u64,
    commit_panel_instance_id: ?u64,
};

pub fn classify(origin: Origin, current: Snapshot) Liveness {
    return switch (origin) {
        .page => |captured| classifyPage(captured, current),
        .history_preview => |captured| blk: {
            const page_liveness = classifyPage(captured.page, current);
            if (page_liveness == .stale) break :blk .stale;
            const authority = current.history_preview orelse break :blk .stale;
            if (!captured.authority.eql(authority)) break :blk .stale;
            break :blk page_liveness;
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

fn classifyPage(captured: PageOrigin, current: Snapshot) Liveness {
    const activation_matches = switch (captured.page_id) {
        .changes => captured.activation_id == current.changes_activation_id,
        .repository => captured.activation_id == current.repository_activation_id,
        .history => captured.activation_id == current.history_activation_id,
        .compare => captured.activation_id == current.compare_activation_id,
        .config => true,
    };
    if (captured.repo_epoch != current.repo_epoch or !activation_matches) return .stale;
    return if (captured.page_id == current.active_page) .live_active else .live_inactive;
}

test "repository selection inactive page accepts same-instance clipboard completion" {
    const current: Snapshot = .{
        .active_page = .changes,
        .repo_epoch = 4,
        .changes_activation_id = 9,
        .repository_activation_id = 5,
        .compare_activation_id = 6,
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

    var history_current = current;
    history_current.active_page = .history;
    history_current.history_activation_id = 7;
    history_current.history_preview = .{ .selection_generation = 3, .copy_generation = 2 };
    const history_origin: Origin = .{ .history_preview = .{
        .page = .{ .page_id = .history, .repo_epoch = 4, .activation_id = 7 },
        .authority = .{ .selection_generation = 3, .copy_generation = 2 },
    } };
    try @import("std").testing.expectEqual(Liveness.live_active, classify(history_origin, history_current));
    history_current.history_preview.?.selection_generation = 4;
    try @import("std").testing.expectEqual(Liveness.stale, classify(history_origin, history_current));
}

test "reopened shell surface rejects prior clipboard completion" {
    const current: Snapshot = .{
        .active_page = .changes,
        .repo_epoch = 4,
        .changes_activation_id = 9,
        .repository_activation_id = 5,
        .compare_activation_id = 6,
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
