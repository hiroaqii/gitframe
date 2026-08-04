const std = @import("std");

pub const Id = enum {
    review,
    repository,
    compare,
    config,

    pub fn label(self: Id) []const u8 {
        return switch (self) {
            .review => "Review",
            .repository => "Repository",
            .compare => "Compare",
            .config => "Config",
        };
    }

    pub fn placeholderDescription(self: Id) []const u8 {
        return switch (self) {
            .review => "Working-tree review",
            .repository => "Repository browser is not initialized",
            .compare => "Compare: not loaded",
            .config => "Configuration viewer is not initialized",
        };
    }
};

pub const all = [_]Id{ .review, .repository, .compare, .config };

/// Scheduling identity shared by every page-owned asynchronous read.
///
/// `repo_epoch` is advanced only when the shell commits a different active
/// repository identity. `activation_id` identifies the page activation which
/// requested the read; matching inactive results may still update retained
/// page data, but cannot grant authority to a later activation.
pub const RequestIdentity = struct {
    origin: Id,
    repo_epoch: u64,
    activation_id: u64,

    pub fn review(repo_epoch: u64, activation_id: u64) RequestIdentity {
        std.debug.assert(activation_id != 0);
        return .{
            .origin = .review,
            .repo_epoch = repo_epoch,
            .activation_id = activation_id,
        };
    }

    pub fn compare(repo_epoch: u64, activation_id: u64) RequestIdentity {
        std.debug.assert(activation_id != 0);
        return .{
            .origin = .compare,
            .repo_epoch = repo_epoch,
            .activation_id = activation_id,
        };
    }
};

pub const Tab = struct {
    id: Id,
    col: u16,
    width: u16,
};

/// Page-bar geometry used by both rendering and mouse hit testing.
/// Column zero and the one-column gaps between labels are intentional
/// whitespace and never resolve to a page.
pub fn tab(id: Id) Tab {
    var col: u16 = 1;
    for (all) |candidate| {
        const width: u16 = @intCast(candidate.label().len + 2);
        if (candidate == id) return .{ .id = candidate, .col = col, .width = width };
        col +|= width +| 1;
    }
    unreachable;
}

pub fn tabAtColumn(bar_width: u16, col: u16) ?Id {
    if (col >= bar_width) return null;
    for (all) |id| {
        const candidate = tab(id);
        if (candidate.col >= bar_width) return null;
        const end = @min(@as(u32, candidate.col) + candidate.width, bar_width);
        if (col >= candidate.col and col < end) return id;
    }
    return null;
}

/// A non-Review page slot remains allocation-free until its owner replaces
/// this placeholder with real state.
pub const LazyPlaceholder = struct {
    initialized: bool = false,

    pub fn ensureInitialized(self: *LazyPlaceholder) void {
        self.initialized = true;
    }
};

test "page vocabulary has stable visible order" {
    try std.testing.expectEqualStrings("Review", all[0].label());
    try std.testing.expectEqualStrings("Repository", all[1].label());
    try std.testing.expectEqualStrings("Compare", all[2].label());
    try std.testing.expectEqualStrings("Config", all[3].label());
}

test "Compare request identity is distinct from Review" {
    const review = RequestIdentity.review(3, 7);
    const compare = RequestIdentity.compare(3, 7);
    try std.testing.expectEqual(Id.review, review.origin);
    try std.testing.expectEqual(Id.compare, compare.origin);
    try std.testing.expect(review.origin != compare.origin);
}

test "placeholder is lazy" {
    var placeholder: LazyPlaceholder = .{};
    try std.testing.expect(!placeholder.initialized);
    placeholder.ensureInitialized();
    try std.testing.expect(placeholder.initialized);
}

test "page bar hit testing excludes margins and gaps" {
    const review_tab = tab(.review);
    const repository_tab = tab(.repository);
    try std.testing.expect(tabAtColumn(80, 0) == null);
    try std.testing.expectEqual(Id.review, tabAtColumn(80, review_tab.col).?);
    try std.testing.expectEqual(Id.review, tabAtColumn(80, review_tab.col + review_tab.width - 1).?);
    try std.testing.expect(tabAtColumn(80, review_tab.col + review_tab.width) == null);
    try std.testing.expectEqual(Id.repository, tabAtColumn(80, repository_tab.col).?);
    try std.testing.expect(tabAtColumn(repository_tab.col, repository_tab.col) == null);
}
