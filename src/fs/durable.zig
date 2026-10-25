//! Domain-free single-operation filesystem mutation and durability mechanics.
const std = @import("std");
const fs = @import("capability.zig");

pub const Operation = enum { create_directory, create_file, write, sync_file, sync_directory, rename_preserve, rename_replace, unlink_file, unlink_directory };
pub const Edge = enum { before, after };
pub const Step = struct { operation: Operation, edge: Edge };
pub const Observer = struct {
    context: ?*anyopaque = null,
    observe_fn: *const fn (?*anyopaque, Step) anyerror!void = noOp,

    pub fn observe(self: Observer, step: Step) !void {
        try self.observe_fn(self.context, step);
    }
    fn noOp(_: ?*anyopaque, _: Step) !void {}
};
pub fn Outcome(comptime T: type) type {
    return union(enum) {
        not_completed: anyerror,
        completed: struct { value: T, after_error: ?anyerror },
    };
}
pub const AcquisitionDisposition = enum { existing, created };
pub const DirectoryAcquisition = struct { disposition: AcquisitionDisposition, directory: ?fs.Directory };
pub const FileAcquisition = struct { disposition: AcquisitionDisposition, file: fs.File };

pub fn createDirectory(io: std.Io, parent: fs.Directory, name: []const u8, permissions: std.Io.Dir.Permissions, observer: Observer) Outcome([]const u8) {
    fs.validateChildName(name) catch |err| return stopped([]const u8, err);
    observer.observe(.{ .operation = .create_directory, .edge = .before }) catch |err| return stopped([]const u8, err);
    ioDirectory(parent).createDir(io, name, permissions) catch |err| return stopped([]const u8, err);
    return finished([]const u8, name, observer, .create_directory);
}

pub fn createFile(parent: fs.Directory, name: []const u8, permissions: std.Io.File.Permissions, observer: Observer) Outcome(fs.File) {
    fs.validateChildName(name) catch |err| return stopped(fs.File, err);
    observer.observe(.{ .operation = .create_file, .edge = .before }) catch |err| return stopped(fs.File, err);
    const handle = std.posix.openat(parent.descriptor.handle, name, writableExclusiveFlags(), permissions.toMode()) catch |err|
        return stopped(fs.File, err);
    var file: fs.File = .{ .descriptor = .{ .handle = handle }, .metadata = std.mem.zeroes(fs.Metadata) };
    const after_error = observeAfter(observer, .create_file);
    file.metadata = fs.metadataForHandle(file.descriptor) catch |err|
        return .{ .completed = .{ .value = file, .after_error = after_error orelse err } };
    return .{ .completed = .{ .value = file, .after_error = after_error } };
}

pub fn writeAll(io: std.Io, file: fs.File, bytes: []const u8, observer: Observer) Outcome(void) {
    observer.observe(.{ .operation = .write, .edge = .before }) catch |err| return stopped(void, err);
    ioFile(file).writeStreamingAll(io, bytes) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .write);
}

pub fn syncFile(io: std.Io, file: fs.File, observer: Observer) Outcome(void) {
    observer.observe(.{ .operation = .sync_file, .edge = .before }) catch |err| return stopped(void, err);
    ioFile(file).sync(io) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .sync_file);
}

pub fn syncDirectory(io: std.Io, directory: fs.Directory, observer: Observer) Outcome(void) {
    observer.observe(.{ .operation = .sync_directory, .edge = .before }) catch |err| return stopped(void, err);
    ioDirectoryFile(directory).sync(io) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .sync_directory);
}

pub fn movePreserving(io: std.Io, source_directory: fs.Directory, source_name: []const u8, target_directory: fs.Directory, target_name: []const u8, observer: Observer) Outcome(void) {
    fs.validateChildName(source_name) catch |err| return stopped(void, err);
    fs.validateChildName(target_name) catch |err| return stopped(void, err);
    observer.observe(.{ .operation = .rename_preserve, .edge = .before }) catch |err| return stopped(void, err);
    ioDirectory(source_directory).renamePreserve(source_name, ioDirectory(target_directory), target_name, io) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .rename_preserve);
}

pub fn moveReplacing(io: std.Io, source_directory: fs.Directory, source_name: []const u8, target_directory: fs.Directory, target_name: []const u8, observer: Observer) Outcome(void) {
    fs.validateChildName(source_name) catch |err| return stopped(void, err);
    fs.validateChildName(target_name) catch |err| return stopped(void, err);
    observer.observe(.{ .operation = .rename_replace, .edge = .before }) catch |err| return stopped(void, err);
    ioDirectory(source_directory).rename(source_name, ioDirectory(target_directory), target_name, io) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .rename_replace);
}

pub fn removeFile(io: std.Io, directory: fs.Directory, name: []const u8, observer: Observer) Outcome(void) {
    fs.validateChildName(name) catch |err| return stopped(void, err);
    observer.observe(.{ .operation = .unlink_file, .edge = .before }) catch |err| return stopped(void, err);
    ioDirectory(directory).deleteFile(io, name) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .unlink_file);
}

pub fn removeDirectory(io: std.Io, directory: fs.Directory, name: []const u8, observer: Observer) Outcome(void) {
    fs.validateChildName(name) catch |err| return stopped(void, err);
    observer.observe(.{ .operation = .unlink_directory, .edge = .before }) catch |err| return stopped(void, err);
    ioDirectory(directory).deleteDir(io, name) catch |err| return stopped(void, err);
    return finished(void, {}, observer, .unlink_directory);
}

pub fn acquireRegularFile(parent: fs.Directory, name: []const u8, admission: fs.Admission, permissions: std.Io.File.Permissions, observer: Observer) Outcome(FileAcquisition) {
    if (parent.openRegularFileExisting(name, admission)) |file| {
        return acquiredFile(.existing, file, null);
    } else |err| if (err != error.FileNotFound) return stopped(FileAcquisition, err);
    const created = createFile(parent, name, permissions, observer);
    switch (created) {
        .not_completed => |err| {
            if (err != error.PathAlreadyExists) return stopped(FileAcquisition, err);
            const file = parent.openRegularFileExisting(name, admission) catch |open_err| return stopped(FileAcquisition, open_err);
            return acquiredFile(.existing, file, null);
        },
        .completed => |result| {
            var post_error: ?anyerror = result.after_error;
            if (post_error == null) fs.admitMetadata(result.value.metadata, admission) catch |err| {
                post_error = err;
            };
            return acquiredFile(.created, result.value, post_error);
        },
    }
}

pub fn acquireDirectory(io: std.Io, parent: fs.Directory, name: []const u8, admission: fs.Admission, permissions: std.Io.Dir.Permissions, observer: Observer) Outcome(DirectoryAcquisition) {
    if (openDirectory(parent, name, admission)) |directory| {
        return acquiredDirectory(.existing, directory, null);
    } else |err| if (err != error.FileNotFound) return stopped(DirectoryAcquisition, err);
    const created = createDirectory(io, parent, name, permissions, observer);
    var disposition: AcquisitionDisposition = .created;
    switch (created) {
        .not_completed => |err| if (err == error.PathAlreadyExists) {
            disposition = .existing;
        } else return stopped(DirectoryAcquisition, err),
        .completed => |result| if (result.after_error) |err| return acquiredDirectory(.created, null, err),
    }
    const directory = openDirectory(parent, name, admission) catch |err|
        return acquiredDirectory(disposition, null, err);
    const synced = syncDirectory(io, parent, observer);
    return switch (synced) {
        .not_completed => |err| acquiredDirectory(disposition, directory, err),
        .completed => |result| acquiredDirectory(disposition, directory, result.after_error),
    };
}

fn openDirectory(parent: fs.Directory, name: []const u8, admission: fs.Admission) !fs.Directory {
    var directory = try parent.openDirectory(name);
    errdefer directory.deinit();
    try fs.admitMetadata(directory.metadata, admission);
    return directory;
}
fn ioDirectory(directory: fs.Directory) std.Io.Dir {
    return .{ .handle = directory.descriptor.handle };
}
fn ioDirectoryFile(directory: fs.Directory) std.Io.File {
    return .{ .handle = directory.descriptor.handle, .flags = .{ .nonblocking = true } };
}
fn ioFile(file: fs.File) std.Io.File {
    return .{ .handle = file.descriptor.handle, .flags = .{ .nonblocking = true } };
}
fn writableExclusiveFlags() std.posix.O {
    return .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true };
}
fn stopped(comptime T: type, err: anyerror) Outcome(T) {
    return .{ .not_completed = err };
}
fn observeAfter(observer: Observer, operation: Operation) ?anyerror {
    observer.observe(.{ .operation = operation, .edge = .after }) catch |err| return err;
    return null;
}
fn finished(comptime T: type, value: T, observer: Observer, operation: Operation) Outcome(T) {
    return .{ .completed = .{ .value = value, .after_error = observeAfter(observer, operation) } };
}
fn acquiredFile(disposition: AcquisitionDisposition, file: fs.File, after_error: ?anyerror) Outcome(FileAcquisition) {
    return .{ .completed = .{ .value = .{ .disposition = disposition, .file = file }, .after_error = after_error } };
}
fn acquiredDirectory(disposition: AcquisitionDisposition, directory: ?fs.Directory, after_error: ?anyerror) Outcome(DirectoryAcquisition) {
    return .{ .completed = .{ .value = .{ .disposition = disposition, .directory = directory }, .after_error = after_error } };
}

test "neutral durable filesystem covers every operation before and after edge" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const operations = [_]Operation{
        .create_directory, .create_file,    .write,       .sync_file,        .sync_directory,
        .rename_preserve,  .rename_replace, .unlink_file, .unlink_directory,
    };
    for (operations) |operation| for ([_]Edge{ .before, .after }) |edge| {
        var fixture = try DurableFixture.init(std.testing.io);
        defer fixture.deinit();
        var fault: StepFault = .{ .selected = .{ .operation = operation, .edge = edge } };
        const outcome = fixture.execute(operation, fault.observer());
        try fixture.expectFaultOutcome(operation, edge, outcome);
    };
}

test "neutral durable filesystem acquisition distinguishes existing and created authority" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    var fixture = try DurableFixture.init(io);
    defer fixture.deinit();
    const admission = fixture.fileAdmission();
    var existing_trace: StepTrace = .{};
    var existing = switch (acquireRegularFile(fixture.root, "existing", admission, .fromMode(0o600), existing_trace.observer())) {
        .not_completed => return error.UnexpectedAcquisitionFailure,
        .completed => |result| result,
    };
    defer existing.value.file.deinit();
    try std.testing.expectEqual(AcquisitionDisposition.existing, existing.value.disposition);
    try std.testing.expect(existing.after_error == null);
    try std.testing.expectEqual(@as(usize, 0), existing_trace.total());
    var created_trace: StepTrace = .{};
    var created = switch (acquireRegularFile(fixture.root, "acquired", admission, .fromMode(0o600), created_trace.observer())) {
        .not_completed => return error.UnexpectedAcquisitionFailure,
        .completed => |result| result,
    };
    defer created.value.file.deinit();
    try std.testing.expectEqual(AcquisitionDisposition.created, created.value.disposition);
    try std.testing.expect(created.after_error == null);
    try created_trace.expect(.create_file, 1, 1);
    var existing_directory_trace: StepTrace = .{};
    var existing_directory = switch (acquireDirectory(io, fixture.root, "remove-dir", fixture.directoryAdmission(), .fromMode(0o700), existing_directory_trace.observer())) {
        .not_completed => return error.UnexpectedAcquisitionFailure,
        .completed => |result| result,
    };
    defer if (existing_directory.value.directory) |*value| value.deinit();
    try std.testing.expectEqual(AcquisitionDisposition.existing, existing_directory.value.disposition);
    try std.testing.expectEqual(@as(usize, 0), existing_directory_trace.total());
    var directory_trace: StepTrace = .{};
    var directory = switch (acquireDirectory(io, fixture.root, "acquired-dir", fixture.directoryAdmission(), .fromMode(0o700), directory_trace.observer())) {
        .not_completed => return error.UnexpectedAcquisitionFailure,
        .completed => |result| result,
    };
    defer if (directory.value.directory) |*value| value.deinit();
    try std.testing.expectEqual(AcquisitionDisposition.created, directory.value.disposition);
    try std.testing.expect(directory.value.directory != null and directory.after_error == null);
    try directory_trace.expect(.create_directory, 1, 1);
    try directory_trace.expect(.sync_directory, 1, 1);
}

test "neutral durable filesystem operation errors never report completion" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    const operations = [_]Operation{
        .create_directory, .create_file,    .write,       .sync_file,        .sync_directory,
        .rename_preserve,  .rename_replace, .unlink_file, .unlink_directory,
    };
    for (operations) |operation| {
        var fixture = try DurableFixture.init(std.testing.io);
        defer fixture.deinit();
        var trace: StepTrace = .{};
        switch (fixture.executeOperationError(operation, trace.observer())) {
            .not_completed => {},
            .completed => return error.UnexpectedCompletedOperation,
        }
        try trace.expect(operation, 1, 0);
    }
}

const StepTrace = struct {
    counts: [9][2]usize = [_][2]usize{.{ 0, 0 }} ** 9,

    fn observe(context: ?*anyopaque, step: Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.counts[@intFromEnum(step.operation)][@intFromEnum(step.edge)] += 1;
    }
    fn observer(self: *@This()) Observer {
        return .{ .context = self, .observe_fn = observe };
    }
    fn total(self: @This()) usize {
        var result: usize = 0;
        for (self.counts) |edges| result += edges[0] + edges[1];
        return result;
    }
    fn expect(self: @This(), operation: Operation, before: usize, after: usize) !void {
        try std.testing.expectEqual(before, self.counts[@intFromEnum(operation)][@intFromEnum(Edge.before)]);
        try std.testing.expectEqual(after, self.counts[@intFromEnum(operation)][@intFromEnum(Edge.after)]);
    }
};

const StepFault = struct {
    selected: Step,
    fn observe(context: ?*anyopaque, step: Step) !void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.selected.operation == step.operation and self.selected.edge == step.edge) return error.InjectedStepFault;
    }
    fn observer(self: *@This()) Observer {
        return .{ .context = self, .observe_fn = observe };
    }
};

const DurableFixture = struct {
    tmp: std.testing.TmpDir,
    root: fs.Directory,
    io: std.Io,

    fn init(io: std.Io) !DurableFixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "existing", .data = "old", .flags = .{ .permissions = .fromMode(0o600) } });
        try tmp.dir.writeFile(io, .{ .sub_path = "source", .data = "source", .flags = .{ .permissions = .fromMode(0o600) } });
        try tmp.dir.writeFile(io, .{ .sub_path = "replace-source", .data = "new", .flags = .{ .permissions = .fromMode(0o600) } });
        try tmp.dir.writeFile(io, .{ .sub_path = "replace-target", .data = "old", .flags = .{ .permissions = .fromMode(0o600) } });
        try tmp.dir.writeFile(io, .{ .sub_path = "remove-file", .data = "remove", .flags = .{ .permissions = .fromMode(0o600) } });
        try tmp.dir.createDir(io, "remove-dir", .fromMode(0o700));
        return .{ .tmp = tmp, .root = try testDirectory(tmp.dir), .io = io };
    }
    fn deinit(self: *@This()) void {
        self.root.deinit();
        self.tmp.cleanup();
        self.* = undefined;
    }
    fn directoryAdmission(self: *@This()) fs.Admission {
        return .{ .expected = .directory, .device = self.root.metadata.device, .uid = self.root.metadata.uid, .mode = 0o700, .require_single_link = false };
    }
    fn fileAdmission(self: *@This()) fs.Admission {
        return .{ .expected = .regular_file, .device = self.root.metadata.device, .uid = self.root.metadata.uid, .mode = 0o600, .require_single_link = true };
    }
    fn execute(self: *@This(), operation: Operation, observer: Observer) Outcome(void) {
        return switch (operation) {
            .create_directory => erase(createDirectory(self.io, self.root, "created-dir", .fromMode(0o700), observer)),
            .create_file => blk: {
                const outcome = createFile(self.root, "created-file", .fromMode(0o600), observer);
                break :blk switch (outcome) {
                    .not_completed => |err| .{ .not_completed = err },
                    .completed => |result| done: {
                        var file = result.value;
                        file.deinit();
                        break :done .{ .completed = .{ .value = {}, .after_error = result.after_error } };
                    },
                };
            },
            .write => blk: {
                const created = createFile(self.root, "write-target", .fromMode(0o600), .{});
                var file = switch (created) {
                    .not_completed => |err| break :blk .{ .not_completed = err },
                    .completed => |result| result.value,
                };
                defer file.deinit();
                break :blk writeAll(self.io, file, "new", observer);
            },
            .sync_file => withFile(self, "existing", observer, syncFile, {}),
            .sync_directory => syncDirectory(self.io, self.root, observer),
            .rename_preserve => movePreserving(self.io, self.root, "source", self.root, "preserved", observer),
            .rename_replace => moveReplacing(self.io, self.root, "replace-source", self.root, "replace-target", observer),
            .unlink_file => removeFile(self.io, self.root, "remove-file", observer),
            .unlink_directory => removeDirectory(self.io, self.root, "remove-dir", observer),
        };
    }
    fn executeOperationError(self: *@This(), operation: Operation, observer: Observer) Outcome(void) {
        return switch (operation) {
            .create_directory => erase(createDirectory(self.io, self.root, "remove-dir", .fromMode(0o700), observer)),
            .create_file => blk: {
                const outcome = createFile(self.root, "existing", .fromMode(0o600), observer);
                break :blk switch (outcome) {
                    .not_completed => |err| .{ .not_completed = err },
                    .completed => |result| done: {
                        var file = result.value;
                        file.deinit();
                        break :done .{ .completed = .{ .value = {}, .after_error = result.after_error } };
                    },
                };
            },
            .write => withFile(self, "existing", observer, writeAll, "blocked"),
            .sync_file => blk: {
                var file = self.root.openRegularFileExisting("existing", self.fileAdmission()) catch |err| break :blk .{ .not_completed = err };
                defer file.deinit();
                var vtable = self.io.vtable.*;
                vtable.fileSync = failFileSync;
                break :blk syncFile(.{ .userdata = self.io.userdata, .vtable = &vtable }, file, observer);
            },
            .sync_directory => blk: {
                var vtable = self.io.vtable.*;
                vtable.fileSync = failFileSync;
                break :blk syncDirectory(.{ .userdata = self.io.userdata, .vtable = &vtable }, self.root, observer);
            },
            .rename_preserve => movePreserving(self.io, self.root, "source", self.root, "existing", observer),
            .rename_replace => moveReplacing(self.io, self.root, "missing", self.root, "existing", observer),
            .unlink_file => removeFile(self.io, self.root, "missing", observer),
            .unlink_directory => removeDirectory(self.io, self.root, "missing-dir", observer),
        };
    }
    fn expectFaultOutcome(self: *@This(), operation: Operation, edge: Edge, outcome: Outcome(void)) !void {
        switch (outcome) {
            .not_completed => |err| {
                try std.testing.expectEqual(error.InjectedStepFault, err);
                try std.testing.expectEqual(Edge.before, edge);
            },
            .completed => |result| {
                try std.testing.expectEqual(Edge.after, edge);
                try std.testing.expectEqual(error.InjectedStepFault, result.after_error.?);
            },
        }
        const affected = switch (operation) {
            .create_directory => "created-dir",
            .create_file => "created-file",
            .rename_preserve => "source",
            .rename_replace => "replace-source",
            .unlink_file => "remove-file",
            .unlink_directory => "remove-dir",
            else => return,
        };
        const exists = exists: {
            self.tmp.dir.access(self.io, affected, .{}) catch break :exists false;
            break :exists true;
        };
        const expected = switch (operation) {
            .rename_preserve, .rename_replace, .unlink_file, .unlink_directory => edge == .before,
            else => edge == .after,
        };
        try std.testing.expectEqual(expected, exists);
    }
};

fn failFileSync(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
    return error.InputOutput;
}

fn erase(outcome: Outcome([]const u8)) Outcome(void) {
    return switch (outcome) {
        .not_completed => |err| .{ .not_completed = err },
        .completed => |result| .{ .completed = .{ .value = {}, .after_error = result.after_error } },
    };
}
fn withFile(fixture: *DurableFixture, name: []const u8, observer: Observer, comptime operation: anytype, extra: anytype) Outcome(void) {
    var file = fixture.root.openRegularFileExisting(name, fixture.fileAdmission()) catch |err| return .{ .not_completed = err };
    defer file.deinit();
    return if (@TypeOf(extra) == void)
        operation(fixture.io, file, observer)
    else
        operation(fixture.io, file, extra, observer);
}
fn testDirectory(dir: std.Io.Dir) !fs.Directory {
    const handle = try std.posix.openat(dir.handle, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true }, 0);
    errdefer _ = std.posix.system.close(handle);
    return .{ .descriptor = .{ .handle = handle }, .metadata = try fs.metadataForHandle(.{ .handle = handle }) };
}
