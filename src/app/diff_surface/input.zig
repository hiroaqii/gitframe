//! Modal keyboard and paste mapping shared by read-only diff surfaces.
//!
//! Normal-mode mapping remains page-owned because Review and Compare extend
//! the shared vocabulary with different commands and authority.

const std = @import("std");
const chasen = @import("chasen");
const key_input = @import("../key_input.zig");
const selection_input = @import("../selection_input.zig");
const diff_selection = @import("../../diff/selection.zig");
const message = @import("message.zig");

pub const SelectionOwnerKind = selection_input.OwnerKind;

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    selection_owner: SelectionOwnerKind = .none,
    retained_selection_action_available: bool = false,
};

pub fn selectionOwnerKind(owner: diff_selection.Owner) SelectionOwnerKind {
    return switch (owner) {
        .none => .none,
        .diff => |selection| if (selection.origin == .keyboard_line) .keyboard_line else .mouse,
        .diff_header => .header,
    };
}

pub fn pasteToMsg(context: Context, text: []const u8) ?message.Msg {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    if (context.search_mode) return .{ .search_paste = text };
    if (context.file_search_mode) return .{ .file_search_paste = text };
    return null;
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?message.Msg {
    if (context.search_mode) return searchKeyToMsg(key);
    if (context.file_search_mode) return fileSearchKeyToMsg(key);
    return selectionKeyToMsg(context, key);
}

/// Bounded selection grammar used both by page-local input and by the root
/// preflight that runs after modal owners but before configured root actions.
pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?message.Msg {
    const command = selection_input.keyToCommand(.{
        .owner_kind = context.selection_owner,
        .retained_action_available = context.retained_selection_action_available,
    }, key) orelse return null;
    return switch (command) {
        .move_up => .{ .keyboard_line_selection_move = .up },
        .move_down => .{ .keyboard_line_selection_move = .down },
        .copy => .{ .selection_action = .copy },
        .clear => .{ .selection_action = .clear },
        .ask => .selection_action_unavailable,
        .owned_noop => .selection_owned_noop,
    };
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
    try std.testing.expectEqual(message.Msg{ .selection_action = .copy }, keyToMsg(available, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(message.Msg{ .selection_action = .clear }, keyToMsg(available, .{ .codepoint = chasen.Key.escape }).?);

    const search: Context = .{ .search_mode = true, .retained_selection_action_available = true };
    try std.testing.expectEqual(message.Msg{ .search_insert = 'y' }, keyToMsg(search, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(message.Msg.cancel_search, keyToMsg(search, .{ .codepoint = chasen.Key.escape }).?);
}

test "keyboard line selection owns its bounded grammar" {
    const active: Context = .{ .selection_owner = .keyboard_line, .retained_selection_action_available = true };
    try std.testing.expectEqual(message.Msg{ .keyboard_line_selection_move = .down }, selectionKeyToMsg(active, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(message.Msg{ .keyboard_line_selection_move = .up }, selectionKeyToMsg(active, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(message.Msg{ .selection_action = .copy }, selectionKeyToMsg(active, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(message.Msg.selection_action_unavailable, selectionKeyToMsg(active, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(message.Msg.selection_owned_noop, selectionKeyToMsg(active, .{ .codepoint = 'V' }).?);
    try std.testing.expect(selectionKeyToMsg(active, .{ .codepoint = chasen.Key.left }) == null);
    try std.testing.expect(selectionKeyToMsg(active, .{ .codepoint = chasen.Key.right }) == null);
}

test "mouse and header selection consume selection keys without acquiring keyboard authority" {
    for ([_]SelectionOwnerKind{ .mouse, .header }) |owner| {
        const context: Context = .{ .selection_owner = owner };
        try std.testing.expectEqual(message.Msg.selection_owned_noop, selectionKeyToMsg(context, .{ .codepoint = 'j' }).?);
        try std.testing.expectEqual(message.Msg{ .selection_action = .clear }, selectionKeyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
        try std.testing.expect(selectionKeyToMsg(context, .{ .codepoint = chasen.Key.left }) == null);
        try std.testing.expect(selectionKeyToMsg(context, .{ .codepoint = chasen.Key.right }) == null);
    }
}
