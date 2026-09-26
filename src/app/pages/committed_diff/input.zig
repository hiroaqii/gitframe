//! Input shared by read-only committed-diff pages.

const chasen = @import("chasen");
const keymap = @import("keymap");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");

pub const Msg = union(enum) {
    shared: diff_surface.message.Msg,
    copy_current_line,
    copy_current_hunk,
};

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    search_query_len: usize = 0,
    focus: diff_surface.Focus = .sidebar,
    sidebar_hidden: bool = false,
    side_by_side: bool = false,
    selection_owner: diff_surface.input.SelectionOwnerKind = .none,
    retained_selection_action_available: bool = false,
    context_copy_available: bool = false,
    keymap: keymap.Effective = .{},

    fn shared(self: Context) diff_surface.input.Context {
        return .{
            .search_mode = self.search_mode,
            .file_search_mode = self.file_search_mode,
            .side_by_side = self.side_by_side,
            .selection_owner = self.selection_owner,
            .retained_selection_action_available = self.retained_selection_action_available,
            .context_copy_available = self.context_copy_available,
            .keymap = self.keymap,
        };
    }
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    return .{ .shared = diff_surface.input.pasteToMsg(context.shared(), text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.search_mode or context.file_search_mode) {
        return .{ .shared = diff_surface.input.keyToMsg(context.shared(), key) orelse return null };
    }
    if (diff_surface.input.keyToMsg(context.shared(), key)) |msg| return .{ .shared = msg };
    if (key.matches(chasen.Key.tab, .{}) and !context.sidebar_hidden) return shared(.toggle_focus);
    if (key.matches(chasen.Key.escape, .{}) and context.search_query_len > 0) return shared(.clear_search);
    if (context.focus == .sidebar and key.matches(chasen.Key.enter, .{})) return shared(.toggle_directory);
    if (context.focus == .diff and key.matches(chasen.Key.enter, .{})) return shared(.toggle_hunk_fold);
    if (context.focus == .sidebar and key.matches(chasen.Key.right, .{})) return shared(.expand_directory);
    if (context.focus == .sidebar and key.matches(chasen.Key.left, .{})) return shared(.collapse_or_parent_directory);
    if (context.focus == .diff and key.matches(chasen.Key.right, .{})) return shared(.scroll_diff_right);
    if (context.focus == .diff and key.matches(chasen.Key.left, .{})) return shared(.scroll_diff_left);
    if (context.focus == .sidebar and key.matches('h', .{})) return shared(.scroll_sidebar_left);
    if (context.focus == .sidebar and key.matches('l', .{})) return shared(.scroll_sidebar_right);
    if (key.matches(chasen.Key.home, .{})) return shared(.select_first_file);
    if (key.matches(chasen.Key.end, .{})) return shared(.select_last_file);

    if (context.keymap.actionForKey(key)) |action| return publicActionToMsg(action, context.focus == .diff);
    if (context.focus == .diff and key_input.matchesShiftedAscii(key, 'v', 'V')) return shared(.begin_keyboard_line_selection);
    if (key_input.matchesShiftedAscii(key, 'j', 'J')) return if (context.focus == .diff) shared(.select_next_hunk) else null;
    if (key_input.matchesShiftedAscii(key, 'k', 'K')) return if (context.focus == .diff) shared(.select_previous_hunk) else null;
    if (key_input.matchesShiftedAscii(key, 'n', 'N')) {
        return if (context.search_query_len > 0) shared(.select_previous_search_match) else null;
    }
    if (key_input.hasCommandModifier(key)) return null;
    return switch (key.codepoint) {
        'k', chasen.Key.up => if (context.focus == .diff) shared(.scroll_diff_up) else shared(.select_previous_file),
        'j', chasen.Key.down => if (context.focus == .diff) shared(.scroll_diff_down) else shared(.select_next_file),
        'n' => if (context.search_query_len > 0) shared(.select_next_search_match) else shared(.select_next_hunk),
        'p' => if (context.search_query_len > 0) shared(.select_previous_search_match) else shared(.select_previous_hunk),
        else => null,
    };
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    return .{ .shared = diff_surface.input.selectionKeyToMsg(context.shared(), key) orelse return null };
}

fn publicActionToMsg(action: keymap.PublicAction, diff_focused: bool) ?Msg {
    if (keymap.isDocumentNavigationAction(action)) {
        return shared(diff_surface.input.documentNavigationMsg(action, diff_focused) orelse return null);
    }
    return switch (action) {
        .search => shared(.enter_search),
        .file_search => shared(.enter_file_search),
        .toggle_display_mode => shared(.toggle_display_mode),
        .toggle_line_numbers => shared(.toggle_line_numbers),
        .toggle_sidebar => shared(.toggle_sidebar_visibility),
        .decrease_sidebar_width => shared(.decrease_sidebar_width),
        .increase_sidebar_width => shared(.increase_sidebar_width),
        .previous_file => shared(if (diff_focused) .previous_file else .selection_owned_noop),
        .next_file => shared(if (diff_focused) .next_file else .selection_owned_noop),
        .changed_file_filter => shared(.cycle_changed_file_filter),
        .mark_reviewed => shared(.toggle_reviewed_file),
        .hide_reviewed => shared(.toggle_hide_reviewed_files),
        .page_up => shared(.page_diff_up),
        .page_down => shared(.page_diff_down),
        .copy_current_line => .copy_current_line,
        .copy_history_detail => null,
        .copy_current_hunk => .copy_current_hunk,
        .branch_switch,
        .page_changes,
        .page_repository,
        .page_compare,
        .help,
        .reload,
        .repo_picker,
        .open_editor,
        .commit,
        .amend,
        .push,
        .pull,
        .fetch,
        .discard,
        => null,
        else => unreachable,
    };
}

fn shared(msg: diff_surface.message.Msg) Msg {
    return .{ .shared = msg };
}

test "committed diff input exposes shared display actions without write actions" {
    const context: Context = .{ .focus = .diff };
    try @import("std").testing.expect(keyToMsg(context, .{ .codepoint = 'u' }).? == .shared);
    try @import("std").testing.expect(keyToMsg(context, .{ .codepoint = 'c' }) == null);
    try @import("std").testing.expectEqual(Msg{ .shared = .previous_file }, keyToMsg(context, .{ .codepoint = '[' }).?);
    try @import("std").testing.expectEqual(Msg{ .shared = .next_file }, keyToMsg(context, .{ .codepoint = ']' }).?);
    try @import("std").testing.expectEqual(Msg{ .shared = .selection_owned_noop }, keyToMsg(.{}, .{ .codepoint = ']' }).?);
}
