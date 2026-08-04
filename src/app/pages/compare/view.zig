//! Compare presentation built exclusively from shared diff-surface renderers.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const compare_page = @import("../compare.zig");
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
        .dialog_width = @min(surface.size().width, 76),
        .dialog_height = @min(surface.size().height, 20),
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

    const current = if (app.page.basis) |basis|
        try std.fmt.allocPrint(content.frameAllocator(), "Current base: {s}", .{basis.base.display_name})
    else
        "Current base: resolving default";
    try draw.copyClippedTextAt(&content, 0, 0, current, app.palette.style(.muted));

    if (picker.loading) {
        if (size.height > 2) try draw.copyClippedTextAt(&content, 0, 2, "Loading local and remote branches...", app.palette.style(.prompt));
        return;
    }
    if (picker.failure) |message| {
        if (size.height > 2) try draw.copyClippedTextAt(&content, 0, 2, firstLine(message), app.palette.style(.danger));
        return;
    }
    const list = picker.accepted orelse {
        if (size.height > 2) try draw.copyClippedTextAt(&content, 0, 2, "No branches", app.palette.style(.muted));
        return;
    };
    if (list.branches.len == 0) {
        if (size.height > 2) try draw.copyClippedTextAt(&content, 0, 2, "No local or remote branches", app.palette.style(.muted));
        return;
    }

    const list_start: u16 = 2;
    const rows: u16 = size.height -| 4;
    const selected = @min(picker.selected_index, list.branches.len - 1);
    const start = listWindowStart(selected, list.branches.len, rows);
    var row: u16 = 0;
    while (row < rows and start + row < list.branches.len) : (row += 1) {
        const index = start + row;
        const item = list.branches[index];
        const marker: []const u8 = if (index == selected) ">" else " ";
        const kind: []const u8 = if (item.kind == .local) "local " else "remote";
        const line = try std.fmt.allocPrint(content.frameAllocator(), "{s} [{s}] {s}", .{ marker, kind, item.name });
        try draw.copyClippedTextAt(
            &content,
            0,
            list_start + row,
            line,
            if (index == selected) app.palette.boldStyle(.accent) else chasen.TextStyle{},
        );
    }
    if (size.height > 0) {
        try draw.copyClippedTextAt(&content, 0, size.height - 1, "Enter: compare    Esc/q: cancel    j/k: move", app.palette.style(.accent));
    }
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
