//! Compare presentation over the shared committed-diff surface.

const std = @import("std");
const chasen = @import("chasen");
const branch_picker = @import("../../branch_picker.zig");
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
const git_refs = @import("../../../git/refs.zig");
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
    const frame = branch_picker.viewFrame(surface, app.palette, "Change comparison Base") orelse return;
    var content = frame.contentSurface();
    const size = content.size();
    if (size.height == 0) return;
    const footer_row = size.height - 1;
    const body_end = size.height -| branch_picker.footer_rows;
    var next_row: u16 = 0;
    const list = picker.accepted;
    const visible_count = picker.visibleCount();
    const has_candidates = list != null and list.?.branches.len > 0 and visible_count > 0;

    if (app.page.basis) |basis| {
        if (next_row < body_end) {
            const base = try std.fmt.allocPrint(content.frameAllocator(), "Current Base: {s}  merge destination", .{basis.base.display_name});
            try draw.copyClippedTextAt(&content, 0, next_row, base, app.palette.style(.muted));
            next_row += 1;
        }
        if (next_row < body_end) {
            const head = try std.fmt.allocPrint(content.frameAllocator(), "Compare: {s}  current HEAD", .{basis.head_display});
            try draw.copyClippedTextAt(&content, 0, next_row, head, app.palette.style(.muted));
            next_row += 1;
        }
    } else if (next_row < body_end) {
        try draw.copyClippedTextAt(&content, 0, next_row, "Current comparison unavailable", app.palette.style(.muted));
        next_row += 1;
    }
    if (next_row +| 1 < body_end) next_row += 1;
    if (next_row < body_end) {
        try branch_picker.viewFilter(&content, next_row, app.palette, .{
            .query = picker.query.slice(),
            .query_mode = picker.input_mode == .query,
        });
        next_row += 1;
    }
    if (picker.selectedItem()) |item| {
        if (next_row < body_end) {
            const full_ref = try std.fmt.allocPrint(content.frameAllocator(), "Full ref  {s}", .{item.full_ref});
            try draw.copyClippedTextAt(&content, 0, next_row, full_ref, app.palette.style(.muted));
            next_row += 1;
        }
        if (next_row < body_end) {
            const last_commit = if (local_time.formatExact(item.tip_committer_unix)) |timestamp|
                try std.fmt.allocPrint(content.frameAllocator(), "last commit: {s}", .{timestamp.text()})
            else
                "last commit: unknown";
            try draw.copyClippedTextAt(&content, 0, next_row, last_commit, app.palette.style(.muted));
            next_row += 1;
        }
        if (next_row +| 1 < body_end) next_row += 1;
    }

    const list_start = next_row;
    const rows = body_end -| list_start;
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
    const start = branch_picker.listWindowStart(selected, visible_count, rows);
    var row: u16 = 0;
    while (has_candidates and row < rows and start + row < visible_count) : (row += 1) {
        const visible_index = start + row;
        const source_index = picker.filter.sourceIndex(visible_index) orelse continue;
        if (source_index >= list.?.branches.len) continue;
        const item = list.?.branches[source_index];
        const focused = visible_index == selected;
        const applied = if (app.page.basis) |basis| std.mem.eql(u8, item.full_ref, basis.base.full_ref) else false;
        const style = if (focused) app.palette.boldStyle(.accent) else chasen.TextStyle{};
        try draw.copyClippedTextAt(&content, 0, list_start + row, if (focused) ">" else " ", app.palette.style(.accent));
        try draw.copyClippedTextAt(&content, 2, list_start + row, if (applied) "*" else " ", app.palette.boldStyle(.prompt));
        const relative = commit_time.formatRelative(item.tip_committer_unix, picker.render_now_unix);
        const time_field_width: u16 = @min(size.width, 14);
        const time_col = size.width - time_field_width;
        const relative_width = @min(content.displayWidth(relative.text()), time_field_width);
        try draw.copyClippedTextAt(&content, time_col + time_field_width - relative_width, list_start + row, relative.text(), if (focused) app.palette.boldStyle(.accent) else app.palette.style(.muted));
        const branch_col: u16 = if (size.width >= 84) 13 else 4;
        if (size.width >= 84) {
            try draw.copyClippedTextAt(&content, 4, list_start + row, if (item.kind == .local) "[local]" else "[remote]", app.palette.style(.muted));
        }
        const branch_end = time_col -| 1;
        if (branch_end > branch_col) {
            var branch_surface = content.child(.{ .col = branch_col, .row = list_start + row, .width = branch_end - branch_col, .height = 1 });
            try draw.copyClippedTextAt(&branch_surface, 0, 0, item.name, style);
        }
    }
    const footer = if (picker.input_mode == .query)
        "Type: filter  Up/Down: move  Enter: use as Base  Tab: command  Esc: clear"
    else
        "/: filter  j/k: move  Enter: use as Base  Esc: cancel";
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

test "Compare empty state distinguishes commits from net file diff" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const message = try emptyStateMessage(arena.allocator(), "main", 1);
    try std.testing.expectEqualStrings("No file changes against main", message.title);
}

test "Compare Base picker identifies accepted Base independently from candidate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var page: compare_page.ComparePageState = .{};
    page.base_picker.open = true;
    const branches = try allocator.alloc(git_refs.BranchListItem, 2);
    branches[0] = .{
        .full_ref = try allocator.dupe(u8, "refs/remotes/origin/main"),
        .name = try allocator.dupe(u8, "origin/main"),
        .kind = .remote_tracking,
        .oid = try allocator.dupe(u8, "1111111111111111111111111111111111111111"),
        .tip_committer_unix = 1_700_000_000,
    };
    branches[1] = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/main"),
        .name = try allocator.dupe(u8, "main"),
        .kind = .local,
        .oid = try allocator.dupe(u8, "2222222222222222222222222222222222222222"),
        .tip_committer_unix = 1_699_000_000,
    };
    page.base_picker.accepted = .{ .branches = branches };
    const labels = try allocator.alloc([]const u8, branches.len);
    for (branches, 0..) |branch, index| labels[index] = branch.full_ref;
    try page.base_picker.filter.apply(allocator, labels, "");
    page.base_picker.render_now_unix = 1_700_000_100;
    page.basis = .{
        .base = .{
            .full_ref = try allocator.dupe(u8, "refs/remotes/origin/main"),
            .display_name = try allocator.dupe(u8, "origin/main"),
            .kind = .remote_tracking,
        },
        .head_display = try allocator.dupe(u8, "feature/context"),
        .target = .{ .object_format = .sha1, .base_oid = .{}, .head_oid = .{}, .diff_base_oid = .{} },
        .ahead_count = 2,
    };
    page.base_target = .{
        .full_ref = try allocator.dupe(u8, "refs/heads/main"),
        .display_name = try allocator.dupe(u8, "main"),
        .kind = .local,
    };
    const context: Context = .{
        .page = &page,
        .palette = .default(),
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = 120, .height = 32 },
    };
    var applied: chasen.testing.TestSurface = undefined;
    try applied.init(120, 32);
    defer applied.deinit();
    try viewBasePicker(context, &applied.surface);
    const applied_snapshot = try applied.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(applied_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "Change comparison Base") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "Current Base: origin/main  merge destination") != null);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "Base      origin/main  merge destination") == null);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "Compare: feature/context  current HEAD") != null);
    const applied_filter_offset = std.mem.indexOf(u8, applied_snapshot, "Filter branches: ").?;
    const applied_filter_row = std.mem.count(u8, applied_snapshot[0..applied_filter_offset], "\n");
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "Candidate") == null);
    const applied_ref_offset = std.mem.indexOf(u8, applied_snapshot, "Full ref  refs/remotes/origin/main").?;
    const applied_ref_row = std.mem.count(u8, applied_snapshot[0..applied_ref_offset], "\n");
    try std.testing.expectEqual(applied_filter_row + 1, applied_ref_row);
    const applied_time = local_time.formatExact(branches[0].tip_committer_unix).?;
    const applied_last_commit = try std.fmt.allocPrint(allocator, "last commit: {s}", .{applied_time.text()});
    const applied_last_commit_offset = std.mem.indexOf(u8, applied_snapshot, applied_last_commit).?;
    const applied_last_commit_row = std.mem.count(u8, applied_snapshot[0..applied_last_commit_offset], "\n");
    const applied_relative = commit_time.formatRelative(branches[0].tip_committer_unix, page.base_picker.render_now_unix);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, applied_relative.text()) != null);
    const applied_branch_offset = std.mem.indexOf(u8, applied_snapshot, "> * [remote] origin/main").?;
    const applied_branch_row = std.mem.count(u8, applied_snapshot[0..applied_branch_offset], "\n");
    try std.testing.expectEqual(applied_last_commit_row + 2, applied_branch_row);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "* current Base   > candidate") == null);
    try std.testing.expect(std.mem.indexOf(u8, applied_snapshot, "/: filter  j/k: move  Enter: use as Base  Esc: cancel") != null);

    page.base_picker.filter.list.focus.index = 1;
    var candidate: chasen.testing.TestSurface = undefined;
    try candidate.init(120, 32);
    defer candidate.deinit();
    try viewBasePicker(context, &candidate.surface);
    const candidate_snapshot = try candidate.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(candidate_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, candidate_snapshot, "Candidate") == null);
    try std.testing.expect(std.mem.indexOf(u8, candidate_snapshot, "Full ref  refs/heads/main") != null);
    const candidate_time = local_time.formatExact(branches[1].tip_committer_unix).?;
    const candidate_last_commit = try std.fmt.allocPrint(allocator, "last commit: {s}", .{candidate_time.text()});
    try std.testing.expect(std.mem.indexOf(u8, candidate_snapshot, candidate_last_commit) != null);
    const candidate_relative = commit_time.formatRelative(branches[1].tip_committer_unix, page.base_picker.render_now_unix);
    try std.testing.expect(std.mem.indexOf(u8, candidate_snapshot, candidate_relative.text()) != null);
    try std.testing.expect(std.mem.indexOf(u8, candidate_snapshot, "  * [remote] origin/main") != null);
    try std.testing.expect(std.mem.indexOf(u8, candidate_snapshot, ">   [local]  main") != null);

    branches[1].tip_committer_unix = null;
    var unknown: chasen.testing.TestSurface = undefined;
    try unknown.init(120, 32);
    defer unknown.deinit();
    try viewBasePicker(context, &unknown.surface);
    const unknown_snapshot = try unknown.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(unknown_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, unknown_snapshot, "last commit: unknown") != null);

    page.base_picker.input_mode = .query;
    var query: chasen.testing.TestSurface = undefined;
    try query.init(120, 32);
    defer query.deinit();
    try viewBasePicker(context, &query.surface);
    const query_snapshot = try query.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(query_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, query_snapshot, "Filter branches: /") != null);
    try std.testing.expect(std.mem.indexOf(u8, query_snapshot, "Type: filter  Up/Down: move  Enter: use as Base  Tab: command  Esc: clear") != null);
}

test "Compare Base picker reports unavailable, loading, failure, and narrow states" {
    var page: compare_page.ComparePageState = .{};
    page.base_picker.open = true;
    page.base_picker.loading = true;
    const context: Context = .{
        .page = &page,
        .palette = .default(),
        .repo_root = null,
        .repo_epoch = 0,
        .root_identity = null,
        .layout = .{ .width = 120, .height = 32 },
    };
    var loading: chasen.testing.TestSurface = undefined;
    try loading.init(120, 32);
    defer loading.deinit();
    try viewBasePicker(context, &loading.surface);
    const loading_snapshot = try loading.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(loading_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Current comparison unavailable") != null);
    const loading_filter_offset = std.mem.indexOf(u8, loading_snapshot, "Filter branches: ").?;
    const loading_filter_row = std.mem.count(u8, loading_snapshot[0..loading_filter_offset], "\n");
    const loading_status_offset = std.mem.indexOf(u8, loading_snapshot, "Loading local and remote branches...").?;
    const loading_status_row = std.mem.count(u8, loading_snapshot[0..loading_status_offset], "\n");
    try std.testing.expectEqual(loading_filter_row + 1, loading_status_row);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Candidate") == null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "Full ref") == null);
    try std.testing.expect(std.mem.indexOf(u8, loading_snapshot, "last commit:") == null);

    page.base_picker.loading = false;
    page.base_picker.failure = .{ .static = "Could not load branches" };
    var failed: chasen.testing.TestSurface = undefined;
    try failed.init(120, 32);
    defer failed.deinit();
    try viewBasePicker(context, &failed.surface);
    const failed_snapshot = try failed.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(failed_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, failed_snapshot, "Could not load branches") != null);

    page.base_picker.failure = null;
    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(12, 5);
    defer narrow.deinit();
    try viewBasePicker(context, &narrow.surface);
    const narrow_snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(narrow_snapshot);
    try std.testing.expect(narrow_snapshot.len > 0);
}
