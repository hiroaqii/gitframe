//! Concrete keyboard and paste mapping for the root shell.
//!
//! Mapping consumes a small immutable snapshot and returns `app_message.Msg`
//! directly. Borrowed paste slices are valid only during synchronous event
//! dispatch and are never retained here.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const app_message = @import("message.zig");
const command_line = @import("command_line.zig");
const key_input = @import("key_input.zig");
const branch_picker = @import("branch_picker.zig");
const app_prompt = @import("prompt.zig");
const page = @import("page.zig");
const changes_input = @import("pages/changes/input.zig");
const compare_input = @import("pages/compare/input.zig");
const repository_page = @import("pages/repository.zig");
const repository_input = @import("pages/repository/input.zig");
const history_input = @import("pages/history/input.zig");

/// Minimal snapshot needed to translate a terminal key into an App message.
/// Keeping this small prevents input mapping from depending on full App state.
pub const ChangesContext = changes_input.Context;
pub const CompareContext = compare_input.Context;
pub const HistoryContext = history_input.Context;

pub const KeyContext = struct {
    active_page: page.Id = .changes,
    changes: ChangesContext = .{},
    compare: CompareContext = .{},
    repository: repository_input.Context = .{},
    history: HistoryContext = .{},
    create_stash: ?*const @import("stash.zig").Create = null,
    commit_panel_mode: bool = false,
    repo_picker_mode: bool = false,
    repo_picker_input_mode: app_prompt.RepoPickerInputMode = .list,
    help_mode: bool = false,
    discard_confirmation_mode: bool = false,
    amend_confirmation_mode: bool = false,
    push_confirmation_mode: bool = false,
    pull_confirmation_mode: bool = false,
    branch_switch_mode: bool = false,
    branch_switch_query_mode: bool = false,
    branch_switch_query_len: usize = 0,
    branch_switch_pending: bool = false,
    remote_error_mode: bool = false,
    remote_error_interactive: bool = false,
    remote_action_cancelable: bool = false,
    active_selection_gesture: bool = false,
    command_line_active: bool = false,
    repository_command_available: bool = false,
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
    remote_error_scroll_up,
    remote_error_scroll_down,
    remote_error_page_up,
    remote_error_page_down,
    copy_popup,
    confirm_discard_file,
    cancel_discard_file,
    confirm_amend,
    cancel_amend,
    confirm_push,
    cancel_push,
    confirm_pull,
    cancel_pull,
    close_remote_error,
    run_interactive_push,
};

pub fn eventToMsg(context: KeyContext, event: chasen.Event) ?app_message.Msg {
    return switch (event) {
        .key_press => |key| keyToMsg(context, key),
        .paste => |text| pasteToMsg(context, text),
        .winsize => |winsize| .{ .terminal_resized = .{
            .width = winsize.cols,
            .height = winsize.rows,
        } },
        else => null,
    };
}

fn pasteToMsg(context: KeyContext, text: []const u8) ?app_message.Msg {
    if (context.create_stash != null) return .{ .stash = .{ .paste = text } };
    if (context.command_line_active) return .{ .command_line = if (text.len > 0 and std.unicode.utf8ValidateSlice(text))
        .{ .paste = text }
    else
        .owned_noop };
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    // Picker search is key-event-only.
    if (context.active_page == .compare and context.compare.base_picker_open) return null;
    if (context.active_page == .changes and (context.changes.search_mode or context.changes.file_search_mode)) {
        const changes_msg = changes_input.pasteToMsg(context.changes, text) orelse return null;
        return translateChangesMsg(changes_msg);
    }
    if (context.active_page == .repository and (context.repository.source_search_mode or context.repository.file_search_mode)) {
        const repository_msg = repository_input.pasteToMsg(repository_page.Msg, context.repository, text) orelse return null;
        return .{ .repository = repository_msg };
    }
    if (context.active_page == .history and (context.history.common.search_mode or context.history.common.file_search_mode)) {
        const msg = history_input.pasteToMsg(context.history, text) orelse return null;
        return .{ .history = msg };
    }
    if (context.active_page == .compare and (context.compare.common.search_mode or context.compare.common.file_search_mode)) {
        const msg = compare_input.pasteToMsg(context.compare, text) orelse return null;
        return .{ .compare = msg };
    }
    if (context.repo_picker_mode) return .{ .repo_picker_paste = text };
    if (context.help_mode or context.discard_confirmation_mode or context.amend_confirmation_mode or context.push_confirmation_mode or context.pull_confirmation_mode or context.branch_switch_mode or context.remote_error_mode) return null;
    if (context.commit_panel_mode) return .{ .commit_panel_paste = text };
    if (context.active_page == .history) {
        const msg = history_input.pasteToMsg(context.history, text) orelse return null;
        return .{ .history = msg };
    }
    if (context.active_page == .changes) {
        const changes_msg = changes_input.pasteToMsg(context.changes, text) orelse return null;
        return translateChangesMsg(changes_msg);
    }
    return null;
}

pub fn keyToMsg(context: KeyContext, key: chasen.Key) ?app_message.Msg {
    if (context.create_stash) |dialog| {
        if (key.matches(chasen.Key.escape, .{})) return .{ .stash = .cancel };
        if (key.matches(chasen.Key.enter, .{})) return .{ .stash = .confirm };
        if (key.matches(chasen.Key.tab, .{})) return .{ .stash = .tab };
        if (dialog.focus == .scope) {
            if (key.matches(chasen.Key.up, .{})) return .{ .stash = .scope_previous };
            if (key.matches(chasen.Key.down, .{})) return .{ .stash = .scope_next };
        } else if (dialog.message.handleEvent(.{ .key_press = key })) |msg| return .{ .stash = .{ .text = msg } };
        return null;
    }
    if (context.command_line_active) return .{ .command_line = commandLineKeyToMsg(key) };
    if (context.remote_action_cancelable and key.matches(chasen.Key.escape, .{}))
        return app_message.Msg.cancel_remote_action;
    if (context.active_page == .changes and (context.changes.search_mode or context.changes.file_search_mode)) {
        const changes_msg = changes_input.keyToMsg(context.changes, key) orelse return null;
        return translateChangesMsg(changes_msg);
    }
    if (context.active_page == .repository and (context.repository.source_search_mode or context.repository.file_search_mode)) {
        const repository_msg = repository_input.keyToMsg(repository_page.Msg, context.repository, key) orelse return null;
        return .{ .repository = repository_msg };
    }
    if (context.active_page == .history and
        (context.history.common.search_mode or context.history.common.file_search_mode))
    {
        const msg = history_input.keyToMsg(context.history, key) orelse return null;
        return .{ .history = msg };
    }
    if (context.active_page == .compare and
        (context.compare.common.search_mode or context.compare.common.file_search_mode or
            context.compare.base_picker_open))
    {
        const msg = compare_input.keyToMsg(context.compare, key) orelse return null;
        return .{ .compare = msg };
    }
    if (context.repo_picker_mode) return repoPickerKeyToMsg(context, key);
    if (context.help_mode) return helpKeyToMsg(context, key);
    if (context.discard_confirmation_mode) return discardConfirmationKeyToMsg(key);
    if (context.amend_confirmation_mode) return amendConfirmationKeyToMsg(key);
    if (context.push_confirmation_mode) return pushConfirmationKeyToMsg(key);
    if (context.pull_confirmation_mode) return pullConfirmationKeyToMsg(key);
    if (context.branch_switch_mode) return branchSwitchKeyToMsg(context, key);
    if (context.remote_error_mode) return remoteErrorKeyToMsg(key, context.remote_error_interactive);
    if (context.commit_panel_mode) return commitPanelKeyToMsg(key);
    if (context.active_page == .history and context.history.loading) {
        const routing_key = normalRoutingKey(key);
        if (pageForKey(context.keymap, routing_key)) |target| return .{ .switch_page = target };
        if (routing_key.codepoint == 'q' and !key_input.hasCommandModifier(routing_key)) return app_message.Msg.quit;
        return .{ .history = history_input.keyToMsg(context.history, routing_key) orelse .owned_noop };
    }
    if (selectionKeyToMsg(context, key)) |msg| return msg;
    const routing_key = normalRoutingKey(key);
    if (pageForKey(context.keymap, routing_key)) |target| return .{ .switch_page = target };
    if (context.keymap.spec(.help)) |spec| if (spec.matches(routing_key)) return app_message.Msg.open_help;
    if (context.keymap.spec(.repo_picker)) |spec| if (spec.matches(routing_key)) return app_message.Msg.enter_repo_picker;
    if (context.keymap.spec(.reload)) |spec| if (spec.matches(routing_key)) return app_message.Msg.reload;

    if (context.active_page == .changes) {
        if (context.keymap.spec(.create_stash)) |spec| if (spec.matches(routing_key)) {
            if (context.changes.selection_owner != .none or context.active_selection_gesture) return null;
            return .{ .stash = .open };
        };
    }
    if (context.active_page != .config) {
        if (context.keymap.spec(.branch_switch)) |spec| if (spec.matches(routing_key)) {
            const selection_owned = switch (context.active_page) {
                .changes => context.changes.selection_owner != .none,
                .repository => context.repository.selection_owner != .none,
                .history => context.history.common.selection_owner != .none,
                .compare => context.compare.common.selection_owner != .none,
                else => unreachable,
            };
            if (selection_owned or context.active_selection_gesture) return null;
            return .request_branch_switch;
        };
    }

    // Repository configured actions claim the canonical logical key even
    // when their current precondition or page handler returns no message.
    // Only a truly unclaimed colon may open the local command session.
    if (context.active_page == .repository and context.repository.keymap.actionForKey(routing_key) != null) {
        if (repository_input.keyToMsg(repository_page.Msg, context.repository, routing_key)) |repository_msg| {
            return .{ .repository = repository_msg };
        }
        return .{ .command_line = .owned_noop };
    }
    if (context.active_page == .repository and
        context.repository_command_available and
        isLogicalColon(key))
    {
        return .{ .command_line = .open };
    }
    if (context.active_page == .changes) {
        if (changes_input.keyToMsg(context.changes, routing_key)) |changes_msg| {
            return translateChangesMsg(changes_msg);
        }
    }
    if (context.active_page == .repository) {
        if (repository_input.keyToMsg(repository_page.Msg, context.repository, routing_key)) |repository_msg| {
            return .{ .repository = repository_msg };
        }
    }
    if (context.active_page == .history) {
        if (history_input.keyToMsg(context.history, routing_key)) |msg| return .{ .history = msg };
    }
    if (context.active_page == .compare) {
        if (compare_input.keyToMsg(context.compare, routing_key)) |msg| {
            return .{ .compare = msg };
        }
    }
    if (routing_key.codepoint == 'q' and !key_input.hasCommandModifier(routing_key)) return app_message.Msg.quit;
    return null;
}

fn commandLineKeyToMsg(key: chasen.Key) command_line.Msg {
    if (key.matches(chasen.Key.escape, .{})) return .cancel;
    if (key.matches(chasen.Key.enter, .{})) return .submit;
    if (key.matches(chasen.Key.backspace, .{})) return .backspace;
    if (key.matches(chasen.Key.left, .{})) return .move_left;
    if (key.matches(chasen.Key.right, .{})) return .move_right;
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .insert = codepoint };
    return .owned_noop;
}

fn isLogicalColon(key: chasen.Key) bool {
    return key_input.textInputCodepoint(key) == ':';
}

fn normalRoutingKey(key: chasen.Key) chasen.Key {
    return if (isLogicalColon(key)) .{ .codepoint = ':' } else key;
}

fn selectionKeyToMsg(context: KeyContext, key: chasen.Key) ?app_message.Msg {
    return switch (context.active_page) {
        .changes => translateChangesMsg(changes_input.selectionKeyToMsg(context.changes, key) orelse return null),
        .compare => .{ .compare = compare_input.selectionKeyToMsg(context.compare, key) orelse return null },
        .repository => .{ .repository = repository_input.selectionKeyToMsg(
            repository_page.Msg,
            context.repository,
            key,
        ) orelse return null },
        .history => .{ .history = history_input.selectionKeyToMsg(context.history, key) orelse return null },
        .config => null,
    };
}

fn pageForKey(effective: keymap.Effective, key: chasen.Key) ?page.Id {
    const bindings = [_]struct { action: keymap.PublicAction, id: page.Id }{
        .{ .action = .page_changes, .id = .changes },
        .{ .action = .page_repository, .id = .repository },
        .{ .action = .page_history, .id = .history },
        .{ .action = .page_compare, .id = .compare },
        .{ .action = .page_config, .id = .config },
    };
    for (bindings) |binding| {
        const spec = effective.spec(binding.action) orelse continue;
        if (spec.matches(key)) return binding.id;
    }
    return null;
}

fn translateChangesMsg(msg: changes_input.Msg) app_message.Msg {
    return .{ .changes = msg };
}

fn repoPickerKeyToMsg(context: KeyContext, key: chasen.Key) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(.cancel_repo_picker);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(.submit_repo_picker);

    switch (context.repo_picker_input_mode) {
        .list => {
            if (key.codepoint == 'q' and !key_input.hasCommandModifier(key)) return actionToMsg(.close_repo_picker);
            if (key.codepoint == '/' and !key_input.hasCommandModifier(key)) return actionToMsg(.repo_picker_enter_filter_input);
            if (key.codepoint == 'p' and !key_input.hasCommandModifier(key)) return actionToMsg(.repo_picker_enter_path_input);
            if (key.codepoint == 'b' and !key_input.hasCommandModifier(key)) return actionToMsg(.repo_picker_back);
            if (key.codepoint == 'd' and !key_input.hasCommandModifier(key)) return actionToMsg(.repo_picker_remove_recent);
            if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return actionToMsg(.repo_picker_move_previous);
            if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return actionToMsg(.repo_picker_move_next);
        },
        .filter => {
            if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(.repo_picker_backspace);
            if (key.matches(chasen.Key.left, .{})) return actionToMsg(.repo_picker_move_left);
            if (key.matches(chasen.Key.right, .{})) return actionToMsg(.repo_picker_move_right);
            if (key.matches(chasen.Key.up, .{})) return actionToMsg(.repo_picker_move_previous);
            if (key.matches(chasen.Key.down, .{})) return actionToMsg(.repo_picker_move_next);
            if (key_input.textInputCodepoint(key)) |codepoint| return .{ .repo_picker_insert = codepoint };
        },
        .path_input => {
            if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(.repo_picker_backspace);
            if (key.matches(chasen.Key.left, .{})) return actionToMsg(.repo_picker_move_left);
            if (key.matches(chasen.Key.right, .{})) return actionToMsg(.repo_picker_move_right);
            if (key.matches(chasen.Key.up, .{}) or key.matches(chasen.Key.down, .{})) return null;
            if (key_input.textInputCodepoint(key)) |codepoint| return .{ .repo_picker_insert = codepoint };
        },
    }
    return null;
}

fn helpKeyToMsg(context: KeyContext, key: chasen.Key) ?app_message.Msg {
    if (context.keymap.spec(.help)) |spec| {
        if (spec.matches(key)) return actionToMsg(.close_help);
    }
    if (context.keymap.spec(.commit)) |spec| {
        if (spec.matches(key)) return translateChangesMsg(.enter_commit_panel);
    }
    if (helpActionForKey(key)) |action| return actionToMsg(action);
    return null;
}

fn discardConfirmationKeyToMsg(key: chasen.Key) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(.cancel_discard_file);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(.confirm_discard_file);
    return null;
}

fn amendConfirmationKeyToMsg(key: chasen.Key) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(.cancel_amend);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(.confirm_amend);
    return null;
}

fn pushConfirmationKeyToMsg(key: chasen.Key) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(.cancel_push);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(.confirm_push);
    return null;
}

fn pullConfirmationKeyToMsg(key: chasen.Key) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return actionToMsg(.cancel_pull);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(.confirm_pull);
    return null;
}

fn branchSwitchKeyToMsg(context: KeyContext, key: chasen.Key) ?app_message.Msg {
    if (context.branch_switch_pending) {
        if (key.matches(chasen.Key.escape, .{}) or key.codepoint == 'q') return .cancel_branch_switch;
        return null;
    }
    const action = branch_picker.keyToAction(.{
        .query_mode = context.branch_switch_query_mode,
        .query_len = context.branch_switch_query_len,
    }, key) orelse return null;
    return switch (action) {
        .confirm => .confirm_branch_switch,
        .cancel => .cancel_branch_switch,
        .previous => .branch_switch_move_previous,
        .next => .branch_switch_move_next,
        .enter_query => .branch_switch_enter_query,
        .leave_query => .branch_switch_leave_query,
        .clear_query => .branch_switch_clear_query,
        .insert => |codepoint| .{ .branch_switch_insert = codepoint },
        .backspace => .branch_switch_backspace,
    };
}

fn remoteErrorKeyToMsg(key: chasen.Key, interactive: bool) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{}) or key.matches(chasen.Key.enter, .{}) or key.codepoint == 'q') return actionToMsg(.close_remote_error);
    if (interactive and key.codepoint == 'i' and !key_input.hasCommandModifier(key)) return actionToMsg(.run_interactive_push);
    if (key.codepoint == 'y' and !key_input.hasCommandModifier(key)) return actionToMsg(.copy_popup);
    if (key.matches(chasen.Key.up, .{}) or key.codepoint == 'k') return actionToMsg(.remote_error_scroll_up);
    if (key.matches(chasen.Key.down, .{}) or key.codepoint == 'j') return actionToMsg(.remote_error_scroll_down);
    if (key.matches(chasen.Key.page_up, .{})) return actionToMsg(.remote_error_page_up);
    if (key.matches(chasen.Key.page_down, .{})) return actionToMsg(.remote_error_page_down);
    return null;
}

fn commitPanelKeyToMsg(key: chasen.Key) ?app_message.Msg {
    if (key.matches(chasen.Key.escape, .{})) return actionToMsg(.cancel_commit_panel);
    if (key.matches('g', .{ .ctrl = true })) return actionToMsg(.assist_commit_message);
    if (key.matches('y', .{ .ctrl = true })) return actionToMsg(.copy_commit_message);
    if (key.matches(chasen.Key.enter, .{ .ctrl = true }) or key.matches('s', .{ .ctrl = true })) return actionToMsg(.submit_commit_panel);
    if (key.matches(chasen.Key.tab, .{})) return actionToMsg(.commit_panel_tab);
    if (key.matches(chasen.Key.enter, .{})) return actionToMsg(.commit_panel_enter);
    if (key.matches(chasen.Key.backspace, .{})) return actionToMsg(.commit_panel_backspace);
    if (key.matches(chasen.Key.left, .{})) return actionToMsg(.commit_panel_move_left);
    if (key.matches(chasen.Key.right, .{})) return actionToMsg(.commit_panel_move_right);
    if (key.matches(chasen.Key.up, .{})) return actionToMsg(.commit_panel_move_up);
    if (key.matches(chasen.Key.down, .{})) return actionToMsg(.commit_panel_move_down);
    if (key_input.textInputCodepoint(key)) |codepoint| return .{ .commit_panel_insert = codepoint };
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

fn actionToMsg(action: Action) app_message.Msg {
    return switch (action) {
        .cancel_commit_panel => app_message.Msg.cancel_commit_panel,
        .submit_commit_panel => app_message.Msg.submit_commit_panel,
        .assist_commit_message => app_message.Msg.assist_commit_message,
        .copy_commit_message => app_message.Msg.copy_commit_message,
        .commit_panel_tab => app_message.Msg.commit_panel_tab,
        .commit_panel_enter => app_message.Msg.commit_panel_enter,
        .commit_panel_backspace => app_message.Msg.commit_panel_backspace,
        .commit_panel_move_left => app_message.Msg.commit_panel_move_left,
        .commit_panel_move_right => app_message.Msg.commit_panel_move_right,
        .commit_panel_move_up => app_message.Msg.commit_panel_move_up,
        .commit_panel_move_down => app_message.Msg.commit_panel_move_down,
        .cancel_repo_picker => app_message.Msg.cancel_repo_picker,
        .close_repo_picker => app_message.Msg.close_repo_picker,
        .submit_repo_picker => app_message.Msg.submit_repo_picker,
        .repo_picker_enter_filter_input => app_message.Msg.repo_picker_enter_filter_input,
        .repo_picker_enter_path_input => app_message.Msg.repo_picker_enter_path_input,
        .repo_picker_back => app_message.Msg.repo_picker_back,
        .repo_picker_remove_recent => app_message.Msg.repo_picker_remove_recent,
        .repo_picker_backspace => app_message.Msg.repo_picker_backspace,
        .repo_picker_move_previous => app_message.Msg.repo_picker_move_previous,
        .repo_picker_move_next => app_message.Msg.repo_picker_move_next,
        .repo_picker_move_left => app_message.Msg.repo_picker_move_left,
        .repo_picker_move_right => app_message.Msg.repo_picker_move_right,
        .close_help => app_message.Msg.close_help,
        .help_scroll_up => app_message.Msg.help_scroll_up,
        .help_scroll_down => app_message.Msg.help_scroll_down,
        .help_page_up => app_message.Msg.help_page_up,
        .help_page_down => app_message.Msg.help_page_down,
        .remote_error_scroll_up => app_message.Msg.remote_error_scroll_up,
        .remote_error_scroll_down => app_message.Msg.remote_error_scroll_down,
        .remote_error_page_up => app_message.Msg.remote_error_page_up,
        .remote_error_page_down => app_message.Msg.remote_error_page_down,
        .copy_popup => app_message.Msg.copy_popup,
        .confirm_discard_file => app_message.Msg.confirm_discard_file,
        .cancel_discard_file => app_message.Msg.cancel_discard_file,
        .confirm_amend => app_message.Msg.confirm_amend,
        .cancel_amend => app_message.Msg.cancel_amend,
        .confirm_push => app_message.Msg.confirm_push,
        .cancel_push => app_message.Msg.cancel_push,
        .confirm_pull => app_message.Msg.confirm_pull,
        .cancel_pull => app_message.Msg.cancel_pull,
        .close_remote_error => app_message.Msg.close_remote_error,
        .run_interactive_push => app_message.Msg.run_interactive_push,
    };
}

fn changesMsg(msg: changes_input.Msg) app_message.Msg {
    return .{ .changes = msg };
}

fn expectMsg(expected: app_message.Msg, actual: app_message.Msg) !void {
    try std.testing.expectEqual(expected, actual);
}

test "root page routing respects modes and remapped keys" {
    try expectMsg(.{ .switch_page = .changes }, keyToMsg(.{}, .{ .codepoint = '1' }).?);
    try expectMsg(.{ .switch_page = .config }, keyToMsg(.{}, .{ .codepoint = '5' }).?);
    try std.testing.expectEqual(changesMsg(.{ .search_insert = '2' }), keyToMsg(.{ .changes = .{ .search_mode = true } }, .{ .codepoint = '2' }).?);
    try expectMsg(.{ .commit_panel_insert = '3' }, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = '3' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{}, .{ .codepoint = '2', .mods = .{ .ctrl = true } }));
    try expectMsg(.{ .repository = .move_down }, keyToMsg(.{ .active_page = .repository }, .{ .codepoint = 'j' }).?);

    var config: keymap.Config = .{};
    config.set(.page_repository, .{ .plain_codepoint = 'w' });
    const remapped = keymap.Effective.fromConfig(config);
    try expectMsg(.{ .switch_page = .repository }, keyToMsg(.{ .keymap = remapped }, .{ .codepoint = 'w' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .keymap = remapped }, .{ .codepoint = '2' }));
}

test "History catalog loading admits only cancel page transition and quit" {
    const context: KeyContext = .{
        .active_page = .history,
        .history = .{ .loading = true },
    };
    try expectMsg(.{ .history = .cancel_load }, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try expectMsg(.{ .switch_page = .compare }, keyToMsg(context, .{ .codepoint = '4' }).?);
    try expectMsg(.quit, keyToMsg(context, .{ .codepoint = 'q' }).?);
    try expectMsg(.{ .history = .owned_noop }, keyToMsg(context, .{ .codepoint = 'j' }).?);
    try expectMsg(.{ .history = .owned_noop }, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try expectMsg(.{ .history = .owned_noop }, pasteToMsg(context, "ignored").?);

    const failed_with_previous: KeyContext = .{
        .active_page = .history,
        .history = .{ .return_to_accepted = true },
    };
    try expectMsg(.reload, keyToMsg(failed_with_previous, .{ .codepoint = 'r' }).?);
    try expectMsg(
        .{ .history = .cancel_draft },
        keyToMsg(failed_with_previous, .{ .codepoint = chasen.Key.escape }).?,
    );
}

test "History committed diff text input precedes page shortcuts and picker key stays local" {
    const searching: KeyContext = .{
        .active_page = .history,
        .history = .{
            .diff_view = true,
            .common = .{ .search_mode = true },
        },
    };
    try expectMsg(
        .{ .history = .{ .common = .{ .shared = .{ .search_insert = '4' } } } },
        keyToMsg(searching, .{ .codepoint = '4' }).?,
    );
    try expectMsg(
        .{ .history = .{ .common = .{ .shared = .{ .search_paste = "needle" } } } },
        pasteToMsg(searching, "needle").?,
    );

    var normal = searching;
    normal.history.common.search_mode = false;
    try expectMsg(.{ .switch_page = .compare }, keyToMsg(normal, .{ .codepoint = '4' }).?);
    try expectMsg(.{ .history = .open_picker }, keyToMsg(normal, .{ .codepoint = 'm' }).?);
    try expectMsg(
        .{ .history = .{ .common = .copy_current_line } },
        keyToMsg(normal, .{ .codepoint = 'y' }).?,
    );
    try expectMsg(
        .{ .history = .copy_detail },
        keyToMsg(.{ .active_page = .history, .history = .{
            .picker_ready = true,
            .focus = .commit_detail,
        } }, .{ .codepoint = 'y' }).?,
    );
    try expectMsg(
        .{ .history = .owned_noop },
        keyToMsg(.{ .active_page = .history, .history = .{ .picker_ready = true } }, .{ .codepoint = 'y' }).?,
    );
    try expectMsg(.{ .changes = .copy_current_line }, keyToMsg(.{}, .{ .codepoint = 'y' }).?);
    try expectMsg(
        .{ .compare = .{ .common = .copy_current_line } },
        keyToMsg(.{ .active_page = .compare }, .{ .codepoint = 'y' }).?,
    );
}

test "History picker leaves i unclaimed so configured page routing wins" {
    var config: keymap.Config = .{};
    config.set(.page_changes, .{ .plain_codepoint = 'i' });
    const effective = keymap.Effective.fromConfig(config);
    try expectMsg(
        .{ .switch_page = .changes },
        keyToMsg(.{
            .active_page = .history,
            .history = .{ .picker_ready = true, .keymap = effective },
            .keymap = effective,
        }, .{ .codepoint = 'i' }).?,
    );
    try std.testing.expect(keyToMsg(.{
        .active_page = .history,
        .history = .{ .picker_ready = true },
    }, .{ .codepoint = 'i' }) == null);
}

test "command line owns key and paste input before every normal route" {
    const context: KeyContext = .{
        .active_page = .repository,
        .command_line_active = true,
        .repository_command_available = true,
    };
    try expectMsg(.{ .command_line = .cancel }, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try expectMsg(.{ .command_line = .submit }, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try expectMsg(.{ .command_line = .backspace }, keyToMsg(context, .{ .codepoint = chasen.Key.backspace }).?);
    try expectMsg(.{ .command_line = .move_left }, keyToMsg(context, .{ .codepoint = chasen.Key.left }).?);
    try expectMsg(.{ .command_line = .move_right }, keyToMsg(context, .{ .codepoint = chasen.Key.right }).?);
    try expectMsg(.{ .command_line = .{ .insert = '2' } }, keyToMsg(context, .{ .codepoint = '2' }).?);
    try expectMsg(.{ .command_line = .owned_noop }, keyToMsg(context, .{ .codepoint = chasen.Key.up }).?);
    try expectMsg(.{ .command_line = .{ .paste = "20🐈" } }, pasteToMsg(context, "20🐈").?);
    try expectMsg(.{ .command_line = .owned_noop }, pasteToMsg(context, "").?);
}

test "repository logical colon preserves configured claims before command open" {
    const keys = [_]chasen.Key{
        .{ .codepoint = ':' },
        shiftedAscii(';', ':'),
    };

    var root_config: keymap.Config = .{};
    root_config.set(.page_changes, .{ .plain_codepoint = ':' });
    const root_keymap = keymap.Effective.fromConfig(root_config);
    for (keys) |key| try expectMsg(
        .{ .switch_page = .changes },
        keyToMsg(.{
            .active_page = .repository,
            .repository_command_available = true,
            .keymap = root_keymap,
            .repository = .{ .focus = .source, .source_available = true, .keymap = root_keymap },
        }, key).?,
    );

    var page_config: keymap.Config = .{};
    page_config.set(.toggle_line_numbers, .{ .plain_codepoint = ':' });
    const page_keymap = keymap.Effective.fromConfig(page_config);
    for (keys) |key| try expectMsg(
        .{ .repository = .toggle_line_numbers },
        keyToMsg(.{
            .active_page = .repository,
            .repository_command_available = true,
            .keymap = page_keymap,
            .repository = .{ .focus = .source, .source_available = true, .keymap = page_keymap },
        }, key).?,
    );

    var unsupported_config: keymap.Config = .{};
    unsupported_config.set(.open_editor, .{ .plain_codepoint = ':' });
    const unsupported_keymap = keymap.Effective.fromConfig(unsupported_config);
    for (keys) |key| try expectMsg(
        .{ .command_line = .owned_noop },
        keyToMsg(.{
            .active_page = .repository,
            .repository_command_available = true,
            .keymap = unsupported_keymap,
            .repository = .{ .focus = .source, .source_available = true, .keymap = unsupported_keymap },
        }, key).?,
    );
}

test "repository unclaimed literal and shifted colon open the same command line" {
    const context: KeyContext = .{
        .active_page = .repository,
        .repository_command_available = true,
        .repository = .{ .focus = .source, .source_available = true },
    };
    try expectMsg(.{ .command_line = .open }, keyToMsg(context, .{ .codepoint = ':' }).?);
    try expectMsg(.{ .command_line = .open }, keyToMsg(context, shiftedAscii(';', ':')).?);
    try std.testing.expect(keyToMsg(.{
        .active_page = .repository,
        .repository_command_available = false,
        .repository = context.repository,
    }, .{ .codepoint = ':' }) == null);
}

test "root selection preflight preserves modal and configured V precedence" {
    var root_config: keymap.Config = .{};
    root_config.set(.page_repository, .{ .plain_codepoint = 'V' });
    const root_keymap = keymap.Effective.fromConfig(root_config);
    const v = chasen.Key{ .codepoint = 'V' };

    try std.testing.expectEqual(
        app_message.Msg{ .switch_page = .repository },
        keyToMsg(.{ .keymap = root_keymap, .changes = .{ .focus = .diff } }, v).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .switch_page = .repository },
        keyToMsg(.{
            .keymap = root_keymap,
            .changes = .{ .focus = .diff, .retained_selection_action_available = true },
        }, v).?,
    );
    try std.testing.expectEqual(
        changesMsg(.selection_owned_noop),
        keyToMsg(.{
            .keymap = root_keymap,
            .changes = .{ .focus = .diff, .selection_owner = .keyboard_line, .retained_selection_action_available = true },
        }, v).?,
    );
    try std.testing.expectEqual(
        changesMsg(.selection_owned_noop),
        keyToMsg(.{ .keymap = root_keymap, .changes = .{ .focus = .diff, .selection_owner = .mouse } }, v).?,
    );
    try std.testing.expectEqual(
        changesMsg(.selection_owned_noop),
        keyToMsg(.{ .keymap = root_keymap, .changes = .{ .focus = .diff, .selection_owner = .header } }, v).?,
    );
    try std.testing.expectEqual(
        changesMsg(.begin_keyboard_line_selection),
        keyToMsg(.{ .changes = .{ .focus = .diff } }, v).?,
    );

    var page_config: keymap.Config = .{};
    page_config.set(.toggle_line_numbers, .{ .plain_codepoint = 'V' });
    const page_keymap = keymap.Effective.fromConfig(page_config);
    try std.testing.expectEqual(
        changesMsg(.toggle_line_numbers),
        keyToMsg(.{
            .changes = .{ .focus = .diff, .retained_selection_action_available = true, .keymap = page_keymap },
        }, v).?,
    );

    const active: KeyContext = .{
        .changes = .{
            .focus = .diff,
            .selection_owner = .keyboard_line,
            .retained_selection_action_available = true,
        },
    };
    try std.testing.expectEqual(changesMsg(.selection_action_unavailable), keyToMsg(active, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(changesMsg(.{ .selection_action = .clear }), keyToMsg(active, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(changesMsg(.scroll_diff_left), keyToMsg(active, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(
        changesMsg(.{ .switch_keyboard_selection_side = .old }),
        keyToMsg(.{ .changes = .{
            .focus = .diff,
            .side_by_side = true,
            .selection_owner = .keyboard_line,
        } }, .{ .codepoint = chasen.Key.left }).?,
    );
    try std.testing.expectEqual(
        changesMsg(.{ .choose_keyboard_selection_side = .new }),
        keyToMsg(.{ .changes = .{
            .focus = .diff,
            .side_by_side = true,
            .selection_owner = .keyboard_side_choice,
        } }, .{ .codepoint = 'l' }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .compare = .{ .common = .{ .shared = .scroll_diff_right } } },
        keyToMsg(.{
            .active_page = .compare,
            .compare = .{ .common = .{ .focus = .diff, .selection_owner = .keyboard_line } },
        }, .{ .codepoint = chasen.Key.right }).?,
    );
    try std.testing.expectEqual(
        changesMsg(.expand_directory),
        keyToMsg(.{ .changes = .{ .focus = .sidebar, .selection_owner = .mouse } }, .{ .codepoint = chasen.Key.right }).?,
    );
    try std.testing.expectEqual(
        changesMsg(.collapse_or_parent_directory),
        keyToMsg(.{ .changes = .{ .focus = .sidebar, .selection_owner = .header } }, .{ .codepoint = chasen.Key.left }).?,
    );
    try std.testing.expectEqual(app_message.Msg.cancel_remote_action, keyToMsg(.{
        .remote_action_cancelable = true,
        .changes = active.changes,
    }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(changesMsg(.cancel_search), keyToMsg(.{
        .changes = .{
            .search_mode = true,
            .selection_owner = .keyboard_line,
            .retained_selection_action_available = true,
        },
    }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.close_help, keyToMsg(.{
        .help_mode = true,
        .changes = active.changes,
    }, .{ .codepoint = chasen.Key.escape }).?);
}

test "root selection preflight routes Repository owners before configured actions" {
    const v = chasen.Key{ .codepoint = 'V' };
    var root_config: keymap.Config = .{};
    root_config.set(.page_changes, .{ .plain_codepoint = 'V' });
    const root_keymap = keymap.Effective.fromConfig(root_config);

    try std.testing.expectEqual(
        app_message.Msg{ .switch_page = .changes },
        keyToMsg(.{
            .active_page = .repository,
            .keymap = root_keymap,
            .repository = .{ .retained_selection_action_available = true },
        }, v).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .selection_owned_noop },
        keyToMsg(.{
            .active_page = .repository,
            .keymap = root_keymap,
            .repository = .{ .selection_owner = .keyboard_line },
        }, v).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .begin_keyboard_line_selection },
        keyToMsg(.{ .active_page = .repository }, v).?,
    );

    var page_config: keymap.Config = .{};
    page_config.set(.toggle_line_numbers, .{ .plain_codepoint = 'V' });
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .toggle_line_numbers },
        keyToMsg(.{
            .active_page = .repository,
            .repository = .{
                .retained_selection_action_available = true,
                .keymap = keymap.Effective.fromConfig(page_config),
            },
        }, v).?,
    );

    const active: KeyContext = .{
        .active_page = .repository,
        .repository = .{
            .focus = .source,
            .selection_owner = .keyboard_line,
            .retained_selection_action_available = true,
        },
    };
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .{ .keyboard_line_selection_move = .down } },
        keyToMsg(active, .{ .codepoint = 'j' }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .{ .selection_action = .copy } },
        keyToMsg(active, .{ .codepoint = 'y' }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .selection_action_unavailable },
        keyToMsg(active, .{ .codepoint = 'a' }).?,
    );
    for ([_]repository_input.Context{
        .{ .selection_owner = .mouse, .retained_selection_action_available = true },
        .{ .selection_owner = .header, .retained_selection_action_available = true },
    }) |repository| {
        const context: KeyContext = .{ .active_page = .repository, .repository = repository };
        try std.testing.expectEqual(
            app_message.Msg{ .repository = .selection_owned_noop },
            keyToMsg(context, .{ .codepoint = 'y' }).?,
        );
        try std.testing.expectEqual(
            app_message.Msg{ .repository = .selection_owned_noop },
            keyToMsg(context, .{ .codepoint = 'j' }).?,
        );
        try std.testing.expectEqual(
            app_message.Msg{ .repository = .selection_owned_noop },
            keyToMsg(context, v).?,
        );
        try std.testing.expectEqual(
            app_message.Msg{ .repository = .{ .selection_action = .clear } },
            keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?,
        );
    }
    const retained: KeyContext = .{
        .active_page = .repository,
        .repository = .{ .retained_selection_action_available = true },
    };
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .{ .selection_action = .copy } },
        keyToMsg(retained, .{ .codepoint = 'y' }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .selection_action_unavailable },
        keyToMsg(retained, .{ .codepoint = 'a' }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg.cancel_remote_action,
        keyToMsg(.{
            .active_page = .repository,
            .remote_action_cancelable = true,
            .repository = active.repository,
        }, .{ .codepoint = chasen.Key.escape }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .cancel_source_search },
        keyToMsg(.{
            .active_page = .repository,
            .repository = .{ .source_search_mode = true, .selection_owner = .keyboard_line },
        }, .{ .codepoint = chasen.Key.escape }).?,
    );
}

test "repository context root routing respects owner and text input priority" {
    const upper_y: chasen.Key = .{ .codepoint = 'Y' };
    for ([_]KeyContext{
        .{ .active_page = .repository, .repository = .{ .selection_owner = .keyboard_line } },
        .{ .active_page = .repository, .repository = .{ .retained_selection_action_available = true } },
    }) |context| {
        try expectMsg(.{ .repository = .{ .selection_action = .copy_context } }, keyToMsg(context, upper_y).?);
    }
    try expectMsg(.{ .repository = .selection_owned_noop }, keyToMsg(.{
        .active_page = .repository,
        .repository = .{ .selection_owner = .mouse },
    }, upper_y).?);
    try expectMsg(.{ .command_line = .owned_noop }, keyToMsg(.{ .active_page = .repository }, upper_y).?);
    try expectMsg(.{ .command_line = .owned_noop }, keyToMsg(.{
        .active_page = .repository,
        .repository = .{ .selection_owner = .header },
    }, upper_y).?);
    try expectMsg(.{ .repository = .{ .source_search_insert = 'Y' } }, keyToMsg(.{
        .active_page = .repository,
        .repository = .{ .source_search_mode = true, .selection_owner = .keyboard_line },
    }, upper_y).?);
    try expectMsg(.{ .repo_picker_insert = 'Y' }, keyToMsg(.{
        .active_page = .repository,
        .repo_picker_mode = true,
        .repo_picker_input_mode = .path_input,
        .repository = .{ .selection_owner = .keyboard_line },
    }, upper_y).?);
}

test "committed context root routing requires source capability and preserves owners" {
    const upper_y: chasen.Key = .{ .codepoint = 'Y' };
    var context: KeyContext = .{ .active_page = .compare, .compare = .{ .common = .{
        .side_by_side = true,
        .context_copy_available = true,
        .selection_owner = .keyboard_line,
    } } };
    try expectMsg(.{ .compare = .{ .common = .{ .shared = .{ .selection_action = .copy_context } } } }, keyToMsg(context, upper_y).?);
    context.compare.common.selection_owner = .mouse;
    try expectMsg(.{ .compare = .{ .common = .{ .shared = .selection_owned_noop } } }, keyToMsg(context, upper_y).?);
    context.compare.common.selection_owner = .none;
    context.compare.common.retained_selection_action_available = true;
    try expectMsg(.{ .compare = .{ .common = .{ .shared = .{ .selection_action = .copy_context } } } }, keyToMsg(context, upper_y).?);
    context.compare.common.side_by_side = false;
    try expectMsg(.{ .compare = .{ .common = .copy_current_hunk } }, keyToMsg(context, upper_y).?);
    context.compare.common.side_by_side = true;
    context.compare.common.selection_owner = .header;
    try expectMsg(.{ .compare = .{ .common = .copy_current_hunk } }, keyToMsg(context, upper_y).?);
    context.compare.common.search_mode = true;
    try expectMsg(.{ .compare = .{ .common = .{ .shared = .{ .search_insert = 'Y' } } } }, keyToMsg(context, upper_y).?);
    context.active_page = .history;
    context.history = .{ .diff_view = true, .common = .{ .side_by_side = true, .context_copy_available = true, .selection_owner = .keyboard_line } };
    try expectMsg(.{ .history = .{ .common = .{ .shared = .{ .selection_action = .copy_context } } } }, keyToMsg(context, upper_y).?);
    context.history.diff_view = false;
    try std.testing.expect(keyToMsg(context, upper_y) == null);
}

test "root selection preflight consumes document navigation only for live owners" {
    const keys = [_]chasen.Key{
        .{ .codepoint = 'g' },
        .{ .codepoint = 'G' },
        .{ .codepoint = 'u', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'd', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'b', .mods = .{ .ctrl = true } },
        .{ .codepoint = 'f', .mods = .{ .ctrl = true } },
    };
    for (keys) |key| {
        try std.testing.expectEqual(
            changesMsg(.selection_owned_noop),
            keyToMsg(.{ .changes = .{ .selection_owner = .mouse } }, key).?,
        );
        try std.testing.expectEqual(
            app_message.Msg{ .compare = .{ .common = .{ .shared = .selection_owned_noop } } },
            keyToMsg(.{ .active_page = .compare, .compare = .{ .common = .{ .selection_owner = .header } } }, key).?,
        );
        try std.testing.expectEqual(
            app_message.Msg{ .repository = .selection_owned_noop },
            keyToMsg(.{ .active_page = .repository, .repository = .{ .selection_owner = .keyboard_line } }, key).?,
        );
    }

    var config: keymap.Config = .{};
    config.set(.document_first, .{ .plain_codepoint = 'z' });
    const custom = keymap.Effective.fromConfig(config);
    const z = chasen.Key{ .codepoint = 'z' };
    try std.testing.expectEqual(changesMsg(.selection_owned_noop), keyToMsg(.{
        .keymap = custom,
        .changes = .{ .selection_owner = .mouse, .keymap = custom },
    }, z).?);
    try std.testing.expectEqual(app_message.Msg{ .compare = .{ .common = .{ .shared = .selection_owned_noop } } }, keyToMsg(.{
        .active_page = .compare,
        .keymap = custom,
        .compare = .{ .common = .{ .selection_owner = .mouse, .keymap = custom } },
    }, z).?);
    try std.testing.expectEqual(app_message.Msg{ .repository = .selection_owned_noop }, keyToMsg(.{
        .active_page = .repository,
        .keymap = custom,
        .repository = .{ .selection_owner = .mouse, .keymap = custom },
    }, z).?);

    try std.testing.expect(keyToMsg(.{ .changes = .{ .retained_selection_action_available = true } }, .{ .codepoint = 'g' }) == null);
    try std.testing.expect(keyToMsg(.{ .active_page = .compare, .compare = .{ .common = .{ .retained_selection_action_available = true } } }, .{ .codepoint = 'g' }) == null);
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .source_first },
        keyToMsg(.{ .active_page = .repository, .repository = .{
            .focus = .source,
            .source_available = true,
            .retained_selection_action_available = true,
        } }, .{ .codepoint = 'g' }).?,
    );

    var overlap_config: keymap.Config = .{};
    overlap_config.set(.copy_current_line, .{ .plain_codepoint = 'x' });
    overlap_config.set(.copy_history_detail, .{ .plain_codepoint = 'x' });
    overlap_config.set(.document_first, .{ .plain_codepoint = 'y' });
    const overlap = keymap.Effective.fromConfig(overlap_config);
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .source_first },
        keyToMsg(.{ .active_page = .repository, .keymap = overlap, .repository = .{
            .focus = .source,
            .source_available = true,
            .retained_selection_action_available = true,
            .keymap = overlap,
        } }, .{ .codepoint = 'y' }).?,
    );
}

test "root keeps Changes and Repository match keys outside document ownership" {
    try std.testing.expectEqual(
        changesMsg(.select_previous_search_match),
        keyToMsg(.{ .changes = .{ .search_query_len = 1, .selection_owner = .keyboard_line } }, .{ .codepoint = 'N' }).?,
    );

    for ([_]chasen.Key{ .{ .codepoint = 'n' }, .{ .codepoint = 'N' }, .{ .codepoint = 'p' } }) |key| {
        try std.testing.expectEqual(
            app_message.Msg{ .repository = .selection_owned_noop },
            keyToMsg(.{ .active_page = .repository, .repository = .{ .selection_owner = .header, .source_query_len = 1 } }, key).?,
        );
    }
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .previous_source_match },
        keyToMsg(.{ .active_page = .repository, .repository = .{
            .retained_selection_action_available = true,
            .source_query_len = 1,
        } }, .{ .codepoint = 'N' }).?,
    );
}

test "eventToMsg maps winsize event" {
    const msg = eventToMsg(.{}, .{ .winsize = .{
        .cols = 120,
        .rows = 40,
        .x_pixel = 0,
        .y_pixel = 0,
    } }).?;
    try expectMsg(.{ .terminal_resized = .{ .width = 120, .height = 40 } }, msg);
}

test "eventToMsg routes paste by active text input mode" {
    const search_msg = eventToMsg(.{ .changes = .{ .search_mode = true } }, .{ .paste = "render" }).?;
    try std.testing.expectEqualStrings("render", search_msg.changes.search_paste);

    const file_msg = eventToMsg(.{ .changes = .{ .file_search_mode = true } }, .{ .paste = "app.zig" }).?;
    try std.testing.expectEqualStrings("app.zig", file_msg.changes.file_search_paste);

    const source_msg = eventToMsg(.{
        .active_page = .repository,
        .repository = .{ .source_search_mode = true },
    }, .{ .paste = "needle" }).?;
    try std.testing.expectEqualStrings("needle", source_msg.repository.source_search_paste);

    const repo_msg = eventToMsg(.{ .repo_picker_mode = true }, .{ .paste = "/tmp/repo" }).?;
    try std.testing.expectEqualStrings("/tmp/repo", repo_msg.repo_picker_paste);

    const commit_msg = eventToMsg(.{ .commit_panel_mode = true }, .{ .paste = "subject" }).?;
    try std.testing.expectEqualStrings("subject", commit_msg.commit_panel_paste);
}

test "eventToMsg rejects invalid paste and ignores non-input modes" {
    const invalid = [_]u8{0xff};
    try std.testing.expect(eventToMsg(.{ .commit_panel_mode = true }, .{ .paste = invalid[0..] }) == null);
    try std.testing.expect(eventToMsg(.{}, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(.{ .help_mode = true }, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(.{ .discard_confirmation_mode = true }, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(.{ .amend_confirmation_mode = true }, .{ .paste = "ignored" }) == null);
    try std.testing.expect(eventToMsg(.{
        .active_page = .compare,
        .compare = .{
            .base_picker_open = true,
            .base_picker_query_mode = true,
            .common = .{ .search_mode = true, .file_search_mode = true },
        },
    }, .{ .paste = "must-not-leak" }) == null);
}

test "shell nests Changes void and payload messages under one route" {
    try std.testing.expectEqual(changesMsg(.toggle_directory), keyToMsg(.{ .changes = .{ .focus = .sidebar } }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(changesMsg(.{ .search_insert = 'x' }), keyToMsg(.{ .changes = .{ .search_mode = true } }, .{ .codepoint = 'x' }).?);
}

test "shell routes plain q by active Changes context" {
    try std.testing.expectEqual(app_message.Msg.quit, keyToMsg(.{}, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(changesMsg(.{ .search_insert = 'q' }), keyToMsg(.{ .changes = .{ .search_mode = true } }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(app_message.Msg.close_help, keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'q' }).?);
}

test "shell owns help repo picker and reload before Changes delegation" {
    try std.testing.expectEqual(app_message.Msg.open_help, keyToMsg(.{}, .{ .codepoint = '?' }).?);
    try std.testing.expectEqual(app_message.Msg.enter_repo_picker, keyToMsg(.{}, .{ .codepoint = 'R' }).?);
    try std.testing.expectEqual(app_message.Msg.reload, keyToMsg(.{}, .{ .codepoint = 'r' }).?);
}

test "keyToMsg maps discard confirmation flow" {
    try std.testing.expectEqual(changesMsg(.request_discard_selected_file), keyToMsg(.{}, .{ .codepoint = 'D' }).?);
    try std.testing.expectEqual(changesMsg(.request_discard_selected_file), keyToMsg(.{}, shiftedAscii('d', 'D')).?);
    try std.testing.expectEqual(changesMsg(.request_discard_selected_file), keyToMsg(.{}, shiftedLowerOnly('d')).?);
    try std.testing.expectEqual(app_message.Msg.confirm_discard_file, keyToMsg(.{ .discard_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_discard_file, keyToMsg(.{ .discard_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_discard_file, keyToMsg(.{ .discard_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .discard_confirmation_mode = true }, .{ .codepoint = 'D' }));
}

test "keyToMsg maps commit panel command and routes panel input" {
    try std.testing.expectEqual(changesMsg(.enter_commit_panel), keyToMsg(.{}, .{ .codepoint = 'c' }).?);
    try std.testing.expectEqual(changesMsg(.enter_amend_panel), keyToMsg(.{}, .{ .codepoint = 'A' }).?);
    try std.testing.expectEqual(changesMsg(.enter_amend_panel), keyToMsg(.{}, shiftedAscii('a', 'A')).?);
    try std.testing.expectEqual(changesMsg(.enter_amend_panel), keyToMsg(.{}, shiftedLowerOnly('a')).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{}, .{ .codepoint = 'a' }));
    try std.testing.expectEqual(app_message.Msg.cancel_commit_panel, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.submit_commit_panel, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.enter, .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(app_message.Msg.submit_commit_panel, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 's', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(app_message.Msg.assist_commit_message, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'g', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(app_message.Msg.copy_commit_message, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'y', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_tab, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_enter, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_backspace, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.backspace }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_move_left, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_move_right, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_move_up, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(app_message.Msg.commit_panel_move_down, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try expectMsg(.{ .commit_panel_insert = 'x' }, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'x' }).?);
    try expectMsg(.{ .commit_panel_insert = 'y' }, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'y' }).?);
    try expectMsg(.{ .commit_panel_insert = 'R' }, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'R' }).?);
    try std.testing.expectEqual(changesMsg(.enter_commit_panel), keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'c' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{}, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'c', .mods = .{ .ctrl = true } }));
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

    try std.testing.expectEqual(changesMsg(.enter_commit_panel), keyToMsg(context, .{ .codepoint = 'm' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(context, .{ .codepoint = 'c' }));
    try std.testing.expectEqual(app_message.Msg.close_help, keyToMsg(context, .{ .codepoint = 'z' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(context, .{ .codepoint = '?' }));
}

test "keyToMsg maps amend confirmation flow" {
    try std.testing.expectEqual(app_message.Msg.confirm_amend, keyToMsg(.{ .amend_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_amend, keyToMsg(.{ .amend_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_amend, keyToMsg(.{ .amend_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .amend_confirmation_mode = true }, .{ .codepoint = 'A' }));
}

test "keyToMsg prioritizes amend confirmation over open commit panel" {
    const context: KeyContext = .{
        .commit_panel_mode = true,
        .amend_confirmation_mode = true,
    };

    try std.testing.expectEqual(app_message.Msg.confirm_amend, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_amend, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_amend, keyToMsg(context, .{ .codepoint = 'q' }).?);
}

test "keyToMsg prioritizes discard confirmation over open commit panel" {
    const context: KeyContext = .{
        .commit_panel_mode = true,
        .discard_confirmation_mode = true,
    };

    try std.testing.expectEqual(app_message.Msg.confirm_discard_file, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_discard_file, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_discard_file, keyToMsg(context, .{ .codepoint = 'q' }).?);
}

test "keyToMsg treats colon as repo picker path text" {
    const context: KeyContext = .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input };
    try expectMsg(.{ .repo_picker_insert = ':' }, keyToMsg(context, .{ .codepoint = ':' }).?);
    try expectMsg(.{ .repo_picker_insert = ':' }, keyToMsg(context, shiftedAscii(';', ':')).?);
    try expectMsg(.{ .repo_picker_insert = ';' }, keyToMsg(context, shiftedLowerOnly(';')).?);
    try expectMsg(.{ .repo_picker_insert = ';' }, keyToMsg(context, .{ .codepoint = ';' }).?);
    try expectMsg(.{ .repo_picker_insert = 'q' }, keyToMsg(context, .{ .codepoint = 'q' }).?);
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
            try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .changes = .{ .search_mode = true } }, key));
        }
        if (!key.matches(chasen.Key.up, .{}) and !key.matches(chasen.Key.down, .{})) {
            try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .changes = .{ .file_search_mode = true } }, key));
        }
        if (key.codepoint != chasen.Key.tab and key.codepoint != chasen.Key.left and key.codepoint != chasen.Key.right and key.codepoint != chasen.Key.up and key.codepoint != chasen.Key.down) {
            try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .commit_panel_mode = true }, key));
        }
        if (key.codepoint != chasen.Key.left and key.codepoint != chasen.Key.right and key.codepoint != chasen.Key.up and key.codepoint != chasen.Key.down) {
            try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .repo_picker_mode = true }, key));
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
        try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .repo_picker_mode = true }, key));
    }
}

test "keyToMsg maps changes file search candidate movement" {
    const context: KeyContext = .{ .changes = .{ .file_search_mode = true } };
    try std.testing.expectEqual(changesMsg(.file_search_previous), keyToMsg(context, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(changesMsg(.file_search_next), keyToMsg(context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(changesMsg(.{ .file_search_insert = 'k' }), keyToMsg(context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(changesMsg(.{ .file_search_insert = 'j' }), keyToMsg(context, .{ .codepoint = 'j' }).?);
}

test "keyToMsg maps repo picker cursor movement" {
    const input_context: KeyContext = .{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input };
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_left, keyToMsg(input_context, .{ .codepoint = chasen.Key.left }).?);
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_right, keyToMsg(input_context, .{ .codepoint = chasen.Key.right }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(input_context, .{ .codepoint = chasen.Key.up }));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(input_context, .{ .codepoint = chasen.Key.down }));
    const filter_context: KeyContext = .{ .repo_picker_mode = true, .repo_picker_input_mode = .filter };
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_previous, keyToMsg(filter_context, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_next, keyToMsg(filter_context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_previous, keyToMsg(.{ .repo_picker_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_next, keyToMsg(.{ .repo_picker_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_previous, keyToMsg(.{ .repo_picker_mode = true }, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(app_message.Msg.repo_picker_move_next, keyToMsg(.{ .repo_picker_mode = true }, .{ .codepoint = 'j' }).?);
}

test "keyToMsg maps repo picker recent removal only in list mode" {
    try std.testing.expectEqual(app_message.Msg.repo_picker_remove_recent, keyToMsg(.{ .repo_picker_mode = true }, .{ .codepoint = 'd' }).?);
    try expectMsg(.{ .repo_picker_insert = 'd' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, .{ .codepoint = 'd' }).?);
    try expectMsg(.{ .repo_picker_insert = 'd' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = 'd' }).?);
}

test "keyToMsg ignores ctrl printable in text input modes" {
    const ctrl_c: chasen.Key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } };

    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .changes = .{ .search_mode = true } }, ctrl_c));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .changes = .{ .file_search_mode = true } }, ctrl_c));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .commit_panel_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .repo_picker_mode = true }, ctrl_c));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .repo_picker_mode = true }, ctrl_c));
}

test "keyToMsg keeps printable text input modes working" {
    try std.testing.expectEqual(changesMsg(.{ .search_insert = 'x' }), keyToMsg(.{ .changes = .{ .search_mode = true } }, .{ .codepoint = 'x' }).?);
    try std.testing.expectEqual(changesMsg(.{ .file_search_insert = 'x' }), keyToMsg(.{ .changes = .{ .file_search_mode = true } }, .{ .codepoint = 'x' }).?);
    try expectMsg(.{ .commit_panel_insert = 'x' }, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'x' }).?);
    try expectMsg(.{ .repo_picker_insert = 'x' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, .{ .codepoint = 'x' }).?);
    try expectMsg(.{ .repo_picker_insert = 'q' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, .{ .codepoint = 'q' }).?);
    try expectMsg(.{ .repo_picker_insert = 'x' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = 'x' }).?);
    try expectMsg(.{ .repo_picker_insert = ':' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = ':' }).?);
    try expectMsg(.{ .repo_picker_insert = 0x1F408 }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, .{ .codepoint = 0x1F408 }).?);
}

test "keyToMsg prefers generated text for printable text input" {
    const keypad_one: chasen.Key = .{
        .codepoint = chasen.Key.kp_1,
        .text = "1",
    };

    try std.testing.expectEqual(changesMsg(.{ .search_insert = '1' }), keyToMsg(.{ .changes = .{ .search_mode = true } }, keypad_one).?);
    try std.testing.expectEqual(changesMsg(.{ .file_search_insert = '1' }), keyToMsg(.{ .changes = .{ .file_search_mode = true } }, keypad_one).?);
    try expectMsg(.{ .commit_panel_insert = '1' }, keyToMsg(.{ .commit_panel_mode = true }, keypad_one).?);
    try expectMsg(.{ .repo_picker_insert = '1' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .filter }, keypad_one).?);
    try expectMsg(.{ .repo_picker_insert = '1' }, keyToMsg(.{ .repo_picker_mode = true, .repo_picker_input_mode = .path_input }, keypad_one).?);
}

test "keyToMsg maps push confirmation keys" {
    try std.testing.expectEqual(app_message.Msg.confirm_push, keyToMsg(.{ .push_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_push, keyToMsg(.{ .push_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_push, keyToMsg(.{ .push_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .push_confirmation_mode = true }, .{ .codepoint = 'P' }));
}

test "keyToMsg maps pull confirmation keys" {
    try std.testing.expectEqual(app_message.Msg.confirm_pull, keyToMsg(.{ .pull_confirmation_mode = true }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_pull, keyToMsg(.{ .pull_confirmation_mode = true }, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.cancel_pull, keyToMsg(.{ .pull_confirmation_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .pull_confirmation_mode = true }, .{ .codepoint = 'U' }));
}

test "remote cancel Escape takes priority while a background action is active" {
    try std.testing.expectEqual(
        app_message.Msg.cancel_remote_action,
        keyToMsg(.{ .remote_action_cancelable = true }, .{ .codepoint = chasen.Key.escape }).?,
    );
    try std.testing.expectEqual(
        app_message.Msg.quit,
        keyToMsg(.{ .remote_action_cancelable = true }, .{ .codepoint = 'q' }).?,
    );
}

test "keyToMsg maps remote error modal keys and limits interactive retry to push" {
    const context: KeyContext = .{ .remote_error_mode = true };
    try std.testing.expectEqual(app_message.Msg.close_remote_error, keyToMsg(context, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(app_message.Msg.close_remote_error, keyToMsg(context, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(app_message.Msg.close_remote_error, keyToMsg(context, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(context, .{ .codepoint = 'i' }));
    try std.testing.expectEqual(
        app_message.Msg.run_interactive_push,
        keyToMsg(.{ .remote_error_mode = true, .remote_error_interactive = true }, .{ .codepoint = 'i' }).?,
    );
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(context, .{ .codepoint = 'c' }));
    try std.testing.expectEqual(app_message.Msg.copy_popup, keyToMsg(context, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(app_message.Msg.remote_error_scroll_up, keyToMsg(context, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(app_message.Msg.remote_error_scroll_down, keyToMsg(context, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(app_message.Msg.remote_error_scroll_up, keyToMsg(context, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(app_message.Msg.remote_error_scroll_down, keyToMsg(context, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(app_message.Msg.remote_error_page_up, keyToMsg(context, .{ .codepoint = chasen.Key.page_up }).?);
    try std.testing.expectEqual(app_message.Msg.remote_error_page_down, keyToMsg(context, .{ .codepoint = chasen.Key.page_down }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(context, .{ .codepoint = 'P' }));
}

test "keyToMsg keeps printable y as editable popup input" {
    try expectMsg(.{ .commit_panel_insert = 'y' }, keyToMsg(.{ .commit_panel_mode = true }, .{ .codepoint = 'y' }).?);
}

test "keyToMsg opens and closes help outside prompt modes" {
    try std.testing.expectEqual(app_message.Msg.open_help, keyToMsg(.{}, .{ .codepoint = '?' }).?);
    try std.testing.expectEqual(app_message.Msg.open_help, keyToMsg(.{}, .{
        .codepoint = '/',
        .shifted_codepoint = '?',
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqual(app_message.Msg.open_help, keyToMsg(.{}, .{
        .codepoint = '/',
        .text = "?",
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqual(changesMsg(.enter_search), keyToMsg(.{}, .{
        .codepoint = '/',
        .text = "/",
    }).?);
    try std.testing.expectEqual(app_message.Msg.close_help, keyToMsg(.{ .help_mode = true }, .{ .codepoint = '?' }).?);
    try std.testing.expectEqual(app_message.Msg.close_help, keyToMsg(.{ .help_mode = true }, .{
        .codepoint = '/',
        .shifted_codepoint = '?',
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqual(app_message.Msg.close_help, keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'q' }).?);
    try std.testing.expectEqual(app_message.Msg.help_scroll_up, keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'k' }).?);
    try std.testing.expectEqual(app_message.Msg.help_scroll_down, keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(app_message.Msg.help_scroll_up, keyToMsg(.{ .help_mode = true }, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(app_message.Msg.help_scroll_down, keyToMsg(.{ .help_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqual(app_message.Msg.help_page_up, keyToMsg(.{ .help_mode = true }, .{ .codepoint = chasen.Key.page_up }).?);
    try std.testing.expectEqual(app_message.Msg.help_page_down, keyToMsg(.{ .help_mode = true }, .{ .codepoint = chasen.Key.page_down }).?);
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'x' }));
}

test "keyToMsg ignores command modifiers for help overlay printable shortcuts" {
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'q', .mods = .{ .ctrl = true } }));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'k', .mods = .{ .alt = true } }));
    try std.testing.expectEqual(@as(?app_message.Msg, null), keyToMsg(.{ .help_mode = true }, .{ .codepoint = 'j', .mods = .{ .super = true } }));
}

test "keyToMsg keeps prompt modes above help overlay" {
    const msg = keyToMsg(.{ .changes = .{ .search_mode = true }, .help_mode = true }, .{ .codepoint = '?' }).?;
    try std.testing.expectEqual(changesMsg(.{ .search_insert = '?' }), msg);
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

test "branch switch routing honors effective keys and existing input owners" {
    const b: chasen.Key = .{ .codepoint = 'b' };
    for ([_]page.Id{ .changes, .repository, .history, .compare }) |id| {
        try std.testing.expectEqual(app_message.Msg.request_branch_switch, keyToMsg(.{ .active_page = id }, b).?);
        try std.testing.expect(keyToMsg(.{ .active_page = id, .branch_switch_mode = true }, b) == null);
        try std.testing.expect(keyToMsg(.{ .active_page = id, .help_mode = true }, b) == null);
    }
    try std.testing.expectEqual(changesMsg(.{ .search_insert = 'b' }), keyToMsg(.{ .changes = .{ .search_mode = true } }, b).?);
    try std.testing.expectEqual(
        app_message.Msg{ .repository = .{ .source_search_insert = 'b' } },
        keyToMsg(.{ .active_page = .repository, .repository = .{ .source_search_mode = true } }, b).?,
    );
    try std.testing.expectEqual(
        app_message.Msg{ .command_line = .{ .insert = 'b' } },
        keyToMsg(.{ .active_page = .repository, .command_line_active = true }, b).?,
    );
    inline for (.{ .keyboard_line, .mouse, .header }) |owner| {
        try std.testing.expect(keyToMsg(.{ .changes = .{ .selection_owner = owner } }, b) == null);
        try std.testing.expect(keyToMsg(.{ .active_page = .repository, .repository = .{ .selection_owner = owner } }, b) == null);
    }
    try std.testing.expectEqual(app_message.Msg.request_branch_switch, keyToMsg(.{
        .active_page = .repository,
        .repository = .{ .retained_selection_action_available = true },
    }, b).?);
    for ([_]bool{ false, true }) |diff_view| {
        try std.testing.expectEqual(app_message.Msg.request_branch_switch, keyToMsg(.{
            .active_page = .history,
            .history = .{ .diff_view = diff_view },
        }, b).?);
    }
    inline for (.{ .history, .compare }) |id| {
        var context: KeyContext = .{ .active_page = id };
        if (id == .history) context.history.diff_view = true;
        const common = if (id == .history) &context.history.common else &context.compare.common;
        common.search_mode = true;
        const insert: app_message.Msg = if (id == .history)
            .{ .history = .{ .common = .{ .shared = .{ .search_insert = 'b' } } } }
        else
            .{ .compare = .{ .common = .{ .shared = .{ .search_insert = 'b' } } } };
        try std.testing.expectEqual(insert, keyToMsg(context, b).?);
        common.search_mode = false;
        common.file_search_mode = true;
        try std.testing.expect(keyToMsg(context, b).? != .request_branch_switch);
        common.file_search_mode = false;
        inline for (.{ .keyboard_line, .mouse, .header }) |owner| {
            common.selection_owner = owner;
            try std.testing.expect(keyToMsg(context, b) == null);
        }
        common.selection_owner = .none;
        context.active_selection_gesture = true;
        try std.testing.expect(keyToMsg(context, b) == null);
        context.active_selection_gesture = false;
        common.retained_selection_action_available = true;
        try std.testing.expectEqual(app_message.Msg.request_branch_switch, keyToMsg(context, b).?);
        var config: keymap.Config = .{};
        config.set(.branch_switch, .{ .plain_codepoint = 'z' });
        context.keymap = .fromConfig(config);
        common.keymap = context.keymap;
        context.history.keymap = context.keymap;
        try std.testing.expect(keyToMsg(context, b) == null);
        try std.testing.expectEqual(app_message.Msg.request_branch_switch, keyToMsg(context, .{ .codepoint = 'z' }).?);
    }
    try std.testing.expectEqual(app_message.Msg{ .compare = .open_base_picker }, keyToMsg(.{ .active_page = .compare }, .{ .codepoint = 'm' }).?);
    try std.testing.expect(keyToMsg(.{ .active_page = .compare, .compare = .{ .base_picker_open = true } }, b) == null);
    try std.testing.expectEqual(app_message.Msg{ .history = .owned_noop }, keyToMsg(.{ .active_page = .history, .history = .{ .loading = true } }, b).?);
    var custom: keymap.Config = .{};
    custom.set(.branch_switch, .{ .plain_codepoint = ':' });
    const effective = keymap.Effective.fromConfig(custom);
    try std.testing.expectEqual(app_message.Msg.request_branch_switch, keyToMsg(.{
        .active_page = .repository,
        .keymap = effective,
        .repository = .{ .keymap = effective },
        .repository_command_available = true,
    }, .{ .codepoint = ':' }).?);
    for ([_]page.Id{.config}) |id| {
        if (keyToMsg(.{ .active_page = id }, b)) |msg| try std.testing.expect(msg != .request_branch_switch);
    }
}
