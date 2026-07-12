//! Shared mapping from neutral token roles to the current GitFrame palette.

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
        .keyword, .operator => .accent,
        .function, .property => .info,
        .type, .constant => .prompt,
        .string => .success,
        .number => .warning,
        .comment => .muted,
        .variable, .punctuation, .plain => null,
    };
}
