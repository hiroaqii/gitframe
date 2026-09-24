//! Repository-local keyboard and paste mapping.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("../../key_input.zig");
const selection_action = @import("../../selection_action.zig");
const selection_input = @import("../../selection_input.zig");
const model = @import("model.zig");

pub const Context = struct {
    focus: model.Focus = .tree,
    source_available: bool = false,
    tree_hidden: bool = false,
    source_search_mode: bool = false,
    file_search_mode: bool = false,
    selection_owner: selection_input.OwnerKind = .none,
    retained_selection_action_available: bool = false,
    source_query_len: usize = 0,
    keymap: keymap.Effective = .{},
};

pub fn pasteToMsg(comptime Msg: type, context: Context, text: []const u8) ?Msg {
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return null;
    if (context.source_search_mode) return payload(Msg, "source_search_paste", text);
    if (context.file_search_mode) return payload(Msg, "file_search_paste", text);
    return null;
}

pub fn keyToMsg(comptime Msg: type, context: Context, key: chasen.Key) ?Msg {
    if (context.source_search_mode) return sourceSearchKey(Msg, key);
    if (context.file_search_mode) return fileSearchKey(Msg, key);

    if (selectionKeyToMsg(Msg, context, key)) |msg| return msg;

    // A configured action claims its normal-mode key even when Repository does
    // not own that action or its current precondition is unavailable. Falling
    // through after a null mapping would reinterpret the same key as a local
    // command; resolving local controls first would also make valid bindings
    // such as `changed_file_filter = space` impossible to use here.
    if (context.keymap.actionForKey(key)) |action| {
        return publicActionToMsg(Msg, context, action);
    }

    if (key_input.matchesShiftedAscii(key, 'v', 'V')) return voidMsg(Msg, "begin_keyboard_line_selection");

    if (key.matches(chasen.Key.tab, .{}) and context.source_available and !context.tree_hidden) return voidMsg(Msg, "toggle_focus");
    if (key.matches(chasen.Key.escape, .{}) and context.source_query_len > 0) return voidMsg(Msg, "clear_source_search");
    if (!context.tree_hidden and context.focus == .tree and (key.matches(chasen.Key.enter, .{}) or key.matches(' ', .{}))) return voidMsg(Msg, "toggle_directory");
    if (key.matches(chasen.Key.home, .{})) {
        return if (context.focus == .source) voidMsg(Msg, "source_first") else voidMsg(Msg, "tree_first");
    }
    if (key.matches(chasen.Key.end, .{})) {
        return if (context.focus == .source) voidMsg(Msg, "source_last") else voidMsg(Msg, "tree_last");
    }

    if (key_input.matchesShiftedAscii(key, 'n', 'N')) {
        return if (context.source_query_len > 0) voidMsg(Msg, "previous_source_match") else null;
    }

    if (key_input.hasCommandModifier(key)) return null;

    return switch (key.codepoint) {
        'k', chasen.Key.up => voidMsg(Msg, "move_up"),
        'j', chasen.Key.down => voidMsg(Msg, "move_down"),
        'h', chasen.Key.left => voidMsg(Msg, "scroll_left"),
        'l', chasen.Key.right => voidMsg(Msg, "scroll_right"),
        'n' => if (context.source_query_len > 0) voidMsg(Msg, "next_source_match") else null,
        'p' => if (context.source_query_len > 0) voidMsg(Msg, "previous_source_match") else null,
        else => null,
    };
}

/// Bounded owner grammar used by root preflight after modal owners and before
/// configured root actions. Repository identity remains in the page adapter.
pub fn selectionKeyToMsg(comptime Msg: type, context: Context, key: chasen.Key) ?Msg {
    if (context.selection_owner != .none and
        (key.matches('n', .{}) or
            key_input.matchesShiftedAscii(key, 'n', 'N') or
            key.matches('p', .{})))
    {
        return voidMsg(Msg, "selection_owned_noop");
    }

    const command = selection_input.keyToCommand(.{
        .owner_kind = context.selection_owner,
        .retained_action_available = context.retained_selection_action_available,
        .context_copy_available = true,
        .keymap = context.keymap,
    }, key) orelse return null;
    return switch (command) {
        .move_up => payload(Msg, "keyboard_line_selection_move", @import("../../direction.zig").Vertical.up),
        .move_down => payload(Msg, "keyboard_line_selection_move", @import("../../direction.zig").Vertical.down),
        .copy => payload(Msg, "selection_action", selection_action.Action.copy),
        .copy_context => payload(Msg, "selection_action", selection_action.Action.copy_context),
        .clear => payload(Msg, "selection_action", selection_action.Action.clear),
        .ask => voidMsg(Msg, "selection_action_unavailable"),
        .owned_noop => voidMsg(Msg, "selection_owned_noop"),
    };
}

fn publicActionToMsg(comptime Msg: type, context: Context, action: keymap.PublicAction) ?Msg {
    if (keymap.isDocumentNavigationAction(action)) return documentNavigationActionToMsg(Msg, context, action);
    return switch (action) {
        .search => if (context.source_available) voidMsg(Msg, "enter_source_search") else null,
        .file_search => voidMsg(Msg, "enter_file_search"),
        .changed_file_filter => voidMsg(Msg, "toggle_changed_filter"),
        .toggle_line_numbers => voidMsg(Msg, "toggle_line_numbers"),
        .page_up => voidMsg(Msg, "page_up"),
        .page_down => voidMsg(Msg, "page_down"),
        .toggle_sidebar => voidMsg(Msg, "toggle_tree_visibility"),
        .decrease_sidebar_width => voidMsg(Msg, "decrease_tree_width"),
        .increase_sidebar_width => voidMsg(Msg, "increase_tree_width"),
        else => null,
    };
}

fn documentNavigationActionToMsg(comptime Msg: type, context: Context, action: keymap.PublicAction) ?Msg {
    if (context.focus != .source or !context.source_available) return null;
    return switch (action) {
        .document_first => voidMsg(Msg, "source_first"),
        .document_last => voidMsg(Msg, "source_last"),
        .half_page_up => voidMsg(Msg, "half_page_up"),
        .half_page_down => voidMsg(Msg, "half_page_down"),
        .page_backward => voidMsg(Msg, "page_up"),
        .page_forward => voidMsg(Msg, "page_down"),
        else => unreachable,
    };
}

fn sourceSearchKey(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_source_search");
    if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_source_search");
    if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "source_search_backspace");
    if (key.matches(chasen.Key.left, .{})) return voidMsg(Msg, "source_search_move_left");
    if (key.matches(chasen.Key.right, .{})) return voidMsg(Msg, "source_search_move_right");
    if (key_input.textInputCodepoint(key)) |codepoint| return payload(Msg, "source_search_insert", codepoint);
    return null;
}

fn fileSearchKey(comptime Msg: type, key: chasen.Key) ?Msg {
    if (key.matches(chasen.Key.escape, .{})) return voidMsg(Msg, "cancel_file_search");
    if (key.matches(chasen.Key.enter, .{})) return voidMsg(Msg, "submit_file_search");
    if (key.matches(chasen.Key.backspace, .{})) return voidMsg(Msg, "file_search_backspace");
    if (key.matches(chasen.Key.up, .{})) return voidMsg(Msg, "file_search_previous");
    if (key.matches(chasen.Key.down, .{})) return voidMsg(Msg, "file_search_next");
    if (key_input.textInputCodepoint(key)) |codepoint| return payload(Msg, "file_search_insert", codepoint);
    return null;
}

fn voidMsg(comptime Msg: type, comptime field: []const u8) Msg {
    return @unionInit(Msg, field, {});
}

fn payload(comptime Msg: type, comptime field: []const u8, value: anytype) Msg {
    return @unionInit(Msg, field, value);
}

const TestMsg = union(enum) {
    selection_action: selection_action.Action,
    selection_owned_noop,
    selection_action_unavailable,
    begin_keyboard_line_selection,
    keyboard_line_selection_move: @import("../../direction.zig").Vertical,
    toggle_focus,
    toggle_directory,
    move_up,
    move_down,
    scroll_left,
    scroll_right,
    page_up,
    page_down,
    half_page_up,
    half_page_down,
    source_first,
    source_last,
    tree_first,
    tree_last,
    toggle_tree_visibility,
    decrease_tree_width,
    increase_tree_width,
    enter_source_search,
    enter_file_search,
    toggle_changed_filter,
    toggle_line_numbers,
    clear_source_search,
    next_source_match,
    previous_source_match,
    cancel_source_search,
    submit_source_search,
    source_search_backspace,
    source_search_move_left,
    source_search_move_right,
    source_search_insert: u21,
    source_search_paste: []const u8,
    cancel_file_search,
    submit_file_search,
    file_search_backspace,
    file_search_previous,
    file_search_next,
    file_search_insert: u21,
    file_search_paste: []const u8,
};

test "repository input routes focus search and file search independently" {
    try std.testing.expectEqual(TestMsg.toggle_focus, keyToMsg(TestMsg, .{ .source_available = true }, .{ .codepoint = chasen.Key.tab }).?);
    try std.testing.expectEqual(TestMsg.source_first, keyToMsg(TestMsg, .{ .focus = .source }, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(TestMsg.tree_first, keyToMsg(TestMsg, .{}, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(TestMsg.enter_source_search, keyToMsg(TestMsg, .{ .source_available = true }, .{ .codepoint = '/' }).?);
    try std.testing.expectEqual(TestMsg.toggle_changed_filter, keyToMsg(TestMsg, .{}, .{ .codepoint = 'F' }).?);
    try std.testing.expectEqual(TestMsg{ .source_search_insert = 'F' }, keyToMsg(TestMsg, .{ .source_search_mode = true }, .{ .codepoint = 'F' }).?);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = 'F' }, keyToMsg(TestMsg, .{ .file_search_mode = true }, .{ .codepoint = 'F' }).?);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = 'B' }, keyToMsg(TestMsg, .{ .file_search_mode = true }, .{ .codepoint = 'B' }).?);
    try std.testing.expectEqual(TestMsg.file_search_next, keyToMsg(TestMsg, .{ .file_search_mode = true }, .{ .codepoint = chasen.Key.down }).?);
    try std.testing.expectEqualStrings("needle", pasteToMsg(TestMsg, .{ .source_search_mode = true }, "needle").?.source_search_paste);
}

test "repository retained actions follow modal owners and precede navigation" {
    const retained: Context = .{ .retained_selection_action_available = true };
    try std.testing.expectEqual(
        TestMsg{ .selection_action = .copy },
        keyToMsg(TestMsg, retained, .{ .codepoint = 'y' }).?,
    );
    try std.testing.expectEqual(
        TestMsg{ .selection_action = .clear },
        keyToMsg(TestMsg, retained, .{ .codepoint = chasen.Key.escape }).?,
    );
    try std.testing.expect(keyToMsg(TestMsg, retained, .{ .codepoint = 'y', .mods = .{ .ctrl = true } }) == null);

    const source_modal: Context = .{
        .source_search_mode = true,
        .retained_selection_action_available = true,
    };
    try std.testing.expectEqual(
        TestMsg{ .source_search_insert = 'y' },
        keyToMsg(TestMsg, source_modal, .{ .codepoint = 'y' }).?,
    );
    try std.testing.expectEqual(
        TestMsg.cancel_source_search,
        keyToMsg(TestMsg, source_modal, .{ .codepoint = chasen.Key.escape }).?,
    );

    const file_modal: Context = .{
        .file_search_mode = true,
        .retained_selection_action_available = true,
    };
    try std.testing.expectEqual(
        TestMsg{ .file_search_insert = 'y' },
        keyToMsg(TestMsg, file_modal, .{ .codepoint = 'y' }).?,
    );
    try std.testing.expectEqual(
        TestMsg.cancel_file_search,
        keyToMsg(TestMsg, file_modal, .{ .codepoint = chasen.Key.escape }).?,
    );
}

test "repository keyboard line selection owns bounded keys and preserves horizontal navigation" {
    const active: Context = .{
        .focus = .source,
        .source_available = true,
        .selection_owner = .keyboard_line,
        .retained_selection_action_available = true,
    };
    try std.testing.expectEqual(TestMsg{ .keyboard_line_selection_move = .down }, keyToMsg(TestMsg, active, .{ .codepoint = 'j' }).?);
    try std.testing.expectEqual(TestMsg{ .keyboard_line_selection_move = .up }, keyToMsg(TestMsg, active, .{ .codepoint = chasen.Key.up }).?);
    try std.testing.expectEqual(TestMsg{ .selection_action = .copy }, keyToMsg(TestMsg, active, .{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(TestMsg{ .selection_action = .clear }, keyToMsg(TestMsg, active, .{ .codepoint = chasen.Key.escape }).?);
    try std.testing.expectEqual(TestMsg.selection_action_unavailable, keyToMsg(TestMsg, active, .{ .codepoint = 'a' }).?);
    try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, active, .{ .codepoint = 'V' }).?);
    try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, active, .{ .codepoint = 'h' }).?);
    try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, active, .{ .codepoint = 'g' }).?);
    try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, active, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }).?);
    try std.testing.expectEqual(TestMsg.scroll_left, keyToMsg(TestMsg, active, .{ .codepoint = chasen.Key.left }).?);
}

test "repository document navigation is source scoped and configurable" {
    const source: Context = .{ .focus = .source, .source_available = true };
    const cases = [_]struct { key: chasen.Key, expected: TestMsg }{
        .{ .key = .{ .codepoint = 'g' }, .expected = .source_first },
        .{ .key = .{ .codepoint = 'G' }, .expected = .source_last },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .expected = .half_page_up },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .expected = .half_page_down },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } }, .expected = .page_up },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .ctrl = true } }, .expected = .page_down },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.expected, keyToMsg(TestMsg, source, case.key).?);
        try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .tree, .source_available = true }, case.key) == null);
        try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .source }, case.key) == null);
    }
    try std.testing.expectEqual(
        keyToMsg(TestMsg, source, .{ .codepoint = chasen.Key.page_up }).?,
        keyToMsg(TestMsg, source, .{ .codepoint = 'b', .mods = .{ .ctrl = true } }).?,
    );
    try std.testing.expectEqual(
        keyToMsg(TestMsg, source, .{ .codepoint = chasen.Key.page_down }).?,
        keyToMsg(TestMsg, source, .{ .codepoint = 'f', .mods = .{ .ctrl = true } }).?,
    );
    try std.testing.expectEqual(TestMsg.source_first, keyToMsg(TestMsg, source, .{ .codepoint = chasen.Key.home }).?);
    try std.testing.expectEqual(TestMsg.tree_first, keyToMsg(TestMsg, .{}, .{ .codepoint = chasen.Key.home }).?);

    var config: keymap.Config = .{};
    config.set(.half_page_down, .{ .plain_codepoint = 'z' });
    const custom = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(TestMsg.half_page_down, keyToMsg(TestMsg, .{ .focus = .source, .source_available = true, .keymap = custom }, .{ .codepoint = 'z' }).?);
    try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, .{ .focus = .source, .source_available = true, .selection_owner = .mouse, .keymap = custom }, .{ .codepoint = 'z' }).?);
}

test "repository source match keys are owned only by live selections" {
    const keys = [_]chasen.Key{
        .{ .codepoint = 'n' },
        .{ .codepoint = 'N' },
        .{ .codepoint = 'p' },
    };
    for ([_]selection_input.OwnerKind{ .keyboard_line, .mouse, .header }) |owner| {
        for (keys) |key| {
            try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, .{ .selection_owner = owner, .source_query_len = 1 }, key).?);
            try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, .{ .selection_owner = owner }, key).?);
        }
    }

    const expected = [_]TestMsg{ .next_source_match, .previous_source_match, .previous_source_match };
    for (keys, expected) |key, message| {
        try std.testing.expectEqual(message, keyToMsg(TestMsg, .{ .source_query_len = 1 }, key).?);
        try std.testing.expect(keyToMsg(TestMsg, .{}, key) == null);
        try std.testing.expectEqual(message, keyToMsg(TestMsg, .{ .retained_selection_action_available = true, .source_query_len = 1 }, key).?);
    }

    try std.testing.expectEqual(TestMsg{ .source_search_insert = 'N' }, keyToMsg(TestMsg, .{ .source_search_mode = true, .selection_owner = .mouse }, .{ .codepoint = 'N' }).?);
}

test "repository mouse owners consume selection grammar and configured V wins before begin" {
    for ([_]selection_input.OwnerKind{ .mouse, .header }) |owner| {
        const context: Context = .{ .selection_owner = owner };
        try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, context, .{ .codepoint = 'y' }).?);
        try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, context, .{ .codepoint = 'j' }).?);
        try std.testing.expectEqual(TestMsg.selection_owned_noop, keyToMsg(TestMsg, context, .{ .codepoint = 'V' }).?);
        try std.testing.expectEqual(TestMsg{ .selection_action = .clear }, keyToMsg(TestMsg, context, .{ .codepoint = chasen.Key.escape }).?);
    }

    const v = chasen.Key{ .codepoint = 'V' };
    try std.testing.expectEqual(TestMsg.begin_keyboard_line_selection, keyToMsg(TestMsg, .{}, v).?);
    var config: keymap.Config = .{};
    config.set(.toggle_line_numbers, .{ .plain_codepoint = 'V' });
    try std.testing.expectEqual(
        TestMsg.toggle_line_numbers,
        keyToMsg(TestMsg, .{ .keymap = keymap.Effective.fromConfig(config) }, v).?,
    );
}

test "repository input uses configured changed-file filter binding" {
    var config: keymap.Config = .{};
    config.set(.changed_file_filter, .{ .plain_codepoint = 'z' });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(TestMsg.toggle_changed_filter, keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'z' }).?);
    try std.testing.expect(keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'F' }) == null);
}

test "repository input routes configured tree width actions" {
    try std.testing.expectEqual(TestMsg.decrease_tree_width, keyToMsg(TestMsg, .{}, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(TestMsg.increase_tree_width, keyToMsg(TestMsg, .{}, .{ .codepoint = ']' }).?);

    var config: keymap.Config = .{};
    config.set(.increase_sidebar_width, .{ .plain_codepoint = 'z' });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(TestMsg.increase_tree_width, keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'z' }).?);
    try std.testing.expect(keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = ']' }) == null);
}

test "repository input routes configured tree visibility and suppresses hidden focus toggles" {
    try std.testing.expectEqual(TestMsg.toggle_tree_visibility, keyToMsg(TestMsg, .{}, .{ .codepoint = 'B' }).?);
    try std.testing.expectEqual(TestMsg.enter_file_search, keyToMsg(TestMsg, .{ .tree_hidden = true }, .{ .codepoint = 'f' }).?);
    try std.testing.expect(keyToMsg(TestMsg, .{ .source_available = true, .tree_hidden = true }, .{ .codepoint = chasen.Key.tab }) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .tree, .tree_hidden = true }, .{ .codepoint = chasen.Key.enter }) == null);

    var config: keymap.Config = .{};
    config.set(.toggle_sidebar, .{ .plain_codepoint = 'z' });
    const effective = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(TestMsg.toggle_tree_visibility, keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'z' }).?);
    try std.testing.expect(keyToMsg(TestMsg, .{ .keymap = effective }, .{ .codepoint = 'B' }) == null);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = '[' }, keyToMsg(TestMsg, .{ .file_search_mode = true, .keymap = effective }, .{ .codepoint = '[' }).?);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = ']' }, keyToMsg(TestMsg, .{ .file_search_mode = true, .keymap = effective }, .{ .codepoint = ']' }).?);
}

test "repository configured Space action claims normal input but not prompts" {
    var config: keymap.Config = .{};
    config.set(.changed_file_filter, .{ .named = .space });
    try std.testing.expect(keymap.validateConfig(config));
    const effective = keymap.Effective.fromConfig(config);
    const space = chasen.Key{ .codepoint = ' ' };

    try std.testing.expectEqual(TestMsg.toggle_changed_filter, keyToMsg(TestMsg, .{ .focus = .tree, .keymap = effective }, space).?);
    try std.testing.expectEqual(TestMsg.toggle_directory, keyToMsg(TestMsg, .{ .focus = .tree }, space).?);
    try std.testing.expectEqual(TestMsg{ .source_search_insert = ' ' }, keyToMsg(TestMsg, .{ .source_search_mode = true, .keymap = effective }, space).?);
    try std.testing.expectEqual(TestMsg{ .file_search_insert = ' ' }, keyToMsg(TestMsg, .{ .file_search_mode = true, .keymap = effective }, space).?);

    var search_config: keymap.Config = .{};
    search_config.set(.search, .{ .named = .space });
    try std.testing.expect(keymap.validateConfig(search_config));
    const search_keymap = keymap.Effective.fromConfig(search_config);
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .tree, .keymap = search_keymap }, space) == null);
    try std.testing.expectEqual(TestMsg.enter_source_search, keyToMsg(TestMsg, .{ .focus = .tree, .source_available = true, .keymap = search_keymap }, space).?);

    var non_repository_config: keymap.Config = .{};
    non_repository_config.set(.push, .{ .named = .space });
    try std.testing.expect(keymap.validateConfig(non_repository_config));
    try std.testing.expect(keyToMsg(TestMsg, .{ .focus = .tree, .keymap = keymap.Effective.fromConfig(non_repository_config) }, space) == null);
    try std.testing.expect(keyToMsg(TestMsg, .{ .source_query_len = 1 }, .{ .codepoint = 'p', .mods = .{ .shift = true } }) == null);
}
