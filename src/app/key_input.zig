//! Terminal key normalization shared by shell and page input mappers.
//!
//! This leaf owns the policy for modifiers, shifted ASCII, generated key text,
//! Vaxis private-use special keys, and Unicode printability. Semantic command
//! mapping remains with each consumer.

const std = @import("std");
const chasen = @import("chasen");

pub fn matchesShiftedAscii(key: chasen.Key, lower: u21, upper: u21) bool {
    if (hasCommandModifier(key)) return false;
    return key.matches(upper, .{}) or (key.codepoint == lower and key.mods.shift);
}

pub fn hasCommandModifier(key: chasen.Key) bool {
    return key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta;
}

pub fn textInputCodepoint(key: chasen.Key) ?u21 {
    if (key.isModifier() or hasCommandModifier(key)) return null;
    if (keyTextCodepoint(key)) |codepoint| return codepoint;
    if (key.mods.shift) {
        if (key.shifted_codepoint) |codepoint| {
            if (isPrintableCodepoint(codepoint)) return codepoint;
        }
    }
    if (key.codepoint == chasen.Key.multicodepoint) return null;
    if (isVaxisSpecialCodepoint(key.codepoint)) return null;
    if (!isPrintableCodepoint(key.codepoint)) return null;
    return key.codepoint;
}

fn keyTextCodepoint(key: chasen.Key) ?u21 {
    const text = key.text orelse return null;
    if (text.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len != text.len) return null;
    const codepoint = std.unicode.utf8Decode(text) catch return null;
    if (!isPrintableCodepoint(codepoint)) return null;
    return codepoint;
}

fn isVaxisSpecialCodepoint(codepoint: u21) bool {
    return codepoint >= chasen.Key.insert and codepoint <= chasen.Key.iso_level_5_shift;
}

fn isPrintableCodepoint(codepoint: u21) bool {
    return codepoint >= 0x20 and codepoint != 0x7f and !(codepoint >= 0x80 and codepoint <= 0x9f);
}

test "generated printable text wins over physical key codepoint" {
    const key: chasen.Key = .{ .codepoint = 'a', .text = "あ" };
    try std.testing.expectEqual(@as(?u21, 'あ'), textInputCodepoint(key));
}

test "command modifiers and terminal special keys are not text" {
    try std.testing.expect(textInputCodepoint(.{ .codepoint = 'x', .mods = .{ .ctrl = true } }) == null);
    try std.testing.expect(textInputCodepoint(.{ .codepoint = chasen.Key.up }) == null);
}

test "shifted ASCII accepts both terminal encodings" {
    try std.testing.expect(matchesShiftedAscii(.{ .codepoint = 'N' }, 'n', 'N'));
    try std.testing.expect(matchesShiftedAscii(.{ .codepoint = 'n', .mods = .{ .shift = true } }, 'n', 'N'));
    try std.testing.expect(!matchesShiftedAscii(.{ .codepoint = 'N', .mods = .{ .ctrl = true } }, 'n', 'N'));
}
