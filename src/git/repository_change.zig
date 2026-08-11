const std = @import("std");
const git_command = @import("command.zig");
const process_runner = @import("../process/runner.zig");
const repository_change_map = @import("../repository/change_map.zig");

pub const RepositoryFileChangeLoadResult = union(enum) {
    /// The pinned HEAD tree has no blob for this path, or HEAD is unborn.
    all_added,
    /// Owned zero-context no-index patch from the pinned blob to `source_bytes`.
    patch: []u8,
    /// The pinned blob and current logical source are identical.
    unchanged,
    /// Static failure only: raw Git/path/source/temp details are never UI text.
    failed_static: []const u8,

    pub fn deinit(self: RepositoryFileChangeLoadResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .patch => |bytes| allocator.free(bytes),
            .all_added, .unchanged, .failed_static => {},
        }
    }
};

pub const RepositoryFileChangeRequest = struct {
    /// Borrowed descriptor cwd kept alive by the synchronous task call.
    cwd: std.Io.Dir,
    /// Borrowed controlled environment shared by repository and temp commands.
    environment: *const git_command.LocalGitEnvironment,
    /// Borrowed byte-exact manifest path; every Git pathspec command is literal.
    path: []const u8,
    /// Borrowed immutable descriptor-safe task snapshot, never page memory.
    source_bytes: []const u8,
    /// Borrowed absolute user-private temp base selected by the App shell.
    temp_base_path: []const u8 = "/tmp",
};

const repository_change_small_output_limit = 256 * 1024;

const HeadState = union(enum) {
    unborn,
    present: []const u8,
};

const AttributeValue = enum { unspecified, unset };

const AttributeState = struct {
    filter: AttributeValue,
    working_tree_encoding: AttributeValue,

    fn eql(self: AttributeState, other: AttributeState) bool {
        return self.filter == other.filter and self.working_tree_encoding == other.working_tree_encoding;
    }
};

const TreeBlob = struct {
    oid: []const u8,
};

const RepositoryChangePhaseHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque, std.Io, std.Io.Dir) git_command.Error!void,

    fn invoke(self: RepositoryChangePhaseHook, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        return self.run(self.context, io, cwd);
    }
};

const RepositoryChangeWriteTarget = enum { head, current };

/// Private deterministic seams for contracts that require a mutation between
/// synchronous Git commands. Production always passes null so test vocabulary
/// does not become part of the public backend namespace.
const RepositoryChangeTestHooks = struct {
    command_index: usize = 0,
    fail_command_at: ?usize = null,
    limit_command_at: ?usize = null,
    forced_stdout_limit: usize = 0,
    fail_write: ?RepositoryChangeWriteTarget = null,
    fail_temp_open: bool = false,
    temp_name_token: ?[]const u8 = null,
    force_cleanup_failure: bool = false,
    after_head_resolved: ?RepositoryChangePhaseHook = null,
    after_blob_loaded: ?RepositoryChangePhaseHook = null,
};

pub fn loadRepositoryFileChange(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryFileChangeRequest,
) git_command.Error!RepositoryFileChangeLoadResult {
    return loadGitRepositoryFileChangeWithHooks(allocator, io, request, null);
}

fn loadGitRepositoryFileChangeWithHooks(
    allocator: std.mem.Allocator,
    io: std.Io,
    request: RepositoryFileChangeRequest,
    hooks: ?*RepositoryChangeTestHooks,
) git_command.Error!RepositoryFileChangeLoadResult {
    const repository_context = git_command.DirectoryContext{ .cwd = request.cwd, .environment = request.environment };

    const head_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
        "git",
        "--no-optional-locks",
        "--literal-pathspecs",
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--untracked-files=no",
        "--",
        request.path,
    }, &.{}, repository_change_small_output_limit, hooks);
    defer head_result.deinit(allocator);
    if (!termExited(head_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    const head = parsePorcelainHead(head_result.stdout) orelse return .{ .failed_static = "Repository change basis unavailable" };
    if (head == .unborn) return .all_added;
    if (hooks) |test_hooks| if (test_hooks.after_head_resolved) |hook| try hook.invoke(io, request.cwd);

    const treeish = std.fmt.allocPrint(allocator, "{s}^{{tree}}", .{head.present}) catch return error.OutOfMemory;
    defer allocator.free(treeish);
    const tree_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
        "git",
        "--no-optional-locks",
        "rev-parse",
        "--verify",
        treeish,
    }, &.{}, 128, hooks);
    defer tree_result.deinit(allocator);
    if (!termExited(tree_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    const tree_oid = trimSingleLine(tree_result.stdout);
    if (!isObjectId(tree_oid)) return .{ .failed_static = "Repository change basis unavailable" };

    const entry_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
        "git",
        "--no-optional-locks",
        "--literal-pathspecs",
        "ls-tree",
        "-z",
        "--full-tree",
        tree_oid,
        "--",
        request.path,
    }, &.{}, repository_change_small_output_limit, hooks);
    defer entry_result.deinit(allocator);
    if (!termExited(entry_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    const blob = parseTreeBlob(entry_result.stdout, request.path) catch return .{ .failed_static = "Repository change basis unavailable" };
    if (blob == null) return .all_added;

    const attributes_before = try loadSafeRepositoryChangeAttributes(allocator, io, repository_context, request.path, hooks) orelse
        return .{ .failed_static = "Repository change attributes unavailable" };

    const blob_result = try runRepositoryChangeCommand(allocator, io, repository_context, &.{
        "git",
        "--no-optional-locks",
        "cat-file",
        "blob",
        blob.?.oid,
    }, &.{}, 16 * 1024 * 1024, hooks);
    defer blob_result.deinit(allocator);
    if (!termExited(blob_result.term, 0)) return .{ .failed_static = "Repository change basis unavailable" };
    if (hooks) |test_hooks| if (test_hooks.after_blob_loaded) |hook| try hook.invoke(io, request.cwd);

    const head_logical = repository_change_map.normalizeCrlfAlloc(allocator, blob_result.stdout) catch return error.OutOfMemory;
    defer allocator.free(head_logical);
    const current_logical = repository_change_map.normalizeCrlfAlloc(allocator, request.source_bytes) catch return error.OutOfMemory;
    defer allocator.free(current_logical);

    var temp = try ComparisonTemp.init(
        allocator,
        io,
        request.temp_base_path,
        if (hooks) |test_hooks| test_hooks.temp_name_token else null,
        if (hooks) |test_hooks| test_hooks.fail_temp_open else false,
    );
    var temp_active = true;
    defer if (temp_active) temp.deinitBestEffort(allocator, io);
    if (hooks) |test_hooks| if (test_hooks.fail_write == .head) return error.SpawnFailed;
    try writePrivateComparisonFile(io, temp.dir, "head", head_logical);
    if (hooks) |test_hooks| if (test_hooks.fail_write == .current) return error.SpawnFailed;
    try writePrivateComparisonFile(io, temp.dir, "current", current_logical);

    const diff_result = try runRepositoryChangeCommand(allocator, io, .{ .cwd = temp.dir, .environment = request.environment }, &.{
        "git",
        "diff",
        "--no-index",
        "--text",
        "--unified=0",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        "--src-prefix=a/",
        "--dst-prefix=b/",
        "--",
        "head",
        "current",
    }, &.{}, 16 * 1024 * 1024, hooks);
    errdefer diff_result.deinit(allocator);

    const attributes_after = try loadSafeRepositoryChangeAttributes(allocator, io, repository_context, request.path, hooks) orelse {
        diff_result.deinit(allocator);
        return .{ .failed_static = "Repository change attributes unavailable" };
    };
    if (!attributes_before.eql(attributes_after)) {
        diff_result.deinit(allocator);
        return .{ .failed_static = "Repository change attributes changed" };
    }

    const candidate: RepositoryFileChangeLoadResult = candidate: {
        switch (diff_result.term) {
            .exited => |code| switch (code) {
                0 => {
                    diff_result.deinit(allocator);
                    break :candidate .unchanged;
                },
                1 => {
                    allocator.free(diff_result.stderr);
                    break :candidate .{ .patch = diff_result.stdout };
                },
                else => {},
            },
            else => {},
        }
        diff_result.deinit(allocator);
        break :candidate .{ .failed_static = "Repository source comparison failed" };
    };

    // A patch is not a successful backend result until its raw materialization
    // is gone. This terminal consumes the temp owner even on delete failure;
    // the candidate is then released and only static optional unavailability
    // can escape. The defer remains solely for error unwind before this point.
    const cleaned = temp.finish(allocator, io, if (hooks) |test_hooks| test_hooks.force_cleanup_failure else false);
    temp_active = false;
    if (!cleaned) {
        candidate.deinit(allocator);
        return .{ .failed_static = "Repository comparison cleanup failed" };
    }
    return candidate;
}

fn runRepositoryChangeCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    argv: []const []const u8,
    stdin: []const u8,
    stdout_limit: usize,
    hooks: ?*RepositoryChangeTestHooks,
) git_command.Error!process_runner.Result {
    var effective_stdout_limit = stdout_limit;
    if (hooks) |test_hooks| {
        const command_index = test_hooks.command_index;
        test_hooks.command_index += 1;
        if (test_hooks.fail_command_at == command_index) return error.SpawnFailed;
        if (test_hooks.limit_command_at == command_index) effective_stdout_limit = @min(effective_stdout_limit, test_hooks.forced_stdout_limit);
    }
    return git_command.runWithStdin(allocator, io, context, .{
        .argv = argv,
        .stdin = stdin,
        .stdout_limit = .limited(effective_stdout_limit),
        .stderr_limit = .limited(repository_change_small_output_limit),
    });
}

fn termExited(term: std.process.Child.Term, expected: u8) bool {
    return switch (term) {
        .exited => |code| code == expected,
        else => false,
    };
}

fn parsePorcelainHead(output: []const u8) ?HeadState {
    const prefix = "# branch.oid ";
    var start: usize = 0;
    while (start < output.len) {
        const newline = std.mem.indexOfAnyPos(u8, output, start, "\n\x00") orelse output.len;
        const record = output[start..newline];
        if (std.mem.startsWith(u8, record, prefix)) {
            const value = record[prefix.len..];
            if (std.mem.eql(u8, value, "(initial)")) return .unborn;
            if (isObjectId(value)) return .{ .present = value };
            return null;
        }
        start = if (newline < output.len) newline + 1 else output.len;
    }
    return null;
}

fn trimSingleLine(output: []const u8) []const u8 {
    return std.mem.trim(u8, output, "\r\n");
}

fn isObjectId(value: []const u8) bool {
    if (value.len != 40 and value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn parseTreeBlob(output: []const u8, expected_path: []const u8) !?TreeBlob {
    if (output.len == 0) return null;
    const record_end = std.mem.indexOfScalar(u8, output, 0) orelse return error.MalformedTreeEntry;
    if (record_end + 1 != output.len) return error.MultipleTreeEntries;
    const record = output[0..record_end];
    const tab = std.mem.indexOfScalar(u8, record, '\t') orelse return error.MalformedTreeEntry;
    const metadata = record[0..tab];
    const path = record[tab + 1 ..];
    if (!std.mem.eql(u8, path, expected_path)) return error.UnexpectedTreePath;
    var fields = std.mem.splitScalar(u8, metadata, ' ');
    const mode = fields.next() orelse return error.MalformedTreeEntry;
    const kind = fields.next() orelse return error.MalformedTreeEntry;
    const oid = fields.next() orelse return error.MalformedTreeEntry;
    if (fields.next() != null) return error.MalformedTreeEntry;
    if ((!std.mem.eql(u8, mode, "100644") and !std.mem.eql(u8, mode, "100755")) or
        !std.mem.eql(u8, kind, "blob") or !isObjectId(oid)) return error.UnsupportedTreeEntry;
    return .{ .oid = oid };
}

fn loadSafeRepositoryChangeAttributes(
    allocator: std.mem.Allocator,
    io: std.Io,
    context: git_command.DirectoryContext,
    path: []const u8,
    hooks: ?*RepositoryChangeTestHooks,
) git_command.Error!?AttributeState {
    const stdin = allocator.alloc(u8, path.len + 1) catch return error.OutOfMemory;
    defer allocator.free(stdin);
    @memcpy(stdin[0..path.len], path);
    stdin[path.len] = 0;
    const result = try runRepositoryChangeCommand(allocator, io, context, &.{
        "git",
        "--no-optional-locks",
        "--literal-pathspecs",
        "check-attr",
        "-z",
        "--stdin",
        "filter",
        "working-tree-encoding",
    }, stdin, repository_change_small_output_limit, hooks);
    defer result.deinit(allocator);
    if (!termExited(result.term, 0)) return null;
    return parseSafeAttributes(result.stdout, path);
}

fn parseSafeAttributes(output: []const u8, expected_path: []const u8) ?AttributeState {
    var fields = std.mem.splitScalar(u8, output, 0);
    const first_path = fields.next() orelse return null;
    const first_name = fields.next() orelse return null;
    const first_value = fields.next() orelse return null;
    const second_path = fields.next() orelse return null;
    const second_name = fields.next() orelse return null;
    const second_value = fields.next() orelse return null;
    if (fields.next()) |tail| if (tail.len != 0 or fields.next() != null) return null;
    if (!std.mem.eql(u8, first_path, expected_path) or !std.mem.eql(u8, second_path, expected_path) or
        !std.mem.eql(u8, first_name, "filter") or !std.mem.eql(u8, second_name, "working-tree-encoding")) return null;
    return .{
        .filter = parseSafeAttributeValue(first_value) orelse return null,
        .working_tree_encoding = parseSafeAttributeValue(second_value) orelse return null,
    };
}

fn parseSafeAttributeValue(value: []const u8) ?AttributeValue {
    if (std.mem.eql(u8, value, "unspecified")) return .unspecified;
    if (std.mem.eql(u8, value, "unset")) return .unset;
    return null;
}

const ComparisonTemp = struct {
    base_dir: std.Io.Dir,
    dir: std.Io.Dir,
    dir_name: []u8,

    fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        configured_base: []const u8,
        name_token: ?[]const u8,
        fail_open: bool,
    ) git_command.Error!ComparisonTemp {
        const preferred = if (std.fs.path.isAbsolute(configured_base)) configured_base else "/tmp";
        var base_dir = std.Io.Dir.openDirAbsolute(io, preferred, .{}) catch
            std.Io.Dir.openDirAbsolute(io, "/tmp", .{}) catch return error.SpawnFailed;
        errdefer base_dir.close(io);
        const now = std.Io.Clock.now(.awake, io).nanoseconds;
        for (0..16) |attempt| {
            const dir_name = if (name_token) |token|
                std.fmt.allocPrint(allocator, "gitframe-change-{s}-{d}", .{ token, attempt }) catch return error.OutOfMemory
            else
                std.fmt.allocPrint(allocator, "gitframe-change-{d}-{d}", .{ now, attempt }) catch return error.OutOfMemory;
            base_dir.createDir(io, dir_name, .fromMode(0o700)) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(dir_name);
                    continue;
                },
                else => {
                    allocator.free(dir_name);
                    return error.SpawnFailed;
                },
            };
            if (fail_open) {
                base_dir.deleteTree(io, dir_name) catch {};
                allocator.free(dir_name);
                return error.SpawnFailed;
            }
            const dir = base_dir.openDir(io, dir_name, .{}) catch {
                base_dir.deleteTree(io, dir_name) catch {};
                allocator.free(dir_name);
                return error.SpawnFailed;
            };
            return .{ .base_dir = base_dir, .dir = dir, .dir_name = dir_name };
        }
        return error.SpawnFailed;
    }

    /// Consumes every handle/name owner and reports whether recursive removal
    /// completed. `force_failure` is a test-only simulation of a filesystem
    /// refusal and deliberately leaves the private directory for the fixture
    /// to inspect and remove.
    fn finish(self: *ComparisonTemp, allocator: std.mem.Allocator, io: std.Io, force_failure: bool) bool {
        self.dir.close(io);
        const removed = if (force_failure) false else blk: {
            self.base_dir.deleteTree(io, self.dir_name) catch break :blk false;
            break :blk true;
        };
        self.base_dir.close(io);
        allocator.free(self.dir_name);
        self.* = undefined;
        return removed;
    }

    fn deinitBestEffort(self: *ComparisonTemp, allocator: std.mem.Allocator, io: std.Io) void {
        _ = self.finish(allocator, io, false);
    }
};

fn writePrivateComparisonFile(io: std.Io, dir: std.Io.Dir, name: []const u8, contents: []const u8) git_command.Error!void {
    var file = dir.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch return error.SpawnFailed;
    defer file.close(io);
    file.writeStreamingAll(io, contents) catch return error.SpawnFailed;
}

fn repositoryChangeMapForTest(cwd: std.Io.Dir, path: []const u8, source_bytes: []const u8, temp_base_path: []const u8) !repository_change_map.Map {
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    const result = try loadRepositoryFileChange(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
        .environment = &environment,
        .path = path,
        .source_bytes = source_bytes,
        .temp_base_path = temp_base_path,
    });
    defer result.deinit(std.testing.allocator);
    return switch (result) {
        .all_added => repository_change_map.allAdded(std.testing.allocator, testContentLineCount(source_bytes)),
        .patch => |patch| repository_change_map.fromPatch(std.testing.allocator, patch, testContentLineCount(source_bytes)),
        .unchanged => repository_change_map.fromPatch(std.testing.allocator, "", testContentLineCount(source_bytes)),
        .failed_static => error.UnexpectedRepositoryChangeFailure,
    };
}

fn testingLocalGitEnvironment(allocator: std.mem.Allocator) !git_command.LocalGitEnvironment {
    var parent = try std.testing.environ.createMap(allocator);
    defer parent.deinit();
    return git_command.LocalGitEnvironment.initFromParent(allocator, &parent);
}

fn testContentLineCount(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 1;
    for (bytes[0 .. bytes.len - 1]) |byte| if (byte == '\n') {
        count += 1;
    };
    return count;
}

test "repository change backend compares current source with pinned HEAD independent of index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source.zig", .data = "keep\nold\nremoved\n" });
    try runTestGit(io, &.{ "git", "add", "source.zig" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);

    try runTestGit(io, &.{ "git", "rm", "--cached", "--", "source.zig" }, work);
    var index_absent_unchanged = try repositoryChangeMapForTest(work, "source.zig", "keep\nold\nremoved\n", "/tmp");
    defer index_absent_unchanged.deinit(std.testing.allocator);
    try std.testing.expect(index_absent_unchanged.isEmpty());
    try runTestGit(io, &.{ "git", "add", "source.zig" }, work);

    const current = "keep\nnew\nadded\n";
    try work.writeFile(io, .{ .sub_path = "source.zig", .data = current });
    var before_stage = try repositoryChangeMapForTest(work, "source.zig", current, "/tmp");
    defer before_stage.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, before_stage.row(1));
    try std.testing.expectEqual(repository_change_map.Kind.modified, before_stage.row(2));
    try std.testing.expectEqual(repository_change_map.Kind.none, before_stage.row(0));

    try runTestGit(io, &.{ "git", "add", "source.zig" }, work);
    var staged = try repositoryChangeMapForTest(work, "source.zig", current, "/tmp");
    defer staged.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, before_stage.rows, staged.rows);

    const mixed_current = "keep\nnewer\nadded\n";
    try work.writeFile(io, .{ .sub_path = "source.zig", .data = mixed_current });
    var mixed = try repositoryChangeMapForTest(work, "source.zig", mixed_current, "/tmp");
    defer mixed.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, before_stage.rows, mixed.rows);

    try runTestGit(io, &.{ "git", "rm", "--cached", "-f", "--", "source.zig" }, work);
    var removed_from_index = try repositoryChangeMapForTest(work, "source.zig", mixed_current, "/tmp");
    defer removed_from_index.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, before_stage.rows, removed_from_index.rows);
}

test "repository change backend marks new and unborn current rows as added including empty source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "committed", .default_dir);
    var committed = try tmp.dir.openDir(io, "committed", .{});
    defer committed.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, committed);
    try committed.writeFile(io, .{ .sub_path = "README", .data = "base\n" });
    try runTestGit(io, &.{ "git", "add", "README" }, committed);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, committed);

    var untracked = try repositoryChangeMapForTest(committed, "new.zig", "one\ntwo\n", "/tmp");
    defer untracked.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{ .added, .added }, untracked.rows);
    try committed.writeFile(io, .{ .sub_path = "new.zig", .data = "one\ntwo\n" });
    try runTestGit(io, &.{ "git", "add", "new.zig" }, committed);
    var tracked_added = try repositoryChangeMapForTest(committed, "new.zig", "one\ntwo\n", "/tmp");
    defer tracked_added.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{ .added, .added }, tracked_added.rows);

    try committed.writeFile(io, .{ .sub_path = "untracked-empty", .data = "" });
    var untracked_empty = try repositoryChangeMapForTest(committed, "untracked-empty", "", "/tmp");
    defer untracked_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), untracked_empty.rows.len);
    try committed.writeFile(io, .{ .sub_path = "tracked-added-empty", .data = "" });
    try runTestGit(io, &.{ "git", "add", "tracked-added-empty" }, committed);
    var tracked_added_empty = try repositoryChangeMapForTest(committed, "tracked-added-empty", "", "/tmp");
    defer tracked_added_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), tracked_added_empty.rows.len);

    try tmp.dir.createDir(io, "unborn", .default_dir);
    var unborn = try tmp.dir.openDir(io, "unborn", .{});
    defer unborn.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, unborn);
    var unborn_map = try repositoryChangeMapForTest(unborn, "first.zig", "one\ntwo\n", "/tmp");
    defer unborn_map.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{ .added, .added }, unborn_map.rows);
    try unborn.writeFile(io, .{ .sub_path = "empty", .data = "" });
    var unborn_empty = try repositoryChangeMapForTest(unborn, "empty", "", "/tmp");
    defer unborn_empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unborn_empty.rows.len);
}

test "repository change backend treats pathspec magic literally and fails closed for transforming attributes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "a*b.zig", .data = "literal\n" });
    try work.writeFile(io, .{ .sub_path = "axb.zig", .data = "other\n" });
    try work.writeFile(io, .{ .sub_path = "-leading.zig", .data = "leading\n" });
    try work.writeFile(io, .{ .sub_path = ":(glob)*.zig", .data = "glob magic\n" });
    try work.writeFile(io, .{ .sub_path = "question?.zig", .data = "question\n" });
    try work.writeFile(io, .{ .sub_path = "bracket[.zig", .data = "bracket\n" });
    try runTestGit(io, &.{ "git", "--literal-pathspecs", "add", "--", "a*b.zig", "axb.zig", "-leading.zig", ":(glob)*.zig", "question?.zig", "bracket[.zig" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);

    var literal = try repositoryChangeMapForTest(work, "a*b.zig", "changed\n", "/tmp");
    defer literal.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{.modified}, literal.rows);
    var leading = try repositoryChangeMapForTest(work, "-leading.zig", "changed\n", "/tmp");
    defer leading.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(repository_change_map.Kind, &.{.modified}, leading.rows);
    inline for (.{ ":(glob)*.zig", "question?.zig", "bracket[.zig" }) |magic_path| {
        var magic = try repositoryChangeMapForTest(work, magic_path, "changed\n", "/tmp");
        defer magic.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(repository_change_map.Kind, &.{.modified}, magic.rows);
    }

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a\\*b.zig filter=unsafe\n" });
    const rejected = try loadRepositoryFileChange(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
        .path = "a*b.zig",
        .source_bytes = "changed\n",
    });
    defer rejected.deinit(std.testing.allocator);
    try std.testing.expect(rejected == .failed_static);

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a[*]b.zig working-tree-encoding=UTF-16\n" });
    const encoding_rejected = try loadRepositoryFileChange(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
        .path = "a*b.zig",
        .source_bytes = "changed\n",
    });
    defer encoding_rejected.deinit(std.testing.allocator);
    try std.testing.expect(encoding_rejected == .failed_static);

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a\\*b.zig -diff\n" });
    var forced_text = try repositoryChangeMapForTest(work, "a*b.zig", "changed\n", "/tmp");
    defer forced_text.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, forced_text.row(0));

    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "a[*]b.zig diff=custom\n" });
    try runTestGit(io, &.{ "git", "config", "diff.custom.textconv", "false" }, work);
    var textconv_disabled = try repositoryChangeMapForTest(work, "a*b.zig", "changed\n", "/tmp");
    defer textconv_disabled.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, textconv_disabled.row(0));
}

test "repository change temporary comparison leaves its private base empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "temp-base", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const temp_base = try tmp.dir.realPathFileAlloc(io, "temp-base", std.testing.allocator);
    defer std.testing.allocator.free(temp_base);

    var direct = try ComparisonTemp.init(std.testing.allocator, io, temp_base, null, false);
    const directory_stat = try direct.base_dir.statFile(io, direct.dir_name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), directory_stat.permissions.toMode() & 0o777);
    try writePrivateComparisonFile(io, direct.dir, "source", "private\n");
    const file_stat = try direct.dir.statFile(io, "source", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);
    try std.testing.expect(direct.finish(std.testing.allocator, io, false));

    var map = try repositoryChangeMapForTest(work, "source", "new\n", temp_base);
    defer map.deinit(std.testing.allocator);

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

const ResetHeadHookContext = struct {
    oid: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "reset", "--hard", ctx.oid }, cwd) catch return error.SpawnFailed;
    }
};

const RemoveIndexHookContext = struct {
    path: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        runTestGit(io, &.{ "git", "rm", "--cached", "--", ctx.path }, cwd) catch return error.SpawnFailed;
    }
};

const RewriteWorktreeHookContext = struct {
    path: []const u8,
    bytes: []const u8,

    fn run(ctx_ptr: *anyopaque, io: std.Io, cwd: std.Io.Dir) git_command.Error!void {
        const ctx: *@This() = @ptrCast(@alignCast(ctx_ptr));
        cwd.writeFile(io, .{ .sub_path = ctx.path, .data = ctx.bytes }) catch return error.SpawnFailed;
    }
};

test "repository change backend keeps copied object basis across HEAD index and worktree mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    try tmp.dir.createDir(io, "head-move", .default_dir);
    var head_move = try tmp.dir.openDir(io, "head-move", .{});
    defer head_move.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, head_move);
    try head_move.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, head_move);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "old" }, head_move);
    const old_oid_output = try gitOutputAlloc(io, head_move, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(old_oid_output);
    try head_move.writeFile(io, .{ .sub_path = "source", .data = "new HEAD\n" });
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-am", "new" }, head_move);
    const new_oid_output = try gitOutputAlloc(io, head_move, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(new_oid_output);
    try runTestGit(io, &.{ "git", "reset", "--hard", trimLineEnd(old_oid_output) }, head_move);

    var reset_context = ResetHeadHookContext{ .oid = trimLineEnd(new_oid_output) };
    var head_hooks = RepositoryChangeTestHooks{ .after_head_resolved = .{
        .context = &reset_context,
        .run = ResetHeadHookContext.run,
    } };
    const pinned = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = head_move,
        .environment = &environment,
        .path = "source",
        .source_bytes = "old\n",
    }, &head_hooks);
    defer pinned.deinit(std.testing.allocator);
    try std.testing.expect(pinned == .unchanged);
    const current_oid_output = try gitOutputAlloc(io, head_move, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(current_oid_output);
    try std.testing.expectEqualStrings(trimLineEnd(new_oid_output), trimLineEnd(current_oid_output));

    try tmp.dir.createDir(io, "index-move", .default_dir);
    var index_move = try tmp.dir.openDir(io, "index-move", .{});
    defer index_move.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, index_move);
    try index_move.writeFile(io, .{ .sub_path = "source", .data = "same\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, index_move);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, index_move);
    var remove_context = RemoveIndexHookContext{ .path = "source" };
    var index_hooks = RepositoryChangeTestHooks{ .after_head_resolved = .{
        .context = &remove_context,
        .run = RemoveIndexHookContext.run,
    } };
    const index_independent = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = index_move,
        .environment = &environment,
        .path = "source",
        .source_bytes = "same\n",
    }, &index_hooks);
    defer index_independent.deinit(std.testing.allocator);
    try std.testing.expect(index_independent == .unchanged);

    try runTestGit(io, &.{ "git", "add", "source" }, index_move);
    var rewrite_context = RewriteWorktreeHookContext{ .path = "source", .bytes = "new live bytes\n" };
    var worktree_hooks = RepositoryChangeTestHooks{ .after_blob_loaded = .{
        .context = &rewrite_context,
        .run = RewriteWorktreeHookContext.run,
    } };
    const snapshot_independent = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = index_move,
        .environment = &environment,
        .path = "source",
        .source_bytes = "same\n",
    }, &worktree_hooks);
    defer snapshot_independent.deinit(std.testing.allocator);
    try std.testing.expect(snapshot_independent == .unchanged);
}

test "repository change backend normalizes checkout EOL and keeps ident on its logical row" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try runTestGit(io, &.{ "git", "config", "core.autocrlf", "true" }, work);
    try work.writeFile(io, .{ .sub_path = ".gitattributes", .data = "eol.txt text eol=crlf\nident.txt ident\n" });
    try work.writeFile(io, .{ .sub_path = "eol.txt", .data = "one\r\ntwo\r\n" });
    try work.writeFile(io, .{ .sub_path = "ident.txt", .data = "$Id$\nkeep\n" });
    try runTestGit(io, &.{ "git", "add", ".gitattributes", "eol.txt", "ident.txt" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);

    var eol_unchanged = try repositoryChangeMapForTest(work, "eol.txt", "one\r\ntwo\r\n", "/tmp");
    defer eol_unchanged.deinit(std.testing.allocator);
    try std.testing.expect(eol_unchanged.isEmpty());
    var eol_changed = try repositoryChangeMapForTest(work, "eol.txt", "one\r\nchanged\r\n", "/tmp");
    defer eol_changed.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, eol_changed.row(1));
    try std.testing.expectEqual(repository_change_map.Kind.none, eol_changed.row(0));

    try work.deleteFile(io, "ident.txt");
    try runTestGit(io, &.{ "git", "checkout", "--", "ident.txt" }, work);
    const ident_bytes = try work.readFileAlloc(io, "ident.txt", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(ident_bytes);
    var ident = try repositoryChangeMapForTest(work, "ident.txt", ident_bytes, "/tmp");
    defer ident.deinit(std.testing.allocator);
    try std.testing.expectEqual(repository_change_map.Kind.modified, ident.row(0));
    try std.testing.expectEqual(repository_change_map.Kind.none, ident.row(1));
}

test "repository change success is gated on cleanup and error paths remove private inputs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "temp-base", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const temp_base = try tmp.dir.realPathFileAlloc(io, "temp-base", std.testing.allocator);
    defer std.testing.allocator.free(temp_base);

    inline for (.{
        .{ .token = "cleanup-patch", .bytes = "changed\n" },
        .{ .token = "cleanup-unchanged", .bytes = "old\n" },
    }) |fixture| {
        var hooks = RepositoryChangeTestHooks{
            .temp_name_token = fixture.token,
            .force_cleanup_failure = true,
        };
        const result = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .environment = &environment,
            .path = "source",
            .source_bytes = fixture.bytes,
            .temp_base_path = temp_base,
        }, &hooks);
        defer result.deinit(std.testing.allocator);
        switch (result) {
            .failed_static => |message| try std.testing.expectEqualStrings("Repository comparison cleanup failed", message),
            else => return error.ExpectedCleanupFailure,
        }
        const retained_name = try std.fmt.allocPrint(std.testing.allocator, "gitframe-change-{s}-0", .{fixture.token});
        defer std.testing.allocator.free(retained_name);
        const retained_path = try std.fmt.allocPrint(std.testing.allocator, "temp-base/{s}", .{retained_name});
        defer std.testing.allocator.free(retained_path);
        const retained = try tmp.dir.statFile(io, retained_path, .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.directory, retained.kind);
        var base_for_cleanup = try tmp.dir.openDir(io, "temp-base", .{});
        defer base_for_cleanup.close(io);
        try base_for_cleanup.deleteTree(io, retained_name);
    }

    var collision_base = try tmp.dir.openDir(io, "temp-base", .{});
    defer collision_base.close(io);
    try collision_base.createDir(io, "gitframe-change-collision-0", .fromMode(0o700));
    var collision_hooks = RepositoryChangeTestHooks{ .temp_name_token = "collision" };
    const collision_result = try loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &collision_hooks);
    defer collision_result.deinit(std.testing.allocator);
    try std.testing.expect(collision_result == .patch);
    try collision_base.deleteTree(io, "gitframe-change-collision-0");

    var open_hooks = RepositoryChangeTestHooks{ .fail_temp_open = true, .temp_name_token = "open-failure" };
    try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &open_hooks));

    inline for (.{ RepositoryChangeWriteTarget.head, RepositoryChangeWriteTarget.current }) |write_failure| {
        var write_hooks = RepositoryChangeTestHooks{ .fail_write = write_failure, .temp_name_token = @tagName(write_failure) };
        try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .environment = &environment,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = temp_base,
        }, &write_hooks));
    }
    inline for (.{ @as(usize, 5), @as(usize, 6) }) |command_index| {
        var command_hooks = RepositoryChangeTestHooks{ .fail_command_at = command_index, .temp_name_token = if (command_index == 5) "diff-failure" else "post-attr-failure" };
        try std.testing.expectError(error.SpawnFailed, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
            .cwd = work,
            .environment = &environment,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = temp_base,
        }, &command_hooks));
    }
    var limit_hooks = RepositoryChangeTestHooks{
        .limit_command_at = 5,
        .forced_stdout_limit = 1,
        .temp_name_token = "output-limit",
    };
    try std.testing.expectError(error.StreamTooLong, loadGitRepositoryFileChangeWithHooks(std.testing.allocator, io, .{
        .cwd = work,
        .environment = &environment,
        .path = "source",
        .source_bytes = "changed\n",
        .temp_base_path = temp_base,
    }, &limit_hooks));

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

const RepositoryChangeAllocationFixture = struct {
    io: std.Io,
    cwd: std.Io.Dir,
    environment: *const git_command.LocalGitEnvironment,
    temp_base_path: []const u8,

    fn exercise(allocator: std.mem.Allocator, fixture: *@This()) !void {
        var hooks = RepositoryChangeTestHooks{ .temp_name_token = "allocation" };
        const result = try loadGitRepositoryFileChangeWithHooks(allocator, fixture.io, .{
            .cwd = fixture.cwd,
            .environment = fixture.environment,
            .path = "source",
            .source_bytes = "changed\n",
            .temp_base_path = fixture.temp_base_path,
        }, &hooks);
        defer result.deinit(allocator);
        if (result != .patch) return error.ExpectedPatch;
    }
};

test "repository change backend releases private inputs at every allocation failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "work", .default_dir);
    try tmp.dir.createDir(io, "temp-base", .default_dir);
    var work = try tmp.dir.openDir(io, "work", .{});
    defer work.close(io);
    try runTestGit(io, &.{ "git", "init", "--initial-branch=main" }, work);
    try work.writeFile(io, .{ .sub_path = "source", .data = "old\n" });
    try runTestGit(io, &.{ "git", "add", "source" }, work);
    try runTestGit(io, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" }, work);
    const temp_base = try tmp.dir.realPathFileAlloc(io, "temp-base", std.testing.allocator);
    defer std.testing.allocator.free(temp_base);
    var environment = try testingLocalGitEnvironment(std.testing.allocator);
    defer environment.deinit();
    var fixture = RepositoryChangeAllocationFixture{
        .io = io,
        .cwd = work,
        .environment = &environment,
        .temp_base_path = temp_base,
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, RepositoryChangeAllocationFixture.exercise, .{&fixture});

    var base = try tmp.dir.openDir(io, "temp-base", .{ .iterate = true });
    defer base.close(io);
    var iterator = base.iterate();
    try std.testing.expect(try iterator.next(io) == null);
}

fn trimLineEnd(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, "\r\n");
}

fn freeRunResult(allocator: std.mem.Allocator, result: std.process.RunResult) void {
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn gitOutputAlloc(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    errdefer freeRunResult(std.testing.allocator, result);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            std.testing.allocator.free(result.stderr);
            return result.stdout;
        },
        else => {},
    }
    freeRunResult(std.testing.allocator, result);
    return error.GitCommandFailed;
}

fn runTestGit(io: std.Io, argv: []const []const u8, cwd: std.Io.Dir) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer freeRunResult(std.testing.allocator, result);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.GitCommandFailed;
}
