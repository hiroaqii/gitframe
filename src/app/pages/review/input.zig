//! Review-local input. Mutating Changes actions are intentionally absent.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const diff_surface = @import("../../diff_surface.zig");
const key_input = @import("../../key_input.zig");
const human_review_decision = @import("human_review_decision.zig");

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
    open_ai_reviews,
    close_ai_reviews,
    ai_reviews_cancel_loading,
    ai_reviews_enter_query,
    ai_reviews_leave_query,
    ai_reviews_clear_query_or_leave,
    ai_reviews_insert: u21,
    ai_reviews_backspace,
    ai_reviews_previous,
    ai_reviews_next,
    ai_reviews_activate,
    ai_reviews_refresh_or_retry,
    return_to_normal_review,
    copy_current_line,
    copy_current_hunk,
    branch_switch_unavailable,
    open_human_review_decision,
    human_review_decision: human_review_decision.Msg,
    finding_navigation: FindingNavigationIntent,
    finding_card: FindingCardMsg,
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
    leave,
    owned_noop,
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
    ai_reviews_open: bool = false,
    ai_reviews_query_mode: bool = false,
    ai_reviews_query_len: usize = 0,
    ai_reviews_loading: bool = false,
    pinned_ai: bool = false,
    human_review: human_review_decision.InputContext = .{},
    selection_owner: diff_surface.input.SelectionOwnerKind = .none,
    retained_selection_action_available: bool = false,
    finding_card_focused: bool = false,
    finding_card_at_cursor: bool = false,
    keymap: keymap.Effective = .{},

    fn shared(self: Context) diff_surface.input.Context {
        return .{
            .search_mode = self.search_mode,
            .file_search_mode = self.file_search_mode,
            .side_by_side = self.side_by_side,
            .selection_owner = self.selection_owner,
            .retained_selection_action_available = self.retained_selection_action_available,
            .keymap = self.keymap,
        };
    }
};

pub fn pasteToMsg(context: Context, text: []const u8) ?Msg {
    if (context.human_review.open) {
        return .{ .human_review_decision = human_review_decision.pasteToMsg(context.human_review, text) orelse return null };
    }
    if (context.finding_card_focused) return .{ .finding_card = .owned_noop };
    return .{ .shared = diff_surface.input.pasteToMsg(context.shared(), text) orelse return null };
}

pub fn keyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (context.human_review.open) {
        return .{ .human_review_decision = human_review_decision.keyToMsg(context.human_review, key) orelse return null };
    }
    if (context.ai_reviews_open) {
        if (key.matches(chasen.Key.escape, .{})) {
            if (context.ai_reviews_query_mode or context.ai_reviews_query_len > 0)
                return .ai_reviews_clear_query_or_leave;
            return if (context.ai_reviews_loading) .ai_reviews_cancel_loading else .close_ai_reviews;
        }
        if (key.matches(chasen.Key.enter, .{})) return .ai_reviews_activate;
        if (key.matches(chasen.Key.up, .{})) return .ai_reviews_previous;
        if (key.matches(chasen.Key.down, .{})) return .ai_reviews_next;
        if (context.ai_reviews_query_mode) {
            if (key.matches(chasen.Key.tab, .{})) return .ai_reviews_leave_query;
            if (key.matches(chasen.Key.backspace, .{})) return .ai_reviews_backspace;
            if (key_input.textInputCodepoint(key)) |codepoint| return .{ .ai_reviews_insert = codepoint };
            return null;
        }
        if (key.codepoint == '/') return .ai_reviews_enter_query;
        if (key.codepoint == 'q') return .close_ai_reviews;
        if (key.codepoint == 'r') return .ai_reviews_refresh_or_retry;
        if (key.codepoint == 'k') return .ai_reviews_previous;
        if (key.codepoint == 'j') return .ai_reviews_next;
        return null;
    }
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
    if (context.search_mode or context.file_search_mode) {
        return .{ .shared = diff_surface.input.keyToMsg(context.shared(), key) orelse return null };
    }
    if (selectionOwnsFindingNavigation(context, key)) return .{ .shared = .selection_owned_noop };
    if (context.finding_card_focused) {
        if (context.pinned_ai) {
            if (findingNavigationIntent(key)) |intent| return .{ .finding_navigation = intent };
        }
        return .{ .finding_card = findingCardKeyToMsg(key) };
    }
    if (diff_surface.input.keyToMsg(context.shared(), key)) |msg| return .{ .shared = msg };
    return normalKeyToMsg(context, key);
}

pub fn selectionKeyToMsg(context: Context, key: chasen.Key) ?Msg {
    if (!key_input.hasCommandModifier(key) and key.codepoint == 'a') return .open_ai_reviews;
    if (selectionOwnsFindingNavigation(context, key)) return .{ .shared = .selection_owned_noop };
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
    if (key.matches(chasen.Key.home, .{})) return shared(.select_first_file);
    if (key.matches(chasen.Key.end, .{})) return shared(.select_last_file);

    if (!key_input.hasCommandModifier(key) and key.codepoint == 'a') return .open_ai_reviews;

    // A user binding consumes the key even when it names an operation Review
    // intentionally does not expose. This is what lets a user-bound `m` win
    // over the page-local picker mnemonic.
    const finding_navigation = if (context.pinned_ai) findingNavigationIntent(key) else null;
    if (context.keymap.actionForKey(key)) |action| {
        if (finding_navigation) |intent| {
            const default_width_collision = switch (key_input.textInputCodepoint(key).?) {
                '[' => action == .decrease_sidebar_width,
                ']' => action == .increase_sidebar_width,
                else => false,
            };
            if (default_width_collision) return .{ .finding_navigation = intent };
        }
        return publicActionToMsg(action, context.focus == .diff);
    }
    if (finding_navigation) |intent| return .{ .finding_navigation = intent };

    if (context.finding_card_at_cursor and !key_input.hasCommandModifier(key) and key.codepoint == 's') {
        return .{ .finding_card = .focus_or_cycle };
    }

    if (context.pinned_ai and key_input.matchesShiftedAscii(key, 'e', 'E')) {
        return .open_human_review_decision;
    }

    if (context.focus == .diff and key_input.matchesShiftedAscii(key, 'v', 'V')) return shared(.begin_keyboard_line_selection);

    if (key_input.matchesShiftedAscii(key, 'j', 'J')) return if (context.focus == .diff) shared(.select_next_hunk) else null;
    if (key_input.matchesShiftedAscii(key, 'k', 'K')) return if (context.focus == .diff) shared(.select_previous_hunk) else null;
    if (key_input.matchesShiftedAscii(key, 'n', 'N')) {
        return if (context.search_query_len > 0) shared(.select_previous_search_match) else null;
    }
    if (key_input.hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'm' => if (context.pinned_ai) .return_to_normal_review else .open_base_picker,
        'k', chasen.Key.up => if (context.focus == .diff) shared(.scroll_diff_up) else shared(.select_previous_file),
        'j', chasen.Key.down => if (context.focus == .diff) shared(.scroll_diff_down) else shared(.select_next_file),
        'n' => if (context.search_query_len > 0) shared(.select_next_search_match) else shared(.select_next_hunk),
        'p' => if (context.search_query_len > 0) shared(.select_previous_search_match) else shared(.select_previous_hunk),
        else => null,
    };
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
        (context.selection_owner != .none or context.retained_selection_action_available);
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
        'q' => .leave,
        else => .owned_noop,
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
        .page_changes, .page_repository, .page_review, .page_config, .help, .reload, .repo_picker, .open_editor, .commit, .amend, .push, .pull, .fetch, .discard => null,
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

test "Review exposes display actions but no write actions" {
    try std.testing.expectEqual(Msg{ .shared = .toggle_display_mode }, keyToMsg(.{}, .{ .codepoint = 'u' }).?);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 's' }) == null);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'P' }) == null);
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'U' }) == null);
    try std.testing.expectEqual(Msg.branch_switch_unavailable, keyToMsg(.{}, .{ .codepoint = 'b' }).?);
}

test "Review inline Finding card owns its local grammar" {
    const available: Context = .{ .focus = .diff, .finding_card_at_cursor = true };
    try std.testing.expectEqual(
        Msg{ .finding_card = .focus_or_cycle },
        keyToMsg(available, .{ .codepoint = 's' }).?,
    );
    const focused: Context = .{ .finding_card_focused = true };
    try std.testing.expectEqual(Msg{ .finding_card = .toggle }, keyToMsg(focused, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .copy }, keyToMsg(focused, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .leave }, keyToMsg(focused, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .owned_noop }, keyToMsg(focused, .{ .codepoint = '1' }).?);
}

test "human review result uses unclaimed uppercase E after public key precedence" {
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = 'E' }) == null);
    const pinned: Context = .{ .pinned_ai = true };
    try std.testing.expectEqual(
        Msg.open_human_review_decision,
        keyToMsg(pinned, .{ .codepoint = 'E' }).?,
    );
    try std.testing.expectEqual(
        Msg.open_human_review_decision,
        keyToMsg(pinned, .{ .codepoint = 'e', .mods = .{ .shift = true } }).?,
    );
    try std.testing.expect(keyToMsg(pinned, .{ .codepoint = 'e' }) == null);

    var config: keymap.Config = .{};
    config.set(.toggle_line_numbers, .{ .plain_codepoint = 'E' });
    const claimed: Context = .{
        .pinned_ai = true,
        .keymap = keymap.Effective.fromConfig(config),
    };
    try std.testing.expectEqual(
        Msg{ .shared = .toggle_line_numbers },
        keyToMsg(claimed, .{ .codepoint = 'E' }).?,
    );
}

test "human review result modal consumes close keys and summary paste" {
    try std.testing.expectEqual(
        Msg{ .human_review_decision = .close },
        keyToMsg(.{ .human_review = .{ .open = true } }, .{ .codepoint = 'q' }).?,
    );
    try std.testing.expectEqual(
        Msg{ .human_review_decision = .{ .summary_paste = "要約" } },
        pasteToMsg(.{ .human_review = .{ .open = true, .focus = .summary, .summary_editing = true } }, "要約").?,
    );
    try std.testing.expect(pasteToMsg(.{ .human_review = .{ .open = true } }, "hidden") == null);
}

test "Review inline Finding focus owns its complete input grammar" {
    const focused: Context = .{ .finding_card_focused = true };
    try std.testing.expectEqual(Msg{ .finding_card = .focus_or_cycle }, keyToMsg(focused, .{ .codepoint = 's' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .toggle }, keyToMsg(focused, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .scroll_down }, keyToMsg(focused, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .scroll_up }, keyToMsg(focused, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .copy }, keyToMsg(focused, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .leave }, keyToMsg(focused, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .owned_noop }, keyToMsg(focused, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(Msg{ .finding_card = .owned_noop }, pasteToMsg(focused, "ignored").?);

    const at_cursor: Context = .{ .focus = .diff, .finding_card_at_cursor = true };
    try std.testing.expectEqual(Msg{ .finding_card = .focus_or_cycle }, keyToMsg(at_cursor, .{ .codepoint = 's' }).?);
}

test "Finding navigation owns exact four-key Review grammar without stealing priority" {
    const pinned: Context = .{ .pinned_ai = true };
    const cases = [_]struct { key: chasen.Key, intent: FindingNavigationIntent }{
        .{ .key = .{ .codepoint = '[' }, .intent = .{ .scope = .current_file, .direction = .previous } },
        .{ .key = .{ .codepoint = ']' }, .intent = .{ .scope = .current_file, .direction = .next } },
        .{ .key = .{ .codepoint = '[', .mods = .{ .shift = true }, .shifted_codepoint = '{' }, .intent = .{ .scope = .all_files, .direction = .previous } },
        .{ .key = .{ .codepoint = ']', .mods = .{ .shift = true }, .shifted_codepoint = '}' }, .intent = .{ .scope = .all_files, .direction = .next } },
    };
    for (cases) |case| {
        try std.testing.expectEqual(Msg{ .finding_navigation = case.intent }, keyToMsg(pinned, case.key).?);
        try std.testing.expectEqual(
            Msg{ .finding_navigation = case.intent },
            keyToMsg(.{ .pinned_ai = true, .finding_card_focused = true }, case.key).?,
        );
        try std.testing.expectEqual(
            Msg{ .shared = .selection_owned_noop },
            keyToMsg(.{ .pinned_ai = true, .finding_card_focused = true, .selection_owner = .mouse }, case.key).?,
        );
        try std.testing.expectEqual(
            Msg{ .shared = .selection_owned_noop },
            selectionKeyToMsg(.{ .pinned_ai = true, .retained_selection_action_available = true }, case.key).?,
        );
    }

    try std.testing.expectEqual(Msg{ .shared = .decrease_sidebar_width }, keyToMsg(.{}, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(Msg{ .shared = .increase_sidebar_width }, keyToMsg(.{}, .{ .codepoint = ']' }).?);
    try std.testing.expectEqual(
        Msg{ .finding_card = .owned_noop },
        keyToMsg(.{ .finding_card_focused = true }, .{ .codepoint = '[' }).?,
    );
    try std.testing.expect(keyToMsg(.{}, .{ .codepoint = '{' }) == null);
    try std.testing.expect(keyToMsg(pinned, .{ .codepoint = '[', .mods = .{ .ctrl = true } }) == null);
    try std.testing.expectEqual(Msg{ .shared = .{ .search_insert = '[' } }, keyToMsg(.{
        .pinned_ai = true,
        .finding_card_focused = true,
        .search_mode = true,
    }, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(Msg{ .shared = .{ .file_search_insert = '[' } }, keyToMsg(.{
        .pinned_ai = true,
        .finding_card_focused = true,
        .file_search_mode = true,
    }, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(Msg{ .base_picker_insert = '[' }, keyToMsg(.{
        .pinned_ai = true,
        .finding_card_focused = true,
        .base_picker_open = true,
        .base_picker_query_mode = true,
    }, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(Msg{ .human_review_decision = .{ .summary_edit = .{ .insert = '[' } } }, keyToMsg(.{
        .pinned_ai = true,
        .finding_card_focused = true,
        .human_review = .{ .open = true, .focus = .summary, .summary_editing = true },
    }, .{ .codepoint = '[' }).?);
    try std.testing.expect(keyToMsg(.{ .pinned_ai = true, .ai_reviews_open = true }, .{ .codepoint = '[' }) == null);

    var config: keymap.Config = .{};
    config.set(.decrease_sidebar_width, .{ .plain_codepoint = 'z' });
    config.set(.toggle_line_numbers, .{ .plain_codepoint = '[' });
    try std.testing.expect(keymap.validateConfig(config));
    const rebound: Context = .{ .pinned_ai = true, .keymap = keymap.Effective.fromConfig(config) };
    try std.testing.expectEqual(Msg{ .shared = .toggle_line_numbers }, keyToMsg(rebound, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(Msg{ .shared = .decrease_sidebar_width }, keyToMsg(rebound, .{ .codepoint = 'z' }).?);
    try std.testing.expectEqual(
        Msg{ .finding_navigation = .{ .scope = .current_file, .direction = .previous } },
        keyToMsg(.{ .pinned_ai = true, .finding_card_focused = true, .keymap = rebound.keymap }, .{ .codepoint = '[' }).?,
    );

    try std.testing.expectEqual(Msg{ .shared = .select_next_hunk }, keyToMsg(pinned, .{ .codepoint = 'n' }).?);
    try std.testing.expectEqual(Msg{ .shared = .select_previous_hunk }, keyToMsg(pinned, .{ .codepoint = 'p' }).?);
    try std.testing.expect(keyToMsg(pinned, .{ .codepoint = 's' }) == null);
}

test "Review document navigation preserves Home End focus and custom bindings" {
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

test "Review routes admitted retained actions through shared input" {
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

test "Review keyboard line selection maps side start and movement" {
    const normal: Context = .{ .focus = .diff, .side_by_side = true };
    try std.testing.expect(keyToMsg(normal, .{ .codepoint = 'h' }) == null);
    try std.testing.expectEqual(Msg{ .shared = .begin_keyboard_line_selection }, keyToMsg(normal, .{ .codepoint = 'V' }).?);

    const active: Context = .{ .selection_owner = .keyboard_line, .retained_selection_action_available = true };
    try std.testing.expectEqual(Msg{ .shared = .{ .keyboard_line_selection_move = .up } }, keyToMsg(active, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(Msg{ .shared = .selection_action_unavailable }, keyToMsg(active, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(Msg{ .shared = .{ .switch_keyboard_selection_side = .new } }, keyToMsg(.{
        .focus = .diff,
        .side_by_side = true,
        .selection_owner = .keyboard_line,
    }, .{ .codepoint = chasen.Key.right }).?);
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

    try std.testing.expectEqual(Msg{ .shared = .{ .choose_keyboard_selection_side = .old } }, keyToMsg(.{
        .focus = .diff,
        .side_by_side = true,
        .selection_owner = .keyboard_side_choice,
    }, .{ .codepoint = 'h' }).?);
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

test "AI Reviews picker fixed a precedence and normal versus pinned m semantics" {
    const retained: Context = .{ .selection_owner = .keyboard_line, .retained_selection_action_available = true };
    try std.testing.expectEqual(Msg.open_ai_reviews, selectionKeyToMsg(retained, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(Msg.open_ai_reviews, keyToMsg(.{}, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(Msg.open_base_picker, keyToMsg(.{}, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(Msg.return_to_normal_review, keyToMsg(.{ .pinned_ai = true }, .{ .codepoint = 'm' }).?);
}

test "AI Reviews picker owns command query loading and two-step escape grammar" {
    const command: Context = .{ .ai_reviews_open = true };
    try std.testing.expectEqual(Msg.ai_reviews_next, keyToMsg(command, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(Msg.ai_reviews_previous, keyToMsg(command, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(Msg.ai_reviews_activate, keyToMsg(command, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(Msg.ai_reviews_refresh_or_retry, keyToMsg(command, .{ .codepoint = 'r' }).?);
    try std.testing.expectEqual(Msg.ai_reviews_enter_query, keyToMsg(command, .{ .codepoint = '/' }).?);
    try std.testing.expectEqual(Msg.close_ai_reviews, keyToMsg(command, .{ .codepoint = chasen.Key.escape }).?);

    const query: Context = .{ .ai_reviews_open = true, .ai_reviews_query_mode = true, .ai_reviews_query_len = 2 };
    try std.testing.expectEqual(Msg{ .ai_reviews_insert = 'r' }, keyToMsg(query, .{ .codepoint = 'r' }).?);
    try std.testing.expectEqual(Msg.ai_reviews_backspace, keyToMsg(query, .{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expectEqual(Msg.ai_reviews_leave_query, keyToMsg(query, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(Msg.ai_reviews_clear_query_or_leave, keyToMsg(query, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(Msg.ai_reviews_cancel_loading, keyToMsg(.{
        .ai_reviews_open = true,
        .ai_reviews_loading = true,
    }, .{ .codepoint = chasen.Key.escape }).?);
}
