//! Pure History input mapping for the commit picker and the shared committed
//! diff surface.

const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../../key_input.zig");
const committed_diff_input = @import("../committed_diff/input.zig");
const interaction = @import("interaction.zig");

pub const Context = struct {
    loading: bool = false,
    diff_view: bool = false,
    focus: interaction.Focus = .history,
    more_row_selected: bool = false,
    picker_ready: bool = false,
    picker_can_move_previous: bool = false,
    picker_can_move_next: bool = false,
    return_to_accepted: bool = false,
    common: committed_diff_input.Context = .{},
    keymap: keymap.Effective = .{},
};

pub const Msg = union(enum) {
    move_previous,
    move_next,
    page_up,
    page_down,
    first,
    last,
    load_older,
    cancel_load,
    toggle_range,
    cancel_draft,
    unsupported_search,
    load_diff,
    open_picker,
    focus_next,
    focus_previous,
    focus_pane: interaction.Focus,
    move_detail: interaction.VerticalAction,
    move_files: interaction.VerticalAction,
    scroll_files: interaction.HorizontalAction,
    adjust_width: interaction.WidthAction,
    copy_detail,
    common: committed_diff_input.Msg,
    owned_noop,
};

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (!context.diff_view) {
        if (key.matches(chasen.Key.tab, .{ .shift = true })) return .focus_previous;
        if (key.matches(chasen.Key.tab, .{})) return .focus_next;
        if (context.keymap.actionForKey(key)) |action| switch (action) {
            .decrease_sidebar_width => return .{ .adjust_width = .decrease },
            .increase_sidebar_width => return .{ .adjust_width = .increase },
            else => {},
        };
    }
    if (context.loading) {
        if (key.matches(chasen.Key.escape, .{})) return .cancel_load;
        return .owned_noop;
    }
    if (context.diff_view) {
        if (!context.common.search_mode and !context.common.file_search_mode) {
            if (context.common.keymap.actionForKey(key)) |action| switch (action) {
                .mark_reviewed, .hide_reviewed => return .owned_noop,
                else => {},
            };
        }
        if (!context.common.search_mode and !context.common.file_search_mode and
            !key_input.hasCommandModifier(key) and key.codepoint == 'm') return .open_picker;
        return .{ .common = committed_diff_input.keyToMsg(context.common, key) orelse return null };
    }
    if (matches(context.keymap, .copy_history_detail, key)) {
        return if (context.focus == .commit_detail) .copy_detail else .owned_noop;
    }
    if (key.matches(chasen.Key.enter, .{})) {
        if (context.more_row_selected) return .load_older;
        if (context.picker_ready) return .load_diff;
    }

    if (verticalAction(context.keymap, key)) |action| switch (context.focus) {
        .history => if (context.picker_ready) return historyMove(action),
        .commit_detail => return .{ .move_detail = action },
        .changed_files => return .{ .move_files = action },
    };
    if (context.focus == .changed_files and !key_input.hasCommandModifier(key)) {
        if (key.matches(chasen.Key.left, .{}) or key.codepoint == 'h') return .{ .scroll_files = .left };
        if (key.matches(chasen.Key.right, .{}) or key.codepoint == 'l') return .{ .scroll_files = .right };
    }
    if (!key_input.hasCommandModifier(key) and key.codepoint == ' ') {
        if (context.focus != .history) return .owned_noop;
        if (context.picker_ready) return .toggle_range;
    }
    if (context.focus == .history and context.picker_ready and
        !key_input.hasCommandModifier(key) and key.codepoint == '/')
    {
        return .unsupported_search;
    }
    if ((context.picker_ready or context.return_to_accepted) and
        key.matches(chasen.Key.escape, .{})) return .cancel_draft;
    return null;
}

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (!context.diff_view) return .owned_noop;
    return .{ .common = committed_diff_input.pasteToMsg(context.common, text) orelse return null };
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (!context.diff_view or context.loading) return null;
    return .{ .common = committed_diff_input.selectionKeyToMsg(context.common, key) orelse return null };
}

fn verticalAction(effective: keymap.Effective, key: chasen.Key) ?interaction.VerticalAction {
    if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return .row_previous;
    if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return .row_next;
    if (key.matches(chasen.Key.page_up, .{}) or matches(effective, .page_up, key)) return .page_previous;
    if (key.matches(chasen.Key.page_down, .{}) or matches(effective, .page_down, key)) return .page_next;
    if (key.matches(chasen.Key.home, .{}) or matches(effective, .document_first, key)) return .first;
    if (key.matches(chasen.Key.end, .{}) or matches(effective, .document_last, key)) return .last;
    return null;
}

fn historyMove(action: interaction.VerticalAction) Msg {
    return switch (action) {
        .row_previous => .move_previous,
        .row_next => .move_next,
        .page_previous => .page_up,
        .page_next => .page_down,
        .first => .first,
        .last => .last,
    };
}

fn matches(effective: keymap.Effective, action: keymap.PublicAction, key: chasen.Key) bool {
    const spec = effective.spec(action) orelse return false;
    return spec.matches(key);
}

test "History loading owns Escape and keeps editing input inert" {
    try @import("std").testing.expectEqual(Msg.cancel_load, keyToMsg(.{ .loading = true }, .{ .codepoint = chasen.Key.escape }).?);
    try @import("std").testing.expectEqual(Msg.owned_noop, keyToMsg(.{ .loading = true }, .{ .codepoint = 'j' }).?);
    try @import("std").testing.expectEqual(Msg.owned_noop, pasteToMsg(.{}, "selection").?);
}

test "History Enter loads the visible operation or one picker selection" {
    try @import("std").testing.expect(keyToMsg(.{}, .{ .codepoint = chasen.Key.enter }) == null);
    try @import("std").testing.expectEqual(Msg.load_older, keyToMsg(.{ .more_row_selected = true }, .{ .codepoint = chasen.Key.enter }).?);
    try @import("std").testing.expectEqual(Msg.load_diff, keyToMsg(.{ .picker_ready = true }, .{ .codepoint = chasen.Key.enter }).?);
}

test "History picker owns range cancel and unsupported search" {
    const ready: Context = .{ .picker_ready = true };
    try @import("std").testing.expectEqual(Msg.toggle_range, keyToMsg(ready, .{ .codepoint = ' ' }).?);
    try @import("std").testing.expectEqual(Msg.cancel_draft, keyToMsg(ready, .{ .codepoint = chasen.Key.escape }).?);
    try @import("std").testing.expectEqual(Msg.unsupported_search, keyToMsg(ready, .{ .codepoint = '/' }).?);
    try @import("std").testing.expectEqual(Msg.load_diff, keyToMsg(ready, .{ .codepoint = chasen.Key.enter }).?);
    try @import("std").testing.expectEqual(
        Msg.cancel_draft,
        keyToMsg(.{ .return_to_accepted = true }, .{ .codepoint = chasen.Key.escape }).?,
    );
}

test "History three pane input cycles focus and routes focused navigation" {
    const ready: Context = .{ .picker_ready = true };
    try @import("std").testing.expectEqual(Msg.focus_next, keyToMsg(ready, .{ .codepoint = chasen.Key.tab }).?);
    try @import("std").testing.expectEqual(
        Msg.focus_previous,
        keyToMsg(ready, .{ .codepoint = chasen.Key.tab, .mods = .{ .shift = true } }).?,
    );
    try @import("std").testing.expectEqual(Msg.move_next, keyToMsg(ready, .{ .codepoint = 'j' }).?);
    try @import("std").testing.expectEqual(
        Msg{ .move_detail = .page_next },
        keyToMsg(.{ .picker_ready = true, .focus = .commit_detail }, .{ .codepoint = chasen.Key.page_down }).?,
    );
    const files: Context = .{ .picker_ready = true, .focus = .changed_files };
    try @import("std").testing.expectEqual(Msg{ .move_files = .last }, keyToMsg(files, .{ .codepoint = chasen.Key.end }).?);
    try @import("std").testing.expectEqual(Msg{ .scroll_files = .right }, keyToMsg(files, .{ .codepoint = 'l' }).?);
    try @import("std").testing.expectEqual(Msg.owned_noop, keyToMsg(files, .{ .codepoint = ' ' }).?);
    try @import("std").testing.expectEqual(Msg.owned_noop, keyToMsg(files, .{ .codepoint = 'y' }).?);
    try @import("std").testing.expectEqual(
        Msg.copy_detail,
        keyToMsg(.{ .picker_ready = true, .focus = .commit_detail }, .{ .codepoint = 'y' }).?,
    );
    try @import("std").testing.expectEqual(Msg.load_diff, keyToMsg(files, .{ .codepoint = chasen.Key.enter }).?);
    try @import("std").testing.expect(keyToMsg(ready, .{ .codepoint = 'i' }) == null);

    var config: keymap.Config = .{};
    config.set(.increase_sidebar_width, .{ .plain_codepoint = 'z' });
    config.set(.copy_history_detail, .{ .plain_codepoint = 'x' });
    const effective = keymap.Effective.fromConfig(config);
    try @import("std").testing.expectEqual(
        Msg{ .adjust_width = .increase },
        keyToMsg(.{ .loading = true, .keymap = effective }, .{ .codepoint = 'z' }).?,
    );
    try @import("std").testing.expectEqual(
        Msg.copy_detail,
        keyToMsg(.{ .picker_ready = true, .focus = .commit_detail, .keymap = effective }, .{ .codepoint = 'x' }).?,
    );
}
