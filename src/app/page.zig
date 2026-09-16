const std = @import("std");

pub const Id = enum {
    changes,
    repository,
    history,
    compare,
    ai_reviews,
    config,

    pub fn label(self: Id) []const u8 {
        return switch (self) {
            .changes => "Changes",
            .repository => "Repository",
            .history => "History",
            .compare => "Compare",
            .ai_reviews => "AI Reviews",
            .config => "Config",
        };
    }

    pub fn placeholderDescription(self: Id) []const u8 {
        return switch (self) {
            .changes => "Working-tree changes",
            .repository => "Repository browser is not initialized",
            .history => "Commit history is not loaded",
            .compare => "Compare: not loaded",
            .ai_reviews => "AI Reviews: select a review",
            .config => "Configuration viewer is not initialized",
        };
    }
};

pub const all = [_]Id{ .changes, .repository, .history, .compare, .ai_reviews, .config };

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

    pub fn changes(repo_epoch: u64, activation_id: u64) RequestIdentity {
        std.debug.assert(activation_id != 0);
        return .{
            .origin = .changes,
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

    pub fn history(repo_epoch: u64, activation_id: u64) RequestIdentity {
        std.debug.assert(activation_id != 0);
        return .{
            .origin = .history,
            .repo_epoch = repo_epoch,
            .activation_id = activation_id,
        };
    }

    pub fn aiReviews(repo_epoch: u64, activation_id: u64) RequestIdentity {
        std.debug.assert(activation_id != 0);
        return .{
            .origin = .ai_reviews,
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

/// Exclusive end of the fixed normal-mode tab reservation.
pub fn tabExtent() u16 {
    const last = tab(all[all.len - 1]);
    return last.col +| last.width;
}

/// A non-Changes page slot remains allocation-free until its owner replaces
/// this placeholder with real state.
pub const LazyPlaceholder = struct {
    initialized: bool = false,

    pub fn ensureInitialized(self: *LazyPlaceholder) void {
        self.initialized = true;
    }
};

test "page vocabulary has stable visible order" {
    try std.testing.expectEqualStrings("Changes", all[0].label());
    try std.testing.expectEqualStrings("Repository", all[1].label());
    try std.testing.expectEqualStrings("History", all[2].label());
    try std.testing.expectEqualStrings("Compare", all[3].label());
    try std.testing.expectEqualStrings("AI Reviews", all[4].label());
    try std.testing.expectEqualStrings("Config", all[5].label());
}

test "History Compare and AI Reviews request identities are distinct" {
    const changes = RequestIdentity.changes(3, 7);
    const history = RequestIdentity.history(3, 7);
    const compare = RequestIdentity.compare(3, 7);
    const ai_reviews = RequestIdentity.aiReviews(3, 7);
    try std.testing.expectEqual(Id.changes, changes.origin);
    try std.testing.expectEqual(Id.history, history.origin);
    try std.testing.expectEqual(Id.compare, compare.origin);
    try std.testing.expectEqual(Id.ai_reviews, ai_reviews.origin);
    try std.testing.expect(changes.origin != compare.origin);
    try std.testing.expect(changes.origin != history.origin);
    try std.testing.expect(history.origin != compare.origin);
    try std.testing.expect(compare.origin != ai_reviews.origin);
}

test "placeholder is lazy" {
    var placeholder: LazyPlaceholder = .{};
    try std.testing.expect(!placeholder.initialized);
    placeholder.ensureInitialized();
    try std.testing.expect(placeholder.initialized);
}

test "page bar hit testing excludes margins and gaps" {
    const changes_tab = tab(.changes);
    const repository_tab = tab(.repository);
    const history_tab = tab(.history);
    try std.testing.expect(tabAtColumn(80, 0) == null);
    try std.testing.expectEqual(Id.changes, tabAtColumn(80, changes_tab.col).?);
    try std.testing.expectEqual(Id.changes, tabAtColumn(80, changes_tab.col + changes_tab.width - 1).?);
    try std.testing.expect(tabAtColumn(80, changes_tab.col + changes_tab.width) == null);
    try std.testing.expectEqual(Id.repository, tabAtColumn(80, repository_tab.col).?);
    try std.testing.expectEqual(Id.history, tabAtColumn(80, history_tab.col).?);
    try std.testing.expect(tabAtColumn(repository_tab.col, repository_tab.col) == null);
}

test "page bar context starts after fixed tabs and remains a non-target" {
    const config = tab(.config);
    try std.testing.expectEqual(config.col + config.width, tabExtent());
    try std.testing.expect(tabAtColumn(80, tabExtent()) == null);
    try std.testing.expect(tabAtColumn(80, tabExtent() + 1) == null);
}
