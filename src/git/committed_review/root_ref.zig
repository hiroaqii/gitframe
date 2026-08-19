//! Bounded descriptor read for one-level `$GIT_DIR/<atom>` root/pseudo-refs.
//!
//! Callers may probe only a single atom without `/`. Slash-containing names
//! belong to explicitly admitted `refs/*` namespaces and are never translated
//! into an arbitrary path beneath `$GIT_DIR`.

const std = @import("std");
const builtin = @import("builtin");
const root_capability = @import("../../repo/root_capability.zig");

const max_record_bytes: usize = 8 * 1024;
const max_root_ref_bytes: usize = 2 * (max_record_bytes + 1);

/// Owned interpretation of one root-ref record.
pub const Candidate = union(enum) {
    oid: []u8,
    symbolic_ref: []u8,

    fn deinit(self: *Candidate, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .oid, .symbolic_ref => |bytes| allocator.free(bytes),
        }
        self.* = .{ .oid = &.{} };
    }
};

/// At most two owned candidates from one bounded probe. A third logical record
/// closes as `ambiguous` instead of growing an unbounded collection.
pub const CandidateList = struct {
    items: [2]Candidate = undefined,
    len: usize = 0,

    /// Release all candidate byte allocations.
    pub fn deinit(self: *CandidateList, allocator: std.mem.Allocator) void {
        for (self.items[0..self.len]) |*item| item.deinit(allocator);
        self.len = 0;
    }
};

/// Complete root-ref read terminal, separate from later object resolution.
pub const ProbeResult = union(enum) {
    absent,
    candidates: CandidateList,
    ambiguous,
    failed,

    /// Release candidate allocations, if any, and reset to an empty terminal.
    pub fn deinit(self: *ProbeResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .candidates => |*list| list.deinit(allocator),
            .absent, .ambiguous, .failed => {},
        }
        self.* = .absent;
    }
};

/// Read one `$GIT_DIR/<atom>` candidate through a no-follow, regular-file-only
/// descriptor path. The caller obtains `absolute_path` from bounded
/// `git rev-parse --path-format=absolute --git-path <atom>` and only calls this
/// for a one-level atom. This function does not accept or derive a slash path
/// from an endpoint name; `absolute_path` is only the already-bounded file.
pub fn probe(
    allocator: std.mem.Allocator,
    io: std.Io,
    absolute_path: []const u8,
) std.mem.Allocator.Error!ProbeResult {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return .failed;
    if (absolute_path.len == 0 or absolute_path[0] != '/') return .failed;
    const parent_path = std.fs.path.dirname(absolute_path) orelse return .failed;
    const name = std.fs.path.basename(absolute_path);
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return .failed;

    var parent = root_capability.RootCapability.openCanonical(parent_path) catch return .failed;
    defer parent.deinit();
    const handle = std.posix.openat(parent.handle, name, regularFlags(), 0) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => .absent,
        else => .failed,
    };
    const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
    defer file.close(io);

    const before = file.stat(io) catch return .failed;
    if (before.kind != .file or before.size > max_root_ref_bytes) return .failed;
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    const bytes = reader.interface.allocRemaining(allocator, .limited(max_root_ref_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .failed,
    };
    defer allocator.free(bytes);
    if (bytes.len > max_root_ref_bytes) return .failed;
    const after = file.stat(io) catch return .failed;
    if (after.kind != .file or before.size != after.size or after.size != bytes.len) return .failed;
    return parseBytes(allocator, bytes);
}

fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!ProbeResult {
    if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, 0) != null or std.mem.indexOfScalar(u8, bytes, '\r') != null) {
        return .failed;
    }
    var records: [3][]const u8 = undefined;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (lines.peek() == null) break;
            return .failed;
        }
        if (line.len > max_record_bytes) return .failed;
        if (count == records.len) return .ambiguous;
        records[count] = line;
        count += 1;
    }
    if (count == 0) return .failed;
    // More than one logical record is ambiguous regardless of either
    // record's contents. Close that terminal before allocating candidates so
    // malformed later records cannot change the taxonomy or leak an earlier
    // allocation.
    if (count > 1) return .ambiguous;

    var list: CandidateList = .{};
    errdefer list.deinit(allocator);
    if (std.mem.startsWith(u8, records[0], "ref: ")) {
        if (count != 1 or records[0].len == "ref: ".len) return .failed;
        const target = records[0]["ref: ".len..];
        if (!std.mem.startsWith(u8, target, "refs/")) return .failed;
        list.items[0] = .{ .symbolic_ref = try allocator.dupe(u8, target) };
        list.len = 1;
        return .{ .candidates = list };
    }

    const record = records[0];
    const tab = std.mem.indexOfScalar(u8, record, '\t');
    const oid = if (tab) |index| record[0..index] else record;
    if (oid.len == 0) return .failed;
    list.items[0] = .{ .oid = try allocator.dupe(u8, oid) };
    list.len = 1;
    return .{ .candidates = list };
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

test "root ref parser accepts direct symbolic and FETCH_HEAD-style records" {
    var direct = try parseBytes(std.testing.allocator, "0123456789012345678901234567890123456789\n");
    defer direct.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0123456789012345678901234567890123456789", direct.candidates.items[0].oid);

    var symbolic = try parseBytes(std.testing.allocator, "ref: refs/heads/main\n");
    defer symbolic.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("refs/heads/main", symbolic.candidates.items[0].symbolic_ref);

    var fetch = try parseBytes(std.testing.allocator, "0123456789012345678901234567890123456789\t\tbranch 'main'\n");
    defer fetch.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("0123456789012345678901234567890123456789", fetch.candidates.items[0].oid);
}

test "root ref parser closes multi-record and malformed terminals" {
    var ambiguous = try parseBytes(std.testing.allocator, "a\nb\n");
    defer ambiguous.deinit(std.testing.allocator);
    try std.testing.expect(ambiguous == .ambiguous);
    var malformed_second = try parseBytes(
        std.testing.allocator,
        "0123456789012345678901234567890123456789\n\tmalformed\n",
    );
    defer malformed_second.deinit(std.testing.allocator);
    try std.testing.expect(malformed_second == .ambiguous);
    var symbolic_first = try parseBytes(std.testing.allocator, "ref: refs/heads/main\nsecond\n");
    defer symbolic_first.deinit(std.testing.allocator);
    try std.testing.expect(symbolic_first == .ambiguous);
    var malformed = try parseBytes(std.testing.allocator, "ref: \n");
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expect(malformed == .failed);
    var non_ref_symbolic = try parseBytes(std.testing.allocator, "ref: HEAD\n");
    defer non_ref_symbolic.deinit(std.testing.allocator);
    try std.testing.expect(non_ref_symbolic == .failed);

    var oversized_record: [max_record_bytes + 1]u8 = undefined;
    @memset(&oversized_record, 'a');
    var oversized = try parseBytes(std.testing.allocator, &oversized_record);
    defer oversized.deinit(std.testing.allocator);
    try std.testing.expect(oversized == .failed);
}

test "root ref probe accepts regular files and rejects symlink and directory replacements" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const oid = "0123456789012345678901234567890123456789\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "ROOT", .data = oid });
    const root_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const regular_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "ROOT" });
    defer std.testing.allocator.free(regular_path);
    var regular = try probe(std.testing.allocator, io, regular_path);
    defer regular.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(oid[0 .. oid.len - 1], regular.candidates.items[0].oid);

    try tmp.dir.symLink(io, "ROOT", "LINK", .{});
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "LINK" });
    defer std.testing.allocator.free(link_path);
    var link = try probe(std.testing.allocator, io, link_path);
    defer link.deinit(std.testing.allocator);
    try std.testing.expect(link == .failed);

    try tmp.dir.createDir(io, "DIRECTORY", .default_dir);
    const directory_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "DIRECTORY" });
    defer std.testing.allocator.free(directory_path);
    var directory = try probe(std.testing.allocator, io, directory_path);
    defer directory.deinit(std.testing.allocator);
    try std.testing.expect(directory == .failed);
}
