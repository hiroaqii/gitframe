//! Shell-owned page transition policy.
//!
//! Keyboard, page-bar mouse input, and the future Session API all request a
//! page change through the same pure disposition function. This module owns no
//! App state; callers provide the small blocker snapshot required by the page
//! transition policy.

const std = @import("std");
const page = @import("page.zig");

pub const Blocker = enum {
    changes_mouse_selection,
    review_mouse_selection,
    repository_mouse_selection,
    changes_deferred_apply,
    review_deferred_apply,
    changes_search,
    changes_file_search,
    review_search,
    review_file_search,
    repository_source_search,
    repository_file_search,
    repo_picker,
    help,
    commit_input,
    confirmation,
    branch_switch,
    review_base_picker,
    push_error,
    git_action,
    foreground_command,
    live_review_waiter,
    teardown,

    pub fn message(self: Blocker) []const u8 {
        return switch (self) {
            .changes_mouse_selection => "finish mouse selection before switching pages",
            .review_mouse_selection => "finish Review mouse selection before switching pages",
            .repository_mouse_selection => "finish Repository mouse selection before switching pages",
            .changes_deferred_apply => "finish deferred Changes update before switching pages",
            .review_deferred_apply => "finish deferred Review update before switching pages",
            .changes_search => "finish search before switching pages",
            .changes_file_search => "finish file search before switching pages",
            .review_search => "finish Review search before switching pages",
            .review_file_search => "finish Review file search before switching pages",
            .repository_source_search => "finish source search before switching pages",
            .repository_file_search => "finish file search before switching pages",
            .repo_picker => "close repository picker before switching pages",
            .help => "close help before switching pages",
            .commit_input => "close commit input before switching pages",
            .confirmation => "finish confirmation before switching pages",
            .branch_switch => "finish branch switch before switching pages",
            .review_base_picker => "close Review base picker before switching pages",
            .push_error => "close push error before switching pages",
            .git_action => "finish current git action before switching pages",
            .foreground_command => "finish foreground command before switching pages",
            .live_review_waiter => "finish review session before switching pages",
            .teardown => "application is shutting down",
        };
    }
};

pub const Snapshot = struct {
    changes_mouse_selection: bool = false,
    review_mouse_selection: bool = false,
    repository_mouse_selection: bool = false,
    changes_deferred_apply: bool = false,
    review_deferred_apply: bool = false,
    changes_search: bool = false,
    changes_file_search: bool = false,
    review_search: bool = false,
    review_file_search: bool = false,
    repository_source_search: bool = false,
    repository_file_search: bool = false,
    repo_picker: bool = false,
    help: bool = false,
    commit_input: bool = false,
    confirmation: bool = false,
    branch_switch: bool = false,
    review_base_picker: bool = false,
    push_error: bool = false,
    git_action: bool = false,
    foreground_command: bool = false,
    live_review_waiter: bool = false,
    teardown: bool = false,
};

pub const Disposition = union(enum) {
    unchanged,
    allowed,
    blocked: Blocker,
};

pub fn disposition(active: page.Id, target: page.Id, snapshot: Snapshot) Disposition {
    if (active == target) return .unchanged;
    if (snapshot.teardown) return .{ .blocked = .teardown };
    if (snapshot.git_action) return .{ .blocked = .git_action };
    if (snapshot.foreground_command) return .{ .blocked = .foreground_command };
    if (snapshot.live_review_waiter) return .{ .blocked = .live_review_waiter };
    if (snapshot.repo_picker) return .{ .blocked = .repo_picker };
    if (snapshot.help) return .{ .blocked = .help };
    if (snapshot.commit_input) return .{ .blocked = .commit_input };
    if (snapshot.confirmation) return .{ .blocked = .confirmation };
    if (snapshot.branch_switch) return .{ .blocked = .branch_switch };
    if (snapshot.review_base_picker) return .{ .blocked = .review_base_picker };
    if (snapshot.push_error) return .{ .blocked = .push_error };
    if (snapshot.changes_search) return .{ .blocked = .changes_search };
    if (snapshot.changes_file_search) return .{ .blocked = .changes_file_search };
    if (snapshot.review_search) return .{ .blocked = .review_search };
    if (snapshot.review_file_search) return .{ .blocked = .review_file_search };
    if (snapshot.repository_source_search) return .{ .blocked = .repository_source_search };
    if (snapshot.repository_file_search) return .{ .blocked = .repository_file_search };
    if (snapshot.changes_mouse_selection) return .{ .blocked = .changes_mouse_selection };
    if (snapshot.review_mouse_selection) return .{ .blocked = .review_mouse_selection };
    if (snapshot.repository_mouse_selection) return .{ .blocked = .repository_mouse_selection };
    if (snapshot.changes_deferred_apply) return .{ .blocked = .changes_deferred_apply };
    if (snapshot.review_deferred_apply) return .{ .blocked = .review_deferred_apply };
    return .allowed;
}

test "ordinary reads do not block page transitions" {
    try std.testing.expectEqual(Disposition.allowed, disposition(.changes, .repository, .{}));
}

test "live review waiter and teardown are explicit transition blockers" {
    try std.testing.expectEqual(
        Disposition{ .blocked = .live_review_waiter },
        disposition(.changes, .repository, .{ .live_review_waiter = true }),
    );
    try std.testing.expectEqual(
        Disposition{ .blocked = .teardown },
        disposition(.changes, .repository, .{ .teardown = true }),
    );
}

test "transition policy is conservative and leaves same-page requests unchanged" {
    try std.testing.expectEqual(Disposition.unchanged, disposition(.changes, .changes, .{ .git_action = true }));
    try std.testing.expectEqual(
        Disposition{ .blocked = .git_action },
        disposition(.changes, .review, .{ .git_action = true, .changes_search = true }),
    );
    try std.testing.expectEqual(
        Disposition{ .blocked = .changes_mouse_selection },
        disposition(.changes, .config, .{ .changes_mouse_selection = true }),
    );
}

test "repository prompt modes block mouse initiated page transitions" {
    try std.testing.expectEqual(
        Disposition{ .blocked = .repository_source_search },
        disposition(.repository, .changes, .{ .repository_source_search = true }),
    );
    try std.testing.expectEqual(
        Disposition{ .blocked = .repository_file_search },
        disposition(.repository, .review, .{ .repository_file_search = true }),
    );
}

test "repository selection transition blocks every page switch" {
    try std.testing.expectEqual(
        Disposition{ .blocked = .repository_mouse_selection },
        disposition(.repository, .changes, .{ .repository_mouse_selection = true }),
    );
}

test "Changes Repository transitions reject every blocker in both directions" {
    const cases = [_]struct {
        blocker: Blocker,
        snapshot: Snapshot,
    }{
        .{ .blocker = .changes_mouse_selection, .snapshot = .{ .changes_mouse_selection = true } },
        .{ .blocker = .review_mouse_selection, .snapshot = .{ .review_mouse_selection = true } },
        .{ .blocker = .repository_mouse_selection, .snapshot = .{ .repository_mouse_selection = true } },
        .{ .blocker = .changes_deferred_apply, .snapshot = .{ .changes_deferred_apply = true } },
        .{ .blocker = .review_deferred_apply, .snapshot = .{ .review_deferred_apply = true } },
        .{ .blocker = .changes_search, .snapshot = .{ .changes_search = true } },
        .{ .blocker = .changes_file_search, .snapshot = .{ .changes_file_search = true } },
        .{ .blocker = .review_search, .snapshot = .{ .review_search = true } },
        .{ .blocker = .review_file_search, .snapshot = .{ .review_file_search = true } },
        .{ .blocker = .repository_source_search, .snapshot = .{ .repository_source_search = true } },
        .{ .blocker = .repository_file_search, .snapshot = .{ .repository_file_search = true } },
        .{ .blocker = .repo_picker, .snapshot = .{ .repo_picker = true } },
        .{ .blocker = .help, .snapshot = .{ .help = true } },
        .{ .blocker = .commit_input, .snapshot = .{ .commit_input = true } },
        .{ .blocker = .confirmation, .snapshot = .{ .confirmation = true } },
        .{ .blocker = .branch_switch, .snapshot = .{ .branch_switch = true } },
        .{ .blocker = .review_base_picker, .snapshot = .{ .review_base_picker = true } },
        .{ .blocker = .push_error, .snapshot = .{ .push_error = true } },
        .{ .blocker = .git_action, .snapshot = .{ .git_action = true } },
        .{ .blocker = .foreground_command, .snapshot = .{ .foreground_command = true } },
        .{ .blocker = .live_review_waiter, .snapshot = .{ .live_review_waiter = true } },
        .{ .blocker = .teardown, .snapshot = .{ .teardown = true } },
    };
    const directions = [_]struct { active: page.Id, target: page.Id }{
        .{ .active = .changes, .target = .repository },
        .{ .active = .repository, .target = .changes },
    };

    try std.testing.expectEqual(std.meta.fields(Blocker).len, cases.len);
    for (cases) |case| {
        for (directions) |direction| {
            try std.testing.expectEqual(
                Disposition{ .blocked = case.blocker },
                disposition(direction.active, direction.target, case.snapshot),
            );
        }
    }
}
