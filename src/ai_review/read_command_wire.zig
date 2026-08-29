//! Shared bounded wire primitives for exact Review Store read commands.

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

pub const LineOutput = struct {
    exit_code: u8,
    bytes: []u8,

    pub fn deinit(self: *LineOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Failure = struct {
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

pub fn errorOutputAlloc(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!LineOutput {
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

pub fn failureTerminal(failure: store_service.ReadFailure) Failure {
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

pub fn writeTarget(stringify: *std.json.Stringify, target: *const committed_review.CommittedReviewTarget) void {
    stringify.beginObject() catch unreachable;
    tryField(stringify, "object_format", @tagName(target.object_format));
    tryField(stringify, "source_kind", @tagName(target.source_kind));
    tryField(stringify, "base_oid", target.base_oid.slice());
    tryField(stringify, "head_oid", target.head_oid.slice());
    tryField(stringify, "diff_base_oid", target.diff_base_oid.slice());
    stringify.endObject() catch unreachable;
}

pub fn tryField(stringify: *std.json.Stringify, name: []const u8, value: anytype) void {
    stringify.objectField(name) catch unreachable;
    stringify.write(value) catch unreachable;
}

fn mapParseError(err: strict.ParseError) ParseError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest;
}
