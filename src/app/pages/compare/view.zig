//! Compare presentation built exclusively from shared diff-surface renderers.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const compare_page = @import("../compare.zig");
const commit_time = @import("commit_time.zig");
const compare_navigation = @import("navigation.zig");
const diff_surface = @import("../../diff_surface.zig");
const root_capability = @import("../../../repo/root_capability.zig");

pub const Context = struct {
    page: *const compare_page.ComparePageState,
    palette: theme.Palette,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,

    pub fn footer(self: Context) diff_surface.view.FooterView {
        return diff_surface.view.footer(.{
            .surface = self.page.readSurface(.{ .range = "compare" }, self.layout),
            .auto_reload_enabled = false,
        });
    }
};

pub fn view(app: Context, surface: *chasen.Surface) !void {
    const navigation_context = navigationView(app);
    var pane_adapter = DiffPaneAdapter{ .context = navigation_context, .palette = app.palette };
    const branch = try branchPresentation(app, surface.frameAllocator());
    const empty_message: ?diff_surface.view.StateMessage = if (app.page.basis) |basis|
        try emptyStateMessage(surface.frameAllocator(), basis.base.display_name, basis.ahead_count)
    else
        null;

    if (!app.page.hasAcceptedDisplay() and (app.page.basis_failure != null or app.page.load_failure != null)) {
        return viewInitialFailure(app, surface);
    }

    try diff_surface.view.view(surface, .{
        .state = app.page.readSurface(.{ .range = "compare" }, app.layout),
        .palette = app.palette,
        .source_label = "branch comparison",
        .no_changes_actions = .{},
        .empty_message = empty_message,
        .branch = branch,
        .diff_pane = pane_adapter.interface(),
    });
}

pub fn viewBasePicker(app: Context, surface: *chasen.Surface) !void {
    const picker = app.page.base_picker;
    if (!picker.open) return;

    const opts: ui.Modal.ViewOptions = .{
        .dialog_width = @min(surface.size().width, 96),
        .dialog_height = @min(surface.size().height, 22),
        .title = "Compare base",
        .backdrop = false,
        .border = .rounded,
        .title_style = app.palette.boldStyle(.accent),
        .border_style = app.palette.style(.accent),
    };
    const frame = ui.Modal.frame(surface, opts) orelse return;
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
    frame.view();
    var content = frame.contentSurface();
    const size = content.size();
    if (size.height == 0) return;

    const list = picker.accepted;
    const visible_count = picker.visibleCount();
    const has_candidates = list != null and list.?.branches.len > 0 and visible_count > 0;
    const show_detail = has_candidates and size.height >= 4;
    const show_current = size.height >= if (show_detail) @as(u16, 5) else @as(u16, 4);
    const footer_row = size.height - 1;
    var next_row: u16 = 0;

    // Filter, one body row, and footer are the compact core. As height shrinks,
    // current-base is omitted before selected detail, and selected detail is
    // omitted before the final candidate/status row.
    if (show_current) {
        const current = if (app.page.basis) |basis|
            try std.fmt.allocPrint(content.frameAllocator(), "Current base: {s}", .{basis.base.display_name})
        else
            "Current base: resolving default";
        try draw.copyClippedTextAt(&content, 0, next_row, current, app.palette.style(.muted));
        next_row += 1;
    }

    if (next_row < footer_row) {
        const filter_prefix = if (picker.input_mode == .query) "Filter: /" else "Filter: ";
        try draw.copyClippedTextAt(&content, 0, next_row, filter_prefix, app.palette.style(.prompt));
        const prefix_width = content.displayWidth(filter_prefix);
        if (prefix_width < size.width) {
            var query_surface = content.child(.{
                .col = prefix_width,
                .row = next_row,
                .width = size.width - prefix_width,
                .height = 1,
            });
            try draw.copyClippedTextAt(&query_surface, 0, 0, picker.query.slice(), chasen.TextStyle{});
        }
        if (picker.input_mode == .query and size.width > 0) {
            const cursor = @min(size.width - 1, prefix_width + content.displayWidth(picker.query.slice()));
            content.showCursor(cursor, next_row);
        }
        next_row += 1;
    }

    if (show_detail and next_row < footer_row) {
        if (picker.selectedItem()) |item| {
            const exact = commit_time.formatExactUtc(item.tip_committer_unix);
            const detail = if (exact) |value|
                try std.fmt.allocPrint(content.frameAllocator(), "last commit: {s}  {s}", .{ value.text(), item.full_ref })
            else
                try std.fmt.allocPrint(content.frameAllocator(), "last commit: unknown  {s}", .{item.full_ref});
            try draw.copyClippedTextAt(&content, 0, next_row, detail, app.palette.style(.muted));
        }
        next_row += 1;
    }

    const list_start = next_row;
    const rows = footer_row -| list_start;
    if (rows > 0) {
        if (picker.loading) {
            try draw.copyClippedTextAt(&content, 0, list_start, "Loading local and remote branches...", app.palette.style(.prompt));
        } else if (picker.failureText()) |message| {
            try draw.copyClippedTextAt(&content, 0, list_start, firstLine(message), app.palette.style(.danger));
        } else if (list == null) {
            try draw.copyClippedTextAt(&content, 0, list_start, "No branches", app.palette.style(.muted));
        } else if (list.?.branches.len == 0) {
            try draw.copyClippedTextAt(&content, 0, list_start, "No local or remote branches", app.palette.style(.muted));
        } else if (visible_count == 0) {
            const message = try std.fmt.allocPrint(content.frameAllocator(), "No branches match \"{s}\"", .{picker.query.slice()});
            try draw.copyClippedTextAt(&content, 0, list_start, message, app.palette.style(.muted));
        }
    }
    const selected = if (visible_count == 0) 0 else picker.filter.list.focusedIndex();
    const start = listWindowStart(selected, visible_count, rows);
    var row: u16 = 0;
    while (has_candidates and row < rows and start + row < visible_count) : (row += 1) {
        const visible_index = start + row;
        const source_index = picker.filter.sourceIndex(visible_index) orelse continue;
        if (source_index >= list.?.branches.len) continue;
        const item = list.?.branches[source_index];
        const focused = visible_index == selected;
        const style = if (focused) app.palette.boldStyle(.accent) else chasen.TextStyle{};
        const marker: []const u8 = if (focused) ">" else " ";
        try draw.copyClippedTextAt(&content, 0, list_start + row, marker, app.palette.style(.accent));

        const relative = commit_time.formatRelative(item.tip_committer_unix, picker.render_now_unix);
        const relative_width = content.displayWidth(relative.text());
        const time_field_width: u16 = @min(size.width, 14);
        const time_col = size.width - time_field_width;
        const rendered_relative_width = @min(relative_width, time_field_width);
        try draw.copyClippedTextAt(
            &content,
            time_col + time_field_width - rendered_relative_width,
            list_start + row,
            relative.text(),
            if (focused) app.palette.boldStyle(.accent) else app.palette.style(.muted),
        );

        const show_kind = size.width >= 84;
        const branch_col: u16 = if (show_kind) 11 else 2;
        if (show_kind) {
            const kind: []const u8 = if (item.kind == .local) "[local]" else "[remote]";
            try draw.copyClippedTextAt(&content, 2, list_start + row, kind, app.palette.style(.muted));
        }
        const branch_end = time_col -| 1;
        if (branch_end > branch_col) {
            var branch_surface = content.child(.{
                .col = branch_col,
                .row = list_start + row,
                .width = branch_end - branch_col,
                .height = 1,
            });
            try draw.copyClippedTextAt(&branch_surface, 0, 0, item.name, style);
        }
    }
    const footer = if (picker.input_mode == .query)
        "Type: filter  Up/Down: move  Tab: command  Esc: clear"
    else
        "/: filter  j/k: move  Enter: compare  Esc: close";
    try draw.copyClippedTextAt(&content, 0, footer_row, footer, app.palette.style(.accent));
}

const DiffPaneAdapter = struct {
    context: compare_navigation.View,
    palette: theme.Palette,

    fn interface(self: *DiffPaneAdapter) diff_surface.view.DiffPaneRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface, loaded: @import("../../../loaded_diff.zig").LoadedDiff) !void {
        const self: *DiffPaneAdapter = @ptrCast(@alignCast(ctx));
        var adapter = self.context.resolver();
        return diff_surface.view.viewDiffPane(
            surface,
            self.context.bodyView(&adapter),
            loaded,
            self.palette,
            null,
        );
    }
};

fn navigationView(app: Context) compare_navigation.View {
    return .{
        .page = app.page,
        .repo_root = app.repo_root,
        .repo_epoch = app.repo_epoch,
        .root_identity = app.root_identity,
        .layout = app.layout,
    };
}

fn branchPresentation(app: Context, allocator: std.mem.Allocator) !?diff_surface.view.SidebarBranchPresentation {
    if (app.page.basis_failure) |failure| {
        const message = try basisFailureText(allocator, failure);
        return .{ .text = if (app.page.hasAcceptedDisplay())
            try std.fmt.allocPrint(allocator, "stale  {s}", .{message})
        else
            message };
    }
    if (app.page.load_failure) |message| return .{ .text = if (app.page.hasAcceptedDisplay())
        try std.fmt.allocPrint(allocator, "stale  {s}", .{firstLine(message)})
    else
        firstLine(message) };
    const basis = app.page.basis orelse return .{ .text = "resolving compare base..." };
    const pending = switch (app.page.activation.state) {
        .active => |active| active.members.source == .pending,
        .inactive => false,
    };
    const same_endpoint = std.mem.eql(u8, basis.base.oid.slice(), basis.head_oid.slice());
    return .{
        .text = try std.fmt.allocPrint(allocator, "{s}...{s}  merge-base {s}  +{d}{s}{s}", .{
            basis.base.display_name,
            basis.head_display,
            basis.merge_base_oid.short(),
            basis.ahead_count,
            if (same_endpoint) "  base == head" else "",
            if (pending) "  loading" else "",
        }),
    };
}

fn viewInitialFailure(app: Context, surface: *chasen.Surface) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;
    const message = if (app.page.basis_failure) |failure|
        try basisFailureText(surface.frameAllocator(), failure)
    else
        firstLine(app.page.load_failure.?);
    const row = size.height / 2;
    try draw.copyClippedTextAt(surface, 1, row, message, app.palette.boldStyle(.danger));
    if (row + 2 < size.height) {
        try draw.copyClippedTextAt(surface, 1, row + 2, "Press m to choose a base or r to retry.", app.palette.style(.muted));
    }
}

fn basisFailureText(allocator: std.mem.Allocator, failure: compare_page.BasisFailureState) ![]const u8 {
    return switch (failure.kind) {
        .missing_base_ref => try std.fmt.allocPrint(allocator, "base {s} not found", .{failure.attempted.display_name}),
        .no_merge_base => try std.fmt.allocPrint(allocator, "no merge base with {s} (shallow clone may have insufficient history)", .{failure.attempted.display_name}),
        .head_unresolved => "HEAD could not be resolved",
    };
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

fn emptyStateMessage(
    allocator: std.mem.Allocator,
    base_display_name: []const u8,
    ahead_count: usize,
) !diff_surface.view.StateMessage {
    if (ahead_count == 0) return .{
        .title = try std.fmt.allocPrint(allocator, "Up to date with {s}", .{base_display_name}),
        .body = try std.fmt.allocPrint(allocator, "No commits are ahead of {s}.", .{base_display_name}),
        .hint = "Press m to choose another base or r to refresh.",
    };

    return .{
        .title = try std.fmt.allocPrint(allocator, "No file changes against {s}", .{base_display_name}),
        .body = if (ahead_count == 1)
            try std.fmt.allocPrint(allocator, "1 commit is ahead of {s}, but its net file diff is empty.", .{base_display_name})
        else
            try std.fmt.allocPrint(allocator, "{d} commits are ahead of {s}, but their net file diff is empty.", .{ ahead_count, base_display_name }),
        .hint = "Press m to choose another base or r to refresh.",
    };
}

fn listWindowStart(selected: usize, len: usize, rows: u16) usize {
    if (rows == 0 or len == 0) return 0;
    const visible: usize = @intCast(rows);
    if (len <= visible) return 0;
    return @min(selected -| (visible / 2), len - visible);
}

test "empty Compare state distinguishes zero ahead commits from an empty net file diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const message = try emptyStateMessage(arena.allocator(), "main", 0);
    try std.testing.expectEqualStrings("Up to date with main", message.title);
    try std.testing.expectEqualStrings("No commits are ahead of main.", message.body);
}

test "empty Compare state describes one ahead commit accurately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const message = try emptyStateMessage(arena.allocator(), "main", 1);
    try std.testing.expectEqualStrings("No file changes against main", message.title);
    try std.testing.expectEqualStrings("1 commit is ahead of main, but its net file diff is empty.", message.body);
}

test "empty Compare state describes multiple ahead commits accurately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const message = try emptyStateMessage(arena.allocator(), "origin/main", 3);
    try std.testing.expectEqualStrings("No file changes against origin/main", message.title);
    try std.testing.expectEqualStrings("3 commits are ahead of origin/main, but their net file diff is empty.", message.body);
}

fn pickerPageForViewTest(allocator: std.mem.Allocator) !compare_page.ComparePageState {
    var page_state: compare_page.ComparePageState = .{};
    errdefer page_state.deinit(allocator);
    const specs = [_]struct {
        full_ref: []const u8,
        name: []const u8,
        kind: @import("../../../git/refs.zig").BranchKind,
        timestamp: ?i64,
    }{
        .{
            .full_ref = "refs/heads/feature/very-long-ascii-branch-name-that-must-never-overlap-time",
            .name = "feature/very-long-ascii-branch-name-that-must-never-overlap-time",
            .kind = .local,
            .timestamp = 1_700_000_000,
        },
        .{
            .full_ref = "refs/remotes/origin/日本語のとても長いブランチ名",
            .name = "origin/日本語のとても長いブランチ名",
            .kind = .remote_tracking,
            .timestamp = 1_699_913_660,
        },
    };
    const branches = try allocator.alloc(@import("../../../git/refs.zig").BranchListItem, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (branches[0..initialized]) |item| {
            allocator.free(item.full_ref);
            allocator.free(item.name);
            allocator.free(item.oid);
        }
        allocator.free(branches);
    }
    for (specs, branches) |spec, *item| {
        const full_ref = try allocator.dupe(u8, spec.full_ref);
        errdefer allocator.free(full_ref);
        const name = try allocator.dupe(u8, spec.name);
        errdefer allocator.free(name);
        const oid = try allocator.dupe(u8, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
        item.* = .{
            .full_ref = full_ref,
            .name = name,
            .kind = spec.kind,
            .oid = oid,
            .tip_committer_unix = spec.timestamp,
        };
        initialized += 1;
    }
    page_state.base_picker.open = true;
    page_state.base_picker.accepted = .{ .branches = branches };
    const labels = [_][]const u8{ branches[0].full_ref, branches[1].full_ref };
    try page_state.base_picker.filter.apply(allocator, &labels, "");
    page_state.base_picker.render_now_unix = 1_700_000_060;
    return page_state;
}

fn pickerViewContext(page_state: *const compare_page.ComparePageState, width: u16, height: u16) Context {
    return .{
        .page = page_state,
        .palette = .default(),
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = width, .height = height },
    };
}

test "Compare base picker narrow and wide surfaces keep time independent from long branch names" {
    const allocator = std.testing.allocator;
    var page_state = try pickerPageForViewTest(allocator);
    defer page_state.deinit(allocator);

    inline for (.{ .{ @as(u16, 80), @as(u16, 12) }, .{ @as(u16, 120), @as(u16, 32) } }) |dimensions| {
        var surface: chasen.testing.TestSurface = undefined;
        try surface.init(dimensions[0], dimensions[1]);
        defer surface.deinit();
        try viewBasePicker(pickerViewContext(&page_state, dimensions[0], dimensions[1]), &surface.surface);
        const snapshot = try surface.snapshot(allocator);
        defer allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "1m ago") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "1d ago") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "1970") == null);
        if (dimensions[0] == 80) {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "[local]") == null);
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "[remote]") == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, snapshot, "[local]") != null);
        }
    }
}

test "Compare base picker compact surface preserves filter candidate and footer before helper rows" {
    const allocator = std.testing.allocator;
    var page_state = try pickerPageForViewTest(allocator);
    defer page_state.deinit(allocator);

    // A 7-row dialog has three content rows after border and padding.
    var surface: chasen.testing.TestSurface = undefined;
    try surface.init(80, 7);
    defer surface.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 7), &surface.surface);
    const snapshot = try surface.snapshot(allocator);
    defer allocator.free(snapshot);

    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "feature/very-long") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "1m ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Esc: close") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Current base:") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "last commit:") == null);
}

test "Compare base picker surface renders query no-match loading and failure terminals" {
    const allocator = std.testing.allocator;
    var page_state = try pickerPageForViewTest(allocator);
    defer page_state.deinit(allocator);
    page_state.base_picker.enterQuery();
    for ("missing") |byte| try page_state.base_picker.insertQuery(allocator, byte);

    var no_match: chasen.testing.TestSurface = undefined;
    try no_match.init(80, 12);
    defer no_match.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &no_match.surface);
    const no_match_snapshot = try no_match.snapshot(allocator);
    defer allocator.free(no_match_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, no_match_snapshot, "Filter: /missing") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_match_snapshot, "No branches match \"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_match_snapshot, "Esc: clear") != null);

    page_state.base_picker.close(allocator);
    page_state.base_picker.open = true;
    page_state.base_picker.loading = true;
    var loading: chasen.testing.TestSurface = undefined;
    try loading.init(80, 12);
    defer loading.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &loading.surface);
    const loading_snapshot = try loading.snapshot(allocator);
    defer allocator.free(loading_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Loading local and remote branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Esc: close") != null);

    page_state.base_picker.loading = false;
    page_state.base_picker.failure = .{ .static = "Compare base list failed" };
    var failure: chasen.testing.TestSurface = undefined;
    try failure.init(80, 12);
    defer failure.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &failure.surface);
    const failure_snapshot = try failure.snapshot(allocator);
    defer allocator.free(failure_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, failure_snapshot, "Compare base list failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_snapshot, "Esc: close") != null);

    page_state.base_picker.failure = null;
    page_state.base_picker.accepted = .{
        .branches = try allocator.alloc(@import("../../../git/refs.zig").BranchListItem, 0),
    };
    var empty: chasen.testing.TestSurface = undefined;
    try empty.init(80, 12);
    defer empty.deinit();
    try viewBasePicker(pickerViewContext(&page_state, 80, 12), &empty.surface);
    const empty_snapshot = try empty.snapshot(allocator);
    defer allocator.free(empty_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "No local or remote branches") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "Filter:") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty_snapshot, "Esc: close") != null);
}
