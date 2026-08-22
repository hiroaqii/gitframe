//! Exact-head repository guidance materialization for AI review units.

const std = @import("std");
const identity = @import("../committed_review/identity.zig");
const target_mod = @import("../committed_review/target.zig");
const git_command = @import("../git/command.zig");
const reader = @import("../git/committed_review/instructions.zig");
const limits = @import("limits.zig");
const patch_plan = @import("patch_plan.zig");
const protocol = @import("protocol.zig");

pub const Error = std.mem.Allocator.Error || error{
    InvalidPath,
    GuidanceReadFailed,
    UnsupportedGuidance,
    LimitExceeded,
    ConflictingGuidance,
};

pub const FileChains = struct {
    before: []const protocol.Guidance,
    after: []const protocol.Guidance,
};

pub const Materialized = struct {
    chains: []const FileChains,
    instruction_set_digest: identity.Sha256Digest,
    unique_source_count: u16,
    unique_content_bytes: u32,
};

const CacheValue = union(enum) {
    missing,
    guidance: protocol.Guidance,
};

const Materializer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: target_mod.CommittedReviewTarget,
    cache: std.StringHashMapUnmanaged(CacheValue) = .empty,
    violation: *?limits.Violation,
    unique_source_count: usize = 0,
    unique_content_bytes: usize = 0,

    fn chain(self: *Materializer, file_path: ?[]const u8) Error![]const protocol.Guidance {
        const path = file_path orelse return &.{};
        const candidate_paths = try applicablePathsWithLimit(self.allocator, path, self.violation);
        var chain_items: std.ArrayList(protocol.Guidance) = .empty;
        for (candidate_paths) |candidate| {
            const cached = self.cache.get(candidate) orelse blk: {
                const owned_key = try self.allocator.dupe(u8, candidate);
                var result = try reader.readExactHeadAgents(
                    self.allocator,
                    self.io,
                    self.context,
                    self.target.object_format,
                    self.target.head_oid,
                    owned_key,
                );
                const value: CacheValue = switch (result) {
                    .missing => .missing,
                    .failure => |failure| return switch (failure) {
                        .content_too_large => limit: {
                            limits.record(self.violation, "guidance_file_bytes", limits.max_guidance_file_bytes + 1, limits.max_guidance_file_bytes);
                            break :limit error.LimitExceeded;
                        },
                        .invalid_content, .non_regular_object => error.UnsupportedGuidance,
                        .invalid_request => error.InvalidPath,
                        .object_unavailable, .git_command_failed => error.GuidanceReadFailed,
                    },
                    .blob => |blob| guidance: {
                        if (self.unique_source_count == limits.max_guidance_files) {
                            limits.record(self.violation, "guidance_files", self.unique_source_count + 1, limits.max_guidance_files);
                            return error.LimitExceeded;
                        }
                        const next_bytes = std.math.add(usize, self.unique_content_bytes, blob.content.len) catch
                            return error.UnsupportedGuidance;
                        if (next_bytes > limits.max_guidance_aggregate_bytes) {
                            limits.record(self.violation, "guidance_aggregate_bytes", next_bytes, limits.max_guidance_aggregate_bytes);
                            return error.LimitExceeded;
                        }
                        self.unique_source_count += 1;
                        self.unique_content_bytes = next_bytes;
                        break :guidance .{ .guidance = .{
                            .head_oid = try self.allocator.dupe(u8, self.target.head_oid.slice()),
                            .path_bytes = owned_key,
                            .blob_oid = try self.allocator.dupe(u8, blob.blob_oid.slice()),
                            .content_digest = identity.Sha256Digest.hash(blob.content),
                            .content = blob.content,
                        } };
                    },
                };
                // The arena-backed caller owns transferred blob bytes. Reset
                // the union without freeing them after successful transfer.
                if (result == .blob) result = .missing;
                try self.cache.put(self.allocator, owned_key, value);
                break :blk value;
            };
            switch (cached) {
                .missing => {},
                .guidance => |guidance| try chain_items.append(self.allocator, guidance),
            }
        }
        return chain_items.toOwnedSlice(self.allocator);
    }
};

/// Materialize both labelled chains for every file. Before and after both
/// intentionally use the exact target head tree.
pub fn materialize(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: target_mod.CommittedReviewTarget,
    files: []const patch_plan.File,
) Error!Materialized {
    var ignored: ?limits.Violation = null;
    return materializeWithLimit(allocator, io, context, target, files, &ignored);
}

pub fn materializeWithLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    target: target_mod.CommittedReviewTarget,
    files: []const patch_plan.File,
    violation: *?limits.Violation,
) Error!Materialized {
    violation.* = null;
    target.validate() catch return error.GuidanceReadFailed;
    var state: Materializer = .{
        .allocator = allocator,
        .io = io,
        .context = context,
        .target = target,
        .violation = violation,
    };
    var chains: std.ArrayList(FileChains) = .empty;
    for (files) |file| {
        try chains.append(allocator, .{
            .before = try state.chain(file.old_path),
            .after = try state.chain(file.new_path),
        });
    }
    const owned = try chains.toOwnedSlice(allocator);
    const validation = try validateCompletePlanWithLimit(allocator, owned, violation);
    return .{
        .chains = owned,
        .instruction_set_digest = validation.digest,
        .unique_source_count = @intCast(validation.unique_count),
        .unique_content_bytes = @intCast(validation.unique_bytes),
    };
}

const Validation = struct {
    digest: identity.Sha256Digest,
    unique_count: usize,
    unique_bytes: usize,
};

/// Validate the unique `(head_oid,path)` source union across the complete
/// plan, including exact repeated blob/digest/content identity.
pub fn validateCompletePlan(allocator: std.mem.Allocator, chains: []const FileChains) Error!Validation {
    var ignored: ?limits.Violation = null;
    return validateCompletePlanWithLimit(allocator, chains, &ignored);
}

fn validateCompletePlanWithLimit(allocator: std.mem.Allocator, chains: []const FileChains, violation: *?limits.Violation) Error!Validation {
    var unique: std.ArrayList(protocol.Guidance) = .empty;
    var unique_bytes: usize = 0;
    for (chains) |file_chains| {
        for ([_][]const protocol.Guidance{ file_chains.before, file_chains.after }) |chain| {
            for (chain) |item| {
                if (!validGuidanceItem(item)) return error.UnsupportedGuidance;
                var existing: ?protocol.Guidance = null;
                for (unique.items) |candidate| {
                    if (std.mem.eql(u8, candidate.head_oid, item.head_oid) and
                        std.mem.eql(u8, candidate.path_bytes, item.path_bytes))
                    {
                        existing = candidate;
                        break;
                    }
                }
                if (existing) |candidate| {
                    if (!std.mem.eql(u8, candidate.blob_oid, item.blob_oid) or
                        !candidate.content_digest.eql(item.content_digest) or
                        !std.mem.eql(u8, candidate.content, item.content)) return error.ConflictingGuidance;
                    continue;
                }
                if (unique.items.len == limits.max_guidance_files) {
                    limits.record(violation, "guidance_files", unique.items.len + 1, limits.max_guidance_files);
                    return error.LimitExceeded;
                }
                unique_bytes = std.math.add(usize, unique_bytes, item.content.len) catch return error.UnsupportedGuidance;
                if (unique_bytes > limits.max_guidance_aggregate_bytes) {
                    limits.record(violation, "guidance_aggregate_bytes", unique_bytes, limits.max_guidance_aggregate_bytes);
                    return error.LimitExceeded;
                }
                try unique.append(allocator, item);
            }
        }
    }
    std.mem.sort(protocol.Guidance, unique.items, {}, lessGuidance);
    var preimage: std.ArrayList(u8) = .empty;
    try preimage.appendSlice(allocator, "gitframe-ai-review-instructions-v1\x00");
    for (unique.items) |item| {
        try appendLengthValue(allocator, &preimage, item.head_oid);
        try appendLengthValue(allocator, &preimage, item.path_bytes);
        try appendLengthValue(allocator, &preimage, item.blob_oid);
        try preimage.appendSlice(allocator, &item.content_digest.bytes);
        try appendLengthValue(allocator, &preimage, item.content);
    }
    return .{
        .digest = identity.Sha256Digest.hash(preimage.items),
        .unique_count = unique.items.len,
        .unique_bytes = unique_bytes,
    };
}

fn applicablePaths(allocator: std.mem.Allocator, file_path: []const u8) Error![]const []const u8 {
    var ignored: ?limits.Violation = null;
    return applicablePathsWithLimit(allocator, file_path, &ignored);
}

fn applicablePathsWithLimit(allocator: std.mem.Allocator, file_path: []const u8, violation: *?limits.Violation) Error![]const []const u8 {
    if (!validRepositoryPath(file_path)) return error.InvalidPath;
    const depth = std.mem.count(u8, file_path, "/");
    if (depth > limits.max_guidance_path_depth) {
        limits.record(violation, "guidance_path_depth", depth, limits.max_guidance_path_depth);
        return error.LimitExceeded;
    }
    var result: std.ArrayList([]const u8) = .empty;
    try result.append(allocator, try allocator.dupe(u8, "AGENTS.md"));
    var cursor: usize = 0;
    for (0..depth) |_| {
        const slash = std.mem.indexOfScalarPos(u8, file_path, cursor, '/') orelse return error.InvalidPath;
        const directory = file_path[0..slash];
        try result.append(allocator, try std.fmt.allocPrint(allocator, "{s}/AGENTS.md", .{directory}));
        cursor = slash + 1;
    }
    return result.toOwnedSlice(allocator);
}

fn validRepositoryPath(path: []const u8) bool {
    if (path.len == 0 or path.len > limits.max_raw_path_bytes or path[0] == '/' or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn validGuidanceItem(item: protocol.Guidance) bool {
    if ((item.head_oid.len != 40 and item.head_oid.len != 64) or item.blob_oid.len != item.head_oid.len or
        item.content.len > limits.max_guidance_file_bytes or !validRepositoryPath(item.path_bytes) or
        (!std.mem.eql(u8, item.path_bytes, "AGENTS.md") and !std.mem.endsWith(u8, item.path_bytes, "/AGENTS.md")) or
        !item.content_digest.eql(identity.Sha256Digest.hash(item.content))) return false;
    for (item.head_oid) |byte| if (!lowerHex(byte)) return false;
    for (item.blob_oid) |byte| if (!lowerHex(byte)) return false;
    var iterator = (std.unicode.Utf8View.init(item.content) catch return false).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0 or codepoint == 0x1b or codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f) or
            (codepoint < 0x20 and codepoint != '\n' and codepoint != '\r' and codepoint != '\t')) return false;
    }
    for (item.content, 0..) |byte, index| {
        if (byte == '\r' and (index + 1 == item.content.len or item.content[index + 1] != '\n')) return false;
    }
    return true;
}

fn lowerHex(byte: u8) bool {
    return (byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f');
}

fn lessGuidance(_: void, left: protocol.Guidance, right: protocol.Guidance) bool {
    const head_order = std.mem.order(u8, left.head_oid, right.head_oid);
    if (head_order != .eq) return head_order == .lt;
    return std.mem.order(u8, left.path_bytes, right.path_bytes) == .lt;
}

fn appendLengthValue(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(value.len), .little);
    try output.appendSlice(allocator, &length);
    try output.appendSlice(allocator, value);
}

test "AI review input guidance paths are root to exact parent and depth bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const paths = try applicablePaths(arena.allocator(), "src/nested/file.zig");
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("AGENTS.md", paths[0]);
    try std.testing.expectEqualStrings("src/AGENTS.md", paths[1]);
    try std.testing.expectEqualStrings("src/nested/AGENTS.md", paths[2]);

    var deep: std.ArrayList(u8) = .empty;
    for (0..limits.max_guidance_path_depth + 1) |_| try deep.appendSlice(arena.allocator(), "d/");
    try deep.appendSlice(arena.allocator(), "f");
    try std.testing.expectError(error.LimitExceeded, applicablePaths(arena.allocator(), deep.items));
}

test "AI review input complete guidance union counts unique keys and rejects conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const oid = "0123456789abcdef0123456789abcdef01234567";
    var paths: [limits.max_guidance_files + 1][24]u8 = undefined;
    var guidance: [limits.max_guidance_files + 1]protocol.Guidance = undefined;
    for (&guidance, 0..) |*item, index| {
        const path = try std.fmt.bufPrint(&paths[index], "d{d}/AGENTS.md", .{index});
        item.* = .{
            .head_oid = oid,
            .path_bytes = path,
            .blob_oid = oid,
            .content_digest = identity.Sha256Digest.hash("g"),
            .content = "g",
        };
    }
    var exact: [limits.max_guidance_files]FileChains = undefined;
    for (&exact, 0..) |*chains, index| {
        chains.* = .{ .before = guidance[index .. index + 1], .after = if (index == 0) guidance[0..1] else &.{} };
    }
    const valid = try validateCompletePlan(arena.allocator(), &exact);
    try std.testing.expectEqual(limits.max_guidance_files, valid.unique_count);
    var overflow: [limits.max_guidance_files + 1]FileChains = undefined;
    for (&overflow, 0..) |*chains, index| chains.* = .{ .before = guidance[index .. index + 1], .after = &.{} };
    var violation: ?limits.Violation = null;
    try std.testing.expectError(error.LimitExceeded, validateCompletePlanWithLimit(arena.allocator(), &overflow, &violation));
    try std.testing.expectEqualStrings("guidance_files", violation.?.resource);
    try std.testing.expectEqual(limits.max_guidance_files + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_guidance_files, violation.?.allowed);

    var conflicting = guidance[0];
    conflicting.content = "different";
    conflicting.content_digest = identity.Sha256Digest.hash("different");
    const conflict = [_]FileChains{.{ .before = guidance[0..1], .after = &.{conflicting} }};
    try std.testing.expectError(error.ConflictingGuidance, validateCompletePlan(arena.allocator(), &conflict));

    const maximum_content = try arena.allocator().alloc(u8, limits.max_guidance_file_bytes);
    @memset(maximum_content, 'm');
    var aggregate_paths: [5][24]u8 = undefined;
    var aggregate: [5]protocol.Guidance = undefined;
    for (&aggregate, 0..) |*item, index| {
        const path = try std.fmt.bufPrint(&aggregate_paths[index], "a{d}/AGENTS.md", .{index});
        const content = if (index < 4) maximum_content else "x";
        item.* = .{ .head_oid = oid, .path_bytes = path, .blob_oid = oid, .content_digest = identity.Sha256Digest.hash(content), .content = content };
    }
    var exact_aggregate: [4]FileChains = undefined;
    for (&exact_aggregate, 0..) |*chains, index| chains.* = .{ .before = aggregate[index .. index + 1], .after = &.{} };
    const exact_result = try validateCompletePlan(arena.allocator(), &exact_aggregate);
    try std.testing.expectEqual(limits.max_guidance_aggregate_bytes, exact_result.unique_bytes);
    var aggregate_plus_one: [5]FileChains = undefined;
    for (&aggregate_plus_one, 0..) |*chains, index| chains.* = .{ .before = aggregate[index .. index + 1], .after = &.{} };
    violation = null;
    try std.testing.expectError(error.LimitExceeded, validateCompletePlanWithLimit(arena.allocator(), &aggregate_plus_one, &violation));
    try std.testing.expectEqualStrings("guidance_aggregate_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_guidance_aggregate_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_guidance_aggregate_bytes, violation.?.allowed);
}
