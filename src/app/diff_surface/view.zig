//! Page-independent footer and state rendering for a diff surface.
//!
//! Pages inject only presentation values which are outside the shared surface
//! contract (currently the auto-reload capability). This module must not
//! import a page namespace.

const std = @import("std");
const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const diff_surface = @import("../diff_surface.zig");
const app_load_state = @import("../load_state.zig");
const app_state = @import("../state.zig");
const view_primitives = @import("../view_primitives.zig");
const diff_render = @import("../../diff/render.zig");
const diff_source = @import("../../diff/source.zig");
const file_tree = @import("../../file_tree.zig");
const file_search = @import("file_search.zig");
const layout = @import("layout.zig");
const loaded_diff = @import("../../loaded_diff.zig");
const sidebar_view_model = @import("../../sidebar/view_model.zig");

/// Normalized presentation capabilities for an empty diff surface.
///
/// `fetch_key` is both reachability and presentation: null means that fetch
/// must not be advertised. Page adapters collapse richer operation policy and
/// effective key binding into this value before crossing the shared boundary.
pub const NoChangesActionPresentation = struct {
    show_repo_picker: bool = false,
    show_pull: bool = false,
    fetch_key: ?[]const u8 = null,
};

pub const FooterView = struct {
    /// Page-local text input consumes printable keys before shell actions.
    /// Suppress ordinary shell hints while those actions are unreachable.
    normal_action_hints_enabled: bool,
    sidebar_hidden: bool,
    auto_reload_enabled: bool,
    source_label: ?[]const u8,
    activation: ?ActivationPresentation,
};

pub const ActivationPresentation = enum {
    validating,
    stale,
};

pub const FooterArgs = struct {
    surface: diff_surface.ReadSurface,
    /// Page-owned policy narrowed to a presentation-only value.
    auto_reload_enabled: bool,
};

pub fn footer(args: FooterArgs) FooterView {
    return .{
        .normal_action_hints_enabled = !args.surface.file_search.mode,
        .sidebar_hidden = args.surface.viewer.sidebar_hidden,
        .auto_reload_enabled = args.auto_reload_enabled,
        .source_label = sourceFooterLabel(args.surface.source),
        .activation = activationPresentation(args.surface.activation, args.surface.source),
    };
}

pub fn activationPresentation(activation: *const diff_surface.authority.Lifecycle, source: diff_source.SourceMode) ?ActivationPresentation {
    // Accepted one-shot input is immutable on re-entry and must never pretend
    // that stdin/pager is being read a second time.
    if (diff_source.sourceIsOneShotInput(source)) return null;
    return switch (activation.state) {
        .inactive => null,
        .active => |active| blk: {
            const members = active.members;
            if (members.source == .pending or members.status == .pending or members.branch == .pending) {
                break :blk .validating;
            }
            if (members.source == .failed or members.status == .failed or members.branch == .failed) {
                break :blk .stale;
            }
            break :blk null;
        },
    };
}

pub fn sourceFooterLabel(source: diff_source.SourceMode) ?[]const u8 {
    return switch (source) {
        .unstaged => null,
        .cached => "staged",
        .stdin => "stdin",
        .pager => "pager",
        .patch_file => "patch",
        .range => "range",
        .no_index => "difftool",
    };
}

pub const StateTone = enum {
    muted,
    loading,
    warning,
    failure,
};

pub const StateMessage = struct {
    title: []const u8,
    body: []const u8 = "",
    /// Borrowed presentation text. Helpers which format this field document
    /// the arena/frame owner and never require per-message deinitialization.
    hint: []const u8 = "",
    tone: StateTone = .muted,
};

pub fn viewLoadState(load: *const app_load_state.LoadRuntimeState, col: *chasen.Column, palette: theme.Palette) void {
    switch (load.state) {
        .idle => drawStateMessageColumn(col, .{
            .title = "Waiting to load diff",
            .body = "GitFrame is waiting for a load request.",
            .hint = "Press q to quit.",
        }, palette),
        .loading => drawStateMessageColumn(col, .{
            .title = "Loading diff",
            .body = "Reading and parsing the current source.",
            .hint = "Press q to quit.",
            .tone = .loading,
        }, palette),
        .empty => |reason| drawStateMessageColumn(col, emptyLoadMessage(reason), palette),
        .failed => |failed| drawStateMessageColumn(col, .{
            .title = "Could not load diff",
            .body = firstLine(failed.message),
            .hint = "Press r to retry or q to quit.",
            .tone = .failure,
        }, palette),
        .loaded => {},
    }
}

pub fn emptyLoadMessage(reason: app_load_state.EmptyReason) StateMessage {
    return switch (reason) {
        .no_changes => .{
            .title = "No changes",
            .body = "Working tree has no diff for the current source.",
            .hint = "Press r to reload or q to quit.",
        },
        .no_repository => .{
            .title = "No Git repository",
            .body = "Run GitFrame inside a repository or a workspace containing direct child repositories.",
            .hint = "Press q to quit.",
            .tone = .warning,
        },
    };
}

/// Builds a message whose dynamic hint, when needed, is owned by
/// `frame_allocator`. The returned slices remain valid until that frame/arena
/// is reset or deinitialized; callers must not free them individually.
pub fn noChangesMessage(frame_allocator: std.mem.Allocator, presentation: NoChangesActionPresentation) StateMessage {
    return .{
        .title = "No changes",
        .body = "Working tree has no diff for the current source.",
        .hint = noChangesHint(frame_allocator, presentation),
    };
}

fn noChangesHint(frame_allocator: std.mem.Allocator, presentation: NoChangesActionPresentation) []const u8 {
    const fetch_key = presentation.fetch_key;
    // `U` refreshes first and may finish as "nothing to pull", so advertise
    // the workflow rather than predicting remote state from a stale count.
    if (presentation.show_repo_picker and presentation.show_pull and fetch_key != null) {
        return std.fmt.allocPrint(frame_allocator, "Press R to switch repository, U to fetch + fast-forward, {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press R to switch repository, U to fetch + fast-forward, r to reload, or q to quit.";
    }
    if (presentation.show_repo_picker and presentation.show_pull) return "Press R to switch repository, U to fetch + fast-forward, r to reload, or q to quit.";
    if (presentation.show_repo_picker and fetch_key != null) {
        return std.fmt.allocPrint(frame_allocator, "Press R to switch repository, {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press R to switch repository, r to reload, or q to quit.";
    }
    if (presentation.show_repo_picker) return "Press R to switch repository, r to reload, or q to quit.";
    if (presentation.show_pull and fetch_key != null) {
        return std.fmt.allocPrint(frame_allocator, "Press U to fetch + fast-forward, {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press U to fetch + fast-forward, r to reload, or q to quit.";
    }
    if (presentation.show_pull) return "Press U to fetch + fast-forward, r to reload, or q to quit.";
    if (fetch_key != null) {
        return std.fmt.allocPrint(frame_allocator, "Press {s} to fetch, r to reload, or q to quit.", .{fetch_key.?}) catch "Press r to reload or q to quit.";
    }
    return "Press r to reload or q to quit.";
}

test "no changes message borrows formatted hint from caller frame arena" {
    var frame = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer frame.deinit();

    const message = noChangesMessage(frame.allocator(), .{
        .show_repo_picker = true,
        .show_pull = true,
        .fetch_key = "Ctrl+f",
    });
    try std.testing.expectEqualStrings(
        "Press R to switch repository, U to fetch + fast-forward, Ctrl+f to fetch, r to reload, or q to quit.",
        message.hint,
    );
}

pub fn filterEmptyMessage(display: app_state.ReviewDisplayState) StateMessage {
    const hint = if (display.hide_reviewed_files and display.changed_file_filter != .all)
        "Press F to change filter, H to show reviewed files, or r to reload."
    else if (display.hide_reviewed_files)
        "Press H to show reviewed files or r to reload."
    else if (display.changed_file_filter != .all)
        "Press F to change filter or r to reload."
    else
        "Press r to reload.";

    return .{
        .title = "No files match current filters",
        .body = "The diff is loaded, but the current sidebar filters hide every file.",
        .hint = hint,
    };
}

pub fn drawStateMessage(surface: *chasen.Surface, message: StateMessage, palette: theme.Palette) void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const width = @min(size.width, 64);
    const height: u16 = @min(size.height, 6);
    var panel = surface.child(.{
        .col = if (size.width > width) (size.width - width) / 2 else 0,
        .row = if (size.height > height) (size.height - height) / 2 else 0,
        .width = width,
        .height = height,
    });
    var col = panel.column(.{ .gap = 1 });
    drawStateMessageColumn(&col, message, palette);
}

pub fn drawStateMessageColumn(col: *chasen.Column, message: StateMessage, palette: theme.Palette) void {
    col.borrowText(message.title, stateTitleStyle(message.tone, palette));
    if (message.body.len > 0) col.borrowText(message.body, stateBodyStyle(message.tone, palette));
    if (message.hint.len > 0) col.borrowText(message.hint, stateHintStyle(palette));
}

pub fn stateTitleStyle(tone: StateTone, palette: theme.Palette) chasen.TextStyle {
    return switch (tone) {
        .muted => palette.boldStyle(.muted),
        .loading => palette.boldStyle(.prompt),
        .warning => palette.boldStyle(.warning),
        .failure => palette.boldStyle(.danger),
    };
}

pub fn stateBodyStyle(tone: StateTone, palette: theme.Palette) chasen.TextStyle {
    return switch (tone) {
        .failure => palette.style(.danger),
        else => palette.style(.muted),
    };
}

pub fn stateHintStyle(palette: theme.Palette) chasen.TextStyle {
    return .{ .fg = palette.color(.muted), .dim = true };
}

pub fn firstLine(text: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, text, "\r\n")) |end| return text[0..end];
    return text;
}

/// Synchronous page adapter that keeps the outer shell separate from the
/// shared diff-pane renderer behind this boundary.
pub const DiffPaneRenderer = struct {
    ctx: *anyopaque,
    render_fn: *const fn (ctx: *anyopaque, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) anyerror!void,

    pub fn render(self: DiffPaneRenderer, surface: *chasen.Surface, loaded: loaded_diff.LoadedDiff) !void {
        return self.render_fn(self.ctx, surface, loaded);
    }
};

pub const ViewArgs = struct {
    state: diff_surface.ReadSurface,
    palette: theme.Palette,
    source_label: []const u8,
    no_changes_actions: NoChangesActionPresentation,
    empty_message: ?StateMessage = null,
    branch: ?SidebarBranchPresentation,
    diff_pane: DiffPaneRenderer,
};

/// Draw the full diff-surface shell from shared state and normalized
/// page-owned presentation capabilities.
pub fn view(surface: *chasen.Surface, args: ViewArgs) !void {
    switch (args.state.load.state) {
        .loaded => |session| return viewLoadedDiff(surface, args, session.loaded),
        else => {},
    }

    // Without an accepted load there is no sidebar owner from which search
    // candidates may borrow paths. Keep the prompt usable, but render the
    // explicit unavailable terminal instead of leaving the old page body
    // visible behind a footer-only input.
    if (args.state.file_search.mode) {
        try drawFileSearch(surface, args.state.file_search, args.palette);
        return;
    }

    switch (args.state.load.state) {
        .empty => |reason| if (reason == .no_changes) return viewNoChanges(surface, args),
        else => {},
    }

    const size = surface.size();
    const title = "GitFrame";
    const subtitle = "Read-only diff viewer shell";

    var panel = surface.child(.{
        .col = if (size.width > 60) (size.width - 60) / 2 else 0,
        .row = if (size.height > 10) (size.height - 10) / 2 else 0,
        .width = @min(size.width, 60),
        .height = if (size.height > 10) 10 else size.height,
    });
    var col = panel.column(.{ .gap = 1 });
    col.borrowText(title, args.palette.boldStyle(.accent));
    col.borrowText(subtitle, args.palette.style(.muted));
    try col.print("Source: {s}", .{args.source_label});
    viewLoadState(args.state.load, &col, args.palette);
}

fn viewNoChanges(surface: *chasen.Surface, args: ViewArgs) !void {
    const message = args.empty_message orelse noChangesMessage(surface.frameAllocator(), args.no_changes_actions);
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (args.state.viewer.sidebar_hidden) {
        drawStateMessage(surface, message, args.palette);
        return;
    }

    const sidebar_width = layout.sidebarWidth(size.width, args.state.viewer.sidebar_width);
    var sidebar = surface.child(.{
        .col = 0,
        .row = 0,
        .width = sidebar_width,
        .height = size.height,
    });
    try viewEmptySidebarChrome(&sidebar, args);
    drawSidebarSeparator(surface, sidebar_width, args.palette);

    if (size.width <= sidebar_width + 1) return;
    var diff_pane = surface.child(.{
        .col = sidebar_width + 1,
        .row = 0,
        .width = size.width - sidebar_width - 1,
        .height = size.height,
    });
    drawStateMessage(&diff_pane, message, args.palette);
}

fn viewEmptySidebarChrome(surface: *chasen.Surface, args: ViewArgs) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    try drawSidebarDetailRow(surface, 0, args.state, args.palette, args.branch);
    try drawEmptySidebarTitle(surface, args.palette);
}

fn viewLoadedDiff(surface: *chasen.Surface, args: ViewArgs, loaded: loaded_diff.LoadedDiff) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (args.state.viewer.sidebar_hidden) {
        if (args.state.file_search.mode) {
            try drawFileSearch(surface, args.state.file_search, args.palette);
            return;
        }
        if (loaded.visibleNodeCount() == 0) {
            drawStateMessage(surface, filterEmptyMessage(args.state.review_display.*), args.palette);
            return;
        }
        try args.diff_pane.render(surface, loaded);
        return;
    }

    const sidebar_width = layout.sidebarWidth(size.width, args.state.viewer.sidebar_width);
    const search_pane_width = size.width -| (sidebar_width +| 1);
    if (args.state.file_search.mode and search_pane_width < file_search_min_pane_width) {
        try drawFileSearch(surface, args.state.file_search, args.palette);
        return;
    }
    var sidebar = surface.child(.{
        .col = 0,
        .row = 0,
        .width = sidebar_width,
        .height = size.height,
    });
    try viewSidebar(&sidebar, args.state, loaded, args.palette, args.branch);
    drawSidebarSeparator(surface, sidebar_width, args.palette);

    if (size.width <= sidebar_width + 1) return;
    var diff_pane = surface.child(.{
        .col = sidebar_width + 1,
        .row = 0,
        .width = size.width - sidebar_width - 1,
        .height = size.height,
    });
    if (args.state.file_search.mode) {
        try drawFileSearch(&diff_pane, args.state.file_search, args.palette);
        return;
    }
    if (loaded.visibleNodeCount() == 0) {
        drawStateMessage(&diff_pane, filterEmptyMessage(args.state.review_display.*), args.palette);
        return;
    }
    try args.diff_pane.render(&diff_pane, loaded);
}

fn drawSidebarSeparator(surface: *chasen.Surface, sidebar_width: u16, palette: theme.Palette) void {
    const size = surface.size();
    if (size.width <= sidebar_width) return;
    var row: u16 = 0;
    while (row < size.height) : (row += 1) {
        _ = surface.borrowTextAt(sidebar_width, row, "│", shellSeparatorStyle(palette));
    }
}

fn shellSeparatorStyle(_: theme.Palette) chasen.TextStyle {
    return .{ .dim = true };
}

/// Synchronous page renderer for Review-only status rows. Compare passes null;
/// the shared pane owns primary and resolver-projected diff bodies.
pub const StatusOnlyRenderer = struct {
    ctx: *anyopaque,
    render_fn: *const fn (ctx: *anyopaque, surface: *chasen.Surface) anyerror!void,

    pub fn render(self: StatusOnlyRenderer, surface: *chasen.Surface) !void {
        return self.render_fn(self.ctx, surface);
    }
};

/// Draw the selected shared diff body, delegating resolver-projected content
/// and an optional page-only status row through synchronous capabilities.
pub fn viewDiffPane(
    surface: *chasen.Surface,
    body: diff_surface.navigation.BodyView,
    loaded: loaded_diff.LoadedDiff,
    palette: theme.Palette,
    status_only: ?StatusOnlyRenderer,
) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    if (status_only) |renderer| {
        try renderer.render(surface);
        return;
    }

    if (loaded.document.files.len == 0) {
        _ = surface.borrowTextAt(0, 0, "No parsed files.", palette.style(.muted));
        return;
    }

    const state = body.view.surface;
    var diff_content = diffContentSurface(surface);
    const active = state.viewer.sidebar_hidden or state.viewer.focus == .diff;
    switch (body.resolvedTarget().kind) {
        .none => return,
        .inert => {
            try body.renderProjectedBody(projectedBodyRenderArgs(&diff_content, body, palette, active));
            drawPaneHeaderRule(surface, active, palette);
            return;
        },
        .projected => try body.renderProjectedBody(projectedBodyRenderArgs(&diff_content, body, palette, active)),
        .primary => {
            const file_index = body.view.selectedFileIndex(&loaded) orelse return;
            const file = loaded.document.files[file_index];
            const mode = diff_render.effectiveMode(diff_render.bodyWidth(diff_content.size().width), state.viewer.display_mode);
            try diff_render.renderFile(&diff_content, file, .{
                .requested_mode = state.viewer.display_mode,
                .scroll = body.renderDiffScroll(),
                .horizontal_scroll = state.viewer.diff_horizontal_scroll,
                .pane_active = active,
                .line_numbers = state.viewer.view_options.line_numbers,
                .highlighted_hunk = body.selectedHunkIndex(),
                .cursor_offset = body.renderDiffCursorOffset(),
                .hunk_stages = try body.hunkStagePresentation(surface.frameAllocator(), file_index),
                .line_index = loaded.cachedRenderedLineIndex(file_index, mode),
                .folded_hunks = loaded.foldedHunksForFile(file_index),
                .palette = palette,
                .syntax = .initDirect(&loaded.syntax_spans, file_index),
                .selection = body.diffSelectionView(),
                .header_selection = body.diffHeaderSelectionActive(),
            });
        },
    }
    if (body.selectionActionRenderBlock()) |block| {
        try diff_render.composeSelectionAction(
            &diff_content,
            block,
            state.viewer.diff_scroll,
            body.renderDiffScroll(),
            state.viewer.display_mode,
            active,
            palette,
        );
    }
    drawDiffHeaderDetailRow(surface, state, active, palette);
    drawSearchMatchMarkerAt(surface, state, palette, if (state.search.match_offset) |offset| body.sourceToPresentationOffset(offset) else null);
}

/// Shared projected-body presentation for inert/status content. Page adapters
/// provide only the already-resolved path, message, and optional line stats.
pub fn renderStatusBody(
    path: []const u8,
    message: []const u8,
    stats: ?file_tree.Stats,
    args: diff_surface.RenderProjectedBodyArgs,
) !void {
    try drawStatusTitlePath(args.surface, path, stats, args.palette);
    try draw.copyClippedTextAt(args.surface, 0, 2, message, .{
        .fg = args.palette.color(.muted),
        .dim = !args.pane_active,
    });
}

pub fn drawStatusTitlePath(
    surface: *chasen.Surface,
    path: []const u8,
    stats: ?file_tree.Stats,
    palette: theme.Palette,
) !void {
    if (stats) |line_stats| {
        if (line_stats.added != 0 or line_stats.removed != 0) {
            const suffix = try std.fmt.allocPrint(surface.frameAllocator(), " +{d} -{d}", .{ line_stats.added, line_stats.removed });
            const suffix_width = chasen.text.displayWidth(suffix);
            const path_width = surface.size().width -| @as(u16, @intCast(@min(suffix_width, std.math.maxInt(u16))));
            if (path_width > 8) {
                var path_surface = surface.child(.{ .col = 0, .row = 0, .width = path_width, .height = 1 });
                try draw.copyTailClippedTextAt(&path_surface, 0, 0, path, statusPaneTitleStyle(palette));
                try drawStatusLineStats(surface, @intCast(path_width), line_stats, palette);
                return;
            }
        }
    }
    try draw.copyTailClippedTextAt(surface, 0, 0, path, statusPaneTitleStyle(palette));
}

pub fn statusPaneTitleStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.boldStyle(.accent);
}

fn drawStatusLineStats(surface: *chasen.Surface, col: u16, stats: file_tree.Stats, palette: theme.Palette) !void {
    var cursor = col;
    const metadata_style = palette.style(.muted);
    try draw.copyClippedTextAt(surface, cursor, 0, " ", metadata_style);
    cursor +|= 1;
    const added = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{stats.added});
    try draw.copyClippedTextAt(surface, cursor, 0, added, .{ .fg = palette.color(.success), .bold = true });
    cursor +|= @intCast(chasen.text.displayWidth(added));
    if (cursor < surface.size().width) {
        try draw.copyClippedTextAt(surface, cursor, 0, " ", metadata_style);
        cursor +|= 1;
    }
    const removed = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{stats.removed});
    try draw.copyClippedTextAt(surface, cursor, 0, removed, .{ .fg = palette.color(.danger), .bold = true });
}

fn projectedBodyRenderArgs(surface: *chasen.Surface, body: diff_surface.navigation.BodyView, palette: theme.Palette, active: bool) diff_surface.RenderProjectedBodyArgs {
    const state = body.view.surface;
    return .{
        .surface = surface,
        .requested_mode = state.viewer.display_mode,
        .scroll = body.renderDiffScroll(),
        .horizontal_scroll = state.viewer.diff_horizontal_scroll,
        .pane_active = active,
        .line_numbers = state.viewer.view_options.line_numbers,
        .highlighted_hunk = body.selectedHunkIndex(),
        .cursor_offset = body.renderDiffCursorOffset(),
        .palette = palette,
        .selection = body.diffSelectionView(),
        .header_selection = body.diffHeaderSelectionActive(),
    };
}

test "diff pane evaluates resolver entries only for its selected body terminal" {
    const test_support = @import("../test_support.zig");
    const diff_selection = @import("../../diff/selection.zig");
    const diff_parser = @import("../../diff/parser.zig");
    const diff_view_model = @import("../../diff/view_model.zig");
    const review_state = @import("../../review/state.zig");
    const Fake = struct {
        kind: diff_surface.ReducedBodyKind,
        loaded: *const loaded_diff.LoadedDiff,
        resolved: usize = 0,
        hunk_stage: usize = 0,
        generated: usize = 0,
        displayed_file: usize = 0,
        line_index: usize = 0,
        unexpected: usize = 0,

        fn from(ctx: *anyopaque) *@This() {
            return @ptrCast(@alignCast(ctx));
        }
        fn resolvedTarget(ctx: *anyopaque) diff_surface.ResolvedTarget {
            const self = from(ctx);
            self.resolved += 1;
            return .{
                .kind = self.kind,
                .line_count = 1,
                .hunk_interaction = .unavailable,
                .status_rows = 0,
                .search_unavailable = null,
                .search_unfold_policy = .suppressed,
                .folded_hunks_source = .underlying_load,
            };
        }
        fn hunkStagePresentation(ctx: *anyopaque, _: std.mem.Allocator, _: usize) anyerror!diff_render.HunkStagePresentation {
            const self = from(ctx);
            self.hunk_stage += 1;
            return .all_unstaged;
        }
        fn contentToken(ctx: *anyopaque) ?diff_surface.ContentToken {
            from(ctx).unexpected += 1;
            return null;
        }
        fn renderProjectedBody(ctx: *anyopaque, _: diff_surface.RenderProjectedBodyArgs) anyerror!void {
            from(ctx).unexpected += 1;
        }
        fn parsedSelectionTarget(ctx: *anyopaque, _: ?diff_selection.Identity) ?diff_surface.ParsedSelectionTarget {
            from(ctx).unexpected += 1;
            return null;
        }
        fn displayedDiffFile(ctx: *anyopaque) ?diff_parser.FileDiff {
            const self = from(ctx);
            self.displayed_file += 1;
            return self.loaded.document.files[0];
        }
        fn displayedSearchTarget(ctx: *anyopaque, _: diff_render.DisplayMode) ?diff_surface.SearchTarget {
            from(ctx).unexpected += 1;
            return null;
        }
        fn displayedDiffLineIndex(ctx: *anyopaque, _: diff_render.DisplayMode) ?diff_view_model.RenderedLineIndex {
            const self = from(ctx);
            self.line_index += 1;
            return null;
        }
        fn displayedDiffLineCount(ctx: *anyopaque) usize {
            from(ctx).unexpected += 1;
            return 0;
        }
        fn generatedBody(ctx: *anyopaque) ?diff_surface.GeneratedBody {
            const self = from(ctx);
            self.generated += 1;
            return null;
        }
        fn displayedDiffHeaderTarget(ctx: *anyopaque, _: ?diff_selection.HeaderIdentity) ?diff_surface.DiffHeaderTarget {
            from(ctx).unexpected += 1;
            return null;
        }

        const vtable: diff_surface.BodyResolver.VTable = .{
            .resolvedTarget = resolvedTarget,
            .hunkStagePresentation = hunkStagePresentation,
            .contentToken = contentToken,
            .renderProjectedBody = renderProjectedBody,
            .parsedSelectionTarget = parsedSelectionTarget,
            .displayedDiffFile = displayedDiffFile,
            .displayedSearchTarget = displayedSearchTarget,
            .displayedDiffLineIndex = displayedDiffLineIndex,
            .displayedDiffLineCount = displayedDiffLineCount,
            .generatedBody = generatedBody,
            .displayedDiffHeaderTarget = displayedDiffHeaderTarget,
        };
    };

    const loaded = test_support.loadedDiffOne();
    var activation = diff_surface.authority.Lifecycle.init(.review);
    var status: app_state.StatusMessage = .{};
    var load = test_support.loadState(loaded);
    defer load.clearCurrent(null);
    var viewer: diff_surface.ViewerState = .{};
    var search: diff_surface.DiffSearchState = .{};
    var search_state: file_search.State = .{};
    var search_focus: diff_surface.Focus = .sidebar;
    var revision: u64 = 0;
    var display: app_state.ReviewDisplayState = .{};
    var reviewed: review_state.Store = .{};
    var order: file_tree.StableOrder = .{};
    var order_scope: ?[]u8 = null;
    var selection_owner: diff_selection.Owner = .none;
    var completed: ?diff_surface.selection.CompletedSelection = null;
    var source_revision: u64 = 0;
    var pending_initial_selection = false;
    var selection_layout_revision: u64 = 1;
    const state: diff_surface.ReadSurface = .{
        .activation = &activation,
        .status = &status,
        .load = &load,
        .viewer = &viewer,
        .search = &search,
        .file_search = &search_state,
        .file_search_return_focus = &search_focus,
        .accepted_sidebar_revision = &revision,
        .review_display = &display,
        .reviewed_store = &reviewed,
        .tree_order = &order,
        .tree_order_scope = &order_scope,
        .selection_owner = &selection_owner,
        .completed_selection = &completed,
        .source_session_revision = &source_revision,
        .pending_initial_first_visible_selection = &pending_initial_selection,
        .reload_anchor = null,
        .live_drag_deferred_source = false,
        .selection_completion_policy = .copy_on_release,
        .selection_layout_revision = &selection_layout_revision,
        .source = .unstaged,
        .layout = .{ .width = 80, .height = 10 },
    };
    var fake: Fake = .{ .kind = .none, .loaded = &loaded };
    const body: diff_surface.navigation.BodyView = .{
        .view = .{ .surface = state, .repo_root = null },
        .resolver = .{ .ctx = &fake, .vtable = &Fake.vtable },
    };
    var ts: chasen.testing.TestSurface = undefined;
    try ts.init(80, 10);
    defer ts.deinit();

    try viewDiffPane(&ts.surface, body, loaded, .default(), null);
    try std.testing.expectEqual(@as(usize, 1), fake.resolved);
    try std.testing.expectEqual(@as(usize, 0), fake.hunk_stage + fake.generated + fake.displayed_file + fake.line_index + fake.unexpected);

    fake = .{ .kind = .primary, .loaded = &loaded };
    try viewDiffPane(&ts.surface, body, loaded, .default(), null);
    try std.testing.expectEqual(@as(usize, 3), fake.resolved);
    try std.testing.expectEqual(@as(usize, 1), fake.hunk_stage);
    try std.testing.expectEqual(@as(usize, 1), fake.generated);
    try std.testing.expectEqual(@as(usize, 1), fake.displayed_file);
    try std.testing.expectEqual(@as(usize, 1), fake.line_index);
    try std.testing.expectEqual(@as(usize, 0), fake.unexpected);
}

fn drawDiffHeaderDetailRow(surface: *chasen.Surface, state: diff_surface.ReadSurface, active: bool, palette: theme.Palette) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    surface.clear(.{ .col = 0, .row = 1, .width = size.width, .height = 1 });
    if (!state.search.mode and state.search.query.len > 0) {
        const label_col: u16 = 1;
        const match_text = if (state.search.match_offset) |offset|
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} @ {d}", .{ state.search.query.slice(), offset + 1 }) catch "search"
        else
            std.fmt.allocPrint(surface.frameAllocator(), "search: {s} (no match)", .{state.search.query.slice()}) catch "search";
        draw.copyClippedTextAt(surface, label_col, 1, match_text, paneSearchStyle(active, palette)) catch {};
        return;
    }

    if (state.search.mode) {
        const label = "search: ";
        const label_col: u16 = 1;
        const style = paneSearchStyle(active, palette);
        draw.copyClippedTextAt(surface, label_col, 1, label, style) catch {};
        if (size.width > label_col + label.len) {
            const input_col: u16 = label_col + @as(u16, @intCast(label.len));
            drawInputLine(surface, input_col, 1, state.search.input.slice(), state.search.input.cursor, style) catch {};
            view_primitives.showInputCursor(surface, input_col, 1, state.search.input.slice(), state.search.input.cursor);
        }
        return;
    }

    drawPaneHeaderRule(surface, active, palette);
}

pub fn drawInputLine(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, cursor: usize, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width or row >= size.height) return;
    const width = size.width - col;
    try draw.copyClippedTextAt(surface, col, row, text[view_primitives.inputVisibleStart(text, cursor, width)..], style);
}

pub fn drawPaneHeaderRule(surface: *chasen.Surface, active: bool, palette: theme.Palette) void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 1) return;

    for (0..size.width) |col| {
        _ = surface.borrowTextAt(@intCast(col), 1, "─", paneHeaderRuleStyle(active, palette));
    }
}

pub fn drawSearchMatchMarker(surface: *chasen.Surface, state: diff_surface.ReadSurface, palette: theme.Palette) void {
    drawSearchMatchMarkerAt(surface, state, palette, state.search.match_offset);
}

fn drawSearchMatchMarkerAt(surface: *chasen.Surface, state: diff_surface.ReadSurface, palette: theme.Palette, match_offset_opt: ?usize) void {
    const match_offset = match_offset_opt orelse return;
    if (match_offset < state.viewer.diff_scroll) return;

    const visible_offset = match_offset - state.viewer.diff_scroll;
    const body_rows = diff_render.visibleBodyRows(surface.size().height);
    if (visible_offset >= body_rows) return;

    const row: u16 = @intCast(layout.diff_body_start_row + visible_offset);
    _ = surface.borrowTextAt(0, row, "»", .{ .bold = true, .reverse = true, .fg = palette.color(.prompt) });
}

pub fn diffContentSurface(surface: *chasen.Surface) chasen.Surface {
    const size = surface.size();
    if (size.width <= layout.search_marker_gutter_width) {
        return surface.child(.{ .col = 0, .row = 0, .width = size.width, .height = size.height });
    }
    return surface.child(.{
        .col = layout.search_marker_gutter_width,
        .row = 0,
        .width = size.width - layout.search_marker_gutter_width,
        .height = size.height,
    });
}

pub fn paneSearchStyle(active: bool, palette: theme.Palette) chasen.TextStyle {
    return if (active)
        palette.boldStyle(.prompt)
    else
        palette.style(.prompt);
}

pub fn paneHeaderRuleStyle(_: bool, _: theme.Palette) chasen.TextStyle {
    return .{ .dim = true };
}

/// Draw a bounded file-search projection in the diff-pane position.
pub fn drawFileSearch(surface: *chasen.Surface, state: *const file_search.State, palette: theme.Palette) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    const label_col: u16 = 1;
    const prompt_style = palette.boldStyle(.prompt);
    draw.copyClippedTextAt(surface, label_col, 0, file_search_label, prompt_style) catch {};
    const label_width = chasen.text.displayWidth(file_search_label);
    if (size.width > label_col + label_width) {
        const input_col = label_col + label_width;
        try drawFileSearchInput(surface, input_col, 0, state.input.slice(), state.input.cursor, prompt_style);
        view_primitives.showInputCursor(surface, input_col, 0, state.input.slice(), state.input.cursor);
    }

    if (size.height > 1) {
        const status = if (state.truncated)
            "512+ matches; refine search"
        else if (!state.projection_available)
            "File list unavailable; wait or press Esc"
        else if (state.no_match)
            "No matching files"
        else
            "Enter: open  Esc: cancel";
        const role: theme.Role = if (state.no_match or !state.projection_available) .warning else .muted;
        draw.copyClippedTextAt(surface, 1, 1, status, palette.style(role)) catch {};
    }

    if (!state.projection_available) return;
    const visible_rows: usize = size.height -| 2;
    const focused = state.filter.list.focusedIndex();
    const range = ui.ListViewport.visibleRange(state.filter.labels.len, focused, visible_rows);
    var result_index = range.start;
    while (result_index < range.end) : (result_index += 1) {
        const candidate = state.candidateAt(result_index) orelse continue;

        const row: u16 = @intCast(2 + result_index - range.start);
        const style = if (result_index == focused) palette.boldStyle(.prompt) else palette.style(.muted);
        try draw.copyTailClippedTextAt(surface, 1, row, candidate.path_key, style);
    }
}

pub const file_search_label = "Find file: ";
// Keep enough room for the fixed label and a short visible input tail. Below
// this width the sidebar is less useful than the active prompt, so search uses
// the full body until normal pane geometry becomes usable again.
pub const file_search_min_pane_width: u16 = 1 + file_search_label.len + 4;

fn drawFileSearchInput(surface: *chasen.Surface, col: u16, row: u16, text: []const u8, cursor: usize, style: chasen.TextStyle) !void {
    const size = surface.size();
    if (col >= size.width or row >= size.height) return;
    const width = size.width - col;
    try draw.copyClippedTextAt(surface, col, row, text[view_primitives.inputVisibleStart(text, cursor, width)..], style);
}

pub fn drawEmptySidebarTitle(surface: *chasen.Surface, palette: theme.Palette) !void {
    const size = surface.size();
    if (size.width == 0 or size.height <= 2) return;

    const title = " Files";
    _ = surface.borrowTextAt(0, 2, title, palette.boldStyle(.accent));
    const stats_col = chasen.text.displayWidth(title) + 1;
    if (stats_col < size.width) {
        _ = try surface.printAt(stats_col, 2, palette.style(.muted), "0 files / 0 hunks", .{});
    }
}

/// Fully normalized page-owned branch chrome. The shared renderer owns only
/// placement and style; pages remain responsible for branch status, action
/// reachability, effective key labels, clipping, and hint composition.
pub const SidebarBranchPresentation = struct {
    text: []const u8,
    hint: ?Hint = null,

    pub const Hint = struct {
        text: []const u8,
        col: u16,
    };
};

/// Whether the detail row can show page-owned branch presentation. Filter
/// chrome has precedence and is rendered entirely from shared surface state.
pub fn sidebarDetailNeedsBranch(display: *const app_state.ReviewDisplayState) bool {
    return !display.hide_reviewed_files and display.changed_file_filter == .all;
}

/// Draw the loaded file sidebar from shared state plus normalized page chrome.
pub fn viewSidebar(
    surface: *chasen.Surface,
    state: diff_surface.ReadSurface,
    loaded: loaded_diff.LoadedDiff,
    palette: theme.Palette,
    branch: ?SidebarBranchPresentation,
) !void {
    const size = surface.size();
    if (size.width == 0 or size.height == 0) return;

    try drawSidebarDetailRow(surface, 0, state, palette, branch);

    if (size.height <= 2) return;
    const title = " Files";
    _ = surface.borrowTextAt(0, 2, title, palette.boldStyle(.accent));
    const title_width = chasen.text.displayWidth(title);
    const stats_col = title_width + 1;
    if (stats_col < size.width) {
        _ = try surface.printAt(stats_col, 2, palette.style(.muted), "{d} files / {d} hunks", .{
            loaded.document.files.len,
            loaded.document.totalHunks(),
        });
    }

    if (size.height <= layout.sidebar_header_rows) return;

    const visible_rows: usize = size.height - layout.sidebar_header_rows;
    // Sidebar has no independent scroll state; derive the visible window
    // from the selected row each frame.
    const range = loaded.sidebarVisibleRange(state.viewer.selected_node, visible_rows);
    var row: u16 = layout.sidebar_header_rows;
    var visible_index: usize = range.start;
    while (visible_index < range.end) : ({
        visible_index += 1;
        row += 1;
    }) {
        const row_model = sidebar_view_model.rowAt(.{
            .tree = loaded.tree,
            .collapsed = &loaded.collapsed_dirs,
            .reviewed_files = loaded.reviewed_files,
            .visible_nodes = loaded.materializedVisibleNodes(),
        }, visible_index, state.viewer.selected_node) orelse continue;
        const cursor_active = state.viewer.focus == .sidebar and !state.file_search.mode;
        try drawSidebarRow(surface, row, row_model, cursor_active, state.viewer.sidebar_horizontal_scroll, palette);
    }
}

pub fn drawSidebarDetailRow(
    surface: *chasen.Surface,
    row: u16,
    state: diff_surface.ReadSurface,
    palette: theme.Palette,
    branch: ?SidebarBranchPresentation,
) !void {
    const size = surface.size();
    if (size.width <= 2 or row >= size.height) return;

    if (state.review_display.hide_reviewed_files and state.review_display.changed_file_filter != .all) {
        const text = try std.fmt.allocPrint(surface.frameAllocator(), "hiding reviewed / {s}", .{state.review_display.changed_file_filter.label()});
        try draw.copyClippedTextAt(surface, 1, row, text, palette.style(.prompt));
        return;
    }
    if (state.review_display.hide_reviewed_files) {
        try draw.copyClippedTextAt(surface, 1, row, "hiding reviewed", palette.style(.prompt));
        return;
    }
    if (state.review_display.changed_file_filter != .all) {
        try draw.copyClippedTextAt(surface, 1, row, state.review_display.changed_file_filter.label(), palette.style(.prompt));
        return;
    }

    if (branch) |presentation| {
        try draw.copyClippedTextAt(surface, 1, row, presentation.text, palette.style(.info));
        if (presentation.hint) |hint| {
            try draw.copyClippedTextAt(surface, hint.col, row, hint.text, sidebarBranchHintStyle(palette));
        }
    }
}

pub fn drawSidebarRow(surface: *chasen.Surface, row: u16, row_model: sidebar_view_model.Row, cursor_active: bool, horizontal_scroll: usize, palette: theme.Palette) !void {
    const width = surface.size().width;
    const row_layout = sidebar_view_model.layout(row_model, width);
    const cursor_bg: ?chasen.Color = if (cursor_active and row_model.selected) palette.color(.pane_cursor_bg) else null;
    const style = withCursorBackground(sidebarRowStyle(row_model, palette), cursor_bg);

    // Cursor chrome is a row-level concern, separate from path/badge Git
    // semantics. Fill first so trailing cells share the same signal, then
    // compose the same background into every semantic cell written below.
    if (cursor_bg != null) fillSidebarCursorRow(surface, row, style);

    if (row_model.status) |status| {
        if (row_layout.badge_col) |badge_col| {
            if (width > badge_col) {
                _ = surface.borrowTextAt(badge_col, row, status.badge(), statusStyle(row_model, status, palette, cursor_bg));
            }
        }
    }

    if (row_layout.mode_col) |mode_col| {
        if (width > mode_col) {
            _ = surface.borrowTextAt(mode_col, row, "m", modeBadgeStyle(palette, cursor_bg));
        }
    }

    if (row_layout.reviewed_col) |reviewed_col| {
        if (width > reviewed_col) {
            _ = surface.borrowTextAt(reviewed_col, row, "✓", reviewedStyle(palette, cursor_bg));
        }
    }

    if (row_layout.tree_content_width > 0) {
        var path_area = surface.child(.{
            .col = row_layout.tree_content_col,
            .row = row,
            .width = row_layout.tree_content_width,
            .height = 1,
        });
        const content = try sidebarTreeContent(surface.frameAllocator(), row_model);
        const effective_scroll = @min(horizontal_scroll, sidebar_view_model.maxHorizontalScroll(row_model, width));
        const visible = chasen.text.dropToWidth(content, view_primitives.scrollCells(effective_scroll));
        try draw.copyClippedTextAt(&path_area, 0, 0, visible, style);
    }

    if (row_layout.stats_col) |stats_col| {
        var stats_area = surface.child(.{
            .col = stats_col,
            .row = row,
            .width = row_layout.stats_width,
            .height = 1,
        });
        try drawSidebarStats(&stats_area, row_model, palette, cursor_bg);
    }
}

fn fillSidebarCursorRow(surface: *chasen.Surface, row: u16, style: chasen.TextStyle) void {
    for (0..surface.size().width) |col| {
        _ = surface.borrowTextAt(@intCast(col), row, " ", style);
    }
}

fn drawSidebarStats(surface: *chasen.Surface, row: sidebar_view_model.Row, palette: theme.Palette, cursor_bg: ?chasen.Color) !void {
    const added_text = try std.fmt.allocPrint(surface.frameAllocator(), "+{d}", .{row.stats.added});
    const removed_text = try std.fmt.allocPrint(surface.frameAllocator(), "-{d}", .{row.stats.removed});
    const added_style = sidebarStatStyle(palette.color(.success), cursor_bg);
    const removed_style = sidebarStatStyle(palette.color(.danger), cursor_bg);

    try draw.copyClippedTextAt(surface, 0, 0, added_text, added_style);
    const removed_col = chasen.text.displayWidth(added_text) + 1;
    if (removed_col < surface.size().width) {
        try draw.copyClippedTextAt(surface, removed_col, 0, removed_text, removed_style);
    }
}

fn sidebarStatStyle(fg: chasen.Color, cursor_bg: ?chasen.Color) chasen.TextStyle {
    return withCursorBackground(.{
        .fg = fg,
        .bold = true,
    }, cursor_bg);
}

fn sidebarTreeContent(allocator: std.mem.Allocator, row: sidebar_view_model.Row) ![]const u8 {
    const indent = @as(usize, row.depth) * 2;
    const fold_marker = switch (row.fold) {
        .none => "",
        .expanded => "▾ ",
        .collapsed => "▸ ",
    };
    const len = indent + fold_marker.len + row.name.len;
    const buf = try allocator.alloc(u8, len);
    @memset(buf[0..indent], ' ');
    @memcpy(buf[indent..][0..fold_marker.len], fold_marker);
    @memcpy(buf[indent + fold_marker.len ..][0..row.name.len], row.name);
    return buf;
}

pub fn sidebarRowStyle(row: sidebar_view_model.Row, palette: theme.Palette) chasen.TextStyle {
    var style: chasen.TextStyle = if (row.kind == .directory or row.kind == .repo_root)
        palette.boldStyle(.accent)
    else switch (row.stage_presence) {
        .staged_only => .{ .fg = palette.color(.staged) },
        .mixed => .{ .fg = palette.color(.prompt) },
        .conflict => .{ .fg = palette.color(.danger), .bold = true },
        else => .{},
    };
    if (row.selected) style.bold = true;
    return style;
}

pub fn withCursorBackground(style: chasen.TextStyle, cursor_bg: ?chasen.Color) chasen.TextStyle {
    var composed = style;
    if (cursor_bg) |background| composed.bg = background;
    return composed;
}

pub fn statusStyle(row: sidebar_view_model.Row, status: file_tree.Status, palette: theme.Palette, cursor_bg: ?chasen.Color) chasen.TextStyle {
    const fg: chasen.Color = switch (row.stage_presence) {
        .staged_only => palette.color(.staged),
        .mixed => palette.color(.prompt),
        .conflict => palette.color(.danger),
        else => switch (status) {
            .modified => palette.color(.prompt),
            .added => palette.color(.success),
            .deleted => palette.color(.danger),
            .renamed => palette.color(.accent),
            .binary => palette.color(.binary),
        },
    };
    return withCursorBackground(.{ .fg = fg, .bold = true }, cursor_bg);
}

fn reviewedStyle(palette: theme.Palette, cursor_bg: ?chasen.Color) chasen.TextStyle {
    return withCursorBackground(.{ .fg = palette.color(.success), .bold = true }, cursor_bg);
}

fn modeBadgeStyle(palette: theme.Palette, cursor_bg: ?chasen.Color) chasen.TextStyle {
    return withCursorBackground(.{ .fg = palette.color(.info), .bold = true }, cursor_bg);
}

fn sidebarBranchHintStyle(palette: theme.Palette) chasen.TextStyle {
    return palette.style(.muted);
}
