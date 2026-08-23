//! Installed strict binary-frame adapter for `review-store-publish`.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const limits = @import("../committed_review/limits.zig");
const projection_command = @import("../committed_review/projection_command.zig");
const strict_data = @import("../data/strict_json.zig");
const publication = @import("publication.zig");

const StrictParser = strict_data.Parser(.{
    .max_token_bytes = limits.max_json_token_bytes,
    .max_depth = limits.max_json_depth,
});

pub const max_header_bytes: usize = 16 * 1024;
pub const max_terminal_bytes: usize = 4 * 1024;
pub const max_frame_bytes: usize = max_header_bytes + limits.max_manifest_bytes + limits.max_artifact_bytes;

pub const ParsedFrame = struct {
    arena: std.heap.ArenaAllocator,
    repository_path: []const u8,
    review_repository_id: committed_review.ReviewRepositoryId,
    review_id: committed_review.ReviewId,
    manifest_bytes: []const u8,
    findings_bytes: []const u8,

    pub fn deinit(self: *ParsedFrame) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn request(self: *const ParsedFrame) publication.PublishRequest {
        return .{
            .repository_path = self.repository_path,
            .review_repository_id = self.review_repository_id,
            .review_id = self.review_id,
            .manifest_bytes = self.manifest_bytes,
            .findings_bytes = self.findings_bytes,
        };
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidRequest,
    UnsupportedSchema,
};

pub const CommandOutput = struct {
    exit_code: u8,
    bytes: []u8,

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Failure = struct { exit_code: u8, code: []const u8, message: []const u8 };

pub fn parseFrame(allocator: std.mem.Allocator, frame: []const u8) ParseError!ParsedFrame {
    if (frame.len == 0 or frame.len > max_frame_bytes) return error.InvalidRequest;
    const lf = std.mem.indexOfScalar(u8, frame, '\n') orelse return error.InvalidRequest;
    if (lf == 0 or lf + 1 > max_header_bytes) return error.InvalidRequest;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = StrictParser.init(arena.allocator(), frame[0..lf]);
    defer parser.deinit();
    parser.beginObject() catch |err| return mapParseError(err);
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var repository_path: ?[]const u8 = null;
    var repository_id: ?committed_review.ReviewRepositoryId = null;
    var review_id: ?committed_review.ReviewId = null;
    var manifest_size: ?usize = null;
    var findings_size: ?usize = null;
    while (parser.nextObjectKey() catch |err| return mapParseError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict_data.markSeen(&seen, 0) catch |err| return mapParseError(err);
            schema_version = parser.unsigned(u64) catch |err| return mapParseError(err);
        } else if (std.mem.eql(u8, key, "repository")) {
            strict_data.markSeen(&seen, 1) catch |err| return mapParseError(err);
            repository_path = projection_command.parseRepository(&parser) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidRequest,
            };
        } else if (std.mem.eql(u8, key, "review_repository_id")) {
            strict_data.markSeen(&seen, 2) catch |err| return mapParseError(err);
            repository_id = committed_review.ReviewRepositoryId.parse(
                parser.string() catch |err| return mapParseError(err),
            ) catch return error.InvalidRequest;
        } else if (std.mem.eql(u8, key, "review_id")) {
            strict_data.markSeen(&seen, 3) catch |err| return mapParseError(err);
            review_id = committed_review.ReviewId.parse(
                parser.string() catch |err| return mapParseError(err),
            ) catch return error.InvalidRequest;
        } else if (std.mem.eql(u8, key, "manifest_size")) {
            strict_data.markSeen(&seen, 4) catch |err| return mapParseError(err);
            manifest_size = parser.unsigned(usize) catch |err| return mapParseError(err);
        } else if (std.mem.eql(u8, key, "findings_size")) {
            strict_data.markSeen(&seen, 5) catch |err| return mapParseError(err);
            findings_size = parser.unsigned(usize) catch |err| return mapParseError(err);
        } else return error.InvalidRequest;
    }
    strict_data.requireFields(seen, 0b11_1111) catch |err| return mapParseError(err);
    parser.endDocument() catch |err| return mapParseError(err);
    if (schema_version.? != limits.schema_version) return error.UnsupportedSchema;
    if (manifest_size.? == 0 or manifest_size.? > limits.max_manifest_bytes or
        findings_size.? == 0 or findings_size.? > limits.max_artifact_bytes)
    {
        return error.InvalidRequest;
    }
    const payload_size = std.math.add(usize, manifest_size.?, findings_size.?) catch
        return error.InvalidRequest;
    if (frame.len - (lf + 1) != payload_size) return error.InvalidRequest;
    const manifest_start = lf + 1;
    const findings_start = manifest_start + manifest_size.?;
    return .{
        .arena = arena,
        .repository_path = repository_path.?,
        .review_repository_id = repository_id.?,
        .review_id = review_id.?,
        .manifest_bytes = frame[manifest_start..findings_start],
        .findings_bytes = frame[findings_start..],
    };
}

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*std.process.Environ.Map,
    arguments: []const []const u8,
    frame_bytes: []const u8,
) std.mem.Allocator.Error!CommandOutput {
    if (arguments.len != 0) return errorOutputAlloc(allocator, .{
        .exit_code = 64,
        .code = "invalid_arguments",
        .message = "review-store-publish accepts no arguments",
    });
    var parsed = parseFrame(allocator, frame_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSchema => errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "unsupported_schema",
            .message = "request schema version is not supported",
        }),
        error.InvalidRequest => errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "invalid_request",
            .message = "publish frame is invalid",
        }),
    };
    defer parsed.deinit();
    const result = try publication.publish(allocator, io, environment_map, parsed.request());
    return switch (result) {
        .success => successOutputAlloc(allocator, parsed.review_repository_id, parsed.review_id),
        .failure => |failure| errorOutputAlloc(allocator, failureTerminal(failure)),
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
        var output = try errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "invalid_arguments",
            .message = "review-store-publish accepts no arguments",
        });
        defer output.deinit(allocator);
        try writeOutput(stdout_file, io, output.bytes);
        return output.exit_code;
    }
    var read_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(io, &read_buffer);
    const frame = reader.interface.allocRemaining(allocator, .limited(max_frame_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return writeEmergency(stdout_file, io),
        else => {
            var output = try errorOutputAlloc(allocator, .{
                .exit_code = 64,
                .code = "invalid_request",
                .message = "publish frame is invalid",
            });
            defer output.deinit(allocator);
            try writeOutput(stdout_file, io, output.bytes);
            return output.exit_code;
        },
    };
    defer allocator.free(frame);
    var output = executeAlloc(allocator, io, environment_map, arguments, frame) catch {
        return writeEmergency(stdout_file, io);
    };
    defer output.deinit(allocator);
    try writeOutput(stdout_file, io, output.bytes);
    return output.exit_code;
}

fn successOutputAlloc(
    allocator: std.mem.Allocator,
    repository_id_value: committed_review.ReviewRepositoryId,
    review_id_value: committed_review.ReviewId,
) std.mem.Allocator.Error!CommandOutput {
    const storage = try allocator.alloc(u8, max_terminal_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    stringify.objectField("status") catch unreachable;
    stringify.write("ok") catch unreachable;
    stringify.objectField("schema_version") catch unreachable;
    stringify.write(limits.schema_version) catch unreachable;
    stringify.objectField("review_repository_id") catch unreachable;
    const repository_id = repository_id_value.canonical();
    stringify.write(&repository_id) catch unreachable;
    stringify.objectField("review_id") catch unreachable;
    const review_id = review_id_value.canonical();
    stringify.write(&review_id) catch unreachable;
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return .{ .exit_code = 0, .bytes = try allocator.realloc(storage, writer.buffered().len) };
}

fn errorOutputAlloc(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!CommandOutput {
    const storage = try allocator.alloc(u8, max_terminal_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    stringify.objectField("status") catch unreachable;
    stringify.write("error") catch unreachable;
    stringify.objectField("schema_version") catch unreachable;
    stringify.write(limits.schema_version) catch unreachable;
    stringify.objectField("code") catch unreachable;
    stringify.write(failure.code) catch unreachable;
    stringify.objectField("message") catch unreachable;
    stringify.write(failure.message) catch unreachable;
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return .{ .exit_code = failure.exit_code, .bytes = try allocator.realloc(storage, writer.buffered().len) };
}

fn failureTerminal(failure: publication.Failure) Failure {
    return switch (failure) {
        .invalid_artifact => .{ .exit_code = 64, .code = "invalid_artifact", .message = "manifest/findings artifacts are invalid" },
        .target_unavailable => .{ .exit_code = 66, .code = "target_unavailable", .message = "target commit objects are unavailable" },
        .store_unavailable => .{ .exit_code = 69, .code = "store_unavailable", .message = "Review Store is unavailable" },
        .unsupported_platform => .{ .exit_code = 69, .code = "unsupported_platform", .message = "Review Store writer is unsupported on this platform" },
        .unsupported_filesystem => .{ .exit_code = 69, .code = "unsupported_filesystem", .message = "Review Store filesystem is unsupported" },
        .duplicate_review_id => .{ .exit_code = 73, .code = "duplicate_review_id", .message = "review ID already exists" },
        .store_invalid => .{ .exit_code = 74, .code = "store_invalid", .message = "Review Store authority is invalid" },
        .repository_invalid => .{ .exit_code = 74, .code = "repository_invalid", .message = "repository path is invalid" },
        .git_failed => .{ .exit_code = 74, .code = "git_failed", .message = "target availability could not be verified" },
        .io_failed => .{ .exit_code = 74, .code = "io_failed", .message = "immutable Run publication failed" },
        .binding_mismatch => .{ .exit_code = 75, .code = "binding_mismatch", .message = "repository binding does not match" },
        .concurrent_conflict => .{ .exit_code = 75, .code = "concurrent_conflict", .message = "Review Store authority changed concurrently" },
    };
}

fn mapParseError(err: strict_data.ParseError) ParseError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest;
}

fn writeOutput(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeEmergency(file: std.Io.File, io: std.Io) !u8 {
    try writeOutput(file, io, "{\"status\":\"error\",\"schema_version\":1,\"code\":\"out_of_memory\",\"message\":\"review-store-publish could not complete\"}\n");
    return 70;
}

test "review run publication frame is exact bounded and binary safe" {
    const header =
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}," ++
        "\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\"," ++
        "\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"manifest_size\":2,\"findings_size\":3}\n";
    const frame = header ++ "m\xfff\x00x";
    var parsed = try parseFrame(std.testing.allocator, frame);
    defer parsed.deinit();
    try std.testing.expectEqualSlices(u8, "m\xff", parsed.manifest_bytes);
    try std.testing.expectEqualSlices(u8, "f\x00x", parsed.findings_bytes);
    try std.testing.expectError(error.InvalidRequest, parseFrame(std.testing.allocator, frame[0 .. frame.len - 1]));
    try std.testing.expectError(error.InvalidRequest, parseFrame(std.testing.allocator, frame ++ "x"));
    const unsupported_header =
        "{\"schema_version\":2,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}," ++
        "\"review_repository_id\":\"123e4567-e89b-42d3-a456-426614174000\"," ++
        "\"review_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"manifest_size\":2,\"findings_size\":3}\n";
    try std.testing.expectError(error.UnsupportedSchema, parseFrame(
        std.testing.allocator,
        unsupported_header ++ "m\xfff\x00x",
    ));
    var invalid_arguments = try executeAlloc(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{"--help"},
        frame,
    );
    defer invalid_arguments.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 64), invalid_arguments.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, invalid_arguments.bytes, "\"code\":\"invalid_arguments\"") != null);
}
