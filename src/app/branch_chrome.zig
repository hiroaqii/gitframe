//! Pure branch-status label formatting shared by page-local chrome.
//!
//! This module owns visible wording, Unicode-aware clipping, and typed width
//! evidence only. Review and Repository retain ownership of snapshot
//! freshness, loading terminals, action hints, and every Git operation.

const std = @import("std");
const chasen = @import("chasen");
const git_branch_status = @import("../git/branch_status.zig");

pub const FormatResult = struct {
    /// Owned by this result until the caller deinitializes it or explicitly
    /// transfers the slice into the same allocator lifetime.
    text: []u8,
    full_display_width: u16,
    was_clipped: bool,

    pub fn deinit(self: *FormatResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

/// Format the base branch label within `available_width` terminal cells.
///
/// `full_display_width` measures the unclipped label and `was_clipped` records
/// the width decision directly. Callers can therefore compose optional chrome
/// without parsing an ellipsis back out of `text`.
pub fn formatBaseLabel(
    allocator: std.mem.Allocator,
    status: git_branch_status.BranchStatus,
    available_width: u16,
) std.mem.Allocator.Error!FormatResult {
    return switch (status.head) {
        .branch => |name| formatBranch(allocator, name, status, available_width),
        .detached => formatLiteral(allocator, "detached", available_width),
        .unknown => formatLiteral(allocator, "unknown branch", available_width),
    };
}

fn formatBranch(
    allocator: std.mem.Allocator,
    branch: []const u8,
    status: git_branch_status.BranchStatus,
    available_width: u16,
) std.mem.Allocator.Error!FormatResult {
    var allocated_suffix: ?[]u8 = null;
    defer if (allocated_suffix) |suffix| allocator.free(suffix);

    const suffix: []const u8 = if (status.upstream == null)
        " no upstream"
    else blk: {
        const ahead = if (status.ahead_behind) |ab| ab.ahead else 0;
        allocated_suffix = try std.fmt.allocPrint(allocator, " ↑{d}", .{ahead});
        break :blk allocated_suffix.?;
    };

    const suffix_width = chasen.text.displayWidth(suffix);
    const full_display_width = chasen.text.displayWidth(branch) +| suffix_width;
    const was_clipped = full_display_width > available_width;

    if (!was_clipped) {
        return .{
            .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ branch, suffix }),
            .full_display_width = full_display_width,
            .was_clipped = false,
        };
    }

    // When even the suffix does not fit, preserve the old visible behavior:
    // the generic row clip showed the suffix's leading cells plus a marker.
    if (available_width <= suffix_width) {
        return .{
            .text = try markedClipToOwned(allocator, suffix, available_width),
            .full_display_width = full_display_width,
            .was_clipped = true,
        };
    }

    const branch_width = available_width - suffix_width;
    const display_branch = try branchPrefixTail(allocator, branch, branch_width);
    defer allocator.free(display_branch);
    return .{
        .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ display_branch, suffix }),
        .full_display_width = full_display_width,
        .was_clipped = true,
    };
}

fn formatLiteral(allocator: std.mem.Allocator, text: []const u8, available_width: u16) std.mem.Allocator.Error!FormatResult {
    const full_display_width = chasen.text.displayWidth(text);
    return .{
        .text = try markedClipToOwned(allocator, text, available_width),
        .full_display_width = full_display_width,
        .was_clipped = full_display_width > available_width,
    };
}

fn branchPrefixTail(allocator: std.mem.Allocator, branch: []const u8, width: u16) std.mem.Allocator.Error![]u8 {
    if (width == 0) return allocator.dupe(u8, "");
    if (chasen.text.displayWidth(branch) <= width) return allocator.dupe(u8, branch);
    const slash = std.mem.indexOfScalar(u8, branch, '/') orelse return markedClipToOwned(allocator, branch, width);
    const prefix = branch[0 .. slash + 1];
    const marker = "…";
    const prefix_width = chasen.text.displayWidth(prefix);
    const marker_width = chasen.text.displayWidth(marker);
    if (width <= prefix_width + marker_width) return markedClipToOwned(allocator, branch, width);

    // Keep branch class prefixes such as "feature/" while preserving the
    // ticket/topic tail that usually disambiguates long branch names.
    const tail_width = width - prefix_width - marker_width;
    const tail_source = branch[slash + 1 ..];
    const tail_source_width = chasen.text.displayWidth(tail_source);
    const tail = chasen.text.dropToWidth(tail_source, tail_source_width -| tail_width);
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, marker, tail });
}

fn markedClipToOwned(allocator: std.mem.Allocator, text: []const u8, width: u16) std.mem.Allocator.Error![]u8 {
    const clipped = chasen.text.clipToWidthWithMarker(text, width, "…");
    if (clipped.marker.len == 0) return allocator.dupe(u8, clipped.prefix);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ clipped.prefix, clipped.marker });
}

test "branch chrome formats upstream and no-upstream labels" {
    var with_upstream = try formatBaseLabel(std.testing.allocator, .{
        .head = .{ .branch = "feature/topic" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 2, .behind = 7 },
    }, 80);
    defer with_upstream.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("feature/topic ↑2", with_upstream.text);
    try std.testing.expect(!with_upstream.was_clipped);

    var without_upstream = try formatBaseLabel(std.testing.allocator, .{
        .head = .{ .branch = "feature/topic" },
    }, 80);
    defer without_upstream.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("feature/topic no upstream", without_upstream.text);
    try std.testing.expect(!without_upstream.was_clipped);
}

test "branch chrome keeps branch prefix and tail when clipped" {
    var result = try formatBaseLabel(std.testing.allocator, .{
        .head = .{ .branch = "feature/very-long-ticket-name" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 0 },
    }, 22);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.was_clipped);
    try std.testing.expect(result.full_display_width > 22);
    try std.testing.expect(chasen.text.displayWidth(result.text) <= 22);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "feature/…"));
    try std.testing.expect(std.mem.endsWith(u8, result.text, " ↑0"));
}

test "branch chrome reports exact-fit and one-cell-short width evidence" {
    const status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 0 },
    };
    const full_width = chasen.text.displayWidth("main ↑0");

    var exact = try formatBaseLabel(std.testing.allocator, status, full_width);
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("main ↑0", exact.text);
    try std.testing.expectEqual(full_width, exact.full_display_width);
    try std.testing.expect(!exact.was_clipped);

    var short = try formatBaseLabel(std.testing.allocator, status, full_width - 1);
    defer short.deinit(std.testing.allocator);
    try std.testing.expectEqual(full_width, short.full_display_width);
    try std.testing.expect(short.was_clipped);
    try std.testing.expect(chasen.text.displayWidth(short.text) <= full_width - 1);
}

test "branch chrome clips upstream and no-upstream suffix-only widths" {
    const Case = struct {
        width: u16,
        expected: []const u8,
    };
    const upstream_status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "main" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 0, .behind = 0 },
    };
    const upstream_full_width = chasen.text.displayWidth("main ↑0");
    const upstream_cases = [_]Case{
        .{ .width = 3, .expected = " ↑0" },
        .{ .width = 2, .expected = " …" },
        .{ .width = 1, .expected = "…" },
        .{ .width = 0, .expected = "" },
    };
    for (upstream_cases) |case| {
        var result = try formatBaseLabel(std.testing.allocator, upstream_status, case.width);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.text);
        try std.testing.expect(chasen.text.displayWidth(result.text) <= case.width);
        try std.testing.expectEqual(upstream_full_width, result.full_display_width);
        try std.testing.expect(result.was_clipped);
    }

    const no_upstream_status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "main" },
    };
    const no_upstream_full_width = chasen.text.displayWidth("main no upstream");
    const no_upstream_cases = [_]Case{
        .{ .width = 12, .expected = " no upstream" },
        .{ .width = 11, .expected = " no upstre…" },
        .{ .width = 1, .expected = "…" },
        .{ .width = 0, .expected = "" },
    };
    for (no_upstream_cases) |case| {
        var result = try formatBaseLabel(std.testing.allocator, no_upstream_status, case.width);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(case.expected, result.text);
        try std.testing.expect(chasen.text.displayWidth(result.text) <= case.width);
        try std.testing.expectEqual(no_upstream_full_width, result.full_display_width);
        try std.testing.expect(result.was_clipped);
    }
}

test "branch chrome clips Unicode labels on grapheme boundaries" {
    var result = try formatBaseLabel(std.testing.allocator, .{
        .head = .{ .branch = "feature/日本語-ticket" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 3, .behind = 0 },
    }, 18);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.was_clipped);
    try std.testing.expect(chasen.text.displayWidth(result.text) <= 18);
    try std.testing.expect(std.unicode.utf8ValidateSlice(result.text));
    try std.testing.expect(std.mem.startsWith(u8, result.text, "feature/…"));
    try std.testing.expect(std.mem.endsWith(u8, result.text, " ↑3"));
}

test "branch chrome formats and clips detached and unknown terminals" {
    var detached = try formatBaseLabel(std.testing.allocator, .{ .head = .detached }, 3);
    defer detached.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("de…", detached.text);
    try std.testing.expectEqual(@as(u16, 8), detached.full_display_width);
    try std.testing.expect(detached.was_clipped);

    var unknown = try formatBaseLabel(std.testing.allocator, .{ .head = .unknown }, 80);
    defer unknown.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("unknown branch", unknown.text);
    try std.testing.expectEqual(chasen.text.displayWidth("unknown branch"), unknown.full_display_width);
    try std.testing.expect(!unknown.was_clipped);
}

test "branch chrome releases every partial allocation on clipped upstream failure" {
    const status: git_branch_status.BranchStatus = .{
        .head = .{ .branch = "feature/very-long-ticket-name" },
        .upstream = .{ .name = "origin/main", .remote = "origin", .remote_branch = "main" },
        .ahead_behind = .{ .ahead = 12, .behind = 3 },
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn format(allocator: std.mem.Allocator, branch_status: git_branch_status.BranchStatus) !void {
            var result = try formatBaseLabel(allocator, branch_status, 22);
            defer result.deinit(allocator);
        }
    }.format, .{status});
}
