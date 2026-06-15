const std = @import("std");
const chasen = @import("chasen");

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
    repo_picker_mode: bool = false,
    search_query_len: usize = 0,
    focus: Focus = .sidebar,
};

pub fn eventToMsg(comptime Msg: type, context: KeyContext, event: chasen.Event) ?Msg {
    return switch (event) {
        .key_press => |key| keyToMsg(Msg, context, key),
        .winsize => |winsize| payloadMsg(Msg, "terminal_resized", chasen.Size{
            .width = winsize.cols,
            .height = winsize.rows,
        }),
        else => null,
    };
}

pub fn keyToMsg(comptime Msg: type, context: KeyContext, key: chasen.Key) ?Msg {
    if (context.search_mode) {
        if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_search");
        if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_search");
        if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "search_backspace");
        if (isTextInputCodepoint(key.codepoint)) return payloadMsg(Msg, "search_insert", key.codepoint);
        return null;
    }

    if (context.file_search_mode) {
        if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_file_search");
        if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_file_search");
        if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "file_search_backspace");
        if (isTextInputCodepoint(key.codepoint)) return payloadMsg(Msg, "file_search_insert", key.codepoint);
        return null;
    }

    if (context.repo_picker_mode) {
        if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_repo_picker");
        if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_repo_picker");
        if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "repo_picker_backspace");
        return switch (key.codepoint) {
            'k', chasen.Key.up => voidMsg(Msg, "repo_picker_move_previous"),
            'j', chasen.Key.down => voidMsg(Msg, "repo_picker_move_next"),
            'q' => voidMsg(Msg, "cancel_repo_picker"),
            else => if (isTextInputCodepoint(key.codepoint)) payloadMsg(Msg, "repo_picker_insert", key.codepoint) else null,
        };
    }

    if (key.matches(chasen.Key.tab, .{})) return voidMsg(Msg, "toggle_focus");
    if (key.matches(chasen.Key.page_up, .{})) return voidMsg(Msg, "page_diff_up");
    if (key.matches(chasen.Key.page_down, .{})) return voidMsg(Msg, "page_diff_down");
    if (key.matches(chasen.Key.home, .{})) return voidMsg(Msg, "select_first_file");
    if (key.matches(chasen.Key.end, .{})) return voidMsg(Msg, "select_last_file");
    if (key.matches(chasen.Key.escape, .{}) and context.search_query_len > 0) return voidMsg(Msg, "clear_search");
    if (context.focus == .sidebar and key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "toggle_directory");
    if (context.focus == .diff and key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "toggle_hunk_fold");
    if (context.focus == .sidebar and key.matches(chasen.Key.right, .{})) return voidMsg(Msg, "expand_directory");
    if (context.focus == .sidebar and key.matches(chasen.Key.left, .{})) return voidMsg(Msg, "collapse_or_parent_directory");

    return switch (key.codepoint) {
        'k', chasen.Key.up => if (context.focus == .diff) voidMsg(Msg, "scroll_diff_up") else voidMsg(Msg, "select_previous_file"),
        'j', chasen.Key.down => if (context.focus == .diff) voidMsg(Msg, "scroll_diff_down") else voidMsg(Msg, "select_next_file"),
        '/' => voidMsg(Msg, "enter_search"),
        'n' => if (context.search_query_len > 0) voidMsg(Msg, "select_next_search_match") else voidMsg(Msg, "select_next_hunk"),
        'N' => if (context.search_query_len > 0) voidMsg(Msg, "select_previous_search_match") else null,
        'p' => if (context.search_query_len > 0) voidMsg(Msg, "select_previous_search_match") else voidMsg(Msg, "select_previous_hunk"),
        'g' => voidMsg(Msg, "select_first_file"),
        'G' => voidMsg(Msg, "select_last_file"),
        'f' => voidMsg(Msg, "enter_file_search"),
        'R' => voidMsg(Msg, "enter_repo_picker"),
        'F' => voidMsg(Msg, "cycle_changed_file_filter"),
        'v' => voidMsg(Msg, "toggle_reviewed_file"),
        'H' => voidMsg(Msg, "toggle_hide_reviewed_files"),
        'e' => voidMsg(Msg, "open_selected_file_in_editor"),
        'u' => voidMsg(Msg, "toggle_display_mode"),
        'q' => voidMsg(Msg, "quit"),
        'r' => voidMsg(Msg, "reload"),
        else => null,
    };
}

pub fn isTextInputCodepoint(codepoint: u21) bool {
    return codepoint >= 0x20 and codepoint != 0x7f and !(codepoint >= 0x80 and codepoint <= 0x9f);
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
    search_insert: u21,
    cancel_file_search,
    submit_file_search,
    file_search_backspace,
    file_search_insert: u21,
    cancel_repo_picker,
    submit_repo_picker,
    repo_picker_backspace,
    repo_picker_move_previous,
    repo_picker_move_next,
    repo_picker_insert: u21,
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
    cycle_changed_file_filter,
    toggle_reviewed_file,
    toggle_hide_reviewed_files,
    open_selected_file_in_editor,
    toggle_display_mode,
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

test "keyToMsg routes text while search is active" {
    const msg = keyToMsg(TestMsg, .{ .search_mode = true }, .{ .codepoint = 'x' }).?;
    try std.testing.expectEqual(TestMsg{ .search_insert = 'x' }, msg);
}

test "keyToMsg maps enter by focused pane" {
    try std.testing.expectEqual(TestMsg.toggle_directory, keyToMsg(TestMsg, .{ .focus = .sidebar }, .{ .codepoint = chasen.Key.enter }).?);
    try std.testing.expectEqual(TestMsg.toggle_hunk_fold, keyToMsg(TestMsg, .{ .focus = .diff }, .{ .codepoint = chasen.Key.enter }).?);
}

test "keyToMsg uses search query to disambiguate navigation" {
    try std.testing.expectEqual(TestMsg.select_next_hunk, keyToMsg(TestMsg, .{}, .{ .codepoint = 'n' }).?);
    try std.testing.expectEqual(TestMsg.select_next_search_match, keyToMsg(TestMsg, .{ .search_query_len = 4 }, .{ .codepoint = 'n' }).?);
}
