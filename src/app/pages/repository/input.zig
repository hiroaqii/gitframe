//! Repository-local keyboard and paste mapping.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../../key_input.zig");
const model = @import("model.zig");

pub const Context = struct {
    focus: model.Focus = .tree,
    source_available: bool = false,
    source_search_mode: bool = false,
    file_search_mode: bool = false,
    source_query_len: usize = 0,
    keymap: keymap.Effective = .{},
};

pub fn pasteToMsg(comptime Msg: type, context: Context, text: []const u8) ?Msg {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    if (context.source_search_mode) return payload(Msg, "source_search_paste", text);
    if (context.file_search_mode) return payload(Msg, "file_search_paste", text);
    return null;
}

pub fn keyToMsg(comptime Msg: type, context: Context, key: chasen.Key) ?Msg {
    if (context.source_search_mode) return sourceSearchKey(Msg, key);
    if (context.file_search_mode) return fileSearchKey(Msg, key);

    if (key.matches(chasen.Key.tab, .{}) and context.source_available) return voidMsg(Msg, "toggle_focus");
    if (key.matches(chasen.Key.escape, .{}) and context.source_query_len > 0) return voidMsg(Msg, "clear_source_search");
    if (context.focus == .tree and (key.matches(chasen.Key.enter, .{}) or key.matches(' ', .{}))) return voidMsg(Msg, "toggle_directory");
    if (key.matches(chasen.Key.home, .{})) {
        return if (context.focus == .source) voidMsg(Msg, "source_first") else voidMsg(Msg, "tree_first");
    }
    if (key.matches(chasen.Key.end, .{})) {
        return if (context.focus == .source) voidMsg(Msg, "source_last") else voidMsg(Msg, "tree_last");
    }
    if (key.matches(chasen.Key.page_up, .{})) return voidMsg(Msg, "page_up");
    if (key.matches(chasen.Key.page_down, .{})) return voidMsg(Msg, "page_down");

    if (context.keymap.actionForKey(key)) |action| switch (action) {
        .search => if (context.source_available) return voidMsg(Msg, "enter_source_search"),
        .file_search => return voidMsg(Msg, "enter_file_search"),
        .toggle_line_numbers => return voidMsg(Msg, "toggle_line_numbers"),
        .first_file => return voidMsg(Msg, "tree_first"),
        .last_file => return voidMsg(Msg, "tree_last"),
        else => {},
    };
    if (key_input.hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'k', chasen.Key.up => voidMsg(Msg, "move_up"),
        'j', chasen.Key.down => voidMsg(Msg, "move_down"),
        'h', chasen.Key.left => voidMsg(Msg, "scroll_left"),
        'l', chasen.Key.right => voidMsg(Msg, "scroll_right"),
        'n' => if (context.source_query_len > 0) voidMsg(Msg, "next_source_match") else null,
        'p' => if (context.source_query_len > 0) voidMsg(Msg, "previous_source_match") else null,
        else => null,
    };
}

fn sourceSearchKey(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_source_search");
    if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_source_search");
    if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "source_search_backspace");
    if (key.matches(chasen.Key.left, .{})) return voidMsg(Msg, "source_search_move_left");
    if (key.matches(chasen.Key.right, .{})) return voidMsg(Msg, "source_search_move_right");
    if (key_input.textInputCodepoint(key)) |codepoint| return payload(Msg, "source_search_insert", codepoint);
    return null;
}

fn fileSearchKey(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_file_search");
    if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_file_search");
    if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "file_search_backspace");
    if (key.matches(chasen.Key.up, .{})) return voidMsg(Msg, "file_search_previous");
    if (key.matches(chasen.Key.down, .{})) return voidMsg(Msg, "file_search_next");
    if (key_input.textInputCodepoint(key)) |codepoint| return payload(Msg, "file_search_insert", codepoint);
    return null;
}

fn voidMsg(comptime Msg: type, comptime field: []const u8) Msg {
    return @unionInit(Msg, field, {});
}

fn payload(comptime Msg: type, comptime field: []const u8, value: anytype) Msg {
    return @unionInit(Msg, field, value);
}

const TestMsg = union(enum) {
    toggle_focus,
    toggle_directory,
    move_up,
    move_down,
    scroll_left,
    scroll_right,
    page_up,
    page_down,
    source_first,
    source_last,
    tree_first,
    tree_last,
    enter_source_search,
    enter_file_search,
    toggle_line_numbers,
    clear_source_search,
    next_source_match,
    previous_source_match,
    cancel_source_search,
    submit_source_search,
    source_search_backspace,
    source_search_move_left,
    source_search_move_right,
    source_search_insert: u21,
    source_search_paste: []const u8,
    cancel_file_search,
    submit_file_search,
    file_search_backspace,
    file_search_previous,
    file_search_next,
    file_search_insert: u21,
    file_search_paste: []const u8,
};

test "repository input routes focus search and file search independently" {
    try std.testing.expectEqual(TestMsg.toggle_focus, keyToMsg(TestMsg, .{ .source_available = true }, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(TestMsg.source_first, keyToMsg(TestMsg, .{ .focus = .source }, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(TestMsg.tree_first, keyToMsg(TestMsg, .{}, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(TestMsg.enter_source_search, keyToMsg(TestMsg, .{ .source_available = true }, .{ .codepoint = '/' }).?);
    try std.testing.expectEqual(TestMsg.file_search_next, keyToMsg(TestMsg, .{ .file_search_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqualStrings("needle", pasteToMsg(TestMsg, .{ .source_search_mode = true }, "needle").?.source_search_paste);
}
