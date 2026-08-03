//! Page-independent footer and state rendering for a diff surface.
//!
//! Pages inject only presentation values which are outside the shared surface
//! contract (currently the auto-reload capability). This module must not
//! import a page namespace.

const std = @import("std");
const chasen = @import("chasen");
const theme = @import("theme");
const diff_surface = @import("../diff_surface.zig");
const app_load_state = @import("../load_state.zig");
const app_state = @import("../state.zig");
const diff_source = @import("../../diff/source.zig");

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
