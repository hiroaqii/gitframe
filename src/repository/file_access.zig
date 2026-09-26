//! Shared no-follow descriptor operations for repository document and stats reads.
const std = @import("std");
const builtin = @import("builtin");
const path = @import("path.zig");
const capability = @import("../fs/capability.zig");

pub const Parent = struct {
    dir: std.Io.Dir,
    name: []const u8,
    owned: bool,

    pub fn deinit(self: *Parent, io: std.Io) void {
        if (self.owned) self.dir.close(io);
        self.* = undefined;
    }
};

/// Pin each directory before traversing the next component. The root is borrowed.
pub fn openParent(root: std.Io.Dir, raw_path: []const u8, io: std.Io) !Parent {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.UnsupportedPlatform;
    path.validate(raw_path) catch return error.InvalidPath;
    var parent: Parent = .{ .dir = root, .name = "", .owned = false };
    errdefer parent.deinit(io);
    var components = std.mem.splitScalar(u8, raw_path, '/');
    var component = components.next().?;
    while (true) {
        capability.validateChildName(component) catch return error.InvalidPath;
        const next = components.next() orelse {
            parent.name = component;
            return parent;
        };
        const child = std.posix.openat(parent.dir.handle, component, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
            .NONBLOCK = true,
            .NOCTTY = true,
        }, 0) catch return error.InvalidPath;
        if (parent.owned) parent.dir.close(io);
        parent.dir = .{ .handle = child };
        parent.owned = true;
        component = next;
    }
}

/// Never follow a leaf symlink or block while opening a substituted FIFO.
/// Callers classify the opened descriptor before reading any bytes.
pub fn openLeaf(parent: std.Io.Dir, name: []const u8) !std.Io.File {
    capability.validateChildName(name) catch return error.InvalidPath;
    const handle = try std.posix.openat(parent.handle, name, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    }, 0);
    return .{ .handle = handle, .flags = .{ .nonblocking = true } };
}

pub fn readRegularAlloc(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, raw_path: []const u8, limit: usize) ![]u8 {
    var parent = try openParent(root, raw_path, io);
    defer parent.deinit(io);
    const file = openLeaf(parent.dir, parent.name) catch |err| switch (err) {
        error.SymLinkLoop => return error.InvalidPath,
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidPath;
    if (stat.size > limit) return error.StreamTooLong;
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    // A sentinel byte distinguishes an exact fit from an over-budget stream.
    const bytes = try reader.interface.allocRemaining(allocator, .limited64(@as(u64, limit) +| 1));
    errdefer allocator.free(bytes);
    if (bytes.len > limit) return error.StreamTooLong;
    return bytes;
}
