//! Invocation-local files for one GitFrame-owned Codex run.

const std = @import("std");
const builtin = @import("builtin");

pub const Failure = error{
    UnsupportedCodexEnvironment,
    PrivateEnvironmentFailed,
    OutOfMemory,
};

pub const CleanupWarning = enum {
    private_root_residue,
};

const FaultInjection = struct {
    fail_after_root_creation: bool = false,
    cleanup_failure: bool = false,
};

const schema_name = "output-schema.json";

/// Owns only the private working directory and output schema. Codex inherits
/// its ordinary host HOME/CODEX_HOME and authentication context natively.
pub const Invocation = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp: std.Io.Dir,
    name: []u8,
    root_path: [:0]u8,
    work_path: []u8,
    schema_path: []u8,
    cleanup_failure_injected: bool = false,

    pub fn deinit(self: *Invocation) ?CleanupWarning {
        const warning = cleanupRoot(self.io, self.tmp, self.name, self.cleanup_failure_injected);
        self.tmp.close(self.io);
        self.allocator.free(self.schema_path);
        self.allocator.free(self.work_path);
        self.allocator.free(self.root_path);
        self.allocator.free(self.name);
        self.* = undefined;
        return warning;
    }
};

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_schema: []const u8,
    cleanup_warning: *?CleanupWarning,
) Failure!Invocation {
    return createWithFaultInjection(allocator, io, output_schema, cleanup_warning, .{});
}

fn createWithFaultInjection(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_schema: []const u8,
    cleanup_warning: *?CleanupWarning,
    faults: FaultInjection,
) Failure!Invocation {
    cleanup_warning.* = null;
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return error.UnsupportedCodexEnvironment;
    }

    var tmp = std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch
        return error.PrivateEnvironmentFailed;
    errdefer tmp.close(io);
    const name = createPrivateRoot(allocator, io, tmp) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PrivateEnvironmentFailed,
    };
    errdefer {
        cleanup_warning.* = cleanupRoot(io, tmp, name, faults.cleanup_failure);
        allocator.free(name);
    }
    if (faults.fail_after_root_creation) return error.PrivateEnvironmentFailed;
    var root = tmp.openDir(io, name, .{}) catch return error.PrivateEnvironmentFailed;
    defer root.close(io);
    root.createDir(io, "work", .fromMode(0o700)) catch return error.PrivateEnvironmentFailed;
    root.writeFile(io, .{
        .sub_path = schema_name,
        .data = output_schema,
        .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) },
    }) catch return error.PrivateEnvironmentFailed;

    const root_path = tmp.realPathFileAlloc(io, name, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PrivateEnvironmentFailed,
    };
    errdefer allocator.free(root_path);
    const work_path = std.fs.path.join(allocator, &.{ root_path, "work" }) catch return error.OutOfMemory;
    errdefer allocator.free(work_path);
    const output_schema_path = std.fs.path.join(allocator, &.{ root_path, schema_name }) catch return error.OutOfMemory;
    errdefer allocator.free(output_schema_path);

    return .{
        .allocator = allocator,
        .io = io,
        .tmp = tmp,
        .name = name,
        .root_path = root_path,
        .work_path = work_path,
        .schema_path = output_schema_path,
        .cleanup_failure_injected = faults.cleanup_failure,
    };
}

fn cleanupRoot(io: std.Io, tmp: std.Io.Dir, name: []const u8, inject_failure: bool) ?CleanupWarning {
    tmp.deleteTree(io, name) catch return .private_root_residue;
    return if (inject_failure) .private_root_residue else null;
}

fn createPrivateRoot(allocator: std.mem.Allocator, io: std.Io, tmp: std.Io.Dir) ![]u8 {
    var random: [16]u8 = undefined;
    for (0..16) |_| {
        try io.randomSecure(&random);
        const name = try std.fmt.allocPrint(allocator, "gitframe-codex-{x}", .{random});
        errdefer allocator.free(name);
        tmp.createDir(io, name, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(name);
                continue;
            },
            else => return err,
        };
        return name;
    }
    return error.PrivateRootCollision;
}

test "Codex invocation owns only an empty workdir and output schema" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var cleanup_warning: ?CleanupWarning = null;
    var invocation = try create(allocator, io, "{\"type\":\"object\"}", &cleanup_warning);
    try std.testing.expect(cleanup_warning == null);
    const root_path = try allocator.dupe(u8, invocation.root_path);
    defer allocator.free(root_path);

    const root_stat = try invocation.tmp.statFile(io, invocation.name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), root_stat.permissions.toMode() & 0o777);
    var root = try invocation.tmp.openDir(io, invocation.name, .{});
    defer root.close(io);
    const work_stat = try root.statFile(io, "work", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), work_stat.permissions.toMode() & 0o777);
    const schema_stat = try root.statFile(io, schema_name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), schema_stat.permissions.toMode() & 0o777);

    var work = try std.Io.Dir.openDirAbsolute(io, invocation.work_path, .{ .iterate = true });
    var iterator = work.iterate();
    try std.testing.expect(try iterator.next(io) == null);
    work.close(io);
    const schema = try std.Io.Dir.cwd().readFileAlloc(io, invocation.schema_path, allocator, .limited(1024));
    defer allocator.free(schema);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", schema);

    try std.testing.expect(invocation.deinit() == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, root_path, .{}));
}

test "Codex invocation reports injected normal teardown cleanup failure" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var cleanup_warning: ?CleanupWarning = null;
    var invocation = try createWithFaultInjection(
        std.testing.allocator,
        std.testing.io,
        "{}",
        &cleanup_warning,
        .{ .cleanup_failure = true },
    );
    try std.testing.expect(cleanup_warning == null);
    try std.testing.expectEqual(CleanupWarning.private_root_residue, invocation.deinit().?);
}

test "Codex partial-create rollback preserves injected cleanup failure" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var cleanup_warning: ?CleanupWarning = null;
    try std.testing.expectError(error.PrivateEnvironmentFailed, createWithFaultInjection(
        std.testing.allocator,
        std.testing.io,
        "{}",
        &cleanup_warning,
        .{ .fail_after_root_creation = true, .cleanup_failure = true },
    ));
    try std.testing.expectEqual(CleanupWarning.private_root_residue, cleanup_warning.?);
}
