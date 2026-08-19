//! Strict request and binary-safe response adapter for `review-projection`.
//!
//! This module validates a complete pinned target and explicit repository,
//! then delegates exactly once to the shared committed projection operation.
//! It neither resolves revision expressions nor owns Git diff policy.

const std = @import("std");
const codec = @import("codec.zig");
const limits = @import("limits.zig");
const strict = @import("strict_json.zig");
const target_mod = @import("target.zig");
const target_command = @import("target_command.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const root_capability = @import("../repo/root_capability.zig");

/// Exact stdin cap including the optional final LF.
pub const max_request_bytes: usize = 8 * 1024;
/// Maximum decoded absolute repository-path bytes.
pub const max_repository_path_bytes: usize = 4096;
/// Success header cap including its framing LF.
pub const max_success_header_bytes: usize = 2 * 1024;
/// Error header cap including its final LF and required EOF.
pub const max_error_header_bytes: usize = 4 * 1024;

/// Explicit repository authority decoded from the request. `path_bytes`
/// borrows the enclosing `ParsedRequest` arena and is an absolute POSIX path.
pub const ProjectionRepository = struct {
    path_bytes: []const u8,
};

/// Structurally admitted process request. Repository bytes borrow the
/// `ParsedRequest` arena; the target is a complete portable value copy.
pub const ProjectionCommandRequest = struct {
    /// Must equal the committed-review schema version; aliases are rejected.
    schema_version: u64,
    repository: ProjectionRepository,
    target: target_mod.CommittedReviewTarget,
};

/// Arena owner for every slice decoded while parsing one request.
pub const ParsedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: ProjectionCommandRequest,

    /// Release all decoded repository/token slices in `value`.
    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Request-admission terminals kept distinct for the process exit/code map.
pub const RequestParseError = error{
    OutOfMemory,
    InvalidRequest,
    UnsupportedSchemaVersion,
    InvalidTarget,
};

/// Typed content of the line-delimited frame header before serialization.
/// The union shape prevents a success target/size from coexisting with an
/// error code and prevents an error header from claiming patch bytes.
pub const ProjectionFrameHeader = union(enum) {
    ok: struct {
        schema_version: u64,
        target: target_mod.CommittedReviewTarget,
        /// Exact raw payload octets following the header LF, in `0..16 MiB`.
        patch_size: usize,
    },
    failure: struct {
        schema_version: u64,
        code: []const u8,
        message: []const u8,
    },
};

/// Complete framed command terminal. `header_bytes` always ends in LF.
/// `patch_bytes`, when present, is the exact allocation transferred from the
/// shared materializer and begins immediately after that LF on stdout.
pub const CommandOutput = struct {
    /// Process exit allocated by the projection command taxonomy.
    exit_code: u8,
    /// Allocator-owned canonical header including its terminating LF.
    header_bytes: []u8,
    /// Allocator-owned exact payload on success; absent for every error.
    patch_bytes: ?[]u8 = null,

    /// Release both header and optional transferred patch allocation.
    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.header_bytes);
        if (self.patch_bytes) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

const Materializer = struct {
    context: ?*anyopaque = null,
    call: *const fn (
        context: ?*anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: git_command.DirectoryContext,
        target: git_review.CommittedReviewTarget,
    ) std.mem.Allocator.Error!git_review.ProjectionResult,
};

const Failure = struct {
    exit_code: u8,
    code: []const u8,
    message: []const u8,
};

const BuildError = std.mem.Allocator.Error || error{CapacityExceeded};
const FrameAdmissionError = std.mem.Allocator.Error || error{InvalidFrame};

/// Parse one bounded JSON request. Field order and JSON whitespace are not
/// authority; unknown/duplicate fields and any trailing second document are
/// rejected, with at most one final LF outside the document.
pub fn parseRequest(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) RequestParseError!ParsedRequest {
    if (bytes.len == 0 or bytes.len > max_request_bytes) return error.InvalidRequest;
    const document = if (bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else bytes;
    if (document.len == 0 or document[document.len - 1] != '}') return error.InvalidRequest;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = strict.Parser.init(arena.allocator(), document);
    defer parser.deinit();

    parser.beginObject() catch |err| return mapRequestError(err);
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var repository_path: ?[]const u8 = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    while (parser.nextObjectKey() catch |err| return mapRequestError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict.markSeen(&seen, 0) catch |err| return mapRequestError(err);
            schema_version = parser.unsigned(u64) catch |err| return mapRequestError(err);
        } else if (std.mem.eql(u8, key, "repository")) {
            strict.markSeen(&seen, 1) catch |err| return mapRequestError(err);
            repository_path = try parseRepository(&parser);
        } else if (std.mem.eql(u8, key, "target")) {
            strict.markSeen(&seen, 2) catch |err| return mapRequestError(err);
            target = codec.parseTarget(&parser) catch |err| return mapTargetError(err);
        } else {
            return error.InvalidRequest;
        }
    }
    strict.requireFields(seen, 0b111) catch |err| return mapRequestError(err);
    parser.endDocument() catch |err| return mapRequestError(err);
    strict.validateSchemaVersion(schema_version.?) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSchemaVersion => error.UnsupportedSchemaVersion,
        else => error.InvalidRequest,
    };
    target.?.validate() catch return error.InvalidTarget;
    return .{ .arena = arena, .value = .{
        .schema_version = schema_version.?,
        .repository = .{ .path_bytes = repository_path.? },
        .target = target.?,
    } };
}

/// Materialize one complete request and return an all-or-nothing frame.
/// `arguments` starts after the `review-projection` command token.
pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    request_bytes: []const u8,
) std.mem.Allocator.Error!CommandOutput {
    return executeWithMaterializer(
        allocator,
        io,
        environment_map,
        arguments,
        request_bytes,
        .{ .call = materializeCore },
    );
}

/// Read stdin, complete the frame in memory, then write header and payload.
/// A write failure is returned so the executable can terminate with exit 70;
/// no alternate payload or raw-diff fallback is attempted.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
) !u8 {
    if (arguments.len != 0) {
        var invalid = try errorOutputAlloc(allocator, invalidArguments());
        defer invalid.deinit(allocator);
        try writeOutput(stdout_file, io, &invalid);
        return invalid.exit_code;
    }

    var read_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(io, &read_buffer);
    const request_bytes = reader.interface.allocRemaining(allocator, .limited(max_request_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return writeEmergency(stdout_file, io),
        else => {
            var invalid = try errorOutputAlloc(allocator, invalidRequest());
            defer invalid.deinit(allocator);
            try writeOutput(stdout_file, io, &invalid);
            return invalid.exit_code;
        },
    };
    defer allocator.free(request_bytes);

    var output = executeAlloc(allocator, io, environment_map, arguments, request_bytes) catch {
        return writeEmergency(stdout_file, io);
    };
    defer output.deinit(allocator);
    try writeOutput(stdout_file, io, &output);
    return output.exit_code;
}

fn executeWithMaterializer(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    request_bytes: []const u8,
    materializer: Materializer,
) std.mem.Allocator.Error!CommandOutput {
    if (arguments.len != 0) return errorOutputAlloc(allocator, invalidArguments());

    var parsed = parseRequest(allocator, request_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidRequest => errorOutputAlloc(allocator, invalidRequest()),
        error.UnsupportedSchemaVersion => errorOutputAlloc(allocator, .{
            .exit_code = 2,
            .code = "unsupported_schema_version",
            .message = "request schema version is not supported",
        }),
        error.InvalidTarget => errorOutputAlloc(allocator, .{
            .exit_code = 2,
            .code = "invalid_target",
            .message = "request target is invalid",
        }),
    };
    defer parsed.deinit();

    var root = root_capability.RootCapability.openCanonical(parsed.value.repository.path_bytes) catch
        return errorOutputAlloc(allocator, invalidRepository());
    defer root.deinit();
    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorOutputAlloc(allocator, internalFailure()),
    };
    defer environment.deinit();

    const result = try materializer.call(materializer.context, allocator, io, .{
        .cwd = root.dir(),
        .environment = &environment,
    }, parsed.value.target);
    return switch (result) {
        .projection => |projection_value| successFromProjection(allocator, parsed.value.target, projection_value),
        .failure => |failure| errorOutputAlloc(allocator, switch (failure) {
            .projection_too_large => .{
                .exit_code = 4,
                .code = "projection_too_large",
                .message = "committed projection exceeds the 16 MiB limit",
            },
            .projection_git_command_failed => .{
                .exit_code = 5,
                .code = "projection_git_command_failed",
                .message = "committed projection could not be materialized",
            },
        }),
    };
}

fn successFromProjection(
    allocator: std.mem.Allocator,
    request_target: target_mod.CommittedReviewTarget,
    projection_value: git_review.CommittedDiffProjection,
) std.mem.Allocator.Error!CommandOutput {
    var projection = projection_value;
    var owns_projection = true;
    errdefer if (owns_projection) projection.deinit(allocator);
    if (!projection.target.eql(&request_target) or projection.patch_bytes.len > limits.max_projection_bytes) {
        projection.deinit(allocator);
        owns_projection = false;
        return errorOutputAlloc(allocator, internalFailure());
    }
    const header = successHeaderAlloc(allocator, &projection.target, projection.patch_bytes.len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CapacityExceeded => {
            projection.deinit(allocator);
            owns_projection = false;
            return errorOutputAlloc(allocator, internalFailure());
        },
    };
    owns_projection = false;
    return .{
        .exit_code = 0,
        .header_bytes = header,
        .patch_bytes = projection.patch_bytes,
    };
}

fn parseRepository(parser: *strict.Parser) RequestParseError![]const u8 {
    parser.beginObject() catch |err| return mapRequestError(err);
    var seen: u32 = 0;
    var encoded: ?[]const u8 = null;
    while (parser.nextObjectKey() catch |err| return mapRequestError(err)) |key| {
        if (!std.mem.eql(u8, key, "path_bytes_b64")) return error.InvalidRequest;
        strict.markSeen(&seen, 0) catch |err| return mapRequestError(err);
        encoded = parser.string() catch |err| return mapRequestError(err);
    }
    strict.requireFields(seen, 0b1) catch |err| return mapRequestError(err);
    const decoded = strict.decodeRawPath(parser.allocator, encoded.?) catch |err| return mapRequestError(err);
    if (decoded.len == 0 or decoded.len > max_repository_path_bytes or decoded[0] != '/') {
        return error.InvalidRequest;
    }
    return decoded;
}

fn mapRequestError(err: strict.ParseError) RequestParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequest,
    };
}

fn mapTargetError(err: codec.ParseError) RequestParseError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidTarget,
    };
}

fn admitSuccessFrame(
    allocator: std.mem.Allocator,
    request_target: target_mod.CommittedReviewTarget,
    exit_code: u8,
    frame: []const u8,
) FrameAdmissionError![]const u8 {
    if (exit_code != 0) return error.InvalidFrame;
    const lf = std.mem.indexOfScalar(u8, frame, '\n') orelse return error.InvalidFrame;
    if (lf + 1 > max_success_header_bytes) return error.InvalidFrame;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = strict.Parser.init(arena.allocator(), frame[0..lf]);
    defer parser.deinit();
    parser.beginObject() catch |err| return mapFrameError(err);
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var status_ok = false;
    var target: ?target_mod.CommittedReviewTarget = null;
    var patch_size: ?usize = null;
    while (parser.nextObjectKey() catch |err| return mapFrameError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict.markSeen(&seen, 0) catch |err| return mapFrameError(err);
            schema_version = parser.unsigned(u64) catch |err| return mapFrameError(err);
        } else if (std.mem.eql(u8, key, "status")) {
            strict.markSeen(&seen, 1) catch |err| return mapFrameError(err);
            status_ok = std.mem.eql(u8, parser.string() catch |err| return mapFrameError(err), "ok");
        } else if (std.mem.eql(u8, key, "target")) {
            strict.markSeen(&seen, 2) catch |err| return mapFrameError(err);
            target = codec.parseTarget(&parser) catch |err| return mapFrameError(err);
        } else if (std.mem.eql(u8, key, "patch_size")) {
            strict.markSeen(&seen, 3) catch |err| return mapFrameError(err);
            patch_size = parser.unsigned(usize) catch |err| return mapFrameError(err);
        } else {
            return error.InvalidFrame;
        }
    }
    strict.requireFields(seen, 0b1111) catch |err| return mapFrameError(err);
    parser.endDocument() catch |err| return mapFrameError(err);
    strict.validateSchemaVersion(schema_version.?) catch return error.InvalidFrame;
    if (!status_ok or !target.?.eql(&request_target)) return error.InvalidFrame;
    if (patch_size.? > limits.max_projection_bytes) return error.InvalidFrame;
    const payload = frame[lf + 1 ..];
    if (payload.len != patch_size.?) return error.InvalidFrame;
    return payload;
}

fn admitErrorFrame(allocator: std.mem.Allocator, exit_code: u8, frame: []const u8) FrameAdmissionError!void {
    if (exit_code == 0 or frame.len == 0 or frame.len > max_error_header_bytes) return error.InvalidFrame;
    if (frame[frame.len - 1] != '\n' or std.mem.indexOfScalar(u8, frame[0 .. frame.len - 1], '\n') != null) {
        return error.InvalidFrame;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = strict.Parser.init(arena.allocator(), frame[0 .. frame.len - 1]);
    defer parser.deinit();
    parser.beginObject() catch |err| return mapFrameError(err);
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var status_error = false;
    var code: ?[]const u8 = null;
    while (parser.nextObjectKey() catch |err| return mapFrameError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict.markSeen(&seen, 0) catch |err| return mapFrameError(err);
            schema_version = parser.unsigned(u64) catch |err| return mapFrameError(err);
        } else if (std.mem.eql(u8, key, "status")) {
            strict.markSeen(&seen, 1) catch |err| return mapFrameError(err);
            status_error = std.mem.eql(u8, parser.string() catch |err| return mapFrameError(err), "error");
        } else if (std.mem.eql(u8, key, "error")) {
            strict.markSeen(&seen, 2) catch |err| return mapFrameError(err);
            code = try parseFrameErrorObject(&parser);
        } else {
            return error.InvalidFrame;
        }
    }
    strict.requireFields(seen, 0b111) catch |err| return mapFrameError(err);
    parser.endDocument() catch |err| return mapFrameError(err);
    strict.validateSchemaVersion(schema_version.?) catch return error.InvalidFrame;
    if (!status_error or projectionErrorExit(code.?) != exit_code) return error.InvalidFrame;
}

fn parseFrameErrorObject(parser: *strict.Parser) FrameAdmissionError![]const u8 {
    parser.beginObject() catch |err| return mapFrameError(err);
    var seen: u32 = 0;
    var code: ?[]const u8 = null;
    var message: ?[]const u8 = null;
    while (parser.nextObjectKey() catch |err| return mapFrameError(err)) |key| {
        if (std.mem.eql(u8, key, "code")) {
            strict.markSeen(&seen, 0) catch |err| return mapFrameError(err);
            code = parser.string() catch |err| return mapFrameError(err);
        } else if (std.mem.eql(u8, key, "message")) {
            strict.markSeen(&seen, 1) catch |err| return mapFrameError(err);
            message = parser.string() catch |err| return mapFrameError(err);
        } else {
            return error.InvalidFrame;
        }
    }
    strict.requireFields(seen, 0b11) catch |err| return mapFrameError(err);
    strict.validateText(message.?, 512, false) catch return error.InvalidFrame;
    return code.?;
}

fn projectionErrorExit(code: []const u8) u8 {
    if (std.mem.eql(u8, code, "invalid_arguments") or
        std.mem.eql(u8, code, "invalid_request") or
        std.mem.eql(u8, code, "unsupported_schema_version") or
        std.mem.eql(u8, code, "invalid_target")) return 2;
    if (std.mem.eql(u8, code, "invalid_repository")) return 3;
    if (std.mem.eql(u8, code, "projection_too_large")) return 4;
    if (std.mem.eql(u8, code, "projection_git_command_failed")) return 5;
    if (std.mem.eql(u8, code, "internal_error")) return 70;
    return 0;
}

fn mapFrameError(err: anyerror) FrameAdmissionError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
}

fn successHeaderAlloc(
    allocator: std.mem.Allocator,
    target: *const target_mod.CommittedReviewTarget,
    patch_size: usize,
) BuildError![]u8 {
    if (patch_size > limits.max_projection_bytes) return error.CapacityExceeded;
    return headerAlloc(allocator, .{ .ok = .{
        .schema_version = limits.schema_version,
        .target = target.*,
        .patch_size = patch_size,
    } });
}

fn headerAlloc(allocator: std.mem.Allocator, header: ProjectionFrameHeader) BuildError![]u8 {
    const maximum = switch (header) {
        .ok => max_success_header_bytes,
        .failure => max_error_header_bytes,
    };
    const storage = try allocator.alloc(u8, maximum);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch return error.CapacityExceeded;
    stringify.objectField("schema_version") catch return error.CapacityExceeded;
    switch (header) {
        .ok => |success| {
            stringify.write(success.schema_version) catch return error.CapacityExceeded;
            stringify.objectField("status") catch return error.CapacityExceeded;
            stringify.write("ok") catch return error.CapacityExceeded;
            stringify.objectField("target") catch return error.CapacityExceeded;
            codec.writeTarget(&stringify, &success.target) catch return error.CapacityExceeded;
            stringify.objectField("patch_size") catch return error.CapacityExceeded;
            stringify.write(success.patch_size) catch return error.CapacityExceeded;
        },
        .failure => |failure| {
            stringify.write(failure.schema_version) catch return error.CapacityExceeded;
            stringify.objectField("status") catch return error.CapacityExceeded;
            stringify.write("error") catch return error.CapacityExceeded;
            stringify.objectField("error") catch return error.CapacityExceeded;
            stringify.beginObject() catch return error.CapacityExceeded;
            stringify.objectField("code") catch return error.CapacityExceeded;
            stringify.write(failure.code) catch return error.CapacityExceeded;
            stringify.objectField("message") catch return error.CapacityExceeded;
            stringify.write(failure.message) catch return error.CapacityExceeded;
            stringify.endObject() catch return error.CapacityExceeded;
        },
    }
    stringify.endObject() catch return error.CapacityExceeded;
    writer.writeByte('\n') catch return error.CapacityExceeded;
    return allocator.realloc(storage, writer.buffered().len);
}

fn errorOutputAlloc(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!CommandOutput {
    const header = headerAlloc(allocator, .{ .failure = .{
        .schema_version = limits.schema_version,
        .code = failure.code,
        .message = failure.message,
    } }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CapacityExceeded => unreachable,
    };
    return .{ .exit_code = failure.exit_code, .header_bytes = header };
}

fn materializeCore(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: git_command.DirectoryContext,
    target: git_review.CommittedReviewTarget,
) std.mem.Allocator.Error!git_review.ProjectionResult {
    return git_review.materializeCommittedProjection(allocator, io, directory, target);
}

fn writeOutput(stdout_file: std.Io.File, io: std.Io, output: *const CommandOutput) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(output.header_bytes);
    if (output.patch_bytes) |patch| try writer.interface.writeAll(patch);
    try writer.interface.flush();
}

fn invalidArguments() Failure {
    return .{ .exit_code = 2, .code = "invalid_arguments", .message = "review-projection accepts no arguments" };
}

fn invalidRequest() Failure {
    return .{ .exit_code = 2, .code = "invalid_request", .message = "projection request is invalid" };
}

fn invalidRepository() Failure {
    return .{ .exit_code = 3, .code = "invalid_repository", .message = "repository path is unavailable" };
}

fn internalFailure() Failure {
    return .{ .exit_code = 70, .code = "internal_error", .message = "review-projection could not complete" };
}

fn writeEmergency(stdout_file: std.Io.File, io: std.Io) !u8 {
    var buffer: [256]u8 = undefined;
    var writer = stdout_file.writerStreaming(io, &buffer);
    try writer.interface.writeAll(
        "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"review-projection could not complete\"}}\n",
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

fn encodePathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(path.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, path);
    return encoded;
}

fn requestAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return requestForTargetAlloc(allocator, path, testTarget());
}

fn requestForTargetAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    target: target_mod.CommittedReviewTarget,
) ![]u8 {
    const encoded = try encodePathAlloc(allocator, path);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"target\":{{\"object_format\":\"{s}\",\"source_kind\":\"branch_range\",\"base_oid\":\"{s}\",\"head_oid\":\"{s}\",\"diff_base_oid\":\"{s}\"}}}}\n",
        .{
            encoded,
            if (target.object_format == .sha1) "sha1" else "sha256",
            target.base_oid.slice(),
            target.head_oid.slice(),
            target.diff_base_oid.slice(),
        },
    );
}

fn expectedTargetSuccessAlloc(
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

fn readFixture(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_error_header_bytes));
}

fn runTestGit(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) !void {
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
    return error.GitCommandFailed;
}

fn testGitOutput(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    if (result.term == .exited and result.term.exited == 0) {
        std.testing.allocator.free(result.stderr);
        return result.stdout;
    }
    std.testing.allocator.free(result.stdout);
    std.testing.allocator.free(result.stderr);
    return error.GitCommandFailed;
}

fn testOutputLine(bytes: []const u8) ![]const u8 {
    if (bytes.len < 2 or bytes[bytes.len - 1] != '\n') return error.ExpectedSingleLine;
    const line = bytes[0 .. bytes.len - 1];
    if (std.mem.indexOfAny(u8, line, "\r\n") != null) return error.ExpectedSingleLine;
    return line;
}

fn inventoryLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn collectObjectInventory(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    prefix: []const u8,
    lines: *std.ArrayList([]u8),
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(relative);
        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                try collectObjectInventory(allocator, io, child, relative, lines);
            },
            .file => {
                const bytes = try dir.readFileAlloc(io, entry.name, allocator, .limited(64 * 1024 * 1024));
                defer allocator.free(bytes);
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                const hex = std.fmt.bytesToHex(digest, .lower);
                const line = try std.fmt.allocPrint(allocator, "{s}\tfile\t{d}\t{s}\n", .{ relative, bytes.len, &hex });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
            else => {
                const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ relative, @tagName(entry.kind) });
                errdefer allocator.free(line);
                try lines.append(allocator, line);
            },
        }
    }
}

fn objectInventory(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir) ![]u8 {
    var objects = try cwd.openDir(io, ".git/objects", .{ .iterate = true });
    defer objects.close(io);
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |line| allocator.free(line);
        lines.deinit(allocator);
    }
    try collectObjectInventory(allocator, io, objects, "", &lines);
    std.mem.sort([]u8, lines.items, {}, inventoryLessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (lines.items) |line| try result.appendSlice(allocator, line);
    return result.toOwnedSlice(allocator);
}

fn expectTarget(result: git_review.TargetResolutionResult) !target_mod.CommittedReviewTarget {
    return switch (result) {
        .target => |target| target,
        .failure => error.ExpectedTarget,
    };
}

test "projection request is strict, bounded, and owns decoded repository bytes" {
    const canonical = try requestAlloc(std.testing.allocator, "/tmp/repo");
    defer std.testing.allocator.free(canonical);
    const request_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/request.json",
    );
    defer std.testing.allocator.free(request_fixture);
    try std.testing.expectEqualStrings(request_fixture, canonical);
    var parsed = try parseRequest(std.testing.allocator, canonical);
    defer parsed.deinit();
    try std.testing.expectEqual(limits.schema_version, parsed.value.schema_version);
    try std.testing.expectEqualStrings("/tmp/repo", parsed.value.repository.path_bytes);
    try std.testing.expect(parsed.value.target.eql(&testTarget()));

    const duplicate =
        "{\"schema_version\":1,\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, duplicate));

    const unsupported =
        "{\"schema_version\":2,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}}";
    try std.testing.expectError(error.UnsupportedSchemaVersion, parseRequest(std.testing.allocator, unsupported));
    const unknown =
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"},\"extra\":true}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, unknown));
    const null_repository =
        "{\"schema_version\":1,\"repository\":null,\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, null_repository));
    const incomplete_target =
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\"}}";
    try std.testing.expectError(error.InvalidTarget, parseRequest(std.testing.allocator, incomplete_target));
    const padded_path =
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv=\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, padded_path));
    const relative_path =
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"cmVsYXRpdmU\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}}";
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, relative_path));
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, "{}{}"));
    const trailing_space = try std.testing.allocator.dupe(u8, canonical);
    defer std.testing.allocator.free(trailing_space);
    trailing_space[trailing_space.len - 1] = ' ';
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, trailing_space));

    var extra_argument = try executeAlloc(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{"--help"},
        canonical,
    );
    defer extra_argument.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), extra_argument.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, extra_argument.header_bytes, "\"code\":\"invalid_arguments\"") != null);
}

test "projection request admits exact request and repository limits only" {
    const suffix =
        "\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"}}";
    var exact_request = try std.testing.allocator.alloc(u8, max_request_bytes);
    defer std.testing.allocator.free(exact_request);
    @memset(exact_request, ' ');
    exact_request[0] = '{';
    @memcpy(exact_request[exact_request.len - suffix.len ..], suffix);
    var parsed = try parseRequest(std.testing.allocator, exact_request);
    parsed.deinit();

    const too_large_request = try std.testing.allocator.alloc(u8, max_request_bytes + 1);
    defer std.testing.allocator.free(too_large_request);
    @memcpy(too_large_request[0..max_request_bytes], exact_request);
    too_large_request[max_request_bytes] = ' ';
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, too_large_request));

    const path = try std.testing.allocator.alloc(u8, max_repository_path_bytes);
    defer std.testing.allocator.free(path);
    @memset(path, 'a');
    path[0] = '/';
    const exact_path_request = try requestAlloc(std.testing.allocator, path);
    defer std.testing.allocator.free(exact_path_request);
    var exact_path = try parseRequest(std.testing.allocator, exact_path_request);
    exact_path.deinit();

    const path_too_large = try std.testing.allocator.alloc(u8, max_repository_path_bytes + 1);
    defer std.testing.allocator.free(path_too_large);
    @memset(path_too_large, 'a');
    path_too_large[0] = '/';
    const large_path_request = try requestAlloc(std.testing.allocator, path_too_large);
    defer std.testing.allocator.free(large_path_request);
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, large_path_request));
}

test "review-projection frames exact materializer bytes and calls it once" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const repository = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const request = try requestAlloc(std.testing.allocator, repository);
    defer std.testing.allocator.free(request);

    const RecordingMaterializer = struct {
        calls: usize = 0,

        fn call(
            opaque_context: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: std.Io,
            _: git_command.DirectoryContext,
            target: git_review.CommittedReviewTarget,
        ) std.mem.Allocator.Error!git_review.ProjectionResult {
            const self: *@This() = @ptrCast(@alignCast(opaque_context.?));
            self.calls += 1;
            return .{ .projection = .{
                .target = target,
                .patch_bytes = try allocator.dupe(u8, &.{ 0, 0xff, '\n', 'x' }),
            } };
        }
    };
    var recorder: RecordingMaterializer = .{};
    var output = try executeWithMaterializer(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{},
        request,
        .{ .context = &recorder, .call = RecordingMaterializer.call },
    );
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), recorder.calls);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    const success_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/success-header-4.json",
    );
    defer std.testing.allocator.free(success_fixture);
    try std.testing.expectEqualStrings(success_fixture, output.header_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, '\n', 'x' }, output.patch_bytes.?);
    try std.testing.expect(output.header_bytes.len <= max_success_header_bytes);
}

test "review-projection process adapter matches core bytes across dirty state" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.txt text\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "base\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "head\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "file.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const target = try expectTarget(try git_review.resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "HEAD~1",
        .head = "HEAD",
    }));
    var direct = try git_review.materializeCommittedProjection(std.testing.allocator, io, context, target);
    defer direct.deinit(std.testing.allocator);
    try std.testing.expect(direct == .projection);

    const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const request = try requestForTargetAlloc(std.testing.allocator, repository, target);
    defer std.testing.allocator.free(request);
    var clean = try executeAlloc(std.testing.allocator, io, null, &.{}, request);
    defer clean.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, direct.projection.patch_bytes, clean.patch_bytes.?);

    try tmp.dir.writeFile(io, .{ .sub_path = ".gitattributes", .data = "*.txt -diff\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", ".gitattributes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "dirty working tree\n" });
    try tmp.dir.createDir(io, "nested", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/.gitattributes", .data = "* binary\n" });

    var dirty = try executeAlloc(std.testing.allocator, io, null, &.{}, request);
    defer dirty.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, direct.projection.patch_bytes, dirty.patch_bytes.?);
    try std.testing.expectEqualSlices(u8, clean.patch_bytes.?, dirty.patch_bytes.?);
}

test "partial-clone two-command flow keeps target success and projection failure effect-free" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blob.txt", .data = "base blob\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "blob.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "base" });
    const base_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(base_output);
    const base_oid = try testOutputLine(base_output);
    try tmp.dir.writeFile(io, .{ .sub_path = "blob.txt", .data = "head blob\n" });
    try runTestGit(io, tmp.dir, &.{ "git", "add", "blob.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "head" });
    const head_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD" });
    defer std.testing.allocator.free(head_output);
    const head_oid = try testOutputLine(head_output);
    const blob_output = try testGitOutput(io, tmp.dir, &.{ "git", "rev-parse", "HEAD:blob.txt" });
    defer std.testing.allocator.free(blob_output);
    const blob_oid = try testOutputLine(blob_output);

    const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    const target: target_mod.CommittedReviewTarget = .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = try target_mod.ObjectId.parse(.sha1, base_oid),
        .head_oid = try target_mod.ObjectId.parse(.sha1, head_oid),
        .diff_base_oid = try target_mod.ObjectId.parse(.sha1, base_oid),
    };
    const expected_target = try expectedTargetSuccessAlloc(std.testing.allocator, target);
    defer std.testing.allocator.free(expected_target);
    var complete_target_output = try target_command.executeAlloc(
        std.testing.allocator,
        io,
        null,
        &.{
            "--repository", repository, "--source-kind", "branch_range",
            "--base",       base_oid,   "--head",        head_oid,
        },
    );
    defer complete_target_output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), complete_target_output.exit_code);
    try std.testing.expectEqualStrings(expected_target, complete_target_output.bytes);

    const missing_object = try std.fmt.allocPrint(std.testing.allocator, ".git/objects/{s}/{s}", .{ blob_oid[0..2], blob_oid[2..] });
    defer std.testing.allocator.free(missing_object);
    try tmp.dir.deleteFile(io, missing_object);
    try runTestGit(io, tmp.dir, &.{ "git", "remote", "add", "origin", "fake::missing" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "extensions.partialClone", "origin" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.promisor", "true" });
    try runTestGit(io, tmp.dir, &.{ "git", "config", "remote.origin.partialclonefilter", "blob:none" });

    try tmp.dir.createDir(io, "helpers", .default_dir);
    const helpers_path = try std.fs.path.join(std.testing.allocator, &.{ repository, "helpers" });
    defer std.testing.allocator.free(helpers_path);
    const remote_marker = try std.fs.path.join(std.testing.allocator, &.{ repository, "remote-helper-invoked" });
    defer std.testing.allocator.free(remote_marker);
    const credential_marker = try std.fs.path.join(std.testing.allocator, &.{ repository, "credential-helper-invoked" });
    defer std.testing.allocator.free(credential_marker);
    const remote_script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\nexit 1\n", .{remote_marker});
    defer std.testing.allocator.free(remote_script);
    const credential_script = try std.fmt.allocPrint(std.testing.allocator, "#!/bin/sh\nprintf invoked > '{s}'\nexit 1\n", .{credential_marker});
    defer std.testing.allocator.free(credential_script);
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/git-remote-fake", .data = remote_script });
    try tmp.dir.writeFile(io, .{ .sub_path = "helpers/credential-helper", .data = credential_script });
    try runTestGit(io, tmp.dir, &.{ "chmod", "+x", "helpers/git-remote-fake", "helpers/credential-helper" });
    const credential_path = try std.fs.path.join(std.testing.allocator, &.{ helpers_path, "credential-helper" });
    defer std.testing.allocator.free(credential_path);
    const credential_config = try std.fmt.allocPrint(std.testing.allocator, "!{s}", .{credential_path});
    defer std.testing.allocator.free(credential_config);
    try runTestGit(io, tmp.dir, &.{ "git", "config", "credential.helper", credential_config });

    var parent = std.process.Environ.Map.init(std.testing.allocator);
    defer parent.deinit();
    const helper_path_env = try std.fmt.allocPrint(std.testing.allocator, "{s}:/usr/bin:/bin", .{helpers_path});
    defer std.testing.allocator.free(helper_path_env);
    try parent.put("PATH", helper_path_env);

    const status_before = try testGitOutput(io, tmp.dir, &.{ "git", "status", "--porcelain=v2", "--untracked-files=no" });
    defer std.testing.allocator.free(status_before);
    const inventory_before = try objectInventory(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(inventory_before);

    var missing_target_output = try target_command.executeAlloc(
        std.testing.allocator,
        io,
        &parent,
        &.{
            "--repository", repository, "--source-kind", "branch_range",
            "--base",       base_oid,   "--head",        head_oid,
        },
    );
    defer missing_target_output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), missing_target_output.exit_code);
    try std.testing.expectEqualStrings(expected_target, missing_target_output.bytes);
    try std.testing.expectEqualStrings(complete_target_output.bytes, missing_target_output.bytes);
    try std.testing.expect(std.mem.indexOf(u8, missing_target_output.bytes, "patch_size") == null);

    const request = try requestForTargetAlloc(std.testing.allocator, repository, target);
    defer std.testing.allocator.free(request);
    var projection_output = try executeAlloc(std.testing.allocator, io, &parent, &.{}, request);
    defer projection_output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 5), projection_output.exit_code);
    try std.testing.expect(projection_output.patch_bytes == null);
    const failure_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/git-command-failed.json",
    );
    defer std.testing.allocator.free(failure_fixture);
    try std.testing.expectEqualStrings(failure_fixture, projection_output.header_bytes);

    const status_after = try testGitOutput(io, tmp.dir, &.{ "git", "status", "--porcelain=v2", "--untracked-files=no" });
    defer std.testing.allocator.free(status_after);
    const inventory_after = try objectInventory(std.testing.allocator, io, tmp.dir);
    defer std.testing.allocator.free(inventory_after);
    try std.testing.expectEqualSlices(u8, status_before, status_after);
    try std.testing.expectEqualSlices(u8, inventory_before, inventory_after);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "remote-helper-invoked", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "credential-helper-invoked", .{}));
}

test "projection frame admits exact sixteen MiB and keeps overflow error-only" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try runTestGit(io, tmp.dir, &.{ "git", "init", "--initial-branch=main" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "base" });
    try runTestGit(io, tmp.dir, &.{ "git", "switch", "-c", "oversized" });
    {
        const large_bytes = try std.testing.allocator.alloc(u8, limits.max_projection_bytes + 64 * 1024);
        defer std.testing.allocator.free(large_bytes);
        @memset(large_bytes, 'x');
        try tmp.dir.writeFile(io, .{ .sub_path = "large.txt", .data = large_bytes });
    }
    try runTestGit(io, tmp.dir, &.{ "git", "add", "large.txt" });
    try runTestGit(io, tmp.dir, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "oversized" });

    var environment = try git_command.LocalGitEnvironment.initFromParent(std.testing.allocator, null);
    defer environment.deinit();
    const context: git_command.DirectoryContext = .{ .cwd = tmp.dir, .environment = &environment };
    const oversized_target = try expectTarget(try git_review.resolveTarget(std.testing.allocator, io, context, .{
        .source_kind = .branch_range,
        .base = "refs/heads/main",
        .head = "HEAD",
    }));
    const expected_target = try expectedTargetSuccessAlloc(std.testing.allocator, oversized_target);
    defer std.testing.allocator.free(expected_target);
    const repository = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(repository);
    var target_output = try target_command.executeAlloc(
        std.testing.allocator,
        io,
        null,
        &.{
            "--repository", repository,        "--source-kind", "branch_range",
            "--base",       "refs/heads/main", "--head",        "HEAD",
        },
    );
    defer target_output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), target_output.exit_code);
    try std.testing.expectEqualStrings(expected_target, target_output.bytes);
    var real_projection = try git_review.materializeCommittedProjection(
        std.testing.allocator,
        io,
        context,
        oversized_target,
    );
    defer real_projection.deinit(std.testing.allocator);
    try std.testing.expectEqual(git_review.ProjectionFailure.projection_too_large, real_projection.failure);

    const request = try requestAlloc(std.testing.allocator, repository);
    defer std.testing.allocator.free(request);

    const ExactMaterializer = struct {
        fn call(
            _: ?*anyopaque,
            allocator: std.mem.Allocator,
            _: std.Io,
            _: git_command.DirectoryContext,
            target: git_review.CommittedReviewTarget,
        ) std.mem.Allocator.Error!git_review.ProjectionResult {
            const patch = try allocator.alloc(u8, limits.max_projection_bytes);
            @memset(patch, 'x');
            return .{ .projection = .{ .target = target, .patch_bytes = patch } };
        }
    };
    var exact = try executeWithMaterializer(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{},
        request,
        .{ .call = ExactMaterializer.call },
    );
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(limits.max_projection_bytes, exact.patch_bytes.?.len);
    try std.testing.expect(std.mem.indexOf(u8, exact.header_bytes, "\"patch_size\":16777216") != null);
    try std.testing.expect(exact.header_bytes.len <= max_success_header_bytes);

    const OverflowMaterializer = struct {
        fn call(
            _: ?*anyopaque,
            _: std.mem.Allocator,
            _: std.Io,
            _: git_command.DirectoryContext,
            _: git_review.CommittedReviewTarget,
        ) std.mem.Allocator.Error!git_review.ProjectionResult {
            return .{ .failure = .projection_too_large };
        }
    };
    var overflow = try executeWithMaterializer(
        std.testing.allocator,
        std.testing.io,
        null,
        &.{},
        request,
        .{ .call = OverflowMaterializer.call },
    );
    defer overflow.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 4), overflow.exit_code);
    try std.testing.expect(overflow.patch_bytes == null);
    const fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/too-large.json",
    );
    defer std.testing.allocator.free(fixture);
    try std.testing.expectEqualStrings(fixture, overflow.header_bytes);
}

test "projection frame admission rejects truncated extra and mismatched transport" {
    const target = testTarget();
    const header = try successHeaderAlloc(std.testing.allocator, &target, 4);
    defer std.testing.allocator.free(header);
    const frame = try std.mem.concat(std.testing.allocator, u8, &.{ header, &.{ 0, 0xff, '\n', 'x' } });
    defer std.testing.allocator.free(frame);
    const payload = try admitSuccessFrame(std.testing.allocator, target, 0, frame);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, '\n', 'x' }, payload);
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, target, 5, frame));
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, target, 0, frame[0 .. frame.len - 1]));

    const extra = try std.mem.concat(std.testing.allocator, u8, &.{ frame, "x" });
    defer std.testing.allocator.free(extra);
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, target, 0, extra));
    var different = target;
    different.head_oid = different.base_oid;
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, different, 0, frame));

    const zero_header = try successHeaderAlloc(std.testing.allocator, &target, 0);
    defer std.testing.allocator.free(zero_header);
    const zero_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/success-header-0.json",
    );
    defer std.testing.allocator.free(zero_fixture);
    try std.testing.expectEqualStrings(zero_fixture, zero_header);
    const zero_payload = try admitSuccessFrame(std.testing.allocator, target, 0, zero_header);
    try std.testing.expectEqual(@as(usize, 0), zero_payload.len);
    const zero_extra = try std.mem.concat(std.testing.allocator, u8, &.{ zero_header, "x" });
    defer std.testing.allocator.free(zero_extra);
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, target, 0, zero_extra));

    const success_unknown = try std.mem.concat(std.testing.allocator, u8, &.{
        header[0 .. header.len - 2],
        ",\"extra\":0}\n",
        &.{ 0, 0xff, '\n', 'x' },
    });
    defer std.testing.allocator.free(success_unknown);
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, target, 0, success_unknown));
    const success_duplicate = try std.mem.concat(std.testing.allocator, u8, &.{
        header[0 .. header.len - 2],
        ",\"patch_size\":4}\n",
        &.{ 0, 0xff, '\n', 'x' },
    });
    defer std.testing.allocator.free(success_duplicate);
    try std.testing.expectError(error.InvalidFrame, admitSuccessFrame(std.testing.allocator, target, 0, success_duplicate));

    const error_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/git-command-failed.json",
    );
    defer std.testing.allocator.free(error_fixture);
    try admitErrorFrame(std.testing.allocator, 5, error_fixture);
    try std.testing.expectError(error.InvalidFrame, admitErrorFrame(std.testing.allocator, 4, error_fixture));
    const error_extra = try std.mem.concat(std.testing.allocator, u8, &.{ error_fixture, "x" });
    defer std.testing.allocator.free(error_extra);
    try std.testing.expectError(error.InvalidFrame, admitErrorFrame(std.testing.allocator, 5, error_extra));
    const error_unknown = try std.mem.concat(std.testing.allocator, u8, &.{
        error_fixture[0 .. error_fixture.len - 2],
        ",\"extra\":0}\n",
    });
    defer std.testing.allocator.free(error_unknown);
    try std.testing.expectError(error.InvalidFrame, admitErrorFrame(std.testing.allocator, 5, error_unknown));
    const error_duplicate = try std.mem.concat(std.testing.allocator, u8, &.{
        error_fixture[0 .. error_fixture.len - 2],
        ",\"status\":\"error\"}\n",
    });
    defer std.testing.allocator.free(error_duplicate);
    try std.testing.expectError(error.InvalidFrame, admitErrorFrame(std.testing.allocator, 5, error_duplicate));
}

test "review-projection emits error-only frames for both public failures" {
    const too_large = try errorOutputAlloc(std.testing.allocator, .{
        .exit_code = 4,
        .code = "projection_too_large",
        .message = "committed projection exceeds the 16 MiB limit",
    });
    var owned_too_large = too_large;
    defer owned_too_large.deinit(std.testing.allocator);
    try std.testing.expect(owned_too_large.patch_bytes == null);
    try std.testing.expect(owned_too_large.header_bytes.len <= max_error_header_bytes);

    var failed = try errorOutputAlloc(std.testing.allocator, .{
        .exit_code = 5,
        .code = "projection_git_command_failed",
        .message = "committed projection could not be materialized",
    });
    defer failed.deinit(std.testing.allocator);
    try std.testing.expect(failed.patch_bytes == null);
    const failure_fixture = try readFixture(
        std.testing.allocator,
        "testdata/committed-review-v1/helper/projection/git-command-failed.json",
    );
    defer std.testing.allocator.free(failure_fixture);
    try std.testing.expectEqualStrings(failure_fixture, failed.header_bytes);
}

test "committed review contract records strict commands and downstream boundaries" {
    const document = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "docs/committed-review-wire-v1.md",
        std.testing.allocator,
        .limited(128 * 1024),
    );
    defer std.testing.allocator.free(document);
    const required = [_][]const u8{
        "Closed commit-ish grammar",
        "one atom without `/`",
        "--no-lazy-fetch",
        "--attr-source=<head_oid>",
        "gitframe review-target",
        "gitframe review-projection",
        "partial target",
        "#106 obtains a target",
        "#111 File/Stream",
        "future History",
        "file-level comment or review summary",
        "Automatic retargeting",
    };
    for (required) |text| try std.testing.expect(std.mem.indexOf(u8, document, text) != null);
}
