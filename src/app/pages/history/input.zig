//! Pure History catalog input mapping. Selection and diff input are owned by
//! later slices and deliberately absent here.

const chasen = @import("chasen");
const keymap = @import("keymap");

pub const Context = struct {
    loading: bool = false,
    more_row_selected: bool = false,
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
