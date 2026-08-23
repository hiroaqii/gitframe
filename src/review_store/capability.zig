//! Review Store policy facade over neutral descriptor capability mechanics.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("../fs/capability.zig");
const durable = @import("../fs/durable.zig");
const store_path = @import("path.zig");

pub const ObjectKind = fs.ObjectKind;
pub const Metadata = fs.Metadata;
pub const ExpectedKind = fs.ExpectedKind;
pub const PolicyError = fs.AdmissionError;
pub const DirectoryAcquisition = struct { disposition: durable.AcquisitionDisposition, directory: ?DirectoryCapability };

pub const Iterator = struct {
    neutral: fs.Iterator = .{},

    pub fn next(self: *Iterator, directory: DirectoryCapability, io: std.Io) std.Io.Dir.Iterator.Error!?std.Io.Dir.Entry {
        return self.neutral.next(directory.neutral, io);
    }
};

/// Review Store policy seam. Directory link counts intentionally never participate.
pub fn admitMetadata(metadata: Metadata, expected: ExpectedKind, root_device: u64, effective_uid: u32) PolicyError!void {
    try fs.admitMetadata(metadata, storeAdmission(expected, root_device, effective_uid));
}

pub const FilesystemPolicy = enum {
    local_supported,
    unsupported,

    pub fn fromLinuxMagic(magic: u64) FilesystemPolicy {
        return switch (magic) {
            0x0000ef53, 0x58465342, 0x9123683e, 0xf2f52010, 0x2fc12fc1, 0x01021994, 0x858458f6, 0x794c7630 => .local_supported,
            else => .unsupported,
        };
    }

    fn fromMetadata(metadata: fs.FilesystemMetadata) FilesystemPolicy {
        return switch (metadata) {
            .linux => |value| if (value.magic < 0) .unsupported else fromLinuxMagic(@intCast(value.magic)),
            .darwin => |value| blk: {
                const read_only: u32 = 0x00000001;
                const local: u32 = 0x00001000;
                if ((value.flags & local) == 0 or (value.flags & read_only) != 0) break :blk .unsupported;
                const name = std.mem.sliceTo(&value.type_name, 0);
                if (std.ascii.eqlIgnoreCase(name, "fusefs") or std.ascii.eqlIgnoreCase(name, "osxfuse") or
                    std.ascii.eqlIgnoreCase(name, "macfuse")) break :blk .unsupported;
                break :blk .local_supported;
            },
        };
    }
};

pub const DirectoryCapability = struct {
    neutral: fs.Directory,
    metadata: Metadata,
    effective_uid: u32,
    root_device: u64,

    pub fn duplicate(self: DirectoryCapability) !DirectoryCapability {
        return self.wrap(try self.neutral.duplicate());
    }

    pub fn deinit(self: *DirectoryCapability) void {
        self.neutral.deinit();
        self.* = undefined;
    }

    pub fn openDirectory(self: DirectoryCapability, name: []const u8) !DirectoryCapability {
        var neutral = try self.neutral.openDirectory(name);
        errdefer neutral.deinit();
        try fs.admitMetadata(neutral.metadata, self.admission(.directory));
        return self.wrap(neutral);
    }

    pub fn admitChild(self: DirectoryCapability, name: []const u8, expected: ExpectedKind) !Metadata {
        return self.neutral.admitChild(name, self.admission(expected));
    }

    pub fn iterate(_: DirectoryCapability) Iterator {
        return .{};
    }

    pub fn readRegularAlloc(self: DirectoryCapability, allocator: std.mem.Allocator, io: std.Io, name: []const u8, maximum: usize) ![]u8 {
        return self.neutral.readRegularAlloc(allocator, io, name, self.admission(.regular_file), maximum);
    }

    fn admission(self: DirectoryCapability, expected: ExpectedKind) fs.Admission {
        return storeAdmission(expected, self.root_device, self.effective_uid);
    }

    fn wrap(self: DirectoryCapability, neutral: fs.Directory) DirectoryCapability {
        return .{ .neutral = neutral, .metadata = neutral.metadata, .effective_uid = self.effective_uid, .root_device = self.root_device };
    }
};

pub fn acquireDirectory(io: std.Io, parent: DirectoryCapability, name: []const u8, observer: durable.Observer) durable.Outcome(DirectoryAcquisition) {
    return switch (durable.acquireDirectory(io, parent.neutral, name, parent.admission(.directory), .fromMode(0o700), observer)) {
        .not_completed => |err| .{ .not_completed = err },
        .completed => |result| .{ .completed = .{
            .value = .{
                .disposition = result.value.disposition,
                .directory = if (result.value.directory) |neutral| parent.wrap(neutral) else null,
            },
            .after_error = result.after_error,
        } },
    };
}

pub fn acquireRegularFile(parent: DirectoryCapability, name: []const u8, observer: durable.Observer) durable.Outcome(durable.FileAcquisition) {
    return durable.acquireRegularFile(parent.neutral, name, parent.admission(.regular_file), .fromMode(0o600), observer);
}

pub fn createDirectory(io: std.Io, parent: DirectoryCapability, name: []const u8, observer: durable.Observer) durable.Outcome([]const u8) {
    return durable.createDirectory(io, parent.neutral, name, .fromMode(0o700), observer);
}

pub fn createFile(parent: DirectoryCapability, name: []const u8, observer: durable.Observer) durable.Outcome(fs.File) {
    return durable.createFile(parent.neutral, name, .fromMode(0o600), observer);
}

pub fn syncDirectory(io: std.Io, directory: DirectoryCapability, observer: durable.Observer) durable.Outcome(void) {
    return durable.syncDirectory(io, directory.neutral, observer);
}

pub fn movePreserving(io: std.Io, source: DirectoryCapability, source_name: []const u8, target: DirectoryCapability, target_name: []const u8, observer: durable.Observer) durable.Outcome(void) {
    return durable.movePreserving(io, source.neutral, source_name, target.neutral, target_name, observer);
}

pub fn moveReplacing(io: std.Io, source: DirectoryCapability, source_name: []const u8, target: DirectoryCapability, target_name: []const u8, observer: durable.Observer) durable.Outcome(void) {
    return durable.moveReplacing(io, source.neutral, source_name, target.neutral, target_name, observer);
}

pub fn removeFile(io: std.Io, directory: DirectoryCapability, name: []const u8, observer: durable.Observer) durable.Outcome(void) {
    return durable.removeFile(io, directory.neutral, name, observer);
}

pub fn removeDirectory(io: std.Io, directory: DirectoryCapability, name: []const u8, observer: durable.Observer) durable.Outcome(void) {
    return durable.removeDirectory(io, directory.neutral, name, observer);
}

pub const StoreRootCapability = struct {
    directory: DirectoryCapability,
    filesystem: FilesystemPolicy,

    pub fn openCanonical(path: []const u8) !StoreRootCapability {
        return openCanonicalPath(null, path);
    }

    /// Component-wise no-follow create walk used only by explicit prepare.
    pub fn openOrCreateCanonical(io: std.Io, path: []const u8) !StoreRootCapability {
        return openCanonicalPath(io, path);
    }

    pub fn deinit(self: *StoreRootCapability) void {
        self.directory.deinit();
        self.* = undefined;
    }
};

fn openCanonicalPath(io: ?std.Io, path: []const u8) !StoreRootCapability {
    try store_path.validateAbsoluteCanonical(path);
    var current = try fs.openAbsoluteRoot();
    errdefer current.deinit();
    var components = std.mem.splitScalar(u8, path[1..], '/');
    while (components.next()) |component| {
        const child = current.openDirectory(component) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const create_io = io orelse return err;
                switch (durable.createDirectory(create_io, current, component, .fromMode(0o700), .{})) {
                    .not_completed => |create_err| if (create_err != error.PathAlreadyExists) return create_err,
                    .completed => |result| if (result.after_error) |after_err| return after_err,
                }
                try completedVoid(durable.syncDirectory(create_io, current, .{}));
                break :blk try current.openDirectory(component);
            },
            else => return err,
        };
        current.deinit();
        current = child;
    }
    const uid = effectiveUid();
    try fs.admitMetadata(current.metadata, storeAdmission(.directory, current.metadata.device, uid));
    const filesystem = FilesystemPolicy.fromMetadata(try fs.filesystemMetadata(current));
    if (filesystem != .local_supported) return error.UnsupportedFilesystem;
    return .{ .directory = .{ .neutral = current, .metadata = current.metadata, .effective_uid = uid, .root_device = current.metadata.device }, .filesystem = filesystem };
}

fn storeAdmission(expected: ExpectedKind, device: u64, uid: u32) fs.Admission {
    return .{ .expected = expected, .device = device, .uid = uid, .mode = if (expected == .directory) 0o700 else 0o600, .require_single_link = expected == .regular_file };
}

fn effectiveUid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.geteuid()),
        .macos => @intCast(std.c.geteuid()),
        else => 0,
    };
}

fn completedVoid(outcome: durable.Outcome(void)) !void {
    switch (outcome) {
        .not_completed => |err| return err,
        .completed => |result| if (result.after_error) |err| return err,
    }
}

test "neutral filesystem capability keeps Review Store policy in its facade" {
    const base: Metadata = .{ .kind = .directory, .device = 7, .inode = 9, .uid = 1000, .mode = 0o700, .link_count = 1, .size = 0 };
    for ([_]u64{ 1, 2, 99 }) |links| {
        var directory = base;
        directory.link_count = links;
        try admitMetadata(directory, .directory, 7, 1000);
    }
    var file = base;
    file.kind = .regular_file;
    file.mode = 0o600;
    file.link_count = 1;
    try admitMetadata(file, .regular_file, 7, 1000);
    file.link_count = 2;
    try std.testing.expectError(error.MultipleLinks, admitMetadata(file, .regular_file, 7, 1000));
}

test "neutral filesystem capability keeps filesystem allowlist in Review Store" {
    try std.testing.expectEqual(FilesystemPolicy.local_supported, FilesystemPolicy.fromLinuxMagic(0x0000ef53));
    try std.testing.expectEqual(FilesystemPolicy.local_supported, FilesystemPolicy.fromLinuxMagic(0x01021994));
    try std.testing.expectEqual(FilesystemPolicy.local_supported, FilesystemPolicy.fromLinuxMagic(0x794c7630));
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0x6969));
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0xff534d42));
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0x65735546));
    try std.testing.expectEqual(FilesystemPolicy.unsupported, FilesystemPolicy.fromLinuxMagic(0x12345678));
}

test "neutral filesystem capability reopens private nested Store layout" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "store", .fromMode(0o700));
    var store_dir = try tmp.dir.openDir(io, "store", .{});
    defer store_dir.close(io);
    try store_dir.createDir(io, "123e4567-e89b-42d3-a456-426614174000", .fromMode(0o700));
    var namespace = try store_dir.openDir(io, "123e4567-e89b-42d3-a456-426614174000", .{});
    defer namespace.close(io);
    try namespace.writeFile(io, .{ .sub_path = "registry.json", .data = "x", .flags = .{ .permissions = .fromMode(0o600) } });
    const root_path = try tmp.dir.realPathFileAlloc(io, "store", allocator);
    defer allocator.free(root_path);
    var root = try StoreRootCapability.openCanonical(root_path);
    defer root.deinit();
    var child = try root.directory.openDirectory("123e4567-e89b-42d3-a456-426614174000");
    defer child.deinit();
    try std.testing.expectEqual(ObjectKind.regular_file, (try child.admitChild("registry.json", .regular_file)).kind);
}

test "neutral filesystem capability keeps canonical Store descriptor pinned across path replacement" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "root-slot", .fromMode(0o700));
    try tmp.dir.createDir(io, "root-replacement", .fromMode(0o700));
    {
        var accepted = try tmp.dir.openDir(io, "root-slot", .{});
        defer accepted.close(io);
        try accepted.writeFile(io, .{ .sub_path = "marker", .data = "accepted-root", .flags = .{ .permissions = .fromMode(0o600) } });
        var replacement = try tmp.dir.openDir(io, "root-replacement", .{});
        defer replacement.close(io);
        try replacement.writeFile(io, .{ .sub_path = "marker", .data = "replacement-root", .flags = .{ .permissions = .fromMode(0o600) } });
    }
    const root_path = try tmp.dir.realPathFileAlloc(io, "root-slot", allocator);
    defer allocator.free(root_path);
    var root = try StoreRootCapability.openCanonical(root_path);
    defer root.deinit();
    try tmp.dir.rename("root-slot", tmp.dir, "old-root-slot", io);
    try tmp.dir.rename("root-replacement", tmp.dir, "root-slot", io);
    const root_marker = try root.directory.readRegularAlloc(allocator, io, "marker", 64);
    defer allocator.free(root_marker);
    try std.testing.expectEqualStrings("accepted-root", root_marker);

    try tmp.dir.createDir(io, "ancestor", .fromMode(0o700));
    try tmp.dir.createDir(io, "ancestor-replacement", .fromMode(0o700));
    {
        var accepted_parent = try tmp.dir.openDir(io, "ancestor", .{});
        defer accepted_parent.close(io);
        try accepted_parent.createDir(io, "store", .fromMode(0o700));
        var accepted = try accepted_parent.openDir(io, "store", .{});
        defer accepted.close(io);
        try accepted.writeFile(io, .{ .sub_path = "marker", .data = "accepted-ancestor", .flags = .{ .permissions = .fromMode(0o600) } });
        var replacement_parent = try tmp.dir.openDir(io, "ancestor-replacement", .{});
        defer replacement_parent.close(io);
        try replacement_parent.createDir(io, "store", .fromMode(0o700));
        var replacement = try replacement_parent.openDir(io, "store", .{});
        defer replacement.close(io);
        try replacement.writeFile(io, .{ .sub_path = "marker", .data = "replacement-ancestor", .flags = .{ .permissions = .fromMode(0o600) } });
    }
    const ancestor_path = try tmp.dir.realPathFileAlloc(io, "ancestor/store", allocator);
    defer allocator.free(ancestor_path);
    var ancestor = try StoreRootCapability.openCanonical(ancestor_path);
    defer ancestor.deinit();
    try tmp.dir.rename("ancestor", tmp.dir, "old-ancestor", io);
    try tmp.dir.rename("ancestor-replacement", tmp.dir, "ancestor", io);
    const ancestor_marker = try ancestor.directory.readRegularAlloc(allocator, io, "marker", 64);
    defer allocator.free(ancestor_marker);
    try std.testing.expectEqualStrings("accepted-ancestor", ancestor_marker);
}

test "neutral filesystem ownership proof final closes permitted Store consumers and preserves repository cwd" {
    try expectTypedFinalSurfaces();
    try expectClosedProductionConsumers(std.testing.allocator, std.testing.io);
    try expectRepositoryCwdAuthority(std.testing.allocator, std.testing.io);
    try expectProductionLineCeilings(std.testing.allocator, std.testing.io);
}

const direct_consumers = [_][]const u8{
    "src/review_store/capability.zig",
    "src/review_store.zig",
    "src/review_store/history.zig",
    "src/review_store/registry.zig",
    "src/review_store/run.zig",
    "src/review_store/publication.zig",
    "src/review_store/mutation.zig",
};

fn expectTypedFinalSurfaces() !void {
    const neutral_fields = @typeInfo(fs.Directory).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 2), neutral_fields.len);
    try std.testing.expectEqualStrings("descriptor", neutral_fields[0].name);
    try std.testing.expect(neutral_fields[0].type == fs.Descriptor);
    try std.testing.expectEqualStrings("metadata", neutral_fields[1].name);
    try std.testing.expect(neutral_fields[1].type == fs.Metadata);
    inline for (neutral_fields) |field| {
        try std.testing.expect(field.type != std.posix.fd_t);
        try std.testing.expect(field.type != std.Io.Dir);
        try std.testing.expect(field.type != std.Io.File);
    }
    const neutral_operations = [_][]const u8{
        "duplicate", "deinit", "openDirectory", "openRegularFileExisting", "admitChild", "readRegularAlloc", "iterate",
    };
    inline for (@typeInfo(fs.Directory).@"struct".decls) |decl| {
        try std.testing.expect(nameIn(decl.name, &neutral_operations));
    }
    const iterator_return = @typeInfo(@TypeOf(fs.Directory.iterate)).@"fn".return_type.?;
    try std.testing.expect(iterator_return == fs.Iterator);
    const iterator_fields = @typeInfo(iterator_return).@"struct".fields;
    try std.testing.expectEqual(@as(usize, 4), iterator_fields.len);
    try std.testing.expectEqualStrings("state", iterator_fields[0].name);
    try std.testing.expect(iterator_fields[0].type == std.Io.Dir.Reader.State);
    try std.testing.expectEqualStrings("buffer", iterator_fields[1].name);
    try std.testing.expect(iterator_fields[1].type == [std.Io.Dir.Iterator.reader_buffer_len]u8);
    try std.testing.expectEqualStrings("index", iterator_fields[2].name);
    try std.testing.expect(iterator_fields[2].type == usize);
    try std.testing.expectEqualStrings("end", iterator_fields[3].name);
    try std.testing.expect(iterator_fields[3].type == usize);
    inline for (iterator_fields) |field| {
        try std.testing.expect(field.type != fs.Descriptor);
        try std.testing.expect(field.type != fs.Directory);
        try std.testing.expect(field.type != std.posix.fd_t);
        try std.testing.expect(field.type != std.Io.Dir);
        try std.testing.expect(field.type != std.Io.File);
    }
    try std.testing.expect(!@hasField(fs.Iterator, "reader"));
    try std.testing.expect(!@hasField(fs.Iterator, "directory"));
    inline for (@typeInfo(fs.Iterator).@"struct".decls) |decl| try std.testing.expectEqualStrings("next", decl.name);
    const iterator_next = @typeInfo(@TypeOf(fs.Iterator.next)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), iterator_next.params.len);
    try std.testing.expect(iterator_next.params[0].type.? == *fs.Iterator);
    try std.testing.expect(iterator_next.params[1].type.? == fs.Directory);
    try std.testing.expect(iterator_next.params[2].type.? == std.Io);
    try std.testing.expect(iterator_next.return_type.? == std.Io.Dir.Iterator.Error!?std.Io.Dir.Entry);
    inline for (.{
        "dir",            "rawHandle",     "createDirectory", "createFile",      "writeAll",         "syncFile",           "syncDirectory",
        "movePreserving", "moveReplacing", "removeFile",      "removeDirectory", "acquireDirectory", "acquireRegularFile",
    }) |name| try std.testing.expect(!@hasDecl(fs.Directory, name));

    const facade_fields = @typeInfo(DirectoryCapability).@"struct".fields;
    var neutral_fields_found: usize = 0;
    inline for (facade_fields) |field| {
        if (field.type == fs.Directory) neutral_fields_found += 1;
        try std.testing.expect(field.type != std.posix.fd_t);
        try std.testing.expect(field.type != std.Io.Dir);
        try std.testing.expect(field.type != std.Io.File);
    }
    try std.testing.expectEqual(@as(usize, 1), neutral_fields_found);
    const facade_operations = [_][]const u8{ "duplicate", "deinit", "openDirectory", "admitChild", "iterate", "readRegularAlloc" };
    inline for (@typeInfo(DirectoryCapability).@"struct".decls) |decl| try std.testing.expect(nameIn(decl.name, &facade_operations));
    inline for (.{ "dir", "rawHandle", "getOrCreateDirectory", "openOrCreateRegularFile", "createRegularFileExclusive", "sync" }) |name|
        try std.testing.expect(!@hasDecl(DirectoryCapability, name));
    const facade_iterator = @typeInfo(@TypeOf(DirectoryCapability.iterate)).@"fn".return_type.?;
    try std.testing.expect(facade_iterator == Iterator);
    try std.testing.expectEqual(@as(usize, 1), @typeInfo(Iterator).@"struct".fields.len);
    try std.testing.expect(@FieldType(Iterator, "neutral") == fs.Iterator);
    const facade_next = @typeInfo(@TypeOf(Iterator.next)).@"fn";
    try std.testing.expect(facade_next.params[0].type.? == *Iterator);
    try std.testing.expect(facade_next.params[1].type.? == DirectoryCapability);
    try std.testing.expect(facade_next.params[2].type.? == std.Io);

    const durable_declarations = [_][]const u8{
        "Operation",       "Edge",                   "Step",                 "Observer",
        "Outcome",         "AcquisitionDisposition", "DirectoryAcquisition", "FileAcquisition",
        "createDirectory", "createFile",             "writeAll",             "syncFile",
        "syncDirectory",   "movePreserving",         "moveReplacing",        "removeFile",
        "removeDirectory", "acquireDirectory",       "acquireRegularFile",
    };
    inline for (@typeInfo(durable).@"struct".decls) |decl| try std.testing.expect(nameIn(decl.name, &durable_declarations));
    inline for (durable_declarations) |name| try std.testing.expect(@hasDecl(durable, name));
    const operation_names = [_][]const u8{
        "create_directory", "create_file",    "write",       "sync_file",        "sync_directory",
        "rename_preserve",  "rename_replace", "unlink_file", "unlink_directory",
    };
    inline for (@typeInfo(durable.Operation).@"enum".fields, operation_names) |field, expected|
        try std.testing.expectEqualStrings(expected, field.name);
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(durable.Edge).@"enum".fields.len);
    try std.testing.expect(@FieldType(durable.Step, "operation") == durable.Operation);
    try std.testing.expect(@FieldType(durable.Step, "edge") == durable.Edge);
    const outcome_fields = @typeInfo(durable.Outcome(void)).@"union".fields;
    try std.testing.expectEqual(@as(usize, 2), outcome_fields.len);
    try std.testing.expectEqualStrings("not_completed", outcome_fields[0].name);
    try std.testing.expectEqualStrings("completed", outcome_fields[1].name);
    try std.testing.expect(hasDirectCapabilityMarker("src/unexpected.zig", "const capability = @import(\"review_store/capability.zig\");"));
    try std.testing.expect(hasForbiddenStoreAccess("const handle = store.neutral.descriptor.handle;", false));
    try std.testing.expect(hasForbiddenStoreAccess("const descriptor = @field(store, \"neutral\");", false));
    try std.testing.expect(hasForbiddenStoreAccess("const dir = store.iterate().reader.dir;", false));
}

fn expectClosedProductionConsumers(allocator: std.mem.Allocator, io: std.Io) !void {
    try expectTestManifestReachability(allocator, io);
    var src = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(allocator);
    defer walker.deinit();
    var seen = [_]bool{false} ** direct_consumers.len;
    while (try walker.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        if (entry.kind != .file) return ownershipFailure("non-regular-source", path);
        const source = try entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(source);
        if (std.mem.endsWith(u8, path, "_test.zig") or std.mem.eql(u8, path, "src/app/test_manifest.zig")) continue;
        const prefix = productionPrefix(source);
        if (std.mem.indexOf(u8, prefix, "_test.zig\")") != null) return ownershipFailure("production-imports-test", path);
        const marker = hasDirectCapabilityMarker(path, prefix);
        if (consumerIndex(path)) |index| {
            if (!marker or seen[index]) return ownershipFailure("missing-or-duplicate-consumer", path);
            seen[index] = true;
        } else if (marker) return ownershipFailure("unknown-consumer", path);

        const imports_neutral = std.mem.indexOf(u8, prefix, "fs/capability.zig\")") != null;
        if (imports_neutral and !std.mem.eql(u8, path, direct_consumers[0])) return ownershipFailure("unknown-neutral-importer", path);
        const imports_durable = std.mem.indexOf(u8, prefix, "fs/durable.zig\")") != null;
        if (imports_durable != durableOwner(path)) return ownershipFailure("durable-import-owner-mismatch", path);
        const facade_only = std.mem.indexOf(u8, prefix, "review_store.zig\")") != null and consumerIndex(path) == null;
        if (facade_only and (imports_neutral or std.mem.indexOf(u8, prefix, "StoreRootCapability") != null or
            std.mem.indexOf(u8, prefix, "DirectoryCapability") != null or imports_durable or
            std.mem.indexOf(u8, prefix, ".neutral") != null or std.mem.indexOf(u8, prefix, ".descriptor") != null or
            std.mem.indexOf(u8, prefix, "durable.") != null))
        {
            return ownershipFailure("facade-importer-owns-capability", path);
        }
        if (consumerIndex(path) != null) {
            const facade_owner = std.mem.eql(u8, path, direct_consumers[0]);
            if (hasForbiddenStoreAccess(prefix, facade_owner)) return ownershipFailure("forbidden-store-access", path);
            if (std.mem.count(u8, prefix, ".dir()") != expectedRepositoryDirCount(path))
                return ownershipFailure("repository-cwd-conversion-count", path);
        }
        if (std.mem.eql(u8, path, "src/fs/capability.zig")) try expectNeutralProductionPrefix(prefix);
        if (std.mem.eql(u8, path, "src/fs/durable.zig")) try expectDurableProductionPrefix(prefix);
    }
    for (seen, direct_consumers) |found, path| if (!found) return ownershipFailure("missing-consumer", path);
}

fn expectTestManifestReachability(allocator: std.mem.Allocator, io: std.Io) !void {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, "src/root.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(source);
    const marker = "@import(\"app/test_manifest.zig\").include()";
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, marker));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, productionPrefix(source), marker));
}

fn expectRepositoryCwdAuthority(allocator: std.mem.Allocator, io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    const root_source = try cwd.readFileAlloc(io, "src/repo/root_capability.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(root_source);
    const command_source = try cwd.readFileAlloc(io, "src/git/command.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(command_source);
    const history_source = try cwd.readFileAlloc(io, "src/review_store/history.zig", allocator, .limited(1024 * 1024));
    defer allocator.free(history_source);
    const publication_source = try cwd.readFileAlloc(io, "src/review_store/publication.zig", allocator, .limited(2 * 1024 * 1024));
    defer allocator.free(publication_source);
    try expectSha256(root_source, "12345c2d0a64f4ede6a0029fe3fb53557822df23597629ddf54190372b7eb833");
    try expectSha256(command_source, "76451e54c554eca93f053490c58b1396c8647629fc51ac17c9e5b2cb9f1219f0");
    try std.testing.expect(@FieldType(@import("history.zig").RepositoryContext, "capability") == *const @import("../repo/root_capability.zig").RootCapability);
    try std.testing.expect(@FieldType(@import("../git/command.zig").DirectoryContext, "cwd") == std.Io.Dir);
    try std.testing.expect(@typeInfo(@TypeOf(@import("../repo/root_capability.zig").RootCapability.dir)).@"fn".return_type.? == std.Io.Dir);
    const history = productionPrefix(history_source);
    const publication = productionPrefix(publication_source);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, history, ".cwd = self.capability.dir()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, publication, ".cwd = self.root.dir()"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, publication, ".cwd = root.dir()"));
    std.debug.print("ownership-proof cwd conversions: history=1 publication-context=1 publication-discovery=1\n", .{});
}

fn expectProductionLineCeilings(allocator: std.mem.Allocator, io: std.Io) !void {
    const core_paths = [_][]const u8{
        "src/fs/capability.zig",            "src/fs/durable.zig",            "src/review_store/capability.zig",
        "src/review_store/publication.zig", "src/review_store/mutation.zig",
    };
    const supporting_paths = [_][]const u8{
        "src/review_store/history.zig", "src/review_store/registry.zig",
        "src/review_store/run.zig",     "src/review_store.zig",
    };
    var core: usize = 0;
    for (core_paths) |path| core += try productionLineCount(allocator, io, path);
    var complete = core;
    for (supporting_paths) |path| complete += try productionLineCount(allocator, io, path);
    std.debug.print("ownership-proof production-prefix LOC: core={d}/1841 complete={d}/3066\n", .{ core, complete });
    try std.testing.expect(core <= 1841);
    try std.testing.expect(complete <= 3066);
}

fn productionLineCount(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !usize {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    defer allocator.free(source);
    const prefix = productionPrefix(source);
    return std.mem.count(u8, prefix, "\n") + @intFromBool(prefix.len != 0 and prefix[prefix.len - 1] != '\n');
}

fn hasDirectCapabilityMarker(path: []const u8, source: []const u8) bool {
    if (std.mem.eql(u8, path, "src/review_store/capability.zig")) return std.mem.indexOf(u8, source, "../fs/capability.zig") != null;
    if (std.mem.eql(u8, path, "src/review_store.zig")) return std.mem.indexOf(u8, source, "review_store/capability.zig") != null;
    return (std.mem.startsWith(u8, path, "src/review_store/") and std.mem.indexOf(u8, source, "@import(\"capability.zig\")") != null) or
        std.mem.indexOf(u8, source, "review_store/capability.zig\")") != null or
        std.mem.indexOf(u8, source, "StoreRootCapability") != null or std.mem.indexOf(u8, source, "DirectoryCapability") != null;
}

fn hasForbiddenStoreAccess(source: []const u8, allow_facade_neutral: bool) bool {
    if (!allow_facade_neutral and std.mem.indexOf(u8, source, ".neutral") != null) return true;
    inline for (.{
        ".descriptor",          ".handle",                 ".reader.dir",                "@field(",
        "std.posix.openat",     "createDir(",              "writeStreamingAll(",         ".sync(",
        ".rename(",             ".renamePreserve(",        ".deleteFile(",               ".deleteDir(",
        ".CREAT =",             ".TRUNC =",                ".EXCL =",                    ".RDWR",
        "getOrCreateDirectory", "openOrCreateRegularFile", "createRegularFileExclusive",
    }) |marker| {
        if (std.mem.indexOf(u8, source, marker) != null) return true;
    }
    return false;
}

fn durableOwner(path: []const u8) bool {
    return std.mem.eql(u8, path, "src/review_store/capability.zig") or
        std.mem.eql(u8, path, "src/review_store/publication.zig") or
        std.mem.eql(u8, path, "src/review_store/mutation.zig");
}

fn expectedRepositoryDirCount(path: []const u8) usize {
    if (std.mem.eql(u8, path, "src/review_store/history.zig")) return 1;
    if (std.mem.eql(u8, path, "src/review_store/publication.zig")) return 2;
    return 0;
}

fn expectNeutralProductionPrefix(source: []const u8) !void {
    inline for (.{
        "review_store", "ai_review", "committed_review", "../repo",      "createDir(",  "writeStreamingAll(",
        ".sync(",       ".rename(",  ".renamePreserve(", ".deleteFile(", ".deleteDir(", ".CREAT =",
        ".TRUNC =",     ".EXCL =",
    }) |marker| if (std.mem.indexOf(u8, source, marker) != null) return ownershipFailure("neutral-capability-forbidden-marker", marker);
}

fn expectDurableProductionPrefix(source: []const u8) !void {
    inline for (.{ "review_store", "ai_review", "committed_review", "../repo", "transaction", "journal", "recovery" }) |marker|
        if (std.mem.indexOf(u8, source, marker) != null) return ownershipFailure("neutral-durable-forbidden-marker", marker);
    inline for (.{ "std.posix.openat", "writeStreamingAll(", ".sync(", ".rename(", ".renamePreserve(", ".deleteFile(", ".deleteDir(" }) |marker|
        if (std.mem.count(u8, source, marker) == 0) return ownershipFailure("neutral-durable-missing-operation", marker);
}

fn consumerIndex(path: []const u8) ?usize {
    for (direct_consumers, 0..) |candidate, index| if (std.mem.eql(u8, path, candidate)) return index;
    return null;
}

fn productionPrefix(source: []const u8) []const u8 {
    var start: usize = 0;
    while (start < source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, start, '\n') orelse source.len;
        const line = source[start..end];
        if (std.mem.startsWith(u8, line, "test ") or std.mem.eql(u8, line, "test")) return source[0..start];
        start = if (end == source.len) source.len else end + 1;
    }
    return source;
}

fn nameIn(name: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn expectSha256(source: []const u8, expected: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(expected, &actual);
}

fn ownershipFailure(reason: []const u8, path: []const u8) error{OwnershipProofFailed} {
    std.debug.print("ownership-proof {s}: {s}\npermitted consumers:", .{ reason, path });
    for (direct_consumers) |consumer| std.debug.print(" {s}", .{consumer});
    std.debug.print("\n", .{});
    return error.OwnershipProofFailed;
}
