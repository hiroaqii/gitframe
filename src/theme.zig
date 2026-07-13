const std = @import("std");
const chasen = @import("chasen");

pub const Role = enum {
    foreground,
    accent,
    muted,
    prompt,
    success,
    warning,
    danger,
    info,
    binary,
    staged,
    amend,

    diff_added,
    diff_modified,
    diff_removed,
    diff_added_bg,
    diff_removed_bg,
    diff_context_bg,
    diff_metadata,
    diff_line_number,
    diff_hunk,
    diff_cursor,
};

pub const role_count = @typeInfo(Role).@"enum".fields.len;

pub const ColorValue = union(enum) {
    named: NamedColor,
    index: u8,
    rgb: Rgb,

    pub fn toChasen(self: ColorValue) chasen.Color {
        return switch (self) {
            .named => |named| named.toChasen(),
            .index => |index| .{ .index = index },
            .rgb => |rgb| .{ .rgb = .{ rgb.r, rgb.g, rgb.b } },
        };
    }
};

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const NamedColor = enum {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    gray,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    pub fn toChasen(self: NamedColor) chasen.Color {
        return switch (self) {
            .black => .{ .index = 0 },
            .red => .{ .index = 1 },
            .green => .{ .index = 2 },
            .yellow => .{ .index = 3 },
            .blue => .{ .index = 4 },
            .magenta => .{ .index = 5 },
            .cyan => .{ .index = 6 },
            .white => .{ .index = 7 },
            .gray => .gray,
            .bright_red => .{ .index = 9 },
            .bright_green => .{ .index = 10 },
            .bright_yellow => .{ .index = 11 },
            .bright_blue => .{ .index = 12 },
            .bright_magenta => .{ .index = 13 },
            .bright_cyan => .{ .index = 14 },
            .bright_white => .{ .index = 15 },
        };
    }
};

pub const Palette = struct {
    colors: [role_count]chasen.Color,

    pub fn default() Palette {
        var palette = Palette{
            .colors = undefined,
        };
        palette.set(.foreground, .default);
        palette.set(.accent, .{ .index = 14 });
        palette.set(.muted, .gray);
        palette.set(.prompt, .{ .index = 11 });
        palette.set(.success, .{ .index = 2 });
        palette.set(.warning, .{ .index = 11 });
        palette.set(.danger, .{ .index = 9 });
        palette.set(.info, .{ .index = 12 });
        palette.set(.binary, .{ .index = 13 });
        palette.set(.staged, .{ .index = 10 });
        palette.set(.amend, .{ .rgb = .{ 203, 166, 247 } });

        palette.set(.diff_added, palette.color(.success));
        palette.set(.diff_modified, palette.color(.info));
        palette.set(.diff_removed, palette.color(.danger));
        palette.set(.diff_added_bg, .{ .rgb = .{ 18, 54, 35 } });
        palette.set(.diff_removed_bg, .{ .rgb = .{ 66, 28, 32 } });
        palette.set(.diff_context_bg, .default);
        palette.set(.diff_metadata, palette.color(.muted));
        palette.set(.diff_line_number, palette.color(.muted));
        palette.set(.diff_hunk, palette.color(.accent));
        palette.set(.diff_cursor, palette.color(.warning));
        return palette;
    }

    pub fn fromConfig(config: anytype) Palette {
        var palette = Palette.default();
        inline for (@typeInfo(Role).@"enum".fields) |field| {
            const role: Role = @enumFromInt(field.value);
            if (!isDerivedRole(role)) {
                if (config.get(role)) |value| {
                    palette.set(role, value.toChasen());
                }
            }
        }
        palette.deriveDiffRoles();
        inline for (@typeInfo(Role).@"enum".fields) |field| {
            const role: Role = @enumFromInt(field.value);
            if (isDerivedRole(role)) {
                if (config.get(role)) |value| {
                    palette.set(role, value.toChasen());
                }
            }
        }
        return palette;
    }

    pub fn color(self: Palette, role: Role) chasen.Color {
        return self.colors[roleIndex(role)];
    }

    pub fn style(self: Palette, role: Role) chasen.TextStyle {
        return .{ .fg = self.color(role) };
    }

    pub fn boldStyle(self: Palette, role: Role) chasen.TextStyle {
        return .{ .bold = true, .fg = self.color(role) };
    }

    fn set(self: *Palette, role: Role, color_value: chasen.Color) void {
        self.colors[roleIndex(role)] = color_value;
    }

    fn deriveDiffRoles(self: *Palette) void {
        self.set(.diff_added, self.color(.success));
        self.set(.diff_modified, self.color(.info));
        self.set(.diff_removed, self.color(.danger));
        self.set(.diff_metadata, self.color(.muted));
        self.set(.diff_line_number, self.color(.muted));
        self.set(.diff_hunk, self.color(.accent));
        self.set(.diff_cursor, self.color(.warning));
    }
};

fn isDerivedRole(role: Role) bool {
    return switch (role) {
        .diff_added,
        .diff_modified,
        .diff_removed,
        .diff_added_bg,
        .diff_removed_bg,
        .diff_context_bg,
        .diff_metadata,
        .diff_line_number,
        .diff_hunk,
        .diff_cursor,
        => true,
        else => false,
    };
}

pub fn roleFromKey(key: []const u8) ?Role {
    inline for (@typeInfo(Role).@"enum".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn parseColorValue(value: []const u8) ?ColorValue {
    if (std.mem.startsWith(u8, value, "#")) return parseHexColor(value);
    if (std.mem.startsWith(u8, value, "index:")) return parseIndexColor(value["index:".len..]);
    if (namedColorFromString(value)) |named| return .{ .named = named };
    return null;
}

fn parseHexColor(value: []const u8) ?ColorValue {
    if (value.len != 7) return null;
    return .{ .rgb = .{
        .r = parseHexByte(value[1..3]) orelse return null,
        .g = parseHexByte(value[3..5]) orelse return null,
        .b = parseHexByte(value[5..7]) orelse return null,
    } };
}

fn parseHexByte(value: []const u8) ?u8 {
    return std.fmt.parseInt(u8, value, 16) catch null;
}

fn parseIndexColor(value: []const u8) ?ColorValue {
    if (value.len == 0) return null;
    const index = std.fmt.parseInt(u8, value, 10) catch return null;
    return .{ .index = index };
}

fn namedColorFromString(value: []const u8) ?NamedColor {
    inline for (@typeInfo(NamedColor).@"enum".fields) |field| {
        if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    }
    if (std.mem.eql(u8, value, "bright-red")) return .bright_red;
    if (std.mem.eql(u8, value, "bright-green")) return .bright_green;
    if (std.mem.eql(u8, value, "bright-yellow")) return .bright_yellow;
    if (std.mem.eql(u8, value, "bright-blue")) return .bright_blue;
    if (std.mem.eql(u8, value, "bright-magenta")) return .bright_magenta;
    if (std.mem.eql(u8, value, "bright-cyan")) return .bright_cyan;
    if (std.mem.eql(u8, value, "bright-white")) return .bright_white;
    return null;
}

fn roleIndex(role: Role) usize {
    return @intFromEnum(role);
}

test "parseColorValue accepts named, hex, and indexed values" {
    try std.testing.expect(parseColorValue("cyan").?.toChasen().eql(.{ .index = 6 }));
    try std.testing.expect(parseColorValue("bright-cyan").?.toChasen().eql(.{ .index = 14 }));
    try std.testing.expect(parseColorValue("#cba6f7").?.toChasen().eql(.{ .rgb = .{ 203, 166, 247 } }));
    try std.testing.expect(parseColorValue("index:11").?.toChasen().eql(.{ .index = 11 }));
}

test "parseColorValue rejects invalid values" {
    try std.testing.expect(parseColorValue("not-a-color") == null);
    try std.testing.expect(parseColorValue("#xyz") == null);
    try std.testing.expect(parseColorValue("index:") == null);
}

test "roleFromKey maps known theme keys" {
    try std.testing.expectEqual(Role.foreground, roleFromKey("foreground").?);
    try std.testing.expectEqual(Role.accent, roleFromKey("accent").?);
    try std.testing.expectEqual(Role.diff_added, roleFromKey("diff_added").?);
    try std.testing.expectEqual(Role.diff_modified, roleFromKey("diff_modified").?);
    try std.testing.expectEqual(Role.diff_added_bg, roleFromKey("diff_added_bg").?);
    try std.testing.expect(roleFromKey("diff-added") == null);
}

test "Palette.fromConfig derives diff roles from base role overrides" {
    const FakeConfig = struct {
        pub fn get(_: @This(), role: Role) ?ColorValue {
            return switch (role) {
                .success => .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
                .info => .{ .rgb = .{ .r = 7, .g = 8, .b = 9 } },
                else => null,
            };
        }
    };

    const palette = Palette.fromConfig(FakeConfig{});
    try std.testing.expect(palette.color(.success).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_added).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_modified).eql(.{ .rgb = .{ 7, 8, 9 } }));
}

test "Palette.fromConfig lets explicit diff role overrides win" {
    const FakeConfig = struct {
        pub fn get(_: @This(), role: Role) ?ColorValue {
            return switch (role) {
                .success => .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
                .diff_added => .{ .index = 10 },
                .diff_modified => .{ .index = 12 },
                .diff_added_bg => .{ .rgb = .{ .r = 4, .g = 5, .b = 6 } },
                else => null,
            };
        }
    };

    const palette = Palette.fromConfig(FakeConfig{});
    try std.testing.expect(palette.color(.success).eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(palette.color(.diff_added).eql(.{ .index = 10 }));
    try std.testing.expect(palette.color(.diff_modified).eql(.{ .index = 12 }));
    try std.testing.expect(palette.color(.diff_added_bg).eql(.{ .rgb = .{ 4, 5, 6 } }));
}
