//! Admission for the binary-safe `review-input` outer frame and the nested
//! successful `review-projection` frame.

const std = @import("std");
const limits = @import("limits.zig");
const committed_codec = @import("../committed_review/codec.zig");
const committed_limits = @import("../committed_review/limits.zig");
const projection_command = @import("../committed_review/projection_command.zig");
const length_frame = @import("../data/length_frame.zig");
const strict_data = @import("../data/strict_json.zig");
const target_mod = @import("../committed_review/target.zig");

const StrictParser = strict_data.Parser(.{
    .max_token_bytes = committed_limits.max_json_token_bytes,
    .max_depth = committed_limits.max_json_depth,
});

pub const Error = std.mem.Allocator.Error || error{
    InvalidFrame,
    UnsupportedSchemaVersion,
    InvalidTarget,
    LimitExceeded,
};

pub const Frame = struct {
    arena: std.heap.ArenaAllocator,
    repository_path: []const u8,
    target: target_mod.CommittedReviewTarget,
    /// Exact projection payload bytes after the nested success header.
    patch_bytes: []const u8,
    /// Exact complete nested frame borrowed from the caller's input.
    projection_frame: []const u8,

    pub fn deinit(self: *Frame) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parse exactly `<outer JSON> LF <projection frame> EOF`.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) Error!Frame {
    var ignored: ?limits.Violation = null;
    return parseWithLimit(allocator, input, &ignored);
}

pub fn parseWithLimit(allocator: std.mem.Allocator, input: []const u8, violation: *?limits.Violation) Error!Frame {
    violation.* = null;
    const outer_parts = try admitParts(input, limits.max_input_header_bytes, "input_header_bytes", violation);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    var outer = StrictParser.init(arena_allocator, outer_parts.header);
    defer outer.deinit();

    outer.beginObject() catch |err| return mapOuterError(err);
    var seen: u32 = 0;
    var schema_version: ?u64 = null;
    var repository_path: ?[]const u8 = null;
    var target: ?target_mod.CommittedReviewTarget = null;
    var projection_frame_size: ?usize = null;
    while (outer.nextObjectKey() catch |err| return mapOuterError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict_data.markSeen(&seen, 0) catch |err| return mapOuterError(err);
            schema_version = outer.unsigned(u64) catch |err| return mapOuterError(err);
        } else if (std.mem.eql(u8, key, "repository")) {
            strict_data.markSeen(&seen, 1) catch |err| return mapOuterError(err);
            repository_path = projection_command.parseRepository(&outer) catch |err| return mapProjectionRequestError(err);
        } else if (std.mem.eql(u8, key, "target")) {
            strict_data.markSeen(&seen, 2) catch |err| return mapOuterError(err);
            target = committed_codec.parseTarget(&outer) catch |err| return mapTargetError(err);
        } else if (std.mem.eql(u8, key, "projection_frame_size")) {
            strict_data.markSeen(&seen, 3) catch |err| return mapOuterError(err);
            projection_frame_size = outer.unsigned(usize) catch |err| return mapOuterError(err);
        } else {
            return error.InvalidFrame;
        }
    }
    strict_data.requireFields(seen, 0b1111) catch |err| return mapOuterError(err);
    outer.endDocument() catch |err| return mapOuterError(err);
    if (schema_version.? != limits.schema_version) return error.UnsupportedSchemaVersion;
    target.?.validate() catch return error.InvalidTarget;
    const canonical_outer = try outerHeaderAlloc(
        arena_allocator,
        repository_path.?,
        &target.?,
        projection_frame_size.?,
    );
    if (!std.mem.eql(u8, outer_parts.header, canonical_outer)) return error.InvalidFrame;
    if (projection_frame_size.? == 0) return error.InvalidFrame;
    if (projection_frame_size.? > limits.max_projection_frame_bytes) {
        limits.record(violation, "projection_frame_bytes", projection_frame_size.?, limits.max_projection_frame_bytes);
        return error.LimitExceeded;
    }
    const nested = length_frame.exactPayload(outer_parts, projection_frame_size.?) catch return error.InvalidFrame;

    const inner_parts = try admitParts(nested, projection_command.max_success_header_bytes, "projection_header_bytes", violation);
    var inner = StrictParser.init(arena_allocator, inner_parts.header);
    defer inner.deinit();
    inner.beginObject() catch |err| return mapOuterError(err);
    seen = 0;
    schema_version = null;
    var status_ok = false;
    var inner_target: ?target_mod.CommittedReviewTarget = null;
    var patch_size: ?usize = null;
    while (inner.nextObjectKey() catch |err| return mapOuterError(err)) |key| {
        if (std.mem.eql(u8, key, "schema_version")) {
            strict_data.markSeen(&seen, 0) catch |err| return mapOuterError(err);
            schema_version = inner.unsigned(u64) catch |err| return mapOuterError(err);
        } else if (std.mem.eql(u8, key, "status")) {
            strict_data.markSeen(&seen, 1) catch |err| return mapOuterError(err);
            status_ok = std.mem.eql(u8, inner.string() catch |err| return mapOuterError(err), "ok");
        } else if (std.mem.eql(u8, key, "target")) {
            strict_data.markSeen(&seen, 2) catch |err| return mapOuterError(err);
            inner_target = committed_codec.parseTarget(&inner) catch |err| return mapTargetError(err);
        } else if (std.mem.eql(u8, key, "patch_size")) {
            strict_data.markSeen(&seen, 3) catch |err| return mapOuterError(err);
            patch_size = inner.unsigned(usize) catch |err| return mapOuterError(err);
        } else {
            return error.InvalidFrame;
        }
    }
    strict_data.requireFields(seen, 0b1111) catch |err| return mapOuterError(err);
    inner.endDocument() catch |err| return mapOuterError(err);
    if (schema_version.? != limits.schema_version) return error.UnsupportedSchemaVersion;
    inner_target.?.validate() catch return error.InvalidTarget;
    if (!status_ok or !inner_target.?.eql(&target.?)) return error.InvalidFrame;
    const canonical_inner = try successHeaderAlloc(arena_allocator, &inner_target.?, patch_size.?);
    if (!std.mem.eql(u8, inner_parts.header, canonical_inner)) return error.InvalidFrame;
    if (patch_size.? > limits.max_projection_bytes) {
        limits.record(violation, "projection_bytes", patch_size.?, limits.max_projection_bytes);
        return error.LimitExceeded;
    }
    const patch = length_frame.exactPayload(inner_parts, patch_size.?) catch return error.InvalidFrame;

    return .{
        .arena = arena,
        .repository_path = repository_path.?,
        .target = target.?,
        .patch_bytes = patch,
        .projection_frame = nested,
    };
}

fn outerHeaderAlloc(
    allocator: std.mem.Allocator,
    repository_path: []const u8,
    target: *const target_mod.CommittedReviewTarget,
    projection_frame_size: usize,
) Error![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(repository_path.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, repository_path);

    const storage = try allocator.alloc(u8, limits.max_input_header_bytes);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch return error.InvalidFrame;
    stringify.objectField("schema_version") catch return error.InvalidFrame;
    stringify.write(limits.schema_version) catch return error.InvalidFrame;
    stringify.objectField("repository") catch return error.InvalidFrame;
    stringify.beginObject() catch return error.InvalidFrame;
    stringify.objectField("path_bytes_b64") catch return error.InvalidFrame;
    stringify.write(encoded) catch return error.InvalidFrame;
    stringify.endObject() catch return error.InvalidFrame;
    stringify.objectField("target") catch return error.InvalidFrame;
    committed_codec.writeTarget(&stringify, target) catch return error.InvalidFrame;
    stringify.objectField("projection_frame_size") catch return error.InvalidFrame;
    stringify.write(projection_frame_size) catch return error.InvalidFrame;
    stringify.endObject() catch return error.InvalidFrame;
    return storage[0..writer.buffered().len];
}

fn successHeaderAlloc(
    allocator: std.mem.Allocator,
    target: *const target_mod.CommittedReviewTarget,
    patch_size: usize,
) Error![]u8 {
    const storage = try allocator.alloc(u8, projection_command.max_success_header_bytes);
    var writer: std.Io.Writer = .fixed(storage);
    var stringify: std.json.Stringify = .{ .writer = &writer, .options = .{} };
    stringify.beginObject() catch return error.InvalidFrame;
    stringify.objectField("schema_version") catch return error.InvalidFrame;
    stringify.write(limits.schema_version) catch return error.InvalidFrame;
    stringify.objectField("status") catch return error.InvalidFrame;
    stringify.write("ok") catch return error.InvalidFrame;
    stringify.objectField("target") catch return error.InvalidFrame;
    committed_codec.writeTarget(&stringify, target) catch return error.InvalidFrame;
    stringify.objectField("patch_size") catch return error.InvalidFrame;
    stringify.write(patch_size) catch return error.InvalidFrame;
    stringify.endObject() catch return error.InvalidFrame;
    return storage[0..writer.buffered().len];
}

fn mapOuterError(err: strict_data.ParseError) Error {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidFrame;
}

fn admitParts(
    input: []const u8,
    max_header_bytes: usize,
    header_resource: []const u8,
    violation: *?limits.Violation,
) Error!length_frame.Parts {
    return length_frame.split(input, .{
        .max_header_bytes = max_header_bytes,
        .max_payload_bytes = std.math.maxInt(usize),
    }) catch |err| {
        if (err != error.HeaderTooLarge) return error.InvalidFrame;
        const lf = std.mem.indexOfScalar(u8, input, '\n') orelse unreachable;
        limits.record(violation, header_resource, lf + 1, max_header_bytes);
        return error.LimitExceeded;
    };
}

fn mapTargetError(err: committed_codec.ParseError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSchemaVersion => error.UnsupportedSchemaVersion,
        error.LimitExceeded, error.ArtifactTooLarge => error.InvalidTarget,
        else => error.InvalidTarget,
    };
}

fn mapProjectionRequestError(err: projection_command.RequestParseError) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsupportedSchemaVersion => error.UnsupportedSchemaVersion,
        else => error.InvalidFrame,
    };
}

fn testTarget() target_mod.CommittedReviewTarget {
    const oid = target_mod.ObjectId.parse(.sha1, "0123456789abcdef0123456789abcdef01234567") catch unreachable;
    return .{
        .object_format = .sha1,
        .source_kind = .branch_range,
        .base_oid = oid,
        .head_oid = oid,
        .diff_base_oid = oid,
    };
}

fn targetJson(allocator: std.mem.Allocator, target: *const target_mod.CommittedReviewTarget) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try committed_codec.writeTarget(&stringify, target);
    return output.toOwnedSlice();
}

test "AI review input projection frame admits exact nested success bytes" {
    const target = testTarget();
    const target_json = try targetJson(std.testing.allocator, &target);
    defer std.testing.allocator.free(target_json);
    const patch = "diff --git a/a b/a\n";
    const inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":{d}}}\n{s}", .{ target_json, patch.len, patch });
    defer std.testing.allocator.free(inner);
    const outer = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, inner.len, inner });
    defer std.testing.allocator.free(outer);

    var parsed = try parse(std.testing.allocator, outer);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/tmp/repo", parsed.repository_path);
    try std.testing.expectEqualStrings(patch, parsed.patch_bytes);
    try std.testing.expectEqualStrings(inner, parsed.projection_frame);
}

test "AI review input projection frame rejects short extra mismatch and failure frames" {
    const oversized_header = try std.testing.allocator.alloc(u8, limits.max_input_header_bytes + 1);
    defer std.testing.allocator.free(oversized_header);
    @memset(oversized_header, 'x');
    oversized_header[oversized_header.len - 1] = '\n';
    var violation: ?limits.Violation = null;
    try std.testing.expectError(error.LimitExceeded, parseWithLimit(std.testing.allocator, oversized_header, &violation));
    try std.testing.expectEqualStrings("input_header_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_input_header_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_input_header_bytes, violation.?.allowed);

    const target = testTarget();
    const target_json = try targetJson(std.testing.allocator, &target);
    defer std.testing.allocator.free(target_json);
    const inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{target_json});
    defer std.testing.allocator.free(inner);
    const short = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, inner.len + 1, inner });
    defer std.testing.allocator.free(short);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, short));

    const extra = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}x", .{ target_json, inner.len + 1, inner });
    defer std.testing.allocator.free(extra);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, extra));

    const other_oid = try target_mod.ObjectId.parse(.sha1, "1123456789abcdef0123456789abcdef01234567");
    var other_target = target;
    other_target.head_oid = other_oid;
    const other_json = try targetJson(std.testing.allocator, &other_target);
    defer std.testing.allocator.free(other_json);
    const mismatch_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{other_json});
    defer std.testing.allocator.free(mismatch_inner);
    const mismatch = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, mismatch_inner.len, mismatch_inner });
    defer std.testing.allocator.free(mismatch);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, mismatch));

    const failure_inner = "{\"schema_version\":1,\"status\":\"error\",\"error\":{\"code\":\"x\",\"message\":\"x\"}}\n";
    const failure = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, failure_inner.len, failure_inner });
    defer std.testing.allocator.free(failure);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, failure));
}

test "AI review input projection frame admits only canonical outer and inner headers" {
    const target = testTarget();
    const target_json = try targetJson(std.testing.allocator, &target);
    defer std.testing.allocator.free(target_json);
    const patch = "diff --git a/a b/a\n";
    const canonical_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":{d}}}\n{s}", .{ target_json, patch.len, patch });
    defer std.testing.allocator.free(canonical_inner);

    const noncanonical_inner_headers = [_][]const u8{
        "{\"status\":\"ok\",\"schema_version\":1,\"target\":",
        "{ \"schema_version\":1,\"status\":\"ok\",\"target\":",
    };
    for (noncanonical_inner_headers) |prefix| {
        const inner = try std.fmt.allocPrint(std.testing.allocator, "{s}{s},\"patch_size\":{d}}}\n{s}", .{ prefix, target_json, patch.len, patch });
        defer std.testing.allocator.free(inner);
        const framed = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, inner.len, inner });
        defer std.testing.allocator.free(framed);
        try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, framed));
    }

    const reordered_target = "{\"source_kind\":\"branch_range\",\"object_format\":\"sha1\",\"base_oid\":\"0123456789abcdef0123456789abcdef01234567\",\"head_oid\":\"0123456789abcdef0123456789abcdef01234567\",\"diff_base_oid\":\"0123456789abcdef0123456789abcdef01234567\"}";
    const inner_nested_reorder = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":{d}}}\n{s}", .{ reordered_target, patch.len, patch });
    defer std.testing.allocator.free(inner_nested_reorder);
    const nested_reorder = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, inner_nested_reorder.len, inner_nested_reorder });
    defer std.testing.allocator.free(nested_reorder);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, nested_reorder));

    const escaped_repository = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXB\\u0076\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, canonical_inner.len, canonical_inner });
    defer std.testing.allocator.free(escaped_repository);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, escaped_repository));

    const outer_reordered = try std.fmt.allocPrint(std.testing.allocator, "{{\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"schema_version\":1,\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, canonical_inner.len, canonical_inner });
    defer std.testing.allocator.free(outer_reordered);
    try std.testing.expectError(error.InvalidFrame, parse(std.testing.allocator, outer_reordered));
}

test "AI review input projection framing fixes exact and plus-one wire precedence" {
    var exact_header = try std.testing.allocator.alloc(u8, limits.max_input_header_bytes);
    defer std.testing.allocator.free(exact_header);
    @memset(exact_header, 'x');
    exact_header[exact_header.len - 1] = '\n';
    var violation: ?limits.Violation = null;
    try std.testing.expectError(error.InvalidFrame, parseWithLimit(std.testing.allocator, exact_header, &violation));
    try std.testing.expect(violation == null);

    var oversized_header = try std.testing.allocator.alloc(u8, limits.max_input_header_bytes + 1);
    defer std.testing.allocator.free(oversized_header);
    @memset(oversized_header, 'x');
    oversized_header[oversized_header.len - 1] = '\n';
    try std.testing.expectError(error.LimitExceeded, parseWithLimit(std.testing.allocator, oversized_header, &violation));
    try std.testing.expectEqualStrings("input_header_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_input_header_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_input_header_bytes, violation.?.allowed);

    const target = testTarget();
    const target_json = try targetJson(std.testing.allocator, &target);
    defer std.testing.allocator.free(target_json);
    const exact_patch = try std.testing.allocator.alloc(u8, limits.max_projection_bytes);
    defer std.testing.allocator.free(exact_patch);
    @memset(exact_patch, 'x');
    const exact_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":{d}}}\n{s}", .{ target_json, exact_patch.len, exact_patch });
    defer std.testing.allocator.free(exact_inner);
    const exact_request = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, exact_inner.len, exact_inner });
    defer std.testing.allocator.free(exact_request);
    var exact = try parseWithLimit(std.testing.allocator, exact_request, &violation);
    defer exact.deinit();
    try std.testing.expectEqual(limits.max_projection_bytes, exact.patch_bytes.len);
    try std.testing.expect(violation == null);

    const plus_patch = try std.testing.allocator.alloc(u8, limits.max_projection_bytes + 1);
    defer std.testing.allocator.free(plus_patch);
    @memset(plus_patch, 'x');
    const plus_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":{d}}}\n{s}", .{ target_json, plus_patch.len, plus_patch });
    defer std.testing.allocator.free(plus_inner);
    const plus_request = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, plus_inner.len, plus_inner });
    defer std.testing.allocator.free(plus_request);
    violation = null;
    try std.testing.expectError(error.LimitExceeded, parseWithLimit(std.testing.allocator, plus_request, &violation));
    try std.testing.expectEqualStrings("projection_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_projection_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_projection_bytes, violation.?.allowed);

    const short_inner = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"status\":\"ok\",\"target\":{s},\"patch_size\":0}}\n", .{target_json});
    defer std.testing.allocator.free(short_inner);
    const exact_frame_declaration = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, limits.max_projection_frame_bytes, short_inner });
    defer std.testing.allocator.free(exact_frame_declaration);
    violation = null;
    try std.testing.expectError(error.InvalidFrame, parseWithLimit(std.testing.allocator, exact_frame_declaration, &violation));
    try std.testing.expect(violation == null);
    const plus_frame_declaration = try std.fmt.allocPrint(std.testing.allocator, "{{\"schema_version\":1,\"repository\":{{\"path_bytes_b64\":\"L3RtcC9yZXBv\"}},\"target\":{s},\"projection_frame_size\":{d}}}\n{s}", .{ target_json, limits.max_projection_frame_bytes + 1, short_inner });
    defer std.testing.allocator.free(plus_frame_declaration);
    try std.testing.expectError(error.LimitExceeded, parseWithLimit(std.testing.allocator, plus_frame_declaration, &violation));
    try std.testing.expectEqualStrings("projection_frame_bytes", violation.?.resource);
    try std.testing.expectEqual(limits.max_projection_frame_bytes + 1, violation.?.observed);
    try std.testing.expectEqual(limits.max_projection_frame_bytes, violation.?.allowed);
}
