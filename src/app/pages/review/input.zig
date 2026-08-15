//! Review-local keyboard and paste mapping.
//!
//! The shell resolves prompt/overlay precedence before delegating here. This
//! module returns Review-owned semantic messages and has no dependency on App,
//! shell overlays, processes, or effect handles.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const diff_surface_input = @import("../../diff_surface/input.zig");
const key_input = @import("../../key_input.zig");
const review_page = @import("../review.zig");
const review_message = @import("message.zig");

pub const Msg = review_message.Msg;

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    search_query_len: usize = 0,
    focus: review_page.Focus = .sidebar,
    sidebar_hidden: bool = false,
    side_by_side: bool = false,
    review_mode: bool = false,
    selection_owner: diff_surface_input.SelectionOwnerKind = .none,
    retained_selection_action_available: bool = false,
    keymap: keymap.Effective = .{},

    fn shared(self: Context) diff_surface_input.Context {
        return .{
            .search_mode = self.search_mode,
            .file_search_mode = self.file_search_mode,
            .selection_owner = self.selection_owner,
            .retained_selection_action_available = self.retained_selection_action_available,
        };
    }
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    return review_message.fromShared(diff_surface_input.pasteToMsg(context.shared(), text) orelse return null);
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (diff_surface_input.keyToMsg(context.shared(), key)) |msg| return review_message.fromShared(msg);
    if (context.search_mode or context.file_search_mode) return null;
    return normalKeyToMsg(context, key);
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    return review_message.fromShared(diff_surface_input.selectionKeyToMsg(context.shared(), key) orelse return null);
}

fn normalKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.tab, .{}) and !context.sidebar_hidden) return .toggle_focus;
    if (key.matches(chasen.Key.escape, .{}) and context.search_query_len > 0) return .clear_search;
    if (context.focus == .sidebar and key.matches(chasen.Key.enter, .{})) return .toggle_directory;
    if (context.focus == .diff and key.matches(chasen.Key.enter, .{})) return .toggle_hunk_fold;
    if (context.focus == .sidebar and key.matches(chasen.Key.right, .{})) return .expand_directory;
    if (context.focus == .sidebar and key.matches(chasen.Key.left, .{})) return .collapse_or_parent_directory;
    if (context.focus == .diff and key.matches(chasen.Key.right, .{})) return .scroll_diff_right;
    if (context.focus == .diff and key.matches(chasen.Key.left, .{})) return .scroll_diff_left;
    if (context.focus == .sidebar and key.matches('h', .{})) return .scroll_sidebar_left;
    if (context.focus == .sidebar and key.matches('l', .{})) return .scroll_sidebar_right;
    if (context.focus == .diff and context.side_by_side and key.matches('h', .{})) return .{ .keyboard_select_side = .old };
    if (context.focus == .diff and context.side_by_side and key.matches('l', .{})) return .{ .keyboard_select_side = .new };
    if (key.matches(chasen.Key.home, .{})) return .select_first_file;
    if (key.matches(chasen.Key.end, .{})) return .select_last_file;

    if (context.keymap.actionForKey(key)) |action| return publicActionToMsg(action);

    if (context.focus == .diff and key_input.matchesShiftedAscii(key, 'v', 'V')) return .begin_keyboard_line_selection;

    if (key_input.matchesShiftedAscii(key, 'j', 'J')) return if (context.focus == .diff) .select_next_hunk else null;
    if (key_input.matchesShiftedAscii(key, 'k', 'K')) return if (context.focus == .diff) .select_previous_hunk else null;
    if (key_input.matchesShiftedAscii(key, 'n', 'N')) {
        if (context.search_query_len > 0) return .select_previous_search_match;
        return if (context.review_mode) .finish_review_needs_changes else null;
    }
    if (context.review_mode and key.matches('a', .{})) return .finish_review_approved;
    if (key_input.hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'k', chasen.Key.up => if (context.focus == .diff) .scroll_diff_up else .select_previous_file,
        'j', chasen.Key.down => if (context.focus == .diff) .scroll_diff_down else .select_next_file,
        'n' => if (context.search_query_len > 0) .select_next_search_match else .select_next_hunk,
        'p' => if (context.search_query_len > 0) .select_previous_search_match else .select_previous_hunk,
        ' ' => if (context.focus == .diff) .toggle_selected_hunk else .toggle_selected_file,
        'q' => if (context.review_mode) .finish_review_canceled else null,
        else => null,
    };
}

fn publicActionToMsg(action: keymap.PublicAction) ?Msg {
    return switch (action) {
        .page_review, .page_repository, .page_compare, .page_config => null,
        .help, .reload => null,
        .search => .enter_search,
        .file_search => .enter_file_search,
        .repo_picker => null,
        .open_editor => .open_selected_file_in_editor,
        .commit => .enter_commit_panel,
        .amend => .enter_amend_panel,
        .push => .request_push,
        .pull => .request_pull,
        .fetch => .request_fetch,
        .branch_switch => .request_branch_switch,
        .discard => .request_discard_selected_file,
        .toggle_display_mode => .toggle_display_mode,
        .toggle_line_numbers => .toggle_line_numbers,
        .toggle_sidebar => .toggle_sidebar_visibility,
        .decrease_sidebar_width => .decrease_sidebar_width,
        .increase_sidebar_width => .increase_sidebar_width,
        .changed_file_filter => .cycle_changed_file_filter,
        .mark_reviewed => .toggle_reviewed_file,
        .hide_reviewed => .toggle_hide_reviewed_files,
        .first_file => .select_first_file,
        .last_file => .select_last_file,
        .page_up => .page_diff_up,
        .page_down => .page_diff_down,
        .copy_current_line => .copy_current_line,
        .copy_current_hunk => .copy_current_hunk,
    };
}

test "search input owns editing navigation and paste" {
    const context: Context = .{ .search_mode = true };
    try std.testing.expectEqual(Msg.search_move_left, keyToMsg(context, chasen.Key{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(Msg{ .search_insert = 'x' }, keyToMsg(context, chasen.Key{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(Msg{ .search_insert = ' ' }, keyToMsg(context, chasen.Key{ .codepoint = ' ' }).?);
    try std.testing.expectEqualStrings("needle", pasteToMsg(context, "needle").?.search_paste);
}

test "file search input owns printable text and candidate movement" {
    const context: Context = .{ .file_search_mode = true };
    try std.testing.expectEqual(Msg.file_search_backspace, keyToMsg(context, chasen.Key{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expectEqual(Msg.file_search_previous, keyToMsg(context, chasen.Key{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(Msg.file_search_next, keyToMsg(context, chasen.Key{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(Msg{ .file_search_insert = 'q' }, keyToMsg(context, chasen.Key{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(Msg{ .file_search_insert = 'j' }, keyToMsg(context, chasen.Key{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg{ .file_search_insert = ' ' }, keyToMsg(context, chasen.Key{ .codepoint = ' ' }).?);
}

test "normal mapping is focus and review-mode aware" {
    try std.testing.expectEqual(Msg.select_next_file, keyToMsg(.{}, chasen.Key{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.scroll_diff_down, keyToMsg(.{ .focus = .diff }, chasen.Key{ .codepoint = 'j' }).?);
    try std.testing.expect(keyToMsg(.{}, chasen.Key{ .codepoint = 'q' }) == null);
    try std.testing.expectEqual(Msg.finish_review_canceled, keyToMsg(.{ .review_mode = true }, chasen.Key{ .codepoint = 'q' }).?);
}

test "retained selection actions override line copy and empty escape fallback" {
    const context: Context = .{ .retained_selection_action_available = true };
    try std.testing.expectEqual(Msg{ .selection_action = .copy }, keyToMsg(context, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(Msg{ .selection_action = .clear }, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.copy_current_line, keyToMsg(.{}, .{ .codepoint = 'y' }).?);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = chasen.Key.escape }) == null);
}

test "Review keyboard line selection maps side start movement and unavailable Ask" {
    const normal: Context = .{ .focus = .diff, .side_by_side = true };
    try std.testing.expectEqual(Msg{ .keyboard_select_side = .old }, keyToMsg(normal, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(Msg{ .keyboard_select_side = .new }, keyToMsg(normal, .{ .codepoint = 'l' }).?);
    try std.testing.expectEqual(Msg.begin_keyboard_line_selection, keyToMsg(normal, .{ .codepoint = 'V' }).?);

    const active: Context = .{ .selection_owner = .keyboard_line, .retained_selection_action_available = true };
    try std.testing.expectEqual(Msg{ .keyboard_line_selection_move = .down }, keyToMsg(active, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.selection_action_unavailable, keyToMsg(active, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(Msg.scroll_diff_left, keyToMsg(.{
        .focus = .diff,
        .selection_owner = .keyboard_line,
    }, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(Msg.expand_directory, keyToMsg(.{
        .focus = .sidebar,
        .selection_owner = .mouse,
    }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg.collapse_or_parent_directory, keyToMsg(.{
        .focus = .sidebar,
        .selection_owner = .header,
    }, .{ .codepoint = chasen.Key.left }).?);
}

test "shell-owned configured commands are not duplicated by Review" {
    var config: keymap.Config = .{};
    config.set(.reload, .{ .ctrl = .s });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expect(keyToMsg(.{ .keymap = effective }, chasen.Key{ .codepoint = 's', .mods = .{ .ctrl = true } }) == null);
}

test "focus controls enter arrows sidebar scroll and stage target" {
    try std.testing.expectEqual(Msg.toggle_directory, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.toggle_hunk_fold, keyToMsg(.{ .focus = .diff }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.expand_directory, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg.scroll_diff_right, keyToMsg(.{ .focus = .diff }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg.scroll_sidebar_left, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(Msg.toggle_selected_file, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = ' ' }).?);
    try std.testing.expectEqual(Msg.toggle_selected_hunk, keyToMsg(.{ .focus = .diff }, .{ .codepoint = ' ' }).?);
    try std.testing.expect(keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 's' }) == null);
    try std.testing.expect(keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'S' }) == null);
}

test "sidebar visibility and width commands remain Review-local" {
    try std.testing.expectEqual(Msg.toggle_focus, keyToMsg(.{}, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expect(keyToMsg(.{ .sidebar_hidden = true }, .{ .codepoint = chasen.Key.tab }) == null);
    try std.testing.expectEqual(Msg.toggle_sidebar_visibility, keyToMsg(.{}, .{ .codepoint = 'b', .mods = .{ .shift = true } }).?);
    try std.testing.expectEqual(Msg.request_branch_switch, keyToMsg(.{}, .{ .codepoint = 'b' }).?);
    try std.testing.expectEqual(Msg.decrease_sidebar_width, keyToMsg(.{}, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(Msg.increase_sidebar_width, keyToMsg(.{}, .{ .codepoint = ']' }).?);
}

test "search query disambiguates match and hunk navigation" {
    try std.testing.expectEqual(Msg.select_next_hunk, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'n' }).?);
    try std.testing.expectEqual(Msg.select_previous_hunk, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'p' }).?);
    try std.testing.expectEqual(Msg.select_next_search_match, keyToMsg(.{ .focus = .diff, .search_query_len = 1 }, .{ .codepoint = 'n' }).?);
    try std.testing.expectEqual(Msg.select_previous_search_match, keyToMsg(.{ .focus = .diff, .search_query_len = 1 }, .{ .codepoint = 'p' }).?);
    try std.testing.expectEqual(Msg.select_next_hunk, keyToMsg(.{ .focus = .diff, .search_query_len = 1 }, .{ .codepoint = 'J' }).?);
}

test "review result commands require review mode" {
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'a' }) == null);
    try std.testing.expectEqual(Msg.finish_review_approved, keyToMsg(.{ .review_mode = true }, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(Msg.finish_review_needs_changes, keyToMsg(.{ .review_mode = true }, .{ .codepoint = 'N' }).?);
    try std.testing.expectEqual(Msg.finish_review_canceled, keyToMsg(.{ .review_mode = true }, .{ .codepoint = 'q' }).?);
}

test "configured view copy and operation commands map through Review owner" {
    var config: keymap.Config = .{};
    config.set(.copy_current_line, .{ .ctrl = .s });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(Msg.copy_current_line, keyToMsg(.{ .keymap = effective }, .{ .codepoint = 's', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(Msg.toggle_display_mode, keyToMsg(.{}, .{ .codepoint = 'u' }).?);
    try std.testing.expectEqual(Msg.request_pull, keyToMsg(.{}, .{ .codepoint = 'U' }).?);
    try std.testing.expectEqual(Msg.request_push, keyToMsg(.{}, .{ .codepoint = 'P' }).?);
}

test "command modifiers do not trigger static Review commands" {
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'j', .mods = .{ .ctrl = true } }) == null);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'N', .mods = .{ .ctrl = true } }) == null);
}

test "static Review command matrix preserves configurable defaults" {
    const Case = struct { codepoint: u21, expected: Msg };
    const cases = [_]Case{
        .{ .codepoint = 'L', .expected = .toggle_line_numbers },
        .{ .codepoint = 'y', .expected = .copy_current_line },
        .{ .codepoint = 'Y', .expected = .copy_current_hunk },
        .{ .codepoint = 'G', .expected = .select_last_file },
        .{ .codepoint = 'F', .expected = .cycle_changed_file_filter },
        .{ .codepoint = 'H', .expected = .toggle_hide_reviewed_files },
        .{ .codepoint = chasen.Key.home, .expected = .select_first_file },
        .{ .codepoint = chasen.Key.end, .expected = .select_last_file },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, keyToMsg(.{}, .{ .codepoint = case.codepoint }).?);
}

test "shifted terminal encodings preserve Review commands" {
    const Case = struct { lower: u21, upper: u21, expected: Msg };
    const cases = [_]Case{
        .{ .lower = 'g', .upper = 'G', .expected = .select_last_file },
        .{ .lower = 'f', .upper = 'F', .expected = .cycle_changed_file_filter },
        .{ .lower = 'h', .upper = 'H', .expected = .toggle_hide_reviewed_files },
        .{ .lower = 'p', .upper = 'P', .expected = .request_push },
        .{ .lower = 'u', .upper = 'U', .expected = .request_pull },
        .{ .lower = 'b', .upper = 'B', .expected = .toggle_sidebar_visibility },
        .{ .lower = 'l', .upper = 'L', .expected = .toggle_line_numbers },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, keyToMsg(.{}, .{ .codepoint = case.lower, .mods = .{ .shift = true } }).?);
        try std.testing.expectEqual(case.expected, keyToMsg(.{}, .{ .codepoint = case.upper }).?);
    }
}

test "shifted stage and dedicated hunk commands preserve contextual guards" {
    try std.testing.expect(keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 'S' }) == null);
    try std.testing.expect(keyToMsg(.{ .focus = .diff }, .{ .codepoint = 's', .mods = .{ .shift = true } }) == null);
    try std.testing.expectEqual(Msg.select_next_hunk, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'J' }).?);
    try std.testing.expectEqual(Msg.select_previous_hunk, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'K' }).?);
    try std.testing.expect(keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 'J' }) == null);
}

test "search input cursor and modifiers are normalized before semantic mapping" {
    const context: Context = .{ .search_mode = true };
    try std.testing.expectEqual(Msg.search_move_left, keyToMsg(context, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(Msg.search_move_right, keyToMsg(context, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = chasen.Key.left, .mods = .{ .ctrl = true } }) == null);
    try std.testing.expect(keyToMsg(context, .{ .codepoint = 'x', .mods = .{ .ctrl = true } }) == null);
}
