const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("key_input.zig");
const app_prompt = @import("prompt.zig");
const page = @import("page.zig");
const review_input = @import("pages/review/input.zig");
const repository_page = @import("pages/repository.zig");

/// Minimal snapshot needed to translate a terminal key into an App message.
/// Keeping this small prevents input mapping from depending on full App state.
pub const KeyContext = struct {
    active_page: page.Id = .review,
    review: review_input.Context = .{},
    repository: repository_page.InputContext = .{},
    commit_panel_mode: bool = false,
    repo_picker_mode: bool = false,
    repo_picker_input_mode: app_prompt.RepoPickerInputMode = .list,
    help_mode: bool = false,
    discard_confirmation_mode: bool = false,
    amend_confirmation_mode: bool = false,
    push_confirmation_mode: bool = false,
    pull_confirmation_mode: bool = false,
    branch_switch_mode: bool = false,
    push_error_mode: bool = false,
    push_credential_mode: bool = false,
    keymap: keymap.Effective = .{},
};

const Action = enum {
    cancel_commit_panel,
    submit_commit_panel,
    assist_commit_message,
    copy_commit_message,
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
    close_help,
    help_scroll_up,
    help_scroll_down,
    help_page_up,
    help_page_down,
    push_error_scroll_up,
    push_error_scroll_down,
    push_error_page_up,
    push_error_page_down,
    copy_popup,
    push_credential_tab,
    push_credential_submit,
    push_credential_cancel,
    push_credential_backspace,
    push_credential_move_left,
    push_credential_move_right,
    confirm_discard_file,
    cancel_discard_file,
    confirm_amend,
    cancel_amend,
    confirm_push,
    cancel_push,
    confirm_pull,
    cancel_pull,
    branch_switch_move_previous,
    branch_switch_move_next,
    confirm_branch_switch,
    cancel_branch_switch,
    close_push_error,
    open_push_credentials,
    run_interactive_push,
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
    if (context.active_page == .review and (context.review.search_mode or context.review.file_search_mode)) {
        const review_msg = review_input.pasteToMsg(context.review, text) orelse return null;
        return translateReviewMsg(Msg, review_msg);
    }
    if (context.active_page == .repository and (context.repository.source_search_mode or context.repository.file_search_mode)) {
        const repository_msg = repository_page.pasteToMsg(context.repository, text) orelse return null;
        return payloadMsg(Msg, "repository", repository_msg);
    }
    if (context.repo_picker_mode) return payloadMsg(Msg, "repo_picker_paste", text);
    if (context.push_credential_mode) return payloadMsg(Msg, "push_credential_paste", text);
    if (context.help_mode or context.discard_confirmation_mode or context.amend_confirmation_mode or context.push_confirmation_mode or context.pull_confirmation_mode or context.branch_switch_mode or context.push_error_mode) return null;
    if (context.commit_panel_mode) return payloadMsg(Msg, "commit_panel_paste", text);
    if (context.active_page == .review) {
        const review_msg = review_input.pasteToMsg(context.review, text) orelse return null;
        return translateReviewMsg(Msg, review_msg);
    }
    return null;
}

pub fn keyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (context.active_page == .review and (context.review.search_mode or context.review.file_search_mode)) {
        const review_msg = review_input.keyToMsg(context.review, key) orelse return null;
        return translateReviewMsg(Msg, review_msg);
    }
    if (context.active_page == .repository and (context.repository.source_search_mode or context.repository.file_search_mode)) {
        const repository_msg = repository_page.keyToMsg(context.repository, key) orelse return null;
        return payloadMsg(Msg, "repository", repository_msg);
    }
    if (context.repo_picker_mode) return repoPickerKeyToMsg(Msg, context, key);
    if (context.help_mode) return helpKeyToMsg(Msg, context, key);
    if (context.discard_confirmation_mode) return discardConfirmationKeyToMsg(Msg, key);
    if (context.amend_confirmation_mode) return amendConfirmationKeyToMsg(Msg, key);
    if (context.push_confirmation_mode) return pushConfirmationKeyToMsg(Msg, key);
    if (context.pull_confirmation_mode) return pullConfirmationKeyToMsg(Msg, key);
    if (context.branch_switch_mode) return branchSwitchKeyToMsg(Msg, key);
    if (context.push_error_mode) return pushErrorKeyToMsg(Msg, key);
    if (context.push_credential_mode) return pushCredentialKeyToMsg(Msg, key);
    if (context.commit_panel_mode) return commitPanelKeyToMsg(Msg, key);
    if (pageForKey(context.keymap, key)) |target| return payloadMsg(Msg, "switch_page", target);
    if (context.keymap.spec(.help)) |spec| if (spec.matches(key)) return voidMsg(Msg, "open_help");
    if (context.keymap.spec(.repo_picker)) |spec| if (spec.matches(key)) return voidMsg(Msg, "enter_repo_picker");
    if (context.keymap.spec(.reload)) |spec| if (spec.matches(key)) return voidMsg(Msg, "reload");
    if (context.active_page == .review) {
        if (review_input.keyToMsg(context.review, key)) |review_msg| {
            return translateReviewMsg(Msg, review_msg);
        }
    }
    if (context.active_page == .repository) {
        if (repository_page.keyToMsg(context.repository, key)) |repository_msg| {
            return payloadMsg(Msg, "repository", repository_msg);
        }
    }
    if (key.codepoint == 'q' and !key_input.hasCommandModifier(key)) return voidMsg(Msg, "quit");
    return null;
}

fn pageForKey(effective: keymap.Effective, key: chasen.Key) ?page.Id {
    const bindings = [_]struct { action: keymap.PublicAction, id: page.Id }{
        .{ .action = .page_review, .id = .review },
        .{ .action = .page_repository, .id = .repository },
        .{ .action = .page_compare, .id = .compare },
        .{ .action = .page_config, .id = .config },
    };
    for (bindings) |binding| {
        const spec = effective.spec(binding.action) orelse continue;
        if (spec.matches(key)) return binding.id;
    }
    return null;
}

fn translateReviewMsg(comptime Msg: type, msg: review_input.Msg) Msg {
    return payloadMsg(Msg, "review", msg);
}

fn repoPickerKeyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .cancel_repo_picker);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .submit_repo_picker);

    switch (context.repo_picker_input_mode) {
        .list => {
            if (key.codepoint == 'q' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .close_repo_picker);
            if (key.codepoint == '/' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_enter_filter_input);
            if (key.codepoint == 'p' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_enter_path_input);
            if (key.codepoint == 'b' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_back);
            if (key.codepoint == 'd' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .repo_picker_remove_recent);
            if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return actionToMsg(Msg, .repo_picker_move_previous);
            if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return actionToMsg(Msg, .repo_picker_move_next);
        },
        .filter => {
            if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .repo_picker_backspace);
            if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .repo_picker_move_left);
            if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .repo_picker_move_right);
            if (key.matches(chasen.Key.up, .{})) return actionToMsg(Msg, .repo_picker_move_previous);
            if (key.matches(chasen.Key.down, .{})) return actionToMsg(Msg, .repo_picker_move_next);
            if (key_input.textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "repo_picker_insert", codepoint);
        },
        .path_input => {
            if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .repo_picker_backspace);
            if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .repo_picker_move_left);
            if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .repo_picker_move_right);
            if (key.matches(chasen.Key.up, .{}) or key.matches(chasen.Key.down, .{})) return null;
            if (key_input.textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "repo_picker_insert", codepoint);
        },
    }
    return null;
}

fn helpKeyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (context.keymap.spec(.help)) |spec| {
        if (spec.matches(key)) return actionToMsg(Msg, .close_help);
    }
    if (context.keymap.spec(.commit)) |spec| {
        if (spec.matches(key)) return translateReviewMsg(Msg, .enter_commit_panel);
    }
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

fn pullConfirmationKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .cancel_pull);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .confirm_pull);
    return null;
}

fn branchSwitchKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .cancel_branch_switch);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .confirm_branch_switch);
    if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return actionToMsg(Msg, .branch_switch_move_previous);
    if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return actionToMsg(Msg, .branch_switch_move_next);
    return null;
}

fn pushErrorKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.matches(chasen.Key.enter, .{}) or key.codepoint == 'q') return actionToMsg(Msg, .close_push_error);
    if (key.codepoint == 'c' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .open_push_credentials);
    if (key.codepoint == 'i' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .run_interactive_push);
    if (key.codepoint == 'y' and !key_input.hasCommandModifier(key)) return actionToMsg(Msg, .copy_popup);
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
    if (key_input.textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "push_credential_insert", codepoint);
    return null;
}

fn commitPanelKeyToMsg(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(Msg, .cancel_commit_panel);
    if (key.matches('g', .{ .ctrl = true })) return actionToMsg(Msg, .assist_commit_message);
    if (key.matches('y', .{ .ctrl = true })) return actionToMsg(Msg, .copy_commit_message);
    if (key.matches(chasen.Key.enter, .{ .ctrl = true }) or key.matches('s', .{ .ctrl = true })) return actionToMsg(Msg, .submit_commit_panel);
    if (key.matches(chasen.Key.tab, .{})) return actionToMsg(Msg, .commit_panel_tab);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(Msg, .commit_panel_enter);
    if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(Msg, .commit_panel_backspace);
    if (key.matches(chasen.Key.left, .{})) return actionToMsg(Msg, .commit_panel_move_left);
    if (key.matches(chasen.Key.right, .{})) return actionToMsg(Msg, .commit_panel_move_right);
    if (key.matches(chasen.Key.up, .{})) return actionToMsg(Msg, .commit_panel_move_up);
    if (key.matches(chasen.Key.down, .{})) return actionToMsg(Msg, .commit_panel_move_down);
    if (key_input.textInputCodepoint(key)) |codepoint| return payloadMsg(Msg, "commit_panel_insert", codepoint);
    return null;
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
            .plain_codepoint => |codepoint| !key_input.hasCommandModifier(key) and key.codepoint == codepoint,
            .exact => |codepoint| key.matches(codepoint, .{}),
            .shifted_ascii => |ascii| key_input.matchesShiftedAscii(key, ascii.lower, ascii.upper),
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

fn helpActionForKey(key: chasen.Key) ?Action {
    return actionForKey(&help_bindings, key);
}

fn actionForKey(bindings: []const KeyBinding, key: chasen.Key) ?Action {
    for (bindings) |binding| {
        if (binding.matcher.matches(key)) return binding.action;
    }
    return null;
}

fn actionToMsg(comptime Msg: type, action: Action) Msg {
    return switch (action) {
        .cancel_commit_panel => voidMsg(Msg, "cancel_commit_panel"),
        .submit_commit_panel => voidMsg(Msg, "submit_commit_panel"),
        .assist_commit_message => voidMsg(Msg, "assist_commit_message"),
        .copy_commit_message => voidMsg(Msg, "copy_commit_message"),
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
        .close_help => voidMsg(Msg, "close_help"),
        .help_scroll_up => voidMsg(Msg, "help_scroll_up"),
        .help_scroll_down => voidMsg(Msg, "help_scroll_down"),
        .help_page_up => voidMsg(Msg, "help_page_up"),
        .help_page_down => voidMsg(Msg, "help_page_down"),
        .push_error_scroll_up => voidMsg(Msg, "push_error_scroll_up"),
        .push_error_scroll_down => voidMsg(Msg, "push_error_scroll_down"),
        .push_error_page_up => voidMsg(Msg, "push_error_page_up"),
        .push_error_page_down => voidMsg(Msg, "push_error_page_down"),
        .copy_popup => voidMsg(Msg, "copy_popup"),
        .push_credential_tab => voidMsg(Msg, "push_credential_tab"),
        .push_credential_submit => voidMsg(Msg, "push_credential_submit"),
        .push_credential_cancel => voidMsg(Msg, "push_credential_cancel"),
        .push_credential_backspace => voidMsg(Msg, "push_credential_backspace"),
        .push_credential_move_left => voidMsg(Msg, "push_credential_move_left"),
        .push_credential_move_right => voidMsg(Msg, "push_credential_move_right"),
        .confirm_discard_file => voidMsg(Msg, "confirm_discard_file"),
        .cancel_discard_file => voidMsg(Msg, "cancel_discard_file"),
        .confirm_amend => voidMsg(Msg, "confirm_amend"),
        .cancel_amend => voidMsg(Msg, "cancel_amend"),
        .confirm_push => voidMsg(Msg, "confirm_push"),
        .cancel_push => voidMsg(Msg, "cancel_push"),
        .confirm_pull => voidMsg(Msg, "confirm_pull"),
        .cancel_pull => voidMsg(Msg, "cancel_pull"),
        .branch_switch_move_previous => voidMsg(Msg, "branch_switch_move_previous"),
        .branch_switch_move_next => voidMsg(Msg, "branch_switch_move_next"),
        .confirm_branch_switch => voidMsg(Msg, "confirm_branch_switch"),
        .cancel_branch_switch => voidMsg(Msg, "cancel_branch_switch"),
        .close_push_error => voidMsg(Msg, "close_push_error"),
        .open_push_credentials => voidMsg(Msg, "open_push_credentials"),
        .run_interactive_push => voidMsg(Msg, "run_interactive_push"),
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
    switch_page: page.Id,
    review: review_input.Msg,
    repository: repository_page.Msg,
    cancel_commit_panel,
    submit_commit_panel,
    assist_commit_message,
    copy_commit_message,
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
    copy_popup,
    push_credential_tab,
    push_credential_submit,
    push_credential_cancel,
    push_credential_insert: u21,
    push_credential_paste: []const u8,
    push_credential_backspace,
    push_credential_move_left,
    push_credential_move_right,
    confirm_discard_file,
    cancel_discard_file,
    confirm_amend,
    cancel_amend,
    confirm_push,
    cancel_push,
    confirm_pull,
    cancel_pull,
    branch_switch_move_previous,
    branch_switch_move_next,
    confirm_branch_switch,
    cancel_branch_switch,
    close_push_error,
    open_push_credentials,
    run_interactive_push,
    quit,
    reload,
};

fn reviewMsg(msg: review_input.Msg) TestMsg {
    return .{ .review = msg };
}

test "normal page keys map after text and overlay precedence" {
    try std.testing.expectEqual(TestMsg{ .switch_page = .review }, keyToMsg(TestMsg, .{}, .{ .codepoint = '1' }).?);
    try std.testing.expectEqual(TestMsg{ .switch_page = .config }, keyToMsg(TestMsg, .{}, .{ .codepoint = '4' }).?);
    try std.testing.expectEqual(reviewMsg(.{ .search_insert = '2' }), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, .{ .codepoint = '2' }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = '3' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = '3' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = '2', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(TestMsg{ .repository = .move_down }, keyToMsg(TestMsg, .{ .active_page = .repository }, .{ .codepoint = 'j' }).?);

    var config: keymap.Config = .{};
    config.set(.page_repository, .{ .plain_codepoint = 'w' });
    const remapped = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(TestMsg{ .switch_page = .repository }, keyToMsg(TestMsg, .{ .keymap = remapped }, .{ .codepoint = 'w' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .keymap = remapped }, .{ .codepoint = '2' }));
}

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
    const search_msg = eventToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, .{ .paste = "render" }).?;
    try std.testing.expectEqualStrings("render", search_msg.review.search_paste);

    const file_msg = eventToMsg(TestMsg, .{ .review = .{ .file_search_mode = true } }, .{ .paste = "app.zig" }).?;
    try std.testing.expectEqualStrings("app.zig", file_msg.review.file_search_paste);

    const source_msg = eventToMsg(TestMsg, .{
        .active_page = .repository,
        .repository = .{ .source_search_mode = true },
    }, .{ .paste = "needle" }).?;
    try std.testing.expectEqualStrings("needle", source_msg.repository.source_search_paste);

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

test "shell nests Review void and payload messages under one route" {
    try std.testing.expectEqual(reviewMsg(.toggle_directory), keyToMsg(TestMsg, .{ .review = .{ .focus = .sidebar } }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(reviewMsg(.{ .search_insert = 'x' }), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, .{ .codepoint = 'x' }).?);
}

test "shell routes plain q by active Review context" {
    try std.testing.expectEqual(TestMsg.quit, keyToMsg(TestMsg, .{}, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(reviewMsg(.finish_review_canceled), keyToMsg(TestMsg, .{ .review = .{ .review_mode = true } }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(reviewMsg(.{ .search_insert = 'q' }), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true, .review_mode = true } }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, .{ .help_mode = true, .review = .{ .review_mode = true } }, .{ .codepoint = 'q' }).?);
}

test "shell owns help repo picker and reload before Review delegation" {
    try std.testing.expectEqual(TestMsg.open_help, keyToMsg(TestMsg, .{}, .{ .codepoint = '?' }).?);
    try std.testing.expectEqual(TestMsg.enter_repo_picker, keyToMsg(TestMsg, .{}, .{ .codepoint = 'R' }).?);
    try std.testing.expectEqual(TestMsg.reload, keyToMsg(TestMsg, .{}, .{ .codepoint = 'r' }).?);
}

test "keyToMsg maps discard confirmation flow" {
    try std.testing.expectEqual(reviewMsg(.request_discard_selected_file), keyToMsg(TestMsg, .{}, .{ .codepoint = 'D' }).?);
    try std.testing.expectEqual(reviewMsg(.request_discard_selected_file), keyToMsg(TestMsg, .{}, shiftedAscii('d', 'D')).?);
    try std.testing.expectEqual(reviewMsg(.request_discard_selected_file), keyToMsg(TestMsg, .{}, shiftedLowerOnly('d')).?);
    try std.testing.expectEqual(TestMsg.confirm_discard_file, keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_discard_file, keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_discard_file, keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .discard_confirmation_mode = true }, .{ .codepoint = 'D' }));
}

test "keyToMsg maps commit panel command and routes panel input" {
    try std.testing.expectEqual(reviewMsg(.enter_commit_panel), keyToMsg(TestMsg, .{}, .{ .codepoint = 'c' }).?);
    try std.testing.expectEqual(reviewMsg(.enter_amend_panel), keyToMsg(TestMsg, .{}, .{ .codepoint = 'A' }).?);
    try std.testing.expectEqual(reviewMsg(.enter_amend_panel), keyToMsg(TestMsg, .{}, shiftedAscii('a', 'A')).?);
    try std.testing.expectEqual(reviewMsg(.enter_amend_panel), keyToMsg(TestMsg, .{}, shiftedLowerOnly('a')).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'a' }));
    try std.testing.expectEqual(TestMsg.cancel_commit_panel, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.submit_commit_panel, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.enter, .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.submit_commit_panel, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 's', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.assist_commit_message, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'g', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.copy_commit_message, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'y', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_tab, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_enter, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_backspace, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_left, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_right, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_up, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.commit_panel_move_down, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'x' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'y' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'R' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'R' }).?);
    try std.testing.expectEqual(reviewMsg(.enter_commit_panel), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'c' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{}, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .help_mode = true }, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
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

    try std.testing.expectEqual(reviewMsg(.enter_commit_panel), keyToMsg(TestMsg, context, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, context, .{ .codepoint = 'c' }));
    try std.testing.expectEqual(TestMsg.close_help, keyToMsg(TestMsg, context, .{ .codepoint = 'z' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, context, .{ .codepoint = '?' }));
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
            try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, key));
        }
        if (!key.matches(chasen.Key.up, .{}) and !key.matches(chasen.Key.down, .{})) {
            try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .review = .{ .file_search_mode = true } }, key));
        }
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

test "keyToMsg maps review file search candidate movement" {
    const context: KeyContext = .{ .review = .{ .file_search_mode = true } };
    try std.testing.expectEqual(reviewMsg(.file_search_previous), keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(reviewMsg(.file_search_next), keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(reviewMsg(.{ .file_search_insert = 'k' }), keyToMsg(TestMsg, context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(reviewMsg(.{ .file_search_insert = 'j' }), keyToMsg(TestMsg, context, .{ .codepoint = 'j' }).?);
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

test "keyToMsg ignores ctrl printable in text input modes" {
    const ctrl_c: chasen.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } };

    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .review = .{ .file_search_mode = true } }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .commit_panel_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .repo_picker_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .repo_picker_mode = true }, ctrl_c));
}

test "keyToMsg keeps printable text input modes working" {
    try std.testing.expectEqual(reviewMsg(.{ .search_insert = 'x' }), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(reviewMsg(.{ .file_search_insert = 'x' }), keyToMsg(TestMsg, .{ .review = .{ .file_search_mode = true } }, .{ .codepoint = 'x' }).?);
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

    try std.testing.expectEqual(reviewMsg(.{ .search_insert = '1' }), keyToMsg(TestMsg, .{ .review = .{ .search_mode = true } }, keypad_one).?);
    try std.testing.expectEqual(reviewMsg(.{ .file_search_insert = '1' }), keyToMsg(TestMsg, .{ .review = .{ .file_search_mode = true } }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = '1' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = '1' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, keypad_one).?);
    try std.testing.expectEqual(TestMsg{ .repo_picker_insert = '1' }, keyToMsg(TestMsg, .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, keypad_one).?);
}

test "push credential prompt accepts q as text and uses escape to cancel" {
    try std.testing.expectEqual(TestMsg{ .push_credential_insert = 'q' }, keyToMsg(TestMsg, .{ .push_credential_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.push_credential_cancel, keyToMsg(TestMsg, .{ .push_credential_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
}

test "keyToMsg maps push confirmation keys" {
    try std.testing.expectEqual(TestMsg.confirm_push, keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_push, keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_push, keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .push_confirmation_mode = true }, .{ .codepoint = 'P' }));
}

test "keyToMsg maps pull confirmation keys" {
    try std.testing.expectEqual(TestMsg.confirm_pull, keyToMsg(TestMsg, .{ .pull_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.cancel_pull, keyToMsg(TestMsg, .{ .pull_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.cancel_pull, keyToMsg(TestMsg, .{ .pull_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .pull_confirmation_mode = true }, .{ .codepoint = 'U' }));
}

test "keyToMsg maps push error modal keys" {
    try std.testing.expectEqual(TestMsg.close_push_error, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.close_push_error, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.close_push_error, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(TestMsg.run_interactive_push, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'i' }).?);
    try std.testing.expectEqual(TestMsg.copy_popup, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_up, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_down, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_up, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg.push_error_scroll_down, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(TestMsg.push_error_page_up, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.page_up }).?);
    try std.testing.expectEqual(TestMsg.push_error_page_down, keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = chasen.Key.page_down }).?);
    try std.testing.expectEqual(@as(?TestMsg, null), keyToMsg(TestMsg, .{ .push_error_mode = true }, .{ .codepoint = 'P' }));
}

test "keyToMsg keeps printable y as editable popup input" {
    try std.testing.expectEqual(TestMsg{ .commit_panel_insert = 'y' }, keyToMsg(TestMsg, .{ .commit_panel_mode = true }, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(TestMsg{ .push_credential_insert = 'y' }, keyToMsg(TestMsg, .{ .push_credential_mode = true }, .{ .codepoint = 'y' }).?);
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
    try std.testing.expectEqual(reviewMsg(.enter_search), keyToMsg(TestMsg, .{}, .{
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
    const msg = keyToMsg(TestMsg, .{ .review = .{ .search_mode = true }, .help_mode = true }, .{ .codepoint = '?' }).?;
    try std.testing.expectEqual(reviewMsg(.{ .search_insert = '?' }), msg);
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
