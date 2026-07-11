//! Review-local keyboard and paste mapping.
//!
//! The shell resolves prompt/overlay precedence before delegating here. This
//! module returns Review-owned semantic messages and has no dependency on App,
//! shell overlays, processes, or effect handles.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../../key_input.zig");
const review_page = @import("../review.zig");

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    search_query_len: usize = 0,
    focus: review_page.Focus = .sidebar,
    sidebar_hidden: bool = false,
    review_mode: bool = false,
    keymap: keymap.Effective = .{},
};

pub const Msg = union(enum) {
    cancel_search,
    submit_search,
    search_backspace,
    search_move_left,
    search_move_right,
    search_insert: u21,
    search_paste: []const u8,
    cancel_file_search,
    submit_file_search,
    file_search_backspace,
    file_search_insert: u21,
    file_search_paste: []const u8,
    toggle_focus,
    page_diff_up,
    page_diff_down,
    select_first_file,
    select_last_file,
    clear_search,
    toggle_directory,
    toggle_hunk_fold,
    expand_directory,
    collapse_or_parent_directory,
    scroll_diff_right,
    scroll_diff_left,
    scroll_sidebar_right,
    scroll_sidebar_left,
    scroll_diff_up,
    select_previous_file,
    scroll_diff_down,
    select_next_file,
    enter_search,
    select_next_search_match,
    select_next_hunk,
    select_previous_search_match,
    select_previous_hunk,
    enter_file_search,
    enter_repo_picker,
    open_help,
    cycle_changed_file_filter,
    toggle_reviewed_file,
    toggle_hide_reviewed_files,
    toggle_sidebar_visibility,
    decrease_sidebar_width,
    increase_sidebar_width,
    enter_commit_panel,
    enter_amend_panel,
    toggle_selected_file,
    toggle_selected_hunk,
    request_discard_selected_file,
    request_push,
    request_pull,
    request_fetch,
    request_branch_switch,
    open_selected_file_in_editor,
    toggle_display_mode,
    toggle_line_numbers,
    copy_current_line,
    copy_current_hunk,
    finish_review_approved,
    finish_review_needs_changes,
    finish_review_canceled,
    quit,
    reload,
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    if (context.search_mode) return .{ .search_paste = text };
    if (context.file_search_mode) return .{ .file_search_paste = text };
    return null;
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.search_mode) return searchKeyToMsg(key);
    if (context.file_search_mode) return fileSearchKeyToMsg(key);
    return normalKeyToMsg(context, key);
}

fn searchKeyToMsg(key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return .cancel_search;
    if (key.matches(chasen.Key.enter, .{})) return .submit_search;
    if (key.matches(chasen.Key.backspace, .{})) return .search_backspace;
    if (key.matches(chasen.Key.left, .{})) return .search_move_left;
    if (key.matches(chasen.Key.right, .{})) return .search_move_right;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .search_insert = codepoint };
    return null;
}

fn fileSearchKeyToMsg(key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return .cancel_file_search;
    if (key.matches(chasen.Key.enter, .{})) return .submit_file_search;
    if (key.matches(chasen.Key.backspace, .{})) return .file_search_backspace;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .file_search_insert = codepoint };
    return null;
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
    if (key.matches(chasen.Key.home, .{})) return .select_first_file;
    if (key.matches(chasen.Key.end, .{})) return .select_last_file;

    if (context.keymap.actionForKey(key)) |action| return publicActionToMsg(action);

    if (key_input.matchesShiftedAscii(key, 'j', 'J')) return if (context.focus == .diff) .select_next_hunk else null;
    if (key_input.matchesShiftedAscii(key, 'k', 'K')) return if (context.focus == .diff) .select_previous_hunk else null;
    if (key_input.matchesShiftedAscii(key, 'n', 'N')) {
        if (context.search_query_len > 0) return .select_previous_search_match;
        return if (context.review_mode) .finish_review_needs_changes else null;
    }
    if (key_input.matchesShiftedAscii(key, 's', 'S')) return null;
    if (context.review_mode and key.matches('a', .{})) return .finish_review_approved;
    if (key_input.hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'k', chasen.Key.up => if (context.focus == .diff) .scroll_diff_up else .select_previous_file,
        'j', chasen.Key.down => if (context.focus == .diff) .scroll_diff_down else .select_next_file,
        'n' => if (context.search_query_len > 0) .select_next_search_match else .select_next_hunk,
        'p' => if (context.search_query_len > 0) .select_previous_search_match else .select_previous_hunk,
        's' => if (context.focus == .diff) .toggle_selected_hunk else .toggle_selected_file,
        'q' => if (context.review_mode) .finish_review_canceled else .quit,
        else => null,
    };
}

fn publicActionToMsg(action: keymap.PublicAction) Msg {
    return switch (action) {
        .help => .open_help,
        .reload => .reload,
        .search => .enter_search,
        .file_search => .enter_file_search,
        .repo_picker => .enter_repo_picker,
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
    try std.testing.expectEqualStrings("needle", pasteToMsg(context, "needle").?.search_paste);
}

test "file search input rejects non text modes" {
    const context: Context = .{ .file_search_mode = true };
    try std.testing.expectEqual(Msg.file_search_backspace, keyToMsg(context, chasen.Key{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expect(keyToMsg(context, chasen.Key{ .codepoint = chasen.Key.up }) == null);
}

test "normal mapping is focus and review-mode aware" {
    try std.testing.expectEqual(Msg.select_next_file, keyToMsg(.{}, chasen.Key{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.scroll_diff_down, keyToMsg(.{ .focus = .diff }, chasen.Key{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.quit, keyToMsg(.{}, chasen.Key{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(Msg.finish_review_canceled, keyToMsg(.{ .review_mode = true }, chasen.Key{ .codepoint = 'q' }).?);
}

test "normal mapping uses configured Review commands" {
    var config: keymap.Config = .{};
    config.set(.reload, .{ .ctrl = .s });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(Msg.reload, keyToMsg(.{ .keymap = effective }, chasen.Key{ .codepoint = 's', .mods = .{ .ctrl = true } }).?);
}

test "focus controls enter arrows sidebar scroll and stage target" {
    try std.testing.expectEqual(Msg.toggle_directory, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.toggle_hunk_fold, keyToMsg(.{ .focus = .diff }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.expand_directory, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg.scroll_diff_right, keyToMsg(.{ .focus = .diff }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg.scroll_sidebar_left, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(Msg.toggle_selected_file, keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 's' }).?);
    try std.testing.expectEqual(Msg.toggle_selected_hunk, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 's' }).?);
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
        .{ .codepoint = 'R', .expected = .enter_repo_picker },
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
        .{ .lower = 'r', .upper = 'R', .expected = .enter_repo_picker },
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
