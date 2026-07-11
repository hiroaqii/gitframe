pub const Id = enum {
    review,
    repository,
    history,
    config,

    pub fn label(self: Id) []const u8 {
        return switch (self) {
            .review => "Review",
            .repository => "Repository",
            .history => "History",
            .config => "Config",
        };
    }

    pub fn placeholderDescription(self: Id) []const u8 {
        return switch (self) {
            .review => "Working-tree review",
            .repository => "Repository browser is not initialized",
            .history => "History browser is not initialized",
            .config => "Configuration viewer is not initialized",
        };
    }
};

pub const all = [_]Id{ .review, .repository, .history, .config };

/// A non-Review page slot remains allocation-free until its owning phase
/// replaces this placeholder with a real state owner.
pub const LazyPlaceholder = struct {
    initialized: bool = false,

    pub fn ensureInitialized(self: *LazyPlaceholder) void {
        self.initialized = true;
    }
};

test "page vocabulary has stable visible order" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Review", all[0].label());
    try std.testing.expectEqualStrings("Repository", all[1].label());
    try std.testing.expectEqualStrings("History", all[2].label());
    try std.testing.expectEqualStrings("Config", all[3].label());
}

test "placeholder is lazy" {
    const std = @import("std");
    var placeholder: LazyPlaceholder = .{};
    try std.testing.expect(!placeholder.initialized);
    placeholder.ensureInitialized();
    try std.testing.expect(placeholder.initialized);
}
