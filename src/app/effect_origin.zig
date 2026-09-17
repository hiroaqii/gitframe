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

pub const CompareAiReviewHandoffOrigin = struct {
    page: PageOrigin,
    modal_instance_id: u64,
    copy_generation: u64,
};

pub const CompareAiReviewHandoffAuthority = struct {
    modal_instance_id: u64,
    copy_generation: u64,
};

pub const HistoryCommitDetailOrigin = struct {
    page: PageOrigin,
    modal_instance_id: u64,
    copy_generation: u64,
};

pub const HistoryCommitDetailAuthority = struct {
    modal_instance_id: u64,
    copy_generation: u64,
};

pub const Origin = union(enum) {
    page: PageOrigin,
    shell_surface: ShellSurfaceOrigin,
    compare_ai_review_handoff: CompareAiReviewHandoffOrigin,
    history_commit_detail: HistoryCommitDetailOrigin,
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
    ai_reviews_activation_id: u64,
    push_error_instance_id: ?u64,
    commit_panel_instance_id: ?u64,
    compare_ai_review_handoff: ?CompareAiReviewHandoffAuthority = null,
    history_commit_detail: ?HistoryCommitDetailAuthority = null,
};

pub fn classify(origin: Origin, current: Snapshot) Liveness {
    return switch (origin) {
        .page => |captured| classifyPage(captured, current),
        .shell_surface => |captured| blk: {
            const current_instance = switch (captured.surface) {
                .push_error => current.push_error_instance_id,
                .commit_panel => current.commit_panel_instance_id,
            };
            if (current_instance == null or current_instance.? != captured.instance_id) break :blk .stale;
            break :blk .live_active;
        },
        .compare_ai_review_handoff => |captured| blk: {
            const page_liveness = classifyPage(captured.page, current);
            if (page_liveness == .stale) break :blk .stale;
            const authority = current.compare_ai_review_handoff orelse break :blk .stale;
            if (authority.modal_instance_id != captured.modal_instance_id or
                authority.copy_generation != captured.copy_generation) break :blk .stale;
            break :blk page_liveness;
        },
        .history_commit_detail => |captured| blk: {
            const page_liveness = classifyPage(captured.page, current);
            if (page_liveness == .stale) break :blk .stale;
            const authority = current.history_commit_detail orelse break :blk .stale;
            if (authority.modal_instance_id != captured.modal_instance_id or
                authority.copy_generation != captured.copy_generation) break :blk .stale;
            break :blk page_liveness;
        },
    };
}

fn classifyPage(captured: PageOrigin, current: Snapshot) Liveness {
    const activation_matches = switch (captured.page_id) {
        .changes => captured.activation_id == current.changes_activation_id,
        .repository => captured.activation_id == current.repository_activation_id,
        .history => captured.activation_id == current.history_activation_id,
        .compare => captured.activation_id == current.compare_activation_id,
        .ai_reviews => captured.activation_id == current.ai_reviews_activation_id,
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
        .ai_reviews_activation_id = 7,
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
        .compare_activation_id = 6,
        .ai_reviews_activation_id = 7,
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

test "AI Review Handoff origin requires exact modal instance and latest copy generation" {
    const current: Snapshot = .{
        .active_page = .compare,
        .repo_epoch = 4,
        .changes_activation_id = 9,
        .repository_activation_id = 5,
        .compare_activation_id = 6,
        .ai_reviews_activation_id = 7,
        .push_error_instance_id = null,
        .commit_panel_instance_id = null,
        .compare_ai_review_handoff = .{ .modal_instance_id = 12, .copy_generation = 3 },
    };
    const exact: Origin = .{ .compare_ai_review_handoff = .{
        .page = .{ .page_id = .compare, .repo_epoch = 4, .activation_id = 6 },
        .modal_instance_id = 12,
        .copy_generation = 3,
    } };
    try @import("std").testing.expectEqual(Liveness.live_active, classify(exact, current));

    var old_instance = exact;
    old_instance.compare_ai_review_handoff.modal_instance_id = 11;
    try @import("std").testing.expectEqual(Liveness.stale, classify(old_instance, current));
    var old_copy = exact;
    old_copy.compare_ai_review_handoff.copy_generation = 2;
    try @import("std").testing.expectEqual(Liveness.stale, classify(old_copy, current));
    var closed = current;
    closed.compare_ai_review_handoff = null;
    try @import("std").testing.expectEqual(Liveness.stale, classify(exact, closed));
}

test "History commit detail origin requires live page exact instance and latest generation" {
    const current: Snapshot = .{
        .active_page = .history,
        .repo_epoch = 8,
        .changes_activation_id = 1,
        .repository_activation_id = 2,
        .history_activation_id = 3,
        .compare_activation_id = 4,
        .ai_reviews_activation_id = 5,
        .push_error_instance_id = null,
        .commit_panel_instance_id = null,
        .history_commit_detail = .{ .modal_instance_id = 6, .copy_generation = 7 },
    };
    const exact: Origin = .{ .history_commit_detail = .{
        .page = .{ .page_id = .history, .repo_epoch = 8, .activation_id = 3 },
        .modal_instance_id = 6,
        .copy_generation = 7,
    } };
    try @import("std").testing.expectEqual(Liveness.live_active, classify(exact, current));
    var old_generation = exact;
    old_generation.history_commit_detail.copy_generation = 6;
    try @import("std").testing.expectEqual(Liveness.stale, classify(old_generation, current));
    var replaced = current;
    replaced.history_commit_detail.?.modal_instance_id = 9;
    try @import("std").testing.expectEqual(Liveness.stale, classify(exact, replaced));
    var inactive = current;
    inactive.active_page = .changes;
    try @import("std").testing.expectEqual(Liveness.live_inactive, classify(exact, inactive));
    var closed = current;
    closed.history_commit_detail = null;
    try @import("std").testing.expectEqual(Liveness.stale, classify(exact, closed));
}
