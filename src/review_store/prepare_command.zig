//! Installed strict process adapter for `review-store-prepare`.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const limits = @import("../committed_review/limits.zig");
const projection_command = @import("../committed_review/projection_command.zig");
const strict = @import("../committed_review/strict_json.zig");
const store_service = @import("../ai_review/store_service.zig");

pub const max_request_bytes: usize = 8 * 1024;
pub const max_terminal_bytes: usize = 4 * 1024;

pub const Request = struct {
    repository_path: []const u8,
};

pub const ParsedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
        self.* = undefined;
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

const Failure = struct {
    exit_code: u8,
    code: []const u8,
    message: []const u8,
};

pub fn parseRequest(allocator: std.mem.Allocator, bytes: []const u8) ParseError!ParsedRequest {
    if (bytes.len == 0 or bytes.len > max_request_bytes) return error.InvalidRequest;
    const document = if (bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else bytes;
    if (document.len == 0 or document[document.len - 1] != '}') return error.InvalidRequest;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = strict.Parser.init(arena.allocator(), document);
    defer parser.deinit();
    parser.beginObject() catch |err| return mapParseError(err);
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var repository_path: ?[]const u8 = null;
    while (parser.nextObjectKey() catch |err| return mapParseError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict.markSeen(&seen, 0) catch |err| return mapParseError(err);
            schema_version = parser.unsigned(u64) catch |err| return mapParseError(err);
        } else if (std.mem.eql(u8, key, "repository")) {
            strict.markSeen(&seen, 1) catch |err| return mapParseError(err);
            repository_path = projection_command.parseRepository(&parser) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidRequest,
            };
        } else return error.InvalidRequest;
    }
    strict.requireFields(seen, 0b11) catch |err| return mapParseError(err);
    parser.endDocument() catch |err| return mapParseError(err);
    if (schema_version.? != limits.schema_version) return error.UnsupportedSchema;
    return .{ .arena = arena, .value = .{ .repository_path = repository_path.? } };
}

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
        .message = "review-store-prepare accepts no arguments",
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
            .message = "prepare request is invalid",
        }),
    };
    defer parsed.deinit();
    const result = try store_service.prepare(
        allocator,
        io,
        environment_map,
        parsed.value.repository_path,
    );
    return switch (result) {
        .success => |success| successOutputAlloc(allocator, success),
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
            .message = "review-store-prepare accepts no arguments",
        });
        defer output.deinit(allocator);
        try writeOutput(stdout_file, io, output.bytes);
        return output.exit_code;
    }
    var read_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(io, &read_buffer);
    const request_bytes = reader.interface.allocRemaining(allocator, .limited(max_request_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return writeEmergency(stdout_file, io),
        else => {
            var output = try errorOutputAlloc(allocator, .{
                .exit_code = 64,
                .code = "invalid_request",
                .message = "prepare request is invalid",
            });
            defer output.deinit(allocator);
            try writeOutput(stdout_file, io, output.bytes);
            return output.exit_code;
        },
    };
    defer allocator.free(request_bytes);
    var output = executeAlloc(allocator, io, environment_map, arguments, request_bytes) catch {
        return writeEmergency(stdout_file, io);
    };
    defer output.deinit(allocator);
    try writeOutput(stdout_file, io, output.bytes);
    return output.exit_code;
}

fn successOutputAlloc(
    allocator: std.mem.Allocator,
    success: store_service.PrepareSuccess,
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
    const repository_id = success.review_repository_id.canonical();
    stringify.write(&repository_id) catch unreachable;
    stringify.objectField("review_id") catch unreachable;
    const review_id = success.review_id.canonical();
    stringify.write(&review_id) catch unreachable;
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return .{ .exit_code = 0, .bytes = try allocator.realloc(storage, writer.buffered().len) };
}

fn errorOutputAlloc(
    allocator: std.mem.Allocator,
    failure: Failure,
) std.mem.Allocator.Error!CommandOutput {
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

fn failureTerminal(failure: store_service.PublicationFailure) Failure {
    return switch (failure) {
        .store_unavailable => .{ .exit_code = 69, .code = "store_unavailable", .message = "Review Store is unavailable" },
        .unsupported_platform => .{ .exit_code = 69, .code = "unsupported_platform", .message = "Review Store writer is unsupported on this platform" },
        .unsupported_filesystem => .{ .exit_code = 69, .code = "unsupported_filesystem", .message = "Review Store filesystem is unsupported" },
        .store_invalid => .{ .exit_code = 74, .code = "store_invalid", .message = "Review Store authority is invalid" },
        .repository_invalid => .{ .exit_code = 74, .code = "repository_invalid", .message = "repository path is invalid" },
        .git_failed => .{ .exit_code = 74, .code = "git_failed", .message = "repository identity could not be resolved" },
        .io_failed => .{ .exit_code = 74, .code = "io_failed", .message = "Review Store prepare failed" },
        .concurrent_conflict => .{ .exit_code = 75, .code = "concurrent_conflict", .message = "Review Store authority changed concurrently" },
        .binding_mismatch => .{ .exit_code = 75, .code = "binding_mismatch", .message = "repository binding does not match" },
        .invalid_artifact => .{ .exit_code = 64, .code = "invalid_artifact", .message = "artifact is invalid" },
        .target_unavailable => .{ .exit_code = 66, .code = "target_unavailable", .message = "target objects are unavailable" },
        .duplicate_review_id => .{ .exit_code = 73, .code = "duplicate_review_id", .message = "review ID already exists" },
    };
}

fn mapParseError(err: strict.ParseError) ParseError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest;
}

fn writeOutput(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn writeEmergency(file: std.Io.File, io: std.Io) !u8 {
    try writeOutput(file, io, "{\"status\":\"error\",\"schema_version\":1,\"code\":\"out_of_memory\",\"message\":\"review-store-prepare could not complete\"}\n");
    return 70;
}

test "review run publication prepare request shares the lossless repository path wire" {
    const bytes = "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}}\n";
    var parsed = try parseRequest(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/tmp/repo", parsed.value.repository_path);
    try std.testing.expectError(error.InvalidRequest, parseRequest(
        std.testing.allocator,
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv=\"}}",
    ));
    try std.testing.expectError(error.UnsupportedSchema, parseRequest(
        std.testing.allocator,
        "{\"schema_version\":2,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}}",
    ));

    const raw_path = "/tmp/non-utf8-\xff";
    const encoded = try std.testing.allocator.alloc(
        u8,
        std.base64.url_safe_no_pad.Encoder.calcSize(raw_path.len),
    );
    defer std.testing.allocator.free(encoded);
    const encoded_path = std.base64.url_safe_no_pad.Encoder.encode(encoded, raw_path);
    const raw_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}}}}",
        .{encoded_path},
    );
    defer std.testing.allocator.free(raw_request);
    var raw_parsed = try parseRequest(std.testing.allocator, raw_request);
    defer raw_parsed.deinit();
    try std.testing.expectEqualSlices(u8, raw_path, raw_parsed.value.repository_path);

    const invalid_paths = [_][]const u8{ "", "relative", "/tmp/with\x00nul" };
    for (invalid_paths) |invalid_path| {
        const invalid_encoded = try std.testing.allocator.alloc(
            u8,
            std.base64.url_safe_no_pad.Encoder.calcSize(invalid_path.len),
        );
        defer std.testing.allocator.free(invalid_encoded);
        const invalid_value = std.base64.url_safe_no_pad.Encoder.encode(invalid_encoded, invalid_path);
        const invalid_request = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}}}}",
            .{invalid_value},
        );
        defer std.testing.allocator.free(invalid_request);
        try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, invalid_request));
    }
    const oversized_path = try std.testing.allocator.alloc(u8, projection_command.max_repository_path_bytes + 1);
    defer std.testing.allocator.free(oversized_path);
    @memset(oversized_path, 'a');
    oversized_path[0] = '/';
    const oversized_encoded = try std.testing.allocator.alloc(
        u8,
        std.base64.url_safe_no_pad.Encoder.calcSize(oversized_path.len),
    );
    defer std.testing.allocator.free(oversized_encoded);
    const oversized_value = std.base64.url_safe_no_pad.Encoder.encode(oversized_encoded, oversized_path);
    const oversized_request = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}}}}",
        .{oversized_value},
    );
    defer std.testing.allocator.free(oversized_request);
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, oversized_request));

    var invalid_arguments = try executeAlloc(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{"--help"},
        bytes,
    );
    defer invalid_arguments.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 64), invalid_arguments.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, invalid_arguments.bytes, "\"code\":\"invalid_arguments\"") != null);
}
