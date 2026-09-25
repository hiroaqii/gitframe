//! Compare-local input and base-picker ownership.

const chasen = @import("chasen");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");
const branch_picker = @import("../../branch_picker.zig");
const committed_diff_input = @import("../committed_diff/input.zig");

pub const Msg = union(enum) {
    common: committed_diff_input.Msg,
    open_base_picker,
    close_base_picker,
    base_picker_enter_query,
    base_picker_leave_query,
    base_picker_clear_query,
    base_picker_insert: u21,
    base_picker_backspace,
    base_picker_previous,
    base_picker_next,
    choose_base,
};

pub const Context = struct {
    common: committed_diff_input.Context = .{},
    base_picker_open: bool = false,
    base_picker_query_mode: bool = false,
    base_picker_query_len: usize = 0,
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (context.base_picker_open) return null;
    return .{ .common = committed_diff_input.pasteToMsg(context.common, text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.base_picker_open) return basePickerKeyToMsg(context, key);
    if (!context.common.search_mode and !context.common.file_search_mode and
        (context.common.keymap.actionForKey(key) == .create_stash or context.common.keymap.actionForKey(key) == .stash_list)) return null;
    if (committed_diff_input.keyToMsg(context.common, key)) |msg| return .{ .common = msg };
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'm') return .open_base_picker;
    return null;
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.base_picker_open) return null;
    return .{ .common = committed_diff_input.selectionKeyToMsg(context.common, key) orelse return null };
}

fn basePickerKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    const action = branch_picker.keyToAction(.{
        .query_mode = context.base_picker_query_mode,
        .query_len = context.base_picker_query_len,
    }, key) orelse return null;
    return switch (action) {
        .confirm => .choose_base,
        .cancel => .close_base_picker,
        .previous => .base_picker_previous,
        .next => .base_picker_next,
        .enter_query => .base_picker_enter_query,
        .leave_query => .base_picker_leave_query,
        .clear_query => .base_picker_clear_query,
        .insert => |codepoint| .{ .base_picker_insert = codepoint },
        .backspace => .base_picker_backspace,
    };
}

test "Compare owns its base picker launch key" {
    const std = @import("std");
    const context: Context = .{};
    try std.testing.expectEqual(Msg.open_base_picker, keyToMsg(context, .{ .codepoint = 'm' }).?);
    var config: @import("keymap").Config = .{};
    config.set(.next_file, .{ .plain_codepoint = 'm' });
    const custom: Context = .{ .common = .{ .keymap = .fromConfig(config) } };
    try std.testing.expectEqual(Msg{ .common = .{ .shared = .selection_owned_noop } }, keyToMsg(custom, .{ .codepoint = 'm' }).?);
}

test "Compare base picker owns modal input" {
    const std = @import("std");
    var context: Context = .{ .base_picker_open = true };
    try std.testing.expectEqual(Msg.choose_base, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.close_base_picker, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.base_picker_enter_query, keyToMsg(context, .{ .codepoint = '/' }).?);
    try std.testing.expectEqual(Msg.base_picker_previous, keyToMsg(context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg.base_picker_next, keyToMsg(context, .{ .codepoint = 'j' }).?);

    context.base_picker_query_mode = true;
    for ("qjk/") |codepoint| {
        try std.testing.expectEqual(Msg{ .base_picker_insert = codepoint }, keyToMsg(context, .{ .codepoint = codepoint }).?);
    }
    try std.testing.expectEqual(Msg.base_picker_previous, keyToMsg(context, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(Msg.base_picker_next, keyToMsg(context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(Msg.choose_base, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.base_picker_leave_query, keyToMsg(context, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(Msg.base_picker_clear_query, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.base_picker_backspace, keyToMsg(context, .{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = 'q', .mods = .{ .ctrl = true } }) == null);
    try std.testing.expect(pasteToMsg(context, "qjk") == null);

    context.base_picker_query_mode = false;
    context.base_picker_query_len = 3;
    try std.testing.expectEqual(Msg.base_picker_clear_query, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.close_base_picker, keyToMsg(context, .{ .codepoint = 'q' }).?);
}

comptime {
    _ = diff_surface.Focus;
}
