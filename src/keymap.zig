const std = @import("std");
const chasen = @import("chasen");

pub const PublicAction = enum {
    help,
    reload,
    search,
    file_search,
    repo_picker,
    open_editor,
    commit,
    amend,
    push,
    pull,
    fetch,
    branch_switch,
    discard,
    toggle_display_mode,
    toggle_line_numbers,
    toggle_sidebar,
    decrease_sidebar_width,
    increase_sidebar_width,
    changed_file_filter,
    mark_reviewed,
    hide_reviewed,
    first_file,
    last_file,
    page_up,
    page_down,
    copy_current_line,
    copy_current_hunk,
};

pub const action_count = @typeInfo(PublicAction).@"enum".fields.len;

pub const NamedKey = enum {
    enter,
    tab,
    esc,
    page_up,
    page_down,
    home,
    end,
    up,
    down,
    left,
    right,
    space,
};

pub const CtrlKey = enum {
    enter,
    q,
    s,
};

pub const KeySpec = union(enum) {
    plain_codepoint: u21,
    exact: u21,
    shifted_ascii: struct {
        lower: u21,
        upper: u21,
    },
    named: NamedKey,
    ctrl: CtrlKey,

    pub fn matches(self: KeySpec, key: chasen.Key) bool {
        return switch (self) {
            .plain_codepoint => |codepoint| matchesPlainCodepoint(key, codepoint),
            .exact => |codepoint| key.matches(codepoint, .{}),
            .shifted_ascii => |ascii| matchesShiftedAscii(key, ascii.lower, ascii.upper),
            .named => |named| key.matches(namedCodepoint(named), .{}),
            .ctrl => |ctrl| key.matches(ctrlCodepoint(ctrl), .{ .ctrl = true }),
        };
    }

    pub fn eql(self: KeySpec, other: KeySpec) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .plain_codepoint => |value| value == other.plain_codepoint,
            .exact => |value| value == other.exact,
            .shifted_ascii => |value| value.lower == other.shifted_ascii.lower and value.upper == other.shifted_ascii.upper,
            .named => |value| value == other.named,
            .ctrl => |value| value == other.ctrl,
        };
    }
};

pub const Config = struct {
    overrides: [action_count]?KeySpec = [_]?KeySpec{null} ** action_count,

    pub fn set(self: *Config, action: PublicAction, spec: KeySpec) void {
        self.overrides[@intFromEnum(action)] = spec;
    }

    pub fn get(self: Config, action: PublicAction) ?KeySpec {
        return self.overrides[@intFromEnum(action)];
    }
};

pub const Effective = struct {
    // `null` means a public action is intentionally available for config but
    // does not claim a default key. Fetch uses this to avoid stealing another
    // global key while still allowing users to opt in.
    bindings: [action_count]?KeySpec = default_specs,

    pub fn fromConfig(config: Config) Effective {
        var result: Effective = .{};
        inline for (@typeInfo(PublicAction).@"enum".fields) |field| {
            const action: PublicAction = @enumFromInt(field.value);
            if (config.get(action)) |override_spec| result.bindings[@intFromEnum(action)] = override_spec;
        }
        return result;
    }

    pub fn spec(self: Effective, action: PublicAction) ?KeySpec {
        return self.bindings[@intFromEnum(action)];
    }

    pub fn isBound(self: Effective, action: PublicAction) bool {
        return self.spec(action) != null;
    }

    pub fn actionForKey(self: Effective, key: chasen.Key) ?PublicAction {
        inline for (@typeInfo(PublicAction).@"enum".fields) |field| {
            const action: PublicAction = @enumFromInt(field.value);
            if (self.spec(action)) |binding| {
                if (binding.matches(key)) return action;
            }
        }
        return null;
    }

    pub fn display(self: Effective, action: PublicAction, buffer: []u8) ?[]const u8 {
        const binding = self.spec(action) orelse return null;
        return formatKeySpec(buffer, binding);
    }
};

pub fn actionFromKey(key: []const u8) ?PublicAction {
    inline for (@typeInfo(PublicAction).@"enum".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseKeySpec(value: []const u8) ?KeySpec {
    if (std.mem.startsWith(u8, value, "ctrl+")) {
        const name = value["ctrl+".len..];
        if (std.mem.eql(u8, name, "enter")) return .{ .ctrl = .enter };
        if (std.mem.eql(u8, name, "q")) return .{ .ctrl = .q };
        if (std.mem.eql(u8, name, "s")) return .{ .ctrl = .s };
        return null;
    }

    if (namedFromText(value)) |named| return .{ .named = named };

    var iter = std.unicode.Utf8Iterator{ .bytes = value, .i = 0 };
    const codepoint = iter.nextCodepoint() orelse return null;
    if (iter.nextCodepoint() != null) return null;
    if (codepoint == ' ') return .{ .named = .space };
    if (codepoint >= 'A' and codepoint <= 'Z') {
        return .{ .shifted_ascii = .{
            .lower = codepoint + ('a' - 'A'),
            .upper = codepoint,
        } };
    }
    if (codepoint == '?') return .{ .exact = '?' };
    if (!isPrintableCodepoint(codepoint)) return null;
    return .{ .plain_codepoint = codepoint };
}

pub fn validateConfig(config: Config) bool {
    const effective = Effective.fromConfig(config);

    inline for (@typeInfo(PublicAction).@"enum".fields, 0..) |left_field, left_index| {
        const left_action: PublicAction = @enumFromInt(left_field.value);
        if (effective.spec(left_action)) |left_spec| {
            if (isReserved(left_spec)) return false;

            inline for (@typeInfo(PublicAction).@"enum".fields[(left_index + 1)..]) |right_field| {
                const right_action: PublicAction = @enumFromInt(right_field.value);
                if (effective.spec(right_action)) |right_spec| {
                    if (left_spec.eql(right_spec)) return false;
                }
            }
        }
    }

    return true;
}

pub fn formatKeySpec(buffer: []u8, spec: KeySpec) []const u8 {
    return switch (spec) {
        .plain_codepoint => |codepoint| writeCodepoint(buffer, codepoint),
        .exact => |codepoint| writeCodepoint(buffer, codepoint),
        .shifted_ascii => |ascii| writeCodepoint(buffer, ascii.upper),
        .named => |named| namedDisplay(named),
        .ctrl => |ctrl| ctrlDisplay(ctrl),
    };
}

const default_specs = buildDefaultSpecs();

fn buildDefaultSpecs() [action_count]?KeySpec {
    var specs: [action_count]?KeySpec = undefined;
    inline for (@typeInfo(PublicAction).@"enum".fields) |field| {
        const action: PublicAction = @enumFromInt(field.value);
        specs[@intFromEnum(action)] = defaultSpec(action);
    }
    return specs;
}

fn defaultSpec(action: PublicAction) ?KeySpec {
    return switch (action) {
        .help => .{ .exact = '?' },
        .reload => .{ .plain_codepoint = 'r' },
        .search => .{ .plain_codepoint = '/' },
        .file_search => .{ .plain_codepoint = 'f' },
        .repo_picker => shiftedAscii('r', 'R'),
        .open_editor => .{ .plain_codepoint = 'e' },
        .commit => .{ .plain_codepoint = 'c' },
        .amend => shiftedAscii('a', 'A'),
        .push => shiftedAscii('p', 'P'),
        .pull => shiftedAscii('u', 'U'),
        .fetch => null,
        .branch_switch => .{ .plain_codepoint = 'b' },
        .discard => shiftedAscii('d', 'D'),
        .toggle_display_mode => .{ .plain_codepoint = 'u' },
        .toggle_line_numbers => shiftedAscii('l', 'L'),
        .toggle_sidebar => shiftedAscii('b', 'B'),
        .decrease_sidebar_width => .{ .plain_codepoint = '[' },
        .increase_sidebar_width => .{ .plain_codepoint = ']' },
        .changed_file_filter => shiftedAscii('f', 'F'),
        .mark_reviewed => .{ .plain_codepoint = 'v' },
        .hide_reviewed => shiftedAscii('h', 'H'),
        .first_file => .{ .plain_codepoint = 'g' },
        .last_file => shiftedAscii('g', 'G'),
        .page_up => .{ .named = .page_up },
        .page_down => .{ .named = .page_down },
        .copy_current_line => .{ .plain_codepoint = 'y' },
        .copy_current_hunk => shiftedAscii('y', 'Y'),
    };
}

fn shiftedAscii(lower: u21, upper: u21) KeySpec {
    return .{ .shifted_ascii = .{ .lower = lower, .upper = upper } };
}

fn isReserved(spec: KeySpec) bool {
    const reserved = [_]KeySpec{
        .{ .named = .tab },
        .{ .named = .esc },
        .{ .named = .enter },
        .{ .named = .up },
        .{ .named = .down },
        .{ .named = .left },
        .{ .named = .right },
        .{ .named = .home },
        .{ .named = .end },
        .{ .plain_codepoint = 'h' },
        .{ .plain_codepoint = 'j' },
        .{ .plain_codepoint = 'k' },
        .{ .plain_codepoint = 'l' },
        .{ .plain_codepoint = 'n' },
        .{ .plain_codepoint = 'p' },
        .{ .plain_codepoint = 'q' },
        .{ .plain_codepoint = 's' },
        .{ .plain_codepoint = 'a' },
        shiftedAscii('j', 'J'),
        shiftedAscii('k', 'K'),
        shiftedAscii('n', 'N'),
    };
    for (reserved) |reserved_spec| {
        if (spec.eql(reserved_spec)) return true;
    }
    return false;
}

fn namedFromText(value: []const u8) ?NamedKey {
    inline for (@typeInfo(NamedKey).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    if (std.mem.eql(u8, value, "escape")) return .esc;
    if (std.mem.eql(u8, value, "pgup")) return .page_up;
    if (std.mem.eql(u8, value, "pgdn")) return .page_down;
    return null;
}

fn namedCodepoint(named: NamedKey) u21 {
    return switch (named) {
        .enter => chasen.Key.enter,
        .tab => chasen.Key.tab,
        .esc => chasen.Key.escape,
        .page_up => chasen.Key.page_up,
        .page_down => chasen.Key.page_down,
        .home => chasen.Key.home,
        .end => chasen.Key.end,
        .up => chasen.Key.up,
        .down => chasen.Key.down,
        .left => chasen.Key.left,
        .right => chasen.Key.right,
        .space => ' ',
    };
}

fn namedDisplay(named: NamedKey) []const u8 {
    return switch (named) {
        .enter => "Enter",
        .tab => "Tab",
        .esc => "Esc",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .home => "Home",
        .end => "End",
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .space => "Space",
    };
}

fn ctrlCodepoint(ctrl: CtrlKey) u21 {
    return switch (ctrl) {
        .enter => chasen.Key.enter,
        .q => 'q',
        .s => 's',
    };
}

fn ctrlDisplay(ctrl: CtrlKey) []const u8 {
    return switch (ctrl) {
        .enter => "Ctrl+Enter",
        .q => "Ctrl+q",
        .s => "Ctrl+s",
    };
}

fn writeCodepoint(buffer: []u8, codepoint: u21) []const u8 {
    if (buffer.len < 4) return "";
    const len = std.unicode.utf8Encode(codepoint, buffer[0..4]) catch return "";
    return buffer[0..len];
}

fn matchesPlainCodepoint(key: chasen.Key, codepoint: u21) bool {
    if (hasCommandModifier(key)) return false;
    if (keyTextCodepoint(key)) |text_codepoint| return text_codepoint == codepoint;
    if (key.mods.shift) return false;
    return key.codepoint == codepoint;
}

fn matchesShiftedAscii(key: chasen.Key, lower: u21, upper: u21) bool {
    if (hasCommandModifier(key)) return false;
    return key.matches(upper, .{}) or (key.codepoint == lower and key.mods.shift);
}

fn hasCommandModifier(key: chasen.Key) bool {
    return key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta;
}

fn keyTextCodepoint(key: chasen.Key) ?u21 {
    const text = key.text orelse return null;
    if (text.len == 0) return null;

    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len != text.len) return null;

    return std.unicode.utf8Decode(text) catch null;
}

fn isPrintableCodepoint(codepoint: u21) bool {
    return codepoint >= 0x20 and codepoint != 0x7f and !(codepoint >= 0x80 and codepoint <= 0x9f);
}

test "parseKeySpec handles printable shifted named and ctrl forms" {
    try std.testing.expect(parseKeySpec("x").?.eql(.{ .plain_codepoint = 'x' }));
    try std.testing.expect(parseKeySpec("R").?.eql(shiftedAscii('r', 'R')));
    try std.testing.expect(parseKeySpec("?").?.eql(.{ .exact = '?' }));
    try std.testing.expect(parseKeySpec("page_up").?.eql(.{ .named = .page_up }));
    try std.testing.expect(parseKeySpec("space").?.eql(.{ .named = .space }));
    try std.testing.expect(parseKeySpec(" ").?.eql(.{ .named = .space }));
    try std.testing.expect(parseKeySpec("ctrl+s").?.eql(.{ .ctrl = .s }));
    try std.testing.expect(parseKeySpec("unknown") == null);
}

test "effective keymap matches overridden actions" {
    var config: Config = .{};
    config.set(.commit, .{ .plain_codepoint = 'm' });
    const effective = Effective.fromConfig(config);

    try std.testing.expectEqual(PublicAction.commit, effective.actionForKey(.{ .codepoint = 'm' }).?);
    try std.testing.expect(effective.actionForKey(.{ .codepoint = 'c' }) == null);
}

test "fetch is unbound by default and configurable" {
    const defaults: Effective = .{};
    try std.testing.expect(!defaults.isBound(.fetch));
    try std.testing.expect(defaults.actionForKey(.{ .codepoint = 'F' }) != PublicAction.fetch);
    try std.testing.expect(defaults.display(.fetch, &.{}) == null);

    var config: Config = .{};
    config.set(.fetch, .{ .ctrl = .s });
    const effective = Effective.fromConfig(config);
    try std.testing.expect(effective.isBound(.fetch));
    try std.testing.expectEqual(PublicAction.fetch, effective.actionForKey(.{ .codepoint = 's', .mods = .{ .ctrl = true } }).?);

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+s", effective.display(.fetch, buffer[0..]).?);
}

test "branch switch uses plain b and sidebar keeps shifted B" {
    const defaults: Effective = .{};
    try std.testing.expectEqual(PublicAction.branch_switch, defaults.actionForKey(.{ .codepoint = 'b' }).?);
    try std.testing.expectEqual(PublicAction.toggle_sidebar, defaults.actionForKey(.{ .codepoint = 'B' }).?);
    try std.testing.expectEqual(PublicAction.toggle_sidebar, defaults.actionForKey(.{ .codepoint = 'b', .mods = .{ .shift = true } }).?);
}

test "copy actions use y and shifted Y by default" {
    const defaults: Effective = .{};
    try std.testing.expectEqual(PublicAction.copy_current_line, defaults.actionForKey(.{ .codepoint = 'y' }).?);
    try std.testing.expectEqual(PublicAction.copy_current_hunk, defaults.actionForKey(.{ .codepoint = 'Y' }).?);
    try std.testing.expectEqual(PublicAction.copy_current_hunk, defaults.actionForKey(.{ .codepoint = 'y', .mods = .{ .shift = true } }).?);
}

test "validateConfig rejects reserved and duplicate effective bindings" {
    var reserved: Config = .{};
    reserved.set(.commit, .{ .plain_codepoint = 's' });
    try std.testing.expect(!validateConfig(reserved));

    var duplicate: Config = .{};
    duplicate.set(.commit, .{ .plain_codepoint = 'r' });
    try std.testing.expect(!validateConfig(duplicate));

    var duplicate_space: Config = .{};
    duplicate_space.set(.commit, .{ .named = .space });
    duplicate_space.set(.help, .{ .named = .space });
    try std.testing.expect(!validateConfig(duplicate_space));

    var fetch_duplicate: Config = .{};
    fetch_duplicate.set(.fetch, .{ .plain_codepoint = 'r' });
    try std.testing.expect(!validateConfig(fetch_duplicate));

    try std.testing.expect(validateConfig(.{}));
}
