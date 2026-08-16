//! Page-neutral bounded key grammar for an existing line selection owner.
//!
//! Page adapters retain semantic identities and translate these commands into
//! their own message unions. This module owns no diff, Repository, or page
//! state.

const std = @import("std");
const chasen = @import("chasen");
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
    clear,
    ask,
    owned_noop,
};

pub const Context = struct {
    owner_kind: OwnerKind = .none,
    retained_action_available: bool = false,
};

pub fn keyToCommand(context: Context, key: chasen.Key) ?Command {
    const escape = key.matches(chasen.Key.escape, .{});
    const copy = key.matches('y', .{});
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
        else if (copy or ask or begin or up or down or lateral)
            .owned_noop
        else
            null,
        .none => if (context.retained_action_available)
            if (escape)
                .clear
            else if (copy)
                .copy
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
