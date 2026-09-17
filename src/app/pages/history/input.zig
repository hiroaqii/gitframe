//! Pure History input mapping for the commit picker and the shared committed
//! diff surface.

const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../../key_input.zig");
const committed_diff_input = @import("../committed_diff/input.zig");

pub const Context = struct {
    loading: bool = false,
    diff_view: bool = false,
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
    common: committed_diff_input.Msg,
    owned_noop,
};

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
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
    if (context.picker_ready) {
        if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return .move_previous;
        if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return .move_next;
        if (key.matches(chasen.Key.page_up, .{}) or matches(context.keymap, .page_up, key)) return .page_up;
        if (key.matches(chasen.Key.page_down, .{}) or matches(context.keymap, .page_down, key)) return .page_down;
        if (key.matches(chasen.Key.home, .{}) or matches(context.keymap, .document_first, key)) return .first;
        if (key.matches(chasen.Key.end, .{}) or matches(context.keymap, .document_last, key)) return .last;
    }
    if (key.matches(chasen.Key.enter, .{})) {
        if (context.more_row_selected) return .load_older;
        if (context.picker_ready) return .load_diff;
    }
    if (context.picker_ready and !key_input.hasCommandModifier(key)) {
        if (key.codepoint == ' ') return .toggle_range;
        if (key.codepoint == '/') return .unsupported_search;
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
