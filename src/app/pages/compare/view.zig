//! Compare presentation over the shared committed-diff surface.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const keymap = @import("keymap");
const compare_page = @import("../compare.zig");
const committed_diff_navigation = @import("../committed_diff/navigation.zig");
const diff_surface = @import("../../diff_surface.zig");
const diff_render = @import("../../../diff/render.zig");
const loaded_diff = @import("../../../loaded_diff.zig");
const file_tree = @import("../../../file_tree.zig");
const page_header = @import("../../page_header.zig");
const root_capability = @import("../../../repo/root_capability.zig");
const commit_time = @import("../../branch_commit_time.zig");
const local_time = @import("../../../local_time.zig");

pub const Context = struct {
    page: *const compare_page.ComparePageState,
    palette: theme.Palette,
    repo_root: ?[]const u8,
    repo_epoch: u64,
    root_identity: ?root_capability.Identity,
    layout: diff_surface.Layout,
    keymap: keymap.Effective = .{},

    pub fn footer(self: Context) diff_surface.view.FooterView {
        const navigation = navigationView(self);
        var resolver = navigation.resolver();
        var result = diff_surface.view.footer(.{
            .surface = self.page.readSurface(self.layout),
            .auto_reload_enabled = false,
            .selection_action_visible = navigation.bodyView(&resolver).retainedSelectionActionAvailable(),
        });
        result.source_label = null;
        return result;
    }
};

pub fn pageHeaderPresentation(app: Context) ?page_header.Presentation {
    if (app.repo_root == null) return null;
    const pending = sourcePending(app.page);
    const failed = app.page.basis_failure != null or app.page.load_failure != null or sourceFailed(app.page);
    const identity = app.page.diff.accepted_repository_identity orelse return terminal(pending, failed);
    if (!identity.matches(app.repo_epoch, app.root_identity)) return terminal(pending, failed);
    if (!app.page.hasAcceptedDisplay()) return terminal(pending, failed);
    const basis = app.page.basis orelse return terminal(pending, failed);
    const target = app.page.base_target orelse return terminal(pending, failed);
    if (!std.mem.eql(u8, target.full_ref, basis.base.full_ref)) return terminal(pending, failed);
    return .{ .comparison = .{
        .base_display_name = basis.base.display_name,
        .head_display_name = basis.head_display,
        .freshness = if (pending) .refreshing else if (failed) .stale else .fresh,
    } };
}

pub fn pageHeaderLineStats(app: Context) ?file_tree.Stats {
    return diff_surface.view.pageHeaderLineStats(app.page.readSurface(app.layout));
}

pub fn view(app: Context, surface: *chasen.Surface) !void {
    if (!app.page.hasAcceptedDisplay() and (app.page.basis_failure != null or app.page.load_failure != null)) {
        return viewInitialFailure(app, surface);
    }
    const navigation = navigationView(app);
    var mode_key_buffer: [16]u8 = undefined;
    var filter_key_buffer: [16]u8 = undefined;
    var pane = DiffPaneAdapter{
        .context = navigation,
        .palette = app.palette,
        .mode_toggle_key = displayModeToggleKey(app, mode_key_buffer[0..]),
    };
    const empty_message: ?diff_surface.view.StateMessage = if (app.page.basis) |basis|
        try emptyStateMessage(surface.frameAllocator(), basis.base.display_name, basis.ahead_count)
    else
        null;
    try diff_surface.view.view(surface, .{
        .state = app.page.readSurface(app.layout),
        .palette = app.palette,
        .source_label = "branch comparison",
        .repo_root = app.repo_root,
        .file_filter_binding = app.keymap.display(.changed_file_filter, filter_key_buffer[0..]),
        .no_changes_actions = .{},
        .empty_message = empty_message,
        .diff_pane = pane.interface(),
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
    const footer_row = size.height - 1;
    var next_row: u16 = 0;
    const list = picker.accepted;
    const visible_count = picker.visibleCount();
    const has_candidates = list != null and list.?.branches.len > 0 and visible_count > 0;
    const show_detail = has_candidates and size.height >= 4;
    const show_current = size.height >= if (show_detail) @as(u16, 5) else @as(u16, 4);

    if (show_current) {
        const current = if (app.page.basis) |basis|
            try std.fmt.allocPrint(content.frameAllocator(), "Current base: {s}", .{basis.base.display_name})
        else
            "Current base: resolving default";
        try draw.copyClippedTextAt(&content, 0, next_row, current, app.palette.style(.muted));
        next_row += 1;
    }
    if (next_row < footer_row) {
        const prefix = if (picker.input_mode == .query) "Filter: /" else "Filter: ";
        try draw.copyClippedTextAt(&content, 0, next_row, prefix, app.palette.style(.prompt));
        const prefix_width = content.displayWidth(prefix);
        if (prefix_width < size.width) {
            var query_surface = content.child(.{ .col = prefix_width, .row = next_row, .width = size.width - prefix_width, .height = 1 });
            try draw.copyClippedTextAt(&query_surface, 0, 0, picker.query.slice(), chasen.TextStyle{});
        }
        if (picker.input_mode == .query and size.width > 0) {
            content.showCursor(@min(size.width - 1, prefix_width + content.displayWidth(picker.query.slice())), next_row);
        }
        next_row += 1;
    }
    if (show_detail and next_row < footer_row) {
        if (picker.selectedItem()) |item| {
            const exact = local_time.formatExact(item.tip_committer_unix);
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
        } else if (list == null or list.?.branches.len == 0) {
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
        try draw.copyClippedTextAt(&content, 0, list_start + row, if (focused) ">" else " ", app.palette.style(.accent));
        const relative = commit_time.formatRelative(item.tip_committer_unix, picker.render_now_unix);
        const time_field_width: u16 = @min(size.width, 14);
        const time_col = size.width - time_field_width;
        const relative_width = @min(content.displayWidth(relative.text()), time_field_width);
        try draw.copyClippedTextAt(&content, time_col + time_field_width - relative_width, list_start + row, relative.text(), if (focused) app.palette.boldStyle(.accent) else app.palette.style(.muted));
        const branch_col: u16 = if (size.width >= 84) 11 else 2;
        if (size.width >= 84) {
            try draw.copyClippedTextAt(&content, 2, list_start + row, if (item.kind == .local) "[local]" else "[remote]", app.palette.style(.muted));
        }
        const branch_end = time_col -| 1;
        if (branch_end > branch_col) {
            var branch_surface = content.child(.{ .col = branch_col, .row = list_start + row, .width = branch_end - branch_col, .height = 1 });
            try draw.copyClippedTextAt(&branch_surface, 0, 0, item.name, style);
        }
    }
    const footer = if (picker.input_mode == .query)
        "Type: filter  Up/Down: move  Tab: command  Esc: clear"
    else
        "/: filter  j/k: move  Enter: compare  Esc: close";
    try draw.copyClippedTextAt(&content, 0, footer_row, footer, app.palette.style(.accent));
}

fn navigationView(app: Context) committed_diff_navigation.View {
    var key_buffer: [16]u8 = undefined;
    return .{
        .diff = &app.page.diff,
        .activation = &app.page.activation,
        .status = &app.page.status,
        .current_target = app.page.currentTarget(),
        .repo_root = app.repo_root,
        .repo_epoch = app.repo_epoch,
        .root_identity = app.root_identity,
        .source = compare_page.selection_source,
        .layout = app.layout,
        .mode_toggle_hint_width = diff_render.modeToggleHintWidth(displayModeToggleKey(app, key_buffer[0..])),
        .live_drag_deferred_source = app.page.deferred_load_apply != null,
    };
}

fn displayModeToggleKey(app: Context, buffer: []u8) ?[]const u8 {
    if (app.page.diff.search.mode or app.page.diff.file_search.mode or app.page.base_picker.open) return null;
    return app.keymap.display(.toggle_display_mode, buffer);
}

const DiffPaneAdapter = struct {
    context: committed_diff_navigation.View,
    palette: theme.Palette,
    mode_toggle_key: ?[]const u8,

    fn interface(self: *DiffPaneAdapter) diff_surface.view.DiffPaneRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
        const self: *DiffPaneAdapter = @ptrCast(@alignCast(ctx));
        var resolver = self.context.resolver();
        return diff_surface.view.viewDiffPane(
            surface,
            self.context.bodyView(&resolver),
            loaded,
            self.palette,
            null,
            self.mode_toggle_key,
            .{},
        );
    }
};

fn sourcePending(page: *const compare_page.ComparePageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .pending,
        .inactive => false,
    };
}

fn sourceFailed(page: *const compare_page.ComparePageState) bool {
    return switch (page.activation.state) {
        .active => |active| active.members.source == .failed,
        .inactive => false,
    };
}

fn terminal(pending: bool, failed: bool) ?page_header.Presentation {
    if (pending) return .{ .terminal = .{ .kind = .comparison, .state = .loading } };
    if (failed) return .{ .terminal = .{ .kind = .comparison, .state = .unavailable } };
    return null;
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
    if (row + 2 < size.height) try draw.copyClippedTextAt(surface, 1, row + 2, "Press m to choose a base or r to retry.", app.palette.style(.muted));
}

fn basisFailureText(allocator: std.mem.Allocator, failure: compare_page.BasisFailureState) ![]const u8 {
    return switch (failure.kind) {
        .missing_base_ref => try std.fmt.allocPrint(allocator, "base {s} not found", .{failure.attempted.display_name}),
        .no_merge_base => try std.fmt.allocPrint(allocator, "no merge base with {s} (shallow clone may have insufficient history)", .{failure.attempted.display_name}),
        .head_unresolved => "HEAD could not be resolved",
    };
}

fn emptyStateMessage(allocator: std.mem.Allocator, base: []const u8, ahead: usize) !diff_surface.view.StateMessage {
    if (ahead == 0) return .{
        .title = try std.fmt.allocPrint(allocator, "Up to date with {s}", .{base}),
        .body = try std.fmt.allocPrint(allocator, "No commits are ahead of {s}.", .{base}),
        .hint = "Press m to choose another base or r to refresh.",
    };
    return .{
        .title = try std.fmt.allocPrint(allocator, "No file changes against {s}", .{base}),
        .body = if (ahead == 1)
            try std.fmt.allocPrint(allocator, "1 commit is ahead of {s}, but its net file diff is empty.", .{base})
        else
            try std.fmt.allocPrint(allocator, "{d} commits are ahead of {s}, but their net file diff is empty.", .{ ahead, base }),
        .hint = "Press m to choose another base or r to refresh.",
    };
}

fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

fn listWindowStart(selected: usize, len: usize, rows: u16) usize {
    if (rows == 0 or len == 0) return 0;
    const visible: usize = @intCast(rows);
    if (len <= visible) return 0;
    return @min(selected -| (visible / 2), len - visible);
}

test "Compare empty state distinguishes commits from net file diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try emptyStateMessage(arena.allocator(), "main", 1);
    try std.testing.expectEqualStrings("No file changes against main", message.title);
}
