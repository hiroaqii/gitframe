const std = @import("std");

/// Maximum argv entries passed to the foreground editor command.
///
/// The final slot is reserved for the target path, so overly long editor
/// commands are truncated before the file argument is appended.
pub const max_argv = 16;

/// Build the foreground editor argv from `$VISUAL`, `$EDITOR`, or `vi`.
///
/// This module only owns editor command resolution and argv construction. The
/// app owns when editing is allowed, the working directory, and reload behavior
/// after the foreground command finishes.
pub fn argv(env_map: ?*std.process.Environ.Map, target_path: []const u8, out: *[max_argv][]const u8) []const []const u8 {
    const cmd = command(env_map);
    var index: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, cmd, " \t\r\n");
    while (tokens.next()) |token| {
        if (index + 1 >= out.len) break;
        out[index] = token;
        index += 1;
    }
    if (index == 0) {
        out[0] = "vi";
        index = 1;
    }
    out[index] = target_path;
    return out[0 .. index + 1];
}

fn command(env_map: ?*std.process.Environ.Map) []const u8 {
    if (env_map) |map| {
        if (nonEmptyEnv(map, "VISUAL")) |visual| return visual;
        if (nonEmptyEnv(map, "EDITOR")) |editor| return editor;
    }
    return "vi";
}

fn nonEmptyEnv(env_map: *std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env_map.get(name) orelse return null;
    return if (std.mem.trim(u8, value, " \t\r\n").len > 0) value else null;
}

test "argv falls back to vi and appends target path" {
    var argv_buf: [max_argv][]const u8 = undefined;
    const args = argv(null, "src/main.zig", &argv_buf);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("vi", args[0]);
    try std.testing.expectEqualStrings("src/main.zig", args[1]);
}
