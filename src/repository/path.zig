const std = @import("std");

pub const max_bytes: usize = 64 * 1024;

pub const ValidationError = error{
    EmptyPath,
    PathTooLong,
    AbsolutePath,
    InvalidComponent,
};

/// Validate the byte-exact repository-relative identity shared by manifest
/// parsing and descriptor-relative document loading.
pub fn validate(raw: []const u8) ValidationError!void {
    if (raw.len == 0) return error.EmptyPath;
    if (raw.len > max_bytes) return error.PathTooLong;
    if (raw[0] == '/' or std.fs.path.isAbsolute(raw)) return error.AbsolutePath;

    var components = std.mem.splitScalar(u8, raw, '/');
    while (components.next()) |component| {
        if (component.len == 0 or
            std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..") or
            std.mem.eql(u8, component, ".git"))
        {
            return error.InvalidComponent;
        }
    }
}

test "repository path accepts byte-exact nested relative paths" {
    try validate("src/main.zig");
    try validate("opaque-\xff/name");
}

test "repository path rejects traversal and reserved components" {
    try std.testing.expectError(error.EmptyPath, validate(""));
    try std.testing.expectError(error.AbsolutePath, validate("/tmp/file"));
    try std.testing.expectError(error.InvalidComponent, validate("."));
    try std.testing.expectError(error.InvalidComponent, validate("a/../b"));
    try std.testing.expectError(error.InvalidComponent, validate("a//b"));
    try std.testing.expectError(error.InvalidComponent, validate(".git/config"));
}

test "repository path enforces bounded identity" {
    const bytes = [_]u8{'a'} ** (max_bytes + 1);
    try std.testing.expectError(error.PathTooLong, validate(&bytes));
}
