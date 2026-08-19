//! Process adapter for the target-only `gitframe review-target` command.
//!
//! Argument admission and JSON/exit mapping live here; Git object resolution
//! remains owned by `git.committed_review.resolveTarget` and no later review
//! operation is reachable from this module.

const std = @import("std");
const codec = @import("codec.zig");
const limits = @import("limits.zig");
const target_mod = @import("target.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const root_capability = @import("../repo/root_capability.zig");

/// Raw byte cap for each repository/source/base/head option value.
pub const max_argument_bytes: usize = 4096;
/// Complete success JSON line cap, including its terminating LF.
pub const max_success_bytes: usize = 2 * 1024;
/// Complete error JSON line cap, including its terminating LF.
pub const max_error_bytes: usize = 4 * 1024;

/// Complete stdout terminal for one helper invocation.
///
/// `bytes` is allocator-owned canonical JSON ending in one LF. The caller
/// must keep it intact until publication and release it with `deinit`.
pub const CommandOutput = struct {
    /// Process exit allocated by the versioned target error taxonomy.
    exit_code: u8,
    bytes: []u8,

    /// Release the canonical JSON line allocation.
    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const ParsedArguments = struct {
    repository: []const u8,
    source_kind: target_mod.SourceKind,
    base: []const u8,
    head: []const u8,
};

const ArgumentResult = union(enum) {
    parsed: ParsedArguments,
    failure: Failure,
};

const Resolver = struct {
    context: ?*anyopaque = null,
    call: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: git_command.DirectoryContext,
        input: git_review.TargetInput,
    ) std.mem.Allocator.Error!git_review.TargetResolutionResult,
};

const Failure = struct {
    exit_code: u8,
    code: []const u8,
    message: []const u8,
};

const BuildError = std.mem.Allocator.Error || error{CapacityExceeded};

/// Resolve exactly one explicit target and return its versioned command
/// terminal. `arguments` starts after the `review-target` command token.
pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
) std.mem.Allocator.Error!CommandOutput {
    return executeWithResolver(allocator, io, environment_map, arguments, .{ .call = resolveCore });
}

/// Execute the target command and publish its one-line terminal to `stdout`.
/// Output transport failure is returned to the executable for exit 70.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    stdout_file: std.Io.File,
) !u8 {
    var output = executeAlloc(allocator, io, environment_map, arguments) catch {
        return writeEmergency(stdout_file, io);
    };
    defer output.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(output.bytes);
    try writer.interface.flush();
    return output.exit_code;
}

fn executeWithResolver(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    resolver: Resolver,
) std.mem.Allocator.Error!CommandOutput {
    const parsed = switch (parseArguments(arguments)) {
        .parsed => |value| value,
        .failure => |failure| return errorOutputAlloc(allocator, failure),
    };

    var root = root_capability.RootCapability.openCanonical(parsed.repository) catch
        return errorOutputAlloc(allocator, invalidRepository());
    defer root.deinit();

    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorOutputAlloc(allocator, internalFailure()),
    };
    defer environment.deinit();

    const result = try resolver.call(resolver.context, allocator, io, .{
        .cwd = root.dir(),
        .environment = &environment,
    }, .{
        .source_kind = parsed.source_kind,
        .base = parsed.base,
        .head = parsed.head,
    });
    return switch (result) {
        .target => |target| successOutputAlloc(allocator, &target) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.CapacityExceeded => errorOutputAlloc(allocator, internalFailure()),
        },
        .failure => |failure| errorOutputAlloc(allocator, resolutionFailure(failure)),
    };
}

fn parseArguments(arguments: []const []const u8) ArgumentResult {
    var repository: ?[]const u8 = null;
    var source_kind: ?target_mod.SourceKind = null;
    var base: ?[]const u8 = null;
    var head: ?[]const u8 = null;

    var index: usize = 0;
    while (index < arguments.len) {
        const option = arguments[index];
        if (index + 1 >= arguments.len) return .{ .failure = invalidArguments() };
        const value = arguments[index + 1];
        if (value.len == 0 or value.len > max_argument_bytes or value[0] == '-') {
            return .{ .failure = invalidArguments() };
        }
        if (std.mem.eql(u8, option, "--repository")) {
            if (repository != null) return .{ .failure = invalidArguments() };
            repository = value;
        } else if (std.mem.eql(u8, option, "--source-kind")) {
            if (source_kind != null) return .{ .failure = invalidArguments() };
            if (!std.mem.eql(u8, value, "branch_range")) {
                return .{ .failure = unsupportedSourceKind() };
            }
            source_kind = .branch_range;
        } else if (std.mem.eql(u8, option, "--base")) {
            if (base != null) return .{ .failure = invalidArguments() };
            base = value;
        } else if (std.mem.eql(u8, option, "--head")) {
            if (head != null) return .{ .failure = invalidArguments() };
            head = value;
        } else {
            return .{ .failure = invalidArguments() };
        }
        index += 2;
    }

    if (repository == null or source_kind == null or base == null or head == null) {
        return .{ .failure = invalidArguments() };
    }
    return .{ .parsed = .{
        .repository = repository.?,
        .source_kind = source_kind.?,
        .base = base.?,
        .head = head.?,
    } };
}

fn successOutputAlloc(
    allocator: std.mem.Allocator,
    target: *const target_mod.CommittedReviewTarget,
) BuildError!CommandOutput {
    target.validate() catch return error.CapacityExceeded;
    const storage = try allocator.alloc(u8, max_success_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch return error.CapacityExceeded;
    stringify.objectField("schema_version") catch return error.CapacityExceeded;
    stringify.write(limits.schema_version) catch return error.CapacityExceeded;
    stringify.objectField("status") catch return error.CapacityExceeded;
    stringify.write("ok") catch return error.CapacityExceeded;
    stringify.objectField("target") catch return error.CapacityExceeded;
    codec.writeTarget(&stringify, target) catch return error.CapacityExceeded;
    stringify.endObject() catch return error.CapacityExceeded;
    writer.writeByte('\n') catch return error.CapacityExceeded;
    return .{
        .exit_code = 0,
        .bytes = try allocator.realloc(storage, writer.buffered().len),
    };
}

fn errorOutputAlloc(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!CommandOutput {
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"status\":\"error\",\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}\n",
        .{ failure.code, failure.message },
    );
    std.debug.assert(bytes.len <= max_error_bytes);
    return .{ .exit_code = failure.exit_code, .bytes = bytes };
}

fn resolveCore(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: git_command.DirectoryContext,
    input: git_review.TargetInput,
) std.mem.Allocator.Error!git_review.TargetResolutionResult {
    return git_review.resolveTarget(allocator, io, directory, input);
}

fn resolutionFailure(failure: git_review.TargetResolutionFailure) Failure {
    return switch (failure) {
        .invalid_repository => invalidRepository(),
        .unsupported_object_format => .{ .exit_code = 3, .code = "unsupported_object_format", .message = "repository object format is not supported" },
        .base_unsupported_commitish => .{ .exit_code = 2, .code = "unsupported_base_commitish", .message = "base commit-ish is not supported" },
        .head_unsupported_commitish => .{ .exit_code = 2, .code = "unsupported_head_commitish", .message = "head commit-ish is not supported" },
        .base_unresolved => .{ .exit_code = 3, .code = "unresolved_base", .message = "base could not be resolved" },
        .head_unresolved => .{ .exit_code = 3, .code = "unresolved_head", .message = "head could not be resolved" },
        .base_ambiguous => .{ .exit_code = 3, .code = "ambiguous_base", .message = "base resolves ambiguously" },
        .head_ambiguous => .{ .exit_code = 3, .code = "ambiguous_head", .message = "head resolves ambiguously" },
        .base_non_commit_object => .{ .exit_code = 3, .code = "non_commit_base", .message = "base does not resolve to a commit" },
        .head_non_commit_object => .{ .exit_code = 3, .code = "non_commit_head", .message = "head does not resolve to a commit" },
        .base_object_unavailable => .{ .exit_code = 3, .code = "object_unavailable_base", .message = "base object is unavailable" },
        .head_object_unavailable => .{ .exit_code = 3, .code = "object_unavailable_head", .message = "head object is unavailable" },
        .no_merge_base => .{ .exit_code = 4, .code = "no_merge_base", .message = "base and head have no merge base" },
        .ambiguous_merge_base => .{ .exit_code = 4, .code = "ambiguous_merge_base", .message = "base and head have multiple best merge bases" },
        .target_graph_unavailable => .{ .exit_code = 3, .code = "target_graph_unavailable", .message = "target commit graph is unavailable" },
        .git_command_failed => .{ .exit_code = 5, .code = "git_command_failed", .message = "target Git command failed" },
    };
}

fn invalidArguments() Failure {
    return .{ .exit_code = 2, .code = "invalid_arguments", .message = "review-target arguments are invalid" };
}

fn unsupportedSourceKind() Failure {
    return .{ .exit_code = 2, .code = "unsupported_source_kind", .message = "source kind is not supported" };
}

fn invalidRepository() Failure {
    return .{ .exit_code = 3, .code = "invalid_repository", .message = "repository path is unavailable" };
}

fn internalFailure() Failure {
    return .{ .exit_code = 70, .code = "internal_error", .message = "review-target could not complete" };
}

fn writeEmergency(stdout_file: std.Io.File, io: std.Io) !u8 {
    var buffer: [256]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(
        "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"review-target could not complete\"}}\n",
    );
    try writer.interface.flush();
    return 70;
}

fn testTarget() target_mod.CommittedReviewTarget {
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = target_mod.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000") catch unreachable,
        .head_oid = target_mod.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111") catch unreachable,
        .diff_base_oid = target_mod.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000") catch unreachable,
    };
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_error_bytes));
}

fn readFixtureMatrix(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(64 * 1024));
}

fn runTestProcess(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer {
        std.testing.allocator.free(result.stdout);
        std.testing.allocator.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.TestProcessFailed;
}

fn expectTarget(result: git_review.TargetResolutionResult) !target_mod.CommittedReviewTarget {
    return switch (result) {
        .target => |target| target,
        .failure => error.ExpectedTarget,
    };
}

fn expectedSuccessAlloc(
    allocator: std.mem.Allocator,
    target: target_mod.CommittedReviewTarget,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{{\"object_format\":\"{s}\",\"source_kind\":\"branch_range\",\"base_oid\":\"{s}\",\"head_oid\":\"{s}\",\"diff_base_oid\":\"{s}\"}}}}\n",
        .{
            if (target.object_format == .sha1) "sha1" else "sha256",
            target.base_oid.slice(),
            target.head_oid.slice(),
            target.diff_base_oid.slice(),
        },
    );
}

test "review-target requires its exact four-option namespace" {
    var output = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{"--help"});
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), output.exit_code);
    const invalid_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/target/invalid-arguments.json",
    );
    defer std.testing.allocator.free(invalid_fixture);
    try std.testing.expectEqualStrings(invalid_fixture, output.bytes);

    const duplicate = parseArguments(&.{
        "--repository",  "/tmp/repo",    "--repository", "/tmp/other",
        "--source-kind", "branch_range", "--base",       "main",
        "--head",        "HEAD",
    });
    try std.testing.expect(duplicate == .failure);
    const option_value = parseArguments(&.{
        "--repository", "/tmp/repo", "--source-kind", "branch_range",
        "--base",       "--help",    "--head",        "HEAD",
    });
    try std.testing.expect(option_value == .failure);

    var unsupported = try executeAlloc(std.testing.allocator, std.testing.io, null, &.{
        "--repository", "/tmp/repo", "--source-kind", "history",
        "--base",       "main",      "--head",        "HEAD",
    });
    defer unsupported.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), unsupported.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, unsupported.bytes, "\"code\":\"unsupported_source_kind\"") != null);
}

test "review-target success invokes only one target resolver and uses canonical target JSON" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repository = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);

    const RecordingResolver = struct {
        calls: usize = 0,
        saw_base: bool = false,
        saw_head: bool = false,

        fn call(
            opaque_context: ?*anyopaque,
            _: std.mem.Allocator,
            _: std.Io,
            _: git_command.DirectoryContext,
            input: git_review.TargetInput,
        ) std.mem.Allocator.Error!git_review.TargetResolutionResult {
            const self: *@This() = @ptrCast(@alignCast(opaque_context.?));
            self.calls += 1;
            self.saw_base = std.mem.eql(u8, input.base, "main");
            self.saw_head = std.mem.eql(u8, input.head, "HEAD");
            return .{ .target = testTarget() };
        }
    };
    var recorder: RecordingResolver = .{};
    var output = try executeWithResolver(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{
            "--repository", repository, "--source-kind", "branch_range",
            "--base",       "main",     "--head",        "HEAD",
        },
        .{ .context = &recorder, .call = RecordingResolver.call },
    );
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expect(recorder.saw_base and recorder.saw_head);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    const success_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/target/success.json",
    );
    defer std.testing.allocator.free(success_fixture);
    try std.testing.expectEqualStrings(success_fixture, output.bytes);

    const io = std.testing.io;
    try runTestProcess(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try runTestProcess(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestProcess(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try runTestProcess(io, tmp.dir, &.{ "git", "switch", "-c", "feature" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\nhead\n" });
    try runTestProcess(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestProcess(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });

    var core_environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer core_environment.deinit();
    const core_target = try expectTarget(try git_review.resolveTarget(
        std.testing.allocator,
        io,
        .{ .cwd = tmp.dir, .environment = &core_environment },
        .{ .source_kind = .branch_range, .base = "refs/heads/main", .head = "HEAD" },
    ));
    const expected = try expectedSuccessAlloc(std.testing.allocator, core_target);
    defer std.testing.allocator.free(expected);

    var core_output = try executeAlloc(
        std.testing.allocator,
        io,
        null,
        &.{
            "--repository", repository,        "--source-kind", "branch_range",
            "--base",       "refs/heads/main", "--head",        "HEAD",
        },
    );
    defer core_output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), core_output.exit_code);
    try std.testing.expectEqualStrings(expected, core_output.bytes);

    const source = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "src/committed_review/target_command.zig",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(source);
    const test_boundary = std.mem.indexOf(u8, source, "fn testTarget()") orelse return error.MissingTestBoundary;
    const production = source[0..test_boundary];
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, production, "git_review.resolveTarget("));
    const forbidden_operations = [_][]const u8{
        "git_review.computeAheadDisplay(",
        "git_review.materializeCommittedProjection(",
        "git_review.resolveCodeAnchor(",
        "git_command.run",
        "std.process.run",
        "\"rev-list\"",
        "\"diff\"",
        "\"ls-tree\"",
        "\"blob\"",
    };
    for (forbidden_operations) |operation| {
        try std.testing.expect(std.mem.indexOf(u8, production, operation) == null);
    }
}

test "review-target preserves operation-specific failure exits" {
    const cases = [_]Failure{
        invalidArguments(),
        unsupportedSourceKind(),
        resolutionFailure(.base_unsupported_commitish),
        resolutionFailure(.head_unsupported_commitish),
        resolutionFailure(.invalid_repository),
        resolutionFailure(.unsupported_object_format),
        resolutionFailure(.base_unresolved),
        resolutionFailure(.head_unresolved),
        resolutionFailure(.base_ambiguous),
        resolutionFailure(.head_ambiguous),
        resolutionFailure(.base_non_commit_object),
        resolutionFailure(.head_non_commit_object),
        resolutionFailure(.base_object_unavailable),
        resolutionFailure(.head_object_unavailable),
        resolutionFailure(.no_merge_base),
        resolutionFailure(.ambiguous_merge_base),
        resolutionFailure(.target_graph_unavailable),
        resolutionFailure(.git_command_failed),
        internalFailure(),
    };
    const exits = [_]u8{ 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 3, 5, 70 };
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(std.testing.allocator);
    for (cases, exits) |failure, exit_code| {
        try std.testing.expectEqual(exit_code, failure.exit_code);
        var output = try errorOutputAlloc(std.testing.allocator, failure);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(exit_code, output.exit_code);
        try std.testing.expect(output.bytes.len <= max_error_bytes);
        try std.testing.expectEqual(@as(u8, '\n'), output.bytes[output.bytes.len - 1]);
        try std.testing.expect(std.mem.indexOfScalar(u8, output.bytes[0 .. output.bytes.len - 1], '\n') == null);
        try actual.appendSlice(std.testing.allocator, output.bytes);
    }
    const error_fixture = try readFixtureMatrix(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/target/errors.jsonl",
    );
    defer std.testing.allocator.free(error_fixture);
    try std.testing.expectEqualStrings(error_fixture, actual.items);

    var no_merge_base = try errorOutputAlloc(std.testing.allocator, resolutionFailure(.no_merge_base));
    defer no_merge_base.deinit(std.testing.allocator);
    const no_merge_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/target/no-merge-base.json",
    );
    defer std.testing.allocator.free(no_merge_fixture);
    try std.testing.expectEqualStrings(no_merge_fixture, no_merge_base.bytes);
}
