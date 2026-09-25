//! Shared presentation and key policy for the branch switch and Compare Base pickers.
//! Each caller retains its list, selection, task ownership, and action routing.

const chasen = @import("chasen");
const ui = @import("chasen_ui");
const draw = @import("draw");
const theme = @import("theme");
const key_input = @import("key_input.zig");

pub const InputAction = union(enum) {
    confirm,
    cancel,
    previous,
    next,
    enter_query,
    leave_query,
    clear_query,
    insert: u21,
    backspace,
};

pub const InputContext = struct {
    query_mode: bool,
    query_len: usize,
};

pub fn keyToAction(context: InputContext, key: chasen.Key) ?InputAction {
    if (key.matches(chasen.Key.escape, .{})) {
        return if (context.query_mode or context.query_len > 0) .clear_query else .cancel;
    }
    if (key.matches(chasen.Key.enter, .{})) return .confirm;
    if (key.matches(chasen.Key.up, .{})) return .previous;
    if (key.matches(chasen.Key.down, .{})) return .next;
    if (context.query_mode) {
        if (key.matches(chasen.Key.tab, .{})) return .leave_query;
        if (key.matches(chasen.Key.backspace, .{})) return .backspace;
        if (key_input.textInputCodepoint(key)) |codepoint| return .{ .insert = codepoint };
        return null;
    }
    if (key.codepoint == '/') return .enter_query;
    if (key.codepoint == 'q') return .cancel;
    if (key.codepoint == 'k') return .previous;
    if (key.codepoint == 'j') return .next;
    return null;
}

/// Includes the blank line above the footer.
pub const footer_rows: u16 = 2;

pub fn viewFrame(surface: *chasen.Surface, palette: theme.Palette, title: []const u8) ?ui.Modal.Frame {
    const frame = ui.Modal.frame(surface, .{
        .dialog_width = @min(surface.size().width, 96),
        .dialog_height = @min(surface.size().height, 22),
        .title = title,
        .backdrop = false,
        .border = .rounded,
        .title_style = palette.boldStyle(.accent),
        .border_style = palette.style(.accent),
    }) orelse return null;
    var dialog = frame.dialogSurface();
    dialog.fillAll(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{} });
    frame.view();
    return frame;
}

pub fn viewFilter(surface: *chasen.Surface, row: u16, palette: theme.Palette, opts: struct {
    query: []const u8,
    query_mode: bool,
    show_cursor: bool = true,
}) !void {
    const size = surface.size();
    if (row >= size.height or size.width == 0) return;
    const prefix = if (opts.query_mode) "Filter branches: /" else "Filter branches: ";
    try draw.copyClippedTextAt(surface, 0, row, prefix, palette.style(.prompt));
    const prefix_width = surface.displayWidth(prefix);
    if (prefix_width < size.width) {
        var query_surface = surface.child(.{ .col = prefix_width, .row = row, .width = size.width - prefix_width, .height = 1 });
        try draw.copyClippedTextAt(&query_surface, 0, 0, opts.query, .{});
    }
    if (opts.query_mode and opts.show_cursor) {
        surface.showCursor(@min(size.width - 1, prefix_width + surface.displayWidth(opts.query)), row);
    }
}

pub fn listWindowStart(selected: usize, len: usize, rows: u16) usize {
    return ui.Viewport.init(.{
        .total = len,
        .height = rows,
        .offset = selected -| (@as(usize, rows) / 2),
    }).clampedOffset();
}
