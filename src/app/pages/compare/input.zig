//! Compare-local input. Mutating Review actions are intentionally absent.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");

pub const Msg = union(enum) {
    shared: diff_surface.message.Msg,
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
    copy_current_line,
    copy_current_hunk,
    branch_switch_unavailable,
};

pub const Context = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    search_query_len: usize = 0,
    focus: diff_surface.Focus = .sidebar,
    sidebar_hidden: bool = false,
    side_by_side: bool = false,
    base_picker_open: bool = false,
    base_picker_query_mode: bool = false,
    base_picker_query_len: usize = 0,
    selection_owner: diff_surface.input.SelectionOwnerKind = .none,
    retained_selection_action_available: bool = false,
    keymap: keymap.Effective = .{},

    fn shared(self: Context) diff_surface.input.Context {
        return .{
            .search_mode = self.search_mode,
            .file_search_mode = self.file_search_mode,
            .selection_owner = self.selection_owner,
            .retained_selection_action_available = self.retained_selection_action_available,
            .keymap = self.keymap,
        };
    }
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    return .{ .shared = diff_surface.input.pasteToMsg(context.shared(), text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.base_picker_open) {
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
    if (diff_surface.input.keyToMsg(context.shared(), key)) |msg| return .{ .shared = msg };
    if (context.search_mode or context.file_search_mode) return null;
    return normalKeyToMsg(context, key);
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    return .{ .shared = diff_surface.input.selectionKeyToMsg(context.shared(), key) orelse return null };
}

fn normalKeyToMsg(context: Context, key: chasen.Key) ?Msg {
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
    if (context.focus == .diff and context.side_by_side and key.matches('h', .{})) return shared(.{ .keyboard_select_side = .old });
    if (context.focus == .diff and context.side_by_side and key.matches('l', .{})) return shared(.{ .keyboard_select_side = .new });
    if (key.matches(chasen.Key.home, .{})) return shared(.select_first_file);
    if (key.matches(chasen.Key.end, .{})) return shared(.select_last_file);

    // A user binding consumes the key even when it names an operation Compare
    // intentionally does not expose. This is what lets a user-bound `m` win
    // over the page-local picker mnemonic.
    if (context.keymap.actionForKey(key)) |action| return publicActionToMsg(action, context.focus == .diff);

    if (context.focus == .diff and key_input.matchesShiftedAscii(key, 'v', 'V')) return shared(.begin_keyboard_line_selection);

    if (key_input.matchesShiftedAscii(key, 'j', 'J')) return if (context.focus == .diff) shared(.select_next_hunk) else null;
    if (key_input.matchesShiftedAscii(key, 'k', 'K')) return if (context.focus == .diff) shared(.select_previous_hunk) else null;
    if (key_input.matchesShiftedAscii(key, 'n', 'N')) {
        return if (context.search_query_len > 0) shared(.select_previous_search_match) else null;
    }
    if (key_input.hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'm' => .open_base_picker,
        'k', chasen.Key.up => if (context.focus == .diff) shared(.scroll_diff_up) else shared(.select_previous_file),
        'j', chasen.Key.down => if (context.focus == .diff) shared(.scroll_diff_down) else shared(.select_next_file),
        'n' => if (context.search_query_len > 0) shared(.select_next_search_match) else shared(.select_next_hunk),
        'p' => if (context.search_query_len > 0) shared(.select_previous_search_match) else shared(.select_previous_hunk),
        else => null,
    };
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
        .changed_file_filter => shared(.cycle_changed_file_filter),
        .mark_reviewed => shared(.toggle_reviewed_file),
        .hide_reviewed => shared(.toggle_hide_reviewed_files),
        .page_up => shared(.page_diff_up),
        .page_down => shared(.page_diff_down),
        .copy_current_line => .copy_current_line,
        .copy_current_hunk => .copy_current_hunk,
        .branch_switch => .branch_switch_unavailable,
        .page_review, .page_repository, .page_compare, .page_config, .help, .reload, .repo_picker, .open_editor, .commit, .amend, .push, .pull, .fetch, .discard => null,
        else => unreachable,
    };
}

fn shared(msg: diff_surface.message.Msg) Msg {
    return .{ .shared = msg };
}

test "user binding wins over hardcoded base picker mnemonic" {
    var config: keymap.Config = .{};
    config.set(.branch_switch, .{ .plain_codepoint = 'm' });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(
        Msg.branch_switch_unavailable,
        keyToMsg(.{ .keymap = effective }, .{ .codepoint = 'm' }).?,
    );
    try std.testing.expectEqual(Msg.open_base_picker, keyToMsg(.{}, .{ .codepoint = 'm' }).?);
}

test "Compare exposes display actions but no write actions" {
    try std.testing.expectEqual(Msg{ .shared = .toggle_display_mode }, keyToMsg(.{}, .{ .codepoint = 'u' }).?);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 's' }) == null);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'P' }) == null);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'U' }) == null);
    try std.testing.expectEqual(Msg.branch_switch_unavailable, keyToMsg(.{}, .{ .codepoint = 'b' }).?);
}

test "Compare document navigation preserves Home End focus and custom bindings" {
    try std.testing.expectEqual(Msg{ .shared = .select_first_file }, keyToMsg(.{}, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(Msg{ .shared = .select_last_file }, keyToMsg(.{}, .{ .codepoint = chasen.Key.end }).?);
    try std.testing.expect(keyToMsg(.{ .focus = .sidebar }, .{ .codepoint = 'G' }) == null);
    try std.testing.expectEqual(Msg{ .shared = .document_first }, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'g' }).?);
    try std.testing.expectEqual(Msg{ .shared = .document_last }, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'G' }).?);
    try std.testing.expectEqual(Msg{ .shared = .half_page_up }, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'u', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(Msg{ .shared = .half_page_down }, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(Msg{ .shared = .page_diff_up }, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'b', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(Msg{ .shared = .page_diff_down }, keyToMsg(.{ .focus = .diff }, .{ .codepoint = 'f', .mods = .{ .ctrl = true } }).?);

    var config: keymap.Config = .{};
    config.set(.document_last, .{ .plain_codepoint = 'z' });
    const custom = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(Msg{ .shared = .document_last }, keyToMsg(.{ .focus = .diff, .keymap = custom }, .{ .codepoint = 'z' }).?);
    try std.testing.expect(keyToMsg(.{ .focus = .diff, .keymap = custom }, .{ .codepoint = 'G' }) == null);
}

test "Compare routes admitted retained actions through shared input" {
    const retained: Context = .{ .retained_selection_action_available = true };
    try std.testing.expectEqual(
        Msg{ .shared = .{ .selection_action = .copy } },
        keyToMsg(retained, .{ .codepoint = 'y' }).?,
    );
    try std.testing.expectEqual(
        Msg{ .shared = .{ .selection_action = .clear } },
        keyToMsg(retained, .{ .codepoint = chasen.Key.escape }).?,
    );
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = chasen.Key.escape }) == null);
    try std.testing.expectEqual(
        Msg{ .shared = .document_first },
        keyToMsg(.{ .focus = .diff, .retained_selection_action_available = true }, .{ .codepoint = 'g' }).?,
    );
}

test "Compare keyboard line selection maps side start and movement" {
    const normal: Context = .{ .focus = .diff, .side_by_side = true };
    try std.testing.expectEqual(Msg{ .shared = .{ .keyboard_select_side = .old } }, keyToMsg(normal, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(Msg{ .shared = .begin_keyboard_line_selection }, keyToMsg(normal, .{ .codepoint = 'V' }).?);

    const active: Context = .{ .selection_owner = .keyboard_line, .retained_selection_action_available = true };
    try std.testing.expectEqual(Msg{ .shared = .{ .keyboard_line_selection_move = .up } }, keyToMsg(active, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg{ .shared = .selection_action_unavailable }, keyToMsg(active, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(Msg{ .shared = .scroll_diff_right }, keyToMsg(.{
        .focus = .diff,
        .selection_owner = .keyboard_line,
    }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg{ .shared = .expand_directory }, keyToMsg(.{
        .focus = .sidebar,
        .selection_owner = .mouse,
    }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(Msg{ .shared = .collapse_or_parent_directory }, keyToMsg(.{
        .focus = .sidebar,
        .selection_owner = .header,
    }, .{ .codepoint = chasen.Key.left }).?);
}

test "base picker owns its modal grammar" {
    const context: Context = .{ .base_picker_open = true };
    try std.testing.expectEqual(Msg.base_picker_next, keyToMsg(context, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.base_picker_previous, keyToMsg(context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg.choose_base, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.close_base_picker, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.base_picker_enter_query, keyToMsg(context, .{ .codepoint = '/' }).?);
}

test "base picker query accepts printable command letters and uses two-step escape" {
    const query: Context = .{
        .base_picker_open = true,
        .base_picker_query_mode = true,
        .base_picker_query_len = 2,
    };
    try std.testing.expectEqual(Msg{ .base_picker_insert = '/' }, keyToMsg(query, .{ .codepoint = '/' }).?);
    try std.testing.expectEqual(Msg{ .base_picker_insert = 'j' }, keyToMsg(query, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg{ .base_picker_insert = 'k' }, keyToMsg(query, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg.base_picker_backspace, keyToMsg(query, .{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expectEqual(Msg.base_picker_leave_query, keyToMsg(query, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(Msg.base_picker_clear_query, keyToMsg(query, .{ .codepoint = chasen.Key.escape }).?);

    const retained_query: Context = .{ .base_picker_open = true, .base_picker_query_len = 2 };
    try std.testing.expectEqual(Msg.base_picker_clear_query, keyToMsg(retained_query, .{ .codepoint = chasen.Key.escape }).?);
}
