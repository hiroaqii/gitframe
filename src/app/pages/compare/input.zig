//! Compare-local input and base-picker ownership.

const chasen = @import("chasen");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");
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
    open_ai_review,
    close_ai_review,
    submit_ai_review,
    ai_review_context_insert: u21,
    /// Borrowed from `chasen.Event.paste`; consumed synchronously by update.
    ai_review_context_paste: []const u8,
    ai_review_context_backspace,
    ai_review_context_move_left,
    ai_review_context_move_right,
};

pub const Context = struct {
    common: committed_diff_input.Context = .{},
    base_picker_open: bool = false,
    base_picker_query_mode: bool = false,
    base_picker_query_len: usize = 0,
    ai_review_modal_open: bool = false,
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (context.ai_review_modal_open) return .{ .ai_review_context_paste = text };
    if (context.base_picker_open) return null;
    return .{ .common = committed_diff_input.pasteToMsg(context.common, text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.ai_review_modal_open) return aiReviewModalKeyToMsg(key);
    if (context.base_picker_open) return basePickerKeyToMsg(context, key);
    if (committed_diff_input.keyToMsg(context.common, key)) |msg| return .{ .common = msg };
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'm') return .open_base_picker;
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'a') return .open_ai_review;
    return null;
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.base_picker_open or context.ai_review_modal_open) return null;
    return .{ .common = committed_diff_input.selectionKeyToMsg(context.common, key) orelse return null };
}

fn aiReviewModalKeyToMsg(key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return .close_ai_review;
    if (key.matches(chasen.Key.enter, .{})) return .submit_ai_review;
    if (key.matches(chasen.Key.backspace, .{})) return .ai_review_context_backspace;
    if (key.matches(chasen.Key.left, .{})) return .ai_review_context_move_left;
    if (key.matches(chasen.Key.right, .{})) return .ai_review_context_move_right;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .ai_review_context_insert = codepoint };
    return null;
}

fn basePickerKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) {
        return if (context.base_picker_query_mode or context.base_picker_query_len > 0)
            .base_picker_clear_query
        else
            .close_base_picker;
    }
    if (key.matches(chasen.Key.enter, .{})) return .choose_base;
    if (key.matches(chasen.Key.up, .{})) return .base_picker_previous;
    if (key.matches(chasen.Key.down, .{})) return .base_picker_next;
    if (context.base_picker_query_mode) {
        if (key.matches(chasen.Key.tab, .{})) return .base_picker_leave_query;
        if (key.matches(chasen.Key.backspace, .{})) return .base_picker_backspace;
        if (key_input.textInputCodepoint(key)) |codepoint| return .{ .base_picker_insert = codepoint };
        return null;
    }
    if (key.codepoint == '/') return .base_picker_enter_query;
    if (key.codepoint == 'q') return .close_base_picker;
    if (key.codepoint == 'k') return .base_picker_previous;
    if (key.codepoint == 'j') return .base_picker_next;
    return null;
}

test "Compare owns independent base and AI review launch keys" {
    const std = @import("std");
    const context: Context = .{};
    try std.testing.expectEqual(Msg.open_base_picker, keyToMsg(context, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(Msg.open_ai_review, keyToMsg(context, .{ .codepoint = 'a' }).?);
}

test "Compare base picker owns modal input" {
    const std = @import("std");
    const context: Context = .{ .base_picker_open = true };
    try std.testing.expectEqual(Msg.choose_base, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.close_base_picker, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
}

test "Compare AI review modal owns context input and submission" {
    const std = @import("std");
    const context: Context = .{ .ai_review_modal_open = true };
    try std.testing.expectEqual(Msg.submit_ai_review, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.close_ai_review, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg{ .ai_review_context_insert = 'x' }, keyToMsg(context, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqualStrings("pasted", pasteToMsg(context, "pasted").?.ai_review_context_paste);
}

comptime {
    _ = diff_surface.Focus;
}
