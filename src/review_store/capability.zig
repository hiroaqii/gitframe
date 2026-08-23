//! Review Store policy facade over neutral descriptor capability mechanics.

const std = @import("std");
const builtin = @import("builtin");
const fs = @import("../fs/capability.zig");
const store_path = @import("path.zig");

pub const ObjectKind = fs.ObjectKind;
pub const Metadata = fs.Metadata;
pub const ExpectedKind = fs.ExpectedKind;
pub const PolicyError = fs.AdmissionError;

/// Review Store policy seam. Directory link counts intentionally never participate.
pub fn admitMetadata(metadata: Metadata, expected: ExpectedKind, root_device: u64, effective_uid: u32) PolicyError!void {
    try fs.admitMetadata(metadata, storeAdmission(expected, root_device, effective_uid));
}

pub const FilesystemPolicy = enum {
    local_supported,
    unsupported,

    pub fn fromLinuxMagic(magic: u64) FilesystemPolicy {
        return switch (magic) {
            0x0000ef53,
            0x58465342,
            0x9123683e,
            0xf2f52010,
            0x2fc12fc1,
            0x01021994,
            0x858458f6,
            0x794c7630,
            => .local_supported,
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

    /// Transitional raw Store mutation/cwd compatibility; removed in slice 2.
    pub fn dir(self: DirectoryCapability) std.Io.Dir {
        return .{ .handle = self.neutral.descriptor.handle };
    }

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

    pub fn getOrCreateDirectory(self: DirectoryCapability, io: std.Io, name: []const u8) !DirectoryCapability {
        return self.openDirectory(name) catch |err| switch (err) {
            error.FileNotFound => {
                self.dir().createDir(io, name, .fromMode(0o700)) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                try self.sync(io);
                return self.openDirectory(name);
            },
            else => return err,
        };
    }

    pub fn openOrCreateRegularFile(self: DirectoryCapability, name: []const u8) !std.Io.File {
        return self.openRegularFile(name, false);
    }

    pub fn createRegularFileExclusive(self: DirectoryCapability, name: []const u8) !std.Io.File {
        return self.openRegularFile(name, true);
    }

    fn openRegularFile(self: DirectoryCapability, name: []const u8, exclusive: bool) !std.Io.File {
        try fs.validateChildName(name);
        const handle = try std.posix.openat(self.neutral.descriptor.handle, name, writableRegularFileFlags(exclusive), 0o600);
        errdefer closeRaw(handle);
        try fs.admitMetadata(try fs.metadataForHandle(.{ .handle = handle }), self.admission(.regular_file));
        return .{ .handle = handle, .flags = .{ .nonblocking = true } };
    }

    pub fn sync(self: DirectoryCapability, io: std.Io) !void {
        try (std.Io.File{ .handle = self.neutral.descriptor.handle, .flags = .{ .nonblocking = true } }).sync(io);
    }

    pub fn admitChild(self: DirectoryCapability, name: []const u8, expected: ExpectedKind) !Metadata {
        return self.neutral.admitChild(name, self.admission(expected));
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
                const parent: std.Io.Dir = .{ .handle = current.descriptor.handle };
                parent.createDir(create_io, component, .fromMode(0o700)) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => return create_err,
                };
                try (std.Io.File{ .handle = current.descriptor.handle, .flags = .{ .nonblocking = true } }).sync(create_io);
                break :blk try current.openDirectory(component);
            },
            else => return err,
        };
        current.deinit();
        current = child;
    }
    const uid = effectiveUid();
    try fs.admitMetadata(current.metadata, storeAdmission(.directory, current.metadata.device, uid));
    const filesystem = FilesystemPolicy.fromMetadata(try fs.filesystemMetadataForHandle(current.descriptor));
    if (filesystem != .local_supported) return error.UnsupportedFilesystem;
    return .{ .directory = .{
        .neutral = current,
        .metadata = current.metadata,
        .effective_uid = uid,
        .root_device = current.metadata.device,
    }, .filesystem = filesystem };
}

fn storeAdmission(expected: ExpectedKind, device: u64, uid: u32) fs.Admission {
    return .{
        .expected = expected,
        .device = device,
        .uid = uid,
        .mode = if (expected == .directory) 0o700 else 0o600,
        .require_single_link = expected == .regular_file,
    };
}

fn writableRegularFileFlags(exclusive: bool) std.posix.O {
    return .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = exclusive, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true, .NOCTTY = true };
}

fn effectiveUid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.geteuid()),
        .macos => @intCast(std.c.geteuid()),
        else => 0,
    };
}

fn closeRaw(handle: std.posix.fd_t) void {
    _ = std.posix.system.close(handle);
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

test "neutral filesystem ownership proof transitional closes permitted Store consumers and preserves repository cwd" {
    try expectTypedTransitionalSurfaces();
    try expectClosedProductionConsumers(std.testing.allocator, std.testing.io);
    try expectRepositoryCwdAuthority(std.testing.allocator, std.testing.io);
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

fn expectTypedTransitionalSurfaces() !void {
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
        "dir",            "rawHandle",     "createDirectory", "createFile",      "writeAll", "syncFile", "syncDirectory",
        "movePreserving", "moveReplacing", "removeFile",      "removeDirectory",
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
    inline for (.{
        "createDirectory", "createFile", "writeAll",        "syncFile",         "syncDirectory",      "movePreserving",
        "moveReplacing",   "removeFile", "removeDirectory", "acquireDirectory", "acquireRegularFile",
    }) |name| {
        try std.testing.expect(!@hasDecl(fs, name));
        try std.testing.expect(!@hasDecl(fs.Directory, name));
    }
    try std.testing.expect(hasDirectCapabilityMarker("src/unexpected.zig", "const capability = @import(\"review_store/capability.zig\");"));
    try std.testing.expect(hasLegacyRawStoreAccess("const handle = store.neutral.descriptor.handle;"));
    try std.testing.expect(hasLegacyRawStoreAccess("const descriptor = @field(store, \"neutral\");"));
    try std.testing.expect(hasLegacyRawStoreAccess("const dir = store.iterate().reader.dir;"));
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
        const facade_only = std.mem.indexOf(u8, prefix, "review_store.zig\")") != null and consumerIndex(path) == null;
        if (facade_only and (imports_neutral or std.mem.indexOf(u8, prefix, "StoreRootCapability") != null or
            std.mem.indexOf(u8, prefix, "DirectoryCapability") != null or std.mem.indexOf(u8, prefix, "fs/durable.zig") != null))
        {
            return ownershipFailure("facade-importer-owns-capability", path);
        }
        if (consumerIndex(path) != null and hasLegacyRawStoreAccess(prefix) and !legacyTransitionalOwner(path)) {
            return ownershipFailure("raw-store-access-outside-transitional-owner", path);
        }
        if (std.mem.eql(u8, path, "src/fs/capability.zig")) try expectNeutralProductionPrefix(prefix);
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

fn hasDirectCapabilityMarker(path: []const u8, source: []const u8) bool {
    if (std.mem.eql(u8, path, "src/review_store/capability.zig")) return std.mem.indexOf(u8, source, "../fs/capability.zig") != null;
    if (std.mem.eql(u8, path, "src/review_store.zig")) return std.mem.indexOf(u8, source, "review_store/capability.zig") != null;
    return (std.mem.startsWith(u8, path, "src/review_store/") and std.mem.indexOf(u8, source, "@import(\"capability.zig\")") != null) or
        std.mem.indexOf(u8, source, "review_store/capability.zig\")") != null or
        std.mem.indexOf(u8, source, "StoreRootCapability") != null or std.mem.indexOf(u8, source, "DirectoryCapability") != null;
}

fn hasLegacyRawStoreAccess(source: []const u8) bool {
    inline for (.{ ".dir()", ".neutral", ".descriptor", ".handle", ".reader.dir", "@field(", "std.posix.openat", "createDir(", "writeStreamingAll(", ".sync(", ".rename(", ".renamePreserve(", ".deleteFile(", ".deleteDir(" }) |marker| {
        if (std.mem.indexOf(u8, source, marker) != null) return true;
    }
    return false;
}

fn legacyTransitionalOwner(path: []const u8) bool {
    inline for (.{
        "src/review_store/capability.zig",  "src/review_store/history.zig",  "src/review_store/run.zig",
        "src/review_store/publication.zig", "src/review_store/mutation.zig",
    }) |permitted| if (std.mem.eql(u8, path, permitted)) return true;
    return false;
}

fn expectNeutralProductionPrefix(source: []const u8) !void {
    inline for (.{
        "review_store", "ai_review", "committed_review", "../repo",      "createDir(",  "writeStreamingAll(",
        ".sync(",       ".rename(",  ".renamePreserve(", ".deleteFile(", ".deleteDir(", ".CREAT =",
        ".TRUNC =",     ".EXCL =",
    }) |marker| if (std.mem.indexOf(u8, source, marker) != null) return ownershipFailure("neutral-capability-forbidden-marker", marker);
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
