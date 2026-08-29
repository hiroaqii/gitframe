//! Strict no-write process adapter for `review-result-read`.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const limits = @import("../committed_review/limits.zig");
const wire = @import("read_command_wire.zig");
const store_service = @import("store_service.zig");

pub const max_request_bytes = wire.max_request_bytes;
pub const max_repository_path_bytes = wire.max_repository_path_bytes;
pub const max_header_bytes = wire.max_terminal_bytes;
pub const max_result_bytes = limits.max_artifact_bytes;
pub const Request = wire.Request;
pub const ParsedRequest = wire.ParsedRequest;
pub const ParseError = wire.ParseError;
pub const parseRequest = wire.parseRequest;

pub const CommandOutput = struct {
    exit_code: u8,
    header: []u8,
    completed: ?store_service.CompletedResult,

    pub fn payload(self: *const CommandOutput) ?[]const u8 {
        return if (self.completed) |*value| value.result_bytes else null;
    }

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        if (self.completed) |*value| value.deinit(allocator);
        allocator.free(self.header);
        self.* = undefined;
    }
};

const SuccessStatus = enum { pending, completed };

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    arguments: []const []const u8,
    request_bytes: []const u8,
) std.mem.Allocator.Error!CommandOutput {
    if (arguments.len != 0) return errorOutputAlloc(allocator, .{
        .exit_code = 64,
        .code = "invalid_arguments",
        .message = "review-result-read accepts no arguments",
    });
    var parsed = parseRequest(allocator, request_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSchema => errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "unsupported_schema",
            .message = "request schema version is not supported",
        }),
        error.InvalidRequest => errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "invalid_request",
            .message = "result read request is invalid",
        }),
    };
    defer parsed.deinit();
    var result = try store_service.readExactResult(
        allocator,
        io,
        environment_map,
        parsed.value.repository_path,
        parsed.value.review_id,
        parsed.value.expected,
    );
    defer result.deinit(allocator);
    return switch (result) {
        .pending => |*identity| .{
            .exit_code = 0,
            .header = try successHeaderAlloc(allocator, .pending, identity, null),
            .completed = null,
        },
        .completed => |*completed| blk: {
            if (!validCompletedResult(completed)) {
                break :blk errorOutputAlloc(allocator, wire.failureTerminal(.artifact_invalid));
            }
            const header = try successHeaderAlloc(
                allocator,
                .completed,
                &completed.identity,
                completed,
            );
            const owned = completed.*;
            result = .{ .failure = .io_failed };
            break :blk .{ .exit_code = 0, .header = header, .completed = owned };
        },
        .failure => |failure| errorOutputAlloc(allocator, wire.failureTerminal(failure)),
    };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    arguments: []const []const u8,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
) !u8 {
    if (arguments.len != 0) {
        var output = errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "invalid_arguments",
            .message = "review-result-read accepts no arguments",
        }) catch return writeEmergency(stdout_file, io);
        defer output.deinit(allocator);
        try writeOutput(stdout_file, io, &output);
        return output.exit_code;
    }
    var read_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(io, &read_buffer);
    const request_bytes = reader.interface.allocRemaining(allocator, .limited(max_request_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return writeEmergency(stdout_file, io),
        else => {
            var output = errorOutputAlloc(allocator, .{
                .exit_code = 64,
                .code = "invalid_request",
                .message = "result read request is invalid",
            }) catch return writeEmergency(stdout_file, io);
            defer output.deinit(allocator);
            try writeOutput(stdout_file, io, &output);
            return output.exit_code;
        },
    };
    defer allocator.free(request_bytes);
    var output = executeAlloc(allocator, io, environment_map, arguments, request_bytes) catch
        return writeEmergency(stdout_file, io);
    defer output.deinit(allocator);
    try writeOutput(stdout_file, io, &output);
    return output.exit_code;
}

fn validCompletedResult(completed: *const store_service.CompletedResult) bool {
    return validResultSize(completed.result_bytes.len) and
        committed_review.Sha256Digest.hash(completed.result_bytes).eql(completed.result_sha256);
}

fn validResultSize(size: usize) bool {
    return size > 0 and size <= max_result_bytes;
}

fn successHeaderAlloc(
    allocator: std.mem.Allocator,
    status: SuccessStatus,
    identity: *const store_service.ResultIdentity,
    completed: ?*const store_service.CompletedResult,
) std.mem.Allocator.Error![]u8 {
    const storage = try allocator.alloc(u8, max_header_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    wire.tryField(&stringify, "status", @tagName(status));
    wire.tryField(&stringify, "schema_version", limits.schema_version);
    stringify.objectField("review_repository_id") catch unreachable;
    const repository_id = identity.review_repository_id.canonical();
    stringify.write(&repository_id) catch unreachable;
    stringify.objectField("review_id") catch unreachable;
    const review_id = identity.review_id.canonical();
    stringify.write(&review_id) catch unreachable;
    stringify.objectField("target") catch unreachable;
    wire.writeTarget(&stringify, &identity.target);
    stringify.objectField("findings_sha256") catch unreachable;
    const findings_digest = identity.findings_sha256.canonical();
    stringify.write(&findings_digest) catch unreachable;
    wire.tryField(&stringify, "finding_count", identity.finding_count);
    if (completed) |value| {
        stringify.objectField("result_sha256") catch unreachable;
        const result_digest = value.result_sha256.canonical();
        stringify.write(&result_digest) catch unreachable;
        wire.tryField(&stringify, "result_size", value.result_bytes.len);
    }
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return allocator.realloc(storage, writer.buffered().len);
}

fn errorOutputAlloc(
    allocator: std.mem.Allocator,
    failure: wire.Failure,
) std.mem.Allocator.Error!CommandOutput {
    const line = try wire.errorOutputAlloc(allocator, failure);
    return .{ .exit_code = line.exit_code, .header = line.bytes, .completed = null };
}

fn writeOutput(file: std.Io.File, io: std.Io, output: *const CommandOutput) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(output.header);
    if (output.payload()) |bytes| try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeEmergency(file: std.Io.File, io: std.Io) !u8 {
    var buffer: [256]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll("{\"status\":\"error\",\"schema_version\":1,\"code\":\"out_of_memory\",\"message\":\"review-result-read ran out of memory\"}\n");
    try writer.interface.flush();
    return 70;
}

fn fixtureIdentity() !store_service.ResultIdentity {
    const base_oid = try committed_review.ObjectId.parse(.sha1, "0000000000000000000000000000000000000000");
    return .{
        .review_repository_id = try committed_review.ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000"),
        .review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000"),
        .target = .{
            .object_format = .sha1,
            .source_kind = .branch_range,
            .base_oid = base_oid,
            .head_oid = try committed_review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111"),
            .diff_base_oid = base_oid,
        },
        .finding_count = 3,
        .findings_sha256 = try committed_review.Sha256Digest.parse("sha256:cffe9be3582f69252a0ac6b4a45b92f9ac2e37a44c98c8142e6c2d3a969d2327"),
    };
}

fn readFixture(allocator: std.mem.Allocator, name: []const u8, limit: usize) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "testdata/ai-review-result-reader-v1/{s}", .{name});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(limit));
}

test "review-result-read reuses the strict exact read request parser" {
    const canonical = try readFixture(std.testing.allocator, "request.json", max_request_bytes);
    defer std.testing.allocator.free(canonical);
    var parsed = try parseRequest(std.testing.allocator, canonical);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/repo", parsed.value.repository_path);
    try std.testing.expect(parsed.value.review_id.eql((try fixtureIdentity()).review_id));
    try std.testing.expect(parsed.value.expected == null);
}

test "review-result-read pending and completed headers and payload are exact" {
    const allocator = std.testing.allocator;
    const identity = try fixtureIdentity();
    const expected_pending = try readFixture(allocator, "pending-header.json", max_header_bytes);
    defer allocator.free(expected_pending);
    const pending = try successHeaderAlloc(allocator, .pending, &identity, null);
    defer allocator.free(pending);
    try std.testing.expectEqualStrings(expected_pending, pending);

    const result_bytes = try readFixture(allocator, "result.json", max_result_bytes);
    defer allocator.free(result_bytes);
    var parsed_result = try committed_review.RevisionReviewResult.parseStrict(allocator, result_bytes);
    defer parsed_result.deinit();
    try std.testing.expectEqual(committed_review.ReviewResultValue.needs_changes, parsed_result.value.result);
    try std.testing.expectEqualStrings("要修正です。\n二行目", parsed_result.value.summary.?);
    try std.testing.expectEqual(@as(usize, 3), parsed_result.value.finding_dispositions.len);
    try std.testing.expectEqual(committed_review.FindingDispositionValue.accepted, parsed_result.value.finding_dispositions[0].disposition);
    try std.testing.expectEqual(committed_review.FindingDispositionValue.dismissed, parsed_result.value.finding_dispositions[1].disposition);
    try std.testing.expectEqual(committed_review.FindingDispositionValue.unreviewed, parsed_result.value.finding_dispositions[2].disposition);
    try std.testing.expectEqual(@as(usize, 1), parsed_result.value.anchored_notes.len);
    try std.testing.expectEqualStrings("確認してください。\n詳細", parsed_result.value.anchored_notes[0].body);
    const canonical_result = try parsed_result.value.writeCanonical(allocator);
    defer allocator.free(canonical_result);
    try std.testing.expectEqualStrings(result_bytes, canonical_result);
    const result_digest = committed_review.Sha256Digest.hash(result_bytes);
    const completed: store_service.CompletedResult = .{
        .identity = identity,
        .result_sha256 = result_digest,
        .result_bytes = result_bytes,
    };
    try std.testing.expect(validCompletedResult(&completed));
    const expected_completed = try readFixture(allocator, "completed-header.json", max_header_bytes);
    defer allocator.free(expected_completed);
    const header = try successHeaderAlloc(allocator, .completed, &identity, &completed);
    defer allocator.free(header);
    try std.testing.expectEqualStrings(expected_completed, header);
    try std.testing.expectEqual(result_bytes.len, completed.result_bytes.len);
    try std.testing.expectEqualStrings(result_bytes, completed.result_bytes);

    const owned_header = try allocator.dupe(u8, header);
    const owned_payload = allocator.dupe(u8, result_bytes) catch |err| {
        allocator.free(owned_header);
        return err;
    };
    var output: CommandOutput = .{
        .exit_code = 0,
        .header = owned_header,
        .completed = .{
            .identity = identity,
            .result_sha256 = result_digest,
            .result_bytes = owned_payload,
        },
    };
    defer output.deinit(allocator);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stdout = try tmp.dir.createFile(std.testing.io, "stdout", .{ .read = true });
    defer stdout.close(std.testing.io);
    try writeOutput(stdout, std.testing.io, &output);
    var frame: [2048]u8 = undefined;
    const frame_len = try stdout.readPositionalAll(std.testing.io, &frame, 0);
    try std.testing.expectEqual(header.len + result_bytes.len, frame_len);
    try std.testing.expectEqualStrings(header, frame[0..header.len]);
    try std.testing.expectEqualStrings(result_bytes, frame[header.len..frame_len]);
}

test "review-result-read result payload bound is exact and hash-bound" {
    const identity = try fixtureIdentity();
    const digest = committed_review.Sha256Digest.hash("x");
    var completed: store_service.CompletedResult = .{
        .identity = identity,
        .result_sha256 = digest,
        .result_bytes = @constCast("x"),
    };
    try std.testing.expect(validCompletedResult(&completed));
    try std.testing.expect(validResultSize(max_result_bytes));
    try std.testing.expect(!validResultSize(max_result_bytes + 1));
    completed.result_bytes = @constCast("");
    try std.testing.expect(!validCompletedResult(&completed));
    completed.result_bytes = @constCast("y");
    try std.testing.expect(!validCompletedResult(&completed));
}

test "review-result-read argument request and schema terminals are exact" {
    const allocator = std.testing.allocator;
    var invalid_arguments = try executeAlloc(allocator, std.testing.io, null, &.{"unexpected"}, "");
    defer invalid_arguments.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 64), invalid_arguments.exit_code);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"schema_version\":1,\"code\":\"invalid_arguments\",\"message\":\"review-result-read accepts no arguments\"}\n", invalid_arguments.header);
    try std.testing.expect(invalid_arguments.payload() == null);

    var invalid_request = try executeAlloc(allocator, std.testing.io, null, &.{}, "{}");
    defer invalid_request.deinit(allocator);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"schema_version\":1,\"code\":\"invalid_request\",\"message\":\"result read request is invalid\"}\n", invalid_request.header);

    var unsupported_schema = try executeAlloc(
        allocator,
        std.testing.io,
        null,
        &.{},
        "{\"schema_version\":2,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}",
    );
    defer unsupported_schema.deinit(allocator);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"schema_version\":1,\"code\":\"unsupported_schema\",\"message\":\"request schema version is not supported\"}\n", unsupported_schema.header);

    const semantic_failures = [_]store_service.ReadFailure{
        .expected_mismatch,
        .artifact_invalid,
        .review_not_found,
        .target_unavailable,
        .store_unavailable,
        .unsupported_platform,
        .unsupported_filesystem,
        .repository_invalid,
        .git_failed,
        .store_invalid,
        .binding_invalid,
        .io_failed,
        .root_changed,
        .binding_changed,
        .artifact_changed,
        .concurrent_conflict,
    };
    for (semantic_failures) |failure| {
        const terminal = wire.failureTerminal(failure);
        var output = try errorOutputAlloc(allocator, terminal);
        defer output.deinit(allocator);
        try std.testing.expectEqual(terminal.exit_code, output.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, output.header, "{\"status\":\"error\",\"schema_version\":1,\"code\":\""));
        try std.testing.expectEqual(@as(u8, '\n'), output.header[output.header.len - 1]);
        try std.testing.expect(output.payload() == null);
    }
}
