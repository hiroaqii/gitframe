//! Small, path-free failure evidence and bounded labels owned by a retained job.
const std = @import("std");
const limits = @import("limits.zig");

pub const Resource = enum {
    unknown,
    context_bytes,
    provider_input_bytes,
    stdout_bytes,
    stderr_bytes,
    final_answer_bytes,
    projection_frame_bytes,
    projection_header_bytes,
    projection_bytes,
    input_header_bytes,
    review_input_frame_bytes,
    plan_summary_bytes,
    review_units,
    unit_bytes,
    unit_raw_fragment_bytes,
    locations_per_side,
    lines_per_unit,
    coverage_spans_per_unit,
    guidance_per_unit_bytes,
    input_output_bytes,
    guidance_file_bytes,
    guidance_files,
    guidance_aggregate_bytes,
    guidance_path_depth,
    changed_files,
    hunks,
    metadata_lines_per_unit,
    diff_line_bytes,
    raw_path_bytes,
    hunk_section_bytes,
    metadata_line_bytes,
    display_path_bytes,

    pub fn unit(self: Resource) enum { bytes, count, unknown } {
        if (self == .unknown) return .unknown;
        return if (std.mem.endsWith(u8, @tagName(self), "_bytes")) .bytes else .count;
    }
};

pub const Limit = struct {
    resource: Resource,
    allowed: usize,
    observed: usize,
    observation: enum { exact, at_least },

    pub fn fromViolation(violation: ?limits.Violation) ?Limit {
        const value = violation orelse return null;
        return .{
            .resource = resourceFromName(value.resource),
            .allowed = value.allowed,
            .observed = value.observed,
            .observation = .at_least,
        };
    }
};

pub const Unavailable = enum { private_environment, executable_missing, executable_denied, launch_failed };
pub const Incompatible = enum { environment, process_control, unexpected_event, model_mismatch };
pub const InvalidResultStage = enum { input, answer };
pub const InternalStage = enum { before_provider };
pub const StoreCause = enum {
    invalid_artifact,
    target_unavailable,
    store_unavailable,
    unsupported_platform,
    unsupported_filesystem,
    duplicate_review_id,
    store_invalid,
    repository_invalid,
    main_worktree_unavailable,
    repository_name_invalid,
    repository_namespace_collision,
    target_label_invalid,
    local_time_unavailable,
    run_name_collision,
    git_failed,
    io_failed,
    binding_mismatch,
    concurrent_conflict,
};
pub const Exit = struct {
    classification: enum { authentication_response, cli_response, other },
    term: std.process.Child.Term,
};

pub const Timeout = struct {
    stage: enum { before_provider, version_probe, provider_execution },
    owner: enum { caller, adapter },
    budget: std.Io.Duration,

    pub fn remaining(now: std.Io.Clock.Timestamp, deadline: std.Io.Clock.Timestamp) std.Io.Duration {
        return .fromNanoseconds(@max(0, now.durationTo(deadline).raw.nanoseconds));
    }
};

fn resourceFromName(name: []const u8) Resource {
    return std.meta.stringToEnum(Resource, name) orelse .unknown;
}

pub const Label = struct {
    bytes: [95]u8 = @splat(0),
    len: u8 = 0,

    pub fn init(text: []const u8) Label {
        var result: Label = .{};
        var offset: usize = 0;
        while (offset < text.len) {
            const length = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
            const end = @min(offset + length, text.len);
            const codepoint = std.unicode.utf8Decode(text[offset..end]) catch 0;
            const unsafe = !std.unicode.utf8ValidateSlice(text[offset..end]) or
                codepoint < 0x20 or (codepoint >= 0x7f and codepoint <= 0x9f) or
                // Unicode Bidi_Control: marks, embeddings/overrides, isolates.
                codepoint == 0x061c or codepoint == 0x200e or codepoint == 0x200f or
                (codepoint >= 0x202a and codepoint <= 0x202e) or (codepoint >= 0x2066 and codepoint <= 0x2069);
            const piece = if (unsafe) "?" else text[offset..end];
            // Reserve the truncation marker whenever more input remains.
            const capacity: usize = if (end < text.len) result.bytes.len - "…".len else result.bytes.len;
            if (result.len + piece.len > capacity) {
                @memcpy(result.bytes[result.len..][0.."…".len], "…");
                result.len += "…".len;
                break;
            }
            @memcpy(result.bytes[result.len..][0..piece.len], piece);
            result.len += @intCast(piece.len);
            offset = end;
        }
        return result;
    }

    pub fn slice(self: *const Label) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Display = struct {
    repository: Label = .{},
    base: Label = .{},
    head: Label = .{},
};

comptime {
    std.debug.assert(@sizeOf(?Limit) <= 256);
    std.debug.assert(@sizeOf(Label) <= 96);
}

test "AI review diagnostic owns limit names and preserves unknown observations" {
    // Explicit current producer names; keep this list in sync with producers,
    // including helper arguments in projection_frame, input_command and patch_plan.
    const byte_names = [_][]const u8{
        "context_bytes",            "provider_input_bytes",     "projection_frame_bytes",  "projection_bytes",
        "input_header_bytes",       "review_input_frame_bytes", "plan_summary_bytes",      "unit_bytes",
        "unit_raw_fragment_bytes",  "guidance_per_unit_bytes",  "input_output_bytes",      "guidance_file_bytes",
        "guidance_aggregate_bytes", "diff_line_bytes",          "raw_path_bytes",          "hunk_section_bytes",
        "metadata_line_bytes",      "display_path_bytes",       "projection_header_bytes", "stdout_bytes",
        "stderr_bytes",             "final_answer_bytes",
    };
    const count_names = [_][]const u8{
        "review_units",            "locations_per_side",  "lines_per_unit", "coverage_spans_per_unit",
        "guidance_files",          "guidance_path_depth", "changed_files",  "hunks",
        "metadata_lines_per_unit",
    };
    for (byte_names) |name| {
        const limit = Limit.fromViolation(.{ .resource = name, .allowed = 1024, .observed = 1025 }).?;
        try std.testing.expectEqualStrings(name, @tagName(limit.resource));
        try std.testing.expectEqual(.bytes, limit.resource.unit());
        try std.testing.expectEqual(@as(usize, 1024), limit.allowed);
        try std.testing.expectEqual(@as(usize, 1025), limit.observed);
        try std.testing.expectEqual(.at_least, limit.observation);
    }
    for (count_names) |name| {
        const limit = Limit.fromViolation(.{ .resource = name, .allowed = 3, .observed = 4 }).?;
        try std.testing.expectEqualStrings(name, @tagName(limit.resource));
        try std.testing.expectEqual(.count, limit.resource.unit());
        try std.testing.expectEqual(@as(usize, 3), limit.allowed);
        try std.testing.expectEqual(@as(usize, 4), limit.observed);
        try std.testing.expectEqual(.at_least, limit.observation);
    }
    try std.testing.expectEqual(@typeInfo(Resource).@"enum".fields.len - 1, byte_names.len + count_names.len);
    for ([_][]const u8{ "future", "future_bytes", "" }) |name| {
        const limit = Limit.fromViolation(.{ .resource = name, .allowed = 3, .observed = 4 }).?;
        try std.testing.expectEqual(.unknown, limit.resource);
        try std.testing.expectEqual(.unknown, limit.resource.unit());
        try std.testing.expectEqual(@as(usize, 3), limit.allowed);
        try std.testing.expectEqual(@as(usize, 4), limit.observed);
    }
    var name = [_]u8{ 'r', 'e', 'v', 'i', 'e', 'w', '_', 'u', 'n', 'i', 't', 's' };
    const value = Limit.fromViolation(.{ .resource = &name, .allowed = 256, .observed = 257 }).?;
    @memset(&name, 'x');
    try std.testing.expectEqual(Resource.review_units, value.resource);
    try std.testing.expectEqual(.count, value.resource.unit());
    try std.testing.expectEqual(.at_least, value.observation);
    try std.testing.expectEqual(@as(usize, 257), value.observed);
    const unknown = Limit.fromViolation(.{ .resource = "future", .allowed = 3, .observed = 4 }).?;
    try std.testing.expectEqual(.unknown, unknown.resource.unit());
    try std.testing.expectEqual(@as(?Limit, null), Limit.fromViolation(null));
}

test "AI review diagnostic labels are bounded sanitized UTF-8 snapshots" {
    const label = Label.init("枝" ** 40);
    try std.testing.expect(label.len <= 96);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label.slice()));
    try std.testing.expect(std.mem.endsWith(u8, label.slice(), "…"));
    const bidi_controls = [_]u21{ 0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069 };
    for (bidi_controls) |codepoint| {
        var text: [5]u8 = undefined;
        text[0] = 'a';
        const length = try std.unicode.utf8Encode(codepoint, text[1..][0..4]);
        text[1 + length] = 'b';
        const safe = Label.init(text[0 .. length + 2]);
        try std.testing.expectEqualStrings("a?b", safe.slice());
        try std.testing.expect(std.unicode.utf8ValidateSlice(safe.slice()));
        try std.testing.expect(@sizeOf(Label) <= 96);
    }
    const sanitized = Label.init("a\n\x1b\xff\xc2\x85b");
    try std.testing.expectEqualStrings("a????b", sanitized.slice());
}
