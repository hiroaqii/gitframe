//! Modal keyboard and paste mapping shared by read-only diff surfaces.
//!
//! Normal-mode mapping remains page-owned because Review and Compare extend
//! the shared vocabulary with different commands and authority.

const std = @import("std");
const chasen = @import("chasen");
const key_input = @import("../key_input.zig");
const message = @import("message.zig");

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    retained_selection_action_available: bool = false,
};

pub fn pasteToMsg(context: Context, text: []const u8) ?message.Msg {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    if (context.search_mode) return .{ .search_paste = text };
    if (context.file_search_mode) return .{ .file_search_paste = text };
    return null;
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?message.Msg {
    if (context.search_mode) return searchKeyToMsg(key);
    if (context.file_search_mode) return fileSearchKeyToMsg(key);
    if (context.retained_selection_action_available and key.matches(chasen.Key.escape, .{})) return .clear_completed_selection;
    if (context.retained_selection_action_available and key.matches('y', .{})) return .copy_completed_selection;
    return null;
}

fn searchKeyToMsg(key: chasen.Key) ?message.Msg {
    if (key.matches(chasen.Key.escape, .{})) return .cancel_search;
    if (key.matches(chasen.Key.enter, .{})) return .submit_search;
    if (key.matches(chasen.Key.backspace, .{})) return .search_backspace;
    if (key.matches(chasen.Key.left, .{})) return .search_move_left;
    if (key.matches(chasen.Key.right, .{})) return .search_move_right;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .search_insert = codepoint };
    return null;
}

fn fileSearchKeyToMsg(key: chasen.Key) ?message.Msg {
    if (key.matches(chasen.Key.escape, .{})) return .cancel_file_search;
    if (key.matches(chasen.Key.enter, .{})) return .submit_file_search;
    if (key.matches(chasen.Key.backspace, .{})) return .file_search_backspace;
    if (key.matches(chasen.Key.up, .{})) return .file_search_previous;
    if (key.matches(chasen.Key.down, .{})) return .file_search_next;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .file_search_insert = codepoint };
    return null;
}

test "retained actions are shared after modal owners" {
    const available: Context = .{ .retained_selection_action_available = true };
    try std.testing.expectEqual(message.Msg.copy_completed_selection, keyToMsg(available, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(message.Msg.clear_completed_selection, keyToMsg(available, .{ .codepoint = chasen.Key.escape }).?);

    const search: Context = .{ .search_mode = true, .retained_selection_action_available = true };
    try std.testing.expectEqual(message.Msg{ .search_insert = 'y' }, keyToMsg(search, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(message.Msg.cancel_search, keyToMsg(search, .{ .codepoint = chasen.Key.escape }).?);
}
