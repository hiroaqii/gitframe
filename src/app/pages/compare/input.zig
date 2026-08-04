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
    base_picker_open: bool = false,
    keymap: keymap.Effective = .{},

    fn shared(self: Context) diff_surface.input.Context {
        return .{ .search_mode = self.search_mode, .file_search_mode = self.file_search_mode };
    }
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    return .{ .shared = diff_surface.input.pasteToMsg(context.shared(), text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.base_picker_open) {
        if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return .close_base_picker;
        if (key.matches(chasen.Key.enter, .{})) return .choose_base;
        if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return .base_picker_previous;
        if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return .base_picker_next;
        return null;
    }
    if (context.search_mode or context.file_search_mode) {
        return .{ .shared = diff_surface.input.keyToMsg(context.shared(), key) orelse return null };
    }
    return normalKeyToMsg(context, key);
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
    if (key.matches(chasen.Key.home, .{})) return shared(.select_first_file);
    if (key.matches(chasen.Key.end, .{})) return shared(.select_last_file);

    // A user binding consumes the key even when it names an operation Compare
    // intentionally does not expose. This is what lets a user-bound `m` win
    // over the page-local picker mnemonic.
    if (context.keymap.actionForKey(key)) |action| return publicActionToMsg(action);

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

fn publicActionToMsg(action: keymap.PublicAction) ?Msg {
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
        .first_file => shared(.select_first_file),
        .last_file => shared(.select_last_file),
        .page_up => shared(.page_diff_up),
        .page_down => shared(.page_diff_down),
        .copy_current_line => .copy_current_line,
        .copy_current_hunk => .copy_current_hunk,
        .branch_switch => .branch_switch_unavailable,
        .page_review, .page_repository, .page_compare, .page_config, .help, .reload, .repo_picker, .open_editor, .commit, .amend, .push, .pull, .fetch, .discard => null,
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

test "base picker owns its modal grammar" {
    const context: Context = .{ .base_picker_open = true };
    try std.testing.expectEqual(Msg.base_picker_next, keyToMsg(context, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.base_picker_previous, keyToMsg(context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg.choose_base, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.close_base_picker, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
}
