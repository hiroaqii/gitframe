//! Strict no-write process adapter for `review-store-read`.

const std = @import("std");
const committed_review = @import("../committed_review.zig");
const limits = @import("../committed_review/limits.zig");
const strict = @import("../committed_review/strict_json.zig");
const store_service = @import("store_service.zig");

pub const max_request_bytes: usize = 16 * 1024;
pub const max_repository_path_bytes: usize = 4096;
pub const max_terminal_bytes: usize = 16 * 1024;

pub const Request = struct {
    repository_path: []const u8,
    review_id: committed_review.ReviewId,
    expected: ?store_service.ExpectedPublicationIdentity,
};

pub const ParsedRequest = struct {
    arena: std.heap.ArenaAllocator,
    value: Request,

    pub fn deinit(self: *ParsedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = error{ OutOfMemory, InvalidRequest, UnsupportedSchema };

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
    var review_id: ?committed_review.ReviewId = null;
    var expected: ?store_service.ExpectedPublicationIdentity = null;
    while (parser.nextObjectKey() catch |err| return mapParseError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict.markSeen(&seen, 0) catch |err| return mapParseError(err);
            schema_version = parser.unsigned(u64) catch |err| return mapParseError(err);
        } else if (std.mem.eql(u8, key, "repository")) {
            strict.markSeen(&seen, 1) catch |err| return mapParseError(err);
            repository_path = parseRepository(&parser) catch |err| return mapParseError(err);
        } else if (std.mem.eql(u8, key, "review_id")) {
            strict.markSeen(&seen, 2) catch |err| return mapParseError(err);
            review_id = committed_review.ReviewId.parse(
                parser.string() catch |err| return mapParseError(err),
            ) catch return error.InvalidRequest;
        } else if (std.mem.eql(u8, key, "expected")) {
            strict.markSeen(&seen, 3) catch |err| return mapParseError(err);
            expected = parseExpected(&parser) catch |err| return mapParseError(err);
        } else return error.InvalidRequest;
    }
    strict.requireFields(seen, 0b0111) catch |err| return mapParseError(err);
    parser.endDocument() catch |err| return mapParseError(err);
    if (schema_version.? != limits.schema_version) return error.UnsupportedSchema;
    return .{ .arena = arena, .value = .{
        .repository_path = repository_path.?,
        .review_id = review_id.?,
        .expected = expected,
    } };
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
        .message = "review-store-read accepts no arguments",
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
            .message = "read request is invalid",
        }),
    };
    defer parsed.deinit();
    var result = try store_service.readExactIdentity(
        allocator,
        io,
        environment_map,
        parsed.value.repository_path,
        parsed.value.review_id,
        parsed.value.expected,
    );
    defer result.deinit(allocator);
    return switch (result) {
        .exact => |*exact| successOutputAlloc(allocator, exact),
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
        var output = errorOutputAlloc(allocator, .{
            .exit_code = 64,
            .code = "invalid_arguments",
            .message = "review-store-read accepts no arguments",
        }) catch return writeEmergency(stdout_file, io);
        defer output.deinit(allocator);
        try writeOutput(stdout_file, io, output.bytes);
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
                .message = "read request is invalid",
            }) catch return writeEmergency(stdout_file, io);
            defer output.deinit(allocator);
            try writeOutput(stdout_file, io, output.bytes);
            return output.exit_code;
        },
    };
    defer allocator.free(request_bytes);
    var output = executeAlloc(allocator, io, environment_map, arguments, request_bytes) catch
        return writeEmergency(stdout_file, io);
    defer output.deinit(allocator);
    try writeOutput(stdout_file, io, output.bytes);
    return output.exit_code;
}

fn parseRepository(parser: *strict.Parser) strict.ParseError![]const u8 {
    try parser.beginObject();
    var seen: u32 = 0;
    var encoded: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (!std.mem.eql(u8, key, "path_bytes_b64")) return error.UnknownField;
        try strict.markSeen(&seen, 0);
        encoded = try parser.string();
    }
    try strict.requireFields(seen, 1);
    const value = encoded.?;
    if (value.len == 0) return error.InvalidValue;
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(value) catch return error.InvalidValue;
    if (decoded_len == 0 or decoded_len > max_repository_path_bytes) return error.LimitExceeded;
    const decoded = try parser.allocator.alloc(u8, decoded_len);
    std.base64.standard.Decoder.decode(decoded, value) catch return error.InvalidValue;
    if (decoded[0] != '/' or std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidValue;
    const canonical_len = std.base64.standard.Encoder.calcSize(decoded.len);
    if (canonical_len != value.len) return error.InvalidValue;
    const canonical = try parser.allocator.alloc(u8, canonical_len);
    const written = std.base64.standard.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, written, value)) return error.InvalidValue;
    return decoded;
}

fn parseExpected(parser: *strict.Parser) strict.ParseError!store_service.ExpectedPublicationIdentity {
    try parser.beginObject();
    var seen: u32 = 0;
    var repository_id: ?committed_review.ReviewRepositoryId = null;
    var target: ?committed_review.CommittedReviewTarget = null;
    var producer: ?committed_review.Producer = null;
    var created_at: ?[]const u8 = null;
    var finding_count: ?u32 = null;
    var manifest_sha256: ?committed_review.Sha256Digest = null;
    var findings_sha256: ?committed_review.Sha256Digest = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "review_repository_id")) {
            try strict.markSeen(&seen, 0);
            repository_id = committed_review.ReviewRepositoryId.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "target")) {
            try strict.markSeen(&seen, 1);
            target = try committed_review.codec.parseTarget(parser);
        } else if (std.mem.eql(u8, key, "producer")) {
            try strict.markSeen(&seen, 2);
            producer = try parseProducer(parser);
        } else if (std.mem.eql(u8, key, "created_at")) {
            try strict.markSeen(&seen, 3);
            const value = try parser.string();
            try strict.validateTimestamp(value);
            created_at = value;
        } else if (std.mem.eql(u8, key, "finding_count")) {
            try strict.markSeen(&seen, 4);
            const value = try parser.unsigned(u32);
            if (value > limits.max_findings) return error.LimitExceeded;
            finding_count = value;
        } else if (std.mem.eql(u8, key, "manifest_sha256")) {
            try strict.markSeen(&seen, 5);
            manifest_sha256 = committed_review.Sha256Digest.parse(try parser.string()) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "findings_sha256")) {
            try strict.markSeen(&seen, 6);
            findings_sha256 = committed_review.Sha256Digest.parse(try parser.string()) catch return error.InvalidValue;
        } else return error.UnknownField;
    }
    try strict.requireFields(seen, 0b111_1111);
    return .{
        .review_repository_id = repository_id.?,
        .target = target.?,
        .producer = producer.?,
        .created_at = created_at.?,
        .finding_count = finding_count.?,
        .manifest_sha256 = manifest_sha256.?,
        .findings_sha256 = findings_sha256.?,
    };
}

fn parseProducer(parser: *strict.Parser) strict.ParseError!committed_review.Producer {
    try parser.beginObject();
    var seen: u32 = 0;
    var name: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var version: ?[]const u8 = null;
    var skill_version: ?[]const u8 = null;
    while (try parser.nextObjectKey()) |key| {
        if (std.mem.eql(u8, key, "name")) {
            try strict.markSeen(&seen, 0);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            name = value;
        } else if (std.mem.eql(u8, key, "model")) {
            try strict.markSeen(&seen, 1);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            model = value;
        } else if (std.mem.eql(u8, key, "version")) {
            try strict.markSeen(&seen, 2);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            version = value;
        } else if (std.mem.eql(u8, key, "skill_version")) {
            try strict.markSeen(&seen, 3);
            const value = try parser.string();
            try strict.validateText(value, limits.max_short_text_bytes, false);
            skill_version = value;
        } else return error.UnknownField;
    }
    try strict.requireFields(seen, 1);
    return .{ .name = name.?, .model = model, .version = version, .skill_version = skill_version };
}

fn successOutputAlloc(allocator: std.mem.Allocator, exact: *const store_service.ExactIdentity) std.mem.Allocator.Error!CommandOutput {
    const storage = try allocator.alloc(u8, max_terminal_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    tryField(&stringify, "status", "ok");
    tryField(&stringify, "schema_version", limits.schema_version);
    stringify.objectField("review_id") catch unreachable;
    const review_id = exact.review_id.canonical();
    stringify.write(&review_id) catch unreachable;
    stringify.objectField("identity") catch unreachable;
    writeIdentity(&stringify, &exact.identity);
    stringify.objectField("artifacts") catch unreachable;
    writeArtifacts(&stringify, exact.artifacts);
    stringify.objectField("lifecycle") catch unreachable;
    stringify.write(@tagName(exact.lifecycle)) catch unreachable;
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return .{ .exit_code = 0, .bytes = try allocator.realloc(storage, writer.buffered().len) };
}

fn writeIdentity(stringify: *std.json.Stringify, identity: *const store_service.PublicationIdentity) void {
    stringify.beginObject() catch unreachable;
    stringify.objectField("review_repository_id") catch unreachable;
    const repository_id = identity.review_repository_id.canonical();
    stringify.write(&repository_id) catch unreachable;
    stringify.objectField("target") catch unreachable;
    writeTarget(stringify, &identity.target);
    stringify.objectField("producer") catch unreachable;
    stringify.beginObject() catch unreachable;
    tryField(stringify, "name", identity.producer_name);
    if (identity.producer_model) |value| tryField(stringify, "model", value);
    if (identity.producer_version) |value| tryField(stringify, "version", value);
    if (identity.producer_skill_version) |value| tryField(stringify, "skill_version", value);
    stringify.endObject() catch unreachable;
    tryField(stringify, "created_at", &identity.created_at);
    tryField(stringify, "finding_count", identity.finding_count);
    stringify.objectField("manifest_sha256") catch unreachable;
    const manifest_digest = identity.manifest_sha256.canonical();
    stringify.write(&manifest_digest) catch unreachable;
    stringify.objectField("findings_sha256") catch unreachable;
    const findings_digest = identity.findings_sha256.canonical();
    stringify.write(&findings_digest) catch unreachable;
    stringify.endObject() catch unreachable;
}

fn writeTarget(stringify: *std.json.Stringify, target: *const committed_review.CommittedReviewTarget) void {
    stringify.beginObject() catch unreachable;
    tryField(stringify, "object_format", @tagName(target.object_format));
    tryField(stringify, "source_kind", @tagName(target.source_kind));
    tryField(stringify, "base_oid", target.base_oid.slice());
    tryField(stringify, "head_oid", target.head_oid.slice());
    tryField(stringify, "diff_base_oid", target.diff_base_oid.slice());
    stringify.endObject() catch unreachable;
}

fn writeArtifacts(stringify: *std.json.Stringify, artifacts: store_service.ArtifactSnapshot) void {
    stringify.beginObject() catch unreachable;
    stringify.objectField("manifest_sha256") catch unreachable;
    const manifest_digest = artifacts.manifest_digest.canonical();
    stringify.write(&manifest_digest) catch unreachable;
    stringify.objectField("findings_sha256") catch unreachable;
    const findings_digest = artifacts.findings_digest.canonical();
    stringify.write(&findings_digest) catch unreachable;
    tryField(stringify, "draft_state", @tagName(artifacts.draft_state));
    if (artifacts.draft_digest) |digest| {
        stringify.objectField("draft_sha256") catch unreachable;
        const text = digest.canonical();
        stringify.write(&text) catch unreachable;
    }
    if (artifacts.result_digest) |digest| {
        stringify.objectField("result_sha256") catch unreachable;
        const text = digest.canonical();
        stringify.write(&text) catch unreachable;
    }
    stringify.endObject() catch unreachable;
}

fn tryField(stringify: *std.json.Stringify, name: []const u8, value: anytype) void {
    stringify.objectField(name) catch unreachable;
    stringify.write(value) catch unreachable;
}

fn errorOutputAlloc(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!CommandOutput {
    const storage = try allocator.alloc(u8, max_terminal_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    tryField(&stringify, "status", "error");
    tryField(&stringify, "schema_version", limits.schema_version);
    tryField(&stringify, "code", failure.code);
    tryField(&stringify, "message", failure.message);
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return .{ .exit_code = failure.exit_code, .bytes = try allocator.realloc(storage, writer.buffered().len) };
}

fn failureTerminal(failure: store_service.ReadFailure) Failure {
    return switch (failure) {
        .expected_mismatch => .{ .exit_code = 65, .code = "expected_mismatch", .message = "observed publication identity does not match" },
        .artifact_invalid => .{ .exit_code = 65, .code = "artifact_invalid", .message = "Review Store artifacts are invalid" },
        .review_not_found => .{ .exit_code = 66, .code = "review_not_found", .message = "exact review ID was not found" },
        .target_unavailable => .{ .exit_code = 66, .code = "target_unavailable", .message = "target objects are unavailable" },
        .store_unavailable => .{ .exit_code = 69, .code = "store_unavailable", .message = "Review Store is unavailable" },
        .unsupported_platform => .{ .exit_code = 69, .code = "unsupported_platform", .message = "Review Store reader is unsupported on this platform" },
        .unsupported_filesystem => .{ .exit_code = 69, .code = "unsupported_filesystem", .message = "Review Store filesystem is unsupported" },
        .repository_invalid => .{ .exit_code = 74, .code = "repository_invalid", .message = "repository path is invalid" },
        .git_failed => .{ .exit_code = 74, .code = "git_failed", .message = "repository target could not be verified" },
        .store_invalid => .{ .exit_code = 74, .code = "store_invalid", .message = "Review Store authority is invalid" },
        .binding_invalid => .{ .exit_code = 74, .code = "binding_invalid", .message = "repository binding is invalid" },
        .io_failed => .{ .exit_code = 74, .code = "io_failed", .message = "Review Store read failed" },
        .root_changed => .{ .exit_code = 75, .code = "root_changed", .message = "Review Store root changed concurrently" },
        .binding_changed => .{ .exit_code = 75, .code = "binding_changed", .message = "repository binding changed concurrently" },
        .artifact_changed => .{ .exit_code = 75, .code = "artifact_changed", .message = "Review Store artifacts changed concurrently" },
        .concurrent_conflict => .{ .exit_code = 75, .code = "concurrent_conflict", .message = "Review Store read conflicted concurrently" },
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
    try writeOutput(file, io, "{\"status\":\"error\",\"schema_version\":1,\"code\":\"out_of_memory\",\"message\":\"review-store-read ran out of memory\"}\n");
    return 70;
}

test "review-store-read request is strict and uses canonical padded RFC 4648 repository bytes" {
    const canonical = "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}\n";
    var parsed = try parseRequest(std.testing.allocator, canonical);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/repo", parsed.value.repository_path);
    try std.testing.expect(parsed.value.expected == null);
    const invalid = [_][]const u8{
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3JlcG8\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}",
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"expected\":null}",
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}\r\n",
        "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}\n\n",
    };
    for (invalid) |bytes| try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, bytes));
}

test "review-store-read repository decoder accepts 4096 bytes and rejects plus one" {
    const allocator = std.testing.allocator;
    for ([_]usize{ max_repository_path_bytes, max_repository_path_bytes + 1 }) |length| {
        const path = try allocator.alloc(u8, length);
        defer allocator.free(path);
        @memset(path, 'p');
        path[0] = '/';
        const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(path.len));
        defer allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, path);
        const request = try std.fmt.allocPrint(
            allocator,
            "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"{s}\"}},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}}",
            .{encoded},
        );
        defer allocator.free(request);
        if (length == max_repository_path_bytes) {
            var parsed = try parseRequest(allocator, request);
            defer parsed.deinit();
            try std.testing.expectEqual(length, parsed.value.repository_path.len);
        } else {
            try std.testing.expectError(error.InvalidRequest, parseRequest(allocator, request));
        }
    }
}

test "review-store-read complete expected identity admits optional producer omissions" {
    const request = "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"expected\":{\"review_repository_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"1111111111111111111111111111111111111111\",\"head_oid\":\"2222222222222222222222222222222222222222\",\"diff_base_oid\":\"1111111111111111111111111111111111111111\"},\"producer\":{\"name\":\"codex\"},\"created_at\":\"2026-08-24T00:00:00Z\",\"finding_count\":0,\"manifest_sha256\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"findings_sha256\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"}}";
    var parsed = try parseRequest(std.testing.allocator, request);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("codex", parsed.value.expected.?.producer.name);
    try std.testing.expect(parsed.value.expected.?.producer.model == null);
}

test "review-store-read success terminal has fixed identity artifact and lifecycle order" {
    const allocator = std.testing.allocator;
    const base_oid = try committed_review.ObjectId.parse(.sha1, "1111111111111111111111111111111111111111");
    const head_oid = try committed_review.ObjectId.parse(.sha1, "2222222222222222222222222222222222222222");
    const manifest_digest = try committed_review.Sha256Digest.parse("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const findings_digest = try committed_review.Sha256Digest.parse("sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    var exact: store_service.ExactIdentity = .{
        .review_id = try committed_review.ReviewId.parse("123e4567-e89b-42d3-a456-426614174000"),
        .identity = .{
            .review_repository_id = try committed_review.ReviewRepositoryId.parse("223e4567-e89b-42d3-a456-426614174000"),
            .target = .{
                .object_format = .sha1,
                .source_kind = .branch_range,
                .base_oid = base_oid,
                .head_oid = head_oid,
                .diff_base_oid = base_oid,
            },
            .producer_name = try allocator.dupe(u8, "codex"),
            .producer_model = null,
            .producer_version = null,
            .producer_skill_version = null,
            .created_at = "2026-08-24T00:00:00Z".*,
            .finding_count = 0,
            .manifest_sha256 = manifest_digest,
            .findings_sha256 = findings_digest,
        },
        .artifacts = .{
            .manifest_digest = manifest_digest,
            .findings_digest = findings_digest,
            .draft_state = .absent,
            .draft_digest = null,
            .result_digest = null,
        },
        .lifecycle = .published,
    };
    defer exact.deinit(allocator);
    var output = try successOutputAlloc(allocator, &exact);
    defer output.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expectEqualStrings(
        "{\"status\":\"ok\",\"schema_version\":1,\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"identity\":{\"review_repository_id\":\"223e4567-e89b-42d3-a456-426614174000\",\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"1111111111111111111111111111111111111111\",\"head_oid\":\"2222222222222222222222222222222222222222\",\"diff_base_oid\":\"1111111111111111111111111111111111111111\"},\"producer\":{\"name\":\"codex\"},\"created_at\":\"2026-08-24T00:00:00Z\",\"finding_count\":0,\"manifest_sha256\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"findings_sha256\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"artifacts\":{\"manifest_sha256\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"findings_sha256\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"draft_state\":\"absent\"},\"lifecycle\":\"published\"}\n",
        output.bytes,
    );

    exact.artifacts.draft_state = .valid;
    exact.artifacts.draft_digest = manifest_digest;
    exact.lifecycle = .draft;
    var draft_output = try successOutputAlloc(allocator, &exact);
    defer draft_output.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        draft_output.bytes,
        "\"draft_state\":\"valid\",\"draft_sha256\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"},\"lifecycle\":\"draft\"}\n",
    ) != null);

    exact.artifacts.draft_state = .invalid;
    exact.artifacts.result_digest = findings_digest;
    exact.lifecycle = .result;
    var result_output = try successOutputAlloc(allocator, &exact);
    defer result_output.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        result_output.bytes,
        "\"draft_state\":\"invalid\",\"draft_sha256\":\"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"result_sha256\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"lifecycle\":\"result\"}\n",
    ) != null);

    exact.artifacts.draft_state = .unsafe;
    exact.artifacts.draft_digest = null;
    var unsafe_output = try successOutputAlloc(allocator, &exact);
    defer unsafe_output.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        unsafe_output.bytes,
        "\"draft_state\":\"unsafe\",\"result_sha256\":\"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"},\"lifecycle\":\"result\"}\n",
    ) != null);
}

test "review-store-read ordinary failure table emits fixed ordered terminals" {
    const cases = [_]store_service.ReadFailure{ .expected_mismatch, .artifact_invalid, .review_not_found, .target_unavailable, .store_unavailable, .unsupported_platform, .unsupported_filesystem, .repository_invalid, .git_failed, .store_invalid, .binding_invalid, .io_failed, .root_changed, .binding_changed, .artifact_changed, .concurrent_conflict };
    for (cases) |failure| {
        const terminal = failureTerminal(failure);
        var output = try errorOutputAlloc(std.testing.allocator, terminal);
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(terminal.exit_code, output.exit_code);
        try std.testing.expect(std.mem.startsWith(u8, output.bytes, "{\"status\":\"error\",\"schema_version\":1,\"code\":\""));
        try std.testing.expect(output.bytes[output.bytes.len - 1] == '\n');
    }
}

test "review-store-read argument request and schema terminals are exact" {
    const allocator = std.testing.allocator;
    var invalid_arguments = try executeAlloc(allocator, std.testing.io, null, &.{"unexpected"}, "");
    defer invalid_arguments.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 64), invalid_arguments.exit_code);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"schema_version\":1,\"code\":\"invalid_arguments\",\"message\":\"review-store-read accepts no arguments\"}\n", invalid_arguments.bytes);

    var invalid_request = try executeAlloc(allocator, std.testing.io, null, &.{}, "{}");
    defer invalid_request.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 64), invalid_request.exit_code);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"schema_version\":1,\"code\":\"invalid_request\",\"message\":\"read request is invalid\"}\n", invalid_request.bytes);

    var unsupported_schema = try executeAlloc(
        allocator,
        std.testing.io,
        null,
        &.{},
        "{\"schema_version\":2,\"repository\":{\"path_bytes_b64\":\"L3JlcG8=\"},\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\"}",
    );
    defer unsupported_schema.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 64), unsupported_schema.exit_code);
    try std.testing.expectEqualStrings("{\"status\":\"error\",\"schema_version\":1,\"code\":\"unsupported_schema\",\"message\":\"request schema version is not supported\"}\n", unsupported_schema.bytes);
}
