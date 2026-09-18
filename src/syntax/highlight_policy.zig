const std = @import("std");

const markdown_extensions = [_][]const u8{
    "md",
    "markdown",
    "mdown",
    "mkd",
    "mkdn",
    "mdwn",
    "mdtxt",
    "mdtext",
    "smd",
};

/// Markdown is intentionally rendered as plain text. Keep this decision in
/// the syntax boundary so every full-source and diff consumer shares it.
pub fn enabledForPath(path: ?[]const u8) bool {
    const value = path orelse return true;
    const extension = std.fs.path.extension(value);
    if (extension.len <= 1) return true;
    const name = extension[1..];
    for (markdown_extensions) |markdown_extension| {
        if (std.ascii.eqlIgnoreCase(name, markdown_extension)) return false;
    }
    return true;
}

test "syntax highlighting policy disables Markdown extensions" {
    try std.testing.expect(!enabledForPath("README.md"));
    try std.testing.expect(!enabledForPath("docs/guide.MARKDOWN"));
    try std.testing.expect(!enabledForPath("notes.SmD"));
    try std.testing.expect(enabledForPath("src/markdown.zig"));
    try std.testing.expect(enabledForPath("README"));
    try std.testing.expect(enabledForPath(null));
}
