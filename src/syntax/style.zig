//! Shared mapping from neutral token roles to the current GitFrame palette.

const std = @import("std");
const chasen = @import("chasen");
const theme = @import("theme");
const token = @import("token.zig");

pub fn apply(base: chasen.TextStyle, role: token.TokenRole, palette: theme.Palette) chasen.TextStyle {
    var result = base;
    if (foreground(role, palette)) |color| result.fg = color;
    return result;
}

pub fn changesForeground(role: token.TokenRole) bool {
    return paletteRole(role) != null;
}

fn foreground(role: token.TokenRole, palette: theme.Palette) ?chasen.Color {
    return palette.color(paletteRole(role) orelse return null);
}

fn paletteRole(role: token.TokenRole) ?theme.Role {
    return switch (role) {
        .keyword => .syntax_keyword,
        .operator => .syntax_operator,
        .function => .syntax_function,
        .property, .parameter, .member, .macro, .special_punctuation => .syntax_property,
        .type, .constructor => .syntax_type,
        .constant => .syntax_constant,
        .string => .syntax_string,
        .number => .syntax_number,
        .comment => .syntax_comment,
        .variable, .punctuation, .plain => null,
    };
}

test "token roles map only colored syntax to dedicated theme roles" {
    try std.testing.expectEqual(theme.Role.syntax_keyword, paletteRole(.keyword).?);
    try std.testing.expectEqual(theme.Role.syntax_operator, paletteRole(.operator).?);
    try std.testing.expectEqual(theme.Role.syntax_function, paletteRole(.function).?);
    try std.testing.expectEqual(theme.Role.syntax_property, paletteRole(.property).?);
    try std.testing.expectEqual(theme.Role.syntax_property, paletteRole(.parameter).?);
    try std.testing.expectEqual(theme.Role.syntax_property, paletteRole(.member).?);
    try std.testing.expectEqual(theme.Role.syntax_property, paletteRole(.macro).?);
    try std.testing.expectEqual(theme.Role.syntax_property, paletteRole(.special_punctuation).?);
    try std.testing.expectEqual(theme.Role.syntax_type, paletteRole(.type).?);
    try std.testing.expectEqual(theme.Role.syntax_type, paletteRole(.constructor).?);
    try std.testing.expectEqual(theme.Role.syntax_constant, paletteRole(.constant).?);
    try std.testing.expectEqual(theme.Role.syntax_string, paletteRole(.string).?);
    try std.testing.expectEqual(theme.Role.syntax_number, paletteRole(.number).?);
    try std.testing.expectEqual(theme.Role.syntax_comment, paletteRole(.comment).?);
    try std.testing.expect(paletteRole(.variable) == null);
    try std.testing.expect(paletteRole(.punctuation) == null);
    try std.testing.expect(paletteRole(.plain) == null);
}

test "syntax style replaces only foreground from dedicated role" {
    var palette: theme.Palette = .default();
    palette.colors[@intFromEnum(theme.Role.syntax_keyword)] = .{ .rgb = .{ 1, 2, 3 } };
    const base: chasen.TextStyle = .{
        .bold = true,
        .italic = true,
        .fg = .{ .index = 7 },
        .bg = .{ .index = 8 },
    };

    const keyword = apply(base, .keyword, palette);
    try std.testing.expect(keyword.fg.eql(.{ .rgb = .{ 1, 2, 3 } }));
    try std.testing.expect(keyword.bg.eql(base.bg));
    try std.testing.expect(keyword.bold);
    try std.testing.expect(keyword.italic);
    try std.testing.expect(apply(base, .variable, palette).eql(base));
}
