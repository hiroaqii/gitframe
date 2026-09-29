//! Temporary fixtures whose absolute paths must stay short.

const std = @import("std");
const builtin = @import("builtin");

/// Unlike std.testing.tmpDir, this does not include the checkout path on
/// Linux/macOS. TMPDIR may also be too long for Unix sockets or bounded text.
/// The caller owns the returned directory and must call cleanup().
pub fn shortDir() !std.testing.TmpDir {
    comptime std.debug.assert(builtin.is_test);
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return std.testing.tmpDir(.{});

    const io = std.testing.io;
    const parent = try std.Io.Dir.openDirAbsolute(io, "/tmp", .{});
    errdefer parent.close(io);

    for (0..16) |_| {
        var random: [12]u8 = undefined;
        io.random(&random);
        var name: [16]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random);
        parent.createDir(io, &name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        errdefer parent.deleteTree(io, &name) catch {};
        return .{
            .dir = try parent.openDir(io, &name, .{}),
            .parent_dir = parent,
            .sub_path = name,
        };
    }
    return error.PathAlreadyExists;
}
