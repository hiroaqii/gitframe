//! Compare-local input and base-picker ownership.

const chasen = @import("chasen");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");
const committed_diff_input = @import("../committed_diff/input.zig");
const ai_review_handoff = @import("ai_review_handoff.zig");

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
    open_ai_review_handoff,
    close_ai_review_handoff,
    copy_ai_review_handoff,
    scroll_ai_review_handoff: ai_review_handoff.ScrollAction,
};

pub const Context = struct {
    common: committed_diff_input.Context = .{},
    base_picker_open: bool = false,
    base_picker_query_mode: bool = false,
    base_picker_query_len: usize = 0,
    ai_review_handoff_open: bool = false,
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (context.ai_review_handoff_open) return null;
    if (context.base_picker_open) return null;
    return .{ .common = committed_diff_input.pasteToMsg(context.common, text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.ai_review_handoff_open) return aiReviewHandoffKeyToMsg(key);
    if (context.base_picker_open) return basePickerKeyToMsg(context, key);
    if (committed_diff_input.keyToMsg(context.common, key)) |msg| return .{ .common = msg };
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'm') return .open_base_picker;
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'a') return .open_ai_review_handoff;
    return null;
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.base_picker_open or context.ai_review_handoff_open) return null;
    return .{ .common = committed_diff_input.selectionKeyToMsg(context.common, key) orelse return null };
}

fn aiReviewHandoffKeyToMsg(key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or
        (!key_input.hasCommandModifier(key) and key.codepoint == 'q')) return .close_ai_review_handoff;
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'y') return .copy_ai_review_handoff;
    if (key.matches(chasen.Key.up, .{}) or
        (!key_input.hasCommandModifier(key) and key.codepoint == 'k')) return .{ .scroll_ai_review_handoff = .row_up };
    if (key.matches(chasen.Key.down, .{}) or
        (!key_input.hasCommandModifier(key) and key.codepoint == 'j')) return .{ .scroll_ai_review_handoff = .row_down };
    if (key.matches(chasen.Key.page_up, .{})) return .{ .scroll_ai_review_handoff = .page_up };
    if (key.matches(chasen.Key.page_down, .{})) return .{ .scroll_ai_review_handoff = .page_down };
    if (key.matches(chasen.Key.home, .{})) return .{ .scroll_ai_review_handoff = .home };
    if (key.matches(chasen.Key.end, .{})) return .{ .scroll_ai_review_handoff = .end };
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

test "AI Review Handoff Compare owns independent base and handoff launch keys" {
    const std = @import("std");
    const context: Context = .{};
    try std.testing.expectEqual(Msg.open_base_picker, keyToMsg(context, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(Msg.open_ai_review_handoff, keyToMsg(context, .{ .codepoint = 'a' }).?);
}

test "Compare base picker owns modal input" {
    const std = @import("std");
    const context: Context = .{ .base_picker_open = true };
    try std.testing.expectEqual(Msg.choose_base, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.close_base_picker, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
}

test "AI Review Handoff modal owns copy scroll close and inert editing input" {
    const std = @import("std");
    const context: Context = .{ .ai_review_handoff_open = true };
    try std.testing.expectEqual(Msg.close_ai_review_handoff, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.close_ai_review_handoff, keyToMsg(context, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(Msg.copy_ai_review_handoff, keyToMsg(context, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(Msg{ .scroll_ai_review_handoff = .row_up }, keyToMsg(context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg{ .scroll_ai_review_handoff = .row_down }, keyToMsg(context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(Msg{ .scroll_ai_review_handoff = .page_up }, keyToMsg(context, .{ .codepoint = chasen.Key.page_up }).?);
    try std.testing.expectEqual(Msg{ .scroll_ai_review_handoff = .end }, keyToMsg(context, .{ .codepoint = chasen.Key.end }).?);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = chasen.Key.enter }) == null);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = 'x' }) == null);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = chasen.Key.backspace }) == null);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = chasen.Key.left }) == null);
    try std.testing.expect(pasteToMsg(context, "pasted") == null);
}

comptime {
    _ = diff_surface.Focus;
}
