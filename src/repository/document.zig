//! Descriptor-safe, bounded snapshot of one repository-relative object.
//!
//! This module is page-neutral: Repository uses it for selected-file browsing,
//! while Review uses the same contract for primary and syntax rereads of an
//! untracked generated preview. Keeping one loader is important because a
//! separate stat-then-open helper would reintroduce symlink substitution and
//! blocking special-file windows at exactly the async ownership boundary.

const std = @import("std");
const builtin = @import("builtin");
const content_fingerprint = @import("../content_fingerprint.zig");
const root_capability = @import("../repo/root_capability.zig");
const repository_path = @import("path.zig");

pub const max_text_bytes: usize = 1024 * 1024;
const max_symlink_target_bytes: usize = std.Io.Dir.max_path_bytes - 1;

const MutationHook = struct {
    context: *anyopaque,
    run: *const fn (context: *anyopaque, parent: std.Io.Dir, name: []const u8, io: std.Io) void,

    fn invoke(self: MutationHook, parent: std.Io.Dir, name: []const u8, io: std.Io) void {
        self.run(self.context, parent, name, io);
    }
};

/// Private deterministic seams used only by this module's race tests. The
/// production entry point always supplies the zero value.
const LoadHooks = struct {
    before_regular_open: ?MutationHook = null,
    /// Runs after the loader has classified the descriptor contents but before
    /// the final descriptor stat which proves that classification stable. The
    /// same seam covers the bounded no-content oversized path.
    before_regular_final_stat: ?MutationHook = null,
};

pub const StableMetadata = struct {
    modified_at: std.Io.Timestamp,
};

pub const Value = union(enum) {
    text: struct {
        bytes: []u8,
        fingerprint: content_fingerprint.Fingerprint,
    },
    symlink: struct {
        target: []u8,
        fingerprint: content_fingerprint.Fingerprint,
    },
    binary,
    invalid_utf8,
    unsafe_control_text,
    oversized: u64,
    directory_or_gitlink,
    named_pipe,
    unix_socket,
    block_device,
    character_device,
    unknown_special,
    missing_or_changed,
    unreadable,
    unsupported_platform,

    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |value| allocator.free(value.bytes),
            .symlink => |value| allocator.free(value.target),
            else => {},
        }
        self.* = undefined;
    }
};

/// One descriptor-safe observation of a repository-relative object.
///
/// Metadata is optional because missing, unsupported, special, and read-error
/// terminals do not describe an accepted regular file or symlink. A stable
/// regular/symlink classification is never published without the metadata
/// proved by its final stat; the two values are one acceptance unit.
pub const Snapshot = struct {
    value: Value,
    metadata: ?StableMetadata = null,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.value.deinit(allocator);
        self.* = undefined;
    }
};

/// Load and classify one selected repository-relative object from a pinned
/// root descriptor. Expected filesystem states are inert values, not errors.
pub fn load(
    root: root_capability.RootCapability,
    raw_path: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
) Snapshot {
    return loadWithHooks(root, raw_path, allocator, io, .{});
}

fn loadWithHooks(
    root: root_capability.RootCapability,
    raw_path: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    hooks: LoadHooks,
) Snapshot {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return withoutMetadata(.unsupported_platform);
    repository_path.validate(raw_path) catch return withoutMetadata(.missing_or_changed);

    const split = std.mem.lastIndexOfScalar(u8, raw_path, '/');
    const parent_path = if (split) |index| raw_path[0..index] else "";
    const final_name = if (split) |index| raw_path[index + 1 ..] else raw_path;

    var parent_handle = root.handle;
    var owns_parent = false;
    defer if (owns_parent) closeRaw(parent_handle);
    if (parent_path.len > 0) {
        var components = std.mem.splitScalar(u8, parent_path, '/');
        while (components.next()) |component| {
            const child = std.posix.openat(parent_handle, component, directoryFlags(), 0) catch return withoutMetadata(.missing_or_changed);
            if (owns_parent) closeRaw(parent_handle);
            parent_handle = child;
            owns_parent = true;
        }
    }

    const parent: std.Io.Dir = .{ .handle = parent_handle };
    const before = parent.statFile(io, final_name, .{ .follow_symlinks = false }) catch |err| {
        return withoutMetadata(mapStatFailure(err));
    };
    return switch (before.kind) {
        .sym_link => loadSymlink(parent, final_name, before, allocator, io),
        .directory => withoutMetadata(.directory_or_gitlink),
        .named_pipe => withoutMetadata(.named_pipe),
        .unix_domain_socket => withoutMetadata(.unix_socket),
        .block_device => withoutMetadata(.block_device),
        .character_device => withoutMetadata(.character_device),
        .file => blk: {
            if (hooks.before_regular_open) |hook| hook.invoke(parent, final_name, io);
            break :blk loadRegular(parent_handle, final_name, allocator, io, hooks.before_regular_final_stat);
        },
        else => withoutMetadata(.unknown_special),
    };
}

fn loadSymlink(
    parent: std.Io.Dir,
    name: []const u8,
    before: std.Io.File.Stat,
    allocator: std.mem.Allocator,
    io: std.Io,
) Snapshot {
    // The extra byte is a truncation sentinel: a full buffer is rejected
    // because readlink cannot otherwise distinguish exact fit from truncation.
    var target_buffer: [max_symlink_target_bytes + 1]u8 = undefined;
    const len = parent.readLink(io, name, &target_buffer) catch return withoutMetadata(.missing_or_changed);
    const target_len = acceptedSymlinkTargetLength(len) orelse return withoutMetadata(.missing_or_changed);
    const after = parent.statFile(io, name, .{ .follow_symlinks = false }) catch return withoutMetadata(.missing_or_changed);
    if (!stableStat(before, after)) return withoutMetadata(.missing_or_changed);
    const target = allocator.dupe(u8, target_buffer[0..target_len]) catch return withoutMetadata(.unreadable);
    return withStableMetadata(.{ .symlink = .{
        .target = target,
        .fingerprint = content_fingerprint.Fingerprint.init(target),
    } }, after.mtime);
}

fn acceptedSymlinkTargetLength(read_len: usize) ?usize {
    if (read_len > max_symlink_target_bytes) return null;
    return read_len;
}

fn loadRegular(
    parent_handle: std.posix.fd_t,
    name: []const u8,
    allocator: std.mem.Allocator,
    io: std.Io,
    before_final_stat_hook: ?MutationHook,
) Snapshot {
    const handle = std.posix.openat(parent_handle, name, regularFlags(), 0) catch |err| return withoutMetadata(mapOpenFailure(err));
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
    defer file.close(io);

    const before = file.stat(io) catch return withoutMetadata(.unreadable);
    if (before.kind != .file) return withoutMetadata(valueForKind(before.kind));
    if (before.size > max_text_bytes) {
        if (before_final_stat_hook) |hook| hook.invoke(.{ .handle = parent_handle }, name, io);
        const after = file.stat(io) catch return withoutMetadata(.missing_or_changed);
        if (!stableStat(before, after)) return withoutMetadata(.missing_or_changed);
        return withStableMetadata(.{ .oversized = before.size }, after.mtime);
    }

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &reader_buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_text_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return withoutMetadata(.missing_or_changed),
        else => return withoutMetadata(.unreadable),
    };
    if (bytes.len > max_text_bytes) {
        allocator.free(bytes);
        return withoutMetadata(.missing_or_changed);
    }
    if (before.size != bytes.len) {
        allocator.free(bytes);
        return withoutMetadata(.missing_or_changed);
    }

    if (before_final_stat_hook) |hook| hook.invoke(.{ .handle = parent_handle }, name, io);

    const after = file.stat(io) catch {
        allocator.free(bytes);
        return withoutMetadata(.missing_or_changed);
    };
    if (!stableStat(before, after)) {
        allocator.free(bytes);
        return withoutMetadata(.missing_or_changed);
    }
    return withStableMetadata(classifyOwned(bytes, allocator), after.mtime);
}

fn withoutMetadata(value: Value) Snapshot {
    return .{ .value = value };
}

fn withStableMetadata(value: Value, modified_at: std.Io.Timestamp) Snapshot {
    return .{
        .value = value,
        .metadata = .{ .modified_at = modified_at },
    };
}

fn classifyOwned(bytes: []u8, allocator: std.mem.Allocator) Value {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        allocator.free(bytes);
        return .binary;
    }
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        return .invalid_utf8;
    }
    if (containsUnsafeControl(bytes)) {
        allocator.free(bytes);
        return .unsafe_control_text;
    }
    return .{ .text = .{
        .fingerprint = content_fingerprint.Fingerprint.init(bytes),
        .bytes = bytes,
    } };
}

fn containsUnsafeControl(bytes: []const u8) bool {
    var iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\t' or codepoint == '\n') continue;
        if (codepoint == '\r' and iter.i < bytes.len and bytes[iter.i] == '\n') continue;
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f)) return true;
    }
    return false;
}

fn stableStat(before: std.Io.File.Stat, after: std.Io.File.Stat) bool {
    return before.kind == after.kind and
        before.inode == after.inode and
        before.size == after.size and
        before.mtime.nanoseconds == after.mtime.nanoseconds and
        before.ctime.nanoseconds == after.ctime.nanoseconds;
}

fn valueForKind(kind: std.Io.File.Kind) Value {
    return switch (kind) {
        .file => .missing_or_changed,
        .directory => .directory_or_gitlink,
        .named_pipe => .named_pipe,
        .unix_domain_socket => .unix_socket,
        .block_device => .block_device,
        .character_device => .character_device,
        .sym_link => .missing_or_changed,
        else => .unknown_special,
    };
}

fn mapStatFailure(err: anyerror) Value {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => .missing_or_changed,
        error.AccessDenied, error.PermissionDenied => .unreadable,
        else => .unreadable,
    };
}

fn mapOpenFailure(err: anyerror) Value {
    return switch (err) {
        error.FileNotFound, error.NotDir, error.SymLinkLoop => .missing_or_changed,
        error.AccessDenied, error.PermissionDenied => .unreadable,
        else => .unreadable,
    };
}

fn directoryFlags() std.posix.O {
    return .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    };
}

fn regularFlags() std.posix.O {
    return .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .NOCTTY = true,
    };
}

fn closeRaw(handle: std.posix.fd_t) void {
    _ = std.posix.system.close(handle);
}

fn createFifoForTest(dir: std.Io.Dir, name: []const u8) !void {
    const argv = [_][]const u8{ "mkfifo", "--", name };
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.MkfifoFailed;
}

const ReplaceWithFifoContext = struct {
    failed: bool = false,

    fn run(context: *anyopaque, parent: std.Io.Dir, name: []const u8, io: std.Io) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        parent.deleteFile(io, name) catch {
            self.failed = true;
            return;
        };
        createFifoForTest(parent, name) catch {
            self.failed = true;
        };
    }
};

const RewriteAfterReadContext = struct {
    failed: bool = false,

    fn run(context: *anyopaque, parent: std.Io.Dir, name: []const u8, io: std.Io) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        parent.writeFile(io, .{ .sub_path = name, .data = "replacement with a different size\n" }) catch {
            self.failed = true;
        };
    }
};

test "repository document loads bounded text through pinned root" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.createDir(io, "src", .default_dir);
    try repo.writeFile(io, .{ .sub_path = "src/main.zig", .data = "const value = 1;\n" });
    const expected = try repo.statFile(io, "src/main.zig", .{});
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var snapshot = load(root, "src/main.zig", allocator, io);
    defer snapshot.deinit(allocator);
    switch (snapshot.value) {
        .text => |text| {
            try std.testing.expectEqualStrings("const value = 1;\n", text.bytes);
            try std.testing.expect(text.fingerprint.eql(content_fingerprint.Fingerprint.init(text.bytes)));
        },
        else => return error.ExpectedTextDocument,
    }
    try std.testing.expectEqual(expected.mtime.nanoseconds, snapshot.metadata.?.modified_at.nanoseconds);
}

test "repository document keeps symlink target inert" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    try repo.writeFile(io, .{ .sub_path = "target", .data = "secret" });
    try repo.symLink(io, "target", "link", .{});
    const expected = try repo.statFile(io, "link", .{ .follow_symlinks = false });
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var snapshot = load(root, "link", allocator, io);
    defer snapshot.deinit(allocator);
    switch (snapshot.value) {
        .symlink => |link| try std.testing.expectEqualStrings("target", link.target),
        else => return error.ExpectedSymlinkDocument,
    }
    try std.testing.expectEqual(expected.mtime.nanoseconds, snapshot.metadata.?.modified_at.nanoseconds);
}

test "repository document symlink sentinel accepts boundary and rejects full buffer" {
    try std.testing.expectEqual(max_symlink_target_bytes, acceptedSymlinkTargetLength(max_symlink_target_bytes).?);
    try std.testing.expect(acceptedSymlinkTargetLength(max_symlink_target_bytes + 1) == null);
}

test "repository document rejects symlink replaced between stat and read" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.symLink(io, "old", "link", .{});
    const before = try tmp.dir.statFile(io, "link", .{ .follow_symlinks = false });
    try tmp.dir.deleteFile(io, "link");
    try tmp.dir.symLink(io, "replacement-target", "link", .{});

    var snapshot = loadSymlink(tmp.dir, "link", before, allocator, io);
    defer snapshot.deinit(allocator);
    try std.testing.expect(snapshot.value == .missing_or_changed);
    try std.testing.expect(snapshot.metadata == null);
}

test "repository document retains invalid UTF-8 and control bytes in inert symlink target" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const target = "opaque-\x1b-\xff";
    try tmp.dir.symLink(io, target, "link", .{});
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var snapshot = load(root, "link", allocator, io);
    defer snapshot.deinit(allocator);
    switch (snapshot.value) {
        .symlink => |link| {
            try std.testing.expectEqualSlices(u8, target, link.target);
            try std.testing.expect(link.fingerprint.eql(content_fingerprint.Fingerprint.init(target)));
        },
        else => return error.ExpectedSymlinkDocument,
    }
}

test "repository document maps every final object kind to an inert value" {
    const Case = struct { kind: std.Io.File.Kind, tag: std.meta.Tag(Value) };
    const cases = [_]Case{
        .{ .kind = .file, .tag = .missing_or_changed },
        .{ .kind = .directory, .tag = .directory_or_gitlink },
        .{ .kind = .named_pipe, .tag = .named_pipe },
        .{ .kind = .unix_domain_socket, .tag = .unix_socket },
        .{ .kind = .block_device, .tag = .block_device },
        .{ .kind = .character_device, .tag = .character_device },
        .{ .kind = .sym_link, .tag = .missing_or_changed },
        .{ .kind = .unknown, .tag = .unknown_special },
    };
    for (cases) |case| try std.testing.expectEqual(case.tag, std.meta.activeTag(valueForKind(case.kind)));
}

test "repository document classifies a named pipe without blocking" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFifoForTest(tmp.dir, "pipe");
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var snapshot = load(root, "pipe", allocator, io);
    defer snapshot.deinit(allocator);
    try std.testing.expect(snapshot.value == .named_pipe);
    try std.testing.expect(snapshot.metadata == null);
}

test "repository document final open reclassifies regular file replaced by named pipe" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "selected", .data = "old\n" });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var mutation: ReplaceWithFifoContext = .{};

    var snapshot = loadWithHooks(root, "selected", allocator, io, .{ .before_regular_open = .{
        .context = &mutation,
        .run = ReplaceWithFifoContext.run,
    } });
    defer snapshot.deinit(allocator);
    try std.testing.expect(!mutation.failed);
    try std.testing.expect(snapshot.value == .named_pipe);
    try std.testing.expect(snapshot.metadata == null);
}

test "repository document rejects a file changed after read" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "selected", .data = "old\n" });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var mutation: RewriteAfterReadContext = .{};

    var snapshot = loadWithHooks(root, "selected", allocator, io, .{ .before_regular_final_stat = .{
        .context = &mutation,
        .run = RewriteAfterReadContext.run,
    } });
    defer snapshot.deinit(allocator);
    try std.testing.expect(!mutation.failed);
    try std.testing.expect(snapshot.value == .missing_or_changed);
    try std.testing.expect(snapshot.metadata == null);
}

test "repository document classifies a unix domain socket" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    const socket_path = try std.fs.path.join(allocator, &.{ root_path, "socket" });
    defer allocator.free(socket_path);
    const address = try std.Io.net.UnixAddress.init(socket_path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var snapshot = load(root, "socket", allocator, io);
    defer snapshot.deinit(allocator);
    try std.testing.expect(snapshot.value == .unix_socket);
    try std.testing.expect(snapshot.metadata == null);
}

test "repository document reads committed object after root path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    var outside = try tmp.dir.openDir(io, "outside", .{});
    defer outside.close(io);
    try repo.writeFile(io, .{ .sub_path = "selected.txt", .data = "committed\n" });
    try outside.writeFile(io, .{ .sub_path = "selected.txt", .data = "replacement\n" });
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    try tmp.dir.rename("repo", tmp.dir, "old-repo", io);
    try tmp.dir.symLink(io, "outside", "repo", .{ .is_directory = true });
    var snapshot = load(root, "selected.txt", allocator, io);
    defer snapshot.deinit(allocator);
    switch (snapshot.value) {
        .text => |text| try std.testing.expectEqualStrings("committed\n", text.bytes),
        else => return error.ExpectedCommittedText,
    }
}

test "repository document rejects unsafe content without retaining bytes" {
    const allocator = std.testing.allocator;
    const binary = try allocator.dupe(u8, "a\x00b");
    var binary_value = classifyOwned(binary, allocator);
    defer binary_value.deinit(allocator);
    try std.testing.expect(binary_value == .binary);

    const control = try allocator.dupe(u8, "page\x0cnext");
    var control_value = classifyOwned(control, allocator);
    defer control_value.deinit(allocator);
    try std.testing.expect(control_value == .unsafe_control_text);

    const c1 = try allocator.dupe(u8, "before\xc2\x80after");
    var c1_value = classifyOwned(c1, allocator);
    defer c1_value.deinit(allocator);
    try std.testing.expect(c1_value == .unsafe_control_text);

    const lone_cr = try allocator.dupe(u8, "before\rafter");
    var lone_cr_value = classifyOwned(lone_cr, allocator);
    defer lone_cr_value.deinit(allocator);
    try std.testing.expect(lone_cr_value == .unsafe_control_text);

    const invalid = try allocator.dupe(u8, "invalid-\xff");
    var invalid_value = classifyOwned(invalid, allocator);
    defer invalid_value.deinit(allocator);
    try std.testing.expect(invalid_value == .invalid_utf8);

    const allowed = try allocator.dupe(u8, "tab\tok\r\nemoji: 🐘");
    var allowed_value = classifyOwned(allowed, allocator);
    defer allowed_value.deinit(allocator);
    try std.testing.expect(allowed_value == .text);
}

test "repository document stable inert regular classifications retain proved metadata" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]struct {
        name: []const u8,
        bytes: []const u8,
        tag: std.meta.Tag(Value),
    }{
        .{ .name = "binary", .bytes = "a\x00b", .tag = .binary },
        .{ .name = "invalid", .bytes = "invalid-\xff", .tag = .invalid_utf8 },
        .{ .name = "control", .bytes = "page\x0cnext", .tag = .unsafe_control_text },
    };

    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = case.name, .data = case.bytes });
        const expected = try tmp.dir.statFile(io, case.name, .{});
        var snapshot = load(root, case.name, allocator, io);
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(case.tag, std.meta.activeTag(snapshot.value));
        try std.testing.expectEqual(expected.mtime.nanoseconds, snapshot.metadata.?.modified_at.nanoseconds);
    }
}

test "repository document preserves negative proved timestamp as raw metadata" {
    var snapshot = withStableMetadata(.binary, .{ .nanoseconds = -1 });
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i96, -1), snapshot.metadata.?.modified_at.nanoseconds);
}

test "repository document enforces exact one MiB boundary" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const exact = try allocator.alloc(u8, max_text_bytes);
    defer allocator.free(exact);
    @memset(exact, 'a');
    const over = try allocator.alloc(u8, max_text_bytes + 1);
    defer allocator.free(over);
    @memset(over, 'b');
    try tmp.dir.writeFile(io, .{ .sub_path = "exact.txt", .data = exact });
    try tmp.dir.writeFile(io, .{ .sub_path = "over.txt", .data = over });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var exact_snapshot = load(root, "exact.txt", allocator, io);
    defer exact_snapshot.deinit(allocator);
    switch (exact_snapshot.value) {
        .text => |text| try std.testing.expectEqual(max_text_bytes, text.bytes.len),
        else => return error.ExpectedBoundaryText,
    }
    var over_snapshot = load(root, "over.txt", allocator, io);
    defer over_snapshot.deinit(allocator);
    try std.testing.expect(over_snapshot.value == .oversized);
    const expected_over = try tmp.dir.statFile(io, "over.txt", .{});
    try std.testing.expectEqual(expected_over.mtime.nanoseconds, over_snapshot.metadata.?.modified_at.nanoseconds);
}

test "repository document oversized classification requires a stable second stat" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const over = try allocator.alloc(u8, max_text_bytes + 1);
    defer allocator.free(over);
    @memset(over, 'x');
    try tmp.dir.writeFile(io, .{ .sub_path = "over.txt", .data = over });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();
    var mutation: RewriteAfterReadContext = .{};

    var snapshot = loadWithHooks(root, "over.txt", allocator, io, .{ .before_regular_final_stat = .{
        .context = &mutation,
        .run = RewriteAfterReadContext.run,
    } });
    defer snapshot.deinit(allocator);
    try std.testing.expect(!mutation.failed);
    try std.testing.expect(snapshot.value == .missing_or_changed);
    try std.testing.expect(snapshot.metadata == null);
}

test "repository document rejects intermediate symlink" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "repo", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    var repo = try tmp.dir.openDir(io, "repo", .{});
    defer repo.close(io);
    var outside = try tmp.dir.openDir(io, "outside", .{});
    defer outside.close(io);
    try outside.writeFile(io, .{ .sub_path = "secret.txt", .data = "secret" });
    try repo.symLink(io, "../outside", "linked", .{ .is_directory = true });
    const root_path = try tmp.dir.realPathFileAlloc(io, "repo", allocator);
    defer allocator.free(root_path);
    var root = try root_capability.RootCapability.openCanonical(root_path);
    defer root.deinit();

    var snapshot = load(root, "linked/secret.txt", allocator, io);
    defer snapshot.deinit(allocator);
    try std.testing.expect(snapshot.value == .missing_or_changed);
    try std.testing.expect(snapshot.metadata == null);
}
