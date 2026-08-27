//! Strict installed adapter for `gitframe review-producer artifacts`.
//!
//! This command owns bounded process framing and read-only committed-anchor
//! access. It cannot publish, inspect a Review Store, or retain producer state.

const std = @import("std");
const committed = @import("../committed_review.zig");
const git_command = @import("../git/command.zig");
const git_review = @import("../git/committed_review.zig");
const root_capability = @import("../repo/root_capability.zig");
const codec = @import("codec.zig");
const limits = @import("limits.zig");
const producer = @import("producer.zig");
const protocol = @import("protocol.zig");

pub const max_header_bytes: usize = 16 * 1024;
pub const max_request_bytes: usize = max_header_bytes + limits.max_review_input_output_bytes +
    limits.max_candidate_batches_bytes;
pub const max_success_header_bytes: usize = 16 * 1024;
pub const max_error_bytes: usize = 1024;

const RepositoryWire = struct { path_bytes_b64: []const u8 };
const ProducerWire = struct {
    name: []const u8,
    model: ?[]const u8 = null,
    version: ?[]const u8 = null,
    skill_version: ?[]const u8 = null,
};
const DisplayWire = struct {
    base_label: ?[]const u8 = null,
    head_label: ?[]const u8 = null,
};
const HeaderWire = struct {
    schema_version: u64,
    repository: RepositoryWire,
    review_repository_id: []const u8,
    review_id: []const u8,
    producer: ProducerWire,
    display: ?DisplayWire = null,
    review_input_size: usize,
    candidate_sizes: []const usize,
};
const ReviewInputWire = struct {
    schema_version: u64,
    status: []const u8,
    summary: std.json.Value,
    units: []const std.json.Value,
};

const ParsedFrame = struct {
    arena: std.heap.ArenaAllocator,
    repository_path: []const u8,
    review_repository_id: committed.ReviewRepositoryId,
    review_id: committed.ReviewId,
    producer_value: committed.Producer,
    display: ?committed.DisplayMetadata,
    summary: protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
    candidates: []const protocol.FindingCandidatePayload,

    fn deinit(self: *ParsedFrame) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const CommandOutput = struct {
    exit_code: u8,
    bytes: []u8,

    pub fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const Clock = struct {
    context: ?*anyopaque = null,
    sample_fn: *const fn (?*anyopaque, std.Io) ?i64 = sampleRealClock,

    fn sample(self: Clock, io: std.Io) ?i64 {
        return self.sample_fn(self.context, io);
    }
};

const Failure = struct {
    exit_code: u8,
    code: []const u8,
    message: []const u8,
};

const FrameError = error{ InvalidFrame, OutOfMemory };

fn parseFrame(allocator: std.mem.Allocator, bytes: []const u8) FrameError!ParsedFrame {
    if (bytes.len == 0 or bytes.len > max_request_bytes) return error.InvalidFrame;
    const header_end = std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.InvalidFrame;
    if (header_end == 0 or header_end + 1 > max_header_bytes) return error.InvalidFrame;
    const header_bytes = bytes[0..header_end];

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const header = std.json.parseFromSliceLeaky(HeaderWire, arena_allocator, header_bytes, .{
        .allocate = .alloc_always,
        .max_value_len = committed.limits.max_json_token_bytes,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;

    if (header.schema_version != limits.schema_version or
        header.review_input_size == 0 or
        header.review_input_size > limits.max_review_input_output_bytes or
        header.candidate_sizes.len == 0 or
        header.candidate_sizes.len > limits.max_review_units)
    {
        return error.InvalidFrame;
    }
    var candidate_total: usize = 0;
    for (header.candidate_sizes) |size| {
        if (size == 0 or size > limits.max_candidate_batch_bytes) return error.InvalidFrame;
        candidate_total = std.math.add(usize, candidate_total, size) catch return error.InvalidFrame;
        if (candidate_total > limits.max_candidate_batches_bytes) return error.InvalidFrame;
    }
    const expected = std.math.add(usize, header_end + 1, header.review_input_size) catch
        return error.InvalidFrame;
    const complete_size = std.math.add(usize, expected, candidate_total) catch return error.InvalidFrame;
    if (complete_size != bytes.len) return error.InvalidFrame;

    const repository_path = try decodeRepository(arena_allocator, header.repository.path_bytes_b64);
    const repository_id = committed.ReviewRepositoryId.parse(header.review_repository_id) catch
        return error.InvalidFrame;
    const review_id = committed.ReviewId.parse(header.review_id) catch return error.InvalidFrame;
    const producer_value = try validateProducer(header.producer);
    const display = if (header.display) |value| try validateDisplay(value) else null;
    try requireCanonicalHeader(arena_allocator, header_bytes, header);

    const input_start = header_end + 1;
    const input_end = input_start + header.review_input_size;
    const review_input = try parseReviewInput(arena_allocator, bytes[input_start..input_end]);
    if (review_input.units.len != header.candidate_sizes.len) return error.InvalidFrame;

    const candidates = arena_allocator.alloc(protocol.FindingCandidatePayload, header.candidate_sizes.len) catch
        return error.OutOfMemory;
    var cursor = input_end;
    for (header.candidate_sizes, 0..) |size, index| {
        const end = cursor + size;
        const parsed = protocol.FindingCandidatePayload.parseStrict(arena_allocator, bytes[cursor..end]) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
        candidates[index] = parsed.value;
        // The nested parser's arena is backed by the frame arena. Retain it so
        // its value remains valid until ParsedFrame.deinit releases everything.
        cursor = end;
    }
    return .{
        .arena = arena,
        .repository_path = repository_path,
        .review_repository_id = repository_id,
        .review_id = review_id,
        .producer_value = producer_value,
        .display = display,
        .summary = review_input.summary,
        .units = review_input.units,
        .candidates = candidates,
    };
}

const ParsedReviewInput = struct {
    summary: protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
};

fn parseReviewInput(allocator: std.mem.Allocator, bytes: []const u8) FrameError!ParsedReviewInput {
    if (bytes.len == 0 or bytes.len > limits.max_review_input_output_bytes) return error.InvalidFrame;
    const document = std.json.parseFromSliceLeaky(ReviewInputWire, allocator, bytes, .{
        .allocate = .alloc_always,
        .max_value_len = committed.limits.max_json_token_bytes,
        .parse_numbers = false,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
    if (document.schema_version != limits.schema_version or !std.mem.eql(u8, document.status, "ok") or
        document.units.len == 0 or document.units.len > limits.max_review_units)
    {
        return error.InvalidFrame;
    }

    const summary_bytes = try valueDocumentAlloc(allocator, document.summary);
    const parsed_summary = protocol.ReviewPlanSummary.parseStrict(allocator, summary_bytes) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
    const summary = parsed_summary.value;
    if (summary.unit_count != document.units.len) return error.InvalidFrame;

    const units = allocator.alloc(protocol.ReviewUnit, document.units.len) catch return error.OutOfMemory;
    for (document.units, 0..) |unit_value, index| {
        const unit_bytes = try valueDocumentAlloc(allocator, unit_value);
        const parsed_unit = protocol.ReviewUnit.parseStrict(allocator, unit_bytes) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
        units[index] = parsed_unit.value;
    }
    try requireCanonicalReviewInput(allocator, bytes, &summary, units);
    return .{ .summary = summary, .units = units };
}

fn valueDocumentAlloc(allocator: std.mem.Allocator, value: std.json.Value) FrameError![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    stringify.write(value) catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    return output.toOwnedSlice() catch error.OutOfMemory;
}

fn decodeRepository(allocator: std.mem.Allocator, encoded: []const u8) FrameError![]const u8 {
    if (encoded.len == 0 or encoded.len > 5462) return error.InvalidFrame;
    for (encoded) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return error.InvalidFrame;
    }
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch
        return error.InvalidFrame;
    if (decoded_len == 0 or decoded_len > 4096) return error.InvalidFrame;
    const decoded = allocator.alloc(u8, decoded_len) catch return error.OutOfMemory;
    std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded) catch return error.InvalidFrame;
    if (decoded[0] != '/' or std.mem.indexOfScalar(u8, decoded, 0) != null) return error.InvalidFrame;
    const canonical_len = std.base64.url_safe_no_pad.Encoder.calcSize(decoded.len);
    if (canonical_len != encoded.len) return error.InvalidFrame;
    const canonical = allocator.alloc(u8, canonical_len) catch return error.OutOfMemory;
    const written = std.base64.url_safe_no_pad.Encoder.encode(canonical, decoded);
    if (!std.mem.eql(u8, written, encoded)) return error.InvalidFrame;
    return decoded;
}

fn validateProducer(value: ProducerWire) FrameError!committed.Producer {
    validateShortText(value.name) catch return error.InvalidFrame;
    if (value.model) |text| validateShortText(text) catch return error.InvalidFrame;
    if (value.version) |text| validateShortText(text) catch return error.InvalidFrame;
    if (value.skill_version) |text| validateShortText(text) catch return error.InvalidFrame;
    return .{
        .name = value.name,
        .model = value.model,
        .version = value.version,
        .skill_version = value.skill_version,
    };
}

fn validateDisplay(value: DisplayWire) FrameError!committed.DisplayMetadata {
    if (value.base_label == null and value.head_label == null) return error.InvalidFrame;
    if (value.base_label) |text| validateShortText(text) catch return error.InvalidFrame;
    if (value.head_label) |text| validateShortText(text) catch return error.InvalidFrame;
    return .{ .base_label = value.base_label, .head_label = value.head_label };
}

fn validateShortText(text: []const u8) committed.strict_json.ParseError!void {
    return committed.strict_json.validateText(text, committed.limits.max_short_text_bytes, false);
}

fn requireCanonicalHeader(
    allocator: std.mem.Allocator,
    expected: []const u8,
    value: HeaderWire,
) FrameError!void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    stringify.beginObject() catch return error.OutOfMemory;
    tryJsonField(&stringify, "schema_version", value.schema_version) catch return error.OutOfMemory;
    stringify.objectField("repository") catch return error.OutOfMemory;
    stringify.beginObject() catch return error.OutOfMemory;
    tryJsonField(&stringify, "path_bytes_b64", value.repository.path_bytes_b64) catch return error.OutOfMemory;
    stringify.endObject() catch return error.OutOfMemory;
    tryJsonField(&stringify, "review_repository_id", value.review_repository_id) catch return error.OutOfMemory;
    tryJsonField(&stringify, "review_id", value.review_id) catch return error.OutOfMemory;
    stringify.objectField("producer") catch return error.OutOfMemory;
    writeProducer(&stringify, value.producer) catch return error.OutOfMemory;
    if (value.display) |display| {
        stringify.objectField("display") catch return error.OutOfMemory;
        writeDisplay(&stringify, display) catch return error.OutOfMemory;
    }
    tryJsonField(&stringify, "review_input_size", value.review_input_size) catch return error.OutOfMemory;
    stringify.objectField("candidate_sizes") catch return error.OutOfMemory;
    stringify.beginArray() catch return error.OutOfMemory;
    for (value.candidate_sizes) |size| stringify.write(size) catch return error.OutOfMemory;
    stringify.endArray() catch return error.OutOfMemory;
    stringify.endObject() catch return error.OutOfMemory;
    if (!std.mem.eql(u8, output.written(), expected)) return error.InvalidFrame;
    output.deinit();
}

fn writeProducer(stringify: *std.json.Stringify, value: ProducerWire) !void {
    try stringify.beginObject();
    try tryJsonField(stringify, "name", value.name);
    if (value.model) |text| try tryJsonField(stringify, "model", text);
    if (value.version) |text| try tryJsonField(stringify, "version", text);
    if (value.skill_version) |text| try tryJsonField(stringify, "skill_version", text);
    try stringify.endObject();
}

fn writeCommittedProducer(stringify: *std.json.Stringify, value: committed.Producer) !void {
    try stringify.beginObject();
    try tryJsonField(stringify, "name", value.name);
    if (value.model) |text| try tryJsonField(stringify, "model", text);
    if (value.version) |text| try tryJsonField(stringify, "version", text);
    if (value.skill_version) |text| try tryJsonField(stringify, "skill_version", text);
    try stringify.endObject();
}

fn writeDisplay(stringify: *std.json.Stringify, value: DisplayWire) !void {
    try stringify.beginObject();
    if (value.base_label) |text| try tryJsonField(stringify, "base_label", text);
    if (value.head_label) |text| try tryJsonField(stringify, "head_label", text);
    try stringify.endObject();
}

fn tryJsonField(stringify: *std.json.Stringify, name: []const u8, value: anytype) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn requireCanonicalReviewInput(
    allocator: std.mem.Allocator,
    expected: []const u8,
    summary: *const protocol.ReviewPlanSummary,
    units: []const protocol.ReviewUnit,
) FrameError!void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    output.writer.writeAll("{\"schema_version\":1,\"status\":\"ok\",\"summary\":") catch
        return error.OutOfMemory;
    const summary_bytes = summary.writeCanonical(allocator) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
    output.writer.writeAll(withoutFinalLf(summary_bytes) orelse return error.InvalidFrame) catch
        return error.OutOfMemory;
    output.writer.writeAll(",\"units\":[") catch return error.OutOfMemory;
    for (units, 0..) |*unit, index| {
        if (index != 0) output.writer.writeByte(',') catch return error.OutOfMemory;
        const unit_bytes = unit.writeCanonical(allocator) catch |err|
            return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
        output.writer.writeAll(withoutFinalLf(unit_bytes) orelse return error.InvalidFrame) catch
            return error.OutOfMemory;
    }
    output.writer.writeAll("]}\n") catch return error.OutOfMemory;
    if (!std.mem.eql(u8, output.written(), expected)) return error.InvalidFrame;
    output.deinit();
}

fn withoutFinalLf(bytes: []const u8) ?[]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') return null;
    return bytes[0 .. bytes.len - 1];
}

pub fn executeAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    request_bytes: []const u8,
) std.mem.Allocator.Error!CommandOutput {
    if (!validArguments(arguments)) return errorOutputAlloc(allocator, invalidArguments());
    var parsed = parseFrame(allocator, request_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFrame => errorOutputAlloc(allocator, invalidFrame()),
    };
    defer parsed.deinit();

    var root = root_capability.RootCapability.openCanonical(parsed.repository_path) catch
        return errorOutputAlloc(allocator, repositoryUnavailable());
    defer root.deinit();
    var environment = git_command.LocalGitEnvironment.initFromParent(allocator, environment_map) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorOutputAlloc(allocator, internalFailure()),
    };
    defer environment.deinit();
    var verifier: GitVerifier = .{
        .allocator = allocator,
        .io = io,
        .directory = .{ .cwd = root.dir(), .environment = &environment },
    };
    return buildOutput(allocator, io, &parsed, verifier.port(), .{});
}

fn executeWithVerifier(
    allocator: std.mem.Allocator,
    io: std.Io,
    arguments: []const []const u8,
    request_bytes: []const u8,
    verifier: producer.AnchorVerifier,
    clock: Clock,
) std.mem.Allocator.Error!CommandOutput {
    if (!validArguments(arguments)) return errorOutputAlloc(allocator, invalidArguments());
    var parsed = parseFrame(allocator, request_bytes) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFrame => errorOutputAlloc(allocator, invalidFrame()),
    };
    defer parsed.deinit();
    return buildOutput(allocator, io, &parsed, verifier, clock);
}

fn validArguments(arguments: []const []const u8) bool {
    return arguments.len == 1 and std.mem.eql(u8, arguments[0], "artifacts");
}

fn buildOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: *const ParsedFrame,
    verifier: producer.AnchorVerifier,
    clock: Clock,
) std.mem.Allocator.Error!CommandOutput {
    const timestamp = clock.sample(io) orelse return errorOutputAlloc(allocator, clockUnavailable());
    const created_at = formatUtcSecond(timestamp) orelse return errorOutputAlloc(allocator, clockUnavailable());
    var bundle = producer.buildAlloc(allocator, .{
        .summary = &parsed.summary,
        .units = parsed.units,
        .candidates = parsed.candidates,
        .review_repository_id = parsed.review_repository_id,
        .review_id = parsed.review_id,
        .producer = parsed.producer_value,
        .created_at = &created_at,
        .display = parsed.display,
    }, verifier) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AnchorUnavailable => errorOutputAlloc(allocator, anchorUnavailable()),
        else => errorOutputAlloc(allocator, invalidArtifact()),
    };
    defer bundle.deinit(allocator);
    return successOutputAlloc(allocator, parsed, &created_at, &bundle);
}

const GitVerifier = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: git_command.DirectoryContext,

    fn port(self: *GitVerifier) producer.AnchorVerifier {
        return .{ .context = self, .verify_fn = verify };
    }

    fn verify(
        context: ?*anyopaque,
        target: *const committed.CommittedReviewTarget,
        anchor: committed.CodeAnchor,
    ) producer.VerifyError!void {
        const self: *GitVerifier = @ptrCast(@alignCast(context.?));
        var resolution = git_review.resolveCodeAnchor(
            self.allocator,
            self.io,
            self.directory,
            target.*,
            anchor,
        ) catch return error.OutOfMemory;
        defer resolution.deinit(self.allocator);
        return switch (resolution) {
            .resolved => {},
            .failure => error.AnchorUnavailable,
        };
    }
};

fn successOutputAlloc(
    allocator: std.mem.Allocator,
    parsed: *const ParsedFrame,
    created_at: *const [20]u8,
    bundle: *const producer.ArtifactBundle,
) std.mem.Allocator.Error!CommandOutput {
    const storage = try allocator.alloc(u8, max_success_header_bytes);
    defer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    tryJsonField(&stringify, "schema_version", limits.schema_version) catch unreachable;
    tryJsonField(&stringify, "status", "ok") catch unreachable;
    const repository_id = parsed.review_repository_id.canonical();
    tryJsonField(&stringify, "review_repository_id", &repository_id) catch unreachable;
    const review_id = parsed.review_id.canonical();
    tryJsonField(&stringify, "review_id", &review_id) catch unreachable;
    stringify.objectField("target") catch unreachable;
    committed.codec.writeTarget(&stringify, &parsed.summary.target) catch unreachable;
    stringify.objectField("producer") catch unreachable;
    writeCommittedProducer(&stringify, parsed.producer_value) catch unreachable;
    tryJsonField(&stringify, "created_at", created_at) catch unreachable;
    tryJsonField(&stringify, "finding_count", bundle.finding_count) catch unreachable;
    const manifest_digest = bundle.manifest_digest.canonical();
    tryJsonField(&stringify, "manifest_sha256", &manifest_digest) catch unreachable;
    const findings_digest = bundle.findings_digest.canonical();
    tryJsonField(&stringify, "findings_sha256", &findings_digest) catch unreachable;
    tryJsonField(&stringify, "manifest_size", bundle.manifest_bytes.len) catch unreachable;
    tryJsonField(&stringify, "findings_size", bundle.findings_bytes.len) catch unreachable;
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    const header = writer.buffered();
    const artifact_size = std.math.add(usize, bundle.manifest_bytes.len, bundle.findings_bytes.len) catch
        return error.OutOfMemory;
    const total = std.math.add(usize, header.len, artifact_size) catch return error.OutOfMemory;
    const bytes = try allocator.alloc(u8, total);
    @memcpy(bytes[0..header.len], header);
    @memcpy(bytes[header.len .. header.len + bundle.manifest_bytes.len], bundle.manifest_bytes);
    @memcpy(bytes[header.len + bundle.manifest_bytes.len ..], bundle.findings_bytes);
    return .{ .exit_code = 0, .bytes = bytes };
}

fn errorOutputAlloc(allocator: std.mem.Allocator, failure: Failure) std.mem.Allocator.Error!CommandOutput {
    const storage = try allocator.alloc(u8, max_error_bytes);
    errdefer allocator.free(storage);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch unreachable;
    tryJsonField(&stringify, "schema_version", limits.schema_version) catch unreachable;
    tryJsonField(&stringify, "status", "error") catch unreachable;
    stringify.objectField("error") catch unreachable;
    stringify.beginObject() catch unreachable;
    tryJsonField(&stringify, "code", failure.code) catch unreachable;
    tryJsonField(&stringify, "message", failure.message) catch unreachable;
    stringify.endObject() catch unreachable;
    stringify.endObject() catch unreachable;
    writer.writeByte('\n') catch unreachable;
    return .{ .exit_code = failure.exit_code, .bytes = try allocator.realloc(storage, writer.buffered().len) };
}

fn invalidArguments() Failure {
    return .{ .exit_code = 64, .code = "invalid_arguments", .message = "review-producer accepts exactly the artifacts action" };
}
fn invalidFrame() Failure {
    return .{ .exit_code = 64, .code = "invalid_frame", .message = "review-producer frame is invalid" };
}
fn invalidArtifact() Failure {
    return .{ .exit_code = 64, .code = "invalid_artifact", .message = "review-producer artifact input is invalid" };
}
fn repositoryUnavailable() Failure {
    return .{ .exit_code = 66, .code = "repository_unavailable", .message = "committed repository is unavailable" };
}
fn anchorUnavailable() Failure {
    return .{ .exit_code = 66, .code = "anchor_unavailable", .message = "committed anchor is unavailable" };
}
fn clockUnavailable() Failure {
    return .{ .exit_code = 70, .code = "clock_unavailable", .message = "artifact timestamp is unavailable" };
}
fn internalFailure() Failure {
    return .{ .exit_code = 70, .code = "internal_error", .message = "review-producer could not complete" };
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    environment_map: ?*const std.process.Environ.Map,
    arguments: []const []const u8,
    stdin_file: std.Io.File,
    stdout_file: std.Io.File,
) !u8 {
    if (!validArguments(arguments)) {
        var output = try errorOutputAlloc(allocator, invalidArguments());
        defer output.deinit(allocator);
        try writeAll(stdout_file, io, output.bytes);
        return output.exit_code;
    }
    var read_buffer: [4096]u8 = undefined;
    var reader = stdin_file.readerStreaming(io, &read_buffer);
    const request = reader.interface.allocRemaining(allocator, .limited(max_request_bytes + 1)) catch |err| switch (err) {
        error.OutOfMemory => return writeEmergency(stdout_file, io),
        else => {
            var output = try errorOutputAlloc(allocator, invalidFrame());
            defer output.deinit(allocator);
            try writeAll(stdout_file, io, output.bytes);
            return output.exit_code;
        },
    };
    defer allocator.free(request);
    var output = executeAlloc(allocator, io, environment_map, arguments, request) catch
        return writeEmergency(stdout_file, io);
    defer output.deinit(allocator);
    try writeAll(stdout_file, io, output.bytes);
    return output.exit_code;
}

fn writeAll(file: std.Io.File, io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var stream = file.writerStreaming(io, &buffer);
    try stream.interface.writeAll(bytes);
    try stream.interface.flush();
}

fn writeEmergency(file: std.Io.File, io: std.Io) !u8 {
    const bytes = "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"internal_error\",\"message\":\"review-producer could not complete\"}}\n";
    try writeAll(file, io, bytes);
    return 70;
}

fn sampleRealClock(_: ?*anyopaque, io: std.Io) ?i64 {
    const resolution = std.Io.Clock.real.resolution(io) catch return null;
    if (resolution.nanoseconds == 0) return null;
    const timestamp = std.Io.Clock.real.now(io);
    return std.math.cast(i64, @divFloor(timestamp.nanoseconds, std.time.ns_per_s));
}

fn formatUtcSecond(value: i64) ?[20]u8 {
    if (value < 0 or value > 253_402_300_799) return null;
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(value) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    var result: [20]u8 = undefined;
    const rendered = std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return null;
    if (rendered.len != result.len) return null;
    return result;
}

const RecordingVerifier = struct {
    count: usize = 0,
    fail: bool = false,
    target: ?committed.CommittedReviewTarget = null,
    anchor_start_line: u32 = 0,
    path_digest: committed.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 },

    fn port(self: *RecordingVerifier) producer.AnchorVerifier {
        return .{ .context = self, .verify_fn = verify };
    }

    fn verify(
        context: ?*anyopaque,
        target: *const committed.CommittedReviewTarget,
        anchor: committed.CodeAnchor,
    ) producer.VerifyError!void {
        const self: *RecordingVerifier = @ptrCast(@alignCast(context.?));
        if (self.fail) return error.AnchorUnavailable;
        self.count += 1;
        self.target = target.*;
        self.anchor_start_line = anchor.start_line;
        self.path_digest = committed.Sha256Digest.hash(anchor.path_bytes);
    }
};

fn fixedClock(context: ?*anyopaque, _: std.Io) ?i64 {
    const value: *i64 = @ptrCast(@alignCast(context.?));
    return value.*;
}

fn unavailableClock(_: ?*anyopaque, _: std.Io) ?i64 {
    return null;
}

fn expectErrorTerminal(output: CommandOutput, exit_code: u8, code: []const u8) !void {
    try std.testing.expectEqual(exit_code, output.exit_code);
    try std.testing.expect(output.bytes.len <= max_error_bytes);
    try std.testing.expectEqual(@as(u8, '\n'), output.bytes[output.bytes.len - 1]);
    try std.testing.expect(std.mem.indexOfScalar(u8, output.bytes[0 .. output.bytes.len - 1], '\n') == null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, code) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes, "/tmp/repo") == null);
}

fn readFixture(allocator: std.mem.Allocator, path: []const u8, maximum: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(maximum));
}

fn testReviewInputAlloc(allocator: std.mem.Allocator) ![]u8 {
    const summary_fixture = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/plan.json", limits.max_plan_summary_bytes);
    defer allocator.free(summary_fixture);
    const unit_fixture = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/unit.json", limits.max_unit_bytes);
    defer allocator.free(unit_fixture);
    var parsed_summary = try protocol.ReviewPlanSummary.parseStrict(allocator, summary_fixture);
    defer parsed_summary.deinit();
    var parsed_unit = try protocol.ReviewUnit.parseStrict(allocator, unit_fixture);
    defer parsed_unit.deinit();
    const zero_digest: committed.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 };
    parsed_summary.value.plan_digest = zero_digest;
    parsed_unit.value.plan_digest = zero_digest;
    const zero_summary = try parsed_summary.value.writeCanonical(allocator);
    defer allocator.free(zero_summary);
    const zero_unit = try parsed_unit.value.writeCanonical(allocator);
    defer allocator.free(zero_unit);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("gitframe-ai-review-plan-v1\x00");
    hasher.update(zero_summary);
    hasher.update(zero_unit);
    var digest: committed.Sha256Digest = undefined;
    hasher.final(&digest.bytes);
    parsed_summary.value.plan_digest = digest;
    parsed_unit.value.plan_digest = digest;
    const summary = try parsed_summary.value.writeCanonical(allocator);
    defer allocator.free(summary);
    const unit = try parsed_unit.value.writeCanonical(allocator);
    defer allocator.free(unit);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"status\":\"ok\",\"summary\":{s},\"units\":[{s}]}}\n",
        .{ withoutFinalLf(summary).?, withoutFinalLf(unit).? },
    );
}

fn testTwoUnitReviewInputAlloc(allocator: std.mem.Allocator) ![]u8 {
    const summary_fixture = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/plan.json", limits.max_plan_summary_bytes);
    defer allocator.free(summary_fixture);
    const unit_fixture = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/unit.json", limits.max_unit_bytes);
    defer allocator.free(unit_fixture);

    var parsed_summary = try protocol.ReviewPlanSummary.parseStrict(allocator, summary_fixture);
    defer parsed_summary.deinit();
    var parsed_unit = try protocol.ReviewUnit.parseStrict(allocator, unit_fixture);
    defer parsed_unit.deinit();
    parsed_summary.value.unit_count = 2;
    parsed_unit.value.unit_count = 2;
    var second_unit = parsed_unit.value;
    second_unit.unit_id = .{ .ordinal = 2 };
    second_unit.ordinal = 2;

    const zero_digest: committed.Sha256Digest = .{ .bytes = [_]u8{0} ** 32 };
    parsed_summary.value.plan_digest = zero_digest;
    parsed_unit.value.plan_digest = zero_digest;
    second_unit.plan_digest = zero_digest;
    const zero_summary = try parsed_summary.value.writeCanonical(allocator);
    defer allocator.free(zero_summary);
    const zero_first_unit = try parsed_unit.value.writeCanonical(allocator);
    defer allocator.free(zero_first_unit);
    const zero_second_unit = try second_unit.writeCanonical(allocator);
    defer allocator.free(zero_second_unit);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("gitframe-ai-review-plan-v1\x00");
    hasher.update(zero_summary);
    hasher.update(zero_first_unit);
    hasher.update(zero_second_unit);
    var digest: committed.Sha256Digest = undefined;
    hasher.final(&digest.bytes);
    parsed_summary.value.plan_digest = digest;
    parsed_unit.value.plan_digest = digest;
    second_unit.plan_digest = digest;

    const summary = try parsed_summary.value.writeCanonical(allocator);
    defer allocator.free(summary);
    const first_unit = try parsed_unit.value.writeCanonical(allocator);
    defer allocator.free(first_unit);
    const second_unit_bytes = try second_unit.writeCanonical(allocator);
    defer allocator.free(second_unit_bytes);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"status\":\"ok\",\"summary\":{s},\"units\":[{s},{s}]}}\n",
        .{ withoutFinalLf(summary).?, withoutFinalLf(first_unit).?, withoutFinalLf(second_unit_bytes).? },
    );
}

fn testFrameAlloc(
    allocator: std.mem.Allocator,
    review_input: []const u8,
    candidate: []const u8,
) ![]u8 {
    const header = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"review_repository_id\":\"123e4567-e89b-42d3-b456-426614174000\",\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"producer\":{{\"name\":\"codex\",\"model\":\"gpt-5\",\"version\":\"1\"}},\"display\":{{\"base_label\":\"main\",\"head_label\":\"feature\"}},\"review_input_size\":{d},\"candidate_sizes\":[{d}]}}\n",
        .{ review_input.len, candidate.len },
    );
    defer allocator.free(header);
    const frame = try allocator.alloc(u8, header.len + review_input.len + candidate.len);
    @memcpy(frame[0..header.len], header);
    @memcpy(frame[header.len .. header.len + review_input.len], review_input);
    @memcpy(frame[header.len + review_input.len ..], candidate);
    return frame;
}

fn testTwoCandidateFrameAlloc(
    allocator: std.mem.Allocator,
    review_input: []const u8,
    candidate: []const u8,
) ![]u8 {
    const header = try std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"review_repository_id\":\"123e4567-e89b-42d3-b456-426614174000\",\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"producer\":{{\"name\":\"codex\"}},\"review_input_size\":{d},\"candidate_sizes\":[{d},{d}]}}\n",
        .{ review_input.len, candidate.len, candidate.len },
    );
    defer allocator.free(header);
    const frame = try allocator.alloc(u8, header.len + review_input.len + candidate.len * 2);
    @memcpy(frame[0..header.len], header);
    @memcpy(frame[header.len .. header.len + review_input.len], review_input);
    @memcpy(frame[header.len + review_input.len .. header.len + review_input.len + candidate.len], candidate);
    @memcpy(frame[header.len + review_input.len + candidate.len ..], candidate);
    return frame;
}

test "AI review producer command emits one canonical artifact frame" {
    const allocator = std.testing.allocator;
    const review_input = try testReviewInputAlloc(allocator);
    defer allocator.free(review_input);
    const candidate = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/candidate.json", limits.max_candidate_batch_bytes);
    defer allocator.free(candidate);
    const request = try testFrameAlloc(allocator, review_input, candidate);
    defer allocator.free(request);
    var verifier: RecordingVerifier = .{};
    var clock_value = try committed.strict_json.timestampToUnixSeconds("2026-08-26T13:00:00Z");
    var output = try executeWithVerifier(
        allocator,
        std.testing.io,
        &.{"artifacts"},
        request,
        verifier.port(),
        .{ .context = &clock_value, .sample_fn = fixedClock },
    );
    defer output.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expectEqual(@as(usize, 1), verifier.count);
    try std.testing.expect(verifier.target.?.eql(&verifier.target.?));
    try std.testing.expectEqual(@as(u32, 2), verifier.anchor_start_line);
    try std.testing.expect(verifier.path_digest.eql(committed.Sha256Digest.hash("src/main.zig")));

    const manifest = try readFixture(allocator, "testdata/ai-review-producer-v1/artifact/manifest.json", committed.limits.max_manifest_bytes);
    defer allocator.free(manifest);
    const findings = try readFixture(allocator, "testdata/ai-review-producer-v1/artifact/findings.json", committed.limits.max_artifact_bytes);
    defer allocator.free(findings);
    const header_end = (std.mem.indexOfScalar(u8, output.bytes, '\n') orelse return error.TestUnexpectedResult) + 1;
    try std.testing.expect(header_end <= max_success_header_bytes);
    const expected_header =
        "{\"schema_version\":1,\"status\":\"ok\",\"review_repository_id\":\"123e4567-e89b-42d3-b456-426614174000\",\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"target\":{\"object_format\":\"sha1\",\"source_kind\":\"branch_range\",\"base_oid\":\"0000000000000000000000000000000000000000\",\"head_oid\":\"1111111111111111111111111111111111111111\",\"diff_base_oid\":\"0000000000000000000000000000000000000000\"},\"producer\":{\"name\":\"codex\",\"model\":\"gpt-5\",\"version\":\"1\"},\"created_at\":\"2026-08-26T13:00:00Z\",\"finding_count\":1,\"manifest_sha256\":\"sha256:266e8c894fd35cbe4307a4742de2dd052d47ce6fbf558f1271ede1fb30eec73a\",\"findings_sha256\":\"sha256:c354da28ddd1778d45a5b8d21d249670643bf0625658eddc19923c681585ce58\",\"manifest_size\":623,\"findings_size\":768}\n";
    try std.testing.expectEqualStrings(expected_header, output.bytes[0..header_end]);
    try std.testing.expectEqualSlices(u8, manifest, output.bytes[header_end .. header_end + manifest.len]);
    try std.testing.expectEqualSlices(u8, findings, output.bytes[header_end + manifest.len ..]);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes[0..header_end], "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.bytes[0..header_end], "\"finding_count\":1") != null);
}

test "AI review producer command retains nested values for a canonical two-unit frame" {
    const allocator = std.testing.allocator;
    const review_input = try testTwoUnitReviewInputAlloc(allocator);
    defer allocator.free(review_input);
    const candidate = "{\"findings\":[]}\n";
    const request = try testTwoCandidateFrameAlloc(allocator, review_input, candidate);
    defer allocator.free(request);
    var verifier: RecordingVerifier = .{};
    var clock_value = try committed.strict_json.timestampToUnixSeconds("2026-08-26T13:00:00Z");
    var output = try executeWithVerifier(
        allocator,
        std.testing.io,
        &.{"artifacts"},
        request,
        verifier.port(),
        .{ .context = &clock_value, .sample_fn = fixedClock },
    );
    defer output.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), output.exit_code);
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
    const header_end = (std.mem.indexOfScalar(u8, output.bytes, '\n') orelse return error.TestUnexpectedResult) + 1;
    try std.testing.expect(std.mem.indexOf(u8, output.bytes[0..header_end], "\"finding_count\":0") != null);
}

test "AI review producer command requires exactly the artifacts action" {
    var verifier: RecordingVerifier = .{};
    var clock_value: i64 = 0;
    for ([_][]const []const u8{ &.{}, &.{"--help"}, &.{ "artifacts", "extra" } }) |arguments| {
        var output = try executeWithVerifier(
            std.testing.allocator,
            std.testing.io,
            arguments,
            "not-read",
            verifier.port(),
            .{ .context = &clock_value, .sample_fn = fixedClock },
        );
        defer output.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u8, 64), output.exit_code);
        try std.testing.expectEqualStrings(
            "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"invalid_arguments\",\"message\":\"review-producer accepts exactly the artifacts action\"}}\n",
            output.bytes,
        );
    }
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
}

test "AI review producer command rejects short extra and noncanonical frames" {
    const allocator = std.testing.allocator;
    const review_input = try testReviewInputAlloc(allocator);
    defer allocator.free(review_input);
    const candidate = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/candidate.json", limits.max_candidate_batch_bytes);
    defer allocator.free(candidate);
    const valid = try testFrameAlloc(allocator, review_input, candidate);
    defer allocator.free(valid);
    const noncanonical_input = try testFrameAlloc(allocator, review_input[0 .. review_input.len - 1], candidate);
    defer allocator.free(noncanonical_input);
    const noncanonical_candidate = try testFrameAlloc(allocator, review_input, "{\"findings\":[]}");
    defer allocator.free(noncanonical_candidate);
    const extra = try std.mem.concat(allocator, u8, &.{ valid, "x" });
    defer allocator.free(extra);
    const oversized = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"review_repository_id\":\"123e4567-e89b-42d3-b456-426614174000\",\"review_id\":\"123e4567-e89b-42d3-a456-426614174000\",\"producer\":{{\"name\":\"codex\"}},\"review_input_size\":{d},\"candidate_sizes\":[1]}}\n", .{limits.max_review_input_output_bytes + 1});
    defer allocator.free(oversized);
    const reordered = try std.mem.replaceOwned(u8, allocator, valid, "{\"schema_version\":1,\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"review_repository_id\"", "{\"repository\":{\"path_bytes_b64\":\"L3RtcC9yZXBv\"},\"schema_version\":1,\"review_repository_id\"");
    defer allocator.free(reordered);
    var verifier: RecordingVerifier = .{};
    var clock_value: i64 = 0;
    for ([_][]const u8{ "", valid[0 .. valid.len - 1], extra, reordered, oversized, noncanonical_input, noncanonical_candidate }) |request| {
        var output = try executeWithVerifier(
            allocator,
            std.testing.io,
            &.{"artifacts"},
            request,
            verifier.port(),
            .{ .context = &clock_value, .sample_fn = fixedClock },
        );
        defer output.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 64), output.exit_code);
        try std.testing.expect(std.mem.indexOf(u8, output.bytes, "\"code\":\"invalid_frame\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
}

test "AI review producer command maps clock anchor and artifact failures without paths" {
    const allocator = std.testing.allocator;
    const review_input = try testReviewInputAlloc(allocator);
    defer allocator.free(review_input);
    const candidate = try readFixture(allocator, "testdata/ai-review-producer-v1/protocol/candidate.json", limits.max_candidate_batch_bytes);
    defer allocator.free(candidate);
    const request = try testFrameAlloc(allocator, review_input, candidate);
    defer allocator.free(request);

    var verifier: RecordingVerifier = .{};
    var clock_output = try executeWithVerifier(
        allocator,
        std.testing.io,
        &.{"artifacts"},
        request,
        verifier.port(),
        .{ .sample_fn = unavailableClock },
    );
    defer clock_output.deinit(allocator);
    try expectErrorTerminal(clock_output, 70, "\"code\":\"clock_unavailable\"");
    try std.testing.expectEqual(@as(usize, 0), verifier.count);

    verifier.fail = true;
    var clock_value: i64 = 0;
    var anchor_output = try executeWithVerifier(
        allocator,
        std.testing.io,
        &.{"artifacts"},
        request,
        verifier.port(),
        .{ .context = &clock_value, .sample_fn = fixedClock },
    );
    defer anchor_output.deinit(allocator);
    try expectErrorTerminal(anchor_output, 66, "\"code\":\"anchor_unavailable\"");
    try std.testing.expectEqual(@as(usize, 0), verifier.count);

    const invalid_candidate = try std.mem.replaceOwned(u8, allocator, candidate, "a0002", "a9999");
    defer allocator.free(invalid_candidate);
    const invalid_request = try testFrameAlloc(allocator, review_input, invalid_candidate);
    defer allocator.free(invalid_request);
    verifier.fail = false;
    var artifact_output = try executeWithVerifier(
        allocator,
        std.testing.io,
        &.{"artifacts"},
        invalid_request,
        verifier.port(),
        .{ .context = &clock_value, .sample_fn = fixedClock },
    );
    defer artifact_output.deinit(allocator);
    try expectErrorTerminal(artifact_output, 64, "\"code\":\"invalid_artifact\"");
    try std.testing.expectEqual(@as(usize, 0), verifier.count);
}
