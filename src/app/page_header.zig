//! Display-only repository context for the shell page bar.
//!
//! Page owners admit accepted snapshots into these borrowed values. The shell
//! may format and draw them, but no operation target or repository authority
//! crosses this boundary.

const std = @import("std");
const chasen = @import("chasen");

pub const Freshness = enum {
    fresh,
    refreshing,
    stale,
};

pub const Upstream = union(enum) {
    ahead: u32,
    no_upstream,
};

pub const BranchHeadContext = struct {
    display_name: []const u8,
    upstream: Upstream,
    freshness: Freshness,
};

/// Only a named branch can carry upstream state. Detached and unknown HEADs
/// therefore cannot be combined with an ahead count or no-upstream label.
pub const HeadContext = union(enum) {
    branch: BranchHeadContext,
    detached: Freshness,
    unknown: Freshness,
};

pub const ComparisonContext = struct {
    base_display_name: []const u8,
    head_display_name: []const u8,
    freshness: Freshness,
};

pub const Terminal = struct {
    kind: Kind,
    state: State,

    pub const Kind = enum { head, comparison };
    pub const State = enum { loading, unavailable };
};

pub const Presentation = union(enum) {
    head: HeadContext,
    comparison: ComparisonContext,
    terminal: Terminal,

    pub fn tone(self: Presentation) Tone {
        return switch (self) {
            .head, .comparison => .fact,
            .terminal => .terminal,
        };
    }
};

pub const Tone = enum { fact, terminal };

/// Format one already-admitted presentation into at most `available_width`
/// cells. `null` means the complete semantic unit cannot be shown safely.
pub fn formatAlloc(
    allocator: std.mem.Allocator,
    presentation: Presentation,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    return switch (presentation) {
        .head => |head| formatHead(allocator, head, available_width),
        .comparison => |comparison| formatComparison(allocator, comparison, available_width),
        .terminal => |terminal| formatTerminal(allocator, terminal, available_width),
    };
}

fn formatHead(
    allocator: std.mem.Allocator,
    head: HeadContext,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    const prefix = "HEAD ";
    const prefix_width = chasen.text.displayWidth(prefix);
    if (available_width < prefix_width) return null;

    return switch (head) {
        .branch => |branch| blk: {
            const name_width = chasen.text.displayWidth(branch.display_name);
            if (name_width == 0) break :blk null;

            var owned_upstream: ?[]u8 = null;
            defer if (owned_upstream) |text| allocator.free(text);
            const upstream: []const u8 = switch (branch.upstream) {
                .ahead => |ahead| value: {
                    owned_upstream = try std.fmt.allocPrint(allocator, " ↑{d}", .{ahead});
                    break :value owned_upstream.?;
                },
                .no_upstream => " no upstream",
            };
            const freshness = freshnessSuffix(branch.freshness);
            const suffix_width = @as(u32, chasen.text.displayWidth(upstream)) +
                chasen.text.displayWidth(freshness);
            const fixed_width = @as(u32, prefix_width) + suffix_width;
            if (fixed_width > available_width) break :blk null;

            const name_available: u16 = @intCast(@as(u32, available_width) - fixed_width);
            const required_name_width: u16 = if (name_width <= 5) name_width else 5;
            if (name_available < required_name_width) break :blk null;
            const display_name = (try branchNameAlloc(allocator, branch.display_name, name_available)) orelse
                break :blk null;
            defer allocator.free(display_name);
            break :blk try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{
                prefix,
                display_name,
                upstream,
                freshness,
            });
        },
        .detached => |freshness| formatHeadLiteral(
            allocator,
            prefix,
            "detached",
            freshness,
            available_width,
        ),
        .unknown => |freshness| formatHeadLiteral(
            allocator,
            prefix,
            "unknown branch",
            freshness,
            available_width,
        ),
    };
}

fn formatHeadLiteral(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    value: []const u8,
    freshness: Freshness,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    const suffix = freshnessSuffix(freshness);
    const required = @as(u32, chasen.text.displayWidth(prefix)) +
        chasen.text.displayWidth(value) +
        chasen.text.displayWidth(suffix);
    if (required > available_width) return null;
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, value, suffix });
}

fn formatComparison(
    allocator: std.mem.Allocator,
    comparison: ComparisonContext,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    const prefix = "BASE ";
    const separator = "  …  HEAD ";
    const freshness = freshnessSuffix(comparison.freshness);
    const base_width = chasen.text.displayWidth(comparison.base_display_name);
    const head_width = chasen.text.displayWidth(comparison.head_display_name);
    if (base_width == 0 or head_width == 0) return null;

    const fixed_width = @as(u32, chasen.text.displayWidth(prefix)) +
        chasen.text.displayWidth(separator) +
        chasen.text.displayWidth(freshness);
    if (fixed_width > available_width) return null;
    const names_available: u16 = @intCast(@as(u32, available_width) - fixed_width);

    const base_min = endpointMinimumWidth(comparison.base_display_name);
    const head_min = endpointMinimumWidth(comparison.head_display_name);
    if (@as(u32, base_min) + head_min > names_available) return null;

    var base_budget = base_min;
    var head_budget = head_min;
    var extra = names_available - base_min - head_min;
    while (extra > 0) : (extra -= 1) {
        const base_remaining = base_width -| base_budget;
        const head_remaining = head_width -| head_budget;
        if (base_remaining == 0 and head_remaining == 0) break;
        if (base_remaining >= head_remaining and base_remaining > 0) {
            base_budget += 1;
        } else {
            head_budget += 1;
        }
    }

    const base = (try middleElideAlloc(allocator, comparison.base_display_name, base_budget)) orelse return null;
    defer allocator.free(base);
    const head = (try middleElideAlloc(allocator, comparison.head_display_name, head_budget)) orelse return null;
    defer allocator.free(head);
    return try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}", .{
        prefix,
        base,
        separator,
        head,
        freshness,
    });
}

fn formatTerminal(
    allocator: std.mem.Allocator,
    terminal: Terminal,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    const text: []const u8 = switch (terminal.kind) {
        .head => switch (terminal.state) {
            .loading => "HEAD loading",
            .unavailable => "HEAD unavailable",
        },
        .comparison => switch (terminal.state) {
            .loading => "Comparison loading",
            .unavailable => "Comparison unavailable",
        },
    };
    if (chasen.text.displayWidth(text) > available_width) return null;
    return try allocator.dupe(u8, text);
}

fn freshnessSuffix(freshness: Freshness) []const u8 {
    return switch (freshness) {
        .fresh => "",
        .refreshing => " loading",
        .stale => " stale",
    };
}

fn endpointMinimumWidth(text: []const u8) u16 {
    const width = chasen.text.displayWidth(text);
    if (width <= 3) return width;
    return @min(width, @max(@as(u16, 3), elidedEdgeWidth(text)));
}

fn branchNameAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    if (chasen.text.displayWidth(name) <= available_width) return try allocator.dupe(u8, name);

    if (std.mem.indexOfScalar(u8, name, '/')) |slash| {
        const prefix = name[0 .. slash + 1];
        const tail_source = name[slash + 1 ..];
        const prefix_width = chasen.text.displayWidth(prefix);
        const last_width = lastGraphemeWidth(tail_source) orelse 0;
        if (last_width > 0 and @as(u32, prefix_width) + 1 + last_width <= available_width) {
            const tail_budget: u16 = @intCast(@as(u32, available_width) - prefix_width - 1);
            const tail = suffixToWidth(tail_source, tail_budget);
            if (tail.len > 0) return try std.fmt.allocPrint(allocator, "{s}…{s}", .{ prefix, tail });
        }
    }

    return middleElideAlloc(allocator, name, available_width);
}

fn middleElideAlloc(
    allocator: std.mem.Allocator,
    text: []const u8,
    available_width: u16,
) std.mem.Allocator.Error!?[]u8 {
    const full_width = chasen.text.displayWidth(text);
    if (full_width <= available_width) return try allocator.dupe(u8, text);

    const edge_width = elidedEdgeWidth(text);
    if (edge_width == 0 or available_width < edge_width) return null;
    const first_width = firstGraphemeWidth(text) orelse return null;
    const last_width = lastGraphemeWidth(text) orelse return null;

    const content_width = available_width - 1;
    var prefix_budget: u16 = (content_width + 1) / 2;
    var suffix_budget: u16 = content_width - prefix_budget;
    if (prefix_budget < first_width) {
        prefix_budget = first_width;
        suffix_budget = content_width - prefix_budget;
    }
    if (suffix_budget < last_width) {
        suffix_budget = last_width;
        prefix_budget = content_width - suffix_budget;
    }

    const prefix = chasen.text.clipToWidth(text, prefix_budget);
    const suffix = suffixToWidth(text, suffix_budget);
    if (prefix.len == 0 or suffix.len == 0) return null;
    return try std.fmt.allocPrint(allocator, "{s}…{s}", .{ prefix, suffix });
}

fn elidedEdgeWidth(text: []const u8) u16 {
    const first = firstGraphemeWidth(text) orelse return 0;
    const last = lastGraphemeWidth(text) orelse return 0;
    return first +| 1 +| last;
}

fn firstGraphemeWidth(text: []const u8) ?u16 {
    var iter = chasen.text.graphemeIterator(text);
    const grapheme = iter.next() orelse return null;
    return chasen.text.displayWidth(grapheme.bytes(text));
}

fn lastGraphemeWidth(text: []const u8) ?u16 {
    var result: ?u16 = null;
    var iter = chasen.text.graphemeIterator(text);
    while (iter.next()) |grapheme| result = chasen.text.displayWidth(grapheme.bytes(text));
    return result;
}

fn suffixToWidth(text: []const u8, available_width: u16) []const u8 {
    const full_width = chasen.text.displayWidth(text);
    if (full_width <= available_width) return text;
    return chasen.text.dropToWidth(text, full_width - available_width);
}

test "page header formats HEAD branch variants and whole suffixes" {
    const ahead = (try formatAlloc(std.testing.allocator, .{ .head = .{ .branch = .{
        .display_name = "feature/review-surface",
        .upstream = .{ .ahead = 2 },
        .freshness = .fresh,
    } } }, 80)).?;
    defer std.testing.allocator.free(ahead);
    try std.testing.expectEqualStrings("HEAD feature/review-surface ↑2", ahead);

    const no_upstream = (try formatAlloc(std.testing.allocator, .{ .head = .{ .branch = .{
        .display_name = "main",
        .upstream = .no_upstream,
        .freshness = .stale,
    } } }, 80)).?;
    defer std.testing.allocator.free(no_upstream);
    try std.testing.expectEqualStrings("HEAD main no upstream stale", no_upstream);
}

test "page header branch uses exact five-cell clipped minimum" {
    const presentation: Presentation = .{ .head = .{ .branch = .{
        .display_name = "abcdefghij",
        .upstream = .{ .ahead = 0 },
        .freshness = .refreshing,
    } } };
    const suffix_width = chasen.text.displayWidth("HEAD  ↑0 loading");
    try std.testing.expect((try formatAlloc(std.testing.allocator, presentation, suffix_width + 4)) == null);
    const text = (try formatAlloc(std.testing.allocator, presentation, suffix_width + 5)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("HEAD ab…ij ↑0 loading", text);

    const short: Presentation = .{ .head = .{ .branch = .{
        .display_name = "main",
        .upstream = .no_upstream,
        .freshness = .fresh,
    } } };
    try std.testing.expect((try formatAlloc(std.testing.allocator, short, 20)) == null);
    const short_text = (try formatAlloc(std.testing.allocator, short, 21)).?;
    defer std.testing.allocator.free(short_text);
    try std.testing.expectEqualStrings("HEAD main no upstream", short_text);
}

test "page header preserves slash tail and Unicode grapheme boundaries" {
    const presentation: Presentation = .{ .head = .{ .branch = .{
        .display_name = "feature/日本e\u{301}ticket",
        .upstream = .{ .ahead = 3 },
        .freshness = .fresh,
    } } };
    const text = (try formatAlloc(std.testing.allocator, presentation, 21)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));
    try std.testing.expect(std.mem.startsWith(u8, text, "HEAD feature/…"));
    try std.testing.expect(std.mem.endsWith(u8, text, " ↑3"));

    const wide_edges: Presentation = .{ .head = .{ .branch = .{
        .display_name = "日abcdef本",
        .upstream = .{ .ahead = 0 },
        .freshness = .fresh,
    } } };
    const exact = (try formatAlloc(std.testing.allocator, wide_edges, 13)).?;
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("HEAD 日…本 ↑0", exact);

    const combining_edges: Presentation = .{ .head = .{ .branch = .{
        .display_name = "e\u{301}abcdefx\u{301}",
        .upstream = .{ .ahead = 0 },
        .freshness = .fresh,
    } } };
    const combining = (try formatAlloc(std.testing.allocator, combining_edges, 13)).?;
    defer std.testing.allocator.free(combining);
    try std.testing.expectEqualStrings("HEAD e\u{301}a…fx\u{301} ↑0", combining);
}

test "page header admits detached and unknown only at whole literal boundaries" {
    const detached: Presentation = .{ .head = .{ .detached = .fresh } };
    try std.testing.expect((try formatAlloc(std.testing.allocator, detached, 12)) == null);
    const detached_text = (try formatAlloc(std.testing.allocator, detached, 13)).?;
    defer std.testing.allocator.free(detached_text);
    try std.testing.expectEqualStrings("HEAD detached", detached_text);

    const unknown: Presentation = .{ .head = .{ .unknown = .fresh } };
    try std.testing.expect((try formatAlloc(std.testing.allocator, unknown, 18)) == null);
    const unknown_text = (try formatAlloc(std.testing.allocator, unknown, 19)).?;
    defer std.testing.allocator.free(unknown_text);
    try std.testing.expectEqualStrings("HEAD unknown branch", unknown_text);
}

test "page header terminals require their complete wording" {
    const Case = struct {
        terminal: Terminal,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .terminal = .{ .kind = .head, .state = .loading }, .expected = "HEAD loading" },
        .{ .terminal = .{ .kind = .head, .state = .unavailable }, .expected = "HEAD unavailable" },
        .{ .terminal = .{ .kind = .comparison, .state = .loading }, .expected = "Comparison loading" },
        .{ .terminal = .{ .kind = .comparison, .state = .unavailable }, .expected = "Comparison unavailable" },
    };
    for (cases) |case| {
        const presentation: Presentation = .{ .terminal = case.terminal };
        const width = chasen.text.displayWidth(case.expected);
        try std.testing.expect((try formatAlloc(std.testing.allocator, presentation, width - 1)) == null);
        const text = (try formatAlloc(std.testing.allocator, presentation, width)).?;
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings(case.expected, text);
    }
}

test "page header comparison keeps both endpoints or omits the whole pair" {
    const presentation: Presentation = .{ .comparison = .{
        .base_display_name = "origin/very-long-main",
        .head_display_name = "feature/very-long-topic",
        .freshness = .fresh,
    } };
    try std.testing.expect((try formatAlloc(std.testing.allocator, presentation, 20)) == null);
    const minimum = (try formatAlloc(std.testing.allocator, presentation, 21)).?;
    defer std.testing.allocator.free(minimum);
    try std.testing.expect(std.mem.indexOf(u8, minimum, "  …  HEAD ") != null);
    const text = (try formatAlloc(std.testing.allocator, presentation, 28)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "BASE "));
    try std.testing.expect(std.mem.indexOf(u8, text, "  …  HEAD ") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "…") != null);
    try std.testing.expect(chasen.text.displayWidth(text) <= 28);

    const short_wide: Presentation = .{ .comparison = .{
        .base_display_name = "日本",
        .head_display_name = "日本",
        .freshness = .fresh,
    } };
    try std.testing.expect((try formatAlloc(std.testing.allocator, short_wide, 22)) == null);
    const short_wide_exact = (try formatAlloc(std.testing.allocator, short_wide, 23)).?;
    defer std.testing.allocator.free(short_wide_exact);
    try std.testing.expectEqualStrings("BASE 日本  …  HEAD 日本", short_wide_exact);
}

test "page header comparison treats display names as opaque and has no upstream suffix" {
    const presentation: Presentation = .{ .comparison = .{
        .base_display_name = "tag:v1.2.3",
        .head_display_name = "HEAD@0123456",
        .freshness = .refreshing,
    } };
    const text = (try formatAlloc(std.testing.allocator, presentation, 80)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("BASE tag:v1.2.3  …  HEAD HEAD@0123456 loading", text);
    try std.testing.expect(std.mem.indexOf(u8, text, "↑") == null);
}

test "page header formatter releases partial allocations on failure" {
    const presentation: Presentation = .{ .head = .{ .branch = .{
        .display_name = "feature/very-long-topic",
        .upstream = .{ .ahead = 123 },
        .freshness = .stale,
    } } };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn format(allocator: std.mem.Allocator, value: Presentation) !void {
            const result = try formatAlloc(allocator, value, 24);
            if (result) |text| allocator.free(text);
        }
    }.format, .{presentation});
}
