const std = @import("std");
const builtin = @import("builtin");
const chasen = @import("chasen");
const draw = @import("draw");
const app_page = @import("../../page.zig");
const page_header = @import("../../page_header.zig");
const changes_projection = @import("../../changes_projection.zig");
const diff_surface_view = @import("../../diff_surface/view.zig");
const changes_page = @import("../changes.zig");
const changes_file_search = @import("../../diff_surface/file_search.zig");
const changes_body_render = @import("body_render.zig");
const changes_layout = @import("layout.zig");
const changes_navigation = @import("navigation.zig");
const diff_render = @import("../../../diff/render.zig");
const diff_source = @import("../../../diff/source.zig");
const git_branch_status = @import("../../../git/branch_status.zig");
const git_status = @import("../../../git/status.zig");
const keymap = @import("keymap");
const loaded_diff = @import("../../../loaded_diff.zig");
const file_tree = @import("../../../file_tree.zig");
const sidebar_view_model = @import("../../../sidebar/view_model.zig");
const theme = @import("theme");
const test_support = if (builtin.is_test) @import("../../test_support.zig") else struct {};

pub const EmptyRemoteActionHints = struct {
    show_repo_picker: bool = false,
    show_pull: bool = false,
    show_fetch: bool = false,
};
pub const FooterView = diff_surface_view.FooterView;
pub const ActivationPresentation = diff_surface_view.ActivationPresentation;

pub const Context = struct {
    page: *const changes_page.ChangesPageState,
    navigation: changes_navigation.View,
    theme: theme.Palette,
    keymap: keymap.Effective,
    source_label: []const u8,
    source: diff_source.SourceMode,
    repo_root: ?[]const u8,
    empty_remote_hints: EmptyRemoteActionHints,

    pub fn init(
        changes: *const changes_page.ChangesPageState,
        navigation: changes_navigation.View,
        palette: theme.Palette,
        effective_keymap: keymap.Effective,
        source_label: []const u8,
        source: diff_source.SourceMode,
        repo_root: ?[]const u8,
        empty_remote_hints: EmptyRemoteActionHints,
    ) Context {
        return .{
            .page = changes,
            .navigation = navigation,
            .theme = palette,
            .keymap = effective_keymap,
            .source_label = source_label,
            .source = source,
            .repo_root = repo_root,
            .empty_remote_hints = empty_remote_hints,
        };
    }

    pub fn footer(self: Context) FooterView {
        return diff_surface_view.footer(.{
            .surface = self.page.readSurface(self.source, self.navigation.layout),
            .auto_reload_enabled = self.page.auto_reload.enabled(),
            .selection_action_visible = self.navigation.retainedSelectionActionAvailable(),
        });
    }

    pub fn selectedStatusEntry(self: Context) ?git_status.StatusEntry {
        return self.navigation.selectedStatusEntry();
    }

    pub fn selectedStatusLineStats(self: Context) ?file_tree.Stats {
        return self.navigation.selectedStatusLineStats();
    }

    pub fn displayedChangesBody(self: Context) changes_navigation.DisplayedChangesBody {
        return self.navigation.displayedChangesBody();
    }

    pub fn selectedHunkIndex(self: Context) ?usize {
        return self.navigation.selectedHunkIndex();
    }

    pub fn visibleDiffCursorOffset(self: Context) ?usize {
        return self.navigation.visibleDiffCursorOffset();
    }

    pub fn diffSelectionView(self: Context) ?@import("../../../diff/selection.zig").View {
        return self.navigation.diffSelectionView();
    }

    pub fn diffHeaderSelectionActive(self: Context) bool {
        return self.navigation.diffHeaderSelectionActive();
    }
};

/// Project Changes's exact current-root branch snapshot into display-only page
/// chrome. Foreground replacement never reuses the retained label; only an
/// exact same-root background refresh may expose refreshing/stale state.
pub fn pageHeaderPresentation(app: Context) ?page_header.Presentation {
    const root = app.repo_root orelse return null;
    const matching_snapshot = if (app.page.branch_status.repo_root) |snapshot_root|
        std.mem.eql(u8, root, snapshot_root)
    else
        false;

    if (app.page.branch_status_load.pending) |pending| if (pending.publication_allowed) {
        if (pending.origin == .foreground or !matching_snapshot) return .{
            .terminal = .{ .kind = .head, .state = .loading },
        };
        return headPresentation(app.page.branch_status.status, .refreshing);
    };

    if (!matching_snapshot) return switch (app.page.branch_status_load.freshness) {
        .missing => .{ .terminal = .{ .kind = .head, .state = .unavailable } },
        .fresh, .stale_refresh => null,
    };
    return switch (app.page.branch_status_load.freshness) {
        .fresh => headPresentation(app.page.branch_status.status, .fresh),
        .stale_refresh => headPresentation(app.page.branch_status.status, .stale),
        .missing => .{ .terminal = .{ .kind = .head, .state = .unavailable } },
    };
}

pub fn pageHeaderLineStats(app: Context) ?file_tree.Stats {
    return diff_surface_view.pageHeaderLineStats(
        app.page.readSurface(app.source, app.navigation.layout),
    );
}

fn headPresentation(
    status: git_branch_status.BranchStatus,
    freshness: page_header.Freshness,
) page_header.Presentation {
    return .{ .head = switch (status.head) {
        .branch => |name| .{ .branch = .{
            .display_name = name,
            .upstream = if (status.upstream == null)
                .no_upstream
            else
                .{ .ahead = if (status.ahead_behind) |counts| counts.ahead else 0 },
            .freshness = freshness,
        } },
        .detached => .{ .detached = freshness },
        .unknown => .{ .unknown = freshness },
    } };
}

fn activationPresentation(changes: *const changes_page.ChangesPageState, source: diff_source.SourceMode) ?ActivationPresentation {
    return diff_surface_view.activationPresentation(&changes.activation, source);
}

test "reloadable activation reports validating and stale while one-shot input stays immutable" {
    var changes: changes_page.ChangesPageState = .{};
    _ = changes.activation.activate(1, .pending, .pending, .pending);
    try std.testing.expectEqual(ActivationPresentation.validating, activationPresentation(&changes, .unstaged).?);

    changes.activation.state.active.members = .{ .source = .fresh, .status = .failed, .branch = .fresh };
    try std.testing.expectEqual(ActivationPresentation.stale, activationPresentation(&changes, .unstaged).?);

    try std.testing.expect(activationPresentation(&changes, .stdin) == null);
    try std.testing.expect(activationPresentation(&changes, .{ .pager = "" }) == null);
}

pub fn view(app: Context, surface: *chasen.Surface) !void {
    var diff_pane_adapter: ChangesDiffPaneRenderer = .{ .app = app };
    var fetch_key_buffer: [16]u8 = undefined;
    var filter_key_buffer: [16]u8 = undefined;
    return diff_surface_view.view(surface, .{
        .state = app.page.readSurface(app.source, app.navigation.layout),
        .palette = app.theme,
        .source_label = app.source_label,
        .repo_root = app.repo_root,
        .file_filter_binding = app.keymap.display(.changed_file_filter, filter_key_buffer[0..]),
        .no_changes_actions = viewNoChangesActionPresentation(app, fetch_key_buffer[0..]),
        .empty_message = null,
        .diff_pane = diff_pane_adapter.interface(),
    });
}

const ChangesDiffPaneRenderer = struct {
    app: Context,

    fn interface(self: *ChangesDiffPaneRenderer) diff_surface_view.DiffPaneRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
        const self: *ChangesDiffPaneRenderer = @ptrCast(@alignCast(ctx));
        return viewDiffPane(self.app, surface, loaded);
    }
};

fn viewNoChangesActionPresentation(app: Context, fetch_key_buffer: []u8) diff_surface_view.NoChangesActionPresentation {
    if (app.page.file_search.mode) return .{};
    switch (app.page.load.state) {
        .empty => |reason| if (reason != .no_changes) return .{},
        else => return .{},
    }
    const fetch_key = app.keymap.display(.fetch, fetch_key_buffer);
    return noChangesActionPresentation(app.empty_remote_hints, fetch_key);
}

/// Draw the file tree side pane from the materialized sidebar view-model.
pub fn viewSidebar(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    var filter_key_buffer: [16]u8 = undefined;
    return diff_surface_view.viewSidebar(
        surface,
        app.page.readSurface(app.source, app.navigation.layout),
        loaded,
        app.repo_root,
        app.keymap.display(.changed_file_filter, filter_key_buffer[0..]),
        app.theme,
    );
}

const drawSidebarRow = diff_surface_view.drawSidebarRow;
const sidebarRowStyle = diff_surface_view.sidebarRowStyle;

/// Draw the selected file's diff pane.
///
/// Diff rows are already backed by rendered-line indexes in LoadedDiff; this
/// layer only chooses the visible file, mode, and current scroll offset.
pub fn viewDiffPane(app: Context, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    var mode_key_buffer: [16]u8 = undefined;
    const mode_toggle_key = displayModeToggleKey(app, mode_key_buffer[0..]);
    var resolver_adapter = app.navigation.contentResolverAdapter();
    var status_adapter: ChangesStatusOnlyRenderer = undefined;
    const status_renderer: ?diff_surface_view.StatusOnlyRenderer = if (app.selectedStatusEntry()) |entry| blk: {
        status_adapter = .{ .app = app, .entry = entry };
        break :blk status_adapter.interface();
    } else null;
    return diff_surface_view.viewDiffPane(
        surface,
        app.navigation.diffSurfaceBodyView(&resolver_adapter),
        loaded,
        app.theme,
        status_renderer,
        mode_toggle_key,
        .{},
    );
}

const ChangesStatusOnlyRenderer = struct {
    app: Context,
    entry: git_status.StatusEntry,

    fn interface(self: *ChangesStatusOnlyRenderer) diff_surface_view.StatusOnlyRenderer {
        return .{ .ctx = self, .render_fn = render };
    }

    fn render(ctx: *anyopaque, surface: *chasen.Surface) !void {
        const self: *ChangesStatusOnlyRenderer = @ptrCast(@alignCast(ctx));
        return viewStatusOnlyPane(self.app, surface, self.entry);
    }
};

fn viewStatusOnlyPane(app: Context, surface: *chasen.Surface, entry: git_status.StatusEntry) !void {
    const active = app.page.viewer.sidebar_hidden or app.page.viewer.focus == .diff;

    var mode_key_buffer: [16]u8 = undefined;
    const mode_toggle_key = displayModeToggleKey(app, mode_key_buffer[0..]);
    var content = diffContentSurface(surface);
    const path = entry.canonicalPathKey() orelse entry.path;

    switch (app.displayedChangesBody()) {
        .cached => |bundle| {
            try changes_body_render.renderParsed(.{
                .file = bundle.loaded.document.files[0],
                .line_index = bundle.loaded.cachedRenderedLineIndex(0, diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .folded_hunks = &.{},
                .hunk_stages = .all_staged,
                .syntax = .initDirect(&bundle.loaded.syntax_spans, 0),
            }, projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            try finishProjectedBody(app, surface, &content, active);
            return;
        },
        .combined => |bundle| {
            try changes_body_render.renderParsed(.{
                .file = bundle.displayFile(),
                .line_index = bundle.displayLineIndex(diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .folded_hunks = &.{},
                .hunk_stages = try changes_navigation.projectedHunkStagePresentation(surface.frameAllocator(), bundle.hunkStageStates()),
                .syntax = bundle.syntaxView(),
            }, projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            try finishProjectedBody(app, surface, &content, active);
            return;
        },
        .retained_staged_only => |bundle| {
            try changes_body_render.renderParsed(.{
                .file = bundle.displayFile(),
                .line_index = bundle.displayLineIndex(diff_render.effectiveMode(diff_render.bodyWidth(content.size().width), app.page.viewer.display_mode)),
                .folded_hunks = &.{},
                .hunk_stages = .all_staged,
                .syntax = bundle.syntaxView(),
            }, projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            try finishProjectedBody(app, surface, &content, active);
            return;
        },
        .generated => |bundle| {
            try changes_body_render.renderGenerated(bundle, projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            try finishProjectedBody(app, surface, &content, active);
            return;
        },
        .inert_invalid_utf8 => |inert| {
            try changes_body_render.renderStatus(inert.display_path, changes_navigation.invalid_utf8_body_message, app.selectedStatusLineStats(), projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            drawProjectedHeaderDetail(app, surface, active);
            return;
        },
        .status => |status| {
            try changes_body_render.renderStatus(status.path, status.message, app.selectedStatusLineStats(), projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            drawProjectedHeaderDetail(app, surface, active);
            return;
        },
        .pending => {
            try changes_body_render.renderStatus(path, "Loading changes projection...", app.selectedStatusLineStats(), projectedBodyRenderArgs(app, &content, active, mode_toggle_key));
            drawProjectedHeaderDetail(app, surface, active);
            return;
        },
        .none, .primary => {},
    }

    try changes_body_render.renderStatusOnlyFallback(&content, entry, app.selectedStatusLineStats(), active, app.theme);
}

fn projectedBodyRenderArgs(
    app: Context,
    surface: *chasen.Surface,
    active: bool,
    display_mode_toggle_key: ?[]const u8,
) @import("../../diff_surface.zig").RenderProjectedBodyArgs {
    return .{
        .surface = surface,
        .requested_mode = app.page.viewer.display_mode,
        .display_mode_toggle_key = display_mode_toggle_key,
        .scroll = app.navigation.renderDiffScroll(),
        .horizontal_scroll = app.page.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .line_numbers = app.page.viewer.view_options.line_numbers,
        .highlighted_hunk = app.selectedHunkIndex(),
        .cursor_offset = app.navigation.renderDiffCursorOffset(),
        .palette = app.theme,
        .selection = app.diffSelectionView(),
        .header_selection = app.diffHeaderSelectionActive(),
    };
}

fn displayModeToggleKey(app: Context, buffer: []u8) ?[]const u8 {
    if (app.page.search.mode or app.page.file_search.mode) return null;
    return app.keymap.display(.toggle_display_mode, buffer);
}

fn finishProjectedBody(app: Context, pane: *chasen.Surface, content: *chasen.Surface, active: bool) !void {
    _ = content;
    drawProjectedHeaderDetail(app, pane, active);
}

fn drawProjectedHeaderDetail(app: Context, pane: *chasen.Surface, active: bool) void {
    diff_surface_view.drawDiffHeaderDetailRow(
        pane,
        app.page.readSurface(app.source, app.navigation.layout),
        app.navigation.keyboardSideChoiceActive(),
        app.navigation.selectionStatusPresentation(),
        active,
        app.theme,
    );
}

fn drawStatusBody(surface: *chasen.Surface, path: []const u8, message: []const u8, stats: ?file_tree.Stats, active: bool, palette: theme.Palette) !void {
    try changes_body_render.renderStatus(path, message, stats, .{
        .surface = surface,
        .requested_mode = .unified,
        .scroll = 0,
        .horizontal_scroll = 0,
        .pane_active = active,
        .line_numbers = true,
        .highlighted_hunk = null,
        .cursor_offset = null,
        .palette = palette,
        .selection = null,
        .header_selection = false,
    });
}

fn noChangesActionPresentation(hints: EmptyRemoteActionHints, fetch_key: ?[]const u8) diff_surface_view.NoChangesActionPresentation {
    return .{
        .show_repo_picker = hints.show_repo_picker,
        .show_pull = hints.show_pull,
        .fetch_key = if (hints.show_fetch) fetch_key else null,
    };
}

const drawFileSearch = diff_surface_view.drawFileSearch;

test "changes no-changes adapter normalizes fetch capability and key" {
    const denied = noChangesActionPresentation(.{ .show_fetch = false }, "Ctrl+f");
    try std.testing.expect(denied.fetch_key == null);

    const allowed = noChangesActionPresentation(.{ .show_fetch = true }, "Ctrl+f");
    try std.testing.expectEqualStrings("Ctrl+f", allowed.fetch_key.?);
}

test "Changes page header admits only exact-root branch snapshots" {
    var builder = git_branch_status.Builder.init(std.testing.allocator);
    errdefer builder.deinit();
    try builder.setBranchHead("feature/header");
    try builder.setUpstream("origin/main");
    builder.setAheadBehind(2, 0);
    var bundle = builder.finish();
    var branch_status: git_branch_status.State = .{};
    try branch_status.replace("/repo", &bundle);

    var page_state: changes_page.ChangesPageState = .{
        .branch_status = branch_status,
        .branch_status_load = .{
            .generation = 1,
            .pending = .{ .generation = 1, .origin = .background, .background_cycle_id = 1 },
            .freshness = .stale_refresh,
        },
    };
    defer page_state.branch_status.deinit();
    var context = testContext(&page_state, .default(), 80, 12);
    context.repo_root = "/repo";

    const refreshing = pageHeaderPresentation(context).?;
    const refreshing_text = (try page_header.formatAlloc(std.testing.allocator, refreshing, 80)).?;
    defer std.testing.allocator.free(refreshing_text);
    try std.testing.expectEqualStrings("HEAD feature/header ↑2 loading", refreshing_text);

    page_state.branch_status_load.pending.?.publication_allowed = false;
    const superseded = pageHeaderPresentation(context).?;
    const superseded_text = (try page_header.formatAlloc(std.testing.allocator, superseded, 80)).?;
    defer std.testing.allocator.free(superseded_text);
    try std.testing.expectEqualStrings("HEAD feature/header ↑2 stale", superseded_text);

    page_state.branch_status_load.pending.?.publication_allowed = true;
    page_state.branch_status_load.pending.?.origin = .foreground;
    try std.testing.expect(pageHeaderPresentation(context).? == .terminal);

    page_state.branch_status_load.pending = null;
    const stale = pageHeaderPresentation(context).?;
    const stale_text = (try page_header.formatAlloc(std.testing.allocator, stale, 80)).?;
    defer std.testing.allocator.free(stale_text);
    try std.testing.expectEqualStrings("HEAD feature/header ↑2 stale", stale_text);

    context.repo_root = "/other";
    try std.testing.expect(pageHeaderPresentation(context) == null);
}

test "changes active file filter uses compact discoverability row" {
    var page_state: changes_page.ChangesPageState = .{
        .review_display = .{ .changed_file_filter = .modified },
    };
    const context = testContext(&page_state, .default(), 48, 4);
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 1);
    defer ts.deinit();

    try diff_surface_view.drawSidebarDetailRow(
        &ts.surface,
        0,
        page_state.readSurface(context.source, context.navigation.layout),
        "F",
        context.theme,
    );
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [modified]  (F: filter)") != null);
    const mode_cell = ts.surface.readCell(1, 0) orelse return error.ExpectedFilterMode;
    const hint_cell = ts.surface.readCell(20, 0) orelse return error.ExpectedFilterHint;
    try std.testing.expect(mode_cell.style.fg.eql(context.theme.color(.accent)));
    try std.testing.expect(mode_cell.style.bold);
    try std.testing.expect(hint_cell.style.fg.eql(context.theme.color(.muted)));
    try std.testing.expect(hint_cell.style.dim);

    page_state.review_display.changed_file_filter = .all;
    ts.surface.clearAll();
    try diff_surface_view.drawSidebarDetailRow(
        &ts.surface,
        0,
        page_state.readSurface(context.source, context.navigation.layout),
        "F",
        context.theme,
    );
    const all_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(all_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, all_snapshot, "Files") == null);
}

test "changes reviewed and file filters retain combined status" {
    var page_state: changes_page.ChangesPageState = .{
        .review_display = .{ .changed_file_filter = .modified, .hide_reviewed_files = true },
    };
    const context = testContext(&page_state, .default(), 48, 4);
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 1);
    defer ts.deinit();

    try diff_surface_view.drawSidebarDetailRow(
        &ts.surface,
        0,
        page_state.readSurface(context.source, context.navigation.layout),
        "F",
        context.theme,
    );
    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "hiding reviewed / modified only") != null);
}

pub fn drawSearchMatchMarker(app: Context, surface: *chasen.Surface) void {
    return diff_surface_view.drawSearchMatchMarker(
        surface,
        app.page.readSurface(app.source, app.navigation.layout),
        app.theme,
    );
}

const diffContentSurface = diff_surface_view.diffContentSurface;

const withCursorBackground = diff_surface_view.withCursorBackground;
const statusStyle = diff_surface_view.statusStyle;

fn sidebarTitleStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.boldStyle(.accent);
}

fn sidebarBranchStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.style(.info);
}

/// Selected-file identity is stable chrome rather than a pane-focus signal.
/// Focus remains visible through the row-1 rule and diff body cursor.
fn paneTitleStyle(palette: theme.Palette) chasen.TextStyle {
    return diff_surface_view.statusPaneTitleStyle(palette);
}

const paneSearchStyle = diff_surface_view.paneSearchStyle;
const paneHeaderRuleStyle = diff_surface_view.paneHeaderRuleStyle;

fn testContext(page: *const changes_page.ChangesPageState, palette: theme.Palette, width: u16, height: u16) Context {
    const navigation: changes_navigation.View = .{
        .page = page,
        .repo_root = null,
        .source = .unstaged,
        .layout = .{ .width = width, .height = height },
    };
    return Context.init(page, navigation, palette, .{}, "working tree", .unstaged, null, .{});
}

test "changes page header line stats project the loaded repository aggregate" {
    const nodes = [_]file_tree.Node{.{
        .kind = .repo_root,
        .name = "gitframe",
        .path = "",
        .depth = 0,
        .stats = .{ .added = 39, .removed = 710 },
        .target = .repo_root,
    }};
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(.{
            .text = "",
            .document = .{ .files = &.{} },
            .file_text_eligibility = &.{},
            .tree = .{ .nodes = &nodes },
            .bytes = 0,
            .lines = 0,
        }),
    };
    defer page.deinit(std.testing.allocator);

    const stats = pageHeaderLineStats(testContext(&page, .default(), 80, 8)).?;
    try std.testing.expectEqual(@as(usize, 39), stats.added);
    try std.testing.expectEqual(@as(usize, 710), stats.removed);
}

fn paletteWithOverride(role: theme.Role, color: theme.ColorValue) theme.Palette {
    const FakeConfig = struct {
        role: theme.Role,
        color: theme.ColorValue,

        pub fn get(self: @This(), requested: theme.Role) ?theme.ColorValue {
            if (requested == self.role) return self.color;
            return null;
        }
    };
    return theme.Palette.fromConfig(FakeConfig{ .role = role, .color = color });
}

test "changes pane title and white rule stay stable while search uses normal prompt weight" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.info)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.muted)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.pane_command_fg)] = .{ .rgb = .{ 10, 11, 12 } };

    const title = sidebarTitleStyle(palette);
    const branch = sidebarBranchStyle(palette);
    const inactive_diff_title = paneTitleStyle(palette);
    const active_rule = paneHeaderRuleStyle(true, palette);
    const inactive_rule = paneHeaderRuleStyle(false, palette);
    const active_search = paneSearchStyle(true, palette);
    const inactive_search = paneSearchStyle(false, palette);
    try std.testing.expect(title.fg.eql(palette.color(.accent)));
    try std.testing.expect(title.bold);
    try std.testing.expect(!title.dim);
    try std.testing.expect(branch.fg.eql(palette.color(.info)));
    try std.testing.expect(!branch.dim);
    try std.testing.expect(inactive_diff_title.fg.eql(palette.color(.accent)));
    try std.testing.expect(inactive_diff_title.bold);
    try std.testing.expect(!inactive_diff_title.dim);
    try std.testing.expect(active_rule.fg.eql(.default));
    try std.testing.expect(active_rule.dim);
    try std.testing.expect(inactive_rule.fg.eql(.default));
    try std.testing.expect(inactive_rule.dim);
    try std.testing.expect(active_search.fg.eql(palette.color(.pane_command_fg)));
    try std.testing.expect(!active_search.bold);
    try std.testing.expect(inactive_search.fg.eql(palette.color(.pane_command_fg)));
    try std.testing.expect(!inactive_search.bold);
}

test "changes file search renders a bounded typed candidate window" {
    const allocator = std.testing.allocator;
    const basis: changes_file_search.Basis = .{
        .repo_epoch = 1,
        .source_session_revision = 2,
        .accepted_sidebar_revision = 3,
    };
    const nodes = [_]file_tree.Node{
        .{ .kind = .file, .name = "alpha.zig", .path = "src/alpha.zig", .path_key = "src/alpha.zig", .depth = 1, .target = .{ .diff_file = 0 } },
        .{ .kind = .file, .name = "bravo.zig", .path = "src/bravo.zig", .path_key = "src/bravo.zig", .depth = 1, .target = .{ .diff_file = 1 } },
        .{ .kind = .file, .name = "charlie.zig", .path = "src/charlie.zig", .path_key = "src/charlie.zig", .depth = 1, .target = .{ .status_entry = 2 } },
    };
    const loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &.{} },
        .file_text_eligibility = &.{},
        .tree = .{ .nodes = &nodes },
        .bytes = 0,
        .lines = 0,
    };

    var state: changes_file_search.State = .{ .mode = true };
    defer state.deinit(allocator);
    try state.input.insertSlice("src/");
    var projection = try changes_file_search.buildProjection(allocator, &loaded, "src/", .{ .basis = basis });
    var projection_live = true;
    defer if (projection_live) projection.deinit(allocator);
    state.publish(allocator, &projection);
    projection_live = false;
    state.move(1);
    state.move(1);

    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 1, 2, 3 } };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(24, 4);
    defer ts.deinit();

    try drawFileSearch(&ts.surface, &state, palette);

    const snapshot = try ts.snapshot(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file: src/") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Enter: open") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/alpha.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/bravo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "src/charlie.zig") != null);
    const focused = ts.surface.readCell(1, 3) orelse return error.ExpectedFocusedSearchCandidate;
    try std.testing.expect(focused.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(focused.style.bold);
}

test "changes file search renders unavailable and no-match terminals" {
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(48, 3);
    defer ts.deinit();

    const unavailable: changes_file_search.State = .{ .mode = true };
    try drawFileSearch(&ts.surface, &unavailable, .default());
    var snapshot = try ts.snapshot(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable; wait or press Esc") != null);
    std.testing.allocator.free(snapshot);

    ts.surface.clearAll();
    const no_match: changes_file_search.State = .{
        .mode = true,
        .basis = .{ .repo_epoch = 1, .source_session_revision = 1, .accepted_sidebar_revision = 1 },
        .projection_available = true,
        .no_match = true,
    };
    try drawFileSearch(&ts.surface, &no_match, .default());
    snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "No matching files") != null);
}

test "changes file search keeps long ASCII and Unicode input cursor visible" {
    var state: changes_file_search.State = .{ .mode = true };
    try state.input.insertSlice("abcdefghijklmnopqrstuvwxyz");

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(18, 3);
    defer ts.deinit();

    try drawFileSearch(&ts.surface, &state, .default());
    var snapshot = try ts.snapshot(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "vwxyz") != null);
    try std.testing.expect(ts.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 0), ts.screen.cursor.row);
    try std.testing.expect(ts.screen.cursor.col < ts.surface.size().width);
    std.testing.allocator.free(snapshot);

    state.input = .{};
    try state.input.insertSlice("prefix-長い🐈末尾");
    ts.surface.clearAll();
    try drawFileSearch(&ts.surface, &state, .default());
    snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try ts.expectCellText(12, 0, "末");
    try ts.expectCellText(14, 0, "尾");
    try std.testing.expect(ts.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 0), ts.screen.cursor.row);
    try std.testing.expect(ts.screen.cursor.col < ts.surface.size().width);
}

test "changes file search unavailable terminal replaces no-changes body" {
    const page: changes_page.ChangesPageState = .{
        .load = .{ .state = .{ .empty = .no_changes } },
        .file_search = .{ .mode = true },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(60, 6);
    defer ts.deinit();

    try view(testContext(&page, .default(), 60, 6), &ts.surface);

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file:") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "No changes") == null);
}

test "changes file search uses full body when compact sidebar leaves no prompt pane" {
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwo()),
        .file_search = .{ .mode = true },
    };
    defer page.deinit(std.testing.allocator);

    for ([_]u16{ 24, 25 }) |width| {
        var ts: chasen.testing.TestSurface = undefined;
        try ts.init(width, 6);
        defer ts.deinit();

        try view(testContext(&page, .default(), width, 6), &ts.surface);

        try ts.expectCellText(1, 0, "F");
        const snapshot = try ts.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(snapshot);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "Find file:") != null);
        try std.testing.expect(std.mem.indexOf(u8, snapshot, "File list unavailable") != null);
    }
}

test "sidebar renderer owns badges summaries selection styles and horizontal scroll" {
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffTwoWithStatuses()),
        .viewer = .{ .focus = .sidebar },
    };
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.accent)] = .{ .rgb = .{ 7, 8, 9 } };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();

    const selected_row = changes_layout.sidebar_header_rows;
    const summary_row = changes_layout.sidebar_header_rows - 1;
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(2, changes_layout.sidebar_header_rows, "A");
    try ts.expectCellText(2, changes_layout.sidebar_header_rows + 1, "D");
    try ts.expectCellText(1, summary_row, "2");
    const active_badge = ts.surface.readCell(2, selected_row) orelse return error.ExpectedActiveBadge;
    const active_path = ts.surface.readCell(6, selected_row) orelse return error.ExpectedActivePath;
    const active_trailing = ts.surface.readCell(33, selected_row) orelse return error.ExpectedActiveTrailingCell;
    const active_summary = ts.surface.readCell(1, summary_row) orelse return error.ExpectedActiveSummary;
    try std.testing.expect(active_badge.style.fg.eql(palette.color(.success)));
    for ([_]chasen.Cell{ active_badge, active_path, active_trailing }) |cell| {
        try std.testing.expect(cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    try std.testing.expect(active_path.style.bold);
    try std.testing.expect(active_trailing.style.bold);
    try std.testing.expect(active_summary.style.eql(palette.style(.muted)));

    page.viewer.focus = .diff;
    ts.surface.clearAll();
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    const inactive_badge = ts.surface.readCell(2, selected_row) orelse return error.ExpectedInactiveBadge;
    const inactive_path = ts.surface.readCell(6, selected_row) orelse return error.ExpectedInactivePath;
    const inactive_trailing = ts.surface.readCell(33, selected_row) orelse return error.ExpectedInactiveTrailingCell;
    const inactive_summary = ts.surface.readCell(1, summary_row) orelse return error.ExpectedInactiveSummary;
    try std.testing.expect(inactive_badge.style.fg.eql(palette.color(.success)));
    for ([_]chasen.Cell{ inactive_badge, inactive_path, inactive_trailing }) |cell| {
        try std.testing.expect(!cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    try std.testing.expect(inactive_path.style.bold);
    try std.testing.expect(inactive_summary.style.eql(palette.style(.muted)));

    page.viewer.focus = .sidebar;
    page.file_search.mode = true;
    ts.surface.clearAll();
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    // Search enter, no-match, and unavailable terminals all retain mode and
    // therefore let the search candidate presentation own attention.
    try std.testing.expect(!ts.surface.readCell(6, selected_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!ts.surface.readCell(33, selected_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    var search_full: chasen.testing.TestSurface = undefined;
    try search_full.init(80, 9);
    defer search_full.deinit();
    try view(testContext(&page, palette, 80, 9), &search_full.surface);
    const search_separator_col = changes_layout.sidebarWidth(80, page.viewer.sidebar_width);
    try search_full.expectCellText(search_separator_col + 2, 0, "F");
    const search_snapshot = try search_full.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(search_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, search_snapshot, "File list unavailable") != null);

    // Cancel/empty submit and sidebar-entry success restore sidebar focus,
    // while the inactive rendering above also represents a successful search
    // entered from the diff pane.
    page.file_search.mode = false;
    ts.surface.clearAll();
    try viewSidebar(testContext(&page, palette, 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(33, selected_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    var full: chasen.testing.TestSurface = undefined;
    try full.init(80, 9);
    defer full.deinit();
    try view(testContext(&page, palette, 80, 9), &full.surface);
    const separator_col = changes_layout.sidebarWidth(80, page.viewer.sidebar_width);
    const separator = full.surface.readCell(separator_col, selected_row) orelse return error.ExpectedSidebarSeparator;
    try std.testing.expect(separator.style.fg.eql(.default));
    try std.testing.expect(separator.style.dim);
    try std.testing.expect(!separator.style.reverse);
    try std.testing.expect(!separator.style.bg.eql(palette.color(.pane_cursor_bg)));

    var short: chasen.testing.TestSurface = undefined;
    try short.init(12, changes_layout.sidebar_header_rows);
    defer short.deinit();
    try viewSidebar(testContext(&page, palette, 80, 9), &short.surface, page.load.state.loaded.loaded);
    try short.expectCellText(1, summary_row, "2");

    const nodes = [_]file_tree.Node{.{
        .kind = .file,
        .name = "very_long_tail_file.zig",
        .path = "a/b/c/d/e/f/very_long_tail_file.zig",
        .depth = 6,
        .target = .{ .diff_file = 0 },
        .status = .modified,
        .mode_changed = true,
    }};
    page.load = test_support.loadState(.{
        .text = "",
        .document = .{ .files = &test_support.files_one },
        .file_text_eligibility = &.{.selectable_utf8},
        .tree = .{ .nodes = &nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    });
    page.viewer.sidebar_horizontal_scroll = 12;
    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(24, 8);
    defer narrow.deinit();
    try viewSidebar(testContext(&page, palette, 80, 9), &narrow.surface, page.load.state.loaded.loaded);
    try narrow.expectCellText(2, changes_layout.sidebar_header_rows, "M");
    try narrow.expectCellText(4, changes_layout.sidebar_header_rows, "m");
    try std.testing.expect(narrow.surface.readCell(4, changes_layout.sidebar_header_rows).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(narrow.surface.readCell(23, changes_layout.sidebar_header_rows).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    const snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "very_long") != null);
}

test "empty status-filter projection keeps repository root as context" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .file,
            .name = "added.zig",
            .path = "src/added.zig",
            .depth = 0,
            .target = .{ .diff_file = 0 },
            .status = .added,
        },
        .{
            .kind = .file,
            .name = "deleted.zig",
            .path = "src/deleted.zig",
            .depth = 0,
            .target = .{ .diff_file = 1 },
            .status = .deleted,
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var loaded: loaded_diff.LoadedDiff = .{
        .text = "",
        .document = .{ .files = &test_support.files_two_statuses },
        .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
        .tree = .{ .nodes = &nodes },
        .collapsed_dirs = .{},
        .bytes = 0,
        .lines = 0,
    };
    try loaded.rebuildVisibleNodes(arena.allocator(), false, .binary);
    try std.testing.expectEqual(@as(usize, 0), loaded.visibleNodeCount());

    var page: changes_page.ChangesPageState = .{
        .review_display = .{ .changed_file_filter = .binary },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 6);
    defer ts.deinit();

    var context = testContext(&page, .default(), 80, 9);
    context.repo_root = "/work/gitframe";
    try viewSidebar(context, &ts.surface, loaded);

    const snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "Files [binary]  (F: filter)") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "2 files / 0 hunks") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "gitframe") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "added.zig") == null);
    try ts.expectCellText(1, changes_layout.sidebar_header_rows, "g");
}

test "changes markerless root renderer keeps hierarchy and selection styling" {
    const nodes = [_]file_tree.Node{
        .{
            .kind = .repo_root,
            .name = "gitframe",
            .path = "",
            .depth = 0,
            .stats = .{ .added = 51, .removed = 25 },
            .target = .repo_root,
        },
        .{
            .kind = .directory,
            .name = "src",
            .path = "src",
            .depth = 1,
        },
    };
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const root = sidebar_view_model.rowForNode(tree, &collapsed, &.{}, 0, 0).?;
    const directory = sidebar_view_model.rowForNode(tree, &collapsed, &.{}, 1, 1).?;

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(40, 2);
    defer ts.deinit();
    const palette = paletteWithOverride(.pane_cursor_bg, .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } });

    try drawSidebarRow(&ts.surface, 0, root, true, 0, palette);
    try drawSidebarRow(&ts.surface, 1, directory, true, 0, palette);

    try ts.expectCellText(0, 0, " ");
    try ts.expectCellText(1, 0, "g");
    try std.testing.expect(!ts.surface.readCell(1, 0).?.style.reverse);
    try std.testing.expect(ts.surface.readCell(1, 0).?.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(ts.surface.readCell(1, 0).?.style.bold);
    try std.testing.expect(ts.surface.readCell(0, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(1, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(39, 0).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    const root_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(root_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, root_snapshot, "+51") == null);
    try std.testing.expect(std.mem.indexOf(u8, root_snapshot, "-25") == null);
    try ts.expectCellText(2, 1, "▾");
    try ts.expectCellText(4, 1, "s");
    try std.testing.expect(ts.surface.readCell(4, 1).?.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(ts.surface.readCell(4, 1).?.style.bold);
    try std.testing.expect(ts.surface.readCell(39, 1).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    ts.surface.clearAll();
    try drawSidebarRow(&ts.surface, 0, root, false, 0, palette);
    try ts.expectCellText(0, 0, " ");
    const retained_root = ts.surface.readCell(1, 0) orelse return error.ExpectedRetainedRoot;
    const retained_trailing = ts.surface.readCell(39, 0) orelse return error.ExpectedRetainedRootTrailingCell;
    try std.testing.expect(retained_root.style.bold);
    try std.testing.expect(retained_root.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(!retained_root.style.dim);
    try std.testing.expect(!retained_root.style.reverse);
    try std.testing.expect(!retained_root.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!retained_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
}

test "changes markerless root renderer uses full width for scrolling and clipping" {
    const nodes = [_]file_tree.Node{.{
        .kind = .repo_root,
        .name = "0123456789abcdefghijklmnopqrstuv",
        .path = "",
        .depth = 0,
        .stats = .{ .added = 68, .removed = 3 },
        .target = .repo_root,
    }};
    const tree: file_tree.FileTree = .{ .nodes = &nodes };
    const collapsed: file_tree.CollapsedSet = .empty;
    const root = sidebar_view_model.rowForNode(tree, &collapsed, &.{}, 0, 0).?;
    const palette: theme.Palette = .default();

    var scrolled: chasen.testing.TestSurface = undefined;
    try scrolled.init(40, 1);
    defer scrolled.deinit();
    try drawSidebarRow(&scrolled.surface, 0, root, true, 1, palette);
    try scrolled.expectCellText(0, 0, " ");
    try scrolled.expectCellText(1, 0, "0");
    const scrolled_snapshot = try scrolled.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(scrolled_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_snapshot, "+68") == null);
    try std.testing.expect(std.mem.indexOf(u8, scrolled_snapshot, "-3") == null);

    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(20, 1);
    defer narrow.deinit();
    try drawSidebarRow(&narrow.surface, 0, root, true, 0, palette);
    try narrow.expectCellText(0, 0, " ");
    try narrow.expectCellText(1, 0, "0");
    try narrow.expectCellText(18, 0, "h");
    try narrow.expectCellText(19, 0, "…");
    const snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "+68") == null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "-3") == null);
}

test "sidebar cursor background composes reviewed status mode and path semantics" {
    const row: sidebar_view_model.Row = .{
        .node_index = 0,
        .kind = .file,
        .selected = true,
        .depth = 0,
        .name = "script.sh",
        .path = "script.sh",
        .stats = .{},
        .status = .modified,
        .stage_presence = .mixed,
        .mode_changed = true,
        .reviewed = true,
        .fold = .none,
    };
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.info)] = .{ .rgb = .{ 10, 11, 12 } };

    var active: chasen.testing.TestSurface = undefined;
    try active.init(40, 1);
    defer active.deinit();
    try drawSidebarRow(&active.surface, 0, row, true, 0, palette);

    const points = [_]struct {
        col: u16,
        role: theme.Role,
    }{
        .{ .col = 1, .role = .success },
        .{ .col = 2, .role = .prompt },
        .{ .col = 4, .role = .info },
        .{ .col = 6, .role = .prompt },
    };
    for (points) |point| {
        const cell = active.surface.readCell(point.col, 0) orelse return error.ExpectedActiveSemanticCell;
        try std.testing.expect(cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    const active_trailing = active.surface.readCell(39, 0) orelse return error.ExpectedActiveTrailingCell;
    try std.testing.expect(active_trailing.style.fg.eql(palette.color(.prompt)));
    try std.testing.expect(active_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(40, 1);
    defer inactive.deinit();
    try drawSidebarRow(&inactive.surface, 0, row, false, 0, palette);
    for (points) |point| {
        const cell = inactive.surface.readCell(point.col, 0) orelse return error.ExpectedInactiveSemanticCell;
        try std.testing.expect(cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(!cell.style.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!cell.style.dim);
        try std.testing.expect(!cell.style.reverse);
    }
    const inactive_trailing = inactive.surface.readCell(39, 0) orelse return error.ExpectedInactiveTrailingCell;
    try std.testing.expect(!inactive_trailing.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!inactive_trailing.style.dim);
    try std.testing.expect(!inactive_trailing.style.reverse);
}

test "sidebar row stage matrix keeps semantic foreground independent of cursor chrome" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.staged)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.prompt)] = .{ .rgb = .{ 7, 8, 9 } };
    palette.colors[@intFromEnum(theme.Role.danger)] = .{ .rgb = .{ 10, 11, 12 } };

    const cases = [_]struct {
        stage_presence: file_tree.StagePresence,
        path_color: chasen.Color,
        status_color: chasen.Color,
    }{
        .{ .stage_presence = .clean_or_unknown, .path_color = .default, .status_color = palette.color(.prompt) },
        .{ .stage_presence = .staged_only, .path_color = palette.color(.staged), .status_color = palette.color(.staged) },
        .{ .stage_presence = .mixed, .path_color = palette.color(.prompt), .status_color = palette.color(.prompt) },
        .{ .stage_presence = .conflict, .path_color = palette.color(.danger), .status_color = palette.color(.danger) },
    };
    for (cases) |case| {
        const row: sidebar_view_model.Row = .{
            .node_index = 0,
            .kind = .file,
            .selected = true,
            .depth = 0,
            .name = "file.zig",
            .path = "file.zig",
            .stats = .{},
            .status = .modified,
            .stage_presence = case.stage_presence,
            .mode_changed = false,
            .reviewed = false,
            .fold = .none,
        };
        const inactive_path = sidebarRowStyle(row, palette);
        const active_path = withCursorBackground(inactive_path, palette.color(.pane_cursor_bg));
        const active_status = statusStyle(row, .modified, palette, palette.color(.pane_cursor_bg));

        try std.testing.expect(inactive_path.fg.eql(case.path_color));
        try std.testing.expect(inactive_path.bold);
        try std.testing.expect(!inactive_path.dim);
        try std.testing.expect(!inactive_path.reverse);
        try std.testing.expect(!inactive_path.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(active_path.fg.eql(case.path_color));
        try std.testing.expect(active_path.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!active_path.dim);
        try std.testing.expect(!active_path.reverse);
        try std.testing.expect(active_status.fg.eql(case.status_color));
        try std.testing.expect(active_status.bg.eql(palette.color(.pane_cursor_bg)));
        try std.testing.expect(!active_status.dim);
        try std.testing.expect(!active_status.reverse);
    }
}

test "diff renderer owns header search marker gutter and input presentation" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.pane_cursor_bg)] = .{ .rgb = .{ 1, 2, 3 } };
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .focus = .diff, .diff_cursor = .{ .hunk_header = 0 } },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(90, 10);
    defer ts.deinit();

    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(0, 1, "─");
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.default));
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.dim);

    page.viewer.focus = .sidebar;
    ts.surface.clear(.{ .col = 0, .row = 0, .width = 90, .height = 10 });
    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try std.testing.expect(ts.surface.readCell(0, 1).?.style.fg.eql(.default));
    try std.testing.expect(!ts.surface.readCell(1, changes_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(!ts.surface.readCell(89, changes_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    page.viewer.focus = .diff;
    page.search.match_offset = 0;
    ts.surface.clear(.{ .col = 0, .row = 0, .width = 90, .height = 10 });
    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(0, changes_layout.diff_body_start_row, "»");
    try ts.expectCellText(1, changes_layout.diff_body_start_row, "▌");
    try ts.expectCellText(2, changes_layout.diff_body_start_row, "┏");
    try std.testing.expect(!ts.surface.readCell(0, changes_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(1, changes_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(2, changes_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));
    try std.testing.expect(ts.surface.readCell(89, changes_layout.diff_body_start_row).?.style.bg.eql(palette.color(.pane_cursor_bg)));

    page.search.match_offset = null;
    page.viewer.display_mode = .side_by_side;
    var narrow: chasen.testing.TestSurface = undefined;
    try narrow.init(72, 8);
    defer narrow.deinit();
    try viewDiffPane(testContext(&page, palette, 72, 9), &narrow.surface, page.load.state.loaded.loaded);
    const narrow_snapshot = try narrow.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(narrow_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, narrow_snapshot, "unified (auto)  (u: toggle)") != null);

    page.search.mode = true;
    try page.search.input.insertSlice("missing");
    ts.surface.clear(.{ .col = 0, .row = 0, .width = 90, .height = 10 });
    try viewDiffPane(testContext(&page, palette, 90, 11), &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(1, 1, "s");
    try ts.expectCellText(9, 1, "m");
    try ts.expectCellText(16, 1, " ");
    const search_snapshot = try ts.snapshot(std.testing.allocator);
    defer std.testing.allocator.free(search_snapshot);
    try std.testing.expect(std.mem.indexOf(u8, search_snapshot, "(u: toggle)") == null);
}

test "changes display mode header key follows the effective keymap and input owner" {
    var page: changes_page.ChangesPageState = .{};
    var config: keymap.Config = .{};
    config.set(.toggle_display_mode, .{ .plain_codepoint = 'z' });
    var context = testContext(&page, .default(), 90, 10);
    context.keymap = keymap.Effective.fromConfig(config);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("z", displayModeToggleKey(context, buffer[0..]).?);

    page.search.mode = true;
    try std.testing.expect(displayModeToggleKey(context, buffer[0..]) == null);
    page.search.mode = false;
    page.file_search.mode = true;
    try std.testing.expect(displayModeToggleKey(context, buffer[0..]) == null);
}

test "status-only header keeps semantic statistics and metadata when inactive" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.success)] = .{ .rgb = .{ 1, 2, 3 } };
    palette.colors[@intFromEnum(theme.Role.danger)] = .{ .rgb = .{ 4, 5, 6 } };
    palette.colors[@intFromEnum(theme.Role.muted)] = .{ .rgb = .{ 7, 8, 9 } };

    var active: chasen.testing.TestSurface = undefined;
    try active.init(40, 4);
    defer active.deinit();
    try drawStatusBody(&active.surface, "src/new.zig", "status only", .{ .added = 12, .removed = 4 }, true, palette);

    var inactive: chasen.testing.TestSurface = undefined;
    try inactive.init(40, 4);
    defer inactive.deinit();
    try drawStatusBody(&inactive.surface, "src/new.zig", "status only", .{ .added = 12, .removed = 4 }, false, palette);

    const suffix_width = chasen.text.displayWidth(" +12 -4");
    const metadata_col: u16 = 40 - @as(u16, @intCast(suffix_width));
    const added_col = metadata_col + 1;
    const separator_col = added_col + 3;
    const removed_col = separator_col + 1;
    const points = [_]struct {
        col: u16,
        role: theme.Role,
        bold: bool,
    }{
        .{ .col = metadata_col, .role = .muted, .bold = false },
        .{ .col = added_col, .role = .success, .bold = true },
        .{ .col = separator_col, .role = .muted, .bold = false },
        .{ .col = removed_col, .role = .danger, .bold = true },
    };
    for (points) |point| {
        const active_cell = active.surface.readCell(point.col, 0) orelse return error.ExpectedActiveStatusHeaderCell;
        const inactive_cell = inactive.surface.readCell(point.col, 0) orelse return error.ExpectedInactiveStatusHeaderCell;
        try std.testing.expect(active_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expect(inactive_cell.style.fg.eql(palette.color(point.role)));
        try std.testing.expectEqual(point.bold, active_cell.style.bold);
        try std.testing.expectEqual(point.bold, inactive_cell.style.bold);
        try std.testing.expect(!active_cell.style.dim);
        try std.testing.expect(!inactive_cell.style.dim);
    }

    const active_body = active.surface.readCell(0, 2) orelse return error.ExpectedActiveStatusBodyCell;
    const inactive_body = inactive.surface.readCell(0, 2) orelse return error.ExpectedInactiveStatusBodyCell;
    try std.testing.expect(!active_body.style.dim);
    try std.testing.expect(inactive_body.style.dim);
}

test "status-only fallback preserves conflict suffix outside resolver rendering" {
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{ .selected_target = .{ .status_only = 0 } },
    };
    defer page.deinit(std.testing.allocator);
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "UU a\x00");
    try page.git_status.replace("/repo", &status_bundle);

    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 8);
    defer ts.deinit();
    try viewDiffPane(testContext(&page, .default(), 80, 9), &ts.surface, page.load.state.loaded.loaded);
    try test_support.expectSnapshotContains(&ts, "status: unmerged (conflict)");
}

test "inactive status-only pending and inert diff path headers keep semantic intensity" {
    const palette = theme.Palette.default();
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(test_support.loadedDiffOne()),
        .viewer = .{
            .selected_target = .{ .status_only = 0 },
            .focus = .sidebar,
        },
    };
    defer page.git_status.deinit();
    var status_bundle = try git_status.StatusBundle.parseOwned(std.testing.allocator, "?? new.zig\x00");
    try page.git_status.replace("/repo", &status_bundle);

    var status_only: chasen.testing.TestSurface = undefined;
    try status_only.init(40, 6);
    defer status_only.deinit();
    var status_context = testContext(&page, palette, 40, 7);
    status_context.repo_root = "/repo";
    status_context.navigation.repo_root = "/repo";
    try viewDiffPane(status_context, &status_only.surface, page.load.state.loaded.loaded);
    const status_path = status_only.surface.readCell(1, 0) orelse return error.ExpectedStatusOnlyPath;
    try std.testing.expect(status_path.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(status_path.style.bold);
    try std.testing.expect(!status_path.style.dim);

    page.changes_projection.pending = try changes_projection.testing.cloneRequest(
        std.testing.allocator,
        app_page.RequestIdentity.changes(0, 1),
        1,
        "/repo",
        "new.zig",
        .generated_added_file,
        .unstaged,
        0,
        0,
    );
    defer page.changes_projection.clearPending(std.testing.allocator);
    var pending: chasen.testing.TestSurface = undefined;
    try pending.init(40, 6);
    defer pending.deinit();
    try viewDiffPane(status_context, &pending.surface, page.load.state.loaded.loaded);
    const pending_path = pending.surface.readCell(1, 0) orelse return error.ExpectedPendingPath;
    try std.testing.expect(pending_path.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(pending_path.style.bold);
    try std.testing.expect(!pending_path.style.dim);
    page.changes_projection.clearPending(std.testing.allocator);

    const inert_eligibility = [_]loaded_diff.FileTextEligibility{.inert_invalid_utf8};
    var inert_loaded = test_support.loadedDiffOne();
    inert_loaded.file_text_eligibility = &inert_eligibility;
    page.load = test_support.loadState(inert_loaded);
    page.viewer.selected_target = .{ .diff_file = 0 };
    var inert: chasen.testing.TestSurface = undefined;
    try inert.init(40, 6);
    defer inert.deinit();
    const inert_context = testContext(&page, palette, 40, 7);
    try viewDiffPane(inert_context, &inert.surface, page.load.state.loaded.loaded);
    const inert_path = inert.surface.readCell(1, 0) orelse return error.ExpectedInertPath;
    try std.testing.expect(inert_path.style.fg.eql(palette.color(.accent)));
    try std.testing.expect(inert_path.style.bold);
    try std.testing.expect(!inert_path.style.dim);
}

test "reviewed sidebar marker and visible search marker are Changes view concerns" {
    var reviewed = [_]bool{ true, false };
    var page: changes_page.ChangesPageState = .{
        .load = test_support.loadState(.{
            .text = "",
            .document = .{ .files = &test_support.files_two_statuses },
            .file_text_eligibility = &.{ .selectable_utf8, .selectable_utf8 },
            .tree = .{ .nodes = &test_support.tree_two_status_nodes },
            .reviewed_files = &reviewed,
            .collapsed_dirs = .{},
            .bytes = 0,
            .lines = 0,
        }),
        .search = .{ .match_offset = 4 },
        .viewer = .{ .diff_scroll = 3 },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(34, 8);
    defer ts.deinit();
    const ctx = testContext(&page, .default(), 80, 9);
    try viewSidebar(ctx, &ts.surface, page.load.state.loaded.loaded);
    try ts.expectCellText(1, changes_layout.sidebar_header_rows, "✓");
    drawSearchMatchMarker(ctx, &ts.surface);
    try ts.expectCellText(0, changes_layout.diff_body_start_row + 1, "»");
}
