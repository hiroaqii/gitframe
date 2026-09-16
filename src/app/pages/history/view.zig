//! History catalog rendering. Rows are projected only for the current
//! viewport and clipped through Chasen UI's terminal-cell presentation.

const std = @import("std");
const chasen = @import("chasen");
const text_presentation = @import("chasen_ui").text_presentation;
const branch_commit_time = @import("../../branch_commit_time.zig");
const git_history = @import("../../../git/history.zig");
const history_page = @import("../history.zig");
const theme = @import("theme");

const row_prefix_width: u16 = 5;

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
            const labels = if (size.width >= 100)
                "    commit   subject  [A anchor  │ range  M merge  R root  ? unavailable]"
            else
                "    commit   subject  [A anchor  │ range  M/R type]";
            break :blk try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s}", .{ labels, suffix });
        };
        try drawClipped(surface, 0, 1, columns, context.palette.style(.muted));
    }

    const range = page.catalog.visibleRange(size.height);
    for (range.start..range.end) |index| {
        const row: u16 = @intCast(2 + index - range.start);
        if (row >= size.height) break;
        const focused = index == page.catalog.cursor;
        if (index == page.catalog.records.items.len) {
            const markers = try std.fmt.allocPrint(surface.frameAllocator(), "{s}  … ", .{if (focused) "›" else " "});
            try drawClipped(surface, 0, row, markers, if (focused) context.palette.boldStyle(.accent) else context.palette.style(.prompt));
            const label = if (page.load_state == .loading) "Loading older commits…" else "Load 200 older commits…";
            try drawClipped(surface, row_prefix_width, row, label, if (focused) context.palette.boldStyle(.prompt) else context.palette.style(.prompt));
            continue;
        }
        const record = &page.catalog.records.items[index];
        const range_marker: []const u8 = if (page.draft.anchor()) |anchor|
            if (index == anchor) "A" else if (page.draft.contains(page.catalog.cursor, index)) "│" else " "
        else
            " ";
        const markers = try std.fmt.allocPrint(surface.frameAllocator(), "{s}{s} {s} ", .{
            if (focused) "›" else " ",
            range_marker,
            topologyMarker(record),
        });
        try drawClipped(surface, 0, row, markers, if (focused) context.palette.boldStyle(.accent) else context.palette.style(.muted));
        const line = try commitRowTextAlloc(surface.frameAllocator(), record, page.render_now_unix, size.width -| row_prefix_width);
        try drawClipped(surface, row_prefix_width, row, line, if (focused) context.palette.boldStyle(.foreground) else context.palette.style(.foreground));
    }
}

fn topologyMarker(record: *const git_history.Record) []const u8 {
    return switch (record.first_parent) {
        .true_root => "R",
        .missing => "?",
        .available => if (record.parent_count > 1) "M" else " ",
    };
}

/// Preserve marker, topology, short OID, and subject. Optional row facts are
/// removed in the contract order: author, refs, then time.
fn commitRowTextAlloc(
    allocator: std.mem.Allocator,
    record: *const git_history.Record,
    now_unix: ?i64,
    available_width: u16,
) ![]const u8 {
    const short_oid = record.oid.short();
    const relative = branch_commit_time.formatRelative(record.committer_unix, now_unix);
    const mandatory_width = chasen.text.displayWidth(short_oid) + 2 + chasen.text.displayWidth(record.subject);
    const time_width = 2 + chasen.text.displayWidth(relative.text());
    const refs_width = if (record.decorations.len == 0) 0 else 4 + chasen.text.displayWidth(record.decorations);
    const author_width = if (record.author.len == 0) 0 else chasen.text.displayWidth("  — ") + chasen.text.displayWidth(record.author);

    var show_time = time_width > 0;
    var show_refs = refs_width > 0;
    var show_author = author_width > 0;
    var total = mandatory_width + time_width + refs_width + author_width;
    if (total > available_width and show_author) {
        total -|= author_width;
        show_author = false;
    }
    if (total > available_width and show_refs) {
        total -|= refs_width;
        show_refs = false;
    }
    if (total > available_width and show_time) {
        show_time = false;
    }

    if (show_author and show_refs) return std.fmt.allocPrint(allocator, "{s}  {s}  {s}  ({s})  — {s}", .{
        short_oid, record.subject, relative.text(), record.decorations, record.author,
    });
    if (show_author) return std.fmt.allocPrint(allocator, "{s}  {s}  {s}  — {s}", .{
        short_oid, record.subject, relative.text(), record.author,
    });
    if (show_refs) return std.fmt.allocPrint(allocator, "{s}  {s}  {s}  ({s})", .{
        short_oid, record.subject, relative.text(), record.decorations,
    });
    if (show_time) return std.fmt.allocPrint(allocator, "{s}  {s}  {s}", .{ short_oid, record.subject, relative.text() });
    return std.fmt.allocPrint(allocator, "{s}  {s}", .{ short_oid, record.subject });
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

test "History catalog renders selected rows at 80x24 and 120x32" {
    const allocator = std.testing.allocator;
    const head = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const parent = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const root = try git_history.ObjectId.parse(.sha1, "3333333333333333333333333333333333333333");
    const records = try allocator.alloc(git_history.Record, 3);
    records[0] = .{
        .oid = head,
        .parent_count = 2,
        .first_parent = .{ .available = parent },
        .author = try allocator.dupe(u8, "Ada Lovelace"),
        .committer_unix = 1_720_000_000,
        .decorations = try allocator.dupe(u8, "HEAD -> main"),
        .subject = try allocator.dupe(u8, "catalog head"),
    };
    records[1] = .{
        .oid = parent,
        .parent_count = 1,
        .first_parent = .{ .available = root },
        .author = try allocator.dupe(u8, "Grace Hopper"),
        .committer_unix = 1_710_000_000,
        .decorations = try allocator.dupe(u8, ""),
        .subject = try allocator.dupe(u8, "catalog middle"),
    };
    records[2] = .{
        .oid = root,
        .parent_count = 0,
        .first_parent = .true_root,
        .author = try allocator.dupe(u8, "Margaret Hamilton"),
        .committer_unix = 1_700_000_000,
        .decorations = try allocator.dupe(u8, "root-tag"),
        .subject = try allocator.dupe(u8, "日本語 root subject"),
    };
    var page: git_history.Page = .{
        .snapshot = .{
            .object_format = .sha1,
            .head = head,
            .display = .{ .branch = try allocator.dupe(u8, "main") },
        },
        .records = records,
    };
    defer page.deinit(allocator);
    var page_state: history_page.HistoryPageState = .{ .load_state = .loaded };
    defer page_state.deinit(allocator);
    try page_state.catalog.replace(allocator, &page);
    page_state.render_now_unix = 1_720_086_400;
    page_state.draft = .{ .range = 0 };
    page_state.catalog.cursor = 2;

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
        try std.testing.expect(std.mem.indexOf(u8, snapshot, " A M 1111111") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "›│ R 3333333") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "root subject") != null);
        if (size.width == 120) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "Ada Lovelace") != null);
        }
    }
}

test "History row projection drops author refs and time in that order" {
    const allocator = std.testing.allocator;
    const oid = try git_history.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const parent = try git_history.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const record: git_history.Record = .{
        .oid = oid,
        .parent_count = 1,
        .first_parent = .{ .available = parent },
        .author = @constCast("Ada"),
        .committer_unix = 1_720_000_000,
        .decorations = @constCast("main"),
        .subject = @constCast("subject"),
    };
    const mandatory_width = chasen.text.displayWidth("1111111  subject");
    const now_unix: i64 = 1_720_086_400;
    const time_width = chasen.text.displayWidth("  1d ago");
    const refs_width = chasen.text.displayWidth("  (main)");

    const without_author = try commitRowTextAlloc(allocator, &record, now_unix, @intCast(mandatory_width + time_width + refs_width));
    defer allocator.free(without_author);
    try std.testing.expect(std.mem.indexOf(u8, without_author, "1d ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_author, "(main)") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_author, "Ada") == null);

    const without_refs = try commitRowTextAlloc(allocator, &record, now_unix, @intCast(mandatory_width + time_width));
    defer allocator.free(without_refs);
    try std.testing.expect(std.mem.indexOf(u8, without_refs, "1d ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_refs, "(main)") == null);

    const mandatory_only = try commitRowTextAlloc(allocator, &record, now_unix, @intCast(mandatory_width));
    defer allocator.free(mandatory_only);
    try std.testing.expectEqualStrings("1111111  subject", mandatory_only);
}
