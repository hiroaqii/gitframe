//! AI Reviews-local input. Compare and mutating Changes actions are absent.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");
const committed_diff_input = @import("../committed_diff/input.zig");
const human_review_decision = @import("human_review_decision.zig");

pub const Msg = union(enum) {
    common: committed_diff_input.Msg,
    open_picker,
    close_picker,
    picker_cancel_loading,
    picker_enter_query,
    picker_leave_query,
    picker_clear_query_or_leave,
    picker_insert: u21,
    picker_backspace,
    picker_previous,
    picker_next,
    picker_activate,
    picker_refresh_or_retry,
    open_human_review_decision,
    human_review_decision: human_review_decision.Msg,
    finding_navigation: FindingNavigationIntent,
    finding_card: FindingCardMsg,
    finding_pointer: FindingPointerEvent,
};

pub const FindingNavigationIntent = struct {
    scope: Scope,
    direction: Direction,

    pub const Scope = enum { current_file, all_files };
    pub const Direction = enum { previous, next };
};

pub const FindingCardMsg = enum {
    focus_or_cycle,
    toggle,
    scroll_up,
    scroll_down,
    copy,
    accept,
    dismiss,
    unreview,
    retry,
    leave,
    owned_noop,
};

/// One synchronous AI Reviews diff-pane pointer sample.
pub const FindingPointerEvent = struct {
    point: diff_surface.MousePoint,
    button: Button,

    pub const Button = enum {
        left,
        wheel_up,
        wheel_down,
        wheel_left,
        wheel_right,
    };
};

pub const Context = struct {
    common: committed_diff_input.Context = .{},
    picker_open: bool = false,
    picker_query_mode: bool = false,
    picker_query_len: usize = 0,
    picker_loading: bool = false,
    selected_run: bool = false,
    human_review: human_review_decision.InputContext = .{},
    finding_card_focused: bool = false,
    finding_card_at_cursor: bool = false,
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (context.human_review.open) {
        return .{ .human_review_decision = human_review_decision.pasteToMsg(context.human_review, text) orelse return null };
    }
    if (context.picker_open or context.finding_card_focused) return null;
    return .{ .common = committed_diff_input.pasteToMsg(context.common, text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.human_review.open) {
        return .{ .human_review_decision = human_review_decision.keyToMsg(context.human_review, key) orelse return null };
    }
    if (context.picker_open) return pickerKeyToMsg(context, key);
    if (context.common.search_mode or context.common.file_search_mode) {
        return commonKeyToMsg(context.common, key);
    }
    if (selectionOwnsFindingNavigation(context, key)) return common(.{ .shared = .selection_owned_noop });
    if (context.finding_card_focused) {
        if (context.selected_run) {
            if (findingNavigationIntent(key)) |intent| return .{ .finding_navigation = intent };
        }
        return .{ .finding_card = findingCardKeyToMsg(key) };
    }
    return normalKeyToMsg(context, key);
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'a') return .open_picker;
    if (selectionOwnsFindingNavigation(context, key)) return common(.{ .shared = .selection_owned_noop });
    return .{ .common = committed_diff_input.selectionKeyToMsg(context.common, key) orelse return null };
}

fn pickerKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) {
        if (context.picker_query_mode or context.picker_query_len > 0) return .picker_clear_query_or_leave;
        return if (context.picker_loading) .picker_cancel_loading else .close_picker;
    }
    if (key.matches(chasen.Key.enter, .{})) return .picker_activate;
    if (key.matches(chasen.Key.up, .{})) return .picker_previous;
    if (key.matches(chasen.Key.down, .{})) return .picker_next;
    if (context.picker_query_mode) {
        if (key.matches(chasen.Key.tab, .{})) return .picker_leave_query;
        if (key.matches(chasen.Key.backspace, .{})) return .picker_backspace;
        if (key_input.textInputCodepoint(key)) |codepoint| return .{ .picker_insert = codepoint };
        return null;
    }
    if (key.codepoint == '/') return .picker_enter_query;
    if (key.codepoint == 'q') return .close_picker;
    if (key.codepoint == 'r') return .picker_refresh_or_retry;
    if (key.codepoint == 'k') return .picker_previous;
    if (key.codepoint == 'j') return .picker_next;
    return null;
}

fn normalKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    const finding_navigation = if (context.selected_run) findingNavigationIntent(key) else null;
    if (context.common.keymap.actionForKey(key)) |action| {
        if (finding_navigation) |intent| {
            const codepoint = key_input.textInputCodepoint(key) orelse return null;
            const default_width_collision = switch (codepoint) {
                '[' => action == .decrease_sidebar_width,
                ']' => action == .increase_sidebar_width,
                else => false,
            };
            if (default_width_collision) return .{ .finding_navigation = intent };
        }
        // A configured binding consumes the key even when AI Reviews does not
        // expose the named write action.
        return commonKeyToMsg(context.common, key);
    }
    if (finding_navigation) |intent| return .{ .finding_navigation = intent };
    if (context.finding_card_at_cursor and !key_input.hasCommandModifier(key) and key.codepoint == 's') {
        return .{ .finding_card = .focus_or_cycle };
    }
    if (context.selected_run and key_input.matchesShiftedAscii(key, 'e', 'E')) {
        return .open_human_review_decision;
    }
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'a') return .open_picker;
    return commonKeyToMsg(context.common, key);
}

fn commonKeyToMsg(context: committed_diff_input.Context, key: chasen.Key) ?Msg {
    return .{ .common = committed_diff_input.keyToMsg(context, key) orelse return null };
}

fn findingNavigationIntent(key: chasen.Key) ?FindingNavigationIntent {
    const codepoint = key_input.textInputCodepoint(key) orelse return null;
    return switch (codepoint) {
        '[' => .{ .scope = .current_file, .direction = .previous },
        ']' => .{ .scope = .current_file, .direction = .next },
        '{' => .{ .scope = .all_files, .direction = .previous },
        '}' => .{ .scope = .all_files, .direction = .next },
        else => null,
    };
}

fn selectionOwnsFindingNavigation(context: Context, key: chasen.Key) bool {
    return findingNavigationIntent(key) != null and
        (context.common.selection_owner != .none or context.common.retained_selection_action_available);
}

fn findingCardKeyToMsg(key: chasen.Key) FindingCardMsg {
    if (key.matches(chasen.Key.enter, .{})) return .toggle;
    if (key.matches(chasen.Key.escape, .{})) return .leave;
    if (key.matches(chasen.Key.up, .{})) return .scroll_up;
    if (key.matches(chasen.Key.down, .{})) return .scroll_down;
    if (key_input.hasCommandModifier(key)) return .owned_noop;
    return switch (key.codepoint) {
        's' => .focus_or_cycle,
        'k' => .scroll_up,
        'j' => .scroll_down,
        'y' => .copy,
        'a' => .accept,
        'd' => .dismiss,
        'u' => .unreview,
        'r' => .retry,
        'q' => .leave,
        else => .owned_noop,
    };
}

fn common(msg: committed_diff_input.Msg) Msg {
    return .{ .common = msg };
}

test "AI Reviews owns a and does not own Compare base selection" {
    try std.testing.expectEqual(Msg.open_picker, keyToMsg(.{}, .{ .codepoint = 'a' }).?);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'm' }) == null);
}

test "AI Reviews picker and Finding overlay retain separate input grammars" {
    try std.testing.expectEqual(
        Msg.picker_activate,
        keyToMsg(.{ .picker_open = true }, .{ .codepoint = chasen.Key.enter }).?,
    );
    try std.testing.expectEqual(
        Msg{ .finding_card = .accept },
        keyToMsg(.{ .finding_card_focused = true, .selected_run = true }, .{ .codepoint = 'a' }).?,
    );
}
