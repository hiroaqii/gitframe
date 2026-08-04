//! Shell-owned page transition policy.
//!
//! Keyboard, page-bar mouse input, and the future Session API all request a
//! page change through the same pure disposition function. This module owns no
//! App state; callers provide the small blocker snapshot required by the
//! reviewed Phase 9 transition matrix.

const std = @import("std");
const page = @import("page.zig");

pub const Blocker = enum {
    review_mouse_selection,
    repository_mouse_selection,
    review_deferred_apply,
    review_search,
    review_file_search,
    repository_source_search,
    repository_file_search,
    repo_picker,
    help,
    commit_input,
    confirmation,
    credential_input,
    branch_switch,
    push_error,
    git_action,
    foreground_command,
    live_review_waiter,
    teardown,

    pub fn message(self: Blocker) []const u8 {
        return switch (self) {
            .review_mouse_selection => "finish mouse selection before switching pages",
            .repository_mouse_selection => "finish Repository mouse selection before switching pages",
            .review_deferred_apply => "finish deferred Review update before switching pages",
            .review_search => "finish search before switching pages",
            .review_file_search => "finish file search before switching pages",
            .repository_source_search => "finish source search before switching pages",
            .repository_file_search => "finish file search before switching pages",
            .repo_picker => "close repository picker before switching pages",
            .help => "close help before switching pages",
            .commit_input => "close commit input before switching pages",
            .confirmation => "finish confirmation before switching pages",
            .credential_input => "close credential input before switching pages",
            .branch_switch => "finish branch switch before switching pages",
            .push_error => "close push error before switching pages",
            .git_action => "finish current git action before switching pages",
            .foreground_command => "finish foreground command before switching pages",
            .live_review_waiter => "finish review session before switching pages",
            .teardown => "application is shutting down",
        };
    }
};

pub const Snapshot = struct {
    review_mouse_selection: bool = false,
    repository_mouse_selection: bool = false,
    review_deferred_apply: bool = false,
    review_search: bool = false,
    review_file_search: bool = false,
    repository_source_search: bool = false,
    repository_file_search: bool = false,
    repo_picker: bool = false,
    help: bool = false,
    commit_input: bool = false,
    confirmation: bool = false,
    credential_input: bool = false,
    branch_switch: bool = false,
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
    if (snapshot.credential_input) return .{ .blocked = .credential_input };
    if (snapshot.branch_switch) return .{ .blocked = .branch_switch };
    if (snapshot.push_error) return .{ .blocked = .push_error };
    if (snapshot.review_search) return .{ .blocked = .review_search };
    if (snapshot.review_file_search) return .{ .blocked = .review_file_search };
    if (snapshot.repository_source_search) return .{ .blocked = .repository_source_search };
    if (snapshot.repository_file_search) return .{ .blocked = .repository_file_search };
    if (snapshot.review_mouse_selection) return .{ .blocked = .review_mouse_selection };
    if (snapshot.repository_mouse_selection) return .{ .blocked = .repository_mouse_selection };
    if (snapshot.review_deferred_apply) return .{ .blocked = .review_deferred_apply };
    return .allowed;
}

test "ordinary reads do not block page transitions" {
    try std.testing.expectEqual(Disposition.allowed, disposition(.review, .repository, .{}));
}

test "live review waiter and teardown are explicit transition blockers" {
    try std.testing.expectEqual(
        Disposition{ .blocked = .live_review_waiter },
        disposition(.review, .repository, .{ .live_review_waiter = true }),
    );
    try std.testing.expectEqual(
        Disposition{ .blocked = .teardown },
        disposition(.review, .repository, .{ .teardown = true }),
    );
}

test "transition policy is conservative and leaves same-page requests unchanged" {
    try std.testing.expectEqual(Disposition.unchanged, disposition(.review, .review, .{ .git_action = true }));
    try std.testing.expectEqual(
        Disposition{ .blocked = .git_action },
        disposition(.review, .compare, .{ .git_action = true, .review_search = true }),
    );
    try std.testing.expectEqual(
        Disposition{ .blocked = .review_mouse_selection },
        disposition(.review, .config, .{ .review_mouse_selection = true }),
    );
}

test "repository prompt modes block mouse initiated page transitions" {
    try std.testing.expectEqual(
        Disposition{ .blocked = .repository_source_search },
        disposition(.repository, .review, .{ .repository_source_search = true }),
    );
    try std.testing.expectEqual(
        Disposition{ .blocked = .repository_file_search },
        disposition(.repository, .compare, .{ .repository_file_search = true }),
    );
}

test "repository selection slice B transition blocks every page switch" {
    try std.testing.expectEqual(
        Disposition{ .blocked = .repository_mouse_selection },
        disposition(.repository, .review, .{ .repository_mouse_selection = true }),
    );
}

test "Review Repository transitions reject every blocker in both directions" {
    const cases = [_]struct {
        blocker: Blocker,
        snapshot: Snapshot,
    }{
        .{ .blocker = .review_mouse_selection, .snapshot = .{ .review_mouse_selection = true } },
        .{ .blocker = .repository_mouse_selection, .snapshot = .{ .repository_mouse_selection = true } },
        .{ .blocker = .review_deferred_apply, .snapshot = .{ .review_deferred_apply = true } },
        .{ .blocker = .review_search, .snapshot = .{ .review_search = true } },
        .{ .blocker = .review_file_search, .snapshot = .{ .review_file_search = true } },
        .{ .blocker = .repository_source_search, .snapshot = .{ .repository_source_search = true } },
        .{ .blocker = .repository_file_search, .snapshot = .{ .repository_file_search = true } },
        .{ .blocker = .repo_picker, .snapshot = .{ .repo_picker = true } },
        .{ .blocker = .help, .snapshot = .{ .help = true } },
        .{ .blocker = .commit_input, .snapshot = .{ .commit_input = true } },
        .{ .blocker = .confirmation, .snapshot = .{ .confirmation = true } },
        .{ .blocker = .credential_input, .snapshot = .{ .credential_input = true } },
        .{ .blocker = .branch_switch, .snapshot = .{ .branch_switch = true } },
        .{ .blocker = .push_error, .snapshot = .{ .push_error = true } },
        .{ .blocker = .git_action, .snapshot = .{ .git_action = true } },
        .{ .blocker = .foreground_command, .snapshot = .{ .foreground_command = true } },
        .{ .blocker = .live_review_waiter, .snapshot = .{ .live_review_waiter = true } },
        .{ .blocker = .teardown, .snapshot = .{ .teardown = true } },
    };
    const directions = [_]struct { active: page.Id, target: page.Id }{
        .{ .active = .review, .target = .repository },
        .{ .active = .repository, .target = .review },
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
