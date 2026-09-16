//! History catalog rendering. Rows are projected only for the current
//! viewport and clipped through Chasen UI's terminal-cell presentation.

const std = @import("std");
const chasen = @import("chasen");
const text_presentation = @import("chasen_ui").text_presentation;
const branch_commit_time = @import("../../branch_commit_time.zig");
const git_history = @import("../../../git/history.zig");
const history_page = @import("../history.zig");
const theme = @import("theme");

pub const ViewContext = struct {
    page_state: *const history_page.HistoryPageState,
    palette: theme.Palette,
};

pub fn view(context: ViewContext, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const page = context.page_state;

    if (page.load_state == .no_repository) {
        drawState(surface, context.palette, "History", "Repository required", "R: switch repository");
        return;
    }
    if (page.catalog.snapshot == null) {
        if (page.load_state == .failed) {
            drawState(surface, context.palette, "History unavailable", page.status.text(), "r: retry");
        } else if (page.load_state == .idle) {
            drawState(surface, context.palette, "History", page.status.text(), "r: retry");
        } else {
            drawState(surface, context.palette, "History", "Loading commit history…", "Esc: cancel");
        }
        return;
    }

    const snapshot = &page.catalog.snapshot.?;
    const head_text = switch (snapshot.display) {
        .branch => |branch| try std.fmt.allocPrint(surface.frameAllocator(), "History  {s}  {s}", .{ branch, snapshot.head.?.short() }),
        .detached => try std.fmt.allocPrint(surface.frameAllocator(), "History  detached@{s}", .{snapshot.head.?.short()}),
        .unborn => |branch| try std.fmt.allocPrint(surface.frameAllocator(), "History  {s}  unborn", .{branch}),
    };
    try drawClipped(surface, 0, 0, head_text, context.palette.boldStyle(.accent));

    if (page.catalog.records.items.len == 0) {
        if (size.height > 2) try drawClipped(surface, 2, 2, "No commits yet", context.palette.style(.muted));
        return;
    }

    if (size.height > 1) {
        const columns = if (page.catalog.capped)
            "History limit reached: 2,000 commits loaded"
        else blk: {
            const suffix = if (page.load_state == .loading)
                "  ·  loading…"
            else
                "";
            break :blk try std.fmt.allocPrint(surface.frameAllocator(), "  commit   date        subject{s}", .{suffix});
        };
        try drawClipped(surface, 0, 1, columns, context.palette.style(.muted));
    }

    const range = page.catalog.visibleRange(size.height);
    for (range.start..range.end) |index| {
        const row: u16 = @intCast(2 + index - range.start);
        if (row >= size.height) break;
        const focused = index == page.catalog.cursor;
        const marker = if (focused) "›" else " ";
        try drawClipped(surface, 0, row, marker, if (focused) context.palette.boldStyle(.accent) else context.palette.style(.muted));
        if (index == page.catalog.records.items.len) {
            const label = if (page.load_state == .loading) "Loading older commits…" else "Load 200 older commits…";
            try drawClipped(surface, 2, row, label, if (focused) context.palette.boldStyle(.prompt) else context.palette.style(.prompt));
            continue;
        }
        const record = &page.catalog.records.items[index];
        const date = if (branch_commit_time.formatExactUtc(record.committer_unix)) |exact| exact.text()[0..10] else "----------";
        const decorations = if (record.decorations.len == 0)
            ""
        else
            try std.fmt.allocPrint(surface.frameAllocator(), "  ({s})", .{record.decorations});
        const author = if (size.width >= 110)
            try std.fmt.allocPrint(surface.frameAllocator(), "  — {s}", .{record.author})
        else
            "";
        const line = try std.fmt.allocPrint(surface.frameAllocator(), "{s}  {s}  {s}{s}{s}", .{
            record.oid.short(), date, record.subject, decorations, author,
        });
        try drawClipped(surface, 2, row, line, if (focused) context.palette.boldStyle(.foreground) else context.palette.style(.foreground));
    }
}

fn drawState(surface: *chasen.Surface, palette: theme.Palette, title: []const u8, body: []const u8, hint: []const u8) void {
    const size = surface.size();
    const row = size.height / 2;
    drawClipped(surface, 2, row, title, palette.boldStyle(.accent)) catch {};
    if (row + 1 < size.height) drawClipped(surface, 2, row + 1, body, palette.style(.muted)) catch {};
    if (row + 2 < size.height) drawClipped(surface, 2, row + 2, hint, palette.style(.prompt)) catch {};
}

fn drawClipped(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, style: chasen.TextStyle) !void {
    try text_presentation.drawClippedAt(surface, col, row, text, style, .{
        .tab_width = 4,
        .marker = "…",
        .direction = .head,
    });
}

test "History catalog renders the same accepted rows at 80x24 and 120x32" {
    const allocator = std.testing.allocator;
    const head = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const parent = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const records = try allocator.alloc(git_history.Record, 2);
    records[0] = .{
        .oid = head,
        .parent_count = 1,
        .first_parent = .{ .available = parent },
        .author = try allocator.dupe(u8, "Ada Lovelace"),
        .committer_unix = 1_720_000_000,
        .decorations = try allocator.dupe(u8, "HEAD -> main"),
        .subject = try allocator.dupe(u8, "catalog head"),
    };
    records[1] = .{
        .oid = parent,
        .parent_count = 0,
        .first_parent = .true_root,
        .author = try allocator.dupe(u8, "Grace Hopper"),
        .committer_unix = 1_710_000_000,
        .decorations = try allocator.dupe(u8, ""),
        .subject = try allocator.dupe(u8, "catalog root"),
    };
    var accepted: git_history.Page = .{
        .snapshot = .{
            .object_format = .sha1,
            .head = head,
            .display = .{ .branch = try allocator.dupe(u8, "main") },
        },
        .records = records,
        .continuation = parent,
    };
    defer accepted.deinit(allocator);
    var page_state: history_page.HistoryPageState = .{ .load_state = .loaded };
    defer page_state.deinit(allocator);
    try page_state.catalog.replace(allocator, &accepted);

    for ([_]chasen.Size{
        .{ .width = 80, .height = 24 },
        .{ .width = 120, .height = 32 },
    }) |size| {
        var rendered: chasen.testing.TestSurface = undefined;
        try rendered.init(size.width, size.height);
        defer rendered.deinit();
        try view(.{ .page_state = &page_state, .palette = .default() }, &rendered.surface);
        const snapshot = try rendered.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "History  main  1111111") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "catalog head") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Load 200 older commits") != null);
        if (size.width == 120) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ada Lovelace") != null);
        }
    }
}
