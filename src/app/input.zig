const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const app_prompt = @import("prompt.zig");

/// App focus state used by key mapping. The state lives on App, but the
/// transition vocabulary belongs with input handling.
pub const Focus = enum {
    sidebar,
    diff,

    pub fn toggled(self: Focus) Focus {
        return switch (self) {
            .sidebar => .diff,
            .diff => .sidebar,
        };
    }
};

/// Minimal snapshot needed to translate a terminal key into an App message.
/// Keeping this small prevents input mapping from depending on full App state.
pub const KeyContext = struct {
    search_mode: bool = false,
    file_search_mode: bool = false,
    commit_panel_mode: bool = false,
    repo_picker_mode: bool = false,
    repo_picker_input_mode: app_prompt.RepoPickerInputMode = .list,
    help_mode: bool = false,
    discard_confirmation_mode: bool = false,
    amend_confirmation_mode: bool = false,
    push_confirmation_mode: bool = false,
    push_error_mode: bool = false,
    push_credential_mode: bool = false,
    search_query_len: usize = 0,
    focus: Focus = .sidebar,
    sidebar_hidden: bool = false,
    review_mode: bool = false,
    keymap: keymap.Effective = .{},
};

const Action = enum {
    cancel_search,
    submit_search,
    search_backspace,
    search_move_left,
    search_move_right,
    cancel_file_search,
    submit_file_search,
    file_search_backspace,
    cancel_commit_panel,
    submit_commit_panel,
    commit_panel_tab,
    commit_panel_enter,
    commit_panel_backspace,
    commit_panel_move_left,
    commit_panel_move_right,
    commit_panel_move_up,
    commit_panel_move_down,
    cancel_repo_picker,
    close_repo_picker,
    submit_repo_picker,
    repo_picker_enter_filter_input,
    repo_picker_enter_path_input,
    repo_picker_back,
    repo_picker_remove_recent,
    repo_picker_backspace,
    repo_picker_move_previous,
    repo_picker_move_next,
    repo_picker_move_left,
    repo_picker_move_right,
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
    close_help,
    help_scroll_up,
    help_scroll_down,
    help_page_up,
    help_page_down,
    push_error_scroll_up,
    push_error_scroll_down,
    push_error_page_up,
    push_error_page_down,
    push_credential_tab,
    push_credential_submit,
    push_credential_cancel,
    push_credential_backspace,
    push_credential_move_left,
    push_credential_move_right,
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
    stage_selected_file,
    stage_selected_hunk,
    unstage_selected_file,
    unstage_selected_hunk,
    request_discard_selected_file,
    confirm_discard_file,
    cancel_discard_file,
    confirm_amend,
    cancel_amend,
    request_push,
    confirm_push,
    cancel_push,
    close_push_error,
    open_push_credentials,
    run_interactive_push,
    open_selected_file_in_editor,
    toggle_display_mode,
    toggle_line_numbers,
    finish_review_approved,
    finish_review_needs_changes,
    finish_review_canceled,
    quit,
    reload,
};

pub fn eventToMsg(comptime Msg: type, context: KeyContext, event: chasen.Event) ?Msg {
    return switch (event) {
        .key_press => |key| keyToMsg(Msg, context, key),
        .paste => |text| pasteToMsg(Msg, context, text),
        .winsize => |winsize| payloadMsg(Msg, "terminal_resized", chasen.Size{
            .width = winsize.cols,
            .height = winsize.rows,
        }),
        else => null,
    };
}

fn pasteToMsg(comptime Msg: type, context: KeyContext, text: []const u8) ?Msg {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    if (context.search_mode) return payloadMsg(Msg, "search_paste", text);
    if (context.file_search_mode) return payloadMsg(Msg, "file_search_paste", text);
    if (context.repo_picker_mode) return payloadMsg(Msg, "repo_picker_paste", text);
    if (context.push_credential_mode) return payloadMsg(Msg, "push_credential_paste", text);
    if (context.help_mode or context.discard_confirmation_mode or context.amend_confirmation_mode or context.push_confirmation_mode or context.push_error_mode) return null;
    if (context.commit_panel_mode) return payloadMsg(Msg, "commit_panel_paste", text);
    return null;
}

pub fn keyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (context.search_mode) return searchKeyToMsg(Msg, key);
    if (context.file_search_mode) return fileSearchKeyToMsg(Msg, key);
    if (context.repo_picker_mode) return repoPickerKeyToMsg(Msg, context, key);
    if (context.help_mode) return helpKeyToMsg(Msg, context, key);
    if (context.discard_confirmation_mode) return discardConfirmationKeyToMsg(Msg, key);
    if (context.amend_confirmation_mode) return amendConfirmationKeyToMsg(Msg, key);
    if (context.push_confirmation_mode) return pushConfirmationKeyToMsg(Msg, key);
    if (context.push_error_mode) return pushErrorKeyToMsg(Msg, key);
    if (context.push_credential_mode) return pushCredentialKeyToMsg(Msg, key);
    if (context.commit_panel_mode) return commitPanelKeyToMsg(Msg, key);
    return viewerKeyToMsg(Msg, context, key);
}

fn searchKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .cancel_search);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .submit_search);
    if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .search_backspace);
    if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .search_move_left);
    if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .search_move_right);
    if (textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "search_insert", codepoint);
    return null;
}

fn fileSearchKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .cancel_file_search);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .submit_file_search);
    if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .file_search_backspace);
    if (textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "file_search_insert", codepoint);
    return null;
}

fn repoPickerKeyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .cancel_repo_picker);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .submit_repo_picker);

    switch (context.repo_picker_input_mode) {
        .list => {
            if (key.codepoint == 'q' and !hasCommandModifier(key)) return actionToMsg(Msg, .close_repo_picker);
            if (key.codepoint == '/' and !hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_enter_filter_input);
            if (key.codepoint == 'p' and !hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_enter_path_input);
            if (key.codepoint == 'b' and !hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_back);
            if (key.codepoint == 'd' and !hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_remove_recent);
            if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return actionToMsg(Msg, .repo_picker_move_previous);
            if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return actionToMsg(Msg, .repo_picker_move_next);
        },
        .filter => {
            if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .repo_picker_backspace);
            if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .repo_picker_move_left);
            if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .repo_picker_move_right);
            if (key.matches(chasen.Key.up, .{})) return actionToMsg(Msg, .repo_picker_move_previous);
            if (key.matches(chasen.Key.down, .{})) return actionToMsg(Msg, .repo_picker_move_next);
            if (textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "repo_picker_insert", codepoint);
        },
        .path_input => {
            if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .repo_picker_backspace);
            if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .repo_picker_move_left);
            if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .repo_picker_move_right);
            if (key.matches(chasen.Key.up, .{}) or key.matches(chasen.Key.down, .{})) return null;
            if (textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "repo_picker_insert", codepoint);
        },
    }
    return null;
}

fn helpKeyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (context.keymap.spec(.help).matches(key)) return actionToMsg(Msg, .close_help);
    if (context.keymap.spec(.commit).matches(key)) return actionToMsg(Msg, .enter_commit_panel);
    if (helpActionForKey(key)) |action| return actionToMsg(Msg, action);
    return null;
}

fn discardConfirmationKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .cancel_discard_file);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .confirm_discard_file);
    return null;
}

fn amendConfirmationKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .cancel_amend);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .confirm_amend);
    return null;
}

fn pushConfirmationKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .cancel_push);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .confirm_push);
    return null;
}

fn pushErrorKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.matches(chasen.Key.enter, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .close_push_error);
    if (key.codepoint == 'c' and !hasCommandModifier(key)) return actionToMsg(Msg, .open_push_credentials);
    if (key.codepoint == 'i' and !hasCommandModifier(key)) return actionToMsg(Msg, .run_interactive_push);
    if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return actionToMsg(Msg, .push_error_scroll_up);
    if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return actionToMsg(Msg, .push_error_scroll_down);
    if (key.matches(chasen.Key.page_up, .{})) return actionToMsg(Msg, .push_error_page_up);
    if (key.matches(chasen.Key.page_down, .{})) return actionToMsg(Msg, .push_error_page_down);
    return null;
}

fn pushCredentialKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .push_credential_cancel);
    if (key.matches(chasen.Key.tab, .{})) return actionToMsg(Msg, .push_credential_tab);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .push_credential_submit);
    if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .push_credential_backspace);
    if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .push_credential_move_left);
    if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .push_credential_move_right);
    if (textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "push_credential_insert", codepoint);
    return null;
}

fn commitPanelKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .cancel_commit_panel);
    if (key.matches(chasen.Key.enter, .{ .ctrl = true }) or key.matches('s', .{ .ctrl = true })) return actionToMsg(Msg, .submit_commit_panel);
    if (key.matches(chasen.Key.tab, .{})) return actionToMsg(Msg, .commit_panel_tab);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .commit_panel_enter);
    if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .commit_panel_backspace);
    if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .commit_panel_move_left);
    if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .commit_panel_move_right);
    if (key.matches(chasen.Key.up, .{})) return actionToMsg(Msg, .commit_panel_move_up);
    if (key.matches(chasen.Key.down, .{})) return actionToMsg(Msg, .commit_panel_move_down);
    if (textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "commit_panel_insert", codepoint);
    return null;
}

fn viewerKeyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.tab, .{}) and !context.sidebar_hidden) return actionToMsg(Msg, .toggle_focus);
    if (key.matches(chasen.Key.escape, .{}) and context.search_query_len > 0) return actionToMsg(Msg, .clear_search);
    if (context.focus == .sidebar and key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .toggle_directory);
    if (context.focus == .diff and key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .toggle_hunk_fold);
    if (context.focus == .sidebar and key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .expand_directory);
    if (context.focus == .sidebar and key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .collapse_or_parent_directory);
    if (context.focus == .diff and key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .scroll_diff_right);
    if (context.focus == .diff and key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .scroll_diff_left);
    if (context.focus == .sidebar and key.matches('h', .{})) return actionToMsg(Msg, .scroll_sidebar_left);
    if (context.focus == .sidebar and key.matches('l', .{})) return actionToMsg(Msg, .scroll_sidebar_right);
    if (key.matches(chasen.Key.home, .{})) return actionToMsg(Msg, .select_first_file);
    if (key.matches(chasen.Key.end, .{})) return actionToMsg(Msg, .select_last_file);

    if (viewerActionForStaticKey(context.keymap, key)) |action| return actionToMsg(Msg, action);

    if (matchesShiftedAscii(key, 'j', 'J')) {
        return if (context.focus == .diff) actionToMsg(Msg, .select_next_hunk) else null;
    }
    if (matchesShiftedAscii(key, 'k', 'K')) {
        return if (context.focus == .diff) actionToMsg(Msg, .select_previous_hunk) else null;
    }
    if (matchesShiftedAscii(key, 'n', 'N')) {
        if (context.search_query_len > 0) return actionToMsg(Msg, .select_previous_search_match);
        return if (context.review_mode) actionToMsg(Msg, .finish_review_needs_changes) else null;
    }
    if (matchesShiftedAscii(key, 's', 'S')) return null;
    if (context.review_mode and key.matches('a', .{})) return actionToMsg(Msg, .finish_review_approved);
    if (hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'k', chasen.Key.up => if (context.focus == .diff) actionToMsg(Msg, .scroll_diff_up) else actionToMsg(Msg, .select_previous_file),
        'j', chasen.Key.down => if (context.focus == .diff) actionToMsg(Msg, .scroll_diff_down) else actionToMsg(Msg, .select_next_file),
        'n' => if (context.search_query_len > 0) actionToMsg(Msg, .select_next_search_match) else actionToMsg(Msg, .select_next_hunk),
        'p' => if (context.search_query_len > 0) actionToMsg(Msg, .select_previous_search_match) else actionToMsg(Msg, .select_previous_hunk),
        's' => if (context.focus == .diff) actionToMsg(Msg, .toggle_selected_hunk) else actionToMsg(Msg, .toggle_selected_file),
        'q' => if (context.review_mode) actionToMsg(Msg, .finish_review_canceled) else actionToMsg(Msg, .quit),
        else => null,
    };
}

const KeyMatcher = union(enum) {
    plain_codepoint: u21,
    exact: u21,
    shifted_ascii: struct {
        lower: u21,
        upper: u21,
    },

    fn matches(self: KeyMatcher, key: chasen.Key) bool {
        return switch (self) {
            .plain_codepoint => |codepoint| !hasCommandModifier(key) and key.codepoint == codepoint,
            .exact => |codepoint| key.matches(codepoint, .{}),
            .shifted_ascii => |ascii| matchesShiftedAscii(key, ascii.lower, ascii.upper),
        };
    }
};

const KeyBinding = struct {
    matcher: KeyMatcher,
    action: Action,
};

const help_bindings = [_]KeyBinding{
    .{ .matcher = .{ .exact = chasen.Key.escape }, .action = .close_help },
    .{ .matcher = .{ .plain_codepoint = 'q' }, .action = .close_help },
    .{ .matcher = .{ .exact = chasen.Key.page_up }, .action = .help_page_up },
    .{ .matcher = .{ .exact = chasen.Key.page_down }, .action = .help_page_down },
    .{ .matcher = .{ .exact = chasen.Key.up }, .action = .help_scroll_up },
    .{ .matcher = .{ .exact = chasen.Key.down }, .action = .help_scroll_down },
    .{ .matcher = .{ .plain_codepoint = 'k' }, .action = .help_scroll_up },
    .{ .matcher = .{ .plain_codepoint = 'j' }, .action = .help_scroll_down },
};

// Static configurable bindings are safe to evaluate without focus/search state.
// Context-dependent keys (s/S, n/N, q, Tab, Esc, Enter, arrows) stay in
// viewerKeyToMsg and are deliberately not exposed by the first keymap slice.
fn viewerActionForStaticKey(effective: keymap.Effective, key: chasen.Key) ?Action {
    const public_action = effective.actionForKey(key) orelse return null;
    return publicActionToAction(public_action);
}

fn helpActionForKey(key: chasen.Key) ?Action {
    return actionForKey(&help_bindings, key);
}

fn actionForKey(bindings: []const KeyBinding, key: chasen.Key) ?Action {
    for (bindings) |binding| {
        if (binding.matcher.matches(key)) return binding.action;
    }
    return null;
}

fn publicActionToAction(action: keymap.PublicAction) Action {
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
    };
}

/// Match an ASCII Shift-letter command across terminals that report either
/// uppercase codepoints or lowercase codepoints with the shift modifier set.
fn matchesShiftedAscii(key: chasen.Key, lower: u21, upper: u21) bool {
    if (hasCommandModifier(key)) return false;
    return key.matches(upper, .{}) or (key.codepoint == lower and key.mods.shift);
}

fn hasCommandModifier(key: chasen.Key) bool {
    return key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta;
}

fn textInputCodepoint(key: chasen.Key) ?u21 {
    if (key.isModifier()) return null;
    if (hasCommandModifier(key)) return null;
    if (keyTextCodepoint(key)) |codepoint| return codepoint;
    if (key.mods.shift) {
        if (key.shifted_codepoint) |codepoint| {
            if (isPrintableCodepoint(codepoint)) return codepoint;
        }
    }
    if (key.codepoint == chasen.Key.multicodepoint) return null;
    if (isVaxisSpecialCodepoint(key.codepoint)) return null;
    if (!isPrintableCodepoint(key.codepoint)) return null;
    return key.codepoint;
}

fn keyTextCodepoint(key: chasen.Key) ?u21 {
    const text = key.text orelse return null;
    if (text.len == 0) return null;

    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len != text.len) return null;

    const codepoint = std.unicode.utf8Decode(text) catch return null;
    if (!isPrintableCodepoint(codepoint)) return null;
    return codepoint;
}

// Vaxis encodes non-text special keys in this private-use range. Treat them as
// non-text unless the event also carries printable key.text.
fn isVaxisSpecialCodepoint(codepoint: u21) bool {
    return codepoint >= chasen.Key.insert and codepoint <= chasen.Key.iso_level_5_shift;
}

fn isPrintableCodepoint(codepoint: u21) bool {
    return codepoint >= 0x20 and codepoint != 0x7f and !(codepoint >= 0x80 and codepoint <= 0x9f);
}

fn actionToMsg(comptime Msg: type, action: Action) Msg {
    return switch (action) {
        .cancel_search => voidMsg(Msg, "cancel_search"),
        .submit_search => voidMsg(Msg, "submit_search"),
        .search_backspace => voidMsg(Msg, "search_backspace"),
        .search_move_left => voidMsg(Msg, "search_move_left"),
        .search_move_right => voidMsg(Msg, "search_move_right"),
        .cancel_file_search => voidMsg(Msg, "cancel_file_search"),
        .submit_file_search => voidMsg(Msg, "submit_file_search"),
        .file_search_backspace => voidMsg(Msg, "file_search_backspace"),
        .cancel_commit_panel => voidMsg(Msg, "cancel_commit_panel"),
        .submit_commit_panel => voidMsg(Msg, "submit_commit_panel"),
        .commit_panel_tab => voidMsg(Msg, "commit_panel_tab"),
        .commit_panel_enter => voidMsg(Msg, "commit_panel_enter"),
        .commit_panel_backspace => voidMsg(Msg, "commit_panel_backspace"),
        .commit_panel_move_left => voidMsg(Msg, "commit_panel_move_left"),
        .commit_panel_move_right => voidMsg(Msg, "commit_panel_move_right"),
        .commit_panel_move_up => voidMsg(Msg, "commit_panel_move_up"),
        .commit_panel_move_down => voidMsg(Msg, "commit_panel_move_down"),
        .cancel_repo_picker => voidMsg(Msg, "cancel_repo_picker"),
        .close_repo_picker => voidMsg(Msg, "close_repo_picker"),
        .submit_repo_picker => voidMsg(Msg, "submit_repo_picker"),
        .repo_picker_enter_filter_input => voidMsg(Msg, "repo_picker_enter_filter_input"),
        .repo_picker_enter_path_input => voidMsg(Msg, "repo_picker_enter_path_input"),
        .repo_picker_back => voidMsg(Msg, "repo_picker_back"),
        .repo_picker_remove_recent => voidMsg(Msg, "repo_picker_remove_recent"),
        .repo_picker_backspace => voidMsg(Msg, "repo_picker_backspace"),
        .repo_picker_move_previous => voidMsg(Msg, "repo_picker_move_previous"),
        .repo_picker_move_next => voidMsg(Msg, "repo_picker_move_next"),
        .repo_picker_move_left => voidMsg(Msg, "repo_picker_move_left"),
        .repo_picker_move_right => voidMsg(Msg, "repo_picker_move_right"),
        .toggle_focus => voidMsg(Msg, "toggle_focus"),
        .page_diff_up => voidMsg(Msg, "page_diff_up"),
        .page_diff_down => voidMsg(Msg, "page_diff_down"),
        .select_first_file => voidMsg(Msg, "select_first_file"),
        .select_last_file => voidMsg(Msg, "select_last_file"),
        .clear_search => voidMsg(Msg, "clear_search"),
        .toggle_directory => voidMsg(Msg, "toggle_directory"),
        .toggle_hunk_fold => voidMsg(Msg, "toggle_hunk_fold"),
        .expand_directory => voidMsg(Msg, "expand_directory"),
        .collapse_or_parent_directory => voidMsg(Msg, "collapse_or_parent_directory"),
        .scroll_diff_right => voidMsg(Msg, "scroll_diff_right"),
        .scroll_diff_left => voidMsg(Msg, "scroll_diff_left"),
        .scroll_sidebar_right => voidMsg(Msg, "scroll_sidebar_right"),
        .scroll_sidebar_left => voidMsg(Msg, "scroll_sidebar_left"),
        .scroll_diff_up => voidMsg(Msg, "scroll_diff_up"),
        .select_previous_file => voidMsg(Msg, "select_previous_file"),
        .scroll_diff_down => voidMsg(Msg, "scroll_diff_down"),
        .select_next_file => voidMsg(Msg, "select_next_file"),
        .enter_search => voidMsg(Msg, "enter_search"),
        .select_next_search_match => voidMsg(Msg, "select_next_search_match"),
        .select_next_hunk => voidMsg(Msg, "select_next_hunk"),
        .select_previous_search_match => voidMsg(Msg, "select_previous_search_match"),
        .select_previous_hunk => voidMsg(Msg, "select_previous_hunk"),
        .enter_file_search => voidMsg(Msg, "enter_file_search"),
        .enter_repo_picker => voidMsg(Msg, "enter_repo_picker"),
        .open_help => voidMsg(Msg, "open_help"),
        .close_help => voidMsg(Msg, "close_help"),
        .help_scroll_up => voidMsg(Msg, "help_scroll_up"),
        .help_scroll_down => voidMsg(Msg, "help_scroll_down"),
        .help_page_up => voidMsg(Msg, "help_page_up"),
        .help_page_down => voidMsg(Msg, "help_page_down"),
        .push_error_scroll_up => voidMsg(Msg, "push_error_scroll_up"),
        .push_error_scroll_down => voidMsg(Msg, "push_error_scroll_down"),
        .push_error_page_up => voidMsg(Msg, "push_error_page_up"),
        .push_error_page_down => voidMsg(Msg, "push_error_page_down"),
        .push_credential_tab => voidMsg(Msg, "push_credential_tab"),
        .push_credential_submit => voidMsg(Msg, "push_credential_submit"),
        .push_credential_cancel => voidMsg(Msg, "push_credential_cancel"),
        .push_credential_backspace => voidMsg(Msg, "push_credential_backspace"),
        .push_credential_move_left => voidMsg(Msg, "push_credential_move_left"),
        .push_credential_move_right => voidMsg(Msg, "push_credential_move_right"),
        .cycle_changed_file_filter => voidMsg(Msg, "cycle_changed_file_filter"),
        .toggle_reviewed_file => voidMsg(Msg, "toggle_reviewed_file"),
        .toggle_hide_reviewed_files => voidMsg(Msg, "toggle_hide_reviewed_files"),
        .toggle_sidebar_visibility => voidMsg(Msg, "toggle_sidebar_visibility"),
        .decrease_sidebar_width => voidMsg(Msg, "decrease_sidebar_width"),
        .increase_sidebar_width => voidMsg(Msg, "increase_sidebar_width"),
        .enter_commit_panel => voidMsg(Msg, "enter_commit_panel"),
        .enter_amend_panel => voidMsg(Msg, "enter_amend_panel"),
        .toggle_selected_file => voidMsg(Msg, "toggle_selected_file"),
        .toggle_selected_hunk => voidMsg(Msg, "toggle_selected_hunk"),
        .stage_selected_file => voidMsg(Msg, "stage_selected_file"),
        .stage_selected_hunk => voidMsg(Msg, "stage_selected_hunk"),
        .unstage_selected_file => voidMsg(Msg, "unstage_selected_file"),
        .unstage_selected_hunk => voidMsg(Msg, "unstage_selected_hunk"),
        .request_discard_selected_file => voidMsg(Msg, "request_discard_selected_file"),
        .confirm_discard_file => voidMsg(Msg, "confirm_discard_file"),
        .cancel_discard_file => voidMsg(Msg, "cancel_discard_file"),
        .confirm_amend => voidMsg(Msg, "confirm_amend"),
        .cancel_amend => voidMsg(Msg, "cancel_amend"),
        .request_push => voidMsg(Msg, "request_push"),
        .confirm_push => voidMsg(Msg, "confirm_push"),
        .cancel_push => voidMsg(Msg, "cancel_push"),
        .close_push_error => voidMsg(Msg, "close_push_error"),
        .open_push_credentials => voidMsg(Msg, "open_push_credentials"),
        .run_interactive_push => voidMsg(Msg, "run_interactive_push"),
        .open_selected_file_in_editor => voidMsg(Msg, "open_selected_file_in_editor"),
        .toggle_display_mode => voidMsg(Msg, "toggle_display_mode"),
        .toggle_line_numbers => voidMsg(Msg, "toggle_line_numbers"),
        .finish_review_approved => voidMsg(Msg, "finish_review_approved"),
        .finish_review_needs_changes => voidMsg(Msg, "finish_review_needs_changes"),
        .finish_review_canceled => voidMsg(Msg, "finish_review_canceled"),
        .quit => voidMsg(Msg, "quit"),
        .reload => voidMsg(Msg, "reload"),
    };
}

fn voidMsg(comptime Msg: type, comptime tag: []const u8) Msg {
    return @unionInit(Msg, tag, {});
}

fn payloadMsg(comptime Msg: type, comptime tag: []const u8, payload: anytype) Msg {
    return @unionInit(Msg, tag, payload);
}

const TestMsg = union(enum) {
    terminal_resized: chasen.Size,
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
    cancel_commit_panel,
    submit_commit_panel,
    commit_panel_tab,
    commit_panel_enter,
    commit_panel_backspace,
    commit_panel_move_left,
    commit_panel_move_right,
    commit_panel_move_up,
    commit_panel_move_down,
    commit_panel_insert: u21,
    commit_panel_paste: []const u8,
    cancel_repo_picker,
    close_repo_picker,
    submit_repo_picker,
    repo_picker_enter_filter_input,
    repo_picker_enter_path_input,
    repo_picker_back,
    repo_picker_remove_recent,
    repo_picker_backspace,
    repo_picker_move_previous,
    repo_picker_move_next,
    repo_picker_move_left,
    repo_picker_move_right,
    repo_picker_insert: u21,
    repo_picker_paste: []const u8,
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
    close_help,
    help_scroll_up,
    help_scroll_down,
    help_page_up,
    help_page_down,
    push_error_scroll_up,
    push_error_scroll_down,
    push_error_page_up,
    push_error_page_down,
    push_credential_tab,
    push_credential_submit,
    push_credential_cancel,
    push_credential_insert: u21,
    push_credential_paste: []const u8,
    push_credential_backspace,
    push_credential_move_left,
    push_credential_move_right,
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
    stage_selected_file,
    stage_selected_hunk,
    unstage_selected_file,
    unstage_selected_hunk,
    request_discard_selected_file,
    confirm_discard_file,
    cancel_discard_file,
    confirm_amend,
    cancel_amend,
    request_push,
    confirm_push,
    cancel_push,
    close_push_error,
    open_push_credentials,
    run_interactive_push,
    open_selected_file_in_editor,
    toggle_display_mode,
    toggle_line_numbers,
    finish_review_approved,
    finish_review_needs_changes,
    finish_review_canceled,
    quit,
    reload,
};

test "eventToMsg maps winsize event" {
    const msg = eventToMsg(TestMsg, .{}, .{ .winsize = .{
        .cols = 120,
        .rows = 40,
        .x_pixel = 0,
        .y_pixel = 0,
    } }).?;
    try std.testing.expectEqual(TestMsg{ .terminal_resized = .{ .width = 120, .height = 40 } }, msg);
}

test "eventToMsg routes paste by active text input mode" {
    const search_msg = eventToMsg(TestMsg, .{ .search_mode = true }, .{ .paste = "render" }).?;
    try std.testing.expectEqualStrings("render", search_msg.search_paste);

    const file_msg = eventToMsg(TestMsg, .{ .file_search_mode = true }, .{ .paste = "app.zig" }).?;
    try std.testing.expectEqualStrings("app.zig", file_msg.file_search_paste);

    const repo_msg = eventToMsg(TestMsg, .{ .repo_picker_mode = true }, .{ .paste = "/tmp/repo" }).?;
    try std.testing.expectEqualStrings("/tmp/repo", repo_msg.repo_picker_paste);

    const commit_msg = eventToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .paste = "subject" }).?;
    try std.testing.expectEqualStrings("subject", commit_msg.commit_panel_paste);
}

test "eventToMsg rejects invalid paste and ignores non-input modes" {
    const invalid = [_]u8{0xff};
    try std.testing.expect(eventToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .paste = invalid[0..] }) == null);
    try std.testing.expect(eventToMsg(TestMsg, .{}, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(TestMsg, .{ .help_mode = true }, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(TestMsg, .{ .amend_confirmation_mode = true }, .{ .paste = "ignored" }) == null);
}

test "keyToMsg routes text while search is active" {
    const msg = keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = 'x' }).?;
    try std.testing.expectEqual(TestMsg{ .search_insert = 'x' }, msg);
}

test "keyToMsg maps enter by focused pane" {
    try std.testing.expectEqual(TestMsg.toggle_directory, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.toggle_hunk_fold, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = chasen.Key.enter }).?);
}

test "keyToMsg maps left and right by focused pane" {
    try std.testing.expectEqual(TestMsg.expand_directory, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(TestMsg.collapse_or_parent_directory, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(TestMsg.scroll_diff_right, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(TestMsg.scroll_diff_left, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = chasen.Key.left }).?);
}

test "keyToMsg maps sidebar h and l to horizontal scroll without stealing shifted toggles" {
    try std.testing.expectEqual(TestMsg.scroll_sidebar_left, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(TestMsg.scroll_sidebar_right, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'l' }).?);
    try std.testing.expectEqual(TestMsg.toggle_hide_reviewed_files, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'H' }).?);
    try std.testing.expectEqual(TestMsg.toggle_line_numbers, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'L' }).?);
}

test "keyToMsg maps sidebar visibility and suppresses focus toggle while hidden" {
    try std.testing.expectEqual(TestMsg.toggle_sidebar_visibility, keyToMsg(TestMsg, .{}, .{ .codepoint = 'B' }).?);
    try std.testing.expectEqual(TestMsg.toggle_sidebar_visibility, keyToMsg(TestMsg, .{}, shiftedAscii('b', 'B')).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .sidebar_hidden = true }, .{ .codepoint = chasen.Key.tab }));
}

test "keyToMsg maps sidebar width adjustment keys" {
    try std.testing.expectEqual(TestMsg.decrease_sidebar_width, keyToMsg(TestMsg, .{}, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(TestMsg.increase_sidebar_width, keyToMsg(TestMsg, .{}, .{ .codepoint = ']' }).?);
}

test "keyToMsg maps view option toggles" {
    try std.testing.expectEqual(TestMsg.toggle_line_numbers, keyToMsg(TestMsg, .{}, .{ .codepoint = 'L' }).?);
    try std.testing.expectEqual(TestMsg.toggle_line_numbers, keyToMsg(TestMsg, .{}, shiftedAscii('l', 'L')).?);
}

test "keyToMsg maps stage action by focused pane" {
    try std.testing.expectEqual(TestMsg.toggle_selected_file, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 's' }).?);
    try std.testing.expectEqual(TestMsg.toggle_selected_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = 's' }).?);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'S' }) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = 'S' }) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .sidebar }, shiftedAscii('s', 'S')) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .diff }, shiftedAscii('s', 'S')) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .sidebar }, shiftedLowerOnly('s')) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .diff }, shiftedLowerOnly('s')) == null);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'S', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'S', .mods = .{ .alt = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 's', .mods = .{ .shift = true, .ctrl = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 's', .mods = .{ .shift = true, .alt = true } }));
}

test "keyToMsg maps discard confirmation flow" {
    try std.testing.expectEqual(TestMsg.request_discard_selected_file, keyToMsg(TestMsg, .{}, .{ .codepoint = 'D' }).?);
    try std.testing.expectEqual(TestMsg.request_discard_selected_file, keyToMsg(TestMsg, .{}, shiftedAscii('d', 'D')).?);
    try std.testing.expectEqual(TestMsg.request_discard_selected_file, keyToMsg(TestMsg, .{}, shiftedLowerOnly('d')).?);
    try std.testing.expectEqual(TestMsg.confirm_discard_file, keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_discard_file, keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_discard_file, keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = 'D' }));
}

test "keyToMsg maps commit panel command and routes panel input" {
    try std.testing.expectEqual(TestMsg.enter_commit_panel, keyToMsg(TestMsg, .{}, .{ .codepoint = 'c' }).?);
    try std.testing.expectEqual(TestMsg.enter_amend_panel, keyToMsg(TestMsg, .{}, .{ .codepoint = 'A' }).?);
    try std.testing.expectEqual(TestMsg.enter_amend_panel, keyToMsg(TestMsg, .{}, shiftedAscii('a', 'A')).?);
    try std.testing.expectEqual(TestMsg.enter_amend_panel, keyToMsg(TestMsg, .{}, shiftedLowerOnly('a')).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'a' }));
    try std.testing.expectEqual(TestMsg.cancel_commit_panel, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.submit_commit_panel, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.enter, .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.submit_commit_panel, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 's', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_tab, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_enter, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_backspace, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_left, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_right, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_up, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_down, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'x' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'R' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'R' }).?);
    try std.testing.expectEqual(TestMsg.enter_commit_panel, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'c' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
}

test "keyToMsg uses configurable viewer bindings" {
    var config: keymap.Config = .{};
    config.set(.commit, .{ .plain_codepoint = 'm' });
    config.set(.help, .{ .plain_codepoint = 'z' });
    const effective = keymap.Effective.fromConfig(config);

    try std.testing.expectEqual(TestMsg.enter_commit_panel, keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'c' }));
    try std.testing.expectEqual(TestMsg.open_help, keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'z' }).?);
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, .{ .help_mode = true, .keymap = effective }, .{ .codepoint = 'z' }).?);
}

test "keyToMsg uses configured keys inside help mode" {
    var config: keymap.Config = .{};
    config.set(.commit, .{ .plain_codepoint = 'm' });
    config.set(.help, .{ .plain_codepoint = 'z' });
    const effective = keymap.Effective.fromConfig(config);
    const context: KeyContext = .{
        .help_mode = true,
        .keymap = effective,
    };

    try std.testing.expectEqual(TestMsg.enter_commit_panel, keyToMsg(TestMsg, context, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, context, .{ .codepoint = 'c' }));
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, context, .{ .codepoint = 'z' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, context, .{ .codepoint = '?' }));
}

test "keyToMsg keeps context-dependent keys outside configurable bindings" {
    var config: keymap.Config = .{};
    config.set(.commit, .{ .plain_codepoint = 'm' });
    const effective = keymap.Effective.fromConfig(config);

    try std.testing.expectEqual(TestMsg.toggle_selected_file, keyToMsg(TestMsg, .{ .focus = .sidebar, .keymap = effective }, .{ .codepoint = 's' }).?);
    try std.testing.expectEqual(TestMsg.toggle_selected_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .keymap = effective }, .{ .codepoint = 's' }).?);
}

test "keyToMsg maps amend confirmation flow" {
    try std.testing.expectEqual(TestMsg.confirm_amend, keyToMsg(TestMsg, .{ .amend_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_amend, keyToMsg(TestMsg, .{ .amend_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_amend, keyToMsg(TestMsg, .{ .amend_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .amend_confirmation_mode = true }, .{ .codepoint = 'A' }));
}

test "keyToMsg prioritizes amend confirmation over open commit panel" {
    const context: KeyContext = .{
        .commit_panel_mode = true,
        .amend_confirmation_mode = true,
    };

    try std.testing.expectEqual(TestMsg.confirm_amend, keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_amend, keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_amend, keyToMsg(TestMsg, context, .{ .codepoint = 'q' }).?);
}

test "keyToMsg prioritizes discard confirmation over open commit panel" {
    const context: KeyContext = .{
        .commit_panel_mode = true,
        .discard_confirmation_mode = true,
    };

    try std.testing.expectEqual(TestMsg.confirm_discard_file, keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_discard_file, keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_discard_file, keyToMsg(TestMsg, context, .{ .codepoint = 'q' }).?);
}

test "keyToMsg treats colon as repo picker path text" {
    const context: KeyContext = .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input };
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = ':' }, keyToMsg(TestMsg, context, .{ .codepoint = ':' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = ':' }, keyToMsg(TestMsg, context, shiftedAscii(';', ':')).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = ';' }, keyToMsg(TestMsg, context, shiftedLowerOnly(';')).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = ';' }, keyToMsg(TestMsg, context, .{ .codepoint = ';' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 'q' }, keyToMsg(TestMsg, context, .{ .codepoint = 'q' }).?);
}

test "keyToMsg ignores special keys in text input modes" {
    const common_cases = [_]chasen.Key{
        .{ .codepoint = chasen.Key.up },
        .{ .codepoint = chasen.Key.up, .mods = .{ .shift = true } },
        .{ .codepoint = chasen.Key.down, .mods = .{ .alt = true } },
        .{ .codepoint = chasen.Key.left, .mods = .{ .ctrl = true } },
        .{ .codepoint = chasen.Key.right },
        .{ .codepoint = chasen.Key.home },
        .{ .codepoint = chasen.Key.end },
        .{ .codepoint = chasen.Key.page_up },
        .{ .codepoint = chasen.Key.page_down },
        .{ .codepoint = chasen.Key.insert },
        .{ .codepoint = chasen.Key.delete },
        .{ .codepoint = chasen.Key.kp_up },
        .{ .codepoint = chasen.Key.kp_down },
        .{ .codepoint = chasen.Key.kp_home },
        .{ .codepoint = chasen.Key.kp_end },
        .{ .codepoint = chasen.Key.kp_page_up },
        .{ .codepoint = chasen.Key.kp_page_down },
        .{ .codepoint = chasen.Key.kp_insert },
        .{ .codepoint = chasen.Key.kp_delete },
        .{ .codepoint = chasen.Key.tab },
        .{ .codepoint = chasen.Key.left_shift },
        .{ .codepoint = chasen.Key.right_shift },
        .{ .codepoint = chasen.Key.left_alt },
        .{ .codepoint = chasen.Key.right_alt },
        .{ .codepoint = chasen.Key.left_control },
        .{ .codepoint = chasen.Key.right_control },
        .{ .codepoint = chasen.Key.iso_level_3_shift },
        .{ .codepoint = chasen.Key.iso_level_5_shift },
        .{ .codepoint = chasen.Key.f1 },
        .{ .codepoint = chasen.Key.f35 },
        .{ .codepoint = chasen.Key.caps_lock },
        .{ .codepoint = chasen.Key.menu },
        .{ .codepoint = chasen.Key.media_play },
        .{ .codepoint = chasen.Key.kp_1 },
        .{ .codepoint = chasen.Key.multicodepoint },
        .{ .codepoint = chasen.Key.multicodepoint, .text = "ab" },
    };

    for (common_cases) |key| {
        if (key.codepoint != chasen.Key.left and key.codepoint != chasen.Key.right) {
            try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .search_mode = true }, key));
        }
        try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .file_search_mode = true }, key));
        if (key.codepoint != chasen.Key.tab and key.codepoint != chasen.Key.left and key.codepoint != chasen.Key.right and key.codepoint != chasen.Key.up and key.codepoint != chasen.Key.down) {
            try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .commit_panel_mode = true }, key));
        }
        if (key.codepoint != chasen.Key.left and key.codepoint != chasen.Key.right and key.codepoint != chasen.Key.up and key.codepoint != chasen.Key.down) {
            try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .repo_picker_mode = true }, key));
        }
    }

    const picker_list_text_cases = [_]chasen.Key{
        .{ .codepoint = chasen.Key.home },
        .{ .codepoint = chasen.Key.end },
        .{ .codepoint = chasen.Key.page_up },
        .{ .codepoint = chasen.Key.page_down },
        .{ .codepoint = chasen.Key.insert },
        .{ .codepoint = chasen.Key.delete },
        .{ .codepoint = chasen.Key.kp_left },
        .{ .codepoint = chasen.Key.kp_right },
        .{ .codepoint = chasen.Key.kp_home },
        .{ .codepoint = chasen.Key.kp_end },
        .{ .codepoint = chasen.Key.kp_page_up },
        .{ .codepoint = chasen.Key.kp_page_down },
        .{ .codepoint = chasen.Key.kp_insert },
        .{ .codepoint = chasen.Key.kp_delete },
        .{ .codepoint = chasen.Key.tab },
        .{ .codepoint = chasen.Key.left_shift },
        .{ .codepoint = chasen.Key.right_shift },
        .{ .codepoint = chasen.Key.left_alt },
        .{ .codepoint = chasen.Key.right_alt },
        .{ .codepoint = chasen.Key.left_control },
        .{ .codepoint = chasen.Key.right_control },
        .{ .codepoint = chasen.Key.iso_level_3_shift },
        .{ .codepoint = chasen.Key.iso_level_5_shift },
        .{ .codepoint = chasen.Key.f1 },
        .{ .codepoint = chasen.Key.f35 },
        .{ .codepoint = chasen.Key.caps_lock },
        .{ .codepoint = chasen.Key.menu },
        .{ .codepoint = chasen.Key.media_play },
        .{ .codepoint = chasen.Key.multicodepoint },
        .{ .codepoint = chasen.Key.multicodepoint, .text = "ab" },
    };
    for (picker_list_text_cases) |key| {
        try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .repo_picker_mode = true }, key));
    }
}

test "keyToMsg maps repo picker cursor movement" {
    const input_context: KeyContext = .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input };
    try std.testing.expectEqual(TestMsg.repo_picker_move_left, keyToMsg(TestMsg, input_context, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(TestMsg.repo_picker_move_right, keyToMsg(TestMsg, input_context, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, input_context, .{ .codepoint = chasen.Key.up }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, input_context, .{ .codepoint = chasen.Key.down }));
    const filter_context: KeyContext = .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter };
    try std.testing.expectEqual(TestMsg.repo_picker_move_previous, keyToMsg(TestMsg, filter_context, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.repo_picker_move_next, keyToMsg(TestMsg, filter_context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg.repo_picker_move_previous, keyToMsg(TestMsg, .{ .repo_picker_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.repo_picker_move_next, keyToMsg(TestMsg, .{ .repo_picker_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg.repo_picker_move_previous, keyToMsg(TestMsg, .{ .repo_picker_mode = true }, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(TestMsg.repo_picker_move_next, keyToMsg(TestMsg, .{ .repo_picker_mode = true }, .{ .codepoint = 'j' }).?);
}

test "keyToMsg maps repo picker recent removal only in list mode" {
    try std.testing.expectEqual(TestMsg.repo_picker_remove_recent, keyToMsg(TestMsg, .{ .repo_picker_mode = true }, .{ .codepoint = 'd' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 'd' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, .{ .codepoint = 'd' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 'd' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = 'd' }).?);
}

test "keyToMsg maps search cursor movement" {
    try std.testing.expectEqual(TestMsg.search_move_left, keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(TestMsg.search_move_right, keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = chasen.Key.right }).?);
}

test "keyToMsg ignores modified search cursor movement" {
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = chasen.Key.left, .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = chasen.Key.right, .mods = .{ .ctrl = true } }));
}

test "keyToMsg ignores ctrl printable in text input modes" {
    const ctrl_c: chasen.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } };

    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .search_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .file_search_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .commit_panel_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .repo_picker_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .repo_picker_mode = true }, ctrl_c));
}

test "keyToMsg ignores command modifiers for static viewer bindings" {
    const cases = [_]chasen.Key{
        .{ .codepoint = '/', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'r', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'g', .mods = .{ .alt = true } },
        .{ .codepoint = 'f', .mods = .{ .super = true } },
        .{ .codepoint = 'e', .mods = .{ .meta = true } },
    };

    for (cases) |key| {
        try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, key));
    }
}

test "keyToMsg keeps printable text input modes working" {
    try std.testing.expectEqual(TestMsg{ .search_insert = 'x' }, keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = 'x' }, keyToMsg(TestMsg, .{ .file_search_mode = true }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'x' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 'x' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 'q' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 'x' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = ':' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = ':' }).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = 0x1F408 }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = 0x1F408 }).?);
}

test "keyToMsg prefers generated text for printable text input" {
    const keypad_one: chasen.Key = .{
        .codepoint = chasen.Key.kp_1,
        .text = "1",
    };

    try std.testing.expectEqual(TestMsg{ .search_insert = '1' }, keyToMsg(TestMsg, .{ .search_mode = true }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = '1' }, keyToMsg(TestMsg, .{ .file_search_mode = true }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = '1' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = '1' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = '1' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, keypad_one).?);
}

test "keyToMsg uses search query to disambiguate navigation" {
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{}, .{ .codepoint = 'n' }).?);
    try std.testing.expectEqual(TestMsg.select_next_search_match, keyToMsg(TestMsg, .{ .search_query_len = 4 }, .{ .codepoint = 'n' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'N' }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, shiftedAscii('n', 'N')));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, shiftedLowerOnly('n')));
    try std.testing.expectEqual(TestMsg.select_previous_search_match, keyToMsg(TestMsg, .{ .search_query_len = 4 }, .{ .codepoint = 'N' }).?);
    try std.testing.expectEqual(TestMsg.select_previous_search_match, keyToMsg(TestMsg, .{ .search_query_len = 4 }, shiftedAscii('n', 'N')).?);
    try std.testing.expectEqual(TestMsg.select_previous_search_match, keyToMsg(TestMsg, .{ .search_query_len = 4 }, shiftedLowerOnly('n')).?);
}

test "keyToMsg maps review result commands only in review mode" {
    try std.testing.expectEqual(TestMsg.finish_review_approved, keyToMsg(TestMsg, .{ .review_mode = true }, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(TestMsg.finish_review_needs_changes, keyToMsg(TestMsg, .{ .review_mode = true }, .{ .codepoint = 'N' }).?);
    try std.testing.expectEqual(TestMsg.finish_review_needs_changes, keyToMsg(TestMsg, .{ .review_mode = true }, shiftedAscii('n', 'N')).?);
    try std.testing.expectEqual(TestMsg.finish_review_needs_changes, keyToMsg(TestMsg, .{ .review_mode = true }, shiftedLowerOnly('n')).?);
    try std.testing.expectEqual(TestMsg.finish_review_canceled, keyToMsg(TestMsg, .{ .review_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.select_previous_search_match, keyToMsg(TestMsg, .{ .review_mode = true, .search_query_len = 4 }, .{ .codepoint = 'N' }).?);
    try std.testing.expectEqual(TestMsg.select_previous_search_match, keyToMsg(TestMsg, .{ .review_mode = true, .search_query_len = 4 }, shiftedAscii('n', 'N')).?);
    try std.testing.expectEqual(TestMsg.enter_amend_panel, keyToMsg(TestMsg, .{ .review_mode = true }, .{ .codepoint = 'A' }).?);

    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'a' }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'N' }));
    try std.testing.expectEqual(TestMsg.quit, keyToMsg(TestMsg, .{}, .{ .codepoint = 'q' }).?);
}

test "keyToMsg maps dedicated hunk jumps only in diff focus" {
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = 'J' }).?);
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = 'K' }).?);
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, shiftedAscii('j', 'J')).?);
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, shiftedAscii('k', 'K')).?);
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, shiftedLowerOnly('j')).?);
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{ .focus = .diff }, shiftedLowerOnly('k')).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'J' }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = 'K' }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .focus = .sidebar }, shiftedAscii('j', 'J')));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .focus = .sidebar }, shiftedAscii('k', 'K')));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .focus = .sidebar }, shiftedLowerOnly('j')));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .focus = .sidebar }, shiftedLowerOnly('k')));
}

test "keyToMsg keeps dedicated hunk jumps independent from search query" {
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .search_query_len = 4 }, .{ .codepoint = 'J' }).?);
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .search_query_len = 4 }, .{ .codepoint = 'K' }).?);
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .search_query_len = 4 }, shiftedAscii('j', 'J')).?);
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .search_query_len = 4 }, shiftedAscii('k', 'K')).?);
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .search_query_len = 4 }, shiftedLowerOnly('j')).?);
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{ .focus = .diff, .search_query_len = 4 }, shiftedLowerOnly('k')).?);
}

test "push credential prompt accepts q as text and uses escape to cancel" {
    try std.testing.expectEqual(TestMsg{ .push_credential_insert = 'q' }, keyToMsg(TestMsg, .{ .push_credential_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.push_credential_cancel, keyToMsg(TestMsg, .{ .push_credential_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
}

test "keyToMsg maps shifted letter commands consistently" {
    try std.testing.expectEqual(TestMsg.select_last_file, keyToMsg(TestMsg, .{}, .{ .codepoint = 'G' }).?);
    try std.testing.expectEqual(TestMsg.select_last_file, keyToMsg(TestMsg, .{}, shiftedAscii('g', 'G')).?);
    try std.testing.expectEqual(TestMsg.select_last_file, keyToMsg(TestMsg, .{}, shiftedLowerOnly('g')).?);
    try std.testing.expectEqual(TestMsg.select_first_file, keyToMsg(TestMsg, .{}, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(TestMsg.select_last_file, keyToMsg(TestMsg, .{}, .{ .codepoint = chasen.Key.end }).?);
    try std.testing.expectEqual(TestMsg.enter_repo_picker, keyToMsg(TestMsg, .{}, .{ .codepoint = 'R' }).?);
    try std.testing.expectEqual(TestMsg.enter_repo_picker, keyToMsg(TestMsg, .{}, shiftedAscii('r', 'R')).?);
    try std.testing.expectEqual(TestMsg.enter_repo_picker, keyToMsg(TestMsg, .{}, shiftedLowerOnly('r')).?);
    try std.testing.expectEqual(TestMsg.cycle_changed_file_filter, keyToMsg(TestMsg, .{}, .{ .codepoint = 'F' }).?);
    try std.testing.expectEqual(TestMsg.cycle_changed_file_filter, keyToMsg(TestMsg, .{}, shiftedAscii('f', 'F')).?);
    try std.testing.expectEqual(TestMsg.cycle_changed_file_filter, keyToMsg(TestMsg, .{}, shiftedLowerOnly('f')).?);
    try std.testing.expectEqual(TestMsg.toggle_hide_reviewed_files, keyToMsg(TestMsg, .{}, .{ .codepoint = 'H' }).?);
    try std.testing.expectEqual(TestMsg.toggle_hide_reviewed_files, keyToMsg(TestMsg, .{}, shiftedAscii('h', 'H')).?);
    try std.testing.expectEqual(TestMsg.toggle_hide_reviewed_files, keyToMsg(TestMsg, .{}, shiftedLowerOnly('h')).?);
    try std.testing.expectEqual(TestMsg.request_push, keyToMsg(TestMsg, .{}, .{ .codepoint = 'P' }).?);
    try std.testing.expectEqual(TestMsg.request_push, keyToMsg(TestMsg, .{}, shiftedAscii('p', 'P')).?);
    try std.testing.expectEqual(TestMsg.request_push, keyToMsg(TestMsg, .{}, shiftedLowerOnly('p')).?);
    try std.testing.expectEqual(TestMsg.toggle_sidebar_visibility, keyToMsg(TestMsg, .{}, shiftedLowerOnly('b')).?);
    try std.testing.expectEqual(TestMsg.toggle_line_numbers, keyToMsg(TestMsg, .{}, shiftedLowerOnly('l')).?);
}

test "keyToMsg keeps lowercase p as previous hunk while uppercase P pushes" {
    try std.testing.expectEqual(TestMsg.select_previous_hunk, keyToMsg(TestMsg, .{}, .{ .codepoint = 'p' }).?);
    try std.testing.expectEqual(TestMsg.request_push, keyToMsg(TestMsg, .{}, .{ .codepoint = 'P' }).?);
}

test "keyToMsg maps push confirmation keys" {
    try std.testing.expectEqual(TestMsg.confirm_push, keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_push, keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_push, keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = 'P' }));
}

test "keyToMsg maps push error modal keys" {
    try std.testing.expectEqual(TestMsg.close_push_error, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.close_push_error, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.close_push_error, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.run_interactive_push, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'i' }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_up, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_down, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_up, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_down, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg.push_error_page_up, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.page_up }).?);
    try std.testing.expectEqual(TestMsg.push_error_page_down, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.page_down }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'P' }));
}

test "keyToMsg opens and closes help outside prompt modes" {
    try std.testing.expectEqual(TestMsg.open_help, keyToMsg(TestMsg, .{}, .{ .codepoint = '?' }).?);
    try std.testing.expectEqual(TestMsg.open_help, keyToMsg(TestMsg, .{}, .{
        .codepoint = '/',
        .shifted_codepoint = '?',
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqual(TestMsg.open_help, keyToMsg(TestMsg, .{}, .{
        .codepoint = '/',
        .text = "?",
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqual(TestMsg.enter_search, keyToMsg(TestMsg, .{}, .{
        .codepoint = '/',
        .text = "/",
    }).?);
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = '?' }).?);
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, .{ .help_mode = true }, .{
        .codepoint = '/',
        .shifted_codepoint = '?',
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.help_scroll_up, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(TestMsg.help_scroll_down, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(TestMsg.help_scroll_up, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.help_scroll_down, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg.help_page_up, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = chasen.Key.page_up }).?);
    try std.testing.expectEqual(TestMsg.help_page_down, keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = chasen.Key.page_down }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'x' }));
}

test "keyToMsg ignores command modifiers for help overlay printable shortcuts" {
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'q', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'k', .mods = .{ .alt = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'j', .mods = .{ .super = true } }));
}

test "keyToMsg keeps prompt modes above help overlay" {
    const msg = keyToMsg(TestMsg, .{ .search_mode = true, .help_mode = true }, .{ .codepoint = '?' }).?;
    try std.testing.expectEqual(TestMsg{ .search_insert = '?' }, msg);
}

fn shiftedAscii(lower: u21, upper: u21) chasen.Key {
    return .{
        .codepoint = lower,
        .shifted_codepoint = upper,
        .mods = .{ .shift = true },
    };
}

fn shiftedLowerOnly(lower: u21) chasen.Key {
    return .{
        .codepoint = lower,
        .mods = .{ .shift = true },
    };
}
