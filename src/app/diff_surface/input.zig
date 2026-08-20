//! Modal keyboard and paste mapping shared by read-only diff surfaces.
//!
//! Normal-mode mapping remains page-owned because Changes and Review extend
//! the shared vocabulary with different commands and authority.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../key_input.zig");
const selection_input = @import("../selection_input.zig");
const diff_selection = @import("../../diff/selection.zig");
const message = @import("message.zig");

pub const SelectionOwnerKind = enum {
    none,
    mouse,
    keyboard_line,
    keyboard_side_choice,
    header,
};

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    side_by_side: bool = false,
    selection_owner: SelectionOwnerKind = .none,
    retained_selection_action_available: bool = false,
    keymap: keymap.Effective = .{},
};

pub fn selectionOwnerKind(owner: diff_selection.Owner) SelectionOwnerKind {
    return switch (owner) {
        .none => .none,
        .diff => |selection| if (selection.origin == .keyboard_line) .keyboard_line else .mouse,
        .diff_header => .header,
        .keyboard_side_choice => .keyboard_side_choice,
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

/// Maps the page-neutral document vocabulary after page modal and selection
/// owners have declined the key. A configured action is still claimed when
/// the diff is not focused; returning null makes that terminal a safe no-op.
pub fn documentNavigationMsg(action: keymap.PublicAction, diff_focused: bool) ?message.Msg {
    if (!diff_focused or !keymap.isDocumentNavigationAction(action)) return null;
    return switch (action) {
        .document_first => .document_first,
        .document_last => .document_last,
        .half_page_up => .half_page_up,
        .half_page_down => .half_page_down,
        .page_backward => .page_diff_up,
        .page_forward => .page_diff_down,
        else => unreachable,
    };
}

/// Bounded selection grammar used both by page-local input and by the root
/// preflight that runs after modal owners but before configured root actions.
pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?message.Msg {
    switch (context.selection_owner) {
        .keyboard_side_choice => {
            if (key.matches('h', .{}) or key.matches(chasen.Key.left, .{})) {
                return .{ .choose_keyboard_selection_side = .old };
            }
            if (key.matches('l', .{}) or key.matches(chasen.Key.right, .{})) {
                return .{ .choose_keyboard_selection_side = .new };
            }
            if (key.matches(chasen.Key.escape, .{})) return .{ .selection_action = .clear };
            return .selection_owned_noop;
        },
        .keyboard_line => if (context.side_by_side) {
            if (key.matches('h', .{}) or key.matches(chasen.Key.left, .{})) {
                return .{ .switch_keyboard_selection_side = .old };
            }
            if (key.matches('l', .{}) or key.matches(chasen.Key.right, .{})) {
                return .{ .switch_keyboard_selection_side = .new };
            }
        },
        .none, .mouse, .header => {},
    }
    const command = selection_input.keyToCommand(.{
        .owner_kind = neutralOwnerKind(context.selection_owner),
        .retained_action_available = context.retained_selection_action_available,
        .keymap = context.keymap,
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

fn neutralOwnerKind(owner: SelectionOwnerKind) selection_input.OwnerKind {
    return switch (owner) {
        .none => .none,
        .mouse => .mouse,
        .keyboard_line => .keyboard_line,
        .header => .header,
        .keyboard_side_choice => unreachable,
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

    const side_by_side: Context = .{ .side_by_side = true, .selection_owner = .keyboard_line };
    try std.testing.expectEqual(
        message.Msg{ .switch_keyboard_selection_side = .old },
        selectionKeyToMsg(side_by_side, .{ .codepoint = chasen.Key.left }).?,
    );
    try std.testing.expectEqual(
        message.Msg{ .switch_keyboard_selection_side = .new },
        selectionKeyToMsg(side_by_side, .{ .codepoint = 'l' }).?,
    );
}

test "keyboard side chooser owns side cancel and background keys" {
    const choosing: Context = .{ .side_by_side = true, .selection_owner = .keyboard_side_choice };
    try std.testing.expectEqual(
        message.Msg{ .choose_keyboard_selection_side = .old },
        selectionKeyToMsg(choosing, .{ .codepoint = 'h' }).?,
    );
    try std.testing.expectEqual(
        message.Msg{ .choose_keyboard_selection_side = .new },
        selectionKeyToMsg(choosing, .{ .codepoint = chasen.Key.right }).?,
    );
    try std.testing.expectEqual(
        message.Msg{ .selection_action = .clear },
        selectionKeyToMsg(choosing, .{ .codepoint = chasen.Key.escape }).?,
    );
    try std.testing.expectEqual(message.Msg.selection_owned_noop, selectionKeyToMsg(choosing, .{ .codepoint = 'j' }).?);
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

test "diff selection and document navigation honor owners focus aliases and custom bindings" {
    const active: Context = .{ .selection_owner = .keyboard_line };
    try std.testing.expectEqual(message.Msg.selection_owned_noop, selectionKeyToMsg(active, .{ .codepoint = 'g' }).?);
    try std.testing.expectEqual(
        message.Msg.selection_owned_noop,
        selectionKeyToMsg(active, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }).?,
    );

    var config: keymap.Config = .{};
    config.set(.document_first, .{ .plain_codepoint = 'z' });
    const custom: Context = .{
        .selection_owner = .header,
        .keymap = keymap.Effective.fromConfig(config),
    };
    try std.testing.expectEqual(message.Msg.selection_owned_noop, selectionKeyToMsg(custom, .{ .codepoint = 'z' }).?);
    try std.testing.expect(selectionKeyToMsg(custom, .{ .codepoint = 'g' }) == null);

    try std.testing.expectEqual(message.Msg.document_first, documentNavigationMsg(.document_first, true).?);
    try std.testing.expectEqual(message.Msg.document_last, documentNavigationMsg(.document_last, true).?);
    try std.testing.expectEqual(message.Msg.half_page_up, documentNavigationMsg(.half_page_up, true).?);
    try std.testing.expectEqual(message.Msg.half_page_down, documentNavigationMsg(.half_page_down, true).?);
    try std.testing.expectEqual(message.Msg.page_diff_up, documentNavigationMsg(.page_backward, true).?);
    try std.testing.expectEqual(message.Msg.page_diff_down, documentNavigationMsg(.page_forward, true).?);
    try std.testing.expect(documentNavigationMsg(.document_first, false) == null);
    try std.testing.expect(documentNavigationMsg(.search, true) == null);
}
