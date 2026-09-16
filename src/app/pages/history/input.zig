//! Pure History commit-picker input mapping. Actual diff loading and accepted
//! diff input remain owned by the next slice.

const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../../key_input.zig");

pub const Context = struct {
    loading: bool = false,
    more_row_selected: bool = false,
    picker_ready: bool = false,
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
    owned_noop,
};

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.loading) {
        if (key.matches(chasen.Key.escape, .{})) return .cancel_load;
        return .owned_noop;
    }
    if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return .move_previous;
    if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return .move_next;
    if (key.matches(chasen.Key.page_up, .{}) or matches(context.keymap, .page_up, key)) return .page_up;
    if (key.matches(chasen.Key.page_down, .{}) or matches(context.keymap, .page_down, key)) return .page_down;
    if (key.matches(chasen.Key.home, .{}) or matches(context.keymap, .document_first, key)) return .first;
    if (key.matches(chasen.Key.end, .{}) or matches(context.keymap, .document_last, key)) return .last;
    if (key.matches(chasen.Key.enter, .{}) and context.more_row_selected) return .load_older;
    if (context.picker_ready and !key_input.hasCommandModifier(key)) {
        if (key.codepoint == ' ') return .toggle_range;
        if (key.codepoint == '/') return .unsupported_search;
    }
    if (context.picker_ready and key.matches(chasen.Key.escape, .{})) return .cancel_draft;
    return null;
}

pub fn pasteToMsg(_: Context, _: []const u8) Msg {
    return .owned_noop;
}

fn matches(effective: keymap.Effective, action: keymap.PublicAction, key: chasen.Key) bool {
    const spec = effective.spec(action) orelse return false;
    return spec.matches(key);
}

test "History loading owns Escape and keeps editing input inert" {
    try @import("std").testing.expectEqual(Msg.cancel_load, keyToMsg(.{ .loading = true }, .{ .codepoint = chasen.Key.escape }).?);
    try @import("std").testing.expectEqual(Msg.owned_noop, keyToMsg(.{ .loading = true }, .{ .codepoint = 'j' }).?);
    try @import("std").testing.expectEqual(Msg.owned_noop, pasteToMsg(.{}, "selection"));
}

test "History Enter is reserved for the visible load-more operation" {
    try @import("std").testing.expect(keyToMsg(.{}, .{ .codepoint = chasen.Key.enter }) == null);
    try @import("std").testing.expectEqual(Msg.load_older, keyToMsg(.{ .more_row_selected = true }, .{ .codepoint = chasen.Key.enter }).?);
}

test "History picker owns range cancel and unsupported search without wiring diff Enter" {
    const ready: Context = .{ .picker_ready = true };
    try @import("std").testing.expectEqual(Msg.toggle_range, keyToMsg(ready, .{ .codepoint = ' ' }).?);
    try @import("std").testing.expectEqual(Msg.cancel_draft, keyToMsg(ready, .{ .codepoint = chasen.Key.escape }).?);
    try @import("std").testing.expectEqual(Msg.unsupported_search, keyToMsg(ready, .{ .codepoint = '/' }).?);
    try @import("std").testing.expect(keyToMsg(ready, .{ .codepoint = chasen.Key.enter }) == null);
}
