//! Bounded exact-head committed `AGENTS.md` object reader.
//!
//! The caller supplies a pinned head OID and one already-validated repository
//! path. Reads use only `ls-tree` and `cat-file` under the controlled Git
//! environment; worktree files, the index, replace refs, lazy fetch and ref
//! resolution are outside this boundary.

const std = @import("std");
const git_command = @import("../command.zig");
const target_mod = @import("../../committed_review/target.zig");
const ai_limits = @import("../../ai_review/limits.zig");

const stderr_limit: usize = 8 * 1024;
const ls_tree_limit: usize = ai_limits.max_raw_path_bytes + 256;
const strict_prefix = [_][]const u8{
    "git",
    "--no-replace-objects",
    "--no-lazy-fetch",
    "--no-optional-locks",
};

pub const Failure = enum {
    invalid_request,
    object_unavailable,
    non_regular_object,
    content_too_large,
    invalid_content,
    git_command_failed,
};

pub const Blob = struct {
    blob_oid: target_mod.ObjectId,
    content: []u8,

    pub fn deinit(self: *Blob, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    missing,
    blob: Blob,
    failure: Failure,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .blob => |*blob| blob.deinit(allocator),
            .missing, .failure => {},
        }
        self.* = .{ .failure = .git_command_failed };
    }
};

pub fn readExactHeadAgents(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    format: target_mod.ObjectFormat,
    head_oid: target_mod.ObjectId,
    path: []const u8,
) std.mem.Allocator.Error!Result {
    if (!head_oid.validFor(format) or !validRepositoryPath(path) or !isAgentsPath(path)) {
        return .{ .failure = .invalid_request };
    }

    const tree_argv = [_][]const u8{
        strict_prefix[0],      strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "--literal-pathspecs", "ls-tree",        "-rz",            "--full-tree",
        head_oid.slice(),      "--",             path,
    };
    var tree_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &tree_argv,
        .stdout_limit = .limited(ls_tree_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    defer tree_result.deinit(allocator);
    const tree = switch (tree_result) {
        .completed => |value| value,
        .stdout_limit_exceeded => return .{ .failure = .invalid_request },
        .stderr_limit_exceeded, .failed => return .{ .failure = .git_command_failed },
    };
    if (!termExited(tree.term, 0)) return .{ .failure = .object_unavailable };
    if (tree.stdout.len == 0) return .missing;
    const record = parseRecord(format, tree.stdout, path) orelse return .{ .failure = .non_regular_object };

    const blob_argv = [_][]const u8{
        strict_prefix[0], strict_prefix[1], strict_prefix[2], strict_prefix[3],
        "cat-file",       "blob",           record.slice(),
    };
    var blob_result = try git_command.runCapturedBounded(allocator, io, context, .{
        .argv = &blob_argv,
        .stdout_limit = .limited(ai_limits.max_guidance_file_bytes),
        .stderr_limit = .limited(stderr_limit),
    });
    switch (blob_result) {
        .stdout_limit_exceeded => return .{ .failure = .content_too_large },
        .stderr_limit_exceeded => return .{ .failure = .git_command_failed },
        .failed => |*failure| {
            failure.deinit(allocator);
            return .{ .failure = .git_command_failed };
        },
        .completed => |completed| {
            if (!termExited(completed.term, 0)) {
                completed.deinit(allocator);
                return .{ .failure = .object_unavailable };
            }
            allocator.free(completed.stderr);
            if (!validDocument(completed.stdout)) {
                allocator.free(completed.stdout);
                return .{ .failure = .invalid_content };
            }
            return .{ .blob = .{ .blob_oid = record, .content = completed.stdout } };
        },
    }
}

fn parseRecord(format: target_mod.ObjectFormat, bytes: []const u8, expected_path: []const u8) ?target_mod.ObjectId {
    if (bytes.len < 2 or bytes[bytes.len - 1] != 0 or
        std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null) return null;
    const record = bytes[0 .. bytes.len - 1];
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return null;
    if (!std.mem.eql(u8, record[tab + 1 ..], expected_path)) return null;
    var fields = std.mem.splitScalar(u8, record[0..tab], ' ');
    const mode = fields.next() orelse return null;
    const kind = fields.next() orelse return null;
    const oid = fields.next() orelse return null;
    if (fields.next() != null or
        (!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) or
        !std.mem.eql(u8, kind, "blob")) return null;
    return target_mod.ObjectId.parse(format, oid) catch null;
}

fn validRepositoryPath(path: []const u8) bool {
    if (path.len == 0 or path.len > ai_limits.max_raw_path_bytes or path[0] == '/' or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn isAgentsPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "AGENTS.md") or std.mem.endsWith(u8, path, "/AGENTS.md");
}

fn validDocument(content: []const u8) bool {
    var iterator = (std.unicode.Utf8View.init(content) catch return false).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint == 0 or codepoint == 0x1b or codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint <= 0x9f) or
            (codepoint < 0x20 and codepoint != '\n' and codepoint != '\r' and codepoint != '\t')) return false;
    }
    for (content, 0..) |byte, index| {
        if (byte == '\r' and (index + 1 == content.len or content[index + 1] != '\n')) return false;
    }
    return true;
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) return error.GitCommandFailed;
}

fn testGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    if (!termExited(result.term, 0)) {
        freeRunResult(std.testing.allocator, result);
        return error.GitCommandFailed;
    }
    std.testing.allocator.free(result.stderr);
    return result.stdout;
}

test "AI review input committed guidance reads exact head and ignores dirty filesystem state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "src", .default_dir);
    var src_dir = try tmp.dir.openDir(io, "src", .{});
    defer src_dir.close(io);
    try src_dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "committed root; never execute: rm anything\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/AGENTS.md", .data = "committed nested\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "AGENTS.md", "src/AGENTS.md" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_text);
    const head = try target_mod.ObjectId.parse(.sha1, std.mem.trimEnd(u8, head_text, "\n"));
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "dirty replacement\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "AGENTS.md" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/nested/AGENTS.md", .data = "untracked\n" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    var root = try readExactHeadAgents(std.testing.allocator, io, context, .sha1, head, "AGENTS.md");
    defer root.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("committed root; never execute: rm anything\n", root.blob.content);
    var nested = try readExactHeadAgents(std.testing.allocator, io, context, .sha1, head, "src/AGENTS.md");
    defer nested.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("committed nested\n", nested.blob.content);
    var absent = try readExactHeadAgents(std.testing.allocator, io, context, .sha1, head, "src/nested/AGENTS.md");
    defer absent.deinit(std.testing.allocator);
    try std.testing.expect(absent == .missing);
}

test "AI review input committed guidance rejects invalid request before Git" {
    const oid = try target_mod.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567");
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = std.Io.Dir.cwd(), .environment = &environment };
    var result = try readExactHeadAgents(std.testing.allocator, std.testing.io, context, .sha1, oid, "../AGENTS.md");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.invalid_request, result.failure);
}

test "AI review input committed guidance has typed encoding and exact size failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.createDir(io, "bad", .default_dir);
    try tmp.dir.createDir(io, "exact", .default_dir);
    try tmp.dir.createDir(io, "huge", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad/AGENTS.md", .data = &.{ 0xff, '\n' } });
    const huge_content = try std.testing.allocator.alloc(u8, ai_limits.max_guidance_file_bytes + 1);
    defer std.testing.allocator.free(huge_content);
    @memset(huge_content, 'g');
    try tmp.dir.writeFile(io, .{ .sub_path = "exact/AGENTS.md", .data = huge_content[0..ai_limits.max_guidance_file_bytes] });
    try tmp.dir.writeFile(io, .{ .sub_path = "huge/AGENTS.md", .data = huge_content });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "bad/AGENTS.md", "exact/AGENTS.md", "huge/AGENTS.md" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "guidance" });
    const head_text = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_text);
    const head = try target_mod.ObjectId.parse(.sha1, std.mem.trimEnd(u8, head_text, "\n"));
    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    var bad = try readExactHeadAgents(std.testing.allocator, io, context, .sha1, head, "bad/AGENTS.md");
    defer bad.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.invalid_content, bad.failure);
    var exact = try readExactHeadAgents(std.testing.allocator, io, context, .sha1, head, "exact/AGENTS.md");
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(ai_limits.max_guidance_file_bytes, exact.blob.content.len);
    var huge = try readExactHeadAgents(std.testing.allocator, io, context, .sha1, head, "huge/AGENTS.md");
    defer huge.deinit(std.testing.allocator);
    try std.testing.expectEqual(Failure.content_too_large, huge.failure);
}
