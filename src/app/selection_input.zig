//! Page-neutral bounded key grammar for an existing line selection owner.
//!
//! Page adapters retain semantic identities and translate these commands into
//! their own message unions. This module owns no diff, Repository, or page
//! state.

const std = @import("std");
const chasen = @import("chasen");
const keymap = @import("keymap");
const key_input = @import("key_input.zig");

pub const OwnerKind = enum {
    none,
    mouse,
    keyboard_line,
    header,
};

pub const Command = enum {
    move_up,
    move_down,
    copy,
    copy_context,
    clear,
    ask,
    owned_noop,
};

pub const Context = struct {
    owner_kind: OwnerKind = .none,
    retained_action_available: bool = false,
    context_copy_available: bool = false,
    keymap: keymap.Effective = .{},
};

pub fn keyToCommand(context: Context, key: chasen.Key) ?Command {
    if (context.keymap.actionForKey(key)) |action| {
        if (keymap.isDocumentNavigationAction(action)) {
            // Completed-only candidates do not own navigation, even when a
            // custom binding overlaps the retained y/a grammar below.
            return if (context.owner_kind != .none) .owned_noop else null;
        }
    }
    const escape = key.matches(chasen.Key.escape, .{});
    const copy = key.matches('y', .{});
    const copy_context = context.context_copy_available and key_input.matchesShiftedAscii(key, 'y', 'Y');
    const ask = key.matches('a', .{});
    const begin = key_input.matchesShiftedAscii(key, 'v', 'V');
    const up = key.matches('k', .{}) or key.matches(chasen.Key.up, .{});
    const down = key.matches('j', .{}) or key.matches(chasen.Key.down, .{});
    const lateral = key.matches('h', .{}) or key.matches('l', .{});

    return switch (context.owner_kind) {
        .keyboard_line => if (escape)
            .clear
        else if (copy)
            .copy
        else if (copy_context)
            .copy_context
        else if (ask)
            .ask
        else if (up)
            .move_up
        else if (down)
            .move_down
        else if (begin or lateral)
            .owned_noop
        else
            null,
        .mouse, .header => if (escape)
            .clear
        else if (copy or ask or begin or up or down or lateral or (copy_context and context.owner_kind == .mouse))
            .owned_noop
        else
            null,
        .none => if (context.retained_action_available)
            if (escape)
                .clear
            else if (copy)
                .copy
            else if (copy_context)
                .copy_context
            else if (ask)
                .ask
            else
                null
        else
            null,
    };
}

test "selection input maps the complete owner command matrix" {
    const cases = [_]struct {
        context: Context,
        key: chasen.Key,
        expected: ?Command,
    }{
        .{ .context = .{}, .key = .{ .codepoint = 'y' }, .expected = null },
        .{ .context = .{ .retained_action_available = true }, .key = .{ .codepoint = 'y' }, .expected = .copy },
        .{ .context = .{ .retained_action_available = true }, .key = .{ .codepoint = 'a' }, .expected = .ask },
        .{ .context = .{ .retained_action_available = true }, .key = .{ .codepoint = chasen.Key.escape }, .expected = .clear },
        .{ .context = .{ .owner_kind = .keyboard_line }, .key = .{ .codepoint = 'j' }, .expected = .move_down },
        .{ .context = .{ .owner_kind = .keyboard_line }, .key = .{ .codepoint = chasen.Key.up }, .expected = .move_up },
        .{ .context = .{ .owner_kind = .keyboard_line }, .key = .{ .codepoint = 'V' }, .expected = .owned_noop },
        .{ .context = .{ .owner_kind = .keyboard_line }, .key = .{ .codepoint = chasen.Key.left }, .expected = null },
        .{ .context = .{ .owner_kind = .mouse }, .key = .{ .codepoint = 'y' }, .expected = .owned_noop },
        .{ .context = .{ .owner_kind = .mouse }, .key = .{ .codepoint = chasen.Key.escape }, .expected = .clear },
        .{ .context = .{ .owner_kind = .header }, .key = .{ .codepoint = chasen.Key.down }, .expected = .owned_noop },
        .{ .context = .{ .owner_kind = .header }, .key = .{ .codepoint = chasen.Key.right }, .expected = null },
        .{ .context = .{ .context_copy_available = true }, .key = .{ .codepoint = 'Y' }, .expected = null },
        .{ .context = .{ .retained_action_available = true }, .key = .{ .codepoint = 'Y' }, .expected = null },
        .{ .context = .{ .retained_action_available = true, .context_copy_available = true }, .key = .{ .codepoint = 'Y' }, .expected = .copy_context },
        .{ .context = .{ .owner_kind = .keyboard_line, .context_copy_available = true }, .key = .{ .codepoint = 'y', .mods = .{ .shift = true } }, .expected = .copy_context },
        .{ .context = .{ .owner_kind = .keyboard_line, .context_copy_available = true }, .key = .{ .codepoint = 'Y', .mods = .{ .ctrl = true } }, .expected = null },
        .{ .context = .{ .owner_kind = .keyboard_line, .context_copy_available = true }, .key = .{ .codepoint = 'Y', .mods = .{ .alt = true } }, .expected = null },
        .{ .context = .{ .owner_kind = .mouse, .context_copy_available = true }, .key = .{ .codepoint = 'Y' }, .expected = .owned_noop },
        .{ .context = .{ .owner_kind = .header, .context_copy_available = true }, .key = .{ .codepoint = 'Y' }, .expected = null },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, keyToCommand(case.context, case.key));
}

test "selection input ignores modifiers and unrelated keys" {
    const active: Context = .{ .owner_kind = .keyboard_line };
    try std.testing.expect(keyToCommand(active, .{ .codepoint = 'y', .mods = .{ .ctrl = true } }) == null);
    try std.testing.expect(keyToCommand(active, .{ .codepoint = 'x' }) == null);
    try std.testing.expect(keyToCommand(active, .{ .codepoint = ' ' }) == null);
    try std.testing.expect(keyToCommand(.{ .owner_kind = .mouse }, .{ .codepoint = ' ' }) == null);
    try std.testing.expect(keyToCommand(.{ .retained_action_available = true }, .{ .codepoint = 'j' }) == null);
}

test "selection input consumes default and custom document navigation only for live owners" {
    const ctrl_d = chasen.Key{ .codepoint = 'd', .mods = .{ .ctrl = true } };
    for ([_]OwnerKind{ .keyboard_line, .mouse, .header }) |owner| {
        try std.testing.expectEqual(Command.owned_noop, keyToCommand(.{ .owner_kind = owner }, .{ .codepoint = 'g' }).?);
        try std.testing.expectEqual(Command.owned_noop, keyToCommand(.{ .owner_kind = owner }, ctrl_d).?);
    }
    try std.testing.expect(keyToCommand(.{}, .{ .codepoint = 'g' }) == null);
    try std.testing.expect(keyToCommand(.{ .retained_action_available = true }, ctrl_d) == null);

    var config: keymap.Config = .{};
    config.set(.document_first, .{ .plain_codepoint = 'z' });
    const custom = keymap.Effective.fromConfig(config);
    try std.testing.expectEqual(
        Command.owned_noop,
        keyToCommand(.{ .owner_kind = .keyboard_line, .keymap = custom }, .{ .codepoint = 'z' }).?,
    );
    try std.testing.expect(keyToCommand(.{ .owner_kind = .keyboard_line, .keymap = custom }, .{ .codepoint = 'g' }) == null);

    var overlap_config: keymap.Config = .{};
    overlap_config.set(.copy_current_line, .{ .plain_codepoint = 'x' });
    overlap_config.set(.copy_history_detail, .{ .plain_codepoint = 'x' });
    overlap_config.set(.document_first, .{ .plain_codepoint = 'y' });
    try std.testing.expect(keymap.validateConfig(overlap_config));
    const overlap = keymap.Effective.fromConfig(overlap_config);
    try std.testing.expect(keyToCommand(.{
        .retained_action_available = true,
        .keymap = overlap,
    }, .{ .codepoint = 'y' }) == null);
    try std.testing.expectEqual(
        Command.owned_noop,
        keyToCommand(.{ .owner_kind = .mouse, .keymap = overlap }, .{ .codepoint = 'y' }).?,
    );
}
